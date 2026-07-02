// Wave 2 顺位 11 — 生产组合根（spec 2026-06-08 §4.2）。
// 构造全部 Default* 具体依赖（只能落 Persistence，因 Contracts 不可 import Persistence）+ 预建 AppRouter。
import Foundation
import KlineTrainerContracts

@MainActor                          // 持 @MainActor props（settings/coordinator/router）；MainActor-confined（刻意非 Sendable）
public final class AppContainer {
    public let api: any APIClient
    public let db: any AppDB
    public let cache: any CacheManager
    public let settings: SettingsStore
    public let acceptance: DownloadAcceptanceRunner
    public let coordinator: TrainingSessionCoordinator
    public let router: AppRouter

    /// - Parameter debugSeedFixtures: `#if DEBUG` 全 app fixture provisioning 开关（默认关；Release 忽略）。
    ///   true 时在 SettingsStore 构造**前** seed，使其 eager-load 到 seeded settings（codex-13b-R3 stale 修）。
    public init(config: AppConfig, debugSeedFixtures: Bool = false) throws {
        let api = DefaultAPIClient(baseURL: config.backendBaseURL)
        let db = try DefaultAppDB(dbPath: config.dbPath)                  // 唯一 throws 点（migration/IO）
        let cache = DefaultFileSystemCacheManager(cacheRoot: config.cacheRootDir)
        let dbFactory = DefaultTrainingSetDBFactory()
        #if DEBUG
        // §C debug fixture provisioning：须在 SettingsStore 构造**前** seed（让其 eager-load 到 seeded
        // settings，解 codex-13b-R3 stale settings）。幂等 + 全空 guard（仅 cache+history+pending 全空才
        // seed，解 codex-13b-R1：iOS 可单独清 Caches 但留 app.sqlite → cache 空 ≠ fresh install，不破坏真实数据）。
        if debugSeedFixtures {
            try Self.seedDebugFixtures(db: db, cache: cache)
        }
        #endif
        let settings = SettingsStore(settingsDAO: db, resetPort: db)     // db 同时是 SettingsDAO + TrainingResetPort（seed 后 load 到 fixture settings）
        let acceptance = DownloadAcceptanceRunner(
            api: api, cache: cache, dbFactory: dbFactory, journal: db,
            integrity: DefaultZipIntegrityVerifier(), extractor: DefaultZipExtractor(),
            dataVerifier: DefaultTrainingSetDataVerifier(), cleaner: DefaultDownloadAcceptanceCleaner())
        let coordinator = TrainingSessionCoordinator(
            dbFactory: dbFactory, recordRepo: db, pendingRepo: db,
            pendingReplayRepo: db,
            reviewArchiveRepo: db,
            finalization: db,
            settingsDAO: db, cache: cache, settings: settings)
        let router = AppRouter(coordinator: coordinator, settings: settings, acceptance: acceptance,
                               recordRepo: db, pendingRepo: db, cache: cache)
        self.api = api; self.db = db; self.cache = cache; self.settings = settings
        self.acceptance = acceptance; self.coordinator = coordinator; self.router = router
    }
}
