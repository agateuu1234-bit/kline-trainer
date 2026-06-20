// ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeBarContentTests.swift
// Spec: docs/superpowers/specs/2026-06-20-trade-bar-inline-design.md §6.1
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TradeBarContent host tests")
struct TradeBarContentTests {

    @Test("buy 态 5 chip label = 1/5..4/5 + 全仓")
    func buyLabels() {
        let c = TradeBarContent(action: .buy)
        #expect(c.chips.map(\.label) == ["1/5", "2/5", "3/5", "4/5", "全仓"])
    }

    @Test("sell 态 5 chip label = 1/5..4/5 + 清仓")
    func sellLabels() {
        let c = TradeBarContent(action: .sell)
        #expect(c.chips.map(\.label) == ["1/5", "2/5", "3/5", "4/5", "清仓"])
    }

    @Test("chip tier 顺序恒 tier1→tier5（迭代 allCases，不受 action 影响）")
    func tierOrder() {
        #expect(TradeBarContent(action: .buy).chips.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
        #expect(TradeBarContent(action: .sell).chips.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
    }

    @Test("买卖仅末档 label 不同、前 4 档相同（真双判别锚）")
    func buySellDifferOnlyAtLastChip() {
        let buy = TradeBarContent(action: .buy).chips
        let sell = TradeBarContent(action: .sell).chips
        #expect(Array(buy[0..<4]).map(\.label) == Array(sell[0..<4]).map(\.label))
        #expect(buy[4].label == "全仓")
        #expect(sell[4].label == "清仓")
        #expect(buy[4].label != sell[4].label)
    }

    @Test("label↔tier↔shortcut 联合锁定（末档 tier5 + isShortcut + 上下文 label）")
    func lastChipConjoint() {
        let buy = TradeBarContent(action: .buy).chips[4]
        #expect(buy.tier == .tier5 && buy.isShortcut && buy.label == "全仓")
        let sell = TradeBarContent(action: .sell).chips[4]
        #expect(sell.tier == .tier5 && sell.isShortcut && sell.label == "清仓")
    }

    @Test("前 4 档 isShortcut == false，仅末档强调")
    func onlyLastChipIsShortcut() {
        #expect(TradeBarContent(action: .buy).chips.map(\.isShortcut) == [false, false, false, false, true])
        #expect(TradeBarContent(action: .sell).chips.map(\.isShortcut) == [false, false, false, false, true])
    }

    @Test("chips 恒 5 元素")
    func alwaysFiveChips() {
        #expect(TradeBarContent(action: .buy).chips.count == 5)
        #expect(TradeBarContent(action: .sell).chips.count == 5)
    }

    @Test("tier5.rawValue 仍为 5/5（UI 重标不改持久化契约）")
    func tier5RawValueUnchanged() {
        #expect(PositionTier.tier5.rawValue == "5/5")
    }

    @Test("Content + Chip 是 Equatable / Sendable（同输入恒等输出）")
    func equatableAndSendable() {
        #expect(TradeBarContent(action: .buy) == TradeBarContent(action: .buy))
        #expect(TradeBarContent(action: .buy) != TradeBarContent(action: .sell))
        let _: any Sendable = TradeBarContent(action: .buy)
        let _: any Sendable = TradeBarContent(action: .buy).chips.first!
    }
}
