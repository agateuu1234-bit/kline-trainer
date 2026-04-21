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

# ---------------- Summary ----------------
printf '\n%d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All 5 tests passed"
    exit 0
fi
exit 1
