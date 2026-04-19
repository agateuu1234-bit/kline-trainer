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
