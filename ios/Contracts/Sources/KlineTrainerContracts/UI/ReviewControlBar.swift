// ios/Contracts/Sources/KlineTrainerContracts/UI/ReviewControlBar.swift
// 复盘控件条（新需求10）：纯内容模型（host-可测）+ SwiftUI 薄壳（Catalyst 编译闸门）。
// 范式同 TradeActionBarContent/SettlementContent：内容 host 测，薄壳 #if canImport(UIKit)。

import Foundation

/// 复盘控件条动作。Hashable 供 SwiftUI ForEach id。
public enum ReviewControlAction: Hashable, Sendable { case step, jumpToEnd }

/// 复盘控件条单按钮（动作 + 文案）。
public struct ReviewControlButton: Equatable, Sendable {
    public let action: ReviewControlAction
    public let title: String
    public init(action: ReviewControlAction, title: String) { self.action = action; self.title = title }
}

/// 平台无关纯内容（host-可测）：决定复盘条显示哪些按钮。
/// `showsJumpToEnd=false` → [「下一根」]；`true` → [「下一根」, 「快进到结尾」]。
public struct ReviewControlBarContent: Equatable, Sendable {
    public let buttons: [ReviewControlButton]
    public init(showsJumpToEnd: Bool) {
        var b = [ReviewControlButton(action: .step, title: "下一根")]
        if showsJumpToEnd { b.append(ReviewControlButton(action: .jumpToEnd, title: "快进到结尾")) }
        self.buttons = b
    }
}

#if canImport(UIKit)
import SwiftUI

/// 复盘专用控件条 SwiftUI 薄壳：仅复盘可步进态显示（canAdvance && !canBuySell）。
/// 动作经单一 onAction 闭包上交；不含买/卖（非交易态）。
public struct ReviewControlBar: View {
    private let content: ReviewControlBarContent
    private let onAction: (ReviewControlAction) -> Void

    public init(showsJumpToEnd: Bool, onAction: @escaping (ReviewControlAction) -> Void) {
        self.content = ReviewControlBarContent(showsJumpToEnd: showsJumpToEnd)
        self.onAction = onAction
    }

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(content.buttons, id: \.action) { btn in
                Button { onAction(btn.action) } label: {
                    Text(btn.title).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
    }
}
#endif
