// ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
// Spec: kline_trainer_plan_v1.5.md §6.2.4 L946-952 + plan 2026-05-28-pr-u5-position-picker-view.md
//
// 平台无关纯值类型：把 enabledTiers: Set<PositionTier> 翻译成 SwiftUI 渲染用的 5 元素有序数组。
// 平台守卫：仅 import Foundation，不 import SwiftUI/UIKit/CoreGraphics —— host swift test 全测。
//
// 决议（D3-D5/D12/D13）：
// - D3 label = PositionTier.rawValue（"1/5".."5/5"）
// - D4 强制 tier1→tier5 升序（迭代 PositionTier.allCases，杜绝 Set 迭代不确定性）
// - D5 enabledTiers.contains(tier) 决定 enabled flag；空 Set → 全 false
// - D12 tiers 是 [Item] 数组（保持顺序）；Item 是 struct（不是 tuple）便于 Equatable/Sendable
// - D13 值类型快照：init 时一次性算 Content；不持引用观察 Set 变更

import Foundation

public struct PositionPickerContent: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let tier: PositionTier
        public let label: String
        public let enabled: Bool

        public init(tier: PositionTier, label: String, enabled: Bool) {
            self.tier = tier
            self.label = label
            self.enabled = enabled
        }
    }

    public let tiers: [Item]

    public init(enabledTiers: Set<PositionTier>) {
        // D4: 迭代 PositionTier.allCases（enum 源码顺序 = tier1..tier5），不迭代 enabledTiers。
        self.tiers = PositionTier.allCases.map { tier in
            Item(tier: tier, label: tier.rawValue, enabled: enabledTiers.contains(tier))
        }
    }
}
