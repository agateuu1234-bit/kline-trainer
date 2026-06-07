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
}
