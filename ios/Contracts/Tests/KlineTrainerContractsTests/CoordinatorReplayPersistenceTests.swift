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
    /// finalTick of the seeded record; used to assert review opens at startTick < finalTick.
    let seededRecordFinalTick: Int

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
        // finalTick = m3Count - 1 = 7（与 makeCandles 默认一致，使 derived startTick 0 < finalTick 7）
        let seededFinalTick = 7
        var firstId: Int64 = 0
        for _ in seedRecordIds {
            let id = try records.insertRecord(
                TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                               stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                               totalCapital: 100_000, profit: 5_000,
                               returnRate: 0.05, maxDrawdown: -0.03,
                               buyCount: 1, sellCount: 1,
                               feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
                               finalTick: seededFinalTick),
                ops: [], drawings: [])
            if firstId == 0 { firstId = id }
        }

        return CoordinatorTestHarness(
            coordinator: coord,
            pendingRepo: pending,
            pendingReplayRepo: pendingReplay,
            recordRepo: records,
            seededRecordId: firstId,
            seededRecordFinalTick: seededFinalTick)
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

    // MARK: - B3: review() derives startTick from training-set metadata

    @Test func review_startsAtTrainingStartTick_notFinalTick() async throws {
        let h = try CoordinatorTestHarness.make()
        let engine = try await h.coordinator.review(recordId: h.seededRecordId)
        #expect(engine.flow.mode == .review)
        #expect(engine.tick.globalTickIndex == engine.flow.initialTick)
        #expect(engine.tick.globalTickIndex < h.seededRecordFinalTick)   // 起点不是末根
        #expect(engine.flow.allowedTickRange.upperBound == h.seededRecordFinalTick)
    }

    // MARK: - A5: resumePendingReplay + hasResumableReplay

    @Test func resumePendingReplay_restoresState() async throws {
        let h = try CoordinatorTestHarness.make()
        let e1 = try await h.coordinator.replay(recordId: h.seededRecordId)
        e1.holdOrObserve(panel: .upper)
        let savedTick = e1.tick.globalTickIndex
        try await h.coordinator.saveProgress(engine: e1)
        await h.coordinator.endSession()

        #expect(h.coordinator.hasResumableReplay(recordId: h.seededRecordId) == true)
        let e2 = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
        #expect(e2 != nil)
        #expect(e2?.tick.globalTickIndex == savedTick)
        #expect(e2?.flow.mode == .replay)
    }

    @Test func resumePendingReplay_recordIdMismatch_returnsNil_noClear() async throws {
        let h = try CoordinatorTestHarness.make()
        let e1 = try await h.coordinator.replay(recordId: h.seededRecordId)
        e1.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: e1)
        await h.coordinator.endSession()
        #expect(h.coordinator.hasResumableReplay(recordId: 999999) == false)
        let e = try await h.coordinator.resumePendingReplay(recordId: 999999)
        #expect(e == nil)
        // 不匹配不清档：另一记录的槽仍在
        #expect(try h.pendingReplayRepo.loadReplay() != nil)
    }

    @Test func resumePendingReplay_corruptSlot_nonMatchingRecord_notBlocked() async throws {
        // codex plan-R11-F1：record A 的损坏 payload 槽不得阻塞 record B 的 replay 入口
        let h = try CoordinatorTestHarness.make(seedRecordIds: [101, 202])
        try h.pendingReplayRepo.saveReplay(makeSlot(recordId: 101))
        h.pendingReplayRepo.failNextLoadReplay = .persistence(.dbCorrupted)  // 全量解码会抛（slotInfo 不受影响）
        // 对 record 202 续局：slotInfo 返 101 ≠ 202 → 直接 nil，**不触发全量 loadReplay**（A 的损坏不阻塞 B）
        let e = try await h.coordinator.resumePendingReplay(recordId: 202)
        #expect(e == nil)
        #expect(try h.pendingReplayRepo.loadReplaySlotInfo()?.recordId == 101)  // A 槽未被清（非本记录不动）
    }

    @Test func resumePendingReplay_corruptSlot_matchingRecord_clearsAndFallsBack() async throws {
        // codex plan-R11-F1：本记录损坏 payload 槽 → 清 + 返回 nil（router 回退从头 fresh）
        let h = try CoordinatorTestHarness.make()
        try h.pendingReplayRepo.saveReplay(makeSlot(recordId: h.seededRecordId))
        h.pendingReplayRepo.failNextLoadReplay = .persistence(.dbCorrupted)  // 本记录槽全量解码损坏
        let e = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
        #expect(e == nil)
        #expect(try h.pendingReplayRepo.loadReplaySlotInfo() == nil)  // 损坏槽已清
    }

    @Test func resumePendingReplay_corruptPositionJSON_clearsAndFallsBack() async throws {
        // codex plan-R18-F1：position_data 合法存在但非法 PositionManager JSON → decodePosition 抛 .dbCorrupted
        // → 与 loadReplay 损坏同路径：清槽 + nil（回退从头），不卡死
        let h = try CoordinatorTestHarness.make()
        var slot = makeSlot(recordId: h.seededRecordId, filename: "set.sqlite")
        slot = PendingReplay(recordId: slot.recordId, trainingSetFilename: slot.trainingSetFilename,
            globalTickIndex: slot.globalTickIndex, upperPeriod: slot.upperPeriod, lowerPeriod: slot.lowerPeriod,
            positionData: Data("{not-valid-position-json".utf8),   // 合法 Data、非法 PositionManager JSON
            cashBalance: slot.cashBalance, feeSnapshot: slot.feeSnapshot, tradeOperations: slot.tradeOperations,
            drawings: slot.drawings, startedAt: slot.startedAt, accumulatedCapital: slot.accumulatedCapital,
            drawdown: slot.drawdown)
        try h.pendingReplayRepo.saveReplay(slot)   // fake 不解码 → loadReplay 成功返回；decodePosition 才抛
        let e = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
        #expect(e == nil)
        #expect(try h.pendingReplayRepo.loadReplaySlotInfo() == nil)   // 损坏槽已清
    }

    @Test func resumePendingReplay_corruptSlot_clearFails_propagatesKeepsSlot() async throws {
        // codex plan-R12-F1：本记录损坏槽 + 清档失败（瞬态 DB）→ 不吞、传播可重试错误、槽保留（不伪装"无暂存"开 fresh）
        let h = try CoordinatorTestHarness.make()
        try h.pendingReplayRepo.saveReplay(makeSlot(recordId: h.seededRecordId))
        h.pendingReplayRepo.failNextLoadReplay = .persistence(.dbCorrupted)
        h.pendingReplayRepo.failNextClearReplay = .internalError(module: "test", detail: "transient clear")
        await #expect(throws: (any Error).self) {
            _ = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
        }
        #expect(try h.pendingReplayRepo.loadReplaySlotInfo()?.recordId == h.seededRecordId)  // 清失败 → 槽仍在
    }

    @Test func resumePendingReplay_filenameMismatch_clearsAndReturnsNil() async throws {
        // codex plan-R10-F1：pending.recordId 匹配但 trainingSetFilename 与记录不符（stale/corrupt 槽）→ 清 + nil（不拿错文件续局）
        let h = try CoordinatorTestHarness.make()
        let bad = PendingReplay(
            recordId: h.seededRecordId, trainingSetFilename: "WRONG-not-the-record-file.sqlite",
            globalTickIndex: 1, upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(),
            cashBalance: 100_000, feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
        try h.pendingReplayRepo.saveReplay(bad)
        let e = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
        #expect(e == nil)
        #expect(try h.pendingReplayRepo.loadReplay() == nil)   // 损坏槽已清
    }

    @Test func resumePendingReplay_transientLoadFailure_propagates_keepsSlot() async throws {
        let h = try CoordinatorTestHarness.make()
        let e1 = try await h.coordinator.replay(recordId: h.seededRecordId)
        e1.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: e1)
        await h.coordinator.endSession()
        // 注入一次瞬态 loadReplay 失败：resumePendingReplay 须抛（不返 nil、不清档）
        h.pendingReplayRepo.failNextLoadReplay = .internalError(module: "test", detail: "transient")
        await #expect(throws: (any Error).self) {
            _ = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
        }
        // 槽仍在（failNext 已消费，本次 load 成功）
        #expect(try h.pendingReplayRepo.loadReplay() != nil)
    }

    // MARK: - A6: replaySettlementPayload async + fence + conditional clear

    @Test func replayTerminal_fencesAndClears_evenWithQueuedAutosave() async throws {
        let h = try CoordinatorTestHarness.make()
        let e = try await h.coordinator.replay(recordId: h.seededRecordId)
        e.holdOrObserve(panel: .upper)
        h.coordinator.requestAutosave(engine: e, immediate: false)   // 排队一个 autosave
        _ = try await h.coordinator.replaySettlementPayload(engine: e)  // 终局：fence + clear
        await h.coordinator.drainAutosaveForTesting()
        #expect(try h.pendingReplayRepo.loadReplay() == nil)          // 不被排队 autosave 复活
    }

    @Test func discardSession_replay_clears() async throws {
        let h = try CoordinatorTestHarness.make()
        let e = try await h.coordinator.replay(recordId: h.seededRecordId)
        e.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: e)
        try await h.coordinator.discardSession()
        #expect(try h.pendingReplayRepo.loadReplay() == nil)
    }

    @Test func replayTerminal_missingRecordContext_throwsNotSilent() async throws {
        // codex plan-R8-F1：终局缺 activeRecord.id → throw、保留会话（不静默返回 record 而留陈旧槽）
        let h = try CoordinatorTestHarness.make()
        let e = try await h.coordinator.replay(recordId: h.seededRecordId)
        e.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: e)
        h.coordinator.setActiveRecordNilForTesting()   // DEBUG 钩子：制造缺上下文
        await #expect(throws: (any Error).self) {
            _ = try await h.coordinator.replaySettlementPayload(engine: e)
        }
        #expect(try h.pendingReplayRepo.loadReplay() != nil)   // 槽未被静默清
    }

    @Test func replayDiscard_missingRecordContext_throws() async throws {
        let h = try CoordinatorTestHarness.make()
        let e = try await h.coordinator.replay(recordId: h.seededRecordId)
        e.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: e)
        h.coordinator.setActiveRecordNilForTesting()
        await #expect(throws: (any Error).self) {
            try await h.coordinator.discardSession()
        }
        _ = e  // suppress unused warning
    }

    @Test func replayTerminal_conditionalClear_preservesOtherRecordSlot() async throws {
        // codex plan-R3-F1：A 有暂停槽；开新 replay B 未成功保存即到终局 → 条件清不删 A
        let h = try CoordinatorTestHarness.make(seedRecordIds: [1, 2])
        let idA = h.seededRecordId
        let allRecords = try h.recordRepo.listRecords(limit: nil)
        let idB = allRecords.first(where: { $0.id != idA })!.id!

        let eA = try await h.coordinator.replay(recordId: idA)
        eA.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: eA)        // slot = idA
        await h.coordinator.endSession()

        let eB = try await h.coordinator.replay(recordId: idB)  // 开新 B，零操作（slot 仍 = idA）
        _ = try await h.coordinator.replaySettlementPayload(engine: eB)   // B 终局：条件清 ifRecordId=idB → 不动 idA
        let slot = try h.pendingReplayRepo.loadReplay()
        #expect(slot?.recordId == idA)                          // A 的槽仍在
    }

    @Test func replayTerminal_clearFailureAfterPayload_keepsSlot_retryable() async throws {
        // codex plan-R1-F2：清档在 payload 构建成功之后；clearReplay 抛 → 方法抛 + 槽保留（可重试）
        let h = try CoordinatorTestHarness.make()
        let e = try await h.coordinator.replay(recordId: h.seededRecordId)
        e.holdOrObserve(panel: .upper)
        try await h.coordinator.saveProgress(engine: e)
        h.pendingReplayRepo.failNextClearReplay = .internalError(module: "test", detail: "transient clear")
        await #expect(throws: (any Error).self) {
            _ = try await h.coordinator.replaySettlementPayload(engine: e)
        }
        #expect(try h.pendingReplayRepo.loadReplay() != nil)      // 槽保留
        // 重试成功（failNext 已消费）→ 清空
        _ = try await h.coordinator.replaySettlementPayload(engine: e)
        #expect(try h.pendingReplayRepo.loadReplay() == nil)
    }

    @Test func replaySettlementFailure_durableExit_persistsTerminalTickResumable() async throws {
        // codex whole-branch R3-F1：结算失败后「退出本局」(=lifecycle.back()=saveProgress+endSession) 须把终态 durable 落槽，
        // 而非 onSessionEnded(nil)（fence 后 autosave 已死 → 槽留旧检查点 → 续局回旧态/提示落空）。
        //
        // 非真空性：若只调 endSession()（无 saveProgress），fence 已置 terminating → autosave 死，
        // 槽停在 firstTick（旧检查点）；durable exit 加了 saveProgress → 槽升至 currentTick（终态）。
        // 本测试断言 slot.globalTickIndex == currentTick 即验证 saveProgress 的 durable 效果。
        let h = try CoordinatorTestHarness.make()
        let e = try await h.coordinator.replay(recordId: h.seededRecordId)

        // 第一个检查点：advance → saveProgress → slot at firstTick
        e.holdOrObserve(panel: .upper)
        let firstTick = e.tick.globalTickIndex
        try await h.coordinator.saveProgress(engine: e)

        // 再前进一根，形成「终态 currentTick」（fence 后 autosave 不会写这一根）
        e.holdOrObserve(panel: .upper)
        let currentTick = e.tick.globalTickIndex
        #expect(currentTick > firstTick)  // 确认前进有效

        // 结算失败：fenceAndDrainAutosaves（terminating=true）→ clearReplay 抛 → 槽仍在 firstTick
        h.pendingReplayRepo.failNextClearReplay = .internalError(module: "test", detail: "transient")
        await #expect(throws: (any Error).self) {
            _ = try await h.coordinator.replaySettlementPayload(engine: e)
        }

        // 「退出本局」durable exit = saveProgress(当前终态) + endSession
        try await h.coordinator.saveProgress(engine: e)
        await h.coordinator.endSession()

        let slot = try h.pendingReplayRepo.loadReplay()
        #expect(slot != nil)
        #expect(slot?.globalTickIndex == currentTick)  // 可在历史记录「返回训练」续到终态（非旧检查点 firstTick）
    }

    // MARK: - Scalar corruption guard (codex whole-branch R1 HIGH fix)

    @Test func resumePendingReplay_tickBeyondMaxTick_clearsAndReturnsNil() async throws {
        // 训练组 maxTick = seededRecordFinalTick = 7（makeCandles m3Count=8，last endGlobalIndex=7）。
        // 槽 globalTickIndex=8 超出 (0...7) → scalar guard 检出 → clearReplay + nil（永不到 make）。
        let h = try CoordinatorTestHarness.make()
        let outOfRangeTick = h.seededRecordFinalTick + 1   // 8 > maxTick(7)
        let badSlot = PendingReplay(
            recordId: h.seededRecordId,
            trainingSetFilename: "set.sqlite",
            globalTickIndex: outOfRangeTick,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: Data(),
            cashBalance: 100_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], drawings: [],
            startedAt: 1,
            accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
        try h.pendingReplayRepo.saveReplay(badSlot)
        let engine = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
        #expect(engine == nil)
        #expect(try h.pendingReplayRepo.loadReplaySlotInfo() == nil)   // 槽已被 durable 清
    }

    @Test func resumePendingReplay_periodAbsentFromCandleMap_clearsAndReturnsNil() async throws {
        // codex whole-branch R2-F1 HIGH：makeCandles() 仅含 .m3/.m60/.daily/.weekly；
        // .monthly 是合法 Period case 但不在 candle map。
        // 槽 upperPeriod=.monthly → scalar guard（period 校验）检出 → clearReplay + nil（永不到 make）。
        let h = try CoordinatorTestHarness.make()
        let badSlot = PendingReplay(
            recordId: h.seededRecordId,
            trainingSetFilename: "set.sqlite",
            globalTickIndex: 1,           // valid tick（in range 0...7）
            upperPeriod: .monthly,        // absent from candle map → guard fires
            lowerPeriod: .daily,
            positionData: Data(),
            cashBalance: 100_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], drawings: [],
            startedAt: 1,
            accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
        try h.pendingReplayRepo.saveReplay(badSlot)
        let engine = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
        #expect(engine == nil)
        #expect(try h.pendingReplayRepo.loadReplaySlotInfo() == nil)   // 槽已被 durable 清
    }

    @Test func resumePendingReplay_nonFiniteMoney_clearsAndReturnsNil() async throws {
        // 槽 cashBalance=.infinity → scalar guard 检出（isFinite=false）→ clearReplay + nil。
        let h = try CoordinatorTestHarness.make()
        let badSlot = PendingReplay(
            recordId: h.seededRecordId,
            trainingSetFilename: "set.sqlite",
            globalTickIndex: 1,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: Data(),
            cashBalance: .infinity,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], drawings: [],
            startedAt: 1,
            accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
        try h.pendingReplayRepo.saveReplay(badSlot)
        let engine = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
        #expect(engine == nil)
        #expect(try h.pendingReplayRepo.loadReplaySlotInfo() == nil)   // 槽已被 durable 清
    }
}

// MARK: - A5 helper（损坏槽测试用最小 PendingReplay 工厂）

/// 损坏槽测试用最小 PendingReplay 工厂（loadReplay 抛错先于文件名 guard，故 filename 无关）。
@MainActor
private func makeSlot(recordId: Int64, filename: String = "rec.sqlite") -> PendingReplay {
    PendingReplay(recordId: recordId, trainingSetFilename: filename,
        globalTickIndex: 1, upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(),
        cashBalance: 100_000, feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
}
