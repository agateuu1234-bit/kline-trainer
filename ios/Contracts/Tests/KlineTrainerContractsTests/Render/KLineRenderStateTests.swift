import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("KLineRenderState")
struct KLineRenderStateTests {
    @Test("empty default has zero-sized frames and zero-revision panel")
    func emptyDefault() {
        let s = KLineRenderState.empty
        #expect(s.panel.revision == 0)
        #expect(s.visibleCandles.isEmpty)
        #expect(s.markers.isEmpty)
        #expect(s.drawings.isEmpty)
        #expect(s.crosshairPoint == nil)
    }

    @Test("Equatable 短路：相等 instances 之间 == 为 true（didSet 不触发）")
    func equatableShortCircuit() {
        let a = KLineRenderState.empty
        let b = KLineRenderState.empty
        #expect(a == b)
    }

    @Test("Equatable 区分：crosshairPoint 不同 → !=")
    func equatableDistinguishCrosshair() {
        // codex R2 finding 2 修复（v3）：字段已改 `let`，用 init 重建而非 mutate
        let a = KLineRenderState.empty
        let b = KLineRenderState(
            panel: a.panel, frames: a.frames, viewport: a.viewport,
            visibleCandles: a.visibleCandles,
            volumeRange: a.volumeRange, macdRange: a.macdRange,
            markers: a.markers, drawings: a.drawings,
            crosshairPoint: CGPoint(x: 100, y: 200))
        #expect(a != b)
    }

    @Test("Sendable 编译断言：KLineRenderState 可跨 async 边界")
    func sendableAcrossActor() async {
        let s = KLineRenderState.empty
        let captured = await Task.detached { s }.value
        #expect(captured == s)
    }
}
