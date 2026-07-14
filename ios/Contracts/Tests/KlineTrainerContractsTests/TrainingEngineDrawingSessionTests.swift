// ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §3.1.2 / §3.3（#2 #4 #4b）+ plan D45。
// D42 全局会话（两面板同时可画、互斥模型退役）+ 不变量「drawingModeActive ⇔ 两面板 .drawing」。
import CoreGraphics        // CGRect（本包不 re-export CoreGraphics；漏了整包编译不过，codex plan-R2-medium）
import Testing
@testable import KlineTrainerContracts

@Suite("TrainingEngine × DrawingSession：全局画线会话 + 不变量")
@MainActor
struct TrainingEngineDrawingSessionTests {

    /// 不变量（本期唯一真相判据）：会话开 ⇔ 两面板都在 .drawing。
    private func assertInvariant(_ e: TrainingEngine, sourceLocation: SourceLocation = #_sourceLocation) {
        let on = e.drawingSession.drawingModeActive
        #expect(e.isDrawingActive(on: .upper) == on, sourceLocation: sourceLocation)
        #expect(e.isDrawingActive(on: .lower) == on, sourceLocation: sourceLocation)
    }

    @Test("D42：开画线模式 → **两个面板**同时进 .drawing（互斥模型已退役）")
    func toggleOnArmsBothPanels() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        #expect(e.isDrawingActive(on: .upper) == true)
        #expect(e.isDrawingActive(on: .lower) == true)      // ← 改造前只有 activePanel 那一个
        assertInvariant(e)
    }

    @Test("再 toggle → 关会话 + 两面板退出 .drawing + pending 丢弃")
    func toggleOffEndsSession() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .m3, candleIndex: 1, price: 10), panel: .upper)
        e.toggleDrawingMode()
        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.drawingSession.activeDrawingTool == nil)
        #expect(e.drawingSession.pendingAnchors.isEmpty)
        assertInvariant(e)
    }

    @Test("D45：买入 → 隐式退出画线会话（不变量不漂移：不会「钮还亮着但画不了」）")
    func buyEndsDrawingSession() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .m3, candleIndex: 1, price: 10), panel: .upper)
        _ = e.buy(panel: .upper, shares: 100)
        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.drawingSession.pendingAnchors.isEmpty)
        assertInvariant(e)                                   // ← 核心：会话与面板 mode 同生同死
    }

    @Test("D45：持有/观察（复盘「下一根」同路径）→ 隐式退出画线会话")
    func holdEndsDrawingSession() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.holdOrObserve(panel: .upper)
        #expect(e.drawingSession.drawingModeActive == false)
        assertInvariant(e)
    }

    // ⚠️ 这两个测试**必须**用 `engineMultiPeriod()`，**不能**用 `TrainingEngine.preview()`：
    // preview 的 allCandles 只有 .m3/.m60/.daily（**没有 .m15**），当前组合 (.m60,.daily) 无论
    // toSmaller（→ 需 .m15）还是 toLarger（→ 需 .weekly）都会撞 switchPeriodCombo 的「target 周期无数据 → no-op」
    // 守卫 → **加不加画线守卫都 no-op**，测试恒绿 = 假守卫，什么也没测到。
    // engineMultiPeriod() 备了 .m15/.m60/.daily，(.m60,.daily) --toSmaller--> (.m15,.m60) 是能真切成功的。

    @Test("codex plan-R7：**直接调** switchPeriodCombo（绕过手势）在画线时是 no-op —— 不变量结构上破不了")
    func periodSwitchIsNoOpWhileDrawing() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        let upBefore = e.upperPanel.period            // .m60
        let lowBefore = e.lowerPanel.period           // .daily
        e.beginDrawingSession(tool: .trend)
        e.drawingSession.addAnchor(DrawingAnchor(period: upBefore, candleIndex: 1, price: 10), panel: .upper)

        e.switchPeriodCombo(direction: .toSmaller)    // 直接调（不经手势）；无守卫时这里会真切成 (.m15,.m60)

        #expect(e.upperPanel.period == upBefore)      // 周期没变（fail-closed no-op）
        #expect(e.lowerPanel.period == lowBefore)
        #expect(e.drawingSession.drawingModeActive == true)      // 会话没被取消（不是 cancel 语义，D31）
        #expect(e.drawingSession.activeDrawingTool == .trend)    // 工具还在
        #expect(e.drawingSession.pendingAnchors.count == 1)      // pending 没丢（丢 pending 是 1a-iv 的 D32）
        assertInvariant(e)                                       // 两面板仍 .drawing —— 没被 .periodComboSwitched 打回
    }

    @Test("对照（防假绿）：**退出**画线后切周期恢复正常 —— 守卫不是把功能焊死")
    func periodSwitchWorksAfterLeavingDrawing() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()          // 开
        e.toggleDrawingMode()          // 关
        e.switchPeriodCombo(direction: .toSmaller)
        #expect(e.upperPanel.period == .m15)          // 真的切了（证明上一个测试的 no-op 是守卫造成的）
        #expect(e.lowerPanel.period == .m60)
        assertInvariant(e)
    }

    @Test("codex plan-R6：手势层同样切不了周期（画线吞竖滑）；1a-iv 放开 D32 时本测试变红")
    func periodSwitchUnreachableWhileDrawing() {
        // 切周期的**唯一**产生条件（见 GestureClassifiersTests:407-420）：phase == .ended
        // + lifecycle == .verticalRejected + 净竖移 >= 40。用这个精确形状造，否则测的是空气。
        let swipeUp = CGPoint(x: 0, y: -50)

        // 画线模式：drawingTakesOver 分支的每个 return 都 periodSwipe == nil（GestureClassifiers.swift:113-121）
        let drawing = singlePanStep(phase: .ended, cumulative: swipeUp, velocityX: 0,
                                    lifecycle: .verticalRejected, lastTranslationX: 0,
                                    drawingTakesOver: true)
        #expect(drawing.periodSwipe == nil,
                "画线模式下竖滑不得切周期。若本条变红 = 1a-iv 的 D32 放开了竖滑 → 必须按 D31 用 discardPendingAnchors() 处理 pending，并同步维护「会话 ⇔ 两面板 .drawing」不变量，不许静默漂移")

        // 对照（防假绿）：非画线模式下**同样**的手势确实会切周期 —— 证明上面的 nil 不是参数造错造出来的
        let normal = singlePanStep(phase: .ended, cumulative: swipeUp, velocityX: 0,
                                   lifecycle: .verticalRejected, lastTranslationX: 0,
                                   drawingTakesOver: false)
        #expect(normal.periodSwipe == .up)
    }

    @Test("codex plan-R9：零 render bounds（首帧未布局）下开会话 —— 不变量仍成立，绝不出现「钮亮着但画不了」")
    func beginSessionWithZeroBoundsKeepsInvariant() {
        let e = TrainingEngine.preview()          // 故意**不**调 recordRenderBounds → bounds 全是 .zero
        e.toggleDrawingMode()
        // 事务性：要么两面板都进 .drawing 且会话开；要么全都没开。**不允许**一半一半。
        assertInvariant(e)
        if e.drawingSession.drawingModeActive {
            #expect(e.drawingSession.activeDrawingTool == .horizontal)
        } else {
            #expect(e.drawingSession.activeDrawingTool == nil)   // 回滚干净：工具不残留
            #expect(e.drawingSession.pendingAnchors.isEmpty)
        }
    }

    @Test("codex plan-R9：只有一个面板有 render bounds —— 同样不许出现半开状态")
    func beginSessionWithOneSidedBoundsKeepsInvariant() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)   // 只给上面板
        e.toggleDrawingMode()
        assertInvariant(e)                        // 会话开 ⇔ **两个**面板都在 .drawing
    }

    @Test("endDrawingSessionIfActive 幂等：未开会话时调用不炸、不改任何状态")
    func endSessionIsIdempotent() {
        let e = TrainingEngine.preview()
        e.endDrawingSessionIfActive()
        e.endDrawingSessionIfActive()
        #expect(e.drawingSession.drawingModeActive == false)
        assertInvariant(e)
    }

    @Test("D42/#4b：切 activePanel 是纯 View 状态 —— 引擎**没有**任何按 activePanel 取消画线的 API")
    func noActivePanelScopedCancelAPI() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .m3, candleIndex: 1, price: 10), panel: .upper)
        // 切下单目标面板在 TrainingView 里只是改 @State activePanel —— 引擎不参与、pending 与会话原封不动。
        // （toggleDrawingExclusive 已删除；本测试锁死「引擎无 activePanel 语义」这一事实。）
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.pendingAnchors.count == 1)
        #expect(e.drawingSession.pendingAnchorPanel == .upper)
        assertInvariant(e)
    }
}
