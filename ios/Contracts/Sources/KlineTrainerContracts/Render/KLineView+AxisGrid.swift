// Kline Trainer Swift Contracts — RFC #3 坐标轴/网格/周期标注渲染（UIKit 薄层）
// Spec: docs/superpowers/specs/2026-06-20-chart-axes-grid-period-design.md
//
// 几何/字符串在 AxisGridLayout.swift（平台无关，host 已测）；本文件只做 UIKit 描线 + 标签盒。
// 两个方法都遵循既有 GState 自平衡惯例（saveGState + defer restoreGState），防 stroke/fill 状态泄漏到后续 pass。
// drawLabelBox 复用自 KLineView+Crosshair.swift（已改 internal）。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// 网格 pass（画在 K 线背后）：用 currentPalette.gridLine 描所有网格线，1 device pixel 宽。
    func drawGridLines(ctx: CGContext, resolved: AxisGridResolved?) {
        guard let resolved, !resolved.gridLines.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        currentPalette.gridLine.setStroke()
        ctx.setLineWidth(1 / traitCollection.displayScale)
        for seg in resolved.gridLines {
            ctx.move(to: seg.from)
            ctx.addLine(to: seg.to)
            ctx.strokePath()
        }
    }

    /// 标签 pass（画在 K 线之上、crosshair 之下）：价格/时间/量/MACD/周期标签盒（复用 drawLabelBox）。
    func drawAxisLabels(ctx: CGContext, resolved: AxisGridResolved?) {
        guard let resolved else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        for l in resolved.priceLabels { drawLabelBox(ctx: ctx, rect: l.rect, text: l.text) }
        for l in resolved.timeLabels { drawLabelBox(ctx: ctx, rect: l.rect, text: l.text) }
        if let v = resolved.volumeLabel { drawLabelBox(ctx: ctx, rect: v.rect, text: v.text) }
        if let m = resolved.macdZeroLabel { drawLabelBox(ctx: ctx, rect: m.rect, text: m.text) }
        drawLabelBox(ctx: ctx, rect: resolved.periodLabel.rect, text: resolved.periodLabel.text)
    }
}
#endif
