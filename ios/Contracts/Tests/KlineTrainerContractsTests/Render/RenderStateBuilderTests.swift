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

    @Test("最老边 overscroll（R1b-wire B4，P7 变更）：offset 顶过 maxOffset → startIndex==0 + pixelShift==offset−maxOffset")
    func saturateLeftClamped() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 750), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=75 → unclamped=71-75=-4 → clamp 0；offset 750 > maxOffset 710 → B4 overscroll 间隙（旧为 pin 0）。
        // P7：drag 经 B3 full-clamp 后 ≤maxOffset 不可达此态；offset>maxOffset 仅来自 bounce → B4 单边渲间隙。
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 40)   // 750 − 710（最老边 overscroll）
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

    @Test("最老边恰过界（R1b-wire B4，P7 变更）：offset=715>maxOffset → startIndex==0 + pixelShift==5")
    func saturateLeftExactBoundary() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 715), candles: cs, tick: 150, bounds: Self.bounds)
        // wholeShift=71 → unclamped=71-71=0（==下界，clamp 不改）；offset 715 > maxOffset 710 → B4 overscroll 5（旧为 pin 0）。
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 5)   // 715 − 710
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

    // MARK: - W3-11-R1a：geometryCore 共享几何内核（行为中性抽取）

    @Test("geometryCore（reveal D5）：count=200/currentIdx=150/width=800/rawVisible=0→80 → base=71,upper=71,step=10,vc=80")
    func geometryCore_known() {
        let core = RenderStateBuilder.geometryCore(
            mainFrameWidth: ChartPanelFrames.split(in: Self.bounds).mainChart.width,
            rawVisible: 0, candleCount: 200, currentIdx: 150)
        #expect(core.visibleCount == 80)
        #expect(core.candleStep == 10)          // 800/80
        #expect(core.baseStartIndex == 71)      // 150 − 79
        #expect(core.upperBound == 71)          // reveal RFC：max(0, baseStartIndex)=max(0,71)（禁前窥；非旧 count−vc=120）
    }

    @Test("offsetBounds（reveal D5）：count=200/currentIdx=150/width=800 → max=710,min=0,step=10")
    func offsetBounds_known() {
        let b = RenderStateBuilder.offsetBounds(
            mainFrameWidth: ChartPanelFrames.split(in: Self.bounds).mainChart.width,
            rawVisible: 0, candleCount: 200, currentIdx: 150)
        #expect(b.maxOffset == 710)     // baseStartIndex 71 · step 10（最老边）
        #expect(b.minOffset == 0)       // reveal D5：最新边 = 当前 tick（offset 0），前向不可越（禁前窥）
        #expect(b.candleStep == 10)
        #expect(b.bounceEdges == [.max])   // codex R3：有滚动空间 → 仅最老边可弹（.min 硬钳不在内）
    }

    // D4 行为对拍（opus M4 + R1-Low1/Low2，reveal D5 更新）：把 offsetBounds 算出的 edge-offset 喂回 makeViewport，
    // 须落到 render 边缘且 pixelShift==0，证 bounds 与 render clamp 同源。
    // 双侧锚（Low1）：max 是 startIndex==0 的**确切下确界**——max−step 时 startIndex 须 ==1（未到最老边）；
    //                min(=0, reveal 最新边)是 startIndex==upperBound 的**确切上确界**——min+step（朝更老）时 startIndex 须 ==upperBound−1。
    // currentIdx 显式锚（Low2）：钉死「offsetBounds 字面入参 currentIdx」== makeViewport 的 tick→currentIdx，防同向漂移。
    @Test("offsetBounds 行为对拍（reveal D5）：maxOffset→startIndex==0 pin / minOffset(0)→upperBound pin / 双侧确界 + currentIdx 同源")
    func offsetBounds_matchesRenderClamp() {
        let cs = Self.candles(period: .m3, count: 200)
        #expect(RenderStateBuilder.currentCandleIndex(candles: cs, tick: 150) == 150)  // Low2：钉死前提同源
        let b = RenderStateBuilder.offsetBounds(
            mainFrameWidth: ChartPanelFrames.split(in: Self.bounds).mainChart.width,
            rawVisible: 0, candleCount: 200, currentIdx: 150)
        let atMax = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: b.maxOffset), candles: cs, tick: 150, bounds: Self.bounds)
        #expect(atMax.startIndex == 0)          // 最老边
        #expect(atMax.pixelShift == 0)          // 边缘 pin
        // Low1 对侧锚：max−step 未到边 → startIndex==1（证 maxOffset 是 startIndex==0 的确切下确界，非任意大值）
        let belowMax = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: b.maxOffset - b.candleStep), candles: cs, tick: 150, bounds: Self.bounds)
        #expect(belowMax.startIndex == 1)
        let atMin = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: b.minOffset), candles: cs, tick: 150, bounds: Self.bounds)
        #expect(atMin.startIndex == 71)         // reveal D5：upperBound==max(0,base)==71（最新边=当前 tick），非旧 120
        #expect(atMin.pixelShift == 0)
        // Low1 对侧锚：min+step（朝更老）未到最新边 → startIndex==70（=upperBound−1，确切上确界）
        let aboveMin = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: b.minOffset + b.candleStep), candles: cs, tick: 150, bounds: Self.bounds)
        #expect(aboveMin.startIndex == 70)
    }

    // codex R2（branch-diff）：offsetBounds.minOffset==0 是 reveal **硬钳**（最新边=当前 tick），**非对称弹簧边**。
    // R1b-wire 若把最新边当 EdgeBounceModel 对称弹簧端点 + 负速 fling → 会 spring offset below 0 = 前向揭示。
    // 本测证 **R1a render 层已兜底**：即便 caller 喂 offset 低于 minOffset（负，模拟该误用），makeViewport 仍把 startIndex
    // 钳在 upperBound、pixelShift==0、slice 末根==currentIdx（无前向揭示）。R1b-wire 据此把最新边实现为硬钳（spec §六 B4 NOTE）。
    @Test("offsetBounds.minOffset 是 reveal 硬钳非弹簧：offset 低于 minOffset → makeViewport 钳最新边、无前向揭示（codex R2）")
    func offsetBounds_minOffsetIsHardClampNotSpring() {
        let cs = Self.candles(period: .m3, count: 200)
        let b = RenderStateBuilder.offsetBounds(
            mainFrameWidth: ChartPanelFrames.split(in: Self.bounds).mainChart.width,
            rawVisible: 0, candleCount: 200, currentIdx: 150)
        #expect(b.minOffset == 0)
        let currentIdx = RenderStateBuilder.currentCandleIndex(candles: cs, tick: 150)   // 150
        // 喂 offset 远低于 minOffset（负=前向/朝新）：R1b 误把最新边当弹簧 + 负速会产生此类 offset。
        for belowMin in [b.minOffset - b.candleStep, b.minOffset - 100, CGFloat(-1000)] {
            let vp = RenderStateBuilder.makeViewport(
                panelState: Self.panel(offset: belowMin), candles: cs, tick: 150, bounds: Self.bounds)
            #expect(vp.startIndex == 71, "belowMin=\(belowMin) 钳最新边 upperBound==71")
            #expect(vp.pixelShift == 0, "belowMin=\(belowMin) 边缘 pin（无前向间隙，非 overscroll gap）")
            #expect(vp.startIndex + vp.visibleCount - 1 <= currentIdx, "belowMin=\(belowMin) slice 末根 ≤ currentIdx（无未来）")
        }
    }

    // codex R3：bounceEdges **类型级**不变量——`.min` 永不在 bounceEdges（最新边硬钳），且 `[.max]` iff 有滚动空间（max>min）。
    // 扫 tick × vc 钉死单边 bounce 策略由返回类型编码（R1b 读 bounceEdges 即不会误把最新边当弹簧）。
    @Test("offsetBounds.bounceEdges 不变量（codex R3）：.min 永不可弹（硬钳）+ [.max] iff 有滚动空间")
    func offsetBounds_bounceEdgesAsymmetryInvariant() {
        let w = ChartPanelFrames.split(in: Self.bounds).mainChart.width
        for tickIdx in [0, 5, 79, 80, 150, 199] {
            for vc in [0, 40, 80, 160] {
                let b = RenderStateBuilder.offsetBounds(mainFrameWidth: w, rawVisible: vc,
                                                        candleCount: 200, currentIdx: tickIdx)
                #expect(!b.bounceEdges.contains(.min), "tick=\(tickIdx) vc=\(vc)：.min 永不可弹（最新边硬钳）")
                let hasRoom = b.maxOffset > b.minOffset
                #expect(b.bounceEdges == (hasRoom ? [.max] : []), "tick=\(tickIdx) vc=\(vc)：[.max] iff 有滚动空间")
            }
        }
    }

    @Test("offsetBounds 退化：count<=visibleCount(无滚动空间) → upperBound==0, min/max 同号无区间")
    func offsetBounds_degenerate() {
        // count=30 < target=80 → visibleCount=min(80,30)=30, step=10; currentIdx=29(最新根) → baseStartIndex=29-29=0
        // reveal upperBound=max(0, baseStartIndex=0)=0（无滚动空间）→ max=0, min=0（单点，无 overscroll 空间）
        let b = RenderStateBuilder.offsetBounds(
            mainFrameWidth: ChartPanelFrames.split(in: Self.bounds).mainChart.width,
            rawVisible: 0, candleCount: 30, currentIdx: 29)
        #expect(b.maxOffset == 0)
        #expect(b.minOffset == 0)
        #expect(b.candleStep == 10)
        #expect(b.bounceEdges.isEmpty)   // codex R3：无滚动空间 → 无边可弹
    }

    // codex R3（branch-diff）：空 candle（candleCount==0 → visibleCount==0）须退化 [0,0]，**不依赖 caller 传的 currentIdx**。
    // 旧洞：count=0 → visibleCount=0 → baseStartIndex=currentIdx−(0−1)=currentIdx+1；哨兵 currentIdx=0 → upperBound=max(0,1)=1>0
    // 漏过守卫 → maxOffset=roundTripEdge(1)=step（伪非零）。修：offsetBounds 守卫加 visibleCount>0。
    @Test("offsetBounds 空 candle 退化（codex R3）：candleCount==0 → [0,0]，任意 currentIdx 哨兵（含 0）不漏")
    func offsetBounds_emptyCandlesDegenerate() {
        let w = ChartPanelFrames.split(in: Self.bounds).mainChart.width
        for sentinelIdx in [-1, 0, 5, 100] {
            let b = RenderStateBuilder.offsetBounds(mainFrameWidth: w, rawVisible: 0,
                                                    candleCount: 0, currentIdx: sentinelIdx)
            #expect(b.minOffset == 0, "currentIdx=\(sentinelIdx) empty → minOffset 0")
            #expect(b.maxOffset == 0, "currentIdx=\(sentinelIdx) empty → maxOffset 0")
            #expect(b.bounceEdges.isEmpty, "currentIdx=\(sentinelIdx) empty → 无边可弹")
        }
    }

    // reveal D5：早 tick currentIdx=10 → baseStartIndex=10−79=−69 → upperBound=max(0,−69)=0 → offsetBounds=[0,0]
    // （无滚动空间：已显最旧 candles[0..]，前向不可越 currentIdx=禁前窥）。区别于旧 true-motion-range [-1890,-690]（codex R2-H 旧解，reveal 后失效）。
    @Test("offsetBounds 早 tick（reveal D5）：base<0 → [0,0]（无滚动空间，已显最旧+禁前窥），任意 offset 仍 clamp 到 autoTracking")
    func offsetBounds_earlyTickNoScrollRoom() {
        let w = ChartPanelFrames.split(in: Self.bounds).mainChart.width
        let b = RenderStateBuilder.offsetBounds(mainFrameWidth: w, rawVisible: 0, candleCount: 200, currentIdx: 10)
        #expect(b.maxOffset == 0)           // base<0 → upperBound 守卫返单点 [0,0]（**reveal-upperBound 判别在此**：
        #expect(b.minOffset == 0)           //   mutation upperBound 退回 count−vc → max/min≠0 被抓，见 Stage2 review）
        #expect(b.candleStep == 10)
        #expect(b.bounceEdges.isEmpty)      // codex R3：早 tick 无滚动空间 → 无边可弹
        // no-OOB smoke（**非** reveal-upperBound 判别——早 tick 下 startIndex 的 max(…,0) 下界 clamp 先于 upperBound 生效）：
        // 正 offset（朝更老，已最旧）/负 offset（朝新，禁前窥）喂回 makeViewport 都落 autoTracking startIndex==0 且不 OOB。
        let cs = Self.candles(period: .m3, count: 200)
        let pos = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 100), candles: cs, tick: 10, bounds: Self.bounds)
        #expect(pos.startIndex == 0)
        let neg = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -100), candles: cs, tick: 10, bounds: Self.bounds)
        #expect(neg.startIndex == 0)
    }

    // reveal D5：span == upperBound·step == max(0, baseStartIndex)·step（早 tick base<0 → span 0；中/晚 tick 渐增）。
    // 不再是与 tick 无关的常数（旧 true-motion-range，codex R2-H 旧解）——upperBound 现随 tick 变（=max(0,base)）。
    @Test("offsetBounds span==upperBound·step（reveal D5：tick 10/150/199 → span 0/710/1200）")
    func offsetBounds_spanEqualsUpperBoundStep() {
        let w = ChartPanelFrames.split(in: Self.bounds).mainChart.width
        let cases: [(tick: Int, span: CGFloat)] = [(10, 0), (150, 710), (199, 1200)]
        for c in cases {
            let b = RenderStateBuilder.offsetBounds(mainFrameWidth: w, rawVisible: 0,
                                                    candleCount: 200, currentIdx: c.tick)
            let upperBound = CGFloat(max(0, c.tick - 79))   // vc=80, base=tick−79
            #expect(b.maxOffset - b.minOffset == upperBound * 10, "tick=\(c.tick) span==upperBound·step")
            #expect(b.maxOffset - b.minOffset == c.span, "tick=\(c.tick) 金值 span")
        }
    }

    // codex R2-M：非有限几何（inf/NaN width → 非有限 step）→ 安全退化 [0,0]，roundTripEdge 不 Int(NaN/inf) trap。
    @Test("offsetBounds 非有限几何安全退化（codex R2-M）：inf/NaN width → [0,0] 不 trap")
    func offsetBounds_nonFiniteGeometrySafe() {
        let bInf = RenderStateBuilder.offsetBounds(mainFrameWidth: .infinity, rawVisible: 0, candleCount: 200, currentIdx: 150)
        #expect(bInf.minOffset == 0 && bInf.maxOffset == 0)
        #expect(bInf.candleStep == 0)   // R1a code-quality Minor1：非有限 step 净化为 0（钉死 safeStep 分支，防 inf/NaN 泄入）
        let bNaN = RenderStateBuilder.offsetBounds(mainFrameWidth: .nan, rawVisible: 0, candleCount: 200, currentIdx: 150)
        #expect(bNaN.minOffset == 0 && bNaN.maxOffset == 0)
        #expect(bNaN.candleStep == 0)   // 同上：NaN step → 0
        // roundTripEdge 喂非有限 step 不 trap（命中 :107 early guard 返 integer·step；内层 q.isFinite 守是 belt-and-suspenders）
        _ = RenderStateBuilder.roundTripEdge(integer: 71, step: .infinity)
        _ = RenderStateBuilder.roundTripEdge(integer: 71, step: .nan)
        #expect(Bool(true))   // 到达此行即证未 trap
    }

    // codex R1-M：非整除 step（width/vc 不整除）下 edge=integer·step 经 makeViewport plain floor 反算可偏 1；
    // roundTripEdge verify-and-correct 钉死：喂 maxOffset/minOffset 回 makeViewport 精确落边 + pixelShift==0。
    @Test("offsetBounds 非整除 step round-trip：vc 20...120 × width=1000 → edge 精确反算落边 pin")
    func offsetBounds_roundTripNonIntegral() {
        let cs = Self.candles(period: .m3, count: 300)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)   // 1000/vc 多数非整除
        let w = ChartPanelFrames.split(in: bounds).mainChart.width
        for vc in 20...120 {
            let b = RenderStateBuilder.offsetBounds(mainFrameWidth: w, rawVisible: vc,
                                                    candleCount: 300, currentIdx: 200)
            let pMax = PanelViewState(period: .m3, interactionMode: .autoTracking,
                                      visibleCount: vc, offset: b.maxOffset, revision: 0)
            let vpMax = RenderStateBuilder.makeViewport(panelState: pMax, candles: cs, tick: 200, bounds: bounds)
            if b.maxOffset > 0 {
                #expect(vpMax.startIndex == 0, "vc=\(vc) maxOffset round-trip→startIndex 0")
                #expect(vpMax.pixelShift == 0, "vc=\(vc) maxOffset pixelShift pin")
            }
            // reveal D5：minOffset 恒 0（vc 20...120 → base=201−vc>0 → minOffset=roundTripEdge(0)=0）；
            // 喂回落 autoTracking 锚 startIndex==baseStartIndex==201−vc（==upperBound），pin。
            let pMin = PanelViewState(period: .m3, interactionMode: .autoTracking,
                                      visibleCount: vc, offset: b.minOffset, revision: 0)
            let vpMin = RenderStateBuilder.makeViewport(panelState: pMin, candles: cs, tick: 200, bounds: bounds)
            #expect(b.minOffset == 0, "vc=\(vc) reveal minOffset==0")
            #expect(vpMin.startIndex == 201 - vc, "vc=\(vc) minOffset(0)→autoTracking 锚")
            #expect(vpMin.pixelShift == 0, "vc=\(vc) minOffset pixelShift pin")
        }
    }

    // MARK: R1b-wire B4 — makeViewport 单边 overscroll（spec §四）
    // 最老边 offset>maxOffset → pixelShift==offset−maxOffset（左露间隙）；最新边/早 tick 硬钉 pixelShift==0。
    // 唯一行为新增 = b4OverscrollOldestEdge（其余 4 条为 interior/边缘/早tick/最新边回归守卫，改动前后皆绿）。

    @Test("B4 overscroll：offset>maxOffset（最老边）→ startIndex==0 + pixelShift==offset−maxOffset")
    func b4OverscrollOldestEdge() {
        let w = ChartPanelFrames.split(in: Self.bounds).mainChart.width
        let b = RenderStateBuilder.offsetBounds(mainFrameWidth: w, rawVisible: 0, candleCount: 200, currentIdx: 150)
        let overshoot: CGFloat = 23
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: b.maxOffset + overshoot),
            candles: Self.candles(period: .m3, count: 200), tick: 150, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(abs(vp.pixelShift - overshoot) < 1e-6)   // 完整 overscroll（可 > candleStep）
        #expect(vp.visibleCount > 0)                      // slice 非空、无 OOB
    }

    @Test("B4 最老边钉：offset==maxOffset → startIndex==0 + pixelShift==0")
    func b4OldestEdgePinned() {
        let w = ChartPanelFrames.split(in: Self.bounds).mainChart.width
        let b = RenderStateBuilder.offsetBounds(mainFrameWidth: w, rawVisible: 0, candleCount: 200, currentIdx: 150)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: b.maxOffset),
            candles: Self.candles(period: .m3, count: 200), tick: 150, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
    }

    @Test("B4 内段回归：offset∈(0,maxOffset) → wholeShift+余量 逐字不变")
    func b4InteriorUnchanged() {
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 35),
            candles: Self.candles(period: .m3, count: 200), tick: 150, bounds: Self.bounds)
        let step = vp.geometry.candleStep
        let wholeShift = Int((35 / step).rounded(.down))
        #expect(vp.startIndex == min(max(71 - wholeShift, 0), 71))   // base=71,upper=71 → 68（内段）
        #expect(abs(vp.pixelShift - (35 - CGFloat(wholeShift) * step)) < 1e-6)
    }

    @Test("B4 早 tick upperBound==0：任意大 offset → pixelShift==0（硬钉，不入 overscroll 分支）")
    func b4EarlyTickPinned() {
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 500),
            candles: Self.candles(period: .m3, count: 200), tick: 10, bounds: Self.bounds)
        #expect(vp.startIndex == 0)     // upperBound==0（base=10−79<0）
        #expect(vp.pixelShift == 0)     // 硬钉，未误入 overscroll
    }

    @Test("B4 最新边（upperBound>0）：offset<0 → startIndex==upperBound + pixelShift==0（reveal 硬钉，回归断言）")
    func b4NewestEdgePinnedWithScrollSpace() {
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -50),
            candles: Self.candles(period: .m3, count: 200), tick: 150, bounds: Self.bounds)
        #expect(vp.startIndex == 71)    // upperBound（base=71）
        #expect(vp.pixelShift == 0)     // 最新边硬钉，无前向间隙
    }

    // R1b-wire T2：offsetBounds(engine:panel:bounds:) 便捷重载 == 直接 extraction（D1 Coordinator 喂 bounds）。
    @Test("offsetBounds(engine:panel:bounds:) 重载 == 直接 extraction（M4 raw visibleCount）")
    @MainActor func offsetBoundsEngineOverload() {
        let (engine, _) = TrainingEnginePinchTests.engine()          // 真实 helper（count 200, .m3 双面板, bounds 已记录）
        let bounds = TrainingEnginePinchTests.bounds                  // 800×600
        let got = RenderStateBuilder.offsetBounds(engine: engine, panel: .upper, bounds: bounds)
        let cs = engine.allCandles[.m3]!
        let mainW = ChartPanelFrames.split(in: bounds).mainChart.width
        let want = RenderStateBuilder.offsetBounds(
            mainFrameWidth: mainW, rawVisible: engine.upperPanel.visibleCount,
            candleCount: cs.count,
            currentIdx: RenderStateBuilder.currentCandleIndex(candles: cs, tick: engine.tick.globalTickIndex))
        #expect(got == want)
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

    // MARK: - review-redesign Task 3：画线逐 tick 揭示（迁移自 codex whole-branch R4-F1；
    // 判据从「锚点 candleIndex ≤ 面板 currentCandleIndex」改为「revealTick ≤ 全局 tick」）。

    @Test("迁移自 R4-F1：未来 revealTick 画线在低 tick 被隐藏，tick 步进越过后揭示（锚点 candleIndex 与渐显解耦）")
    @MainActor
    func drawingsRevealByTick_futureRevealTickHiddenUntilStepped() {
        // Engine with 50 m3 candles (endGlobalIndex==i), starting at tick=5.
        let candles = Self.candles(period: .m3, count: 50)
        let maxTick = candles.count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: maxTick),
            allCandles: [.m3: candles],
            maxTick: maxTick,
            initialTick: 5,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        // Drawing A: revealTick=3（已到达，3 ≤ 当前 tick 5）→ 必须显现——锚点故意给「未来」candleIndex=8
        // 证明渐显不再看锚点。
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 8, price: 10)],
                                      isExtended: true, panelPosition: 0, revealTick: 3))
        // Drawing B: revealTick=8（未来，8 > 当前 tick 5）→ tick=5 时必须隐藏——锚点故意给「过去」candleIndex=3
        // 证明若仍按旧锚点判据这条本该显现，而新判据下必须隐藏。
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 3, price: 11)],
                                      isExtended: true, panelPosition: 0, revealTick: 8))

        // RED assertion (before advancing): only revealTick=3 的画线可见。
        let rsAtTick5 = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rsAtTick5.drawings.count == 1)
        #expect(rsAtTick5.drawings.allSatisfy { $0.revealTick == 3 })

        // Advance tick past revealTick=8: call holdOrObserve 5× (tick 5→6→7→8→9→10).
        for _ in 0..<5 { e.holdOrObserve(panel: .upper) }
        #expect(e.tick.globalTickIndex == 10)   // revealTick=8 ≤ 10

        // GREEN assertion (after advancing): both drawings now visible.
        let rsAtTick10 = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rsAtTick10.drawings.count == 2)
    }

    // MARK: - review-redesign Task 10：engine.reviewDrawings 两层叠加（review 模式专属）

    @Test("Task 10（迁移自 R4-F1 判据）：review 模式 drawings = engine.drawings(只读原训练) + engine.reviewDrawings，按 revealTick 各自渐显叠加")
    @MainActor
    func reviewOverlayDrawingsRevealByTick() throws {
        // Review engine：50 根 m3（endGlobalIndex==i），起始 tick=5。
        let candles = Self.candles(period: .m3, count: 50)
        let maxTick = candles.count - 1
        let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let record = TrainingRecord(id: 1, trainingSetFilename: "t.sqlite", createdAt: 0,
                                    stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 1,
                                    totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                                    buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: maxTick)
        let e = TrainingEngine(
            flow: ReviewFlow(record: record, startTick: 0),
            allCandles: [.m3: candles],
            maxTick: maxTick,
            initialTick: 5,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        // 原训练线（只读 engine.drawings）revealTick=2（过去，2<=5）→ 显现——锚点故意给「未来」candleIndex=8。
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 8, price: 10)],
                                      isExtended: true, panelPosition: 0, revealTick: 2))
        // 复盘新画线（engine.reviewDrawings）revealTick=8（未来，8>5，tick=5 时不应显示）——锚点故意给「过去」candleIndex=2。
        try e.setReviewDrawings([DrawingObject(toolType: .horizontal,
                                           anchors: [DrawingAnchor(period: .m3, candleIndex: 2, price: 11)],
                                           isExtended: true, panelPosition: 0, revealTick: 8)])

        // tick=5：只含原训练线（复盘线 revealTick=8 未揭示）。
        let rsAtTick5 = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rsAtTick5.drawings.count == 1)
        #expect(rsAtTick5.drawings.allSatisfy { $0.revealTick == 2 })

        // 步进到 tick=10（越过 revealTick=8）。
        for _ in 0..<5 { e.holdOrObserve(panel: .upper) }
        #expect(e.tick.globalTickIndex == 10)

        // tick=10：两条都显（原训练线 + 复盘线）。
        let rsAtTick10 = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rsAtTick10.drawings.count == 2)
    }

    @Test("Task 10：非 review 模式（normal/replay）drawings 恒不叠加 reviewDrawings")
    @MainActor
    func nonReviewModeIgnoresReviewDrawings() {
        let (e, _) = TrainingEngineInteractionTests.engine()   // NormalFlow
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: 10)],
                                      isExtended: true, panelPosition: 0))
        e.setReviewDrawingsForTesting([DrawingObject(toolType: .horizontal,
                                       anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: 11)],
                                       isExtended: true, panelPosition: 0)])
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: TrainingEngineInteractionTests.bounds)
        #expect(rs.drawings.count == 1)   // reviewDrawings 未叠加（非 review 模式）
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

    // MARK: - review-redesign Task 3：渐显改按 revealTick（创建时全局 tick），与锚点 candleIndex 解耦

    /// 单一 .m3 双面板 engine（NormalFlow，起始 tick=0）+ 一条画线：revealTick/panelPosition/锚点
    /// candleIndex 独立可控——用于证明渐显只认 `revealTick`，与锚点、面板自身 period 均无关。
    @MainActor
    static func makeEngineWithDrawing(revealTick: Int, panelPosition: Int, anchorCandleIndex: Int) -> TrainingEngine {
        let candles = Self.candles(period: .m3, count: 200)
        let maxTick = candles.count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: maxTick),
            allCandles: [.m3: candles],
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: anchorCandleIndex, price: 10)],
                                      isExtended: true, panelPosition: panelPosition, revealTick: revealTick))
        return e
    }

    /// engine 逐 tick 步进到目标 tick（NormalFlow 下 `holdOrObserve` 每次 +1）。
    @MainActor
    static func step(_ engine: TrainingEngine, toTick target: Int) {
        while engine.tick.globalTickIndex < target { engine.holdOrObserve(panel: .upper) }
    }

    @Test("revealTick 渐显：tick 未到 revealTick 前隐藏，到达后显现（与锚点 candleIndex 无关）")
    @MainActor
    func drawingReveal_byRevealTick_hiddenBeforeCreationTick() {
        let engine = Self.makeEngineWithDrawing(revealTick: 100, panelPosition: 0, anchorCandleIndex: 0)
        Self.step(engine, toTick: 99)
        let s99 = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        #expect(s99.drawings.isEmpty)              // revealTick 100 > 99：隐藏（即便锚 candleIndex=0）
        Self.step(engine, toTick: 100)
        let s100 = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        #expect(s100.drawings.count == 1)          // revealTick 100 <= 100：显现
    }

    @Test("下栏画线按全局 revealTick 显现（不依赖面板自身 period 的 currentCandleIndex）")
    @MainActor
    func drawingReveal_lowerPanel_crossPeriod_byGlobalRevealTick() {
        let engine = Self.makeEngineWithDrawing(revealTick: 100, panelPosition: 1, anchorCandleIndex: 0)  // 下栏
        Self.step(engine, toTick: 100)
        let up = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        let low = RenderStateBuilder.make(engine: engine, panel: .lower, bounds: Self.bounds)
        #expect(up.drawings.isEmpty)               // panelPosition=1 不进上栏
        #expect(low.drawings.count == 1)           // 进下栏，按全局 revealTick 显现
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

    @Test("reveal backward 历史 + B4 overscroll（P7 变更）：大正 offset(5000)>maxOffset → startIndex==0 + pixelShift==4290")
    func backwardScrollReachesOldest() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 5000), candles: cs, tick: 150, bounds: Self.bounds)
        // offset 5000 > maxOffset 710 → B4 最老边 overscroll 4290（旧为 pin 0；drag B3-clamp 后不可达，仅 bounce）。
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 4290)   // 5000 − 710
    }

    // MARK: - D29：周期绑定渲染过滤 + upper==lower fail-safe（1a-i Task 6）

    @Test("D29：按 period 落面板，panelPosition 不再影响")
    func filtersByPeriodNotPanelPosition() {
        let d = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .m60, candleIndex: 0, price: 1)],
                              isExtended: false, panelPosition: 1, period: .m60)   // period=.m60 但 panelPosition=1（冲突）
        #expect(RenderStateBuilder.belongsToPanel(d, panel: .upper, upperPeriod: .m60, lowerPeriod: .m15) == true)
        #expect(RenderStateBuilder.belongsToPanel(d, panel: .lower, upperPeriod: .m60, lowerPeriod: .m15) == false)
    }
    @Test("D29：某 period 不在任一面板 → 两面板都不含")
    func periodNotShownHiddenBoth() {
        let d = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .weekly, candleIndex: 0, price: 1)],
                              isExtended: false, panelPosition: 0, period: .weekly)
        for p in [PanelId.upper, .lower] {
            #expect(RenderStateBuilder.belongsToPanel(d, panel: p, upperPeriod: .m60, lowerPeriod: .m15) == false)
        }
    }
    @Test("D29 fail-safe：upper==lower==线period → 只落 panelPosition 指定的那个面板")
    func failSafeSamePeriodSinglePanel() {
        let up0 = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .m60, candleIndex: 0, price: 1)],
                                isExtended: false, panelPosition: 0, period: .m60)
        let low1 = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .m60, candleIndex: 0, price: 1)],
                                 isExtended: false, panelPosition: 1, period: .m60)
        #expect(RenderStateBuilder.belongsToPanel(up0, panel: .upper, upperPeriod: .m60, lowerPeriod: .m60) == true)
        #expect(RenderStateBuilder.belongsToPanel(up0, panel: .lower, upperPeriod: .m60, lowerPeriod: .m60) == false)
        #expect(RenderStateBuilder.belongsToPanel(low1, panel: .upper, upperPeriod: .m60, lowerPeriod: .m60) == false)
        #expect(RenderStateBuilder.belongsToPanel(low1, panel: .lower, upperPeriod: .m60, lowerPeriod: .m60) == true)
    }
    @Test("D29 fail-safe：upper==lower 但 ≠ 线period → 两面板都 false（period 先于 panelPosition，codex plan-high）")
    func failSafeWrongPeriodExcludedBoth() {
        // 两面板都 .m60，一条 .weekly 线 panelPosition=0：period 不符，绝不能被 panelPosition 硬塞进 .m60 面板
        let wk = DrawingObject(toolType: .horizontal, anchors: [DrawingAnchor(period: .weekly, candleIndex: 0, price: 1)],
                               isExtended: false, panelPosition: 0, period: .weekly)
        #expect(RenderStateBuilder.belongsToPanel(wk, panel: .upper, upperPeriod: .m60, lowerPeriod: .m60) == false)
        #expect(RenderStateBuilder.belongsToPanel(wk, panel: .lower, upperPeriod: .m60, lowerPeriod: .m60) == false)
    }

    @MainActor
    @Test("D29 集成：make 两层（drawings/reviewDrawings）都按面板 period 路由——preview(.review) upper=.m60/lower=.daily 不同周期，非 fail-safe")
    func makeRoutesBothLayersByPanelPeriod() {
        let engine = TrainingEngine.preview(mode: .review)
        // engine.upperPanel.period == .m60、engine.lowerPanel.period == .daily（真实 period 路由，非 upper==lower fail-safe）
        engine.appendDrawing(DrawingObject(toolType: .horizontal,
                                           anchors: [DrawingAnchor(period: .m60, candleIndex: 0, price: 10)],
                                           isExtended: false, panelPosition: 0, period: .m60))
        engine.appendReviewDrawing(DrawingObject(toolType: .horizontal,
                                                 anchors: [DrawingAnchor(period: .daily, candleIndex: 0, price: 11)],
                                                 isExtended: false, panelPosition: 0, period: .daily))
        let rs = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
        #expect(rs.drawings.count == 1)
        #expect(rs.drawings.allSatisfy { $0.period == .m60 })
    }
}

// MARK: - RFC-C Task 6: previousCloseBeforeVisible helper

@Suite("RenderStateBuilder.previousCloseBeforeVisible")
struct PrevCloseBeforeVisibleTests {
    private func cs(_ closes: [Double]) -> [KLineCandle] {
        closes.enumerated().map { i, c in
            KLineCandle(period: .m3, datetime: Int64(1_735_689_600 + i * 180),
                        open: c, high: c + 1, low: c - 1, close: c,
                        volume: 100, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
    }
    @Test("startIndex>0 → 前一根收盘；startIndex==0 → nil")
    func prevClose() {
        let arr = cs([10, 20, 30, 40, 50])
        #expect(RenderStateBuilder.previousCloseBeforeVisible(candles: arr, startIndex: 3) == 30)
        #expect(RenderStateBuilder.previousCloseBeforeVisible(candles: arr, startIndex: 0) == nil)
    }
}
