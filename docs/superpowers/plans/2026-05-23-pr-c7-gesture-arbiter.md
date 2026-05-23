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
| phase | incrementalDeltaX | velocityX | 消费者（C8/E5）派发 |
|---|---|---|---|
| `.began` | 0 | ~0 | `.panStarted` |
| `.changed` | 帧间水平增量 | 实时水平速度 | `.offsetApplied(deltaPixels: incrementalDeltaX)` |
| `.ended` | 末帧残量（消费者可忽略） | 释放水平速度 | `.panEnded(velocity: velocityX)` |
| `.cancelled` | 末帧残量 | 0 | `.panEnded(velocity: 0)` |

---

## 设计约束与残留（codex review 重点审视项，前置声明）

1. **arbiter 无 macOS 单测，是平台固有约束。** `UIGestureRecognizerDelegate` / `UIPanGestureRecognizer` 等 UIKit 独有，plain macOS SDK 无对等 API。arbiter 整类 `#if canImport(UIKit)`：macOS `swift build` 编译为空；Catalyst `xcodebuild` 真实编译（required `Mac Catalyst build-for-testing on macos-15`）；运行时手势触发 = 真机验收残留（plan v1.5 §验收 L1177）。所有**非平凡决策逻辑都在被全量单测的纯函数里**（4 分类/换算函数）；arbiter 内未测部分仅为 UIKit 管道：识别器声明式配置、`State→GesturePhase` 平凡 switch、跨识别器 scale/translation 读取、per-gesture 增量状态、委托共存策略。
2. **两指仲裁由 `classifyTwoFingerGesture` 真实承担（修正 R1 finding 3）。** pinch 与两指 pan 是两个独立识别器、**放行同时识别**；两个 handler 都调 `classifyTwoFingerGesture(translation:, scale:)` 并喂**两个识别器的实时值**（pinch handler 读两指pan.translation，两指pan handler 读 pinch.scale）。函数内 `abs(scale-1.0)>0.02` 优先判 pinch、否则垂直判切周期——成为确定性单一仲裁权威，`.pinch` 分支在生产**转活**。arbiter 持两识别器 **weak** 引用（view 持有它们，避免 arbiter↔recognizer 环）。
3. **单指平移：方向判定用累积位移，offset 发帧间增量。** `classifySingleFingerPan` 吃累积 translation 锁定主方向（需累积才能过 minThreshold/1.5 倍比）；锁定为 `.horizontal` 后用纯函数 `panIncrement(current:last:)` 算帧间增量出回调。per-gesture `lastTranslationX` 在 `.began` 归零（UIKit handler 内状态，device-tested）。已知微行为：首个水平帧的增量含 ~8pt deadzone 起跳量（亚像素级，不修，防 `feedback_codex_fractional_subpixel_bias` 挖边界）。
4. **边界语义严格对齐 spec 字面**：`abs(scale-1.0) > 0.02`、`dy > dx*1.2`、`dx > dy*1.5` / `dy > dx*1.5`、`dx < minThreshold && dy < minThreshold` 全严格不等；边界相等值归属由单测固定。codex 若就 `>` vs `>=` 无 spec 依据反复挖，按 `feedback_codex_plan_budget_overshoot` pushback。

---

## File Structure

- **Create** `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift`
  4 值类型（`GesturePhase`/`TwoFingerIntent`/`SingleFingerPanIntent`/`DrawingModePanPolicy`）+ 3 分类纯函数（spec 逐字）+ `panIncrement` 增量纯函数。跨平台。`SwipeDirection` 复用 `Models.swift`。
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
    @Test("scale 恰在阈值 0.02 不算 pinch（严格 >）")
    func scaleAtBoundaryNotPinch() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 1.02) == .switchPeriod(.up))
    }
    @Test("scale 略超阈值 → pinch")
    func scaleJustOverBoundary() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 1.0201) == .pinch)
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

/// 两指意图分类（spec L1363-1368 逐字）。scale 偏离 1.0 超阈值优先判 pinch；
/// 否则垂直分量显著（dy > dx*1.2）判切周期方向；其余忽略。
public func classifyTwoFingerGesture(translation: CGPoint, scale: CGFloat) -> TwoFingerIntent {
    if abs(scale - 1.0) > 0.02 { return .pinch }
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --package-path ios/Contracts --filter ClassifyTwoFingerGestureTests` 然后依次 `--filter ClassifySingleFingerPanTests`、`--filter PanPolicyInDrawingModeTests`、`--filter PanIncrementTests`、`--filter GestureValueTypeTests`
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

    // 单指平移 per-gesture 增量状态（.began 归零）。
    private var lastSinglePanTranslationX: CGFloat = 0

    public override init() { super.init() }

    /// 在目标视图上创建并挂载 5 个识别器，全部以 self 为 delegate。
    public func attach(to view: UIView) {
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

        view.addGestureRecognizer(single)
        view.addGestureRecognizer(twoFinger)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(tap)

        pinchRecognizer = pinch
        twoFingerPanRecognizer = twoFinger
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
        // Drawing 模式下 Pan 被绘线截获（spec 仲裁表）
        guard panPolicyInDrawingMode(drawingMode: drawingMode) == .normalPass else { return }
        guard let ph = phase(from: g.state) else { return }
        let cumulative = g.translation(in: g.view)
        let velocityX = g.velocity(in: g.view).x
        switch ph {
        case .began:
            lastSinglePanTranslationX = 0
            onPan?(0, velocityX, .began)
        case .changed:
            // 方向判定用累积位移；仅水平才发增量 offset
            if case .horizontal = classifySingleFingerPan(translation: cumulative) {
                let delta = panIncrement(current: cumulative.x, last: lastSinglePanTranslationX)
                lastSinglePanTranslationX = cumulative.x
                onPan?(delta, velocityX, .changed)
            }
        case .ended, .cancelled:
            let delta = panIncrement(current: cumulative.x, last: lastSinglePanTranslationX)
            lastSinglePanTranslationX = cumulative.x
            onPan?(delta, ph == .ended ? velocityX : 0, ph)
        }
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        // 切周期离散：松手判定一次；scale 取实时 pinch 识别器值参与仲裁
        guard g.state == .ended else { return }
        let t = g.translation(in: g.view)
        let scale = pinchRecognizer?.scale ?? 1.0
        if case .switchPeriod(let dir) = classifyTwoFingerGesture(translation: t, scale: scale) {
            onTwoFingerSwipe?(dir)
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        // 喂两指pan 实时 translation + 本识别器 scale；仅 scale 主导（classifier == .pinch）才发缩放
        let translation = twoFingerPanRecognizer?.translation(in: g.view) ?? .zero
        if classifyTwoFingerGesture(translation: translation, scale: g.scale) == .pinch {
            onPinch?(g.scale, g.location(in: g.view), ph)
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
  - grep `panIncrement` 在 handleSinglePan（增量换算接线存在 → 防 R1 finding 1 回归）
  - grep `velocity(in:` 在 arbiter（释放速度路径存在 → 防 R1 finding 2 回归）
  - grep `classifyTwoFingerGesture` 在 handlePinch 与 handleTwoFingerPan 各 1 处（两指仲裁活接线 → 防 R1 finding 3 回归）
  - PanIncrementTests `multiFrameNetMovement` 通过（净位移 == 增量和，单测层证 finding 1 修复）

- [ ] **Step 5: 提交**

```bash
git add docs/acceptance/2026-05-23-pr-c7-gesture-arbiter.md
git commit -m "docs(C7): 验收清单（4 纯函数测试 + Catalyst 闸门 + R1 三 finding 回归 grep）"
```

---

## Self-Review（对照 spec + R1 findings）

**1. Spec coverage（modules §C7 L1351-1406）：** `GesturePhase`/`TwoFingerIntent`/`classifyTwoFingerGesture`(逐字)/`SingleFingerPanIntent`/`classifySingleFingerPan`(逐字)/`DrawingModePanPolicy`/`panPolicyInDrawingMode`(逐字)/`ChartGestureArbiter`(5 回调+drawingMode+attach) 全覆盖；spec L2231 三纯函数测试目标 ✓ 穷举；plan v1.5 §仲裁规则 L90-100 全映射。

**2. R1 findings 闭合：**
- finding 1（累积当增量）→ `panIncrement` 纯函数 + 单指 handler 跟踪 lastTranslationX + `multiFrameNetMovement` 单测。✓
- finding 2（缺速度路径）→ onPan 第二参定义 velocityX、`.ended` surface `velocity(in:).x`、对齐 reducer `panEnded(velocity:)→startDeceleration`。✓
- finding 3（仲裁虚设）→ pinch/两指pan 放行同时识别 + 两 handler 喂双实时值经 `classifyTwoFingerGesture` 确定性仲裁、`.pinch` 转活。✓

**3. Placeholder 扫描：** 无 TBD/TODO；每 code step 含完整代码；分类函数逐字 spec。✓

**4. 类型一致性：** `SwipeDirection`(Models.swift 既有)；4 值类型 Task1 定义 / Task2 引用一致；回调签名对齐 spec L1398-1402；onPan 双参语义在「下游契约」表锁定。✓

**已知超 spec 实现选择（已声明，非 placeholder）：** onPan 双 CGFloat 具体化为 (incrementalDeltaX, velocityX)（spec 未标注，依 Reducer 契约推定）；两指切周期 `.ended` 离散触发；首水平帧增量含 deadzone 起跳量（亚像素，不修）。

---

## 流程位置

用户指定 Superpowers 6 段流程：1 writing-plans（本文件）→ 2 plan-stage codex（**R1 needs-attention 3 findings → 本次 R2 修订**）→ 3 subagent-driven-development → 4 verification-before-completion → 5 requesting-code-review → 6 branch-diff codex。
