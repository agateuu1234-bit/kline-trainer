#!/usr/bin/env bash
# attest-override.sh — user-tty manual override ceremony for attest ledger.
# Threat model: see spec §2.5. NOT agent-proof security; defense-in-depth only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/ledger-lib.sh"

TARGET="${1:-}"
REASON="${2:-}"
# Required for a branch override: an override for a head is only meaningful against
# the exact base it was granted for, or it would be honoured against any base and
# bypass the frozen-base binding the normal attestation path enforces.
BASE_REF="${3:-}"

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

# Usage validation before the TTY guard: a malformed invocation should fail on its own
# terms rather than on interactivity, and this must be testable non-interactively.
if [ ! -f "$TARGET" ] && git rev-parse --verify "$TARGET" >/dev/null 2>&1; then
    if [ -z "$BASE_REF" ]; then
        echo "[attest-override] ERROR: a branch override needs the base it is granted against." >&2
        echo "  usage: attest-override.sh <branch> <reason> <base-ref>" >&2
        exit 10
    fi
    git rev-parse "$BASE_REF" >/dev/null 2>&1 || {
        echo "[attest-override] ERROR: cannot resolve base ref $BASE_REF" >&2; exit 11; }
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
    if [ -z "$BASE_REF" ]; then
        echo "[attest-override] ERROR: a branch override needs the base it is granted against." >&2
        echo "  usage: attest-override.sh <branch> <reason> <base-ref>" >&2
        exit 10
    fi
    BASE_SHA=$(git rev-parse "$BASE_REF" 2>/dev/null) || {
        echo "[attest-override] ERROR: cannot resolve base ref $BASE_REF" >&2; exit 11; }
    HEAD_SHA=$(git rev-parse "$TARGET")
    SHORT=$(printf '%s' "$HEAD_SHA" | cut -c1-7)
    DETAIL_SHA="$HEAD_SHA"
fi

printf 'Override target (%s): %s\n' "$KIND" "$TARGET"
printf '  sha: %s\n' "$DETAIL_SHA"
if [ "$KIND" = "branch" ]; then
    printf '  base: %s (%s)\n' "$BASE_REF" "$BASE_SHA"
fi
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
LOG_ENTRY=$(python3 - "$TARGET" "$KIND" "$DETAIL_SHA" "$REASON" "$GIT_USER" "$PARENT_CMD" "$NOW" "${BASE_REF:-}" "${BASE_SHA:-}" <<'PY'
import json, sys
t, k, sha, reason, user, parent, now, base_ref, base_sha = sys.argv[1:10]
print(json.dumps({
    "time_utc": now,
    "target": t, "kind": k,
    "blob_or_head_sha": sha,
    "base_ref": base_ref,
    "base_sha": base_sha,
    "reason": reason,
    "git_user": user,
    "parent_cmd": parent,
    "actor": "manual-cli",
}, sort_keys=True))
PY
)
# Take the shared lock BEFORE appending: computing the line number outside it lets two
# concurrent overrides append in one order and number in another, so the ledger would
# cite an audit line describing a different target and reason.
ledger_lock_acquire || { echo "[attest-override] could not acquire ledger lock; aborting" >&2; exit 12; }
trap 'ledger_lock_release' EXIT INT TERM HUP

printf '%s\n' "$LOG_ENTRY" >> "$AUDIT_LOG"
sync 2>/dev/null || true
LINE_NO=$(wc -l < "$AUDIT_LOG" | tr -d ' ')
# Bind the exact entry, not just its position: a line number alone cannot prove which
# override the ledger is citing.
AUDIT_DIGEST="sha256:$(printf '%s' "$LOG_ENTRY" | shasum -a 256 | awk '{print $1}')"

# Ledger entry is written under the same lock already held above.
ledger_init_if_missing
if [ "$KIND" = "file" ]; then
    KEY=$(ledger_file_key "$TARGET")
else
    KEY=$(ledger_branch_key "$TARGET" "$DETAIL_SHA")
fi
python3 - "$LEDGER_PATH" "$KEY" "$KIND" "$DETAIL_SHA" "$REASON" "$NOW" "$LINE_NO" "$AUDIT_DIGEST" "${BASE_SHA:-}" <<'PY'
import json, sys
p, key, kind, sha, reason, now, ln, audit_digest, base_sha = sys.argv[1:10]
d = json.load(open(p))
d["entries"][key] = {
    "kind": kind,
    "override": True,
    "override_reason": reason,
    "override_time_utc": now,
    "audit_log_line": int(ln),
    "audit_entry_digest": audit_digest,
    "base_sha": base_sha,
    "blob_or_head_sha_at_override": sha,
}
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY

echo "[attest-override] OVERRIDE RECORDED: target=$TARGET kind=$KIND log_line=$LINE_NO"
