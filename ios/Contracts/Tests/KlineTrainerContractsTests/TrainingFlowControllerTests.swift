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

@Suite("ReviewFlow")
struct ReviewFlowTests {
    private let record = makeRecord(finalTick: 742, feeSnapshot: originalFees)
    private var flow: ReviewFlow { ReviewFlow(record: record) }

    @Test("属性：mode/feeSnapshot=原局/initialTick=finalTick/单点 range")
    func properties() {
        #expect(flow.mode == .review)
        #expect(flow.feeSnapshot == originalFees)
        #expect(flow.initialTick == 742)
        #expect(flow.allowedTickRange == 742...742)
    }

    @Test("能力：全 false（矩阵 Review 列）")
    func capabilities() {
        #expect(!flow.canBuySell())
        #expect(!flow.canAdvance())
        #expect(!flow.shouldSaveRecord())
        #expect(!flow.shouldAccumulateCapital())
        #expect(!flow.shouldShowSettlement())
        #expect(!flow.shouldGiveHapticFeedback())
    }

    @Test("验收：initialTick == record.finalTick，不是 maxTick（spec v1.1→v1.2 修正点）")
    func initialTickIsFinalTickNotMaxTick() {
        #expect(flow.initialTick == record.finalTick)
        #expect(flow.allowedTickRange.lowerBound == flow.allowedTickRange.upperBound)
        #expect(!flow.canAdvance())
    }
}

@Suite("ReplayFlow")
struct ReplayFlowTests {
    private let flow = ReplayFlow(feeSnapshotFromOriginal: originalFees, maxTick: 1000)

    @Test("属性：mode/feeSnapshot=原局/initialTick=0/0...maxTick")
    func properties() {
        #expect(flow.mode == .replay)
        #expect(flow.feeSnapshot == originalFees)
        #expect(flow.initialTick == 0)
        #expect(flow.allowedTickRange == 0...1000)
    }

    @Test("能力：T,T,F,F,T,T（矩阵 Replay 列）")
    func capabilities() {
        #expect(flow.canBuySell())
        #expect(flow.canAdvance())
        #expect(!flow.shouldSaveRecord())          // 不保存
        #expect(!flow.shouldAccumulateCapital())   // 不累加资金
        #expect(flow.shouldShowSettlement())       // 显示结算但不保存
        #expect(flow.shouldGiveHapticFeedback())
    }

    @Test("验收：从头开始(tick=0)、用原局 feeSnapshot、结束不保存（spec modules §E4 验收）")
    func acceptance() {
        #expect(flow.initialTick == 0)
        #expect(flow.feeSnapshot == originalFees)
        #expect(!flow.shouldSaveRecord())
    }
}

@Suite("Capability matrix（逐列 sweep，经协议存在类型）")
struct TrainingFlowMatrixTests {
    /// 顺序：canBuySell, canAdvance, shouldSaveRecord,
    ///       shouldAccumulateCapital, shouldShowSettlement, shouldGiveHapticFeedback
    private func column(_ f: TrainingFlowController) -> [Bool] {
        [f.canBuySell(), f.canAdvance(), f.shouldSaveRecord(),
         f.shouldAccumulateCapital(), f.shouldShowSettlement(), f.shouldGiveHapticFeedback()]
    }

    @Test("Normal 列 = 全 true")
    func normalColumn() {
        let f: TrainingFlowController = NormalFlow(fees: normalFees, maxTick: 1000)
        #expect(column(f) == [true, true, true, true, true, true])
    }

    @Test("Review 列 = 全 false")
    func reviewColumn() {
        let f: TrainingFlowController = ReviewFlow(record: makeRecord(finalTick: 742, feeSnapshot: originalFees))
        #expect(column(f) == [false, false, false, false, false, false])
    }

    @Test("Replay 列 = T,T,F,F,T,T")
    func replayColumn() {
        let f: TrainingFlowController = ReplayFlow(feeSnapshotFromOriginal: originalFees, maxTick: 1000)
        #expect(column(f) == [true, true, false, false, true, true])
    }

    @Test("三列两两可区分（无两列相同，防复制粘贴塌缩）")
    func columnsAreDistinct() {
        let normal = column(NormalFlow(fees: normalFees, maxTick: 10))
        let review = column(ReviewFlow(record: makeRecord(finalTick: 5, feeSnapshot: originalFees)))
        let replay = column(ReplayFlow(feeSnapshotFromOriginal: originalFees, maxTick: 10))
        #expect(normal != review)
        #expect(normal != replay)
        #expect(review != replay)
    }
}

@Suite("allowedTickRange 边界：maxTick==0 / finalTick==0 → 单点 0...0")
struct TrainingFlowBoundaryTests {
    @Test("NormalFlow maxTick==0（precondition 最小合法值）→ 0...0")
    func normalMinMaxTick() {
        #expect(NormalFlow(fees: normalFees, maxTick: 0).allowedTickRange == 0...0)
    }

    @Test("ReplayFlow maxTick==0 → 0...0")
    func replayMinMaxTick() {
        #expect(ReplayFlow(feeSnapshotFromOriginal: originalFees, maxTick: 0).allowedTickRange == 0...0)
    }

    @Test("ReviewFlow finalTick==0 → 单点 0...0")
    func reviewZeroFinalTick() {
        let flow = ReviewFlow(record: makeRecord(finalTick: 0, feeSnapshot: originalFees))
        #expect(flow.initialTick == 0)
        #expect(flow.allowedTickRange == 0...0)
    }
}
