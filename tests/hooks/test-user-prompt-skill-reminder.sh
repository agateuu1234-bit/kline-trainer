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

# ---------------- Summary ----------------
printf '\n%d pass, %d fail\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All 5 tests passed"
    exit 0
fi
exit 1
