#!/usr/bin/env bash
# 校验 AppDBMigrations.swift 内 inline schema 字串与 ios/sql/app_schema_v1.sql 一致。
# 失败 → CI 必须 block。
# 用法：bash scripts/check_app_schema_drift.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEMA_FILE="ios/sql/app_schema_v1.sql"
SWIFT_FILE="ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift"

# 提取 Swift 字串内容：从 `static let v1_4_baselineDDL: String = """` 后到最近 `"""`
INLINE=$(awk '
    /static let v1_4_baselineDDL: String = """/ { capture=1; next }
    capture && /^    """$/ { capture=0; next }
    capture { print }
' "$SWIFT_FILE")

# 规范化两侧去掉注释行 / 前导空白做对比
NORMALIZE() { grep -v '^[[:space:]]*--' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'; }
LEFT=$(echo "$INLINE" | NORMALIZE)
RIGHT=$(cat "$SCHEMA_FILE" | NORMALIZE)

if [ "$LEFT" != "$RIGHT" ]; then
    echo "ERROR: schema drift between AppDBMigrations.v1_4_baselineDDL and $SCHEMA_FILE"
    diff <(echo "$LEFT") <(echo "$RIGHT") || true
    exit 1
fi

echo "OK: AppDBMigrations.swift schema 与 $SCHEMA_FILE 一致"
