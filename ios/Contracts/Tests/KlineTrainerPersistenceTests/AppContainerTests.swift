import Testing
import Foundation
@testable import KlineTrainerPersistence
import KlineTrainerContracts

@MainActor
@Suite("AppContainer")
struct AppContainerTests {
    static func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("有效 config → 依赖图实例化（router 可达）+ 不抛")
    func validConfig_buildsGraph() throws {
        let dir = Self.tmpDir()
        let cfg = AppConfig(dbPath: dir.appendingPathComponent("app.sqlite"),
                            cacheRootDir: dir.appendingPathComponent("cache"),
                            backendBaseURL: URL(string: "http://kline-trainer.local")!)
        let container = try AppContainer(config: cfg)
        _ = container.router          // 预建 router 可达
        _ = container.coordinator
        _ = container.acceptance
    }

    @Test("DB 路径不可写 → init throws（DefaultAppDB 上抛）")
    func badDBPath_throws() {
        let cfg = AppConfig(dbPath: URL(fileURLWithPath: "/nonexistent-root-xyz/app.sqlite"),
                            cacheRootDir: FileManager.default.temporaryDirectory,
                            backendBaseURL: URL(string: "http://x.local")!)
        #expect(throws: (any Error).self) { _ = try AppContainer(config: cfg) }
    }

    // Task 5 — 接线集成验证：组合根已注入 TrainingResetPort，resetAllProgress 不抛「需注入端口」。
    @Test("AppContainer 接线：settings.resetAllProgress 已注入端口（不抛 internalError）")
    func settingsStore_resetAllProgress_wired() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResetWire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = AppConfig(dbPath: dir.appendingPathComponent("app.sqlite"),
                            cacheRootDir: dir.appendingPathComponent("training-sets"),
                            backendBaseURL: URL(string: "http://debug.local")!)
        let c = try AppContainer(config: cfg)
        let rec = TrainingRecord(
            id: nil, trainingSetFilename: "t.sqlite", createdAt: 1_735_689_600,
            stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
            totalCapital: 100_000, profit: 5_000, returnRate: 0.05, maxDrawdown: 0.1,
            buyCount: 1, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            finalTick: 40)
        _ = try c.db.insertRecord(rec, ops: [], drawings: [])
        try await c.settings.resetAllProgress()   // 未接端口会抛 internalError「需注入端口」
        #expect(try c.db.statistics().totalCount == 0)
        #expect(c.settings.settings.totalCapital == 100_000)
    }
}
