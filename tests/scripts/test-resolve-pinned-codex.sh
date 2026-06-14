#!/usr/bin/env bash
# Host-isolated tests for resolve-pinned-codex.sh (no real network/clone).
set -uo pipefail
RESOLVER=".claude/scripts/resolve-pinned-codex.sh"
fail() { echo "FAIL: $1"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixture plugin tree (the "cloned" content) ---
TREE="$TMP/tree"; mkdir -p "$TREE/scripts"
printf '// fake codex companion\n' > "$TREE/scripts/codex-companion.mjs"
HASH="$(shasum -a 256 "$TREE/scripts/codex-companion.mjs" | awk '{print $1}')"
COMMIT="1111111111111111111111111111111111111111"

# --- fixture pin (matches the fixture tree) ---
PIN="$TMP/pin.json"
cat > "$PIN" <<EOF
{"codex_plugin_cc":{"tag":"vtest","commit_sha":"$COMMIT","repo":"file:///unused",
"file_tree":{"scripts/codex-companion.mjs":"sha256:$HASH"}}}
EOF

# --- stub git (env-driven): clone copies TREE; rev-parse echoes commit ---
STUBGIT="$TMP/stubgit"
cat > "$STUBGIT" <<'EOS'
#!/usr/bin/env bash
set -e
case "$1" in
  clone)
    [ "${STUB_GIT_MODE:-ok}" = "clonefail" ] && { echo "stub clone fail" >&2; exit 1; }
    dest="${@: -1}"; mkdir -p "$dest/plugins/codex"
    cp -R "$STUB_GIT_TREE/." "$dest/plugins/codex/"
    printf '%s' "$STUB_GIT_COMMIT" > "$dest/.stub_head" ;;
  -C)
    [ "${STUB_GIT_MODE:-ok}" = "commitmismatch" ] && { echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; exit 0; }
    cat "$2/.stub_head" ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$STUBGIT"

run() { CODEX_PIN_FILE="$PIN" CODEX_PINNED_CACHE="$1" CODEX_PINNED_GIT="$STUBGIT" \
        STUB_GIT_TREE="$TREE" STUB_GIT_COMMIT="$COMMIT" STUB_GIT_MODE="${2:-ok}" \
        bash "$RESOLVER"; }

# Case 1: clone-ok → prints path, exit 0
C1="$TMP/c1"
out="$(run "$C1" ok)" || fail "clone-ok should exit 0"
[ "$out" = "$C1/$COMMIT/src/plugins/codex/scripts/codex-companion.mjs" ] || fail "clone-ok path wrong: $out"

# Case 2: cache-hit → does NOT clone (stub set to clonefail, but cache pre-seeded) → still ok
out="$(run "$C1" clonefail)" || fail "cache-hit should skip clone and exit 0"
[ "$out" = "$C1/$COMMIT/src/plugins/codex/scripts/codex-companion.mjs" ] || fail "cache-hit path wrong"

# Case 3: clone-fail (offline) → exit 1
if run "$TMP/c3" clonefail >/dev/null 2>&1; then fail "clone-fail should exit nonzero"; fi

# Case 4: commit-mismatch → exit 1
if run "$TMP/c4" commitmismatch >/dev/null 2>&1; then fail "commit-mismatch should exit nonzero"; fi

# Case 5: verify-fail (tamper pin hash) → exit 1
BADPIN="$TMP/badpin.json"
cat > "$BADPIN" <<EOF
{"codex_plugin_cc":{"tag":"vtest","commit_sha":"$COMMIT","repo":"file:///unused",
"file_tree":{"scripts/codex-companion.mjs":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}}}
EOF
if CODEX_PIN_FILE="$BADPIN" CODEX_PINNED_CACHE="$TMP/c5" CODEX_PINNED_GIT="$STUBGIT" \
   STUB_GIT_TREE="$TREE" STUB_GIT_COMMIT="$COMMIT" STUB_GIT_MODE=ok bash "$RESOLVER" >/dev/null 2>&1; then
  fail "verify-fail should exit nonzero"
fi

# Case 6: missing pin field (no commit_sha) → exit 2
NOPIN="$TMP/nopin.json"
printf '%s' '{"codex_plugin_cc":{"tag":"vtest","repo":"file:///x","file_tree":{}}}' > "$NOPIN"
CODEX_PIN_FILE="$NOPIN" CODEX_PINNED_CACHE="$TMP/c6" CODEX_PINNED_GIT="$STUBGIT" bash "$RESOLVER" >/dev/null 2>&1
rc=$?
[ "$rc" = "2" ] || fail "missing pin field should exit 2 (got $rc)"

echo "PASS"
