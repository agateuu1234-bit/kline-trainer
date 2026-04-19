"""H3-1: guard-env-read.sh fail-closed deny for **/.env* with allow-list for examples."""
import json
import subprocess
from pathlib import Path

from tests.hooks.conftest import run_hook


def hook_path(repo: Path) -> Path:
    return repo / ".claude/hooks/guard-env-read.sh"


def call(repo, tool_name, file_path):
    return run_hook(
        hook_path(repo),
        {"tool_name": tool_name, "tool_input": {"file_path": file_path}},
        repo,
    )


class TestEnvDenyDefault:
    def test_plain_env_denied(self, temp_git_repo):
        for tool in ("Read", "Edit", "Write"):
            r = call(temp_git_repo, tool, "backend/.env")
            assert r.returncode == 2, f"{tool} on .env should deny; got {r.returncode}"

    def test_env_local_denied(self, temp_git_repo):
        r = call(temp_git_repo, "Read", "backend/.env.local")
        assert r.returncode == 2

    def test_env_production_denied(self, temp_git_repo):
        r = call(temp_git_repo, "Read", "backend/.env.production")
        assert r.returncode == 2

    def test_compound_suffix_denied_H3F1(self, temp_git_repo):
        """The hardening-2 residual: compound suffixes fell through to allow.
        Hardening-3 must close this."""
        for path in (
            "backend/.env.local.backup",
            "backend/.env.production.local",
            "backend/.env.staging.bak",
            "backend/.env.abc123",
            "backend/.env.custom_suffix",
        ):
            r = call(temp_git_repo, "Read", path)
            assert r.returncode == 2, f"{path} MUST be denied (compound suffix); got {r.returncode}"


class TestEnvAllowList:
    def test_env_example_allowed(self, temp_git_repo):
        for tool in ("Read", "Edit", "Write"):
            r = call(temp_git_repo, tool, "backend/.env.example")
            assert r.returncode == 0, f"{tool} on .env.example should allow; got {r.returncode}"

    def test_env_sample_allowed(self, temp_git_repo):
        r = call(temp_git_repo, "Read", "backend/.env.sample")
        assert r.returncode == 0

    def test_env_template_allowed(self, temp_git_repo):
        r = call(temp_git_repo, "Read", "backend/.env.template")
        assert r.returncode == 0

    def test_env_dist_allowed(self, temp_git_repo):
        r = call(temp_git_repo, "Read", "backend/.env.dist")
        assert r.returncode == 0


class TestNonEnvPaths:
    def test_unrelated_file_allowed(self, temp_git_repo):
        r = call(temp_git_repo, "Read", "backend/app/main.py")
        assert r.returncode == 0

    def test_env_in_middle_of_name_not_matched(self, temp_git_repo):
        """File named 'environment.py' must not be treated as .env*."""
        r = call(temp_git_repo, "Read", "backend/environment.py")
        assert r.returncode == 0


class TestOtherTools:
    def test_non_read_write_tool_passed(self, temp_git_repo):
        """Bash / Grep etc. should be ignored (only Read/Edit/Write are env-gated)."""
        r = run_hook(
            hook_path(temp_git_repo),
            {"tool_name": "Bash", "tool_input": {"command": "cat backend/.env"}},
            temp_git_repo,
        )
        assert r.returncode == 0, "Non-Read/Edit/Write tools must pass (other hooks handle them)"


class TestMalformedInput:
    def test_missing_file_path(self, temp_git_repo):
        r = run_hook(
            hook_path(temp_git_repo),
            {"tool_name": "Read", "tool_input": {}},
            temp_git_repo,
        )
        assert r.returncode == 2, "Missing file_path on Read must fail-closed"
