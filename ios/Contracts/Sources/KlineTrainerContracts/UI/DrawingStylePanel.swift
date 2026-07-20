// Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift
// 1a-iii 切片2 Task3：常驻样式面板 = 「类型行 + 参数」一个整体，由底栏①「类型」键统一开/合。
// 盖在 K 线上的 overlay（遮挡、**不挤压** K 线——布局不变量见 DrawingLayoutInvariantTests）。
// 上下摆放与镜像在 Task4 接线；本 task 先固定下半区形态：视觉自上而下 = 参数 → 类型行（类型行贴底栏）。
#if canImport(UIKit)
import SwiftUI

/// 面板挂靠的半区。Task 3 只用 `.bottom`；Task 4 补 ⇅ 真行为与上半区镜像/盾。
enum DrawingStylePanelPosition {
    case top
    case bottom
}

struct DrawingStylePanel: View {
    let session: DrawingSession
    let scheme: AppColorScheme
    let position: DrawingStylePanelPosition
    let onTogglePosition: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 镜像只翻「类型行 ↔ 参数」两大块；参数内部 5 组顺序两态相同、不翻（user 确认）。
            if position == .top {
                DrawingTypeOverlay(onTogglePosition: onTogglePosition)
                Divider()
                DrawingStyleParams(session: session, scheme: scheme)
            } else {
                DrawingStyleParams(session: session, scheme: scheme)
                Divider()
                DrawingTypeOverlay(onTogglePosition: onTogglePosition)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        // 第一道盾：吞掉落在面板上的点击，不穿透到下层图表（第二道盾 = ChartPanelsContainer 的 shieldRect）。
        // ⭐codex 计划-R1-F2：`.contentShape` 必须**紧贴可见内容**、在任何 padding **之前**——
        //   本视图的边界 == 用户看得见的那块圆角材质，一个像素的透明外边距都不许算进来。
        .contentShape(Rectangle())
        .onTapGesture {}
        // ⚠️**与计划原稿的刻意分歧（上游派发前已明确指出）**：原稿这里要求再挂
        //   `.onAppear { session.setStylePanelVisible(true) }` / `.onDisappear { session.setStylePanelVisible(false) }`
        //   作为 fail-closed 的可见性信号源。但 Task 2（commit a1e420c）hosted 测试实证：`ImageRenderer`
        //   离屏渲染拆除会**多触发一次 `.onDisappear`**（面板逻辑上从未真正消失），若这里自己置位可见性，
        //   刚算好的盾会被这次假消失清空——四个屏蔽差分测试当场假红（见 TrainingView.swift 的
        //   `stylePanelVisible` 大注释）。可见性单一真相已改由 `ChartPanelsContainer.stylePanelVisible`
        //   计算属性 + 三个 PreferenceKey 收敛（`refreshShields()`）统一维护，**不再依赖任何一次性生命周期
        //   事件**。本视图刻意不再持有 onAppear/onDisappear，避免重新引入已被证伪的设计、也避免与
        //   `ChartPanelsContainer` 的单一真相打架（两处都能写 shield，谁后写谁赢）。
        .accessibilityIdentifier("drawingStylePanel")
        // ⚠️**本视图刻意不加 .padding**：离屏边距由调用方在**量完 frame 之后**施加（见 Task3 Step6）。
        //   否则 call-site 的 GeometryReader 量到的是「含 8pt 透明外边距」的框，那圈看不见的边距会被
        //   写进 shieldRect → 图表上出现**看不见的死条**（点了没反应、也画不了线），且上半区时
        //   还与「类型行顶边贴上半 K 线顶边」的对齐语义打架。
    }
}
#endif
