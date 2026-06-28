import Testing
@testable import KlineTrainerContracts

@Suite("TrainingTopBarContent")
struct TrainingTopBarContentTests {

    @Test("总资金：¥ + 一空格 + 千分位 + 2 位小数（对齐 SettlementContent 口径）")
    func totalCapital_thousands() {
        let c = TrainingTopBarContent(totalCapital: 102_345.67, averageCost: 0, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.totalCapital == "¥ 102,345.67")
    }

    @Test("持仓成本：空仓 0 → ¥ 0.00")
    func holdingCost_zero() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.holdingCostPerShare == "¥ 0.00")
    }

    @Test("持仓成本：含小数千分位")
    func holdingCost_value() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 12_040.5, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.holdingCostPerShare == "¥ 12,040.50")
    }

    @Test("收益率：正 → +X.XX%")
    func returnRate_positive() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0, returnRate: 0.0234, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.returnRate == "+2.34%")
    }

    @Test("收益率：负 → -X.XX%")
    func returnRate_negative() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0, returnRate: -0.0832, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.returnRate == "-8.32%")
    }

    @Test("收益率：零 → +0.00%")
    func returnRate_zero() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.returnRate == "+0.00%")
    }

    @Test("收益率：负零归一 → +0.00%（killer：-0.0 不得显 -0.00%）")
    func returnRate_negativeZero_normalized() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0, returnRate: -0.0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.returnRate == "+0.00%")
    }

    @Test("Equatable：同输入同值")
    func equatable() {
        let a = TrainingTopBarContent(totalCapital: 100, averageCost: 50, shares: 0, returnRate: 0.01, positionTier: 0, stockName: nil, stockCode: nil)
        let b = TrainingTopBarContent(totalCapital: 100, averageCost: 50, shares: 0, returnRate: 0.01, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(a == b)
    }

    // MARK: - 5 new tests (RFC-B Task 2)

    @Test func perShareCost_usesAverageCost_notTotal() {
        let c = TrainingTopBarContent(totalCapital: 12_840_650, averageCost: 1_683.50,
                                      shares: 200, returnRate: 0.0234, positionTier: 2,
                                      stockName: nil, stockCode: nil)
        #expect(c.holdingCostPerShare == "¥ 1,683.50")   // 每股价位级，非总额
    }

    @Test func sharesText_grouped_with_unit() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 9_999_999,
                                      returnRate: 0, positionTier: 5, stockName: nil, stockCode: nil)
        #expect(c.sharesText == "9,999,999 股")           // 7 位千分位 + 单位
    }

    @Test func sharesZero_costZero() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0,
                                      returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.sharesText == "0 股")
        #expect(c.holdingCostPerShare == "¥ 0.00")
    }

    @Test func stockName_hiddenWhenNil_shownWhenPresent() {
        let blind = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0,
                                          returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(blind.stockNameDisplay == "训练标的 · 盲测")
        let named = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0,
                                          returnRate: 0, positionTier: 0, stockName: "贵州茅台", stockCode: "600519")
        #expect(named.stockNameDisplay == "贵州茅台（600519）")   // 全角括号
    }

    @Test func totalCapital_8digit_noTruncation() {
        let c = TrainingTopBarContent(totalCapital: 99_999_999, averageCost: 0, shares: 0,
                                      returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.totalCapital == "¥ 99,999,999.00")    // 8 位整数位完整千分位
    }
}

// MARK: - RFC-A A3: 持仓未实现盈亏（Task 6）

@Suite("TrainingTopBarContent holdingPnL")
struct TrainingTopBarContentHoldingPnLTests {

    @Test("持仓>0：浮动盈亏 = (现价-成本)*股数，元+%")
    func holdingPnLPositive() {
        let c = TrainingTopBarContent(totalCapital: 100_000, averageCost: 10, shares: 1000,
                                      returnRate: 0.05, positionTier: 1,
                                      stockName: nil, stockCode: nil, currentPrice: 12)
        // (12-10)*1000 = +2000；(12-10)/10 = +20.00%
        #expect(c.holdingPnL == "+¥ 2,000.00 (+20.00%)")
    }

    @Test("持仓=0：浮动盈亏 +¥ 0.00 (+0.00%)")
    func holdingPnLZero() {
        let c = TrainingTopBarContent(totalCapital: 100_000, averageCost: 0, shares: 0,
                                      returnRate: 0, positionTier: 0,
                                      stockName: nil, stockCode: nil, currentPrice: 12)
        #expect(c.holdingPnL == "+¥ 0.00 (+0.00%)")
    }

    @Test("亏损：负号 + 负%")
    func holdingPnLNegative() {
        let c = TrainingTopBarContent(totalCapital: 100_000, averageCost: 10, shares: 1000,
                                      returnRate: -0.1, positionTier: 1,
                                      stockName: nil, stockCode: nil, currentPrice: 9)
        #expect(c.holdingPnL == "-¥ 1,000.00 (-10.00%)")
    }
}

@Suite("TrainingTopBarContent 仓位 X/5")
struct TrainingTopBarPositionTierTests {
    @Test("空仓 → 仓位 0/5")
    func tierZero() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.position == "仓位 0/5")
    }

    @Test("3/5 档")
    func tierThree() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 3, stockName: nil, stockCode: nil)
        #expect(c.position == "仓位 3/5")
    }

    @Test("满仓 → 仓位 5/5")
    func tierFive() {
        let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 5, stockName: nil, stockCode: nil)
        #expect(c.position == "仓位 5/5")
    }
}
