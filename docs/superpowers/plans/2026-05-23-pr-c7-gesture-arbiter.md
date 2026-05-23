# C7 Gesture Arbiter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec §C7 手势系统模块——3 个分类纯函数 + 1 个增量纯函数 + 4 个值类型（macOS 全量单测）+ `ChartGestureArbiter`（UIKit 手势识别器绑定 + 仲裁委托，Catalyst 编译闸门 + 真机验收），输出与 C2/Reducer 契约对齐的增量 offset + 释放速度。

**Architecture:** 决策逻辑沉淀在跨平台纯函数（spec L1363-1395 逐字 + 增量换算）；`ChartGestureArbiter` 是 UIKit 适配薄层——读识别器原始值 → 纯函数 → 回调。纯函数在 macOS `swift test` 全量覆盖；arbiter 用 `#if canImport(UIKit)` 包裹，macOS 编译为空、真实编译校验落 required Catalyst CI 闸门，运行时手势行为是真机验收残留（C2 同款先例）。

**Tech Stack:** Swift 6.0 / swift-testing（`import Testing` + `@Suite`/`@Test`/`#expect`）/ CoreGraphics（跨平台）/ UIKit（仅 arbiter，`#if canImport(UIKit)`）。

**依赖：** C2 DecelerationAnimator（PR #60 merged）+ Reducer（PR #47/#48）。本 PR 不直接 import 这些类型，但 **onPan 回调语义必须与 Reducer action 契约对齐**（见下「下游契约」），scope 仅到回调出口。

---

## 下游契约（决定 onPan 双参语义；codex R1 finding 1+2 修正依据）

`ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift` 既有 action：
- `case offsetApplied(deltaPixels: CGFloat)`（L101）—— reducer **累加** delta 到 offset + bump revision。
- `case panEnded(velocity: CGFloat)`（L94）—— `(.freeScrolling, .panEnded(let v)) → .startDeceleration(velocity: v)`（L139-141）→ `DecelerationAnimator.start(initialVelocity: v)`。
- `case panStarted`（L123 注释列）—— autoTracking → freeScrolling 转换。

故 `UIPanGestureRecognizer` 的 **累积 translation 必须换算成帧间增量**再出回调（否则下游累加得 10+20+30=60 而非净 30，codex R1 finding 1）；**松手必须surface 释放速度** `velocity(in:).x`（否则惯性滚动拿不到初速，codex R1 finding 2）。

**因此 spec 未标注的 `onPan: ((CGFloat, CGFloat, GesturePhase))` 两个 CGFloat 定义为 `(incrementalDeltaX, velocityX, phase)`**：
| onPan 回调 phase | incrementalDeltaX | velocityX | 消费者（C8/E5）派发 |
|---|---|---|---|
| `.began`（首次锁定水平时发） | 0 | 锁定瞬时速度 | `.panStarted` |
| `.changed` | 帧间水平增量 | 实时水平速度 | `.offsetApplied(deltaPixels: incrementalDeltaX)` |
| `.ended` | 0（残量见下） | 释放水平速度 | `.panEnded(velocity: velocityX)` |
| `.cancelled` | 0（残量见下） | 0 | `.panEnded(velocity: 0)` |

**关键 1（R2 finding 修正）**：上表回调**仅在手势被 `classifySingleFingerPan` 锁定为水平后才发**。垂直 / ambiguous 单指手势全程**不发任何 onPan**（emissions==[]），绝不把 reducer 从 autoTracking 推到 freeScrolling / 启动减速。该不变量由纯函数 `singlePanStep` 承载并被 `SinglePanStepTests` 单测覆盖。UIKit 真实 `.began` 相位被吞，水平锁定瞬间合成一个 `.began` 回调。

**关键 2（R7 finding-2 修正）**：终止时若末段还有残量位移，arbiter 在该回调内**先发一个 `.changed`(残量) 再发终止相位**（共 2 个 onPan）——消费者照常 `.changed→offsetApplied`、终止→`panEnded`，**残量精确应用一次不丢**（消费者无需也不应忽略 `.ended` 之前的 `.changed`）。残量为 0 时只发终止一个。drawing 截获 / 多指接管的取消路径同样补残量再 `.cancelled`（R13 finding-2）。

**关键 3（R13 finding-1 修正）**：`.changed` 增量为 0（识别器重复回调 x 不变）时**不发** onPan——避免下游 `offsetApplied(0)` 空 bump reducer revision、误使绘图快照失效。

---

## 设计约束与残留（codex review 重点审视项，前置声明）

1. **arbiter 无 macOS 单测，是平台固有约束。** `UIGestureRecognizerDelegate` / `UIPanGestureRecognizer` / `UIView` 等 UIKit 独有，plain macOS SDK 无对等 API。arbiter 整类 `#if canImport(UIKit)`：macOS `swift build` 编译为空；Catalyst `xcodebuild` 真实编译（required `Mac Catalyst build-for-testing on macos-15`）；运行时手势触发 + `attach(to:)` 幂等性 = 真机/Catalyst 验收残留（plan v1.5 §验收 L1177）。所有**非平凡决策与生命周期逻辑都在被全量单测的纯函数里**（3 分类 + `panIncrement` + `singlePanStep` + `twoFingerStep`）；arbiter 内未测部分仅为 UIKit 管道：识别器声明式配置/挂载/卸载、`State→GesturePhase` 平凡 switch、跨识别器实时值读取、把纯函数结果转回调。
2. **两指仲裁是纯函数生命周期状态机 `twoFingerStep`（修正 R1 finding 3 + R3 + R5 finding-2）。** pinch 与两指 pan 两个独立识别器、**放行同时识别**、各喂对方实时值进**同一** `twoFingerStep`（带 `source` 标识）。内部用 `classifyTwoFingerGesture` 判定（`.pinch` 分支转活），**意图一旦锁定 pinch 即锁死**（后续不切周期、终止始终关闭 pinch 生命周期、切周期仅未锁定时终止发一次）。**真顺序无关**：状态机分别跟踪 `pinchDown`/`panDown`，**仅当两者皆 false 才结算**——一个识别器先终止只清自己 down 标志延后结算，滞后识别器回调不重启/不泄漏；孤立终止（无 began）no-op。arbiter 持两识别器 **weak** 引用（view 持有，避免环），仅存 `twoFingerState` 一字段。
3. **单指平移生命周期是纯函数 `singlePanStep` 三态机 `idle/horizontalActive/verticalRejected`（修正 R2 + R4 + R9 finding-1）。** 方向判定用累积位移过 `classifySingleFingerPan`；**仅 `horizontalActive` 才发 onPan**——`idle`(等待)/`verticalRejected`(已拒) 全程零回调，不触碰 reducer pan 状态。**垂直一旦判定即 latch 为 `verticalRejected`**，后续累积即便满足水平分类器也不翻成 pan（R9 finding-1）。锁定水平瞬间合成 `.began`（消费者 panStarted）+ 基线设当前累积（deadzone 不计入）；之后 `panIncrement` 出增量；终止仅 active 时发、`.ended` 携 `velocity(in:).x`、`.cancelled` 速度归零、末段残量先补 `.changed`（R7 finding-2）。`drawingTakesOver` 折入：截获清空状态、active 时先发 `.cancelled` 关闭生命周期（R4 + R5 finding-1）。arbiter 仅存 `lastTranslationX` + `singlePanLifecycle` 两字段（macOS 单测穷举垂直 latch/ambiguous/水平/drawing-截获 全生命周期）。
4. **边界语义严格对齐 spec 字面（一处 verify-and-correct）**：`dy > dx*1.2`、`dx > dy*1.5` / `dy > dx*1.5`、`dx < minThreshold && dy < minThreshold` 全严格不等逐字。**唯一 verify-and-correct（R12 finding）**：pinch 阈值 spec 字面 `abs(scale-1.0) > 0.02` 在 Double 下 1.02/0.98 精确边界 FP 误判 → 改对称显式边界 `scale > 1.02 || scale < 0.98`（保 spec ">2% 偏离" 意图，消 FP wart）。边界相等值归属由单测固定（含对称 0.98）。codex 若就其余 `>` vs `>=` 无 spec 依据反复挖，按 `feedback_codex_plan_budget_overshoot` pushback。

5. **单指↔两指优先级（spec L95）= 确定性 touch-count 升级（R8 finding-2 / R9 finding-2 / R10 finding-1）。** 干净场景靠 `maxTouches=1`/`minTouches=2` + 委托 pan+pan 互斥。**不用 `single.require(toFail:)`**（会卡死单指响应，R9）。**交错起手**用**确定性接管**：两指 pan / pinch `.began` 时 `supersedeSinglePanForMultitouch()` 切 `single.isEnabled` 取消进行中的单指 pan（其 `.cancelled` 经 `singlePanStep` 关闭消费者生命周期），路由权交两指。单指响应性不受影响（仅在第 2 指真触发多指手势时才取消）。运行时手势 fire 行为（真机/Catalyst 验收）仍是残留，但**优先级设计已确定不再靠 UX 调优**。

---

## File Structure

- **Create** `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift`
  4 值类型（`GesturePhase`/`TwoFingerIntent`/`SingleFingerPanIntent`/`DrawingModePanPolicy`）+ 3 分类纯函数（spec 逐字）+ `panIncrement` + `singlePanStep`（单指生命周期）+ `twoFingerStep`（两指生命周期）纯函数（+ internal `SinglePanLifecycle`/`SinglePanStep`/`SinglePanEmission`/`TwoFingerEmission`/`TwoFingerSource`/`TwoFingerState`/`TwoFingerStepResult`）。跨平台。`SwipeDirection` 复用 `Models.swift`。
- **Create** `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift`
  `ChartGestureArbiter` UIKit 类——5 回调 + drawingMode + attach + 委托 + @objc handlers + per-gesture 增量状态 + 两指仲裁。整文件 `#if canImport(UIKit)`。
- **Create** `ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift`
  4 纯函数穷举单测（含 `panIncrement` 多帧净位移）+ 值类型 Equatable。跨平台。
- **Create** `docs/acceptance/2026-05-23-pr-c7-gesture-arbiter.md`
  非 coder 验收清单（中文、二元可决、禁忌词见 `.claude/workflow-rules.json`）。

---

## Task 0 — §15.3 评审策略前置

- [ ] **局部对抗性评审**（必）：本 plan C7 scope 内 `codex:adversarial-review`；plan-stage + branch-diff 各 4-5 轮内收敛或 escalate（per `feedback_codex_plan_budget_overshoot`）。
- [ ] 集成层评审（C8/E5 PR 必）：**本 PR 不涉及**。
- [ ] 性能评审（Phase 5 PR 必）：**本 PR 不涉及**。

完成 Task 0 才进 Task 1。

---

## Task 1: 值类型 + 4 个纯函数（GestureClassifiers.swift）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift`

- [ ] **Step 1: 写失败测试（4 函数穷举 + 值类型）**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("classifyTwoFingerGesture")
struct ClassifyTwoFingerGestureTests {
    @Test("scale 放大超阈值 → pinch")
    func scaleZoomIn() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: 100), scale: 1.5) == .pinch)
    }
    @Test("scale 缩小超阈值 → pinch")
    func scaleZoomOut() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 999, y: 999), scale: 0.5) == .pinch)
    }
    @Test("scale 恰在上边界 1.02 不算 pinch（显式 > 1.02，R12 FP 修正）")
    func scaleAtBoundaryNotPinch() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 1.02) == .switchPeriod(.up))
    }
    @Test("scale 略超上边界 → pinch")
    func scaleJustOverBoundary() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 1.0201) == .pinch)
    }
    @Test("scale 恰在下边界 0.98 不算 pinch（对称）")
    func scaleAtLowerBoundaryNotPinch() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 0.98) == .switchPeriod(.up))
    }
    @Test("scale 略低于下边界 → pinch")
    func scaleJustUnderLowerBoundary() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 0.9799) == .pinch)
    }
    @Test("两指上滑 → switchPeriod up")
    func swipeUp() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 10, y: -100), scale: 1.0) == .switchPeriod(.up))
    }
    @Test("两指下滑 → switchPeriod down")
    func swipeDown() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 10, y: 100), scale: 1.0) == .switchPeriod(.down))
    }
    @Test("水平为主 → ignore")
    func horizontalIgnore() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 100, y: 50), scale: 1.0) == .ignore)
    }
    @Test("dy 恰为 dx*1.2 → ignore（严格 >）")
    func dyAtBoundaryIgnore() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 100, y: 120), scale: 1.0) == .ignore)
    }
}

@Suite("classifySingleFingerPan")
struct ClassifySingleFingerPanTests {
    @Test("微动低于阈值 → ambiguous")
    func belowThreshold() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 5, y: 5)) == .ambiguous)
    }
    @Test("右滑 → horizontal 正 delta")
    func horizontalRight() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 100, y: 10)) == .horizontal(delta: 100))
    }
    @Test("左滑 → horizontal 负 delta")
    func horizontalLeft() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: -100, y: 10)) == .horizontal(delta: -100))
    }
    @Test("垂直为主 → vertical")
    func vertical() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 10, y: 100)) == .vertical)
    }
    @Test("斜向 45° → ambiguous")
    func diagonalAmbiguous() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 50, y: 50)) == .ambiguous)
    }
    @Test("纯水平但幅度不足 → ambiguous（阈值先判）")
    func clearDirectionButTooSmall() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 5, y: 0)) == .ambiguous)
    }
    @Test("自定义阈值抬高门槛 → ambiguous")
    func customThreshold() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 30, y: 5), minThreshold: 40) == .ambiguous)
    }
}

@Suite("panPolicyInDrawingMode")
struct PanPolicyInDrawingModeTests {
    @Test("drawing 模式 → drawingTakesOver")
    func drawingOn() { #expect(panPolicyInDrawingMode(drawingMode: true) == .drawingTakesOver) }
    @Test("非 drawing 模式 → normalPass")
    func drawingOff() { #expect(panPolicyInDrawingMode(drawingMode: false) == .normalPass) }
}

@Suite("panIncrement")
struct PanIncrementTests {
    // 核心契约（修正 R1 finding 1）：累积 [10,20,30] 的逐帧增量为 [10,10,10]，和 == 末帧累积 30
    @Test("多帧累积换增量：增量和等于净位移")
    func multiFrameNetMovement() {
        let cumulative: [CGFloat] = [10, 20, 30]
        var last: CGFloat = 0
        var increments: [CGFloat] = []
        for c in cumulative {
            increments.append(panIncrement(current: c, last: last))
            last = c
        }
        #expect(increments == [10, 10, 10])
        #expect(increments.reduce(0, +) == 30)
        #expect(last == 30)
    }
    @Test("反向拖动增量为负")
    func reverseDirection() {
        #expect(panIncrement(current: -15, last: -5) == -10)
    }
    @Test("无移动增量为 0")
    func noMove() { #expect(panIncrement(current: 42, last: 42) == 0) }
}

@Suite("singlePanStep lifecycle")
struct SinglePanStepTests {
    // 垂直手势全程不产出回调（修正 R2 finding：不得触碰 reducer pan 状态）
    @Test("垂直单指手势全程 emissions 为空且 latch verticalRejected")
    func verticalNeverEmits() {
        let began = singlePanStep(phase: .began, cumulative: .zero, velocityX: 0, lifecycle: .idle, lastTranslationX: 99)
        #expect(began.emissions.isEmpty); #expect(began.lifecycle == .idle); #expect(began.lastTranslationX == 0)
        let changed = singlePanStep(phase: .changed, cumulative: CGPoint(x: 5, y: 100), velocityX: 800,
                                    lifecycle: began.lifecycle, lastTranslationX: began.lastTranslationX)
        #expect(changed.emissions.isEmpty); #expect(changed.lifecycle == .verticalRejected)
        let ended = singlePanStep(phase: .ended, cumulative: CGPoint(x: 5, y: 120), velocityX: 900,
                                  lifecycle: changed.lifecycle, lastTranslationX: changed.lastTranslationX)
        #expect(ended.emissions.isEmpty)   // 关键：垂直手势松手不发 panEnded，不启动减速
    }
    // R9 finding-1：垂直一旦判定即 latch，后续累积满足水平分类器也不得翻成 pan
    @Test("垂直 latch 后水平累积不翻成 pan")
    func verticalLatchedBlocksLaterHorizontal() {
        // 首帧垂直（5,100）→ verticalRejected
        let v = singlePanStep(phase: .changed, cumulative: CGPoint(x: 5, y: 100), velocityX: 0,
                              lifecycle: .idle, lastTranslationX: 0)
        #expect(v.lifecycle == .verticalRejected); #expect(v.emissions.isEmpty)
        // 后续累积变成明显水平（200,100）→ 仍 latch，零回调（不发 .began）
        let later = singlePanStep(phase: .changed, cumulative: CGPoint(x: 200, y: 100), velocityX: 500,
                                  lifecycle: v.lifecycle, lastTranslationX: v.lastTranslationX)
        #expect(later.emissions.isEmpty); #expect(later.lifecycle == .verticalRejected)
    }
    // ambiguous（斜向 / 微动）保持 idle、零回调（仍可后续锁定方向）
    @Test("ambiguous 手势保持 idle 零回调")
    func ambiguousStaysIdle() {
        let s = singlePanStep(phase: .changed, cumulative: CGPoint(x: 50, y: 50), velocityX: 100,
                              lifecycle: .idle, lastTranslationX: 0)
        #expect(s.emissions.isEmpty); #expect(s.lifecycle == .idle)
    }
    // 水平手势：首次锁定发 .began(delta 0)，后续发 .changed 增量，松手发末段残量 .changed + .ended
    @Test("水平手势激活→增量→松手残量+速度全链")
    func horizontalActivationLifecycle() {
        let begin = singlePanStep(phase: .began, cumulative: .zero, velocityX: 0, lifecycle: .idle, lastTranslationX: 0)
        #expect(begin.emissions.isEmpty)
        // 首个水平 .changed（累积 20）：发 .began，delta 0，基线设 20（deadzone 不计入）
        let lock = singlePanStep(phase: .changed, cumulative: CGPoint(x: 20, y: 3), velocityX: 600,
                                 lifecycle: begin.lifecycle, lastTranslationX: begin.lastTranslationX)
        #expect(lock.emissions == [SinglePanEmission(deltaX: 0, velocityX: 600, phase: .began)])
        #expect(lock.lifecycle == .horizontalActive); #expect(lock.lastTranslationX == 20)
        // 后续 .changed（累积 30）：发 .changed，delta 10
        let move = singlePanStep(phase: .changed, cumulative: CGPoint(x: 30, y: 4), velocityX: 700,
                                 lifecycle: lock.lifecycle, lastTranslationX: lock.lastTranslationX)
        #expect(move.emissions == [SinglePanEmission(deltaX: 10, velocityX: 700, phase: .changed)])
        // .ended（累积 35）：末段残量 5 → 先发 .changed(5) 再发 .ended(0)；两者携 velocity 900（R7 finding-2）
        let end = singlePanStep(phase: .ended, cumulative: CGPoint(x: 35, y: 4), velocityX: 900,
                                lifecycle: move.lifecycle, lastTranslationX: move.lastTranslationX)
        #expect(end.emissions == [SinglePanEmission(deltaX: 5, velocityX: 900, phase: .changed),
                                  SinglePanEmission(deltaX: 0, velocityX: 900, phase: .ended)])
        #expect(end.lifecycle == .idle)
    }
    // 残量为 0（松手时无新位移）→ 仅发终止一个
    @Test("松手无残量 → 仅终止一个 emission")
    func endedNoResidual() {
        let end = singlePanStep(phase: .ended, cumulative: CGPoint(x: 30, y: 4), velocityX: 900,
                                lifecycle: .horizontalActive, lastTranslationX: 30)
        #expect(end.emissions == [SinglePanEmission(deltaX: 0, velocityX: 900, phase: .ended)])
    }
    // R13 finding-1：horizontalActive 下 x 不变（current==last）→ 不发 .changed，避免下游 offsetApplied(0) 空 bump revision
    @Test("零 delta .changed 不发回调")
    func zeroDeltaChangedSuppressed() {
        let s = singlePanStep(phase: .changed, cumulative: CGPoint(x: 30, y: 7), velocityX: 700,
                              lifecycle: .horizontalActive, lastTranslationX: 30)
        #expect(s.emissions.isEmpty); #expect(s.lifecycle == .horizontalActive); #expect(s.lastTranslationX == 30)
    }
    // .cancelled 在已激活时发终止但速度归零（不启动减速的释放速度）；残量 10 先补
    @Test("cancelled 在激活态发残量+终止且 velocity 归零")
    func cancelledZeroVelocity() {
        let end = singlePanStep(phase: .cancelled, cumulative: CGPoint(x: 50, y: 4), velocityX: 999,
                                lifecycle: .horizontalActive, lastTranslationX: 40)
        #expect(end.emissions == [SinglePanEmission(deltaX: 10, velocityX: 0, phase: .changed),
                                  SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled)])
        #expect(end.lifecycle == .idle)
    }
    // R4 + R5 finding-1 + R13 finding-2：drawing 中途截获活跃水平 pan → 先补末段残量 .changed 再 .cancelled，关闭生命周期 + reset
    @Test("drawing 截获活跃 pan → 残量 + cancelled + reset")
    func drawingTakeoverCancelsActive() {
        // 截获时累积 80、基线 40 → 残量 40 先补，再 .cancelled（R13 finding-2 不丢接管前位移）
        let intercepted = singlePanStep(phase: .changed, cumulative: CGPoint(x: 80, y: 4), velocityX: 700,
                                        lifecycle: .horizontalActive, lastTranslationX: 40, drawingTakesOver: true)
        #expect(intercepted.emissions == [SinglePanEmission(deltaX: 40, velocityX: 0, phase: .changed),
                                          SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled)])
        #expect(intercepted.lifecycle == .idle); #expect(intercepted.lastTranslationX == 0)
        // 截获再来一帧（仍 drawing、已 idle）→ 不再发回调
        let stillDrawing = singlePanStep(phase: .changed, cumulative: CGPoint(x: 85, y: 4), velocityX: 700,
                                         lifecycle: intercepted.lifecycle, lastTranslationX: intercepted.lastTranslationX,
                                         drawingTakesOver: true)
        #expect(stillDrawing.emissions.isEmpty)
        // drawing 关闭后下一个 .changed：从干净态重新分类，累积 90 水平 → 锁定发 .began delta 0（不灌 stale delta）
        let resumed = singlePanStep(phase: .changed, cumulative: CGPoint(x: 90, y: 4), velocityX: 700,
                                    lifecycle: stillDrawing.lifecycle, lastTranslationX: stillDrawing.lastTranslationX,
                                    drawingTakesOver: false)
        #expect(resumed.emissions == [SinglePanEmission(deltaX: 0, velocityX: 700, phase: .began)])
        #expect(resumed.lastTranslationX == 90)
    }
    // drawing 截获时本就未激活（idle）→ 纯 reset 无回调
    @Test("drawing 截获非活跃 pan → 无回调")
    func drawingTakeoverInactiveNoEmit() {
        let s = singlePanStep(phase: .changed, cumulative: CGPoint(x: 80, y: 4), velocityX: 700,
                              lifecycle: .idle, lastTranslationX: 0, drawingTakesOver: true)
        #expect(s.emissions.isEmpty); #expect(s.lifecycle == .idle)
    }
    // R11 finding：多指接管同步关闭——horizontalActive 无残量（current==last）→ 恰发一个 .cancelled + 复位，不依赖回调投递
    @Test("supersede horizontalActive 无残量 → 恰一个 cancelled")
    func supersedeActiveNoResidual() {
        let s = singlePanSupersede(lifecycle: .horizontalActive, cumulative: CGPoint(x: 30, y: 5), lastTranslationX: 30)
        #expect(s.emissions == [SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled)])
        #expect(s.lifecycle == .idle); #expect(s.lastTranslationX == 0)
    }
    // R13 finding-2：supersede 时基线落后于当前累积 → 先补残量 .changed 再 .cancelled，不丢接管前位移
    @Test("supersede horizontalActive 有残量 → 残量 + cancelled")
    func supersedeActiveWithResidual() {
        let s = singlePanSupersede(lifecycle: .horizontalActive, cumulative: CGPoint(x: 55, y: 5), lastTranslationX: 40)
        #expect(s.emissions == [SinglePanEmission(deltaX: 15, velocityX: 0, phase: .changed),
                                SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled)])
    }
    // supersede 在 idle / verticalRejected → 无 emission，仍复位
    @Test("supersede 非活跃态无回调仍复位")
    func supersedeInactiveNoEmit() {
        #expect(singlePanSupersede(lifecycle: .idle, cumulative: CGPoint(x: 99, y: 0), lastTranslationX: 0).emissions.isEmpty)
        let v = singlePanSupersede(lifecycle: .verticalRejected, cumulative: CGPoint(x: 99, y: 0), lastTranslationX: 0)
        #expect(v.emissions.isEmpty); #expect(v.lifecycle == .idle)
    }
}

@Suite("twoFingerStep lifecycle")
struct TwoFingerStepTests {
    // R3 核心反例：先 pinch 越阈值 → 后回落 scale≈1.0 + 垂直平移结束 → 只发 pinch 生命周期，绝不切周期
    // （单识别器序列：pan 未参与，pinch began/changed/ended 即两 down 归零结算）
    @Test("pinch 锁定后末帧回落不触发切周期")
    func pinchLockSuppressesSwipe() {
        var st = TwoFingerState()
        let began = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st); st = began.state
        #expect(began.emission == nil)
        let lock = twoFingerStep(source: .pinch, phase: .changed, scale: 1.05, translation: .zero, state: st); st = lock.state
        #expect(lock.emission == .pinch(scale: 1.05, phase: .began)); #expect(st.locked)
        // 末帧 scale 回落到 1.0 且垂直平移大 → 仍发 pinch(.ended)，不发 switchPeriod
        let end = twoFingerStep(source: .pinch, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -200), state: st); st = end.state
        #expect(end.emission == .pinch(scale: 1.0, phase: .ended))
        #expect(st == TwoFingerState())
    }
    // 反向失败模式：已 emit 的 pinch 末帧 scale 回落阈值内仍须关闭生命周期（不丢 .ended）
    @Test("锁定 pinch 末帧 scale 在阈值内仍发 ended")
    func pinchTerminalAlwaysClosed() {
        let st = TwoFingerState(pinchDown: true, panDown: false, locked: true)
        let end = twoFingerStep(source: .pinch, phase: .ended, scale: 1.001, translation: .zero, state: st)
        #expect(end.emission == .pinch(scale: 1.001, phase: .ended))
    }
    // 纯垂直两指 swipe（无 pinch）：changed 不发，ended 发一次 switchPeriod
    @Test("纯垂直两指 → ended 发一次 switchPeriod")
    func verticalSwipe() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        let changed = twoFingerStep(source: .pan, phase: .changed, scale: 1.0, translation: CGPoint(x: 5, y: -100), state: st); st = changed.state
        #expect(changed.emission == nil); #expect(st.locked == false)
        let end = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 5, y: -120), state: st); st = end.state
        #expect(end.emission == .switchPeriod(.up))
        #expect(st == TwoFingerState())
    }
    // R5 finding-2 核心：pinch 锁定 + 先终止（另一识别器仍在按）→ 延后；滞后 pan 的 changed/ended 不泄漏切周期
    @Test("pinch 锁定先终止 + 滞后 pan 终止 → 只 pinch.ended 无 switchPeriod（顺序无关）")
    func lateRecognizerNoLeak() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st).state
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        // pinch 锁定
        let lock = twoFingerStep(source: .pinch, phase: .changed, scale: 1.06, translation: .zero, state: st); st = lock.state
        #expect(lock.emission == .pinch(scale: 1.06, phase: .began))
        // pinch 先 ended（scale 1.06 记入 lastPinchScale），但 pan 仍 down → 延后，不发
        let pinchEnd = twoFingerStep(source: .pinch, phase: .ended, scale: 1.06, translation: .zero, state: st); st = pinchEnd.state
        #expect(pinchEnd.emission == nil); #expect(st.panDown == true && st.locked == true)
        // 滞后 pan 的 changed（pinch 已抬起，scale=1.0 是 stale）→ 抑制，不发 stale pinch.changed（R10 finding-2）
        let lagChanged = twoFingerStep(source: .pan, phase: .changed, scale: 1.0, translation: CGPoint(x: 0, y: -200), state: st); st = lagChanged.state
        #expect(lagChanged.emission == nil)
        // pan ended（两 down 归零）→ 结算发 pinch.ended，scale 用 lastPinchScale=1.06（非 stale 1.0），无 switchPeriod
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -240), state: st); st = panEnd.state
        #expect(panEnd.emission == .pinch(scale: 1.06, phase: .ended))
        #expect(st == TwoFingerState())
    }
    // R6 finding-1：锁定 pinch 先 .cancelled（pan 仍 down 延后）→ 滞后 pan .ended 结算须发 pinch(.cancelled) 不是 .ended
    @Test("锁定 pinch 先 cancelled 滞后 pan ended → 发 pinch(.cancelled)")
    func lockedPinchCancellationPreserved() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st).state
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        let lock = twoFingerStep(source: .pinch, phase: .changed, scale: 1.08, translation: .zero, state: st); st = lock.state
        #expect(lock.emission == .pinch(scale: 1.08, phase: .began))
        let pinchCancel = twoFingerStep(source: .pinch, phase: .cancelled, scale: 1.08, translation: .zero, state: st); st = pinchCancel.state
        #expect(pinchCancel.emission == nil); #expect(st.pendingTerminal == .cancelled)
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: .zero, state: st); st = panEnd.state
        #expect(panEnd.emission == .pinch(scale: 1.08, phase: .cancelled))   // 中断 pinch 不误报成功；scale 用 lastPinchScale 非 stale
        #expect(st == TwoFingerState())
    }
    // cancelled 的垂直两指手势不得切周期（离散成功动作只在正常 ended 触发）
    @Test("cancelled 垂直两指 → 不切周期")
    func cancelledSwipeSuppressed() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        let end = twoFingerStep(source: .pan, phase: .cancelled, scale: 1.0, translation: CGPoint(x: 0, y: -200), state: st)
        #expect(end.emission == nil)
    }
    // R7 finding-1：纯垂直 swipe，pan 先 ended（带垂直 translation）→ pinch 后 ended（translation 已失效为 .zero）→ swipe 不丢
    @Test("pan 先 ended 捕获方向 + pinch 后 ended 失效帧 → swipe 保留")
    func swipeSurvivesPanEndedFirst() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        st = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st).state
        // pan 先 ended（垂直 -120），pinch 仍 down → 延后，捕获 pendingSwipe=.up
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -120), state: st); st = panEnd.state
        #expect(panEnd.emission == nil); #expect(st.pendingSwipe == .up)
        // pinch 后 ended，此刻 pan translation 已失效（.zero）→ 用 pendingSwipe 结算
        let pinchEnd = twoFingerStep(source: .pinch, phase: .ended, scale: 1.0, translation: .zero, state: st); st = pinchEnd.state
        #expect(pinchEnd.emission == .switchPeriod(.up))
        #expect(st == TwoFingerState())
    }
    // 对称：pinch 先 ended（读到 pan 实时垂直 translation 捕获方向）→ pan 后 ended → swipe 不丢
    @Test("pinch 先 ended 捕获方向 + pan 后 ended → swipe 保留")
    func swipeSurvivesPinchEndedFirst() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pinch, phase: .began, scale: 1.0, translation: .zero, state: st).state
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        // pinch 先 ended，handlePinch 读 pan 实时 translation = 垂直 120（向下）→ 捕获 .down，pan 仍 down → 延后
        let pinchEnd = twoFingerStep(source: .pinch, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: 120), state: st); st = pinchEnd.state
        #expect(pinchEnd.emission == nil); #expect(st.pendingSwipe == .down)
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: 130), state: st); st = panEnd.state
        #expect(panEnd.emission == .switchPeriod(.down))
    }
    // R8 finding-1：旁观 pinch（从未 began）的 .failed→.cancelled 不得取消有效两指 swipe
    @Test("旁观 pinch failed 不取消有效两指 swipe")
    func failedPinchDoesNotCancelSwipe() {
        var st = TwoFingerState()
        st = twoFingerStep(source: .pan, phase: .began, scale: 1.0, translation: .zero, state: st).state
        // pinch 从未 began，却来 .cancelled（.failed 映射）→ 必须被忽略，不污染 pendingTerminal
        let pinchFail = twoFingerStep(source: .pinch, phase: .cancelled, scale: 1.0, translation: .zero, state: st); st = pinchFail.state
        #expect(pinchFail.emission == nil); #expect(st.pendingTerminal == nil); #expect(st.panDown == true)
        // pan 正常垂直结束 → 仍发 switchPeriod
        let panEnd = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -150), state: st); st = panEnd.state
        #expect(panEnd.emission == .switchPeriod(.up))
    }
    // 顺序无关 + 不双发：在干净（空）状态收到孤立终止回调 no-op
    @Test("空状态孤立终止回调 no-op（不双发）")
    func strayTerminalNoOp() {
        let second = twoFingerStep(source: .pan, phase: .ended, scale: 1.0, translation: CGPoint(x: 0, y: -200),
                                   state: TwoFingerState())
        #expect(second.emission == nil); #expect(second.state == TwoFingerState())
    }
}

@Suite("Gesture value types Equatable")
struct GestureValueTypeTests {
    @Test("switchPeriod 方向区分")
    func swipeDirDistinct() { #expect(TwoFingerIntent.switchPeriod(.up) != .switchPeriod(.down)) }
    @Test("horizontal delta 区分")
    func horizontalDeltaDistinct() {
        #expect(SingleFingerPanIntent.horizontal(delta: 1) != .horizontal(delta: 2))
    }
    @Test("GesturePhase 四相区分")
    func phasesDistinct() {
        #expect(GesturePhase.began != .changed)
        #expect(GesturePhase.ended != .cancelled)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --package-path ios/Contracts --filter ClassifyTwoFingerGestureTests`
Expected: 编译失败 / `cannot find 'classifyTwoFingerGesture' in scope`。

- [ ] **Step 3: 写最小实现（分类函数逐字 spec L1354-1395 + 增量函数）**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift
// Kline Trainer Swift Contracts — C7 手势分类/换算纯函数 + 值类型
// Spec: kline_trainer_modules_v1.4.md §C7（L1351-1406）+ kline_trainer_plan_v1.5.md §手势方案
// Plan: docs/superpowers/plans/2026-05-23-pr-c7-gesture-arbiter.md

import Foundation
import CoreGraphics

/// 手势生命周期相位（spec §C7）。映射自 UIGestureRecognizer.State，本类型跨平台。
public enum GesturePhase: Equatable, Sendable {
    case began, changed, ended, cancelled
}

/// 两指手势意图（spec §C7 v1.1）。
public enum TwoFingerIntent: Equatable, Sendable {
    case switchPeriod(SwipeDirection)
    case pinch
    case ignore
}

/// 两指意图分类（spec L1363-1368）。scale 偏离 1.0 超 2% 判 pinch；否则垂直分量显著（dy > dx*1.2）判切周期方向；其余忽略。
///
/// **verify-and-correct（R12 finding）**：spec 字面 `abs(scale - 1.0) > 0.02` 在 IEEE754 Double 下，`1.02 - 1.0` 舍入到
/// 略大于 `0.02` → 恰好 2% 边界（scale==1.02 / 0.98）被误判为 pinch（codex `swift -e` 实证）。这里用**对称显式边界**
/// 表达同一意图（>2% 偏离判 pinch），使恰好 2% 边界确定为**非 pinch**、避免减法舍入。等价于 spec 意图，仅消除 FP 边界 wart
/// （C1a xToIndex verify-and-correct 同类先例；非功能性改写——真实连续 scale 不会落在 measure-zero 的精确边界）。
public func classifyTwoFingerGesture(translation: CGPoint, scale: CGFloat) -> TwoFingerIntent {
    if scale > 1.02 || scale < 0.98 { return .pinch }
    let dx = abs(translation.x); let dy = abs(translation.y)
    if dy > dx * 1.2 { return .switchPeriod(translation.y < 0 ? .up : .down) }
    return .ignore
}

/// 单指平移意图（spec §C7 v1.2）。
public enum SingleFingerPanIntent: Equatable, Sendable {
    case horizontal(delta: CGFloat)             // 触发平移（delta = 入参 translation.x，累积或增量由调用方语义决定）
    case vertical                                // 忽略
    case ambiguous                               // 等待更多数据
}

/// 单指平移分类（spec L1377-1385 逐字）。两轴均低于 minThreshold 时等待；
/// 水平/垂直分量超 1.5 倍判明确方向；其余等待。
public func classifySingleFingerPan(translation: CGPoint,
                                    minThreshold: CGFloat = 8) -> SingleFingerPanIntent {
    let dx = abs(translation.x)
    let dy = abs(translation.y)
    if dx < minThreshold && dy < minThreshold { return .ambiguous }
    if dx > dy * 1.5 { return .horizontal(delta: translation.x) }
    if dy > dx * 1.5 { return .vertical }
    return .ambiguous
}

/// Drawing 模式 Pan 截获策略（spec §C7 v1.2）。
public enum DrawingModePanPolicy: Equatable, Sendable {
    case drawingTakesOver    // Pan 被绘线工具吃掉
    case normalPass          // 普通透传
}

/// Drawing 模式下 Pan 归属（spec L1393-1395 逐字）。
public func panPolicyInDrawingMode(drawingMode: Bool) -> DrawingModePanPolicy {
    drawingMode ? .drawingTakesOver : .normalPass
}

/// 累积平移 → 帧间增量。`UIPanGestureRecognizer.translation(in:)` 是整手势累积值，
/// 而下游 `Reducer.offsetApplied(deltaPixels:)` 按增量累加，故 arbiter 必须发增量。
/// 逐帧调用：`delta = panIncrement(current: 当前累积.x, last: 上一帧累积.x)`，调用后更新 last。
public func panIncrement(current: CGFloat, last: CGFloat) -> CGFloat {
    current - last
}

// MARK: - 单指平移生命周期状态机（纯函数，修正 R2 finding：垂直/ambiguous 不得触碰 reducer pan 状态）

/// 单指平移一次回调应发出的事件。
struct SinglePanEmission: Equatable {
    let deltaX: CGFloat
    let velocityX: CGFloat
    let phase: GesturePhase
}

/// 单指平移生命周期态（修正 R9 finding-1：垂直意图须 latch，不得后续翻成 pan）。
enum SinglePanLifecycle: Equatable {
    case idle               // 方向未定，仍可锁定水平 / 拒绝为垂直
    case horizontalActive   // 已锁定水平平移
    case verticalRejected   // 已判定垂直，本手势剩余全程忽略（latch）
}

/// 单指平移生命周期一步的纯决策结果。`emissions` 按序发（0/1/2 个）——终止带残量时发 2 个（先 .changed 后终止）。
struct SinglePanStep: Equatable {
    let emissions: [SinglePanEmission]   // [] = 本步不触发任何 onPan 回调
    let lifecycle: SinglePanLifecycle    // 本手势更新后的生命周期态
    let lastTranslationX: CGFloat        // 下一步增量基线
}

/// 单指平移生命周期纯决策。arbiter handler 把识别器原始值喂入、据返回更新状态并发回调。
/// 关键不变量：
/// - 仅 `horizontalActive` 才产出 pan emissions；`idle`(等待) / `verticalRejected`(已拒) 全程 emissions == []（R2 finding）；
/// - **垂直一旦判定即 latch 为 `verticalRejected`**，后续即便累积满足水平分类器也不再发回调（R9 finding-1）；
/// - `.began` 仅复位为 `idle` 不发回调；首次 `.horizontal` 才发 `.began`（消费者 panStarted），基线设当前累积（deadzone 不计入 offset）；
/// - 终止（R7 finding-2）：`horizontalActive` 时若末段有残量，**先发 `.changed`(残量) 再发终止相位**，残量精确应用一次不丢。
func singlePanStep(phase: GesturePhase,
                   cumulative: CGPoint,
                   velocityX: CGFloat,
                   lifecycle: SinglePanLifecycle,
                   lastTranslationX: CGFloat,
                   minThreshold: CGFloat = 8,
                   drawingTakesOver: Bool = false) -> SinglePanStep {
    // Drawing 模式截获（修正 R4 + R5 finding-1 + R13 finding-2）：清空 per-gesture 状态防残留；
    // 若**已激活**水平 pan，先补末段残量 `.changed`(若非零) 再发 `.cancelled` 关闭生命周期——
    // 不丢截获前最后一段拖动位移（R13 finding-2），且避免下游 panStarted 悬空无终止（R5 finding-1）。
    if drawingTakesOver {
        if lifecycle == .horizontalActive {
            let residual = panIncrement(current: cumulative.x, last: lastTranslationX)
            var emissions: [SinglePanEmission] = []
            if residual != 0 { emissions.append(SinglePanEmission(deltaX: residual, velocityX: 0, phase: .changed)) }
            emissions.append(SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled))
            return SinglePanStep(emissions: emissions, lifecycle: .idle, lastTranslationX: 0)
        }
        return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: 0)
    }
    switch phase {
    case .began:
        return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: 0)
    case .changed:
        switch lifecycle {
        case .horizontalActive:
            let delta = panIncrement(current: cumulative.x, last: lastTranslationX)
            // 零 delta（识别器重复回调 x 不变）→ 不发，避免下游 offsetApplied(0) 空 bump revision（R13 finding-1）
            if delta == 0 {
                return SinglePanStep(emissions: [], lifecycle: .horizontalActive, lastTranslationX: lastTranslationX)
            }
            return SinglePanStep(
                emissions: [SinglePanEmission(deltaX: delta, velocityX: velocityX, phase: .changed)],
                lifecycle: .horizontalActive, lastTranslationX: cumulative.x)
        case .verticalRejected:
            return SinglePanStep(emissions: [], lifecycle: .verticalRejected, lastTranslationX: lastTranslationX)  // latch
        case .idle:
            switch classifySingleFingerPan(translation: cumulative, minThreshold: minThreshold) {
            case .horizontal:
                return SinglePanStep(
                    emissions: [SinglePanEmission(deltaX: 0, velocityX: velocityX, phase: .began)],
                    lifecycle: .horizontalActive, lastTranslationX: cumulative.x)
            case .vertical:
                return SinglePanStep(emissions: [], lifecycle: .verticalRejected, lastTranslationX: lastTranslationX)  // latch 垂直
            case .ambiguous:
                return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: lastTranslationX)  // 继续等待
            }
        }
    case .ended, .cancelled:
        if lifecycle == .horizontalActive {
            let residual = panIncrement(current: cumulative.x, last: lastTranslationX)
            let v: CGFloat = phase == .ended ? velocityX : 0
            var emissions: [SinglePanEmission] = []
            if residual != 0 {   // 末段残量先补 offset（R7 finding-2），再发终止
                emissions.append(SinglePanEmission(deltaX: residual, velocityX: v, phase: .changed))
            }
            emissions.append(SinglePanEmission(deltaX: 0, velocityX: v, phase: phase))
            return SinglePanStep(emissions: emissions, lifecycle: .idle, lastTranslationX: cumulative.x)
        }
        return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: lastTranslationX)  // idle/verticalRejected → 复位
    }
}

/// 多指接管时**同步**关闭单指生命周期的纯决策（R11 finding：正确性不得依赖 `isEnabled` toggle 的 .cancelled 回调投递）。
/// `horizontalActive` → 先补末段残量 `.changed`(若非零，R13 finding-2 不丢接管前位移) 再发 `.cancelled` 关闭；
/// `idle`/`verticalRejected` → 无 emission。一律复位为 `.idle` + 基线 0（arbiter 据此同步更新，再物理 toggle 识别器作防御性清理）。
func singlePanSupersede(lifecycle: SinglePanLifecycle, cumulative: CGPoint, lastTranslationX: CGFloat) -> SinglePanStep {
    guard lifecycle == .horizontalActive else {
        return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: 0)
    }
    let residual = panIncrement(current: cumulative.x, last: lastTranslationX)
    var emissions: [SinglePanEmission] = []
    if residual != 0 { emissions.append(SinglePanEmission(deltaX: residual, velocityX: 0, phase: .changed)) }
    emissions.append(SinglePanEmission(deltaX: 0, velocityX: 0, phase: .cancelled))
    return SinglePanStep(emissions: emissions, lifecycle: .idle, lastTranslationX: 0)
}

// MARK: - 两指手势生命周期状态机（纯函数，修正 R3 finding：意图须锁定，不得跨回调重分类）

/// 两指手势一次应发出的事件（focus 由 arbiter 从识别器补）。
enum TwoFingerEmission: Equatable {
    case pinch(scale: CGFloat, phase: GesturePhase)
    case switchPeriod(SwipeDirection)
}

/// 事件来源识别器（pinch 与两指 pan 同时识别，各发各的 began/changed/ended）。
enum TwoFingerSource: Equatable { case pinch, pan }

/// 两指手势生命周期状态。跟踪两识别器是否在按（`pinchDown`/`panDown`）+ 是否锁定 pinch（`locked`）
/// + 延后结算时已记下的终止 phase（`pendingTerminal`，`.cancelled` 压倒 `.ended`）
/// + 延后时已捕获的切周期方向（`pendingSwipe`，防滞后识别器结算时 translation 已失效，R7 finding-1）。
struct TwoFingerState: Equatable {
    var pinchDown = false
    var panDown = false
    var locked = false
    var pendingTerminal: GesturePhase? = nil
    var pendingSwipe: SwipeDirection? = nil
    var lastPinchScale: CGFloat = 1.0    // 最近一次 pinch 源报告的 scale；pan 源/终止结算复用，防 stale（R10 finding-2）
}

/// `twoFingerStep` 返回。
struct TwoFingerStepResult: Equatable {
    let emission: TwoFingerEmission?
    let state: TwoFingerState
}

/// 两指生命周期纯决策。pinch 与两指 pan 两识别器**交错**调用、各喂对方实时值（scale / translation），
/// 并传 `source` 标识本次回调来自哪个识别器。关键不变量：
/// - 一旦 `classifyTwoFingerGesture == .pinch`，**锁定** intent，后续 `.changed` 全发 pinch、**不再可能切周期**（R3）；
/// - 已锁定 pinch 在终止相位**始终**发 `pinch(.ended/.cancelled)`，无论末帧 scale（不丢生命周期，R3）；
/// - 切周期仅在**未锁定** 且终止时垂直发一次（R3）；
/// - **真顺序无关**（R5 finding-2）：终止结算仅当 `pinchDown` 与 `panDown` 双双归 false 才发生；
///   一个识别器先终止只清自己的 down 标志、延后结算，滞后识别器的 `.changed/.ended` 不会重启手势或泄漏切周期。
func twoFingerStep(source: TwoFingerSource, phase: GesturePhase, scale: CGFloat, translation: CGPoint,
                   state: TwoFingerState) -> TwoFingerStepResult {
    var st = state
    func setDown(_ v: Bool) { switch source { case .pinch: st.pinchDown = v; case .pan: st.panDown = v } }
    switch phase {
    case .began:
        setDown(true)
        return TwoFingerStepResult(emission: nil, state: st)
    case .changed:
        setDown(true)   // .changed 蕴含本识别器活跃
        if st.locked {
            // 仅 pinch 源、或 pinch 仍在按时（scale 为 pinch 实时有效值）才发 pinch.changed 并记 lastPinchScale；
            // pinch 已抬起后 pan 源的 scale 是 stale（默认 1.0）→ 抑制，避免缩放跳变（R10 finding-2）
            if source == .pinch || st.pinchDown {
                st.lastPinchScale = scale
                return TwoFingerStepResult(emission: .pinch(scale: scale, phase: .changed), state: st)
            }
            return TwoFingerStepResult(emission: nil, state: st)
        }
        if classifyTwoFingerGesture(translation: translation, scale: scale) == .pinch {
            st.locked = true
            st.lastPinchScale = scale
            return TwoFingerStepResult(emission: .pinch(scale: scale, phase: .began), state: st)
        }
        return TwoFingerStepResult(emission: nil, state: st)   // 切周期延后到终止判定
    case .ended, .cancelled:
        // 本识别器从未参与（never began，如 .failed→.cancelled 的旁观 pinch）→ 完全忽略，不污染生命周期（R8 finding-1）
        let thisSourceWasDown = (source == .pinch) ? st.pinchDown : st.panDown
        guard thisSourceWasDown else { return TwoFingerStepResult(emission: nil, state: st) }
        setDown(false)
        if source == .pinch { st.lastPinchScale = scale }   // pinch 自身终止 scale 有效 → 记下供结算（R10 finding-2）
        // 合并终止意图：任一识别器 .cancelled 则整手势视为 cancelled（压倒 .ended），见 R6 finding-1
        let effectivePhase: GesturePhase = (phase == .cancelled || st.pendingTerminal == .cancelled) ? .cancelled : .ended
        // 本次终止回调时（translation 仍有效）捕获切周期方向；与已记 pendingSwipe 取首个非空（R7 finding-1）
        var swipe = st.pendingSwipe
        if swipe == nil, !st.locked,
           case .switchPeriod(let dir) = classifyTwoFingerGesture(translation: translation, scale: scale) {
            swipe = dir
        }
        // 另一识别器仍在按 → 记下 pending 终止 phase + 已捕获的切周期方向，延后结算（R5 finding-2 + R6 + R7 finding-1）
        if st.pinchDown || st.panDown {
            st.pendingTerminal = effectivePhase
            st.pendingSwipe = swipe
            return TwoFingerStepResult(emission: nil, state: st)
        }
        // 至此本识别器确曾参与（thisSourceWasDown）且两 down 皆归零 → 结算
        let reset = TwoFingerState()
        if st.locked {
            // 锁定 pinch：用合并后的 effectivePhase 关闭生命周期（中断的 pinch 不得误报成功，R6 finding-1）；
            // scale 用 lastPinchScale（pinch 源最后有效值），不用结算回调可能 stale 的 scale（R10 finding-2）
            return TwoFingerStepResult(emission: .pinch(scale: st.lastPinchScale, phase: effectivePhase), state: reset)
        }
        // 切周期是离散成功动作：仅正常结束（非 cancelled）才发；用 defer 时捕获的方向（防滞后帧 translation 失效，R7 finding-1）
        if effectivePhase == .ended, let dir = swipe {
            return TwoFingerStepResult(emission: .switchPeriod(dir), state: reset)
        }
        return TwoFingerStepResult(emission: nil, state: reset)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --package-path ios/Contracts --filter ClassifyTwoFingerGestureTests` 然后依次 `--filter ClassifySingleFingerPanTests`、`--filter PanPolicyInDrawingModeTests`、`--filter PanIncrementTests`、`--filter SinglePanStepTests`、`--filter TwoFingerStepTests`、`--filter GestureValueTypeTests`
Expected: 各 suite `0 failures`。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift
git commit -m "feat(C7): 手势分类/增量纯函数 + 值类型（spec §C7 L1354-1395 逐字 + 下游增量契约）"
```

---

## Task 2: ChartGestureArbiter（UIKit 适配薄层 + 两指仲裁 + 增量/速度）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift`

> 说明：本 Task 无 macOS 单测（平台固有约束，见「设计约束与残留」#1）；验证靠 Task 3 Catalyst 编译闸门 + 真机验收。

- [ ] **Step 1: 写实现（整文件 `#if canImport(UIKit)`）**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift
// Kline Trainer Swift Contracts — C7 ChartGestureArbiter（UIKit 手势绑定 + 仲裁）
// Spec: kline_trainer_modules_v1.4.md §C7（L1397-1405）+ kline_trainer_plan_v1.5.md §手势仲裁规则（L90-100）
// Plan: docs/superpowers/plans/2026-05-23-pr-c7-gesture-arbiter.md
//
// 平台门：整类 UIKit-only。macOS swift build 编译为空；Catalyst 编译校验落 required CI 闸门。
// 决策逻辑全在 GestureClassifiers.swift 纯函数（macOS 全量单测）；本类只读识别器原始值 → 调纯函数 → 触发回调。

#if canImport(UIKit)
import UIKit
import CoreGraphics

/// K 线图手势仲裁器（spec §C7）。在 KLineView 上挂 5 个识别器，把原始手势归类为业务回调。
///
/// 仲裁规则（spec plan v1.5 §手势仲裁规则 L90-100）：
/// - 单指左右滑动 = 平移（累积判方向、增量出 offset；Drawing 模式被绘线截获不 fire onPan）
/// - 两指上下滑动 = 切周期；两指捏合 = 缩放（二者放行同时识别，由 classifyTwoFingerGesture 喂双实时值确定性仲裁）
/// - 长按 = 十字光标（与 Pan 共存）
/// - 单指点击 = 仅 Drawing 模式确定锚点
@MainActor
public final class ChartGestureArbiter: NSObject, UIGestureRecognizerDelegate {

    /// 单指水平平移：(incrementalDeltaX, velocityX, phase)。见 plan「下游契约」表。
    public var onPan: ((CGFloat, CGFloat, GesturePhase) -> Void)?
    /// 捏合缩放：(scale, focus, phase)。
    public var onPinch: ((CGFloat, CGPoint, GesturePhase) -> Void)?
    /// 长按：(location, phase)。
    public var onLongPress: ((CGPoint, GesturePhase) -> Void)?
    /// 单指点击：location。仅 Drawing 模式触发。
    public var onTap: ((CGPoint) -> Void)?
    /// 两指上下滑动切周期：松手离散触发一次。
    public var onTwoFingerSwipe: ((SwipeDirection) -> Void)?

    /// Drawing 模式开关。true 时单指 Pan 被绘线截获、单指点击 fire onTap。
    public var drawingMode: Bool = false

    // 弱引用：两指仲裁需跨识别器读对方实时值；view 持有识别器，weak 避免 arbiter↔recognizer 环。
    private weak var pinchRecognizer: UIPinchGestureRecognizer?
    private weak var twoFingerPanRecognizer: UIPanGestureRecognizer?
    private weak var singlePanRecognizer: UIPanGestureRecognizer?   // 两指起手时确定性取消单指（R10 finding-1）
    // 已挂载的目标视图（weak）；attach 幂等性判定用（R6 finding-2）。
    private weak var attachedView: UIView?

    // 单指平移 per-gesture 状态（生命周期决策在纯函数 singlePanStep，本类仅存状态）。
    private var lastSinglePanTranslationX: CGFloat = 0
    private var singlePanLifecycle: SinglePanLifecycle = .idle

    // 两指 per-gesture 状态（生命周期决策在纯函数 twoFingerStep）。
    private var twoFingerState = TwoFingerState()

    public override init() { super.init() }

    /// 在目标视图上创建并挂载 5 个识别器，全部以 self 为 delegate。
    /// **幂等（R6 finding-2）**：同 view 重复调用 no-op；换 view 时先卸载本 arbiter 装的旧识别器并复位状态，
    /// 防重复 attach 装两套识别器导致回调翻倍（pan delta / deceleration / tap / 切周期重复）。
    public func attach(to view: UIView) {
        if attachedView === view { return }                 // 同 view 幂等
        if let old = attachedView {                          // 换 view：卸载本 arbiter 的旧识别器
            for r in (old.gestureRecognizers ?? []) where r.delegate === self {
                old.removeGestureRecognizer(r)
            }
        }
        resetGestureState()

        let single = UIPanGestureRecognizer(target: self, action: #selector(handleSinglePan(_:)))
        single.maximumNumberOfTouches = 1
        single.delegate = self

        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.delegate = self

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self

        // 两指优先级（spec L95）：靠 maxTouches=1（单指）/ minTouches=2（两指）+ 委托对 pan+pan 返回 false（互斥）覆盖
        // **干净两指起手**——两指同时落 → 两指/pinch 识别器赢。
        // ⚠️ 不用 `single.require(toFail: twoFinger/pinch)`：那会让正常单指拖动一直卡 `.possible` 等两指失败，毁掉
        //   图表主交互单指滚动的响应性（R9 finding-2）。**交错起手（先 1 指微动再落第 2 指）的两指优先级**为
        //   device-tuning 残留（运行时 UX，真机/Catalyst 验收；静态无法两全于单指响应性，见 plan 设计约束 #4）。

        view.addGestureRecognizer(single)
        view.addGestureRecognizer(twoFinger)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(tap)

        pinchRecognizer = pinch
        twoFingerPanRecognizer = twoFinger
        singlePanRecognizer = single
        attachedView = view
    }

    /// 两指/pinch 起手时确定性接管：取消进行中的单指 pan（R10 finding-1；不用 require(toFail:) 故不伤单指响应）。
    /// **同步**关闭生命周期（R11 finding）：经纯函数 `singlePanSupersede` 直接发 `.cancelled` + 复位状态，
    /// **不依赖** `isEnabled` toggle 的回调投递；toggle 仅作防御性物理取消（其后续 .cancelled 命中 idle 被吞，不双发）。
    private func supersedeSinglePanForMultitouch(in view: UIView?) {
        // 读单指识别器当前累积，结算时补末段残量（R13 finding-2 不丢接管前位移）
        let cumulative = singlePanRecognizer?.translation(in: view) ?? .zero
        let step = singlePanSupersede(lifecycle: singlePanLifecycle, cumulative: cumulative,
                                      lastTranslationX: lastSinglePanTranslationX)
        singlePanLifecycle = step.lifecycle
        lastSinglePanTranslationX = step.lastTranslationX
        for e in step.emissions { onPan?(e.deltaX, e.velocityX, e.phase) }
        if let s = singlePanRecognizer, s.isEnabled { s.isEnabled = false; s.isEnabled = true }
    }

    /// 复位 per-gesture 状态（attach 切 view 时调，防跨 view/代次状态串）。
    private func resetGestureState() {
        lastSinglePanTranslationX = 0
        singlePanLifecycle = .idle
        twoFingerState = TwoFingerState()
    }

    // MARK: - State → GesturePhase（平凡映射；possible 无业务相位）

    private func phase(from state: UIGestureRecognizer.State) -> GesturePhase? {
        switch state {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        case .cancelled, .failed: return .cancelled
        case .possible: return nil
        @unknown default: return nil
        }
    }

    // MARK: - Handlers

    @objc private func handleSinglePan(_ g: UIPanGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        // 生命周期决策全在纯函数 singlePanStep：垂直/ambiguous → emission==nil 不触碰 reducer；
        // drawing 截获 → 始终 reset state 不发回调（R4 finding：防 mid-flight 切入残留）。
        let step = singlePanStep(phase: ph,
                                 cumulative: g.translation(in: g.view),
                                 velocityX: g.velocity(in: g.view).x,
                                 lifecycle: singlePanLifecycle,
                                 lastTranslationX: lastSinglePanTranslationX,
                                 drawingTakesOver: panPolicyInDrawingMode(drawingMode: drawingMode) == .drawingTakesOver)
        singlePanLifecycle = step.lifecycle
        lastSinglePanTranslationX = step.lastTranslationX
        for e in step.emissions { onPan?(e.deltaX, e.velocityX, e.phase) }
    }

    // 两指 pan 与 pinch 两识别器都喂入同一 twoFingerStep 状态机（顺序无关）；各读对方实时值。
    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        if ph == .began { supersedeSinglePanForMultitouch(in: g.view) }   // 第 2 指落 → 取消单指（R10 finding-1）
        let scale = pinchRecognizer?.scale ?? 1.0
        let focus = pinchRecognizer?.location(in: g.view) ?? g.location(in: g.view)
        emitTwoFinger(twoFingerStep(source: .pan, phase: ph, scale: scale, translation: g.translation(in: g.view),
                                    state: twoFingerState), focus: focus)
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        if ph == .began { supersedeSinglePanForMultitouch(in: g.view) }   // 捏合起手 → 取消单指（R10 finding-1）
        let translation = twoFingerPanRecognizer?.translation(in: g.view) ?? .zero
        emitTwoFinger(twoFingerStep(source: .pinch, phase: ph, scale: g.scale, translation: translation,
                                    state: twoFingerState), focus: g.location(in: g.view))
    }

    private func emitTwoFinger(_ result: TwoFingerStepResult, focus: CGPoint) {
        twoFingerState = result.state
        switch result.emission {
        case .pinch(let s, let p): onPinch?(s, focus, p)
        case .switchPeriod(let dir): onTwoFingerSwipe?(dir)
        case .none: break
        }
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        onLongPress?(g.location(in: g.view), ph)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard drawingMode, g.state == .ended else { return }   // 仅 Drawing 模式确定锚点
        onTap?(g.location(in: g.view))
    }

    // MARK: - UIGestureRecognizerDelegate

    /// 长按+Pan 共存（spec 仲裁表）；Pinch+两指Pan 共存（供 classifyTwoFingerGesture 同时拿 scale+translation 仲裁）。
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair = [gestureRecognizer, other]
        let hasLongPress = pair.contains { $0 is UILongPressGestureRecognizer }
        let hasPinch = pair.contains { $0 is UIPinchGestureRecognizer }
        let hasPan = pair.contains { $0 is UIPanGestureRecognizer }
        if hasLongPress && hasPan { return true }
        if hasPinch && hasPan { return true }
        return false
    }
}
#endif
```

- [ ] **Step 2: 本地 macOS 编译确认门控正确（编译为空，不破坏现有构建）**

Run: `swift build --package-path ios/Contracts`
Expected: `Build complete!`，无 error。

- [ ] **Step 3: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift
git commit -m "feat(C7): ChartGestureArbiter UIKit 绑定 + 两指 classifyTwoFinger 仲裁 + 增量/速度（spec §C7 L1397-1405）"
```

---

## Task 3: 验证闸门 + 验收清单

**Files:**
- Create: `docs/acceptance/2026-05-23-pr-c7-gesture-arbiter.md`

- [ ] **Step 1: 全量 swift test（macOS）**

Run: `swift test --package-path ios/Contracts`
Expected: `0 failures`；记录总 tests 数（C2 merge 后基线 + 本 PR 新增）。

- [ ] **Step 2: Catalyst build-for-testing（编译 arbiter UIKit 路径）**

Run（在 `ios/Contracts` 目录，命令与 C2 验收一致；scheme 以仓库现有为准）：
```bash
xcodebuild build-for-testing -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/c7-catalyst
```
Expected: `** TEST BUILD SUCCEEDED **`，无 `error:` / `warning:`。

- [ ] **Step 3: AppError 信任边界 grep 守卫**

Run: `grep -n "AppError" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift`
Expected: 0 匹配。

- [ ] **Step 4: 写验收清单文档**

写 `docs/acceptance/2026-05-23-pr-c7-gesture-arbiter.md`，表格列「# / 动作 / 预期 / 判定」，全中文、二元可决、禁用 forbidden_phrases。至少含：
  - 各 `--filter` 测试 + 全量 `swift test` → `0 failures`
  - `swift build` → `Build complete!`
  - Catalyst build-for-testing → `** TEST BUILD SUCCEEDED **`
  - grep AppError → 0 匹配
  - grep `#if canImport(UIKit)` 在 arbiter（UIKit 门控存在）
  - grep `singlePanStep` 在 handleSinglePan（生命周期纯函数接线存在 → 防 R1 finding 1 + R2 finding 回归）
  - grep `velocity(in:` 在 arbiter（释放速度路径存在 → 防 R1 finding 2 回归）
  - grep `twoFingerStep` 在 handlePinch 与 handleTwoFingerPan 各 1 处（两指生命周期状态机活接线 → 防 R1 finding 3 + R3 finding 回归）
  - grep `attachedView === view` 在 attach（幂等守卫存在 → 防 R6 finding-2 回归）
  - grep `verticalRejected` 在 GestureClassifiers（垂直 latch 态存在 → 防 R9 finding-1 回归）
  - grep `supersedeSinglePanForMultitouch` 在 handleTwoFingerPan 与 handlePinch（确定性两指接管接线 → 防 R10 finding-1 回归）
  - grep `singlePanSupersede` 在 supersedeSinglePanForMultitouch（同步关闭不依赖回调 → 防 R11 finding 回归）
  - SinglePanStepTests `supersedeActiveNoResidual` 通过（多指接管同步关闭恰一个终止，单测证 R11 finding）
  - SinglePanStepTests `zeroDeltaChangedSuppressed` 通过（零 delta 不空 bump revision，单测证 R13 finding-1）
  - grep `lastPinchScale` 在 GestureClassifiers（pinch scale 记忆存在 → 防 R10 finding-2 回归）
  - （真机/Catalyst 验收残留）同一 arbiter 对同一 view 连调 `attach` 两次 → 该 view `gestureRecognizers.count` 不增（幂等，R6 finding-2）
  - （真机/Catalyst 验收残留）正常单指拖动 → 拖动过程中即收到 `.began`/`.changed`（不卡到松手；R9 finding-2）
  - （真机/Catalyst 验收残留）交错两指起手（先 1 指微动再落第 2 指上下滑/捏合）→ 单指被取消、触发切周期/缩放（R10 finding-1 确定性接管）
  - PanIncrementTests `multiFrameNetMovement` 通过（净位移 == 增量和，单测证 R1 finding 1）
  - SinglePanStepTests `verticalNeverEmits` 通过（垂直手势零回调，单测证 R2 finding）
  - TwoFingerStepTests `pinchLockSuppressesSwipe` 通过（pinch 锁定不切周期，单测证 R3 finding）
  - SinglePanStepTests `drawingTakeoverCancelsActive` 通过（drawing 截获发 cancelled + reset，单测证 R4 + R5 finding-1）
  - TwoFingerStepTests `lateRecognizerNoLeak` 通过（双识别器顺序无关、滞后回调不泄漏切周期，单测证 R5 finding-2）

- [ ] **Step 5: 提交**

```bash
git add docs/acceptance/2026-05-23-pr-c7-gesture-arbiter.md
git commit -m "docs(C7): 验收清单（4 纯函数测试 + Catalyst 闸门 + R1 三 finding 回归 grep）"
```

---

## Self-Review（对照 spec + R1 findings）

**1. Spec coverage（modules §C7 L1351-1406）：** `GesturePhase`/`TwoFingerIntent`/`classifyTwoFingerGesture`(spec 意图，pinch 阈值 verify-and-correct 见约束 #4)/`SingleFingerPanIntent`/`classifySingleFingerPan`(逐字)/`DrawingModePanPolicy`/`panPolicyInDrawingMode`(逐字)/`ChartGestureArbiter`(5 回调+drawingMode+attach) 全覆盖；spec L2231 三纯函数测试目标 ✓ 穷举；plan v1.5 §仲裁规则 L90-100 全映射。

**2. codex findings 闭合：**
- R1 finding 1（累积当增量）→ `panIncrement` + `singlePanStep` 维护基线 + `multiFrameNetMovement` 单测。✓
- R1 finding 2（缺速度路径）→ onPan 第二参定义 velocityX、`.ended` surface `velocity(in:).x`、对齐 reducer `panEnded(velocity:)→startDeceleration`。✓
- R1 finding 3（仲裁虚设）→ pinch/两指pan 放行同时识别 + 喂双实时值经 `classifyTwoFingerGesture` 判定、`.pinch` 转活。✓（R3 进一步加生命周期锁定）
- R2 finding（垂直/ambiguous 仍 emit pan 生命周期）→ `singlePanStep` 显式水平态状态机：仅锁定水平后才产 emission，垂直/ambiguous 全程 nil；`verticalNeverEmits` / `ambiguousNeverEmits` 单测。✓
- R3 finding（两指跨回调重分类致冲突/丢终止）→ `twoFingerStep` 生命周期状态机：意图锁定 pinch 后不切周期、终止始终关闭 pinch 生命周期、顺序无关不双发；`pinchLockSuppressesSwipe` / `pinchTerminalAlwaysClosed` / `secondTerminalNoOp` 单测。✓
- R4 finding（drawing 中途截获留 stale 单指状态）→ `drawingTakesOver` 折入 `singlePanStep` reset；移除 handler 早返回。✓
- R5 finding-1（drawing 截获丢终止致 panStarted 悬空）→ 截获时若 active 先发 `.cancelled`(v 0) 再 reset；`drawingTakeoverCancelsActive` 单测。✓
- R5 finding-2（两指首终止即 reset 致滞后回调泄漏切周期）→ `twoFingerStep` 双 down-flag 模型：仅 `pinchDown`/`panDown` 皆 false 才结算 + `wasActive` 守卫孤立终止；`lateRecognizerNoLeak` / `strayTerminalNoOp` 单测。✓
- R6 finding-1（滞后终止丢锁定 pinch 的 cancel 误报成功）→ `pendingTerminal` 持久化终止 phase、`.cancelled` 压倒 `.ended`、cancelled 不切周期；`lockedPinchCancellationPreserved` / `cancelledSwipeSuppressed` 单测。✓
- R6 finding-2（attach 非幂等致回调翻倍）→ `attach(to:)` 同 view no-op、换 view 卸载旧识别器 + `resetGestureState`；Catalyst/真机验收"重复 attach 识别器数不增"+ grep `attachedView === view` 守卫。✓
- R7 finding-1（两指 swipe 顺序依赖丢失）→ `twoFingerStep` defer 时捕获 `pendingSwipe` 方向、结算用之；`swipeSurvivesPanEndedFirst` / `swipeSurvivesPinchEndedFirst` 双序单测。✓
- R7 finding-2（末段 pan 残量丢失）→ `singlePanStep` 终止有残量时先补 `.changed`(残量) 再终止（emissions 数组）；`horizontalActivationLifecycle`/`cancelledZeroVelocity`/`endedNoResidual` 单测。✓
- R8 finding-1（旁观 failed 识别器误取消 swipe）→ `twoFingerStep` 终止先查 `thisSourceWasDown`，从未参与的识别器终止完全忽略；`failedPinchDoesNotCancelSwipe` 单测。✓
- R8 finding-2（两指优先级未强制）→ 干净场景靠 maxTouches/minTouches + 委托互斥；**交错起手优先级记为 device 残留**（见约束 #5）。
- R9 finding-1（垂直意图未 latch 后翻成 pan）→ `singlePanStep` 三态 `idle/horizontalActive/verticalRejected`，垂直一旦判定即 latch；`verticalLatchedBlocksLaterHorizontal` 单测。✓
- R9 finding-2（`require(toFail:)` 卡死单指滚动）→ **回退 require(toFail:)** 保单指响应性。✓
- R10 finding-1（交错两指优先级不该留残留）→ 确定性 `supersedeSinglePanForMultitouch()`：两指/pinch `.began` 切 `single.isEnabled` 取消单指、路由交两指（不伤单指响应）；约束 #5。✓
- R10 finding-2（pinch 抬起后 pan 源发 stale-scale pinch.changed）→ `lastPinchScale` 记 pinch 源最后有效 scale；pinch down 才发 pan 源 pinch.changed、终止用 lastPinchScale；`lateRecognizerNoLeak`（lagChanged 抑制 + 终止 scale 1.06）单测。✓
- R11 finding（多指接管依赖回调投递不可靠）→ `singlePanSupersede` 纯函数**同步**关闭（恰一个 .cancelled + 复位），supersede 不再依赖 isEnabled 回调；`supersedeActiveEmitsOneCancelled`/`supersedeInactiveNoEmit` 单测。✓
- R12 finding（pinch 阈值 FP 边界 1.02 误判致测试失败）→ verify-and-correct 改对称显式边界 `scale > 1.02 || scale < 0.98`（保 spec 意图）；`scaleAtBoundaryNotPinch`/`scaleAtLowerBoundaryNotPinch` 等四边界单测。✓
- R13 finding-1（零 delta .changed 空 bump revision）→ `singlePanStep` horizontalActive 下 delta==0 不发 .changed；`zeroDeltaChangedSuppressed` 单测。✓
- R13 finding-2（取消/接管丢末段位移）→ drawing 截获 + `singlePanSupersede` 均先补末段残量 `.changed`(读当前累积) 再 `.cancelled`；`drawingTakeoverCancelsActive`(残量 40) / `supersedeActiveWithResidual`(残量 15) 单测。✓

**3. Placeholder 扫描：** 无 TBD/TODO；每 code step 含完整代码；分类函数逐字 spec。✓

**4. 类型一致性：** `SwipeDirection`(Models.swift 既有)；4 值类型 Task1 定义 / Task2 引用一致；回调签名对齐 spec L1398-1402；onPan 双参语义在「下游契约」表锁定。✓

**已知超 / 偏离 spec 字面（已声明，非 placeholder）：** onPan 双 CGFloat 具体化为 (incrementalDeltaX, velocityX)（spec 未标注，依 Reducer 契约推定）；两指切周期 `.ended` 离散触发；首水平帧 deadzone 不计入 offset；**`classifyTwoFingerGesture` pinch 阈值由 spec 字面 `abs(scale-1.0)>0.02` verify-and-correct 为 `scale>1.02||scale<0.98`**（保意图、消 FP 边界 wart，R12，约束 #4）。

---

## 流程位置

用户指定 Superpowers 6 段流程：1 writing-plans（本文件）→ 2 plan-stage codex（R1→…→R13 见上 findings；R13 零 delta 抑制 + 取消保残量→**本次 R14 修订**）→ 3 subagent-driven-development → 4 verification-before-completion → 5 requesting-code-review → 6 branch-diff codex。⚠️ 超 5 轮预算：2026-05-23 user 明示"继续修到 codex 批准"（每轮均真 bug/真 tradeoff，非边界挖掘）。
