// Kline Trainer Swift Contracts — C8 ChartContainerView 布局重算回归（修 #2 复盘静态界面空白）
// Mirror: ChartContainerViewCompileTests（UIKit-only；macOS host 编译为空，模拟器/Catalyst 跑）
//
// 复现的 bug：renderState 仅在 ChartContainerView.updateUIView（@Bindable engine observation 变化）时
// 用 view.bounds 重算；KLineView 无 layoutSubviews 自重算。静态 engine（Review：tick 冻结、canAdvance false、
// 无交易）首帧若 bounds 未定（.zero）算出 .empty 后，再无 observation 触发 updateUIView → 永久空白。
// Replay/Normal 因 tick 持续推进不断重触发故有图。修复：KLineView.layoutSubviews 在 bounds 变化时回调
// Coordinator，用当前 engine + 真实 bounds 重算 renderState（不依赖 SwiftUI observation 再触发）。
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
@testable import KlineTrainerContracts

@Suite("ChartContainerView 布局重算（修 #2 复盘静态界面空白）")
struct ChartContainerViewLayoutTests {

    @Test("布局到有效尺寸后 renderState 重算非空（静态 engine 不依赖 observation 再触发）")
    @MainActor
    func renderStateRecomputedOnLayoutForStaticEngine() {
        let engine = TrainingEngine.preview()   // 静态：默认 tick，无 observation 变化驱动 updateUIView
        let coordinator = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let view = KLineView(frame: .zero)       // 首帧零尺寸：模拟 updateUIView 时 bounds 未定
        coordinator.attach(to: view)
        // 首帧（零 bounds / 未重算）renderState 为空——等价 make 在 bounds<=0 返回 .empty。
        #expect(view.renderState.visibleCandles.isEmpty)

        // SwiftUI 完成布局，view 拿到有效尺寸；静态 engine 无 observation 变化触发 updateUIView。
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.setNeedsLayout()
        view.layoutIfNeeded()                    // 触发 layoutSubviews

        // 修复前：KLineView 无 layoutSubviews 重算 → renderState 仍空 → 复盘空白（本断言 FAIL）。
        // 修复后：layoutSubviews 回调 Coordinator 用当前 engine + 真实 bounds 重算 → 非空。
        #expect(!view.renderState.visibleCandles.isEmpty)
    }

    @Test("layoutSubviews 同 bounds 只回调一次（lastLaidOutBounds 去重，挡重复 make）")
    @MainActor
    func boundsChangeDedupedForSameBounds() {
        let view = KLineView(frame: .zero)
        var calls = 0
        view.onBoundsChange = { _ in calls += 1 }
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.setNeedsLayout(); view.layoutIfNeeded()   // .zero → 320×480：变化，回调一次
        view.setNeedsLayout(); view.layoutIfNeeded()   // bounds 未变：去重，不回调
        // 去重 guard 若被移除，第二次 layout 会再触发 → calls==2 → 本断言 FAIL。
        #expect(calls == 1)
    }

    @Test("布局重算同步 engine bounds → 静态界面后续 pinch 生效（codex R1-F1：不被 stale .zero bounds no-op）")
    @MainActor
    func layoutRebuildSyncsEngineBoundsForPinch() {
        let engine = TrainingEngine.preview()
        let coordinator = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let view = KLineView(frame: .zero)
        coordinator.attach(to: view)
        // 静态界面（Review）：未经 observation 驱动的 updateUIView，engine 缓存 bounds 仍 .zero。
        // 仅 layoutSubviews 把图画出来——该路径须同步 engine bounds，否则后续手势读到 stale .zero。
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.setNeedsLayout(); view.layoutIfNeeded()
        // applyPinch(.changed) guard bounds.width>0（读 engine 缓存 bounds）。缓存仍 .zero → no-op → visibleCount 不变。
        let before = engine.upperPanel.visibleCount
        engine.applyPinch(scale: 1.0, focusX: 160, phase: .began, panel: .upper)
        engine.applyPinch(scale: 2.0, focusX: 160, phase: .changed, panel: .upper)
        engine.applyPinch(scale: 2.0, focusX: 160, phase: .ended, panel: .upper)
        // 修复前：layout 路径不同步 engine bounds → 缓存 .zero → pinch no-op → visibleCount 不变 → FAIL。
        // 修复后：rebuildRenderState 先 recordRenderBounds → 缓存有效 → 缩放生效。
        #expect(engine.upperPanel.visibleCount != before)
    }

    @Test("瞬态零尺寸 layout 不 clamp panel offset（codex R2-F1：滚动位置不被吞）")
    @MainActor
    func zeroSizeLayoutPreservesScrollOffset() {
        // 200 根 + tick 150 → 有滚动空间（可造非零 offset）。
        let (engine, _) = TrainingEngineBounceWiringTests.makeEngine(count: 200, tick: 150)
        let coordinator = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let view = KLineView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        coordinator.attach(to: view)
        view.setNeedsLayout(); view.layoutIfNeeded()   // 有效 bounds 记录

        // 滚动到非零 offset（freeScrolling，朝最老边）。
        engine.beginPan(panel: .upper)
        let ob = RenderStateBuilder.offsetBounds(engine: engine, panel: .upper, bounds: view.bounds)
        engine.applyPanOffset(deltaPixels: ob.maxOffset * 0.5, renderBounds: view.bounds, panel: .upper)
        let scrolled = engine.upperPanel.offset
        #expect(scrolled > 0)   // 前置：确有非零滚动位置

        // 瞬态零尺寸 layout（导航/分屏/旋转过渡）。
        view.frame = .zero
        view.setNeedsLayout(); view.layoutIfNeeded()

        // 无 guard：rebuildRenderState → recordRenderBounds(.zero) → 零宽 offsetBounds → offset clamp 0 → FAIL。
        // 有 guard：无效 bounds 早返 → 不改 engine 状态 → offset 保持。
        #expect(engine.upperPanel.offset == scrolled)
    }

    @Test("零尺寸 rebuild（updateUIView 路径）不 clamp offset（codex R3-F1：observation 路径同护）")
    @MainActor
    func zeroBoundsRebuildPreservesScrollOffset() {
        // updateUIView 现委托 rebuildRenderState(bounds: view.bounds)；SwiftUI 在瞬态零尺寸期触发
        // updateUIView 即等价于此处直接以 .zero 调 rebuildRenderState——须同样不吞滚动位置。
        let (engine, _) = TrainingEngineBounceWiringTests.makeEngine(count: 200, tick: 150)
        let coordinator = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let view = KLineView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        coordinator.attach(to: view)
        view.setNeedsLayout(); view.layoutIfNeeded()

        engine.beginPan(panel: .upper)
        let ob = RenderStateBuilder.offsetBounds(engine: engine, panel: .upper, bounds: view.bounds)
        engine.applyPanOffset(deltaPixels: ob.maxOffset * 0.5, renderBounds: view.bounds, panel: .upper)
        let scrolled = engine.upperPanel.offset
        #expect(scrolled > 0)

        // 直接走 updateUIView 委托的 helper，模拟瞬态零尺寸 observation 更新。
        coordinator.rebuildRenderState(bounds: .zero)

        #expect(engine.upperPanel.offset == scrolled)
    }
}
#endif
