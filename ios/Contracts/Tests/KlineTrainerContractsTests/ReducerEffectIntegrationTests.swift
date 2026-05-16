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
    /// 关键契约（spec L1167「必须 stop」隐含要求）：stop() 同步生效，返回后 animator 不再
    /// 触发 onUpdate——包括 stop() 之前已在途的回调。`isRunning = false` 即此 cancellation guard。
    func stop() {
        stopCount += 1
        isRunning = false
    }

    /// 测试钩子：模拟 animator 尝试投递一次 onUpdate（一帧 driver tick）。
    /// - start 后、stop 前（isRunning）：正常 tick → 触发 onUpdate → 返回 true。
    /// - stop 后（!isRunning）：driver 已停，tick 被 stop() cancellation 契约丢弃，返回 false。
    /// 注意：本 primitive 只模型「handler stop 后 driver 不再产生新 tick」，
    /// 不模型「stop() 前已脱离调度的 in-flight 回调」——后者属 Wave 1 C2 cancellation 机制。
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
        handle(effect)
    }

    /// spec L1015-1021 + L1167 handler 合约的可执行参考实现。
    private func handle(_ effect: ChartReduceEffect) {
        switch effect {
        case .startDeceleration(let velocity):
            // spec L1167：panEnded → .startDeceleration → handler 启动 animator。
            animator.start(initialVelocity: velocity)
            timeline.append(.animatorStarted)

        case .requestDrawingSnapshotAfterStoppingAnimator:
            // PR7b3 Task 2 填真实现（spec L1015-1021 handler 合约）。Task 1 暂 stub。
            break

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
}
