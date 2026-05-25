// Kline Trainer Swift Contracts — C3 MainChartLayout host tests
// Spec: kline_trainer_modules_v1.4.md §C3 + plan 2026-05-25-pr-c3-candles-ma66-boll.md
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

// MARK: - 测试构造器
private func mc(_ index: Int,
               open: Double = 10, high: Double = 11, low: Double = 9, close: Double = 10,
               ma66: Double? = nil,
               bollUpper: Double? = nil, bollMid: Double? = nil, bollLower: Double? = nil) -> KLineCandle {
    KLineCandle(period: .m3, datetime: Int64(index),
                open: open, high: high, low: low, close: close,
                volume: 0, amount: nil, ma66: ma66,
                bollUpper: bollUpper, bollMid: bollMid, bollLower: bollLower,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: index, endGlobalIndex: index)
}

/// 干净取整的 mapper：step=10, width=6, scale=2, price 0...100, frame 0,0,1000,600。
/// indexToX(startIndex + k) == k*10；priceToY(p) == 600 - p*6（p∈[0,100]）。
private func makeMapper(startIndex: Int = 0, count: Int) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return CoordinateMapper(viewport: vp, displayScale: 2)
}

@Suite("MainChartLayout.candleShapes")
struct MainChartLayoutCandleTests {

    @Test("涨蜡烛：isUp=true，实体顶=priceToY(close)，影线 cx 居中")
    func upCandle() {
        let candles = [mc(0, open: 10, high: 25, low: 5, close: 20)]
        let m = makeMapper(count: 1)
        let shapes = MainChartLayout.candleShapes(for: candles[0..<1], mapper: m)
        #expect(shapes.count == 1)
        let s = shapes[0]
        #expect(s.isUp == true)
        #expect(s.bodyRect.minX == -3)
        #expect(s.bodyRect.width == 6)
        #expect(s.bodyRect.minY == 480)
        #expect(s.bodyRect.height == 60)
        #expect(s.wickTop == CGPoint(x: 0, y: 450))
        #expect(s.wickBottom == CGPoint(x: 0, y: 570))
    }

    @Test("跌蜡烛：isUp=false")
    func downCandle() {
        let candles = [mc(0, open: 20, high: 25, low: 5, close: 10)]
        let s = MainChartLayout.candleShapes(for: candles[0..<1], mapper: makeMapper(count: 1))[0]
        #expect(s.isUp == false)
        #expect(s.bodyRect.minY == 480)
        #expect(s.bodyRect.height == 60)
    }

    @Test("平盘 doji：实体高度=1/displayScale（最小 1 设备像素）")
    func dojiMinBody() {
        let candles = [mc(0, open: 10, high: 12, low: 8, close: 10)]
        let s = MainChartLayout.candleShapes(for: candles[0..<1], mapper: makeMapper(count: 1))[0]
        #expect(s.isUp == true)
        #expect(s.bodyRect.height == 0.5)
    }

    @Test("slice 起始下标对齐 viewport.startIndex（第二根 x=10）")
    func indexAlignment() {
        let arr = [mc(0), mc(1, open: 10, close: 20)]
        let m = makeMapper(startIndex: 0, count: 2)
        let shapes = MainChartLayout.candleShapes(for: arr[0..<2], mapper: m)
        #expect(shapes[1].bodyRect.midX == 10)
    }
}

@Suite("MainChartLayout.ma66Polyline")
struct MainChartLayoutMA66Tests {

    @Test("leading nil 跳过：前两根 nil，后三根连成一段")
    func leadingNilSkipped() {
        let arr = [mc(0), mc(1), mc(2, ma66: 50), mc(3, ma66: 60), mc(4, ma66: 40)]
        let segs = MainChartLayout.ma66Polyline(for: arr[0..<5], mapper: makeMapper(count: 5))
        #expect(segs.count == 1)
        #expect(segs[0] == [CGPoint(x: 20, y: 300), CGPoint(x: 30, y: 240), CGPoint(x: 40, y: 360)])
    }

    @Test("内部 nil 断线分两段（D9 防御）")
    func internalGapSplits() {
        let arr = [mc(0, ma66: 50), mc(1, ma66: 60), mc(2), mc(3, ma66: 40)]
        let segs = MainChartLayout.ma66Polyline(for: arr[0..<4], mapper: makeMapper(count: 4))
        #expect(segs.count == 2)
        #expect(segs[0].count == 2)
        #expect(segs[1].count == 1)
    }

    @Test("全 nil → 空")
    func allNil() {
        let arr = [mc(0), mc(1)]
        #expect(MainChartLayout.ma66Polyline(for: arr[0..<2], mapper: makeMapper(count: 2)).isEmpty)
    }
}

@Suite("MainChartLayout.bollPolylines")
struct MainChartLayoutBollTests {

    @Test("三轨各取对应 keypath（用不同值区分上中下）")
    func threeBandsDistinct() {
        let arr = [mc(0, bollUpper: 80, bollMid: 50, bollLower: 20),
                   mc(1, bollUpper: 90, bollMid: 60, bollLower: 30)]
        let b = MainChartLayout.bollPolylines(for: arr[0..<2], mapper: makeMapper(count: 2))
        #expect(b.upper.count == 1 && b.mid.count == 1 && b.lower.count == 1)
        #expect(b.upper[0][0] == CGPoint(x: 0, y: 120))
        #expect(b.mid[0][0]   == CGPoint(x: 0, y: 300))
        #expect(b.lower[0][0] == CGPoint(x: 0, y: 480))
    }

    @Test("warmup：某轨 nil 段被跳过，不连跨 gap")
    func warmupNilPerBand() {
        let arr = [mc(0), mc(1, bollUpper: 90, bollMid: 60, bollLower: 30)]
        let b = MainChartLayout.bollPolylines(for: arr[0..<2], mapper: makeMapper(count: 2))
        #expect(b.upper == [[CGPoint(x: 10, y: 60)]])
        #expect(b.mid.count == 1 && b.lower.count == 1)
    }

    @Test("全 nil → 三轨皆空")
    func allNil() {
        let arr = [mc(0), mc(1)]
        let b = MainChartLayout.bollPolylines(for: arr[0..<2], mapper: makeMapper(count: 2))
        #expect(b.upper.isEmpty && b.mid.isEmpty && b.lower.isEmpty)
    }

    @Test("D3：dashPattern 段长 = 4/displayScale（虚线参数 host 可测，H1 修订）")
    func dashPatternValue() {
        #expect(MainChartLayout.dashPattern(displayScale: 2) == [2, 2])
        #expect(MainChartLayout.dashPattern(displayScale: 1) == [4, 4])
    }
}

@Suite("MainChartLayout 索引契约（D6 杀手测试：startIndex≠0）")
struct MainChartLayoutIndexTests {

    @Test("candleShapes：slice arr[2..<5] + startIndex=2 → 首根 midX==0")
    func candleStartIndexOffset() {
        let arr = (0..<5).map { mc($0, open: 10, close: 20) }
        let m = makeMapper(startIndex: 2, count: 3)
        let shapes = MainChartLayout.candleShapes(for: arr[2..<5], mapper: m)
        #expect(shapes.count == 3)
        #expect(shapes[0].bodyRect.midX == 0)
        #expect(shapes[1].bodyRect.midX == 10)
        #expect(shapes[2].bodyRect.midX == 20)
    }

    @Test("ma66Polyline：slice arr[2..<5] + startIndex=2 → 首点 x==0")
    func ma66StartIndexOffset() {
        let arr = (0..<5).map { mc($0, ma66: 50) }
        let m = makeMapper(startIndex: 2, count: 3)
        let segs = MainChartLayout.ma66Polyline(for: arr[2..<5], mapper: m)
        #expect(segs.count == 1)
        #expect(segs[0].map(\.x) == [0, 10, 20])
    }
}
