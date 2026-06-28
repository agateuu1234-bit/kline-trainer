import Testing
import Foundation
import GRDB
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

#if DEBUG
/// A4（RFC-A）coordinator 资金集成：用**真 DefaultAppDB** 作 repos+finalization+settingsDAO，
/// SettingsStore 套同一 DB —— 验 finalize 成功后活缓存 == DB 权威资金（R-plan-3-1），
/// 及局终自动强平退化局 floor 到 0（R-plan-13-1，端到端经协调器）。
@Suite("A4 coordinator 资金集成（真 DefaultAppDB）")
@MainActor
struct CoordinatorCapitalIntegrationTests {

    /// 合法 candle fixture（连续 m3 0..n + m60/daily 覆盖 maxTick），close 由闭包给定。
    static func candles(m3Count: Int = 8, close: (Int) -> Double) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int, cl: Double) -> KLineCandle {
            KLineCandle(period: p, datetime: 1 + Int64(gi) * 180, open: cl, high: cl, low: cl,
                        close: cl, volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: gi, endGlobalIndex: egi)
        }
        let m3 = (0..<m3Count).map { c(.m3, gi: $0, egi: $0, cl: close($0)) }
        let last = m3Count - 1
        let m60 = [c(.m60, gi: 0, egi: last / 2, cl: close(last / 2)),
                   c(.m60, gi: last / 2 + 1, egi: last, cl: close(last))]
        let daily = [c(.daily, gi: 0, egi: last, cl: close(last))]
        return [.m3: m3, .m60: m60, .daily: daily]
    }

    static func cachedFile() -> TrainingSetFile {
        TrainingSetFile(id: 1, filename: "set.sqlite",
                        localURL: URL(fileURLWithPath: "/tmp/set.sqlite"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    /// 真 DefaultAppDB 作 repos/finalization/settingsDAO；SettingsStore 套同一 DB。
    static func makeCoordinator(appDB: DefaultAppDB, candles: [Period: [KLineCandle]])
        -> (TrainingSessionCoordinator, SettingsStore) {
        let cache = InMemoryCacheManager(); cache._seedForTesting([cachedFile()])
        let store = SettingsStore(settingsDAO: appDB)
        let coord = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: candles),
            recordRepo: appDB, pendingRepo: appDB, finalization: appDB,
            settingsDAO: appDB, cache: cache, settings: store)
        return (coord, store)
    }

    private static func makeFreshDB() throws -> (URL, DefaultAppDB) {
        let url = try AppDBFixture.makeFreshDB()
        return (url, try DefaultAppDB(dbPath: url))
    }

    // codex R-plan-3-1：finalize 成功 → 注入的活 SettingsStore 缓存 == DB 权威资金（无需重启/reload）。
    @Test("finalize → 活缓存 == DB 权威资金（且 ≠ 默认，证非巧合）")
    func test_finalize_refreshes_live_settings_cache() async throws {
        let (url, appDB) = try Self.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // 上涨行情：buy@tick0(价 10) → m60 步进到 tick3(价 13) → 持仓盈利 → 终态资金 > 起始 10 万。
        let (coord, store) = Self.makeCoordinator(appDB: appDB,
            candles: Self.candles(close: { 10 + Double($0) }))
        let engine = try await coord.startNewNormalSession()   // 起始本金 = DB 权威 10 万
        _ = engine.buy(panel: .upper, shares: 2000)            // 建仓 + 推进 → 价升 → 盈利
        let id = try await coord.finalize(engine: engine)
        #expect(id != nil)
        // 同一注入 SettingsStore：缓存值 == DB 权威值（无需重启/reload）
        #expect(abs(store.settings.totalCapital - (try appDB.loadSettings().totalCapital)) < 1e-6)
        #expect(store.settings.totalCapital > 100_000)         // 盈利已并入权威资金（非巧合等于默认）
    }

    // codex R-plan-13-1（端到端经协调器）：局终自动强平退化局（净 proceeds 为负、currentTotalCapital<0）
    // → 跑完 finalize 后 DB/缓存 settings.total_capital >= 0（floor 生效，非负权威资金）。
    @Test("局终自动强平负 proceeds → 权威资金 floor ≥ 0（DB + 活缓存）")
    func test_auto_end_force_close_negative_proceeds_floors_capital() async throws {
        let (url, appDB) = try Self.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // 低价 0.01 全程 + 最低佣金 5（minCommissionEnabled）→ 强平 100 股 proceeds = 1 - 5 - 印花税 < 0。
        let (coord, store) = Self.makeCoordinator(appDB: appDB,
            candles: Self.candles(close: { _ in 0.01 }))
        // 注入退化局 pending：100 股、小额现金 3、起始本金 3、tick 3（< maxTick 7）。
        let pos = PositionManager(shares: 100, averageCost: 0.01, totalInvested: 1.0)
        try appDB.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 3,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            tradeOperations: [], drawings: [], startedAt: 1,
            accumulatedCapital: 3, drawdown: .initial, sessionKey: "kFC"))
        let engine = try #require(try await coord.resumePending())
        #expect(engine.tick.globalTickIndex == 3)
        engine.holdOrObserve(panel: .upper)                    // 3 → 7（maxTick）→ 局终自动强平
        #expect(engine.position.shares == 0)                   // 已强平
        #expect(engine.currentTotalCapital < 0)                // 退化：净现金转负（不能欠钱 → 须 floor）
        let id = try await coord.finalize(engine: engine)
        #expect(id != nil)
        #expect(try appDB.loadSettings().totalCapital >= 0)    // 权威资金不为负（floor）
        #expect(store.settings.totalCapital >= 0)              // 活缓存亦然
        #expect(try appDB.loadSettings().totalCapital == 0)    // 具体 floor 值
    }

    // codex R-plan-24-1：腐坏 total_capital（负值）→ loadSettings 抛 .dbCorrupted → forceResetAndReload
    // 经 **repairAllToDefaults**（写全键含 total_capital）真修复 → reload 不抛、total_capital==10万。
    // （单写者下 saveSettings 不写 total_capital，旧路径修不掉——本测试钉死 repairAllToDefaults 的必要性。）
    @Test("腐坏恢复：负 total_capital → forceResetAndReload 经 repairAllToDefaults 修复为 10 万（DB 真修）")
    func test_forceReset_repairs_corrupt_total_capital() async throws {
        let (url, appDB) = try Self.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // 绕守卫直写负 total_capital → loadSettings 抛 .dbCorrupted。
        try await appDB.dbQueue.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO settings(key, value) VALUES ('total_capital', '-1.0')")
        }
        #expect(throws: AppError.persistence(.dbCorrupted)) { _ = try appDB.loadSettings() }

        let store = SettingsStore(settingsDAO: appDB)          // init load 失败 → loadError 置位
        #expect(store.loadError != nil)
        await #expect(throws: (any Error).self) { try await store.retryReload() }   // 仍腐坏 → 失败（前置门）
        try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())   // repairAllToDefaults 修复

        #expect(store.loadError == nil)
        #expect(store.settings.totalCapital == 100_000)        // 缓存修复
        #expect(try appDB.loadSettings().totalCapital == 100_000)   // DB 真修复（不再抛）
    }
}
#endif
