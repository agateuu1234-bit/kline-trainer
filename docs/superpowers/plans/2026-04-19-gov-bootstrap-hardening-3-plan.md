# gov-bootstrap-hardening-3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline). Trust-boundary edits (`.claude/hooks/**`, `.claude/scripts/**`, `.claude/settings.json`) go via `/tmp/` patch scripts + user terminal (same pattern as hardening-1/-2). subagent-driven would multiply the handoff overhead by 3x.

**Goal:** Close 3 hardening-2 residuals: (H3-1) env-guard hook with fail-closed deny + allow-list, (H3-2) skill-gate drift ceiling at push-time, (H3-3) heredoc false-positive fix in refspec parser.

**Architecture:** One new PreToolUse hook for env-file read/write (replaces 35-line enumeration with 4-line allow-list). Existing stop-hook gets clearer stderr; existing guard-attest-ledger gets drift-count check + heredoc-stripping preprocessor. One new tty-ceremony script for cursor acknowledgment.

**Tech Stack:** bash 3.2 / zsh / python3 stdlib / pytest. Same as hardening-1/2.

**Spec:** `docs/superpowers/specs/2026-04-19-gov-bootstrap-hardening-3-design.md` (commit `bd69792` on this branch)

**Branch:** `gov-bootstrap-hardening-3`

---

## File structure

### Created (new files)

- `.claude/hooks/guard-env-read.sh` — Task 1 (H3-1)
- `.claude/scripts/ack-drift.sh` — Task 3 (H3-2 cursor ceremony)
- `tests/hooks/test_guard_env_read.py` — Task 1
- `tests/hooks/test_ack_drift.py` — Task 3

### Modified (trust-boundary — user-terminal patches)

- `.claude/hooks/stop-response-check.sh` — Task 2 (H3-2 stderr improvement)
- `.claude/hooks/guard-attest-ledger.sh` — Tasks 4+5 (H3-2 drift ceiling, H3-3 heredoc strip)
- `.claude/settings.json` — Task 6 (remove 35 env enum entries, mount guard-env-read, deny ack-drift direct invoke)

### Modified (no ask — tests)

- `tests/hooks/conftest.py` — Task 1 (copy guard-env-read.sh into temp repo)
- `tests/hooks/test_stop_response_check.py` — Task 2
- `tests/hooks/test_guard_attest_ledger.py` — Tasks 4+5
- `tests/hooks/test_settings_json_shape.py` — Task 6

### State (gitignored, runtime)

- `.claude/state/skill-gate-push-cursor.txt` — created by guard-attest-ledger on first push
- `.claude/state/ack-drift-log.jsonl` — created by ack-drift.sh on first ack

---

## Task 1: H3-1 guard-env-read.sh — fail-closed env file deny

**Files:**
- Create: `.claude/hooks/guard-env-read.sh` (via /tmp/ patch; trust-boundary deny for direct Write)
- Create: `tests/hooks/test_guard_env_read.py`
- Modify: `tests/hooks/conftest.py` (add hook to copy list)

- [ ] **Step 1: Write failing tests**

Create `tests/hooks/test_guard_env_read.py`:

```python
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
```

Also update `tests/hooks/conftest.py` to copy the new hook. Add `".claude/hooks/guard-env-read.sh"` to the list in `temp_git_repo` fixture.

- [ ] **Step 2: Run failing tests**

```bash
python3 -m pytest tests/hooks/test_guard_env_read.py -v
```

Expected: all tests fail with "No such file or directory: .../guard-env-read.sh".

- [ ] **Step 3: Prepare hook impl patch for user terminal**

Write `/tmp/patch-h31-create-env-guard.py`:

```python
#!/usr/bin/env python3
"""H3-1: Create .claude/hooks/guard-env-read.sh."""
from pathlib import Path

TARGET = Path(".claude/hooks/guard-env-read.sh")
CONTENT = '''#!/usr/bin/env bash
# guard-env-read.sh
# H3-1: PreToolUse hook for Read/Edit/Write tools. Fail-closed deny any
# file whose basename matches .env* unless it's in the sample allow-list.
# Replaces hardening-2's 35-line enumeration (which missed compound suffixes).
set -eo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))")

# Only gate Read/Edit/Write
case "$TOOL_NAME" in
    Read|Edit|Write) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))")
if [ -z "$FILE_PATH" ]; then
    echo "[guard-env-read] BLOCK: $TOOL_NAME with empty file_path (malformed)" >&2
    exit 2
fi

BASENAME=$(basename "$FILE_PATH")

# Not an env file -> pass
case "$BASENAME" in
    .env|.env.*) ;;
    *) exit 0 ;;
esac

# Sample allow-list
case "$BASENAME" in
    .env.example|.env.sample|.env.template|.env.dist)
        echo "[guard-env-read] PASS: $BASENAME (sample file)" >&2
        exit 0 ;;
esac

# Real env file -> deny
echo "[guard-env-read] BLOCK: $TOOL_NAME on $FILE_PATH -- env files with real secrets are not readable/writable by Claude tools" >&2
echo "  Allow-list (always passes): .env.example, .env.sample, .env.template, .env.dist" >&2
exit 2
'''

if TARGET.exists():
    print("[patch] file already exists; refusing to overwrite"); raise SystemExit(0)
TARGET.parent.mkdir(parents=True, exist_ok=True)
TARGET.write_text(CONTENT)
TARGET.chmod(0o755)
print(f"[patch] created {TARGET}")
```

- [ ] **Step 4: User runs patch + verifies**

User in terminal:

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h31-create-env-guard.py
chmod +x .claude/hooks/guard-env-read.sh
ls -la .claude/hooks/guard-env-read.sh
python3 -m pytest tests/hooks/test_guard_env_read.py -v
```

Expected: all tests pass. Then commit:

```bash
git add .claude/hooks/guard-env-read.sh tests/hooks/conftest.py tests/hooks/test_guard_env_read.py
git commit -m "feat(guard-env-read): fail-closed env file deny with sample allow-list (H3-1)"
```

---

## Task 2: H3-2 stop-hook stderr improvement

**Files:**
- Modify: `.claude/hooks/stop-response-check.sh` (via /tmp/ patch)
- Modify: `tests/hooks/test_stop_response_check.py`

- [ ] **Step 1: Add failing test for new stderr format**

Append to `tests/hooks/test_stop_response_check.py`:

```python
class TestDriftStderrFormatH32:
    """H3-2 a2: stderr output on drift must be multi-line with drift count + explicit next-action."""

    def test_stderr_contains_drift_count(self, temp_git_repo, tmp_path):
        # Pre-populate drift log to seed count = 3
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        drift.parent.mkdir(parents=True, exist_ok=True)
        drift.write_text(
            '{"first_line":"prev1"}\n'
            '{"first_line":"prev2"}\n'
            '{"first_line":"prev3"}\n'
        )
        from tests.hooks.test_stop_response_check import make_transcript, run_hook
        tx = make_transcript(tmp_path, [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Missing gate here.\n\nBody."},
            ]}},
        ])
        r = run_hook(tx, temp_git_repo)
        assert r.returncode == 0
        combined = r.stderr + r.stdout
        assert "drift" in combined.lower()
        # Drift count (4 after this entry) must appear
        assert ("drift count" in combined.lower() or
                "累积" in combined or "累计" in combined), \
            f"stderr should show drift count; got:\n{combined}"
        # Explicit next-action instruction
        assert "Skill gate:" in combined, \
            f"stderr should instruct next response format; got:\n{combined}"

    def test_stderr_contains_inferred_skill_hint(self, temp_git_repo, tmp_path):
        from tests.hooks.test_stop_response_check import make_transcript, run_hook
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
            f"stderr should mention inferred skill; got:\n{combined}"
```

- [ ] **Step 2: Run tests, expect failure**

```bash
python3 -m pytest tests/hooks/test_stop_response_check.py::TestDriftStderrFormatH32 -v
```

Expected: both tests fail (current stderr is single line without drift count or inferred skill hint).

- [ ] **Step 3: Patch script for user**

Write `/tmp/patch-h32-stderr.py`:

```python
#!/usr/bin/env python3
"""H3-2 a2: enhance stop-response-check.sh drift stderr format."""
from pathlib import Path

TARGET = Path(".claude/hooks/stop-response-check.sh")

OLD = '  echo "[stop-hook] drift logged (inferred skill: $inferred); please include \\'Skill gate: ...\\' explicitly next response" >&2'

NEW = '''  DRIFT_COUNT=$(wc -l < "$DRIFT_LOG" 2>/dev/null | tr -d ' ' || echo 0)
  echo "[skill-gate-drift] =================================" >&2
  echo "  Previous response MISSED first-line Skill gate." >&2
  echo "  First line was: $first_line" >&2
  echo "  Inferred skill (from transcript): $inferred" >&2
  echo "  Drift count (this session log): $DRIFT_COUNT" >&2
  echo "  YOUR NEXT RESPONSE MUST START WITH:" >&2
  echo "    Skill gate: <skill-name>   OR   Skill gate: exempt(<whitelist-reason>)" >&2
  echo "  (drift recorded; not blocking; hardening-3 will push-gate at threshold)" >&2
  echo "[skill-gate-drift] =================================" >&2'''

s = TARGET.read_text()
if "skill-gate-drift] ===" in s:
    print("[patch] already applied"); raise SystemExit(0)
if OLD not in s:
    # Try approximate match
    simple_old = [ln for ln in s.split("\n") if "drift logged" in ln and "please include" in ln]
    if not simple_old:
        print("[patch] ERROR: old drift echo line not found"); raise SystemExit(2)
    # Replace that specific line
    marker = simple_old[0]
    s = s.replace(marker, NEW.replace("  DRIFT_COUNT", "DRIFT_COUNT").strip())
    # Fallback ends up needing different indent; let's just insist on precise match
    if "skill-gate-drift] ===" not in s:
        print("[patch] ERROR: fallback match insufficient; inspect file manually"); raise SystemExit(3)
    TARGET.write_text(s)
    print("[patch] patched (fallback match)")
else:
    TARGET.write_text(s.replace(OLD, NEW))
    print("[patch] patched")
```

- [ ] **Step 4: User runs + tests**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h32-stderr.py
grep -n "skill-gate-drift" .claude/hooks/stop-response-check.sh
python3 -m pytest tests/hooks/test_stop_response_check.py -v
```

Expected: all prior tests pass + 2 new TestDriftStderrFormatH32 pass.

- [ ] **Step 5: Commit**

```bash
git add .claude/hooks/stop-response-check.sh tests/hooks/test_stop_response_check.py
git commit -m "feat(stop-hook): multi-line drift stderr with count + instruction (H3-2 a2)"
```

---

## Task 3: H3-2 ack-drift.sh ceremony script

**Files:**
- Create: `.claude/scripts/ack-drift.sh` (via /tmp/ patch)
- Create: `tests/hooks/test_ack_drift.py`
- Modify: `tests/hooks/conftest.py` (copy ack-drift.sh into temp repo)

- [ ] **Step 1: Write failing tests**

Create `tests/hooks/test_ack_drift.py`:

```python
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
        # stdin is pipe but we exit before tty check because nothing to ack
        r = run_ack(temp_git_repo, stdin="")
        assert r.returncode == 0
        assert "nothing to ack" in (r.stderr + r.stdout).lower()
        assert read_cursor(temp_git_repo) == 3
```

Update `tests/hooks/conftest.py` to copy `.claude/scripts/ack-drift.sh` (add to the list).

- [ ] **Step 2: Run tests, expect failures**

```bash
python3 -m pytest tests/hooks/test_ack_drift.py -v
```

Expected: all fail (script doesn't exist).

- [ ] **Step 3: Patch script for user**

Write `/tmp/patch-h32-create-ack-drift.py`:

```python
#!/usr/bin/env python3
"""H3-2: Create .claude/scripts/ack-drift.sh (tty + nonce cursor advance)."""
from pathlib import Path

TARGET = Path(".claude/scripts/ack-drift.sh")
CONTENT = '''#!/usr/bin/env bash
# ack-drift.sh — manually advance skill-gate-drift push cursor.
# Ceremony: tty + PPID check + nonce (same pattern as attest-override.sh).
# Defense-in-depth only (not cryptographically anti-agent).
set -euo pipefail

DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
CURSOR_FILE=".claude/state/skill-gate-push-cursor.txt"
AUDIT_LOG=".claude/state/ack-drift-log.jsonl"

current_drift=$([ -f "$DRIFT_LOG" ] && wc -l < "$DRIFT_LOG" | tr -d ' ' || echo 0)
cursor=$([ -f "$CURSOR_FILE" ] && cat "$CURSOR_FILE" | tr -d ' \\n' || echo 0)
new_drift=$((current_drift - cursor))

if [ "$new_drift" -le 0 ]; then
    echo "[ack-drift] nothing to ack: drift=$current_drift, cursor=$cursor" >&2
    exit 0
fi

# PPID heuristic
PARENT_CMD="${CLAUDE_OVERRIDE_TEST_PARENT_CMD:-}"
if [ -z "$PARENT_CMD" ]; then
    PARENT_CMD=$(ps -p $PPID -o comm= 2>/dev/null | tr -d ' ' || echo unknown)
fi
case "$PARENT_CMD" in
    claude|node|*claude-code*|*claude.app*|*Claude*)
        if [ "${ATTEST_OVERRIDE_CONFIRM_PARENT:-0}" != "1" ]; then
            echo "[ack-drift] refuse: parent process '$PARENT_CMD' looks like Claude/agent." >&2
            exit 9
        fi
        echo "[ack-drift] WARN: bypassing parent-process check" >&2
        ;;
esac

# TTY
if [ ! -t 0 ]; then
    echo "[ack-drift] refuse: stdin is not a tty. Run interactively." >&2
    exit 5
fi

# Nonce = short sha of drift log tail (last 4KB)
NONCE=$(tail -c 4096 "$DRIFT_LOG" 2>/dev/null | shasum -a 256 | cut -c1-7)
echo "Drift ack request:" 
echo "  current_drift: $current_drift"
echo "  cursor: $cursor"
echo "  new_since_last_push: $new_drift"
printf 'Type "ACK-DRIFT-%s" to advance cursor from %s to %s: ' "$NONCE" "$cursor" "$current_drift"
IFS= read -r ANS
if [ "$ANS" != "ACK-DRIFT-${NONCE}" ]; then
    echo "[ack-drift] confirm string mismatch; aborting." >&2
    exit 6
fi

# Advance cursor + audit log
mkdir -p "$(dirname "$CURSOR_FILE")"
echo "$current_drift" > "$CURSOR_FILE"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_USER=$(git config user.email 2>/dev/null || echo "unknown")
python3 - "$AUDIT_LOG" "$NOW" "$cursor" "$current_drift" "$new_drift" "$GIT_USER" "$PARENT_CMD" <<'\\''PY'\\''
import json, sys
p, t, oldc, newc, nd, user, parent = sys.argv[1:8]
with open(p, "a") as f:
    f.write(json.dumps({
        "time_utc": t,
        "old_cursor": int(oldc),
        "new_cursor": int(newc),
        "acked_drift_count": int(nd),
        "git_user": user,
        "parent_cmd": parent,
        "actor": "manual-cli",
    }, sort_keys=True) + "\\n")
PY

echo "[ack-drift] Cursor advanced from $cursor to $current_drift (acked $new_drift drift entries)"
'''

if TARGET.exists():
    print("[patch] file already exists; refusing to overwrite"); raise SystemExit(0)
TARGET.parent.mkdir(parents=True, exist_ok=True)
TARGET.write_text(CONTENT)
TARGET.chmod(0o755)
print(f"[patch] created {TARGET}")
```

- [ ] **Step 4: User runs + tests**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h32-create-ack-drift.py
chmod +x .claude/scripts/ack-drift.sh
python3 -m pytest tests/hooks/test_ack_drift.py -v
```

Expected: all pass. Commit:

```bash
git add .claude/scripts/ack-drift.sh tests/hooks/conftest.py tests/hooks/test_ack_drift.py
git commit -m "feat(ack-drift): tty ceremony script to advance skill-gate-drift cursor (H3-2 a3)"
```

---

## Task 4: H3-2 guard-attest-ledger drift ceiling check

**Files:**
- Modify: `.claude/hooks/guard-attest-ledger.sh` (via /tmp/ patch)
- Modify: `tests/hooks/test_guard_attest_ledger.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/hooks/test_guard_attest_ledger.py`:

```python
class TestDriftCeilingH32:
    """H3-2 a3: push is blocked when new_drift_since_last_push > DRIFT_PUSH_THRESHOLD."""

    def _setup_branch_with_ledger(self, repo, branch="feat"):
        setup_repo_with_remote(repo)
        subprocess.run(["git", "checkout", "-qb", branch], cwd=repo, check=True)
        # empty commit to have something to push
        subprocess.run(["git", "commit", "--allow-empty", "-qm", "empty"], cwd=repo, check=True)
        # Populate branch ledger so hook file-level check passes
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
        # drift=3, cursor=0, new=3, threshold default=5 -> pass
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
        # drift=10, cursor=0, new=10 > threshold 5 -> block
        r = run_hook(hook_path(temp_git_repo),
                     {"tool_name": "Bash",
                      "tool_input": {"command": "git push -u origin feat"}},
                     temp_git_repo)
        assert r.returncode != 0
        combined = r.stderr + r.stdout
        assert ("drift count" in combined.lower() or "drift" in combined.lower())
        assert "ack-drift" in combined

    def test_env_override_bypasses(self, temp_git_repo):
        self._setup_branch_with_ledger(temp_git_repo)
        drift = temp_git_repo / ".claude/state/skill-gate-drift.jsonl"
        drift.write_text("\n".join(f'{{"i":{i}}}' for i in range(20)) + "\n")
        import os
        env = {**os.environ, "DRIFT_PUSH_OVERRIDE": "1"}
        r = subprocess.run(
            ["bash", str(hook_path(temp_git_repo))],
            input=json.dumps({"tool_name": "Bash",
                              "tool_input": {"command": "git push -u origin feat"}}),
            capture_output=True, text=True, cwd=temp_git_repo, env=env,
        )
        assert r.returncode == 0, f"DRIFT_PUSH_OVERRIDE should bypass; stderr={r.stderr}"
```

- [ ] **Step 2: Run tests, expect failure**

```bash
python3 -m pytest tests/hooks/test_guard_attest_ledger.py::TestDriftCeilingH32 -v
```

Expected: test_drift_above_threshold_blocks FAILS (no ceiling check yet).

- [ ] **Step 3: Patch script**

Write `/tmp/patch-h32-drift-ceiling.py`:

```python
#!/usr/bin/env python3
"""H3-2 a3: add drift ceiling check to guard-attest-ledger.sh scenario dispatch."""
from pathlib import Path

TARGET = Path(".claude/hooks/guard-attest-ledger.sh")

# Insert right before scenario dispatch (case "$SCENARIO" in)
ANCHOR = 'case "$SCENARIO" in'
INSERT_BEFORE = ANCHOR

NEW_BLOCK = '''# H3-2 a3: drift ceiling check
DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
CURSOR_FILE=".claude/state/skill-gate-push-cursor.txt"
DRIFT_PUSH_THRESHOLD="${DRIFT_PUSH_THRESHOLD:-5}"
current_drift_count=$([ -f "$DRIFT_LOG" ] && wc -l < "$DRIFT_LOG" | tr -d ' ' || echo 0)
drift_cursor=$([ -f "$CURSOR_FILE" ] && cat "$CURSOR_FILE" | tr -d ' \\n' || echo 0)
# Sanitize cursor if non-numeric
case "$drift_cursor" in
    ''|*[!0-9]*) drift_cursor=0 ;;
esac
new_drift=$((current_drift_count - drift_cursor))
if [ "$new_drift" -gt "$DRIFT_PUSH_THRESHOLD" ] && [ "${DRIFT_PUSH_OVERRIDE:-0}" != "1" ]; then
    block "Skill-gate drift count since last push = $new_drift (> threshold $DRIFT_PUSH_THRESHOLD). Run .claude/scripts/ack-drift.sh in real tty to acknowledge and advance cursor, OR set DRIFT_PUSH_OVERRIDE=1 in your own shell (NOT Claude's Bash tool) to bypass once."
fi

'''

s = TARGET.read_text()
if "H3-2 a3: drift ceiling check" in s:
    print("[patch] already applied"); raise SystemExit(0)
count = s.count(ANCHOR)
if count == 0:
    print("[patch] ERROR: ANCHOR scenario dispatch not found"); raise SystemExit(2)
if count > 1:
    print(f"[patch] ERROR: ANCHOR found {count} times"); raise SystemExit(3)
TARGET.write_text(s.replace(ANCHOR, NEW_BLOCK + ANCHOR))
print("[patch] patched")
```

- [ ] **Step 4: User runs + tests**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h32-drift-ceiling.py
grep -n "drift ceiling" .claude/hooks/guard-attest-ledger.sh
python3 -m pytest tests/hooks/test_guard_attest_ledger.py::TestDriftCeilingH32 -v
```

Expected: 3/3 pass. Commit:

```bash
git add .claude/hooks/guard-attest-ledger.sh tests/hooks/test_guard_attest_ledger.py
git commit -m "feat(guard-attest-ledger): block push when drift count exceeds threshold (H3-2 a3)"
```

---

## Task 5: H3-3 heredoc stripping in detect_scenario

**Files:**
- Modify: `.claude/hooks/guard-attest-ledger.sh` (via /tmp/ patch)
- Modify: `tests/hooks/test_guard_attest_ledger.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/hooks/test_guard_attest_ledger.py`:

```python
class TestHeredocStrippingH33:
    """H3-3: detect_scenario must strip heredoc body before scanning for protected commands."""

    def test_heredoc_with_git_push_text_not_false_positive(self, temp_git_repo):
        """Bash command with heredoc body containing 'git push' string must not be BLOCK_UNPARSEABLE."""
        cmd = """cat > /tmp/test.md <<'EOF'
documentation mentions git push as a concept
also gh pr create was used earlier
EOF"""
        r = run_hook(
            hook_path(temp_git_repo),
            {"tool_name": "Bash", "tool_input": {"command": cmd}},
            temp_git_repo,
        )
        assert r.returncode == 0, f"heredoc body should be stripped; got block:\n{r.stderr}"

    def test_real_git_push_outside_heredoc_still_detected(self, temp_git_repo):
        """Regression: real git push after heredoc must still fire scenario A."""
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan")
        cmd = """cat > /tmp/test.md <<'EOF'
some text
EOF
git push -u origin feat"""
        r = run_hook(
            hook_path(temp_git_repo),
            {"tool_name": "Bash", "tool_input": {"command": cmd}},
            temp_git_repo,
        )
        # Chaining via heredoc followed by git push -> we don't support multi-command parsing
        # For this PR, conservative BLOCK_UNPARSEABLE is acceptable.
        # Main guarantee: heredoc body alone does NOT trigger false positive (see prior test).
        assert r.returncode != 0  # either unparseable or genuine ledger miss
```

- [ ] **Step 2: Run tests, expect first failure**

```bash
python3 -m pytest tests/hooks/test_guard_attest_ledger.py::TestHeredocStrippingH33 -v
```

Expected: `test_heredoc_with_git_push_text_not_false_positive` FAILS (current detect_scenario sees `git push` substring in heredoc body and returns BLOCK_UNPARSEABLE).

- [ ] **Step 3: Patch script**

Write `/tmp/patch-h33-heredoc-strip.py`:

```python
#!/usr/bin/env python3
"""H3-3: strip heredoc body in detect_scenario before scanning for push/pr patterns."""
from pathlib import Path

TARGET = Path(".claude/hooks/guard-attest-ledger.sh")

# Insert heredoc-stripping step at the very beginning of detect_scenario()
OLD = '''detect_scenario() {
    # Normalize whitespace for matching
    local cmd=" $CMD "'''

NEW = '''detect_scenario() {
    # H3-3: strip heredoc body so literal "git push" / "gh pr" inside docs doesn't false-positive
    local stripped_cmd
    stripped_cmd=$(printf '%s' "$CMD" | python3 -c "
import re, sys
cmd = sys.stdin.read()
# Match <<-?['\\\"]?TAG['\\\"]? (any options) ... \\nTAG[\\\\s]*\\n?
cmd = re.sub(
    r\\\"<<-?['\\\\\\\"]?(\\\\\\w+)['\\\\\\\"]?[^\\\\n]*\\\\n.*?\\\\n\\\\1\\\\s*\\\\n?\\\",
    ' ',
    cmd,
    flags=re.DOTALL
)
print(cmd)
" 2>/dev/null || printf '%s' "$CMD")
    # Normalize whitespace for matching
    local cmd=" $stripped_cmd "'''

s = TARGET.read_text()
if "H3-3: strip heredoc body" in s:
    print("[patch] already applied"); raise SystemExit(0)
count = s.count(OLD)
if count == 0:
    print("[patch] ERROR: OLD detect_scenario prologue not found"); raise SystemExit(2)
if count > 1:
    print(f"[patch] ERROR: OLD found {count} times"); raise SystemExit(3)
TARGET.write_text(s.replace(OLD, NEW))
print("[patch] patched")
```

Note: the Python regex inside the bash heredoc has 4 levels of quoting. If this proves fragile, fallback approach: use an external helper script `.claude/scripts/strip-heredoc.py` and call it from guard-attest-ledger.sh. (Plan does NOT fall back; if Step 4 fails, implementer stops and reports BLOCKED.)

- [ ] **Step 4: User runs + tests**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h33-heredoc-strip.py
grep -n "H3-3: strip heredoc" .claude/hooks/guard-attest-ledger.sh
python3 -m pytest tests/hooks/test_guard_attest_ledger.py -v
```

Expected: all tests pass (incl. the heredoc one now passing). If the regex escaping is broken, report BLOCKED and fall back to external helper approach.

- [ ] **Step 5: Commit**

```bash
git add .claude/hooks/guard-attest-ledger.sh tests/hooks/test_guard_attest_ledger.py
git commit -m "feat(guard-attest-ledger): strip heredoc body before push/pr detection (H3-3)"
```

---

## Task 6: H3-1 settings.json cleanup + mount guard-env-read

**Files:**
- Modify: `.claude/settings.json` (via /tmp/ patch — ask-prompted; patch handles)
- Modify: `tests/hooks/test_settings_json_shape.py`

- [ ] **Step 1: Write failing tests**

Append to `tests/hooks/test_settings_json_shape.py`:

```python
class TestH31SettingsCleanup:
    """H3-1 settings.json: env enumeration deleted, guard-env-read mounted,
    ack-drift.sh deny pattern present."""

    def test_env_enumeration_all_removed(self):
        """Hardening-2's 35 Read/Edit/Write enumeration entries should be gone.
        Base `Read(**/.env)` still present as defense-in-depth."""
        deny = set(load()["permissions"]["deny"])
        for v in ("local", "dev", "development", "prod", "production", "staging",
                  "test", "testing", "secret", "secrets", "override", "private",
                  "ci", "qa", "uat", "preview", "stage", "pre",
                  "backup", "bak", "old", "orig", "shared", "personal", "remote",
                  "heroku", "vercel", "netlify", "fly", "render", "railway",
                  "docker", "compose", "k8s", "nas"):
            for action in ("Read", "Edit", "Write"):
                assert f"{action}(**/.env.{v})" not in deny, \
                    f"{action}(**/.env.{v}) should be removed (guard-env-read handles it)"

    def test_base_env_still_denied(self):
        """`Read(**/.env)` stays as defense-in-depth fallback."""
        deny = set(load()["permissions"]["deny"])
        for action in ("Read", "Edit", "Write"):
            assert f"{action}(**/.env)" in deny

    def test_guard_env_read_mounted_on_read(self):
        pre = load()["hooks"]["PreToolUse"]
        mounted = False
        for group in pre:
            m = group.get("matcher", "")
            if m in ("Read", "Edit", "Write") or "Read" in m:
                for h in group.get("hooks", []):
                    if "guard-env-read.sh" in h.get("command", ""):
                        mounted = True
        assert mounted, "guard-env-read.sh must be mounted on Read (+Edit+Write) PreToolUse"

    def test_ack_drift_deny(self):
        deny = set(load()["permissions"]["deny"])
        assert any("ack-drift.sh" in p for p in deny), \
            "Bash(*ack-drift.sh*) must be in deny (user-tty only)"
```

- [ ] **Step 2: Run tests, expect failure**

```bash
python3 -m pytest tests/hooks/test_settings_json_shape.py::TestH31SettingsCleanup -v
```

Expected: all 4 fail (enumeration still present, hook not mounted, ack-drift not denied).

- [ ] **Step 3: Patch script**

Write `/tmp/patch-h31-settings.py`:

```python
#!/usr/bin/env python3
"""H3-1/H3-2: remove env enumeration, mount guard-env-read on Read/Edit/Write, deny ack-drift direct invocation."""
import json
from pathlib import Path

TARGET = Path(".claude/settings.json")
VARIANTS = [
    "local", "dev", "development", "prod", "production", "staging",
    "test", "testing", "secret", "secrets", "override", "private",
    "ci", "qa", "uat", "preview", "stage", "pre",
    "backup", "bak", "old", "orig", "shared", "personal", "remote",
    "heroku", "vercel", "netlify", "fly", "render", "railway",
    "docker", "compose", "k8s", "nas",
]

s = TARGET.read_text()
settings = json.loads(s)

# Remove enumerated env variants from deny
deny = settings["permissions"]["deny"]
to_remove = set()
for v in VARIANTS:
    for action in ("Read", "Edit", "Write"):
        to_remove.add(f"{action}(**/.env.{v})")
new_deny = [p for p in deny if p not in to_remove]

# Add ack-drift.sh deny (if not present)
ack_pattern = "Bash(*ack-drift.sh*)"
if ack_pattern not in new_deny:
    new_deny.append(ack_pattern)

settings["permissions"]["deny"] = new_deny

# Mount guard-env-read.sh on Read/Edit/Write PreToolUse (single group, 3 matchers via 3 entries)
pre = settings["hooks"]["PreToolUse"]
# Check if already mounted
already = False
for group in pre:
    for h in group.get("hooks", []):
        if "guard-env-read.sh" in h.get("command", ""):
            already = True
if not already:
    # Add 3 groups, one per tool (Claude Code's matcher is single-tool per group)
    for matcher in ("Read", "Edit", "Write"):
        pre.append({
            "matcher": matcher,
            "hooks": [
                {"type": "command", "command": "bash .claude/hooks/guard-env-read.sh", "timeout": 3}
            ],
        })

new_content = json.dumps(settings, indent=2)
TARGET.write_text(new_content + "\n")

# Validate
json.loads(TARGET.read_text())
print(f"[patch] removed {len(to_remove)} enum entries; ack-drift deny added; guard-env-read mounted on Read/Edit/Write")
```

- [ ] **Step 4: User runs + tests**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h31-settings.py
python3 -m json.tool .claude/settings.json > /dev/null && echo "JSON OK"
python3 -m pytest tests/hooks/test_settings_json_shape.py -v
```

Expected: all shape tests pass (old tests + new 4). Then:

```bash
git add .claude/settings.json tests/hooks/test_settings_json_shape.py
git commit -m "fix(settings): replace env enum with guard-env-read hook + ack-drift deny (H3-1)"
```

---

## Task 7: Full acceptance

- [ ] **Step 1: Full test suite**

```bash
python3 -m pytest tests/hooks/ -q
```

Expected: prior 78 + Task 1 (~12) + Task 2 (2) + Task 3 (3) + Task 4 (3) + Task 5 (2) + Task 6 (4) = ~104 tests passing.

- [ ] **Step 2: Acceptance script**

```bash
./scripts/acceptance/plan_0a_toolchain.sh
```

Expected: `PLAN 0A PASS` unchanged (25 + 1 SKIP).

- [ ] **Step 3: Manual verification per spec §8**

Run each of the 8 items in spec §8 acceptance checklist. Record in `artifacts/acceptance/gov-bootstrap-hardening-3-run.md`:

```bash
mkdir -p artifacts/acceptance
# Write acceptance log (can be done via Claude Write tool, outside Claude Bash due to heredoc-with-git-push content risk)
git add artifacts/acceptance/gov-bootstrap-hardening-3-run.md
git commit -m "docs(acceptance): gov-bootstrap-hardening-3 run log"
```

---

## Task 8: Push + open PR (user action)

- [ ] **Step 1: codex-attest on plan doc + branch**

```bash
.claude/scripts/codex-attest.sh --scope working-tree --focus docs/superpowers/plans/2026-04-19-gov-bootstrap-hardening-3-plan.md
.claude/scripts/codex-attest.sh --scope branch-diff --base origin/main --head gov-bootstrap-hardening-3
```

Expected path: plan doc approve; branch-diff likely needs-attention same pattern as hardening-2 → override ceremony:

```bash
.claude/scripts/attest-override.sh gov-bootstrap-hardening-3 "hardening-3 self-bootstrap per hardening-1/-2 precedent; residuals documented"
```

- [ ] **Step 2: Push + PR**

```bash
git push -u origin gov-bootstrap-hardening-3
gh pr create --base main --head gov-bootstrap-hardening-3 \
  --title "gov-bootstrap-hardening-3: H3-1 env-guard + H3-2 drift ceiling + H3-3 heredoc fix" \
  --body-file /tmp/h3-pr-body.md
```

- [ ] **Step 3: User posts verdict + merges (same pattern as #17/#18/#19)**

---

## Self-Review

### Spec coverage

| Spec § | Task |
|---|---|
| §2 H3-1 goal | Task 1 + Task 6 |
| §2 H3-2 a2 goal | Task 2 |
| §2 H3-2 a3 goal | Tasks 3 + 4 |
| §2 H3-3 goal | Task 5 |
| §4.1 file manifest | Tasks 1-6 |
| §4.2 guard-env-read logic | Task 1 Step 3 patch body |
| §4.3 drift ceiling mechanism | Task 4 Step 3 patch body |
| §4.4 ack-drift.sh | Task 3 Step 3 patch body |
| §4.5 heredoc stripping | Task 5 Step 3 patch body |
| §7 test strategy | Tasks 1-6 Steps 1/2/4 |
| §8 acceptance | Task 7 |

### Placeholder scan

- No TBD / TODO / "implement later"
- All patch scripts contain full Python/bash content
- Tests are complete, runnable

### Type consistency

- `DRIFT_LOG` / `CURSOR_FILE` / `DRIFT_PUSH_THRESHOLD` env/file names match across Tasks 2, 3, 4
- `ACK-DRIFT-<nonce>` format consistent in ack-drift.sh (Task 3) and test expectations
- `guard-env-read.sh` exit codes (0 pass, 2 deny) match Task 1 test assertions

No issues.

---

## Dependencies

- Tasks 1 and 6 are coupled (Task 6 mounts what Task 1 creates; both needed before env tests fully pass end-to-end)
- Tasks 2, 3, 4 are order-independent within H3-2 scope
- Task 5 independent
- Task 7 depends on 1-6; Task 8 depends on 7
