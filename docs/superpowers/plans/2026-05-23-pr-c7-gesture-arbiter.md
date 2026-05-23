# C7 Gesture Arbiter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec §C7 手势系统模块——3 个纯分类函数 + 4 个值类型（macOS 全量单测）+ `ChartGestureArbiter`（UIKit 手势识别器绑定 + 仲裁委托，Catalyst 编译闸门 + 真机验收）。

**Architecture:** 决策逻辑全部沉淀在跨平台纯函数（spec L1363-1395 逐字），`ChartGestureArbiter` 只是 UIKit 适配薄层——读识别器原始值 → 调纯函数 → 触发回调。纯函数在 macOS `swift test` 全量覆盖；arbiter 用 `#if canImport(UIKit)` 包裹，macOS 编译为空、真实编译校验落在已 required 的 Catalyst CI 闸门，运行时手势行为是真机验收残留（C2 DecelerationAnimator 同款先例）。

**Tech Stack:** Swift 6.0 / swift-testing（`import Testing` + `@Suite`/`@Test`/`#expect`）/ CoreGraphics（CGPoint/CGFloat 跨平台）/ UIKit（仅 arbiter，`#if canImport(UIKit)`）。

**依赖：** C2 DecelerationAnimator（PR #60 已 merged）——本 PR 不直接引用 C2 类型，依赖关系是语义层面（arbiter.onPan 的消费者 C8/E5 会把 delta 经 reducer 喂给 DecelerationAnimator），本 PR scope 仅到回调出口。

---

## 设计约束与残留（codex review 重点审视项，前置声明）

1. **arbiter 无 macOS 单测，是平台固有约束而非设计缺陷。** `UIGestureRecognizerDelegate` / `UIPanGestureRecognizer` 等是 UIKit 独有，plain macOS SDK 无对等 API。故 arbiter 整类 `#if canImport(UIKit)`：
   - macOS `swift build` / `swift test`：该文件编译为空（`canImport(UIKit)` 为 false）。
   - Catalyst `xcodebuild -variant 'Mac Catalyst'`：编译该文件 → **真实编译校验**（已 required 的 `Mac Catalyst build-for-testing on macos-15`）。
   - 运行时手势触发（识别器是否正确 fire、仲裁是否生效）：**真机/Simulator 验收残留**（plan v1.5 §验收 L1177「iPad mini 7 测试：Pinch 缩放、十字光标、两指切周期、斜向消歧」）。
2. **所有"非平凡"决策逻辑都在被全量单测的纯函数里。** arbiter 内剩余未测逻辑仅为：(a) `attach(to:)` 识别器声明式配置、(b) `UIGestureRecognizer.State` → `GesturePhase` 平凡 switch、(c) 委托 `shouldRecognizeSimultaneouslyWith` 返回长按+Pan 共存。三者均为声明式/平凡，由 Catalyst 编译 + 真机验收覆盖。
3. **`classifyTwoFingerGesture` 的 scale 入参在 arbiter 中恒为 1.0。** arbiter 用独立 `UIPinchGestureRecognizer` 处理捏合（spec 仲裁表把 Pinch 与两指 Pan 列为两个独立识别器），故两指 Pan handler 调 `classifyTwoFingerGesture(translation:scale: 1.0)` 只取「切周期 vs 忽略」判定；`.pinch` 分支由独立 pinch 识别器走。函数本体仍逐字实现 spec 全签名并被单测穷举（含 `.pinch` 分支）——它是 spec 命名的测试目标（L2231），保留为两指意图的单一决策权威。
4. **边界语义严格对齐 spec 字面**（防 `feedback_codex_fractional_subpixel_bias` 无止境挖边界）：`abs(scale-1.0) > 0.02` 严格大于、`dy > dx * 1.2` 严格大于、`dx > dy * 1.5` / `dy > dx * 1.5` 严格大于、`dx < minThreshold && dy < minThreshold` 严格小于。边界相等值的归属由单测固定，codex 若就 `>` vs `>=` 反复挖且无 spec 依据则按 budget 规则 pushback。

---

## File Structure

- **Create** `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift`
  职责：4 个值类型（`GesturePhase` / `TwoFingerIntent` / `SingleFingerPanIntent` / `DrawingModePanPolicy`）+ 3 个纯分类函数。跨平台（仅 Foundation/CoreGraphics）。`SwipeDirection` 复用 `Models.swift` 既有定义。
- **Create** `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift`
  职责：`ChartGestureArbiter` UIKit 类——5 个回调闭包 + `drawingMode` + `attach(to:)` + 委托 + @objc handlers。整文件 `#if canImport(UIKit)`。
- **Create** `ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift`
  职责：3 个纯函数穷举单测 + 值类型 Equatable 断言。跨平台。
- **Create** `docs/acceptance/2026-05-23-pr-c7-gesture-arbiter.md`
  职责：非 coder 可执行验收清单（中文、action/expected/pass-fail、二元可决）。

---

## Task 0 — §15.3 评审策略前置

- [ ] **局部对抗性评审**（必）：本 plan C7 scope 内 `codex:adversarial-review`；plan-stage + branch-diff 各 4-5 轮内收敛或 escalate（per `feedback_codex_plan_budget_overshoot`）。
- [ ] 集成层评审（C8/E5 PR 必）：**本 PR 不涉及**（C7 仅到回调出口，不做桥接/编排）。
- [ ] 性能评审（Phase 5 PR 必）：**本 PR 不涉及**。

完成 Task 0 才进 Task 1。

---

## Task 1: 值类型 + 3 个纯分类函数（GestureClassifiers.swift）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift`

- [ ] **Step 1: 写失败测试（值类型 + 三函数穷举）**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("classifyTwoFingerGesture")
struct ClassifyTwoFingerGestureTests {

    // scale 偏离 1.0 超阈值 → pinch（优先于平移判定）
    @Test("scale 放大超阈值 → pinch")
    func scaleZoomIn() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: 100), scale: 1.5) == .pinch)
    }
    @Test("scale 缩小超阈值 → pinch")
    func scaleZoomOut() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 999, y: 999), scale: 0.5) == .pinch)
    }
    // 边界：abs(scale-1.0) == 0.02 不算 pinch（严格 >）
    @Test("scale 恰在阈值 0.02 不算 pinch")
    func scaleAtBoundaryNotPinch() {
        // translation 垂直 → 落入 switchPeriod 分支，证明未走 pinch
        let r = classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 1.02)
        #expect(r == .switchPeriod(.up))
    }
    @Test("scale 略超阈值 → pinch")
    func scaleJustOverBoundary() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 0, y: -100), scale: 1.0201) == .pinch)
    }
    // 垂直向上（y<0）→ switchPeriod(.up)
    @Test("两指上滑 → switchPeriod up")
    func swipeUp() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 10, y: -100), scale: 1.0) == .switchPeriod(.up))
    }
    // 垂直向下（y>0）→ switchPeriod(.down)
    @Test("两指下滑 → switchPeriod down")
    func swipeDown() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 10, y: 100), scale: 1.0) == .switchPeriod(.down))
    }
    // dy 不够垂直（dy 未超 dx*1.2）→ ignore
    @Test("水平为主 → ignore")
    func horizontalIgnore() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 100, y: 50), scale: 1.0) == .ignore)
    }
    // 边界：dy == dx*1.2 → ignore（严格 >）
    @Test("dy 恰为 dx*1.2 → ignore")
    func dyAtBoundaryIgnore() {
        #expect(classifyTwoFingerGesture(translation: CGPoint(x: 100, y: 120), scale: 1.0) == .ignore)
    }
}

@Suite("classifySingleFingerPan")
struct ClassifySingleFingerPanTests {

    // 两轴均低于 minThreshold → ambiguous
    @Test("微动低于阈值 → ambiguous")
    func belowThreshold() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 5, y: 5)) == .ambiguous)
    }
    // 明显水平（含阈值满足）→ horizontal，delta 保留 translation.x 原值与符号
    @Test("右滑 → horizontal 正 delta")
    func horizontalRight() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 100, y: 10)) == .horizontal(delta: 100))
    }
    @Test("左滑 → horizontal 负 delta")
    func horizontalLeft() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: -100, y: 10)) == .horizontal(delta: -100))
    }
    // 明显垂直 → vertical
    @Test("垂直为主 → vertical")
    func vertical() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 10, y: 100)) == .vertical)
    }
    // 斜向（都过阈值但谁都不到 1.5 倍）→ ambiguous
    @Test("斜向 45° → ambiguous")
    func diagonalAmbiguous() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 50, y: 50)) == .ambiguous)
    }
    // 阈值优先：方向明确但幅度都未过 minThreshold → ambiguous（阈值先判）
    @Test("纯水平但幅度不足 → ambiguous")
    func clearDirectionButTooSmall() {
        #expect(classifySingleFingerPan(translation: CGPoint(x: 5, y: 0)) == .ambiguous)
    }
    // 自定义 minThreshold 放大门槛
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

@Suite("Gesture value types Equatable")
struct GestureValueTypeTests {
    @Test("switchPeriod 方向区分")
    func swipeDirDistinct() { #expect(TwoFingerIntent.switchPeriod(.up) != .switchPeriod(.down)) }
    @Test("horizontal delta 区分")
    func horizontalDeltaDistinct() {
        #expect(SingleFingerPanIntent.horizontal(delta: 1) != .horizontal(delta: 2))
    }
    @Test("GesturePhase 四相不等")
    func phasesDistinct() {
        #expect(GesturePhase.began != .changed)
        #expect(GesturePhase.ended != .cancelled)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --package-path ios/Contracts --filter ClassifyTwoFingerGestureTests`
Expected: 编译失败 / `cannot find 'classifyTwoFingerGesture' in scope`（函数与类型尚未定义）。

- [ ] **Step 3: 写最小实现（逐字对齐 spec L1354-1395）**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift
// Kline Trainer Swift Contracts — C7 手势分类纯函数 + 值类型
// Spec: kline_trainer_modules_v1.4.md §C7（L1351-1406）+ kline_trainer_plan_v1.5.md §手势方案
// Plan: docs/superpowers/plans/2026-05-23-pr-c7-gesture-arbiter.md

import Foundation
import CoreGraphics

/// 手势生命周期相位（spec §C7）。映射自 UIGestureRecognizer.State，但本类型跨平台。
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
    case horizontal(delta: CGFloat)             // 触发平移
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --package-path ios/Contracts --filter ClassifyTwoFingerGestureTests` 然后 `--filter ClassifySingleFingerPanTests`、`--filter PanPolicyInDrawingModeTests`、`--filter GestureValueTypeTests`
Expected: 各 suite `0 failures`。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/GestureClassifiersTests.swift
git commit -m "feat(C7): 手势分类纯函数 + 值类型（spec §C7 L1354-1395 逐字）"
```

---

## Task 2: ChartGestureArbiter（UIKit 适配薄层）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift`

> 说明：本 Task 无 macOS 单测（平台固有约束，见「设计约束与残留」#1）。验证靠 Task 3 的 Catalyst 编译闸门。

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
/// - 单指左右滑动 = 平移（Drawing 模式下被绘线截获，不 fire onPan）
/// - 两指上下滑动 = 切周期（与 Pinch 经主方向/独立识别器互斥）
/// - 两指捏合 = 缩放
/// - 长按 = 十字光标（与 Pan 共存，`shouldRecognizeSimultaneouslyWith` 返回 true）
/// - 单指点击 = 仅 Drawing 模式确定锚点
@MainActor
public final class ChartGestureArbiter: NSObject, UIGestureRecognizerDelegate {

    /// 单指水平平移：(dx, dy, phase)。dx = 已分类的水平位移，dy 原样透传供消费者参考。
    public var onPan: ((CGFloat, CGFloat, GesturePhase) -> Void)?
    /// 捏合缩放：(scale, focus, phase)。focus = 捏合焦点（识别器坐标系）。
    public var onPinch: ((CGFloat, CGPoint, GesturePhase) -> Void)?
    /// 长按：(location, phase)。十字光标随长按移动，松手退出。
    public var onLongPress: ((CGPoint, GesturePhase) -> Void)?
    /// 单指点击：location。仅 Drawing 模式触发（确定绘线锚点）。
    public var onTap: ((CGPoint) -> Void)?
    /// 两指上下滑动切周期：松手时离散触发一次。
    public var onTwoFingerSwipe: ((SwipeDirection) -> Void)?

    /// Drawing 模式开关。true 时单指 Pan 被绘线截获（不 fire onPan），单指点击 fire onTap。
    public var drawingMode: Bool = false

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
    }

    // MARK: - State → GesturePhase 映射（平凡 switch；possible/failed 无业务相位）

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

    // MARK: - Handlers（薄适配：读原始值 → 纯函数 → 回调）

    @objc private func handleSinglePan(_ g: UIPanGestureRecognizer) {
        // Drawing 模式下 Pan 被绘线截获（spec 仲裁表）
        guard panPolicyInDrawingMode(drawingMode: drawingMode) == .normalPass else { return }
        guard let ph = phase(from: g.state) else { return }
        let t = g.translation(in: g.view)
        switch classifySingleFingerPan(translation: t) {
        case .horizontal(let delta):
            onPan?(delta, t.y, ph)
        case .vertical, .ambiguous:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        // 切周期为离散动作：松手时按最终位移判定一次（无需跨帧状态）
        guard g.state == .ended else { return }
        let t = g.translation(in: g.view)
        // scale 恒 1.0：捏合由独立 pinch 识别器处理（见 plan 设计约束 #3）
        if case .switchPeriod(let dir) = classifyTwoFingerGesture(translation: t, scale: 1.0) {
            onTwoFingerSwipe?(dir)
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        onPinch?(g.scale, g.location(in: g.view), ph)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard let ph = phase(from: g.state) else { return }
        onLongPress?(g.location(in: g.view), ph)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        // 仅 Drawing 模式确定锚点
        guard drawingMode, g.state == .ended else { return }
        onTap?(g.location(in: g.view))
    }

    // MARK: - UIGestureRecognizerDelegate

    /// 长按与 Pan 共存（spec 仲裁表「shouldRecognizeSimultaneouslyWith 返回 true」）；其余组合默认互斥。
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair = [gestureRecognizer, other]
        let hasLongPress = pair.contains { $0 is UILongPressGestureRecognizer }
        let hasPan = pair.contains { $0 is UIPanGestureRecognizer }
        return hasLongPress && hasPan
    }
}
#endif
```

- [ ] **Step 2: 本地 macOS 编译确认文件被正确门控（编译为空，不破坏现有构建）**

Run: `swift build --package-path ios/Contracts`
Expected: `Build complete!`，无 error（macOS 下 arbiter 编译为空段）。

- [ ] **Step 3: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift
git commit -m "feat(C7): ChartGestureArbiter UIKit 手势绑定 + 仲裁委托（spec §C7 L1397-1405）"
```

---

## Task 3: 验证闸门 + 验收清单

**Files:**
- Create: `docs/acceptance/2026-05-23-pr-c7-gesture-arbiter.md`

- [ ] **Step 1: 全量 swift test（macOS）**

Run: `swift test --package-path ios/Contracts`
Expected: `0 failures`；记录总 tests 数（应 = C2 merge 后基线 + 本 PR 新增纯函数测试数）。

- [ ] **Step 2: Catalyst build-for-testing（编译 arbiter UIKit 路径）**

Run:
```bash
xcodebuild build-for-testing \
  -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/c7-catalyst \
  -workspace /dev/null 2>/dev/null || \
xcodebuild build-for-testing -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/c7-catalyst
```
（实际命令与 C2 验收一致，在 `ios/Contracts` 目录运行；以仓库现有 scheme 为准。）
Expected: `** TEST BUILD SUCCEEDED **`，无 `error:` / `warning:`（arbiter UIKit 路径真实编译）。

- [ ] **Step 3: AppError 信任边界 grep 守卫**

Run: `grep -n "AppError" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift`
Expected: 0 匹配（C7 不跨错误信任边界）。

- [ ] **Step 4: 写验收清单文档**

写 `docs/acceptance/2026-05-23-pr-c7-gesture-arbiter.md`，表格列「# / 动作 / 预期 / 判定」，全中文、二元可决、禁用 `.claude/workflow-rules.json` forbidden_phrases（"验证通过即可"/"看起来正常"/"应该没问题"/"should work"/"looks fine"）。至少含：
  - 运行各 `--filter` 测试 → `0 failures`
  - 全量 `swift test` → `0 failures`
  - `swift build` → `Build complete!`
  - Catalyst build-for-testing → `** TEST BUILD SUCCEEDED **`
  - grep AppError → 0 匹配
  - grep 验证 arbiter 含 `#if canImport(UIKit)`（UIKit 门控存在）
  - grep 验证 `shouldRecognizeSimultaneouslyWith`（长按+Pan 共存委托存在）
  - grep 验证 `panPolicyInDrawingMode` 在 handleSinglePan 中被调用（Drawing 截获接线存在）

- [ ] **Step 5: 提交**

```bash
git add docs/acceptance/2026-05-23-pr-c7-gesture-arbiter.md
git commit -m "docs(C7): 验收清单（纯函数测试 + Catalyst 编译闸门 + grep 守卫）"
```

---

## Self-Review（写完即查，对照 spec）

**1. Spec coverage（modules §C7 L1351-1406）：**
- `GesturePhase` ✓ Task 1 / `TwoFingerIntent` ✓ / `classifyTwoFingerGesture` ✓ 逐字 / `SingleFingerPanIntent` ✓ / `classifySingleFingerPan` ✓ 逐字 / `DrawingModePanPolicy` ✓ / `panPolicyInDrawingMode` ✓ 逐字 / `ChartGestureArbiter`（5 回调 + drawingMode + attach）✓ Task 2。
- spec L2231 三纯函数测试目标 ✓ Task 1 穷举。
- spec plan v1.5 §仲裁规则（L90-100）：单指水平平移 ✓、两指上下切周期 ✓、Pinch ✓、长按+Pan 共存 ✓、Drawing 模式 Pan 截获 + Tap 锚点 ✓。

**2. Placeholder 扫描：** 无 TBD/TODO；每个 code step 含完整代码；纯函数逐字 spec。✓

**3. 类型一致性：** `SwipeDirection`（Models.swift 既有 .up/.down）；`GesturePhase`/`TwoFingerIntent`/`SingleFingerPanIntent`/`DrawingModePanPolicy` 在 Task 1 定义、Task 2 引用一致；回调签名与 spec L1398-1402 逐字（onPan: (CGFloat,CGFloat,GesturePhase)、onPinch: (CGFloat,CGPoint,GesturePhase)、onLongPress: (CGPoint,GesturePhase)、onTap: (CGPoint)、onTwoFingerSwipe: (SwipeDirection)）。✓

**已知超 spec 的实现选择（已在「设计约束与残留」声明，非 placeholder）：** 两指切周期改 `.ended` 离散触发（spec 未规定触发时机，离散更合理且无状态）；arbiter 用独立 pinch 识别器故 `classifyTwoFingerGesture` scale 入参恒 1.0。

---

## 流程位置

本 plan 是用户指定 Superpowers 6 段流程的 step 1 产出。后续：
2. plan-stage `codex:adversarial-review`（本文件 scope）到收敛/escalate
3. `superpowers:subagent-driven-development`（Sonnet 4.6 high effort 子 agent / 每 Task fresh）
4. `superpowers:verification-before-completion`（上述 Task 3 闸门真跑留证）
5. `superpowers:requesting-code-review`
6. branch-diff `codex:adversarial-review` 到收敛/escalate
