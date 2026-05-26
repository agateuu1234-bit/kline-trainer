# C5 辅助层渲染（Crosshair + Markers）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PR #51 留下的 C5 两个空 stub（`drawCrosshair` / `drawMarkers`）替换为真实现：**十字光标**（长按时绘制竖/横线 + 价签 + 时间签）+ **交易标记**（红点B 买 / 绿点S 卖，二分谓词精确锚定全周期同步显示）。

**Architecture:** 几何/布局逻辑（十字线段对、价/时签框、marker 锚位 + B/S 字符锚位、findCandleIndex 二分谓词）抽到**平台无关**两个纯函数文件 `CrosshairLayout.swift` + `MarkersLayout.swift`，由 macOS host `swift test` 真断言。`KLineView+Crosshair.swift` 与 `KLineView+Markers.swift` 两个 extension 方法降为**薄 UIKit 层**：调用布局函数拿到几何原语，再用 `AppColor` token + CGContext stroke/fill + `NSString.draw` 文本绘制；由 Mac Catalyst `build-for-testing` 编译闸门守护。这与 C3/C4 已落地的 `MainChartLayout` / `SubChartLayout`（平台无关 + host 全测）+ §15.1 #3 Catalyst 编译闸门完全同款两闸门架构。**签名守 spec 字面决议（D1）**：spec §C5 L1302 `drawCrosshair(ctx, at: point, viewport)` 不含 mapper / candles；stub L9 注释要求"价格/时间标签框" + 时间签需 candles ——本 PR **保留 spec 字面 3-arg 签名不动**，`drawCrosshair` 在函数体内读 `self.renderState.visibleCandles` + 从 `self.traitCollection.displayScale` 派生 `CoordinateMapper(viewport: viewport, displayScale:)`（KLineView 是 final class，extension 方法可访问 self 实例）。**不**碰 spec L1302，**不**碰 KLineView.swift 派发点。理由：尊重 PR #64 E2-RFC 建立的"spec 改动走 governance PR"先例（per memory `project_pr64_e2rfc_merged`），架构对称性 < spec 纪律。

**Tech Stack:** Swift 6.0 / Swift Testing（`import Testing` + `@Test` + `#expect`）/ CoreGraphics（host 可用）/ UIKit（仅 Catalyst，含 `NSString.draw` 文本绘制）/ 已冻结模块：`CoordinateMapper`（C1a Geometry.swift）/ `KLineCandle.endGlobalIndex: Int`（F1 Models.swift L73）/ `TradeMarker(globalTick, price, direction)`（F1 Models.swift L212-222）/ `TradeDirection.{buy,sell}`（F1 Models.swift L20-23）/ `partitioningIndex` BinarySearch util（F1 BinarySearch.swift L12-26，**注释 L4 已显式标 C5 是消费方**）/ `AppColor.candleUp/candleDown/text/background`（F2 Theme.swift）。

---

## 背景与既有接缝（实施者必读）

- 派发点已存在且**不改动**：`Render/KLineView.swift` 的 `draw(_:)` 已调用 `drawMarkers(ctx:viewport:mapper:markers:candles:)`（L57-58）+ `drawCrosshair(ctx:at:viewport:)`（L59，spec 字面 3-arg）。本 PR 只填两个方法体；不改 `KLineView.swift` 任何行。`drawCrosshair` 内部通过 `self.renderState.visibleCandles` 拿 candles + `CoordinateMapper(viewport: viewport, displayScale: self.traitCollection.displayScale)` 派生 mapper（per D1）。
- 当前 stub：`Render/KLineView+Crosshair.swift`（13 行）+ `Render/KLineView+Markers.swift`（17 行），均 `#if canImport(UIKit)` 守卫。
- `KLineRenderState`（C1c 已落地，`Render/KLineRenderState.swift`）的 `markers: [TradeMarker]`（L21）+ `crosshairPoint: CGPoint?`（L23）字段已就位；`.empty` 给 `markers: []` + `crosshairPoint: nil`（L73/L75）。**本 PR 不动 KLineRenderState**。
- `CoordinateMapper`（`Geometry/Geometry.swift` L127-170，平台无关）：
  - `indexToX(_:)` 已 round-to-device-pixel（L138-141）；**crosshair 横线竖线必须用这两个返回值，不再二次取整**。
  - `priceToY(_:)` 已 round-to-device-pixel（L143-149）。
  - `yToPrice(_:)` 反映射（L165-169，给 crosshair 价签计算用）。
  - `xToIndex(_:)` verify-and-correct（L153-163，给 crosshair 时间签解析 candle index 用）。
- `KLineCandle`（`Models/Models.swift`）：
  - `endGlobalIndex: Int`（L73，非可选）—— `findCandleIndex` 二分谓词的 key。
  - `datetime: Int64`（unix epoch 秒）—— crosshair 时间签源。
- `TradeMarker`（`Models/Models.swift` L212-222）：`globalTick: Int` + `price: Double` + `direction: TradeDirection`，**Equatable + Sendable，非 Codable**（UI overlay runtime-only，M0.3 已冻结）。
- `partitioningIndex`（`Models/BinarySearch.swift` L12-26）：单调谓词二分；**返回 endIndex 表示"无匹配"**（spec L1311 字面写 `binarySearchFirst`，util 实际叫 `partitioningIndex`——本 PR `findCandleIndex` 直接用 `partitioningIndex`，**不**新增 alias；spec 字面差异在代码注释 + D2 决议中说明）。
- `AppColor` F2 token（`Theme/Theme.swift`，`#if canImport(UIKit)`）：
  - `.candleUp`（红 0.86/0.18/0.20）：买入 marker 红点 + 字母 "B"。
  - `.candleDown`（绿 0.16/0.66/0.36）：卖出 marker 绿点 + 字母 "S"。
  - `.text`（白 0.92）：crosshair 线 + 标签文字。
  - `.background`（深 0.10/0.10/0.12）：标签框背景。
- 测试基线：当前 466 tests / 81 suites（PR #67 merge 后，per 本仓 README v1.4 + PR #66/#67 memory）。本 PR 目标 **+20 host 测试**（Task 1 = 3 / Task 2 = 4 / Task 3 = 6 / Task 6 哨兵 = 7 → **共 +20 / 总 486**）。Task 4-5 仅 UIKit 薄层 + Catalyst 编译验证，不加 swift test。

---

## Task 0 — §15.3 评审策略前置 + spec 偏差裁决

> 完成 Task 0 才进 Task 1。本节是**决策记录**，无代码；实施者据此实现，评审据此核对。

- [ ] **局部对抗性评审（必）**：本 plan C5 scope 内对抗性 review = 用户本次显式指定 **Claude Opus 4.7 xhigh effort 双闸门**（plan-stage + impl-stage / branch-diff），**不走 codex**（per memory `feedback_openai_quota_ci_pattern` + 用户本次显式 prompt）。4-5 轮内收敛，超 5 轮 escalate（`feedback_codex_plan_budget_overshoot`）。
- [ ] **集成层评审（N/A）**：C8 `ChartContainerView` 桥接 + LongPress 手势 → `renderState.crosshairPoint` 写回 + TrainingEngine `markers` → `renderState.markers` 注入在 **Wave 2**；本 PR 不含集成层。
- [ ] **性能评审（N/A）**：plan v1.5 §一 "单帧 <4ms / Instruments" 属 **Phase 5 磨光 PR**；C5 是 Phase 1 纯 `draw(_:)` 渲染，本 PR 不做 Instruments 评审（同 C3/C4 决议）。

### Spec 偏差裁决（D1-D10，全部写进代码注释 + 验收）

| # | 偏差/歧义 | 裁决 | 权威依据 |
|---|---|---|---|
| **D1** | `drawCrosshair` 签名缺 `mapper`/`candles`（spec L1302）vs stub L9 注释要求 "价格/时间标签框" | **保留 spec 字面 3-arg `(ctx, at: point, viewport)`** + 函数体内通过 `self.renderState.visibleCandles` 拿 candles + 从 `self.traitCollection.displayScale` 派生 `CoordinateMapper(viewport: viewport, displayScale:)`。KLineView 是 `final class`（KLineView.swift L15），extension 方法可访问 self 实例 —— 这是惯用 UIKit 模式。**不**改 spec、**不**改 KLineView.swift 派发点。理由：尊重 PR #64 E2-RFC 建立的"spec 改动走独立 governance PR"先例；架构对称性 < spec 纪律。 | spec L1302 字面 + `KLineView.swift` L15 `final class` + memory `project_pr64_e2rfc_merged` + R1 F3 |
| **D2** | spec L1311 `candles.binarySearchFirst { ... }` 实际 util 名 `partitioningIndex` | `findCandleIndex` 内直接用 `partitioningIndex { $0.endGlobalIndex >= marker.globalTick }`；**不**新增 `binarySearchFirst` alias。理由：BinarySearch.swift L4 已显式标 "消费方：Wave 1 C5"；新增 alias 是 vanity wrapper（CLAUDE.md "Simplicity First / No abstractions for single-use code"）。代码注释引 spec L1311 + 注明字面差。 | BinarySearch.swift L4 注释 + CLAUDE.md §2 + memory `feedback_outline_no_inline_implementation` |
| **D3** | 十字光标线条颜色 | `AppColor.text`（白 0.92，全不透明）。**不**用 `gridLine`（白 0.5 alpha 0.25 太透明，标准 K 线 app 十字光标视觉惯例是高对比）。 | F2 Theme 已冻 token + 视觉惯例 + Simplicity（不引入新 token） |
| **D4** | 标签框（价签 + 时间签）颜色 | 背景 `AppColor.background`（深 0.10/0.10/0.12）+ 文字 `AppColor.text`（白 0.92）。 | F2 Theme 已冻 + 与主图 chart-area 背景一致 |
| **D5** | 价格标签数值格式 | 2 位小数（A 股惯例）：`String(format: "%.2f", price)`。Locale 中性（避免千分位逗号干扰窄标签框）。 | A 股惯例 + plan v1.5 §四"价格"全用 Double + 不分大小区域 |
| **D6** | 时间标签格式 | `yyyy-MM-dd HH:mm`（中性 24h，UTC+8 北京时区 fixed `TimeZone(secondsFromGMT: 8*3600)`，避免 trainer 设备时区差异）。candle.datetime 是 unix 秒。 | plan v1.5 §四 K 线惯例 + 中国 A 股交易所固定 UTC+8 |
| **D7** | crosshair point 横/竖线吸附蜡烛中心 vs 自由位置 | **不吸附**：横线 = `point.y`（已 round-to-device-pixel by caller / displayScale 由 mapper 提供）；竖线 = `point.x`。理由：spec 字面 "at point"；吸附是 UX 设计决策，留给 Wave 2 LongPress 手势源（C8 可在写回 `crosshairPoint` 前自吸附）。但**价签 / 时签数值仍走 mapper.yToPrice / xToIndex**（数值给真实价/时；线本身保留触点位置）。 | spec L1302 "at point" 字面 + 渲染层职责单一 + Simplicity |
| **D8** | crosshair point 落在 mainChartFrame 外 | **不画**（含 point.x / point.y 任一在 frame 外即不画）。理由：避免十字线越界画到 volume/MACD 子图上造成视觉污染；point 越界等价于"指针出图"，等价于无光标。**不返回错误**，静默跳过。 | 渲染层职责 + 视觉合理性 + UIKit clipping 习惯 |
| **D9** | marker 锚定 candle 不在可见 slice 内 | **跳过该 marker**（`findCandleIndex` 返回 `endIndex` 或 `<startIndex`/`>=endIndex` → nil → 跳过）。理由：spec L1310-1311 字面"二分找到对应 K 线"，找不到即跨期未出现在可见区。 | spec L1310-1311 + plan v1.5 §4.3 "对应该 globalTick 的 K 线" |
| **D10** | marker 视觉布局（dot + 字母 B/S） | dot 半径 = 5pt（设备无关，渲染时 `ctx.fillEllipse(in:)`）；字母 = 系统字体 10pt bold，**白色**（`AppColor.text`），居中于 dot。dot 中心 = `(mapper.indexToX(candleIndex), mapper.priceToY(candle.close))`（**锚到该 K 线的收盘价 Y**，per plan v1.5 §4.3 L767 字面）；字母 baseline 偏移 = font.capHeight/2（视觉居中）。 | plan v1.5 §4.3 L767-769 字面 "收盘价 Y 轴" + "红点 B / 绿点 S" + 标准 K 线 app 标记视觉 |

---

## File Structure

| 文件 | 动作 | 职责 | 平台 |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift` | **新建** | 纯布局函数：`lines(at:mapper:)` 返回 `CrosshairLines?`、`priceLabel(at:mapper:)` 返回 `(rect: CGRect, text: String)`、`timeLabel(at:mapper:candles:)` 返回 `(rect, text)?`（frame 内/外 + slice 越界判定均内联 in lines/timeLabel） | 平台无关（host 全测） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/MarkersLayout.swift` | **新建** | 纯布局函数：`findCandleIndex(for:in:)` 二分谓词 + `markerPlacements(mapper:markers:candles:)` 返回 `[MarkerPlacement]`（含 center / direction / candleIndex） | 平台无关（host 全测） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift` | **改**（填 stub，保 spec 字面 3-arg） | `drawCrosshair(ctx:at:viewport:)` 调布局函数 + `AppColor` + CGContext stroke + `NSString.draw`；体内通过 `self.renderState.visibleCandles` + `self.traitCollection.displayScale` 拿 candles / 派生 mapper | `#if canImport(UIKit)` |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift` | **改**（填 stub） | `drawMarkers` 调布局函数 + `AppColor` + CGContext fillEllipse + `NSString.draw` | `#if canImport(UIKit)` |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift` | **新建** | 布局函数 host 测试（lines / priceLabel / timeLabel + 3 哨兵：boundary 4 角 / priceLabelMirrorsMapper / timeLabelLocaleNeutral） | 平台无关 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/MarkersLayoutTests.swift` | **新建** | 布局函数 host 测试（findCandleIndex 边界 + markerPlacements 几何） | 平台无关 |
| `scripts/acceptance/plan_c5_crosshair_markers.sh` | **新建** | 机检验收脚本（grep 谓词验证 + swift test 输出 + Catalyst build 输出） | bash |
| `docs/acceptance/2026-05-26-pr-c5-crosshair-markers.md` | **新建** | 非程序员逐条验收清单（action / expected / pass-fail，中文） | md |

---

## Task 1: `CrosshairLayout.lines` —— 十字线几何 + 内联范围谓词

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `CrosshairLayoutTests.swift`：

```swift
// Kline Trainer Swift Contracts — C5 CrosshairLayout host tests
// Spec: kline_trainer_modules_v1.4.md §C5 + plan 2026-05-26-pr-c5-crosshair-markers.md
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func mc(_ idx: Int, datetime: Int64, close: Double = 10) -> KLineCandle {
    KLineCandle(period: .m3, datetime: datetime,
                open: close, high: close + 1, low: close - 1, close: close,
                volume: 100, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: idx, endGlobalIndex: idx)
}

private func makeMapper(startIndex: Int = 0, count: Int = 10) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return CoordinateMapper(viewport: vp, displayScale: 2)
}

@Suite("CrosshairLayout.lines")
struct CrosshairLinesTests {

    @Test("frame 内点：横线 y = point.y、竖线 x = point.x，两线跨 frame 全宽全高")
    func basic() {
        let m = makeMapper()
        let lines = CrosshairLayout.lines(at: CGPoint(x: 250, y: 300), mapper: m)
        #expect(lines != nil)
        guard let lines else { return }
        #expect(lines.horizontal.from == CGPoint(x: 0, y: 300))
        #expect(lines.horizontal.to   == CGPoint(x: 1000, y: 300))
        #expect(lines.vertical.from   == CGPoint(x: 250, y: 0))
        #expect(lines.vertical.to     == CGPoint(x: 250, y: 600))
    }

    @Test("frame 外点（x 越界）：lines == nil")
    func outsideX() {
        let m = makeMapper()
        #expect(CrosshairLayout.lines(at: CGPoint(x: -1, y: 300), mapper: m) == nil)
        #expect(CrosshairLayout.lines(at: CGPoint(x: 1001, y: 300), mapper: m) == nil)
    }

    @Test("frame 外点（y 越界）：lines == nil")
    func outsideY() {
        let m = makeMapper()
        #expect(CrosshairLayout.lines(at: CGPoint(x: 250, y: -1), mapper: m) == nil)
        #expect(CrosshairLayout.lines(at: CGPoint(x: 250, y: 601), mapper: m) == nil)
    }
}
```

- [ ] **Step 2: 运行测试，验证 FAIL（编译错误：`CrosshairLayout` 未定义）**

```
swift test --package-path ios/Contracts --filter CrosshairLinesTests
```

期望：编译失败 / "cannot find 'CrosshairLayout' in scope"。

- [ ] **Step 3: 实现 `CrosshairLayout.lines`**

新建 `CrosshairLayout.swift`：

```swift
// Kline Trainer Swift Contracts — C5 十字光标布局纯函数（平台无关）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313 + plan 2026-05-26-pr-c5-crosshair-markers.md
//
// 本文件不 import UIKit：所有几何/文本字符串在 host swift test 真断言。
// drawXxx 的 UIKit 描边/填充/文本绘制薄层在 KLineView+Crosshair.swift（#if canImport(UIKit)）。
//
// D7：lines 不吸附蜡烛中心，竖/横 = point.x / point.y 原值；吸附决策在 Wave 2 LongPress 源。
// D8：point 落在 mainChartFrame 外即返回 nil；caller 整体跳过绘制。

import Foundation
import CoreGraphics

/// 十字光标一对横竖线段（端点已对齐 mainChartFrame 四边）。
struct CrosshairLines: Equatable, Sendable {
    let horizontal: LineSegment
    let vertical: LineSegment

    struct LineSegment: Equatable, Sendable {
        let from: CGPoint
        let to: CGPoint
    }
}

enum CrosshairLayout {

    /// D7/D8：point 在 mainChartFrame 内则返回穿 frame 全宽全高的横/竖线对；否则 nil。
    static func lines(at point: CGPoint, mapper: CoordinateMapper) -> CrosshairLines? {
        let frame = mapper.viewport.mainChartFrame
        guard frame.contains(point) else { return nil }
        return CrosshairLines(
            horizontal: .init(from: CGPoint(x: frame.minX, y: point.y),
                              to:   CGPoint(x: frame.maxX, y: point.y)),
            vertical:   .init(from: CGPoint(x: point.x, y: frame.minY),
                              to:   CGPoint(x: point.x, y: frame.maxY)))
    }
}
```

- [ ] **Step 4: 运行测试，验证 PASS（3 个）**

```
swift test --package-path ios/Contracts --filter CrosshairLinesTests
```

期望：3 PASS / 0 FAIL。

- [ ] **Step 5: 提交**

```
cd ios/Contracts && swift test --filter CrosshairLinesTests 2>&1 | tail -5 && cd -
git add ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift
git commit -m "C5 Task 1: CrosshairLayout.lines (3 tests, frame.contains 内联)"
```

---

## Task 2: `CrosshairLayout.priceLabel` + `timeLabel` —— 价/时签字符串与框

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift`

- [ ] **Step 1: 写失败测试**

在 `CrosshairLayoutTests.swift` 追加：

```swift
@Suite("CrosshairLayout.priceLabel / timeLabel")
struct CrosshairLabelTests {

    @Test("priceLabel：价 = mapper.yToPrice(point.y) 2 位小数；rect.right=frame.maxX；rect.center.y=point.y")
    func priceLabelBasic() {
        let m = makeMapper()
        // point.y=300 → yToPrice = 100 - 300/600 * 100 = 50.00
        let label = CrosshairLayout.priceLabel(at: CGPoint(x: 250, y: 300), mapper: m)
        #expect(label.text == "50.00")
        // 标签框右贴 frame.maxX；垂直居中 point.y
        #expect(label.rect.maxX == 1000)
        #expect(label.rect.midY == 300)
    }

    @Test("priceLabel：负价/超 100 也按 yToPrice 字面（caller 已保证 frame 内）")
    func priceLabelEdge() {
        let m = makeMapper()
        // point.y=0 → yToPrice = 100.00
        #expect(CrosshairLayout.priceLabel(at: CGPoint(x: 0, y: 0), mapper: m).text == "100.00")
        // point.y=600 → yToPrice = 0.00
        #expect(CrosshairLayout.priceLabel(at: CGPoint(x: 0, y: 600), mapper: m).text == "0.00")
    }

    @Test("timeLabel：xToIndex(point.x) 落在 candles 范围内 → 取 datetime 格式化（UTC+8）；rect.bottom=frame.maxY、rect.center.x=point.x")
    func timeLabelInside() {
        let m = makeMapper(count: 3)
        // 2025-01-02 09:30:00 UTC+8 = 1735781400 epoch
        let candles = [mc(0, datetime: 1735781400),
                       mc(1, datetime: 1735781580),  // 09:33
                       mc(2, datetime: 1735781760)]  // 09:36
        // point.x=10 → xToIndex 解析为 index 1 → datetime 1735781580 → "2025-01-02 09:33"
        let label = CrosshairLayout.timeLabel(at: CGPoint(x: 10, y: 300),
                                              mapper: m, candles: candles[0..<3])
        #expect(label != nil)
        #expect(label?.text == "2025-01-02 09:33")
        #expect(label?.rect.maxY == 600)
        #expect(label?.rect.midX == 10)
    }

    @Test("timeLabel：xToIndex 超出 candles 范围 → nil")
    func timeLabelOutside() {
        let m = makeMapper(count: 3)
        let candles = [mc(0, datetime: 1735781400)]
        // point.x=20 → xToIndex 解析为 2 → 越界（slice 仅 0...0）
        let label = CrosshairLayout.timeLabel(at: CGPoint(x: 20, y: 300),
                                              mapper: m, candles: candles[0..<1])
        #expect(label == nil)
    }
}
```

- [ ] **Step 2: 运行测试，验证 FAIL**

```
swift test --package-path ios/Contracts --filter CrosshairLabelTests
```

期望：编译错误 / "no such member 'priceLabel' / 'timeLabel'"。

- [ ] **Step 3: 实现 priceLabel + timeLabel**

在 `CrosshairLayout.swift` 追加（enum body 内）：

```swift
    /// 价格标签：D5 2 位小数 + Locale 中性；D4 框右贴 mainChartFrame.maxX、垂直居中 point.y。
    /// rect 仅给"参考几何"——具体框宽/高在 caller 的 UIKit 层按字体度量；这里给字符 + 锚位。
    static func priceLabel(at point: CGPoint,
                           mapper: CoordinateMapper) -> (rect: CGRect, text: String) {
        let price = mapper.yToPrice(point.y)
        let text = String(format: "%.2f", price)
        // 锚位参考框：宽 = 60、高 = 18；右贴 frame.maxX；垂直居中 point.y。
        // caller UIKit 层若字体度量不同可重排，但锚锚点（maxX / midY）契约固定。
        let frame = mapper.viewport.mainChartFrame
        let labelWidth: CGFloat = 60
        let labelHeight: CGFloat = 18
        let rect = CGRect(x: frame.maxX - labelWidth,
                          y: point.y - labelHeight / 2,
                          width: labelWidth, height: labelHeight)
        return (rect: rect, text: text)
    }

    /// 时间标签：D6 yyyy-MM-dd HH:mm UTC+8 fixed；D4 框底贴 mainChartFrame.maxY、水平居中 point.x。
    /// 用 xToIndex 解析候选 candle，越界（< slice.startIndex 或 >= slice.endIndex）返回 nil。
    static func timeLabel(at point: CGPoint,
                          mapper: CoordinateMapper,
                          candles: ArraySlice<KLineCandle>) -> (rect: CGRect, text: String)? {
        let candleIndex = mapper.xToIndex(point.x)
        guard candleIndex >= candles.startIndex && candleIndex < candles.endIndex else {
            return nil
        }
        let datetime = candles[candleIndex].datetime
        let date = Date(timeIntervalSince1970: TimeInterval(datetime))
        // DateFormatter 是 NSObject 引用类型，let 即可配置 (per R1 F7 修正)。
        // 每次 draw 重建——可接受：drawCrosshair 仅在长按显示 crosshair 时才走到此，频次远低于
        // 主图 60Hz；如 Phase 5 磨光需 hoist 全局 static，再走单独 PR。
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.locale = Locale(identifier: "en_US_POSIX")  // 避免本地化串干扰
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let text = formatter.string(from: date)
        let frame = mapper.viewport.mainChartFrame
        let labelWidth: CGFloat = 120
        let labelHeight: CGFloat = 18
        let rect = CGRect(x: point.x - labelWidth / 2,
                          y: frame.maxY - labelHeight,
                          width: labelWidth, height: labelHeight)
        return (rect: rect, text: text)
    }
```

- [ ] **Step 4: 运行测试，验证 PASS（4 个）**

```
swift test --package-path ios/Contracts --filter CrosshairLabelTests
```

期望：4 PASS / 0 FAIL。

- [ ] **Step 5: 提交**

```
cd ios/Contracts && swift test --filter CrosshairLabelTests 2>&1 | tail -5 && cd -
git add ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift
git commit -m "C5 Task 2: CrosshairLayout.priceLabel + timeLabel (4 tests)"
```

---

## Task 3: `MarkersLayout.findCandleIndex` + `markerPlacements` —— 二分谓词 + 锚位

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/MarkersLayout.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/MarkersLayoutTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `MarkersLayoutTests.swift`：

```swift
// Kline Trainer Swift Contracts — C5 MarkersLayout host tests
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313 + plan v1.5 §4.3 L753-771
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func mc(_ idx: Int, endGlobal: Int, close: Double = 10) -> KLineCandle {
    KLineCandle(period: .m3, datetime: Int64(idx),
                open: close, high: close + 1, low: close - 1, close: close,
                volume: 100, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: idx, endGlobalIndex: endGlobal)
}

private func makeMapper(startIndex: Int = 0, count: Int = 5) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return CoordinateMapper(viewport: vp, displayScale: 2)
}

@Suite("MarkersLayout.findCandleIndex")
struct FindCandleIndexTests {

    @Test("精确命中：endGlobalIndex == globalTick → 返回该 index")
    func exactHit() {
        // candles: endGlobal = [5, 10, 15, 20]
        let candles = [mc(0, endGlobal: 5),  mc(1, endGlobal: 10),
                       mc(2, endGlobal: 15), mc(3, endGlobal: 20)]
        let marker = TradeMarker(globalTick: 10, price: 10, direction: .buy)
        #expect(MarkersLayout.findCandleIndex(for: marker, in: candles[0..<4]) == 1)
    }

    @Test("首根满足谓词：endGlobalIndex >= globalTick 取最小 index（spec L1310 字面）")
    func firstSatisfying() {
        let candles = [mc(0, endGlobal: 5),  mc(1, endGlobal: 10),
                       mc(2, endGlobal: 15), mc(3, endGlobal: 20)]
        // globalTick = 7：endGlobal=5 不满足，endGlobal=10 满足 → index 1
        let marker = TradeMarker(globalTick: 7, price: 10, direction: .buy)
        #expect(MarkersLayout.findCandleIndex(for: marker, in: candles[0..<4]) == 1)
    }

    @Test("超出最大 endGlobalIndex → nil（找不到，跳过该 marker per D9）")
    func beyondMax() {
        let candles = [mc(0, endGlobal: 5), mc(1, endGlobal: 10)]
        let marker = TradeMarker(globalTick: 100, price: 10, direction: .sell)
        #expect(MarkersLayout.findCandleIndex(for: marker, in: candles[0..<2]) == nil)
    }

    @Test("空 slice → nil")
    func empty() {
        let candles: [KLineCandle] = []
        let marker = TradeMarker(globalTick: 5, price: 10, direction: .buy)
        #expect(MarkersLayout.findCandleIndex(for: marker, in: candles[0..<0]) == nil)
    }
}

@Suite("MarkersLayout.markerPlacements")
struct MarkerPlacementsTests {

    @Test("D10：dot center = (indexToX(idx), priceToY(candle.close))；direction 透传")
    func dotCenter() {
        let m = makeMapper(count: 4)
        // close = 50 → priceToY = 600 - 50/100*600 = 300
        let candles = [mc(0, endGlobal: 5,  close: 50),
                       mc(1, endGlobal: 10, close: 50),
                       mc(2, endGlobal: 15, close: 50),
                       mc(3, endGlobal: 20, close: 50)]
        let markers = [TradeMarker(globalTick: 10, price: 51, direction: .buy)]
        let placements = MarkersLayout.markerPlacements(
            mapper: m, markers: markers, candles: candles[0..<4])
        #expect(placements.count == 1)
        #expect(placements[0].center == CGPoint(x: 10, y: 300))  // indexToX(1)=10
        #expect(placements[0].direction == .buy)
        #expect(placements[0].candleIndex == 1)
    }

    @Test("D9：marker 越界（globalTick > 所有 endGlobalIndex） → 跳过，placements 不含该项")
    func skipOutOfRange() {
        let m = makeMapper(count: 2)
        let candles = [mc(0, endGlobal: 5), mc(1, endGlobal: 10)]
        let markers = [TradeMarker(globalTick: 7,   price: 10, direction: .buy),   // 命中 idx 1
                       TradeMarker(globalTick: 100, price: 10, direction: .sell)]  // 跳过
        let placements = MarkersLayout.markerPlacements(
            mapper: m, markers: markers, candles: candles[0..<2])
        #expect(placements.count == 1)
        #expect(placements[0].direction == .buy)
    }
}
```

- [ ] **Step 2: 运行测试，验证 FAIL**

```
swift test --package-path ios/Contracts --filter "FindCandleIndexTests|MarkerPlacementsTests"
```

期望：编译错误。

- [ ] **Step 3: 实现 `MarkersLayout`**

新建 `MarkersLayout.swift`：

```swift
// Kline Trainer Swift Contracts — C5 交易标记布局纯函数（平台无关）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313 + plan v1.5 §4.3 L753-771
//
// D2：spec L1311 字面 `candles.binarySearchFirst { ... }`；BinarySearch util 名 `partitioningIndex`。
//     本文件直接用 partitioningIndex，不新增 alias（参 BinarySearch.swift L4 注释）。
// D9：findCandleIndex 返回 nil 时跳过该 marker。
// D10：dot center = (indexToX(idx), priceToY(candle.close))，锚到收盘价 Y。

import Foundation
import CoreGraphics

/// 单个 marker 的可绘几何（dot center + B/S 字母方向 + 该锚定 K 线 index 给 caller 调试）。
struct MarkerPlacement: Equatable, Sendable {
    let center: CGPoint
    let direction: TradeDirection
    let candleIndex: Int
}

enum MarkersLayout {

    /// 精确二分谓词（spec L1308-1312 字面）：找首个 endGlobalIndex >= marker.globalTick 的 K 线。
    /// 返回 partitioningIndex == endIndex 视为"无匹配"，统一为 nil（D9 跳过）。
    static func findCandleIndex(for marker: TradeMarker,
                                in candles: ArraySlice<KLineCandle>) -> Int? {
        let idx = candles.partitioningIndex { $0.endGlobalIndex >= marker.globalTick }
        return idx < candles.endIndex ? idx : nil
    }

    /// 遍历 markers，对每个 marker 找候选 K 线，跳过越界（D9），构造 placements。
    /// dot center 锚到 (indexToX(idx), priceToY(candle.close))，per D10 + plan v1.5 §4.3 L767。
    static func markerPlacements(mapper: CoordinateMapper,
                                 markers: [TradeMarker],
                                 candles: ArraySlice<KLineCandle>) -> [MarkerPlacement] {
        var out: [MarkerPlacement] = []
        out.reserveCapacity(markers.count)
        for marker in markers {
            guard let idx = findCandleIndex(for: marker, in: candles) else { continue }
            let candle = candles[idx]
            let center = CGPoint(x: mapper.indexToX(idx),
                                 y: mapper.priceToY(candle.close))
            out.append(MarkerPlacement(center: center,
                                       direction: marker.direction,
                                       candleIndex: idx))
        }
        return out
    }
}
```

- [ ] **Step 4: 运行测试，验证 PASS（6 个）**

```
swift test --package-path ios/Contracts --filter "FindCandleIndexTests|MarkerPlacementsTests"
```

期望：6 PASS / 0 FAIL。

- [ ] **Step 5: 提交**

```
cd ios/Contracts && swift test --filter "FindCandleIndexTests|MarkerPlacementsTests" 2>&1 | tail -5 && cd -
git add ios/Contracts/Sources/KlineTrainerContracts/Render/MarkersLayout.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/MarkersLayoutTests.swift
git commit -m "C5 Task 3: MarkersLayout.findCandleIndex + markerPlacements (6 tests)"
```

---

## Task 4: `KLineView+Crosshair.swift` —— 替换 stub（保 spec 字面 3-arg 签名）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift`（替换全文）

- [ ] **Step 1: 在 `KLineView+Crosshair.swift` 全文替换为：**

```swift
// Kline Trainer Swift Contracts — C5 十字光标渲染（UIKit 薄层）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313
//
// 几何/字符串在 CrosshairLayout.swift（平台无关）；本文件只做 UIKit 描边 + 框 + 文本。
// 签名保 spec 字面 3-arg per plan D1：通过 self.renderState.visibleCandles + self.traitCollection
// 派生 candles 与 mapper（KLineView 是 final class，extension 可访问 self）。不改 spec、不改 KLineView.swift 派发点。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C5 十字光标：point != nil 且在 mainChartFrame 内时画横+竖线 + 右侧价签 + 底部时签。
    /// point == nil 直接返回（无光标）。frame 外 point 由 CrosshairLayout.lines 返回 nil 跳过。
    func drawCrosshair(ctx: CGContext, at point: CGPoint?, viewport: ChartViewport) {
        guard let point else { return }
        let mapper = CoordinateMapper(viewport: viewport,
                                      displayScale: self.traitCollection.displayScale)
        guard let lines = CrosshairLayout.lines(at: point, mapper: mapper) else { return }
        let candles = self.renderState.visibleCandles

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // D3：crosshair 线 = AppColor.text（白 0.92），1 device pixel 宽。
        AppColor.text.setStroke()
        ctx.setLineWidth(1 / mapper.displayScale)
        ctx.move(to: lines.horizontal.from); ctx.addLine(to: lines.horizontal.to); ctx.strokePath()
        ctx.move(to: lines.vertical.from);   ctx.addLine(to: lines.vertical.to);   ctx.strokePath()

        // 价签
        let priceLabel = CrosshairLayout.priceLabel(at: point, mapper: mapper)
        drawLabelBox(ctx: ctx, rect: priceLabel.rect, text: priceLabel.text)

        // 时签（candles 越界则 nil）
        if let timeLabel = CrosshairLayout.timeLabel(at: point, mapper: mapper, candles: candles) {
            drawLabelBox(ctx: ctx, rect: timeLabel.rect, text: timeLabel.text)
        }
    }

    /// D4：标签框 = background 实心 + text 文字，10pt 系统字体，居中。
    private func drawLabelBox(ctx: CGContext, rect: CGRect, text: String) {
        AppColor.background.setFill()
        ctx.fill(rect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: AppColor.text,
        ]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        let drawX = rect.midX - size.width / 2
        let drawY = rect.midY - size.height / 2
        str.draw(at: CGPoint(x: drawX, y: drawY), withAttributes: attrs)
    }
}

#endif
```

- [ ] **Step 2: 运行 Catalyst build-for-testing 验证编译**

```
xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/c5-derived-task4 \
           build-for-testing 2>&1 | tail -20
```

期望：`** TEST BUILD SUCCEEDED **`。

- [ ] **Step 3: 跑全量 host swift test 不退步**

```
cd ios/Contracts && swift test 2>&1 | tail -10
```

期望：原 466 → 现 479 全 PASS（Task 1=3 + Task 2=4 + Task 3=6 共 +13；Task 4 不加 test）。

- [ ] **Step 4: 提交**

```
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift
git commit -m "C5 Task 4: drawCrosshair UIKit shell (保 spec 字面 3-arg, D1)"
```

---

## Task 5: `KLineView+Markers.swift` —— 替换 stub

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift`（替换全文）

- [ ] **Step 1: 全文替换为：**

```swift
// Kline Trainer Swift Contracts — C5 交易标记渲染（UIKit 薄层）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313 + plan v1.5 §4.3 L753-771
//
// 几何/锚位/字母字符在 MarkersLayout.swift（平台无关）；本文件只做 UIKit 圆点 + 字母。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C5 交易标记：遍历 markers，二分定位候选 K 线（D9 越界跳过），
    /// dot center 锚到收盘价 Y（D10），buy = AppColor.candleUp + "B"，sell = AppColor.candleDown + "S"。
    func drawMarkers(ctx: CGContext,
                     viewport: ChartViewport,
                     mapper: CoordinateMapper,
                     markers: [TradeMarker],
                     candles: ArraySlice<KLineCandle>) {
        guard !markers.isEmpty, !candles.isEmpty else { return }
        let placements = MarkersLayout.markerPlacements(
            mapper: mapper, markers: markers, candles: candles)
        guard !placements.isEmpty else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // D10：dot 半径 5pt，字母 10pt bold 白色居中。
        let radius: CGFloat = 5
        let font = UIFont.boldSystemFont(ofSize: 10)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: AppColor.text,
        ]

        for p in placements {
            let color: UIColor
            let letter: String
            switch p.direction {
            case .buy:  color = AppColor.candleUp;   letter = "B"
            case .sell: color = AppColor.candleDown; letter = "S"
            }
            color.setFill()
            let dotRect = CGRect(x: p.center.x - radius, y: p.center.y - radius,
                                 width: radius * 2, height: radius * 2)
            ctx.fillEllipse(in: dotRect)

            let str = letter as NSString
            let size = str.size(withAttributes: textAttrs)
            let drawX = p.center.x - size.width / 2
            let drawY = p.center.y - size.height / 2
            str.draw(at: CGPoint(x: drawX, y: drawY), withAttributes: textAttrs)
        }
    }
}

#endif
```

- [ ] **Step 2: 运行 Catalyst build-for-testing 验证编译**

```
xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/c5-derived-task5 \
           build-for-testing 2>&1 | tail -20
```

期望：`** TEST BUILD SUCCEEDED **`。

- [ ] **Step 3: 跑全量 host swift test 不退步**

```
cd ios/Contracts && swift test 2>&1 | tail -10
```

期望：479 仍全 PASS（Task 5 不加 test）。

- [ ] **Step 4: 提交**

```
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift
git commit -m "C5 Task 5: drawMarkers UIKit shell"
```

---

## Task 6: 哨兵测试（contract guards） + acceptance 脚本 + 验收清单

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift`（追加 3 哨兵）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/MarkersLayoutTests.swift`（追加 3 哨兵）
- Create: `scripts/acceptance/plan_c5_crosshair_markers.sh`
- Create: `docs/acceptance/2026-05-26-pr-c5-crosshair-markers.md`

### 6.1 哨兵测试

- [ ] **Step 1: 追加 CrosshairLayout 哨兵（防止 D7/D8 漂移）**

在 `CrosshairLayoutTests.swift` 追加：

```swift
@Suite("CrosshairLayout 哨兵契约")
struct CrosshairSentinelTests {

    @Test("frame 四角 point —— frame.contains 半开区间 [minX, maxX) × [minY, maxY)（R1 F6 4 角全覆盖）")
    func boundary() {
        let m = makeMapper()
        // CGRect.contains 半开区间：(x>=minX && x<maxX) && (y>=minY && y<maxY)
        #expect(CrosshairLayout.lines(at: CGPoint(x: 0,    y: 0),    mapper: m) != nil)  // 左上角 ∈
        #expect(CrosshairLayout.lines(at: CGPoint(x: 1000, y: 0),    mapper: m) == nil)  // 右上角 ∉（maxX 开）
        #expect(CrosshairLayout.lines(at: CGPoint(x: 0,    y: 600),  mapper: m) == nil)  // 左下角 ∉（maxY 开）
        #expect(CrosshairLayout.lines(at: CGPoint(x: 1000, y: 600),  mapper: m) == nil)  // 右下角 ∉ ←R1 F6 补
    }

    @Test("priceLabel 与 yToPrice 完全一致（哨兵：禁止 priceLabel 内重算 ratio）")
    func priceLabelMirrorsMapper() {
        let m = makeMapper()
        for y: CGFloat in [50, 150, 300, 450, 550] {
            let p = m.yToPrice(y)
            let label = CrosshairLayout.priceLabel(at: CGPoint(x: 100, y: y), mapper: m)
            #expect(label.text == String(format: "%.2f", p))
        }
    }

    @Test("timeLabel locale 中性（en_US_POSIX + UTC+8）：跨设备 locale 结果稳定")
    func timeLabelLocaleNeutral() {
        let m = makeMapper(count: 1)
        let candles = [mc(0, datetime: 1735689600)]  // 2025-01-01 00:00:00 UTC = 08:00 北京
        let label = CrosshairLayout.timeLabel(at: CGPoint(x: 0, y: 300),
                                              mapper: m, candles: candles[0..<1])
        #expect(label?.text == "2025-01-01 08:00")
    }
}
```

- [ ] **Step 2: 追加 MarkersLayout 哨兵**

在 `MarkersLayoutTests.swift` 追加：

```swift
@Suite("MarkersLayout 哨兵契约")
struct MarkersSentinelTests {

    @Test("D2：findCandleIndex 等价 partitioningIndex（哨兵：禁止改换为 linear scan）")
    func equivalentToPartitioning() {
        let candles = [mc(0, endGlobal: 5), mc(1, endGlobal: 10),
                       mc(2, endGlobal: 15), mc(3, endGlobal: 20)]
        let slice = candles[0..<4]
        for gt in [1, 5, 6, 10, 15, 20, 21] {
            let marker = TradeMarker(globalTick: gt, price: 10, direction: .buy)
            let mine = MarkersLayout.findCandleIndex(for: marker, in: slice)
            let ref = slice.partitioningIndex { $0.endGlobalIndex >= gt }
            let expected: Int? = (ref < slice.endIndex) ? ref : nil
            #expect(mine == expected)
        }
    }

    @Test("D10：dot center.y 锚到 candle.close（不是 marker.price）—— 跨周期同步关键")
    func centerYAnchorsCandleClose() {
        let m = makeMapper(count: 2)
        // candle close = 80（priceToY = 600 - 80/100*600 = 120）；marker price = 30
        let candles = [mc(0, endGlobal: 5, close: 80), mc(1, endGlobal: 10, close: 80)]
        let markers = [TradeMarker(globalTick: 5, price: 30, direction: .buy)]
        let placements = MarkersLayout.markerPlacements(
            mapper: m, markers: markers, candles: candles[0..<2])
        #expect(placements.count == 1)
        #expect(placements[0].center.y == 120)  // priceToY(80)，不是 priceToY(30)=420
    }

    @Test("方向透传：buy/sell 不丢失（D10 后续 UIKit 据此选色 + 字母）")
    func directionPassthrough() {
        let m = makeMapper(count: 2)
        let candles = [mc(0, endGlobal: 5), mc(1, endGlobal: 10)]
        let markers = [TradeMarker(globalTick: 5,  price: 10, direction: .buy),
                       TradeMarker(globalTick: 10, price: 10, direction: .sell)]
        let placements = MarkersLayout.markerPlacements(
            mapper: m, markers: markers, candles: candles[0..<2])
        #expect(placements.map(\.direction) == [.buy, .sell])
    }

    @Test("R1 F8：startIndex≠0 slice 时 findCandleIndex 返回的是 slice 母数组 index 而非 0-based")
    func nonZeroSliceStartIndex() {
        // 母数组 6 根；slice 取 [2..<6]（startIndex=2）。
        let arr = [mc(0, endGlobal: 1),  mc(1, endGlobal: 3),
                   mc(2, endGlobal: 5),  mc(3, endGlobal: 10),
                   mc(4, endGlobal: 15), mc(5, endGlobal: 20)]
        let slice = arr[2..<6]  // startIndex=2, endIndex=6
        // globalTick=7：母数组 endGlobal[2,5]=5 不满足，[3,10]=10 满足 → 母数组 index 3。
        let m1 = TradeMarker(globalTick: 7, price: 10, direction: .buy)
        #expect(MarkersLayout.findCandleIndex(for: m1, in: slice) == 3)
        // globalTick=20：[5,20]=20 满足，首个 → 母数组 index 5。
        let m2 = TradeMarker(globalTick: 20, price: 10, direction: .sell)
        #expect(MarkersLayout.findCandleIndex(for: m2, in: slice) == 5)
        // 同样验 markerPlacements.candleIndex 用 slice 母数组 index（不是 0-based）。
        let placements = MarkersLayout.markerPlacements(
            mapper: makeMapper(startIndex: 2, count: 4),
            markers: [m1, m2], candles: slice)
        #expect(placements.count == 2)
        #expect(placements[0].candleIndex == 3)
        #expect(placements[1].candleIndex == 5)
    }
}
```

- [ ] **Step 3: 运行哨兵测试 + 全量 swift test 不退步**

```
swift test --package-path ios/Contracts --filter "CrosshairSentinelTests|MarkersSentinelTests"
cd ios/Contracts && swift test 2>&1 | tail -10
```

期望：哨兵共 **7 新 PASS**（CrosshairSentinelTests 3 = boundary/priceLabelMirrorsMapper/timeLabelLocaleNeutral；MarkersSentinelTests 4 = equivalentToPartitioning/centerYAnchorsCandleClose/directionPassthrough/nonZeroSliceStartIndex）。
全量 = 基线 466 + Task 1(3) + Task 2(4) + Task 3(6) + Task 6(7) = **486 PASS / 0 FAIL**。

### 6.2 acceptance 脚本

- [ ] **Step 4: 新建 `scripts/acceptance/plan_c5_crosshair_markers.sh`**

```bash
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
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/c5-derived-final \
           build-for-testing 2>&1 | tail -5 | tee /tmp/c5-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/c5-build-tail.txt

echo
echo "✅ 所有 9 项 G1-G9 验收通过"
```

设可执行：

```
chmod +x scripts/acceptance/plan_c5_crosshair_markers.sh
```

### 6.3 非程序员验收清单

- [ ] **Step 5: 新建 `docs/acceptance/2026-05-26-pr-c5-crosshair-markers.md`**

```markdown
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
| 3.1 | 跑：`cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests in [0-9]+ suites passed"` | 看到一行 "Test run with 486 tests in 96 suites passed after X seconds."（Swift Testing 输出格式） | 该行出现 ≥ 1 次（数量轻微浮动可接受） |
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
```

- [ ] **Step 6: 跑一次完整验收**

```
bash scripts/acceptance/plan_c5_crosshair_markers.sh
```

期望：9 行 G1-G9 + 末行 `✅ 所有 9 项 G1-G9 验收通过`。

- [ ] **Step 7: 提交**

```
git add ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/MarkersLayoutTests.swift \
        scripts/acceptance/plan_c5_crosshair_markers.sh \
        docs/acceptance/2026-05-26-pr-c5-crosshair-markers.md
git commit -m "C5 Task 6: 哨兵契约测试 + acceptance 脚本 + 非程序员验收清单"
```

---

## Self-Review（plan 作者自审，非 subagent）

### 1. Spec coverage

| Spec 章节 | 覆盖 Task |
|---|---|
| `kline_trainer_modules_v1.4.md` §C5 L1302 `drawCrosshair` 3-arg 签名 | Task 4（保 spec 字面，体内读 self.renderState）|
| `kline_trainer_modules_v1.4.md` §C5 L1303-1304 `drawMarkers` 签名 | Task 5 |
| `kline_trainer_modules_v1.4.md` §C5 L1308-1312 `findCandleIndex` + 二分谓词 | Task 3 |
| `kline_trainer_plan_v1.5.md` §4.3 L753-771 跨周期标记 + 红点B/绿点S + 收盘价 Y | Task 3（findCandleIndex + 锚位）+ Task 5（红/绿点 + B/S）|
| `kline_trainer_modules_v1.4.md` §C5 stub L9 注释 "价格/时间标签框" | Task 1+2（lines + priceLabel + timeLabel）+ Task 4（UIKit）|
| `kline_trainer_plan_v1.5.md` §10 L1245 "十字光标验收" | Task 6.3 |
| Theme F2 token 引用（不硬编码颜色）| Task 4+5（AppColor.text / candleUp / candleDown / background）|

**未覆盖 spec**：无（C5 所有 spec 引用均映射到 Task）。

### 2. Placeholder scan

| 红旗词 | 出现 |
|---|---|
| TBD / TODO | 0 |
| "implement later" / "fill in details" | 0 |
| "add appropriate error handling" / "add validation" | 0 |
| "similar to Task N" | 0（每 Task 自含完整代码）|
| 步骤只描述不出代码 | 无 |

### 3. Type consistency

| 类型/签名 | 一致 |
|---|---|
| `MarkerPlacement(center, direction, candleIndex)` Task 3 定义 → Task 5 消费 | ✓ |
| `CrosshairLines(horizontal, vertical)` Task 1 定义 → Task 4 消费 | ✓ |
| `priceLabel` 返回 `(rect, text)` Task 2 → Task 4 解构 | ✓ |
| `timeLabel` 返回 `(rect, text)?` Task 2 → Task 4 `if let` | ✓ |
| `findCandleIndex` 返回 `Int?` Task 3 → `markerPlacements` 内 `guard let` | ✓ |
| `drawCrosshair` 3 形参（ctx/at/viewport）Task 4 定义 ↔ `KLineView.swift:59` 派发 | ✓（spec 字面，不改派发）|
| 测试数累计 | ✓ Task 1=3 + Task 2=4 + Task 3=6 + Task 6=7 → 共 +20，基线 466 + 20 = **486 total** |

**修正过的不一致**：无（一遍写就一致）。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-26-pr-c5-crosshair-markers.md`. Two execution options:

1. **Subagent-Driven（recommended）** — 用 superpowers:subagent-driven-development，每 Task 一个 fresh subagent + 两段 review，迭代快。
2. **Inline Execution** — 用 superpowers:executing-plans，本会话内批量带 checkpoint。

按用户本次 prompt 显式指定路径 = **subagent-driven-development**，与流程图后续节点（verification-before-completion + requesting-code-review + 第二道 opus 4.7 xhigh 对抗性 review）衔接。
