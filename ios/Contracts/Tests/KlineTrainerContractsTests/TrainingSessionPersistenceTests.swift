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
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
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
                                                startDatetime: 1_583_000_000, endDatetime: 1_583_100_000)
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
            finalization: InMemorySessionFinalizationPort(records: records, pending: pending),
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: capital)))
        let engine = try await coord.replay(recordId: srcId)
        return (coord, engine, records, pending)
    }

    @Test("replaySettlementPayload: 强平后终态 → in-memory TrainingRecord（原局 fees + meta）")
    func replaySettlementPayload_returnsTerminalStateRecord() async throws {
        let (coord, engine, _, _) = try await Self.makeReplaySession(capital: 100_000)
        _ = engine.buy(panel: .upper, tier: .tier1)      // replay 可交易；建非平凡终态
        engine.forceCloseManually()                       // 6a：强平 → 持仓平
        #expect(engine.position.shares == 0)
        let payload = try coord.replaySettlementPayload(engine: engine)
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
        _ = engine.buy(panel: .upper, tier: .tier1)
        engine.forceCloseManually()
        _ = try coord.replaySettlementPayload(engine: engine)
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
        #expect(throws: AppError.self) {
            _ = try coord.replaySettlementPayload(engine: engine)
        }
    }

    @Test("replaySettlementPayload: 无活跃会话 / engine 身份不符 → throws")
    func replaySettlementPayload_throwsWithoutActiveSession() async throws {
        let (coord, engine, _, _) = try await Self.makeReplaySession()
        await coord.endSession()                               // 清活跃上下文
        #expect(throws: AppError.self) {
            _ = try coord.replaySettlementPayload(engine: engine)
        }
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
        #expect(coord.activeEngine != nil)
        #expect(coord.activeReader != nil)
        #expect(coord.activeSessionKey != nil)
        // 重试成功
        let id = try #require(try await coord.finalize(engine: engine))
        #expect(id > 0)
        #expect(try pending.loadPending() == nil)              // 成功后 pending 清空
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
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: SettingsStore(settingsDAO: CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        let id1 = try #require(try await coord.finalize(engine: engine))
        // 模拟 crash-recovery：手动重新注入 pending（同 sessionKey "SK-test"）以允许再次 finalize
        // 但 port 已经 keyed["SK-test"] → 返同 id（幂等）
        try pending.savePending(try Self.deterministicPending())
        // 重建 session（resumePending 会从 pending 取回 "SK-test"）
        let coord2 = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)),
            recordRepo: records, pendingRepo: pending,
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
