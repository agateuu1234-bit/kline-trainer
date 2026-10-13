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

@MainActor
@Suite("P1c-3 拖动几何：幂等夹取（D137）")
struct DrawingNodeDragClampTests {

    static func hLine(price: Double, candleIndex: Int, sub: LineSubType = .straight) -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m15, candleIndex: candleIndex, price: price)],
                      isExtended: sub == .ray, panelPosition: 0, revealTick: 0,
                      period: .m15, lineSubType: sub)
    }

    // ⭐ 非整像素价位：整像素价位会让往返**碰巧**恒等 ⇒ 缺陷原样存在而测试全绿
    static let oddPrice = 15.123456

    @Test("① 零位移 ⇒ 新锚点**逐字段**等于原锚点（price 用 ==，⛔ 不用近似）")
    func zeroTranslationReturnsIdenticalAnchor() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0, translation: .zero,
                                                mapper: m, tool: HorizontalLineTool())
        #expect(out?.price == Self.oddPrice)
        #expect(out?.candleIndex == 40)
        #expect(out?.period == .m15)
    }

    @Test("② 纯横拖 ⇒ price 逐位不变，只有 candleIndex 变")
    func pureHorizontalKeepsPriceBitExact() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                translation: CGPoint(x: 20, y: 0),
                                                mapper: m, tool: HorizontalLineTool())
        #expect(out?.price == Self.oddPrice)        // ⛔ ==，不是近似
        #expect(out?.candleIndex == 45)             // 20/4.0025 = 4.997 → 5
    }

    @Test("④ 边界档：价位略超 priceRange 但舍入后仍可见 ⇒ 零位移照样逐位恒等")
    func boundaryPriceOutsideRangeButStillRealIsUntouched() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let boundary = 23.701                        // ⭐ 必须真的超出上限
        #expect(boundary > m.viewport.priceRange.max)       // ⭐ 先断言它确实超出，否则这档只是①的复制品
        let d = Self.hLine(price: boundary, candleIndex: 40)
        // ⭐ 先断言它确实产出 .real，否则「夹了也无所谓」的实现会假绿
        #expect(DrawingNodeDrag.producesRealNode(anchor: d.anchors[0], in: d, anchorIndex: 0,
                                                 mapper: m, tool: HorizontalLineTool()))
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0, translation: .zero,
                                                mapper: m, tool: HorizontalLineTool())
        #expect(out?.price == boundary)              // ⛔ 无条件夹会把它改成 23.7 ⇒ 这条红
    }

    @Test("N7 框内不夹：拖到仍然合法的位置 ⇒ 锚点就是候选值本身，没有被额外修正")
    func inBoundsCandidateIsNotModified() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
        let delta = DrawingNodeDrag.anchorDelta(translation: CGPoint(x: 8, y: -8), mapper: m)!
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                translation: CGPoint(x: 8, y: -8),
                                                mapper: m, tool: HorizontalLineTool())
        #expect(out?.price == Self.oddPrice + delta.price)   // ⭐「恒夹到边界」的实现这条会红
        #expect(out?.candleIndex == 40 + delta.index)
    }

    @Test("N7 四个方向：拖到框外任意远 ⇒ 夹回后**仍产出 .real**，纵向两档还要夹到**正确那一侧**边界")
    func clampKeepsNodeReal() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let tool = HorizontalLineTool()
        // ⭐ 修复环第 1 轮 Finding 1：只问「是不是 .real」测不出夹到了哪一侧 ——
        // priceRange 两端投影后都落在框内、都产出 .real，方向反了照样绿。
        // 实测该 fixture（dy=-5000 / dy=+5000）：夹到 23.699999999999996（≈max，偏差 ~4e-15）
        // 与 10.005694098088114（≈min，偏差 ~0.0057）。容差 0.1：比两次实测偏差大一个量级，
        // 又比「夹到对侧」的距离（priceRange 跨度 13.7）小两个量级 ⇒ 方向反了必定超出容差。
        let boundaryTolerance = 0.1
        for (dx, dy) in [(0.0, -5000.0), (0.0, 5000.0), (-5000.0, 0.0), (5000.0, 0.0)] {
            let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
            let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                    translation: CGPoint(x: dx, y: dy),
                                                    mapper: m, tool: tool)
            #expect(out != nil, "方向 (\(dx),\(dy)) 夹取返回了 nil")
            let moved = Self.hLine(price: out!.price, candleIndex: out!.candleIndex)
            // ⛔ 判据是「产出 .real」，不是 visibleGeometry != nil —— 后者在 .straight 上空洞成立
            #expect(DrawingNodeDrag.producesRealNode(anchor: out!, in: moved, anchorIndex: 0,
                                                     mapper: m, tool: tool),
                    "方向 (\(dx),\(dy)) 夹取后节点不是 .real")
            if dy != 0 {
                // dy<0（手指往上拖，想要更高价）⇒ 应贴近 priceRange.max；
                // dy>0（往下拖，想要更低价）⇒ 应贴近 priceRange.min。
                let expected = dy < 0 ? m.viewport.priceRange.max : m.viewport.priceRange.min
                #expect(abs(out!.price - expected) < boundaryTolerance,
                        "方向 (\(dx),\(dy)) 夹到了错误的一侧：price=\(out!.price)，期望贴近 \(expected)")
            }
        }
    }

    @Test("N7 `.ray` 右缘：严格 fail-closed ⇒ 夹取必须避开最后一根，线不得整条消失")
    func rayRightEdgeIsFailClosed() {
        let m = DrawingNodeDragDeltaTests.mapper()
        let tool = HorizontalLineTool()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40, sub: .ray)
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                translation: CGPoint(x: 5000, y: 0),
                                                mapper: m, tool: tool)
        #expect(out != nil)
        let moved = Self.hLine(price: out!.price, candleIndex: out!.candleIndex, sub: .ray)
        #expect(HorizontalLineTool.visibleGeometry(for: moved, mapper: m) != nil, "`.ray` 被夹成了不可见")
        #expect(DrawingNodeDrag.producesRealNode(anchor: out!, in: moved, anchorIndex: 0,
                                                 mapper: m, tool: tool))
    }

    @Test("N7 非整像素右缘：`.straight` 线照常可见，坏的是节点变 proxy ⇒ 必须仍能再次抓住")
    func straightNonPixelAlignedRightEdgeKeepsNodeGrabbable() {
        // ⭐ 实证参数：最后一根(79) 未舍入 320.1975 → 舍入 320.3333 > 右缘 320.2；合法最大下标 78
        let m = DrawingNodeDragDeltaTests.mapper()
        let tool = HorizontalLineTool()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                translation: CGPoint(x: 5000, y: 0),
                                                mapper: m, tool: tool)
        #expect(out != nil)
        // ⭐ 修复环第 1 轮 Finding 2：精确值，⛔ 不用 `<= 78` —— 一个「出界一律解析成
        // candleIndex == 0」的退化实现在 `<=78` / visibleGeometry != nil / hitTestNode == 0
        // 这三条断言上全部通过（0 <= 78 恒真；.straight 的可见性不看 x；下标 0 在本 fixture 下
        // 本就合法）。改成精确值才有判别力。
        #expect(out!.candleIndex == 78, "夹到了 \(out!.candleIndex)：边界下标必须在**像素舍入之后**的空间里选")
        let moved = Self.hLine(price: out!.price, candleIndex: out!.candleIndex)
        // ⭐ 关键：`.straight` 的 visibleGeometry 恒非 nil（不看锚点 x）⇒ 只有 hitTestNode 接得住
        #expect(HorizontalLineTool.visibleGeometry(for: moved, mapper: m) != nil)
        let hit = DrawingNodeGeometry.hitTestNode(
            point: CGPoint(x: m.indexToX(out!.candleIndex), y: m.priceToY(out!.price)),
            drawing: moved, mapper: m,
            isVisible: tool.isVisible(drawing: moved, mapper: m),
            maxAnchors: tool.requiredAnchors.upperBound)
        #expect(hit == 0, "夹取后节点抓不住了（变成 proxy）")
    }

    @Test("N7 左缘对称档：往左拖出界 ⇒ 精确夹到 startIndex 那一侧最近合法下标")
    func straightLeftEdgeClampsToStartIndexExactly() {
        // ⭐ 修复环第 1 轮 Finding 2 (b)：只验右缘上界（<=78 或 ==78）测不出方向 ——
        // 「恒夹到 78」的退化实现在右缘测试上一样能通过。这里补左缘对称档，用精确值堵住
        // 「恒返回同一个下标」这一类退化实现。
        // ⭐ 实测（本 fixture）：candleIndex=40 往左拖 5000pt，候选下标越界到远负数，
        // clampIndex 从 clamp 进窗口的 startIndex(=0) 出发向右扫，第一步（candleIndex=0）
        // 就产出 .real ⇒ 唯一合法答案是 0，没有「相邻两根都越界」的歧义。
        let m = DrawingNodeDragDeltaTests.mapper()
        let tool = HorizontalLineTool()
        let d = Self.hLine(price: Self.oddPrice, candleIndex: 40)
        let out = DrawingNodeDrag.draggedAnchor(drawing: d, anchorIndex: 0,
                                                translation: CGPoint(x: -5000, y: 0),
                                                mapper: m, tool: tool)
        #expect(out != nil)
        #expect(out!.candleIndex == m.viewport.startIndex,
                "夹到了 \(out!.candleIndex)：应精确落在 startIndex(=\(m.viewport.startIndex)) 这一侧最近合法下标")
        let moved = Self.hLine(price: out!.price, candleIndex: out!.candleIndex)
        let hit = DrawingNodeGeometry.hitTestNode(
            point: CGPoint(x: m.indexToX(out!.candleIndex), y: m.priceToY(out!.price)),
            drawing: moved, mapper: m,
            isVisible: tool.isVisible(drawing: moved, mapper: m),
            maxAnchors: tool.requiredAnchors.upperBound)
        #expect(hit == 0, "夹取后节点抓不住了（变成 proxy）")
    }
}
