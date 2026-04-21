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

# ---------------- T3: hook doesn't hang on garbage stdin ----------------
# Portable timeout helper: prefers timeout (Linux) / gtimeout (brew coreutils on mac),
# falls back to perl -e 'alarm' which ships with stock macOS.

run_with_timeout() {
    local limit="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$limit" "$@"; return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$limit" "$@"; return $?
    fi
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

# ---------------- T4A/B: skill routing bidirectional drift guard ----------------
# Run hook once, parse STDOUT (not source file), compare against skill_entry_map.

t4_stdout=$(printf '%s' '{"prompt":"x"}' | bash "$HOOK" 2>/dev/null)

expected_skills=$(jq -r \
  '.skill_entry_map | to_entries | map(.value) | .[] | select(startswith("(exempt") | not)' \
  "$RULES" | sort -u)

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

# ---------------- T4C/D: exempt reason bidirectional drift guard ----------------
expected_exempt=$(jq -r '.skill_gate_policy.exempt_reason_whitelist[]' "$RULES" | sort -u)

# Extract exempt reasons from hook stdout (exempt(<reason>) patterns + "Whitelist reasons" line)
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

# Direction C: every exempt reason in hook must be in whitelist
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

# ---------------- Summary ----------------
printf '\n%d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All 5 tests passed"
    exit 0
fi
exit 1
