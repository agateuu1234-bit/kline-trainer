#!/usr/bin/env bash
# pre-merge-warn.sh — warn before gh pr merge (advisory only)
# Input: stdin JSON; Output: printed warn, exit 0.
set -euo pipefail
_=$(cat)
cat <<'EOF'
[pre-merge-warn] Reminder: merge gate authoritative is codex-verify-pass on GitHub.
This local warn is advisory; GitHub branch protection enforces actual gate.
Before merge: verify codex-verify-pass is green on PR web UI + CODEOWNERS Approve in place.
EOF
exit 0
