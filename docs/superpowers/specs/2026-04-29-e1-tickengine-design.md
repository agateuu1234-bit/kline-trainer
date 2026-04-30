# E1 TickEngine — Implementation Design

> **Status**：approved 2026-04-29，Opus 4.7 xhigh adversarial review Round 1 (0 Critical / 3 Important / 3 Minor) accept verdict.
>
> **起因**：Wave 0 启动锚从 E2 PositionManager 切到 E1 TickEngine（per memory `feedback_module_level_abort_signal.md`，E2 v1+v2+v3 三连 abort，spec §4.2 vs codex defense-in-depth bias 永久冲突）。E1 在 modules §E1 + plan §3 双引用，body 完整，无 trust-boundary / 无 persistence / 无 mutation invariant 复杂度，是 codex review 友好的纯计算模块。

## Goal

落地 modules §E1 + plan §3 的 `TickEngine` 值类型 —— 单用户训练期"全局唯一时间状态"。

## Architecture

E1 是 SwiftPM `KlineTrainerContracts` package 的 standalone value type，无外部依赖（除 Swift stdlib），无 trust-boundary，仅由 E5 TrainingEngine 在 `@MainActor` 内持有 `private(set) var tick: TickEngine`（modules L1574）。

## Tech Stack

- Swift 6（toolchain 6.3.1）
- Swift Testing macros（`@Test` / `@Suite` / `#expect`）
- SwiftPM intra-package value type
- 不需要 Foundation（纯 Int 运算）

## Spec snapshot（grep-verified）

**modules §E1**（kline_trainer_modules_v1.4.md L1457-1469）—— **frozen baseline，权威**：
```swift
struct TickEngine: Equatable {
    private(set) var globalTickIndex: Int
    let maxTick: Int

    init(maxTick: Int, initialTick: Int = 0) {
        self.maxTick = maxTick
        self.globalTickIndex = max(0, min(initialTick, maxTick))
    }

    mutating func advance(steps: Int = 1) -> Bool
    mutating func reset(to tick: Int)
}
```

**plan §3**（kline_trainer_plan_v1.5.md L555-566）—— body implementation guide：
```swift
mutating func advance(steps: Int = 1) -> Bool {
    guard globalTickIndex < maxTick else { return false }
    globalTickIndex = min(globalTickIndex + steps, maxTick)
    return true
}

mutating func reset(to tick: Int) {
    globalTickIndex = max(0, min(tick, maxTick))
}
```

### Spec discrepancy（reviewer I-3）

modules vs plan declaration 不一致：

| Aspect | modules §E1 | plan §3 |
|---|---|---|
| Equatable conformance | 显式 `: Equatable` | 无（隐式 by struct） |
| `globalTickIndex` 默认值 | 无（构造时 init 给值） | `= 0` |
| 显式 `init` clamping | 显式 `init(maxTick:initialTick:)` 含 clamp | 无（依赖 Swift auto-synth memberwise + `= 0` 默认值，无 clamp） |

**冲突解决**：以 **modules §E1 为准**（per memory `project_modules_v1.4_frozen`，35 模块 4 轮 codex review 冻结 baseline）。impl 加显式 `: Equatable` + 显式 `init` 含 clamp（构造路径全经 init clamp，无默认值）。

## Scope

**Sub-task 1**：impl + tests（Plan Task 2 是只读 verification，不计 sub-task）
- 文件 1：`ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift`（≤30 行 prod）
- 文件 2：`ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift`（≤130 行 含 blank separator，15 tests）

**子项总数 1**（远低于 ≤3 硬上限），**prod 行数 ≤30**（远低于 ≤500 硬上限）。

## 不在范围

- ❌ Codable conformance（spec 不要求；E1 in-memory only，不持久化）
- ❌ Sendable explicit conformance（**reviewer M-1**：Swift 6 value type with all-Sendable stored properties (`Int` × 2) 自动推断 Sendable；E1 不跨 actor，无需手写）
- ❌ Comparable / Hashable / CustomStringConvertible（spec 不要求）
- ❌ Error types / throwing API（spec body 已用 Bool sentinel pattern；defense-in-depth bias 已被 spec 满足）
- ❌ E5 TrainingEngine integration（E1 standalone，integration 是 E5 自身 PR scope）
- ❌ persistence layer（无）
- ❌ E2 PositionManager 重审（独立 backlog track）
- ❌ M0.3 矩阵 bump（**reviewer M-2**：E1 在 §七业务逻辑模块，**不**在 §M0.3 契约值类型 scope）
- ❌ spec / m01 / §M0.x 任何修订
- ❌ negative steps / `init(maxTick: < 0)` invariant 守门 / `Int.+` overflow 防（**3 项 accepted residuals**：spec gap，归 E5 caller side 验证，不在 E1 v1 scope；详见 §"Open Questions / Residuals"）

## Implementation

```swift
// Kline Trainer Swift Contracts — E1 TickEngine
// Spec: kline_trainer_modules_v1.4.md §E1 + kline_trainer_plan_v1.5.md §3

public struct TickEngine: Equatable {
    public private(set) var globalTickIndex: Int
    public let maxTick: Int

    public init(maxTick: Int, initialTick: Int = 0) {
        self.maxTick = maxTick
        self.globalTickIndex = max(0, min(initialTick, maxTick))
    }

    public mutating func advance(steps: Int = 1) -> Bool {
        guard globalTickIndex < maxTick else { return false }
        globalTickIndex = min(globalTickIndex + steps, maxTick)
        return true
    }

    public mutating func reset(to tick: Int) {
        globalTickIndex = max(0, min(tick, maxTick))
    }
}
```

**Notes**：
- `public` 暴露符合 SwiftPM package 跨模块使用约定（与 PR #36 archive 的 PositionManager 一致）。
- 实现一字不差对应 plan §3 L555-566 body + modules §E1 L1457 declaration（resolved per discrepancy section）。

## 测试矩阵（15 tests，含 reviewer I-1 + I-2 + R1 adversarial review characterization tests）

| # | Test | Purpose |
|---|---|---|
| 1 | `init(maxTick: 100, initialTick: 0)` → globalTickIndex = 0 | default init |
| 2 | `init(maxTick: 100, initialTick: -5)` → globalTickIndex = 0 | clamp negative initialTick |
| 3 | `init(maxTick: 100, initialTick: 200)` → globalTickIndex = 100 | clamp initialTick > maxTick |
| 4 | **`init(maxTick: 0, initialTick: 5)` → globalTickIndex = 0** | **reviewer I-2**：edge case maxTick=0 |
| 5 | `advance(steps: 1)` from 50 (maxTick 100) → true, idx = 51 | default advance |
| 6 | `advance(steps: 60)` from 50 (maxTick 100) → true, idx = 100 | multi-step + clamp at maxTick |
| 7 | `advance()` at maxTick → false, no mutation | terminal state |
| 8 | **`advance(steps: 0)` from 50 → true, idx = 50** | **reviewer I-1**：characterize 0-step（spec body 字面行为：guard 通过，min(50+0, max) = 50, return true） |
| 9 | **`advance(steps: -1)` from 50 → true, idx = 49** | **reviewer I-1**：characterize negative-step（spec body 字面行为：guard 通过，min(50-1, max) = 49, return true；residual #1 见 Open Questions） |
| 10 | `reset(to: -5)` → globalTickIndex = 0 | clamp negative reset |
| 11 | `reset(to: 200)` (maxTick 100) → globalTickIndex = 100 | clamp reset > maxTick |
| 12 | `reset(to: 50)` → globalTickIndex = 50 | mid-range reset exact |
| 13 | Equatable: identical state == / different state != / different maxTick != | Equatable conformance（含 R1 M-4：maxTick discriminator） |
| 14 | **`advance(steps: -1000)` from idx=5 → true, idx = -995** | **R1 I-1**：characterize lower-bound invariant break（advance 不 clamp 下界；residual #1 见 Open Questions） |
| 15 | **`advance(steps: 0)` AT maxTick → false, no mutation** | **R1 I-2**：characterize guard branch when steps=0 at terminal state（vs test #8 在 mid-range） |

实际 15 tests（含 R1 round adversarial review characterization #14 #15 + Equatable maxTick discriminator，实测 123 行 / 含 blank separator）。

## Open Questions / Residuals（不在 E1 v1 scope）

1. **Negative `steps` 语义反直觉 + 下界 invariant 破坏**（reviewer I-1 + R1 I-1）：spec body 字面接受 negative steps 实现"回退"，与方法名 `advance` 语义冲突。**关键**：`advance` 只 clamp 上界 `min(.., maxTick)`，**不 clamp 下界**。从 `globalTickIndex > 0` 大幅 negative steps 会让 `globalTickIndex` 变负数（test #14 characterize: `-1000` from idx=5 → idx=-995），破坏 init/reset 维护的 `globalTickIndex >= 0` invariant。**归 E5 integration 责任**：caller-side `precondition(steps >= 0)` 或 deliberate negative use；E5 下游消费方（如 BinarySearch L526）须自防 `globalTickIndex < 0`。E1 不引入 precondition，保 spec 字面 fidelity。

2. **`init(maxTick: < 0)` invariant gap**（reviewer I-2）：spec 没给 maxTick 下界 contract。`maxTick = -1` 时 `globalTickIndex = 0 > maxTick = -1`，invariant `globalTickIndex <= maxTick` 破坏。**归 E5 caller side**：构造 TickEngine 前 caller 自验 `maxTick >= 0`。E1 不加 precondition / fatalError（避免触发 codex defense-in-depth bias 进而 spec drift）。

3. **`advance(steps: Int.max)` checked arithmetic overflow trap**（R1 C-1）：Swift 6 `Int.+` 是 checked arithmetic。`globalTickIndex + steps` 溢出时 trap（SIGTRAP / exit 133），先于 `min(.., maxTick)` clamp 触发。从任何 `globalTickIndex > 0`，`steps = Int.max` 会让进程崩。**归 E5 caller side**：caller 须保证 `steps <= Int.max - globalTickIndex`（实践中 advance 单步 1 / 几十，绝不可能 Int.max）。E1 不加 `addingReportingOverflow` 或 saturating 算术（spec body 字面写 `min(globalTickIndex + steps, maxTick)`，加防御 = spec drift）。**Codex 风险**：可能 R1 push "为啥不防 overflow"。反驳素材：spec 原文 + `feedback_governance_budget_cap` + 业务上 advance 步长有自然上限（K 线 tick 数 ≤百万级）。

三项作 **accepted residuals**，design doc 已 codify + 各自 characterization tests（test #9 / N/A / N/A），不写进 impl。

## Codex review 策略

- **预期 round 数**：1-2 轮（无 trust-boundary surface 可 push）
- **关键预防**：
  - tests #8 #9（characterization tests）把 spec body implicit 行为变 explicit verifiable contract → 抢先回答 codex 可能的 R1 push "为啥 advance() 接受负数"
  - design doc Open Questions section codify residuals → R2 push "init invariant" 可引用
  - impl 一字不差对应 spec → 不给 codex "spec drift" 攻击面
- **超 3 轮立即 abort**（per memory `feedback_big_pr_codex_noncovergence` ≤3 轮硬规则）
- **若 codex push throws / Result API 风格**：spec 原文 `-> Bool` 是硬证据，1 轮 inline 反驳 + accept residual

## Rollout

```
T0  worktree 设置：git worktree add .worktrees/e1-tickengine -b e1-tickengine main
T1  impl + tests（subagent-driven-development，1 task）
T2  verification-before-completion（swift test all pass / 0 warnings）
T3  requesting-code-review（superpowers code-reviewer subagent）
T4  user explicit confirm → push branch + open PR
T5  codex adversarial review（≤3 轮 / 超 3 abort）
T6  CODEOWNERS approve（单人项目 = user self-approve）
T7  merge
```

## 8 行非 coder 验收清单（CLAUDE.md backstop §2）

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | `cd .worktrees/e1-tickengine && swift test` | 退出码 0；64 tests 全过（49 baseline + 15 E1）；0 warnings | ☐ |
| 2 | `wc -l ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift` | ≤30 行 prod | ☐ |
| 3 | `wc -l ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift` | ≤130 行（15 tests 含 blank separator） | ☐ |
| 4 | `git diff main --stat` | 4 文件（TickEngine.swift + TickEngineTests.swift + design doc + plan doc） | ☐ |
| 5 | grep `import Foundation\|import Combine\|import GRDB` TickEngine.swift | 0 命中（纯 Int 运算，无外部 import） | ☐ |
| 6 | grep `precondition\|fatalError\|throws` TickEngine.swift | 0 命中（spec 字面 fidelity，无新增防御） | ☐ |
| 7 | PR description 含 cross-ref 引用本 design doc + spec discrepancy 解决记录 + 3 项 residuals | 显式 list | ☐ |
| 8 | PR `codex-verify-pass` GitHub status check | **绿灯** | ☐ |

第 8 行红/黄灯 → 不得 merge（CLAUDE.md backstop §1）。**超 3 轮 codex needs-attn → abort PR + close + 重新评估**（per memory hard rule）。

## Memory compliance check

- ✅ `feedback_big_pr_codex_noncovergence`：≤30 行 prod / 15 tests / 预计 ≤3 codex 轮
- ✅ `feedback_planner_packaging_bias`：1 sub-task ≤ 3 硬上限
- ✅ `feedback_brainstorming_grep_first`：spec 章节归属 grep-verified（modules L1457 + plan L555-566）
- ✅ `feedback_module_level_abort_signal`：E1 anchor 选择基于 E2 三连 abort 教训
- ✅ `feedback_governance_budget_cap`：不主动加防御（precondition / throws）；spec gap 归 caller-side
- ✅ `project_modules_v1.4_frozen`：modules §E1 declaration 优先，不修 spec
- ✅ `feedback_pr_language_chinese`：本 design doc + 后续 PR description 全中文
- ✅ `feedback_reviewer_verdict_not_authorization`：T4 push / merge 前 user explicit confirm

## Brainstorming convergence trail

- **Q1（reframed）**：scope 决策 = pure impl + tests，不动 spec / m01 / §M0.x
- **Adversarial review**（Opus 4.7 xhigh）Round 1：0 Critical，3 Important（characterization tests / spec gap residuals / spec discrepancy）+ 3 Minor（Sendable / M0.3 bump / worktree timing）→ 直接收敛 accept
- **6 条增量修正**：全部 design doc 级，不改 scope；2 条 characterization tests + 4 条 design doc 注释

## Cross-references

- **本 design doc**：`docs/superpowers/specs/2026-04-29-e1-tickengine-design.md`
- **spec 源**：`kline_trainer_modules_v1.4.md` L1457-1469 + `kline_trainer_plan_v1.5.md` L555-566
- **E5 上游持有点**：`kline_trainer_modules_v1.4.md` L1574 (`private(set) var tick: TickEngine`)
- **E2 deferred archive**（不复用，仅参考论证素材）：
  - `pr1-e2-position-manager` branch (sha 631f8cf)
  - `spec-redesign-pr1-e2` branch (b1f2045，v1 design doc aborted)
  - memory `project_pr36_aborted.md`
- **CLAUDE.md backstop**：§1 codex-verify-pass / §2 非 coder 验收清单 / §4 skill gate
- **Memory references**：`feedback_module_level_abort_signal` / `feedback_brainstorming_grep_first` / `feedback_planner_packaging_bias` / `feedback_big_pr_codex_noncovergence` / `feedback_governance_budget_cap`
