import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("ChartGeometry")
struct ChartGeometryTests {

    @Test("init + Equatable auto-synth")
    func initAndEquatable() {
        let a = ChartGeometry(candleStep: 8, candleWidth: 6, gap: 2)
        let b = ChartGeometry(candleStep: 8, candleWidth: 6, gap: 2)
        let c = ChartGeometry(candleStep: 9, candleWidth: 6, gap: 2)
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("ChartPanelFrames")
struct ChartPanelFramesTests {

    @Test("split 60/15/25 比例 + 顺序堆叠")
    func splitProportions() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let f = ChartPanelFrames.split(in: rect)
        #expect(f.mainChart.height == 600)
        #expect(f.volumeChart.height == 150)
        #expect(f.macdChart.height == 250)
        #expect(f.mainChart.minY == 0)
        #expect(f.volumeChart.minY == 600)
        #expect(f.macdChart.minY == 750)
    }

    @Test("非零 origin 保持偏移")
    func splitNonZeroOrigin() {
        let rect = CGRect(x: 50, y: 100, width: 400, height: 1000)
        let f = ChartPanelFrames.split(in: rect)
        #expect(f.mainChart.minX == 50)
        #expect(f.volumeChart.minX == 50)
        #expect(f.mainChart.minY == 100)
        #expect(f.volumeChart.minY == 700)
    }

    @Test("0 高度 rect 全部子 frame 高度为 0")
    func splitZeroHeight() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 0)
        let f = ChartPanelFrames.split(in: rect)
        #expect(f.mainChart.height == 0)
        #expect(f.volumeChart.height == 0)
        #expect(f.macdChart.height == 0)
    }
}

@Suite("NonDegenerateRange")
struct NonDegenerateRangeTests {

    @Test("empty values → fallback")
    func emptyFallback() {
        let r = NonDegenerateRange.make(values: [])
        #expect(r.lower == 0.0)
        #expect(r.upper == 1.0)
        #expect(r.span == 1.0)
        #expect(r.span > 0)
    }

    @Test("全等值 → 对称 ±pad")
    func equalValues() {
        let r = NonDegenerateRange.make(values: [10.0, 10.0, 10.0])
        #expect(r.lower < 10.0)
        #expect(r.upper > 10.0)
        #expect(r.span > 0)
    }

    @Test("普通 values → span * paddingRatio pad")
    func normalSpanPad() {
        let r = NonDegenerateRange.make(values: [0.0, 100.0])
        let span = 100.0
        let pad = span * 0.02
        #expect(r.lower == -pad)
        #expect(r.upper == 100.0 + pad)
        #expect(r.span > 0)
    }

    @Test("non-default paddingRatio honored")
    func customPaddingRatio() {
        let r = NonDegenerateRange.make(values: [0.0, 100.0], paddingRatio: 0.10)
        let pad = 100.0 * 0.10
        #expect(r.lower == -pad)
        #expect(r.upper == 100.0 + pad)
        #expect(r.span > 0)
    }

    @Test("non-default fallback honored")
    func customFallback() {
        let r = NonDegenerateRange.make(values: [], fallback: -10.0...20.0)
        #expect(r.lower == -10.0)
        #expect(r.upper == 20.0)
        #expect(r.span > 0)
    }

    @Test("全 0 单值 → 1e-6 padding 兜底（防 abs(0)*ratio = 0 退化）")
    func zeroValueFallbackPad() {
        let r = NonDegenerateRange.make(values: [0.0])
        #expect(r.lower < 0.0)
        #expect(r.upper > 0.0)
        #expect(r.span > 0)
        #expect(r.span >= 2e-6)   // pad = 1e-6 on each side → total span = 2e-6
    }
}

// MARK: - Helper for PriceRange tests

private func makeCandle(low: Double, high: Double,
                       bollUpper: Double? = nil, bollLower: Double? = nil,
                       ma66: Double? = nil) -> KLineCandle {
    KLineCandle(
        period: .m15, datetime: 0,
        open: low, high: high, low: low, close: high,
        volume: 0, amount: nil, ma66: ma66,
        bollUpper: bollUpper, bollMid: nil, bollLower: bollLower,
        macdDiff: nil, macdDea: nil, macdBar: nil,
        globalIndex: nil, endGlobalIndex: 0
    )
}

@Suite("PriceRange")
struct PriceRangeTests {

    @Test("empty candles → (0, 1)")
    func emptyFallback() {
        let empty: ArraySlice<KLineCandle> = []
        let r = PriceRange.calculate(from: empty)
        #expect(r.min == 0.0)
        #expect(r.max == 1.0)
    }

    @Test("普通 candles 仅 high/low → ±5% padding")
    func plainHighLow() {
        let candles = [makeCandle(low: 100, high: 200)]
        let r = PriceRange.calculate(from: candles[...])
        #expect(r.min == 100.0 * 0.95)
        #expect(r.max == 200.0 * 1.05)
    }

    @Test("含 bollUpper 扩 hi")
    func includesBollUpper() {
        let candles = [makeCandle(low: 100, high: 200, bollUpper: 250)]
        let r = PriceRange.calculate(from: candles[...])
        #expect(r.max == 250.0 * 1.05)
        #expect(r.min == 100.0 * 0.95)
    }

    @Test("含 bollLower 扩 lo")
    func includesBollLower() {
        let candles = [makeCandle(low: 100, high: 200, bollLower: 80)]
        let r = PriceRange.calculate(from: candles[...])
        #expect(r.min == 80.0 * 0.95)
        #expect(r.max == 200.0 * 1.05)
    }

    @Test("含 ma66 同时扩 lo/hi")
    func includesMA66() {
        let candlesHi = [makeCandle(low: 100, high: 200, ma66: 250)]
        let r1 = PriceRange.calculate(from: candlesHi[...])
        #expect(r1.max == 250.0 * 1.05)
        #expect(r1.min == 100.0 * 0.95)   // 抢答：ma66 仅扩 hi 时 lo 不应被污染

        let candlesLo = [makeCandle(low: 100, high: 200, ma66: 50)]
        let r2 = PriceRange.calculate(from: candlesLo[...])
        #expect(r2.min == 50.0 * 0.95)
        #expect(r2.max == 200.0 * 1.05)   // 抢答：ma66 仅扩 lo 时 hi 不应被污染
    }

    @Test("三指标全有 + 同时扩 lo/hi（reviewer test-1）")
    func allThreeIndicators() {
        let candles = [makeCandle(low: 100, high: 200, bollUpper: 240, bollLower: 90, ma66: 250)]
        let r = PriceRange.calculate(from: candles[...])
        // hi: bollUpper=240 < ma66=250 → 250 wins
        // lo: bollLower=90 < low=100 → 90 wins
        #expect(r.max == 250.0 * 1.05)
        #expect(r.min == 90.0 * 0.95)
    }

    @Test("单根 candle 全 nil 指标 → 仅 high/low ±5%")
    func singleCandleNoIndicators() {
        let candles = [makeCandle(low: 50, high: 60)]
        let r = PriceRange.calculate(from: candles[...])
        #expect(r.min == 50.0 * 0.95)
        #expect(r.max == 60.0 * 1.05)
    }
}

@Suite("ChartViewport")
struct ChartViewportTests {

    private func makeViewport(startIndex: Int = 0, mainChartFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 600)) -> ChartViewport {
        ChartViewport(
            startIndex: startIndex,
            visibleCount: 100,
            pixelShift: 0,
            geometry: ChartGeometry(candleStep: 8, candleWidth: 6, gap: 2),
            priceRange: PriceRange(min: 100, max: 200),
            mainChartFrame: mainChartFrame
        )
    }

    @Test("init 6 字段全保留")
    func initFields() {
        let v = makeViewport(startIndex: 50)
        #expect(v.startIndex == 50)
        #expect(v.visibleCount == 100)
        #expect(v.pixelShift == 0)
        #expect(v.geometry.candleStep == 8)
        #expect(v.priceRange.min == 100)
        #expect(v.mainChartFrame.width == 400)
    }

    @Test("Equatable 同字段 ==")
    func equatableSame() {
        let a = makeViewport()
        let b = makeViewport()
        #expect(a == b)
    }

    @Test("Equatable 跨 frame 不同 !=")
    func equatableDifferentFrame() {
        let a = makeViewport(mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let b = makeViewport(mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(a != b)
    }
}

@Suite("CoordinateMapper")
struct CoordinateMapperTests {

    private func makeMapper(displayScale: CGFloat = 2,
                           startIndex: Int = 0,
                           candleStep: CGFloat = 8,
                           mainChartFrame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 600),
                           priceMin: Double = 100, priceMax: Double = 200) -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(
                startIndex: startIndex, visibleCount: 100, pixelShift: 0,
                geometry: ChartGeometry(candleStep: candleStep, candleWidth: 6, gap: 2),
                priceRange: PriceRange(min: priceMin, max: priceMax),
                mainChartFrame: mainChartFrame
            ),
            displayScale: displayScale
        )
    }

    @Test("indexToX 起点 = 0")
    func indexToXStart() {
        let m = makeMapper(displayScale: 1, startIndex: 0)
        #expect(m.indexToX(0) == 0)
    }

    @Test("indexToX 偏移 N step")
    func indexToXOffset() {
        let m = makeMapper(displayScale: 1, startIndex: 0, candleStep: 8)
        #expect(m.indexToX(10) == 80)
    }

    @Test("priceToY 上界 priceMax → frame.minY")
    func priceToYUpper() {
        let m = makeMapper(priceMin: 100, priceMax: 200)
        // ratio = 1 → raw = maxY - height = 0
        #expect(m.priceToY(200) == 0)
    }

    @Test("priceToY 下界 priceMin → frame.maxY")
    func priceToYLower() {
        let m = makeMapper(mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 600),
                          priceMin: 100, priceMax: 200)
        // ratio = 0 → raw = maxY = 600
        #expect(m.priceToY(100) == 600)
    }

    @Test("priceToY 退化 PriceRange(min==max) → NaN（document residual #10 R1 抢答）")
    func priceToYDegenerateRange() {
        // PriceRange.init 不强制 min < max；calculate 路径天然不退化，
        // 但 caller 直接 init 传 min==max 时 (price-min)/0 = NaN，最终输出 NaN。
        // 此 test 显式 character 此行为，抢答 codex push "为啥 PriceRange.init 不验证"。
        // 归 caller side（residual #10）；不加 precondition。
        let m = makeMapper(priceMin: 100, priceMax: 100)
        #expect(m.priceToY(100).isNaN)
    }

    @Test("xToIndex floor 行为（向 -∞ 取整）")
    func xToIndexFloor() {
        let m = makeMapper(startIndex: 0, candleStep: 8)
        #expect(m.xToIndex(0) == 0)
        #expect(m.xToIndex(7.9) == 0)         // floor(7.9/8) = 0
        #expect(m.xToIndex(8) == 1)
        #expect(m.xToIndex(15.9) == 1)        // floor(15.9/8) = 1
    }

    @Test("yToPrice 反向 priceToY")
    func yToPriceInverse() {
        let m = makeMapper(mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 600),
                          priceMin: 100, priceMax: 200)
        let y = m.priceToY(150)
        let price = m.yToPrice(y)
        #expect(abs(price - 150) < 0.01)
    }

    @Test("sub-pixel scale=1 不改变整数 raw")
    func subPixelScale1() {
        let m = makeMapper(displayScale: 1, startIndex: 0, candleStep: 8)
        // raw = 80 → 80 * 1 = 80 → rounded(80) / 1 = 80
        #expect(m.indexToX(10) == 80)
    }

    @Test("sub-pixel scale=2 raw=0.25 → 0.5（.toNearestOrAwayFromZero 抢答 banker's drift, reviewer test-3）")
    func subPixelScale2HalfBoundary() {
        // raw = candleStep * (1 - 0) = 0.25; raw * scale = 0.5
        // .toNearestOrAwayFromZero(0.5) = 1.0 → 1.0 / 2 = 0.5
        // .rounded() (banker's = .toNearestOrEven) would give 0 → 0/2 = 0 (drift)
        // 此 test 验证选 .toNearestOrAwayFromZero 而非默认 banker's
        let m = makeMapper(displayScale: 2, startIndex: 0, candleStep: 0.25)
        #expect(m.indexToX(1) == 0.5)
    }

    @Test("sub-pixel scale=3 不同于 scale=1")
    func subPixelScale3() {
        let m1 = makeMapper(displayScale: 1, startIndex: 0, candleStep: 0.4)
        let m3 = makeMapper(displayScale: 3, startIndex: 0, candleStep: 0.4)
        // m1: raw = 0.4 → rounded(0.4) = 0 → 0/1 = 0
        // m3: raw = 0.4 → 0.4*3 = 1.2 → rounded(1.2) = 1 → 1/3 ≈ 0.333
        #expect(m1.indexToX(1) == 0)
        #expect(abs(m3.indexToX(1) - (1.0/3.0)) < 1e-9)
    }
}

@Suite("IndicatorMapper")
struct IndicatorMapperTests {

    private func makeViewport(candleStep: CGFloat = 8, startIndex: Int = 0) -> ChartViewport {
        ChartViewport(
            startIndex: startIndex, visibleCount: 100, pixelShift: 0,
            geometry: ChartGeometry(candleStep: candleStep, candleWidth: 6, gap: 2),
            priceRange: PriceRange(min: 100, max: 200),
            mainChartFrame: CGRect(x: 0, y: 0, width: 400, height: 600)
        )
    }

    private func makeMapper(displayScale: CGFloat = 2,
                           candleStep: CGFloat = 8,
                           startIndex: Int = 0,
                           valueRange: NonDegenerateRange = .make(values: [0, 100]),
                           frame: CGRect = CGRect(x: 0, y: 600, width: 400, height: 150)) -> IndicatorMapper {
        let v = makeViewport(candleStep: candleStep, startIndex: startIndex)
        return IndicatorMapper(
            frame: frame,
            valueRange: valueRange,
            geometry: v.geometry,
            viewport: v,
            displayScale: displayScale
        )
    }

    @Test("indexToX(i) === CoordinateMapper.indexToX(i) 共享 viewport/scale/geometry（reviewer test-2）")
    func indexToXConsistent() {
        let v = makeViewport(candleStep: 8, startIndex: 0)
        let coord = CoordinateMapper(viewport: v, displayScale: 2)
        let ind = IndicatorMapper(
            frame: CGRect(x: 0, y: 600, width: 400, height: 150),
            valueRange: .make(values: [0, 100]),
            geometry: v.geometry,
            viewport: v,
            displayScale: 2
        )
        for i in [0, 1, 5, 10, 50] {
            #expect(coord.indexToX(i) == ind.indexToX(i))
        }
    }

    @Test("valueToY 上界 valueRange.upper → frame.minY")
    func valueToYUpper() {
        let r = NonDegenerateRange.make(values: [0, 100])
        let m = makeMapper(valueRange: r, frame: CGRect(x: 0, y: 600, width: 400, height: 150))
        // ratio = 1 → raw = maxY - height = 600
        #expect(m.valueToY(r.upper) == 600)
    }

    @Test("valueToY 下界 valueRange.lower → frame.maxY")
    func valueToYLower() {
        let r = NonDegenerateRange.make(values: [0, 100])
        let m = makeMapper(valueRange: r, frame: CGRect(x: 0, y: 600, width: 400, height: 150))
        // ratio = 0 → raw = maxY = 750
        #expect(m.valueToY(r.lower) == 750)
    }

    @Test("sub-pixel rounding 与 CoordinateMapper 同 rule")
    func subPixelConsistent() {
        let m = makeMapper(displayScale: 3, candleStep: 0.4)
        // raw = 0.4 * 3 = 1.2 → .toNearestOrAwayFromZero(1.2) = 1.0 → 1/3
        #expect(abs(m.indexToX(1) - (1.0/3.0)) < 1e-9)
    }

    @Test("valueRange.span > 0 不除零（.make 任何分支 post-condition）")
    func spanNonZero() {
        let m1 = makeMapper(valueRange: .make(values: []))            // empty fallback
        let m2 = makeMapper(valueRange: .make(values: [42, 42, 42]))  // 全等值
        let m3 = makeMapper(valueRange: .make(values: [0]))           // 单 0 值
        // 都不应崩；valueToY 任何输入应产生有限 CGFloat
        #expect(m1.valueToY(0).isFinite)
        #expect(m2.valueToY(42).isFinite)
        #expect(m3.valueToY(0).isFinite)
    }
}
