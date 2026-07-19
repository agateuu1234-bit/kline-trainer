// ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift
// 1a-iii 切片1 Task2：类型行改 overlay（不占 chartPanels VStack 高度，浮在图表上方，`.overlay(alignment: .bottom)`
// 挂在 TrainingView.chartPanels）。内容从旧 DrawingModeBar.typeRow 原样平移（本期只 1 个水平线图标、恒亮、
// 无 toggle；D19：不 ship 未接线的 ②–⑤）。
//
// 双层命中屏蔽（trade-safety-critical：防误画+autosave 幽灵线）：
//   第一道盾 = 本视图根 `.contentShape(Rectangle())` + 吞点 `.onTapGesture {}`——挡住直接落在 overlay 上的点击
//     不穿透到下层图表（SwiftUI 手势层面）。
//   第二道盾 = TrainingView 把本视图（经 GeometryReader）的 frame 转成下面板局部坐标写入
//     `DrawingSession.shieldRect`，`ChartContainerView.handleDrawingTap` 据此拒绝命中（输入层面，可单测）。
#if canImport(UIKit)
import SwiftUI

struct DrawingTypeOverlay: View {
    let expanded: Bool
    let onLongPressType: () -> Void          // 长按水平线图标 → 呈现设置卡片（Task 5 接线）

    var body: some View {
        if expanded {
            typeRow
                .contentShape(Rectangle())   // 第一道盾：吞点手势的命中形状
                .onTapGesture {}             // 第一道盾：吞掉落在 overlay 上的点击，不穿透到下层图表
        }
    }

    // 类型行：本期只 1 个水平线图标，恒亮浅蓝框（D38：本期无选中、不做 toggle）。
    private var typeRow: some View {
        HStack(spacing: 12) {
            Button { /* 本期短按 no-op：只有一个工具、已恒选中 */ } label: {
                Image(systemName: "minus")
                    .frame(width: 40, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("水平线")
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in onLongPressType() })
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }
}
#endif
