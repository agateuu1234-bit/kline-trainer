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
