// Kline Trainer Swift Contracts — C1c KLineRenderState
// Spec: kline_trainer_modules_v1.4.md §六 C1c (L1219-1229) + §十 Wave 0 C1 三件拆分 (L2126-2130)
// 与 KLineView.draw(_:) 派发链一一对应；所有字段 Equatable + Sendable 自动合成。
//
// codex R2 finding 2 修复（v3）：spec L1219-1229 字面用 `let`；改回 `let` 保持
// public API source-stable（tightening 后期不破 caller）。C8 Wave 2 ChartContainerView
// 每次构造完整 KLineRenderState 注入，不 partial mutate。
//
// 注：drawings 字段类型使用 Models.swift 中已存在的 DrawingObject（spec §C6 L1295+）。

import Foundation
import CoreGraphics

public struct KLineRenderState: Equatable, Sendable {
    public let panel: PanelViewState
    public let frames: ChartPanelFrames
    public let viewport: ChartViewport
    public let visibleCandles: ArraySlice<KLineCandle>
    public let volumeRange: NonDegenerateRange
    public let macdRange: NonDegenerateRange
    public let markers: [TradeMarker]
    public let drawings: [DrawingObject]
    public let crosshairPoint: CGPoint?
    public let previousCloseBeforeVisible: Double?   // RFC-C：可见首根前一根收盘（涨跌基准；切片外，codex R2-M）

    public init(panel: PanelViewState,
                frames: ChartPanelFrames,
                viewport: ChartViewport,
                visibleCandles: ArraySlice<KLineCandle>,
                volumeRange: NonDegenerateRange,
                macdRange: NonDegenerateRange,
                markers: [TradeMarker],
                drawings: [DrawingObject],
                crosshairPoint: CGPoint?,
                previousCloseBeforeVisible: Double? = nil) {
        self.panel = panel
        self.frames = frames
        self.viewport = viewport
        self.visibleCandles = visibleCandles
        self.volumeRange = volumeRange
        self.macdRange = macdRange
        self.markers = markers
        self.drawings = drawings
        self.crosshairPoint = crosshairPoint
        self.previousCloseBeforeVisible = previousCloseBeforeVisible
    }

    public static let empty: KLineRenderState = .init(
        panel: PanelViewState(
            period: .m3,
            interactionMode: .autoTracking,
            visibleCount: 0,
            offset: 0,
            revision: 0
        ),
        frames: ChartPanelFrames(
            mainChart: .zero,
            volumeChart: .zero,
            macdChart: .zero
        ),
        viewport: ChartViewport(
            startIndex: 0,
            visibleCount: 0,
            pixelShift: 0,
            geometry: ChartGeometry(candleStep: 0, candleWidth: 0, gap: 0),
            priceRange: PriceRange(min: 0, max: 1),
            mainChartFrame: .zero
        ),
        visibleCandles: [],
        // 注：`NonDegenerateRange.make(values: [])` 在 empty array 时落入 fallback range 0.0...1.0
        // （Geometry.swift L56-63）。Wave 1 C4 Volume/MACD 渲染必须用 `visibleCandles.isEmpty`
        // 判 "no-data"，**不**用 range 值做 emptiness 判断（`.empty` 的 range 是合法的 0.0...1.0
        // 非退化值，不是 sentinel）。
        volumeRange: NonDegenerateRange.make(values: []),
        macdRange: NonDegenerateRange.make(values: []),
        markers: [],
        drawings: [],
        crosshairPoint: nil
    )
}
