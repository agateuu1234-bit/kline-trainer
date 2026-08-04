// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift
// Spec: docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md §3.1（P1b-1a-ii）
// 母 spec: docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md §2 / §3 / §10
//
// D39 共享状态容器：底栏（1a-iii）与 ChartContainerView.Coordinator **共同消费**的单一真相。
//   —— 状态**不得**再留在各面板 Coordinator 私有（否则 updateUIView 会撤销工具选择，codex R15-high；
//      且下面板清不掉上面板的 pending，codex R31-high）。1b-i 的 selectedDrawingID / selectedPanel 进**同一容器**。
// D42 全局画线会话：drawingModeActive **不属于任何单一面板**；上下两面板都能落锚，
//   归属由**被点击的那个面板**决定（与 activePanel＝下单目标面板**无关**）。
// D31（前半）：discardPendingAnchors() —— **只丢 pending 锚**，保留 activeDrawingTool / drawingModeActive。
// D38：commit 后**不退出**画线模式、**不清**工具 → 支持连续画。
//
// 跨平台：@MainActor + @Observable，仅依赖 Models 值类型；无 UIKit → host swift test 全覆盖。
// D44（见 plan）：pending 锚由本容器直接持有，**不再**经 DrawingToolManager（toggle 非 set / enabledTools
//   闸门会让 addAnchor 撞 precondition / completedDrawings 重复增长三处硬伤）。DrawingObject 的
//   派生/归一化/可用性语义（D59，切片2）经 `withStyle` 统一把关（语义单点），commitPending 不再自行派生。

import Observation
import CoreGraphics   // ← 1a-iii Task2：PanelShield.rect(CGRect)

/// **访问级别是 load-bearing 的（codex plan-R5-high）**：类与**状态**是 `public`（只读，`private(set)`），
/// 但**所有 mutator 一律 internal**（`activate` / `deactivate` / `addAnchor` / `discardPendingAnchors` /
/// `commitPending` / `setDefaultStyle` 前面**没有** `public`，别手贱加上）。理由：`TrainingEngine.drawingSession` 是 `public let`，
/// 若 mutator 也 public，包外任何 client 都能 `engine.drawingSession.deactivate()` —— 绕过
/// `beginDrawingSession` / `endDrawingSessionIfActive` 这两个**唯一会同时更新两个面板 reducer** 的入口，
/// 于是「会话关了但面板还在 .drawing」/「会话开着但面板是 autoTracking」**又回来了**，正是本期要消灭的漂移。
/// 包内调用者只有两个：`TrainingEngine`（会话开关）与 `ChartContainerView.Coordinator`（落锚/提交），
/// 均由 Task 4 的源码守卫钉死；测试经 `@testable import` 照常可调。
@MainActor
@Observable
public final class DrawingSession {
    /// D42：全局画线会话开关。浮动钮（本期）/ 底栏「画图」钮（1a-iii）切换它。
    public private(set) var drawingModeActive: Bool = false

    /// D39：当前工具。**提交一条线后保持不变**（D38 连续画线）。
    public private(set) var activeDrawingTool: DrawingToolType?

    /// D57（1b-i）：画线态/选择态显式区分。取代母 spec 用 `activeDrawingTool == nil` 编码——
    /// nil 编码会让 `restoreDrawingSessionAfterPeriodChange` 的 guard 在选择态早退→裂脑（codex R1）。
    /// 会话存活期间 `activeDrawingTool` 恒非 nil；nil 重回唯一含义「没有会话」。
    public enum DrawingSessionMode: Equatable, Sendable { case draw, select }
    public private(set) var mode: DrawingSessionMode = .draw

    /// D41（1b-i PR-3）：选中态是 **`(selectedPanel, selectedDrawingID)` 二元组**，与 `activeDrawingTool`
    /// 同源存在本容器里（底栏、样式面板、tap 处理读写**同一份**，任何一方都不得私存副本）。
    /// **只带 id 不带 panel 会出错**：D29 周期绑定下，一条线会随切周期从 `selectedPanel` 迁到**另一个**
    /// 面板——它全局仍在 `drawings` 里，id-only 判据会让它在用户没选的那个面板里继续高亮、继续可操作。
    /// **D55：瞬时 UI 状态，绝不落盘**（`DrawingObject` 不新增字段，本容器不进任何存储路径）。
    public private(set) var selectedDrawingID: DrawingID?
    public private(set) var selectedPanel: PanelId?

    /// D54：建立选中。**fail-closed**：非选择态 / 无会话一律拒——这让「画线态里挂着一个选中」
    /// 这个坏状态**不可表达**（而不是靠每个调用点自觉先 setMode）。internal（同容器 mutator 纪律）。
    func setSelection(id: DrawingID, panel: PanelId) {
        guard drawingModeActive, mode == .select else { return }
        selectedDrawingID = id
        selectedPanel = panel
    }

    /// D54：清空选中。**二元组整体清**（只清 id 会留下半个二元组）。
    /// ⚠️ 判据一律是**状态**（态变了 / 结构性不可见 / id 不在 `drawings` 里），
    /// **绝不是**「某个写入 API 返回了 false」（D64；写入 API 的接线属 PR-4）。
    func clearSelection() {
        selectedDrawingID = nil
        selectedPanel = nil
    }

    /// D57：切换画线/选择态。切 `.select` 保留 activeDrawingTool、丢 pending（半成品多锚线不跨态存活）。
    /// D54 clause 2（1b-i PR-3）：**任何一次态切换都清空选中** —— 切回 `.draw` 时必须清（画线态不该有选中）；
    /// 切进 `.select` 时本来就没有可清的，无条件清让不变量「`mode == .draw` ⟹ 选中为空」由构造保证。
    /// internal（同容器 mutator 纪律）。
    func setMode(_ m: DrawingSessionMode) {
        mode = m
        clearSelection()
        discardPendingAnchors()
    }

    /// 未成形画线的锚点暂存（多锚工具用；.horizontal 落一锚即提交）。
    public private(set) var pendingAnchors: [DrawingAnchor] = []

    /// D31/D42：pending 锚的**归属面板** = 落锚时被点击的面板。**与 activePanel 无关**。
    public private(set) var pendingAnchorPanel: PanelId?

    /// 1a-iii：设置卡片写入的「下一条线」默认样式（单一真相，提交路径读它）。
    public private(set) var defaultStyle = DrawingDefaultStyle()

    /// 1a-iii：常驻样式面板（DrawingStyleParams，同包 UI 层；切片2 Task3 替代长按卡片）经此写默认样式。
    /// internal——包外不得直改。
    func setDefaultStyle(_ style: DrawingDefaultStyle) { defaultStyle = style }

    /// 1a-iii 切片2 Task2：某个面板当前的命中屏蔽状态。三态互斥 —— 「面板可见却没有任何屏蔽」这一危险状态
    /// **无法被表达**（它就是 `.pending`，而 `.pending` 一律拒收），故不需要额外的布尔量与守卫（codex 计划-R17-F2）。
    public enum PanelShield: Equatable, Sendable {
        // ⚠️刻意不叫 `.none`：`shield` 是 `[Int: PanelShield]`，取值是 `PanelShield?`，
        //   `shield[0] == .none` 会被 Swift 解析成 `Optional.none`（「字典里没这个 key」），
        //   与「该面板无屏蔽」混为一谈 —— 撞名陷阱，改名规避。
        case unshielded        // 无面板覆盖本面板 → 正常落线
        case pending           // 面板已挂载、真实几何尚未收敛 → **拒收一切 tap**（fail-closed）
        case rect(CGRect)      // 已知覆盖区（**面板局部坐标**）→ 只挡区内，区外正常落线
    }

    /// key 0=upper / 1=lower。缺省（无 key）等价 `.none`（这里指 Optional，非上面枚举的 case）。
    /// `ChartContainerView.handleDrawingTap` 读它决定是否拒绝落锚（防误画+autosave 幽灵线）。
    public private(set) var shield: [Int: PanelShield] = [:]

    /// `visible == true`：把**两个**面板置 `.pending`（同步、不经 preference）——`ChartPanelsContainer
    /// .refreshShields()` 在几何尚未到齐（`stylePanelChartFrame`/两个面板 frame 三者任一为 nil）时调用它，
    /// 是 fail-closed 窗口的唯一表达方式。`visible == false`：全清（面板真正不可见时的语义，`refreshShields()`
    /// 判定 `stylePanelVisible == false` 时调用）。**whole-branch fix（critical）**：`TrainingView` 的三个
    /// 生命周期 `onChange`（`drawingModeActive` / `typeRowExpanded` / `stylePanelPosition`）现在也调用
    /// `setStylePanelVisible(true)`（而非 `clearAllShields()`）——绝不能让面板可见期间出现「无 key」的
    /// 中间态：absent 在 `ChartContainerView.handleDrawingTap` 里读作 `.unshielded`（放行），若此刻
    /// `refreshShields()` 恰好因三个 frame 均未变化而不再重新触发（面板高度 + 16pt padding == 容器高时
    /// 可复现），absent 状态会一直留到面板消失为止。
    func setStylePanelVisible(_ visible: Bool) {
        if visible { shield[0] = .pending; shield[1] = .pending } else { shield.removeAll() }
    }

    /// 几何收敛后由 `refreshShields()` 写入某面板的最终状态（`.rect` 或 `.unshielded`）。
    func setShield(_ s: PanelShield, panel: PanelId) { shield[panel == .upper ? 0 : 1] = s }

    /// 一次清掉**所有**面板的屏蔽。**唯一**调用点是「面板真正卸载」的语义——`deactivate()`（退画线）与
    /// `TrainingView` 的 `.onDisappear`（view 消失/导航退出）。面板仍可见期间的生命周期事件（进/出画线、
    /// 收起/展开类型行、切上下半区）改调 `setStylePanelVisible(true)`（见上）而**不是**本方法——
    /// 清空会产生「面板可见却无 key」的裸奔窗口，只有面板真的不在了才允许清空。
    func clearAllShields() { shield.removeAll() }

    public init() {}

    /// 进入/保持画线会话并选定工具。同工具重复调用**幂等且不丢 pending**；
    /// 换工具则丢弃旧工具的半成品锚（否则会把上一个工具的锚混进新工具）。
    func activate(tool: DrawingToolType) {
        drawingModeActive = true
        mode = .draw                              // ← 在幂等 guard 之前（D57，否则选择态点回同工具态切不回）
        clearSelection()                          // ← D54 clause 2：跟着 mode 走，同样必须在幂等 guard 之前
        guard activeDrawingTool != tool else { return }
        activeDrawingTool = tool
        discardPendingAnchors()
    }

    /// 结束整场画线会话：关模式 + 清工具 + 丢 pending。幂等。
    /// **唯一**「整场结束」入口（旧 DrawingToolManager.cancel() 的角色）。
    func deactivate() {
        drawingModeActive = false
        activeDrawingTool = nil
        mode = .draw                              // 复位，防下次开会话继承旧态
        clearSelection()                          // D54 clause 1：退出画线模式即清空选中
        discardPendingAnchors()
        clearAllShields()   // 1a-iii Task2 模型不变量：退画线无残留盾（防死区拒收后续正常 tap）
    }

    /// D31：**只丢 pending 锚** —— activeDrawingTool 与 drawingModeActive 必须存活。
    /// 1a-iv 的「周期组合改变 → 丢 pending」复用本 API，**不得**另写一份取消语义。
    func discardPendingAnchors() {
        pendingAnchors = []
        pendingAnchorPanel = nil
    }

    /// 落锚。D42：归属 = 被点击的面板。D31：落在 ≠ pendingAnchorPanel 的面板 →
    /// 先只丢 pending（**保工具**），再在新面板起新锚。
    /// 非画线模式 / 无工具 → no-op（fail-closed：「没有工具却攒着 pending」不可表达）。
    func addAnchor(_ anchor: DrawingAnchor, panel: PanelId) {
        guard drawingModeActive, activeDrawingTool != nil, mode == .draw else { return }   // 选择态恒不落锚
        if let owner = pendingAnchorPanel, owner != panel {
            discardPendingAnchors()
        }
        pendingAnchors.append(anchor)
        pendingAnchorPanel = panel
    }

    /// pending → DrawingObject。**DrawingObject 的唯一写入点**：先造裸对象（锚/工具/面板位，与样式无关），
    /// 再经 `withStyle` 统一派生与归一化（D59 切片2语义单点：isExtended 派生 / textColorToken 条件派生 /
    /// labelMode 归一化 / lineSubType 可用性全部由 `withStyle` 承担，本函数不再自行派生任何字段）。
    /// **返回 nil = 该默认样式对本次 toolType 语义上不成立**（如水平线的 `.segment`，或越域 thickness）——
    /// 调用方（`ChartContainerView.handleDrawingTap`）据此不提交，本次画线数据丢弃、不落库。
    /// period 不传 → 由 DrawingObject.init 取 anchors.first.period（D29 周期绑定，不得回退）。
    /// revealTick 由 engine.routeDrawingCommit 盖真值。
    /// **D38：提交后只清 pending —— 工具与会话保持不变（连续画线）**。
    func commitPending(panelPosition: Int) -> DrawingObject? {
        guard mode == .draw, let tool = activeDrawingTool, !pendingAnchors.isEmpty else { return nil }
        // D31（1a-iv）：全锚必须同 period。`DrawingObject.init` 只取 `anchors.first.period`（D29 周期绑定），
        // 混 period 的锚集合存下去 = 后续所有锚的 candleIndex 被按错误周期解释的坏数据。
        // 拒交 + **只丢 pending**（保 activeDrawingTool / drawingModeActive，绝不整场取消）。
        // 本期水平线单锚、落锚即提交，实际触发不到；钩子供 P1c 的多锚工具复用（spec §5.1 #2）。
        guard let anchorPeriod = pendingAnchors.first?.period,
              pendingAnchors.allSatisfy({ $0.period == anchorPeriod }) else {
            discardPendingAnchors()
            return nil
        }
        let s = defaultStyle
        // D59（切片2）：样式语义闸**单点** —— 派生①②/归一化/可用性全部由 withStyle 承担，
        // 本函数不再自己派生任何字段（否则就有第二份语义，面板归一化一改就漂）。
        // 基对象只带「与样式无关」的部分：锚 / 工具 / 面板位 / period（由 init 从 anchors 取，D29）。
        let base = DrawingObject(
            toolType: tool,
            anchors: pendingAnchors,
            isExtended: false,          // 占位：随后由 withStyle 的派生① 覆盖
            panelPosition: panelPosition,
            revealTick: 0)              // 真值由 engine.routeDrawingCommit 盖
        discardPendingAnchors()
        return base.withStyle(s)        // nil = 该样式语义不成立（水平线 .segment）→ 不提交
    }
}
