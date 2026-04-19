# gov-bootstrap-hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the three governance gaps (G1 / G2 / R) defined in `docs/superpowers/specs/2026-04-18-gov-bootstrap-hardening-design.md` as concrete files + tests + settings changes, so that `spec` / `plan` / `code` artifacts can no longer escape a local Claude-session adversarial-review before reaching the remote.

**Architecture:** One PreToolUse Bash hook (`guard-attest-ledger.sh`) reads a per-artifact attestation ledger (`.claude/state/attest-ledger.json`) to decide whether Claude-issued `git push` / `gh pr create` / `gh pr merge` may proceed. The ledger is writable only by two approved entrypoints: `codex-attest.sh` (on codex approve) and `attest-override.sh` (user-tty ceremony). A tightened `settings.json` permission model restores Edit/Write/Read catch-alls while blocking credential paths and all non-approved writes to `.claude/state/**`.

**Tech Stack:** bash (hooks + scripts), Python 3.11+ (pytest for hook testing), jq/python for JSON, git, gh CLI.

**Spec:** `docs/superpowers/specs/2026-04-18-gov-bootstrap-hardening-design.md` (commit `41cabb7` on `gov-bootstrap-hardening` branch)

**Branch:** `gov-bootstrap-hardening` (already created; this plan commits onto it)

---

## File structure (decomposition reference)

### Created files

- `.claude/state/.gitkeep` — directory marker
- `.claude/scripts/ledger-lib.sh` — **shared helpers** (read/write ledger, compute file blob, compute branch diff fingerprint). Sourced by hook + attest-override + codex-attest to keep logic DRY.
- `.claude/scripts/attest-override.sh` — user-tty manual override entrypoint
- `.claude/hooks/guard-attest-ledger.sh` — main attestation gate hook
- `tests/hooks/conftest.py` — pytest fixtures
- `tests/hooks/test_ledger_lib.py` — unit tests for ledger-lib.sh
- `tests/hooks/test_attest_override.py` — unit tests for attest-override.sh
- `tests/hooks/test_codex_attest_ledger_write.py` — unit tests for codex-attest.sh ledger writeback
- `tests/hooks/test_guard_attest_ledger.py` — unit tests for guard-attest-ledger.sh
- `tests/hooks/test_pre_commit_state_block.py` — unit tests for pre-commit-diff-scan.sh extension

### Modified files

- `.gitignore` — add `.claude/state/*` with `.gitkeep` exception
- `.claude/scripts/codex-attest.sh` — add `--scope branch-diff`, add ledger writeback on approve
- `.claude/hooks/pre-commit-diff-scan.sh` — add block for staged state files
- `.claude/settings.json` — full permission + hook registration update (last, when all dependencies exist)
- `~/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory/project_plan0b_naming_informal.md` → rename to `project_gov_bootstrap_naming.md` + rewrite
- `~/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory/feedback_codex_review_direction_fallback.md` — text ref update
- `~/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory/feedback_post_bootstrap_audit_findings.md` — text ref update
- `~/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory/MEMORY.md` — index update
- `docs/superpowers/plans/2026-04-18-claude-md-reset-plan.md` — text ref update
- `docs/superpowers/specs/2026-04-17-claude-md-reset-design.md` — text ref update

### Not touched

- `docs/superpowers/plans/2026-04-18-plan-0a-v3-split.md` — already reordered during brainstorm stage (stays untracked on this branch; resumed post-merge)
- GitHub remote history (PR #14, merged commits) — untouched per spec R
- `.github/workflows/codex-review-verify.yml` — out of scope (server-side belongs to hardening-3)

---

## Task 0: pytest test-harness setup

Before any other task can run, tests need a pytest target in the repo.

**Files:**
- Create: `tests/hooks/__init__.py` (empty)
- Create: `tests/hooks/conftest.py`
- Create: `requirements-dev.txt` (if not exists) with `pytest>=7.4`
- Create: `pytest.ini` (if not exists)

- [ ] **Step 1: Check if pytest is already set up**

```bash
test -f pytest.ini && echo "pytest.ini exists" || echo "need to create"
test -f requirements-dev.txt && cat requirements-dev.txt || echo "need to create"
pip show pytest >/dev/null 2>&1 && echo "pytest installed" || echo "need to install"
```

Expected: one of the two states. If pytest+pytest.ini exist, skip Step 2/3.

- [ ] **Step 2: Create pytest.ini**

```ini
[pytest]
testpaths = tests
python_files = test_*.py
python_classes = Test*
python_functions = test_*
```

- [ ] **Step 3: Create requirements-dev.txt (if missing) and install**

```
pytest>=7.4
```

```bash
pip install -r requirements-dev.txt
```

Expected: `pytest --version` prints `pytest 7.4+` or later.

- [ ] **Step 4: Create tests/hooks/__init__.py (empty file)**

```bash
mkdir -p tests/hooks
touch tests/hooks/__init__.py
```

- [ ] **Step 5: Create tests/hooks/conftest.py**

```python
"""Shared fixtures for hooks unit tests."""
import json
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def temp_git_repo(tmp_path: Path) -> Path:
    """Create a temp git repo with .claude/state/ scaffolding."""
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "config", "user.email", "test@local"], cwd=tmp_path, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=tmp_path, check=True)
    state_dir = tmp_path / ".claude" / "state"
    state_dir.mkdir(parents=True)
    (state_dir / ".gitkeep").touch()
    # Copy scripts/hooks under test into the temp repo so paths match.
    for rel in [".claude/scripts/ledger-lib.sh", ".claude/scripts/codex-attest.sh",
                ".claude/scripts/attest-override.sh",
                ".claude/hooks/guard-attest-ledger.sh",
                ".claude/hooks/pre-commit-diff-scan.sh"]:
        src = REPO_ROOT / rel
        if src.exists():
            dst = tmp_path / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(src.read_bytes())
            dst.chmod(0o755)
    return tmp_path


@pytest.fixture
def ledger_path(temp_git_repo: Path) -> Path:
    return temp_git_repo / ".claude" / "state" / "attest-ledger.json"


@pytest.fixture
def override_log_path(temp_git_repo: Path) -> Path:
    return temp_git_repo / ".claude" / "state" / "attest-override-log.jsonl"


def run_hook(hook_path: Path, stdin_json: dict, cwd: Path) -> subprocess.CompletedProcess:
    """Invoke a hook script with stdin JSON; return CompletedProcess."""
    return subprocess.run(
        ["bash", str(hook_path)],
        input=json.dumps(stdin_json),
        capture_output=True,
        text=True,
        cwd=cwd,
    )
```

- [ ] **Step 6: Smoke-run pytest to verify discovery**

```bash
pytest tests/hooks -q
```

Expected: `no tests ran` or `collected 0 items` (no tests yet). Exit code 5 (no tests collected) is acceptable.

- [ ] **Step 7: Commit**

```bash
git add tests/hooks/__init__.py tests/hooks/conftest.py pytest.ini requirements-dev.txt
git commit -m "test(hooks): pytest harness + fixtures for attestation hook tests"
```

---

## Task 1: .gitignore + .claude/state/.gitkeep scaffolding

Addresses spec §2.1 + R3-F2 (state files must not enter git).

**Files:**
- Modify: `.gitignore`
- Create: `.claude/state/.gitkeep` (already exists per conftest assumption; verify)

- [ ] **Step 1: Confirm `.claude/state/.gitkeep` exists**

```bash
ls -la .claude/state/.gitkeep || (mkdir -p .claude/state && touch .claude/state/.gitkeep)
```

Expected: the file exists (possibly create it if not).

- [ ] **Step 2: Append .gitignore entries**

Edit `.gitignore`, append at end:

```
# gov-bootstrap-hardening: keep local attestation state out of git
.claude/state/*
!.claude/state/.gitkeep
```

- [ ] **Step 3: Verify no tracked state files and .gitkeep still tracked**

```bash
git check-ignore -v .claude/state/attest-ledger.json
git check-ignore -v .claude/state/attest-override-log.jsonl
git check-ignore -v .claude/state/.gitkeep || echo "gitkeep is NOT ignored (correct)"
```

Expected: first two print ignore rule; third prints "NOT ignored (correct)".

- [ ] **Step 4: Commit**

```bash
git add .gitignore .claude/state/.gitkeep
git commit -m "chore(state): gitignore .claude/state/* except .gitkeep"
```

---

## Task 2: ledger-lib.sh (shared helpers)

Addresses spec §2.3 ledger schema + §2.6 codex-attest key format consistency. This library is sourced by hook + codex-attest + attest-override so all three use identical key/read/write logic.

**Files:**
- Create: `.claude/scripts/ledger-lib.sh`
- Create: `tests/hooks/test_ledger_lib.py`

- [ ] **Step 1: Write failing tests**

Create `tests/hooks/test_ledger_lib.py`:

```python
"""Unit tests for .claude/scripts/ledger-lib.sh helpers."""
import json
import subprocess
from pathlib import Path

import pytest

from tests.hooks.conftest import REPO_ROOT


def run_lib_fn(fn_name: str, args: list[str], cwd: Path) -> subprocess.CompletedProcess:
    """Source ledger-lib.sh and invoke a function, returning CompletedProcess."""
    lib = cwd / ".claude" / "scripts" / "ledger-lib.sh"
    cmd = f'set -euo pipefail; source "{lib}"; {fn_name} ' + " ".join(f'"{a}"' for a in args)
    return subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, cwd=cwd)


class TestLedgerInit:
    def test_init_creates_empty_ledger_json(self, temp_git_repo, ledger_path):
        r = run_lib_fn("ledger_init_if_missing", [], temp_git_repo)
        assert r.returncode == 0, r.stderr
        assert ledger_path.exists()
        data = json.loads(ledger_path.read_text())
        assert data == {"version": 1, "entries": {}}

    def test_init_is_idempotent(self, temp_git_repo, ledger_path):
        ledger_path.write_text(json.dumps({"version": 1, "entries": {"file:foo.md": {"blob_sha": "abc"}}}))
        r = run_lib_fn("ledger_init_if_missing", [], temp_git_repo)
        assert r.returncode == 0
        data = json.loads(ledger_path.read_text())
        assert data["entries"]["file:foo.md"]["blob_sha"] == "abc"


class TestFileEntryKey:
    def test_build_file_key(self, temp_git_repo):
        r = run_lib_fn("ledger_file_key", ["docs/plans/x.md"], temp_git_repo)
        assert r.returncode == 0
        assert r.stdout.strip() == "file:docs/plans/x.md"


class TestBranchEntryKey:
    def test_build_branch_key(self, temp_git_repo):
        r = run_lib_fn("ledger_branch_key", ["feature-X", "d34db33f0123456789abcdef0123456789abcdef"], temp_git_repo)
        assert r.returncode == 0
        assert r.stdout.strip() == "branch:feature-X@d34db33f0123456789abcdef0123456789abcdef"


class TestLedgerWriteFile:
    def test_write_file_entry(self, temp_git_repo, ledger_path):
        run_lib_fn("ledger_init_if_missing", [], temp_git_repo)
        r = run_lib_fn("ledger_write_file",
                       ["docs/x.md", "abc123", "2026-04-19T00:00:00Z", "sha256:deadbeef", "1"],
                       temp_git_repo)
        assert r.returncode == 0, r.stderr
        data = json.loads(ledger_path.read_text())
        e = data["entries"]["file:docs/x.md"]
        assert e["kind"] == "file"
        assert e["blob_sha"] == "abc123"
        assert e["attest_time_utc"] == "2026-04-19T00:00:00Z"
        assert e["verdict_digest"] == "sha256:deadbeef"
        assert e["codex_round"] == 1


class TestLedgerWriteBranch:
    def test_write_branch_entry(self, temp_git_repo, ledger_path):
        run_lib_fn("ledger_init_if_missing", [], temp_git_repo)
        r = run_lib_fn("ledger_write_branch",
                       ["feature-X", "d34db33f", "origin/main", "sha256:diff",
                        "2026-04-19T00:00:00Z", "sha256:verdict", "1"],
                       temp_git_repo)
        assert r.returncode == 0, r.stderr
        data = json.loads(ledger_path.read_text())
        e = data["entries"]["branch:feature-X@d34db33f"]
        assert e["kind"] == "branch"
        assert e["head_sha"] == "d34db33f"
        assert e["base"] == "origin/main"
        assert e["diff_fingerprint"] == "sha256:diff"


class TestLedgerLookupFile:
    def test_lookup_existing_returns_blob(self, temp_git_repo, ledger_path):
        ledger_path.write_text(json.dumps({
            "version": 1,
            "entries": {"file:x.md": {"kind": "file", "blob_sha": "abc123"}},
        }))
        r = run_lib_fn("ledger_get_file_blob", ["x.md"], temp_git_repo)
        assert r.returncode == 0
        assert r.stdout.strip() == "abc123"

    def test_lookup_missing_returns_empty(self, temp_git_repo, ledger_path):
        ledger_path.write_text(json.dumps({"version": 1, "entries": {}}))
        r = run_lib_fn("ledger_get_file_blob", ["x.md"], temp_git_repo)
        assert r.returncode == 0
        assert r.stdout.strip() == ""


class TestLedgerLookupBranch:
    def test_lookup_returns_fingerprint(self, temp_git_repo, ledger_path):
        ledger_path.write_text(json.dumps({
            "version": 1,
            "entries": {"branch:feat@d34db33f": {
                "kind": "branch",
                "diff_fingerprint": "sha256:diff",
            }},
        }))
        r = run_lib_fn("ledger_get_branch_fingerprint", ["feat", "d34db33f"], temp_git_repo)
        assert r.returncode == 0
        assert r.stdout.strip() == "sha256:diff"


class TestComputeFileBlob:
    def test_compute_blob_of_staged_path(self, temp_git_repo):
        f = temp_git_repo / "hello.md"
        f.write_text("hello world\n")
        subprocess.run(["git", "add", "hello.md"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "x"], cwd=temp_git_repo, check=True)
        r = run_lib_fn("ledger_compute_file_blob_at_ref", ["HEAD", "hello.md"], temp_git_repo)
        assert r.returncode == 0
        # `git hash-object hello.md` and tree blob should match
        expected = subprocess.run(
            ["git", "hash-object", "hello.md"],
            cwd=temp_git_repo, capture_output=True, text=True, check=True,
        ).stdout.strip()
        assert r.stdout.strip() == expected


class TestComputeBranchDiffFingerprint:
    def test_fingerprint_is_stable(self, temp_git_repo):
        # Make a branch with a known diff
        subprocess.run(["git", "commit", "--allow-empty", "-qm", "init"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        (temp_git_repo / "new.txt").write_text("new\n")
        subprocess.run(["git", "add", "new.txt"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "add"], cwd=temp_git_repo, check=True)
        r1 = run_lib_fn("ledger_compute_branch_fingerprint", ["master", "feat"], temp_git_repo)
        r2 = run_lib_fn("ledger_compute_branch_fingerprint", ["master", "feat"], temp_git_repo)
        assert r1.returncode == 0 and r2.returncode == 0
        assert r1.stdout.strip() == r2.stdout.strip()
        assert r1.stdout.strip().startswith("sha256:")
```

- [ ] **Step 2: Run tests — expect failures**

```bash
pytest tests/hooks/test_ledger_lib.py -q
```

Expected: every test FAILs with "No such file or directory: .../ledger-lib.sh" (script doesn't exist yet).

- [ ] **Step 3: Implement `.claude/scripts/ledger-lib.sh`**

```bash
#!/usr/bin/env bash
# ledger-lib.sh — shared helpers for attest ledger + override log.
# Sourced (not executed directly) by hook + codex-attest.sh + attest-override.sh.

# All functions operate relative to repo root (cwd).
: "${LEDGER_PATH:=.claude/state/attest-ledger.json}"
: "${OVERRIDE_LOG_PATH:=.claude/state/attest-override-log.jsonl}"

ledger_init_if_missing() {
    if [ ! -f "$LEDGER_PATH" ]; then
        mkdir -p "$(dirname "$LEDGER_PATH")"
        printf '%s\n' '{"version":1,"entries":{}}' > "$LEDGER_PATH"
    fi
}

ledger_file_key() {
    # $1 = relative path
    printf 'file:%s\n' "$1"
}

ledger_branch_key() {
    # $1 = branch name, $2 = head sha
    printf 'branch:%s@%s\n' "$1" "$2"
}

ledger_write_file() {
    # args: <relpath> <blob_sha> <attest_time_utc> <verdict_digest> <codex_round>
    local key; key=$(ledger_file_key "$1")
    ledger_init_if_missing
    python3 - "$LEDGER_PATH" "$key" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
p, key, blob, t, digest, rnd = sys.argv[1:7]
d = json.load(open(p))
d["entries"][key] = {
    "kind": "file",
    "blob_sha": blob,
    "attest_time_utc": t,
    "verdict_digest": digest,
    "codex_round": int(rnd),
}
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
}

ledger_write_branch() {
    # args: <branch> <head_sha> <base> <diff_fingerprint> <attest_time_utc> <verdict_digest> <codex_round>
    local key; key=$(ledger_branch_key "$1" "$2")
    ledger_init_if_missing
    python3 - "$LEDGER_PATH" "$key" "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import json, sys
p, key, branch, head, base, fp, t, digest, rnd = sys.argv[1:10]
d = json.load(open(p))
d["entries"][key] = {
    "kind": "branch",
    "branch": branch,
    "head_sha": head,
    "base": base,
    "diff_fingerprint": fp,
    "attest_time_utc": t,
    "verdict_digest": digest,
    "codex_round": int(rnd),
}
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
}

ledger_get_file_blob() {
    # $1 = relpath; prints blob_sha or empty string if missing
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" <<'PY'
import json, sys
p, relpath = sys.argv[1:3]
try:
    d = json.load(open(p))
except Exception:
    print("")
    sys.exit(0)
e = d.get("entries", {}).get(f"file:{relpath}")
print(e.get("blob_sha", "") if e else "")
PY
}

ledger_get_branch_fingerprint() {
    # args: <branch> <head_sha>; prints diff_fingerprint or empty
    [ -f "$LEDGER_PATH" ] || return 0
    python3 - "$LEDGER_PATH" "$1" "$2" <<'PY'
import json, sys
p, branch, head = sys.argv[1:4]
try:
    d = json.load(open(p))
except Exception:
    print("")
    sys.exit(0)
e = d.get("entries", {}).get(f"branch:{branch}@{head}")
print(e.get("diff_fingerprint", "") if e else "")
PY
}

ledger_compute_file_blob_at_ref() {
    # args: <ref> <relpath>; prints blob sha from git ls-tree
    git ls-tree "$1" -- "$2" 2>/dev/null | awk '{print $3}'
}

ledger_compute_branch_fingerprint() {
    # args: <base-ref> <head-ref>; prints sha256 of canonical diff
    local diff_output
    diff_output=$(git diff --no-color --no-ext-diff "$1...$2" 2>/dev/null) || return 1
    local sha
    sha=$(printf '%s' "$diff_output" | shasum -a 256 | awk '{print $1}')
    printf 'sha256:%s\n' "$sha"
}
```

- [ ] **Step 4: Run tests — expect all pass**

```bash
chmod +x .claude/scripts/ledger-lib.sh
pytest tests/hooks/test_ledger_lib.py -q
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add .claude/scripts/ledger-lib.sh tests/hooks/test_ledger_lib.py
git commit -m "feat(ledger-lib): shared helpers for attest ledger + fingerprint computation"
```

---

## Task 3: attest-override.sh (user-tty override ceremony)

Addresses spec §2.5 — user-tty ceremony + PPID heuristic + nonce + audit log.

**Files:**
- Create: `.claude/scripts/attest-override.sh`
- Create: `tests/hooks/test_attest_override.py`

- [ ] **Step 1: Write failing tests**

Create `tests/hooks/test_attest_override.py`:

```python
"""Unit tests for .claude/scripts/attest-override.sh."""
import json
import os
import subprocess
from pathlib import Path


def run_override(
    repo: Path,
    target: str,
    reason: str,
    stdin: str,
    env_extra: dict | None = None,
    use_pty: bool = False,
) -> subprocess.CompletedProcess:
    env = {**os.environ, **(env_extra or {})}
    cmd = ["bash", str(repo / ".claude/scripts/attest-override.sh"), target, reason]
    if use_pty:
        # Minimal PTY harness; pexpect optional, prefer script(1) wrapper.
        wrapped = ["script", "-q", "/dev/null", *cmd]
        return subprocess.run(wrapped, input=stdin, capture_output=True, text=True, cwd=repo, env=env)
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True, cwd=repo, env=env)


class TestTTYRequirement:
    def test_reject_when_stdin_is_pipe(self, temp_git_repo):
        # Pipe stdin → not a tty → [ -t 0 ] fails → exit non-zero
        r = run_override(temp_git_repo, "docs/x.md", "reason text 10+", "OVERRIDE-CONFIRM-anything\n")
        assert r.returncode != 0
        assert "tty" in (r.stderr + r.stdout).lower()


class TestPPIDHeuristic:
    def test_reject_claude_like_parent(self, temp_git_repo, monkeypatch):
        # Force parent_cmd lookup to return "claude" via a stub
        # We set CLAUDE_OVERRIDE_TEST_PARENT_CMD to simulate
        r = run_override(
            temp_git_repo, "docs/x.md", "reason text 10+",
            "",
            env_extra={"CLAUDE_OVERRIDE_TEST_PARENT_CMD": "claude"},
        )
        assert r.returncode == 9 or "parent process" in (r.stderr + r.stdout).lower()

    def test_override_env_can_bypass_ppid_check(self, temp_git_repo):
        # Even with Claude-like parent, if ATTEST_OVERRIDE_CONFIRM_PARENT=1 set, proceed (still blocked by tty though)
        r = run_override(
            temp_git_repo, "docs/x.md", "reason text 10+",
            "",
            env_extra={
                "CLAUDE_OVERRIDE_TEST_PARENT_CMD": "claude",
                "ATTEST_OVERRIDE_CONFIRM_PARENT": "1",
            },
        )
        # tty check still fails → non-zero; but NOT with parent-process error
        assert r.returncode != 0
        assert "parent process" not in (r.stderr + r.stdout).lower() or "tty" in (r.stderr + r.stdout).lower()


class TestReasonLengthMinimum:
    def test_reject_short_reason(self, temp_git_repo):
        r = run_override(temp_git_repo, "docs/x.md", "short", "")
        assert r.returncode != 0
        assert "reason" in (r.stderr + r.stdout).lower()


class TestMissingTarget:
    def test_reject_missing_target(self, temp_git_repo):
        r = run_override(temp_git_repo, "does/not/exist.md", "legit reason text", "")
        assert r.returncode != 0
        assert "not found" in (r.stderr + r.stdout).lower() or "no such" in (r.stderr + r.stdout).lower()
```

- [ ] **Step 2: Run tests — expect failures**

```bash
pytest tests/hooks/test_attest_override.py -q
```

Expected: tests fail (script doesn't exist).

- [ ] **Step 3: Implement `.claude/scripts/attest-override.sh`**

```bash
#!/usr/bin/env bash
# attest-override.sh — user-tty manual override ceremony for attest ledger.
# Threat model: see spec §2.5. NOT agent-proof security; defense-in-depth only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/ledger-lib.sh"

TARGET="${1:-}"
REASON="${2:-}"

if [ -z "$TARGET" ] || [ -z "$REASON" ]; then
    echo "usage: attest-override.sh <target-file-or-branch> <reason>" >&2
    exit 2
fi

if [ "${#REASON}" -lt 10 ]; then
    echo "[attest-override] reason must be ≥10 chars (got ${#REASON})" >&2
    exit 3
fi

# Target must exist (file) OR be a valid branch ref
if [ ! -f "$TARGET" ] && ! git rev-parse --verify "$TARGET" >/dev/null 2>&1; then
    echo "[attest-override] target not found: $TARGET (neither file nor git ref)" >&2
    exit 4
fi

# PPID heuristic (R3-F1)
PARENT_CMD="${CLAUDE_OVERRIDE_TEST_PARENT_CMD:-}"
if [ -z "$PARENT_CMD" ]; then
    PARENT_CMD=$(ps -p $PPID -o comm= 2>/dev/null | tr -d ' ' || echo unknown)
fi
case "$PARENT_CMD" in
    claude|node|*claude-code*|*claude.app*|*Claude*)
        if [ "${ATTEST_OVERRIDE_CONFIRM_PARENT:-0}" != "1" ]; then
            echo "[attest-override] refuse: parent process '$PARENT_CMD' looks like Claude/agent." >&2
            echo "  If false positive, set ATTEST_OVERRIDE_CONFIRM_PARENT=1 and rerun." >&2
            exit 9
        fi
        echo "[attest-override] WARN: bypassing parent-process check via ATTEST_OVERRIDE_CONFIRM_PARENT=1" >&2
        ;;
esac

# TTY requirement (R3-F1 residual defense-in-depth)
if [ ! -t 0 ]; then
    echo "[attest-override] refuse: stdin is not a tty. Override must be run interactively." >&2
    exit 5
fi

# Determine kind (file vs branch) and compute sha/fingerprint
if [ -f "$TARGET" ]; then
    KIND="file"
    BLOB_SHA=$(git hash-object "$TARGET")
    SHORT=$(printf '%s' "$BLOB_SHA" | cut -c1-7)
    DETAIL_SHA="$BLOB_SHA"
else
    KIND="branch"
    HEAD_SHA=$(git rev-parse "$TARGET")
    SHORT=$(printf '%s' "$HEAD_SHA" | cut -c1-7)
    DETAIL_SHA="$HEAD_SHA"
fi

printf 'Override target (%s): %s\n' "$KIND" "$TARGET"
printf '  sha: %s\n' "$DETAIL_SHA"
printf '  reason: %s\n' "$REASON"
printf 'Type "OVERRIDE-CONFIRM-%s" to authorize: ' "$SHORT"
IFS= read -r ANS
if [ "$ANS" != "OVERRIDE-CONFIRM-${SHORT}" ]; then
    echo "[attest-override] confirm string mismatch; aborting." >&2
    exit 6
fi

# Write audit log entry (append-only)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_USER=$(git config user.email 2>/dev/null || echo "unknown")
AUDIT_LOG="${OVERRIDE_LOG_PATH}"
mkdir -p "$(dirname "$AUDIT_LOG")"
LOG_ENTRY=$(python3 - "$TARGET" "$KIND" "$DETAIL_SHA" "$REASON" "$GIT_USER" "$PARENT_CMD" "$NOW" <<'PY'
import json, sys
t, k, sha, reason, user, parent, now = sys.argv[1:8]
print(json.dumps({
    "time_utc": now,
    "target": t, "kind": k,
    "blob_or_head_sha": sha,
    "reason": reason,
    "git_user": user,
    "parent_cmd": parent,
    "actor": "manual-cli",
}, sort_keys=True))
PY
)
printf '%s\n' "$LOG_ENTRY" >> "$AUDIT_LOG"
LINE_NO=$(wc -l < "$AUDIT_LOG" | tr -d ' ')

# Write override ledger entry
ledger_init_if_missing
if [ "$KIND" = "file" ]; then
    KEY=$(ledger_file_key "$TARGET")
else
    KEY=$(ledger_branch_key "$TARGET" "$DETAIL_SHA")
fi
python3 - "$LEDGER_PATH" "$KEY" "$KIND" "$DETAIL_SHA" "$REASON" "$NOW" "$LINE_NO" <<'PY'
import json, sys
p, key, kind, sha, reason, now, ln = sys.argv[1:8]
d = json.load(open(p))
d["entries"][key] = {
    "kind": kind,
    "override": True,
    "override_reason": reason,
    "override_time_utc": now,
    "audit_log_line": int(ln),
    "blob_or_head_sha_at_override": sha,
}
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY

echo "[attest-override] OVERRIDE RECORDED: target=$TARGET kind=$KIND log_line=$LINE_NO"
```

- [ ] **Step 4: Run tests — expect pass**

```bash
chmod +x .claude/scripts/attest-override.sh
pytest tests/hooks/test_attest_override.py -q
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add .claude/scripts/attest-override.sh tests/hooks/test_attest_override.py
git commit -m "feat(attest-override): user-tty ceremony with PPID heuristic + audit log"
```

---

## Task 4: codex-attest.sh branch-diff mode + ledger writeback

Addresses spec §2.6 — new `--scope branch-diff` mode, ledger writeback on approve with correct key format.

**Files:**
- Modify: `.claude/scripts/codex-attest.sh`
- Create: `tests/hooks/test_codex_attest_ledger_write.py`

- [ ] **Step 1: Read current codex-attest.sh**

```bash
cat .claude/scripts/codex-attest.sh
```

Expected: shows existing script (~52 lines) with `exec node ...` at end.

- [ ] **Step 2: Write failing tests for ledger writeback**

Create `tests/hooks/test_codex_attest_ledger_write.py`:

```python
"""Unit tests for codex-attest.sh --scope branch-diff + ledger writeback.

Note: These tests mock the codex-companion invocation by stubbing node.
"""
import json
import os
import subprocess
from pathlib import Path


def make_node_stub(repo: Path, verdict: dict):
    """Install a shell stub at ~/.claude/.../codex-companion.mjs path that prints verdict JSON."""
    stub_dir = repo / "stubs"
    stub_dir.mkdir(exist_ok=True)
    stub = stub_dir / "node"
    stub.write_text(f"""#!/usr/bin/env bash
# Stub for codex-companion. Emit verdict then exit.
cat <<'EOF'
{json.dumps(verdict)}
EOF
exit 0
""")
    stub.chmod(0o755)
    return stub


class TestCodexAttestFileModeLedgerWrite:
    def test_file_approve_writes_file_entry(self, temp_git_repo, ledger_path, monkeypatch):
        # create a focus file and commit
        f = temp_git_repo / "focus.md"
        f.write_text("content\n")
        subprocess.run(["git", "add", "focus.md"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "x"], cwd=temp_git_repo, check=True)

        stub = make_node_stub(temp_git_repo, {"verdict": "approve"})
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}"}

        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "working-tree", "--focus", "focus.md"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        # Script exits 0 on approve + ledger write
        assert r.returncode == 0, r.stderr
        data = json.loads(ledger_path.read_text())
        assert "file:focus.md" in data["entries"]
        assert data["entries"]["file:focus.md"]["blob_sha"]


class TestCodexAttestBranchDiffMode:
    def test_branch_approve_writes_branch_entry_with_head_sha(self, temp_git_repo, ledger_path):
        subprocess.run(["git", "commit", "--allow-empty", "-qm", "init"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "branch", "-M", "main"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        (temp_git_repo / "f").write_text("x\n")
        subprocess.run(["git", "add", "f"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "m"], cwd=temp_git_repo, check=True)

        # Fake remote via: treat "main" local as "origin/main" for this test with env tweak
        subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "main"],
                       cwd=temp_git_repo, check=True)

        stub = make_node_stub(temp_git_repo, {"verdict": "approve"})
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}"}

        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "branch-diff", "--base", "origin/main", "--head", "feat"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        assert r.returncode == 0, r.stderr
        head_sha = subprocess.run(["git", "rev-parse", "feat"],
                                  cwd=temp_git_repo, capture_output=True, text=True).stdout.strip()
        key = f"branch:feat@{head_sha}"
        data = json.loads(ledger_path.read_text())
        assert key in data["entries"], f"expected key {key} in {list(data['entries'])}"
        e = data["entries"][key]
        assert e["head_sha"] == head_sha
        assert e["base"] == "origin/main"
        assert e["diff_fingerprint"].startswith("sha256:")

    def test_branch_without_head_arg_errors(self, temp_git_repo):
        stub = make_node_stub(temp_git_repo, {"verdict": "approve"})
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}"}
        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "branch-diff", "--base", "origin/main"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        assert r.returncode != 0


class TestCodexAttestNeedsAttentionNoWrite:
    def test_needs_attention_verdict_leaves_ledger_untouched(self, temp_git_repo, ledger_path):
        f = temp_git_repo / "focus.md"
        f.write_text("content\n")
        subprocess.run(["git", "add", "focus.md"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "x"], cwd=temp_git_repo, check=True)

        stub = make_node_stub(temp_git_repo, {"verdict": "needs-attention"})
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}"}

        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "working-tree", "--focus", "focus.md"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        # non-zero exit on needs-attention
        assert r.returncode != 0
        # ledger should not have focus.md entry
        if ledger_path.exists():
            data = json.loads(ledger_path.read_text())
            assert "file:focus.md" not in data.get("entries", {})
```

- [ ] **Step 3: Run tests — expect failures**

```bash
pytest tests/hooks/test_codex_attest_ledger_write.py -q
```

- [ ] **Step 4: Rewrite `.claude/scripts/codex-attest.sh`**

Replace entire file:

```bash
#!/usr/bin/env bash
# codex-attest.sh
# Local wrapper around codex-companion adversarial-review for spec/plan/branch stage.
# On approve → write attest ledger entry (file or branch key).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/ledger-lib.sh"

DRY_RUN=false
SCOPE="working-tree"
FOCUS=""
BASE=""
HEAD_BR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --head-sha)
            echo "[codex-attest] ERROR: head SHA auto-computed, do not pass --head-sha" >&2
            exit 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --scope) SCOPE="$2"; shift 2 ;;
        --focus) FOCUS="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --head) HEAD_BR="$2"; shift 2 ;;
        --target) shift 2 ;;
        *) FOCUS="$FOCUS $1"; shift ;;
    esac
done

if [ "$SCOPE" = "branch-diff" ] && [ -z "$HEAD_BR" ]; then
    echo "[codex-attest] ERROR: --scope branch-diff requires --head <branch>" >&2
    exit 5
fi
if [ "$SCOPE" = "branch-diff" ] && [ -z "$BASE" ]; then
    BASE="origin/main"
fi

# Locate codex-companion.mjs at pinned path
CODEX_PATH="$HOME/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_PATH" ]; then
    echo "[codex-attest] ERROR: codex-companion.mjs not at pinned path $CODEX_PATH" >&2
    exit 3
fi
PIN_FILE=".claude/scripts/codex-companion.sha256"
if [ -f "$PIN_FILE" ]; then
    expected=$(cat "$PIN_FILE")
    actual=$(shasum -a 256 "$CODEX_PATH" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo "[codex-attest] ERROR: codex-companion sha256 mismatch." >&2
        exit 4
    fi
fi

HEAD_SHA_GIT=$(git rev-parse HEAD 2>/dev/null || echo "untracked")
echo "[codex-attest] auto HEAD=$HEAD_SHA_GIT  scope=$SCOPE"

if $DRY_RUN; then
    echo "[codex-attest] DRY RUN - would execute: node $CODEX_PATH adversarial-review --wait --scope $SCOPE $FOCUS"
    exit 0
fi

# Run codex; capture stdout to both terminal and buffer so we can parse verdict.
echo "[codex-attest] invoking codex-companion"
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

# Note: node is expected to be on PATH; tests stub via PATH prefix
node "$CODEX_PATH" adversarial-review --wait --scope "$SCOPE" $FOCUS 2>&1 | tee "$TMP_OUT"
CODEX_EXIT=${PIPESTATUS[0]}

# Extract verdict JSON from stdout (codex-companion emits single JSON somewhere)
VERDICT=$(python3 - "$TMP_OUT" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
# Try to find last JSON object in output
objs = re.findall(r'\{[^{}]*"verdict"\s*:\s*"[^"]+"[^{}]*\}', text)
if not objs:
    # fallback: try parse each line as JSON
    for line in reversed(text.splitlines()):
        line=line.strip()
        if line.startswith("{") and '"verdict"' in line:
            try: print(json.loads(line)["verdict"]); sys.exit(0)
            except Exception: pass
    print("unknown"); sys.exit(0)
try:
    print(json.loads(objs[-1])["verdict"])
except Exception:
    print("unknown")
PY
)

if [ "$CODEX_EXIT" -ne 0 ]; then
    echo "[codex-attest] codex-companion exited $CODEX_EXIT; ledger not updated." >&2
    exit "$CODEX_EXIT"
fi

if [ "$VERDICT" != "approve" ]; then
    echo "[codex-attest] verdict=$VERDICT (not approve); ledger not updated." >&2
    exit 7
fi

# Approve path → write ledger
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VERDICT_DIGEST="sha256:$(shasum -a 256 "$TMP_OUT" | awk '{print $1}')"
ROUND=1  # plan-stage: always round 1; future: read from state

if [ "$SCOPE" = "working-tree" ] && [ -n "$FOCUS" ]; then
    for f in $FOCUS; do
        # Read blob from HEAD if tracked, else hash-object of working-tree
        BLOB=$(ledger_compute_file_blob_at_ref HEAD "$f")
        [ -z "$BLOB" ] && BLOB=$(git hash-object "$f")
        ledger_write_file "$f" "$BLOB" "$NOW" "$VERDICT_DIGEST" "$ROUND"
        echo "[codex-attest] ledger: file:$f blob=$BLOB"
    done
elif [ "$SCOPE" = "branch-diff" ]; then
    HEAD_SHA=$(git rev-parse "$HEAD_BR")
    FP=$(ledger_compute_branch_fingerprint "$BASE" "$HEAD_BR")
    ledger_write_branch "$HEAD_BR" "$HEAD_SHA" "$BASE" "$FP" "$NOW" "$VERDICT_DIGEST" "$ROUND"
    echo "[codex-attest] ledger: branch:$HEAD_BR@$HEAD_SHA fp=$FP"
fi

echo "[codex-attest] verdict=approve; ledger updated."
```

- [ ] **Step 5: Run tests — expect pass**

```bash
pytest tests/hooks/test_codex_attest_ledger_write.py -q
```

- [ ] **Step 6: Commit**

```bash
git add .claude/scripts/codex-attest.sh tests/hooks/test_codex_attest_ledger_write.py
git commit -m "feat(codex-attest): add --scope branch-diff + ledger writeback on approve"
```

---

## Task 5: guard-attest-ledger.sh (scenarios A / B / C with independent file discovery)

Addresses spec §2.4 + R5-F1 + R6-F3. Single hook, all three scenarios.

**Files:**
- Create: `.claude/hooks/guard-attest-ledger.sh`
- Create: `tests/hooks/test_guard_attest_ledger.py`

- [ ] **Step 1: Write failing tests (large)**

Create `tests/hooks/test_guard_attest_ledger.py`:

```python
"""Unit tests for .claude/hooks/guard-attest-ledger.sh.

Tests each scenario (A=push, B=pr create, C=pr merge) against a temp git repo
with a mock "origin" remote set up as another local bare repo.
"""
import json
import os
import subprocess
from pathlib import Path

from tests.hooks.conftest import run_hook


# Helpers
def setup_repo_with_remote(repo: Path) -> Path:
    """Create repo + a bare 'origin' sibling that repo tracks."""
    bare = repo.parent / "origin.git"
    subprocess.run(["git", "init", "--bare", "-q", str(bare)], check=True)
    subprocess.run(["git", "remote", "add", "origin", str(bare)], cwd=repo, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-qm", "init"], cwd=repo, check=True)
    subprocess.run(["git", "branch", "-M", "main"], cwd=repo, check=True)
    subprocess.run(["git", "push", "-qu", "origin", "main"], cwd=repo, check=True)
    return bare


def plan_file_at(repo: Path, rel: str, content: str) -> str:
    p = repo / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    subprocess.run(["git", "add", rel], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-qm", f"add {rel}"], cwd=repo, check=True)
    return subprocess.run(["git", "hash-object", rel],
                          cwd=repo, capture_output=True, text=True, check=True).stdout.strip()


def hook_path(repo: Path) -> Path:
    return repo / ".claude/hooks/guard-attest-ledger.sh"


class TestScenarioAGitPush:
    def test_push_with_no_plan_changes_passes(self, temp_git_repo):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        (temp_git_repo / "random.txt").write_text("noise\n")
        subprocess.run(["git", "add", "random.txt"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "x"], cwd=temp_git_repo, check=True)

        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash", "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        # code-only still requires branch-diff check; should block
        assert r.returncode != 0
        assert "branch" in (r.stderr + r.stdout).lower()

    def test_push_with_plan_change_and_no_ledger_blocks(self, temp_git_repo):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan x")
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash", "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode != 0
        assert "x.md" in (r.stderr + r.stdout) or "codex-attest" in (r.stderr + r.stdout)

    def test_push_with_plan_change_and_matching_ledger_passes_file_check(self, temp_git_repo, ledger_path):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        blob = plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan x")
        # Write matching ledger entry
        ledger_path.write_text(json.dumps({
            "version": 1,
            "entries": {"file:docs/superpowers/plans/x.md": {
                "kind": "file", "blob_sha": blob, "attest_time_utc": "now",
                "verdict_digest": "sha256:x", "codex_round": 1,
            }},
        }))
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash", "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        # File check passes but branch-diff also required → still blocked
        assert r.returncode != 0
        assert "branch" in (r.stderr + r.stdout).lower()

    def test_push_with_plan_and_branch_ledger_both_match_passes(self, temp_git_repo, ledger_path):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        blob = plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan x")
        head_sha = subprocess.run(["git", "rev-parse", "feat"],
                                  cwd=temp_git_repo, capture_output=True, text=True).stdout.strip()
        # Compute fingerprint the same way the hook will
        fp_proc = subprocess.run(
            ["bash", "-c",
             f"git diff --no-color --no-ext-diff origin/main...feat | shasum -a 256 | awk '{{print $1}}'"],
            cwd=temp_git_repo, capture_output=True, text=True, check=True)
        fp = "sha256:" + fp_proc.stdout.strip()
        ledger_path.write_text(json.dumps({
            "version": 1,
            "entries": {
                "file:docs/superpowers/plans/x.md": {
                    "kind": "file", "blob_sha": blob, "attest_time_utc": "now",
                    "verdict_digest": "sha256:x", "codex_round": 1,
                },
                f"branch:feat@{head_sha}": {
                    "kind": "branch", "head_sha": head_sha, "base": "origin/main",
                    "diff_fingerprint": fp, "attest_time_utc": "now",
                    "verdict_digest": "sha256:y", "codex_round": 1,
                },
            },
        }))
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash", "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode == 0, f"expected pass, got:\nstdout={r.stdout}\nstderr={r.stderr}"

    def test_ledger_missing_first_run_still_blocks(self, temp_git_repo):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan")
        # Ensure ledger does NOT exist
        ledger = temp_git_repo / ".claude/state/attest-ledger.json"
        if ledger.exists():
            ledger.unlink()
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash", "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode != 0
        assert "首次" in (r.stderr + r.stdout) or "initialized" in (r.stderr + r.stdout).lower()


class TestScenarioBGhPrCreate:
    def test_pr_create_without_head_arg_uses_current(self, temp_git_repo):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan")
        # simulate already-pushed: push to bare then verify hook finds the diff independently
        subprocess.run(["git", "push", "-qu", "origin", "feat"], cwd=temp_git_repo, check=True)
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "gh pr create --base main --title x --body y"}},
                     temp_git_repo)
        # Independent file discovery catches the plan change
        assert r.returncode != 0
        assert "x.md" in (r.stderr + r.stdout) or "branch" in (r.stderr + r.stdout).lower()

    def test_pr_create_with_explicit_head_arg_uses_it(self, temp_git_repo):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "other"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan")
        subprocess.run(["git", "push", "-qu", "origin", "feat"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "checkout", "-q", "main"], cwd=temp_git_repo, check=True)

        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "gh pr create --head feat --base main"}},
                     temp_git_repo)
        assert r.returncode != 0  # feat has plan without ledger


class TestScenarioCGhPrMerge:
    def test_pr_merge_requires_match_head_commit(self, temp_git_repo):
        setup_repo_with_remote(temp_git_repo)
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash", "tool_input": {"command": "gh pr merge 42 --squash"}},
                     temp_git_repo)
        assert r.returncode != 0
        assert "--match-head-commit" in (r.stderr + r.stdout)

    def test_pr_merge_with_match_head_mismatch_blocks(self, temp_git_repo, monkeypatch):
        # We would need to stub `gh pr view` to return a specific headRefOid.
        # Approach: wrap `gh` via a PATH stub that emits JSON for "pr view".
        stub_dir = temp_git_repo / "stubs"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "gh"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'case "$*" in\n'
            '  *"pr view"*) echo \'{"headRefName":"feat","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseRefName":"main"}\';; '
            '  *) exit 0;; \n'
            'esac\n'
        )
        stub.chmod(0o755)
        env_path = f"{stub.parent}:{os.environ.get('PATH', '')}"
        r = subprocess.run(
            ["bash", str(hook_path(temp_git_repo))],
            input=json.dumps({"tool_name": "Bash",
                              "tool_input": {"command": "gh pr merge 42 --match-head-commit bbbbbbbb --squash"}}),
            capture_output=True, text=True, cwd=temp_git_repo,
            env={**os.environ, "PATH": env_path},
        )
        assert r.returncode != 0
        assert ("match" in (r.stderr + r.stdout).lower() or
                "mismatch" in (r.stderr + r.stdout).lower())


class TestIgnoredCommands:
    def test_unrelated_bash_command_passes(self, temp_git_repo):
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash", "tool_input": {"command": "ls -la"}},
                     temp_git_repo)
        assert r.returncode == 0
```

- [ ] **Step 2: Run tests — expect failures**

```bash
pytest tests/hooks/test_guard_attest_ledger.py -q
```

- [ ] **Step 3: Implement `.claude/hooks/guard-attest-ledger.sh`**

```bash
#!/usr/bin/env bash
# guard-attest-ledger.sh — PreToolUse Bash hook.
# Enforces attest ledger + override ceremony before Claude-issued
# git push / gh pr create / gh pr merge reaches remote.
# See spec docs/superpowers/specs/2026-04-18-gov-bootstrap-hardening-design.md §2.4
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
. "$SCRIPT_DIR/ledger-lib.sh"

# --- Parse hook input ---
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))")
CMD=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))")
[ "$TOOL_NAME" = "Bash" ] || exit 0

block() {
    local reason="$1"
    echo "[guard-attest-ledger] BLOCK: $reason" >&2
    exit 2
}

# --- Dispatch by command prefix ---
case "$CMD" in
    "git push"*)   SCENARIO=A ;;
    "gh pr create"*) SCENARIO=B ;;
    "gh pr merge"*)  SCENARIO=C ;;
    *) exit 0 ;;
esac

# --- Ledger init (ROUND 3 fix: do NOT soft-pass on missing) ---
MISSING_INITIAL=false
if [ ! -f "$LEDGER_PATH" ]; then
    ledger_init_if_missing
    MISSING_INITIAL=true
fi

PLAN_GLOB='docs/superpowers/plans/'
SPEC_GLOB='docs/superpowers/specs/'

is_plan_or_spec_file() {
    case "$1" in
        "$PLAN_GLOB"*.md|"$SPEC_GLOB"*.md) return 0;;
        *) return 1;;
    esac
}

check_file_entries() {
    # args: <ref> <file list>
    local ref="$1"; shift
    local violations=()
    for f in "$@"; do
        is_plan_or_spec_file "$f" || continue
        local current_blob ledger_blob
        current_blob=$(ledger_compute_file_blob_at_ref "$ref" "$f")
        [ -z "$current_blob" ] && { violations+=("$f (cannot resolve at $ref)"); continue; }
        ledger_blob=$(ledger_get_file_blob "$f")
        if [ -z "$ledger_blob" ] || [ "$ledger_blob" != "$current_blob" ]; then
            violations+=("$f (blob=$current_blob, ledger=$ledger_blob)")
        fi
    done
    printf '%s\n' "${violations[@]}"
}

check_branch_entry() {
    # args: <branch> <head_sha> <base>
    local branch="$1" head="$2" base="$3"
    local fp_current fp_ledger
    fp_current=$(ledger_compute_branch_fingerprint "$base" "$head")
    fp_ledger=$(ledger_get_branch_fingerprint "$branch" "$head")
    if [ -z "$fp_ledger" ] || [ "$fp_ledger" != "$fp_current" ]; then
        echo "branch:$branch@$head mismatch (current=$fp_current, ledger=$fp_ledger)"
    fi
}

has_code_change() {
    # args: <file list>; return 0 if any file is NOT plan/spec
    for f in "$@"; do
        is_plan_or_spec_file "$f" || return 0
    done
    return 1
}

# --- Scenario A: git push ---
scenario_A() {
    # Parse refspec: `git push [options] [remote] [src[:dst]]`
    local SRC_BRANCH
    # Handle bare `git push` → current branch
    if echo "$CMD" | grep -qE '^git push[[:space:]]*$'; then
        SRC_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    else
        # Find last word that is not a flag; if contains `:`, take left side
        SRC_BRANCH=$(echo "$CMD" | awk '{
            for(i=NF;i>0;i--){
                if(substr($i,1,1)!="-"&&$i!="origin"&&$i!="push"){print $i;exit}
            }
        }')
        [ -z "$SRC_BRANCH" ] && SRC_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        # Strip src:dst → src only
        SRC_BRANCH="${SRC_BRANCH%%:*}"
        # Handle HEAD literal
        [ "$SRC_BRANCH" = "HEAD" ] && SRC_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    fi

    # Compute commits-to-push; file list of touched files
    local upstream base_ref
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || echo "")
    if [ -n "$upstream" ]; then
        base_ref="$upstream"
    else
        base_ref="origin/main"
        echo "[guard-attest-ledger] WARN: no tracked upstream; falling back to origin/main" >&2
    fi

    local files
    files=$(git diff --name-only "$base_ref..$SRC_BRANCH" 2>/dev/null) || {
        block "cannot compute diff $base_ref..$SRC_BRANCH"
    }

    # File-level checks
    local file_violations
    mapfile -t file_arr < <(printf '%s\n' "$files" | grep -v '^$')
    file_violations=$(check_file_entries "$SRC_BRANCH" "${file_arr[@]}")

    # Branch-diff check (R2-F1: push requires it when any code file touched)
    local branch_violation=""
    if has_code_change "${file_arr[@]}"; then
        local head_sha
        head_sha=$(git rev-parse "$SRC_BRANCH")
        branch_violation=$(check_branch_entry "$SRC_BRANCH" "$head_sha" "$base_ref")
    fi

    if [ -n "$file_violations" ] || [ -n "$branch_violation" ]; then
        local msg="unattested items in push:"
        [ -n "$file_violations" ] && msg="$msg\n  plan/spec:\n$file_violations"
        [ -n "$branch_violation" ] && msg="$msg\n  branch:\n$branch_violation"
        if $MISSING_INITIAL; then
            msg="$msg\n  (ledger 首次初始化 / first-run; 请先跑 codex-attest 再重试 / run codex-attest first)"
        else
            msg="$msg\n  跑: .claude/scripts/codex-attest.sh --scope working-tree --focus <file>\n  或: .claude/scripts/codex-attest.sh --scope branch-diff --head $SRC_BRANCH --base ${base_ref}"
        fi
        block "$(printf '%b' "$msg")"
    fi
    exit 0
}

# --- Scenario B: gh pr create ---
scenario_B() {
    local head base
    head=$(echo "$CMD" | grep -oE -- '--head[[:space:]]+[^[:space:]]+' | awk '{print $2}')
    [ -z "$head" ] && head=$(git rev-parse --abbrev-ref HEAD)
    base=$(echo "$CMD" | grep -oE -- '--base[[:space:]]+[^[:space:]]+' | awk '{print $2}')
    [ -z "$base" ] && base="main"

    local head_sha
    head_sha=$(git rev-parse "$head" 2>/dev/null) || block "cannot resolve head '$head'"

    # Independent PR diff (R3-F3)
    local files
    files=$(git diff --name-only "origin/$base...$head_sha" 2>/dev/null) || block "cannot compute PR diff origin/$base...$head_sha"
    mapfile -t file_arr < <(printf '%s\n' "$files" | grep -v '^$')
    local file_violations
    file_violations=$(check_file_entries "$head_sha" "${file_arr[@]}")

    local branch_violation
    branch_violation=$(check_branch_entry "$head" "$head_sha" "origin/$base")

    if [ -n "$file_violations" ] || [ -n "$branch_violation" ]; then
        local msg="unattested items in PR:"
        [ -n "$file_violations" ] && msg="$msg\n  plan/spec:\n$file_violations"
        [ -n "$branch_violation" ] && msg="$msg\n  branch:\n$branch_violation"
        msg="$msg\n  跑: .claude/scripts/codex-attest.sh --scope branch-diff --head $head --base origin/$base"
        block "$(printf '%b' "$msg")"
    fi
    exit 0
}

# --- Scenario C: gh pr merge ---
scenario_C() {
    # Extract target (first non-flag arg after "gh pr merge")
    local target
    target=$(echo "$CMD" | sed -nE 's|^gh pr merge[[:space:]]+([^-[:space:]]+).*|\1|p')
    local view_json
    if [ -n "$target" ]; then
        view_json=$(gh pr view "$target" --json headRefName,headRefOid,baseRefName 2>/dev/null) || block "gh pr view $target failed"
    else
        view_json=$(gh pr view --json headRefName,headRefOid,baseRefName 2>/dev/null) || block "gh pr view (current) failed"
    fi

    local head_ref head_oid base_ref
    head_ref=$(echo "$view_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['headRefName'])")
    head_oid=$(echo "$view_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['headRefOid'])")
    base_ref=$(echo "$view_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['baseRefName'])")

    # R2-F3: require --match-head-commit
    local match_arg
    match_arg=$(echo "$CMD" | grep -oE -- '--match-head-commit[[:space:]]+[^[:space:]]+' | awk '{print $2}')
    if [ -z "$match_arg" ]; then
        block "gh pr merge requires --match-head-commit $head_oid to avoid head-SHA race"
    fi
    if [ "$match_arg" != "$head_oid" ]; then
        block "match-head-commit mismatch: arg=$match_arg vs PR head=$head_oid"
    fi

    # File and branch checks (independent PR diff; reuse B logic via head_oid)
    local files
    files=$(git diff --name-only "origin/$base_ref...$head_oid" 2>/dev/null) || block "cannot compute merge diff origin/$base_ref...$head_oid"
    mapfile -t file_arr < <(printf '%s\n' "$files" | grep -v '^$')
    local file_violations
    file_violations=$(check_file_entries "$head_oid" "${file_arr[@]}")
    local branch_violation
    branch_violation=$(check_branch_entry "$head_ref" "$head_oid" "origin/$base_ref")

    if [ -n "$file_violations" ] || [ -n "$branch_violation" ]; then
        local msg="unattested items in merge target:"
        [ -n "$file_violations" ] && msg="$msg\n  plan/spec:\n$file_violations"
        [ -n "$branch_violation" ] && msg="$msg\n  branch:\n$branch_violation"
        block "$(printf '%b' "$msg")"
    fi
    exit 0
}

case "$SCENARIO" in
    A) scenario_A ;;
    B) scenario_B ;;
    C) scenario_C ;;
esac
```

- [ ] **Step 4: Run tests — expect pass**

```bash
chmod +x .claude/hooks/guard-attest-ledger.sh
pytest tests/hooks/test_guard_attest_ledger.py -q
```

Expected: all tests pass. If some fail, inspect test fixture or hook logic and fix.

- [ ] **Step 5: Commit**

```bash
git add .claude/hooks/guard-attest-ledger.sh tests/hooks/test_guard_attest_ledger.py
git commit -m "feat(guard-attest-ledger): enforce attestation on push/PR create/merge"
```

---

## Task 6: pre-commit-diff-scan.sh — block staging state files

Addresses spec §2.1 (R3-F2 staging block).

**Files:**
- Modify: `.claude/hooks/pre-commit-diff-scan.sh`
- Create: `tests/hooks/test_pre_commit_state_block.py`

- [ ] **Step 1: Read current hook**

```bash
cat .claude/hooks/pre-commit-diff-scan.sh
```

Identify where to insert the new check (typically at top of main logic).

- [ ] **Step 2: Write failing test**

Create `tests/hooks/test_pre_commit_state_block.py`:

```python
"""Test pre-commit-diff-scan.sh blocks staging .claude/state files."""
import json
import subprocess
from pathlib import Path

from tests.hooks.conftest import run_hook


class TestStateFileStagingBlock:
    def test_block_staging_attest_ledger(self, temp_git_repo):
        # Create and stage the file
        ledger = temp_git_repo / ".claude/state/attest-ledger.json"
        ledger.write_text('{"version":1,"entries":{}}')
        subprocess.run(["git", "add", "-f", ".claude/state/attest-ledger.json"],
                       cwd=temp_git_repo, check=True)
        r = run_hook(
            temp_git_repo / ".claude/hooks/pre-commit-diff-scan.sh",
            {"tool_name": "Bash", "tool_input": {"command": "git commit -m x"}},
            temp_git_repo,
        )
        assert r.returncode != 0
        assert "attest-ledger" in (r.stderr + r.stdout)

    def test_block_staging_override_log(self, temp_git_repo):
        log = temp_git_repo / ".claude/state/attest-override-log.jsonl"
        log.write_text('{"fake":"entry"}\n')
        subprocess.run(["git", "add", "-f", ".claude/state/attest-override-log.jsonl"],
                       cwd=temp_git_repo, check=True)
        r = run_hook(
            temp_git_repo / ".claude/hooks/pre-commit-diff-scan.sh",
            {"tool_name": "Bash", "tool_input": {"command": "git commit -m x"}},
            temp_git_repo,
        )
        assert r.returncode != 0
        assert "attest-override-log" in (r.stderr + r.stdout)

    def test_allow_unrelated_commits(self, temp_git_repo):
        (temp_git_repo / "hello.txt").write_text("hi")
        subprocess.run(["git", "add", "hello.txt"], cwd=temp_git_repo, check=True)
        r = run_hook(
            temp_git_repo / ".claude/hooks/pre-commit-diff-scan.sh",
            {"tool_name": "Bash", "tool_input": {"command": "git commit -m hello"}},
            temp_git_repo,
        )
        assert r.returncode == 0
```

- [ ] **Step 3: Run tests — expect failures**

```bash
pytest tests/hooks/test_pre_commit_state_block.py -q
```

- [ ] **Step 4: Extend `.claude/hooks/pre-commit-diff-scan.sh`**

Insert this block near the top (after initial input parse, before existing logic):

```bash
# gov-bootstrap-hardening (R3-F2): block staging local attestation state files.
STAGED=$(git diff --cached --name-only 2>/dev/null)
if echo "$STAGED" | grep -qE '^\.claude/state/(attest-ledger\.json|attest-override-log\.jsonl)$'; then
    OFFENDERS=$(echo "$STAGED" | grep -E '^\.claude/state/(attest-ledger\.json|attest-override-log\.jsonl)$')
    echo "[pre-commit-diff-scan] BLOCK: local attestation state must not be committed:" >&2
    printf '  %s\n' $OFFENDERS >&2
    echo "  (see .gitignore; unstage with: git restore --staged <file>)" >&2
    exit 2
fi
```

- [ ] **Step 5: Run tests — expect pass**

```bash
pytest tests/hooks/test_pre_commit_state_block.py -q
```

- [ ] **Step 6: Commit**

```bash
git add .claude/hooks/pre-commit-diff-scan.sh tests/hooks/test_pre_commit_state_block.py
git commit -m "feat(pre-commit-scan): block staging .claude/state/attest-* files"
```

---

## Task 7: settings.json — full permission + hook registration update

Addresses spec §2.1 (all deny additions) + G1 catch-all + R5-F1 allowlist + R5-F2 credential denies + R6-F2 git content denies + hook registration. **This is the wiring-up task; runs last.**

**Files:**
- Modify: `.claude/settings.json`
- Create: `tests/hooks/test_settings_json_shape.py`

- [ ] **Step 1: Write shape assertions test**

Create `tests/hooks/test_settings_json_shape.py`:

```python
"""Verify .claude/settings.json shape after Task 7 update."""
import json
from pathlib import Path

from tests.hooks.conftest import REPO_ROOT


SETTINGS = REPO_ROOT / ".claude/settings.json"


def load():
    return json.loads(SETTINGS.read_text())


class TestG1CatchAll:
    def test_write_edit_read_in_allow(self):
        allow = load()["permissions"]["allow"]
        for n in ("Write", "Edit", "Read"):
            assert n in allow, f"{n} (bare) should be in allow"


class TestStateAllowlist:
    def test_codex_attest_in_allow(self):
        allow = load()["permissions"]["allow"]
        assert any("codex-attest.sh" in p for p in allow)

    def test_attest_override_NOT_in_allow(self):
        allow = load()["permissions"]["allow"]
        assert not any("attest-override" in p for p in allow), \
            "attest-override.sh must be user-tty only; not allowed via Claude Bash"

    def test_state_catch_all_in_deny(self):
        deny = load()["permissions"]["deny"]
        assert "Bash(*.claude/state*)" in deny


class TestSecretDeny:
    def test_env_files_denied(self):
        deny = set(load()["permissions"]["deny"])
        for p in ["Read(**/.env)", "Edit(**/.env)", "Write(**/.env)"]:
            assert p in deny

    def test_ios_credentials_denied(self):
        deny = set(load()["permissions"]["deny"])
        for p in ["Read(**/GoogleService-Info.plist)",
                  "Read(**/*.mobileprovision)",
                  "Read(**/*.p12)"]:
            assert p in deny

    def test_npm_style_denied(self):
        deny = set(load()["permissions"]["deny"])
        for p in ["Read(**/.npmrc)", "Read(**/.netrc)", "Read(**/.pypirc)"]:
            assert p in deny


class TestGitContentBypassDenyR6F2:
    def test_git_show_secret_paths_denied(self):
        deny = set(load()["permissions"]["deny"])
        assert "Bash(git show *.env*)" in deny
        assert "Bash(git show *secrets/*)" in deny
        assert "Bash(git show *.p12*)" in deny
        assert "Bash(git show *mobileprovision*)" in deny
        assert "Bash(git show *GoogleService-Info.plist*)" in deny

    def test_git_diff_secret_paths_denied(self):
        deny = set(load()["permissions"]["deny"])
        assert "Bash(git diff *.env*)" in deny
        assert "Bash(git diff *secrets/*)" in deny

    def test_git_grep_secret_paths_denied(self):
        deny = set(load()["permissions"]["deny"])
        assert "Bash(git grep *secrets/*)" in deny


class TestHookRegistration:
    def test_guard_attest_ledger_mounted_unconditional_bash(self):
        hooks = load()["hooks"]["PreToolUse"]
        bash_matcher_groups = [g for g in hooks if g.get("matcher") == "Bash"]
        assert bash_matcher_groups
        # Some entry must reference guard-attest-ledger.sh without an `if` filter
        found = False
        for g in bash_matcher_groups:
            for h in g["hooks"]:
                cmd = h.get("command", "")
                if "guard-attest-ledger.sh" in cmd and "if" not in h:
                    found = True
        assert found, "guard-attest-ledger.sh must be mounted unconditionally on Bash PreToolUse"
```

- [ ] **Step 2: Run tests — expect failures**

```bash
pytest tests/hooks/test_settings_json_shape.py -q
```

- [ ] **Step 3: Update `.claude/settings.json`**

Read current settings.json fully. Then apply the following changes:

**In `permissions.allow`:**
- Append three new entries at the end: `"Write"`, `"Edit"`, `"Read"`
- Append: `"Bash(bash .claude/scripts/codex-attest.sh:*)"` and `"Bash(.claude/scripts/codex-attest.sh:*)"`

**In `permissions.deny`:**
- Append `Bash(*.claude/state*)` (R5-F1 allowlist catch-all)
- Append `Bash(*attest-override.sh*)` (prevent Claude bypass)
- Append credential read/edit/write denies (**/.env*, **/.npmrc, **/.netrc, **/.pypirc, **/.pgpass, **/*.p12, **/*.pfx, **/*.mobileprovision, **/GoogleService-Info.plist, **/private_keys/**, **/*_private.key, **/*_rsa, **/fastlane/Appfile, **/fastlane/Matchfile, secrets/**, **/*.pem, **/*.key, **/id_rsa*, **/.ssh/**, **/.aws/credentials*)
- Append `Bash(cat **/.env*)`, `Bash(cat **/secrets/**)`, `Bash(cat **/*.p12)`, `Bash(cat **/*.mobileprovision)`, `Bash(cat **/GoogleService-Info.plist)`, `Bash(cat **/.npmrc)`, `Bash(cat **/.netrc)`, `Bash(cat **/.pypirc)`
- Append `Bash(* > **/.env*)`, `Bash(* > **/secrets/**)`
- **R6-F2 git content denies**: `Bash(git show *.env*)`, `Bash(git show *secrets/*)`, `Bash(git show *.p12*)`, `Bash(git show *mobileprovision*)`, `Bash(git show *GoogleService-Info.plist*)`, `Bash(git show *.npmrc*)`, `Bash(git show *.netrc*)`, `Bash(git show *.pypirc*)`, `Bash(git show *fastlane/Appfile*)`, `Bash(git show *fastlane/Matchfile*)`, `Bash(git show *.pem)`, `Bash(git show *.key)`, `Bash(git show *id_rsa*)`, `Bash(git show *.ssh/*)`
- Same patterns for `Bash(git diff ...)` and `Bash(git grep ...)` and `Bash(git cat-file -p * .env*)` etc

**In `hooks.PreToolUse`:**
- Append a new matcher-Bash group (or append to existing Bash matcher) containing:
  ```json
  { "type": "command", "command": "bash .claude/hooks/guard-attest-ledger.sh", "timeout": 5 }
  ```
  (no `if` filter — applies to all Bash invocations, hook filters internally)

Use `Edit` tool to modify the file precisely. Verify JSON parses after changes:

```bash
python3 -m json.tool .claude/settings.json > /dev/null && echo "OK"
```

- [ ] **Step 4: Run all tests — expect pass**

```bash
pytest tests/hooks -q
```

Expected: full hooks test suite passes.

- [ ] **Step 5: Commit**

```bash
git add .claude/settings.json tests/hooks/test_settings_json_shape.py
git commit -m "feat(settings): wire gov-bootstrap-hardening permissions + hook registration"
```

---

## Task 8: Rename plan-0b → gov-bootstrap (memory + docs text refs)

Addresses spec §6 rename scope. **Behavior-neutral, no tests.**

**Files:**
- Rename: `~/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory/project_plan0b_naming_informal.md` → `project_gov_bootstrap_naming.md`
- Modify: `~/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory/MEMORY.md` (index line)
- Modify: `~/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory/feedback_codex_review_direction_fallback.md`
- Modify: `~/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory/feedback_post_bootstrap_audit_findings.md`
- Modify: `docs/superpowers/plans/2026-04-18-claude-md-reset-plan.md`
- Modify: `docs/superpowers/specs/2026-04-17-claude-md-reset-design.md`

- [ ] **Step 1: Enumerate candidate files with plan-0b references**

```bash
grep -rln "plan-0b\|plan0b\|Plan 0B" \
    ~/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory \
    docs/superpowers \
    2>/dev/null | sort -u
```

- [ ] **Step 2: Rename memory file and rewrite**

```bash
MEMDIR="$HOME/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory"
git mv "$MEMDIR/project_plan0b_naming_informal.md" "$MEMDIR/project_gov_bootstrap_naming.md" 2>/dev/null || \
  mv "$MEMDIR/project_plan0b_naming_informal.md" "$MEMDIR/project_gov_bootstrap_naming.md"
```

Rewrite the content (use Edit tool): change frontmatter `name` to "gov-bootstrap 命名约定"; rewrite body to state "曾用非正式名 plan-0b（2026-04-18 前），为避免与 Kline Trainer Plan 0B 编号撞车，2026-04-19 重命名为 gov-bootstrap；本次修补 PR = gov-bootstrap-hardening；后续修补递增为 gov-bootstrap-hardening-2/-3。PR #14 的远端历史 branch/commit message 不改。"

- [ ] **Step 3: Update MEMORY.md index**

Open `$MEMDIR/MEMORY.md` and change the line referencing `project_plan0b_naming_informal.md` to reference `project_gov_bootstrap_naming.md` with the updated hook ("曾用名 plan-0b → gov-bootstrap；本次修补 gov-bootstrap-hardening").

- [ ] **Step 4: Update text refs in other memory files**

For `feedback_codex_review_direction_fallback.md` and `feedback_post_bootstrap_audit_findings.md`: read, replace any body-text reference "plan-0b" with "gov-bootstrap" (keep the phrase "曾用名 plan-0b" intact where it's an explicit history note).

- [ ] **Step 5: Update docs/superpowers text refs**

For `docs/superpowers/plans/2026-04-18-claude-md-reset-plan.md` and `docs/superpowers/specs/2026-04-17-claude-md-reset-design.md`:

```bash
grep -n "plan-0b" docs/superpowers/plans/2026-04-18-claude-md-reset-plan.md docs/superpowers/specs/2026-04-17-claude-md-reset-design.md
```

Use Edit to change "plan-0b" → "gov-bootstrap" in each matching line, except historical quotes (commit messages, PR #14 title reproductions).

- [ ] **Step 6: Verify no unintended residuals**

```bash
grep -rln "plan-0b" docs/ 2>/dev/null | grep -v "plan-0a" || echo "no docs residuals"
grep -rln "plan-0b" "$HOME/.claude/projects/-Users-maziming-Coding-Prj-Kline-trainer/memory" 2>/dev/null
```

Expected: only `project_gov_bootstrap_naming.md` mentions "plan-0b" (inside the history note), nothing else.

- [ ] **Step 7: Commit docs/ changes (memory changes are outside repo)**

```bash
git add docs/superpowers/plans/2026-04-18-claude-md-reset-plan.md docs/superpowers/specs/2026-04-17-claude-md-reset-design.md
git commit -m "docs(gov-bootstrap): rename plan-0b references to gov-bootstrap in doc bodies"
```

Memory changes live in `~/.claude/projects/...` (not in this repo); they take effect for this user's Claude sessions but aren't versioned in the repo. Note this to user in handoff.

---

## Task 9: Full integration acceptance (non-coder checklist execution)

Spec §7 has 41 acceptance items. This task executes them in a guided order.

**Files:** none created; only verifications run.

- [ ] **Step 1: Run the full hooks test suite**

```bash
pytest tests/hooks -v
```

Expected: all pass.

- [ ] **Step 2: Manual acceptance #1-#7 (plan/spec attest flow)**

Walk through spec §7 items #1-#7 literally. Document outputs in a file `artifacts/acceptance/gov-bootstrap-hardening-run.md` (create if missing):

```bash
mkdir -p artifacts/acceptance
# Example for #1:
echo "## #1 plan push blocked before attest" >> artifacts/acceptance/gov-bootstrap-hardening-run.md
# ...then actually execute and paste results
```

- [ ] **Step 3: Manual acceptance #8-#11 (permission tests — G1)**

Verify Edit/Read on `docs/**` doesn't ask; Edit on CLAUDE.md still denied; Edit on settings.json still asks. Write one-line PASS/FAIL per item.

- [ ] **Step 4: Manual acceptance #12-#15 (tty override + ledger key shape)**

Run `attest-override.sh` in real tty; verify ledger + audit log written; verify key format `branch:<name>@<head_sha>`.

- [ ] **Step 5: Manual acceptance #16-#17 (rename verification)**

Run the grep from Task 8 Step 6; paste output. Verify PR #14 page still shows "plan-0b" (historical).

- [ ] **Step 6: Manual acceptance #18 (non-destructive boundary confirmation)**

Per revised #18: `jq '.hooks.PreToolUse[].matcher' .claude/settings.json` should include `"Bash"`; `grep '^set -\|from stdin\|tool_name' .claude/hooks/guard-attest-ledger.sh` shows Claude tool_use input shape. No actual merge performed.

- [ ] **Step 7: Manual acceptance #19-#23 (new scenarios: code push, bare, match-head, key parity)**

Run each scenario. #19 requires a code-only change + push expecting block; #20 `git push` bare form; #21/#22 merge without / with mismatched `--match-head-commit`; #23 round-trip of codex-attest write → hook read.

- [ ] **Step 8: Manual acceptance #24-#30 (override defense + state gitignore + Plan 0a v3 reorder)**

Follow each item. #30 verifies Plan 0a v3 plan file was reordered in brainstorm stage (already on disk; confirm `head -40 docs/superpowers/plans/2026-04-18-plan-0a-v3-split.md | grep -A 2 "Task 5"` shows codex-attest, not push).

- [ ] **Step 9: Manual acceptance #31-#41 (credential deny comprehensive)**

One by one: Read/Edit/Write on each of `.env`, `secrets/foo`, `GoogleService-Info.plist`, `.mobileprovision`, `.npmrc`, `.netrc`, `.pypirc`, `.pgpass`, `fastlane/Appfile`, `fastlane/Matchfile`. `cat`, `>`, `git show`, `git diff`, `git grep` variants on the same paths. `.env.example` should still read OK.

- [ ] **Step 10: Commit acceptance run artifact**

```bash
git add artifacts/acceptance/gov-bootstrap-hardening-run.md
git commit -m "docs(acceptance): gov-bootstrap-hardening run log (spec §7 items 1-41)"
```

---

## Task 10: Final — push + open PR + run codex-attest on branch-diff (gated by own hook)

**Files:** none (external actions).

⚠ These steps are externally visible. Only proceed after Task 9 is green.

- [ ] **Step 1: Run codex-attest on this plan file (working-tree scope)**

```bash
.claude/scripts/codex-attest.sh --scope working-tree --focus docs/superpowers/plans/2026-04-19-gov-bootstrap-hardening-plan.md
```

Expected: codex verdict=approve after ≤3 rounds → ledger writes `file:docs/superpowers/plans/2026-04-19-gov-bootstrap-hardening-plan.md`.

- [ ] **Step 2: Run codex-attest on branch diff**

```bash
.claude/scripts/codex-attest.sh --scope branch-diff --base origin/main --head gov-bootstrap-hardening
```

Expected: verdict=approve → ledger writes `branch:gov-bootstrap-hardening@<head_sha>`.

- [ ] **Step 3: Verify ledger**

```bash
python3 -m json.tool .claude/state/attest-ledger.json
```

Expected: both entries visible.

- [ ] **Step 4: Push branch** (now self-enforced by the very hook this PR implements)

```bash
git push -u origin gov-bootstrap-hardening
```

Expected: passes hook (ledger hits).

- [ ] **Step 5: Open PR**

```bash
gh pr create --base main --head gov-bootstrap-hardening \
  --title "gov-bootstrap-hardening: close G1 (Edit/Write allow regression) + G2 (Claude-session attest gate) + R (rename plan-0b)" \
  --body "$(cat <<'EOF'
## Summary

Implements `docs/superpowers/specs/2026-04-18-gov-bootstrap-hardening-design.md` (commit 41cabb7).

- **G1**: restore `Write`/`Edit`/`Read` in `.claude/settings.json` allow (reverses regression from PR #14); extensive deny for credential paths.
- **G2**: new PreToolUse hook `.claude/hooks/guard-attest-ledger.sh` + ledger `.claude/state/attest-ledger.json` forces codex:adversarial-review on spec/plan files and code branch-diff before Claude-issued `git push` / `gh pr create` / `gh pr merge`. `attest-override.sh` for user-tty ceremony.
- **R**: rename informal "plan-0b" → "gov-bootstrap" in local memory + docs/superpowers. Remote history (PR #14) untouched.

Scope explicitly EXCLUDES:
- G3 (skill pipeline enforcement) → `gov-bootstrap-hardening-2`
- Server-side required-check enforcement → `gov-bootstrap-hardening-3` (depends on OpenAI API funding)
- Same-clone non-Claude-terminal ops (see spec §1.3 coverage table)

## Codex adversarial-review rounds

- Round 1-6: see spec §10 + commits b82ce27 / 466c987 / 988c507 / 22f944a / 6729dbb / affc1cb / 41cabb7
- R6-F1 fixed (destructive acceptance test removed); R6-F2/F3 deferred as plan Tasks (this PR implements them)
- User authorized rounds 4/5/6 via brainstorming session on 2026-04-18/19

## Test plan

- [ ] `pytest tests/hooks -v` all pass
- [ ] Manual acceptance §7 #1-#41 walk-through (see artifacts/acceptance/gov-bootstrap-hardening-run.md)
- [ ] Verify main branch protection unchanged post-merge (enforce_admins=true, required checks unchanged)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 6: Verify PR gates**

```bash
gh pr checks <NEW_PR_NUMBER>
```

Expected: required checks (`codeowners-config-check`, `check-bootstrap-used-once`) green. `codex-review-verify` may be non-required and may fail on API quota; that is fine per 🅱️ fallback.

- [ ] **Step 7: Hand off to user for manual merge**

User executes `gh pr merge <N> --match-head-commit <headRefOid>` or clicks Merge in GitHub web UI after reviewing. (Per spec §6 R: "Claude 不能代替用户点 Merge".)

---

## Self-Review

### Spec coverage

| Spec section | Task(s) implementing it |
|---|---|
| §1.2 G1 Edit/Write/Read catch-all | Task 7 |
| §1.2 G2 hook + ledger | Tasks 2, 4, 5 |
| §1.2 R rename | Task 8 |
| §1.3 coverage table (non-goals) | Task 5 + Task 9 manual acceptance #18/#35 |
| §2.1 attest-override.sh | Task 3 |
| §2.1 .gitignore + .gitkeep | Task 1 |
| §2.1 pre-commit-diff-scan extension | Task 6 |
| §2.3 ledger schema | Task 2 |
| §2.4 scenarios A/B/C | Task 5 |
| §2.5 override ceremony | Task 3 |
| §2.6 codex-attest extensions | Task 4 |
| §4 error handling (all rows) | covered in Task 5 hook + Task 3 override |
| §7 acceptance #1-#41 | Task 9 |
| §9 #6 R6-F2 git content denies | Task 7 Step 3 |
| §9 #7 R6-F3 independent PR file discovery | Task 5 scenarios B/C |

All spec requirements traced to tasks.

### Placeholder scan

Scanning for "TBD", "TODO", "add appropriate", "similar to" — none found in the plan body. All test code and bash are concrete and runnable.

### Type consistency

- `ledger_file_key` / `ledger_branch_key` function names used identically in Task 2 impl and Task 4/5 callers ✓
- Ledger key format `file:<relpath>` / `branch:<name>@<head_sha>` consistent across Tasks 2, 3, 4, 5 ✓
- `attest-override.sh` signature `<target> <reason>` consistent between Task 3 tests and spec §2.5 ✓
- `ATTEST_OVERRIDE_CONFIRM_PARENT` + `CLAUDE_OVERRIDE_TEST_PARENT_CMD` env vars used identically in test (Task 3 Step 1) and impl (Task 3 Step 3) ✓

No inconsistencies found.

---

## Dependencies and ordering

- Task 0 must run first (no tests can exist without harness)
- Tasks 1, 2, 3, 4, 5, 6 depend on Task 0 only — can be executed sequentially without other dependencies
- Task 7 depends on Tasks 2, 3, 5, 6 (all scripts/hooks must exist before they're registered in settings.json)
- Task 8 is independent (doc rename) — can run anytime after Task 0
- Task 9 (acceptance) depends on Tasks 1-8
- Task 10 (push/PR) depends on Task 9
