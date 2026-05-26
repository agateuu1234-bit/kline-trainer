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

@Suite("MarkersLayout 哨兵契约")
struct MarkersSentinelTests {

    @Test("D2：findCandleIndex 等价 partitioningIndex（哨兵：禁止改换为 linear scan）")
    func equivalentToPartitioning() {
        let candles = [mc(0, endGlobal: 5), mc(1, endGlobal: 10),
                       mc(2, endGlobal: 15), mc(3, endGlobal: 20)]
        let slice = candles[0..<4]
        for gt in [1, 5, 6, 10, 15, 20, 21] {
            let marker = TradeMarker(globalTick: gt, price: 10, direction: .buy)
            let mine = MarkersLayout.findCandleIndex(for: marker, in: slice)
            let ref = slice.partitioningIndex { $0.endGlobalIndex >= gt }
            let expected: Int? = (ref < slice.endIndex) ? ref : nil
            #expect(mine == expected)
        }
    }

    @Test("D10：dot center.y 锚到 candle.close（不是 marker.price）—— 跨周期同步关键")
    func centerYAnchorsCandleClose() {
        let m = makeMapper(count: 2)
        // candle close = 80（priceToY = 600 - 80/100*600 = 120）；marker price = 30
        let candles = [mc(0, endGlobal: 5, close: 80), mc(1, endGlobal: 10, close: 80)]
        let markers = [TradeMarker(globalTick: 5, price: 30, direction: .buy)]
        let placements = MarkersLayout.markerPlacements(
            mapper: m, markers: markers, candles: candles[0..<2])
        #expect(placements.count == 1)
        #expect(placements[0].center.y == 120)  // priceToY(80)，不是 priceToY(30)=420
    }

    @Test("方向透传：buy/sell 不丢失（D10 后续 UIKit 据此选色 + 字母）")
    func directionPassthrough() {
        let m = makeMapper(count: 2)
        let candles = [mc(0, endGlobal: 5), mc(1, endGlobal: 10)]
        let markers = [TradeMarker(globalTick: 5,  price: 10, direction: .buy),
                       TradeMarker(globalTick: 10, price: 10, direction: .sell)]
        let placements = MarkersLayout.markerPlacements(
            mapper: m, markers: markers, candles: candles[0..<2])
        #expect(placements.map(\.direction) == [.buy, .sell])
    }

    @Test("R1 F8：startIndex≠0 slice 时 findCandleIndex 返回的是 slice 母数组 index 而非 0-based")
    func nonZeroSliceStartIndex() {
        // 母数组 6 根；slice 取 [2..<6]（startIndex=2）。
        let arr = [mc(0, endGlobal: 1),  mc(1, endGlobal: 3),
                   mc(2, endGlobal: 5),  mc(3, endGlobal: 10),
                   mc(4, endGlobal: 15), mc(5, endGlobal: 20)]
        let slice = arr[2..<6]  // startIndex=2, endIndex=6
        // globalTick=7：母数组 endGlobal[2,5]=5 不满足，[3,10]=10 满足 → 母数组 index 3。
        let m1 = TradeMarker(globalTick: 7, price: 10, direction: .buy)
        #expect(MarkersLayout.findCandleIndex(for: m1, in: slice) == 3)
        // globalTick=20：[5,20]=20 满足，首个 → 母数组 index 5。
        let m2 = TradeMarker(globalTick: 20, price: 10, direction: .sell)
        #expect(MarkersLayout.findCandleIndex(for: m2, in: slice) == 5)
        // 同样验 markerPlacements.candleIndex 用 slice 母数组 index（不是 0-based）。
        let placements = MarkersLayout.markerPlacements(
            mapper: makeMapper(startIndex: 2, count: 4),
            markers: [m1, m2], candles: slice)
        #expect(placements.count == 2)
        #expect(placements[0].candleIndex == 3)
        #expect(placements[1].candleIndex == 5)
    }
}
