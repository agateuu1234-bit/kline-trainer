import Testing
import Foundation
@testable import KlineTrainerContracts

// MARK: - Harness

/// CoordinatorTestHarness: in-memory 装配的 coordinator，seed 一条或多条 record + fixture 训练组，
/// 使 replay(recordId:) 和 review(recordId:) 可以成功返回引擎。
/// Mirror TrainingSessionPersistenceTests.makeCoordinator 的组装模式。
@MainActor
struct CoordinatorTestHarness {
    let coordinator: TrainingSessionCoordinator
    let pendingRepo: InMemoryPendingTrainingRepository
    let pendingReplayRepo: InMemoryPendingReplayRepository
    let recordRepo: InMemoryRecordRepository
    let seededRecordId: Int64

    /// 组装含单条 record（trainingSetFilename="set.sqlite"）的 harness。
    static func make() throws -> CoordinatorTestHarness {
        try make(seedRecordIds: [1])
    }

    /// 组装含多条 record 的 harness；seedRecordIds 仅为 "数量" 占位（实际 DB 自增 id）；
    /// 返回时 seededRecordId = 第一条记录的 DB id。
    static func make(seedRecordIds: [Int]) throws -> CoordinatorTestHarness {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let pendingReplay = InMemoryPendingReplayRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let cache = InMemoryCacheManager()
        let file = TrainingSetFile(id: 1, filename: "set.sqlite",
                                   localURL: URL(fileURLWithPath: "/tmp/set.sqlite"),
                                   schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
        cache._seedForTesting([file])

        // 注入包含足够 m3/m60/daily/weekly candles 的 factory（满足 startTick + maxTick 校验）。
        let candles = makeCandles()
        let factory = PreviewTrainingSetDBFactory(candles: candles)

        let settingsDAO = CapitalDAO(capital: 100_000)
        let coord = TrainingSessionCoordinator(
            dbFactory: factory,
            recordRepo: records,
            pendingRepo: pending,
            pendingReplayRepo: pendingReplay,
            finalization: port,
            settingsDAO: settingsDAO,
            cache: cache,
            settings: SettingsStore(settingsDAO: settingsDAO))

        // Seed records（fake insertRecord 自增 id）
        var firstId: Int64 = 0
        for _ in seedRecordIds {
            let id = try records.insertRecord(
                TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                               stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                               totalCapital: 100_000, profit: 5_000,
                               returnRate: 0.05, maxDrawdown: -0.03,
                               buyCount: 1, sellCount: 1,
                               feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                               finalTick: 7),
                ops: [], drawings: [])
            if firstId == 0 { firstId = id }
        }

        return CoordinatorTestHarness(
            coordinator: coord,
            pendingRepo: pending,
            pendingReplayRepo: pendingReplay,
            recordRepo: records,
            seededRecordId: firstId)
    }

    struct CapitalDAO: SettingsDAO {
        let capital: Double
        func loadSettings() throws -> AppSettings {
            AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                        totalCapital: capital, displayMode: .system)
        }
        func saveSettings(_: AppSettings) throws {}
        func resetCapital() throws {}
    }

    /// 含 m3/m60/daily/weekly 的 candle fixture（weekly 使 switchPeriodCombo(.toLarger) 从 m60/daily → daily/weekly 有效）。
    static func makeCandles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int, close: Double) -> KLineCandle {
            KLineCandle(period: p, datetime: 1 + Int64(gi) * 180, open: 10, high: 11, low: 9,
                        close: close, volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: gi, endGlobalIndex: egi)
        }
        let m3 = (0..<m3Count).map { c(.m3, gi: $0, egi: $0, close: 10 + Double($0) * 0.1) }
        let last = m3Count - 1
        let m60 = [c(.m60, gi: 0, egi: last / 2, close: 10.3),
                   c(.m60, gi: last / 2 + 1, egi: last, close: 10.7)]
        let daily = [c(.daily, gi: 0, egi: last, close: 10.7)]
        let weekly = [c(.weekly, gi: 0, egi: last, close: 10.7)]
        return [.m3: m3, .m60: m60, .daily: daily, .weekly: weekly]
    }
}

// MARK: - Tests

@MainActor
@Suite("CoordinatorReplayPersistence")
struct CoordinatorReplayPersistenceTests {

    @Test func saveProgress_replay_writesPendingReplay() async throws {
        let h = try CoordinatorTestHarness.make()
        let engine = try await h.coordinator.replay(recordId: h.seededRecordId)
        // 模拟前进一根触发脏状态后保存
        engine.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: engine)
        let saved = try h.pendingReplayRepo.loadReplay()
        #expect(saved?.recordId == h.seededRecordId)
        #expect(saved?.globalTickIndex == engine.tick.globalTickIndex)
        // normal 槽不被污染
        #expect(try h.pendingRepo.loadPending() == nil)
    }

    @Test func cleanFreshReplay_backOrBackground_preservesOtherSlot() async throws {
        // codex plan-R4-F1：A 有槽；开新 replay B 零操作 → back()(saveProgress) 与后台 flush 都不得覆盖 A
        let h = try CoordinatorTestHarness.make(seedRecordIds: [1, 2])
        // 用 id 1 先做进度
        let id1 = h.seededRecordId
        let eA = try await h.coordinator.replay(recordId: id1)
        eA.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: eA)         // slot = id1
        await h.coordinator.endSession()
        // 获取 id2（第二条记录）
        let allRecords = try h.recordRepo.listRecords(limit: nil)
        let id2 = allRecords.first(where: { $0.id != id1 })!.id!
        let eB = try await h.coordinator.replay(recordId: id2)   // fresh B，零操作
        try await h.coordinator.saveProgress(engine: eB)         // back() 路径：clean → 跳过
        #expect(try h.pendingReplayRepo.loadReplay()?.recordId == id1)
        await h.coordinator.flushAutosave(engine: eB)            // 后台 flush：clean → 跳过
        await h.coordinator.drainAutosaveForTesting()
        #expect(try h.pendingReplayRepo.loadReplay()?.recordId == id1)   // A 仍在
        // B 做了进度后再存 → 覆盖（单槽 last-active wins）
        eB.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: eB)
        #expect(try h.pendingReplayRepo.loadReplay()?.recordId == id2)
    }

    @Test func replayPeriodChange_isDirty_persistsPeriods() async throws {
        // codex plan-R14-F1：replay 切周期组合（不动 tick/ops/drawings）须算脏并落盘 upper/lowerPeriod
        // 默认 upper=.m60 lower=.daily (combo index 2)；toLarger → daily/weekly (index 3)，需 weekly candles
        let h = try CoordinatorTestHarness.make()
        let e = try await h.coordinator.replay(recordId: h.seededRecordId)
        let origUpper = e.upperPanel.period
        e.switchPeriodCombo(direction: .toLarger)               // m60/daily → daily/weekly
        #expect(e.upperPanel.period != origUpper)    // 周期已变（tick/ops/drawings 未变）
        try await h.coordinator.saveProgress(engine: e)   // clean-skip 比较含周期 → 不跳过、写
        #expect(try h.pendingReplayRepo.loadReplay()?.upperPeriod == e.upperPanel.period)
        #expect(try h.pendingReplayRepo.loadReplay()?.lowerPeriod == e.lowerPanel.period)
    }

    @Test func freshReplayAfterTeardown_autosaveEnabled() async throws {
        // codex plan-R7-F1：前一会话 endSession 留 terminating=true；fresh replay 须 resetAutosaveState 重开栅栏，
        // 否则 tick/后台 autosave 全 no-op（只 back() 存）。验证 advance 后 flush 真写 pending_replay。
        let h = try CoordinatorTestHarness.make()
        let warmup = try await h.coordinator.replay(recordId: h.seededRecordId)
        await h.coordinator.endSession()                         // 留 terminating=true
        let e = try await h.coordinator.replay(recordId: h.seededRecordId)  // fresh：须重开栅栏
        e.holdOrObserve(panel: .upper)                           // dirty
        h.coordinator.requestAutosave(engine: e, immediate: false)  // tick 节流路径
        await h.coordinator.flushAutosave(engine: e)
        await h.coordinator.drainAutosaveForTesting()
        #expect(try h.pendingReplayRepo.loadReplay()?.recordId == h.seededRecordId)  // 已写（栅栏已重开）
        _ = warmup
    }

    @Test func replayDrawingAddThenDelete_noStaleSlot() async throws {
        // codex plan-R6-F1：加画线→存(拥有槽)→删画线(count 回基线)→存 → 槽须更新为无画线（不被 clean-skip 残留）
        let h = try CoordinatorTestHarness.make()
        let e = try await h.coordinator.replay(recordId: h.seededRecordId)
        // 用引擎公共 API 加一条画线
        e.appendDrawing(DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0))
        try await h.coordinator.saveProgress(engine: e)            // 写槽（含 1 画线）→ replayHasPersisted=true
        #expect(try h.pendingReplayRepo.loadReplay()?.drawings.count == 1)
        e.deleteDrawing(at: 0)                                     // 删除 → e.drawings.count 回到 0（==fresh 基线 count）
        try await h.coordinator.saveProgress(engine: e)            // 已拥有槽 → 不 clean-skip → 写无画线
        #expect(try h.pendingReplayRepo.loadReplay()?.drawings.isEmpty == true)   // 无残留
    }

    @Test func requestAutosave_replayEnabled_reviewNoOp() async throws {
        let h = try CoordinatorTestHarness.make()
        let replayEngine = try await h.coordinator.replay(recordId: h.seededRecordId)
        // clean fresh replay：immediate autosave 不写槽（clean-skip 守卫）
        h.coordinator.requestAutosave(engine: replayEngine, immediate: true)
        await h.coordinator.drainAutosaveForTesting()
        #expect(h.pendingReplayRepo.saveCount == 0)
        // 有进度后：autosave 才写
        replayEngine.holdOrObserve(panel: .upper)
        h.coordinator.requestAutosave(engine: replayEngine, immediate: true)
        await h.coordinator.drainAutosaveForTesting()
        #expect(h.pendingReplayRepo.saveCount >= 1)

        await h.coordinator.endSession()
        let reviewEngine = try await h.coordinator.review(recordId: h.seededRecordId)
        let before = h.pendingReplayRepo.saveCount
        h.coordinator.requestAutosave(engine: reviewEngine, immediate: true)
        await h.coordinator.drainAutosaveForTesting()
        #expect(h.pendingReplayRepo.saveCount == before)   // review 不存（shouldPersistProgress=false）
    }
}
