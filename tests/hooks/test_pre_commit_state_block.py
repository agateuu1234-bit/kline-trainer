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
