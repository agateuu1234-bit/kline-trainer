#!/usr/bin/env bash
# pre-edit-trust-boundary-hint.sh
# Input: stdin JSON {"tool_name":"Edit"|"Write", "tool_input":{"file_path":"..."}}
# Output: context-only print (exit 0); never blocks.
set -euo pipefail

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // ""')
[ -z "$file" ] && exit 0

RULES=".claude/workflow-rules.json"
[ ! -f "$RULES" ] && exit 0

match=$(python3 - "$file" <<'PY'
import json, pathlib, fnmatch, sys
f = sys.argv[1]
d = json.load(open('.claude/workflow-rules.json'))
for w in d.get('trust_boundary_whitelist', []):
    if fnmatch.fnmatch(f, w): sys.exit(0)
for g in d['trust_boundary_globs']:
    if fnmatch.fnmatch(f, g) or pathlib.PurePath(f).match(g):
        print('MATCH'); sys.exit(0)
PY
)

if [ "$match" = "MATCH" ]; then
  echo "[pre-edit-hint] $file is trust-boundary -> requires codex:adversarial-review approve + (if codeowners_required) user Approve before merge."
fi
exit 0
