// Kline Trainer Swift Contracts — C3 主图渲染 extension stubs（Wave 1 真实现占位）
// Spec: kline_trainer_modules_v1.4.md §C3（主图蜡烛 + MA66 + BOLL）
// §15.1 #3 编译验证：本文件 3 个方法签名与 KLineView.draw(_:) 派发点逐字匹配。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C3 主图蜡烛渲染 stub。Wave 1 C3 落地：使用 mapper.indexToX / priceToY 画蜡烛实体 + 影线，
    /// 使用 AppColor.candleUp / .candleDown 着色（spec §F2 字面色）。
    func drawCandles(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C3): implement candle body + wick rendering
    }

    /// C3 MA66 移动平均线 stub。Wave 1 C3 落地：滑窗 66 根计算均价、polyline 画线，
    /// 使用 AppColor.ma66 着色（spec §F2 字面色）。
    func drawMA66(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C3): implement MA66 polyline rendering
    }

    /// C3 BOLL 布林带 stub。Wave 1 C3 落地：上中下三轨 polyline + 上下轨填充，
    /// 使用 AppColor.bollLine 着色（spec §F2 字面色）。
    func drawBOLL(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C3): implement BOLL upper/middle/lower band rendering
    }
}

#endif
