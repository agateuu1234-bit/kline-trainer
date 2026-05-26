// Kline Trainer Swift Contracts — C4 MACD 副图渲染 extension（Wave 1 真实现）
// Spec: kline_trainer_modules_v1.4.md §C4（DIF + DEA + MACD bar；spec v1.5 §2: DIF 白 / DEA 黄）
// 几何来自 SubChartLayout（平台无关，host 已测）；本文件仅 UIKit 描边/填充薄层。
// §15.1 #3 编译验证：本文件方法签名与 KLineView.draw(_:) 派发点逐字匹配。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C4 MACD：DIF（白）+ DEA（黄）折线（实线，D3）+ 柱（正红负绿，D11 基线钳制）。
    /// 颜色 token: AppColor.macdDIF / .macdDEA / .macdBarPositive / .macdBarNegative（D4，F2 已冻结）。
    func drawMACD(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>) {
        guard !candles.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 柱先画（在折线下方视觉层次）
        for bar in SubChartLayout.macdBars(for: candles, mapper: mapper) {
            let color = bar.isPositive ? AppColor.macdBarPositive : AppColor.macdBarNegative
            color.setFill()
            ctx.fill(bar.rect)
        }

        // DIF / DEA 折线（D3 实线 / D9a 单点段跳过）
        let lines = SubChartLayout.macdLines(for: candles, mapper: mapper)
        ctx.setLineWidth(1 / mapper.displayScale)
        ctx.setLineJoin(.round)

        AppColor.macdDIF.setStroke()
        for segment in lines.dif where segment.count >= 2 {
            ctx.move(to: segment[0])
            for point in segment.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }

        AppColor.macdDEA.setStroke()
        for segment in lines.dea where segment.count >= 2 {
            ctx.move(to: segment[0])
            for point in segment.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }
    }
}

#endif
