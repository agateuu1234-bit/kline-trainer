"""H2-1: stop-response-check.sh should drift-log instead of block on first-line gate miss."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

from tests.hooks.conftest import REPO_ROOT


def make_transcript(tmp_path, entries):
    """Write a JSONL transcript at tmp_path/transcript.jsonl."""
    p = tmp_path / "transcript.jsonl"
    with p.open("w") as f:
        for entry in entries:
            f.write(json.dumps(entry) + "\n")
    return p


def run_hook(transcript_path: Path, cwd: Path) -> subprocess.CompletedProcess:
    hook = cwd / ".claude" / "hooks" / "stop-response-check.sh"
    stdin = json.dumps({"transcript_path": str(transcript_path)})
    return subprocess.run(
        ["bash", str(hook)],
        input=stdin, capture_output=True, text=True, cwd=cwd,
    )


class TestFirstLineCompliant:
    def test_skill_gate_present_exits_zero_no_drift(self, temp_git_repo, tmp_path):
        tx = make_transcript(tmp_path, [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Skill gate: superpowers:brainstorming\n\nBody."},
            ]}},
        ])
        r = run_hook(tx, temp_git_repo)
        assert r.returncode == 0
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        assert not drift.exists() or drift.stat().st_size == 0


class TestFirstLineMissing:
    def test_missing_gate_appends_drift_no_block(self, temp_git_repo, tmp_path):
        tx = make_transcript(tmp_path, [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Plan complete, now testing.\n\nBody."},
            ]}},
        ])
        r = run_hook(tx, temp_git_repo)
        assert r.returncode == 0, f"stop-hook should NOT block on drift now; stderr={r.stderr}"
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        assert drift.exists()
        lines = drift.read_text().splitlines()
        assert len(lines) == 1
        entry = json.loads(lines[0])
        assert entry["first_line"] == "Plan complete, now testing."
        assert "time_utc" in entry and "inferred_skill" in entry and "response_sha" in entry
        # H3-2 changed wording: "drift logged" -> "drift recorded" / "Drift count"
        assert ("drift recorded" in r.stderr.lower() or
                "drift count" in r.stderr.lower() or
                "skill-gate-drift" in r.stderr.lower()), \
            f"stderr should mention drift was recorded; got:\n{r.stderr}"

    def test_missing_gate_infers_last_skill_from_transcript(self, temp_git_repo, tmp_path):
        tx = make_transcript(tmp_path, [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Skill gate: superpowers:writing-plans\n\nFirst reply."},
            ]}},
            {"type": "user", "message": {"content": "ok"}},
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Body without gate.\n\nSecond reply."},
            ]}},
        ])
        r = run_hook(tx, temp_git_repo)
        assert r.returncode == 0
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        entry = json.loads(drift.read_text().splitlines()[-1])
        assert entry["inferred_skill"] == "superpowers:writing-plans"

    def test_missing_gate_no_prior_gate_defaults_exempt(self, temp_git_repo, tmp_path):
        tx = make_transcript(tmp_path, [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "No gate anywhere."},
            ]}},
        ])
        r = run_hook(tx, temp_git_repo)
        assert r.returncode == 0
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        entry = json.loads(drift.read_text().splitlines()[-1])
        assert entry["inferred_skill"] == "exempt(behavior-neutral)"


class TestDriftStderrFormatH32:
    """H3-2 a2: stderr on drift must be multi-line with drift count + inferred skill + next-action."""

    def test_stderr_contains_drift_count(self, temp_git_repo, tmp_path):
        """H3-2: stderr must show explicit drift count number (not just 'drift')."""
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        drift.parent.mkdir(parents=True, exist_ok=True)
        drift.write_text('{"first_line":"p1"}\n{"first_line":"p2"}\n{"first_line":"p3"}\n')
        tx = make_transcript(tmp_path, [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Missing gate here.\n\nBody."},
            ]}},
        ])
        r = run_hook(tx, temp_git_repo)
        assert r.returncode == 0
        combined = r.stderr + r.stdout
        # New H3-2 format: explicit "Drift count" phrase + numeric value
        assert "drift count" in combined.lower(), \
            f"H3-2 stderr must contain explicit 'drift count' phrase (new format); got:\n{combined}"
        # Multi-line format (at least 4 lines in stderr block)
        stderr_line_count = len([ln for ln in r.stderr.split("\n") if ln.strip()])
        assert stderr_line_count >= 4, \
            f"H3-2 stderr must be multi-line (>=4 lines); got {stderr_line_count} lines:\n{r.stderr}"
        # Explicit next-action capitalized/emphasized
        assert ("MUST START WITH" in combined or "NEXT RESPONSE" in combined.upper()), \
            f"H3-2 stderr must have explicit next-action instruction; got:\n{combined}"

    def test_stderr_contains_inferred_skill_hint(self, temp_git_repo, tmp_path):
        tx = make_transcript(tmp_path, [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Skill gate: superpowers:brainstorming\n\nFirst."},
            ]}},
            {"type": "user", "message": {"content": "next"}},
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Missing gate second time.\n\nBody."},
            ]}},
        ])
        r = run_hook(tx, temp_git_repo)
        combined = r.stderr + r.stdout
        assert "superpowers:brainstorming" in combined, \
            f"must mention inferred skill; got:\n{combined}"


class TestExemptBadReasonStillBlocks:
    """Regression: exempt reason outside whitelist should STILL block."""
    def test_unknown_exempt_reason_blocks(self, temp_git_repo, tmp_path):
        tx = make_transcript(tmp_path, [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Skill gate: exempt(not-in-whitelist)\n\nBody."},
            ]}},
        ])
        # Need workflow-rules.json in temp repo for exempt whitelist check
        rules_src = REPO_ROOT / ".claude/workflow-rules.json"
        rules_dst = temp_git_repo / ".claude/workflow-rules.json"
        rules_dst.parent.mkdir(parents=True, exist_ok=True)
        rules_dst.write_bytes(rules_src.read_bytes())

        r = run_hook(tx, temp_git_repo)
        # This SHOULD block: bad exempt reason is not "missing gate"
        output = json.loads(r.stdout) if r.stdout.strip() else {}
        assert output.get("decision") == "block"
        assert "whitelist" in output.get("reason", "").lower()

# === Hardening-6 Task 4: L1 block mode + L3 exempt integrity tests ===

import json
import os
import subprocess
import tempfile
import pytest

HOOK = ".claude/hooks/stop-response-check.sh"

def _run_hook(transcript_path):
    """Invoke hook with stdin JSON; return (exit_code, stdout, stderr)."""
    proc = subprocess.run(
        ["bash", HOOK],
        input=json.dumps({"transcript_path": str(transcript_path)}),
        capture_output=True, text=True, timeout=10,
    )
    return proc.returncode, proc.stdout, proc.stderr

def _write_transcript(tmp_path, assistant_text, tool_uses=None, user_text=None,
                      prior_assistant_tool_uses=None):
    """Write mock transcript JSONL. Optionally includes a preceding user message
    (needed for v31 R31 F1 user-explicit-skip tests which validate last-user-text).
    v34 R34 F1: prior_assistant_tool_uses lets tests build transcripts like
    [user prompt, assistant+tool_uses, tool_result user pseudo-turn,
     final assistant with gate] to verify hook aggregates across tool_result
     pseudo-turns correctly."""
    lines = []
    if user_text is not None:
        user_entry = {"type": "user", "message": {"content": user_text}}
        lines.append(json.dumps(user_entry))
    if prior_assistant_tool_uses:
        prior_content = []
        for tu in prior_assistant_tool_uses:
            prior_content.append({"type": "tool_use", "id": tu.get("id", "tu_prior"),
                                   "name": tu["name"], "input": tu["input"]})
        lines.append(json.dumps({"type": "assistant", "message": {"content": prior_content}}))
        # tool_result pseudo-user turn (what Anthropic transcripts actually have)
        tool_result_entry = {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": prior_assistant_tool_uses[0].get("id", "tu_prior"),
             "content": "ok"}
        ]}}
        lines.append(json.dumps(tool_result_entry))
    content = [{"type": "text", "text": assistant_text}]
    if tool_uses:
        for tu in tool_uses:
            content.append({"type": "tool_use", "name": tu["name"], "input": tu["input"]})
    entry = {"type": "assistant", "message": {"content": content}}
    lines.append(json.dumps(entry))
    tp = tmp_path / "transcript.jsonl"
    tp.write_text('\n'.join(lines) + '\n')
    return tp

def _set_enforcement_mode(mode):
    """Temporarily set workflow-rules.json enforcement_mode.
    Returns a unique backup path to avoid conflicts when nested."""
    import shutil, pathlib, uuid
    p = pathlib.Path(".claude/workflow-rules.json")
    bak = str(p) + ".bak." + uuid.uuid4().hex[:8]
    shutil.copy(p, bak)
    rules = json.loads(p.read_text())
    rules["skill_gate_policy"]["enforcement_mode"] = mode
    p.write_text(json.dumps(rules, indent=2))
    return bak

def _restore_enforcement_mode(backup):
    import shutil, pathlib
    shutil.copy(backup, backup.rsplit(".bak.", 1)[0])
    pathlib.Path(backup).unlink(missing_ok=True)

class TestL1BlockMode:
    def test_missing_first_line_block_mode_blocks(self, tmp_path):
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(tmp_path, "No gate declaration here")
            rc, stdout, stderr = _run_hook(tp)
            assert rc == 0  # hook uses JSON output for block
            assert '"decision":"block"' in stdout or '"decision": "block"' in stdout
        finally:
            _restore_enforcement_mode(bak)

    def test_missing_first_line_drift_mode_pass(self, tmp_path):
        bak = _set_enforcement_mode("drift-log")
        try:
            tp = _write_transcript(tmp_path, "No gate declaration here")
            rc, stdout, stderr = _run_hook(tp)
            assert rc == 0
            assert "skill-gate-drift" in stderr
            assert '"decision"' not in stdout  # not block
        finally:
            _restore_enforcement_mode(bak)

    def test_codex_adversarial_review_gate_regex_explicit(self, tmp_path):
        """R7 F1 regression: prove regex [a-z-]+ accepts codex:adversarial-review.
        
        Codex R7 incorrectly inferred that codex:[a-z-]+ allows only single
        hyphen-free segment. In POSIX character classes, the literal - can
        be placed at end/start of class and matches any hyphen - so
        [a-z-]+ matches adversarial-review (mix of a-z and -).
        """
        # Test the exact first-line string Task 1 requires
        for mode in ("drift-log", "block"):
            bak = _set_enforcement_mode(mode)
            try:
                tp = _write_transcript(tmp_path, "Skill gate: codex:adversarial-review\n\nText")
                rc, stdout, stderr = _run_hook(tp)
                assert rc == 0
                assert '"decision":"block"' not in stdout.replace(" ", ""), f"mode={mode} blocked 'codex:adversarial-review' - Hook 1 regex bug"
                # No skill-gate-drift WARN either (means regex matched)
                assert "skill-gate-drift" not in stderr, f"mode={mode} drift-logged 'codex:adversarial-review' - regex didn't match"
            finally:
                _restore_enforcement_mode(bak)

        # Additional sanity: raw grep test of the regex
        import subprocess as sp
        for line in [
            "Skill gate: codex:adversarial-review",
            "Skill gate: superpowers:verification-before-completion",
            "Skill gate: superpowers:requesting-code-review",
            "Skill gate: superpowers:finishing-a-development-branch",
        ]:
            r = sp.run(
                ["grep", "-qE",
                 "^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|exempt\\([a-z-]+\\))"],  # v44 R44 F1 final: H6 scope only
                input=line, capture_output=True, text=True,
            )
            assert r.returncode == 0, f"regex rejected valid gate: {line}"

    def test_valid_first_line_both_modes_pass(self, tmp_path):
        """Verify 3 legal gate forms pass Hook 1 in both modes (R6 F1 verification).

        v44 R44 F1 final: L1 scope restricted to H6 only
        (superpowers:* + codex:* + exempt(...)). Non-H6 plugins (frontend-design
        etc.) either go through superpowers:* gate as sub-skill, or register
        in skill-invoke-enforced.json with their own L2/L4/L5 contract.
        """
        gate_samples = [
            "Skill gate: superpowers:brainstorming\n\nSome text",
            "Skill gate: superpowers:writing-plans\n\ntext",
            "Skill gate: superpowers:verification-before-completion\n\ntext",
            "Skill gate: codex:adversarial-review\n\ntext",
            "Skill gate: exempt(read-only-query)\n\ntext",
            "Skill gate: exempt(behavior-neutral)\n\ntext",
        ]
        for mode in ("drift-log", "block"):
            bak = _set_enforcement_mode(mode)
            try:
                for gate in gate_samples:
                    tp = _write_transcript(tmp_path, gate)
                    rc, stdout, stderr = _run_hook(tp)
                    assert rc == 0
                    # Skill gate (non-exempt) or exempt passed whitelist → no block
                    assert '"decision":"block"' not in stdout.replace(" ", ""), f"mode={mode} gate={gate[:60]} unexpectedly blocked"
            finally:
                _restore_enforcement_mode(bak)


class TestL3ExemptIntegrityReadOnly:
    @pytest.fixture(autouse=True)
    def _block_mode_for_l3(self):
        """v45 R45 F2: L3 integrity only blocks in enforcement_mode=block."""
        bak = _set_enforcement_mode("block")
        yield
        _restore_enforcement_mode(bak)

    def test_read_only_with_read_tool_passes(self, tmp_path):
        # v51 R51 F2: Read path must be repo-relative (absolute /tmp path now blocked)
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\nLooking at a file.",
            tool_uses=[{"name": "Read", "input": {"file_path": "README.md"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_read_only_with_edit_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\nActually editing",
            tool_uses=[{"name": "Edit", "input": {"file_path": "/tmp/foo.txt", "old_string": "a", "new_string": "b"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_bash_pwd_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "pwd"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_read_only_with_bash_git_push_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git push origin main"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_bash_pipe_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git log | tee out.txt"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_find_delete_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "find . -delete"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # v30 R30 F1 regression tests: spec §3.1 R2 F2 hardening — git fully blocked
    # in read-only-query. Earlier spec diagram (pre-v30) listed git as legal,
    # which contradicted the authoritative §3.1 policy. These tests lock the
    # hardened policy so future spec drift can't silently relax it.
    def test_read_only_with_git_status_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git status"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_git_diff_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git diff HEAD~1"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_git_log_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git log --oneline"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # v41 R41 F1 regression: read-only exempt Bash cat/head/tail/wc MUST
    # reject sensitive paths (~/.ssh/id_rsa, ~/.aws/credentials, .env) and
    # repo-outside absolute paths. Previously safe_bash regex charset check
    # allowed these, and Stop hook fires AFTER Bash already ran → exempt
    # approval would let a response containing secrets be emitted.
    def test_read_only_cat_ssh_key_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "cat ~/.ssh/id_rsa"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_cat_aws_credentials_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "cat /Users/x/.aws/credentials"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_cat_dotenv_blocks(self, tmp_path):
        """Repo-relative .env files are still blocked (sensitive by name)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "cat .env"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_cat_abs_out_of_repo_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "cat /etc/passwd"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_cat_repo_relative_passes(self, tmp_path):
        """Repo-relative non-sensitive path (e.g., README.md) passes."""
        # Create a harmless file to cat
        f = Path("README.md")
        created = False
        if not f.exists():
            f.write_text("readme")
            created = True
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: exempt(read-only-query)\n\n",
                tool_uses=[{"name": "Bash", "input": {"command": "cat README.md"}}],
            )
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' not in stdout.replace(" ", "")
        finally:
            if created:
                f.unlink(missing_ok=True)

    # v45 R45 F1 regression: mode-i rescue MUST NOT rescue frontend-design
    # (or other plugin gates outside H6 scope). Attack shape: earlier
    # `Skill gate: frontend-design:web` + plugin tool_use + tool_result
    # + ungated final. Without fix: L1 rescue accepts plugin gate, Hook 2
    # H6-only regex skips plugin gate → effectively passes without H6
    # state machine or codex evidence enforcement.
    def test_block_mode_frontend_design_rescue_rejected_r45_f1(self, tmp_path):
        """Earlier frontend-design gate + tool_result + ungated final MUST
        BLOCK in block mode (rescue refuses non-H6-scoped gates)."""
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Implementation done.",
                user_text="add a form component",
            )
            lines = tp.read_text().splitlines()
            gated = json.dumps({
                "type": "assistant",
                "message": {"content": [
                    {"type": "text", "text": "Skill gate: frontend-design:web\n\ndesigning"},
                    {"type": "tool_use", "id": "tu_fd",
                     "name": "Skill",
                     "input": {"skill": "frontend-design:web"}},
                ]},
            })
            tool_result = json.dumps({
                "type": "user",
                "message": {"content": [
                    {"type": "tool_result", "tool_use_id": "tu_fd",
                     "content": "design ok"},
                ]},
            })
            new_lines = [lines[0], gated, tool_result, lines[1]]
            tp.write_text('\n'.join(new_lines) + '\n')
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' in stdout.replace(" ", ""), \
                f"frontend-design rescue bypass must block; stdout={stdout[:400]}"
        finally:
            _restore_enforcement_mode(bak)

    # v45 R45 F2 regression: L3 integrity violations MUST drift-log (not
    # block) when enforcement_mode=drift-log. Block only activates after
    # Task 9/H6.0-flip.
    def test_l3_violation_drift_logs_in_observe_mode_r45_f2(self, tmp_path):
        """drift-log mode + exempt(read-only-query) + disallowed Bash →
        drift-log entry written, NO block decision."""
        bak = _set_enforcement_mode("drift-log")
        drift_log = Path(".claude/state/skill-gate-drift.jsonl")
        drift_log.parent.mkdir(parents=True, exist_ok=True)
        before_size = drift_log.stat().st_size if drift_log.exists() else 0
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: exempt(read-only-query)\n\n",
                tool_uses=[{"name": "Bash", "input": {"command": "cat /etc/passwd"}}],
            )
            rc, stdout, _ = _run_hook(tp)
            # observe mode: no block decision, but drift record appended
            assert '"decision":"block"' not in stdout.replace(" ", ""), \
                f"drift-log mode should NOT block L3 violations; stdout={stdout[:400]}"
            # drift log should have new record with kind=l3_integrity_violation
            if drift_log.exists():
                # Use byte slicing (before_size is st_size in bytes; read_text uses char idx)
                tail = drift_log.read_bytes()[before_size:].decode()
                assert "l3_integrity_violation" in tail, \
                    f"drift log should record L3 violation; new content={tail[:400]!r}"
        finally:
            _restore_enforcement_mode(bak)

    # v43 R43 F1 regression: mode-i rescue MUST NOT rescue exempt gates.
    # Attack shape: earlier assistant with `Skill gate: exempt(read-only-query)`
    # + disallowed Bash (e.g., cat ~/.ssh/id_rsa), tool_result pseudo-user,
    # final assistant ungated. Without this fix:
    #   L1 rescue finds exempt earlier → passes L1
    #   L3 reads ungated final first_line → no exempt reason → skips validator
    #   → disallowed Bash bypasses L3 allowlist
    def test_block_mode_exempt_rescue_rejected_r43_f1(self, tmp_path):
        """Earlier exempt gate + disallowed Bash + tool_result + ungated final
        MUST BLOCK (rescue refuses exempt gates)."""
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(
                tmp_path,
                # final assistant text: no gate line
                "This run is done.",
                user_text="check things",
                prior_assistant_tool_uses=[
                    # First prior-assistant-in-turn has the exempt gate + Bash
                    # (We encode the gate text via a hack: include a text
                    # block via prior_assistant_tool_uses extension below)
                ],
            )
            # Manually overwrite transcript to add the exempt gate + Bash in
            # an earlier assistant entry, plus a tool_result pseudo-user,
            # plus the ungated final assistant (already written above).
            lines = tp.read_text().splitlines()
            # Expected order from helper: [user, ?prior_assistant+tool_result, final assistant]
            # Since prior_assistant_tool_uses=[] above, lines = [user, final_assistant].
            # Insert gated assistant + tool_result BEFORE final assistant.
            gated_assistant = json.dumps({
                "type": "assistant",
                "message": {"content": [
                    {"type": "text",
                     "text": "Skill gate: exempt(read-only-query)\n\nrunning"},
                    {"type": "tool_use", "id": "tu_bypass",
                     "name": "Bash",
                     "input": {"command": "cat /tmp/secret-evidence"}},
                ]},
            })
            tool_result_pseudo = json.dumps({
                "type": "user",
                "message": {"content": [
                    {"type": "tool_result", "tool_use_id": "tu_bypass",
                     "content": "stolen secret contents"}
                ]},
            })
            new_lines = [lines[0], gated_assistant, tool_result_pseudo, lines[1]]
            tp.write_text('\n'.join(new_lines) + '\n')
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' in stdout.replace(" ", ""), \
                f"Exempt rescue bypass must block; stdout={stdout[:400]}"
        finally:
            _restore_enforcement_mode(bak)

    # v34 R34 F1 regression: tool_result pseudo-user turn must NOT reset
    # the "current turn" — prior assistant tool_use still counts for L3.
    # Previously last_user_idx found the tool_result user turn → dropped
    # earlier assistant tool_use → read-only check passed despite side
    # effect already done in prior assistant entry.
    def test_read_only_tool_result_pseudo_turn_still_sees_prior_bash(self, tmp_path):
        """Transcript: [user, assistant with 'rm -rf /x' Bash, tool_result
        pseudo-user, final assistant gate] — the Bash tool_use MUST be
        detected and block read-only (side effect in the same turn)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            user_text="do something read-only",
            prior_assistant_tool_uses=[
                {"name": "Bash", "input": {"command": "rm -rf /tmp/x"}, "id": "tu1"},
            ],
            tool_uses=[],  # final assistant has only text (the gate line)
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", ""), \
            f"tool_result pseudo-turn must not hide prior Bash side-effect; stdout={stdout[:400]}"


class TestR53F1RepoRootRejectInHelper:
    """R53 F1 fix: _path_is_safe_for_read rejects paths that normalize to repo root."""

    @pytest.fixture(autouse=True)
    def _block_mode(self):
        bak = _set_enforcement_mode("block")
        yield
        _restore_enforcement_mode(bak)

    def test_read_only_grep_dot_path_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "secret", "path": "."}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")


class TestR53F1GrepGlob:
    """R53 F1 fix: Grep requires path; Glob unconditionally blocked in all exempt branches."""

    @pytest.fixture(autouse=True)
    def _block_mode(self):
        bak = _set_enforcement_mode("block")
        yield
        _restore_enforcement_mode(bak)

    def test_read_only_grep_without_path_blocks(self, tmp_path):
        """Gate-4 round-9 finding: use non-sensitive pattern `TODO` so test
        validates Task 2's 'path required' rule (not Task 1 sensitive-name helper)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "TODO"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_grep_without_path_blocks(self, tmp_path):
        """Gate-4 round-9 finding: inventory gap — behavior-neutral needed own
        native Grep no-path test."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "TODO"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_grep_with_safe_path_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "TODO", "path": "docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_single_step_grep_without_path_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "TODO"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_grep_normalized_root_dotdot_blocks(self, tmp_path):
        """Grep path='docs/..' resolves to repo-root → BLOCK via helper."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Grep", "input": {"pattern": "secret", "path": "docs/.."}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_glob_always_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Glob", "input": {"pattern": "**/*.md", "path": "docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_glob_always_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Glob", "input": {"pattern": "*.md", "path": "docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_single_step_glob_always_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Glob", "input": {"pattern": "*.md", "path": "docs/"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")


class TestL3ExemptIntegrityBehaviorNeutral:
    @pytest.fixture(autouse=True)
    def _block_mode_for_l3(self):
        """v45 R45 F2: L3 integrity only blocks in enforcement_mode=block."""
        bak = _set_enforcement_mode("block")
        yield
        _restore_enforcement_mode(bak)

    def test_behavior_neutral_with_doc_edit_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Write", "input": {"file_path": "docs/foo.md", "content": "x"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_behavior_neutral_with_commit_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git commit -m 'x'"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # v30 R30 F2 regression tests: spec §3.1 R11 F1 CRITICAL + R17 F1 CRITICAL
    # hardening — ALL .claude/state/ writes are blocked in behavior-neutral
    # (both .json like attest-ledger and .jsonl like override-log can forge
    # L5 evidence). Earlier spec carveout ".claude/state/*.jsonl" is removed
    # and these tests lock the hardened policy.
    def test_behavior_neutral_with_claude_state_jsonl_blocks(self, tmp_path):
        """R11 hardening: .claude/state/*.jsonl writes blocked — override-log
        forgery path must stay closed."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Write", "input": {
                "file_path": ".claude/state/attest-override-log.jsonl",
                "content": "forged entry",
            }}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_with_claude_state_json_blocks(self, tmp_path):
        """R11 hardening: .claude/state/attest-ledger.json writes blocked."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Write", "input": {
                "file_path": ".claude/state/attest-ledger.json",
                "content": '{"entries":{}}',
            }}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_with_drift_jsonl_blocks(self, tmp_path):
        """R11 hardening: even seemingly-innocent drift-log writes are blocked —
        drift log must be hook-written, never response-written."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Write", "input": {
                "file_path": ".claude/state/skill-invoke-drift.jsonl",
                "content": '{"fake":"entry"}',
            }}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")


class TestL3ExemptIntegritySingleStep:
    @pytest.fixture(autouse=True)
    def _block_mode_for_l3(self):
        """v45 R45 F2: L3 integrity only blocks in enforcement_mode=block."""
        bak = _set_enforcement_mode("block")
        yield
        _restore_enforcement_mode(bak)

    def test_single_step_with_one_tool_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "ls ."}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_single_step_with_three_tools_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[
                {"name": "Bash", "input": {"command": "ls"}},
                {"name": "Read", "input": {"file_path": "/a"}},
                {"name": "Read", "input": {"file_path": "/b"}},
            ],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")


class TestL3ExemptIntegrityUserExplicitSkip:
    """v31 R31 F1 hardening: user-explicit-skip MUST carry auditable user
    authorization in the current-turn user message. Previously it was
    "trust user, no content check" which was an unrestricted L1 bypass —
    any Claude response could self-declare this reason and skip all
    L2/L4/L5 checks once block mode global."""

    @pytest.fixture(autouse=True)
    def _block_mode_for_l3(self):
        """v45 R45 F2: L3 integrity only blocks in enforcement_mode=block."""
        bak = _set_enforcement_mode("block")
        yield
        _restore_enforcement_mode(bak)

    def test_user_explicit_skip_without_auth_phrase_blocks(self, tmp_path):
        """No authorization phrase in user message → BLOCK."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            user_text="修一下这个 bug",  # no skip authorization
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")
        assert "user-explicit-skip" in stdout or "授权" in stdout

    def test_user_explicit_skip_with_en_skip_skill_passes(self, tmp_path):
        """'skip skill' in user message → pass."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            user_text="just run ls, skip skill for this one",
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_user_explicit_skip_with_zh_phrase_passes(self, tmp_path):
        """中文 '跳过 skill' → pass."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            user_text="直接跑 ls, 跳过 skill",
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_user_explicit_skip_with_slash_marker_passes(self, tmp_path):
        """'/no-skill' slash marker → pass."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            user_text="/no-skill ls",
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_user_explicit_skip_no_user_message_blocks(self, tmp_path):
        """No user message at all → BLOCK (can't verify authorization)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            # user_text omitted → transcript has only assistant entry
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")
