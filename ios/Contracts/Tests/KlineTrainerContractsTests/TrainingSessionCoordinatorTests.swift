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
