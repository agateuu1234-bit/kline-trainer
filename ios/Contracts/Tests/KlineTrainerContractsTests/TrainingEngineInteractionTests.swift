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

    @Test("beginPan 停掉进行中的减速（re-grab 截住惯性，标准滚动语义；final-review F1）")
    func beginPanStopsRunningDeceleration() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)   // 启动减速 → 创建 upper 驱动 fakes[0]
        let upperFake = fakes()[0]
        #expect(upperFake.isInvalidated == false)
        e.beginPan(panel: .upper)                  // re-grab → 必须先停减速
        #expect(upperFake.isInvalidated == true)
        let fired = upperFake.fire(1.0 / 120.0)    // 旧驱动延迟帧
        #expect(fired == false)                    // 已停，不再发 onUpdate / 不漂移
    }

    @Test("交易硬切 autoTracking 时停减速：trade 后 stale 帧不漂移 offset")
    func tradeStopsDecelerationNoDriftAfter() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        let upperFake = fakes()[0]
        _ = e.buy(panel: .upper, tier: .tier1)          // tradeTriggered → 硬切 autoTracking + stopAllDeceleration
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(upperFake.isInvalidated == true)         // 减速被停（驱动失活）
        let off = e.upperPanel.offset
        let fired = upperFake.fire(1.0 / 120.0)          // 模拟延迟帧
        #expect(fired == false)                          // 驱动自失活，不再发 onUpdate
        #expect(e.upperPanel.offset == off)              // 无 offsetApplied 漂移
    }

    @Test("硬切 autoTracking 后 offset 经 reducer 归零（D8 不变量：autoTracking ⇒ offset==0）")
    func autoTrackingOffsetZeroedAfterTrade() {
        let (e, _) = Self.engine()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 45, panel: .upper)   // freeScrolling, offset=45
        #expect(e.upperPanel.offset == 45)
        _ = e.holdOrObserve(panel: .upper)                 // 经 advanceAndAccount 硬切 + 归零
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.offset == 0)                  // 归零（makeViewport mode-agnostic 下保 autoTracking 锁最新）
    }

    @Test("switchPeriodCombo 硬切 autoTracking 同样停减速 + 归零")
    func periodComboStopsAndZeroes() {
        // 双面板需多周期数据：用 60m/日 默认组合，向 toSmaller 切到 15m/60m
        let (e, fakes) = Self.engineMultiPeriod()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        let upperFake = fakes()[0]
        e.switchPeriodCombo(direction: .toSmaller)
        #expect(upperFake.isInvalidated == true)
        #expect(e.upperPanel.offset == 0)
        #expect(e.upperPanel.interactionMode == .autoTracking)
    }

    @Test("activateDrawingTool: autoTracking → drawing，snapshot 含 viewport candleRange")
    func activateDrawingEntersDrawingMode() {
        let (e, _) = Self.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        let expected = RenderStateBuilder.visibleCandleRange(
            panelState: e.upperPanel, candles: e.allCandles[.m3]!,
            tick: e.tick.globalTickIndex, bounds: Self.bounds)
        e.activateDrawingTool(.trend, panel: .upper)
        guard case .drawing(let snap) = e.upperPanel.interactionMode else {
            Issue.record("应进入 drawing 模式"); return
        }
        #expect(snap.frozen.candleRange == expected)
    }

    @Test("activateDrawingTool: drawing 模式下再激活 → no-op（工具切换归 DrawingToolManager/Wave 3）")
    func activateDrawingWhileDrawingNoOp() {
        let (e, _) = Self.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.activateDrawingTool(.trend, panel: .upper)
        let modeBefore = e.upperPanel.interactionMode
        e.activateDrawingTool(.ray, panel: .upper)
        #expect(e.upperPanel.interactionMode == modeBefore)   // 仍 drawing(同 snapshot)
    }

    @Test("deleteDrawing: 按 index 从 engine.drawings 删除")
    func deleteDrawingRemovesByIndex() {
        let d0 = DrawingObject(toolType: .trend, anchors: [], isExtended: false, panelPosition: 0)
        let d1 = DrawingObject(toolType: .ray, anchors: [], isExtended: false, panelPosition: 0)
        let (e, _) = Self.engineWithDrawings([d0, d1])
        e.deleteDrawing(at: 0)
        #expect(e.drawings.count == 1)
        #expect(e.drawings[0].toolType == .ray)
    }

    static func engineWithDrawings(_ drawings: [DrawingObject]) -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        let e = TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: 99),
            allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: 100)),
            maxTick: 99, initialCapital: 100_000, initialCashBalance: 100_000,
            initialDrawings: drawings, initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { onTick in
                let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f
            })
        return (e, { box.fakes })
    }

    /// 多周期 engine（默认 60m/日 组合可向 toSmaller 切 15m/60m）+ 注入 fake 驱动。
    static func engineMultiPeriod() -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        func candle(_ p: Period, start: Int, end: Int) -> KLineCandle {
            KLineCandle(period: p, datetime: Int64(start) * 180, open: 10, high: 11, low: 9, close: 10,
                        volume: 1, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: start, endGlobalIndex: end)
        }
        let m3 = (0..<8).map { candle(.m3, start: $0, end: $0) }
        let m15 = [candle(.m15, start: 0, end: 3), candle(.m15, start: 4, end: 7)]
        let m60 = [candle(.m60, start: 0, end: 3), candle(.m60, start: 4, end: 7)]
        let daily = [candle(.daily, start: 0, end: 7)]
        let all: [Period: [KLineCandle]] = [.m3: m3, .m15: m15, .m60: m60, .daily: daily]
        let e = TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: 7), allCandles: all, maxTick: 7,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m60, initialLowerPeriod: .daily,
            decelerationDriverFactory: { onTick in
                let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f
            })
        return (e, { box.fakes })
    }
}
