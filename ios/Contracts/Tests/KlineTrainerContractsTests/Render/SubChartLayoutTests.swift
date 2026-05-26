// Kline Trainer Swift Contracts — C4 SubChartLayout host tests
// Spec: kline_trainer_modules_v1.4.md §C4 + plan 2026-05-26-pr-c4-volume-macd.md
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

// MARK: - 测试构造器
private func mc(_ index: Int,
               open: Double = 10, close: Double = 10,
               volume: Int64 = 100,
               macdDiff: Double? = nil, macdDea: Double? = nil, macdBar: Double? = nil) -> KLineCandle {
    KLineCandle(period: .m3, datetime: Int64(index),
                open: open, high: max(open, close), low: min(open, close), close: close,
                volume: volume, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: macdDiff, macdDea: macdDea, macdBar: macdBar,
                globalIndex: index, endGlobalIndex: index)
}

/// 干净取整的 IndicatorMapper for volume：step=10, width=6, scale=2, valueRange 0...1000, frame y∈[0,200]。
/// indexToX(startIndex + k) == k*10；valueToY(v) == 200 - v*0.2（v∈[0,1000]）。
private func makeVolumeMapper(startIndex: Int = 0, count: Int,
                              lower: Double = 0, upper: Double = 1000) -> IndicatorMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return IndicatorMapper(frame: CGRect(x: 0, y: 0, width: 1000, height: 200),
                           valueRange: NonDegenerateRange(lower: lower, upper: upper),
                           geometry: geom, viewport: vp, displayScale: 2)
}

/// 干净取整的 MACD mapper：valueRange -50...50（跨 0），frame y∈[0,200]。
/// valueToY(0) == 100；valueToY(50)==0；valueToY(-50)==200。
private func makeMacdMapper(startIndex: Int = 0, count: Int,
                            lower: Double = -50, upper: Double = 50) -> IndicatorMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return IndicatorMapper(frame: CGRect(x: 0, y: 0, width: 1000, height: 200),
                           valueRange: NonDegenerateRange(lower: lower, upper: upper),
                           geometry: geom, viewport: vp, displayScale: 2)
}

@Suite("SubChartLayout.volumeBars")
struct SubChartLayoutVolumeTests {

    @Test("涨蜡烛对应红柱：isUp=true，基线=frame.maxY，柱顶=valueToY(volume)")
    func upBar() {
        let candles = [mc(0, open: 10, close: 20, volume: 500)]
        let m = makeVolumeMapper(count: 1)
        let bars = SubChartLayout.volumeBars(for: candles[0..<1], mapper: m)
        #expect(bars.count == 1)
        let b = bars[0]
        #expect(b.isUp == true)
        #expect(b.rect.minX == -3)
        #expect(b.rect.width == 6)
        #expect(b.rect.minY == 100)
        #expect(b.rect.height == 100)
    }

    @Test("跌蜡烛对应绿柱：isUp=false")
    func downBar() {
        let candles = [mc(0, open: 20, close: 10, volume: 250)]
        let b = SubChartLayout.volumeBars(for: candles[0..<1], mapper: makeVolumeMapper(count: 1))[0]
        #expect(b.isUp == false)
        #expect(b.rect.minY == 150)
        #expect(b.rect.height == 50)
    }

    @Test("volume==0（停牌）柱高=1/displayScale 最小（D8）+ 中心契约 D5（M1）")
    func zeroVolumeMinHeight() {
        let candles = [mc(0, open: 10, close: 10, volume: 0)]
        let b = SubChartLayout.volumeBars(for: candles[0..<1], mapper: makeVolumeMapper(count: 1))[0]
        #expect(b.rect.minX == -3 && b.rect.width == 6)
        #expect(b.rect.height == 0.5)
    }

    @Test("lower>0：基线仍取 frame.maxY（=valueToY(lower)），不取 valueToY(0)（D10）+ M1 中心契约")
    func baselineFromLowerNotZero() {
        let candles = [mc(0, volume: 100)]
        let m = makeVolumeMapper(count: 1, lower: 100, upper: 1000)
        let b = SubChartLayout.volumeBars(for: candles[0..<1], mapper: m)[0]
        #expect(b.rect.minX == -3 && b.rect.width == 6)
        #expect(b.rect.height == 0.5)
        let b2 = SubChartLayout.volumeBars(for: [mc(1, volume: 1000)][0..<1], mapper: m)[0]
        #expect(b2.rect.minX == -3 && b2.rect.width == 6)
        #expect(b2.rect.height == 200)
        #expect(b2.rect.minY == 0)
    }

    @Test("D6 杀手：slice arr[2..<5] + startIndex=2 → 首根 midX==0（防 enumerated-offset bug）")
    func indexAlignment() {
        let arr = (0..<5).map { mc($0, volume: 100) }
        let m = makeVolumeMapper(startIndex: 2, count: 3)
        let bars = SubChartLayout.volumeBars(for: arr[2..<5], mapper: m)
        #expect(bars.count == 3)
        #expect(bars[0].rect.midX == 0)
        #expect(bars[1].rect.midX == 10)
        #expect(bars[2].rect.midX == 20)
    }
}

@Suite("SubChartLayout.macdLines")
struct SubChartLayoutMacdLinesTests {

    @Test("DIF 与 DEA 各自独立折线，warmup nil 跳过")
    func difDeaDistinctAndWarmup() {
        let arr = [mc(0),
                   mc(1, macdDiff: 20, macdDea: 10),
                   mc(2, macdDiff: -10, macdDea: 5),
                   mc(3, macdDiff: 30, macdDea: nil)]
        let m = makeMacdMapper(count: 4)
        let lines = SubChartLayout.macdLines(for: arr[0..<4], mapper: m)
        #expect(lines.dif.count == 1)
        #expect(lines.dif[0] == [CGPoint(x: 10, y: 60), CGPoint(x: 20, y: 120), CGPoint(x: 30, y: 40)])
        #expect(lines.dea.count == 1)
        #expect(lines.dea[0] == [CGPoint(x: 10, y: 80), CGPoint(x: 20, y: 90)])
    }

    @Test("内部 nil 断段（D9a 防御）")
    func internalGapSplits() {
        let arr = [mc(0, macdDiff: 10, macdDea: 5),
                   mc(1, macdDiff: 20, macdDea: 10),
                   mc(2),
                   mc(3, macdDiff: 30, macdDea: nil)]
        let lines = SubChartLayout.macdLines(for: arr[0..<4], mapper: makeMacdMapper(count: 4))
        #expect(lines.dif.count == 2)
        #expect(lines.dif[0].count == 2)
        #expect(lines.dif[1].count == 1)
    }

    @Test("全 nil → 两轨皆空")
    func allNil() {
        let arr = [mc(0), mc(1)]
        let lines = SubChartLayout.macdLines(for: arr[0..<2], mapper: makeMacdMapper(count: 2))
        #expect(lines.dif.isEmpty && lines.dea.isEmpty)
    }

    @Test("D6 杀手：slice arr[2..<5] + startIndex=2 → 首点 x==0")
    func indexAlignment() {
        let arr = (0..<5).map { mc($0, macdDiff: 0, macdDea: 0) }
        let m = makeMacdMapper(startIndex: 2, count: 3)
        let lines = SubChartLayout.macdLines(for: arr[2..<5], mapper: m)
        #expect(lines.dif.count == 1)
        #expect(lines.dif[0].map(\.x) == [0, 10, 20])
        #expect(lines.dif[0].allSatisfy { $0.y == 100 })
    }
}
