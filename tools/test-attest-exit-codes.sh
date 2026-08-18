#!/usr/bin/env bash
# test-attest-exit-codes.sh
# Regression cover for the EXIT/signal trap composition in {codex,kimi}-attest.sh.
#
# Why this exists: the ledger-writing path installs a second EXIT trap on top of the
# branch-diff worktree-cleanup trap. A 2026-08-16 adversarial review claimed the
# composition swallows the original exit status, turning `exit 22` (ledger read-back
# mismatch) into a success. It does not -- an EXIT handler's return value does not
# change the script's exit status in bash -- but nothing in the repo proved that
# either way, so a future refactor could introduce exactly that bug unnoticed.
# A gate that reports success on a failed attestation is the worst failure this
# toolchain has, so it gets a test rather than an argument.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d -t attest-exitcode-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Lift the REAL trap functions out of the script under test. A hand-copied probe would
# stay green while the real composition rotted -- exactly the regression this file
# claims to prevent -- so the bodies come from the source, and their side effects are
# observed by shimming the commands they call rather than by rewriting them.
SUBJECT="${1:-$REPO_ROOT/.claude/scripts/kimi-attest.sh}"
[ -r "$SUBJECT" ] || { echo "cannot read $SUBJECT" >&2; exit 1; }

python3 - "$SUBJECT" > "$TMP/traps.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
out = []
for name in ("_cleanup_worktree", "_release_lock_then_cleanup"):
    m = re.search(rf"^[ \t]*{name}\(\)[ \t]*\{{", src, re.M)
    if not m:
        print(f"MISSING:{name}", file=sys.stderr); sys.exit(1)
    i, depth = m.end() - 1, 0
    while i < len(src):                      # brace-match to the closing }
        if src[i] == "{": depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0: break
        i += 1
    body = src[m.start():i + 1]
    out.append("\n".join(l[4:] if l.startswith("    ") else l for l in body.splitlines()))
print("\n".join(out))
PY

if [ ! -s "$TMP/traps.sh" ]; then
    echo "FAIL: could not lift the trap functions from $SUBJECT." >&2
    echo "  They were renamed or restructured. Update this test deliberately -- do not" >&2
    echo "  delete it: it is the only cover proving a failed attestation cannot exit 0." >&2
    exit 1
fi

make_script() {
    {
    cat <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
# The lifted bodies reference the script's own variables; give them harmless values so
# `set -u` does not fire. If a future refactor makes them reference something new, this
# probe fails loudly rather than silently testing a different code path.
TMP_OUT=/dev/null
TMP_DIFF=/dev/null
WORKTREE=/nonexistent-worktree
PLUGIN_DATA_DIR=/nonexistent-plugin-data
# Shims: the real bodies call these; recording them proves both actions still run.
git() { [ "${1:-}" = "worktree" ] && echo "worktree-cleaned" >> "$MARKER"; return 0; }
ledger_lock_release() { echo "lock-released" >> "$MARKER"; return 0; }
chmod() { return 0; }
rm() { return 0; }
find() { return 0; }
PROBE
    cat "$TMP/traps.sh"
    cat <<'PROBE'
trap '_cleanup_worktree' EXIT
trap '_cleanup_worktree SIGNAL-INT' INT
if [ "${LAYER:-composed}" = "composed" ]; then
    # Mirrors the real script: this pair is installed only after the ledger lock is held.
    trap '_release_lock_then_cleanup' EXIT
    trap '_release_lock_then_cleanup SIGNAL-INT' INT
fi
exit "$WANT"
PROBE
    } > "$TMP/probe.sh"
    command chmod +x "$TMP/probe.sh"
}

make_script

# The two trap layers are NOT both installed for every exit. In the real script the
# lock-release trap is composed on top only after ledger_lock_acquire succeeds, so
# exit 7 (verdict not approve), 13 (base/head drift) and 21 (lock acquisition failed)
# unwind through the single cleanup trap, while 0 and 22 (ledger read-back mismatch)
# unwind through the composed pair. Testing everything against the composed shape
# would claim coverage the mirror does not have, so each code is exercised against
# the layering it actually meets.
#   single = only _cleanup_worktree installed
#   composed = _release_lock_then_cleanup layered over it
for pair in "0:composed" "7:single" "13:single" "21:single" "22:composed"; do
    code="${pair%%:*}"; layer="${pair##*:}"
    : > "$TMP/marker"
    MARKER="$TMP/marker" WANT="$code" LAYER="$layer" bash "$TMP/probe.sh"
    got=$?
    if [ "$got" = "$code" ]; then
        ok "exit $code survives the $layer trap path"
    else
        bad "exit $code was rewritten to $got on the $layer path -- a failed attestation would report success"
    fi
done

# Composed path: both cleanup actions must run; composing must not drop either one.
: > "$TMP/marker"
MARKER="$TMP/marker" WANT=22 LAYER=composed bash "$TMP/probe.sh" || true
if grep -q lock-released "$TMP/marker"; then ok "composed path releases the lock"
else bad "lock was NOT released -- later runs would block on a stale lock"; fi
if grep -q worktree-cleaned "$TMP/marker"; then ok "composed path cleans the worktree"
else bad "worktree was NOT cleaned -- the leak this composition fixes is back"; fi

# Single path: the worktree must still be cleaned when the run never held the lock.
: > "$TMP/marker"
MARKER="$TMP/marker" WANT=7 LAYER=single bash "$TMP/probe.sh" || true
if grep -q worktree-cleaned "$TMP/marker"; then ok "single path cleans the worktree (exit 7)"
else bad "worktree leaked on the non-approve path -- the most common outcome of all"; fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "$PASS/$PASS cases passed"
else
    echo "$FAIL of $((PASS+FAIL)) cases FAILED"
    exit 1
fi
