// ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift
// Spec: kline_trainer_modules_v1.4.md §U4 L2081-2084 字面 init 签名 + plan_v1.5 §6.4 五控件。
// 薄 SwiftUI 壳（D8/D10 不单测，靠 Catalyst 编译闸门）：纯逻辑全在 SettingsPanelContent / SettingsStore。
// 决策（D3/D6/D9）：SettingsResetConfirmation() 在本模块内构造（落实 UI-owned 恢复边界）；
//               离线缓存薄接线 reserveTrainingSets → runBatch（取消/逐项错误恢复不在本锚）；
//               恢复按钮操作期 isRecovering 禁用，防并发双触发 clobber（恢复是手动单发动作）。
import SwiftUI

public struct SettingsPanel: View {
    private let settings: SettingsStore
    private let api: any APIClient
    private let cache: any CacheManager
    private let acceptance: DownloadAcceptanceRunner

    @State private var commissionInput = ""
    @State private var showCommissionEditor = false
    @State private var showResetConfirm = false
    @State private var downloadCountInput = ""
    @State private var showDownloadEditor = false
    @State private var downloadStatus = ""
    @State private var isDownloading = false
    @State private var recoveryMessage = ""
    @State private var isRecovering = false   // M1：禁用恢复按钮防并发双触发 clobber

    public init(settings: SettingsStore, api: any APIClient,
                cache: any CacheManager, acceptance: DownloadAcceptanceRunner) {
        self.settings = settings
        self.api = api
        self.cache = cache
        self.acceptance = acceptance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            if settings.loadError != nil {
                recoverySection
                Divider()
            }

            // 1. 佣金费率
            Button("佣金费率：\(SettingsPanelContent.formatCommissionUIInput(settings.settings.commissionRate))（万分之一）") {
                commissionInput = SettingsPanelContent.formatCommissionUIInput(settings.settings.commissionRate)
                showCommissionEditor = true
            }

            // 2. 免5 开关
            Toggle("免5（不收最低 5 元佣金）", isOn: Binding(
                get: { !settings.settings.minCommissionEnabled },
                set: { newValue in
                    Task { try? await settings.update { $0.minCommissionEnabled = !newValue } }
                }))

            // 3. 重置资金
            Button("重置资金（→ ¥100,000）") { showResetConfirm = true }

            // 4. 离线缓存
            Button(isDownloading ? "下载中…" : "离线缓存下载") { showDownloadEditor = true }
                .disabled(isDownloading)
            if !downloadStatus.isEmpty {
                Text(downloadStatus).font(.caption).foregroundStyle(.secondary)
            }

            // 5. 显示模式
            Picker("显示模式", selection: Binding(
                get: { settings.settings.displayMode },
                set: { newMode in Task { try? await settings.update { $0.displayMode = newMode } } })) {
                ForEach(SettingsPanelContent.displayModeOrder, id: \.self) { mode in
                    Text(SettingsPanelContent.displayModeLabel(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(24)
        // 佣金编辑
        .alert("佣金费率（万分之一）", isPresented: $showCommissionEditor) {
            TextField("如 1.000", text: $commissionInput)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let rate = SettingsPanelContent.parseCommissionUIInput(commissionInput) {
                    Task { try? await settings.update { $0.commissionRate = rate } }
                }
            }
        }
        // 重置资金二次确认
        .alert("确认重置资金为 ¥100,000？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                Task { try? await settings.resetCapital() }
            }
        }
        // 离线缓存数量输入
        .alert("下载数量（1~20）", isPresented: $showDownloadEditor) {
            TextField("如 5", text: $downloadCountInput)
            Button("取消", role: .cancel) {}
            Button("下载") { startDownload() }
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("⚠️ 设置加载失败").foregroundStyle(.red)
            if !recoveryMessage.isEmpty {
                Text(recoveryMessage).font(.caption).foregroundStyle(.secondary)
            }
            Button("重试") {
                isRecovering = true
                Task {
                    defer { isRecovering = false }
                    do { try await settings.retryReload(); recoveryMessage = "" }
                    catch { recoveryMessage = "重试失败，可尝试重置为默认设置" }
                }
            }
            .disabled(isRecovering)   // M1：防并发双触发 clobber（恢复是手动单发动作）
            // 仅在重试失败后暴露破坏性入口（recoveryMessage 非空）
            if !recoveryMessage.isEmpty {
                Button("重置为默认设置（清除本地设置）", role: .destructive) {
                    isRecovering = true
                    Task {
                        defer { isRecovering = false }
                        // SettingsResetConfirmation() 仅本模块可构造（D3）
                        do { try await settings.forceResetAndReload(confirmation: SettingsResetConfirmation()) }
                        catch { recoveryMessage = "重置失败：\((error as? AppError)?.userMessage ?? "未知错误")" }
                    }
                }
                .disabled(isRecovering)
            }
        }
    }

    private func startDownload() {
        guard case .valid(let count) = SettingsPanelContent.validateDownloadCount(downloadCountInput) else {
            downloadStatus = "请输入 1~20 的整数"
            return
        }
        isDownloading = true
        downloadStatus = "下载中…"
        Task {
            defer { isDownloading = false }
            do {
                let lease = try await api.reserveTrainingSets(count: count)
                let results = await acceptance.runBatch(lease: lease)
                let ok = results.filter { if case .confirmed = $0 { return true }; return false }.count
                downloadStatus = "完成：\(ok)/\(results.count) 成功"
            } catch {
                downloadStatus = "下载失败：\((error as? AppError)?.userMessage ?? "网络错误")"
            }
        }
    }
}

// MARK: - DEBUG-only #Preview（fileprivate APIClient stub + 现有 fakes）

#if DEBUG
private struct _PreviewSettingsAPIClient: APIClient {
    func reserveTrainingSets(count: Int) async throws -> LeaseResponse {
        LeaseResponse(leaseId: "preview", expiresAt: "2099-01-01T00:00:00Z", sets: [])
    }
    func downloadTrainingSet(id: Int) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    func confirmTrainingSet(id: Int, leaseId: String) async throws {}
}

@MainActor
private func _previewRunner() -> DownloadAcceptanceRunner {
    DownloadAcceptanceRunner(
        api: _PreviewSettingsAPIClient(), cache: InMemoryCacheManager(),
        dbFactory: PreviewTrainingSetDBFactory(), journal: InMemoryAcceptanceJournalDAO(),
        integrity: FakeZipIntegrityVerifier(), extractor: FakeZipExtractor(),
        dataVerifier: FakeTrainingSetDataVerifier(), cleaner: FakeDownloadAcceptanceCleaner())
}

#Preview {
    SettingsPanel(settings: .preview(), api: _PreviewSettingsAPIClient(),
                  cache: InMemoryCacheManager(), acceptance: _previewRunner())
}
#endif
