#!/usr/bin/env bash
# Wave 1 顺位 11 (C5 Crosshair + Markers) 机检验收
# 用法：bash scripts/acceptance/plan_c5_crosshair_markers.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: 四个 C5 源文件存在（KLineView.swift 不动）=="
test -f ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift
test -f ios/Contracts/Sources/KlineTrainerContracts/Render/MarkersLayout.swift
test -f ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift
test -f ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift

echo "== G2: stub 已替换（无 'Wave 1 (C5)' 占位注释残留）=="
! grep -q "Wave 1 (C5): implement" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift \
  ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift

echo "== G3: drawCrosshair 保 spec 字面 3-arg 签名（D1 决议）=="
grep -qE "func drawCrosshair\(ctx: CGContext, at point: CGPoint\?, viewport: ChartViewport\) \{" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift

echo "== G4: drawCrosshair 体内通过 self.renderState + self.traitCollection 拿 candles/displayScale =="
grep -q "self.renderState.visibleCandles" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift
grep -q "self.traitCollection.displayScale" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift

echo "== G5: 用 partitioningIndex（不新建 binarySearchFirst alias）—— D2 落地 =="
grep -q "partitioningIndex" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/MarkersLayout.swift
! grep -q "binarySearchFirst" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/MarkersLayout.swift

echo "== G6: AppColor token 引用（不硬编码 RGB）—— D3/D4 落地 =="
grep -q "AppColor\.text" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift
grep -q "AppColor\.candleUp" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift
grep -q "AppColor\.candleDown" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift

echo "== G7: 时区固定 UTC+8 + locale POSIX —— D6 落地 =="
grep -q "secondsFromGMT: 8 \* 3600" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift
grep -q "en_US_POSIX" \
  ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift

echo "== G8: swift test 全量 PASS（含 C5 新测试，R1 F1 改用 exit code + Swift Testing 真输出）=="
cd ios/Contracts
# Swift Testing 输出格式 = "Test run with N tests in M suites passed after X seconds." 或
# 任一 test fail 时 exit code ≠ 0；swift test --enable-experimental-swift-testing 已在本仓默认开。
swift test 2>&1 | tee /tmp/c5-test-full.txt | tail -3
grep -E "Test run with [0-9]+ tests in [0-9]+ suites passed" /tmp/c5-test-full.txt > /dev/null
cd -

echo "== G9: Mac Catalyst build-for-testing SUCCEEDED =="
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/c5-derived-final \
           build-for-testing 2>&1 | tail -5 | tee /tmp/c5-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/c5-build-tail.txt

echo
echo "✅ 所有 9 项 G1-G9 验收通过"
