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

    @Test("锚定(b)：count>=80 但 currentIdx<79（早期 tick）→ startIndex==0，只显已揭示前缀（reveal）")
    func anchorEarlyTick() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 10, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.visibleCount == 11)        // reveal：slice=candles[0..<11]（currentIdx+1），非旧 80
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

    // count=200, tick=150 → baseStartIndex=71, candleStep=10, upperBound=max(0,baseStartIndex)=71（reveal）
    @Test("offset：中段正 offset → wholeShift + pixelShift 余量")
    func offsetMidScroll() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 25), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=floor(25/10)=2 → startIndex=71-2=69（非边界）；pixelShift=25-20=5
        #expect(vp.startIndex == 69)
        #expect(abs(vp.pixelShift - 5) < 1e-9)
    }

    @Test("offset：负 offset（前向/朝新）→ clamp 回 autoTracking（reveal 禁前窥）")
    func offsetNegative() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -25), candles: cs, tick: 150, bounds: Self.bounds)
        // reveal：upperBound=max(0,baseStartIndex)=71；wholeShift=floor(-2.5)=-3 → unclamped=74 → clamp 71
        //（前向滚动不可越当前 tick）；startIndex==71==upperBound → pixelShift 边 pin=0
        #expect(vp.startIndex == 71)
        #expect(vp.pixelShift == 0)
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

    @Test("饱和(前向/朝新越界)：负大 offset → clamp 到 autoTracking（reveal），pixelShift=0")
    func saturateRightClamped() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -600), candles: cs, tick: 150, bounds: Self.bounds)
        // reveal：upperBound=max(0,71)=71；wholeShift=floor(-60)=-60 → unclamped=131 → clamp 71（不越当前 tick）
        #expect(vp.startIndex == 71)
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

    @Test("饱和(前向恰落旧右界 + 非零余量)：reveal 下仍 clamp 到 autoTracking，pixelShift=0")
    func saturateRightExactBoundary() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -485), candles: cs, tick: 150, bounds: Self.bounds)
        // reveal：upperBound=71；wholeShift=floor(-48.5)=-49 → unclamped=120 → clamp 71；余量按落位归 0
        #expect(vp.startIndex == 71)
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

    @Test("crosshair 参数透传到 renderState.crosshairPoint")
    @MainActor
    func crosshairPassthrough() {
        let e = TrainingEngine.preview()
        let pt = CGPoint(x: 120, y: 240)
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds, crosshair: pt)
        #expect(rs.crosshairPoint == pt)
    }

    @Test("crosshair 默认 nil（既有 C8a 调用面不变）")
    @MainActor
    func crosshairDefaultsNil() {
        let e = TrainingEngine.preview()
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rs.crosshairPoint == nil)
    }

    @Test("perf smoke（非权威）：5000 根 makeViewport 装配开销")
    func perfSmoke() {
        let cs = Self.candles(period: .m3, count: 5000)
        let panel = Self.panel()
        let start = Date()
        for _ in 0..<100 {
            _ = RenderStateBuilder.makeViewport(panelState: panel, candles: cs,
                                                tick: 4000, bounds: Self.bounds)
        }
        let ms = Date().timeIntervalSince(start) * 1000 / 100
        // 非权威 smoke：仅记录单次装配毫秒；spec「120Hz 单帧 <4ms」完整 draw 帧预算归 C8b/顺位 9。
        print("[C8a perf smoke] makeViewport avg = \(ms) ms (non-authoritative; not the spec frame budget)")
        #expect(ms < 50)   // 极宽松上界，仅防病态退化（partitioningIndex O(log n) + 切片 O(80)）
    }

    @Test("perf smoke（非权威）：完整 make() 装配开销（含 volume/macd range + 装配）")
    @MainActor
    func makePerfSmoke() {
        // make() 的成本由 ≤80 根可见切片的 map/flatMap + KLineRenderState 装配主导
        //（总根数仅影响 makeViewport 的 O(log n) 二分，已由既有 perfSmoke 覆盖）。
        // preview() 仅 8 根不足以压装配，故直接造 5000 根 .m3 engine。
        let cs = Self.candles(period: .m3, count: 5000, macd: true)
        let maxTick = cs.count - 1
        let engine = TrainingEngine(
            flow: NormalFlow(
                fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
                maxTick: maxTick),
            allCandles: [.m3: cs],
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3)
        let start = Date()
        for _ in 0..<100 {
            _ = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        }
        let ms = Date().timeIntervalSince(start) * 1000 / 100
        // 非权威 host smoke：draw 侧帧预算唯一权威 = device Instruments runbook（2026-06-14 frame-budget）。
        print("[顺位12 perf smoke] make() avg = \(ms) ms (non-authoritative; not the spec frame budget)")
        #expect(ms < 50)   // 极宽松上界，仅防病态退化（同既有 perfSmoke 量级）
    }

    // MARK: 顺位 3 D5：去硬编码 80（target = panelState.visibleCount，≤0 → fallback 80）

    /// 非 0 显式入参 + 80 golden parity（独立金值硬编码，R1-L3 防 tautology）
    @Test("D5 parity：visibleCount=80 显式入参 ≡ 旧 80 行为（金值：step=10/startIndex=71/count=80）")
    func explicitEightyMatchesGolden() {
        let ps = PanelViewState(period: .m3, interactionMode: .autoTracking,
                                visibleCount: 80, offset: 0, revision: 0)
        let vp = RenderStateBuilder.makeViewport(
            panelState: ps, candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 10) < 1e-9)   // 800/80（金值手算，非新公式推导）
        #expect(vp.startIndex == 71)                        // 150−79
        #expect(vp.visibleCount == 80)
        #expect(abs(vp.geometry.candleWidth - 7) < 1e-9)
    }

    @Test("D5 缩放生效：visibleCount=40 → step=20、startIndex=111（右锚 40 根）")
    func fortyVisible() {
        let ps = PanelViewState(period: .m3, interactionMode: .autoTracking,
                                visibleCount: 40, offset: 0, revision: 0)
        let vp = RenderStateBuilder.makeViewport(
            panelState: ps, candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 20) < 1e-9)   // 800/40
        #expect(vp.startIndex == 111)                       // 150−39
        #expect(vp.visibleCount == 40)
    }

    @Test("D5 放宽视野 + reveal：visibleCount=160、currentIdx=150 → 早 tick 左填充至 currentIdx+1")
    func oneSixtyVisibleSaturates() {
        let ps = PanelViewState(period: .m3, interactionMode: .freeScrolling,
                                visibleCount: 160, offset: 15, revision: 0)
        let vp = RenderStateBuilder.makeViewport(
            panelState: ps, candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 5) < 1e-9)    // 800/160
        // baseStart=150−159=−9 → upperBound=max(0,−9)=0；wholeShift=floor(15/5)=3 → −12 → clamp 0 → pixelShift=0
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
        #expect(vp.visibleCount == 151)    // reveal：sliceEnd=min(0+160, 150+1)=151，末根==currentIdx==150
    }

    @Test("D5 数据不足左对齐：count=100 < target=160 → visibleCount=100、分母仍 target（step=5）")
    func leftFillWhenDataShort() {
        let ps = PanelViewState(period: .m3, interactionMode: .autoTracking,
                                visibleCount: 160, offset: 0, revision: 0)
        let vp = RenderStateBuilder.makeViewport(
            panelState: ps, candles: Self.candles(period: .m3, count: 100),
            tick: 99, bounds: Self.bounds)
        #expect(vp.visibleCount == 100)
        #expect(abs(vp.geometry.candleStep - 5) < 1e-9)    // 800/160：分母 = target 非 count
        #expect(vp.startIndex == 0)
    }

    @Test("D5 fallback：visibleCount=0（旧构造）→ 80（既有 helper 兼容性显式断言）")
    func zeroFallsBackToEighty() {
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 10) < 1e-9)
        #expect(vp.visibleCount == 80)
    }

    // 端到端 focus 不变量（Plan-R2 PR2-01：从 Task 1 移此处——依赖去硬编码后 makeViewport honor visibleCount）。
    @Test("D5 端到端 focus：makeViewport 缩放前后 u(fx) 连续域 <1e-9 + 离散 candle 不变（fx 取 candle 中心）")
    func endToEndFocusInvariant() {
        let candles = Self.candles(period: .m3, count: 200)
        // freeScrolling offset=15：vpBefore startIndex=70/pixelShift=5/step=10（非饱和中段，R1-L4）
        var before = PanelViewState(period: .m3, interactionMode: .freeScrolling,
                                    visibleCount: 80, offset: 15, revision: 0)
        let vpBefore = RenderStateBuilder.makeViewport(panelState: before, candles: candles,
                                                       tick: 150, bounds: Self.bounds)
        let cIdx = RenderStateBuilder.currentCandleIndex(candles: candles, tick: 150)
        // fx = 第 40 个可见 slot 中心 x = 40·10 + 5 + 5 = 410；uBefore = 70 + (410−5)/10 = 110.5
        let fx: CGFloat = 410
        let uBefore = CGFloat(vpBefore.startIndex) + (fx - vpBefore.pixelShift) / vpBefore.geometry.candleStep
        let newCount = 40
        let newOffset = PinchZoomModel.rezoomOffset(viewport: vpBefore, currentIdx: cIdx,
                                                    focusX: fx, newCount: newCount, mainWidth: 800)
        before.visibleCount = newCount
        before.offset = newOffset
        let vpAfter = RenderStateBuilder.makeViewport(panelState: before, candles: candles,
                                                      tick: 150, bounds: Self.bounds)
        let uAfter = CGFloat(vpAfter.startIndex) + (fx - vpAfter.pixelShift) / vpAfter.geometry.candleStep
        #expect(abs(uAfter - uBefore) < 1e-9)          // uAfter = 90 + (410−0)/20 = 110.5
        let mBefore = CoordinateMapper(viewport: vpBefore, displayScale: 1)
        let mAfter = CoordinateMapper(viewport: vpAfter, displayScale: 1)
        #expect(mBefore.xToIndex(fx) == mAfter.xToIndex(fx))
    }

    // MARK: - Wave 3 顺位 4：panelPosition 过滤（横线只渲本面板）

    @Test("make: drawings 按 panelPosition 过滤 —— 上栏(0)在 .upper，下栏(1)被排除")
    @MainActor
    func drawingsFilteredByPanelPositionUpper() {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: 10)],
                                      isExtended: true, panelPosition: 0))    // 上栏
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: 11)],
                                      isExtended: true, panelPosition: 1))    // 下栏
        let rs = RenderStateBuilder.make(engine: e, panel: .upper,
                                         bounds: TrainingEngineInteractionTests.bounds)
        #expect(rs.drawings.count == 1)
        #expect(rs.drawings.allSatisfy { $0.panelPosition == 0 })            // 仅上栏；下栏被排除
    }

    @Test("make: drawings 按 panelPosition 过滤 —— 反之 .lower 仅含下栏(1)，上栏(0)被排除")
    @MainActor
    func drawingsFilteredByPanelPositionLower() {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: 10)],
                                      isExtended: true, panelPosition: 0))    // 上栏
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: 11)],
                                      isExtended: true, panelPosition: 1))    // 下栏
        let rs = RenderStateBuilder.make(engine: e, panel: .lower,
                                         bounds: TrainingEngineInteractionTests.bounds)
        #expect(rs.drawings.count == 1)
        #expect(rs.drawings.allSatisfy { $0.panelPosition == 1 })            // 仅下栏；上栏被排除
    }

    // MARK: - 聚合感知 reveal（进行中聚合 K 线 partial 合成；spec 2026-06-15-aggregate-aware-reveal）

    /// m60 上区 engine：m3 driving（12 根，datetime=i*180）+ m60 聚合（sparse ends [3,7,11]，datetime 对齐 m3）。
    @MainActor
    static func aggregateEngine(tick: Int, m60FutureHigh: Double = 9999) -> TrainingEngine {
        let m3 = (0..<12).map { i in
            KLineCandle(period: .m3, datetime: Int64(i) * 180, open: Double(i), high: Double(i) + 1,
                        low: Double(i) - 1, close: Double(i) + 0.5, volume: 100, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil, macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        func m60(_ dtIdx: Int, end: Int) -> KLineCandle {
            KLineCandle(period: .m60, datetime: Int64(dtIdx) * 180, open: 5, high: m60FutureHigh, low: -9999,
                        close: 5, volume: 999_999, amount: nil, ma66: 8, bollUpper: 8, bollMid: 8, bollLower: 8,
                        macdDiff: 8, macdDea: 8, macdBar: 8, globalIndex: nil, endGlobalIndex: end)
        }
        let m60s = [m60(0, end: 3), m60(4, end: 7), m60(8, end: 11)]
        return TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: 11),
            allCandles: [.m3: m3, .m60: m60s],
            maxTick: 11, initialTick: tick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m60, initialLowerPeriod: .m60,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
    }

    @MainActor
    @Test("聚合面板进行中根被 partial 合成：OHLC=partial、指标 nil、endGlobalIndex==tick（aggregate-leak 复现转正）")
    func aggregateInProgressSynthesized() {
        let e = Self.aggregateEngine(tick: 1)
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        let last = rs.visibleCandles.last!
        #expect(last.endGlobalIndex == 1)
        #expect(last.open == 0)
        #expect(last.high == 2)
        #expect(last.close == 1.5)
        #expect(last.ma66 == nil && last.macdDiff == nil)
    }

    @MainActor
    @Test("base 索引契约：合成后 visibleCandles.startIndex == viewport.startIndex（R1-H3）")
    func synthesisPreservesBaseIndex() {
        let e = Self.aggregateEngine(tick: 1)
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rs.visibleCandles.startIndex == rs.viewport.startIndex)
    }

    @MainActor
    @Test("Y 轴不泄漏：priceRange 只反映已揭示 partial，不含 vendor 未来 high（R1-H2）")
    func priceRangeExcludesFuture() {
        let e = Self.aggregateEngine(tick: 1, m60FutureHigh: 9999)
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rs.viewport.priceRange.max < 100)
    }

    @MainActor
    @Test("m3 驱动面板：currentIdx 那根 endGlobalIndex==tick → 不合成（原根原样）")
    func m3PanelNotSynthesized() {
        let m3 = (0..<200).map { i in
            KLineCandle(period: .m3, datetime: Int64(i) * 180, open: 10, high: 11, low: 9, close: 10 + Double(i) * 0.1,
                        volume: 1000, amount: nil, ma66: 7, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: i, endGlobalIndex: i)
        }
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: 199),
            allCandles: [.m3: m3], maxTick: 199, initialTick: 150,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        let last = rs.visibleCandles.last!
        #expect(last.endGlobalIndex == 150)
        #expect(last.ma66 == 7)
    }

    @MainActor
    @Test("无未来不变量：聚合面板所有可见根 endGlobalIndex ≤ tick")
    func allVisibleWithinTick() {
        for t in [0, 1, 3, 5, 9, 11] {
            let e = Self.aggregateEngine(tick: t)
            let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
            for c in rs.visibleCandles {
                #expect(c.endGlobalIndex <= t, "tick=\(t) 可见根 endGlobalIndex=\(c.endGlobalIndex) > tick")
            }
        }
    }

    @MainActor
    @Test("base 索引契约（强 fixture，startIndex>0）：非空泛守 R1-H3 + 合成值在非零 base 正确（final-review R1-H）")
    func synthesisPreservesBaseIndexNonZero() {
        // 100 根 m60（各跨 3 m3，end=3k+2）→ tick=271 时 currentIdx=90、startIndex=11>0；
        // 旧 fixture 仅 3 根 m60 → startIndex 恒 0 → 错误的 Array(candles[...]) 从 0 重索引也"通过"（vacuous）。
        // 本强 fixture 使 base 索引契约可被回归捕获（Array(...) 会令 startIndex 变 0 != 11）。
        let m3 = (0..<300).map { i in
            KLineCandle(period: .m3, datetime: Int64(i) * 180, open: Double(i), high: Double(i) + 1,
                        low: Double(i) - 1, close: Double(i) + 0.5, volume: 100, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil, macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        let m60 = (0..<100).map { k in
            KLineCandle(period: .m60, datetime: Int64(3 * k) * 180, open: 5, high: 9999, low: -9999,
                        close: 5, volume: 999_999, amount: nil, ma66: 8, bollUpper: 8, bollMid: 8, bollLower: 8,
                        macdDiff: 8, macdDea: 8, macdBar: 8, globalIndex: nil, endGlobalIndex: 3 * k + 2)
        }
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: 299),
            allCandles: [.m3: m3, .m60: m60], maxTick: 299, initialTick: 271,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m60, initialLowerPeriod: .m60,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rs.viewport.startIndex == 11)                            // 非零 base（vacuous 防回归前提）
        #expect(rs.visibleCandles.startIndex == rs.viewport.startIndex)  // base 索引契约（Array(...) 重索引会 fail）
        let last = rs.visibleCandles.last!
        #expect(last.endGlobalIndex == 271)                             // == tick（合成）
        #expect(last.open == 270)                                       // m3[270].open（合成 start=270）
        #expect(last.high == 272)                                       // max(m3[270,271].high)，非 vendor 9999
        #expect(last.close == 271.5)                                    // m3[271].close
        #expect(last.ma66 == nil)                                       // 指标 nil
    }

    @MainActor
    @Test("perf smoke（非权威）：大 in-progress 聚合面板 make() 装配开销（codex R3 全数组 COW 回归 guard）")
    func aggregateMakePerfSmoke() {
        // 大 m15 聚合（1000 根各跨 5 m3）+ 5000 m3，in-progress tick → 合成 fire。
        // 防 codex R3 全 period 数组 per-frame COW 回归（就地 slice 突变仅拷窗口 ≤80）。device Instruments 为权威。
        let m3 = (0..<5000).map { i in
            KLineCandle(period: .m3, datetime: Int64(i) * 180, open: Double(i), high: Double(i) + 1,
                        low: Double(i) - 1, close: Double(i) + 0.5, volume: 100, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil, macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        let m15 = (0..<1000).map { k in
            KLineCandle(period: .m15, datetime: Int64(5 * k) * 180, open: 5, high: 6, low: 4, close: 5,
                        volume: 1, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: nil, endGlobalIndex: 5 * k + 4)
        }
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: 4999),
            allCandles: [.m3: m3, .m15: m15], maxTick: 4999, initialTick: 2502,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m15, initialLowerPeriod: .m15,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        let probe = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(probe.visibleCandles.last!.endGlobalIndex == 2502)   // 确认合成 fire（in-progress）
        let start = Date()
        for _ in 0..<100 { _ = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds) }
        let ms = Date().timeIntervalSince(start) * 1000 / 100
        print("[aggregate-reveal perf smoke] make() avg = \(ms) ms (non-authoritative; device Instruments 权威)")
        #expect(ms < 50)   // 极宽松上界，仅防病态退化（就地 slice 突变下应远小于此）
    }

    // MARK: - reveal 约束（已揭示前缀窗口；spec §五）

    @Test("reveal 不变量扫描：跨 tick × offset，slice 末根 ≤ currentIdx 且 visibleCount ≥ 1（禁前窥）")
    func revealedPrefixInvariantScan() {
        let cs = Self.candles(period: .m3, count: 200)
        let ticks = [0, 5, 10, 40, 79, 80, 150, 199]
        let offsets: [CGFloat] = [0, 25, -25, 600, -600, 5000, -5000]
        for t in ticks {
            let currentIdx = RenderStateBuilder.currentCandleIndex(candles: cs, tick: t)
            for off in offsets {
                let vp = RenderStateBuilder.makeViewport(
                    panelState: Self.panel(offset: off), candles: cs, tick: t, bounds: Self.bounds)
                #expect(vp.visibleCount >= 1, "空切片 tick=\(t) offset=\(off)")
                #expect(vp.startIndex + vp.visibleCount - 1 <= currentIdx,
                        "前窥 tick=\(t) offset=\(off)：末根=\(vp.startIndex + vp.visibleCount - 1) > cIdx=\(currentIdx)")
            }
        }
    }

    @Test("reveal 前向滚动禁：任意负 offset → startIndex ≤ max(0, baseStartIndex)（不越 autoTracking）")
    func forwardScrollClampedToAutoTracking() {
        let cs = Self.candles(period: .m3, count: 200)
        let ticks = [10, 79, 150, 199]
        let negOffsets: [CGFloat] = [-5, -25, -200, -600, -5000]
        for t in ticks {
            let currentIdx = RenderStateBuilder.currentCandleIndex(candles: cs, tick: t)
            let cap = max(0, currentIdx - (min(80, cs.count) - 1))   // vc=80（panel visibleCount=0→fallback）
            for off in negOffsets {
                let vp = RenderStateBuilder.makeViewport(
                    panelState: Self.panel(offset: off), candles: cs, tick: t, bounds: Self.bounds)
                #expect(vp.startIndex <= cap, "前向越界 tick=\(t) offset=\(off)：si=\(vp.startIndex) > cap=\(cap)")
            }
        }
    }

    @Test("reveal 早 tick 修复：count=200/tick=10 → visibleCount==11、slice 末根==currentIdx==10（无未来）")
    func earlyTickRevealsOnlyRevealedPrefix() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 10, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.visibleCount == 11)
        #expect(vp.startIndex + vp.visibleCount - 1 == 10)   // 末根==currentIdx，无未来
    }

    @Test("reveal backward 历史：大正 offset → startIndex==0 + pixelShift==0（至最旧；regression 基准）")
    func backwardScrollReachesOldest() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 5000), candles: cs, tick: 150, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
    }
}
