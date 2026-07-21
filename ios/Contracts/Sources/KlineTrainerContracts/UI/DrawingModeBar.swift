// Sources/KlineTrainerContracts/UI/DrawingModeBar.swift
#if canImport(UIKit)
import SwiftUI

/// 画线底栏（单行，1a-iii 切片 1）：只①类型键（收/展类型行，Task 2 接 overlay）。②–⑤ 本期不渲染（D19/D24）。
/// 与 TradeActionBar/ReviewControlBar 沿用同一套按钮构造配方（buttonStyle/controlSize/font/padding），
/// 但配方相同不保证测出来的高度相同（Catalyst 真机测量证伪：内容量不同，headless sizeThatFits 还会随
/// 宽度改变、不可靠）——三者改为显式共享同一个 `BottomBarMetrics.height` 固定高度（1a-iii 切片1 Task1
/// fix），保证训练/画线/复盘切换零跳动，且钉一个数字比钉一套配方更能被测试直接锚定、防未来漂移。
struct DrawingBottomBar: View {
    @Binding var typeRowExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { typeRowExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "minus")   // 与类型行水平线图标一致（DrawingTypeOverlay）
                    Text("类型")
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(typeRowExpanded ? 0 : 180))   // 收起态朝上，展开态朝下
                }
            }
            .accessibilityLabel("类型")
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .font(.system(size: 14).weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        // 与 TradeActionBar/ReviewControlBar 共享同一固定高度（1a-iii 切片1 Task1 fix）→ 三者切换零跳动。
        .frame(height: BottomBarMetrics.height)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
    }
}
#endif
