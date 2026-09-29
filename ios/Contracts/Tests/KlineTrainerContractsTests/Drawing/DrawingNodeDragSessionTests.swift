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

@MainActor
@Suite("P1c-3 拖动进行中点击不改选中（D135c）")
struct NodeDragSelectionGateTests {

    static func armedSession() -> DrawingSession {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.setMode(.select)
        s.setSelection(id: "A", panel: .upper)
        s.beginNodeDrag(.init(panel: .upper, drawingID: "A", anchorIndex: 0,
                              grabPoint: CGPoint(x: 10, y: 20)),
                        anchor: DrawingAnchor(period: .m15, candleIndex: 40, price: 15.5))
        return s
    }

    @Test("T14① 拖动中 setSelection ⇒ 选中**仍是 A**（正面断言，⛔ 不是「没崩」）")
    func tapSelectionIsBlockedDuringDrag() {
        let s = Self.armedSession()
        s.setSelection(id: "B", panel: .lower)
        #expect(s.selectedDrawingID == "A")
        #expect(s.selectedPanel == .upper)
        #expect(s.nodeDragOwner != nil)          // 拖动态没被顺手清掉
    }

    @Test("T14④ 抬手之后再选 B ⇒ 这时选中**才**变（①的对照，缺了它「选中整个坏掉」也全绿）")
    func tapSelectionWorksAfterDragEnds() {
        let s = Self.armedSession()
        s.endNodeDrag()
        s.setSelection(id: "B", panel: .lower)
        #expect(s.selectedDrawingID == "B")
        #expect(s.selectedPanel == .lower)
    }

    @Test("T14b 生命周期清理连带丢弃拖动态：退画线 / setMode / clearSelection 各一档")
    func lifecycleCleanupDiscardsDrag() {
        for trigger in ["deactivate", "setMode", "clearSelection"] {
            let s = Self.armedSession()
            #expect(s.nodeDragOwner != nil)      // ⭐ 正面对照：先证明它确实建立过
            switch trigger {
            case "deactivate":     s.deactivate()
            case "setMode":        s.setMode(.draw)
            default:               s.clearSelection()
            }
            #expect(s.nodeDragOwner == nil, "\(trigger) 之后拖动态没被丢弃")
            #expect(s.nodeDragCurrent == nil, "\(trigger) 之后 current 没被丢弃")
        }
    }
}
