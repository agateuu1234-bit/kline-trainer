#!/usr/bin/env bash
# Task 5 test: pre-commit-diff-scan.sh
# Uses a throwaway git repo to avoid touching main workspace
set -euo pipefail

ORIG_PWD=$(pwd)
HOOK_SRC="$ORIG_PWD/.claude/hooks/pre-commit-diff-scan.sh"
RULES_SRC="$ORIG_PWD/.claude/workflow-rules.json"

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
cd "$TMP"

git init -q
git config user.email test@local
git config user.name test
git checkout -q -b main
echo init > README.md && git add . && git commit -qm init

# Copy hook + rules into tmp
mkdir -p .claude
cp "$RULES_SRC" .claude/
cp "$HOOK_SRC" ./hook.sh
chmod +x hook.sh

# Scenario 1: on main, stage a trust-boundary file
echo test > CLAUDE.md
git add CLAUDE.md
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' | bash ./hook.sh || true)
if ! echo "$out" | grep -q '"permissionDecision":"deny"'; then
  echo "FAIL: should deny on main+trust-boundary (got: $out)"
  exit 1
fi

# Scenario 2: on feature branch, same file -> allowed (no deny output)
git checkout -q -b feature/x
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' | bash ./hook.sh || true)
if echo "$out" | grep -q '"permissionDecision":"deny"'; then
  echo "FAIL: blocked on feature branch (got: $out)"
  exit 1
fi

# Scenario 3: on main, non-git-commit bash command (e.g. ls) -> no action
git checkout -q main
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash ./hook.sh || true)
if echo "$out" | grep -q '"permissionDecision":"deny"'; then
  echo "FAIL: blocked non-git-commit command"
  exit 1
fi

echo "PASS"
