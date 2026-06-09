# C8b 图表交互路径 + H1 闭环 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 C7 `ChartGestureArbiter` 生产接线到 `ChartContainerView`，落地交互 production handler（pan→offsetApplied/减速、两指切周期、长按十字光标、画线激活 `animator.stop()→算 range→setDrawingSnapshot`），实现 `TrainingEngine.activateDrawingTool/deleteDrawing`，并以 host 集成测试**真正闭环 H1**（spec §C1b 闸门 #4 F3 Wave 2 验收）。

**Architecture:** 编排归 `TrainingEngine`（E5——它已 own 两个 `DecelerationAnimator`〔private〕+ 两面板 reducer + 既有 `buy/sell/switchPeriodCombo` 的 effect 派发模式）。`ChartContainerView`（C8，UIKit）的 `Coordinator` 持 arbiter、attach-once、把原始手势回调路由进 engine。视口几何/可见 range 复用 C8a `RenderStateBuilder`（平台无关），`activateDrawingTool` 所需 `bounds` 由渲染路径缓存进 engine（spec `activateDrawingTool` 签名无 bounds 参数）。十字光标为**视图层瞬态**（Coordinator 本地 + `make(crosshair:)` 透传渲染），不进 engine 业务状态。

**Tech Stack:** Swift 6.0 / Swift Testing / UIKit（`#if canImport(UIKit)`）/ SwiftUI `UIViewRepresentable` + `Coordinator` / Mac Catalyst build-for-testing required check。

---

## 关键设计决策（D1–D10；前 4 项为 user 2026-06-07 裁决）

- **D1（user 裁决 · 编排归属）**：`activateDrawing` effect handler + 减速接线放 **engine**；engine 缓存渲染路径传入的 `bounds`（`@ObservationIgnored`，不触发观察），保 spec `activateDrawingTool(_:)` 字面无 bounds 参数。理由：engine own animators〔private〕+ panels + 复用 `buy/sell` 的 effect 派发模式；Coordinator 处理 effect 需打破 animator private 封装（E5a 刻意收紧的 trust boundary）。
- **D2（user 裁决 · 画线面板）**：`activateDrawingTool` **加 `panel: PanelId` 参数**（spec 签名无 panel，但 drawing 模式是 per-`PanelViewState`）。`deleteDrawing(at:)` **不加** panel（`engine.drawings` 是扁平数组，按 index 删）。
- **D3（user 裁决 · 十字光标）**：onLongPress callback 接线 + **透传渲染**。十字光标点为 **Coordinator 视图层本地状态**（不进 engine），经 `RenderStateBuilder.make(..., crosshair:)` 新增参数流到 `renderState.crosshairPoint`。打磨（吸附最近 candle、HUD）留 Wave 3。
- **D4（user 裁决 · 运行时验收）**：C2/C8 运行时 gate（CADisplayLink 减速运行时 + draw 帧 <4ms/120Hz）以**手动 runbook 文档** artifact 交付（device/simulator 步骤/预期/pass-fail）；能自动化的（H1 host 集成测试、Catalyst build）尽量自动；device 帧预算证据由 user 按 runbook 执行后回填。手势仲裁运行时证据归顺位 9 U2（outline §四 L121/L125）。
- **D5（test seam · 可注入减速驱动）**：`TrainingEngine` 的 internal `init` 新增 `decelerationDriverFactory`（默认 = 真实 `RealFrameDriver`）。H1 集成测试经 `@testable` 注入 `FakeFrameDriver`（沿用 `DecelerationAnimatorTests` 范式），确定性触发/失活减速帧。该参数 internal（`FrameDriving` 是 internal 类型），`make()` 走默认；既有 caller 因有默认值不受影响。
- **D6（减速 onUpdate 接线）**：engine `init` 末尾把 `animators.upper/lower.onUpdate` 绑到 `applyOffsetDelta(_:panel:)`（经 reducer `offsetApplied`，spec §C2 闸门 #2 F2 禁直写 offset）。`onFinish` 不接（C8b 无消费者：减速自然结束后面板留 freeScrolling）。
- **D7（硬切 autoTracking 立即停减速）**：`buy/sell/holdOrObserve`（经 `advanceAndAccount`）与 `switchPeriodCombo` 硬切 autoTracking 时，C8b 加 `stopAllDeceleration()`（spec plan L235「立即中断 free-scrolling」）。否则接线 onUpdate 后，交易期间残余减速回调会在 autoTracking 派 `offsetApplied` 致漂移（reducer 仅在 drawing 吞 offsetApplied，autoTracking 不吞）。
- **D8（autoTracking offset==0 不变量）**：C8a `makeViewport` 对 offset **mode-agnostic**（autoTracking + 非零 offset 在 C8a 测试里被断言；见 `RenderStateBuilderTests` L101-153），故**不能**改 `makeViewport` 在 autoTracking 忽略 offset。改由 engine 维护「autoTracking ⇒ offset==0」不变量：硬切 autoTracking 后经 reducer `offsetApplied(-offset)` 归零（遵守 spec L1153「offset 只经 reducer」；在 reduce(.tradeTriggered/.periodComboSwitched) **之后**调，此时 mode 已 autoTracking、offsetApplied 不被吞）。既有 E5b 测试 offset 恒 0 → 归零是 no-op，零回归。
- **D9（两指切周期映射）**：arbiter `onTwoFingerSwipe(SwipeDirection)` → `switchPeriodCombo(PeriodDirection)`，纯函数映射 `up → .toLarger`、`down → .toSmaller`（spec 未钉死方向；本 PR 决策，runtime-tunable，runbook 注明）。host 可测。
- **D10（文件组织）**：engine 新方法以**同文件 extension** 加在 `TrainingEngine.swift` 末尾（Swift `private` 文件作用域 → 同文件 extension 可访问 `private let animators`/`private(set) var drawings`，免破坏 E5a trust boundary）。`init`/`advanceAndAccount`/`switchPeriodCombo` 就地小改。沿用 E5a/E5b「TrainingEngine 运行时全在一文件」先例。

---

## 文件结构

| 文件 | 动作 | 责任 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | Modify | init 加可注入驱动 + onUpdate 接线 + `@ObservationIgnored` bounds 缓存；`advanceAndAccount`/`switchPeriodCombo` 加停减速+归零；末尾 extension 加 C8b 交互方法 + 私有 helper |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift` | Modify | `make` 加 `crosshair: CGPoint? = nil` 参数，流到 `renderState.crosshairPoint`（取代硬编码 nil） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift` | Modify | 加 `Coordinator`（持 arbiter/crosshair/engine/panel/view ref）；`makeCoordinator`/`makeUIView` attach-once + 路由回调；`updateUIView` 记录 bounds + 透传 crosshair + 同步 drawingMode |
| `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureRouting.swift` | Create | 纯函数 `periodDirection(for: SwipeDirection) -> PeriodDirection`（平台无关，host 测） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift` | Create | engine 交互方法单测（pan dispatch / 硬切停减速+归零 / activateDrawingTool / deleteDrawing） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingHandlerH1Tests.swift` | Create | **H1 production handler 集成测试**（注入 fake 驱动；stop-before-range；drawing 后无 offsetApplied 漂移；trade 停减速） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/GestureRoutingTests.swift` | Create | `periodDirection(for:)` 双向映射测试 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift` | Modify | 加 crosshair 透传测试 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewCompileTests.swift` | Modify | 加 Coordinator 存在性/构造编译反射（Catalyst gate） |
| `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md` | Create | C2/C8 运行时手动验收 runbook（CADisplayLink 减速 + draw 帧预算） |
| `docs/acceptance/2026-06-07-pr-c8b-chart-interaction-h1.md` | Create | 验收 checklist（中文 action/expected/pass-fail） |

---

## Task 1: Engine test seam（可注入减速驱动）+ onUpdate 接线 + bounds 缓存 + 私有 helper

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift`

- [ ] **Step 1: 写失败测试（注入 fake 驱动 + onUpdate 经 reducer 派 offsetApplied）**

新建 `TrainingEngineInteractionTests.swift`：

```swift
// C8b TrainingEngine 交互编排测试（Wave 2 顺位 7 下半）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite struct TrainingEngineInteractionTests {

    static let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// 单 .m3 双面板 engine + 注入 fake 减速驱动；返回 engine 与「按创建序的 fake 列表」(0=upper,1=lower)。
    static func engine(closes: [Double] = Array(repeating: 10, count: 100))
        -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        let maxTick = closes.count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(closes),
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { onTick in
                let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f
            })
        return (e, { box.fakes })
    }

    @Test("减速 onUpdate 经 reducer 派 offsetApplied（freeScrolling 累加 offset + bump）")
    func decelerationOnUpdateRoutesThroughReducer() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)                       // autoTracking → freeScrolling
        e.endPan(velocity: 1000, panel: .upper)         // startDeceleration → animator.start
        let before = e.upperPanel.offset
        let fired = fakes()[0].fire(1.0 / 120.0)        // 推进一帧 → onUpdate → offsetApplied
        #expect(fired == true)                          // 仍在减速
        #expect(e.upperPanel.offset != before)          // offset 被 reducer 累加
        #expect(e.upperPanel.interactionMode == .freeScrolling)
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests 2>&1 | tail -20`
Expected: 编译失败——`extra argument 'decelerationDriverFactory'` + `beginPan`/`endPan` 未定义。

- [ ] **Step 3: 改 init 签名 + 建可注入 animators + 接线 onUpdate + bounds 缓存**

在 `TrainingEngine.swift` init 形参末尾（`initialLowerPeriod: Period = .daily)` 之前）加参数：

```swift
                initialUpperPeriod: Period = .m60,
                initialLowerPeriod: Period = .daily,
                decelerationDriverFactory: @escaping (@escaping @MainActor (CGFloat) -> Bool) -> FrameDriving =
                    { onTick in RealFrameDriver(onTick: onTick) }) {
```

把 init 体内 `self.animators = (upper: DecelerationAnimator(), lower: DecelerationAnimator())` 改为：

```swift
        self.animators = (
            upper: DecelerationAnimator(makeDriver: decelerationDriverFactory),
            lower: DecelerationAnimator(makeDriver: decelerationDriverFactory))
        // C8b：减速每帧 delta 必经 reducer offsetApplied（spec §C2 闸门 #2 F2，禁直写 offset）。
        // self 此时已全初始化（animators 为最后一个无默认值的存储属性；lastRenderedBounds 有默认值）。
        self.animators.upper.onUpdate = { [weak self] delta in self?.applyOffsetDelta(delta, panel: .upper) }
        self.animators.lower.onUpdate = { [weak self] delta in self?.applyOffsetDelta(delta, panel: .lower) }
```

在存储属性区（`private let animators` 行后）加 bounds 缓存（`@ObservationIgnored`：渲染路径写入不触发 SwiftUI 重建循环）：

```swift
    /// C8b：渲染路径缓存的最近 bounds（按面板）。`activateDrawingTool` 算 candleRange 复用
    /// （spec `activateDrawingTool` 签名无 bounds 参数 → 缓存，D1）。`@ObservationIgnored`：
    /// 渲染层 `recordRenderBounds` 写入不得触发观察重建（否则 updateUIView 写 → 重渲染循环）。
    @ObservationIgnored private var lastRenderedBounds: (upper: CGRect, lower: CGRect) = (.zero, .zero)
```

- [ ] **Step 4: 末尾加 C8b 交互 extension（本 Task 仅私有 helper；公共方法后续 Task 续加同一 extension）**

在 `TrainingEngine.swift` 类闭合 `}`（约 L447）之后、`#if DEBUG`（约 L449）之前插入：

```swift
// MARK: - C8b 交互编排（C7 手势接线下游 + 画线激活 H1 production handler）
// 同文件 extension：可访问 `private let animators` / `private(set) var drawings` / `lastRenderedBounds`
// （Swift `private` 文件作用域；免破坏 E5a init internal 的 trust boundary）。

extension TrainingEngine {

    // MARK: 私有 helper（面板/动画/bounds 取址 + 经 reducer 的 offset 派发）

    private func panelState(_ panel: PanelId) -> PanelViewState {
        panel == .upper ? upperPanel : lowerPanel
    }

    private func renderBounds(_ panel: PanelId) -> CGRect {
        panel == .upper ? lastRenderedBounds.upper : lastRenderedBounds.lower
    }

    private func animator(for panel: PanelId) -> DecelerationAnimator {
        panel == .upper ? animators.upper : animators.lower
    }

    /// 把 ChartAction 派给对应面板的 reducer（统一面板 mutate 入口）。
    @discardableResult
    private func reduce(_ action: ChartAction, on panel: PanelId) -> ChartReduceEffect {
        switch panel {
        case .upper: return upperPanel.reduce(action)
        case .lower: return lowerPanel.reduce(action)
        }
    }

    /// 减速 onUpdate + 单指 pan `.changed` 共用：每帧 delta 经 reducer offsetApplied
    /// （drawing 吞 / autoTracking·freeScrolling 累加 + bump，spec L1123-1129）。
    private func applyOffsetDelta(_ delta: CGFloat, panel: PanelId) {
        _ = reduce(.offsetApplied(deltaPixels: delta), on: panel)
    }

    /// 停两面板减速（D7：硬切 autoTracking / 画线激活前调）。
    private func stopAllDeceleration() {
        animators.upper.stop()
        animators.lower.stop()
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests 2>&1 | tail -20`
Expected: 仍失败——`beginPan`/`endPan` 未定义（本 Task 只建 seam + helper）。先确认**编译错误只剩 pan 方法缺失**（不再是 init 参数/onUpdate 错误）。Task 2 补 pan 方法后本测试转 PASS。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift
git commit -m "feat(c8b): engine 可注入减速驱动 + onUpdate 经 reducer 接线 + bounds 缓存 seam"
```

---

## Task 2: Engine 单指 pan 手势派发（beginPan / applyPanOffset / endPan / cancelPan）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（续 C8b extension）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift`

- [ ] **Step 1: 写失败测试**

在 `TrainingEngineInteractionTests` 内加：

```swift
    @Test("beginPan: autoTracking → freeScrolling + revision bump")
    func beginPanEntersFreeScrolling() {
        let (e, _) = Self.engine()
        let r0 = e.upperPanel.revision
        e.beginPan(panel: .upper)
        #expect(e.upperPanel.interactionMode == .freeScrolling)
        #expect(e.upperPanel.revision == r0 + 1)
    }

    @Test("applyPanOffset: freeScrolling offset 累加")
    func applyPanOffsetAccumulates() {
        let (e, _) = Self.engine()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 12, panel: .upper)
        e.applyPanOffset(deltaPixels: 8, panel: .upper)
        #expect(e.upperPanel.offset == 20)
    }

    @Test("endPan: freeScrolling + 有限速度 → 启动减速（驱动创建、未失活）")
    func endPanStartsDeceleration() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        #expect(fakes().count >= 1)
        #expect(fakes()[0].isInvalidated == false)
    }

    @Test("endPan: 速度低于阈值 → 不启动（start guard no-op，无 fake 创建）")
    func endPanBelowThresholdNoStart() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.endPan(velocity: 0.1, panel: .upper)   // < stopThreshold 0.5 → animator.start no-op
        #expect(fakes().isEmpty)
    }

    @Test("cancelPan: 不启动减速（freeScrolling 结束但无惯性）")
    func cancelPanNoDeceleration() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.cancelPan(panel: .upper)
        #expect(fakes().isEmpty)            // 未调 animator.start
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests 2>&1 | tail -20`
Expected: 编译失败——`beginPan`/`applyPanOffset`/`endPan`/`cancelPan` 未定义。

- [ ] **Step 3: 在 C8b extension 加 pan 派发方法**

在 Task 1 的 extension 内（私有 helper 之后）加：

```swift
    // MARK: 单指 pan 手势派发（C7 arbiter onPan 回调下游）

    /// onPan `.began`：autoTracking → freeScrolling（spec 状态转换表 L231）。
    public func beginPan(panel: PanelId) {
        _ = reduce(.panStarted, on: panel)
    }

    /// onPan `.changed`：freeScrolling 下 offset 累加（drawing 模式 arbiter 截获不到此处）。
    public func applyPanOffset(deltaPixels: CGFloat, panel: PanelId) {
        applyOffsetDelta(deltaPixels, panel: panel)
    }

    /// onPan `.ended`：panEnded → `.startDeceleration` effect → 启动惯性（spec C2/闸门 #2）。
    public func endPan(velocity: CGFloat, panel: PanelId) {
        if case .startDeceleration(let v) = reduce(.panEnded(velocity: velocity), on: panel) {
            animator(for: panel).start(initialVelocity: v)
        }
    }

    /// onPan `.cancelled`（两指接管 / drawing 截获结算后）：结束 freeScrolling，**不**启动惯性。
    /// 经 reducer `panEnded(0)` 关闭 freeScrolling 相位；忽略其 `.startDeceleration(0)` effect（不调 start）。
    public func cancelPan(panel: PanelId) {
        _ = reduce(.panEnded(velocity: 0), on: panel)
    }
```

- [ ] **Step 4: 跑测试确认通过（含 Task 1 的 onUpdate 测试）**

Run: `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests 2>&1 | tail -20`
Expected: 全部 PASS（Task 1 的 `decelerationOnUpdateRoutesThroughReducer` + 本 Task 5 个）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift
git commit -m "feat(c8b): engine 单指 pan 手势派发（begin/apply/end/cancel）"
```

---

## Task 3: Engine 硬切 autoTracking 停减速 + offset 归零（D7 + D8）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（`advanceAndAccount` + `switchPeriodCombo` + extension 加私有归零 helper）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
    @Test("交易硬切 autoTracking 时停减速：trade 后 stale 帧不漂移 offset")
    func tradeStopsDecelerationNoDriftAfter() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        let upperFake = fakes()[0]
        _ = e.buy(panel: .upper, tier: .tier1)          // tradeTriggered → 硬切 autoTracking + stopAllDeceleration
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(upperFake.isInvalidated == true)         // 减速被停（驱动失活）
        let off = e.upperPanel.offset
        let fired = upperFake.fire(1.0 / 120.0)          // 模拟延迟帧
        #expect(fired == false)                          // 驱动自失活，不再发 onUpdate
        #expect(e.upperPanel.offset == off)              // 无 offsetApplied 漂移
    }

    @Test("硬切 autoTracking 后 offset 经 reducer 归零（D8 不变量：autoTracking ⇒ offset==0）")
    func autoTrackingOffsetZeroedAfterTrade() {
        let (e, _) = Self.engine()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 45, panel: .upper)   // freeScrolling, offset=45
        #expect(e.upperPanel.offset == 45)
        _ = e.holdOrObserve(panel: .upper)                 // 经 advanceAndAccount 硬切 + 归零
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.offset == 0)                  // 归零（makeViewport mode-agnostic 下保 autoTracking 锁最新）
    }

    @Test("switchPeriodCombo 硬切 autoTracking 同样停减速 + 归零")
    func periodComboStopsAndZeroes() {
        // 双面板需多周期数据：用 60m/日 默认组合，向 toSmaller 切到 15m/60m
        let (e, fakes) = Self.engineMultiPeriod()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        let upperFake = fakes()[0]
        e.switchPeriodCombo(direction: .toSmaller)
        #expect(upperFake.isInvalidated == true)
        #expect(e.upperPanel.offset == 0)
        #expect(e.upperPanel.interactionMode == .autoTracking)
    }
```

并加多周期 fixture helper（60m/日默认组合 + 15m，供 `switchPeriodCombo` toSmaller 命中 15m/60m）：

```swift
    /// 多周期 engine（默认 60m/日 组合可向 toSmaller 切 15m/60m）+ 注入 fake 驱动。
    static func engineMultiPeriod() -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        func candle(_ p: Period, start: Int, end: Int) -> KLineCandle {
            KLineCandle(period: p, datetime: Int64(start) * 180, open: 10, high: 11, low: 9, close: 10,
                        volume: 1, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: start, endGlobalIndex: end)
        }
        let m3 = (0..<8).map { candle(.m3, start: $0, end: $0) }
        let m15 = [candle(.m15, start: 0, end: 3), candle(.m15, start: 4, end: 7)]
        let m60 = [candle(.m60, start: 0, end: 3), candle(.m60, start: 4, end: 7)]
        let daily = [candle(.daily, start: 0, end: 7)]
        let all: [Period: [KLineCandle]] = [.m3: m3, .m15: m15, .m60: m60, .daily: daily]
        let e = TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: 7), allCandles: all, maxTick: 7,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m60, initialLowerPeriod: .daily,
            decelerationDriverFactory: { onTick in
                let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f
            })
        return (e, { box.fakes })
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests 2>&1 | tail -20`
Expected: `autoTrackingOffsetZeroedAfterTrade` 失败（offset==45 not 0）；`tradeStopsDeceleration...` 失败（fire 返回 true / offset 漂移，因未停减速）。

- [ ] **Step 3: 加归零 helper + 改 advanceAndAccount/switchPeriodCombo**

在 C8b extension 私有 helper 区加：

```swift
    /// D8：硬切 autoTracking 后经 reducer 把 offset 归零（spec L1153「offset 只经 reducer」）。
    /// 必须在 reduce(.tradeTriggered/.periodComboSwitched) **之后**调——此时 mode 已 autoTracking，
    /// offsetApplied 不被 drawing 吞、被 autoTracking 分支累加。autoTracking + makeViewport mode-agnostic
    /// 下，offset!=0 会令视口偏移，故须归零以「锁定最新」（D8）。
    private func resetOffsetAfterAutoTracking(_ panel: PanelId) {
        let off = panelState(panel).offset
        if off != 0 { _ = reduce(.offsetApplied(deltaPixels: -off), on: panel) }
    }
```

在 `advanceAndAccount(panel:)` 体首加 `stopAllDeceleration()`，并在两个 `.tradeTriggered` reduce 后加归零：

```swift
    private func advanceAndAccount(panel: PanelId) {
        stopAllDeceleration()                       // D7：立即中断 free-scrolling 惯性（spec L235）
        _ = upperPanel.reduce(.tradeTriggered)
        _ = lowerPanel.reduce(.tradeTriggered)
        resetOffsetAfterAutoTracking(.upper)        // D8：autoTracking ⇒ offset==0
        resetOffsetAfterAutoTracking(.lower)
        _ = tick.advance(steps: stepsForPeriod(period(of: panel)))
        drawdown.update(currentCapital: currentTotalCapital)
        forceCloseIfEnded()
    }
```

在 `switchPeriodCombo(direction:)` 命中分支（`upperPanel.period = next.upper` 之前）加 `stopAllDeceleration()`；在两个 `.periodComboSwitched` reduce 之后加归零：

```swift
        guard let u = allCandles[next.upper], !u.isEmpty,
              let l = allCandles[next.lower], !l.isEmpty else { return }
        stopAllDeceleration()                       // D7
        upperPanel.period = next.upper
        lowerPanel.period = next.lower
        _ = upperPanel.reduce(.periodComboSwitched)
        _ = lowerPanel.reduce(.periodComboSwitched)
        resetOffsetAfterAutoTracking(.upper)        // D8
        resetOffsetAfterAutoTracking(.lower)
```

- [ ] **Step 4: 跑测试确认通过 + 跑既有 E5b 测试零回归**

Run: `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests 2>&1 | tail -10`
Expected: 全 PASS。

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests 2>&1 | tail -5`
Expected: 全 PASS（offset 恒 0 → 归零 no-op → 零回归）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift
git commit -m "feat(c8b): 硬切 autoTracking 停减速 + offset 经 reducer 归零（D7/D8）"
```

---

## Task 4: Engine `activateDrawingTool(_:panel:)` + `deleteDrawing(at:)`（H1 production handler 主体）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（续 C8b extension）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift`

- [ ] **Step 1: 写失败测试（基本激活 + 删除）**

```swift
    @Test("activateDrawingTool: autoTracking → drawing，snapshot 含 viewport candleRange")
    func activateDrawingEntersDrawingMode() {
        let (e, _) = Self.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        let expected = RenderStateBuilder.visibleCandleRange(
            panelState: e.upperPanel, candles: e.allCandles[.m3]!,
            tick: e.tick.globalTickIndex, bounds: Self.bounds)
        e.activateDrawingTool(.trend, panel: .upper)
        guard case .drawing(let snap) = e.upperPanel.interactionMode else {
            Issue.record("应进入 drawing 模式"); return
        }
        #expect(snap.frozen.candleRange == expected)
    }

    @Test("activateDrawingTool: drawing 模式下再激活 → no-op（工具切换归 DrawingToolManager/Wave 3）")
    func activateDrawingWhileDrawingNoOp() {
        let (e, _) = Self.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.activateDrawingTool(.trend, panel: .upper)
        let modeBefore = e.upperPanel.interactionMode
        e.activateDrawingTool(.ray, panel: .upper)
        #expect(e.upperPanel.interactionMode == modeBefore)   // 仍 drawing(同 snapshot)
    }

    @Test("deleteDrawing: 按 index 从 engine.drawings 删除")
    func deleteDrawingRemovesByIndex() {
        let d0 = DrawingObject(toolType: .trend, anchors: [], isExtended: false, panelPosition: 0)
        let d1 = DrawingObject(toolType: .ray, anchors: [], isExtended: false, panelPosition: 0)
        let (e, _) = Self.engineWithDrawings([d0, d1])
        e.deleteDrawing(at: 0)
        #expect(e.drawings.count == 1)
        #expect(e.drawings[0].toolType == .ray)
    }
```

加注入初始 drawings 的 helper：

```swift
    static func engineWithDrawings(_ drawings: [DrawingObject]) -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        let e = TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: 99),
            allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: 100)),
            maxTick: 99, initialCapital: 100_000, initialCashBalance: 100_000,
            initialDrawings: drawings, initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { onTick in
                let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f
            })
        return (e, { box.fakes })
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests 2>&1 | tail -20`
Expected: 编译失败——`activateDrawingTool`/`deleteDrawing`/`recordRenderBounds` 未定义。

- [ ] **Step 3: 实现 recordRenderBounds + activateDrawingTool + deleteDrawing**

在 C8b extension 加（public 方法区）：

```swift
    // MARK: bounds 记录（渲染路径每次 updateUIView 调）

    /// ChartContainerView.updateUIView 调：缓存该面板最近渲染 bounds，供 `activateDrawingTool` 算 range（D1）。
    public func recordRenderBounds(_ bounds: CGRect, panel: PanelId) {
        switch panel {
        case .upper: lastRenderedBounds.upper = bounds
        case .lower: lastRenderedBounds.lower = bounds
        }
    }

    // MARK: 画线激活 H1 production handler（spec §C1b 闸门 #4 F3 + effect 合约 L1026-1032）

    /// 画线工具激活（spec `activateDrawingTool`；C8b 加 `panel` 参数，D2）。
    /// **顺序契约（spec Reducer effect L1026-1032，闸门 #2 F2）**：
    ///   ① `animator.stop()`（防 stale 漂移；必须在算 range 之前——停后无新帧可改 offset）
    ///   ② 基于当前（已冻结）面板状态算 candleRange（复用 C8a `visibleCandleRange`）
    ///   ③ 派 `setDrawingSnapshot`（同步无漂移 → 进 drawing；理论 stale → 留 autoTracking）
    public func activateDrawingTool(_ tool: DrawingToolType, panel: PanelId) {
        guard case .requestDrawingSnapshotAfterStoppingAnimator(let t, let baseRev) =
                reduce(.activateDrawing(tool), on: panel) else {
            return   // 已在 drawing（.none）等 → no-op（工具切换归 DrawingToolManager/Wave 3）
        }
        animator(for: panel).stop()                                   // ①
        let ps = panelState(panel)                                    // ② 当前=已冻结 offset
        let range = RenderStateBuilder.visibleCandleRange(
            panelState: ps, candles: allCandles[ps.period] ?? [],
            tick: tick.globalTickIndex, bounds: renderBounds(panel))
        _ = reduce(.setDrawingSnapshot(tool: t, baseRevision: baseRev, candleRange: range), on: panel)   // ③
    }

    /// 删除已完成绘线（spec `deleteDrawing(at:)`）。越界 trap（caller bug，与 spec precondition 同风格）。
    public func deleteDrawing(at index: Int) {
        precondition(drawings.indices.contains(index), "deleteDrawing index out of bounds")
        drawings.remove(at: index)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests 2>&1 | tail -10`
Expected: 全 PASS。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineInteractionTests.swift
git commit -m "feat(c8b): activateDrawingTool(stop→range→snapshot) + deleteDrawing + recordRenderBounds"
```

---

## Task 5: H1 production handler 集成测试（**H1 真正闭环**）

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingHandlerH1Tests.swift`

闭合 spec §C1b 闸门 #4 F3 **Wave 2 验收**（modules L1180）：「production handler 集成测试 — 模拟延迟 animator 回调，验证 handler 必须**先**调用 `animator.stop()` 再计算 range；drawing 退出后无 `offsetApplied` 到达 reducer」。三模块在场：C2 `DecelerationAnimator`（PR #60）+ E5a/E5b `TrainingEngine`（PR #80/#81）+ C8 `RenderStateBuilder`/`ChartContainerView`（C8a #84 + 本 PR）。

- [ ] **Step 1: 写测试**

```swift
// C8b H1 production handler 集成测试（Wave 2 顺位 7 下半）—— 闭合 spec §C1b 闸门 #4 F3 Wave 2 验收。
// 三模块在场：C2 DecelerationAnimator + E5a/E5b TrainingEngine + C8 RenderStateBuilder/ChartContainerView。
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("H1 production handler 集成（animator.stop → range → setDrawingSnapshot）")
struct TrainingEngineDrawingHandlerH1Tests {

    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    static let ref: CGFloat = 1.0 / 120.0

    // MARK: H1-1 range 取冻结 offset + 驱动已失活
    // 注（F2 诚实化）：`DecelerationAnimator.stop()` 只置 isDecelerating=false / 失活驱动，**不改 offset**
    // （animator L84-89）→ 「先 stop 再算 range」对 snapshot 的 range *值* 是顺序无关的（同步 handler 无插帧）。
    // 本测试**不**声称证明时序顺序；它证明：① 驱动确被 stop（失活）② range 来自冻结 offset。
    // 真正 load-bearing 的「stop-before-return（停后无未来漂移）」由 H1-2 证明。

    @Test("activateDrawing：range 取冻结 offset + 驱动已失活（非时序证明，见上注）")
    func rangeUsesFrozenOffsetAndDriverDeactivated() {
        let (e, fakes) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)              // 启动减速
        let upperFake = fakes()[0]
        _ = upperFake.fire(Self.ref)                         // 减速跑一帧 → offset 进一步漂移
        // 捕获激活时刻的「预期 range」（仍 freeScrolling、offset=漂移后值）
        let psAtActivation = e.upperPanel
        let expected = RenderStateBuilder.visibleCandleRange(
            panelState: psAtActivation, candles: e.allCandles[.m3]!,
            tick: e.tick.globalTickIndex, bounds: Self.bounds)
        e.activateDrawingTool(.trend, panel: .upper)
        #expect(upperFake.isInvalidated == true)             // ① stop 已调（驱动失活）
        guard case .drawing(let snap) = e.upperPanel.interactionMode else {
            Issue.record("应进入 drawing"); return
        }
        #expect(snap.frozen.candleRange == expected)         // ② range 来自冻结 offset
        #expect(snap.frozen.offset == psAtActivation.offset) // offset 冻结一致
    }

    // MARK: H1-2 drawing 后无 offsetApplied 漂移（延迟 animator 回调被 stop 自失活吞掉）

    @Test("drawing 进入后延迟减速帧不漂移 offset（stop 后驱动自失活，无 onUpdate）")
    func staleDecelerationTickAfterDrawingNoDrift() {
        let (e, fakes) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        let upperFake = fakes()[0]
        _ = upperFake.fire(Self.ref)
        e.activateDrawingTool(.trend, panel: .upper)
        let offsetFrozen = e.upperPanel.offset
        let revFrozen = e.upperPanel.revision
        let fired = upperFake.fire(Self.ref)                 // 延迟帧（stop 后）
        #expect(fired == false)                              // 驱动自失活，不再回调
        #expect(e.upperPanel.offset == offsetFrozen)         // 无漂移
        #expect(e.upperPanel.revision == revFrozen)          // 无额外 bump
    }

    // MARK: H1-3 drawing 模式 reducer 兜底吞 offsetApplied（即便有杂散回调到达）

    @Test("drawing 模式直派 offsetApplied 被吞（reducer 兜底，spec L1123）")
    func drawingModeSwallowsOffsetApplied() {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.activateDrawingTool(.trend, panel: .upper)
        guard case .drawing(let snap0) = e.upperPanel.interactionMode else {
            Issue.record("应进入 drawing"); return
        }
        let offsetBefore = e.upperPanel.offset
        e.applyPanOffset(deltaPixels: 99, panel: .upper)     // 模拟杂散 offsetApplied
        #expect(e.upperPanel.offset == offsetBefore)         // 被吞，offset 不变
        guard case .drawing(let snap1) = e.upperPanel.interactionMode else {
            Issue.record("仍应 drawing"); return
        }
        #expect(snap1.frozen.baseRevision == snap0.frozen.baseRevision)
    }

    // MARK: H1-4 drawing 退出后无 offsetApplied 漂移（spec L1182 字面「drawing 退出后」）
    // 退出 drawing 的**生产路径** = 交易硬切（tradeTriggered：drawing→autoTracking，C8b 已实现）。
    // 关键：退出到 autoTracking 后 offsetApplied **不再被吞**（reducer 只在 drawing 吞，L1123），故唯一保护是
    // 「进入 drawing 时 stop 动画 + 交易再 stopAllDeceleration（D7）使其后无减速帧」。本测试正向覆盖 spec 字面
    // 「退出 (exit)」路径（补 F1；drawingCommitted/onTap 提交触发归 Wave 3，此处用已实现的交易退出路径）。

    @Test("drawing 退出（交易→autoTracking）后延迟减速帧不漂移 offset（spec L1182 退出路径）")
    func noOffsetAppliedAfterDrawingExit() {
        let (e, fakes) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 30, panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)            // 启动减速
        let upperFake = fakes()[0]
        _ = upperFake.fire(Self.ref)
        e.activateDrawingTool(.trend, panel: .upper)        // 进 drawing（① stop 动画 → 驱动失活）
        #expect({ if case .drawing = e.upperPanel.interactionMode { return true }; return false }())
        e.holdOrObserve(panel: .upper)                      // 退出：tradeTriggered → autoTracking（生产路径）
        #expect(e.upperPanel.interactionMode == .autoTracking)
        let off = e.upperPanel.offset                       // D8：归零后应为 0
        let fired = upperFake.fire(Self.ref)               // 退出后延迟减速帧
        #expect(fired == false)                            // 驱动早已失活 → 无 onUpdate
        #expect(e.upperPanel.offset == off)                // autoTracking 不吞 offsetApplied，但无帧到达故无漂移
    }
}
```

- [ ] **Step 2: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineDrawingHandlerH1Tests 2>&1 | tail -15`
Expected: 4 个 PASS。

- [ ] **Step 3: 提交**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingHandlerH1Tests.swift
git commit -m "test(c8b): H1 production handler 集成测试闭环（stop→range→snapshot + 无漂移）"
```

---

## Task 6: `RenderStateBuilder.make` 加 crosshair 透传参数（D3）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`

- [ ] **Step 1: 写失败测试**

在 `RenderStateBuilderTests` 加：

```swift
    @Test("crosshair 参数透传到 renderState.crosshairPoint")
    @MainActor
    func crosshairPassthrough() {
        let e = TrainingEngine.preview()
        let pt = CGPoint(x: 120, y: 240)
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds, crosshair: pt)
        #expect(rs.crosshairPoint == pt)
    }

    @Test("crosshair 默认 nil（既有 C8a 调用面不变）")
    @MainActor
    func crosshairDefaultsNil() {
        let e = TrainingEngine.preview()
        let rs = RenderStateBuilder.make(engine: e, panel: .upper, bounds: Self.bounds)
        #expect(rs.crosshairPoint == nil)
    }
```

> 注：`RenderStateBuilderTests` 已有 `Self.bounds`（C8a）；若 perf/几何套件用不同 bounds 常量，沿用该文件既有静态常量名，勿新引入。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilder 2>&1 | tail -15`
Expected: `crosshairPassthrough` 编译失败——`make` 无 `crosshair:` 参数。

- [ ] **Step 3: 改 make 签名 + 透传**

`RenderStateBuilder.make` 签名加默认参数：

```swift
    @MainActor
    public static func make(engine: TrainingEngine, panel: PanelId, bounds: CGRect,
                            crosshair: CGPoint? = nil) -> KLineRenderState {
```

把返回的 `crosshairPoint: nil)   // 长按十字光标属 C8b` 改为：

```swift
            crosshairPoint: crosshair)   // C8b：长按十字光标由 ChartContainerView.Coordinator 视图层透传（D3）
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilder 2>&1 | tail -10`
Expected: 全 PASS（含既有 C8a 20 测试 + 新 2 个 = 22）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "feat(c8b): RenderStateBuilder.make 加 crosshair 透传参数（D3）"
```

---

## Task 7: `periodDirection(for:)` 纯函数映射（D9）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureRouting.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/GestureRoutingTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `ChartEngine/GestureRoutingTests.swift`：

```swift
import Testing
@testable import KlineTrainerContracts

@Suite struct GestureRoutingTests {
    @Test("两指上滑 → toLarger（较大/较粗周期）")
    func upToLarger() { #expect(periodDirection(for: .up) == .toLarger) }

    @Test("两指下滑 → toSmaller（较小/较细周期）")
    func downToSmaller() { #expect(periodDirection(for: .down) == .toSmaller) }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter GestureRoutingTests 2>&1 | tail -10`
Expected: 编译失败——`periodDirection` 未定义。

- [ ] **Step 3: 实现纯函数**

新建 `ChartEngine/GestureRouting.swift`：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureRouting.swift
// C8b 手势路由纯函数（平台无关，host 测）。arbiter onTwoFingerSwipe(SwipeDirection) →
// TrainingEngine.switchPeriodCombo(PeriodDirection) 的映射。
// spec 未钉死方向语义（plan v1.5 §4.4 仅「两指上下滑切周期」）；本 PR 决策（D9）：
//   上滑(.up) → .toLarger（较粗/较大周期），下滑(.down) → .toSmaller（较细/较小周期）。
// runtime-tunable：真机手感不符可调本函数，runbook 注明。

/// 两指上下滑方向 → 周期组合切换方向（D9）。
public func periodDirection(for swipe: SwipeDirection) -> PeriodDirection {
    switch swipe {
    case .up:   return .toLarger
    case .down: return .toSmaller
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter GestureRoutingTests 2>&1 | tail -10`
Expected: 2 个 PASS。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureRouting.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/GestureRoutingTests.swift
git commit -m "feat(c8b): periodDirection(for:) 两指切周期映射纯函数（D9）"
```

---

## Task 8: `ChartContainerView.Coordinator` — C7 arbiter 生产接线 + crosshair + bounds 记录

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewCompileTests.swift`

> UIKit-only（`#if canImport(UIKit)`）→ macOS host 编译为空，逻辑不可 host 行为测；**接线正确性靠 engine 侧 host 测（Task 1-5）+ Catalyst 编译反射 + runbook 运行时验收**（outline §四 L125「acceptance 验证接线正确」+ D4）。

- [ ] **Step 1: 写编译反射测试（Catalyst gate；先失败）**

`UIViewRepresentableContext` 无公共 init（SwiftUI），**不能**在测试里造 `context` 调 `makeUIView(context:)`。故直接测 `Coordinator` 的纯接线面（`attach(to:)` 不需 `context`）。把 `ChartContainerViewCompileTests.swift` 的 `instantiates()` 之后加：

```swift
    @Test("Coordinator 可构造 + attach 装 5 个识别器（C7 接线编译反射）")
    @MainActor
    func coordinatorAttachesRecognizers() {
        let engine = TrainingEngine.preview()
        let view = ChartContainerView(panel: .upper, engine: engine)
        let coordinator = view.makeCoordinator()
        let host = KLineView(frame: .zero)
        coordinator.attach(to: host)
        #expect(host.gestureRecognizers?.count == 5)   // C7 attach 5 个识别器（单指/两指/pinch/长按/tap）
        coordinator.attach(to: host)                    // 幂等：再 attach 不重复装
        #expect(host.gestureRecognizers?.count == 5)
    }

    @Test("Coordinator crosshairPoint 默认 nil（视图层瞬态）")
    @MainActor
    func coordinatorCrosshairDefaultsNil() {
        let engine = TrainingEngine.preview()
        let coordinator = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        #expect(coordinator.crosshairPoint == nil)
    }
```

- [ ] **Step 2: 跑测试确认失败（Catalyst 编译）**

host `swift test` 对本 UIKit-gated 文件编译为空，真实门为 Catalyst：
Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived 2>&1 | tail -15`
Expected: 编译失败——`makeCoordinator`/`Coordinator`/`coordinator.crosshairPoint` 未定义。

- [ ] **Step 3: 实现 ChartContainerView + Coordinator（覆盖 Step 1 草案为最终版）**

把 `ChartContainerView.swift` 整体替换为（保留文件头注释，更新实现约束注 #8 已运行期闭环）：

```swift
// Kline Trainer Swift Contracts — C8 ChartContainerView（@Observable→UIKit 桥接 + C7 手势接线）
// Spec: kline_trainer_modules_v1.4.md §C8 (L1409-1467) + §C7 (L1397-1406)
// Design: docs/superpowers/specs/2026-06-07-pr-c8a-chart-container-render-design.md（C8a 渲染）
//        + docs/superpowers/plans/2026-06-07-pr-c8b-chart-interaction-h1.md（C8b 交互）
//
// 平台门：UIKit-only。macOS swift build 编译为空；Catalyst build-for-testing 落 required CI 闸门。
// spec 实现约束：不订阅 ObservationRegistrar（1）；靠 @Bindable 触发重建（2）；KLineView 只收值类型（3）；
// buildRenderState 算值域（4，RenderStateBuilder）；不监听 scenePhase（5）。
// C8b：Coordinator 持 C7 ChartGestureArbiter，attach-once，把手势回调路由进 engine（D1）；
//      长按十字光标为视图层瞬态（Coordinator 本地 + make(crosshair:) 透传，D3）。

#if canImport(UIKit)
import SwiftUI
import UIKit
import CoreGraphics

public struct ChartContainerView: UIViewRepresentable {
    public let panel: PanelId
    @Bindable public var engine: TrainingEngine

    public init(panel: PanelId, engine: TrainingEngine) {
        self.panel = panel
        self._engine = Bindable(wrappedValue: engine)
    }

    public func makeCoordinator() -> Coordinator { Coordinator(panel: panel, engine: engine) }

    public func makeUIView(context: Context) -> KLineView {
        let view = KLineView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    public func updateUIView(_ view: KLineView, context: Context) {
        // 每次重建刷新 Coordinator 的 engine/panel 引用（ChartContainerView 是值类型，可能换 engine）。
        context.coordinator.sync(panel: panel, engine: engine, view: view)
        engine.recordRenderBounds(view.bounds, panel: panel)   // D1：缓存 bounds 供 activateDrawingTool 算 range
        view.renderState = RenderStateBuilder.make(
            engine: engine, panel: panel, bounds: view.bounds,
            crosshair: context.coordinator.crosshairPoint)       // D3：透传视图层瞬态十字光标
    }

    /// C7 手势仲裁接线（spec §C7 + plan v1.5 §手势仲裁规则）。持 arbiter + 视图层十字光标本地状态。
    @MainActor
    public final class Coordinator {
        private var panel: PanelId
        private weak var engine: TrainingEngine?
        private weak var view: KLineView?
        private let arbiter = ChartGestureArbiter()
        /// 视图层瞬态十字光标（D3，不进 engine）。长按时设置，松手清空。
        public private(set) var crosshairPoint: CGPoint?

        public init(panel: PanelId, engine: TrainingEngine) {
            self.panel = panel
            self.engine = engine
        }

        /// updateUIView 每次调：刷新引用（值类型 ChartContainerView 可能携新 engine/panel）。
        func sync(panel: PanelId, engine: TrainingEngine, view: KLineView) {
            self.panel = panel
            self.engine = engine
            self.view = view
            // drawing 模式下 arbiter 截获单指 pan（spec §C7 L1393）：按当前面板 mode 同步开关。
            arbiter.drawingMode = isDrawing(engine: engine, panel: panel)
        }

        /// attach-once（C7 R6 幂等）：makeUIView 调一次；路由 5 类回调进 engine。
        func attach(to view: UIView) {
            self.view = view as? KLineView
            arbiter.onPan = { [weak self] deltaX, velocityX, phase in
                guard let self, let engine = self.engine else { return }
                switch phase {
                case .began:   engine.beginPan(panel: self.panel)
                case .changed: engine.applyPanOffset(deltaPixels: deltaX, panel: self.panel)
                case .ended:   engine.endPan(velocity: velocityX, panel: self.panel)
                case .cancelled: engine.cancelPan(panel: self.panel)
                }
            }
            arbiter.onTwoFingerSwipe = { [weak self] swipe in
                guard let self, let engine = self.engine else { return }
                engine.switchPeriodCombo(direction: periodDirection(for: swipe))
            }
            arbiter.onLongPress = { [weak self] location, phase in
                guard let self else { return }
                switch phase {
                case .began, .changed: self.setCrosshair(location)
                case .ended, .cancelled: self.setCrosshair(nil)
                }
            }
            // onPinch（缩放改 visibleCount）属 Wave 3；onTap（画线锚点）需 DrawingInputController（Wave 3）→ C8b 不接。
            arbiter.attach(to: view)
        }

        private func isDrawing(engine: TrainingEngine, panel: PanelId) -> Bool {
            let mode = (panel == .upper) ? engine.upperPanel.interactionMode : engine.lowerPanel.interactionMode
            if case .drawing = mode { return true }
            return false
        }

        /// 设置/清空十字光标并即时重渲染（视图层瞬态，不经 SwiftUI observation）。
        private func setCrosshair(_ point: CGPoint?) {
            crosshairPoint = point
            guard let view, let engine else { return }
            view.renderState = RenderStateBuilder.make(
                engine: engine, panel: panel, bounds: view.bounds, crosshair: point)
        }
    }
}
#endif
```

- [ ] **Step 4: Catalyst build-for-testing 确认通过**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived 2>&1 | tee /tmp/cat.log | tail -5 && grep -F "** TEST BUILD SUCCEEDED **" /tmp/cat.log && ! grep -E "(^|[[:space:]])(error|warning):" /tmp/cat.log && echo "GATE PASS"`
Expected: `** TEST BUILD SUCCEEDED **` + `GATE PASS`，无 error/warning。

> ⚠️ per `feedback_swift_local_toolchain_blindspot`：本地 swift test 绿 ≠ CI 绿；Catalyst 编译面（@MainActor/Sendable/weak）须本地 Catalyst 真跑过再推。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewCompileTests.swift
git commit -m "feat(c8b): ChartContainerView.Coordinator C7 arbiter 接线 + 十字光标透传"
```

---

## Task 9: 运行时验收 runbook + 验收 checklist + 全量验证

**Files:**
- Create: `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md`
- Create: `docs/acceptance/2026-06-07-pr-c8b-chart-interaction-h1.md`

- [ ] **Step 1: 写运行时验收 runbook（D4）**

新建 `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md`，内容覆盖 C2/C8 运行时 gate（outline §四 L121）：

```markdown
# C8b 运行时验收 runbook（C2 CADisplayLink 减速 + C8 draw 帧预算）

**性质**：device/simulator **手动**验收（CLI/CI 仅编译，不跑 UIKit 运行时；per outline §四 L121/L149）。
执行者：user（按步骤操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：在 U2 TrainingView（顺位 9）落地后，或用一个最小 SwiftUI 宿主把 `ChartContainerView(panel:.upper, engine:.preview())`
> 放进 Mac Catalyst / iPad 运行。两指/单指手势仲裁运行时证据归顺位 9 U2（本 runbook 只验 C2 减速 + C8 帧预算）。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | iPad/Catalyst 上单指水平快滑 K 线后松手 | 图表惯性滚动后平滑减速停下（CADisplayLink 驱动，非瞬停/非卡顿） | pass = 有可见惯性衰减且自然停 |
| 2 | 减速过程中点「买入/持有」 | 滚动立即中断、硬切锁定最新 K 线（无平滑过渡，spec L235）；其后无回弹漂移 | pass = 立即锁定且无后续漂移 |
| 3 | Instruments Time Profiler / Core Animation 录制滚动 + 减速 | `KLineView.draw(_:)` 单帧 < 4ms（120Hz 预算，spec L1467）；记录实测峰值 ms | pass = 峰值单帧 < 4ms（填实测值：____ ms） |
| 4 | 长按 K 线拖动 | 出现十字光标随手指移动；松手消失 | pass = 十字光标显示/跟随/消失正常 |
| 5 | 减速运行中切到后台再回前台 | 无 dt 爆炸跳帧（onSceneActivated→resetOnSceneActive，C2） | pass = 回前台无跳帧/无残留滚动 |

**回填**：执行后把 #3 实测 ms 填入；本 runbook 链接进收尾 completion doc 作 C2/C8 运行时 artifact。
```

- [ ] **Step 2: 写验收 checklist**

新建 `docs/acceptance/2026-06-07-pr-c8b-chart-interaction-h1.md`：

```markdown
# C8b 图表交互路径 + H1 闭环 — 验收 checklist（Wave 2 顺位 7 下半）

非编码者可执行。每项 action / expected / pass-fail；pass 标准二值可判。

| # | 操作（action） | 预期（expected） | pass / fail |
|---|---|---|---|
| 1 | 终端 `cd ios/Contracts && swift test --filter TrainingEngineDrawingHandlerH1Tests` | 末行 `Test run with 4 tests in 1 suite passed`，0 failures | pass = 4 tests 且 passed 且 0 failures |
| 2 | 终端 `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests` | 末行 passed，0 failures（12 tests） | pass = 0 failures 且 ≥12 tests |
| 3 | 终端 `cd ios/Contracts && swift test` （全量） | 末行 `Test run with <N> tests in <M> suites passed`，0 failures。baseline 实测 **674**（commit 22c88de）；C8b 新增 host 测约 +20（Interaction 12 + H1 4 + GestureRouting 2 + RenderStateBuilder 2；ChartContainerViewCompile 2 为 UIKit-gated host=0）→ N≈694 | pass = 0 failures 且 N ≥ 692 |
| 4 | 终端 `grep -n "animator(for: panel).stop()" ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 命中 `activateDrawingTool` 内 stop 行（① 早于算 range） | pass = 恰 1 处命中且在 activateDrawingTool 体内 |
| 5 | 终端 `grep -n "decelerationDriverFactory" ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 命中 init 参数 + 2 处 animators 构造复用 | pass = ≥2 处命中 |
| 6 | CI：PR 页 `Mac Catalyst build-for-testing on macos-15` required check | 绿色 success（ChartContainerView+Coordinator 编译链接通过） | pass = 该 required check success（本地 `xcodebuild build-for-testing -destination 'platform=macOS,variant=Mac Catalyst'` 得 `** TEST BUILD SUCCEEDED **` 无 error/warning） |
| 7 | 打开 `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md` | C2/C8 运行时手动验收 runbook 在位（5 项 action/expected/pass-fail） | pass = 文件存在且含 #3 帧预算 < 4ms 项 |
| 8 | 终端 `git diff --stat 22c88de..HEAD -- ios/` | 改 3 既有文件（TrainingEngine.swift / RenderStateBuilder.swift / ChartContainerView.swift）+ 新文件（GestureRouting.swift + 4 测试）；无其他 ios 既有文件被改 | pass = 仅上述文件出现 |

## spec 偏离记录（须回填 Wave 2 收尾 completion doc 的 deviation ledger）
- **D2**：`activateDrawingTool(_:panel:)` 比 spec L1622 字面 `func activateDrawingTool(_: DrawingToolType)` **多 `panel: PanelId` 参数**——drawing 模式是 per-`PanelViewState`，须指明面板。依据 user 2026-06-07 裁决（本 plan §决策 D2）。`deleteDrawing(at:)` 与 spec L1623 一致（不加 panel）。

## 范围边界（本 PR 不含 → Wave 3 / 顺位 9）
- pinch 缩放改 visibleCount（onPinch）、画线锚点放置/提交（onTap + DrawingInputController + drawingCommitted/Cancelled 生产触发）→ Wave 3。
- 手势仲裁运行时证据（双识别器/斜向消歧）→ 顺位 9 U2（outline §四 L121/L125）。
- draw 帧预算 device 实测 ms 由 runbook #3 执行后回填。
```

- [ ] **Step 3: 全量 swift test + Catalyst build 双绿**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: `Test run with <N> tests ... passed`，0 failures。

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived 2>&1 | tee /tmp/cat.log | tail -3 && grep -F "** TEST BUILD SUCCEEDED **" /tmp/cat.log && ! grep -E "(^|[[:space:]])(error|warning):" /tmp/cat.log && echo "CATALYST GATE PASS"`
Expected: `** TEST BUILD SUCCEEDED **` + `CATALYST GATE PASS`。

- [ ] **Step 4: 提交**

```bash
git add docs/runbooks/2026-06-07-c8b-runtime-acceptance.md \
        docs/acceptance/2026-06-07-pr-c8b-chart-interaction-h1.md
git commit -m "docs(c8b): 运行时验收 runbook + 验收 checklist（H1 闭环 D4）"
```

---

## Self-Review（plan 完成后自查）

**1. Spec coverage（C8a design §1.2/§1.4 + outline §四 + H1 RFC）：**
- C7 arbiter 生产接线（attach-once + 路由）→ Task 8 ✅
- 生产 handler `activateDrawing→stop→range→setDrawingSnapshot` → Task 4 ✅；`panEnded→startDeceleration→onUpdate→offsetApplied` → Task 1+2 ✅
- `TrainingEngine.activateDrawingTool/deleteDrawing` → Task 4 ✅（D2：activateDrawingTool 加 panel）
- **H1 production handler 集成测试** → Task 5 ✅（stop-before-range + drawing 后无 offsetApplied）
- 十字光标接线 + 透传渲染 → Task 6（make 参数）+ Task 8（Coordinator）✅
- 两指切周期 → Task 7（映射）+ Task 8（路由）✅
- C2/C8 运行时 artifact → Task 9 runbook ✅（D4）
- C8a 未覆盖的 autoTracking-offset-0 不变量（C8b 引入 offset 路径必维护）→ Task 3 ✅（D8）

**2. Placeholder 扫描：** Task 8 Step 1 为草案（明确标注 Step 3/4 覆盖为终版，因 `UIViewRepresentableContext` 无公共 init）；其余步骤均含完整代码。无 TBD/TODO。

**3. 类型一致性：** `decelerationDriverFactory` 类型 = DecelerationAnimator internal init 的 makeDriver 类型 `(@escaping @MainActor (CGFloat) -> Bool) -> FrameDriving`；`reduce(_:on:)`/`animator(for:)`/`panelState(_:)`/`renderBounds(_:)`/`applyOffsetDelta`/`stopAllDeceleration`/`resetOffsetAfterAutoTracking` 命名跨 Task 一致；`periodDirection(for:)` 测试与实现签名一致；`make(crosshair:)` 默认 nil 保 C8a caller。

**4. 风险/攻击面（待 opus 4.8 xhigh 对抗 review）：**
- R1（D8 归零的 reducer 双派发）：硬切后 `offsetApplied(-off)` 多一次 revision bump——可接受（单调性不破），但 reviewer 可能质疑「为何不在 reducer 归零」→ 答：reducer 冻结（Wave 0 C1b），D8 注明。
- R2（drawing 模式 trade 归零失效）：drawing 模式 `offsetApplied` 被吞，但 `resetOffsetAfterAutoTracking` 在 `.tradeTriggered` **之后**调（此时已 autoTracking 非 drawing）→ 不被吞，正确。
- R3（init self 逃逸闭包）：onUpdate `[weak self]` 在 init 末尾、所有存储属性赋值后接线 → 合法；`lastRenderedBounds` 有默认值不算未初始化。
- R4（Coordinator weak engine/view）：weak 防 retain cycle；回调内 guard let 取强引用；arbiter 强持有 Coordinator 的回调闭包（闭包 [weak self=Coordinator]），arbiter 由 Coordinator 强持有 → 闭包 weak 断环。
- R5（H1 stop-before-range 测可证性）：用「range==冻结 offset 推导值 + 驱动失活 + 延迟帧无漂移」三断言间接证顺序（host 无法插桩 mid-handler 时序，已在 Task 5 注明）。
```
