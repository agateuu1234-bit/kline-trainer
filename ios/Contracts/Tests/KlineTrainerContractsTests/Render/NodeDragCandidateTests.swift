// ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragCandidateTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D140b / D140c / T11 / T12）
//
// 平台门：UIKit-only（触 ChartContainerView.Coordinator / KLineView，macOS host swift test 整份不编译，
// 同既有先例 ChartContainerViewDrawingSessionTests.swift / DrawingTapHitShieldTests.swift）。
#if canImport(UIKit)
import CoreGraphics
import UIKit
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 候选捕获与生命周期（D140b / D140c）")
struct NodeDragCandidateTests {

    // ── 共用夹具①：preview rig（无滚动空间，上/下面板各只有 1 根可见 candle，index 恒 0）──
    // 与 NodeDragPreconditionsTests.baseline() 同款选择（candleIndex: 0），理由相同：
    // preview 的 upper(.m60)/lower(.daily) 可见 slice 都只有 array index 0（RenderStateBuilder.makeViewport
    // 的 reveal 钳算出来的，与 globalIndex 字段值无关）。
    private struct Rig {
        let engine: TrainingEngine
        let coordinator: ChartContainerView.Coordinator
        let view: KLineView
        let bounds: CGRect
    }

    /// 造「画线会话已开 + 选择态 + 上面板选中一条可编辑直线」+ 一个真实 Coordinator/KLineView（出真 viewport）。
    private func makeRig(mode: TrainingMode = .normal, id: String = "A") -> Rig {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let engine = TrainingEngine.preview(mode: mode)
        engine.injectDrawingsForTesting([makeStyledHLine(id: id, revealTick: 0,
                                                          period: engine.upperPanel.period, candleIndex: 0, price: 10)])
        engine.toggleDrawingMode()
        engine.drawingSession.setMode(.select)
        engine.drawingSession.setSelection(id: id, panel: .upper)
        let coordinator = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let view = KLineView(frame: bounds)
        coordinator.attach(to: view)
        coordinator.rebuildRenderState(bounds: bounds)
        return Rig(engine: engine, coordinator: coordinator, view: view, bounds: bounds)
    }

    /// 被选中那条线的真实屏幕点——与 `captureNodeDragCandidate` 内部用的同一条管线
    /// （mapper ← view.renderState.viewport；marks ← DrawingNodeGeometry + 工具表）。
    private func nodePoint(_ rig: Rig, id: String = "A") throws -> CGPoint {
        let mapper = CoordinateMapper(viewport: rig.view.renderState.viewport,
                                      displayScale: rig.view.traitCollection.displayScale)
        let drawing = RenderStateBuilder.visibleDrawings(
            engine: rig.engine, panel: .upper, tick: rig.engine.tick.globalTickIndex
        ).first(where: { $0.id == id })!
        let tool = KLineView.drawingTools[drawing.toolType]!
        let marks = DrawingNodeGeometry.marks(for: drawing, mapper: mapper,
                                              isVisible: tool.isVisible(drawing: drawing, mapper: mapper),
                                              maxAnchors: tool.requiredAnchors.upperBound)
        // 修复环第1轮：fatalError 会崩掉整个测试进程，让「这一档夹具算错」在日志里长得像「全绿」
        // （xcodebuild 重启后那一轮打印 0 tests passed）。改用 #require——失败只红这一档，其余照常跑完。
        var real: CGPoint?
        if case let .real(_, p)? = marks.first { real = p }
        return try #require(real, "夹具前置条件：选中线的锚点必须是 .real 节点")
    }

    // MARK: - T12④ 候选在 touchesCancelled 之后仍在

    @Test("T12④ 触摸被取消之后候选**仍在**（⛔「取消」不等于「手指抬起」）")
    func candidateSurvivesTouchesCancelled() throws {
        let rig = makeRig()
        let p = try nodePoint(rig)
        rig.coordinator.captureNodeDragCandidateForTesting(at: p)
        #expect(rig.coordinator.nodeDragCandidateForTesting != nil)   // 前提：候选真的建立了

        // D140c：候选的清除时机只有三个（新按下覆盖 / 多指按下 / 消费），都不含 touchesCancelled——
        // KLineView 没有覆写它，调用落到 UIResponder 默认实现，不碰 onTouchDown/onMultiTouchBegan。
        rig.view.touchesCancelled(Set<UITouch>(), with: nil)

        #expect(rig.coordinator.nodeDragCandidateForTesting != nil)   // ⭐ 仍在
        #expect(rig.coordinator.nodeDragCandidateForTesting?.drawingID == "A")
        #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)
    }

    // MARK: - T12⑤ 陈旧候选不泄漏：靠覆盖，不是记得清

    @Test("T12⑤ 陈旧候选不泄漏：节点上按下后抬手不拖，再到远处按下 ⇒ 候选被**覆盖**")
    func newTouchDownOverwritesStaleCandidate() throws {
        let rig = makeRig()
        let p = try nodePoint(rig)
        rig.coordinator.captureNodeDragCandidateForTesting(at: p)
        #expect(rig.coordinator.nodeDragCandidateForTesting != nil)   // 前提：旧候选真的建立了

        // 第二次按下：远离节点（主图外一个安全远点），这次按下**没有**命中任何节点。
        let farPoint = CGPoint(x: p.x + 5_000, y: p.y)
        rig.coordinator.captureNodeDragCandidateForTesting(at: farPoint)

        // ⭐ 必须是 nil（覆盖），不是仍保留旧候选（「记得清」的坏实现会让它还是 "A"）。
        #expect(rig.coordinator.nodeDragCandidateForTesting == nil)
        #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == false)
    }

    // MARK: - G7 两点触摸 ⇒ 不产生候选（行为面，不是源码守卫）

    @Test("G7 行为面：两点触摸 ⇒ 不产生候选（⛔ 只做源码守卫不够，判据写成 >= 1 源码上照样出现）")
    func multiTouchProducesNoCandidate() throws {
        let rig = makeRig()
        let p = try nodePoint(rig)
        rig.coordinator.captureNodeDragCandidateForTesting(at: p)
        #expect(rig.coordinator.nodeDragCandidateForTesting != nil)   // 前提：候选真的建立了

        // 直接触发 Coordinator 在 attach(to:) 里接的那个真闭包（Task 9 自己的接线），
        // 而不是重造一套 UITouch/UIEvent 去撞 KLineView.touchesBegan 的分支判据——
        // 本测试要钉住的是「钩子触发后 Coordinator 真的清了候选」这一段行为，
        // KLineView 侧「total != 1 时调用哪个闭包」的判据另见 Step 3 的 total 计算（事件层，无法脱离真实
        // UIEvent 单测，留给 Catalyst/真机验收覆盖）。
        rig.view.onMultiTouchBegan?()

        #expect(rig.coordinator.nodeDragCandidateForTesting == nil)   // ⭐ fail-closed
        #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == false)
    }

    // MARK: - T11④ 候选中途失效的六个成因，各自 fail-closed

    @Test("T11④ 候选中途失效的**六个**成因，各自 fail-closed 不进拖动")
    func candidateRevalidationRejectsSixCauses() throws {
        // ① 线被删
        do {
            let rig = makeRig()
            let p = try nodePoint(rig)
            rig.coordinator.captureNodeDragCandidateForTesting(at: p)
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)   // 前提：此刻仍放行
            #expect(rig.engine.deleteDrawing(id: "A") == true)
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == false)
        }

        // ② 选中被清
        do {
            let rig = makeRig()
            let p = try nodePoint(rig)
            rig.coordinator.captureNodeDragCandidateForTesting(at: p)
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)
            rig.engine.drawingSession.clearSelection()
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == false)
            // 撤掉成因 → 应复原（证明拒绝确实来自「选中被清」这一件事，不是测试串味）。
            rig.engine.drawingSession.setSelection(id: "A", panel: .upper)
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)
        }

        // ③ 被锁
        do {
            let rig = makeRig()
            let p = try nodePoint(rig)
            rig.coordinator.captureNodeDragCandidateForTesting(at: p)
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)
            #expect(rig.engine.setDrawingLocked(id: "A", locked: true) == true)
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == false)
            #expect(rig.engine.setDrawingLocked(id: "A", locked: false) == true)
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)
        }

        // ④ 进复盘（flow.mode 构造时定型，不可写——撤/加成因靠两个独立引擎，照 NodeDragPreconditionsTests 先例）
        do {
            let normalRig = makeRig(mode: .normal)
            let p = try nodePoint(normalRig)
            normalRig.coordinator.captureNodeDragCandidateForTesting(at: p)
            #expect(normalRig.coordinator.acceptNodeDragCandidateForTesting() == true)

            let reviewRig = makeRig(mode: .review)
            #expect(reviewRig.engine.flow.mode == .review)   // 前提成立
            let pr = try nodePoint(reviewRig)
            reviewRig.coordinator.captureNodeDragCandidateForTesting(at: pr)
            #expect(reviewRig.coordinator.acceptNodeDragCandidateForTesting() == false)
        }

        // ⑤ 选中换成**同面板**另一条可编辑线——⭐ 必须断言 B 真的可编辑（否则退化成②的复制品）
        do {
            let rig = makeRig()
            let p = try nodePoint(rig)
            rig.coordinator.captureNodeDragCandidateForTesting(at: p)
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)

            rig.engine.injectDrawingsForTesting(
                rig.engine.drawings + [makeStyledHLine(id: "B", revealTick: 0,
                                                       period: rig.engine.upperPanel.period, candleIndex: 0, price: 10)])
            rig.engine.drawingSession.setSelection(id: "B", panel: .upper)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: rig.engine, panel: .upper, point: .zero) == true,
                    "前提：B 必须真的可编辑，否则本档退化成「选中被清」的复制品")

            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == false)   // 身份不符：候选记的是 A
        }

        // ⑥ 选中换成**另一面板**的可编辑线——⭐ 同样必须断言 C 真的可编辑
        // ⚠️ 修复环第1轮订正：本档**不隔离身份比对**——它是被 `acceptNodeDragCandidate`
        // （ChartContainerView.swift:439）里 `nodeDragPreconditions` 自己的「`selectedPanel==panel`」
        // 那一步先挡住的（`panel` 是 Coordinator 固定的 `self.panel`=.upper，候选换到 .lower 选中后
        // `session.selectedPanel` 变成 .lower，两者不等，还没走到身份比对就已经 false）。
        // **真正隔离身份比对的是 cause⑤**（同面板换选中）。⛔ 若将来有人见本档全绿就删掉
        // `acceptNodeDragCandidate` 里的身份比对那一行，本档依然会正确拒绝——那不能当「身份比对没用」的证据。
        do {
            let rig = makeRig()
            let p = try nodePoint(rig)
            rig.coordinator.captureNodeDragCandidateForTesting(at: p)
            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)

            rig.engine.injectDrawingsForTesting(
                rig.engine.drawings + [makeStyledHLine(id: "C", panelPosition: 1, revealTick: 0,
                                                       period: rig.engine.lowerPanel.period,
                                                       candleIndex: 0, price: 10)])
            rig.engine.drawingSession.setSelection(id: "C", panel: .lower)
            #expect(DrawingEditRouter.nodeDragPreconditions(engine: rig.engine, panel: .lower, point: .zero) == true,
                    "前提：C 必须真的可编辑，否则本档退化成「选中被清」的复制品")

            #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == false)   // 候选是 upper 面板的 A
        }
    }

    // MARK: - T11①②③：视口在「按下 → .began」之间移动（D140b）

    // 共用夹具②：真有滚动空间的 .m3/.m3 双面板引擎 + FakeFrameDriver，驱动真实惯性/overscroll。
    private struct ScrollRig {
        let engine: TrainingEngine
        let fakes: () -> [FakeFrameDriver]
        let coordinator: ChartContainerView.Coordinator
        let view: KLineView
        let bounds: CGRect
    }

    // ⚠️ 修复环第1轮订正：candleIndex 选哪个值**不能手算**——手算漏掉了 `pixelShift`（overscroll 时
    //    整段内容连同 startIndex==0 一起整体右移，把 indexToX 推出 mainChartFrame 右缘，index 落在数组
    //    可见区间内也可能被判成 `.proxy` 而非 `.real`）。本仓已有纪律：期望值要交给真解析器/真几何去算，
    //    不要手算——这正是那条纪律在本文件第一轮踩的坑。
    //    已用 TEMP-DIAG 临时测试（Catalyst 真机跑出来，见 task-9-report.md 修复环第1轮）在**每个测试
    //    实际会查询的 checkpoint** 上扫过 `DrawingNodeGeometry.marks`，结果：
    //      T11①/T11②（kickInertia 惯性配方）：1 帧后 real∈[65,144]，7 帧后 real∈[41,120]，交集 [65,120]——
    //        75 落在交集内，默认值不改。
    //      T11③（overscroll+settle 配方）：越界那一帧 real∈[0,63]（pixelShift 把 >63 推出右缘），
    //        夹回后 real∈[0,80]，交集 [0,63]——与 T11①/② 的交集**不相交**，⛔ 不能共用一个默认值，
    //        T11③ 调用处显式传 `candleIndex: 50`（见下）。
    private func makeScrollRig(candleIndex: Int = 75, price: Double = 10, id: String = "A") -> ScrollRig {
        let bounds = TrainingEnginePanLinkageTests.bounds   // 800×600，makeEngine 已 recordRenderBounds
        let (engine, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        engine.injectDrawingsForTesting([makeStyledHLine(id: id, revealTick: 0, period: .m3,
                                                          candleIndex: candleIndex, price: price)])
        engine.toggleDrawingMode()
        engine.drawingSession.setMode(.select)
        engine.drawingSession.setSelection(id: id, panel: .upper)
        let coordinator = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let view = KLineView(frame: bounds)
        coordinator.attach(to: view)
        coordinator.rebuildRenderState(bounds: bounds)
        return ScrollRig(engine: engine, fakes: fakes, coordinator: coordinator, view: view, bounds: bounds)
    }

    private func scrollNodePoint(_ rig: ScrollRig, id: String = "A") throws -> CGPoint {
        let mapper = CoordinateMapper(viewport: rig.view.renderState.viewport,
                                      displayScale: rig.view.traitCollection.displayScale)
        let drawing = RenderStateBuilder.visibleDrawings(
            engine: rig.engine, panel: .upper, tick: rig.engine.tick.globalTickIndex
        ).first(where: { $0.id == id })!
        let tool = KLineView.drawingTools[drawing.toolType]!
        let marks = DrawingNodeGeometry.marks(for: drawing, mapper: mapper,
                                              isVisible: tool.isVisible(drawing: drawing, mapper: mapper),
                                              maxAnchors: tool.requiredAnchors.upperBound)
        // 修复环第1轮：同 nodePoint 的理由——fatalError 崩进程会把「夹具算错」伪装成「全绿」。
        var real: CGPoint?
        if case let .real(_, p)? = marks.first { real = p }
        return try #require(real, "夹具前置条件：选中线的锚点必须是 .real 节点")
    }

    /// 起一次大速度甩动惯性（beginPan→endPan(velocity:)），不手动 applyPanOffset——
    /// 让 FakeFrameDriver 的 onTick 自己把 offset 往前推（D140b 描述的那种「触摸落下时惯性仍在跑」）。
    private func kickInertia(_ rig: ScrollRig, velocity: CGFloat = 4_000) {
        rig.engine.beginPan(panel: .upper)
        rig.engine.endPan(velocity: velocity, renderBounds: rig.bounds, panel: .upper)
    }

    @discardableResult
    private func advanceFrames(_ rig: ScrollRig, count: Int = 6, dt: CGFloat = 1.0 / 60.0) -> CGFloat {
        for _ in 0..<count { _ = rig.fakes().last?.fire(dt) }
        rig.coordinator.rebuildRenderState(bounds: rig.bounds)
        return rig.engine.upperPanel.offset
    }

    @Test("T11① 按下时节点在指下、之后惯性把节点移出 11pt → 仍必须进拖动（`.began` 不重做几何）")
    func inertiaMovingNodeAwayStillEntersNodeDrag() throws {
        let rig = makeScrollRig()
        kickInertia(rig)
        _ = advanceFrames(rig, count: 1)          // 惯性已经在跑的那一刻
        let p0 = try scrollNodePoint(rig)
        rig.coordinator.captureNodeDragCandidateForTesting(at: p0)
        #expect(rig.coordinator.nodeDragCandidateForTesting != nil)   // 前提：按下那一刻真的命中了节点

        _ = advanceFrames(rig, count: 6)          // 模拟按下到 `.began` 之间惯性继续跑
        let p1 = try scrollNodePoint(rig)
        let moved = abs(p1.x - p0.x)
        #expect(moved > DrawingNodeGeometry.hitRadius,
                "前提：视口必须真的移动了超过命中半径，否则本档与「没有移动」无法区分")

        // ⭐ 正向对照：若 `.began` 真的重新做了命中判定，用**原按下点** p0 在**新视口**下应该已经落空
        // （节点已经移出 hitRadius）——这正是本档要证伪的那种回归写法。
        let mapperAfter = CoordinateMapper(viewport: rig.view.renderState.viewport,
                                           displayScale: rig.view.traitCollection.displayScale)
        let drawingAfter = RenderStateBuilder.visibleDrawings(
            engine: rig.engine, panel: .upper, tick: rig.engine.tick.globalTickIndex
        ).first(where: { $0.id == "A" })!
        let toolAfter = KLineView.drawingTools[drawingAfter.toolType]!
        let wouldMissIfRechecked = DrawingNodeGeometry.hitTestNode(
            point: p0, drawing: drawingAfter, mapper: mapperAfter,
            isVisible: toolAfter.isVisible(drawing: drawingAfter, mapper: mapperAfter),
            maxAnchors: toolAfter.requiredAnchors.upperBound)
        #expect(wouldMissIfRechecked == nil, "自检：若这里命中了说明 p0/p1 没有移动够，本档测的是空气")

        #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)   // ⭐ 仍必须进拖动
    }

    @Test("T11② 按下时指下没有节点、惯性把某节点移进指下 → 必须不进拖动")
    func inertiaMovingNodeInDoesNotRetroactivelyCreateCandidate() throws {
        // 先用一个独立的「演练」rig 跑同一套惯性配方，只是为了算出「惯性结束后节点会落在哪个点」——
        // 两个 rig 用同一份夹具 + 同一串引擎调用，是纯函数式确定性状态转移，结果逐位相同。
        let dryRun = makeScrollRig()
        kickInertia(dryRun)
        _ = advanceFrames(dryRun, count: 1)
        _ = advanceFrames(dryRun, count: 6)
        let q = try scrollNodePoint(dryRun)             // 节点「惯性跑完之后」会落在的点

        let rig = makeScrollRig()
        kickInertia(rig)
        _ = advanceFrames(rig, count: 1)
        // 前提：此刻（按下那一刻）q 这个点底下**没有**节点。
        let mapperBefore = CoordinateMapper(viewport: rig.view.renderState.viewport,
                                            displayScale: rig.view.traitCollection.displayScale)
        let drawingBefore = RenderStateBuilder.visibleDrawings(
            engine: rig.engine, panel: .upper, tick: rig.engine.tick.globalTickIndex
        ).first(where: { $0.id == "A" })!
        let toolBefore = KLineView.drawingTools[drawingBefore.toolType]!
        #expect(DrawingNodeGeometry.hitTestNode(
            point: q, drawing: drawingBefore, mapper: mapperBefore,
            isVisible: toolBefore.isVisible(drawing: drawingBefore, mapper: mapperBefore),
            maxAnchors: toolBefore.requiredAnchors.upperBound) == nil,
            "前提：按下那一刻 q 处确实没有节点")

        rig.coordinator.captureNodeDragCandidateForTesting(at: q)
        #expect(rig.coordinator.nodeDragCandidateForTesting == nil)   // 按下时指下没有节点 ⇒ 没有候选

        // 让惯性跑完（与 dryRun 同一串调用）—— 正向对照：节点**真的**移进了 q。
        _ = advanceFrames(rig, count: 6)
        let mapperAfter = CoordinateMapper(viewport: rig.view.renderState.viewport,
                                           displayScale: rig.view.traitCollection.displayScale)
        let drawingAfter = RenderStateBuilder.visibleDrawings(
            engine: rig.engine, panel: .upper, tick: rig.engine.tick.globalTickIndex
        ).first(where: { $0.id == "A" })!
        let toolAfter = KLineView.drawingTools[drawingAfter.toolType]!
        #expect(DrawingNodeGeometry.hitTestNode(
            point: q, drawing: drawingAfter, mapper: mapperAfter,
            isVisible: toolAfter.isVisible(drawing: drawingAfter, mapper: mapperAfter),
            maxAnchors: toolAfter.requiredAnchors.upperBound) != nil,
            "正向对照：节点必须真的移进了 q，否则「没有候选」这个结论无意义")

        // `.began` 复核**不重新命中** ⇒ 候选依旧是 nil ⇒ 不进拖动，照常走图表手势
        // （「照常走图表手势」的那一半由 Task 8 的 singlePanRouteStep 纯函数覆盖，
        //  ChartGestureArbiter.swift:192 — candidateAccepted==false 时不转发节点拖动）。
        #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == false)
    }

    @Test("T11③ settleDeceleration 夹回 overscroll 致投影移动 → 同①，仍必须进拖动")
    func overscrollSettleClampStillEntersNodeDrag() throws {
        // candleIndex: 50——越界那一帧的 pixelShift 把 >63 的下标推出 mainChartFrame 右缘（见
        // makeScrollRig 上方注释的 TEMP-DIAG 实测），默认值 75 在这一档会落空，必须显式传。
        let rig = makeScrollRig(candleIndex: 50)
        let ob = RenderStateBuilder.offsetBounds(engine: rig.engine, panel: .upper, bounds: rig.bounds)
        #expect(ob.maxOffset > 0)   // 前提：真有滚动空间

        // 拖到超过 maxOffset（最老边橡皮筋）再松手 → 走 bounce 分支（allowOverscroll），
        // 照 TrainingEngineDrawingSessionTests.settleDuringBounceKeepsPanelsTimeAligned 的先例。
        rig.engine.beginPan(panel: .upper)
        rig.engine.applyPanOffset(deltaPixels: ob.maxOffset + 400, renderBounds: rig.bounds, panel: .upper)
        rig.engine.endPan(velocity: 0, renderBounds: rig.bounds, panel: .upper)
        _ = rig.fakes().last?.fire(1.0 / 60.0)
        rig.coordinator.rebuildRenderState(bounds: rig.bounds)
        #expect(rig.engine.upperPanel.offset > ob.maxOffset, "前提：确实还在越界区，否则测不到 clamp")

        // 按下那一刻：节点在指下（此刻视口仍是越界的那一帧）。
        let p0 = try scrollNodePoint(rig)
        rig.coordinator.captureNodeDragCandidateForTesting(at: p0)
        #expect(rig.coordinator.nodeDragCandidateForTesting != nil)

        let offsetBeforeSettle = rig.engine.upperPanel.offset
        rig.engine.settleDeceleration(initiatedBy: .upper)
        #expect(rig.engine.upperPanel.offset != offsetBeforeSettle, "自检：settle 必须真的夹过，不是 no-op")
        #expect(rig.engine.upperPanel.offset <= ob.maxOffset, "自检：夹回界内")

        rig.coordinator.rebuildRenderState(bounds: rig.bounds)
        let p1 = try scrollNodePoint(rig)
        #expect(abs(p1.x - p0.x) > DrawingNodeGeometry.hitRadius,
                "前提：clamp 必须真的挪动了投影超过命中半径")

        #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == true)   // ⭐ 仍必须进拖动
    }
}
#endif
