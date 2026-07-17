// Sources/KlineTrainerContracts/UI/DrawingModeBar.swift
// 两行画线底栏骨架（1a-iii，D24 一次定型）。上行=类型行（本期只水平线 1 图标、恒亮、无 toggle）；
// 下行=只①类型键（收/展类型行）。②–⑤ 本期不渲染（D19：不 ship 未接线控件）。仅训练/replay 出现。
#if canImport(UIKit)
import SwiftUI

struct DrawingModeBar: View {
    @Binding var typeRowExpanded: Bool
    let onLongPressType: () -> Void          // 长按水平线图标 → 呈现设置卡片（Task 5 接线）

    var body: some View {
        VStack(spacing: 6) {
            if typeRowExpanded {
                typeRow
            }
            bottomRow
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
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
    }

    // 下行：只①类型键（收/展类型行）。②–⑤ 不渲染。
    private var bottomRow: some View {
        HStack(spacing: 12) {
            Button { typeRowExpanded.toggle() } label: {
                Image(systemName: "list.bullet").frame(width: 40, height: 32)
            }
            .accessibilityLabel("类型")
            Spacer()
        }
        .padding(.horizontal, 12)
    }
}
#endif
