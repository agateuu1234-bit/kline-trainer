// Kline Trainer Swift Contracts — E6 TrainingSessionCoordinator (Wave 0 契约 + preview)
// Spec: kline_trainer_modules_v1.4.md §E6 (line 1623-1700)
// Wave 0 范围：class + init + 7 方法签名（fatalError 体）+ static func preview()
// TrainingEnginePreviewFactory（TrainingEngine.preview(mode:)）：spec line 2111，
//   依赖 Wave 2 E5 完整 init + E4 flows，dep-graph 阻塞，本 PR 不交付

#if canImport(Observation)
import Observation
#endif

@MainActor
@Observable
public final class TrainingSessionCoordinator {
    private let dbFactory: TrainingSetDBFactory       // P3a
    private let recordRepo: RecordRepository          // P4
    private let pendingRepo: PendingTrainingRepository // P4
    private let settingsDAO: SettingsDAO              // P4
    private let cache: CacheManager                   // P5
    private let settings: SettingsStore               // P6

    public private(set) var activeEngine: TrainingEngine?
    public private(set) var activeReader: (any TrainingSetReader)?

    public init(dbFactory: TrainingSetDBFactory,
                recordRepo: RecordRepository,
                pendingRepo: PendingTrainingRepository,
                settingsDAO: SettingsDAO,
                cache: CacheManager,
                settings: SettingsStore) {
        self.dbFactory = dbFactory
        self.recordRepo = recordRepo
        self.pendingRepo = pendingRepo
        self.settingsDAO = settingsDAO
        self.cache = cache
        self.settings = settings
        self.activeEngine = nil
        self.activeReader = nil
    }

    /// 开始新 Normal 训练（spec line 1647）
    public func startNewNormalSession() async throws -> TrainingEngine {
        fatalError("Wave 2 E6 impl")
    }

    /// 继续中断训练（spec line 1650）
    public func resumePending() async throws -> TrainingEngine? {
        fatalError("Wave 2 E6 impl")
    }

    /// Review 模式（spec line 1653）
    public func review(recordId: Int64) async throws -> TrainingEngine {
        fatalError("Wave 2 E6 impl")
    }

    /// Replay 模式（spec line 1656）
    public func replay(recordId: Int64) async throws -> TrainingEngine {
        fatalError("Wave 2 E6 impl")
    }

    /// 保存进度（spec line 1659）
    public func saveProgress(engine: TrainingEngine) async throws {
        fatalError("Wave 2 E6 impl")
    }

    /// 正式结束（spec line 1663）
    public func finalize(engine: TrainingEngine) async throws -> Int64? {
        fatalError("Wave 2 E6 impl")
    }

    /// session 结束清理（spec line 1666，不 throws）
    public func endSession() async {
        fatalError("Wave 2 E6 impl")
    }
}

// MARK: - Preview Fixture (spec line 1689-1700)

#if DEBUG
@MainActor
extension TrainingSessionCoordinator {
    public static func preview() -> TrainingSessionCoordinator {
        TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(),
            recordRepo: InMemoryRecordRepository(),
            pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(),
            cache: InMemoryCacheManager(),
            settings: SettingsStore.preview()
        )
    }
}
#endif
