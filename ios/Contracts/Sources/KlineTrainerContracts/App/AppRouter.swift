// Wave 2 顺位 11 — 生产组合根导航状态机（spec 2026-06-08 §4.3）。
// 平台无关纯逻辑（host 全测）：只依赖抽象端口，被 AppContainer(Persistence) 预建、AppRootView(Contracts) 驱动。
import Foundation
import Observation

@MainActor
@Observable
public final class AppRouter {
    public enum Modal: Identifiable {
        case settings
        case history(TrainingRecord)
        case settlement(TrainingRecord)
        public var id: String {
            switch self {
            case .settings:          return "settings"
            case .history(let r):    return "history-\(r.id ?? -1)"       // TrainingRecord.id 是 Int64?；持久 record 恒有 id，?? -1 仅消插值警告
            case .settlement(let r): return "settlement-\(r.id ?? -1)"
            }
        }
    }

    public struct ActiveTraining {
        public let lifecycle: TrainingSessionLifecycle
        public init(lifecycle: TrainingSessionLifecycle) { self.lifecycle = lifecycle }
    }

    private let coordinator: TrainingSessionCoordinator
    private let settings: SettingsStore
    private let acceptance: DownloadAcceptanceRunner
    private let recordRepo: any RecordRepository
    private let pendingRepo: any PendingTrainingRepository
    private let cache: any CacheManager

    public private(set) var homeContent: HomeContent
    public private(set) var activeTraining: ActiveTraining?
    public var activeModal: Modal?
    public private(set) var errorMessage: String?

    private var records: [TrainingRecord] = []
    private var didRunLaunchRecovery = false

    public init(coordinator: TrainingSessionCoordinator, settings: SettingsStore,
                acceptance: DownloadAcceptanceRunner, recordRepo: any RecordRepository,
                pendingRepo: any PendingTrainingRepository, cache: any CacheManager) {
        self.coordinator = coordinator
        self.settings = settings
        self.acceptance = acceptance
        self.recordRepo = recordRepo
        self.pendingRepo = pendingRepo
        self.cache = cache
        self.homeContent = AppRouter.emptyHome()
    }

    static func emptyHome() -> HomeContent {
        HomeContent(statistics: (totalCount: 0, winCount: 0, currentCapital: 0),
                    configuredCapital: 0, records: [], hasPending: false, hasCachedSets: false)
    }

    public func loadHome() async {
        do {
            let recs = try recordRepo.listRecords(limit: nil)
            let stats = try recordRepo.statistics()
            let hasPending = (try pendingRepo.loadPending()) != nil
            let hasCached = !cache.listAvailable().isEmpty
            self.records = recs
            self.homeContent = HomeContent(statistics: stats,
                                           configuredCapital: settings.settings.totalCapital,
                                           records: recs, hasPending: hasPending, hasCachedSets: hasCached)
        } catch {
            self.records = []
            self.homeContent = AppRouter.emptyHome()
            setError(error)
        }
    }

    public func startTraining() async {
        do {
            let engine = try await coordinator.startNewNormalSession()
            activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
        } catch { setError(error) }
    }

    public func continueTraining() async {
        do {
            if let engine = try await coordinator.resumePending() {
                activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
            }
        } catch { setError(error) }
    }

    public func selectRecord(id: Int64) {
        if let r = records.first(where: { $0.id == id }) { activeModal = .history(r) }
    }

    public func review(id: Int64) async {
        activeModal = nil
        do {
            let engine = try await coordinator.review(recordId: id)
            activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
        } catch { setError(error) }
    }

    public func replay(id: Int64) async {
        activeModal = nil
        do {
            // resume-first：总先试续局；返 nil（无槽/不匹配/已验证损坏已清）才从头。
            // throw（瞬态）→ setError → 不 fresh、不覆盖槽（防丢有效暂停档）。
            let engine: TrainingEngine
            if let resumed = try await coordinator.resumePendingReplay(recordId: id) {
                engine = resumed
            } else {
                engine = try await coordinator.replay(recordId: id)   // 从头
            }
            activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
        } catch { setError(error) }
    }

    /// A7: 透传谓词，避免在 AppRootView 中暴露 private coordinator。
    public func hasResumableReplay(id: Int64) -> Bool {
        coordinator.hasResumableReplay(recordId: id)
    }

    public func openSettings() { activeModal = .settings }

    public func exitTraining() async {
        activeTraining = nil            // 经 TrainingView「返回」按钮触发，其 lifecycle.back() 已 saveProgress+endSession；此处不再 endSession 防双调
        await loadHome()
    }

    public func runLaunchRecovery() async {
        guard !didRunLaunchRecovery else { return }   // 恰一次门：runner 每次全量重扫不去重，property 来自此门
        didRunLaunchRecovery = true                   // 同步置位（首次 await 前）防并发双跑
        await acceptance.retryPendingConfirmations()
        await loadHome()
    }

    public func sessionEnded(recordId: Int64?) async {
        let mode = activeTraining?.lifecycle.engine.flow.mode
        if let id = recordId {
            // Normal 正常结束：结算窗（reader 在结算期间保持开，confirm 时才关）
            do {
                let record = try recordRepo.loadRecordBundle(id: id).0
                activeModal = .settlement(record)
            } catch {
                await activeTraining?.lifecycle.endAfterSettlement()   // 取 record 失败也须关 reader
                setError(error); activeTraining = nil; await loadHome()
            }
        } else {
            // recordId==nil：防御性兜底分支。自 Wave 3 顺位 8 起，**replay 结束改经 onReplaySettlement →
            // presentReplaySettlement 走结算窗**（RFC §4.5），不再经此 nil 路径；replay-nil 仅在
            // TrainingView.routeEndOfSession 的不可达 catch 兜底时到达。normal finalize 失败自 Wave 3 10a 起
            // 亦不再走此路径（TrainingView 失败保留 + 重试/放弃，§4.7a）；两者均保留作防御性守卫，
            // 并由 AppRouterTests.sessionEnded_normalNilError 单测覆盖（直接注入 nil 验 errorMessage）；
            // 若生产回归命中本路径则说明 §4.7a 调用链有漏洞。
            await activeTraining?.lifecycle.endAfterSettlement()
            if mode == .normal { errorMessage = "结算入账失败，请重试" }   // replay 不报错（正常 retreat）
            activeTraining = nil
            await loadHome()
        }
    }

    public func confirmSettlement() async {
        await activeTraining?.lifecycle.endAfterSettlement()
        activeModal = nil
        activeTraining = nil
        await loadHome()
    }

    /// 顺位 8（RFC §4.5）：replay 结束的**非持久化**结算窗。caller（TrainingView）已强平 + 经
    /// `lifecycle.replaySettlementRecord()` 取 in-memory payload（`coordinator.replaySettlementPayload`，
    /// 不写 record / 不触 pending）→ 此处仅设 `.settlement` modal。确认复用 `confirmSettlement()`
    /// （`endAfterSettlement`→`endSession` 关 reader，无持久化）。replay 不计入统计、pending 不动。
    public func presentReplaySettlement(record: TrainingRecord) {
        activeModal = .settlement(record)
    }

    /// RFC-A R-plan-7-1：重置资金后立即重建 homeContent，使主页当权威 10 万即时可见。
    /// settings.resetAllProgress（Task 3/4 已将 deleteAll-records 去除，仅清 pending + 置 10 万） +
    /// loadHome（用新 settings.totalCapital 重建 homeContent）。
    public func resetAllProgressAndReload() async throws {
        try await settings.resetAllProgress()   // Task 3：保留记录 + 置 10 万 + 刷活缓存
        await loadHome()                         // 用新 settings.totalCapital 重建 homeContent
    }

    public func clearError() { errorMessage = nil }

    func setError(_ error: Error) {
        errorMessage = (error as? AppError)?.userMessage ?? "操作失败"
    }
}
