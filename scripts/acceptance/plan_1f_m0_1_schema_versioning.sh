#!/usr/bin/env bash
# Plan 1f 聚合验收：M0.1 Schema Versioning Contract
# R6 设计（Plan 1e R7 MEDIUM + Plan 1f R3/R4/R5 教训）：
# - 不用 substring 全文 grep（易被删行骗过）：改 awk 按 H2 章节切片 + 行级 regex 要 dim/version/rule/owner 共现
# - 不 nested plan_1d_m0_4_apperror.sh（其内部 TODO 断言是 Plan 3 P1 闭合的 transient state）：改为内联 Plan 1d 稳定断言
# - m04 regression：只断言 file 存在 + cross-ref "Plan 3 P1"（兼容闭合前 TODO + 闭合后 completed 两态）
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
APPERROR=ios/Contracts/Sources/KlineTrainerContracts/AppError.swift

# ---- 文件存在性 ----
run "file: m01 contract doc" test -s "$DOC"

# ---- H2 章节完整性（7 个 ## 顶级标题）----
run "structure: 7 H2 sections" bash -c "grep -c '^## ' $DOC | grep -q '^7$'"

# ---- CONTRACT_VERSION 矩阵 6 行协同断言（cell-boundary exact；per codex R6）----
# 每断言要求: dim 在前 | 精确 version 字面值 含 cell boundary （空格+backtick可选+值+backtick可选+空格+\|）
# 防御模式：值后面必须紧跟 \| 或 backtick+空格+\|，禁止 version="1" 匹配 cell="10"
run "matrix row: CONTRACT_VERSION top | \`\"1.4\"\`" \
    grep -qE '^\|.*CONTRACT_VERSION.*\| *`?"1\.4"`? *\|' \
    <(awk '/^## CONTRACT_VERSION 矩阵$/,/^## Bump 策略/' "$DOC")
run "matrix row: PostgreSQL | \`0003_v1.3\`" \
    grep -qE '^\|.*PostgreSQL.*\| *`?0003_v1\.3`? *\|' \
    <(awk '/^## CONTRACT_VERSION 矩阵$/,/^## Bump 策略/' "$DOC")
run "matrix row: 训练组 SQLite PRAGMA user_version | \`1\`" \
    grep -qE '^\|.*训练组 SQLite.*PRAGMA.*user_version.*\| *`?1`? *\|' \
    <(awk '/^## CONTRACT_VERSION 矩阵$/,/^## Bump 策略/' "$DOC")
run "matrix row: app.sqlite | \`0003_v1.4_purge_leased\`" \
    grep -qE '^\|.*app\.sqlite.*\| *`?0003_v1\.4_purge_leased`? *\|' \
    <(awk '/^## CONTRACT_VERSION 矩阵$/,/^## Bump 策略/' "$DOC")
run "matrix row: Swift 模型 | \`1.3\`" \
    grep -qE '^\|.*Swift 模型.*\| *`?1\.3`? *\|' \
    <(awk '/^## CONTRACT_VERSION 矩阵$/,/^## Bump 策略/' "$DOC")
run "matrix row: P2 journal states | \`v2\`" \
    grep -qE '^\|.*P2 journal states.*\| *`?v2`? *\|' \
    <(awk '/^## CONTRACT_VERSION 矩阵$/,/^## Bump 策略/' "$DOC")

# ---- Bump 策略 A/B 二分 + DAO reader 未知 state 规则（section-bounded）----
run "bump A: 必须 bump 顶层 CONTRACT_VERSION (破坏性)" \
    grep -qE '必须 bump 顶层.*CONTRACT_VERSION.*破坏性' \
    <(awk '/^## Bump 策略/,/^## Migration Rollback/' "$DOC")
run "bump B: 只 bump 子版本 (本地兼容)" \
    grep -qE '只 bump 子版本.*本地兼容' \
    <(awk '/^## Bump 策略/,/^## Migration Rollback/' "$DOC")
run "bump DAO: §'未知 state'处理 heading" \
    grep -q '未知 state' \
    <(awk '/^## Bump 策略/,/^## Migration Rollback/' "$DOC")
run "bump DAO: fail-safe 忽略策略 body" \
    grep -q 'fail-safe' \
    <(awk '/^## Bump 策略/,/^## Migration Rollback/' "$DOC")
run "bump DAO: 不进入任何恢复扫描集" \
    grep -q '不进入任何恢复扫描集' \
    <(awk '/^## Bump 策略/,/^## Migration Rollback/' "$DOC")

# ---- Migration Rollback 3 行协同断言（storage + rule + owner 必须同行共现，section-bounded）----
run "rollback row: PostgreSQL | forward.sql + rollback.sql | B3" \
    grep -qE '^\|.*PostgreSQL.*forward\.sql.*rollback\.sql.*\|.*B3' \
    <(awk '/^## Migration Rollback/,/^## 应用范围/' "$DOC")
run "rollback row: app.sqlite | DatabaseMigrator | P4" \
    grep -qE '^\|.*app\.sqlite.*DatabaseMigrator.*\|.*P4' \
    <(awk '/^## Migration Rollback/,/^## 应用范围/' "$DOC")
run "rollback row: 训练组 SQLite | versionMismatch | P3a" \
    grep -qE '^\|.*训练组 SQLite.*versionMismatch.*\|.*P3a' \
    <(awk '/^## Migration Rollback/,/^## 应用范围/' "$DOC")

# ---- 应用范围 section: 3 个强制 owner 必须标 ✅/强制（section-bounded）----
run "scope: B3 强制引用" \
    grep -qE 'B3.*(✅|强制)' \
    <(awk '/^## 应用范围/,/^## 未来强制点/' "$DOC")
run "scope: P4 强制引用" \
    grep -qE 'P4.*(✅|强制)' \
    <(awk '/^## 应用范围/,/^## 未来强制点/' "$DOC")
run "scope: P3a 强制引用" \
    grep -qE 'P3a.*(✅|强制)' \
    <(awk '/^## 应用范围/,/^## 未来强制点/' "$DOC")

# ---- 交叉引用 section（section-bounded，避免 callout 里的误命中）----
run "cross-ref §交叉引用: spec L125-293 范围" \
    grep -qE 'kline_trainer_modules_v1\.4\.md.*L125' \
    <(awk '/^## 交叉引用/{f=1} f' "$DOC")
run "cross-ref §交叉引用: m04 gate" \
    grep -q 'm04-apperror-translation-gate' \
    <(awk '/^## 交叉引用/{f=1} f' "$DOC")

# ---- m04 gate stub regression（不 regression Plan 1d hotfix）----
# 注意：只断言 m04 doc 存在 + 仍 cross-ref Plan 3 P1；不断言 TODO 仍开
# （Plan 3 P1 闭合时会删除 TODO 标记，本 plan 不该阻断 Plan 3 P1）
run "regression: m04 gate stub still present" \
    test -s docs/governance/m04-apperror-translation-gate.md
run "regression: m04 still cross-refs Plan 3 P1 (闭合前 TODO 或闭合后 completed 都匹配)" \
    grep -q 'Plan 3 P1' docs/governance/m04-apperror-translation-gate.md

# ---- 不 regression Plan 1/1b/1c acceptance ----
# 不直接 nested plan_1d_m0_4_apperror.sh——其 TODO 断言 transient；改为下方 Plan 1d 稳定断言内联
run "regression: Plan 1 (M0.1 DDL) acceptance" \
    bash -c "test -x scripts/acceptance/plan_1_m0_1_db_schema.sh && ./scripts/acceptance/plan_1_m0_1_db_schema.sh > /tmp/p1.log 2>&1"
run "regression: Plan 1b (M0.2 OpenAPI) acceptance" \
    bash -c "test -x scripts/acceptance/plan_1b_m0_2_rest_api.sh && ./scripts/acceptance/plan_1b_m0_2_rest_api.sh > /tmp/p1b.log 2>&1"
run "regression: Plan 1c (M0.3 Swift Models) acceptance (间接覆盖 Plan 1d AppError swift test)" \
    bash -c "test -x scripts/acceptance/plan_1c_m0_3_swift_contracts.sh && ./scripts/acceptance/plan_1c_m0_3_swift_contracts.sh > /tmp/p1c.log 2>&1"

# ---- Plan 1d 稳定断言内联（AppError 结构不变量；排除 TODO transient state）----
run "plan-1d stable: AppError.swift file" test -s "$APPERROR"
run "plan-1d stable: AppErrorTests.swift file" test -s ios/Contracts/Tests/KlineTrainerContractsTests/AppErrorTests.swift
run "plan-1d stable: public enum AppError 定义" \
    grep -qE '^public enum AppError:' "$APPERROR"
run "plan-1d stable: 4 Reason enums (Network/Persistence/Trade/TrainingSet)" \
    bash -c "grep -cE '^public enum (Network|Persistence|Trade|TrainingSet)Reason:' $APPERROR | grep -q '^4$'"
run "plan-1d stable: 3 extension methods (userMessage/isRecoverable/shouldShowToast)" \
    bash -c "grep -cE '(userMessage|isRecoverable|shouldShowToast):' $APPERROR | grep -q '^3$'"

# ---- 汇总 ----
echo ""
echo "============================================"
echo "Plan 1f (M0.1 schema versioning) acceptance: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed items:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "失败日志位置（regression 段）：/tmp/p1.log, /tmp/p1b.log, /tmp/p1c.log"
  echo "PLAN 1f FAIL"
  exit 1
fi
echo "PLAN 1f PASS"
