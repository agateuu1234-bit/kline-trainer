# 买卖小操作栏（内联展开 + 全仓/清仓快捷）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把买卖交互从「点按钮→弹模态 5 档 sheet（PositionPickerView）」改成「点买/卖→按钮旁悬浮内联小操作栏（TradeBarView），全仓/清仓 = 强调色 tier5 chip」。

**Architecture:** UI 壳三件套（纯值 `TradeBarContent` host 全测 + 薄壳 `TradeBarView` Catalyst 编译闸 + `TrainingView` 集成）。全仓/清仓 = 引擎现有 `PositionTier.tier5`（买入 ratio=1.0 全仓投入 / 卖出全平不取整）→ **零引擎改动**。删除被替换的模态 `PositionPickerView`/`PositionPickerContent`/其测试/孤儿验收脚本。

**Tech Stack:** Swift Package（KlineTrainerContracts），SwiftUI（跨 iOS17/macOS14/Catalyst），Swift Testing（`@Suite`/`@Test`/`#expect`/`@testable import`），host `swift test`，Mac Catalyst `build-for-testing`。

**Spec:** `docs/superpowers/specs/2026-06-20-trade-bar-inline-design.md`（已收敛 APPROVE）。

## Global Constraints

- **零引擎改动**：不碰 `TrainingEngine` / `TradeCalculator` / `TradeFeedback` / 触觉 / Toast / autosave / `PositionTier` 枚举。全仓/清仓 = `engine.buy/sell(panel:tier:.tier5)`（现有路径）。
- **`CONTRACT_VERSION` 不 bump**（仍 `"1.6"`）：UI 壳层改版，`PositionTier.rawValue`(`"5/5"`)/Codable/DDL/持久格式全不变。
- **纯值类型仅 `import Foundation`**（`TradeBarContent`）；host `swift test` 全测。
- **`TradeBarView` 平台无关 SwiftUI**（不加 `#if canImport(UIKit)`，同 `PositionPickerView`）；`TrainingView` 仍在 `#if canImport(UIKit)` 内（嵌 `ChartContainerView` UIViewRepresentable），host 不编译、靠 Catalyst 闸。
- **新顶层 `TradeAction` 枚举**：grep 已确认无碰撞（既有 `TradeOperation`/`TradeReason`/`TradeFeedback`/`TradeCalculator`，无 `TradeAction`）。
- **小条 overlay 渲染条件**恒为 conjoint：`showsTradeButtons && tradeStrip?.panel == id`（防 stale 悬空）。
- 频繁提交；每个 Task 末尾独立可测可审。
- 验收清单中文，action/expected/pass-fail；禁用 `.claude/workflow-rules.json` 列出的措辞。

---

## File Structure

| 文件 | 责任 | Task |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarContent.swift`（新） | 纯值：`TradeAction` + `TradeBarContent(action:)` → 5 chip | 1 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeBarContentTests.swift`（新） | host 单测 | 1 |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarView.swift`（新） | SwiftUI 薄壳：横排 chips + ✕ | 2 |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（改） | 集成：删 sheet、加 overlay、改 state/形参/struct | 3 |
| `…/UI/PositionPickerView.swift` / `PositionPickerContent.swift` / `Tests/…/PositionPickerContentTests.swift` / `scripts/acceptance/plan_u5_position_picker_view.sh`（删） | 被替换的模态组件 + 孤儿脚本 | 4 |
| `kline_trainer_modules_v1.4.md` / `kline_trainer_plan_v1.5.md`（改） | 冻结 spec amendment §U5 + §6.2.4 + 目录树 | 5 |
| `docs/superpowers/acceptance/2026-06-20-trade-bar-inline-acceptance.md`（新） | 验收清单 | 5 |

依赖序：Task 1（Content）→ Task 2（View 依赖 Content）→ Task 3（TrainingView 依赖 View）→ Task 4（删旧，须在 Task 3 解除 TrainingView 对 PositionPicker 的引用后）→ Task 5（文档）。

---

## Task 1: TradeBarContent 纯值 + host 测试

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarContent.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeBarContentTests.swift`

**Interfaces:**
- Consumes: `PositionTier`（`Models/Models.swift:25-31`，`allCases` = tier1…tier5，`rawValue` = `"1/5"…"5/5"`）。
- Produces: `public enum TradeAction { case buy, sell }`；`public struct TradeBarContent { let action: TradeAction; let chips: [Chip] }`，`Chip = { tier: PositionTier, label: String, isShortcut: Bool }`，`init(action: TradeAction)`。

- [ ] **Step 1: 写失败测试**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeBarContentTests.swift
// Spec: docs/superpowers/specs/2026-06-20-trade-bar-inline-design.md §6.1
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TradeBarContent host tests")
struct TradeBarContentTests {

    @Test("buy 态 5 chip label = 1/5..4/5 + 全仓")
    func buyLabels() {
        let c = TradeBarContent(action: .buy)
        #expect(c.chips.map(\.label) == ["1/5", "2/5", "3/5", "4/5", "全仓"])
    }

    @Test("sell 态 5 chip label = 1/5..4/5 + 清仓")
    func sellLabels() {
        let c = TradeBarContent(action: .sell)
        #expect(c.chips.map(\.label) == ["1/5", "2/5", "3/5", "4/5", "清仓"])
    }

    @Test("chip tier 顺序恒 tier1→tier5（迭代 allCases，不受 action 影响）")
    func tierOrder() {
        #expect(TradeBarContent(action: .buy).chips.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
        #expect(TradeBarContent(action: .sell).chips.map(\.tier) == [.tier1, .tier2, .tier3, .tier4, .tier5])
    }

    @Test("买卖仅末档 label 不同、前 4 档相同（真双判别锚）")
    func buySellDifferOnlyAtLastChip() {
        let buy = TradeBarContent(action: .buy).chips
        let sell = TradeBarContent(action: .sell).chips
        #expect(Array(buy[0..<4]).map(\.label) == Array(sell[0..<4]).map(\.label))
        #expect(buy[4].label == "全仓")
        #expect(sell[4].label == "清仓")
        #expect(buy[4].label != sell[4].label)
    }

    @Test("label↔tier↔shortcut 联合锁定（末档 tier5 + isShortcut + 上下文 label）")
    func lastChipConjoint() {
        let buy = TradeBarContent(action: .buy).chips[4]
        #expect(buy.tier == .tier5 && buy.isShortcut && buy.label == "全仓")
        let sell = TradeBarContent(action: .sell).chips[4]
        #expect(sell.tier == .tier5 && sell.isShortcut && sell.label == "清仓")
    }

    @Test("前 4 档 isShortcut == false，仅末档强调")
    func onlyLastChipIsShortcut() {
        #expect(TradeBarContent(action: .buy).chips.map(\.isShortcut) == [false, false, false, false, true])
        #expect(TradeBarContent(action: .sell).chips.map(\.isShortcut) == [false, false, false, false, true])
    }

    @Test("chips 恒 5 元素")
    func alwaysFiveChips() {
        #expect(TradeBarContent(action: .buy).chips.count == 5)
        #expect(TradeBarContent(action: .sell).chips.count == 5)
    }

    @Test("tier5.rawValue 仍为 5/5（UI 重标不改持久化契约）")
    func tier5RawValueUnchanged() {
        #expect(PositionTier.tier5.rawValue == "5/5")
    }

    @Test("Content + Chip 是 Equatable / Sendable（同输入恒等输出）")
    func equatableAndSendable() {
        #expect(TradeBarContent(action: .buy) == TradeBarContent(action: .buy))
        #expect(TradeBarContent(action: .buy) != TradeBarContent(action: .sell))
        let _: any Sendable = TradeBarContent(action: .buy)
        let _: any Sendable = TradeBarContent(action: .buy).chips.first!
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TradeBarContentTests`
Expected: 编译失败 `cannot find 'TradeBarContent' in scope` / `cannot find type 'TradeAction'`。

- [ ] **Step 3: 写最小实现**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarContent.swift
// Spec: docs/superpowers/specs/2026-06-20-trade-bar-inline-design.md §4.2/§5.1
//
// 平台无关纯值类型：把 action(.buy/.sell) 翻译成 SwiftUI 渲染用的 5 chip 有序数组。
// 仅 import Foundation —— host swift test 全测（同 PositionPickerContent 范式）。
//
// 决议：
// - tier1–4：label = PositionTier.rawValue（"1/5".."4/5"），isShortcut = false。
// - tier5：label = action==.buy ? "全仓" : "清仓"，isShortcut = true（UI 强调快捷档）。
//   底层仍是 PositionTier.tier5 → engine.buy/sell(tier:.tier5) 即现有全仓/清仓引擎路径（零引擎改动）。
// - 迭代 PositionTier.allCases（杜绝 Set 迭代不确定性，同 PositionPickerContent D4）。

import Foundation

public enum TradeAction: Equatable, Sendable {
    case buy
    case sell
}

public struct TradeBarContent: Equatable, Sendable {
    public struct Chip: Equatable, Sendable {
        public let tier: PositionTier
        public let label: String
        public let isShortcut: Bool

        public init(tier: PositionTier, label: String, isShortcut: Bool) {
            self.tier = tier
            self.label = label
            self.isShortcut = isShortcut
        }
    }

    public let action: TradeAction
    public let chips: [Chip]

    public init(action: TradeAction) {
        self.action = action
        self.chips = PositionTier.allCases.map { tier in
            if tier == .tier5 {
                return Chip(tier: tier, label: action == .buy ? "全仓" : "清仓", isShortcut: true)
            } else {
                return Chip(tier: tier, label: tier.rawValue, isShortcut: false)
            }
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TradeBarContentTests`
Expected: 9 个测试全 PASS。

- [ ] **Step 5: 跑全量确认不回归**

Run: `cd ios/Contracts && swift test`
Expected: 0 failures（相对基线净 +9 个 TradeBarContent 测试）。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarContent.swift ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeBarContentTests.swift
git commit -m "feat: TradeBarContent 纯值（买卖 5 chip，tier5=全仓/清仓）+ 9 host 测试"
```

---

## Task 2: TradeBarView SwiftUI 薄壳

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarView.swift`

**Interfaces:**
- Consumes: `TradeBarContent`（Task 1）、`TradeAction`（Task 1）、`PositionTier`。
- Produces: `public struct TradeBarView: View`，`init(action: TradeAction, onPick: @escaping (PositionTier) -> Void, onCancel: @escaping () -> Void)`。

- [ ] **Step 1: 写薄壳实现**（SwiftUI 壳不写 host 单测，D10；靠编译闸）

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarView.swift
// Spec: docs/superpowers/specs/2026-06-20-trade-bar-inline-design.md §4.3/§5.2
//
// 薄 SwiftUI shell：横排 5 chip Button + 取消(✕)；数据映射交 TradeBarContent（Task 1）。
// 平台无关 SwiftUI（不加 #if canImport(UIKit)，同 PositionPickerView 跨 iOS17/macOS14/Catalyst）。
//
// 决议：
// - 单 tap 直接 fire onPick(chip.tier)，无二次确认（同 PositionPickerView D8）。
// - View 不调 dismiss，收起由 caller(TrainingView) 负责（同 D15）。
// - tier5（全仓/清仓，chip.isShortcut）用 .borderedProminent 强调，其余 .bordered（设计 D5 强调色）。
// - onPick/onCancel @escaping（Swift 编译强制）。

import SwiftUI

public struct TradeBarView: View {
    private let content: TradeBarContent
    private let onPick: (PositionTier) -> Void
    private let onCancel: () -> Void

    public init(action: TradeAction,
                onPick: @escaping (PositionTier) -> Void,
                onCancel: @escaping () -> Void) {
        self.content = TradeBarContent(action: action)
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(content.chips, id: \.tier) { chip in
                chipButton(chip)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    // tier5 全仓/清仓档强调（.borderedProminent），其余 .bordered。
    // 两分支各为具体 ButtonStyle 类型，用 @ViewBuilder if/else 统一（避免 ternary 类型不一致）。
    @ViewBuilder
    private func chipButton(_ chip: TradeBarContent.Chip) -> some View {
        if chip.isShortcut {
            Button(action: { onPick(chip.tier) }) {
                Text(chip.label).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: { onPick(chip.tier) }) {
                Text(chip.label).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
    }
}

#if DEBUG
#Preview("买入小条") {
    TradeBarView(action: .buy, onPick: { _ in }, onCancel: {})
}

#Preview("卖出小条") {
    TradeBarView(action: .sell, onPick: { _ in }, onCancel: {})
}
#endif
```

- [ ] **Step 2: host 编译验证**（TradeBarView 无 `#if`，host 编译）

Run: `cd ios/Contracts && swift build`
Expected: `Compiling … TradeBarView.swift` 无错误，build 成功。

- [ ] **Step 3: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarView.swift
git commit -m "feat: TradeBarView SwiftUI 薄壳（横排 chips + ✕，tier5 强调）"
```

---

## Task 3: TrainingView 集成（删 sheet → 加内联 overlay）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`

**Interfaces:**
- Consumes: `TradeBarView`（Task 2）、`TradeAction`（Task 1）、既有 `performTrade` / `engine.buy/sell` / `buyEnabled` / `sellEnabled` / `showsTradeButtons`。
- Produces: 无对外接口（壳内部改装）。

> 该文件在 `#if canImport(UIKit)` 内，host 不编译；本 Task 验证走 Mac Catalyst `build-for-testing`。

- [ ] **Step 1: state 改名**（`pickerRequest` → `tradeStrip`）

把 `@State private var pickerRequest: PickerRequest?`（约 L32）改为：

```swift
    @State private var tradeStrip: TradeStripRequest?
```

- [ ] **Step 2: 删 `.sheet`（PositionPickerView）**

删除整段 `.sheet(item: $pickerRequest) { req in PositionPickerView(...) }`（约 L107-115，含 `enabledTiers`/`onPick`/`onCancel` 闭包）。

- [ ] **Step 3: `panel(_:)` 加内联 overlay**

把 `panel(_:)`（约 L189-195）替换为：

```swift
    private func panel(_ id: PanelId) -> some View {
        HStack(spacing: 0) {
            ChartContainerView(panel: id, engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsTradeButtons { tradeButtons(id) }
        }
        // 内联买卖小条：仅当该面板被点开时悬浮贴底（conjoint guard 含 showsTradeButtons，
        // 防 Normal 置位的 tradeStrip 在模式翻转至 Review/会话结束后悬空，spec §5.3 L3）。
        .overlay(alignment: .bottom) {
            if showsTradeButtons, let strip = tradeStrip, strip.panel == id {
                TradeBarView(
                    action: strip.action,
                    onPick: { tier in
                        performTrade(strip.action, panel: id, tier: tier)
                        tradeStrip = nil
                    },
                    onCancel: { tradeStrip = nil })
            }
        }
    }
```

- [ ] **Step 4: `tradeButtons(_:)` 买/卖改置位 tradeStrip**

把 `tradeButtons(_:)`（约 L197-211）中买入/卖出两 Button 的 action 改为（其余 `.disabled` / 持有观察 / `.buttonStyle(.bordered)` 不变）：

```swift
            Button("买入") { tradeStrip = TradeStripRequest(panel: id, action: .buy) }
                .disabled(!engine.buyEnabled)
            Button("卖出") { tradeStrip = TradeStripRequest(panel: id, action: .sell) }
                .disabled(!engine.sellEnabled)
```

- [ ] **Step 5: `performTrade` 形参类型改 `TradeAction`**

把 `performTrade` 签名（约 L214）从 `_ action: PickerRequest.Action` 改为 `_ action: TradeAction`（**函数体不变**，`switch action { case .buy …; case .sell … }` 对 `TradeAction` 同样成立）：

```swift
    private func performTrade(_ action: TradeAction, panel: PanelId, tier: PositionTier) {
```

- [ ] **Step 6: `PickerRequest` struct 改名 `TradeStripRequest` + 换 action 类型**

把私有 struct（约 L304-309）替换为（删其嵌套 `enum Action`，`action` 改用顶层 `TradeAction`）：

```swift
    private struct TradeStripRequest: Identifiable {
        let panel: PanelId
        let action: TradeAction
        var id: String { "\(panel)-\(action)" }
    }
```

- [ ] **Step 7: 修头部 stale 注释（保留同行 D10 子句，修 plan-review L1）**

文件头 L13 实为 D9+D10 同行：`// - D9 PositionPicker 全档启用，buy 返 failure 兜；D10 交易按钮仅 Normal/Replay，持有/观察随持仓切文案。`。**只改 D9 子句、保留 D10 子句**——Edit 用整行 old_string 防误伤：

old_string:
```swift
// - D9 PositionPicker 全档启用，buy 返 failure 兜；D10 交易按钮仅 Normal/Replay，持有/观察随持仓切文案。
```
new_string:
```swift
// - D9（RFC #1 改）：买卖改内联 TradeBarView（点买/卖悬浮小条，非模态 PositionPicker）；全仓/清仓 = tier5 强调档；buyEnabled/sellEnabled 门控小条打开，失败仍走 TradeFeedback toast。D10 交易按钮仅 Normal/Replay，持有/观察随持仓切文案。
```

（只改 stale 的 D9 子句，D10 子句字面保留；不动其余无关注释。）

- [ ] **Step 8: Mac Catalyst 编译验证**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer" && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`（TrainingView 引用 TradeBarView/TradeAction/TradeStripRequest 全编译通过；PositionPickerView 此刻仍在但已不被引用）。

- [ ] **Step 9: host 全量不回归**

Run: `cd ios/Contracts && swift test`
Expected: 0 failures（PositionPickerContentTests 仍在、仍绿——Task 4 才删）。

- [ ] **Step 10: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "feat: TrainingView 集成内联买卖小条（删 PositionPicker sheet → TradeBarView overlay）"
```

---

## Task 4: 删除被替换的模态组件 + 孤儿验收脚本

**Files:**
- Delete: `ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift`
- Delete: `ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift`
- Delete: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift`
- Delete: `scripts/acceptance/plan_u5_position_picker_view.sh`

**Interfaces:** 无（纯删除；Task 3 已解除唯一 caller）。

- [ ] **Step 1: 再核实零残留引用**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer" && grep -rn "PositionPickerView\|PositionPickerContent" ios/ --include=*.swift`
Expected: **无任何 .swift 命中**（Task 3 已删 TrainingView 的 sheet；其余只剩 doc/历史引用，不影响编译）。若有 .swift 命中 → 停止，回 Task 3 补删。

- [ ] **Step 2: 删除 4 个文件**

```bash
git rm ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift \
       ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift \
       ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift \
       scripts/acceptance/plan_u5_position_picker_view.sh
```

- [ ] **Step 3: host 全量确认不回归**

Run: `cd ios/Contracts && swift test`
Expected: 0 failures（少了 10 个 PositionPickerContentTests，总数相应下调；TradeBarContentTests 9 个仍绿）。

- [ ] **Step 4: Mac Catalyst 编译确认（删后仍编译）**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer" && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "refactor: 删除被内联小条取代的模态 PositionPickerView/Content/Tests + 孤儿验收脚本"
```

---

## Task 5: 冻结 spec amendment + 验收清单

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（§U5 L2124-2131 + 验收清单 L2207）
- Modify: `kline_trainer_plan_v1.5.md`（§6.2.4 L950-964 + 目录树 L274）
- Create: `docs/superpowers/acceptance/2026-06-20-trade-bar-inline-acceptance.md`

**Interfaces:** 无（文档）。

- [ ] **Step 1: 改 modules §U5（L2124-2132）**

把：

```markdown
### U5 仓位选择 HUD `PositionPickerView.swift`

```swift
struct PositionPickerView: View {
    init(enabledTiers: Set<PositionTier>,
         onPick: (PositionTier) -> Void,
         onCancel: () -> Void)
}
```
```

替换为：

```markdown
### U5 买卖小操作栏 `TradeBarView.swift`（RFC 2026-06-20 #1：内联展开取代模态 PositionPickerView）

```swift
struct TradeBarView: View {
    init(action: TradeAction,            // .buy / .sell
         onPick: (PositionTier) -> Void,  // tier5 = 全仓(买)/清仓(卖)
         onCancel: () -> Void)
}
// 纯值 TradeBarContent(action:) 产出 5 chip（tier1–4="1/5".."4/5"；tier5="全仓"/"清仓" isShortcut 强调）。
// 引擎零改动：onPick(.tier5) 即现有全仓/清仓路径。模态 PositionPickerView 已删除（RFC #1）。
```
```

- [ ] **Step 2: 改 modules 验收清单 L2207**

把 `- [ ] U5 PositionPickerView` 改为：

```markdown
- [ ] U5 TradeBarView（RFC 2026-06-20 #1 内联买卖小操作栏，取代 PositionPickerView）
```

- [ ] **Step 3: 改 plan §6.2.4（L950-964）**

把 L954-964 描述模态 HUD 的部分：

```markdown
- **买入按钮**：空仓或未满仓时可用（否则灰置）。点击弹出仓位选择 HUD
- **卖出按钮**：有持仓时可用（否则灰置）。点击弹出仓位选择 HUD
- **持有/观察按钮**：始终可用。直接推进 1 根当前周期 K 线。**有仓位时显示为"持有"图标，空仓时显示为"观察"图标**

**仓位选择 HUD：**

```
[ 1/5 ]  [ 2/5 ]  [ 3/5 ]  [ 4/5 ]  [ 5/5 ]
```

点击某档位后确认交易，面板消失。
```

替换为：

```markdown
- **买入按钮**：空仓或未满仓时可用（否则灰置）。点击在该面板**就地展开内联买卖小操作栏**（非模态弹窗）
- **卖出按钮**：有持仓时可用（否则灰置）。点击展开内联买卖小操作栏
- **持有/观察按钮**：始终可用。直接推进 1 根当前周期 K 线。**有仓位时显示为"持有"图标，空仓时显示为"观察"图标**

**内联买卖小操作栏（RFC 2026-06-20 #1，取代模态 HUD）：**

```
[ 1/5 ]  [ 2/5 ]  [ 3/5 ]  [ 4/5 ]  [ 全仓/清仓★ ]   ✕
```

- 悬浮贴该面板底部（不挤压图表、不触发 renderState 重算）；点某档**立即成交并收起**；✕ 收起不成交。
- ★ = tier5 强调色快捷档：买入语境="全仓"、卖出语境="清仓"，即 `engine.buy/sell(tier:.tier5)` 现有路径（引擎零改动）。
```

- [ ] **Step 4: 改 plan 目录树 L274**

把 `│   │   ├── PositionPickerView.swift      # 仓位选择 HUD（5档）` 改为：

```markdown
│   │   ├── TradeBarView.swift           # 买卖小操作栏（内联 + 全仓/清仓快捷，RFC #1）
```

- [ ] **Step 5: 写验收清单**

```markdown
# 验收清单：买卖小操作栏（内联展开 + 全仓/清仓快捷）（RFC #1）

## 1. host 单测（机器执行）
- [ ] 动作：`cd ios/Contracts && swift test --filter TradeBarContentTests`
      预期：`TradeBarContent host tests` 9 个全绿。
- [ ] 动作：`cd ios/Contracts && swift test`
      预期：全量 0 failures，相对基线净 = +TradeBarContent(9) −PositionPickerContent(10)。

## 2. Mac Catalyst 编译（机器执行）
- [ ] 动作：`xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`
      预期：`** TEST BUILD SUCCEEDED **`。

## 3. iOS app build（机器执行）
- [ ] 动作：`xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived CODE_SIGNING_ALLOWED=NO`（同 app-build.yml；若报 SwiftPM 包依赖未解析，改 `-workspace ios/KlineTrainer/KlineTrainer.xcodeproj/project.xcworkspace`）
      预期：`** BUILD SUCCEEDED **`。

## 4. 模拟器人工验收（非编码者执行，iPhone 17 Pro 模拟器 + seed fixture）
| # | 动作 | 预期 | 通过? |
|---|---|---|---|
| 1 | 进训练，点上面板「买入」 | 该面板底部悬浮出现横排小条 `[1/5][2/5][3/5][4/5][全仓] ✕`，无模态弹窗 | ☐ |
| 2 | 点小条某分档（如 2/5） | 立即按 2/5 买入成交（触觉+标记），小条收起 | ☐ |
| 3 | 再点「买入」，点末档「全仓」 | 按全仓（tier5）买入成交，小条收起 | ☐ |
| 4 | 全仓档视觉 | 「全仓」chip 为强调色（与 1/5–4/5 区分） | ☐ |
| 5 | 有持仓时点「卖出」 | 小条末档显示「清仓」（非「全仓」），点清仓全部卖出 | ☐ |
| 6 | 点小条 ✕ | 小条收起，不成交、不推进 | ☐ |
| 7 | 点上面板「买入」后再点下面板「卖出」 | 同时只有一个小条（上面板小条消失、下面板出现卖出小条） | ☐ |
| 8 | 进复盘(Review)模式 | 右列买卖按钮与小条均不显示（能力矩阵不变） | ☐ |
| 9 | 空仓时看「卖出」按钮 | 灰置不可点（sellEnabled=false，无法打开清仓小条） | ☐ |

## 5. 回归确认（非编码者执行）
| # | 动作 | 预期 | 通过? |
|---|---|---|---|
| 1 | 买入/卖出成交 | 触觉(.heavy)+红B/绿S 标记+推进 K 线，一切如常（performTrade 体不变） | ☐ |
| 2 | 资金不足点全仓 | 出 toast 失败提示（TradeFeedback 路径不变） | ☐ |
| 3 | 图表 pan/pinch/坐标轴 | 滚动/缩放/RFC #3 轴网格一切如常（overlay 不扰图表几何） | ☐ |

## 6. Opus 4.8 xhigh 对抗性 review ledger（代 codex，user explicit）
- spec：R1 NEEDS-ATTENTION（C1+2H+2M+3L）→ 全修 → R2（2 引用精度）→ 收敛 APPROVE。commits 397a40b / aa03c94 / a07ba09。
- plan：（实施前 review 回填）。
- 实现期（subagent-driven）：（回填）。
- branch-diff：（回填）。
```

- [ ] **Step 6: 提交**

```bash
git add kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md docs/superpowers/acceptance/2026-06-20-trade-bar-inline-acceptance.md
git commit -m "docs: spec amendment §U5/§6.2.4（模态→内联小条）+ 目录树 + 验收清单"
```

---

## Self-Review（写完后自查）

**1. Spec 覆盖**：
- §4.2 TradeBarContent → Task 1 ✓
- §4.3 TradeBarView → Task 2 ✓
- §4.4 TrainingView 6 改点（state/sheet/overlay/buttons/performTrade/struct）→ Task 3 Step 1-7 ✓
- §4.5 删 4 文件 → Task 4 ✓
- §5.1/§5.2/§5.3 规格 → Task 1 测试 + Task 2 壳 + Task 3 行为 ✓
- §6.1 测试（买卖区分 + 联合断言 + count + order + rawValue）→ Task 1 ✓
- §7 spec amendment（modules §U5+L2207 / plan §6.2.4+L274 / 验收）→ Task 5 ✓
- §7 CONTRACT_VERSION 不 bump → Global Constraints + 不改 Models.swift ✓
- conjoint guard（L3）→ Task 3 Step 3 ✓

**2. Placeholder 扫描**：无 TBD/TODO/「类似 Task N」；每步含完整代码/命令/预期。

**3. 类型一致性**：`TradeAction`（Task 1 定义 → Task 2/3 用）、`TradeBarContent.Chip`（Task 1 → Task 2 `chipButton` 形参）、`TradeStripRequest`（Task 3 定义 + 用）、`onPick: (PositionTier)->Void`（Task 2 ↔ Task 3 调用）全一致。

**4. 残留**：spec R6（m01/matrix drift）非本计划职责，不在任务内（如登记交后续治理 PR）。
