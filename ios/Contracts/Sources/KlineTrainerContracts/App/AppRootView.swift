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

    // RFC-E：锚齿轮 popover 的 Bool binding —— 由 HistoryDialogPresentation.isSettings(router.activeModal) 判定（单一真相）。
    // dismiss 回写仅当当前是 settings 才清（守卫防误清已切换到 .settlement/.history 的模态）。
    // 注：Modal 非 Equatable，必须用 isSettings 谓词（禁 == 比较，见全局约束 + Step 4 grep 守卫）。
    private var settingsPopoverBinding: Binding<Bool> {
        Binding(
            get: { HistoryDialogPresentation.isSettings(router.activeModal) },
            set: { newValue in
                if !newValue && HistoryDialogPresentation.isSettings(router.activeModal) {
                    router.activeModal = nil
                }
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
                     onOpenSettings: { router.openSettings() },
                     isSettingsPresented: settingsPopoverBinding,
                     settingsContent: {
                        SettingsPanel(settings: settings, api: api, cache: cache, acceptance: acceptance,
                                      onConfirmReset: {
                                          try await router.resetAllProgressAndReload()
                                          router.activeModal = nil   // RFC-E：reset 成功 → 收 popover（spec-R1-M1 / A_reset_dismiss）
                                      })
                     })
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
        // RFC #2 / RFC-E：.history 居中 overlay、.settings 锚齿轮 popover；共享 sheet 仅剩 .settlement。
        .sheet(item: sheetModalBinding) { modal in
            switch modal {
            case .settlement(let r):
                SettlementView(record: r, onConfirm: { Task { await router.confirmSettlement() } })
            case .settings, .history:
                // sheetModalBinding 已把 .settings/.history 滤成 nil → 此分支永不到达，仅为 switch 穷尽。
                let _ = assertionFailure("sheetModalBinding 必须把 .settings/.history 滤出共享 sheet")
                EmptyView()
            }
        }
        // RFC #2 / D5：.history 经 .overlay 居中呈现（半透明遮罩内含居中卡片，由 HistoryActionSheet body 自绘）
        .overlay {
            if case .history(let r) = router.activeModal {
                HistoryActionSheet(record: r,
                                   hasResumableReplay: router.hasResumableReplay(id: r.id ?? -1),
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
