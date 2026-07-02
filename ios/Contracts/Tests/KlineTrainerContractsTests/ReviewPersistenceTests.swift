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

    /// `wrapRepoForTesting`：Task 7 延迟替身注入点（如 `SlowReviewArchiveRepo`）——包一层再传给
    /// coordinator，`reviewRepo` 字段仍指向底层 in-memory repo，供测试直接断言落盘态。
    static func make(wrapRepoForTesting wrap: ((InMemoryReviewArchiveRepository) -> ReviewArchiveRepository)? = nil)
        throws -> ReviewTestHarness {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let pendingReplay = InMemoryPendingReplayRepository()
        let reviewRepo = InMemoryReviewArchiveRepository()
        let injectedReviewRepo: ReviewArchiveRepository = wrap?(reviewRepo) ?? reviewRepo
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
            reviewArchiveRepo: injectedReviewRepo,
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

/// Task 7：包一层真 repo，写方法前人为延迟（模拟慢速磁盘 I/O），放大『陈旧排队写 vs 终态权威写』的
/// 时间窗口——用以验证即便底层写变慢，token/revision fence 仍保证终态 last-wins（而非仅因写得快、
/// 凑巧没撞上竞态窗口才侥幸通过）。所有方法均转发到 `inner`（同底层状态，供测试直接断言）。
private final class SlowReviewArchiveRepo: ReviewArchiveRepository, @unchecked Sendable {
    private let inner: ReviewArchiveRepository
    private let delay: TimeInterval

    init(wrapping inner: ReviewArchiveRepository, delay: TimeInterval = 0.02) {
        self.inner = inner
        self.delay = delay
    }

    func loadWorking(recordId: Int64) throws -> ReviewWorking? { try inner.loadWorking(recordId: recordId) }
    func loadSaved(recordId: Int64) throws -> [DrawingObject]? { try inner.loadSaved(recordId: recordId) }
    func loadArchive(recordId: Int64) throws -> ReviewArchive? { try inner.loadArchive(recordId: recordId) }

    func saveWorking(recordId: Int64, stepTick: Int, drawings: [DrawingObject]) throws {
        Thread.sleep(forTimeInterval: delay)     // 模拟慢写：即便变慢，fence 仍须保证 last-wins
        try inner.saveWorking(recordId: recordId, stepTick: stepTick, drawings: drawings)
    }
    func commitSaved(recordId: Int64, drawings: [DrawingObject]) throws {
        try inner.commitSaved(recordId: recordId, drawings: drawings)
    }
    func clearWorking(recordId: Int64) throws { try inner.clearWorking(recordId: recordId) }
    func clearSaved(recordId: Int64) throws { try inner.clearSaved(recordId: recordId) }
    func loadMarkers() throws -> [Int64: ReviewMarker] { try inner.loadMarkers() }
    func reviewMarker(recordId: Int64) throws -> ReviewMarker { try inner.reviewMarker(recordId: recordId) }
}

/// 第二条 record fixture（mirror harness 内 seed 用的字段：ops=[] / finalTick=7 / profit=0 / returnRate=0，
/// 使入口终局等式校验同样通过），供跨 session token 隔离测试用。
private func secondFixtureRecord() -> TrainingRecord {
    TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 2,
                   stockCode: "000002", stockName: "股B", startYear: 2020, startMonth: 1,
                   totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: -0.02,
                   buyCount: 0, sellCount: 0,
                   feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                   finalTick: 7)
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

    // final-review T6（此前未测的 fail-closed 分支）：working 坏 → clearWorking + 返回 nil，
    // 既有 saved 未被误清（marker 回退 .saved 非 .none）、且未留下悬空活跃 session 状态。
    @Test func resumePendingReview_workingCorrupt_clearsWorking_returnsNil() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])       // 既有 saved
        try h.reviewRepo.saveWorking(recordId: h.seededRecordId, stepTick: 4, drawings: [line(20)])
        h.reviewRepo.failNextLoadWorking = .persistence(.dbCorrupted)

        let e = try await h.coordinator.resumePendingReview(recordId: h.seededRecordId)

        #expect(e == nil)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)          // working 已清
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)       // 回退到既有 saved（非 .none）
        #expect(h.coordinator.activeEngine == nil)                                        // 未留下悬空活跃 session
        #expect(h.coordinator.hasReviewInProgress(recordId: h.seededRecordId) == false)
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

// MARK: - Task 7: review autosave 单写者 fence（token/revision/drain，终态 last-wins）

@MainActor
@Suite("ReviewAutosaveFence")
struct ReviewAutosaveFenceTests {

    // 1) 快速多次 autosaveReview（延迟替身放大竞态窗口）后立即 backReview（终态）：
    //    最终 working == 最后一次引擎状态，不被迟到的排队 autosave 覆盖。
    @Test func burstAutosaveThenImmediateBackReview_finalStateIsTerminalNotStale() async throws {
        let h = try ReviewTestHarness.make(wrapRepoForTesting: { SlowReviewArchiveRepo(wrapping: $0) })
        let e = try await h.coordinator.review(recordId: h.seededRecordId)

        e.setReviewDrawingsForTesting([line(10)])
        h.coordinator.autosaveReview(engine: e)
        e.setReviewDrawingsForTesting([line(10), line(20)])
        h.coordinator.autosaveReview(engine: e)
        e.setReviewDrawingsForTesting([line(10), line(20), line(30)])
        h.coordinator.autosaveReview(engine: e)

        try await h.coordinator.backReview(engine: e)   // drain → persistReviewWorkingIfChanged → endSession

        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId)?.drawings
                == [line(10), line(20), line(30)])
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)
    }

    // 同上，但终态走 endReviewSave（commitReview）：saved == 最后一次状态，working 已清。
    @Test func burstAutosaveThenImmediateEndReviewSave_finalStateIsTerminalNotStale() async throws {
        let h = try ReviewTestHarness.make(wrapRepoForTesting: { SlowReviewArchiveRepo(wrapping: $0) })
        let e = try await h.coordinator.review(recordId: h.seededRecordId)

        e.setReviewDrawingsForTesting([line(1)])
        h.coordinator.autosaveReview(engine: e)
        e.setReviewDrawingsForTesting([line(1), line(2)])
        h.coordinator.autosaveReview(engine: e)

        try await h.coordinator.endReviewSave(engine: e)   // drain → commitReview → endSession

        #expect(try h.reviewRepo.loadSaved(recordId: h.seededRecordId) == [line(1), line(2)])
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)
    }

    // 同上，但终态走 endReviewDiscard：working 已清（放弃改动），与 autosave 排队写内容无关。
    @Test func burstAutosaveThenImmediateEndReviewDiscard_workingCleared() async throws {
        let h = try ReviewTestHarness.make(wrapRepoForTesting: { SlowReviewArchiveRepo(wrapping: $0) })
        let e = try await h.coordinator.review(recordId: h.seededRecordId)

        e.setReviewDrawingsForTesting([line(5)])
        h.coordinator.autosaveReview(engine: e)

        try await h.coordinator.endReviewDiscard(engine: e)   // drain → discardReviewWorking → endSession

        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .none)
    }

    // 2) 旧 token 的写被丢弃：session A 排队一次 autosave（token=TA，尚无 suspension 故尚未执行），
    //    未经正规终态直接进入 session B（对抗性场景：mint 新 token=TB）。显式排空——A 排的 task 此刻
    //    检查 reviewSessionToken(TB) != 捕获的 TA → 早退丢弃，两条记录均未被那次陈旧写触碰。
    @Test func staleTokenAfterSessionSwitch_pendingAutosaveDropped_neitherRecordWritten() async throws {
        let h = try ReviewTestHarness.make()
        let idB = try h.recordRepo.insertRecord(secondFixtureRecord(), ops: [], drawings: [])

        let eA = try await h.coordinator.review(recordId: h.seededRecordId)
        eA.setReviewDrawingsForTesting([line(99)])
        h.coordinator.autosaveReview(engine: eA)          // 排队写（token=TA），尚未执行

        _ = try await h.coordinator.review(recordId: idB)  // mint 新 token=TB（未先 endSession，故意对抗）

        await h.coordinator.drainReviewAutosaveForTesting() // 排空：A 排的 task 见 token 不符 → 早退丢弃

        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
        #expect(try h.reviewRepo.loadWorking(recordId: idB) == nil)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .none)
        #expect(try h.reviewRepo.reviewMarker(recordId: idB) == .none)
    }

    // 3) 无复盘 session（reviewSessionToken==nil）→ autosaveReview no-op，不排程 Task、不碰 repo。
    @Test func autosaveReview_noReviewSession_isNoOp() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.startNewNormalSession()   // 非 review session

        h.coordinator.autosaveReview(engine: e)
        await h.coordinator.drainReviewAutosaveForTesting()       // 若误排程，这里会等到；no-op 应立即返回

        #expect(h.coordinator.loadReviewMarkers().isEmpty)
    }

    // 4) lifecycle 转发：TrainingSessionLifecycle.autosaveReview/backReview/endReviewSave/endReviewDiscard/
    //    reviewNetChanged 均正确转发到 coordinator。
    @Test func lifecycleForwarders_delegateToCoordinator() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        let lifecycle = TrainingSessionLifecycle(engine: e, coordinator: h.coordinator)

        #expect(lifecycle.reviewNetChanged() == false)
        e.setReviewDrawingsForTesting([line(7)])
        #expect(lifecycle.reviewNetChanged() == true)

        lifecycle.autosaveReview(engine: e)
        try await lifecycle.backReview(engine: e)

        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId)?.drawings == [line(7)])
        #expect(h.coordinator.activeEngine == nil)   // endSession 已执行
    }
}
