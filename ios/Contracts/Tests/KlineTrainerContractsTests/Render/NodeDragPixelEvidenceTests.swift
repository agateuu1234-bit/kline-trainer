// ios/Contracts/Tests/KlineTrainerContractsTests/Render/NodeDragPixelEvidenceTests.swift
// Spec: docs/superpowers/specs/2026-09-28-drawing-tools-P1c-3-node-drag-design.md §8-T5 + §2.4
//
// T5：成交标记是半径 5pt 的实心圆（直径 10pt，`KLineView+Markers.swift:30`/`:44`），
// 选中节点直径 7pt（`DrawingNodeGeometry.visualDiameter`）。`KLineView.draw(_:)` 的真实顺序
// （`KLineView.swift:134` 先 drawMarkers，`:140` 后 drawSelectionNodes）保证节点画在标记之上，
// 不被整个盖住 —— 否则「取消变蓝后节点是唯一的图内选中反馈」就会在有成交记录的那根线上失效。
// §2.4 已实跑核实：`MarkersLayout.findCandleIndex` 返回的是全局下标（`ArraySlice` 保留原下标，
// `RenderStateBuilder.swift:34` 自陈 `slice.startIndex == viewport.startIndex`），与锚点的
// `candleIndex` 同一个 x 坐标空间 ⇒ 下面构造的「标记与节点锚同一根 K 线、同一价位」场景成立。
//
// 本测试直调 `KLineView` 的两个真实 UIKit extension 方法（不重新实现绘制逻辑），
// 按生产顺序喂同一个 CGContext —— 与 `ChartContainerViewDrawingSessionTests.pixelAt`/`litPixels`
// 同款 `UIGraphicsPushContext`/`draw`/`UIGraphicsPopContext` 技巧（`:427`/`:446`）。
//
// 平台门：UIKit-only（drawMarkers/drawSelectionNodes 是 KLineView 的 UIKit extension 方法），
// macOS host swift test 整份不编译，同既有先例 NodeDragCandidateTests.swift。
#if canImport(UIKit)
import CoreGraphics
import UIKit
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 T5：选中节点不被成交标记整个盖住（像素证据）")
struct NodeDragPixelEvidenceTests {

    // 与 `MarkersLayoutTests.makeMapper`（Render/MarkersLayoutTests.swift:16-23）同款几何：
    // candleStep 10 / priceRange 0...100 / mainChartFrame 1000x600。
    private static func makeMapper() -> CoordinateMapper {
        let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
        let vp = ChartViewport(startIndex: 0, visibleCount: 4, pixelShift: 0,
                               geometry: geom, priceRange: PriceRange(min: 0, max: 100),
                               mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        return CoordinateMapper(viewport: vp, displayScale: 2)
    }

    // 同 `MarkersLayoutTests.mc`（:7-14）同款夹具 helper（私有，文件各自一份，不跨文件共享私有符号）。
    private static func mc(_ idx: Int, endGlobal: Int, close: Double) -> KLineCandle {
        KLineCandle(period: .daily, datetime: Int64(idx),
                    open: close, high: close + 1, low: close - 1, close: close,
                    volume: 100, amount: nil, ma66: nil,
                    bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil,
                    globalIndex: idx, endGlobalIndex: endGlobal)
    }

    // 第 2 根（idx=2）close=50 ⇒ priceToY(50)=300；indexToX(2)=20。
    // marker.globalTick=15 精确命中 idx=2（endGlobal 序列 [5,10,15,20]，同 MarkersLayoutTests.exactHit）。
    // 线的锚点 candleIndex=2、price=50 —— 与 marker 锚同一根 K 线、同一价位 ⇒ 节点与标记圆心重合于同一点。
    private static let candles: [KLineCandle] = [
        mc(0, endGlobal: 5, close: 50), mc(1, endGlobal: 10, close: 50),
        mc(2, endGlobal: 15, close: 50), mc(3, endGlobal: 20, close: 50),
    ]
    private static let center = CGPoint(x: 20, y: 300)
    private static let W = 1000, H = 600

    private static func makeView() -> KLineView {
        let v = KLineView(frame: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
        v.overrideUserInterfaceStyle = .light   // 钉死 currentPalette 走白天集，不依赖测试机系统外观
        return v
    }

    private static func line(id: String = "A") -> DrawingObject {
        makeHLine(id: id, candleIndex: 2, price: 50, period: .daily)
    }

    private static func buyMarker() -> [TradeMarker] {
        [TradeMarker(globalTick: 15, price: 999, direction: .buy)]  // price 不影响几何（D10：锚到 candle.close）
    }

    /// `W`×`H` bitmap，`CGContext(data:)` 直建、`UIGraphicsPushContext` 推成"当前 UIKit 上下文"——
    /// `drawMarkers` 内部用 `UIColor.setFill()`（只认"当前上下文"，不认传入的显式 `ctx` 参数），
    /// 不推的话标记会被填成 CGContext 默认填色（不透明黑），与节点色（日间纯黑）撞色，
    /// 整条测试的判别力归零（标记色=节点色，正反序都看不出差异）。
    /// 先例：`ChartContainerViewDrawingSessionTests.pixelAt`/`litPixels`（同款 push/draw/pop，`:427`/`:446`）。
    private static func render(_ draw: (KLineView, CGContext) -> Void) -> [UInt8] {
        let view = makeView()
        var data = [UInt8](repeating: 0, count: W * H * 4)
        let ctx = CGContext(data: &data, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        draw(view, ctx)
        UIGraphicsPopContext()
        return data
    }

    /// 反 premultiplied 颜色；`y` 是 CG 坐标，行序 bottom-up（同
    /// `DrawingNodeRendererTests.pixel` 实测结论：内存行 = H - 1 - CG的y）。
    private static func pixel(_ data: [UInt8], at p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let x = Int(p.x), y = Int(p.y)
        let i = ((H - 1 - y) * W + x) * 4
        let a = CGFloat(data[i + 3]) / 255
        guard a > 0.3 else { return nil }
        return (CGFloat(data[i]) / 255 / a, CGFloat(data[i + 1]) / 255 / a, CGFloat(data[i + 2]) / 255 / a)
    }

    @Test("T5 正序（真实顺序）：标记 + 节点同锚 ⇒ 节点中心仍是节点色（日间纯黑），不被标记整个盖住")
    func nodeIsNotCoveredByTradeMarker() throws {
        let mapper = Self.makeMapper()
        let drawing = Self.line()
        let data = Self.render { view, ctx in
            // 真实顺序：KLineView.draw(_:) 先 drawMarkers（:134）再 drawSelectionNodes（:140）。
            view.drawMarkers(ctx: ctx, viewport: mapper.viewport, mapper: mapper,
                             markers: Self.buyMarker(), candles: Self.candles[0..<4])
            view.drawSelectionNodes(ctx: ctx, mapper: mapper, drawings: [drawing],
                                    scheme: .light, selectedDrawingID: drawing.id,
                                    tools: KLineView.drawingTools)
        }
        let p = try #require(Self.pixel(data, at: Self.center),
                             "节点中心必须有像素 —— 否则下面的颜色断言恒真")
        #expect(p.r < 0.1 && p.g < 0.1 && p.b < 0.1,
               "节点画在标记之后，中心必须是节点的纯黑色，实得 \(p)")
    }

    @Test("⭐正向对照：移走标记后同一点仍是节点色 —— 证明上面那条不是恒真")
    func withoutMarkerStillNodeColor() throws {
        let mapper = Self.makeMapper()
        let drawing = Self.line()
        let data = Self.render { view, ctx in
            // 仍调用 drawMarkers（走它真实的早返分支），但 markers 列表为空 —— 场景里"移走"了那枚标记。
            view.drawMarkers(ctx: ctx, viewport: mapper.viewport, mapper: mapper,
                             markers: [], candles: Self.candles[0..<4])
            view.drawSelectionNodes(ctx: ctx, mapper: mapper, drawings: [drawing],
                                    scheme: .light, selectedDrawingID: drawing.id,
                                    tools: KLineView.drawingTools)
        }
        let p = try #require(Self.pixel(data, at: Self.center), "节点中心必须有像素")
        #expect(p.r < 0.1 && p.g < 0.1 && p.b < 0.1,
               "无标记时节点中心仍须是纯黑，实得 \(p)")
    }

    @Test("⭐反向对照：测试内部把两次绘制换序（不改生产代码）⇒ 同一点变成标记色，证明 T5 有判别力")
    func reversedOrderCoversNodeWithMarker() throws {
        let mapper = Self.makeMapper()
        let drawing = Self.line()
        let data = Self.render { view, ctx in
            // ⚠️ 仅本测试内部换序；生产代码（KLineView.swift:134/:140）顺序不变。
            view.drawSelectionNodes(ctx: ctx, mapper: mapper, drawings: [drawing],
                                    scheme: .light, selectedDrawingID: drawing.id,
                                    tools: KLineView.drawingTools)
            view.drawMarkers(ctx: ctx, viewport: mapper.viewport, mapper: mapper,
                             markers: Self.buyMarker(), candles: Self.candles[0..<4])
        }
        let p = try #require(Self.pixel(data, at: Self.center), "节点中心必须有像素")
        #expect(!(p.r < 0.1 && p.g < 0.1 && p.b < 0.1),
               "换序后标记画在节点之上，中心不该再是节点的纯黑，实得 \(p)")
        #expect(p.r > p.g && p.r > p.b,
               "换序后中心应被 buy 标记（红点，日间 0.82/0.10/0.12）覆盖，呈红色主导，实得 \(p)")
    }
}
#endif
