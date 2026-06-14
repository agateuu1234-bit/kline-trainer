// Kline Trainer Swift Contracts — C4 成交量副图渲染 extension（Wave 1 真实现）
// Spec: kline_trainer_modules_v1.4.md §C4（Volume + MACD，使用 IndicatorMapper）
// 几何来自 SubChartLayout（平台无关，host 已测）；本文件仅 UIKit 描边/填充薄层。
// §15.1 #3 编译验证：本文件方法签名与 KLineView.draw(_:) 派发点逐字匹配。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C4 成交量柱：柱矩形（涨/跌色填充，与主图蜡烛同步 D7）。
    /// 几何来自 SubChartLayout.volumeBars（host 已测）；本方法仅 UIKit 填充。
    func drawVolume(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>) {
        guard !candles.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        for bar in SubChartLayout.volumeBars(for: candles, mapper: mapper) {
            let color = bar.isUp ? currentPalette.candleUp : currentPalette.candleDown
            color.setFill()
            ctx.fill(bar.rect)
        }
    }
}

#endif
