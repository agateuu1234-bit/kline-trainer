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

    /// 主入口：装配完整 KLineRenderState。空 candle / bounds.width 或 height <=0 → .empty。
    /// 不取 displayScale（renderState 无该字段；亚像素对齐在 KLineView.draw 用 traitCollection.displayScale）。
    @MainActor
    public static func make(engine: TrainingEngine, panel: PanelId, bounds: CGRect,
                            crosshair: CGPoint? = nil) -> KLineRenderState {
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
            drawings: engine.drawings.filter { $0.panelPosition == (panel == .upper ? 0 : 1) },
            crosshairPoint: crosshair)   // C8b：长按十字光标由 ChartContainerView.Coordinator 视图层透传（D3）
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

    /// 视口几何推导（唯一拥有 startIndex/pixelShift 装配的函数；make 与 visibleCandleRange 都经它）。
    /// **前置约束**：`candles` 非空、`bounds.width > 0`（调用方 make/visibleCandleRange 已守 .empty/空）。
    /// 支持 autoTracking（offset=0）与 freeScrolling（非零 offset 分解 + 边界饱和）；C8b H1 handler 复用点。
    static func makeViewport(panelState: PanelViewState, candles: [KLineCandle],
                             tick: Int, bounds: CGRect) -> ChartViewport {
        let mainFrame = ChartPanelFrames.split(in: bounds).mainChart
        let count = candles.count
        // 顺位 3 D5 去硬编码：target = panelState.visibleCount（≤0 → fallback 80 兼容旧构造；
        // engine init 已 seed 80，新路径不依赖 fallback）。
        let target = panelState.visibleCount > 0 ? panelState.visibleCount : defaultVisibleCount
        let visibleCount = min(target, count)

        // 几何：分母 = target（count<target 时左对齐填充、candle 宽度稳定；target==80 与旧行为逐位一致）。
        let candleStep = mainFrame.width / CGFloat(target)
        let geometry = ChartGeometry(candleStep: candleStep,
                                     candleWidth: candleStep * candleWidthRatio,
                                     gap: candleStep - candleStep * candleWidthRatio)

        let currentIdx = currentCandleIndex(candles: candles, tick: tick)

        // autoTracking 锚定：当前 candle 落最右被绘制 slot（baseStartIndex 可能 <0，下方 clamp）。
        let baseStartIndex = currentIdx - (visibleCount - 1)
        // reveal RFC（2026-06-15）：upperBound 从 max(0,count−visibleCount) 收紧为 max(0,baseStartIndex)
        // = autoTracking 即最新可见边，前向滚动（朝新）不可越当前 tick（禁前窥）。
        let upperBound = max(0, baseStartIndex)
        // offset 分解（C8b freeScrolling 复用；C8a offset 恒 0 时 wholeShift=0/pixelShift=0）。
        // 符号契约（CoordinateMapper Geometry.swift L136）：pixelShift>0 = candles 右移。
        let wholeShift = Int((panelState.offset / candleStep).rounded(.down))   // floor
        let startIndex = min(max(baseStartIndex - wholeShift, 0), upperBound)
        // 余量 ∈ [0,candleStep)；按 startIndex *落位* 判饱和（非按 clamp 是否改值，F3）：
        // 处硬边界（最老 startIndex==0 / 最新 ==upperBound，无更多可揭示）→ pixelShift=0（边缘钉面板边）。
        var pixelShift = panelState.offset - CGFloat(wholeShift) * candleStep
        if startIndex == 0 || startIndex == upperBound { pixelShift = 0 }

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
