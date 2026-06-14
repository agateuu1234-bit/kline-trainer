#!/usr/bin/env bash
# resolve-pinned-codex.sh
# 输出一份已校验的、钉死版本的 codex-companion.mjs 绝对路径，解耦自会自动更新的
# Claude 插件缓存。读 codex.pin.json 的 codex_plugin_cc.{repo,tag,commit_sha,file_tree}，
# 按 commit 入键 clone 到本地缓存，verify-codex-tree.mjs 全树校验后打印路径。
# Fail-closed：任一步失败即非零退出，绝不回落到未校验副本。
# stdout：仅一行（路径）；所有诊断走 stderr。
# 测试 seam（默认即生产值）：CODEX_PIN_FILE / CODEX_PINNED_CACHE / CODEX_PINNED_GIT。
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PIN="${CODEX_PIN_FILE:-$REPO_ROOT/codex.pin.json}"
VERIFY="$REPO_ROOT/.claude/scripts/verify-codex-tree.mjs"
GIT_BIN="${CODEX_PINNED_GIT:-git}"

err() { printf '[resolve-pinned-codex] %s\n' "$*" >&2; }

[ -r "$PIN" ]    || { err "pin not readable: $PIN"; exit 2; }
[ -r "$VERIFY" ] || { err "verifier not readable: $VERIFY"; exit 2; }

read_pin() { python3 -c "import json; print(json.load(open('$PIN'))['codex_plugin_cc']['$1'])" 2>/dev/null; }
TAG="$(read_pin tag)"           || { err "pin missing codex_plugin_cc.tag"; exit 2; }
COMMIT="$(read_pin commit_sha)" || { err "pin missing codex_plugin_cc.commit_sha"; exit 2; }
REPO_URL="$(read_pin repo)"     || { err "pin missing codex_plugin_cc.repo"; exit 2; }
[ -n "$TAG" ] && [ -n "$COMMIT" ] && [ -n "$REPO_URL" ] || { err "pin fields empty"; exit 2; }

CACHE_ROOT="${CODEX_PINNED_CACHE:-$HOME/.cache/kline-trainer-codex}"
SRC="$CACHE_ROOT/$COMMIT/src"
PLUGIN="$SRC/plugins/codex"

clone_and_check() {
    rm -rf "$SRC"
    mkdir -p "$(dirname "$SRC")"
    "$GIT_BIN" clone --depth 1 --branch "$TAG" "$REPO_URL" "$SRC" >&2 || { err "git clone failed"; return 1; }
    local actual
    actual="$("$GIT_BIN" -C "$SRC" rev-parse HEAD 2>/dev/null)" || { err "rev-parse failed"; return 1; }
    [ "$actual" = "$COMMIT" ] || { err "commit mismatch: expected $COMMIT got $actual"; return 1; }
    return 0
}

if [ ! -f "$PLUGIN/scripts/codex-companion.mjs" ]; then
    clone_and_check || { err "acquire failed (offline / commit mismatch); fail-closed"; exit 1; }
fi

if ! node "$VERIFY" "$PIN" "$PLUGIN" >&2; then
    err "tree verify failed; re-cloning once"
    clone_and_check || { err "re-clone failed; fail-closed"; exit 1; }
    node "$VERIFY" "$PIN" "$PLUGIN" >&2 || { err "tree verify failed after re-clone; fail-closed"; exit 1; }
fi

printf '%s\n' "$PLUGIN/scripts/codex-companion.mjs"
