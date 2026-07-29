// ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §3.1.2 / §3.3（#2 #4 #4b）+ plan D45。
// D42 全局会话（两面板同时可画、互斥模型退役）+ 不变量「drawingModeActive ⇔ 两面板 .drawing」。
import CoreGraphics        // CGRect（本包不 re-export CoreGraphics；漏了整包编译不过，codex plan-R2-medium）
import Foundation          // URL/FileManager（N23a 源码守卫：调用图扫描 Sources/）
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

    // MARK: N23a 源码守卫 helper（Task 5：append 家族信任边界，调用图 D67）
    // PR-2 Task 2：`contractsDir` / `allSwiftFilesUnderSources()` / `trainingEnginePath` 三个 suite 私有版本
    // 已删除，改用 SourceGuardScanner.swift 里的共享顶层函数（`contractsDirForGuards` / `allSwiftFilesUnderSources()` /
    // `trainingEnginePath`）——同一份判据两个 suite 共用，不许再抄局部副本。

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

    @Test("D31 真变化：画线时切周期 → **只丢 pending**（工具/会话/两面板 .drawing 全部存活）")
    func realPeriodChangeDiscardsOnlyPendingAnchors() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()                                    // 会话开：两面板 .drawing，工具 .horizontal
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        #expect(e.drawingSession.pendingAnchors.count == 1)      // 前置：确实攒着 pending

        e.switchPeriodCombo(direction: .toSmaller)               // (.m60,.daily) → (.m15,.m60) 真的能切成功

        #expect(e.upperPanel.period == .m15)                     // 周期真的变了（防假绿：不是撞 no-op 守卫）
        #expect(e.lowerPanel.period == .m60)
        #expect(e.drawingSession.pendingAnchors.isEmpty)         // pending 被丢
        #expect(e.drawingSession.pendingAnchorPanel == nil)
        #expect(e.drawingSession.activeDrawingTool == .horizontal)   // ⭐工具存活（不是 cancel/deactivate 语义）
        #expect(e.drawingSession.drawingModeActive == true)          // ⭐会话存活
        #expect(e.drawings.isEmpty)                              // 丢 pending 不产生画线
        assertInvariant(e)                                       // ⭐两面板重新回到 .drawing
    }

    @Test("D31 no-op（目标周期无数据）：pending 锚**原样保留** —— 判据是「周期变没变」不是「做没做手势」")
    func noOpPeriodSwitchKeepsPendingAnchors() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()   // 只有 m3/m15/m60/daily，无 weekly
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)

        e.switchPeriodCombo(direction: .toLarger)   // 目标 (.daily,.weekly)：weekly 无数据 → no-op

        #expect(e.upperPanel.period == .m60)                     // 前置：确实没变
        #expect(e.lowerPanel.period == .daily)
        #expect(e.drawingSession.pendingAnchors.count == 1)      // ⭐锚没被误杀
        #expect(e.drawingSession.pendingAnchorPanel == .upper)
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        #expect(e.drawingSession.drawingModeActive == true)
        assertInvariant(e)
    }

    @Test("D31 no-op（周期阶梯边界）：已是最粗组合再往粗切 → 周期不变、pending 不丢")
    func boundaryPeriodSwitchKeepsPendingAnchors() {
        // 全 6 周期 fixture：(.weekly,.monthly) 是阶梯最后一档，再 toLarger 越界 → no-op。
        let e = TrainingEngineActionsTests.comboEngine(upper: .weekly, lower: .monthly)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.drawingSession.addAnchor(DrawingAnchor(period: .weekly, candleIndex: 0, price: 10), panel: .upper)

        e.switchPeriodCombo(direction: .toLarger)   // 越界 → no-op

        #expect(e.upperPanel.period == .weekly)
        #expect(e.lowerPanel.period == .monthly)
        #expect(e.drawingSession.pendingAnchors.count == 1)      // ⭐边界 no-op 不误杀
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
        #expect(e.drawingSession.drawingModeActive == true)
        assertInvariant(e)
    }

    @Test("D31 no-op（阶梯表出现重复档位）：目标档与当前档相同 → 一切副作用都不许发生、不许裂脑")
    func duplicateComboEntryIsFullyNoOp() {
        // 造不出重复档位的真 fixture（periodCombos 是 private static let）→ 用**等价的可观测判据**：
        // 「目标档 == 当前档」在语义上就是「周期没变」，与边界 no-op 同类。这里锁的是**顺序契约**：
        // no-op 判据必须在 `.periodComboSwitched` 之前，否则面板已被打回 .autoTracking 而会话还开着。
        // 结构侧由下面的源码守卫钉死；行为侧由既有的两条 no-op 测试（边界 / 目标无数据）覆盖同一条早返路径。
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        e.switchPeriodCombo(direction: .toLarger)     // 目标 (.daily,.weekly)：weekly 无数据 → 早返
        assertInvariant(e)                            // ⭐早返路径不得留下裂脑（会话开着但面板 autoTracking）
        #expect(e.drawingSession.drawingModeActive == true)
    }

    @Test("D32 × D29 联合：画线模式内切周期后，原周期的线不再属于原面板（跟着它的 period 跑）")
    func drawingFollowsItsPeriodAcrossInDrawingPeriodSwitch() {
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        // 一条画在上面板（当时 .m60）的线。直接构造 DrawingObject：本条测的是 D29 归属判据，
        // 与提交路径无关（提交路径由 ChartContainerViewDrawingSessionTests 覆盖）。
        let line = DrawingObject(toolType: .horizontal,
                                 anchors: [DrawingAnchor(period: .m60, candleIndex: 1, price: 10)],
                                 isExtended: false, panelPosition: 0, revealTick: 0,
                                 lineSubType: .straight)
        #expect(RenderStateBuilder.belongsToPanel(line, panel: .upper,
                                                  upperPeriod: e.upperPanel.period,
                                                  lowerPeriod: e.lowerPanel.period))   // 前置：切之前在上面板

        e.switchPeriodCombo(direction: .toSmaller)     // (.m60,.daily) → (.m15,.m60)：.m60 挪到下面板

        #expect(!RenderStateBuilder.belongsToPanel(line, panel: .upper,
                                                   upperPeriod: e.upperPanel.period,
                                                   lowerPeriod: e.lowerPanel.period))  // ⭐不再渲染在上面板
        #expect(RenderStateBuilder.belongsToPanel(line, panel: .lower,
                                                  upperPeriod: e.upperPanel.period,
                                                  lowerPeriod: e.lowerPanel.period))   // ⭐跟着 .m60 跑到下面板
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

    // MARK: whole-branch codex R1-high 回归：退出画线会话必须停两面板惯性
    // Task 1 让 `.drawing` 的 `panEnded` 会起减速动画（改造前 `.drawing` 吞 panEnded、不起减速，这条路不存在）。
    // 但 `endDrawingSessionIfActive` / `cancelDrawingAllPanels` 两个 teardown 只 deactivate + cancelUnchecked +
    // 补跑一次性 normalize——不停 animator。于是：画线中甩一下起惯性 → 退出画线（回 autoTracking）→ animator
    // 仍在跑 → 后续减速帧继续 `.offsetApplied` 且被 autoTracking 接受、经 propagateLinkage 连带另一面板一起漂。

    @Test("whole-branch codex R1-high 回归：toggleDrawingMode 关闭画线会话必须停两面板惯性（否则退出后画面继续漂）")
    func toggleDrawingModeOffStopsInertiaOnBothPanels() {
        let (e, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds       // 800×600，makeEngine 已 recordRenderBounds
        e.toggleDrawingMode()
        #expect(e.isDrawingActive(on: .upper))                 // 前置：真在画线态

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 200, renderBounds: bounds, panel: .upper)
        e.endPan(velocity: 3000, renderBounds: bounds, panel: .upper)   // 大速度 → 起惯性
        _ = fakes().last?.fire(1.0 / 60.0)
        let mid = e.upperPanel.offset
        _ = fakes().last?.fire(1.0 / 60.0)
        #expect(e.upperPanel.offset != mid)                    // 防假绿：惯性确实在跑（否则本测试测的是空气）

        e.toggleDrawingMode()                                  // 退出画线（关闭会话）

        let after = e.upperPanel.offset
        let afterLower = e.lowerPanel.offset
        for _ in 0..<10 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(e.upperPanel.offset == after)                  // ⭐核心：退出画线后惯性已停，offset 不再变
        #expect(e.lowerPanel.offset == afterLower)             // ⭐follower 也不再被残留惯性经联动带着漂
    }

    @Test("whole-branch codex R1-high 回归：cancelDrawingAllPanels 必须停两面板惯性（否则退出后画面继续漂）")
    func cancelDrawingAllPanelsStopsInertiaOnBothPanels() {
        let (e, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let bounds = TrainingEnginePanLinkageTests.bounds
        e.toggleDrawingMode()
        #expect(e.isDrawingActive(on: .upper))                 // 前置：真在画线态

        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 200, renderBounds: bounds, panel: .upper)
        e.endPan(velocity: 3000, renderBounds: bounds, panel: .upper)   // 大速度 → 起惯性
        _ = fakes().last?.fire(1.0 / 60.0)
        let mid = e.upperPanel.offset
        _ = fakes().last?.fire(1.0 / 60.0)
        #expect(e.upperPanel.offset != mid)                    // 防假绿：惯性确实在跑

        e.cancelDrawingAllPanels()                             // 退出画线（取消整场会话）

        let after = e.upperPanel.offset
        let afterLower = e.lowerPanel.offset
        for _ in 0..<10 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(e.upperPanel.offset == after)                  // ⭐核心：退出画线后惯性已停，offset 不再变
        #expect(e.lowerPanel.offset == afterLower)             // ⭐follower 也不再被残留惯性经联动带着漂
    }

    // 注：本 bug 的第三条退出路径 `holdOrObserve` 未加回归测试——它经 `advanceAndAccount` 调用，
    // 而 `advanceAndAccount` 自己在最开头就调了 `stopAllDeceleration()`（D7：立即中断 free-scrolling 惯性），
    // **早于**其内部对 `endDrawingSessionIfActive()` 的调用。故 animator 在 teardown 方法运行前已被这条
    // 独立的既有路径停掉，无法在这条路径上复现本 bug（已用同形状探针实测确认：修复前即为绿，不是有效回归锁）。
    // `buy`/`sell` 同样经 `advanceAndAccount`，同一原因不受本 bug 影响。真正受影响的只有 teardown 被
    // **直接**调用、不经 `advanceAndAccount` 的路径——即上面两条：`toggleDrawingMode`(关) 与 `cancelDrawingAllPanels`。

    @Test("drawingsRevision: appendDrawing 成功严格 +1，appendReviewDrawing 不动它")
    @MainActor func drawingsRevisionCoversDrawingsNotReview() throws {
        let engine = TrainingEngine.preview()          // 既有测试工厂（同文件其它测试在用）
        #expect(engine.drawingsRevision == 0)
        #expect(engine.appendDrawing(makeHLine(candleIndex: 3, price: 10)) == true)
        #expect(engine.drawingsRevision == 1)                 // 严格 +1
        // review 侧不动 drawingsRevision（D56）
        #expect(engine.appendReviewDrawing(makeHLine(candleIndex: 4, price: 11)) == true)
        #expect(engine.drawingsRevision == 1)                 // 仍是 1
    }

    @Test("drawingsRevision: deleteDrawing(at:) 严格 +1")
    @MainActor func drawingsRevisionOnDelete() throws {
        let engine = TrainingEngine.preview()
        _ = engine.appendDrawing(makeHLine(candleIndex: 3, price: 10))
        let before = engine.drawingsRevision
        engine.deleteDrawing(at: 0)
        #expect(engine.drawingsRevision == before + 1)
    }

    // MARK: Task 5（D67 + D66 append 部分）：append 家族信任边界

    @Test("N23b: appendDrawing/appendReviewDrawing 拒 .segment（引擎层，direct-call），不动 revision")
    @MainActor func appendRejectsSegment() {
        let engine = TrainingEngine.preview()
        let seg = DrawingObject(id: "s", toolType: .horizontal,
                                anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                                isExtended: false, panelPosition: 0, period: .daily, lineSubType: .segment)
        let before = engine.drawingsRevision
        #expect(engine.appendDrawing(seg) == false)          // .segment 恒不可渲染 → 拒
        #expect(engine.drawings.isEmpty)
        #expect(engine.drawingsRevision == before)           // 拒绝不动 revision
        #expect(engine.appendReviewDrawing(seg) == false)
        #expect(engine.reviewDrawings.isEmpty)
    }

    @Test("N23b2: 横规则限横工具——水平 .segment 仍拒，但非水平（.trend）.segment 合法被接收（codex WB re-attest R1）")
    @MainActor func nonHorizontalSegmentAccepted() {
        let engine = TrainingEngine.preview()
        // 对照：水平线 .segment 恒不可渲染 → 仍拒（限定后行为不变，防「blanket 放开」回归）
        let hSeg = DrawingObject(id: "h", toolType: .horizontal,
                                 anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                                 isExtended: false, panelPosition: 0, period: .daily, lineSubType: .segment)
        #expect(engine.appendDrawing(hSeg) == false)
        // 非水平工具（.trend）的 .segment：横规则不适用 → 接收（此前被共享引擎门静默拒→丢线）
        let tSeg = DrawingObject(id: "t", toolType: .trend,
                                 anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                                 isExtended: false, panelPosition: 0, period: .daily, lineSubType: .segment)
        let before = engine.drawingsRevision
        #expect(engine.appendDrawing(tSeg) == true)
        #expect(engine.drawings.contains { $0.id == "t" })
        #expect(engine.drawingsRevision == before + 1)   // 接收 → revision +1（非拒绝）
        // review 侧同一判据
        let trSeg = DrawingObject(id: "tr", toolType: .trend,
                                  anchors: [DrawingAnchor(period: .daily, candleIndex: 4, price: 11)],
                                  isExtended: false, panelPosition: 0, period: .daily, lineSubType: .segment)
        #expect(engine.appendReviewDrawing(trSeg) == true)
        #expect(engine.reviewDrawings.contains { $0.id == "tr" })
    }

    @Test("N23d: appendDrawing/appendReviewDrawing 拒空 id / 重复 id，拒绝不动 revision（D66 append 部分，codex plan-R5-F1）")
    @MainActor func appendRejectsEmptyAndDuplicateId() {
        let engine = TrainingEngine.preview()
        // 空 id → 拒
        let empty = makeHLine(id: "", candleIndex: 3, price: 10)
        #expect(engine.appendDrawing(empty) == false)
        #expect(engine.drawings.isEmpty)
        #expect(engine.drawingsRevision == 0)
        // 正常一条
        #expect(engine.appendDrawing(makeHLine(id: "A", candleIndex: 3, price: 10)) == true)
        let after1 = engine.drawingsRevision
        // 重复 id → 拒、不动 revision
        #expect(engine.appendDrawing(makeHLine(id: "A", candleIndex: 4, price: 11)) == false)
        #expect(engine.drawings.count == 1)
        #expect(engine.drawingsRevision == after1)
        // review 侧独立判 reviewDrawings：同 id "A" 在 review 侧应可接受（不同数组）
        #expect(engine.appendReviewDrawing(makeHLine(id: "A", candleIndex: 5, price: 12)) == true)
        // review 侧再来一条同 id → 拒
        #expect(engine.appendReviewDrawing(makeHLine(id: "A", candleIndex: 6, price: 13)) == false)
        #expect(engine.reviewDrawings.count == 1)
    }

    @Test("N23a: append 家族非 public + 唯一调用点（源码守卫，调用图 D67，codex plan-R5-F2）")
    func appendFamilyTrustBoundary() throws {
        // (1) 访问级别：7 个 public 写入面全非 public（编辑 5 + 装载 2）
        let engineSrc = try String(contentsOfFile: trainingEnginePath, encoding: .utf8)
        for decl in ["appendDrawing(", "appendReviewDrawing(", "routeDrawingCommit(", "deleteDrawing(at ",
                     "removeReviewDrawing(at ", "setReviewLossy(", "setReviewDrawings("] {
            #expect(!engineSrc.contains("public func " + decl))
            #expect(engineSrc.contains("func " + decl))                       // 仍存在（internal）
        }
        // (2) 唯一调用点（**核心**：仅非 public 不够——包内新调用者仍能绕过 handleDrawingTap 的 geometry 门）。
        //     扫整个 Sources/，统计匹配 callPattern 的「调用」行（排除 defExclude 定义行与注释行）。
        //     ⚠️ callPattern 必须匹配【真实调用语法】（codex plan-R6-F3）：
        //        无标签调用 `xxx(...)` 用 "xxx("；带标签调用 `deleteDrawing(at: 0)` 用 "deleteDrawing(at:"（冒号），
        //        不能用 "deleteDrawing(at(" —— 那样永远匹配不到、守卫恒空恒过（假绿）。
        func callSites(callPattern: String, defExclude: String) throws -> [(file: String, line: String)] {
            try allSwiftFilesUnderSources().flatMap { path -> [(String, String)] in
                try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .filter { line in
                        let t = line.trimmingCharacters(in: .whitespaces)
                        return t.contains(callPattern) && !t.contains(defExclude) && !t.hasPrefix("//") && !t.hasPrefix("///")
                    }
                    .map { (path, $0) }
            }
        }
        // appendDrawing/appendReviewDrawing 各恰好 1 处调用（`appendDrawing(stamped)`），都在 routeDrawingCommit
        #expect(try callSites(callPattern: "appendDrawing(", defExclude: "func appendDrawing(").count == 1)
        #expect(try callSites(callPattern: "appendReviewDrawing(", defExclude: "func appendReviewDrawing(").count == 1)
        // routeDrawingCommit 恰好 1 处调用（`engine.routeDrawingCommit(committed)`），在 ChartContainerView.handleDrawingTap
        let route = try callSites(callPattern: "routeDrawingCommit(", defExclude: "func routeDrawingCommit(")
        #expect(route.count == 1)
        #expect(route.allSatisfy { $0.file.contains("ChartContainerView") })
        // deleteDrawing(at:) / removeReviewDrawing(at:) 零生产调用点（D51/D67）——调用语法带标签冒号 `xxx(at: 0)`；
        //   定义是 `func xxx(at index:`（`at ` 后无冒号），故 pattern `xxx(at:` 只命中调用、不命中定义。
        #expect(try callSites(callPattern: "deleteDrawing(at:", defExclude: "func deleteDrawing(at").isEmpty)
        #expect(try callSites(callPattern: "removeReviewDrawing(at:", defExclude: "func removeReviewDrawing(at").isEmpty)
        // 装载入口：setReviewLossy 只在 TrainingSessionCoordinator（复盘装载 :538）与 TrainingEngine
        //   （setReviewDrawings :315 委托调它）——不强求 count（委托是合法内部调用），只断言不在别处新增旁路。
        let reviewLossy = try callSites(callPattern: "setReviewLossy(", defExclude: "func setReviewLossy(")
        #expect(!reviewLossy.isEmpty)
        #expect(reviewLossy.allSatisfy { $0.file.contains("TrainingSessionCoordinator") || $0.file.contains("TrainingEngine") })
        // setReviewDrawings 零 Sources/ 调用点（其定义 :315 委托 setReviewLossy，被 defExclude 排除；测试经 @testable 调、不在 Sources/）
        #expect(try callSites(callPattern: "setReviewDrawings(", defExclude: "func setReviewDrawings(").isEmpty)
    }

    // MARK: 切片2 Task 3（D50/D58 引擎支/D62/D66）：updateDrawingStyle

    private func styleFixture(_ sub: LineSubType = .straight, _ ls: LineStyle = .solid, _ th: Int = 1,
                              _ c: DrawingColorToken = .orange, _ lm: LabelMode = .hidden) -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.lineSubType = sub; s.lineStyle = ls; s.thickness = th; s.colorToken = c; s.labelMode = lm
        return s
    }

    @Test("N2: updateDrawingStyle 只动 5 样式字段 + 两个派生，其余逐字段不变；revision +1")
    @MainActor func updateTouchesOnlyStyleFields() throws {
        let e = TrainingEngine.preview()
        let old = makeStyledHLine(id: "A", thickness: 1, text: "note", fontSize: 21)
        #expect(e.appendDrawing(old) == true)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.straight, .dash1, 4, .green, .right)) == true)
        let now = try #require(e.drawings.first { $0.id == "A" })
        #expect(e.drawingsRevision == rev + 1)
        // 变的
        #expect(now.lineStyle == .dash1); #expect(now.thickness == 4)
        #expect(now.colorToken == .green); #expect(now.labelMode == .right)
        // 不变的（逐字段）
        #expect(now.id == old.id); #expect(now.anchors == old.anchors); #expect(now.period == old.period)
        #expect(now.panelPosition == old.panelPosition); #expect(now.revealTick == old.revealTick)
        #expect(now.locked == old.locked); #expect(now.text == old.text); #expect(now.fontSize == old.fontSize)
        #expect(now.textForm == old.textForm); #expect(now.tailAnchor == old.tailAnchor)
    }

    @Test("N3: updateDrawingStyle 对不存在 id → false、drawings 逐字段不变、revision 不递增")
    @MainActor func updateUnknownIdIsNoop() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "ZZZ", style: styleFixture(.straight, .dash1, 4)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N12a: 引擎层恒开门——水平线改 .segment 被拒，该线逐字段不变、revision 不递增")
    @MainActor func updateRejectsUnrenderableSubType() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", lineSubType: .straight)) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.segment)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N5 行为 + N12d: 直调（绕开面板）传未归一化的 (ray,.left) → 结果 .hidden、isExtended 派生成立")
    @MainActor func updateNormalizesAndDerivesAtWriteBoundary() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", lineSubType: .straight, labelMode: .left)) == true)
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.ray, .solid, 1, .orange, .left)) == true)
        let now = try #require(e.drawings.first { $0.id == "A" })
        #expect(now.labelMode == .hidden)                    // (ray,.left) 不可表达
        #expect(now.isExtended == true)                      // 派生①
        // 改回 .straight → isExtended 回 false
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.straight)) == true)
        #expect(e.drawings.first { $0.id == "A" }?.isExtended == false)
    }

    @Test("N21c(update): id 匹配 ≥2 条 → fail，不改任何一条、revision 不递增（D66，绝不打第一条）")
    @MainActor func updateFailsOnAmbiguousId() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)
        // 绕过 append 的唯一性门，直接注入第二条同 id（模拟坏状态）
        e.injectDrawingsForTesting(e.drawings + [makeStyledHLine(id: "A", thickness: 2, candleIndex: 4)])
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.straight, .dash1, 5)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("D66: 空 id 恒 fail（写入边界不变量：id 非空）")
    @MainActor func updateRejectsEmptyId() throws {
        let e = TrainingEngine.preview()
        // fix round 1（Important 1）：夹具里若只有 id "A"，查 id "" 必然 matches.count==0，
        // 被下一道唯一性门挡下——测试通过与否跟 `guard !id.isEmpty` 这半截无关（恒真）。
        // 生产入口造不出 id=="" 的线，但 `Models.swift` 解码是 `decodeIfPresent(...) ?? ""`，
        // 缺 id 就得到空串——真实存在这类坏数据，故用 DEBUG hook 直接注入一条 id=="" 的线，
        // 使「没有这道门」时 matches.count==1 会真的走到底、真的改写它。
        e.injectDrawingsForTesting([makeStyledHLine(id: "")])   // 生产入口造不出，正是 hook 的用途
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "", style: styleFixture(.straight, .dash1)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("SD-7/D34 纵深防御: 复盘模式下 updateDrawingStyle 恒 fail（drawings = 已归档 record 的原训练线）")
    @MainActor func updateRefusedInReviewMode() throws {
        let e = TrainingEngine.preview(mode: .review)
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)   // 造出「归档线」状态
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.straight, .dash1, 5)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        // 反向对照：同样的调用在 normal 模式成功（防「一律拒绝」）
        let n = TrainingEngine.preview(mode: .normal)
        #expect(n.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)
        #expect(n.updateDrawingStyle(id: "A", style: styleFixture(.straight, .dash1, 5)) == true)
    }

    // MARK: 源码守卫扫描器 —— **Task 2 已建**（`Tests/.../SourceGuardScanner.swift` 的顶层函数），本文件直接调用：
    //   `squeeze` / `squeezedText` / `scanCode` / `consumeStringLiteral` / `squeezedSource` /
    //   `callCount(inSqueezed:pattern:)` / `callSiteCount(_:)` / `squeezedContains(_:_:)` /
    //   `filesMentioning(_:)` / `expectEngineInternalOnly(_:)`（同 test module 顶层函数，无需再声明）。
    //   ⚠️ **不得**在本文件另写一份扫描逻辑——同族判据留两档正是本计划一路在修的毛病。

    @Test("N15: updateDrawingStyle 非 public + Sources/ 中零调用点（切片2 语义；PR-4 接线时改成恰好 1 处）")
    func updateDrawingStyleTrustBoundary() throws {
        try expectEngineInternalOnly("updateDrawingStyle(id:")   // 存在 + 非 public/package/open（D62）
        // ⚠️ 本切片是引擎写入面，UI 编辑路由属 PR-4 → 现在**零调用点**。
        //    PR-4 接线时必须把本断言改成：恰好 1 处、且该文件是 UI 编辑路由、且路由在调用前先验
        //    HorizontalLineTool.visibleGeometry（D58 候选预检 + D65 当前门）。谁不补几何门就加调用点，
        //    这条当场红——这就是本守卫存在的意义（fail-closed forcing function）。
        let sites = try callSiteCount("updateDrawingStyle(")
        #expect(sites.isEmpty, "updateDrawingStyle 出现了非预期调用点：\(sites)")
        // **更强的一层（codex plan-R5-F1）**：连**方法引用**（`let f = engine.updateDrawingStyle`）都要挡——
        // 那种写法源码里不出现 `updateDrawingStyle(`，只数调用 pattern 会放过它，而几何门**只**靠
        // 「唯一调用点在已验几何的 UI 路由」这条守卫成立。故按**标识符的文件作用域**钉：
        // 本切片只许出现在引擎自身文件；PR-4 接线时把路由文件加进白名单（**只加那一个**）。
        let mentions = try filesMentioning("updateDrawingStyle")
        // fix round 1（Minor 2）：`.contains("TrainingEngine.swift")` 是路径子串匹配——任何叫
        // `XxxTrainingEngine.swift` 的文件都会被误判进白名单，绕过守卫。改成精确尾匹配
        // （目录 + 文件名都钉死），才真的只放行引擎自身这一个文件。
        #expect(mentions.allSatisfy { $0.hasSuffix("/TrainingEngine/TrainingEngine.swift") },
                "updateDrawingStyle 被引擎以外的文件提到（含方法引用）：\(mentions)")
    }
}
