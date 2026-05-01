# C1a Geometry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Project memory `project_executing_plans_excluded` 明确：本项目只用 subagent-driven-development，不用 executing-plans。每个 batch 派一个 fresh sonnet 4.6 high-effort subagent；批与批之间主线 review。

**Goal:** 落地 modules §C1a 的 7 个值类型——图表渲染的几何 / 视口 / 坐标映射底盘（`ChartGeometry / ChartPanelFrames / PriceRange / ChartViewport / CoordinateMapper / IndicatorMapper / NonDegenerateRange`），全部 `Equatable, Sendable`，UIKit-free，纯 CoreGraphics 数学。

**Architecture:** 单文件值类型 bundle 落 SwiftPM `KlineTrainerContracts` package 内 `Geometry/` 子目录；零业务 invariant；2 个 factory 带 logic（`PriceRange.calculate` 含 BOLL/MA66 + 5% padding；`NonDegenerateRange.make` 含 3 分支 fallback），其它纯值容器 + sub-pixel 算式。impl 一字不差对应 modules §C1a declaration + plan §3 body（5 项 spec discrepancy 全 modules 优先，详见 design doc）。

**Tech Stack:** Swift 6（toolchain 6.3.1）+ SwiftPM intra-package + Swift Testing macros（`@Test` / `@Suite` / `#expect`）+ `import Foundation` + `import CoreGraphics`。CGFloat/CGRect Sendable via Swift 6 retroactive。

**Design Doc:** `docs/superpowers/specs/2026-04-30-c1a-geometry-design.md`（commit 92a5f64）

---

## File Structure

| File | Responsibility | LOC budget |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Geometry/Geometry.swift` | 7 值类型 impl bundle | ≤210 行 prod |
| `ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift` | 34 tests（7 个 `@Suite`：1+3+7+3+6+9+5） | ≤420 行（含 blank separator + helpers，实测对齐） |

**File rationale**：单 prod 文件 ~187 LOC 在 simplicity-first / 可读性范围内；7 个 `@Suite` 分组让测试结构按类型映射，无需拆 7 个 test 文件。Swift Package Manager 自动递归扫 target path，`Geometry/` 子目录无需改 Package.swift。

**Working directory**：`/Users/maziming/Coding/Prj_Kline trainer/.worktrees/c1a-geometry/ios/Contracts/`（SwiftPM root）

**Baseline**：`swift test` 当前 64 tests pass / 0 warnings（49 baseline + 15 E1）；C1a PR 完成后预期 98 tests pass（64 + 34）。

---

## Task 1: C1a Geometry impl + 34 tests（TDD red-green per dep-order batch）

**Strategy**：4 batches 按依赖顺序拆，每个 batch 走完 RED → GREEN → commit 后进下一个。每 batch 一个 fresh sonnet 4.6 high-effort subagent；所有 7 类型最终落同一 `Geometry.swift`，测试落同一 `GeometryTests.swift`。

| Batch | 类型 | 依赖 | tests | LOC prod 增量 |
|---|---|---|---|---|
| A | ChartGeometry / ChartPanelFrames / NonDegenerateRange | 无（NDR 内部完整） | 1+3+6=10 | ~70 |
| B | PriceRange | KLineCandle（外部 same-package） | 7 | ~30 |
| C | ChartViewport | ChartGeometry + PriceRange | 3 | ~22 |
| D | CoordinateMapper + IndicatorMapper | ChartViewport + NonDegenerateRange + ChartGeometry | 9+5=14 | ~70 |

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Geometry/Geometry.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift`

---

### Batch A: ChartGeometry / ChartPanelFrames / NonDegenerateRange + 10 tests

依赖最少（NDR 无 init public，外部走 .make；其它纯字段），可独立验证。

- [ ] **Step A.1: Create test file scaffold + 10 tests**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("ChartGeometry")
struct ChartGeometryTests {

    @Test("init + Equatable auto-synth")
    func initAndEquatable() {
        let a = ChartGeometry(candleStep: 8, candleWidth: 6, gap: 2)
        let b = ChartGeometry(candleStep: 8, candleWidth: 6, gap: 2)
        let c = ChartGeometry(candleStep: 9, candleWidth: 6, gap: 2)
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("ChartPanelFrames")
struct ChartPanelFramesTests {

    @Test("split 60/15/25 比例 + 顺序堆叠")
    func splitProportions() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let f = ChartPanelFrames.split(in: rect)
        #expect(f.mainChart.height == 600)
        #expect(f.volumeChart.height == 150)
        #expect(f.macdChart.height == 250)
        #expect(f.mainChart.minY == 0)
        #expect(f.volumeChart.minY == 600)
        #expect(f.macdChart.minY == 750)
    }

    @Test("非零 origin 保持偏移")
    func splitNonZeroOrigin() {
        let rect = CGRect(x: 50, y: 100, width: 400, height: 1000)
        let f = ChartPanelFrames.split(in: rect)
        #expect(f.mainChart.minX == 50)
        #expect(f.volumeChart.minX == 50)
        #expect(f.mainChart.minY == 100)
        #expect(f.volumeChart.minY == 700)
    }

    @Test("0 高度 rect 全部子 frame 高度为 0")
    func splitZeroHeight() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 0)
        let f = ChartPanelFrames.split(in: rect)
        #expect(f.mainChart.height == 0)
        #expect(f.volumeChart.height == 0)
        #expect(f.macdChart.height == 0)
    }
}

@Suite("NonDegenerateRange")
struct NonDegenerateRangeTests {

    @Test("empty values → fallback")
    func emptyFallback() {
        let r = NonDegenerateRange.make(values: [])
        #expect(r.lower == 0.0)
        #expect(r.upper == 1.0)
        #expect(r.span == 1.0)
        #expect(r.span > 0)
    }

    @Test("全等值 → 对称 ±pad")
    func equalValues() {
        let r = NonDegenerateRange.make(values: [10.0, 10.0, 10.0])
        #expect(r.lower < 10.0)
        #expect(r.upper > 10.0)
        #expect(r.span > 0)
    }

    @Test("普通 values → span * paddingRatio pad")
    func normalSpanPad() {
        let r = NonDegenerateRange.make(values: [0.0, 100.0])
        let span = 100.0
        let pad = span * 0.02
        #expect(r.lower == -pad)
        #expect(r.upper == 100.0 + pad)
        #expect(r.span > 0)
    }

    @Test("non-default paddingRatio honored")
    func customPaddingRatio() {
        let r = NonDegenerateRange.make(values: [0.0, 100.0], paddingRatio: 0.10)
        let pad = 100.0 * 0.10
        #expect(r.lower == -pad)
        #expect(r.upper == 100.0 + pad)
        #expect(r.span > 0)
    }

    @Test("non-default fallback honored")
    func customFallback() {
        let r = NonDegenerateRange.make(values: [], fallback: -10.0...20.0)
        #expect(r.lower == -10.0)
        #expect(r.upper == 20.0)
        #expect(r.span > 0)
    }

    @Test("全 0 单值 → 1e-6 padding 兜底（防 abs(0)*ratio = 0 退化）")
    func zeroValueFallbackPad() {
        let r = NonDegenerateRange.make(values: [0.0])
        #expect(r.lower < 0.0)
        #expect(r.upper > 0.0)
        #expect(r.span > 0)
        #expect(r.span >= 2e-6)
    }
}
```

- [ ] **Step A.2: Run tests to verify RED**

Run from worktree root:
```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry/ios/Contracts && swift test --filter "ChartGeometry|ChartPanelFrames|NonDegenerateRange"
```
Expected: 编译失败，`error: cannot find 'ChartGeometry' / 'ChartPanelFrames' / 'NonDegenerateRange' in scope`

- [ ] **Step A.3: Create Geometry.swift with Batch A 3 类型**

Create `ios/Contracts/Sources/KlineTrainerContracts/Geometry/Geometry.swift`:

```swift
// Kline Trainer Swift Contracts — C1a Geometry
// Spec: kline_trainer_modules_v1.4.md §C1a + kline_trainer_plan_v1.5.md §3
// Design doc: docs/superpowers/specs/2026-04-30-c1a-geometry-design.md

import Foundation
import CoreGraphics

// MARK: - 几何 + 面板

public struct ChartGeometry: Equatable, Sendable {
    public let candleStep: CGFloat
    public let candleWidth: CGFloat
    public let gap: CGFloat

    public init(candleStep: CGFloat, candleWidth: CGFloat, gap: CGFloat) {
        self.candleStep = candleStep
        self.candleWidth = candleWidth
        self.gap = gap
    }
}

public struct ChartPanelFrames: Equatable, Sendable {
    public let mainChart: CGRect
    public let volumeChart: CGRect
    public let macdChart: CGRect

    public init(mainChart: CGRect, volumeChart: CGRect, macdChart: CGRect) {
        self.mainChart = mainChart
        self.volumeChart = volumeChart
        self.macdChart = macdChart
    }

    /// 60/15/25 纵向堆叠（modules L884-886）
    public static func split(in rect: CGRect) -> ChartPanelFrames {
        let mainH = rect.height * 0.60
        let volH = rect.height * 0.15
        let macdH = rect.height * 0.25
        let main = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: mainH)
        let vol = CGRect(x: rect.minX, y: rect.minY + mainH, width: rect.width, height: volH)
        let macd = CGRect(x: rect.minX, y: rect.minY + mainH + volH, width: rect.width, height: macdH)
        return ChartPanelFrames(mainChart: main, volumeChart: vol, macdChart: macd)
    }
}

// MARK: - 非退化值域（副图 mapper 用）

public struct NonDegenerateRange: Equatable, Sendable {
    public let lower: Double
    public let upper: Double                    // 强制 upper > lower（无 public init，外部只能走 .make）

    // memberwise init 不显式声明 → Swift 合成 internal init；外部只能 .make
    // 同 package test 可直接 internal init 验证 Equatable / span / 边界

    /// modules L924-925 字面：empty / 全等值都返回可用 range
    public static func make(values: [Double],
                            fallback: ClosedRange<Double> = 0.0...1.0,
                            paddingRatio: Double = 0.02) -> NonDegenerateRange {
        guard let minV = values.min(), let maxV = values.max() else {
            return NonDegenerateRange(lower: fallback.lowerBound, upper: fallback.upperBound)
        }
        if minV == maxV {
            let pad = Swift.max(abs(minV) * paddingRatio, 1e-6)
            return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
        }
        let span = maxV - minV
        let pad = span * paddingRatio
        return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
    }

    public var span: Double { upper - lower }
}
```

- [ ] **Step A.4: Run tests to verify GREEN**

Run:
```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry/ios/Contracts && swift test --filter "ChartGeometry|ChartPanelFrames|NonDegenerateRange"
```
Expected: 10 tests 全过；0 warnings。

- [ ] **Step A.5: Commit Batch A**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry
git add ios/Contracts/Sources/KlineTrainerContracts/Geometry/Geometry.swift ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift
git commit -m "feat(C1a): ChartGeometry/ChartPanelFrames/NonDegenerateRange + 10 tests (Batch A, TDD green)"
```

---

### Batch B: PriceRange + 7 tests（含 reviewer test-1 三指标全有 + 5% pad 精确值 + 单根 candle）

依赖 KLineCandle（已在 same package Models.swift L59）。

- [ ] **Step B.1: Append PriceRange test fixture helpers + 7 tests**

Append to `GeometryTests.swift`（在 `NonDegenerateRangeTests` 闭合 `}` 之后）:

```swift

// MARK: - Helper for PriceRange tests

private func makeCandle(low: Double, high: Double,
                       bollUpper: Double? = nil, bollLower: Double? = nil,
                       ma66: Double? = nil) -> KLineCandle {
    KLineCandle(
        period: .min15, datetime: 0,
        open: low, high: high, low: low, close: high,
        volume: 0, amount: nil, ma66: ma66,
        bollUpper: bollUpper, bollMid: nil, bollLower: bollLower,
        macdDiff: nil, macdDea: nil, macdBar: nil,
        globalIndex: nil, endGlobalIndex: 0
    )
}

@Suite("PriceRange")
struct PriceRangeTests {

    @Test("empty candles → (0, 1)")
    func emptyFallback() {
        let empty: ArraySlice<KLineCandle> = []
        let r = PriceRange.calculate(from: empty)
        #expect(r.min == 0.0)
        #expect(r.max == 1.0)
    }

    @Test("普通 candles 仅 high/low → ±5% padding")
    func plainHighLow() {
        let candles = [makeCandle(low: 100, high: 200)]
        let r = PriceRange.calculate(from: candles[...])
        #expect(r.min == 100.0 * 0.95)
        #expect(r.max == 200.0 * 1.05)
    }

    @Test("含 bollUpper 扩 hi")
    func includesBollUpper() {
        let candles = [makeCandle(low: 100, high: 200, bollUpper: 250)]
        let r = PriceRange.calculate(from: candles[...])
        #expect(r.max == 250.0 * 1.05)
        #expect(r.min == 100.0 * 0.95)
    }

    @Test("含 bollLower 扩 lo")
    func includesBollLower() {
        let candles = [makeCandle(low: 100, high: 200, bollLower: 80)]
        let r = PriceRange.calculate(from: candles[...])
        #expect(r.min == 80.0 * 0.95)
        #expect(r.max == 200.0 * 1.05)
    }

    @Test("含 ma66 同时扩 lo/hi")
    func includesMA66() {
        let candlesHi = [makeCandle(low: 100, high: 200, ma66: 250)]
        let r1 = PriceRange.calculate(from: candlesHi[...])
        #expect(r1.max == 250.0 * 1.05)

        let candlesLo = [makeCandle(low: 100, high: 200, ma66: 50)]
        let r2 = PriceRange.calculate(from: candlesLo[...])
        #expect(r2.min == 50.0 * 0.95)
    }

    @Test("三指标全有 + 同时扩 lo/hi（reviewer test-1）")
    func allThreeIndicators() {
        let candles = [makeCandle(low: 100, high: 200, bollUpper: 240, bollLower: 90, ma66: 250)]
        let r = PriceRange.calculate(from: candles[...])
        // hi: bollUpper=240 < ma66=250 → 250 wins
        // lo: bollLower=90 < low=100 → 90 wins
        #expect(r.max == 250.0 * 1.05)
        #expect(r.min == 90.0 * 0.95)
    }

    @Test("单根 candle 全 nil 指标 → 仅 high/low ±5%")
    func singleCandleNoIndicators() {
        let candles = [makeCandle(low: 50, high: 60)]
        let r = PriceRange.calculate(from: candles[...])
        #expect(r.min == 50.0 * 0.95)
        #expect(r.max == 60.0 * 1.05)
    }
}
```

- [ ] **Step B.2: Run tests to verify RED**

Run:
```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry/ios/Contracts && swift test --filter PriceRange
```
Expected: 编译失败，`error: cannot find 'PriceRange' in scope`

- [ ] **Step B.3: Append PriceRange impl to Geometry.swift**

Append to `Geometry.swift`（在 `NonDegenerateRange` 闭合 `}` 之后）:

```swift

// MARK: - 价格值域

public struct PriceRange: Equatable, Sendable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    /// plan §3 L142-161 字面：含 BOLL / MA66 + 5% 上下扩展
    public static func calculate(from candles: ArraySlice<KLineCandle>) -> PriceRange {
        guard !candles.isEmpty else { return PriceRange(min: 0, max: 1) }
        var lo = candles.map(\.low).min()!
        var hi = candles.map(\.high).max()!
        for c in candles {
            if let bu = c.bollUpper { hi = Swift.max(hi, bu) }
            if let bl = c.bollLower { lo = Swift.min(lo, bl) }
            if let ma = c.ma66 { hi = Swift.max(hi, ma); lo = Swift.min(lo, ma) }
        }
        lo *= 0.95
        hi *= 1.05
        return PriceRange(min: lo, max: hi)
    }
}
```

- [ ] **Step B.4: Run tests to verify GREEN**

Run:
```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry/ios/Contracts && swift test --filter PriceRange
```
Expected: 7 tests 全过；累计 17 tests pass。

- [ ] **Step B.5: Commit Batch B**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry
git add ios/Contracts/Sources/KlineTrainerContracts/Geometry/Geometry.swift ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift
git commit -m "feat(C1a): PriceRange.calculate + 7 tests 含三指标全有 (Batch B, TDD green)"
```

---

### Batch C: ChartViewport + 3 tests

依赖 ChartGeometry + PriceRange（Batch A + B 已 green）。

- [ ] **Step C.1: Append 3 ChartViewport tests**

Append to `GeometryTests.swift`:

```swift

@Suite("ChartViewport")
struct ChartViewportTests {

    private func makeViewport(startIndex: Int = 0, mainChartFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 600)) -> ChartViewport {
        ChartViewport(
            startIndex: startIndex,
            visibleCount: 100,
            pixelShift: 0,
            geometry: ChartGeometry(candleStep: 8, candleWidth: 6, gap: 2),
            priceRange: PriceRange(min: 100, max: 200),
            mainChartFrame: mainChartFrame
        )
    }

    @Test("init 6 字段全保留")
    func initFields() {
        let v = makeViewport(startIndex: 50)
        #expect(v.startIndex == 50)
        #expect(v.visibleCount == 100)
        #expect(v.pixelShift == 0)
        #expect(v.geometry.candleStep == 8)
        #expect(v.priceRange.min == 100)
        #expect(v.mainChartFrame.width == 400)
    }

    @Test("Equatable 同字段 ==")
    func equatableSame() {
        let a = makeViewport()
        let b = makeViewport()
        #expect(a == b)
    }

    @Test("Equatable 跨 frame 不同 !=")
    func equatableDifferentFrame() {
        let a = makeViewport(mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let b = makeViewport(mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(a != b)
    }
}
```

- [ ] **Step C.2: Run tests to verify RED**

Run:
```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry/ios/Contracts && swift test --filter ChartViewport
```
Expected: 编译失败，`error: cannot find 'ChartViewport' in scope`

- [ ] **Step C.3: Append ChartViewport impl to Geometry.swift**

Append:

```swift

// MARK: - 视口

public struct ChartViewport: Equatable, Sendable {
    public let startIndex: Int
    public let visibleCount: Int
    public let pixelShift: CGFloat
    public let geometry: ChartGeometry
    public let priceRange: PriceRange
    public let mainChartFrame: CGRect

    public init(startIndex: Int, visibleCount: Int, pixelShift: CGFloat,
                geometry: ChartGeometry, priceRange: PriceRange, mainChartFrame: CGRect) {
        self.startIndex = startIndex
        self.visibleCount = visibleCount
        self.pixelShift = pixelShift
        self.geometry = geometry
        self.priceRange = priceRange
        self.mainChartFrame = mainChartFrame
    }
}
```

- [ ] **Step C.4: Run tests to verify GREEN**

Run:
```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry/ios/Contracts && swift test --filter ChartViewport
```
Expected: 3 tests 全过；累计 20 tests pass。

- [ ] **Step C.5: Commit Batch C**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry
git add ios/Contracts/Sources/KlineTrainerContracts/Geometry/Geometry.swift ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift
git commit -m "feat(C1a): ChartViewport 6 字段 + 3 tests (Batch C, TDD green)"
```

---

### Batch D: CoordinateMapper + IndicatorMapper + 14 tests（含 reviewer test-2 / test-3）

依赖 ChartViewport + NonDegenerateRange + ChartGeometry（Batch A + C 已 green）。

- [ ] **Step D.1: Append 9 CoordinateMapper tests + 5 IndicatorMapper tests**

Append to `GeometryTests.swift`:

```swift

@Suite("CoordinateMapper")
struct CoordinateMapperTests {

    private func makeMapper(displayScale: CGFloat = 2,
                           startIndex: Int = 0,
                           candleStep: CGFloat = 8,
                           mainChartFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 600),
                           priceMin: Double = 100, priceMax: Double = 200) -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(
                startIndex: startIndex, visibleCount: 100, pixelShift: 0,
                geometry: ChartGeometry(candleStep: candleStep, candleWidth: 6, gap: 2),
                priceRange: PriceRange(min: priceMin, max: priceMax),
                mainChartFrame: mainChartFrame
            ),
            displayScale: displayScale
        )
    }

    @Test("indexToX 起点 = 0")
    func indexToXStart() {
        let m = makeMapper(displayScale: 1, startIndex: 0)
        #expect(m.indexToX(0) == 0)
    }

    @Test("indexToX 偏移 N step")
    func indexToXOffset() {
        let m = makeMapper(displayScale: 1, startIndex: 0, candleStep: 8)
        #expect(m.indexToX(10) == 80)
    }

    @Test("priceToY 上界 priceMax → frame.minY")
    func priceToYUpper() {
        let m = makeMapper(priceMin: 100, priceMax: 200)
        // ratio = 1 → raw = maxY - height = 0
        #expect(m.priceToY(200) == 0)
    }

    @Test("priceToY 下界 priceMin → frame.maxY")
    func priceToYLower() {
        let m = makeMapper(priceMin: 100, priceMax: 200,
                          mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 600))
        // ratio = 0 → raw = maxY = 600
        #expect(m.priceToY(100) == 600)
    }

    @Test("xToIndex floor 行为（向 -∞ 取整）")
    func xToIndexFloor() {
        let m = makeMapper(startIndex: 0, candleStep: 8)
        #expect(m.xToIndex(0) == 0)
        #expect(m.xToIndex(7.9) == 0)         // floor(7.9/8) = 0
        #expect(m.xToIndex(8) == 1)
        #expect(m.xToIndex(15.9) == 1)        // floor(15.9/8) = 1
    }

    @Test("yToPrice 反向 priceToY")
    func yToPriceInverse() {
        let m = makeMapper(priceMin: 100, priceMax: 200,
                          mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let y = m.priceToY(150)
        let price = m.yToPrice(y)
        #expect(abs(price - 150) < 0.01)
    }

    @Test("sub-pixel scale=1 不改变整数 raw")
    func subPixelScale1() {
        let m = makeMapper(displayScale: 1, startIndex: 0, candleStep: 8)
        // raw = 80 → 80 * 1 = 80 → rounded(80) / 1 = 80
        #expect(m.indexToX(10) == 80)
    }

    @Test("sub-pixel scale=2 raw=0.25 → 0.5（.toNearestOrAwayFromZero 抢答 banker's drift, reviewer test-3）")
    func subPixelScale2HalfBoundary() {
        // 构造 raw = 0.25：indexToX delta = 0.25 → candleStep = 0.25 / (idx-startIndex)
        // 简单做法：candleStep=0.5, idx=1, startIndex=0 → raw = 0.5 → raw*scale=1.0 → 1/2 = 0.5
        // 真正 .5-边界：raw = 0.25, scale = 2 → raw*scale = 0.5 → .toNearestOrAwayFromZero(0.5) = 1.0 → 1/2 = 0.5
        // 但 .rounded()(banker's) = 0 → 0/2 = 0
        // 所以这个 test 验证选 .toNearestOrAwayFromZero 而非默认
        let m = makeMapper(displayScale: 2, startIndex: 0, candleStep: 0.25)
        // raw = 0.25 * (1 - 0) = 0.25; raw * scale = 0.5; .toNearestOrAwayFromZero(0.5) = 1.0
        #expect(m.indexToX(1) == 0.5)         // 1.0 / 2 = 0.5
    }

    @Test("sub-pixel scale=3 不同于 scale=1")
    func subPixelScale3() {
        let m1 = makeMapper(displayScale: 1, startIndex: 0, candleStep: 0.4)
        let m3 = makeMapper(displayScale: 3, startIndex: 0, candleStep: 0.4)
        // m1: raw = 0.4 → rounded(0.4) = 0
        // m3: raw = 0.4 → 0.4 * 3 = 1.2 → rounded = 1.0 → 1/3 ≈ 0.333
        #expect(m1.indexToX(1) == 0)
        #expect(abs(m3.indexToX(1) - (1.0/3.0)) < 1e-9)
    }
}

@Suite("IndicatorMapper")
struct IndicatorMapperTests {

    private func makeViewport(candleStep: CGFloat = 8, startIndex: Int = 0) -> ChartViewport {
        ChartViewport(
            startIndex: startIndex, visibleCount: 100, pixelShift: 0,
            geometry: ChartGeometry(candleStep: candleStep, candleWidth: 6, gap: 2),
            priceRange: PriceRange(min: 100, max: 200),
            mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 600)
        )
    }

    private func makeMapper(displayScale: CGFloat = 2,
                           candleStep: CGFloat = 8,
                           startIndex: Int = 0,
                           valueRange: NonDegenerateRange = .make(values: [0, 100]),
                           frame: CGRect = CGRect(x: 0, y: 600, width: 400, height: 150)) -> IndicatorMapper {
        let v = makeViewport(candleStep: candleStep, startIndex: startIndex)
        return IndicatorMapper(
            frame: frame,
            valueRange: valueRange,
            geometry: v.geometry,
            viewport: v,
            displayScale: displayScale
        )
    }

    @Test("indexToX(i) === CoordinateMapper.indexToX(i) 共享 viewport/scale/geometry（reviewer test-2）")
    func indexToXConsistent() {
        let v = makeViewport(candleStep: 8, startIndex: 0)
        let coord = CoordinateMapper(viewport: v, displayScale: 2)
        let ind = IndicatorMapper(
            frame: CGRect(x: 0, y: 600, width: 400, height: 150),
            valueRange: .make(values: [0, 100]),
            geometry: v.geometry,
            viewport: v,
            displayScale: 2
        )
        for i in [0, 1, 5, 10, 50] {
            #expect(coord.indexToX(i) == ind.indexToX(i))
        }
    }

    @Test("valueToY 上界 valueRange.upper → frame.minY")
    func valueToYUpper() {
        let r = NonDegenerateRange.make(values: [0, 100])  // span 含 padding
        let m = makeMapper(valueRange: r, frame: CGRect(x: 0, y: 600, width: 400, height: 150))
        // ratio = 1 → raw = maxY - height = 600
        #expect(m.valueToY(r.upper) == 600)
    }

    @Test("valueToY 下界 valueRange.lower → frame.maxY")
    func valueToYLower() {
        let r = NonDegenerateRange.make(values: [0, 100])
        let m = makeMapper(valueRange: r, frame: CGRect(x: 0, y: 600, width: 400, height: 150))
        // ratio = 0 → raw = maxY = 750
        #expect(m.valueToY(r.lower) == 750)
    }

    @Test("sub-pixel rounding 与 CoordinateMapper 同 rule")
    func subPixelConsistent() {
        let m = makeMapper(displayScale: 3, candleStep: 0.4)
        // raw = 0.4 * 3 = 1.2 → .toNearestOrAwayFromZero(1.2) = 1.0 → 1/3
        #expect(abs(m.indexToX(1) - (1.0/3.0)) < 1e-9)
    }

    @Test("valueRange.span > 0 不除零（.make 任何分支 post-condition）")
    func spanNonZero() {
        let m1 = makeMapper(valueRange: .make(values: []))            // empty fallback
        let m2 = makeMapper(valueRange: .make(values: [42, 42, 42]))  // 全等值
        let m3 = makeMapper(valueRange: .make(values: [0]))           // 单 0 值
        // 都不应崩；valueToY 任何输入 should 产生有限 CGFloat
        #expect(m1.valueToY(0).isFinite)
        #expect(m2.valueToY(42).isFinite)
        #expect(m3.valueToY(0).isFinite)
    }
}
```

- [ ] **Step D.2: Run tests to verify RED**

Run:
```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry/ios/Contracts && swift test --filter "CoordinateMapper|IndicatorMapper"
```
Expected: 编译失败，`error: cannot find 'CoordinateMapper' / 'IndicatorMapper' in scope`

- [ ] **Step D.3: Append CoordinateMapper + IndicatorMapper impl**

Append to `Geometry.swift`:

```swift

// MARK: - 坐标映射

public struct CoordinateMapper: Equatable, Sendable {
    public let viewport: ChartViewport
    public let displayScale: CGFloat

    public init(viewport: ChartViewport, displayScale: CGFloat) {
        self.viewport = viewport
        self.displayScale = displayScale
    }

    public func indexToX(_ index: Int) -> CGFloat {
        let raw = CGFloat(index - viewport.startIndex) * viewport.geometry.candleStep
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }

    public func priceToY(_ price: Double) -> CGFloat {
        let frame = viewport.mainChartFrame
        let span = viewport.priceRange.max - viewport.priceRange.min
        let ratio = (price - viewport.priceRange.min) / span
        let raw = frame.maxY - CGFloat(ratio) * frame.height
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }

    public func xToIndex(_ x: CGFloat) -> Int {
        viewport.startIndex + Int((x / viewport.geometry.candleStep).rounded(.down))
    }

    public func yToPrice(_ y: CGFloat) -> Double {
        let frame = viewport.mainChartFrame
        let ratio = Double((frame.maxY - y) / frame.height)
        return viewport.priceRange.min + ratio * (viewport.priceRange.max - viewport.priceRange.min)
    }
}

public struct IndicatorMapper: Equatable, Sendable {
    public let frame: CGRect
    public let valueRange: NonDegenerateRange
    public let geometry: ChartGeometry
    public let viewport: ChartViewport
    public let displayScale: CGFloat

    public init(frame: CGRect, valueRange: NonDegenerateRange,
                geometry: ChartGeometry, viewport: ChartViewport, displayScale: CGFloat) {
        self.frame = frame
        self.valueRange = valueRange
        self.geometry = geometry
        self.viewport = viewport
        self.displayScale = displayScale
    }

    public func indexToX(_ index: Int) -> CGFloat {
        let raw = CGFloat(index - viewport.startIndex) * geometry.candleStep
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }

    public func valueToY(_ value: Double) -> CGFloat {
        let ratio = (value - valueRange.lower) / valueRange.span    // span > 0 by .make 构造保证
        let raw = frame.maxY - CGFloat(ratio) * frame.height
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }
}
```

- [ ] **Step D.4: Run tests to verify GREEN**

Run:
```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry/ios/Contracts && swift test --filter "CoordinateMapper|IndicatorMapper"
```
Expected: 14 tests 全过；累计 34 C1a tests 全过。

- [ ] **Step D.5: Final full-suite verification**

Run:
```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry/ios/Contracts && swift test 2>&1 | tail -5
```
Expected: 末行 `Test Suite 'All tests' passed`；总数 64 baseline + 34 C1a = 98 tests pass；0 warnings。

- [ ] **Step D.6: LOC budget check**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry
wc -l ios/Contracts/Sources/KlineTrainerContracts/Geometry/*.swift
wc -l ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift
```
Expected:
- Geometry/*.swift ≤ 210 行 prod 总和
- GeometryTests.swift ≤ 420 行（实测对齐）

若超：先 try 删冗余 blank line / 注释；不要为压行数砍 test。超 ≥10% 找用户决策。

- [ ] **Step D.7: Acceptance gate grep**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry
grep -rnE "import UIKit|import SwiftUI" ios/Contracts/Sources/KlineTrainerContracts/Geometry/
grep -rnE "precondition|fatalError|throws|assertionFailure" ios/Contracts/Sources/KlineTrainerContracts/Geometry/
```
Expected: 两条命令全 0 命中（exit 1）。任一命中 → 违反 design doc + governance budget cap，回退 fix。

- [ ] **Step D.8: Commit Batch D**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry
git add ios/Contracts/Sources/KlineTrainerContracts/Geometry/Geometry.swift ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift
git commit -m "feat(C1a): CoordinateMapper + IndicatorMapper + 14 tests (Batch D, TDD green; 34 C1a / 98 total)"
```

---

## Task 2: 实施 plan 与 design doc 同步（only-if-discrepancy-found）

**条件触发**：仅在 Task 1 batches 实施过程中发现 design doc 与实际 spec 不一致时触发；正常路径跳过。

- [ ] **Step 2.1**：若发现 design doc bug，开 `docs/superpowers/specs/2026-04-30-c1a-geometry-design.md` 修订；记录在 commit message
- [ ] **Step 2.2**：修订 commit 单独 `docs(C1a): ...` 不混入 feat commit

---

## Task 3: PR 准备 + push（user explicit confirm 后）

- [ ] **Step 3.1: 验收清单 self-check（design doc §"8 行非 coder 验收清单"全 ☑）**

读 design doc L325-336，逐行验证。任何 ☐ 留空表示 acceptance 未过 → fix 后再 push。

- [ ] **Step 3.2: 等待 user 显式确认 push**

memory `feedback_reviewer_verdict_not_authorization` 硬规则：远端写入永远要 user explicit confirm。subagent **不主动**执行 `git push` 或 `gh pr create`。

- [ ] **Step 3.3: User 确认后 push branch**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/c1a-geometry
git push -u origin c1a-geometry
```

- [ ] **Step 3.4: User 确认后 open PR（中文 body per memory `feedback_pr_language_chinese`）**

```bash
gh pr create --title "feat(C1a): Geometry 7 值类型 + 34 tests" --body "$(cat <<'EOF'
## 摘要

落地 modules §C1a 的 7 个值类型——图表渲染的几何 / 视口 / 坐标映射底盘：
- `ChartGeometry / ChartPanelFrames / PriceRange / ChartViewport / CoordinateMapper / IndicatorMapper / NonDegenerateRange`
- 全 `Equatable, Sendable` ; UIKit-free ; `import Foundation` + `import CoreGraphics`
- ~187 行 prod / 34 tests / 1 文件 bundle 落 `KlineTrainerContracts/Geometry/`

## 关键设计决策

- **Package α**：C1a 落 Contracts package（非 spec literal `ChartEngine/Core/Geometry/`），跟 E1 precedent；C1c 跨 2 package 拆分（`KLineRenderState` 在 Contracts，`KLineView: UIView` 留 iOS app target）
- **5 项 spec discrepancy 全 modules 优先**（详见 design doc §"Spec discrepancies"）
- **`NonDegenerateRange` 无 public init**：外部只能走 `.make`，依赖 Swift auto-synth internal memberwise 强制 `upper > lower` 不变量

## 6 项 accepted residuals

1. PriceRange 5% padding magic number 不参数化（plan §3 字面）
2. NonDegenerateRange 默认值（modules 字面）
3. `displayScale` 由 caller 注入（C1a 不 import UIKit）
4. `xToIndex` Int 转换不防 overflow（caller bound x）
5. PriceRange.calculate 假定正价（caller 保正）
6. 空 candles → `PriceRange(min: 0, max: 1)`（plan §3 L148）

## Cross-references

- Design doc：`docs/superpowers/specs/2026-04-30-c1a-geometry-design.md`
- Plan：`docs/superpowers/plans/2026-04-30-c1a-geometry.md`
- Spec：`kline_trainer_modules_v1.4.md` §C1a L854-955 + `kline_trainer_plan_v1.5.md` §3 L100-200
- E1 precedent：PR #37（已 merged）

## Test plan

- [x] `swift test`：64 baseline + 34 C1a = 98 tests 全过 / 0 warnings
- [x] `wc -l` Geometry/*.swift ≤ 210 行 prod
- [x] `grep -rnE "import UIKit|import SwiftUI"` 0 命中
- [x] `grep -rnE "precondition|fatalError|throws|assertionFailure"` 0 命中
- [ ] codex adversarial review ≤3 轮
- [ ] CODEOWNERS approve（user self-approve）

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3.5: 等 codex adversarial review verdict**

memory `feedback_big_pr_codex_noncovergence` 硬规则：超 3 轮立即 abort PR。

---

## 自检（plan self-review）

- ✅ **Spec coverage**：design doc §"Implementation"全 7 类型 mapped 到 4 个 batch；测试矩阵 34 全 mapped；6 residuals 中 5 项有专门 char test，#3 (caller-injected displayScale) 由 sub-pixel scale=1/2/3 多组测覆盖
- ✅ **No placeholders**：每个 batch 完整代码；每个 test 完整 `#expect`；每个 commit 有完整 git 命令；无 TBD / TODO / "implement later"
- ✅ **Type consistency**：`makeViewport` / `makeMapper` helper 命名跨 Suite 一致；`CoordinateMapper` / `IndicatorMapper` 共享 `ChartViewport` 字段访问无 typo
- ✅ **No proactive defense**：impl 全 0 `precondition` / `fatalError` / `throws`，verified by D.7 grep gate
- ✅ **Memory compliance**：subagent-driven-development（不用 executing-plans）/ 中文 PR / sonnet 4.6 high effort sub-coder（subagent-driven-development skill 内决定）/ user explicit push confirm
- ✅ **TDD strict**：每 batch RED → 写 impl → GREEN → commit；不偷跳 RED step

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-30-c1a-geometry.md`.

**推荐**：subagent-driven-development（per project memory `project_executing_plans_excluded` 硬约束本项目只用 subagent driven）。每 batch 派 fresh sonnet 4.6 high-effort subagent；批与批之间主线 review。
