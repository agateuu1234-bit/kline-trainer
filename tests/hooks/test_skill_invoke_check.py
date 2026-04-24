"""Hardening-6 skill-invoke-check.sh unit tests (ζ v9)."""
import json
import os
import shutil
import subprocess
import tempfile
import pytest
from pathlib import Path

HOOK = ".claude/hooks/skill-invoke-check.sh"

def _run_hook(transcript_path, env_extra=None):
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        ["bash", HOOK],
        input=json.dumps({"transcript_path": str(transcript_path)}),
        capture_output=True, text=True, timeout=15, env=env,
    )
    return proc.returncode, proc.stdout, proc.stderr

def _write_transcript(tmp_path, assistant_text, tool_uses=None):
    content = [{"type": "text", "text": assistant_text}]
    if tool_uses:
        for tu in tool_uses:
            content.append({"type": "tool_use", "name": tu["name"], "input": tu["input"]})
    entry = {"type": "assistant", "message": {"content": content}}
    tp = tmp_path / "t.jsonl"
    tp.write_text(json.dumps(entry) + "\n")
    return tp

def _set_mode(skill, mode):
    p = Path(".claude/config/skill-invoke-enforced.json")
    bak = str(p) + ".bak"
    shutil.copy(p, bak)
    d = json.loads(p.read_text())
    if skill in d["enforce"]:
        d["enforce"][skill]["mode"] = mode
    p.write_text(json.dumps(d, indent=2))
    return bak

def _restore(bak):
    shutil.move(bak, bak[:-4])

# v36 R36 F2 fix: local helpers for workflow-rules.json enforcement_mode
# mutation (needed by TestL1RegexTightening). Previously these were
# referenced-but-not-defined → NameError at pytest collection.
def _set_enforcement_mode(mode):
    p = Path(".claude/workflow-rules.json")
    bak = str(p) + ".enf.bak"
    shutil.copy(p, bak)
    d = json.loads(p.read_text())
    d["skill_gate_policy"]["enforcement_mode"] = mode
    p.write_text(json.dumps(d, indent=2))
    return bak

def _restore_enforcement_mode(bak):
    import pathlib
    shutil.move(bak, bak[:-len(".enf.bak")])


class TestL2InvokeMatch:
    def test_valid_invoke_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_missing_invoke_observe_drift(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Read", "input": {"file_path": "/a"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        # observe mode default → no block
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_missing_invoke_block_blocks(self, tmp_path):
        bak = _set_mode("superpowers:brainstorming", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:brainstorming\n\nx",
                tool_uses=[{"name": "Read", "input": {"file_path": "/a"}}],
            )
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            _restore(bak)


class TestUnknownGate:
    def test_unknown_skill_drift_pass(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:typo-skill\n\nx",
            tool_uses=[],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_unknown_skill_block_mode_blocks(self, tmp_path):
        # We can't flip enforcement_mode globally here; test via config key absent
        # But block mode is global via workflow-rules.json, not per skill
        # For this test we simulate via env ALLOW_UNKNOWN_GATE=0 default + forcing block via mode
        # Actually unknown gate block depends on ENF_MODE=block globally
        import json as _j
        rules_p = Path(".claude/workflow-rules.json")
        bak = str(rules_p) + ".bak"
        shutil.copy(rules_p, bak)
        try:
            d = _j.loads(rules_p.read_text())
            d["skill_gate_policy"]["enforcement_mode"] = "block"
            rules_p.write_text(_j.dumps(d, indent=2))
            tp = _write_transcript(tmp_path, "Skill gate: superpowers:typo-skill\n\nx")
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            shutil.move(bak, str(rules_p))

    def test_unknown_skill_allow_flag_pass(self, tmp_path):
        import json as _j
        rules_p = Path(".claude/workflow-rules.json")
        bak = str(rules_p) + ".bak"
        shutil.copy(rules_p, bak)
        try:
            d = _j.loads(rules_p.read_text())
            d["skill_gate_policy"]["enforcement_mode"] = "block"
            rules_p.write_text(_j.dumps(d, indent=2))
            tp = _write_transcript(tmp_path, "Skill gate: superpowers:typo-skill\n\nx")
            rc, stdout, _ = _run_hook(tp, env_extra={"ALLOW_UNKNOWN_GATE": "1"})
            assert '"decision":"block"' not in stdout.replace(" ", "")
        finally:
            shutil.move(bak, str(rules_p))


class TestMiniStateTransition:
    def _reset_state(self):
        import hashlib
        p = Path(".claude/state/skill-stage")
        for f in p.glob("*.json"):
            f.unlink()

    def test_initial_to_brainstorming_passes(self, tmp_path):
        self._reset_state()
        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_illegal_transition_observe(self, tmp_path):
        """brainstorming → test-driven-development is NOT legal."""
        self._reset_state()
        # Step 1: establish last_stage=brainstorming via first call
        tp1 = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
        )
        _run_hook(tp1)
        # Step 2: illegal jump
        tp2 = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:test-driven-development\n\ny",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:test-driven-development"}}],
        )
        rc, stdout, _ = _run_hook(tp2)
        # observe mode → drift-log only; no block
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_illegal_transition_block(self, tmp_path):
        self._reset_state()
        bak = _set_mode("superpowers:test-driven-development", "block")
        try:
            tp1 = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:brainstorming\n\nx",
                tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
            )
            _run_hook(tp1)
            tp2 = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:test-driven-development\n\ny",
                tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:test-driven-development"}}],
            )
            rc, stdout, _ = _run_hook(tp2)
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            _restore(bak)


class TestL5CodexGate:
    """L5 codex evidence gate tests with real fixtures (plan R2 F1 fix).
    
    Each test establishes last_stage != _initial (so target computes to a file:
    or branch: path) and sets ledger / override-log content to drive specific
    pass/block outcomes.
    """

    # v28 R28 F2 fix: deterministic session ID + SHA256 hash matching the hook
    # v27 R26 F1 changed hook to hash FULL CLAUDE_SESSION_ID via SHA256[:8];
    # test fixture previously used CLAUDE_SESSION_ID[:8] → hook and fixture
    # wrote/read different filenames → L5 evidence tests silently exercised
    # _initial path, not the intended brainstorming/plan path. All block-mode
    # tests MUST pass DETERMINISTIC_SESSION_ID via env; fixture hashes it
    # identically to the hook.
    DETERMINISTIC_SESSION_ID = "01HQTESTAAAAAAAAAAAAAAAAAA"  # ULID-shaped, 26 chars

    def _sid_hash8(self, session_id=None):
        import hashlib
        sid = session_id or os.environ.get("CLAUDE_SESSION_ID") or self.DETERMINISTIC_SESSION_ID
        return hashlib.sha256(sid.encode()).hexdigest()[:8]

    def _setup_brainstorming_stage(self, spec_file, session_id=None):
        """Force state to last_stage=superpowers:brainstorming with file target
        pointing at spec_file. Uses state filename identical to the hook's
        SHA256-based scheme (v27 R26 F1).
        """
        import hashlib
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = self._sid_hash8(session_id)
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        state = {
            "version": "1",
            "last_stage": "superpowers:brainstorming",
            "last_stage_time_utc": "2026-04-22T00:00:00Z",
            "worktree_path": os.getcwd(),
            "session_id": session_id or os.environ.get("CLAUDE_SESSION_ID") or self.DETERMINISTIC_SESSION_ID,
            "drift_count": 0,
            "transition_history": [],
        }
        sf.write_text(json.dumps(state))
        return sf

    def _write_ledger_entry(self, key, blob_sha, attest_time="2026-04-22T09:00:00Z"):
        """Write a mock approve entry to attest-ledger.json."""
        ledger_p = Path(".claude/state/attest-ledger.json")
        bak = str(ledger_p) + ".testbak"
        if ledger_p.exists():
            shutil.copy(ledger_p, bak)
            ledger = json.loads(ledger_p.read_text())
        else:
            ledger = {}
            bak = None
        ledger[key] = {
            "attest_time_utc": attest_time,
            "verdict_digest": "sha256:testdigest",
            "blob_sha": blob_sha,
            "round": 1,
        }
        ledger_p.parent.mkdir(parents=True, exist_ok=True)
        ledger_p.write_text(json.dumps(ledger, indent=2))
        return bak

    def _restore_ledger(self, bak):
        ledger_p = Path(".claude/state/attest-ledger.json")
        if bak and Path(bak).exists():
            shutil.move(bak, ledger_p)
        elif ledger_p.exists() and not bak:
            ledger_p.unlink()

    def test_codex_no_evidence_observe_drift_only(self, tmp_path):
        """No ledger entry in observe mode → drift-log, no block."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: codex:adversarial-review\n\nx",
            tool_uses=[],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout.replace(" ", "")

    # v28 R28 F2 fix: block-mode evidence tests MUST provide deterministic
    # CLAUDE_SESSION_ID so the L4 fail-closed gate (v27 R26 F1 + v28 R27 F1)
    # does not short-circuit before the intended L5 evidence code path runs.
    # Each test asserts a SPECIFIC block reason substring, so that any
    # regression that routes the test to a different (earlier) gate fails
    # the assertion explicitly.
    def _block_env(self):
        return {
            "CLAUDE_SESSION_ID": self.DETERMINISTIC_SESSION_ID,
            "CLAUDE_SESSION_START_UTC": "2026-04-22T00:00:00Z",
        }

    def test_codex_no_evidence_block_blocks(self, tmp_path):
        """Block mode + last_stage=brainstorming + no ledger → BLOCK (evidence missing)."""
        # Create a real spec file so target computes
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("test")
        sf = self._setup_brainstorming_stage(spec)
        bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
            # v28 R28 F2: assert evidence-missing reason (not session_id_absent)
            # Hook uses Chinese message "无 target-bound 有效证据" — match substring
            assert ("有效证据" in stdout or "codex-attest" in stdout)
        finally:
            _restore(bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_ledger_match_block_mode_passes(self, tmp_path):
        """Block mode + ledger has entry with matching file blob + attest > session_start → pass."""
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("test-content-v1")
        blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        sf = self._setup_brainstorming_stage(spec)
        ledger_bak = self._write_ledger_entry(f"file:{spec}", blob)
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' not in stdout.replace(" ", "")
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_ledger_blob_mismatch_blocks(self, tmp_path):
        """Ledger entry exists but file content changed (blob mismatch) → BLOCK (revision check)."""
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("original-content")
        old_blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        spec.write_text("edited-content-different-blob")
        sf = self._setup_brainstorming_stage(spec)
        ledger_bak = self._write_ledger_entry(f"file:{spec}", old_blob)
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
            # v28 R28 F2: assert blob-mismatch reason explicitly
            # Hook consolidates blob mismatch into "无 target-bound 有效证据" (evidence fail)
            assert ("有效证据" in stdout or "codex-attest" in stdout)
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_ledger_stale_time_blocks(self, tmp_path):
        """Ledger entry exists but attest_time_utc < SESSION_START → BLOCK."""
        # ULID "01KPSNGHG0AAAAAAAAAAAAAAAA" decodes to 2026-04-22T04:00:00Z,
        # which is AFTER the stale ledger attest_time (2026-04-21T00:00:00Z),
        # so the hook correctly sees the evidence as expired and blocks.
        # DETERMINISTIC_SESSION_ID decodes to 2024-02-29 (before 2026-04-21),
        # making the stale entry appear fresh — hence a dedicated session_id here.
        STALE_SESSION_ID = "01KPSNGHG0AAAAAAAAAAAAAAAA"  # decodes to 2026-04-22T04:00:00Z
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("content")
        blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        sf = self._setup_brainstorming_stage(spec, session_id=STALE_SESSION_ID)
        ledger_bak = self._write_ledger_entry(f"file:{spec}", blob, attest_time="2026-04-21T00:00:00Z")
        mode_bak = _set_mode("codex:adversarial-review", "block")
        stale_env = {"CLAUDE_SESSION_ID": STALE_SESSION_ID}
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=stale_env)
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_ledger_wrong_target_blocks(self, tmp_path):
        """Ledger has entry for different file → BLOCK."""
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("content")
        sf = self._setup_brainstorming_stage(spec)
        ledger_bak = self._write_ledger_entry("file:docs/superpowers/specs/UNRELATED.md", "dummyblob")
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_session_start_unknown_block_mode_blocks(self, tmp_path):
        """No CLAUDE_SESSION_ID + no CLAUDE_SESSION_START_UTC + block mode → BLOCK (fail-closed)."""
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("content")
        blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        sf = self._setup_brainstorming_stage(spec)
        ledger_bak = self._write_ledger_entry(f"file:{spec}", blob)
        mode_bak = _set_mode("codex:adversarial-review", "block")
        # Unset both session envs
        env_no_sess = {k: v for k, v in os.environ.items()
                       if k not in ("CLAUDE_SESSION_ID", "CLAUDE_SESSION_START_UTC")}
        try:
            # v5 R4 F1 fix: include Write tool_use so target derives from response
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "x"}}],
            )
            proc = subprocess.run(
                ["bash", HOOK],
                input=json.dumps({"transcript_path": str(tp)}),
                capture_output=True, text=True, timeout=15, env=env_no_sess,
            )
            assert '"decision":"block"' in proc.stdout.replace(" ", "")
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)


class TestStateIsolation:
    def test_different_session_ids_independent(self, tmp_path):
        """Two session_ids produce two state files."""
        state_dir = Path(".claude/state/skill-stage")
        before = set(state_dir.glob("*.json"))

        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
        )
        _run_hook(tp, env_extra={"CLAUDE_SESSION_ID": "01HQAAAAAAAAAAAAAAAAAAAAAA"})
        _run_hook(tp, env_extra={"CLAUDE_SESSION_ID": "01HQBBBBBBBBBBBBBBBBBBBBBB"})

        after = set(state_dir.glob("*.json"))
        new_files = after - before
        assert len(new_files) >= 2

    def test_no_session_id_block_mode_fails_closed_v28(self, tmp_path):
        """v28 R27 F1: non-codex skill invocation with no CLAUDE_SESSION_ID in
        block mode MUST block (PPID+time fallback would reset last_stage=_initial,
        silently bypassing L4 mini-state)."""
        mode_bak = _set_mode("superpowers:brainstorming", "block")
        env_no_sess = {k: v for k, v in os.environ.items()
                       if k not in ("CLAUDE_SESSION_ID",)}
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:brainstorming\n\nx",
                tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
            )
            proc = subprocess.run(
                ["bash", HOOK],
                input=json.dumps({"transcript_path": str(tp)}),
                capture_output=True, text=True, timeout=15, env=env_no_sess,
            )
            assert '"decision":"block"' in proc.stdout.replace(" ", "")
            assert "session_id_absent_l4_fail_closed" in proc.stdout or "CLAUDE_SESSION_ID" in proc.stdout
        finally:
            _restore(mode_bak)


class TestOutOfRepoPathRejection:
    """v29 R29 F1: codex target derivation and recent_artifact recording MUST
    reject absolute out-of-repo paths (Path.resolve + relative_to check).
    Previously sed/lstrip('/') could normalize /tmp/docs/superpowers/specs/x.md
    into a repo-relative-looking string and bind codex evidence to a file
    outside the repo."""

    OUT_OF_REPO_PATHS = [
        "/tmp/docs/superpowers/specs/x.md",
        "/docs/superpowers/specs/x.md",
        "../outside/docs/superpowers/specs/x.md",
    ]

    def _deterministic_env(self):
        return {
            "CLAUDE_SESSION_ID": "01HQTESTAAAAAAAAAAAAAAAAAA",
            "CLAUDE_SESSION_START_UTC": "2026-04-22T00:00:00Z",
        }

    def test_codex_target_rejects_out_of_repo_paths(self, tmp_path):
        """codex:adversarial-review gate MUST NOT bind to absolute out-of-repo
        spec/plan paths in the response tool_uses."""
        import hashlib
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = hashlib.sha256(b"01HQTESTAAAAAAAAAAAAAAAAAA").hexdigest()[:8]
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        sf.write_text(json.dumps({
            "version": "1",
            "last_stage": "superpowers:brainstorming",
            "last_stage_time_utc": "2026-04-22T00:00:00Z",
            "worktree_path": os.getcwd(),
            "session_id": "01HQTESTAAAAAAAAAAAAAAAAAA",
            "drift_count": 0,
            "transition_history": [],
        }))
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            for bad_path in self.OUT_OF_REPO_PATHS:
                tp = _write_transcript(
                    tmp_path,
                    "Skill gate: codex:adversarial-review\n\nx",
                    tool_uses=[{"name": "Write", "input": {"file_path": bad_path, "content": "x"}}],
                )
                rc, stdout, _ = _run_hook(tp, env_extra=self._deterministic_env())
                # Out-of-repo path must not produce a file: TARGET.
                # Either blocks with no_target/stale or fails on evidence —
                # in no case does it pass silently.
                assert '"decision":"block"' in stdout.replace(" ", ""), \
                    f"Out-of-repo path {bad_path!r} should not pass codex gate; stdout={stdout[:300]}"
        finally:
            _restore(mode_bak)
            sf.unlink(missing_ok=True)

    def test_recent_artifact_state_rejects_out_of_repo_paths(self, tmp_path):
        """State recorded recent_artifact_path MUST NOT be set to an
        out-of-repo absolute path even when brainstorming/writing-plans
        response carries such a Write tool_use."""
        import hashlib
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        # Clean slate: remove existing state for this test's sid hash
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = hashlib.sha256(b"01HQTESTAAAAAAAAAAAAAAAAAA").hexdigest()[:8]
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        sf.unlink(missing_ok=True)
        try:
            # Stage brainstorming with an out-of-repo Write tool_use
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:brainstorming\n\nx",
                tool_uses=[
                    {"name": "Skill", "input": {"skill": "superpowers:brainstorming"}},
                    {"name": "Write", "input": {
                        "file_path": "/tmp/docs/superpowers/specs/evil.md",
                        "content": "hijack",
                    }},
                ],
            )
            _run_hook(tp, env_extra=self._deterministic_env())
            assert sf.exists(), "brainstorming should create state file"
            state = json.loads(sf.read_text())
            recent = state.get("recent_artifact_path", "")
            # Out-of-repo path MUST NOT be recorded
            assert not recent.startswith("/"), \
                f"recent_artifact_path should not be absolute: {recent!r}"
            assert recent != "tmp/docs/superpowers/specs/evil.md", \
                f"out-of-repo path leaked via lstrip: {recent!r}"
            # Either empty or an actual in-repo docs/superpowers/... path
            if recent:
                assert recent.startswith("docs/superpowers/"), \
                    f"recent_artifact_path must be in-repo docs/superpowers/: {recent!r}"
                # And the corresponding file must actually exist in repo
                assert Path(recent).exists(), \
                    f"recent_artifact_path should point at a real in-repo file: {recent!r}"
        finally:
            sf.unlink(missing_ok=True)


class TestCodexTargetInResponseOnly:
    """v33 R33 F1 regression: codex target MUST derive from CURRENT response
    Write/Edit tool_use when present. Previous `echo $X | python3 - <<'PY'`
    had stdin conflict between pipe and heredoc → CANDIDATES always empty →
    valid codex gate after spec/plan edit blocked with no_target."""

    def test_codex_target_from_response_write_in_block_mode(self, tmp_path):
        """Block mode + brainstorming stage + response has Write to spec +
        ledger has matching entry → PASS (target derives from response)."""
        import hashlib
        spec = Path("docs/superpowers/specs/2026-04-22-r33-f1-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("v33-r33-f1-content")
        blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        # Stage brainstorming so codex target path executes
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = hashlib.sha256(b"01HQTESTAAAAAAAAAAAAAAAAAA").hexdigest()[:8]
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        sf.write_text(json.dumps({
            "version": "1",
            "last_stage": "superpowers:brainstorming",
            "last_stage_time_utc": "2026-04-22T00:00:00Z",
            "worktree_path": os.getcwd(),
            "session_id": "01HQTESTAAAAAAAAAAAAAAAAAA",
            "drift_count": 0,
            "transition_history": [],
        }))
        ledger_p = Path(".claude/state/attest-ledger.json")
        ledger_bak = str(ledger_p) + ".r33bak"
        if ledger_p.exists():
            shutil.copy(ledger_p, ledger_bak)
            ledger = json.loads(ledger_p.read_text())
        else:
            ledger = {"entries": {}}
            ledger_bak = None
        ledger.setdefault("entries", {})[f"file:{spec}"] = {
            "attest_time_utc": "2026-04-22T09:00:00Z",
            "verdict_digest": "sha256:testdigest",
            "blob_sha": blob,
            "round": 1,
        }
        ledger_p.parent.mkdir(parents=True, exist_ok=True)
        ledger_p.write_text(json.dumps(ledger, indent=2))
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra={
                "CLAUDE_SESSION_ID": "01HQTESTAAAAAAAAAAAAAAAAAA",
                "CLAUDE_SESSION_START_UTC": "2026-04-22T00:00:00Z",
            })
            # Target MUST derive from response Write → file:<spec> → ledger
            # entry found → pass. If R33 F1 stdin bug regresses, CANDIDATES
            # is empty → target falls back to state/_initial → would block
            # with no_target.
            assert '"decision":"block"' not in stdout.replace(" ", ""), \
                f"Valid codex gate with response Write should pass; stdout={stdout[:400]}"
            assert "codex_gate_no_target" not in stdout, \
                "If CANDIDATES empty, hook would drift_log codex_gate_no_target — stdin-pipe bug regressed"
        finally:
            _restore(mode_bak)
            if ledger_bak:
                shutil.move(ledger_bak, ledger_p)
            elif ledger_p.exists():
                ledger_p.unlink()
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)


class TestH6ScopeOnlyL1L2:
    """v44 R44 F1 final regression: L1 + L2 scoped to H6 only. Non-H6
    plugin gates MUST be rejected (neither passthrough nor invoke-match
    bypass). Rationale: codex R44 verified that plugin-format passthrough
    lets agents bypass required H6 transitions (brainstorming → writing-plans
    → codex:adversarial-review) by routing through an unrelated plugin gate."""

    def test_frontend_design_gate_l1_rejects_in_block_mode(self, tmp_path):
        """frontend-design:web declared as L1 gate → L1 regex fails (H6 scope).
        In block mode, stop-response-check.sh hard-blocks missing/invalid gate."""
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: frontend-design:web\n\nx",
                tool_uses=[{"name": "Skill", "input": {"skill": "frontend-design:web"}}],
            )
            # Run the L1 stop-response-check (owns L1 regex).
            stop_hook = ".claude/hooks/stop-response-check.sh"
            if Path(stop_hook).exists():
                proc = subprocess.run(
                    ["bash", stop_hook],
                    input=json.dumps({"transcript_path": str(tp)}),
                    capture_output=True, text=True, timeout=15,
                )
                combined = proc.stdout + proc.stderr
                assert '"decision":"block"' in combined.replace(" ", "") \
                    or proc.returncode == 2 \
                    or "Skill gate" in combined, \
                    f"frontend-design:web must not pass L1 in block mode; stdout={proc.stdout[:400]}"
        finally:
            _restore_enforcement_mode(bak)

    def test_unregistered_codex_prefix_l2_fail_closed(self, tmp_path):
        """codex:rescue / codex:<anything> not in config → L2 unknown-gate
        fail-closed in block mode (no plugin-format invoke-match bypass)."""
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:rescue\n\nx",
                tool_uses=[{"name": "Skill", "input": {"skill": "codex:rescue"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra={
                "CLAUDE_SESSION_ID": "01HQTESTAAAAAAAAAAAAAAAAAA",
            })
            assert '"decision":"block"' in stdout.replace(" ", ""), \
                f"codex:rescue not in config must block at L2; stdout={stdout[:400]}"
            assert "未在 skill-invoke-enforced" in stdout or "未在" in stdout \
                or "block mode" in stdout, \
                f"Block reason should indicate unregistered gate; stdout={stdout[:400]}"
        finally:
            _restore_enforcement_mode(bak)


class TestVerificationBeforeCompletionBlockFlip:
    """H6.1: verification-before-completion mode flipped to block.
    复用 _set_mode 显式锁定 "block"（防回滚静默）。
    复用 TestL5CodexGate 同款 state seeding + session id 约定。"""

    DETERMINISTIC_SESSION_ID = "01HQTESTAAAAAAAAAAAAAAAAAA"

    def _sid_hash8(self, sid=None):
        import hashlib
        sid = sid or self.DETERMINISTIC_SESSION_ID
        return hashlib.sha256(sid.encode()).hexdigest()[:8]

    def _seed_tdd_stage(self, session_id=None):
        """Pre-seed state file with last_stage=test-driven-development
        so transition → verification-before-completion is legal at L4."""
        import hashlib
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = self._sid_hash8(session_id)
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        sf.write_text(json.dumps({
            "version": "1",
            "last_stage": "superpowers:test-driven-development",
            "last_stage_time_utc": "2026-04-22T00:00:00Z",
            "worktree_path": os.getcwd(),
            "session_id": session_id or self.DETERMINISTIC_SESSION_ID,
            "drift_count": 0,
            "transition_history": [],
        }))
        return sf

    def _seed_stage(self, stage, session_id=None):
        """Generalized version of _seed_tdd_stage for any predecessor."""
        import hashlib
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = self._sid_hash8(session_id)
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        sf.write_text(json.dumps({
            "version": "1",
            "last_stage": stage,
            "last_stage_time_utc": "2026-04-22T00:00:00Z",
            "worktree_path": os.getcwd(),
            "session_id": session_id or self.DETERMINISTIC_SESSION_ID,
            "drift_count": 0,
            "transition_history": [],
        }))
        return sf

    def _block_env(self):
        return {
            "CLAUDE_SESSION_ID": self.DETERMINISTIC_SESSION_ID,
            "CLAUDE_SESSION_START_UTC": "2026-04-22T00:00:00Z",
        }

    def test_l2_missing_invoke_blocks(self, tmp_path):
        sf = self._seed_tdd_stage()
        bak = _set_mode("superpowers:verification-before-completion", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:verification-before-completion\n\nx",
                tool_uses=[{"name": "Read", "input": {"file_path": "/a"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
            assert "声明但响应未 Skill tool invoke" in stdout
        finally:
            _restore(bak)
            sf.unlink(missing_ok=True)

    def test_l2_valid_invoke_passes(self, tmp_path):
        sf = self._seed_tdd_stage()
        bak = _set_mode("superpowers:verification-before-completion", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:verification-before-completion\n\nx",
                tool_uses=[{"name": "Skill",
                            "input": {"skill": "superpowers:verification-before-completion"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' not in stdout.replace(" ", "")
        finally:
            _restore(bak)
            sf.unlink(missing_ok=True)

    def test_l2_wrong_skill_invoke_blocks(self, tmp_path):
        sf = self._seed_tdd_stage()
        bak = _set_mode("superpowers:verification-before-completion", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:verification-before-completion\n\nx",
                tool_uses=[{"name": "Skill",
                            "input": {"skill": "superpowers:brainstorming"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
            assert "声明但响应未 Skill tool invoke" in stdout
        finally:
            _restore(bak)
            sf.unlink(missing_ok=True)

    def test_committed_config_is_block(self):
        """Codex R2 F2 fix: guard against _set_mode masking a regressed commit."""
        cfg = json.loads(Path(".claude/config/skill-invoke-enforced.json").read_text())
        assert cfg["enforce"]["superpowers:verification-before-completion"]["mode"] == "block", \
            "H6.1 flip regressed: committed config must be 'block', not 'observe'"

    def test_l4_codex_to_verification_still_blocks(self, tmp_path):
        """Codex R12 F1 fix: 1b was reverted — codex → verification 直通
        构成 bypass（跳过 writing-plans + TDD）。本测试断言该 transit 仍挡。"""
        sf = self._seed_stage("codex:adversarial-review")
        bak = _set_mode("superpowers:verification-before-completion", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:verification-before-completion\n\nx",
                tool_uses=[{"name": "Skill",
                            "input": {"skill": "superpowers:verification-before-completion"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", ""), \
                "codex → verification bypass must stay blocked (R12 F1)"
            assert "非法 transition" in stdout
        finally:
            _restore(bak)
            sf.unlink(missing_ok=True)

    def test_l2_block_drift_log_matches_monitoring_predicate(self, tmp_path):
        """Codex R9 F2 fix: verify emitted drift-log entry has the exact
        fields (gate_skill / config_mode / drift_kind) the §6 revert
        predicate reads."""
        sf = self._seed_tdd_stage()
        bak = _set_mode("superpowers:verification-before-completion", "block")
        drift_path = Path(".claude/state/skill-invoke-drift.jsonl")
        drift_path.parent.mkdir(parents=True, exist_ok=True)
        lines_before = drift_path.read_text().count('\n') if drift_path.exists() else 0
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:verification-before-completion\n\nx",
                tool_uses=[{"name": "Read", "input": {"file_path": "/a"}}],
            )
            _run_hook(tp, env_extra=self._block_env())
            new_lines = drift_path.read_text().splitlines()[lines_before:]
            relevant = []
            for line in new_lines:
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if e.get("gate_skill") == "superpowers:verification-before-completion":
                    relevant.append(e)
            assert relevant, \
                "drift log must include an entry for the blocked gate"
            e = relevant[-1]
            assert e["config_mode"] == "block"
            assert e["drift_kind"] in ("gate_declared_no_invoke", "illegal_transition")
        finally:
            _restore(bak)
            sf.unlink(missing_ok=True)

    def test_l4_initial_to_verification_allowed(self, tmp_path):
        """D_narrow 方案核心断言（覆盖 codex R2/R5/R6/R9/R11 F1）：
        加了 1c legal_next_set 后，`_initial` → verification-before-completion
        transition 合法，session resume / state reset 场景不被 L4 误挡。"""
        import hashlib
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = self._sid_hash8()
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        sf.unlink(missing_ok=True)  # ensure _initial

        bak = _set_mode("superpowers:verification-before-completion", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:verification-before-completion\n\nx",
                tool_uses=[{"name": "Skill",
                            "input": {"skill": "superpowers:verification-before-completion"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' not in stdout.replace(" ", ""), \
                "`_initial` → verification must pass under D_narrow (1c legal_next_set 豁免)"
        finally:
            _restore(bak)
            sf.unlink(missing_ok=True)

    def test_l4_brainstorming_to_verification_still_blocks(self, tmp_path):
        """D_narrow 保留场景 #5 的 L4 保护：brainstorming 不是 verification 的
        合法前序，从 brainstorming 直接跳 verification 仍 block — 防"脑暴后假装完成"。"""
        sf = self._seed_stage("superpowers:brainstorming")
        bak = _set_mode("superpowers:verification-before-completion", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:verification-before-completion\n\nx",
                tool_uses=[{"name": "Skill",
                            "input": {"skill": "superpowers:verification-before-completion"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
            assert "非法 transition" in stdout
            assert "last_stage=superpowers:brainstorming" in stdout
        finally:
            _restore(bak)
            sf.unlink(missing_ok=True)
