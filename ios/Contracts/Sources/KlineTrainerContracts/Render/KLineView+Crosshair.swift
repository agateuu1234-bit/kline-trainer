// Kline Trainer Swift Contracts — C5 十字光标渲染（UIKit 薄层）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313
//
// 几何/字符串在 CrosshairLayout.swift（平台无关）；本文件只做 UIKit 描边 + 框 + 文本。
// 签名保 spec 字面 3-arg per plan D1：通过 self.renderState.visibleCandles + self.traitCollection
// 派生 candles 与 mapper（KLineView 是 final class，extension 可访问 self）。不改 spec、不改 KLineView.swift 派发点。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C5 十字光标：point != nil 且在 mainChartFrame 内时画横+竖线 + 右侧价签 + 底部时签。
    /// point == nil 直接返回（无光标）。frame 外 point 由 CrosshairLayout.lines 返回 nil 跳过。
    func drawCrosshair(ctx: CGContext, at point: CGPoint?, viewport: ChartViewport) {
        guard let point else { return }
        let mapper = CoordinateMapper(viewport: viewport,
                                      displayScale: self.traitCollection.displayScale)
        guard let lines = CrosshairLayout.lines(at: point, mapper: mapper) else { return }
        let candles = self.renderState.visibleCandles

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // D3：crosshair 线 = AppColor.text（白 0.92），1 device pixel 宽。
        AppColor.text.setStroke()
        ctx.setLineWidth(1 / mapper.displayScale)
        ctx.move(to: lines.horizontal.from); ctx.addLine(to: lines.horizontal.to); ctx.strokePath()
        ctx.move(to: lines.vertical.from);   ctx.addLine(to: lines.vertical.to);   ctx.strokePath()

        // 价签
        let priceLabel = CrosshairLayout.priceLabel(at: point, mapper: mapper)
        drawLabelBox(ctx: ctx, rect: priceLabel.rect, text: priceLabel.text)

        // 时签（candles 越界则 nil）
        if let timeLabel = CrosshairLayout.timeLabel(at: point, mapper: mapper, candles: candles) {
            drawLabelBox(ctx: ctx, rect: timeLabel.rect, text: timeLabel.text)
        }
    }

    /// D4：标签框 = background 实心 + text 文字，10pt 系统字体，居中。
    private func drawLabelBox(ctx: CGContext, rect: CGRect, text: String) {
        AppColor.background.setFill()
        ctx.fill(rect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: AppColor.text,
        ]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        let drawX = rect.midX - size.width / 2
        let drawY = rect.midY - size.height / 2
        str.draw(at: CGPoint(x: drawX, y: drawY), withAttributes: attrs)
    }
}

#endif
