// Kline Trainer C1b — Reducer Tests
// Spec: kline_trainer_modules_v1.4.md §C1b L957-1131 + L1136-1144 (ChartAction) + L1209 (验收 #1)
// Plan: docs/superpowers/plans/2026-05-05-pr7a-c1b-values-revision.md
// Scope: PR7a = 值类型 + freeze + 5 非-drawing reducer case + revision 单调性。
//        Drawing FSM (activateDrawing / setDrawingSnapshot / drawingCommitted / drawingCancelled)
//        + 27 格矩阵 + 3 漂移 + cross-session guard + animator 集成 → PR7b1/7b2/7b3。

import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

// MARK: - PanelViewState

@Suite("PanelViewState")
struct PanelViewStateTests {

    @Test("init + Equatable auto-synth")
    func initAndEquatable() {
        let a = PanelViewState(period: .m15, interactionMode: .autoTracking,
                               visibleCount: 100, offset: 0, revision: 0)
        let b = PanelViewState(period: .m15, interactionMode: .autoTracking,
                               visibleCount: 100, offset: 0, revision: 0)
        let c = PanelViewState(period: .m60, interactionMode: .autoTracking,
                               visibleCount: 100, offset: 0, revision: 0)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Equatable 区分 revision")
    func equatableDistinguishesRevision() {
        let a = PanelViewState(period: .m15, interactionMode: .autoTracking,
                               visibleCount: 100, offset: 0, revision: 0)
        let b = PanelViewState(period: .m15, interactionMode: .autoTracking,
                               visibleCount: 100, offset: 0, revision: 1)
        #expect(a != b)
    }

    @Test("Equatable 区分 interactionMode")
    func equatableDistinguishesMode() {
        let a = PanelViewState(period: .m15, interactionMode: .autoTracking,
                               visibleCount: 100, offset: 0, revision: 0)
        let b = PanelViewState(period: .m15, interactionMode: .freeScrolling,
                               visibleCount: 100, offset: 0, revision: 0)
        #expect(a != b)
    }
}

// MARK: - ChartInteractionMode

@Suite("ChartInteractionMode")
struct ChartInteractionModeTests {

    @Test("autoTracking == autoTracking")
    func autoEqual() {
        #expect(ChartInteractionMode.autoTracking == ChartInteractionMode.autoTracking)
    }

    @Test("freeScrolling != autoTracking")
    func freeNeqAuto() {
        #expect(ChartInteractionMode.freeScrolling != ChartInteractionMode.autoTracking)
    }

    @Test("drawing 区分 snapshot.baseRevision")
    func drawingDistinctByBaseRev() {
        let f0 = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                  candleRange: 0..<100, baseRevision: 0)
        let f1 = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                  candleRange: 0..<100, baseRevision: 1)
        let m0 = ChartInteractionMode.drawing(snapshot: DrawingSnapshot(frozen: f0))
        let m1 = ChartInteractionMode.drawing(snapshot: DrawingSnapshot(frozen: f1))
        #expect(m0 != m1)
    }
}

// MARK: - FrozenPanelState

@Suite("FrozenPanelState")
struct FrozenPanelStateTests {

    @Test("init + Equatable")
    func initAndEquatable() {
        let a = FrozenPanelState(period: .m15, visibleCount: 100, offset: 5,
                                 candleRange: 0..<100, baseRevision: 7)
        let b = FrozenPanelState(period: .m15, visibleCount: 100, offset: 5,
                                 candleRange: 0..<100, baseRevision: 7)
        #expect(a == b)
        #expect(a.baseRevision == 7)
    }

    @Test("Equatable 区分 candleRange")
    func equatableDistinguishesRange() {
        let a = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                 candleRange: 0..<100, baseRevision: 0)
        let b = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                 candleRange: 1..<101, baseRevision: 0)
        #expect(a != b)
    }
}

// MARK: - DrawingSnapshot

@Suite("DrawingSnapshot")
struct DrawingSnapshotTests {

    @Test("init + Equatable 透传 frozen")
    func initAndEquatable() {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: 3)
        let a = DrawingSnapshot(frozen: frozen)
        let b = DrawingSnapshot(frozen: frozen)
        #expect(a == b)
        #expect(a.frozen.baseRevision == 3)
    }
}

// MARK: - freeze()

@Suite("PanelViewState.freeze")
struct FreezeTests {

    @Test("freeze 捕捉当前 revision 到 baseRevision")
    func freezeCapturesRevision() {
        let state = PanelViewState(period: .m15, interactionMode: .autoTracking,
                                   visibleCount: 100, offset: 5, revision: 42)
        let frozen = state.freeze(candleRange: 0..<100)
        #expect(frozen.baseRevision == 42)
    }

    @Test("freeze 透传 period / visibleCount / offset")
    func freezePassesThrough() {
        let state = PanelViewState(period: .m60, interactionMode: .autoTracking,
                                   visibleCount: 200, offset: 7.5, revision: 3)
        let frozen = state.freeze(candleRange: 50..<250)
        #expect(frozen.period == .m60)
        #expect(frozen.visibleCount == 200)
        #expect(frozen.offset == 7.5)
        #expect(frozen.candleRange == 50..<250)
    }
}
