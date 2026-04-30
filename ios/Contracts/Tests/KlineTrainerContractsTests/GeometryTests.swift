import Testing
import Foundation
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
        #expect(r.span >= 2e-6)
    }
}
