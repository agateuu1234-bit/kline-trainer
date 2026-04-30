# E1 TickEngine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Project memory `project_executing_plans_excluded` 明确：本项目只用 subagent-driven-development，不用 executing-plans。

**Goal:** 落地 modules §E1 + plan §3 的 `TickEngine` 值类型 —— 单用户训练期"全局唯一时间状态"，纯 clamping arithmetic + Bool sentinel pattern + in-memory only。

**Architecture:** 单文件值类型 `public struct TickEngine: Equatable`，`globalTickIndex: Int (private(set))` + `maxTick: Int (let)`，3 个方法（init / advance / reset），impl 一字不差对应 modules §E1 declaration + plan §3 body。无 trust-boundary / 无 persistence / 无错误类型 / 无外部依赖（除 Swift stdlib）。

**Tech Stack:** Swift 6 (toolchain 6.3.1) + SwiftPM intra-package + Swift Testing macros (`@Test` / `@Suite` / `#expect`)。

**Design Doc:** `docs/superpowers/specs/2026-04-29-e1-tickengine-design.md` (sha 2339481)

---

## File Structure

| File | Responsibility | LOC budget |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift` | TickEngine 值类型 impl（init + advance + reset + Equatable） | ≤30 行 prod |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift` | 13 tests（init 4 + advance 5 含 characterization + reset 3 + Equatable 1） | ≤80 行 |

**Working directory**：`/Users/maziming/Coding/Prj_Kline trainer/.worktrees/e1-tickengine/ios/Contracts/`（SwiftPM root）

**Baseline**：`swift test` 当前 49 tests pass / 0 warnings；E1 PR 完成后预期 62 tests pass。

---

## Task 1: TickEngine impl + 13 tests (TDD red-green per method batch)

**Strategy**: 4 个 method batch（init / advance / reset / Equatable），每个 batch 走完 RED → GREEN → commit 后进下一个。最终单文件 ≤30 行 prod + ≤80 行 tests，4 commits。

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift`

### Batch A: init + 4 tests (#1-#4)

- [ ] **Step A.1: Create test file scaffold + 4 init tests**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift`:

```swift
import Testing
@testable import KlineTrainerContracts

@Suite("TickEngine")
struct TickEngineTests {

    @Test("init default initialTick = 0")
    func initDefault() {
        let t = TickEngine(maxTick: 100)
        #expect(t.globalTickIndex == 0)
        #expect(t.maxTick == 100)
    }

    @Test("init clamps negative initialTick to 0")
    func initClampNegative() {
        let t = TickEngine(maxTick: 100, initialTick: -5)
        #expect(t.globalTickIndex == 0)
    }

    @Test("init clamps initialTick > maxTick to maxTick")
    func initClampOverMax() {
        let t = TickEngine(maxTick: 100, initialTick: 200)
        #expect(t.globalTickIndex == 100)
    }

    @Test("init with maxTick=0 clamps initialTick to 0")
    func initZeroMaxTick() {
        let t = TickEngine(maxTick: 0, initialTick: 5)
        #expect(t.globalTickIndex == 0)
        #expect(t.maxTick == 0)
    }
}
```

- [ ] **Step A.2: Run tests to verify RED (TickEngine not defined)**

Run: `cd ios/Contracts && swift test --filter TickEngineTests`
Expected: 编译失败，`error: cannot find 'TickEngine' in scope`

- [ ] **Step A.3: Create TickEngine.swift with struct + init only**

Create `ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift`:

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
}
```

- [ ] **Step A.4: Run tests to verify GREEN (4 init tests pass)**

Run: `cd ios/Contracts && swift test --filter TickEngineTests`
Expected: `Test run with 4 tests in 1 suites passed`

- [ ] **Step A.5: Commit Batch A**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/e1-tickengine
git add ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift
git commit -m "feat(E1): TickEngine init + 4 init tests (Batch A, TDD green)"
```

### Batch B: advance + 5 tests (#5-#9 含 characterization)

- [ ] **Step B.1: Append 5 advance tests to test file**

Append to `TickEngineTests.swift`（在 `initZeroMaxTick()` 之后，闭合 `}` 之前）:

```swift

    @Test("advance default steps=1 increments by 1")
    func advanceDefault() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        let result = t.advance()
        #expect(result == true)
        #expect(t.globalTickIndex == 51)
    }

    @Test("advance multi-step clamps at maxTick")
    func advanceMultiStep() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        let result = t.advance(steps: 60)
        #expect(result == true)
        #expect(t.globalTickIndex == 100)
    }

    @Test("advance at maxTick returns false, no mutation")
    func advanceAtMaxTick() {
        var t = TickEngine(maxTick: 100, initialTick: 100)
        let result = t.advance()
        #expect(result == false)
        #expect(t.globalTickIndex == 100)
    }

    @Test("advance steps=0 returns true, no mutation (spec body 字面行为)")
    func advanceZeroSteps() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        let result = t.advance(steps: 0)
        #expect(result == true)
        #expect(t.globalTickIndex == 50)
    }

    @Test("advance steps=-1 returns true, decrements (spec body 字面行为; residual 见 design doc)")
    func advanceNegativeStep() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        let result = t.advance(steps: -1)
        #expect(result == true)
        #expect(t.globalTickIndex == 49)
    }
```

- [ ] **Step B.2: Run tests to verify RED (advance not defined)**

Run: `cd ios/Contracts && swift test --filter TickEngineTests`
Expected: 编译失败，`error: value of type 'TickEngine' has no member 'advance'`

- [ ] **Step B.3: Add advance method to TickEngine.swift**

在 `TickEngine.swift` `init(...)` 之后插入：

```swift

    public mutating func advance(steps: Int = 1) -> Bool {
        guard globalTickIndex < maxTick else { return false }
        globalTickIndex = min(globalTickIndex + steps, maxTick)
        return true
    }
```

- [ ] **Step B.4: Run tests to verify GREEN (9 tests pass)**

Run: `cd ios/Contracts && swift test --filter TickEngineTests`
Expected: `Test run with 9 tests in 1 suites passed`

- [ ] **Step B.5: Commit Batch B**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift
git commit -m "feat(E1): TickEngine advance + 5 tests 含 characterization #8 #9 (Batch B, TDD green)"
```

### Batch C: reset + 3 tests (#10-#12)

- [ ] **Step C.1: Append 3 reset tests to test file**

Append to `TickEngineTests.swift`（在 `advanceNegativeStep()` 之后）:

```swift

    @Test("reset to negative clamps to 0")
    func resetNegative() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        t.reset(to: -5)
        #expect(t.globalTickIndex == 0)
    }

    @Test("reset to > maxTick clamps to maxTick")
    func resetOverMax() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        t.reset(to: 200)
        #expect(t.globalTickIndex == 100)
    }

    @Test("reset to mid-range exact")
    func resetMidRange() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        t.reset(to: 75)
        #expect(t.globalTickIndex == 75)
    }
```

- [ ] **Step C.2: Run tests to verify RED (reset not defined)**

Run: `cd ios/Contracts && swift test --filter TickEngineTests`
Expected: 编译失败，`error: value of type 'TickEngine' has no member 'reset'`

- [ ] **Step C.3: Add reset method to TickEngine.swift**

在 `TickEngine.swift` `advance(...)` 之后插入：

```swift

    public mutating func reset(to tick: Int) {
        globalTickIndex = max(0, min(tick, maxTick))
    }
```

- [ ] **Step C.4: Run tests to verify GREEN (12 tests pass)**

Run: `cd ios/Contracts && swift test --filter TickEngineTests`
Expected: `Test run with 12 tests in 1 suites passed`

- [ ] **Step C.5: Commit Batch C**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift
git commit -m "feat(E1): TickEngine reset + 3 reset tests (Batch C, TDD green)"
```

### Batch D: Equatable test (#13) — GREEN-only verification batch

注：本 batch 无 RED step。Equatable conformance 在 Batch A 的 `public struct TickEngine: Equatable` 已显式声明，由 Swift 编译器 auto-synthesize（struct + 所有 stored property 都 Equatable）。测试直接 GREEN 是 expected behavior；plan 顶部"red-green per method batch"模式在此 batch 退化为 GREEN-only verification（characterization test for auto-synth conformance）。

- [ ] **Step D.1: Append Equatable test to test file**

Append to `TickEngineTests.swift`（在 `resetMidRange()` 之后）:

```swift

    @Test("Equatable: identical state ==, different state !=")
    func equatable() {
        let a = TickEngine(maxTick: 100, initialTick: 50)
        let b = TickEngine(maxTick: 100, initialTick: 50)
        #expect(a == b)

        var c = TickEngine(maxTick: 100, initialTick: 50)
        _ = c.advance(steps: 5)
        #expect(a != c)
    }
```

- [ ] **Step D.2: Run tests to verify GREEN (13 tests pass; Equatable auto-derived from `: Equatable` conformance)**

Run: `cd ios/Contracts && swift test --filter TickEngineTests`
Expected: `Test run with 13 tests in 1 suites passed`

注：Equatable 由 Swift 编译器自动 synthesize（struct + 所有 stored property 都 Equatable）。无 impl 改动。

- [ ] **Step D.3: Commit Batch D**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift
git commit -m "feat(E1): TickEngine Equatable test (Batch D, TDD green; auto-synth)"
```

---

## Task 2: 验证 + 8 行非 coder 验收清单

**Files:**
- Read-only verification（无文件改动）

- [ ] **Step 2.1: 跑整个 SwiftPM package 全测试，确认 baseline 49 + new 13 = 62 全过 + 0 warnings + 0 errors**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected:
```
✔ Suite "TickEngine" passed after ... seconds.
...
Test run with 62 tests in 14 suites passed after ... seconds.
```

- [ ] **Step 2.2: 验收清单第 1 行 —— SwiftPM 测试退出码**

Run: `cd ios/Contracts && swift test ; echo "exit: $?"`
Expected: 最后一行 `exit: 0`

- [ ] **Step 2.3: 验收清单第 2 行 —— TickEngine.swift 行数 ≤30**

Run: `wc -l ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift`
Expected: 输出 `<= 30 ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift`（行数 ≤30）

- [ ] **Step 2.4: 验收清单第 3 行 —— TickEngineTests.swift 行数 ≤80**

Run: `wc -l ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift`
Expected: 输出行数 ≤80

- [ ] **Step 2.5: 验收清单第 4 行 —— git diff main --stat 文件数（plan commit 在 Step 2.10 之后单独入账）**

**第一次 check（Step 2.5 当前时刻，plan 尚未 commit）**：
Run: `git diff main --stat`
Expected: 命中 **3 文件**：
- `ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift` (new, Batch A-C)
- `ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift` (new, Batch A-D)
- `docs/superpowers/specs/2026-04-29-e1-tickengine-design.md` (design doc commit 2339481)

**第二次 check（Step 2.10 commit plan 后）**：再跑一次 `git diff main --stat`，预期 4 文件命中（多 plan 一份）。这步在 Step 2.10 之后 inline 跑，不再单独列。

- [ ] **Step 2.6: 验收清单第 5 行 —— TickEngine.swift 无外部 import**

Run: `grep -E 'import Foundation|import Combine|import GRDB' ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift ; echo "exit: $?"`
Expected: 0 命中，`exit: 1`（grep 没匹配 = 退出码 1 = 通过）

- [ ] **Step 2.7: 验收清单第 6 行 —— TickEngine.swift 无 defense-in-depth bias 触发器**

Run: `grep -E 'precondition|fatalError|throws' ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift ; echo "exit: $?"`
Expected: 0 命中，`exit: 1`（即 spec 字面 fidelity，无新增防御）

- [ ] **Step 2.8: 验收清单第 7 行 —— PR description 模板预备（待 user explicit confirm 后 push）**

PR description 草稿（pending push）应含：
- 引用本 plan + design doc cross-ref
- spec discrepancy 解决记录（modules §E1 优先 over plan §3）
- 2 项 accepted residuals（negative steps + maxTick<0）
- codex review ≤3 轮硬规则声明（超 3 立即 abort）

实际 PR open 时 user explicit confirm 后由 push 步骤生成。本 plan 不实际 push。

- [ ] **Step 2.9: 验收清单第 8 行 —— `codex-verify-pass` GitHub status check**

实际 PR open + codex-attest 跑过后才能验证。本 plan 不到 push 阶段。
**红/黄灯 → 不得 merge**（CLAUDE.md backstop §1）。
**超 3 轮 codex needs-attn → abort PR + close + 重新评估**（per memory `feedback_big_pr_codex_noncovergence`）。

- [ ] **Step 2.10: Commit plan 文件本身**

```bash
git add docs/superpowers/plans/2026-04-30-e1-tickengine.md
git commit -m "docs(plan): E1 TickEngine implementation plan (subagent-driven-development friendly)"
```

---

## Acceptance summary

完成后状态：
- 5 commits on branch `e1-tickengine`：
  1. design doc commit (sha 2339481, 已 commit on Apr 29)
  2. Batch A (init + 4 tests)
  3. Batch B (advance + 5 tests)
  4. Batch C (reset + 3 tests)
  5. Batch D (Equatable test, no impl change)
  6. plan commit
- `ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift` ≤30 行 prod
- `ios/Contracts/Tests/KlineTrainerContractsTests/TickEngineTests.swift` ≤80 行 13 tests
- 整 package 62 tests pass / 0 warnings / 0 errors
- 0 grep 命中外部 import / precondition / fatalError / throws

**未 push**：等 user explicit confirm（per memory `feedback_reviewer_verdict_not_authorization`）。

---

## Memory compliance check

- ✅ `feedback_big_pr_codex_noncovergence`：≤30 行 prod / 13 tests / 预计 ≤3 codex 轮（超 3 abort）
- ✅ `feedback_planner_packaging_bias`：1 sub-task ≤ ≤3 硬上限（4 commits 是 TDD batch 不是 sub-task）
- ✅ `feedback_brainstorming_grep_first`：spec 章节归属 grep-verified（modules L1457 + plan L555-566）
- ✅ `feedback_module_level_abort_signal`：E1 anchor 选择基于 E2 三连 abort 教训
- ✅ `feedback_governance_budget_cap`：不主动加防御；spec gap 归 caller-side
- ✅ `project_modules_v1.4_frozen`：modules §E1 declaration 优先，不修 spec
- ✅ `project_executing_plans_excluded`：plan 走 subagent-driven-development（顶部 header 已声明）
- ✅ `feedback_pr_language_chinese`：plan + 后续 PR description 全中文
- ✅ `feedback_reviewer_verdict_not_authorization`：T2.8 / T2.9 显式标 push 前需 user confirm
- ✅ `feedback_xcode_cli_first`：全 swift test 命令行，不 Xcode GUI
- ✅ `feedback_subagent_model_selection`：subagent-driven-development 用 sonnet 4.6 high effort（writing-plans 默认）

---

## Cross-references

- **本 plan**：`docs/superpowers/plans/2026-04-30-e1-tickengine.md`
- **Design doc**：`docs/superpowers/specs/2026-04-29-e1-tickengine-design.md`（sha 2339481）
- **spec 源**：`kline_trainer_modules_v1.4.md` L1457-1469 + `kline_trainer_plan_v1.5.md` L555-566
- **E5 上游持有点**：`kline_trainer_modules_v1.4.md` L1574
- **CLAUDE.md backstop**：§1 codex-verify-pass / §2 非 coder 验收清单 / §4 skill gate
- **Memory references**：见 Memory compliance check section
