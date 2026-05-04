#!/usr/bin/env bash
# PR4a P2 边界翻译 gate（per docs/governance/m04-apperror-translation-gate.md）
# 校验 KlineTrainerPersistence 的 4 个 P2 Default*.swift 不裸 throw ZipFoundation / Foundation 错误。
# 仅校验本 PR 新增的 4 个文件，避免污染其它 module 实现。
set -euo pipefail

cd "$(dirname "$0")/.."

ROOT="ios/Contracts/Sources/KlineTrainerPersistence"
TARGETS=(
    "$ROOT/DefaultZipIntegrityVerifier.swift"
    "$ROOT/DefaultZipExtractor.swift"
    "$ROOT/DefaultTrainingSetDataVerifier.swift"
    "$ROOT/DefaultDownloadAcceptanceCleaner.swift"
)

FAIL=0

for f in "${TARGETS[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "MISS: $f"
        FAIL=1
        continue
    fi
    # 不允许裸 throw ZipFoundation / NSError / DecodingError 类型
    # 允许：throw AppError... / throw ZipErrorMapping.translate... / throw 已捕获的 AppError
    # 先剔除注释行（// ...）再 grep，避免注释说明文字触发误报
    if grep -vE "^\s*//" "$f" | grep -nE "throw\s+(NSError|Archive\.ArchiveError|DecodingError)"; then
        echo "FAIL: $f 有裸 throw（应走 AppError / ZipErrorMapping.translate）"
        FAIL=1
    fi
done

if [[ $FAIL -eq 0 ]]; then
    echo "OK: P2 4 Default*.swift 全部走 AppError 边界"
fi
exit $FAIL
