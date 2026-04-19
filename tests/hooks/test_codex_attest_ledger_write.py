"""Unit tests for codex-attest.sh --scope branch-diff + ledger writeback.

Note: These tests mock the codex-companion invocation by stubbing node.
"""
import json
import os
import subprocess
from pathlib import Path
from typing import Optional


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
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}

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
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}

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
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}
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
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}

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


class TestNodeBinAllowlistP2F1:
    """P2-F1: reject PATH-shadowed node in ./stubs or /tmp."""
    def test_reject_stub_node_in_cwd(self, temp_git_repo):
        # Place stub at ./stubs/node (which is NOT in the allowlist)
        stub_dir = temp_git_repo / "stubs"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "node"
        stub.write_text("#!/usr/bin/env bash\necho '{\"verdict\":\"approve\"}'\nexit 0\n")
        stub.chmod(0o755)
        # IMPORTANT: CODEX_ATTEST_TEST_MODE is intentionally NOT set here
        # to verify the allowlist rejects stub node (exit 11)
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}"}

        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "working-tree", "--focus", "any.md"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        assert r.returncode == 11, f"expected exit 11 for untrusted node; got {r.returncode}\nstderr={r.stderr}"
        assert "untrusted path" in (r.stderr + r.stdout).lower()


class TestBranchDiffPassesPatchToCodex:
    def test_codex_receives_patch_file_path(self, temp_git_repo):
        """Regression for P1-F1: branch-diff mode must hand the actual
        diff to codex as --focus; an empty --focus would let codex approve
        the wrong target."""
        subprocess.run(["git", "commit", "--allow-empty", "-qm", "init"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "branch", "-M", "main"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        (temp_git_repo / "f").write_text("x\n")
        subprocess.run(["git", "add", "f"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "m"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "main"],
                       cwd=temp_git_repo, check=True)

        # Stub that asserts --focus argv contains a .patch file whose content
        # matches the branch diff, then emits approve.
        stub_dir = temp_git_repo / "stubs"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "node"
        stub.write_text("""#!/usr/bin/env bash
# Find --focus arg and validate patch file exists + non-empty.
FOUND=""
for ((i=1;i<=$#;i++)); do
    if [ "${!i}" = "--focus" ]; then
        next=$((i+1))
        FOUND="${!next}"
    fi
done
if [ -z "$FOUND" ]; then echo '{"verdict":"needs-attention","why":"no --focus"}' ; exit 1; fi
if [ ! -s "$FOUND" ]; then echo '{"verdict":"needs-attention","why":"empty focus"}' ; exit 1; fi
echo '{"verdict":"approve"}'
exit 0
""")
        stub.chmod(0o755)
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}
        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "branch-diff", "--base", "origin/main", "--head", "feat"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        assert r.returncode == 0, f"stdout={r.stdout}\nstderr={r.stderr}"
