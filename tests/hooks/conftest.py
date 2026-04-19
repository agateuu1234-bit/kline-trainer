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
                ".claude/hooks/pre-commit-diff-scan.sh",
                ".claude/hooks/stop-response-check.sh"]:
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
