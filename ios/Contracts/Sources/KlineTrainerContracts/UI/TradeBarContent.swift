// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarContent.swift
// Spec: docs/superpowers/specs/2026-06-20-trade-bar-inline-design.md §4.2/§5.1
//
// 平台无关纯值类型：把 action(.buy/.sell) 翻译成 SwiftUI 渲染用的 5 chip 有序数组。
// 仅 import Foundation —— host swift test 全测（同 PositionPickerContent 范式）。
//
// 决议：
// - tier1–4：label = PositionTier.rawValue（"1/5".."4/5"），isShortcut = false。
// - tier5：label = action==.buy ? "全仓" : "清仓"，isShortcut = true（UI 强调快捷档）。
//   底层仍是 PositionTier.tier5 → engine.buy/sell(tier:.tier5) 即现有全仓/清仓引擎路径（零引擎改动）。
// - 迭代 PositionTier.allCases（杜绝 Set 迭代不确定性，同 PositionPickerContent D4）。

import Foundation

public enum TradeAction: Equatable, Sendable {
    case buy
    case sell
}

public struct TradeBarContent: Equatable, Sendable {
    public struct Chip: Equatable, Sendable {
        public let tier: PositionTier
        public let label: String
        public let isShortcut: Bool

        public init(tier: PositionTier, label: String, isShortcut: Bool) {
            self.tier = tier
            self.label = label
            self.isShortcut = isShortcut
        }
    }

    public let action: TradeAction
    public let chips: [Chip]

    public init(action: TradeAction) {
        self.action = action
        self.chips = PositionTier.allCases.map { tier in
            if tier == .tier5 {
                return Chip(tier: tier, label: action == .buy ? "全仓" : "清仓", isShortcut: true)
            } else {
                return Chip(tier: tier, label: tier.rawValue, isShortcut: false)
            }
        }
    }
}
