#!/usr/bin/env bash
# Wave 1 顺位 13 (U3 SettlementView) 机检验收
# 用法：bash scripts/acceptance/plan_u3_settlement_view.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: U3 源文件 + 测试文件 + 验收 doc 存在 =="
test -f ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
test -f ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
test -f ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettlementContentTests.swift
test -f docs/acceptance/2026-05-27-pr-u3-settlement-view.md

echo "== G2: SettlementContent 平台无关（仅 import Foundation；不 import SwiftUI/UIKit/CoreGraphics）=="
grep -q "^import Foundation$" ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
! grep -qE "^import (SwiftUI|UIKit|CoreGraphics)$" ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift

echo "== G3: spec §U3 字面 init 签名（D1/D11）=="
grep -q "public struct SettlementView: View" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
grep -q "init(record: TrainingRecord, onConfirm: @escaping () -> Void)" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G4: spec §6.3 字面字串：本局结算 / 确认 =="
grep -q "本局结算" ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
grep -q '"确认"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G5: D3/D4/D5/D7 格式化字面落地 + signed-zero 归一化代码（R1-C1）=="
grep -q '"¥ ' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q "en_US_POSIX" ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q '"%02d"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q '"%+.2f"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q 'raw == 0' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q '（' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift

echo "== G6: D2 不实现盈亏色（反向验证）=="
! grep -qE '\.foregroundStyle\(\.red|\.foregroundStyle\(\.green' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
! grep -qE 'Color\(red:|UIColor\(' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G7: F2/F3 不引业务运行时 / Content 平台无关 =="
! grep -qE 'import (GRDB|ZIPFoundation)' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
! grep -qE 'TradeCalculator|TickEngine|PositionManager|TrainingFlowController|APIClient' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G8: D9 + R1-H4 DEBUG-only fileprivate preview fixture（防跨模块污染）=="
grep -q '^#if DEBUG' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
grep -q "fileprivate extension TrainingRecord" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
grep -q "static func preview() -> TrainingRecord" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
# 反向：不能是 public extension（会污染下游 DEBUG 编译）
! grep -qE "^public.*extension TrainingRecord|^extension TrainingRecord.*public" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
# 反向：PreviewFakes 不被本 PR 动
! grep -qE "extension TrainingRecord|TrainingRecord\.preview" \
  ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift

echo "== G9: D11 onConfirm 不分 mode 分支 =="
! grep -qE 'TrainingFlowController|\.normal|\.review|\.replay' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G10: swift test 全量 PASS（基线 502 + 本 PR +16 = 期望 ≥518，宽松正则锚 per R1-H1；strong gate 由 set -euo pipefail 提供，无需重跑）=="
cd ios/Contracts
swift test 2>&1 | tee /tmp/u3-test-full.txt | tail -3
grep -qE "Test run with [0-9]+ tests in [0-9]+ suites passed" /tmp/u3-test-full.txt
cd -

echo "== G11: SettlementContentTests 单 suite 全绿（宽松正则锚 + set -euo pipefail strong gate）=="
cd ios/Contracts
swift test --filter SettlementContentTests 2>&1 | tee /tmp/u3-test-suite.txt | tail -3
grep -qE "Test run with [0-9]+ tests? in [0-9]+ suites? passed" /tmp/u3-test-suite.txt
cd -

echo "== G12: Mac Catalyst build-for-testing SUCCEEDED =="
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/u3-derived-final \
           build-for-testing 2>&1 | tail -5 | tee /tmp/u3-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/u3-build-tail.txt
cd -

echo
echo "✅ 所有 12 项 G1-G12 验收通过"
