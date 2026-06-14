// Wave 2 顺位 11 — 生产根视图薄壳（spec 2026-06-08 §4.4）。
// 不含路由逻辑：全部 delegate AppRouter；只吃 Contracts 抽象（不吃 AppContainer）。
#if canImport(UIKit)
import SwiftUI

public struct AppRootView: View {
    @State private var router: AppRouter
    private let settings: SettingsStore
    private let api: any APIClient
    private let cache: any CacheManager
    private let acceptance: DownloadAcceptanceRunner

    public init(router: AppRouter, settings: SettingsStore, api: any APIClient,
                cache: any CacheManager, acceptance: DownloadAcceptanceRunner) {
        self._router = State(initialValue: router)
        self.settings = settings; self.api = api; self.cache = cache; self.acceptance = acceptance
    }

    private var trainingBinding: Binding<Bool> {
        Binding(get: { router.activeTraining != nil },
                set: { if !$0 { Task { await router.exitTraining() } } })   // 系统返回键已隐藏，仅程序化 pop
    }

    public var body: some View {
        NavigationStack {
            HomeView(content: router.homeContent,
                     onStartTraining: { Task { await router.startTraining() } },
                     onContinueTraining: { Task { await router.continueTraining() } },
                     onSelectRecord: { id in router.selectRecord(id: id) },
                     onOpenSettings: { router.openSettings() })
                .navigationDestination(isPresented: trainingBinding) {
                    if let t = router.activeTraining {
                        TrainingView(lifecycle: t.lifecycle,
                                     onExit: { Task { await router.exitTraining() } },
                                     onSessionEnded: { id in Task { await router.sessionEnded(recordId: id) } },
                                     onReplaySettlement: { record in router.presentReplaySettlement(record: record) })
                            .navigationBarBackButtonHidden(true)            // 抑制系统返回+back-swipe，强制经「返回」按钮 teardown
                    }
                }
        }
        .sheet(item: $router.activeModal) { modal in
            switch modal {
            case .settings:
                SettingsPanel(settings: settings, api: api, cache: cache, acceptance: acceptance)
            case .history(let r):
                HistoryActionSheet(record: r,
                                   onReview: { Task { await router.review(id: r.id ?? -1) } },
                                   onReplay: { Task { await router.replay(id: r.id ?? -1) } },
                                   onCancel: { router.activeModal = nil })
            case .settlement(let r):
                SettlementView(record: r, onConfirm: { Task { await router.confirmSettlement() } })
            }
        }
        .alert("出错了", isPresented: Binding(get: { router.errorMessage != nil },
                                            set: { if !$0 { router.clearError() } })) {
            Button("好", role: .cancel) { router.clearError() }
        } message: { Text(router.errorMessage ?? "") }
        .task { await router.runLaunchRecovery() }
    }
}
#endif
