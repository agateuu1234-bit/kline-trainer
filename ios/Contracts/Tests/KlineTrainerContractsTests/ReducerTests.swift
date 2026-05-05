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

// MARK: - ChartAction / ChartReduceEffect

@Suite("ChartAction Equatable")
struct ChartActionEquatableTests {

    @Test("9 cases 互不相等")
    func allCasesDistinct() {
        let cases: [ChartAction] = [
            .panStarted,
            .panEnded(velocity: 1.0),
            .activateDrawing(.ray),
            .setDrawingSnapshot(tool: .ray, baseRevision: 0, candleRange: 0..<100),
            .drawingCommitted(baseRevision: 0),
            .drawingCancelled(baseRevision: 0),
            .tradeTriggered,
            .periodComboSwitched,
            .offsetApplied(deltaPixels: 1.0),
        ]
        // pairwise inequality
        for i in 0..<cases.count {
            for j in (i+1)..<cases.count {
                #expect(cases[i] != cases[j], "case \(i) vs \(j)")
            }
        }
    }

    @Test("panEnded velocity 区分相等")
    func panEndedVelocity() {
        #expect(ChartAction.panEnded(velocity: 1.0) == ChartAction.panEnded(velocity: 1.0))
        #expect(ChartAction.panEnded(velocity: 1.0) != ChartAction.panEnded(velocity: 2.0))
    }
}

@Suite("ChartReduceEffect Equatable")
struct ChartReduceEffectEquatableTests {

    @Test("5 cases 互不相等")
    func allCasesDistinct() {
        let cases: [ChartReduceEffect] = [
            .none,
            .startDeceleration(velocity: 1.0),
            .clearPendingDrawing,
            .requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 0),
            .staleDrawingSnapshot(expected: 0, actual: 1),
        ]
        for i in 0..<cases.count {
            for j in (i+1)..<cases.count {
                #expect(cases[i] != cases[j], "effect \(i) vs \(j)")
            }
        }
    }
}

// MARK: - reduce: panStarted (3 modes)

@Suite("reduce panStarted")
struct ReducePanStartedTests {

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    @Test("autoTracking → freeScrolling + bump revision")
    func autoToFree() {
        var s = make(.autoTracking, rev: 5)
        let eff = s.reduce(.panStarted)
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("freeScrolling → 无变化, 无 bump")
    func freeNoChange() {
        var s = make(.freeScrolling, rev: 5)
        let eff = s.reduce(.panStarted)
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 5)
        #expect(eff == .none)
    }

    @Test("drawing → 无变化, 无 bump")
    func drawingNoChange() {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: 5)
        var s = make(.drawing(snapshot: DrawingSnapshot(frozen: frozen)), rev: 5)
        let eff = s.reduce(.panStarted)
        guard case .drawing = s.interactionMode else {
            Issue.record("expected drawing mode unchanged after panStarted")
            return
        }
        #expect(s.revision == 5)
        #expect(eff == .none)
    }
}

// MARK: - reduce: panEnded (3 modes)

@Suite("reduce panEnded")
struct ReducePanEndedTests {

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    @Test("autoTracking → 无 bump, 无 effect")
    func autoNoBump() {
        var s = make(.autoTracking, rev: 5)
        let eff = s.reduce(.panEnded(velocity: 3.0))
        #expect(s.revision == 5)
        #expect(eff == .none)
    }

    @Test("freeScrolling → bump + .startDeceleration(v)")
    func freeBumpAndEffect() {
        var s = make(.freeScrolling, rev: 5)
        let eff = s.reduce(.panEnded(velocity: 3.0))
        #expect(s.revision == 6)
        #expect(eff == .startDeceleration(velocity: 3.0))
    }

    @Test("drawing → 无 bump, 无 effect, mode 不变")
    func drawingNoBump() {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: 5)
        var s = make(.drawing(snapshot: DrawingSnapshot(frozen: frozen)), rev: 5)
        let eff = s.reduce(.panEnded(velocity: 3.0))
        guard case .drawing = s.interactionMode else {
            Issue.record("expected drawing mode unchanged after panEnded")
            return
        }
        #expect(s.revision == 5)
        #expect(eff == .none)
    }
}

// MARK: - reduce: tradeTriggered (3 modes 全 bump + 全 → autoTracking)

@Suite("reduce tradeTriggered")
struct ReduceTradeTriggeredTests {

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    @Test("autoTracking → autoTracking + bump")
    func auto() {
        var s = make(.autoTracking, rev: 5)
        let eff = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("freeScrolling → autoTracking + bump")
    func free() {
        var s = make(.freeScrolling, rev: 5)
        let eff = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("drawing → autoTracking + bump")
    func drawing() {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: 5)
        var s = make(.drawing(snapshot: DrawingSnapshot(frozen: frozen)), rev: 5)
        let eff = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }
}

// MARK: - reduce: periodComboSwitched (3 modes 全 bump + 全 → autoTracking + .clearPendingDrawing)

@Suite("reduce periodComboSwitched")
struct ReducePeriodComboTests {

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    @Test("autoTracking → autoTracking + bump + .clearPendingDrawing")
    func auto() {
        var s = make(.autoTracking, rev: 5)
        let eff = s.reduce(.periodComboSwitched)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .clearPendingDrawing)
    }

    @Test("freeScrolling → autoTracking + bump + .clearPendingDrawing")
    func free() {
        var s = make(.freeScrolling, rev: 5)
        let eff = s.reduce(.periodComboSwitched)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .clearPendingDrawing)
    }

    @Test("drawing → autoTracking + bump + .clearPendingDrawing")
    func drawing() {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: 5)
        var s = make(.drawing(snapshot: DrawingSnapshot(frozen: frozen)), rev: 5)
        let eff = s.reduce(.periodComboSwitched)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .clearPendingDrawing)
    }
}

// MARK: - reduce: offsetApplied (autoTracking/freeScrolling bump + drawing 吞)

@Suite("reduce offsetApplied")
struct ReduceOffsetAppliedTests {

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 0, offset: CGFloat = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: offset, revision: rev)
    }

    @Test("autoTracking → offset+=delta + bump")
    func auto() {
        var s = make(.autoTracking, rev: 5, offset: 10)
        let eff = s.reduce(.offsetApplied(deltaPixels: 3))
        #expect(s.offset == 13)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("freeScrolling → offset+=delta + bump")
    func free() {
        var s = make(.freeScrolling, rev: 5, offset: 10)
        let eff = s.reduce(.offsetApplied(deltaPixels: -2))
        #expect(s.offset == 8)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("drawing → 全部忽略，offset / revision / mode 不变")
    func drawingSwallows() {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: 5)
        var s = make(.drawing(snapshot: DrawingSnapshot(frozen: frozen)), rev: 5, offset: 10)
        let eff = s.reduce(.offsetApplied(deltaPixels: 100))
        guard case .drawing = s.interactionMode else {
            Issue.record("expected drawing mode unchanged after offsetApplied")
            return
        }
        #expect(s.offset == 10)
        #expect(s.revision == 5)
        #expect(eff == .none)
    }
}

// MARK: - reduce: drawing-action 占位（PR7a scope = 不 bump revision；PR7b1 替换为真实现）

@Suite("reduce drawing-action 占位 (PR7a scope = 不 bump, 全 3 mode)")
struct ReduceDrawingPlaceholderTests {
    // spec L1157 字面验收：「其它 action 均不 bump」要求覆盖全部 3 mode（autoTracking / freeScrolling / drawing）。
    // PR7a 占位行为 = `case (_, .activateDrawing/.setDrawingSnapshot/.drawingCommitted/.drawingCancelled): return .none`；
    // 4 action × 3 mode = 12 测试。PR7b1 替换占位时此 @Suite 整体改写（assert 真 FSM 行为）。

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 5) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    private func drawing(baseRev: UInt64 = 5) -> ChartInteractionMode {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: baseRev)
        return .drawing(snapshot: DrawingSnapshot(frozen: frozen))
    }

    // —— activateDrawing 占位：3 mode 全不 bump ——

    @Test("activateDrawing autoTracking 不 bump (PR7a 占位)")
    func activateDrawingAutoNoBump() {
        var s = make(.autoTracking)
        _ = s.reduce(.activateDrawing(.ray))
        #expect(s.revision == 5)
    }

    @Test("activateDrawing freeScrolling 不 bump (PR7a 占位)")
    func activateDrawingFreeNoBump() {
        var s = make(.freeScrolling)
        _ = s.reduce(.activateDrawing(.ray))
        #expect(s.revision == 5)
    }

    @Test("activateDrawing drawing 不 bump (PR7a 占位)")
    func activateDrawingDrawingNoBump() {
        var s = make(drawing())
        _ = s.reduce(.activateDrawing(.ray))
        #expect(s.revision == 5)
    }

    // —— setDrawingSnapshot 占位：3 mode 全不 bump ——

    @Test("setDrawingSnapshot autoTracking 不 bump (PR7a 占位)")
    func setDrawingSnapshotAutoNoBump() {
        var s = make(.autoTracking)
        _ = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 5, candleRange: 0..<100))
        #expect(s.revision == 5)
    }

    @Test("setDrawingSnapshot freeScrolling 不 bump (PR7a 占位)")
    func setDrawingSnapshotFreeNoBump() {
        var s = make(.freeScrolling)
        _ = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 5, candleRange: 0..<100))
        #expect(s.revision == 5)
    }

    @Test("setDrawingSnapshot drawing 不 bump (PR7a 占位)")
    func setDrawingSnapshotDrawingNoBump() {
        var s = make(drawing())
        _ = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 5, candleRange: 0..<100))
        #expect(s.revision == 5)
    }

    // —— drawingCommitted 占位：3 mode 全不 bump ——

    @Test("drawingCommitted autoTracking 不 bump (PR7a 占位)")
    func drawingCommittedAutoNoBump() {
        var s = make(.autoTracking)
        _ = s.reduce(.drawingCommitted(baseRevision: 5))
        #expect(s.revision == 5)
    }

    @Test("drawingCommitted freeScrolling 不 bump (PR7a 占位)")
    func drawingCommittedFreeNoBump() {
        var s = make(.freeScrolling)
        _ = s.reduce(.drawingCommitted(baseRevision: 5))
        #expect(s.revision == 5)
    }

    @Test("drawingCommitted drawing 不 bump (PR7a 占位)")
    func drawingCommittedDrawingNoBump() {
        var s = make(drawing())
        _ = s.reduce(.drawingCommitted(baseRevision: 5))
        #expect(s.revision == 5)
    }

    // —— drawingCancelled 占位：3 mode 全不 bump ——

    @Test("drawingCancelled autoTracking 不 bump (PR7a 占位)")
    func drawingCancelledAutoNoBump() {
        var s = make(.autoTracking)
        _ = s.reduce(.drawingCancelled(baseRevision: 5))
        #expect(s.revision == 5)
    }

    @Test("drawingCancelled freeScrolling 不 bump (PR7a 占位)")
    func drawingCancelledFreeNoBump() {
        var s = make(.freeScrolling)
        _ = s.reduce(.drawingCancelled(baseRevision: 5))
        #expect(s.revision == 5)
    }

    @Test("drawingCancelled drawing 不 bump (PR7a 占位)")
    func drawingCancelledDrawingNoBump() {
        var s = make(drawing())
        _ = s.reduce(.drawingCancelled(baseRevision: 5))
        #expect(s.revision == 5)
    }
}

// MARK: - revision UInt64 wrap 防御

@Suite("revision UInt64 overflow")
struct RevisionWrapTests {

    @Test("UInt64.max &+= 1 wrap 到 0（reducer 用 &+= 不应 trap）")
    func wrapsAtMax() {
        // spec L1099-1102: tradeTriggered bumps unconditionally even when mode unchanged.
        // 这里 autoTracking → autoTracking（mode 不变）但 revision 仍然 &+= 1。
        // UInt64.max &+ 1 = 0（Swift `&+=` 是有意 wrap 而非 trap，避免 reducer 长寿命会话崩溃）。
        var s = PanelViewState(period: .m15, interactionMode: .autoTracking,
                               visibleCount: 100, offset: 0, revision: UInt64.max)
        let eff = s.reduce(.tradeTriggered)
        #expect(s.revision == 0)
        #expect(eff == .none)
    }
}
