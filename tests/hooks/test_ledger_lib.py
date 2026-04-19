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
        subprocess.run(["git", "branch", "-M", "main"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        (temp_git_repo / "new.txt").write_text("new\n")
        subprocess.run(["git", "add", "new.txt"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "add"], cwd=temp_git_repo, check=True)
        r1 = run_lib_fn("ledger_compute_branch_fingerprint", ["main", "feat"], temp_git_repo)
        r2 = run_lib_fn("ledger_compute_branch_fingerprint", ["main", "feat"], temp_git_repo)
        assert r1.returncode == 0 and r2.returncode == 0
        assert r1.stdout.strip() == r2.stdout.strip()
        assert r1.stdout.strip().startswith("sha256:")


class TestOverrideAccessors:
    """P1-F3: guard reads override entries via these accessors."""
    def test_file_override_blob_when_entry_is_override(self, temp_git_repo, ledger_path):
        ledger_path.write_text(json.dumps({
            "version": 1,
            "entries": {"file:x.md": {
                "kind": "file", "override": True,
                "blob_or_head_sha_at_override": "abc123",
                "audit_log_line": 2,
            }},
        }))
        r = run_lib_fn("ledger_get_file_override_blob", ["x.md"], temp_git_repo)
        assert r.stdout.strip() == "abc123"

    def test_file_override_blob_empty_for_non_override_entry(self, temp_git_repo, ledger_path):
        ledger_path.write_text(json.dumps({
            "version": 1,
            "entries": {"file:x.md": {"kind": "file", "blob_sha": "abc"}},
        }))
        r = run_lib_fn("ledger_get_file_override_blob", ["x.md"], temp_git_repo)
        assert r.stdout.strip() == ""

    def test_validate_audit_log_line_ok(self, temp_git_repo, override_log_path):
        override_log_path.write_text('{"one":1}\n{"two":2}\n{"three":3}\n')
        r = run_lib_fn("ledger_validate_audit_log_line", ["2"], temp_git_repo)
        assert r.returncode == 0

    def test_validate_audit_log_line_tampered(self, temp_git_repo, override_log_path):
        override_log_path.write_text('{"one":1}\n')
        r = run_lib_fn("ledger_validate_audit_log_line", ["5"], temp_git_repo)
        assert r.returncode != 0
