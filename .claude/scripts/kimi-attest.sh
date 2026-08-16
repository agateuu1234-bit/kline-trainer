#!/usr/bin/env bash
# kimi-attest.sh
# Local wrapper around Kimi Code CLI adversarial-review for spec/plan/branch stage.
# On approve → write attest ledger entry (branch key).
#
# Derived from codex-attest.sh by replacing ONLY the review engine. Every ledger,
# drift-detection, locking and read-back guarantee is inherited verbatim, because
# none of them depend on who the reviewer is.
#
# Three deltas vs the codex path:
#   1. Engine resolution: `kimi` on an allowlisted path, not a pinned companion clone.
#   2. Invocation: `kimi -p <prompt> --output-format stream-json`, run inside the
#      frozen worktree, under a review-only KIMI_CODE_HOME (Read/Grep/Glob only).
#   3. Verdict extraction: pull the assistant turn out of stream-json first, then
#      apply the SAME strict `^Verdict: <label>$` rule as the codex path.
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
            echo "[kimi-attest] ERROR: head SHA auto-computed, do not pass --head-sha" >&2
            exit 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --review-only) REVIEW_ONLY=true; shift ;;
        --scope) SCOPE="$2"; shift 2 ;;
        --focus) FOCUS="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --head) HEAD_BR="$2"; shift 2 ;;
        --target)
            echo "[kimi-attest] ERROR: --target is not supported. Attestation is branch-scoped;" >&2
            echo "  the ledger key is the frozen base...head diff fingerprint, not a file path." >&2
            exit 2 ;;
        *) FOCUS="$FOCUS $1"; shift ;;
    esac
done

case "$SCOPE" in
    working-tree|branch-diff) ;;
    *)
        echo "[kimi-attest] ERROR: unsupported scope '$SCOPE'. Only working-tree (review" >&2
        echo "  only) and branch-diff (attesting) are supported. The companion-native" >&2
        echo "  'branch' scope would review and approve but write no ledger entry, so it is" >&2
        echo "  rejected here; use: --scope branch-diff --head <branch>." >&2
        exit 4 ;;
esac

if [ "$SCOPE" = "working-tree" ] && [ "$REVIEW_ONLY" != "true" ]; then
    echo "[kimi-attest] ERROR: working-tree scope cannot attest and must be requested" >&2
    echo "  explicitly with --review-only. Attestation binds a verdict to exact reviewed" >&2
    echo "  content, but the reviewer reads the live tree, so content can change between" >&2
    echo "  any snapshot and what it actually read. Use --scope branch-diff --head <branch>." >&2
    exit 3
fi

if [ "$SCOPE" = "branch-diff" ] && [ -z "$HEAD_BR" ]; then
    echo "[kimi-attest] ERROR: --scope branch-diff requires --head <branch>" >&2
    exit 5
fi
if [ "$SCOPE" = "branch-diff" ] && [ -z "$BASE" ]; then
    BASE="origin/main"
fi

# P2-F1 (kimi): resolve the kimi binary and refuse PATH-shadowed variants.
# Same threat as the codex path's node check: a `kimi` earlier on PATH would become
# the reviewer, and a reviewer that always prints "Verdict: approve" silently turns
# the gate into a rubber stamp. Fail closed on anything outside the allowlist.
KIMI_BIN=$(command -v kimi 2>/dev/null || true)
if [ -z "$KIMI_BIN" ]; then
    echo "[kimi-attest] ERROR: 'kimi' not found on PATH (install: npm i -g @moonshot-ai/kimi-code)" >&2
    exit 10
fi
KIMI_BIN=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$KIMI_BIN")

# Reviewer capability comes from kimi.pin.json, which lives in the repo -- NOT from the
# environment. Defaulting these to env vars made "pinned" a misnomer: an exported
# KIMI_ATTEST_MIN_CONTEXT=1 plus a weak model would have been consumed by the generator
# AND by the verifier below, so the check would validate the downgrade instead of
# catching it, and the gate would silently lower its own bar. codex-attest.sh pins
# through a committed codex.pin.json for the same reason; this restores the symmetry.
# Lowering the bar now requires editing a tracked file, which shows up in review.
KIMI_PIN="$SCRIPT_DIR/../../kimi.pin.json"
_read_kimi_pin() {
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['kimi_code'][sys.argv[2]])" \
        "$KIMI_PIN" "$1" 2>/dev/null
}
KIMI_MODEL=$(_read_kimi_pin model) || KIMI_MODEL=""
KIMI_EFFORT=$(_read_kimi_pin effort) || KIMI_EFFORT=""
KIMI_MIN_CONTEXT=$(_read_kimi_pin min_context_size) || KIMI_MIN_CONTEXT=""
# Test-mode overrides only. Production sessions never set KIMI_ATTEST_TEST_MODE, so the
# pin is the only source of these values there.
if [ "${KIMI_ATTEST_TEST_MODE:-0}" = "1" ]; then
    KIMI_MODEL="${KIMI_ATTEST_MODEL:-$KIMI_MODEL}"
    KIMI_EFFORT="${KIMI_ATTEST_EFFORT:-$KIMI_EFFORT}"
    KIMI_MIN_CONTEXT="${KIMI_ATTEST_MIN_CONTEXT:-$KIMI_MIN_CONTEXT}"
fi
if [ -z "$KIMI_MODEL" ] || [ -z "$KIMI_EFFORT" ] || [ -z "$KIMI_MIN_CONTEXT" ]; then
    echo "[kimi-attest] ERROR: cannot read reviewer pin from $KIMI_PIN" >&2
    echo "  (need kimi_code.model / .effort / .min_context_size); refusing to review" >&2
    exit 3
fi
# Test-mode bypass (tests set KIMI_ATTEST_TEST_MODE=1 + stub $KIMI_BIN location).
# Production sessions never set this.
if [ "${KIMI_ATTEST_TEST_MODE:-0}" != "1" ]; then
    case "$KIMI_BIN" in
        /usr/bin/kimi|/usr/local/bin/kimi|/opt/homebrew/bin/kimi|/opt/local/bin/kimi) ;;
        /opt/homebrew/lib/node_modules/@moonshot-ai/*) ;;   # npm -g realpath under Homebrew
        /usr/local/lib/node_modules/@moonshot-ai/*) ;;      # npm -g realpath under /usr/local
        "$HOME"/.nvm/*|"$HOME"/.volta/*|"$HOME"/.asdf/*) ;;
        *)
            echo "[kimi-attest] ERROR: kimi resolved to untrusted path: $KIMI_BIN" >&2
            echo "  Allowlist: /usr/bin, /usr/local/bin, /opt/homebrew/bin, /opt/local/bin," >&2
            echo "  npm -g node_modules/@moonshot-ai/*, \$HOME/.nvm, \$HOME/.volta, \$HOME/.asdf" >&2
            echo "  (set KIMI_ATTEST_TEST_MODE=1 for test suites only; NEVER in production)" >&2
            exit 11
            ;;
    esac
fi

HEAD_SHA_GIT=$(git rev-parse HEAD 2>/dev/null || echo "untracked")
echo "[kimi-attest] auto HEAD=$HEAD_SHA_GIT  scope=$SCOPE"

# Dry-run short-circuits BEFORE building the review-only home (no side effects on dry-run).
if $DRY_RUN; then
    echo "[kimi-attest] DRY RUN - would execute: $KIMI_BIN -m $KIMI_MODEL -p <adversarial-review prompt> --output-format stream-json (scope=$SCOPE, effort=$KIMI_EFFORT, min-context=$KIMI_MIN_CONTEXT, review-only KIMI_CODE_HOME, focus=$FOCUS)"
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
            echo "[kimi-attest] ERROR: $out does not match its cycle logs." >&2
            python3 "$LEDGER_CHECKER" --check --logs "$logs" --out "$out" >&2 || true
            echo "  Regenerate it before reviewing; a cycle seeded with incomplete history" >&2
            echo "  does not satisfy spec section 4.5 and cannot count under 8.5A." >&2
            exit 6
        fi
    done
fi

# The review prompt is the format contract. codex-companion owned this on the codex
# path; here it is ours, and the ledger's meaning depends on it, so a missing or
# unreadable prompt is fail-closed rather than "review with whatever default".
PROMPT_FILE="$SCRIPT_DIR/kimi-review-prompt.md"
if [ ! -r "$PROMPT_FILE" ]; then
    echo "[kimi-attest] ERROR: review prompt not readable: $PROMPT_FILE" >&2
    exit 3
fi

# Review-only KIMI_CODE_HOME. `kimi -p` hard-codes permission='auto' and auto-approves
# every tool call -- verified empirically: an unconstrained `kimi -p` rewrote a canary
# file without asking. A reviewer that can edit the tree under review can approve its
# own edits, so the write tools are removed at the tool-registry level (an allowlist,
# not a per-call prompt) and the deny rules below are belt-and-braces.
# Kept outside the repo so it is never committed, and separate from ~/.kimi-code so a
# review can never inherit interactive settings.
# Location is test-mode-gated like the pin values. Left ungated it was the one knob a
# caller could still turn in production, and the credentials that seat the reviewing
# identity live under it.
KIMI_HOME_RO="$HOME/.cache/prjwf-kimi-attest-home"
if [ "${KIMI_ATTEST_TEST_MODE:-0}" = "1" ]; then
    KIMI_HOME_RO="${KIMI_ATTEST_HOME:-$KIMI_HOME_RO}"
fi
mkdir -p "$KIMI_HOME_RO"
chmod 700 "$KIMI_HOME_RO" 2>/dev/null || true
# Credentials are symlinked, never copied: no second copy of the token to leak or
# go stale. If the user has not logged in, fail closed here rather than at first call.
for _c in oauth credentials device_id; do
    if [ ! -e "$HOME/.kimi-code/$_c" ]; then
        echo "[kimi-attest] ERROR: kimi is not logged in ($HOME/.kimi-code/$_c missing). Run: kimi login" >&2
        exit 12
    fi
    # Relink every run, same invariant the config below already gets: linking only when
    # absent left whatever the home already contained in place, so a pre-seeded
    # KIMI_ATTEST_HOME could run the review under a different account. It also aborted
    # outright on a dangling link -- `-e` follows symlinks and reports false, then
    # `ln -s` fails with a bare "File exists" and set -e kills the script with no
    # diagnostic (reproduced). rm -f clears a link or file but never a directory, so a
    # directory in the way still surfaces as an explicit error below.
    rm -f "$KIMI_HOME_RO/$_c" 2>/dev/null || true
    ln -s "$HOME/.kimi-code/$_c" "$KIMI_HOME_RO/$_c" || {
        echo "[kimi-attest] ERROR: cannot link credential '$_c' into the review-only home" >&2
        echo "  ($KIMI_HOME_RO/$_c is in the way and is not a file or symlink); refusing to review" >&2
        exit 12
    }
done
# PreToolUse guard. The credentials above are mounted inside a home the reviewer can
# read, and the tool allowlist cannot express "Read, except these paths" -- so without
# this, review content that induces the model to open them (the threat model this file
# already assumes) walks the token into the transcript. [[permission.rules]] cannot do
# it either: `kimi -p` hard-codes permission='auto' and ignores them, verified by
# denying "Read" outright and watching the read succeed. The hook is the only gate that
# actually runs. Regenerated every run for the same reason the config is.
KIMI_GUARD_HOOK="$KIMI_HOME_RO/attest-guard-hook.py"
KIMI_HOME_RO="$KIMI_HOME_RO" python3 - "$KIMI_GUARD_HOOK" <<'GUARDGEN'
import json, os, sys
out = sys.argv[1]
home = os.path.realpath(os.environ["KIMI_HOME_RO"])
protected = sorted({home,
                    os.path.realpath(os.path.expanduser("~/.kimi-code"))} |
                   {os.path.realpath(os.path.join(home, x))
                    for x in ("oauth", "credentials", "device_id")})
body = '''#!/usr/bin/env python3
"""PreToolUse gate: the reviewer may not read the credentials that authenticate it.

Generated by kimi-attest.sh; edits are overwritten on the next run.

Matching is by RESOLVED path, not substring: blocking any path containing "oauth"
would also block a project's own OAuth sources, which are ordinary review material.
Fails closed on unparsable input and on anything it cannot resolve.
"""
import json, os, sys

PROTECTED = %s


def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


try:
    d = json.load(sys.stdin)
except Exception as e:
    print(f"attest-guard: unparsable hook input ({e}); refusing", file=sys.stderr)
    sys.exit(2)

cwd = d.get("cwd") or os.getcwd()
for value in (d.get("tool_input") or {}).values():
    if not isinstance(value, str) or not value:
        continue
    candidates = [value]
    if any(ch in value for ch in "*?["):
        # A glob is not a path, but an absolute one still names a directory.
        candidates.append(value.split("*")[0].split("?")[0].split("[")[0])
    for cand in candidates:
        try:
            r = os.path.realpath(cand if os.path.isabs(cand) else os.path.join(cwd, cand))
        except Exception:
            continue
        for root in PROTECTED:
            if under(r, root):
                print(f"attest-guard: refused {d.get('tool_name','?')} on {value} — "
                      f"credentials under {root} are mounted for authentication only",
                      file=sys.stderr)
                sys.exit(2)
sys.exit(0)
''' % json.dumps(protected)
open(out, "w", encoding="utf-8").write(body)
os.chmod(out, 0o700)
GUARDGEN
[ -x "$KIMI_GUARD_HOOK" ] || {
    echo "[kimi-attest] ERROR: could not generate the credential guard hook; refusing to review" >&2
    exit 12
}

# Regenerate the config every run: a hand-edited home must not be able to silently
# restore write tools and keep producing ledger-writing approvals.
if [ ! -r "$HOME/.kimi-code/config.toml" ]; then
    echo "[kimi-attest] ERROR: $HOME/.kimi-code/config.toml missing; run kimi login first" >&2
    exit 12
fi
# Strip any [tools] / [permission*] tables from the source before appending ours.
# Blindly concatenating produced a duplicate table whenever the user's own config
# defined either one, and TOML forbids redefining a table: kimi then refuses to start
# with "No model configured", which is fail-closed but diagnoses the wrong thing.
# Found by this script reviewing its own diff.
KIMI_MODEL="$KIMI_MODEL" KIMI_EFFORT="$KIMI_EFFORT" KIMI_GUARD_HOOK="$KIMI_GUARD_HOOK" \
python3 - "$HOME/.kimi-code/config.toml" > "$KIMI_HOME_RO/config.toml" <<'PY'
import json, os, sys
MODEL = os.environ["KIMI_MODEL"]
EFFORT = os.environ["KIMI_EFFORT"]
skip = False
in_model = False
saw_effort = False
out = []

def close_model_table():
    # Force the tier even when the source table omits it, so an absent key cannot
    # silently mean "whatever the CLI defaults to".
    global saw_effort
    if in_model and not saw_effort:
        out.append(f'default_effort = "{EFFORT}"')
    saw_effort = False

for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    s = line.strip()
    # Strip a trailing comment before testing for a table header: `[tools] # mine` is a
    # valid header, and requiring the line to END with "]" let it through the stripper,
    # after which our own [tools] made a duplicate table and kimi refused to start with
    # an unrelated-looking error. Quotes are respected so `[models."a#b"]` survives.
    if s.startswith("["):
        cut, inq = len(s), False
        for i, ch in enumerate(s):
            if ch == '"':
                inq = not inq
            elif ch == "#" and not inq:
                cut = i
                break
        s = s[:cut].strip()
    if s.startswith("[") and s.endswith("]"):
        name = s.strip("[]").strip()
        close_model_table()
        in_model = name == f'models."{MODEL}"'
        # Drop the tables we are about to define, and only those.
        skip = name == "tools" or name == "permission" or name.startswith("permission.")
    if skip:
        continue
    # Pin the reasoning tier for the reviewing model. Inheriting it would let an
    # unrelated edit to the interactive config quietly downgrade every review.
    if in_model and s.startswith("default_effort"):
        out.append(f'default_effort = "{EFFORT}"')
        saw_effort = True
        continue
    out.append(line)
close_model_table()
print("\n".join(out))
print()
print('# === review-only lock — regenerated by kimi-attest.sh on every run, do not edit ===')
# The allowlist is the load-bearing control: it removes the write tools at registration
# so the model is never offered them. Verified empirically.
print('[tools]')
print('enabled = ["Read", "Grep", "Glob", "LS"]')
# NOT belt-and-braces: [[permission.rules]] has NO effect under `kimi -p`, which
# hard-codes permission='auto' and auto-approves every call. Denying "Read" outright
# was verified to change nothing. They are emitted only so an interactive session
# started against this home behaves the same way; the runtime gate is the hook below.
for tool in ("Write", "Edit", "Bash"):
    print()
    print('[[permission.rules]]')
    print('decision = "deny"')
    print(f'pattern = "{tool}"')
# The credentials that authenticate the reviewer are mounted inside this home, and the
# allowlist cannot express "Read, except these paths". A PreToolUse hook can, and it is
# the only control that actually runs under -p.
print()
print('[[hooks]]')
print('event = "PreToolUse"')
print(f'command = {json.dumps(os.environ["KIMI_GUARD_HOOK"])}')
print('timeout = 15')
PY

# The read-only posture is only real if the file actually parses; a config kimi
# rejects would fall back to defaults or refuse to run, and "refuse to run" must be
# detected here rather than surfacing later as an unrelated-looking model error.
KIMI_MODEL="$KIMI_MODEL" KIMI_EFFORT="$KIMI_EFFORT" KIMI_MIN_CONTEXT="$KIMI_MIN_CONTEXT" \
python3 - "$KIMI_HOME_RO/config.toml" <<'PY' || {
import os, sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        # Fail CLOSED. This block is the only thing enforcing the pin -- write tools
        # absent, deny rules present, context floor met, effort forced. Exiting 0 here
        # meant "verified" to the caller, so on any python < 3.11 without tomli the
        # floor silently stopped applying: macOS ships /usr/bin/python3 3.9, so a PATH
        # without Homebrew's python reviews with no enforcement at all. The earlier
        # claim that "kimi will still fail closed" holds only for malformed TOML, not
        # for a config that parses fine while sitting below the pinned floor.
        print("cannot verify the review-only config: python >= 3.11 or the 'tomli' "
              "package is required (found %d.%d)" % sys.version_info[:2], file=sys.stderr)
        sys.exit(1)
try:
    d = tomllib.load(open(sys.argv[1], "rb"))
except Exception as e:
    print(f"invalid TOML: {e}", file=sys.stderr); sys.exit(1)
WRITE_TOOLS = ("Write", "Edit", "Bash")
tools = (d.get("tools") or {}).get("enabled")
if not tools or any(t in tools for t in WRITE_TOOLS):
    print(f"tool allowlist did not survive generation: {tools}", file=sys.stderr); sys.exit(1)
# Check the deny rules too, not just the allowlist. A check that validates only half
# of what it claims to protect would pass a config whose stripper dropped the rules,
# or one where a surviving user `allow` rule shadows them.
rules = (d.get("permission") or {}).get("rules") or []
denied = {r.get("pattern") for r in rules if r.get("decision") == "deny"}
missing = [t for t in WRITE_TOOLS if t not in denied]
if missing:
    print(f"deny rules missing for: {missing}", file=sys.stderr); sys.exit(1)
allowed = {r.get("pattern") for r in rules if r.get("decision") == "allow"}
shadowed = [t for t in WRITE_TOOLS if t in allowed]
if shadowed:
    print(f"a surviving allow rule shadows the deny for: {shadowed}", file=sys.stderr); sys.exit(1)

# The reviewer's capability is part of what the ledger attests. Verify the model this
# run will actually seat, rather than assuming the generation step landed.
model = os.environ["KIMI_MODEL"]
spec = (d.get("models") or {}).get(model)
if spec is None:
    print(f"reviewing model not defined in config: {model}", file=sys.stderr); sys.exit(1)
ctx = spec.get("max_context_size") or 0
if ctx < int(os.environ["KIMI_MIN_CONTEXT"]):
    print(f"{model} context {ctx} is below the required floor {os.environ['KIMI_MIN_CONTEXT']}",
          file=sys.stderr); sys.exit(1)
want_effort = os.environ["KIMI_EFFORT"]
got_effort = spec.get("default_effort")
if got_effort != want_effort:
    print(f"{model} effort is {got_effort!r}, expected {want_effort!r}", file=sys.stderr); sys.exit(1)
supported = spec.get("support_efforts")
if supported and want_effort not in supported:
    print(f"{model} does not support effort {want_effort!r} (supports {supported})",
          file=sys.stderr); sys.exit(1)
PY
    echo "[kimi-attest] ERROR: generated review-only config is not usable; refusing to review" >&2
    exit 12
}

echo "[kimi-attest] invoking kimi (review-only) model=$KIMI_MODEL effort=$KIMI_EFFORT"
TMP_OUT=$(mktemp)
TMP_DIFF=$(mktemp)
TMP_PATCH=""
trap 'rm -f "$TMP_OUT" "$TMP_DIFF" ${TMP_PATCH:+"$TMP_PATCH"}' EXIT

# In branch-diff mode the review runs against a frozen checkout, not the live tree,
# so a verdict always describes an immutable revision.
if [ "$SCOPE" = "branch-diff" ]; then
    HEAD_SHA_FOR_PATCH=$(git rev-parse "$HEAD_BR")
    BASE_SHA_FROZEN=$(git rev-parse "$BASE" 2>/dev/null) || {
        echo "[kimi-attest] ERROR: cannot resolve base ref $BASE" >&2
        exit 15
    }
    # H2-3: use a git worktree at the frozen SHA and run the reviewer inside it, so it
    # reads the target revision rather than whatever the current checkout happens to be.
    WORKTREE=$(mktemp -d -t kimi-attest-wt.XXXXXX)
    _cleanup_worktree() {
        local ec=$?
        # H4R4: this trap replaces the top-level one, so it must clean everything the
        # top-level trap covered -- TMP_DIFF included, or branch-diff runs leak it.
        rm -f "$TMP_OUT" "$TMP_DIFF" 2>/dev/null || true
        chmod -R u+w "$WORKTREE" 2>/dev/null || true
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
    chmod 700 "$WORKTREE" 2>/dev/null || true
    if ! git worktree add --detach "$WORKTREE" "$HEAD_SHA_FOR_PATCH" 2>/dev/null; then
        echo "[kimi-attest] ERROR: cannot create worktree at $HEAD_SHA_FOR_PATCH" >&2
        exit 14
    fi
    # Raise the cost of tampering with the reviewed bytes: private mode, and the tree
    # made non-writable after checkout. This does NOT make the input provably immutable
    # against a same-user process that chmods it back -- the reviewer reads files
    # throughout the run, so a mid-run edit cannot be excluded by an end check alone.
    # It converts a passive race into active tampering, and the residual risk is
    # recorded rather than claimed solved.
    find "$WORKTREE" -type f ! -path '*/.git/*' -exec chmod a-w {} + 2>/dev/null || true
    # The diff is computed from the FROZEN shas, so the reviewed bytes and the ledger
    # fingerprint describe the same revision even if the branch moves mid-run (the
    # drift checks below then reject the run anyway).
    #
    # --no-color --no-ext-diff mirrors ledger_compute_branch_fingerprint exactly. Without
    # them a repo-level `diff.external` or `color.ui=always` would show the reviewer a
    # different byte stream than the one the ledger fingerprints -- the reviewer would
    # be attesting something other than what gets recorded.
    git diff --no-color --no-ext-diff "$BASE_SHA_FROZEN...$HEAD_SHA_FOR_PATCH" > "$TMP_DIFF"
    REVIEW_CWD="$WORKTREE"
    echo "[kimi-attest] branch-diff review snapshot @ $HEAD_SHA_FOR_PATCH (path not disclosed)"
else
    git diff --no-color --no-ext-diff HEAD > "$TMP_DIFF"
    # `git diff HEAD` omits untracked files, so a change that both edits a tracked file
    # and adds a new one would pass the non-empty check below while the new file never
    # reaches the reviewer -- who was told the diff IS the change under review. Append
    # them as real diffs against /dev/null so the format stays uniform.
    git ls-files --others --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' _f; do
        git diff --no-color --no-ext-diff --no-index -- /dev/null "$_f" || true
    done >> "$TMP_DIFF"
    REVIEW_CWD="$PWD"
fi

if [ ! -s "$TMP_DIFF" ]; then
    echo "[kimi-attest] ERROR: the diff under review is empty; refusing to issue a verdict" >&2
    exit 16
fi

# FOCUS is interpolated into the prompt as prose, never as argv. On the codex path a
# flag-shaped word inside the focus text could be parsed as an option; here the whole
# prompt is a single argument, so that class of bug cannot occur. The ledger key is
# the frozen diff fingerprint, untouched by focus text either way.
PROMPT=$(sed -e "s|__DIFF_FILE__|$TMP_DIFF|g" "$PROMPT_FILE")
if [ -n "${FOCUS// /}" ]; then
    PROMPT="$PROMPT

审查重点（由调用方指定）：$FOCUS"
fi

# Run kimi from inside the reviewed tree so it can open the surrounding files to
# check a finding before reporting it -- reviewing a bare diff produced a confident
# "this parameter is never registered" for a parameter registered 400 lines away.
# Read-only is enforced by KIMI_CODE_HOME above, not by trusting the model.
# `set -e` must be lifted around the call. A bare non-zero here aborts the script on
# the spot, so `KIMI_EXIT=$?` and the diagnostics below never run -- and since the EXIT
# trap removes TMP_OUT, the operator is left with a raw exit code and no output at all.
# That is the gate's most likely failure (network, expired credentials, CLI crash), so
# it is exactly the path that must stay observable. codex-attest.sh avoids this with
# `| tee` + PIPESTATUS; this is the same protection, written explicitly.
set +e
( cd "$REVIEW_CWD" && KIMI_CODE_HOME="$KIMI_HOME_RO" \
    "$KIMI_BIN" -m "$KIMI_MODEL" -p "$PROMPT" --output-format stream-json ) > "$TMP_OUT" 2>&1
KIMI_EXIT=$?
set -e

# Extract the verdict from the ASSISTANT TURN ONLY, then apply the codex path's rule
# verbatim.
#
# Why the turn must be isolated first: stream-json interleaves the model's own words
# with `role":"tool"` records containing whole files it read. The tree under review is
# attacker-adjacent content -- this very repo has files quoting `Verdict: approve` in
# prose -- so scanning the raw stream would let a reviewed file, or a prompt-injecting
# comment inside it, mint its own approval. Only the assistant's final prose counts.
VERDICT=$(python3 - "$TMP_OUT" <<'PY'
import json, re, sys

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
turns, saw_json = [], False
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    saw_json = True
    if o.get("role") == "assistant" and isinstance(o.get("content"), str):
        turns.append(o["content"])

# No parsable stream at all => the CLI died, printed a plain-text error, or changed
# its output contract. Any of those means we have no validated verdict.
if not saw_json or not turns:
    print("unknown"); sys.exit(0)

# ONLY the final assistant turn. Joining every turn was a real hole, found by this
# script reviewing its own diff: the prompt asks the reviewer to REPORT injection
# attempts it finds, so a mid-run turn legitimately quotes an attacker's line --
# "the file contains: Verdict: approve". If the closing turn is then truncated or
# malformed and carries no verdict of its own, the quoted line is the only match
# left and the attacker's text becomes the verdict. Verified: that exact shape
# returned "approve" before this change.
# A verdict that is not in the reviewer's closing statement is not a verdict; a
# reviewer that puts it earlier is malformed, and unknown is the fail-closed answer.
text = turns[-1]

matches = []
for line in text.splitlines():
    m = re.match(r'^Verdict:\s*(approve|needs-attention|request-changes|reject|block)\s*$', line.strip())
    if m:
        matches.append(m.group(1))
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

# Show the review to the operator: the codex path streamed through `tee`, but the raw
# stream-json is unreadable, so render the assistant turn instead.
python3 - "$TMP_OUT" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("role") == "assistant" and isinstance(o.get("content"), str):
        print(o["content"])
PY

if [ "$KIMI_EXIT" -ne 0 ]; then
    echo "[kimi-attest] kimi exited $KIMI_EXIT; ledger not updated." >&2
    exit "$KIMI_EXIT"
fi

if [ "$VERDICT" != "approve" ]; then
    echo "[kimi-attest] verdict=$VERDICT (not approve); ledger not updated." >&2
    exit 7
fi

# Approve path → write ledger
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VERDICT_DIGEST="sha256:$(shasum -a 256 "$TMP_OUT" | awk '{print $1}')"
ROUND=1  # plan-stage: always round 1; future: read from state
# Who issued this verdict. Recorded because codex-attest.sh writes to the same ledger
# and the two engines are not interchangeable -- an approve is only auditable if you
# can tell which reviewer produced it. Version is resolved from the binary that
# actually ran, not hardcoded, so an upgrade cannot silently misattribute entries.
# The version string is validated, not trusted: `--version` on a wrapper, a stub or a
# future release can print anything, and an unchecked value lands verbatim in the
# ledger -- a stub that emitted stream-json for every argv wrote a JSON fragment into
# this field during testing. Accept only a dotted version, else record "unknown".
# `|| _kimi_ver=""` is load-bearing: under `set -e` + `pipefail` a failing --version
# makes the assignment itself fail, and this line runs AFTER the verdict is already
# approve but BEFORE the ledger write -- so a passed review would vanish with no output
# and no entry. Degrade to "unknown", never abort here.
_kimi_ver=$("$KIMI_BIN" --version 2>/dev/null | tr -d '\r' | head -n1 | tr -d '[:space:]') || _kimi_ver=""
case "$_kimi_ver" in
    [0-9]*.[0-9]*) : ;;
    *) _kimi_ver="unknown" ;;
esac
# Digest of the binary that actually ran. A self-reported version is only as trustworthy
# as the thing reporting it: this path verifies WHERE kimi is installed but never WHAT it
# contains, so a routine `npm -g update` -- or a tampered install -- silently becomes the
# reviewer while still printing any version it likes. The codex path does verify its
# reviewer's bytes (verify-codex-tree.mjs against the file_tree hash in codex.pin.json);
# this one does not, so the symmetry claimed at the top of this file covers the
# configuration pin ONLY, not reviewer integrity. Recording an unforgeable digest does
# not close that gap, but it makes the gap auditable after the fact: two entries with
# the same version and different digests are visibly not the same reviewer.
_kimi_sha=$(shasum -a 256 "$KIMI_BIN" 2>/dev/null | awk '{print $1}') || _kimi_sha=""
[ -n "$_kimi_sha" ] || _kimi_sha="unavailable"
# The MODEL, not just the CLI version. Reviewing capability is a property of the model:
# k3 carries a 1M context against kimi-for-coding's 256K, which is the difference
# between holding the surrounding code while cross-checking a finding and guessing at
# it. An entry that names only the CLI cannot distinguish a verdict from a strong
# reviewer from one produced by whatever `default_model` happened to be set to.
REVIEWER="$KIMI_MODEL@kimi-code/$_kimi_ver+sha256:${_kimi_sha:0:16}"

if [ "$SCOPE" = "working-tree" ]; then
    # Deliberately no ledger entry, ever. Attestation binds a verdict to exact
    # reviewed content, but the reviewer reads the live tree, so a change-read-restore
    # sequence defeats any snapshot comparison. The previous implementation also keyed
    # the ledger on the HEAD blob, attesting a modified tracked file with its
    # pre-change content while reporting success. branch-diff is the sound path: it
    # reviews a detached worktree pinned to a frozen SHA, verifies neither base nor
    # head moved, and keys the ledger on an immutable diff fingerprint.
    echo "[kimi-attest] review complete, verdict=approve. No ledger entry: working-tree" >&2
    echo "  scope cannot attest. Commit and use: --scope branch-diff --head <branch>" >&2
    exit 20
elif [ "$SCOPE" = "branch-diff" ] && [ "$REVIEW_ONLY" = "true" ]; then
    # --review-only means "review, record nothing" -- it was only ever read on the
    # working-tree path, so passing it with branch-diff silently wrote an attestation
    # anyway. The entry was accurate, but a caller who asked not to record one got one.
    echo "[kimi-attest] review complete, verdict=approve. No ledger entry: --review-only" >&2
    echo "  was requested. Re-run without it to attest this branch." >&2
    exit 20
elif [ "$SCOPE" = "branch-diff" ]; then
    # BD-R2-F1: verify HEAD_BR didn't advance during review
    HEAD_SHA_AFTER_REVIEW=$(git rev-parse "$HEAD_BR")
    if [ "$HEAD_SHA_AFTER_REVIEW" != "$HEAD_SHA_FOR_PATCH" ]; then
        echo "[kimi-attest] ERROR: head $HEAD_BR drift moved during review ($HEAD_SHA_FOR_PATCH -> $HEAD_SHA_AFTER_REVIEW); ledger NOT updated" >&2
        exit 13
    fi
    # H4R1: also verify BASE didn't move during review
    BASE_SHA_AFTER_REVIEW=$(git rev-parse "$BASE")
    if [ "$BASE_SHA_AFTER_REVIEW" != "$BASE_SHA_FROZEN" ]; then
        echo "[kimi-attest] ERROR: base $BASE drift moved during review ($BASE_SHA_FROZEN -> $BASE_SHA_AFTER_REVIEW); ledger NOT updated" >&2
        exit 13
    fi
    # The review worktree is writable and its path was printed, so verify it still
    # holds exactly the frozen commit and nothing was edited in it during the run.
    # Checking only HEAD_BR and BASE proves the branch did not move; it says nothing
    # about what the reviewer was actually looking at.
    WT_HEAD=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "unknown")
    if [ "$WT_HEAD" != "$HEAD_SHA_FOR_PATCH" ]; then
        echo "[kimi-attest] ERROR: review worktree moved ($HEAD_SHA_FOR_PATCH -> $WT_HEAD);" >&2
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
        echo "[kimi-attest] ERROR: cannot read the review worktree state (git exit $WT_STATUS_RC);" >&2
        echo "  cannot prove the reviewer saw the frozen revision. ledger NOT updated" >&2
        exit 19
    fi
    if [ -n "$WT_STATUS" ]; then
        echo "[kimi-attest] ERROR: review worktree was modified during the review;" >&2
        echo "  the reviewer saw content that is not the frozen revision. ledger NOT updated" >&2
        exit 19
    fi

    # Use frozen SHAs for fingerprint so it matches exactly what codex saw
    FP=$(ledger_compute_branch_fingerprint "$BASE_SHA_FROZEN" "$HEAD_SHA_FOR_PATCH")
    # ledger_write_branch is read-modify-write, so two concurrent approvals could both
    # exit 0 while the later write drops the earlier entry. Serialize, then prove the
    # exact key landed with the expected fingerprint before claiming success.
    ledger_lock_acquire || {
        echo "[kimi-attest] ERROR: could not acquire the ledger lock; ledger NOT updated" >&2
        exit 21
    }
    # finally-style release. Under set -e any failure in the write, fsync, replace or
    # read-back exits before an inline release would run, orphaning the lock and making
    # every later attestation and override wait out the timeout instead of recovering.
    #
    # BUGFIX vs codex-attest.sh: installing a bare `trap 'ledger_lock_release'` here
    # REPLACES the _cleanup_worktree trap set for branch-diff, so the approve path --
    # the only path that reaches this line -- left its checkout behind every time. The
    # symptom is a `prunable` worktree pointing into /var/folders for every successful
    # attestation (this repo carried one for the 2026-08-09 spec-align approval). The
    # release must therefore be composed with the existing cleanup, not substituted for it.
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
        echo "[kimi-attest] ERROR: ledger read-back mismatch for branch:$HEAD_BR@$HEAD_SHA_FOR_PATCH" >&2
        echo "  expected $FP|$BASE_SHA_FROZEN, got '${READBACK:-<missing>}'. Not reporting success." >&2
        exit 22
    fi
    echo "[kimi-attest] ledger: branch:$HEAD_BR@$HEAD_SHA_FOR_PATCH base=$BASE_SHA_FROZEN fp=$FP"

else
    # Unreachable given the allowlist above, but a future scope must not be able to
    # reach the success line without an attestation having been written.
    echo "[kimi-attest] ERROR: no ledger path ran for scope '$SCOPE'; refusing to report" >&2
    echo "  a successful attestation." >&2
    exit 5
fi

echo "[kimi-attest] verdict=approve; ledger updated."
