// W3-11-R1b-wire — bounce 实时接线测试（机制 A 分派 + 三 clamp + interruptDeceleration）
// Spec: docs/superpowers/specs/2026-06-16-w3-11-r1b-wire-design.md
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingEngine bounce 接线", .serialized)
struct TrainingEngineBounceWiringTests {
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// 真实 init + initialTick 线程：count=200/tick=150 → mainW=800/step=10/base=71/maxOffset=710/bounceEdges=[.max]。
    static func makeEngine(count: Int, tick: Int) -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        let maxTick = count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: count)),
            maxTick: maxTick,
            initialTick: tick,                                       // 覆盖 flow.initialTick(0) → 制造有滚动空间几何
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { onTick in
                let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f })
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.recordRenderBounds(Self.bounds, panel: .lower)
        return (e, { box.fakes })
    }

    // §六.3 drag full-clamp（新签名）
    @Test("drag full-clamp：推过 maxOffset → 钳 maxOffset；推过 0 → 钳 0")
    func dragFullClamp() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(ob.bounceEdges.contains(.max))                       // 前提：有滚动空间（maxOffset≈710）
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset + 999, renderBounds: Self.bounds, panel: .upper)
        #expect(abs(e.upperPanel.offset - ob.maxOffset) < 1e-6)     // 钳上界
        e.applyPanOffset(deltaPixels: -99999, renderBounds: Self.bounds, panel: .upper)
        #expect(e.upperPanel.offset == 0)                            // 钳下界 0
    }

    // §六.4 机制 A 分派 killer：v>0 → bounce（offset 朝 maxOffset 越界过冲，M5）
    @Test("dispatch v>0 有空间 → bounce overscroll（offset 朝 maxOffset 移动并越界）M5")
    func dispatchPositiveBounces() {
        let (e, fakes) = Self.makeEngine(count: 200, tick: 150)
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(ob.bounceEdges.contains(.max))
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset, renderBounds: Self.bounds, panel: .upper)   // 起于最老边
        e.endPan(velocity: 4000, renderBounds: Self.bounds, panel: .upper)                       // 强甩朝最老边
        var maxSeen = e.upperPanel.offset
        for _ in 0..<240 { _ = fakes().last?.fire(1.0 / 60.0); maxSeen = max(maxSeen, e.upperPanel.offset) }
        #expect(maxSeen > ob.maxOffset)                              // 越界过冲（证 bounce 非 plain，方向朝 max）
        #expect(abs(e.upperPanel.offset - ob.maxOffset) < 1.0)       // settle 落 maxOffset
    }

    // §六.4 v<0 → plain decel（offset 朝 0、不越 max）
    @Test("dispatch v<0 → plain decel（offset 朝 0 单调、不越 maxOffset）")
    func dispatchNegativeDecel() {
        let (e, fakes) = Self.makeEngine(count: 200, tick: 150)
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(ob.bounceEdges.contains(.max))
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset * 0.5, renderBounds: Self.bounds, panel: .upper)
        e.endPan(velocity: -4000, renderBounds: Self.bounds, panel: .upper)
        var maxSeen = e.upperPanel.offset
        for _ in 0..<240 { _ = fakes().last?.fire(1.0 / 60.0); maxSeen = max(maxSeen, e.upperPanel.offset) }
        #expect(maxSeen <= ob.maxOffset + 1e-6)                      // 从不越界（plain，非 bounce）
        #expect(e.upperPanel.offset == 0)                            // full-clamp 硬停 0
    }

    // §六.4 C1 killer：v>0 但无滚动空间 → plain decel + full-clamp 钳 0（不 strand 正 offset）
    @Test("C1：v>0 无滚动空间（bounceEdges==[]）→ plain decel full-clamp 钳 0，不 strand")
    func c1NoScrollSpacePositiveNoStrand() {
        let (e, fakes) = Self.makeEngine(count: 40, tick: 39)   // count<=visibleCount → base=0 → upperBound=0 → [0,0]
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(ob.bounceEdges.isEmpty)                              // 前提：无滚动空间
        e.beginPan(panel: .upper)
        e.endPan(velocity: 4000, renderBounds: Self.bounds, panel: .upper)   // 正速
        for _ in 0..<240 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(e.upperPanel.offset == 0)                            // 不 strand 成正值
    }

    // §六.5 onUpdate clamp 类型对比（H3）：bounce floor 放 overscroll vs decel full 钳两边
    @Test("§六.5 onUpdate clamp 类型：bounce floor 越界 vs decel full 两边夹")
    func onUpdateClampTypeContrast() {
        let (e1, f1) = Self.makeEngine(count: 200, tick: 150)
        let ob = RenderStateBuilder.offsetBounds(engine: e1, panel: .upper, bounds: Self.bounds)
        #expect(ob.bounceEdges.contains(.max))
        e1.beginPan(panel: .upper)
        e1.applyPanOffset(deltaPixels: ob.maxOffset, renderBounds: Self.bounds, panel: .upper)
        e1.endPan(velocity: 6000, renderBounds: Self.bounds, panel: .upper)
        var bounceMax = e1.upperPanel.offset
        for _ in 0..<60 { _ = f1().last?.fire(1.0 / 60.0); bounceMax = max(bounceMax, e1.upperPanel.offset) }
        #expect(bounceMax > ob.maxOffset + 10)                       // floor：明确越界（不钳上界）

        let (e2, f2) = Self.makeEngine(count: 200, tick: 150)
        e2.beginPan(panel: .upper)
        e2.applyPanOffset(deltaPixels: ob.maxOffset * 0.3, renderBounds: Self.bounds, panel: .upper)
        e2.endPan(velocity: -6000, renderBounds: Self.bounds, panel: .upper)
        var decelMin = e2.upperPanel.offset, decelMax = e2.upperPanel.offset
        for _ in 0..<240 {
            _ = f2().last?.fire(1.0 / 60.0)
            decelMin = min(decelMin, e2.upperPanel.offset); decelMax = max(decelMax, e2.upperPanel.offset)
        }
        #expect(decelMin >= -1e-6)                                   // full 下界：从不 <0
        #expect(decelMax <= ob.maxOffset + 1e-6)                     // full 上界：从不 >max
    }

    // §六.8 H3：re-grab 中途 overscroll → beginPan 归 maxOffset
    @Test("H3：bounce overscroll 中途 beginPan → offset 归 maxOffset（不 strand）")
    func interruptBeginPanNormalizes() {
        let (e, fakes) = Self.makeEngine(count: 200, tick: 150)
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(ob.bounceEdges.contains(.max))
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset, renderBounds: Self.bounds, panel: .upper)
        e.endPan(velocity: 4000, renderBounds: Self.bounds, panel: .upper)
        var sawOverscroll = false
        for _ in 0..<30 { _ = fakes().last?.fire(1.0 / 60.0); if e.upperPanel.offset > ob.maxOffset { sawOverscroll = true; break } }
        #expect(sawOverscroll)                              // 确处于 overscroll 中
        e.beginPan(panel: .upper)                           // re-grab 打断
        #expect(abs(e.upperPanel.offset - ob.maxOffset) < 1e-6)   // 归 maxOffset，不 strand
    }

    // §六.8 M2-new：bounce overscroll 中途 activateDrawingTool → snapshot offset 归 maxOffset（顺序不变量 killer）
    @Test("M2-new：overscroll 中途 activateDrawingTool → snap.frozen.offset==maxOffset（归一在算 range 前）")
    func activateDrawingDuringOverscrollNormalizes() {
        let (e, fakes) = Self.makeEngine(count: 200, tick: 150)
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(ob.bounceEdges.contains(.max))
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset, renderBounds: Self.bounds, panel: .upper)
        e.endPan(velocity: 6000, renderBounds: Self.bounds, panel: .upper)
        var overscrolled = false
        for _ in 0..<30 { _ = fakes().last?.fire(1.0 / 60.0); if e.upperPanel.offset > ob.maxOffset + 5 { overscrolled = true; break } }
        #expect(overscrolled)                               // 确处于 overscroll（offset>maxOffset）
        e.activateDrawingTool(.trend, panel: .upper)        // 中断 + 归一须在算 range（捕获 baseRev）前
        guard case .drawing(let snap) = e.upperPanel.interactionMode else { Issue.record("应进入 drawing"); return }
        #expect(abs(snap.frozen.offset - ob.maxOffset) < 1e-6)   // 归一后 offset（无归一则 frozen.offset>maxOffset）
        #expect(snap.frozen.offset <= ob.maxOffset + 1e-6)       // 绝非 overscrolled
    }

    // §六.8 stale 自纠正：动画 settle 后再 beginPan（isDecelerating==false）→ 不误钳一个当前合法 offset
    @Test("stale 自纠正：settle 后 beginPan 不误钳一个当前合法 offset")
    func interruptStaleSelfCorrect() {
        let (e, fakes) = Self.makeEngine(count: 200, tick: 150)
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset * 0.5, renderBounds: Self.bounds, panel: .upper)
        e.endPan(velocity: -4000, renderBounds: Self.bounds, panel: .upper)   // decel 到 0、settle
        for _ in 0..<600 { _ = fakes().last?.fire(1.0 / 60.0) }
        #expect(e.upperPanel.offset == 0)
        e.beginPan(panel: .upper)                                     // 拖到合法中段
        e.applyPanOffset(deltaPixels: ob.maxOffset * 0.5, renderBounds: Self.bounds, panel: .upper)
        let mid = e.upperPanel.offset
        e.beginPan(panel: .upper)                                     // 无活跃动画 → 不应 clamp 改 mid
        #expect(abs(e.upperPanel.offset - mid) < 1e-6)
    }

    // codex branch-diff M1：resize 中途 bounce → recordRenderBounds stop+归一新几何（不 strand 持久 overscroll 间隙）
    @Test("resize 中途 bounce：bounds 变 → stop + 按新几何归一（offset 不 strand 过新 maxOffset）")
    func resizeMidBounceNormalizes() {
        let (e, fakes) = Self.makeEngine(count: 200, tick: 150)
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(ob.bounceEdges.contains(.max))
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset, renderBounds: Self.bounds, panel: .upper)
        e.endPan(velocity: 6000, renderBounds: Self.bounds, panel: .upper)
        var overscrolled = false
        for _ in 0..<30 { _ = fakes().last?.fire(1.0 / 60.0); if e.upperPanel.offset > ob.maxOffset { overscrolled = true; break } }
        #expect(overscrolled)                               // 确处于 overscroll（offset>旧 maxOffset 710）
        // resize 到更小 bounds（新 maxOffset 更小）→ recordRenderBounds 触发 stop+归一
        let smaller = CGRect(x: 0, y: 0, width: 400, height: 600)
        let freshOb = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: smaller)
        #expect(freshOb.maxOffset < ob.maxOffset)           // 前提：新 max 更小（旧 settled offset 会 strand）
        e.recordRenderBounds(smaller, panel: .upper)
        #expect(e.upperPanel.offset >= freshOb.minOffset - 1e-6)
        #expect(e.upperPanel.offset <= freshOb.maxOffset + 1e-6)   // 不 strand 过新 maxOffset（归一新几何）
    }

    // codex R2-M1：drag 结束于旧最老边后（**无 animator**）resize → recordRenderBounds 仍归一（不 gate on isDecelerating）
    @Test("R2-M1：drag 停旧最老边（无 animator）后 resize → 归一新几何，不 strand")
    func resizeAfterSettleNormalizes() {
        let (e, _) = Self.makeEngine(count: 200, tick: 150)
        let ob = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: Self.bounds)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: ob.maxOffset, renderBounds: Self.bounds, panel: .upper)   // drag 到旧最老边 710
        e.cancelPan(panel: .upper)                                                      // 结束 drag，**不启动惯性**（无 animator）
        #expect(abs(e.upperPanel.offset - ob.maxOffset) < 1e-6)                         // offset 停在 710
        let smaller = CGRect(x: 0, y: 0, width: 400, height: 600)
        let freshOb = RenderStateBuilder.offsetBounds(engine: e, panel: .upper, bounds: smaller)
        #expect(freshOb.maxOffset < ob.maxOffset)
        e.recordRenderBounds(smaller, panel: .upper)                                    // 无 animator 也须归一
        #expect(e.upperPanel.offset <= freshOb.maxOffset + 1e-6)                        // 归一新 max 355，不 strand
    }
}
