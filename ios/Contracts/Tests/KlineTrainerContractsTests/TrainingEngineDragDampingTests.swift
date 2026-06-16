// TrainingEngineDragDampingTests.swift（新文件头）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingEngine drag 跟手橡皮筋阻尼（R1b-drag）", .serialized)
struct TrainingEngineDragDampingTests {
    static let bounds = TrainingEngineBounceWiringTests.bounds
    static func makeEngine() -> (TrainingEngine, () -> [FakeFrameDriver]) {
        TrainingEngineBounceWiringTests.makeEngine(count: 200, tick: 150)
    }

    @Test("dragRaw 生命周期：beginPan seed=offset / endPan·cancelPan 清 / 两面板独立")
    func dragRawLifecycle() {
        let (e, _) = Self.makeEngine()
        #expect(e.debug_dragRawFor(.upper) == nil)
        e.beginPan(panel: .upper)
        #expect(e.debug_dragRawFor(.upper) == e.upperPanel.offset)   // seed=归一后 offset
        #expect(e.debug_dragRawFor(.lower) == nil)                   // 面板独立
        e.endPan(velocity: 0, renderBounds: Self.bounds, panel: .upper)
        #expect(e.debug_dragRawFor(.upper) == nil)                   // endPan 清
        e.beginPan(panel: .lower)
        e.cancelPan(panel: .lower)
        #expect(e.debug_dragRawFor(.lower) == nil)                   // cancelPan 清
    }

    @Test("过最老边阻尼：offset=maxOffset+damp 且 maxOffset<offset<raw（D2 killer）")
    func dragPastEdgeDamps() {
        let (e, _) = Self.makeEngine()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(ob.bounceEdges.contains(.max))
        let raw = ob.maxOffset + 600
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: raw, renderBounds: Self.bounds, panel: .upper)   // 从 0 一帧推到 raw
        let mainW: CGFloat = 800
        let expected = ob.maxOffset + RubberBand.damp(over: 600, dimension: mainW)
        #expect(abs(e.upperPanel.offset - expected) < 1e-6)
        #expect(e.upperPanel.offset > ob.maxOffset)            // 确实过界
        #expect(e.upperPanel.offset < raw)                     // 确实被压缩（非 vacuous）
    }

    @Test("反拖解绕：过界后回拉 → 连续单调降回 maxOffset 再 1:1（raw 累加器正确）")
    func reverseDragUnwinds() {
        let (e, _) = Self.makeEngine()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        e.beginPan(panel: .upper)
        for _ in 0..<6 { e.applyPanOffset(deltaPixels: 100, renderBounds: Self.bounds, panel: .upper) }  // raw=600（<maxOffset 710，仍界内 1:1）
        #expect(abs(e.upperPanel.offset - 600) < 1e-6)         // 界内 1:1
        for _ in 0..<3 { e.applyPanOffset(deltaPixels: 100, renderBounds: Self.bounds, panel: .upper) }  // raw=900 > 710 → 阻尼
        let overOffset = e.upperPanel.offset
        #expect(overOffset > ob.maxOffset)
        var prev = overOffset
        for _ in 0..<3 { e.applyPanOffset(deltaPixels: -100, renderBounds: Self.bounds, panel: .upper); #expect(e.upperPanel.offset < prev); prev = e.upperPanel.offset }  // 单调降
        #expect(e.upperPanel.offset <= ob.maxOffset + 1e-6)    // 回到界内
    }

    @Test("界内 1:1 回归：[0,maxOffset] 内 drag 与硬钳逐字等价")
    func inBoundsLinear() {
        let (e, _) = Self.makeEngine()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset * 0.5, renderBounds: Self.bounds, panel: .upper)
        #expect(abs(e.upperPanel.offset - ob.maxOffset * 0.5) < 1e-6)   // 1:1
    }

    @Test("最新边硬钳无给（单边 killer）：往最新边推 → 恒 0、反向立即响应、永不 <0")
    func newestEdgeHardClamp() {
        let (e, _) = Self.makeEngine()
        e.beginPan(panel: .upper)                               // 起于 offset 0（autoTracking tick=150 → 0）
        e.applyPanOffset(deltaPixels: -500, renderBounds: Self.bounds, panel: .upper)  // 往最新边硬推
        #expect(e.upperPanel.offset == 0)                      // 硬钳 0，不给
        e.applyPanOffset(deltaPixels: 200, renderBounds: Self.bounds, panel: .upper)   // 立即反向
        #expect(abs(e.upperPanel.offset - 200) < 1e-6)         // 无死区，立即响应到 200（raw=max(0,-500)+200=200）
    }

    @Test("无滚动空间硬钳（E6）：maxOffset==0 → 任意 drag 恒 0")
    func noScrollRoomHardClamp() {
        let (e, _) = TrainingEngineBounceWiringTests.makeEngine(count: 5, tick: 0)   // count≤visibleCount → 无空间
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(!ob.bounceEdges.contains(.max))                // 无滚动空间
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 500, renderBounds: Self.bounds, panel: .upper)
        #expect(e.upperPanel.offset == 0)                      // 不给
    }

    @Test("endPan 从 overscroll 慢松手（v=0）→ 启动弹簧回 maxOffset（非 no-op strand）D3 killer")
    func endPanFromOverscrollZeroVelocitySprings() {
        let (e, fakes) = Self.makeEngine()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset + 600, renderBounds: Self.bounds, panel: .upper)  // 拖到 overscroll
        #expect(e.upperPanel.offset > ob.maxOffset)
        e.endPan(velocity: 0, renderBounds: Self.bounds, panel: .upper)            // 慢松手
        for _ in 0..<300 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(abs(e.upperPanel.offset - ob.maxOffset) < 1.0)                     // 弹回 maxOffset（非 strand 在界外）
    }

    @Test("endPan 从 overscroll 内向甩（v<0）→ 弹回 maxOffset 不过冲/不下穿")
    func endPanFromOverscrollInwardVelocitySprings() {
        let (e, fakes) = Self.makeEngine()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset + 600, renderBounds: Self.bounds, panel: .upper)
        e.endPan(velocity: -2000, renderBounds: Self.bounds, panel: .upper)       // 内向甩
        var minSeen = e.upperPanel.offset
        for _ in 0..<300 { _ = fakes().last?.fire(1.0 / 60.0); minSeen = min(minSeen, e.upperPanel.offset) }
        #expect(abs(e.upperPanel.offset - ob.maxOffset) < 1.0)                    // 落 maxOffset
        #expect(minSeen >= ob.maxOffset - 2.0)                                    // 临界阻尼不显著下穿（容 settle 容差）
    }

    @Test("对照回归：界内 offset<maxOffset + v=0 endPan → 不弹（R1b-wire 既有）")
    func endPanInBoundsZeroVelocityNoSpring() {
        let (e, fakes) = Self.makeEngine()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset * 0.5, renderBounds: Self.bounds, panel: .upper)
        let before = e.upperPanel.offset
        e.endPan(velocity: 0, renderBounds: Self.bounds, panel: .upper)
        for _ in 0..<60 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(abs(e.upperPanel.offset - before) < 1e-6)                         // 不动（v=0 界内不弹）
    }

    @Test("cancel-于-overscroll（E4）：drag 过界后 cancelPan → 归一 maxOffset、dragRaw==nil")
    func cancelAtOverscrollNormalizes() {
        let (e, _) = Self.makeEngine()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset + 600, renderBounds: Self.bounds, panel: .upper)  // 越界
        #expect(e.upperPanel.offset > ob.maxOffset)
        e.cancelPan(panel: .upper)                                  // 两指接管/drawing 截获
        #expect(abs(e.upperPanel.offset - ob.maxOffset) < 1e-6)    // 归一 maxOffset（无残留越界间隙）
        #expect(e.debug_dragRawFor(.upper) == nil)
    }

    @Test("resize 中途 active drag（E5）：bounds 变 → offset 归新几何 + dragRaw 重同步")
    func resizeMidDragResyncsDragRaw() {
        let (e, _) = Self.makeEngine()
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset, renderBounds: Self.bounds, panel: .upper)   // 到最老边 710
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 600)                                 // 窗口变窄 → 新几何
        e.recordRenderBounds(narrow, panel: .upper)
        let nb = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: narrow)
        #expect(e.upperPanel.offset <= nb.maxOffset + 1e-6)        // offset 归新 [0,newMax]
        #expect(e.debug_dragRawFor(.upper) == e.upperPanel.offset) // dragRaw 重同步=归一后 offset
        // 续拖一帧不应基于 stale raw 跳变（delta 0 → offset 不变）
        let after = e.upperPanel.offset
        e.applyPanOffset(deltaPixels: 0, renderBounds: narrow, panel: .upper)
        #expect(abs(e.upperPanel.offset - after) < 1e-6)
    }
}
