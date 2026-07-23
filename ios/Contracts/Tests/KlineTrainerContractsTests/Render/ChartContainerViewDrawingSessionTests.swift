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
}
#endif
