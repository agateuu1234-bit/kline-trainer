import Testing
import Foundation
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingSessionPersistence")
struct TrainingSessionPersistenceTests {

    // MARK: - 合法 candle fixture（连续 .m3 轴 0..n + m60/daily 非空，过 make 全校验）

    static func validCandles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int, close: Double) -> KLineCandle {
            KLineCandle(period: p, datetime: Int64(gi) * 180, open: 10, high: 11, low: 9,
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
    ) -> (TrainingSessionCoordinator, InMemoryRecordRepository, InMemoryPendingTrainingRepository) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let cache = InMemoryCacheManager()
        if let f = seedFile { cache._seedForTesting([f]) }
        let coord = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: candles),
            recordRepo: records,
            pendingRepo: pending,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: SettingsStore(settingsDAO: CapitalDAO(capital: capital)))
        return (coord, records, pending)
    }

    @Test("endSession: 关闭 reader + 清空 active 状态（D10）")
    func endSession_closesReaderClearsActive() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        _ = try await coord.startNewNormalSession()
        #expect(coord.activeReader != nil)
        #expect(coord.activeEngine != nil)
        await coord.endSession()
        #expect(coord.activeReader == nil)
        #expect(coord.activeEngine == nil)
    }

    @Test("endSession: never-started → 安全 no-op（不崩）")
    func endSession_neverStarted_noop() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        await coord.endSession()     // 全 nil，不崩
        #expect(coord.activeReader == nil)
        #expect(coord.activeEngine == nil)
    }

    @Test("endSession: 真关闭注入 reader（spy.closed == true）")
    func endSession_closesInjectedReader() async throws {
        let spy = Self.MetaSpyReader(candles: Self.validCandles())
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: InMemoryRecordRepository(),
            pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        _ = try await coord.startNewNormalSession()
        await coord.endSession()
        #expect(spy.closed == true)
    }

    @Test("saveProgress: Normal 局 → 持久化 PendingTraining 全字段（含 startedAt=now()、accumulated=起始资金）")
    func saveProgress_normal_persistsAllFields() async throws {
        let (coord, _, pending) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        coord.now = { 111 }                                  // 控制 startedAt
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
        let (coord, records, pending) = Self.makeCoordinator(candles: Self.validCandles())
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
        let (coord, records, pending) = Self.makeCoordinator(candles: Self.validCandles())
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

    @Test("saveProgress: 缺活跃上下文（endSession 后）→ .internalError（D9）")
    func saveProgress_noActiveContext_throws() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.startNewNormalSession()
        await coord.endSession()                               // 清空 activeFile/activeStartedAt
        await #expect(throws: AppError.internalError(module: "E6b",
                      detail: "saveProgress without active session context")) {
            try await coord.saveProgress(engine: engine)
        }
    }

    @Test("saveProgress → resumePending round-trip：状态还原一致（D4 跨方法集成）")
    func saveProgress_thenResume_roundTrips() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
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

    /// 构造一个确定性 pending：resume 后 tick=7、price=10.7、cash=90000、shares=100、accumulated=100000，
    /// → currentTotal=91070、profit=-8930、drawdown abs=8930/peak=100000。
    static func deterministicPending() throws -> PendingTraining {
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        return PendingTraining(
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
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 5_000))
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
        let coord = TrainingSessionCoordinator(
            dbFactory: StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
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

    @Test("finalize: review 模式 → nil（不插记录、不动 pending，D2）")
    func finalize_review_returnsNil() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles())
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
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles())
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
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
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
            accumulatedCapital: 100_000, drawdown: .initial))
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
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
}
