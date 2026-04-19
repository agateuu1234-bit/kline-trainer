"""H3-2 a3: .claude/scripts/ack-drift.sh — user-tty cursor advancement."""
import os
import subprocess
from pathlib import Path


def run_ack(repo: Path, stdin: str = "", env_extra: dict = None) -> subprocess.CompletedProcess:
    env = {**os.environ, **(env_extra or {})}
    return subprocess.run(
        ["bash", str(repo / ".claude/scripts/ack-drift.sh")],
        input=stdin, capture_output=True, text=True, cwd=repo, env=env,
    )


def seed_drift(repo: Path, n: int):
    drift = repo / ".claude/state/skill-gate-drift.jsonl"
    drift.parent.mkdir(parents=True, exist_ok=True)
    drift.write_text("".join(f'{{"i":{i}}}\n' for i in range(n)))


def read_cursor(repo: Path) -> int:
    c = repo / ".claude/state/skill-gate-push-cursor.txt"
    if not c.exists():
        return 0
    return int(c.read_text().strip() or "0")


class TestTTYRequirement:
    def test_reject_when_stdin_is_pipe(self, temp_git_repo):
        seed_drift(temp_git_repo, 5)
        r = run_ack(temp_git_repo, stdin="ACK-DRIFT-anything\n")
        assert r.returncode != 0
        assert "tty" in (r.stderr + r.stdout).lower()


class TestPPIDHeuristic:
    def test_reject_claude_like_parent(self, temp_git_repo):
        seed_drift(temp_git_repo, 5)
        r = run_ack(temp_git_repo, env_extra={"CLAUDE_OVERRIDE_TEST_PARENT_CMD": "claude"})
        assert r.returncode == 9 or "parent process" in (r.stderr + r.stdout).lower()


class TestNothingToAck:
    def test_drift_equals_cursor_exits_zero_no_change(self, temp_git_repo):
        seed_drift(temp_git_repo, 3)
        (temp_git_repo / ".claude/state/skill-gate-push-cursor.txt").write_text("3\n")
        r = run_ack(temp_git_repo, stdin="")
        assert r.returncode == 0
        assert "nothing to ack" in (r.stderr + r.stdout).lower()
        assert read_cursor(temp_git_repo) == 3
