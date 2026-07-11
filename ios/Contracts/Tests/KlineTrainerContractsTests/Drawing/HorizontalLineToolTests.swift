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

    @Test("视觉零变化：默认样式在昼夜下都是 legacy 橙 + 1.5pt")
    func defaultStyleUnchangedBothSchemes() {
        #expect(HorizontalLineTool.lineWidth(forThickness: 1) == 1.5)
        for s in [AppColorScheme.light, .dark] {
            let c = DrawingColorResolver.resolve(.orange, scheme: s)   // 默认 colorToken=.orange
            #expect(c.red == 0.82 && c.green == 0.40 && c.blue == 0.0)
        }
        #expect(HorizontalLineTool.dashPattern(for: .solid).isEmpty)
    }
    @Test("thickness 五档产出五个不同线宽")
    func thicknessFiveDistinctWidths() {
        let ws = (1...5).map { HorizontalLineTool.lineWidth(forThickness: $0) }
        #expect(Set(ws).count == 5)
        #expect(ws[0] == 1.5)   // 档 1 = 今天线宽
    }
    @Test("thickness 越界被 clamp 到 1...5")
    func thicknessClamped() {
        #expect(HorizontalLineTool.lineWidth(forThickness: 0) == HorizontalLineTool.lineWidth(forThickness: 1))
        #expect(HorizontalLineTool.lineWidth(forThickness: 99) == HorizontalLineTool.lineWidth(forThickness: 5))
    }
    @Test("lineStyle：solid 无 pattern；dash1…4 四种互不相同")
    func dashPatternsDistinct() {
        #expect(HorizontalLineTool.dashPattern(for: .solid).isEmpty)
        let ds = [LineStyle.dash1, .dash2, .dash3, .dash4].map { HorizontalLineTool.dashPattern(for: $0) }
        #expect(ds.allSatisfy { !$0.isEmpty })
        for i in 0..<ds.count { for j in (i+1)..<ds.count { #expect(ds[i] != ds[j]) } }
    }

    // 采样 helper：render 到 sRGB premultiplied bitmap，返回展开后的像素（不假设坐标方向——扫列/行找线像素）。
    @MainActor
    static func renderPixels(_ drawing: DrawingObject, scheme: AppColorScheme)
        -> (data: [UInt8], w: Int, h: Int) {
        let w = 800, h = 360
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        HorizontalLineTool().render(ctx: ctx, mapper: Self.mapper(), drawing: drawing, scheme: scheme)
        return (data, w, h)
    }
    // x=400 列上（线贯穿全宽，此列必有线像素），反 premultiplied 还原颜色；只取 alpha 明显的像素。
    static func litColumn(_ data: [UInt8], w: Int, h: Int, x: Int = 400)
        -> [(r: CGFloat, g: CGFloat, b: CGFloat)] {
        var out: [(CGFloat, CGFloat, CGFloat)] = []
        for yy in 0..<h {
            let i = (yy * w + x) * 4
            let a = CGFloat(data[i+3]) / 255
            guard a > 0.3 else { continue }
            out.append((CGFloat(data[i])/255/a, CGFloat(data[i+1])/255/a, CGFloat(data[i+2])/255/a))
        }
        return out
    }

    @Test("render 输出：默认样式画出 legacy 橙（走真实 render，非纯 helper）")
    func renderDefaultIsLegacyOrange() {
        let def = DrawingObject(toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)], isExtended: false, panelPosition: 0)
        let (data, w, h) = Self.renderPixels(def, scheme: .light)
        let lit = Self.litColumn(data, w: w, h: h)
        #expect(!lit.isEmpty)   // 线真的画出来了
        #expect(lit.contains { abs($0.r-0.82)<0.15 && abs($0.g-0.40)<0.15 && $0.b<0.15 })   // 橙
    }
    @Test("render 输出：colorToken=.blue 画蓝（证明 render 消费了 colorToken，没留 legacy strokeRGBA）")
    func renderConsumesColorToken() {
        let blue = DrawingObject(toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
            isExtended: false, panelPosition: 0, colorToken: .blue)
        let (data, w, h) = Self.renderPixels(blue, scheme: .light)
        #expect(Self.litColumn(data, w: w, h: h).contains { $0.b > $0.r && $0.b > 0.5 })   // 蓝占主导、非橙
    }
    @Test("render 输出：thickness=5 覆盖行数 > thickness=1（证明 render 消费 thickness）")
    func renderConsumesThickness() {
        func litRows(_ t: Int) -> Int {
            let d = DrawingObject(toolType: .horizontal,
                anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
                isExtended: false, panelPosition: 0, thickness: t)
            let (data, w, h) = Self.renderPixels(d, scheme: .light)
            return Self.litColumn(data, w: w, h: h).count
        }
        #expect(litRows(5) > litRows(1))
    }
    @Test("render 输出：solid 沿线连续、dash1 有间断（证明 render 消费 lineStyle）")
    func renderConsumesLineStyle() {
        func gaps(_ style: LineStyle) -> Int {
            let d = DrawingObject(toolType: .horizontal,
                anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
                isExtended: false, panelPosition: 0, lineStyle: style)
            let (data, w, h) = Self.renderPixels(d, scheme: .light)
            // 找线所在行（x=400 列 alpha 最大的行），再沿该行 x∈[100,700] 数「亮→暗」跳变
            let lineY = (0..<h).max(by: { data[($0*w+400)*4+3] < data[($1*w+400)*4+3] })!
            var g = 0, prevLit = false
            for x in 100..<700 {
                let lit = data[(lineY*w + x)*4 + 3] > 60
                if prevLit && !lit { g += 1 }
                prevLit = lit
            }
            return g
        }
        #expect(gaps(.solid) == 0)     // 实线：中段无间断
        #expect(gaps(.dash1) >= 1)     // 虚线：有间断
    }
}
