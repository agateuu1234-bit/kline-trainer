#!/usr/bin/env bash
# Plan 3 P1 边界翻译 Gate 2（per docs/governance/m04-apperror-translation-gate.md；对齐 check_p5_apperror_gate.sh 3 规则）。
# 规则1：所有 throw 走 AppError 边界（token：AppError / *ErrorMapping.translate / CancellationError；剥行内注释封 codex R4 旁路；无 bare-variable token 封 codex R3 旁路）。
# 规则2（codex R5）：public 方法体内禁 raw 危险 try（transport/decoder/JSONDecoder/FileManager/.decode/.write）——必须走 private helper，否则 raw try 让 DecodingError/URLError 无 throw 行直接逃逸。
# 规则3：含 raw 危险 try 的行 ±10 行内必有 perform / *ErrorMapping.translate / AppError（证明翻译就近发生）。
# 已知局限（同 P2/P5 grep gate）：多行 throw / 字符串内 `//` 不处理；本仓单行 throw 风格不触发。SwiftSyntax 当前 toolchain 无（YAGNI）。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then
    TARGETS=("$@")
else
    ROOT="ios/Contracts/Sources/KlineTrainerPersistence"
    TARGETS=("$ROOT/DefaultAPIClient.swift" "$ROOT/Internal/APIErrorMapping.swift")
fi

# 危险 raw try：调用会抛非-AppError（transport/decoder/JSONDecoder/FileManager/任意 .decode/.write）。
# 注意 `try?`（带 ?）不匹配——它不抛，安全。
DANGER='try (await )?(transport|decoder|JSONDecoder|FileManager)[.(]|try [A-Za-z0-9_.]+\.(decode|write)\('
# awk -v 传入时 \( 被剥反斜杠，改用 [(] 表示字面量左括号（功能等价）。
DANGER_AWK='try (await )?(transport|decoder|JSONDecoder|FileManager)[.(]|try [A-Za-z0-9_.]+\.(decode|write)[(]'

FAIL=0
for f in "${TARGETS[@]}"; do
    if [[ ! -f "$f" ]]; then echo "MISS: $f"; FAIL=1; continue; fi

    # === 规则1：throw 走 AppError ===
    while IFS= read -r line; do
        code="${line%%//*}"   # 剥行内注释
        echo "$code" | grep -qE "(AppError|[A-Za-z]*ErrorMapping\.translate|CancellationError)" && continue
        echo "FAIL[规则1]: $f 非 AppError throw -> $line"; FAIL=1
    done < <(grep -vE "^[[:space:]]*//" "$f" | grep -nE "(^|[[:space:]])throw[[:space:]]")

    # === 规则2：public 方法体内禁 raw 危险 try ===
    PUBLIC_BAD=$(awk -v danger="$DANGER_AWK" '
        /^[[:space:]]*public (func|init)/ { in_pub=1 }
        in_pub==1 {
            n=gsub(/{/,"{"); m=gsub(/}/,"}"); depth += n - m
            l=$0; sub(/\/\/.*/,"",l)
            if (l ~ danger) print FILENAME ":" NR ": " $0
            if (depth<=0 && (n>0 || m>0)) { in_pub=0; depth=0 }
        }
    ' "$f")
    if [[ -n "$PUBLIC_BAD" ]]; then
        echo "FAIL[规则2]: $f public 方法体内 raw 危险 try（应走 private helper）："; echo "$PUBLIC_BAD"; FAIL=1
    fi

    # === 规则3：raw 危险 try 行 ±10 行内有翻译 ===
    while IFS= read -r ln; do
        ln="${ln%%:*}"
        start=$(( ln>10 ? ln-10 : 1 )); end=$(( ln+10 ))
        if ! sed -n "${start},${end}p" "$f" | grep -qE "perform|[A-Za-z]*ErrorMapping\.translate|AppError"; then
            echo "FAIL[规则3]: $f 行 $ln raw try 附近 ±10 行无 AppError 翻译"; FAIL=1
        fi
    done < <(grep -vE "^[[:space:]]*//" "$f" | grep -nE "$DANGER")
done

if [[ $FAIL -eq 0 ]]; then
    echo "OK: P1 边界全 throw 走 AppError + public 方法零 raw 危险 try"
fi
exit $FAIL
