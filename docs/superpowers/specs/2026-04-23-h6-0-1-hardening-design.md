# H6.0.1 Hardening — Spec

**Date**: 2026-04-23
**Status**: Design frozen, awaiting codex adversarial review
**Scope**: Fix 3 HIGH residuals from H6.0 R53 (Grep-no-path / Skill-invoke-order / state-write-fail-open)
**Branch**: `hardening-6.0.1` off `origin/main@893b832` (H6.0 merged)
**Precondition**: H6.0.1 merged is a hard gate before any H6.0-flip or H6.1-H6.10 per-skill flip PR

## Context

H6.0 (PR #30, squash-merge `893b832`, merged 2026-04-23) landed the skill-pipeline enforcement framework in `drift-log` (observe-only) mode. The merge accepted codex findings R49-R53 as residuals (10 HIGH + 1 MEDIUM). Seven HIGH + one MEDIUM were fixed on the merged branch during iteration; three HIGH (R53 F1/F2/F3) remain and are the exclusive scope of this PR.

Why residual merge was safe: framework runs observe-only → no response is blocked → accepted findings cause no in-the-wild harm. Fix MUST land BEFORE `enforcement_mode: drift-log → block` flip.

## Out of Scope

- `enforcement_mode` flip (that is H6.0-flip PR)
- Any per-skill enforcement change (H6.1-H6.10)
- New findings outside R53 F1/F2/F3
- Refactors / cleanup not required by the fixes
- CLAUDE.md / workflow-rules.json / skill-invoke-enforced.json changes

## Residuals (in-scope)

### R53 F1 — Grep/Glob with no `path` parameter bypasses read-safety

**File**: `.claude/hooks/stop-response-check.sh` line 88-108 (`_path_is_safe_for_read`) + three exempt branches (line 118, 194, 214).

**Bug**: Path extraction in each exempt branch uses
```python
tgt = inp.get('file_path') or inp.get('path') or inp.get('pattern') or ''
```
When `Grep(pattern="TODO")` has no `path` parameter, the code falls back to treating the `pattern` string as a path. `_path_is_safe_for_read` then checks the pattern for glob chars / sensitive names / repo-containment — but the actual Grep call recursively searches the whole cwd tree, bypassing any path-safety intent.

**Fix (approach A)**:
1. Remove the `pattern` fallback everywhere (`pattern` is NOT a path).
2. Introduce a helper `_extract_read_target(tu)` that returns `(tool_name, path_str_or_None)`:
   - `Read` → `file_path`
   - `Grep` / `Glob` → `path` only; `None` if absent
3. In `_path_is_safe_for_read`, when called for Grep/Glob with `None`/empty path, return
   `BLOCK: {exempt_label} Grep/Glob 必须显式传 path 参数（不允许无 path 全仓搜索）`.
4. Update three call sites (read-only-query / behavior-neutral / single-step-no-semantic-change).

**Tests** (`tests/hooks/test_stop_response_check.py`):
- `test_read_only_grep_without_path_blocks` — `Grep(pattern=".env")` no path → BLOCK
- `test_read_only_grep_with_safe_path_passes` — `Grep(pattern=".env", path="docs/")` → PASS
- `test_behavior_neutral_glob_without_path_blocks` — same case in behavior-neutral branch → BLOCK
- `test_single_step_grep_without_path_blocks` — same case in single-step branch → BLOCK

**Risk**: False positives for legitimate no-path Grep. Mitigation: no-path Grep is always repo-wide; in an exempt context (which is meant to be minimal & read-limited), requiring an explicit path is the right tightening.

---

### R53 F2 — Skill invoke with no order constraint allows lagging invoke to satisfy L2

**File**: `.claude/hooks/skill-invoke-check.sh` line 495-530 (L2 invoke match).

**Bug**: Current L2 only checks "does `tool_uses` contain a Skill invoke matching the declared gate name". Attacker can emit `[Write(dangerous), Bash(exfil), Skill(superpowers:brainstorming)]` and satisfy L2. In observe mode nothing blocks; in block mode this is a real bypass.

**Fix (approach A)**:
1. After finding the matching Skill invoke, compute:
   - `skill_idx` = index of the first matching `Skill` tool_use (input.skill == SKILL_NAME) in `tool_uses`
   - `first_non_skill_idx` = index of the first tool_use whose `name != "Skill"`
2. If `first_non_skill_idx < skill_idx` → emit `drift_log "invoke_order_violation" true null "$LAST_STAGE"` and in block mode `block "Skill invoke 必须在任何其他 tool_use 之前; 第一个非-Skill tool 在 index N, Skill invoke 在 index M"`.
3. Order check is additive to existing `gate_declared_no_invoke`: it only runs when a matching Skill IS found. Absent-invoke path unchanged.

**Tests** (`tests/hooks/test_skill_invoke_check.py`):
- `test_l2_skill_first_passes` — `[Skill, Write]` → PASS (observe and block)
- `test_l2_write_before_skill_drift_logs` — `[Write, Skill]` drift-log → drift-log entry `invoke_order_violation`, exit 0
- `test_l2_write_before_skill_blocks` — `[Write, Skill]` block mode → BLOCK
- `test_l2_only_skill_passes` — `[Skill]` → PASS

**Risk**: Responses that legitimately use non-Skill tools before invoking Skill (e.g., `TaskCreate` / `ToolSearch`). Decision: treat all non-Skill tool_uses uniformly; Skill must be strictly first. Rationale: the whole point of invoking a skill is to load its rubric BEFORE doing work; any tool before Skill is bypassable attack surface. If this proves too strict in practice, narrow via follow-up PR (whitelist `TaskCreate` / `ToolSearch` as "pre-skill meta tools") — NOT in this PR.

---

### R53 F3 — state write / mv failure is fail-open under block mode

**File**: `.claude/hooks/skill-invoke-check.sh` line 645-655.

**Bug**:
- Lines 645-650: Python `json.dump` in heredoc catches exceptions, prints stderr warning, `sys.exit(0)`.
- Lines 652-655: bash `mv $TMP $STATE_FILE` on failure prints stderr warning, removes tmp, continues.

Either failure → `last_stage` NOT updated → next response sees stale `_initial` (or prior stage) → L4 transition check evaluated against wrong baseline → effectively a bypass in block mode.

**Fix (approach A)**:
1. Python heredoc: change `sys.exit(0)` in the except block to `sys.exit(1)`. Remove the silent-swallow.
2. Bash after heredoc: capture Python's exit code. If nonzero AND `CONFIG_MODE == "block"` → emit block JSON (via existing `block()` helper) with reason `"state write failed (持久化失败，block 模式拒绝继续)"`. If nonzero AND `drift-log` → keep current stderr warn behavior; also emit `drift_log "state_write_failed" false null "$LAST_STAGE"` for observability.
3. Bash `mv` branch: same mode-dispatch. Block mode → block; drift-log mode → stderr + drift_log.

**Tests** (`tests/hooks/test_skill_invoke_check.py`):
- `test_state_write_fail_drift_mode_passes` — make STATE_DIR readonly (chmod 0555) + drift-log mode → exit 0, stderr contains `state-write-failed`
- `test_state_write_fail_block_mode_blocks` — same chmod + block mode → BLOCK
- `test_state_mv_fail_block_mode_blocks` — simulate mv failure (e.g. STATE_FILE is a dir) + block mode → BLOCK

**Risk**: Observe-mode operator loses observability from non-blocking infra hiccups. Mitigation: we ADD a `drift_log` entry for `state_write_failed` so it's still visible in the drift-log stream.

## Non-goals / Explicit Deferrals

- No new enforcement-mode flip (strict contract: this PR stays observe-only; all 3 fixes pass through existing `CONFIG_MODE` branches).
- No refactor of `_path_is_safe_for_read` signature beyond what F1 requires.
- No consolidation of R49-R52 fixes (they are already merged; do NOT touch).
- No new `skill-invoke-enforced.json` keys.

## Acceptance (non-coder-executable)

Per CLAUDE.md §Repository governance backstop item 2: every module/phase delivery includes a non-coder acceptance checklist.

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| A1 | 用户终端执行 `pytest tests/hooks/test_stop_response_check.py -v` | 所有测试 pass；新增 4 个 F1 测试里至少 3 个是 "no path → BLOCK" 断言 | 输出里 "passed" 数 ≥ 原有 + 4；failed = 0 |
| A2 | 用户终端执行 `pytest tests/hooks/test_skill_invoke_check.py -v` | 所有测试 pass；新增 4 个 F2 + 3 个 F3 测试 | 输出里 "passed" 数 ≥ 原有 + 7；failed = 0 |
| A3 | 用户肉眼审 diff：`git diff origin/main -- .claude/hooks/ tests/hooks/` | 只改 2 个 hooks 文件 + 2 个 test 文件，无其他文件改动（尤其 skill-invoke-enforced.json / workflow-rules.json / CLAUDE.md 必须 0 改动） | diff 只覆盖 4 个文件 |
| A4 | 用户读 spec + plan 确认 scope | scope 只含 R53 F1/F2/F3；不含 enforcement_mode flip / 其他 residual / 无关 refactor | 用户口头确认 |
| A5 | 用户 terminal 跑 `bash .claude/scripts/codex-attest.sh --scope branch-diff --head hardening-6.0.1 --base origin/main` | codex 回 `Verdict: approve`（ledger 记录） | 脚本 exit 0，ledger 更新 |

**禁词**：此 checklist 不出现 "should work" / "looks good" / "probably fine"；所有判定有可观测命令。

## Review Gates

1. **Spec self-review** (inline, done now): placeholder scan / 矛盾 / 范围 / 歧义
2. **Codex adversarial-review on spec** (this PR stage 1): `bash .claude/scripts/codex-attest.sh --scope working-tree docs/superpowers/specs/2026-04-23-h6-0-1-hardening-design.md` → must reach `approve`
3. **Plan written** (via `superpowers:writing-plans`)
4. **Codex adversarial-review on plan**: working-tree on plan file → `approve`
5. **Implementation** (TDD via `superpowers:test-driven-development`)
6. **Codex adversarial-review on branch**: `--scope branch-diff --head hardening-6.0.1 --base origin/main` → `approve`
7. **PR → user merges after non-coder acceptance A1-A5 pass**

## Codex budget contract

Per hardening-5 lesson + memory "Codex plan 5+轮 pushback 规则":
- Each review gate budget ≤ 3 rounds
- Round 4+ → inline-justify as spec-scope ambiguity or accept as residual for H6.0.2
- Round 5 → user escalate
- Total PR codex budget ≤ 9 rounds across all gates
