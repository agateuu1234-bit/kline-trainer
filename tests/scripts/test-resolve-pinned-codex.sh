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

# CODEX_ATTEST_TEST_MODE=1 is REQUIRED for the override seams (PIN/CACHE/GIT) to be honored
# (codex R2 §high trust boundary). Without it the resolver ignores all overrides.
run() { CODEX_ATTEST_TEST_MODE=1 CODEX_PIN_FILE="$PIN" CODEX_PINNED_CACHE="$1" CODEX_PINNED_GIT="$STUBGIT" \
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
if CODEX_ATTEST_TEST_MODE=1 CODEX_PIN_FILE="$BADPIN" CODEX_PINNED_CACHE="$TMP/c5" CODEX_PINNED_GIT="$STUBGIT" \
   STUB_GIT_TREE="$TREE" STUB_GIT_COMMIT="$COMMIT" STUB_GIT_MODE=ok bash "$RESOLVER" >/dev/null 2>&1; then
  fail "verify-fail should exit nonzero"
fi

# Case 6: missing pin field (no commit_sha) → exit 2
NOPIN="$TMP/nopin.json"
printf '%s' '{"codex_plugin_cc":{"tag":"vtest","repo":"file:///x","file_tree":{}}}' > "$NOPIN"
CODEX_ATTEST_TEST_MODE=1 CODEX_PIN_FILE="$NOPIN" CODEX_PINNED_CACHE="$TMP/c6" CODEX_PINNED_GIT="$STUBGIT" bash "$RESOLVER" >/dev/null 2>&1
rc=$?
[ "$rc" = "2" ] || fail "missing pin field should exit 2 (got $rc)"

# Case 7: hostile overrides IGNORED without CODEX_ATTEST_TEST_MODE (codex R2 §high trust boundary).
# A malicious inherited env supplies an evil pin + a pre-seeded evil cache whose file_tree matches
# the evil companion. If the resolver honored these in production it would verify+emit the evil path
# (→ forged approve). Production must ignore them (use the real pinned pin/cache), so the output must
# NOT be the evil companion.
EVILC="dead0000dead0000dead0000dead0000dead0000"
EVIL="$TMP/evil-cache"
evil_companion="$EVIL/$EVILC/src/plugins/codex/scripts/codex-companion.mjs"
mkdir -p "$(dirname "$evil_companion")"; printf 'evil-companion' > "$evil_companion"
evil_hash="$(shasum -a 256 "$evil_companion" | awk '{print $1}')"
EVILPIN="$TMP/evil-pin.json"
printf '%s' "{\"codex_plugin_cc\":{\"tag\":\"v\",\"commit_sha\":\"$EVILC\",\"repo\":\"file:///x\",\"file_tree\":{\"scripts/codex-companion.mjs\":\"sha256:$evil_hash\"}}}" > "$EVILPIN"
out7="$(CODEX_PIN_FILE="$EVILPIN" CODEX_PINNED_CACHE="$EVIL" CODEX_PINNED_GIT="$STUBGIT" bash "$RESOLVER" 2>/dev/null || true)"
[ "$out7" != "$evil_companion" ] || fail "hostile overrides honored without CODEX_ATTEST_TEST_MODE (R2 HIGH)"

# Case 8: concurrent cold-start → exactly one published src, no nested \$SRC/src, no leaked stage/lock
# (codex R2 §medium: mv into an existing dir would nest; lock-serialized publish must prevent it).
C8="$TMP/c8"
run "$C8" ok >/dev/null 2>&1 & p1=$!
run "$C8" ok >/dev/null 2>&1 & p2=$!
wait "$p1" 2>/dev/null || true; wait "$p2" 2>/dev/null || true
[ -f "$C8/$COMMIT/src/plugins/codex/scripts/codex-companion.mjs" ] || fail "concurrent: companion missing after publish"
[ ! -e "$C8/$COMMIT/src/src" ] || fail "concurrent: nested src/src created (mv-nest bug)"
if ls -d "$C8/.staging."* >/dev/null 2>&1; then fail "concurrent: staging dir leaked"; fi
[ ! -e "$C8/$COMMIT/.publish.lock" ] || fail "concurrent: lock dir leaked"

echo "PASS"
