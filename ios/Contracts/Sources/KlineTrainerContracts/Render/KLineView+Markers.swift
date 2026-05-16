// Kline Trainer Swift Contracts — C5 交易标记辅助层 extension stub
// Spec: kline_trainer_modules_v1.4.md §C5（Markers + Crosshair；marker 二分谓词精确）

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C5 交易标记 stub。Wave 1 C5 落地：findCandleIndex 二分定位 + buy/sell 图标贴位 + 价签。
    func drawMarkers(ctx: CGContext,
                     viewport: ChartViewport,
                     mapper: CoordinateMapper,
                     markers: [TradeMarker],
                     candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C5): implement trade marker rendering with binary search index lookup
    }
}

#endif
