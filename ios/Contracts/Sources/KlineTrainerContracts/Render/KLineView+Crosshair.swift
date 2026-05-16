// Kline Trainer Swift Contracts — C5 十字光标辅助层 extension stub
// Spec: kline_trainer_modules_v1.4.md §C5（Crosshair；point optional 表无光标）

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C5 十字光标 stub。Wave 1 C5 落地：point 非空时画十字线 + 价格/时间标签框。
    func drawCrosshair(ctx: CGContext, at point: CGPoint?, viewport: ChartViewport) {
        // Wave 1 (C5): implement crosshair lines + price/time labels when point != nil
    }
}

#endif
