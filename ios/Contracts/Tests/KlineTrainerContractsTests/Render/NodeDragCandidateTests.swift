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

    // MARK: - T11④ cause④ 的 mid-flight 场景（修复环第2轮订正）

    /// 评审实测证明 `candidateRevalidationRejectsSixCauses` 的 cause④（进复盘）判别力为零：
    /// `reviewRig` 是另造的引擎，`captureNodeDragCandidateForTesting` 在捕获阶段就被
    /// `editableIgnoringGeometry` 的 `flow.mode != .review` 挡掉（候选从未建立），`acceptNodeDragCandidate`
    /// 第一行 `guard let c = nodeDragCandidate else { return false }` 就返回——复核那一行有没有都无所谓。
    /// cause④ 实际测的是「捕获前拒绝」，与 `NodeDragPreconditionsTests.swift:130-152` 近乎重复。
    ///
    /// 本档补 spec T11④ 真正要的场景：**候选在按下时已合法建立，`.began` 之前环境才变化**——
    /// 由于活引擎的 `flow.mode` 是构造时定型的只读计算属性（`TrainingFlowController` 协议、
    /// `NormalFlow`/`ReviewFlow`/`ReplayFlow` 三个实现各自写死返回值），「进复盘」在一个**活引擎**上
    /// 结构性不可能发生——真实可达的等价场景是**换一整个引擎**，对应「手指还在屏幕上，视图层把
    /// Coordinator 换绑到一个新引擎」。复用 Coordinator 既有的换引擎缝 `sync(panel:engine:view:)`
    /// （`ChartContainerView.updateUIView` 每次调用的那条真实路径，`ChartContainerView.swift:79-108`），
    /// ⛔ 不新增任何生产 API、不放宽可见性。
    @Test("T11④ cause④' mid-flight：候选已合法建立，`.began` 前 Coordinator 的 engine 被换成复盘引擎 ⇒ 拒绝")
    func candidateRevalidationRejectsMidFlightSwitchToReview() throws {
        let rig = makeRig(mode: .normal)
        let p = try nodePoint(rig)
        rig.coordinator.captureNodeDragCandidateForTesting(at: p)
        // ⭐ 不能省：证明候选真的被建立过，否则这一档又会退化成「压根没捕获」的复制品。
        #expect(rig.coordinator.nodeDragCandidateForTesting != nil,
                "前提：候选必须在切换引擎之前就合法建立")

        // 换引擎（与 makeRig(mode:.review) 同款构造：画线会话已开、选择态、同一条线 "A" 已选中——
        // 唯一差别是 flow.mode，这样复盘门才与「选择态/选中」等其它分量隔离开）。
        let reviewRig = makeRig(mode: .review)
        rig.coordinator.sync(panel: .upper, engine: reviewRig.engine, view: rig.view)

        #expect(rig.coordinator.acceptNodeDragCandidateForTesting() == false)
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

    // MARK: - Task 11：拖动三相位接线 + 收尾路径（D138 三分 / D135b 两支失败 / 订正 1-4）

    /// 通用「捕获候选 + 走完一次 `.began`」的前置动作，供下面多档共用。
    @discardableResult
    private func beginDrag(_ rig: Rig, id: String = "A") throws -> CGPoint {
        let p = try nodePoint(rig, id: id)
        rig.coordinator.captureNodeDragCandidateForTesting(at: p)
        rig.coordinator.handleNodeDragForTesting(translation: .zero, phase: .began)
        return p
    }

    // MARK: N4：一次完整拖动只产生一条撤销记录

    @Test("N4：一次完整拖动（began→changed→ended）⇒ 撤销栈深度恰好1 / ↩一次整个回到拖前 / 拖动后≠拖前 / drawingsRevision 恰好+1")
    func fullDragProducesExactlyOneUndoRecord() throws {
        let rig = makeRig()
        _ = try beginDrag(rig)
        #expect(rig.engine.drawingSession.nodeDragOwner != nil, "前提：拖动态确实已经开始")
        let anchorBefore = try #require(rig.engine.drawings.first(where: { $0.id == "A" })).anchors[0]
        let revisionBefore = rig.engine.drawingsRevision

        rig.coordinator.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -5), phase: .changed)
        rig.coordinator.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -10), phase: .ended)

        #expect(rig.engine.drawingSession.nodeDragOwner == nil, "收尾后必须清槧")
        #expect(rig.engine.drawingSession.nodeDragCurrent == nil)
        let anchorAfter = try #require(rig.engine.drawings.first(where: { $0.id == "A" })).anchors[0]
        // ③ 拖动后锚点确实 ≠ 拖前（否则下面「撤销后等于拖前」因为压根没改而恒真）。
        #expect(anchorAfter != anchorBefore, "拖动必须真的改动了锚点，否则下面的撤销断言是空转")
        // ④ drawingsRevision 相对基线恰好 +1（不是每帧写一次）。
        #expect(rig.engine.drawingsRevision == revisionBefore + 1,
                "一次拖动必须恰好写盘一次——.changed 帧绝不许碰 drawings")
        // ① 撤销栈深度恰好 1：此刻确实有恰好一条可撤销的记录。
        #expect(rig.engine.canUndoDrawing == true, "必须恰好有一条可撤销记录")

        // ② ↩ 一次锚点整个回到拖前。
        #expect(rig.engine.undoDrawing() == true)
        let anchorUndone = try #require(rig.engine.drawings.first(where: { $0.id == "A" })).anchors[0]
        #expect(anchorUndone == anchorBefore, "撤销一次必须整个回到拖动之前的锚点")
    }

    // MARK: T4：第二根手指落下 ⇒ 就地定住（走与抬手同一条收尾路径）

    @Test("T4：拖到一半被第二根手指打断（ChartGestureArbiter 对此发 .ended，与抬手同一条收尾路径）⇒ 就地定住：写一次、记一条撤销，定住的锚点 ≠ 起点")
    func secondFingerInterruptionFinalizesInPlace() throws {
        let rig = makeRig()
        _ = try beginDrag(rig)
        let anchorAtStart = try #require(rig.engine.drawings.first(where: { $0.id == "A" })).anchors[0]
        let revisionBefore = rig.engine.drawingsRevision

        // 拖到一半（.changed）……
        rig.coordinator.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -6), phase: .changed)
        // ……第二根手指落下：`ChartGestureArbiter.supersedeSinglePanForMultitouch`（`:134-141`）对
        // 正在进行的节点拖动发的是 `.ended`（“定住不是作废”，⛔ 不是 `.cancelled`）——与真实抬手
        // **同一条**生产回调，因此直接喂 `.ended` 即忠实复现这条打断源，不需要另造一套 UITouch。
        rig.coordinator.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -6), phase: .ended)

        #expect(rig.engine.drawingSession.nodeDragOwner == nil, "就地定住之后必须清槧")
        let anchorFinal = try #require(rig.engine.drawings.first(where: { $0.id == "A" })).anchors[0]
        #expect(anchorFinal != anchorAtStart, "定住的锚点必须 ≠ 拖动起点（D138：就地定住不是回弹到起点）")
        #expect(rig.engine.drawingsRevision == revisionBefore + 1, "恰好写一次")
        #expect(rig.engine.canUndoDrawing == true, "恰好记一条撤销")
    }

    // MARK: T14⑤：陈旧回调不得动别人的槧

    /// 找某面板上某条线唯一锚点的真实屏幕点（同 `nodePoint(_:id:)`，但支持任意面板——
    /// T14⑤ 需要同时操作 upper/lower 两个独立 Coordinator）。
    private func nodePointOnPanel(engine: TrainingEngine, view: KLineView, panel: PanelId, id: String) throws -> CGPoint {
        let mapper = CoordinateMapper(viewport: view.renderState.viewport, displayScale: view.traitCollection.displayScale)
        let drawing = try #require(RenderStateBuilder.visibleDrawings(
            engine: engine, panel: panel, tick: engine.tick.globalTickIndex
        ).first(where: { $0.id == id }))
        let tool = try #require(KLineView.drawingTools[drawing.toolType])
        let marks = DrawingNodeGeometry.marks(for: drawing, mapper: mapper,
                                              isVisible: tool.isVisible(drawing: drawing, mapper: mapper),
                                              maxAnchors: tool.requiredAnchors.upperBound)
        var real: CGPoint?
        if case let .real(_, p)? = marks.first { real = p }
        return try #require(real, "夹具前置条件：选中线的锚点必须是 .real 节点")
    }

    @Test("T14⑤ 陈旧回调不得动别人的槧：A 已收尾清槧、B 已占槧 ⇒ 来自 A 面板的陈旧 .changed/.ended 不碰 B 的拖动态/drawingsRevision，且 B 之后仍能正常收尾")
    func staleCallbackFromOtherPanelDoesNotTouchActiveDrag() throws {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let engine = TrainingEngine.preview()
        engine.injectDrawingsForTesting([
            makeStyledHLine(id: "A", revealTick: 0, period: engine.upperPanel.period, candleIndex: 0, price: 10),
            makeStyledHLine(id: "B", panelPosition: 1, revealTick: 0, period: engine.lowerPanel.period, candleIndex: 0, price: 10),
        ])
        engine.toggleDrawingMode()
        engine.drawingSession.setMode(.select)

        let coordUpper = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let viewUpper = KLineView(frame: bounds)
        coordUpper.attach(to: viewUpper)
        coordUpper.rebuildRenderState(bounds: bounds)

        let coordLower = ChartContainerView(panel: .lower, engine: engine).makeCoordinator()
        let viewLower = KLineView(frame: bounds)
        coordLower.attach(to: viewLower)
        coordLower.rebuildRenderState(bounds: bounds)

        // --- A（upper）走完一整轮拖动，正常收尾、清槧。
        engine.drawingSession.setSelection(id: "A", panel: .upper)
        let pA = try nodePointOnPanel(engine: engine, view: viewUpper, panel: .upper, id: "A")
        coordUpper.captureNodeDragCandidateForTesting(at: pA)
        coordUpper.handleNodeDragForTesting(translation: .zero, phase: .began)
        #expect(engine.drawingSession.nodeDragOwner?.drawingID == "A", "前提：A 的拖动确实开始了")
        coordUpper.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -5), phase: .ended)
        #expect(engine.drawingSession.nodeDragOwner == nil, "前提：A 已经收尾清槧")

        // --- 选中切到 B（lower），开始 B 的拖动，占槧。
        engine.drawingSession.setSelection(id: "B", panel: .lower)
        let pB = try nodePointOnPanel(engine: engine, view: viewLower, panel: .lower, id: "B")
        coordLower.captureNodeDragCandidateForTesting(at: pB)
        coordLower.handleNodeDragForTesting(translation: .zero, phase: .began)
        #expect(engine.drawingSession.nodeDragOwner?.drawingID == "B", "前提：B 已经占槧")
        let ownerBSnapshot = engine.drawingSession.nodeDragOwner
        let currentBSnapshot = engine.drawingSession.nodeDragCurrent
        let revisionBeforeStale = engine.drawingsRevision

        // --- 陈旧回调：来自 A 的面板（upper）的 .changed / .ended 分别喂一次——这是 A 自己的
        //     Coordinator 实例收到的、属于**早已结束**那次拖动的迟到回调（D135b 的①：来源不符）。
        coordUpper.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -50), phase: .changed)
        #expect(engine.drawingSession.nodeDragOwner == ownerBSnapshot, "B 的拖动态不得被 A 的陈旧回调碰")
        #expect(engine.drawingSession.nodeDragCurrent == currentBSnapshot)
        #expect(engine.drawingsRevision == revisionBeforeStale)

        coordUpper.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -50), phase: .ended)
        #expect(engine.drawingSession.nodeDragOwner == ownerBSnapshot, "B 的拖动态仍不得被碰（陈旧 .ended 同样要忽略）")
        #expect(engine.drawingSession.nodeDragCurrent == currentBSnapshot)
        #expect(engine.drawingsRevision == revisionBeforeStale)

        // --- B 之后仍能正常继续更新、并自行收尾（证明 A 的陈旧回调没有把 B 的槧提前清掉/提前提交）。
        coordLower.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -8), phase: .changed)
        #expect(engine.drawingSession.nodeDragCurrent != currentBSnapshot, "B 必须仍能继续正常更新")
        coordLower.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -8), phase: .ended)
        #expect(engine.drawingSession.nodeDragOwner == nil, "B 必须仍能自行正常收尾")
        #expect(engine.canUndoDrawing == true, "B 的收尾必须留下一条撤销记录")
    }

    // MARK: 订正 2（Critical）：终止相位必须无条件清槧

    @Test("订正2①：归属对得上，但本帧 viewport 失效（candleStep<=0）⇒ `.ended` 仍必须无条件清槧")
    func endedClearsSlotEvenWhenGeometryUnavailable() throws {
        let rig = makeRig()
        _ = try beginDrag(rig)
        #expect(rig.engine.drawingSession.nodeDragOwner != nil, "前提：拖动态确实在进行")

        // 强行破坏本帧视口（模拟转屏/resize 瞬间 bounds 失效那一类场景，订正 2 枚举的第一种成因）——
        // ⛔ 不碰 engine/session，只破坏 `view.renderState`（Coordinator 读几何的那个唯一来源）。
        rig.view.renderState = .empty

        rig.coordinator.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -5), phase: .ended)

        #expect(rig.engine.drawingSession.nodeDragOwner == nil,
                "⭐⭐ 订正2 本体：几何取不到也必须清槧，否则 nodeDragOwner 残留 ⇒ 底栏永久锁灰")
        #expect(rig.engine.drawingSession.nodeDragCurrent == nil)
    }

    @Test("订正2②：清槧之后，十道写入门必须真的重新放行（⛔ 只断言 nodeDragOwner==nil 是在测中间变量）")
    func styleControlsReopenAfterGeometryUnavailableEndedClearsSlot() throws {
        let rig = makeRig()
        _ = try beginDrag(rig)
        // 门此刻必须是关着的——拖动进行中，这是本档断言「重新放行」的对照基线。
        #expect(DrawingEditRouter.styleControlsEnabled(engine: rig.engine) == false,
                "前提：拖动进行中，styleControlsEnabled 必须是关着的")

        rig.view.renderState = .empty   // 同上一档：模拟本帧几何失效
        rig.coordinator.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -5), phase: .ended)

        #expect(rig.engine.drawingSession.nodeDragOwner == nil, "前提：槧确实被清了")
        // ⭐ 真判据：门必须恢复为 true——此刻选中仍是 "A"、线仍存在、几何提示标志
        // （`session.selectionGeometryVisible`）在这次事故里从未被碰过，唯一改变的变量
        // 就是 `nodeDragOwner`，门的恢复因此只能归因于「拖动态清了」。
        #expect(DrawingEditRouter.styleControlsEnabled(engine: rig.engine) == true,
                "清槧之后，styleControlsEnabled 必须恢复为 true——十道门里任选一道做真判据")
    }

    // MARK: 订正 3：拖动进行中，tap 未命中（.select）整支早退

    @Test("订正3：拖动进行中，tap 未命中 ⇒ `.select` 整支早退：不换选中、不清空、不丢弃拖动态")
    func tapMissWhileDraggingDoesNotDisturbDragState() throws {
        let rig = makeRig()
        let p = try beginDrag(rig)
        #expect(rig.engine.drawingSession.nodeDragOwner != nil, "前提：拖动态确实在进行")
        let ownerBefore = rig.engine.drawingSession.nodeDragOwner
        let currentBefore = rig.engine.drawingSession.nodeDragCurrent
        let selectedBefore = rig.engine.drawingSession.selectedDrawingID
        let revisionBefore = rig.engine.drawingsRevision

        let missPoint = CGPoint(x: p.x + 10_000, y: p.y + 10_000)   // 安全远点，必定未命中任何线/节点
        rig.coordinator.handleDrawingTapForTesting(at: missPoint)

        #expect(rig.engine.drawingSession.nodeDragOwner == ownerBefore, "①拖动态（owner）必须原样保留")
        #expect(rig.engine.drawingSession.nodeDragCurrent == currentBefore, "②拖动态（current）必须原样保留")
        #expect(rig.engine.drawingSession.selectedDrawingID == selectedBefore, "③选中必须不变")
        // ⚠️ Task 12 评审实测：去掉 `handleDrawingTap` 的 `.select` 分支里那道 `nodeDragInFlight` 门之后，
        // 只有 ①②③ 会转红——`clearSelection()`（DrawingSession.swift:142-147）本就不碰 `drawings` /
        // `drawingsRevision`。⇒ 第④条对**这道门**判别力为零（隔离它的是 ①②③），不要删它——
        // 它仍是有意义的附带确认「这次事故里没有任何写盘发生」，只是不能拿它当这道门的证据。
        #expect(rig.engine.drawingsRevision == revisionBefore, "④drawingsRevision 必须不变")
    }

    @Test("订正3 反向对照：不在拖动中时，同一次未命中的 tap ⇒ 选中确实被清空（D37），证明上一档的「不变」不是巧合")
    func tapMissWithoutDraggingClearsSelectionNormally() throws {
        let rig = makeRig()
        let p = try nodePoint(rig)
        #expect(rig.engine.drawingSession.nodeDragOwner == nil, "前提：此刻没有拖动")
        #expect(rig.engine.drawingSession.selectedDrawingID == "A", "前提：此刻确实选中着 A")

        let missPoint = CGPoint(x: p.x + 10_000, y: p.y + 10_000)
        rig.coordinator.handleDrawingTapForTesting(at: missPoint)

        #expect(rig.engine.drawingSession.selectedDrawingID == nil,
                "不在拖动中时，tap 未命中必须清空选中——证明「整支早退」挡的是拖动，不是把 tap 清空焊死")
    }

    // MARK: 订正 4：`updateDrawingAnchor` 返回 false 时的静默丢弃，钉住这个行为

    @Test("订正4：`updateDrawingAnchor` 返回 false（七道门之一拒绝）⇒ 拖动态清、锚点不变、不覆盖既有撤销记录、drawingsRevision 不再额外 +1")
    func updateDrawingAnchorFailureIsSilentlyDiscardedWithoutClobberingExistingUndo() throws {
        let rig = makeRig()
        _ = try beginDrag(rig)
        #expect(rig.engine.drawingSession.nodeDragOwner != nil, "前提：拖动态确实在进行")
        let anchorBefore = try #require(rig.engine.drawings.first(where: { $0.id == "A" })).anchors[0]

        // 绕过路由直调引擎（`DrawingEditRouter.toggleLockSelected` 本身会被 `nodeDragInFlight`
        // 拒绝，必须走 `engine.setDrawingLocked` 直调，同既有 cause③ 先例，`:151` 附近）——
        // 制造「七道门」里的门②（`!old.locked`）在 `.ended` 写入那一刻失败。
        #expect(rig.engine.setDrawingLocked(id: "A", locked: true) == true, "前提：锁定本身必须成功")
        let revisionAfterLock = rig.engine.drawingsRevision
        guard case .replaced(_, let afterLockSnapshot, _)? = rig.engine.drawingUndoEntryForTesting?.drawingsDelta else {
            Issue.record("前提：锁定必须已经产生一条 .replaced 撤销记录")
            return
        }

        rig.coordinator.handleNodeDragForTesting(translation: CGPoint(x: 0, y: -10), phase: .ended)

        #expect(rig.engine.drawingSession.nodeDragOwner == nil, "拖动态必须清——即便写入被拒")
        #expect(rig.engine.drawingSession.nodeDragCurrent == nil)
        let anchorAfter = try #require(rig.engine.drawings.first(where: { $0.id == "A" })).anchors[0]
        #expect(anchorAfter == anchorBefore, "锚点必须原样不变——写入被 locked 门拒绝")
        #expect(rig.engine.drawingsRevision == revisionAfterLock, "写入被拒必须零副作用，revision 不许再 +1")
        guard case .replaced(_, let afterSnapshotNow, _)? = rig.engine.drawingUndoEntryForTesting?.drawingsDelta else {
            Issue.record("撤销记录不见了，或类型变了——写入被拒不该动它")
            return
        }
        #expect(afterSnapshotNow == afterLockSnapshot,
                "被拒绝的拖动写入**绝不能**覆盖掉锁定那条已有的撤销记录（深度 1 的栈最容易被误覆盖）")
    }

    // MARK: 订正 1（Critical）：Catalyst 端到端验证 —— 真实 Coordinator 流水线不复利叠加

    @Test("订正1 Catalyst 验证：真实 handleNodeDrag 流水线下，多帧累计位移与 `DrawingNodeDrag.draggedAnchor(基准=提交值)` 逐帧吻合（⛔ 不复利叠加）")
    func realPipelineChangedPhaseStaysLinearAgainstCommittedBasis() throws {
        let rig = makeRig()
        let committedBefore = try #require(rig.engine.drawings.first(where: { $0.id == "A" }))
        _ = try beginDrag(rig)
        #expect(rig.engine.drawingSession.nodeDragOwner != nil, "前提：拖动态确实已经开始")

        // `.began` 之后视口不会再变（本档全程没有任何平移/惯性），全程复用这一个 mapper 算期望值。
        let mapper = CoordinateMapper(viewport: rig.view.renderState.viewport,
                                      displayScale: rig.view.traitCollection.displayScale)
        let tool = try #require(KLineView.drawingTools[committedBefore.toolType])
        let anchorIndex = 0

        var actual: [DrawingAnchor] = []
        var expected: [DrawingAnchor] = []
        // 三帧累计位移（与 host 复现测试同款：-10/-20/-30）。
        for ty in [CGFloat(-10), -20, -30] {
            let t = CGPoint(x: 0, y: ty)
            rig.coordinator.handleNodeDragForTesting(translation: t, phase: .changed)
            let cur = try #require(rig.engine.drawingSession.nodeDragCurrent)
            actual.append(cur)
            // ⭐⭐ 订正1④ 的行为守卫：此刻 `nodeDragCurrent` 已经与提交值不同（上一帧已经移动过）——
            //    每一帧都是「提交值 ≠ nodeDragCurrent」状态下喂的 `.changed`，期望值**恒用提交值**
            //    现算，若 Coordinator 内部悄悄改回拿 `visibleDrawings`（拖动中的覆盖值）当基准，
            //    这里算出的期望值就会与 `actual` 分叉（本测试会变红）。
            let want = try #require(DrawingNodeDrag.draggedAnchor(
                drawing: committedBefore, anchorIndex: anchorIndex, translation: t, mapper: mapper, tool: tool))
            expected.append(want)
        }

        #expect(actual == expected, "每一帧的 nodeDragCurrent 都必须恰好等于「基准=提交值」算出来的结果，实测 actual=\(actual) expected=\(expected)")
        // 帧间差相等（线性）+ 两两不等（确实在动）——与 host 复现档同款判据。
        let diffs = zip(actual.dropFirst(), actual).map { $0.price - $1.price }
        #expect(abs(diffs[0] - diffs[1]) < 1e-9, "帧间差必须相等（线性），实测 \(diffs)")
        #expect(Set(actual.map(\.price)).count == actual.count, "三帧的值必须两两不等，否则「线性」断言可能是在比较三个相同的常数")
    }
}
#endif
