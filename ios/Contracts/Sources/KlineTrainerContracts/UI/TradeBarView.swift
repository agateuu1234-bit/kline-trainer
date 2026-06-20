// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarView.swift
// Spec: docs/superpowers/specs/2026-06-20-trade-bar-inline-design.md §4.3/§5.2
//
// 薄 SwiftUI shell：横排 5 chip Button + 取消(✕)；数据映射交 TradeBarContent（Task 1）。
// 平台无关 SwiftUI（不加 #if canImport(UIKit)，同 PositionPickerView 跨 iOS17/macOS14/Catalyst）。
//
// 决议：
// - 单 tap 直接 fire onPick(chip.tier)，无二次确认（同 PositionPickerView D8）。
// - View 不调 dismiss，收起由 caller(TrainingView) 负责（同 D15）。
// - tier5（全仓/清仓，chip.isShortcut）用 .borderedProminent 强调，其余 .bordered（设计 D5 强调色）。
// - onPick/onCancel @escaping（Swift 编译强制）。

import SwiftUI

public struct TradeBarView: View {
    private let content: TradeBarContent
    private let onPick: (PositionTier) -> Void
    private let onCancel: () -> Void

    public init(action: TradeAction,
                onPick: @escaping (PositionTier) -> Void,
                onCancel: @escaping () -> Void) {
        self.content = TradeBarContent(action: action)
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(content.chips, id: \.tier) { chip in
                chipButton(chip)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    // tier5 全仓/清仓档强调（.borderedProminent），其余 .bordered。
    // 两分支各为具体 ButtonStyle 类型，用 @ViewBuilder if/else 统一（避免 ternary 类型不一致）。
    @ViewBuilder
    private func chipButton(_ chip: TradeBarContent.Chip) -> some View {
        if chip.isShortcut {
            Button(action: { onPick(chip.tier) }) {
                Text(chip.label).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: { onPick(chip.tier) }) {
                Text(chip.label).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
    }
}

#if DEBUG
#Preview("买入小条") {
    TradeBarView(action: .buy, onPick: { _ in }, onCancel: {})
}

#Preview("卖出小条") {
    TradeBarView(action: .sell, onPick: { _ in }, onCancel: {})
}
#endif
