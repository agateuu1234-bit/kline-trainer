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
    """Create repo + a bare 'origin' sibling that repo tracks.

    Uses repo.name as suffix so multiple tests in same pytest-tmp parent don't collide.
    """
    bare = repo.parent / (repo.name + "-origin.git")
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


def compute_branch_fingerprint(repo: Path, base: str, head: str) -> str:
    """Compute branch diff fingerprint exactly as ledger_compute_branch_fingerprint does.

    ledger-lib.sh captures diff into a variable (stripping trailing newlines via $(...))
    then pipes through shasum. We replicate that here so ledger entries match.
    """
    # Capture diff (stripping trailing newlines, same as bash $(...))
    diff_result = subprocess.run(
        ["git", "diff", "--no-color", "--no-ext-diff", f"{base}...{head}"],
        cwd=repo, capture_output=True, text=True,
    )
    diff_text = diff_result.stdout.rstrip("\n")
    # shasum via subprocess on the stripped text (no trailing newline added by printf '%s')
    sha_result = subprocess.run(
        ["shasum", "-a", "256"],
        input=diff_text, capture_output=True, text=True,
    )
    sha = sha_result.stdout.split()[0]
    return f"sha256:{sha}"


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
        # Compute fingerprint exactly as ledger_compute_branch_fingerprint does
        fp = compute_branch_fingerprint(temp_git_repo, "origin/main", head_sha)
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


class TestWrappedFormsP1F2:
    """P1-F2: wrapped forms of git push / gh pr commands must not bypass the hook."""
    def _setup(self, repo):
        setup_repo_with_remote(repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=repo, check=True)
        plan_file_at(repo, "docs/superpowers/plans/x.md", "plan x")

    def test_env_prefixed_git_push_blocked(self, temp_git_repo):
        self._setup(temp_git_repo)
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "env FOO=bar git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode != 0

    def test_command_prefixed_git_push_blocked(self, temp_git_repo):
        self._setup(temp_git_repo)
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "command git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode != 0

    def test_git_C_push_blocked(self, temp_git_repo):
        self._setup(temp_git_repo)
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "git -C . push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode != 0

    def test_cd_chain_git_push_blocked(self, temp_git_repo):
        self._setup(temp_git_repo)
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "cd . && git push -u origin feat"}},
                     temp_git_repo)
        # cd chain → unparseable → conservative BLOCK
        assert r.returncode != 0
        assert "parse" in (r.stderr + r.stdout).lower() or "simplif" in (r.stderr + r.stdout).lower() \
               or "x.md" in (r.stderr + r.stdout)

    def test_gh_global_flag_before_pr_merge_blocked(self, temp_git_repo):
        self._setup(temp_git_repo)
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "gh --repo foo/bar pr merge 42"}},
                     temp_git_repo)
        assert r.returncode != 0


class TestOverrideRecognitionP1F3:
    """P1-F3: guard must honor override ledger entries."""
    def test_override_file_entry_blob_match_passes(self, temp_git_repo, ledger_path, override_log_path):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        blob = plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan")
        # Compute branch fp for ledger (still required for branch check)
        head_sha = subprocess.run(["git", "rev-parse", "feat"],
                                  cwd=temp_git_repo, capture_output=True, text=True).stdout.strip()
        # Compute fingerprint exactly as ledger_compute_branch_fingerprint does
        fp = compute_branch_fingerprint(temp_git_repo, "origin/main", head_sha)

        # Write override entry for the file + normal ledger for the branch
        override_log_path.write_text('{"entry":1}\n')
        ledger_path.write_text(json.dumps({
            "version": 1,
            "entries": {
                "file:docs/superpowers/plans/x.md": {
                    "kind": "file", "override": True,
                    "blob_or_head_sha_at_override": blob,
                    "audit_log_line": 1,
                    "override_reason": "test", "override_time_utc": "now",
                },
                f"branch:feat@{head_sha}": {
                    "kind": "branch", "head_sha": head_sha, "base": "origin/main",
                    "diff_fingerprint": fp, "attest_time_utc": "now",
                    "verdict_digest": "sha256:y", "codex_round": 1,
                },
            },
        }))
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode == 0, f"expected PASS via override; stdout={r.stdout}\nstderr={r.stderr}"
        assert "OVERRIDE IN USE" in (r.stderr + r.stdout)

    def test_override_with_mismatched_audit_log_line_blocks(self, temp_git_repo, ledger_path, override_log_path):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        blob = plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan")

        override_log_path.write_text('{"entry":1}\n')  # only 1 line
        ledger_path.write_text(json.dumps({
            "version": 1,
            "entries": {"file:docs/superpowers/plans/x.md": {
                "kind": "file", "override": True,
                "blob_or_head_sha_at_override": blob,
                "audit_log_line": 99,  # claims line 99 but log has only 1
            }},
        }))
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode != 0
        assert "tamper" in (r.stderr + r.stdout).lower() or "missing" in (r.stderr + r.stdout).lower()


class TestDriftCeilingH32:
    """H3-2 a3: push is blocked when new_drift_since_last_push > DRIFT_PUSH_THRESHOLD."""

    def _setup_branch_with_ledger(self, repo, branch="feat"):
        setup_repo_with_remote(repo)
        subprocess.run(["git", "checkout", "-qb", branch], cwd=repo, check=True)
        subprocess.run(["git", "commit", "--allow-empty", "-qm", "empty"], cwd=repo, check=True)
        head_sha = subprocess.run(["git", "rev-parse", branch],
                                  cwd=repo, capture_output=True, text=True).stdout.strip()
        fp_proc = subprocess.run(
            ["bash", "-c",
             f"git diff --no-color --no-ext-diff origin/main...{branch} | shasum -a 256 | awk '{{print $1}}'"],
            cwd=repo, capture_output=True, text=True, check=True)
        fp = "sha256:" + fp_proc.stdout.strip()
        ledger = repo / ".claude/state/attest-ledger.json"
        ledger.parent.mkdir(parents=True, exist_ok=True)
        ledger.write_text(json.dumps({
            "version": 1,
            "entries": {
                f"branch:{branch}@{head_sha}": {
                    "kind": "branch", "head_sha": head_sha, "base": "origin/main",
                    "diff_fingerprint": fp, "attest_time_utc": "now",
                    "verdict_digest": "sha256:y", "codex_round": 1,
                },
            },
        }))

    def test_drift_below_threshold_passes(self, temp_git_repo):
        self._setup_branch_with_ledger(temp_git_repo)
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        drift.write_text("\n".join(f'{{"i":{i}}}' for i in range(3)) + "\n")
        (temp_git_repo / ".claude/state/skill-gate-push-cursor.txt").write_text("0\n")
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode == 0, f"expected pass; stderr={r.stderr}"

    def test_drift_above_threshold_blocks(self, temp_git_repo):
        self._setup_branch_with_ledger(temp_git_repo)
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        drift.write_text("\n".join(f'{{"i":{i}}}' for i in range(10)) + "\n")
        (temp_git_repo / ".claude/state/skill-gate-push-cursor.txt").write_text("0\n")
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode != 0
        combined = r.stderr + r.stdout
        assert "drift" in combined.lower()
        assert "ack-drift" in combined

    def test_env_override_bypasses(self, temp_git_repo):
        self._setup_branch_with_ledger(temp_git_repo)
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        drift.write_text("\n".join(f'{{"i":{i}}}' for i in range(20)) + "\n")
        env = {**os.environ, "DRIFT_PUSH_OVERRIDE": "1"}
        r = subprocess.run(
            ["bash", str(hook_path(temp_git_repo))],
            input=json.dumps({"tool_name": "Bash",
                              "tool_input": {"command": "git push -u origin feat"}}),
            capture_output=True, text=True, cwd=temp_git_repo, env=env,
        )
        assert r.returncode == 0, f"DRIFT_PUSH_OVERRIDE should bypass; stderr={r.stderr}"


class TestHeredocAttacksStillBlocked:
    """H3-3 DROPPED (codex round 3 user option A). No heredoc stripping = any heredoc
    containing git push / gh pr create / gh pr merge is caught by BLOCK_UNPARSEABLE
    substring fallback. This is the pre-hardening-3 behavior; H3-3's attempt to
    carve out false positives created more attack surface than the original bug.

    Plan 0a v3 doc-writing workaround: use Write tool for file content, not
    heredoc via Bash.

    These tests confirm heredoc-wrapped protected commands remain blocked:"""

    def test_bash_heredoc_push_blocked(self, temp_git_repo):
        cmd = """bash <<EOF
git push -u origin feat
EOF"""
        r = run_hook(
            hook_path(temp_git_repo),
            {"tool_name": "Bash", "tool_input": {"command": cmd}},
            temp_git_repo,
        )
        assert r.returncode != 0

    def test_cat_pipe_sh_heredoc_push_blocked(self, temp_git_repo):
        cmd = """cat <<'EOF' | sh
git push -u origin feat
EOF"""
        r = run_hook(
            hook_path(temp_git_repo),
            {"tool_name": "Bash", "tool_input": {"command": cmd}},
            temp_git_repo,
        )
        assert r.returncode != 0


class TestShellOpsFilterH24:
    """H2-4: refspec parser must skip shell redirect/operator tokens.

    Pre-fix behavior: `git push -u origin feat 2>&1` parses `2>&1` as src-branch,
    leading to "cannot compute diff origin/main..2>&1" BLOCK message.
    Post-fix: parser correctly extracts `feat`."""

    def test_refspec_with_2gt1_tail(self, temp_git_repo):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan x")
        r = run_hook(
            hook_path(temp_git_repo),
            {"tool_name": "Bash",
             "tool_input": {"command": "git push -u origin feat 2>&1"}},
            temp_git_repo,
        )
        # Should BLOCK (plan without ledger) but refer to 'feat', not misread '2>&1' as branch
        assert r.returncode != 0
        output = r.stderr + r.stdout
        # The block reason must not mention "2>&1" as if it were a branch
        assert "origin/main..2>&1" not in output, \
            f"parser misread 2>&1 as src-branch. Output:\n{output}"
        # Positive: message should be about the actual plan file or feat branch
        assert ("x.md" in output or
                "feat" in output.replace("feature", "")), \
            f"expected BLOCK msg to mention x.md or feat. Output:\n{output}"

    def test_refspec_with_gt_ampersand(self, temp_git_repo):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan")
        r = run_hook(
            hook_path(temp_git_repo),
            {"tool_name": "Bash",
             "tool_input": {"command": "git push -u origin feat >& /dev/null"}},
            temp_git_repo,
        )
        assert r.returncode != 0
        output = r.stderr + r.stdout
        assert ">&" not in output.split("BLOCK")[-1] if "BLOCK" in output else True
