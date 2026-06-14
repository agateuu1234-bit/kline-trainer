import Foundation
@testable import KlineTrainerContracts

/// Wave 3 顺位 10b 持久化集成测试共享 fixture（与 10a TrainingSessionPersistenceTests 同构）。
@MainActor
enum PIFixtures {

    /// 无参 Normal coordinator + 三 fake（autosave/fence/discard/cross-feature 复用）。
    static func makeCoordinator(capital: Double = 50_000)
        -> (TrainingSessionCoordinator, InMemoryRecordRepository,
            InMemoryPendingTrainingRepository, InMemorySessionFinalizationPort) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let cache = InMemoryCacheManager()
        cache._seedForTesting([TrainingSessionPersistenceTests.cachedFile()])
        let coord = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: TrainingSessionPersistenceTests.validCandles()),
            recordRepo: records, pendingRepo: pending, finalization: port,
            settingsDAO: InMemorySettingsDAO(), cache: cache,
            settings: SettingsStore(settingsDAO: TrainingSessionPersistenceTests.CapitalDAO(capital: capital)))
        return (coord, records, pending, port)
    }

    /// provenance coordinator：多缓存文件 + 损坏/错误注入 + 确定性 pick（按 filename 升序，删后顺移）。
    static func makeProvenanceCoordinator(files: [String], corrupt: Set<String>, openError: AppError? = nil)
        -> (TrainingSessionCoordinator, PreviewTrainingSetDBFactory,
            InMemoryCacheManager, InMemoryPendingTrainingRepository) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let cache = InMemoryCacheManager()
        cache._seedForTesting(files.map { Self.file(filename: $0) })
        cache.pickOverride = { fs in fs.sorted { $0.filename < $1.filename }.first }   // 确定性
        let factory = PreviewTrainingSetDBFactory(
            candles: TrainingSessionPersistenceTests.validCandles(),
            corruptFilenames: corrupt, openErrorAll: openError)   // knob 经 init（struct，禁后赋值）
        let coord = TrainingSessionCoordinator(
            dbFactory: factory, recordRepo: records, pendingRepo: pending, finalization: port,
            settingsDAO: InMemorySettingsDAO(), cache: cache,
            settings: SettingsStore(settingsDAO: TrainingSessionPersistenceTests.CapitalDAO(capital: 50_000)))
        return (coord, factory, cache, pending)
    }

    /// localURL.lastPathComponent == filename（使 corruptFilenames 与 cache.delete 字段一致，D8 M1）。
    /// 真实 init（AppState.swift:142）：id 是 Int（非 Int64）；mirror cachedFile() /tmp 约定。
    static func file(filename: String) -> TrainingSetFile {
        TrainingSetFile(id: abs(filename.hashValue), filename: filename,
                        localURL: URL(fileURLWithPath: "/tmp/\(filename)"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    /// 一条样本画线（真实 init Models.swift:202，plan-review R2-1f；复用 10a 具体样本）。
    static func sampleDrawing() -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.4)],
                      isExtended: false, panelPosition: 0)
    }
}
