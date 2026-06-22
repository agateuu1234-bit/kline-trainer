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
            Button { expanded = true } label: { Image(systemName: "pencil.tip.crop.circle") }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .accessibilityLabel("画线工具")
        }
    }
}
#endif
