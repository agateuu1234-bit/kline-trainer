// ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewAutoSelectTests.swift
// Spec: docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md §5.3（M12）
// 平台门：UIKit-only（Catalyst / 模拟器跑；macOS host swift test 整份不编译）。
// ⚠️ 本文件是本片**唯一**新增的 UIKit-gated 测试 —— 新增即触发 Catalyst 四处基线同步
//    （[[feedback_catalyst_uikit_baseline_four_sync]]，本 task Step 6）。
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("自动选中 × 渲染态：画线态提交后**本帧**高亮就跟上")
@MainActor
struct ChartContainerViewAutoSelectTests {

    private let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)

    /// 造「一个 engine + 上面板一个真 Coordinator（真 KLineView，已布局出有效 viewport）」。
    /// 结构照抄同目录 `ChartContainerViewDrawingSessionTests.makeRig`（同一份 rig 语义）。
    private func makeRig() -> (TrainingEngine, ChartContainerView.Coordinator, KLineView) {
        let engine = TrainingEngine.preview()
        let c = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let v = KLineView(frame: bounds)
        c.attach(to: v)
        c.rebuildRenderState(bounds: bounds)          // 出真 viewport（candleStep > 0）
        return (engine, c, v)
    }

    /// 主图区内一个**真实可见 candle 上**的可落锚点 = 首根可见 candle 的中心。
    /// ⚠️ 不可用 `mainChartFrame.midX`：preview rig 的可见 slice 只有 1 根，midX 落在右侧 overscroll
    ///    空白区，`xToIndex` 越界会被 fail-closed 校验拒掉（理由与同目录既有 rig 逐字相同）。
    private func mainChartPoint(_ view: KLineView) -> CGPoint {
        let vp = view.renderState.viewport
        let mapper = CoordinateMapper(viewport: vp, displayScale: view.traitCollection.displayScale)
        return CGPoint(x: mapper.indexToX(vp.startIndex) + vp.geometry.candleStep / 2,
                       y: vp.mainChartFrame.midY)
    }

    @Test("M12 的守门测试：画线态点一下 → 落线 + 自动选中，且**本帧** renderState.selectedDrawingID 已是新那条")
    func drawTapUpdatesRenderStateSelectionInSameFrame() throws {
        let (engine, c, v) = makeRig()
        engine.toggleDrawingMode()
        #expect(engine.drawingSession.mode == .draw)

        c.handleDrawingTapForTesting(at: mainChartPoint(v))

        // ① 落线 + 自动选中（经 DrawingEditRouter，路由本身的判据已在 host 测过）
        #expect(engine.drawings.count == 1)
        let newId = try #require(engine.drawings.last?.id)
        #expect(engine.drawingSession.selectedDrawingID == newId)

        // ② **本帧**渲染态就已经跟上 —— 这是 M12 唯一的判别力所在：
        //    handleDrawingTap 开头那次 rebuildRenderState 发生在选中改变**之前**，
        //    不补 `.draw` 分支这一次重建，本帧画出来的还是旧选中（高亮慢一帧）。
        //    ⚠️ 不得改成依赖 SwiftUI observation 顺带刷新：Coordinator 这条直连路径不经
        //       updateUIView，那样等于没有证据。
        #expect(v.renderState.selectedDrawingID == newId,
                "本帧渲染态没跟上 —— `.draw` 分支缺了那一次 rebuildRenderState")
    }
}
#endif
