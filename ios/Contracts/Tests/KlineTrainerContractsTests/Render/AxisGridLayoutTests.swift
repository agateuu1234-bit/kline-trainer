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

private func makeFrames(width: CGFloat = 1000, height: CGFloat = 600) -> ChartPanelFrames {
    ChartPanelFrames.split(in: CGRect(x: 0, y: 0, width: width, height: height))
}

@Suite("AxisGridLayout.timeTicks 时间刻度 + 垂直网格")
struct TimeTicksTests {
    @Test("首条垂直线 x == indexToX(candles.startIndex)，≠ indexToX(0)（防 slice-relative 索引陷阱）")
    func absoluteIndexNotSliceRelative() {
        // startIndex=5：indexToX(5)=0（左缘），indexToX(0)=-50（错位），两者可区分。
        let m = makeMapper(startIndex: 5, visibleCount: 10, candleStep: 10)
        let c = makeCandles(count: 15)[5..<15]
        let (labels, lines) = AxisGridLayout.timeTicks(mapper: m, candles: c, period: .m3, frames: makeFrames())
        #expect(lines.first!.from.x == m.indexToX(c.startIndex))   // == indexToX(5) == 0
        #expect(lines.first!.from.x != m.indexToX(0))              // ≠ -50（错位陷阱）
        #expect(labels.count == lines.count)
    }

    @Test("垂直线贯穿三区（mainChart.minY .. macdChart.maxY）")
    func verticalSpansAllFrames() {
        let f = makeFrames()
        let m = makeMapper(visibleCount: 10)
        let c = makeCandles(count: 10)[0..<10]
        let (_, lines) = AxisGridLayout.timeTicks(mapper: m, candles: c, period: .m3, frames: f)
        for line in lines {
            #expect(line.from.y == f.mainChart.minY)
            #expect(line.to.y == f.macdChart.maxY)
        }
    }

    @Test("六周期日期格式分支（UTC+8 / en_US_POSIX）")
    func periodDateFormats() {
        let f = makeFrames()
        // 2025-01-02 09:30 北京（datetime=1735781400）
        func firstLabel(_ p: Period) -> String {
            let c = makeCandles(count: 1, startDatetime: 1735781400, period: p)[0..<1]
            let m = makeMapper(visibleCount: 1)
            return AxisGridLayout.timeTicks(mapper: m, candles: c, period: p, frames: f).labels.first!.text
        }
        #expect(firstLabel(.m3)    == "01-02 09:30")
        #expect(firstLabel(.m60)   == "01-02 09:30")
        #expect(firstLabel(.daily) == "2025-01-02")
        #expect(firstLabel(.weekly) == "2025-01-02")
        #expect(firstLabel(.monthly) == "2025-01")
    }

    @Test("n=1 → 单刻度（索引集去重为 {startIndex}）；n=2 → 两刻度")
    func dedupSmallN() {
        let f = makeFrames()
        let m1 = makeMapper(startIndex: 3, visibleCount: 1)
        let c1 = makeCandles(count: 4)[3..<4]
        #expect(AxisGridLayout.timeTicks(mapper: m1, candles: c1, period: .m3, frames: f).labels.count == 1)
        let m2 = makeMapper(startIndex: 0, visibleCount: 2)
        let c2 = makeCandles(count: 2)[0..<2]
        #expect(AxisGridLayout.timeTicks(mapper: m2, candles: c2, period: .m3, frames: f).labels.count == 2)
    }
}

private func makeIndicatorMapper(frame: CGRect, values: [Double],
                                 candleStep: CGFloat = 10, displayScale: CGFloat = 2) -> IndicatorMapper {
    let geom = ChartGeometry(candleStep: candleStep, candleWidth: candleStep * 0.7, gap: candleStep * 0.3)
    let vp = ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0, geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100), mainChartFrame: frame)
    return IndicatorMapper(frame: frame, valueRange: NonDegenerateRange.make(values: values),
                           geometry: geom, viewport: vp, displayScale: displayScale)
}

@Suite("AxisGridLayout 量图/MACD 标签")
struct VolumeMacdTests {
    @Test("formatVolume 万/亿分支")
    func volumeFormat() {
        #expect(AxisGridLayout.formatVolume(9999) == "9999")
        #expect(AxisGridLayout.formatVolume(10_000) == "1.0万")
        #expect(AxisGridLayout.formatVolume(150_000_000) == "1.5亿")
    }

    @Test("量图：标签在 valueToY(maxVolume)，y 略低于 frame 顶（2% padding）")
    func volumeMaxLine() {
        let frame = makeFrames().volumeChart
        let candles = [mc(0, datetime: 1, volume: 5000), mc(1, datetime: 2, volume: 20000)][0..<2]
        // mapper 的 valueRange 必须由同一组 volume 构造（含 0 下界，镜像 RenderStateBuilder）。
        let vm = makeIndicatorMapper(frame: frame, values: [0] + candles.map { Double($0.volume) })
        let result = AxisGridLayout.volumeAxis(volumeMapper: vm, candles: candles)
        #expect(result != nil)
        #expect(result!.gridLine.from.y == vm.valueToY(20000))   // 镜像 valueToY
        #expect(result!.label.text == "2.0万")
        #expect(result!.gridLine.from.y > frame.minY)            // 略低于顶边（2% padding）
    }

    @Test("MACD：0 在区间 → 线/标签在 valueToY(0)；0 不在区间 → nil")
    func macdZeroBranches() {
        let frame = makeFrames().macdChart
        let inRange = makeIndicatorMapper(frame: frame, values: [-0.5, 0.5])
        let r = AxisGridLayout.macdZero(macdMapper: inRange)
        #expect(r != nil)
        #expect(r!.gridLine.from.y == inRange.valueToY(0))
        #expect(r!.label.text == "0")
        // [1.0,2.0]+2% padding → [0.98,2.02]，0 不在区间 → nil
        let outRange = makeIndicatorMapper(frame: frame, values: [1.0, 2.0])
        #expect(AxisGridLayout.macdZero(macdMapper: outRange) == nil)
    }
}

@Suite("AxisGridLayout.periodLabel 周期角标")
struct PeriodLabelTests {
    @Test("六周期文字映射")
    func periodTexts() {
        let f = makeFrames()
        func txt(_ p: Period) -> String { AxisGridLayout.periodLabel(period: p, frames: f).text }
        #expect(txt(.m3) == "3分")
        #expect(txt(.m15) == "15分")
        #expect(txt(.m60) == "60分")
        #expect(txt(.daily) == "日")
        #expect(txt(.weekly) == "周")
        #expect(txt(.monthly) == "月")
    }

    @Test("角标定位左上角（mainChart 内）")
    func cornerPlacement() {
        let f = makeFrames()
        let label = AxisGridLayout.periodLabel(period: .m60, frames: f)
        #expect(label.rect.minX >= f.mainChart.minX)
        #expect(label.rect.minY >= f.mainChart.minY)
        #expect(label.rect.maxY <= f.mainChart.maxY)
    }
}

@Suite("AxisGridLayout.resolve 组装")
struct AxisGridResolveTests {
    @Test("空切片 → nil")
    func emptyCandlesNil() {
        let m = makeMapper(visibleCount: 0)
        let f = makeFrames()
        let vm = makeIndicatorMapper(frame: f.volumeChart, values: [0, 1])
        let mm = makeIndicatorMapper(frame: f.macdChart, values: [-1, 1])
        #expect(AxisGridLayout.resolve(mapper: m, volumeMapper: vm, macdMapper: mm,
                                       candles: makeCandles(count: 0)[0..<0], period: .m3, frames: f) == nil)
    }

    @Test("非空 → 组装各部件；gridLines = 价格 + 时间 + 量 + macd 合并")
    func assembles() {
        let f = makeFrames()
        let m = makeMapper(visibleCount: 10, priceMin: 11.23, priceMax: 12.87)
        let vm = makeIndicatorMapper(frame: f.volumeChart, values: [0, 100])
        let mm = makeIndicatorMapper(frame: f.macdChart, values: [-0.5, 0.5])
        let c = makeCandles(count: 10, volume: 100)[0..<10]
        let r = AxisGridLayout.resolve(mapper: m, volumeMapper: vm, macdMapper: mm,
                                       candles: c, period: .m60, frames: f)
        #expect(r != nil)
        guard let r else { return }
        let price = AxisGridLayout.priceTicks(mapper: m)
        let time = AxisGridLayout.timeTicks(mapper: m, candles: c, period: .m60, frames: f)
        #expect(r.priceLabels == price.labels)
        #expect(r.timeLabels == time.labels)
        #expect(r.periodLabel.text == "60分")
        #expect(r.volumeLabel != nil)
        #expect(r.macdZeroLabel != nil)
        // gridLines 合并计数 = 价格 + 时间 + 量(1) + macd(1)
        #expect(r.gridLines.count == price.gridLines.count + time.gridLines.count + 2)
    }
}
