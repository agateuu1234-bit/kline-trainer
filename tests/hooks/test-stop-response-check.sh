#!/usr/bin/env bash
# Task 7 test: stop-response-check.sh (stdin JSON + transcript file)
set -euo pipefail

HOOK=".claude/hooks/stop-response-check.sh"
TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

mk_transcript() {
  local text="$1"
  local path="$TMP/transcript-$$.$RANDOM.jsonl"
  jq -nc --arg t "$text" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}' > "$path"
  echo "$path"
}

# Test 1: missing Skill gate -> block
tp=$(mk_transcript "Just some regular text")
out=$(echo "{\"transcript_path\":\"$tp\"}" | bash "$HOOK" || true)
echo "$out" | grep -q '"decision":"block"' || { echo "FAIL test 1 (should block)"; echo "$out"; exit 1; }

# Test 2: valid Skill gate -> pass (no block output)
tp=$(mk_transcript "Skill gate: superpowers:brainstorming
Rest of response body here")
out=$(echo "{\"transcript_path\":\"$tp\"}" | bash "$HOOK" || true)
if echo "$out" | grep -q '"decision":"block"'; then
  echo "FAIL test 2 (should not block)"; echo "$out"; exit 1
fi

# Test 3: exempt whitelist -> pass
tp=$(mk_transcript "Skill gate: exempt(behavior-neutral)
...")
out=$(echo "{\"transcript_path\":\"$tp\"}" | bash "$HOOK" || true)
if echo "$out" | grep -q '"decision":"block"'; then
  echo "FAIL test 3 (should not block valid exempt)"; echo "$out"; exit 1
fi

# Test 4: exempt non-whitelist -> block
tp=$(mk_transcript "Skill gate: exempt(made-up-reason)
...")
out=$(echo "{\"transcript_path\":\"$tp\"}" | bash "$HOOK" || true)
echo "$out" | grep -q '"decision":"block"' || { echo "FAIL test 4 (should block non-whitelist exempt)"; echo "$out"; exit 1; }

echo "PASS"
