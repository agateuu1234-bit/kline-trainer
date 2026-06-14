// Kline Trainer Swift Contracts — C5 交易标记渲染（UIKit 薄层）
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313 + plan v1.5 §4.3 L753-771
//
// 几何/锚位/字母字符在 MarkersLayout.swift（平台无关）；本文件只做 UIKit 圆点 + 字母。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C5 交易标记：遍历 markers，二分定位候选 K 线（D9 越界跳过），
    /// dot center 锚到收盘价 Y（D10），buy = currentPalette.candleUp + "B"，sell = currentPalette.candleDown + "S"（顺位9 scheme-aware）。
    func drawMarkers(ctx: CGContext,
                     viewport: ChartViewport,
                     mapper: CoordinateMapper,
                     markers: [TradeMarker],
                     candles: ArraySlice<KLineCandle>) {
        guard !markers.isEmpty, !candles.isEmpty else { return }
        let placements = MarkersLayout.markerPlacements(
            mapper: mapper, markers: markers, candles: candles)
        guard !placements.isEmpty else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // D10：dot 半径 5pt，字母 10pt bold 白色居中。
        let radius: CGFloat = 5
        let font = UIFont.boldSystemFont(ofSize: 10)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: currentPalette.text,
        ]

        for p in placements {
            let color: UIColor
            let letter: String
            switch p.direction {
            case .buy:  color = currentPalette.candleUp;   letter = "B"
            case .sell: color = currentPalette.candleDown; letter = "S"
            }
            color.setFill()
            let dotRect = CGRect(x: p.center.x - radius, y: p.center.y - radius,
                                 width: radius * 2, height: radius * 2)
            ctx.fillEllipse(in: dotRect)

            let str = letter as NSString
            let size = str.size(withAttributes: textAttrs)
            let drawX = p.center.x - size.width / 2
            let drawY = p.center.y - size.height / 2
            str.draw(at: CGPoint(x: drawX, y: drawY), withAttributes: textAttrs)
        }
    }
}

#endif
