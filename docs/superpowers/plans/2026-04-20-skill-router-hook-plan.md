# Skill Router Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the UserPromptSubmit reminder hook per spec `docs/superpowers/specs/2026-04-20-skill-router-hook-design.md` — a stateless bash hook that injects a fixed skill-routing reminder on every user message, enabling Claude's first-line `Skill gate:` self-declaration to stay fresh across long conversations.

**Architecture:** One new bash script (`.claude/hooks/user-prompt-skill-reminder.sh`) reads and discards stdin, then emits a hardcoded heredoc reminder covering every `skill_entry_map` entry and every `exempt_reason_whitelist` reason. One new test file (`tests/hooks/test-user-prompt-skill-reminder.sh`) runs the hook and validates its stdout. One change to `.claude/settings.json` wires the hook to the `UserPromptSubmit` event. No state files, no external classification, fail-open on any failure.

**Tech Stack:** bash 3.2+, `jq` (tests only, runtime-free), portable timeout helper (`timeout` / `gtimeout` / `perl -e 'alarm'`), Claude Code hooks system (`UserPromptSubmit` event).

**Trust-boundary execution model:** `.claude/settings.json` deny list blocks Claude's `Edit(.claude/hooks/**)` and `Write(.claude/hooks/**)` by design (governance invariant). The plan therefore splits who creates which file:

| File | Who creates/edits | Via |
|---|---|---|
| `tests/hooks/test-user-prompt-skill-reminder.sh` | **Claude** | `Write` tool (tests/ is not in deny) |
| `.claude/hooks/user-prompt-skill-reminder.sh` | **User (TTY)** | Heredoc commands copy-pasted into user's own terminal |
| `.claude/settings.json` | **Claude** | `Edit` tool (settings.json is in `ask`, click-approval each time) |

User-terminal steps (like Task 1 Step 3 below) are **not ambiguous**: the plan provides the exact command block, and execution returns to Claude once the user confirms completion.

**Phase delivery:** true (mechanism verification per spec §4.6 acceptance checklist 1–5).

**Task class:** governance_process_toolchain_change (per `.claude/workflow-rules.json`). Stage order: brainstorming ✅ → writing-plans (this) → codex:adversarial-review → verification-before-completion.

---

## File Structure

### Files to create

| Path | Responsibility |
|---|---|
| `.claude/hooks/user-prompt-skill-reminder.sh` | UserPromptSubmit hook; drains stdin; emits fixed reminder text via `<<'EOF'` heredoc; exits 0 |
| `tests/hooks/test-user-prompt-skill-reminder.sh` | 5 test cases (T1–T5) verifying hook output + settings.json wiring; self-contained with local `fail()` helper |

### Files to modify

| Path | Change |
|---|---|
| `.claude/settings.json` | Add `UserPromptSubmit` node under `hooks` pointing to the new hook with `timeout: 2` |

### Files NOT touched (from spec §7 non-goals)

- All 7 existing hooks in `.claude/hooks/`
- `.claude/workflow-rules.json`
- `.claude/scripts/*`
- `CLAUDE.md`
- `stop-response-check.sh` logic (deliberately preserved; drift-log continues)

---

## Tasks

### Task 1: Test file skeleton + T1 (hook exists, emits non-empty stdout, exits 0)

**Files:**
- Create: `tests/hooks/test-user-prompt-skill-reminder.sh`
- Create: `.claude/hooks/user-prompt-skill-reminder.sh`

- [ ] **Step 1: Write the failing test (T1 only)**

Create `tests/hooks/test-user-prompt-skill-reminder.sh`:

```bash
#!/usr/bin/env bash
# Tests for .claude/hooks/user-prompt-skill-reminder.sh
# Spec: docs/superpowers/specs/2026-04-20-skill-router-hook-design.md §4.5
# Plan: docs/superpowers/plans/2026-04-20-skill-router-hook-plan.md

set -u  # do NOT use `set -e` — we want to run all tests then summarize

HOOK=".claude/hooks/user-prompt-skill-reminder.sh"
RULES=".claude/workflow-rules.json"
SETTINGS=".claude/settings.json"

PASS=0
FAIL=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAIL=$((FAIL + 1))
}

pass() {
    printf 'PASS: %s\n' "$1"
    PASS=$((PASS + 1))
}

# ---------------- T1: basic invocation ----------------
t1_stdout=$(printf '%s' '{"prompt":"任意消息"}' | bash "$HOOK" 2>/dev/null)
t1_exit=$?
if [ "$t1_exit" -ne 0 ]; then
    fail "T1: hook exit=$t1_exit expected 0"
elif [ -z "$t1_stdout" ]; then
    fail "T1: hook stdout is empty"
else
    pass "T1 basic invocation"
fi

# ---------------- Summary ----------------
printf '\n%d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All 5 tests passed"
    exit 0
fi
exit 1
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output:
```
FAIL: T1: hook exit=127 expected 0
0 pass, 1 fail
```
(exit 127 = "bash: hook file not found")

- [ ] **Step 3: USER creates hook file via terminal (Claude is deny-blocked)**

Claude cannot `Write(.claude/hooks/**)` — hard-denied in `.claude/settings.json`. The user must run the heredoc below in their own terminal (any one-shot paste works; `cat > ... <<'OUTER'` is intentionally used so bash does NOT expand the inner `'EOF'` heredoc terminator).

User runs in terminal:

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"

cat > .claude/hooks/user-prompt-skill-reminder.sh <<'OUTER'
#!/usr/bin/env bash
# user-prompt-skill-reminder.sh — UserPromptSubmit hook.
# Emits a fixed skill-routing reminder so Claude's first-line `Skill gate:`
# self-declaration stays fresh across long conversations.
#
# Spec: docs/superpowers/specs/2026-04-20-skill-router-hook-design.md
# Plan: docs/superpowers/plans/2026-04-20-skill-router-hook-plan.md
#
# Design: stateless, fail-open. Reads stdin to drain pipe buffer, then emits
# heredoc to stdout (which Claude sees as context). Never blocks, never errors.
set -u

# Drain stdin (Claude Code passes JSON; we don't parse, just drain so the
# pipe doesn't block the parent)
cat >/dev/null 2>&1 || true

cat <<'EOF'
[skill-router-reminder] placeholder — real reminder text lands in Task 2
EOF

exit 0
OUTER

ls -l .claude/hooks/user-prompt-skill-reminder.sh
```

Expected last line shows the file exists (executable bit not required since we invoke via `bash <path>`).

User then tells Claude "done" (or pastes the `ls -l` line back) to resume.

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output:
```
PASS: T1 basic invocation
1 pass, 0 fail
All 5 tests passed
```

(Note: summary line is currently misleading because only T1 exists; we fix later tasks to have the full count match.)

- [ ] **Step 5: Commit**

Claude runs:
```bash
git add tests/hooks/test-user-prompt-skill-reminder.sh .claude/hooks/user-prompt-skill-reminder.sh
git commit -m "test+feat(skill-router-hook T1): hook skeleton + basic invocation test"
```

(The `git add` of `.claude/hooks/user-prompt-skill-reminder.sh` works because `Bash(git add:*)` is in Claude's allow list; Claude cannot Edit/Write the file but CAN stage and commit a file the user created.)

---

### Task 2: T2 — output contains required anchors + full reminder text

**Files:**
- Modify: `tests/hooks/test-user-prompt-skill-reminder.sh` (add T2)
- Modify: `.claude/hooks/user-prompt-skill-reminder.sh` (replace placeholder with full reminder)

- [ ] **Step 1: Add T2 to the test file**

Insert this block after T1 (before the `# ---------------- Summary ----------------` line):

```bash
# ---------------- T2: output contains required anchors ----------------
t2_stdout=$(printf '%s' '{"prompt":"x"}' | bash "$HOOK" 2>/dev/null)

check_anchor() {
    local name="$1" pattern="$2"
    if printf '%s' "$t2_stdout" | grep -Fq "$pattern"; then
        pass "T2 anchor '$name' present"
    else
        fail "T2 anchor '$name' missing (pattern: $pattern)"
    fi
}

check_anchor "Skill gate: literal"        "Skill gate:"
check_anchor "superpowers:brainstorming"  "superpowers:brainstorming"
check_anchor "exempt(...) pattern"        "exempt("
check_anchor "whitelist reasons line"     "Whitelist reasons"
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output (excerpt):
```
PASS: T1 basic invocation
FAIL: T2 anchor 'Skill gate: literal' missing (pattern: Skill gate:)
FAIL: T2 anchor 'superpowers:brainstorming' missing ...
FAIL: T2 anchor 'exempt(...) pattern' missing ...
FAIL: T2 anchor 'whitelist reasons line' missing ...
1 pass, 4 fail
```

- [ ] **Step 3: USER replaces hook heredoc with full reminder via terminal**

Claude still cannot write. User runs in terminal:

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"

cat > .claude/hooks/user-prompt-skill-reminder.sh <<'OUTER'
#!/usr/bin/env bash
# user-prompt-skill-reminder.sh — UserPromptSubmit hook.
# Spec: docs/superpowers/specs/2026-04-20-skill-router-hook-design.md
# Plan: docs/superpowers/plans/2026-04-20-skill-router-hook-plan.md
# Stateless, fail-open. Drain stdin, emit fixed heredoc, exit 0.
set -u

cat >/dev/null 2>&1 || true

cat <<'EOF'
[skill-router] Choose the correct skill before acting. Each row below maps ONE user-intent to ONE next skill. Pick the EARLIEST applicable row.

  • New feature / component / behavior change          → superpowers:brainstorming
  • Have approved spec, need to write plan             → superpowers:writing-plans
  • Execute existing plan (single-thread)              → superpowers:executing-plans
  • Execute existing plan (independent subtasks)       → superpowers:subagent-driven-development
  • 2+ independent investigations running in parallel  → superpowers:dispatching-parallel-agents
  • Write production code (feature / bugfix / refactor)→ superpowers:test-driven-development
  • Bug / test failure / unexpected behavior           → superpowers:systematic-debugging
  • Before claiming done / passing / commit / PR       → superpowers:verification-before-completion
  • UI / frontend code                                 → frontend-design:frontend-design
  • Self-review before merge                           → superpowers:requesting-code-review
  • Receive review feedback                            → superpowers:receiving-code-review
  • Create / modify a skill                            → superpowers:writing-skills
  • Multi-PR parallel / isolation needed               → superpowers:using-git-worktrees
  • Finishing a development branch                     → superpowers:finishing-a-development-branch
  • Session start / cross-session resume               → superpowers:using-superpowers
  • Mandatory review class (trust-boundary governance) → codex:adversarial-review
  • Governance / hooks / workflow rules / CLAUDE.md    → superpowers:brainstorming
    (after brainstorming: run codex-attest.sh to invoke codex:adversarial-review)
  • Read-only query                                    → exempt(read-only-query)
  • Trivial one-step with no semantic change           → exempt(single-step-no-semantic-change)
  • Doc-only change with zero runtime effect           → exempt(behavior-neutral)
  • User explicitly told you to skip                   → exempt(user-explicit-skip)

First line of your response MUST be exactly:
  Skill gate: <skill-name>
OR:
  Skill gate: exempt(<whitelist-reason>)

Whitelist reasons (exhaustive): behavior-neutral | user-explicit-skip | read-only-query | single-step-no-semantic-change
EOF

exit 0
OUTER

# Verify
bash .claude/hooks/user-prompt-skill-reminder.sh < /dev/null | head -3
```

Expected last 3 lines of output start with `[skill-router] Choose the correct skill...`.

User tells Claude "done" to resume.

**Why a dedicated `codex:adversarial-review` row (R3-F3 fix)**: the earlier version buried `codex:adversarial-review` in a governance parenthetical, so T4 greps saw the token but there was no actionable route. Now a top-level row pairs the `mandatory_review_class_change` situation directly with the skill.

- [ ] **Step 4: Run the test to verify all pass**

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output:
```
PASS: T1 basic invocation
PASS: T2 anchor 'Skill gate: literal' present
PASS: T2 anchor 'superpowers:brainstorming' present
PASS: T2 anchor 'exempt(...) pattern' present
PASS: T2 anchor 'whitelist reasons line' present
5 pass, 0 fail
All 5 tests passed
```

- [ ] **Step 5: Commit**

```bash
git add tests/hooks/test-user-prompt-skill-reminder.sh .claude/hooks/user-prompt-skill-reminder.sh
git commit -m "test+feat(skill-router-hook T2): full reminder text + anchor assertions"
```

---

### Task 3: T3 — stdin drain safety (no hang on garbage input)

**Files:**
- Modify: `tests/hooks/test-user-prompt-skill-reminder.sh` (add T3)

- [ ] **Step 1: Add T3 to the test file (portable timeout · R1-F2 fix)**

Insert this block after T2 (before the summary). **macOS by default has neither `timeout` nor `gtimeout`**; the fix is a portable shim that uses whichever is available, falling back to `perl -e 'alarm'` which ships with macOS.

```bash
# ---------------- T3: hook doesn't hang on garbage stdin ----------------
# Portable timeout helper (R1-F2 fix).
#
# Defines run_with_timeout(): runs "$@" with a 3-second cap.
#   - Prefers GNU `timeout` (Linux) or `gtimeout` (brew coreutils on mac)
#   - Falls back to `perl -e 'alarm'` which is available on stock macOS
# Exit 124 = timed out (for both timeout/gtimeout);
# perl fallback: SIGALRM-killed child returns 142 on macOS; we normalize to 124.

run_with_timeout() {
    local limit="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$limit" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$limit" "$@"
        return $?
    fi
    # perl fallback
    perl -e '
        my $limit = shift;
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) { exec @ARGV; die "exec: $!"; }
        local $SIG{ALRM} = sub { kill 15, $pid; sleep 1; kill 9, $pid; exit 124; };
        alarm $limit;
        waitpid $pid, 0;
        my $rc = $? >> 8;
        exit $rc;
    ' "$limit" "$@"
    return $?
}

t3_exit=0
{ printf '%s' "not-json-at-all" | run_with_timeout 3 bash "$HOOK" >/dev/null 2>&1; } || t3_exit=$?
if [ "$t3_exit" -eq 124 ]; then
    fail "T3: hook hung past 3s on garbage stdin"
elif [ "$t3_exit" -ne 0 ]; then
    fail "T3: hook exit=$t3_exit on garbage stdin, expected 0"
else
    pass "T3 stdin drain safety"
fi
```

- [ ] **Step 2: Run the test to verify it passes**

The hook already does `cat >/dev/null 2>&1 || true`, which drains stdin regardless of content. Expected T3 passes immediately without hook changes.

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output (excerpt):
```
PASS: T3 stdin drain safety
6 pass, 0 fail
All 5 tests passed
```

If T3 fails, the hook's `cat` line is broken — verify the drain line at top of hook is exactly:
```bash
cat >/dev/null 2>&1 || true
```

- [ ] **Step 3: Commit**

```bash
git add tests/hooks/test-user-prompt-skill-reminder.sh
git commit -m "test(skill-router-hook T3): stdin drain safety under garbage input"
```

---

### Task 4: T4A + T4B — skill routing drift guard (bidirectional, stdout-driven)

**Files:**
- Modify: `tests/hooks/test-user-prompt-skill-reminder.sh` (add T4A/B)

- [ ] **Step 1: Add T4A/B to the test file**

Insert this block after T3:

```bash
# ---------------- T4A/B: skill routing bidirectional drift guard ----------------
# Per spec §4.5, T4 executes the hook and parses STDOUT (not source file),
# then compares bidirectionally against skill_entry_map.

t4_stdout=$(printf '%s' '{"prompt":"x"}' | bash "$HOOK" 2>/dev/null)

# Expected: all non-exempt values in .skill_entry_map
expected_skills=$(jq -r \
  '.skill_entry_map | to_entries | map(.value) | .[] | select(startswith("(exempt") | not)' \
  "$RULES" | sort -u)

# Actual: skill identifiers grepped from hook stdout (all three namespaces)
actual_skills=$(printf '%s\n' "$t4_stdout" \
  | grep -oE '(superpowers|frontend-design|codex):[a-z-]+' \
  | sort -u)

# Direction A: every skill in hook stdout must exist in skill_entry_map
t4a_ok=1
for s in $actual_skills; do
    if ! printf '%s\n' "$expected_skills" | grep -Fxq "$s"; then
        fail "T4A: '$s' in hook stdout but not in skill_entry_map"
        t4a_ok=0
    fi
done
[ "$t4a_ok" -eq 1 ] && pass "T4A hook -> skill_entry_map"

# Direction B: every non-exempt skill in skill_entry_map must appear in hook stdout
t4b_ok=1
for s in $expected_skills; do
    if ! printf '%s\n' "$actual_skills" | grep -Fxq "$s"; then
        fail "T4B: '$s' in skill_entry_map but not in hook stdout"
        t4b_ok=0
    fi
done
[ "$t4b_ok" -eq 1 ] && pass "T4B skill_entry_map -> hook"
```

- [ ] **Step 2: Run the test to verify it passes**

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output (excerpt):
```
PASS: T4A hook -> skill_entry_map
PASS: T4B skill_entry_map -> hook
8 pass, 0 fail
All 5 tests passed
```

If T4A fails, the hook has a skill name that's not in the map — check for typos.

If T4B fails, `.claude/workflow-rules.json` has a route that the hook doesn't mention. Either add the missing route to the hook heredoc (Task 2 block) or remove the route from workflow-rules.

- [ ] **Step 3: Commit**

```bash
git add tests/hooks/test-user-prompt-skill-reminder.sh
git commit -m "test(skill-router-hook T4A+T4B): bidirectional skill routing drift guard"
```

---

### Task 5: T4C + T4D — exempt reason whitelist drift guard (bidirectional)

**Files:**
- Modify: `tests/hooks/test-user-prompt-skill-reminder.sh` (add T4C/D)

- [ ] **Step 1: Add T4C/D to the test file**

Insert this block after T4A/B:

```bash
# ---------------- T4C/D: exempt reason bidirectional drift guard ----------------
# Per spec §4.5, validate that the hook's exempt reasons exactly match
# skill_gate_policy.exempt_reason_whitelist.

expected_exempt=$(jq -r '.skill_gate_policy.exempt_reason_whitelist[]' \
  "$RULES" | sort -u)

# Extract exempt reasons from two places in hook stdout:
#   1. exempt(<reason>) patterns in the route table
#   2. The "Whitelist reasons" explicit line at the bottom
actual_exempt=$({
    printf '%s' "$t4_stdout" \
      | grep -oE 'exempt\([a-z-]+\)' \
      | sed 's/^exempt(//; s/)$//'
    printf '%s' "$t4_stdout" \
      | grep -E '^Whitelist reasons' \
      | sed 's/^Whitelist reasons[^:]*: *//' \
      | tr '|' '\n' \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
      | grep -E '^[a-z-]+$'
} | sort -u)

# Direction C: every exempt reason mentioned in hook must be in whitelist
t4c_ok=1
for r in $actual_exempt; do
    if ! printf '%s\n' "$expected_exempt" | grep -Fxq "$r"; then
        fail "T4C: '$r' in hook stdout but not in exempt_reason_whitelist"
        t4c_ok=0
    fi
done
[ "$t4c_ok" -eq 1 ] && pass "T4C hook exempt -> whitelist"

# Direction D: every whitelist reason must appear in hook stdout
t4d_ok=1
for r in $expected_exempt; do
    if ! printf '%s\n' "$actual_exempt" | grep -Fxq "$r"; then
        fail "T4D: '$r' in whitelist but not in hook stdout"
        t4d_ok=0
    fi
done
[ "$t4d_ok" -eq 1 ] && pass "T4D whitelist -> hook exempt"
```

- [ ] **Step 2: Run the test to verify it passes**

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output (excerpt):
```
PASS: T4C hook exempt -> whitelist
PASS: T4D whitelist -> hook exempt
10 pass, 0 fail
All 5 tests passed
```

If T4C fails, the hook heredoc contains an exempt reason not in `skill_gate_policy.exempt_reason_whitelist`. Either remove from hook heredoc or add to workflow-rules whitelist.

If T4D fails, workflow-rules has a whitelist reason the hook doesn't mention. Add the missing reason to both the route table AND the bottom "Whitelist reasons" line in the hook heredoc.

- [ ] **Step 3: Commit**

```bash
git add tests/hooks/test-user-prompt-skill-reminder.sh
git commit -m "test(skill-router-hook T4C+T4D): exempt reason whitelist bidirectional guard"
```

---

### Task 6: T5 + `.claude/settings.json` wiring

**Files:**
- Modify: `tests/hooks/test-user-prompt-skill-reminder.sh` (add T5)
- Modify: `.claude/settings.json` (add UserPromptSubmit hook node)

- [ ] **Step 1: Add T5 to the test file**

Insert this block after T4C/D:

```bash
# ---------------- T5: settings.json wiring guard ----------------
# Per spec §4.5 (Codex R2-F1 fix), split into two independent jq -e calls.

# Step 5a: UserPromptSubmit must be a non-empty array
if jq -e '.hooks.UserPromptSubmit | type == "array" and length > 0' \
    "$SETTINGS" > /dev/null 2>&1; then
    pass "T5a UserPromptSubmit is a non-empty array"
else
    fail "T5a: .hooks.UserPromptSubmit is missing / not an array / empty"
fi

# Step 5b: at least one hook entry with correct command/timeout/type
if jq -e '
    .hooks.UserPromptSubmit[]?.hooks[]?
    | select(.command == "bash .claude/hooks/user-prompt-skill-reminder.sh"
          and .timeout == 2
          and .type == "command")
' "$SETTINGS" > /dev/null 2>&1; then
    pass "T5b UserPromptSubmit wired with correct command/timeout/type"
else
    fail "T5b: no UserPromptSubmit hook entry with correct command/timeout/type"
fi
```

- [ ] **Step 2: Run the test to verify T5 fails**

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output (excerpt):
```
FAIL: T5a: .hooks.UserPromptSubmit is missing / not an array / empty
FAIL: T5b: no UserPromptSubmit hook entry with correct command/timeout/type
10 pass, 2 fail
```

- [ ] **Step 3: Claude edits `.claude/settings.json` to add UserPromptSubmit node**

`.claude/settings.json` is in Claude's `ask` permission list — Claude's `Edit` tool prompts the user to click Accept before writing. Claude executes:

```
Edit tool on .claude/settings.json (user approves the click-through)
```

Open `.claude/settings.json` and find the `"hooks": {` object (around line 311 in the current file). Inside that object, after the closing `]` of the existing `"SessionStart"` array and before the `"PreToolUse"` array, insert the new `"UserPromptSubmit"` node.

Concretely, find this structure:

```json
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/session-start.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
```

Change it to:

```json
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/session-start.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/user-prompt-skill-reminder.sh",
            "timeout": 2
          }
        ]
      }
    ],
    "PreToolUse": [
```

(The only change is the new `"UserPromptSubmit": [ ... ],` block between SessionStart and PreToolUse.)

- [ ] **Step 4: Validate settings.json is still valid JSON**

Run:
```bash
jq '.hooks | keys' .claude/settings.json
```

Expected output:
```json
[
  "PreToolUse",
  "SessionStart",
  "Stop",
  "UserPromptSubmit"
]
```

If jq reports a parse error, revert the edit and redo carefully — the comma placement matters in JSON.

- [ ] **Step 5: Run full test to verify T5 passes**

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output:
```
PASS: T1 basic invocation
PASS: T2 anchor 'Skill gate: literal' present
PASS: T2 anchor 'superpowers:brainstorming' present
PASS: T2 anchor 'exempt(...) pattern' present
PASS: T2 anchor 'whitelist reasons line' present
PASS: T3 stdin drain safety
PASS: T4A hook -> skill_entry_map
PASS: T4B skill_entry_map -> hook
PASS: T4C hook exempt -> whitelist
PASS: T4D whitelist -> hook exempt
PASS: T5a UserPromptSubmit is a non-empty array
PASS: T5b UserPromptSubmit wired with correct command/timeout/type
12 pass, 0 fail
All 5 tests passed
```

- [ ] **Step 6: Commit**

```bash
git add tests/hooks/test-user-prompt-skill-reminder.sh .claude/settings.json
git commit -m "test+feat(skill-router-hook T5): wire UserPromptSubmit in settings.json"
```

---

### Task 7: Final summary line fix + integration verification

**Files:**
- Modify: `tests/hooks/test-user-prompt-skill-reminder.sh` (fix summary count)

- [ ] **Step 1: Fix the "All 5 tests passed" summary line**

The summary line currently hardcodes "All 5 tests passed" but we actually have 12 assertion points (T1, 4× T2 anchors, T3, T4A, T4B, T4C, T4D, T5a, T5b). Spec §6 verification uses the phrase "All 5 tests passed" referring to the five TOP-level test IDs (T1, T2, T3, T4, T5), not individual assertions.

Change the summary block at the end of `tests/hooks/test-user-prompt-skill-reminder.sh` from:

```bash
# ---------------- Summary ----------------
printf '\n%d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All 5 tests passed"
    exit 0
fi
exit 1
```

to:

```bash
# ---------------- Summary ----------------
# 5 top-level tests = T1, T2, T3, T4 (A/B/C/D), T5 (a/b).
# Spec §6 acceptance uses "All 5 tests passed" to match top-level grouping.
printf '\n%d assertions passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All 5 tests passed"
    exit 0
fi
exit 1
```

- [ ] **Step 2: Run the full test suite one more time**

Run:
```bash
bash tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected output (last 3 lines):
```
12 assertions passed, 0 failed
All 5 tests passed
```

Exit code must be 0:
```bash
echo $?
```
Expected: `0`

- [ ] **Step 3: Verify hook is reachable by Claude Code (smoke test)**

This step only confirms the file/wiring; the end-to-end new-session behavior is spec §6 acceptance 3, done by the user after merge.

Run:
```bash
ls -l .claude/hooks/user-prompt-skill-reminder.sh tests/hooks/test-user-prompt-skill-reminder.sh
```

Expected: two lines, both files exist.

Run:
```bash
jq '.hooks.UserPromptSubmit[0].hooks[0]' .claude/settings.json
```

Expected output:
```json
{
  "type": "command",
  "command": "bash .claude/hooks/user-prompt-skill-reminder.sh",
  "timeout": 2
}
```

- [ ] **Step 4: Commit**

```bash
git add tests/hooks/test-user-prompt-skill-reminder.sh
git commit -m "test(skill-router-hook T7): fix summary line count + integration verify"
```

---

> **Note:** R4 outcome + Option B override rationale is documented in the spec's §9 (escalation payload) + attest-override-log (lines 5, 6). Editing the spec here would invalidate the existing user override (blob sha change), so that context intentionally stays in commit messages / override log, not in the spec.

---

## Self-Review Checklist (for plan author — do NOT check off during execution)

- [x] **Spec coverage:** each of spec §4.1–§4.7 is mapped to a task (architecture → Task 1–6, reminder text → Task 2, drift guards T4 → Task 4+5, settings wiring T5 → Task 6, §6 acceptance → user runs post-merge).
- [x] **No placeholders:** no "TBD", "similar to Task N", or vague handwaving.
- [x] **Type consistency:** `HOOK`, `RULES`, `SETTINGS` variable names consistent across T1–T5; `fail`/`pass` helpers introduced in Task 1 and used throughout.
- [x] **Frequent commits:** one commit per task; test+feat pattern on tasks where implementation changes (Task 1, 2, 6).
- [x] **TDD discipline:** red step explicit in Task 1/2/6 (tests before implementation); Task 3/4/5 add tests that pass against already-implemented hook (verification-of-state, not gate-of-behavior).

---

## After Implementation — Next Stages

Per `.claude/workflow-rules.json` `task_class_to_required_stages.governance_process_toolchain_change`:

1. **This plan**: writing-plans ✅ (you are here)
2. **Plan-level codex attest**: run `bash .claude/scripts/codex-attest.sh --scope working-tree --focus docs/superpowers/plans/2026-04-20-skill-router-hook-plan.md` before implementation begins
3. **Branch-level codex attest**: run `bash .claude/scripts/codex-attest.sh --scope branch-diff --head gov/skill-router-hook --base origin/main` after all 8 tasks complete
4. **Verification-before-completion**: run the full test suite + user-executes spec §6 acceptance
5. **PR + CODEOWNERS Approve + `gh pr merge`**

---

## Phase Delivery — Acceptance Verification (per spec §6)

After the PR merges and this plan is complete, **the user** (not Claude, not Codex) runs:

1. **验收 1**: `ls -l` hook file exists; `bash tests/hooks/test-user-prompt-skill-reminder.sh` ends with `All 5 tests passed`.
2. **验收 2**: open `.claude/settings.json`, search `UserPromptSubmit`, confirm command + timeout.
3. **验收 3**: open brand new Claude Code session; send "帮我加一个新功能：RSI 指标的计算模块"; confirm first line is `Skill gate: superpowers:brainstorming`.
4. **验收 4**: same session, send "查一下当前分支叫什么"; confirm first line is `Skill gate: exempt(read-only-query)` or `exempt(single-step-no-semantic-change)`.
5. **验收 5**: anti-drift guard — temporarily rename a skill in workflow-rules, run tests, confirm T4 fails.

All five must pass for phase delivery.
