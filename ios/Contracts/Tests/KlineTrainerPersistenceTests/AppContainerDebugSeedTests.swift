import Testing
import Foundation
@testable import KlineTrainerPersistence
import KlineTrainerContracts

#if DEBUG
@Suite("AppContainer debug seed：经真 DefaultAppDB+cache 落库，loadHome 非空、可恢复、可开局（§C）")
@MainActor
struct AppContainerDebugSeedTests {

    private func makeContainer() throws -> (AppContainer, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeedTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = AppConfig(dbPath: dir.appendingPathComponent("app.sqlite"),
                            cacheRootDir: dir.appendingPathComponent("training-sets"),
                            backendBaseURL: URL(string: "http://debug.local")!)
        return (try AppContainer(config: cfg), dir)
    }

    @Test("seed 后：cache 非空 + history 非空 + pending 可恢复")
    func seed_populatesCachePendingHistory() async throws {
        let (c, dir) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        try c.seedDebugFixturesIfEmpty()
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
    }

    @Test("幂等：已 seed（cache 非空）再调 → no-op，不叠加")
    func seed_idempotent() async throws {
        let (c, dir) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        try c.seedDebugFixturesIfEmpty()
        let recCount1 = try c.db.listRecords(limit: nil).count
        let cacheCount1 = c.cache.listAvailable().count
        try c.seedDebugFixturesIfEmpty()
        #expect(try c.db.listRecords(limit: nil).count == recCount1, "幂等：records 不叠加")
        #expect(c.cache.listAvailable().count == cacheCount1, "幂等：cache 不叠加")
    }

    @Test("seed 的训练组可真开局（resumePending 重建引擎）")
    func seed_pendingResumable() async throws {
        let (c, dir) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        try c.seedDebugFixturesIfEmpty()
        let engine = try await c.coordinator.resumePending()
        #expect(engine != nil)
    }
}
#endif
