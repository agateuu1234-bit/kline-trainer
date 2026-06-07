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
        // offset 分解（C8b freeScrolling 复用；C8a offset 恒 0 时 wholeShift=0/pixelShift=0）。
        // 符号契约（CoordinateMapper Geometry.swift L136）：pixelShift>0 = candles 右移。
        let wholeShift = Int((panelState.offset / candleStep).rounded(.down))   // floor
        let startIndex = min(max(baseStartIndex - wholeShift, 0), upperBound)
        // 余量 ∈ [0,candleStep)；按 startIndex *落位* 判饱和（非按 clamp 是否改值，F3）：
        // 处硬边界（最老 startIndex==0 / 最新 ==upperBound，无更多可揭示）→ pixelShift=0（边缘钉面板边）。
        var pixelShift = panelState.offset - CGFloat(wholeShift) * candleStep
        if startIndex == 0 || startIndex == upperBound { pixelShift = 0 }

        let sliceEnd = min(startIndex + visibleCount, count)
        let slice = candles[startIndex ..< sliceEnd]
        return ChartViewport(startIndex: startIndex, visibleCount: slice.count,
                             pixelShift: pixelShift, geometry: geometry,
                             priceRange: PriceRange.calculate(from: slice),
                             mainChartFrame: mainFrame)
    }
}
