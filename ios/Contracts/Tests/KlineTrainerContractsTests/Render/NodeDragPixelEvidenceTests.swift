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
// 评审修复环第 1/5 轮 Important：首版"正序"/"正向对照"两档手工按固定顺序分别调
// `drawMarkers`/`drawSelectionNodes`，从不经过 `KLineView.draw(_:)` 真实派发 ⇒ 把生产代码里
// `KLineView.swift:134`/`:140` 的真实调用顺序整段换掉，这两档照样 PASS（评审实测复现）。
// 判别力只能靠 `SelectionNodeDrawOrderGuardTests`（源码文本顺序守卫）兜底，T5 自己对"生产
// 真的按这个顺序调"这件事判别力为零。本轮改为：**正序 / 正向对照改走真实 `view.draw(view.bounds)`**
// 派发链（与 `ChartContainerViewDrawingSessionTests.pixelAt`/`litPixels` 同款 push/draw/pop
// 技巧，`:427`/`:446`），构造一份真实 `KLineRenderState` 喂给 `view.renderState`，这样生产顺序
// 一旦被换掉，这两档会跟着 `SelectionNodeDrawOrderGuardTests` 一起真的变红（已实测验证，见下）。
// **反向对照**仍然必须手工调用两个真实 extension 方法并在测试内部换序——这正是它的定义
// （"不改生产代码，只在测试内部换序"），不能走 `draw(_:)`（那只会执行**今天**的生产顺序）。
//
// 平台门：UIKit-only（drawMarkers/drawSelectionNodes/KLineView.draw 都是 UIKit-only API），
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

    /// 真实 `KLineRenderState`（`KLineRenderState.swift:16-41` 的完整 public init）——喂给
    /// `view.renderState` 后，`view.draw(view.bounds)` 走的是生产 `KLineView.swift:98-145`
    /// **一字不改**的真实派发链（含 `drawGridLines`/`drawCandles`/.../`drawDrawings` 等本测试
    /// 不关心的层）。`volumeChart`/`macdChart` 给 `.zero`：那两块面积为零，`drawVolume`/`drawMACD`
    /// 画不出任何像素，不会污染主图区的采样点。`crosshairPoint: nil` —— `drawCrosshair` 是
    /// `drawSelectionNodes` 之后**唯一**还会画的东西（`KLineView.swift:144`），必须关掉，否则它
    /// 会在节点之上再画一层，让"谁画在最后"这件事多一个变量。
    private static func makeRenderState(markers: [TradeMarker], drawing: DrawingObject) -> KLineRenderState {
        let mapper = Self.makeMapper()
        return KLineRenderState(
            panel: PanelViewState(period: .daily, interactionMode: .autoTracking,
                                  visibleCount: 4, offset: 0, revision: 0),
            frames: ChartPanelFrames(mainChart: mapper.viewport.mainChartFrame,
                                     volumeChart: .zero, macdChart: .zero),
            viewport: mapper.viewport,
            visibleCandles: Self.candles[0..<4],
            volumeRange: NonDegenerateRange.make(values: []),
            macdRange: NonDegenerateRange.make(values: []),
            markers: markers,
            drawings: [drawing],
            crosshairPoint: nil,
            selectedDrawingID: drawing.id)
    }

    /// 真实派发链：`view.renderState = state` 之后直调 `view.draw(view.bounds)`——
    /// 生产 `KLineView.swift:98` 这个方法本身，不是本文件重新拼出来的调用序列。
    /// 换句话说，这里**没有**任何地方写"先 drawMarkers 再 drawSelectionNodes"——顺序完全
    /// 由生产代码自己决定，改坏生产顺序会让这条路径跟着变。
    private static func renderReal(markers: [TradeMarker], drawing: DrawingObject) -> [UInt8] {
        let view = makeView()
        view.renderState = Self.makeRenderState(markers: markers, drawing: drawing)
        var data = [UInt8](repeating: 0, count: W * H * 4)
        let ctx = CGContext(data: &data, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        UIGraphicsPushContext(ctx)
        view.draw(view.bounds)
        UIGraphicsPopContext()
        return data
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

    // ⭐ 判别力边界（评审修复环第 1/5 轮 Important）：下面这两档走 `view.draw(view.bounds)`
    // 真实派发链 —— 证明的是"**生产代码此刻真的按这个顺序调用时**，节点中心是节点色"。
    // 它们**不是**"生产代码永远不会把节点盖住"的独立证明；那一半由
    // `SelectionNodeDrawOrderGuardTests`（源码文本顺序守卫）钉住生产顺序本身不会被静默改掉。
    // 两者缺一不可：改坏生产顺序时，这两档会**跟着**顺序守卫一起变红（已实测验证，见 Step3 的
    // "换生产顺序"核验，T5 正序/正向对照与顺序守卫同时报错；见 task-13-report.md）。
    @Test("T5 正序（真实路径）：标记 + 节点同锚，走 KLineView.draw(_:) 真实派发 ⇒ 节点中心仍是节点色（日间纯黑）")
    func nodeIsNotCoveredByTradeMarker() throws {
        let drawing = Self.line()
        let data = Self.renderReal(markers: Self.buyMarker(), drawing: drawing)
        let p = try #require(Self.pixel(data, at: Self.center),
                             "节点中心必须有像素 —— 否则下面的颜色断言恒真")
        #expect(p.r < 0.1 && p.g < 0.1 && p.b < 0.1,
               "按生产真实派发链画完，中心必须是节点的纯黑色，实得 \(p)")
    }

    @Test("⭐正向对照：移走标记后同一点仍是节点色 —— 证明上面那条不是恒真")
    func withoutMarkerStillNodeColor() throws {
        let drawing = Self.line()
        let data = Self.renderReal(markers: [], drawing: drawing)
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
