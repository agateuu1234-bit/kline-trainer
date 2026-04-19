# gov-bootstrap-hardening-4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline). Trust-boundary edit (`.claude/scripts/codex-attest.sh`) goes via `/tmp/` patch + user terminal (same pattern as hardening-1/-2/-3).

**Goal:** Make `codex-attest.sh --scope branch-diff` actually review the target SHA's code (not current checkout) by creating a temporary git worktree at the frozen SHA and invoking codex-companion with `--cwd <worktree>`.

**Architecture:** Single script change. 4 new tests. Trap-based worktree cleanup on any exit. Pre/post ref-drift check preserved from hardening-2 R2.

**Tech Stack:** bash 3.2 / pytest / git worktree (Git 2.5+).

**Spec:** `docs/superpowers/specs/2026-04-19-gov-bootstrap-hardening-4-design.md` (commit `cba6ef7`)

**Branch:** `gov-bootstrap-hardening-4`

---

## File structure

### Modified (trust-boundary — user-terminal patches)

- `.claude/scripts/codex-attest.sh` — Task 1 (core mechanism change)

### Modified (tests, no ask)

- `tests/hooks/test_codex_attest_ledger_write.py` — Task 1 (add TestWorktreeBranchReviewH23 class)

---

## Task 1: H2-3 worktree-based branch-diff review

**Files:**
- Modify: `.claude/scripts/codex-attest.sh` (via /tmp/ patch)
- Modify: `tests/hooks/test_codex_attest_ledger_write.py`

- [ ] **Step 1: Write failing tests (append to existing file)**

Append to `tests/hooks/test_codex_attest_ledger_write.py`:

```python
class TestWorktreeBranchReviewH23:
    """H2-3: branch-diff mode must invoke codex with --cwd pointing at a worktree
    checked out at the frozen HEAD_SHA, not the current repo checkout."""

    def _make_marker_stub(self, repo: Path, marker_path: str) -> Path:
        """Stub node that inspects --cwd arg: if dir contains marker_path, echo approve."""
        stub_dir = repo / "stubs"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "node"
        stub.write_text(f'''#!/usr/bin/env bash
# Find --cwd arg
FOUND_CWD=""
for ((i=1;i<=$#;i++)); do
    if [ "${{!i}}" = "--cwd" ]; then
        next=$((i+1))
        FOUND_CWD="${{!next}}"
    fi
done
if [ -z "$FOUND_CWD" ]; then echo '{{"verdict":"needs-attention","why":"no --cwd"}}'; exit 1; fi
if [ ! -d "$FOUND_CWD" ]; then echo '{{"verdict":"needs-attention","why":"cwd missing"}}'; exit 1; fi
if [ -f "$FOUND_CWD/{marker_path}" ]; then
    echo '# Codex Adversarial Review'
    echo 'Target: branch diff'
    echo 'Verdict: approve'
    exit 0
fi
echo '{{"verdict":"needs-attention","why":"marker missing from cwd"}}'
exit 1
''')
        stub.chmod(0o755)
        return stub

    def _setup_branches(self, repo: Path, marker_filename: str):
        """Create main + feature branch with marker only in feature."""
        subprocess.run(["git", "commit", "--allow-empty", "-qm", "init"], cwd=repo, check=True)
        subprocess.run(["git", "branch", "-M", "main"], cwd=repo, check=True)
        subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "main"], cwd=repo, check=True)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=repo, check=True)
        (repo / marker_filename).write_text("only-in-feat\n")
        subprocess.run(["git", "add", marker_filename], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-qm", "add marker"], cwd=repo, check=True)

    def test_branch_diff_reviews_target_sha_not_current_checkout(self, temp_git_repo, ledger_path):
        """Core H2-3: codex sees target branch content even when we're checked out on main."""
        MARKER = "marker-only-in-feat.txt"
        self._setup_branches(temp_git_repo, MARKER)
        # Checkout main (marker absent here)
        subprocess.run(["git", "checkout", "-q", "main"], cwd=temp_git_repo, check=True)
        assert not (temp_git_repo / MARKER).exists(), "marker must not be in main"

        stub = self._make_marker_stub(temp_git_repo, MARKER)
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}
        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "branch-diff", "--base", "origin/main", "--head", "feat"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        assert r.returncode == 0, (
            f"stub approves iff --cwd contains marker; stub seeing main's checkout would fail. "
            f"exit={r.returncode}\nstdout={r.stdout}\nstderr={r.stderr}"
        )
        # Ledger entry written for feat@<sha>, not main
        feat_sha = subprocess.run(["git", "rev-parse", "feat"],
                                  cwd=temp_git_repo, capture_output=True, text=True).stdout.strip()
        data = json.loads(ledger_path.read_text())
        key = f"branch:feat@{feat_sha}"
        assert key in data["entries"], f"expected {key} in ledger; got {list(data['entries'])}"

    def test_worktree_cleaned_on_success(self, temp_git_repo, tmp_path):
        MARKER = "m2.txt"
        self._setup_branches(temp_git_repo, MARKER)
        subprocess.run(["git", "checkout", "-q", "main"], cwd=temp_git_repo, check=True)

        stub = self._make_marker_stub(temp_git_repo, MARKER)
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}
        # Record existing /tmp/codex-attest-wt.* before
        import glob
        before = set(glob.glob("/tmp/codex-attest-wt.*"))
        subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "branch-diff", "--base", "origin/main", "--head", "feat"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        after = set(glob.glob("/tmp/codex-attest-wt.*"))
        # No new worktree dirs should remain
        new_dirs = after - before
        assert not new_dirs, f"worktree dirs leaked: {new_dirs}"

    def test_worktree_cleaned_on_failure(self, temp_git_repo, ledger_path):
        """When verdict is needs-attention, worktree still gets cleaned up + ledger not written."""
        MARKER = "m3.txt"
        self._setup_branches(temp_git_repo, MARKER)
        subprocess.run(["git", "checkout", "-q", "main"], cwd=temp_git_repo, check=True)

        # Stub that always returns needs-attention (doesn't check marker)
        stub_dir = temp_git_repo / "stubs"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "node"
        stub.write_text('''#!/usr/bin/env bash
echo '# Codex Adversarial Review'
echo 'Verdict: needs-attention'
echo 'Findings: forced failure for test'
exit 0
''')
        stub.chmod(0o755)
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}

        import glob
        before = set(glob.glob("/tmp/codex-attest-wt.*"))
        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "branch-diff", "--base", "origin/main", "--head", "feat"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        after = set(glob.glob("/tmp/codex-attest-wt.*"))
        assert r.returncode != 0, "needs-attention should exit non-zero"
        new_dirs = after - before
        assert not new_dirs, f"worktree dirs leaked on failure: {new_dirs}"
        # Ledger should NOT have feat entry
        if ledger_path.exists():
            data = json.loads(ledger_path.read_text())
            feat_sha = subprocess.run(["git", "rev-parse", "feat"],
                                      cwd=temp_git_repo, capture_output=True, text=True).stdout.strip()
            assert f"branch:feat@{feat_sha}" not in data["entries"]

    def test_ref_drift_during_review_aborts(self, temp_git_repo, ledger_path):
        """If HEAD_BR moves between freeze and ledger-write, abort with exit 13."""
        MARKER = "m4.txt"
        self._setup_branches(temp_git_repo, MARKER)
        subprocess.run(["git", "checkout", "-q", "main"], cwd=temp_git_repo, check=True)

        # Stub that advances target branch mid-review then echoes approve
        # (simulates ref drift during the codex call)
        stub_dir = temp_git_repo / "stubs"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "node"
        stub_code = f'''#!/usr/bin/env bash
# Advance feat branch as side-effect
cd "{temp_git_repo}"
git checkout -q feat 2>/dev/null
git commit --allow-empty -qm "drift"
git checkout -q main 2>/dev/null
echo '# Codex Adversarial Review'
echo 'Verdict: approve'
exit 0
'''
        stub.write_text(stub_code)
        stub.chmod(0o755)
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}
        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "branch-diff", "--base", "origin/main", "--head", "feat"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        assert r.returncode == 13, f"expected exit 13 for ref drift; got {r.returncode}\nstderr={r.stderr}"
        assert "moved during review" in (r.stderr + r.stdout).lower()
```

- [ ] **Step 2: Run failing tests**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 -m pytest tests/hooks/test_codex_attest_ledger_write.py::TestWorktreeBranchReviewH23 -v
```

Expected: at least `test_branch_diff_reviews_target_sha_not_current_checkout` FAILS because current script generates patch + sends `--focus` (codex stub sees no `--cwd` → exits 1 → verdict needs-attention → exit 7).

- [ ] **Step 3: Prepare patch for user terminal**

Write `/tmp/patch-h4-worktree.py`:

```python
#!/usr/bin/env python3
"""H2-3: replace branch-diff patch-as-focus mechanism with git worktree + --cwd."""
from pathlib import Path

TARGET = Path(".claude/scripts/codex-attest.sh")

# Old block: generate patch file, pass as --focus
OLD_PATCH_GEN = '''    TMP_PATCH=$(mktemp --suffix=.patch 2>/dev/null || mktemp -t codex-branchdiff)
    HEAD_SHA_FOR_PATCH=$(git rev-parse "$HEAD_BR")
    git diff --no-color --no-ext-diff "$BASE...$HEAD_BR" > "$TMP_PATCH" || {
        echo "[codex-attest] ERROR: cannot compute $BASE...$HEAD_BR diff for patch" >&2
        exit 6
    }
    REVIEW_ARGS="--base $BASE --focus $TMP_PATCH"
    echo "[codex-attest] branch-diff patch: $TMP_PATCH ($BASE...$HEAD_BR @ $HEAD_SHA_FOR_PATCH)"'''

NEW_WORKTREE = '''    HEAD_SHA_FOR_PATCH=$(git rev-parse "$HEAD_BR")
    # H2-3: use git worktree at frozen SHA + --cwd so codex reviews the target,
    # not the current checkout. Replaces the patch-as-focus trick (codex-companion
    # ignored --focus files and reviewed cwd HEAD anyway).
    WORKTREE=$(mktemp -d -t codex-attest-wt.XXXXXX)
    trap 'git worktree remove --force "$WORKTREE" 2>/dev/null || true; rm -rf "$WORKTREE" 2>/dev/null || true' EXIT
    if ! git worktree add --detach "$WORKTREE" "$HEAD_SHA_FOR_PATCH" 2>/dev/null; then
        echo "[codex-attest] ERROR: cannot create worktree at $HEAD_SHA_FOR_PATCH" >&2
        exit 14
    fi
    REVIEW_ARGS="--base $BASE --cwd $WORKTREE"
    echo "[codex-attest] branch-diff worktree: $WORKTREE @ $HEAD_SHA_FOR_PATCH"'''

s = TARGET.read_text()
if "--cwd $WORKTREE" in s or "git worktree add --detach" in s:
    print("[patch] already applied"); raise SystemExit(0)
count = s.count(OLD_PATCH_GEN)
if count == 0:
    print("[patch] ERROR: OLD patch-generation block not found; inspect script manually")
    raise SystemExit(2)
if count > 1:
    print(f"[patch] ERROR: OLD block found {count} times"); raise SystemExit(3)
TARGET.write_text(s.replace(OLD_PATCH_GEN, NEW_WORKTREE))
print("[patch] patched")
```

- [ ] **Step 4: User runs + verifies**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h4-worktree.py
grep -n "git worktree add --detach" .claude/scripts/codex-attest.sh
python3 -m pytest tests/hooks/test_codex_attest_ledger_write.py::TestWorktreeBranchReviewH23 -v
```

Expected: 4/4 new tests pass.

- [ ] **Step 5: Run full suite for regressions**

```bash
python3 -m pytest tests/hooks/ -q
```

Expected: 105 baseline + 4 new = 109 passing; no regressions.

- [ ] **Step 6: Commit**

```bash
git add .claude/scripts/codex-attest.sh tests/hooks/test_codex_attest_ledger_write.py
git commit -m "feat(codex-attest): branch-diff uses git worktree + --cwd for real target review (H2-3)

Prior: generated diff patch + --focus <patch>. codex-companion ignored
--focus and reviewed cwd HEAD anyway (attest semantics was 'we reviewed
current checkout while writing ledger for frozen SHA'), forcing every
bootstrap PR through attest-override ceremony.

New: git worktree add --detach <tmp> <HEAD_SHA_FROZEN>; invoke codex with
--cwd <worktree>. codex literally reviews the target SHA's tree. Trap
cleans up worktree on any exit (success / needs-attention / ref-drift
abort / ctrl+c). Ref-drift check from hardening-2 R2 preserved.

4 new tests: target-sha review, cleanup-on-success, cleanup-on-failure,
ref-drift abort."
git log --oneline -3
```

---

## Task 2: Full acceptance

- [ ] **Step 1: Full test suite**

```bash
python3 -m pytest tests/hooks/ -q
```

Expected: 109 passing / 0 failing / 0 regressions.

- [ ] **Step 2: Acceptance script**

```bash
./scripts/acceptance/plan_0a_toolchain.sh
```

Expected: `PLAN 0A PASS` (25 + 1 SKIP).

- [ ] **Step 3: Acceptance artifact**

Write `artifacts/acceptance/gov-bootstrap-hardening-4-run.md` via Write tool, then:

```bash
git add artifacts/acceptance/gov-bootstrap-hardening-4-run.md
git commit -m "docs(acceptance): gov-bootstrap-hardening-4 run log"
```

---

## Task 3: Push + PR (user action)

- [ ] **Step 1: codex-attest on plan + branch**

```bash
.claude/scripts/codex-attest.sh --scope working-tree --focus docs/superpowers/plans/2026-04-19-gov-bootstrap-hardening-4-plan.md
.claude/scripts/codex-attest.sh --scope branch-diff --base origin/main --head gov-bootstrap-hardening-4
```

**Special note for H2-3**: THIS IS THE FIRST PR WHERE branch-diff SHOULD LEGITIMATELY REACH APPROVE without override. If needs-attention, it's real codex feedback on the worktree change itself — patch and retry per normal loop.

If override still needed (3 rounds unconverged), use same pattern as prior:

```bash
.claude/scripts/attest-override.sh gov-bootstrap-hardening-4 "reason"
```

- [ ] **Step 2: Push + PR**

```bash
git push -u origin gov-bootstrap-hardening-4
gh pr create --base main --head gov-bootstrap-hardening-4 \
  --title "gov-bootstrap-hardening-4: H2-3 branch-diff worktree real review" \
  --body-file /tmp/h4-pr-body.md
```

- [ ] **Step 3: User posts verdict + merges**

Same pattern as #17/#18/#19/#20.

---

## Self-Review

### Spec coverage

| Spec § | Task |
|---|---|
| §2 H2-3 target | Task 1 Step 3 patch body |
| §4.2 new flow pseudocode | Task 1 Step 3 patch body lines 1-11 |
| §4.3 worktree path | Task 1 Step 3 (uses `/tmp/codex-attest-wt.XXXXXX`) |
| §4.4 trap cleanup | Task 1 Step 3 patch body |
| §4.5 failure modes | covered by Task 1 Step 1 tests (success, failure, drift) + Task 1 Step 3 impl |
| §5 unit tests | Task 1 Step 1 — 4 tests written verbatim |
| §6 non-coder acceptance | Task 2 |

All spec items traced.

### Placeholder scan

- No TBD / TODO
- All bash/Python bodies concrete
- Tests runnable

### Type consistency

- `HEAD_SHA_FOR_PATCH` (from hardening-2 Task 4 patch) preserved — same variable name reused for drift check
- `WORKTREE` env name consistent in patch body
- `CODEX_ATTEST_TEST_MODE=1` env consistent with hardening-1 pattern

---

## Dependencies

Tasks 1 → 2 → 3. Single Task 1 does the core work; 2 is verification; 3 is external actions.
