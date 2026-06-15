import Testing
import Foundation
@testable import KlineTrainerPersistence
import KlineTrainerContracts

#if DEBUG
@Suite("AppContainer debug seed：init 内 seed（settings 不 stale）+ 全空 guard（不破坏真实数据）（§C）")
@MainActor
struct AppContainerDebugSeedTests {

    private func makeConfig() throws -> (AppConfig, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeedTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = AppConfig(dbPath: dir.appendingPathComponent("app.sqlite"),
                            cacheRootDir: dir.appendingPathComponent("training-sets"),
                            backendBaseURL: URL(string: "http://debug.local")!)
        return (cfg, dir)
    }

    @Test("seed（debugSeedFixtures:true）：cache/history/pending 非空 + settings 反映 fixture（非 stale 0）")
    func seed_populatesAll_andFreshSettings() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: true)
        #expect(!c.cache.listAvailable().isEmpty)
        let file = c.cache.listAvailable().first!
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: file.localURL, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        reader.close()
        #expect(try c.db.statistics().totalCount >= 2)
        #expect(try c.db.listRecords(limit: nil).count >= 2)
        #expect(try c.db.loadPending() != nil)
        await c.router.loadHome()
        #expect(c.router.homeContent.hasCachedSets == true)
        #expect(c.router.homeContent.isResuming == true)
        // codex-13b-R3：live SettingsStore eager-load 到 seeded settings（非 stale zero-default）
        #expect(c.settings.loadError == nil)
        #expect(c.settings.settings.totalCapital == 100_000, "settings 须 eager-load 到 seeded fixture（非 stale 0）")
    }

    @Test("未 seed（debugSeedFixtures:false）：settings 为空库 zero-default（对照，证上一测非 vacuous）")
    func noSeed_settingsIsZeroDefault() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: false)
        #expect(c.cache.listAvailable().isEmpty)
        #expect(c.settings.settings.totalCapital == 0)   // 空库 zero-default，与 seeded 100_000 区分
    }

    @Test("幂等：同 config 第二个 container（seed:true）→ 全空 guard 跳过，records/cache 不叠加")
    func seed_idempotent() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c1 = try AppContainer(config: cfg, debugSeedFixtures: true)
        let recCount1 = try c1.db.listRecords(limit: nil).count
        let cacheCount1 = c1.cache.listAvailable().count
        let c2 = try AppContainer(config: cfg, debugSeedFixtures: true)   // 同 db/cache 路径
        #expect(try c2.db.listRecords(limit: nil).count == recCount1, "幂等：records 不叠加")
        #expect(c2.cache.listAvailable().count == cacheCount1, "幂等：cache 不叠加")
    }

    @Test("seed 的训练组可真开局（resumePending 重建引擎）")
    func seed_pendingResumable() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: true)
        let engine = try await c.coordinator.resumePending()
        #expect(engine != nil)
    }

    // codex-13b-R1：cache 空但 app.sqlite 有真实 history（iOS 清 Caches 但留 app.sqlite）→ seed 拒绝（records guard）。
    @Test("全空 guard：cache 空但 db 有真实 history → seed no-op，不混入 fixture records")
    func seed_refusesWhenHistoryExists() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: false)   // 不 seed
        let realRec = TrainingRecord(
            id: nil, trainingSetFilename: "real-user-set.sqlite", createdAt: 1,
            stockCode: "999999", stockName: "真实用户股", startYear: 2024, startMonth: 1,
            totalCapital: 50_000, profit: 100, returnRate: 0.002, maxDrawdown: -0.01,
            buyCount: 1, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0009, minCommissionEnabled: true), finalTick: 5)
        _ = try c.db.insertRecord(realRec, ops: [], drawings: [])
        #expect(c.cache.listAvailable().isEmpty)

        try AppContainer.seedDebugFixtures(db: c.db, cache: c.cache)      // 模拟带 env 重启 + Caches 被清

        #expect(try c.db.statistics().totalCount == 1, "真实 history 未被 fixture records 混入")
        #expect(try c.db.listRecords(limit: nil).first?.stockCode == "999999", "真实 record 保留")
        #expect(c.cache.listAvailable().isEmpty, "未 seed cache（保护真实安装）")
    }

    // codex-13b-R1：cache 空但 db 有真实 pending → seed 拒绝（pending guard），不覆盖真实会话与 settings。
    @Test("全空 guard：cache 空但 db 有真实 pending/settings → seed no-op，不覆盖")
    func seed_refusesWhenPendingExists() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: false)
        let realSettings = AppSettings(commissionRate: 0.0009, minCommissionEnabled: true,
                                       totalCapital: 555_555, displayMode: .system)
        try c.db.saveSettings(realSettings)
        let realPending = PendingTraining(
            trainingSetFilename: "real-user-set.sqlite", globalTickIndex: 7,
            upperPeriod: .m3, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(PositionManager()), cashBalance: 9_999,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0009, minCommissionEnabled: true),
            tradeOperations: [], drawings: [], startedAt: 100,
            accumulatedCapital: 9_999, drawdown: DrawdownAccumulator(peakCapital: 9_999, maxDrawdown: 0),
            sessionKey: "real-user-session")
        try c.db.savePending(realPending)
        #expect(c.cache.listAvailable().isEmpty)

        try AppContainer.seedDebugFixtures(db: c.db, cache: c.cache)

        #expect(try c.db.loadPending()?.sessionKey == "real-user-session", "真实 pending 未被 fixture 覆盖")
        #expect(try c.db.loadSettings().totalCapital == 555_555, "真实 settings 未被 fixture 覆盖")
        #expect(c.cache.listAvailable().isEmpty, "未 seed cache")
    }
}
#endif
