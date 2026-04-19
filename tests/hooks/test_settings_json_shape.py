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


class TestBlobShaExfilDenyP1F4:
    """P1-F4: two-step blob-SHA exfil (ls-files -s → show <sha>) must fail."""
    def test_broad_git_show_allow_removed(self):
        allow = set(load()["permissions"]["allow"])
        assert "Bash(git show:*)" not in allow, \
            "broad Bash(git show:*) allow enables show <blob-sha> bypass"

    def test_git_cat_file_p_denied(self):
        deny = set(load()["permissions"]["deny"])
        assert "Bash(git cat-file -p:*)" in deny

    def test_git_ls_files_s_secret_paths_denied(self):
        deny = set(load()["permissions"]["deny"])
        for p in ["Bash(git ls-files -s *.env*)",
                  "Bash(git ls-files -s *secrets/*)",
                  "Bash(git ls-files -s *.p12*)",
                  "Bash(git ls-files -s *mobileprovision*)",
                  "Bash(git ls-files -s *GoogleService-Info.plist*)",
                  "Bash(git ls-files -s *.pem)",
                  "Bash(git ls-files -s *id_rsa*)"]:
            assert p in deny, f"missing deny: {p}"

    def test_narrow_git_show_allow_still_usable(self):
        allow = set(load()["permissions"]["allow"])
        # At least one narrow form should remain so operators can still inspect commits
        assert any(p.startswith("Bash(git show HEAD") for p in allow)


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
