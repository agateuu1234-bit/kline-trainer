// ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewDrawingSessionTests.swift
// Spec: 2026-07-10-drawing-tools-P1b-split-addendum.md §3.3（#1 #2 #3 #5）
// **必须跨两个真实 Coordinator**（codex R31-high）：只在同一个 manager 上调两次，测不出
// 「私有 pending 跨 Coordinator 不可见」这个真缺陷。
// 平台门：UIKit-only（Catalyst / 模拟器跑；macOS host swift test 整份不编译）。
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("ChartContainerView × DrawingSession：全局会话 / 双面板 / 连续画线")
@MainActor
struct ChartContainerViewDrawingSessionTests {

    private let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)

    /// 造「一个 engine + 上下两个真 Coordinator（各自真 KLineView，已布局出有效 viewport）」。
    private func makeRig() -> (TrainingEngine, ChartContainerView.Coordinator, ChartContainerView.Coordinator,
                               KLineView, KLineView) {
        let engine = TrainingEngine.preview()
        let upperC = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let lowerC = ChartContainerView(panel: .lower, engine: engine).makeCoordinator()
        let upperV = KLineView(frame: bounds)
        let lowerV = KLineView(frame: bounds)
        upperC.attach(to: upperV)
        lowerC.attach(to: lowerV)
        upperC.rebuildRenderState(bounds: bounds)   // 出真 viewport（candleStep > 0）
        lowerC.rebuildRenderState(bounds: bounds)
        return (engine, upperC, lowerC, upperV, lowerV)
    }

    /// 主图区内一个**真实可见 candle 上**的可落锚点 = 首根可见 candle 的中心。
    /// ⚠️ 不可用 `mainChartFrame.midX`：preview rig 的可见 slice 只有 1 根（panel 周期是 m60/daily，
    /// 各 2/1 根，且 reveal 钳 sliceEnd 到 currentIdx+1=1；candleStep=320/80=4pt）→ midX=160 落在
    /// 右侧 overscroll 空白区，xToIndex=40 越界，被 R7 fail-closed 校验拒掉（这本就是坏数据路径）。
    private func mainChartPoint(_ view: KLineView) -> CGPoint {
        let vp = view.renderState.viewport
        let mapper = CoordinateMapper(viewport: vp, displayScale: view.traitCollection.displayScale)
        return CGPoint(x: mapper.indexToX(vp.startIndex) + vp.geometry.candleStep / 2,
                       y: vp.mainChartFrame.midY)
    }

    @Test("#2 D42：上面板画一条、下面板画一条 —— 两条都提交，period 各自绑所在面板当时的周期")
    func bothPanelsCanDraw() {
        let (engine, upperC, lowerC, upperV, lowerV) = makeRig()
        engine.toggleDrawingMode()

        upperC.handleDrawingTapForTesting(at: mainChartPoint(upperV))
        lowerC.handleDrawingTapForTesting(at: mainChartPoint(lowerV))

        #expect(engine.drawings.count == 2)                       // ← 改造前：下面板那一下没反应
        #expect(engine.drawings[0].period == engine.upperPanel.period)   // D29 周期绑定
        #expect(engine.drawings[1].period == engine.lowerPanel.period)
        #expect(engine.drawings[0].panelPosition == 0)
        #expect(engine.drawings[1].panelPosition == 1)
    }

    @Test("#5 连续画线：同一面板连点三次 → 三条线；每次提交后会话与工具仍在")
    func continuousDrawing() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)

        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawingSession.drawingModeActive == true)   // ← 改造前：画完一条就退出了
        #expect(engine.drawingSession.activeDrawingTool == .horizontal)
        upperC.handleDrawingTapForTesting(at: p)
        upperC.handleDrawingTapForTesting(at: p)

        #expect(engine.drawings.count == 3)
        #expect(engine.drawingSession.drawingModeActive == true)
        #expect(engine.drawingSession.activeDrawingTool == .horizontal)
        #expect(engine.drawingSession.pendingAnchors.isEmpty)      // 提交后 pending 清空
    }

    @Test("#3 D31 跨 Coordinator：上面板 pending + 下面板落锚 → 只丢 pending，工具/会话存活")
    func crossCoordinatorPendingDiscard() {
        let (engine, upperC, lowerC, upperV, lowerV) = makeRig()
        // 人造多锚工具场景：.trend 需 ≥2 锚（DefaultDrawingInputController.minAnchors 非 .implemented
        // 恒 Int.max）→ 落一锚不会提交，pending 留得住。公共入口对未实现工具 fail-closed
        // （whole-branch R2-high），故绕开 beginDrawingSession、直接用内部 API 复现「多锚工具 pending
        // 跨面板存活」这个 1a-iii 才会真实可达的场景，并手动维持不变量（两面板都武装）。
        engine.drawingSession.activate(tool: .trend)
        engine.armPanelForDrawing(.trend, panel: .upper)
        engine.armPanelForDrawing(.trend, panel: .lower)
        upperC.handleDrawingTapForTesting(at: mainChartPoint(upperV))
        #expect(engine.drawingSession.pendingAnchors.count == 1)
        #expect(engine.drawingSession.pendingAnchorPanel == .upper)

        lowerC.handleDrawingTapForTesting(at: mainChartPoint(lowerV))   // 打到**另一个** Coordinator

        #expect(engine.drawingSession.pendingAnchors.count == 1)        // 上面板那个被丢，只剩下面板的新锚
        #expect(engine.drawingSession.pendingAnchorPanel == .lower)     // ← 私有 pending 时下面板清不掉上面板的
        #expect(engine.drawingSession.activeDrawingTool == .trend)      // ← 走 discardPendingAnchors，不是 cancel()
        #expect(engine.drawingSession.drawingModeActive == true)
        #expect(engine.drawings.isEmpty)                                 // 未成形，不提交
    }

    @Test("#1 D39：反复 sync/updateUIView **不改写**工具（1b-i 的类型行 toggle 不会被撤销）")
    func repeatedSyncNeverRewritesTool() {
        let (engine, upperC, _, upperV, _) = makeRig()
        // 模拟「未来底栏选了别的工具」：.trend 尚未实现，公共入口 fail-closed（whole-branch R2-high），
        // 且本测试恰好需要一个 ≠ .horizontal 的工具才能证明 sync 没有把它 re-arm 回 .horizontal ——
        // 借内部 API 直接置容器状态，并手动维持不变量（两面板都武装）。
        engine.drawingSession.activate(tool: .trend)
        engine.armPanelForDrawing(.trend, panel: .upper)
        engine.armPanelForDrawing(.trend, panel: .lower)
        for _ in 0..<5 {
            upperC.sync(panel: .upper, engine: engine, view: upperV)   // = updateUIView 反复触发
        }
        #expect(engine.drawingSession.activeDrawingTool == .trend)     // ← 改造前会被 re-arm 成 .horizontal
        #expect(engine.drawingSession.drawingModeActive == true)
    }

    @Test("#1 D39：未开会话时 sync **不会**自动武装任何工具（re-arm 已删除）")
    func syncNeverArmsToolWhenSessionOff() {
        let (engine, upperC, _, upperV, _) = makeRig()
        for _ in 0..<5 {
            upperC.sync(panel: .upper, engine: engine, view: upperV)
        }
        #expect(engine.drawingSession.drawingModeActive == false)
        #expect(engine.drawingSession.activeDrawingTool == nil)
    }

    @Test("codex R7 fail-closed：主图内 overscroll 空白区的 tap（越界 candleIndex）→ 不落锚不落库，会话存活")
    func outOfRangeTapIsDiscardedFailClosed() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        // preview rig 实证：可见 slice 只有 index 0 一根；midX=160 在主图内但 xToIndex=40（不存在的 candle）
        let f = upperV.renderState.viewport.mainChartFrame
        upperC.handleDrawingTapForTesting(at: CGPoint(x: f.midX, y: f.midY))
        #expect(engine.drawings.isEmpty)                                 // 越界 tap 不落库（改造前会存 candleIndex=40 坏数据）
        #expect(engine.drawingSession.pendingAnchors.isEmpty)            // 也不留 pending
        #expect(engine.drawingSession.drawingModeActive == true)         // fail-closed 只丢这次 tap，不砸会话
        #expect(engine.drawingSession.activeDrawingTool == .horizontal)
        // 随后点真实可见 candle 仍能画（校验不误伤正常路径）
        upperC.handleDrawingTapForTesting(at: mainChartPoint(upperV))
        #expect(engine.drawings.count == 1)
    }

    @Test("未开会话时点图 = 不画线")
    func tapDoesNothingWhenSessionOff() {
        let (engine, upperC, _, upperV, _) = makeRig()
        upperC.handleDrawingTapForTesting(at: mainChartPoint(upperV))
        #expect(engine.drawings.isEmpty)
    }

    @Test("1a-iv：惯性未停时点击 —— 锚落在**定住后**视口映射的那根 K 线上，且提交后图不再滑")
    func tapDuringInertiaUsesSettledViewport() {
        // 需要「真滚得动 + 可控帧驱动」的 engine：makeRig 的 preview fixture 只有 1 根可见 candle、滚不动。
        let (engine, fakes) = TrainingEnginePanLinkageTests.makeEngine(count: 200, tick: 150)
        let panelBounds = TrainingEnginePanLinkageTests.bounds       // 800×600，makeEngine 已 recordRenderBounds
        let c = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let v = KLineView(frame: panelBounds)
        c.attach(to: v)
        c.rebuildRenderState(bounds: panelBounds)
        engine.toggleDrawingMode()
        #expect(engine.isDrawingActive(on: .upper))                  // 前置：真在画线态

        // 甩出惯性 → 记下「滑动中」这一帧的 renderState → 再让 engine 多跑 6 帧但**不重建** → view 里的 viewport 变 stale
        engine.beginPan(panel: .upper)
        engine.applyPanOffset(deltaPixels: 200, renderBounds: panelBounds, panel: .upper)
        engine.endPan(velocity: 3000, renderBounds: panelBounds, panel: .upper)
        c.rebuildRenderState(bounds: panelBounds)
        let staleVP = v.renderState.viewport
        for _ in 0..<6 { _ = fakes().last?.fire(1.0 / 60.0) }

        // 取可见 slice **中部**的点：定住后索引会平移几根，取首根会掉出 slice 被 tapToAnchor fail-closed 拒掉。
        let staleMapper = CoordinateMapper(viewport: staleVP, displayScale: v.traitCollection.displayScale)
        let midIdx = staleVP.startIndex + staleVP.visibleCount / 2
        let point = CGPoint(x: staleMapper.indexToX(midIdx) + staleVP.geometry.candleStep / 2,
                            y: staleVP.mainChartFrame.midY)

        c.handleDrawingTapForTesting(at: point)

        let settledMapper = CoordinateMapper(viewport: v.renderState.viewport,
                                             displayScale: v.traitCollection.displayScale)
        let settledIdx = settledMapper.xToIndex(point.x)
        #expect(settledIdx != staleMapper.xToIndex(point.x))         // 防假绿：stale 与 settled 真的映射到不同 candle
        #expect(engine.drawings.count == 1)                          // 线真的落了（没被 fail-closed 守卫吞掉）
        #expect(engine.drawings.first?.anchors.first?.candleIndex == settledIdx)   // ⭐用的是定住后的映射

        let afterTap = engine.upperPanel.offset
        for _ in 0..<10 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(engine.upperPanel.offset == afterTap)                // ⭐惯性已被 tap 截住，提交后图不再滑
    }

    // MARK: - 1b-i PR-3：选择态 tap 接线（D34 复盘门 / D37 未命中清空 / D53 盾优先 / D54 画线态不 hitTest）

    /// 复盘 rig：与 `makeRig()` 同构，但 engine 是 review flow。
    /// engine 复用既有 `TrainingEngineDrawingCommitTests.reviewEngine()`（`:76-90`，两面板均 `.m3`）。
    private func makeReviewRig() -> (TrainingEngine, ChartContainerView.Coordinator, KLineView) {
        let engine = TrainingEngineDrawingCommitTests.reviewEngine()
        let c = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let v = KLineView(frame: bounds)
        c.attach(to: v)
        c.rebuildRenderState(bounds: bounds)     // 出真 viewport（candleStep > 0）
        return (engine, c, v)
    }

    @Test("D34 反向对照（防过度 fail-closed）：复盘的**画线态** tap 照常落线 —— 复盘画线是既有功能，不得回归")
    func reviewModeStillDrawsInDrawMode() {
        let (engine, c, v) = makeReviewRig()
        engine.toggleDrawingMode()
        #expect(engine.drawingSession.drawingModeActive == true)   // 前提成立
        #expect(engine.drawingSession.mode == .draw)               // 前提：默认就是画线态

        c.handleDrawingTapForTesting(at: mainChartPoint(v))

        #expect(engine.reviewDrawings.count == 1, "复盘画线是 1a-iii 起的既有功能，本切片不得回归")
        #expect(engine.drawings.isEmpty, "复盘新画线不得污染原训练线")
    }

    @Test("D34 trust-boundary：复盘的**选择态** tap 不选中（否则可改写已归档 record 里的原训练线）")
    func reviewModeNeverSelects() {
        let (engine, c, v) = makeReviewRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(v)
        c.handleDrawingTapForTesting(at: p)                        // 先在画线态落一条，保证 p 上真有线可命中
        #expect(engine.reviewDrawings.count == 1)                  // 前提成立（否则下面全是恒真）
        engine.drawingSession.setMode(.select)
        #expect(engine.drawingSession.mode == .select)

        c.handleDrawingTapForTesting(at: p)                        // 同一点，选择态

        #expect(engine.drawingSession.selectedDrawingID == nil, "复盘不得获得选中能力（D34 trust-boundary）")
        #expect(engine.drawingSession.selectedPanel == nil)
        #expect(engine.reviewDrawings.count == 1, "选择态也不落锚：不得又画出第二条")
        #expect(engine.drawings.isEmpty)
    }

    @Test("D37：选择态未命中 → 清空选中、且不落锚（先命中建立选中，再点空白处）")
    func selectModeMissClearsSelectionAndDrawsNothing() throws {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let onLine = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: onLine)              // 画线态落一条
        try #require(engine.drawings.count == 1)                   // 前提成立
        engine.drawingSession.setMode(.select)
        upperC.handleDrawingTapForTesting(at: onLine)              // 选择态命中它
        let hitID = engine.drawings[0].id
        #expect(engine.drawingSession.selectedDrawingID == hitID)  // 前提成立（否则"被清空"恒真）
        #expect(engine.drawingSession.selectedPanel == .upper)

        // 同一列、纵向挪开 60pt（远超 8pt 命中容差），仍落在主图内
        let frame = upperV.renderState.viewport.mainChartFrame
        let missY = onLine.y - 60 >= frame.minY ? onLine.y - 60 : onLine.y + 60
        #expect(abs(missY - onLine.y) > 8)                         // 自证：这确实是个"未命中"的点
        #expect(missY >= frame.minY && missY <= frame.maxY)        // 自证：仍在主图内（不是靠出界侥幸未命中）
        // ⭐ 命中那一刻，**渲染态**也必须立刻带上它（只断言 session 状态证明不了用户看得见高亮）
        #expect(upperV.renderState.selectedDrawingID == hitID,
                "命中后必须立刻重建渲染态，否则本帧画的还是旧选中（D41/D55）")

        upperC.handleDrawingTapForTesting(at: CGPoint(x: onLine.x, y: missY))

        #expect(engine.drawingSession.selectedDrawingID == nil, "未命中必须清空选中（D37）")
        #expect(engine.drawingSession.selectedPanel == nil)
        #expect(engine.drawings.count == 1, "选择态未命中也绝不落锚")
        #expect(upperV.renderState.selectedDrawingID == nil, "清空后渲染态也必须立刻不再高亮")
    }

    @Test("D41/D55 端到端：tap 命中 → 该条真的以选中色画出来（像素级，不只是状态位）")
    func selectedLineActuallyRendersHighlighted() throws {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)                   // 画线态落一条
        try #require(engine.drawings.count == 1)                   // 前提成立
        // ⚠️ `.draw` 分支在 `routeDrawingCommit` 之后**不**重建渲染态（既有行为，生产靠 observation
        //    刷新；本 rig 是直连 Coordinator，不经 updateUIView）→ 不补这一次重建，`upperV.renderState`
        //    里还没有这条线，下面的 `before` 会是空的（codex plan-R4-F2）。
        upperC.rebuildRenderState(bounds: bounds)
        #expect(upperV.renderState.drawings.count == 1)             // 前提成立：线真的进渲染态了
        engine.drawingSession.setMode(.select)

        // 选中前：画出来的是它自己的 colorToken 色
        let before = Self.litPixels(of: upperV)
        #expect(!before.isEmpty, "对照组必须真的画出了线（否则下面的差异断言恒真）")

        upperC.handleDrawingTapForTesting(at: p)                   // 选择态命中
        #expect(engine.drawingSession.selectedDrawingID == engine.drawings[0].id)   // 前提成立

        let after = Self.litPixels(of: upperV)
        #expect(!after.isEmpty, "选中后线仍要画出来（不能因为高亮反而消失）")
        // ⚠️ 不假设测试环境的 scheme（`KLineView.draw` 取 `themeController.resolve(trait:)`，
        //    CI 上是 light 还是 dark 不由本测试决定）→ 两套选中色都认，判据仍然有力：
        //    两者都 ≠ 任何 DrawingColorToken 的解析结果（`selectionColorIsOutsideTokenRange` 已钉死）。
        let sels = [DrawingColorResolver.selectionRGBA(scheme: .light),
                    DrawingColorResolver.selectionRGBA(scheme: .dark)]
        #expect(after.contains { px in
            sels.contains { abs(px.r - CGFloat($0.red)) < 0.06 && abs(px.g - CGFloat($0.green)) < 0.06
                          && abs(px.b - CGFloat($0.blue)) < 0.06 }
        }, "选中的线必须以选中色画出（D55）")
        #expect(before != after, "选中前后画面必须真的不同，否则高亮等于没做")
    }

    @Test("D40 路由（行为级）：最上层但**未揭示**的线不得被选中 —— 证明命中吃的是 visibleDrawings 不是 engine.drawings")
    func hitIgnoresUnrevealedTopmostLine() throws {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)                   // 画线态落一条（revealTick = 当时 tick）
        try #require(engine.drawings.count == 1)                   // 前提成立
        let visible = engine.drawings[0]
        // 在它**之上**（数组末尾 = z-order 最上层）注入一条同几何、但 revealTick 远在未来的线。
        // 命中若直接吃 `engine.drawings`（绕过渐显过滤），逆序第一个命中的就是这条幽灵线。
        let ghost = DrawingObject(id: "UNREVEALED", toolType: visible.toolType, anchors: visible.anchors,
                                  isExtended: visible.isExtended, panelPosition: visible.panelPosition,
                                  revealTick: engine.tick.globalTickIndex + 9_999, period: visible.period)
        engine.injectDrawingsForTesting([visible, ghost])
        engine.drawingSession.setMode(.select)

        upperC.handleDrawingTapForTesting(at: p)

        #expect(engine.drawingSession.selectedDrawingID == visible.id,
                "未揭示的线不在渲染集合里 → 也不该在命中集合里（D40）")
    }

    @Test("D40 路由（行为级）：属于**另一个面板**的线不得在本面板被选中（belongsToPanel 过滤真的生效）")
    func hitIgnoresOtherPanelLine() throws {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)
        try #require(engine.drawings.count == 1)                   // 前提成立
        let mine = engine.drawings[0]
        #expect(mine.period == engine.upperPanel.period)           // 前提：它确实属于上面板
        #expect(engine.upperPanel.period != engine.lowerPanel.period)   // 前提：两面板周期不同（非 fail-safe 态）
        // 同几何、同 revealTick，但 period 绑到**下**面板 → belongsToPanel 判它不属于上面板
        let other = DrawingObject(id: "OTHER_PANEL", toolType: mine.toolType,
                                  anchors: [DrawingAnchor(period: engine.lowerPanel.period,
                                                          candleIndex: mine.anchors[0].candleIndex,
                                                          price: mine.anchors[0].price)],
                                  isExtended: mine.isExtended, panelPosition: 1,
                                  revealTick: mine.revealTick, period: engine.lowerPanel.period)
        engine.injectDrawingsForTesting([mine, other])
        engine.drawingSession.setMode(.select)

        upperC.handleDrawingTapForTesting(at: p)

        #expect(engine.drawingSession.selectedDrawingID == mine.id,
                "另一个面板的线不在本面板渲染集合里 → 也不该在本面板命中集合里（D40/D29）")
        #expect(engine.drawingSession.selectedPanel == .upper)
    }

    @Test("D41 跨面板：在另一个面板选中后，原面板刷新时高亮必须消失（不得两条同时高亮）")
    func selectingInOtherPanelUnhighlightsSibling() {
        let (engine, upperC, lowerC, upperV, lowerV) = makeRig()
        engine.toggleDrawingMode()
        let pUp = mainChartPoint(upperV), pLow = mainChartPoint(lowerV)
        upperC.handleDrawingTapForTesting(at: pUp)                 // 上面板一条
        lowerC.handleDrawingTapForTesting(at: pLow)                // 下面板一条
        #expect(engine.drawings.count == 2)                        // 前提成立
        engine.drawingSession.setMode(.select)

        lowerC.handleDrawingTapForTesting(at: pLow)                // 先选中下面板那条
        let lowID = engine.drawingSession.selectedDrawingID
        #expect(lowID != nil)                                      // 前提成立
        #expect(lowerV.renderState.selectedDrawingID == lowID)     // 下面板确实高亮着
        upperC.rebuildRenderState(bounds: bounds)
        #expect(upperV.renderState.selectedDrawingID == nil, "上面板不该被下面板的选中点亮（二元组门）")

        upperC.handleDrawingTapForTesting(at: pUp)                 // 改选上面板那条
        #expect(engine.drawingSession.selectedPanel == .upper)
        #expect(upperV.renderState.selectedDrawingID == engine.drawingSession.selectedDrawingID)

        // ⚠️ 本 rig 是直连 Coordinator、不经 `updateUIView` → sibling 不会自动刷新，必须手动触发一次
        //    （生产靠 observation：`rebuildRenderState` 在 bounds 守卫**之前**显式读了选中二元组，
        //     Task 3 Step 5 已建立该订阅，并由 `rebuildRenderStateSubscribesToPanelState` 源码守卫钉死；
        //     observation 的真实触发**单测测不到**，同本仓「图表冻结」那次回归的处置）。
        lowerC.rebuildRenderState(bounds: bounds)
        #expect(lowerV.renderState.selectedDrawingID == nil,
                "下面板刷新后必须不再高亮 —— 否则屏幕上会同时有两条选中线")
    }

    /// ⚠️ **必须是具名 `Equatable` 结构体，不能用元组**（codex plan-R6-F1）：Swift 的元组**不遵循协议**，
    /// 故 `[(r: CGFloat, g: CGFloat, b: CGFloat)]` 不是 `Equatable` 的 `Array`，`before != after`
    /// **类型检查就过不了**。而这段是 UIKit-gated 的 → host `swift test` 整份不编译、发现不了，
    /// 要等到 Catalyst 闸门才炸。（既有的 `HorizontalLineToolTests.litColumn` 返回元组数组是安全的，
    /// 因为那边只 `contains {…}` 逐元素比，从不比整个数组。）
    private struct Px: Equatable { let r: CGFloat; let g: CGFloat; let b: CGFloat }

    /// 把 `view` 当前 renderState 画进一张 bitmap，返回线像素的（反 premultiplied）颜色。
    /// 与 `HorizontalLineToolTests.litColumn` 同思路，但走的是**真实 `KLineView.draw(_:)` 派发链**
    /// （renderState → drawDrawings → tool.render），这才证明得了「选中态一路流到了像素」。
    private static func litPixels(of view: KLineView) -> [Px] {
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        view.draw(view.bounds)
        UIGraphicsPopContext()
        var out: [Px] = []
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = CGFloat(data[i + 3]) / 255
            guard a > 0.3 else { continue }
            out.append(Px(r: CGFloat(data[i]) / 255 / a,
                          g: CGFloat(data[i + 1]) / 255 / a,
                          b: CGFloat(data[i + 2]) / 255 / a))
        }
        return out
    }

    @Test("D54：画线态单击**恒落锚**、绝不 hitTest —— 点在已有线上是又叠一条，不是选中它（验收 #5）")
    func drawModeTapAlwaysAnchorsNeverSelects() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawings.count == 1)                        // 前提成立
        #expect(engine.drawingSession.mode == .draw)

        upperC.handleDrawingTapForTesting(at: p)                   // 同一点再来一下

        #expect(engine.drawings.count == 2, "画线态点在已有线上 = 又叠一条重合线，不是选中")
        #expect(engine.drawingSession.selectedDrawingID == nil, "画线态永远不建立选中")
    }

    @Test("N6/D53：`.pending` 盾对**选择态**同样拒收 —— 既不选中也不落锚")
    func pendingShieldRejectsSelectTap() {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)                   // 无盾时先落一条（保证 p 上有线）
        #expect(engine.drawings.count == 1)                        // 前提成立
        engine.drawingSession.setMode(.select)
        engine.drawingSession.setStylePanelVisible(true)           // 两面板 → .pending（fail-closed 窗口）
        #expect(engine.drawingSession.shield[0] == .pending)       // 前提成立

        upperC.handleDrawingTapForTesting(at: p)

        #expect(engine.drawingSession.selectedDrawingID == nil, ".pending 拒收一切 tap，选择态不例外（D53）")
        #expect(engine.drawings.count == 1)
    }

    @Test("N6/D53：`.rect` 区内的选择态 tap 被挡、区外正常选中（证明分叉在盾之后、且盾不过度屏蔽）")
    func rectShieldBlocksSelectInsideOnly() throws {
        let (engine, upperC, _, upperV, _) = makeRig()
        engine.toggleDrawingMode()
        let p = mainChartPoint(upperV)
        upperC.handleDrawingTapForTesting(at: p)
        try #require(engine.drawings.count == 1)                   // 前提成立
        let hitID = engine.drawings[0].id
        engine.drawingSession.setMode(.select)

        // ① 盾盖住 p → 拒收
        let covering = CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)
        #expect(covering.contains(p))                              // 自证：这个盾确实盖住了 p
        engine.drawingSession.setShield(.rect(covering), panel: .upper)
        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawingSession.selectedDrawingID == nil, "盾内的 tap 既不落锚也不选中")

        // ② 盾挪到别处（区外）→ 同一点正常选中。**没有这一半**，实现完全可以用「有盾就一律拒收」骗过 ①
        let far = CGRect(x: 0, y: 0, width: 8, height: 8)
        #expect(!far.contains(p))                                  // 自证：这个盾没盖住 p
        engine.drawingSession.setShield(.rect(far), panel: .upper)
        upperC.handleDrawingTapForTesting(at: p)
        #expect(engine.drawingSession.selectedDrawingID == hitID, "盾外的 tap 应正常命中选中")
        #expect(engine.drawings.count == 1, "选择态命中不落锚")
    }
}
#endif
