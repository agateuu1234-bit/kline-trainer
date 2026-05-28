#!/usr/bin/env bash
# Wave 1 顺位 14 (U5 PositionPickerView) 机检验收
# 用法：bash scripts/acceptance/plan_u5_position_picker_view.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: U5 源文件 + 测试文件 + 验收 doc 存在 =="
test -f ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
test -f ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
test -f ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift
test -f docs/acceptance/2026-05-28-pr-u5-position-picker-view.md

echo "== G2: PositionPickerContent 平台无关（仅 import Foundation；不 import SwiftUI/UIKit/CoreGraphics）=="
grep -q "^import Foundation$" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
# R4-C1：负向断言必须用 if/exit 1，不能用 `! grep`（pipeline 起头 `!` 被 set -e 豁免，永不 abort）
if grep -qE "^import (SwiftUI|UIKit|CoreGraphics)$" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift; then
  echo "G2 FAIL: Content 不应 import SwiftUI/UIKit/CoreGraphics"; exit 1
fi

echo "== G3: spec §U5 字面 init 签名（D1/D11）=="
grep -q "public struct PositionPickerView: View" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "init(enabledTiers: Set<PositionTier>," \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "onPick: @escaping (PositionTier) -> Void" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "onCancel: @escaping () -> Void" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift

echo "== G4: spec §6.2.4 字面字串：仓位选择 / 取消（D6/D7）+ 取消按钮真接 onCancel（R1-M2 + R3 修）=="
# R3 修：grep `Text("…")` body literal，避免命中 header 注释中相同字符串导致计数 ≠ 1
grep -q 'Text("仓位选择")' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q 'Text("取消")' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
# R1-M2：取消按钮 label 必须真接 onCancel callback，不只是文本字面
grep -q 'Button(action: onCancel)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift

echo "== G5: D3/D4/D5 数据映射字面落地 =="
grep -q "PositionTier.allCases.map" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
grep -q "tier.rawValue" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
grep -q "enabledTiers.contains(tier)" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift

echo "== G6: D16 不实现盈亏色 / RGB 硬编码（反向验证）=="
if grep -qE '\.foregroundStyle\(\.red|\.foregroundStyle\(\.green' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G6 FAIL: 不应实现盈亏色 .foregroundStyle(.red/.green)"; exit 1
fi
if grep -qE 'Color\(red:|UIColor\(' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G6 FAIL: 不应 RGB 硬编码 Color(red:/UIColor("; exit 1
fi

echo "== G7: D14 不引业务运行时 / Content 平台无关 =="
if grep -qE 'import (GRDB|ZIPFoundation)' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G7 FAIL: 不应 import GRDB/ZIPFoundation"; exit 1
fi
# R4-I1：业务运行时类型不得出现在 prod 源（含注释）；D14 注释已改写不含裸 type token
if grep -qE 'TradeCalculator|TickEngine|PositionManager|TrainingFlowController|APIClient' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G7 FAIL: 不应引用业务运行时类型 TradeCalculator/TickEngine/PositionManager/TrainingFlowController/APIClient"; exit 1
fi

echo "== G8: D9 v2 DEBUG-only fileprivate extension PositionTier preview fixture（R1-M4 修：机制与 U3 严格同款，反向锚真有目标）=="
grep -q '^#if DEBUG' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "fileprivate extension PositionTier" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "static func previewEnabledTiers() -> Set<PositionTier>" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
# 反向：不能是 public extension PositionTier（会污染下游 DEBUG 编译）
if grep -qE "^public.*extension PositionTier|^extension PositionTier.*public" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G8 FAIL: preview fixture extension 不能是 public（会跨模块污染 DEBUG 编译）"; exit 1
fi
# 反向：PreviewFakes 不被本 PR 动
if grep -qE "extension PositionTier|PositionTier\.preview" \
  ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift; then
  echo "G8 FAIL: 本 PR 不应改 PreviewFakes（D9 单 use site）"; exit 1
fi

echo "== G9: D15 View 不调 dismiss（caller 负责 presentation）=="
if grep -qE 'dismiss\(\)|@Environment\(.*dismiss' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G9 FAIL: View 不应调 dismiss() 或 @Environment(\\.dismiss)（caller 负责 presentation）"; exit 1
fi

echo "== G10: swift test 全量 PASS（基线 519 + 本 PR +10 = 期望 ≥529，宽松正则锚）=="
cd ios/Contracts
swift test 2>&1 | tee /tmp/u5-test-full.txt | tail -3
grep -qE "Test run with [0-9]+ tests in [0-9]+ suites passed" /tmp/u5-test-full.txt
cd -

echo "== G11: PositionPickerContentTests 单 suite 全绿（宽松正则锚）=="
cd ios/Contracts
swift test --filter PositionPickerContentTests 2>&1 | tee /tmp/u5-test-suite.txt | tail -3
grep -qE "Test run with [0-9]+ tests? in [0-9]+ suites? passed" /tmp/u5-test-suite.txt
cd -

echo "== G12: Mac Catalyst build-for-testing SUCCEEDED =="
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/u5-derived-final \
           build-for-testing 2>&1 | tail -5 | tee /tmp/u5-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/u5-build-tail.txt
cd -

echo
echo "✅ 所有 12 项 G1-G12 验收通过"
