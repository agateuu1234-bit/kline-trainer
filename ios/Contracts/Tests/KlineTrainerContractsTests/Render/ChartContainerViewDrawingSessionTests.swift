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

    /// 主图区内一个可落锚的点（tapToAnchor 要求落在 mainChartFrame 内）。
    private func mainChartPoint(_ view: KLineView) -> CGPoint {
        let f = view.renderState.viewport.mainChartFrame
        return CGPoint(x: f.midX, y: f.midY)
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

    @Test("未开会话时点图 = 不画线")
    func tapDoesNothingWhenSessionOff() {
        let (engine, upperC, _, upperV, _) = makeRig()
        upperC.handleDrawingTapForTesting(at: mainChartPoint(upperV))
        #expect(engine.drawings.isEmpty)
    }
}
#endif
