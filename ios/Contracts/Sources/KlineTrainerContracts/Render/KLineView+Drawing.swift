// Kline Trainer Swift Contracts — C6 绘线渲染层 extension
// Spec: kline_trainer_modules_v1.4.md §C6 + design doc §3.2
// Wave 1 PR C6: real dispatch loop over [DrawingObject] keyed by DrawingToolType.
// Wave 1 callsites pass `tools: [:]` so for-loop continues every iteration (no paint).
// Wave 3 callsites register concrete tool implementations and render begins.

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C6 绘线渲染 dispatch loop. spec §C6 + design §3.2.
    /// Missing tool in `tools` dict → silently skip (Wave 1 default path).
    /// `period` 保留作 Wave 3 跨周期价格映射用；当前 Wave 1 不消费（@MainActor 隔离由
    /// KLineView UIView 继承，与 sibling extensions（Crosshair/Candles/Volume/MACD）一致不重声明）。
    func drawDrawings(ctx: CGContext,
                      mapper: CoordinateMapper,
                      drawings: [DrawingObject],
                      period: Period,
                      scheme: AppColorScheme,
                      tools: [DrawingToolType: any DrawingTool]) {
        _ = period  // reserved（周期过滤在 RenderStateBuilder，见 Task 6；此处仍不消费）
        for drawing in drawings {
            guard let tool = tools[drawing.toolType] else { continue }
            tool.render(ctx: ctx, mapper: mapper, drawing: drawing, scheme: scheme)
        }
    }
}

#endif
