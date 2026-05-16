// Kline Trainer Swift Contracts — C1c KLineRenderState Tests
// Spec: kline_trainer_modules_v1.4.md §六 C1c (L1219-1229, L1240)
// Covers: .empty defaults, Equatable auto-synthesis, Sendable crossing.
//
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
        // self-review fix #1: frame + viewport 默认值断言（防 .empty 静默回归）
        #expect(s.frames.mainChart == .zero)
        #expect(s.viewport.visibleCount == 0)
    }

    @Test("Equatable 自动合成：两个 .empty 实例 == 为 true")
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
