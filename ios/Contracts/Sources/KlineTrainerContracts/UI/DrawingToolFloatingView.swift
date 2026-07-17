import CoreGraphics

/// 平台无关纯几何：把拖动后的 proposed 左上角钳制在 bounds 内（控件尺寸 size）。host 可测。
public enum DrawingFloatLayout {
    public static func clampedOffset(proposed: CGPoint, bounds: CGRect, size: CGSize) -> CGPoint {
        let maxX = max(bounds.minX, bounds.maxX - size.width)
        let maxY = max(bounds.minY, bounds.maxY - size.height)
        return CGPoint(x: min(max(proposed.x, bounds.minX), maxX),
                       y: min(max(proposed.y, bounds.minY), maxY))
    }
}

#if canImport(UIKit)
import SwiftUI

/// RFC-B D2：浮动可拖动画线控件。折叠=圆按钮(✎)；点开=工具条（水平线 + 收起）；
/// 拖动整体；仅手动点收起图标才折叠（不自动收）。仅 showsTradeButtons 时由 TrainingView 渲染。
struct DrawingToolFloatingView: View {
    let isDrawingActive: Bool
    let onToggleTool: () -> Void      // 激活/取消水平线（= TrainingView.toggleDrawing）
    @State private var expanded = false
    @State private var offset = CGSize(width: 12, height: 80)
    @State private var dragBase = CGSize.zero

    var body: some View {
        GeometryReader { geo in
            content
                .offset(offset)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            let proposed = CGPoint(x: dragBase.width + v.translation.width,
                                                   y: dragBase.height + v.translation.height)
                            let clamped = DrawingFloatLayout.clampedOffset(
                                proposed: proposed,
                                bounds: CGRect(origin: .zero, size: geo.size),
                                size: CGSize(width: 160, height: 44))
                            offset = CGSize(width: clamped.x, height: clamped.y)
                        }
                        .onEnded { _ in dragBase = offset }
                )
                .onAppear { dragBase = offset }
        }
    }

    @ViewBuilder private var content: some View {
        if expanded {
            HStack(spacing: 6) {
                Button(isDrawingActive ? "结束画线" : "水平线") { onToggleTool() }
                    .tint(isDrawingActive ? .orange : nil)
                    .accessibilityLabel("水平线")
                Button { expanded = false } label: { Image(systemName: "chevron.left.circle") }
                    .accessibilityLabel("收起画线工具")
            }
            .buttonStyle(.bordered)
            .padding(6)
            .background(.thinMaterial, in: Capsule())
        } else {
            // P1b-1a-ii 回归修复（现象①：连续画线让画线模式持续，收起工具条后小圆圈看不出还在画线 → 隐形卡死）：
            // 画线模式开时，折叠圆圈钮变**橙色实心**（一眼看出在画线），且点它**直接退出画线**（而非展开工具条）——
            // 给用户「随手收起也能一键退出」的可靠出口。画线模式关时保持原行为（点=展开工具条）。
            Button {
                if isDrawingActive { onToggleTool() } else { expanded = true }
            } label: {
                Image(systemName: isDrawingActive ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            }
            .buttonStyle(.bordered)
            .tint(isDrawingActive ? .orange : nil)
            .clipShape(Circle())
            .accessibilityLabel(isDrawingActive ? "结束画线" : "画线工具")
        }
    }
}
#endif
