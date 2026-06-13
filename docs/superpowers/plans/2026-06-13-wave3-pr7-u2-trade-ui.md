# Wave 3 顺位 7：U2 交易 UI 接线 + 交易反馈 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把已冻结的 6a engine API（`currentPositionTier` / `forceCloseManually`）+ M0.4 `AppError` 反馈契约接到 U2 训练页：顶栏「仓位 X/5」、底部「结束本局」手动强平按钮（确认弹窗 → 路由结算）、交易失败 Toast、成功 `.heavy` 触觉。

**Architecture:** 沿用本仓「平台无关纯值（host 全测）+ 薄 UIKit/SwiftUI 壳（`#if canImport(UIKit)`，Catalyst 编译守护，不 host 测）」分层。新增 1 个纯值 `TradeFeedback`（把 `Result<_, AppError>` 决策成 haptic/toast，host 测）+ 扩 `TrainingTopBarContent` 加 tier 显示串（host 测）；`TrainingView` 壳只做执行（捕获 Result → 触觉/Toast、确认弹窗 → `forceCloseManually` → 复用既有 `runFinalize` 路由）。engine/schema/持久化 **0 改动**（契约由 6a + RFC 冻结，本锚仅消费）。

**Tech Stack:** Swift 6.0 / SwiftUI / Swift Testing（`@Test`/`#expect`）/ SwiftPM `KlineTrainerContracts` target / Mac Catalyst build-for-testing CI。

---

## 背景与契约来源（实施前必读）

本锚是 RFC-governed **消费锚**——所有公共面契约已由顺位 1 RFC（`docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md`）+ plan v1.5 钉死，**实施锚不得现编未治理公共面**。

**依赖（DAG `7 ← 1, 6, 10a`，全部已 merged）**：顺位 1 RFC（#94）+ 6a/6b engine 契约（#95/#97，提供 `currentPositionTier`/`forceCloseManually`）+ **10a 持久化基础（#99，`b4f0e2a`）**——`runFinalize` 走的是已修的单事务 finalize port（§4.7a 失败保留），故手动结束承接的失败-保留语义是 10a 之后的硬化版本。各需求的权威来源：

| 需求 | 权威契约 | engine API 状态 |
|---|---|---|
| 顶栏「仓位 X/5」 | RFC §4.1 / §4.4b；plan v1.5 §6.2.1 L916 | `engine.currentPositionTier: Int`（0...5）**已存在**（6a，PR #95） |
| 底部「结束本局」手动强平 | RFC §4.4a；plan v1.5 §6.2.2 | `engine.forceCloseManually() -> Bool`（返 settlement-safe 信号）**已存在**（6a，PR #95） |
| 交易失败 Toast（资金不足 / 持仓不足） | plan v1.5 §6.2.4 L735/L736；RFC §六（"已 spec'd 无需 RFC 契约"） | `AppError.userMessage` / `.shouldShowToast` **已冻结**（M0.4，`AppError.swift`） |
| 成功 `.heavy` 触觉（Normal/Replay；Review 无） | plan v1.5 §6.2.4「买入/卖出确认后 → UIImpactFeedbackGenerator(.heavy)」；capability matrix L841 | `UIImpactFeedbackGenerator`（UIKit，壳层） |
| 顶栏 = 实时总资金 / 结算 = 冻结总资金 | RFC §4.2（reconcile，**无 engine 改动**）；plan v1.5 §6.2.1 | `engine.currentTotalCapital`**已接**（顶栏现状）；结算 `total_capital` 由 U3 `SettlementContent` + 顺位 11 路由**已接** |

**关键设计决策（实施时遵守）：**

- **D1 — Toast 文案用 `AppError.userMessage` 单一真值源，不重抄 plan 字面。** plan L735「资金不足，无法买入」/ L736「持仓不足」是 illustrative；M0.4 `AppError`（`insufficientCash → "可用资金不足"`、`insufficientHolding → "持仓不足"`）是冻结权威契约（沿用「spec 示例 illustrative，冻结契约权威」先例，memory `project_pr63_e4_merged` D2）。是否打 Toast 用 `AppError.shouldShowToast`（`.trade(.disabled)` → false，由按钮禁用态自然呈现；其余 trade reason → true）。
- **D2 — 触觉仅在「买入/卖出成功」时触发，不含「持有/观察」与「结束本局」。** plan v1.5 §6.2.4 把 `.heavy` 明列在「买入/卖出确认后」步骤；持有/观察（仅推进 tick）与手动结束（结算路由）spec 未列触觉。**「确认后」读作「成功成交后」**——失败交易（资金/持仓不足）不执行 §6.2.4 后续 advance/标记步骤，故只在 `Result.success` 震动，与 runbook「失败不震动」断言一致。Review 模式不显示交易按钮（`showsTradeButtons == canBuySell()` 为 false），故 capability matrix L841「触觉反馈 Review ❌」由按钮不可见**自然满足**，无需额外门。
- **D3 — 手动结束复用既有 `runFinalize()` 路径，承接 §4.7a 失败保留语义。** `forceCloseManually()` 已封装「强平 + settlement-safe 自检」；壳只需：确认弹窗 →（确认）调用 → 返 `true` 则走 `runFinalize()`（与自动结束同一 finalize/路由/失败-alert 路径）；返 `false`（Review/disabled/非有限财务量的安全降级）则 **no-op 不路由**。手动结束发生在 maxTick 之前，`maybeAutoEnd` 的 `isAtEnd` 门不会误触发；置 `didFinalize = true` 防任何重入。
- **D4 — `TradeFeedback` init 泛型 over Success。** 反馈决策只依赖「成功 vs 失败」，与成功载荷 `TradeOperation` 无关；泛型 init（`init<Success>(result: Result<Success, AppError>)`）使纯值层解耦、host 测无需构造完整 `TradeOperation`。壳传入 `Result<TradeOperation, AppError>` 自动适配。
- **D5 — §4.2「结束总资金 vs 当前总资金」对 顺位 7 无新生产代码。** 顶栏现状已喂 `engine.currentTotalCapital`（实时），结算窗由 U3 `SettlementContent.totalCapital = record.totalCapital`（冻结）+ 顺位 11 路由呈现。顺位 7 仅 **保持** 顶栏喂 `currentTotalCapital`（Task 3 加 tier 时不改该参数）+ 在 acceptance/runbook 断言该语义不回归。

**Scope / size：** 生产 ~90 行（`TradeFeedback` ~25 + `TrainingTopBarContent` +5 + `TrainingView` 壳 +60），测试 ~70 行，2 doc。**远低于 500 行阈值 → 单 PR 不拆**（outline「plan 超 500 拆 交易动作接线 / 反馈层」未触发）。

**Out of scope（不做）：** engine/coordinator/schema/CONTRACT_VERSION 任何改动（6a + 10a 已冻）；Replay 结算窗呈现（顺位 8，本锚 replay 手动结束仍走 `onSessionEnded(nil)` retreat）；画线面板（顺位 4）；周期/后台 autosave、finalize fence、provenance（顺位 10）；夜间调色板（顺位 9）。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeFeedback.swift` | 纯值：`Result<_, AppError>` → `{firesHaptic, toastMessage}`（成功/失败决策 + Toast 文案 + shouldShowToast 门）。Foundation only，host 测。 | **Create** |
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeFeedbackTests.swift` | `TradeFeedback` host 测（成功/4 trade reason/disabled 抑制）。 | **Create** |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift` | 扩 init 加 `positionTier: Int` 参数 + 输出 `position: String`（"仓位 X/5"）。 | **Modify** |
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift` | 更新 9 个既有 3-arg callsite → 4-arg；加 tier 边界 host 测（0/5、3/5、clamp）。 | **Modify** |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | 壳接线：顶栏加 `Text(bar.position)`；picker onPick 捕获 Result → 触觉/Toast；底部 `bottomBar`「结束本局」+ 确认弹窗 + `endManually()` 路由；Toast overlay。`#if canImport(UIKit)`，Catalyst 编译守护，不 host 测。 | **Modify** |
| `docs/runbooks/2026-06-13-wave3-pr7-trade-ui-runtime-acceptance.md` | 运行时手动验收 runbook（顺位 13 阻塞依赖之一）：仓位 X/5 实时、Toast 可见、触觉、手动结束→结算、失败不 mutate/不震动。 | **Create** |
| `docs/acceptance/2026-06-13-wave3-pr7-u2-trade-ui.md` | 非-coder 可执行验收清单（命令 + CI check）。 | **Create** |

---

## Task 1：`TradeFeedback` 纯值（host 测）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeFeedback.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeFeedbackTests.swift`

- [ ] **Step 1: 写失败测试**

`ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeFeedbackTests.swift`：

```swift
import Testing
@testable import KlineTrainerContracts

@Suite("TradeFeedback")
struct TradeFeedbackTests {
    // 成功（载荷类型与决策无关 → 用 Int 占位，验 D4 泛型 init）
    @Test("success → 触觉、无 Toast")
    func successFiresHapticNoToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.success(0))
        #expect(fb.firesHaptic == true)
        #expect(fb.toastMessage == nil)
    }

    @Test("资金不足 → 无触觉、Toast = AppError.userMessage")
    func insufficientCashToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.failure(.trade(.insufficientCash)))
        #expect(fb.firesHaptic == false)
        #expect(fb.toastMessage == "可用资金不足")
    }

    @Test("持仓不足 → 无触觉、Toast = 持仓不足")
    func insufficientHoldingToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.failure(.trade(.insufficientHolding)))
        #expect(fb.firesHaptic == false)
        #expect(fb.toastMessage == "持仓不足")
    }

    @Test("invalidShareCount → Toast = 股数非法")
    func invalidShareCountToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.failure(.trade(.invalidShareCount)))
        #expect(fb.firesHaptic == false)
        #expect(fb.toastMessage == "股数非法")
    }

    // disabled 由按钮禁用态自然呈现 → shouldShowToast == false → 不打 Toast（D1）
    @Test("disabled → 无触觉、无 Toast（按钮禁用态已呈现）")
    func disabledSuppressesToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.failure(.trade(.disabled)))
        #expect(fb.firesHaptic == false)
        #expect(fb.toastMessage == nil)
    }

    @Test("Equatable / Sendable 值语义")
    func equatable() {
        let a = TradeFeedback(result: Result<Int, AppError>.success(1))
        let b = TradeFeedback(result: Result<String, AppError>.success("x"))
        #expect(a == b)   // 同决策（成功）→ 相等，与载荷类型无关
    }
}
```

- [ ] **Step 2: 跑测试验证失败**

Run: `cd ios/Contracts && swift test --filter TradeFeedback`
Expected: 编译失败（`cannot find 'TradeFeedback' in scope`）。

- [ ] **Step 3: 写最小实现**

`ios/Contracts/Sources/KlineTrainerContracts/UI/TradeFeedback.swift`：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeFeedback.swift
// Kline Trainer Swift Contracts — U2 交易反馈纯值（Wave 3 顺位 7）
// Spec: kline_trainer_plan_v1.5.md §6.2.4（买入/卖出确认后触觉 + 失败 Toast L735/L736）
//     + AppError.swift（M0.4 冻结：userMessage / shouldShowToast）。
//
// 平台无关纯值（host 全测）：把 engine.buy/sell 的 `Result<_, AppError>` 决策成两条 UI 效果——
// 是否触发 .heavy 触觉、是否打 Toast 及文案。壳层（TrainingView）只执行（不决策）。
// 决议（D1/D2/D4）：
// - D1 Toast 文案 = AppError.userMessage（M0.4 单一真值源，不重抄 plan 字面）；是否打用 shouldShowToast
//   （.trade(.disabled) → false，由按钮禁用态自然呈现）。
// - D2 触觉仅在成功时（买入/卖出成功）；失败不震动。
// - D4 init 泛型 over Success：反馈只依赖「成功 vs 失败」，与成功载荷 TradeOperation 无关 → 解耦 + host 测免构造。

import Foundation

public struct TradeFeedback: Equatable, Sendable {
    /// 是否触发 .heavy 触觉（仅交易成功）。
    public let firesHaptic: Bool
    /// 需展示的 Toast 文案；nil = 不打 Toast（成功 / disabled 等 shouldShowToast==false 的错误）。
    public let toastMessage: String?

    public init<Success>(result: Result<Success, AppError>) {
        switch result {
        case .success:
            self.firesHaptic = true
            self.toastMessage = nil
        case .failure(let error):
            self.firesHaptic = false
            self.toastMessage = error.shouldShowToast ? error.userMessage : nil
        }
    }
}
```

- [ ] **Step 4: 跑测试验证通过**

Run: `cd ios/Contracts && swift test --filter TradeFeedback`
Expected: `Test run with 6 tests ... 0 failures`，6 个 `TradeFeedback` 测试全 ✔。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TradeFeedback.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeFeedbackTests.swift
git commit -m "feat(pr7): TradeFeedback 纯值（Result→触觉/Toast 决策，D1/D2/D4）"
```

---

## Task 2：`TrainingTopBarContent` 加「仓位 X/5」（host 测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift`

- [ ] **Step 1: 写失败测试 + 更新既有 callsite**

先更新 `TrainingTopBarContentTests.swift` 中 **全部 9 个既有 callsite**：把 `TrainingTopBarContent(totalCapital: …, holdingCost: …, returnRate: …)` 加上 `, positionTier: 0`（既有测试关注 currency/percent 格式，与 tier 无关 → 补 0 即可，不改既有断言）。例如：

```swift
let c = TrainingTopBarContent(totalCapital: 102_345.67, holdingCost: 0, returnRate: 0, positionTier: 0)
```

（9 处机械更新：第 9/15/21/27/33/39/45/51/52 行 callsite——逐个补 `, positionTier: 0`；Equatable 测试的 `a`/`b` 两行同补。）

然后在同文件追加 tier 测试 suite：

```swift
@Suite("TrainingTopBarContent 仓位 X/5")
struct TrainingTopBarPositionTierTests {
    @Test("空仓 → 仓位 0/5")
    func tierZero() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0, positionTier: 0)
        #expect(c.position == "仓位 0/5")
    }

    @Test("3/5 档")
    func tierThree() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0, positionTier: 3)
        #expect(c.position == "仓位 3/5")
    }

    @Test("满仓 → 仓位 5/5")
    func tierFive() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0, positionTier: 5)
        #expect(c.position == "仓位 5/5")
    }
}
```

- [ ] **Step 2: 跑测试验证失败**

Run: `cd ios/Contracts && swift test --filter TrainingTopBar`
Expected: 编译失败（`extra argument 'positionTier'` 或 `value of type 'TrainingTopBarContent' has no member 'position'`）。

- [ ] **Step 3: 写最小实现**

`TrainingTopBarContent.swift`：(1) 改决议注释 D8 行；(2) 加 `position` 字段 + init 参数。

把文件顶部决议注释行：
```swift
// 决议 D8：本文件不含「仓位 X/5」（PositionManager 无档位存值 + 项目拒绝臆造 tier 公式，residual U2-R3）。
```
改为：
```swift
// 决议 D8（Wave 3 顺位 7 兑现）：加「仓位 X/5」= `position`，由 engine.currentPositionTier（RFC §4.1/§4.4b
// 派生公式 = round(持仓市值/当前总资金×5)，clamp 0...5）格式化；不在本壳臆造公式（顺位 6 accessor 已钉死）。
```

把 struct 体改为（加 `position` 字段 + init 参数 + 赋值）：
```swift
public struct TrainingTopBarContent: Equatable, Sendable {
    public let totalCapital: String   // "¥ 102,345.67"
    public let holdingCost: String    // "¥ 0.00"
    public let position: String       // "仓位 3/5"（Wave 3 顺位 7）
    public let returnRate: String     // "+2.34%" / "-8.32%" / "+0.00%"

    public init(totalCapital: Double, holdingCost: Double, returnRate: Double, positionTier: Int) {
        self.totalCapital = Self.currency(totalCapital)
        self.holdingCost = Self.currency(holdingCost)
        self.position = "仓位 \(positionTier)/5"
        self.returnRate = Self.percent(returnRate)
    }
    // currency / percent 静态方法保持不变。
}
```

> 注：`positionTier` 入参口径已由 `engine.currentPositionTier` 保证 0...5（clamp + 非有限守卫，6a）；本壳不再 clamp（单一真值源），直接插值。

- [ ] **Step 4: 跑测试验证通过**

Run: `cd ios/Contracts && swift test --filter TrainingTopBar`
Expected: 既有 currency/percent 测试 + 3 个新 tier 测试全 ✔，`0 failures`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift
git commit -m "feat(pr7): TrainingTopBarContent 加「仓位 X/5」（RFC §4.1/§4.4b 显示，兑现 D8）"
```

---

## Task 3：`TrainingView` 壳接线（Catalyst 编译守护，不 host 测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`

> **验证方式（重要）：** 本文件全部在 `#if canImport(UIKit)` 内，macOS host（AppKit）**不编译**，仅 Mac Catalyst 编译。故 Task 3 **无 host 单测**，靠 (a) `swift test` 不回归（壳被排除，不影响 908 基线）+ (b) **Mac Catalyst build-for-testing 编译通过**（本地 + CI）+ (c) 运行时 runbook（Task 4，手动）。纯值决策已在 Task 1/2 host 测覆盖。

- [ ] **Step 1: 顶栏接线「仓位 X/5」**

`topBar` 计算属性内，把 `TrainingTopBarContent(...)` 构造加 `positionTier:` 参数，并在 HStack 插入 `Text(bar.position)`（紧邻持仓成本之后、收益率之前，对齐 plan v1.5 L905 顶栏布局顺序）：

```swift
private var topBar: some View {
    let bar = TrainingTopBarContent(totalCapital: engine.currentTotalCapital,   // D5：保持实时总资金（§4.2）
                                    holdingCost: engine.holdingCost,
                                    returnRate: engine.returnRate,
                                    positionTier: engine.currentPositionTier)   // 顺位 7：仓位 X/5
    return HStack(spacing: 12) {
        Button("返回") { Task { try? await lifecycle.back(); onExit() } }
        Spacer()
        Text(bar.totalCapital)
        Text("持仓成本\(bar.holdingCost)")
        Text(bar.position)        // 仓位 X/5（plan v1.5 L905 布局序）
        Text(bar.returnRate)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .font(.callout)
}
```

- [ ] **Step 2: 加 Toast + 触觉 state 与执行私有方法**

在 struct 顶部 `@State` 区加：
```swift
@State private var toastMessage: String?
@State private var toastToken = 0          // latest-wins 自动消失（防旧 timer 清掉新 Toast）
@State private var confirmingEnd = false    // 「结束本局」确认弹窗
```

加执行私有方法（壳只执行，不决策）：
```swift
// 交易动作执行：调 engine.buy/sell → TradeFeedback（纯值决策）→ 触觉/Toast（壳执行）。
private func performTrade(_ action: PickerRequest.Action, panel: PanelId, tier: PositionTier) {
    let result: Result<TradeOperation, AppError>
    switch action {
    case .buy:  result = engine.buy(panel: panel, tier: tier)
    case .sell: result = engine.sell(panel: panel, tier: tier)
    }
    let feedback = TradeFeedback(result: result)
    if feedback.firesHaptic {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()   // D2：仅成功（plan §6.2.4）
    }
    if let message = feedback.toastMessage {
        presentToast(message)
    }
}

// latest-wins 自动消失 Toast（壳层 UX，不 host 测）。
private func presentToast(_ message: String) {
    toastToken += 1
    let token = toastToken
    toastMessage = message
    Task {
        try? await Task.sleep(for: .seconds(2))
        if toastToken == token { toastMessage = nil }
    }
}

// 手动结束（plan §6.2.2 / RFC §4.4a）：强平 + settlement-safe 自检（engine）→ 安全则复用 runFinalize（D3）。
// 返 false（Review/disabled/非有限财务量安全降级）→ no-op 不路由。didFinalize 置位防重入。
// `!didFinalize` 守卫**先于** forceCloseManually（auto-end 已结算后 no-op 早返，不再触 engine；虽 forceClose 幂等仍更干净）。
private func endManually() {
    guard !didFinalize else { return }
    guard engine.forceCloseManually() else { return }
    didFinalize = true
    runFinalize()
}
```

- [ ] **Step 3: picker onPick 改走 `performTrade`**

把 `.sheet(item: $pickerRequest)` 内 onPick 的两行 `_ = engine.buy/sell` 替换为：
```swift
onPick: { tier in
    performTrade(req.action, panel: req.panel, tier: tier)
    pickerRequest = nil
},
```

- [ ] **Step 4: body 加底部「结束本局」bottomBar + 确认弹窗 + Toast overlay**

`body` 的 VStack 末尾（`panel(.lower)` 之后）加 bottomBar；并挂确认弹窗 + Toast overlay 修饰：

```swift
public var body: some View {
    VStack(spacing: 0) {
        topBar
        panel(.upper)
        Divider()
        panel(.lower)
        if showsTradeButtons { bottomBar }      // 结束按钮 capability == canBuySell（RFC §4.4a 注；Review 不显示）
    }
    .onAppear { maybeAutoEnd() }
    .onChange(of: engine.tick.globalTickIndex) { _, _ in maybeAutoEnd() }
    .onChange(of: scenePhase) { _, newPhase in
        if newPhase == .active { engine.onSceneActivated() }
    }
    .sheet(item: $pickerRequest) { req in
        PositionPickerView(
            enabledTiers: Set(PositionTier.allCases),
            onPick: { tier in
                performTrade(req.action, panel: req.panel, tier: tier)
                pickerRequest = nil
            },
            onCancel: { pickerRequest = nil })
    }
    .confirmationDialog("结束本局训练", isPresented: $confirmingEnd, titleVisibility: .visible) {
        Button("是", role: .destructive) { endManually() }   // plan §6.2.2「是」→ 强平 + 结算
        Button("否", role: .cancel) {}                         // 「否」→ 对话框消失
    }
    .overlay(alignment: .top) {
        if let toast = toastMessage {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    .animation(.easeInOut(duration: 0.2), value: toastMessage)
    .alert("结算入账失败", isPresented: $finalizeFailed) {
        Button("重试") { runFinalize() }
        Button("放弃", role: .cancel) {
            Task { await lifecycle.endAfterSettlement(); onExit() }
        }
    } message: {
        Text("本局结果尚未写入历史记录。可重试入账，或放弃结算退出（进度保留至最近存档）。")
    }
}

// 底部「结束本局」（plan §6.2.2：屏幕底部左侧）。可见性同交易按钮（canBuySell）。
private var bottomBar: some View {
    HStack {
        Button("结束本局") { confirmingEnd = true }
            .buttonStyle(.bordered)
        Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
}
```

> 既有 `.alert("结算入账失败"…)` / `topBar` 的「返回」/ `tradeButtons` / `runFinalize` / `maybeAutoEnd` 保持原样；本 Task 只**新增** bottomBar/confirmationDialog/overlay/performTrade/presentToast/endManually，并把 topBar 与 picker onPick 两处替换。

- [ ] **Step 5: host 回归（确认壳不影响 host 基线）**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `Test run with N tests`，`N == 908 + Task1(6) + Task2(3) == 917`，`0 failures`。（壳代码 host 不编译，不影响计数；新增仅 Task1/2 的纯值测试。）

- [ ] **Step 6: Mac Catalyst 编译守护（壳真正的编译验证）**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`（`TrainingView` 壳新增的 `UIImpactFeedbackGenerator`/`confirmationDialog`/overlay 全编译链接通过）。

> 若本地无 Xcode 16 / Catalyst destination，跳过本地步骤，依赖 PR 的 `Mac Catalyst build-for-testing on macos-15` required check（CI 守护）。但**优先本地跑通 de-risk**（memory `feedback_swift_local_toolchain_blindspot`：本地绿≠CI 绿，但本地能抓多数编译错）。

- [ ] **Step 7: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "feat(pr7): U2 壳接线 — 仓位 X/5 + 结束本局手动强平 + 交易 Toast/触觉（D2/D3/D5）"
```

---

## Task 4：运行时 runbook + 非-coder 验收清单（docs）

**Files:**
- Create: `docs/runbooks/2026-06-13-wave3-pr7-trade-ui-runtime-acceptance.md`
- Create: `docs/acceptance/2026-06-13-wave3-pr7-u2-trade-ui.md`

- [ ] **Step 1: 写运行时 runbook**

`docs/runbooks/2026-06-13-wave3-pr7-trade-ui-runtime-acceptance.md`（device/sim 手动验收，顺位 13 阻塞依赖之一；含失败不 mutate/不震动断言，对齐 outline §三.3）：

```markdown
# Wave 3 顺位 7 — U2 交易 UI（仓位 X/5 + 手动强平 + Toast/触觉）运行时验收 runbook

**性质**：device/simulator **手动**验收（CI 仅 Catalyst 编译守护，不验运行时触觉/Toast/路由）。
执行者：user（操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：经顺位 10 全 app fixture provisioning（顺位 7 实施时若未落地，则用 DEBUG `.preview()` 或已有缓存训练组），
> 在 iPhone/iPad 启动 `KlineTrainer` app target，进入一局 **Normal** 训练。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | 空仓时看顶栏「仓位」 | 显示「仓位 0/5」 | pass = 0/5 |
| 2 | 买入 3/5（点买入 → 选 3/5） | (a) 触发一次 **.heavy 触觉**；(b) 顶栏「仓位」即时变为约「3/5」（容 round ±1 档）；(c) 顶栏总资金 = 实时（现金+持仓市值，§4.2） | pass = 触觉 + 仓位更新 + 总资金实时 |
| 3 | 满仓后（5/5）再点买入 | 买入按钮**灰置不可点**（不弹 HUD、无 Toast、无触觉） | pass = 按钮 disabled |
| 4 | 构造资金不足档位买入（若可点到使股数取整为 0 的档） | 弹 **Toast「可用资金不足」**；**无触觉**；持仓/资金/tick **不变**（失败不 mutate） | pass = Toast 可见 + 不震动 + 状态不变 |
| 5 | 空仓点卖出 | 卖出按钮**灰置不可点** | pass = 按钮 disabled |
| 6 | 卖出成功 | 触发 **.heavy 触觉**；仓位档位下降；总资金实时更新 | pass = 触觉 + 仓位降 |
| 7 | 点底部左侧「结束本局」→ 弹确认「结束本局训练」→ 点「否」 | 对话框消失；**仍在本局**（无强平、无结算、状态不变） | pass = 取消不路由 |
| 8 | 再点「结束本局」→「是」（有持仓） | 若有持仓按当前收盘价强制平仓 → 弹 **结算窗**（显示 total_capital 冻结值）→ 确认回首页，按钮变「继续训练」消失（已入账） | pass = 强平 + 结算 + 入账 |
| 9 | Replay 模式重复 step 8 | 手动结束触发（本顺位 7 replay 仍走 retreat 回首页，**不**显示结算窗——结算窗归顺位 8）；记录数/统计**不变** | pass = retreat + 不入账（顺位 8 再补结算窗） |
| 10 | Review 模式看底部 | **无「结束本局」按钮**（capability matrix「结束按钮 Review ❌」，用返回退出）；无交易按钮 | pass = 无结束/交易按钮 |

**回填**：执行后逐行填 pass/fail。本 runbook 作 Wave 3 新交互运行时矩阵一项，是顺位 13 收尾阻塞依赖之一（spec §三.3）。
失败可见性（step 4）+ 触觉（step 2/6）+ 手动结束路由（step 8）是本顺位核心运行时断言。
```

- [ ] **Step 2: 写非-coder 验收清单**

`docs/acceptance/2026-06-13-wave3-pr7-u2-trade-ui.md`：

```markdown
# 验收清单 — Wave 3 顺位 7：U2 交易 UI 接线 + 交易反馈

**交付物：** 顶栏「仓位 X/5」+ 底部「结束本局」手动强平（确认弹窗 → 路由结算）+ 交易失败 Toast + 成功 .heavy 触觉。
纯值层 `TradeFeedback` + `TrainingTopBarContent.position`（host 测）；`TrainingView` 壳接线（Catalyst 编译守护）。
engine/schema/持久化 **0 改动**（6a + RFC 契约消费）。

**前置：** 在 `ios/Contracts` 目录执行命令；macOS 装 Swift 6 工具链。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | `swift test --filter TradeFeedback` | `Test run with 6 tests ... 0 failures`；6 个 TradeFeedback 测试全 ✔（成功触觉 / 资金不足·持仓不足·股数非法 Toast / disabled 抑制） | 6 ✔ 且 0 failures = 通过 |
| 2 | `swift test --filter TrainingTopBar` | 既有 currency/percent 测试 + 3 个新「仓位 X/5」测试（0/5、3/5、5/5）全 ✔，`0 failures` | 全 ✔ 且 0 failures = 通过 |
| 3 | `swift test`（全量回归） | `Test run with 917 tests`（基线 908 + 新增 9），`0 failures` | 917 且 0 failures = 通过 |
| 4 | 阅读 `git diff origin/main -- ios/Contracts/Sources` | 仅 `TradeFeedback.swift`（新）、`TrainingTopBarContent.swift`、`TrainingView.swift` 被改；**无** `TrainingEngine.swift` / `*.sql` / schema / `CONTRACT_VERSION` / coordinator 改动 | 改动文件集 ⊆ {TradeFeedback, TrainingTopBarContent, TrainingView} 且无 engine/schema = 通过 |
| 5 | 阅读 `TrainingView.swift` topBar | `TrainingTopBarContent(...)` 第一参数仍为 `engine.currentTotalCapital`（§4.2 实时总资金未回归）；新增 `positionTier: engine.currentPositionTier` | 总资金参数 = currentTotalCapital 且 tier 接 currentPositionTier = 通过 |
| 6 | Mac Catalyst CI（PR 上 `Mac Catalyst build-for-testing on macos-15`） | required check 状态 = success（壳 UIImpactFeedbackGenerator/confirmationDialog/overlay 编译链接通过） | check = success = 通过 |
| 7 | 运行时 runbook（`docs/runbooks/2026-06-13-wave3-pr7-trade-ui-runtime-acceptance.md`） | user 在 device/sim 逐行执行回填 pass（仓位实时 / Toast 可见 / 触觉 / 手动结束→结算 / 失败不 mutate） | 10 行 runbook 回填 = 顺位 13 阻塞项（本 PR 交付 runbook 文件即可，实测回填随运行时矩阵） |

**证据上传：** PR comment 附命令 #1–#3 尾部输出（含 `Test run with ... 0 failures`）+ #4 diff 文件清单 + CI check 链接。
```

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/2026-06-13-wave3-pr7-trade-ui-runtime-acceptance.md \
        docs/acceptance/2026-06-13-wave3-pr7-u2-trade-ui.md
git commit -m "docs(pr7): 运行时 runbook + 非-coder 验收清单"
```

---

## Self-Review（spec 覆盖核对）

| spec 需求 | 实现任务 |
|---|---|
| 顶栏「仓位 X/5」（RFC §4.1/§4.4b，plan L916） | Task 2（纯值）+ Task 3 Step 1（壳接线） |
| 底部「结束本局」手动强平 + 确认弹窗 + 路由结算（RFC §4.4a，plan §6.2.2） | Task 3 Step 2/4（`endManually` + bottomBar + confirmationDialog，复用 runFinalize） |
| 交易失败 Toast（资金不足/持仓不足，plan L735/736） | Task 1（`TradeFeedback` 决策）+ Task 3 Step 2/3/4（presentToast + overlay） |
| 成功 .heavy 触觉（Normal/Replay；Review 无，plan L841/§6.2.4） | Task 1（firesHaptic）+ Task 3 Step 2（UIImpactFeedbackGenerator）；Review 由 showsTradeButtons 自然抑制 |
| §4.2 顶栏实时 / 结算冻结总资金语义 | Task 3 Step 1（保持 currentTotalCapital）+ Task 4 acceptance #5 断言 |
| 运行时 runbook 条目（outline §三.3 顺位 13 阻塞） | Task 4 Step 1 |
| 失败不 mutate / 不震动断言（runbook） | Task 4 Step 1 runbook step 4 |

**Placeholder 扫描：** 无 TBD/TODO；每 code step 给完整代码。
**类型一致性：** `TradeFeedback(result:)` 泛型 init 在 Task 1 定义、Task 3 调用一致；`position`（String）/ `positionTier`（Int 入参）命名 Task 2 定义、Task 3 使用一致；`performTrade`/`presentToast`/`endManually`/`bottomBar` 在 Task 3 内自洽。

---

## Execution Handoff

执行用 **subagent-driven-development**（每 task 独立 subagent + 两道评审），4 个 task 串行（Task 3 依赖 Task 1/2 的纯值符号；Task 4 纯 doc 可并行但顺序执行更稳）。
