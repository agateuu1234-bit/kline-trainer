// ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeActionBarContentTests.swift
// 平台无关纯值：host 可编译，不需 Catalyst。RFC-B T2 薄条内容 + Period.shortLabel。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TradeActionBarContent host tests")
struct TradeActionBarContentTests {

    @Test("price label 中性措辞（不写「日线下单价」等 per-period 字样）")
    func priceLabel_neutral_notPerPeriodWording() {
        let c = TradeActionBarContent(price: 1680)
        #expect(c.priceLabel == "下单价 ¥ 1,680.00")
    }

    @Test("period short label：m60 → 60分，daily → 日线")
    func periodShortLabels() {
        #expect(Period.m60.shortLabel == "60分")
        #expect(Period.daily.shortLabel == "日线")
    }

    @Test("period short label 覆盖全部 6 个周期")
    func periodShortLabelAllCases() {
        #expect(Period.m3.shortLabel == "3分")
        #expect(Period.m15.shortLabel == "15分")
        #expect(Period.m60.shortLabel == "60分")
        #expect(Period.daily.shortLabel == "日线")
        #expect(Period.weekly.shortLabel == "周线")
        #expect(Period.monthly.shortLabel == "月线")
    }

    @Test("price label 千分位格式化（整千）")
    func priceLabel_thousands() {
        let c = TradeActionBarContent(price: 12000)
        #expect(c.priceLabel == "下单价 ¥ 12,000.00")
    }

    @Test("price label 小数精度（两位）")
    func priceLabel_decimalPrecision() {
        let c = TradeActionBarContent(price: 3.5)
        #expect(c.priceLabel == "下单价 ¥ 3.50")
    }

    @Test("TradeActionBarContent 是 Equatable / Sendable（同输入恒等输出）")
    func equatableAndSendable() {
        #expect(TradeActionBarContent(price: 100) == TradeActionBarContent(price: 100))
        #expect(TradeActionBarContent(price: 100) != TradeActionBarContent(price: 200))
        let _: any Sendable = TradeActionBarContent(price: 100)
    }

    // codex R2-high 防过期下单守卫：买卖条捕获开条周期，执行前比对当前周期。
    @Test("tradeStripStillValid：同周期=有效；周期被切=失效（拒绝对新周期下单）")
    func tradeStripGuard_blocksOnPeriodChange() {
        // 周期未变 → 守卫放行（可下单）
        #expect(tradeStripStillValid(capturedPeriod: .m60, currentPeriod: .m60) == true)
        #expect(tradeStripStillValid(capturedPeriod: .daily, currentPeriod: .daily) == true)
        // 周期被切（分段钮 / 两指滑 switchPeriodCombo）→ 守卫拒绝，不对新周期下单
        #expect(tradeStripStillValid(capturedPeriod: .m60, currentPeriod: .daily) == false)
        #expect(tradeStripStillValid(capturedPeriod: .daily, currentPeriod: .m60) == false)
        #expect(tradeStripStillValid(capturedPeriod: .m15, currentPeriod: .weekly) == false)
    }
}
