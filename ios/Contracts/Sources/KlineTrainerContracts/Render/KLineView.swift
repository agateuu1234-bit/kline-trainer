// Kline Trainer Swift Contracts — C1c KLineView UIKit shell
// Spec: kline_trainer_modules_v1.4.md §六 C1c (L1179-1211) + §15.1 #3 编译验证
// Cross-platform precedent: Theme.swift L66-117（UIKit 部分 #if canImport(UIKit) 守卫）
//
// 本文件实现 KLineView：UIView 子类，renderState 驱动 setNeedsDisplay，
// draw(_:) 派发到 C3-C6 八个 drawXxx extension 方法（散在 6 个 +Xxx.swift 文件，由 Task 3-6 提供）。
// 所有 drawXxx 在 PR 8 内为 Wave 1 占位空 stub；本 shell 关闭 §15.1 #3 编译验证闸门。

import Foundation

#if canImport(UIKit)
import UIKit
import CoreGraphics

public final class KLineView: UIView {
    public var renderState: KLineRenderState = .empty {
        didSet {
            guard renderState != oldValue else { return }
            setNeedsDisplay()
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported; KLineView is constructed via init(frame:)")
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = traitCollection.displayScale
        let mapper = CoordinateMapper(viewport: renderState.viewport, displayScale: scale)
        let volMapper = IndicatorMapper(
            frame: renderState.frames.volumeChart,
            valueRange: renderState.volumeRange,
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)
        let macdMapper = IndicatorMapper(
            frame: renderState.frames.macdChart,
            valueRange: renderState.macdRange,
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)

        drawCandles(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawMA66(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawBOLL(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawVolume(ctx: ctx, mapper: volMapper, candles: renderState.visibleCandles)
        drawMACD(ctx: ctx, mapper: macdMapper, candles: renderState.visibleCandles)
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                     period: renderState.panel.period, tools: [:])
        drawMarkers(ctx: ctx, viewport: renderState.viewport, mapper: mapper,
                    markers: renderState.markers, candles: renderState.visibleCandles)
        drawCrosshair(ctx: ctx, at: renderState.crosshairPoint, viewport: renderState.viewport)
    }
}

#endif
