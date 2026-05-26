// Kline Trainer Swift Contracts — C5 CrosshairLayout host tests
// Spec: kline_trainer_modules_v1.4.md §C5 + plan 2026-05-26-pr-c5-crosshair-markers.md
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func mc(_ idx: Int, datetime: Int64, close: Double = 10) -> KLineCandle {
    KLineCandle(period: .m3, datetime: datetime,
                open: close, high: close + 1, low: close - 1, close: close,
                volume: 100, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: idx, endGlobalIndex: idx)
}

private func makeMapper(startIndex: Int = 0, count: Int = 10) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return CoordinateMapper(viewport: vp, displayScale: 2)
}

@Suite("CrosshairLayout.lines")
struct CrosshairLinesTests {

    @Test("frame 内点：横线 y = point.y、竖线 x = point.x，两线跨 frame 全宽全高")
    func basic() {
        let m = makeMapper()
        let lines = CrosshairLayout.lines(at: CGPoint(x: 250, y: 300), mapper: m)
        #expect(lines != nil)
        guard let lines else { return }
        #expect(lines.horizontal.from == CGPoint(x: 0, y: 300))
        #expect(lines.horizontal.to   == CGPoint(x: 1000, y: 300))
        #expect(lines.vertical.from   == CGPoint(x: 250, y: 0))
        #expect(lines.vertical.to     == CGPoint(x: 250, y: 600))
    }

    @Test("frame 外点（x 越界）：lines == nil")
    func outsideX() {
        let m = makeMapper()
        #expect(CrosshairLayout.lines(at: CGPoint(x: -1, y: 300), mapper: m) == nil)
        #expect(CrosshairLayout.lines(at: CGPoint(x: 1001, y: 300), mapper: m) == nil)
    }

    @Test("frame 外点（y 越界）：lines == nil")
    func outsideY() {
        let m = makeMapper()
        #expect(CrosshairLayout.lines(at: CGPoint(x: 250, y: -1), mapper: m) == nil)
        #expect(CrosshairLayout.lines(at: CGPoint(x: 250, y: 601), mapper: m) == nil)
    }
}

@Suite("CrosshairLayout.priceLabel / timeLabel")
struct CrosshairLabelTests {

    @Test("priceLabel：价 = mapper.yToPrice(point.y) 2 位小数；rect.right=frame.maxX；rect.center.y=point.y")
    func priceLabelBasic() {
        let m = makeMapper()
        // point.y=300 → yToPrice = 100 - 300/600 * 100 = 50.00
        let label = CrosshairLayout.priceLabel(at: CGPoint(x: 250, y: 300), mapper: m)
        #expect(label.text == "50.00")
        // 标签框右贴 frame.maxX；垂直居中 point.y
        #expect(label.rect.maxX == 1000)
        #expect(label.rect.midY == 300)
    }

    @Test("priceLabel：负价/超 100 也按 yToPrice 字面（caller 已保证 frame 内）")
    func priceLabelEdge() {
        let m = makeMapper()
        // point.y=0 → yToPrice = 100.00
        #expect(CrosshairLayout.priceLabel(at: CGPoint(x: 0, y: 0), mapper: m).text == "100.00")
        // point.y=600 → yToPrice = 0.00
        #expect(CrosshairLayout.priceLabel(at: CGPoint(x: 0, y: 600), mapper: m).text == "0.00")
    }

    @Test("timeLabel：xToIndex(point.x) 落在 candles 范围内 → 取 datetime 格式化（UTC+8）；rect.bottom=frame.maxY、rect.center.x=point.x")
    func timeLabelInside() {
        let m = makeMapper(count: 3)
        // 2025-01-02 09:30:00 UTC+8 = 1735781400 epoch
        let candles = [mc(0, datetime: 1735781400),
                       mc(1, datetime: 1735781580),  // 09:33
                       mc(2, datetime: 1735781760)]  // 09:36
        // point.x=10 → xToIndex 解析为 index 1 → datetime 1735781580 → "2025-01-02 09:33"
        let label = CrosshairLayout.timeLabel(at: CGPoint(x: 10, y: 300),
                                              mapper: m, candles: candles[0..<3])
        #expect(label != nil)
        #expect(label?.text == "2025-01-02 09:33")
        #expect(label?.rect.maxY == 600)
        #expect(label?.rect.midX == 10)
    }

    @Test("timeLabel：xToIndex 超出 candles 范围 → nil")
    func timeLabelOutside() {
        let m = makeMapper(count: 3)
        let candles = [mc(0, datetime: 1735781400)]
        // point.x=20 → xToIndex 解析为 2 → 越界（slice 仅 0...0）
        let label = CrosshairLayout.timeLabel(at: CGPoint(x: 20, y: 300),
                                              mapper: m, candles: candles[0..<1])
        #expect(label == nil)
    }
}
