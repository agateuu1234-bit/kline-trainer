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

// 1a-iii 切片1/2 Task2：类型行 overlay 命中屏蔽——三个 PreferenceKey，值均 CGRect?、defaultValue = nil
// （overlay 隐藏时无 descendant 设置 preference → 值回落 nil，codex 计划-R3-medium）。切片2 起：
// 上下两个面板都上报 frame（DrawingUpperPanelFrameKey/DrawingLowerPanelFrameKey），供 refreshShields()
// 与 overlay frame 求交、装两个面板的盾（旧 DrawingPanelFrameKey 改名为 DrawingLowerPanelFrameKey）。
struct DrawingShieldFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
struct DrawingUpperPanelFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
struct DrawingLowerPanelFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

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
    @State private var replaySettlementFailed = false  // 新需求10(A6)：replay 结算失败 → 可重试 alert
    @State private var tradeStrip: TradeStripRequest?
    @State private var typeRowExpanded = true      // 画线类型行收/展
    // 1a-iii 切片2 Task3：常驻样式面板替代长按卡片；面板上/下半区位置（Task4 已接 ⇅ 真行为——onTogglePosition
    // 在 .top/.bottom 间切换，DrawingStylePanel 据此镜像「参数/类型行」两大块顺序）。
    @State private var stylePanelPosition: DrawingStylePanelPosition = .bottom
    @State private var toast = ToastState()      // §B.1：latest-wins 调度核（host-tested）
    @State private var confirmingEnd = false
    @State private var backFailed = false      // §4.7a/§4.6：返回保存失败 → alert 重试/放弃（不丢数据）
    @State private var exitInFlight = false   // 退出路径 in-flight 门（对齐 finalizing 模式）：阻返回/放弃双击并发触发 onExit
    @State private var activePanel: PanelId = .lower   // RFC-B T2：分段钮选中面板（默认下图）
    @State private var crosshairOwner: PanelId? = nil  // RFC-C：当前持十字光标的面板（跨面板互斥，同时只一个图有光标）
    // review-redesign Task 13：复盘「结束」保存弹窗 + 专用失败态（不复用 backFailed——那会误走
    // lifecycle.back()=review no-op saveProgress，丢已 drain 的 saved）。
    @State private var confirmingEndReview = false
    private enum ReviewEndAction { case back, save, discard }
    @State private var reviewFailedAction: ReviewEndAction?

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
    // B4：复盘控件条可见性——canAdvance=true（Review）且 canBuySell=false（非交易态），两谓词合取。
    // 与 showsTradeButtons 互斥：正常/Replay 时 canBuySell=true → showsReviewControls=false；
    // Review 时 canBuySell=false + canAdvance=true → showsReviewControls=true。
    private var showsReviewControls: Bool { engine.flow.canAdvance() && !engine.flow.canBuySell() }
    // review-redesign Task 13：画线门控与交易门控解耦——复盘不可交易(showsTradeButtons==false)但仍可画线
    // （routeDrawingCommit/appendReviewDrawing 写 reviewDrawings 层，Task 10 已接线）。买卖条仍严格仅
    // showsTradeButtons（不受本谓词影响）。
    // D26/codex R22-high：原 showsDrawingTools 同时门控浮动钮与 activePanel 高亮 → 拆成两个谓词。
    // 浮动钮只在复盘（训练/replay 改用「画图」钮 + 两行底栏）。
    private var showsFloatingDrawingTool: Bool { engine.flow.mode == .review }
    // activePanel 红框**保留原语义**（showsTradeButtons || review）——绝不可改 review-only，
    // 否则训练/replay 丢掉「当前对哪个面板下单」的唯一提示（下错面板 autosave 不可逆）。
    private var showsActivePanelHighlight: Bool { showsTradeButtons || engine.flow.mode == .review }

    /// 某 panel 当前下单周期（codex R2-high：买卖条捕获/比对用）。
    private func currentPeriod(of id: PanelId) -> Period {
        id == .upper ? engine.upperPanel.period : engine.lowerPanel.period
    }

    // P1b-1a-ii D42：画线会话是**全局**的（不属于任何面板）——按钮选中态与 toggle 都读/写唯一真相
    // `engine.drawingSession`。旧的「按 activePanel 互斥」模型（toggleDrawingExclusive）已退役。
    private var isDrawingActive: Bool {
        engine.drawingSession.drawingModeActive
    }
    // P1b-1a-iii 回归修复（HIGH，codex adversarial review，6a84fa5 引入）：样式面板「是否会出现」的判据
    // 唯一权威定义——此前同一表达式在 ChartPanelsContainer（计算属性）与本文件三个生命周期 onChange
    // （各自硬编码调用 setStylePanelVisible(true)）里存在两份互不联动的拷贝：复盘态本该算出 false
    // （showsTradeButtons==false，overlay 从不挂载），但三个 onChange 从不知道这件事，仍无条件把两面板
    // 摁进 .pending——此后没有任何 onPreferenceChange 会再触发 refreshShields() 来解开它，复盘每一次
    // tap 都被 ChartContainerView.handleDrawingTap 拒收（session.shield[k] ?? .unshielded 读到的是
    // .pending），复盘画线永久失效。收敛为单一定义：ChartPanelsContainer 与三个 onChange（见
    // syncPanelShields()）都读这一处。
    private var stylePanelWillBeVisible: Bool { showsTradeButtons && isDrawingActive && typeRowExpanded }
    private func toggleDrawing() {
        // 交易边界（codex rebased-R1-high）：进/出画线**同步**作废未确认买卖框——不依赖会被 SwiftUI
        // coalesce 掉的 .onChange（drawingModeActive 若在一次 update 内 false→true→false，onChange 看不到净变化）。
        // 这是画线模式唯一的 UI 开/关入口（画图钮/退出钮/复盘浮动钮都走它）。下方 .onChange 保留作纵深。
        tradeStrip = nil
        // 1a-iii 切片2 Task2 Step5a（codex 计划-R9-F3/R10-F1）：每次**进入**画线，面板默认展开
        // （spec §2.1）。drawingModeActive 此刻仍是**切换前**的值，故 `!active` == 「即将进入」。
        // 退出方向不动展开态（避免与退出动画/清理抢状态）——「记住工具与样式」是另一回事（session.defaultStyle）。
        if !engine.drawingSession.drawingModeActive { typeRowExpanded = true }
        engine.toggleDrawingMode()
    }

    // P1b-1a-iii 回归修复：三个仍可能在样式面板可见期间触发的生命周期 onChange
    // （drawingModeActive/typeRowExpanded/stylePanelPosition）唯一共用的盾更新实现——按
    // stylePanelWillBeVisible 分流：面板确实会出现 → setStylePanelVisible(true)（两面板 .pending，
    // 交给 ChartPanelsContainer.refreshShields() 按几何收敛，fail-closed）；面板根本不会出现（如复盘）
    // → clearAllShields()（absent 等价放行是正确语义——没有面板可能挡住 tap，继续摁着 .pending 只会
    // 堵死后续画线，且没有任何 onPreferenceChange 会来解开它）。真正的卸载语义（.onDisappear）不经此
    // 方法，仍无条件调 clearAllShields()。
    private func syncPanelShields() {
        if stylePanelWillBeVisible { engine.drawingSession.setStylePanelVisible(true) }
        else { engine.drawingSession.clearAllShields() }
    }

    // codex/W3-review-redesign-Task10：body 原是单个巨型 modifier 链——加一条 `.onChange` 后编译器
    // "unable to type-check this expression in reasonable time"（Catalyst build-for-testing 实测超时失败）。
    // 拆成 `trainingContent`（VStack + 全部 onAppear/onChange） + `body`（alert/confirmationDialog/toast/overlay）
    // 两段各自独立类型检查，纯行为中性重构（无逻辑改动，仅表达式分割）。
    public var body: some View {
        trainingContent
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
        // 新需求10(A6)：replay 结算失败（fence/payload/clear 中任一步抛）→ 保留 session+槽（可重试），
        // 用户可显式选择重试（幂等）或退出本局（codex R3-F1：lifecycle.back() durable 落终态槽，
        // 而非 onSessionEnded(nil)；fence 已置 terminating → autosave 协程死，槽仅剩旧检查点，
        // 须显式 saveProgress 把终态 durable 落槽，保障「暂存进度保留，可在历史记录返回训练」承诺）。
        .alert("结算失败", isPresented: $replaySettlementFailed) {
            Button("重试") { runReplaySettlement() }
            Button("退出本局", role: .cancel) {
                guard !exitInFlight else { return }
                exitInFlight = true
                Task {
                    defer { exitInFlight = false }
                    // codex whole-branch R3-F1：退出=保留进度（honor 提示文案）。fence 已置 terminating → autosave 协程死，
                    // 槽只剩旧检查点；须显式 lifecycle.back()（saveProgress 当前终态 + endSession）把终态 durable 落槽，
                    // 而非 onSessionEnded(nil)（不落盘 → 续局回旧检查点 / 提示落空）。保存失败 → 重弹 alert（可重试）。
                    do { try await lifecycle.back(); onExit() }
                    catch { replaySettlementFailed = true }
                }
            }
        } message: {
            Text("本局结算未能完成。可重试，或退出本局（暂存进度保留，可在历史记录返回训练）。")
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
        // review-redesign Task 13：复盘「结束」仅在有净改动时弹（ReviewEndPrompt.shouldPrompt 门控于 action 内）。
        .confirmationDialog("结束复盘", isPresented: $confirmingEndReview, titleVisibility: .visible) {
            Button("保存") { performReviewEnd(.save) }
            Button("不保存", role: .destructive) { performReviewEnd(.discard) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("是否保存本次复盘记录？")
        }
        // 专用 review 失败态（不复用 backFailed）：重试调**同一个**失败的动作，放弃=丢弃工作副本退出
        // （已保存的复盘存档不受影响）。
        .alert("复盘保存失败", isPresented: Binding(
            get: { reviewFailedAction != nil },
            set: { if !$0 { reviewFailedAction = nil } })) {
            Button("重试") {
                if let action = reviewFailedAction {
                    reviewFailedAction = nil
                    performReviewEnd(action)
                }
            }
            // codex whole-branch R2（medium）：不用 `try? endReviewDiscard`——若其内部 clearWorking 抛错，
            // endSession 从未执行，会话/reader 泄漏。改用 `abandonReview`：恒收尾会话，清档失败也不阻断退出。
            Button("放弃", role: .destructive) {
                reviewFailedAction = nil
                guard !exitInFlight else { return }
                exitInFlight = true
                Task {
                    defer { exitInFlight = false }
                    await lifecycle.abandonReview(engine: engine)
                    onExit()
                }
            }
        } message: {
            Text("复盘进度未能写入。可重试，或放弃本次复盘改动退出（已保存的复盘存档不受影响）。")
        }
        .toastOverlay(toast.message)             // §B.1 复用呈现壳（消费 ToastState.message）
        .overlay(alignment: .topLeading) {
            if showsFloatingDrawingTool {          // 只复盘（训练/replay 用「画图」钮）
                DrawingToolFloatingView(isDrawingActive: isDrawingActive, onToggleTool: toggleDrawing)
            }
        }
    }

    /// body 前半段（拆分见 body 顶部注释）：主内容 VStack + 全部 onAppear/onChange 中继。
    private var trainingContent: some View {
        VStack(spacing: 0) {
            topBar
            chartPanels
            if showsTradeButtons {
                if isDrawingActive {
                    DrawingBottomBar(typeRowExpanded: $typeRowExpanded)
                } else {
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
            } else if showsReviewControls {
                // B4：复盘控件条——仅 Review 可步进态显示（canAdvance && !canBuySell）。
                // Task 8：训练底栏样式重设计——[上图|下图]分段器选中面板即「下一根」步进的目标面板。
                ReviewControlBar(showsJumpToEnd: engine.flow.canJumpToEnd(),
                                 price: engine.currentPrice,
                                 upperPeriod: engine.upperPanel.period,
                                 lowerPeriod: engine.lowerPanel.period,
                                 activePanel: $activePanel) { action in
                    switch action {
                    case .step:      engine.stepReviewForward(panel: activePanel)   // 逐根步进（Task 4 panel 重载）
                    case .jumpToEnd: engine.jumpToEnd()            // 快进到结尾（B2）
                    }
                }
            }
        }
        .onAppear {
            maybeAutoEnd()                                                       // M2：resume-at-maxTick
            // review-redesign Task 13：进复盘时若 Task 6 已自动清掉损坏 saved 存档，一次性 toast 告知。
            if engine.flow.mode == .review && lifecycle.coordinator.pendingReviewCorruptToast {
                presentToast("复盘存档损坏已清除，可重新复盘保存")
                lifecycle.coordinator.clearPendingReviewCorruptToast()
            }
        }
        .onChange(of: activePanel) { _, _ in
            // RFC-B(codex R1-medium 修)：切分段钮(下单目标 panel)即清掉打开的买卖档位条——
            // 否则条内捕获的 strip.panel 会过期（条显示在旧 panel、成交也按旧 panel），
            // 切目标后再选档会对错 panel 下单（autosave 后不可逆）。切目标=取消未确认下单。
            tradeStrip = nil
            // P1b-1a-ii D42/R30-medium：**不再**取消画线。activePanel 是「下单目标面板」，
            // 与画线会话无关；切它不产生新落锚，故 drawingModeActive / activeDrawingTool /
            // pending 锚**全部原封保留**（丢 pending 只发生在「下一次落锚 tap 落在别的面板」时）。
        }
        // codex R2-high：周期也能被两指上下滑手势改（switchPeriodCombo 改 panel.period，activePanel 不变）→
        // 同样清掉打开的买卖条，防对新周期下单。与上面的执行时守卫(onPick)双保险。
        .onChange(of: engine.upperPanel.period) { _, _ in tradeStrip = nil; lifecycle.autosave(immediate: false) }
        .onChange(of: engine.lowerPanel.period) { _, _ in tradeStrip = nil; lifecycle.autosave(immediate: false) }
        // codex branch-R3-high / plan-R9-high（交易安全）：画线模式**任一方向切换**都作废未确认买卖框。
        // 不只清「进画线」——退出也清：否则一个跨 round-trip 幸存的陈旧 tradeStrip 会在退出后（!drawingModeActive）
        // remount，同 tick/period 下被 TradeConfirmGuard 放行成交。清 nil 恒安全（本就不该跨画线切换留着买卖框）。
        .onChange(of: engine.drawingSession.drawingModeActive) { _, _ in
            tradeStrip = nil
            // P1b-1a-iii 回归修复：盾的收敛/清空判据统一交给 syncPanelShields()（唯一权威实现，定义处
            // 大注释详述复盘死锁的根因）——tradeStrip 清空仍保持无条件（两个方向都清，见
            // TrainingViewShellSourceGuardTests.tradeBoundary/drawingModeOnChangeStaysUnconditional）。
            syncPanelShields()
        }
        // 收起/展开类型行同样可能改变样式面板是否出现的判据，统一走 syncPanelShields()。
        .onChange(of: typeRowExpanded) { _, _ in
            syncPanelShields()
        }
        // 1a-iii 切片2 Task4：切面板上/下半区即重置所有盾——旧位置的盾若残留，那半边 K 线会变成
        // 「怎么点都画不了线」的死区（nil-preference 自动重算是第一层，本行是明确的生命周期第二层）。
        // ⭐codex 计划-R16-F1：这里绝不能用 settleWithNoShields()（测试逃生舱）。
        //   切位置正是几何尚未重新收敛的时刻——把两面板标记「已收敛」等于在最需要保护的瞬间
        //   关掉 fail-closed：新位置的面板已可见、盾还没算出来，此时的 tap 会穿透并 autosave 幽灵线。
        //   syncPanelShields() 在面板确实会出现时置两面板 .pending 并保持未收敛，直到 refreshShields()
        //   见到 overlay + 两个面板 frame 齐备才开闸；面板根本不会出现（如复盘）则直接清空，不留裸奔窗口。
        .onChange(of: stylePanelPosition) { _, _ in
            syncPanelShields()
        }
        .onChange(of: engine.tick.globalTickIndex) { _, _ in
            tradeStrip = nil                                    // codex R3-high：tick 推进(含持有/观察)即作废未确认买卖条，防按新 tick 价成交
            lifecycle.autosave(immediate: false)                // §4.6：tick 推进按 N 节流（review 恒 no-op，shouldPersistProgress==false）
            if engine.flow.mode == .review { lifecycle.autosaveReview(engine: engine) }   // Task 13：复盘步进即存
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
                Task {
                    await lifecycle.flushForBackground()        // §4.6 item4：失活/后台立即 flush（OS 可能随后杀进程）
                    // codex whole-branch R1：review 的 autosave 只走排队 `autosaveReview`（上面这条对 review no-op），
                    // 须单独 flush，否则未排空的画线/步进改动可能随进程被杀丢失。
                    if engine.flow.mode == .review { await lifecycle.flushReviewForBackground(engine: engine) }
                }
            @unknown default:
                break
            }
        }
        .onChange(of: engine.drawings.count) { _, _ in
            lifecycle.autosave(immediate: true)                 // §4.6：画线即存（commit/delete 不推 tick，D9）
        }
        .onChange(of: engine.reviewDrawings.count) { _, _ in
            // review-redesign Task 10：复盘新画线走 reviewDrawings（非 drawings），故上面那条 onChange 不触发；
            // 镜像同款「画线即存」语义，改调 autosaveReview（Task 7）。非 review 模式下 reviewDrawings 恒不变，no-op。
            lifecycle.autosaveReview(engine: engine)
        }
        .onChange(of: lifecycle.coordinator.autosaveErrorGeneration) { _, _ in
            // §B.2 + codex-13a-F1：观察失败**计数**（非错误值）——每次失败都递增 → 重复同一错误也 surface，
            // 持久故障（如磁盘满每 tick 失败）保持可见，非首条 toast 过期即静默。非阻塞、不 teardown
            // （与 finalize 失败 blocking alert 区分）。shouldShowToast 过滤 .internalError 等。
            if let e = lifecycle.coordinator.autosaveBannerError, e.shouldShowToast {
                presentToast(e.userMessage)
            }
        }
        // 1a-iii 切片2 Task2：view 消失（导航退出）也显式清盾——三重防御的第三处（几何未齐 fail-closed +
        // 两个 onChange + 本处），生命周期上不留残留 shield 死区。
        .onDisappear {
            engine.drawingSession.clearAllShields()
        }
    }

    private var topBar: some View {
        let rec = lifecycle.activeRecord
        // Task 9：review 顶栏读 ReviewLedger 截至当前 tick 的运行值（替换 #136 R4「隐藏最终成绩」行为——
        // 复盘现在全程显示运行 P&L，非结局才揭示）。ops fold 已由 Task 6 入口校验保证干净，
        // 逐帧 try? 仅保编译期非 throw，永不触发 nil 兜底。normal/replay 仍直接用 engine 派生值。
        let isReview = engine.flow.mode == .review
        let ledger: ReviewLedgerState? = isReview
            ? (try? ReviewLedger.state(atTick: engine.tick.globalTickIndex, ops: engine.tradeOperations,
                                       initialCapital: engine.initialCapital,
                                       markPriceAtTick: { engine.markPrice(atTick: $0) }))
            : nil
        let bar = TrainingTopBarContent(
            totalCapital: ledger?.totalCapital ?? engine.currentTotalCapital,
            initialCapital: engine.initialCapital,
            averageCost: ledger?.averageCost ?? engine.position.averageCost,
            shares: ledger?.shares ?? engine.position.shares,
            returnRate: ledger?.returnRate ?? engine.returnRate,
            positionTier: ledger?.positionTier ?? engine.currentPositionTier,
            stockName: rec?.stockName, stockCode: rec?.stockCode)
        return VStack(spacing: 6) {
            HStack {
                Button("返回") {
                    // Task 13：review 走专用保存分支（失败进专用 alert，重试同动作——不误走 lifecycle.back()
                    // 那是 review no-op saveProgress，会丢掉已 drain 的 saved）。
                    if isReview { performReviewEnd(.back); return }
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
                if showsTradeButtons && !isDrawingActive {
                    Button { toggleDrawing() } label: { Image(systemName: "pencil.tip.crop.circle") }
                        .accessibilityLabel("画图")
                    Spacer().frame(width: 28)          // 与「结束」留明显间距，防误点
                }
                if showsTradeButtons {
                    if isDrawingActive {
                        Button("退出") { toggleDrawing() }      // 退出画线（非结束本局）
                            .font(.callout)
                            .accessibilityLabel("退出画线")
                    } else {
                        Button("结束") { confirmingEnd = true }
                            .font(.callout).tint(.red)
                            .accessibilityLabel("结束本局")
                    }
                } else if isReview {
                    // Task 13：复盘「结束」——有净改动才弹保存确认，无改动直接丢弃退出。
                    Button("结束") {
                        if ReviewEndPrompt.shouldPrompt(netChanged: lifecycle.reviewNetChanged()) {
                            confirmingEndReview = true
                        } else {
                            performReviewEnd(.discard)
                        }
                    }
                    .font(.callout).tint(.red)
                    .accessibilityLabel("结束复盘")
                } else {
                    // 不可达：Normal/Replay 命中 showsTradeButtons 分支、Review 命中 isReview 分支；占位保三段对称
                    Color.clear.frame(width: 36, height: 1)
                }
            }
            // 方案A 横向均匀分布：每格 worst-case 定宽（留够极限值）+ 格间等距 Spacer 把剩余空间均匀摊到间隙；
            // 浮动盈亏不再独吞剩余（定宽 92），自适应屏宽（宽屏间隙等比增大）。Σ定宽320+min间隙 ≤ 375pt 内容宽。
            HStack(alignment: .top, spacing: 0) {
                metricCell("总资金", bar.totalCapital, width: 80)
                Spacer(minLength: 4)
                metricCell("成本/股", bar.holdingCostPerShare, width: 56)
                Spacer(minLength: 4)
                metricCell("股数", bar.sharesText, width: 64)
                Spacer(minLength: 4)
                metricCell("仓位", bar.positionShort, width: 28)
                Spacer(minLength: 4)
                pnlCell(amount: bar.sessionPnLAmount, percent: bar.sessionPnLPercent, sign: bar.sessionPnLSign)
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
        // 方案A：定宽 92 留够 worst-case「+¥12,345,678」（不再 maxWidth:.infinity 吃光剩余）。
        // minimumScaleFactor 0.5 = 任意窄屏安全网（受支持设备 375pt+ 满刻度即放得下、永不触发缩放，codex r4）。
        return VStack(spacing: 1) {
            Text("本局盈亏").font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(amount).font(.system(size: 12).weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
            Text(percent).font(.system(size: 11).weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 0)
        }
        .frame(width: 92, height: Self.metricRowH, alignment: .top)
    }

    /// 1a-iii 切片1 Task2：上下两个图表面板容器 + 类型行 overlay（不占 VStack 高度）。
    /// codex 计划-R2-high：overlay 必须挂在「仅上下 K 线面板」的容器、**不是**整个 `trainingContent`
    /// （否则 `.bottom` 对齐到含底栏的整栈底、盖住 DrawingBottomBar、遮住①类型键）。
    /// Task3：正文抽成 `ChartPanelsContainer`——hosted 布局不变量测试直接渲染这个**同一份**容器测本体
    /// frame 三态不变（抽共享、不复制，见 Render/DrawingLayoutInvariantTests.swift）。
    private var chartPanels: some View {
        ChartPanelsContainer(engine: engine, stylePanelVisible: stylePanelWillBeVisible,
                             scheme: colorScheme == .dark ? .dark : .light,
                             stylePanelPosition: stylePanelPosition,
                             onTogglePosition: { stylePanelPosition = (stylePanelPosition == .bottom ? .top : .bottom) },
                             upperPanel: { panel(.upper) }, lowerPanel: { panel(.lower) })
    }

    private func panel(_ id: PanelId) -> some View {
        ChartContainerView(panel: id, engine: engine, crosshairOwner: $crosshairOwner)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 内联买卖小条：仅当该面板被点开时悬浮贴底（conjoint guard 含 showsTradeButtons，
            // 防 Normal 置位的 tradeStrip 在模式翻转至 Review/会话结束后悬空，spec §5.3 L3）。
            .overlay(alignment: .bottom) {
                if showsTradeButtons, !engine.drawingSession.drawingModeActive,
                   let strip = tradeStrip, strip.panel == id {
                    TradeBoxView(
                        action: strip.action, price: engine.currentPrice,
                        cash: engine.cashBalance, holding: engine.position.shares,
                        fees: engine.fees, initialQty: 0,
                        onConfirm: { shares in
                            // codex plan-R1/R3-high：confirm transition 走可测 apply——画线中 onProceed(performTrade) 绝不触发。
                            TradeConfirmGuard.apply(
                                drawingModeActive: engine.drawingSession.drawingModeActive,
                                periodTickStillValid: tradeStripStillValid(capturedPeriod: strip.period,
                                                                           currentPeriod: currentPeriod(of: id),
                                                                           capturedTick: strip.tick,
                                                                           currentTick: engine.tick.globalTickIndex),
                                onProceed: { performTrade(strip.action, panel: id, shares: shares) })
                            tradeStrip = nil   // 两条路径都收起买卖框（成交与否都关框）
                        },
                        onCancel: { tradeStrip = nil })
                    // codex R-plan-21-1：SwiftUI @State 由视图身份保持，不因 action/panel 变化重置。
                    // 同 panel 上 买入→卖出 切换若不绑身份，旧 qty 会残留进新框并可被提交。
                    // 把身份绑到 strip 请求 → 请求(panel/action/tick)变即新身份 → qty @State 重置为 initialQty(0)。
                    // 键用纯函数（host 可测身份随请求变化）。
                    .id(TradeBoxContent.boxIdentity(panel: strip.panel, action: strip.action, tick: strip.tick))
                }
            }
            .overlay {   // active panel 高亮（红描边 inset，RFC-B T2 D10；1a-iii：门控 showsActivePanelHighlight=showsTradeButtons||review，复盘也高亮）
                if showsActivePanelHighlight && id == activePanel {
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

    // 顺位 8（RFC §4.5）：结束路由分流。Replay → runReplaySettlement（async，含 fence+clear）；
    // Normal → runFinalize（字节不变）。Review 不可达此方法（shouldAutoFinalize 抑制 + forceCloseManually 对 Review 返 false）。
    private func routeEndOfSession() {
        guard engine.flow.mode == .replay else { runFinalize(); return }
        runReplaySettlement()
    }

    // 新需求10(A6)：replay 终局 async（fence→构建 payload→清槽）。失败=保留 session+槽（不 onSessionEnded(nil)），
    // 弹可重试 alert（镜像 runFinalize）。didFinalize 已由 maybeAutoEnd/endManually 置 true，防 onChange 重入；
    // 重试=显式 alert 按钮再调本方法（fence/payload/clear 均幂等）。
    private func runReplaySettlement() {
        guard !finalizing else { return }
        finalizing = true
        Task {
            defer { finalizing = false }
            do {
                let record = try await lifecycle.replaySettlementRecord()
                onReplaySettlement(record)
            } catch {
                replaySettlementFailed = true
            }
        }
    }

    // review-redesign Task 13：复盘退出统一入口（返回/结束-保存/结束-不保存三个动作共用），捕获**具体
    // 动作**供失败重试——绝不重试成 lifecycle.back()（那是 review no-op saveProgress，会丢已 drain 的 saved）。
    private func performReviewEnd(_ action: ReviewEndAction) {
        guard !exitInFlight else { return }
        exitInFlight = true
        Task {
            defer { exitInFlight = false }
            do {
                switch action {
                case .back:    try await lifecycle.backReview(engine: engine)
                case .save:    try await lifecycle.endReviewSave(engine: engine)
                case .discard: try await lifecycle.endReviewDiscard(engine: engine)
                }
                onExit()
            } catch {
                reviewFailedAction = action   // 记住失败的具体动作，供专用 alert 重试
            }
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

/// 上下面板容器 + 类型行 overlay + 命中屏蔽的共享实现（1a-iii 切片1 Task3 抽出）：生产 `TrainingView.chartPanels`
/// 与 hosted 布局不变量测试（Render/DrawingLayoutInvariantTests.swift 直接渲染本容器测 frame 三态不变）
/// 共用同一份 VStack/overlay/PreferenceKey 接线，防止几何断言测的是一份复制品、
/// 悄悄跟生产接线漂移（抽共享、不复制）。上下面板内容由调用方注入（生产传真 K 线面板，hosted 测试传等尺寸占位）。
struct ChartPanelsContainer<Upper: View, Lower: View>: View {
    let engine: TrainingEngine
    // 1a-iii 切片2 Task2（实测发现，见 Task2 report）：样式面板「是否应当可见」不经 `.onAppear`/
    // `.onDisappear` 侧写——原稿用 onAppear/onDisappear 置位 `.pending`/清空——host-真机上可行，但
    // hosted 测试用的 `ImageRenderer.uiImage` 在完成一次离屏渲染、内部两轮布局收敛 GeometryReader 后，
    // 会把临时渲染上下文整体拆除，**这次拆除本身也会触发 `.onDisappear`**（即便 typeRowExpanded 仍是
    // true、overlay 逻辑上从未真正"消失"）——把刚算好的 `.rect` 覆写回空字典，四个新测试全部假红
    // （shieldRectOf 恒 nil）。
    // P1b-1a-iii 回归修复（HIGH，6a84fa5 引入）：本参数原是容器自己的纯计算属性
    // `showsTradeButtons && isDrawingActive && typeRowExpanded`；TrainingView 的三个生命周期 onChange
    // 却各自硬编码调用 setStylePanelVisible(true)，从不读这条判据——复盘态（showsTradeButtons==false）
    // 本容器算出 false（overlay 从不挂载），但三个 onChange 不知道这件事仍无条件把两面板摁进 .pending，
    // 此后再没有任何 onPreferenceChange 触发 refreshShields() 来解开它，复盘画线永久失效（codex
    // adversarial review HIGH）。收敛为单一定义：`TrainingView.stylePanelWillBeVisible` 是唯一权威计算处，
    // call site（`TrainingView.chartPanels` + 本文件下方三个测试外壳）各自算好结果后作为本参数传入——
    // 本容器与 TrainingView 三个生命周期 onChange（经 `syncPanelShields()`）读的是同一个值，不再各自维护
    // 第二份「样式面板会不会出现」的猜测。
    let stylePanelVisible: Bool
    let scheme: AppColorScheme                    // 1a-iii 切片2 Task3：样式面板色板取色（DrawingColorResolver）
    let stylePanelPosition: DrawingStylePanelPosition   // 上/下半区（Task4 已接 ⇅ 真行为：refreshShields() 按当前位置求交两面板）
    let onTogglePosition: () -> Void               // ⇅ 回调（替代已删的 onLongPressType）
    @ViewBuilder let upperPanel: () -> Upper
    @ViewBuilder let lowerPanel: () -> Lower
    @State private var upperPanelChartFrame: CGRect?
    @State private var lowerPanelChartFrame: CGRect?
    @State private var stylePanelChartFrame: CGRect?

    var body: some View {
        VStack(spacing: 0) {
            upperPanel()
                .background(GeometryReader { p in Color.clear
                    .preference(key: DrawingUpperPanelFrameKey.self, value: p.frame(in: .named("chart"))) })
            Divider()
            lowerPanel()
                .background(GeometryReader { p in Color.clear
                    .preference(key: DrawingLowerPanelFrameKey.self, value: p.frame(in: .named("chart"))) })
        }
        .coordinateSpace(name: "chart")
        .overlay(alignment: stylePanelPosition == .top ? .top : .bottom) {
            // codex 计划-R4-medium：挂载条件必须排除复盘（复盘用浮动铅笔钮，本切片不改其行为）——否则复盘
            // 经浮动钮 drawingModeActive 时也会挂 overlay+装两面板盾、吞复盘图表点。P1b-1a-iii 回归修复后，
            // call site 传入的 stylePanelVisible 唯一定义在 TrainingView.stylePanelWillBeVisible
            // （= showsTradeButtons && isDrawingActive && typeRowExpanded，天然排除复盘），本容器不再自算。
            if stylePanelVisible {
                DrawingStylePanel(session: engine.drawingSession, scheme: scheme,
                                  position: stylePanelPosition, onTogglePosition: onTogglePosition)
                    // ⭐codex 计划-R1-F2：GeometryReader 必须量**未加 padding 的可见面板本体**——
                    //   量到的 frame 就是写进 shield（经 refreshShields() 的 .rect case）的盾。先量、后 padding：
                    .background(GeometryReader { g in Color.clear
                        .preference(key: DrawingShieldFrameKey.self, value: g.frame(in: .named("chart"))) })
                    // 离屏边距加在测量之后 → 只影响面板摆放位置，不进盾（无看不见的死条）。
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }
        }
        .accessibilityIdentifier("chartPanels")
        // 三个 frame **任一**变化都重算盾：不假设 preference 的到达顺序（切片1 只在 shield frame 变化时算、
        // 把 panel frame 当已知值读——若 panel frame 后到，盾会被算成 nil 并永远停在那，是一条靠收敛顺序侥幸的隐患）。
        .onPreferenceChange(DrawingUpperPanelFrameKey.self) { upperPanelChartFrame = $0; refreshShields() }
        .onPreferenceChange(DrawingLowerPanelFrameKey.self) { lowerPanelChartFrame = $0; refreshShields() }
        .onPreferenceChange(DrawingShieldFrameKey.self) { stylePanelChartFrame = $0; refreshShields() }
        // codex R2-medium：`.pending` 的唯一退出路径是上面三条 onPreferenceChange——但 SwiftUI 只在**新值
        // 与旧值不相等**时才回调它们。切 stylePanelPosition（.top⇄.bottom）在容器高度恰等于「样式面板高 +
        // 16pt 竖直 padding」时（大字号/iPad/横屏可达），overlay 未加 padding 的 frame 在两态下算出**同一个**
        // CGRect（上/下贴边对齐退化成同一位置）——三个 preference 值全都不变，三条 onPreferenceChange 一条都
        // 不触发，refreshShields() 从此再也不会重跑；而 TrainingView.syncPanelShields() 在此之前已把两面板摁
        // 进 `.pending`，于是永远卡住（见 DrawingSession.setStylePanelVisible 文档注释）。`.task(id:)` 在
        // id **变化后**独立重跑，不依赖三个 preference 是否真的变了——几何真变时 preference 那条已经跑过
        // 一次，这里只是无害的幂等重算；几何未变时（本 bug 场景）@State 里缓存的三帧仍是正确值，正是这条
        // 负责用它们把 .pending 收敛掉。两个 id 各自独立触发，覆盖「位置切换」与「面板可见性切换」两类
        // 可能不改几何却需要重新收敛的转场。
        .task(id: stylePanelPosition) { refreshShields() }
        .task(id: stylePanelVisible) { refreshShields() }
    }

    /// codex 计划-R15-F1/R17-F2 唯一权威实现：判据是「计算所需的几何全部到齐」——不齐时**什么都不写**
    /// （两面板保持 `.pending`，fail-closed），不得在缺帧时写 `.unshielded`（那正是裸奔窗口）。
    /// 判据是**几何相交**，不是「面板停在上/下半区就挡对应面板」——面板变高/上下切/跨越两面板时全自动正确。
    /// `stylePanelVisible == false` → 一次清掉两面板（对齐 `setStylePanelVisible(false)`/`clearAllShields()`
    /// 语义）；`true` 但几何未到齐 → `setStylePanelVisible(true)` 置两面板 `.pending`（fail-closed 窗口）。
    @MainActor
    private func refreshShields() {
        guard stylePanelVisible else { engine.drawingSession.clearAllShields(); return }
        guard stylePanelChartFrame != nil, upperPanelChartFrame != nil, lowerPanelChartFrame != nil else {
            engine.drawingSession.setStylePanelVisible(true)
            return
        }
        let overlay = stylePanelChartFrame!, upper = upperPanelChartFrame!, lower = lowerPanelChartFrame!
        for (panel, pf) in [(PanelId.upper, upper), (PanelId.lower, lower)] {
            let hit = overlay.intersection(pf)
            if hit.isNull || hit.isEmpty {
                engine.drawingSession.setShield(.unshielded, panel: panel)          // 面板没盖到这半 → 正常落线
            } else {
                // canonical 空间 = 目标面板局部（与 handleDrawingTap 的 tap point 同一空间）
                engine.drawingSession.setShield(.rect(hit.offsetBy(dx: -pf.minX, dy: -pf.minY)), panel: panel)
            }
        }
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
