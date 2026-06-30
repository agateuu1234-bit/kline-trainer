# RFC-C 长按十字光标 overlay + 单指竖滑切周期 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 训练界面长按出黏滞十字光标（整图冻结、点击退出、贯穿整 panel、逐根吸附 + 短震动、悬浮自适应信息栏），并把周期切换从两指竖滑改为单指竖滑——全部视图/手势层，零引擎/契约改动。

**Architecture:** 纯函数（信息栏装配 `CrosshairSidebarContent`、十字光标几何 `CrosshairLayout`、单指手势分类 `GestureClassifiers`）host 全测；UIKit 薄层（`ChartGestureArbiter` 仲裁、`ChartContainerView.Coordinator` 黏滞状态机 + 接线 + haptic、`KLineView+Crosshair` 绘制）靠 Catalyst build + 模拟器/真机人工验收。十字光标是 view-layer 瞬态（`Coordinator.crosshairPoint`，不进 engine）；周期切换复用既有 `engine.switchPeriodCombo`。

**Tech Stack:** Swift 6 / Swift Testing（host）/ UIKit（`#if canImport(UIKit)`）/ CoreGraphics / Mac Catalyst CI build-for-testing。

## Global Constraints

> 以下逐条来自 spec `docs/superpowers/specs/2026-06-30-crosshair-sidebar-period-swipe-design.md`，每个 Task 隐含遵守。

- **零引擎行为 / 零契约改动**：不改 `TrainingEngine` 行为、不改持久化、不 bump `CONTRACT_VERSION`（保持 `"1.7"`，`Models.swift:7`）。周期切换复用既有 `engine.switchPeriodCombo(direction:)`。
- **十字光标是 view-layer 瞬态**：状态只在 `ChartContainerView.Coordinator`（`crosshairPoint` 等），不进 engine、不进 RFC 7 契约。
- **两指捏合缩放保留**；**单指竖滑替换两指切周期**（R-A：不改 `twoFingerStep` 分类器，只在 Coordinator 取消 `onTwoFingerSwipe → switchPeriodCombo` 接线）。
- **drawingMode × crosshairMode 互斥**：drawingMode 时长按不进十字光标。
- **均价 fail-safe**：仅 `amount != nil && volume > 0 && low ≤ amount/volume ≤ high` 才显示均价行。
- **方向色基准 = 前一根收盘（prevClose）**；slice 首根无 prevClose → 涨跌显「—」+ 中性白。
- **host 两测试框架都要核绿**：`swift test` 末尾必看 Swift Testing 汇总 + XCTest「All tests passed」（教训：两框架分开打印）。非整除浮点 host 断言用容差 / mirror mapper。
- **平台门**：UIKit 代码全 `#if canImport(UIKit)`；macOS host 编译为空；Mac Catalyst `build-for-testing` 必须 SUCCEEDED。
- **十字光标线已是细实线**（`KLineView+Crosshair.swift:27` `1/displayScale` 实线），本 RFC 不改线型。

## 文件结构（decomposition）

**新建：**
- `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairSidebarContent.swift` — 纯值类型：信息栏字段行（标签/值/颜色类）+ 均价单位自检 + 涨跌派生 + 颜色归类 + 左右停靠判定 + 日期/时间格式化。平台无关。
- `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairSidebarContentTests.swift` — host 测。

**修改：**
- `Render/CrosshairLayout.swift` — `resolve` 增 `frames: ChartPanelFrames? = nil`；非 nil 时竖线贯穿 `mainChart.minY → macdChart.maxY`、时间标移 `macdChart.maxY`。
- `Tests/.../Render/CrosshairLayoutTests.swift` — 新增 frames-path 断言（既有断言不动，omit frames 保旧行为）。
- `ChartEngine/GestureClassifiers.swift` — `SinglePanStep` 增 `periodSwipe: SwipeDirection?`；`singlePanStep` 在 `.verticalRejected` 终止时按阈值发竖滑切周期。
- `Tests/.../GestureClassifiersTests.swift` — 既有 `SinglePanStep(...)` 构造补 `periodSwipe: nil`；新增竖滑切周期断言。
- `ChartEngine/ChartGestureArbiter.swift` — 加 `crosshairMode` + `onCrosshairMove`/`onCrosshairExit`/`onVerticalSwipe`；crosshairMode 抑制 pan/pinch/两指、单指路由光标移动、tap 退出；普通态单指竖滑发 `onVerticalSwipe`。
- `Render/ChartContainerView.swift`（`Coordinator`）— 黏滞状态机（enter/move/park/exit）+ haptic 去重 + 接线（onCrosshairMove/Exit/VerticalSwipe；删 onTwoFingerSwipe）。
- `Render/KLineView+Crosshair.swift` — `resolve` 传 `frames`；绘制悬浮信息卡（颜色）。
- `docs/superpowers/acceptance/2026-06-30-crosshair-sidebar-period-swipe.md` — 验收清单（新建）。

**Task 依赖序**：1（信息栏纯层）→ 2（光标几何纯层）→ 3（手势分类纯层）→ 4（arbiter）→ 5（Coordinator 接线）→ 6（绘制）→ 7（验收）。1/2/3 互不依赖可并行；4 依赖 3；5 依赖 4+1+2；6 依赖 1+2+5。

---

### Task 1: CrosshairSidebarContent 纯值类型（信息栏装配）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairSidebarContent.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairSidebarContentTests.swift`

**Interfaces:**
- Consumes: `KLineCandle`（`Models.swift`，字段 `open/high/low/close: Double`、`volume: Int64`、`amount: Double?`、`datetime: Int64`、`period: Period`）；`Period`（`.m3/.m15/.m60/.daily/.weekly/.monthly`）；`CGFloat`。
- Produces:
  - `enum CrosshairSidebarContent.DockSide { case left, right }`
  - `enum CrosshairSidebarContent.ValueColor { case up, down, flat, neutral }`（up=红 / down=绿 / flat=白(平) / neutral=黄(非方向字段)）
  - `struct CrosshairSidebarContent.Row { let label: String; let value: String; let color: ValueColor }`
  - `struct CrosshairSidebarContent { let cursorPriceText: String; let cursorPriceColor: ValueColor; let dateText: String; let timeText: String?; let rows: [Row]; let dock: DockSide }`
  - `static func make(candle: KLineCandle, previousClose: Double?, cursorPrice: Double, snappedX: CGFloat, mainChartMidX: CGFloat) -> CrosshairSidebarContent`

- [ ] **Step 1: 写失败测试**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairSidebarContentTests.swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func candle(period: Period = .m60,
                    datetime: Int64 = 1_711_605_600,   // 2024-03-28 14:00 UTC+8
                    open: Double = 1672.40, high: Double = 1689.00,
                    low: Double = 1668.20, close: Double = 1683.50,
                    volume: Int64 = 12_840, amount: Double? = 1683.0 * 12_840) -> KLineCandle {
    KLineCandle(period: period, datetime: datetime,
                open: open, high: high, low: low, close: close,
                volume: volume, amount: amount, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: 0, endGlobalIndex: 0)
}

@Suite("CrosshairSidebarContent 装配")
struct CrosshairSidebarContentTests {

    // 停靠：snappedX > 主图中点 → 靠左；否则 → 靠右（含恰中点 = 右）
    @Test("光标偏右(snappedX > midX) → dock = left")
    func dockLeftWhenRight() {
        let c = CrosshairSidebarContent.make(candle: candle(), previousClose: 1672.40,
                                             cursorPrice: 1681.20, snappedX: 700, mainChartMidX: 500)
        #expect(c.dock == .left)
    }

    @Test("光标偏左/恰中点(snappedX <= midX) → dock = right")
    func dockRightWhenLeftOrCenter() {
        let left = CrosshairSidebarContent.make(candle: candle(), previousClose: 1672.40,
                                                cursorPrice: 1660, snappedX: 300, mainChartMidX: 500)
        let center = CrosshairSidebarContent.make(candle: candle(), previousClose: 1672.40,
                                                  cursorPrice: 1660, snappedX: 500, mainChartMidX: 500)
        #expect(left.dock == .right)
        #expect(center.dock == .right)   // 恰中点归右（确定性）
    }

    // 光标价颜色：vs prevClose（> 红、< 绿、== 白）
    @Test("光标价 vs 前收：高=up、低=down、平=flat")
    func cursorPriceColor() {
        let up = CrosshairSidebarContent.make(candle: candle(), previousClose: 1680,
                                              cursorPrice: 1690, snappedX: 100, mainChartMidX: 500)
        let dn = CrosshairSidebarContent.make(candle: candle(), previousClose: 1680,
                                              cursorPrice: 1670, snappedX: 100, mainChartMidX: 500)
        let fl = CrosshairSidebarContent.make(candle: candle(), previousClose: 1680,
                                              cursorPrice: 1680, snappedX: 100, mainChartMidX: 500)
        #expect(up.cursorPriceColor == .up)
        #expect(dn.cursorPriceColor == .down)
        #expect(fl.cursorPriceColor == .flat)
    }

    // 收盘价颜色 vs prevClose；开/高/低 = neutral(黄)
    @Test("收 vs 前收上色；开/高/低 = neutral")
    func ohlcColors() {
        let c = CrosshairSidebarContent.make(candle: candle(close: 1683.50), previousClose: 1672.40,
                                             cursorPrice: 1683.5, snappedX: 100, mainChartMidX: 500)
        let close = c.rows.first { $0.label == "收" }
        let open = c.rows.first { $0.label == "开" }
        #expect(close?.color == .up)        // 1683.5 > 1672.4
        #expect(open?.color == .neutral)    // 开 = 黄
    }

    // 涨跌 / 涨跌幅 派生 + 颜色
    @Test("涨跌额/涨跌幅 = 收 − 前收 / ÷ 前收，红涨")
    func changeDerivation() {
        let c = CrosshairSidebarContent.make(candle: candle(close: 1683.50), previousClose: 1672.40,
                                             cursorPrice: 1683.5, snappedX: 100, mainChartMidX: 500)
        let chg = c.rows.first { $0.label == "涨跌" }
        let pct = c.rows.first { $0.label == "涨跌幅" }
        #expect(chg?.value == "+11.10")
        #expect(chg?.color == .up)
        #expect(pct?.value == "+0.66%")     // 11.10/1672.40 = 0.6637% → +0.66%
        #expect(pct?.color == .up)
    }

    // 首根无 prevClose → 涨跌「—」+ flat
    @Test("首根无 prevClose → 涨跌『—』中性白")
    func firstCandleNoPrev() {
        let c = CrosshairSidebarContent.make(candle: candle(), previousClose: nil,
                                             cursorPrice: 1683.5, snappedX: 100, mainChartMidX: 500)
        let chg = c.rows.first { $0.label == "涨跌" }
        #expect(chg?.value == "—")
        #expect(chg?.color == .flat)
        #expect(c.cursorPriceColor == .flat)   // 无基准 → 光标价也中性
    }

    // 均价单位自检：落 [低,高] → 显示；越界 → 隐藏
    @Test("均价 ∈ [低,高] 显示")
    func avgPriceInRange() {
        // amount = 1679.8 * 12840 → 均价 = 1679.8 ∈ [1668.2,1689]
        let c = CrosshairSidebarContent.make(candle: candle(amount: 1679.8 * 12_840),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        let avg = c.rows.first { $0.label == "均价" }
        #expect(avg?.value == "1679.80")
        #expect(avg?.color == .neutral)
    }

    @Test("均价越界([低,高]外, 如手/元差100倍) → 隐藏该行")
    func avgPriceOutOfRangeHidden() {
        // volume 当「手」时 amount/volume = 100× 价 → 越界
        let c = CrosshairSidebarContent.make(candle: candle(volume: 128, amount: 1679.8 * 12_840),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        #expect(!c.rows.contains { $0.label == "均价" })
    }

    @Test("amount==nil → 均价 + 成交额两行都隐藏")
    func amountNilHidesAvgAndTurnover() {
        let c = CrosshairSidebarContent.make(candle: candle(amount: nil),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        #expect(!c.rows.contains { $0.label == "均价" })
        #expect(!c.rows.contains { $0.label == "成交额" })
    }

    // 日期/时间：日内显时分；日/周/月只显日期
    @Test("日内周期(m60) → date + time")
    func intradayDateTime() {
        let c = CrosshairSidebarContent.make(candle: candle(period: .m60),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        #expect(c.dateText == "2024-03-28")
        #expect(c.timeText == "14:00")
    }

    @Test("日线周期(daily) → 只 date，time == nil")
    func dailyDateOnly() {
        let c = CrosshairSidebarContent.make(candle: candle(period: .daily),
                                             previousClose: 1672.40, cursorPrice: 1683.5,
                                             snappedX: 100, mainChartMidX: 500)
        #expect(c.dateText == "2024-03-28")
        #expect(c.timeText == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter CrosshairSidebarContentTests`
Expected: 编译失败 `cannot find 'CrosshairSidebarContent' in scope`。

- [ ] **Step 3: 写最小实现**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairSidebarContent.swift
// Kline Trainer Swift Contracts — RFC-C 十字光标悬浮信息栏装配（平台无关纯值类型）
// Spec: docs/superpowers/specs/2026-06-30-crosshair-sidebar-period-swipe-design.md §4.5
//
// 不 import UIKit：字段/格式化/派生/颜色归类/停靠判定全 host swift test 真断言。
// 颜色基准 = 前一根收盘(prevClose)；均价单位自检 = 均价 ∈ [低,高] 才显（防 手/元 100× 假值）。

import Foundation
import CoreGraphics

public struct CrosshairSidebarContent: Equatable, Sendable {

    /// 悬浮栏停靠侧（光标偏右靠左、偏左/居中靠右，防手指遮挡）。
    public enum DockSide: Equatable, Sendable { case left, right }

    /// 值颜色：up=红(涨) / down=绿(跌) / flat=白(平/无基准) / neutral=黄(非方向字段)。
    public enum ValueColor: Equatable, Sendable { case up, down, flat, neutral }

    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String
        public let color: ValueColor
        public init(label: String, value: String, color: ValueColor) {
            self.label = label; self.value = value; self.color = color
        }
    }

    public let cursorPriceText: String     // 栏顶居中实时价（无标签）
    public let cursorPriceColor: ValueColor
    public let dateText: String            // 日期(左)
    public let timeText: String?           // 时间(右)，日/周/月为 nil
    public let rows: [Row]                  // 开/高/低/收/涨跌/涨跌幅/[均价]/成交量/[成交额]
    public let dock: DockSide

    // MARK: - 装配

    public static func make(candle: KLineCandle, previousClose: Double?, cursorPrice: Double,
                            snappedX: CGFloat, mainChartMidX: CGFloat) -> CrosshairSidebarContent {
        let dock: DockSide = snappedX > mainChartMidX ? .left : .right

        let cursorColor = directionColor(value: cursorPrice, base: previousClose)
        let cursorText = price2(cursorPrice)

        let (dateText, timeText) = formatDateTime(datetime: candle.datetime, period: candle.period)

        var rows: [Row] = [
            Row(label: "开", value: price2(candle.open), color: .neutral),
            Row(label: "高", value: price2(candle.high), color: .neutral),
            Row(label: "低", value: price2(candle.low), color: .neutral),
            Row(label: "收", value: price2(candle.close),
                color: directionColor(value: candle.close, base: previousClose)),
        ]

        // 涨跌 / 涨跌幅（vs 前收；首根无基准 → 「—」中性白）
        if let prev = previousClose, prev != 0 {
            let diff = candle.close - prev
            let pct = diff / prev * 100
            let color: ValueColor = diff > 0 ? .up : (diff < 0 ? .down : .flat)
            rows.append(Row(label: "涨跌", value: signed2(diff), color: color))
            rows.append(Row(label: "涨跌幅", value: signedPct2(pct), color: color))
        } else {
            rows.append(Row(label: "涨跌", value: "—", color: .flat))
            rows.append(Row(label: "涨跌幅", value: "—", color: .flat))
        }

        // 均价（成交额÷成交量）+ 单位自检（∈ [低,高] 才显）
        if let amount = candle.amount, candle.volume > 0 {
            let avg = amount / Double(candle.volume)
            if avg >= candle.low && avg <= candle.high {
                rows.append(Row(label: "均价", value: price2(avg), color: .neutral))
            }
        }

        // 成交量（千分位 + 手）
        rows.append(Row(label: "成交量", value: groupedInt(candle.volume) + " 手", color: .neutral))

        // 成交额（amount 非 nil 才显；亿/万 自适应）
        if let amount = candle.amount {
            rows.append(Row(label: "成交额", value: formatAmount(amount), color: .neutral))
        }

        return CrosshairSidebarContent(
            cursorPriceText: cursorText, cursorPriceColor: cursorColor,
            dateText: dateText, timeText: timeText, rows: rows, dock: dock)
    }

    // MARK: - 纯辅助（host 测）

    /// 方向色：value vs base（前收）；> 红、< 绿、== 白；base==nil → 白(无基准)。
    static func directionColor(value: Double, base: Double?) -> ValueColor {
        guard let base else { return .flat }
        if value > base { return .up }
        if value < base { return .down }
        return .flat
    }

    static func price2(_ v: Double) -> String { String(format: "%.2f", v) }
    static func signed2(_ v: Double) -> String { (v >= 0 ? "+" : "") + String(format: "%.2f", v) }
    static func signedPct2(_ v: Double) -> String { (v >= 0 ? "+" : "") + String(format: "%.2f", v) + "%" }

    /// 千分位整数（locale 无关手工分组，正负皆可）。左→右扫描，避开 ReversedCollection 类型坑（codex M2）。
    static func groupedInt(_ n: Int64) -> String {
        let neg = n < 0
        let s = String(n.magnitude)
        let count = s.count
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (count - i) % 3 == 0 { out.append(",") }   // 每满 3 位前插逗号
            out.append(ch)
        }
        return (neg ? "-" : "") + out
    }

    /// 成交额：≥1亿 显「X.XX 亿」、≥1万 显「X.XX 万」、否则千分位元。
    static func formatAmount(_ a: Double) -> String {
        if a >= 1e8 { return String(format: "%.2f 亿", a / 1e8) }
        if a >= 1e4 { return String(format: "%.2f 万", a / 1e4) }
        return groupedInt(Int64(a)) + " 元"
    }

    static func isIntraday(_ p: Period) -> Bool {
        switch p { case .m3, .m15, .m60: return true; default: return false }
    }

    /// 日期/时间格式化（UTC+8 / en_US_POSIX）。日内 → (yyyy-MM-dd, HH:mm)；日/周/月 → (yyyy-MM-dd, nil)。
    static func formatDateTime(datetime: Int64, period: Period) -> (String, String?) {
        let date = Date(timeIntervalSince1970: TimeInterval(datetime))
        let df = DateFormatter()
        df.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let dateText = df.string(from: date)
        guard isIntraday(period) else { return (dateText, nil) }
        df.dateFormat = "HH:mm"
        return (dateText, df.string(from: date))
    }

    public init(cursorPriceText: String, cursorPriceColor: ValueColor,
                dateText: String, timeText: String?, rows: [Row], dock: DockSide) {
        self.cursorPriceText = cursorPriceText
        self.cursorPriceColor = cursorPriceColor
        self.dateText = dateText
        self.timeText = timeText
        self.rows = rows
        self.dock = dock
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter CrosshairSidebarContentTests`
Expected: 全 PASS（11 测试）。若 `涨跌幅` 容差需要：`11.10/1672.40*100 = 0.6637...` → `%.2f` = `0.66` → `+0.66%` 字面相等，无浮点容差问题。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairSidebarContent.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairSidebarContentTests.swift
git commit -m "feat(rfc-c): CrosshairSidebarContent 信息栏纯装配 + 均价自检 + 颜色/停靠"
```

---

### Task 2: CrosshairLayout 贯穿整 panel + 时间标移最底（frames 可选参数）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift:63-102`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift`

**Interfaces:**
- Consumes: `ChartPanelFrames`（`Geometry.swift`：`mainChart/volumeChart/macdChart: CGRect`）；`CoordinateMapper`；`ArraySlice<KLineCandle>`。
- Produces: `CrosshairLayout.resolve(at:mapper:candles:frames:)` —— `frames: ChartPanelFrames? = nil`。`nil` → 现状（竖线/时签限 `mainChartFrame`，既有断言不变）；非 `nil` → 竖线 `mainChart.minY → macdChart.maxY`、时签居中 `snappedX` 底贴 `macdChart.maxY`。横线/价签不变（仍主图区 + 自由 Y）。

- [ ] **Step 1: 写失败测试（frames 路径）**

```swift
// 追加到 CrosshairLayoutTests.swift 末尾（既有 import/helpers 复用）

private func makeFrames(mainTop: CGFloat = 0, mainH: CGFloat = 360,
                       volH: CGFloat = 90, macdH: CGFloat = 150,
                       width: CGFloat = 1000) -> ChartPanelFrames {
    let main = CGRect(x: 0, y: mainTop, width: width, height: mainH)
    let vol = CGRect(x: 0, y: mainTop + mainH, width: width, height: volH)
    let macd = CGRect(x: 0, y: mainTop + mainH + volH, width: width, height: macdH)
    return ChartPanelFrames(mainChart: main, volumeChart: vol, macdChart: macd)
}

@Suite("CrosshairLayout frames 贯穿整 panel")
struct CrosshairWholePanelTests {

    // mapper 的 mainChartFrame 高 360（= main 区）；frames 的 panel 底 = macdChart.maxY = 600
    @Test("传 frames → 竖线从 mainChart.minY 到 macdChart.maxY（贯穿三子图）")
    func verticalSpansWholePanel() {
        let m = makeMapper(visibleCount: 10, frameHeight: 360)   // mainChartFrame.height = 360
        let c = makeCandles(count: 10)[0..<10]
        let frames = makeFrames()                                 // macdChart.maxY = 600
        let r = CrosshairLayout.resolve(at: CGPoint(x: 35, y: 100), mapper: m, candles: c, frames: frames)
        #expect(r != nil)
        #expect(r!.lines.vertical.from.y == 0)                    // mainChart.minY
        #expect(r!.lines.vertical.to.y == 600)                    // macdChart.maxY（非 360）
    }

    @Test("传 frames → 时签底贴 macdChart.maxY（非 mainChartFrame.maxY）")
    func timeLabelAtPanelBottom() {
        let m = makeMapper(visibleCount: 10, frameHeight: 360)
        let c = makeCandles(count: 10)[0..<10]
        let frames = makeFrames()
        let r = CrosshairLayout.resolve(at: CGPoint(x: 35, y: 100), mapper: m, candles: c, frames: frames)
        #expect(r!.timeLabel.rect.maxY == 600)                    // 底贴 macdChart.maxY
    }

    @Test("不传 frames（nil）→ 保持现状（竖线/时签限 mainChartFrame）")
    func nilFramesKeepsLegacy() {
        let m = makeMapper(visibleCount: 10, frameHeight: 360)
        let c = makeCandles(count: 10)[0..<10]
        let r = CrosshairLayout.resolve(at: CGPoint(x: 35, y: 100), mapper: m, candles: c)
        #expect(r!.lines.vertical.to.y == 360)                    // mainChartFrame.maxY（旧行为）
        #expect(r!.timeLabel.rect.maxY == 360)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter CrosshairWholePanelTests`
Expected: 编译失败 `extra argument 'frames' in call`。

- [ ] **Step 3: 改实现（resolve 增 frames 参数）**

把 `CrosshairLayout.swift` 的 `resolve` 签名与竖线/时签构造改为：

```swift
    /// 单一入口（spec D6 + RFC-C frames 扩展）。frames 非 nil → 竖线贯穿整 panel + 时签底贴 macdChart.maxY。
    static func resolve(at point: CGPoint?, mapper: CoordinateMapper,
                        candles: ArraySlice<KLineCandle>,
                        frames: ChartPanelFrames? = nil) -> CrosshairResolved? {
        guard let point else { return nil }
        let frame = mapper.viewport.mainChartFrame
        guard frame.contains(point) else { return nil }     // D8 frame 守卫（触发区仍限主图）
        guard !candles.isEmpty else { return nil }          // D3 空切片守卫

        let snappedIndex = snappedCandleIndex(at: point.x, mapper: mapper, candles: candles)
        let snappedX = mapper.indexToX(snappedIndex)

        // 竖线纵向延展：frames 非 nil → 贯穿 mainChart.minY..macdChart.maxY；nil → 限 mainChartFrame（旧行为）。
        let verticalTop = frames?.mainChart.minY ?? frame.minY
        let verticalBottom = frames?.macdChart.maxY ?? frame.maxY

        let lines = CrosshairLines(
            horizontal: .init(from: CGPoint(x: frame.minX, y: point.y),
                              to:   CGPoint(x: frame.maxX, y: point.y)),
            vertical:   .init(from: CGPoint(x: snappedX, y: verticalTop),
                              to:   CGPoint(x: snappedX, y: verticalBottom)))

        let price = mapper.yToPrice(point.y)
        let priceWidth: CGFloat = 60, priceHeight: CGFloat = 18
        let priceRect = CGRect(x: frame.maxX - priceWidth, y: point.y - priceHeight / 2,
                               width: priceWidth, height: priceHeight)
        let priceLabel = CrosshairResolved.Label(rect: priceRect,
                                                 text: String(format: "%.2f", price))

        let datetime = candles[snappedIndex].datetime
        let date = Date(timeIntervalSince1970: TimeInterval(datetime))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        // 时签底：frames 非 nil → macdChart.maxY（整图最底）；nil → mainChartFrame.maxY（旧）。
        let timeBottom = frames?.macdChart.maxY ?? frame.maxY
        let timeWidth: CGFloat = 120, timeHeight: CGFloat = 18
        let timeRect = CGRect(x: snappedX - timeWidth / 2, y: timeBottom - timeHeight,
                              width: timeWidth, height: timeHeight)
        let timeLabel = CrosshairResolved.Label(rect: timeRect, text: formatter.string(from: date))

        return CrosshairResolved(lines: lines, priceLabel: priceLabel,
                                 timeLabel: timeLabel, snappedIndex: snappedIndex)
    }
```

> 注：`CrosshairLines` 仍标注「端点已对齐 mainChartFrame 四边」的注释（L14）已不精确——更新该行注释为「竖线端点 = 整 panel（frames 非 nil）或 mainChartFrame」。

- [ ] **Step 4: 跑全部 CrosshairLayout 测试**

Run: `cd ios/Contracts && swift test --filter CrosshairLayout && swift test --filter CrosshairWholePanel && swift test --filter SnappedIndex`
Expected: 既有断言（omit frames）全绿 + 新 frames-path 3 测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift
git commit -m "feat(rfc-c): CrosshairLayout 竖线贯穿整 panel + 时签移 macdChart.maxY（frames 可选）"
```

---

### Task 3: 单指竖滑切周期（GestureClassifiers.singlePanStep）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift:86-165`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift`

**Interfaces:**
- Consumes: 既有 `SinglePanLifecycle`/`classifySingleFingerPan`/`SwipeDirection`。
- Produces: `SinglePanStep` 增字段 `periodSwipe: SwipeDirection?`（终止时为竖滑切周期方向，否则 nil）。`singlePanStep` 在 `lifecycle == .verticalRejected` 且 `phase == .ended` 且 `abs(cumulative.y) >= verticalSwitchThreshold(默认 40)` 时填 `periodSwipe = cumulative.y < 0 ? .up : .down`。`.cancelled` 不发。

- [ ] **Step 1: 写失败测试**

```swift
// 追加到 GestureClassifiersTests.swift（@testable import 已有；SinglePanStep/singlePanStep internal 可见）

@Suite("单指竖滑切周期")
struct SingleFingerVerticalSwipeTests {

    // 竖直锁定（dy > dx*1.5 且 dy>=8）→ verticalRejected，过程不发 pan
    @Test("竖直拖动过程不发 onPan emissions")
    func verticalNoPanDuringChange() {
        let began = singlePanStep(phase: .began, cumulative: CGPoint(x: 0, y: 30), velocityX: 0,
                                  lifecycle: .idle, lastTranslationX: 0)
        #expect(began.lifecycle == .verticalRejected)
        #expect(began.emissions.isEmpty)
        #expect(began.periodSwipe == nil)
    }

    // 松手净竖移 >= 阈值(40) → 发竖滑切周期；上滑(y<0)=up、下滑(y>0)=down
    @Test("松手净竖移 >= 40 → 切周期；上滑 up / 下滑 down")
    func endedAboveThresholdSwitches() {
        // 上滑：y = -50
        let up = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: -50), velocityX: 0,
                               lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(up.periodSwipe == .up)
        #expect(up.emissions.isEmpty)            // 竖滑不发 pan
        #expect(up.lifecycle == .idle)
        // 下滑：y = +50
        let dn = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: 50), velocityX: 0,
                               lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(dn.periodSwipe == .down)
    }

    // 松手净竖移 < 阈值 → 不切（防误触）
    @Test("松手净竖移 < 40 → 不切周期")
    func endedBelowThresholdNoSwitch() {
        let r = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: -30), velocityX: 0,
                              lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(r.periodSwipe == nil)
    }

    // .cancelled（被两指接管等）→ 不切
    @Test(".cancelled 不切周期")
    func cancelledNoSwitch() {
        let r = singlePanStep(phase: .cancelled, cumulative: CGPoint(x: 0, y: -80), velocityX: 0,
                              lifecycle: .verticalRejected, lastTranslationX: 0)
        #expect(r.periodSwipe == nil)
    }

    // 水平 pan 不受影响：仍发 onPan、periodSwipe == nil
    @Test("水平拖动仍发 pan、不切周期")
    func horizontalUnaffected() {
        let began = singlePanStep(phase: .began, cumulative: CGPoint(x: 30, y: 0), velocityX: 5,
                                  lifecycle: .idle, lastTranslationX: 0)
        #expect(began.lifecycle == .horizontalActive)
        #expect(began.periodSwipe == nil)
        #expect(began.emissions.contains { $0.phase == .began })
    }

    // drawingTakesOver：竖直被绘线吃掉，不切周期
    @Test("drawing 模式竖直 → 不切周期")
    func drawingModeNoSwitch() {
        let r = singlePanStep(phase: .ended, cumulative: CGPoint(x: 0, y: -80), velocityX: 0,
                              lifecycle: .verticalRejected, lastTranslationX: 0, drawingTakesOver: true)
        #expect(r.periodSwipe == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter SingleFingerVerticalSwipeTests`
Expected: 编译失败 `value of type 'SinglePanStep' has no member 'periodSwipe'`。

- [ ] **Step 3: 改实现**

3a. `SinglePanStep` 加字段（`GestureClassifiers.swift:87-91`）：

```swift
struct SinglePanStep: Equatable, Sendable {
    let emissions: [SinglePanEmission]   // [] = 本步不触发任何 onPan 回调
    let lifecycle: SinglePanLifecycle    // 本手势更新后的生命周期态
    let lastTranslationX: CGFloat        // 下一步增量基线
    let periodSwipe: SwipeDirection?     // 非 nil = 单指竖滑切周期（仅 .ended 终止且净竖移达阈值）
}
```

3b. 加阈值常量（文件顶部 `import` 后）：

```swift
/// 单指竖滑切周期的最小净竖移（pt）。低于此不切（防误触）。真机手感可调（runbook 注明）。
let verticalSwitchThreshold: CGFloat = 40
```

3c. **每处 `SinglePanStep(...)` 构造补 `periodSwipe: nil`**——`singlePanStep`（含 `classifyFromIdle` 内 3 处 + `.changed` 各分支 + `drawingTakesOver` 2 处 + `.ended/.cancelled` 非 vertical 分支）与 `singlePanSupersede`（2 处）。然后在 `.ended/.cancelled` 的**非 horizontalActive** 返回处，按 verticalRejected + ended + 阈值填 periodSwipe：

把 `singlePanStep` 的 `.ended, .cancelled` 段（`GestureClassifiers.swift:152-164`）改为：

```swift
    case .ended, .cancelled:
        if lifecycle == .horizontalActive {
            let residual = panIncrement(current: cumulative.x, last: lastTranslationX)
            let v: CGFloat = phase == .ended ? velocityX : 0
            var emissions: [SinglePanEmission] = []
            if residual != 0 {
                emissions.append(SinglePanEmission(deltaX: residual, velocityX: v, phase: .changed))
            }
            emissions.append(SinglePanEmission(deltaX: 0, velocityX: v, phase: phase))
            return SinglePanStep(emissions: emissions, lifecycle: .idle,
                                 lastTranslationX: cumulative.x, periodSwipe: nil)
        }
        // 竖直已锁定 + 正常结束 + 净竖移达阈值 → 单指竖滑切周期（一甩一档；.cancelled 不发）
        if lifecycle == .verticalRejected, phase == .ended, abs(cumulative.y) >= verticalSwitchThreshold {
            let dir: SwipeDirection = cumulative.y < 0 ? .up : .down
            return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: lastTranslationX,
                                 periodSwipe: dir)
        }
        return SinglePanStep(emissions: [], lifecycle: .idle,
                             lastTranslationX: lastTranslationX, periodSwipe: nil)
```

> ⚠️ 实现者：`drawingTakesOver` 段（L109-118）的两个 `SinglePanStep(...)` 也要补 `periodSwipe: nil`——drawing 截获竖直即丢，不切（测试 `drawingModeNoSwitch` 守此）。`classifyFromIdle`（L121-131）3 处、`.changed`（L136-151）3 处同补 `periodSwipe: nil`。`singlePanSupersede`（L170-179）2 处同补。

- [ ] **Step 4: 跑测试确认通过 + 既有手势测试回归**

Run: `cd ios/Contracts && swift test --filter SingleFingerVerticalSwipeTests && swift test --filter GestureClassifiers && swift test --filter PublicGestureSurface`
Expected: 新 6 测试 PASS；既有 singlePanStep/twoFingerStep 断言全绿（补 periodSwipe: nil 不改行为）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift
git commit -m "feat(rfc-c): singlePanStep 单指竖滑切周期（一甩一档 + 阈值防误触）"
```

---

### Task 4: ChartGestureArbiter crosshairMode + 新回调

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift`

**Interfaces:**
- Consumes: Task 3 的 `SinglePanStep.periodSwipe`。
- Produces（arbiter 新公共面，供 Task 5 Coordinator 接线）：
  - `public var crosshairMode: Bool`（Coordinator 进入/退出十字光标时设）
  - `public var onCrosshairMove: ((CGPoint) -> Void)?`（crosshairMode 下单指 began/changed 的绝对触点）
  - `public var onCrosshairExit: (() -> Void)?`（crosshairMode 下单指点击）
  - `public var onVerticalSwipe: ((SwipeDirection) -> Void)?`（普通态单指竖滑一甩）

> UIKit-only：无 host 单元（识别器交互）。验证 = Catalyst build SUCCEEDED + Task 3 纯测试 + Task 7 人工验收。

- [ ] **Step 1: 加标志位与回调**（`ChartGestureArbiter.swift:30-35` 附近，`drawingMode` 旁）

```swift
    /// 两指上下滑动切周期：松手离散触发一次。（RFC-C：Coordinator 已不接此回调，two-finger 不再切周期）
    public var onTwoFingerSwipe: ((SwipeDirection) -> Void)?

    /// RFC-C 单指竖滑切周期（普通态，一甩一档）。
    public var onVerticalSwipe: ((SwipeDirection) -> Void)?
    /// RFC-C 十字光标模式：crosshairMode 下单指拖动移动光标的绝对触点。
    public var onCrosshairMove: ((CGPoint) -> Void)?
    /// RFC-C 十字光标模式下单指点击 → 退出。
    public var onCrosshairExit: (() -> Void)?

    /// Drawing 模式开关。true 时单指 Pan 被绘线截获、单指点击 fire onTap。
    public var drawingMode: Bool = false
    /// RFC-C 十字光标模式开关（Coordinator 长按进入时设 true、点击退出时设 false）。
    /// true 时：单指拖动 → onCrosshairMove（不平移）；两指/捏合抑制（整图冻结）；单指点击 → onCrosshairExit。
    public var crosshairMode: Bool = false
```

- [ ] **Step 2: 单指 handler 路由（crosshairMode 移光标 / 普通态竖滑切周期）**

把 `handleSinglePan`（`ChartGestureArbiter.swift:138-151`）改为：

```swift
    @objc private func handleSinglePan(_ g: UIPanGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        // RFC-C：crosshairMode 下单指 = 移动光标（整图冻结，不发 onPan/切周期）
        if crosshairMode {
            if ph == .began || ph == .changed { onCrosshairMove?(g.location(in: g.view)) }
            return
        }
        let step = singlePanStep(phase: ph,
                                 cumulative: g.translation(in: g.view),
                                 velocityX: g.velocity(in: g.view).x,
                                 lifecycle: singlePanLifecycle,
                                 lastTranslationX: lastSinglePanTranslationX,
                                 drawingTakesOver: panPolicyInDrawingMode(drawingMode: drawingMode) == .drawingTakesOver)
        singlePanLifecycle = step.lifecycle
        lastSinglePanTranslationX = step.lastTranslationX
        for e in step.emissions { onPan?(e.deltaX, e.velocityX, e.phase) }
        if let dir = step.periodSwipe { onVerticalSwipe?(dir) }   // RFC-C 单指竖滑切周期
    }
```

- [ ] **Step 3: 两指/捏合在 crosshairMode 抑制 + tap 退出**

3a. `handleTwoFingerPan`（L154）与 `handlePinch`（L163）首行加 crosshairMode 早返：

```swift
    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        if crosshairMode { return }                                   // RFC-C：光标模式整图冻结
        guard let ph = phase(from: g.state) else { return }
        if ph == .began { supersedeSinglePanForMultitouch(in: g.view) }
        ...
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if crosshairMode { return }                                   // RFC-C：光标模式不缩放
        guard let ph = phase(from: g.state) else { return }
        ...
    }
```

3b. `handleTap`（L185-188）改为 crosshairMode 优先退出：

```swift
    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        if crosshairMode { onCrosshairExit?(); return }   // RFC-C：光标模式点击退出
        guard drawingMode else { return }                  // 仅 Drawing 模式确定锚点
        onTap?(g.location(in: g.view))
    }
```

- [ ] **Step 4: Catalyst build 验证编译**

Run: `xcodebuild build-for-testing -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/rfcc-ddt 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`（arbiter 新面编译通过；回调未接=nil，行为未变）。
> 若本地无 Catalyst 工具链：`cd ios/Contracts && swift build` 至少须过（UIKit 段 macOS 编译为空，但 SwipeDirection/类型引用须解析）。CI macos-15 跑 Catalyst。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift
git commit -m "feat(rfc-c): arbiter crosshairMode（冻结+移光标+点击退出）+ 单指竖滑 onVerticalSwipe"
```

---

### Task 5: Coordinator 黏滞状态机 + 接线 + haptic

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`

**Interfaces:**
- Consumes: Task 4 arbiter 回调；既有 `setCrosshair`、`CrosshairLayout.snappedCandleIndex`、`CoordinateMapper`、`periodDirection(for:)`、`engine.switchPeriodCombo`。
- Produces: 黏滞十字光标（长按进入 + 冻结 + 松手保留 + 点击退出）；单指竖滑切周期接线；逐根吸附短 haptic。

> UIKit-only：验证 = Catalyst build + Task 7 人工/真机验收（haptic）。

- [ ] **Step 1: 加状态字段**（`Coordinator` 内，`crosshairPoint` 旁，L54 附近）

```swift
        /// 视图层瞬态十字光标（D3，不进 engine）。RFC-C：黏滞——长按进入、点击才清。
        public private(set) var crosshairPoint: CGPoint?
        /// RFC-C 黏滞模式是否激活（= crosshairPoint 已置且未点击退出）。
        private var crosshairActive = false
        /// RFC-C 吸附 haptic 去重：上次吸附到的 candle index。
        private var lastSnappedIndex: Int?
        /// RFC-C 吸附震动发生器（UIKit）。
        private let snapHaptic = UIImpactFeedbackGenerator(style: .light)
```

- [ ] **Step 2: 改 onLongPress 为黏滞 + 删 onTwoFingerSwipe + 接 onCrosshairMove/Exit/VerticalSwipe**

把 `attach(to:)` 内回调块（`ChartContainerView.swift:98-115`）改为：

```swift
            // RFC-C：two-finger 不再切周期（改单指竖滑）——不接 onTwoFingerSwipe。
            arbiter.onVerticalSwipe = { [weak self] swipe in
                guard let self, let engine = self.engine else { return }
                engine.switchPeriodCombo(direction: periodDirection(for: swipe))
            }
            arbiter.onLongPress = { [weak self] location, phase in
                guard let self else { return }
                switch phase {
                case .began:
                    guard let engine = self.engine, !self.isDrawing(engine: engine, panel: self.panel) else { return }
                    self.enterCrosshair(at: location)            // drawing 优先：drawing 时不进光标
                case .changed:
                    if self.crosshairActive { self.moveCrosshair(to: location) }
                case .ended, .cancelled:
                    break                                         // 黏滞：松手保留，不清
                }
            }
            arbiter.onCrosshairMove = { [weak self] location in
                guard let self, self.crosshairActive else { return }
                self.moveCrosshair(to: location)                 // 松手后再拖动移光标（图仍冻结）
            }
            arbiter.onCrosshairExit = { [weak self] in
                self?.exitCrosshair()
            }
            arbiter.onPinch = { [weak self] scale, focus, phase in
                guard let self, let engine = self.engine else { return }
                engine.applyPinch(scale: scale, focusX: focus.x, phase: phase, panel: self.panel)
            }
            arbiter.onTap = { [weak self] point in
                self?.handleDrawingTap(at: point)
            }
```

> 注：`onPan` 块（L87-97）不动。删除原 `arbiter.onTwoFingerSwipe = {...}`（L98-101）整块。

- [ ] **Step 3: 加黏滞状态机方法 + haptic**（`Coordinator` 内，`setCrosshair` 旁）

```swift
        /// RFC-C 进入黏滞十字光标：**先守卫（仅主图区 + 有效渲染态）再置状态**——防 volume/MACD/轴区
        /// 长按导致「隐形冻结」（codex M1）。守卫不过 = no-op，不冻结、不置 crosshairMode。
        private func enterCrosshair(at location: CGPoint) {
            guard let view else { return }
            let vp = view.renderState.viewport
            guard vp.geometry.candleStep > 0,
                  !view.renderState.visibleCandles.isEmpty,
                  vp.mainChartFrame.contains(location) else { return }   // 非主图区 → 不进光标、不冻结
            crosshairActive = true
            arbiter.crosshairMode = true
            snapHaptic.prepare()
            lastSnappedIndex = nil
            moveCrosshair(to: location)
        }

        /// RFC-C 移动光标：**先守卫（主图区内）再刷新**；出主图区则忽略本次移动（保留上次有效位置，不消失）。
        /// 吸附 index 变化时震一次（去重）。
        private func moveCrosshair(to location: CGPoint) {
            guard let view else { return }
            let vp = view.renderState.viewport
            guard vp.geometry.candleStep > 0,                            // 空图守卫（Int(NaN) 防崩）
                  !view.renderState.visibleCandles.isEmpty,
                  vp.mainChartFrame.contains(location) else { return }   // 出主图区忽略本次（保留上次）
            setCrosshair(location)                                       // 既有：置点 + rebuild renderState
            let mapper = CoordinateMapper(viewport: vp, displayScale: view.traitCollection.displayScale)
            let idx = CrosshairLayout.snappedCandleIndex(at: location.x, mapper: mapper,
                                                         candles: view.renderState.visibleCandles)
            if idx != lastSnappedIndex {                                 // 每根一次（去重）
                snapHaptic.impactOccurred()
                lastSnappedIndex = idx
            }
        }

        /// RFC-C 退出黏滞：清光标 + arbiter 解冻 + 复位 haptic 去重。
        private func exitCrosshair() {
            crosshairActive = false
            arbiter.crosshairMode = false
            lastSnappedIndex = nil
            setCrosshair(nil)
        }
```

> `setCrosshair` 既有方法（L146-155）保留不动（被 moveCrosshair/exitCrosshair 复用）。`CrosshairLayout.snappedCandleIndex` 是 internal、同模块可见。`view.renderState.visibleCandles` 为空时 `snappedCandleIndex` 调用方已由 candleStep>0 守卫 + resolve 内部 clamp 保护（空切片此处不会进入，因 candleStep>0 蕴含有数据）。

- [ ] **Step 4: Catalyst build 验证**

Run: `xcodebuild build-for-testing -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/rfcc-ddt 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift
git commit -m "feat(rfc-c): Coordinator 黏滞十字光标状态机 + 单指竖滑切周期接线 + 逐根 haptic"
```

---

### Task 6: KLineView+Crosshair 绘制（传 frames + 悬浮信息卡）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift`

**Interfaces:**
- Consumes: Task 1 `CrosshairSidebarContent`、Task 2 `resolve(...,frames:)`；`renderState.frames`、`renderState.visibleCandles`、`renderState.panel.period`、`currentPalette`。
- Produces: 绘制贯穿整 panel 的十字光标 + 悬浮信息卡（颜色：up=palette.up / down=palette.down / flat=白 / neutral=黄）。

> UIKit-only：验证 = Catalyst build + Task 7 人工验收（视觉）。

- [ ] **Step 1: drawCrosshair 传 frames + 装配并画信息卡**

把 `drawCrosshair`（`KLineView+Crosshair.swift:16-35`）改为：

```swift
    func drawCrosshair(ctx: CGContext, at point: CGPoint?, viewport: ChartViewport) {
        let mapper = CoordinateMapper(viewport: viewport,
                                      displayScale: self.traitCollection.displayScale)
        let candles = self.renderState.visibleCandles
        let frames = self.renderState.frames
        guard let resolved = CrosshairLayout.resolve(at: point, mapper: mapper,
                                                     candles: candles, frames: frames) else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        currentPalette.text.setStroke()
        ctx.setLineWidth(1 / mapper.displayScale)
        let lines = resolved.lines
        ctx.move(to: lines.horizontal.from); ctx.addLine(to: lines.horizontal.to); ctx.strokePath()
        ctx.move(to: lines.vertical.from);   ctx.addLine(to: lines.vertical.to);   ctx.strokePath()

        drawLabelBox(ctx: ctx, rect: resolved.priceLabel.rect, text: resolved.priceLabel.text)
        drawLabelBox(ctx: ctx, rect: resolved.timeLabel.rect, text: resolved.timeLabel.text)

        // RFC-C 悬浮信息卡
        guard let p = point else { return }
        let snapped = candles[resolved.snappedIndex]
        let prevClose: Double? = resolved.snappedIndex > candles.startIndex
            ? candles[resolved.snappedIndex - 1].close : nil
        let content = CrosshairSidebarContent.make(
            candle: snapped, previousClose: prevClose,
            cursorPrice: mapper.yToPrice(p.y),
            snappedX: resolved.lines.vertical.from.x,
            mainChartMidX: frames.mainChart.midX)
        drawSidebar(ctx: ctx, content: content, panelFrame: frames.mainChart)
    }
```

- [ ] **Step 2: 加 drawSidebar 绘制方法**

```swift
    /// RFC-C 悬浮信息卡：半透明圆角卡 + 字段行（颜色 up=红/down=绿/flat=白/neutral=黄）。
    /// 停靠：content.dock == .left → 贴 mainChart 左上；.right → 右上。固定不跟手指 Y。
    private func drawSidebar(ctx: CGContext, content: CrosshairSidebarContent, panelFrame: CGRect) {
        let pad: CGFloat = 7, cardW: CGFloat = 126, rowH: CGFloat = 15
        let topRowH: CGFloat = 22
        let rowCount = CGFloat(1 + content.rows.count)   // 日期时间行 + 字段行
        let cardH = topRowH + rowCount * rowH + pad * 2
        let inset: CGFloat = 7
        let x = content.dock == .left ? panelFrame.minX + inset
                                      : panelFrame.maxX - cardW - inset
        let y = panelFrame.minY + inset
        let card = CGRect(x: x, y: y, width: cardW, height: cardH)

        // 背景
        ctx.saveGState()
        let bg = UIBezierPath(roundedRect: card, cornerRadius: 9)
        UIColor.black.withAlphaComponent(0.82).setFill(); bg.fill()
        UIColor(white: 0.25, alpha: 1).setStroke(); bg.lineWidth = 0.5; bg.stroke()
        ctx.restoreGState()

        func color(_ c: CrosshairSidebarContent.ValueColor) -> UIColor {
            switch c {
            case .up:   return currentPalette.candleUp      // 红涨（Theme.swift UIChartPalette.candleUp）
            case .down: return currentPalette.candleDown    // 绿跌（UIChartPalette.candleDown）
            case .flat: return .white
            case .neutral: return UIColor(red: 0.94, green: 0.82, blue: 0.23, alpha: 1)   // 黄
            }
        }
        func draw(_ s: String, _ rect: CGRect, _ col: UIColor, size: CGFloat = 10,
                  align: NSTextAlignment = .left, weight: UIFont.Weight = .semibold) {
            let para = NSMutableParagraphStyle(); para.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: col, .paragraphStyle: para]
            (s as NSString).draw(in: rect, withAttributes: attrs)
        }

        var cy = card.minY + pad
        let lx = card.minX + 8, rx = card.maxX - 8, innerW = rx - lx
        // 栏顶居中实时价
        draw(content.cursorPriceText, CGRect(x: lx, y: cy, width: innerW, height: topRowH - 4),
             color(content.cursorPriceColor), size: 15, align: .center)
        cy += topRowH
        // 日期(左) · 时间(右)
        draw(content.dateText, CGRect(x: lx, y: cy, width: innerW, height: rowH), color(.neutral))
        if let t = content.timeText {
            draw(t, CGRect(x: lx, y: cy, width: innerW, height: rowH), color(.neutral), align: .right)
        }
        cy += rowH
        // 字段行：标签左、值右
        for row in content.rows {
            draw(row.label, CGRect(x: lx, y: cy, width: innerW, height: rowH),
                 UIColor(white: 0.55, alpha: 1), weight: .regular)
            draw(row.value, CGRect(x: lx, y: cy, width: innerW, height: rowH), color(row.color), align: .right)
            cy += rowH
        }
    }
```

> 注：已核实 `UIChartPalette` 实名为 `candleUp`/`candleDown`（`Theme.swift:176`，红涨/绿跌）；`currentPalette` 由 `KLineView.swift:39` 提供，含 `text`/`background`/`gridLine`/`candleUp`/`candleDown` 等。

- [ ] **Step 3: Catalyst build 验证**

Run: `xcodebuild build-for-testing -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/rfcc-ddt 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 4: 跑全量 host 测试核绿（两框架）**

Run: `cd ios/Contracts && swift test 2>&1 | tail -20`
Expected: Swift Testing 汇总 0 失败 + XCTest「All tests passed」（若有）。确认 Task 1-3 全绿、无回归。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift
git commit -m "feat(rfc-c): KLineView 绘制贯穿整 panel 十字光标 + 悬浮信息卡（颜色规则）"
```

---

### Task 7: 验收清单（非程序员可执行）

**Files:**
- Create: `docs/superpowers/acceptance/2026-06-30-crosshair-sidebar-period-swipe.md`

- [ ] **Step 1: 写验收文档**（从 spec §8 抄录，二值可判）

```markdown
# RFC-C 长按十字光标 + 单指竖滑切周期 — 验收清单

> 设备：模拟器 iPhone 17 Pro（udid DE0BA39D-C749-459D-A407-4418599B61CA）+ 真机（haptic）。
> DEBUG fixture（SIMCTL_CHILD_KLINE_SEED_FIXTURE=1）。改 fixture 后须 simctl uninstall 再装。证据：每条附截图。

| # | 操作 | 预期 | 通过判定 |
|---|---|---|---|
| 1 | 长按上图主图 | 细实线十字、竖线贯穿整周期图(主图+量+MACD)、横线在手指 Y(仅主图)、时间标在整图最底部(MACD 下)、整图冻结 | 竖线贯三子图+时标最底+图不动=pass；否则 fail |
| 2 | 按住左右拖动 | 竖线逐根跳变吸附，横线随手指 Y，图不动 | 逐根吸附且图不动=pass；否则 fail |
| 3 | 按住拖动(真机) | 每跨新一根 K 线一次短震动，停同根不重复 | 每根一次=pass；否则 fail |
| 4 | 松手抬指 | 光标+信息栏保留(不消失) | 保留=pass；消失 fail |
| 5 | 点一下屏幕 | 光标消失+栏收+图恢复平移缩放 | 退出且恢复=pass；否则 fail |
| 6 | 光标在主图中心偏右 | 信息栏靠左 | 偏右→左=pass |
| 7 | 光标在中心或偏左 | 信息栏靠右 | 偏左→右=pass |
| 8 | 看信息栏字段 | 栏顶居中实时价 + 日期·时间(同行) + 开高低收/涨跌/涨跌幅/[均价]/成交量/[成交额]；日内显时分、日线只日期 | 字段齐+周期对=pass |
| 9 | 看颜色(涨/跌 K 线各一) | 实时价/收/涨跌/涨跌幅：涨红跌绿平白(基准前收)；日期时间/开高低/均价/量额：黄 | 两类都符=pass |
| 10 | 上下滑横线(竖线不动) | 栏顶实时价随横线纵轴读数变 | 随变=pass |
| 11 | 长按下图(日线) | 栏显日线那根明细(非上图60分) | 显下图=pass |
| 12 | 普通态单指竖直一甩 | 周期切一档(上滑变大/下滑变小)；横滑仍平移 | 竖切横移=pass |
| 13 | 普通态两指竖滑 | 不再切周期(捏合仍缩放) | 两指不切+捏合缩放=pass |
| 14 | 均价行(正常/异常) | 正常显且∈[低,高]；异常(越界)隐藏 | 落区间显/越界隐=pass |
| 15 | 长按成交量/MACD/坐标轴区(非主图蜡烛区) | 不进入十字光标、图不冻结(仍可平移/缩放) | 子图区长按无反应=pass；冻结或隐形光标=fail |
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/acceptance/2026-06-30-crosshair-sidebar-period-swipe.md
git commit -m "docs(rfc-c): 验收清单（14 条二值可判）"
```

---

## Self-Review（plan 对 spec 的覆盖核查）

**1. Spec coverage：**
- §4.1 手势消歧表 → Task 3（单指竖滑）+ Task 4（crosshairMode 路由/抑制/tap 退出）+ Task 5（drawing 互斥门）。✅
- §4.2 黏滞状态机（enter/move/park/exit + 冻结）→ Task 4（arbiter 冻结）+ Task 5（Coordinator 状态机）。✅
- §4.2 竖线贯穿整 panel + 时间标移 macdChart.maxY → Task 2 + Task 6 传 frames。✅
- §4.3 单指竖滑替换两指（R-A 不改 twoFingerStep）→ Task 3（新增单指路径）+ Task 5（删 onTwoFingerSwipe 接线）。✅
- §4.4 吸附 haptic 去重 → Task 5（lastSnappedIndex + impactOccurred）。✅
- §4.5 信息栏字段/均价自检/涨跌派生/颜色/停靠 → Task 1。栏顶实时价居中无标签 + 日期时间同行 + 颜色绘制 → Task 1（数据）+ Task 6（绘制）。✅
- §9 不 bump CONTRACT_VERSION → 全程未触 `Models.swift:7`。✅
- §10 风险 R2 双驱动光标去重 → Task 5（idx != lastSnappedIndex 守门）。✅

**2. Placeholder scan：** 无 TBD/TODO；UIKit 任务（4/5/6）无 host 测是诚实声明（识别器/绘制/触觉无纯单元），由 Catalyst build + Task 7 人工验收覆盖——非占位。`verticalSwitchThreshold=40` 为具体值（runbook 可调）。✅

**3. Type consistency：**
- `SinglePanStep.periodSwipe`（Task 3 定义）→ Task 4 `step.periodSwipe` 消费。✅
- `arbiter.crosshairMode/onCrosshairMove/onCrosshairExit/onVerticalSwipe`（Task 4 定义）→ Task 5 消费。✅
- `CrosshairSidebarContent.make(candle:previousClose:cursorPrice:snappedX:mainChartMidX:)`（Task 1）→ Task 6 同签名调用。✅
- `resolve(...,frames:)`（Task 2）→ Task 6 传 `renderState.frames`。✅
- `currentPalette.candleUp/.candleDown`（已核 `Theme.swift:176`）+ `SwipeDirection`（已核 `Models.swift:49`）。✅

**已知 plan-时未定项（实现者按代码核实，不阻塞）：**
- 成交量单位「手」vs「股」：Task 1 默认「手」（A 股惯例 + mockup）；实现者跑 fixture 核实量级，若为股改标签（均价自检不受影响）。

---

## Codex 对抗 review 修正记录（branch-diff vs main `35a97ab`）

**R1（real Codex，verdict=needs-attention，2 medium 全成立、已修）：**
- **M1 隐形冻结**（Task 5）：`enterCrosshair` 在 `mainChartFrame.contains` 校验前就置 `crosshairActive=true`+`arbiter.crosshairMode=true` → 长按 volume/MACD/轴区会进入冻结模式但 `resolve` 渲染为 nil（图看着死了）。→ **修**：守卫（live view + candleStep>0 + 非空 candles + `mainChartFrame.contains(location)`）**前置于状态置位**，不过则 no-op；`moveCrosshair` 同样守卫前置（出主图区忽略本次、保留上次位置）。新增验收 #15（长按子图区 = no-op）。
- **M2 `groupedInt` 不编译**（Task 1）：`digits = out.reversed()` 把 `ReversedCollection<[Character]>` 赋给 `[Character]` → 类型错，Task 1 首步即编译失败。→ **修**：改左→右扫描（`(count-i)%3==0` 插逗号），不再反转、不再用 `[Character]` 中转。
- 两 finding 都属 plan 文本 bug（隐形冻结的状态置序 / Swift 类型）；修订后逻辑/类型自洽。spec §6 加「长按非主图区 no-op」边界 + §8 加验收 #15 同步。
