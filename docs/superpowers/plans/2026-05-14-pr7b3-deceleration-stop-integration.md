# PR 7b3 — C1b Deceleration Stop 契约集成测试 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task（本项目只用 subagent-driven-development，见 memory `project_executing_plans_excluded`）。每个 Task 派一个 fresh sonnet 4.6 high-effort subagent；Task 与 Task 之间主线 two-stage review。Steps use checkbox (`- [ ]`) syntax for tracking。

**Goal:** 为 spec `kline_trainer_modules_v1.4.md` L1167「Deceleration stop 契约测试」交付**可执行的 handler 合约 spec + reducer 侧验证**——用测试 target 内的 mock 派发管线验证 reducer 的 effect 合约足以让一个正确的 handler 存在，**零生产代码改动**。注意：本 PR **不**关闭 L1167 的 production handler/animator 集成 gate（见下「本 PR 不证明什么」）——那部分依赖 Wave 1 的 E5/C8/C2。

**Architecture:** 新建单文件 `ReducerEffectIntegrationTests.swift`，含三段：(1) `SpyDecelerationAnimator` —— spec §C2 `DecelerationAnimator` 的测试替身；(2) `ReducerEffectHarness` —— 把**真** `PanelViewState.reduce(_:)` + spec L1015-1021 handler 合约的可执行参考实现 + spy animator 串成 dispatch 链的测试集成桥；(3) `ReducerEffectIntegrationTests` Suite —— 5 条 spec L1167 集成断言。`DecelerationAnimator`（C2）与真 effect handler（E5/C8）属 Wave 1，不在 v6 outline 的 Wave 0 PR 列表，本 PR 不提前落地它们。

**Tech Stack:** Swift 6.0（toolchain 6.3.1）+ SwiftPM intra-package + Swift Testing macros（`@Test` / `@Suite` / `#expect` / `Issue.record`）+ `import Foundation` + `import CoreGraphics`。无新增依赖、无 `Package.swift` 改动、无 prod 文件改动。

**Spec 锚点：**
- 主要：`kline_trainer_modules_v1.4.md` **L1167**（Deceleration stop 契约测试，闸门 #4 F3）
- 次要：L1015-1021（`requestDrawingSnapshotAfterStoppingAnimator` handler 合约：必须先 stop animator 再算 range 再派发 setDrawingSnapshot）；L1019-1020（残留 animator 回调只在 handler **不** stop 时才存在，drawing 退出后会真应用 → 必须 stop）；L1112-1113（drawing 模式吞 `offsetApplied` 兜底层）；§C2 L1242-1259（`DecelerationAnimator` 的 `onUpdate` / `start` / `stop` 表面合约 + onUpdate 必须封装为 `.offsetApplied` 派发）

**与 v6 outline 顺位关系：** v6 outline 顺位 14 = "PR 7b3: DecelerationAnimator 集成测试"。PR7b1 验收单 + PR7b2 计划/验收单三处一致把「`DecelerationAnimator.stop()` handler 合约 + integration test」「effect handler 真派发集成测试（含 animator.stop() 必须在 candleRange 计算前）」明确 scope-out 到 PR7b3。本 PR 即接力这唯一剩余项。PR7b2 计划当时算过账：此 scope「需要 mock Effect 派发管线、超 ~150 行……独立大 scope」——本 plan 正是该 mock 派发管线。

**Scope 决策（已与 user 确认）：** 管线放**测试代码、零生产改动**。理由：(1) PR7b2 计划原话是「mock Effect 派发管线」——字面是 mock；(2) `DecelerationAnimator`（C2）与 effect handler（E5/C8）属 Wave 1，v6 outline 未列为 Wave 0 PR，提前落地生产类型 = 违反 memory `project_modules_v1.4_frozen`「模块不要再拆/不要加 scope」；(3) CLAUDE.md §2 simplicity-first / §3 surgical——零 prod 改动是满足 L1167 的最小动作；(4) 与 PR7b2（几乎纯测试 PR）同性质。

**本 PR 不证明什么（codex R1 high-1：避免 false confidence）：** 当前 Wave 0 仓库里**没有**生产 effect handler、也**没有**生产 `DecelerationAnimator`——两者属 E5/C8/C2，是 Wave 1。因此 `ReducerEffectHarness.handle(_:)` 是 spec L1015-1021 合约的**参考实现 / characterization**，不是生产路径。本 PR 证明的是：**真 reducer 返回的 `ChartReduceEffect` 足以让一个遵守合约的 handler 正确驱动 animator**（reducer 侧 + effect 合约侧）；本 PR **不**证明用户可见的「减速动画在算 snapshot 前真的停了」——那需要生产 handler 被 wire 进去。**L1167 的 production handler/animator 集成 gate 因此保持 OPEN，作为 Wave 1（E5/C8/C2 落地时）的验收项**，不由本 PR 关闭。

为什么不走 codex R1 推荐的方案 (a)「加最小注入协议 wire 进生产」：(a) 要求落地 Wave 1 生产类型（`DecelerationAnimating` 协议 + handler），与 (i) user 已确认的「零生产改动」scope 决策冲突、(ii) v6 outline（两者均非 Wave 0 PR）冲突、(iii) memory `project_modules_v1.4_frozen`「模块不要再加 scope」冲突。故采纳 codex R1 推荐方案 (b)：reclassify 为 executable spec，production gate 留 Wave 1。

**完成后：** C1b 的 **reducer 侧 + effect 合约侧**验收全部落地（PR7a/7b1/7b2/7b3）；唯一遗留 = L1167 的 production handler/animator 集成（Wave 1，随 E5/C8/C2 落地）。下一锚 = v6 outline 顺位 15 = PR 8（C1c Render + C3-C6 stubs + §15.1 sign-off + tag `wave0-frozen-v1.4`）。

**⚠️ Wave 0 freeze blocker（codex R3 high-1）：** L1167 在 spec 里挂「Wave 0 额外验收」，但其 production 保证（见下「本 PR 不证明什么」+「spy 的回调模型 · 本模型不覆盖什么」）依赖 Wave 1 的 C2/E5/C8。本 PR **不**关闭该 gate。因此 **PR 8 不得在以下任一条件满足前打 `wave0-frozen-v1.4` tag**：
> 1. L1167 的 production handler/animator 集成测试落地（随 Wave 1 C2/E5/C8，或提前补）；或
> 2. L1167 经 spec 修订正式从「Wave 0 额外验收」移入 Wave 1 验收（治理动作，走 `superpowers:brainstorming` → `codex:adversarial-review`）。
>
> PR 8 的 plan 必须把本条列为**显式 blocking checklist item**；本 plan 在此留痕，避免该 gate 在 freeze 时被静默跳过。PR7b3 merge 时同步在 v6 outline 记忆（`project_wave0_execution_plan_v5.md`）补一行该约束。

---

## File Structure

| 文件 | 责任 | 状态 | 增量 LOC budget |
|---|---|---|---|
| `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift` | 单文件含 (1) `SpyDecelerationAnimator` 测试替身；(2) `ReducerEffectHarness` 测试集成桥（含 handler 参考实现）；(3) `ReducerEffectIntegrationTests` Suite × 5 集成测试 | Create | ~160（spy ~32 + harness ~58 + 5 tests ~56 + header/imports ~14） |
| `docs/acceptance/2026-05-14-pr7b3-deceleration-stop-integration.md` | 中文非-coder 验收清单（action / expected / pass_fail 三段） | Create | ≤95 |
| `docs/superpowers/plans/2026-05-14-pr7b3-deceleration-stop-integration.md` | 本计划文件（codex 对抗性 review 的 source-of-truth + branch-diff 复审对照） | Create（本文件） | — |

**File rationale：**
- **单新文件、不动 `ReducerTests.swift`：** Spy + Harness + 集成测试是一个紧耦合的单元（writing-plans 原则「files that change together live together」）。`ReducerTests.swift`（736 行）保持不动 = CLAUDE.md §3 surgical。
- **不动任何 prod 文件：** `Reducer.swift` 已在 PR7a/7b1/7b2 落地完整 reducer（含 drawing 模式吞 `offsetApplied`、stale guard、cross-session guard），L1167 集成测试不需要任何 prod 改动。
- **`makeState` 文件局部 helper：** 新文件自带一个极小的 `private func makeState`。这**不是** PR7b2 修复的「单文件内 13 处 copy」重复模式——那是同一文件内 13 处；此处是另一个独立测试文件的 5 处局部调用，跨文件 `private` 本就不可见、无法复用 `ReducerTests.swift` 的 `makePanel`。
- **不抽生产协议：** 不加 `DecelerationAnimating` 协议（user 确认走「零生产改动」方案，非「最小协议 seam」方案）。

**Working directory：** worktree，由 `superpowers:using-git-worktrees` 在执行阶段创建（不在 plan 阶段创建）。SwiftPM root: `<worktree>/ios/Contracts/`。计划文件本身 commit 进 PR scope（PR #49 教训：plan 文件漏 commit 触发 re-attest 循环）。

**Baseline：** PR7b2 merged 后 origin/main = **265 tests in 58 suites / 0 failures / 0 warnings**（已用实跑确认）。PR7b3 完成后预期：
- 新增 1 个 Suite `ReducerEffectIntegrationTests` + 5 个 `@Test`
- 净 **+5 测试 → 270 tests in 59 suites** / 0 failures / 0 warnings

**子项数（per memory `feedback_planner_packaging_bias`「硬规则 ≤3 子项 / ≤500 行 prod」）：**
1. **Task 1**：测试替身 + 集成桥骨架（handler 的 `requestDrawingSnapshot` case 先 stub）+ Test 1（`.startDeceleration` 路径）
2. **Task 2**：handler `requestDrawingSnapshot` case 真实现 + Tests 2-5（stop 契约 + 顺序 + drawing 内残留回调 + drawing 退出后残留回调）
3. **Task 3**：中文非-coder 验收清单

合计 **3 子项** ✓ / prod 净增 **0 行** ✓（远 ≤500）

---

## 设计要点

### 为什么 `handle(_:)` 是「参考实现」而不是「被测的测试代码」

`ReducerEffectHarness.handle(_:)` 是 spec L1015-1021 + L1167 handler 合约**写成可执行代码的参考实现**。它不是「我们写来测自己的测试代码」——它是「把 spec 的 handler 合约固化成 runnable 形式，接到**真** reducer 上」。集成测试验证的是：**真 reducer 返回的 `ChartReduceEffect` 值，足以让一个遵守合约的 handler 正确驱动 animator 而不产生 offset 漂移**。Wave 1 的 E5/C8 真 handler 落地时，这个文件就是它们的 executable spec。

**边界（codex R1 high-1）：** 正因为 `handle(_:)` 是参考实现而非生产路径，本 PR **不关闭** L1167 的 production gate——见上「本 PR 不证明什么」。测试能通过，是因为参考 handler 按合约调了 `stop()`；这证明的是「合约可被满足」，不是「生产 handler 已满足合约」。

### dispatch 链的 reentrancy

`dispatch(.activateDrawing)` → `handle(.requestDrawingSnapshotAfterStoppingAnimator)` → 链内再 `dispatch(.setDrawingSnapshot)` → `handle(.none)` → 终止。深度 2，必然终止（`setDrawingSnapshot` 只返回 `.none` 或 `.staleDrawingSnapshot`，两者都不再 re-dispatch）。这正确复刻真实 app 的 reentrant dispatch。

### spy 的回调模型：单一 `tick` primitive + `isRunning` cancellation guard（codex R2→R4）

只有**一个**回调投递 primitive：`SpyDecelerationAnimator.tick(delta:)`，由 `isRunning` 守门。
- `start` 后、`stop` 前调用 → 正常 tick，触发 `onUpdate`，返回 `true`。
- `stop` 后调用 → animator 的 driver 已停，`tick` 被 `stop()` 的 cancellation 契约（`isRunning = false`）丢弃，不触发 `onUpdate`，返回 `false`。**注意（codex R4 high-1）：这只模型「handler stop 后 driver 不再产生新 tick」，不模型「stop() 前已脱离调度的 in-flight 回调」**——后者见下「本模型不覆盖什么」。本 PR 的测试不声称覆盖 in-flight 延迟回调契约。

**为什么不再有「绕过 isRunning 强行触发」的 primitive（codex R2 修订）：** 早期 plan 设过一个 `fireDelayedCallback` 无视 `isRunning` 强行触发——但那模型的是「stop() 没真正取消排队回调」的 **bug**，不是 spec 的契约。per spec L1019-1020，残留回调只在 handler **不** stop 时才存在（原文「若 handler 不 stop animator…」）；handler 一旦 stop，就不该再有任何回调到达——这正是「必须 stop」要保证的。所以 spy 用单一 `isRunning`-guarded `tick`：handler stop 后，无论在 drawing 内还是退出后，`tick` 一律被丢弃。

**本模型不覆盖什么（codex R3 high-2）：** spy 把 `stop()` 建模为「完全取消」（`isRunning = false`，`tick` 一律守门）。这只证明：**假如** production `DecelerationAnimator.stop()` 能完全取消——连 stop() 之前已排队、已脱离调度的 **in-flight 回调**都不漏——**那么** handler 合约 + reducer 不产生漂移。本 PR **不**证明 production `stop()` 真能挡住 in-flight 回调；那个保证需要 Wave 1 机制（C2 `DecelerationAnimator.stop()` 里的 generation token / cancellation guard，或 E5/C8 handler 对 `onUpdate` wiring 的守门）。

换言之：**「in-flight 延迟回调在 drawing 退出后被彻底挡住」这条 = L1167 production gate 的一部分 = Wave 1**（见上「Wave 0 freeze blocker」+「本 PR 不证明什么」）。本 PR 的 5 个测试是该 production 机制的**可执行验收 spec**：Wave 1 实现 `stop()` cancellation 时，必须让这 5 个测试在 production-wired harness 上仍通过。本 PR 不声称已覆盖 in-flight delayed-callback 失败模式。

**Layer 1 兜底（reducer drawing 模式吞 offsetApplied）不在本 PR 重测：** spec L1019 提到的「reducer 已通过 drawing 模式下吞 offsetApplied 兜底」已由 PR7b2 的 `ReduceOffsetAppliedTests` Suite 内 `drawingSwallows` 单元测试覆盖（`ReducerTests.swift`，drawing 模式 `offsetApplied` → `.none` + offset/revision 不变）。本 PR 的集成测试聚焦 L1167 的 **handler 合约**（Layer 2：handler 必须 stop），不重复 Layer 1。

### revision 走账（Task 2 测试断言依赖）

初始 `.freeScrolling` rev=5：
- `dispatch(.panEnded(velocity: 3.0))` → reducer `(.freeScrolling, .panEnded)` → rev `&+= 1` → **rev=6**，mode 保持 freeScrolling，返回 `.startDeceleration(3.0)`
- `dispatch(.activateDrawing(.ray))` → reducer `(.freeScrolling, .activateDrawing)` → 返回 `.requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 6)`，mode/rev 不变
- handler 链内 `dispatch(.setDrawingSnapshot(tool: .ray, baseRevision: 6, candleRange: 0..<100))` → reducer `(.freeScrolling, .setDrawingSnapshot)` → guard `baseRev(6) == revision(6)` ✓ → mode = `.drawing(snapshot)`，rev 不变 → **进 drawing，rev=6，snap.frozen.baseRevision=6**
- `dispatch(.drawingCommitted(baseRevision: 6))` → reducer `(.drawing(snap), .drawingCommitted(6))` → guard `6 == snap.frozen.baseRevision(6)` ✓ → mode = `.autoTracking`，rev 不变 → **退出 drawing，rev=6**

---

## Task 1: 测试替身 + 集成桥骨架 + Test 1（`.startDeceleration` 路径）

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift`
- Test: 同上（Swift Testing：测试与替身同文件）

- [ ] **Step 0: 确认 baseline**

Run: `swift test --package-path ios/Contracts 2>&1 | tail -5`
Expected: 末行 `Test run with 265 tests in 58 suites passed`（0 failures / 0 warnings）。若数字不符，停下来核对 origin/main 是否 = PR #49 merged 状态。

- [ ] **Step 1: 写新文件——header + imports + Suite 含 Test 1（此时引用的 `ReducerEffectHarness` / `SpyDecelerationAnimator` 尚不存在 → 故意编译失败）**

写入 `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑测试，确认编译失败**

Run: `swift test --package-path ios/Contracts 2>&1 | tail -30`
Expected: 编译 FAIL，错误含 `cannot find 'ReducerEffectHarness' in scope`（以及 `SpyDecelerationAnimator` 间接）。

- [ ] **Step 3: 在同文件加 `SpyDecelerationAnimator` + `ReducerEffectHarness`（handler 的 `requestDrawingSnapshot` case 先 stub 为 `break`）**

在 `import @testable ...` 行之后、`// MARK: - spec L1167` 之前插入：

```swift
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
    /// - stop 后（!isRunning）：**这就是 spec L1167「延迟/残留 animator 回调」的模型**——
    ///   stop() 之后才尝试投递的回调被 stop 契约丢弃 → 不触发 onUpdate → 返回 false。
    ///   无独立「绕过 isRunning」的 primitive：per spec L1019-1020，残留回调只在 handler
    ///   **不** stop 时才存在；handler 一旦 stop，isRunning guard 即丢弃所有后续投递尝试。
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
```

- [ ] **Step 4: 跑测试，确认 Test 1 PASS + 全套不回归**

Run: `swift test --package-path ios/Contracts 2>&1 | tail -8`
Expected: `Test run with 266 tests in 59 suites passed`（baseline 265/58 + 1 新测试 + 1 新 Suite）/ 0 failures / 0 warnings。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift
git commit -m "test(PR7b3): SpyDecelerationAnimator + ReducerEffectHarness + startDeceleration 集成测试"
```

---

## Task 2: handler `requestDrawingSnapshot` case 真实现 + Tests 2-5

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift`（`handle(_:)` 的 `requestDrawingSnapshot` case + `ReducerEffectIntegrationTests` Suite 加 4 个 `@Test`）

- [ ] **Step 1: 在 `ReducerEffectIntegrationTests` Suite 内、`panEndedStartsAnimator()` 之后加 Tests 2-4（此时 handler 仍 stub → 故意失败）**

在 `panEndedStartsAnimator()` 函数闭合 `}` 之后、Suite 闭合 `}` 之前插入：

```swift
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
    }

    @Test("drawing 模式内：handler 已 stop animator → 残留 tick 被丢弃，无 offsetApplied 到达 reducer")
    func noResidualCallbackWhileDrawing() {
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
```

- [ ] **Step 2: 跑测试，确认 Tests 2-4 FAIL（handler 仍 stub）**

Run: `swift test --package-path ios/Contracts 2>&1 | tail -30`
Expected: Test 1 (`panEndedStartsAnimator`) PASS；Tests 2-4 FAIL——因为 `handle(_:)` 的 `requestDrawingSnapshot` case 是 `break` stub：animator 未 stop（`stopCount==0`、`isRunning==true`）、`setDrawingSnapshot` 未派发、state 仍是 `.freeScrolling`。错误含 `expected drawing mode ...`（Test 2）/ timeline 不符（Test 3）/ `tick` 返回 `true` + `fired == false` 失败 + offset 漂移（Test 4）。**无 trap/crash**（3 个测试全是干净的 `#expect` / `Issue.record` 失败；Test 2-4 均不在 `.freeScrolling` 上派 `drawingCommitted`，不触发 reducer 的非法转换 `assertionFailure`）。

- [ ] **Step 3: 把 `handle(_:)` 的 `requestDrawingSnapshot` case 从 stub 替换为真实现**

把 Task 1 Step 3 写入的：

```swift
        case .requestDrawingSnapshotAfterStoppingAnimator:
            // PR7b3 Task 2 填真实现（spec L1015-1021 handler 合约）。Task 1 暂 stub。
            break
```

替换为：

```swift
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
```

- [ ] **Step 4: 跑测试，确认 Tests 1-4 PASS（4/4）+ 全套不回归**

Run: `swift test --package-path ios/Contracts 2>&1 | tail -8`
Expected: `Test run with 269 tests in 59 suites passed`（baseline 265/58 + 4 新测试 + 1 新 Suite）/ 0 failures / 0 warnings。

- [ ] **Step 5: 加 Test 5（after-exit 集成测试）到 `ReducerEffectIntegrationTests` Suite 内、`noResidualCallbackWhileDrawing()` 之后**

> **为什么 Test 5 不和 Tests 2-4 一起在 Step 1 加：** Test 5 需要 `drawingCommitted` 在已进 drawing 的 state 上派发；而 Step 1 时 stub handler 不进 drawing，`drawingCommitted` 落在 `.freeScrolling` 上会触发 reducer 的 `assertionFailure`（非法转换）—— debug build 下 trap/crash 整个 test run，污染 red 输出。故 Test 5 移到本 Step（handler 真实现之后），此刻 `drawingCommitted` 能正常退出 drawing、不再 trap。

在 `noResidualCallbackWhileDrawing()` 函数闭合 `}` 之后、Suite 闭合 `}` 之前插入：

```swift
    @Test("drawing 退出后：handler 已 stop animator → driver tick 静默，autoTracking 下也无 offsetApplied 漂移")
    func noResidualCallbackAfterDrawingExit() {
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
```

- [ ] **Step 6: 跑测试，确认 5/5 PASS + 全套不回归**

Run: `swift test --package-path ios/Contracts 2>&1 | tail -8`
Expected: `Test run with 270 tests in 59 suites passed`（baseline 265/58 + 5 新测试 + 1 新 Suite）/ 0 failures / 0 warnings。

- [ ] **Step 7: 确认 release build + 零生产改动**

Run: `swift build -c release --package-path ios/Contracts 2>&1 | tail -3 && git diff --stat origin/main -- ios/Contracts/Sources/`
Expected: `Build complete!`；`git diff --stat` 对 `ios/Contracts/Sources/` **零输出**（确认无任何 prod 文件改动）。

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift
git commit -m "test(PR7b3): handler stop 契约 + 顺序 + drawing 内/退出后残留回调 4 集成测试"
```

---

## Task 3: 中文非-coder 验收清单

**Files:**
- Create: `docs/acceptance/2026-05-14-pr7b3-deceleration-stop-integration.md`

- [ ] **Step 1: 写验收清单**

写入 `docs/acceptance/2026-05-14-pr7b3-deceleration-stop-integration.md`（结构对齐 `docs/acceptance/2026-05-13-pr7b2-stale-drift-tests-helpers-cosmetic.md`；三段 action / expected / pass_fail；中文；禁用 `.claude/workflow-rules.json` `forbidden_phrases`：「验证通过即可」「看起来正常」「应该没问题」「should work」「looks fine」）：

```markdown
# PR 7b3 — C1b Deceleration Stop 契约集成测试 验收清单

> 给非 coder 的你：每节照「操作」敲命令，把输出和「预期」对一对，再按「通过判定」打勾。
> 所有命令在仓库根目录执行。

## §1. 编译通过

- **操作：** `swift build --package-path ios/Contracts 2>&1 | tail -3`
- **预期：** 末尾出现 `Build complete!`，无 `error:`、无 `warning:`。
- **通过判定：** 看到 `Build complete!` 且全程无 `error:` / `warning:` → 通过；否则不通过。

## §2. 全部测试通过 270/270 in 59 suites（baseline 265/58 + 5 新测试 + 1 新 Suite）

- **操作：** `swift test --package-path ios/Contracts 2>&1 | tail -6`
- **预期：** 末尾出现 `Test run with 270 tests in 59 suites passed`，`0 failures`。
- **通过判定：** 数字正好是 `270 tests in 59 suites` 且 `passed` → 通过；任何 `failed:` / 数字不符 → 不通过。

## §3. 新 Suite `ReducerEffectIntegrationTests` 5/5 PASS

- **操作：** `swift test --package-path ios/Contracts --filter ReducerEffectIntegrationTests 2>&1 | tail -12`
- **预期：** 5 个测试全 `passed`：`panEndedStartsAnimator` / `activateDrawingStopsAnimatorAndEntersDrawing` / `handlerStopsAnimatorBeforeComputingRange` / `noResidualCallbackWhileDrawing` / `noResidualCallbackAfterDrawingExit`。
- **通过判定：** 5 个测试名全部出现且全 `passed`，`0 failures` → 通过；少一个或有 `failed:` → 不通过。

## §4. 零生产代码改动（本 PR 只动测试 + 文档）

- **操作：** `git diff --stat origin/main -- ios/Contracts/Sources/`
- **预期：** **零输出**（命令打印空行后直接结束）。
- **通过判定：** 完全无输出 → 通过；只要列出任何 `ios/Contracts/Sources/...` 文件 → 不通过。

## §5. 新文件落在测试 target、且只新增一个文件

- **操作：** `git diff --stat origin/main -- ios/Contracts/`
- **预期：** 只列出一个文件 `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift`，状态为新增。
- **通过判定：** 恰好一个新增文件、路径在 `Tests/` 下 → 通过；出现第二个文件或路径在 `Sources/` 下 → 不通过。

## §6. spec L1167 三项契约被测试字面守住

- **操作：**
  ```
  grep -c "animator.stop()" ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift
  grep -n "animatorStopped" ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift
  grep -n "func tick" ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift
  ```
- **预期：** 第 1 条 ≥1（handler 真调 `animator.stop()`）；第 2 条至少出现在 `handle(_:)` 与 `handlerStopsAnimatorBeforeComputingRange` 两处（先 stop 再算 range 的顺序断言）；第 3 条命中 `SpyDecelerationAnimator.tick` 定义（被 `noResidualCallbackWhileDrawing` / `noResidualCallbackAfterDrawingExit` 用于验证 handler-stop 后 driver tick 静默）。
- **通过判定：** 三条 grep 都命中且行数符合上述 → 通过；任一条 0 命中 → 不通过。

## §7. PR7a / PR7b1 / PR7b2 既有 Suite 行为零回归

- **操作：** `swift test --package-path ios/Contracts --filter ReducerTests 2>&1 | tail -4` 再 `swift test --package-path ios/Contracts --filter "reduce " 2>&1 | tail -4`
- **预期：** 既有 reducer 相关 Suite 全 `passed`，无 `failed:`。
- **通过判定：** 全 `passed` → 通过；出现 `failed:` → 不通过。

## §8. PR7b3 之后 C1b 验收状态

- C1b 验收清单（spec L1156-1174）的 **reducer 侧 + effect 合约侧**至此全部落地：revision 单调性（PR7a）、requestDrawingSnapshot effect 覆盖（PR7b1）、staleDrawingSnapshot 三路径（PR7b2）、跨 session guard（PR7b1）、双分支 + 非法转换 assertion（PR7b1/7b2）、**Deceleration stop 契约的可执行 spec + reducer 侧验证（本 PR）**。
- **遗留（非缺陷，是 scope 边界）：** L1167 的 **production handler/animator 集成 gate** 保持 OPEN——本 PR 用测试内参考 handler 验证「reducer 的 effect 合约足以让正确 handler 存在」，但生产 effect handler（E5/C8）与生产 `DecelerationAnimator`（C2）属 Wave 1；尤其「in-flight 延迟回调被 production `stop()` 彻底挡住」这条不在本 PR 覆盖范围。该 gate 在 Wave 1 E5/C8/C2 落地时关闭，不由本 PR 关闭（详见计划「本 PR 不证明什么」+「spy 的回调模型 · 本模型不覆盖什么」）。
- **⚠️ 对 PR 8 的约束：** `wave0-frozen-v1.4` tag **不得**在「L1167 production 集成落地」或「L1167 经 spec 修订移入 Wave 1」之前打。PR 8 的 plan 须把此列为显式 blocking checklist item（详见计划「Wave 0 freeze blocker」）。
- 下一锚 = v6 outline 顺位 15 = PR 8（C1c Render + C3-C6 stubs + §15.1 sign-off + tag `wave0-frozen-v1.4`）。

## §9. 总结

- 本 PR 交付 spec L1167 的**可执行 handler 合约 spec + reducer 侧验证**（非 production 集成 gate 关闭），3 子项：测试替身 + 集成桥（Task 1）、handler 契约 + 4 集成测试（Task 2）、本验收清单（Task 3）。
- 生产代码净增 0 行；测试净增 1 文件 / 1 Suite / 5 测试。
- 全部 8 节验收命令可由非 coder 逐条复跑核对。
```

- [ ] **Step 2: Commit（含计划文件——PR #49 教训：plan 文件随 PR 一起 commit）**

```bash
git add docs/acceptance/2026-05-14-pr7b3-deceleration-stop-integration.md \
        docs/superpowers/plans/2026-05-14-pr7b3-deceleration-stop-integration.md
git commit -m "docs(PR7b3): 验收清单（中文非-coder 可执行）+ 计划文件"
```

---

## Self-Review

**1. Spec coverage：** spec L1167 拆 4 个可验证子句 → 全部映射到测试：
- 「`panEnded(velocity:) → .startDeceleration(v)` effect handler 启动 animator」→ Test 1 `panEndedStartsAnimator`
- 「activateDrawing → `.requestDrawingSnapshotAfterStoppingAnimator` effect」+「handler stop animator」→ Test 2 `activateDrawingStopsAnimatorAndEntersDrawing`
- 「验证 handler 必须**先**调用 `animator.stop()` 再计算 range」→ Test 3 `handlerStopsAnimatorBeforeComputingRange`（全时间线相等断言）
- 「模拟延迟 animator 回调，验证 drawing 退出后无 `offsetApplied` 到达 reducer」→ **部分覆盖**：Test 4 `noResidualCallbackWhileDrawing` + Test 5 `noResidualCallbackAfterDrawingExit` 验证「handler stop animator 后，driver tick 在 drawing 内 + 退出后均静默 → 无 offsetApplied 漂移」。**未覆盖**：in-flight（stop 前已脱离调度）回调被 production `stop()` 挡住——属 Wave 1（见「spy 的回调模型 · 本模型不覆盖什么」+「Wave 0 freeze blocker」）
无 spec L1167 子句无对应 task。**注意（codex R1 high-1）**：本 PR 覆盖的是 L1167 的 **reducer 侧 + effect 合约侧**；L1167 的 production handler/animator 集成 gate 保持 OPEN 留 Wave 1，不由本 PR 关闭（见「本 PR 不证明什么」+「Wave 0 freeze blocker」）。**延迟回调模型边界（codex R2→R3）**：`tick` after `stop()` 是「延迟/残留回调」的模型，`isRunning` guard 是「`stop()` 完全取消」的契约**假设**。**本 PR 不声称覆盖** in-flight（stop 前已脱离调度）回调被 production `stop()` 彻底挡住这条——那是 L1167 production gate 的一部分，属 Wave 1（见「spy 的回调模型 · 本模型不覆盖什么」）。本 PR 的 5 个测试是该 production 机制的可执行验收 spec。Layer 1（reducer drawing 吞 offsetApplied）已由 PR7b2 `drawingSwallows` 单元测试覆盖，本 PR 不重测。其余 C1b 验收项（L1157-1166、L1168-1174）已 PR7a/7b1/7b2 落地，非本 PR scope。

**2. Placeholder scan：** 全 plan 无 `TBD` / `TODO` / `implement later` / `fill in details` / `add appropriate ...` / `handle edge cases` / `similar to Task N`。Task 1 Step 3 的 `requestDrawingSnapshot` case `break` **不是** placeholder——它是 TDD 的故意 stub，Task 2 Step 3 显式给出完整替换代码。✓

**3. Type consistency：**
- `ReducerEffectHarness` / `SpyDecelerationAnimator` / `ReducerEffectHarness.Event` 命名全 plan 一致。
- `dispatch(_:)` / `handle(_:)` / `tick(delta:)` / `start(initialVelocity:)` / `stop()` 方法签名全 plan 一致。**无 `fireDelayedCallback`**（codex R2 修订删除，全 plan 不再出现）。
- `Event` 的 4 个 case（`.dispatched` / `.animatorStarted` / `.animatorStopped` / `.rangeComputed`）在 harness 定义、`handle(_:)` 追加、Test 1 / Test 3 断言三处一致。
- 引用的生产类型 `PanelViewState` / `ChartInteractionMode` / `ChartAction`（`.panEnded(velocity:)` / `.activateDrawing` / `.setDrawingSnapshot(tool:baseRevision:candleRange:)` / `.drawingCommitted(baseRevision:)` / `.offsetApplied(deltaPixels:)`）/ `ChartReduceEffect`（5 case：`.none` / `.startDeceleration(velocity:)` / `.clearPendingDrawing` / `.requestDrawingSnapshotAfterStoppingAnimator(tool:baseRevision:)` / `.staleDrawingSnapshot(expected:actual:)`）/ `DrawingToolType`（`.ray`）/ `FrozenPanelState`（`.candleRange` / `.baseRevision`）/ `DrawingSnapshot`（`.frozen`）—— 全部核对自 `ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift` L24-118 现状，签名一致。
- `handle(_:)` 的 `switch` 覆盖 `ChartReduceEffect` 全 5 case（Swift 要求穷举）→ Task 1 stub 版与 Task 2 真实现版都穷举。✓

**4. revision 走账自洽：** Test 2/3 断言 `snap.frozen.baseRevision == 6` / timeline 含 `.setDrawingSnapshot(... baseRevision: 6 ...)`；Test 5 `drawingCommitted(baseRevision: 6)` 匹配 `snap.frozen.baseRevision(6)` → 退出 drawing —— 与「设计要点 · revision 走账」一致（freeScrolling rev=5 → panEnded bump → 6 → activateDrawing/setDrawingSnapshot/drawingCommitted 均不 bump）。✓

**5. 子项 / LOC 红线：** 3 子项 ✓；prod 净增 0 行 ✓（Task 2 Step 7 的 `git diff --stat ... Sources/` 零输出 gate 强制）。

**6. TDD red→green 完整性：** Task 1 Test 1：red = 编译失败（类型不存在）→ green = 写 spy + harness。Task 2 Tests 2-4：red = stub handler 下干净 `#expect` 失败（无 trap，因 Test 2-4 不派 `drawingCommitted`）→ green = 实现 handler case。Test 5 移到 handler 实现后加入（after-exit characterization；若放 stub 阶段，`drawingCommitted` 落 `.freeScrolling` 会 `assertionFailure` trap 污染 red 输出）。✓
