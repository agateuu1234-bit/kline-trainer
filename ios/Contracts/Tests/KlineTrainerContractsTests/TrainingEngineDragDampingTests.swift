// TrainingEngineDragDampingTests.swift（新文件头）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingEngine drag 跟手橡皮筋阻尼（R1b-drag）", .serialized)
struct TrainingEngineDragDampingTests {
    static let bounds = TrainingEngineBounceWiringTests.bounds
    static func makeEngine() -> (TrainingEngine, () -> [FakeFrameDriver]) {
        TrainingEngineBounceWiringTests.makeEngine(count: 200, tick: 150)
    }

    @Test("dragRaw 生命周期：beginPan seed=offset / endPan·cancelPan 清 / 两面板独立")
    func dragRawLifecycle() {
        let (e, _) = Self.makeEngine()
        #expect(e.debug_dragRawFor(.upper) == nil)
        e.beginPan(panel: .upper)
        #expect(e.debug_dragRawFor(.upper) == e.upperPanel.offset)   // seed=归一后 offset
        #expect(e.debug_dragRawFor(.lower) == nil)                   // 面板独立
        e.endPan(velocity: 0, renderBounds: Self.bounds, panel: .upper)
        #expect(e.debug_dragRawFor(.upper) == nil)                   // endPan 清
        e.beginPan(panel: .lower)
        e.cancelPan(panel: .lower)
        #expect(e.debug_dragRawFor(.lower) == nil)                   // cancelPan 清
    }
}
