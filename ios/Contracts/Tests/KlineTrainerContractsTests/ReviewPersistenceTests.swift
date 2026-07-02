import Testing
import Foundation
@testable import KlineTrainerContracts

// MARK: - Harness

/// ReviewTestHarness: in-memory 装配的 coordinator，seed 一条 record + fixture 训练组，
/// 使 review(recordId:) 可以成功返回引擎，并保留 `reviewRepo` 引用供测试直接种子/断言存档态。
/// 复用 CoordinatorTestHarness 的 candle fixture + CapitalDAO（见 CoordinatorReplayPersistenceTests.swift）。
@MainActor
private struct ReviewTestHarness {
    let coordinator: TrainingSessionCoordinator
    let reviewRepo: InMemoryReviewArchiveRepository
    let recordRepo: InMemoryRecordRepository
    let seededRecordId: Int64

    static func make() throws -> ReviewTestHarness {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let pendingReplay = InMemoryPendingReplayRepository()
        let reviewRepo = InMemoryReviewArchiveRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let cache = InMemoryCacheManager()
        let file = TrainingSetFile(id: 1, filename: "set.sqlite",
                                   localURL: URL(fileURLWithPath: "/tmp/set.sqlite"),
                                   schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
        cache._seedForTesting([file])

        let candles = CoordinatorTestHarness.makeCandles()
        let factory = PreviewTrainingSetDBFactory(candles: candles)
        let settingsDAO = CoordinatorTestHarness.CapitalDAO(capital: 100_000)
        let coord = TrainingSessionCoordinator(
            dbFactory: factory,
            recordRepo: records,
            pendingRepo: pending,
            pendingReplayRepo: pendingReplay,
            reviewArchiveRepo: reviewRepo,
            finalization: port,
            settingsDAO: settingsDAO,
            cache: cache,
            settings: SettingsStore(settingsDAO: settingsDAO))

        let seededFinalTick = 7
        // profit/returnRate=0（非旧 5_000/0.05）：ops=[] 无交易 → Task 6 entry-validation 折叠终局 == 起始，
        // 须与 record 声明一致（否则 review() 新增的入口终局等式校验会拒绝这条 fixture record）。
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                           totalCapital: 100_000, profit: 0,
                           returnRate: 0, maxDrawdown: -0.03,
                           buyCount: 1, sellCount: 1,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                           finalTick: seededFinalTick),
            ops: [], drawings: [])

        return ReviewTestHarness(coordinator: coord, reviewRepo: reviewRepo, recordRepo: records, seededRecordId: id)
    }
}

/// 简易水平线 fixture（唯一变量=价格，用以区分不同画线）。
@MainActor
private func line(_ price: Double) -> DrawingObject {
    DrawingObject(toolType: .horizontal,
                  anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: price)],
                  isExtended: false, panelPosition: 0)
}

/// Task 6 入口终局校验测试用的 TradeOperation fixture（mirror ReviewLedgerTests.op）。
private func op(_ tick: Int, _ dir: TradeDirection, price: Double, shares: Int,
                commission: Double, stampDuty: Double, totalCost: Double) -> TradeOperation {
    TradeOperation(globalTick: tick, period: .m3, direction: dir, price: price, shares: shares,
                   positionTier: .tier5, commission: commission, stampDuty: stampDuty,
                   totalCost: totalCost, createdAt: Int64(tick))
}

// MARK: - ReviewNetChange (pure function)

@Suite("ReviewNetChange")
struct ReviewNetChangeTests {
    @Test @MainActor func emptyVsEmpty_noChange() {
        #expect(ReviewNetChange.changed(working: [], committed: []) == false)
    }

    @Test @MainActor func nonEmptyVsEmpty_changed() {
        #expect(ReviewNetChange.changed(working: [line(5)], committed: []) == true)
    }

    @Test @MainActor func sameSingleDrawing_noChange() {
        #expect(ReviewNetChange.changed(working: [line(5)], committed: [line(5)]) == false)
    }

    @Test @MainActor func sameSetDifferentOrder_noChange() {
        // 顺序无关：working=[5,7] vs committed=[7,5] → 无改动
        #expect(ReviewNetChange.changed(working: [line(5), line(7)], committed: [line(7), line(5)]) == false)
    }

    @Test @MainActor func differentPrice_changed() {
        #expect(ReviewNetChange.changed(working: [line(5)], committed: [line(7)]) == true)
    }
}

// MARK: - Coordinator review-persistence

@MainActor
@Suite("ReviewPersistence")
struct ReviewPersistenceTests {

    // 1) 进入 none 记录 → 画一条 → persistReviewWorkingIfChanged → reviewMarker==.inProgress
    @Test func enterFreshRecord_drawOne_persist_marksInProgress() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        h.coordinator.setReviewSessionForTesting(recordId: h.seededRecordId, committedBaseline: [])
        e.setReviewDrawingsForTesting([line(10)])

        try h.coordinator.persistReviewWorkingIfChanged(engine: e)

        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId)?.drawings == [line(10)])
    }

    // 2) 进入 saved 记录（committed=saved）→ 不动 → persist → clearWorking → reviewMarker==.saved
    @Test func enterSavedRecord_noChange_persist_revertsToSaved() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])   // 既有 saved 基线
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        h.coordinator.setReviewSessionForTesting(recordId: h.seededRecordId, committedBaseline: [line(10)])
        e.setReviewDrawingsForTesting([line(10)])   // 未动，working == committed

        try h.coordinator.persistReviewWorkingIfChanged(engine: e)

        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)   // 已回退，working 未写
    }

    // 3) 进入 saved → 画一条(≠saved) → persist → .inProgress；再删回=saved → persist → .saved（committed 基线回退）
    @Test func drawThenRevertToSavedBaseline_marksSaved_notStuckInProgress() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        h.coordinator.setReviewSessionForTesting(recordId: h.seededRecordId, committedBaseline: [line(10)])

        e.setReviewDrawingsForTesting([line(10), line(20)])   // 画一条，偏离 committed
        try h.coordinator.persistReviewWorkingIfChanged(engine: e)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)

        e.setReviewDrawingsForTesting([line(10)])   // 删回 == committed 基线
        try h.coordinator.persistReviewWorkingIfChanged(engine: e)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)   // 回退，非卡在 .inProgress
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
    }

    // 4) commitReview → .saved 且 saved==working；discardReviewWorking(有 saved) → 仍 .saved
    @Test func commitReview_thenDiscardWorking_staysSaved() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        h.coordinator.setReviewSessionForTesting(recordId: h.seededRecordId, committedBaseline: [])
        e.setReviewDrawingsForTesting([line(10)])

        try h.coordinator.commitReview(engine: e)

        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)
        #expect(try h.reviewRepo.loadSaved(recordId: h.seededRecordId) == [line(10)])
        #expect(h.coordinator.reviewNetChanged() == false)   // committed 基线已前移到 [line(10)]

        // 再画一条 → persist → .inProgress；discard working → 回退 .saved（saved 未被改动）
        e.setReviewDrawingsForTesting([line(10), line(20)])
        try h.coordinator.persistReviewWorkingIfChanged(engine: e)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)

        try h.coordinator.discardReviewWorking(engine: e)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)
        #expect(try h.reviewRepo.loadSaved(recordId: h.seededRecordId) == [line(10)])   // saved 不受影响
    }

    // MARK: - hasReviewInProgress / loadReviewMarkers

    @Test func hasReviewInProgress_and_loadReviewMarkers_reflectRepoState() async throws {
        let h = try ReviewTestHarness.make()
        #expect(h.coordinator.hasReviewInProgress(recordId: h.seededRecordId) == false)
        #expect(h.coordinator.loadReviewMarkers().isEmpty)

        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        h.coordinator.setReviewSessionForTesting(recordId: h.seededRecordId, committedBaseline: [])
        e.setReviewDrawingsForTesting([line(10)])
        try h.coordinator.persistReviewWorkingIfChanged(engine: e)

        #expect(h.coordinator.hasReviewInProgress(recordId: h.seededRecordId) == true)
        #expect(h.coordinator.loadReviewMarkers()[h.seededRecordId] == .inProgress)
    }

    // MARK: - No review session → guarded no-op, never throws
    // （Task 6 后 review()/resumePendingReview() 自动设置 reviewRecordId；本测试改用「从未进过复盘 session」
    // 的 normal session engine 验证 3 个方法仍 guard 早返、不碰 repo——覆盖同一条 coordinator 内 guard 逻辑。）

    @Test func noReviewSession_persistCommitDiscard_areNoOps() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.startNewNormalSession()   // 非 review session：reviewRecordId 仍 nil

        try h.coordinator.persistReviewWorkingIfChanged(engine: e)
        try h.coordinator.commitReview(engine: e)
        try h.coordinator.discardReviewWorking(engine: e)

        #expect(h.coordinator.loadReviewMarkers().isEmpty)   // 全部 guard 早返，未触碰 repo
    }

    // MARK: - Task 6: review() 基线（committed = saved，非手动注入）

    @Test func review_onSavedRecord_seedsDrawingsAndCommittedBaselineFromSaved() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])

        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        #expect(e.reviewDrawings == [line(10)])

        // 未手动注入 reviewCommittedBaseline：不动画线 → persist → 应回退 .saved（证明 baseline==saved，
        // 非手动 setReviewSessionForTesting；若 baseline 误为 [] 则此处会误判"改动"→.inProgress）。
        try h.coordinator.persistReviewWorkingIfChanged(engine: e)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
    }

    @Test func review_freshRecord_noSaved_seedsEmptyBaseline() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        #expect(e.reviewDrawings == [])
        #expect(h.coordinator.reviewNetChanged() == false)   // committed 基线 == [] == engine.reviewDrawings
    }

    // MARK: - Task 6: saved 损坏恢复

    @Test func review_savedCorrupt_recoversToEmptyBaseline_marksNone() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])
        h.reviewRepo.failNextLoadSaved = .persistence(.dbCorrupted)

        let e = try await h.coordinator.review(recordId: h.seededRecordId)

        #expect(e.reviewDrawings == [])
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .none)   // clearSaved 已生效
    }

    @Test func review_savedCorruptAndClearSavedFails_throwsRetryable_keepsSavedRow() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])
        h.reviewRepo.failNextLoadSaved = .persistence(.dbCorrupted)
        h.reviewRepo.failNextClearSaved = .internalError(module: "test", detail: "transient clear")

        await #expect(throws: (any Error).self) {
            _ = try await h.coordinator.review(recordId: h.seededRecordId)
        }
        // 坏 saved 行仍在（clearSaved 失败未清）——不以空基线开界面。
        #expect(try h.reviewRepo.loadArchive(recordId: h.seededRecordId)?.savedDrawings == [line(10)])
        #expect(h.coordinator.activeEngine == nil)   // 入口失败前未写活跃状态
    }

    // MARK: - Task 6: resumePendingReview

    @Test func resumePendingReview_hitInProgress_restoresStepTickAndDrawings() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.saveWorking(recordId: h.seededRecordId, stepTick: 4, drawings: [line(20)])

        let e = try await h.coordinator.resumePendingReview(recordId: h.seededRecordId)
        #expect(e != nil)
        #expect(e?.tick.globalTickIndex == 4)
        #expect(e?.reviewDrawings == [line(20)])
        #expect(e?.flow.mode == .review)
    }

    @Test func resumePendingReview_notInProgress_returnsNil() async throws {
        let h = try ReviewTestHarness.make()
        // 无任何存档（marker == .none）
        let e1 = try await h.coordinator.resumePendingReview(recordId: h.seededRecordId)
        #expect(e1 == nil)

        // 仅 saved（marker == .saved，非 .inProgress）
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])
        let e2 = try await h.coordinator.resumePendingReview(recordId: h.seededRecordId)
        #expect(e2 == nil)
    }

    // MARK: - Task 6: 入口 ops 校验 + 终局等式强制

    @Test func review_oversellRecord_throwsDBCorrupted() async throws {
        let h = try ReviewTestHarness.make()
        let badOps = [op(1, .sell, price: 10, shares: 100, commission: 0, stampDuty: 0, totalCost: 1000)]
        let rec = TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                                 stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                                 totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                                 buyCount: 0, sellCount: 1,
                                 feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                                 finalTick: 5)
        let id = try h.recordRepo.insertRecord(rec, ops: badOps, drawings: [])

        await #expect(throws: (any Error).self) {
            _ = try await h.coordinator.review(recordId: id)
        }
    }

    @Test func review_finalTotalsInconsistentWithRecord_throwsDBCorrupted() async throws {
        let h = try ReviewTestHarness.make()
        // 实际折叠：100_000 -1000(buy) +1000(sell,notional-0-0) = 100_000（flat，profit 实际=0）
        let roundTripOps = [
            op(1, .buy, price: 10, shares: 100, commission: 0, stampDuty: 0, totalCost: 1000),
            op(2, .sell, price: 10, shares: 100, commission: 0, stampDuty: 0, totalCost: 1000),
        ]
        let rec = TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                                 stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                                 totalCapital: 100_000, profit: 999, returnRate: 0.00999, maxDrawdown: 0,
                                 buyCount: 1, sellCount: 1,
                                 feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                                 finalTick: 5)
        let id = try h.recordRepo.insertRecord(rec, ops: roundTripOps, drawings: [])

        await #expect(throws: (any Error).self) {
            _ = try await h.coordinator.review(recordId: id)
        }
    }

    @Test func review_consistentRecord_succeeds() async throws {
        let h = try ReviewTestHarness.make()
        // 折叠：100_000 -50_000(buy 500@100) +68_000(sell 500@136, 0 佣金印花) = 118_000 → profit 18_000
        let consistentOps = [
            op(1, .buy, price: 100, shares: 500, commission: 0, stampDuty: 0, totalCost: 50_000),
            op(2, .sell, price: 136, shares: 500, commission: 0, stampDuty: 0, totalCost: 68_000),
        ]
        let rec = TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                                 stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                                 totalCapital: 100_000, profit: 18_000, returnRate: 0.18, maxDrawdown: 0,
                                 buyCount: 1, sellCount: 1,
                                 feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                                 finalTick: 5)
        let id = try h.recordRepo.insertRecord(rec, ops: consistentOps, drawings: [])

        let engine = try await h.coordinator.review(recordId: id)
        #expect(engine.flow.mode == .review)
    }
}
