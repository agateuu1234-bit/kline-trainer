#!/usr/bin/env bash
# codex-attest.sh
# Local wrapper around codex-companion adversarial-review for spec/plan/branch stage.
# On approve → write attest ledger entry (file or branch key).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/ledger-lib.sh"

DRY_RUN=false
SCOPE="working-tree"
FOCUS=""
BASE=""
HEAD_BR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --head-sha)
            echo "[codex-attest] ERROR: head SHA auto-computed, do not pass --head-sha" >&2
            exit 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --scope) SCOPE="$2"; shift 2 ;;
        --focus) FOCUS="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --head) HEAD_BR="$2"; shift 2 ;;
        --target) shift 2 ;;
        *) FOCUS="$FOCUS $1"; shift ;;
    esac
done

if [ "$SCOPE" = "branch-diff" ] && [ -z "$HEAD_BR" ]; then
    echo "[codex-attest] ERROR: --scope branch-diff requires --head <branch>" >&2
    exit 5
fi
if [ "$SCOPE" = "branch-diff" ] && [ -z "$BASE" ]; then
    BASE="origin/main"
fi

# P2-F1: resolve node binary and refuse PATH-shadowed variants
NODE_BIN=$(command -v node 2>/dev/null || true)
if [ -z "$NODE_BIN" ]; then
    echo "[codex-attest] ERROR: 'node' not found on PATH" >&2
    exit 10
fi
# Canonicalize to absolute real path
NODE_BIN=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$NODE_BIN")
# Test-mode bypass (tests set CODEX_ATTEST_TEST_MODE=1 + stub $NODE_BIN location).
# Production sessions never set this.
if [ "${CODEX_ATTEST_TEST_MODE:-0}" != "1" ]; then
    case "$NODE_BIN" in
        /usr/bin/node|/usr/local/bin/node|/opt/homebrew/bin/node|/opt/local/bin/node) ;;
        "$HOME"/.nvm/*|"$HOME"/.volta/*|"$HOME"/.asdf/*) ;;
        /opt/homebrew/Cellar/node*/bin/node) ;;  # Homebrew realpath (bootstrap fix 2026-04-19)
        *)
            echo "[codex-attest] ERROR: node resolved to untrusted path: $NODE_BIN" >&2
            echo "  Allowlist: /usr/bin, /usr/local/bin, /opt/homebrew/bin, /opt/local/bin, \$HOME/.nvm, \$HOME/.volta, \$HOME/.asdf" >&2
            echo "  (set CODEX_ATTEST_TEST_MODE=1 for test suites only; NEVER in production)" >&2
            exit 11
            ;;
    esac
fi

# Locate codex-companion.mjs at pinned path
CODEX_PATH="$HOME/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_PATH" ]; then
    echo "[codex-attest] ERROR: codex-companion.mjs not at pinned path $CODEX_PATH" >&2
    exit 3
fi
PIN_FILE=".claude/scripts/codex-companion.sha256"
if [ -f "$PIN_FILE" ]; then
    expected=$(cat "$PIN_FILE")
    actual=$(shasum -a 256 "$CODEX_PATH" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo "[codex-attest] ERROR: codex-companion sha256 mismatch." >&2
        exit 4
    fi
fi

HEAD_SHA_GIT=$(git rev-parse HEAD 2>/dev/null || echo "untracked")
echo "[codex-attest] auto HEAD=$HEAD_SHA_GIT  scope=$SCOPE"

if $DRY_RUN; then
    echo "[codex-attest] DRY RUN - would execute: node $CODEX_PATH adversarial-review --wait --scope $SCOPE $FOCUS"
    exit 0
fi

# Run codex; capture stdout to both terminal and buffer so we can parse verdict.
echo "[codex-attest] invoking codex-companion"
TMP_OUT=$(mktemp)
TMP_PATCH=""
trap 'rm -f "$TMP_OUT" ${TMP_PATCH:+"$TMP_PATCH"}' EXIT

# P1-F1 fix: in branch-diff mode, generate a canonical patch file and hand it
# to codex as the review target via --focus (FOCUS was previously empty in
# branch-diff mode, causing approve to be written for an unreviewed target).
REVIEW_ARGS=""
if [ "$SCOPE" = "branch-diff" ]; then
    TMP_PATCH=$(mktemp --suffix=.patch 2>/dev/null || mktemp -t codex-branchdiff)
    HEAD_SHA_FOR_PATCH=$(git rev-parse "$HEAD_BR")
    git diff --no-color --no-ext-diff "$BASE...$HEAD_BR" > "$TMP_PATCH" || {
        echo "[codex-attest] ERROR: cannot compute $BASE...$HEAD_BR diff for patch" >&2
        exit 6
    }
    REVIEW_ARGS="--focus $TMP_PATCH"
    echo "[codex-attest] branch-diff patch: $TMP_PATCH ($BASE...$HEAD_BR @ $HEAD_SHA_FOR_PATCH)"
else
    REVIEW_ARGS="$FOCUS"
fi

"$NODE_BIN" "$CODEX_PATH" adversarial-review --wait --scope "$SCOPE" $REVIEW_ARGS 2>&1 | tee "$TMP_OUT"
CODEX_EXIT=${PIPESTATUS[0]}

# Extract verdict JSON from stdout (codex-companion emits single JSON somewhere)
VERDICT=$(python3 - "$TMP_OUT" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
# Try to find last JSON object in output
objs = re.findall(r'\{[^{}]*"verdict"\s*:\s*"[^"]+"[^{}]*\}', text)
if not objs:
    # fallback: try parse each line as JSON
    for line in reversed(text.splitlines()):
        line=line.strip()
        if line.startswith("{") and '"verdict"' in line:
            try: print(json.loads(line)["verdict"]); sys.exit(0)
            except Exception: pass
    print("unknown"); sys.exit(0)
try:
    print(json.loads(objs[-1])["verdict"])
except Exception:
    print("unknown")
PY
)

if [ "$CODEX_EXIT" -ne 0 ]; then
    echo "[codex-attest] codex-companion exited $CODEX_EXIT; ledger not updated." >&2
    exit "$CODEX_EXIT"
fi

if [ "$VERDICT" != "approve" ]; then
    echo "[codex-attest] verdict=$VERDICT (not approve); ledger not updated." >&2
    exit 7
fi

# Approve path → write ledger
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VERDICT_DIGEST="sha256:$(shasum -a 256 "$TMP_OUT" | awk '{print $1}')"
ROUND=1  # plan-stage: always round 1; future: read from state

if [ "$SCOPE" = "working-tree" ] && [ -n "$FOCUS" ]; then
    for f in $FOCUS; do
        # Read blob from HEAD if tracked, else hash-object of working-tree
        BLOB=$(ledger_compute_file_blob_at_ref HEAD "$f")
        [ -z "$BLOB" ] && BLOB=$(git hash-object "$f")
        ledger_write_file "$f" "$BLOB" "$NOW" "$VERDICT_DIGEST" "$ROUND"
        echo "[codex-attest] ledger: file:$f blob=$BLOB"
    done
elif [ "$SCOPE" = "branch-diff" ]; then
    HEAD_SHA=$(git rev-parse "$HEAD_BR")
    FP=$(ledger_compute_branch_fingerprint "$BASE" "$HEAD_BR")
    ledger_write_branch "$HEAD_BR" "$HEAD_SHA" "$BASE" "$FP" "$NOW" "$VERDICT_DIGEST" "$ROUND"
    echo "[codex-attest] ledger: branch:$HEAD_BR@$HEAD_SHA fp=$FP"
fi

echo "[codex-attest] verdict=approve; ledger updated."
