#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCHEMA="$REPO_ROOT/ios/sql/app_schema_v1.sql"
DB=$(mktemp -t app_schema.XXXXXX.db)
trap 'rm -f "$DB"' EXIT

sqlite3 "$DB" < "$SCHEMA"

# 6 张表（按字母序比对）：download_acceptance_journal / drawings / pending_training / settings / trade_operations / training_records
# 排除 SQLite 内部表（AUTOINCREMENT 会在 sqlite_master 生成 sqlite_sequence 行）
TABLES=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" | paste -sd, -)
EXPECTED="download_acceptance_journal,drawings,pending_training,settings,trade_operations,training_records"
if [[ "$TABLES" != "$EXPECTED" ]]; then
  echo "FAIL: tables mismatch"
  echo "  expected: $EXPECTED"
  echo "  got:      $TABLES"
  exit 1
fi

# training_records.final_tick 列存在（v1.2 必须）且 NOT NULL
FT=$(sqlite3 "$DB" "SELECT count(*) FROM pragma_table_info('training_records') WHERE name='final_tick' AND \"notnull\"=1;")
if [[ "$FT" != "1" ]]; then
  echo "FAIL: training_records.final_tick missing or nullable"
  exit 1
fi

# pending_training.cash_balance + drawdown 存在（v1.3 必须）且均 NOT NULL
CB=$(sqlite3 "$DB" "SELECT count(*) FROM pragma_table_info('pending_training') WHERE name IN ('cash_balance','drawdown') AND \"notnull\"=1;")
if [[ "$CB" != "2" ]]; then
  echo "FAIL: pending_training.cash_balance / drawdown missing or nullable"
  exit 1
fi

# download_acceptance_journal UNIQUE(training_set_id, lease_id)
# SQLite 为 table-level UNIQUE 创建 sqlite_autoindex_* 索引（sql IS NULL），用 pragma_index_list 查 unique=1 更稳
UQ=$(sqlite3 "$DB" "SELECT count(*) FROM pragma_index_list('download_acceptance_journal') WHERE \"unique\"=1;")
if [[ "$UQ" -lt "1" ]]; then
  echo "FAIL: journal UNIQUE(training_set_id, lease_id) missing"
  exit 1
fi

# idx_journal_state 存在
JIDX=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='idx_journal_state';")
if [[ "$JIDX" != "1" ]]; then
  echo "FAIL: idx_journal_state missing"
  exit 1
fi

echo "PASS: app_schema_v1.sql deploys with all v1.4 columns"
