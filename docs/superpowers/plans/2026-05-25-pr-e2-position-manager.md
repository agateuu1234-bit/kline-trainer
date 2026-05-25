# E2 PositionManager 实施 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 Wave 1 顺位 8 / 第 10 个 PR——E2 `PositionManager` 实施本体：加权平均成本值类型，buy/sell `precondition` trap（不 throws/Result），持久化用 throwing 自定义 Codable decoder + `invariantsHold` 守门；同 PR 执行 RFC §4.2.7 MANDATORY 的 `CONTRACT_VERSION` bump（1.4 → 1.5）三件套。

**Architecture:** 单一 `public struct PositionManager: Codable, Equatable, Sendable`（intra-package 值类型，被 Wave 2 `@MainActor TrainingEngine` 持有），按 spec §4.2.1–§4.2.8 信任边界设计：进程内 buy/sell 输入由上游 E3 `TradeCalculator`（Result 通道，入口 1a）或 force-close caller 不变量 `holding==shares`（入口 1b）守门 → 违约 = caller programmer error → `precondition` trap；唯一外部不可信入口 = 持久化 load（SQLite `position_data`，入口 2）→ throwing `init(from:)` + `invariantsHold`。`position_data` typed decoder 收紧已 shipped 列语义（m01 §Bump A 类"改既有语义"）→ 顶层 `CONTRACT_VERSION` bump 同 PR 落地（§4.2.7）。

**Tech Stack:** Swift 6.0（swift-tools-version 6.0）、SwiftPM target `KlineTrainerContracts`、Swift Testing（`import Testing` / `@Suite` / `@Test` / `#expect`）。测试命令：`cd ios/Contracts && swift test`。Catalyst：`xcodebuild build-for-testing -scheme ...`（CI 必绿）。

**Wave 1 顺位：** 8（交付序第 10 个 PR）。设计来源 = `kline_trainer_plan_v1.5.md` §4.2.1–§4.2.8（PR #64 E2-RFC，design-stage opus 4.7 xhigh R1→R3 APPROVE 冻结）。前置 = 顺位 7 RFC（已 merged PR #64）。范围估算 ~135 行 prod（PositionManager.swift）+ bump 三件套 ~6 行 + 验收脚本 ~60 行。

**评审契约（per memory `feedback_review_tool_switch_must_ask`）：** 本 session 用户开头明示用**另一个 Claude opus 4.7 xhigh effort 做对抗性 review（非 codex）**，两道闸门（plan-stage + 整支 branch-diff）均由 opus 4.7 xhigh 执行，到收敛为止。

---

## Task 0 — §15.3 评审策略前置（per `docs/governance/wave1-plan-template.md`）

- [ ] **局部对抗性评审（必）：** 本 plan 子模块 scope 内对抗性评审；用户 session 契约 = opus 4.7 xhigh（非 codex），plan-stage + branch-diff 两道闸门，到收敛为止（per memory `feedback_codex_plan_budget_overshoot` 5 轮 escalate + `feedback_review_tool_switch_must_ask` 用户指定工具是契约）。
- [ ] **集成层评审（N/A）：** 本 PR 不含 C8 桥接 / E5 编排；PositionManager 只被 Wave 2 E5 `TrainingEngine` 持有 + E6/P4 持久化 caller 解码，集成层评审在 Wave 2 对应 PR。
- [ ] **性能评审（N/A）：** 非 Phase 5 磨光 PR；O(1) 算术 + Codable，无性能热点。

完成 Task 0 才进 Task 1 实施。

---

## 设计决策（实施前必读 —— 这是本 PR 的核心判断点）

权威来源 = `kline_trainer_plan_v1.5.md` §4.2.1–§4.2.8（RFC 冻结）。归档分支 `pr1-e2-position-manager` 的 14-test 实现（codex R1-R5 收敛）作**结构借鉴**，但下列 D1-D4 是新 RFC 相对归档实现的**真 delta**，必须按 RFC 字面修正（不复用归档的 R7 spec-drift）。

### D1（关键 delta）：`sell(0)` 必须 no-op，不 trap

§4.2.1 入口 1b 字面：`forceCloseOnEnd` 只守 `holding>0/price`（否则**全零报价 → `sell(0)` no-op**）。即局终强平当 `holding<=0` 时 E3 返回 `shares==0` 的 `SellQuote`，E5 调 `position.sell(0)`，**必须是 no-op**。归档实现 `sell` 有 `precondition(shares > 0)` 会在 `sell(0)` 上 **trap** —— 与 §4.2.1 冲突。**本 PR：`sell(soldShares:)` 开头 `if soldShares == 0 { return }` 早返（no-op）**，其后才 `precondition(soldShares > 0)`（负值 = caller bug → trap）+ `precondition(soldShares <= shares)`（oversell → trap）。`buy(0)` 无对应"全零买入"入口（E3 资金不足返 `.failure` 终止于 UI），故 `buy` 保留 `precondition(shares > 0)` trap。

### D2（delta）：post-mutation `invariantsHold` 用 `assert`（debug 兜底），不用 `precondition`

§4.2.4 实现要求三步：① mutation **前**用 `addingReportingOverflow` / `isFinite` 预检合成结果，违约即 `precondition` trap（**主守门**，message 含违约参数 + 当前 state）；② 预检通过后写入；③ debug build end-of-function `assert(invariantsHold)` 兜底（**不作主守门**）。归档实现把 post-mutation `invariantsHold` 写成 `precondition`（release 也跑）。**本 PR 按 §4.2.4 ③ 改 `assert`** —— 因 ① 预检已保证写入态合法（`combinedShares>0` ∧ `newTotal` finite & `>0` ∧ `newAverage>0` finite），③ 仅 debug 复核。

### D3（delta）：`invariantsHold` 容差 RHS 对齐 spec 字面 `tol * max(1, |totalInvested|)`

§4.2.8 字面第 4 条：`shares > 0 ⟹ averageCost > 0 ∧ averageCost.isFinite ∧ |averageCost*Double(shares) - totalInvested| ≤ tol * max(1, |totalInvested|)`。归档用 `tol * max(1, max(|totalInvested|, |expected|))`（多了 `|expected|`）。**本 PR 用 spec 字面 `tol * max(1, abs(totalInvested))`**。`tol` 具体值（§4.2.8 "由顺位 8 定并给测试"）= **`1e-9`**，理由 + mutation-verify 见 D4。

### D4：`tol = 1e-9` 必须 mutation-verify（per memory `feedback_codex_fractional_subpixel_bias` + E3 FP demonstrator 教训）

仅声明 tol 值不够；必须给**双向 demonstrator** 证明容差真在判别（非 fall-open）：
- **正向**（接受 app 自写存档）：`buy` 产生 `averageCost = newTotal/newShares` 的除-乘 ULP 误差 → encode → decode **成功**（用 `==` 或过紧 epsilon 会拒收 → 反证 tol 必要）。
- **负向 / mutation**（拒绝损坏存档）：取合法存档，把 `totalInvested` 篡改远超 tol（如 2×）→ decode **抛 `DecodingError`**（若 decoder fall-open / 不校验一致性，此 case 会漏过 → 反证 tol 在判别）。
- **边界**：`exact + 0.5·tol·max(1,|exact|)` 接受 / `exact + 2·tol·max(1,|exact|)` 拒绝。

### D5：`CONTRACT_VERSION` bump 1.4 → 1.5（§4.2.7 MANDATORY 门）+ 仅 bump 顶层

§4.2.7：typed throwing decoder 把 `position_data` 从"任何字节"收紧为"合法否则拒收" = m01 §Bump **A 类"改既有语义"** → **必须 bump 顶层 `CONTRACT_VERSION`**，且执行 MANDATORY 与 decoder 同 PR。

- **target = `"1.5"`**：当前 `"1.4"` 的自然下一个；与 plan 文档 v1.5 同号纯属巧合（CONTRACT_VERSION 是数据契约轴，独立于文档版本轴）。
- **仅 bump 顶层标识，三套存储 sub-version 不变**：`position_data` 无 DDL 变更（仍 `TEXT NOT NULL`），收紧是 **reader 侧语义**非 schema migration。m01 §Bump A 类"改既有语义"是独立触发条件（不要求伴随 DDL/sub-dimension 变更）。故 PostgreSQL `0003_v1.3` / 训练组 SQLite `1` / app.sqlite `0003_v1.4_purge_leased` 全不动，**不新增 migration 文件**（避免 scope creep）。
- **`CONTRACT_VERSION` 非运行时 gate**（grep 全仓确认：仅 `Models.swift` 常量 + `ModelsTests` 断言 + m01/modules 矩阵 + plan_1f 脚本引用，无任何 reader 拿它拒数据）→ bump 安全，不会拒绝旧 app.sqlite 数据；真正拒损坏 `position_data` 的是 decoder + `invariantsHold`。
- **5 个权威触点同步**（缺一即矩阵/脚本不自洽）：① `Models.swift:7` 常量 ② `ModelsTests.swift:7-8` 断言（+ 函数名 `contractVersionIs1_4`→`contractVersionIs1_5`）③ `m01-schema-versioning-contract.md:29` 矩阵 cell ④ `kline_trainer_modules_v1.4.md:144` 矩阵 cell ⑤ `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh:42-44` 断言。历史 plan 文档（plan1c/plan1f）是时点记录，**不改**。

### D6：`positionTier` 从实现 + spec §4.2 代码块移除（§4.2.8 注 MANDATORY）

§4.2.8 `positionTier` 注：placeholder，档位 caller-derived（E4/E5 依初始资金推导），**顺位 8 从 PositionManager 移除此 member**。production 不含 `positionTier`；同步把 spec §4.2 illustrative 代码块（plan_v1.5 §4.2，约 L655-659）的 `positionTier` 占位行删除、§4.2.8 注由"顺位 8 移除"flip 为"顺位 8 已移除"——这是执行 RFC §4.2.8 **已授权**的 follow-through（非新设计），保持 spec↔impl 一致。

### D7：M0.4 豁免（per `docs/governance/m04-apperror-translation-gate.md`）

PositionManager **不消费 AppError**：进程内违约走 `precondition` trap；持久化非法走标准 `DecodingError`（Codable 契约）。`DecodingError → AppError.persistence(...)` 的翻译是持久化 caller（E6/P4）职责，非本类型。Gate = grep `PositionManager.swift` 不引用 `AppError`（0 命中 → 豁免）。同 E3/E4 豁免模式。

### D8：`public init` 带 `precondition(invariantsHold)`

提供 `public init(shares:averageCost:totalInvested:)`（默认全 0）供测试构造已知持仓态 + Wave 2 重建。违约 = 进程内构造 programmer error → trap（§4.2.2 进程内入口归 trap）。`.init()`→(0,0,0) invariants 成立。§4.2.8 "使用点"列举非穷举，public init trap 与 §4.2.2 信任分类一致。

### D9：依赖 Swift 合成 `encode(to:)`

自定义 `init(from:)` + `private enum CodingKeys` 下，Swift 仍合成 `encode(to:)`（用 CodingKeys）。不手写 encode（YAGNI）。round-trip 测试验证编解码对称。

---

## Spec snapshot（grep-verified，2026-05-25 复核）

| 锚点 | 文件:行 | 当前内容 |
|---|---|---|
| §4.2 设计理由块 | `kline_trainer_plan_v1.5.md` L663-736 | §4.2.1–§4.2.8 全文（RFC 冻结，本 PR 权威契约） |
| §4.2 illustrative 代码块 | `kline_trainer_plan_v1.5.md` L630-661 | 裸 struct 示例，含 `positionTier` 占位 L655-659（D6 移除） |
| §E2 模块条目 | `kline_trainer_modules_v1.4.md` L1489-1493 | "类型加 Equatable" + 交叉引用 §4.2.1–§4.2.8 |
| 现有 PositionManager 生产代码 | （grep `PositionManager` --include=*.swift） | **无**——本 PR 首次落地生产实现 |
| 模块落点 | `ios/Contracts/Sources/KlineTrainerContracts/` | E3 = `TradeCalculator.swift`（top-level）；本 PR `PositionManager.swift` 同级 |
| `CONTRACT_VERSION` 常量 | `ios/.../Models/Models.swift:7` | `public let CONTRACT_VERSION = "1.4"`（D5 → "1.5"） |
| `CONTRACT_VERSION` 测试 | `ios/.../ModelsTests.swift:7-8` | `contractVersionIs1_4` / `#expect(CONTRACT_VERSION == "1.4")`（D5 → 1.5） |
| m01 矩阵 cell | `docs/governance/m01-schema-versioning-contract.md:29` | `\| CONTRACT_VERSION（顶层标识） \| "1.4" \| ...`（D5 → "1.5"） |
| modules 矩阵 cell | `kline_trainer_modules_v1.4.md:144` | 同上（D5 → "1.5"） |
| plan_1f 断言 | `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh:42-44` | `grep ... '"1\.4"' ...`（D5 → "1.5"） |
| persistence baseline | `ios/.../AppState.swift:90` / `app_schema_v1.sql:55` | `positionData: Data` / `position_data TEXT NOT NULL`（已 shipped，本 PR 无 DDL 改动） |

---

## File Structure

| 文件 | 动作 | 责任 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift` | Create | E2 值类型本体（props / invariantsHold / public init / throwing decoder / buy / sell / holdingCost） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift` | Create | buy/sell 算术 + sell(0) no-op + Codable round-trip + decoder reject 矩阵 + tol mutation demonstrator |
| `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | Modify | CONTRACT_VERSION "1.4"→"1.5"（D5） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift` | Modify | 断言 + 函数名 → 1.5（D5） |
| `docs/governance/m01-schema-versioning-contract.md` | Modify | 矩阵 cell → "1.5" + changelog 一行说明 bump 理由（D5） |
| `kline_trainer_modules_v1.4.md` | Modify | 矩阵 cell → "1.5"（D5） |
| `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | Modify | 断言 → "1.5"（D5） |
| `kline_trainer_plan_v1.5.md` | Modify | §4.2 代码块移除 positionTier + §4.2.8 注 flip 为"已移除"（D6） |
| `scripts/acceptance/plan_e2_position_manager.sh` | Create | §4.2.7 enforcement hook + 结构/bump-sync/M0.4 断言 |
| `docs/acceptance/2026-05-25-pr-e2-position-manager.md` | Create | 非 coder 中文验收清单 |

子项归并（≤3，per `feedback_planner_packaging_bias`）：**A** = E2 模块 impl + tests（Task 1-3）；**B** = CONTRACT_VERSION bump 三件套 + spec 同步（Task 4-5）；**C** = 验收 hook + 清单（Task 6-7）。prod 行数 ~135（PositionManager）+ ~6（bump）+ ~60（脚本）≈ 200 « 500。

---

## Task 1：PositionManager 核心（props + invariantsHold + public init + throwing decoder + holdingCost）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift`

- [ ] **Step 1：写失败测试（核心构造 + holdingCost + Equatable + round-trip + 1 代表性 reject）**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("PositionManager 核心")
struct PositionManagerCoreTests {

    @Test func emptyPositionIsZero() {
        let p = PositionManager()
        #expect(p.shares == 0)
        #expect(p.averageCost == 0)
        #expect(p.totalInvested == 0)
        #expect(p.holdingCost == 0)
    }

    @Test func publicInitConstructsKnownState() {
        let p = PositionManager(shares: 200, averageCost: 11.0, totalInvested: 2200.0)
        #expect(p.shares == 200)
        #expect(p.averageCost == 11.0)
        #expect(p.totalInvested == 2200.0)
    }

    @Test func holdingCostIsAverageCostTimesShares() {
        let p = PositionManager(shares: 300, averageCost: 5.0, totalInvested: 1500.0)
        #expect(p.holdingCost == 1500.0)
    }

    @Test func equatable() {
        let a = PositionManager(shares: 100, averageCost: 10.0, totalInvested: 1000.0)
        let b = PositionManager(shares: 100, averageCost: 10.0, totalInvested: 1000.0)
        let c = PositionManager(shares: 200, averageCost: 10.0, totalInvested: 2000.0)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func codableRoundTripOfValidPosition() throws {
        let p = PositionManager(shares: 100, averageCost: 10.0, totalInvested: 1000.0)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PositionManager.self, from: data)
        #expect(decoded == p)
    }

    @Test func decoderRejectsNegativeShares() {
        let json = Data(#"{"shares":-1,"averageCost":0.0,"totalInvested":0.0}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PositionManager.self, from: json)
        }
    }
}
```

- [ ] **Step 2：运行测试，确认编译失败（红）**

Run: `cd ios/Contracts && swift test --filter PositionManagerCoreTests`
Expected: 编译失败 `cannot find 'PositionManager' in scope`（类型尚未创建）。

- [ ] **Step 3：创建 PositionManager.swift（核心：props + invariantsHold + tol + public init + 自定义 throwing decoder + holdingCost）**

创建 `ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift`：

```swift
// Kline Trainer Swift Contracts — E2 PositionManager 模块
// Spec: kline_trainer_plan_v1.5.md §4.2 + §4.2.1–§4.2.8（trust-boundary 设计理由块）
//       kline_trainer_modules_v1.4.md §E2
//
// 信任边界（§4.2.1）：进程内 buy/sell 输入由上游 E3 TradeCalculator（Result 通道，入口 1a）
// 或 force-close caller 不变量 holding==shares（入口 1b）守门 → 违约 = caller programmer error
// → precondition trap。唯一外部不可信入口 = 持久化 load（SQLite position_data，入口 2）
// → throwing 自定义 init(from:) + invariantsHold。详见 plan §4.2.1–§4.2.8。
// 注：纯 stdlib 值类型（Codable/Decoder/CodingKey/DecodingError 均属 stdlib），不 import Foundation（同 TradeCalculator/TickEngine）。

public struct PositionManager: Codable, Equatable, Sendable {
    public private(set) var shares: Int
    public private(set) var averageCost: Double
    public private(set) var totalInvested: Double

    // MARK: - 不变量（§4.2.8）

    /// 相对容差：吸收 buy 的除-乘 ULP + JSON Double 十进制往返误差（§4.2.8）。
    /// 用 `==` 或过紧 epsilon 会拒收 app 自写的合法存档（见 PositionManagerCodableTests 双向 demonstrator）。
    static let invariantTolerance: Double = 1e-9

    /// O(1) 不变量校验（§4.2.8 四条 + isFinite/≥0 通用守门防 NaN*0）。
    private static func invariantsHold(shares: Int, averageCost: Double, totalInvested: Double) -> Bool {
        guard shares >= 0,
              averageCost.isFinite, averageCost >= 0,
              totalInvested.isFinite, totalInvested >= 0
        else { return false }
        // (shares == 0) ⟺ (totalInvested == 0)
        guard (shares == 0) == (totalInvested == 0) else { return false }
        guard shares > 0 else { return true }
        // shares > 0 ⟹ averageCost > 0 ∧ averageCost*shares ≈ totalInvested（相对容差，§4.2.8 字面 RHS）
        guard averageCost > 0 else { return false }
        let expected = averageCost * Double(shares)
        guard expected.isFinite else { return false }
        return abs(expected - totalInvested) <= invariantTolerance * Swift.max(1.0, abs(totalInvested))
    }

    // MARK: - 构造

    /// 进程内构造。违约 = caller programmer error → trap（§4.2.2 进程内入口归 trap）。
    public init(shares: Int = 0, averageCost: Double = 0, totalInvested: Double = 0) {
        precondition(
            PositionManager.invariantsHold(shares: shares, averageCost: averageCost, totalInvested: totalInvested),
            "PositionManager.init: invariants violated (shares=\(shares), averageCost=\(averageCost), totalInvested=\(totalInvested))"
        )
        self.shares = shares
        self.averageCost = averageCost
        self.totalInvested = totalInvested
    }

    // MARK: - 持久化（§4.2.1 入口 2：唯一外部不可信入口 → throwing）

    private enum CodingKeys: String, CodingKey {
        case shares, averageCost, totalInvested
    }

    /// 持久化反序列化。损坏/被篡改存档 → throw DecodingError（§4.2.1 入口 2 / §4.2.8）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let shares = try c.decode(Int.self, forKey: .shares)
        let averageCost = try c.decode(Double.self, forKey: .averageCost)
        let totalInvested = try c.decode(Double.self, forKey: .totalInvested)
        guard PositionManager.invariantsHold(shares: shares, averageCost: averageCost, totalInvested: totalInvested) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "PositionManager: invariants violated (shares=\(shares), averageCost=\(averageCost), totalInvested=\(totalInvested))"
            ))
        }
        self.shares = shares
        self.averageCost = averageCost
        self.totalInvested = totalInvested
    }

    // MARK: - 派生

    /// 持仓成本 = 当前持仓股数 × 加权平均成本（§4.2）。
    public var holdingCost: Double { averageCost * Double(shares) }
}
```

- [ ] **Step 4：运行测试，确认通过（绿）**

Run: `cd ios/Contracts && swift test --filter PositionManagerCoreTests`
Expected: 6 tests pass，0 failures。

- [ ] **Step 5：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift
git commit -m "feat(e2): PositionManager 核心 — props + invariantsHold + throwing decoder + holdingCost（顺位 8）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：buy / sell（precondition trap + 溢出预检 + sell(0) no-op）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift`（加 buy/sell）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift`（加交易 suite）

- [ ] **Step 1：写失败测试（buy/sell 算术 + sell(0) no-op）**

在 `PositionManagerTests.swift` 末尾追加：

```swift
@Suite("PositionManager 交易")
struct PositionManagerTradeTests {

    @Test func buySingleSetsAverageCost() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000.0)
        #expect(p.shares == 100)
        #expect(p.totalInvested == 1000.0)
        #expect(abs(p.averageCost - 10.0) < 1e-9)
    }

    @Test func buyMultipleAccumulatesWeightedAverage() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000.0)   // avg 10
        p.buy(shares: 100, totalCost: 1200.0)   // total 2200 / 200 = 11
        #expect(p.shares == 200)
        #expect(p.totalInvested == 2200.0)
        #expect(abs(p.averageCost - 11.0) < 1e-9)
    }

    @Test func sellPartialKeepsAverageCost() {
        var p = PositionManager()
        p.buy(shares: 300, totalCost: 3000.0)   // avg 10
        p.sell(shares: 100)
        #expect(p.shares == 200)
        #expect(abs(p.averageCost - 10.0) < 1e-9)
        #expect(abs(p.totalInvested - 2000.0) < 1e-9)
    }

    @Test func sellFullClearsToZero() {
        var p = PositionManager()
        p.buy(shares: 100, totalCost: 1000.0)
        p.sell(shares: 100)
        #expect(p == PositionManager())
    }

    // D1：§4.2.1 入口 1b force-close 全零报价 → sell(0) no-op（不 trap）
    @Test func sellZeroIsNoOp() {
        var p = PositionManager(shares: 300, averageCost: 5.0, totalInvested: 1500.0)
        let before = p
        p.sell(shares: 0)
        #expect(p == before)
    }

    // sell(0) 在空仓上也 no-op（force-close holding==shares==0 路径）
    @Test func sellZeroOnEmptyIsNoOp() {
        var p = PositionManager()
        p.sell(shares: 0)
        #expect(p == PositionManager())
    }
}
```

- [ ] **Step 2：运行测试，确认失败（红）**

Run: `cd ios/Contracts && swift test --filter PositionManagerTradeTests`
Expected: 编译失败 `value of type 'PositionManager' has no member 'buy'`（buy/sell 未实现）。

- [ ] **Step 3：实现 buy / sell**

在 `PositionManager.swift` 的 `// MARK: - 派生` **之前**插入 `// MARK: - 交易` 段：

```swift
    // MARK: - 交易（§4.2.1 入口 1a/1b：进程内 → precondition trap；§4.2.4 溢出预检）

    /// 买入（加权平均成本）。§4.2.4：① 预检合成结果溢出/非有限 → trap；② 写入；③ debug assert 兜底。
    public mutating func buy(shares purchasedShares: Int, totalCost: Double) {
        precondition(purchasedShares > 0,
            "PositionManager.buy: shares must be > 0 (got \(purchasedShares); state shares=\(shares))")
        precondition(totalCost.isFinite && totalCost > 0,
            "PositionManager.buy: totalCost must be finite & > 0 (got \(totalCost); state totalInvested=\(totalInvested))")
        // ① 预检合成结果（§4.2.4 ①：主守门）
        let (combinedShares, sharesOverflow) = shares.addingReportingOverflow(purchasedShares)
        precondition(!sharesOverflow,
            "PositionManager.buy: shares would overflow Int (state shares=\(shares) + \(purchasedShares))")
        let newTotal = totalInvested + totalCost
        precondition(newTotal.isFinite,
            "PositionManager.buy: totalInvested would become non-finite (state totalInvested=\(totalInvested) + \(totalCost))")
        let newAverage = newTotal / Double(combinedShares)
        // ② 写入
        shares = combinedShares
        averageCost = newAverage
        totalInvested = newTotal
        // ③ debug 兜底（§4.2.4 ③：不作主守门）
        assert(PositionManager.invariantsHold(shares: shares, averageCost: averageCost, totalInvested: totalInvested),
            "PositionManager.buy: post-mutation invariants violated (shares=\(shares), averageCost=\(averageCost), totalInvested=\(totalInvested))")
    }

    /// 卖出。§4.2.1 入口 1b：force-close 全零报价 → sell(0) no-op；oversell / 负值 = caller bug → trap。
    public mutating func sell(shares soldShares: Int) {
        if soldShares == 0 { return }   // D1 / §4.2.1 入口 1b：全零报价 no-op
        precondition(soldShares > 0,
            "PositionManager.sell: shares must be > 0 (got \(soldShares); 0 已作 no-op)")
        precondition(soldShares <= shares,
            "PositionManager.sell: cannot oversell (got \(soldShares) > holding \(shares))")
        let remaining = shares - soldShares
        if remaining == 0 {
            shares = 0
            averageCost = 0
            totalInvested = 0
        } else {
            shares = remaining
            // averageCost 不变；totalInvested = averageCost * remaining（精确赋值，§4.2.8 sell 安全）
            totalInvested = averageCost * Double(remaining)
        }
        // ③ debug 兜底
        assert(PositionManager.invariantsHold(shares: shares, averageCost: averageCost, totalInvested: totalInvested),
            "PositionManager.sell: post-mutation invariants violated (shares=\(shares), averageCost=\(averageCost), totalInvested=\(totalInvested))")
    }
```

- [ ] **Step 4：运行测试，确认通过（绿）**

Run: `cd ios/Contracts && swift test --filter PositionManagerTradeTests`
Expected: 6 tests pass，0 failures。

- [ ] **Step 5：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift
git commit -m "feat(e2): PositionManager buy/sell — precondition trap + 溢出预检 + sell(0) no-op（D1/D2，顺位 8）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：decoder reject 矩阵 + tol mutation demonstrator（D3/D4）

decoder 本体已在 Task 1 落地；本 task 仅**补齐 test surface**——证明 `invariantsHold` 在 decode 路径上真在判别（含 tol 双向 demonstrator，per `feedback_codex_fractional_subpixel_bias`）。

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift`（加 Codable suite）

- [ ] **Step 1：写测试（6 reject + round-trip-with-ULP + tol 边界）**

在 `PositionManagerTests.swift` 末尾追加：

```swift
@Suite("PositionManager 持久化 decoder 守门")
struct PositionManagerCodableTests {

    private func decode(_ json: String) throws -> PositionManager {
        try JSONDecoder().decode(PositionManager.self, from: Data(json.utf8))
    }

    // ---- 5 个 reject case（§4.2.8 各条；negative-shares 已在 Task 1 PositionManagerCoreTests 守 TDD，不重复）----

    @Test func rejectsNegativeTotalInvested() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":0,"averageCost":0.0,"totalInvested":-1.0}"#)
        }
    }

    // 超界数值：JSONDecoder 对 1e400 在 parse 阶段即抛 DecodingError（Swift Double 不可表示）；
    // 不依赖 decoder 自身 isFinite 分支（JSON 无法表达 NaN/Inf 字面），但结果同 → DecodingError。
    @Test func rejectsNonFiniteValues() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":100,"averageCost":1e400,"totalInvested":1e400}"#)
        }
    }

    // (shares==0) ⟺ (totalInvested==0) 违反：空仓但有投入
    @Test func rejectsZeroSharesWithNonZeroTotal() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":0,"averageCost":0.0,"totalInvested":100.0}"#)
        }
    }

    // (shares==0) ⟺ (totalInvested==0) 违反：有持仓但零投入
    @Test func rejectsPositiveSharesWithZeroTotal() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":100,"averageCost":10.0,"totalInvested":0.0}"#)
        }
    }

    // shares>0 ⟹ averageCost>0 违反：有持仓但零均价
    @Test func rejectsPositiveSharesWithZeroAverageCost() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":100,"averageCost":0.0,"totalInvested":1000.0}"#)
        }
    }

    // ---- D4 tol 双向 demonstrator ----

    // 正向：buy 产生真实除-乘 ULP 误差的合法存档 → decode 成功（若用 == 会拒收 → 反证 tol 必要）
    @Test func acceptsAppWrittenArchiveWithRoundingError() throws {
        var p = PositionManager()
        p.buy(shares: 300, totalCost: 1001.0)   // averageCost = 1001/300；avg*300 与 1001 差 ~1.1e-13（ULP）
        // 自证这是真 demonstrator：avg*shares 与 totalInvested 有非零 round 误差（严格 == 会拒收），但在 tol 内
        let gap = abs(p.averageCost * Double(p.shares) - p.totalInvested)
        #expect(gap > 0)
        #expect(gap <= PositionManager.invariantTolerance * max(1.0, abs(p.totalInvested)))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PositionManager.self, from: data)
        #expect(decoded == p)
    }

    // 负向 / mutation：合法态 totalInvested 篡改 2× 远超 tol → decode 抛（若 fall-open 会漏过）
    @Test func rejectsCorruptedTotalInvestedBeyondTolerance() {
        // 合法基准: shares=100, avg=10 → totalInvested 应 ≈1000；篡改成 2000
        #expect(throws: DecodingError.self) {
            try decode(#"{"shares":100,"averageCost":10.0,"totalInvested":2000.0}"#)
        }
    }

    // 边界：just-within tol 接受 / just-beyond tol 拒绝（证明 tol 是真判别阈，非 fall-open）
    @Test func tolBoundaryDiscriminates() throws {
        let exact = 10.0 * 100.0   // 1000，avg*shares
        let tol = PositionManager.invariantTolerance
        let margin = tol * max(1.0, abs(exact))
        let within = exact + 0.5 * margin
        let beyond = exact + 2.0 * margin

        let withinJSON = "{\"shares\":100,\"averageCost\":10.0,\"totalInvested\":\(within)}"
        #expect(throws: Never.self) {
            try decode(withinJSON)
        }

        let beyondJSON = "{\"shares\":100,\"averageCost\":10.0,\"totalInvested\":\(beyond)}"
        #expect(throws: DecodingError.self) {
            try decode(beyondJSON)
        }
    }
}
```

- [ ] **Step 2：运行测试，确认通过（绿）**

Run: `cd ios/Contracts && swift test --filter PositionManagerCodableTests`
Expected: 8 tests pass，0 failures。（decoder 已在 Task 1 实现，本 suite 验证其守门覆盖；negative-shares reject 在 Task 1 核心 suite。）

> 若 `acceptsAppWrittenArchiveWithRoundingError` 或 `tolBoundaryDiscriminates` 失败：说明 `invariantTolerance` 选值与 JSON Double 往返不匹配——这是 D4 要捕捉的真信号，**不要**盲目放大 tol；先打印 `abs(decoded.averageCost*Double(decoded.shares) - decoded.totalInvested)` 与 `margin` 对比，按实测 ULP 量级定 tol（systematic-debugging）。

- [ ] **Step 3：跑全量 PositionManager 测试 + 全 package**

Run:
```bash
cd ios/Contracts && swift test --filter PositionManager
cd ios/Contracts && swift test
```
Expected: PositionManager 全 suites 通过；全 package 在既有 415 基础上 +20 左右、0 failures。

- [ ] **Step 4：Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/PositionManagerTests.swift
git commit -m "test(e2): PositionManager decoder reject 矩阵（6 case）+ tol 双向 mutation demonstrator（D3/D4，顺位 8）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：CONTRACT_VERSION bump 三件套（D5 · §4.2.7 MANDATORY 门）

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift`（断言 + 函数名 → 1.5）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift`（常量 → 1.5）
- Modify: `docs/governance/m01-schema-versioning-contract.md`（矩阵 cell → 1.5 + changelog）
- Modify: `kline_trainer_modules_v1.4.md`（矩阵 cell → 1.5）
- Modify: `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`（断言 → 1.5）

- [ ] **Step 1：先改测试断言（红）**

`ModelsTests.swift` L6-9，把：

```swift
    @Test func contractVersionIs1_4() {
        #expect(CONTRACT_VERSION == "1.4")
    }
```

改为：

```swift
    @Test func contractVersionIs1_5() {
        #expect(CONTRACT_VERSION == "1.5")
    }
```

- [ ] **Step 2：运行测试，确认失败（红）**

Run: `cd ios/Contracts && swift test --filter ContractVersionTests`
Expected: FAIL —— `CONTRACT_VERSION == "1.5"` 不成立（常量仍 "1.4"）。

- [ ] **Step 3：bump 常量（绿）**

`Models.swift:7`，把 `public let CONTRACT_VERSION = "1.4"` 改为 `public let CONTRACT_VERSION = "1.5"`。

- [ ] **Step 4：运行测试，确认通过（绿）**

Run: `cd ios/Contracts && swift test --filter ContractVersionTests`
Expected: PASS。

- [ ] **Step 5：同步 m01 矩阵 cell + 加 changelog 一行**

`docs/governance/m01-schema-versioning-contract.md` L29，把矩阵行的 `` `"1.4"` `` 改为 `` `"1.5"` ``（**仅顶层 CONTRACT_VERSION 这一行**；PostgreSQL `0003_v1.3` / 训练组 `1` / app.sqlite `0003_v1.4_purge_leased` 三行**不动**——D5：position_data 无 DDL 变更）。

并在该文件 `## CONTRACT_VERSION 矩阵` 标题下、矩阵表格**之后**插入一行 changelog（紧接表格末行的下一空行）：

```markdown
> **bump 记录（2026-05-25，Wave 1 顺位 8 E2）**：顶层 `CONTRACT_VERSION` `"1.4"` → `"1.5"`。触发 = E2 PositionManager typed throwing `init(from:)` 把 `position_data` 列从"任何字节"收紧为"合法否则拒收"，命中 §Bump 策略 **A 类"改既有语义"**。**无 DDL 变更**（`position_data` 仍 `TEXT NOT NULL`，收紧属 reader 侧语义），故仅 bump 顶层标识，三套存储 sub-version（PostgreSQL/训练组/app.sqlite）不变、不新增 migration 文件。详见 `kline_trainer_plan_v1.5.md` §4.2.7。
```

- [ ] **Step 6：同步 modules 矩阵 cell**

`kline_trainer_modules_v1.4.md` L144，把矩阵顶层 CONTRACT_VERSION 行的 `` `"1.4"` `` 改为 `` `"1.5"` ``（同样仅这一行）。

- [ ] **Step 7：同步 plan_1f acceptance 断言 + 跑脚本**

`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` L42-44，把：

```bash
run "matrix row: CONTRACT_VERSION top | \`\"1.4\"\`" \
    grep -qE '^\|.*CONTRACT_VERSION.*\| *`?"1\.4"`? *\|' \
    <(awk '/^## CONTRACT_VERSION 矩阵$/,/^## Bump 策略/' "$DOC")
```

改为（`1.4` → `1.5`，描述同步）：

```bash
run "matrix row: CONTRACT_VERSION top | \`\"1.5\"\`" \
    grep -qE '^\|.*CONTRACT_VERSION.*\| *`?"1\.5"`? *\|' \
    <(awk '/^## CONTRACT_VERSION 矩阵$/,/^## Bump 策略/' "$DOC")
```

Run: `bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`
Expected: 全部断言 OK（矩阵 6 行含新 "1.5" 顶层 cell + bump 策略文本不变）。

- [ ] **Step 8：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift \
        docs/governance/m01-schema-versioning-contract.md \
        kline_trainer_modules_v1.4.md \
        scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
git commit -m "feat(e2): CONTRACT_VERSION bump 1.4→1.5 三件套（§4.2.7 MANDATORY · 仅顶层，无 DDL，顺位 8）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5：spec §4.2 同步——移除 positionTier 占位 + flip §4.2.8 注（D6）

**Files:**
- Modify: `kline_trainer_plan_v1.5.md`（§4.2 illustrative 代码块 + §4.2.8 positionTier 注）

- [ ] **Step 1：移除 §4.2 代码块内 positionTier 占位**

在 `kline_trainer_plan_v1.5.md` §4.2 PositionManager `struct` 代码块内，删除以下整段（约 L654-659，含其上方空行）：

```swift
    
    /// 当前仓位档位（0~5）—— ⚠️ 占位符：见 §4.2.8 positionTier 注（caller-derived，顺位 8 移除本 member）
    var positionTier: Int {
        // 占位返回 0；真实档位由 caller（E4/E5）依初始资金 + 当前持仓推导（顺位 8 落地）
        0
    }
```

使代码块以 `holdingCost` 计算属性 + `}` 闭合（`holdingCost` 行保留）。

- [ ] **Step 2：flip §4.2.8 positionTier 注为"已移除"**

把 §4.2.8 末尾 `positionTier` 注（约 L736）：

```markdown
**`positionTier` 注**：本节**上方** PositionManager struct 代码块里的 `var positionTier: Int { 0 }` 是占位符；档位需"初始资金"（不在 PositionManager 状态内）→ 判定 **caller-derived**（E4/E5 依初始资金 + 当前持仓推导）；**顺位 8 从 PositionManager 移除此 member**。本 RFC 仅 codify 此契约，不改算术。
```

改为：

```markdown
**`positionTier` 注**：档位需"初始资金"（不在 PositionManager 状态内）→ 判定 **caller-derived**（E4/E5 依初始资金 + 当前持仓推导）；**顺位 8 已从 PositionManager 移除此占位 member**（连同本节上方 illustrative 代码块的占位行），生产 `PositionManager.swift` 不含 `positionTier`。
```

- [ ] **Step 3：验证 positionTier 在 spec §4.2 区不再以"实现"出现 + impl 无 positionTier**

Run:
```bash
grep -n "positionTier" kline_trainer_plan_v1.5.md
grep -c "positionTier" ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift || echo "0 (impl 无 positionTier)"
```
Expected: spec 内 `positionTier` 仅剩 §4.2.8 注的"caller-derived / 已移除"叙述（无 `var positionTier: Int` 代码行）；impl grep `-c` = 0。

- [ ] **Step 4：Commit**

```bash
git add kline_trainer_plan_v1.5.md
git commit -m "docs(e2): spec §4.2 移除 positionTier 占位 + §4.2.8 注 flip 为已移除（D6 · §4.2.8 mandate，顺位 8）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6：验收 hook 脚本（§4.2.7 enforcement + 结构/bump-sync/M0.4 断言）

**Files:**
- Create: `scripts/acceptance/plan_e2_position_manager.sh`

- [ ] **Step 1：创建验收脚本**

创建 `scripts/acceptance/plan_e2_position_manager.sh`：

```bash
#!/usr/bin/env bash
# 验收脚本 — E2 PositionManager（Wave 1 顺位 8 / 第 10 个 PR）
# §4.2.7 enforcement：typed decoder 落地 ⟹ CONTRACT_VERSION bump 必须同 PR；
# 外加 trust-boundary 结构 / bump 矩阵同步 / M0.4 豁免断言。
set -uo pipefail
cd "$(dirname "$0")/../.."

PM="ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift"
MODELS="ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift"
M01="docs/governance/m01-schema-versioning-contract.md"
MODULES="kline_trainer_modules_v1.4.md"
SPEC="kline_trainer_plan_v1.5.md"

fail=0
ok()   { echo "OK:   $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
want() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }      # 期望成功
wantn(){ if eval "$2"; then bad "$1"; else ok "$1"; fi; }      # 期望失败（NOT 命中）

# ---- §4.2.7 义务门：decoder 落地 ⟹ CONTRACT_VERSION 已离开 1.4 且 == 1.5 ----
if grep -q 'init(from decoder' "$PM"; then
  wantn "§4.2.7 门: decoder 落地则 CONTRACT_VERSION 不得仍为 1.4" "grep -qE 'CONTRACT_VERSION = \"1\\.4\"' '$MODELS'"
  want  "§4.2.7 门: CONTRACT_VERSION 已 bump 为 1.5"             "grep -qE 'CONTRACT_VERSION = \"1\\.5\"' '$MODELS'"
else
  ok "§4.2.7 门: 无 typed decoder（bump 不强制）"
fi

# ---- trust-boundary 结构（§4.2.1/§4.2.4/§4.2.8/D1/D6）----
want  "buy/sell precondition trap 存在"        "grep -q 'precondition(' '$PM'"
want  "持久化 decoder 抛 DecodingError"         "grep -q 'DecodingError' '$PM'"
want  "invariantsHold 守门存在"                 "grep -q 'invariantsHold' '$PM'"
want  "sell(0) no-op 分支存在（D1）"            "grep -q 'no-op' '$PM'"
wantn "positionTier 已移除（D6/§4.2.8）"         "grep -q 'positionTier' '$PM'"

# ---- bump 矩阵同步（D5）----
want "m01 矩阵 CONTRACT_VERSION = 1.5"     "grep -qE '^\\|.*CONTRACT_VERSION.*\\| *\`?\"1\\.5\"\`? *\\|' '$M01'"
want "modules 矩阵 CONTRACT_VERSION = 1.5" "grep -qE '^\\|.*CONTRACT_VERSION.*\\| *\`?\"1\\.5\"\`? *\\|' '$MODULES'"

# ---- M0.4 豁免（D7）：PositionManager 不引用 AppError ----
wantn "M0.4 豁免: PositionManager 不引用 AppError" "grep -q 'AppError' '$PM'"

# ---- spec 同步（D6）：§4.2 区不再有 positionTier 代码行 ----
wantn "spec §4.2 无 'var positionTier' 代码行" "grep -q 'var positionTier' '$SPEC'"

if [ "$fail" -ne 0 ]; then echo "=== E2 ACCEPTANCE FAILED ==="; exit 1; fi
echo "=== ALL E2 ACCEPTANCE CHECKS PASSED ==="
```

- [ ] **Step 2：赋可执行 + 运行**

Run:
```bash
chmod +x scripts/acceptance/plan_e2_position_manager.sh
bash scripts/acceptance/plan_e2_position_manager.sh
```
Expected: 每行 `OK: ...`，末行 `=== ALL E2 ACCEPTANCE CHECKS PASSED ===`，exit 0。

- [ ] **Step 3：Commit**

```bash
git add scripts/acceptance/plan_e2_position_manager.sh
git commit -m "test(e2): 验收 hook 脚本 — §4.2.7 enforcement + 结构/bump-sync/M0.4 断言（顺位 8）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7：非 coder 中文验收清单

**Files:**
- Create: `docs/acceptance/2026-05-25-pr-e2-position-manager.md`

- [ ] **Step 1：创建验收清单**

创建 `docs/acceptance/2026-05-25-pr-e2-position-manager.md`：

````markdown
# 验收清单 — E2 PositionManager 实施（Wave 1 顺位 8 / 第 10 个 PR）

> 给非程序员逐条核对。每条：照"动作"敲命令 → 比对"期望" → 在"通过"打 ✓/✗。命令在仓库根目录运行。
> 模块 E2 `PositionManager` = 加权平均成本持仓值类型；进程内交易违约直接崩（trap，因上游已守门），只有读存档（可能损坏）才走"抛错拒收"。本 PR 同时把数据契约版本号从 1.4 升到 1.5（因为读存档变严了）。

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | 运行：`cd ios/Contracts && swift test --filter PositionManager` | 全部通过，0 失败（约 20 项：核心 6 + 交易 6 + 持久化 8） | ☐ |
| 2 | 运行：`cd ios/Contracts && swift test` | 全 package 通过，0 失败（在既有 415 基础上增加约 20 项） | ☐ |
| 3 | 运行：`bash scripts/acceptance/plan_e2_position_manager.sh` | 每行 `OK:`，末行 `=== ALL E2 ACCEPTANCE CHECKS PASSED ===` | ☐ |
| 4 | 运行：`bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | 全部断言通过（含矩阵顶层 CONTRACT_VERSION 已是 1.5） | ☐ |
| 5 | 运行：`grep -n 'CONTRACT_VERSION = ' ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | 显示 `= "1.5"`（版本号已升） | ☐ |
| 6 | 运行：`grep -c 'positionTier' ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift` | 输出 `0`（占位档位已移除，改由调用方推导） | ☐ |
| 7 | 运行：`grep -n 'init(from decoder' ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift` | 命中（持久化用"会抛错"的自定义解码器） | ☐ |
| 8 | 运行：`grep -n 'AppError' ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift` | **无任何输出**（本类型不碰 AppError，M0.4 豁免） | ☐ |
| 9 | 运行：`grep -n 'no-op' ios/Contracts/Sources/KlineTrainerContracts/PositionManager.swift` | 命中 sell(0) no-op（局终强平零报价不崩） | ☐ |
| 10 | 运行：`git diff --stat main...HEAD` | 改动文件 = PositionManager.swift / PositionManagerTests.swift / Models.swift / ModelsTests.swift / m01 契约 / modules / plan_1f 脚本 / plan_v1.5 / 新验收脚本 / 本清单 / plan 文档（**无新增 migration / 无新 .sql**） | ☐ |
| 11 | 运行：`git diff --name-only main...HEAD \| grep -E '\.sql$\|migration'` | **无任何输出**（仅顶层版本号 bump，无 DDL/migration —— 见 plan §4.2.7 / D5） | ☐ |

**任一条 ✗ → 不得 merge。** 第 1/2/3 条是硬门（功能 + 守门 + 契约同步真绿）；第 11 条证明"只升版本号、没动数据库结构"。
````

- [ ] **Step 2：验证清单创建成功**

Run: `test -f docs/acceptance/2026-05-25-pr-e2-position-manager.md && grep -c '| ☐ |' docs/acceptance/2026-05-25-pr-e2-position-manager.md`
Expected: 输出 `11`。

- [ ] **Step 3：Commit**

```bash
git add docs/acceptance/2026-05-25-pr-e2-position-manager.md
git commit -m "docs(e2): 非 coder 中文验收清单（11 条 · 顺位 8）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Final verification（全部 task 完成后，进 requesting-code-review 前）

- [ ] `cd ios/Contracts && swift build` → Build complete!
- [ ] `cd ios/Contracts && swift test` → 全 package 0 failures（约 435 in 83+ suites）
- [ ] Catalyst：`xcodebuild build-for-testing -scheme <scheme> -destination 'platform=macOS,variant=Mac Catalyst'` → TEST BUILD SUCCEEDED（CI 必绿，不绕过）
- [ ] `bash scripts/acceptance/plan_e2_position_manager.sh` → ALL PASSED
- [ ] `bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` → 全通过
- [ ] `git diff --name-only main...HEAD | grep -E '\.sql$'` → 空（无 DDL）
- [ ] strict-concurrency：`swift build -Xswiftc -strict-concurrency=complete`（per `feedback_swift_local_toolchain_blindspot`：本地新 toolchain 有盲区，CI macos-15 为准）

---

## Self-Review（writing-plans 自查）

**1. Spec coverage（§4.2.1–§4.2.8 逐节）：**
- §4.2.1 trust-boundary（1a/1b/1c/2）→ Task 1 decoder（入口2 throws）+ Task 2 buy/sell（入口1a/1b trap）+ D1 sell(0) no-op ✓
- §4.2.2 stdlib 一致性 → buy/sell trap / decoder throws（Task 1/2 注释引用）✓
- §4.2.3 threat model → D5 bump 安全性论证 + decoder isFinite 守门 ✓
- §4.2.4 溢出语义（①预检 trap / ②写 / ③assert 兜底）→ Task 2 buy/sell 三步 + D2 ✓
- §4.2.5 considered alternatives → 不入代码（设计理由，已 RFC 冻结）✓
- §4.2.6 acceptance/testability（违约路径不在 test surface）→ Task 2/3 只测合法 + decoder reject，不测 trap ✓
- §4.2.7 migration + bump 门 → Task 4 三件套 + Task 6 §4.2.7 enforcement hook + D5 ✓
- §4.2.8 invariantsHold（4 条 + tol 相对容差）→ Task 1 invariantsHold + D3 字面 RHS + D4 tol demonstrator ✓
- §4.2.8 positionTier 注 → Task 5 D6 移除 ✓

**2. Placeholder scan：** 无 TBD/TODO/"待补"。`tol=1e-9` 是确定值（D4 给 mutation 测试，非占位）。

**3. Type/命名一致性：** `PositionManager` / `shares`/`averageCost`/`totalInvested` / `invariantsHold(shares:averageCost:totalInvested:)` / `invariantTolerance` / `init(from:)` / `buy(shares:totalCost:)` / `sell(shares:)` / `holdingCost` / `CONTRACT_VERSION` / `contractVersionIs1_5` 全 plan 内一致，且与源文件签名（§4.2 struct、Models.swift、ModelsTests.swift）核对过。

**4. Scope（CLAUDE.md §3 surgical）：** 仅本模块 + §4.2.7/§4.2.8 RFC 已授权的 bump/positionTier follow-through；无新 migration / 无 .sql / 不动其它冻结类型。3 子项 / ~200 prod 行 « 500（per `feedback_planner_packaging_bias`）。

**5. 与归档 delta 显式声明：** D1（sell(0) no-op）/ D2（assert 非 precondition）/ D3（tol RHS 字面）/ D4（tol mutation-verify）四处相对 `pr1-e2-position-manager` 归档实现的修正全部书面化，供 reviewer 对照——不静默复用归档。
