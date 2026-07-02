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
    /// `metaStartDatetime`：codex whole-branch R6 回归测试专用——注入非默认训练组 meta.startDatetime，
    /// 使派生的 `metaStartTick` > 0（默认 fixture meta.startDatetime=1 恒使 metaStartTick==0，
    /// 无法复现「working.stepTick 落在 [0, metaStartTick) 」这一 R6 场景）。nil=沿用默认 fixture meta。
    static func make(wrapRepoForTesting wrap: ((InMemoryReviewArchiveRepository) -> ReviewArchiveRepository)? = nil,
                      metaStartDatetime: Int64? = nil)
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
        let factory: PreviewTrainingSetDBFactory
        if let startDatetime = metaStartDatetime {
            let meta = TrainingSetMeta(stockCode: "000001", stockName: "股",
                                       startDatetime: startDatetime, endDatetime: startDatetime + 10_000)
            factory = PreviewTrainingSetDBFactory(meta: meta, candles: candles)
        } else {
            factory = PreviewTrainingSetDBFactory(candles: candles)
        }
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

    // codex whole-branch review [medium]：key(_:) 曾遗漏 revealTick，致「同几何异渐显时机」被误判为无改动。
    @Test @MainActor func sameGeometryDifferentRevealTick_changed() {
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 5, price: 10)]
        let saved   = [DrawingObject(toolType: .horizontal, anchors: anchors, isExtended: false, panelPosition: 0, revealTick: 100)]
        let working = [DrawingObject(toolType: .horizontal, anchors: anchors, isExtended: false, panelPosition: 0, revealTick: 200)]
        #expect(ReviewNetChange.changed(working: working, committed: saved) == true)
    }

    @Test @MainActor func sameGeometrySameRevealTick_noChange() {
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 5, price: 10)]
        let saved   = [DrawingObject(toolType: .horizontal, anchors: anchors, isExtended: false, panelPosition: 0, revealTick: 100)]
        let working = [DrawingObject(toolType: .horizontal, anchors: anchors, isExtended: false, panelPosition: 0, revealTick: 100)]
        #expect(ReviewNetChange.changed(working: working, committed: saved) == false)
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

    // codex whole-branch R5（high）：`working.stepTick` 越界（负数或超过 record.finalTick——schema 漂移/
    // 损坏，DB CHECK 只强制非空配对、不校验 tick 边界）此前直接传给 `buildReviewEngine`，令
    // `TrainingEngine.make` 因 `flow.allowedTickRange` 不含该 tick 而 trap-guard throw；但坏 working 行
    // 仍 `.inProgress`，之后每次 tap 都重试同一失败 resume（永久 brick，永远无法进复盘）。
    // 修复后须先校验、越界 → clearWorking + nil（router 回退 fresh review，saved/record 不受影响）。
    @Test func resumePendingReview_workingStepTickNegative_clearsWorking_returnsNil() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])   // 既有 saved，须保留
        try h.reviewRepo.saveWorking(recordId: h.seededRecordId, stepTick: -1, drawings: [line(20)])   // 越界：负数

        let e = try await h.coordinator.resumePendingReview(recordId: h.seededRecordId)

        #expect(e == nil)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)          // working 已清
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)       // 回退到既有 saved（非 .none）
        #expect(try h.reviewRepo.loadSaved(recordId: h.seededRecordId) == [line(10)])      // saved 原样未动
        #expect(h.coordinator.activeEngine == nil)                                        // 未留下悬空活跃 session
        #expect(h.coordinator.hasReviewInProgress(recordId: h.seededRecordId) == false)
    }

    @Test func resumePendingReview_workingStepTickBeyondFinal_clearsWorking_returnsNil() async throws {
        let h = try ReviewTestHarness.make()   // seededFinalTick == 7
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])   // 既有 saved，须保留
        try h.reviewRepo.saveWorking(recordId: h.seededRecordId, stepTick: 8, drawings: [line(20)])   // 越界：超过 finalTick=7

        let e = try await h.coordinator.resumePendingReview(recordId: h.seededRecordId)

        #expect(e == nil)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)          // working 已清
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)       // 回退到既有 saved（非 .none）
        #expect(try h.reviewRepo.loadSaved(recordId: h.seededRecordId) == [line(10)])      // saved 原样未动
        #expect(h.coordinator.activeEngine == nil)                                        // 未留下悬空活跃 session
        #expect(h.coordinator.hasReviewInProgress(recordId: h.seededRecordId) == false)
    }

    // codex whole-branch R6（high）：R5 加的 guard 只挡 `working.stepTick` 越出 `0...finalTick`，未验
    // 训练组 metadata 派生的真实下界 `metaStartTick`（可 >0）。fixture 注入 metaStartDatetime 使
    // metaStartTick==3（seededFinalTick==7），working.stepTick=2 落在 [0, metaStartTick) 内、通过 R5
    // 的 0...7 guard，但仍是越界 resume tick——此前会让 `TrainingEngine.make` 的
    // `AppError.trainingSet(.emptyData)` 直接冒泡给调用方，working 行却仍 `.inProgress`（永久 brick）。
    // 修复后须 clearWorking + 返回 nil，且随后一次 fresh `review()` 必须能成功打开（无 brick）。
    @Test func resumePendingReview_workingStepTickBelowMetaStartTick_clearsWorking_returnsNil_noBrick() async throws {
        let h = try ReviewTestHarness.make(metaStartDatetime: 541)   // datetime=1+gi*180 → gi=3 时 541 → metaStartTick==3
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])   // 既有 saved，须保留
        try h.reviewRepo.saveWorking(recordId: h.seededRecordId, stepTick: 2, drawings: [line(20)])   // 越界：< metaStartTick(3)，但在 0...7 内

        let e = try await h.coordinator.resumePendingReview(recordId: h.seededRecordId)

        #expect(e == nil)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)          // working 已清
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)       // 回退到既有 saved（非 .none）
        #expect(try h.reviewRepo.loadSaved(recordId: h.seededRecordId) == [line(10)])      // saved 原样未动
        #expect(h.coordinator.activeEngine == nil)                                        // 未留下悬空活跃 session
        #expect(h.coordinator.hasReviewInProgress(recordId: h.seededRecordId) == false)

        // 无 brick：随后一次 fresh review() 必须能正常打开（非重复撞同一失败 resume）。
        let fresh = try await h.coordinator.review(recordId: h.seededRecordId)
        #expect(fresh.flow.mode == .review)
        #expect(fresh.tick.globalTickIndex == 3)   // metaStartTick
    }

    // codex whole-branch R2（high）：`resumePendingReview` 此前用 `try?` 把 `reviewMarker` 的瞬态读错误
    // 收敛为 `.none`，router 据此回退 fresh `review()`——若此时存在有效 `working_*` 行，用户随后放弃会把它
    // 清掉，丢失一份仍在进行的复盘。修复后瞬态错误须 PROPAGATE（不得静默回退 nil），working 行原样保留。
    @Test func resumePendingReview_reviewMarkerTransientError_propagatesAndPreservesWorking() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.saveWorking(recordId: h.seededRecordId, stepTick: 4, drawings: [line(20)])
        h.reviewRepo.failNextReviewMarker = .internalError(module: "test", detail: "transient marker read")

        await #expect(throws: (any Error).self) {
            _ = try await h.coordinator.resumePendingReview(recordId: h.seededRecordId)
        }

        // working 行未被清、未被覆盖——fail-closed 传播，非静默回退到 fresh review。
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId)?.drawings == [line(20)])
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)
        #expect(h.coordinator.activeEngine == nil)   // 未启动任何 fresh session（未 clobber）
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

    // MARK: - codex whole-branch R4 finding 2：commitReview/discardReviewWorking 必须校验 engine 仍是 activeEngine
    //
    // `endReviewSave`/`endReviewDiscard` 在调用 `commitReview`/`discardReviewWorking` 前 `await
    // fenceAndDrainReviewAutosave()`——@MainActor 重入窗口内若会话状态先被换成另一记录（`activeEngine`/
    // `reviewRecordId` 均已指向新会话），陈旧调用方仍持旧 engine 会把旧数据错写进新 `reviewRecordId` 的存档。
    // 修复=两个终态写者顶部加身份闸，不符 → throw `.internalError`（非静默 no-op，terminal writer 必须显错）。

    @Test func commitReview_staleEngine_throwsInternalError_doesNotMutateArchive() async throws {
        let h = try ReviewTestHarness.make()
        let idB = try h.recordRepo.insertRecord(secondFixtureRecord(), ops: [], drawings: [])
        let eA = try await h.coordinator.review(recordId: h.seededRecordId)
        eA.setReviewDrawingsForTesting([line(99)])

        _ = try await h.coordinator.review(recordId: idB)   // activeEngine → B 的引擎；reviewRecordId → idB

        do {
            try h.coordinator.commitReview(engine: eA)   // 陈旧调用方仍持 A 的引擎
            Issue.record("expected commitReview(engine: eA) to throw for stale/mismatched engine")
        } catch let e as AppError {
            guard case .internalError = e else {
                Issue.record("expected .internalError, got \(e)")
                return
            }
        }

        // A、B 的存档均未被这次陈旧写触碰。
        #expect(try h.reviewRepo.reviewMarker(recordId: idB) == .none)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .none)
    }

    @Test func discardReviewWorking_staleEngine_throwsInternalError_doesNotMutateArchive() async throws {
        let h = try ReviewTestHarness.make()
        let idB = try h.recordRepo.insertRecord(secondFixtureRecord(), ops: [], drawings: [])
        try h.reviewRepo.saveWorking(recordId: h.seededRecordId, stepTick: 4, drawings: [line(20)])   // A 有 working
        let eA = try #require(try await h.coordinator.resumePendingReview(recordId: h.seededRecordId))

        try h.reviewRepo.saveWorking(recordId: idB, stepTick: 1, drawings: [line(50)])   // B 自己的合法 working
        _ = try await h.coordinator.review(recordId: idB)   // activeEngine → B 的引擎；reviewRecordId → idB

        do {
            try h.coordinator.discardReviewWorking(engine: eA)   // 陈旧调用方仍持 A 的引擎
            Issue.record("expected discardReviewWorking(engine: eA) to throw for stale/mismatched engine")
        } catch let e as AppError {
            guard case .internalError = e else {
                Issue.record("expected .internalError, got \(e)")
                return
            }
        }

        // A、B 的 working 行均未被这次陈旧写触碰（尤其 B 的合法 working 不能被误清）。
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId)?.drawings == [line(20)])
        #expect(try h.reviewRepo.loadWorking(recordId: idB)?.drawings == [line(50)])
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

    // codex whole-branch R2（medium）：失败 alert 的「放弃」此前调 `endReviewDiscard`——若其内部
    // `discardReviewWorking`（clearWorking）抛错，`endSession` 从未执行 → coordinator 保留活跃
    // reader/session，router 却已摘视图（会话/reader 泄漏）。`abandonReview` 须**恒**收尾：清档失败
    // 也照常 endSession（working 行原样保留，`复盘中` marker 不变——可恢复，用户可重新进入再结束一次）。
    @Test func abandonReview_clearWorkingThrows_stillEndsSessionAndPreservesWorkingRow() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.saveWorking(recordId: h.seededRecordId, stepTick: 4, drawings: [line(20)])
        let e = try #require(try await h.coordinator.resumePendingReview(recordId: h.seededRecordId))
        h.reviewRepo.failNextClearWorking = .internalError(module: "test", detail: "transient clear failure")

        await h.coordinator.abandonReview(engine: e)

        #expect(h.coordinator.activeEngine == nil)     // 会话已恒收尾（reader/session 未泄漏）
        #expect(h.coordinator.activeReader == nil)
        // 清档失败 → working 行原样保留（未清），marker 仍 .inProgress（可恢复：重新进入再结束一次）。
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId)?.drawings == [line(20)])
    }

    // 对照：clearWorking 成功时 abandonReview 行为等价于既有 endReviewDiscard（working 已清 + 会话收尾）。
    @Test func abandonReview_clearWorkingSucceeds_clearsWorkingAndEndsSession() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        h.coordinator.setReviewSessionForTesting(recordId: h.seededRecordId, committedBaseline: [])
        e.setReviewDrawingsForTesting([line(5)])
        try h.coordinator.persistReviewWorkingIfChanged(engine: e)   // 落 working（.inProgress）

        await h.coordinator.abandonReview(engine: e)

        #expect(h.coordinator.activeEngine == nil)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .none)
    }

    // lifecycle 转发：TrainingSessionLifecycle.abandonReview 正确转发到 coordinator。
    @Test func lifecycle_abandonReview_delegatesToCoordinator() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        h.coordinator.setReviewSessionForTesting(recordId: h.seededRecordId, committedBaseline: [])
        e.setReviewDrawingsForTesting([line(3)])
        try h.coordinator.persistReviewWorkingIfChanged(engine: e)
        let lifecycle = TrainingSessionLifecycle(engine: e, coordinator: h.coordinator)

        await lifecycle.abandonReview(engine: e)

        #expect(h.coordinator.activeEngine == nil)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
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

    // MARK: - codex whole-branch R1（data-loss）：scenePhase 后台 flush review working 态
    //
    // 此前 scenePhase `.inactive/.background` 只调 `flushForBackground`（对 review no-op），review 全靠
    // 排队 `autosaveReview` 落盘；若该 Task 尚未排空、OS 随后杀进程，工作态丢失且无 durable working 行。
    // 本组验证新 `flushReviewForBackground`：① 未经手动 drain 即落盘当前 working 态；② 与终态栅栏
    // `fenceAndDrainReviewAutosave` 的关键区别——**不** invalidate `reviewSessionToken`，session 继续
    // （回前台后仍可正常 autosave，非 backReview/endReviewSave/endReviewDiscard 那种终态语义）。

    // 1) 画线改动后排队 autosaveReview（故意不手动 drain）→ flushReviewForBackground → working 行已落盘。
    @Test func flushReviewForBackground_persistsPendingWorkingState_withoutManualDrain() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)

        e.setReviewDrawingsForTesting([line(42)])
        h.coordinator.autosaveReview(engine: e)   // 排队，故意不 drainReviewAutosaveForTesting

        await h.coordinator.flushReviewForBackground(engine: e)

        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId)?.drawings == [line(42)])
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)
    }

    // 2) 关键区别断言：flush 后 session 未终止——reviewSessionToken 未被 invalidate，activeEngine 仍在，
    //    后续 autosaveReview 仍正常生效（若 token 被误清，此处第二次写会因 guard 早退而丢失）。
    @Test func flushReviewForBackground_doesNotInvalidateSession_subsequentAutosaveStillWorks() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)

        e.setReviewDrawingsForTesting([line(1)])
        h.coordinator.autosaveReview(engine: e)
        await h.coordinator.flushReviewForBackground(engine: e)

        #expect(h.coordinator.activeEngine != nil)   // 未 endSession（与终态 backReview 不同）

        e.setReviewDrawingsForTesting([line(1), line(2)])
        h.coordinator.autosaveReview(engine: e)
        await h.coordinator.drainReviewAutosaveForTesting()

        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId)?.drawings == [line(1), line(2)])
    }

    // 3) 无复盘 session（normal 引擎）→ no-op，不误碰 repo。
    @Test func flushReviewForBackground_normalMode_isNoOp() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.startNewNormalSession()

        await h.coordinator.flushReviewForBackground(engine: e)

        #expect(h.coordinator.loadReviewMarkers().isEmpty)
    }

    // 4) lifecycle 转发。
    @Test func lifecycle_flushReviewForBackground_delegatesToCoordinator() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        let lifecycle = TrainingSessionLifecycle(engine: e, coordinator: h.coordinator)

        e.setReviewDrawingsForTesting([line(9)])
        await lifecycle.flushReviewForBackground(engine: e)

        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId)?.drawings == [line(9)])
    }

    // MARK: - codex whole-branch R3（high，data resurrection）：终态收尾后陈旧 background flush 不得复活
    //
    // 缺陷：`TrainingView` 在 scenePhase `.inactive/.background` 分支起一个 UNSTRUCTURED `Task`，捕获
    // 当时的 `engine`，稍后才调 `flushReviewForBackground(engine:)`。若一个终态动作（`endReviewDiscard`/
    // `abandonReview`/`backReview`）先完成收尾（working 已清或已提交、`endSession` 已跑），
    // 该陈旧 Task 才轮到执行——此前 `flushReviewForBackground`/`persistReviewWorkingIfChanged` 只凭
    // `reviewRecordId != nil` 判活，无法分辨"这颗 engine 是否还是当前活跃 session"，遂把陈旧 engine
    // 内存里未清的 `reviewDrawings`（与 committed 基线不同）当净改动重新写回 working 行——用户已看到的
    // 丢弃/保存又"复活"成`复盘中`。修复=双保险：① `endSession` 清 `reviewRecordId`/`reviewCommittedBaseline`；
    // ② `persistReviewWorkingIfChanged`/`flushReviewForBackground` 顶部加 `activeEngine === engine` 身份闸。

    // 1) 完整交错场景：先落一条 working（模拟画线未存），terminal `endReviewDiscard` 完成收尾（working 已清、
    //    `reviewRecordId` 归 nil），随后陈旧 `flushReviewForBackground(engine: e)`（捕获的仍是同一个内存里
    //    reviewDrawings 未变的 e）执行——必须 no-op，不得把 marker 从 `.saved` 又翻回 `.inProgress`。
    @Test func staleFlushReviewForBackground_afterEndReviewDiscard_doesNotResurrectDiscardedWorking() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])   // 既有 saved 基线
        let e = try await h.coordinator.review(recordId: h.seededRecordId)

        e.setReviewDrawingsForTesting([line(10), line(20)])            // 偏离 committed 基线
        try h.coordinator.persistReviewWorkingIfChanged(engine: e)      // 模拟中途 autosave：落 working
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)

        // Terminal 动作先完成：discard working + endSession（reviewRecordId 归 nil，见 endSession 修复）。
        try await h.coordinator.endReviewDiscard(engine: e)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)

        // 陈旧 background flush 才轮到执行：engine `e` 本身未被 discard/endSession 改动，
        // `e.reviewDrawings` 仍是 [line(10), line(20)]（≠ 已清的 committed 基线）——必须 no-op。
        await h.coordinator.flushReviewForBackground(engine: e)

        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)   // 未被翻回 .inProgress
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)       // 未被重新写入
        #expect(try h.reviewRepo.loadSaved(recordId: h.seededRecordId) == [line(10)])  // saved 基线未被触碰
    }

    // 隔离验证 `endSession` 清 `reviewCommittedBaseline`（fix 1）本身：`reviewNetChanged()` 不经任何
    // engine 身份闸——直接读 `activeEngine?.reviewDrawings ?? []` vs `reviewCommittedBaseline`。若终态
    // 收尾后 `reviewCommittedBaseline` 残留非空陈旧基线，`activeEngine` 已 nil（working 侧退化为 []），
    // 净改动判定会误判 `true`（非空 committed ≠ 空 working）——供 `ReviewEndPrompt` 用的
    // `reviewNetChanged()` 会在无活跃会话时凭空报「有未保存改动」。本测试独立于 persist/flush 的
    // `activeEngine === engine` 身份闸（那两处不覆盖 `reviewNetChanged()` 这条只读路径）。
    @Test func endSession_clearsCommittedBaseline_reviewNetChangedFalseAfterTerminalTeardown() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])   // 非空 committed 基线
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        #expect(h.coordinator.reviewNetChanged() == false)   // fresh：working==committed==[line(10)]

        try await h.coordinator.endReviewDiscard(engine: e)   // 终态收尾：activeEngine→nil

        #expect(h.coordinator.activeEngine == nil)
        #expect(h.coordinator.reviewNetChanged() == false)    // 收尾后必须归零，非残留基线误判 true
    }

    // 同上，但 terminal 动作走 `abandonReview`（同类稳健放弃路径）。
    @Test func staleFlushReviewForBackground_afterAbandonReview_doesNotResurrectDiscardedWorking() async throws {
        let h = try ReviewTestHarness.make()
        try h.reviewRepo.commitSaved(recordId: h.seededRecordId, drawings: [line(10)])
        let e = try await h.coordinator.review(recordId: h.seededRecordId)

        e.setReviewDrawingsForTesting([line(10), line(30)])
        try h.coordinator.persistReviewWorkingIfChanged(engine: e)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)

        await h.coordinator.abandonReview(engine: e)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)

        await h.coordinator.flushReviewForBackground(engine: e)

        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .saved)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
    }

    // 2) 隔离验证「activeEngine === engine」身份闸本身（不依赖 endSession 清态）：人为把 `reviewRecordId`/
    //    `reviewCommittedBaseline` 强制指回 A 记录（模拟"state 未被清"的极端场景），但 `activeEngine` 已经
    //    是 B 记录的引擎——即便 guard 1（reviewRecordId != nil）会放行，身份闸也必须单独拦下 A 的陈旧写。
    @Test func activeEngineIdentityGuard_blocksStaleEngine_evenWhenReviewRecordIdStillSet() async throws {
        let h = try ReviewTestHarness.make()
        let eA = try await h.coordinator.review(recordId: h.seededRecordId)   // activeEngine=eA, reviewRecordId=seeded
        let idB = try h.recordRepo.insertRecord(secondFixtureRecord(), ops: [], drawings: [])
        _ = try await h.coordinator.review(recordId: idB)                    // activeEngine 现在是 B 的引擎（≠ eA）

        // 人为把复盘 session 态指回 A（模拟"未被清"的场景）：即便 reviewRecordId != nil 判活为真，
        // activeEngine 已不是 eA。
        h.coordinator.setReviewSessionForTesting(recordId: h.seededRecordId, committedBaseline: [])
        eA.setReviewDrawingsForTesting([line(99)])                            // 陈旧 engine 内存中的"净改动"

        try h.coordinator.persistReviewWorkingIfChanged(engine: eA)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .none)   // 身份闸拦下，未写

        await h.coordinator.flushReviewForBackground(engine: eA)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .none)   // 同样拦下

        // 对照：activeEngine 自己（B 的引擎）走同一路径应正常放行（证明身份闸只挡陈旧引擎，非全局失效）。
        let eB = h.coordinator.activeEngine!
        eB.setReviewDrawingsForTesting([line(77)])
        try h.coordinator.persistReviewWorkingIfChanged(engine: eB)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .inProgress)   // 写的是当前指回的 seeded id
    }

    // MARK: - codex whole-branch R4 finding 1：review autosave/flush 持久化失败必须可观察（mirror normal autosave）
    //
    // 此前 `autosaveReview`/`flushReviewForBackground` 内部用 `try?` 吞掉 `persistReviewWorkingIfChanged`
    // 的失败（DB 不可用/磁盘满）：用户可能后台/杀进程时以为画线/步进已存，实则未存，且无任何可观察信号。
    // 修复=复用 normal autosave 已有的同一套可观察信号（`autosaveBannerError` + 单调 `autosaveErrorGeneration`），
    // 供 `TrainingView` 既有 `.onChange(of: autosaveErrorGeneration)` + scenePhase `.active` replay 呈现 toast。

    @Test func autosaveReview_saveWorkingFails_recordsObservableAutosaveError() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        e.setReviewDrawingsForTesting([line(10)])   // 净改动 → persist 走 saveWorking 分支（非 clearWorking）
        h.reviewRepo.failNextSaveWorking = .persistence(.diskFull)

        h.coordinator.autosaveReview(engine: e)
        await h.coordinator.drainReviewAutosaveForTesting()

        #expect(h.coordinator.autosaveErrorGeneration == 1)
        #expect(h.coordinator.autosaveBannerError == .persistence(.diskFull))
        #expect(h.coordinator.autosaveBannerError?.shouldShowToast == true)
        // 写确实失败了（fixture 未收到 working 行），非「碰巧失败前已写完」的假阳性。
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
    }

    @Test func flushReviewForBackground_saveWorkingFails_recordsObservableAutosaveError() async throws {
        let h = try ReviewTestHarness.make()
        let e = try await h.coordinator.review(recordId: h.seededRecordId)
        e.setReviewDrawingsForTesting([line(10)])
        h.reviewRepo.failNextSaveWorking = .persistence(.diskFull)

        await h.coordinator.flushReviewForBackground(engine: e)

        #expect(h.coordinator.autosaveErrorGeneration == 1)
        #expect(h.coordinator.autosaveBannerError == .persistence(.diskFull))
        #expect(h.coordinator.autosaveBannerError?.shouldShowToast == true)
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
    }

    // MARK: - codex whole-branch R6（medium）：stale-engine `autosaveReview` 不得占用共享 task 槽位
    //
    // 缺陷：`autosaveReview` 此前只校验 `reviewSessionToken != nil`，未校验 `engine` 仍是 `activeEngine`——
    // 一枚捕获了旧 session engine 的陈旧调用（例如刚切到新记录 B 之后，仍持 A 的 engine 的回调）会先
    // 递增 `reviewRevision` / 占用 `reviewAutosaveTask` 槽位（该身份校验此前只在 `persistReviewWorkingIfChanged`
    // 内部真正落盘时才生效），导致新 session 紧随其后的合法 `autosaveReview(engine: B)` 因槽位已占用
    // 只被合并（不重新排程）——但排队 Task 闭包捕获的仍是陈旧的 A engine，最终因身份闸 no-op，
    // B 的这次改动直到下一次触发才真正落盘（本测试若不修复会在此处静默丢失）。
    @Test func autosaveReview_staleEngine_doesNotBumpRevisionOrOccupyTask_currentSessionStillWorks() async throws {
        let h = try ReviewTestHarness.make()
        let idB = try h.recordRepo.insertRecord(secondFixtureRecord(), ops: [], drawings: [])
        let eA = try await h.coordinator.review(recordId: h.seededRecordId)   // session A: activeEngine=eA

        _ = try await h.coordinator.review(recordId: idB)   // 切到 B（未先 endSession）：activeEngine 现为 B 的引擎，reviewRevision 归 0

        let revisionBefore = h.coordinator.reviewRevisionForTesting
        eA.setReviewDrawingsForTesting([line(99)])          // 陈旧引擎 A 内存中的"净改动"
        h.coordinator.autosaveReview(engine: eA)            // 陈旧调用：activeEngine(B) !== eA → 应早退，不占槽/不计数

        #expect(h.coordinator.reviewRevisionForTesting == revisionBefore)     // 未递增
        #expect(h.coordinator.hasQueuedReviewAutosaveForTesting == false)     // 未占用排队槽位

        // 当前会话 B 的合法 autosaveReview 必须仍能正常排程 + 落盘（未被陈旧调用"吃掉"）。
        let eB = h.coordinator.activeEngine!
        eB.setReviewDrawingsForTesting([line(5)])
        h.coordinator.autosaveReview(engine: eB)
        await h.coordinator.drainReviewAutosaveForTesting()

        #expect(try h.reviewRepo.loadWorking(recordId: idB)?.drawings == [line(5)])
        #expect(try h.reviewRepo.reviewMarker(recordId: idB) == .inProgress)
        // A 的存档全程未被这次陈旧调用触碰。
        #expect(try h.reviewRepo.loadWorking(recordId: h.seededRecordId) == nil)
        #expect(try h.reviewRepo.reviewMarker(recordId: h.seededRecordId) == .none)
    }
}
