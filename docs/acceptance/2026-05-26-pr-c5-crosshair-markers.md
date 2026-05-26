# Wave 1 顺位 11 — C5 十字光标 + 交易标记 验收清单（非程序员）

> 本文用中文 + 行动化语言。每条 = 动作 / 期望 / 通过判据；禁忌词 per `.claude/workflow-rules.json`。

## 1. 仓库状态

| # | 动作 | 期望 | 通过判据 |
|---|------|------|----------|
| 1.1 | 在仓库根跑：`bash scripts/acceptance/plan_c5_crosshair_markers.sh` | 终端打出 9 行 G1-G9 + "✅ 所有 9 项 G1-G9 验收通过" | 终端最后一行精确包含 `✅ 所有 9 项 G1-G9 验收通过` 字符串 |

## 2. 文件存在与字数

| # | 动作 | 期望 | 通过判据 |
|---|------|------|----------|
| 2.1 | 跑：`wc -l ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift` | 行数 ≥ 60 且 ≤ 100 | 数值落区间内 |
| 2.2 | 跑：`wc -l ios/Contracts/Sources/KlineTrainerContracts/Render/MarkersLayout.swift` | 行数 ≥ 40 且 ≤ 80 | 数值落区间内 |
| 2.3 | 跑：`wc -l ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift` | 行数 ≥ 40 且 ≤ 80 | 数值落区间内 |
| 2.4 | 跑：`wc -l ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift` | 行数 ≥ 40 且 ≤ 80 | 数值落区间内 |

## 3. 测试数量

| # | 动作 | 期望 | 通过判据 |
|---|------|------|----------|
| 3.1 | 跑：`cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests in [0-9]+ suites passed"` | 看到一行 "Test run with 486 tests in 87 suites passed after X seconds."（Swift Testing 输出格式） | 该行出现 ≥ 1 次（数量轻微浮动可接受） |
| 3.2 | 数 C5 新 suite：`cd ios/Contracts && swift test 2>&1 \| grep -cE "Suite \"(CrosshairLinesTests\|CrosshairLabelTests\|FindCandleIndexTests\|MarkerPlacementsTests\|CrosshairSentinelTests\|MarkersSentinelTests)\" passed"` | 6（6 个 suite 各 1 行 Swift Testing 格式 ✔ Suite "Name" passed） | 数字 = 6 |

## 4. Mac Catalyst 编译

| # | 动作 | 期望 | 通过判据 |
|---|------|------|----------|
| 4.1 | 跑：`xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/c5-derived-acc build-for-testing 2>&1 \| tail -3` | 看到 "TEST BUILD SUCCEEDED" | 末 3 行内出现该字符串 |

## 5. spec 决策记录

| # | 动作 | 期望 | 通过判据 |
|---|------|------|----------|
| 5.1 | 翻开 `docs/superpowers/plans/2026-05-26-pr-c5-crosshair-markers.md`，找 "D1 ... 保留 spec 字面 3-arg ... self.renderState.visibleCandles" | 决策写明，权威依据列出 | 文字命中 |
| 5.2 | 翻开同上文件找 "D2 ... 用 partitioningIndex ... 不新增 alias" | 决策写明 | 文字命中 |

## 6. 反向 / 错误路径（手工）

| # | 动作 | 期望 | 通过判据 |
|---|------|------|----------|
| 6.1 | 翻开 `Render/CrosshairLayout.swift`，找 `if frame.contains(point)` | 出现 1 次 | grep 命中 1 次 |
| 6.2 | 翻开 `Render/MarkersLayout.swift`，找 `idx < candles.endIndex ? idx : nil` | 出现 1 次 | grep 命中 1 次 |
| 6.3 | 翻开 `Render/KLineView+Crosshair.swift`，找硬编码十六进制颜色字面（`#`）| 出现 0 次（颜色全走 AppColor token）| grep 不命中 |

## 7. 全部通过

| # | 动作 | 期望 | 通过判据 |
|---|------|------|----------|
| 7.1 | 1-6 节所有"通过判据"列均勾上 | 是 | 人工核对 |
