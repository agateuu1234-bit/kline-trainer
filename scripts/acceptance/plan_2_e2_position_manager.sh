#!/usr/bin/env bash
# Plan 2 聚合验收：E2 PositionManager
# 涵盖：PositionManager.swift + PositionManagerTests.swift 存在 + swift test exit 0
#      + 公开 API 表面 grep（buy/sell/holdingCost/positionTier）
#      + 不重复 DrawdownAccumulator（保持 E2 scope 边界）
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

SRC=ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift
TEST=ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift

# ---- 文件存在性 ----
run "file: PositionManager.swift" test -s "$SRC"
run "file: PositionManagerTests.swift" test -s "$TEST"

# ---- 公开 API 表面 ----
run "grep: PositionManager struct" grep -q '^public struct PositionManager:' "$SRC"
run "grep: Codable+Equatable+Sendable conformance" grep -q 'Codable, Equatable, Sendable' "$SRC"
run "grep: shares property" grep -q 'public private(set) var shares: Int' "$SRC"
run "grep: averageCost property" grep -q 'public private(set) var averageCost: Double' "$SRC"
run "grep: totalInvested property" grep -q 'public private(set) var totalInvested: Double' "$SRC"
run "grep: buy method" grep -q 'public mutating func buy(shares: Int, totalCost: Double)' "$SRC"
run "grep: sell method" grep -q 'public mutating func sell(shares: Int)' "$SRC"
run "grep: holdingCost computed" grep -q 'public var holdingCost: Double' "$SRC"
run "grep: positionTier method-arg signature" grep -q 'public func positionTier(totalCapital: Double, currentPrice: Double) -> Int' "$SRC"

# ---- scope 边界：E2 不重复实现 DrawdownAccumulator（容许注释引用）----
run "grep: no DrawdownAccumulator type definition" bash -c "! grep -qE '^(public )?(struct|class|enum) DrawdownAccumulator' $SRC"
run "grep: no peakCapital/maxDrawdown stored property" bash -c "! grep -qE 'var (peakCapital|maxDrawdown):' $SRC"

# ---- 测试 suite 数量 ----
run "grep: 7 test suites declared" bash -c "grep -c '^@Suite' $TEST | grep -q '^7$'"

# ---- Swift 测试 exit 0 ----
run "swift test: exit 0" bash -c 'cd ios/Contracts && swift test'

# ---- 汇总 ----
echo ""
echo "============================================"
echo "Plan 2 (E2 PositionManager) acceptance: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed items:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "PLAN 2 FAIL"
  exit 1
fi
echo "PLAN 2 PASS"
