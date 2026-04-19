#!/usr/bin/env bash
# pre-commit-diff-scan.sh
# Input: stdin JSON {"tool_name":"Bash", "tool_input":{"command":"git commit..."}}
# Output: JSON deny if committing trust-boundary file directly on main/master; exit 0 empty otherwise.
set -eo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
# Only act on git commit commands
echo "$cmd" | grep -qE '(^|[[:space:]&;|])git[[:space:]]+commit' || exit 0

branch=$(git branch --show-current 2>/dev/null || echo "")
if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
  exit 0
fi

# gov-bootstrap-hardening (R3-F2): block staging local attestation state files.
STAGED=$(git diff --cached --name-only 2>/dev/null)
if echo "$STAGED" | grep -qE '^\.claude/state/(attest-ledger\.json|attest-override-log\.jsonl)$'; then
    OFFENDERS=$(echo "$STAGED" | grep -E '^\.claude/state/(attest-ledger\.json|attest-override-log\.jsonl)$')
    echo "[pre-commit-diff-scan] BLOCK: local attestation state must not be committed:" >&2
    printf '  %s\n' $OFFENDERS >&2
    echo "  (see .gitignore; unstage with: git restore --staged <file>)" >&2
    exit 2
fi

RULES=".claude/workflow-rules.json"
[ ! -f "$RULES" ] && exit 0

staged=$(git diff --staged --name-only 2>/dev/null || echo "")
[ -z "$staged" ] && exit 0

hit=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  m=$(python3 - "$f" <<'PY'
import json, pathlib, fnmatch, sys
f = sys.argv[1]
d = json.load(open('.claude/workflow-rules.json'))
for w in d.get('trust_boundary_whitelist', []):
    if fnmatch.fnmatch(f, w): sys.exit(0)
for g in d['trust_boundary_globs']:
    if fnmatch.fnmatch(f, g) or pathlib.PurePath(f).match(g):
        print(f); sys.exit(0)
PY
)
  if [ -n "$m" ]; then hit="$hit $m"; fi
done <<< "$staged"

if [ -n "$hit" ]; then
  jq -nc --arg reason "trust-boundary commit 在 main/master 上被禁:$hit" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
fi
exit 0
