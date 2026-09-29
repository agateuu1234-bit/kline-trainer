// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingNodeDragSessionTests.swift
// Spec: 2026-09-28-drawing-tools-P1c-3-node-drag-design.md（D135 两半 / D135c 生命周期）
import CoreGraphics
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("P1c-3 拖动态：两半同生同死（D135）")
struct DrawingNodeDragSessionTests {

    static func owner(_ id: DrawingID = "L1") -> DrawingSession.NodeDragOwner {
        .init(panel: .upper, drawingID: id, anchorIndex: 0, grabPoint: CGPoint(x: 10, y: 20))
    }
    static func anchor(_ price: Double) -> DrawingAnchor {
        DrawingAnchor(period: .m15, candleIndex: 40, price: price)
    }

    @Test("占槽 ⇒ 两半同时非空；清槽 ⇒ 两半同时为空")
    func bothHalvesLiveAndDieTogether() {
        let s = DrawingSession()
        #expect(s.nodeDragOwner == nil && s.nodeDragCurrent == nil)   // ⭐ 起点对照
        s.beginNodeDrag(Self.owner(), anchor: Self.anchor(15.5))
        #expect(s.nodeDragOwner != nil && s.nodeDragCurrent != nil)
        s.endNodeDrag()
        #expect(s.nodeDragOwner == nil && s.nodeDragCurrent == nil)
    }

    @Test("每帧更新只动 current，owner 一个字节不变")
    func perFrameUpdateTouchesOnlyCurrent() {
        let s = DrawingSession()
        let o = Self.owner()
        s.beginNodeDrag(o, anchor: Self.anchor(15.5))
        s.updateNodeDragCurrent(Self.anchor(16.5))
        #expect(s.nodeDragCurrent?.price == 16.5)     // ⭐ 反假绿：证明它真的变了
        #expect(s.nodeDragOwner == o)                  // owner 不受影响
    }

    @Test("没占槽时的每帧更新是 no-op（fail-closed，⛔ 不得凭空造出半个拖动态）")
    func updateWithoutOwnerIsNoOp() {
        let s = DrawingSession()
        s.updateNodeDragCurrent(Self.anchor(16.5))
        #expect(s.nodeDragCurrent == nil)
        // ⭐ 反向对照：占槽之后同一次调用**确实**生效
        s.beginNodeDrag(Self.owner(), anchor: Self.anchor(15.5))
        s.updateNodeDragCurrent(Self.anchor(16.5))
        #expect(s.nodeDragCurrent?.price == 16.5)
    }
}
