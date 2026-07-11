import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("HorizontalLineTool")
struct HorizontalLineToolTests {

    // 已知视口：mainChartFrame x∈[0,800] y∈[0,360]（split 60% of 600），price∈[10,20]。
    static func mapper() -> CoordinateMapper {
        let main = CGRect(x: 0, y: 0, width: 800, height: 360)
        let vp = ChartViewport(
            startIndex: 0, visibleCount: 80, pixelShift: 0,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 10, max: 20), mainChartFrame: main)
        return CoordinateMapper(viewport: vp, displayScale: 2.0)
    }

    @Test("type == .horizontal / requiredAnchors == 1...1")
    func metadata() {
        #expect(HorizontalLineTool.type == .horizontal)
        #expect(HorizontalLineTool().requiredAnchors == 1...1)
    }

    @Test("lineY: 横线 y == mapper.priceToY(anchor.price)")
    func lineYMatchesPriceToY() {
        let m = Self.mapper()
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)]
        let y = HorizontalLineTool().lineY(anchors: anchors, mapper: m)
        #expect(y == m.priceToY(15))
    }

    @Test("lineY: 空 anchors → nil（无可画）")
    func lineYEmptyNil() {
        #expect(HorizontalLineTool().lineY(anchors: [], mapper: Self.mapper()) == nil)
    }

    @Test("hitTest: 命中（point.y 接近横线 y，容差内）")
    func hitTestHit() {
        let m = Self.mapper()
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)]
        let drawing = DrawingObject(toolType: .horizontal, anchors: anchors, isExtended: false, panelPosition: 0)
        let y = m.priceToY(15)
        #expect(HorizontalLineTool().hitTest(point: CGPoint(x: 400, y: y + 2),
                                             mapper: m, drawing: drawing) == true)
    }

    @Test("hitTest: 未命中（远离横线 y，超容差）")
    func hitTestMiss() {
        let m = Self.mapper()
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)]
        let drawing = DrawingObject(toolType: .horizontal, anchors: anchors, isExtended: false, panelPosition: 0)
        let y = m.priceToY(15)
        #expect(HorizontalLineTool().hitTest(point: CGPoint(x: 400, y: y + 50),
                                             mapper: m, drawing: drawing) == false)
    }

    @Test("hitTest: 空 anchors → false")
    func hitTestEmptyFalse() {
        let drawing = DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        #expect(HorizontalLineTool().hitTest(point: .zero, mapper: Self.mapper(), drawing: drawing) == false)
    }
}
