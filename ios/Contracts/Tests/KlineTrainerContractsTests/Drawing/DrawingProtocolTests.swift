// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingProtocolTests.swift
// Spec: docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md §5.2
// 3 protocol contract tests. Verifies DrawingTool + DrawingInputController conformance shape.

import Testing
import CoreGraphics
@testable import KlineTrainerContracts

// 跨平台测试：仅依赖 CoreGraphics + 跨平台值类型（CoordinateMapper / ChartViewport /
// ChartGeometry / PriceRange / PanelViewState / DrawingAnchor / DrawingToolType）；
// 无 UIKit 依赖。在 macOS host `swift test` 跑得通，Catalyst CI 也跑得通。

@MainActor
struct DrawingProtocolTests {

    @Test("§5.2 #11 FakeDrawingTool conforms to DrawingTool (4 members reachable)")
    func fakeDrawingToolConforms() {
        let tool: any DrawingTool = FakeDrawingTool()
        #expect(type(of: tool).type == .horizontal)
        #expect(tool.requiredAnchors == 1...1)
        // render / hitTest reachable through dynamic dispatch
        let mapper = makeMapperFixture()
        let ctx = makeCtxFixture()
        let drawing = DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        tool.render(ctx: ctx, mapper: mapper, drawing: drawing, scheme: .light)
        let hit = tool.hitTest(point: .zero, mapper: mapper, drawing: drawing)
        #expect(hit == false)
    }

    @Test("§5.2 #12 requiredAnchors is ClosedRange<Int> (lower & upper both contained)")
    func requiredAnchorsRangeIsClosed() {
        let tool = FakeDrawingTool()
        let r = tool.requiredAnchors
        #expect(r.contains(r.lowerBound))
        #expect(r.contains(r.upperBound))
        // Compile-time guard: assignment to ClosedRange<Int> would fail if it were Range<Int>
        let _: ClosedRange<Int> = r
    }

    @Test("§5.2 #13 FakeInputController conforms to DrawingInputController (2 methods callable)")
    func fakeInputControllerConforms() {
        let ctrl: any DrawingInputController = FakeInputController()
        let mapper = makeMapperFixture()
        let panel = makePanelFixture()
        let anchor = ctrl.tapToAnchor(at: .zero, panel: panel, mapper: mapper)
        #expect(anchor.candleIndex == 0)
        #expect(anchor.price == 0)
        let shouldCommit = ctrl.shouldCommit(current: [anchor], tool: .horizontal)
        #expect(shouldCommit == true)
    }
}

// MARK: - Test fakes
// protocol DrawingTool 是 @MainActor 隔离（无 : Sendable 要求），fake 类只需 @MainActor。

@MainActor
private final class FakeDrawingTool: DrawingTool {
    static var type: DrawingToolType { .horizontal }
    var requiredAnchors: ClosedRange<Int> { 1...1 }
    func render(ctx: CGContext, mapper: CoordinateMapper, drawing: DrawingObject, scheme: AppColorScheme) {}
    func hitTest(point: CGPoint, mapper: CoordinateMapper, drawing: DrawingObject) -> Bool { false }
}

@MainActor
private final class FakeInputController: DrawingInputController {
    func tapToAnchor(at point: CGPoint, panel: PanelViewState, mapper: CoordinateMapper) -> DrawingAnchor {
        DrawingAnchor(period: .m60, candleIndex: 0, price: 0)
    }
    func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool {
        !current.isEmpty
    }
}

// MARK: - Fixtures
// fixture 形状对齐 GeometryTests.swift L210-219 + ReducerTests.swift L20-21 既有 pattern

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

@MainActor
private func makeCtxFixture() -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

@MainActor
private func makePanelFixture() -> PanelViewState {
    PanelViewState(
        period: .m60,
        interactionMode: .autoTracking,
        visibleCount: 100,
        offset: 0,
        revision: 0
    )
}
