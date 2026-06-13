import Testing
@testable import KlineTrainerContracts

@Suite("TrainingTopBarContent")
struct TrainingTopBarContentTests {

    @Test("总资金：¥ + 一空格 + 千分位 + 2 位小数（对齐 SettlementContent 口径）")
    func totalCapital_thousands() {
        let c = TrainingTopBarContent(totalCapital: 102_345.67, holdingCost: 0, returnRate: 0, positionTier: 0)
        #expect(c.totalCapital == "¥ 102,345.67")
    }

    @Test("持仓成本：空仓 0 → ¥ 0.00")
    func holdingCost_zero() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0, positionTier: 0)
        #expect(c.holdingCost == "¥ 0.00")
    }

    @Test("持仓成本：含小数千分位")
    func holdingCost_value() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 12_040.5, returnRate: 0, positionTier: 0)
        #expect(c.holdingCost == "¥ 12,040.50")
    }

    @Test("收益率：正 → +X.XX%")
    func returnRate_positive() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0.0234, positionTier: 0)
        #expect(c.returnRate == "+2.34%")
    }

    @Test("收益率：负 → -X.XX%")
    func returnRate_negative() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: -0.0832, positionTier: 0)
        #expect(c.returnRate == "-8.32%")
    }

    @Test("收益率：零 → +0.00%")
    func returnRate_zero() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0, positionTier: 0)
        #expect(c.returnRate == "+0.00%")
    }

    @Test("收益率：负零归一 → +0.00%（killer：-0.0 不得显 -0.00%）")
    func returnRate_negativeZero_normalized() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: -0.0, positionTier: 0)
        #expect(c.returnRate == "+0.00%")
    }

    @Test("Equatable：同输入同值")
    func equatable() {
        let a = TrainingTopBarContent(totalCapital: 100, holdingCost: 50, returnRate: 0.01, positionTier: 0)
        let b = TrainingTopBarContent(totalCapital: 100, holdingCost: 50, returnRate: 0.01, positionTier: 0)
        #expect(a == b)
    }
}

@Suite("TrainingTopBarContent 仓位 X/5")
struct TrainingTopBarPositionTierTests {
    @Test("空仓 → 仓位 0/5")
    func tierZero() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0, positionTier: 0)
        #expect(c.position == "仓位 0/5")
    }

    @Test("3/5 档")
    func tierThree() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0, positionTier: 3)
        #expect(c.position == "仓位 3/5")
    }

    @Test("满仓 → 仓位 5/5")
    func tierFive() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0, positionTier: 5)
        #expect(c.position == "仓位 5/5")
    }
}
