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
//   **唯一写入点**语义（isExtended 由 lineSubType 派生）在 commitPending 内原样保留。

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
        guard activeDrawingTool != tool else { return }
        activeDrawingTool = tool
        discardPendingAnchors()
    }

    /// 结束整场画线会话：关模式 + 清工具 + 丢 pending。幂等。
    /// **唯一**「整场结束」入口（旧 DrawingToolManager.cancel() 的角色）。
    func deactivate() {
        drawingModeActive = false
        activeDrawingTool = nil
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
        guard drawingModeActive, activeDrawingTool != nil else { return }
        if let owner = pendingAnchorPanel, owner != panel {
            discardPendingAnchors()
        }
        pendingAnchors.append(anchor)
        pendingAnchorPanel = panel
    }

    /// pending → DrawingObject。**DrawingObject 的唯一写入点**：isExtended 从 lineSubType 派生
    /// （不变量 isExtended == (lineSubType == .ray)；矛盾数据不可表达）。
    /// **1a-iii：5 样式字段全部从 defaultStyle 原子读取**——在 append 之前就灌满，
    /// 让 routeDrawingCommit 的 append 成为 drawings 的唯一改动（count 触发一次即完整落盘，
    /// 杜绝「先 append 默认样式、再原地改样式」的提交后套用不落盘缺陷，codex branch-R1/R2）。
    /// period 不传 → 由 DrawingObject.init 取 anchors.first.period（D29 周期绑定，不得回退）。
    /// revealTick 由 engine.routeDrawingCommit 盖真值。
    /// **D38：提交后只清 pending —— 工具与会话保持不变（连续画线）**。
    func commitPending(panelPosition: Int) -> DrawingObject? {
        guard let tool = activeDrawingTool, !pendingAnchors.isEmpty else { return nil }
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
        let drawing = DrawingObject(
            toolType: tool,
            anchors: pendingAnchors,
            isExtended: s.lineSubType == .ray,
            panelPosition: panelPosition,
            revealTick: 0,
            lineSubType: s.lineSubType,
            lineStyle: s.lineStyle,
            thickness: s.thickness,
            colorToken: s.colorToken,
            labelMode: s.labelMode,
            // codex plan-R7-medium：价格标签渲染用 textColorToken（DrawingLabelLayout.labelContent:75），
            // 本期卡片只有一个「颜色」控件（线色）→ 标签跟线同色，否则蓝线配橙标签。
            // （独立「字色」是 P3 的标注文字工具，本期不引入。）
            textColorToken: s.colorToken)
        discardPendingAnchors()
        return drawing
    }
}
