#!/usr/bin/env bash
# 验证 DefaultFileSystemCacheManager 不裸抛非 AppError 错误（M0.4 trust-boundary gate）
# R1 强化 (codex M-4)：增 2 条规则
#   规则 1（PR4a 套路）：所有 throw 必须 throw AppError.* 或 throw CacheErrorMapping.translate(...)
#   规则 2：public 方法体内禁止 raw `try FileManager.` / `try DatabaseQueue` —— 必须走 helper
#   规则 3：所有含 raw try FileManager / try DatabaseQueue 的 private helper 内必须有 do/catch + CacheErrorMapping.translate
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/ios/Contracts/Sources/KlineTrainerPersistence/DefaultFileSystemCacheManager.swift"
if [[ ! -f "$F" ]]; then
  echo "FAIL: $F 不存在"
  exit 1
fi

FAIL=0

# === 规则 1：throw 走 AppError 边界 ===
# 剔除注释行；抓所有 throw 行；排除 throw AppError / throw CacheErrorMapping.translate
BAD_THROW=$(grep -vE '^\s*//' "$F" | grep -nE '^\s*throw\s+' \
  | grep -vE 'throw\s+AppError\.' \
  | grep -vE 'throw\s+CacheErrorMapping\.translate' \
  | grep -vE 'throw\s+error\b' \
  || true)
if [[ -n "$BAD_THROW" ]]; then
  echo "FAIL[规则1]: 含未走 AppError 边界的 throw："
  echo "$BAD_THROW"
  FAIL=1
fi

# === 规则 2：public 方法体内禁 raw try FileManager / try DatabaseQueue ===
# 用 awk 跟踪 public func 块的开闭：检测到 `public func` 进入 public 区，遇到顶层 `}` 退出
# 简化：CacheManager protocol surface 的 5 个 public 方法是 store/touch/delete/listAvailable/pickRandom + init
# 若这 5 个方法体内出现 `try FileManager` / `try DatabaseQueue` / `try q.read` 即 fail
PUBLIC_BAD=$(awk '
  /^    public (func|init)/ { in_pub = 1; depth = 0; method = $0; next }
  in_pub == 1 && /\{/ { depth += gsub(/\{/, "{") }
  in_pub == 1 && /\}/ { depth -= gsub(/\}/, "}"); if (depth <= 0) { in_pub = 0; depth = 0 } }
  in_pub == 1 && /try FileManager\.|try DatabaseQueue|try q\.read|try [a-z][a-zA-Z0-9_]*\.read[ {]/ {
    print FILENAME ":" NR ": " $0 " (in public method: " method ")"
  }
' "$F")
if [[ -n "$PUBLIC_BAD" ]]; then
  echo "FAIL[规则2]: public 方法体内含 raw try FileManager / try DatabaseQueue（应走 private helper）："
  echo "$PUBLIC_BAD"
  FAIL=1
fi

# === 规则 3：含 raw try FileManager / try DatabaseQueue 的行附近必有 CacheErrorMapping.translate ===
# 简化检查：每行 raw try 后 ±10 行内必出现 "CacheErrorMapping.translate" 或本行就在 catch block 里
RAW_TRY_LINES=$(grep -nE 'try FileManager\.|try DatabaseQueue|try q\.read' "$F" | grep -vE ':\s*//' | cut -d: -f1)
for ln in $RAW_TRY_LINES; do
  start=$((ln > 10 ? ln - 10 : 1))
  end=$((ln + 10))
  block=$(sed -n "${start},${end}p" "$F")
  if ! echo "$block" | grep -qE 'CacheErrorMapping\.translate'; then
    echo "FAIL[规则3]: 行 $ln 的 raw try 附近 ±10 行无 CacheErrorMapping.translate："
    sed -n "${ln}p" "$F"
    FAIL=1
  fi
done

if [[ $FAIL -eq 0 ]]; then
  echo "OK: P5 DefaultFileSystemCacheManager 全部 throw 走 AppError 边界 + public 方法零 raw try"
fi
exit $FAIL
