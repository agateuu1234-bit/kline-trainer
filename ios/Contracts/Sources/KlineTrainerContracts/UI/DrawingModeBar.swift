// Sources/KlineTrainerContracts/UI/DrawingModeBar.swift
#if canImport(UIKit)
import SwiftUI

/// 画线底栏（单行）：①「类型」键 + ②🔒 锁定 + ③🗑 删除 + **④↩ 撤销 + ⑤↪ 前进（1b-ii 撤销 PR）**。
/// 至此为母 spec §2 的 5 键终局形态。
/// 与 TradeActionBar/ReviewControlBar 共享同一个 `BottomBarMetrics.height` 固定高度 → 三者切换零跳动。
struct DrawingBottomBar: View {
    @Binding var typeRowExpanded: Bool
    /// D71「锁定可用」谓词的结果。**本视图自己不判任何东西**——判据全在 `DrawingEditRouter`。
    let lockEnabled: Bool
    /// 选中线当前是否锁定 —— 只决定图标形态（闭锁 / 开锁），不参与可用性。
    let lockIsOn: Bool
    let onToggleLock: () -> Void
    /// D65「删除可用」谓词的结果。**本视图自己不判任何东西**——几何/locked/唯一性/复盘四个分量
    /// 都在 `DrawingEditRouter.canDelete` 里，视图只负责显示。
    let deleteEnabled: Bool
    /// 只负责**弹确认框**，绝不直接删（D65 R13-F1：弹框期间线可能滑出屏，几何必须在确认那一刻重算）。
    let onDelete: () -> Void
    /// D78「撤销可用」谓词的结果。**本视图自己不判任何东西**——判据全在 `DrawingEditRouter`。
    /// ⚠️ 这个谓词**刻意不含**几何与选中分量（与 🔒/🗑 不同）：撤销是会话级操作。
    ///    形状不一致是**有意的**，不要"顺手统一"（D78）。
    let undoEnabled: Bool
    let onUndo: () -> Void
    /// D78「前进可用」谓词的结果。理由同上。
    let redoEnabled: Bool
    let onRedo: () -> Void

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
            Button(action: onToggleLock) {
                Image(systemName: lockIsOn ? "lock" : "lock.open")
            }
                .accessibilityLabel(lockIsOn ? "解锁" : "锁定")
                .disabled(!lockEnabled)
            Button(action: onDelete) { Image(systemName: "trash") }
                .accessibilityLabel("删除")
                .disabled(!deleteEnabled)
            Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }
                .accessibilityLabel("撤销")
                .disabled(!undoEnabled)
            Button(action: onRedo) { Image(systemName: "arrow.uturn.forward") }
                .accessibilityLabel("前进")
                .disabled(!redoEnabled)
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
