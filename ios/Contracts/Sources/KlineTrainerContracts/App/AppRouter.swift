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
            let engine = try await coordinator.replay(recordId: id)
            activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
        } catch { setError(error) }
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
            // recordId==nil：replay 结束（retreat）正常路径。normal finalize 失败自 Wave 3 10a 起
            // 不再走此路径（TrainingView 失败保留 + 重试/放弃，§4.7a）；normal-nil 分支保留作防御性守卫，
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

    public func clearError() { errorMessage = nil }

    func setError(_ error: Error) {
        errorMessage = (error as? AppError)?.userMessage ?? "操作失败"
    }
}
