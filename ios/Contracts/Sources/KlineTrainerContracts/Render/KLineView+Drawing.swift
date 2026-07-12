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

            // KLineView+Drawing.swift —— tool.render 之后画价格标签。UIKit 层【零决策】：画不画/文字/色/对齐全在 labelContent，
            // 位置全在 labelRect，本块只负责机械绘制（文字绘制范式同 KLineView+Markers.swift:46-51 / KLineView+Crosshair.swift:112-123）。
            if drawing.toolType == .horizontal,
               let g = HorizontalLineTool.visibleGeometry(for: drawing, mapper: mapper) {   // nil = segment/超界射线/价格超出可见区间（fail-closed，codex branch-R3）
                if let content = DrawingLabelLayout.labelContent(for: drawing, lineVisible: true) {
                    let rgba = DrawingColorResolver.resolve(content.colorToken, scheme: scheme)
                    let color = UIColor(red: CGFloat(rgba.red), green: CGFloat(rgba.green), blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha))
                    // fontSize 先 clamp 再进 UIKit（codex branch-R5 medium）：持久化的 fontSize 是任意 Int，
                    // 负数 / 极大值原样喂给 UIFont + size(withAttributes:) 会让 CoreText 崩溃/卡死/极慢——
                    // 而 labelRect 的 fail-closed 守卫在【测量之后】才跑。故 sanitize 必须是本块第一次碰 fontSize。
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: DrawingLabelLayout.sanitizedFontSize(drawing.fontSize)),
                        .foregroundColor: color,
                    ]
                    let textSize = (content.text as NSString).size(withAttributes: attrs)
                    if let rect = DrawingLabelLayout.labelRect(mode: content.mode, lineY: g.y, lineXRange: (g.minX, g.maxX),
                                                               textSize: textSize, mainChartFrame: mapper.viewport.mainChartFrame) {
                        UIGraphicsPushContext(ctx)
                        (content.text as NSString).draw(at: rect.origin, withAttributes: attrs)
                        UIGraphicsPopContext()
                    }
                }
            }
        }
    }
}

#endif
