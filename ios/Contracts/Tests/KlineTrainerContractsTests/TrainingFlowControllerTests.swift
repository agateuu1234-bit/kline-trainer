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
    private var flow: ReviewFlow { ReviewFlow(record: record, startTick: record.finalTick) }

    @Test("属性：mode/feeSnapshot=原局/initialTick=finalTick/单点 range")
    func properties() {
        #expect(flow.mode == .review)
        #expect(flow.feeSnapshot == originalFees)
        #expect(flow.initialTick == 742)
        #expect(flow.allowedTickRange == 742...742)
    }

    @Test("能力：canAdvance=true，其余 false（矩阵 Review 列，B1 起 canAdvance 改 true）")
    func capabilities() {
        #expect(!flow.canBuySell())
        #expect(flow.canAdvance())       // B1：复盘可步进重演
        #expect(!flow.shouldSaveRecord())
        #expect(!flow.shouldAccumulateCapital())
        #expect(!flow.shouldShowSettlement())
        #expect(!flow.shouldGiveHapticFeedback())
    }

    @Test("验收：startTick==finalTick 时 initialTick==finalTick，range 单点，canAdvance=true（B1 后）")
    func initialTickIsFinalTickNotMaxTick() {
        #expect(flow.initialTick == record.finalTick)
        #expect(flow.allowedTickRange.lowerBound == flow.allowedTickRange.upperBound)
        #expect(flow.canAdvance())      // B1：复盘可步进重演
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

    @Test("Review 列 = canAdvance true，其余 false（B1 起）")
    func reviewColumn() {
        let f: TrainingFlowController = ReviewFlow(record: makeRecord(finalTick: 742, feeSnapshot: originalFees), startTick: 742)
        #expect(column(f) == [false, true, false, false, false, false])
    }

    @Test("Replay 列 = T,T,F,F,T,T")
    func replayColumn() {
        let f: TrainingFlowController = ReplayFlow(feeSnapshotFromOriginal: originalFees, maxTick: 1000)
        #expect(column(f) == [true, true, false, false, true, true])
    }

    @Test("三列两两可区分（无两列相同，防复制粘贴塌缩）")
    func columnsAreDistinct() {
        let normal = column(NormalFlow(fees: normalFees, maxTick: 10))
        let review = column(ReviewFlow(record: makeRecord(finalTick: 5, feeSnapshot: originalFees), startTick: 5))
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
        let flow = ReviewFlow(record: makeRecord(finalTick: 0, feeSnapshot: originalFees), startTick: 0)
        #expect(flow.initialTick == 0)
        #expect(flow.allowedTickRange == 0...0)
    }
}

@Test func shouldPersistProgress_matrix() {
    let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    #expect(NormalFlow(fees: fees, maxTick: 100).shouldPersistProgress() == true)
    #expect(ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: 100).shouldPersistProgress() == true)
    // Review 用最小 record 构造（finalTick 任意；B1 之后 init 增 startTick——见 Task B1，届时本行同步改）
    let rec = TrainingRecord(id: 1, trainingSetFilename: "x.sqlite", createdAt: 0, stockCode: "1", stockName: "n",
                             startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
                             maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 100)
    #expect(ReviewFlow(record: rec, startTick: rec.finalTick).shouldPersistProgress() == false)
}

// MARK: - Task B1: ReviewFlow 可步进重演 + canJumpToEnd + FlowInput/make 守卫

@Test func reviewFlow_playable_matrix() {
    let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    let rec = TrainingRecord(id: 1, trainingSetFilename: "x.sqlite", createdAt: 0, stockCode: "1", stockName: "n",
        startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
        maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 1000)
    let rf = ReviewFlow(record: rec, startTick: 200)
    #expect(rf.initialTick == 200)
    #expect(rf.allowedTickRange == 200...1000)
    #expect(rf.canAdvance() == true)
    #expect(rf.canBuySell() == false)
    #expect(rf.canJumpToEnd() == true)
    #expect(rf.shouldShowSettlement() == false)
    #expect(NormalFlow(fees: fees, maxTick: 100).canJumpToEnd() == false)
    #expect(ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: 100).canJumpToEnd() == false)
}

@MainActor
@Test func make_review_startTickAfterFinalTick_throwsNotTrap() throws {
    let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    let rec = TrainingRecord(id: 1, trainingSetFilename: "x.sqlite", createdAt: 0, stockCode: "1", stockName: "n",
        startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
        maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 5)
    // startTick(10) > finalTick(5)：guard 在候选校验/flow 构造前抛 → 不触 ClosedRange trap
    #expect(throws: AppError.self) {
        _ = try TrainingEngine.make(.review(record: rec, startTick: 10),
                                    allCandles: [:],
                                    initialCapital: 100_000, initialCashBalance: 100_000)
    }
}

@Test func reviewFlow_directBadStartTick_noTrap_degenerateRange() {
    let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    let rec = TrainingRecord(id: 1, trainingSetFilename: "x.sqlite", createdAt: 0, stockCode: "1", stockName: "n",
        startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
        maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 5)
    let rf = ReviewFlow(record: rec, startTick: 10)   // startTick>finalTick：钳位为退化 5...5，不 trap
    #expect(rf.allowedTickRange == 5...5)
    #expect(rf.initialTick == 5)
}
