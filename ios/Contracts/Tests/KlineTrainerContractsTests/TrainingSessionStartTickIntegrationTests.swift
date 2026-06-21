import Foundation
import Testing
@testable import KlineTrainerContracts

struct TrainingSessionStartTickIntegrationTests {
    // m3 datetime = 1 + i*180 → [1,181,361,541,721,901,1081,1261]；含 before（< startDatetime）。
    static func candles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int) -> KLineCandle {
            KLineCandle(period: p, datetime: 1 + Int64(gi) * 180, open: 10, high: 11, low: 9,
                        close: 10, volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: p == .m3 ? gi : nil, endGlobalIndex: egi)
        }
        let last = m3Count - 1
        return [.m3: (0..<m3Count).map { c(.m3, gi: $0, egi: $0) },
                .m60: [c(.m60, gi: 0, egi: last / 2), c(.m60, gi: last / 2 + 1, egi: last)],
                .daily: [c(.daily, gi: 0, egi: last)]]
    }

    /// startDatetime=361（=m3[2].datetime）→ 起始点 index 2，前有 2 根 before。
    /// 构造签名经核（R1-C1）：TrainingSessionCoordinator.init(dbFactory:recordRepo:pendingRepo:finalization:settingsDAO:cache:settings:)；
    /// PreviewTrainingSetDBFactory(meta:candles:)（InMemoryFakes.swift:24）；
    /// TrainingSetFile(id:filename:localURL:schemaVersion:lastAccessedAt:downloadedAt:)（AppState.swift:142）；
    /// CapitalDAO 是 TrainingSessionPersistenceTests 的嵌套 SettingsDAO（同 target 可见）；`now` 是 init 后可设 var。
    @MainActor
    func makeCoordinatorAndRecords() -> (TrainingSessionCoordinator, InMemoryRecordRepository) {
        let meta = TrainingSetMeta(stockCode: "600000", stockName: "测试股",
                                   startDatetime: 361, endDatetime: 1261)
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let cache = InMemoryCacheManager()
        cache._seedForTesting([
            TrainingSetFile(id: 1, filename: "set.sqlite",
                            localURL: URL(fileURLWithPath: "/tmp/set.sqlite"),
                            schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
        ])
        let coord = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(meta: meta, candles: Self.candles()),
            recordRepo: records, pendingRepo: pending,
            finalization: InMemorySessionFinalizationPort(records: records, pending: pending),
            settingsDAO: InMemorySettingsDAO(), cache: cache,
            settings: SettingsStore(settingsDAO: TrainingSessionPersistenceTests.CapitalDAO(capital: 100_000)))
        coord.now = { 1_700_000_000 }
        return (coord, records)
    }

    @Test("startNewNormalSession 开局 tick = 起始点派生（有 before → 非 0）")
    @MainActor
    func freshNormalOpensAtStartTick() async throws {
        let (coord, _) = makeCoordinatorAndRecords()
        let engine = try await coord.startNewNormalSession()
        #expect(engine.tick.globalTickIndex == 2)   // 首个 datetime >= 361 = index 2
    }

    @Test("replay 同样从起始点开局（非 0）")
    @MainActor
    func replayOpensAtStartTick() async throws {
        let (coord, records) = makeCoordinatorAndRecords()
        let src = TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 0,
            stockCode: "600000", stockName: "测试股", startYear: 2023, startMonth: 11,
            totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
            buyCount: 0, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false), finalTick: 7)
        let srcId = try records.insertRecord(src, ops: [], drawings: [])
        let engine = try await coord.replay(recordId: srcId)
        #expect(engine.tick.globalTickIndex == 2)   // replay 也 seed 到起始点
    }
}
