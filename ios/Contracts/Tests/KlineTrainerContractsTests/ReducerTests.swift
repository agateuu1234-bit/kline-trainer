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

// MARK: - reduce: activateDrawing (3 modes; PR7b1 replaces PR7a placeholder)

@Suite("reduce activateDrawing")
struct ReduceActivateDrawingTests {

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    private func drawingMode(baseRev: UInt64 = 5) -> ChartInteractionMode {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: baseRev)
        return .drawing(snapshot: DrawingSnapshot(frozen: frozen))
    }

    @Test("autoTracking → 不 bump + .requestDrawingSnapshotAfterStoppingAnimator(tool, revision)")
    func autoEffect() {
        var s = make(.autoTracking, rev: 5)
        let eff = s.reduce(.activateDrawing(.ray))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 5)
        #expect(eff == .requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 5))
    }

    @Test("freeScrolling → 不 bump + .requestDrawingSnapshotAfterStoppingAnimator(tool, revision)")
    func freeEffect() {
        var s = make(.freeScrolling, rev: 7)
        let eff = s.reduce(.activateDrawing(.trend))
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 7)
        #expect(eff == .requestDrawingSnapshotAfterStoppingAnimator(tool: .trend, baseRevision: 7))
    }

    @Test("drawing → 不 bump + .none（DrawingToolManager 处理切工具）")
    func drawingNoChange() {
        var s = make(drawingMode(baseRev: 5), rev: 5)
        let eff = s.reduce(.activateDrawing(.horizontal))
        guard case .drawing = s.interactionMode else {
            Issue.record("expected drawing mode unchanged after activateDrawing")
            return
        }
        #expect(s.revision == 5)
        #expect(eff == .none)
    }
}

// MARK: - reduce: setDrawingSnapshot (3 modes happy / matched only; PR7b2 cover stale)

@Suite("reduce setDrawingSnapshot")
struct ReduceSetDrawingSnapshotTests {

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    private func drawingMode(baseRev: UInt64 = 5) -> ChartInteractionMode {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: baseRev)
        return .drawing(snapshot: DrawingSnapshot(frozen: frozen))
    }

    @Test("autoTracking + matched baseRev → drawing(snap) + 不 bump + .none")
    func autoMatchedEntersDrawing() {
        var s = make(.autoTracking, rev: 5)
        let eff = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 5, candleRange: 10..<110))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode after matched setDrawingSnapshot")
            return
        }
        #expect(snap.frozen.period == .m15)
        #expect(snap.frozen.visibleCount == 100)
        #expect(snap.frozen.offset == 0)
        #expect(snap.frozen.candleRange == 10..<110)
        #expect(snap.frozen.baseRevision == 5)
        #expect(s.revision == 5)
        #expect(eff == .none)
    }

    @Test("freeScrolling + matched baseRev → drawing(snap) + 不 bump + .none")
    func freeMatchedEntersDrawing() {
        var s = make(.freeScrolling, rev: 7)
        let eff = s.reduce(.setDrawingSnapshot(tool: .trend, baseRevision: 7, candleRange: 0..<50))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode after matched setDrawingSnapshot")
            return
        }
        #expect(snap.frozen.candleRange == 0..<50)
        #expect(snap.frozen.baseRevision == 7)
        #expect(s.revision == 7)
        #expect(eff == .none)
    }

    @Test("drawing → 不变 + 不 bump + .none（DrawingToolManager 处理切工具；distinguishing fixture 守'未重入'）")
    func drawingNoReentry() {
        // R1 H-3 修订：fixture 与 reduce 参数 candleRange / offset 不同；
        // 若 prod 错把 drawing 模式重入新 snap，新 snap 会带 reduce 参数 candleRange=200..<300
        // 而非 fixture 0..<100；fixture frozen.offset=0 vs PanelViewState.offset=99 同理（注：
        // setDrawingSnapshot 字面落地时新 snap 用 PanelViewState.offset 而非 frozen 旧值）。
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: 5)
        var s = PanelViewState(period: .m15,
                               interactionMode: .drawing(snapshot: DrawingSnapshot(frozen: frozen)),
                               visibleCount: 100, offset: 99, revision: 5)
        let eff = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 5, candleRange: 200..<300))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode unchanged")
            return
        }
        #expect(snap.frozen.candleRange == 0..<100)  // fixture 值，证明未重入
        #expect(snap.frozen.offset == 0)              // 同上
        #expect(snap.frozen.baseRevision == 5)
        #expect(s.revision == 5)
        #expect(eff == .none)
    }
}

// MARK: - reduce: drawingCommitted (drawing-matched + drawing-unmatched cross-session guard;
//                                   auto/free assertion paths 不直接 unit test, see plan §2)

@Suite("reduce drawingCommitted")
struct ReduceDrawingCommittedTests {

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    private func drawingMode(baseRev: UInt64 = 5) -> ChartInteractionMode {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: baseRev)
        return .drawing(snapshot: DrawingSnapshot(frozen: frozen))
    }

    @Test("drawing(snap.baseRev=r) + drawingCommitted(baseRev=r) → autoTracking + 不 bump + .none")
    func drawingMatchedExits() {
        var s = make(drawingMode(baseRev: 5), rev: 5)
        let eff = s.reduce(.drawingCommitted(baseRevision: 5))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 5)
        #expect(eff == .none)
    }

    @Test("drawing(snap.baseRev=r) + drawingCommitted(baseRev != r) → mode 不变 + 不 bump + .none（cross-session 丢弃）")
    func drawingUnmatchedKeepsSession() {
        // spec L1163-1166 验收 #4：session A 遗留 drawingCommitted(baseRev=0)
        // 在新 session B drawing(snap.baseRev=1) 时到达 → guard `base != snap.frozen.baseRevision`
        // → 丢弃返回 .none，mode 仍为 drawing（不错误切出 session B）
        var s = make(drawingMode(baseRev: 1), rev: 1)
        let eff = s.reduce(.drawingCommitted(baseRevision: 0))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode unchanged after unmatched commit")
            return
        }
        #expect(snap.frozen.baseRevision == 1)  // session B snap 不变
        #expect(s.revision == 1)
        #expect(eff == .none)
    }
}

// MARK: - reduce: drawingCancelled (drawing-matched + drawing-unmatched cross-session guard;
//                                   same scope notes as committed)

@Suite("reduce drawingCancelled")
struct ReduceDrawingCancelledTests {

    private func make(_ mode: ChartInteractionMode, rev: UInt64 = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    private func drawingMode(baseRev: UInt64 = 5) -> ChartInteractionMode {
        let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                      candleRange: 0..<100, baseRevision: baseRev)
        return .drawing(snapshot: DrawingSnapshot(frozen: frozen))
    }

    @Test("drawing(snap.baseRev=r) + drawingCancelled(baseRev=r) → autoTracking + 不 bump + .none")
    func drawingMatchedExits() {
        var s = make(drawingMode(baseRev: 5), rev: 5)
        let eff = s.reduce(.drawingCancelled(baseRevision: 5))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 5)
        #expect(eff == .none)
    }

    @Test("drawing(snap.baseRev=r) + drawingCancelled(baseRev != r) → mode 不变 + 不 bump + .none（cross-session 丢弃）")
    func drawingUnmatchedKeepsSession() {
        // spec L1163-1166 验收 #4 cancel 分支：session A 遗留 drawingCancelled(baseRev=0)
        // 在新 session B drawing(snap.baseRev=1) 时到达 → guard 丢弃保持 session B
        var s = make(drawingMode(baseRev: 1), rev: 1)
        let eff = s.reduce(.drawingCancelled(baseRevision: 0))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode unchanged after unmatched cancel")
            return
        }
        #expect(snap.frozen.baseRevision == 1)
        #expect(s.revision == 1)
        #expect(eff == .none)
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
