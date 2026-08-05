// Sources/KlineTrainerContracts/UI/DrawingModeBar.swift
#if canImport(UIKit)
import SwiftUI

/// 画线底栏（单行）：①「类型」键（收/展类型行）+ **③🗑 删除键（1b-i PR-4）**。
/// ②🔒④↩⑤↪ 属 1b-ii，本期**一个占位都不渲染**（母 spec D19 / D24：不 ship 恒灰的未接线按钮）；
/// 1b-ii 落 🔒 时插在「类型」与 🗑 之间。
/// 与 TradeActionBar/ReviewControlBar 共享同一个 `BottomBarMetrics.height` 固定高度 → 三者切换零跳动。
struct DrawingBottomBar: View {
    @Binding var typeRowExpanded: Bool
    /// D65「删除可用」谓词的结果。**本视图自己不判任何东西**——几何/locked/唯一性/复盘四个分量
    /// 都在 `DrawingEditRouter.canDelete` 里，视图只负责显示。
    let deleteEnabled: Bool
    /// 只负责**弹确认框**，绝不直接删（D65 R13-F1：弹框期间线可能滑出屏，几何必须在确认那一刻重算）。
    let onDelete: () -> Void

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
            Button(action: onDelete) { Image(systemName: "trash") }
                .accessibilityLabel("删除")
                .disabled(!deleteEnabled)
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
