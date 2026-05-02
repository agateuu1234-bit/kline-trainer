import Testing
import Foundation
@testable import KlineTrainerContracts

// MARK: - 6 dep protocols 形状 conformance

@Suite("PersistenceProtocolsShape")
struct PersistenceProtocolsShapeTests {

    // P3a
    @Test("TrainingSetDBFactory: openAndVerify 签名照 spec line 1827")
    func dbFactoryShape() {
        struct Stub: TrainingSetDBFactory {
            func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
                fatalError("test stub")
            }
        }
        let _: TrainingSetDBFactory = Stub()
    }

    // P3b: protocol 是 AnyObject + Sendable，class stub 须显式 @unchecked Sendable
    // 否则 Swift 6 strict concurrency 会 warn（与 0-warnings gate 冲突）
    @Test("TrainingSetReader: AnyObject + Sendable + 3 方法照 spec line 1843")
    func readerShape() {
        final class Stub: TrainingSetReader, @unchecked Sendable {
            func loadMeta() throws -> TrainingSetMeta { fatalError() }
            func loadAllCandles() throws -> [Period: [KLineCandle]] { fatalError() }
            func close() {}
        }
        let _: any TrainingSetReader = Stub()
    }

    // P4 RecordRepository
    @Test("RecordRepository: Sendable + 4 方法照 spec line 1870")
    func recordRepoShape() {
        struct Stub: RecordRepository {
            func insertRecord(_: TrainingRecord, ops: [TradeOperation], drawings: [DrawingObject]) throws -> Int64 { fatalError() }
            func listRecords(limit: Int?) throws -> [TrainingRecord] { [] }
            func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) { fatalError() }
            func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) { (0, 0, 0) }
        }
        let _: any RecordRepository = Stub()
    }

    // P4 PendingTrainingRepository
    @Test("PendingTrainingRepository: Sendable + 3 方法照 spec line 1879")
    func pendingRepoShape() {
        struct Stub: PendingTrainingRepository {
            func savePending(_: PendingTraining) throws {}
            func loadPending() throws -> PendingTraining? { nil }
            func clearPending() throws {}
        }
        let _: any PendingTrainingRepository = Stub()
    }

    // P4 SettingsDAO —— init 签名按 baseline grep 实测对齐
    // AppState.swift baseline: AppSettings(commissionRate:minCommissionEnabled:totalCapital:displayMode:)
    @Test("SettingsDAO: Sendable + 3 方法照 spec line 1885")
    func settingsDAOShape() {
        struct Stub: SettingsDAO {
            func loadSettings() throws -> AppSettings {
                AppSettings(commissionRate: 0,
                            minCommissionEnabled: false,
                            totalCapital: 0,
                            displayMode: .system)
            }
            func saveSettings(_: AppSettings) throws {}
            func resetCapital() throws {}
        }
        let _: any SettingsDAO = Stub()
    }

    // P5 CacheManager
    @Test("CacheManager: 5 方法照 spec line 1953")
    func cacheManagerShape() {
        struct Stub: CacheManager {
            func listAvailable() -> [TrainingSetFile] { [] }
            func pickRandom() -> TrainingSetFile? { nil }
            func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile { fatalError() }
            func touch(_: TrainingSetFile) {}
            func delete(_: TrainingSetFile) throws {}
        }
        let _: any CacheManager = Stub()
    }
}

@MainActor
@Suite("SettingsStoreShape")
struct SettingsStoreShapeTests {

    private struct StubDAO: SettingsDAO {
        func loadSettings() throws -> AppSettings {
            AppSettings(commissionRate: 0.0001,
                        minCommissionEnabled: false,
                        totalCapital: 0,
                        displayMode: .system)
        }
        func saveSettings(_: AppSettings) throws {}
        func resetCapital() throws {}
    }

    @Test("init(settingsDAO:) 签名照 spec line 1979 编译")
    func initSignature() {
        let store = SettingsStore(settingsDAO: StubDAO())
        // settings 默认值取自 stub init 内部初始化（Wave 0 stub：zero-value AppSettings）
        // Wave 2 P6 PR 改为 init 内 try? settingsDAO.loadSettings() 实际加载
        _ = store
    }

    @Test("snapshotFees() 签名 -> FeeSnapshot")
    func snapshotFeesSignature() {
        let store = SettingsStore(settingsDAO: StubDAO())
        let _: FeeSnapshot = store.snapshotFees()
    }

    @Test("update / resetCapital 签名编译期解析（不调用 fatalError 体）")
    func mutatorSignatures() {
        let store = SettingsStore(settingsDAO: StubDAO())
        let _: ((inout AppSettings) -> Void) async throws -> Void = store.update
        let _: () async throws -> Void = store.resetCapital
    }
}

@MainActor
@Suite("TrainingEngineShell")
struct TrainingEngineShellTests {

    @Test("TrainingEngine 类型存在且 @MainActor 可解析")
    func typeExists() {
        // 本 stub 不可外部实例化（fileprivate init 触发 fatalError）；
        // 只验类型存在，能作为 TSC 方法返回值类型
        let _: TrainingEngine.Type = TrainingEngine.self
    }
}

@Suite("InMemoryFakes")
struct InMemoryFakesTests {

    @Test("PreviewTrainingSetDBFactory 实例化")
    func dbFactoryInstantiates() {
        let _: any TrainingSetDBFactory = PreviewTrainingSetDBFactory()
    }

    @Test("InMemoryRecordRepository.listRecords 返回空 / statistics 返回零")
    func recordRepoDefaults() throws {
        let repo = InMemoryRecordRepository()
        #expect(try repo.listRecords(limit: nil).isEmpty)
        let stats = try repo.statistics()
        #expect(stats.totalCount == 0)
        #expect(stats.winCount == 0)
        #expect(stats.currentCapital == 0)
    }

    @Test("InMemoryPendingTrainingRepository.loadPending 返回 nil")
    func pendingRepoDefault() throws {
        let repo = InMemoryPendingTrainingRepository()
        #expect(try repo.loadPending() == nil)
    }

    @Test("InMemorySettingsDAO.loadSettings 返回 zero-value AppSettings")
    func settingsDAODefault() throws {
        let dao = InMemorySettingsDAO()
        let s = try dao.loadSettings()
        #expect(s.commissionRate == 0)
        #expect(s.totalCapital == 0)
        #expect(s.displayMode == .system)
    }

    @Test("InMemoryCacheManager.listAvailable 返回空 / pickRandom 返回 nil")
    func cacheManagerDefaults() {
        let cache = InMemoryCacheManager()
        #expect(cache.listAvailable().isEmpty)
        #expect(cache.pickRandom() == nil)
    }
}

@MainActor
@Suite("TrainingSessionCoordinatorShape")
struct TrainingSessionCoordinatorShapeTests {

    // 复用 Task 4 in-memory fakes 构造 TSC
    private func makeCoordinator() -> TrainingSessionCoordinator {
        TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(),
            recordRepo: InMemoryRecordRepository(),
            pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(),
            cache: InMemoryCacheManager(),
            settings: SettingsStore(settingsDAO: InMemorySettingsDAO())
        )
    }

    @Test("init 6 参数签名照 spec line 1639-1644 编译 + 初始 active state 为 nil")
    func initSignature() {
        let coord = makeCoordinator()
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    // 7 个方法签名编译期解析（不调用 fatalError 体）
    @Test("startNewNormalSession() async throws -> TrainingEngine 签名")
    func startNewSignature() {
        let coord = makeCoordinator()
        let _: () async throws -> TrainingEngine = coord.startNewNormalSession
    }

    @Test("resumePending() async throws -> TrainingEngine? 签名")
    func resumeSignature() {
        let coord = makeCoordinator()
        let _: () async throws -> TrainingEngine? = coord.resumePending
    }

    @Test("review(recordId:) async throws -> TrainingEngine 签名")
    func reviewSignature() {
        let coord = makeCoordinator()
        let _: (Int64) async throws -> TrainingEngine = coord.review
    }

    @Test("replay(recordId:) async throws -> TrainingEngine 签名")
    func replaySignature() {
        let coord = makeCoordinator()
        let _: (Int64) async throws -> TrainingEngine = coord.replay
    }

    @Test("saveProgress(engine:) async throws 签名")
    func saveProgressSignature() {
        let coord = makeCoordinator()
        let _: (TrainingEngine) async throws -> Void = coord.saveProgress
    }

    @Test("finalize(engine:) async throws -> Int64? 签名")
    func finalizeSignature() {
        let coord = makeCoordinator()
        let _: (TrainingEngine) async throws -> Int64? = coord.finalize
    }

    @Test("endSession() async 签名（spec line 1666 不 throws）")
    func endSessionSignature() {
        let coord = makeCoordinator()
        let _: () async -> Void = coord.endSession
    }

    // spec line 1689-1700 TSC.preview() smoke
    @Test("TrainingSessionCoordinator.preview() 构造成功 + 初始 active state 为 nil")
    func previewSmoke() {
        let coord = TrainingSessionCoordinator.preview()
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }
}
