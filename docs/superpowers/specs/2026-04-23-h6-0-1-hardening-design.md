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
4. **Reject repo-root-equivalent paths** (codex round-2 finding 1): after `rel = resolved.relative_to(repo_root)`, if `str(rel).replace(os.sep, '/')` is `'.'` or empty, return `BLOCK: {exempt_label} 路径归一化到仓库根等于全仓搜索: {s}`. Catches `.`, `./`, `docs/..`, `<repo>` absolute, etc.
5. Update three tool-native call sites.

Bash fixes (behavior-neutral + single-step branches):
6. For `grep` / `rg` (identified by `parts[0]`):
   - **Ban all flags in exempt context** (codex round-3 finding 3): if ANY arg (including middle/trailing) matches regex `^-` → `BLOCK: exempt(X) Bash {grep|rg} 不允许任何 flag（避免 -g/-f/--include 这类 flag 吃 operand 导致 operand 误分类）`. Supersedes the earlier "strip leading -flag" design — flag-aware parsing is out of scope; banning flags is the correct simplification.
   - After flag-ban confirms no flag, require exactly 2 positional args: `pattern` (arg[0]) + `path` (arg[1]). <2 or >2 → `BLOCK: exempt(X) Bash {grep|rg} 必须恰好 "<pattern> <path>" 形式`.
   - Pattern (arg[0]) is NOT path-safety-checked. Path (arg[1]) goes through `_path_is_safe_for_read`, which (per step 4) also rejects repo-root-equivalent paths (`.` / `docs/..`).
7. `cat` / `head` / `tail` / `wc` keep existing rule (all non-flag args are paths; require ≥1).
8. **`jq` special parse** (codex round-4 finding 3, regression avoidance): `jq` filters like `.`, `.items[]`, `keys` are NOT paths — the earlier rule misclassified them and the new repo-root-equivalent-reject would false-block `jq .`. Fix: for `parts[0] == "jq"`, the FIRST non-flag arg is the filter (do NOT path-check it); subsequent args are paths (path-checked normally). If zero non-flag args → BLOCK `exempt(X) Bash jq 必须至少传 filter`. This keeps `jq . file.json` passing while `jq . /etc/passwd` still blocks on the path arg.

**Tests** (`tests/hooks/test_stop_response_check.py`) — 10 new tests:

Tool-native (4):
- `test_read_only_grep_without_path_blocks` — `Grep(pattern=".env")` no path → BLOCK
- `test_read_only_grep_with_safe_path_passes` — `Grep(pattern=".env", path="docs/")` → PASS
- `test_behavior_neutral_glob_without_path_blocks` — same in behavior-neutral → BLOCK
- `test_single_step_grep_without_path_blocks` — same in single-step → BLOCK

Bash (3):
- `test_behavior_neutral_bash_rg_without_path_blocks` — `Bash("rg secret")` → BLOCK
- `test_behavior_neutral_bash_rg_with_path_passes` — `Bash("rg secret docs/")` → PASS
- `test_single_step_bash_grep_recursive_no_path_blocks` — `Bash("grep -r TODO")` → BLOCK (flag stripped, only 1 non-flag arg remains)

Repo-root-equivalent rejection (3 — codex round-2 finding 1):
- `test_read_only_grep_dot_path_blocks` — `Grep(pattern="secret", path=".")` → BLOCK
- `test_behavior_neutral_bash_rg_dot_blocks` — `Bash("rg secret .")` → BLOCK
- `test_single_step_grep_normalized_root_blocks` — `Grep(pattern="secret", path="docs/..")` → BLOCK

Flag-ban (2 — codex round-3 finding 3):
- `test_behavior_neutral_bash_rg_with_flag_blocks` — `Bash("rg -g '*.md' secret docs/")` → BLOCK (flag present, operand-consuming attack)
- `test_single_step_bash_grep_with_f_flag_blocks` — `Bash("grep -f patterns.txt secret docs/")` → BLOCK

Note: earlier `test_single_step_bash_grep_recursive_no_path_blocks` (grep -r TODO) now blocks via flag-ban (−r is a flag); still passes, semantics simpler.

jq regression coverage (2 — codex round-4 finding 3):
- `test_behavior_neutral_bash_jq_filter_only_blocks` — `Bash("jq .")` no file → BLOCK (filter OK but no file to read = malformed invocation in exempt context)
- `test_behavior_neutral_bash_jq_filter_and_file_passes` — `Bash("jq . docs/foo.json")` → PASS (filter `.` not path-checked; file path goes through safety check)
- `test_behavior_neutral_bash_jq_filter_and_sensitive_file_blocks` — `Bash("jq . .env")` → BLOCK (filter OK; path hits sensitive-name)

**Risk**: False positives for legitimate no-path Grep/rg. Mitigation: no-path Grep/rg is always repo-wide; exempt contexts are by design minimal and read-limited — requiring an explicit path is the correct tightening, and escape hatch is "don't use exempt path, declare a real skill gate".

---

### R53 F2 — Skill invoke with no order constraint allows lagging invoke to satisfy L2

**File**: `.claude/hooks/skill-invoke-check.sh` line 495-530 (L2 invoke match).

**Bug**: Current L2 only checks "does `tool_uses` contain a Skill invoke matching the declared gate name". Attacker can emit `[Write(dangerous), Bash(exfil), Skill(superpowers:brainstorming)]` and satisfy L2. In observe mode nothing blocks; in block mode this is a real bypass.

**Fix (approach A — STRICT first-index, per codex round-2 finding 3)**:
1. After finding the matching Skill invoke, compute `skill_idx` = index of the first matching `Skill` tool_use (input.skill == SKILL_NAME) in `tool_uses`.
2. If `skill_idx != 0` → emit `drift_log "invoke_order_violation" true null "$LAST_STAGE"` and in block mode `block "Skill invoke '$SKILL_NAME' 必须是 tool_uses[0]；实际在 index $skill_idx"`.
3. Order check is additive to existing `gate_declared_no_invoke`: runs only when a matching Skill IS found. Absent-invoke path unchanged.
4. **Rationale for strict `== 0` vs "before first non-Skill"**: round-1 spec used "before first non-Skill" but that allows `[Skill(other), Skill(required), Write]` to pass — an unrelated skill can still shape the turn before the gated rubric loads. Strict `== 0` matches the spec's own block message contract ("必须在任何其他 tool_use 之前"). Cost: any response that invokes a non-matching Skill before the gated Skill now drift-logs/blocks. Acceptable — if there's a legitimate case (none known), whitelist as exempt_rule in follow-up PR.

**Tests** (`tests/hooks/test_skill_invoke_check.py`) — 6 new tests:
- `test_l2_skill_first_passes` — `[Skill(required), Write]` → PASS (observe and block)
- `test_l2_write_before_skill_drift_logs` — `[Write, Skill(required)]` drift-log → entry `invoke_order_violation`, exit 0
- `test_l2_write_before_skill_blocks` — `[Write, Skill(required)]` block mode → BLOCK
- `test_l2_only_skill_passes` — `[Skill(required)]` → PASS
- `test_l2_other_skill_before_required_drift_logs` — `[Skill(other), Skill(required), Write]` drift-log → `invoke_order_violation`, exit 0 (**round-2 finding 3**)
- `test_l2_other_skill_before_required_blocks` — same sequence block mode → BLOCK (**round-2 finding 3**)

**Risk**: Responses that legitimately use meta-tools (`TaskCreate` / `ToolSearch`) or preparatory Skills before the gated Skill. Decision: accept this strictness; invoke the gated Skill FIRST, then use other tools. If a legitimate case emerges, narrow via a follow-up exempt_rule — NOT in this PR.

---

### R53 F3 — state persistence / integrity failures are fail-open under any-block rollout (5 failure points + preflight + read-side + reset-trigger; keyed to ANY_BLOCK not per-skill mode)

**File**: `.claude/hooks/skill-invoke-check.sh` line 291-293 (state read), 565-655 (state-write block), 668-680 (reset-trigger write).

**Why ANY_BLOCK instead of per-skill CONFIG_MODE** (codex round-3 finding 1): state is shared across skills. If skill A is observe and skill B is block, a state-write failure under skill A leaves stale `last_stage` which skill B's L4 transition check then consumes → bypass. Per-skill `CONFIG_MODE` is wrong for shared state. Correct gate: `ANY_BLOCK = (jq any skill.enforcement_mode == "block")`. When ANY_BLOCK → state failures fail-close globally. When all observe (current H6.0.1 state) → state failures drift-log + continue (existing observe semantics preserved until first flip). Precondition: any H6.x flip PR must re-verify `ANY_BLOCK` evaluates correctly.

**Bug — 6 failure points are all silently bypassable**:

0. **Read side** (line 291-293, codex round-3 finding 2): `LAST_STAGE=$(jq -r '.last_stage // "_initial"' "$STATE_FILE" 2>/dev/null || echo "_initial")`. Malformed JSON / missing `last_stage` field / truncated file → silently defaults to `_initial`. Any subsequent L4 transition check under block-mode skill evaluates against wrong baseline → bypass.

1. `mkdir -p "$STATE_DIR"` (line 566) — no error check; with `set -eo pipefail` on line 1, a failure normally aborts, but `mkdir -p` rarely fails on common filesystems, masking the condition. If it does fail, the subsequent `mktemp` also fails and the shell exits silently (no block emit, no drift_log).
2. `TMP=$(mktemp "$STATE_DIR/.tmp.XXXXXX")` (line 571) — subshell swallows errors on `set -e`; if mktemp fails, `TMP` is empty; Python receives empty `tmp` argv and still writes nothing useful.
3. Python `json.dump` exception (line 645-650) — except block prints stderr warn, `sys.exit(0)`. Explicit fail-open regardless of mode.
4. `mv "$TMP" "$STATE_FILE" 2>/dev/null` (line 652-655) — failure prints warn, removes TMP, continues. Fail-open regardless of mode.
5. **Preflight gap**: if `$STATE_FILE` exists as a directory (e.g. stale mkdir mistake), `mv` will succeed on POSIX by placing TMP INSIDE that directory — so `STATE_FILE` as a dir stays stale and subsequent `json.load(open(sf))` fails (IsADirectoryError) → state permanently unrecoverable.

Net effect: under `enforcement_mode=block`, any of these 5 failure conditions causes state NOT to update → next response sees stale `_initial` or prior stage → L4 transition check evaluated against wrong baseline → silent bypass.

**Fix (approach A — 6 guard points; all keyed to ANY_BLOCK not per-skill CONFIG_MODE; survive `set -e`)**:

**Compute ANY_BLOCK at hook init** (once per invocation, near line 193 where `ENF_MODE` is read):
```bash
# Schema verified against .claude/config/skill-invoke-enforced.json (codex round-4 finding 1 fix):
# actual path is .enforce[<skill>].mode, NOT .skills[<skill>].enforcement_mode
ANY_BLOCK=$(jq -r '[.enforce | to_entries[] | select(.value.mode == "block")] | length' "$CONFIG" 2>/dev/null || echo "0")
# ANY_BLOCK == "0" means pure-observe (H6.0.1 baseline); >0 means mixed rollout began
```
Helper `state_fail()` (bash function defined once, used by all 6 branches):
```bash
state_fail() {
  # $1 = drift_kind; $2 = block message
  drift_log "$1" false null "$LAST_STAGE"
  if [ "${ANY_BLOCK:-0}" != "0" ]; then
    block "$2"
  fi
  exit 0
}
```

1. **Read-side validation (new, codex round-3 finding 2)** — replace the bare `jq -r ...` at line 291-293 with:
   ```bash
   if [ -e "$STATE_FILE" ]; then
     # Validate JSON + required last_stage field
     LAST_STAGE=$(jq -r '.last_stage // empty' "$STATE_FILE" 2>/dev/null)
     if [ -z "$LAST_STAGE" ]; then
       # Malformed JSON, missing field, or unreadable
       state_fail "state_corrupt" "state persistence: STATE_FILE 损坏或 last_stage 字段缺失 ($STATE_FILE)"
     fi
   else
     LAST_STAGE="_initial"
   fi
   ```
   Note: pure-observe (ANY_BLOCK=0) + corrupt state → `state_fail` calls `drift_log` + exit 0 without block. LAST_STAGE ends up empty/unset for this response only; subsequent L4 check short-circuits on unset (no bypass because no block mode exists to bypass).
2. **Preflight dir-check (line 565 context)**:
   ```bash
   if [ -e "$STATE_FILE" ] && [ -d "$STATE_FILE" ]; then
     state_fail "state_file_is_directory" "state persistence: STATE_FILE 存在但是目录 ($STATE_FILE)"
   fi
   ```
3. **`mkdir -p`**:
   ```bash
   mkdir -p "$STATE_DIR" 2>/dev/null || state_fail "state_mkdir_failed" "state persistence: mkdir -p $STATE_DIR 失败"
   ```
4. **`mktemp`**:
   ```bash
   TMP=$(mktemp "$STATE_DIR/.tmp.XXXXXX" 2>/dev/null) || TMP=""
   [ -z "$TMP" ] && state_fail "state_mktemp_failed" "state persistence: mktemp in $STATE_DIR 失败"
   ```
5. **Python heredoc** — change `sys.exit(0)` → `sys.exit(1)` in except (line 650). Bash captures via `PY_EC=0; python3 - ... || PY_EC=$?`:
   ```bash
   PY_EC=0
   python3 - "$STATE_FILE" "$TMP" ... <<'PY' || PY_EC=$?
   ... (sys.exit(1) on except now)
   PY
   if [ "$PY_EC" != "0" ]; then
     rm -f "$TMP" 2>/dev/null || true
     state_fail "state_write_failed" "state persistence: json.dump 失败 (PY_EC=$PY_EC)"
   fi
   ```
6. **`mv`**:
   ```bash
   if ! mv "$TMP" "$STATE_FILE" 2>/dev/null; then
     rm -f "$TMP" 2>/dev/null || true
     state_fail "state_mv_failed" "state persistence: mv $TMP → $STATE_FILE 失败"
   fi
   ```

All 6 branches emit `drift_log` (observability preserved in both modes) and dispatch on `$ANY_BLOCK` for block/exit decision. Per-skill `CONFIG_MODE` is still used for L1/L2/L4 check decisions; only state-persistence/integrity is promoted to `ANY_BLOCK`.

7. **Reset-trigger state rewrite** (line 668-680, codex round-2 finding 2) — SECOND state-write path exists for reset triggers (`git worktree add` / branch-finish + PR-create/merge). Current code uses `json.dump(d, open(sf, 'w'), indent=2)` wrapped in `except Exception: pass` — same fail-open pattern.

   Fix: extract a bash helper `_write_state_atomic()` taking `STATE_FILE`, `STATE_DIR`, and a Python snippet (via argv) that produces the JSON. Reuse for both the main state-write and the reset-trigger state-write. Helper uses all 6 guards above (preflight / mkdir / mktemp / py_ec / mv / post-mv verify). Scope note: extracting the helper is the minimum refactor to avoid duplicating guard logic — NOT a speculative abstraction.

   Failure-mode coverage: reset-trigger path inherits all 6 failure modes via the helper. No new drift_kind names needed.

**Tests** (`tests/hooks/test_skill_invoke_check.py`) — 8 new tests (all keyed to ANY_BLOCK toggled via the test's skill-invoke-enforced.json fixture):

Persistence failures (each injects its own failure mode; all run under ANY_BLOCK=1 fixture):
- `test_state_preflight_state_file_is_directory_any_block_blocks` — pre-create STATE_FILE as dir → BLOCK
- `test_state_mkdir_failed_any_block_blocks` — STATE_DIR parent chmod 0555 → BLOCK
- `test_state_mktemp_failed_any_block_blocks` — STATE_DIR pre-exists chmod 0555 → BLOCK
- `test_state_mv_failed_any_block_blocks` — STATE_FILE at `/dev/null/foo` (ENOTDIR) → BLOCK
- `test_state_reset_trigger_mv_fail_any_block_blocks` (round-2 finding 2) — flow with `git worktree add` tool_use + force mv fail on reset-trigger path → BLOCK

Read-side validation (codex round-3 finding 2):
- `test_state_corrupt_json_any_block_blocks` — pre-seed STATE_FILE with malformed JSON (e.g. `{`) + ANY_BLOCK=1 → BLOCK with drift_kind `state_corrupt`
- `test_state_missing_last_stage_any_block_blocks` — pre-seed STATE_FILE with valid JSON but no `last_stage` key → BLOCK

Pure-observe differentiation (codex round-3 finding 1):
- `test_state_any_failure_pure_observe_passes_with_drift_log` — ANY_BLOCK=0 fixture + ANY of the above conditions → exit 0; drift-log file contains matching drift_kind. Verifies that pure-observe rollout preserves current observe semantics.

ANY_BLOCK schema validation (codex round-4 finding 1):
- `test_state_fail_under_real_config_with_one_skill_flipped_blocks` — fixture sets one skill's `.enforce.<skill>.mode` to `"block"` in skill-invoke-enforced.json (real schema path, not the old wrong `.skills[].enforcement_mode`) + force any state failure → BLOCK. Validates that the jq query introspects the REAL schema; catches the exact bug codex round-4 finding 1 pointed out.

Python-write exception (`json.dump` raise) test: **explicitly deferred** — not reliably injectable without test-only hook seams. The `PY_EC` guard is still added (belt-and-suspenders), and its behavior is covered by codex-inspection rather than runtime test. Documented as acceptable residual for H6.0.1.

**Risk**: Observe-mode operators see more drift-log entries for infra conditions. Mitigation intended: these are real anomalies and should be visible.

## Non-goals / Explicit Deferrals

- No new enforcement-mode flip (strict contract: this PR stays observe-only; state-persistence fixes use `ANY_BLOCK` detection but config itself remains all-observe).
- No refactor of `_path_is_safe_for_read` signature beyond what F1 requires.
- No consolidation of R49-R52 fixes (they are already merged; do NOT touch).
- No new `skill-invoke-enforced.json` keys.

## Accepted residuals (deferred to H6.0-flip PR, NOT this PR)

### R-SID-1: CLAUDE_SESSION_ID continuity gap (codex round-4 finding 2)

**Finding**: `.claude/hooks/skill-invoke-check.sh` line 279-288 falls back to a per-invocation SID hash when `CLAUDE_SESSION_ID` env var is absent. Fallback produces a different state file path per invocation → effectively resets state. In mixed-rollout (ANY_BLOCK>0), an observe turn with missing SID loses stage history; a subsequent block turn sees `_initial` baseline → L4 transition bypass.

**Why deferred to H6.0-flip (not H6.0.1)**:
1. **Different failure mode**: R53 F3 residual is about state **content** integrity (write/read corruption). SID gap is state **identity** (wrong file read entirely). Different mechanism, different fix surface (hook init SID resolution, not the state-write block).
2. **Current H6.0.1 state**: `ANY_BLOCK=0` (all observe). Even if SID is unstable today, no block-mode skill exists to consume stale state → no in-the-wild bypass.
3. **Scope contract**: R53 residual memory and H6.0 merge-acceptance agreed "3 HIGH residual" = F1/F2/F3. SID continuity was NOT in that scope. Inflating H6.0.1 to 4 residuals violates the scope freeze that made H6.0 mergeable.

**Hard precondition bound to H6.0-flip PR** (new gate):
- H6.0-flip PR (first `mode: "block"` flip for any skill) MUST land CLAUDE_SESSION_ID fail-close logic before the flip commits. Specifically: if CLAUDE_SESSION_ID is absent and ANY_BLOCK would be ≥1 after the proposed flip, hook init emits block JSON (`session_id_absent_l4_fail_closed` drift_kind already exists per line 283 — extend to block).
- H6.0-flip PR body MUST link this spec's `R-SID-1` section as the gate origin.
- Acceptance A5 extended: H6.0-flip codex review MUST verify SID-continuity fix is landed.

This residual is **acceptable to merge H6.0.1** because: ANY_BLOCK currently = 0 (no block-mode skill exists), so the SID gap has no exploitable consequence. It becomes exploitable only when the first skill is flipped, and that flip PR is gated on fixing R-SID-1 first.

## Acceptance (non-coder-executable)

Per CLAUDE.md §Repository governance backstop item 2: every module/phase delivery includes a non-coder acceptance checklist.

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| A1 | 用户终端执行 `pytest tests/hooks/test_stop_response_check.py -v` | 所有测试 pass；新增 15 个 F1 测试（4 tool-native + 3 Bash + 3 repo-root-equivalent + 2 flag-ban + 3 jq regression） | 输出里 "passed" 数 ≥ 原有 + 15；failed = 0 |
| A2 | 用户终端执行 `pytest tests/hooks/test_skill_invoke_check.py -v` | 所有测试 pass；新增 6 个 F2 + 9 个 F3 测试（含 read-side + ANY_BLOCK + real-schema + reset-trigger） | 输出里 "passed" 数 ≥ 原有 + 15；failed = 0 |
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
