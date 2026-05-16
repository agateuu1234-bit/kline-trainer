// Kline Trainer Swift Contracts — C4 成交量副图渲染 extension stub
// Spec: kline_trainer_modules_v1.4.md §C4（Volume + MACD，使用 IndicatorMapper）

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C4 成交量副图柱状 stub。Wave 1 C4 落地：indexToX + valueToY，红涨绿跌色（与蜡烛同步）。
    func drawVolume(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C4): implement volume bar rendering
    }
}

#endif
