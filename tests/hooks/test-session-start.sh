#!/usr/bin/env bash
# Task 3: test session-start.sh hook (stdin JSON contract)
set -euo pipefail

HOOK=".claude/hooks/session-start.sh"
if [ ! -f "$HOOK" ]; then
  echo "FAIL: $HOOK not found"
  exit 1
fi

OUT=$(echo '{}' | bash "$HOOK")
echo "$OUT" | grep -q "Skill gate" || { echo "FAIL: no Skill gate reminder"; exit 1; }
echo "$OUT" | grep -q "workflow-rules.json" || { echo "FAIL: no workflow-rules ref"; exit 1; }
echo "$OUT" | grep -q "codex:adversarial-review" || { echo "FAIL: no adversarial-review ref"; exit 1; }
echo "PASS"
