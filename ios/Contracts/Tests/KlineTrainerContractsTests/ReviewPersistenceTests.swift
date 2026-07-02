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
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                           totalCapital: 100_000, profit: 5_000,
                           returnRate: 0.05, maxDrawdown: -0.03,
                           buyCount: 1, sellCount: 1,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                           finalTick: seededFinalTick),
            ops: [], drawings: [])

        return ReviewTestHarness(coordinator: coord, reviewRepo: reviewRepo, seededRecordId: id)
    }
}

/// 简易水平线 fixture（唯一变量=价格，用以区分不同画线）。
@MainActor
private func line(_ price: Double) -> DrawingObject {
    DrawingObject(toolType: .horizontal,
                  anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: price)],
                  isExtended: false, panelPosition: 0)
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

    // MARK: - No review session (Task 6 not landed yet) → guarded no-op, never throws

    @Test func noReviewSession_persistCommitDiscard_areNoOps() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        e.setReviewDrawingsForTesting([line(10)])   // reviewRecordId 从未设置（Task 6 未落）

        try h.coordinator.persistReviewWorkingIfChanged(engine: e)
        try h.coordinator.commitReview(engine: e)
        try h.coordinator.discardReviewWorking(engine: e)

        #expect(h.coordinator.loadReviewMarkers().isEmpty)   // 全部 guard 早返，未触碰 repo
    }
}
