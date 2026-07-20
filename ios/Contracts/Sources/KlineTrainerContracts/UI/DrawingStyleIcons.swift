// Sources/KlineTrainerContracts/UI/DrawingStyleIcons.swift
// 1a-iii 切片2 Task1：线型 / 线样式 / 粗细的「画出来」图标（spec §3：面板内这三组不写文字）。
// 数值规格全部来自 DrawingStyleIconSpec（单一真相，host 可测）；本文件只负责把它画出来。
// 颜色继承外层 foregroundStyle（选中态染色由 DrawingStyleParams 给），故图标本身不写死颜色。
#if canImport(UIKit)
import SwiftUI

/// 线型：直线 = 一段实线；射线 = 起点圆点 + 朝右箭头；线段 = 两端带端点竖杠。
struct LineSubTypeIcon: View {
    let subType: LineSubType
    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            switch subType {
            case .straight:
                var p = Path()
                p.move(to: CGPoint(x: 2, y: midY)); p.addLine(to: CGPoint(x: size.width - 2, y: midY))
                ctx.stroke(p, with: .style(.foreground), lineWidth: 2)
            case .ray:
                var line = Path()
                line.move(to: CGPoint(x: 4, y: midY)); line.addLine(to: CGPoint(x: size.width - 4, y: midY))
                ctx.stroke(line, with: .style(.foreground), lineWidth: 2)
                ctx.fill(Path(ellipseIn: CGRect(x: 1.6, y: midY - 2.4, width: 4.8, height: 4.8)),
                         with: .style(.foreground))                       // 起点圆点
                var arrow = Path()                                        // 朝右箭头
                arrow.move(to: CGPoint(x: size.width - 6, y: midY - 4))
                arrow.addLine(to: CGPoint(x: size.width, y: midY))
                arrow.addLine(to: CGPoint(x: size.width - 6, y: midY + 4))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .style(.foreground))
            case .segment:
                var p = Path()
                p.move(to: CGPoint(x: 5, y: midY)); p.addLine(to: CGPoint(x: size.width - 5, y: midY))
                p.move(to: CGPoint(x: 5, y: midY - 4)); p.addLine(to: CGPoint(x: 5, y: midY + 4))
                p.move(to: CGPoint(x: size.width - 5, y: midY - 4))
                p.addLine(to: CGPoint(x: size.width - 5, y: midY + 4))
                ctx.stroke(p, with: .style(.foreground), lineWidth: 2)
            }
        }
        .frame(width: 30, height: 14)
        .accessibilityHidden(true)     // 可访问性标签挂在外层按钮上（选项语义），图标本身不重复播报
    }
}

/// 线样式：各画一小段真实 dash（实线 + 虚线 1~4）。
struct LineStyleIcon: View {
    let style: LineStyle
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 2, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            ctx.stroke(p, with: .style(.foreground),
                       style: StrokeStyle(lineWidth: 2,
                                          dash: DrawingStyleIconSpec.dashPattern(for: style)))
        }
        .frame(width: 30, height: 12)
        .accessibilityHidden(true)
    }
}

/// 粗细：5 档各画**真实粗细**的一条线（非数字）。
struct ThicknessIcon: View {
    let thickness: Int
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 2, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            ctx.stroke(p, with: .style(.foreground),
                       lineWidth: DrawingStyleIconSpec.iconLineWidth(forThickness: thickness))
        }
        .frame(width: 26, height: 14)
        .accessibilityHidden(true)
    }
}
#endif
