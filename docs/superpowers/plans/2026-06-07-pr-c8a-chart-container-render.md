# C8a ChartContainerView 渲染路径 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用平台无关 `RenderStateBuilder`（视口几何 + buildRenderState）+ 薄 `ChartContainerView`（UIViewRepresentable）把 `TrainingEngine` 运行时状态桥接成 `KLineView` 可渲染的 `KLineRenderState`（Wave 2 顺位 7 上半 C8a；渲染路径）。

**Architecture:** 三层——`RenderStateBuilder`（无 UIKit 纯静态函数，host 全量单测，C8b H1 handler 复用 `makeViewport`/`visibleCandleRange`）→ `KLineRenderState`（Wave 0 冻结值类型）→ `ChartContainerView`（`#if canImport(UIKit)` UIKit glue，仅 Catalyst 编译验证）。视口几何 spec 无公式，本 PR 用固定 `defaultVisibleCount=80` 分母 + 条件锚定（数据足够锁物理右缘，不足左对齐填充）+ offset→startIndex/pixelShift 分解（边界饱和 pixelShift=0），标注 Wave 2 占位。

**Tech Stack:** Swift 6 / Swift Testing（`import Testing`）/ CoreGraphics / SwiftUI（UIViewRepresentable，仅 UIKit 平台）/ SwiftPM（KlineTrainerContracts 模块）。

**设计依据:** `docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md`（opus 4.8 xhigh 设计 review 4 轮收敛 APPROVE）。

---

## Task 0：评审策略前置（Wave 2 outline §五 Task 0；非编码）

- [ ] **Step 1: 锁定本 PR 评审通道（写入 PR 描述 / 不改代码）**

本 PR 全程评审通道（user 2026-06-07 明确）：
- **plan-stage**：Claude **Opus 4.8 xhigh** 对抗 review 到收敛（非 codex；codex 周配额 + 本仓 iOS PR required check 为 Catalyst build）。
- **branch-diff**：实现完成后再一道 Opus 4.8 xhigh 对抗 review 到收敛。
- **超 5 轮不收敛** → escalate user（attestation residual + admin merge 路径，**不绕 required checks**）。
- **CI required check**：`Mac Catalyst build-for-testing on macos-15` 必须真过（本地 `swift test` 绿 ≠ CI 绿，per `feedback_swift_local_toolchain_blindspot`）。
- **merge ceremony**：worktree 分支 attest 写 worktree-local ledger；主仓 `gh pr create`/`merge` 被 guard 拦 → user 真终端跑（per `feedback_worktree_local_ledger_user_tty_pr`）。

无代码改动。Task 0 仅记录，进 Task 1。

---

## File Structure

| 文件 | 责任 | 平台 |
|---|---|---|
| **Create** `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift` | 视口几何（makeViewport）+ buildRenderState（make）+ visibleCandleRange（C8b 复用）；纯静态函数 | 全平台（无 UIKit） |
| **Create** `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift` | UIViewRepresentable 薄 glue：makeUIView→KLineView，updateUIView→builder | `#if canImport(UIKit)` |
| **Create** `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift` | host 全量单测：几何/锚定/offset/值域/空/Equatable 前提/perf smoke | 全平台（macOS host 跑） |
| **Create** `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewCompileTests.swift` | ChartContainerView 编译反射（Catalyst gate；mirror KLineViewCompileTests） | `#if canImport(UIKit)` |

**消费的冻结契约（只读，不改）：** `KLineRenderState`(9 字段 init + `.empty`)、`ChartViewport`/`ChartGeometry`/`ChartPanelFrames.split(in:)`/`NonDegenerateRange.make(values:fallback:)`/`PriceRange.calculate(from:)`（Geometry.swift）、`PanelViewState`(period/interactionMode/visibleCount/offset:CGFloat/revision)、`KLineCandle`(period/endGlobalIndex:Int/globalIndex:Int?/volume:Int64/macd*:Double?/close...)、`PanelId`(.upper/.lower)、`RandomAccessCollection.partitioningIndex(where:)`、`TrainingEngine`(public 只读 tick/upperPanel/lowerPanel/allCandles/markers/drawings + `make`/`preview()` + `@testable` internal init)。

---

## Task 1：`makeViewport` 几何 + 条件锚定（offset=0 路径）+ priceRange

实现视口几何（candleStep/candleWidth/gap）、当前 candle 三分流锚定（物理右缘 / 早期 tick / 短聚合面板）、可见切片与 priceRange。**本 task 实现 offset=0 行为**（startIndex = clamp(baseStartIndex)，pixelShift=0）；Task 2 再泛化非零 offset。

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`

- [ ] **Step 1: 写失败测试（几何 + 锚定三分流 + priceRange + 切片）**

创建 `RenderStateBuilderTests.swift`：

```swift
// Kline Trainer Swift Contracts — C8a RenderStateBuilder host tests
// Spec: docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md
import Testing
import Foundation          // Date()（perf smoke）；@testable import 不透传 Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("RenderStateBuilder 视口几何 + 装配")
struct RenderStateBuilderTests {

    /// 连续轴 candle 工厂：第 i 根 endGlobalIndex==i（满足 partitioningIndex 单调）。
    static func candles(period: Period, count: Int,
                        volume: Int64 = 1000,
                        macd: Bool = false) -> [KLineCandle] {
        (0..<count).map { i in
            KLineCandle(
                period: period, datetime: Int64(i) * 60,
                open: 10, high: 11, low: 9, close: 10 + Double(i) * 0.1,
                volume: volume, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: macd ? 0.2 : nil, macdDea: macd ? 0.1 : nil, macdBar: macd ? 0.1 : nil,
                globalIndex: i, endGlobalIndex: i)
        }
    }

    static func panel(period: Period = .m3, offset: CGFloat = 0) -> PanelViewState {
        PanelViewState(period: period, interactionMode: .autoTracking,
                       visibleCount: 0, offset: offset, revision: 0)
    }

    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    // split: mainChart width=800 height=360；candleStep=800/80=10；candleWidth=7；gap=3

    @Test("几何：固定 80 分母 → candleStep/candleWidth/gap")
    func geometry() {
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 10) < 1e-9)
        #expect(abs(vp.geometry.candleWidth - 7) < 1e-9)
        #expect(abs(vp.geometry.gap - 3) < 1e-9)
        #expect(abs(vp.mainChartFrame.width - 800) < 1e-9)
        #expect(abs(vp.mainChartFrame.height - 360) < 1e-9)
    }

    @Test("锚定(a)：count>=80 且 currentIdx>=79 → 物理右缘（slot 79）")
    func anchorPhysicalRightEdge() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 150, bounds: Self.bounds)
        // currentIdx=150, visibleCount=80, baseStartIndex=150-79=71
        #expect(vp.startIndex == 71)
        #expect(vp.visibleCount == 80)
        #expect(150 - vp.startIndex == 79)  // 当前 candle 落最右物理 slot
    }

    @Test("锚定(b)：count>=80 但 currentIdx<79（早期 tick）→ startIndex==0，slot=currentIdx")
    func anchorEarlyTick() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 10, bounds: Self.bounds)
        // currentIdx=10, baseStartIndex=10-79=-69 → clamp 0
        #expect(vp.startIndex == 0)
        #expect(vp.visibleCount == 80)
        #expect(10 - vp.startIndex == 10)   // slot 10（左区，非右缘）
    }

    @Test("锚定(c)：count<80 且 currentIdx==count-1（短聚合面板最新根）→ startIndex==0，非物理右缘")
    func anchorShortHistory() {
        let cs = Self.candles(period: .m60, count: 30)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(period: .m60), candles: cs, tick: 29, bounds: Self.bounds)
        // currentIdx=29, visibleCount=min(80,30)=30, baseStartIndex=29-29=0, upperBound=0
        #expect(vp.startIndex == 0)
        #expect(vp.visibleCount == 30)
        #expect(29 - vp.startIndex == 29)       // 最右被绘制 slot
        #expect(29 < RenderStateBuilder.defaultVisibleCount - 1)  // 29 < 79 → 非物理右缘
        #expect(abs(vp.geometry.candleStep - 10) < 1e-9)          // candleStep 仍 800/80（固定分母）
    }

    @Test("priceRange：用可见切片经 PriceRange.calculate（含 5% 扩展）")
    func priceRange() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 150, bounds: Self.bounds)
        let slice = cs[vp.startIndex ..< vp.startIndex + vp.visibleCount]
        let expected = PriceRange.calculate(from: slice)
        #expect(vp.priceRange == expected)
    }

    @Test("聚合面板锚定用面板自身 period（非 .m3）：.m60 锚 ≠ 误用 .m3 锚")
    func aggregatePanelAnchorsOwnPeriod() {
        // .m60 面板 candles 各 endGlobalIndex=i；tick=100 → currentIdx=clamp(first>=100, count-1)
        let m60 = Self.candles(period: .m60, count: 50)   // endGlobalIndex 0..49
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(period: .m60), candles: m60, tick: 100, bounds: Self.bounds)
        // first endGlobalIndex>=100 不存在 → partitioningIndex=count=50 → currentIdx=min(50,49)=49
        #expect(vp.startIndex == 0)          // count=50<80 → startIndex 0
        #expect(vp.visibleCount == 50)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests`
Expected: 编译失败 `cannot find 'RenderStateBuilder' in scope`。

- [ ] **Step 3: 实现 `RenderStateBuilder.makeViewport`（offset=0 路径）+ 常量**

创建 `RenderStateBuilder.swift`：

```swift
// Kline Trainer Swift Contracts — C8a RenderStateBuilder（视口几何 + buildRenderState）
// Spec: kline_trainer_modules_v1.4.md §C8 (L1409-1467) + §C1a 几何 (L887-927)
//     + kline_trainer_plan_v1.5.md §坐标映射 (L104-233)
// Design: docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md
//
// 平台无关（无 UIKit）：host 全量单测 + C8b H1 handler 复用 makeViewport/visibleCandleRange。
// 视口几何 spec 无公式 → 本 PR 固定 defaultVisibleCount=80 分母 + 条件锚定 + offset 分解（Wave 2 占位；
// pinch 缩放改 visibleCount 属 Wave 3）。

import Foundation
import CoreGraphics

public enum RenderStateBuilder {
    /// 渲染常量（spec 无公式，本 PR 占位）。pinch 缩放改 visibleCount 属 Wave 3/C8b。
    static let defaultVisibleCount = 80
    static let candleWidthRatio: CGFloat = 0.7

    /// 视口几何推导（唯一拥有 startIndex/pixelShift 装配的函数；make 与 visibleCandleRange 都经它）。
    /// **前置约束**：`candles` 非空、`bounds.width > 0`（调用方 make/visibleCandleRange 已守 .empty/空）。
    /// Task 1：offset=0 路径（startIndex=clamp(baseStartIndex)，pixelShift=0）。Task 2 泛化非零 offset。
    static func makeViewport(panelState: PanelViewState, candles: [KLineCandle],
                             tick: Int, bounds: CGRect) -> ChartViewport {
        let mainFrame = ChartPanelFrames.split(in: bounds).mainChart
        let count = candles.count
        let visibleCount = min(defaultVisibleCount, count)

        // 几何：固定 80 分母（早期数据少时 candle 宽度稳定，count<80 左对齐填充）。
        let candleStep = mainFrame.width / CGFloat(defaultVisibleCount)
        let geometry = ChartGeometry(candleStep: candleStep,
                                     candleWidth: candleStep * candleWidthRatio,
                                     gap: candleStep - candleStep * candleWidthRatio)

        // 当前 candle 索引：面板自身 period 中首个 endGlobalIndex>=tick（超末根取末根）。
        // 仅谓词同 E5 currentPrice；序列为面板自身 period（聚合面板必须在自身序列定位，勿改读 .m3）。
        let rawIdx = candles.partitioningIndex { $0.endGlobalIndex >= tick }
        let currentIdx = min(rawIdx, count - 1)

        // autoTracking 锚定：当前 candle 落最右被绘制 slot（baseStartIndex 可能 <0，下方 clamp）。
        let baseStartIndex = currentIdx - (visibleCount - 1)
        let upperBound = max(0, count - visibleCount)
        let startIndex = min(max(baseStartIndex, 0), upperBound)   // offset=0：pixelShift 恒 0
        let pixelShift: CGFloat = 0

        let sliceEnd = min(startIndex + visibleCount, count)
        let slice = candles[startIndex ..< sliceEnd]
        return ChartViewport(startIndex: startIndex, visibleCount: slice.count,
                             pixelShift: pixelShift, geometry: geometry,
                             priceRange: PriceRange.calculate(from: slice),
                             mainChartFrame: mainFrame)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests`
Expected: PASS（6 测试：geometry / 3 锚定 / priceRange / aggregate）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "feat(c8a): RenderStateBuilder.makeViewport 几何 + 条件锚定（offset=0）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：`makeViewport` 泛化非零 offset（wholeShift/pixelShift + 边界饱和）

把 Task 1 的 offset=0 路径泛化为 freeScrolling：用 `panelState.offset` 算整根位移 + 亚像素余量，边界饱和（startIndex 落 0 或 upperBound）时 pixelShift=0。**C8a 运行期 offset 恒 0，本数学为 C8b 复用而现在实现 + host 测。**

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`（makeViewport offset 段）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（加 offset 测试）

- [ ] **Step 1: 写失败测试（offset 分解 + 两类边界饱和）**

在 `RenderStateBuilderTests` 内追加：

```swift
    // count=200, tick=150 → baseStartIndex=71, candleStep=10, upperBound=120
    @Test("offset：中段正 offset → wholeShift + pixelShift 余量")
    func offsetMidScroll() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 25), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=floor(25/10)=2 → startIndex=71-2=69（非边界）；pixelShift=25-20=5
        #expect(vp.startIndex == 69)
        #expect(abs(vp.pixelShift - 5) < 1e-9)
    }

    @Test("offset：负 offset → 余量仍落 [0,candleStep)")
    func offsetNegative() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -25), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=floor(-2.5)=-3 → startIndex=71-(-3)=74；pixelShift=-25-(-30)=5
        #expect(vp.startIndex == 74)
        #expect(vp.pixelShift >= 0 && vp.pixelShift < 10)
        #expect(abs(vp.pixelShift - 5) < 1e-9)
    }

    @Test("饱和(顶过左界)：offset 把 startIndex clamp 到 0 → pixelShift=0")
    func saturateLeftClamped() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 750), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=75 → unclamped=71-75=-4 → clamp 0
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
    }

    @Test("饱和(顶过右界)：offset 把 startIndex clamp 到 upperBound → pixelShift=0")
    func saturateRightClamped() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -600), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=floor(-60)=-60 → unclamped=71+60=131 → clamp upperBound 120
        #expect(vp.startIndex == 120)
        #expect(vp.pixelShift == 0)
    }

    @Test("饱和(F3：恰落左界 + 非零余量，clamp 不改值)→ pixelShift=0")
    func saturateLeftExactBoundary() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 715), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=71 → unclamped=71-71=0（==下界，clamp 不改）；余量=715-710=5 → 按落位归 0
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
    }

    @Test("饱和(F3：恰落右界 + 非零余量，clamp 不改值)→ pixelShift=0")
    func saturateRightExactBoundary() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -485), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=floor(-48.5)=-49 → unclamped=71+49=120（==upperBound，clamp 不改）；余量=-485-(-490)=5 → 0
        #expect(vp.startIndex == 120)
        #expect(vp.pixelShift == 0)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests`
Expected: 新 6 测试 FAIL（Task 1 实现 pixelShift 恒 0、startIndex 不读 offset，中段/负 offset 断言不符）。

- [ ] **Step 3: 实现 offset 分解（替换 makeViewport 的 startIndex/pixelShift 段）**

把 Task 1 的：

```swift
        let startIndex = min(max(baseStartIndex, 0), upperBound)   // offset=0：pixelShift 恒 0
        let pixelShift: CGFloat = 0
```

替换为：

```swift
        // offset 分解（C8b freeScrolling 复用；C8a offset 恒 0 时 wholeShift=0/pixelShift=0）。
        // 符号契约（CoordinateMapper Geometry.swift L136）：pixelShift>0 = candles 右移。
        let wholeShift = Int((panelState.offset / candleStep).rounded(.down))   // floor
        let startIndex = min(max(baseStartIndex - wholeShift, 0), upperBound)
        // 余量 ∈ [0,candleStep)；按 startIndex *落位* 判饱和（非按 clamp 是否改值，F3）：
        // 处硬边界（最老 startIndex==0 / 最新 ==upperBound，无更多可揭示）→ pixelShift=0（边缘钉面板边）。
        var pixelShift = panelState.offset - CGFloat(wholeShift) * candleStep
        if startIndex == 0 || startIndex == upperBound { pixelShift = 0 }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests`
Expected: PASS（Task 1 的 6 + Task 2 的 6 = 12 测试）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "feat(c8a): makeViewport 泛化非零 offset + 边界饱和 pixelShift=0

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：`make`（buildRenderState 装配）+ `visibleCandleRange`（C8b 复用）

实现完整 `KLineRenderState` 装配（viewport + 可见切片 + volumeRange/macdRange 经 `NonDegenerateRange.make` + 透传 markers/drawings + crosshair nil）+ 空/退化守卫；`visibleCandleRange` 委托 makeViewport。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`（加 `make` + `visibleCandleRange`）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（加装配 + 守卫 + 复用测试）

- [ ] **Step 1: 写失败测试（装配 + 值域 fallback + 守卫 + visibleCandleRange + Equatable 前提）**

追加：

```swift
    @MainActor
    @Test("make：preview 引擎装配完整 renderState（透传 markers/drawings、crosshair nil）")
    func makeAssembles() {
        let engine = TrainingEngine.preview()
        let rs = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        #expect(rs.panel.period == engine.upperPanel.period)
        #expect(rs.crosshairPoint == nil)
        #expect(rs.markers == engine.markers)
        #expect(rs.drawings == engine.drawings)
        #expect(rs.frames == ChartPanelFrames.split(in: Self.bounds))
        #expect(!rs.visibleCandles.isEmpty)
        // 值域来自真实 make（F4：直接验 rs.* 而非仅 NonDegenerateRange 约定）：
        // preview .m60 candles macd 全 nil → macdRange 走 fallback；volume 含 0 下界。
        #expect(rs.volumeRange.lower < rs.volumeRange.upper)
        #expect(rs.macdRange.lower < rs.macdRange.upper)
        #expect(rs.volumeRange.lower <= 0)   // [0.0]+ 保证下界 ≤ 0
    }

    @Test("值域 fallback 约定（contract characterization；make 内部同款调用）")
    func valueRangeContract() {
        // 表征 NonDegenerateRange.make 的 fallback 不变量（make 依赖它；非 exercise make 本身）。
        let macd = NonDegenerateRange.make(values: [], fallback: -0.001...0.001)
        #expect(macd.lower < macd.upper)
        let vol = NonDegenerateRange.make(values: [0.0] + [Double](repeating: 0, count: 5),
                                          fallback: 0.0...1.0)
        #expect(vol.lower < vol.upper)
    }

    @MainActor
    @Test("守卫：bounds==.zero → .empty")
    func emptyBoundsGuard() {
        let engine = TrainingEngine.preview()
        let rs = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: .zero)
        #expect(rs == KLineRenderState.empty)
    }

    @MainActor
    @Test("守卫：zero-height bounds → .empty")
    func zeroHeightGuard() {
        let engine = TrainingEngine.preview()
        let rs = RenderStateBuilder.make(engine: engine, panel: .upper,
                                         bounds: CGRect(x: 0, y: 0, width: 800, height: 0))
        #expect(rs == KLineRenderState.empty)
    }

    @Test("visibleCandleRange 委托 makeViewport（同 startIndex..<+visibleCount）")
    func visibleRangeDelegates() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 150, bounds: Self.bounds)
        let range = RenderStateBuilder.visibleCandleRange(
            panelState: Self.panel(), candles: cs, tick: 150, bounds: Self.bounds)
        #expect(range == vp.startIndex ..< vp.startIndex + vp.visibleCount)
    }

    @Test("visibleCandleRange 空 candles → 0..<0（不崩）")
    func visibleRangeEmpty() {
        let range = RenderStateBuilder.visibleCandleRange(
            panelState: Self.panel(), candles: [], tick: 0, bounds: Self.bounds)
        #expect(range == 0..<0)
    }

    @MainActor
    @Test("Equatable 短路*前提*：同 engine 状态两次 make → 结果 ==（host 仅证前提，didSet 抑制属 device）")
    func equalityPrecondition() {
        let engine = TrainingEngine.preview()
        let a = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        let b = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        #expect(a == b)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests`
Expected: 新测试 FAIL（`make`/`visibleCandleRange` 不存在）。

- [ ] **Step 3: 实现 `make` + `visibleCandleRange`（追加到 RenderStateBuilder）**

在 `makeViewport` 之前（或之后）追加到 `enum RenderStateBuilder`：

```swift
    /// 主入口：装配完整 KLineRenderState。空 candle / bounds.width 或 height <=0 → .empty。
    /// 不取 displayScale（renderState 无该字段；亚像素对齐在 KLineView.draw 用 traitCollection.displayScale）。
    @MainActor
    public static func make(engine: TrainingEngine, panel: PanelId, bounds: CGRect) -> KLineRenderState {
        let panelState = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
        let candles = engine.allCandles[panelState.period] ?? []
        guard !candles.isEmpty, bounds.width > 0, bounds.height > 0 else { return .empty }
        let viewport = makeViewport(panelState: panelState, candles: candles,
                                    tick: engine.tick.globalTickIndex, bounds: bounds)
        let slice = candles[viewport.startIndex ..< viewport.startIndex + viewport.visibleCount]
        // C3-C6 渲染收口（modules L1443-1452 字面）：volume 含 0 下界、macd 全 nil/零 fallback。
        let volumeRange = NonDegenerateRange.make(
            values: [0.0] + slice.map { Double($0.volume) }, fallback: 0.0...1.0)
        let macdRange = NonDegenerateRange.make(
            values: slice.flatMap { [$0.macdDiff, $0.macdDea, $0.macdBar].compactMap { $0 } },
            fallback: -0.001...0.001)
        return KLineRenderState(
            panel: panelState,
            frames: ChartPanelFrames.split(in: bounds),
            viewport: viewport,
            visibleCandles: slice,
            volumeRange: volumeRange,
            macdRange: macdRange,
            markers: engine.markers,
            drawings: engine.drawings,
            crosshairPoint: nil)   // 长按十字光标属 C8b
    }

    /// C8b H1 handler 复用：当前可见 candle 索引半开区间。委托 makeViewport 单一真相。
    /// 〔C8b 调用面 provisional〕：handler 在 animator.stop() 后取当时 engine 的 panelState（offset 冻结）
    /// + candles + tick + bounds 调本函数；若 C8b 实测签名不足按 C8b 自有 review 调整，不回改 C8a 数学。
    public static func visibleCandleRange(panelState: PanelViewState, candles: [KLineCandle],
                                          tick: Int, bounds: CGRect) -> Range<Int> {
        guard !candles.isEmpty, bounds.width > 0 else { return 0..<0 }
        let vp = makeViewport(panelState: panelState, candles: candles, tick: tick, bounds: bounds)
        return vp.startIndex ..< vp.startIndex + vp.visibleCount
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests`
Expected: PASS（12 + 7 = 19 测试）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "feat(c8a): RenderStateBuilder.make 装配 + visibleCandleRange 复用 + 守卫

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：`ChartContainerView`（UIKit glue）+ 编译反射 + perf smoke

实现 `UIViewRepresentable` 薄桥接（仅 UIKit 平台）+ Catalyst 编译反射测试（mirror KLineViewCompileTests）+ host perf smoke（非权威）。

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewCompileTests.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（加 perf smoke）

- [ ] **Step 1: 写失败测试（perf smoke，host）**

在 `RenderStateBuilderTests` 追加（host 可跑，纯函数 makeViewport）：

```swift
    @Test("perf smoke（非权威）：5000 根 makeViewport 装配开销")
    func perfSmoke() {
        let cs = Self.candles(period: .m3, count: 5000)
        let panel = Self.panel()
        let start = Date()
        for _ in 0..<100 {
            _ = RenderStateBuilder.makeViewport(panelState: panel, candles: cs,
                                                tick: 4000, bounds: Self.bounds)
        }
        let ms = Date().timeIntervalSince(start) * 1000 / 100
        // 非权威 smoke：仅记录单次装配毫秒；spec「120Hz 单帧 <4ms」完整 draw 帧预算归 C8b/顺位 9。
        print("[C8a perf smoke] makeViewport avg = \(ms) ms (non-authoritative; not the spec frame budget)")
        #expect(ms < 50)   // 极宽松上界，仅防病态退化（partitioningIndex O(log n) + 切片 O(80)）
    }
```

- [ ] **Step 2: 跑 perf smoke 确认通过（makeViewport 已存在）**

Run: `cd ios/Contracts && swift test --filter "RenderStateBuilderTests/perfSmoke"`
Expected: PASS（打印 avg ms；远 < 50ms）。

- [ ] **Step 3: 实现 `ChartContainerView`**

创建 `ChartContainerView.swift`：

```swift
// Kline Trainer Swift Contracts — C8a ChartContainerView（@Observable→UIKit 桥接）
// Spec: kline_trainer_modules_v1.4.md §C8 (L1409-1467)
// Design: docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md
//
// 平台门：UIKit-only。macOS swift build 编译为空；Catalyst build-for-testing 落 required CI 闸门。
// spec 实现约束：不订阅 ObservationRegistrar（1）；靠 @Bindable 触发重建（2）；KLineView 只收值类型（3）；
// buildRenderState 算值域（4，已下放 RenderStateBuilder）；不监听 scenePhase（5）。
// 注：observation 驱动的 updateUIView 刷新在 C8b/顺位 9（U2 集成）运行期验证；C8a 仅编译 + 单次渲染装配。

#if canImport(UIKit)
import SwiftUI
import UIKit

public struct ChartContainerView: UIViewRepresentable {
    public let panel: PanelId
    @Bindable public var engine: TrainingEngine

    public init(panel: PanelId, engine: TrainingEngine) {
        self.panel = panel
        self._engine = Bindable(wrappedValue: engine)
    }

    public func makeUIView(context: Context) -> KLineView { KLineView(frame: .zero) }

    public func updateUIView(_ view: KLineView, context: Context) {
        view.renderState = RenderStateBuilder.make(engine: engine, panel: panel, bounds: view.bounds)
    }
}
#endif
```

- [ ] **Step 4: 写编译反射测试（Catalyst gate）**

创建 `ChartContainerViewCompileTests.swift`：

```swift
// Kline Trainer Swift Contracts — C8a ChartContainerView 编译反射（Catalyst build gate）
// Mirror: KLineViewCompileTests（UIKit-only；macOS host 编译为空）
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
@testable import KlineTrainerContracts

@Suite("ChartContainerView 编译反射（Catalyst compile gate）")
struct ChartContainerViewCompileTests {

    @Test("ChartContainerView 可构造 + 符合 UIViewRepresentable")
    @MainActor
    func instantiates() {
        let engine = TrainingEngine.preview()
        let view = ChartContainerView(panel: .upper, engine: engine)
        #expect(view.panel == .upper)
        let _: any UIViewRepresentable = view   // 编译期符合性
    }
}
#endif
```

> **Step 4 注（F2）**：`UIViewRepresentable.Context` **无 public 构造器**，无法在测试中合成调用 `makeUIView(context:)`/`updateUIView(_:context:)`，故编译反射只验：(a) `ChartContainerView(panel:engine:)` 可构造；(b) 类型符合 `UIViewRepresentable`。`makeUIView`/`updateUIView` 的运行期行为（含 builder 装配进 renderState）在 C8b/顺位 9 U2 集成运行期验证（UIViewRepresentable 在 host 无 SwiftUI 渲染管线）。需 `import SwiftUI`（`UIViewRepresentable` 协议）。

- [ ] **Step 5: 跑全套 + 确认 host 编译（ChartContainerView 在 macOS 编译为空 #if）**

Run: `cd ios/Contracts && swift build && swift test --filter RenderStateBuilder && swift test --filter ChartContainerViewCompileTests`
Expected: `swift build` 成功；RenderStateBuilderTests 全 PASS（**20 测试，host**，含 perf smoke）；ChartContainerViewCompileTests 在 macOS host **0 测试运行**（`#if canImport(UIKit)` 编译为空，正常；其 1 测试仅 Catalyst 跑）。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewCompileTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "feat(c8a): ChartContainerView UIKit 桥接 + 编译反射 + perf smoke

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## 验收 checklist（非编码者可执行；中文 action/expected/pass-fail）

| # | 操作（action） | 预期（expected） | 通过/失败 |
|---|---|---|---|
| 1 | 在 `ios/Contracts` 跑 `swift test --filter RenderStateBuilder` | 全部测试 PASS（**20 个 host**：几何/锚定 3 分流/聚合面板/offset 分解/两类边界饱和/装配/值域 2/守卫 2/visibleCandleRange 2/Equatable 前提/perf smoke） | |
| 2 | 看测试输出 `[C8a perf smoke] makeViewport avg = … ms` | 打印一行毫秒数（**非权威 smoke**；spec「120Hz 单帧 <4ms」完整 draw 帧预算归 C8b/顺位 9，不在本 PR 宣称满足） | |
| 3 | grep `RenderStateBuilder.swift` 是否用 `NonDegenerateRange.make` 算 volumeRange/macdRange | 命中 2 处（volume `[0.0]+` 含 0 下界 + macd `compactMap` fallback `-0.001...0.001`） | |
| 4 | 跑 `swift build`（macOS host） | 成功；`ChartContainerView.swift`（`#if canImport(UIKit)`）在 macOS 编译为空、不报错 | |
| 5 | CI：PR 触发 `Mac Catalyst build-for-testing on macos-15` required check | 真过（不绕过）——验证 `ChartContainerView` + 编译反射测试在 Catalyst 编译链接通过 | |
| 6 | 检查 design doc traceability（§1.4）对照本 PR | C8a 关闭项（volumeRange/macdRange 收口 + perf host smoke）已交付；H1/C7 接线/activateDrawing/运行时 artifact 明确标 C8b（无悬空） | |

---

## Self-Review（writing-plans 自查）

**1. Spec coverage（design doc → task）：**
- RenderStateBuilder（§2.1）→ Task 1/2/3 ✅
- 视口几何条件锚定（§3.1/3.2）→ Task 1（3 分流测试）✅
- offset 分解 + 边界饱和（§3.3 + F3）→ Task 2 ✅
- buildRenderState 装配 + 值域收口（§四）→ Task 3 ✅
- visibleCandleRange C8b 复用（§2.1）→ Task 3 ✅
- 空/退化守卫（§四/§六-7）→ Task 3（bounds zero / zero-height）✅
- 可见切片边界（§六-5）→ **F3 诚实化**：`makeViewport` 的 `sliceEnd = min(startIndex+visibleCount, count)` 中 `min()` 是**防御性**——因 `startIndex <= upperBound = max(0, count-visibleCount)`，恒有 `startIndex+visibleCount <= count`，**truncation 分支结构上不可达**。`viewport.visibleCount` 恒 == `min(80, count)`。故 §六-5 的「startIndex>0 处切片被截断」场景不存在；`count<80`（visibleCount==count）由 `anchorShortHistory`/`aggregatePanelAnchorsOwnPeriod` 覆盖，不另设截断测试。
- ChartContainerView UIKit glue（§五）→ Task 4 ✅
- Equatable 短路前提（§六-8）+ perf smoke（§六-9）→ Task 3/4 ✅
- 评审策略（§八）→ Task 0 ✅
- 顺位-7 residual traceability（§1.4）→ 验收 #6 ✅

**2. Placeholder scan：** Task 4 Step 4 含一个**显式标注**的占位（UIViewRepresentable.Context 不可构造），已在「Step 4 实现注」给出替换的真实代码 + 理由。无其它 TBD/TODO。

**3. Type consistency：** `RenderStateBuilder.make(engine:panel:bounds:)`（无 displayScale，全程一致）/ `makeViewport(panelState:candles:tick:bounds:)` / `visibleCandleRange(panelState:candles:tick:bounds:)` / `defaultVisibleCount` / `candleWidthRatio`——Task 1-4 引用一致。冻结契约签名（KLineRenderState 9 字段 init、ChartViewport 6 字段 init、NonDegenerateRange.make(values:fallback:)、partitioningIndex(where:)）均按源码核实。测试 import：`Testing`/`Foundation`（Date）/`CoreGraphics`/`@testable KlineTrainerContracts`（F1）；compile-test 加 `SwiftUI`（UIViewRepresentable，F2）。

---

## 变更日志
| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-07 | v1 | 落 design doc v4（收敛）为 4 task TDD plan；待 opus 4.8 xhigh plan-stage 对抗 review |
| 2026-06-07 | v2 (opus 4.8 xhigh plan review R1 修) | **F1**(H)：测试 header 加 `import Foundation`（perf smoke `Date()`，@testable 不透传）；**F2**(L)：Task 4 Step 4 主代码块改为正确版（`any UIViewRepresentable` 符合性，删 fatalError 占位 + 加 `import SwiftUI`）；**F3**(L)：诚实化——`sliceEnd` min 截断分支结构不可达（startIndex<=upperBound），§六-5 仅由 count<80 等值 case 覆盖；**F4**(L)：值域断言改验真实 `make` 输出（rs.volumeRange/macdRange）+ 拆出 contract-characterization 测试。R1 验证全算术正确 + 核心 source 探针真编译 + `@Bindable` in UIViewRepresentable 在 Catalyst 真编译通过 |
| 2026-06-07 | v3 (opus 4.8 xhigh plan review R2 APPROVE + L1 修) | **R2 VERDICT: APPROVE**（零 C/H；验证 preview fixture 断言、imports、契约签名、F3 数学全对）；**L1**(L)：测试计数 off-by-one 订正——Task 1 = 6（非 7）→ 累计 12/19/20（host）；ChartContainerViewCompileTests 1 测试仅 Catalyst 跑不计 host |
