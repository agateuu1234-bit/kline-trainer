#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCHEMA="$REPO_ROOT/backend/sql/training_set_schema_v1.sql"
DB=$(mktemp -t training_set_schema.XXXXXX.db)
trap 'rm -f "$DB"' EXIT

sqlite3 "$DB" < "$SCHEMA"

# PRAGMA user_version 必须 = 1
UV=$(sqlite3 "$DB" "PRAGMA user_version;")
if [[ "$UV" != "1" ]]; then
  echo "FAIL: expected user_version=1, got $UV"
  exit 1
fi

# meta + klines 两表存在（排除 SQLite 内部表 sqlite_sequence，AUTOINCREMENT 会创建它）
TABLES=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" | paste -sd, -)
if [[ "$TABLES" != "klines,meta" ]]; then
  echo "FAIL: expected tables klines,meta; got '$TABLES'"
  exit 1
fi

# 2 个 idx_* 索引（sqlite_autoindex_* 已被 LIKE 'idx_%' 自动排除）
IDX=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';")
if [[ "$IDX" != "2" ]]; then
  echo "FAIL: expected 2 idx_* indexes, got $IDX"
  exit 1
fi

# end_global_index NOT NULL
ENDIDX_NOTNULL=$(sqlite3 "$DB" "SELECT \"notnull\" FROM pragma_table_info('klines') WHERE name='end_global_index';")
if [[ "$ENDIDX_NOTNULL" != "1" ]]; then
  echo "FAIL: klines.end_global_index expected NOT NULL; got notnull=$ENDIDX_NOTNULL"
  exit 1
fi

echo "PASS: training_set_schema_v1.sql deploys with user_version=1"
