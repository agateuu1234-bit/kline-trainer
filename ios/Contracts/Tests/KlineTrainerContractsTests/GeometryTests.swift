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
