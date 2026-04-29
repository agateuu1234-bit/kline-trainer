# PR 1 — E2 PositionManager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `KlineTrainerContracts` Swift 包内落地 E2 `PositionManager` 值类型，覆盖加权平均成本买入 / 卖出 / 持仓成本，作为 v6 outline 的启动锚 PR。

**Architecture:** 单文件 `PositionManager.swift` + 单测试文件 `PositionManagerTests.swift`，落入 `ios/Contracts/Sources/KlineTrainerContracts/` 与 `ios/Contracts/Tests/KlineTrainerContractsTests/`。值类型仅依赖 `Foundation`；与 spec v1.5 §4.2 + modules v1.4 §E2 一致；conformances `Codable, Equatable, Sendable`（持久化由 §M0.1 `position_data TEXT NOT NULL` 要求 + Wave 0 contract 一律标 Sendable 惯例）。

**Tech Stack:** Swift 6 (toolchain 6.3.1) · SwiftPM · `swift test`（Swift Testing macros + XCTest 共存）

**Spec refs（不写新 spec，只读现有冻结文档）:**
- 业务规则：`kline_trainer_plan_v1.5.md` §4.2（lines 627–681，加权平均、卖出归零、holdingCost、最大回撤算法）
- 类型清单：`kline_trainer_modules_v1.4.md` §E2（line 1474，"见 v1.5 §4.2；类型加 `Equatable`"）
- 调用方：`kline_trainer_modules_v1.4.md` line 1575 / 1594（`TrainingEngine.position: PositionManager` + `initialPosition: PositionManager = .init()`）
- 持久化：`kline_trainer_plan_v1.5.md` line 527（`position_data TEXT NOT NULL` JSON）

**Out of scope（PR 1 不做，记为 residual）:**
- `positionTier: Int`（spec 桩函数 `return 0`，真实实现需 `initialCapital` 上下文 → 留给 E5 `TrainingEngine` PR；本 PR **不**实现 stub）
- 100 股取整 / 强制平仓 → E3 `TradeCalculator` + E5 `TrainingEngine` 职责
- 最大回撤 (`DrawdownAccumulator`) → E5 单独类型

**Codex R1+R2 接收（defense-in-depth）:** Codex 抓到 `public + Codable` 是 trust boundary。
- **R1**：buy/sell 数学未守 0/负值 → 加 `precondition`（`shares > 0`、`totalCost` 有限非负、`sellShares <= holding`）。
- **R2**：synthesized `init(from:)` 绕过 buy/sell preconditions，可从恶意 JSON 产负 shares → 加 public init 不变量 precondition + 自定义 `init(from:)` throw `DecodingError` on 非法状态（不变量：shares ≥ 0；averageCost / totalInvested 有限非负；shares == 0 ⟹ avg == 0 && total == 0）。
- **R3**：shares > 0 时 `totalInvested ≈ averageCost * shares` 一致性，容差 `1e-9 * max(1, |operands|)` 覆盖 buy 后 IEEE 754 ULP 误差；sell 后精确成立。`invariantsHold` private static helper 复用于 init + decoder。
- **R4-1**：shares > 0 时 averageCost / totalInvested 必须 strictly positive（实际交易必有正成本）；buy precondition 改 `totalCost > 0`。
- **R4-2**：拒绝 `averageCost * shares` 中间积非有限，防溢出致容差变 +inf 而 fall-open。
- 上游 E3 `TradeCalculator` 仍负责语义 gating；本 PR 是 defense-in-depth。preconditions 是 invariant assertion 而非 error handling（CLAUDE.md §2 允许）；DecodingError 是 stdlib 边界错误（不与 M0.4 AppError 冲突）。
- 增加 3 个 decoder reject test（negative shares / negative cost / inconsistent empty）。运行时 invariant trap 仍不测（Swift Testing 无 expectFatalError 标准 idiom）。

**Quantitative budget（per `feedback_planner_packaging_bias.md` 硬规则）:**
- 子项 ≤ 3 ✅（本 plan = 3 task）
- prod 行数 ≤ 500 ✅（PositionManager.swift 预估 ~60 行，tests ~120 行）

---

## Task 1: PositionManager 值类型 + 加权平均买入/卖出 + Equatable

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift`

- [ ] **Step 1.1: 写 6 条失败测试（覆盖 spec §4.2 全部行为）**

> **数值选取规则:** 全部用 dyadic 友好值（10.0 / 12.5 / 1500 / 2500 / 1875），保证 `averageCost * Double(shares)` 在 IEEE 754 double 下恰好与字面量按位相等，避免浮点 `==` 假阳性。

把以下内容写入 `ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift`：

```swift
import Testing
@testable import KlineTrainerContracts

@Suite("PositionManager")
struct PositionManagerTests {

    @Test("default init is empty position")
    func defaultInit() {
        let p = PositionManager()
        #expect(p.shares == 0)
        #expect(p.averageCost == 0)
        #expect(p.totalInvested == 0)
        #expect(p.holdingCost == 0)
    }

    @Test("single buy sets weighted state correctly")
    func singleBuy() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000)
        #expect(p.shares == 100)
        #expect(p.totalInvested == 1000)
        #expect(p.averageCost == 10.0)
        #expect(p.holdingCost == 1000)                 // 10.0 × 100 = 1000 exact
    }

    @Test("multiple buys produce weighted average cost")
    func weightedAverageBuys() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000)            // avg 10.0
        p.buy(shares: 100, totalCost: 1500)            // (1000+1500)/200 = 12.5 exact dyadic
        #expect(p.shares == 200)
        #expect(p.totalInvested == 2500)
        #expect(p.averageCost == 12.5)
        #expect(p.holdingCost == 2500)                 // 12.5 × 200 = 2500 exact
    }

    @Test("partial sell reduces shares, keeps averageCost, recomputes totalInvested = avg * remaining")
    func partialSell() {
        var p = PositionManager()
        p.buy(shares: 200, totalCost: 2500)            // avg 12.5
        p.sell(shares: 50)
        #expect(p.shares == 150)
        #expect(p.averageCost == 12.5)
        #expect(p.totalInvested == 1875)               // 12.5 × 150 = 1875 exact
        #expect(p.holdingCost == 1875)                 // 卖出后 holdingCost 同步更新（守门：防 stored 而非 computed 的回归）
    }

    @Test("full sell zeroes averageCost and totalInvested")
    func fullSellResets() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000)
        p.sell(shares: 100)
        #expect(p.shares == 0)
        #expect(p.averageCost == 0)
        #expect(p.totalInvested == 0)
        #expect(p.holdingCost == 0)
    }

    @Test("Equatable: identical states are equal, different states are not")
    func equatable() {
        var a = PositionManager()
        a.buy(shares: 100, totalCost: 1000)
        var b = PositionManager()
        b.buy(shares: 100, totalCost: 1000)
        #expect(a == b)

        var c = PositionManager()
        c.buy(shares: 200, totalCost: 2000)
        #expect(a != c)
    }
}
```

- [ ] **Step 1.2: 运行测试验证失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2/ios/Contracts"
swift test --filter PositionManager 2>&1 | tail -20
```

期望：编译失败，`cannot find 'PositionManager' in scope`。

- [ ] **Step 1.3: 实现最小 PositionManager**

把以下内容写入 `ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift`：

```swift
// Kline Trainer Swift Contracts — E2 PositionManager
// Spec: kline_trainer_plan_v1.5.md §4.2 + kline_trainer_modules_v1.4.md §E2

import Foundation

public struct PositionManager: Equatable, Sendable {
    public private(set) var shares: Int
    public private(set) var averageCost: Double
    public private(set) var totalInvested: Double

    public init(
        shares: Int = 0,
        averageCost: Double = 0,
        totalInvested: Double = 0
    ) {
        self.shares = shares
        self.averageCost = averageCost
        self.totalInvested = totalInvested
    }

    public mutating func buy(shares: Int, totalCost: Double) {
        let newTotal = totalInvested + totalCost
        let newShares = self.shares + shares
        averageCost = newTotal / Double(newShares)
        self.shares = newShares
        totalInvested = newTotal
    }

    public mutating func sell(shares: Int) {
        self.shares -= shares
        totalInvested = averageCost * Double(self.shares)
        if self.shares == 0 {
            averageCost = 0
            totalInvested = 0
        }
    }

    public var holdingCost: Double { averageCost * Double(shares) }
}
```

- [ ] **Step 1.4: 运行测试验证全部通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2/ios/Contracts"
swift test --filter PositionManager 2>&1 | tail -10
```

期望：6 tests passed in PositionManager suite.

- [ ] **Step 1.5: Commit（含 plan 文件，让 plan 与 PR 同行）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2"
git add docs/superpowers/plans/2026-04-28-pr1-e2-position-manager.md \
        ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift
git commit -m "feat(E2): PositionManager 加权平均成本 + Equatable + plan"
```

---

## Task 2: Codable 一致性 + 持久化序列化校验

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift`（加 `Codable` conformance）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift`（追加 round-trip test）

**Why separate task:** Codable 是与 §M0.1 `position_data TEXT` 列的 trust boundary 接缝；单独 test + 单独 commit 让回归定位更小。

- [ ] **Step 2.1: 追加 Codable round-trip 失败测试**

把以下内容追加到 `PositionManagerTests.swift` 的 `struct PositionManagerTests` 内（紧跟最后一个 test 后）：

```swift
    @Test("Codable round-trip preserves all state")
    func codableRoundTrip() throws {
        var original = PositionManager()
        original.buy(shares: 200, totalCost: 2500)         // avg 12.5

        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PositionManager.self, from: json)

        #expect(decoded == original)
        #expect(decoded.shares == 200)
        #expect(decoded.averageCost == 12.5)
        #expect(decoded.totalInvested == 2500)
    }

    @Test("Codable JSON keys are camelCase (averageCost / totalInvested)")
    func codableJsonKeys() throws {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000)
        let data = try JSONEncoder().encode(p)
        // 用 JSONSerialization 解键名，避免 Double 渲染（"10" vs "10.0"）的字符串脆性。
        // Wave 0 §M0.1 position_data 列契约靠 round-trip 保证；本测试只锁键名约定。
        let dict = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict.keys.sorted() == ["averageCost", "shares", "totalInvested"])
    }
```

- [ ] **Step 2.2: 运行测试验证失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2/ios/Contracts"
swift test --filter PositionManager 2>&1 | tail -15
```

期望：编译失败，`type 'PositionManager' does not conform to protocol 'Decodable'`（或 `Encodable`）。

- [ ] **Step 2.3: 给 PositionManager 加 Codable conformance**

在 `PositionManager.swift` 修改 struct 声明那一行：

```swift
public struct PositionManager: Codable, Equatable, Sendable {
```

（仅加 `Codable,` —— Swift 自动合成；无需自写 init(from:) / encode(to:)）

- [ ] **Step 2.4: 运行测试验证通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2/ios/Contracts"
swift test --filter PositionManager 2>&1 | tail -10
```

期望：PositionManager suite 共 8 tests passed（6 业务 + 2 Codable）。

- [ ] **Step 2.5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2"
git add ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift
git commit -m "feat(E2): Codable 序列化 + JSON 形状锁"
```

---

## Task 3: 全包回归 + 推送 + 开 PR（中文 body）

**Files:** 无代码修改，只验收 + push + PR。

- [ ] **Step 3.1: 跑完整 Contracts 测试套件（Wave 0 验收）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2/ios/Contracts"
swift test 2>&1 | tail -5
```

期望：`Test run with 63 tests in 14 suites passed`（baseline 49 + PositionManager 8）。若 baseline 数字与本机 49 不一致，以 PR 提交前 main 分支跑出的实际数为准 +8。

- [ ] **Step 3.2: 跑完整 SwiftPM 编译（捕获 warning regression）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2/ios/Contracts"
swift build 2>&1 | grep -E "warning:|error:" | grep -v "AppErrorTests.swift:63" | head -20
```

期望：无新 warning（pre-existing 的 `AppErrorTests.swift:63 #expect(true)` 是 baseline，已 grep 排除）；无 error。

- [ ] **Step 3.3: 跑落地文件清单 + 行数预算核查**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2"
git diff --stat main...HEAD
```

期望：3 个文件改动（PositionManager.swift + PositionManagerTests.swift + 本 plan `.md`）；PositionManager.swift ≤ 80 行，PositionManagerTests.swift ≤ 170 行；plan `.md` 行数不在硬规则约束内（`feedback_planner_packaging_bias.md` 的 ≤500 prod 上限只数代码）。

- [ ] **Step 3.4: 把分支推上去**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2"
git push -u origin pr1-e2-position-manager
```

> **远端写入 checkpoint** — 按 `feedback_reviewer_verdict_not_authorization.md`，push 是远端写入，**必须等用户明确点头**才执行 Step 3.4。

- [ ] **Step 3.5: 开 PR（中文 body，per `feedback_pr_language_chinese.md`）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2"
gh pr create --title "feat(E2): PositionManager 加权平均成本 + Codable" --body "$(cat <<'EOF'
## Wave 0 v6 outline · PR 1（启动锚）

落地 spec v1.5 §4.2 + modules v1.4 §E2 的 `PositionManager` 值类型。

### 范围
- `PositionManager` struct：`shares` / `averageCost` / `totalInvested` / `holdingCost`
- `buy(shares:totalCost:)` 加权平均买入
- `sell(shares:)` 卖出（清仓时归零 averageCost & totalInvested）
- conformances：`Codable`, `Equatable`, `Sendable`

### 不在范围（residual，留给后续 PR）
- `positionTier` —— spec 桩 `return 0`，真实实现需 `initialCapital` 上下文，留给 E5 TrainingEngine
- 100 股取整 / 强制平仓 —— E3 TradeCalculator + E5 TrainingEngine 职责

### 验收
- 8 个 PositionManager 测试全过（默认 init / 单买 / 加权多买 / 部分卖 / 全卖归零 / Equatable / Codable round-trip / JSON 形状）
- 整包 57 tests pass（baseline 49 + 新增 8）
- 无新 warning、无 error
- 文件预算：1 个 prod 文件 ~60 行 + 1 个 test 文件 ~140 行；远低于 ≤500 行硬上限
EOF
)"
```

> **远端写入 checkpoint** — Step 3.5 创建公开 PR，按 `feedback_reviewer_verdict_not_authorization.md` 等用户点头。

- [ ] **Step 3.6: 把 PR 链接回报用户，等用户 GitHub UI merge**

merge 后按 `feedback_post_plan_ritual.md` 回回中列剩余 v6 PR 清单。

---

## 非 coder 验收清单（CLAUDE.md backstop §2 + workflow-rules `phase_delivery`）

> **执行者：用户本人**（非 coder 视角）。Claude 不得替用户勾选；每行须用户在终端 / GitHub UI 自验后填 ✅ / ❌。
> 禁用语（per workflow-rules.json）：「验证通过即可」「看起来正常」「应该没问题」「should work」「looks fine」。每行必须客观可对照。

| # | 动作 | 期望结果 | 通过/失败 |
|---|------|----------|-----------|
| 1 | 在终端 cd 到 worktree 后跑 `swift test 2>&1 \| tail -5` | 最末行包含 `Test run with 63 tests in 14 suites passed` | ☐ |
| 2 | 跑 `git diff --stat main...HEAD` | 仅列出 3 个文件：`PositionManager.swift`、`PositionManagerTests.swift`、本 plan `.md`；其中 PositionManager.swift ≤ 80 行，PositionManagerTests.swift ≤ 170 行（plan `.md` 行数不约束） | ☐ |
| 3 | 跑 `swift build 2>&1 \| grep -E "warning:\|error:" \| grep -v "AppErrorTests.swift:63"` | 输出为空（即除 baseline `#expect(true)` 警告外无新告警 / 无错误） | ☐ |
| 4 | 在 GitHub PR 页面看 Files changed | 文件清单与上方第 2 行一致；PositionManager.swift ≤ 80 行 | ☐ |
| 5 | 在 GitHub PR 页面看 CI checks | 若 CI 已挂：所有 check 绿灯，test summary 显示 57 tests passed（任一红灯不得 merge）；若 CI 未挂：本行 N/A 并标 ✅ | ☐ |
| 6 | PR body 末尾「不在范围 (residual)」段 | 列出 `positionTier`、100 股取整、强制平仓三项；并指明各自归属下一个 PR | ☐ |
| 7 | 在 PR 页面的 commit 列表 | 看到至少 3 个独立 commit（Task 1 主 + Task 2 主 + Task 3 push 不产生 commit）；额外可能含 Task 2 review-fix 衍生 commit（如 import 顺序 / plan 同步），可接受不视为缺陷 | ☐ |
| 8 | 在 GitHub PR 页面 Checks 面板看 `codex-verify-pass` status check（这是 CLAUDE.md backstop §1 要求的 `codex:adversarial-review` 在 GitHub 上的对外 check 名，由 `.github/workflows/codex-review-verify.yml` 写入） | 该 check 绿灯通过；若该 check 不存在 / 红灯 / 仍 pending，**不得 merge**（即使其他行全绿） | ☐ |

**任一行 ❌ → 不得 merge**；用户可在 PR comment 中粘贴每条命令的实际输出 / 截图作为证据。

---

## 全 PR 验收命令一览（用户可一键复粘核对）

```bash
# A. 跑 PR 测试
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2/ios/Contracts"
swift test 2>&1 | tail -5
# 期望：Test run with 63 tests in 14 suites passed

# B. 行数预算核查
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2"
git diff --stat main...HEAD
# 期望：3 files changed（PositionManager.swift + PositionManagerTests.swift + 本 plan .md）
# 代码新增行（prod + test）≤ 250；plan .md 行数不在硬规则约束内（per feedback_planner_packaging_bias.md，硬上限只数 prod 代码）

# C. 编译 warning 核查
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr1-e2/ios/Contracts"
swift build 2>&1 | grep -E "warning:|error:" | grep -v "AppErrorTests.swift:63"
# 期望：空输出
```

---

## 回滚预案

3 task 全部独立 commit，回滚粒度 = 单 commit；`git revert <sha>` 即可。最坏情况：删 worktree（`git worktree remove .worktrees/pr1-e2`）+ 删分支。

## 依赖图

PR 1（E2）= **零依赖**。仅依赖 Foundation 与已合并的 KlineTrainerContracts target；不依赖 M0.5（per `feedback_dep_graph_m05_overstated.md`，纯值类型不依赖 M0.5 doc）。
