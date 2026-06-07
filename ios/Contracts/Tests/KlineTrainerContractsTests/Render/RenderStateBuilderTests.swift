// Kline Trainer Swift Contracts — C8a RenderStateBuilder host tests
// Spec: docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md
import Testing
import Foundation          // Date()（perf smoke）；@testable import 不透传 Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("RenderStateBuilder 视口几何 + 装配")
struct RenderStateBuilderTests {

    /// 连续轴 candle 工厂：第 i 根 endGlobalIndex==i（满足 partitioningIndex 单调）。
    static func candles(period: Period, count: Int,
                        volume: Int64 = 1000,
                        macd: Bool = false) -> [KLineCandle] {
        (0..<count).map { i in
            KLineCandle(
                period: period, datetime: Int64(i) * 60,
                open: 10, high: 11, low: 9, close: 10 + Double(i) * 0.1,
                volume: volume, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: macd ? 0.2 : nil, macdDea: macd ? 0.1 : nil, macdBar: macd ? 0.1 : nil,
                globalIndex: i, endGlobalIndex: i)
        }
    }

    static func panel(period: Period = .m3, offset: CGFloat = 0) -> PanelViewState {
        PanelViewState(period: period, interactionMode: .autoTracking,
                       visibleCount: 0, offset: offset, revision: 0)
    }

    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    // split: mainChart width=800 height=360；candleStep=800/80=10；candleWidth=7；gap=3

    @Test("几何：固定 80 分母 → candleStep/candleWidth/gap")
    func geometry() {
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 10) < 1e-9)
        #expect(abs(vp.geometry.candleWidth - 7) < 1e-9)
        #expect(abs(vp.geometry.gap - 3) < 1e-9)
        #expect(abs(vp.mainChartFrame.width - 800) < 1e-9)
        #expect(abs(vp.mainChartFrame.height - 360) < 1e-9)
    }

    @Test("锚定(a)：count>=80 且 currentIdx>=79 → 物理右缘（slot 79）")
    func anchorPhysicalRightEdge() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 150, bounds: Self.bounds)
        #expect(vp.startIndex == 71)
        #expect(vp.visibleCount == 80)
        #expect(150 - vp.startIndex == 79)
    }

    @Test("锚定(b)：count>=80 但 currentIdx<79（早期 tick）→ startIndex==0，slot=currentIdx")
    func anchorEarlyTick() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 10, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.visibleCount == 80)
        #expect(10 - vp.startIndex == 10)
    }

    @Test("锚定(c)：count<80 且 currentIdx==count-1（短聚合面板最新根）→ startIndex==0，非物理右缘")
    func anchorShortHistory() {
        let cs = Self.candles(period: .m60, count: 30)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(period: .m60), candles: cs, tick: 29, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.visibleCount == 30)
        #expect(29 - vp.startIndex == 29)
        #expect(29 < RenderStateBuilder.defaultVisibleCount - 1)
        #expect(abs(vp.geometry.candleStep - 10) < 1e-9)
    }

    @Test("priceRange：用可见切片经 PriceRange.calculate（含 5% 扩展）")
    func priceRange() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 150, bounds: Self.bounds)
        let slice = cs[vp.startIndex ..< vp.startIndex + vp.visibleCount]
        let expected = PriceRange.calculate(from: slice)
        #expect(vp.priceRange == expected)
    }

    @Test("聚合面板锚定用面板自身 period（非 .m3）：.m60 锚 ≠ 误用 .m3 锚")
    func aggregatePanelAnchorsOwnPeriod() {
        let m60 = Self.candles(period: .m60, count: 50)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(period: .m60), candles: m60, tick: 100, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.visibleCount == 50)
    }

    // count=200, tick=150 → baseStartIndex=71, candleStep=10, upperBound=120
    @Test("offset：中段正 offset → wholeShift + pixelShift 余量")
    func offsetMidScroll() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 25), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=floor(25/10)=2 → startIndex=71-2=69（非边界）；pixelShift=25-20=5
        #expect(vp.startIndex == 69)
        #expect(abs(vp.pixelShift - 5) < 1e-9)
    }

    @Test("offset：负 offset → 余量仍落 [0,candleStep)")
    func offsetNegative() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -25), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=floor(-2.5)=-3 → startIndex=71-(-3)=74；pixelShift=-25-(-30)=5
        #expect(vp.startIndex == 74)
        #expect(vp.pixelShift >= 0 && vp.pixelShift < 10)
        #expect(abs(vp.pixelShift - 5) < 1e-9)
    }

    @Test("饱和(顶过左界)：offset 把 startIndex clamp 到 0 → pixelShift=0")
    func saturateLeftClamped() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 750), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=75 → unclamped=71-75=-4 → clamp 0
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
    }

    @Test("饱和(顶过右界)：offset 把 startIndex clamp 到 upperBound → pixelShift=0")
    func saturateRightClamped() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -600), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=floor(-60)=-60 → unclamped=71+60=131 → clamp upperBound 120
        #expect(vp.startIndex == 120)
        #expect(vp.pixelShift == 0)
    }

    @Test("饱和(F3：恰落左界 + 非零余量，clamp 不改值)→ pixelShift=0")
    func saturateLeftExactBoundary() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 715), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=71 → unclamped=71-71=0（==下界，clamp 不改）；余量=715-710=5 → 按落位归 0
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
    }

    @Test("饱和(F3：恰落右界 + 非零余量，clamp 不改值)→ pixelShift=0")
    func saturateRightExactBoundary() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -485), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=floor(-48.5)=-49 → unclamped=71+49=120（==upperBound，clamp 不改）；余量=-485-(-490)=5 → 0
        #expect(vp.startIndex == 120)
        #expect(vp.pixelShift == 0)
    }

    @MainActor
    @Test("make：preview 引擎装配完整 renderState（透传 markers/drawings、crosshair nil）")
    func makeAssembles() {
        let engine = TrainingEngine.preview()
        let rs = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        #expect(rs.panel.period == engine.upperPanel.period)
        #expect(rs.crosshairPoint == nil)
        #expect(rs.markers == engine.markers)
        #expect(rs.drawings == engine.drawings)
        #expect(rs.frames == ChartPanelFrames.split(in: Self.bounds))
        #expect(!rs.visibleCandles.isEmpty)
        // 值域来自真实 make（F4：直接验 rs.* 而非仅 NonDegenerateRange 约定）：
        // preview .m60 candles macd 全 nil → macdRange 走 fallback；volume 含 0 下界。
        #expect(rs.volumeRange.lower < rs.volumeRange.upper)
        #expect(rs.macdRange.lower < rs.macdRange.upper)
        #expect(rs.volumeRange.lower <= 0)   // [0.0]+ 保证下界 ≤ 0
    }

    @Test("值域 fallback 约定（contract characterization；make 内部同款调用）")
    func valueRangeContract() {
        let macd = NonDegenerateRange.make(values: [], fallback: -0.001...0.001)
        #expect(macd.lower < macd.upper)
        let vol = NonDegenerateRange.make(values: [0.0] + [Double](repeating: 0, count: 5),
                                          fallback: 0.0...1.0)
        #expect(vol.lower < vol.upper)
    }

    @MainActor
    @Test("守卫：bounds==.zero → .empty")
    func emptyBoundsGuard() {
        let engine = TrainingEngine.preview()
        let rs = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: .zero)
        #expect(rs == KLineRenderState.empty)
    }

    @MainActor
    @Test("守卫：zero-height bounds → .empty")
    func zeroHeightGuard() {
        let engine = TrainingEngine.preview()
        let rs = RenderStateBuilder.make(engine: engine, panel: .upper,
                                         bounds: CGRect(x: 0, y: 0, width: 800, height: 0))
        #expect(rs == KLineRenderState.empty)
    }

    @Test("visibleCandleRange 委托 makeViewport（同 startIndex..<+visibleCount）")
    func visibleRangeDelegates() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 150, bounds: Self.bounds)
        let range = RenderStateBuilder.visibleCandleRange(
            panelState: Self.panel(), candles: cs, tick: 150, bounds: Self.bounds)
        #expect(range == vp.startIndex ..< vp.startIndex + vp.visibleCount)
    }

    @Test("visibleCandleRange 空 candles → 0..<0（不崩）")
    func visibleRangeEmpty() {
        let range = RenderStateBuilder.visibleCandleRange(
            panelState: Self.panel(), candles: [], tick: 0, bounds: Self.bounds)
        #expect(range == 0..<0)
    }

    @MainActor
    @Test("Equatable 短路*前提*：同 engine 状态两次 make → 结果 ==（host 仅证前提，didSet 抑制属 device）")
    func equalityPrecondition() {
        let engine = TrainingEngine.preview()
        let a = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        let b = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        #expect(a == b)
    }
}
