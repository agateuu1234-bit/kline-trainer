#!/usr/bin/env bash
set -euo pipefail

WRAPPER=".claude/scripts/codex-attest.sh"

# Test 1: reject --head-sha
out=$(bash "$WRAPPER" --head-sha fakesha 2>&1 || true)
echo "$out" | grep -q "head SHA auto-computed" || { echo "FAIL: should reject user --head-sha"; exit 1; }

# Test 2: --dry-run proxies to codex-companion
out=$(bash "$WRAPPER" --scope working-tree --dry-run --focus "test focus" 2>&1 || true)
echo "$out" | grep -q "codex-companion" || { echo "FAIL: should mention codex-companion"; echo "$out"; exit 1; }

echo "PASS"
