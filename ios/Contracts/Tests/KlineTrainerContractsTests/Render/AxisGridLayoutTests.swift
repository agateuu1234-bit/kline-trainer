// Kline Trainer Swift Contracts — AxisGridLayout host tests（RFC #3 坐标轴/网格/周期标注）
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func mc(_ idx: Int, datetime: Int64, close: Double = 10, volume: Int64 = 100,
                period: Period = .m3, macdBar: Double? = nil) -> KLineCandle {
    KLineCandle(period: period, datetime: datetime,
                open: close, high: close + 1, low: close - 1, close: close,
                volume: volume, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: macdBar,
                globalIndex: idx, endGlobalIndex: idx)
}

private func makeCandles(count: Int, startDatetime: Int64 = 1735689600, stepSeconds: Int64 = 180,
                         period: Period = .m3, volume: Int64 = 100) -> [KLineCandle] {
    (0..<count).map { mc($0, datetime: startDatetime + Int64($0) * stepSeconds,
                         volume: volume, period: period) }
}

private func makeMapper(startIndex: Int = 0, visibleCount: Int = 10, candleStep: CGFloat = 10,
                        pixelShift: CGFloat = 0, displayScale: CGFloat = 2,
                        priceMin: Double = 0, priceMax: Double = 100,
                        frameWidth: CGFloat = 1000, frameHeight: CGFloat = 360) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: candleStep, candleWidth: candleStep * 0.7, gap: candleStep * 0.3)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: visibleCount, pixelShift: pixelShift,
                           geometry: geom, priceRange: PriceRange(min: priceMin, max: priceMax),
                           mainChartFrame: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    return CoordinateMapper(viewport: vp, displayScale: displayScale)
}

@Suite("AxisGridLayout.priceTicks 价格刻度 nice-step")
struct PriceTicksTests {
    @Test("非整除区间 11.23..12.87 → {11.50,12.00,12.50}（step 0.5，≤6 档）")
    func niceStepNonInteger() {
        let m = makeMapper(priceMin: 11.23, priceMax: 12.87)
        let (labels, lines) = AxisGridLayout.priceTicks(mapper: m)
        #expect(labels.map(\.text) == ["11.50", "12.00", "12.50"])
        #expect(labels.count <= 6)
        #expect(lines.count == labels.count)   // 每档一条水平网格线
    }

    @Test("常态区间 10.05..10.95 → {10.20,10.40,10.60,10.80}（step 0.2，4 档）")
    func niceStepCommon() {
        let m = makeMapper(priceMin: 10.05, priceMax: 10.95)
        let (labels, _) = AxisGridLayout.priceTicks(mapper: m)
        #expect(labels.map(\.text) == ["10.20", "10.40", "10.60", "10.80"])
    }

    @Test("价格档 y == mapper.priceToY(value)（镜像，无第二套公式）")
    func mirrorsPriceToY() {
        let m = makeMapper(priceMin: 11.23, priceMax: 12.87)
        let (labels, lines) = AxisGridLayout.priceTicks(mapper: m)
        for (label, line) in zip(labels, lines) {
            let value = Double(label.text)!
            #expect(line.from.y == m.priceToY(value))
            #expect(line.from.x == m.viewport.mainChartFrame.minX)
            #expect(line.to.x == m.viewport.mainChartFrame.maxX)
            #expect(label.rect.maxX == m.viewport.mainChartFrame.maxX)   // 右贴右缘
            #expect(label.rect.midY == m.priceToY(value))
        }
    }

    @Test("退化区间（全零价格 min==max==0）→ 空刻度、不 trap（防 log10(0) 回归）")
    func degenerateRangeEmpty() {
        let m = makeMapper(priceMin: 0, priceMax: 0)
        let (labels, lines) = AxisGridLayout.priceTicks(mapper: m)
        #expect(labels.isEmpty)
        #expect(lines.isEmpty)
    }

    @Test("极窄正区间 10.001..10.002 → 价格刻度非空、≤6 档（细端阶梯保证非空；非空性回归）")
    func ultraNarrowNonEmpty() {
        let m = makeMapper(priceMin: 10.001, priceMax: 10.002)
        let (labels, _) = AxisGridLayout.priceTicks(mapper: m)
        #expect(!labels.isEmpty)
        #expect(labels.count <= 6)
    }
}
