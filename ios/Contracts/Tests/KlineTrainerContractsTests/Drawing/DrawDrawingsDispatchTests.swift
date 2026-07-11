// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift
// Spec: docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md §5.3
// 3 dispatch tests for drawDrawings: empty list / registered tool render-once / missing-tool silent skip.
// + D35 (Task 1)：样式抵达断言（drawing + scheme 逐条透传，不串味）。
// 本文件使用 KLineView 必须 `#if canImport(UIKit)`；SpyDrawingTool 不需 @unchecked Sendable
// 因 protocol DrawingTool 已改为 @MainActor protocol（Task 1 deviation a80c9df，无 : Sendable）。

import Testing
import CoreGraphics
@testable import KlineTrainerContracts

#if canImport(UIKit)

@MainActor
struct DrawDrawingsDispatchTests {

    @Test("§5.3 #14 drawDrawings with empty list calls no render")
    func drawDrawingsEmptyListNoRenderCalls() {
        let view = makeViewFixture()
        let spy = SpyDrawingTool()
        let ctx = makeCtxFixture()
        let mapper = makeMapperFixture()
        view.drawDrawings(
            ctx: ctx, mapper: mapper, drawings: [], period: .m60,
            scheme: .light, tools: [.horizontal: spy]
        )
        #expect(spy.received.isEmpty)
    }

    @Test("§5.3 #15 registered tool render called once with passed-through drawing")
    func drawDrawingsRegisteredToolRenderCalledOnce() {
        let view = makeViewFixture()
        let spy = SpyDrawingTool()
        let ctx = makeCtxFixture()
        let mapper = makeMapperFixture()
        let anchor = DrawingAnchor(period: .m60, candleIndex: 5, price: 120)
        let drawing = DrawingObject(
            toolType: .horizontal, anchors: [anchor],
            isExtended: false, panelPosition: 0
        )
        view.drawDrawings(
            ctx: ctx, mapper: mapper, drawings: [drawing], period: .m60,
            scheme: .light, tools: [.horizontal: spy]
        )
        #expect(spy.received.count == 1)
        #expect(spy.received.first?.drawing == drawing)
    }

    @Test("§5.3 #16 missing tool in dictionary skips silently (Wave 1 default path)")
    func drawDrawingsMissingToolSkipsSilently() {
        let view = makeViewFixture()
        let spy = SpyDrawingTool()
        let ctx = makeCtxFixture()
        let mapper = makeMapperFixture()
        let drawing = DrawingObject(
            toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m60, candleIndex: 0, price: 100)],
            isExtended: false, panelPosition: 0
        )
        // tools: [:] = Wave 1 default callsite (empty registry).
        view.drawDrawings(
            ctx: ctx, mapper: mapper, drawings: [drawing], period: .m60,
            scheme: .light, tools: [:]
        )
        #expect(spy.received.isEmpty)
    }

    // DrawDrawingsDispatchTests.swift —— SpyDrawingTool 改签名 + 记录【每一次】render 调用（codex plan-medium：
    // 只记 lastDrawing 会让「所有 dispatch 复用第一条」的错误实现蒙混过关）
    @Test("D35：两条不同样式的 drawing 各自带自己的样式 + scheme 按顺序抵达渲染层")
    func drawDrawingsPassesEachDrawingDistinctly() {
        let view = makeViewFixture()
        let spy = SpyDrawingTool()
        let d1 = DrawingObject(toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m60, candleIndex: 5, price: 120)],
            isExtended: false, panelPosition: 0, thickness: 4, colorToken: .blue)
        let d2 = DrawingObject(toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m60, candleIndex: 9, price: 130)],
            isExtended: false, panelPosition: 0, thickness: 2, colorToken: .red)
        view.drawDrawings(ctx: makeCtxFixture(), mapper: makeMapperFixture(),
            drawings: [d1, d2], period: .m60, scheme: .dark, tools: [.horizontal: spy])
        #expect(spy.received.count == 2)
        // 逐条样式各不相同（防「复用第一条 / 样式串味」）
        #expect(spy.received[0].drawing.colorToken == .blue && spy.received[0].drawing.thickness == 4)
        #expect(spy.received[1].drawing.colorToken == .red && spy.received[1].drawing.thickness == 2)
        #expect(spy.received[0].drawing.id != spy.received[1].drawing.id)   // 顺序/身份不被混淆
        #expect(spy.received.allSatisfy { $0.scheme == .dark })
    }

    @MainActor
    @Test("标注 render 路径：.left/.right 画出文字像素；.hidden/.segment 无标注泄漏（codex plan-R5）")
    func labelsRenderOnlyWhenVisible() {
        func labelPixels(_ mode: LabelMode, sub: LineSubType = .straight) -> Int {
            let w = 320, h = 200   // 必须匹配 makeMapperFixture 的 mainChartFrame（320×200），否则线/标注落到画布外（codex plan-R6）
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let d = DrawingObject(toolType: .horizontal,
                anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 150)],   // price 落在 fixture priceRange 100…200 内
                isExtended: false, panelPosition: 0, lineSubType: sub, labelMode: mode)
            makeViewFixture().drawDrawings(ctx: ctx, mapper: makeMapperFixture(),
                drawings: [d], period: .m3, scheme: .light, tools: [.horizontal: HorizontalLineTool()])
            // 每行非透明像素数；最多的行 = 线行（贯穿全宽）。数「距线行 >4」各行的像素 = 标注文字。
            let rowCounts = (0..<h).map { yy in (0..<w).reduce(0) { $0 + (data[(yy*w + $1)*4 + 3] > 60 ? 1 : 0) } }
            let lineRow = rowCounts.firstIndex(of: rowCounts.max() ?? 0) ?? 0
            return rowCounts.enumerated().filter { abs($0.offset - lineRow) > 4 }.map(\.element).reduce(0, +)
        }
        #expect(labelPixels(.left) > 0)                    // 左标注真画出
        #expect(labelPixels(.right) > 0)                   // 右标注真画出
        #expect(labelPixels(.hidden) == 0)                 // 隐藏无泄漏
        #expect(labelPixels(.left, sub: .segment) == 0)    // .segment fail-closed → 连线带标注都不画
    }
}

// MARK: - Spies / fixtures
// SpyDrawingTool 不需 @unchecked Sendable: protocol DrawingTool 是 @MainActor (Task 1 deviation)，
// 已自带 actor isolation Sendability。

@MainActor
private final class SpyDrawingTool: DrawingTool {
    static var type: DrawingToolType { .horizontal }
    var requiredAnchors: ClosedRange<Int> { 1...1 }
    private(set) var received: [(drawing: DrawingObject, scheme: AppColorScheme)] = []
    func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject, scheme: AppColorScheme) {
        received.append((drawing, scheme))
    }
    func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool { false }
}

@MainActor
private func makeViewFixture() -> KLineView {
    KLineView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
}

@MainActor
private func makeCtxFixture() -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

@MainActor
private func makeMapperFixture() -> CoordinateMapper {
    let viewport = ChartViewport(
        startIndex: 0,
        visibleCount: 100,
        pixelShift: 0,
        geometry: ChartGeometry(candleStep: 8, candleWidth: 6, gap: 2),
        priceRange: PriceRange(min: 100, max: 200),
        mainChartFrame: CGRect(x: 0, y: 0, width: 320, height: 200)
    )
    return CoordinateMapper(viewport: viewport, displayScale: 1)
}

#endif
