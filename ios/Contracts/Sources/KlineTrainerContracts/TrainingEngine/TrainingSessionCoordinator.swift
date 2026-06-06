// Kline Trainer Swift Contracts — E6 TrainingSessionCoordinator (Wave 0 契约 + preview)
// Spec: kline_trainer_modules_v1.4.md §E6 (line 1623-1700)
// Wave 0 范围：class + init + 7 方法签名（fatalError 体）+ static func preview()
// TrainingEnginePreviewFactory（TrainingEngine.preview(mode:)）：spec line 2111，
//   依赖 Wave 2 E5 完整 init + E4 flows，dep-graph 阻塞，本 PR 不交付

import Foundation

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

    /// 开始新 Normal 训练（spec L1664）：fail-closed 取费 → 随机选训练组 → 打开 reader →
    /// 累计本金构造 NormalFlow 引擎。loadError 时早抛、零副作用（D2/D9）。
    /// **前置（D10）**：caller 须先 `endSession()` 关闭上一 session 的 reader，否则上一
    /// `activeReader` 被覆盖泄漏（E6a 不替前一 session 收尾——E6b/caller 契约）。
    public func startNewNormalSession() async throws -> TrainingEngine {
        let fees = try settings.snapshotFeesIfReady()        // D2 fail-closed：loadError → throw（reader 未开）
        guard let file = cache.pickRandom() else {
            throw AppError.trainingSet(.fileNotFound)         // 无可用缓存训练组
        }
        let start = try startingCapital()                    // D4 累计模型（reader 未开，throw 无副作用）
        let reader = try openReader(for: file)
        do {
            let allCandles = try reader.loadAllCandles()
            let mt = try maxTick(from: allCandles)            // D3
            let engine = try TrainingEngine.make(
                .normal(fees: fees, maxTick: mt),
                allCandles: allCandles,
                initialCapital: start, initialCashBalance: start)
            activeReader = reader
            activeEngine = engine
            return engine
        } catch {
            reader.close()                                   // D9：失败关闭已开 reader，不留半态
            // D11 M0.4：单表达式可静态证明类型（禁裸变量 `throw error`，m04 gate 规则1）
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
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

    // MARK: - 私有构造 helper（E6a）

    /// D4：新局起始资金 = 累计模型。有记录 → 末条 total_capital+profit；无记录 → settings 配置本金。
    private func startingCapital() throws -> Double {
        let stats = try recordRepo.statistics()
        return stats.totalCount > 0 ? stats.currentCapital : settings.settings.totalCapital
    }

    /// D8：按 M0.1 schema 版本打开训练组（每次新 reader 实例，spec L1830）。
    private func openReader(for file: TrainingSetFile) throws -> TrainingSetReader {
        // M0.1 TRAINING_SET_SCHEMA_VERSION = 1（modules L1847/L2202）。E6a 硬编码避免与并行
        // 顺位 6 P2 PR 重复定义共享常量致编译冲突；shared-constant 单一 owner 见 PR body（residual E6a-R1）。
        try dbFactory.openAndVerify(file: file.localURL, expectedSchemaVersion: 1)
    }

    /// D3：从已校验 candle 取 maxTick = .m3 末根 endGlobalIndex（连续轴 = count-1）。
    /// .m3 缺/空 → 可恢复 .emptyData（make 也二次校验，但 FlowInput.normal/.replay 需先得 maxTick）。
    private func maxTick(from allCandles: [Period: [KLineCandle]]) throws -> Int {
        guard let m3 = allCandles[.m3], let last = m3.last else {
            throw AppError.trainingSet(.emptyData)
        }
        return last.endGlobalIndex
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
