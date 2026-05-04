// Kline Trainer Swift Contracts — P6 SettingsStore (PR4b 生产实现)
// Spec: kline_trainer_modules_v1.4.md §P6 (line 1970-1983)
// Plan: docs/superpowers/plans/2026-05-04-pr4b-cache-settings.md §6.1-§6.3
//
// 设计要点（R1-R6 codex review 修订）：
// - init eager-load via settingsDAO.loadSettings()；任意 load 失败 → zero-default + loadError 阻塞写
// - update / resetCapital 用 inflight Task chain 串行化；snapshot value type 防写丢
// - update closure 标 `@escaping @Sendable`（Swift 6 strict concurrency 必需）
// - snapshotFees 保留 fail-open（UI 显示路径）；snapshotFeesIfReady throws on loadError（trading flow 必须用）

import os.log

#if canImport(Observation)
import Observation
#endif

@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: AppSettings

    private let settingsDAO: SettingsDAO
    private var pendingMutations: Task<Void, Error>?
    /// R2 H-3 + R3 H-1 + R4 H-1：所有 load 失败（含 dbCorrupted）都阻塞写。
    /// R5 H-1：暴露为 public read-only，让 caller (E6/E5) 在调 snapshotFees / 进 trade flow 前 guard。
    private var _loadError: AppError?
    public var loadError: AppError? { _loadError }

    private static let zeroDefault = AppSettings(
        commissionRate: 0, minCommissionEnabled: false,
        totalCapital: 0, displayMode: .system)

    public init(settingsDAO: SettingsDAO) {
        self.settingsDAO = settingsDAO
        do {
            self.settings = try settingsDAO.loadSettings()
        } catch {
            // R4 H-1: 任何错误（含 dbCorrupted）都设 loadError 阻塞写
            // SettingsDAO 是 key-value，dbCorrupted 可能伴随部分合法 keys；conservative 阻塞防 silent 覆盖
            // 用户恢复路径：重启 app 重新 load；极端情况靠 Wave 2 U4 显式 reset 按钮（本 PR 不做）
            self.settings = SettingsStore.zeroDefault
            self._loadError = (error as? AppError)
                ?? .internalError(module: "P6", detail: String(describing: error))
            Logger(subsystem: "kline.trainer", category: "settings").error(
                "loadSettings: blocked write (loadError set): \(String(describing: error), privacy: .public)")
        }
    }

    public func update(_ mutate: @escaping @Sendable (inout AppSettings) -> Void) async throws {
        if let e = _loadError { throw e }  // R2 H-3 + R4 H-1: block writes 直到 reload 成功
        let prev = pendingMutations
        let task = Task { [weak self, mutate] in
            _ = try? await prev?.value  // 等前一个完成（错误不级联）
            guard let self = self else { return }
            var copy = self.settings
            mutate(&copy)
            let snapshot = copy
            let dao = self.settingsDAO
            try await Task.detached(priority: .userInitiated) {
                try dao.saveSettings(snapshot)
            }.value
            self.settings = snapshot
        }
        pendingMutations = task
        try await task.value
    }

    public func resetCapital() async throws {
        if let e = _loadError { throw e }  // R2 H-3 + R4 H-1: block writes 直到 reload 成功
        let prev = pendingMutations
        let task = Task { [weak self] in
            _ = try? await prev?.value
            guard let self = self else { return }
            let dao = self.settingsDAO
            try await Task.detached(priority: .userInitiated) {
                try dao.resetCapital()
            }.value
            self.settings.totalCapital = 0
        }
        pendingMutations = task
        try await task.value
    }

    public func snapshotFees() -> FeeSnapshot {
        // R5 H-1 defense-in-depth: caller 应 guard loadError；这里仅 log 不抛
        if let e = _loadError {
            Logger(subsystem: "kline.trainer", category: "settings").error(
                "snapshotFees called while loadError set (caller bug): \(String(describing: e), privacy: .public)")
        }
        return FeeSnapshot(commissionRate: settings.commissionRate,
                           minCommissionEnabled: settings.minCommissionEnabled)
    }

    /// R6 H-1: trading-flow caller (Wave 2 E5/E6) 必须用此 enforced 变体；
    /// loadError 状态下 throws，避免基于 zero fees 误算 P&L。
    public func snapshotFeesIfReady() throws -> FeeSnapshot {
        if let e = _loadError { throw e }
        return snapshotFees()
    }
}

// MARK: - Preview Fixture (spec line 1689-1700 配套；依赖 InMemorySettingsDAO from PreviewFakes)

#if DEBUG
@MainActor
extension SettingsStore {
    public static func preview() -> SettingsStore {
        SettingsStore(settingsDAO: InMemorySettingsDAO())
    }
}
#endif
