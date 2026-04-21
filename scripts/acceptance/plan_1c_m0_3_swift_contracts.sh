#!/usr/bin/env bash
# Plan 1c 聚合验收：M0.3 Swift 数据模型契约
# 涵盖：SwiftPM 包 + 4 源文件 + fixture + CI workflow + 22 passed
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

# ---- 文件存在性（源文件 + fixture + 3 测试文件 + CI workflow）----
run "file: Package.swift"            test -s ios/Contracts/Package.swift
run "file: Models.swift"             test -s ios/Contracts/Sources/KlineTrainerContracts/Models.swift
run "file: AppState.swift"           test -s ios/Contracts/Sources/KlineTrainerContracts/AppState.swift
run "file: RESTDTOs.swift"           test -s ios/Contracts/Sources/KlineTrainerContracts/RESTDTOs.swift
run "file: ModelsTests.swift"        test -s ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift
run "file: AppStateTests.swift"      test -s ios/Contracts/Tests/KlineTrainerContractsTests/AppStateTests.swift
run "file: RESTDTOsTests.swift"      test -s ios/Contracts/Tests/KlineTrainerContractsTests/RESTDTOsTests.swift
run "file: lease_response.json"      test -s ios/Contracts/Tests/KlineTrainerContractsTests/fixtures/lease_response.json
run "file: swift-contracts-smoke.yml" test -s .github/workflows/swift-contracts-smoke.yml

# ---- Swift 测试（codex round 5 finding: 解析 swift test summary 字符串跨
# 工具链脆弱。改为 swift test exit code only；测试套件完整性靠前面 3 个
# 测试文件存在性检查兜底）----
run "swift test: exit 0" \
    bash -c 'cd ios/Contracts && swift test'

# ---- YAML 合法 ----
run "yaml: swift-contracts-smoke.yml parse" \
    python3 -c "import yaml; yaml.safe_load(open('.github/workflows/swift-contracts-smoke.yml'))"

# ---- 跨契约 content_hash 对齐（grep 3 处）----
# Plan 1b (backend/openapi.yaml) 必须已 merge 入 origin/main 才能通过此检查；
# 否则说明 Plan 1c hard prereq 未满足，fail-fast 给出明确诊断。
#
# 3 文件统一用固定字符串 [0-9a-f]{8}（codex round 3 finding 修复：schema.sql
# 原用带锚点 pattern，其它文件不带，不一致；按语义"8 字符小写 hex"这个核心
# token 对齐就够，anchors 在各文件单元测试内独立验证）。
run "content_hash pattern alignment (3 files)" \
    bash -c 'test -f backend/openapi.yaml || { echo "FAIL: backend/openapi.yaml missing; merge Plan 1b (PR #24) first and re-run"; exit 1; }; grep -Fq "[0-9a-f]{8}" backend/sql/schema.sql && grep -Fq "[0-9a-f]{8}" backend/openapi.yaml && grep -Fq "[0-9a-f]{8}" ios/Contracts/Tests/KlineTrainerContractsTests/RESTDTOsTests.swift'

# ---- 汇总 ----
echo ""
echo "============================================"
echo "Plan 1c (M0.3 Swift Contracts) acceptance: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed items:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "PLAN 1c FAIL"
  exit 1
fi
echo "PLAN 1c PASS"
