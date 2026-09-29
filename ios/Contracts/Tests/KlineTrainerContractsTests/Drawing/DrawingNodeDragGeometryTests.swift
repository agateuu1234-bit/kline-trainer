// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragGeometryTests.swift
// Spec: docs/superpowers/specs/2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D134d / D137）
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 拖动几何：位移换算（D134d）")
struct DrawingNodeDragDeltaTests {

    /// 造一个「投影落在非整像素上」的视口——⭐ 整像素参数会让缺陷碰巧不暴露（spec T10 自检）
    static func mapper(candleStep: CGFloat = 4.0025, pixelShift: CGFloat = 4,
                       startIndex: Int = 0, visibleCount: Int = 80,
                       frame: CGRect = CGRect(x: 0, y: 0, width: 320.2, height: 401),
                       priceMin: Double = 10, priceMax: Double = 23.7,
                       displayScale: CGFloat = 3) -> CoordinateMapper {
        let geo = ChartGeometry(candleStep: candleStep, candleWidth: candleStep * 0.8, gap: candleStep * 0.2)
        let vp = ChartViewport(startIndex: startIndex, visibleCount: visibleCount,
                               pixelShift: pixelShift, geometry: geo,
                               priceRange: PriceRange(min: priceMin, max: priceMax),
                               mainChartFrame: frame)
        return CoordinateMapper(viewport: vp, displayScale: displayScale)
    }

    @Test("零位移 ⇒ 两个轴的增量都逐位为 0（⇒ 新锚点恒等于原锚点）")
    func zeroTranslationIsIdentity() {
        let m = Self.mapper()
        let d = DrawingNodeDrag.anchorDelta(translation: .zero, mapper: m)
        #expect(d != nil)
        #expect(d?.price == 0.0)        // ⛔ 用 == 不用近似：乘 0 必须逐位为 0
        #expect(d?.index == 0)
    }

    @Test("纯横拖（translation.y == 0）⇒ 价位增量逐位为 0，只有下标变")
    func pureHorizontalDragDoesNotTouchPrice() {
        let m = Self.mapper()
        let d = DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 40, y: 0), mapper: m)
        #expect(d?.price == 0.0)
        #expect(d?.index != 0)          // ⭐ 反假绿：证明这一档真的拖动了，不是「什么都没发生」
        #expect(d?.index == 10)         // 40 / 4.0025 = 9.994 → 四舍五入 10
    }

    @Test("纵向增量 = -translation.y × span / height，且**符号朝上为正**")
    func verticalDeltaSignAndMagnitude() {
        let m = Self.mapper()
        // 屏幕 y 向下为正 ⇒ 手指向上拖（负 y）应让价位**变大**
        let up = DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 0, y: -40.1), mapper: m)
        #expect((up?.price ?? 0) > 0)   // ⭐ 负号写掉这条就红
        let span = 23.7 - 10.0
        #expect(abs((up?.price ?? 0) - 40.1 * span / 401.0) < 1e-12)
        let down = DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 0, y: 40.1), mapper: m)
        #expect((down?.price ?? 0) < 0)
    }

    @Test("空图表（candleStep <= 0）⇒ 返回 nil，⛔ 绝不 Int(NaN) 崩")
    func emptyChartReturnsNil() {
        let geo = ChartGeometry(candleStep: 0, candleWidth: 0, gap: 0)
        let vp = ChartViewport(startIndex: 0, visibleCount: 0, pixelShift: 0, geometry: geo,
                               priceRange: PriceRange(min: 10, max: 23.7),
                               mainChartFrame: CGRect(x: 0, y: 0, width: 320.2, height: 401))
        let m = CoordinateMapper(viewport: vp, displayScale: 3)
        #expect(DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 40, y: 40), mapper: m) == nil)
        // ⭐ 反假绿：同一串输入在正常视口下**确实**返回非 nil
        #expect(DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 40, y: 40), mapper: Self.mapper()) != nil)
    }
}
