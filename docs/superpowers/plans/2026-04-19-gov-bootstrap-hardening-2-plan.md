# gov-bootstrap-hardening-2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline recommended — many edits land on `.claude/hooks/**` and `.claude/scripts/**` which are Edit-deny; patches go via `/tmp/` scripts + user terminal). subagent-driven adds excessive handoff overhead.

**Goal:** Fix 4 hardening-1 bugs discovered during bootstrap: (1) skill-gate stop-hook auto-inject via drift log, (2) codex verdict parser take-first + fail-closed, (3) hook refspec parser filters shell operators, (4) `.env.example` truly exempt via deny enumeration.

**Architecture:** Minimal incremental changes. stop-hook rewritten to drift-log instead of block. Two bash/python internal edits to codex-attest + guard-attest-ledger parsers. settings.json `deny` list's 3 `**/.env.*` entries replaced with explicit enumeration. 4 test files updated; 1 new.

**Tech Stack:** bash 3.2 / zsh / python3 (stdlib) / pytest. Same as hardening-1.

**Spec:** `docs/superpowers/specs/2026-04-19-gov-bootstrap-hardening-2-design.md` (commit `081af18` on branch `gov-bootstrap-hardening-2`)

**Branch:** `gov-bootstrap-hardening-2` (already created; this plan commits onto it)

---

## File structure

### Modified (trust-boundary — user-terminal patches)

- `.claude/hooks/stop-response-check.sh` — Task 1 (H2-1)
- `.claude/scripts/codex-attest.sh` — Task 2 (H2-2)
- `.claude/hooks/guard-attest-ledger.sh` — Task 3 (H2-4)

### Modified (ask — one-shot confirm)

- `.claude/settings.json` — Task 4 (H2-5)

### Modified (no ask — in-allow)

- `tests/hooks/test_codex_attest_ledger_write.py` — Task 2
- `tests/hooks/test_guard_attest_ledger.py` — Task 3
- `tests/hooks/test_settings_json_shape.py` — Task 4

### Created

- `tests/hooks/test_stop_response_check.py` — Task 1

### State (gitignored, runtime)

- `.claude/state/skill-gate-drift.jsonl` — created by stop-hook on first drift

---

## Task 1: H2-1 stop-hook drift-log

**Files:**
- Modify: `.claude/hooks/stop-response-check.sh` (via user-terminal patch)
- Create: `tests/hooks/test_stop_response_check.py`

- [ ] **Step 1: Write failing tests**

Create `tests/hooks/test_stop_response_check.py`:

```python
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
        assert "drift logged" in r.stderr.lower()

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


class TestExemptBadReasonStillBlocks:
    """Regression: exempt reason outside whitelist should STILL block."""
    def test_unknown_exempt_reason_blocks(self, temp_git_repo, tmp_path):
        tx = make_transcript(tmp_path, [
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Skill gate: exempt(not-in-whitelist)\n\nBody."},
            ]}},
        ])
        # Need workflow-rules.json in temp repo for exempt whitelist check
        # Copy from REPO_ROOT
        rules_src = REPO_ROOT / ".claude/workflow-rules.json"
        rules_dst = temp_git_repo / ".claude/workflow-rules.json"
        rules_dst.parent.mkdir(parents=True, exist_ok=True)
        rules_dst.write_bytes(rules_src.read_bytes())

        r = run_hook(tx, temp_git_repo)
        # This SHOULD block: bad exempt reason is not "missing gate", it's malformed
        # Per spec §6 error handling row "exempt reason not in whitelist" still block
        output = json.loads(r.stdout)
        assert output.get("decision") == "block"
        assert "whitelist" in output.get("reason", "").lower()
```

- [ ] **Step 2: Run tests — expect failures**

```bash
python3 -m pytest tests/hooks/test_stop_response_check.py -v
```

Expected: all 5 tests FAIL because stop-response-check.sh still uses old block logic.

- [ ] **Step 3: Prepare user-terminal patch for stop-response-check.sh**

Write patch script to `/tmp/patch-h21-stop-hook.py`. Patch replaces the block-on-missing logic (lines 48-51 area) with drift-log logic:

```python
#!/usr/bin/env python3
"""H2-1: rewrite stop-response-check.sh to drift-log instead of block."""
from pathlib import Path

TARGET = Path(".claude/hooks/stop-response-check.sh")

OLD = """# 1) First-line Skill gate syntax
if ! echo "$first_line" | grep -qE '^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\\([a-z-]+\\))'; then
  block "首行缺 'Skill gate: <name>' 或 'Skill gate: exempt(<reason>)'; 实际首行: $first_line"
fi"""

NEW = """# 1) First-line Skill gate syntax (H2-1: drift-log instead of block)
if ! echo "$first_line" | grep -qE '^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\\([a-z-]+\\))'; then
  DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
  mkdir -p "$(dirname "$DRIFT_LOG")"
  # Infer last valid Skill gate from transcript (reverse scan most recent 20 assistant messages)
  inferred=$(python3 - "$tpath" <<'PY'
import json, re, sys
target = sys.argv[1]
gate_re = re.compile(r'^Skill gate:\\s*(superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\\([a-z-]+\\))')
recent = []
try:
    with open(target) as f:
        for line in f:
            try:
                d = json.loads(line)
                if d.get('type') == 'assistant':
                    content = d.get('message', {}).get('content', [])
                    if isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict) and c.get('type') == 'text':
                                recent.append(c.get('text', ''))
                    elif isinstance(content, str):
                        recent.append(content)
            except Exception:
                continue
except Exception:
    pass
# Take last 20, reverse, find first whose first-line matches
for text in list(reversed(recent))[1:21]:  # skip current (index 0)
    fl = text.splitlines()[0] if text.splitlines() else ''
    m = gate_re.match(fl)
    if m:
        print(m.group(1)); sys.exit(0)
print('exempt(behavior-neutral)')
PY
)
  response_sha=$(printf %s "$last_text" | shasum -a 256 | awk '{print $1}')
  # Append JSONL drift record
  python3 - "$DRIFT_LOG" "$first_line" "$inferred" "$response_sha" <<'PY'
import json, sys, time
p, first_line, inferred, sha = sys.argv[1:5]
entry = {
    "time_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "first_line": first_line,
    "inferred_skill": inferred,
    "response_sha": sha,
}
with open(p, "a") as f:
    f.write(json.dumps(entry) + "\\n")
PY
  echo "[stop-hook] drift logged (inferred skill: $inferred); please include 'Skill gate: ...' explicitly next response" >&2
fi"""

s = TARGET.read_text()
if "drift logged" in s:
    print("[patch] already applied"); raise SystemExit(0)
count = s.count(OLD)
if count == 0:
    print("[patch] ERROR: OLD block not found"); raise SystemExit(2)
if count > 1:
    print(f"[patch] ERROR: OLD found {count} times"); raise SystemExit(3)
TARGET.write_text(s.replace(OLD, NEW))
print("[patch] patched")
```

Write the above to `/tmp/patch-h21-stop-hook.py`.

- [ ] **Step 4: Ask user to run patch + commit (external action)**

User runs in terminal:

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h21-stop-hook.py
grep -n "drift logged" .claude/hooks/stop-response-check.sh
git add .claude/hooks/stop-response-check.sh
git commit -m "fix(stop-hook): drift-log instead of block on missing Skill gate (H2-1)"
```

- [ ] **Step 5: Run tests — expect pass**

After user commits:

```bash
python3 -m pytest tests/hooks/test_stop_response_check.py -v
```

Expected: all 5 tests PASS.

- [ ] **Step 6: Commit test file**

```bash
git add tests/hooks/test_stop_response_check.py
git commit -m "test(stop-hook): drift-log behavior coverage (H2-1)"
```

---

## Task 2: H2-2 codex verdict parser take-first

**Files:**
- Modify: `.claude/scripts/codex-attest.sh` (user-terminal patch)
- Modify: `tests/hooks/test_codex_attest_ledger_write.py`

- [ ] **Step 1: Write failing test (append to existing file)**

Add to `tests/hooks/test_codex_attest_ledger_write.py`:

```python
class TestVerdictParserFirstLineH22:
    """H2-2: markdown Verdict parser must take FIRST, not last; fail-closed on duplicate labels."""
    def test_parser_takes_first_when_only_header(self, temp_git_repo):
        f = temp_git_repo / "focus.md"
        f.write_text("content\n")
        subprocess.run(["git", "add", "focus.md"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "x"], cwd=temp_git_repo, check=True)

        stub_dir = temp_git_repo / "stubs"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "node"
        stub.write_text("""#!/usr/bin/env bash
cat <<'EOF'
# Codex Adversarial Review
Target: working tree diff
Verdict: approve

Some body text.
EOF
exit 0
""")
        stub.chmod(0o755)
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}
        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "working-tree", "--focus", "focus.md"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        assert r.returncode == 0, f"expected approve path; stderr={r.stderr}"

    def test_parser_fails_closed_on_duplicate_verdicts(self, temp_git_repo):
        f = temp_git_repo / "focus.md"
        f.write_text("content\n")
        subprocess.run(["git", "add", "focus.md"], cwd=temp_git_repo, check=True)
        subprocess.run(["git", "commit", "-qm", "x"], cwd=temp_git_repo, check=True)

        stub_dir = temp_git_repo / "stubs"
        stub_dir.mkdir(exist_ok=True)
        stub = stub_dir / "node"
        stub.write_text("""#!/usr/bin/env bash
cat <<'EOF'
# Codex Adversarial Review
Target: working tree diff
Verdict: approve

Findings:
- [high] finding body talks about prior reviews that said "Verdict: needs-attention"
Verdict: needs-attention
EOF
exit 0
""")
        stub.chmod(0o755)
        env = {**os.environ, "PATH": f"{stub.parent}:{os.environ['PATH']}",
               "CODEX_ATTEST_TEST_MODE": "1"}
        r = subprocess.run(
            ["bash", str(temp_git_repo / ".claude/scripts/codex-attest.sh"),
             "--scope", "working-tree", "--focus", "focus.md"],
            cwd=temp_git_repo, capture_output=True, text=True, env=env,
        )
        # Should NOT be approve (ambiguous → not-approve → exit 7)
        assert r.returncode != 0, f"expected fail-closed on duplicate; got exit 0"
        # Ledger should NOT have the entry
        ledger = temp_git_repo / ".claude/state/attest-ledger.json"
        if ledger.exists():
            data = json.loads(ledger.read_text())
            assert "file:focus.md" not in data.get("entries", {})
```

- [ ] **Step 2: Run tests — expect second test failure**

```bash
python3 -m pytest tests/hooks/test_codex_attest_ledger_write.py::TestVerdictParserFirstLineH22 -v
```

Expected: `test_parser_takes_first_when_only_header` passes (current parser finds the line somehow), `test_parser_fails_closed_on_duplicate_verdicts` FAILs (current parser takes last → needs-attention → already fails, but for wrong reason; or takes approve → approves wrongly).

- [ ] **Step 3: Prepare user-terminal patch**

Write `/tmp/patch-h22-parser-takefirst.py`:

```python
#!/usr/bin/env python3
"""H2-2: codex-attest.sh verdict parser takes FIRST Verdict line + fail-closed duplicates."""
from pathlib import Path

TARGET = Path(".claude/scripts/codex-attest.sh")

OLD = """# Primary: markdown "Verdict: <label>" line from the final rendered review
for line in reversed(text.splitlines()):
    m = re.match(r'^Verdict:\\s*(approve|needs-attention|request-changes|reject|block)\\s*$', line.strip())
    if m:
        print(m.group(1)); sys.exit(0)"""

NEW = """# Primary: markdown "Verdict: <label>" lines (H2-2: take FIRST, fail-closed on mismatch)
matches = []
for line in text.splitlines():
    m = re.match(r'^Verdict:\\s*(approve|needs-attention|request-changes|reject|block)\\s*$', line.strip())
    if m:
        matches.append(m.group(1))
if matches:
    if len(set(matches)) > 1:
        # Header verdict and body/quoted text disagree → ambiguous, fail closed
        print("ambiguous"); sys.exit(0)
    print(matches[0]); sys.exit(0)"""

s = TARGET.read_text()
if "take FIRST, fail-closed" in s:
    print("[patch] already applied"); raise SystemExit(0)
count = s.count(OLD)
if count == 0:
    print("[patch] ERROR: OLD not found"); raise SystemExit(2)
if count > 1:
    print(f"[patch] ERROR: OLD found {count} times"); raise SystemExit(3)
TARGET.write_text(s.replace(OLD, NEW))
print("[patch] patched")
```

- [ ] **Step 4: User runs + commits**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h22-parser-takefirst.py
grep -n "take FIRST" .claude/scripts/codex-attest.sh
git add .claude/scripts/codex-attest.sh
git commit -m "fix(codex-attest): verdict parser takes first + fail-closed duplicates (H2-2)"
```

- [ ] **Step 5: Run tests — expect pass**

```bash
python3 -m pytest tests/hooks/test_codex_attest_ledger_write.py::TestVerdictParserFirstLineH22 -v
```

Expected: both tests pass.

- [ ] **Step 6: Commit test additions**

```bash
git add tests/hooks/test_codex_attest_ledger_write.py
git commit -m "test(codex-attest): parser first-line + duplicate fail-closed (H2-2)"
```

---

## Task 3: H2-4 hook refspec parser shell-op filter

**Files:**
- Modify: `.claude/hooks/guard-attest-ledger.sh` (user-terminal patch)
- Modify: `tests/hooks/test_guard_attest_ledger.py`

- [ ] **Step 1: Write failing test**

Add to `tests/hooks/test_guard_attest_ledger.py`:

```python
class TestShellOpsFilterH24:
    """H2-4: refspec parser must skip shell redirect/operator tokens."""
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
        # Should BLOCK (plan without ledger) but refer to 'feat', not '2>&1'
        assert r.returncode != 0
        assert "feat" in (r.stderr + r.stdout) or "x.md" in (r.stderr + r.stdout)
        assert "2>&1" not in (r.stderr + r.stdout).split("BLOCK:")[-1] if "BLOCK" in (r.stderr + r.stdout) else True

    def test_refspec_with_pipe_tail(self, temp_git_repo):
        setup_repo_with_remote(temp_git_repo)
        subprocess.run(["git", "checkout", "-qb", "feat"], cwd=temp_git_repo, check=True)
        plan_file_at(temp_git_repo, "docs/superpowers/plans/x.md", "plan")
        r = run_hook(
            hook_path(temp_git_repo),
            {"tool_name": "Bash",
             "tool_input": {"command": "git push origin feat | tee /tmp/log"}},
            temp_git_repo,
        )
        # With shell chaining, our hook conservatively BLOCK_UNPARSEABLE
        assert r.returncode != 0
```

- [ ] **Step 2: Run tests — expect failures**

```bash
python3 -m pytest tests/hooks/test_guard_attest_ledger.py::TestShellOpsFilterH24 -v
```

Expected: FAIL (current parser misreads `2>&1` as src branch).

- [ ] **Step 3: Prepare user-terminal patch**

Write `/tmp/patch-h24-shellops.py`:

```python
#!/usr/bin/env python3
"""H2-4: guard-attest-ledger.sh refspec parser skips shell redirect/operator tokens."""
from pathlib import Path

TARGET = Path(".claude/hooks/guard-attest-ledger.sh")

OLD = '''        SRC_BRANCH=$(echo "$CMD" | awk '{
            for(i=NF;i>0;i--){
                if(substr($i,1,1)!="-"&&$i!="origin"&&$i!="push"){print $i;exit}
            }
        }')'''

NEW = '''        # H2-4: skip shell redirect/operator tokens + origin/push + flags
        SRC_BRANCH=$(echo "$CMD" | awk '{
            for(i=NF;i>0;i--){
                tok=$i
                if(tok=="2>&1"||tok==">&"||tok=="&>"||tok==">"||tok=="<"||tok=="|"||tok=="&&"||tok=="||"||tok==";"||tok=="origin"||tok=="push") continue
                if(substr(tok,1,1)=="-") continue
                if(tok ~ /^[0-9]*>&?[0-9]*$/) continue
                if(tok ~ /^\\/(tmp|var|dev)\\//) continue  # redirect target paths
                print tok; exit
            }
        }')'''

s = TARGET.read_text()
if "H2-4: skip shell redirect" in s:
    print("[patch] already applied"); raise SystemExit(0)
count = s.count(OLD)
if count == 0:
    print("[patch] ERROR: OLD awk block not found (verify line ~161 of guard-attest-ledger.sh)"); raise SystemExit(2)
if count > 1:
    print(f"[patch] ERROR: OLD found {count} times"); raise SystemExit(3)
TARGET.write_text(s.replace(OLD, NEW))
print("[patch] patched")
```

- [ ] **Step 4: User runs + commits**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 /tmp/patch-h24-shellops.py
grep -n "H2-4: skip shell" .claude/hooks/guard-attest-ledger.sh
git add .claude/hooks/guard-attest-ledger.sh
git commit -m "fix(guard-attest-ledger): refspec parser skips shell operators (H2-4)"
```

- [ ] **Step 5: Run tests — expect pass**

```bash
python3 -m pytest tests/hooks/test_guard_attest_ledger.py::TestShellOpsFilterH24 -v
```

- [ ] **Step 6: Commit test additions**

```bash
git add tests/hooks/test_guard_attest_ledger.py
git commit -m "test(guard-attest-ledger): shell-op refspec filter (H2-4)"
```

---

## Task 4: H2-5 `.env.example` exemption via deny enumeration

**Files:**
- Modify: `.claude/settings.json` (Claude can Edit via ask-once prompt)
- Modify: `tests/hooks/test_settings_json_shape.py`

- [ ] **Step 1: Write failing test**

Add to `tests/hooks/test_settings_json_shape.py`:

```python
class TestEnvExampleExemptionH25:
    """H2-5: .env.example must NOT be in deny; .env.local MUST be in deny; **/.env.* blanket gone."""
    def test_env_example_not_denied(self):
        deny = set(load()["permissions"]["deny"])
        for p in ["Read(**/.env.example)", "Edit(**/.env.example)", "Write(**/.env.example)"]:
            assert p not in deny, f"{p} should NOT be in deny (sample file must be readable)"

    def test_env_sample_template_also_exempt(self):
        deny = set(load()["permissions"]["deny"])
        for suffix in ("sample", "template", "dist"):
            for action in ("Read", "Edit", "Write"):
                assert f"{action}(**/.env.{suffix})" not in deny

    def test_env_local_denied(self):
        deny = set(load()["permissions"]["deny"])
        assert "Read(**/.env.local)" in deny
        assert "Edit(**/.env.local)" in deny
        assert "Write(**/.env.local)" in deny

    def test_env_blanket_gone(self):
        """Regression: **/.env.* blanket pattern (too broad) must not exist."""
        deny = set(load()["permissions"]["deny"])
        for p in ["Read(**/.env.*)", "Edit(**/.env.*)", "Write(**/.env.*)"]:
            assert p not in deny, f"blanket {p} over-broad; use enumeration instead"
```

- [ ] **Step 2: Run test — expect failures**

```bash
python3 -m pytest tests/hooks/test_settings_json_shape.py::TestEnvExampleExemptionH25 -v
```

Expected: fail at test_env_blanket_gone (blanket still present) and test_env_local_denied (variant not enumerated).

- [ ] **Step 3: Edit `.claude/settings.json` (ask prompt)**

Use Edit tool on `.claude/settings.json`. Goal: replace `Read(**/.env.*)` / `Edit(**/.env.*)` / `Write(**/.env.*)` with explicit enumeration.

Find current (after `Read(**/.env)`):
```json
      "Read(**/.env.*)",
```
Replace with:
```json
      "Read(**/.env.local)",
      "Read(**/.env.dev)",
      "Read(**/.env.development)",
      "Read(**/.env.prod)",
      "Read(**/.env.production)",
      "Read(**/.env.staging)",
      "Read(**/.env.test)",
      "Read(**/.env.testing)",
      "Read(**/.env.secret)",
      "Read(**/.env.secrets)",
      "Read(**/.env.override)",
      "Read(**/.env.private)",
```

Similarly for `Edit(**/.env.*)` and `Write(**/.env.*)`.

Also check for `Bash(cat **/.env*)` / `Bash(* > **/.env*)` — keep these as-is since they use `.env*` (not `.env.*`) and the asterisk is zero-or-more, matching `.env.example`. For consistency, replace with enumeration:
- Current: `Bash(cat **/.env*)` → enumerate to `Bash(cat **/.env)`, `Bash(cat **/.env.local)`, etc.
- Same for `Bash(* > **/.env*)`

(Alternative: keep blanket Bash forms since they're defense-in-depth and `.env.example` doesn't contain real secrets anyway. But Claude running `cat backend/.env.example` would still be blocked. Decision: enumerate to preserve example readability in Bash too.)

- [ ] **Step 4: Verify JSON validity**

```bash
python3 -m json.tool .claude/settings.json > /dev/null && echo "JSON OK"
```

- [ ] **Step 5: Run tests — expect pass**

```bash
python3 -m pytest tests/hooks/test_settings_json_shape.py -q
```

Expected: all prior tests still pass + new H2-5 class passes.

- [ ] **Step 6: Commit**

```bash
git add .claude/settings.json tests/hooks/test_settings_json_shape.py
git commit -m "fix(settings): env deny enumeration exempts .env.example/.sample/.template (H2-5)"
```

---

## Task 5: Full acceptance run

**Files:** none created.

- [ ] **Step 1: Run full test suite**

```bash
python3 -m pytest tests/hooks/ -v
```

Expected: 61 prior + new H2 tests (~8-10 new) all passing.

- [ ] **Step 2: Run acceptance script**

```bash
./scripts/acceptance/plan_0a_toolchain.sh
```

Expected: `PLAN 0A PASS` with 25 PASS + 1 SKIP (unchanged from Plan 0a v3 baseline).

- [ ] **Step 3: Manual verification**

Paste into session:
- Read `backend/.env.example` → should return content, not ask/deny
- Try to Read `.env` (if exists) → should deny
- Trigger drift: respond without Skill gate (intentionally) → check `.claude/state/skill-gate-drift.jsonl` gained a line

- [ ] **Step 4: Commit acceptance artifact**

```bash
cat > artifacts/acceptance/gov-bootstrap-hardening-2-run.md <<'EOF'
# gov-bootstrap-hardening-2 acceptance run (YYYY-MM-DD)

## Test suite
`python3 -m pytest tests/hooks/ -q` → NN passed

## Acceptance script
`./scripts/acceptance/plan_0a_toolchain.sh` → PLAN 0A PASS (25 + 1 SKIP)

## H2-1 drift
Drift log at .claude/state/skill-gate-drift.jsonl: N lines recorded during session.

## H2-5 manual
- Read .env.example: PASS (returned content)
- Read .env: PASS (denied)
EOF
git add artifacts/acceptance/gov-bootstrap-hardening-2-run.md
git commit -m "docs(acceptance): gov-bootstrap-hardening-2 run log"
```

---

## Task 6: push + open PR (user action)

**Files:** none (external).

- [ ] **Step 1: codex-attest on plan doc + branch**

```bash
.claude/scripts/codex-attest.sh --scope working-tree --focus docs/superpowers/plans/2026-04-19-gov-bootstrap-hardening-2-plan.md
.claude/scripts/codex-attest.sh --scope branch-diff --base origin/main --head gov-bootstrap-hardening-2
```

Expected: both approve (scope narrow, content small). If needs-attention, fix and retry up to 3 rounds.

- [ ] **Step 2: If attest doesn't converge, use override ceremony (same pattern as Plan 0a v3)**

```bash
.claude/scripts/attest-override.sh gov-bootstrap-hardening-2 "hardening-2 self-bootstrap: incremental fixes for hardening-1 bugs"
```

- [ ] **Step 3: Push + PR**

```bash
git push -u origin gov-bootstrap-hardening-2
gh pr create --base main --head gov-bootstrap-hardening-2 \
  --title "gov-bootstrap-hardening-2: H2-1 skill-gate drift + H2-2/4/5" \
  --body-file /tmp/h2-pr-body.md
```

- [ ] **Step 4: User posts verdict + merges**

```bash
gh pr comment <N> --body-file /tmp/h2-verdict-summary.md
gh pr merge <N> --squash --match-head-commit <OID>
```

---

## Self-Review

### Spec coverage

| Spec section | Task |
|---|---|
| §2 H2-1 目标 | Task 1 |
| §2 H2-2 目标 | Task 2 |
| §2 H2-4 目标 | Task 3 |
| §2 H2-5 目标 | Task 4 |
| §4.1 架构件清单 | Tasks 1-4 |
| §4.2 stop-hook 重写 | Task 1 Step 3 patch content |
| §4.3 parser take-first | Task 2 Step 3 patch content |
| §4.4 hook shell-op 过滤 | Task 3 Step 3 patch content |
| §4.5 .env.example 豁免 | Task 4 Step 3 |
| §7 测试策略 | Tasks 1-4 Steps 1/2/5 |
| §8 非 coder 验收 | Task 5 |

All spec requirements traced.

### Placeholder scan

- No "TBD / TODO / implement later" in task content
- All bash commands and Python snippets are concrete
- Patch contents provided verbatim per task

### Type consistency

- `.claude/state/skill-gate-drift.jsonl` path used identically in Task 1 test + patch
- `CODEX_ATTEST_TEST_MODE=1` env usage consistent with hardening-1 pattern
- Test class names `TestXxxH2N` consistent across Tasks

No issues.

---

## Dependencies

- Tasks 1-4 are order-independent; can run in any order
- Task 5 depends on Tasks 1-4 complete
- Task 6 depends on Task 5 + user decision
