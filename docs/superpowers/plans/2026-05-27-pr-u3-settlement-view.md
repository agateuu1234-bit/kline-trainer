# PR U3 — SettlementView 结算弹窗 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec §6.3 + modules §U3 字面要求的 SwiftUI 结算弹窗（`struct SettlementView: View` 含 `init(record: TrainingRecord, onConfirm: () -> Void)`），显示股票/起始/总资金/总收益率/最大回撤/买入次数/卖出次数 7 字段 + 确认按钮 —— Wave 1 顺位 13 / 第 15 个 PR per outline v20。

**Architecture:** **平台无关的纯值类型 `SettlementContent`**（host 全测的格式化结果：7 个已格式化字符串）+ **薄 SwiftUI shell `SettlementView`**（body 消费 `SettlementContent`，仅做 VStack/HStack/Button 装配；无业务逻辑、无格式化分支）。此双层架构与 C3/C4/C5 的 `MainChartLayout` / `SubChartLayout` / `CrosshairLayout` 同款：纯函数层 host swift test 真断言 + 渲染薄层由 Mac Catalyst build-for-testing SUCCEEDED 编译闸门守护。Spec 字面 `init(record:onConfirm:)` 不增不减；onConfirm 语义（Normal 模式保存 / Replay 模式不保存）属 caller（E5/U2 Wave 2）职责，本 PR 只触发回调。

**Tech Stack:** Swift 6.0 / Swift Testing (`import Testing` + `@Test` + `#expect`) / Foundation (`NumberFormatter` / `Locale`) / SwiftUI (跨 iOS 17 + macOS 14 + Mac Catalyst) / 已冻结模块：`TrainingRecord`（AppState.swift L19，15 字段含 stockCode / stockName / startYear / startMonth / totalCapital / returnRate / maxDrawdown / buyCount / sellCount）/ `FeeSnapshot`（Models.swift L143）。

**Spec source:** `kline_trainer_plan_v1.5.md` §6.3 (L988-1009) + `kline_trainer_modules_v1.4.md` §U3 (L2065-2071)。

**Constraint reminders (per Wave 1 outline v20 §3.2 + memory `feedback_planner_packaging_bias`):**
- ≤ 3 sub-items (this plan: 3 Tasks)
- ≤ 500 行 prod (this plan: ~200 行 prod estimate per outline 顺位 13 "UI 壳 ~200 行 SwiftUI")
- review budget: opus 4.7 xhigh 双闸门各 4-5 轮内收敛（user 本次显式指定走 opus 不走 codex）
- `cd ios/Contracts && swift test` 是 macOS host 命令；Mac Catalyst 用 `xcodebuild ... build-for-testing`（§15.1 #3 闸门）
- Working branch: `worktree-pr-u3-settlement-view`（执行阶段由 `using-git-worktrees` 创建）

---

## 背景与既有接缝（实施者必读）

- **TrainingRecord 形状已冻结**（`ios/Contracts/Sources/KlineTrainerContracts/AppState.swift` L19-60，**只读 15 字段**，本 PR **不动该文件**）：
  - `stockCode: String` / `stockName: String` —— 股票名+代码
  - `startYear: Int` / `startMonth: Int` —— 起始年/月
  - `totalCapital: Double` —— 总资金（结算时刻值）
  - `returnRate: Double` —— 总收益率，**已存为小数**（0.0234 表示 +2.34%）
  - `maxDrawdown: Double` —— 最大回撤，**已存为小数**（-0.0832 表示 -8.32%；存的就是负数或零，参 `AppStateTests.swift` L68 `maxDrawdown: -0.05`）
  - `buyCount: Int` / `sellCount: Int` —— 买卖次数
  - 其他字段（id / trainingSetFilename / createdAt / profit / feeSnapshot / finalTick）**本 PR 不显示**（spec §6.3 不要求）
- **SwiftUI 跨平台可用**：`ios/Contracts/Package.swift` 已声明 `.iOS(.v17), .macOS(.v14)`，SwiftUI 在两个 platform + Mac Catalyst 均可 `import SwiftUI`（不需要 `#if canImport(UIKit)` 守卫；UIKit 模块（C3-C6 渲染）才需要，因为 macOS 14 host 无 UIKit）。
- **现有 SwiftUI 文件唯一**：`ios/KlineTrainer/KlineTrainer/{KlineTrainerApp,ContentView}.swift` 是 Xcode 工程模板默认；本 PR **不**动这两个文件（U2 TrainingView 在 Wave 2 才整合）。SettlementView 文件落 `ios/Contracts/Sources/KlineTrainerContracts/UI/`（新建目录）作为 SwiftPM `KlineTrainerContracts` target 的一部分，跨平台可编译。
- **测试基线**：当前 **502 tests / 99 suites**（macOS host `swift test`，PR #69 merge 后 + 实测）。本 PR 目标 **+16 host 测试**（Task 1 = 16 = SettlementContentTests 一个 suite，含 R1-C1/M2/L1 加强）→ **共 +16 / 总 ≥518 / ≥100 suites**。**baseline 走宽松正则锚**（per R1-H1 + plan_c5_crosshair_markers.sh L53 既定 mode）：grep `"Test run with [0-9]+ tests in [0-9]+ suites passed"` 不硬锁 N；§B.2 / §D.1 prose 措辞"N≥518 / M≥100" 仅给人读，验收 gate 不硬锁。Task 2 = SwiftUI shell 仅编译验证，**0 新测试**（参 C5/C6 mode：UIKit/SwiftUI 薄层 0 单测 + Catalyst build-for-testing 编译闸门）。Task 3 = 验收 doc/script，0 新测试。
- **`UI/` 目录新建**：与现有 `Render/` / `Drawing/` / `Models/` / `Geometry/` / `Settings/` / `TrainingEngine/` / `PreviewFakes/` 平级。U3 落地后，U5 (顺位 14) / U6 (顺位 15) 共享此目录。
- **不依赖 Wave 0/1 任何运行时单例**：SettlementView 是纯展示组件，仅依赖 TrainingRecord（已冻 Wave 0 F1）。**不依赖 E3 TradeCalculator runtime code**（用户已在 outline 标 "依赖 E3" 是指**语义依赖**：买卖次数和总收益率是 E3 计算 + E5 写入 TrainingRecord 的产物；本 PR 不引 import）。

---

## Task 0 — §15.3 评审策略前置 + spec 偏差裁决

per `docs/governance/wave1-plan-template.md`：本 plan 使用哪些评审形式。

- [ ] **局部对抗性评审（必）**：本 plan U3 scope 内 **Claude Opus 4.7 xhigh effort 双闸门**（plan-stage + impl-stage / branch-diff），**不走 codex**（per memory `feedback_openai_quota_ci_pattern` + 用户本次显式 prompt）。4-5 轮内收敛或 escalate（per memory `feedback_codex_plan_budget_overshoot` 同样适用于 opus xhigh review）。
- [x] **集成层评审（N/A）**：C8 `ChartContainerView` 桥接 + E5 编排在 Wave 2；本 PR 不含集成层。U3 是叶子组件，无下游被桥接 surface。
- [x] **性能评审（N/A）**：plan v1.5 §一 "单帧 <4ms / Instruments" 属 **Phase 5 磨光 PR**；U3 是一次性渲染的小窗口（无 60Hz 渲染路径），本 PR 不做 Instruments 评审。

### Step ↔ Skill 显式映射（per memory `feedback_workflow_skill_invoke_explicit` —— PR #67 教训第 4 次复现预防）

本 PR 实施序列对应的 Superpowers skill：

| 阶段 | Skill | 何时调 | 何时**不**用 raw Agent 替代 |
|---|---|---|---|
| Plan-stage adversarial review | （主线 dispatch fresh opus 4.7 xhigh subagent，无对应 skill 名；按 `adversarial-review-template.md` 给 prompt） | plan 写完后、Task 1 开工前 | 主线必须 dispatch 新 agent；不能在主线自审 |
| Task 1-2 实施 | `superpowers:subagent-driven-development` | 每 Task fresh sonnet subagent + paired sonnet reviewer | 不用 raw Agent；不在主线自写 |
| Verification | `superpowers:verification-before-completion` | Task 3 acceptance script 跑完前最终验证 | 不在主线自宣"绿了" |
| Self-review | `superpowers:requesting-code-review` | 整体 branch-diff review 前 | 不跳 |
| Branch-diff adversarial review | （主线 dispatch fresh opus 4.7 xhigh subagent）| 全部实施完 + self-review 后 + push PR 前 | 主线必须 dispatch 新 agent |

完成 Task 0 才进 Task 1 实施（仅"局部对抗性评审"项为可执行待办，2 项 N/A 已预勾声明）。

### Spec 偏差裁决（D1-D11，全部写进代码注释 + 验收 §J）

| # | 偏差/歧义 | 裁决 | 权威依据 |
|---|---|---|---|
| **D1** | 落到 SwiftUI 还是 UIKit | **SwiftUI**：modules §U3 L2068 字面 `struct SettlementView: View` → SwiftUI；现有 KlineTrainer 工程 ContentView.swift 已用 SwiftUI；SwiftUI 跨 iOS 17+ macOS 14+ Catalyst 三平台原生支持，**不**加 `#if canImport(UIKit)` 守卫。 | modules §U3 L2068 字面 + Package.swift platforms 声明 |
| **D2** | 数值（returnRate / maxDrawdown）是否按盈正红/亏负绿着色 | **不着色，全用默认 `.primary` 文本色**。理由：spec §6.3 (L988-1009) 字面不规定 SettlementView 颜色规则；§四"盈正红 / 亏负绿"（L857）字面只规定 HomeView 历史记录列表；外推到 SettlementView 属 over-engineering（CLAUDE.md §2 Simplicity First）。如未来 Wave 3 磨光阶段需要，独立 PR 加。 | plan v1.5 §6.3 字面 + CLAUDE.md §2 |
| **D3** | "¥ 102,345.67" 的 `¥` 与数字间是否有空格 | **保留一个空格**（NumberFormatter 不带 currencySymbol，自前缀 `"¥ "`）。理由：spec §6.3 L997 ASCII `¥ 102,345.67` 字面有空格；`Locale("zh_CN") + .currency` 默认不带空格 → 自前缀 + 自定义 minimumFractionDigits=2/maximumFractionDigits=2/usesGroupingSeparator=true。 | spec L997 字面 |
| **D4** | "2021年08月" 月份零填充 | **零填充到两位**：`String(format: "%02d", month) + "月"`。spec L995 ASCII "08月" 字面。 | spec L995 字面 |
| **D5** | 收益率 / 回撤的符号 + 零值表示 + **signed zero / ULP 噪声**规范化 | **显式带符号 + 2 位小数**；零值（**含 IEEE-754 signed `-0.0` 和 ULP 噪声 ±ε**）规范化后显示为 `+0.00%`。理由：spec L998/L999 ASCII 显示了 `+2.34%` 和 `-8.32%`，明确正/负号显式；零值无 ASCII 例，选 `+0.00%` 优于 `0.00%`（保持格式一致性，与"是否盈利"语义一致）；E3 TradeCalculator 计算后写入的 Double 完全可能产出 signed `-0.0`（如 -1.0 + 1.0 在某些 ULP 路径）→ `String(format: "%+.2f", -0.0)` 实测产出 `-0.00`，违反决议字面 → 必须先把 pct 经 IEEE 测 `== 0` 归一化（IEEE `==` 在 `+0.0` 和 `-0.0` 均 true）。 | spec L998-L999 字面 + 格式一致性 + IEEE-754 + R1-C1 反向 testcase |
| **D6** | returnRate / maxDrawdown 是否要 ×100 转百分比 | **×100 + 2 位小数**。TrainingRecord 中 returnRate / maxDrawdown 均存为小数（fraction，参 AppStateTests.swift L67-68 `returnRate: 0.015` / `maxDrawdown: -0.05` 实际写入示例）；UI 显示要 ×100 加 `%`。 | AppState.swift L29-30 + AppStateTests.swift L67-68 实测 |
| **D7** | 股票字段显示 "name + code" 的括号 | **中文全角括号 `（）`**：`"贵州茅台（600519）"`。spec L994 ASCII 显示的就是全角括号。 | spec L994 字面 |
| **D8** | 买卖次数后是否带"次" | **带"次"且与数字有一空格**：`"4 次"` / `"3 次"`。spec L1000-1001 ASCII "买入次数：4 次" 字面。 | spec L1000-L1001 字面 |
| **D9** | Preview Fixture：是否新增 `TrainingRecord.preview()` 公共 fixture | **`fileprivate extension TrainingRecord` 内联 SettlementView.swift 的 `#if DEBUG` 区块**，不动 `PreviewFakes/InMemoryFakes.swift`，不新建公共 fixture 文件。理由：CLAUDE.md §2 "no abstractions for single-use code"——U5/U6（顺位 14/15）后续 PR 若再次需要相同 record fixture 再做抽取或各自 fileprivate 内联各自 fixture；本 PR 单 use site。**关键修正（R1-H4）**：必须 `fileprivate`（而非 `public`），否则 public extension 在 DEBUG 编译下任何 downstream 模块都可见，等价于"已抽取到 PreviewFakes 但藏在 SettlementView.swift"——破坏 PreviewFakes 单一来源 + U6 真要加同名 fixture 会重定义编译错。 | CLAUDE.md §2 + memory `feedback_planner_packaging_bias` + R1-H4 |
| **D10** | SwiftUI shell 是否单元测试 | **不单测**，只跑 Mac Catalyst build-for-testing SUCCEEDED 闸门（含 macOS host swift test 与 iOS Catalyst 两套编译）+ visual preview。理由：SwiftUI 内部断言要 ViewInspector / 类似第三方库，引入新 SwiftPM 依赖 vs **零业务逻辑 view 单测收益极低**；纯格式化逻辑全在 `SettlementContent`（Task 1，host 全测）。参 C5/C6 mode：UIKit 薄层 0 单测，靠 layout 纯函数测 + Catalyst 编译闸门。 | C5/C6 既定 mode + CLAUDE.md §2 |
| **D11** | `onConfirm` 闭包语义：本 View 是否需要分 Normal/Replay 行为分支 | **不分支**，View 只触发回调，闭包内部如何处理（Normal 保存 / Replay 跳过）由 caller（E5 / U2 / Wave 2 集成）决定。理由：spec L1007-1009 字面写"点击确认 → Normal: 保存 + 返回；Replay: 不保存 + 返回"是 **caller 职责**；spec §U3 init 签名 `init(record:, onConfirm: () -> Void)` 字面无 mode 参数。 | modules §U3 L2069 字面 + spec L1007-1009 字面（行为属 caller） |
| **D12** | spec §U3 L2069 字面 `onConfirm: () -> Void` vs 落地 `@escaping () -> Void` | **落地必须 `@escaping`**：SwiftUI `View` init 把 closure 存为 `private let onConfirm: () -> Void` 然后在 body `Button(action: onConfirm)` 间接传给 SwiftUI 内部存储 → Swift 编译要求 store-and-defer-call 的 closure 形参必须 `@escaping`，否则编译错。spec L2069 `() -> Void` 是契约形态（caller 视角的可调用性）；落地形态附加 `@escaping` 是 Swift 闭包逃逸语义的强制要求，不改变契约形状。 | spec L2069 字面 + Swift 编译约束 + R1-H2 |

---

## File Structure

### Production (2 files, ~200 行)

| 路径 | 动作 | 行数 | 职责 |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | **新建** | ~110 | 纯值类型 `public struct SettlementContent: Equatable, Sendable`，含 7 已格式化字段 `String` + 1 初始化器 `init(record: TrainingRecord)` + 4 内部静态纯函数（`formatStock` / `formatStartMonth` / `formatCapital` / `formatSignedRate`）。**平台无关**：仅 `import Foundation`（不 import SwiftUI / UIKit / CoreGraphics）。 |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | **新建** | ~90 | SwiftUI shell `public struct SettlementView: View`，`init(record: TrainingRecord, onConfirm: @escaping () -> Void)`，body 用 `SettlementContent(record:)` 拿 7 字段渲染 VStack/HStack/Button；DEBUG-only `static func preview() -> SettlementView` + `extension TrainingRecord { static func preview() }` 提供 SwiftUI `#Preview` macro 用 fixture。 |

### Tests (1 file, ~280 行)

| 路径 | 动作 | 行数 | 测试 |
|---|---|---|---|
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettlementContentTests.swift` | **新建** | ~320 | 16 host 测试覆盖：4 字段 init / 6 格式化角部 / 6 边界（含 R1-C1 signed-zero + R1-M2 negative-zero 反向 + R1-L1 ULP 边界 + 加强后的 boundary 正则锚）。详见 Task 1 Step 1。 |

### Docs (1 file)

| 路径 | 动作 | 内容 |
|---|---|---|
| `docs/acceptance/2026-05-27-pr-u3-settlement-view.md` | **新建** | ~140 行中文非程序员验收清单（10 节 §A-§J 含字面 grep / suite count / Catalyst build / 文件存在 / RGB 反向 grep / 决议落地） |

### Scripts (1 file)

| 路径 | 动作 | 内容 |
|---|---|---|
| `scripts/acceptance/plan_u3_settlement_view.sh` | **新建** | 机检 bash：与 acceptance §A-§J 对齐的 ≥10 项 grep / test / build 自动跑（参 `plan_c5_crosshair_markers.sh` 同款）。 |

**Total: 2 prod + 1 test + 1 doc + 1 script = 5 文件 / ~200 prod / ~280 test / 14 新测试。**

---

## Task 1 — `SettlementContent` 纯值类型 + 4 格式化函数 + 14 host 测试

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettlementContentTests.swift`

- [ ] **Step 1: 写失败测试 — `SettlementContentTests.swift`**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettlementContentTests.swift
// Spec: kline_trainer_plan_v1.5.md §6.3 L988-1009 + plan 2026-05-27-pr-u3-settlement-view.md Task 1
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("SettlementContent host tests")
struct SettlementContentTests {

    // MARK: - Fixture helper

    private func makeRecord(
        stockCode: String = "600519",
        stockName: String = "贵州茅台",
        startYear: Int = 2021,
        startMonth: Int = 8,
        totalCapital: Double = 102_345.67,
        returnRate: Double = 0.0234,
        maxDrawdown: Double = -0.0832,
        buyCount: Int = 4,
        sellCount: Int = 3
    ) -> TrainingRecord {
        TrainingRecord(
            id: 1,
            trainingSetFilename: "fixture.sqlite",
            createdAt: 1_700_000_000,
            stockCode: stockCode,
            stockName: stockName,
            startYear: startYear,
            startMonth: startMonth,
            totalCapital: totalCapital,
            profit: 0,
            returnRate: returnRate,
            maxDrawdown: maxDrawdown,
            buyCount: buyCount,
            sellCount: sellCount,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 100
        )
    }

    // MARK: - D1-D8 字面 spec 对齐

    @Test("§6.3 L994 字面：stock 字段全角括号包代码（D7）")
    func stockFieldUsesFullWidthParens() {
        let c = SettlementContent(record: makeRecord())
        #expect(c.stock == "贵州茅台（600519）")
    }

    @Test("§6.3 L995 字面：起始月份零填充到两位（D4）")
    func startMonthZeroPadded() {
        let c = SettlementContent(record: makeRecord(startMonth: 8))
        #expect(c.startMonth == "2021年08月")
    }

    @Test("§6.3 L995 字面：12月不加多余零（边界）")
    func startMonthTwoDigitMonthUnchanged() {
        let c = SettlementContent(record: makeRecord(startYear: 2024, startMonth: 12))
        #expect(c.startMonth == "2024年12月")
    }

    @Test("§6.3 L997 字面：总资金 ¥ 与数字间一空格 + 千分位 + 2 小数（D3）")
    func capitalFormatHasSpaceAfterYen() {
        let c = SettlementContent(record: makeRecord(totalCapital: 102_345.67))
        #expect(c.totalCapital == "¥ 102,345.67")
    }

    @Test("§6.3 L997 整数总资金也补 2 位小数")
    func capitalIntegerStillTwoDecimals() {
        let c = SettlementContent(record: makeRecord(totalCapital: 100_000))
        #expect(c.totalCapital == "¥ 100,000.00")
    }

    @Test("§6.3 L998 字面：正收益率显式 + 号 + 2 位小数（D5/D6）")
    func returnRatePositiveSign() {
        let c = SettlementContent(record: makeRecord(returnRate: 0.0234))
        #expect(c.returnRate == "+2.34%")
    }

    @Test("§6.3 L999 字面：负回撤显式 - 号 + 2 位小数（D5/D6）")
    func maxDrawdownNegativeSign() {
        let c = SettlementContent(record: makeRecord(maxDrawdown: -0.0832))
        #expect(c.maxDrawdown == "-8.32%")
    }

    @Test("D5 零值显式 + 号（避免 -0.00%）")
    func zeroValueShowsPositiveSign() {
        let c = SettlementContent(record: makeRecord(returnRate: 0, maxDrawdown: 0))
        #expect(c.returnRate == "+0.00%")
        #expect(c.maxDrawdown == "+0.00%")
    }

    @Test("R1-C1 IEEE-754 signed zero -0.0 规范化为 +0.00%（D5 必修）")
    func signedZeroNormalizedToPositive() {
        let c = SettlementContent(record: makeRecord(returnRate: -0.0, maxDrawdown: -0.0))
        #expect(c.returnRate == "+0.00%")
        #expect(c.maxDrawdown == "+0.00%")
    }

    @Test("R1-M2 IEEE-754 ±0.0 输入都不显示 -0.00%（D5 反向断言；ULP 噪声不阈值化属 D5 注释明确 residual）")
    func neverShowsNegativeZero() {
        for v in [0.0, -0.0] {
            let c = SettlementContent(record: makeRecord(returnRate: v, maxDrawdown: v))
            #expect(c.returnRate != "-0.00%")
            #expect(c.maxDrawdown != "-0.00%")
        }
    }

    @Test("§6.3 L1000-L1001 字面：买卖次数与'次'一空格（D8）")
    func tradeCountsHaveSpaceBeforeCi() {
        let c = SettlementContent(record: makeRecord(buyCount: 4, sellCount: 3))
        #expect(c.buyCount == "4 次")
        #expect(c.sellCount == "3 次")
    }

    @Test("零次买卖也保留'次'后缀")
    func zeroTradeCountStillHasCi() {
        let c = SettlementContent(record: makeRecord(buyCount: 0, sellCount: 0))
        #expect(c.buyCount == "0 次")
        #expect(c.sellCount == "0 次")
    }

    // MARK: - 边界值

    @Test("R1-H3 rate 边界值：正则强锚 ^[+-]\\d+\\.\\d{2}%$ + halfUp 实测值锁定（强断言）")
    func rateBoundaryHalfDecimalRegex() {
        let c = SettlementContent(record: makeRecord(returnRate: 0.00501))
        // 强锚 #1：符号 + 至少一位整数 + 小数点 + 恰好两位小数 + 百分号
        #expect(c.returnRate.wholeMatch(of: #/^[+\-]\d+\.\d{2}%$/#) != nil)
        // 强锚 #2：本机 Swift 6.0 toolchain `String(format: "%+.2f", 0.501)` 实测 = "+0.50"（halfEven 规则在 0.501 不触发 banker's round）
        #expect(c.returnRate == "+0.50%")
    }

    @Test("R1-L1 ULP 边界：0.1 × 100 ≈ 10.000000000000002 不泄漏到显示")
    func ulpBoundaryDecimalDoesNotLeak() {
        let c = SettlementContent(record: makeRecord(returnRate: 0.1))
        #expect(c.returnRate == "+10.00%")
    }

    @Test("非常大的资金正常显示千分位（不科学记数）")
    func capitalLargeNumberUsesGrouping() {
        let c = SettlementContent(record: makeRecord(totalCapital: 12_345_678.99))
        #expect(c.totalCapital == "¥ 12,345,678.99")
    }

    @Test("负 returnRate 与 maxDrawdown 同时呈现")
    func negativeReturnRateAlsoSigned() {
        let c = SettlementContent(record: makeRecord(returnRate: -0.10, maxDrawdown: -0.15))
        #expect(c.returnRate == "-10.00%")
        #expect(c.maxDrawdown == "-15.00%")
    }

    @Test("SettlementContent 是 Equatable / Sendable")
    func contentEquatableAndSendable() {
        let c1 = SettlementContent(record: makeRecord())
        let c2 = SettlementContent(record: makeRecord())
        #expect(c1 == c2)
        // Sendable 编译时检查；同 actor 内 await 即证（这里用 @MainActor 不必要，结构体本身即时值）
        let _: any Sendable = c1
    }
}
```

- [ ] **Step 2: 跑测试确认全 fail（编译错或测试 fail —— 关键是 exit ≠ 0）**

Run:
```bash
cd ios/Contracts
swift test --filter SettlementContentTests > /tmp/u3-red.txt 2>&1
echo "exit=$?"
grep -iE "error:|cannot find|undeclared" /tmp/u3-red.txt | head -3
```
Expected: `exit=` 非 0 + 至少 1 行 error / cannot find / undeclared 命中。**用 exit code 不依赖 wording**（R1-M4：Swift toolchain 小版本"Cannot find" vs "cannot find" 大小写差异不再卡 verification）。

- [ ] **Step 3: 写最小实现 — `SettlementContent.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
// Spec: kline_trainer_plan_v1.5.md §6.3 L988-1009 + plan 2026-05-27-pr-u3-settlement-view.md
//
// 平台无关纯值类型：把 TrainingRecord 的 7 个字段格式化成 SwiftUI 显示用字符串。
// 平台守卫：仅 import Foundation，不 import SwiftUI/UIKit/CoreGraphics —— host swift test 全测。
//
// 决议（D1-D8）：
// - D3 ¥ + 一空格 + 千分位 + 2 位小数
// - D4 月份零填充
// - D5 returnRate / maxDrawdown 显式带符号（含零值 +0.00%）
// - D6 returnRate / maxDrawdown 在 TrainingRecord 存为小数，UI 显示 ×100 + %
// - D7 stock = "name（code）" 中文全角括号
// - D8 买卖次数 + 一空格 + "次"

import Foundation

public struct SettlementContent: Equatable, Sendable {
    public let stock: String        // "贵州茅台（600519）"
    public let startMonth: String   // "2021年08月"
    public let totalCapital: String // "¥ 102,345.67"
    public let returnRate: String   // "+2.34%"
    public let maxDrawdown: String  // "-8.32%"
    public let buyCount: String     // "4 次"
    public let sellCount: String    // "3 次"

    public init(record: TrainingRecord) {
        self.stock = Self.formatStock(name: record.stockName, code: record.stockCode)
        self.startMonth = Self.formatStartMonth(year: record.startYear, month: record.startMonth)
        self.totalCapital = Self.formatCapital(record.totalCapital)
        self.returnRate = Self.formatSignedRate(record.returnRate)
        self.maxDrawdown = Self.formatSignedRate(record.maxDrawdown)
        self.buyCount = "\(record.buyCount) 次"
        self.sellCount = "\(record.sellCount) 次"
    }

    // MARK: - 内部纯函数（static 便于 Self.xxx 调用，避免实例方法 capture）

    /// D7：name（code），全角括号。
    static func formatStock(name: String, code: String) -> String {
        "\(name)（\(code)）"
    }

    /// D4：年 + 零填充月 + "月"。
    static func formatStartMonth(year: Int, month: Int) -> String {
        "\(year)年\(String(format: "%02d", month))月"
    }

    /// D3：¥ + 一空格 + 千分位 + 强制 2 位小数。Locale 中性（POSIX）避免设备 Locale 影响千分位字符（强制英文逗号）。
    static func formatCapital(_ value: Double) -> String {
        let fmt = NumberFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.numberStyle = .decimal
        fmt.usesGroupingSeparator = true
        fmt.groupingSeparator = ","
        fmt.decimalSeparator = "."
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        // 兜底：若极端情况（如 .nan / .infinity）formatter 返回 nil，回落到普通 String 表达。
        // 业务上 TrainingRecord.totalCapital 不允许 NaN（M0.3 已冻），但渲染层保留兜底。
        let body = fmt.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "¥ \(body)"
    }

    /// D5/D6：value 是小数（0.0234 = 2.34%），×100 + 2 位小数 + 显式 ±。零值 → "+0.00%"。
    /// **D5 signed-zero 规范化（R1-C1）**：`String(format: "%+.2f", -0.0)` 实测产 "-0.00"，违反决议；
    /// IEEE-754 `==0` 在 `+0.0` 和 `-0.0` 均 true → 归一化为 `+0.0` 再格式化。
    /// 对 ULP 噪声本身不做阈值化（E3 写入语义零是字面 0，不是 1e-16 级；若 E3 后续出现 ULP 噪声会暴露另一处问题，本 PR 不预阻断）。
    static func formatSignedRate(_ value: Double) -> String {
        let raw = value * 100
        let pct = (raw == 0) ? 0.0 : raw
        let body = String(format: "%+.2f", pct)
        return "\(body)%"
    }
}
```

- [ ] **Step 4: 跑测试确认 16 全绿**

Run: `cd ios/Contracts && swift test --filter SettlementContentTests 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中模式 `Test run with N tests in M suites passed after X seconds.`（**宽松正则锚，per R1-H1** + plan_c5 既定 mode 不硬锁 N=16/M=1；语义检验 N≥16，M=1）。

加成 strong gate：跑 `swift test` 退出码 == 0：
```bash
cd ios/Contracts && swift test --filter SettlementContentTests > /tmp/u3-green.txt 2>&1
echo "exit=$?"
```
Expected: `exit=0`。

如某测试 fail，按测试失败信息修代码（不动测试断言），重跑直到全绿；不能修改测试断言来对齐错误实现。

如某测试 fail，按测试失败信息修代码（不动测试断言），重跑直到全绿；不能修改测试断言来对齐错误实现。

- [ ] **Step 5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettlementContentTests.swift
git commit -m "feat(u3): SettlementContent 纯值类型 + 4 格式化函数 + 16 host 测试 (Task 1)

Spec §6.3 L988-1009 字面对齐：stock 全角括号 / 月份零填充 / ¥ 空格千分位 /
±2位百分比 / N 次。POSIX Locale 中性。signed-zero 归一化（D5 + R1-C1）。
本 PR scope 仅纯函数 + 测试，SwiftUI shell 在 Task 2 落地。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 — `SettlementView` SwiftUI shell + DEBUG preview fixture

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift`

> 本 Task 不加新测试（per D10）；Mac Catalyst build-for-testing SUCCEEDED 是编译闸门。

- [ ] **Step 1: 写实现 — `SettlementView.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
// Spec: kline_trainer_modules_v1.4.md §U3 L2065-2071 字面 init 签名 +
//       kline_trainer_plan_v1.5.md §6.3 L988-1009 ASCII 布局
//
// 薄 SwiftUI shell：body 仅装配 VStack/HStack/Button；所有格式化交 SettlementContent（Task 1）。
//
// 决议（D1/D2/D9-D11）：
// - D1 SwiftUI 跨 iOS17/macOS14/Catalyst 三平台原生支持，不加 #if canImport(UIKit)
// - D2 数值不分盈亏色，默认 .primary（spec §6.3 不规定，Simplicity）
// - D9 TrainingRecord.preview() 内联本文件 #if DEBUG 区，U6 顺位 15 再看是否抽取
// - D10 不单测 SwiftUI shell，靠 Catalyst build-for-testing 闸门
// - D11 onConfirm 闭包语义（Normal 保存 / Replay 跳过）属 caller，本 View 只触发

import SwiftUI

public struct SettlementView: View {
    private let content: SettlementContent
    private let onConfirm: () -> Void

    public init(record: TrainingRecord, onConfirm: @escaping () -> Void) {
        self.content = SettlementContent(record: record)
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本局结算")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 8)

            // 第一组：股票 + 起始
            VStack(alignment: .leading, spacing: 8) {
                row(label: "股票", value: content.stock)
                row(label: "起始", value: content.startMonth)
            }

            Divider()

            // 第二组：5 数值
            VStack(alignment: .leading, spacing: 8) {
                row(label: "总资金", value: content.totalCapital)
                row(label: "总收益率", value: content.returnRate)
                row(label: "最大回撤", value: content.maxDrawdown)
                row(label: "买入次数", value: content.buyCount)
                row(label: "卖出次数", value: content.sellCount)
            }

            Spacer().frame(height: 8)

            Button(action: onConfirm) {
                Text("确认")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - DEBUG-only preview fixture (D9 + R1-H4 — fileprivate 防跨模块污染)

#if DEBUG
fileprivate extension TrainingRecord {
    /// Preview fixture。决议 D9 + R1-H4：**fileprivate** 真单 use site；U6 顺位 15 再看是否抽取到 PreviewFakes
    /// 或各自 fileprivate 内联各自 fixture。public 会污染下游 DEBUG 编译 → 破坏 PreviewFakes 单一来源约定。
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
    SettlementView(record: .preview(), onConfirm: {})
}
#endif
```

- [ ] **Step 2: 跑 macOS host swift test 确认零回归**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中模式 `Test run with N tests in M suites passed after X seconds.`，N≥518，M≥100（baseline 502/99 + Task 1 加 16/1 = 518/100；宽松正则锚 per R1-H1）。强 gate 用退出码：`swift test > /tmp/u3-zero-regression.txt 2>&1; echo "exit=$?"` 期望 `exit=0`。

- [ ] **Step 3: 跑 Mac Catalyst build-for-testing SUCCEEDED**

Run:
```bash
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/u3-derived \
           build-for-testing 2>&1 | tail -5 | tee /tmp/u3-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/u3-build-tail.txt && echo "✅ Catalyst PASS"
```
Expected: `TEST BUILD SUCCEEDED` 命中。若失败：常见原因是 SwiftUI iOS-only API 在 Catalyst 不支持 / `@Observable` macro 在某 toolchain 报错 —— 修代码不修平台守卫（spec D1 明确 SwiftUI 跨三平台）。

- [ ] **Step 4: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
git commit -m "feat(u3): SettlementView SwiftUI shell + #Preview fixture (Task 2)

薄 shell：body 消费 SettlementContent，仅 VStack/HStack/Button 装配，无业务逻辑。
DEBUG-only TrainingRecord.preview() 内联（D9）；spec §U3 L2068-2069 字面 init
签名（D1 SwiftUI；D11 onConfirm 语义属 caller）。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 — acceptance doc + 机检脚本

**Files:**
- Create: `docs/acceptance/2026-05-27-pr-u3-settlement-view.md`
- Create: `scripts/acceptance/plan_u3_settlement_view.sh`

> 本 Task 不加新测试。

- [ ] **Step 1: 写 acceptance doc**

新建 `docs/acceptance/2026-05-27-pr-u3-settlement-view.md`，**完整内容**：

```markdown
# PR U3 验收清单（中文非程序员可执行）

> Wave 1 顺位 13 / 第 15 个 PR。spec `kline_trainer_plan_v1.5.md` §6.3 + `kline_trainer_modules_v1.4.md` §U3。
> plan `docs/superpowers/plans/2026-05-27-pr-u3-settlement-view.md`。

## §A 文件存在

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| A.1 | `ls ios/Contracts/Sources/KlineTrainerContracts/UI/` | SettlementContent.swift / SettlementView.swift 两个文件 | 全部存在 |
| A.2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/UI/` | SettlementContentTests.swift | 存在 |
| A.3 | `test -f scripts/acceptance/plan_u3_settlement_view.sh && echo OK` | OK | 输出 OK |

## §B 编译 + 全量测试（macOS host）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| B.1 | `cd ios/Contracts && swift build 2>&1 \| tail -3` | `Build complete!` | 命中 |
| B.2 | `cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests in [0-9]+ suites passed"` | 一行命中模式（基线 502/99 + 本 PR +16/+1 = 期望 518/100，但 grep 宽松不硬锁 N/M） | 命中模式 + `swift test` exit=0 |

## §C Catalyst 编译闸门（§15.1 #3）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| C.1 | `cd ios/Contracts && xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/u3-derived build-for-testing 2>&1 \| tail -5` | `TEST BUILD SUCCEEDED` | 命中 |

## §D 新 suite 全绿

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| D.1 | `cd ios/Contracts && swift test --filter SettlementContentTests 2>&1 \| grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"` | 一行命中模式（期望 N≥16/M=1） | 命中模式 + `swift test --filter SettlementContentTests` exit=0 |

## §E spec 字面 grep 锚（D1-D8 落地 — 防 spec drift）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'public struct SettlementContent: Equatable, Sendable' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit | 数字 = 1 |
| E.2 | `grep -nc 'public struct SettlementView: View' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit | 数字 = 1 |
| E.3 | `grep -nc 'init(record: TrainingRecord, onConfirm: @escaping () -> Void)' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (D12：modules §U3 字面 `() -> Void` + Swift 编译强制 `@escaping`) | 数字 = 1 |
| E.4 | `grep -nc '本局结算' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (spec L992) | 数字 = 1 |
| E.5 | `grep -nc '"确认"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (spec L1003) | 数字 = 1 |
| E.6 | `grep -nc '"¥ "' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (D3 ¥+空格) | 数字 = 1 |
| E.7 | `grep -nc 'en_US_POSIX' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (D3 Locale 中性) | 数字 = 1 |
| E.8 | `grep -nc '"%+.2f"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (D5 显式带符号) | 数字 = 1 |
| E.9 | `grep -nc '"%02d"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (D4 月份零填充) | 数字 = 1 |
| E.10 | `grep -nc 'static func formatStock' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (D7 全角括号函数存在) | 数字 = 1 |
| E.11 | `grep -nc '（' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | ≥ 1 hit (D7 中文全角左括号字面) | 数字 ≥ 1 |
| E.12 | `grep -nc 'raw == 0' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 1 hit (R1-C1 D5 signed-zero 归一化代码) | 数字 = 1 |

## §F 不依赖 Wave 0 / 1 业务运行时（叶子组件硬约束）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nE 'import (GRDB\|ZIPFoundation)' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 | 输出为空 |
| F.2 | `grep -nE 'TradeCalculator\|TickEngine\|PositionManager\|TrainingFlowController\|APIClient' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 | 输出为空 |
| F.3 | `grep -nc 'import SwiftUI' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift` | 0 hit (Content 平台无关) | 数字 = 0 |
| F.4 | `grep -nc 'import SwiftUI' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (View 才 import) | 数字 = 1 |

## §G 无 RGB 硬编码 / 无 D2 反例（盈亏色未实现）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -nE 'Color\\(red:\|UIColor\\(' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 | 输出为空 |
| G.2 | `grep -nE '\\.foregroundStyle\\(\\.red\|\\.foregroundStyle\\(\\.green' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 (D2：不分盈亏色) | 输出为空 |

## §H DEBUG-only preview 隔离（D9 + R1-H4 — fileprivate 防跨模块污染）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| H.1 | `grep -nE '#if DEBUG' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit | 数字 = 1 |
| H.2 | `grep -nc '#endif' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | ≥ 1 hit (DEBUG 配对) | 数字 ≥ 1 |
| H.3 | `grep -nc 'fileprivate extension TrainingRecord' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 1 hit (D9 + R1-H4 fileprivate) | 数字 = 1 |
| H.4 | `grep -ncE '^public.* extension TrainingRecord\|^extension TrainingRecord.*public' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 0 hit (R1-H4 拒绝 public 跨模块污染；锚行首与 script G8 对齐) | 数字 = 0 |
| H.5 | `grep -nc 'extension TrainingRecord\|TrainingRecord.preview' ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | 0 hit (本 PR 不动 PreviewFakes — D9) | 数字 = 0 |

## §I onConfirm 语义不分支（D11）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| I.1 | `grep -nE 'TrainingFlowController\|Mode\\.\|\\.normal\|\\.review\|\\.replay' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift` | 无命中 (View 不分 mode) | 输出为空 |

## §J 机检脚本自身

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_u3_settlement_view.sh 2>&1 \| tail -2` | `所有 N 项 G1-Gx 验收通过` | 末行 ✅ + 0 exit code |
```

- [ ] **Step 2: 写机检脚本 — `plan_u3_settlement_view.sh`**

```bash
#!/usr/bin/env bash
# Wave 1 顺位 13 (U3 SettlementView) 机检验收
# 用法：bash scripts/acceptance/plan_u3_settlement_view.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: U3 源文件 + 测试文件 + 验收 doc 存在 =="
test -f ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
test -f ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
test -f ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettlementContentTests.swift
test -f docs/acceptance/2026-05-27-pr-u3-settlement-view.md

echo "== G2: SettlementContent 平台无关（仅 import Foundation；不 import SwiftUI/UIKit/CoreGraphics）=="
grep -q "^import Foundation$" ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
! grep -qE "^import (SwiftUI|UIKit|CoreGraphics)$" ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift

echo "== G3: spec §U3 字面 init 签名（D1/D11）=="
grep -q "public struct SettlementView: View" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
grep -q "init(record: TrainingRecord, onConfirm: @escaping () -> Void)" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G4: spec §6.3 字面字串：本局结算 / 确认 =="
grep -q "本局结算" ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
grep -q '"确认"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G5: D3/D4/D5/D7 格式化字面落地 + signed-zero 归一化代码（R1-C1）=="
grep -q '"¥ "' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q "en_US_POSIX" ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q '"%02d"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q '"%+.2f"' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q 'raw == 0' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift
grep -q '（' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift

echo "== G6: D2 不实现盈亏色（反向验证）=="
! grep -qE '\.foregroundStyle\(\.red|\.foregroundStyle\(\.green' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
! grep -qE 'Color\(red:|UIColor\(' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G7: F2/F3 不引业务运行时 / Content 平台无关 =="
! grep -qE 'import (GRDB|ZIPFoundation)' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
! grep -qE 'TradeCalculator|TickEngine|PositionManager|TrainingFlowController|APIClient' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementContent.swift \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G8: D9 + R1-H4 DEBUG-only fileprivate preview fixture（防跨模块污染）=="
grep -q '^#if DEBUG' ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
grep -q "fileprivate extension TrainingRecord" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
grep -q "static func preview() -> TrainingRecord" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
# 反向：不能是 public extension（会污染下游 DEBUG 编译）
! grep -qE "^public.*extension TrainingRecord|^extension TrainingRecord.*public" \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift
# 反向：PreviewFakes 不被本 PR 动
! grep -qE "extension TrainingRecord|TrainingRecord\.preview" \
  ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift

echo "== G9: D11 onConfirm 不分 mode 分支 =="
! grep -qE 'TrainingFlowController|\.normal|\.review|\.replay' \
  ios/Contracts/Sources/KlineTrainerContracts/UI/SettlementView.swift

echo "== G10: swift test 全量 PASS（基线 502 + 本 PR +16 = 期望 ≥518，宽松正则锚 per R1-H1；strong gate 由 set -euo pipefail 提供，无需重跑）=="
cd ios/Contracts
swift test 2>&1 | tee /tmp/u3-test-full.txt | tail -3
grep -qE "Test run with [0-9]+ tests in [0-9]+ suites passed" /tmp/u3-test-full.txt
cd -

echo "== G11: SettlementContentTests 单 suite 全绿（宽松正则锚 + set -euo pipefail strong gate）=="
cd ios/Contracts
swift test --filter SettlementContentTests 2>&1 | tee /tmp/u3-test-suite.txt | tail -3
grep -qE "Test run with [0-9]+ tests? in [0-9]+ suites? passed" /tmp/u3-test-suite.txt
cd -

echo "== G12: Mac Catalyst build-for-testing SUCCEEDED =="
cd ios/Contracts
xcodebuild -scheme KlineTrainerContracts \
           -destination 'platform=macOS,variant=Mac Catalyst' \
           -derivedDataPath /tmp/u3-derived-final \
           build-for-testing 2>&1 | tail -5 | tee /tmp/u3-build-tail.txt
grep -q "TEST BUILD SUCCEEDED" /tmp/u3-build-tail.txt
cd -

echo
echo "✅ 所有 12 项 G1-G12 验收通过"
```

> **注**：script v2 的 G5 / G8 项内多了若干 grep 反向断言（per R1-H4 / C1）但顶层编号仍是 G1-G12；最后一行打印消息保持 "12 项" wording。

加可执行权限：
```bash
chmod +x scripts/acceptance/plan_u3_settlement_view.sh
```

- [ ] **Step 3: 跑机检脚本一遍确认全绿**

Run: `bash scripts/acceptance/plan_u3_settlement_view.sh 2>&1 | tail -2`
Expected: `✅ 所有 12 项 G1-G12 验收通过` 末行 + exit code 0。

- [ ] **Step 4: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add docs/acceptance/2026-05-27-pr-u3-settlement-view.md \
        scripts/acceptance/plan_u3_settlement_view.sh
git commit -m "docs(u3): acceptance §A-§J + 机检脚本（12 G 项）(Task 3)

非程序员可执行；spec §6.3 + modules §U3 字面 grep 锚 / Catalyst 编译闸门 /
test baseline 走宽松正则锚（per R1-H1，不硬锁 N/M；用 exit code 守 strong gate）。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## R2 → v3 修订（cosmetic 整合）

R2 verdict APPROVE，3 个 fresh-eye finding（1 M honesty + 2 L cosmetic）顺手修：

| Finding | 修订 |
|---|---|
| R2-M1 `neverShowsNegativeZero` 测试描述与 body 不自洽 | 删除测试名 "和 ULP 噪声" wording，与 body `[0.0, -0.0]` 对齐；ULP 行为由 D5 决议注释 + `ulpBoundaryDecimalDoesNotLeak` 正向覆盖 |
| R2-L1 G10/G11 strong-gate 死代码 + swift test 重跑浪费 | 删除 line 731-732 / 739-740 重跑 + dead `||` 兜底；信任 `set -euo pipefail` + pipefail strong-gate |
| R2-L2 §H.4 vs G8 锚不一致（`^` 有/无） | §H.4 加 `^` 锚 + 用 `-E` 切到 ERE 模式，与 script G8 一致 |

R2-M1 是 cosmetic honesty 完善；R2-L1/L2 是脚本工程清洁，全部 cosmetic 不影响 plan 落地。R2 reviewer 明示"不需新轮 review"——v3 直接进 subagent-driven-development。

---

## R1 → v2 修订总览

R1 verdict NEEDS-ATTENTION（1C/4H/4M/3L）落地结果：

| Finding | 严重度 | 修订方式 | 落地位置 |
|---|---|---|---|
| C1 signed zero → `-0.00%` | Critical | `formatSignedRate` 加 `let pct = (raw == 0) ? 0.0 : raw` 归一化 + 加 `signedZeroNormalizedToPositive` testcase | Task 1 Step 3 + Step 1 测试 + D5 决议更新 |
| H1 G10/G11 硬锁 N=516/14 brittle | High | acceptance §B.2/§D.1 + script G10/G11 改宽松正则 `[0-9]+ tests in [0-9]+ suites` + exit code 守 strong gate | acceptance §B.2/§D.1 + script G10/G11 |
| H2 `@escaping` 偏差未列 D | High | 加 D12 决议 + 验收 E.3 wording 显式标"D12" | D 表 + 验收 E.3 |
| H3 boundary 断言空洞 | High | 改 `rateBoundaryHalfDecimal` 用 Swift Regex `wholeMatch` 强锚 + 锁定本机 toolchain 实测 "+0.50%" | Task 1 Step 1 测试 |
| H4 D9 `public extension` 跨模块污染 | High | 改 `fileprivate extension TrainingRecord` + 加反向 §H.4 / G8 grep 锚拒绝 public | D9 决议 + Task 2 代码 + 验收 §H.3-H.4 + script G8 |
| M1 §E.10 escape 错 | Medium | 改 E.10 锚函数签名 `static func formatStock` + 新 E.11/E.12 字面锚 | 验收 §E |
| M2 缺 negative-zero 反向断言 | Medium | 加 `neverShowsNegativeZero` testcase | Task 1 Step 1 测试 |
| M3 §H.4 vague | Medium | §H.4 → §H.5 改成确定性 grep 反向锚 | 验收 §H |
| M4 grep 大小写脆 | Medium | Step 2 改用 exit code + `grep -iE "error:..(cannot find\|undeclared)"` | Task 1 Step 2 |
| L1 ULP 边界未覆盖 | Low | 加 `ulpBoundaryDecimalDoesNotLeak` testcase（0.1 ×100） | Task 1 Step 1 测试 |
| L2 / L3 cosmetic | Low | 不修（接受 residual） | — |

测试数：14 → 16（新增 3 个：signedZero + neverShowsNegativeZero + ulpBoundary）。基线推算 502+16 = 518 / 99+1 = 100，但 acceptance / script 走宽松正则锚不硬锁。

---

## Self-Review（plan 写完后、push 给 reviewer 前）

按 writing-plans skill §Self-Review 跑：

**1. Spec 覆盖检查**：

| spec 要求 | 实现 task |
|---|---|
| spec §6.3 L992 "本局结算" 标题 | Task 2 body Text("本局结算") + 验收 E.4 |
| spec §6.3 L994 股票字段全角括号 | Task 1 `formatStock` + 测试 + 验收 E.10 |
| spec §6.3 L995 起始月份零填充 | Task 1 `formatStartMonth` + 2 测试 + 验收 E.9 |
| spec §6.3 L997 总资金 ¥ + 千分位 + 2 小数 | Task 1 `formatCapital` + 3 测试 + 验收 E.6/E.7 |
| spec §6.3 L998 总收益率 ± 2 位 % | Task 1 `formatSignedRate` + 3 测试 + 验收 E.8 |
| spec §6.3 L999 最大回撤 ± 2 位 % | Task 1 同 `formatSignedRate` 复用 + 测试 |
| spec §6.3 L1000-L1001 买卖次数 "N 次" | Task 1 init body 直拼 + 2 测试 |
| spec §6.3 L1003 "确认"按钮 | Task 2 Button("确认") + 验收 E.5 |
| spec §6.3 L1007-1009 onConfirm Normal/Replay 行为 | D11 决议：本 View 不分支，caller 职责 |
| modules §U3 L2068-2069 init 签名 | Task 2 字面 `init(record: TrainingRecord, onConfirm: @escaping () -> Void)` + 验收 E.3 |

无 spec 要求缺 task。

**2. 占位扫描**：搜 "TBD"、"TODO"、"implement later"、"fill in details"、"Similar to Task" —— 全部不存在（plan 全代码原文 + 命令原文）。

**3. 类型一致性**：`SettlementContent` (Task 1) → `SettlementView` (Task 2) 单向使用，无类型重命名；`SettlementContent.init(record:)` 在 Task 1 定义，在 Task 2 调用 → 签名一致；`TrainingRecord.preview()` 在 Task 2 #if DEBUG fileprivate 区定义，在 SettlementView #Preview macro 调用 → 一致；4 个 static 函数 `formatStock` / `formatStartMonth` / `formatCapital` / `formatSignedRate` 在 Task 1 定义且仅在同文件 init body 内 self 调用，无跨 task 引用冲突。

**4. Acceptance/script 一致性**：acceptance doc §B.2 + script G10 用同款宽松正则 `Test run with [0-9]+ tests in [0-9]+ suites passed` → 一致；§D.1 + script G11 用同款 → 一致；§C.1 + script G12 用 "TEST BUILD SUCCEEDED" → 一致；§H.3/H.4 + script G8 关于 `fileprivate extension TrainingRecord` + 反向 public 拒绝 → 一致；§E.12 + script G5 关于 `raw == 0` signed-zero 归一化锚 → 一致。

**5. R1 修订完整性**：1C + 4H + 4M 全部按修订方式落地；3 L 接受 residual。

无 plan failure。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-27-pr-u3-settlement-view.md`。

下一步走用户在主线已选定的路径：**Subagent-Driven Development**（user 本次显式 prompt 第 3 段 = "再是 sub agent driven development"）。在此之前先跑**Plan-stage 对抗性 review = Claude Opus 4.7 xhigh effort**（user 本次显式 prompt 第 2 段 = "另一个 claude opus 4.7 xhigh effort 做对抗性 review 到收敛"），收敛 APPROVE 后才开 Task 1 实施 subagent。
