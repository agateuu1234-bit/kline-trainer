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
        let frames = self.renderState.frames
        guard let resolved = CrosshairLayout.resolve(at: point, mapper: mapper,
                                                     candles: candles, frames: frames) else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        currentPalette.text.setStroke()
        ctx.setLineWidth(1 / mapper.displayScale)
        let lines = resolved.lines
        ctx.move(to: lines.horizontal.from); ctx.addLine(to: lines.horizontal.to); ctx.strokePath()
        ctx.move(to: lines.vertical.from);   ctx.addLine(to: lines.vertical.to);   ctx.strokePath()

        drawLabelBox(ctx: ctx, rect: resolved.priceLabel.rect, text: resolved.priceLabel.text)
        drawLabelBox(ctx: ctx, rect: resolved.timeLabel.rect, text: resolved.timeLabel.text)

        // RFC-C 悬浮信息卡
        guard let p = point else { return }
        let snapped = candles[resolved.snappedIndex]
        // 前收：切片内取 candles[idx-1]；最左可见根(idx==startIndex)取切片外真实前收（codex R2-M）
        let prevClose: Double? = resolved.snappedIndex > candles.startIndex
            ? candles[resolved.snappedIndex - 1].close
            : self.renderState.previousCloseBeforeVisible
        let content = CrosshairSidebarContent.make(
            candle: snapped, previousClose: prevClose,
            cursorPrice: mapper.yToPrice(p.y),
            snappedX: resolved.lines.vertical.from.x,
            mainChartMidX: frames.mainChart.midX)
        drawSidebar(ctx: ctx, content: content, panelFrame: frames.mainChart)
    }

    /// RFC-C 悬浮信息卡：半透明圆角卡 + 字段行（颜色 up=红/down=绿/flat=白/neutral=黄）。
    /// 停靠：content.dock == .left → 贴 mainChart 左上；.right → 右上。固定不跟手指 Y。
    private func drawSidebar(ctx: CGContext, content: CrosshairSidebarContent, panelFrame: CGRect) {
        let pad: CGFloat = 7, cardW: CGFloat = 126, rowH: CGFloat = 15
        let topRowH: CGFloat = 22
        let rowCount = CGFloat(1 + content.rows.count)   // 日期时间行 + 字段行
        let cardH = topRowH + rowCount * rowH + pad * 2
        let inset: CGFloat = 7
        let x = content.dock == .left ? panelFrame.minX + inset
                                      : panelFrame.maxX - cardW - inset
        let y = panelFrame.minY + inset
        let card = CGRect(x: x, y: y, width: cardW, height: cardH)

        // 背景
        ctx.saveGState()
        let bg = UIBezierPath(roundedRect: card, cornerRadius: 9)
        UIColor.black.withAlphaComponent(0.82).setFill(); bg.fill()
        UIColor(white: 0.25, alpha: 1).setStroke(); bg.lineWidth = 0.5; bg.stroke()
        ctx.restoreGState()

        func color(_ c: CrosshairSidebarContent.ValueColor) -> UIColor {
            switch c {
            case .up:   return currentPalette.candleUp      // 红涨（Theme.swift UIChartPalette.candleUp）
            case .down: return currentPalette.candleDown    // 绿跌（UIChartPalette.candleDown）
            case .flat: return .white
            case .neutral: return UIColor(red: 0.94, green: 0.82, blue: 0.23, alpha: 1)   // 黄
            }
        }
        func draw(_ s: String, _ rect: CGRect, _ col: UIColor, size: CGFloat = 10,
                  align: NSTextAlignment = .left, weight: UIFont.Weight = .semibold) {
            let para = NSMutableParagraphStyle(); para.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: col, .paragraphStyle: para]
            (s as NSString).draw(in: rect, withAttributes: attrs)
        }

        var cy = card.minY + pad
        let lx = card.minX + 8, rx = card.maxX - 8, innerW = rx - lx
        // 栏顶居中实时价
        draw(content.cursorPriceText, CGRect(x: lx, y: cy, width: innerW, height: topRowH - 4),
             color(content.cursorPriceColor), size: 15, align: .center)
        cy += topRowH
        // 日期(左) · 时间(右)
        draw(content.dateText, CGRect(x: lx, y: cy, width: innerW, height: rowH), color(.neutral))
        if let t = content.timeText {
            draw(t, CGRect(x: lx, y: cy, width: innerW, height: rowH), color(.neutral), align: .right)
        }
        cy += rowH
        // 字段行：标签左、值右
        for row in content.rows {
            draw(row.label, CGRect(x: lx, y: cy, width: innerW, height: rowH),
                 UIColor(white: 0.55, alpha: 1), weight: .regular)
            draw(row.value, CGRect(x: lx, y: cy, width: innerW, height: rowH), color(row.color), align: .right)
            cy += rowH
        }
    }

    /// RFC-B D1：透明文字、无底框（同花顺式）。去掉 background 实心填充，
    /// 加细阴影防糊在 K 线上不可读。10pt 系统字体，居中。轴标 + crosshair 标共用。
    func drawLabelBox(ctx: CGContext, rect: CGRect, text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: currentPalette.text,
        ]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        let drawX = rect.midX - size.width / 2
        let drawY = rect.midY - size.height / 2
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setShadow(offset: .zero, blur: 2.5, color: currentPalette.background.cgColor)  // 描边式阴影
        str.draw(at: CGPoint(x: drawX, y: drawY), withAttributes: attrs)
    }
}

#endif
