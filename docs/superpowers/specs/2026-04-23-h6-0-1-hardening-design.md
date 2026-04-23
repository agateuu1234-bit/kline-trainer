# H6.0.1 Hardening — Spec (v12, 三拆最终 scope + Glob-ban + shell-glob-metachar-ban)

**Date**: 2026-04-23
**Status**: Design frozen, awaiting codex branch-diff review at Review Gate 2 of 7 (spec-only phase; pre-implementation)
**Planned scope** (to be implemented AFTER plan approval + TDD, NOT present in this branch yet): Fix 1 HIGH residual from H6.0 R53 — **F1** (read-safety bypass via Grep/Glob/Bash grep/rg/jq/ls in exempt contexts) only
**Branch**: `hardening-6.0.1` off `origin/main@893b832` (H6.0 merged)

## ⚠️ Branch state vs PR state (for reviewers)

**This branch is currently at Review Gate 2** (spec review). The branch diff vs `origin/main` intentionally contains ONLY this spec document. Implementation (`.claude/hooks/stop-response-check.sh` + `tests/hooks/test_stop_response_check.py`) is **Gate 5**, which follows:
- Gate 3: Plan written (via `superpowers:writing-plans`)
- Gate 4: Codex adversarial-review on plan
- Gate 5: TDD implementation of hook + tests
- Gate 6: Codex adversarial-review on full branch (post-implementation)
- Gate 7: PR merge

This spec MUST reach `approve` at Gate 2 BEFORE any implementation begins. Acceptance checklist A1/A2 (in "Acceptance" section below) applies at Gate 7 (PR merge review), NOT at this Gate 2 review. Reviewers at Gate 2 are asked to validate the **design** (fix approach, completeness, test plan), not the implementation (which does not yet exist).

H6.0-flip precondition satisfaction requires this branch to reach Gate 7 with the full implementation + Gate 6 approve — the spec-only state at Gate 2 is NOT a satisfied precondition. This ordering is intentional (spec-first catches design flaws before implementation sunk cost, as demonstrated by rounds 1-8 refining F1 before any code was written).

**Sibling PRs (must ALL merge before any H6.x flip)**:
- H6.0.1b — R53 F3 family (state persistence/integrity, 6 guards + reset-trigger + ANY_BLOCK, + R-SID-1 CLAUDE_SESSION_ID continuity, + config-robustness)
- H6.0.1c — R53 F2 family (Skill invoke assistant-message boundary enforcement, transcript-parse refactor)

## Why v7 scope 再收缩 (decision log)

- v1-v5: codex rounds 1-5 expanded F3 scope each round → hardening-5 pattern
- v6 (scope C): pulled F3 out, kept F1+F2 → codex round 6 found F1 leaves `ls` untouched + F2 `skill_idx==0` still allows `[Skill(req), Write]` in one assistant message (flatten-bug)
- v7 (this, scope C'-1): pull F2 out too. F1 alone is a pure read-side hook refactor, single file, no cross-state concerns. Expected: 1-round approve.

Three-way split:
- **H6.0.1 (this PR)**: F1 only. Touches `.claude/hooks/stop-response-check.sh` + its test. Well-bounded.
- **H6.0.1b**: F3 family. Touches `.claude/hooks/skill-invoke-check.sh` state-persistence block + hook init. Its own spec, own review budget, own residuals (R-SID-1, config-robustness).
- **H6.0.1c**: F2 family. Touches `.claude/hooks/skill-invoke-check.sh` transcript-parsing + L2 invoke check. Requires preserving assistant-message boundaries (architectural), its own spec.

All three PRs are H6.0-flip preconditions; H6.0-flip PR body MUST link all three commit SHAs.

## Context

H6.0 (PR #30, squash-merge `893b832`, merged 2026-04-23) landed the skill-pipeline enforcement framework in `drift-log` (observe-only) mode. R53 F1/F2/F3 were accepted as residuals. This PR fixes F1 only; F2 and F3 go to separate PRs for scope containment.

Why residual merge was safe: framework runs observe-only → no response is blocked → no in-the-wild harm. All three residuals MUST land BEFORE any `enforcement_mode: drift-log → block` flip.

## Out of Scope

- R53 F2 (Skill invoke order) — **moved to H6.0.1c**
- R53 F3 family (state persistence/integrity + R-SID-1 + config-robustness) — **moved to H6.0.1b**
- `enforcement_mode` flip (H6.0-flip PR)
- Any per-skill enforcement change (H6.1-H6.10)
- Refactors / cleanup not required by F1
- CLAUDE.md / workflow-rules.json / skill-invoke-enforced.json changes
- `.claude/hooks/skill-invoke-check.sh` changes of any kind

## Residual (in-scope)

### R53 F1 — exempt-context read-safety bypass via Grep/Glob/Bash grep/rg/jq/ls with missing or root-equivalent path

**File**: `.claude/hooks/stop-response-check.sh` only
- `_path_is_safe_for_read` helper (line 88-108)
- Tool-native branches: line 115-121 (read-only-query), 192-197 (behavior-neutral), 212-215 (single-step)
- Bash branches: line 185-191 (behavior-neutral arg loop), 230-236 (single-step arg loop)
- `safe_bash` / `safe_bash_single` whitelist regex: line 150-154, 205-209

**Bug — five equivalent bypass paths**:

(a) **Tool-native Grep without `path`**: path extraction falls back to `pattern` as path, so `Grep(pattern="TODO")` searches cwd recursively while path-safety sees pattern string.

(b) **Tool-native / Bash `path` = repo-root-equivalent** (codex round-2 finding 1): `rg secret .` / `Grep(path="docs/..")` / `ls .` all resolve to repo root but currently pass `_path_is_safe_for_read` (only rejects `~`, glob, out-of-repo, sensitive-component).

(c) **Bash grep/rg flag parsing** (codex round-3 finding 3): `rg -g '*.md' secret` — flag consumes next token; "strip leading -flag" misclassifies operands. Current safe_bash regex already rejects `-` so this is moot at whitelist level; fix ensures exempt arg-path-check matches the whitelist's strictness.

(d) **Bash `ls` not in arg-path-check loop** (codex round-6 finding 2): `ls` IS in safe_bash whitelist (line 153) but the arg loop (line 185-191, 231-236) only covers `cat/head/tail/wc/grep/rg/jq`. `ls .` / `ls .env` / `ls docs/..` pass the whitelist AND skip arg-path-check → bypass for repo-wide enum or sensitive-name probe.

(e) **Glob — entire tool class is the wrong fit for exempt contexts** (codex rounds 8+10 findings, root-cause): Glob's `pattern` is itself a file selector with a rich wildcard language (`*`, `**`, `?`, `[abc]`, `{a,b}`). Every round of "validate Glob pattern" (round 8 = literal-component sensitive-name; round 10 = wildcarded-component sensitive-name like `**/.en[v]`, `**/*.pem`, `id_[rd]sa`) closed one subset of the bypass space and opened another. Glob's whole purpose is "enumerate files matching a pattern" — which is the opposite of the minimum-privilege read-limited posture that exempt contexts are designed for. Fixing this at the pattern-grammar level is a losing game (codex 2 rounds already). **Root-cause fix: exempt contexts should not allow Glob at all** — whoever needs to enumerate files should declare a real skill gate.

**Fix (approach A — unified, minimal, in one file)**:

Tool-native (3 exempt branches):
1. Remove `pattern` fallback from path extraction for Grep (Grep's pattern is content-match, NOT a path).
2. Introduce helper `_extract_read_target(tu)` returning `(tool_name, path_str_or_None)`:
   - `Read` → `(Read, file_path)` (None if absent)
   - `Grep` → `(Grep, path)` (None if absent)
   - `Glob` → `(Glob, None)` — caller will unconditionally BLOCK (see step 5).
3. `_path_is_safe_for_read`: when called with empty/None path for Grep, return
   `BLOCK: {exempt_label} Grep 必须显式传 path 参数（不允许无 path 全仓搜索）`.
4. **Reject repo-root-equivalent paths**: after `rel = resolved.relative_to(repo_root)`, if `str(rel).replace(os.sep, '/')` is `'.'` or empty, return `BLOCK: {exempt_label} 路径归一化到仓库根等于全仓搜索: {s}`. Catches `.`, `./`, `docs/..`, absolute `<repo>` form.
5. **Glob unconditionally blocked in all three exempt branches** (codex rounds 8+10 root-cause fix — supersedes the prior `_glob_pattern_is_safe` helper, which is removed): when a tool_use has `name == "Glob"` in any exempt branch, return
   `BLOCK: {exempt_label} 不允许 Glob 工具（文件枚举不符合 exempt 最小读语义；请用 Read + 具体 path，或声明真实 skill gate）`.
   No path or pattern inspection. No wildcards sub-rule. No literal-vs-glob-char distinction. The entire Glob-related finding class is closed by refusing to route Glob through exempt at all.
6. Update three tool-native call sites to use `_extract_read_target` and the step-5 unconditional Glob block.

Bash (behavior-neutral + single-step branches):
7. Extend the arg-path-check loop to cover **all** whitelisted Bash read tools:
   ```python
   if parts[0] in ('ls', 'cat', 'head', 'tail', 'wc', 'grep', 'rg', 'jq'):
       # per-tool parse
   ```
8. **Universal flag-ban** (codex round-7 finding 1 uniformity fix): for ANY of the 8 whitelisted tools, if any arg in `parts[1:]` matches regex `^-` → `BLOCK: exempt(X) Bash {tool} 不允许任何 flag（避免 flag 吃 operand 导致 operand 误分类，如 head -n 1 .env / ls -I .env）`. Aligns arg-loop strictness with safe_bash regex's existing `-` exclusion; closes the same class as grep/rg flag-consumption.
9. Per-tool operand rules (after flag-ban confirms no `-` args):
   - **`cat` / `head` / `tail` / `wc` / `ls`**: all args are paths; require ≥1 arg; each path → `_path_is_safe_for_read` (rejects empty / root-equiv / sensitive / out-of-repo).
   - **`grep` / `rg`**: require exactly 2 args: pattern (arg[0]) + path (arg[1], path-checked). **Pattern MUST additionally be rejected if it contains any shell-glob metacharacter (`*`, `?`, `[`, `]`, `{`, `}`)** — see step 11. Requires BLOCK: `exempt(X) Bash {grep|rg} pattern 含 shell glob 元字符（shell 会在命令执行前展开成文件列表，绕过 path 检查）: {pattern}`.
   - **`jq`**: require ≥2 args: the first is the filter (arg[0]) + at least one path (arg[1:], path-checked). **Filter MUST additionally be rejected if it contains any shell-glob metacharacter** — same reason and same rule as grep/rg. Cost: jq array-iteration syntax `.foo[]` becomes unavailable in exempt context; users needing it declare a real skill gate.
10. Note: `safe_bash` regex at line 153 / 208 already excludes `-` in arg chars (whitelist-level flag-block). Step 8's arg-loop flag-ban is **defense-in-depth** — aligns the two layers so any future relaxation of safe_bash must also update step 8, and ensures the arg-loop never sees a flag to misclassify.
11. **Shell-glob metacharacter ban in unchecked operands** (codex Gate-4 round-1 finding): for `grep`/`rg`/`jq`, the first non-flag arg is a pattern/filter (not a path), so `_path_is_safe_for_read` does not see it. But bash performs glob expansion BEFORE invoking the tool, so `rg * docs/` expands `*` to every repo-root entry — rg then sees `rg a b .env ... docs/` and searches all expanded names, bypassing the path check. Fix: reject any pattern/filter arg matching `re.search(r'[*?\[\]{}]', arg)`. The SAME set of chars `_path_is_safe_for_read` already rejects on path args at line 96; Step 11 applies identical rule to pattern/filter slot.

12. **Path-operand glob-metachar defense is pre-existing, not a new rule** (codex Gate-4 round-5 clarification): for **path** operands (e.g. `cat docs/*`, `ls docs/*.md`, `wc docs/[ab].txt`), `_path_is_safe_for_read` already rejects glob metacharacters at line 96-97 via `if any(c in s for c in '*?[]{}'): return f"BLOCK: {exempt_label} 路径含 glob: {s}"`. This H6.0.1 PR does NOT change that rule — the fix inherits it for all newly-routed Bash path operands (cat/head/tail/wc/ls full args + grep/rg arg[1] + jq arg[1:]). Defense-in-depth tests added to prove the combined flow (Bash arg-loop → `_path_is_safe_for_read`) blocks shell-expanded path operands end-to-end.

**Tests** (`tests/hooks/test_stop_response_check.py`) — 31 new tests (one authoritative inventory; numbers below must match plan A1/A4 exactly):

Tool-native Grep (4; Gate-4 round-4 finding: patterns use non-sensitive `TODO` so tests validate the "path required" rule rather than incidentally matching sensitive-name fallback; behavior-neutral no-path case added):
- `test_read_only_grep_without_path_blocks` — `Grep(pattern="TODO")` no path → BLOCK
- `test_behavior_neutral_grep_without_path_blocks` — `Grep(pattern="TODO")` in behavior-neutral → BLOCK
- `test_read_only_grep_with_safe_path_passes` — `Grep(pattern="TODO", path="docs/")` → PASS
- `test_single_step_grep_without_path_blocks` — `Grep(pattern="TODO")` in single-step → BLOCK

Tool-native Glob unconditional block (3 — codex rounds 8+10 root-cause fix):
- `test_read_only_glob_always_blocks` — any `Glob(pattern="*", path="docs/")` (or any args) → BLOCK
- `test_behavior_neutral_glob_always_blocks` — same → BLOCK
- `test_single_step_glob_always_blocks` — same → BLOCK

Bash grep/rg (3):
- `test_behavior_neutral_bash_rg_without_path_blocks` — `Bash("rg secret")` → BLOCK
- `test_behavior_neutral_bash_rg_with_path_passes` — `Bash("rg secret docs/")` → PASS
- `test_single_step_bash_grep_recursive_no_path_blocks` — `Bash("grep -r TODO")` → BLOCK

Repo-root-equivalent rejection (3):
- `test_read_only_grep_dot_path_blocks` — `Grep(pattern="secret", path=".")` → BLOCK
- `test_behavior_neutral_bash_rg_dot_blocks` — `Bash("rg secret .")` → BLOCK
- `test_single_step_grep_normalized_root_dotdot_blocks` — `Grep(pattern="secret", path="docs/..")` → BLOCK

Flag-ban on grep/rg (2):
- `test_behavior_neutral_bash_rg_with_flag_blocks` — `Bash("rg -g '*.md' secret docs/")` → BLOCK
- `test_single_step_bash_grep_with_f_flag_blocks` — `Bash("grep -f patterns.txt secret docs/")` → BLOCK

jq regression coverage (3):
- `test_behavior_neutral_bash_jq_filter_only_blocks` — `Bash("jq .")` → BLOCK (no file)
- `test_behavior_neutral_bash_jq_filter_and_file_passes` — `Bash("jq . docs/foo.json")` → PASS
- `test_behavior_neutral_bash_jq_filter_and_sensitive_file_blocks` — `Bash("jq . .env")` → BLOCK

**ls coverage** (3 — codex round-6 finding 2):
- `test_read_only_bash_ls_dot_blocks` — `Bash("ls .")` → BLOCK (repo-root)
- `test_behavior_neutral_bash_ls_dotenv_blocks` — `Bash("ls .env")` → BLOCK (sensitive-name)
- `test_single_step_bash_ls_safe_path_passes` — `Bash("ls docs/")` → PASS

**Universal flag-ban on all Bash read tools** (3 — codex round-7 finding 1):
- `test_behavior_neutral_bash_head_with_n_flag_blocks` — `Bash("head -n 1 .env")` → BLOCK (flag-ban; covers option-consuming attack on head)
- `test_single_step_bash_ls_with_I_flag_blocks` — `Bash("ls -I .env")` → BLOCK
- `test_behavior_neutral_bash_wc_with_l_flag_blocks` — `Bash("wc -l .env")` → BLOCK

**Shell-glob metachar ban in grep/rg pattern and jq filter** (3 — codex Gate-4 round-1 finding):
- `test_behavior_neutral_bash_rg_star_pattern_blocks` — `Bash("rg * docs/")` → BLOCK (bare `*` expands in shell before rg runs)
- `test_single_step_bash_grep_starpem_pattern_blocks` — `Bash("grep *.pem docs/")` → BLOCK (`*.pem` expands to sensitive files)
- `test_behavior_neutral_bash_jq_star_filter_blocks` — `Bash("jq * docs/foo.json")` → BLOCK (filter slot same class)

**Shell-glob metachar on path operands — defense-in-depth** (3 — codex Gate-4 round-5 clarification; `_path_is_safe_for_read` already rejects glob chars since pre-H6.0.1, these tests prove Bash arg-loop routes path args through helper correctly):
- `test_behavior_neutral_bash_cat_glob_path_blocks` — `Bash("cat docs/*")` → BLOCK (`*` in path arg hits helper's pre-existing glob-char reject)
- `test_single_step_bash_ls_glob_path_blocks` — `Bash("ls docs/*.md")` → BLOCK
- `test_behavior_neutral_bash_wc_bracket_path_blocks` — `Bash("wc docs/[ab].txt")` → BLOCK (`[...]` char class)

**Static source assertion — flag-ban arg-loop presence** (1 — codex Gate-4 round-6 finding): existing safe_bash whitelist rejects `-` before the arg-loop runs, so runtime flag-ban tests block via whitelist not arg-loop. A static assertion independent of whitelist confirms arg-loop flag-ban code exists in both exempt branches (defense-in-depth invariant: if whitelist is future-relaxed, arg-loop still blocks):
- `test_r53f1_flag_ban_code_present_in_both_branches` — grep hook source for "不允许任何 flag"; count ≥ 2 (one per exempt branch)

<!-- Prior v9 "Glob pattern validation" (dotdot / absolute / sensitive-literal / safe-pass) tests REMOVED in v11 — replaced by the 3 Glob-always-blocks tests above. Rationale: v9 rule validated the pattern grammar; v10 codex still exposed wildcarded-sensitive-name bypasses (`**/.en[v]`, `**/*.pem`, `id_[rd]sa`). Exiting the grammar-validation arms race by unconditionally blocking Glob in exempt contexts. -->


**Risk**: False positives for legitimate whole-repo read. Mitigation: exempt contexts are by design minimal; whole-repo reads should declare a real skill gate instead. Escape hatch exists.

---

## Non-goals / Explicit Deferrals

- R53 F2 / R53 F3 / R-SID-1 / config-robustness → **moved to sibling PRs H6.0.1c / H6.0.1b**
- No refactor of `_path_is_safe_for_read` signature beyond what F1 requires
- No consolidation of R49-R52 fixes (already merged)
- No new `skill-invoke-enforced.json` keys
- No changes to `.claude/hooks/skill-invoke-check.sh`

## Sibling PR contract

H6.0.1b and H6.0.1c are separate PRs with their own specs, plans, and codex reviews. **All three (H6.0.1 + H6.0.1b + H6.0.1c) must land before any H6.x flip**. H6.0-flip PR body MUST link all three commit SHAs as preconditions; H6.0-flip codex review MUST verify all three are landed. This PR (H6.0.1) is orthogonal to b and c — F1 is pure read-safety, no dependency on state-integrity or invoke-order fixes.

## Acceptance (non-coder-executable, applies at Gate 7 / PR merge; NOT at Gate 2 spec review)

The following 4 acceptance criteria are evaluated by the user at the final PR-merge review (Review Gate 7). They assume Gate 5 (TDD implementation) has already landed the hook + test changes. At Gate 2 (spec review, this branch's current state), these criteria are NOT applicable — at Gate 2 the branch contains only the spec document and A1/A2 would fail by construction.

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| A1 | 用户终端执行 `pytest tests/hooks/test_stop_response_check.py -v` (**after Gate 5 implementation**) | 所有测试 pass；新增 31 个 F1 测试（4 Grep tool-native + 3 Glob-always-block + 3 Bash grep/rg + 3 repo-root-equivalent + 2 flag-ban grep/rg + 3 jq + 3 ls + 3 其他 flag-ban + 3 shell-glob-metachar-ban pattern/filter + 3 path-defense-in-depth + 1 static source assertion） | 输出里 "passed" 数 ≥ 原有 + 31；failed = 0 |
| A2 | 用户肉眼审 diff：`git diff origin/main -- .claude/hooks/ tests/hooks/` (**after Gate 5 implementation**) | 只改 `.claude/hooks/stop-response-check.sh` + `tests/hooks/test_stop_response_check.py` 两个文件（外加本 spec 文档 `docs/superpowers/specs/2026-04-23-h6-0-1-hardening-design.md` 以及 Gate 3 产出的 plan 文档 `docs/superpowers/plans/2026-04-23-h6-0-1-hardening-plan.md`）；`.claude/hooks/skill-invoke-check.sh` / `skill-invoke-enforced.json` / `workflow-rules.json` / `CLAUDE.md` 必须 0 改动 | diff 只覆盖 4 个文件（2 code + 2 doc） |
| A3 | 用户读 spec 确认 scope | scope 只含 R53 F1；F2 / F3 明确标注归 H6.0.1c / H6.0.1b | 用户口头确认 |
| A4 | 用户 terminal 跑 `bash .claude/scripts/codex-attest.sh --scope branch-diff --head hardening-6.0.1 --base origin/main` (**Gate 6 codex review**) | codex 回 `Verdict: approve`（ledger 记录） | 脚本 exit 0，ledger 更新 |

**禁词**：此 checklist 不出现 "should work" / "looks good" / "probably fine"；所有判定有可观测命令。

## Review Gates

1. Spec self-review (inline, done)
2. Codex adversarial-review on spec (branch-diff, round 7+) → must `approve`
3. Plan written (via `superpowers:writing-plans`)
4. Codex adversarial-review on plan (branch-diff) → `approve`
5. Implementation (TDD via `superpowers:test-driven-development`)
6. Codex adversarial-review on branch (branch-diff) → `approve`
7. PR → user merges after acceptance A1-A4 pass

## Codex budget contract

Rounds 1-6 of v1-v6 spec review exhausted the original budget. Budget reset under v7 scope (F1-only):
- Spec round 7 (post-three-way-split) SHOULD approve in 1-2 rounds — F1 design is stable and well-bounded, single file.
- Plan gate: ≤ 2 rounds
- Branch-diff gate (post-implementation): ≤ 2 rounds
- Total remaining H6.0.1 codex budget ≤ 5 rounds
- Round ≥ 3 on any single gate → user escalate (stricter than the rounds-1-6 drift)
