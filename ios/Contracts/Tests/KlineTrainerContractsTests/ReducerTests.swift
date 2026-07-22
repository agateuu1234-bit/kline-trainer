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

// MARK: - File-level test helpers (extracted in PR7b2 from per-Suite copies)

/// 构造 `PanelViewState` 的统一测试 fixture。
/// 默认 visibleCount=100、offset=0、revision=0；可覆写。
/// PR7b2 抽自 9 个 Suite 内 `private func make` copy（PR7b1 plan §4 R1 M-4 技术债）。
private func makePanel(_ mode: ChartInteractionMode,
                       rev: UInt64 = 0,
                       offset: CGFloat = 0) -> PanelViewState {
    PanelViewState(period: .m15, interactionMode: mode,
                   visibleCount: 100, offset: offset, revision: rev)
}

/// 构造 drawing 模式 fixture（candleRange: 0..<100, offset: 0, baseRev 可调）。
/// PR7b2 抽自 4 个 Suite 内 `private func drawingMode` copy。
private func makeDrawingMode(baseRev: UInt64 = 5) -> ChartInteractionMode {
    let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                  candleRange: 0..<100, baseRevision: baseRev)
    return .drawing(snapshot: DrawingSnapshot(frozen: frozen))
}

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

    @Test("autoTracking → freeScrolling + bump revision")
    func autoToFree() {
        var s = makePanel(.autoTracking, rev: 5)
        let eff = s.reduce(.panStarted)
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("freeScrolling → 无变化, 无 bump")
    func freeNoChange() {
        var s = makePanel(.freeScrolling, rev: 5)
        let eff = s.reduce(.panStarted)
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 5)
        #expect(eff == .none)
    }

    @Test("drawing → 无变化, 无 bump")
    func drawingNoChange() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5)
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

    @Test("autoTracking → 无 bump, 无 effect")
    func autoNoBump() {
        var s = makePanel(.autoTracking, rev: 5)
        let eff = s.reduce(.panEnded(velocity: 3.0))
        #expect(s.revision == 5)
        #expect(eff == .none)
    }

    @Test("freeScrolling → bump + .startDeceleration(v)")
    func freeBumpAndEffect() {
        var s = makePanel(.freeScrolling, rev: 5)
        let eff = s.reduce(.panEnded(velocity: 3.0))
        #expect(s.revision == 6)
        #expect(eff == .startDeceleration(velocity: 3.0))
    }

    @Test("drawing → bump + .startDeceleration(v)（1a-iv 视口解冻：画线时松手也要有惯性/回弹，否则橡皮筋越界回不来）")
    func drawingBumpAndEffect() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5)
        let eff = s.reduce(.panEnded(velocity: 3.0))
        guard case .drawing = s.interactionMode else {
            Issue.record("panEnded 不得把面板踢出 .drawing（会话仍开着）")
            return
        }
        #expect(s.revision == 6)
        #expect(eff == .startDeceleration(velocity: 3.0))
    }
}

// MARK: - reduce: tradeTriggered (3 modes 全 bump + 全 → autoTracking)

@Suite("reduce tradeTriggered")
struct ReduceTradeTriggeredTests {

    @Test("autoTracking → autoTracking + bump")
    func auto() {
        var s = makePanel(.autoTracking, rev: 5)
        let eff = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("freeScrolling → autoTracking + bump")
    func free() {
        var s = makePanel(.freeScrolling, rev: 5)
        let eff = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("drawing → autoTracking + bump")
    func drawing() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5)
        let eff = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }
}

// MARK: - reduce: periodComboSwitched (3 modes 全 bump + 全 → autoTracking + .clearPendingDrawing)

@Suite("reduce periodComboSwitched")
struct ReducePeriodComboTests {

    @Test("autoTracking → autoTracking + bump + .clearPendingDrawing")
    func auto() {
        var s = makePanel(.autoTracking, rev: 5)
        let eff = s.reduce(.periodComboSwitched)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .clearPendingDrawing)
    }

    @Test("freeScrolling → autoTracking + bump + .clearPendingDrawing")
    func free() {
        var s = makePanel(.freeScrolling, rev: 5)
        let eff = s.reduce(.periodComboSwitched)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .clearPendingDrawing)
    }

    @Test("drawing → autoTracking + bump + .clearPendingDrawing")
    func drawing() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5)
        let eff = s.reduce(.periodComboSwitched)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff == .clearPendingDrawing)
    }
}

// MARK: - reduce: offsetApplied (autoTracking/freeScrolling/drawing 三态均 += delta + bump)

@Suite("reduce offsetApplied")
struct ReduceOffsetAppliedTests {

    @Test("autoTracking → offset+=delta + bump")
    func auto() {
        var s = makePanel(.autoTracking, rev: 5, offset: 10)
        let eff = s.reduce(.offsetApplied(deltaPixels: 3))
        #expect(s.offset == 13)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("freeScrolling → offset+=delta + bump")
    func free() {
        var s = makePanel(.freeScrolling, rev: 5, offset: 10)
        let eff = s.reduce(.offsetApplied(deltaPixels: -2))
        #expect(s.offset == 8)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }

    @Test("drawing → offset += delta + bump（1a-iv 视口解冻；1a-iii 及以前恒被吞）")
    func drawingApplies() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5, offset: 10)
        let eff = s.reduce(.offsetApplied(deltaPixels: 100))
        guard case .drawing = s.interactionMode else {
            Issue.record("offsetApplied 不得把面板踢出 .drawing（会话仍开着）")
            return
        }
        #expect(s.offset == 110)
        #expect(s.revision == 6)
        #expect(eff == .none)
    }
}

// MARK: - reduce: activateDrawing (3 modes; PR7b1 replaces PR7a placeholder)

@Suite("reduce activateDrawing")
struct ReduceActivateDrawingTests {

    @Test("autoTracking → 不 bump + .requestDrawingSnapshotAfterStoppingAnimator(tool, revision)")
    func autoEffect() {
        var s = makePanel(.autoTracking, rev: 5)
        let eff = s.reduce(.activateDrawing(.ray))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 5)
        #expect(eff == .requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 5))
    }

    @Test("freeScrolling → 不 bump + .requestDrawingSnapshotAfterStoppingAnimator(tool, revision)")
    func freeEffect() {
        var s = makePanel(.freeScrolling, rev: 7)
        let eff = s.reduce(.activateDrawing(.trend))
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 7)
        #expect(eff == .requestDrawingSnapshotAfterStoppingAnimator(tool: .trend, baseRevision: 7))
    }

    @Test("drawing → 不 bump + .none（DrawingToolManager 处理切工具）")
    func drawingNoChange() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5)
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

    @Test("autoTracking + matched baseRev → drawing(snap) + 不 bump + .none")
    func autoMatchedEntersDrawing() {
        var s = makePanel(.autoTracking, rev: 5)
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
        var s = makePanel(.freeScrolling, rev: 7)
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

    @Test("drawing(snap.baseRev=r) + drawingCommitted(baseRev=r) → autoTracking + 不 bump + .none")
    func drawingMatchedExits() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5)
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
        var s = makePanel(makeDrawingMode(baseRev: 1), rev: 1)
        let eff = s.reduce(.drawingCommitted(baseRevision: 0))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode unchanged after unmatched commit")
            return
        }
        #expect(snap.frozen.baseRevision == 1)  // session B snap 不变
        #expect(s.revision == 1)
        #expect(eff == .none)
    }

    @Test("drawing(snap.baseRev=5) + state.rev=99 + drawingCommitted(base=99) → guard 读 snap.baseRev 而非 state.rev → mode 不变 + .none")
    func drawingCommittedReadsSnapshotNotRevision() {
        // R3 high-1 修订：distinguishing fixture where state.revision != snap.frozen.baseRevision。
        // 守 prod guard literal `guard base == snap.frozen.baseRevision`：
        //   - 真 guard: base(99) == snap.baseRev(5) → false → guard 失败 → return .none → mode 保 drawing ✓
        //   - mutation `guard base == revision`: base(99) == state.rev(99) → true → guard 通过 → 退出 drawing ✗
        // 此 fixture 合成（drawing 模式内 revision 不会被 bump，真实流程触达不到 state.rev != snap.baseRev），
        // 但 mutation testing 需要此 fixture 暴露 wrong-source 误改。
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 99)
        let eff = s.reduce(.drawingCommitted(baseRevision: 99))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode unchanged (wrong-source mutation would exit drawing)")
            return
        }
        #expect(snap.frozen.baseRevision == 5)  // snap 不变
        #expect(s.revision == 99)                // state.rev 不变
        #expect(eff == .none)
    }
}

// MARK: - reduce: drawingCancelled (drawing-matched + drawing-unmatched cross-session guard;
//                                   same scope notes as committed)

@Suite("reduce drawingCancelled")
struct ReduceDrawingCancelledTests {

    @Test("drawing(snap.baseRev=r) + drawingCancelled(baseRev=r) → autoTracking + 不 bump + .none")
    func drawingMatchedExits() {
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 5)
        let eff = s.reduce(.drawingCancelled(baseRevision: 5))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 5)
        #expect(eff == .none)
    }

    @Test("drawing(snap.baseRev=r) + drawingCancelled(baseRev != r) → mode 不变 + 不 bump + .none（cross-session 丢弃）")
    func drawingUnmatchedKeepsSession() {
        // spec L1163-1166 验收 #4 cancel 分支：session A 遗留 drawingCancelled(baseRev=0)
        // 在新 session B drawing(snap.baseRev=1) 时到达 → guard 丢弃保持 session B
        var s = makePanel(makeDrawingMode(baseRev: 1), rev: 1)
        let eff = s.reduce(.drawingCancelled(baseRevision: 0))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode unchanged after unmatched cancel")
            return
        }
        #expect(snap.frozen.baseRevision == 1)
        #expect(s.revision == 1)
        #expect(eff == .none)
    }

    @Test("drawing(snap.baseRev=5) + state.rev=99 + drawingCancelled(base=99) → guard 读 snap.baseRev 而非 state.rev → mode 不变 + .none")
    func drawingCancelledReadsSnapshotNotRevision() {
        // R3 high-1 修订（mirror committed）：distinguishing fixture state.revision != snap.frozen.baseRevision。
        // 守 cancel 分支 prod guard 同样读 snap.frozen.baseRevision；mutation 同上抓。
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 99)
        let eff = s.reduce(.drawingCancelled(baseRevision: 99))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode unchanged (wrong-source mutation would exit drawing)")
            return
        }
        #expect(snap.frozen.baseRevision == 5)
        #expect(s.revision == 99)
        #expect(eff == .none)
    }
}

// MARK: - reduce: 5 stale drift paths (spec L1146-1162 验收 #3 + R2 freeScrolling 补 + R6 trade nonzero baseline 拆姊妹 test)
// Characterization tests: prod stale guard literal 在 PR7b1 已落（Reducer.swift L174-176）；
// 本 Suite 验证 3 条 spec 字面 sequence path（trade / periodCombo / offsetApplied 漂移）
// 在 reducer 内端到端可达，stale guard 真返回 .staleDrawingSnapshot。

@Suite("reduce stale drift paths")
struct ReduceStaleDrawingSnapshotTests {

    @Test("trade 漂移 (spec literal r=0→1): activateDrawing(r=0) → tradeTriggered(r=1) → setDrawingSnapshot(baseRev:0) → stale")
    func tradeDrift() {
        // R6 medium-1 修订：保留 spec L1148/L1160 字面 r=0→r=1 trade path（守 r=0 boundary case，
        // 防 "revision==0 sentinel 错把 tradeTriggered 漂移当成 no-op"回归窗口）。
        // R1 medium-2 提出的 nonzero mutation-killing 拆到独立 `tradeDriftNonZeroBaseline` test（下方），
        // 两个 test 分担：本 test 守 spec literal、姊妹 test 守 mutation gap。
        var s = makePanel(.autoTracking, rev: 0)

        // Step 1: activateDrawing — 不 bump revision，mode 不变
        let eff1 = s.reduce(.activateDrawing(.ray))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 0)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 0))

        // Step 2: tradeTriggered 漂移 — revision bump 到 1，mode 保持 autoTracking
        let eff2 = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff2 == .none)

        // Step 3: setDrawingSnapshot(baseRev=0) handler 回推 — revision 已漂到 1
        // → reducer 守 stale guard 返回 .staleDrawingSnapshot；mode 保持 autoTracking（未进 drawing）
        let eff3 = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 0, candleRange: 0..<100))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff3 == .staleDrawingSnapshot(expected: 0, actual: 1))
    }

    @Test("trade 漂移 (nonzero baseline, mutation killer): activateDrawing(r=5) → tradeTriggered(r=6) → setDrawingSnapshot(baseRev:5) → stale")
    func tradeDriftNonZeroBaseline() {
        // R1 medium-2 + R6 medium-1 修订：与 `tradeDrift` (r=0) 互补的姊妹 test，起点 rev=5。
        // 抓 mutation `guard baseRev != 0 else { return stale }` 常量 guard 错改：
        // baseRev=5 时 `baseRev != 0 = true` → guard CONDITION true → 不进 else 分支 →
        // 不返回 stale → 进 drawing mode；本 test 期望 .staleDrawingSnapshot → 整体 FAIL → mutation 被抓。
        var s = makePanel(.autoTracking, rev: 5)

        let eff1 = s.reduce(.activateDrawing(.ray))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 5)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 5))

        let eff2 = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff2 == .none)

        let eff3 = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 5, candleRange: 0..<100))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff3 == .staleDrawingSnapshot(expected: 5, actual: 6))
    }

    @Test("periodCombo 漂移: activateDrawing(r=0) → periodComboSwitched(r=1, .clearPendingDrawing) → setDrawingSnapshot(baseRev:0) → stale")
    func periodComboDrift() {
        var s = makePanel(.autoTracking, rev: 0)

        // Step 1: activateDrawing — 不 bump revision，mode 不变
        let eff1 = s.reduce(.activateDrawing(.trend))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 0)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .trend, baseRevision: 0))

        // Step 2: periodComboSwitched 漂移 — bump + .clearPendingDrawing
        let eff2 = s.reduce(.periodComboSwitched)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff2 == .clearPendingDrawing)

        // Step 3: setDrawingSnapshot(baseRev=0) → stale
        let eff3 = s.reduce(.setDrawingSnapshot(tool: .trend, baseRevision: 0, candleRange: 0..<100))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff3 == .staleDrawingSnapshot(expected: 0, actual: 1))
    }

    @Test("offsetApplied 漂移 (autoTracking): activateDrawing(r=0) → offsetApplied(delta=3, autoTracking, r=1) → setDrawingSnapshot(baseRev:0) → stale")
    func offsetAppliedDrift() {
        // 闸门 #5 新增路径：handler 计算 candleRange 期间发生 .offsetApplied（手势 / deceleration 余震），
        // mode 仍是 autoTracking → revision bump → setDrawingSnapshot 回推已 stale
        var s = makePanel(.autoTracking, rev: 0)

        // Step 1: activateDrawing — 不 bump revision，mode 不变
        let eff1 = s.reduce(.activateDrawing(.horizontal))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 0)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .horizontal, baseRevision: 0))

        // Step 2: offsetApplied 漂移 — offset 累加 + bump
        let eff2 = s.reduce(.offsetApplied(deltaPixels: 3))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.offset == 3)
        #expect(s.revision == 1)
        #expect(eff2 == .none)

        // Step 3: setDrawingSnapshot(baseRev=0) → stale
        let eff3 = s.reduce(.setDrawingSnapshot(tool: .horizontal, baseRevision: 0, candleRange: 0..<100))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff3 == .staleDrawingSnapshot(expected: 0, actual: 1))
    }

    @Test("freeScrolling 漂移 (offsetApplied): activateDrawing(r=0, free) → offsetApplied(delta=3, free, r=1) → setDrawingSnapshot(baseRev:0) → stale + mode 保 free")
    func freeScrollingOffsetAppliedDrift() {
        // R2 medium-1 修订：覆盖 spec L1059-1064 stale guard 的 freeScrolling 分支；
        // 关闭 prod 错写「auto 单 case + free 单走 .none」回归窗口。
        // 选 offsetApplied（非 trade/period）：spec L1098-1102 / L1104-1108 trade/period
        // 会硬切 autoTracking，中间 step 后 mode 已不在 freeScrolling；offsetApplied 在
        // freeScrolling 上吞 + bump（不切 mode），mode 全程保 freeScrolling。
        var s = makePanel(.freeScrolling, rev: 0)

        // Step 1: activateDrawing — 不 bump revision，mode 保 freeScrolling
        let eff1 = s.reduce(.activateDrawing(.ray))
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 0)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 0))

        // Step 2: offsetApplied 漂移 — offset 累加 + bump；mode 保 freeScrolling
        let eff2 = s.reduce(.offsetApplied(deltaPixels: 3))
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.offset == 3)
        #expect(s.revision == 1)
        #expect(eff2 == .none)

        // Step 3: setDrawingSnapshot(baseRev=0) → stale；mode 保 freeScrolling（未进 drawing 也未掉 auto）
        let eff3 = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 0, candleRange: 0..<100))
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 1)
        #expect(eff3 == .staleDrawingSnapshot(expected: 0, actual: 1))
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
