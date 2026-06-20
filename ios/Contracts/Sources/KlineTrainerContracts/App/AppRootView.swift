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

    // RFC #2：共享 sheet 的 item binding —— 滤掉 .history（走居中 overlay）+ High-1 守卫（dismiss 回写不清 history）
    private var sheetModalBinding: Binding<AppRouter.Modal?> {
        Binding(
            get: { HistoryDialogPresentation.sheetItem(for: router.activeModal) },
            set: { newValue in
                guard HistoryDialogPresentation.sheetDismissMayApply(current: router.activeModal) else { return }
                router.activeModal = newValue
            }
        )
    }

    // RFC #2：驱动 .history 居中弹窗淡入淡出的 Equatable 值（覆盖 onCancel/遮罩/review/replay 全部清除路径）
    private var isHistoryPresented: Bool {
        HistoryDialogPresentation.isHistoryPresented(router.activeModal)
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
        // RFC #2：.history 经下方 .overlay 居中呈现；.settings/.settlement 仍走底部 sheet。
        .sheet(item: sheetModalBinding) { modal in
            switch modal {
            case .settings:
                SettingsPanel(settings: settings, api: api, cache: cache, acceptance: acceptance)
            case .settlement(let r):
                SettlementView(record: r, onConfirm: { Task { await router.confirmSettlement() } })
            case .history:
                // sheetModalBinding 已把 .history 滤成 nil → 此分支永不到达，仅为 switch 穷尽。
                // 到达即分流 binding 失效（assertionFailure 在 release 为 no-op，DEBUG 下暴露）。
                let _ = assertionFailure("sheetModalBinding 必须把 .history 滤到居中 overlay")
                EmptyView()
            }
        }
        // RFC #2 / D5：.history 经 .overlay 居中呈现（半透明遮罩内含居中卡片，由 HistoryActionSheet body 自绘）
        .overlay {
            if case .history(let r) = router.activeModal {
                HistoryActionSheet(record: r,
                                   onReview: { Task { await router.review(id: r.id ?? -1) } },
                                   onReplay: { Task { await router.replay(id: r.id ?? -1) } },
                                   onCancel: { router.activeModal = nil })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isHistoryPresented)
        .alert("出错了", isPresented: Binding(get: { router.errorMessage != nil },
                                            set: { if !$0 { router.clearError() } })) {
            Button("好", role: .cancel) { router.clearError() }
        } message: { Text(router.errorMessage ?? "") }
        .task { await router.runLaunchRecovery() }
        .preferredColorScheme(displayModePrefersDark(settings.settings.displayMode).map { $0 ? .dark : .light })
    }
}
#endif
