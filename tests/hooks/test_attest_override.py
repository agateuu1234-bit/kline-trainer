"""Unit tests for .claude/scripts/attest-override.sh."""
import json
import os
import subprocess
from pathlib import Path
from typing import Optional


def run_override(
    repo: Path,
    target: str,
    reason: str,
    stdin: str,
    env_extra: Optional[dict] = None,
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
        # Create target file so the script reaches the tty check
        (temp_git_repo / "docs").mkdir(parents=True, exist_ok=True)
        (temp_git_repo / "docs" / "x.md").write_text("x")
        r = run_override(temp_git_repo, "docs/x.md", "reason text 10+", "OVERRIDE-CONFIRM-anything\n")
        assert r.returncode != 0
        assert "tty" in (r.stderr + r.stdout).lower()


class TestPPIDHeuristic:
    def test_reject_claude_like_parent(self, temp_git_repo, monkeypatch):
        # Force parent_cmd lookup to return "claude" via a stub
        # We set CLAUDE_OVERRIDE_TEST_PARENT_CMD to simulate
        # Create target file so the script reaches the PPID check
        (temp_git_repo / "docs").mkdir(parents=True, exist_ok=True)
        (temp_git_repo / "docs" / "x.md").write_text("x")
        r = run_override(
            temp_git_repo, "docs/x.md", "reason text 10+",
            "",
            env_extra={"CLAUDE_OVERRIDE_TEST_PARENT_CMD": "claude"},
        )
        assert r.returncode == 9 or "parent process" in (r.stderr + r.stdout).lower()

    def test_override_env_can_bypass_ppid_check(self, temp_git_repo):
        # Even with Claude-like parent, if ATTEST_OVERRIDE_CONFIRM_PARENT=1 set, proceed (still blocked by tty though)
        # Create target file so the script reaches past target check
        (temp_git_repo / "docs").mkdir(parents=True, exist_ok=True)
        (temp_git_repo / "docs" / "x.md").write_text("x")
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
