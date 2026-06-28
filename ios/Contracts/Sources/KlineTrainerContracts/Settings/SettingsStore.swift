// Kline Trainer Swift Contracts — P6 SettingsStore (PR4b 生产实现)
// Spec: kline_trainer_modules_v1.4.md §P6 (line 1970-1983)
// Plan: docs/superpowers/plans/2026-05-04-pr4b-cache-settings.md §6.1-§6.3
//
// 设计要点（R1-R6 codex review 修订）：
// - init eager-load via settingsDAO.loadSettings()；任意 load 失败 → zero-default + loadError 阻塞写
// - update / resetAllProgress 用 inflight Task chain 串行化；snapshot value type 防写丢
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
    private let resetPort: TrainingResetPort?
    private var pendingMutations: Task<Void, Error>?
    /// R2 H-3 + R3 H-1 + R4 H-1：所有 load 失败（含 dbCorrupted）都阻塞写。
    /// R5 H-1：暴露为 public read-only，让 caller (E6/E5) 在调 snapshotFees / 进 trade flow 前 guard。
    private var _loadError: AppError?
    public var loadError: AppError? { _loadError }
    /// Wave 2 顺位 1 RFC §四：retryReload() 失败后置位；forceResetAndReload 强制「先试 retryReload」顺序。
    private var _retryReloadFailed = false

    private static let zeroDefault = AppSettings(
        commissionRate: 0, minCommissionEnabled: false,
        totalCapital: 0, displayMode: .system)

    public init(settingsDAO: SettingsDAO, resetPort: TrainingResetPort? = nil) {
        self.settingsDAO = settingsDAO
        self.resetPort = resetPort
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
            // R-plan-22-1：提交缓存时保留**当前权威 total_capital**（detached save 期间 finalize/reset
            // 可能已推进）——override 旧快照/closure 对 total_capital 的任何改动，防偏好保存回滚权威资金。
            var committed = snapshot
            committed.totalCapital = self.settings.totalCapital
            self.settings = committed
        }
        pendingMutations = task
        try await task.value
    }

    /// A4：finalize/外部写库后把权威 total_capital 同步进活缓存（不再写库）。
    public func refreshTotalCapital(_ value: Double) {
        settings.totalCapital = value
    }

    /// 重置资金(运行时 #1)：经注入端口在单事务内**保留历史训练记录**、仅清未完成对局，
    /// 并把资金恢复为 AppSettings.defaultTotalCapital（RFC-A：reset 不再删记录）。
    /// 复用 loadError 写阻塞 + pendingMutations 串行化（与 update 同机制）。
    public func resetAllProgress() async throws {
        if let e = _loadError { throw e }   // block writes 直到 reload 成功
        // port 在进入 pendingMutations 链前同步取出并守卫（fail-fast：nil 端口立即抛，不排队）；
        // 端口副作用仍受下方 `guard let self else return` 闸门保护，self 释放即跳过（与 update() 一致）。
        guard let port = resetPort else {
            throw AppError.internalError(module: "P6", detail: "resetAllProgress 需注入 TrainingResetPort")
        }
        let prev = pendingMutations
        let task = Task { [weak self] in
            _ = try? await prev?.value
            guard let self = self else { return }
            try await Task.detached(priority: .userInitiated) { [port] in
                try port.resetAllTrainingProgress(toCapital: AppSettings.defaultTotalCapital)
            }.value
            self.settings.totalCapital = AppSettings.defaultTotalCapital
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

    // MARK: - Wave 2 顺位 1 RFC §四：loadError 两层恢复

    /// 仅 `.persistence(.dbCorrupted)` 是 corruption-class（数据真不可解，破坏才有意义）；
    /// diskFull/ioError/schemaMismatch 等一律 transient（不允许破坏）。
    private static func isDBCorrupted(_ error: AppError) -> Bool {
        if case .persistence(.dbCorrupted) = error { return true }
        return false
    }

    /// 非破坏性 transient 恢复（首选）。要求 loadError != nil；纯重读不写库。
    /// 成功 → MainActor 先 settings=loaded 再清 loadError+flag（保留 DB 真实用户设置）。
    /// 失败 → 置 _retryReloadFailed + 更新 _loadError 为本次最新错误（不留 stale init 错误）+ throws。
    public func retryReload() async throws {
        guard _loadError != nil else {
            throw AppError.internalError(module: "P6", detail: "retryReload 仅在 loadError 态可用")
        }
        let dao = self.settingsDAO
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try dao.loadSettings()
            }.value
            self.settings = loaded          // R2-high 不变量：先刷新 settings
            self._loadError = nil           // 再清错误位
            self._retryReloadFailed = false
        } catch {
            let appErr = (error as? AppError)
                ?? .internalError(module: "P6", detail: String(describing: error))
            self._retryReloadFailed = true
            self._loadError = appErr        // FR7：更新为最新错误，不留 stale
            throw appErr
        }
    }

    /// 破坏性 last-resort（仅持久损坏）。守卫编码进 state（非 prose 约定）：
    /// ① loadError != nil ② _retryReloadFailed == true（已先试 retryReload 且失败）
    /// ③ loadError 是 corruption-class .persistence(.dbCorrupted)。
    /// 任一不满足 → throws 且不调 saveSettings（零破坏；transient 走 retry-only）。
    /// 过门后破坏前最后非破坏 reload：成功（transient 已恢复）→ 保留真实设置不写库；
    /// 失败且 final error 也是 dbCorrupted → saveSettings(.default) → reload；
    /// 失败但 final 是 transient → 更新 loadError + throws + 不破坏（FR3 混合错误）。
    public func forceResetAndReload(confirmation: SettingsResetConfirmation) async throws {
        _ = confirmation  // deliberate-intent 信号（构造即意图）；真正数据安全靠下方守卫
        guard let entryError = _loadError else {
            throw AppError.internalError(module: "P6", detail: "forceReset 仅在 loadError 态可用")
        }
        guard _retryReloadFailed else {
            throw AppError.internalError(module: "P6", detail: "forceReset 须先失败的 retryReload")
        }
        guard Self.isDBCorrupted(entryError) else {
            throw entryError   // 非 dbCorrupted（transient）→ retry-only，零破坏
        }
        let dao = self.settingsDAO
        do {
            // 破坏前最后非破坏 reload
            let loaded = try await Task.detached(priority: .userInitiated) {
                try dao.loadSettings()
            }.value
            self.settings = loaded          // transient 已恢复：保留真实设置
            self._loadError = nil
            self._retryReloadFailed = false
            return                          // 零破坏（不 saveSettings）
        } catch {
            let finalError = (error as? AppError)
                ?? .internalError(module: "P6", detail: String(describing: error))
            guard Self.isDBCorrupted(finalError) else {
                self._loadError = finalError  // 混合错误：更新为 transient
                throw finalError              // 不破坏
            }
            // 确认持久损坏 → 破坏性 reset
            // R-plan-24-1：用 repairAllToDefaults（写全键含 total_capital），**不**用 saveSettings——
            // 单写者下 saveSettings 已豁免 total_capital，靠它修不掉腐坏/负 total_capital。
            try await Task.detached(priority: .userInitiated) {
                try dao.repairAllToDefaults()
            }.value                           // 写失败则抛出，_loadError 保留 dbCorrupted
            let reloaded = try await Task.detached(priority: .userInitiated) {
                try dao.loadSettings()
            }.value
            self.settings = reloaded
            self._loadError = nil
            self._retryReloadFailed = false
        }
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
