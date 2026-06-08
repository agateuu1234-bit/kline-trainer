// ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
// Kline Trainer Swift Contracts — U2 训练页 SwiftUI 薄壳（Wave 2 顺位 9）
// Spec: kline_trainer_modules_v1.4.md §U2 L2049-2068（scenePhase 中继）
//     + kline_trainer_plan_v1.5.md §6.2（顶栏 / 双 K 线区 / 交易按钮 / 自动结束）。
//
// 决议（D1/D2/D4/D5/D9/D10/D11）：
// - D1 init 扩 (lifecycle:, onExit:, onSessionEnded:)（modules §U2 示意，outline §124 权威接线）。
// - D2 不呈现 SettlementView：自动结束调 finalizeForSettlement → recordId? 经 onSessionEnded 上交顺位 11。
// - D4 自动结束检测 tick>=maxTick 且 shouldShowSettlement()（Review 抑制）；D5 didFinalize 一次性闸门。
// - D9 PositionPicker 全档启用，buy 返 failure 兜；D10 交易按钮仅 Normal/Replay，持有/观察随持仓切文案。
// - D11 #if canImport(UIKit)：嵌 ChartContainerView（UIViewRepresentable）故同门；host 不编译，Catalyst 编译闸门。
// - 延后（D6 手动结束按钮 / D7 画线面板 / D8 仓位 X/5）：见 plan residual U2-R1/R2/R3。

#if canImport(UIKit)
import SwiftUI

public struct TrainingView: View {
    private let lifecycle: TrainingSessionLifecycle
    private let onExit: () -> Void
    private let onSessionEnded: (Int64?) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var didFinalize = false
    @State private var pickerRequest: PickerRequest?

    public init(lifecycle: TrainingSessionLifecycle,
                onExit: @escaping () -> Void,
                onSessionEnded: @escaping (Int64?) -> Void) {
        self.lifecycle = lifecycle
        self.onExit = onExit
        self.onSessionEnded = onSessionEnded
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
                    switch req.action {
                    case .buy:  _ = engine.buy(panel: req.panel, tier: tier)
                    case .sell: _ = engine.sell(panel: req.panel, tier: tier)
                    }
                    pickerRequest = nil
                },
                onCancel: { pickerRequest = nil })
        }
    }

    private var topBar: some View {
        let bar = TrainingTopBarContent(totalCapital: engine.currentTotalCapital,
                                        holdingCost: engine.holdingCost,
                                        returnRate: engine.returnRate)
        return HStack(spacing: 12) {
            // 返回为 best-effort：保存进度后必回首页。`back()` 仅在「无活跃 session 上下文」抛 .internalError
            // （活跃 Normal 局不会发生；review/replay 的 saveProgress 是 no-op 不抛）→ `try?` 吞掉这一不可达错误以
            // 保证「点返回必退出」UX；不把保存失败上交（错误通道属顺位 11 路由 scope，code-review Task3 Minor）。
            Button("返回") { Task { try? await lifecycle.back(); onExit() } }
            Spacer()
            Text(bar.totalCapital)
            Text("持仓成本\(bar.holdingCost)")
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

    // D4/D5：判定下放 host-测 lifecycle.shouldAutoFinalize；壳仅持一次性 didFinalize + 触发 finalize。
    // .onAppear（resume-at-maxTick）与 .onChange(globalTickIndex)（步进至末态）双触发，!didFinalize 门保证仅一次。
    private func maybeAutoEnd() {
        guard lifecycle.shouldAutoFinalize(didFinalize: didFinalize) else { return }
        didFinalize = true
        Task {
            do {
                let id = try await lifecycle.finalizeForSettlement()
                onSessionEnded(id)
            } catch {
                onSessionEnded(nil)
            }
        }
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
        onSessionEnded: { _ in })
}
#endif
#endif
