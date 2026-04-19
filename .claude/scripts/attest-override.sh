#!/usr/bin/env bash
# attest-override.sh — user-tty manual override ceremony for attest ledger.
# Threat model: see spec §2.5. NOT agent-proof security; defense-in-depth only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/ledger-lib.sh"

TARGET="${1:-}"
REASON="${2:-}"

if [ -z "$TARGET" ] || [ -z "$REASON" ]; then
    echo "usage: attest-override.sh <target-file-or-branch> <reason>" >&2
    exit 2
fi

if [ "${#REASON}" -lt 10 ]; then
    echo "[attest-override] reason must be ≥10 chars (got ${#REASON})" >&2
    exit 3
fi

# PPID heuristic (R3-F1)
PARENT_CMD="${CLAUDE_OVERRIDE_TEST_PARENT_CMD:-}"
if [ -z "$PARENT_CMD" ]; then
    PARENT_CMD=$(ps -p $PPID -o comm= 2>/dev/null | tr -d ' ' || echo unknown)
fi
case "$PARENT_CMD" in
    claude|node|*claude-code*|*claude.app*|*Claude*)
        if [ "${ATTEST_OVERRIDE_CONFIRM_PARENT:-0}" != "1" ]; then
            echo "[attest-override] refuse: parent process '$PARENT_CMD' looks like Claude/agent." >&2
            echo "  If false positive, set ATTEST_OVERRIDE_CONFIRM_PARENT=1 and rerun." >&2
            exit 9
        fi
        echo "[attest-override] WARN: bypassing parent-process check via ATTEST_OVERRIDE_CONFIRM_PARENT=1" >&2
        ;;
esac

# Target must exist (file) OR be a valid branch ref
if [ ! -f "$TARGET" ] && ! git rev-parse --verify "$TARGET" >/dev/null 2>&1; then
    echo "[attest-override] target not found: $TARGET (neither file nor git ref)" >&2
    exit 4
fi

# TTY requirement (R3-F1 residual defense-in-depth)
if [ ! -t 0 ]; then
    echo "[attest-override] refuse: stdin is not a tty. Override must be run interactively." >&2
    exit 5
fi

# Determine kind (file vs branch) and compute sha/fingerprint
if [ -f "$TARGET" ]; then
    KIND="file"
    BLOB_SHA=$(git hash-object "$TARGET")
    SHORT=$(printf '%s' "$BLOB_SHA" | cut -c1-7)
    DETAIL_SHA="$BLOB_SHA"
else
    KIND="branch"
    HEAD_SHA=$(git rev-parse "$TARGET")
    SHORT=$(printf '%s' "$HEAD_SHA" | cut -c1-7)
    DETAIL_SHA="$HEAD_SHA"
fi

printf 'Override target (%s): %s\n' "$KIND" "$TARGET"
printf '  sha: %s\n' "$DETAIL_SHA"
printf '  reason: %s\n' "$REASON"
printf 'Type "OVERRIDE-CONFIRM-%s" to authorize: ' "$SHORT"
IFS= read -r ANS
if [ "$ANS" != "OVERRIDE-CONFIRM-${SHORT}" ]; then
    echo "[attest-override] confirm string mismatch; aborting." >&2
    exit 6
fi

# Write audit log entry (append-only)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_USER=$(git config user.email 2>/dev/null || echo "unknown")
AUDIT_LOG="${OVERRIDE_LOG_PATH}"
mkdir -p "$(dirname "$AUDIT_LOG")"
LOG_ENTRY=$(python3 - "$TARGET" "$KIND" "$DETAIL_SHA" "$REASON" "$GIT_USER" "$PARENT_CMD" "$NOW" <<'PY'
import json, sys
t, k, sha, reason, user, parent, now = sys.argv[1:8]
print(json.dumps({
    "time_utc": now,
    "target": t, "kind": k,
    "blob_or_head_sha": sha,
    "reason": reason,
    "git_user": user,
    "parent_cmd": parent,
    "actor": "manual-cli",
}, sort_keys=True))
PY
)
printf '%s\n' "$LOG_ENTRY" >> "$AUDIT_LOG"
LINE_NO=$(wc -l < "$AUDIT_LOG" | tr -d ' ')

# Write override ledger entry
ledger_init_if_missing
if [ "$KIND" = "file" ]; then
    KEY=$(ledger_file_key "$TARGET")
else
    KEY=$(ledger_branch_key "$TARGET" "$DETAIL_SHA")
fi
python3 - "$LEDGER_PATH" "$KEY" "$KIND" "$DETAIL_SHA" "$REASON" "$NOW" "$LINE_NO" <<'PY'
import json, sys
p, key, kind, sha, reason, now, ln = sys.argv[1:8]
d = json.load(open(p))
d["entries"][key] = {
    "kind": kind,
    "override": True,
    "override_reason": reason,
    "override_time_utc": now,
    "audit_log_line": int(ln),
    "blob_or_head_sha_at_override": sha,
}
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY

echo "[attest-override] OVERRIDE RECORDED: target=$TARGET kind=$KIND log_line=$LINE_NO"
