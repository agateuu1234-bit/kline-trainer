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
        // 公共入口对未实现工具 fail-closed（whole-branch R2-high）；本测试要的是「多锚工具 pending
        // 跨面板存活」这个 1a-iii 才会真实可达的场景 —— 借内部 API 手动维持不变量（两面板都武装）。
        e.drawingSession.activate(tool: .trend)       // 容器可持有任何工具（1a-iii 才开放公共入口）
        e.armPanelForDrawing(.trend, panel: .upper)    // 手动维持不变量：两面板都武装
        e.armPanelForDrawing(.trend, panel: .lower)
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

    // MARK: 两个 HIGH finding 的回归锁：cancelDrawingAllPanels 不再是 no-op / activateDrawingTool 不再造裂脑

    @Test("finding-1 回归：cancelDrawingAllPanels 在会话 ACTIVE 时**不是** no-op —— 整场收干净")
    func cancelAllPanelsEndsActiveSession() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()                                // 会话 ACTIVE，两面板 .drawing
        e.drawingSession.addAnchor(DrawingAnchor(period: .m3, candleIndex: 1, price: 10), panel: .upper)
        #expect(e.drawingSession.drawingModeActive == true)  // 前置：确实开着（不是测了个已关的假绿）

        e.cancelDrawingAllPanels()                            // 本方法曾在会话 ACTIVE 时静默 no-op（finding-1）

        #expect(e.drawingSession.drawingModeActive == false)  // 会话真被关了
        #expect(e.drawingSession.activeDrawingTool == nil)
        #expect(e.drawingSession.pendingAnchors.isEmpty)
        #expect(e.isDrawingActive(on: .upper) == false)       // 两面板都退出 .drawing
        #expect(e.isDrawingActive(on: .lower) == false)
        assertInvariant(e)
    }

    @Test("finding-2 回归：公共 activateDrawingTool(panel:) 不再造裂脑 —— 两面板同进 .drawing + 会话同步为真")
    func publicActivateDrawingToolArmsBothPanelsNoSplitBrain() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)

        // .trend 尚未实现（公共入口 fail-closed，whole-branch R2-high）；本测试测的是「公共入口不造裂脑」，
        // 与具体工具无关，改用已实现的 .horizontal 即可复现同一回归场景。
        e.activateDrawingTool(.horizontal, panel: .upper)     // 曾经只武装 upper（finding-2 裂脑：panel 侧 true，会话侧 false）

        #expect(e.drawingSession.drawingModeActive == true)   // 会话真相同步跟上，不是「面板亮了会话没开」
        #expect(e.isDrawingActive(on: .upper) == true)
        #expect(e.isDrawingActive(on: .lower) == true)        // lower 没被落下
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        assertInvariant(e)
    }

    // MARK: whole-branch R2-high 回归锁：公共入口对「未实现工具」fail-closed（不再卡死画不出线的会话）

    @Test("whole-branch R2-high 回归：beginDrawingSession(未实现工具) fail-closed —— 不开会话、不留半武装残留")
    func beginDrawingSessionRejectsUnimplementedTool() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)

        e.beginDrawingSession(tool: .trend)   // .trend 的 shouldCommit 恒 false（DefaultDrawingInputController）

        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.drawingSession.activeDrawingTool == nil)
        #expect(e.drawingSession.pendingAnchors.isEmpty)
        #expect(e.isDrawingActive(on: .upper) == false)   // 两面板都没被半武装
        #expect(e.isDrawingActive(on: .lower) == false)
        assertInvariant(e)
    }

    @Test("whole-branch R2-high 回归：公共 activateDrawingTool(未实现工具) 同样 fail-closed（继承 beginDrawingSession 的守卫）")
    func activateDrawingToolRejectsUnimplementedTool() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)

        e.activateDrawingTool(.trend, panel: .upper)

        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.drawingSession.activeDrawingTool == nil)
        #expect(e.drawingSession.pendingAnchors.isEmpty)
        #expect(e.isDrawingActive(on: .upper) == false)
        #expect(e.isDrawingActive(on: .lower) == false)
        assertInvariant(e)
    }

    // MARK: whole-branch R4-medium 回归锁（1a-iv 升级）：画线期间 resize/旋转 → offset 必须**当场**被归一

    @Test("whole-branch R4-medium 回归（1a-iv 升级）：画线中途转屏/resize → offset **当场**被归一（视口解冻后不再等退出画线才补）")
    func resizeDuringContinuousDrawingIsNormalized() {
        // fixture 必须**真的滚得动**：200 根 m3、起始 tick=150 → 左侧有历史，maxOffset>0。
        let (e, _) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let wide = TrainingEnginePanLinkageTests.bounds        // 800×600，makeEngine 已 recordRenderBounds

        // ① 先滚动出一个非零 offset（freeScrolling）
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: wide, panel: .upper)
        e.endPan(velocity: 0, renderBounds: wide, panel: .upper)
        #expect(e.upperPanel.offset > 0)                       // 防假绿：确实滚出了 offset

        // ② 进画线模式（会话持续，画完一条也不退出）
        e.toggleDrawingMode()
        #expect(e.isDrawingActive(on: .upper))

        // ③ 画线期间转屏/resize：变窄后 maxOffset 变小，原 offset 越界。
        //    1a-iv 起 `.drawing` 接受 `.offsetApplied` → recordRenderBounds 的归一**当场**生效。
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 480)
        e.recordRenderBounds(narrow, panel: .upper)
        e.recordRenderBounds(narrow, panel: .lower)
        let during = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: narrow)
        #expect(e.upperPanel.offset <= during.maxOffset)       // 改造前：> maxOffset，要等退出画线才补
        #expect(e.upperPanel.offset >= during.minOffset)
        assertInvariant(e)                                     // 归一不得把面板踢出 .drawing

        // ④ 退出画线后依然合法（会话结束的补跑归一是幂等防御）
        e.toggleDrawingMode()
        let after = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: narrow)
        #expect(e.upperPanel.offset <= after.maxOffset)
        #expect(e.upperPanel.offset >= after.minOffset)
        assertInvariant(e)
    }

    // MARK: whole-branch R3-high 回归锁：公共「进画线 → 退画线」序列必须真的能退出来（不许卡死）

    @Test("whole-branch R3-high 回归：activateDrawingTool 之后 commitDrawing —— 必须真的退出画线（不是 no-op 卡死）")
    func publicActivateThenCommitActuallyExitsDrawing() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)

        e.activateDrawingTool(.horizontal, panel: .upper)   // 公共入口：开全局会话（两面板武装）
        #expect(e.drawingSession.drawingModeActive == true)

        e.commitDrawing(panel: .upper)                      // 公共既有用法：提交并退出画线 FSM

        // 修复前：fail-closed 守卫让它静默 no-op → 会话还开着、两面板还在 .drawing → 调用者永久卡死。
        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.drawingSession.activeDrawingTool == nil)
        #expect(e.isDrawingActive(on: .upper) == false)
        #expect(e.isDrawingActive(on: .lower) == false)     // 全局会话：两个面板一起退出
        assertInvariant(e)
    }

    @Test("whole-branch R3-high 回归：activateDrawingTool 之后 cancelDrawing —— 同样必须真的退出画线")
    func publicActivateThenCancelActuallyExitsDrawing() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)

        e.activateDrawingTool(.horizontal, panel: .upper)
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)

        e.cancelDrawing(panel: .lower)                      // 注意：连「另一个面板」调都得能收干净

        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.drawingSession.pendingAnchors.isEmpty)    // pending 也收干净，不留残渣
        #expect(e.isDrawingActive(on: .upper) == false)
        #expect(e.isDrawingActive(on: .lower) == false)
        assertInvariant(e)
    }

    @Test("对照（防假绿）：会话未开时 commitDrawing/cancelDrawing 保持原有面板级 FSM 语义（只动被点名的那个面板）")
    func panelLevelFSMSemanticsPreservedWhenNoSession() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)

        e.armPanelForDrawing(.horizontal, panel: .upper)    // 只武装上面板（会话未开）
        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.isDrawingActive(on: .upper) == true)

        e.commitDrawing(panel: .upper)                      // 会话没开 → 走原面板级语义
        #expect(e.isDrawingActive(on: .upper) == false)
        #expect(e.drawingSession.drawingModeActive == false)
    }

    @Test("对照（防假绿）：beginDrawingSession(.horizontal) 仍能正常开会话 —— 守卫只挡未实现工具，不是焊死整条路径")
    func beginDrawingSessionStillAcceptsImplementedTool() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)

        e.beginDrawingSession(tool: .horizontal)

        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        #expect(e.isDrawingActive(on: .upper) == true)
        #expect(e.isDrawingActive(on: .lower) == true)
        assertInvariant(e)
    }

    // MARK: 1a-iv 视口解冻：画线会话开着时，平移 / 缩放必须真的作用到视口

    @Test("1a-iv：画线会话开着时单指平移真的移动图表（1a-iii 及以前 offset 恒不动）")
    func panMovesChartWhileDrawing() {
        // fixture 必须**真的滚得动**：200 根 m3、起始 tick=150 → 左侧有历史，maxOffset>0。
        let (e, _) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let wide = TrainingEnginePanLinkageTests.bounds        // 800×600，makeEngine 已 recordRenderBounds
        e.toggleDrawingMode()
        #expect(e.isDrawingActive(on: .upper))                 // 防假绿：确实在画线态，不是普通滚动
        let before = e.upperPanel.offset

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 120, renderBounds: wide, panel: .upper)

        #expect(e.upperPanel.offset > before)                  // 改造前：恒 == before（reducer 吞）
        e.endPan(velocity: 0, renderBounds: wide, panel: .upper)
        assertInvariant(e)                                     // 平移不得把面板踢出 .drawing
        #expect(e.drawingSession.drawingModeActive == true)
    }

    @Test("1a-iv：画线会话开着时双指缩放真的改变 visibleCount，且走 focus 路径（不右锚跳回最新）")
    func pinchZoomsWhileDrawing() {
        let (e, _) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let wide = TrainingEnginePanLinkageTests.bounds
        // 先滚出非零 offset —— 只有此时「右锚(offset=0)」与「focus 保持」才可区分
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 300, renderBounds: wide, panel: .upper)
        e.endPan(velocity: 0, renderBounds: wide, panel: .upper)
        #expect(e.upperPanel.offset > 0)                       // 防假绿

        e.toggleDrawingMode()
        let countBefore = e.upperPanel.visibleCount
        e.applyPinch(scale: 1.0, focusX: wide.midX, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: wide.midX, phase: .changed, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: wide.midX, phase: .ended, panel: .upper)

        #expect(e.upperPanel.visibleCount != countBefore)      // 改造前：恒不变（reducer 吞）
        #expect(e.upperPanel.offset != 0)                      // 走 focus 路径，不是右锚置 0 跳回最新
        assertInvariant(e)
    }

    @Test("1a-iv：画线模式甩动起惯性后，settleDeceleration(initiatedBy:) 必须把两面板都定住（落锚不得对着移动中的视口）")
    func settleDecelerationStopsInertiaOnBothPanels() {
        // ⚠️ fixture 必须**真的滚得动**（codex plan-R6-high）：`engineMultiPeriod()` 只有 2 根 m60 / 1 根 daily，
        // maxOffset≈0 → 惯性根本跑不起来，「惯性在跑」的前置断言会红或被人调松，整条测试变空气。
        let (e, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds       // 800×600，makeEngine 已 recordRenderBounds
        #expect(RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: bounds).maxOffset > 0)   // 前置：真有滚动空间
        e.toggleDrawingMode()
        #expect(e.isDrawingActive(on: .upper))                 // 前置：真在画线态

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 200, renderBounds: bounds, panel: .upper)
        e.endPan(velocity: 3000, renderBounds: bounds, panel: .upper)   // 大速度 → 起惯性
        _ = fakes().last?.fire(1.0 / 60.0)
        let mid = e.upperPanel.offset
        _ = fakes().last?.fire(1.0 / 60.0)
        #expect(e.upperPanel.offset != mid)                    // 防假绿：惯性确实在跑（否则本测试测的是空气）

        e.settleDeceleration(initiatedBy: .upper)

        let settledUpper = e.upperPanel.offset
        let settledLower = e.lowerPanel.offset
        for _ in 0..<10 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(e.upperPanel.offset == settledUpper)           // ⭐已定住，后续帧不再改 offset
        #expect(e.lowerPanel.offset == settledLower)           // ⭐follower 也不再被联动驱动
        assertInvariant(e)                                     // 定住不得把面板踢出 .drawing
    }

    @Test("1a-iv：甩上面板起惯性后立刻捏合**下**面板 —— 上面板的减速不得再经联动改下面板 offset")
    func pinchOnOnePanelSettlesTheOtherPanelsInertia() {
        // fixture 同上：必须真的滚得动（codex plan-R6-high）
        let (e, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds
        #expect(RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: bounds).maxOffset > 0)
        e.toggleDrawingMode()

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 200, renderBounds: bounds, panel: .upper)
        e.endPan(velocity: 3000, renderBounds: bounds, panel: .upper)   // 上面板起惯性
        _ = fakes().last?.fire(1.0 / 60.0)
        let lowerMid = e.lowerPanel.offset
        _ = fakes().last?.fire(1.0 / 60.0)
        #expect(e.lowerPanel.offset != lowerMid)                        // 防假绿：上面板减速确实在经联动驱动下面板

        e.applyPinch(scale: 1.0, focusX: bounds.midX, phase: .began, panel: .lower)   // 捏合**下**面板

        let lowerAtPinchStart = e.lowerPanel.offset
        for _ in 0..<10 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(e.lowerPanel.offset == lowerAtPinchStart)               // ⭐上面板的 stale 减速不再动下面板
        assertInvariant(e)
    }

    @Test("1a-iv：在 overscroll 回弹中途定住 —— 夹回界内后两面板右缘仍对齐同一 tick（不留错位）")
    func settleDuringBounceKeepsPanelsTimeAligned() {
        let (e, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds
        e.toggleDrawingMode()

        // 拖到**超过 maxOffset**（最老边橡皮筋）再松手 → 走 bounce 分支（allowOverscroll）
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: bounds)
        #expect(ob.maxOffset > 0)                                    // 前置：真有滚动空间
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset + 400, renderBounds: bounds, panel: .upper)
        e.endPan(velocity: 0, renderBounds: bounds, panel: .upper)
        _ = fakes().last?.fire(1.0 / 60.0)
        #expect(e.upperPanel.offset > ob.maxOffset)                  // 前置：确实还在越界区（否则测不到 clamp）

        e.settleDeceleration(initiatedBy: .upper)

        // ⭐夹回界内 + 两面板右缘仍指向同一个 global tick
        #expect(e.upperPanel.offset <= ob.maxOffset)
        let upperTick = PanLinkage.rightEdgeTick(offset: e.upperPanel.offset,
                                                 candles: e.allCandles[e.upperPanel.period] ?? [],
                                                 rawVisible: e.upperPanel.visibleCount,
                                                 bounds: bounds, tick: e.tick.globalTickIndex)
        let lowerTick = PanLinkage.rightEdgeTick(offset: e.lowerPanel.offset,
                                                 candles: e.allCandles[e.lowerPanel.period] ?? [],
                                                 rawVisible: e.lowerPanel.visibleCount,
                                                 bounds: bounds, tick: e.tick.globalTickIndex)
        #expect(upperTick == lowerTick)                              // ⭐无错位（补 propagate 之前这里会不等）
    }

    @Test("1a-iv：拖到越界时两指接管（先 cancelPan 再 pinch.began）—— 夹回后两面板右缘仍对齐同一 tick")
    func twoFingerTakeoverDuringOverscrollKeepsPanelsTimeAligned() {
        let (e, _) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds
        e.toggleDrawingMode()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: bounds)
        #expect(ob.maxOffset > 0)                                    // 前置：真有滚动空间

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset + 400, renderBounds: bounds, panel: .upper)
        #expect(e.upperPanel.offset > ob.maxOffset)                  // 前置：确实拖进了越界区

        // 真实 UIKit 时序：两指落下 → arbiter supersede 单指 → onPan(.cancelled) → cancelPan → 然后 pinch.began
        e.cancelPan(panel: .upper)
        e.applyPinch(scale: 1.0, focusX: bounds.midX, phase: .began, panel: .upper)

        #expect(e.upperPanel.offset <= ob.maxOffset)                 // 夹回界内
        let upperTick = PanLinkage.rightEdgeTick(offset: e.upperPanel.offset,
                                                 candles: e.allCandles[e.upperPanel.period] ?? [],
                                                 rawVisible: e.upperPanel.visibleCount,
                                                 bounds: bounds, tick: e.tick.globalTickIndex)
        let lowerTick = PanLinkage.rightEdgeTick(offset: e.lowerPanel.offset,
                                                 candles: e.allCandles[e.lowerPanel.period] ?? [],
                                                 rawVisible: e.lowerPanel.visibleCount,
                                                 bounds: bounds, tick: e.tick.globalTickIndex)
        #expect(upperTick == lowerTick)                              // ⭐无错位（补 propagate 之前这里会不等）
    }
}
