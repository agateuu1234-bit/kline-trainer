#!/usr/bin/env bash
# Plan 1 聚合验收：M0.1 DB schema（DDL 部分）
# 涵盖：PostgreSQL / 训练组 SQLite / app.sqlite 三套 DDL + §15.3 模板补齐
# CONTRACT_VERSION 矩阵 + migration rollback 规则移至 Plan 1f（独立设计）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
declare -a FAILED

run() {
  local label="$1"; shift
  echo ""
  echo "========== $label =========="
  if "$@"; then
    echo "OK: $label"
    PASS=$((PASS + 1))
  else
    echo "NG: $label"
    FAIL=$((FAIL + 1))
    FAILED+=("$label")
  fi
}

# ---- 文档存在性 ----
run "doc: adversarial-review §15.3 section" bash -c "grep -q '按阶段评审策略' docs/governance/adversarial-review-template.md"

# ---- SQL DDL 部署 ----
run "sql: PostgreSQL schema (pglast AST)" \
    bash -c "cd backend && python3 -m pytest tests/test_schema.py -q"
run "sql: training set SQLite schema"       ./backend/sql/tests/test_training_set_schema.sh
run "sql: app.sqlite schema"                ./backend/sql/tests/test_app_schema.sh

# ---- 汇总 ----
echo ""
echo "============================================"
echo "Plan 1 (M0.1 DDL) acceptance: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed items:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "PLAN 1 FAIL"
  exit 1
fi
echo "PLAN 1 PASS"
