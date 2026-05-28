// ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift
// Spec: kline_trainer_plan_v1.5.md §6.2.4 L946-952 + plan 2026-05-28-pr-u5-position-picker-view.md Task 1
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("PositionPickerContent host tests")
struct PositionPickerContentTests {

    // MARK: - D4 order: 5 元素严格 tier1→tier5 升序

    @Test("D4 全启用时 5 个 item 顺序 tier1→tier5")
    func allEnabledOrderIsTier1ToTier5() {
        let c = PositionPickerContent(enabledTiers: Set(PositionTier.allCases))
        #expect(c.tiers.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
    }

    @Test("D4 全 disabled 时（empty Set）顺序仍 tier1→tier5")
    func allDisabledStillOrdered() {
        let c = PositionPickerContent(enabledTiers: [])
        #expect(c.tiers.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
    }

    @Test("D4 部分启用（tier3+tier1）顺序仍 tier1→tier5（Set 迭代顺序不污染）")
    func partialEnabledRespectsTierOrder() {
        // 故意按反序 / 跳序构造 enabledTiers，强制证明 Content 顺序来自 PositionTier.allCases 非 Set 迭代
        let c = PositionPickerContent(enabledTiers: [.tier3, .tier1])
        #expect(c.tiers.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
    }

    @Test("tiers 数组恒 5 元素")
    func alwaysFiveItems() {
        #expect(PositionPickerContent(enabledTiers: []).tiers.count == 5)
        #expect(PositionPickerContent(enabledTiers: Set(PositionTier.allCases)).tiers.count == 5)
        #expect(PositionPickerContent(enabledTiers: [.tier1]).tiers.count == 5)
    }

    // MARK: - D5 enabled flag 映射

    @Test("D5 enabledTiers 空 → 5 个 item 全 disabled")
    func emptyEnabledTiersAllDisabled() {
        let c = PositionPickerContent(enabledTiers: [])
        #expect(c.tiers.map(\.enabled) == [false, false, false, false, false])
    }

    @Test("D5 enabledTiers 全 → 5 个 item 全 enabled")
    func fullEnabledTiersAllEnabled() {
        let c = PositionPickerContent(enabledTiers: Set(PositionTier.allCases))
        #expect(c.tiers.map(\.enabled) == [true, true, true, true, true])
    }

    @Test("D5 部分启用 [tier1, tier3] → enabled = [T,F,T,F,F]")
    func partialEnabledFlagsCorrect() {
        let c = PositionPickerContent(enabledTiers: [.tier1, .tier3])
        #expect(c.tiers.map(\.enabled) == [true, false, true, false, false])
    }

    // MARK: - D3 labels = rawValue

    @Test("D3 labels = '1/5'..'5/5' = PositionTier.rawValue（spec L949 字面）")
    func labelsMatchRawValues() {
        let c = PositionPickerContent(enabledTiers: Set(PositionTier.allCases))
        #expect(c.tiers.map(\.label) == ["1/5", "2/5", "3/5", "4/5", "5/5"])
    }

    // MARK: - Equatable + Sendable + determinism

    @Test("Content + Item 是 Equatable / Sendable（同输入恒等输出）")
    func equatableAndSendableAndDeterministic() {
        let c1 = PositionPickerContent(enabledTiers: [.tier1, .tier3])
        let c2 = PositionPickerContent(enabledTiers: [.tier3, .tier1]) // 故意反序构造
        #expect(c1 == c2)
        let _: any Sendable = c1
        let _: any Sendable = c1.tiers.first!
    }

    @Test("PositionTier.allCases 长度恒 5（D4 隐约束验证）")
    func positionTierAllCasesLengthIsFive() {
        #expect(PositionTier.allCases.count == 5)
    }
}
