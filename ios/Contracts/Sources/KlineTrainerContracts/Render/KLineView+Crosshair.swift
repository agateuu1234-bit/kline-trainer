// Kline Trainer Swift Contracts — C5 十字光标渲染（UIKit 薄层）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313
//
// 几何/字符串在 CrosshairLayout.swift（平台无关）；本文件只做 UIKit 描边 + 框 + 文本。
// 签名保 spec 字面 3-arg per plan D1：通过 self.renderState.visibleCandles + self.traitCollection
// 派生 candles 与 mapper（KLineView 是 final class，extension 可访问 self）。不改 spec、不改 KLineView.swift 派发点。
// 守卫（point==nil / frame 外 / 空切片）统一由 CrosshairLayout.resolve 返回 nil 处理。竖线吸附最近蜡烛中心。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// 顺位5 十字光标：point != nil 且在 mainChartFrame 内时画横+竖线（竖线吸附最近蜡烛中心）
    /// + 右侧价签（自由 Y）+ 底部时签（吸附蜡烛）。守卫由 CrosshairLayout.resolve 统一处理。
    func drawCrosshair(ctx: CGContext, at point: CGPoint?, viewport: ChartViewport) {
        let mapper = CoordinateMapper(viewport: viewport,
                                      displayScale: self.traitCollection.displayScale)
        let candles = self.renderState.visibleCandles
        guard let resolved = CrosshairLayout.resolve(at: point, mapper: mapper, candles: candles) else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // D3：crosshair 线 = currentPalette.text，1 device pixel 宽。
        currentPalette.text.setStroke()
        ctx.setLineWidth(1 / mapper.displayScale)
        let lines = resolved.lines
        ctx.move(to: lines.horizontal.from); ctx.addLine(to: lines.horizontal.to); ctx.strokePath()
        ctx.move(to: lines.vertical.from);   ctx.addLine(to: lines.vertical.to);   ctx.strokePath()

        // HUD：价签（自由 Y）+ 时签（吸附 X，resolve 保证 in-frame 恒在）。
        drawLabelBox(ctx: ctx, rect: resolved.priceLabel.rect, text: resolved.priceLabel.text)
        drawLabelBox(ctx: ctx, rect: resolved.timeLabel.rect, text: resolved.timeLabel.text)
    }

    /// D4：标签框 = background 实心 + text 文字，10pt 系统字体，居中。
    func drawLabelBox(ctx: CGContext, rect: CGRect, text: String) {
        currentPalette.background.setFill()
        ctx.fill(rect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: currentPalette.text,
        ]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        let drawX = rect.midX - size.width / 2
        let drawY = rect.midY - size.height / 2
        str.draw(at: CGPoint(x: drawX, y: drawY), withAttributes: attrs)
    }
}

#endif
