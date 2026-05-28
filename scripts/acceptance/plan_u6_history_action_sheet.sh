#!/usr/bin/env bash
# Wave 1 顺位 15 (U6 HistoryActionSheet) 机检验收
# 用法：bash scripts/acceptance/plan_u6_history_action_sheet.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

CONTENT=ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift
SHEET=ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift

echo "== G1: U6 源文件 + 测试文件 + 验收 doc 存在 =="
test -f "$CONTENT"
test -f "$SHEET"
test -f ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionContentTests.swift
test -f docs/acceptance/2026-05-29-pr-u6-history-action-sheet.md

echo "== G2: HistoryActionContent 平台无关（仅 import Foundation；不 import SwiftUI/UIKit/CoreGraphics）=="
grep -q "^import Foundation$" "$CONTENT"
if grep -qE "^import (SwiftUI|UIKit|CoreGraphics)$" "$CONTENT"; then
  echo "G2 FAIL: Content 不应 import SwiftUI/UIKit/CoreGraphics"; exit 1
fi

echo "== G3: spec §U6 字面 init 签名（D1/D9）=="
grep -q "public struct HistoryActionSheet: View" "$SHEET"
grep -q "init(record: TrainingRecord," "$SHEET"
grep -q "onReview: @escaping () -> Void" "$SHEET"
grep -q "onReplay: @escaping () -> Void" "$SHEET"
grep -q "onCancel: @escaping () -> Void" "$SHEET"

echo "== G4: spec §6.1.3 字面文案 + 三按钮真接对应 callback（D6/D7）=="
grep -q 'Text("复盘")' "$SHEET"
grep -q 'Text("再来一次")' "$SHEET"
grep -q 'Text("取消")' "$SHEET"
grep -q 'Button(action: onReview)' "$SHEET"
grep -q 'Button(action: onReplay)' "$SHEET"
grep -q 'Button(action: onCancel)' "$SHEET"

echo "== G5: D3/D4/D5 标题映射字面落地 =="
grep -q "public struct HistoryActionContent: Equatable, Sendable" "$CONTENT"
grep -q "static func formatStock(name: String, code: String)" "$CONTENT"
grep -q "Self.formatStock(name: record.stockName, code: record.stockCode)" "$CONTENT"
grep -q 'Text(content.title)' "$SHEET"

echo "== G6: D8 不实现盈亏色 / RGB 硬编码 / borderedProminent（反向验证）=="
if grep -qE '\.foregroundStyle\(\.red|\.foregroundStyle\(\.green' "$SHEET"; then
  echo "G6 FAIL: 不应实现盈亏色 .foregroundStyle(.red/.green)"; exit 1
fi
if grep -qE 'Color\(red:|UIColor\(' "$SHEET"; then
  echo "G6 FAIL: 不应 RGB 硬编码 Color(red:/UIColor("; exit 1
fi
# 锚真实用法 buttonStyle(.borderedProminent)（-F 定串），避免命中 header 注释里的 .borderedProminent 字样
if grep -qF 'buttonStyle(.borderedProminent)' "$SHEET"; then
  echo "G6 FAIL: D8 三按钮全 .bordered，不用 buttonStyle(.borderedProminent) 暗示主次"; exit 1
fi

echo "== G7: D12 不引业务运行时 / Content 平台无关 =="
if grep -qE 'import (GRDB|ZIPFoundation)' "$CONTENT" "$SHEET"; then
  echo "G7 FAIL: 不应 import GRDB/ZIPFoundation"; exit 1
fi
if grep -qE 'TradeCalculator|TickEngine|PositionManager|TrainingFlowController|TrainingMode|NormalFlow|ReviewFlow|ReplayFlow|APIClient' "$CONTENT" "$SHEET"; then
  echo "G7 FAIL: 不应引用业务运行时类型"; exit 1
fi

echo "== G8: D11 DEBUG-only fileprivate extension TrainingRecord preview fixture（与 U3 严格同款，反向锚真有目标）=="
grep -q '^#if DEBUG' "$SHEET"
grep -q "fileprivate extension TrainingRecord" "$SHEET"
grep -q "static func preview() -> TrainingRecord" "$SHEET"
if grep -qE "^public.*extension TrainingRecord|^extension TrainingRecord.*public" "$SHEET"; then
  echo "G8 FAIL: preview fixture extension 不能是 public（会跨模块污染 DEBUG 编译）"; exit 1
fi
if grep -qE "extension TrainingRecord|TrainingRecord\.preview" \
  ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift; then
  echo "G8 FAIL: 本 PR 不应改 PreviewFakes（D11 各自 fileprivate 内联）"; exit 1
fi

echo "== G9: D13 View 不调 dismiss（caller 负责 presentation）=="
if grep -qE 'dismiss\(\)|@Environment\(.*dismiss' "$SHEET"; then
  echo "G9 FAIL: View 不应调 dismiss() 或 @Environment(.dismiss)（caller 负责 presentation）"; exit 1
fi

echo "== G10: swift test 全量 PASS（基线 529 + 本 PR +10 = 期望 ≥539，宽松正则锚）=="
cd ios/Contracts
swift test 2>&1 | tee /tmp/u6-test-full.txt | tail -3
grep -qE "Test run with [0-9]+ tests in [0-9]+ suites passed" /tmp/u6-test-full.txt
cd -

echo "== G11: HistoryActionContentTests 单 suite 全绿（宽松正则锚）=="
cd ios/Contracts
swift test --filter HistoryActionContentTests 2>&1 | tee /tmp/u6-test-suite.txt | tail -3
grep -qE "Test run with [0-9]+ tests? in [0-9]+ suites? passed" /tmp/u6-test-suite.txt
cd -

echo "== G12: Mac Catalyst build-for-testing SUCCEEDED =="
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/u6-derived-final \
           build-for-testing 2>&1 | tail -5 | tee /tmp/u6-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/u6-build-tail.txt
cd -

echo
echo "✅ 所有 12 项 G1-G12 验收通过"
