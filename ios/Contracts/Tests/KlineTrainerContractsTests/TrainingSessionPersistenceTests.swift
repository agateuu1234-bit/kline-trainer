import Testing
import Foundation
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingSessionPersistence")
struct TrainingSessionPersistenceTests {

    // MARK: - 合法 candle fixture（连续 .m3 轴 0..n + m60/daily 非空，过 make 全校验）

    static func validCandles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
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
        return [.m3: m3, .m60: m60, .daily: daily]
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

    static func cachedFile(id: Int = 1, filename: String = "set.sqlite") -> TrainingSetFile {
        TrainingSetFile(id: id, filename: filename,
                        localURL: URL(fileURLWithPath: "/tmp/\(filename)"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    /// 可配置 meta + 记录 close() 的 spy reader（finalize 需控制 loadMeta 返回值）。
    final class MetaSpyReader: TrainingSetReader, @unchecked Sendable {
        let candles: [Period: [KLineCandle]]
        let meta: TrainingSetMeta
        private(set) var closed = false
        init(candles: [Period: [KLineCandle]],
             meta: TrainingSetMeta = TrainingSetMeta(stockCode: "X", stockName: "X",
                                                     startDatetime: 1, endDatetime: 1)) {
            self.candles = candles; self.meta = meta
        }
        func loadMeta() throws -> TrainingSetMeta { meta }
        func loadAllCandles() throws -> [Period: [KLineCandle]] { candles }
        func close() { closed = true }
    }

    /// 注入指定 reader 的 factory（绕过 PreviewTrainingSetDBFactory 的 happy-path）。
    struct StubFactory: TrainingSetDBFactory {
        let reader: TrainingSetReader
        func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader { reader }
    }

    /// PreviewTrainingSetDBFactory + seed 缓存文件 + 指定起始本金 的 happy-path coordinator。
    static func makeCoordinator(
        candles: [Period: [KLineCandle]],
        capital: Double = 50_000,
        seedFile: TrainingSetFile? = cachedFile()
    ) -> (TrainingSessionCoordinator, InMemoryRecordRepository, InMemoryPendingTrainingRepository, InMemorySessionFinalizationPort) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let cache = InMemoryCacheManager()
        if let f = seedFile { cache._seedForTesting([f]) }
        let coord = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: candles),
            recordRepo: records,
            pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            // A4：settingsDAO 与 SettingsStore 同源（mirror 生产同一 DefaultAppDB）——startingCapital 直读 DAO。
            settingsDAO: CapitalDAO(capital: capital),
            cache: cache,
            settings: SettingsStore(settingsDAO: CapitalDAO(capital: capital)))
        return (coord, records, pending, port)
    }

    @Test("endSession: 关闭 reader + 清空 active 状态（D10）")
    func endSession_closesReaderClearsActive() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        _ = try await coord.startNewNormalSession()
        #expect(coord.activeReader != nil)
        #expect(coord.activeEngine != nil)
        await coord.endSession()
        #expect(coord.activeReader == nil)
        #expect(coord.activeEngine == nil)
    }

    @Test("endSession: never-started → 安全 no-op（不崩）")
    func endSession_neverStarted_noop() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        await coord.endSession()     // 全 nil，不崩
        #expect(coord.activeReader == nil)
        #expect(coord.activeEngine == nil)
    }

    @Test("endSession: 真关闭注入 reader（spy.closed == true）")
    func endSession_closesInjectedReader() async throws {
        let spy = Self.MetaSpyReader(candles: Self.validCandles())
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records,
            pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: InMemorySessionFinalizationPort(records: records, pending: pending),
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        _ = try await coord.startNewNormalSession()
        await coord.endSession()
        #expect(spy.closed == true)
    }

    @Test("saveProgress: Normal 局 → 持久化 PendingTraining 全字段（含 startedAt=now()、accumulated=起始资金）")
    func saveProgress_normal_persistsAllFields() async throws {
        let (coord, _, pending, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        coord.now = { 111 }                                  // 控制 startedAt
        coord.makeSessionKey = { "fixed-key" }               // 控制 sessionKey（RFC §4.7c）
        let engine = try await coord.startNewNormalSession()  // fresh：tick 0、空仓、cash 50000
        try await coord.saveProgress(engine: engine)
        let p = try #require(try pending.loadPending())
        #expect(p.trainingSetFilename == "set.sqlite")        // D4：activeFile.filename
        #expect(p.globalTickIndex == 0)
        #expect(p.upperPeriod == .m60)
        #expect(p.lowerPeriod == .daily)
        #expect(p.cashBalance == 50_000)
        #expect(p.accumulatedCapital == 50_000)               // D4：engine.initialCapital
        #expect(p.startedAt == 111)                            // D4/D5：fresh=now() at start
        #expect(p.sessionKey == "fixed-key")                  // RFC §4.7c：sessionKey 落 pending
        #expect(p.tradeOperations.isEmpty)
        #expect(p.drawings.isEmpty)
        #expect(p.feeSnapshot == FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false))  // 自 settings 快照
        #expect(p.drawdown == DrawdownAccumulator(peakCapital: 50_000, maxDrawdown: 0))  // fresh：peak=起始总资金 seed
        // positionData 可解回空仓（D9 encode 往返）
        let pos = try JSONDecoder().decode(PositionManager.self, from: p.positionData)
        #expect(pos.shares == 0)
    }

    @Test("saveProgress: review 模式 → no-op（不写 pending，D3）")
    func saveProgress_review_noop() async throws {
        let (coord, records, pending, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let engine = try await coord.review(recordId: id)
        try await coord.saveProgress(engine: engine)
        #expect(try pending.loadPending() == nil)             // review 不持久化
    }

    @Test("saveProgress: replay 模式 → no-op（不写 pending，D3）")
    func saveProgress_replay_noop() async throws {
        let (coord, records, pending, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 80_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let engine = try await coord.replay(recordId: id)
        try await coord.saveProgress(engine: engine)
        #expect(try pending.loadPending() == nil)
    }

    @Test("RFC-B：activeRecord 在 review 后 = record，normal 后 = nil")
    func activeRecord_setAfterReview_nilAfterNormal() async throws {
        let (coord, records, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "600000", stockName: "测试股", startYear: 2020, startMonth: 1,
                           totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        _ = try await coord.review(recordId: id)
        #expect(coord.activeRecord?.stockName == "测试股")
        #expect(coord.activeRecord?.stockCode == "600000")
        await coord.endSession()                          // R2-M：teardown 清 activeRecord
        #expect(coord.activeRecord == nil)                // 结束后无 stale 名
        _ = try await coord.startNewNormalSession()        // 无参；盲测仍 nil
        #expect(coord.activeRecord == nil)
    }

    @Test("saveProgress: 缺活跃上下文（endSession 后）→ .internalError（D9）")
    func saveProgress_noActiveContext_throws() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.startNewNormalSession()
        await coord.endSession()                               // 清空 activeFile/activeStartedAt
        await #expect(throws: AppError.internalError(module: "E6b",
                      detail: "saveProgress without active session context")) {
            try await coord.saveProgress(engine: engine)
        }
    }

    @Test("saveProgress → resumePending round-trip：状态还原一致（D4 跨方法集成）")
    func saveProgress_thenResume_roundTrips() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        coord.now = { 222 }
        let engine = try await coord.startNewNormalSession()
        try await coord.saveProgress(engine: engine)
        await coord.endSession()
        let resumed = try #require(try await coord.resumePending())
        #expect(resumed.tick.globalTickIndex == 0)
        #expect(resumed.cashBalance == 50_000)
        #expect(resumed.initialCapital == 50_000)
        #expect(resumed.position.shares == 0)
        #expect(resumed.upperPanel.period == .m60)
        #expect(resumed.lowerPanel.period == .daily)
    }

    // MARK: - 纯函数单元（D6/D7/D11）

    @Test("drawdownRatio: peak<=0 → 0（无有效峰值）")
    func drawdownRatio_zeroPeak_returnsZero() {
        #expect(TrainingSessionCoordinator.drawdownRatio(absolute: 0, peak: 0) == 0)
        #expect(TrainingSessionCoordinator.drawdownRatio(absolute: 100, peak: 0) == 0)
        #expect(TrainingSessionCoordinator.drawdownRatio(absolute: 0, peak: -5) == 0)
    }

    @Test("drawdownRatio: 绝对额(元)→负比率 = -(abs/peak)")
    func drawdownRatio_normal_negativeRatio() {
        #expect(abs(TrainingSessionCoordinator.drawdownRatio(absolute: 8930, peak: 100_000) - (-0.0893)) < 1e-12)
        #expect(abs(TrainingSessionCoordinator.drawdownRatio(absolute: 12_000, peak: 100_000) - (-0.12)) < 1e-12)
    }

    @Test("drawdownRatio: 零回撤 → 0（无亏损）")
    func drawdownRatio_zeroDrawdown_returnsZero() {
        #expect(TrainingSessionCoordinator.drawdownRatio(absolute: 0, peak: 100_000) == 0)
    }

    @Test("startYearMonth: 普通时刻按 UTC+8 取年/月")
    func startYearMonth_normal() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let epoch = Int64(cal.date(from: DateComponents(year: 2021, month: 8, day: 15, hour: 12))!
                            .timeIntervalSince1970)
        let (y, m) = TrainingSessionCoordinator.startYearMonth(from: epoch)
        #expect(y == 2021)
        #expect(m == 8)
    }

    @Test("startYearMonth: 用 UTC+8 而非 UTC（跨月边界 killer）")
    func startYearMonth_usesBeijingTZ_notUTC() {
        // 2021-08-01 02:00 北京时 == 2021-07-31 18:00 UTC：UTC+8→8月，误用 UTC→7月。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let epoch = Int64(cal.date(from: DateComponents(year: 2021, month: 8, day: 1, hour: 2))!
                            .timeIntervalSince1970)
        let (y, m) = TrainingSessionCoordinator.startYearMonth(from: epoch)
        #expect(y == 2021)
        #expect(m == 8)               // 误用 UTC 会得 7 → 测试失败
    }

    @Test("startYearMonth: 年初边界（跨年）按 UTC+8")
    func startYearMonth_yearBoundary() {
        // 2022-01-01 01:00 北京时 == 2021-12-31 17:00 UTC：UTC+8→2022/1，误用 UTC→2021/12。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let epoch = Int64(cal.date(from: DateComponents(year: 2022, month: 1, day: 1, hour: 1))!
                            .timeIntervalSince1970)
        let (y, m) = TrainingSessionCoordinator.startYearMonth(from: epoch)
        #expect(y == 2022)
        #expect(m == 1)
    }

    // MARK: - Task 4: finalize 集成测试

    /// 构造一个确定性 pending：**stored** drawdown abs=5000/peak=100000；resume 后 tick=7、price=10.7、
    /// cash=90000、shares=100、accumulated=100000 → currentTotal=91070、profit=-8930。engine.init 的
    /// seededDrawdown.update(91070) 因 peak(100000)-currentTotal(91070)=8930>5000 → maxDrawdown 提升到 8930。
    static func deterministicPending() throws -> PendingTraining {
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        return try PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 7,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: true),
            tradeOperations: [
                TradeOperation(globalTick: 2, period: .m3, direction: .buy, price: 10.2, shares: 100,
                               positionTier: .tier1, commission: 1, stampDuty: 0, totalCost: 1020, createdAt: 0),
                TradeOperation(globalTick: 5, period: .m3, direction: .sell, price: 10.5, shares: 100,
                               positionTier: .tier1, commission: 1, stampDuty: 1, totalCost: 1048, createdAt: 0)
            ],
            drawings: [], startedAt: 1,
            accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 5_000),
            sessionKey: "SK-test")
    }

    /// resume 路径 coordinator（StubFactory + MetaSpyReader 控制 meta；pending 注入）。
    static func resumeCoordinator(
        meta: TrainingSetMeta
    ) throws -> (TrainingSessionCoordinator, InMemoryRecordRepository, InMemoryPendingTrainingRepository, MetaSpyReader) {
        let spy = MetaSpyReader(candles: validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        try pending.savePending(try deterministicPending())
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: CapitalDAO(capital: 10_000)))
        return (coord, records, pending, spy)
    }

    @Test("finalize: Normal 入账 record 全字段（total=起始≠结束 killer / profit / 回撤比率 / 买卖次数 / 年月 / 清 pending）")
    func finalize_normal_insertsRecordCorrectly() async throws {
        // startDatetime = 2021-08-15 12:00 北京时
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let startEpoch = Int64(cal.date(from: DateComponents(year: 2021, month: 8, day: 15, hour: 12))!
                                .timeIntervalSince1970)
        let meta = TrainingSetMeta(stockCode: "600519", stockName: "贵州茅台",
                                   startDatetime: startEpoch, endDatetime: startEpoch + 1)
        let (coord, records, pending, _) = try Self.resumeCoordinator(meta: meta)
        coord.now = { 1_700_000_000 }
        let engine = try #require(try await coord.resumePending())   // tick 7, shares 100
        let id = try #require(try await coord.finalize(engine: engine))

        let (rec, ops, _) = try records.loadRecordBundle(id: id)
        #expect(rec.totalCapital == 100_000)                          // D1 方案 A：起始资金
        #expect(rec.totalCapital != 91_070)                           // killer：非结束总资金
        #expect(abs(rec.profit - (-8_930)) < 1e-6)                    // 91070 - 100000（容差，FP）
        #expect(abs(rec.returnRate - (-0.0893)) < 1e-9)              // profit/起始
        #expect(abs(rec.maxDrawdown - (-0.0893)) < 1e-9)            // -(8930/100000)，D6
        #expect(rec.buyCount == 1)                                    // D8
        #expect(rec.sellCount == 1)
        #expect(rec.stockCode == "600519")
        #expect(rec.stockName == "贵州茅台")
        #expect(rec.startYear == 2021)                                // D7 UTC+8
        #expect(rec.startMonth == 8)
        #expect(rec.createdAt == 1_700_000_000)                       // D5 now()
        #expect(rec.finalTick == 7)
        #expect(rec.trainingSetFilename == "set.sqlite")
        #expect(rec.feeSnapshot.commissionRate == 0.0002)
        #expect(ops.count == 2)                                       // ops 一并入账
        #expect(try pending.loadPending() == nil)                    // D2：清 pending
    }

    /// 注入固定 (id, totalCapital) 的 finalization stub（验 coordinator 刷缓存用**返回值**非 engine 现值）。
    struct StubFinalization: SessionFinalizationPort {
        let fixed: (id: Int64, totalCapital: Double)
        func finalizeSession(record: TrainingRecord, ops: [TradeOperation],
                             drawings: [DrawingObject], sessionKey: String)
            throws -> (id: Int64, totalCapital: Double) { fixed }
    }

    // codex R-plan-5-1：coordinator 刷缓存用 finalizeSession **返回的权威值**，非 engine 现值。
    @Test("finalize: 活缓存刷为返回的权威值（777_000），非 engine.currentTotalCapital")
    func test_finalize_refreshes_cache_from_returned_authority_not_engine() async throws {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let injectedStore = SettingsStore(settingsDAO: Self.CapitalDAO(capital: 50_000))   // engine 现值=50_000
        let coord = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: Self.validCandles()),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: StubFinalization(fixed: (1, 777_000)),   // 刻意 ≠ engine.currentTotalCapital
            settingsDAO: Self.CapitalDAO(capital: 50_000),
            cache: cache, settings: injectedStore)
        let engine = try await coord.startNewNormalSession()
        #expect(engine.currentTotalCapital == 50_000)                       // engine 现值 ≠ 777_000
        _ = try await coord.finalize(engine: engine)
        #expect(abs(injectedStore.settings.totalCapital - 777_000) < 1e-6)  // 活缓存 == 返回值（非 engine 现值）
    }

    @Test("finalize: review 模式 → nil（不插记录、不动 pending，D2）")
    func finalize_review_returnsNil() async throws {
        let (coord, records, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let countBefore = try records.listRecords(limit: nil).count
        let engine = try await coord.review(recordId: id)
        let result = try await coord.finalize(engine: engine)
        #expect(result == nil)
        #expect(try records.listRecords(limit: nil).count == countBefore)   // 未新增记录
    }

    @Test("finalize: replay 模式 → nil（不入账，D2）")
    func finalize_replay_returnsNil() async throws {
        let (coord, records, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 80_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let countBefore = try records.listRecords(limit: nil).count
        let engine = try await coord.replay(recordId: id)
        let result = try await coord.finalize(engine: engine)
        #expect(result == nil)
        #expect(try records.listRecords(limit: nil).count == countBefore)
    }

    @Test("finalize: Normal 但缺活跃上下文（endSession 后）→ .internalError（D9）")
    func finalize_noActiveContext_throws() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.startNewNormalSession()
        await coord.endSession()
        await #expect(throws: AppError.internalError(module: "E6b",
                      detail: "finalize without active session context")) {
            _ = try await coord.finalize(engine: engine)
        }
    }

    @Test("finalize: 局终自动强平产生的 sell 计入 sellCount（D8 覆盖）")
    func finalize_forceCloseSell_countedInSellCount() async throws {
        // resume 在 tick 3 持仓 100；holdOrObserve(.upper) 走 m60 步进 3→7（maxTick）→ 触发局终强平卖出。
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        let spy = Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        try pending.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], drawings: [], startedAt: 1,
            accumulatedCapital: 100_000, drawdown: .initial,
            sessionKey: "SK-test"))
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        #expect(engine.tick.globalTickIndex == 3)
        engine.holdOrObserve(panel: .upper)              // 3 → 7（m60 步进）→ 局终强平 100 股
        #expect(engine.tick.globalTickIndex == 7)
        #expect(engine.position.shares == 0)             // 强平后空仓
        let id = try #require(try await coord.finalize(engine: engine))
        let (rec, _, _) = try records.loadRecordBundle(id: id)
        #expect(rec.sellCount == 1)                       // 仅强平 1 笔 sell（pending ops 为空，D8）
        #expect(rec.buyCount == 0)
        #expect(rec.finalTick == 7)
    }

    // MARK: - codex whole-branch R4 finding 2：finalize 遇 resume 存活的 unknownRaw → fail-closed，不清 pending

    /// resume 一条仍带 unknownRaw（未来客户端画的线）的 pending → finalize 须 fail-closed 拒绝：
    /// 永久 `drawings` 表按行结构化，无法携带原始未识别字节，若照常 finalize 会把这些条随 pending
    /// 一起永久丢弃且不可逆。抛可恢复错误 + pending 槽不被清空（数据仍在磁盘，未来版本 app 可续 finalize）。
    @Test("finalize: resume 的 pending 仍带 unknownRaw → 抛 .persistence(.dbCorrupted)，pending 不被清空（codex WB R4 finding 2）")
    func finalize_unknownRawStillPresent_throwsAndPreservesPending() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 1)
        let spy = Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let knownDrawing = DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        // 已知条 + 一条未来 toolType（未识别）——mirror CoordinatorLossyPreserveTests 的 `unknown` fixture。
        let lossy = LossyDrawingArray(elements: try LossyDrawingArray(drawings: [knownDrawing]).elements
                                      + [.unknownRaw(#"{"toolType":"__future__","z":1.0}"#)])
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        try pending.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], lossy: lossy, startedAt: 1,
            accumulatedCapital: 100_000, drawdown: .initial,
            sessionKey: "SK-unknown-raw"))
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try await coord.finalize(engine: engine)
        }
        #expect(try pending.loadPending() != nil)   // pending 未被清空（unknownRaw 数据仍在磁盘）
        #expect(port.finalizeCallCount == 0)         // 从未到达 finalization port（未清 record/pending）
    }

    /// 对照组：resume 的 pending 仅含已知画线（无 unknownRaw）→ finalize 照常成功、pending 正常清空。
    @Test("finalize: resume 的 pending 仅含已知画线 → 正常成功、pending 清空（control，codex WB R4 finding 2）")
    func finalize_onlyKnownDrawings_succeedsNormally() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 1)
        let spy = Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let knownDrawing = DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        try pending.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], drawings: [knownDrawing], startedAt: 1,
            accumulatedCapital: 100_000, drawdown: .initial,
            sessionKey: "SK-known-only"))
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        let id = try #require(try await coord.finalize(engine: engine))
        let (_, _, drawings) = try records.loadRecordBundle(id: id)
        #expect(drawings == [knownDrawing])
        #expect(try pending.loadPending() == nil)   // 正常清空
        #expect(port.finalizeCallCount == 1)
    }

    // MARK: - codex whole-branch R9 finding 1：finalize 遇 known drawing 未来字段 → fail-closed，不清 pending

    /// resume 一条【已知 toolType，但携带未来客户端加的额外字段】的 pending（无 unknownRaw）→ finalize 须
    /// fail-closed 拒绝：finalize 只把 `engine.drawings`（已知投影）交给 `finalizeSession` 的表结构持久化，
    /// 这条未来字段（`futureField`）无法随之存活——若照常 finalize 会随 pending 一起永久丢弃且不可逆（同
    /// unknownRaw 的道理，但此前的门只查 `unknownRaw`，漏了这类"已知条身上的未来字段"）。
    @Test("finalize: resume 的 pending 已知条携带未来字段（无 unknownRaw）→ 抛 .persistence(.dbCorrupted)，pending 不被清空（codex WB R9 finding 1）")
    func finalize_knownDrawingHasFutureField_throwsAndPreservesPending() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 1)
        let spy = Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let knownDrawing = DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        // 已知条的 raw 携带一个当前 schema 不认识的未来字段（mirror CoordinatorLossyPreserveTests 的
        // `knownFuture` fixture手法）——DrawingObject 解码成功（`futureField` 被 JSONDecoder 忽略），
        // 但字节仍在 raw 里。
        let encoded = try LossyDrawingArray.encodeKnown(knownDrawing)
        let futureRaw = String(encoded.dropLast()) + #","futureField":1}"#
        let lossy = LossyDrawingArray(elements: [.known(knownDrawing, raw: futureRaw)])
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        try pending.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], lossy: lossy, startedAt: 1,
            accumulatedCapital: 100_000, drawdown: .initial,
            sessionKey: "SK-known-future"))
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try await coord.finalize(engine: engine)
        }
        #expect(try pending.loadPending() != nil)   // pending 未被清空（未来字段数据仍在磁盘）
        #expect(port.finalizeCallCount == 0)         // 从未到达 finalization port（未清 record/pending）
    }

    // MARK: - codex whole-branch R10 finding 1：用户删除携带未来字段的画线后，finalize 门不应再误 brick

    /// resume 一条携带未来字段的已知 drawing 的 pending 后，用户把这条画线【删除】（`engine.drawings`
    /// 不再含它，只有从不更新的 `loadedDrawingsLossy` 加载快照还留着）——finalize 此时已不会丢失任何数据
    /// （未来字段随用户的删除意愿一起不再需要保留），门须按【存活】画线 id 过滤未来字段判定，不应再
    /// fail-closed 永久卡死用户。
    @Test("finalize: 携带未来字段的已知 drawing 被用户删除后 → 门不再拦，finalize 成功且清空 pending（codex WB R10 finding 1）")
    func finalize_knownDrawingFutureFieldDeletedByUser_succeeds() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 1)
        let spy = Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let knownDrawing = DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let encoded = try LossyDrawingArray.encodeKnown(knownDrawing)
        let futureRaw = String(encoded.dropLast()) + #","futureField":1}"#
        let lossy = LossyDrawingArray(elements: [.known(knownDrawing, raw: futureRaw)])
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        try pending.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], lossy: lossy, startedAt: 1,
            accumulatedCapital: 100_000, drawdown: .initial,
            sessionKey: "SK-known-future-deleted"))
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        #expect(engine.drawings.count == 1)
        engine.deleteDrawing(at: 0)                       // 用户删除这条携带未来字段的画线
        #expect(engine.drawings.isEmpty)
        let id = try #require(try await coord.finalize(engine: engine))
        let (_, _, drawings) = try records.loadRecordBundle(id: id)
        #expect(drawings.isEmpty)                         // 删除后无 drawing 入账
        #expect(try pending.loadPending() == nil)         // 正常清空
        #expect(port.finalizeCallCount == 1)
    }

    // MARK: - codex whole-branch R18：finalize 遇 known drawing 未来枚举值（已知 key）→ fail-closed，不清 pending

    /// resume 一条【已知 toolType，raw 里某已知枚举 key（colorToken）携带当前版本不认识的未来值】的 pending
    /// （无 unknownRaw、也无未来 EXTRA key）→ finalize 须 fail-closed 拒绝：R16 让 `.known` 对这类值容错
    /// 解码（colorToken fallback 成 `.orange`），但 finalize 只把 `engine.drawings`（fallback 后的已知
    /// 投影）交给 `finalizeSession` 的表结构持久化——原始未来值（"futureNeon"）不在其中，若照常 finalize
    /// 会随 pending 一起永久丢弃且不可逆。此前的门（`hasKnownFutureFields`/`unknownRaw`）都看不到这类
    /// 「已知 key 自身的未来值」，故须新增 `hasKnownFutureEnumValues` 判定。
    @Test("finalize: resume 的 pending 已知条携带未来枚举值（colorToken，无 unknownRaw/无未来 EXTRA key）→ 抛 .persistence(.dbCorrupted)，pending 不被清空（codex WB R18，红→绿）")
    func finalize_knownDrawingHasFutureEnumValue_throwsAndPreservesPending() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 1)
        let spy = Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let raw = #"{"id":"g1","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"colorToken":"futureNeon"}"#
        let knownDrawing = try JSONDecoder().decode(DrawingObject.self, from: Data(raw.utf8))
        #expect(knownDrawing.colorToken == .orange)   // 前置：确实 fallback（R16），非 unknownRaw/非未来 EXTRA key
        let lossy = LossyDrawingArray(elements: [.known(knownDrawing, raw: raw)])
        #expect(lossy.unknownRaw.isEmpty)
        #expect(lossy.hasKnownFutureFields(liveIds: [knownDrawing.id]) == false)   // 旧门看不到（证明 R18 缺口）
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        try pending.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], lossy: lossy, startedAt: 1,
            accumulatedCapital: 100_000, drawdown: .initial,
            sessionKey: "SK-known-future-enum"))
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try await coord.finalize(engine: engine)
        }
        #expect(try pending.loadPending() != nil)   // pending 未被清空（未来枚举值数据仍在磁盘）
        #expect(port.finalizeCallCount == 0)         // 从未到达 finalization port（未清 record/pending）
    }

    /// 对照组：用户把携带未来枚举值的已知 drawing 删除后（`engine.drawings` 不再含它，只有从不更新的
    /// `loadedDrawingsLossy` 加载快照还留着）——finalize 此时已不会丢失任何数据（未来值随删除意愿一起
    /// 不再需要保留），门须按存活画线 id 过滤，不应再 fail-closed 卡死用户（同 R10 finding 1 先例）。
    @Test("对照：携带未来枚举值的已知 drawing 被用户删除后 → 门不再拦，finalize 成功且清空 pending（codex WB R18）")
    func finalize_knownDrawingFutureEnumValueDeletedByUser_succeeds() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 1)
        let spy = Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let raw = #"{"id":"g1","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"colorToken":"futureNeon"}"#
        let knownDrawing = try JSONDecoder().decode(DrawingObject.self, from: Data(raw.utf8))
        let lossy = LossyDrawingArray(elements: [.known(knownDrawing, raw: raw)])
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        try pending.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], lossy: lossy, startedAt: 1,
            accumulatedCapital: 100_000, drawdown: .initial,
            sessionKey: "SK-known-future-enum-deleted"))
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        #expect(engine.drawings.count == 1)
        engine.deleteDrawing(at: 0)                       // 用户删除这条携带未来枚举值的画线
        #expect(engine.drawings.isEmpty)
        let id = try #require(try await coord.finalize(engine: engine))
        let (_, _, drawings) = try records.loadRecordBundle(id: id)
        #expect(drawings.isEmpty)                         // 删除后无 drawing 入账
        #expect(try pending.loadPending() == nil)         // 正常清空
        #expect(port.finalizeCallCount == 1)
    }

    @Test("finalize/saveProgress: 传入非活跃 engine → .internalError（engine 身份守门，final-review L2 加固）")
    func finalizeSaveProgress_foreignEngine_throws() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        _ = try await coord.startNewNormalSession()         // activeEngine = 本 session 引擎
        let foreign = TrainingEngine.preview()              // 不同实例，normal 模式（过 mode/shouldSaveRecord 首守门）
        await #expect(throws: AppError.internalError(module: "E6b",
                      detail: "finalize without active session context")) {
            _ = try await coord.finalize(engine: foreign)
        }
        await #expect(throws: AppError.internalError(module: "E6b",
                      detail: "saveProgress without active session context")) {
            try await coord.saveProgress(engine: foreign)
        }
    }

    // MARK: - A4 Step 3d：pending cashBalance 边界 floor（崩溃恢复防 brick）

    /// 全 0.01 低价 candle（强平 100 股 → notional 1，最低佣金 5 → proceeds 负 → cash 转负）。
    static func lowPriceCandles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int) -> KLineCandle {
            KLineCandle(period: p, datetime: 1 + Int64(gi) * 180, open: 0.01, high: 0.01, low: 0.01,
                        close: 0.01, volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: gi, endGlobalIndex: egi)
        }
        let m3 = (0..<m3Count).map { c(.m3, gi: $0, egi: $0) }
        let last = m3Count - 1
        let m60 = [c(.m60, gi: 0, egi: last / 2), c(.m60, gi: last / 2 + 1, egi: last)]
        let daily = [c(.daily, gi: 0, egi: last)]
        return [.m3: m3, .m60: m60, .daily: daily]
    }

    /// resume 路径 coordinator：低价 100 股持仓 + 小额现金 3（起始本金 3）→ 推进 maxTick 强平产负现金。
    static func negativeCashCoordinator()
        throws -> (TrainingSessionCoordinator, InMemoryRecordRepository, InMemoryPendingTrainingRepository) {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        let spy = MetaSpyReader(candles: lowPriceCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let pos = PositionManager(shares: 100, averageCost: 0.01, totalInvested: 1.0)
        try pending.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 3,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            tradeOperations: [], drawings: [], startedAt: 1,
            accumulatedCapital: 3, drawdown: .initial, sessionKey: "kNeg"))
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: StubFactory(reader: spy), recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port, settingsDAO: CapitalDAO(capital: 3),
            cache: cache, settings: SettingsStore(settingsDAO: CapitalDAO(capital: 3)))
        return (coord, records, pending)
    }

    // codex R-plan-18-2/25-1：saveProgress floor max(0,cash)；崩溃恢复局记 floored P&L，正常 finalize 如实记负。
    @Test("Step 3d: pending cash floor + 崩溃恢复记 floored P&L vs 正常 finalize 如实记负")
    func test_pending_cash_floor_recovery_vs_normal_finalize() async throws {
        // ③ 正常 finalize（无崩溃）：直接对负现金引擎 finalize → 记录**如实**负 profit。
        let (coordA, recordsA, _) = try Self.negativeCashCoordinator()
        let engineA = try #require(try await coordA.resumePending())   // cash 3, shares 100, tick 3
        engineA.holdOrObserve(panel: .upper)                            // → maxTick 强平 → cash 转负
        #expect(engineA.cashBalance < 0)
        let kNeg = engineA.cashBalance                                  // 真实负现金（= currentTotalCapital，已空仓）
        let idA = try #require(try await coordA.finalize(engine: engineA))
        let (recA, _, _) = try recordsA.loadRecordBundle(id: idA)
        #expect(abs(recA.profit - (kNeg - 3)) < 1e-6)                   // 如实记负：currentTotalCapital - 起始 3

        // ①② 崩溃恢复：saveProgress floor cash → resume 不 brick → 恢复后 finalize 记 floored 终值。
        let (coordB, recordsB, pendingB) = try Self.negativeCashCoordinator()
        let engineB = try #require(try await coordB.resumePending())
        engineB.holdOrObserve(panel: .upper)                            // 强平 → cash 负
        #expect(engineB.cashBalance < 0)
        try await coordB.saveProgress(engine: engineB)                  // autosave 落盘负现金局
        let saved = try #require(try pendingB.loadPending())
        #expect(saved.cashBalance == 0)                                 // ① floor max(0,cash)
        await coordB.endSession()                                       // 模拟重启
        let resumed = try #require(try await coordB.resumePending())    // ① 不抛 = 不 brick（cash 0 ≥ 0）
        #expect(resumed.cashBalance == 0)
        let idB = try #require(try await coordB.finalize(engine: resumed))
        let (recB, _, _) = try recordsB.loadRecordBundle(id: idB)
        #expect(abs(recB.profit - (0 - 3)) < 1e-6)                      // ② floored P&L（0 - 起始 3），非真实 kNeg-3
    }

    // MARK: - Wave 3 顺位 6b：appendDrawing 进入持久化路径

    @Test("appendDrawing: 追加的画线经 saveProgress 落 pending.drawings（§4.4c 单一真相→持久化）")
    func appendDrawing_flowsIntoPendingPersistence() async throws {
        let (coord, _, pending, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        coord.now = { 222 }
        let engine = try await coord.startNewNormalSession()
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.4)],
                              isExtended: false, panelPosition: 0)
        engine.appendDrawing(d)
        try await coord.saveProgress(engine: engine)
        let p = try #require(try pending.loadPending())
        #expect(p.drawings == [d])                   // engine.drawings → pending.drawings 单一真相
    }

    // MARK: - Wave 3 顺位 6b：replaySettlementPayload（RFC §4.4e 非持久化 replay 结算 payload）

    /// 建一个活跃 replay 会话（seed 源 record + 注入可控 meta 的 reader），返回 (coord, engine, records, pending)。
    static func makeReplaySession(
        capital: Double = 100_000,
        meta: TrainingSetMeta = TrainingSetMeta(stockCode: "600000", stockName: "测试股",
                                                startDatetime: 1, endDatetime: 1_583_100_000)
    ) async throws -> (TrainingSessionCoordinator, TrainingEngine,
                       InMemoryRecordRepository, InMemoryPendingTrainingRepository) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile(filename: "set.sqlite")])
        let src = TrainingRecord(
            id: nil, trainingSetFilename: "set.sqlite", createdAt: 0,
            stockCode: "ignored", stockName: "ignored", startYear: 2000, startMonth: 1,
            totalCapital: capital, profit: 0, returnRate: 0, maxDrawdown: 0,
            buyCount: 0, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), finalTick: 7)
        let srcId = try records.insertRecord(src, ops: [], drawings: [])
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: InMemorySessionFinalizationPort(records: records, pending: pending),
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: capital)))
        let engine = try await coord.replay(recordId: srcId)
        return (coord, engine, records, pending)
    }

    @Test("replaySettlementPayload: 强平后终态 → in-memory TrainingRecord（原局 fees + meta）")
    func replaySettlementPayload_returnsTerminalStateRecord() async throws {
        let (coord, engine, _, _) = try await Self.makeReplaySession(capital: 100_000)
        _ = engine.buy(panel: .upper, shares: 2000)      // replay 可交易；建非平凡终态
        engine.forceCloseManually()                       // 6a：强平 → 持仓平
        #expect(engine.position.shares == 0)
        let payload = try await coord.replaySettlementPayload(engine: engine)
        #expect(payload.id == nil)                                       // 非持久（无 server id）
        #expect(payload.totalCapital == engine.initialCapital)          // D1 方案 A：起始资金
        #expect(payload.profit == engine.currentTotalCapital - engine.initialCapital)
        #expect(payload.returnRate == engine.returnRate)
        #expect(payload.feeSnapshot == engine.fees)                      // 原局 FeeSnapshot
        #expect(payload.stockCode == "600000")                          // 来自 reader.loadMeta()
        #expect(payload.stockName == "测试股")
        #expect(payload.finalTick == 3)                                 // buy@tick0 → m60 步进 3 → tick3（非自指）
        #expect(payload.buyCount == 1)                                  // 1 笔买入
        #expect(payload.sellCount == 1)                                 // forceCloseManually 的 1 笔强平卖出
    }

    @Test("replaySettlementPayload: 非持久化不变量 —— 不写 record、不触 pending，DB 不变")
    func replaySettlementPayload_doesNotPersist() async throws {
        let (coord, engine, records, pending) = try await Self.makeReplaySession()
        let recordsBefore = try records.listRecords(limit: nil).count   // = 1（仅 seed 的源 record）
        _ = engine.buy(panel: .upper, shares: 2000)
        engine.forceCloseManually()
        _ = try await coord.replaySettlementPayload(engine: engine)
        #expect(try records.listRecords(limit: nil).count == recordsBefore)   // 无新 insert
        #expect(try pending.loadPending() == nil)                             // pending 不动
        // finalize 对 replay 仍返 nil（持久化路径不变）
        #expect(try await coord.finalize(engine: engine) == nil)
        #expect(try records.listRecords(limit: nil).count == recordsBefore)   // finalize 也未插
    }

    @Test("replaySettlementPayload: 非 replay 模式 → throws（caller-contract 守卫）")
    func replaySettlementPayload_throwsInNonReplayMode() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        let engine = try await coord.startNewNormalSession()   // .normal
        await #expect(throws: AppError.self) {
            _ = try await coord.replaySettlementPayload(engine: engine)
        }
    }

    @Test("replaySettlementPayload: 无活跃会话 / engine 身份不符 → throws")
    func replaySettlementPayload_throwsWithoutActiveSession() async throws {
        let (coord, engine, _, _) = try await Self.makeReplaySession()
        await coord.endSession()                               // 清活跃上下文
        await #expect(throws: AppError.self) {
            _ = try await coord.replaySettlementPayload(engine: engine)
        }
    }

    @Test("E2E（顺位 4）: 画线 → saveProgress → endSession → resume：engine.drawings 逐字段还原")
    func drawing_saveProgress_thenResume_restoresDrawings() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        coord.now = { 222 }
        let engine = try await coord.startNewNormalSession()
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m60, candleIndex: 3, price: 10.55)],
                              isExtended: true, panelPosition: 0)
        engine.appendDrawing(d)
        try await coord.saveProgress(engine: engine)
        await coord.endSession()
        let resumed = try #require(try await coord.resumePending())
        #expect(resumed.drawings == [d])              // resume 经 initialDrawings 逐字段还原画线
    }

    // MARK: - Wave 3 顺位 10a：sessionKey 生命周期 + finalize 单事务 + 幂等（RFC §4.7a/b/c）

    @Test("sessionKey 生命周期：fresh Normal → activeSessionKey 非空；endSession → nil")
    func sessionKey_lifecycle_fresh_normal() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        coord.makeSessionKey = { "K1" }
        #expect(coord.activeSessionKey == nil)                 // 初始为 nil
        _ = try await coord.startNewNormalSession()
        #expect(coord.activeSessionKey == "K1")               // fresh 后已设置
        await coord.endSession()
        #expect(coord.activeSessionKey == nil)                 // endSession 清空
    }

    @Test("sessionKey 生命周期：resume → activeSessionKey == pending.sessionKey")
    func sessionKey_lifecycle_resume_restores() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        let (coord, _, _, _) = try Self.resumeCoordinator(meta: meta)
        _ = try await coord.resumePending()
        #expect(coord.activeSessionKey == "SK-test")          // deterministicPending 内 sessionKey
    }

    @Test("sessionKey 生命周期：review/replay → activeSessionKey == nil")
    func sessionKey_lifecycle_review_replay_nil() async throws {
        let (coord, records, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        _ = try await coord.review(recordId: id)
        #expect(coord.activeSessionKey == nil)                 // review → nil（RFC §4.7c）
        await coord.endSession()
        _ = try await coord.replay(recordId: id)
        #expect(coord.activeSessionKey == nil)                 // replay → nil
    }

    @Test("finalize 失败：port 注入错误 → session 保持活跃（RFC §4.7a：失败不拆 session）")
    func finalize_failure_preserves_session_then_retry_succeeds() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        let spy = Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        try pending.savePending(try Self.deterministicPending())
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())

        // 注入首次 finalize 失败
        port.failNextFinalize = AppError.persistence(.ioError("disk"))
        await #expect(throws: AppError.persistence(.ioError("disk"))) {
            _ = try await coord.finalize(engine: engine)
        }
        // RFC §4.7a：失败后 session 仍活跃（activeEngine/Reader/SessionKey 均非 nil）
        #expect(coord.activeEngine === engine)
        #expect(coord.activeReader != nil)
        #expect(coord.activeSessionKey != nil)
        #expect(try pending.loadPending() != nil)              // 失败保留：pending 仍存在（§4.7a）
        // 重试成功
        let id = try #require(try await coord.finalize(engine: engine))
        #expect(id > 0)
        #expect(try pending.loadPending() == nil)              // 成功后 pending 清空
        #expect(port.finalizeCallCount == 2)                   // port 调用两次（首次失败 + 重试成功）
    }

    @Test("finalize 幂等：同 sessionKey 重试 → 返相同 id（RFC §4.7c 幂等锚）")
    func finalize_retry_after_committed_returns_same_id() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        // 手动组装，保持 port 引用
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        try pending.savePending(try Self.deterministicPending())
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: SettingsStore(settingsDAO: CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        let id1 = try #require(try await coord.finalize(engine: engine))
        // 证明 fake 层幂等（§4.7c）：重新注入同 sessionKey pending → port.keyed["SK-test"] 已存 → 返同 id。
        // 注：真实 DB 层幂等由 SessionFinalizationPortTests 覆盖；此处仅验证 fake 契约正确。
        try pending.savePending(try Self.deterministicPending())
        // 重建 session（resumePending 会从 pending 取回 "SK-test"）
        let coord2 = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)),
            recordRepo: records, pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            reviewArchiveRepo: InMemoryReviewArchiveRepository(),
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: SettingsStore(settingsDAO: CapitalDAO(capital: 10_000)))
        let engine2 = try #require(try await coord2.resumePending())  // 恢复 sessionKey = "SK-test"
        let id2 = try #require(try await coord2.finalize(engine: engine2))
        #expect(id1 == id2)                                    // 幂等：同 key 返同 id
        #expect(port.finalizeCallCount == 2)                  // port 调用两次（幂等由 port 处理）
    }

    @Test("finalize：review/replay 不触 port（shouldSaveRecord() 早返 nil 在 key guard 之前）")
    func finalize_review_replay_do_not_touch_port() async throws {
        let (coord, records, _, port) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let reviewEngine = try await coord.review(recordId: id)
        _ = try await coord.finalize(engine: reviewEngine)    // 早返 nil（review）
        await coord.endSession()
        let replayEngine = try await coord.replay(recordId: id)
        _ = try await coord.finalize(engine: replayEngine)    // 早返 nil（replay）
        #expect(port.finalizeCallCount == 0)                   // port 从未被触发
    }
}
