// ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift
// Spec: docs/superpowers/specs/2026-06-13-wave3-pr4-drawing-mvp-design.md §一.1 + D-CROSSPERIOD
// Wave 3 顺位 4：唯一具体 DrawingTool（水平线 MVP）。横线仅 price 承重（周期无关），
// candleIndex 不参与 render。几何抽纯 helper `lineY` host 可测；render 仅 stroke。
//
// 跨平台：仅 CoreGraphics（CGContext/CGColor/CGPoint），与 DrawingTool protocol 一致无 UIKit。

import CoreGraphics

@MainActor
public struct HorizontalLineTool: DrawingTool {
    public static var type: DrawingToolType { .horizontal }
    public var requiredAnchors: ClosedRange<Int> { 1...1 }

    public init() {}

    /// 纯几何 helper（host 可测）：横线 y = 第一锚价位映射；空 anchors → nil。
    public func lineY(anchors: [DrawingAnchor], mapper: CoordinateMapper) -> CGFloat? {
        guard let first = anchors.first else { return nil }
        return mapper.priceToY(first.price)
    }

    /// 命中容差（点）：point.y 距横线 y 在此内即命中。MVP 不接删除 UI（Phase 4）。
    private static let hitTolerance: CGFloat = 8

    public func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor]) {
        guard let y = lineY(anchors: anchors, mapper: mapper) else { return }
        let frame = mapper.viewport.mainChartFrame
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 0.95, green: 0.6, blue: 0.1, alpha: 1))  // MVP 固定橙；token 化属后续
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: frame.minX, y: y))
        ctx.addLine(to: CGPoint(x: frame.maxX, y: y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    public func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool {
        guard let y = lineY(anchors: anchors, mapper: mapper) else { return false }
        return abs(point.y - y) <= Self.hitTolerance
    }
}
