// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift
// Spec: docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md §3.1 / §3.3（1a-ii）
// D39 单一真相容器 / D42 全局会话 + 落锚归属被点击面板 / D31 只丢 pending 保工具 / D38 连续画线。
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingSession：画线共享状态容器（D39/D42/D31/D38）")
@MainActor
struct DrawingSessionTests {

    private func anchor(_ price: Double, period: Period = .m3) -> DrawingAnchor {
        DrawingAnchor(period: period, candleIndex: 3, price: price)
    }

    @Test("初始：会话关、无工具、无 pending")
    func initialState() {
        let s = DrawingSession()
        #expect(s.drawingModeActive == false)
        #expect(s.activeDrawingTool == nil)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    @Test("activate：开会话 + 置工具；同工具重复 activate 幂等且不丢 pending")
    func activateIsIdempotent() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.activate(tool: .horizontal)                       // 重复激活同一工具
        #expect(s.drawingModeActive == true)
        #expect(s.activeDrawingTool == .horizontal)
        #expect(s.pendingAnchors.count == 1)                // 未被误清
    }

    @Test("activate 换工具：丢 pending（旧工具的半成品不能混进新工具）")
    func switchingToolDiscardsPending() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.activate(tool: .trend)
        #expect(s.activeDrawingTool == .trend)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    @Test("D31：discardPendingAnchors 只丢 pending —— 工具与会话必须存活（绝不是 cancel）")
    func discardPendingKeepsToolAndSession() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.discardPendingAnchors()
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
        #expect(s.activeDrawingTool == .horizontal)         // ← 保工具（cancel() 会清掉，本 API 不许）
        #expect(s.drawingModeActive == true)                // ← 保会话
    }

    @Test("D42：落锚归属 = 被点击的面板（与 activePanel 无关）")
    func anchorOwnershipFollowsTappedPanel() {
        let s = DrawingSession()
        s.activate(tool: .trend)                            // 多锚工具：pending 才留得住
        s.addAnchor(anchor(10), panel: .lower)
        #expect(s.pendingAnchorPanel == .lower)
        #expect(s.pendingAnchors.count == 1)
    }

    @Test("D31 触发：下一锚落在**别的**面板 → 只丢 pending，工具存活，新锚归新面板")
    func anchorOnOtherPanelDiscardsPendingButKeepsTool() {
        let s = DrawingSession()
        s.activate(tool: .trend)
        s.addAnchor(anchor(10), panel: .upper)
        s.addAnchor(anchor(20), panel: .lower)              // 换面板落锚
        #expect(s.pendingAnchors.count == 1)                // 上面板那个被丢；只剩新的
        #expect(s.pendingAnchors.first?.price == 20)
        #expect(s.pendingAnchorPanel == .lower)
        #expect(s.activeDrawingTool == .trend)              // ← 工具没被连带清掉
        #expect(s.drawingModeActive == true)
    }

    @Test("对照：下一锚仍在**同一**面板 → 不丢 pending（判据是落锚面板，不是 activePanel）")
    func anchorOnSamePanelKeepsPending() {
        let s = DrawingSession()
        s.activate(tool: .trend)
        s.addAnchor(anchor(10), panel: .upper)
        s.addAnchor(anchor(20), panel: .upper)
        #expect(s.pendingAnchors.count == 2)
        #expect(s.pendingAnchorPanel == .upper)
    }

    @Test("非画线模式落锚 = no-op（不可表达「没有工具却攒着 pending」）")
    func addAnchorIgnoredWhenInactive() {
        let s = DrawingSession()
        s.addAnchor(anchor(10), panel: .upper)              // 未 activate
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    @Test("D38 连续画线：commit 后只清 pending —— 工具与会话保持不变")
    func commitKeepsToolAndSession() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        let obj = s.commitPending(panelPosition: 0)
        #expect(obj != nil)
        #expect(s.pendingAnchors.isEmpty)                   // pending 清了
        #expect(s.activeDrawingTool == .horizontal)         // ← 工具还在（改造前这里会变 nil）
        #expect(s.drawingModeActive == true)                // ← 会话还在（改造前会退出画线模式）
    }

    @Test("commit 产出：D29 周期绑定 = 首锚周期；isExtended 由 lineSubType 派生（矛盾不可表达）")
    func commitProducesConsistentObject() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10, period: .m15), panel: .lower)
        // 1a-iii：lineSubType 不再是 commitPending 入参，改经 defaultStyle 单一真相
        s.setDefaultStyle({ var st = DrawingDefaultStyle(); st.lineSubType = .straight; return st }())
        let straight = s.commitPending(panelPosition: 1)
        #expect(straight?.period == .m15)                   // D29：跟首锚周期，不跟面板位置
        #expect(straight?.panelPosition == 1)
        #expect(straight?.isExtended == false)
        #expect(straight?.lineSubType == .straight)

        s.addAnchor(anchor(11, period: .m15), panel: .lower)
        s.setDefaultStyle({ var st = DrawingDefaultStyle(); st.lineSubType = .ray; return st }())
        let ray = s.commitPending(panelPosition: 1)
        #expect(ray?.isExtended == true)                    // 不变量：isExtended == (lineSubType == .ray)
        #expect(ray?.lineSubType == .ray)
    }

    @Test("commit 无 pending / 无工具 → nil，且不改会话状态")
    func commitWithoutPendingReturnsNil() {
        let s = DrawingSession()
        #expect(s.commitPending(panelPosition: 0) == nil)   // 未激活
        s.activate(tool: .horizontal)
        #expect(s.commitPending(panelPosition: 0) == nil)   // 激活但无锚
        #expect(s.drawingModeActive == true)
        #expect(s.activeDrawingTool == .horizontal)
    }

    @Test("deactivate：关会话 + 清工具 + 丢 pending（幂等）")
    func deactivateClearsEverything() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        s.deactivate()
        s.deactivate()                                      // 幂等
        #expect(s.drawingModeActive == false)
        #expect(s.activeDrawingTool == nil)
        #expect(s.pendingAnchors.isEmpty)
        #expect(s.pendingAnchorPanel == nil)
    }

    // ── Task 1（1a-iii）：默认样式原子流进提交 ──
    @Test("默认样式全 5 字段原子流进提交的线 + 标签色=线色")
    func defaultStyleFlowsIntoCommit() throws {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        var style = DrawingDefaultStyle()
        style.lineSubType = .ray; style.lineStyle = .dash2
        style.thickness = 3; style.colorToken = .red; style.labelMode = .right
        s.setDefaultStyle(style)
        s.addAnchor(anchor(10), panel: .upper)
        let obj = try #require(s.commitPending(panelPosition: 0))
        #expect(obj.lineSubType == .ray)
        #expect(obj.lineStyle == .dash2)
        #expect(obj.thickness == 3)
        #expect(obj.colorToken == .red)
        #expect(obj.labelMode == .right)
        #expect(obj.textColorToken == .red)       // codex plan-R7：标签色跟线色（否则标签渲染成默认橙）
        #expect(obj.isExtended == true)           // isExtended 由 lineSubType==.ray 派生（不变量保留）
        // 标签**渲染路径**真拿到线色（labelContent.colorToken 来自 textColorToken，codex plan-R7）
        let label = try #require(DrawingLabelLayout.labelContent(for: obj, lineVisible: true))
        #expect(label.colorToken == .red)
    }

    @Test("改默认只影响下一条：先画一条、改默认、再画一条 —— 第一条不变")
    func defaultChangeAffectsOnlyNextLine() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        let first = s.commitPending(panelPosition: 0)          // 默认橙/实线/1/直线/隐藏
        var style = DrawingDefaultStyle(); style.colorToken = .green
        s.setDefaultStyle(style)
        s.addAnchor(anchor(20), panel: .upper)
        let second = s.commitPending(panelPosition: 0)
        #expect(first?.colorToken == .orange)                  // 第一条不被回改
        #expect(second?.colorToken == .green)
    }

    @Test("straight 默认 → isExtended==false（派生不变量）")
    func straightDerivesNotExtended() {
        let s = DrawingSession(); s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        #expect(s.commitPending(panelPosition: 1)?.isExtended == false)
    }
}
