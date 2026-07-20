// ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift
// 1a-iii 切片1 Task2：类型行改 overlay（不占 chartPanels VStack 高度，浮在图表上方，`.overlay(alignment: .bottom)`
// 挂在 TrainingView.chartPanels）。内容从旧 DrawingModeBar.typeRow 原样平移（本期只 1 个水平线图标、恒亮、
// 无 toggle；D19：不 ship 未接线的 ②–⑤）。
// 1a-iii 切片2 Task3：本视图现是 `DrawingStylePanel`（常驻面板，替代长按卡片）的类型行子块——展开与否
// 已由 `ChartPanelsContainer` 的挂载条件单独决定（面板存在即展开），本视图不再自判 expanded、也不再持有
// 长按手势（长按弹卡片的设置入口已被常驻面板取代）；第一道命中盾整体上移到 `DrawingStylePanel` 根
// （整块面板统一吞点，留在这里只护住类型行那一条会漏掉参数区）。右端新增 ⇅ 切上/下半区（Task4 接真行为）。
//
// 双层命中屏蔽（trade-safety-critical：防误画+autosave 幽灵线）：
//   第一道盾 = `DrawingStylePanel` 根 `.contentShape(Rectangle())` + 吞点 `.onTapGesture {}`——挡住直接落在
//     面板上的点击不穿透到下层图表（SwiftUI 手势层面）。
//   第二道盾 = `ChartPanelsContainer` 把 `DrawingStylePanel`（经 GeometryReader）的 frame 与两个面板 frame
//     求交，写入 `DrawingSession.shield`（面板局部坐标三态），`ChartContainerView.handleDrawingTap` 据此
//     拒绝命中（输入层面，可单测）。
#if canImport(UIKit)
import SwiftUI

struct DrawingTypeOverlay: View {
    let onTogglePosition: () -> Void          // 1a-iii 切片2 Task3：⇅ 切换面板上/下半区（Task4 接真行为）

    // 类型行：本期只 1 个水平线图标，恒亮浅蓝框（D38：本期无选中、不做 toggle）。
    var body: some View {
        HStack(spacing: 12) {
            Button { /* 本期短按 no-op：只有一个工具、已恒选中 */ } label: {
                Image(systemName: "minus")
                    .frame(width: 40, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("水平线")
            Spacer()
            Button(action: onTogglePosition) {
                Image(systemName: "arrow.up.arrow.down")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color.secondary)
            }
            .accessibilityLabel("切换面板位置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}
#endif
