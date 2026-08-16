#!/usr/bin/env bash
# codex-attest.sh
# Local wrapper around codex-companion adversarial-review for spec/plan/branch stage.
# On approve → write attest ledger entry (file or branch key).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/ledger-lib.sh"

DRY_RUN=false
REVIEW_ONLY=false
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
        --review-only) REVIEW_ONLY=true; shift ;;
        --scope) SCOPE="$2"; shift 2 ;;
        --focus) FOCUS="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --head) HEAD_BR="$2"; shift 2 ;;
        --target)
            echo "[codex-attest] ERROR: --target is not supported. Attestation is branch-scoped;" >&2
            echo "  the ledger key is the frozen base...head diff fingerprint, not a file path." >&2
            exit 2 ;;
        *) FOCUS="$FOCUS $1"; shift ;;
    esac
done

case "$SCOPE" in
    working-tree|branch-diff) ;;
    *)
        echo "[codex-attest] ERROR: unsupported scope '$SCOPE'. Only working-tree (review" >&2
        echo "  only) and branch-diff (attesting) are supported. The companion-native" >&2
        echo "  'branch' scope would review and approve but write no ledger entry, so it is" >&2
        echo "  rejected here; use: --scope branch-diff --head <branch>." >&2
        exit 4 ;;
esac

if [ "$SCOPE" = "working-tree" ] && [ "$REVIEW_ONLY" != "true" ]; then
    echo "[codex-attest] ERROR: working-tree scope cannot attest and must be requested" >&2
    echo "  explicitly with --review-only. Attestation binds a verdict to exact reviewed" >&2
    echo "  content, but the reviewer reads the live tree, so content can change between" >&2
    echo "  any snapshot and what it actually read. Use --scope branch-diff --head <branch>." >&2
    exit 3
fi

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

HEAD_SHA_GIT=$(git rev-parse HEAD 2>/dev/null || echo "untracked")
echo "[codex-attest] auto HEAD=$HEAD_SHA_GIT  scope=$SCOPE"

# Dry-run short-circuits BEFORE resolving the pinned codex (no clone on dry-run).
if $DRY_RUN; then
    echo "[codex-attest] DRY RUN - would execute: node <pinned codex-companion.mjs via resolve-pinned-codex.sh> adversarial-review --wait --scope $SCOPE $FOCUS"
    exit 0
fi

# The reviewer must receive complete accumulated history (spec section 4.5), and a
# qualifying cycle under 8.5A only counts if it did. A ledger that lags its logs means
# this review would run on incomplete evidence, so refuse before dispatching rather
# than discover it afterwards.
LEDGER_CHECKER="$SCRIPT_DIR/../../tools/build-ledger.py"
if [ -f "$LEDGER_CHECKER" ]; then
    for pair in "REVIEW_LEDGER.md:/tmp/prjwf-spec-R*.log" "DESIGN_REVIEW_LEDGER.md:/tmp/prjwf-design-R*.log"; do
        out="${pair%%:*}"; logs="${pair##*:}"
        [ -f "$out" ] || continue
        if ! python3 "$LEDGER_CHECKER" --check --logs "$logs" --out "$out" >/dev/null 2>&1; then
            echo "[codex-attest] ERROR: $out does not match its cycle logs." >&2
            python3 "$LEDGER_CHECKER" --check --logs "$logs" --out "$out" >&2 || true
            echo "  Regenerate it before reviewing; a cycle seeded with incomplete history" >&2
            echo "  does not satisfy spec section 4.5 and cannot count under 8.5A." >&2
            exit 6
        fi
    done
fi

# Resolve pinned + verified codex-companion.mjs (decoupled from auto-updating plugin cache).
CODEX_PATH="$(bash "$SCRIPT_DIR/resolve-pinned-codex.sh")" || {
    echo "[codex-attest] ERROR: cannot resolve pinned codex (offline / verify failed); use attest-override.sh on a tty." >&2
    exit 3
}
export CLAUDE_PLUGIN_ROOT="$(dirname "$(dirname "$CODEX_PATH")")"   # …/plugins/codex

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
    # H4R5: scope codex-companion plugin state/logs to a wrapper-owned temp dir
    PLUGIN_DATA_DIR=$(mktemp -d -t codex-attest-plugin-data.XXXXXX)
    export CLAUDE_PLUGIN_DATA="$PLUGIN_DATA_DIR"
    _cleanup_worktree() {
        local ec=$?
        # H4R4: also clean up TMP_OUT (previously cleaned by top-level trap we override)
        rm -f "$TMP_OUT" 2>/dev/null || true
        chmod -R u+w "$WORKTREE" 2>/dev/null || true
        git worktree remove --force "$WORKTREE" 2>/dev/null || true
        rm -rf "$WORKTREE" 2>/dev/null || true
        # H4R5: clean up scoped CLAUDE_PLUGIN_DATA dir (companion state/logs)
        rm -rf "$PLUGIN_DATA_DIR" 2>/dev/null || true
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
    chmod 700 "$WORKTREE" 2>/dev/null || true
    if ! git worktree add --detach "$WORKTREE" "$HEAD_SHA_FOR_PATCH" 2>/dev/null; then
        echo "[codex-attest] ERROR: cannot create worktree at $HEAD_SHA_FOR_PATCH" >&2
        exit 14
    fi
    # Raise the cost of tampering with the reviewed bytes: private mode, and the tree
    # made non-writable after checkout. This does NOT make the input provably immutable
    # against a same-user process that chmods it back -- the reviewer reads files
    # throughout the run, so a mid-run edit cannot be excluded by an end check alone.
    # It converts a passive race into active tampering, and the residual risk is
    # recorded rather than claimed solved.
    find "$WORKTREE" -type f ! -path '*/.git/*' -exec chmod a-w {} + 2>/dev/null || true
    # FOCUS goes through as ONE quoted positional. Splitting it would let any
    # flag-shaped word inside the prose -- "--base", "--target" -- be parsed by the
    # companion as an option and consume the next word as its value. That is not
    # hypothetical: an unquoted pass produced `git merge-base HEAD and` and exit 128.
    # The companion joins positionals with a space, so one element round-trips exactly.
    # The ledger key is the frozen diff fingerprint, untouched by focus text.
    REVIEW_ARGS=(--base "$BASE_SHA_FROZEN" --cwd "$WORKTREE" ${FOCUS:+--} ${FOCUS:+"$FOCUS"})
    echo "[codex-attest] branch-diff review snapshot @ $HEAD_SHA_FOR_PATCH (path not disclosed)"
else
    # Same quoting rule as branch mode: one positional, never split. Callers that used
    # to pass bare paths as focus still work, since a single path is one element.
    REVIEW_ARGS=( ${FOCUS:+--} ${FOCUS:+"$FOCUS"} )
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
# A verdict is only a verdict when the companion validated its own result.
# The companion's exit status reflects turn completion, not schema validation: on a
# parse or shape failure it renders "Parse error:" and echoes the model's unvalidated
# output inside a "Raw final message:" block. A stray approval line inside that block
# would otherwise authorize a ledger write for content nobody validated. Reject the
# whole run when either marker is present rather than trying to locate a trustworthy
# region within it.
if "Raw final message:" in text or "Parse error:" in text:
    print("unknown"); sys.exit(0)
# Free-form JSON scraped from stdout is not authoritative either, for the same reason.
if not matches:
    print("unknown"); sys.exit(0)
if len(set(matches)) > 1:
    print("ambiguous"); sys.exit(0)
# A structured verdict may not contradict it.
structured = None
for o in re.findall(r'\{[^{}]*"verdict"\s*:\s*"[^"]+"[^{}]*\}', text):
    try: structured = json.loads(o)["verdict"]
    except Exception: pass
if structured is not None and structured != matches[0]:
    print("ambiguous"); sys.exit(0)
print(matches[0])
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
if [ "$SCOPE" = "working-tree" ]; then
    # Deliberately no ledger entry, ever. Attestation binds a verdict to exact
    # reviewed content, but the reviewer reads the live tree, so a change-read-restore
    # sequence defeats any snapshot comparison. The previous implementation also keyed
    # the ledger on the HEAD blob, attesting a modified tracked file with its
    # pre-change content while reporting success. branch-diff is the sound path: it
    # reviews a detached worktree pinned to a frozen SHA, verifies neither base nor
    # head moved, and keys the ledger on an immutable diff fingerprint.
    echo "[codex-attest] review complete, verdict=approve. No ledger entry: working-tree" >&2
    echo "  scope cannot attest. Commit and use: --scope branch-diff --head <branch>" >&2
    exit 20
elif [ "$SCOPE" = "branch-diff" ]; then
    # Who issued this verdict. kimi-attest.sh writes to the same ledger and the two
    # engines are not interchangeable, so an entry that does not name its reviewer
    # cannot be audited later.
    # Record the pinned COMMIT, not the tag: a tag can be re-pointed upstream, so two
    # approvals recorded as "v1.0.3" could come from different companion trees -- which
    # is precisely the audit precision this field exists to provide. The tag rides along
    # for readability. Path is anchored to this script, not the cwd, so a call from a
    # subdirectory cannot silently degrade the entry to "unknown".
    # Resolved HERE, not before the scope split: REVIEWER is consumed only by the ledger
    # write, so checking it earlier let a pin problem abort --review-only runs that were
    # never going to record anything.
    _CODEX_PIN="$SCRIPT_DIR/../../codex.pin.json"
    REVIEWER=$(python3 - "$_CODEX_PIN" <<'PY' 2>/dev/null
import json, sys
p = json.load(open(sys.argv[1]))["codex_plugin_cc"]
print(f"codex/{p['tag']}@{p['commit_sha']}")
PY
) || REVIEWER=""
    if [ -z "$REVIEWER" ]; then
        echo "[codex-attest] ERROR: cannot read reviewer pin from $_CODEX_PIN;" >&2
        echo "  refusing to attest rather than recording an unidentifiable reviewer." >&2
        exit 3
    fi

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
    # The review worktree is writable and its path was printed, so verify it still
    # holds exactly the frozen commit and nothing was edited in it during the run.
    # Checking only HEAD_BR and BASE proves the branch did not move; it says nothing
    # about what the reviewer was actually looking at.
    WT_HEAD=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "unknown")
    if [ "$WT_HEAD" != "$HEAD_SHA_FOR_PATCH" ]; then
        echo "[codex-attest] ERROR: review worktree moved ($HEAD_SHA_FOR_PATCH -> $WT_HEAD);" >&2
        echo "  the verdict does not describe the frozen revision. ledger NOT updated" >&2
        exit 19
    fi
    # Capture status and exit code separately. Folding them together meant a git
    # failure (corrupt index, unreadable worktree) produced empty stdout, which read
    # as "clean" -- the integrity check failed OPEN on exactly the states it exists to
    # catch. rev-parse above can still succeed with a corrupt index, so it does not
    # cover this.
    WT_STATUS=$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>/dev/null)
    WT_STATUS_RC=$?
    if [ "$WT_STATUS_RC" -ne 0 ]; then
        echo "[codex-attest] ERROR: cannot read the review worktree state (git exit $WT_STATUS_RC);" >&2
        echo "  cannot prove the reviewer saw the frozen revision. ledger NOT updated" >&2
        exit 19
    fi
    if [ -n "$WT_STATUS" ]; then
        echo "[codex-attest] ERROR: review worktree was modified during the review;" >&2
        echo "  the reviewer saw content that is not the frozen revision. ledger NOT updated" >&2
        exit 19
    fi

    # Use frozen SHAs for fingerprint so it matches exactly what codex saw
    FP=$(ledger_compute_branch_fingerprint "$BASE_SHA_FROZEN" "$HEAD_SHA_FOR_PATCH")
    # ledger_write_branch is read-modify-write, so two concurrent approvals could both
    # exit 0 while the later write drops the earlier entry. Serialize, then prove the
    # exact key landed with the expected fingerprint before claiming success.
    ledger_lock_acquire || {
        echo "[codex-attest] ERROR: could not acquire the ledger lock; ledger NOT updated" >&2
        exit 21
    }
    # finally-style release. Under set -e any failure in the write, fsync, replace or
    # read-back exits before an inline release would run, orphaning the lock and making
    # every later attestation and override wait out the timeout instead of recovering.
    #
    # BUGFIX 2026-08-16: a bare `trap 'ledger_lock_release'` here REPLACES the
    # _cleanup_worktree trap installed for branch-diff, so the approve path -- the only
    # path that reaches this line -- leaked its checkout every time. Each successful
    # attestation left a prunable worktree pointing into /var/folders; this repo carried
    # one from the 2026-08-09 spec-align approval (head 99f9d82) until it was pruned.
    # The release must be composed with the existing cleanup, not substituted for it.
    _release_lock_then_cleanup() {
        local ec=$?
        ledger_lock_release 2>/dev/null || true
        # `ec` is captured on entry and returned unconditionally. Falling through to
        # _cleanup_worktree's return value instead would hand back the status of the
        # `declare -f` probe (always 0), so the "preserve the original exit status"
        # mechanism was inert on this path. Harmless today -- bash resumes the pending
        # exit status after an EXIT handler returns -- but the code claimed a guarantee
        # it did not implement, which is exactly what breaks when this pair is reused
        # somewhere a trap's return value does carry meaning.
        if declare -f _cleanup_worktree >/dev/null 2>&1; then
            _cleanup_worktree "$@"
        fi
        return $ec
    }
    trap '_release_lock_then_cleanup' EXIT
    trap '_release_lock_then_cleanup SIGNAL-INT' INT
    trap '_release_lock_then_cleanup SIGNAL-TERM' TERM
    trap '_release_lock_then_cleanup SIGNAL-HUP' HUP

    ledger_write_branch "$HEAD_BR" "$HEAD_SHA_FOR_PATCH" "$BASE" "$BASE_SHA_FROZEN" "$FP" "$NOW" "$VERDICT_DIGEST" "$ROUND" "$REVIEWER"

    # Read back while still holding the lock: releasing first would leave a window in
    # which another writer could replace the file between the write and the check.
    READBACK=$(ledger_get_branch_fingerprint "$HEAD_BR" "$HEAD_SHA_FOR_PATCH")
    ledger_lock_release
    if [ "$READBACK" != "$FP|$BASE_SHA_FROZEN" ]; then
        echo "[codex-attest] ERROR: ledger read-back mismatch for branch:$HEAD_BR@$HEAD_SHA_FOR_PATCH" >&2
        echo "  expected $FP|$BASE_SHA_FROZEN, got '${READBACK:-<missing>}'. Not reporting success." >&2
        exit 22
    fi
    echo "[codex-attest] ledger: branch:$HEAD_BR@$HEAD_SHA_FOR_PATCH base=$BASE_SHA_FROZEN fp=$FP"

else
    # Unreachable given the allowlist above, but a future scope must not be able to
    # reach the success line without an attestation having been written.
    echo "[codex-attest] ERROR: no ledger path ran for scope '$SCOPE'; refusing to report" >&2
    echo "  a successful attestation." >&2
    exit 5
fi

echo "[codex-attest] verdict=approve; ledger updated."
