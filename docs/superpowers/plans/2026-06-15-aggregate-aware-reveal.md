# 聚合感知 reveal 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 渲染「进行中聚合 K 线」时用已揭示 m3 实时合成 partial OHLC/volume（指标 nil、`endGlobalIndex=tick`），消除默认 m60/日线面板的聚合未来泄漏（关闭 reveal RFC 的聚合 HIGH residual）。

**Architecture:** 新增平台无关纯函数 `PartialAggregateCandle.synthesize`（从 m3 合成，start 用 datetime 定位）；`RenderStateBuilder.make` 在 viewport 装配后，若末根可见且进行中（`endGlobalIndex>tick`）则改 base 数组副本替换该根 + 用合成 slice 重算 priceRange 装入 viewport 副本。不动 `makeViewport` 几何 / `currentCandleIndex` / `visibleCandleRange`。

**Tech Stack:** Swift / Swift Testing（`@testable import KlineTrainerContracts`）；host `swift test` + Mac Catalyst build-for-testing。

**收敛设计（spec）：** `docs/superpowers/specs/2026-06-15-aggregate-aware-reveal-design.md`（opus spec-review R1→R2 APPROVE 收敛）。

**基线：** main `bb0d597`（含 reveal 修复）= `1021 tests in 144 suites`（实施时跑确认）。本计划净增 **10** 测（Task1 5 + Task2 5）→ `1031 tests in 145 suites`（+1 suite = PartialAggregateCandle；opus plan-R1 实跑确认）。

---

## File Structure
- **Create** `ios/Contracts/Sources/KlineTrainerContracts/Render/PartialAggregateCandle.swift`：纯函数 `synthesize(original:m3:tick:)`（单一职责、host 全测、无 engine 依赖）。
- **Modify** `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`：`make()` 挂钩合成 + priceRange 重算（不动 `makeViewport`/`currentCandleIndex`）。
- **Create** `ios/Contracts/Tests/KlineTrainerContractsTests/Render/PartialAggregateCandleTests.swift`：纯函数 host 测。
- **Modify** `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`：make() 聚合合成集成测 + base 索引契约断言。
- **Create** `docs/acceptance/2026-06-15-aggregate-aware-reveal.md`：非 coder 验收清单。

---

## Task 1: 合成纯函数 PartialAggregateCandle（TDD）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/PartialAggregateCandle.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/PartialAggregateCandleTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `PartialAggregateCandleTests.swift`：
```swift
// 聚合感知 reveal 合成纯函数 host 测
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("PartialAggregateCandle.synthesize")
struct PartialAggregateCandleTests {

    /// m3 工厂：第 i 根 datetime=i*180、endGlobalIndex==globalIndex==i、OHLC 可控。
    static func m3(_ count: Int,
                   highs: [Int: Double] = [:], lows: [Int: Double] = [:],
                   closes: [Int: Double] = [:], vols: [Int: Int64] = [:]) -> [KLineCandle] {
        (0..<count).map { i in
            // 字段先 hoist 到 typed local（避免 dict-coalescing + 算术挤爆 Swift 类型检查器，opus plan-R1-H）
            let h: Double = highs[i] ?? (Double(i) + 1)
            let lo: Double = lows[i] ?? (Double(i) - 1)
            let cl: Double = closes[i] ?? (Double(i) + 0.5)
            let v: Int64 = vols[i] ?? 100
            return KLineCandle(period: .m3, datetime: Int64(i) * 180,
                               open: Double(i), high: h, low: lo, close: cl, volume: v,
                               amount: 999, ma66: 1, bollUpper: 1, bollMid: 1, bollLower: 1,
                               macdDiff: 1, macdDea: 1, macdBar: 1, globalIndex: i, endGlobalIndex: i)
        }
    }

    /// 聚合根（含未来的 vendor 整根；合成应忽略其 OHLC/指标）。datetime 对齐某根 m3 的 datetime。
    static func agg(period: Period, datetime: Int64, endGlobalIndex: Int) -> KLineCandle {
        KLineCandle(period: period, datetime: datetime,
                    open: 9999, high: 9999, low: -9999, close: 9999, volume: 999_999,
                    amount: 999, ma66: 8, bollUpper: 8, bollMid: 8, bollLower: 8,
                    macdDiff: 8, macdDea: 8, macdBar: 8, globalIndex: nil, endGlobalIndex: endGlobalIndex)
    }

    @Test("多 m3：open=首 / high=max / low=min / close=末 / volume=sum；指标+amount nil；endGlobalIndex=tick")
    func multiM3() {
        // m60 覆盖 m3[0..3]（datetime 0），已揭示到 tick=2 → 成分 m3[0..2]
        let series = Self.m3(12, highs: [1: 50], lows: [2: -50], closes: [2: 7.7], vols: [0: 10, 1: 20, 2: 30])
        let a = Self.agg(period: .m60, datetime: 0, endGlobalIndex: 3)
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 2)
        #expect(s.open == 0)            // m3[0].open
        #expect(s.high == 50)           // max(m3[0..2].high)（m3[1] 注 50）
        #expect(s.low == -50)           // min(m3[0..2].low)（m3[2] 注 -50）
        #expect(s.close == 7.7)         // m3[2].close
        #expect(s.volume == 60)         // 10+20+30
        #expect(s.endGlobalIndex == 2)  // == tick
        #expect(s.period == .m60)
        #expect(s.datetime == 0)
        #expect(s.amount == nil)
        #expect(s.ma66 == nil && s.bollUpper == nil && s.bollMid == nil && s.bollLower == nil)
        #expect(s.macdDiff == nil && s.macdDea == nil && s.macdBar == nil)
        #expect(s.globalIndex == nil)
    }

    @Test("单 m3（start==tick）：成分仅 1 根")
    func singleM3() {
        let series = Self.m3(12)
        let a = Self.agg(period: .m60, datetime: Int64(4) * 180, endGlobalIndex: 7)  // 覆盖 m3[4..7]
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 4)   // 刚揭示第 4 根
        #expect(s.open == 4)            // m3[4]
        #expect(s.close == 4.5)         // m3[4].close
        #expect(s.volume == 100)        // 单根
        #expect(s.endGlobalIndex == 4)
    }

    @Test("datetime 定位 start：predecessor endGlobalIndex clamp 到 0 不影响（R1-H1 killer）")
    func datetimeStartImmuneToClampedPredecessor() {
        // 模拟开局：m60[0] 是首根 in-window，datetime=0 对齐 m3[0]；predecessor（未传）clamp 不参与。
        // 合成 start 必须取 m3[0]，不能因任何 predecessor 偏成 1。
        let series = Self.m3(12, highs: [0: 77])
        let a = Self.agg(period: .m60, datetime: 0, endGlobalIndex: 3)
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 1)
        #expect(s.open == 0)            // m3[0].open（不是 m3[1]）
        #expect(s.high == 77)           // 含 m3[0] 的 high=77 → 证明 start==0
    }

    @Test("聚合 open datetime 早于 m3[0]（pre-window）→ start clamp 到 0")
    func aggOpenBeforeFirstM3() {
        let series = Self.m3(12)        // datetimes 从 0 起
        let a = Self.agg(period: .daily, datetime: -1000, endGlobalIndex: 5)  // open 早于 m3[0]
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 3)
        #expect(s.open == 0)            // partitioningIndex{datetime >= -1000} == 0
        #expect(s.endGlobalIndex == 3)
    }

    @Test("trigger 下 start ≤ tick（assert 不触发，R2-L）")
    func startWithinTick() {
        let series = Self.m3(12)
        let a = Self.agg(period: .m60, datetime: Int64(8) * 180, endGlobalIndex: 11)  // 覆盖 m3[8..11]
        let s = PartialAggregateCandle.synthesize(original: a, m3: series, tick: 9)    // start=8 ≤ 9
        #expect(s.open == 8)
        #expect(s.endGlobalIndex == 9)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter PartialAggregateCandle 2>&1 | tail -15`
Expected: 编译失败 / FAIL —— `PartialAggregateCandle` 未定义。

- [ ] **Step 3: 写最小实现**

创建 `Render/PartialAggregateCandle.swift`：
```swift
// 聚合感知 reveal —— 进行中聚合 K 线 partial 合成
// Spec: docs/superpowers/specs/2026-06-15-aggregate-aware-reveal-design.md
//
// 平台无关纯函数：从已揭示 m3 合成进行中聚合 K 线的 partial OHLC/volume，
// 指标/amount nil（D2：vendor 整根指标含未来、不在端上重算），endGlobalIndex=tick（D3）。

import Foundation

public enum PartialAggregateCandle {
    /// 合成进行中聚合 K 线。
    /// - start = 首个 `datetime >= original.datetime` 的 m3（匹配 backend `[open,nextOpen)` 下界；
    ///   对 pre-window predecessor `endGlobalIndex` clamp 到 0 免疫，spec R1-H1）。
    /// - 前置：`m3` 非空、按 datetime 升序（.m3 连续轴）、`tick < m3.count`；`start <= tick`（trigger 保证，assert 钉死）。
    public static func synthesize(original: KLineCandle, m3: [KLineCandle], tick: Int) -> KLineCandle {
        let start = m3.partitioningIndex { $0.datetime >= original.datetime }
        assert(start <= tick, "PartialAggregateCandle.synthesize: start(\(start)) must be <= tick(\(tick))")
        let constituents = m3[start ... tick]
        return KLineCandle(
            period: original.period,
            datetime: original.datetime,
            open: constituents.first!.open,
            high: constituents.map(\.high).max()!,
            low: constituents.map(\.low).min()!,
            close: constituents.last!.close,
            volume: constituents.reduce(Int64(0)) { $0 + $1.volume },
            amount: nil, ma66: nil,
            bollUpper: nil, bollMid: nil, bollLower: nil,
            macdDiff: nil, macdDea: nil, macdBar: nil,
            globalIndex: nil, endGlobalIndex: tick)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter PartialAggregateCandle 2>&1 | tail -8`
Expected: `5 tests` 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/PartialAggregateCandle.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/PartialAggregateCandleTests.swift
git commit -m "feat(aggregate-reveal): PartialAggregateCandle 合成纯函数（datetime-start + 指标 nil + endGlobalIndex=tick）"
```

---

## Task 2: RenderStateBuilder.make 挂钩合成 + priceRange 重算（TDD）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`（`make()`，当前 :18-43）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`

- [ ] **Step 1: 写失败的集成测试**

在 `RenderStateBuilderTests` struct 末尾（最后一个 `}` 前）追加：
```swift
    // MARK: - 聚合感知 reveal（进行中聚合 K 线 partial 合成；spec 2026-06-15-aggregate-aware-reveal）

    /// m60 上区 engine：m3 driving（12 根，datetime=i*180）+ m60 聚合（sparse ends [3,7,11]，datetime 对齐 m3）。
    @MainActor
    static func aggregateEngine(tick: Int, m60FutureHigh: Double = 9999) -> TrainingEngine {
        let m3 = (0..<12).map { i in
            KLineCandle(period: .m3, datetime: Int64(i) * 180, open: Double(i), high: Double(i) + 1,
                        low: Double(i) - 1, close: Double(i) + 0.5, volume: 100, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil, macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        func m60(_ dtIdx: Int, end: Int) -> KLineCandle {
            KLineCandle(period: .m60, datetime: Int64(dtIdx) * 180, open: 5, high: m60FutureHigh, low: -9999,
                        close: 5, volume: 999_999, amount: nil, ma66: 8, bollUpper: 8, bollMid: 8, bollLower: 8,
                        macdDiff: 8, macdDea: 8, macdBar: 8, globalIndex: nil, endGlobalIndex: end)
        }
        let m60s = [m60(0, end: 3), m60(4, end: 7), m60(8, end: 11)]
        return TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: 11),
            allCandles: [.m3: m3, .m60: m60s],
            maxTick: 11, initialTick: tick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m60, initialLowerPeriod: .m60,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
    }

    @MainActor
    @Test("聚合面板进行中根被 partial 合成：OHLC=partial、指标 nil、endGlobalIndex==tick（aggregate-leak 复现转正）")
    func aggregateInProgressSynthesized() {
        let e = Self.aggregateEngine(tick: 1)
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        let last = rs.visibleCandles.last!
        #expect(last.endGlobalIndex == 1)         // == tick（不再是 vendor 的 3）
        #expect(last.open == 0)                    // m3[0].open（合成）
        #expect(last.high == 2)                    // max(m3[0..1].high)=2，非 vendor 9999（无未来）
        #expect(last.close == 1.5)                 // m3[1].close == 当前价
        #expect(last.ma66 == nil && last.macdDiff == nil)   // 指标 nil
    }

    @MainActor
    @Test("base 索引契约：合成后 visibleCandles.startIndex == viewport.startIndex（R1-H3）")
    func synthesisPreservesBaseIndex() {
        let e = Self.aggregateEngine(tick: 1)
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rs.visibleCandles.startIndex == rs.viewport.startIndex)
    }

    @MainActor
    @Test("Y 轴不泄漏：priceRange 只反映已揭示 partial，不含 vendor 未来 high（R1-H2）")
    func priceRangeExcludesFuture() {
        let e = Self.aggregateEngine(tick: 1, m60FutureHigh: 9999)
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        // 已揭示 m3[0..1].high 上界=2 → priceRange.max 远小于 vendor 9999
        #expect(rs.viewport.priceRange.max < 100)
    }

    @MainActor
    @Test("m3 驱动面板：currentIdx 那根 endGlobalIndex==tick → 不合成（原根原样）")
    func m3PanelNotSynthesized() {
        // m3 上区：currentIdx 那根 endGlobalIndex==tick，不进合成分支
        let m3 = (0..<200).map { i in
            KLineCandle(period: .m3, datetime: Int64(i) * 180, open: 10, high: 11, low: 9, close: 10 + Double(i) * 0.1,
                        volume: 1000, amount: nil, ma66: 7, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: i, endGlobalIndex: i)
        }
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: 199),
            allCandles: [.m3: m3], maxTick: 199, initialTick: 150,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        let last = rs.visibleCandles.last!
        #expect(last.endGlobalIndex == 150)       // currentIdx==tick，原根
        #expect(last.ma66 == 7)                    // 原指标保留（未被 nil 合成）
    }

    @MainActor
    @Test("无未来不变量：聚合面板所有可见根 endGlobalIndex ≤ tick")
    func allVisibleWithinTick() {
        for t in [0, 1, 3, 5, 9, 11] {
            let e = Self.aggregateEngine(tick: t)
            let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
            for c in rs.visibleCandles {
                #expect(c.endGlobalIndex <= t, "tick=\(t) 可见根 endGlobalIndex=\(c.endGlobalIndex) > tick")
            }
        }
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests 2>&1 | tail -25`
Expected: `aggregateInProgressSynthesized`（last.endGlobalIndex 期望 1 实得 3 等）、`priceRangeExcludesFuture`、`allVisibleWithinTick` **FAIL**（当前 make 未合成、聚合泄漏）；`synthesisPreservesBaseIndex` 当前实得 startIndex==0 也可能 FAIL（视实现）；`m3PanelNotSynthesized` PASS（regression 基准）。

- [ ] **Step 3: 改 make() 实现合成挂钩**

`RenderStateBuilder.swift` 把 `make()`（当前 :18-43）整体替换为：
```swift
    @MainActor
    public static func make(engine: TrainingEngine, panel: PanelId, bounds: CGRect,
                            crosshair: CGPoint? = nil) -> KLineRenderState {
        let panelState = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
        let candles = engine.allCandles[panelState.period] ?? []
        guard !candles.isEmpty, bounds.width > 0, bounds.height > 0 else { return .empty }
        let tick = engine.tick.globalTickIndex
        let viewport = makeViewport(panelState: panelState, candles: candles, tick: tick, bounds: bounds)
        // 聚合感知 reveal（spec 2026-06-15-aggregate-aware-reveal）：进行中聚合 K 线（可见且 endGlobalIndex>tick）
        // 用已揭示 m3 partial 合成；改 base 数组副本保 base 索引（R1-H3）+ 用合成 slice 重算 priceRange（R1-H2）。
        var renderViewport = viewport
        var slice = candles[viewport.startIndex ..< viewport.startIndex + viewport.visibleCount]
        let currentIdx = currentCandleIndex(candles: candles, tick: tick)
        let lastVisibleIdx = viewport.startIndex + viewport.visibleCount - 1
        if lastVisibleIdx == currentIdx, candles[currentIdx].endGlobalIndex > tick,
           let m3 = engine.allCandles[.m3], tick < m3.count {
            var arr = candles
            arr[currentIdx] = PartialAggregateCandle.synthesize(original: candles[currentIdx], m3: m3, tick: tick)
            slice = arr[viewport.startIndex ..< viewport.startIndex + viewport.visibleCount]
            renderViewport = ChartViewport(
                startIndex: viewport.startIndex, visibleCount: viewport.visibleCount,
                pixelShift: viewport.pixelShift, geometry: viewport.geometry,
                priceRange: PriceRange.calculate(from: slice), mainChartFrame: viewport.mainChartFrame)
        }
        // C3-C6 渲染收口（modules L1443-1452 字面）：volume 含 0 下界、macd 全 nil/零 fallback。
        let volumeRange = NonDegenerateRange.make(
            values: [0.0] + slice.map { Double($0.volume) }, fallback: 0.0...1.0)
        let macdRange = NonDegenerateRange.make(
            values: slice.flatMap { [$0.macdDiff, $0.macdDea, $0.macdBar].compactMap { $0 } },
            fallback: -0.001...0.001)
        return KLineRenderState(
            panel: panelState,
            frames: ChartPanelFrames.split(in: bounds),
            viewport: renderViewport,
            visibleCandles: slice,
            volumeRange: volumeRange,
            macdRange: macdRange,
            markers: engine.markers,
            drawings: engine.drawings.filter { $0.panelPosition == (panel == .upper ? 0 : 1) },
            crosshairPoint: crosshair)
    }
```
（仅 `make` 改：新增合成分支 + `viewport→renderViewport`、`let slice→var slice`；`makeViewport`/`currentCandleIndex`/其余函数**不动**。）

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests 2>&1 | tail -8`
Expected: 全 PASS（5 新聚合测 + 既有 reveal/几何测全绿）。

- [ ] **Step 5: 跑全量 host 测试**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `Test run with 1031 tests in 145 suites passed`，`0 failures`（1021 baseline + 5 Task1 + 5 Task2；suite +1 为 PartialAggregateCandle）。**注**：`TrainingEngine.preview()` 上区为 .m60、tick 0 → 合成会 fire（makeAssembles/equalityPrecondition/crosshair* 仍 PASS：其断言不探末根 OHLC/指标，量/macd range 仍有效）。若有非聚合测失败 → 停下排查（勿改无关测试凑绿）。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "feat(aggregate-reveal): make() 合成进行中聚合 K 线 + priceRange 重算（base 索引契约 + 无未来不变量）"
```

---

## Task 3: 验收清单 + 关闭 residual + 最终验证

**Files:**
- Create: `docs/acceptance/2026-06-15-aggregate-aware-reveal.md`

- [ ] **Step 1: 写非 coder 验收清单**

创建 `docs/acceptance/2026-06-15-aggregate-aware-reveal.md`：
```markdown
# 验收清单 — 聚合感知 reveal（进行中聚合 K 线 partial 合成）

**交付物：** `PartialAggregateCandle.synthesize` 纯函数 + `RenderStateBuilder.make` 合成挂钩（base 索引契约 + priceRange 重算）= 消除聚合面板（默认 m60/日线）进行中 K 线未来泄漏。设计经 opus 4.8 xhigh spec-review R1→R2 APPROVE 收敛；计划经 opus 4.8 xhigh 对抗评审收敛；整体 opus + codex:adversarial-review 收敛。关闭 reveal RFC（PR #113）聚合 HIGH residual。

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | `1031 tests in 145 suites passed`，`0 failures` | ☐ |
| 2 | `git diff origin/main...HEAD --stat -- ios/` | 改动集 ⊆ {PartialAggregateCandle.swift(新), RenderStateBuilder.swift, PartialAggregateCandleTests.swift(新), RenderStateBuilderTests.swift}；无 .sql/schema/workflow/CONTRACT_VERSION | ☐ |
| 3 | `cd ios/Contracts && swift test --filter allVisibleWithinTick 2>&1 \| tail -2` | PASS（聚合面板跨 tick 所有可见根 endGlobalIndex≤tick，无未来） | ☐ |
| 4 | `grep -n "PartialAggregateCandle.synthesize" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift; echo rc=$?` | 命中 `rc=0`（合成挂钩已落地） | ☐ |
| 5 | Mac Catalyst CI：PR checks 页查 `Mac Catalyst build-for-testing on macos-15` | SUCCESS | ☐ |
| 6 | app-target CI：PR checks 页查 app build required check | SUCCESS | ☐ |

## 运行时 runbook（user device/sim 执行）

| # | Action（iPad mini 7 或 Catalyst） | Expected | Pass/Fail |
|---|---|---|---|
| R1 | 训练中观察**非推进面板**（如按下区推进时看上区 m60） | 最新一根聚合 K 线"正在形成"（随每步长高/变体），**不**提前显示完整未来形态 | ☐ |
| R2 | 训练开局聚合面板 | 进行中根即有 partial 实体（**非空白**） | ☐ |
| R3 | 进行中聚合根 | **无** MA66/BOLL/MACD 点（指标线终止在上一根已完成根） | ☐ |
| R4（cosmetic） | 某根聚合 K 线走完瞬间 | 肉眼无明显 OHLC / 量柱跳变（真实数据一致性；spec D6） | ☐ |

## Residuals
- 关闭 reveal RFC（PR #113）聚合 HIGH residual：本 RFC 已根治。
- D6 完成跳变：vendor 各周期独立源，理论一帧轻微 OHLC/量变化（真实数据 close 连续，因当前价=m3 close）；列 R4 device 验收。
```

- [ ] **Step 2: 最终验证（host + Catalyst）**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `1031 tests in 145 suites passed`，`0 failures`。

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 3: Commit**

```bash
git add docs/acceptance/2026-06-15-aggregate-aware-reveal.md
git commit -m "docs(aggregate-reveal): 验收清单 + device runbook + 关闭 reveal 聚合 residual"
```

---

## Self-Review（writing-plans 自查）
1. **Spec coverage：** §二 合成公式 → Task 1；§四 make 挂钩 + base 索引 + priceRange 重算 → Task 2；§五 测试（合成纯函数 + 集成 + 无未来 + m3 no-op）→ Task 1/2；§六 验收 + 关 residual → Task 3。D1-D7 + R1/R2 修全覆盖（datetime-start Task1 / priceRange 重算 + base 索引 Task2 / start≤tick assert Task1）。多面板组合（R1-M1）由 `allVisibleWithinTick` 跨 tick + 既有双面板测覆盖核心路径；weekly/monthly 极粗跨度数学同 m60（合成函数 period-agnostic），不另造 fixture（YAGNI，纯函数已测大跨度逻辑）。
2. **Placeholder scan：** 无 TBD/TODO；每步含完整 Swift + 命令 + 期望。
3. **Type consistency：** `PartialAggregateCandle.synthesize(original:m3:tick:)` 签名 Task1 定义、Task2 调用一致；`ChartViewport(startIndex:visibleCount:pixelShift:geometry:priceRange:mainChartFrame:)` 与源 memberwise init 一致；`KLineCandle` init 字段顺序与源一致；`currentCandleIndex`/`makeViewport`/`PriceRange.calculate` 复用既有签名。

## 治理
- 评审通道：`codex:adversarial-review`（配额恢复优先 codex；耗尽 fallback opus 4.8 xhigh）+ Catalyst + app-build。
- phase_delivery：true；acceptance = host 合成/不变量测 + device runbook。不 claim 行为中性（明为聚合面板渲染行为修正）。
