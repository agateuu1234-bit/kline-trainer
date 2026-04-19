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
    HEAD_SHA_FOR_PATCH=$(git rev-parse "$HEAD_BR")
    BASE_SHA_FROZEN=$(git rev-parse "$BASE" 2>/dev/null) || {
        echo "[codex-attest] ERROR: cannot resolve base ref $BASE" >&2
        exit 15
    }
    # H2-3: use git worktree at frozen SHA + --cwd so codex reviews the target,
    # not the current checkout. Replaces patch-as-focus (codex-companion ignored
    # --focus files and reviewed cwd HEAD anyway).
    WORKTREE=$(mktemp -d -t codex-attest-wt.XXXXXX)
    _cleanup_worktree() {
        local ec=$?
        # H4R4: also clean up TMP_OUT (previously cleaned by top-level trap we override)
        rm -f "$TMP_OUT" 2>/dev/null || true
        git worktree remove --force "$WORKTREE" 2>/dev/null || true
        rm -rf "$WORKTREE" 2>/dev/null || true
        # Preserve original exit status on EXIT; for signals, exit with conventional 128+signal
        case "${1:-EXIT}" in
            SIGNAL-INT) exit 130 ;;
            SIGNAL-TERM) exit 143 ;;
            SIGNAL-HUP) exit 129 ;;
            *) return $ec ;;
        esac
    }
    trap '_cleanup_worktree' EXIT
    trap '_cleanup_worktree SIGNAL-INT' INT
    trap '_cleanup_worktree SIGNAL-TERM' TERM
    trap '_cleanup_worktree SIGNAL-HUP' HUP
    if ! git worktree add --detach "$WORKTREE" "$HEAD_SHA_FOR_PATCH" 2>/dev/null; then
        echo "[codex-attest] ERROR: cannot create worktree at $HEAD_SHA_FOR_PATCH" >&2
        exit 14
    fi
    REVIEW_ARGS=(--base "$BASE_SHA_FROZEN" --cwd "$WORKTREE")
    echo "[codex-attest] branch-diff worktree: $WORKTREE @ $HEAD_SHA_FOR_PATCH"
else
    # working-tree path: split FOCUS into an array (existing callers pass paths separated by spaces)
    # shellcheck disable=SC2206
    REVIEW_ARGS=( $FOCUS )
fi

# Translate internal SCOPE to codex-companion CLI name
case "$SCOPE" in
    branch-diff) NODE_SCOPE="branch" ;;
    *) NODE_SCOPE="$SCOPE" ;;
esac
"$NODE_BIN" "$CODEX_PATH" adversarial-review --wait --scope "$NODE_SCOPE" "${REVIEW_ARGS[@]}" 2>&1 | tee "$TMP_OUT"
CODEX_EXIT=${PIPESTATUS[0]}

# Extract verdict from stdout. codex-companion emits markdown with "Verdict: X"
# line which is reliable; JSON form in log is often truncated. Try markdown first.
VERDICT=$(python3 - "$TMP_OUT" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
# Primary: markdown "Verdict: <label>" lines (H2-2: take FIRST, fail-closed on mismatch)
matches = []
for line in text.splitlines():
    m = re.match(r'^Verdict:\s*(approve|needs-attention|request-changes|reject|block)\s*$', line.strip())
    if m:
        matches.append(m.group(1))
if matches:
    if len(set(matches)) > 1:
        # Header verdict and body/quoted text disagree -> ambiguous, fail closed
        print("ambiguous"); sys.exit(0)
    print(matches[0]); sys.exit(0)
# Fallback 1: complete JSON object anywhere in text
objs = re.findall(r'\{[^{}]*"verdict"\s*:\s*"[^"]+"[^{}]*\}', text)
if objs:
    try: print(json.loads(objs[-1])["verdict"]); sys.exit(0)
    except Exception: pass
# Fallback 2: line-by-line JSON parse
for line in reversed(text.splitlines()):
    line = line.strip()
    if line.startswith("{") and '"verdict"' in line:
        try: print(json.loads(line)["verdict"]); sys.exit(0)
        except Exception: pass
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
    # BD-R2-F1: verify HEAD_BR didn't advance during review
    HEAD_SHA_AFTER_REVIEW=$(git rev-parse "$HEAD_BR")
    if [ "$HEAD_SHA_AFTER_REVIEW" != "$HEAD_SHA_FOR_PATCH" ]; then
        echo "[codex-attest] ERROR: head $HEAD_BR drift moved during review ($HEAD_SHA_FOR_PATCH -> $HEAD_SHA_AFTER_REVIEW); ledger NOT updated" >&2
        exit 13
    fi
    # H4R1: also verify BASE didn't move during review
    BASE_SHA_AFTER_REVIEW=$(git rev-parse "$BASE")
    if [ "$BASE_SHA_AFTER_REVIEW" != "$BASE_SHA_FROZEN" ]; then
        echo "[codex-attest] ERROR: base $BASE drift moved during review ($BASE_SHA_FROZEN -> $BASE_SHA_AFTER_REVIEW); ledger NOT updated" >&2
        exit 13
    fi
    # Use frozen SHAs for fingerprint so it matches exactly what codex saw
    FP=$(ledger_compute_branch_fingerprint "$BASE_SHA_FROZEN" "$HEAD_SHA_FOR_PATCH")
    ledger_write_branch "$HEAD_BR" "$HEAD_SHA_FOR_PATCH" "$BASE" "$FP" "$NOW" "$VERDICT_DIGEST" "$ROUND"
    echo "[codex-attest] ledger: branch:$HEAD_BR@$HEAD_SHA_FOR_PATCH base=$BASE_SHA_FROZEN fp=$FP"
fi

echo "[codex-attest] verdict=approve; ledger updated."
