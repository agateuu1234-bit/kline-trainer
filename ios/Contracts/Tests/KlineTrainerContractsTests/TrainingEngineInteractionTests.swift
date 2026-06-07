// C8b TrainingEngine 交互编排测试（Wave 2 顺位 7 下半）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite struct TrainingEngineInteractionTests {

    static let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// 单 .m3 双面板 engine + 注入 fake 减速驱动；返回 engine 与「按创建序的 fake 列表」(0=upper,1=lower)。
    static func engine(closes: [Double] = Array(repeating: 10, count: 100))
        -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        let maxTick = closes.count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(closes),
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { onTick in
                let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f
            })
        return (e, { box.fakes })
    }

    @Test("减速 onUpdate 经 reducer 派 offsetApplied（freeScrolling 累加 offset + bump）")
    func decelerationOnUpdateRoutesThroughReducer() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)                       // autoTracking → freeScrolling
        e.endPan(velocity: 1000, panel: .upper)         // startDeceleration → animator.start
        let before = e.upperPanel.offset
        let fired = fakes()[0].fire(1.0 / 120.0)        // 推进一帧 → onUpdate → offsetApplied
        #expect(fired == true)                          // 仍在减速
        #expect(e.upperPanel.offset != before)          // offset 被 reducer 累加
        #expect(e.upperPanel.interactionMode == .freeScrolling)
    }

    @Test("beginPan: autoTracking → freeScrolling + revision bump")
    func beginPanEntersFreeScrolling() {
        let (e, _) = Self.engine()
        let r0 = e.upperPanel.revision
        e.beginPan(panel: .upper)
        #expect(e.upperPanel.interactionMode == .freeScrolling)
        #expect(e.upperPanel.revision == r0 + 1)
    }

    @Test("applyPanOffset: freeScrolling offset 累加")
    func applyPanOffsetAccumulates() {
        let (e, _) = Self.engine()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 12, panel: .upper)
        e.applyPanOffset(deltaPixels: 8, panel: .upper)
        #expect(e.upperPanel.offset == 20)
    }

    @Test("endPan: freeScrolling + 有限速度 → 启动减速（驱动创建、未失活）")
    func endPanStartsDeceleration() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        #expect(fakes().count >= 1)
        #expect(fakes()[0].isInvalidated == false)
    }

    @Test("endPan: 速度低于阈值 → 不启动（start guard no-op，无 fake 创建）")
    func endPanBelowThresholdNoStart() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.endPan(velocity: 0.1, panel: .upper)   // < stopThreshold 0.5 → animator.start no-op
        #expect(fakes().isEmpty)
    }

    @Test("cancelPan: 不启动减速（freeScrolling 结束但无惯性）")
    func cancelPanNoDeceleration() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.cancelPan(panel: .upper)
        #expect(fakes().isEmpty)            // 未调 animator.start
    }
}
