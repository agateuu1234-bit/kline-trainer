# C2 DecelerationAnimator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 modules §C2 的 `DecelerationAnimator` —— K 线图惯性滚动减速器：基于 deltaTime 的帧率无关指数衰减，每帧把 delta offset 经回调派发给消费者（消费者再封装为 `.offsetApplied`）。

**Architecture:** 纯逻辑 / 驱动 分离 + 驱动可注入——(1) 纯值类型 `DecelerationModel`（确定性衰减计算 + 数值校验）；(2) `@MainActor public final class DecelerationAnimator`（持 model + 经注入工厂创建帧驱动 + 回调 + `currentGeneration` run identity；`handleTick(dt:generation:)` 作测试缝）；(3) internal `FrameDriving` 协议 + `RealFrameDriver`（每平台 CADisplayLink / Timer 薄 adapter）。驱动可注入 → 用 fake 在 `swift test` 里**确定性**覆盖调度 / 失活 / 清理 / 代次（无需在 Catalyst 跑测试）。复用代码库"纯核心 + 薄壳"模式。

**Tech Stack:** Swift 6（swift-tools 6.0，strict-concurrency complete）；Swift Testing（`@Suite` / `@Test` / `#expect`，1 个 macOS 真驱动 smoke 用 `RunLoop.main.run(until:)` spin）；`import Foundation` + `CoreGraphics` + `QuartzCore`（CADisplayLink / `CACurrentMediaTime`）；驱动 iOS+Catalyst 用 CADisplayLink、plain macOS 用 Timer（详见 DD-7）；SwiftPM intra-package（`KlineTrainerContracts`）；CI 守护 = `.github/workflows/catalyst-build.yml`（Mac Catalyst build-for-testing on macos-15，required check）。

> **Plan-stage codex 收敛记录**
> - **R1**（3 findings 全接受）：F1 `target:self` 泄漏 → weak 自失活；F2 friction/threshold 未校验致 NaN/永不停 → 数值校验（DD-8）；F3 plain macOS 永不自驱 → macOS 真 Timer 驱动（DD-7）。
> - **R2**（3 findings 全接受/1 纠偏）：F1 旧帧回调改写 restart 后 animator → generation token（DD-3）；F2 本地 gate 没编 UIKit 分支 → 加本地 Catalyst build-for-testing；codex 称"Catalyst CI 不存在"系**误判**（`catalyst-build.yml` 确在每 PR 跑）；F3 测试缺 `import Testing` → 补。
> - **R3**（2 findings 全接受）：F1 UIKit 驱动只编译不运行 → **注入式 frame-driver**（FrameDriving + 可注入工厂 + fake），driver 调度/失活/清理在 `swift test` 确定性覆盖（codex 原话 "covered deterministically"）；**已验证 `xcodebuild test` 在 Catalyst 不可行**（"Scheme … not configured for the test action"），故不靠 Catalyst 跑测试。F2 验收 grep `\.offset` 误伤 `.offsetApplied` → 改为只查 `PanelViewState`。
> - **R4**（2 findings medium）：F1 验收 grep 仍误伤——`PanelViewState` 字面在 onUpdate 注释里 → **去掉注释字面**（grep 干净且仍证不变量）；F2 生产 CADisplayLink 无运行时 gate（第 4 次提）→ 实测 **iOS Simulator 与 Catalyst 两 destination 的 `xcodebuild test` 均不可行**（scheme 不支持 test action），属基础设施受限残留，已穷尽缓解并显式记入「Accepted residual」。
> - 每轮改后版本经 `swiftc -typecheck -swift-version 6 -strict-concurrency=complete` 在 macOS + iOS-sim SDK 两路径 exit 0。

---

## Spec snapshot（grep-verified）

**权威 baseline = modules §C2**（`kline_trainer_modules_v1.4.md` L1257-1275，per memory `project_modules_v1.4_frozen`）：

```swift
final class DecelerationAnimator {
    var onUpdate: ((CGFloat) -> Void)?      // 消费者必须封装为 .offsetApplied(deltaPixels:) 派发；禁止直接写 PanelViewState.offset
    var onFinish: (() -> Void)?
    init(friction: CGFloat = 0.94, stopThreshold: CGFloat = 0.5)
    func start(initialVelocity: CGFloat)
    func stop()
    func resetOnSceneActive()               // 由 E5.onSceneActivated() 调用
}
```

**body 实现指引 = plan §3**（`kline_trainer_plan_v1.5.md` L43-88）—— 给出物理细节：

- `friction = 0.94`；`refInterval = 1.0 / 120.0`；`stopThreshold = 0.5`（pt/s）
- 每帧 tick：`dt = targetTimestamp - timestamp`
- `guard dt > 0 && dt < 1.0 else { stop() }` —— 后台恢复 dt 爆炸直接停（L63-67）
- `velocity *= pow(friction, dt / refInterval)` —— 帧率无关指数衰减（L68）
- `if abs(velocity) < stopThreshold { stop() }`（L69-72）
- `onUpdate?(velocity * dt)` —— 派发**衰减后**速度 × dt（L73）
- `sceneDidBecomeActive` reset 防后台一帧跳出屏幕（L87）

### 两份 spec 的差异（modules 优先）

| # | Aspect | modules §C2（权威） | plan §3 | 取舍 |
|---|---|---|---|---|
| D-1 | 类型签名 | `final class` + `onFinish` + `init(friction:stopThreshold:)` + `resetOnSceneActive()` | 裸 `class`，无 onFinish / 无 init 参数 / 无 reset | 取 modules（v1.3 较新，是冻结契约层） |
| D-2 | 物理细节 | 仅声明，无 body | 完整 tick body（friction/refInterval/threshold/decay 公式） | 取 plan body（modules 不提供 body） |
| D-3 | `refInterval` 是否进 init | init 仅 friction + stopThreshold | 硬编码 `1/120` | refInterval 作内部常量（默认 1/120），不进 public init —— 严格匹配 modules init 签名 |

### Spec 未定义、本 plan 决议的语义

- **DD-1 分层 + 驱动可注入**：production 三件——`DecelerationModel`（纯值类型衰减）、`DecelerationAnimator`（@MainActor，持 model + 经工厂建帧驱动 + 回调 + 代次）、`RealFrameDriver`（@MainActor，平台 CADisplayLink/Timer adapter）；加 internal `FrameDriving` 协议（测试缝）+ 测试侧 `FakeFrameDriver`。理由：帧驱动由 run loop 实时驱动、无法同步确定性触发；把驱动抽成可注入协议，用 fake 即可在 `swift test`（CI 跑）里确定性覆盖 start 调度 / stop·finish·restart 失活 / 代次 / weak 清理（修 R3-F1）。`DecelerationModel` / `FrameDriving` / `RealFrameDriver` 均 internal，**不扩张 §C2 public 契约**。
- **DD-2 `onFinish` 语义**：**仅减速自然终止**（速度衰减到 < stopThreshold）**或 dt-guard 异常停**（后台恢复）时触发**一次**；外部主动 `stop()` / `resetOnSceneActive()` **静默不触发**。理由：reducer 在 drawing 激活时调 `stop()` 防 stale 漂移（modules L1027 / Reducer.swift:112）；若 stop() 触发 onFinish → 可能再触发 onUpdate 链，正是要防的漂移。
- **DD-3 防泄漏 + 防 stale 回调（修 R1-F1 + R2-F1）**：
  - **防泄漏（无 deinit / 无 proxy）**：`RealFrameDriver` 是平台帧驱动 target（`runloop → link/timer → RealFrameDriver`）；animator 注入的 `onTick` 闭包以 `[weak self]` 持 animator。owner 释放 animator 后，下一帧 `onTick` 见 `self == nil` **返回 false**，`RealFrameDriver` 据此**自失活**并被释放——无需 animator deinit（规避 Swift 6 nonisolated deinit 访问 non-Sendable 隔离属性陷阱）、无需独立 proxy 类。`stop()` / 自然终止经 `driver?.invalidate()` 立即失活。
  - **防 stale 回调（generation token）**：仅 `isDecelerating` 不足区分 run 代次——`stop()`+`start()` 复用同实例后，旧驱动 in-flight 回调若到达会推进**新 model**派发 stale `.offsetApplied`（本模块要防的漂移）。解法：`currentGeneration` 每 `start()` 自增；`onTick` 闭包捕获该代次，闭包与 `handleTick(dt:generation:)` 都 `guard generation == currentGeneration`，stale 代次→闭包返回 false→旧驱动自失活、`handleTick` no-op。
- **DD-4 并发**：`DecelerationAnimator` / `RealFrameDriver` / `FakeFrameDriver` / `FrameDriving` 均 `@MainActor`（帧驱动在 main run loop；消费者是 UI）。`onUpdate`/`onFinish` 是 main-actor 隔离存储属性，**无需** `@Sendable`。`DecelerationModel` 是 `Sendable` 纯值类型。
- **DD-5 测试缝**：(a) `handleTick(dt:generation:)` internal——确定性测模型/回调/代次逻辑；(b) 第二个 internal `init(... makeDriver:)`——注入 `FakeFrameDriver`，确定性测驱动调度/失活/weak 清理（`fake.fire(dt:)` 驱动**真实生产 onTick 闭包**）；(c) `isDecelerating` / `currentGeneration` internal `private(set)`。三者经 `@testable import` 可见，**不进 public 面**。另 1 个 macOS 真 Timer smoke（runloop-spin）证明真实 adapter 确实 fire。
- **DD-6 文件位置**：`ChartEngine/` 目录（feature-named，平铺于 `Sources/KlineTrainerContracts/` 下）。spec 文件树写 `ChartEngine/Core/`，但代码库已不照抄（ChartViewport/CoordinateMapper 在 `Geometry/`）；沿用"feature 目录直挂 Sources"惯例，为 顺位 4 C7 留空间。`FrameDriving` / `RealFrameDriver` 与 animator 同文件（仅服务它）。
- **DD-7 每平台真实驱动 + 验证 gate（修 R1-F3 + R2-F2 + R3-F1；已 typecheck / 已验证 Catalyst 测试不可行）**：
  - **驱动**：`RealFrameDriver` 内 `#if canImport(UIKit)` 用 `CADisplayLink`（dt = targetTimestamp - timestamp）；`#else`（plain macOS）用 `Timer`（120Hz，target/selector 避 `@Sendable` 闭包问题，dt = `CACurrentMediaTime()` 帧间差）。两平台都是真驱动。
  - **UIKit 分支编译 gate**（本地 + CI）：`.github/workflows/catalyst-build.yml` L41-53 每 PR 跑 `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`（required check「Mac Catalyst build-for-testing on macos-15」），编译 `#if canImport(UIKit)` CADisplayLink adapter；Task 3 + 验收同命令在本地复跑。
  - **为何不在 iOS/Catalyst 跑测试**（两 destination 均已验证不可行）：`xcodebuild test -scheme KlineTrainerContracts -destination '…Mac Catalyst'` **和** `-destination 'platform=iOS Simulator,name=iPhone 17'` 都报 `Scheme KlineTrainerContracts is not currently configured for the test action`——SwiftPM 自动生成 scheme 不含 Test action（与 destination 无关）。本仓 `swift test`（macOS host，SwiftPM 原生）能跑、`xcodebuild test`（任何苹果设备 destination）跑不了，这是 PR #51/#54 既定测试规范的根因。故 CADisplayLink **运行时**无法在本仓 CI/本地 toolchain 执行——其调度/失活/清理逻辑由**注入 fake** 在 `swift test` 确定性覆盖（fake 驱动的是**真实生产 onTick 闭包**；CADisplayLink adapter 仅 ~3 行 link 创建 + dt 公式，编译守护 + 与 Timer adapter 结构同形，Timer 由 macOS smoke 运行时验证）。详见「Accepted residual」。
  - **验证证据**：修复版草稿在 `swiftc -typecheck -swift-version 6 -strict-concurrency=complete` 下 macOS + iOS-sim 两路径 exit 0。
- **DD-8 数值校验（修 R1-F2）**：
  - `DecelerationModel.init`：`friction` 非有限或 ∉ (0,1) → 回退 `0.94`；`stopThreshold` 非有限或 ≤0 → 回退 `0.5`；`refInterval` 非有限或 ≤0 → 回退 `1/120`。
  - `advance(dt:)`：衰减后 `guard velocity.isFinite else { velocity = 0; return .stop }`。
  - `start(initialVelocity:)`：`guard initialVelocity.isFinite else { return }`。

### 信任边界 / gate 适配

- **M0.4 AppError gate N/A**：C2 不消费 `AppError`、不 throw、不持有任何错误类型 → 不跨错误信任边界，`project_m04_translation_gate` Gate 1/2 不适用。
- **§15.1 闸门**：spec L1178-1180「Deceleration stop 契约测试」中——Wave 0 reducer 契约测试已于 PR #50 落地；**production handler 集成测试归 Wave 2**；本 PR 仅交付类本体 + unit test。无额外 §15.1 ledger 条目需在本 PR 关闭。

---

## Accepted residual（R4-F2：生产 CADisplayLink adapter 无运行时执行 gate）

**残留**：iOS/Catalyst 的 `CADisplayLink` adapter（`RealFrameDriver` 的 `#if canImport(UIKit)` 分支：target/selector 投递、main run loop 注册、`onTick==false` 自失活）在本仓**只被编译、不被运行时执行**。

**为何不可在本 PR scope 内闭合（已穷尽验证）**：codex R4-F2 建议"加 iOS Simulator 或 Catalyst host 运行时 smoke"。实测两 destination 均报 `Scheme KlineTrainerContracts is not currently configured for the test action`——本仓 SwiftPM 自动 scheme 不支持 `xcodebuild test`（与 destination 无关）。要运行需提交自定义 `.xcscheme` 启用 Test action = 测试基础设施改动，属治理/tooling scope，违反 `feedback_governance_budget_cap`（业务 PR 不做预防性基础设施），且与 PR #51 KLineView UIKit 壳 / PR #54 freeze 既定"UIKit 分支 = Catalyst 编译 + 纯逻辑单测"规范一致。

**已穷尽的等效缓解**：
1. 纯物理 14 测（确定性，CI `swift test`）。
2. 驱动生命周期（start 调度 / stop·finish·restart 失活 / 代次 / weak 清理）经**注入 fake** 确定性覆盖——fake 驱动的是 animator 创建的**真实生产 onTick 闭包**（含 weak-self、代次 guard、`return isDecelerating` 自失活信号），CI `swift test` 跑。
3. 真实 driver firing 由 macOS `Timer` adapter 运行时 smoke（runloop-spin）验证。
4. `CADisplayLink` adapter 与 `Timer` adapter **结构同形**（同 `onTick→Bool` 自失活契约），差异仅 ~3 行（link 创建 + `targetTimestamp-timestamp` dt），由 Catalyst build-for-testing 编译守护。

**未覆盖的精确剩余**：仅"CADisplayLink 这个平台对象在真机/模拟器上确实按帧回调"——属 Apple 框架行为，将在 **Wave 2 C8 ChartContainerView 集成 + 真机/模拟器手测**时端到端覆盖（与 §15.1 production handler 集成测试同窗口）。

> 若 codex 在 branch-diff 阶段再次将此残留判为 blocker，按 `feedback_codex_plan_budget_overshoot` / `feedback_codex_round6_self_contradiction` 走 user TTY override + attestation residual（记 `.claude/state/codex-attest-overrides.jsonl` + `docs/acceptance/<PR>.md`），不绕过 required checks。

---

## File Structure

| 文件 | 责任 |
|---|---|
| Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift` | 纯减速物理 + 数值校验（internal struct）：`advance(dt:) -> Outcome`。无 UIKit / 无 run loop。 |
| Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift` | `@MainActor public final class` + internal `FrameDriving` 协议 + `RealFrameDriver`：持 model + 注入工厂建驱动 + generation + §C2 public API + 测试缝 `handleTick(dt:generation:)` / 注入 init / `isDecelerating` / `currentGeneration`。 |
| Create: `ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationModelTests.swift` | 纯物理 + 数值校验测试（14）。 |
| Create: `ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationAnimatorTests.swift` | 接线测试（@MainActor，`.serialized`）+ 内置 `FakeFrameDriver`：handleTick 逻辑 + 代次 + initialVelocity guard + fake 驱动生命周期/清理 + 1 macOS 真 Timer smoke（13）。 |
| Create: `docs/acceptance/2026-05-22-pr-c2-deceleration-animator.md` | 非 coder 验收清单（中文，action/expected/pass-fail，二元可判）。 |

子项映射（per `feedback_planner_packaging_bias` ≤3 子项 / ≤500 行 prod；本 PR 约 175 行 prod）：① DecelerationModel ② DecelerationAnimator + FrameDriving + RealFrameDriver ③ acceptance + 验证。

---

## Task 0 — §15.3 评审策略前置

（per `docs/governance/wave1-plan-template.md`；section-name 锚定）

- [ ] **局部对抗性评审**（必）：本 plan 子模块 scope 内 `codex:adversarial-review`，plan-stage + branch-diff 各自 4-5 轮内收敛或 escalate（per `feedback_codex_plan_budget_overshoot`）。
- [ ] **集成层评审**：N/A（C8 桥接 + E5 编排在 Wave 2）。
- [ ] **性能评审**：N/A（Phase 5 磨光 PR 才需）。

完成 Task 0 才进 Task 1 实施。

---

## Task 1 — DecelerationModel（纯减速物理 + 数值校验）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationModelTests.swift`

- [ ] **Step 1: 写失败测试**（创建 `DecelerationModelTests.swift`）

```swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("DecelerationModel")
struct DecelerationModelTests {

    private let f: CGFloat = 0.94
    private let ref: CGFloat = 1.0 / 120.0
    private let thr: CGFloat = 0.5

    // 1. dt == refInterval 时速度恰好 *= friction，且 move delta == 衰减后速度 * dt
    @Test("dt equals refInterval decays velocity by exactly friction")
    func decayAtRefInterval() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        let outcome = m.advance(dt: ref)
        #expect(abs(m.velocity - 940) < 1e-6)          // 1000 * 0.94
        guard case .move(let delta) = outcome else { Issue.record("expected .move"); return }
        #expect(abs(delta - 940 * ref) < 1e-9)
    }

    // 2. 正速度下每步幅度严格递减
    @Test("velocity magnitude strictly decreases each step")
    func monotonicDecay() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 2000)
        var prev = m.velocity
        for _ in 0..<3 {
            _ = m.advance(dt: ref)
            #expect(m.velocity < prev)
            prev = m.velocity
        }
    }

    // 3. 负速度：符号保持，delta 为负
    @Test("negative velocity preserves sign in delta")
    func signPreserved() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: -1000)
        let outcome = m.advance(dt: ref)
        #expect(m.velocity < 0)
        guard case .move(let delta) = outcome else { Issue.record("expected .move"); return }
        #expect(delta < 0)
    }

    // 4. 衰减到 < 阈值 → .stop，velocity 归零
    @Test("velocity below threshold after decay stops and zeroes")
    func belowThresholdStops() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 0.52)
        let outcome = m.advance(dt: ref)   // 0.52 * 0.94 = 0.4888 < 0.5
        #expect(outcome == .stop)
        #expect(m.velocity == 0)
    }

    // 5. 衰减后仍 >= 阈值 → .move（test 4 边界互补）
    @Test("velocity just above threshold after decay keeps moving")
    func justAboveThresholdMoves() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 0.6)
        let outcome = m.advance(dt: ref)   // 0.6 * 0.94 = 0.564 >= 0.5
        guard case .move = outcome else { Issue.record("expected .move"); return }
        #expect(m.velocity > thr)
    }

    // 6. dt == 0 → .stop，归零，不衰减
    @Test("dt zero stops without decay")
    func dtZeroStops() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        #expect(m.advance(dt: 0) == .stop)
        #expect(m.velocity == 0)
    }

    // 7. dt 为负 → .stop
    @Test("negative dt stops")
    func dtNegativeStops() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        #expect(m.advance(dt: -0.1) == .stop)
        #expect(m.velocity == 0)
    }

    // 8. dt >= 1.0 → .stop（后台恢复 guard）
    @Test("dt one or larger stops (background recovery)")
    func dtTooLargeStops() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 1000)
        #expect(m.advance(dt: 1.5) == .stop)
        #expect(m.velocity == 0)
    }

    // 9. 高初速度有限步内必终止
    @Test("high velocity terminates within finite steps")
    func terminatesFinite() {
        var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: 5000)
        var steps = 0
        while case .move = m.advance(dt: ref) {
            steps += 1
            #expect(steps < 2000)
        }
        #expect(m.velocity == 0)
    }

    // 10. friction 越大衰减越慢
    @Test("higher friction retains more velocity")
    func higherFrictionSlowerDecay() {
        var slow = DecelerationModel(friction: 0.99, stopThreshold: thr, refInterval: ref, velocity: 1000)
        var fast = DecelerationModel(friction: 0.94, stopThreshold: thr, refInterval: ref, velocity: 1000)
        _ = slow.advance(dt: ref)
        _ = fast.advance(dt: ref)
        #expect(slow.velocity > fast.velocity)
    }

    // 11. 非法 friction → 回退默认 0.94（修 R1-F2）
    @Test("invalid friction falls back to default")
    func invalidFrictionFallsBack() {
        for bad: CGFloat in [.nan, 0, -0.5, 1.0, 1.5, .infinity] {
            let m = DecelerationModel(friction: bad, stopThreshold: thr, refInterval: ref)
            #expect(m.friction == 0.94)
        }
    }

    // 12. 非法 stopThreshold → 回退默认 0.5（修 R1-F2）
    @Test("invalid stopThreshold falls back to default")
    func invalidThresholdFallsBack() {
        for bad: CGFloat in [.nan, 0, -1, .infinity] {
            let m = DecelerationModel(friction: f, stopThreshold: bad, refInterval: ref)
            #expect(m.stopThreshold == 0.5)
        }
    }

    // 13. 非法 refInterval → 回退默认 1/120（修 R1-F2）
    @Test("invalid refInterval falls back to default")
    func invalidRefIntervalFallsBack() {
        for bad: CGFloat in [.nan, 0, -0.1] {
            let m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: bad)
            #expect(abs(m.refInterval - 1.0 / 120.0) < 1e-12)
        }
    }

    // 14. advance 遇非有限速度 → .stop 兜底（修 R1-F2）
    @Test("advance with non-finite velocity stops")
    func nonFiniteVelocityStops() {
        for bad: CGFloat in [.nan, .infinity, -.infinity] {
            var m = DecelerationModel(friction: f, stopThreshold: thr, refInterval: ref, velocity: bad)
            #expect(m.advance(dt: ref) == .stop)
            #expect(m.velocity == 0)
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --package-path ios/Contracts --filter DecelerationModel`
Expected: 编译失败 —— `cannot find 'DecelerationModel' in scope`

- [ ] **Step 3: 写最小实现**（创建 `DecelerationModel.swift`）

```swift
// Kline Trainer Swift Contracts — C2 DecelerationModel（纯减速物理 + 数值校验）
// Spec: kline_trainer_modules_v1.4.md §C2 + kline_trainer_plan_v1.5.md §3
// Plan: docs/superpowers/plans/2026-05-22-pr-c2-deceleration-animator.md

import Foundation
import CoreGraphics

/// 纯减速物理：基于 deltaTime 的帧率无关指数衰减。
/// 无 UIKit / 无 run loop —— 可确定性单测。`DecelerationAnimator` 持有它做实际驱动。
struct DecelerationModel: Equatable, Sendable {

    /// 单帧推进结果。
    enum Outcome: Equatable, Sendable {
        case move(delta: CGFloat)   // 继续：派发 delta offset（pt）
        case stop                   // 终止：调用方应失活 driver + 触发 onFinish
    }

    let friction: CGFloat        // 每 refInterval 的衰减系数（默认 0.94）
    let stopThreshold: CGFloat   // 停止阈值（pt/s，默认 0.5）
    let refInterval: CGFloat     // 参考帧间隔（默认 1/120）
    var velocity: CGFloat

    init(friction: CGFloat = 0.94,
         stopThreshold: CGFloat = 0.5,
         refInterval: CGFloat = 1.0 / 120.0,
         velocity: CGFloat = 0) {
        // DD-8 / R1-F2：非法 config 回退默认，杜绝 pow(负数,分数)=NaN / friction>=1 永不停
        self.friction = (friction.isFinite && friction > 0 && friction < 1) ? friction : 0.94
        self.stopThreshold = (stopThreshold.isFinite && stopThreshold > 0) ? stopThreshold : 0.5
        self.refInterval = (refInterval.isFinite && refInterval > 0) ? refInterval : (1.0 / 120.0)
        self.velocity = velocity
    }

    /// 推进一帧。`dt` 单位为秒（来自帧驱动 timestamp 差）。
    mutating func advance(dt: CGFloat) -> Outcome {
        // 后台恢复 / 异常 dt：直接停（plan §3 L63-67）
        guard dt > 0, dt < 1.0 else {
            velocity = 0
            return .stop
        }
        // 帧率无关指数衰减（plan §3 L68）
        velocity *= pow(friction, dt / refInterval)
        // DD-8 / R1-F2 defense-in-depth：非有限速度终止，绝不外溢 NaN/inf delta
        guard velocity.isFinite else {
            velocity = 0
            return .stop
        }
        // 停止阈值（plan §3 L69-72）
        if abs(velocity) < stopThreshold {
            velocity = 0
            return .stop
        }
        // 继续：派发衰减后速度 × dt（plan §3 L73）
        return .move(delta: velocity * dt)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --package-path ios/Contracts --filter DecelerationModel`
Expected: PASS（14 tests，0 failures）

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationModelTests.swift
git commit -m "feat(C2): DecelerationModel 纯减速物理 + 数值校验 + 14 tests"
```

---

## Task 2 — DecelerationAnimator + FrameDriving + RealFrameDriver（可注入帧驱动）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationAnimatorTests.swift`

- [ ] **Step 1: 写失败测试**（创建 `DecelerationAnimatorTests.swift`）

> 注：除测 #13 外都注入 `FakeFrameDriver`（不创建真实 Timer/CADisplayLink）。确定性逻辑测试直接调 `handleTick(dt:generation:)`；驱动路径测试用 `fake.fire(dt:)` 驱动**真实生产 onTick 闭包**。`.serialized` 避免并行 spin 干扰 RunLoop.main。

```swift
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DecelerationAnimator", .serialized)
struct DecelerationAnimatorTests {

    private let ref: CGFloat = 1.0 / 120.0

    /// 注入 fake 的 animator + 取最近一次创建的 fake。
    private func makeWithFake(friction: CGFloat = 0.94, stopThreshold: CGFloat = 0.5)
        -> (DecelerationAnimator, () -> FakeFrameDriver?) {
        final class Box { var fake: FakeFrameDriver? }
        let box = Box()
        let a = DecelerationAnimator(friction: friction, stopThreshold: stopThreshold,
                                     makeDriver: { onTick in
            let f = FakeFrameDriver(onTick: onTick); box.fake = f; return f
        })
        return (a, { box.fake })
    }

    // 1. start() 进入减速态 + 创建驱动
    @Test("start begins decelerating and creates a driver")
    func startBegins() {
        let (a, fake) = makeWithFake()
        a.start(initialVelocity: 1000)
        #expect(a.isDecelerating)
        #expect(fake() != nil)
    }

    // 2. handleTick .move → onUpdate 收到衰减后 delta
    @Test("handleTick move dispatches onUpdate with decayed delta")
    func tickDispatchesUpdate() {
        let (a, _) = makeWithFake()
        var updates: [CGFloat] = []
        a.onUpdate = { updates.append($0) }
        a.start(initialVelocity: 1000)
        a.handleTick(dt: ref, generation: a.currentGeneration)
        #expect(updates.count == 1)
        #expect(abs(updates[0] - 940 * ref) < 1e-6)
        #expect(a.isDecelerating)
    }

    // 3. 自然终止：onFinish 一次 + 失活驱动，无 onUpdate
    @Test("natural stop fires onFinish once and invalidates driver")
    func naturalStop() {
        let (a, fake) = makeWithFake()
        var updates = 0, finishes = 0
        a.onUpdate = { _ in updates += 1 }
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 0.52)
        a.handleTick(dt: ref, generation: a.currentGeneration)
        #expect(updates == 0)
        #expect(finishes == 1)
        #expect(!a.isDecelerating)
        #expect(fake()?.isInvalidated == true)
    }

    // 4. 外部 stop() 静默 + 失活驱动
    @Test("external stop is silent and invalidates driver")
    func externalStopSilent() {
        let (a, fake) = makeWithFake()
        var finishes = 0
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 1000)
        a.stop()
        #expect(finishes == 0)
        #expect(!a.isDecelerating)
        #expect(fake()?.isInvalidated == true)
    }

    // 5. resetOnSceneActive() 静默 + 停止
    @Test("resetOnSceneActive is silent and stops")
    func resetSilent() {
        let (a, _) = makeWithFake()
        var finishes = 0
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 1000)
        a.resetOnSceneActive()
        #expect(finishes == 0)
        #expect(!a.isDecelerating)
    }

    // 6. dt-guard：大 dt → onFinish + 失活，无 onUpdate
    @Test("handleTick with large dt finishes (background recovery)")
    func backgroundRecovery() {
        let (a, _) = makeWithFake()
        var updates = 0, finishes = 0
        a.onUpdate = { _ in updates += 1 }
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 1000)
        a.handleTick(dt: 2.0, generation: a.currentGeneration)
        #expect(updates == 0)
        #expect(finishes == 1)
        #expect(!a.isDecelerating)
    }

    // 7. 重复 start() 重置：旧驱动失活 + 新驱动 + 新初速度
    @Test("re-start invalidates old driver and resets velocity")
    func restartResets() {
        let (a, fake) = makeWithFake()
        var updates: [CGFloat] = []
        a.onUpdate = { updates.append($0) }
        a.start(initialVelocity: 1000)
        let firstFake = fake()
        a.handleTick(dt: ref, generation: a.currentGeneration)
        a.start(initialVelocity: 2000)
        #expect(firstFake?.isInvalidated == true)   // 旧驱动被失活
        #expect(fake() !== firstFake)               // 新驱动
        a.handleTick(dt: ref, generation: a.currentGeneration)
        #expect(updates.count == 2)
        #expect(abs(updates[1] - 1880 * ref) < 1e-6)
    }

    // 8. 未 start 时 handleTick no-op
    @Test("handleTick is no-op when not decelerating")
    func tickWhenIdleNoOp() {
        let (a, _) = makeWithFake()
        var updates = 0, finishes = 0
        a.onUpdate = { _ in updates += 1 }
        a.onFinish = { finishes += 1 }
        a.handleTick(dt: ref, generation: a.currentGeneration)
        #expect(updates == 0)
        #expect(finishes == 0)
    }

    // 9. 非有限初速度不启动（修 R1-F2）
    @Test("non-finite initial velocity does not start")
    func nonFiniteInitialVelocityNoStart() {
        for bad: CGFloat in [.nan, .infinity, -.infinity] {
            let (a, fake) = makeWithFake()
            a.start(initialVelocity: bad)
            #expect(!a.isDecelerating)
            #expect(fake() == nil)
        }
    }

    // 10. 旧代次 handleTick 被忽略（修 R2-F1）
    @Test("stale-generation tick is ignored after restart")
    func staleGenerationIgnored() {
        let (a, _) = makeWithFake()
        var updates = 0
        a.onUpdate = { _ in updates += 1 }
        a.start(initialVelocity: 1000)
        let staleGen = a.currentGeneration
        a.start(initialVelocity: 2000)
        a.handleTick(dt: ref, generation: staleGen)            // 旧代次 → 忽略
        #expect(updates == 0)
        a.handleTick(dt: ref, generation: a.currentGeneration) // 新代次 → 生效
        #expect(updates == 1)
    }

    // 11. 经驱动 fire 路由到 onUpdate（驱动真实 onTick 闭包，修 R3-F1）
    @Test("driver fire routes through onTick to onUpdate")
    func driverFireRoutesToUpdate() {
        let (a, fake) = makeWithFake()
        var updates: [CGFloat] = []
        a.onUpdate = { updates.append($0) }
        a.start(initialVelocity: 1000)
        let keepGoing = fake()!.fire(ref)
        #expect(updates.count == 1)
        #expect(abs(updates[0] - 940 * ref) < 1e-6)
        #expect(keepGoing == true)            // 仍在减速 → 驱动继续
    }

    // 12. 释放活跃 animator：驱动下一帧 fire 返回 false → 自失活（weak 清理，修 R1-F1）
    @Test("released animator: driver tick returns false (self-stop)")
    func releasedAnimatorDriverSelfStops() {
        final class Box { var fake: FakeFrameDriver? }
        let box = Box()
        var a: DecelerationAnimator? = DecelerationAnimator(makeDriver: { onTick in
            let f = FakeFrameDriver(onTick: onTick); box.fake = f; return f
        })
        a!.start(initialVelocity: 1000)
        #expect(box.fake != nil)
        a = nil   // 释放 animator（fake 仍由 box 持有）
        #expect(box.fake!.fire(ref) == false)   // onTick [weak self] nil → false（驱动应自失活）
    }

    #if !canImport(UIKit)
    // 13. macOS 真 Timer 驱动 smoke：start() → onUpdate(≥1) → onFinish（真实 adapter 确实 fire）
    @Test("macOS real Timer driver produces updates then finishes")
    func macTimerDriverRuntime() {
        let a = DecelerationAnimator()   // 默认 init → RealFrameDriver(Timer)
        var updates = 0, finishes = 0
        a.onUpdate = { _ in updates += 1 }
        a.onFinish = { finishes += 1 }
        a.start(initialVelocity: 8)
        let deadline = Date().addingTimeInterval(3.0)
        while finishes == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(updates >= 1)
        #expect(finishes == 1)
        #expect(!a.isDecelerating)
    }
    #endif
}

/// 测试用确定性帧驱动：手动 `fire(dt:)` 模拟一帧；记录是否被 `invalidate()`。
@MainActor
final class FakeFrameDriver: FrameDriving {
    let onTick: (CGFloat) -> Bool
    private(set) var isInvalidated = false
    init(onTick: @escaping (CGFloat) -> Bool) { self.onTick = onTick }
    func invalidate() { isInvalidated = true }
    @discardableResult func fire(_ dt: CGFloat) -> Bool { onTick(dt) }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --package-path ios/Contracts --filter DecelerationAnimator`
Expected: 编译失败 —— `cannot find 'DecelerationAnimator' in scope`（或 `FrameDriving`）

- [ ] **Step 3: 写最小实现**（创建 `DecelerationAnimator.swift`）

> 以下代码已用 `swiftc -typecheck -swift-version 6 -strict-concurrency=complete` 在 macOS + iOS-sim SDK 两条路径验证 exit 0。

```swift
// Kline Trainer Swift Contracts — C2 DecelerationAnimator（v1.3：offset 更新必须派发 action）
// Spec: kline_trainer_modules_v1.4.md §C2 + kline_trainer_plan_v1.5.md §3
// Plan: docs/superpowers/plans/2026-05-22-pr-c2-deceleration-animator.md

import Foundation
import CoreGraphics
import QuartzCore   // CACurrentMediaTime（两平台）；CADisplayLink（UIKit）
#if canImport(UIKit)
import UIKit
#endif

/// 帧驱动抽象（internal 测试缝）。每帧回调 `(dt) -> Bool`：返回 false 表示应停止
/// （owner 已释放 / 代次失效），实现据此自失活。可注入 fake 做确定性单测（DD-1 / DD-5）。
@MainActor
protocol FrameDriving: AnyObject {
    func invalidate()
}

/// C2 减速动画器：经注入工厂创建每平台帧驱动的惯性滚动。纯物理在 `DecelerationModel`。
///
/// 用法（C8 / E5 中）：
/// ```
/// animator.onUpdate = { [weak dispatcher] delta in
///     dispatcher?.dispatch(.offsetApplied(deltaPixels: delta))
/// }
/// ```
///
/// 防泄漏（DD-3 / R1-F1）：注入的 onTick 闭包以 `[weak self]` 持本对象；owner 释放后下一帧
/// 闭包返回 false，`RealFrameDriver` 自失活——无需 deinit、无独立 proxy。
/// 防 stale 回调（DD-3 / R2-F1）：`currentGeneration` 每 start 自增，闭包捕获该代次并校验。
@MainActor
public final class DecelerationAnimator {

    /// 每帧 delta offset（pt）。消费者**必须**封装为 `.offsetApplied(deltaPixels:)` 派发给 reducer 来移动面板，
    /// 不可绕过 reducer 直接改写面板偏移状态（spec §C2 v1.3 闸门 #2 F2）。
    /// （注：本类型不持有也不引用任何面板状态类型，故无法直接改写其 offset——验收 #7 以此为不变量。）
    public var onUpdate: ((CGFloat) -> Void)?

    /// 减速**自然结束**（速度 < 阈值 / 后台恢复 dt 异常）时触发一次。
    /// 外部 `stop()` / `resetOnSceneActive()` **不**触发（调用方主动终止）。
    public var onFinish: (() -> Void)?

    private var model: DecelerationModel

    /// 运行态单一真相（跨平台）。供测试断言；不由 driver 派生。
    private(set) var isDecelerating = false

    /// run identity：每次 start 自增；忽略 stale 旧驱动回调（R2-F1）。
    private(set) var currentGeneration = 0

    private var driver: FrameDriving?
    private let makeDriver: (@escaping @MainActor (CGFloat) -> Bool) -> FrameDriving

    public init(friction: CGFloat = 0.94, stopThreshold: CGFloat = 0.5) {
        self.model = DecelerationModel(friction: friction, stopThreshold: stopThreshold)
        self.makeDriver = { onTick in RealFrameDriver(onTick: onTick) }
    }

    /// 测试缝：注入帧驱动工厂（默认 = 真实平台驱动）。
    init(friction: CGFloat = 0.94, stopThreshold: CGFloat = 0.5,
         makeDriver: @escaping (@escaping @MainActor (CGFloat) -> Bool) -> FrameDriving) {
        self.model = DecelerationModel(friction: friction, stopThreshold: stopThreshold)
        self.makeDriver = makeDriver
    }

    /// 以初速度启动惯性滚动。重复调用会重置（先 stop 失活旧驱动 + 代次自增 + 归位）。
    public func start(initialVelocity: CGFloat) {
        stop()
        guard initialVelocity.isFinite else { return }   // DD-8 / R1-F2
        currentGeneration &+= 1
        let gen = currentGeneration
        model.velocity = initialVelocity
        isDecelerating = true
        driver = makeDriver { [weak self] dt in
            // owner 已释放 / 代次失效 → 返回 false 令驱动自失活（DD-3）
            guard let self, self.currentGeneration == gen else { return false }
            self.handleTick(dt: dt, generation: gen)
            return self.isDecelerating
        }
    }

    /// 外部主动停止（如 drawing 激活防 stale 漂移，spec Reducer.swift:112）。静默，不触发 onFinish。
    public func stop() {
        isDecelerating = false
        model.velocity = 0
        driver?.invalidate()
        driver = nil
    }

    /// 由 E5.onSceneActivated() 调用：scene 恢复时复位，防后台 dt 爆炸跳帧。静默。
    public func resetOnSceneActive() {
        stop()
    }

    // MARK: - 测试缝（internal，经 @testable import 可见）

    /// 推进一帧并派发回调；代次不符直接忽略（R2-F1）。
    func handleTick(dt: CGFloat, generation: Int) {
        guard isDecelerating, generation == currentGeneration else { return }
        switch model.advance(dt: dt) {
        case .move(let delta):
            onUpdate?(delta)
        case .stop:
            isDecelerating = false
            driver?.invalidate()
            driver = nil
            onFinish?()
        }
    }
}

/// 真实平台帧驱动（internal）：iOS/Catalyst = CADisplayLink；plain macOS = Timer。
/// 是平台帧对象的 target；`onTick` 返回 false 时自失活（打断 runloop 强持有，DD-3）。
@MainActor
final class RealFrameDriver: FrameDriving {
    private let onTick: @MainActor (CGFloat) -> Bool
    #if canImport(UIKit)
    private var link: CADisplayLink?
    #else
    private var timer: Timer?
    private var lastTimestamp: CFTimeInterval?
    #endif

    init(onTick: @escaping @MainActor (CGFloat) -> Bool) {
        self.onTick = onTick
        #if canImport(UIKit)
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        #else
        let t = Timer(timeInterval: 1.0 / 120.0, target: self,
                      selector: #selector(stepTimer), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        #endif
    }

    func invalidate() {
        #if canImport(UIKit)
        link?.invalidate()
        link = nil
        #else
        timer?.invalidate()
        timer = nil
        #endif
    }

    #if canImport(UIKit)
    @objc private func step(_ link: CADisplayLink) {
        if !onTick(CGFloat(link.targetTimestamp - link.timestamp)) { invalidate() }
    }
    #else
    @objc private func stepTimer() {
        let now = CACurrentMediaTime()
        let dt = lastTimestamp.map { now - $0 } ?? (1.0 / 120.0)
        lastTimestamp = now
        if !onTick(CGFloat(dt)) { invalidate() }
    }
    #endif
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --package-path ios/Contracts --filter DecelerationAnimator`
Expected: PASS（macOS 宿主 13 tests = 12 确定性/fake + 1 真 Timer smoke；Catalyst 编译 12，0 failures）

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationAnimatorTests.swift
git commit -m "feat(C2): DecelerationAnimator + 可注入 FrameDriving + RealFrameDriver + 13 tests"
```

---

## Task 3 — 全量验证 + 验收清单

**Files:**
- Create: `docs/acceptance/2026-05-22-pr-c2-deceleration-animator.md`

- [ ] **Step 1: strict-concurrency build（macOS Timer 分支）**

Run: `swift build --package-path ios/Contracts`
Expected: `Build complete!`，0 concurrency warning/error。
（注 per memory `feedback_swift_local_toolchain_blindspot`：本地新 toolchain 可能漏报跨 actor Sendable 问题。）

- [ ] **Step 2: 全量测试**

Run: `swift test --package-path ios/Contracts`
Expected: 既有测试（PR #59 后约 297+ 个）+ 新增 27 个（model 14 + animator 13）全 PASS，0 failures。

- [ ] **Step 3: Mac Catalyst build-for-testing（编译 iOS/Catalyst CADisplayLink adapter，修 R2-F2）**

Run（working-directory `ios/Contracts`）：
```bash
xcodebuild build-for-testing \
  -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/c2-catalyst 2>&1 | tee /tmp/c2-catalyst.log
grep -F "** TEST BUILD SUCCEEDED **" /tmp/c2-catalyst.log
! grep -E "(^|[[:space:]])(error|warning):" /tmp/c2-catalyst.log
```
Expected: 出现 `** TEST BUILD SUCCEEDED **`，无 `error:` / `warning:`。此步本地编译 `#if canImport(UIKit)` CADisplayLink adapter（与 CI `catalyst-build.yml` 同命令）。
（注：本仓不在 Catalyst 跑 `xcodebuild test`——SwiftPM scheme + Catalyst destination 报 "not configured for the test action"；驱动运行时逻辑由 animator 测试的注入 fake 在 `swift test` 确定性覆盖，见 DD-7。）

- [ ] **Step 4: 写验收清单**（创建 `docs/acceptance/2026-05-22-pr-c2-deceleration-animator.md`）

```markdown
# PR C2 DecelerationAnimator —— 验收清单

> 语言：中文。判定二元可决。证据：命令输出贴 PR comment。

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| 1 | 运行 `swift test --package-path ios/Contracts --filter DecelerationModel` | 终端输出含 `14 tests`、`0 failures` | failures = 0 → 通过；否则不通过 |
| 2 | 运行 `swift test --package-path ios/Contracts --filter DecelerationAnimator` | 终端输出含 `13 tests`、`0 failures` | failures = 0 → 通过；否则不通过 |
| 3 | 运行 `swift test --package-path ios/Contracts` | 全量测试 0 failures | failures = 0 → 通过；否则不通过 |
| 4 | 运行 `swift build --package-path ios/Contracts` | 输出 `Build complete!` | 出现该串且无 error → 通过；否则不通过 |
| 5 | 在 `ios/Contracts` 运行 `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/c2-catalyst` | 输出含 `** TEST BUILD SUCCEEDED **`，无 `error:`/`warning:` | 出现该串且无 error/warning → 通过（编译 iOS/Catalyst CADisplayLink adapter）；否则不通过 |
| 6 | 运行 `grep -n "AppError" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift` | 无任何匹配行 | 0 匹配（C2 不跨错误信任边界）→ 通过；有匹配 → 不通过 |
| 7 | 运行 `grep -n "PanelViewState" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift` | 无任何匹配行 | 0 匹配（animator 不引用面板状态类型 → 不可能直接写 PanelViewState.offset；注 `.offsetApplied` 仅在注释，属合规消费者契约，故此处只查 `PanelViewState`，修 R3-F2）→ 通过；有匹配 → 不通过 |
| 8 | 运行 `grep -n "weak self" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift` | 至少 1 行匹配 | ≥1 匹配（onTick 闭包 weak 持 animator，防 runloop 强持有泄漏）→ 通过；0 匹配 → 不通过 |
```

- [ ] **Step 5: 提交**

```bash
git add docs/acceptance/2026-05-22-pr-c2-deceleration-animator.md
git commit -m "docs(C2): 验收清单"
```

---

## Self-Review（writing-plans 自查）

**1. Spec coverage**：modules §C2 六 public 成员全落 Task 2 ✓；plan §3 物理全落 Task 1 `advance(dt:)` ✓；§C2 v1.3「onUpdate 禁止直接写 offset」落验收 #7 ✓。

**2. Placeholder scan**：每个 code step 含完整可编译代码，无占位 ✓。

**3. Type consistency**：`DecelerationModel.Outcome` / `advance(dt:)` / `handleTick(dt:generation:)` / `isDecelerating` / `currentGeneration` / `makeDriver` / `FrameDriving.invalidate()` / `RealFrameDriver` / `FakeFrameDriver.fire(_:)` 全程一致 ✓；测试常量 `ref = 1/120` 与实现 `refInterval` 默认值一致 ✓。

**4. codex findings 闭合**：
- R1-F1 泄漏 → DD-3 onTick→Bool 自失活 + 测试 #12 ✓；R1-F2 NaN/永不停 → DD-8 + model #11-14 / animator #9 ✓；R1-F3 macOS 无驱动 → DD-7 Timer 真驱动 + 测试 #13 ✓。
- R2-F1 stale 回调 → DD-3 generation token + 测试 #10 ✓；R2-F2 UIKit 未本地编译 + CI 误判 → Task 3 Step 3 + 验收 #5 + DD-7 引 catalyst-build.yml ✓；R2-F3 缺 import Testing → 已补 ✓。
- R3-F1 UIKit 驱动只编译不运行 → DD-1/DD-5 注入式 FrameDriving + fake，driver 调度/失活/清理/代次在 `swift test` 确定性覆盖（测试 #1/#3/#4/#7/#11/#12）；已验证 Catalyst 不能跑测试故不依赖之 ✓；R3-F2 grep 误伤 → 验收 #7 改只查 `PanelViewState` ✓。
