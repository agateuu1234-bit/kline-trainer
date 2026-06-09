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

    public init(config: AppConfig) throws {
        let api = DefaultAPIClient(baseURL: config.backendBaseURL)
        let db = try DefaultAppDB(dbPath: config.dbPath)                  // 唯一 throws 点（migration/IO）
        let cache = DefaultFileSystemCacheManager(cacheRoot: config.cacheRootDir)
        let dbFactory = DefaultTrainingSetDBFactory()
        let settings = SettingsStore(settingsDAO: db)                     // db 同时是 SettingsDAO
        let acceptance = DownloadAcceptanceRunner(
            api: api, cache: cache, dbFactory: dbFactory, journal: db,
            integrity: DefaultZipIntegrityVerifier(), extractor: DefaultZipExtractor(),
            dataVerifier: DefaultTrainingSetDataVerifier(), cleaner: DefaultDownloadAcceptanceCleaner())
        let coordinator = TrainingSessionCoordinator(
            dbFactory: dbFactory, recordRepo: db, pendingRepo: db,
            settingsDAO: db, cache: cache, settings: settings)
        let router = AppRouter(coordinator: coordinator, settings: settings, acceptance: acceptance,
                               recordRepo: db, pendingRepo: db, cache: cache)
        self.api = api; self.db = db; self.cache = cache; self.settings = settings
        self.acceptance = acceptance; self.coordinator = coordinator; self.router = router
    }
}
