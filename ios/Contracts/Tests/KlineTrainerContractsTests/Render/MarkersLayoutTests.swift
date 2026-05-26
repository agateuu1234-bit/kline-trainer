// Kline Trainer Swift Contracts — C5 MarkersLayout host tests
// Spec: kline_trainer_modules_v1.4.md §C5 L1298-1313 + plan v1.5 §4.3 L753-771
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func mc(_ idx: Int, endGlobal: Int, close: Double = 10) -> KLineCandle {
    KLineCandle(period: .m3, datetime: Int64(idx),
                open: close, high: close + 1, low: close - 1, close: close,
                volume: 100, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: idx, endGlobalIndex: endGlobal)
}

private func makeMapper(startIndex: Int = 0, count: Int = 5) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return CoordinateMapper(viewport: vp, displayScale: 2)
}

@Suite("MarkersLayout.findCandleIndex")
struct FindCandleIndexTests {

    @Test("精确命中：endGlobalIndex == globalTick → 返回该 index")
    func exactHit() {
        // candles: endGlobal = [5, 10, 15, 20]
        let candles = [mc(0, endGlobal: 5),  mc(1, endGlobal: 10),
                       mc(2, endGlobal: 15), mc(3, endGlobal: 20)]
        let marker = TradeMarker(globalTick: 10, price: 10, direction: .buy)
        #expect(MarkersLayout.findCandleIndex(for: marker, in: candles[0..<4]) == 1)
    }

    @Test("首根满足谓词：endGlobalIndex >= globalTick 取最小 index（spec L1310 字面）")
    func firstSatisfying() {
        let candles = [mc(0, endGlobal: 5),  mc(1, endGlobal: 10),
                       mc(2, endGlobal: 15), mc(3, endGlobal: 20)]
        // globalTick = 7：endGlobal=5 不满足，endGlobal=10 满足 → index 1
        let marker = TradeMarker(globalTick: 7, price: 10, direction: .buy)
        #expect(MarkersLayout.findCandleIndex(for: marker, in: candles[0..<4]) == 1)
    }

    @Test("超出最大 endGlobalIndex → nil（找不到，跳过该 marker per D9）")
    func beyondMax() {
        let candles = [mc(0, endGlobal: 5), mc(1, endGlobal: 10)]
        let marker = TradeMarker(globalTick: 100, price: 10, direction: .sell)
        #expect(MarkersLayout.findCandleIndex(for: marker, in: candles[0..<2]) == nil)
    }

    @Test("空 slice → nil")
    func empty() {
        let candles: [KLineCandle] = []
        let marker = TradeMarker(globalTick: 5, price: 10, direction: .buy)
        #expect(MarkersLayout.findCandleIndex(for: marker, in: candles[0..<0]) == nil)
    }
}

@Suite("MarkersLayout.markerPlacements")
struct MarkerPlacementsTests {

    @Test("D10：dot center = (indexToX(idx), priceToY(candle.close))；direction 透传")
    func dotCenter() {
        let m = makeMapper(count: 4)
        // close = 50 → priceToY = 600 - 50/100*600 = 300
        let candles = [mc(0, endGlobal: 5,  close: 50),
                       mc(1, endGlobal: 10, close: 50),
                       mc(2, endGlobal: 15, close: 50),
                       mc(3, endGlobal: 20, close: 50)]
        let markers = [TradeMarker(globalTick: 10, price: 51, direction: .buy)]
        let placements = MarkersLayout.markerPlacements(
            mapper: m, markers: markers, candles: candles[0..<4])
        #expect(placements.count == 1)
        #expect(placements[0].center == CGPoint(x: 10, y: 300))  // indexToX(1)=10
        #expect(placements[0].direction == .buy)
        #expect(placements[0].candleIndex == 1)
    }

    @Test("D9：marker 越界（globalTick > 所有 endGlobalIndex） → 跳过，placements 不含该项")
    func skipOutOfRange() {
        let m = makeMapper(count: 2)
        let candles = [mc(0, endGlobal: 5), mc(1, endGlobal: 10)]
        let markers = [TradeMarker(globalTick: 7,   price: 10, direction: .buy),   // 命中 idx 1
                       TradeMarker(globalTick: 100, price: 10, direction: .sell)]  // 跳过
        let placements = MarkersLayout.markerPlacements(
            mapper: m, markers: markers, candles: candles[0..<2])
        #expect(placements.count == 1)
        #expect(placements[0].direction == .buy)
    }
}
