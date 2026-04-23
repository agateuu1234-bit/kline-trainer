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

(b) **Bash equivalent** (codex R53-review-round-1 finding 1): `safe_bash` regex (line 153) + arg loop (line 185-191) allows Bash `grep TODO` or `rg secret` with NO path operand. Loop feeds `TODO` / `secret` through `_path_is_safe_for_read` as if it were a path (passes — not sensitive, not glob), but `rg` without path recurses cwd and `grep -r` / `grep --recursive` does the same. Equivalent repo-wide leak.

**Fix (approach A — both paths)**:

Tool-native fixes:
1. Remove `pattern` fallback from path extraction (pattern is NOT a path).
2. Introduce helper `_extract_read_target(tu)` returning `(tool_name, path_str_or_None)`:
   - `Read` → `file_path` (required)
   - `Grep` / `Glob` → `path` only (None if absent)
3. `_path_is_safe_for_read`: when called with empty/None path for Grep/Glob, return
   `BLOCK: {exempt_label} Grep/Glob 必须显式传 path 参数（不允许无 path 全仓搜索）`.
4. Update three tool-native call sites.

Bash fixes (behavior-neutral + single-step branches):
5. After `shlex.split(cmd)`, separately for `grep` / `rg` commands (identified by `parts[0]`):
   - Strip leading `-<flag>` args (existing logic).
   - Require ≥2 non-flag positional args (`pattern` + at least 1 path). <2 → `BLOCK: exempt(X) Bash {grep|rg} 必须同时传 pattern 和 path (拒绝无 path 全仓搜索)`.
   - The FIRST non-flag arg is the pattern (do NOT path-safety check it).
   - ALL subsequent args ARE paths — each goes through `_path_is_safe_for_read` as before.
6. `cat` / `head` / `tail` / `wc` / `jq` keep existing rule (all non-flag args are paths; require ≥1).

**Tests** (`tests/hooks/test_stop_response_check.py`) — 7 new tests:

Tool-native (4):
- `test_read_only_grep_without_path_blocks` — `Grep(pattern=".env")` no path → BLOCK
- `test_read_only_grep_with_safe_path_passes` — `Grep(pattern=".env", path="docs/")` → PASS
- `test_behavior_neutral_glob_without_path_blocks` — same in behavior-neutral → BLOCK
- `test_single_step_grep_without_path_blocks` — same in single-step → BLOCK

Bash (3):
- `test_behavior_neutral_bash_rg_without_path_blocks` — `Bash("rg secret")` → BLOCK
- `test_behavior_neutral_bash_rg_with_path_passes` — `Bash("rg secret docs/")` → PASS
- `test_single_step_bash_grep_recursive_no_path_blocks` — `Bash("grep -r TODO")` → BLOCK (flag stripped, only 1 non-flag arg remains)

**Risk**: False positives for legitimate no-path Grep/rg. Mitigation: no-path Grep/rg is always repo-wide; exempt contexts are by design minimal and read-limited — requiring an explicit path is the correct tightening, and escape hatch is "don't use exempt path, declare a real skill gate".

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

### R53 F3 — state persistence failures are fail-open under block mode (4 failure points + preflight)

**File**: `.claude/hooks/skill-invoke-check.sh` line 565-655 (state-write block).

**Bug — 5 failure points are all silently bypassable**:
1. `mkdir -p "$STATE_DIR"` (line 566) — no error check; with `set -eo pipefail` on line 1, a failure normally aborts, but `mkdir -p` rarely fails on common filesystems, masking the condition. If it does fail, the subsequent `mktemp` also fails and the shell exits silently (no block emit, no drift_log).
2. `TMP=$(mktemp "$STATE_DIR/.tmp.XXXXXX")` (line 571) — subshell swallows errors on `set -e`; if mktemp fails, `TMP` is empty; Python receives empty `tmp` argv and still writes nothing useful.
3. Python `json.dump` exception (line 645-650) — except block prints stderr warn, `sys.exit(0)`. Explicit fail-open regardless of mode.
4. `mv "$TMP" "$STATE_FILE" 2>/dev/null` (line 652-655) — failure prints warn, removes TMP, continues. Fail-open regardless of mode.
5. **Preflight gap**: if `$STATE_FILE` exists as a directory (e.g. stale mkdir mistake), `mv` will succeed on POSIX by placing TMP INSIDE that directory — so `STATE_FILE` as a dir stays stale and subsequent `json.load(open(sf))` fails (IsADirectoryError) → state permanently unrecoverable.

Net effect: under `enforcement_mode=block`, any of these 5 failure conditions causes state NOT to update → next response sees stale `_initial` or prior stage → L4 transition check evaluated against wrong baseline → silent bypass.

**Fix (approach A — enumerate all 5, mode-aware, survive `set -e`)**:

1. **Preflight (new)** — after line 564 check:
   ```bash
   if [ -e "$STATE_FILE" ] && [ -d "$STATE_FILE" ]; then
     drift_log "state_file_is_directory" false null "$LAST_STAGE"
     if [ "$CONFIG_MODE" = "block" ]; then
       block "state persistence: STATE_FILE 存在但是目录 ($STATE_FILE)；拒绝继续"
     fi
     exit 0
   fi
   ```
2. **`mkdir -p`** — wrap with explicit guard:
   ```bash
   if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
     drift_log "state_mkdir_failed" false null "$LAST_STAGE"
     if [ "$CONFIG_MODE" = "block" ]; then
       block "state persistence: mkdir -p $STATE_DIR 失败"
     fi
     exit 0
   fi
   ```
3. **`mktemp`** — same pattern:
   ```bash
   TMP=$(mktemp "$STATE_DIR/.tmp.XXXXXX" 2>/dev/null) || TMP=""
   if [ -z "$TMP" ]; then
     drift_log "state_mktemp_failed" ...
     block-or-log-and-exit
   fi
   ```
4. **Python heredoc** — change `sys.exit(0)` → `sys.exit(1)` in the `except` (line 650). Bash side captures via `|| PY_EC=$?` form (survives `set -e`):
   ```bash
   python3 - "$STATE_FILE" "$TMP" ... <<'PY' || PY_EC=$?
   ...
   PY
   if [ "${PY_EC:-0}" != "0" ]; then
     drift_log "state_write_failed" ...
     block-or-log-and-exit (cleanup TMP)
   fi
   ```
5. **`mv`** — current line 652-655 already has `if ! mv ...; then` structure; extend:
   ```bash
   if ! mv "$TMP" "$STATE_FILE" 2>/dev/null; then
     rm -f "$TMP" 2>/dev/null || true
     drift_log "state_mv_failed" ...
     if [ "$CONFIG_MODE" = "block" ]; then block "state persistence: mv $TMP → $STATE_FILE 失败"; fi
     exit 0
   fi
   ```

All 5 branches emit a `drift_log` entry (observability preserved in both modes) and dispatch on `$CONFIG_MODE` for block/exit decision.

**Tests** (`tests/hooks/test_skill_invoke_check.py`) — 5 new tests, each injects a DIFFERENT failure mode directly (fixing codex round-1 finding 2):

- `test_state_preflight_state_file_is_directory_blocks` — pre-create STATE_FILE as a dir (`os.makedirs(state_file)`) + block mode → BLOCK with `STATE_FILE 存在但是目录`
- `test_state_mkdir_failed_block_mode_blocks` — set STATE_DIR to a path inside a parent chmod 0555 (so mkdir fails) + block mode → BLOCK
- `test_state_mktemp_failed_block_mode_blocks` — pre-create STATE_DIR as chmod 0555 (so mkdir succeeds no-op, mktemp fails) + block mode → BLOCK
- `test_state_mv_failed_block_mode_blocks` — use monkeypatched STATE_FILE pointing to `/dev/null/foo` (POSIX: `/dev/null` is not a dir → mv fails with ENOTDIR) + block mode → BLOCK. (Alternative if `/dev/null/foo` is flaky in test runner: make STATE_FILE's parent dir not the same filesystem as TMP — but since mktemp uses STATE_DIR, test via a sibling path trick.)
- `test_state_any_failure_drift_mode_passes_with_drift_log` — any one of the above conditions + drift-log mode → exit 0; drift-log file contains the matching `drift_kind`

Python-write exception test: **explicitly deferred** — not reliably injectable without test-only hook hooks. The `PY_EC` guard is still added (belt-and-suspenders), and its behavior is covered by inspection in codex review rather than a runtime test. Documented as acceptable residual.

**Risk**: Observe-mode operators see more drift-log entries for infra conditions. Mitigation intended: these are real anomalies and should be visible.

## Non-goals / Explicit Deferrals

- No new enforcement-mode flip (strict contract: this PR stays observe-only; all 3 fixes pass through existing `CONFIG_MODE` branches).
- No refactor of `_path_is_safe_for_read` signature beyond what F1 requires.
- No consolidation of R49-R52 fixes (they are already merged; do NOT touch).
- No new `skill-invoke-enforced.json` keys.

## Acceptance (non-coder-executable)

Per CLAUDE.md §Repository governance backstop item 2: every module/phase delivery includes a non-coder acceptance checklist.

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| A1 | 用户终端执行 `pytest tests/hooks/test_stop_response_check.py -v` | 所有测试 pass；新增 7 个 F1 测试（4 个 tool-native + 3 个 Bash grep/rg） | 输出里 "passed" 数 ≥ 原有 + 7；failed = 0 |
| A2 | 用户终端执行 `pytest tests/hooks/test_skill_invoke_check.py -v` | 所有测试 pass；新增 4 个 F2 + 5 个 F3 测试 | 输出里 "passed" 数 ≥ 原有 + 9；failed = 0 |
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
