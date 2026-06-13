// 顺位 3 engine applyPinch 编排测试（设计 D6）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite struct TrainingEnginePinchTests {

    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// 复用 InteractionTests 夹具风格：单 .m3 双面板 + fake 减速驱动 + 已记录渲染 bounds。
    static func engine(closes: [Double] = Array(repeating: 10, count: 200))
        -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        let maxTick = closes.count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
                             maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(closes),
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { onTick in
                let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f
            })
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.recordRenderBounds(Self.bounds, panel: .lower)
        return (e, { box.fakes })
    }

    @Test("init seed：双面板 visibleCount == 80（D5，不再是 0）")
    func initSeedsEighty() {
        let (e, _) = Self.engine()
        #expect(e.upperPanel.visibleCount == 80)
        #expect(e.lowerPanel.visibleCount == 80)
    }

    @Test("began 停本面板减速（同 beginPan 先例）")
    func beganStopsDeceleration() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        #expect(fakes()[0].isInvalidated == false)
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        #expect(fakes()[0].isInvalidated == true)
    }

    @Test("autoTracking 缩放：scale=2 → visibleCount 40，offset 恒 0，mode 不变（裁决 A 右锚）")
    func autoTrackingZoom() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
        #expect(e.upperPanel.offset == 0)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .ended, panel: .upper)
    }

    @Test("scaleAtBegan 归一（R1-L1）：began 于 1.02 → changed 1.02 无变化（effectiveScale=1）")
    func normalizationKillsDeadZone() {
        let (e, _) = Self.engine()
        let r0 = e.upperPanel.revision
        e.applyPinch(scale: 1.02, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 1.02, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 80)
        #expect(e.upperPanel.revision == r0)       // target==current → 跳过派发，不 bump
        // 继续张开到 2.04 → effectiveScale=2 → 40
        e.applyPinch(scale: 2.04, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
    }

    @Test("非有限/非正 scale → guard return 真无操作（R2-L1：不派发、状态零改动）")
    func nonFiniteScaleNoOp() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        let before = e.upperPanel
        e.applyPinch(scale: .nan, focusX: 400, phase: .changed, panel: .upper)
        e.applyPinch(scale: .infinity, focusX: 400, phase: .changed, panel: .upper)
        e.applyPinch(scale: 0, focusX: 400, phase: .changed, panel: .upper)
        e.applyPinch(scale: -1, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel == before)
    }

    @Test("bounds 未记录 → changed no-op（防御）")
    func zeroBoundsNoOp() {
        // fixture 已记录双面板 bounds → 此测试独立构造从未 recordRenderBounds 的 engine
        let maxTick = 199
        let e2 = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
                             maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: 200)),
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        e2.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        let before = e2.upperPanel
        e2.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e2.upperPanel == before)
    }

    @Test("self-heal（D6）：changed 先于 began → 以当前值+当前 scale 补 seed，首拍无跳变")
    func selfHealOnMissingBegan() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.7, focusX: 400, phase: .changed, panel: .upper)   // 无 began
        #expect(e.upperPanel.visibleCount == 80)        // effectiveScale=1 → 不变
        e.applyPinch(scale: 3.4, focusX: 400, phase: .changed, panel: .upper)   // 相对 1.7 翻倍
        #expect(e.upperPanel.visibleCount == 40)
        e.applyPinch(scale: 3.4, focusX: 400, phase: .ended, panel: .upper)
    }

    @Test("ended/cancelled 清 base：下一次 changed 重新 self-heal 不串味")
    func endedClearsBase() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)   // → 40
        e.applyPinch(scale: 2.0, focusX: 400, phase: .ended, panel: .upper)
        // 新手势：changed-only，scale=2.0 起步 → self-heal base=(40, 2.0) → effectiveScale=1 → 40 不变
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
    }

    @Test("per-panel 隔离：upper 缩放不影响 lower")
    func perPanelIsolation() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
        #expect(e.lowerPanel.visibleCount == 80)
    }

    @Test("freeScrolling focus 端到端：缩放前后 pinch 中点连续索引不变 + 离散 candle 不变")
    func freeScrollingFocusInvariant() {
        let (e, _) = Self.engine()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 15, panel: .upper)     // freeScrolling offset=15
        let candles = e.allCandles[.m3]!
        let tick = e.tick.globalTickIndex
        let vpBefore = RenderStateBuilder.makeViewport(panelState: e.upperPanel, candles: candles,
                                                       tick: tick, bounds: Self.bounds)
        // NormalFlow.initialTick==0 → currentIdx==0 → before 视口左缘饱和（startIndex=0/pixelShift=0）；
        // fx=405 仍为 candle 40 槽中心（远离 candle 边界，离散锚有判别力），前后离散索引恒 40。
        // 非饱和-中段 focus 路径由 Task 1 endToEndFocusInvariant（tick=150）覆盖。
        let fx: CGFloat = 405
        let uBefore = CGFloat(vpBefore.startIndex) + (fx - vpBefore.pixelShift) / vpBefore.geometry.candleStep
        e.applyPinch(scale: 1.0, focusX: fx, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: fx, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
        let vpAfter = RenderStateBuilder.makeViewport(panelState: e.upperPanel, candles: candles,
                                                      tick: tick, bounds: Self.bounds)
        let uAfter = CGFloat(vpAfter.startIndex) + (fx - vpAfter.pixelShift) / vpAfter.geometry.candleStep
        #expect(abs(uAfter - uBefore) < 1e-9)
        let mB = CoordinateMapper(viewport: vpBefore, displayScale: 1)
        let mA = CoordinateMapper(viewport: vpAfter, displayScale: 1)
        #expect(mB.xToIndex(fx) == mA.xToIndex(fx))
        #expect(e.upperPanel.interactionMode == .freeScrolling)   // 不切 mode
    }

    @Test("revision 单调：每次生效 changed bump 一次；目标不变跳过不 bump")
    func revisionMonotone() {
        let (e, _) = Self.engine()
        let r0 = e.upperPanel.revision
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.revision == r0 + 1)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)   // target 不变
        #expect(e.upperPanel.revision == r0 + 1)
        e.applyPinch(scale: 2.1, focusX: 400, phase: .changed, panel: .upper)   // 80/2.1→38
        #expect(e.upperPanel.revision == r0 + 2)
    }
}
