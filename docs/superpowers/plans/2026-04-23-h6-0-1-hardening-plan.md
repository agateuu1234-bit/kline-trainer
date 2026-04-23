# H6.0.1 Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix R53 F1 — close 6 read-safety bypass classes in exempt contexts (Grep no-path, repo-root-equivalent paths, Bash grep/rg flag-consumption, Bash `ls` missing from arg-path-check, Glob unconditional-block, shell-glob-metachar expansion in pattern/filter operands).

**Architecture:** Single-file refactor to `.claude/hooks/stop-response-check.sh`. Changes span two helpers (`_path_is_safe_for_read` + new `_extract_read_target`) and three exempt branches (`read-only-query`, `behavior-neutral`, `single-step-no-semantic-change`). No changes to `skill-invoke-check.sh`, `skill-invoke-enforced.json`, `workflow-rules.json`, or `CLAUDE.md`. Glob is unconditionally blocked in exempt (root-cause fix — abandons glob-pattern-grammar arms race).

**Tech Stack:** Bash hook with embedded Python3 block; pytest with subprocess-based integration tests; conftest fixtures for temp git repo + enforcement-mode toggle.

**Branch:** `hardening-6.0.1` in worktree `.worktrees/hardening-6.0.1/` (off `origin/main@893b832`).

**Spec:** `docs/superpowers/specs/2026-04-23-h6-0-1-hardening-design.md` (v11, codex-attested Gate 2 approve at `branch:hardening-6.0.1@f39bb964`).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `.claude/hooks/stop-response-check.sh` | Modify lines 88-108, 110-145, 147-200, 202-250 | Two helpers (`_path_is_safe_for_read` / new `_extract_read_target`) + three exempt branches' Tool-native + Bash logic |
| `tests/hooks/test_stop_response_check.py` | Add new `TestR53F1RepoRootRejectInHelper` + `TestR53F1GrepGlob` + `TestR53F1BashArgs` test classes | **32 new tests** covering all 6 bypass classes (1 Task 1 + 8 Task 2 + 23 Task 3; see per-class breakdown in each Task + A4/A4b audit commands) |

No other files touched. Acceptance A2 requires `git diff origin/main -- .claude/hooks/ tests/hooks/` to show exactly these two files (plus `docs/superpowers/specs/` + `docs/superpowers/plans/` already on branch).

---

## Task 1: `_path_is_safe_for_read` repo-root-equivalent rejection

**Files:**
- Modify: `.claude/hooks/stop-response-check.sh:104-107`
- Test: `tests/hooks/test_stop_response_check.py` (add to existing `TestL3ExemptIntegrityReadOnly` class or new test class `TestR53F1FixRepoRootReject`)

### Step 1: Write the failing test

Add this test to `tests/hooks/test_stop_response_check.py` after `test_read_only_cat_repo_relative_passes` (around line 470):

```python
class TestR53F1RepoRootRejectInHelper:
    """R53 F1 fix: _path_is_safe_for_read rejects paths that normalize to repo root."""

    @pytest.fixture(autouse=True)
    def _block_mode(self):
        bak = _set_enforcement_mode("block")
        yield
        _restore_enforcement_mode(bak)

    def test_read_only_grep_dot_path_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "secret", "path": "."}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1"
pytest tests/hooks/test_stop_response_check.py::TestR53F1RepoRootRejectInHelper::test_read_only_grep_dot_path_blocks -v
```

Expected: FAIL. Current `_path_is_safe_for_read` does not reject path=".". The test asserts block-decision but the hook currently returns no block.

- [ ] **Step 3: Add repo-root-equivalent rejection to helper**

Edit `.claude/hooks/stop-response-check.sh` lines 104-108. Change from:

```python
    rel_str = str(rel).replace(os.sep, '/')
    for component in rel_str.split('/'):
        if _SENSITIVE_NAME_RE.search(component):
            return f"BLOCK: {exempt_label} 路径含敏感名: {rel_str}"
    return None
```

To:

```python
    rel_str = str(rel).replace(os.sep, '/')
    # R53 F1 fix (codex round-2): reject repo-root-equivalent paths
    if rel_str in ('.', ''):
        return f"BLOCK: {exempt_label} 路径归一化到仓库根等于全仓搜索: {raw_path}"
    for component in rel_str.split('/'):
        if _SENSITIVE_NAME_RE.search(component):
            return f"BLOCK: {exempt_label} 路径含敏感名: {rel_str}"
    return None
```

- [ ] **Step 4: Run test to verify it passes**

```bash
pytest tests/hooks/test_stop_response_check.py::TestR53F1RepoRootRejectInHelper::test_read_only_grep_dot_path_blocks -v
```

Expected: PASS.

- [ ] **Step 5: Run the full test file to confirm no regression**

```bash
pytest tests/hooks/test_stop_response_check.py -v
```

Expected: all pre-existing tests still PASS + new test PASS.

- [ ] **Step 6: Commit**

```bash
git add .claude/hooks/stop-response-check.sh tests/hooks/test_stop_response_check.py
git commit -m "hardening-6.0.1 Task 1: _path_is_safe_for_read reject repo-root equivalent

Add rel_str in ('.', '') check to _path_is_safe_for_read after
relative_to(repo_root) resolves. Catches path='.', path='./', path='docs/..',
absolute <repo> form — all normalize to repo-root = whole-repo read.

Test: Grep(pattern='secret', path='.') in read-only-query exempt → BLOCK.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `_extract_read_target` helper + refactor Grep/Glob in all 3 exempt branches

**Files:**
- Modify: `.claude/hooks/stop-response-check.sh` — add new helper after line 108; refactor line 115-122 (read-only-query), 192-198 (behavior-neutral), 212-216 (single-step)
- Test: `tests/hooks/test_stop_response_check.py` (add new `TestR53F1GrepGlob` class)

### Step 1: Write 7 failing tests

Add this test class to `tests/hooks/test_stop_response_check.py` after `TestR53F1RepoRootRejectInHelper`:

```python
class TestR53F1GrepGlob:
    """R53 F1 fix: Grep requires path; Glob unconditionally blocked in all exempt branches."""

    @pytest.fixture(autouse=True)
    def _block_mode(self):
        bak = _set_enforcement_mode("block")
        yield
        _restore_enforcement_mode(bak)

    def test_read_only_grep_without_path_blocks(self, tmp_path):
        """Gate-4 round-4 finding: use non-sensitive pattern so test fails on
        current (pre-fix) code — validates the actual 'path required' rule,
        not the incidental sensitive-name fallback."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "TODO"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_grep_without_path_blocks(self, tmp_path):
        """Gate-4 round-4 finding: inventory gap — behavior-neutral needed own
        native Grep no-path test (previous inventory only had read-only +
        single-step)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "TODO"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_grep_with_safe_path_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "TODO", "path": "docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_single_step_grep_without_path_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "TODO"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_grep_normalized_root_dotdot_blocks(self, tmp_path):
        """Grep path='docs/..' resolves to repo-root → BLOCK via helper."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "secret", "path": "docs/.."}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_glob_always_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Glob", "input": {"pattern": "**/*.md", "path": "docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_glob_always_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Glob", "input": {"pattern": "*.md", "path": "docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_glob_always_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Glob", "input": {"pattern": "*.md", "path": "docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")
```

- [ ] **Step 2: Run tests to verify all 7 fail**

```bash
pytest tests/hooks/test_stop_response_check.py::TestR53F1GrepGlob -v
```

Expected: all 7 FAIL (Grep no-path currently passes; Glob currently goes through `_path_is_safe_for_read` on pattern substring and may pass).

- [ ] **Step 3: Add `_extract_read_target` helper**

Edit `.claude/hooks/stop-response-check.sh` — insert new helper function after line 108 (right after `_path_is_safe_for_read` closing `return None`):

```python
def _extract_read_target(tu):
    """R53 F1 fix: per-tool path extraction. Returns (tool_name, path_or_None).
    Read → (Read, file_path); Grep → (Grep, path); Glob → (Glob, None sentinel for unconditional block).
    Removes the v52 fallback `file_path or path or pattern or ''` which incorrectly
    treated Grep's pattern as a path when path param was absent."""
    name = tu.get('name', '')
    inp = tu.get('input', {})
    if name == 'Read':
        return (name, inp.get('file_path'))
    if name == 'Grep':
        return (name, inp.get('path'))
    if name == 'Glob':
        return (name, None)  # sentinel — caller unconditionally blocks
    return (name, None)
```

- [ ] **Step 4: Refactor read-only-query branch (line 115-122)**

Replace lines 115-122 (starting with `if name in ('Read', 'Grep', 'Glob'):`) with:

```python
        if name in ('Read', 'Grep', 'Glob'):
            tool_name, path_arg = _extract_read_target(tu)
            if tool_name == 'Glob':
                print(f"BLOCK: exempt(read-only-query) 不允许 Glob 工具（文件枚举不符合 exempt 最小读语义；请用 Read + 具体 path，或声明真实 skill gate）"); sys.exit(0)
            if tool_name == 'Grep' and not path_arg:
                print(f"BLOCK: exempt(read-only-query) Grep 必须显式传 path 参数（不允许无 path 全仓搜索）"); sys.exit(0)
            msg = _path_is_safe_for_read(path_arg, f"exempt(read-only-query) {tool_name}")
            if msg:
                print(msg); sys.exit(0)
            continue
```

- [ ] **Step 5: Refactor behavior-neutral branch (line 192-198)**

Find lines 192-198 (inside `elif reason == 'behavior-neutral':`, the `elif name in ('Read', 'Grep', 'Glob'):` block). Replace with:

```python
        elif name in ('Read', 'Grep', 'Glob'):
            tool_name, path_arg = _extract_read_target(tu)
            if tool_name == 'Glob':
                print(f"BLOCK: exempt(behavior-neutral) 不允许 Glob 工具（文件枚举不符合 exempt 最小读语义；请用 Read + 具体 path，或声明真实 skill gate）"); sys.exit(0)
            if tool_name == 'Grep' and not path_arg:
                print(f"BLOCK: exempt(behavior-neutral) Grep 必须显式传 path 参数（不允许无 path 全仓搜索）"); sys.exit(0)
            msg = _path_is_safe_for_read(path_arg, f"exempt(behavior-neutral) {tool_name}")
            if msg:
                print(msg); sys.exit(0)
            continue
```

- [ ] **Step 6: Refactor single-step-no-semantic-change branch (line 212-216)**

Find the `if name in ('Read', 'Grep', 'Glob'):` block inside `elif reason == 'single-step-no-semantic-change':`. Replace with:

```python
        if name in ('Read', 'Grep', 'Glob'):
            tool_name, path_arg = _extract_read_target(tu)
            if tool_name == 'Glob':
                print(f"BLOCK: exempt(single-step) 不允许 Glob 工具（文件枚举不符合 exempt 最小读语义；请用 Read + 具体 path，或声明真实 skill gate）"); sys.exit(0)
            if tool_name == 'Grep' and not path_arg:
                print(f"BLOCK: exempt(single-step) Grep 必须显式传 path 参数（不允许无 path 全仓搜索）"); sys.exit(0)
            msg = _path_is_safe_for_read(path_arg, f"exempt(single-step) {tool_name}")
            if msg:
                print(msg); sys.exit(0)
            continue
```

- [ ] **Step 7: Run the 7 new tests to verify all pass**

```bash
pytest tests/hooks/test_stop_response_check.py::TestR53F1GrepGlob -v
```

Expected: all 7 PASS.

- [ ] **Step 8: Run the full test file to confirm no regression**

```bash
pytest tests/hooks/test_stop_response_check.py -v
```

Expected: all pre-existing tests still PASS + Task 1 test PASS + Task 2's 8 tests PASS.

- [ ] **Step 9: Commit**

```bash
git add .claude/hooks/stop-response-check.sh tests/hooks/test_stop_response_check.py
git commit -m "hardening-6.0.1 Task 2: _extract_read_target helper + Grep/Glob refactor

Add _extract_read_target(tu) helper: per-tool path extraction (Read→file_path,
Grep→path, Glob→None sentinel). Remove the 'pattern' fallback that
mis-classified Grep patterns as paths.

Refactor 3 exempt branches (read-only-query, behavior-neutral,
single-step-no-semantic-change) to:
- Unconditionally BLOCK Glob (root-cause fix vs pattern-grammar arms race)
- BLOCK Grep with no path param
- Path-check Grep+Read via _path_is_safe_for_read (now incl repo-root reject)

7 new tests: grep_without_path × 2 branches + grep_with_safe_path_passes
+ grep_normalized_root_dotdot_blocks + glob_always_blocks × 3 branches.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Bash arg-parse refactor — 8-tool coverage + universal flag-ban + per-tool operand rules

**Files:**
- Modify: `.claude/hooks/stop-response-check.sh` — lines 185-191 (behavior-neutral bash arg-loop) and 231-236 (single-step bash arg-loop)
- Test: `tests/hooks/test_stop_response_check.py` (add new `TestR53F1BashArgs` class)

This is the largest task (**23 tests**, ~50 lines of hook code). Implementation is identical in both branches (copy-paste). Test in pieces for TDD rhythm. The 23 tests break down: bash grep/rg 3 + repo-root-equivalent-on-bash 1 + flag-ban grep/rg 2 + jq 3 + ls 3 + universal-flag-ban head/ls/wc 3 + shell-glob-metachar pattern/filter 4 (3 behavior-neutral + 1 single-step jq) + path-operand glob defense-in-depth 3 + static source assertion 1.

### Step 1: Write 15 failing tests

Add this test class to `tests/hooks/test_stop_response_check.py` after `TestR53F1GrepGlob`:

```python
class TestR53F1BashArgs:
    """R53 F1 fix: Bash arg-loop extended to 8 tools + universal flag-ban + per-tool operand rules."""

    @pytest.fixture(autouse=True)
    def _block_mode(self):
        bak = _set_enforcement_mode("block")
        yield
        _restore_enforcement_mode(bak)

    # --- Bash grep/rg: no-path / with-path / recursive-flag ---

    def test_behavior_neutral_bash_rg_without_path_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "rg secret"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_bash_rg_with_path_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "rg secret docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_single_step_bash_grep_recursive_no_path_blocks(self, tmp_path):
        """`grep -r TODO` — blocked by flag-ban (-r is a flag)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "grep -r TODO"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # --- Repo-root-equivalent on Bash grep/rg ---

    def test_behavior_neutral_bash_rg_dot_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "rg secret ."}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # --- Flag-ban on Bash grep/rg ---

    def test_behavior_neutral_bash_rg_with_flag_blocks(self, tmp_path):
        """rg -g '*.md' secret docs/ — flag consumes next token, must be blocked."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "rg -g *.md secret docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_bash_grep_with_f_flag_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "grep -f patterns.txt secret docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # --- jq special parse: filter vs paths ---

    def test_behavior_neutral_bash_jq_filter_only_blocks(self, tmp_path):
        """`jq .` alone — filter present but no file operand → BLOCK."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "jq ."}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_bash_jq_filter_and_file_passes(self, tmp_path):
        """`jq . docs/foo.json` — filter `.` not path-checked; file is safe."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "jq . docs/foo.json"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_behavior_neutral_bash_jq_filter_and_sensitive_file_blocks(self, tmp_path):
        """`jq . .env` — filter `.` not path-checked; .env hits sensitive-name."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "jq . .env"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # --- ls coverage (currently missing from arg-loop in behavior-neutral & single-step) ---

    def test_read_only_bash_ls_dot_blocks(self, tmp_path):
        """`ls .` — read-only-query branch already has ls in arg-check; repo-root-reject from Task 1 catches this."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "ls ."}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_bash_ls_dotenv_blocks(self, tmp_path):
        """`ls .env` in behavior-neutral — previously passed because ls was not in arg-loop."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "ls .env"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_bash_ls_safe_path_passes(self, tmp_path):
        """`ls docs/` — safe path, new arg-loop should allow."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "ls docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    # --- Universal flag-ban on head/ls/wc ---

    def test_behavior_neutral_bash_head_with_n_flag_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "head -n 1 .env"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_bash_ls_with_I_flag_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "ls -I .env"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_bash_wc_with_l_flag_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "wc -l .env"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # --- Shell-glob-metachar ban in grep/rg pattern + jq filter (Gate-4 round-1 fix) ---

    def test_behavior_neutral_bash_rg_star_pattern_blocks(self, tmp_path):
        """`rg * docs/` — bare `*` expands in shell BEFORE rg runs → BLOCK."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "rg * docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_bash_grep_starpem_pattern_blocks(self, tmp_path):
        """`grep *.pem docs/` — `*.pem` expands to all .pem files at cwd → BLOCK."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "grep *.pem docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_bash_jq_star_filter_blocks(self, tmp_path):
        """`jq * docs/foo.json` — `*` filter slot expands in shell → BLOCK."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "jq * docs/foo.json"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_bash_jq_star_filter_blocks(self, tmp_path):
        """Gate-4 round-7 finding: same class as behavior-neutral — single-step
        must also reject `*` in jq filter slot."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "jq * docs/foo.json"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # --- Shell-glob metachar on PATH operands: defense-in-depth (Gate-4 round-5 clarification) ---
    # Note: `_path_is_safe_for_read` already rejects glob chars at line 96 (pre-H6.0.1).
    # These tests prove the new Bash arg-loop routes path args through that existing check.

    def test_behavior_neutral_bash_cat_glob_path_blocks(self, tmp_path):
        """`cat docs/*` — path arg contains `*`; pre-existing helper rule blocks."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "cat docs/*"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_bash_ls_glob_path_blocks(self, tmp_path):
        """`ls docs/*.md` — `*` in path arg."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "ls docs/*.md"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_bash_wc_bracket_path_blocks(self, tmp_path):
        """`wc docs/[ab].txt` — `[` `]` in path arg (character class glob)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "wc docs/[ab].txt"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # --- Static source assertion (Gate-4 round-6 finding) ---
    # Current safe_bash whitelist rejects `-` before arg-loop runs, so runtime
    # flag-ban tests block via whitelist, not arg-loop. Static assertion verifies
    # the arg-loop flag-ban code exists independently in BOTH exempt branches —
    # guards against silent drop if future PR relaxes the whitelist.

    def test_r53f1_flag_ban_code_present_in_both_branches(self):
        """Gate-4 round-7 finding: branch-scoped assertion (vs naive count >= 2).
        Split hook at `elif reason ==` boundaries and verify EACH exempt branch
        (behavior-neutral + single-step) contains BOTH the `arg.startswith('-')`
        guard AND the flag-ban BLOCK message."""
        import re
        hook_path = REPO_ROOT / ".claude" / "hooks" / "stop-response-check.sh"
        hook_src = hook_path.read_text()

        def _extract_branch_body(reason):
            """Extract Python code between `elif reason == '<reason>':` and the
            next `elif reason ==` (or end-of-file)."""
            m = re.search(
                rf"(?:if|elif) +reason +== +['\"]?{re.escape(reason)}['\"]?\s*:(.*?)(?=(?:if|elif) +reason +==|\Z)",
                hook_src, re.DOTALL)
            assert m, f"branch for reason={reason!r} not found in hook source"
            return m.group(1)

        for reason in ('behavior-neutral', 'single-step-no-semantic-change'):
            body = _extract_branch_body(reason)
            assert ("arg.startswith('-')" in body) or ('arg.startswith("-")' in body), (
                f"branch '{reason}' Bash arg-loop missing `arg.startswith('-')` flag guard"
            )
            assert "不允许任何 flag" in body, (
                f"branch '{reason}' missing flag-ban BLOCK message — defense-in-depth gone"
            )
```

- [ ] **Step 2: Run tests to verify all 15 fail**

```bash
pytest tests/hooks/test_stop_response_check.py::TestR53F1BashArgs -v
```

Expected: multiple FAILs (exact count varies — some may already pass via safe_bash regex's `-` exclusion, but 7-10 should fail since arg-loop currently skips `ls` and has wrong operand rules for `rg`/`jq`).

- [ ] **Step 3: Define shared Bash arg-parse logic (Python block embedded in hook)**

This logic replaces lines 185-191 in the behavior-neutral branch AND lines 231-236 in the single-step branch. The two branches use different `exempt_label` strings but identical logic.

Here's the **shared** implementation (for both branches — parametrize `exempt_label`):

```python
# R53 F1 fix: extended 8-tool coverage + universal flag-ban + per-tool operand rules
BASH_READ_TOOLS = ('ls', 'cat', 'head', 'tail', 'wc', 'grep', 'rg', 'jq')
if parts and parts[0] in BASH_READ_TOOLS:
    tool = parts[0]
    args = parts[1:]
    # Universal flag-ban (defense-in-depth; safe_bash regex also rejects `-`)
    for arg in args:
        if arg.startswith('-'):
            print(f"BLOCK: exempt({exempt_label_short}) Bash {tool} 不允许任何 flag（避免 flag 吃 operand 导致 operand 误分类，如 head -n 1 .env / ls -I .env）: {cmd[:120]}"); sys.exit(0)
    # Per-tool operand rules (after flag-ban confirms no `-` args)
    if tool in ('cat', 'head', 'tail', 'wc', 'ls'):
        # All args are paths; require ≥1
        if len(args) < 1:
            print(f"BLOCK: exempt({exempt_label_short}) Bash {tool} 需至少 1 个路径参数: {cmd[:120]}"); sys.exit(0)
        for path_arg in args:
            msg = _path_is_safe_for_read(path_arg, f"exempt({exempt_label_short}) Bash {tool}")
            if msg:
                print(msg); sys.exit(0)
    elif tool in ('grep', 'rg'):
        # exactly 2 args: pattern (arg[0], NOT path-checked) + path (arg[1], path-checked)
        if len(args) != 2:
            print(f"BLOCK: exempt({exempt_label_short}) Bash {tool} 必须恰好 '<pattern> <path>' 形式 (实际 {len(args)} 参数): {cmd[:120]}"); sys.exit(0)
        msg = _path_is_safe_for_read(args[1], f"exempt({exempt_label_short}) Bash {tool}")
        if msg:
            print(msg); sys.exit(0)
    elif tool == 'jq':
        # arg[0] = filter (NOT path-checked); arg[1:] = paths (path-checked)
        if len(args) < 1:
            print(f"BLOCK: exempt({exempt_label_short}) Bash jq 至少需 filter: {cmd[:120]}"); sys.exit(0)
        if len(args) < 2:
            print(f"BLOCK: exempt({exempt_label_short}) Bash jq 必须传文件参数 (filter 后至少 1 个 path): {cmd[:120]}"); sys.exit(0)
        for path_arg in args[1:]:
            msg = _path_is_safe_for_read(path_arg, f"exempt({exempt_label_short}) Bash jq")
            if msg:
                print(msg); sys.exit(0)
```

- [ ] **Step 4: Apply the shared logic to behavior-neutral branch (line 185-191)**

In `.claude/hooks/stop-response-check.sh`, find the behavior-neutral branch's Bash arg-loop (around line 181-197, starting with `elif name == 'Bash':`). Replace the existing arg-loop (line 185-191, the `if parts and parts[0] in ('cat', ...)` block) with the shared logic above, using `exempt_label_short = "behavior-neutral"`.

Concretely, replace lines 185-191:

```python
            if parts and parts[0] in ('cat', 'head', 'tail', 'wc', 'grep', 'rg', 'jq'):
                for arg in parts[1:]:
                    if arg.startswith('-'):
                        continue
                    msg = _path_is_safe_for_read(arg, f"exempt(behavior-neutral) Bash {parts[0]}")
                    if msg:
                        print(msg); sys.exit(0)
```

With (using exempt_label_short = "behavior-neutral"):

```python
            # R53 F1 fix: extended 8-tool coverage + universal flag-ban + per-tool operand rules
            BASH_READ_TOOLS = ('ls', 'cat', 'head', 'tail', 'wc', 'grep', 'rg', 'jq')
            if parts and parts[0] in BASH_READ_TOOLS:
                tool = parts[0]
                args = parts[1:]
                for arg in args:
                    if arg.startswith('-'):
                        print(f"BLOCK: exempt(behavior-neutral) Bash {tool} 不允许任何 flag: {cmd[:120]}"); sys.exit(0)
                if tool in ('cat', 'head', 'tail', 'wc', 'ls'):
                    if len(args) < 1:
                        print(f"BLOCK: exempt(behavior-neutral) Bash {tool} 需至少 1 个路径参数: {cmd[:120]}"); sys.exit(0)
                    for path_arg in args:
                        msg = _path_is_safe_for_read(path_arg, f"exempt(behavior-neutral) Bash {tool}")
                        if msg:
                            print(msg); sys.exit(0)
                elif tool in ('grep', 'rg'):
                    if len(args) != 2:
                        print(f"BLOCK: exempt(behavior-neutral) Bash {tool} 必须恰好 '<pattern> <path>' 形式 (实际 {len(args)} 参数): {cmd[:120]}"); sys.exit(0)
                    # Gate-4 round-1 fix: reject shell-glob metachars in pattern (shell expands before tool runs)
                    if any(c in args[0] for c in '*?[]{}'):
                        print(f"BLOCK: exempt(behavior-neutral) Bash {tool} pattern 含 shell glob 元字符（shell 会在命令执行前展开成文件列表，绕过 path 检查）: {args[0]}"); sys.exit(0)
                    msg = _path_is_safe_for_read(args[1], f"exempt(behavior-neutral) Bash {tool}")
                    if msg:
                        print(msg); sys.exit(0)
                elif tool == 'jq':
                    if len(args) < 1:
                        print(f"BLOCK: exempt(behavior-neutral) Bash jq 至少需 filter: {cmd[:120]}"); sys.exit(0)
                    if len(args) < 2:
                        print(f"BLOCK: exempt(behavior-neutral) Bash jq 必须传文件参数 (filter 后至少 1 个 path): {cmd[:120]}"); sys.exit(0)
                    # Gate-4 round-1 fix: same class as grep/rg — reject shell-glob metachars in filter
                    if any(c in args[0] for c in '*?[]{}'):
                        print(f"BLOCK: exempt(behavior-neutral) Bash jq filter 含 shell glob 元字符（shell 会在命令执行前展开成文件列表，绕过 path 检查）: {args[0]}"); sys.exit(0)
                    for path_arg in args[1:]:
                        msg = _path_is_safe_for_read(path_arg, f"exempt(behavior-neutral) Bash jq")
                        if msg:
                            print(msg); sys.exit(0)
```

- [ ] **Step 5: Apply the shared logic to single-step branch (line 231-236)**

In the same file, find the single-step branch's Bash arg-loop (around line 227-240, inside `elif reason == 'single-step-no-semantic-change':`, block `elif name == 'Bash':`). Apply the SAME shared logic replacement, changing `exempt(behavior-neutral)` → `exempt(single-step)`.

Specifically, replace the existing arg-loop (line 231-236, the `if parts and parts[0] in ('cat', ...)` block) with the same structure as above but with `exempt(single-step)` label string.

- [ ] **Step 6: Also update read-only-query branch for ls repo-root-reject consistency**

The read-only-query branch already handles `ls` with 1-arg requirement (line 138). The `path_arg` check at line 141 calls `_path_is_safe_for_read` which now rejects `.` (Task 1 change). So `ls .` already blocks after Task 1. No further changes needed here — verified by `test_read_only_bash_ls_dot_blocks` passing.

- [ ] **Step 6b: Update pre-existing `test_single_step_with_one_tool_passes` to use a safe path (codex Gate-4 round-2 finding 1)**

The existing test in `TestL3ExemptIntegritySingleStep` class (search for `test_single_step_with_one_tool_passes` in `tests/hooks/test_stop_response_check.py`) uses `Bash("ls .")` and asserts no block. After Task 1's repo-root-reject + Task 3's single-step `ls` path-check, this fixture is now unsafe and the test will fail. Update the `command` string:

Before:
```python
tool_uses=[{"name": "Bash", "input": {"command": "ls ."}}],
```

After:
```python
tool_uses=[{"name": "Bash", "input": {"command": "ls docs/"}}],
```

Rationale: test's original intent was "single-step allows ONE tool_use, passes" — the `.` vs `docs/` choice was incidental. With F1 fix, `.` is unsafe and tested by our new `test_single_step_bash_ls_safe_path_passes` (which uses `ls docs/`). The update preserves the existing test's "one-tool count" semantic while moving away from now-unsafe fixture.

Note: the new `test_single_step_bash_ls_safe_path_passes` (in TestR53F1BashArgs class) effectively replaces the coverage lost here if we had deleted the existing test. They're near-duplicates semantically — acceptable because the existing test lives in `TestL3ExemptIntegritySingleStep` (legacy H6.0 class) and the new one lives in F1-specific class.

- [ ] **Step 7: Run the 15 new Bash tests**

```bash
pytest tests/hooks/test_stop_response_check.py::TestR53F1BashArgs -v
```

Expected: all 15 PASS.

- [ ] **Step 8: Run full test file**

```bash
pytest tests/hooks/test_stop_response_check.py -v
```

Expected: all tests PASS (original + Task 1 + Task 2 + Task 3 = original count + 30 new).

- [ ] **Step 9: Commit**

```bash
git add .claude/hooks/stop-response-check.sh tests/hooks/test_stop_response_check.py
git commit -m "hardening-6.0.1 Task 3: Bash arg-loop refactor — 8 tools + flag-ban + per-tool ops

Extend Bash arg-parse in behavior-neutral and single-step exempt branches:
- Add 'ls' to the 8 whitelisted tools (previously only cat/head/tail/wc/grep/rg/jq)
- Universal flag-ban: any arg matching ^- triggers BLOCK in arg-loop
  (defense-in-depth; safe_bash regex already excludes -)
- Per-tool operand rules:
  * cat/head/tail/wc/ls: all args are paths, require ≥1
  * grep/rg: exactly 2 args (pattern + path); only path path-checked
  * jq: arg[0] = filter (not path-checked); arg[1:] = paths

15 new tests: bash rg without/with path, grep recursive via flag-ban,
bash_rg_dot via helper repo-root-reject, flag-ban (rg/grep/head/ls/wc),
jq filter-only/with-file/with-sensitive, ls dot/dotenv/safe.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Final verification — full pytest + diff audit

- [ ] **Step 1: Run the entire test file**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1"
pytest tests/hooks/test_stop_response_check.py -v
```

Expected: all tests PASS (including 32 new F1 tests: 1 Task 1 + 8 Task 2 + 23 Task 3).

- [ ] **Step 2: Run the full hooks test suite (regression check)**

```bash
pytest tests/hooks/ -v
```

Expected: all tests PASS. Confirms no accidental breakage of `test_skill_invoke_check.py` or any other hook test.

- [ ] **Step 3: Diff audit — confirm only 2 code/test files changed**

```bash
git diff origin/main --name-only
```

Expected output (4 files):
```
.claude/hooks/stop-response-check.sh
docs/superpowers/plans/2026-04-23-h6-0-1-hardening-plan.md
docs/superpowers/specs/2026-04-23-h6-0-1-hardening-design.md
tests/hooks/test_stop_response_check.py
```

Critical: these four and ONLY these four. If `skill-invoke-check.sh` / `skill-invoke-enforced.json` / `workflow-rules.json` / `CLAUDE.md` appear, STOP and investigate — the refactor accidentally touched a forbidden file.

- [ ] **Step 4: Count new tests in test file**

```bash
git diff origin/main -- tests/hooks/test_stop_response_check.py | grep -c "^+    def test_"
```

Expected: 32 (exactly — 1 Task 1 + 8 Task 2 + 23 Task 3).

- [ ] **Step 5: Commit the plan itself if not yet committed**

```bash
git status  # check if plan doc is committed
# If the plan doc shows uncommitted:
git add docs/superpowers/plans/2026-04-23-h6-0-1-hardening-plan.md
git commit -m "plan(hardening-6.0.1): R53 F1 TDD implementation plan

Bite-sized TDD plan for Gate 5 implementation of H6.0.1 F1 fix. 4 tasks
(3 implementation + 1 verification) covering 32 new tests across
_path_is_safe_for_read repo-root-reject / _extract_read_target helper /
Bash arg-loop 8-tool + flag-ban + per-tool ops.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Gate 4 (plan codex review) — run this after plan is committed

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1"
bash .claude/scripts/codex-attest.sh --scope branch-diff --head hardening-6.0.1 --base origin/main
```

Target verdict: `approve`. If `needs-attention`, evaluate each finding:
- In-scope substantive issue → fix inline, re-attest (budget ≤2 rounds)
- Framing / spec-reference confusion → adjust wording
- Out-of-scope (e.g. revives F2/F3 territory) → pushback inline, cite v7 scope 收缩 decision

If round 3 fails → user escalate. Do not iterate past round 3 on this gate.

---

## Gate 6 (post-implementation branch codex review) — after Task 3 commits

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1"
bash .claude/scripts/codex-attest.sh --scope branch-diff --head hardening-6.0.1 --base origin/main
```

Target verdict: `approve`. Budget ≤2 rounds.

---

## Gate 7 Acceptance (non-coder-executable, Chinese, 无禁词)

执行顺序：用户 terminal 依次跑；任何一步 fail 则停。

| # | 动作 | 预期 | 判定（可观测命令） |
|---|---|---|---|
| A1 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1" && pytest tests/hooks/test_stop_response_check.py -v 2>&1 \| tail -30` | 最后一行包含 "N passed"；所有新增 F1 tests 命中 `TestR53F1RepoRootRejectInHelper` / `TestR53F1GrepGlob` / `TestR53F1BashArgs` 三个 class | 新增 32 个测试全部在输出中以 `PASSED` 出现；"failed" 计数 = 0；"error" 计数 = 0 |
| A2 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1" && pytest tests/hooks/ -v 2>&1 \| tail -10` | 全部 hooks tests 通过（回归检查） | 输出最后 "failed" 计数 = 0；"error" 计数 = 0 |
| A3 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1" && git diff origin/main --name-only` | 恰好列出 4 个文件路径 | 文件名集合 = {`.claude/hooks/stop-response-check.sh`, `docs/superpowers/plans/2026-04-23-h6-0-1-hardening-plan.md`, `docs/superpowers/specs/2026-04-23-h6-0-1-hardening-design.md`, `tests/hooks/test_stop_response_check.py`}；不含 `skill-invoke-check.sh` / `skill-invoke-enforced.json` / `workflow-rules.json` / `CLAUDE.md` 任何一个 |
| A4 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1" && git diff origin/main -- tests/hooks/test_stop_response_check.py \| grep -c "^+    def test_"` | 新增测试函数恰好 32 个 | 输出数字 = 32 |
| A4b | `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1" && for t in test_read_only_grep_dot_path_blocks test_read_only_grep_without_path_blocks test_behavior_neutral_grep_without_path_blocks test_read_only_grep_with_safe_path_passes test_single_step_grep_without_path_blocks test_single_step_grep_normalized_root_dotdot_blocks test_read_only_glob_always_blocks test_behavior_neutral_glob_always_blocks test_single_step_glob_always_blocks test_behavior_neutral_bash_rg_without_path_blocks test_behavior_neutral_bash_rg_with_path_passes test_single_step_bash_grep_recursive_no_path_blocks test_behavior_neutral_bash_rg_dot_blocks test_behavior_neutral_bash_rg_with_flag_blocks test_single_step_bash_grep_with_f_flag_blocks test_behavior_neutral_bash_jq_filter_only_blocks test_behavior_neutral_bash_jq_filter_and_file_passes test_behavior_neutral_bash_jq_filter_and_sensitive_file_blocks test_read_only_bash_ls_dot_blocks test_behavior_neutral_bash_ls_dotenv_blocks test_single_step_bash_ls_safe_path_passes test_behavior_neutral_bash_head_with_n_flag_blocks test_single_step_bash_ls_with_I_flag_blocks test_behavior_neutral_bash_wc_with_l_flag_blocks test_behavior_neutral_bash_rg_star_pattern_blocks test_single_step_bash_grep_starpem_pattern_blocks test_behavior_neutral_bash_jq_star_filter_blocks test_behavior_neutral_bash_cat_glob_path_blocks test_single_step_bash_ls_glob_path_blocks test_behavior_neutral_bash_wc_bracket_path_blocks test_single_step_bash_jq_star_filter_blocks test_r53f1_flag_ban_code_present_in_both_branches; do grep -q "def $t" tests/hooks/test_stop_response_check.py && echo "OK $t" \|\| echo "MISSING $t"; done \| grep -c "^OK "` | 以上 32 个测试名每一个都存在于测试文件中（按类别覆盖 6 个 bypass class + 1 static assertion） | 输出数字 = 32；无 `MISSING` 行 |
| A5 | `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/hardening-6.0.1" && bash .claude/scripts/codex-attest.sh --scope branch-diff --head hardening-6.0.1 --base origin/main 2>&1 \| tail -5` | codex 输出 `Verdict: approve`；脚本 exit 0；ledger 被更新 | 输出含字符串 `Verdict: approve`；无 `Verdict: needs-attention` 或 `Verdict: request-changes` |

**禁词核查**：此 checklist 不含 "should work" / "looks good" / "probably fine" / "basically" / "roughly" / "more or less"。所有判定有可观测命令。

---

## Execution mode

**I recommend inline execution** (`superpowers:executing-plans`) for this plan:
- Tasks are sequential (Task 2 depends on Task 1's helper change; Task 3 depends on Task 2's refactor touching same line ranges)
- Code changes are small and local (single file + single test file)
- Subagent overhead not worth it for ~4 distinct commits

Alternative: subagent-driven if parallelizable subtasks appear worth isolating.
