// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift
// Spec: docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md §5.3
// 3 dispatch tests for drawDrawings: empty list / registered tool render-once / missing-tool silent skip.
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
            tools: [.horizontal: spy]
        )
        #expect(spy.renderCallCount == 0)
    }

    @Test("§5.3 #15 registered tool render called once with passed-through anchors")
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
            tools: [.horizontal: spy]
        )
        #expect(spy.renderCallCount == 1)
        #expect(spy.lastAnchors == [anchor])
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
            tools: [:]
        )
        #expect(spy.renderCallCount == 0)
    }
}

// MARK: - Spies / fixtures
// SpyDrawingTool 不需 @unchecked Sendable: protocol DrawingTool 是 @MainActor (Task 1 deviation)，
// 已自带 actor isolation Sendability。

@MainActor
private final class SpyDrawingTool: DrawingTool {
    static var type: DrawingToolType { .horizontal }
    var requiredAnchors: ClosedRange<Int> { 1...1 }
    var renderCallCount = 0
    var lastAnchors: [DrawingAnchor] = []
    func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor]) {
        renderCallCount += 1
        lastAnchors = anchors
    }
    func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool { false }
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
