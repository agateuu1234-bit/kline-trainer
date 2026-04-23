# H6.0.1 Hardening — Spec (v6, scope 收缩)

**Date**: 2026-04-23
**Status**: Design frozen, awaiting codex adversarial review (round 6+)
**Scope**: Fix 2 HIGH residuals from H6.0 R53 — **F1** (Grep/Bash-grep read-safety bypass) **and F2** (Skill invoke order bypass) only
**Branch**: `hardening-6.0.1` off `origin/main@893b832` (H6.0 merged)
**Sibling PR**: H6.0.1b (state persistence/integrity, R53 F3 + R-SID-1 + config-robustness) — separate spec, separate PR, must also land before H6.0-flip
**Precondition**: BOTH H6.0.1 AND H6.0.1b merged are hard gates before any H6.0-flip or H6.1-H6.10 per-skill flip PR

## Why v6 scope收缩 (decision log)

Rounds 1-5 of codex adversarial review kept expanding F3 scope (state-write-fail → reset-trigger → mixed-rollout → CLAUDE_SESSION_ID → config-robustness). All 5 rounds produced legitimate new HIGH findings; pattern resembles hardening-5 (memory: 11 rounds non-convergent, aborted).

User decision 2026-04-23 (this conversation): split H6.0.1 into two PRs:
- **H6.0.1 (this PR)** — R53 F1 + F2 only. Fixes are well-bounded, 1-round convergence expected.
- **H6.0.1b (sibling PR, separate spec)** — R53 F3 (state persistence/integrity, 6 guard points + reset-trigger + ANY_BLOCK) + R-SID-1 (CLAUDE_SESSION_ID continuity) + config-robustness (ANY_BLOCK fail-close when skill-invoke-enforced.json is missing/malformed). These are all "state-integrity" family and cohere better in one PR that can iterate on the family together.

Both PRs land BEFORE first H6.x flip.

## Context

H6.0 (PR #30, squash-merge `893b832`, merged 2026-04-23) landed the skill-pipeline enforcement framework in `drift-log` (observe-only) mode. The merge accepted codex findings R49-R53 as residuals (10 HIGH + 1 MEDIUM). Seven HIGH + one MEDIUM were fixed on the merged branch during iteration; three HIGH (R53 F1/F2/F3) remain. This PR fixes F1 and F2; H6.0.1b fixes F3.

Why residual merge was safe: framework runs observe-only → no response is blocked → accepted findings cause no in-the-wild harm. All three residuals MUST land BEFORE `enforcement_mode: drift-log → block` flip.

## Out of Scope

- R53 F3 (state persistence/integrity) — **moved to H6.0.1b**
- R-SID-1 (CLAUDE_SESSION_ID continuity) — **in H6.0.1b** (part of state-integrity family)
- Config-robustness (skill-invoke-enforced.json missing/malformed handling) — **in H6.0.1b**
- `enforcement_mode` flip (that is H6.0-flip PR)
- Any per-skill enforcement change (H6.1-H6.10)
- New findings outside R53 F1/F2
- Refactors / cleanup not required by the fixes
- CLAUDE.md / workflow-rules.json / skill-invoke-enforced.json changes

## Residuals (in-scope)

### R53 F1 — Grep/Glob (tool-native AND Bash grep/rg) with no `path` bypasses read-safety

**File**: `.claude/hooks/stop-response-check.sh`
- `_path_is_safe_for_read` helper (line 88-108)
- Tool-native branches: line 115-121 (read-only-query), 192-197 (behavior-neutral), 212-215 (single-step)
- Bash branches: line 185-191 (behavior-neutral `grep/rg/jq` arg loop), 230-236 (single-step similar)

**Bug — two equivalent bypass paths**:

(a) **Tool-native**: Path extraction in each exempt branch uses
```python
tgt = inp.get('file_path') or inp.get('path') or inp.get('pattern') or ''
```
When `Grep(pattern="TODO")` has no `path`, the code falls back to treating `pattern` as a path. `_path_is_safe_for_read` checks the pattern string for glob / sensitive-name / repo-containment — but the actual Grep recursively searches the whole cwd tree, bypassing the safety intent.

(b) **Bash equivalent** (codex round-1 finding 1): `safe_bash` regex (line 153) + arg loop (line 185-191) allows Bash `grep TODO` or `rg secret` with NO path operand. Loop feeds `TODO` / `secret` through `_path_is_safe_for_read` as if it were a path (passes — not sensitive, not glob), but `rg` without path recurses cwd and `grep -r` / `grep --recursive` does the same. Equivalent repo-wide leak.

**Fix (approach A — both paths)**:

Tool-native fixes:
1. Remove `pattern` fallback from path extraction (pattern is NOT a path).
2. Introduce helper `_extract_read_target(tu)` returning `(tool_name, path_str_or_None)`:
   - `Read` → `file_path` (required)
   - `Grep` / `Glob` → `path` only (None if absent)
3. `_path_is_safe_for_read`: when called with empty/None path for Grep/Glob, return
   `BLOCK: {exempt_label} Grep/Glob 必须显式传 path 参数（不允许无 path 全仓搜索）`.
4. **Reject repo-root-equivalent paths** (codex round-2 finding 1): after `rel = resolved.relative_to(repo_root)`, if `str(rel).replace(os.sep, '/')` is `'.'` or empty, return `BLOCK: {exempt_label} 路径归一化到仓库根等于全仓搜索: {s}`. Catches `.`, `./`, `docs/..`, `<repo>` absolute, etc.
5. Update three tool-native call sites.

Bash fixes (behavior-neutral + single-step branches):
6. For `grep` / `rg` (identified by `parts[0]`):
   - **Ban all flags in exempt context** (codex round-3 finding 3): if ANY arg matches regex `^-` → `BLOCK: exempt(X) Bash {grep|rg} 不允许任何 flag（避免 -g/-f/--include 这类 flag 吃 operand 导致 operand 误分类）`.
   - After flag-ban, require exactly 2 positional args: `pattern` (arg[0]) + `path` (arg[1]). <2 or >2 → `BLOCK: exempt(X) Bash {grep|rg} 必须恰好 "<pattern> <path>" 形式`.
   - Pattern is NOT path-safety-checked. Path goes through `_path_is_safe_for_read`, which (step 4) rejects repo-root-equivalent paths.
7. `cat` / `head` / `tail` / `wc` keep existing rule (all non-flag args are paths; require ≥1).
8. **`jq` special parse** (codex round-4 finding 3, regression avoidance): `jq` filters like `.`, `.items[]`, `keys` are NOT paths. Without this fix, the new repo-root-reject would false-block `jq .`. Fix: for `parts[0] == "jq"`, the FIRST non-flag arg is the filter (NOT path-checked); subsequent args are paths (path-checked normally). Zero non-flag args → BLOCK.

**Tests** (`tests/hooks/test_stop_response_check.py`) — 15 new tests:

Tool-native (4):
- `test_read_only_grep_without_path_blocks` — `Grep(pattern=".env")` no path → BLOCK
- `test_read_only_grep_with_safe_path_passes` — `Grep(pattern=".env", path="docs/")` → PASS
- `test_behavior_neutral_glob_without_path_blocks` → BLOCK
- `test_single_step_grep_without_path_blocks` → BLOCK

Bash (3):
- `test_behavior_neutral_bash_rg_without_path_blocks` — `Bash("rg secret")` → BLOCK
- `test_behavior_neutral_bash_rg_with_path_passes` — `Bash("rg secret docs/")` → PASS
- `test_single_step_bash_grep_recursive_no_path_blocks` — `Bash("grep -r TODO")` → BLOCK (flag-ban catches it)

Repo-root-equivalent rejection (3 — round-2 finding 1):
- `test_read_only_grep_dot_path_blocks` — `Grep(pattern="secret", path=".")` → BLOCK
- `test_behavior_neutral_bash_rg_dot_blocks` — `Bash("rg secret .")` → BLOCK
- `test_single_step_grep_normalized_root_blocks` — `Grep(pattern="secret", path="docs/..")` → BLOCK

Flag-ban (2 — round-3 finding 3):
- `test_behavior_neutral_bash_rg_with_flag_blocks` — `Bash("rg -g '*.md' secret docs/")` → BLOCK
- `test_single_step_bash_grep_with_f_flag_blocks` — `Bash("grep -f patterns.txt secret docs/")` → BLOCK

jq regression coverage (3 — round-4 finding 3):
- `test_behavior_neutral_bash_jq_filter_only_blocks` — `Bash("jq .")` → BLOCK (no file)
- `test_behavior_neutral_bash_jq_filter_and_file_passes` — `Bash("jq . docs/foo.json")` → PASS
- `test_behavior_neutral_bash_jq_filter_and_sensitive_file_blocks` — `Bash("jq . .env")` → BLOCK

**Risk**: False positives for legitimate no-path Grep/rg. Mitigation: no-path Grep/rg is always repo-wide; exempt contexts are by design minimal and read-limited. Escape hatch: declare a real skill gate.

---

### R53 F2 — Skill invoke with no order constraint allows lagging invoke to satisfy L2

**File**: `.claude/hooks/skill-invoke-check.sh` line 495-530 (L2 invoke match).

**Bug**: Current L2 only checks "does `tool_uses` contain a Skill invoke matching the declared gate name". Attacker can emit `[Write(dangerous), Bash(exfil), Skill(superpowers:brainstorming)]` and satisfy L2. In observe mode nothing blocks; in block mode this is a real bypass.

**Fix (approach A — STRICT first-index)**:
1. After finding the matching Skill invoke, compute `skill_idx` = index of the first matching `Skill` tool_use (input.skill == SKILL_NAME) in `tool_uses`.
2. If `skill_idx != 0` → emit `drift_log "invoke_order_violation" true null "$LAST_STAGE"` and in block mode `block "Skill invoke '$SKILL_NAME' 必须是 tool_uses[0]；实际在 index $skill_idx"`.
3. Order check is additive to existing `gate_declared_no_invoke`: runs only when a matching Skill IS found. Absent-invoke path unchanged.
4. **Rationale for strict `== 0`** (codex round-2 finding 3): "before first non-Skill" allows `[Skill(other), Skill(required), Write]` to pass — an unrelated skill can shape the turn before the gated rubric loads. Strict `== 0` matches the spec's own block message contract.

**Tests** (`tests/hooks/test_skill_invoke_check.py`) — 6 new tests:
- `test_l2_skill_first_passes` — `[Skill(required), Write]` → PASS
- `test_l2_write_before_skill_drift_logs` — `[Write, Skill(required)]` drift-log mode → drift entry, exit 0
- `test_l2_write_before_skill_blocks` — same sequence block mode → BLOCK
- `test_l2_only_skill_passes` — `[Skill(required)]` → PASS
- `test_l2_other_skill_before_required_drift_logs` — `[Skill(other), Skill(required), Write]` drift-log → drift entry, exit 0
- `test_l2_other_skill_before_required_blocks` — same sequence block mode → BLOCK

**Risk**: Responses that legitimately use meta-tools (`TaskCreate` / `ToolSearch`) or preparatory Skills before the gated Skill. Decision: accept strictness; invoke the gated Skill FIRST. If a legitimate case emerges, narrow via follow-up exempt_rule — NOT in this PR.

---

## Non-goals / Explicit Deferrals

- R53 F3 (state persistence/integrity) + R-SID-1 + config-robustness → **H6.0.1b sibling PR** (MUST land before any H6.x flip)
- No refactor of `_path_is_safe_for_read` signature beyond what F1 requires
- No consolidation of R49-R52 fixes (they are already merged; do NOT touch)
- No new `skill-invoke-enforced.json` keys

## Sibling PR contract (H6.0.1b)

H6.0.1b is a separate PR with its own spec, plan, and codex review. Both PRs must land before any H6.x flip. H6.0-flip PR body MUST link BOTH H6.0.1 and H6.0.1b commit SHAs as preconditions; H6.0-flip codex review MUST verify both are landed. This PR (H6.0.1) does not depend on H6.0.1b for its own correctness — F1/F2 are orthogonal to state integrity.

## Acceptance (non-coder-executable)

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| A1 | 用户终端执行 `pytest tests/hooks/test_stop_response_check.py -v` | 所有测试 pass；新增 15 个 F1 测试 | 输出里 "passed" 数 ≥ 原有 + 15；failed = 0 |
| A2 | 用户终端执行 `pytest tests/hooks/test_skill_invoke_check.py -v` | 所有测试 pass；新增 6 个 F2 测试 | 输出里 "passed" 数 ≥ 原有 + 6；failed = 0 |
| A3 | 用户肉眼审 diff：`git diff origin/main -- .claude/hooks/ tests/hooks/` | 只改 2 个 hooks 文件 + 2 个 test 文件；skill-invoke-enforced.json / workflow-rules.json / CLAUDE.md 必须 0 改动；**skill-invoke-check.sh 仅涉及 F2 L2 顺序检查（line 495-530 周边），不含任何 state 相关修改** | diff 只覆盖 4 个文件；skill-invoke-check.sh 改动行数 ≤ 30 |
| A4 | 用户读 spec 确认 scope | scope 只含 R53 F1 + F2；F3 明确标注归 H6.0.1b | 用户口头确认 |
| A5 | 用户 terminal 跑 `bash .claude/scripts/codex-attest.sh --scope branch-diff --head hardening-6.0.1 --base origin/main` | codex 回 `Verdict: approve`（ledger 记录） | 脚本 exit 0，ledger 更新 |

**禁词**：此 checklist 不出现 "should work" / "looks good" / "probably fine"；所有判定有可观测命令。

## Review Gates

1. Spec self-review (inline, done)
2. Codex adversarial-review on spec (working-tree) → must `approve` — round 6 attempt after scope 收缩
3. Plan written (via `superpowers:writing-plans`)
4. Codex adversarial-review on plan (working-tree) → `approve`
5. Implementation (TDD via `superpowers:test-driven-development`)
6. Codex adversarial-review on branch (branch-diff) → `approve`
7. PR → user merges after acceptance A1-A5 pass

## Codex budget contract (收缩后预期)

Rounds 1-5 of v1-v5 spec review spent on the F3 family; those findings migrate to H6.0.1b's own review budget. For this收缩版 H6.0.1:
- Spec round 6 (post-scope-shrink) SHOULD approve in 1 round — F1 design was stable through all 5 rounds (refined not reopened); F2 stable since round 2.
- Plan gate: ≤ 3 rounds
- Branch-diff gate: ≤ 3 rounds
- Total remaining H6.0.1 codex budget ≤ 7 rounds (1 + 3 + 3)
- Round ≥ 5 on any single gate → user escalate
