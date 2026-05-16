// Kline Trainer Swift Contracts — C4 MACD 副图渲染 extension stub
// Spec: kline_trainer_modules_v1.4.md §C4（DIF + DEA + MACD bar；spec v1.5 §2: DIF 白 / DEA 黄）

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C4 MACD 副图 stub。Wave 1 C4 落地：DIF/DEA 两线 polyline + MACD bar 柱（正负色）。
    /// 颜色 token: AppColor.macdDIF (白) / .macdDEA (黄) / .macdBarPositive / .macdBarNegative。
    func drawMACD(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C4): implement MACD DIF/DEA polyline + bar rendering
    }
}

#endif
