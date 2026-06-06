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
            settingsDAO: InMemorySettingsDAO(),
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
}
