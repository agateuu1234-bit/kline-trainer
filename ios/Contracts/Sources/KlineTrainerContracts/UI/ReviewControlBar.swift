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

/// 平台无关纯内容（host-可测）：决定复盘条显示哪些按钮 + 下单价文案。
/// `showsJumpToEnd=false` → [「下一根」]；`true` → [「下一根」, 「快进到结尾」]。
public struct ReviewControlBarContent: Equatable, Sendable {
    public let buttons: [ReviewControlButton]
    public let priceLabel: String
    public init(showsJumpToEnd: Bool, price: Double) {
        var b = [ReviewControlButton(action: .step, title: "下一根")]
        if showsJumpToEnd { b.append(ReviewControlButton(action: .jumpToEnd, title: "快进到结尾")) }
        self.buttons = b
        // 复刻 TradeActionBarContent.init(price:) 的 formatter（sibling-decoupled，项目惯例=复制不共享）。
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let body = f.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)
        self.priceLabel = "下单价 ¥ \(body)"
    }
}

#if canImport(UIKit)
import SwiftUI

/// 复盘专用控件条 SwiftUI 薄壳：仅复盘可步进态显示（canAdvance && !canBuySell）。
/// 训练底栏样式（同 TradeActionBar）：[上图|下图]分段器 + 下单价 + 下一根（强调）+ [快进到结尾]。
/// 动作经单一 onAction 闭包上交；不含买/卖（非交易态）。
public struct ReviewControlBar: View {
    private let content: ReviewControlBarContent
    let upperPeriod: Period
    let lowerPeriod: Period
    @Binding var activePanel: PanelId
    private let onAction: (ReviewControlAction) -> Void

    public init(showsJumpToEnd: Bool, price: Double, upperPeriod: Period, lowerPeriod: Period,
                activePanel: Binding<PanelId>, onAction: @escaping (ReviewControlAction) -> Void) {
        self.content = ReviewControlBarContent(showsJumpToEnd: showsJumpToEnd, price: price)
        self.upperPeriod = upperPeriod
        self.lowerPeriod = lowerPeriod
        self._activePanel = activePanel
        self.onAction = onAction
    }

    public var body: some View {
        HStack(spacing: 8) {
            Picker("步进周期", selection: $activePanel) {
                Text(upperPeriod.shortLabel).tag(PanelId.upper)
                Text(lowerPeriod.shortLabel).tag(PanelId.lower)
            }
            .pickerStyle(.segmented)
            .frame(width: 104)
            .accessibilityLabel("步进周期")
            Text(content.priceLabel)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            ForEach(content.buttons, id: \.action) { btn in
                Button { onAction(btn.action) } label: {
                    Text(btn.title).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .tint(.blue)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .font(.system(size: 14).weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
    }
}
#endif
