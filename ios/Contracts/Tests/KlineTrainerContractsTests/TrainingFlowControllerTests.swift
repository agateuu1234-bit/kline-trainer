import Testing
@testable import KlineTrainerContracts

// MARK: - Fixtures

private let normalFees = FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true)
private let originalFees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false)

/// 构造一条原局 record（仅用于 ReviewFlow 测试）；非默认字段不参与 E4 逻辑。
private func makeRecord(finalTick: Int, feeSnapshot: FeeSnapshot) -> TrainingRecord {
    TrainingRecord(
        id: 1, trainingSetFilename: "x.sqlite", createdAt: 0,
        stockCode: "600519", stockName: "贵州茅台",
        startYear: 2021, startMonth: 8,
        totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
        buyCount: 0, sellCount: 0,
        feeSnapshot: feeSnapshot, finalTick: finalTick
    )
}

@Suite("NormalFlow")
struct NormalFlowTests {
    private let flow = NormalFlow(fees: normalFees, maxTick: 1000)

    @Test("属性：mode/feeSnapshot/initialTick/allowedTickRange")
    func properties() {
        #expect(flow.mode == .normal)
        #expect(flow.feeSnapshot == normalFees)
        #expect(flow.initialTick == 0)
        #expect(flow.allowedTickRange == 0...1000)
    }

    @Test("能力：全 true（矩阵 Normal 列）")
    func capabilities() {
        #expect(flow.canBuySell())
        #expect(flow.canAdvance())
        #expect(flow.shouldSaveRecord())
        #expect(flow.shouldAccumulateCapital())
        #expect(flow.shouldShowSettlement())
        #expect(flow.shouldGiveHapticFeedback())
    }

    @Test("验收：启动后 tick==0 且 canAdvance==true（spec modules §E4 验收）")
    func acceptance() {
        #expect(flow.initialTick == 0)
        #expect(flow.canAdvance())
    }
}
