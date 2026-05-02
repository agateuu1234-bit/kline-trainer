// Kline Trainer Swift Contracts — Wave 0 In-Memory Fakes for E6.preview() path
// Spec: kline_trainer_modules_v1.4.md §11.3 Test Fixture Ports list (line 2195-2206)
// 本 PR 只落 5 个 E6.preview() 调用路径上的 fake；其余 6 个属 PR 5 Fixture/Mock Ports
// `#if DEBUG` 包裹与 spec line 1671-1713 preview Fixture 一致：fakes 不进 Release binary

#if DEBUG

import Foundation

// MARK: - P3a fake

public struct PreviewTrainingSetDBFactory: TrainingSetDBFactory {
    public init() {}
    public func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
        fatalError("Wave 0 fake: not exercised in preview path")
    }
}

// MARK: - P4 fakes

public final class InMemoryRecordRepository: RecordRepository, @unchecked Sendable {
    public init() {}
    public func insertRecord(_: TrainingRecord, ops: [TradeOperation], drawings: [DrawingObject]) throws -> Int64 {
        fatalError("Wave 0 fake: not exercised in preview path")
    }
    public func listRecords(limit: Int?) throws -> [TrainingRecord] { [] }
    public func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) {
        fatalError("Wave 0 fake: not exercised in preview path")
    }
    public func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) { (0, 0, 0) }
}

public final class InMemoryPendingTrainingRepository: PendingTrainingRepository, @unchecked Sendable {
    public init() {}
    public func savePending(_: PendingTraining) throws {}
    public func loadPending() throws -> PendingTraining? { nil }
    public func clearPending() throws {}
}

public final class InMemorySettingsDAO: SettingsDAO, @unchecked Sendable {
    public init() {}
    public func loadSettings() throws -> AppSettings {
        // zero-value 让 SettingsStore.preview() 能 succeed
        AppSettings(commissionRate: 0,
                    minCommissionEnabled: false,
                    totalCapital: 0,
                    displayMode: .system)
    }
    public func saveSettings(_: AppSettings) throws {}
    public func resetCapital() throws {}
}

// MARK: - P5 fake

public final class InMemoryCacheManager: CacheManager, @unchecked Sendable {
    public init() {}
    public func listAvailable() -> [TrainingSetFile] { [] }
    public func pickRandom() -> TrainingSetFile? { nil }
    public func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile {
        fatalError("Wave 0 fake: not exercised in preview path")
    }
    public func touch(_: TrainingSetFile) {}
    public func delete(_: TrainingSetFile) throws {}
}

#endif
