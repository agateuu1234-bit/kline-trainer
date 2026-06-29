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
// - D9（RFC-A 改）：点买/卖弹**数量框** TradeBoxView（active-panel overlay，非旧 5 档条/模态 PositionPicker）；按股数下单、显示==提交（.id 绑 strip 请求重置）；buyEnabled=可买≥1手(fee-aware)，失败仍走 TradeFeedback toast。D10 交易按钮仅 Normal/Replay，持有/观察随持仓切文案。
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var didFinalize = false
    @State private var finalizeFailed = false
    @State private var finalizing = false      // R1-H2：in-flight 门，阻重试双击/并发 finalize Task
    @State private var tradeStrip: TradeStripRequest?
    @State private var toast = ToastState()      // §B.1：latest-wins 调度核（host-tested）
    @State private var confirmingEnd = false
    @State private var backFailed = false      // §4.7a/§4.6：返回保存失败 → alert 重试/放弃（不丢数据）
    @State private var exitInFlight = false   // 退出路径 in-flight 门（对齐 finalizing 模式）：阻返回/放弃双击并发触发 onExit
    @State private var activePanel: PanelId = .lower   // RFC-B T2：分段钮选中面板（默认下图）

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

    /// 某 panel 当前下单周期（codex R2-high：买卖条捕获/比对用）。
    private func currentPeriod(of id: PanelId) -> Period {
        id == .upper ? engine.upperPanel.period : engine.lowerPanel.period
    }

    // 顺位 4：上栏是否在画线模式（按钮选中态 + toggle 语义）。
    private var isDrawingActive: Bool {
        if case .drawing = engine.upperPanel.interactionMode { return true }
        return false
    }
    private func toggleDrawing() {
        if isDrawingActive {
            engine.cancelDrawing(panel: .upper)
        } else {
            engine.activateDrawingTool(.horizontal, panel: .upper)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            panel(.upper)
            Divider()
            panel(.lower)
            if showsTradeButtons {
                TradeActionBar(
                    content: TradeActionBarContent(price: engine.currentPrice),
                    upperPeriod: engine.upperPanel.period,
                    lowerPeriod: engine.lowerPanel.period,
                    activePanel: $activePanel,
                    buyEnabled: engine.buyEnabled,
                    sellEnabled: engine.sellEnabled,
                    holdLabel: engine.position.shares > 0 ? "持有" : "观察",
                    onBuy:  { tradeStrip = TradeStripRequest(panel: activePanel, action: .buy, period: currentPeriod(of: activePanel), tick: engine.tick.globalTickIndex) },
                    onSell: { tradeStrip = TradeStripRequest(panel: activePanel, action: .sell, period: currentPeriod(of: activePanel), tick: engine.tick.globalTickIndex) },
                    onHold: { engine.holdOrObserve(panel: activePanel) })
            }
        }
        .onAppear { maybeAutoEnd() }                                            // M2：resume-at-maxTick
        .onChange(of: activePanel) { _, _ in
            // RFC-B(codex R1-medium 修)：切分段钮(下单目标 panel)即清掉打开的买卖档位条——
            // 否则条内捕获的 strip.panel 会过期（条显示在旧 panel、成交也按旧 panel），
            // 切目标后再选档会对错 panel 下单（autosave 后不可逆）。切目标=取消未确认下单。
            tradeStrip = nil
        }
        // codex R2-high：周期也能被两指上下滑手势改（switchPeriodCombo 改 panel.period，activePanel 不变）→
        // 同样清掉打开的买卖条，防对新周期下单。与上面的执行时守卫(onPick)双保险。
        .onChange(of: engine.upperPanel.period) { _, _ in tradeStrip = nil }
        .onChange(of: engine.lowerPanel.period) { _, _ in tradeStrip = nil }
        .onChange(of: engine.tick.globalTickIndex) { _, _ in
            tradeStrip = nil                                    // codex R3-high：tick 推进(含持有/观察)即作废未确认买卖条，防按新 tick 价成交
            lifecycle.autosave(immediate: false)                // §4.6：tick 推进按 N 节流
            maybeAutoEnd()
        }                                                       // D4/D5
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                engine.onSceneActivated()                       // modules §U2 既有动画链（不替换）
                // codex-13a-R2：回前台重放未确认的 autosave 失败。后台 flush 失败时 generation observer
                // 在 app 不可见时已弹过 toast 并 2s 过期 → 用户回前台无感知「进度可能未落盘」。banner 仍置位
                // （仅成功/endSession/reset 清），故此处重放使其在可见时呈现。非阻塞、不 teardown。
                if let e = lifecycle.coordinator.autosaveBannerError, e.shouldShowToast {
                    presentToast(e.userMessage)
                }
            case .inactive, .background:
                Task { await lifecycle.flushForBackground() }   // §4.6 item4：失活/后台立即 flush（OS 可能随后杀进程）
            @unknown default:
                break
            }
        }
        .onChange(of: engine.drawings.count) { _, _ in
            lifecycle.autosave(immediate: true)                 // §4.6：画线即存（commit/delete 不推 tick，D9）
        }
        .onChange(of: lifecycle.coordinator.autosaveErrorGeneration) { _, _ in
            // §B.2 + codex-13a-F1：观察失败**计数**（非错误值）——每次失败都递增 → 重复同一错误也 surface，
            // 持久故障（如磁盘满每 tick 失败）保持可见，非首条 toast 过期即静默。非阻塞、不 teardown
            // （与 finalize 失败 blocking alert 区分）。shouldShowToast 过滤 .internalError 等。
            if let e = lifecycle.coordinator.autosaveBannerError, e.shouldShowToast {
                presentToast(e.userMessage)
            }
        }
        .alert("结算入账失败", isPresented: $finalizeFailed) {
            Button("重试") { runFinalize() }
            // 放弃 = durable discard（fence→清 pending→关 reader→回首页，§4.7e）
            Button("放弃", role: .cancel) {
                guard !exitInFlight else { return }
                exitInFlight = true
                Task {
                    defer { exitInFlight = false }
                    try? await lifecycle.discard(); onExit()
                }
            }
        } message: {
            Text("本局结果尚未写入历史记录。可重试入账，或放弃结算退出（进度保留至最近存档）。")
        }
        .alert("保存进度失败", isPresented: $backFailed) {
            Button("重试") {
                guard !exitInFlight else { return }
                exitInFlight = true
                Task {
                    defer { exitInFlight = false }
                    do { try await lifecycle.back(); onExit() } catch { backFailed = true }
                }
            }
            Button("放弃", role: .destructive) {
                guard !exitInFlight else { return }
                exitInFlight = true
                Task {
                    defer { exitInFlight = false }
                    try? await lifecycle.discard(); onExit()   // durable 弃局退出
                }
            }
        } message: {
            Text("当前进度未能写入存档。可重试保存，或放弃本局退出。")
        }
        .confirmationDialog("结束本局训练", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("是", role: .destructive) { endManually() }
            Button("否", role: .cancel) {}
        }
        .toastOverlay(toast.message)             // §B.1 复用呈现壳（消费 ToastState.message）
        .overlay(alignment: .topLeading) {
            if showsTradeButtons {
                DrawingToolFloatingView(isDrawingActive: isDrawingActive, onToggleTool: toggleDrawing)
            }
        }
    }

    private var topBar: some View {
        let rec = lifecycle.activeRecord
        let bar = TrainingTopBarContent(totalCapital: engine.currentTotalCapital,
                                        averageCost: engine.position.averageCost,
                                        shares: engine.position.shares,
                                        returnRate: engine.returnRate,
                                        positionTier: engine.currentPositionTier,
                                        stockName: rec?.stockName, stockCode: rec?.stockCode,
                                        currentPrice: engine.currentPrice)
        return VStack(spacing: 6) {
            HStack {
                Button("返回") {
                    guard !exitInFlight else { return }
                    exitInFlight = true
                    Task {
                        defer { exitInFlight = false }
                        do { try await lifecycle.back(); onExit() }
                        catch { backFailed = true }
                    }
                }
                Spacer()
                Text(bar.stockNameDisplay).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if showsTradeButtons {
                    Button("结束") { confirmingEnd = true }
                        .font(.callout).tint(.red)
                        .accessibilityLabel("结束本局")
                } else {
                    // review 模式无结束：占位保持三段对称
                    Color.clear.frame(width: 36, height: 1)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                metricCell("总资金", bar.totalCapital, width: 84)
                metricCell("成本/股", bar.holdingCostPerShare, width: 56)
                metricCell("股数", bar.sharesText, width: 62)
                metricCell("仓位", bar.positionShort, width: 30)
                pnlCell(amount: bar.holdingPnLAmount, percent: bar.holdingPnLPercent, sign: bar.holdingPnLSign)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private static let metricRowH: CGFloat = 44   // 顶栏指标行固定高（容标签+浮动盈亏两行）；有界=不与图表抢空间

    /// 单值指标格：标签顶部齐头 + 数值在固定行高内上下居中；各格同 metricRowH → 等高、标签齐平。
    private func metricCell(_ label: String, _ value: String, width: CGFloat?) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: Self.metricRowH, alignment: .top)   // 固定有界高，label 顶 / value 居中
    }

    /// 浮动盈亏格（弹性末格）：标签顶 + 金额一行 / 百分比一行；盈红亏绿平中性（红涨绿跌）。同 metricRowH 固定高。
    private func pnlCell(amount: String, percent: String, sign: Int) -> some View {
        let palette = UIChartPalette.forScheme(colorScheme == .dark ? .dark : .light)
        let color: Color = sign > 0 ? Color(uiColor: palette.profitRed) : (sign < 0 ? Color(uiColor: palette.lossGreen) : .secondary)
        // 最小受支持设备=iPhone SE2/3=375pt（部署目标 iOS 17.6，无 320pt 设备）：内容宽 375−24(padding)=351，
        // 固定格 84+56+62+30=232 → PnL 弹性余量≈119pt，worst-case `+¥12,345,678`/`-12,345,678` 满刻度(~85pt)即放得下。
        // minimumScaleFactor 0.5 是「窄于受支持下限」的安全网（受支持设备永不触发缩放），保证任意窄屏也不截断（codex r4）。
        return VStack(spacing: 1) {
            Text("浮动盈亏").font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(amount).font(.system(size: 12).weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
            Text(percent).font(.system(size: 11).weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity).frame(height: Self.metricRowH, alignment: .top)
    }

    private func panel(_ id: PanelId) -> some View {
        ChartContainerView(panel: id, engine: engine)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 内联买卖小条：仅当该面板被点开时悬浮贴底（conjoint guard 含 showsTradeButtons，
            // 防 Normal 置位的 tradeStrip 在模式翻转至 Review/会话结束后悬空，spec §5.3 L3）。
            .overlay(alignment: .bottom) {
                if showsTradeButtons, let strip = tradeStrip, strip.panel == id {
                    TradeBoxView(
                        action: strip.action, price: engine.currentPrice,
                        cash: engine.cashBalance, holding: engine.position.shares,
                        fees: engine.fees, initialQty: 0,
                        onConfirm: { shares in
                            guard tradeStripStillValid(capturedPeriod: strip.period,
                                                       currentPeriod: currentPeriod(of: id),
                                                       capturedTick: strip.tick,
                                                       currentTick: engine.tick.globalTickIndex) else {
                                tradeStrip = nil; return
                            }
                            performTrade(strip.action, panel: id, shares: shares)
                            tradeStrip = nil
                        },
                        onCancel: { tradeStrip = nil })
                    // codex R-plan-21-1：SwiftUI @State 由视图身份保持，不因 action/panel 变化重置。
                    // 同 panel 上 买入→卖出 切换若不绑身份，旧 qty 会残留进新框并可被提交。
                    // 把身份绑到 strip 请求 → 请求(panel/action/tick)变即新身份 → qty @State 重置为 initialQty(0)。
                    // 键用纯函数（host 可测身份随请求变化）。
                    .id(TradeBoxContent.boxIdentity(panel: strip.panel, action: strip.action, tick: strip.tick))
                }
            }
            .overlay {   // active panel 高亮（红描边 inset，RFC-B T2 D10）
                if showsTradeButtons && id == activePanel {
                    Rectangle().strokeBorder(Color.red.opacity(0.45), lineWidth: 2).allowsHitTesting(false)
                }
            }
    }

    // 交易动作执行：调 engine.buy/sell → TradeFeedback（纯值决策）→ 触觉/Toast（壳执行）。
    private func performTrade(_ action: TradeAction, panel: PanelId, shares: Int) {
        let result: Result<TradeOperation, AppError>
        switch action {
        case .buy:  result = engine.buy(panel: panel, shares: shares)
        case .sell: result = engine.sell(panel: panel, shares: shares)
        }
        if case .success = result { lifecycle.autosave(immediate: true) }
        let feedback = TradeFeedback(result: result)
        if feedback.firesHaptic { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
        if let message = feedback.toastMessage { presentToast(message) }
    }

    // latest-wins 自动消失 Toast（驱动 host-tested ToastState；计时留壳层，不 host 测）。
    private func presentToast(_ message: String) {
        let token = toast.present(message)
        Task {
            try? await Task.sleep(for: .seconds(2))
            toast.expire(token: token)
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

    private struct TradeStripRequest: Identifiable {
        let panel: PanelId
        let action: TradeAction
        let period: Period          // codex R2-high：捕获开条时下单周期
        let tick: Int               // codex R3-high：捕获开条时 globalTickIndex（防 tick 推进后按新价成交）
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
