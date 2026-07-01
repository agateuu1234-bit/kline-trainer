import Testing
@testable import KlineTrainerContracts

@Suite("TrainingTopBarContent")
struct TrainingTopBarContentTests {

    @Test("总资金：¥ + 千分位 + 无小数（无空格）")
    func totalCapital_thousands() {
        let c = TrainingTopBarContent(totalCapital: 102_345, initialCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.totalCapital == "¥102,345")
    }

    @Test("持仓成本：空仓 0 → 0.00（无 ¥）")
    func holdingCost_zero() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.holdingCostPerShare == "0.00")
    }

    @Test("持仓成本：含小数千分位（无 ¥）")
    func holdingCost_value() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 12_040.5, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.holdingCostPerShare == "12,040.50")
    }

    @Test("收益率：正 → +X.XX%")
    func returnRate_positive() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0, returnRate: 0.0234, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.returnRate == "+2.34%")
    }

    @Test("收益率：负 → -X.XX%")
    func returnRate_negative() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0, returnRate: -0.0832, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.returnRate == "-8.32%")
    }

    @Test("收益率：零 → +0.00%")
    func returnRate_zero() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.returnRate == "+0.00%")
    }

    @Test("收益率：负零归一 → +0.00%（killer：-0.0 不得显 -0.00%）")
    func returnRate_negativeZero_normalized() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0, returnRate: -0.0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.returnRate == "+0.00%")
    }

    @Test("Equatable：同输入同值")
    func equatable() {
        let a = TrainingTopBarContent(totalCapital: 100, initialCapital: 0, averageCost: 50, shares: 0, returnRate: 0.01, positionTier: 0, stockName: nil, stockCode: nil)
        let b = TrainingTopBarContent(totalCapital: 100, initialCapital: 0, averageCost: 50, shares: 0, returnRate: 0.01, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(a == b)
    }

    // MARK: - 5 new tests (RFC-B Task 2)

    @Test func perShareCost_usesAverageCost_notTotal() {
        let c = TrainingTopBarContent(totalCapital: 12_840_650, initialCapital: 0, averageCost: 1_683.50,
                                      shares: 200, returnRate: 0.0234, positionTier: 2,
                                      stockName: nil, stockCode: nil)
        #expect(c.holdingCostPerShare == "1,683.50")   // 每股价位级，无 ¥
    }

    @Test func sharesText_grouped_no_unit() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 9_999_999,
                                      returnRate: 0, positionTier: 5, stockName: nil, stockCode: nil)
        #expect(c.sharesText == "9,999,999")           // 7 位千分位，无「股」后缀
    }

    @Test func sharesZero_costZero() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0,
                                      returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.sharesText == "0")
        #expect(c.holdingCostPerShare == "0.00")
    }

    @Test func stockName_hiddenWhenNil_shownWhenPresent() {
        let blind = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0,
                                          returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(blind.stockNameDisplay == "训练标的 · 盲测")
        let named = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0,
                                          returnRate: 0, positionTier: 0, stockName: "贵州茅台", stockCode: "600519")
        #expect(named.stockNameDisplay == "贵州茅台（600519）")   // 全角括号
    }

    @Test func totalCapital_8digit_noTruncation() {
        let c = TrainingTopBarContent(totalCapital: 99_999_999, initialCapital: 0, averageCost: 0, shares: 0,
                                      returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.totalCapital == "¥99,999,999")    // 8 位整数位完整千分位，无小数无空格
    }

    // MARK: - Task 1：顶栏格式改造

    @Test("总资金/股数无小数；成本/股保留2位")
    func intFormats() {
        let c = TrainingTopBarContent(totalCapital: 10_000_000, initialCapital: 0, averageCost: 1_683.5, shares: 9_999_999,
                                      returnRate: 0, positionTier: 5, stockName: "x", stockCode: "1")
        #expect(c.totalCapital == "¥10,000,000")        // 无小数
        #expect(c.sharesText == "9,999,999")            // 无「股」后缀
        #expect(c.holdingCostPerShare == "1,683.50")    // 2 位、去 ¥（codex plan-R1 省宽）
        #expect(c.positionShort == "5/5")
    }

    @Test("总资金 currencyInt 对小数输入去小数（锁舍入行为）")
    func totalCapital_fractional_truncated() {
        let c = TrainingTopBarContent(totalCapital: 102_345.67, initialCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.totalCapital == "¥102,346")   // NumberFormatter maxFractionDigits=0 四舍五入：102345.67 → 102346
    }

    // MARK: - Task 5：「本局盈亏」整局级 PnL（sessionPnL*）

    @Test("本局盈亏：盈（cur>init）→ +¥ 金额 / +% / sign=1")
    func sessionPnL_profit() {
        let c = TrainingTopBarContent(totalCapital: 110_000, initialCapital: 100_000,
                                      averageCost: 0, shares: 0, returnRate: 0.1,
                                      positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.sessionPnLAmount == "+¥10,000")
        #expect(c.sessionPnLPercent == "+10.00%")
        #expect(c.sessionPnLSign == 1)
    }

    @Test("本局盈亏：亏（cur<init）→ -¥ 金额 / -% / sign=-1")
    func sessionPnL_loss() {
        let c = TrainingTopBarContent(totalCapital: 90_000, initialCapital: 100_000,
                                      averageCost: 0, shares: 0, returnRate: -0.1,
                                      positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.sessionPnLAmount == "-¥10,000")
        #expect(c.sessionPnLPercent == "-10.00%")
        #expect(c.sessionPnLSign == -1)
    }

    @Test("本局盈亏：持平（cur==init）→ +¥0 / +0.00% / sign=0")
    func sessionPnL_flat() {
        let c = TrainingTopBarContent(totalCapital: 100_000, initialCapital: 100_000,
                                      averageCost: 0, shares: 0, returnRate: 0,
                                      positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.sessionPnLAmount == "+¥0")
        #expect(c.sessionPnLPercent == "+0.00%")
        #expect(c.sessionPnLSign == 0)
    }

    @Test("本局盈亏：sub-yuan（profit=-0.1，舍入→0）→ +¥0 / +0.00% / sign=0")
    func sessionPnL_subYuan() {
        let c = TrainingTopBarContent(totalCapital: 99_999.9, initialCapital: 100_000,
                                      averageCost: 0, shares: 0, returnRate: -0.000001,
                                      positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.sessionPnLAmount == "+¥0")
        #expect(c.sessionPnLPercent == "+0.00%")
        #expect(c.sessionPnLSign == 0)
    }

    @Test("本局盈亏：非有限（totalCapital=inf）→ — / — / sign=0")
    func sessionPnL_nonFinite() {
        let c = TrainingTopBarContent(totalCapital: .infinity, initialCapital: 100_000,
                                      averageCost: 0, shares: 0, returnRate: 0,
                                      positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.sessionPnLAmount == "—")
        #expect(c.sessionPnLPercent == "—")
        #expect(c.sessionPnLSign == 0)
    }

    // MARK: - task-review M1/M2 边界补测

    @Test("本局盈亏：returnRate 独立 NaN（profit 有限）→ — / — / sign=0")
    func sessionPnL_returnRateNaN_independentPath() {
        // profit=10_000 有限，但 returnRate=.nan 非有限 → `|| !returnRate.isFinite` 分支触发
        let c = TrainingTopBarContent(totalCapital: 110_000, initialCapital: 100_000,
                                      averageCost: 0, shares: 0, returnRate: .nan,
                                      positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.sessionPnLAmount == "—")
        #expect(c.sessionPnLPercent == "—")
        #expect(c.sessionPnLSign == 0)
    }

    @Test("本局盈亏：超大额 profit（> Int64.max 附近）不崩 + 正号前缀")
    func sessionPnL_hugeProfitNoIntTrap() {
        // profit = 9.0e18（有限，Double 可表达，> Int64.max≈9.22e18 量级附近）
        // signedCurrencyInt 用 Double.rounded() 非 Int() 转换，验证不 trap + 正常格式化路径
        let c = TrainingTopBarContent(totalCapital: 9.0e18, initialCapital: 0,
                                      averageCost: 0, shares: 0, returnRate: 1.0e14,
                                      positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.sessionPnLAmount.hasPrefix("+¥"))
        #expect(c.sessionPnLSign == 1)
    }
}

// MARK: - codex whole-branch R4-F1：reviewAware helpers

@Suite("TrainingTopBarContent reviewAware helpers")
struct TrainingTopBarReviewAwareTests {

    // MARK: reviewAwareCapital

    @Test("reviewAwareCapital：review + !isAtEnd → initialCapital（隐藏最终成绩）")
    func reviewAwareCapital_reviewNotAtEnd() {
        let result = TrainingTopBarContent.reviewAwareCapital(
            mode: .review, isAtEnd: false, initialCapital: 100_000, currentTotalCapital: 150_000)
        #expect(result == 100_000)
    }

    @Test("reviewAwareCapital：review + isAtEnd → currentTotalCapital（揭示真实）")
    func reviewAwareCapital_reviewAtEnd() {
        let result = TrainingTopBarContent.reviewAwareCapital(
            mode: .review, isAtEnd: true, initialCapital: 100_000, currentTotalCapital: 150_000)
        #expect(result == 150_000)
    }

    @Test("reviewAwareCapital：normal + !isAtEnd → currentTotalCapital（恒真实）")
    func reviewAwareCapital_normalNotAtEnd() {
        let result = TrainingTopBarContent.reviewAwareCapital(
            mode: .normal, isAtEnd: false, initialCapital: 100_000, currentTotalCapital: 150_000)
        #expect(result == 150_000)
    }

    @Test("reviewAwareCapital：replay + !isAtEnd → currentTotalCapital（恒真实）")
    func reviewAwareCapital_replayNotAtEnd() {
        let result = TrainingTopBarContent.reviewAwareCapital(
            mode: .replay, isAtEnd: false, initialCapital: 100_000, currentTotalCapital: 150_000)
        #expect(result == 150_000)
    }

    // MARK: reviewAwareReturnRate

    @Test("reviewAwareReturnRate：review + !isAtEnd → 0（隐藏收益率）")
    func reviewAwareReturnRate_reviewNotAtEnd() {
        let result = TrainingTopBarContent.reviewAwareReturnRate(
            mode: .review, isAtEnd: false, actualReturnRate: 0.5)
        #expect(result == 0)
    }

    @Test("reviewAwareReturnRate：review + isAtEnd → actualReturnRate（揭示真实）")
    func reviewAwareReturnRate_reviewAtEnd() {
        let result = TrainingTopBarContent.reviewAwareReturnRate(
            mode: .review, isAtEnd: true, actualReturnRate: 0.5)
        #expect(result == 0.5)
    }

    @Test("reviewAwareReturnRate：normal + !isAtEnd → actualReturnRate（恒真实）")
    func reviewAwareReturnRate_normalNotAtEnd() {
        let result = TrainingTopBarContent.reviewAwareReturnRate(
            mode: .normal, isAtEnd: false, actualReturnRate: -0.2)
        #expect(result == -0.2)
    }

    @Test("reviewAwareReturnRate：replay + !isAtEnd → actualReturnRate（恒真实）")
    func reviewAwareReturnRate_replayNotAtEnd() {
        let result = TrainingTopBarContent.reviewAwareReturnRate(
            mode: .replay, isAtEnd: false, actualReturnRate: 0.1)
        #expect(result == 0.1)
    }
}

@Suite("TrainingTopBarContent 仓位 X/5")
struct TrainingTopBarPositionTierTests {
    @Test("空仓 → 仓位 0/5")
    func tierZero() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
        #expect(c.position == "仓位 0/5")
    }

    @Test("3/5 档")
    func tierThree() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 3, stockName: nil, stockCode: nil)
        #expect(c.position == "仓位 3/5")
    }

    @Test("满仓 → 仓位 5/5")
    func tierFive() {
        let c = TrainingTopBarContent(totalCapital: 0, initialCapital: 0, averageCost: 0, shares: 0, returnRate: 0, positionTier: 5, stockName: nil, stockCode: nil)
        #expect(c.position == "仓位 5/5")
    }
}
