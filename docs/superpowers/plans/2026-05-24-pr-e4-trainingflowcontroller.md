# E4 TrainingFlowController Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 E4 `TrainingFlowController` —— 一个协议 + Normal/Review/Replay 三个值类型实现，把训练模式的"能力矩阵"（可买卖 / 可步进 / 是否存档 / 是否累加资金 / 是否结算 / 是否触觉）编码为纯查询，供 Wave 2 E5 TrainingEngine 注入。

**Architecture:** 纯值类型模块，零副作用、零 IO、零 actor 跨界。一个 `protocol TrainingFlowController`（10 个只读成员）+ 三个 `struct`（`NormalFlow` / `ReviewFlow` / `ReplayFlow`）各自显式实现协议全部成员。行为权威来自 plan v1.5 §5.0 的 **Capability Matrix**；每个 struct = 矩阵对应列的逐格转写。不引入 protocol extension 默认实现（理由见 §设计决策）。

**Tech Stack:** Swift 6.0（swift-tools-version 6.0）、SwiftPM `KlineTrainerContracts` target、Swift Testing（`import Testing` / `@Suite` / `@Test` / `#expect`）。复用已冻结类型 `TrainingMode` / `FeeSnapshot` / `TrainingRecord`。

**Wave 1 顺位：** 6（交付序第 8 个 PR）。依赖 E3（同属业务逻辑组，已 merged PR #62）。范围估算 ~95 行 prod。

---

## Task 0 — §15.3 评审策略前置（per `docs/governance/wave1-plan-template.md`）

- [x] **局部对抗性评审（必）：** 本 plan 子模块 scope 内对抗性评审；**用户 session 开头明示用另一个 Claude opus 4.7 xhigh effort 做对抗性 review（非 codex）**，两道闸门（plan-stage + branch-diff）均由 opus 4.7 xhigh 执行，4-5 轮内收敛或 escalate（per memory `feedback_codex_plan_budget_overshoot` + `feedback_review_tool_switch_must_ask`：用户指定的 review 工具是契约）。
- [ ] **集成层评审（N/A）：** 本 PR 不含 C8 桥接 / E5 编排；E4 只被 Wave 2 E5 消费，集成层评审在 Wave 2 E5 PR。
- [ ] **性能评审（N/A）：** 非 Phase 5 磨光 PR；纯布尔/整数查询无性能热点。

完成 Task 0 才进 Task 1 实施。

---

## 设计决策（实施前必读 —— 这是本 PR 的核心判断点）

### D1. 两份 spec 的协议不自洽 → 以 Capability Matrix 为行为权威

两处 spec 对 `TrainingFlowController` 的描述存在漂移：

- **`kline_trainer_modules_v1.4.md` §E4（L1529-1576，标注"v1.2 验收文字修正"）** —— 模块级权威协议，10 个成员：`mode` / `feeSnapshot` / `initialTick` / `allowedTickRange` + 6 个布尔方法（含 `shouldGiveHapticFeedback()`）。
- **`kline_trainer_plan_v1.5.md` §5.0（L744-775）** —— 高层设计，协议只列 6 个成员（缺 `feeSnapshot` / `initialTick` / `allowedTickRange` / `shouldGiveHapticFeedback`），但附了一张权威的 **Capability Matrix**（含"触觉反馈"行）。

**采用协议形状 = modules v1.4 §E4 的 10 成员超集**（它是模块级、且更新——"v1.2 验收文字修正"）。

**采用行为权威 = plan v1.5 §5.0 Capability Matrix**：

| 能力（方法） | Normal | Review | Replay |
|---|---|---|---|
| `canBuySell()` | `true` | `false` | `true` |
| `canAdvance()` | `true` | `false` | `true` |
| `shouldSaveRecord()` | `true` | `false` | `false` |
| `shouldAccumulateCapital()` | `true` | `false` | `false` |
| `shouldShowSettlement()` | `true` | `false` | `true` |
| `shouldGiveHapticFeedback()` | `true` | `false` | `true` |

属性权威（modules v1.4 §E4 struct 示例 + 验收文字）：

| 属性 | NormalFlow | ReviewFlow | ReplayFlow |
|---|---|---|---|
| `mode` | `.normal` | `.review` | `.replay` |
| `feeSnapshot` | `fees`（注入） | `record.feeSnapshot` | `feeSnapshotFromOriginal` |
| `initialTick` | `0` | `record.finalTick` | `0` |
| `allowedTickRange` | `0...maxTick` | `record.finalTick...record.finalTick` | `0...maxTick` |

### D2. 不用 protocol extension 默认实现；每个 struct 显式实现全部 6 个布尔方法（关键判断）

modules v1.4 §E4 的三个 struct 示例只写出"差异化 override"：`NormalFlow` 0 个方法、`ReviewFlow` 只 override `canAdvance`/`canBuySell` 两个、`ReplayFlow` 只 override `shouldSaveRecord` 一个。**这套示例与 Capability Matrix 不自洽**：

- 若按字面（假设有"全 true"默认 + 部分 override），`ReviewFlow` 的 `shouldSaveRecord`/`shouldAccumulateCapital`/`shouldShowSettlement`/`shouldGiveHapticFeedback` 会落到默认 `true`，违反矩阵"Review 全 ❌"。
- `ReplayFlow` 的 `shouldAccumulateCapital` 会落到默认 `true`，违反矩阵"Replay 资金累加 ❌"。

**结论：spec struct 示例是不完整/不自洽的，矩阵 + 验收文字才是权威。** 三种实现路线对比：

| 路线 | 描述 | 取舍 |
|---|---|---|
| **A（采用）** | 每个 struct 显式实现全部 6 个布尔方法 = 矩阵对应列逐格转写；无 protocol extension 默认 | 每个 (mode × 能力) 格在唯一一处（struct 内）显式可见，是矩阵的 1:1 转写；reviewer 读一个 struct 即见全部 6 个返回值；消除"默认 + 部分 override"交互（正是它令 spec 示例出错）。代价：NormalFlow 多 6 行 `return true`——可接受，模块极小 |
| B（拒绝） | protocol extension 默认 = 全 true（Normal 语义）+ 各 struct override 偏差 | 按字面 ReviewFlow 要 override 6 个、ReplayFlow 2 个——已偏离 spec 示例所列数量；且"默认 + 部分 override"正是缺陷来源 |
| C（拒绝） | protocol extension 用 `mode` 派生默认（如 `mode != .review`） | 最 DRY 但把能力逻辑隐式耦合到 `mode` 比较；若日后新增第 4 种 mode，默认会静默套用错误能力；且令 spec 所列 override 全部冗余 |

**对 spec 字面的偏离声明：** 路线 A 给 `NormalFlow` 加了 6 个方法体（spec 示例为空）、给 `ReviewFlow`/`ReplayFlow` 补齐了矩阵要求但 spec 示例遗漏的 override。这是**有意的、为消除 spec 示例自身的不自洽**——没有 protocol 默认时协议要求必须由 conformer 满足，spec 的空 `NormalFlow` 仅在"假设有默认"下可编译，而那个假设的默认正是令 ReviewFlow/ReplayFlow 出错的根因。

### D3. `allowedTickRange = 0...maxTick` 的 `maxTick >= 0` 前置条件

`0...maxTick`（`ClosedRange<Int>`）在 `maxTick < 0` 时运行时 trap。`maxTick` 来自训练组 K 线根数 - 1，调用方保证 ≥ 0。**遵循 spec 字面 `0...maxTick`，不做防御性 clamp**（CLAUDE.md "No error handling for impossible scenarios"；clamp 会掩盖调用方 bug）。以 doc comment 记录该 caller precondition。`ReviewFlow` 的 `record.finalTick...record.finalTick` 上下界相等，恒为合法 `ClosedRange`。

### D4. 不加 `Sendable` 标注

参照 E3 `TradeCalculator`（public `BuyQuote`/`SellQuote` 均**未**标 `Sendable`，编译通过）：public 值类型只有跨 actor 发送时才需 `Sendable`。E4 本 PR 仅有单元测试，无 actor 跨界；Wave 2 E5 `TrainingEngine` 是 `@MainActor` class，`let flow` 作其存储属性不构成跨界发送。三个 struct 成员（`FeeSnapshot`/`Int`/`ClosedRange<Int>`/`TrainingRecord`）均为 Sendable，未来如需可零成本补 `Sendable`。本 PR 保持最小、与 TradeCalculator 先例一致——不标注。

### D5. M0.4 豁免

E4 纯 capability 查询，返 `Bool`/`Int`/`ClosedRange<Int>`，从不 `throws`、从不消费 `AppError`。同 E3 = 豁免（`docs/governance/m04-apperror-translation-gate.md`）。本 PR 在该 gate doc 应用范围表补一行 `E4 TrainingFlowController | 否 | 纯 capability 查询，不 throws`，保持注册表完整可审。

---

## File Structure

- **Create** `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift`
  - 责任：`protocol TrainingFlowController` + `NormalFlow` + `ReviewFlow` + `ReplayFlow`。放 `TrainingEngine/` 目录（与 `TrainingEngine.swift` / `TrainingSessionCoordinator.swift` 同模块家族，对应 spec `ViewModels/` 分组）。
- **Create** `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingFlowControllerTests.swift`
  - 责任：三个 per-struct 属性+方法 suite + 一个 Capability Matrix 逐列 sweep suite + spec 验收文字对应测试。
- **Modify** `docs/governance/m04-apperror-translation-gate.md`（应用范围表加 1 行 E4 = 否）。
- **Create** `docs/acceptance/2026-05-24-pr-e4-trainingflowcontroller.md`（中文非 coder 验收清单）。

**冻结契约文件不碰：** `Models/Models.swift`（`TrainingMode`/`FeeSnapshot`）、`AppState.swift`（`TrainingRecord`）、`AppError.swift`、`Package.swift` 全部不改。

---

## Task 1: 协议 + NormalFlow

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingFlowControllerTests.swift`

- [ ] **Step 1: 写失败测试（test 文件头 + NormalFlow suite）**

写入 `TrainingFlowControllerTests.swift`：

```swift
import Testing
@testable import KlineTrainerContracts

// MARK: - Fixtures

private let normalFees = FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true)
private let originalFees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false)

/// 构造一条原局 record（仅用于 ReviewFlow 测试）；非默认字段不参与 E4 逻辑。
private func makeRecord(finalTick: Int, feeSnapshot: FeeSnapshot) -> TrainingRecord {
    TrainingRecord(
        id: 1, trainingSetFilename: "x.sqlite", createdAt: 0,
        stockCode: "600519", stockName: "贵州茅台",
        startYear: 2021, startMonth: 8,
        totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
        buyCount: 0, sellCount: 0,
        feeSnapshot: feeSnapshot, finalTick: finalTick
    )
}

@Suite("NormalFlow")
struct NormalFlowTests {
    private let flow = NormalFlow(fees: normalFees, maxTick: 1000)

    @Test("属性：mode/feeSnapshot/initialTick/allowedTickRange")
    func properties() {
        #expect(flow.mode == .normal)
        #expect(flow.feeSnapshot == normalFees)
        #expect(flow.initialTick == 0)
        #expect(flow.allowedTickRange == 0...1000)
    }

    @Test("能力：全 true（矩阵 Normal 列）")
    func capabilities() {
        #expect(flow.canBuySell())
        #expect(flow.canAdvance())
        #expect(flow.shouldSaveRecord())
        #expect(flow.shouldAccumulateCapital())
        #expect(flow.shouldShowSettlement())
        #expect(flow.shouldGiveHapticFeedback())
    }

    @Test("验收：启动后 tick==0 且 canAdvance==true（spec modules §E4 验收）")
    func acceptance() {
        #expect(flow.initialTick == 0)
        #expect(flow.canAdvance())
    }
}
```

- [ ] **Step 2: 跑测试确认失败（编译失败 = RED）**

Run: `swift test --package-path ios/Contracts --filter NormalFlowTests`
Expected: 编译失败，报 `cannot find 'NormalFlow' in scope`（协议/struct 尚不存在）。

- [ ] **Step 3: 写最小实现（协议 + NormalFlow）**

写入 `TrainingFlowController.swift`：

```swift
// Kline Trainer Swift Contracts — E4 TrainingFlowController
// Spec: kline_trainer_modules_v1.4.md §E4（协议 10 成员 + Normal/Review/Replay 三实现）
//     + kline_trainer_plan_v1.5.md §5.0（Capability Matrix —— 行为权威表）
// M0.4: 豁免 — 纯 capability 查询，返 Bool/Int/ClosedRange<Int>，从不 throws AppError
//       (docs/governance/m04-apperror-translation-gate.md)
//
// 设计决策（见 plan docs/superpowers/plans/2026-05-24-pr-e4-trainingflowcontroller.md）：
// modules v1.4 §E4 的三个 struct 示例只列"差异化 override"，与 plan v1.5 §5.0 Capability
// Matrix 不自洽（矩阵要求 Review 全 ❌、Replay 的 shouldAccumulateCapital ❌）。本模块以
// Capability Matrix 为行为权威，每个 Flow 显式实现全部 6 个布尔方法 = 矩阵对应列的逐格
// 转写，不引入 protocol extension 默认实现（避免"默认 + 部分 override"交互——正是它令
// spec 示例 struct 自身出错）。

public protocol TrainingFlowController {
    var mode: TrainingMode { get }
    var feeSnapshot: FeeSnapshot { get }
    var initialTick: Int { get }
    var allowedTickRange: ClosedRange<Int> { get }

    func canBuySell() -> Bool
    func canAdvance() -> Bool
    func shouldSaveRecord() -> Bool
    func shouldAccumulateCapital() -> Bool
    func shouldShowSettlement() -> Bool
    func shouldGiveHapticFeedback() -> Bool
}

/// 正常训练：全能力开放。
/// - Precondition: `maxTick >= 0`（来自训练组 K 线根数 - 1，调用方保证）。
///   `allowedTickRange` 用 `0...maxTick`，maxTick < 0 时会 trap——与 spec 字面一致，
///   不做防御性 clamp（clamp 会掩盖调用方 bug）。
public struct NormalFlow: TrainingFlowController {
    public let fees: FeeSnapshot
    public let maxTick: Int

    public init(fees: FeeSnapshot, maxTick: Int) {
        self.fees = fees
        self.maxTick = maxTick
    }

    public var mode: TrainingMode { .normal }
    public var feeSnapshot: FeeSnapshot { fees }
    public var initialTick: Int { 0 }
    public var allowedTickRange: ClosedRange<Int> { 0...maxTick }

    public func canBuySell() -> Bool { true }
    public func canAdvance() -> Bool { true }
    public func shouldSaveRecord() -> Bool { true }
    public func shouldAccumulateCapital() -> Bool { true }
    public func shouldShowSettlement() -> Bool { true }
    public func shouldGiveHapticFeedback() -> Bool { true }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --package-path ios/Contracts --filter NormalFlowTests`
Expected: PASS，`0 failures`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingFlowControllerTests.swift
git commit -m "feat(E4): TrainingFlowController 协议 + NormalFlow"
```

---

## Task 2: ReviewFlow

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingFlowControllerTests.swift`

- [ ] **Step 1: 写失败测试（追加 ReviewFlow suite）**

在 `TrainingFlowControllerTests.swift` 追加：

```swift
@Suite("ReviewFlow")
struct ReviewFlowTests {
    private let record = makeRecord(finalTick: 742, feeSnapshot: originalFees)
    private var flow: ReviewFlow { ReviewFlow(record: record) }

    @Test("属性：mode/feeSnapshot=原局/initialTick=finalTick/单点 range")
    func properties() {
        #expect(flow.mode == .review)
        #expect(flow.feeSnapshot == originalFees)
        #expect(flow.initialTick == 742)
        #expect(flow.allowedTickRange == 742...742)
    }

    @Test("能力：全 false（矩阵 Review 列）")
    func capabilities() {
        #expect(!flow.canBuySell())
        #expect(!flow.canAdvance())
        #expect(!flow.shouldSaveRecord())
        #expect(!flow.shouldAccumulateCapital())
        #expect(!flow.shouldShowSettlement())
        #expect(!flow.shouldGiveHapticFeedback())
    }

    @Test("验收：initialTick == record.finalTick，不是 maxTick（spec v1.1→v1.2 修正点）")
    func initialTickIsFinalTickNotMaxTick() {
        // finalTick=742 与任意 maxTick 概念无关：ReviewFlow 不持有 maxTick，
        // allowedTickRange 锁死在 finalTick 单点 → canAdvance 必 false。
        #expect(flow.initialTick == record.finalTick)
        #expect(flow.allowedTickRange.lowerBound == flow.allowedTickRange.upperBound)
        #expect(!flow.canAdvance())
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --package-path ios/Contracts --filter ReviewFlowTests`
Expected: 编译失败，`cannot find 'ReviewFlow' in scope`。

- [ ] **Step 3: 写最小实现（追加 ReviewFlow）**

在 `TrainingFlowController.swift` 末尾追加：

```swift
/// 复盘（只读）：固定在原局结束态，全能力关闭。
public struct ReviewFlow: TrainingFlowController {
    public let record: TrainingRecord

    public init(record: TrainingRecord) {
        self.record = record
    }

    public var mode: TrainingMode { .review }
    public var feeSnapshot: FeeSnapshot { record.feeSnapshot }
    public var initialTick: Int { record.finalTick }
    public var allowedTickRange: ClosedRange<Int> { record.finalTick...record.finalTick }

    public func canBuySell() -> Bool { false }
    public func canAdvance() -> Bool { false }
    public func shouldSaveRecord() -> Bool { false }
    public func shouldAccumulateCapital() -> Bool { false }
    public func shouldShowSettlement() -> Bool { false }
    public func shouldGiveHapticFeedback() -> Bool { false }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --package-path ios/Contracts --filter ReviewFlowTests`
Expected: PASS，`0 failures`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingFlowControllerTests.swift
git commit -m "feat(E4): ReviewFlow（只读复盘，全能力关闭，initialTick=finalTick）"
```

---

## Task 3: ReplayFlow

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingFlowControllerTests.swift`

- [ ] **Step 1: 写失败测试（追加 ReplayFlow suite）**

在 `TrainingFlowControllerTests.swift` 追加：

```swift
@Suite("ReplayFlow")
struct ReplayFlowTests {
    private let flow = ReplayFlow(feeSnapshotFromOriginal: originalFees, maxTick: 1000)

    @Test("属性：mode/feeSnapshot=原局/initialTick=0/0...maxTick")
    func properties() {
        #expect(flow.mode == .replay)
        #expect(flow.feeSnapshot == originalFees)
        #expect(flow.initialTick == 0)
        #expect(flow.allowedTickRange == 0...1000)
    }

    @Test("能力：T,T,F,F,T,T（矩阵 Replay 列）")
    func capabilities() {
        #expect(flow.canBuySell())
        #expect(flow.canAdvance())
        #expect(!flow.shouldSaveRecord())          // 不保存
        #expect(!flow.shouldAccumulateCapital())   // 不累加资金
        #expect(flow.shouldShowSettlement())       // 显示结算但不保存
        #expect(flow.shouldGiveHapticFeedback())
    }

    @Test("验收：从头开始(tick=0)、用原局 feeSnapshot、结束不保存（spec modules §E4 验收）")
    func acceptance() {
        #expect(flow.initialTick == 0)
        #expect(flow.feeSnapshot == originalFees)
        #expect(!flow.shouldSaveRecord())
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --package-path ios/Contracts --filter ReplayFlowTests`
Expected: 编译失败，`cannot find 'ReplayFlow' in scope`。

- [ ] **Step 3: 写最小实现（追加 ReplayFlow）**

在 `TrainingFlowController.swift` 末尾追加：

```swift
/// 再来一次：可操作但不入账，沿用原局 FeeSnapshot。
/// - Precondition: `maxTick >= 0`（同 NormalFlow）。
public struct ReplayFlow: TrainingFlowController {
    public let feeSnapshotFromOriginal: FeeSnapshot
    public let maxTick: Int

    public init(feeSnapshotFromOriginal: FeeSnapshot, maxTick: Int) {
        self.feeSnapshotFromOriginal = feeSnapshotFromOriginal
        self.maxTick = maxTick
    }

    public var mode: TrainingMode { .replay }
    public var feeSnapshot: FeeSnapshot { feeSnapshotFromOriginal }
    public var initialTick: Int { 0 }
    public var allowedTickRange: ClosedRange<Int> { 0...maxTick }

    public func canBuySell() -> Bool { true }
    public func canAdvance() -> Bool { true }
    public func shouldSaveRecord() -> Bool { false }
    public func shouldAccumulateCapital() -> Bool { false }
    public func shouldShowSettlement() -> Bool { true }
    public func shouldGiveHapticFeedback() -> Bool { true }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --package-path ios/Contracts --filter ReplayFlowTests`
Expected: PASS，`0 failures`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingFlowControllerTests.swift
git commit -m "feat(E4): ReplayFlow（可操作不入账，沿用原局 fees）"
```

---

## Task 4: Capability Matrix 逐列 sweep 测试 + M0.4 注册 + 验收文档

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingFlowControllerTests.swift`
- Modify: `docs/governance/m04-apperror-translation-gate.md`
- Create: `docs/acceptance/2026-05-24-pr-e4-trainingflowcontroller.md`

- [ ] **Step 1: 写矩阵 sweep 测试（通过协议存在类型读，逐列断言全 6 格）**

在 `TrainingFlowControllerTests.swift` 追加。该 suite 把三列作为一个整体表断言，确保任何单格回归都会失败，且强制经由 `TrainingFlowController` 存在类型调用（验证多态分发，而非具体类型短路）：

```swift
@Suite("Capability matrix（逐列 sweep，经协议存在类型）")
struct TrainingFlowMatrixTests {
    /// 顺序：canBuySell, canAdvance, shouldSaveRecord,
    ///       shouldAccumulateCapital, shouldShowSettlement, shouldGiveHapticFeedback
    private func column(_ f: TrainingFlowController) -> [Bool] {
        [f.canBuySell(), f.canAdvance(), f.shouldSaveRecord(),
         f.shouldAccumulateCapital(), f.shouldShowSettlement(), f.shouldGiveHapticFeedback()]
    }

    @Test("Normal 列 = 全 true")
    func normalColumn() {
        let f: TrainingFlowController = NormalFlow(fees: normalFees, maxTick: 1000)
        #expect(column(f) == [true, true, true, true, true, true])
    }

    @Test("Review 列 = 全 false")
    func reviewColumn() {
        let f: TrainingFlowController = ReviewFlow(record: makeRecord(finalTick: 742, feeSnapshot: originalFees))
        #expect(column(f) == [false, false, false, false, false, false])
    }

    @Test("Replay 列 = T,T,F,F,T,T")
    func replayColumn() {
        let f: TrainingFlowController = ReplayFlow(feeSnapshotFromOriginal: originalFees, maxTick: 1000)
        #expect(column(f) == [true, true, false, false, true, true])
    }

    @Test("三列两两可区分（无两列相同，防复制粘贴塌缩）")
    func columnsAreDistinct() {
        let normal = column(NormalFlow(fees: normalFees, maxTick: 10))
        let review = column(ReviewFlow(record: makeRecord(finalTick: 5, feeSnapshot: originalFees)))
        let replay = column(ReplayFlow(feeSnapshotFromOriginal: originalFees, maxTick: 10))
        #expect(normal != review)
        #expect(normal != replay)
        #expect(review != replay)
    }
}
```

- [ ] **Step 2: 跑新 suite 确认通过**

Run: `swift test --package-path ios/Contracts --filter TrainingFlowMatrixTests`
Expected: PASS，`0 failures`（4 测试）。

- [ ] **Step 3: M0.4 注册表补 E4 行**

编辑 `docs/governance/m04-apperror-translation-gate.md`，在 `| Plan 3 | E3 TradeCalculator | 否 | 返 \`Result\`，不 throws |` 行之后追加一行：

```
| Plan 3 | E4 TrainingFlowController | 否 | 纯 capability 查询，返 Bool/Int，不 throws |
```

- [ ] **Step 4: 全量回归 + 构建 + Catalyst 闸门（verification-before-completion 时正式跑；此处先本地确认）**

Run: `swift test --package-path ios/Contracts`
Expected: `0 failures`（在 E3 的 399 基线上新增本模块测试）。

Run: `swift build --package-path ios/Contracts`
Expected: `Build complete!`，无 `error:`。

- [ ] **Step 5: 写验收文档**

创建 `docs/acceptance/2026-05-24-pr-e4-trainingflowcontroller.md`，中文、二元可决、命令可机器核验，结构参照 `docs/acceptance/2026-05-23-pr-e3-tradecalculator.md`：

- 一、自动闸门：`swift test --filter NormalFlowTests` / `ReviewFlowTests` / `ReplayFlowTests` / `TrainingFlowMatrixTests` 各 `0 failures`；全量 `swift test` `0 failures`；`swift build` `Build complete!`；Catalyst `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'` 出 `** TEST BUILD SUCCEEDED **`；`grep -c "throw " TrainingFlowController.swift` = 0（M0.4 豁免，throw 仅可能出现在注释）；`git diff --stat` 源码仅 `TrainingFlowController.swift` + `TrainingFlowControllerTests.swift` 两个源文件（冻结契约 `Models.swift`/`AppState.swift`/`AppError.swift`/`Package.swift` 未改）。
- 二、业务规则验收：逐条映射 Capability Matrix 三列 18 格 + 三个 struct 属性 + spec 三条验收文字（Normal tick==0 canAdvance；Review tick==finalTick canAdvance=false；Replay tick==0 用原局 fees 不保存）到具体测试名。
- 三、流程合规与偏差：如实记录 6 段 Superpowers 流程 + opus 4.7 xhigh 双闸门轮数 + D1-D5 设计决策（含对 spec struct 示例的有意偏离）。
- 禁忌词（`.claude/workflow-rules.json` `verification_template.forbidden_phrases`）：不得出现"验证通过即可/看起来正常/应该没问题/should work/looks fine"。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingFlowControllerTests.swift \
        docs/governance/m04-apperror-translation-gate.md \
        docs/acceptance/2026-05-24-pr-e4-trainingflowcontroller.md
git commit -m "test(E4): Capability Matrix sweep + M0.4 注册 + 验收文档"
```

---

## Self-Review（写完计划后对照 spec 复查）

**1. Spec coverage（逐条对照 modules v1.4 §E4 + plan v1.5 §5.0）：**
- 协议 10 成员 → Task 1 全列出 ✓
- `NormalFlow`（fees/maxTick；mode/feeSnapshot/initialTick=0/0...maxTick；全能力 true）→ Task 1 ✓
- `ReviewFlow`（record；mode/feeSnapshot=record/initialTick=finalTick/单点 range；全能力 false）→ Task 2 ✓
- `ReplayFlow`（feeSnapshotFromOriginal/maxTick；mode/feeSnapshot=原局/initialTick=0/0...maxTick；T,T,F,F,T,T）→ Task 3 ✓
- Capability Matrix 18 格 → Task 1-3 per-struct + Task 4 sweep 双重覆盖 ✓
- 三条验收文字（Normal/Review/Replay）→ Task 1/2/3 acceptance 测试 ✓
- M0.4 豁免登记 → Task 4 ✓
- 非 coder 验收清单 → Task 4 ✓

**2. Placeholder scan：** 无 TBD/TODO/"add error handling"；每个 code step 含完整代码；每个命令含 expected 输出。✓

**3. Type consistency：** 协议成员名 `canBuySell`/`canAdvance`/`shouldSaveRecord`/`shouldAccumulateCapital`/`shouldShowSettlement`/`shouldGiveHapticFeedback` + 属性 `mode`/`feeSnapshot`/`initialTick`/`allowedTickRange` 在 Task 1-4 全程一致；struct 成员 `fees`/`maxTick`/`record`/`feeSnapshotFromOriginal` 一致；复用类型 `TrainingMode`/`FeeSnapshot`/`TrainingRecord` 签名已与代码库核对（`TrainingMode` 为 `Equatable, Sendable`；`TrainingRecord.finalTick: Int` / `.feeSnapshot: FeeSnapshot` 存在）。✓

---

## Execution Handoff

按用户 session 开头明示：本 plan 后续走 **plan-stage 对抗性 review（opus 4.7 xhigh，收敛）→ subagent-driven-development → verification-before-completion → requesting-code-review → branch-diff 对抗性 review（opus 4.7 xhigh，收敛）**。执行采用 **Subagent-Driven**（superpowers:subagent-driven-development），每 Task 一个 fresh subagent + 两阶段 review。
