import Testing
import Foundation
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingSessionCoordinatorConstruction")
struct TrainingSessionCoordinatorConstructionTests {

    // MARK: - 合法 candle fixture（连续 .m3 轴 0..n + m60/daily 非空，过 make 全校验）

    /// m3: globalIndex==endGlobalIndex==i, i∈0..<count；m60/daily 覆盖到 maxTick。
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

    /// 设置非零起始本金的 DAO（happy-path：load 成功）。
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

    /// 组装一个 coordinator：注入指定 candle 的 reader（经 PreviewTrainingSetDBFactory）+
    /// 已 seed 一个缓存文件 + 指定起始本金的 SettingsStore。
    static func makeCoordinator(
        candles: [Period: [KLineCandle]],
        capital: Double = 100_000,
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
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            finalization: InMemorySessionFinalizationPort(records: records, pending: pending),
            // A4：settingsDAO 与 SettingsStore 同源（startingCapital 直读 DAO）。
            settingsDAO: CapitalDAO(capital: capital),
            cache: cache,
            settings: SettingsStore(settingsDAO: CapitalDAO(capital: capital)))
        return (coord, records, pending)
    }

    @Test("startNewNormalSession: 无记录 → 起始本金取 settings.totalCapital + 引擎可交易 + active 写入")
    func startNew_noRecords_usesSettingsCapital() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        let engine = try await coord.startNewNormalSession()
        #expect(engine.initialCapital == 50_000)
        #expect(engine.cashBalance == 50_000)
        #expect(engine.flow.mode == .normal)
        #expect(engine.tick.globalTickIndex == 0)        // NormalFlow.initialTick == 0
        #expect(coord.activeEngine != nil)
        #expect(coord.activeReader != nil)
    }

    // MARK: - 失败注入 mock

    /// loadSettings 抛 → SettingsStore.loadError 置位 → snapshotFeesIfReady throws。
    struct ThrowingDAO: SettingsDAO {
        let error: AppError
        func loadSettings() throws -> AppSettings { throw error }
        func saveSettings(_: AppSettings) throws {}
        func resetCapital() throws {}
    }

    /// 记录 close() 调用 + 可配置 loadAllCandles 抛错的 spy reader。
    final class SpyReader: TrainingSetReader, @unchecked Sendable {
        let candles: [Period: [KLineCandle]]
        let loadError: AppError?
        private(set) var closed = false
        init(candles: [Period: [KLineCandle]], loadError: AppError? = nil) {
            self.candles = candles; self.loadError = loadError
        }
        func loadMeta() throws -> TrainingSetMeta {
            TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 1)
        }
        func loadAllCandles() throws -> [Period: [KLineCandle]] {
            if let e = loadError { throw e }
            return candles
        }
        func close() { closed = true }
    }

    /// 注入指定 reader 的 factory（绕过 PreviewTrainingSetDBFactory 的 happy-path）。
    struct StubFactory: TrainingSetDBFactory {
        let reader: TrainingSetReader
        let openError: AppError?
        init(reader: TrainingSetReader, openError: AppError? = nil) {
            self.reader = reader; self.openError = openError
        }
        func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
            if let e = openError { throw e }
            return reader
        }
    }

    /// 用指定 factory + 起始本金 + 缓存文件 组装 coordinator（失败注入专用）。
    static func makeCoordinator(
        factory: TrainingSetDBFactory,
        settings: SettingsStore,
        seedFile: TrainingSetFile? = cachedFile()
    ) -> TrainingSessionCoordinator {
        let cache = InMemoryCacheManager()
        if let f = seedFile { cache._seedForTesting([f]) }
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        return TrainingSessionCoordinator(
            dbFactory: factory,
            recordRepo: records,
            pendingRepo: pending,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            finalization: InMemorySessionFinalizationPort(records: records, pending: pending),
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: settings)
    }

    // A4：startingCapital 直读权威 settings.total_capital，**不**再从记录累计（推翻旧累计模型）。
    @Test("startNewNormalSession: 有记录也取权威 settings.totalCapital（A4，非 statistics() 末条累计）")
    func startNew_withRecords_usesAuthoritativeSettingsCapital() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        _ = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 100,
                           stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                           totalCapital: 50_000, profit: 12_000, returnRate: 0.24, maxDrawdown: 0,
                           buyCount: 1, sellCount: 1,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let engine = try await coord.startNewNormalSession()
        #expect(engine.initialCapital == 50_000)         // A4 权威 settings；非记录累计 62_000
        #expect(engine.initialCapital != 62_000)         // killer：不再用 statistics().currentCapital
        #expect(engine.cashBalance == 50_000)
    }

    @Test("startNewNormalSession: settings.loadError → throws 且不写 active（fail-closed D2/D9）")
    func startNew_loadError_throwsNoActive() async throws {
        let store = SettingsStore(settingsDAO: ThrowingDAO(error: .persistence(.dbCorrupted)))
        let spy = SpyReader(candles: Self.validCandles())
        let coord = Self.makeCoordinator(factory: StubFactory(reader: spy), settings: store)
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            try await coord.startNewNormalSession()
        }
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
        #expect(spy.closed == false)                     // reader 从未打开（fees 早抛）
    }

    @Test("startNewNormalSession: 无缓存训练组 → .trainingSet(.fileNotFound)")
    func startNew_noCache_throwsFileNotFound() async throws {
        let store = SettingsStore(settingsDAO: CapitalDAO(capital: 10_000))
        let coord = Self.makeCoordinator(
            factory: StubFactory(reader: SpyReader(candles: Self.validCandles())),
            settings: store, seedFile: nil)
        await #expect(throws: AppError.trainingSet(.fileNotFound)) {
            try await coord.startNewNormalSession()
        }
        #expect(coord.activeReader == nil)
    }

    @Test("startNewNormalSession: loadAllCandles 抛 → reader.close() 调用 + 不写 active（D9）")
    func startNew_loadCandlesFails_closesReader() async throws {
        let store = SettingsStore(settingsDAO: CapitalDAO(capital: 10_000))
        let spy = SpyReader(candles: [:], loadError: .persistence(.ioError("disk")))
        let coord = Self.makeCoordinator(factory: StubFactory(reader: spy), settings: store)
        await #expect(throws: AppError.persistence(.ioError("disk"))) {
            try await coord.startNewNormalSession()
        }
        #expect(spy.closed == true)                      // D9：失败关闭已开 reader
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    @Test("startNewNormalSession: openAndVerify 抛 .versionMismatch（损坏）→ 删文件重试，单文件耗尽 → .fileNotFound + 不写 active（RFC §4.7f）")
    func startNew_openThrows_propagatesNoActive() async throws {
        let store = SettingsStore(settingsDAO: CapitalDAO(capital: 10_000))
        let spy = SpyReader(candles: Self.validCandles())
        let coord = Self.makeCoordinator(
            factory: StubFactory(reader: spy, openError: .trainingSet(.versionMismatch(expected: 1, got: 2))),
            settings: store)
        // §4.7f: versionMismatch is a corrupt training-set error → delete + retry;
        // with 1 file in cache, after deletion the retry exhausts → .fileNotFound (caller re-downloads).
        await #expect(throws: AppError.trainingSet(.fileNotFound)) {
            try await coord.startNewNormalSession()
        }
        #expect(spy.closed == false)                     // openAndVerify 抛 → 无 reader 返回，无可关
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    static func pending(
        filename: String = "set.sqlite",
        tick: Int = 3,
        position: PositionManager = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000),
        cash: Double = 90_000,
        accumulated: Double = 100_000,
        positionDataOverride: Data? = nil,
        ops: [TradeOperation] = []
    ) throws -> PendingTraining {
        let posData = try positionDataOverride ?? JSONEncoder().encode(position)
        return PendingTraining(
            trainingSetFilename: filename, globalTickIndex: tick,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: posData, cashBalance: cash,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: ops, drawings: [], startedAt: 1,
            accumulatedCapital: accumulated, drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 5_000),
            sessionKey: "SK-test")
    }

    @Test("resumePending: 无 pending → 返回 nil（不抛、不写 active）")
    func resume_noPending_returnsNil() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.resumePending()
        #expect(engine == nil)
        #expect(coord.activeEngine == nil)
    }

    @Test("resumePending: 有 pending → 重建 tick/position/cash/drawdown/periods + active 写入")
    func resume_happy_rebuildsState() async throws {
        let (coord, _, pendingRepo) = Self.makeCoordinator(candles: Self.validCandles())
        try pendingRepo.savePending(try Self.pending(tick: 3, cash: 90_000, accumulated: 100_000))
        let engine = try #require(try await coord.resumePending())
        #expect(engine.tick.globalTickIndex == 3)        // D7：initialTick = pending.globalTickIndex
        #expect(engine.position.shares == 100)            // decode 还原
        #expect(engine.cashBalance == 90_000)
        #expect(engine.initialCapital == 100_000)         // accumulatedCapital
        #expect(engine.upperPanel.period == .m60)
        #expect(engine.lowerPanel.period == .daily)
        #expect(coord.activeReader != nil)
    }

    @Test("resumePending: positionData 损坏 → .persistence(.dbCorrupted)（D11）+ reader 关闭")
    func resume_corruptPosition_throwsDbCorrupted() async throws {
        let store = SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000))
        let spy = Self.SpyReader(candles: Self.validCandles())
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let pendingRepo = InMemoryPendingTrainingRepository()
        try pendingRepo.savePending(try Self.pending(positionDataOverride: Data("not json".utf8)))
        let records2 = InMemoryRecordRepository()
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records2, pendingRepo: pendingRepo,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            finalization: InMemorySessionFinalizationPort(records: records2, pending: pendingRepo),
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: store)
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            try await coord.resumePending()
        }
        #expect(spy.closed == true)
        #expect(coord.activeEngine == nil)
    }

    @Test("resumePending: 训练组文件不在缓存 → .trainingSet(.fileNotFound)")
    func resume_fileMissing_throwsFileNotFound() async throws {
        let (coord, _, pendingRepo) = Self.makeCoordinator(candles: Self.validCandles(), seedFile: nil)
        try pendingRepo.savePending(try Self.pending())
        await #expect(throws: AppError.trainingSet(.fileNotFound)) {
            try await coord.resumePending()
        }
    }

    @Test("resumePending: stale tick 超出 maxTick → make 抛 .emptyData + reader 关闭（D7/D9）")
    func resume_staleTick_throwsEmptyDataClosesReader() async throws {
        let store = SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000))
        let spy = Self.SpyReader(candles: Self.validCandles(m3Count: 8))   // maxTick = 7
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let pendingRepo = InMemoryPendingTrainingRepository()
        try pendingRepo.savePending(try Self.pending(tick: 99))            // 超出 allowedTickRange 0...7（训练组被替换）
        let records3 = InMemoryRecordRepository()
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records3, pendingRepo: pendingRepo,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            finalization: InMemorySessionFinalizationPort(records: records3, pending: pendingRepo),
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: store)
        await #expect(throws: AppError.trainingSet(.emptyData)) {
            try await coord.resumePending()
        }
        #expect(spy.closed == true)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    /// 插一条带 ops/drawings 的记录，返回 recordId。
    static func seedRecord(
        _ records: InMemoryRecordRepository,
        filename: String = "set.sqlite",
        totalCapital: Double = 100_000, profit: Double = 8_000, finalTick: Int = 7,
        ops: [TradeOperation], drawings: [DrawingObject] = []
    ) throws -> Int64 {
        try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: filename, createdAt: 1,
                           stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                           totalCapital: totalCapital, profit: profit,
                           returnRate: profit / totalCapital, maxDrawdown: -0.05,
                           buyCount: 1, sellCount: 1,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: true),
                           finalTick: finalTick),
            ops: ops, drawings: drawings)
    }

    static func op(tick: Int, price: Double, dir: TradeDirection) -> TradeOperation {
        TradeOperation(globalTick: tick, period: .m3, direction: dir, price: price, shares: 100,
                       positionTier: .tier1, commission: 1, stampDuty: 0, totalCost: price * 100,
                       createdAt: 0)
    }

    @Test("review: 从训练起点开演 + 还原标记 + tick=派生 startTick + 收益率与 record 自洽（D5 / B3）")
    func review_happy_restoresEndState() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try Self.seedRecord(records, totalCapital: 100_000, profit: 8_000, finalTick: 7,
                                     ops: [Self.op(tick: 2, price: 10.2, dir: .buy),
                                           Self.op(tick: 5, price: 10.5, dir: .sell)])
        let engine = try await coord.review(recordId: id)
        #expect(engine.flow.mode == .review)
        #expect(engine.flow.canBuySell() == false)        // ReviewFlow 全能力关
        #expect(engine.tick.globalTickIndex == 0)          // B3: initialTick = derived startTick (startDatetime=1 → m3[0])
        #expect(engine.tick.globalTickIndex < 7)           // 起点不是末根
        #expect(engine.flow.allowedTickRange.upperBound == 7)  // 末根仍是 finalTick
        #expect(engine.markers.count == 2)                 // 还原全部标记
        #expect(engine.tradeOperations.count == 2)
        #expect(engine.initialCapital == 100_000)
        #expect(abs(engine.returnRate - 0.08) < 1e-9)      // (108000-100000)/100000 = record.returnRate
        #expect(coord.activeReader != nil)
    }

    @Test("review: 费率来自 record 非当前 settings（D5）")
    func review_usesRecordFees() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 10_000)
        let id = try Self.seedRecord(records, ops: [])
        let engine = try await coord.review(recordId: id)
        #expect(engine.fees.commissionRate == 0.0002)      // record.feeSnapshot，非 settings 的 0.0001
        #expect(engine.fees.minCommissionEnabled == true)
    }

    @Test("review: loadAllCandles 抛 → reader.close() + 不写 active（D9 post-open）")
    func review_loadCandlesFails_closesReader() async throws {
        let store = SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000))
        let records = InMemoryRecordRepository()
        let id = try Self.seedRecord(records, ops: [])
        let spy = Self.SpyReader(candles: [:], loadError: .persistence(.ioError("x")))
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let pendingR = InMemoryPendingTrainingRepository()
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pendingR,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            finalization: InMemorySessionFinalizationPort(records: records, pending: pendingR),
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: store)
        await #expect(throws: AppError.persistence(.ioError("x"))) {
            try await coord.review(recordId: id)
        }
        #expect(spy.closed == true)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    @Test("replay: 从头 tick=0 + 无标记 + 用原局费率 + 起始本金=record.totalCapital（D6）")
    func replay_happy_freshFromOriginalFees() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 10_000)
        let id = try Self.seedRecord(records, totalCapital: 80_000, profit: 5_000,
                                     ops: [Self.op(tick: 2, price: 10.2, dir: .buy)])
        let engine = try await coord.replay(recordId: id)
        #expect(engine.flow.mode == .replay)
        #expect(engine.flow.canBuySell() == true)          // Replay 可操作
        #expect(engine.flow.shouldSaveRecord() == false)   // 不入账
        #expect(engine.tick.globalTickIndex == 0)          // 从头
        #expect(engine.markers.isEmpty)                    // fresh，无还原
        #expect(engine.tradeOperations.isEmpty)
        #expect(engine.initialCapital == 80_000)           // record.totalCapital（非累计、非 settings）
        #expect(engine.cashBalance == 80_000)
        #expect(engine.fees.commissionRate == 0.0002)      // 原局 feeSnapshot
        #expect(coord.activeReader != nil)
    }

    @Test("replay: 记录不存在 → 传播 AppError（fake 抛 .dbCorrupted；reader 未开）")
    func replay_unknownRecord_propagates() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            try await coord.replay(recordId: 999)
        }
        #expect(coord.activeReader == nil)
    }

    @Test("replay: loadAllCandles 抛 → reader.close() + 不写 active（D9 post-open）")
    func replay_loadCandlesFails_closesReader() async throws {
        let store = SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000))
        let records = InMemoryRecordRepository()
        let id = try Self.seedRecord(records, ops: [])
        let spy = Self.SpyReader(candles: [:], loadError: .persistence(.diskFull))
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let pendingP = InMemoryPendingTrainingRepository()
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pendingP,
            pendingReplayRepo: InMemoryPendingReplayRepository(),
            finalization: InMemorySessionFinalizationPort(records: records, pending: pendingP),
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: store)
        await #expect(throws: AppError.persistence(.diskFull)) {
            try await coord.replay(recordId: id)
        }
        #expect(spy.closed == true)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }
}
