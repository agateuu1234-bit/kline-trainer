// Wave 3 顺位 4：engine 画线 FSM 退出（commitDrawing/cancelDrawing）。
// 复用 TrainingEngineInteractionTests.engine()（单 .m3 双面板 + fake 驱动）。
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingEngine drawing commit/cancel（FSM 退出，Wave 3 顺位 4）")
struct TrainingEngineDrawingCommitTests {

    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// 进入 .drawing 的 engine（activateDrawingTool 已验证进 drawing）。
    static func drawingEngine() -> TrainingEngine {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.activateDrawingTool(.horizontal, panel: .upper)
        return e
    }

    @Test("commitDrawing: .drawing → .autoTracking + revision 不变（核 Reducer:203-208 不 bump）")
    func commitExitsToAutoTrackingNoRevisionBump() {
        let e = Self.drawingEngine()
        guard case .drawing = e.upperPanel.interactionMode else { Issue.record("应在 drawing"); return }
        let revBefore = e.upperPanel.revision
        e.commitDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision == revBefore)             // commit 不 bump revision
    }

    @Test("cancelDrawing: .drawing → .autoTracking + revision 不变")
    func cancelExitsToAutoTrackingNoRevisionBump() {
        let e = Self.drawingEngine()
        let revBefore = e.upperPanel.revision
        e.cancelDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision == revBefore)
    }

    @Test("commitDrawing: 非 drawing 态 → no-op（autoTracking 不变）")
    func commitNonDrawingNoOp() {
        let (e, _) = TrainingEngineInteractionTests.engine()        // autoTracking
        let revBefore = e.upperPanel.revision
        e.commitDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision == revBefore)
    }

    @Test("cancelDrawing: 非 drawing 态 → no-op")
    func cancelNonDrawingNoOp() {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.cancelDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
    }

    @Test("append 与 commit 独立：appendDrawing 不改 mode；commitDrawing 不改 drawings")
    func appendAndCommitAreIndependent() {
        let e = Self.drawingEngine()
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.4)],
                              isExtended: true, panelPosition: 0)
        e.appendDrawing(d)
        #expect({ if case .drawing = e.upperPanel.interactionMode { return true }; return false }())  // append 不改 mode
        #expect(e.drawings == [d])
        e.commitDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.drawings == [d])                                 // commit 不改 drawings
    }
}
