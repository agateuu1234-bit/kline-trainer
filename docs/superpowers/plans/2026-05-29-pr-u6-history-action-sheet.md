# PR U6 — HistoryActionSheet 历史动作表 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec §6.1.3 + modules §U6 字面要求的 SwiftUI 历史动作表（`struct HistoryActionSheet: View` 含 `init(record: TrainingRecord, onReview: () -> Void, onReplay: () -> Void, onCancel: () -> Void)`），渲染一个识别本条历史记录的标题（股票名（代码））+ 三个动作按钮「复盘」/「再来一次」/「取消」分别触发 onReview / onReplay / onCancel —— Wave 1 顺位 15 / 交付序第 17 个 PR per outline v20。

**Architecture:** **平台无关纯值类型 `HistoryActionContent`**（host 全测：把 `TrainingRecord` 翻译成单个 `title: String` = 股票名（代码）全角括号格式）+ **薄 SwiftUI shell `HistoryActionSheet`**（body 消费 `HistoryActionContent`，仅做 VStack/Button 装配 + 三个 callback 触发；无业务逻辑）。此双层架构与 U3 SettlementView / U5 PositionPickerView 严格同款：纯函数层 host swift test 真断言 + 渲染薄层由 Mac Catalyst build-for-testing SUCCEEDED 编译闸门守护。modules §U6 字面 `init(record:onReview:onReplay:onCancel:)` 不增不减；三个 callback 触发后由 caller（U1 HomeView，Wave 2）负责 sheet dismiss + 路由到 Review/Replay 模式，本 PR 只触发回调。

**Tech Stack:** Swift 6.0 / Swift Testing (`import Testing` + `@Test` + `#expect`) / Foundation / SwiftUI (跨 iOS 17 + macOS 14 + Mac Catalyst) / 已冻结模块：`TrainingRecord`（AppState.swift L19-60，15 字段 Codable/Equatable/Sendable）+ `FeeSnapshot`（Models.swift L143-151，preview fixture 需要）。

**Spec source:** `kline_trainer_plan_v1.5.md` §6.1.3 (L871-895) + `kline_trainer_modules_v1.4.md` §U6 (L2094-2103)。

**Constraint reminders (per Wave 1 outline v20 §3.2 + memory `feedback_planner_packaging_bias`):**
- ≤ 3 sub-items (this plan: 3 Tasks)
- ≤ 500 行 prod (this plan: ~200 行 prod estimate；与 U3/U5 同档 UI 壳)
- review budget: opus 4.7 xhigh 双闸门各 4-5 轮内收敛（user 本次显式指定走 opus 不走 codex）
- `cd ios/Contracts && swift test` 是 macOS host 命令；Mac Catalyst 用 `xcodebuild ... build-for-testing`（§15.1 #3 闸门）
- Working branch：执行阶段由 `superpowers:using-git-worktrees` 创建；**push/PR 前必跑 `pwd` + `git branch --show-current` + `git rev-parse HEAD` 三连确认**（per memory `feedback_worktree_cwd_drift`：EnterWorktree 后 `cd 主仓 && ...` 会把 cwd 永久漂回主仓，曾误推 main HEAD 到远端分支）

---

## 背景与既有接缝（实施者必读）

- **`TrainingRecord` 形状已冻结**（`ios/Contracts/Sources/KlineTrainerContracts/AppState.swift` L19-60，**Codable + Equatable + Sendable**，本 PR **不动该文件**）。本 PR 仅读取 `stockName: String` + `stockCode: String` 两字段拼标题；其余 13 字段不被本 View 显示（见 D3 决议）。
- **`FeeSnapshot` 形状**（`ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` L143-151）：`init(commissionRate: Double, minCommissionEnabled: Bool)`。仅 preview fixture 构造 `TrainingRecord` 时需要（DEBUG-only）。
- **SwiftUI 跨平台可用**：`ios/Contracts/Package.swift` 已声明 `.iOS(.v17), .macOS(.v14)`，SwiftUI 在两个 platform + Mac Catalyst 均可 `import SwiftUI`（不需要 `#if canImport(UIKit)` 守卫，见 D1）。
- **现有 UI/ 目录已存在**（PR #70 U3 + PR #71 U5 落地）：`ios/Contracts/Sources/KlineTrainerContracts/UI/` 下有 `SettlementContent.swift` / `SettlementView.swift` / `PositionPickerContent.swift` / `PositionPickerView.swift`。本 PR 在同目录新增 2 个 swift 文件（`HistoryActionContent.swift` + `HistoryActionSheet.swift`），**不动 U3/U5 现有文件**。
- **`U3 SettlementContent.formatStock` 存在但不复用**（见 D4）：`SettlementContent.formatStock(name:code:)` 是 internal static func（同模块可见），但本 PR **不调用**它——each UI Content 自包含，避免 sibling UI content 类型间耦合（U5 PositionPickerContent 同样未复用 U3 任何东西）。
- **`U3 SettlementView` 内有 `fileprivate extension TrainingRecord { static func preview() }`**（L76-98），但 **`fileprivate` = 文件作用域，本文件不可见**；本 PR 各自内联自己的 `fileprivate extension TrainingRecord.preview()`（见 D11；两个 `fileprivate` 同名扩展不冲突，因均文件作用域——U3 D9 注释已预期"各自 fileprivate 内联各自 fixture"）。
- **测试基线**：当前 **529 tests / 101 suites**（macOS host `swift test`，PR #71 U5 merge 后 per memory 实测 529/101）。本 PR 目标 **+10 host 测试**（Task 1 = HistoryActionContentTests 一个 suite）→ **共 +10 / 总 ≥539 / ≥102 suites**。**baseline 走宽松正则锚**（per U3/U5 既定 mode）：grep `"Test run with [0-9]+ tests? in [0-9]+ suites? passed"` 不硬锁 N；prose "N≥539 / M≥102" 仅给人读，验收 gate 不硬锁。Task 2 = SwiftUI shell 仅编译验证，**0 新测试**（参 U3/U5/C5/C6 mode）。Task 3 = 验收 doc/script，0 新测试。
- **不依赖 Wave 0/1/2 任何运行时单例**：HistoryActionSheet 是纯展示组件，仅依赖 `TrainingRecord` + `FeeSnapshot`（均已冻 Wave 0 F1/M0.3）。**不依赖 E4 TrainingFlowController runtime code**（outline v20 顺位 15 row 标 "依赖 E4" 是指**语义依赖**：caller 用 onReview/onReplay 路由到 Review/Replay TrainingFlowController；本 PR 不引 import，见 D12）。

---

## Task 0 — §15.3 评审策略前置 + spec 偏差裁决

per `docs/governance/wave1-plan-template.md`：本 plan 使用哪些评审形式。

- [ ] **局部对抗性评审（必）**：本 plan U6 scope 内 **Claude Opus 4.7 xhigh effort 双闸门**（plan-stage + impl-stage / branch-diff），**不走 codex**（per memory `feedback_openai_quota_ci_pattern` + 用户本次显式 prompt）。4-5 轮内收敛或 escalate（per memory `feedback_codex_plan_budget_overshoot` 同样适用于 opus xhigh review）。
- [x] **集成层评审（N/A）**：C8 `ChartContainerView` 桥接 + U1 `HomeView` 编排在 Wave 2；本 PR 不含集成层。U6 是叶子组件，无下游被桥接 surface。
- [x] **性能评审（N/A）**：plan v1.5 §一 "单帧 <4ms / Instruments" 属 **Phase 5 磨光 PR**；U6 是一次性渲染的小弹窗（无 60Hz 渲染路径），本 PR 不做 Instruments 评审。

### Step ↔ Skill 显式映射（per memory `feedback_workflow_skill_invoke_explicit` —— PR #67 教训第 6 次复现预防）

本 PR 实施序列对应的 Superpowers skill：

| 阶段 | Skill | 何时调 | 何时**不**用 raw Agent 替代 |
|---|---|---|---|
| Plan-stage adversarial review | （主线 dispatch fresh opus 4.7 xhigh subagent，无对应 skill 名；按 `adversarial-review-template.md` 给 prompt） | plan 写完后、Task 1 开工前 | 主线必须 dispatch 新 agent；不能在主线自审 |
| Task 1-3 实施 | `superpowers:subagent-driven-development` | 每 Task fresh sonnet 4.6 high subagent + paired sonnet reviewer 双道 | 不用 raw Agent；不在主线自写 |
| Verification | `superpowers:verification-before-completion` | Task 3 acceptance script 跑完前最终验证 | 不在主线自宣"绿了" |
| Self-review | `superpowers:requesting-code-review` | 整体 branch-diff review 前 | 不跳 |
| Branch-diff adversarial review | （主线 dispatch fresh opus 4.7 xhigh subagent）| 全部实施完 + self-review 后 + push PR 前 | 主线必须 dispatch 新 agent |

完成 Task 0 才进 Task 1 实施（仅"局部对抗性评审"项为可执行待办，2 项 N/A 已预勾声明）。

### Spec 偏差裁决（D1-D14，全部写进代码注释 + 验收 §J）

| # | 偏差/歧义 | 裁决 | 权威依据 |
|---|---|---|---|
| **D1** | 落到 SwiftUI 还是 UIKit | **SwiftUI**：modules §U6 L2097 字面 `struct HistoryActionSheet: View` → SwiftUI；SwiftUI 跨 iOS 17+ macOS 14+ Catalyst 三平台原生支持，**不**加 `#if canImport(UIKit)` 守卫。 | modules §U6 L2097 字面 + Package.swift platforms 声明 |
| **D2** | 落 "提示框"的 SwiftUI 形态：`.confirmationDialog` 修饰符 vs 内容 View | **内容 View（VStack of Button），由 caller 呈现**：modules §U6 init 签名是 `struct HistoryActionSheet: View { init(record:onReview:onReplay:onCancel:) }`——**无 Binding 参数**，故它是一个由 caller 装进 sheet/popover 呈现的内容视图（与 U3 SettlementView / U5 PositionPickerView 严格同款），不是挂在别的 view 上的 `.confirmationDialog` modifier（后者需要 `isPresented` Binding，与 init 签名不符）。 | modules §U6 L2097-2102 字面（无 Binding）+ U3/U5 既定 mode |
| **D3** | 弹窗从 `record` 显示什么内容 | **单个标题 = 股票名（代码）全角括号**（如 "贵州茅台（600519）"），不显示其余 13 字段。理由：(1) 弹窗背后的历史行（spec §6.1.3 L879-880）已展示完整明细（日期/起始/总资金/盈亏/收益率），弹窗职责是「确认点的是哪条 + 提供 2 个动作」，重复明细是冗余；(2) modules init 字面带 `record: TrainingRecord` 参数 → View 必须消费它做显示（否则 record 形参未用 = 编译警告 + 评审质疑），最小且最具识别性的消费 = 股票标识。**Residual（已知 + 接受）**：同股票多局训练时单股票名不能区分具体哪局；但 iOS sheet/popover 视觉锚定被点的行（行仍可见）→ 用户知道点的是哪条；对抗性 reviewer 若坚持加起始年月可在 v2 吸收，起始最小是正确默认（CLAUDE.md §2 Simplicity / 不加 spec 未要求的字段）。 | modules §U6 L2098 字面 `record:` + spec §6.1.3 L879-880 行明细 + CLAUDE.md §2 |
| **D4** | 标题格式化逻辑放哪 / 是否复用 U3 `SettlementContent.formatStock` | **自包含 `HistoryActionContent` 纯值类型（仅 import Foundation）内置 `formatStock`，不复用 U3**：理由 (1) U5 `PositionPickerContent` 同样未复用 U3 任何 helper——each UI Content 自包含是既定 precedent；(2) `SettlementContent.formatStock` 是 internal（同模块可见），跨 sibling UI content 类型调用会制造耦合（U3 改 formatStock 行为会暗中影响 U6），比一行 `"\(name)（\(code)）"` 重复更糟（CLAUDE.md §3 + "三行相似代码胜过过早抽象"）；(3) 标题格式化是 U6 **唯一**的逻辑——抽到 host-testable 纯值类型 = 跟 U3/U5 同 precedent + 避免在不做单测的 SwiftUI shell 里留未测格式化逻辑。 | U5 precedent（不复用 U3）+ CLAUDE.md §2/§3 |
| **D5** | 括号字符 | **全角 `（` U+FF08 / `）` U+FF09**（与 SettlementContent D7 同款，spec §6.1.3 L880 字面 "贵州茅台（600519）"）。Task 1 测试断言精确全角字符（含「不含 ASCII `(`/`)`」反向断言）。 | spec L880 字面 + U3 D7 同款 |
| **D6** | 按钮个数 + 顺序 | **三个按钮 = 复盘 → 再来一次 → 取消，取消置底**。理由：spec §6.1.3 表先列「复盘」后列「再来一次」（L893/L894）；「取消」按钮补满 modules init 字面 `onCancel: () -> Void` 契约（弹窗必须有触发 onCancel 的元素；不能仅依赖 caller-installed dismiss——caller 可能用 popover / 自定义 overlay 不带 sheet 取消语义）。取消置底符合 iOS 惯例。**机制与 U5 D6 取消按钮同款**。 | spec §6.1.3 L893/L894 + modules §U6 L2101 字面 + View 自包含原则 |
| **D7** | 按钮文案 | **"复盘" / "再来一次" / "取消"**（spec §6.1.3 L893 "复盘" + L894 "再来一次" 字面 + modules init `onCancel` → "取消"）。 | spec §6.1.3 L893/L894 字面 |
| **D8** | 按钮样式 / 颜色 | **三个按钮全 `.bordered`，不分盈亏色 / 不 RGB 硬编码 / 不用 `.borderedProminent` 在「复盘」「再来一次」间暗示主次**（两者均为合法用户选择，无优先级）。默认 SwiftUI Button style。同 U3 D2 / U5 D16 simplicity 原则。 | spec §6.1.3 不规定颜色 + CLAUDE.md §2 + U5 D16 同款 |
| **D9** | spec 字面 `onReview/onReplay/onCancel: () -> Void` vs 落地 `@escaping` | **落地必须 `@escaping`**：SwiftUI `View` init 把三个 closure 存为 `private let` 然后在 body Button 间接调用 → Swift 编译要求 store-and-defer-call 的 closure 形参必须 `@escaping`。spec 闭包类型形态是契约（caller 视角可调用性）；落地附加 `@escaping` 是 Swift 闭包逃逸语义的强制要求，不改变契约形状。**不加 `@Sendable`**（U3 D12 / U5 D11 同款：闭包随 SwiftUI `View` 协议合成 `@MainActor` 隔离运行，不跨 actor 边界；加 `@Sendable` 会过度收紧 caller 闭包形状）。 | modules §U6 L2099-2101 字面 + Swift 编译约束 + U3 D12 / U5 D11 同款 |
| **D10** | SwiftUI shell 是否单元测试 | **不单测**，只跑 Mac Catalyst build-for-testing SUCCEEDED 闸门（含 macOS host swift test 与 iOS Catalyst 两套编译）+ visual preview。理由：SwiftUI 内部断言要 ViewInspector / 类似第三方库，引入新 SwiftPM 依赖 vs **零业务逻辑 view 单测收益极低**；所有可测逻辑全在 `HistoryActionContent`（Task 1，host 全测）。参 U3/U5/C5/C6 mode。 | U3/U5/C5/C6 既定 mode + CLAUDE.md §2 |
| **D11** | Preview Fixture：复用 U3 `TrainingRecord.preview()` 还是各自内联 | **各自内联 `fileprivate extension TrainingRecord { static func preview() -> TrainingRecord }` 于 `HistoryActionSheet.swift` 的 `#if DEBUG` 区**。理由：U3 的 `preview()` 是 `fileprivate`（文件作用域）→ 本文件**不可见**，无法复用；不抽到 `PreviewFakes/`（refactor 未被要求 + public extension 跨模块污染下游 DEBUG 编译，U3 R1-H4 已裁定）；两个文件各有 `fileprivate extension TrainingRecord.preview()` **不冲突**（均文件作用域，Swift 允许；U3 D9 注释明确预期"各自 fileprivate 内联各自 fixture"）。**机制与 U3 D9 / U5 D9 严格同款**，使 §H 反向 grep `^public.*extension TrainingRecord` 在本 prod 文件真有目标可禁。 | U3 D9 + R1-H4 + U5 D9 严格同款机制 + CLAUDE.md §2/§3 |
| **D12** | 不依赖 E4 TrainingFlowController runtime | **本 PR 不 import E4 任何 prod 类型 / 函数 / 不引 `TrainingMode`**；outline v20 顺位 15 row 标"依赖 E4"是**语义依赖**（caller 用 onReview → 路由到 Review 模式 TrainingFlowController，onReplay → Replay 模式），不是代码依赖。grep `TrainingFlowController` / `TrainingMode` / `NormalFlow` / `ReviewFlow` / `ReplayFlow` 在 U6 prod 文件应为 0 命中。 | outline v20 §二 + 叶子组件硬约束 + U5 D14 同款 |
| **D13** | View 是否调 dismiss | **不调**：spec 没有"View 自己关闭"语义；面板消失由 caller-installed presentation container 负责。View body 三个 Button 仅 fire 对应 callback。grep `dismiss()` / `@Environment(\.dismiss)` 在 U6 prod 应为 0 命中。同 U5 D15。 | U5 D15 同款 + caller-presentation 边界 |
| **D14** | Content 数据结构 shape + 快照语义 | **`HistoryActionContent: Equatable, Sendable` 含单个 `title: String` + `init(record: TrainingRecord)` + `static func formatStock(name:code:) -> String`**。值快照：init 时一次性算 title，不持引用观察 record 变更（`Sendable` + `Equatable` 值类型保证）。`static func` 便于 `Self.formatStock` 调用避免实例方法 capture（与 SettlementContent 同 idiom）。 | Swift 类型设计 + U3 SettlementContent / U5 PositionPickerContent 同 idiom |

---

## File Structure

### Production (2 files, ~150 行)

| 路径 | 动作 | 行数 | 职责 |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift` | **新建** | ~40 | 纯值类型 `public struct HistoryActionContent: Equatable, Sendable`，含 `title: String` + `init(record: TrainingRecord)`（D3 仅取 stockName/stockCode）+ `static func formatStock(name:code:) -> String`（D4/D5 全角括号）。**平台无关**：仅 `import Foundation`（不 import SwiftUI / UIKit / CoreGraphics）。 |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | **新建** | ~110 | SwiftUI shell `public struct HistoryActionSheet: View`，`init(record: TrainingRecord, onReview: @escaping () -> Void, onReplay: @escaping () -> Void, onCancel: @escaping () -> Void)`，body 用 `HistoryActionContent(record:)` 拿 title 渲染 Text 标题 + 三个 Button（复盘/再来一次/取消，D6/D7/D8）；DEBUG-only `#Preview` macro + `fileprivate extension TrainingRecord.preview()`（D11）。 |

### Tests (1 file, ~140 行)

| 路径 | 动作 | 行数 | 测试 |
|---|---|---|---|
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionContentTests.swift` | **新建** | ~140 | 10 host 测试覆盖：formatStock 基础 + 边界 4 tests / 全角括号字符 2 tests / Content.init 连线 1 test / Equatable 2 tests / Sendable 1 test。详见 Task 1 Step 1。 |

### Docs (1 file)

| 路径 | 动作 | 内容 |
|---|---|---|
| `docs/acceptance/2026-05-29-pr-u6-history-action-sheet.md` | **新建** | ~120 行中文非程序员验收清单（10 节 §A-§J 含字面 grep / suite count / Catalyst build / 文件存在 / RGB 反向 grep / 决议落地） |

### Scripts (1 file)

| 路径 | 动作 | 内容 |
|---|---|---|
| `scripts/acceptance/plan_u6_history_action_sheet.sh` | **新建** | 机检 bash：与 acceptance §A-§J 对齐的 ≥12 项 grep / test / build 自动跑（参 `plan_u5_position_picker_view.sh` 同款；**负向断言用 `if grep -q ...; then echo FAIL; exit 1; fi` 不用 `! grep`**，per memory `feedback_acceptance_grep_anchoring`）。 |

**Total: 2 prod + 1 test + 1 doc + 1 script = 5 文件 / ~150 prod / ~140 test / 10 新测试。**

---

## Task 1 — `HistoryActionContent` 纯值类型 + 10 host 测试

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionContentTests.swift`

- [ ] **Step 1: 写失败测试 — `HistoryActionContentTests.swift`**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionContentTests.swift
// Spec: kline_trainer_plan_v1.5.md §6.1.3 L871-895 + plan 2026-05-29-pr-u6-history-action-sheet.md Task 1
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("HistoryActionContent host tests")
struct HistoryActionContentTests {

    // MARK: - 共享 fixture helper（测试内 internal，不污染 prod）

    private func makeRecord(stockName: String, code: String) -> TrainingRecord {
        TrainingRecord(
            id: 1,
            trainingSetFilename: "t.sqlite",
            createdAt: 1_700_000_000,
            stockCode: code,
            stockName: stockName,
            startYear: 2021,
            startMonth: 8,
            totalCapital: 100_000,
            profit: 0,
            returnRate: 0,
            maxDrawdown: 0,
            buyCount: 0,
            sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 1000
        )
    }

    // MARK: - D4/D5 formatStock 基础 + 边界

    @Test("D4/D5 formatStock 基础：name（code）全角括号")
    func formatStockBasic() {
        #expect(HistoryActionContent.formatStock(name: "贵州茅台", code: "600519") == "贵州茅台（600519）")
    }

    @Test("D4/D5 formatStock 另一只股票")
    func formatStockAnotherStock() {
        #expect(HistoryActionContent.formatStock(name: "宁德时代", code: "300750") == "宁德时代（300750）")
    }

    @Test("D5 formatStock 空 name → （code）")
    func formatStockEmptyName() {
        #expect(HistoryActionContent.formatStock(name: "", code: "600519") == "（600519）")
    }

    @Test("D5 formatStock 空 code → name（）")
    func formatStockEmptyCode() {
        #expect(HistoryActionContent.formatStock(name: "贵州茅台", code: "") == "贵州茅台（）")
    }

    // MARK: - D5 全角括号字符精确（防 ASCII 括号回归）

    @Test("D5 title 含全角左右括号 U+FF08 / U+FF09")
    func titleContainsFullWidthParens() {
        let title = HistoryActionContent.formatStock(name: "贵州茅台", code: "600519")
        #expect(title.contains("（"))  // U+FF08
        #expect(title.contains("）"))  // U+FF09
    }

    @Test("D5 title 不含 ASCII 半角括号 ( / )")
    func titleHasNoAsciiParens() {
        let title = HistoryActionContent.formatStock(name: "贵州茅台", code: "600519")
        #expect(!title.contains("("))  // ASCII U+0028
        #expect(!title.contains(")"))  // ASCII U+0029
    }

    // MARK: - D3/D14 Content.init 从 record 连线 title

    @Test("D3 Content.init 用 record.stockName + stockCode 拼 title")
    func contentInitWiresTitleFromRecord() {
        let r = makeRecord(stockName: "贵州茅台", code: "600519")
        let c = HistoryActionContent(record: r)
        #expect(c.title == "贵州茅台（600519）")
        #expect(c.title == HistoryActionContent.formatStock(name: r.stockName, code: r.stockCode))
    }

    // MARK: - Equatable

    @Test("Equatable：同 stockName/stockCode 的 record → Content 相等")
    func equatableSameStockEqual() {
        let c1 = HistoryActionContent(record: makeRecord(stockName: "贵州茅台", code: "600519"))
        let c2 = HistoryActionContent(record: makeRecord(stockName: "贵州茅台", code: "600519"))
        #expect(c1 == c2)
    }

    @Test("Equatable：不同股票 → Content 不相等")
    func equatableDifferentStockNotEqual() {
        let c1 = HistoryActionContent(record: makeRecord(stockName: "贵州茅台", code: "600519"))
        let c2 = HistoryActionContent(record: makeRecord(stockName: "宁德时代", code: "300750"))
        #expect(c1 != c2)
    }

    // MARK: - Sendable

    @Test("Content 是 Sendable（compile-time conformance）")
    func contentIsSendable() {
        let c = HistoryActionContent(record: makeRecord(stockName: "贵州茅台", code: "600519"))
        let _: any Sendable = c
    }
}
```

- [ ] **Step 2: 跑测试确认全 fail（编译错或测试 fail —— 关键是 exit ≠ 0）**

Run:
```bash
cd ios/Contracts
swift test --filter HistoryActionContentTests > /tmp/u6-red.txt 2>&1
echo "exit=$?"
grep -iE "error:|cannot find|undeclared" /tmp/u6-red.txt | head -3
```
Expected: `exit=` 非 0 + 至少 1 行 error / cannot find / undeclared 命中（`HistoryActionContent` 未定义）。**用 exit code 不依赖 wording**（同 U3 R1-M4 / U5 教训）。

- [ ] **Step 3: 写最小实现 — `HistoryActionContent.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift
// Spec: kline_trainer_plan_v1.5.md §6.1.3 L871-895 + plan 2026-05-29-pr-u6-history-action-sheet.md
//
// 平台无关纯值类型：把 TrainingRecord 翻译成历史动作表显示用的单个标题字符串。
// 平台守卫：仅 import Foundation，不 import SwiftUI/UIKit/CoreGraphics —— host swift test 全测。
//
// 决议（D3-D5/D14）：
// - D3 弹窗只显示识别本条记录的标题（股票名（代码）），不重复历史行已有的明细字段
// - D4 自包含 formatStock，不复用 U3 SettlementContent.formatStock（避免 sibling UI content 耦合）
// - D5 全角括号 （ U+FF08 / ） U+FF09（spec §6.1.3 L880 字面）
// - D14 值快照：init 一次性算 title；static func 便于 Self. 调用

import Foundation

public struct HistoryActionContent: Equatable, Sendable {
    public let title: String   // "贵州茅台（600519）"

    public init(record: TrainingRecord) {
        self.title = Self.formatStock(name: record.stockName, code: record.stockCode)
    }

    /// D4/D5：name（code），全角括号。
    static func formatStock(name: String, code: String) -> String {
        "\(name)（\(code)）"
    }
}
```

- [ ] **Step 4: 跑测试确认 10 全绿**

Run: `cd ios/Contracts && swift test --filter HistoryActionContentTests 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中模式 `Test run with N tests in M suites passed after X seconds.`（**宽松正则锚**不硬锁 N=10/M=1；语义检验 N≥10，M=1）。

加成 strong gate：跑退出码 == 0：
```bash
cd ios/Contracts && swift test --filter HistoryActionContentTests > /tmp/u6-green.txt 2>&1
echo "exit=$?"
```
Expected: `exit=0`。

如某测试 fail，按测试失败信息修代码（不动测试断言），重跑直到全绿；不能修改测试断言来对齐错误实现。

- [ ] **Step 5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionContentTests.swift
git commit -m "feat(u6): HistoryActionContent 纯值类型 + 10 host 测试 (Task 1)

Spec §6.1.3 L871-895：弹窗标题 = 股票名（代码）全角括号（D3 仅取
stockName/stockCode 识别本条记录，不重复历史行明细；D5 全角括号 U+FF08/FF09）。
自包含 formatStock 不复用 U3（D4）。本 PR scope 仅纯函数 + 测试，
SwiftUI shell 在 Task 2 落地。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 — `HistoryActionSheet` SwiftUI shell + DEBUG preview fixture

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift`

> 本 Task 不加新测试（per D10）；Mac Catalyst build-for-testing SUCCEEDED 是编译闸门。

- [ ] **Step 1: 写实现 — `HistoryActionSheet.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift
// Spec: kline_trainer_modules_v1.4.md §U6 L2094-2103 字面 init 签名 +
//       kline_trainer_plan_v1.5.md §6.1.3 L871-895 历史记录点击弹窗
//
// 薄 SwiftUI shell：body 仅装配 VStack/Button；标题映射交 HistoryActionContent（Task 1）。
//
// 决议（D1/D2/D6-D13）：
// - D1 SwiftUI 跨 iOS17/macOS14/Catalyst 三平台原生支持，不加 #if canImport(UIKit)
// - D2 内容 View（无 Binding），由 caller 装进 sheet/popover 呈现
// - D6 三按钮：复盘 / 再来一次 / 取消（取消置底；取消补满 init onCancel 契约）
// - D7 按钮文案字面 复盘 / 再来一次 / 取消
// - D8 三按钮 .bordered，不分盈亏色 / 不 RGB 硬编码 / 不用 .borderedProminent 暗示主次
// - D9 onReview / onReplay / onCancel 闭包 @escaping（Swift 编译强制）；不加 @Sendable
// - D10 不单测 SwiftUI shell，靠 Catalyst build-for-testing 闸门
// - D11 fileprivate extension TrainingRecord.preview() 内联本文件 #if DEBUG 区，不污染 PreviewFakes
// - D12 仅语义依赖 E4（caller 用 onReview/onReplay 路由 Review/Replay 模式）；本文件不引业务运行时类型
// - D13 Button tap 仅 fire callback，不调 dismiss（caller 负责 presentation）

import SwiftUI

public struct HistoryActionSheet: View {
    private let content: HistoryActionContent
    private let onReview: () -> Void
    private let onReplay: () -> Void
    private let onCancel: () -> Void

    public init(record: TrainingRecord,
                onReview: @escaping () -> Void,
                onReplay: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.content = HistoryActionContent(record: record)
        self.onReview = onReview
        self.onReplay = onReplay
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // D3: 标题 = 股票名（代码），识别本条记录
            Text(content.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)

            // D6: 复盘 → onReview
            Button(action: onReview) {
                Text("复盘")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            // D6: 再来一次 → onReplay
            Button(action: onReplay) {
                Text("再来一次")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            Spacer().frame(height: 8)

            // D6: 取消置底 → onCancel（补满 modules §U6 init 字面要求）
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

// MARK: - DEBUG-only preview fixture (D11 — fileprivate extension 防跨模块污染，机制与 U3/U5 同款)

#if DEBUG
fileprivate extension TrainingRecord {
    /// Preview fixture。决议 D11：**fileprivate** 文件作用域，与 U3 SettlementView 内同名 fixture 不冲突
    /// （均文件作用域，Swift 允许）；不抽到 PreviewFakes（public 会污染下游 DEBUG 编译，U3 R1-H4 同款）。
    static func preview() -> TrainingRecord {
        TrainingRecord(
            id: 1,
            trainingSetFilename: "preview.sqlite",
            createdAt: 1_700_000_000,
            stockCode: "600519",
            stockName: "贵州茅台",
            startYear: 2021,
            startMonth: 8,
            totalCapital: 102_345.67,
            profit: 2_345.67,
            returnRate: 0.0234,
            maxDrawdown: -0.0832,
            buyCount: 4,
            sellCount: 3,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 1000
        )
    }
}

#Preview {
    HistoryActionSheet(
        record: .preview(),
        onReview: {},
        onReplay: {},
        onCancel: {}
    )
}
#endif
```

- [ ] **Step 2: 跑 macOS host swift test 确认零回归**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中模式，N≥539，M≥102（baseline 529/101 + Task 1 加 10/1 = 539/102；宽松正则锚不硬锁）。强 gate 用退出码：`swift test > /tmp/u6-zero-regression.txt 2>&1; echo "exit=$?"` 期望 `exit=0`。

- [ ] **Step 3: 跑 Mac Catalyst build-for-testing SUCCEEDED**

Run:
```bash
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/u6-derived \
           build-for-testing 2>&1 | tail -5 | tee /tmp/u6-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/u6-build-tail.txt && echo "✅ Catalyst PASS"
```
Expected: `TEST BUILD SUCCEEDED` 命中。若失败：常见原因是 SwiftUI iOS-only API 在 Catalyst 不支持 —— 修代码不修平台守卫（spec D1 明确 SwiftUI 跨三平台）。

- [ ] **Step 4: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift
git commit -m "feat(u6): HistoryActionSheet SwiftUI shell + #Preview fixture (Task 2)

薄 shell：body 消费 HistoryActionContent.title 标题 + 三按钮（D6 复盘/再来一次/取消）；
spec §U6 L2097-2102 字面 init 签名（D1 SwiftUI；D9 三 callback @escaping）。
fileprivate preview fixture 内联（D11）；不污染 PreviewFakes。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 — acceptance doc + 机检脚本

**Files:**
- Create: `docs/acceptance/2026-05-29-pr-u6-history-action-sheet.md`
- Create: `scripts/acceptance/plan_u6_history_action_sheet.sh`

> 本 Task 不加新测试。

- [ ] **Step 1: 写 acceptance doc**

新建 `docs/acceptance/2026-05-29-pr-u6-history-action-sheet.md`，**完整内容**：

````markdown
# PR U6 验收清单（中文非程序员可执行）

> Wave 1 顺位 15 / 交付序第 17 个 PR。spec `kline_trainer_plan_v1.5.md` §6.1.3 + `kline_trainer_modules_v1.4.md` §U6。
> plan `docs/superpowers/plans/2026-05-29-pr-u6-history-action-sheet.md`。

## §A 文件存在

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| A.1 | `ls ios/Contracts/Sources/KlineTrainerContracts/UI/` | HistoryActionContent.swift / HistoryActionSheet.swift 两个新文件（+ Settlement*/PositionPicker* 老的 4 个） | 全部存在 |
| A.2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/UI/` | HistoryActionContentTests.swift（+ 老的 SettlementContentTests / PositionPickerContentTests） | 存在 |
| A.3 | `test -f scripts/acceptance/plan_u6_history_action_sheet.sh && echo OK` | OK | 输出 OK |

## §B 编译 + 全量测试（macOS host）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| B.1 | `cd ios/Contracts && swift build 2>&1 \| tail -3` | `Build complete!` | 命中 |
| B.2 | `cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests in [0-9]+ suites passed"` | 一行命中模式（基线 529/101 + 本 PR +10/+1 = 期望 539/102，但 grep 宽松不硬锁 N/M） | 命中模式 + `swift test` exit=0 |

## §C Catalyst 编译闸门（§15.1 #3）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| C.1 | `cd ios/Contracts && xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/u6-derived build-for-testing 2>&1 \| tail -5` | `TEST BUILD SUCCEEDED` | 命中 |

## §D 新 suite 全绿

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| D.1 | `cd ios/Contracts && swift test --filter HistoryActionContentTests 2>&1 \| grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"` | 一行命中模式（期望 N≥10/M=1） | 命中模式 + `swift test --filter HistoryActionContentTests` exit=0 |

## §E spec 字面 grep 锚（D1-D13 落地 — 防 spec drift）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'public struct HistoryActionContent: Equatable, Sendable' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift` | 1 hit | 数字 = 1 |
| E.2 | `grep -nc 'public struct HistoryActionSheet: View' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit | 数字 = 1 |
| E.3 | `grep -nc 'init(record: TrainingRecord,' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit | 数字 = 1 |
| E.4 | `grep -nc 'onReview: @escaping () -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D9) | 数字 = 1 |
| E.5 | `grep -nc 'onReplay: @escaping () -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D9) | 数字 = 1 |
| E.6 | `grep -nc 'onCancel: @escaping () -> Void' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D6 + D9) | 数字 = 1 |
| E.7 | `grep -nc 'Text("复盘")' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D7 spec L893 — anchor SwiftUI body literal，非 header 注释里同字符串) | 数字 = 1 |
| E.8 | `grep -nc 'Text("再来一次")' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D7 spec L894 body literal) | 数字 = 1 |
| E.9 | `grep -nc 'Text("取消")' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D6/D7 取消按钮 label body literal) | 数字 = 1 |
| E.10 | `grep -nc 'Button(action: onReview)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (复盘按钮真接 onReview callback) | 数字 = 1 |
| E.11 | `grep -nc 'Button(action: onReplay)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (再来一次按钮真接 onReplay callback) | 数字 = 1 |
| E.12 | `grep -nc 'Button(action: onCancel)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (取消按钮真接 onCancel callback) | 数字 = 1 |
| E.13 | `grep -nc 'Text(content.title)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D3 标题来自 Content) | 数字 = 1 |
| E.14 | `grep -nc 'Self.formatStock(name: record.stockName, code: record.stockCode)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift` | 1 hit (D3/D4 标题映射) | 数字 = 1 |

## §F 不依赖 Wave 0/1/2 业务运行时（叶子组件硬约束 + D12）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nE 'import (GRDB\|ZIPFoundation)' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 | 输出为空 |
| F.2 | `grep -nE 'TradeCalculator\|TickEngine\|PositionManager\|TrainingFlowController\|TrainingMode\|NormalFlow\|ReviewFlow\|ReplayFlow\|APIClient' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 (D12 — 含 E4 三 flow 类型) | 输出为空 |
| F.3 | `grep -ncE '^import SwiftUI$' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift` | 0 hit (Content 平台无关；锚 `^import SwiftUI$` 行首避免命中注释里"不 import SwiftUI"子串) | 数字 = 0 |
| F.4 | `grep -ncE '^import SwiftUI$' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (View 才真 import SwiftUI；锚行首) | 数字 = 1 |

## §G 无 RGB 硬编码 / 无 D8 反例（盈亏色未实现）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -nE 'Color\(red:\|UIColor\(' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 | 输出为空 |
| G.2 | `grep -nE '\.foregroundStyle\(\.red\|\.foregroundStyle\(\.green' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 (D8：不分盈亏色) | 输出为空 |
| G.3 | `grep -nc 'borderedProminent' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 0 hit (D8：三按钮全 .bordered，不用 borderedProminent 暗示主次) | 数字 = 0 |

## §H DEBUG-only preview 隔离（D11 — fileprivate 防跨模块污染）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| H.1 | `grep -ncE '^#if DEBUG$' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (锚 `^#if DEBUG$` 行首避免命中注释里同子串) | 数字 = 1 |
| H.2 | `grep -nc '#endif' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | ≥ 1 hit (DEBUG 配对) | 数字 ≥ 1 |
| H.3 | `grep -nc 'fileprivate extension TrainingRecord' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 1 hit (D11 机制 = fileprivate extension TrainingRecord，与 U3 严格同款) | 数字 = 1 |
| H.4 | `grep -ncE '^public.* extension TrainingRecord\|^extension TrainingRecord.*public' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 0 hit (D11 拒绝 public 跨模块污染) | 数字 = 0 |
| H.5 | `grep -nc 'extension TrainingRecord\|TrainingRecord.preview' ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | 0 hit (本 PR 不动 PreviewFakes — D11) | 数字 = 0 |
| H.6 | `grep -nc 'static func formatStock' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (U3 既有；证明本 PR 不动 U3 — D4 不复用) | 数字 = 1 |

## §I caller-presentation 边界（D13 — View 不调 dismiss）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| I.1 | `grep -nE 'dismiss\(\)\|@Environment\(\\.dismiss' ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | 无命中 (View 不调 dismiss；caller 负责 presentation container) | 输出为空 |

## §J 机检脚本自身

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_u6_history_action_sheet.sh 2>&1 \| tail -2` | `所有 12 项 G1-G12 验收通过` | 末行 ✅ + 0 exit code |
````

- [ ] **Step 2: 写机检脚本 — `plan_u6_history_action_sheet.sh`**

```bash
#!/usr/bin/env bash
# Wave 1 顺位 15 (U6 HistoryActionSheet) 机检验收
# 用法：bash scripts/acceptance/plan_u6_history_action_sheet.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

CONTENT=ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift
SHEET=ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift

echo "== G1: U6 源文件 + 测试文件 + 验收 doc 存在 =="
test -f "$CONTENT"
test -f "$SHEET"
test -f ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionContentTests.swift
test -f docs/acceptance/2026-05-29-pr-u6-history-action-sheet.md

echo "== G2: HistoryActionContent 平台无关（仅 import Foundation；不 import SwiftUI/UIKit/CoreGraphics）=="
grep -q "^import Foundation$" "$CONTENT"
# 负向断言用 if/exit 1（per feedback_acceptance_grep_anchoring：`! grep` 在 set -e 下被豁免=死闸门）
if grep -qE "^import (SwiftUI|UIKit|CoreGraphics)$" "$CONTENT"; then
  echo "G2 FAIL: Content 不应 import SwiftUI/UIKit/CoreGraphics"; exit 1
fi

echo "== G3: spec §U6 字面 init 签名（D1/D9）=="
grep -q "public struct HistoryActionSheet: View" "$SHEET"
grep -q "init(record: TrainingRecord," "$SHEET"
grep -q "onReview: @escaping () -> Void" "$SHEET"
grep -q "onReplay: @escaping () -> Void" "$SHEET"
grep -q "onCancel: @escaping () -> Void" "$SHEET"

echo "== G4: spec §6.1.3 字面文案 + 三按钮真接对应 callback（D6/D7）=="
# anchor Text("…") body literal，避免命中 header 注释中相同字符串
grep -q 'Text("复盘")' "$SHEET"
grep -q 'Text("再来一次")' "$SHEET"
grep -q 'Text("取消")' "$SHEET"
grep -q 'Button(action: onReview)' "$SHEET"
grep -q 'Button(action: onReplay)' "$SHEET"
grep -q 'Button(action: onCancel)' "$SHEET"

echo "== G5: D3/D4/D5 标题映射字面落地 =="
grep -q "public struct HistoryActionContent: Equatable, Sendable" "$CONTENT"
grep -q "static func formatStock(name: String, code: String)" "$CONTENT"
grep -q "Self.formatStock(name: record.stockName, code: record.stockCode)" "$CONTENT"
grep -q 'Text(content.title)' "$SHEET"
# D5 全角括号正确性由 Task 1 host 测试 titleContainsFullWidthParens / titleHasNoAsciiParens 真断言守护
# （此处不 grep 源码字面：`\(code)` 在 BRE 下会被当捕获组，-F 又难锚定，host 测试是权威闸门）

echo "== G6: D8 不实现盈亏色 / RGB 硬编码 / borderedProminent（反向验证）=="
if grep -qE '\.foregroundStyle\(\.red|\.foregroundStyle\(\.green' "$SHEET"; then
  echo "G6 FAIL: 不应实现盈亏色 .foregroundStyle(.red/.green)"; exit 1
fi
if grep -qE 'Color\(red:|UIColor\(' "$SHEET"; then
  echo "G6 FAIL: 不应 RGB 硬编码 Color(red:/UIColor("; exit 1
fi
if grep -q 'borderedProminent' "$SHEET"; then
  echo "G6 FAIL: D8 三按钮全 .bordered，不用 borderedProminent 暗示主次"; exit 1
fi

echo "== G7: D12 不引业务运行时 / Content 平台无关 =="
if grep -qE 'import (GRDB|ZIPFoundation)' "$CONTENT" "$SHEET"; then
  echo "G7 FAIL: 不应 import GRDB/ZIPFoundation"; exit 1
fi
# 业务运行时类型不得出现在 prod 源（含注释）；D12 注释已改写不含裸 type token
# R1-F2 修：补 E4 三 flow 类型 NormalFlow/ReviewFlow/ReplayFlow，与 D12 承诺 token 集合对齐
if grep -qE 'TradeCalculator|TickEngine|PositionManager|TrainingFlowController|TrainingMode|NormalFlow|ReviewFlow|ReplayFlow|APIClient' "$CONTENT" "$SHEET"; then
  echo "G7 FAIL: 不应引用业务运行时类型"; exit 1
fi

echo "== G8: D11 DEBUG-only fileprivate extension TrainingRecord preview fixture（与 U3 严格同款，反向锚真有目标）=="
grep -q '^#if DEBUG' "$SHEET"
grep -q "fileprivate extension TrainingRecord" "$SHEET"
grep -q "static func preview() -> TrainingRecord" "$SHEET"
# 反向：不能是 public extension TrainingRecord（会污染下游 DEBUG 编译）
if grep -qE "^public.*extension TrainingRecord|^extension TrainingRecord.*public" "$SHEET"; then
  echo "G8 FAIL: preview fixture extension 不能是 public（会跨模块污染 DEBUG 编译）"; exit 1
fi
# 反向：PreviewFakes 不被本 PR 动
if grep -qE "extension TrainingRecord|TrainingRecord\.preview" \
  ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift; then
  echo "G8 FAIL: 本 PR 不应改 PreviewFakes（D11 各自 fileprivate 内联）"; exit 1
fi

echo "== G9: D13 View 不调 dismiss（caller 负责 presentation）=="
if grep -qE 'dismiss\(\)|@Environment\(.*dismiss' "$SHEET"; then
  echo "G9 FAIL: View 不应调 dismiss() 或 @Environment(\\.dismiss)（caller 负责 presentation）"; exit 1
fi

echo "== G10: swift test 全量 PASS（基线 529 + 本 PR +10 = 期望 ≥539，宽松正则锚）=="
cd ios/Contracts
swift test 2>&1 | tee /tmp/u6-test-full.txt | tail -3
grep -qE "Test run with [0-9]+ tests in [0-9]+ suites passed" /tmp/u6-test-full.txt
cd -

echo "== G11: HistoryActionContentTests 单 suite 全绿（宽松正则锚）=="
cd ios/Contracts
swift test --filter HistoryActionContentTests 2>&1 | tee /tmp/u6-test-suite.txt | tail -3
grep -qE "Test run with [0-9]+ tests? in [0-9]+ suites? passed" /tmp/u6-test-suite.txt
cd -

echo "== G12: Mac Catalyst build-for-testing SUCCEEDED =="
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/u6-derived-final \
           build-for-testing 2>&1 | tail -5 | tee /tmp/u6-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/u6-build-tail.txt
cd -

echo
echo "✅ 所有 12 项 G1-G12 验收通过"
```

加可执行权限：
```bash
chmod +x scripts/acceptance/plan_u6_history_action_sheet.sh
```

- [ ] **Step 3: 跑机检脚本一遍确认全绿**

Run: `bash scripts/acceptance/plan_u6_history_action_sheet.sh 2>&1 | tail -2`
Expected: `✅ 所有 12 项 G1-G12 验收通过` 末行 + exit code 0。

- [ ] **Step 4: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add docs/acceptance/2026-05-29-pr-u6-history-action-sheet.md \
        scripts/acceptance/plan_u6_history_action_sheet.sh
git commit -m "docs(u6): acceptance §A-§J + 机检脚本（12 G 项）(Task 3)

非程序员可执行；spec §6.1.3 + modules §U6 字面 grep 锚 / Catalyst 编译闸门 /
test baseline 走宽松正则锚（不硬锁 N/M；用 exit code 守 strong gate）；
负向断言用 if/exit 1 不用 ! grep（per acceptance grep anchoring 教训）。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review（plan 写完后、push 给 reviewer 前）

按 writing-plans skill §Self-Review 跑：

**1. Spec 覆盖检查**：

| spec 要求 | 实现 task |
|---|---|
| modules §U6 L2097 `struct HistoryActionSheet: View` | Task 2 + 验收 E.2 |
| modules §U6 L2098 `init(record: TrainingRecord,` | Task 2 init + 验收 E.3 |
| modules §U6 L2099 `onReview: () -> Void` | Task 2 init `@escaping` + 复盘按钮 + 验收 E.4/E.10 + D9 决议 |
| modules §U6 L2100 `onReplay: () -> Void` | Task 2 init `@escaping` + 再来一次按钮 + 验收 E.5/E.11 + D9 决议 |
| modules §U6 L2101 `onCancel: () -> Void` | Task 2 init `@escaping` + 取消按钮 + 验收 E.6/E.12 + D6/D9 决议 |
| spec §6.1.3 L889 "点击一条历史记录 → 弹出提示框" | Task 2 HistoryActionSheet View（caller 呈现，D2） |
| spec §6.1.3 L893 "复盘" 选项 | Task 2 body Button(action: onReview) Text("复盘") + 验收 E.7/E.10 + D7 决议 |
| spec §6.1.3 L894 "再来一次" 选项 | Task 2 body Button(action: onReplay) Text("再来一次") + 验收 E.8/E.11 + D7 决议 |
| spec §6.1.3 L879-880 历史行股票名（代码）格式（弹窗标题识别本条记录） | Task 1 HistoryActionContent.formatStock + Task 2 Text(content.title) + 验收 E.13/E.14 + D3/D4/D5 决议 |

无 spec 要求缺 task。

**2. 占位扫描**：搜 "TBD"、"TODO"、"implement later"、"fill in details"、"Similar to Task" —— 全部不存在（plan 全代码原文 + 命令原文）。

**3. 类型一致性**：`HistoryActionContent` (Task 1) → `HistoryActionSheet` (Task 2) 单向使用，无类型重命名；`HistoryActionContent.init(record:)` 在 Task 1 定义，在 Task 2 调用 → 签名一致；`HistoryActionContent.title` 在 Task 1 定义，在 Task 2 body `Text(content.title)` 使用 → 一致；`HistoryActionContent.formatStock(name:code:)` 在 Task 1 定义，Task 1 测试 + Content.init 调用 → 一致；`TrainingRecord` / `FeeSnapshot` 已在 AppState.swift / Models.swift 冻结，不重定义（preview fixture 用其 init 字面字段顺序）。

**4. Acceptance/script 一致性**：acceptance doc §B.2 + script G10 用同款宽松正则 `Test run with [0-9]+ tests in [0-9]+ suites passed` → 一致；§D.1 + script G11 用同款 → 一致；§C.1 + script G12 用 "TEST BUILD SUCCEEDED" → 一致；§E.4/E.5/E.6 + script G3 关于三 callback `@escaping` 签名锚 → 一致；§E.7-E.13 + script G4/G5 关于 body literal `Text("…")` + `Button(action: on…)` callback 锚 → 一致；§E.14 + script G5 关于 `Self.formatStock(...)` 标题映射锚 → 一致；§H.3/H.4 + script G8 关于 `fileprivate extension TrainingRecord` + `static func preview() -> TrainingRecord` 锚 + 反向 `^public.*extension TrainingRecord` 禁 → 一致；§G.3 + script G6 关于 `borderedProminent` 反向禁（D8）→ 一致。

**5. 负向断言 idiom（per memory `feedback_acceptance_grep_anchoring`）**：script 所有反向断言用 `if grep -q ...; then echo "GN FAIL"; exit 1; fi`（G2/G6×3/G7×2/G8×2/G9），**不用 `! grep`**（POSIX：`!` 起头 pipeline 被 `set -e` 豁免 = 死闸门，命中禁止 pattern 也永不 abort）。human-facing grep 计数用行首 / body-literal 锚（`^import SwiftUI$` / `Text("…")` / `^#if DEBUG$` / `^public.*extension`），避免命中 prod header 注释里复述的同字符串（U3/U5 R3/R5/R6 三次复发同 bug-class，本 plan 预先规避）。

无 plan failure。

---

## Plan-stage 对抗性 review 收敛记录（opus 4.7 xhigh）

**R1 VERDICT: APPROVE**（6 维度：5 PASS + 1 NEEDS-ATTENTION 仅 Low）。reviewer 实证核对：preview fixture 15 字段与真 `TrainingRecord` init 逐字段一致；**实际编译验证双 `fileprivate extension TrainingRecord.preview()` 同 target 不冲突**（文件作用域，U6 首次出现「两文件扩展同一类型」情形但安全）；formatStock 输出正确；11 处负向断言全用 set-e-safe `if grep -q…;then exit 1;fi`；grep 锚均防注释碰撞。

| Finding | 严重度 | 处理 |
|---|---|---|
| R1-F1 双 fileprivate 同名扩展冲突？ | （质疑→实证反驳） | **非缺陷**：fileprivate 文件作用域不跨文件碰撞，plan D11 判断正确 |
| R1-F2 D12 承诺 token `NormalFlow/ReviewFlow/ReplayFlow` 未进 F.2/G7 正则 | Low | **已吸收**：F.2 + script G7 补三 flow 类型，与 D12 承诺对齐 |
| R1-F3 D3 单标题同股票多局不可区分 | Low | **接受 residual**：plan 已显式列；spec §6.1.3 最小解读正确（历史行已展示明细 + sheet 视觉锚定被点行）；v2 可吸收 startMonth |
| R1-F4 §J.1 tail -2 展示细节 | Low | **确认性记录**：与 U5 同款，无需改 |

reviewer 对 D4（不复用 U3 formatStock）/ D6（加取消按钮）独立判断均为「合理」。R1-F2 是 reviewer 推荐的一行 inline 修（grep 正则一致化，非语义改变）→ 不需新轮 review，plan-stage 收敛于 R1 APPROVE。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-pr-u6-history-action-sheet.md`。

下一步走用户在主线已选定的路径：**Subagent-Driven Development**（user 本次显式 prompt 第 3 段 = "再是 sub agent driven development"）。在此之前先跑 **Plan-stage 对抗性 review = Claude Opus 4.7 xhigh effort**（user 本次显式 prompt 第 2 段 = "另一个 claude opus 4.7 xhigh effort 做对抗性 review 到收敛"），收敛 APPROVE 后才开 Task 1 实施 subagent。
