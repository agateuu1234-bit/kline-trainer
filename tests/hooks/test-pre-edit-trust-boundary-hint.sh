#!/usr/bin/env bash
set -euo pipefail

HOOK=".claude/hooks/pre-edit-trust-boundary-hint.sh"

# Test 1: trust-boundary path -> should hint
OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"CLAUDE.md"}}' | bash "$HOOK")
echo "$OUT" | grep -q "codex:adversarial-review" || { echo "FAIL: no hint for CLAUDE.md"; exit 1; }

# Test 2: non-trust-boundary -> no hint
OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"some-random-nonexistent-file-xyz.txt"}}' | bash "$HOOK" || true)
if echo "$OUT" | grep -q "codex:adversarial-review"; then
  echo "FAIL: false hint on non-trust-boundary"; exit 1
fi
echo "PASS"
