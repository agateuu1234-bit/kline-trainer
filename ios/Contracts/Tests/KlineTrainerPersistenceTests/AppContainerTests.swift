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
}
