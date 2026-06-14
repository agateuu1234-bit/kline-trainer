#!/usr/bin/env bash
# resolve-pinned-codex.sh
# 输出一份已校验的、钉死版本的 codex-companion.mjs 绝对路径，解耦自会自动更新的 Claude 插件缓存。
# Fail-closed：任一步失败即非零退出，绝不回落到未校验副本。stdout 仅一行（路径）；诊断走 stderr。
# 信任根锚定（codex R3 §high）：REPO_ROOT 取自 BASH_SOURCE（本脚本位置），不依赖 PATH-resolved git
#   → 防 shadow git 重定位信任根。覆盖 seam（CODEX_PIN_FILE/CACHE/GIT）仅在 CODEX_ATTEST_TEST_MODE=1 生效。
# 并发（codex R1/R2/R3 §medium）：mkdir 原子锁 + owner-token 仅删自己的锁 + rm $SRC 前 recheck COMPANION
#   + 不偷锁（崩溃 owner → waiter 超时 fail-closed + 指引清缓存，绝不冒删活树的险）。
set -euo pipefail

SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY="$SCRIPT_DIR/verify-codex-tree.mjs"

if [ "${CODEX_ATTEST_TEST_MODE:-0}" = "1" ]; then
    PIN="${CODEX_PIN_FILE:-$REPO_ROOT/codex.pin.json}"
    GIT_BIN="${CODEX_PINNED_GIT:-git}"
    CACHE_ROOT="${CODEX_PINNED_CACHE:-$HOME/.cache/kline-trainer-codex}"
else
    PIN="$REPO_ROOT/codex.pin.json"
    GIT_BIN="git"
    CACHE_ROOT="$HOME/.cache/kline-trainer-codex"
fi

err() { printf '[resolve-pinned-codex] %s\n' "$*" >&2; }

[ -r "$PIN" ]    || { err "pin not readable: $PIN"; exit 2; }
[ -r "$VERIFY" ] || { err "verifier not readable: $VERIFY"; exit 2; }

read_pin() { python3 -c "import json; print(json.load(open('$PIN'))['codex_plugin_cc']['$1'])" 2>/dev/null; }
TAG="$(read_pin tag)"           || { err "pin missing codex_plugin_cc.tag"; exit 2; }
COMMIT="$(read_pin commit_sha)" || { err "pin missing codex_plugin_cc.commit_sha"; exit 2; }
REPO_URL="$(read_pin repo)"     || { err "pin missing codex_plugin_cc.repo"; exit 2; }
[ -n "$TAG" ] && [ -n "$COMMIT" ] && [ -n "$REPO_URL" ] || { err "pin fields empty"; exit 2; }

SRC="$CACHE_ROOT/$COMMIT/src"
PLUGIN="$SRC/plugins/codex"
COMPANION="$PLUGIN/scripts/codex-companion.mjs"

if [ ! -f "$COMPANION" ]; then
    mkdir -p "$CACHE_ROOT/$COMMIT"
    lock="$CACHE_ROOT/$COMMIT/.publish.lock"
    if mkdir "$lock" 2>/dev/null; then
        printf '%s' "$$" > "$lock/owner" 2>/dev/null || true
        stage=""
        trap 'if [ "$(cat "$lock/owner" 2>/dev/null)" = "$$" ]; then rm -rf "$lock"; fi; [ -n "${stage:-}" ] && rm -rf "$stage" 2>/dev/null || true' EXIT
        if [ ! -f "$COMPANION" ]; then
            stage="$(mktemp -d "$CACHE_ROOT/.staging.XXXXXX")" || { err "mktemp failed; fail-closed"; exit 1; }
            "$GIT_BIN" clone --depth 1 --branch "$TAG" "$REPO_URL" "$stage/src" >&2 \
                || { err "git clone failed (offline?); fail-closed"; exit 1; }
            actual="$("$GIT_BIN" -C "$stage/src" rev-parse HEAD 2>/dev/null)" \
                || { err "rev-parse failed; fail-closed"; exit 1; }
            [ "$actual" = "$COMMIT" ] \
                || { err "commit mismatch: expected $COMMIT got $actual; fail-closed"; exit 1; }
            node "$VERIFY" "$PIN" "$stage/src/plugins/codex" >&2 \
                || { err "staged tree verify failed; fail-closed"; exit 1; }
            if [ ! -f "$COMPANION" ]; then
                rm -rf "$SRC" 2>/dev/null || true
                mv "$stage/src" "$SRC" || { err "publish rename failed; fail-closed"; exit 1; }
            fi
        fi
    else
        waited=0
        while [ ! -f "$COMPANION" ]; do
            sleep 0.2; waited=$((waited+1))
            [ "$waited" -ge 300 ] && { err "timed out (~60s) waiting for concurrent publish; if a publisher crashed: rm -rf \"$CACHE_ROOT/$COMMIT\"; fail-closed"; exit 1; }
        done
    fi
fi

node "$VERIFY" "$PIN" "$PLUGIN" >&2 || {
    err "published codex tree failed integrity check at $SRC."
    err "clear it and retry:  rm -rf \"$CACHE_ROOT/$COMMIT\""
    exit 1
}

printf '%s\n' "$COMPANION"
