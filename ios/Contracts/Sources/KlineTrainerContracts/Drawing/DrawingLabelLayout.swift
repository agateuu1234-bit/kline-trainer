// DrawingLabelLayout.swift —— 价格标签矩形（纯函数，host 可测）。
// 「不压线」= 标签底边贴在线上方 gap 处；「右缘不溢出」= 右对齐时右边界裁到主图右缘内。
// Foundation 显式导入：`labelContent` 用 `String(format:)`（Foundation API），不依赖 CoreGraphics 的传递导入
// （Swift import file-scoped；同 target 内 CrosshairLayout.swift / AxisGridLayout.swift 同款写法）。
import Foundation
import CoreGraphics

public enum DrawingLabelLayout {
    private static let gap: CGFloat = 2   // 标签与线的间隙

    public static func labelRect(mode: LabelMode, lineY: CGFloat,
                                 lineXRange: (minX: CGFloat, maxX: CGFloat),
                                 textSize: CGSize, mainChartFrame: CGRect) -> CGRect? {
        let x: CGFloat
        switch mode {
        case .hidden:       return nil
        case .show, .left:  x = lineXRange.minX                    // 锚线左端（水平线只 隐藏/左/右，.show 归左）
        case .right:        x = lineXRange.maxX - textSize.width   // 锚线右端
        }
        return placed(x: x, lineY: lineY, textSize: textSize, mainChartFrame: mainChartFrame)
    }

    // 统一裁剪（codex plan-R3）：x 收进 [minX, maxX-textWidth]——左右都不溢出，含射线锚近右缘时的 .left/.show；
    // y 优先线【上方】（不压线），上方顶到主图上缘放不下时改放线【下方】（仍不压线）。
    private static func placed(x: CGFloat, lineY: CGFloat, textSize: CGSize, mainChartFrame: CGRect) -> CGRect {
        let maxX = max(mainChartFrame.minX, mainChartFrame.maxX - textSize.width)
        let clampedX = min(max(x, mainChartFrame.minX), maxX)
        let above = lineY - gap - textSize.height
        let y = above >= mainChartFrame.minY ? above : lineY + gap   // 上方无空间 → 线下方
        return CGRect(x: clampedX, y: y, width: textSize.width, height: textSize.height)
    }
}

// labelContent：决定「画不画标注 + 画什么文字 + 什么色 + 哪种对齐」。全部决策在此 host 可测纯函数里，
// UIKit dispatch 层只机械绘制（codex plan-R8：决策逻辑不能只活在 #if canImport(UIKit) 的绘制块里）。
public struct DrawingLabelContent: Equatable {
    public let text: String
    public let colorToken: DrawingColorToken
    public let mode: LabelMode          // 只会是 .left / .right（对齐用；.show 归 .left）
}
extension DrawingLabelLayout {
    // lineVisible = 该线是否有可见几何（HorizontalLineTool.lineXRange != nil）——segment / 超界射线为 false。
    public static func labelContent(for drawing: DrawingObject, lineVisible: Bool) -> DrawingLabelContent? {
        guard drawing.toolType == .horizontal else { return nil }   // 本期只水平线接线
        guard lineVisible else { return nil }                       // 线不可见 → 标注也不画（fail-closed 一致）
        let mode: LabelMode
        switch drawing.labelMode {
        case .hidden:       return nil
        case .show, .left:  mode = .left
        case .right:        mode = .right
        }
        let text = String(format: "%.2f", drawing.anchors.first?.price ?? 0)
        return DrawingLabelContent(text: text, colorToken: drawing.textColorToken, mode: mode)
    }
}
