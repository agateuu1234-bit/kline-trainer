#!/usr/bin/env bash
# Plan 1f 聚合验收：M0.1 Schema Versioning Contract
# 涵盖：m01 doc 存在 + 7 H2 + 各独立 anchor（不聚合）+ 3 owner + 交叉引用 + 不 regression Plan 1/1b/1c/1d
# 关键设计：每 anchor 独立断言（per Plan 1e R7 MEDIUM fix）
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

DOC=docs/governance/m01-schema-versioning-contract.md

# ---- 文件存在性 ----
run "file: m01 contract doc" test -s "$DOC"

# ---- H2 章节完整性（7 个 ## 顶级标题）----
run "structure: 7 H2 sections" \
    bash -c "grep -c '^## ' $DOC | grep -q '^7$'"

# ---- 5 个子版本维度独立断言 ----
run "anchor: top version literal 1.4" grep -q '"1.4"' "$DOC"
run "anchor: dim PostgreSQL"          grep -q 'PostgreSQL' "$DOC"
run "anchor: dim 训练组 SQLite"        grep -q '训练组 SQLite' "$DOC"
run "anchor: dim app.sqlite"           grep -q 'app.sqlite' "$DOC"
run "anchor: dim Swift 模型"            grep -q 'Swift 模型' "$DOC"
run "anchor: dim P2 journal states"    grep -q 'P2 journal states' "$DOC"

# ---- Bump 策略二分独立断言 ----
run "anchor: bump 破坏性"     grep -q '破坏性' "$DOC"
run "anchor: bump 本地兼容"    grep -q '本地兼容' "$DOC"
run "anchor: 未知 state 处理"  grep -q '未知 state' "$DOC"
run "anchor: fail-safe 忽略策略" grep -q 'fail-safe' "$DOC"

# ---- Migration Rollback 独立断言 ----
run "anchor: forward.sql"  grep -q 'forward.sql'  "$DOC"
run "anchor: rollback.sql" grep -q 'rollback.sql' "$DOC"
run "anchor: versionMismatch error" grep -q 'AppError.trainingSet(.versionMismatch)' "$DOC"

# ---- 3 个 owner 独立点名 ----
run "owner: B3 PostgreSQL"     grep -q 'B3' "$DOC"
run "owner: P4 app.sqlite"     grep -q 'P4' "$DOC"
run "owner: P3a 训练组 Factory" grep -q 'P3a' "$DOC"

# ---- 交叉引用 ----
run "cross-ref: spec L133-157" \
    bash -c "grep -q 'kline_trainer_modules_v1.4.md' $DOC && grep -q 'L133' $DOC"
run "cross-ref: m04 gate doc" grep -q 'm04-apperror-translation-gate' "$DOC"

# ---- m04 gate stub 仍存在（不 regression Plan 1d hotfix）----
run "regression: m04 gate stub still present" \
    test -s docs/governance/m04-apperror-translation-gate.md
run "regression: m04 stub TODOs still open (Plan 3 P1 owns closure)" \
    grep -q 'TODO Plan 3 P1' docs/governance/m04-apperror-translation-gate.md

# ---- 不 regression Plan 1/1b/1c/1d acceptance ----
run "regression: Plan 1 (M0.1 DDL) acceptance" \
    bash -c "test -x scripts/acceptance/plan_1_m0_1_db_schema.sh && ./scripts/acceptance/plan_1_m0_1_db_schema.sh > /tmp/p1.log 2>&1"
run "regression: Plan 1b (M0.2 OpenAPI) acceptance" \
    bash -c "test -x scripts/acceptance/plan_1b_m0_2_rest_api.sh && ./scripts/acceptance/plan_1b_m0_2_rest_api.sh > /tmp/p1b.log 2>&1"
run "regression: Plan 1c (M0.3 Swift Models) acceptance" \
    bash -c "test -x scripts/acceptance/plan_1c_m0_3_swift_contracts.sh && ./scripts/acceptance/plan_1c_m0_3_swift_contracts.sh > /tmp/p1c.log 2>&1"
run "regression: Plan 1d (M0.4 AppError) acceptance" \
    bash -c "test -x scripts/acceptance/plan_1d_m0_4_apperror.sh && ./scripts/acceptance/plan_1d_m0_4_apperror.sh > /tmp/p1d.log 2>&1"

# ---- 汇总 ----
echo ""
echo "============================================"
echo "Plan 1f (M0.1 schema versioning) acceptance: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed items:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "失败日志位置（regression 段）：/tmp/p1.log, /tmp/p1b.log, /tmp/p1c.log, /tmp/p1d.log"
  echo "PLAN 1f FAIL"
  exit 1
fi
echo "PLAN 1f PASS"
