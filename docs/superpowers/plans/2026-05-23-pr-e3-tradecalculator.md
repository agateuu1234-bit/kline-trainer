# E3 TradeCalculator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the E3 `TradeCalculator` pure-function module — `quoteBuy` / `quoteSell` returning `Result<Quote, TradeReason>` plus a non-failing `forceCloseOnEnd` — matching the frozen spec signatures and the v1.5 §4.2 trade-calculation rules.

**Architecture:** A caseless `enum TradeCalculator` namespace (mirroring E1 `TickEngine`'s pure-value style) holding two `Equatable` quote structs, three documented constants, the three public static functions, and private helpers (`robustFloor`, `computeCommission`, `makeSellQuote`, `ratio`). No state, no I/O, no `AppError` translation — the caller (E5) lifts `TradeReason → AppError` via `.mapError`. Lives in target `KlineTrainerContracts`.

**Tech Stack:** Swift 6.0, SwiftPM (`ios/Contracts/Package.swift`), swift-testing (`@Test`/`@Suite`/`#expect`). Test command: `cd ios/Contracts && swift test`.

---

## Task 0 — §15.3 评审策略前置 (per `docs/governance/wave1-plan-template.md`)

- [ ] **局部对抗性评审**（必）：本 plan 子模块 scope 内对抗性 review；**本 PR 用户指定用 Claude opus 4.7 xhigh effort 做对抗性评审**（非 codex；session 开头契约，per memory `feedback_review_tool_switch_must_ask`），plan-stage + branch-diff 各一轮收敛。
- [ ] **集成层评审**：N/A（E3 是叶子纯函数模块，无 C8 桥接 / E5 编排）。
- [ ] **性能评审**：N/A（非 Phase 5 磨光 PR）。

### 设计决策与 spec 来源映射（reviewer 速查）

| 主题 | 来源 | 决策 |
|---|---|---|
| 函数签名 + 3 常量 | `kline_trainer_modules_v1.4.md` §E3 (L1493-1516) | 逐字匹配冻结签名 |
| 买入算法 | `kline_trainer_plan_v1.5.md` §4.2 (L602-611) | 目标金额=总资金×仓位比例；floor 至 100 股整数倍；股数=0→`.insufficientCash` |
| 卖出算法 | `kline_trainer_plan_v1.5.md` §4.2 (L613-624) | 仓位相对**当前持仓**；5/5 清仓不取整（允许零股）；非清仓股数=0→`.insufficientHolding` |
| 免5 / 印花税 | `kline_trainer_plan_v1.5.md` §4.2 (L597-599, L609, L621-622) | `minCommissionEnabled` 开且佣金<5→佣金=5；印花税 `notional×0.0005` 始终计算（仅卖出） |
| `PositionTier.ratio` | `Models.swift:25` 无 ratio 属性 | E3 文件内私有 `ratio(of:)`，不改冻结 `Models.swift`（surgical） |
| **`TradeReason` 4 case 归属** | `AppError.swift:36` + spec 无逐 case 触发表 → **本 plan 决定** | 见下表 |
| **浮点 floor 掉股** | memory `feedback_codex_fractional_subpixel_bias` (C1a verify-and-correct) | `robustFloor` 1e-6 容差根治；buy 路径**载荷**（价格非二进制精确如 0.07 时真会掉股），sell 路径**防御性对称**（整数 holding × 5 档比例不会 FP 下溢）；demonstrator 测试用经验证 undershoot 输入 |
| 金额取整 | spec 公式无 round-to-cent | 不四舍五入到分，保留 raw `Double`（逐字匹配 spec）；测试用容差比较 |
| M0.4 AppError gate | `docs/governance/m04-apperror-translation-gate.md` **L62** | **豁免**：E3 返 `Result` 不 throws，无 AppError 消费表面 |
| `averageCost` 参数 | spec 签名含但 `SellQuote` 无成本/盈亏字段 | 保留以匹配冻结签名；E3 不使用（已实现盈亏由 E5 按 `averageCost` 自算）；代码注释说明 |

### `TradeReason` 4 case 触发归属（本 plan 决定）

| case | quoteBuy | quoteSell | forceCloseOnEnd |
|---|---|---|---|
| `.invalidShareCount` | `price<=0` / 负 totalCapital / 负 cash / 非有限值 | `price<=0` / `holding<0` / 非有限值 | 无错误通道（holding<=0 或 price<=0 → 全零报价） |
| `.insufficientCash` | floor 后股数=0 **或** 总成本>cash | — | — |
| `.insufficientHolding` | — | 非清仓且 floor 后股数=0 | — |
| `.disabled` | — | `holding==0`（空仓点卖出，镜像 UI 灰置） | — |

**Rationale**：`.disabled` 对应 spec §4.2"空仓点卖出按钮灰置（disabled）"——纯函数防御性返回，镜像 UI 状态。`.invalidShareCount` 收口非法/非有限输入（保证 floor / 除法有意义）。买入"满仓灰置"无法在 `quoteBuy` 输入（无当前持仓参数）侦测，归 UI/E5；故 `quoteBuy` 不返 `.disabled`。

完成 Task 0 才进 Task 1 实施。

---

## Task 1: 模块骨架 + `quoteBuy`

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift`

- [ ] **Step 1: Write the failing tests (quoteBuy)**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift`:

```swift
import Testing
@testable import KlineTrainerContracts

// 公用容差断言：Double 字段比较用容差（佣金/印花税含 FP 误差，禁裸 ==）
private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool {
    abs(a - b) < tol
}

private let noMin = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false)
private let withMin = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)

@Suite("TradeCalculator.quoteBuy")
struct TradeCalculatorBuyTests {

    @Test("happy: 整手买入，佣金按实际")
    func happy() {
        let r = TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: 10, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(q.shares == 2000)                       // floor(100000*0.2/10)=2000
        #expect(approx(q.notional, 20_000))
        #expect(approx(q.commission, 2.0))              // 20000*0.0001
        #expect(approx(q.totalCost, 20_002))
    }

    @Test("lot rounding: 非整百原始股数 floor 至 100 倍")
    func lotRounding() {
        let r = TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: 33, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 600)                        // floor(20000/33)=606 -> floor(606/100)*100=600
        #expect(approx(q.notional, 19_800))
        #expect(approx(q.commission, 1.98))
        #expect(approx(q.totalCost, 19_801.98))
    }

    @Test("FP 根治: 价格非二进制精确(0.07)时 robustFloor 防掉股")
    func fpRobustFloor() {
        // 1001/0.07 真值=14300，但 IEEE-754 下 = 14299.999999999998；
        // 朴素 Int(floor) 得 14299 -> lot 14200；robustFloor 进位回 14300 -> lot 14300。
        // 此输入经 toolchain 验证会 undershoot——该测试在 robustFloor 换成朴素 floor 时
        // 必须 FAIL（否则未真正覆盖机制）。实施时 red->green 后，若怀疑未触发，把
        // robustFloor 临时换朴素 floor 跑一次确认本测试转 FAIL。
        let r = TradeCalculator.quoteBuy(totalCapital: 1_001, cash: 1_000_000,
                                         tier: .tier5, price: 0.07, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 14_300)
        #expect(approx(q.notional, 1_001.0))
    }

    @Test("insufficientCash: floor 后股数=0")
    func roundsToZero() {
        let r = TradeCalculator.quoteBuy(totalCapital: 1_000, cash: 1_000,
                                         tier: .tier1, price: 10, fees: noMin)
        #expect(r == .failure(.insufficientCash))       // floor(200/10)=20 -> lot 0
    }

    @Test("insufficientCash: 总成本 > 可用现金")
    func costExceedsCash() {
        let r = TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 50_000,
                                         tier: .tier5, price: 10, fees: noMin)
        #expect(r == .failure(.insufficientCash))       // shares 10000 totalCost 100010 > 50000
    }

    @Test("min commission: 免5开启且佣金<5 计 5")
    func minCommission() {
        let r = TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: 10, fees: withMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(approx(q.commission, 5.0))              // raw 2.0 < 5 -> 5
        #expect(approx(q.totalCost, 20_005))
    }

    @Test("invalidShareCount: price<=0")
    func invalidPrice() {
        #expect(TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: 0, fees: noMin) == .failure(.invalidShareCount))
        #expect(TradeCalculator.quoteBuy(totalCapital: 100_000, cash: 100_000,
                                         tier: .tier1, price: -5, fees: noMin) == .failure(.invalidShareCount))
    }

    @Test("invalidShareCount: 负输入")
    func invalidNegative() {
        #expect(TradeCalculator.quoteBuy(totalCapital: -1, cash: 100_000,
                                         tier: .tier1, price: 10, fees: noMin) == .failure(.invalidShareCount))
        #expect(TradeCalculator.quoteBuy(totalCapital: 100_000, cash: -1,
                                         tier: .tier1, price: 10, fees: noMin) == .failure(.invalidShareCount))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/Contracts && swift test --filter TradeCalculatorBuyTests`
Expected: FAIL — `cannot find 'TradeCalculator' in scope` (file not yet created).

- [ ] **Step 3: Create the source file with skeleton + quoteBuy**

Create `ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift`:

```swift
// Kline Trainer Swift Contracts — E3 TradeCalculator
// Spec: kline_trainer_modules_v1.4.md §E3 (签名 + 常量)
//     + kline_trainer_plan_v1.5.md §4.2 (买卖计算规则)
// M0.4: 豁免 — 返 Result<_, TradeReason>，从不 throws AppError
//       (docs/governance/m04-apperror-translation-gate.md L62)

public enum TradeCalculator {

    public struct BuyQuote: Equatable {
        public let shares: Int
        public let notional, commission, totalCost: Double
        public init(shares: Int, notional: Double, commission: Double, totalCost: Double) {
            self.shares = shares
            self.notional = notional
            self.commission = commission
            self.totalCost = totalCost
        }
    }

    public struct SellQuote: Equatable {
        public let shares: Int
        public let notional, commission, stampDuty, proceeds: Double
        public init(shares: Int, notional: Double, commission: Double,
                    stampDuty: Double, proceeds: Double) {
            self.shares = shares
            self.notional = notional
            self.commission = commission
            self.stampDuty = stampDuty
            self.proceeds = proceeds
        }
    }

    public static let stampDutyRate: Double = 0.0005   // 卖出印花税 0.05%，始终生效
    public static let minCommissionAmount: Double = 5  // 免5关闭时的最低佣金
    public static let shareLotSize: Int = 100          // A股一手 = 100 股

    // MARK: - Buy

    public static func quoteBuy(totalCapital: Double, cash: Double,
                                tier: PositionTier, price: Double,
                                fees: FeeSnapshot) -> Result<BuyQuote, TradeReason> {
        guard price > 0, totalCapital >= 0, cash >= 0,
              price.isFinite, totalCapital.isFinite, cash.isFinite else {
            return .failure(.invalidShareCount)
        }
        let targetAmount = totalCapital * ratio(of: tier)
        let rawShares = robustFloor(targetAmount / price)
        let lotShares = (rawShares / shareLotSize) * shareLotSize
        guard lotShares > 0 else { return .failure(.insufficientCash) }

        let notional = Double(lotShares) * price
        let commission = computeCommission(notional: notional, fees: fees)
        let totalCost = notional + commission
        guard totalCost <= cash else { return .failure(.insufficientCash) }

        return .success(BuyQuote(shares: lotShares, notional: notional,
                                 commission: commission, totalCost: totalCost))
    }

    // MARK: - Private helpers

    /// floor() 对二进制浮点表示误差做 verify-and-correct（C1a 模式）。
    /// 适用前提：price 为 0.01 整数倍、capital/holding 近整数——此类操作数的乘除积真值
    /// 要么是精确整数、要么离整数远超 FP 噪声底（≤ ~1e-8），故 1e-6 容差能干净区分
    /// "整数的 FP 下溢"(应进位) vs"真实小数结果"(应截断)。signature 不强制该前提，故对
    /// 任意 Double 并非无条件正确的 floor（只在本模块的输入域内成立）。
    private static func robustFloor(_ value: Double) -> Int {
        let f = value.rounded(.down)
        return ((f + 1) - value <= 1e-6) ? Int(f) + 1 : Int(f)
    }

    private static func computeCommission(notional: Double, fees: FeeSnapshot) -> Double {
        let raw = notional * fees.commissionRate
        if fees.minCommissionEnabled && raw < minCommissionAmount {
            return minCommissionAmount
        }
        return raw
    }

    private static func ratio(of tier: PositionTier) -> Double {
        switch tier {
        case .tier1: return 0.2
        case .tier2: return 0.4
        case .tier3: return 0.6
        case .tier4: return 0.8
        case .tier5: return 1.0
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/Contracts && swift test --filter TradeCalculatorBuyTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift
git commit -m "feat(E3): TradeCalculator.quoteBuy + 模块骨架"
```

---

## Task 2: `quoteSell`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift`

- [ ] **Step 1: Write the failing tests (quoteSell)**

Append to `TradeCalculatorTests.swift`:

```swift
@Suite("TradeCalculator.quoteSell")
struct TradeCalculatorSellTests {

    @Test("happy: 整手卖出，佣金+印花税")
    func happy() {
        let r = TradeCalculator.quoteSell(holding: 1000, averageCost: 15,
                                          tier: .tier2, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(q.shares == 400)                        // floor(1000*0.4/100)*100=400
        #expect(approx(q.notional, 8_000))
        #expect(approx(q.commission, 0.8))              // 8000*0.0001
        #expect(approx(q.stampDuty, 4.0))               // 8000*0.0005
        #expect(approx(q.proceeds, 7_995.2))            // 8000-0.8-4.0
    }

    @Test("清仓 5/5: 不取整，允许零股（奇数持仓全卖）")
    func clearOddLot() {
        let r = TradeCalculator.quoteSell(holding: 1050, averageCost: 15,
                                          tier: .tier5, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 1050)                       // 清仓全卖不取整
        #expect(approx(q.notional, 21_000))
    }

    @Test("清仓 5/5: 持仓 < 100 也全卖")
    func clearSubLot() {
        let r = TradeCalculator.quoteSell(holding: 50, averageCost: 15,
                                          tier: .tier5, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 50)
    }

    @Test("tier3 整手卖出: 500*0.6=300 -> lot 300")
    func tier3LotRounding() {
        // 整手卖出正确性测试（非 FP demo：整数 holding × 0.6 不会 FP 下溢，
        // sell 路径 robustFloor 仅为与 buy 对称的防御层）。
        let r = TradeCalculator.quoteSell(holding: 500, averageCost: 15,
                                          tier: .tier3, price: 10, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(q.shares == 300)
        #expect(approx(q.notional, 3_000))
    }

    @Test("insufficientHolding: 非清仓且 floor 后股数=0")
    func roundsToZero() {
        let r = TradeCalculator.quoteSell(holding: 250, averageCost: 15,
                                          tier: .tier1, price: 20, fees: noMin)
        #expect(r == .failure(.insufficientHolding))    // floor(250*0.2)=50 -> lot 0，tier1 非清仓
    }

    @Test("disabled: 空仓点卖出")
    func emptyHolding() {
        #expect(TradeCalculator.quoteSell(holding: 0, averageCost: 0,
                                          tier: .tier1, price: 20, fees: noMin) == .failure(.disabled))
        // 空仓即使点 5/5 清仓也是 disabled（无仓可清）
        #expect(TradeCalculator.quoteSell(holding: 0, averageCost: 0,
                                          tier: .tier5, price: 20, fees: noMin) == .failure(.disabled))
    }

    @Test("invalidShareCount: price<=0 / holding<0")
    func invalid() {
        #expect(TradeCalculator.quoteSell(holding: 1000, averageCost: 15,
                                          tier: .tier1, price: 0, fees: noMin) == .failure(.invalidShareCount))
        #expect(TradeCalculator.quoteSell(holding: -1, averageCost: 15,
                                          tier: .tier1, price: 20, fees: noMin) == .failure(.invalidShareCount))
    }

    @Test("min commission: 卖出免5开启且佣金<5 计 5")
    func minCommission() {
        let r = TradeCalculator.quoteSell(holding: 1000, averageCost: 15,
                                          tier: .tier2, price: 20, fees: withMin)
        guard case .success(let q) = r else { Issue.record("expected success"); return }
        #expect(approx(q.commission, 5.0))              // raw 0.8 < 5 -> 5
        #expect(approx(q.proceeds, 7_991.0))            // 8000-5-4
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/Contracts && swift test --filter TradeCalculatorSellTests`
Expected: FAIL — `type 'TradeCalculator' has no member 'quoteSell'`.

- [ ] **Step 3: Add quoteSell + makeSellQuote helper**

In `TradeCalculator.swift`, add the `quoteSell` function after `quoteBuy` (before `// MARK: - Private helpers`):

```swift
    // MARK: - Sell

    public static func quoteSell(holding: Int, averageCost: Double,
                                 tier: PositionTier, price: Double,
                                 fees: FeeSnapshot) -> Result<SellQuote, TradeReason> {
        // averageCost 属冻结签名；E3 不用它（已实现盈亏由 E5 调用方按 averageCost 计算）。
        guard price > 0, holding >= 0, price.isFinite else {
            return .failure(.invalidShareCount)
        }
        guard holding > 0 else { return .failure(.disabled) }

        let sellShares: Int
        if tier == .tier5 {
            sellShares = holding                        // 清仓：全部持仓，不取整，允许零股
        } else {
            // robustFloor 在 sell 路径为防御性对称（整数 holding × 5 档比例不会 FP 下溢），
            // 与 buy 路径保持一致 floor 语义。
            sellShares = (robustFloor(Double(holding) * ratio(of: tier)) / shareLotSize) * shareLotSize
        }
        guard sellShares > 0 else { return .failure(.insufficientHolding) }

        return .success(makeSellQuote(shares: sellShares, price: price, fees: fees))
    }
```

And add `makeSellQuote` to the private helpers section (after `computeCommission`):

```swift
    private static func makeSellQuote(shares: Int, price: Double, fees: FeeSnapshot) -> SellQuote {
        let notional = Double(shares) * price
        let commission = computeCommission(notional: notional, fees: fees)
        let stampDuty = notional * stampDutyRate
        let proceeds = notional - commission - stampDuty
        return SellQuote(shares: shares, notional: notional, commission: commission,
                         stampDuty: stampDuty, proceeds: proceeds)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/Contracts && swift test --filter TradeCalculatorSellTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift
git commit -m "feat(E3): TradeCalculator.quoteSell（清仓零股 + FP 根治）"
```

---

## Task 3: `forceCloseOnEnd`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift`

- [ ] **Step 1: Write the failing tests (forceCloseOnEnd)**

Append to `TradeCalculatorTests.swift`:

```swift
@Suite("TradeCalculator.forceCloseOnEnd")
struct TradeCalculatorForceCloseTests {

    @Test("happy: 全量清仓，佣金+印花税")
    func happy() {
        let q = TradeCalculator.forceCloseOnEnd(holding: 1000, averageCost: 15,
                                                price: 20, fees: noMin)
        #expect(q.shares == 1000)
        #expect(approx(q.notional, 20_000))
        #expect(approx(q.commission, 2.0))
        #expect(approx(q.stampDuty, 10.0))
        #expect(approx(q.proceeds, 19_988.0))           // 20000-2-10
    }

    @Test("奇数持仓全量清仓不取整")
    func oddLot() {
        let q = TradeCalculator.forceCloseOnEnd(holding: 1234, averageCost: 15,
                                                price: 10, fees: noMin)
        #expect(q.shares == 1234)
        #expect(approx(q.notional, 12_340))
    }

    @Test("holding=0: 全零报价（无交易无费用）")
    func zeroHolding() {
        let q = TradeCalculator.forceCloseOnEnd(holding: 0, averageCost: 0,
                                                price: 20, fees: withMin)
        #expect(q.shares == 0)
        #expect(approx(q.notional, 0))
        #expect(approx(q.commission, 0))                // 不触发 min5
        #expect(approx(q.stampDuty, 0))
        #expect(approx(q.proceeds, 0))
    }

    @Test("min commission: 清仓免5开启且佣金<5 计 5")
    func minCommission() {
        let q = TradeCalculator.forceCloseOnEnd(holding: 1000, averageCost: 15,
                                                price: 20, fees: withMin)
        #expect(approx(q.commission, 5.0))              // raw 2.0 < 5 -> 5
        #expect(approx(q.proceeds, 19_985.0))           // 20000-5-10
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/Contracts && swift test --filter TradeCalculatorForceCloseTests`
Expected: FAIL — `type 'TradeCalculator' has no member 'forceCloseOnEnd'`.

- [ ] **Step 3: Add forceCloseOnEnd**

In `TradeCalculator.swift`, add after `quoteSell` (before `// MARK: - Private helpers`):

```swift
    // MARK: - Force close (end of game)

    public static func forceCloseOnEnd(holding: Int, averageCost: Double,
                                       price: Double, fees: FeeSnapshot) -> SellQuote {
        // 局终全量清仓，无错误通道；holding<=0 或非法 price -> 全零报价（无交易无费用）。
        // averageCost 属冻结签名；E3 不用它（已实现盈亏由 E5 调用方计算）。
        guard holding > 0, price > 0, price.isFinite else {
            return SellQuote(shares: 0, notional: 0, commission: 0, stampDuty: 0, proceeds: 0)
        }
        return makeSellQuote(shares: holding, price: price, fees: fees)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/Contracts && swift test --filter TradeCalculatorForceCloseTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full Contracts suite (no regressions)**

Run: `cd ios/Contracts && swift test`
Expected: PASS — all pre-existing suites still pass + 20 new TradeCalculator tests, 0 failures.（闸门为"全绿 0 failure"，不硬断言历史 test 计数——parameterized `@Test(arguments:)` 的 run-count 与 annotation-count 不可直接相加。）

- [ ] **Step 6: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift
git commit -m "feat(E3): TradeCalculator.forceCloseOnEnd（局终全量清仓）"
```

---

## Task 4: 非编码者验收清单 + 最终验证

**Files:**
- Create: `docs/acceptance/2026-05-23-pr-e3-tradecalculator.md`

- [ ] **Step 1: Run full suite + capture evidence**

Run: `cd ios/Contracts && swift test 2>&1 | tail -20`
Capture the pass count for the acceptance doc.

- [ ] **Step 2: Write the acceptance checklist**

Create `docs/acceptance/2026-05-23-pr-e3-tradecalculator.md` — 中文、非编码者可执行（动作 / 预期 / 通过判定），无禁忌词（见 `.claude/workflow-rules.json`）。每节给：用户做什么动作、预期看到什么、如何判定通过/失败。覆盖：买入整手、买入资金不足、卖出整手、卖出清仓零股、卖出空仓 disabled、局终清仓、免5开关、印花税、浮点不掉股共 9 节，并附"运行 `cd ios/Contracts && swift test` 全绿"的总闸门一节。

- [ ] **Step 3: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add docs/acceptance/2026-05-23-pr-e3-tradecalculator.md
git commit -m "docs(E3): TradeCalculator 非编码者验收清单"
```

---

## Self-Review

**1. Spec coverage:**
- §E3 签名（quoteBuy/quoteSell/forceCloseOnEnd + BuyQuote/SellQuote + 3 常量）→ Task 1-3 逐字匹配 ✓
- §4.2 买入（目标金额=总资金×比例 / floor 100 倍 / 股数0→资金不足 / 佣金 / 免5 / 总成本）→ Task 1 ✓
- §4.2 卖出（相对持仓 / 100 倍取整 / 5/5 清仓零股 / 非清仓0→持仓不足 / 佣金 / 免5 / 印花税 / 到手）→ Task 2 ✓
- forceCloseOnEnd（签名仅给，行为按"全量清仓+卖出费用规则"推断）→ Task 3 ✓ + 验收文档说明推断
- TradeReason 4 case 全覆盖（Task 0 归属表 + 各 Task 错误测试）✓
- M0.4 豁免（L62）→ Task 0 文档化，无 gate 脚本 ✓

**2. Placeholder scan:** 无 TBD/TODO/"similar to"；每步含完整代码与命令 ✓

**3. Type consistency:**
- `BuyQuote(shares:notional:commission:totalCost:)` — Task 1 定义，Task 1 测试一致 ✓
- `SellQuote(shares:notional:commission:stampDuty:proceeds:)` — Task 1 定义，Task 2/3 测试 + `makeSellQuote` 一致 ✓
- `robustFloor` / `computeCommission` / `ratio(of:)` / `makeSellQuote` — Task 1 引入，Task 2/3 复用，签名一致 ✓
- `PositionTier` case 名 `.tier1`..`.tier5`（Models.swift:25）✓；`FeeSnapshot(commissionRate:minCommissionEnabled:)`（Models.swift:143）✓；`TradeReason` 4 case（AppError.swift:36）✓
