// ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
// Kline Trainer Swift Contracts — U2 训练页 SwiftUI 薄壳（Wave 2 顺位 9；Wave 3 顺位 7 扩：仓位 X/5 + 结束本局手动强平 + 交易 Toast/触觉；Wave 3 顺位 8 扩：Replay 结束分流非持久结算窗）
// Spec: kline_trainer_modules_v1.4.md §U2 L2049-2068（scenePhase 中继）
//     + kline_trainer_plan_v1.5.md §6.2（顶栏 / 双 K 线区 / 交易按钮 / 自动结束）。
//
// 决议（D1/D2/D4/D5/D9/D10/D11）：
// - D1 init 扩 (lifecycle:, onExit:, onSessionEnded:)（modules §U2 示意，outline §124 权威接线）。
// - D2 Normal/Review 不呈现 SettlementView：结束调 finalizeForSettlement → recordId? 经 onSessionEnded 上交顺位 11。
//   **Wave 3 顺位 8（D-replay-route）**：结束路由按 mode 分流（routeEndOfSession）——Replay 取非持久 in-memory
//   payload（lifecycle.replaySettlementRecord）经 onReplaySettlement 上交 AppRouter 呈现结算窗（RFC §4.5，不入账）；
//   Normal 仍走 onSessionEnded。
// - D4 自动结束检测 tick>=maxTick 且 shouldShowSettlement()（Review 抑制）；D5 didFinalize 一次性闸门。
// - D9 PositionPicker 全档启用，buy 返 failure 兜；D10 交易按钮仅 Normal/Replay，持有/观察随持仓切文案。
// - D11 #if canImport(UIKit)：嵌 ChartContainerView（UIViewRepresentable）故同门；host 不编译，Catalyst 编译闸门。
// - D6 手动结束按钮 + D8 仓位 X/5：**Wave 3 顺位 7 已兑现**（结束本局确认弹窗→engine.forceCloseManually→runFinalize；
//   顶栏 currentPositionTier；交易失败 Toast + 成功 .heavy 触觉，plan §6.2.4 / RFC §4.1/§4.4a/§4.4b）。
// - 延后（D7 画线面板）：顺位 4（U2-R2）。

#if canImport(UIKit)
import SwiftUI

public struct TrainingView: View {
    private let lifecycle: TrainingSessionLifecycle
    private let onExit: () -> Void
    private let onSessionEnded: (Int64?) -> Void
    private let onReplaySettlement: (TrainingRecord) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var didFinalize = false
    @State private var finalizeFailed = false
    @State private var finalizing = false      // R1-H2：in-flight 门，阻重试双击/并发 finalize Task
    @State private var pickerRequest: PickerRequest?
    @State private var toastMessage: String?
    @State private var toastToken = 0
    @State private var confirmingEnd = false

    public init(lifecycle: TrainingSessionLifecycle,
                onExit: @escaping () -> Void,
                onSessionEnded: @escaping (Int64?) -> Void,
                onReplaySettlement: @escaping (TrainingRecord) -> Void) {
        self.lifecycle = lifecycle
        self.onExit = onExit
        self.onSessionEnded = onSessionEnded
        self.onReplaySettlement = onReplaySettlement
    }

    private var engine: TrainingEngine { lifecycle.engine }
    // D10：交易按钮组可见性用权威能力谓词 `canBuySell()`（Normal/Replay=true、Review=false），而非硬编码
    // `mode != .review`——与按钮自身 `buyEnabled/sellEnabled` 同源（二者均 guard canBuySell），杜绝谓词漂移
    // （code-review Task3 Important；同 Task1 shouldShowSettlement 范式）。
    private var showsTradeButtons: Bool { engine.flow.canBuySell() }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            panel(.upper)
            Divider()
            panel(.lower)
            if showsTradeButtons { bottomBar }
        }
        .onAppear { maybeAutoEnd() }                                            // M2：resume-at-maxTick
        .onChange(of: engine.tick.globalTickIndex) { _, _ in maybeAutoEnd() }   // D4/D5
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { engine.onSceneActivated() }                // modules §U2 唯一链路
        }
        .sheet(item: $pickerRequest) { req in
            PositionPickerView(
                enabledTiers: Set(PositionTier.allCases),                       // D9
                onPick: { tier in
                    performTrade(req.action, panel: req.panel, tier: tier)
                    pickerRequest = nil
                },
                onCancel: { pickerRequest = nil })
        }
        .alert("结算入账失败", isPresented: $finalizeFailed) {
            Button("重试") { runFinalize() }
            // 放弃 = 关 reader + 清活跃上下文 + 回首页（§4.7a 用户显式选择；pending 留存可恢复，
            // durable discard〔清 pending + fence〕归顺位 10b §4.7e）
            Button("放弃", role: .cancel) {
                Task { await lifecycle.endAfterSettlement(); onExit() }
            }
        } message: {
            Text("本局结果尚未写入历史记录。可重试入账，或放弃结算退出（进度保留至最近存档）。")
        }
        .confirmationDialog("结束本局训练", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("是", role: .destructive) { endManually() }
            Button("否", role: .cancel) {}
        }
        .overlay(alignment: .top) {
            if let toast = toastMessage {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
    }

    private var topBar: some View {
        let bar = TrainingTopBarContent(totalCapital: engine.currentTotalCapital,
                                        holdingCost: engine.holdingCost,
                                        returnRate: engine.returnRate,
                                        positionTier: engine.currentPositionTier)
        return HStack(spacing: 12) {
            // 返回为 best-effort：保存进度后必回首页。`back()` 仅在「无活跃 session 上下文」抛 .internalError
            // （活跃 Normal 局不会发生；review/replay 的 saveProgress 是 no-op 不抛）→ `try?` 吞掉这一不可达错误以
            // 保证「点返回必退出」UX；不把保存失败上交（错误通道属顺位 11 路由 scope，code-review Task3 Minor）。
            Button("返回") { Task { try? await lifecycle.back(); onExit() } }
            Spacer()
            Text(bar.totalCapital)
            Text("持仓成本\(bar.holdingCost)")
            Text(bar.position)
            Text(bar.returnRate)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .font(.callout)
    }

    private func panel(_ id: PanelId) -> some View {
        HStack(spacing: 0) {
            ChartContainerView(panel: id, engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsTradeButtons { tradeButtons(id) }
        }
    }

    private func tradeButtons(_ id: PanelId) -> some View {
        VStack(spacing: 8) {
            Button("买入") { pickerRequest = PickerRequest(panel: id, action: .buy) }
                .disabled(!engine.buyEnabled)
            Button("卖出") { pickerRequest = PickerRequest(panel: id, action: .sell) }
                .disabled(!engine.sellEnabled)
            // 持有/观察始终可用（无 .disabled）：不变量靠 `showsTradeButtons==canBuySell()` 已排除唯一
            // 不可步进模式 Review（canAdvance==false）；Normal/Replay 两可见模式 canAdvance 恒 true（plan v1.5 L944）。
            Button(engine.position.shares > 0 ? "持有" : "观察") {   // D10
                engine.holdOrObserve(panel: id)
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 8)
    }

    // 交易动作执行：调 engine.buy/sell → TradeFeedback（纯值决策）→ 触觉/Toast（壳执行）。
    private func performTrade(_ action: PickerRequest.Action, panel: PanelId, tier: PositionTier) {
        let result: Result<TradeOperation, AppError>
        switch action {
        case .buy:  result = engine.buy(panel: panel, tier: tier)
        case .sell: result = engine.sell(panel: panel, tier: tier)
        }
        let feedback = TradeFeedback(result: result)
        if feedback.firesHaptic {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()   // D2：仅成功（plan §6.2.4）
        }
        if let message = feedback.toastMessage {
            presentToast(message)
        }
    }

    // latest-wins 自动消失 Toast（壳层 UX，不 host 测）。
    private func presentToast(_ message: String) {
        toastToken += 1
        let token = toastToken
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toastToken == token { toastMessage = nil }
        }
    }

    // 手动结束（plan §6.2.2 / RFC §4.4a）：强平 + settlement-safe 自检（engine）→ 安全则复用 runFinalize（D3）。
    // 返 false（Review/disabled/非有限财务量安全降级）→ no-op 不路由。didFinalize 置位防重入。
    private func endManually() {
        guard !didFinalize else { return }
        guard engine.forceCloseManually() else { return }
        didFinalize = true
        routeEndOfSession()
    }

    // D4/D5：判定下放 host-测 lifecycle.shouldAutoFinalize；壳仅持一次性 didFinalize + 触发 finalize。
    // .onAppear（resume-at-maxTick）与 .onChange(globalTickIndex)（步进至末态）双触发，!didFinalize 门保证仅一次。
    private func maybeAutoEnd() {
        guard lifecycle.shouldAutoFinalize(didFinalize: didFinalize) else { return }
        didFinalize = true
        routeEndOfSession()
    }

    // §4.7a 失败保留：finalize 抛错 → 保留 session（不 onSessionEnded(nil) 拆毁）→ alert 重试/放弃。
    // didFinalize 保持 true：阻 .onChange 重入；重试是显式用户动作（alert 按钮）再次调用本方法。
    // finalizing in-flight 门（R1-H2）：阻重试双击产生并发 finalize Task（port 幂等兜数据层，
    // 此门兜 UI 层——防 onSessionEnded 双发/alert 与 settlement 路由交错）。@MainActor 串行置位无 race。
    // replay 的 finalizeForSettlement 是不抛的早返 nil（shouldSaveRecord()==false）→ 仍走
    // onSessionEnded(nil) = 正常 retreat 路径，不受本 alert 影响。
    private func runFinalize() {
        guard !finalizing else { return }
        finalizing = true
        Task {
            defer { finalizing = false }
            do {
                let id = try await lifecycle.finalizeForSettlement()
                onSessionEnded(id)
            } catch {
                finalizeFailed = true
            }
        }
    }

    // 顺位 8（RFC §4.5）：结束路由分流。Replay → 非持久结算窗（取 in-memory payload 经 onReplaySettlement
    // 上交 AppRouter）；Normal → 入账（runFinalize，字节不变）。Review 不可达此方法
    // （shouldAutoFinalize 抑制 + forceCloseManually 对 Review 返 false），故 else 恒为 Normal。
    // 读 engine.flow.mode 与既有 showsTradeButtons=canBuySell() 同范式（壳层 flow-capability 分流）。
    private func routeEndOfSession() {
        guard engine.flow.mode == .replay else { runFinalize(); return }
        do {
            let record = try lifecycle.replaySettlementRecord()   // 强平已由上面 caller 先行（D4）
            onReplaySettlement(record)
        } catch {
            // 不可达（replay + 活跃会话已保证）；防御性 retreat（不入账，走 AppRouter replay-nil 兜底）
            onSessionEnded(nil)
        }
    }

    // 底部「结束本局」（plan §6.2.2：屏幕底部左侧）。可见性同交易按钮（canBuySell）。
    private var bottomBar: some View {
        HStack {
            Button("结束本局") { confirmingEnd = true }
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private struct PickerRequest: Identifiable {
        enum Action { case buy, sell }
        let panel: PanelId
        let action: Action
        var id: String { "\(panel)-\(action)" }
    }
}

#if DEBUG
#Preview {
    TrainingView(
        lifecycle: TrainingSessionLifecycle(engine: .preview(), coordinator: .preview()),
        onExit: {},
        onSessionEnded: { _ in },
        onReplaySettlement: { _ in })
}
#endif
#endif
