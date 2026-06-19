# 图表坐标轴 / 网格 / 周期标注 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 K 线上下两面板的主图 + 量图 + MACD 三区加上价格轴、时间轴、网格线、周期角标（draw-time 解析，零 `KLineRenderState` 改动）。

**Architecture:** 沿用十字光标 `CrosshairLayout` 的 **draw-time 纯函数解析**先例：新增平台无关 `AxisGridLayout`（`internal`，host 全测）算出刻度/网格/标签几何，新增 2 个 UIKit 绘制 pass（`drawGridLines` 最前、`drawAxisLabels` 在 markers 与 crosshair 之间）。全部输入已在 `KLineRenderState` 里（viewport / frames / visibleCandles / volumeRange / macdRange / panel.period），故 **不加 renderState 字段、不改 `RenderStateBuilder`、不 bump `CONTRACT_VERSION`**。

**Tech Stack:** Swift 6 strict concurrency, Swift Testing (`@Suite`/`@Test`/`#expect`), CoreGraphics, UIKit（`#if canImport(UIKit)`），Mac Catalyst build-for-testing。

**Spec:** `docs/superpowers/specs/2026-06-20-chart-axes-grid-period-design.md`（opus 4.8 xhigh 双轮 APPROVE）。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift` | 平台无关纯解析：`AxisGridLayout` enum（priceTicks/timeTicks/volumeAxis/macdZero/periodLabel/resolve）+ `AxisGridResolved`/`Label`/`LineSegment` 嵌套值类型 | **Create** |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+AxisGrid.swift` | UIKit 薄绘制层：`drawGridLines` + `drawAxisLabels`（`#if canImport(UIKit)`） | **Create** |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift` | `drawLabelBox` `private`→`internal`（跨 extension 复用） | **Modify**（单 token） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | `draw(_:)` 插入 1 行 resolve + 2 个绘制调用 | **Modify** |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift` | host 单测 | **Create** |
| `kline_trainer_modules_v1.4.md` / `kline_trainer_plan_v1.5.md` | spec amendment（新增段落） | **Modify** |
| `docs/superpowers/acceptance/2026-06-20-chart-axes-grid-period-acceptance.md` | 非编码者验收清单 | **Create** |

**关键不变量**：`AxisGridLayout` 所有几何**镜像 mapper**（`priceToY`/`indexToX`/`valueToY`），不写第二套公式；时间刻度用**绝对索引**（`candles.startIndex + offset`），价格刻度有**退化区间守卫**（`span≤0`/非有限 → 空）。

---

## Task 1: AxisGridLayout 值类型 + 价格刻度（nice-step）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift`

- [ ] **Step 1: 写失败测试（价格刻度 nice-step + 退化 + 极窄 + 镜像 priceToY）**

创建 `AxisGridLayoutTests.swift`：

```swift
// Kline Trainer Swift Contracts — AxisGridLayout host tests（RFC #3 坐标轴/网格/周期标注）
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func mc(_ idx: Int, datetime: Int64, close: Double = 10, volume: Int64 = 100,
                period: Period = .m3, macdBar: Double? = nil) -> KLineCandle {
    KLineCandle(period: period, datetime: datetime,
                open: close, high: close + 1, low: close - 1, close: close,
                volume: volume, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: macdBar,
                globalIndex: idx, endGlobalIndex: idx)
}

private func makeCandles(count: Int, startDatetime: Int64 = 1735689600, stepSeconds: Int64 = 180,
                         period: Period = .m3, volume: Int64 = 100) -> [KLineCandle] {
    (0..<count).map { mc($0, datetime: startDatetime + Int64($0) * stepSeconds,
                         volume: volume, period: period) }
}

private func makeMapper(startIndex: Int = 0, visibleCount: Int = 10, candleStep: CGFloat = 10,
                        pixelShift: CGFloat = 0, displayScale: CGFloat = 2,
                        priceMin: Double = 0, priceMax: Double = 100,
                        frameWidth: CGFloat = 1000, frameHeight: CGFloat = 360) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: candleStep, candleWidth: candleStep * 0.7, gap: candleStep * 0.3)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: visibleCount, pixelShift: pixelShift,
                           geometry: geom, priceRange: PriceRange(min: priceMin, max: priceMax),
                           mainChartFrame: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    return CoordinateMapper(viewport: vp, displayScale: displayScale)
}

@Suite("AxisGridLayout.priceTicks 价格刻度 nice-step")
struct PriceTicksTests {
    @Test("非整除区间 11.23..12.87 → {11.50,12.00,12.50}（step 0.5，≤6 档）")
    func niceStepNonInteger() {
        let m = makeMapper(priceMin: 11.23, priceMax: 12.87)
        let (labels, lines) = AxisGridLayout.priceTicks(mapper: m)
        #expect(labels.map(\.text) == ["11.50", "12.00", "12.50"])
        #expect(labels.count <= 6)
        #expect(lines.count == labels.count)   // 每档一条水平网格线
    }

    @Test("常态区间 10.05..10.95 → {10.20,10.40,10.60,10.80}（step 0.2，4 档）")
    func niceStepCommon() {
        let m = makeMapper(priceMin: 10.05, priceMax: 10.95)
        let (labels, _) = AxisGridLayout.priceTicks(mapper: m)
        #expect(labels.map(\.text) == ["10.20", "10.40", "10.60", "10.80"])
    }

    @Test("价格档 y == mapper.priceToY(value)（镜像，无第二套公式）")
    func mirrorsPriceToY() {
        let m = makeMapper(priceMin: 11.23, priceMax: 12.87)
        let (labels, lines) = AxisGridLayout.priceTicks(mapper: m)
        for (label, line) in zip(labels, lines) {
            let value = Double(label.text)!
            #expect(line.from.y == m.priceToY(value))
            #expect(line.from.x == m.viewport.mainChartFrame.minX)
            #expect(line.to.x == m.viewport.mainChartFrame.maxX)
            #expect(label.rect.maxX == m.viewport.mainChartFrame.maxX)   // 右贴右缘
            #expect(label.rect.midY == m.priceToY(value))
        }
    }

    @Test("退化区间（全零价格 min==max==0）→ 空刻度、不 trap（防 log10(0) 回归）")
    func degenerateRangeEmpty() {
        let m = makeMapper(priceMin: 0, priceMax: 0)
        let (labels, lines) = AxisGridLayout.priceTicks(mapper: m)
        #expect(labels.isEmpty)
        #expect(lines.isEmpty)
    }

    @Test("极窄正区间 10.001..10.002 → 价格刻度非空、≤6 档（细端阶梯保证非空；非空性回归）")
    func ultraNarrowNonEmpty() {
        let m = makeMapper(priceMin: 10.001, priceMax: 10.002)
        let (labels, _) = AxisGridLayout.priceTicks(mapper: m)
        #expect(!labels.isEmpty)
        #expect(labels.count <= 6)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter PriceTicksTests`
Expected: FAIL — `cannot find 'AxisGridLayout' in scope`。

- [ ] **Step 3: 写最小实现（类型 + priceTicks + niceTickValues）**

创建 `AxisGridLayout.swift`：

```swift
// Kline Trainer Swift Contracts — RFC #3 坐标轴/网格/周期标注 布局（平台无关纯函数）
// Spec: docs/superpowers/specs/2026-06-20-chart-axes-grid-period-design.md
//
// 不 import UIKit：所有几何/文本字符串在 host swift test 真断言（同 CrosshairLayout/MainChartLayout）。
// drawXxx 的 UIKit 描绘薄层在 KLineView+AxisGrid.swift（#if canImport(UIKit)）。
// 全部几何镜像 mapper（priceToY/indexToX/valueToY），不写第二套公式。

import Foundation
import CoreGraphics

/// 坐标轴/网格/周期标注解析结果（单次 draw-time 解析，绘制层消费两遍：网格最前、标签最后）。
struct AxisGridResolved: Equatable, Sendable {
    let gridLines: [AxisGridLayout.LineSegment]   // 水平(价格档/量max/macd0) + 垂直(时间档)
    let priceLabels: [AxisGridLayout.Label]       // 右缘价格刻度
    let timeLabels: [AxisGridLayout.Label]        // 底部时间刻度
    let volumeLabel: AxisGridLayout.Label?        // 量图最大量（万/亿）
    let macdZeroLabel: AxisGridLayout.Label?       // MACD 0 轴
    let periodLabel: AxisGridLayout.Label         // 左上角周期角标
}

enum AxisGridLayout {

    /// 标签盒（rect + text），形状镜像 CrosshairResolved.Label。
    struct Label: Equatable, Sendable {
        let rect: CGRect
        let text: String
    }

    /// 线段（端点），形状镜像 CrosshairLines.LineSegment。
    struct LineSegment: Equatable, Sendable {
        let from: CGPoint
        let to: CGPoint
    }

    private static let maxTicks = 6

    /// 价格刻度 + 对齐的水平网格线（主图）。退化/非有限区间 → 空（守卫，防 log10(0)/除零）。
    static func priceTicks(mapper: CoordinateMapper) -> (labels: [Label], gridLines: [LineSegment]) {
        let lo = mapper.viewport.priceRange.min
        let hi = mapper.viewport.priceRange.max
        let span = hi - lo
        guard span.isFinite, span > 0 else { return ([], []) }
        let frame = mapper.viewport.mainChartFrame
        let labelW: CGFloat = 56, labelH: CGFloat = 16
        var labels: [Label] = []
        var lines: [LineSegment] = []
        for value in niceTickValues(lo: lo, hi: hi) {
            let y = mapper.priceToY(value)
            lines.append(LineSegment(from: CGPoint(x: frame.minX, y: y),
                                     to: CGPoint(x: frame.maxX, y: y)))
            let rect = CGRect(x: frame.maxX - labelW, y: y - labelH / 2, width: labelW, height: labelH)
            labels.append(Label(rect: rect, text: String(format: "%.2f", value)))
        }
        return (labels, lines)
    }

    /// nice-step：候选 {1,2,5}×10^k 由细到粗，取满足 count≤maxTicks 的最小 step（不超 6 档的最细网格）。
    /// 调用方已保 span>0、有限。极窄区间致空 → 回退单档（区间中点）。
    private static func niceTickValues(lo: Double, hi: Double) -> [Double] {
        let span = hi - lo
        let baseExp = Int(floor(log10(span)))
        var candidates: [Double] = []
        for e in (baseExp - 2)...(baseExp + 1) {
            for m in [1.0, 2.0, 5.0] { candidates.append(m * pow(10.0, Double(e))) }
        }
        candidates.sort()
        func count(_ s: Double) -> Int { Int(floor(hi / s)) - Int(ceil(lo / s)) + 1 }
        var chosen = candidates.last!
        for s in candidates where count(s) <= maxTicks { chosen = s; break }
        var ticks: [Double] = []
        var v = (lo / chosen).rounded(.up) * chosen        // first = ceil(lo/step)*step
        while v <= hi + chosen * 1e-9 { ticks.append(v); v += chosen }
        if ticks.isEmpty { ticks = [(lo + hi) / 2] }        // 防御性兜底（R2-N1；当前 2-decade 阶梯下不触发，细端 count≥~100）
        return ticks
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter PriceTicksTests`
Expected: PASS（5 tests）。

- [ ] **Step 5: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift
git commit -m "feat(axis): AxisGridLayout 值类型 + 价格刻度 nice-step（退化守卫 + 空档兜底）"
```

---

## Task 2: 时间刻度 + 垂直网格线（绝对索引 + 周期自适应格式）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift`

- [ ] **Step 1: 写失败测试（绝对索引陷阱 + 六周期格式 + n=1/2 去重）**

追加到 `AxisGridLayoutTests.swift`：

```swift
private func makeFrames(width: CGFloat = 1000, height: CGFloat = 600) -> ChartPanelFrames {
    ChartPanelFrames.split(in: CGRect(x: 0, y: 0, width: width, height: height))
}

@Suite("AxisGridLayout.timeTicks 时间刻度 + 垂直网格")
struct TimeTicksTests {
    @Test("首条垂直线 x == indexToX(candles.startIndex)，≠ indexToX(0)（防 slice-relative 索引陷阱）")
    func absoluteIndexNotSliceRelative() {
        // startIndex=5：indexToX(5)=0（左缘），indexToX(0)=-50（错位），两者可区分。
        let m = makeMapper(startIndex: 5, visibleCount: 10, candleStep: 10)
        let c = makeCandles(count: 15)[5..<15]
        let (labels, lines) = AxisGridLayout.timeTicks(mapper: m, candles: c, period: .m3, frames: makeFrames())
        #expect(lines.first!.from.x == m.indexToX(c.startIndex))   // == indexToX(5) == 0
        #expect(lines.first!.from.x != m.indexToX(0))              // ≠ -50（错位陷阱）
        #expect(labels.count == lines.count)
    }

    @Test("垂直线贯穿三区（mainChart.minY .. macdChart.maxY）")
    func verticalSpansAllFrames() {
        let f = makeFrames()
        let m = makeMapper(visibleCount: 10)
        let c = makeCandles(count: 10)[0..<10]
        let (_, lines) = AxisGridLayout.timeTicks(mapper: m, candles: c, period: .m3, frames: f)
        for line in lines {
            #expect(line.from.y == f.mainChart.minY)
            #expect(line.to.y == f.macdChart.maxY)
        }
    }

    @Test("六周期日期格式分支（UTC+8 / en_US_POSIX）")
    func periodDateFormats() {
        let f = makeFrames()
        // 2025-01-02 09:30 北京（datetime=1735781400）
        func firstLabel(_ p: Period) -> String {
            let c = makeCandles(count: 1, startDatetime: 1735781400, period: p)[0..<1]
            let m = makeMapper(visibleCount: 1)
            return AxisGridLayout.timeTicks(mapper: m, candles: c, period: p, frames: f).labels.first!.text
        }
        #expect(firstLabel(.m3)    == "01-02 09:30")
        #expect(firstLabel(.m60)   == "01-02 09:30")
        #expect(firstLabel(.daily) == "2025-01-02")
        #expect(firstLabel(.weekly) == "2025-01-02")
        #expect(firstLabel(.monthly) == "2025-01")
    }

    @Test("n=1 → 单刻度（索引集去重为 {startIndex}）；n=2 → 两刻度")
    func dedupSmallN() {
        let f = makeFrames()
        let m1 = makeMapper(startIndex: 3, visibleCount: 1)
        let c1 = makeCandles(count: 4)[3..<4]
        #expect(AxisGridLayout.timeTicks(mapper: m1, candles: c1, period: .m3, frames: f).labels.count == 1)
        let m2 = makeMapper(startIndex: 0, visibleCount: 2)
        let c2 = makeCandles(count: 2)[0..<2]
        #expect(AxisGridLayout.timeTicks(mapper: m2, candles: c2, period: .m3, frames: f).labels.count == 2)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter TimeTicksTests`
Expected: FAIL — `type 'AxisGridLayout' has no member 'timeTicks'`。

- [ ] **Step 3: 写实现（timeTicks + dateFormat）**

在 `AxisGridLayout` enum 内追加：

```swift
    /// 时间刻度 + 对齐的垂直网格线（贯穿三区）。**用绝对索引**（candles.startIndex + offset；
    /// indexToX 内部减 viewport.startIndex，传 slice-relative 0 会错位 —— 修 spec-review High）。
    static func timeTicks(mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>,
                          period: Period, frames: ChartPanelFrames) -> (labels: [Label], gridLines: [LineSegment]) {
        guard !candles.isEmpty else { return ([], []) }
        let n = candles.count
        let start = candles.startIndex
        var absIndices: [Int] = []
        for k in 0...3 {
            let idx = start + (n - 1) * k / 3      // 整数运算；k 升序故 idx 非降
            if absIndices.last != idx { absIndices.append(idx) }   // 相邻去重（升序足够）
        }
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = dateFormat(for: period)
        let labelW: CGFloat = 96, labelH: CGFloat = 16
        var labels: [Label] = []
        var lines: [LineSegment] = []
        for idx in absIndices {
            let x = mapper.indexToX(idx)
            lines.append(LineSegment(from: CGPoint(x: x, y: frames.mainChart.minY),
                                     to: CGPoint(x: x, y: frames.macdChart.maxY)))
            let rawX = x - labelW / 2
            let clampedX = min(max(rawX, frames.mainChart.minX), frames.mainChart.maxX - labelW)
            let rect = CGRect(x: clampedX, y: frames.macdChart.maxY - labelH, width: labelW, height: labelH)
            let date = Date(timeIntervalSince1970: TimeInterval(candles[idx].datetime))
            labels.append(Label(rect: rect, text: fmt.string(from: date)))
        }
        return (labels, lines)
    }

    /// 周期自适应日期格式（与 CrosshairLayout.swift:91-94 同 formatter 配置；镜像配置非共享符号）。
    private static func dateFormat(for period: Period) -> String {
        switch period {
        case .m3, .m15, .m60: return "MM-dd HH:mm"
        case .daily, .weekly: return "yyyy-MM-dd"
        case .monthly:        return "yyyy-MM"
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter TimeTicksTests`
Expected: PASS（4 tests）。

- [ ] **Step 5: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift
git commit -m "feat(axis): 时间刻度 + 垂直网格（绝对索引 + 周期自适应格式）"
```

---

## Task 3: 量图最大量标签 + MACD 0 轴

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift`

- [ ] **Step 1: 写失败测试（万/亿格式 + valueToY 镜像 + MACD 0 在/不在区间）**

追加：

```swift
private func makeIndicatorMapper(frame: CGRect, values: [Double],
                                 candleStep: CGFloat = 10, displayScale: CGFloat = 2) -> IndicatorMapper {
    let geom = ChartGeometry(candleStep: candleStep, candleWidth: candleStep * 0.7, gap: candleStep * 0.3)
    let vp = ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0, geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100), mainChartFrame: frame)
    return IndicatorMapper(frame: frame, valueRange: NonDegenerateRange.make(values: values),
                           geometry: geom, viewport: vp, displayScale: displayScale)
}

@Suite("AxisGridLayout 量图/MACD 标签")
struct VolumeMacdTests {
    @Test("formatVolume 万/亿分支")
    func volumeFormat() {
        #expect(AxisGridLayout.formatVolume(9999) == "9999")
        #expect(AxisGridLayout.formatVolume(10_000) == "1.0万")
        #expect(AxisGridLayout.formatVolume(150_000_000) == "1.5亿")
    }

    @Test("量图：标签在 valueToY(maxVolume)，y 略低于 frame 顶（2% padding）")
    func volumeMaxLine() {
        let frame = makeFrames().volumeChart
        let candles = [mc(0, datetime: 1, volume: 5000), mc(1, datetime: 2, volume: 20000)][0..<2]
        // mapper 的 valueRange 必须由同一组 volume 构造（含 0 下界，镜像 RenderStateBuilder）。
        let vm = makeIndicatorMapper(frame: frame, values: [0] + candles.map { Double($0.volume) })
        let result = AxisGridLayout.volumeAxis(volumeMapper: vm, candles: candles)
        #expect(result != nil)
        #expect(result!.gridLine.from.y == vm.valueToY(20000))   // 镜像 valueToY
        #expect(result!.label.text == "2.0万")
        #expect(result!.gridLine.from.y > frame.minY)            // 略低于顶边（2% padding）
    }

    @Test("MACD：0 在区间 → 线/标签在 valueToY(0)；0 不在区间 → nil")
    func macdZeroBranches() {
        let frame = makeFrames().macdChart
        let inRange = makeIndicatorMapper(frame: frame, values: [-0.5, 0.5])
        let r = AxisGridLayout.macdZero(macdMapper: inRange)
        #expect(r != nil)
        #expect(r!.gridLine.from.y == inRange.valueToY(0))
        #expect(r!.label.text == "0")
        // [1.0,2.0]+2% padding → [0.98,2.02]，0 不在区间 → nil
        let outRange = makeIndicatorMapper(frame: frame, values: [1.0, 2.0])
        #expect(AxisGridLayout.macdZero(macdMapper: outRange) == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter VolumeMacdTests`
Expected: FAIL — `no member 'formatVolume'/'volumeAxis'/'macdZero'`。

- [ ] **Step 3: 写实现**

在 `AxisGridLayout` enum 内追加：

```swift
    /// 量图最大量：水平网格线 + 标签，定位 valueToY(maxVolume)（因 volumeRange 有 2% padding，
    /// 此 y 略低于 frame 顶边——与最高量柱顶对齐，非贴 frame 顶）。
    static func volumeAxis(volumeMapper: IndicatorMapper,
                           candles: ArraySlice<KLineCandle>) -> (label: Label, gridLine: LineSegment)? {
        guard let maxVol = candles.map(\.volume).max() else { return nil }
        let y = volumeMapper.valueToY(Double(maxVol))
        let frame = volumeMapper.frame
        let line = LineSegment(from: CGPoint(x: frame.minX, y: y), to: CGPoint(x: frame.maxX, y: y))
        let labelW: CGFloat = 56, labelH: CGFloat = 14
        let rect = CGRect(x: frame.maxX - labelW, y: y, width: labelW, height: labelH)   // 顶端贴线
        return (Label(rect: rect, text: formatVolume(maxVol)), line)
    }

    /// 成交量万/亿格式（≥1e8 亿、≥1e4 万，各一位小数；否则原值）。
    static func formatVolume(_ v: Int64) -> String {
        if v >= 100_000_000 { return String(format: "%.1f亿", Double(v) / 1e8) }
        if v >= 10_000 { return String(format: "%.1f万", Double(v) / 1e4) }
        return "\(v)"
    }

    /// MACD 0 轴：0 落在 valueRange 内 → 线 + "0" 标签；否则 nil。
    static func macdZero(macdMapper: IndicatorMapper) -> (label: Label, gridLine: LineSegment)? {
        let r = macdMapper.valueRange
        guard r.lower <= 0, 0 <= r.upper else { return nil }
        let y = macdMapper.valueToY(0)
        let frame = macdMapper.frame
        let line = LineSegment(from: CGPoint(x: frame.minX, y: y), to: CGPoint(x: frame.maxX, y: y))
        let labelW: CGFloat = 20, labelH: CGFloat = 14
        let rect = CGRect(x: frame.maxX - labelW, y: y - labelH / 2, width: labelW, height: labelH)
        return (Label(rect: rect, text: "0"), line)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter VolumeMacdTests`
Expected: PASS（3 tests）。

- [ ] **Step 5: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift
git commit -m "feat(axis): 量图最大量(万/亿) + MACD 0 轴标签/网格"
```

---

## Task 4: 周期角标

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift`

- [ ] **Step 1: 写失败测试（六周期文字 + 左上角定位）**

追加：

```swift
@Suite("AxisGridLayout.periodLabel 周期角标")
struct PeriodLabelTests {
    @Test("六周期文字映射")
    func periodTexts() {
        let f = makeFrames()
        func txt(_ p: Period) -> String { AxisGridLayout.periodLabel(period: p, frames: f).text }
        #expect(txt(.m3) == "3分")
        #expect(txt(.m15) == "15分")
        #expect(txt(.m60) == "60分")
        #expect(txt(.daily) == "日")
        #expect(txt(.weekly) == "周")
        #expect(txt(.monthly) == "月")
    }

    @Test("角标定位左上角（mainChart 内）")
    func cornerPlacement() {
        let f = makeFrames()
        let label = AxisGridLayout.periodLabel(period: .m60, frames: f)
        #expect(label.rect.minX >= f.mainChart.minX)
        #expect(label.rect.minY >= f.mainChart.minY)
        #expect(label.rect.maxY <= f.mainChart.maxY)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter PeriodLabelTests`
Expected: FAIL — `no member 'periodLabel'`。

- [ ] **Step 3: 写实现**

在 `AxisGridLayout` enum 内追加：

```swift
    /// 周期角标（左上角，mainChart 内）。
    static func periodLabel(period: Period, frames: ChartPanelFrames) -> Label {
        let text: String
        switch period {
        case .m3: text = "3分"
        case .m15: text = "15分"
        case .m60: text = "60分"
        case .daily: text = "日"
        case .weekly: text = "周"
        case .monthly: text = "月"
        }
        let pad: CGFloat = 4, w: CGFloat = 44, h: CGFloat = 16
        let rect = CGRect(x: frames.mainChart.minX + pad, y: frames.mainChart.minY + pad, width: w, height: h)
        return Label(rect: rect, text: text)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter PeriodLabelTests`
Expected: PASS（2 tests）。

- [ ] **Step 5: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift
git commit -m "feat(axis): 周期角标（3分/15分/60分/日/周/月 左上角）"
```

---

## Task 5: resolve 组装 + 空切片守卫

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift`

- [ ] **Step 1: 写失败测试（组装 + nil 守卫 + gridLines 合并）**

追加：

```swift
@Suite("AxisGridLayout.resolve 组装")
struct ResolveTests {
    @Test("空切片 → nil")
    func emptyCandlesNil() {
        let m = makeMapper(visibleCount: 0)
        let f = makeFrames()
        let vm = makeIndicatorMapper(frame: f.volumeChart, values: [0, 1])
        let mm = makeIndicatorMapper(frame: f.macdChart, values: [-1, 1])
        #expect(AxisGridLayout.resolve(mapper: m, volumeMapper: vm, macdMapper: mm,
                                       candles: makeCandles(count: 0)[0..<0], period: .m3, frames: f) == nil)
    }

    @Test("非空 → 组装各部件；gridLines = 价格 + 时间 + 量 + macd 合并")
    func assembles() {
        let f = makeFrames()
        let m = makeMapper(visibleCount: 10, priceMin: 11.23, priceMax: 12.87)
        let vm = makeIndicatorMapper(frame: f.volumeChart, values: [0, 100])
        let mm = makeIndicatorMapper(frame: f.macdChart, values: [-0.5, 0.5])
        let c = makeCandles(count: 10, volume: 100)[0..<10]
        let r = AxisGridLayout.resolve(mapper: m, volumeMapper: vm, macdMapper: mm,
                                       candles: c, period: .m60, frames: f)
        #expect(r != nil)
        guard let r else { return }
        let price = AxisGridLayout.priceTicks(mapper: m)
        let time = AxisGridLayout.timeTicks(mapper: m, candles: c, period: .m60, frames: f)
        #expect(r.priceLabels == price.labels)
        #expect(r.timeLabels == time.labels)
        #expect(r.periodLabel.text == "60分")
        #expect(r.volumeLabel != nil)
        #expect(r.macdZeroLabel != nil)
        // gridLines 合并计数 = 价格 + 时间 + 量(1) + macd(1)
        #expect(r.gridLines.count == price.gridLines.count + time.gridLines.count + 2)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter ResolveTests`
Expected: FAIL — `no member 'resolve'`。

- [ ] **Step 3: 写实现**

在 `AxisGridLayout` enum 内追加：

```swift
    /// 单次 draw-time 解析：组装全部部件。candles.isEmpty → nil（绘制层两 pass 都跳过）。
    /// 各部件独立守卫：价格刻度退化→空、MACD 0 不在区间→nil、量图非空→有；周期角标恒在。
    static func resolve(mapper: CoordinateMapper, volumeMapper: IndicatorMapper, macdMapper: IndicatorMapper,
                        candles: ArraySlice<KLineCandle>, period: Period,
                        frames: ChartPanelFrames) -> AxisGridResolved? {
        guard !candles.isEmpty else { return nil }
        let price = priceTicks(mapper: mapper)
        let time = timeTicks(mapper: mapper, candles: candles, period: period, frames: frames)
        let vol = volumeAxis(volumeMapper: volumeMapper, candles: candles)
        let macd = macdZero(macdMapper: macdMapper)
        var gridLines = price.gridLines + time.gridLines
        if let vol { gridLines.append(vol.gridLine) }
        if let macd { gridLines.append(macd.gridLine) }
        return AxisGridResolved(
            gridLines: gridLines,
            priceLabels: price.labels,
            timeLabels: time.labels,
            volumeLabel: vol?.label,
            macdZeroLabel: macd?.label,
            periodLabel: periodLabel(period: period, frames: frames))
    }
```

- [ ] **Step 4: 跑测试确认通过 + 全量回归**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter ResolveTests` 然后跑全量 `swift test`
Expected: ResolveTests PASS；全量 host 测试无回归（≥ 基线测试数 + 本套新增，0 failures）。
（5 个测试 Suite 的 type 名：PriceTicksTests / TimeTicksTests / VolumeMacdTests / PeriodLabelTests / ResolveTests；逐个可 `--filter <TypeName>`，全跑用无 filter 的 `swift test`。）

- [ ] **Step 5: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/AxisGridLayoutTests.swift
git commit -m "feat(axis): resolve 组装全部件 + 空切片守卫"
```

---

## Task 6: UIKit 绘制层 + KLineView.draw 接线

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+AxisGrid.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift:38`（`private`→`internal`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift`（`draw(_:)`）

> 本任务是 UIKit 层（`#if canImport(UIKit)`），host `swift test` 不编译它；验证 = Mac Catalyst `build-for-testing` 编译闸 + 模拟器人工验收（Task 7）。无 host 单测步骤。

- [ ] **Step 1: `drawLabelBox` private→internal（复用前提）**

编辑 `KLineView+Crosshair.swift:38`，把：
```swift
    private func drawLabelBox(ctx: CGContext, rect: CGRect, text: String) {
```
改为（仅去掉 `private`）：
```swift
    func drawLabelBox(ctx: CGContext, rect: CGRect, text: String) {
```

- [ ] **Step 2: 创建 `KLineView+AxisGrid.swift`**

```swift
// Kline Trainer Swift Contracts — RFC #3 坐标轴/网格/周期标注渲染（UIKit 薄层）
// Spec: docs/superpowers/specs/2026-06-20-chart-axes-grid-period-design.md
//
// 几何/字符串在 AxisGridLayout.swift（平台无关，host 已测）；本文件只做 UIKit 描线 + 标签盒。
// 两个方法都遵循既有 GState 自平衡惯例（saveGState + defer restoreGState），防 stroke/fill 状态泄漏到后续 pass。
// drawLabelBox 复用自 KLineView+Crosshair.swift（已改 internal）。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// 网格 pass（画在 K 线背后）：用 currentPalette.gridLine 描所有网格线，1 device pixel 宽。
    func drawGridLines(ctx: CGContext, resolved: AxisGridResolved?) {
        guard let resolved, !resolved.gridLines.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        currentPalette.gridLine.setStroke()
        ctx.setLineWidth(1 / traitCollection.displayScale)
        for seg in resolved.gridLines {
            ctx.move(to: seg.from)
            ctx.addLine(to: seg.to)
            ctx.strokePath()
        }
    }

    /// 标签 pass（画在 K 线之上、crosshair 之下）：价格/时间/量/MACD/周期标签盒（复用 drawLabelBox）。
    func drawAxisLabels(ctx: CGContext, resolved: AxisGridResolved?) {
        guard let resolved else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        for l in resolved.priceLabels { drawLabelBox(ctx: ctx, rect: l.rect, text: l.text) }
        for l in resolved.timeLabels { drawLabelBox(ctx: ctx, rect: l.rect, text: l.text) }
        if let v = resolved.volumeLabel { drawLabelBox(ctx: ctx, rect: v.rect, text: v.text) }
        if let m = resolved.macdZeroLabel { drawLabelBox(ctx: ctx, rect: m.rect, text: m.text) }
        drawLabelBox(ctx: ctx, rect: resolved.periodLabel.rect, text: resolved.periodLabel.text)
    }
}
#endif
```

- [ ] **Step 3: 接线 `KLineView.draw(_:)`**

在 `KLineView.swift` 的 `draw(_:)` 内，三个 mapper 构造之后、`drawCandles(...)` 之前，插入 resolve + 网格 pass：
```swift
        let axisGrid = AxisGridLayout.resolve(
            mapper: mapper, volumeMapper: volMapper, macdMapper: macdMapper,
            candles: renderState.visibleCandles, period: renderState.panel.period,
            frames: renderState.frames)
        drawGridLines(ctx: ctx, resolved: axisGrid)

        drawCandles(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
```
（即在现有 `drawCandles(...)` 行上方加 4 行。）

然后在 `drawMarkers(...)` 调用之后、`drawCrosshair(...)` 之前，插入标签 pass：
```swift
        drawMarkers(ctx: ctx, viewport: renderState.viewport, mapper: mapper,
                    markers: renderState.markers, candles: renderState.visibleCandles)
        drawAxisLabels(ctx: ctx, resolved: axisGrid)
        drawCrosshair(ctx: ctx, at: renderState.crosshairPoint, viewport: renderState.viewport)
```

- [ ] **Step 4: Mac Catalyst 编译闸 + host 回归**

Run（host 全量先确认纯层不回归）:
`cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed`，0 failures。

Run（Catalyst build-for-testing 编译 UIKit 层）:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
xcodebuild build-for-testing -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -15
```
Expected: `** TEST BUILD SUCCEEDED **`（`KLineView+AxisGrid.swift` 与改后的 `KLineView.draw` 编译通过）。
（命令与 `.github/workflows/catalyst-build.yml:45-47` 逐字一致。）

Run（iOS app target build，命令与 `.github/workflows/app-build.yml:41-46` 一致）:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
xcodebuild build \
  -project ios/KlineTrainer/KlineTrainer.xcodeproj \
  -scheme KlineTrainer \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/app-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+AxisGrid.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift
git commit -m "feat(axis): UIKit 绘制层（网格最前 + 标签 crosshair 前）+ drawLabelBox internal 复用 + draw 接线"
```

---

## Task 7: spec amendment + 验收清单

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（新增 §C5b）
- Modify: `kline_trainer_plan_v1.5.md`（新增轴/网格/周期渲染一节）
- Create: `docs/superpowers/acceptance/2026-06-20-chart-axes-grid-period-acceptance.md`

- [ ] **Step 1: modules_v1.4 新增 §C5b**

在 `kline_trainer_modules_v1.4.md` 的 §C5（十字光标）段落之后，新增：
```markdown
### §C5b 坐标轴 / 网格 / 周期标注布局 `AxisGridLayout`（RFC 2026-06-20）

平台无关纯类型 `AxisGridLayout`（internal，同 `CrosshairLayout`），draw-time 解析：
- `priceTicks` / `timeTicks` / `volumeAxis` / `macdZero` / `periodLabel` / `resolve(...) -> AxisGridResolved?`
- 全部输入来自既有 `KLineRenderState`（viewport / frames / visibleCandles / volumeRange / macdRange / panel.period）；
  **`KLineRenderState` 契约不变（无新字段）**。
- UIKit 绘制：`KLineView.draw` 新增 2 pass —— `drawGridLines`（最前，K 线背后，`gridLine` token）、
  `drawAxisLabels`（在 `drawMarkers` 与 `drawCrosshair` 之间）。既有 8 个 draw 调用顺序不变。
- 价格刻度：右缘整齐 nice-step（≤6 档，退化区间空）；时间刻度：底部周期自适应格式 + 绝对索引；
  垂直网格贯穿三区；量图最大量（万/亿）、MACD 0 轴；周期角标左上。
- 标签盒复用 `KLineView.drawLabelBox`（`private`→`internal`）。
```

- [ ] **Step 2: plan_v1.5 新增渲染节**

在 `kline_trainer_plan_v1.5.md` 的图表渲染相关章节末尾，新增：
```markdown
#### 坐标轴 / 网格 / 周期标注（RFC 2026-06-20，#3）

上下两面板主图 + 量图 + MACD 三区均渲染：价格轴（右缘，整齐 nice-step 刻度 + 水平网格）、
时间轴（底部共享，周期自适应：分钟级 MM-dd HH:mm / 日·周 yyyy-MM-dd / 月 yyyy-MM）+ 垂直网格、
量图最大量（万/亿）、MACD 0 轴、左上周期角标（3分/15分/60分/日/周/月）。
**标签悬浮**（半透明/实心盒叠在 K 线上），**冻结的 60/15/25 三区几何与视口宽度不变**（非留白槽）。
无最新价横线。详见 docs/superpowers/specs/2026-06-20-chart-axes-grid-period-design.md。
```

- [ ] **Step 3: 写验收清单**

创建 `docs/superpowers/acceptance/2026-06-20-chart-axes-grid-period-acceptance.md`（见下方完整模板，含：host 测试节、Catalyst 编译节、模拟器 runbook 多场景、Opus ledger 节）。模板：
```markdown
# 验收清单：图表坐标轴 / 网格 / 周期标注（RFC #3）

## 1. host 单测（机器执行）
- [ ] 动作：`cd ios/Contracts && swift test --filter AxisGridLayout`
      预期：`AxisGridLayout` 各 Suite 全绿（PriceTicks/TimeTicks/VolumeMacd/PeriodLabel/Resolve）。
- [ ] 动作：`cd ios/Contracts && swift test`
      预期：全量通过，0 failures，相对基线无回归。

## 2. Mac Catalyst 编译（机器执行）
- [ ] 动作：`xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`
      预期：`** TEST BUILD SUCCEEDED **`。

## 3. iOS app build（机器执行）
- [ ] 动作：构建 app target（按仓库现有 app build 命令/CI job）。
      预期：`** BUILD SUCCEEDED **`。

## 4. 模拟器人工验收（非编码者执行，iPhone 17 Pro 模拟器 + seed fixture）
| # | 动作 | 预期 | 通过? |
|---|---|---|---|
| 1 | 启动训练，看上面板（默认 60 分） | 右缘有整齐价格刻度数字、对齐的横向网格线 | ☐ |
| 2 | 看上面板左上角 | 显示「60分」角标 | ☐ |
| 3 | 看屏幕底部 | 一条时间轴，分钟级显示「MM-DD HH:mm」格式 | ☐ |
| 4 | 看量图区 | 顶部有最大量标签（万/亿），一条水平网格 | ☐ |
| 5 | 看 MACD 区 | 有一条 0 轴水平线 + 「0」标签 | ☐ |
| 6 | 看下面板（默认日线） | 角标「日」，时间轴显示「YYYY-MM-DD」格式 | ☐ |
| 7 | 两指上滑切到更大周期（如月线） | 角标与时间轴格式随周期变化（月线「YYYY-MM」） | ☐ |
| 8 | 切到暗/亮主题 | 网格线 gridLine 在两主题下都可见、不刺眼 | ☐ |
| 9 | 长按出十字光标 | 十字光标 HUD 盖在坐标轴标签之上（层序正确） | ☐ |

## 5. 回归确认（非编码者执行）
| # | 动作 | 预期 | 通过? |
|---|---|---|---|
| 1 | 买入/卖出/平仓 | 交易动作与标记一切如常（未受渲染改动影响） | ☐ |
| 2 | pan/pinch/复盘 | 滚动、缩放、复盘出图一切如常 | ☐ |

## 6. Opus 4.8 xhigh 对抗性 review ledger（代 codex，user explicit）
- spec：R1 NEEDS-ATTENTION（3H/2M）→ 全修 → R2 APPROVE（+3L 修）。commits 5f15d68 / 74b397b。
- plan：<填 R 轮次 + 结论>。
- branch-diff：<填 R 轮次 + 结论>。
```

- [ ] **Step 4: 验证文档锚点（grep 真匹配）**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
grep -Fc "AxisGridLayout" kline_trainer_modules_v1.4.md
grep -Fc "坐标轴 / 网格 / 周期标注" kline_trainer_plan_v1.5.md
test -f docs/superpowers/acceptance/2026-06-20-chart-axes-grid-period-acceptance.md && echo OK
```
Expected: modules 计数 ≥1、plan 计数 ≥1、`OK`。

- [ ] **Step 5: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md docs/superpowers/acceptance/2026-06-20-chart-axes-grid-period-acceptance.md
git commit -m "docs(axis): spec amendment（modules §C5b + plan 渲染节）+ 验收清单"
```

---

## 备注（实现者必读）

- **标签盒样式**：复用 `KLineView.drawLabelBox` —— 该方法用 `currentPalette.background` **实心**填充（同十字光标 HUD），非真半透明。spec 文案写「半透明」是观感目标；实现以 drawLabelBox 实心盒为准（spec-review 已 bless 复用 drawLabelBox 的决策）。真半透明属 cosmetic follow-up，不在本 PR 范围。branch-diff review 据此判定，不算 spec-impl 失配。
- **浮点**：价格刻度断言用 `%.2f` 字符串比较（FP-safe）；勿对原始 Double 做 `==`（吸取 `feedback_swift_local_toolchain_blindspot`：非整除浮点必须容差/字面对齐）。
- **绝对索引**：时间刻度的 `idx_k = candles.startIndex + …`（绝对），传给 `indexToX`；这是 spec-review High 修复点，Task 2 测试 `absoluteIndexNotSliceRelative` 是其杀手测试，勿改成 slice-relative。
- **GState**：两个新 draw 方法都必须 `saveGState()` + `defer restoreGState()`，否则 stroke/fill 状态泄漏进 `drawCandles`。
- **CONTRACT_VERSION 不 bump**：internal 类型 + 增量 draw pass，不命中 `docs/governance/m01-schema-versioning-contract.md` 的 A 类触发。
```
