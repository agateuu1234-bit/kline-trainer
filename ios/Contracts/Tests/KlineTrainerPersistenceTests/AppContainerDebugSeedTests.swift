import Testing
import Foundation
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

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

    @Test("未 seed（debugSeedFixtures:false）：cache/records/pending 皆空（对照，证 seed 测非 vacuous）")
    func noSeed_isEmptyProgress() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: false)
        #expect(c.cache.listAvailable().isEmpty)
        #expect(try c.db.statistics().totalCount == 0)   // 区分：seeded 测断言 >= 2
        #expect(try c.db.loadPending() == nil)           // 区分：seeded 测断言 != nil
        #expect(c.settings.settings.totalCapital == 100_000)  // #6：空库现也默认 10 万（非 0）
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

    // codex-13b-R2-F1：seeded 训练组须能 fresh start（make 默认上区 .m60/下区 .daily 非空）。
    @Test("seeded 训练组：startNewNormalSession（默认 .m60/.daily）成功开局")
    func seed_freshStartSucceeds() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: true)
        let engine = try await c.coordinator.startNewNormalSession()
        #expect(engine.upperPanel.period == .m60)
        #expect(engine.lowerPanel.period == .daily)
    }

    // codex-13b-R2-F1：seeded 训练组须能 review + replay 既有 record（全 6 周期 → make 默认 panel 可开）。
    @Test("seeded 训练组：review + replay 既有 record 成功")
    func seed_reviewAndReplaySucceed() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: true)
        let recId = try c.db.listRecords(limit: nil).first!.id!
        let reviewEngine = try await c.coordinator.review(recordId: recId)
        #expect(reviewEngine.flow.mode == .review)
        await c.coordinator.endSession()
        let replayEngine = try await c.coordinator.replay(recordId: recId)
        #expect(replayEngine.flow.mode == .replay)
    }

    // codex-13b-R2-F2：cache/history/pending 全空但 settings 被自定义 → seed 拒绝（不覆盖 settings）。
    @Test("全空 guard：仅 settings 被自定义（cache/history/pending 空）→ seed no-op 不覆盖")
    func seed_refusesWhenOnlySettingsCustomized() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: false)
        try c.db.saveSettings(AppSettings(commissionRate: 0.0007, minCommissionEnabled: true,
                                          totalCapital: 333_333, displayMode: .system))
        #expect(c.cache.listAvailable().isEmpty)
        #expect(try c.db.statistics().totalCount == 0)
        #expect(try c.db.loadPending() == nil)

        try AppContainer.seedDebugFixtures(db: c.db, cache: c.cache)

        #expect(try c.db.loadSettings().totalCapital == 333_333, "自定义 settings 未被 fixture 覆盖")
        #expect(c.cache.listAvailable().isEmpty, "未 seed")
    }

    // Task 5 Medium-10：运行时 #1 端到端真协调器路径。
    // seeded（有记录+pending+cache）→ resetAllProgress（清记录/pending，cache 保留）
    // → startNewNormalSession（cache 仍在可开局）→ 零记录使 startingCapital 走 settings 分支 → 顶栏 10 万。
    @Test("重置后开新局：startingCapital 走 settings=10 万（真协调器路径）")
    func test_after_reset_freshStart_startsAtDefault() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: true)
        #expect(try c.db.statistics().totalCount >= 2)        // 前置：seed 有记录
        try await c.settings.resetAllProgress()
        #expect(try c.db.statistics().totalCount == 0)        // 记录已清
        #expect(try c.db.loadPending() == nil)                // pending 已清
        #expect(!c.cache.listAvailable().isEmpty)             // cache 保留（可开局）
        let engine = try await c.coordinator.startNewNormalSession()
        // currentTotalCapital = cashBalance + shares*price；开局无持仓 → = 起始资金。
        #expect(engine.currentTotalCapital == 100_000)
    }

    // 13c-R2 根治端到端：实际 seeded + cached 的训练组（= 帧预算 runbook 真正剖析的那份）须满载。
    // 直接打开缓存 sqlite，loadAllCandles() 验每周期渲染负载——证 seed 调用点确用满载根数（非仅 make 能力）。
    @Test("seeded 缓存 fixture 满载：每周期 ≥ defaultVisibleCount(80)，默认面板 .m60/.daily ≥ maxVisibleCount(240)")
    func seededFixture_isFullLoad() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: true)
        let file = c.cache.listAvailable().first!
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: file.localURL, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let byPeriod = try reader.loadAllCandles()
        for period in Period.allCases {
            let count = byPeriod[period]?.count ?? 0
            #expect(count >= RenderStateBuilder.defaultVisibleCount,
                    "seeded 周期 \(period) 蜡烛数 \(count) 须 ≥ defaultVisibleCount(\(RenderStateBuilder.defaultVisibleCount))")
        }
        #expect((byPeriod[.m60]?.count ?? 0) >= PinchZoomModel.maxVisibleCount,
                "seeded .m60 须 ≥ maxVisibleCount(\(PinchZoomModel.maxVisibleCount))")
        #expect((byPeriod[.daily]?.count ?? 0) >= PinchZoomModel.maxVisibleCount,
                "seeded .daily 须 ≥ maxVisibleCount(\(PinchZoomModel.maxVisibleCount))")
    }
}
#endif
