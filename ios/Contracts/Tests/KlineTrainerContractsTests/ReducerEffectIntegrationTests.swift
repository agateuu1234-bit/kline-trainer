// Kline Trainer C1b — Reducer Effect Integration Tests (PR7b3)
// Spec: kline_trainer_modules_v1.4.md §C1b L1167（Deceleration stop 契约测试，闸门 #4 F3）
//       + §C1b L1015-1021（requestDrawingSnapshotAfterStoppingAnimator handler 合约）
//       + §C1b L1019-1020（残留 animator 回调只在 handler 不 stop 时才存在 → 必须 stop）
//       + §C2 L1242-1259（DecelerationAnimator onUpdate/start/stop 表面合约）
// Plan: docs/superpowers/plans/2026-05-14-pr7b3-deceleration-stop-integration.md
//
// PR7b3 scope（本文件本 PR 落地，零生产代码改动）：
//   - SpyDecelerationAnimator：测试替身，复刻 spec §C2 的 onUpdate/start/stop 行为合约
//   - ReducerEffectHarness：测试集成桥，把真 reducer + spec L1015-1021 handler 参考实现
//     + spy animator 串成一条 dispatch 链；handle(_:) 即「Wave 1 E5/C8 将承担的合约」的可执行版
//   - ReducerEffectIntegrationTests：spec L1167 5 条集成断言
//
// 为什么零生产代码：DecelerationAnimator（C2）与 effect handler（E5/C8）属 Wave 1，
//   不在 v6 outline 的 Wave 0 PR 列表内。本 PR 用测试 target 内的 mock 派发管线验证
//   reducer 的 effect 合约「足以让一个正确的 handler 存在」，不提前落地 Wave 1 生产类型。
//   L1167 的 production handler/animator 集成 gate 因此保持 OPEN，留 Wave 1 关闭。

import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

// MARK: - 测试替身：DecelerationAnimator（spec §C2 L1245-1254）

/// `DecelerationAnimator`（spec §C2 L1245-1254）的测试替身。
/// 只复刻 L1167 集成测试需要的行为合约——onUpdate 回调 + start/stop + stop 后不再回调；
/// 不模拟摩擦力物理（friction/stopThreshold），不实现 onFinish/resetOnSceneActive（L1167 用不到）。
final class SpyDecelerationAnimator {
    /// spec §C2 L1246-1248：onUpdate 的消费者必须把 delta 封装为 .offsetApplied 派发回 reducer。
    var onUpdate: ((CGFloat) -> Void)?

    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// 记录最近一次 start 传入的初速度——供 Test 1 断言 handler 透传了 reducer effect 的 velocity
    /// （codex R4 medium-1：start 若丢 velocity / 传 0 / 传错符号，用户可见减速会错）。
    private(set) var lastInitialVelocity: CGFloat?

    /// spec §C2 L1251：启动减速动画。
    func start(initialVelocity: CGFloat) {
        startCount += 1
        isRunning = true
        lastInitialVelocity = initialVelocity
    }

    /// spec §C2 L1252：停止减速动画。
    /// stop() 同步生效，返回后 `isRunning = false` guard 确保后续 tick(delta:) 调用不触发 onUpdate。
    /// 注意：本 spy **不**模型「stop() 前已脱离调度的 in-flight 回调」——见 tick(delta:) doc 的边界说明。
    func stop() {
        stopCount += 1
        isRunning = false
    }

    /// 测试钩子：模拟 animator 尝试投递一次 onUpdate（一帧 driver tick）。
    /// - start 后、stop 前（isRunning）：正常 tick → 触发 onUpdate → 返回 true。
    /// - stop 后（!isRunning）：driver 已停，tick 被 stop() cancellation 契约丢弃，返回 false。
    /// 注意：本 primitive 只模型「handler stop 后 driver 不再产生新 tick」。
    /// 对 Wave 0 此即完整模型——per spec L1019-1020「残留 animator 回调**只在 handler 不 stop 时存在**」，
    /// handler 一旦 stop()，isRunning guard 即丢弃所有后续投递尝试。
    /// 不模型「stop() 前已脱离调度的 in-flight 回调」——后者属 Wave 1 C2 的 cancellation 机制（generation token 等），
    /// 由 production gate 在 Wave 1 关闭，非本 PR scope。
    @discardableResult
    func tick(delta: CGFloat) -> Bool {
        guard isRunning else { return false }
        onUpdate?(delta)
        return true
    }
}

// MARK: - 测试集成桥：reducer + handler 参考实现 + spy animator

/// 集成测试用的 dispatch 链。**不是生产代码**——只在测试 target 内。
///
/// 串起三段：
///   1. 真 `PanelViewState.reduce(_:)`（生产 reducer，已在 PR7a/7b1/7b2 落地）
///   2. `handle(_:)` —— spec L1015-1021 + L1167 handler 合约的**可执行参考实现**；
///      Wave 1 的 E5/C8 真 handler 必须 conform 同一合约
///   3. `SpyDecelerationAnimator` —— C2 的测试替身
///
/// `timeline` 按发生顺序记录每次 dispatch + handler 关键步骤，供断言「先 stop 再算 range」。
final class ReducerEffectHarness {

    /// 时间线事件（typed，断言用）。
    enum Event: Equatable {
        case dispatched(ChartAction)
        case animatorStarted
        case animatorStopped
        case rangeComputed
    }

    private(set) var state: PanelViewState
    let animator = SpyDecelerationAnimator()
    private(set) var timeline: [Event] = []

    /// handler 计算 candleRange 的 viewport 替身（测试常量；真 handler 基于真 viewport 算）。
    private let stubCandleRange: Range<Int>

    init(state: PanelViewState, stubCandleRange: Range<Int> = 0..<100) {
        self.state = state
        self.stubCandleRange = stubCandleRange
        // spec §C2 L1246-1248 / L1256-1259：animator 回调必须封装为 .offsetApplied 派发回 reducer。
        animator.onUpdate = { [weak self] delta in
            self?.dispatch(.offsetApplied(deltaPixels: delta))
        }
    }

    /// 派发一个 action：记录 → 跑真 reducer → 把 effect 路由给 handler 参考实现。
    func dispatch(_ action: ChartAction) {
        timeline.append(.dispatched(action))
        let effect = state.reduce(action)
        // effect routing：handle(_:) 是 spec L1015-1021 的可执行 handler 参考实现，Wave 1 E5/C8 必须 conform。
        handle(effect)
    }

    /// spec L1015-1021 + L1167 handler 合约的可执行参考实现。
    private func handle(_ effect: ChartReduceEffect) {
        switch effect {
        case .startDeceleration(let velocity):
            // spec L1167：panEnded → .startDeceleration → handler 启动 animator。
            animator.start(initialVelocity: velocity)
            timeline.append(.animatorStarted)

        case .requestDrawingSnapshotAfterStoppingAnimator(let tool, let baseRevision):
            // spec L1015-1021 handler 合约（必须按序）：
            //   1. 立即 stop animator（防 stale 漂移，spec L1167「必须先调用 animator.stop()」）
            animator.stop()
            timeline.append(.animatorStopped)
            //   2. 基于当前 viewport 计算 candleRange
            timeline.append(.rangeComputed)
            let range = stubCandleRange
            //   3. 派发 setDrawingSnapshot（链内 reentrant dispatch）
            dispatch(.setDrawingSnapshot(tool: tool, baseRevision: baseRevision, candleRange: range))

        case .none, .clearPendingDrawing, .staleDrawingSnapshot:
            // L1167 集成链路无需额外处理：clearPendingDrawing/stale 由 UI 层响应（Wave 1）。
            break
        }
    }
}

// MARK: - spec L1167：Deceleration stop 契约集成测试

@Suite("reduce effect integration")
struct ReducerEffectIntegrationTests {

    /// 文件局部 fixture。不复用 ReducerTests.swift 的 private makePanel——跨文件 private 不可见；
    /// 本 helper 仅本文件 5 处调用，非 PR7b2 修复的「单文件内 13 处 copy」重复模式。
    private func makeState(_ mode: ChartInteractionMode, rev: UInt64 = 0) -> PanelViewState {
        PanelViewState(period: .m15, interactionMode: mode,
                       visibleCount: 100, offset: 0, revision: rev)
    }

    @Test("panEnded(freeScrolling) → .startDeceleration → handler 启动 animator")
    func panEndedStartsAnimator() {
        // spec L1167：panEnded(velocity:) → .startDeceleration(v) effect handler 启动 animator。
        let harness = ReducerEffectHarness(state: makeState(.freeScrolling, rev: 5))

        harness.dispatch(.panEnded(velocity: 3.0))

        #expect(harness.animator.startCount == 1)
        #expect(harness.animator.isRunning == true)
        // codex R4 medium-1：断言 handler 把 reducer effect 的 velocity（3.0，非默认非零）透传给 animator.start
        #expect(harness.animator.lastInitialVelocity == 3.0)
        #expect(harness.timeline == [
            .dispatched(.panEnded(velocity: 3.0)),
            .animatorStarted,
        ])
    }

    @Test("activateDrawing → handler stop animator + 派发 setDrawingSnapshot + 进 drawing")
    func activateDrawingStopsAnimatorAndEntersDrawing() {
        // spec L1167：animator 运行中 → activateDrawing → .requestDrawingSnapshotAfterStoppingAnimator
        // → handler stop animator + 算 range + 派发 setDrawingSnapshot → reducer 进 drawing。
        let harness = ReducerEffectHarness(state: makeState(.freeScrolling, rev: 5))
        harness.dispatch(.panEnded(velocity: 3.0))   // animator 启动，rev 5→6
        #expect(harness.animator.isRunning == true)

        harness.dispatch(.activateDrawing(.ray))

        // handler 停了 animator
        #expect(harness.animator.stopCount == 1)
        #expect(harness.animator.isRunning == false)
        // setDrawingSnapshot 被 handler 回推 → reducer 进 drawing（baseRev == 当前 revision 6）
        guard case .drawing(let snap) = harness.state.interactionMode else {
            Issue.record("expected drawing mode after handler dispatched setDrawingSnapshot")
            return
        }
        #expect(snap.frozen.baseRevision == 6)        // panEnded bump 后 revision=6
        #expect(snap.frozen.candleRange == 0..<100)   // stubCandleRange
    }

    @Test("handler 必须先 stop animator 再算 range 再派发 setDrawingSnapshot（顺序契约）")
    func handlerStopsAnimatorBeforeComputingRange() {
        // spec L1167：验证 handler 必须**先**调用 animator.stop() 再计算 range。
        // 全时间线相等断言 = mutation killer：handler 若先算 range / 先派发再 stop，顺序即不符。
        let harness = ReducerEffectHarness(state: makeState(.freeScrolling, rev: 5))
        harness.dispatch(.panEnded(velocity: 3.0))
        harness.dispatch(.activateDrawing(.ray))

        #expect(harness.timeline == [
            .dispatched(.panEnded(velocity: 3.0)),
            .animatorStarted,
            .dispatched(.activateDrawing(.ray)),
            .animatorStopped,     // ← 必须早于 rangeComputed
            .rangeComputed,       // ← 必须早于 setDrawingSnapshot 派发
            .dispatched(.setDrawingSnapshot(tool: .ray, baseRevision: 6, candleRange: 0..<100)),
        ])
        // PR-level review Important #1：单独断言 animator.stop() 真被调（spy state 派生），
        // 守 mutation「漏 animator.stop() 调用、但保 timeline.append(.animatorStopped)」——
        // 否则 Test 3 时间线对得上而本 case 静默通过；本断言让 Test 3 独立自洽。
        #expect(harness.animator.stopCount == 1)
    }

    @Test("drawing 模式内：handler 已 stop animator → spy.tick(delta:) 被 isRunning guard 挡回 false，无 onUpdate 触发")
    func tickAfterStopReturnsFalseInDrawing() {
        // 本 test 验证「handler-stop 的**效果**」：handler 进 drawing 时已 stop animator，
        // 此后 animator 的 driver tick 静默（被 isRunning guard 丢弃）→ 无 offsetApplied 进 reducer。
        // 它**不是** in-flight 延迟回调测试——「stop() 前已脱离调度、stop() 后才到达的回调被挡住」
        // 是 L1167 production gate 的一部分，属 Wave 1（见「spy 的回调模型 · 本模型不覆盖什么」）。
        let harness = ReducerEffectHarness(state: makeState(.freeScrolling, rev: 5))
        harness.dispatch(.panEnded(velocity: 3.0))
        harness.dispatch(.activateDrawing(.ray))      // handler stop animator + 进 drawing
        let timelineCountAfterDrawing = harness.timeline.count
        let offsetBefore = harness.state.offset

        // handler stop 后的 driver tick：animator 已 stop → tick 返回 false，onUpdate 不触发
        let fired = harness.animator.tick(delta: 50)

        #expect(fired == false)                                        // stop 契约：无残留回调
        #expect(harness.state.offset == offsetBefore)                  // offset 未漂移
        #expect(harness.timeline.count == timelineCountAfterDrawing)    // 没有新 dispatch
        #expect(!harness.timeline.contains(.dispatched(.offsetApplied(deltaPixels: 50))))
    }

    @Test("drawing 退出后：handler 已 stop animator → spy.tick(delta:) 被 isRunning guard 挡回 false，autoTracking 下 offset/revision 不变")
    func tickAfterStopReturnsFalseAfterExit() {
        // 本 test 验证「handler-stop 的效果」延伸到 drawing 退出后：handler 进 drawing 时已 stop
        // animator，退出 drawing 回到 autoTracking 后，animator 的 driver tick 仍静默（isRunning guard）。
        // spec L1019-1020：drawing 退出后 reducer 不再吞 offsetApplied（autoTracking 会真应用）——
        // 所以「handler 必须 stop」在退出后才真正要命；本 test 守这条。
        // mutation killer：若 handler 漏调 animator.stop()，tick 在此 autoTracking 窗口会 fire →
        // offsetApplied 真漂移 offset/revision → 本 test FAIL。
        // 边界（codex R3/R4 high）：本 test **不是** in-flight 延迟回调测试。它在「stop() 完全取消」
        // 的 spy 模型下验证 handler-stop 合约的效果；「production stop() 真能挡住 stop() 前已脱离
        // 调度的 in-flight 回调」是 Wave 1 C2 的 cancellation 机制，本 PR 不覆盖、不声称覆盖。
        let harness = ReducerEffectHarness(state: makeState(.freeScrolling, rev: 5))
        harness.dispatch(.panEnded(velocity: 3.0))            // animator 启动，rev 5→6
        harness.dispatch(.activateDrawing(.ray))              // handler stop animator + 进 drawing(baseRev=6)
        harness.dispatch(.drawingCommitted(baseRevision: 6))  // 匹配 baseRev → 退出 drawing → autoTracking

        #expect(harness.state.interactionMode == .autoTracking)   // 已退出 drawing，drawing-swallow 兜底层失效
        let offsetBefore = harness.state.offset
        let revisionBefore = harness.state.revision

        // handler stop 后的 driver tick，落在危险的 autoTracking 窗口：animator 已 stop → 丢弃
        let fired = harness.animator.tick(delta: 50)

        #expect(fired == false)
        #expect(harness.state.offset == offsetBefore)         // 退出后 offset 不漂移
        #expect(harness.state.revision == revisionBefore)     // 退出后 revision 不漂移
        #expect(!harness.timeline.contains(.dispatched(.offsetApplied(deltaPixels: 50))))
    }
}
