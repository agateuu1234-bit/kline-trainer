# PR U5 — PositionPickerView 仓位选择 HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec §6.2.4 + modules §U5 字面要求的 SwiftUI 仓位选择 HUD（`struct PositionPickerView: View` 含 `init(enabledTiers: Set<PositionTier>, onPick: (PositionTier) -> Void, onCancel: () -> Void)`），渲染 5 档位横排按钮（"1/5".."5/5"）按 enabledTiers 启用/灰置 + 取消按钮 —— Wave 1 顺位 14 / 第 16 个 PR per outline v20。

**Architecture:** **平台无关的纯值类型 `PositionPickerContent`**（host 全测的 5 元素有序数组 `[Item]`：`tier` / `label` / `enabled`，强制 tier1→tier5 升序）+ **薄 SwiftUI shell `PositionPickerView`**（body 消费 `PositionPickerContent`，仅做 VStack/HStack/Button 装配 + `.disabled(!enabled)` 控制 + 单 tap fire onPick；无业务逻辑、无 Set 迭代）。此双层架构与 U3 SettlementView 同款：纯函数层 host swift test 真断言 + 渲染薄层由 Mac Catalyst build-for-testing SUCCEEDED 编译闸门守护。modules §U5 字面 `init(enabledTiers:onPick:onCancel:)` 不增不减；onPick / onCancel 触发后由 caller（E5/U2 Wave 2）处理 sheet dismiss + 真实交易，本 PR 只触发回调。

**Tech Stack:** Swift 6.0 / Swift Testing (`import Testing` + `@Test` + `#expect`) / Foundation / SwiftUI (跨 iOS 17 + macOS 14 + Mac Catalyst) / 已冻结模块：`PositionTier`（Models.swift L25-30，5 case CaseIterable，rawValue = "1/5".."5/5"）。

**Spec source:** `kline_trainer_plan_v1.5.md` §6.2.4 (L946-952) + `kline_trainer_modules_v1.4.md` §U5 (L2084-2092)。

**Constraint reminders (per Wave 1 outline v20 §3.2 + memory `feedback_planner_packaging_bias`):**
- ≤ 3 sub-items (this plan: 3 Tasks)
- ≤ 500 行 prod (this plan: ~200 行 prod estimate per outline 顺位 14 "UI 壳 ~200 行 SwiftUI HUD")
- review budget: opus 4.7 xhigh 双闸门各 4-5 轮内收敛（user 本次显式指定走 opus 不走 codex）
- `cd ios/Contracts && swift test` 是 macOS host 命令；Mac Catalyst 用 `xcodebuild ... build-for-testing`（§15.1 #3 闸门）
- Working branch: `worktree-pr-u5-position-picker-view`（执行阶段由 `using-git-worktrees` 创建）

---

## 背景与既有接缝（实施者必读）

- **PositionTier 形状已冻结**（`ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` L25-30，**5 case + CaseIterable + Sendable**，本 PR **不动该文件**）：
  - `tier1 = "1/5"` / `tier2 = "2/5"` / `tier3 = "3/5"` / `tier4 = "4/5"` / `tier5 = "5/5"`
  - `enum PositionTier: String, Codable, Equatable, Sendable, CaseIterable`
  - **`PositionTier.allCases` 顺序 = source-order = tier1, tier2, tier3, tier4, tier5**（Swift enum 语义：CaseIterable 合成的 allCases 严格按 case 声明顺序，非字典序）
- **`Set<PositionTier>` 迭代顺序非确定**：`Set` 是 hash-based，迭代顺序不稳定 → 纯函数 `PositionPickerContent.init(enabledTiers:)` **必须迭代 `PositionTier.allCases`**（按 enum 定义顺序）然后 `enabledTiers.contains(tier)` 判定，不能反向迭代 enabledTiers。
- **SwiftUI 跨平台可用**：`ios/Contracts/Package.swift` 已声明 `.iOS(.v17), .macOS(.v14)`，SwiftUI 在两个 platform + Mac Catalyst 均可 `import SwiftUI`（不需要 `#if canImport(UIKit)` 守卫）。
- **现有 UI/ 目录已存在**（PR #70 U3 落地）：`ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` + `SettlementView.swift`。本 PR 在同目录新增 2 个 swift 文件（`PositionPickerContent.swift` + `PositionPickerView.swift`），不动 U3 现有文件。
- **测试基线**：当前 **519 tests / 100 suites**（macOS host `swift test`，PR #70 merge 后 + memory 实测 519/100）。本 PR 目标 **+10 host 测试**（Task 1 = 10 = PositionPickerContentTests 一个 suite）→ **共 +10 / 总 ≥529 / ≥101 suites**。**baseline 走宽松正则锚**（per `plan_u3_settlement_view.sh` 既定 mode）：grep `"Test run with [0-9]+ tests? in [0-9]+ suites? passed"` 不硬锁 N；§B.2 / §D.1 prose "N≥529 / M≥101" 仅给人读，验收 gate 不硬锁。Task 2 = SwiftUI shell 仅编译验证，**0 新测试**（参 U3/C5/C6 mode）。Task 3 = 验收 doc/script，0 新测试。
- **不依赖 Wave 0/1 任何运行时单例**：PositionPickerView 是纯展示组件，仅依赖 `PositionTier`（已冻 Wave 0 F1）。**不依赖 E2 PositionManager runtime code**（outline v20 顺位 14 row 标 "依赖 E2" 是指**语义依赖**：caller 由 PositionManager state 推导 `enabledTiers`；本 PR 不引 import）。

---

## Task 0 — §15.3 评审策略前置 + spec 偏差裁决

per `docs/governance/wave1-plan-template.md`：本 plan 使用哪些评审形式。

- [ ] **局部对抗性评审（必）**：本 plan U5 scope 内 **Claude Opus 4.7 xhigh effort 双闸门**（plan-stage + impl-stage / branch-diff），**不走 codex**（per memory `feedback_openai_quota_ci_pattern` + 用户本次显式 prompt）。4-5 轮内收敛或 escalate（per memory `feedback_codex_plan_budget_overshoot` 同样适用于 opus xhigh review）。
- [x] **集成层评审（N/A）**：C8 `ChartContainerView` 桥接 + E5 编排在 Wave 2；本 PR 不含集成层。U5 是叶子组件，无下游被桥接 surface。
- [x] **性能评审（N/A）**：plan v1.5 §一 "单帧 <4ms / Instruments" 属 **Phase 5 磨光 PR**；U5 是一次性渲染的小窗口（无 60Hz 渲染路径），本 PR 不做 Instruments 评审。

### Step ↔ Skill 显式映射（per memory `feedback_workflow_skill_invoke_explicit` —— PR #67 教训第 5 次复现预防）

本 PR 实施序列对应的 Superpowers skill：

| 阶段 | Skill | 何时调 | 何时**不**用 raw Agent 替代 |
|---|---|---|---|
| Plan-stage adversarial review | （主线 dispatch fresh opus 4.7 xhigh subagent，无对应 skill 名；按 `adversarial-review-template.md` 给 prompt） | plan 写完后、Task 1 开工前 | 主线必须 dispatch 新 agent；不能在主线自审 |
| Task 1-2 实施 | `superpowers:subagent-driven-development` | 每 Task fresh sonnet 4.6 high subagent + paired sonnet reviewer | 不用 raw Agent；不在主线自写 |
| Verification | `superpowers:verification-before-completion` | Task 3 acceptance script 跑完前最终验证 | 不在主线自宣"绿了" |
| Self-review | `superpowers:requesting-code-review` | 整体 branch-diff review 前 | 不跳 |
| Branch-diff adversarial review | （主线 dispatch fresh opus 4.7 xhigh subagent）| 全部实施完 + self-review 后 + push PR 前 | 主线必须 dispatch 新 agent |

完成 Task 0 才进 Task 1 实施（仅"局部对抗性评审"项为可执行待办，2 项 N/A 已预勾声明）。

### Spec 偏差裁决（D1-D16，全部写进代码注释 + 验收 §J）

| # | 偏差/歧义 | 裁决 | 权威依据 |
|---|---|---|---|
| **D1** | 落到 SwiftUI 还是 UIKit | **SwiftUI**：modules §U5 L2087 字面 `struct PositionPickerView: View` → SwiftUI；SwiftUI 跨 iOS 17+ macOS 14+ Catalyst 三平台原生支持，**不**加 `#if canImport(UIKit)` 守卫。 | modules §U5 L2087 字面 + Package.swift platforms 声明 |
| **D2** | 5 档位排列方向 | **HStack 横向**：plan v1.5 §6.2.4 L949 ASCII `[ 1/5 ]  [ 2/5 ]  [ 3/5 ]  [ 4/5 ]  [ 5/5 ]` 字面横排。 | spec L949 字面 |
| **D3** | 按钮 label 文案 | **= `PositionTier.rawValue`**（"1/5" / "2/5" / "3/5" / "4/5" / "5/5"）。spec L949 ASCII 方括号 `[ ]` 是按钮**框**示意，文案是 `X/5` 字面与 Models.swift L26-30 raw value 一致。 | spec L949 字面 + Models.swift L25-30 字面 |
| **D4** | 5 档位渲染顺序 | **强制 tier1 → tier5 升序**（PositionTier.allCases 顺序 = enum 源码定义顺序，Swift CaseIterable 语义保证）。Content init 迭代 `PositionTier.allCases`（非 enabledTiers 迭代），杜绝 Set 迭代顺序不稳定污染。 | spec L949 字面 + Swift CaseIterable 语义 |
| **D5** | `enabledTiers` 空集合 | **全 5 按钮 disabled，取消按钮仍可用**；不抛错、不 fallback 默认值。caller 责任（buy/sell 触发时确保至少 1 档可用——但 U5 不预判 caller 状态）。 | modules §U5 L2088 字面 `Set<PositionTier>`（Set 允许空）+ caller-derived 语义 |
| **D6** | 取消按钮（modules §U5 init 含 `onCancel` 但 spec §6.2.4 L946-952 ASCII 仅画 5-tier 行） | **加显式独立"取消"按钮**于 5-tier 行下方。理由：modules §U5 init 字面要求 `onCancel: () -> Void` callback → View 必须有触发器；纯依赖 caller-installed sheet dismiss / overlay tap 无法保证（caller 可能用 popover / 自定义 overlay 不带 sheet 语义），违反 View 自包含原则。spec ASCII 仅画 5 tier 是**显示样例**非全 body 字面规范，加最简取消按钮是补完 init 契约必需，不是 over-engineering。 | modules §U5 L2090 字面 + View 自包含原则 |
| **D7** | 标题文案 | **"仓位选择"**（plan v1.5 L946 字面 "**仓位选择 HUD：**"，去掉技术词"HUD"取核心 wording 作 user-facing 标题）。 | spec L946 字面 |
| **D8** | 已选中态高亮 | **不实现**：spec L952 字面"点击某档位后确认交易，面板消失" → 单 tap 即提交，无 selected-then-confirm 中间态；按钮 visual 仅 enabled / disabled 两态。SwiftUI Button 默认 style 已提供 tap 反馈，无需额外高亮。 | spec L952 字面 + CLAUDE.md §2 Simplicity |
| **D9** | Preview Fixture：是否新增 `PositionTier.preview()` 公共 fixture | **`fileprivate extension PositionTier`** 内联 `PositionPickerView.swift` 的 `#if DEBUG` 区块：`fileprivate extension PositionTier { static func previewEnabledTiers() -> Set<PositionTier> { [.tier1, .tier2, .tier3] } }`；不动 `PreviewFakes/InMemoryFakes.swift`，不新建公共 fixture 文件。**机制选 `fileprivate extension PositionTier` 与 U3 D9 严格同款**（U3 用 `fileprivate extension TrainingRecord { static func preview() }`），使 §H.4 / G8 反向 grep `^public.*extension PositionTier` 在本 prod 文件**真有**目标可禁。理由：CLAUDE.md §2 "no abstractions for single-use code" + memory `feedback_planner_packaging_bias` + U3 D9 + R1-H4 fileprivate 防跨模块污染。 | CLAUDE.md §2 + U3 D9 严格同款机制 |
| **D10** | SwiftUI shell 是否单元测试 | **不单测**，只跑 Mac Catalyst build-for-testing SUCCEEDED 闸门（含 macOS host swift test 与 iOS Catalyst 两套编译）+ visual preview。理由：SwiftUI 内部断言要 ViewInspector / 类似第三方库，引入新 SwiftPM 依赖 vs **零业务逻辑 view 单测收益极低**；所有可测逻辑全在 `PositionPickerContent`（Task 1，host 全测）。参 U3/C5/C6 mode。 | U3/C5/C6 既定 mode + CLAUDE.md §2 |
| **D11** | spec §U5 L2089-2090 字面 `onPick: (PositionTier) -> Void` / `onCancel: () -> Void` vs 落地 `@escaping` | **落地必须 `@escaping`**：SwiftUI `View` init 把 closure 存为 `private let` 然后在 body Button 间接调用 → Swift 编译要求 store-and-defer-call 的 closure 形参必须 `@escaping`。spec L2089-2090 闭包类型形态是契约（caller 视角可调用性）；落地附加 `@escaping` 是 Swift 闭包逃逸语义的强制要求，不改变契约形状。**不加 `@Sendable`**（U3 同款，闭包随 SwiftUI `View` 协议合成 `@MainActor` 隔离运行，不跨 actor 边界；加 `@Sendable` 会过度收紧 caller 闭包形状）。 | spec L2089-L2090 字面 + Swift 编译约束 + U3 D12 同款 |
| **D12** | Content 数据结构 shape | **`PositionPickerContent` 内一个 `tiers: [Item]` 数组（恒 5 元素）**，`Item` 含 `tier: PositionTier` / `label: String` / `enabled: Bool`。**用数组（保持顺序）不用 Set / Dictionary**；`Item` 是 `public` `struct`（不是 tuple），便于 Equatable / Sendable conformance + 显式字段名。 | Swift 类型设计 + D4 顺序硬约束 |
| **D13** | `enabledTiers` 是 init 值快照 vs 引用持续观察 | **值快照**：View 初始化时一次性把 Set 翻译成 Content（init body 内 `self.content = PositionPickerContent(enabledTiers: enabledTiers)`）；caller 不变更（spec 没有"动态启停档位"语义）。`PositionPickerContent` 是 `Sendable` + `Equatable` 值类型保证此约束。 | spec §6.2.4 字面 + Sendable 语义 |
| **D14** | 不依赖 E2 PositionManager runtime | **本 PR 不 import E2 任何 prod 类型 / 函数**；outline v20 顺位 14 row 标"依赖 E2"是**语义依赖**（caller 由 PositionManager state 推导 `enabledTiers` 集合），不是代码依赖。grep `PositionManager` 在 U5 prod 文件应为 0 命中。 | outline v20 §二 + 叶子组件硬约束 |
| **D15** | 按钮 hit 立即 fire onPick（不需二次确认） | **直接 fire**：spec L952 字面"点击某档位后确认交易，面板消失" → tap = commit。View body Button(action: { onPick(tier) }) 直接调用。本 View **不**调 `dismiss` / 不操控 sheet 状态 —— 面板消失由 caller-installed presentation container 负责。 | spec L952 字面 |
| **D16** | 按钮颜色 / RGB 硬编码 | **不实现盈亏色 / RGB 硬编码**：默认 SwiftUI Button style（系统 accent + disabled 灰）；spec §6.2.4 不规定按钮颜色。同 U3 D2 simplicity 原则。 | spec §6.2.4 字面 + CLAUDE.md §2 |

---

## File Structure

### Production (2 files, ~200 行)

| 路径 | 动作 | 行数 | 职责 |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | **新建** | ~60 | 纯值类型 `public struct PositionPickerContent: Equatable, Sendable`，含 `tiers: [Item]` 5 元素 + `init(enabledTiers: Set<PositionTier>)`；嵌套 `public struct Item: Equatable, Sendable` 含 `tier: PositionTier` / `label: String` / `enabled: Bool`。**平台无关**：仅 `import Foundation`（不 import SwiftUI / UIKit / CoreGraphics）。 |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | **新建** | ~140 | SwiftUI shell `public struct PositionPickerView: View`，`init(enabledTiers: Set<PositionTier>, onPick: @escaping (PositionTier) -> Void, onCancel: @escaping () -> Void)`，body 用 `PositionPickerContent(enabledTiers:)` 拿 5 Item 渲染 HStack of Button + 下方"取消" Button；DEBUG-only `#Preview` macro + fileprivate fixture。 |

### Tests (1 file, ~180 行)

| 路径 | 动作 | 行数 | 测试 |
|---|---|---|---|
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift` | **新建** | ~180 | 10 host 测试覆盖：order 5 tests / enabled flag 3 tests / labels 1 test / Equatable+Sendable 1 test。详见 Task 1 Step 1。 |

### Docs (1 file)

| 路径 | 动作 | 内容 |
|---|---|---|
| `docs/acceptance/2026-05-28-pr-u5-position-picker-view.md` | **新建** | ~130 行中文非程序员验收清单（10 节 §A-§J 含字面 grep / suite count / Catalyst build / 文件存在 / RGB 反向 grep / 决议落地） |

### Scripts (1 file)

| 路径 | 动作 | 内容 |
|---|---|---|
| `scripts/acceptance/plan_u5_position_picker_view.sh` | **新建** | 机检 bash：与 acceptance §A-§J 对齐的 ≥12 项 grep / test / build 自动跑（参 `plan_u3_settlement_view.sh` 同款）。 |

**Total: 2 prod + 1 test + 1 doc + 1 script = 5 文件 / ~200 prod / ~180 test / 10 新测试。**

---

## Task 1 — `PositionPickerContent` 纯值类型 + 10 host 测试

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift`

- [ ] **Step 1: 写失败测试 — `PositionPickerContentTests.swift`**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift
// Spec: kline_trainer_plan_v1.5.md §6.2.4 L946-952 + plan 2026-05-28-pr-u5-position-picker-view.md Task 1
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("PositionPickerContent host tests")
struct PositionPickerContentTests {

    // MARK: - D4 order: 5 元素严格 tier1→tier5 升序

    @Test("D4 全启用时 5 个 item 顺序 tier1→tier5")
    func allEnabledOrderIsTier1ToTier5() {
        let c = PositionPickerContent(enabledTiers: Set(PositionTier.allCases))
        #expect(c.tiers.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
    }

    @Test("D4 全 disabled 时（empty Set）顺序仍 tier1→tier5")
    func allDisabledStillOrdered() {
        let c = PositionPickerContent(enabledTiers: [])
        #expect(c.tiers.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
    }

    @Test("D4 部分启用（tier3+tier1）顺序仍 tier1→tier5（Set 迭代顺序不污染）")
    func partialEnabledRespectsTierOrder() {
        // 故意按反序 / 跳序构造 enabledTiers，强制证明 Content 顺序来自 PositionTier.allCases 非 Set 迭代
        let c = PositionPickerContent(enabledTiers: [.tier3, .tier1])
        #expect(c.tiers.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
    }

    @Test("tiers 数组恒 5 元素")
    func alwaysFiveItems() {
        #expect(PositionPickerContent(enabledTiers: []).tiers.count == 5)
        #expect(PositionPickerContent(enabledTiers: Set(PositionTier.allCases)).tiers.count == 5)
        #expect(PositionPickerContent(enabledTiers: [.tier1]).tiers.count == 5)
    }

    // MARK: - D5 enabled flag 映射

    @Test("D5 enabledTiers 空 → 5 个 item 全 disabled")
    func emptyEnabledTiersAllDisabled() {
        let c = PositionPickerContent(enabledTiers: [])
        #expect(c.tiers.map(\.enabled) == [false, false, false, false, false])
    }

    @Test("D5 enabledTiers 全 → 5 个 item 全 enabled")
    func fullEnabledTiersAllEnabled() {
        let c = PositionPickerContent(enabledTiers: Set(PositionTier.allCases))
        #expect(c.tiers.map(\.enabled) == [true, true, true, true, true])
    }

    @Test("D5 部分启用 [tier1, tier3] → enabled = [T,F,T,F,F]")
    func partialEnabledFlagsCorrect() {
        let c = PositionPickerContent(enabledTiers: [.tier1, .tier3])
        #expect(c.tiers.map(\.enabled) == [true, false, true, false, false])
    }

    // MARK: - D3 labels = rawValue

    @Test("D3 labels = '1/5'..'5/5' = PositionTier.rawValue（spec L949 字面）")
    func labelsMatchRawValues() {
        let c = PositionPickerContent(enabledTiers: Set(PositionTier.allCases))
        #expect(c.tiers.map(\.label) == ["1/5", "2/5", "3/5", "4/5", "5/5"])
    }

    // MARK: - Equatable + Sendable + determinism

    @Test("Content + Item 是 Equatable / Sendable（同输入恒等输出）")
    func equatableAndSendableAndDeterministic() {
        let c1 = PositionPickerContent(enabledTiers: [.tier1, .tier3])
        let c2 = PositionPickerContent(enabledTiers: [.tier3, .tier1]) // 故意反序构造
        #expect(c1 == c2)
        let _: any Sendable = c1
        let _: any Sendable = c1.tiers.first!
    }

    @Test("PositionTier.allCases 长度恒 5（D4 隐约束验证）")
    func positionTierAllCasesLengthIsFive() {
        #expect(PositionTier.allCases.count == 5)
    }
}
```

- [ ] **Step 2: 跑测试确认全 fail（编译错或测试 fail —— 关键是 exit ≠ 0）**

Run:
```bash
cd ios/Contracts
swift test --filter PositionPickerContentTests > /tmp/u5-red.txt 2>&1
echo "exit=$?"
grep -iE "error:|cannot find|undeclared" /tmp/u5-red.txt | head -3
```
Expected: `exit=` 非 0 + 至少 1 行 error / cannot find / undeclared 命中。**用 exit code 不依赖 wording**（同 U3 R1-M4 教训）。

- [ ] **Step 3: 写最小实现 — `PositionPickerContent.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
// Spec: kline_trainer_plan_v1.5.md §6.2.4 L946-952 + plan 2026-05-28-pr-u5-position-picker-view.md
//
// 平台无关纯值类型：把 enabledTiers: Set<PositionTier> 翻译成 SwiftUI 渲染用的 5 元素有序数组。
// 平台守卫：仅 import Foundation，不 import SwiftUI/UIKit/CoreGraphics —— host swift test 全测。
//
// 决议（D3-D5/D12/D13）：
// - D3 label = PositionTier.rawValue（"1/5".."5/5"）
// - D4 强制 tier1→tier5 升序（迭代 PositionTier.allCases，杜绝 Set 迭代不确定性）
// - D5 enabledTiers.contains(tier) 决定 enabled flag；空 Set → 全 false
// - D12 tiers 是 [Item] 数组（保持顺序）；Item 是 struct（不是 tuple）便于 Equatable/Sendable
// - D13 值类型快照：init 时一次性算 Content；不持引用观察 Set 变更

import Foundation

public struct PositionPickerContent: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let tier: PositionTier
        public let label: String
        public let enabled: Bool

        public init(tier: PositionTier, label: String, enabled: Bool) {
            self.tier = tier
            self.label = label
            self.enabled = enabled
        }
    }

    public let tiers: [Item]

    public init(enabledTiers: Set<PositionTier>) {
        // D4: 迭代 PositionTier.allCases（enum 源码顺序 = tier1..tier5），不迭代 enabledTiers。
        self.tiers = PositionTier.allCases.map { tier in
            Item(tier: tier, label: tier.rawValue, enabled: enabledTiers.contains(tier))
        }
    }
}
```

- [ ] **Step 4: 跑测试确认 10 全绿**

Run: `cd ios/Contracts && swift test --filter PositionPickerContentTests 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中模式 `Test run with N tests in M suites passed after X seconds.`（**宽松正则锚**不硬锁 N=10/M=1；语义检验 N≥10，M=1）。

加成 strong gate：跑 `swift test` 退出码 == 0：
```bash
cd ios/Contracts && swift test --filter PositionPickerContentTests > /tmp/u5-green.txt 2>&1
echo "exit=$?"
```
Expected: `exit=0`。

如某测试 fail，按测试失败信息修代码（不动测试断言），重跑直到全绿；不能修改测试断言来对齐错误实现。

- [ ] **Step 5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift
git commit -m "feat(u5): PositionPickerContent 纯值类型 + 10 host 测试 (Task 1)

Spec §6.2.4 L946-952 字面对齐：5 档位强制 tier1→tier5 升序（迭代 allCases，
非 Set）/ label = rawValue / enabledTiers.contains 决定 enabled flag。
本 PR scope 仅纯函数 + 测试，SwiftUI shell 在 Task 2 落地。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 — `PositionPickerView` SwiftUI shell + DEBUG preview fixture

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift`

> 本 Task 不加新测试（per D10）；Mac Catalyst build-for-testing SUCCEEDED 是编译闸门。

- [ ] **Step 1: 写实现 — `PositionPickerView.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
// Spec: kline_trainer_modules_v1.4.md §U5 L2084-2092 字面 init 签名 +
//       kline_trainer_plan_v1.5.md §6.2.4 L946-952 ASCII 布局
//
// 薄 SwiftUI shell：body 仅装配 VStack/HStack/Button；所有数据映射交 PositionPickerContent（Task 1）。
//
// 决议（D1/D2/D6-D11/D14-D16）：
// - D1 SwiftUI 跨 iOS17/macOS14/Catalyst 三平台原生支持，不加 #if canImport(UIKit)
// - D2 HStack 横向 5 按钮
// - D6 5-tier 行下方加显式"取消"按钮触发 onCancel（modules §U5 init 字面要求）
// - D7 标题"仓位选择"
// - D8 单 tap fire onPick，无 selected-then-confirm 中间态
// - D9 fileprivate preview fixture 内联本文件 #if DEBUG 区，不污染 PreviewFakes
// - D10 不单测 SwiftUI shell，靠 Catalyst build-for-testing 闸门
// - D11 onPick / onCancel 闭包 @escaping（Swift 编译强制）
// - D14 仅语义依赖 E2（caller 由持仓状态推导 enabledTiers）；本文件不引业务运行时类型
// - D15 Button tap 直接 fire onPick，不调 dismiss（caller 负责 presentation）
// - D16 不实现 RGB 硬编码 / 不分盈亏色，默认 SwiftUI Button style

import SwiftUI

public struct PositionPickerView: View {
    private let content: PositionPickerContent
    private let onPick: (PositionTier) -> Void
    private let onCancel: () -> Void

    public init(enabledTiers: Set<PositionTier>,
                onPick: @escaping (PositionTier) -> Void,
                onCancel: @escaping () -> Void) {
        self.content = PositionPickerContent(enabledTiers: enabledTiers)
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("仓位选择")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)

            // D2: 5 档位横向（spec L949 ASCII）
            HStack(spacing: 12) {
                ForEach(content.tiers, id: \.tier) { item in
                    Button(action: { onPick(item.tier) }) {
                        Text(item.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!item.enabled)
                }
            }

            Spacer().frame(height: 8)

            // D6: 取消按钮触发 onCancel（modules §U5 init 字面要求）
            Button(action: onCancel) {
                Text("取消")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }
}

// MARK: - DEBUG-only preview fixture (D9 — fileprivate extension 防跨模块污染，机制与 U3 D9 同款)

#if DEBUG
fileprivate extension PositionTier {
    /// Preview fixture：部分启用前 3 档（演示 disabled 视觉态）。
    /// `fileprivate` 防 public extension 跨模块污染下游 DEBUG 编译（U3 D9 + R1-H4 同款）。
    static func previewEnabledTiers() -> Set<PositionTier> {
        [.tier1, .tier2, .tier3]
    }
}

#Preview("部分启用") {
    PositionPickerView(
        enabledTiers: PositionTier.previewEnabledTiers(),
        onPick: { _ in },
        onCancel: {}
    )
}

#Preview("全启用") {
    PositionPickerView(
        enabledTiers: Set(PositionTier.allCases),
        onPick: { _ in },
        onCancel: {}
    )
}

#Preview("全 disabled") {
    PositionPickerView(
        enabledTiers: [],
        onPick: { _ in },
        onCancel: {}
    )
}
#endif
```

- [ ] **Step 2: 跑 macOS host swift test 确认零回归**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中模式，N≥529，M≥101（baseline 519/100 + Task 1 加 10/1 = 529/101；宽松正则锚）。强 gate 用退出码：`swift test > /tmp/u5-zero-regression.txt 2>&1; echo "exit=$?"` 期望 `exit=0`。

- [ ] **Step 3: 跑 Mac Catalyst build-for-testing SUCCEEDED**

Run:
```bash
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/u5-derived \
           build-for-testing 2>&1 | tail -5 | tee /tmp/u5-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/u5-build-tail.txt && echo "✅ Catalyst PASS"
```
Expected: `TEST BUILD SUCCEEDED` 命中。若失败：常见原因是 SwiftUI iOS-only API 在 Catalyst 不支持 —— 修代码不修平台守卫（spec D1 明确 SwiftUI 跨三平台）。

- [ ] **Step 4: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
git commit -m "feat(u5): PositionPickerView SwiftUI shell + 3 #Preview fixture (Task 2)

薄 shell：body 消费 PositionPickerContent，HStack 5 按钮（D2）+ 取消按钮（D6）；
spec §U5 L2087-2091 字面 init 签名（D1 SwiftUI；D11 onPick/onCancel @escaping）。
fileprivate preview fixture 内联（D9）；不污染 PreviewFakes。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 — acceptance doc + 机检脚本

**Files:**
- Create: `docs/acceptance/2026-05-28-pr-u5-position-picker-view.md`
- Create: `scripts/acceptance/plan_u5_position_picker_view.sh`

> 本 Task 不加新测试。

- [ ] **Step 1: 写 acceptance doc**

新建 `docs/acceptance/2026-05-28-pr-u5-position-picker-view.md`，**完整内容**：

```markdown
# PR U5 验收清单（中文非程序员可执行）

> Wave 1 顺位 14 / 第 16 个 PR。spec `kline_trainer_plan_v1.5.md` §6.2.4 + `kline_trainer_modules_v1.4.md` §U5。
> plan `docs/superpowers/plans/2026-05-28-pr-u5-position-picker-view.md`。

## §A 文件存在

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| A.1 | `ls ios/Contracts/Sources/KlineTrainerContracts/UI/` | PositionPickerContent.swift / PositionPickerView.swift 两个文件（+ SettlementContent.swift / SettlementView.swift 老的） | 全部存在 |
| A.2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/UI/` | PositionPickerContentTests.swift（+ SettlementContentTests.swift 老的） | 存在 |
| A.3 | `test -f scripts/acceptance/plan_u5_position_picker_view.sh && echo OK` | OK | 输出 OK |

## §B 编译 + 全量测试（macOS host）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| B.1 | `cd ios/Contracts && swift build 2>&1 \| tail -3` | `Build complete!` | 命中 |
| B.2 | `cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests in [0-9]+ suites passed"` | 一行命中模式（基线 519/100 + 本 PR +10/+1 = 期望 529/101，但 grep 宽松不硬锁 N/M） | 命中模式 + `swift test` exit=0 |

## §C Catalyst 编译闸门（§15.1 #3）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| C.1 | `cd ios/Contracts && xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/u5-derived build-for-testing 2>&1 \| tail -5` | `TEST BUILD SUCCEEDED` | 命中 |

## §D 新 suite 全绿

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| D.1 | `cd ios/Contracts && swift test --filter PositionPickerContentTests 2>&1 \| grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"` | 一行命中模式（期望 N≥10/M=1） | 命中模式 + `swift test --filter PositionPickerContentTests` exit=0 |

## §E spec 字面 grep 锚（D1-D11 落地 — 防 spec drift）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'public struct PositionPickerContent: Equatable, Sendable' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 1 hit | 数字 = 1 |
| E.2 | `grep -nc 'public struct PositionPickerView: View' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit | 数字 = 1 |
| E.3 | `grep -nc 'init(enabledTiers: Set<PositionTier>,' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit | 数字 = 1 |
| E.4 | `grep -nc 'onPick: @escaping (PositionTier) -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D11) | 数字 = 1 |
| E.5 | `grep -nc 'onCancel: @escaping () -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D6 + D11) | 数字 = 1 |
| E.6 | `grep -nc 'Text("仓位选择")' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D7 spec L946 — anchor SwiftUI body literal，非 header 注释里的同字符串；R3 修) | 数字 = 1 |
| E.7 | `grep -nc 'Text("取消")' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D6 取消按钮 label — anchor SwiftUI body literal；R3 修) | 数字 = 1 |
| E.7b | `grep -nc 'Button(action: onCancel)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (R1-M2 修：D6 取消按钮真接 onCancel callback，非仅 label) | 数字 = 1 |
| E.8 | `grep -nc 'PositionTier.allCases.map' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 1 hit (D4 迭代 allCases 非 Set) | 数字 = 1 |
| E.9 | `grep -nc 'tier.rawValue' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 1 hit (D3 label = rawValue) | 数字 = 1 |
| E.10 | `grep -nc 'enabledTiers.contains(tier)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 1 hit (D5 enabled 判定) | 数字 = 1 |
| E.11 | `grep -nc 'HStack' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | ≥ 1 hit (D2 横向布局) | 数字 ≥ 1 |
| E.12 | `grep -nc '.disabled(!item.enabled)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D5/D8 disabled 视觉) | 数字 = 1 |

## §F 不依赖 Wave 0 / 1 业务运行时（叶子组件硬约束 + D14）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nE 'import (GRDB\|ZIPFoundation)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 | 输出为空 |
| F.2 | `grep -nE 'TradeCalculator\|TickEngine\|PositionManager\|TrainingFlowController\|APIClient' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 (D14) | 输出为空 |
| F.3 | `grep -ncE '^import SwiftUI$' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift` | 0 hit (Content 平台无关；锚 `^import SwiftUI$` 避免命中注释里"不 import SwiftUI"子串，R5 修) | 数字 = 0 |
| F.4 | `grep -ncE '^import SwiftUI$' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (View 才真 import；锚行首 R5 修) | 数字 = 1 |

## §G 无 RGB 硬编码 / 无 D16 反例（盈亏色未实现）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -nE 'Color\\(red:\|UIColor\\(' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 | 输出为空 |
| G.2 | `grep -nE '\\.foregroundStyle\\(\\.red\|\\.foregroundStyle\\(\\.green' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 (D16：不分盈亏色) | 输出为空 |

## §H DEBUG-only preview 隔离（D9 — fileprivate 防跨模块污染）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| H.1 | `grep -nE '#if DEBUG' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit | 数字 = 1 |
| H.2 | `grep -nc '#endif' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | ≥ 1 hit (DEBUG 配对) | 数字 ≥ 1 |
| H.3 | `grep -nc 'fileprivate extension PositionTier' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D9 v2 mechanism = `fileprivate extension PositionTier`，与 U3 严格同款) | 数字 = 1 |
| H.3b | `grep -nc 'static func previewEnabledTiers() -> Set<PositionTier>' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 1 hit (D9 v2 fixture 方法名) | 数字 = 1 |
| H.4 | `grep -ncE '^public.* extension PositionTier\|^extension PositionTier.*public' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 0 hit (D9 拒绝 public 跨模块污染；锚现在真有目标可禁，R1-M4 修) | 数字 = 0 |
| H.5 | `grep -nc 'extension PositionTier\|PositionTier.preview' ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | 0 hit (本 PR 不动 PreviewFakes — D9) | 数字 = 0 |

## §I caller-presentation 边界（D15 — View 不调 dismiss）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| I.1 | `grep -nE 'dismiss\\(\\)\|@Environment\\(\\\\.dismiss' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift` | 无命中 (View 不调 dismiss；caller 负责 presentation container) | 输出为空 |

## §J 机检脚本自身

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_u5_position_picker_view.sh 2>&1 \| tail -2` | `所有 12 项 G1-G12 验收通过` | 末行 ✅ + 0 exit code |
```

- [ ] **Step 2: 写机检脚本 — `plan_u5_position_picker_view.sh`**

```bash
#!/usr/bin/env bash
# Wave 1 顺位 14 (U5 PositionPickerView) 机检验收
# 用法：bash scripts/acceptance/plan_u5_position_picker_view.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: U5 源文件 + 测试文件 + 验收 doc 存在 =="
test -f ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
test -f ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
test -f ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift
test -f docs/acceptance/2026-05-28-pr-u5-position-picker-view.md

echo "== G2: PositionPickerContent 平台无关（仅 import Foundation；不 import SwiftUI/UIKit/CoreGraphics）=="
grep -q "^import Foundation$" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
# R4-C1：负向断言必须用 if/exit 1，不能用 `! grep`（pipeline 起头 `!` 被 set -e 豁免，永不 abort）
if grep -qE "^import (SwiftUI|UIKit|CoreGraphics)$" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift; then
  echo "G2 FAIL: Content 不应 import SwiftUI/UIKit/CoreGraphics"; exit 1
fi

echo "== G3: spec §U5 字面 init 签名（D1/D11）=="
grep -q "public struct PositionPickerView: View" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "init(enabledTiers: Set<PositionTier>," \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "onPick: @escaping (PositionTier) -> Void" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "onCancel: @escaping () -> Void" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift

echo "== G4: spec §6.2.4 字面字串：仓位选择 / 取消（D6/D7）+ 取消按钮真接 onCancel（R1-M2 + R3 修）=="
# R3 修：grep `Text("…")` body literal，避免命中 header 注释中相同字符串导致计数 ≠ 1
grep -q 'Text("仓位选择")' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q 'Text("取消")' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
# R1-M2：取消按钮 label 必须真接 onCancel callback，不只是文本字面
grep -q 'Button(action: onCancel)' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift

echo "== G5: D3/D4/D5 数据映射字面落地 =="
grep -q "PositionTier.allCases.map" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
grep -q "tier.rawValue" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift
grep -q "enabledTiers.contains(tier)" ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift

echo "== G6: D16 不实现盈亏色 / RGB 硬编码（反向验证）=="
if grep -qE '\.foregroundStyle\(\.red|\.foregroundStyle\(\.green' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G6 FAIL: 不应实现盈亏色 .foregroundStyle(.red/.green)"; exit 1
fi
if grep -qE 'Color\(red:|UIColor\(' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G6 FAIL: 不应 RGB 硬编码 Color(red:/UIColor("; exit 1
fi

echo "== G7: D14 不引业务运行时 / Content 平台无关 =="
if grep -qE 'import (GRDB|ZIPFoundation)' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G7 FAIL: 不应 import GRDB/ZIPFoundation"; exit 1
fi
# R4-I1：业务运行时类型不得出现在 prod 源（含注释）；D14 注释已改写不含裸 type token
if grep -qE 'TradeCalculator|TickEngine|PositionManager|TrainingFlowController|APIClient' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G7 FAIL: 不应引用业务运行时类型 TradeCalculator/TickEngine/PositionManager/TrainingFlowController/APIClient"; exit 1
fi

echo "== G8: D9 v2 DEBUG-only fileprivate extension PositionTier preview fixture（R1-M4 修：机制与 U3 严格同款，反向锚真有目标）=="
grep -q '^#if DEBUG' ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "fileprivate extension PositionTier" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
grep -q "static func previewEnabledTiers() -> Set<PositionTier>" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift
# 反向：不能是 public extension PositionTier（会污染下游 DEBUG 编译）
if grep -qE "^public.*extension PositionTier|^extension PositionTier.*public" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G8 FAIL: preview fixture extension 不能是 public（会跨模块污染 DEBUG 编译）"; exit 1
fi
# 反向：PreviewFakes 不被本 PR 动
if grep -qE "extension PositionTier|PositionTier\.preview" \
  ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift; then
  echo "G8 FAIL: 本 PR 不应改 PreviewFakes（D9 单 use site）"; exit 1
fi

echo "== G9: D15 View 不调 dismiss（caller 负责 presentation）=="
if grep -qE 'dismiss\(\)|@Environment\(.*dismiss' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift; then
  echo "G9 FAIL: View 不应调 dismiss() 或 @Environment(\\.dismiss)（caller 负责 presentation）"; exit 1
fi

echo "== G10: swift test 全量 PASS（基线 519 + 本 PR +10 = 期望 ≥529，宽松正则锚）=="
cd ios/Contracts
swift test 2>&1 | tee /tmp/u5-test-full.txt | tail -3
grep -qE "Test run with [0-9]+ tests in [0-9]+ suites passed" /tmp/u5-test-full.txt
cd -

echo "== G11: PositionPickerContentTests 单 suite 全绿（宽松正则锚）=="
cd ios/Contracts
swift test --filter PositionPickerContentTests 2>&1 | tee /tmp/u5-test-suite.txt | tail -3
grep -qE "Test run with [0-9]+ tests? in [0-9]+ suites? passed" /tmp/u5-test-suite.txt
cd -

echo "== G12: Mac Catalyst build-for-testing SUCCEEDED =="
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/u5-derived-final \
           build-for-testing 2>&1 | tail -5 | tee /tmp/u5-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/u5-build-tail.txt
cd -

echo
echo "✅ 所有 12 项 G1-G12 验收通过"
```

加可执行权限：
```bash
chmod +x scripts/acceptance/plan_u5_position_picker_view.sh
```

- [ ] **Step 3: 跑机检脚本一遍确认全绿**

Run: `bash scripts/acceptance/plan_u5_position_picker_view.sh 2>&1 | tail -2`
Expected: `✅ 所有 12 项 G1-G12 验收通过` 末行 + exit code 0。

- [ ] **Step 4: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add docs/acceptance/2026-05-28-pr-u5-position-picker-view.md \
        scripts/acceptance/plan_u5_position_picker_view.sh
git commit -m "docs(u5): acceptance §A-§J + 机检脚本（12 G 项）(Task 3)

非程序员可执行；spec §6.2.4 + modules §U5 字面 grep 锚 / Catalyst 编译闸门 /
test baseline 走宽松正则锚（不硬锁 N/M；用 exit code 守 strong gate）。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## R1 → v2 修订总览

R1 verdict **APPROVE**（0C/0H/4M/4L）— reviewer 明示"absorb M2 + M4 是 meaningful tightening；M1/M3/L1-L4 接受 residual"。v2 落地 3 项 inline tightening：

| Finding | 严重度 | 修订方式 | 落地位置 |
|---|---|---|---|
| M1 D11 未声明 `@Sendable` 不加（与 U3 同款） | Medium | D11 末尾加一句"不加 `@Sendable`（U3 同款，闭包随 SwiftUI `View` 协议合成 `@MainActor` 隔离运行，不跨 actor 边界）" | D11 决议 |
| M2 §E.7 / G4 仅锚 `"取消"` label，未锚取消按钮真接 `onCancel` callback | Medium | 加 §E.7b grep `Button(action: onCancel)` + script G4 加同款 grep | 验收 §E.7b + script G4 |
| M4 D9 free func 机制 与 U3 D9 fileprivate extension 机制 divergent → G8 反向 grep 无目标 | Medium | D9 改 `fileprivate extension PositionTier { static func previewEnabledTiers() -> Set<PositionTier> }`（与 U3 严格同款）；Task 2 Step 1 prod 代码同改；§H.3 + script G8 grep 改 `fileprivate extension PositionTier` + 加 §H.3b `static func previewEnabledTiers()` 锚 | D9 决议 + Task 2 Step 1 prod 代码 + 验收 §H.3/H.3b + script G8 |
| M3 §E.11 grep `HStack` 仅锚字面非结构 | Medium | **接受 residual**：reviewer 自评"Catalyst visual preview 是真 gate"；不加复杂结构 grep（会脆） | residual |
| L1 D6 取消按钮与 spec L949 ASCII 张力未显式 residual 标注 | Low | **接受 residual** | residual |
| L2 `equatableAndSendableAndDeterministic` 中 `any Sendable` runtime 断言无意义（compile-time 已守） | Low | **接受 residual**：测试名已含 Equatable + Determinism 真断言；删 `any Sendable` 行会让测试变更，引入 review noise；CLAUDE.md §3 "Touch only what you must"。 | residual |
| L3 baseline test count 漂移风险（+10 / 529 prose） | Low | **接受 residual**：acceptance grep 已用宽松正则不锁 N，prose 漂 ±2 不修 doc | residual |
| L4 `#Preview` macro 依赖 iOS17/macOS14 未在 D9 显标 | Low | **接受 residual**：Package.swift 已锚定 platforms；不退化到 PreviewProvider 已是默认假设 | residual |

测试数：10 → 10（不增不减；M2 修是新增 acceptance grep 不增测试）。基线推算 519+10 = 529 / 100+1 = 101，但 acceptance / script 走宽松正则锚不硬锁。

---

## R5 → v6 修订（whole-branch self-review 抓 doc-only false-fail）

`superpowers:requesting-code-review` 整体 branch self-review 报 With-fixes — 1 Minor doc-only：

| Finding | 严重度 | 修订方式 |
|---|---|---|
| R5-Minor acceptance §F.3 human grep `'import SwiftUI'` 命中 Content.swift 注释里"不 import SwiftUI"子串 → human 跑 F.3 看到 1 ≠ 期望 0 误判 FAIL | Minor（doc-only，机检 G2 用 `^import...$` 锚已正确，不受影响） | §F.3 + §F.4 改 `grep -ncE '^import SwiftUI$'` 锚行首（与 script G2 idiom 一致；同 R3-H1 注释子串 bug-class）；acceptance doc + plan 同步 |
| R5-Minor2 U3 (PR #70) `plan_u3_settlement_view.sh` 同有 `! grep` 死闸门 | Minor（已 merged，out of scope） | **接受 residual**：surgical scope 不回溯改 U3；教训记 memory 供后续 acceptance script 复用正确 idiom |

R5-Minor 只影响 human-facing doc（机检脚本 G2 用 `^import (SwiftUI\|UIKit\|CoreGraphics)$` 行首锚本就正确，J.1 跑脚本仍绿）。修是 1 行 doc 锚一致化。R5 不需新轮 review。

---

## R4 → v5 修订（Task 3 code-quality reviewer 抓 gate-soundness 硬伤）

Task 3 code-quality reviewer 报 NEEDS_FIXES — 抓出 1 Critical + 1 Important：

| Finding | 严重度 | 修订方式 |
|---|---|---|
| R4-C1 script 所有 `! grep -q` 负向断言在 `set -euo pipefail` 下是**死闸门** | Critical | POSIX 规则：以 `!` 起头的 pipeline 被 `set -e` 豁免（不 abort）→ G2/G6×2/G7×2/G8×2/G9 即使命中禁止 pattern 也永不 fail。改成 `if grep -q ...; then echo "GN FAIL: ..."; exit 1; fi` 标准 `set -e`-safe 负向 idiom。script + plan Task 3 Step 2 同步修。**实测验证**：`! grep` 对含 `import SwiftUI` 的文件 exit=0 不 abort（证实死闸门）；修后含禁止 pattern 时 exit≠0。 |
| R4-I1 修 C1 后 G7 业务运行时 grep 会命中 prod 注释里裸 `PositionManager` token → 干净树误 FAIL | Important（修 C1 暴露） | 改写 prod `PositionPickerView.swift` L16 D14 注释：`不 import E2 PositionManager runtime` → `仅语义依赖 E2（caller 由持仓状态推导 enabledTiers）；本文件不引业务运行时类型`，去掉裸 type token。Task 2 Step 1 plan code block 同步。其余负向闸门（G2/G6/G8/G9）实测干净树通过（G9 dismiss CJK 全角括号不命中 ASCII `dismiss()`；G8 `fileprivate` 起头不命中 `^public`/`^extension`）。 |
| R4-Minor doc 表格 `\|` 转义 / `Spacer().frame(height:8)` idiom / 缺 accessibilityLabel | Minor | **接受 residual**：表格 `\|` 是 GitHub 渲染正确的 markdown 转义；Spacer idiom plan-frozen；a11y label 用可见中文文本 VoiceOver 可读，故意省略（reviewer 自评不 block） |

R4-C1 是真 gate-soundness 硬伤（5/12 闸门非功能性），R4-I1 是修 C1 后暴露的连带。两者均在 Task 3 review 阶段抓出、subagent-driven 流程内一次性修复并 re-run 验收脚本绿（12/12 + Catalyst SUCCEEDED + 负向闸门实测 live）。修后将 re-run code-quality review 确认收敛。

> **注**：U3 (PR #70) 的 `plan_u3_settlement_view.sh` 同样有 `! grep` 死闸门模式（已 merged）——本 PR 不回溯修 U3（surgical scope），但教训记入 memory 供后续 acceptance script 复用正确 idiom。

---

## R3 → v4 修订（Task 2 implementer 抓 plan defect）

Task 2 implementer 报 DONE_WITH_CONCERNS — 抓出 plan §E.6/§E.7 + script G4 grep `'"仓位选择"'` / `'"取消"'` 会命中 prod 文件 header 注释（L309-310）+ body Text(...) 共 2 处 → `数字 = 1` 验收必失败：

| Finding | 修订 |
|---|---|
| R3-H1 grep `'"仓位选择"'` / `'"取消"'` 命中 header 注释 + body Text 共 2 处，验收硬锁 `= 1` 必失 | 改成 `Text("仓位选择")` / `Text("取消")` 精确 body literal anchor（implementer Option 2 recommended）；§E.6/§E.7 + script G4 同步 |

R3-H1 是 plan 自身的 grep precision defect，不是 prod 代码缺陷（prod 代码逐字 copy plan 同样源）。R3-H1 在 Task 2 implementer 阶段抓出，Task 3 实施时才会真触发——抓到点位仍属"实施前防御"，纳入 v4 一次性 inline 修。R3 不需新轮 review（修是字面更精准的 grep 而非语义改变）。

---

## R2 → v3 修订（cosmetic 收敛）

R2 verdict APPROVE。1 个 L 顺手修：

| Finding | 修订 |
|---|---|
| R2-L1 Self-Review §4 仍 cite obsolete `fileprivate func makePreviewEnabledTiers` 名 | Self-Review §4 prose 改成 v2 真名 `fileprivate extension PositionTier` + `static func previewEnabledTiers() -> Set<PositionTier>`；附加把 R1-M2 新增的 §E.7b cancel button 锚也一并列入一致性表 |

R2-L1 是 cosmetic prose 完善；R2 reviewer 明示"planner may absorb inline or accept as residual at their discretion；matches L3 prose-drift residual category already accepted"——v3 选 absorb 因为是 self-review §4 的一致性 attestation，prose drift 会反噬。R2 不需新轮 review。

---

## Self-Review（plan 写完后、push 给 reviewer 前）

按 writing-plans skill §Self-Review 跑：

**1. Spec 覆盖检查**：

| spec 要求 | 实现 task |
|---|---|
| modules §U5 L2087 `struct PositionPickerView: View` | Task 2 + 验收 E.2 |
| modules §U5 L2088 `init(enabledTiers: Set<PositionTier>,` | Task 2 init + 验收 E.3 |
| modules §U5 L2089 `onPick: (PositionTier) -> Void` | Task 2 init `@escaping` + 验收 E.4 + D11 决议 |
| modules §U5 L2090 `onCancel: () -> Void` | Task 2 init `@escaping` + 取消按钮 + 验收 E.5 + D6 决议 |
| spec §6.2.4 L946 "**仓位选择 HUD：**" 标题 | Task 2 body Text("仓位选择") + 验收 E.6 + D7 决议 |
| spec §6.2.4 L949 `[ 1/5 ]  [ 2/5 ]  [ 3/5 ]  [ 4/5 ]  [ 5/5 ]` 横排 | Task 1 Content tiers + Task 2 body HStack ForEach + 验收 E.8/E.9/E.11 + D2/D3/D4 决议 |
| spec §6.2.4 L952 "点击某档位后确认交易，面板消失" | Task 2 body Button(action: { onPick(tier) }) + D15 决议（caller dismiss） |
| spec L942/L943 "灰置（disabled）" 语义 | Task 1 Content.Item.enabled + Task 2 body .disabled(!item.enabled) + 验收 E.10/E.12 + D5 决议 |

无 spec 要求缺 task。

**2. 占位扫描**：搜 "TBD"、"TODO"、"implement later"、"fill in details"、"Similar to Task" —— 全部不存在（plan 全代码原文 + 命令原文）。

**3. 类型一致性**：`PositionPickerContent` (Task 1) → `PositionPickerView` (Task 2) 单向使用，无类型重命名；`PositionPickerContent.init(enabledTiers:)` 在 Task 1 定义，在 Task 2 调用 → 签名一致；`PositionPickerContent.Item` 在 Task 1 定义，在 Task 2 body `ForEach(content.tiers, id: \.tier)` 使用 → 一致；`PositionTier` 已在 Models.swift L25-30 冻结，不重定义。

**4. Acceptance/script 一致性**：acceptance doc §B.2 + script G10 用同款宽松正则 `Test run with [0-9]+ tests in [0-9]+ suites passed` → 一致；§D.1 + script G11 用同款 → 一致；§C.1 + script G12 用 "TEST BUILD SUCCEEDED" → 一致；§E.4/E.5 + script G3 关于 `@escaping` 签名锚 → 一致；§E.8/E.9/E.10 + script G5 关于 D3/D4/D5 数据映射锚 → 一致；§E.7b + script G4 关于 `Button(action: onCancel)` callback 锚（R1-M2 v2 修）→ 一致；§H.3 + §H.3b + script G8 关于 `fileprivate extension PositionTier` + `static func previewEnabledTiers() -> Set<PositionTier>` v2 锚（R1-M4 + R2-L1 v3 修）→ 一致。

**5. Set 迭代顺序硬约束**：D4 决议要求迭代 `PositionTier.allCases`（非 `enabledTiers`）；Task 1 Step 3 代码 `PositionTier.allCases.map { tier in ... enabledTiers.contains(tier) }`；Task 1 Step 1 测试 `partialEnabledRespectsTierOrder` 故意按反序构造 Set 强证；验收 E.8 grep `PositionTier.allCases.map` → 三层互锁。

无 plan failure。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-28-pr-u5-position-picker-view.md`。

下一步走用户在主线已选定的路径：**Subagent-Driven Development**（user 本次显式 prompt 第 3 段 = "再是 sub agent driven development"）。在此之前先跑**Plan-stage 对抗性 review = Claude Opus 4.7 xhigh effort**（user 本次显式 prompt 第 2 段 = "另一个 claude opus 4.7 xhigh effort 做对抗性 review 到收敛"），收敛 APPROVE 后才开 Task 1 实施 subagent。
