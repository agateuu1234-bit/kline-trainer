// Kline Trainer Swift Contracts — C8a RenderStateBuilder（视口几何 + buildRenderState）
// Spec: kline_trainer_modules_v1.4.md §C8 (L1409-1467) + §C1a 几何 (L887-927)
//     + kline_trainer_plan_v1.5.md §坐标映射 (L104-233)
// Design: docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md
//
// 平台无关（无 UIKit）：host 全量单测 + C8b H1 handler 复用 makeViewport/visibleCandleRange。
// 视口几何：分母 = panelState.visibleCount（顺位 3 去硬编码；≤0 fallback 80）+ 条件锚定 + offset 分解。

import CoreGraphics

public enum RenderStateBuilder {
    /// 渲染常量。defaultVisibleCount = seed/fallback 单一来源（engine init 与 ≤0 兜底共用）；zoom clamp 在 PinchZoomModel。
    static let defaultVisibleCount = 80
    static let candleWidthRatio: CGFloat = 0.7

    /// RFC-C：可见切片首根之前一根的收盘（startIndex>0 时存在于完整数组、在切片外）。
    /// 供十字光标信息栏算最左可见 K 线的真实涨跌基准（codex R2-M）。
    static func previousCloseBeforeVisible(candles: [KLineCandle], startIndex: Int) -> Double? {
        startIndex > 0 ? candles[startIndex - 1].close : nil
    }

    /// 主入口：装配完整 KLineRenderState。空 candle / bounds.width 或 height <=0 → .empty。
    /// 不取 displayScale（renderState 无该字段；亚像素对齐在 KLineView.draw 用 traitCollection.displayScale）。
    @MainActor
    public static func make(engine: TrainingEngine, panel: PanelId, bounds: CGRect,
                            crosshair: CGPoint? = nil) -> KLineRenderState {
        let panelState = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
        let candles = engine.allCandles[panelState.period] ?? []
        guard !candles.isEmpty, bounds.width > 0, bounds.height > 0 else { return .empty }
        let tick = engine.tick.globalTickIndex
        let viewport = makeViewport(panelState: panelState, candles: candles, tick: tick, bounds: bounds)
        // 聚合感知 reveal（spec 2026-06-15-aggregate-aware-reveal）：进行中聚合 K 线（可见且 endGlobalIndex>tick）
        // 用已揭示 m3 partial 合成；**就地改 base-indexed slice**（ArraySlice COW 仅拷可见窗口 ≤target、保 base 索引
        // slice.startIndex==viewport.startIndex，engine.allCandles 不变，codex R3-H：不拷全 period 数组）+ 重算 priceRange（R1-H2）。
        var renderViewport = viewport
        var slice = candles[viewport.startIndex ..< viewport.startIndex + viewport.visibleCount]
        let currentIdx = currentCandleIndex(candles: candles, tick: tick)
        let lastVisibleIdx = viewport.startIndex + viewport.visibleCount - 1
        if lastVisibleIdx == currentIdx, candles[currentIdx].endGlobalIndex > tick,
           let m3 = engine.allCandles[.m3], tick < m3.count {
            slice[currentIdx] = PartialAggregateCandle.synthesize(original: candles[currentIdx], m3: m3, tick: tick)
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
            // codex whole-branch R4-F1：复盘步进时逐 tick 揭示画线（镜像 markers reveal 语义）。
            // 锚点全部 ≤ 当前面板自身 period 的 currentCandleIndex 才渲染；未来锚点在步进到达前隐藏。
            // normal/replay 下画线恒为历史锚（不受影响）；空锚点 drawing（allSatisfy 对空集为 true）保留但不渲染。
            drawings: engine.drawings.filter { drawing in
                drawing.panelPosition == (panel == .upper ? 0 : 1)
                    && drawing.anchors.allSatisfy { anchor in
                        anchor.candleIndex <= currentCandleIndex(candles: engine.allCandles[anchor.period] ?? [], tick: tick)
                    }
            },
            crosshairPoint: crosshair,   // C8b：长按十字光标由 ChartContainerView.Coordinator 视图层透传（D3）
            previousCloseBeforeVisible: previousCloseBeforeVisible(candles: candles, startIndex: viewport.startIndex))
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

    /// 共享几何内核（spec §二.B1 / D4 单一真相）：makeViewport 的 startIndex 派生与 offsetBounds 的边界派生
    /// 都消费它，杜绝两套几何公式漂移。纯值、平台无关。
    struct GeometryCore: Equatable, Sendable {
        let baseStartIndex: Int
        let upperBound: Int
        let candleStep: CGFloat
        let visibleCount: Int
    }

    static func geometryCore(mainFrameWidth: CGFloat, rawVisible: Int,
                             candleCount: Int, currentIdx: Int) -> GeometryCore {
        let target = rawVisible > 0 ? rawVisible : defaultVisibleCount
        let visibleCount = min(target, candleCount)
        let candleStep = mainFrameWidth / CGFloat(target)
        let baseStartIndex = currentIdx - (visibleCount - 1)
        // reveal RFC（2026-06-15, #113）：upperBound 从 max(0, count−visibleCount) 收紧为 max(0, baseStartIndex)
        // = autoTracking 锚（baseStartIndex）即最新可见边，前向滚动（朝新）不可越当前 tick（禁前窥）。
        // 早 tick base<0 → upperBound=0（无滚动空间，已显最旧 + 无未来）。makeViewport startIndex clamp 与
        // offsetBounds 边界派生都经此，故 reveal 语义在两处一致（D4）。
        let upperBound = max(0, baseStartIndex)
        return GeometryCore(baseStartIndex: baseStartIndex, upperBound: upperBound,
                            candleStep: candleStep, visibleCount: visibleCount)
    }

    /// bounce 接线所需的 offset 边界（spec §二.B1 / §五.D5，**reveal RFC #113 后**）：带符号——
    /// `maxOffset = max(0, baseStartIndex)·step`（最老边 startIndex==0 的 offset）、`minOffset = 0`（最新边 = 当前 tick）。
    /// reveal 禁前窥：autoTracking 锚（baseStartIndex）即最新可见边，前向滚动不可越当前 tick → 故 **minOffset 恒 0**
    /// （offset=0 即 autoTracking rest = 最新边，在区间内，**无早 tick 负 minOffset 歧义**，消旧 normalize-on-freeScrolling 契约）。
    /// 与 makeViewport 的 startIndex clamp **共用 geometryCore**（D4 单一真相，upperBound=max(0,baseStartIndex)）：
    /// maxOffset=roundTripEdge(baseStartIndex)、minOffset=roundTripEdge(baseStartIndex−upperBound)=roundTripEdge(0)=0。
    /// 供 R1b-wire 的 Coordinator 喂 engine——bounce/overscroll 在 [0, maxOffset]（仅 freeScrolling；autoTracking rest offset=0 照旧 pin）。
    /// **⚠️ 边非对称（codex R2/R3，reveal）**：`minOffset=0` 是**硬钳**（最新边=当前 tick，前向=未来），**非对称弹簧边**——
    /// 返回的 `OffsetBounds.bounceEdges` **类型级编码**该非对称（仅含 `.max` 最老边、或无滚动空间时为空；**永不含 `.min`**），
    /// R1b-wire 据此单边化 `EdgeBounceModel`——**不可**把最新边当对称弹簧端点（否则负速 fling 会 spring offset<0 = 前向揭示）。
    /// R1a 的 makeViewport 已在 render 层兜底（offset<0 → startIndex 钳 upperBound + pixelShift=0，无前向间隙；
    /// 见测 `offsetBounds_minOffsetIsHardClampNotSpring`），但 R1b 仍须按 `bounceEdges` 硬钳语义接线以保正确 UX。
    /// **span == upperBound·candleStep**（=max(0,base)·step）：早 tick base<0 → upperBound=0 → 单点 [0,0]
    /// （无滚动空间，已显最旧 + 无未来）；中/晚 tick span 随 base 渐增（不再是与 tick 无关常数）。
    /// **FP round-trip（codex R1-M）**：maxOffset 经 makeViewport plain `floor(offset/step)` 反算须得回 baseStartIndex——
    /// 非整除 step（如 1000/21）下 `integer·step` 可 FP 偏移致 floor 偏 1 → `roundTripEdge` verify-and-correct 钉死。
    /// **非有限几何（codex R2-M）**：width/step 非有限 → 返单点 [0,0] 安全退化（交 R1b-wire EdgeBounceModel 端点校验），不 trap。
    /// **空 candle（codex R3 branch-diff）**：candleCount==0 → visibleCount==0 → 退化 [0,0]，**不依赖 caller 传的 currentIdx**——
    /// 否则 visibleCount=0 使 baseStartIndex=currentIdx+1，哨兵 currentIdx=0 → upperBound=1 漏过守卫 → 伪非零 maxOffset。
    /// offsetBounds 返回（codex R3）：offset 区间 + reveal 单边 bounce 策略。`minOffset/maxOffset/candleStep`
    /// 同旧 tuple；`bounceEdges` **类型级编码非对称**——仅最老边（`.max`）可弹，最新边（`minOffset` 硬钳）**永不可弹**。
    struct OffsetBounds: Equatable, Sendable {
        let minOffset: CGFloat       // 最新边硬钳（reveal：=当前 tick offset 0，前向不可越，非弹簧）
        let maxOffset: CGFloat       // 最老边（≥ minOffset）
        let candleStep: CGFloat
        enum Edge: Hashable, Sendable { case min, max }
        /// reveal 单边 bounce 策略：有滚动空间（max>min）→ `[.max]`（仅最老边弹）；否则空。**`.min` 永不在内**（硬钳）。
        var bounceEdges: Set<Edge> { maxOffset > minOffset ? [.max] : [] }
    }

    static func offsetBounds(mainFrameWidth: CGFloat, rawVisible: Int,
                             candleCount: Int, currentIdx: Int) -> OffsetBounds {
        let core = geometryCore(mainFrameWidth: mainFrameWidth, rawVisible: rawVisible,
                                candleCount: candleCount, currentIdx: currentIdx)
        // 空 candle（visibleCount==0）/ 非有限几何（NaN/inf width → NaN/inf step）/ 无滚动空间 → 单点 [0,0] 安全退化（codex R3 / R2-M / 退化）。
        guard core.visibleCount > 0, core.candleStep.isFinite, core.candleStep > 0, core.upperBound > 0 else {
            let safeStep = core.candleStep.isFinite ? core.candleStep : 0
            return OffsetBounds(minOffset: 0, maxOffset: 0, candleStep: safeStep)
        }
        let maxOffset = roundTripEdge(integer: core.baseStartIndex, step: core.candleStep)
        let minOffset = roundTripEdge(integer: core.baseStartIndex - core.upperBound, step: core.candleStep)
        return OffsetBounds(minOffset: minOffset, maxOffset: maxOffset, candleStep: core.candleStep)
    }

    /// R1b-wire 便捷重载（D1）：从 engine 抽取 candles/tick/visibleCount + split 出 mainChart 宽，算 numeric
    /// offset 边界喂 engine（Coordinator 用；engine 不反向依赖 ChartPanelFrames/像素）。复用 `make` 的 extraction。
    /// M4：传 **raw** `visibleCount`（与 makeViewport 一致；≤0→80 fallback 在 geometryCore 内统一）。
    @MainActor
    static func offsetBounds(engine: TrainingEngine, panel: PanelId, bounds: CGRect) -> OffsetBounds {
        let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
        let candles = engine.allCandles[ps.period] ?? []
        let mainW = ChartPanelFrames.split(in: bounds).mainChart.width
        let currentIdx = candles.isEmpty ? 0 : currentCandleIndex(candles: candles, tick: engine.tick.globalTickIndex)
        return offsetBounds(mainFrameWidth: mainW, rawVisible: ps.visibleCount,
                            candleCount: candles.count, currentIdx: currentIdx)
    }

    /// FP round-trip 守门（codex R1-M / C1a verify-and-correct）：返回一个 edge，使 makeViewport 的
    /// plain `Int((edge/step).rounded(.down)) == integer`。`integer·step` 在非整除 step 下可 FP 偏移致 floor 偏 1；
    /// 按 floor 方向 ULP-nudge 至吻合（bounded）。**调用方须先保 step 有限正（offsetBounds 已守，codex R2-M）**——
    /// 但本函数对非有限 quotient 仍 fail-safe（quotient 非有限 → 直接返 integer·step 不进 Int() 防 trap）。
    static func roundTripEdge(integer: Int, step: CGFloat) -> CGFloat {
        guard step.isFinite, step > 0 else { return CGFloat(integer) * step }
        var edge = CGFloat(integer) * step
        var n = 0
        while n < 32 {
            let q = edge / step
            guard q.isFinite else { break }   // 防 Int(NaN/inf) trap（codex R2-M）
            let f = Int(q.rounded(.down))
            if f == integer { break }
            edge = f < integer ? edge.nextUp : edge.nextDown
            n += 1
        }
        return edge
    }

    /// 视口几何推导（唯一拥有 startIndex/pixelShift 装配的函数；make 与 visibleCandleRange 都经它）。
    /// **前置约束**：`candles` 非空、`bounds.width > 0`（调用方 make/visibleCandleRange 已守 .empty/空）。
    /// 支持 autoTracking（offset=0）与 freeScrolling（非零 offset 分解 + 边界饱和）；C8b H1 handler 复用点。
    static func makeViewport(panelState: PanelViewState, candles: [KLineCandle],
                             tick: Int, bounds: CGRect) -> ChartViewport {
        let mainFrame = ChartPanelFrames.split(in: bounds).mainChart
        let count = candles.count
        let currentIdx = currentCandleIndex(candles: candles, tick: tick)
        let core = geometryCore(mainFrameWidth: mainFrame.width, rawVisible: panelState.visibleCount,
                                candleCount: count, currentIdx: currentIdx)
        let candleStep = core.candleStep
        let geometry = ChartGeometry(candleStep: candleStep,
                                     candleWidth: candleStep * candleWidthRatio,
                                     gap: candleStep - candleStep * candleWidthRatio)
        let baseStartIndex = core.baseStartIndex
        let upperBound = core.upperBound        // reveal RFC：= max(0, baseStartIndex)（禁前窥，语义在 geometryCore）
        let visibleCount = core.visibleCount
        // offset 分解（C8b freeScrolling 复用；C8a offset 恒 0 时 wholeShift=0/pixelShift=0）。
        // 符号契约（CoordinateMapper Geometry.swift L136）：pixelShift>0 = candles 右移。
        let wholeShift = Int((panelState.offset / candleStep).rounded(.down))   // floor
        let startIndex = min(max(baseStartIndex - wholeShift, 0), upperBound)
        // 余量 ∈ [0,candleStep)；按 startIndex *落位* 判饱和（非按 clamp 是否改值，F3）：
        // 处硬边界（最老 startIndex==0 / 最新 ==upperBound，无更多可揭示）→ pixelShift=0（边缘钉面板边）。
        // R1b-wire B4（spec §四，单边 overscroll）：最新边硬钉先判；最老边 offset>maxOffset 放开 overscroll 间隙。
        var pixelShift = panelState.offset - CGFloat(wholeShift) * candleStep
        if startIndex == upperBound {
            pixelShift = 0                                   // 最新边硬钉（含早 tick upperBound==0；reveal offset<minOffset 前向不可达）
        } else if startIndex == 0 {
            // 最老边：offset>maxOffset → 左露 overscroll 间隙（pixelShift>0=candles 右移）；否则钉边
            // M2：复用本函数 core 派生的 baseStartIndex/candleStep（勿重算 geometryCore、勿用 upperBound）
            let maxOffset = roundTripEdge(integer: baseStartIndex, step: candleStep)   // 与 offsetBounds.maxOffset 同源（D4）
            pixelShift = panelState.offset > maxOffset ? panelState.offset - maxOffset : 0
        }

        // reveal RFC：可见窗口 ⊆ 已揭示前缀 candles[0...currentIdx]；slice 末根恒 ≤ currentIdx（看不到未来）。
        // 早 tick 左填充时 visibleCount(返回) = sliceEnd−startIndex < target。currentIdx+1 ≤ count（界内）。
        let sliceEnd = min(startIndex + visibleCount, currentIdx + 1)
        let slice = candles[startIndex ..< sliceEnd]
        return ChartViewport(startIndex: startIndex, visibleCount: slice.count,
                             pixelShift: pixelShift, geometry: geometry,
                             priceRange: PriceRange.calculate(from: slice),
                             mainChartFrame: mainFrame)
    }

    /// 当前 candle 索引单一谓词（顺位 3 D3/R1-M1：makeViewport 与 engine.applyPinch 共用，禁双实现）。
    /// 面板自身 period 中首个 endGlobalIndex>=tick（超末根取末根）。
    /// 仅谓词同 E5 currentPrice；序列为面板自身 period（聚合面板必须在自身序列定位，勿改读 .m3）。
    /// **前置**：candles 非空。
    static func currentCandleIndex(candles: [KLineCandle], tick: Int) -> Int {
        let rawIdx = candles.partitioningIndex { $0.endGlobalIndex >= tick }
        return min(rawIdx, candles.count - 1)
    }
}
