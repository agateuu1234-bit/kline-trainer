#!/usr/bin/env bash
# ack-drift.sh — manually advance skill-gate-drift push cursor.
# Ceremony: tty + PPID check + nonce (same pattern as attest-override.sh).
# Defense-in-depth only (not cryptographically anti-agent).
set -euo pipefail

DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
CURSOR_FILE=".claude/state/skill-gate-push-cursor.txt"
AUDIT_LOG=".claude/state/ack-drift-log.jsonl"

current_drift=$([ -f "$DRIFT_LOG" ] && wc -l < "$DRIFT_LOG" | tr -d ' ' || echo 0)
cursor=$([ -f "$CURSOR_FILE" ] && cat "$CURSOR_FILE" | tr -d ' \n' || echo 0)
# Sanitize cursor
case "$cursor" in
    ''|*[!0-9]*) cursor=0 ;;
esac
new_drift=$((current_drift - cursor))

if [ "$new_drift" -le 0 ]; then
    echo "[ack-drift] nothing to ack: drift=$current_drift, cursor=$cursor" >&2
    exit 0
fi

# PPID heuristic (same as attest-override.sh)
PARENT_CMD="${CLAUDE_OVERRIDE_TEST_PARENT_CMD:-}"
if [ -z "$PARENT_CMD" ]; then
    PARENT_CMD=$(ps -p $PPID -o comm= 2>/dev/null | tr -d ' ' || echo unknown)
fi
case "$PARENT_CMD" in
    claude|node|*claude-code*|*claude.app*|*Claude*)
        if [ "${ATTEST_OVERRIDE_CONFIRM_PARENT:-0}" != "1" ]; then
            echo "[ack-drift] refuse: parent process '$PARENT_CMD' looks like Claude/agent." >&2
            exit 9
        fi
        echo "[ack-drift] WARN: bypassing parent-process check" >&2
        ;;
esac

# TTY
if [ ! -t 0 ]; then
    echo "[ack-drift] refuse: stdin is not a tty. Run interactively from your terminal." >&2
    exit 5
fi

# Nonce = short sha of drift log tail (last 4KB)
NONCE=$(tail -c 4096 "$DRIFT_LOG" 2>/dev/null | shasum -a 256 | cut -c1-7)
echo "Drift ack request:"
echo "  current_drift: $current_drift"
echo "  cursor: $cursor"
echo "  new_since_last_push: $new_drift"
printf 'Type "ACK-DRIFT-%s" to advance cursor from %s to %s: ' "$NONCE" "$cursor" "$current_drift"
IFS= read -r ANS
if [ "$ANS" != "ACK-DRIFT-${NONCE}" ]; then
    echo "[ack-drift] confirm string mismatch; aborting." >&2
    exit 6
fi

# Advance cursor + audit log
mkdir -p "$(dirname "$CURSOR_FILE")"
echo "$current_drift" > "$CURSOR_FILE"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_USER=$(git config user.email 2>/dev/null || echo "unknown")
python3 - "$AUDIT_LOG" "$NOW" "$cursor" "$current_drift" "$new_drift" "$GIT_USER" "$PARENT_CMD" <<'PY'
import json, sys
p, t, oldc, newc, nd, user, parent = sys.argv[1:8]
with open(p, "a") as f:
    f.write(json.dumps({
        "time_utc": t,
        "old_cursor": int(oldc),
        "new_cursor": int(newc),
        "acked_drift_count": int(nd),
        "git_user": user,
        "parent_cmd": parent,
        "actor": "manual-cli",
    }, sort_keys=True) + "\n")
PY

echo "[ack-drift] Cursor advanced from $cursor to $current_drift (acked $new_drift drift entries)"
