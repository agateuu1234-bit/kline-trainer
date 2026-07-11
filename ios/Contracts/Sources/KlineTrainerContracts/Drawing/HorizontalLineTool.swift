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

    /// 画线描边色（固定 scheme-independent）。顺位9/codex R2-F1：旧 0.95/0.6/0.1 在白底仅 2.15:1<3，
    /// 改暗橙 0.82/0.40/0 → 白底 3.59:1 + 黑底 4.66:1 均 ≥3:1（图形元素阈，`drawingStrokeContrastWCAG` 测）。
    /// 完整 scheme-aware 画线 token 化仍属后续（Phase 4）；此处为满足双 scheme 可读的最小修正。
    nonisolated public static let strokeRGBA = AppColorRGBA(red: 0.82, green: 0.40, blue: 0.0)

    /// thickness (1...5, clamp) → 线宽（pt）。档 1 = 1.5pt，等于今天线宽（视觉零变化）。
    nonisolated static func lineWidth(forThickness t: Int) -> CGFloat {
        let clamped = min(max(t, 1), 5)
        return 1.0 + 0.5 * CGFloat(clamped)   // 1→1.5, 2→2.0, 3→2.5, 4→3.0, 5→3.5
    }
    /// lineStyle → CGContext setLineDash 的 lengths；.solid 返回空数组（无 dash）。
    nonisolated static func dashPattern(for style: LineStyle) -> [CGFloat] {
        switch style {
        case .solid: return []
        case .dash1: return [6, 3]
        case .dash2: return [2, 3]
        case .dash3: return [10, 4]
        case .dash4: return [10, 3, 2, 3]
        }
    }

    public func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject, scheme: AppColorScheme) {
        guard let y = lineY(anchors: drawing.anchors, mapper: mapper) else { return }
        let frame = mapper.viewport.mainChartFrame
        ctx.saveGState()
        let rgba = DrawingColorResolver.resolve(drawing.colorToken, scheme: scheme)
        ctx.setStrokeColor(CGColor(srgbRed: CGFloat(rgba.red), green: CGFloat(rgba.green),
                                   blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha)))
        ctx.setLineWidth(Self.lineWidth(forThickness: drawing.thickness))
        let dash = Self.dashPattern(for: drawing.lineStyle)
        if dash.isEmpty { ctx.setLineDash(phase: 0, lengths: []) } else { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.move(to: CGPoint(x: frame.minX, y: y))
        ctx.addLine(to: CGPoint(x: frame.maxX, y: y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    public func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool {
        guard let y = lineY(anchors: drawing.anchors, mapper: mapper) else { return false }
        return abs(point.y - y) <= Self.hitTolerance
    }
}
