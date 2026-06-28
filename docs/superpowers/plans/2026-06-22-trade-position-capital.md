# RFC-A 交易/仓位/资金对齐主流 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把交易/仓位/资金改造为主流股票软件风格——按股数下单 + 两步式买卖框 + 持仓浮动盈亏 + 跨局复利资金（重置保留历史）。

**Architecture:** 引擎/计算器从「按 PositionTier 比例」演进为「按股数」（比例降级为快捷填入股数的辅助）；UI 把「点买卖即弹 5 档条」换成「点买卖弹数量框」（沿用 RFC-B 的 active-panel overlay 机制，零机制改动）；资金从「派生自末条记录」改为「`settings.total_capital` 权威字段，每局结束写、开局直读 DB」，重置改为保留历史记录。触碰 Wave-1 冻结契约 E3，按 m01 §A 类「改既有语义」bump `CONTRACT_VERSION` 1.6→1.7。

**Tech Stack:** Swift / SwiftUI（iOS 17 / macOS 14 / Mac Catalyst）；Swift Testing（Contracts host 测：`@Suite`/`@Test`/`#expect`）；XCTest + GRDB `DatabaseMigrator`（Persistence 测，经 `AppDBFixture.makeFreshDB()`）。

## Global Constraints

- **一手 = 100 股**：`TradeCalculator.shareLotSize = 100`（已存在，复用，勿改值）。
- **买 = 可用现金基准**：买 k/5 = `floor(cash × k/5 / price / 100) × 100`（k=1..4）；**全仓 = `maxBuyableShares`（fee-aware 上限）**，非朴素 `floor(cash/price/100)×100`。
- **卖 = 持仓基准**：卖 k/5 = `floor(holding × k/5 / 100) × 100`（k=1..4）；**清仓 = 全部持仓（精确，含非整手奇数股）**。
- **D7 清仓奇数股例外**：`quoteSell` 在 `shares == holding` 时放行任意股数；仅部分卖要求整手。
- **0 持仓禁卖**；买卖均经全局 `currentPrice`（**不做 per-period 取价**）。
- **bump `CONTRACT_VERSION` `"1.6"`→`"1.7"`**（m01 §A 类「改既有语义」，同 E2 1.4→1.5 先例）。
- **无 DDL 表结构改动**；migration `0005` = 仅 `key='total_capital'` 单键 DML upsert + `user_version` 2→3。**禁止无 WHERE 的 `UPDATE settings SET value=…`**。
- **资金权威源** = `settings.total_capital`（DB）；`startingCapital()` 直读 DB；finalize 在终结事务内写；reset 置 10 万 + **保留**记录。
- 等比/FP host 断言用容差（`approx`，1e-6）且 FP demonstrator 须 mutation-verify 非空洞；负向 grep 断言用 `if … ; exit 1` 非 `! grep`。
- 评审通道 = `codex:adversarial-review`（唯一权威；经 `.claude/scripts/codex-attest.sh`）。
- spec 权威源：`docs/superpowers/specs/2026-06-22-trade-position-capital-design.md`。

---

## File Structure

**新建：**
- `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxContent.swift` — A2 买卖框纯值（可买/可卖、预估、各档填入股数、确认使能）。host 测。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxView.swift` — A2 买卖框 SwiftUI 薄壳（数量框 + ±100 + 比例快捷 + ✕ + 全宽确认）。
- `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeBoxContentTests.swift`
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDB0005MigrationTests.swift`

**修改：**
- `ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift` — 加按股数 `quoteBuy`/`quoteSell` + `maxBuyableShares` + `sharesForBuyTier`/`sharesForSellTier` + `tierForFraction`（Task 1）；**末期删** tier-based `quoteBuy(totalCapital:…)`/`quoteSell(…tier:)`（Task 9）。
- `ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator` 测试：`ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift` — 加按股数测试（Task 1），末期迁移 tier 测试（Task 9）。
- `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` — 加 `buy(panel:shares:)`/`sell(panel:shares:)`（Task 2）；改 `buyEnabled`（Task 9）；末期删 tier-based `buy/sell(panel:tier:)`（Task 9）。
- `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` — `startingCapital()` 直读 DB；`finalize()` 用 finalizeSession 返回的权威资金刷活缓存（Task 3）。
- `ios/Contracts/Sources/KlineTrainerContracts/Persistence/SessionFinalizationPort.swift` + `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift` — `finalizeSession` 返回 `(id,totalCapital)`、事务内从持久记录派生权威资金随返回；`resetAllTrainingProgress` 去 `deleteAll`（Task 3）。
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift` — 加 `0005`（Task 4）。
- `ios/sql/app_schema_v1.sql` — `PRAGMA user_version` baseline 注释同步（Task 4，无结构变更）。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` — `performTrade` 改 shares + overlay 换 `TradeBoxView` + topBar 传 currentPrice（Task 8）。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift` — 浮动盈亏改持仓 PnL（Task 6）。
- `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` + `ModelsTests.swift` — bump 1.7（Task 10）。
- `docs/governance/m01-schema-versioning-contract.md` — bump 记录（Task 10，触发 CODEOWNERS）。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift` — 主页当前资金恒用权威 `configuredCapital`（去派生 `statistics.currentCapital`，Task 5/D6）。

**任务依赖序**：1（计算器加法）→ 2（引擎加法）→ 3（资金读写）→ 4（迁移）→ 5（D6 消费者）→ 6（A3 PnL）→ 7（A2 框纯值）→ 8（A2 框壳 + UI 接线，UI 切到 shares）→ 9（D3 删 tier，须在 8 之后）→ 10（bump）→ 11（验收）。

---

### Task 1: TradeCalculator 按股数 API + helpers（纯函数，host 测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift`（在 `enum TradeCalculator` 内、现有方法之后追加；现有 tier 方法本任务**不动**；含 R-plan-6-1 费率守卫）
- Modify（R-plan-6-1 费率信任边界）：`ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift`（`saveSettings`/`parseDouble` 拒**负** commissionRate）+ `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift`（输入校验拒负费率）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift`（追加按股数 + 费率守卫 `@Suite`）+ `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift`（负费率拒收）

**Interfaces:**
- Consumes: 现有 `BuyQuote`/`SellQuote`（字段不变）、`TradeReason`、`FeeSnapshot`、`shareLotSize`、`robustFloor`、`computeCommission`、`makeSellQuote`、`ratio(of:)`、`PositionTier`。
- Produces（Task 2/7/9 依赖这些精确签名）:
  - `static func quoteBuy(cash: Double, shares: Int, price: Double, fees: FeeSnapshot) -> Result<BuyQuote, TradeReason>`
  - `static func quoteSell(cash: Double, holding: Int, shares: Int, price: Double, fees: FeeSnapshot) -> Result<SellQuote, TradeReason>`（cash 用于净现金非负校验，集中可执行性契约）
  - `static func maxBuyableShares(cash: Double, price: Double, fees: FeeSnapshot) -> Int`
  - `static func sharesForBuyTier(cash: Double, price: Double, tier: PositionTier, fees: FeeSnapshot) -> Int`
  - `static func sharesForSellTier(holding: Int, tier: PositionTier) -> Int`
  - `static func tierForFraction(_ fraction: Double) -> PositionTier`

- [ ] **Step 1: 写失败测试**（追加到 `TradeCalculatorTests.swift` 末尾）

```swift
@Suite("TradeCalculator.quoteBuy(shares:)")
struct TradeCalculatorBuySharesTests {
    @Test("happy: 整手买入，cost=notional+commission")
    func happy() {
        let r = TradeCalculator.quoteBuy(cash: 100_000, shares: 2000, price: 10, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(q.shares == 2000)
        #expect(approx(q.notional, 20_000))
        #expect(approx(q.commission, 2.0))      // 20000*0.0001
        #expect(approx(q.totalCost, 20_002))
    }
    @Test("非整手 → invalidShareCount")
    func notLot() {
        #expect(TradeCalculator.quoteBuy(cash: 100_000, shares: 250, price: 10, fees: noMin)
                == .failure(.invalidShareCount))
    }
    @Test("0/负股 → invalidShareCount")
    func zeroShares() {
        #expect(TradeCalculator.quoteBuy(cash: 100_000, shares: 0, price: 10, fees: noMin)
                == .failure(.invalidShareCount))
    }
    @Test("现金不足 → insufficientCash")
    func cashShort() {
        // 1000 股 ×10 = 10000，+佣金 1 = 10001 > 10000
        #expect(TradeCalculator.quoteBuy(cash: 10_000, shares: 1000, price: 10, fees: noMin)
                == .failure(.insufficientCash))
    }
}

@Suite("TradeCalculator.quoteSell(shares:)")
struct TradeCalculatorSellSharesTests {
    @Test("happy: 部分整手卖")
    func happy() {
        let r = TradeCalculator.quoteSell(cash: 100_000, holding: 1000, shares: 400, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(q.shares == 400)
        #expect(approx(q.notional, 8_000))
        #expect(approx(q.commission, 0.8))      // 8000*0.0001
        #expect(approx(q.stampDuty, 4.0))       // 8000*0.0005
        #expect(approx(q.proceeds, 7_995.2))
    }
    @Test("D7 清仓: shares==holding 奇数股放行")
    func clearOddLot() {
        let r = TradeCalculator.quoteSell(cash: 100_000, holding: 150, shares: 150, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(q.shares == 150)
    }
    @Test("D7 部分卖非整手且≠holding → invalidShareCount")
    func partialOddLot() {
        #expect(TradeCalculator.quoteSell(cash: 100_000, holding: 150, shares: 50, price: 20, fees: noMin)
                == .failure(.invalidShareCount))
    }
    @Test("超持仓 → insufficientHolding")
    func overSell() {
        #expect(TradeCalculator.quoteSell(cash: 100_000, holding: 100, shares: 200, price: 20, fees: noMin)
                == .failure(.insufficientHolding))
    }
    @Test("R-plan-14-1：净现金<0（低价小手+免5、近零现金）→ insufficientHolding 之前先 insufficientCash")
    func negativeNetCash() {
        // 100 股 ×0.01 = notional 1；免5 commission=5；proceeds = 1-5-tiny ≈ -4.0005；cash=0 → newCash<0
        #expect(TradeCalculator.quoteSell(cash: 0, holding: 100, shares: 100, price: 0.01, fees: withMin)
                == .failure(.insufficientCash))
        // 现金够覆盖净损（cash=10）→ 放行
        if case .success = TradeCalculator.quoteSell(cash: 10, holding: 100, shares: 100, price: 0.01, fees: withMin) {} 
        else { Issue.record("cash 够覆盖净损应放行") }
    }
    @Test("R-plan-14-1：极端价输出非有限 → invalidShareCount（不返非有限 quote）")
    func nonFiniteOutput() {
        #expect(TradeCalculator.quoteSell(cash: 1e300, holding: 1_000_000, shares: 1_000_000,
                                          price: .greatestFiniteMagnitude, fees: noMin)
                == .failure(.invalidShareCount))
    }
}

@Suite("TradeCalculator share helpers")
struct TradeCalculatorShareHelperTests {
    @Test("maxBuyableShares: fee-aware 上限（差1手 vs 恰好够）")
    func maxBuyable() {
        // cash=10_001, price=10, rate=0.0001：1000 股 notional=10000 commission=1 total=10001≤10001 ✓；
        // 1100 股 total=11001.1 > 10001 ✗ → 上限 1000
        #expect(TradeCalculator.maxBuyableShares(cash: 10_001, price: 10, fees: noMin) == 1000)
        // cash=10_000：1000 股 total=10001 > 10000 → 退到 900
        #expect(TradeCalculator.maxBuyableShares(cash: 10_000, price: 10, fees: noMin) == 900)
    }
    @Test("maxBuyableShares: 免5 下限触发")
    func maxBuyableMinComm() {
        // withMin：佣金下限 5。cash=1005, price=1：1000 股 notional=1000 commission=max(0.1,5)=5 total=1005≤1005 ✓
        #expect(TradeCalculator.maxBuyableShares(cash: 1_005, price: 1, fees: withMin) == 1000)
        // cash=1004：1000 股 total=1005>1004 → 900（notional900 comm5 total905≤1004）
        #expect(TradeCalculator.maxBuyableShares(cash: 1_004, price: 1, fees: withMin) == 900)
    }
    @Test("maxBuyableShares: 现金/价非法 → 0")
    func maxBuyableGuard() {
        #expect(TradeCalculator.maxBuyableShares(cash: 0, price: 10, fees: noMin) == 0)
        #expect(TradeCalculator.maxBuyableShares(cash: 100, price: 0, fees: noMin) == 0)
    }
    @Test("R-plan-6-1：负/近-1/非有限费率不 trap，返 0 / 失败")
    func badCommissionRateNoTrap() {
        let neg1 = FeeSnapshot(commissionRate: -1, minCommissionEnabled: false)      // (1+rate)=0 → 旧码除零 +inf → Int() trap
        let near = FeeSnapshot(commissionRate: -0.9999, minCommissionEnabled: false)  // 旧码巨大值超 Int 范围 → trap
        let inf  = FeeSnapshot(commissionRate: .infinity, minCommissionEnabled: false)
        // 守卫后：不崩，返 0
        #expect(TradeCalculator.maxBuyableShares(cash: 100_000, price: 10, fees: neg1) == 0)
        #expect(TradeCalculator.maxBuyableShares(cash: 100_000, price: 10, fees: near) == 0)
        #expect(TradeCalculator.maxBuyableShares(cash: 100_000, price: 10, fees: inf)  == 0)
        // quoteBuy/quoteSell 同样守卫 → .invalidShareCount（不崩）
        #expect(TradeCalculator.quoteBuy(cash: 100_000, shares: 1000, price: 10, fees: neg1) == .failure(.invalidShareCount))
        #expect(TradeCalculator.quoteSell(cash: 100_000, holding: 1000, shares: 100, price: 10, fees: neg1) == .failure(.invalidShareCount))
        // 正常正费率仍工作
        #expect(TradeCalculator.maxBuyableShares(cash: 10_001, price: 10, fees: noMin) == 1000)
    }
    @Test("R-plan-10-2：极小有限价（商溢出 > Int.max）不 trap，返 0")
    func tinyPriceNoTrap() {
        let tiny = Double.leastNonzeroMagnitude          // cash/tiny → +inf
        #expect(TradeCalculator.maxBuyableShares(cash: 100_000, price: tiny, fees: noMin) == 0)
        #expect(TradeCalculator.sharesForBuyTier(cash: 100_000, price: tiny, tier: .tier1, fees: noMin) == 0)
        #expect(TradeCalculator.sharesForBuyTier(cash: 100_000, price: tiny, tier: .tier5, fees: noMin) == 0)
        // 商超 Int.max 但有限（cash 大、price 极小但非最小）：1e308/1e-300 ≈ 1e608=inf → 0；用可控值
        #expect(TradeCalculator.maxBuyableShares(cash: 1e300, price: 1e-300, fees: noMin) == 0)
    }
    @Test("R-plan-15-1：tiny 有限价 + 免5 二分即时返回（不空转），边界正确")
    func tinyPriceMinCommissionPrompt() {
        let withMin = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let n = TradeCalculator.maxBuyableShares(cash: 1_000, price: 1e-9, fees: withMin)
        #expect(n > 0 && n % 100 == 0)
        // n 可行、n+100 不可行（证明二分取到精确最大手数，非近似；且必然瞬时返回=非空转）
        #expect(Double(n) * 1e-9 + 5 <= 1_000.0 + 1e-6)
        #expect(Double(n + 100) * 1e-9 + 5 > 1_000.0)
    }
    @Test("sharesForBuyTier: 1/5..4/5 = cash 基准 lot-floor；全仓 = maxBuyable")
    func buyTier() {
        #expect(TradeCalculator.sharesForBuyTier(cash: 100_000, price: 10, tier: .tier1, fees: noMin) == 2000)
        #expect(TradeCalculator.sharesForBuyTier(cash: 100_000, price: 10, tier: .tier4, fees: noMin) == 8000)
        // 全仓：cash=100_000 →maxBuyable=9900（10000 股 total=100010>100000）
        #expect(TradeCalculator.sharesForBuyTier(cash: 100_000, price: 10, tier: .tier5, fees: noMin) == 9900)
    }
    @Test("sharesForSellTier: 1/5..4/5 = holding 基准 lot-floor；清仓 = 全部（含奇数）")
    func sellTier() {
        #expect(TradeCalculator.sharesForSellTier(holding: 1000, tier: .tier2) == 400)
        #expect(TradeCalculator.sharesForSellTier(holding: 150, tier: .tier5) == 150)   // 清仓含奇数
        #expect(TradeCalculator.sharesForSellTier(holding: 0, tier: .tier5) == 0)
    }
    @Test("tierForFraction: round×5 clamp 1..5")
    func tierFrac() {
        #expect(TradeCalculator.tierForFraction(0.0) == .tier1)   // clamp 下限 1
        #expect(TradeCalculator.tierForFraction(0.2) == .tier1)
        #expect(TradeCalculator.tierForFraction(0.5) == .tier3)   // round(2.5)=2... 见实现：rounded() banker? 用 .toNearestOrAwayFromZero
        #expect(TradeCalculator.tierForFraction(1.0) == .tier5)
        #expect(TradeCalculator.tierForFraction(2.0) == .tier5)   // clamp 上限 5
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter TradeCalculatorBuySharesTests`
Expected: 编译失败（`quoteBuy(cash:shares:…)` 等方法未定义）。

- [ ] **Step 3: 实现**（追加到 `TradeCalculator.swift` 的 `ratio(of:)` 之后、`enum` 闭合 `}` 之前）

```swift
    // MARK: - RFC-A 按股数 API（A1）

    /// 按股数买入报价（可用现金约束）。
    public static func quoteBuy(cash: Double, shares: Int, price: Double,
                                fees: FeeSnapshot) -> Result<BuyQuote, TradeReason> {
        guard price > 0, cash >= 0, price.isFinite, cash.isFinite else {
            return .failure(.invalidShareCount)
        }
        // codex R-plan-6-1：费率信任边界守卫——拒非有限/负费率，防后续除法/Int 转换 trap。
        guard fees.commissionRate.isFinite, fees.commissionRate >= 0 else { return .failure(.invalidShareCount) }
        guard shares > 0, shares % shareLotSize == 0 else { return .failure(.invalidShareCount) }
        let notional = Double(shares) * price
        let commission = computeCommission(notional: notional, fees: fees)
        let totalCost = notional + commission
        guard totalCost <= cash else { return .failure(.insufficientCash) }
        return .success(BuyQuote(shares: shares, notional: notional,
                                 commission: commission, totalCost: totalCost))
    }

    /// 按股数卖出报价。D7：shares==holding（清仓）放行任意股数（含奇数）；部分卖要求整手。
    /// 按股数卖出报价。R-plan-14-1：集中**可执行性契约**（输出有限 + 净现金非负），UI 与 engine 同源。
    public static func quoteSell(cash: Double, holding: Int, shares: Int, price: Double,
                                 fees: FeeSnapshot) -> Result<SellQuote, TradeReason> {
        guard price > 0, holding >= 0, price.isFinite, cash.isFinite else { return .failure(.invalidShareCount) }
        guard fees.commissionRate.isFinite, fees.commissionRate >= 0 else { return .failure(.invalidShareCount) }  // R-plan-6-1
        guard shares > 0 else { return .failure(.invalidShareCount) }
        guard shares <= holding else { return .failure(.insufficientHolding) }
        if shares != holding {                      // 部分卖才要求整手（清仓例外）
            guard shares % shareLotSize == 0 else { return .failure(.invalidShareCount) }
        }
        let q = makeSellQuote(shares: shares, price: price, fees: fees)
        // R-plan-14-1：极端价 → 输出非有限 → 失败（防 UI 格式化非有限 / engine 写脏值）。
        guard q.notional.isFinite, q.commission.isFinite, q.stampDuty.isFinite, q.proceeds.isFinite else {
            return .failure(.invalidShareCount)
        }
        // R-plan-12-1/13-1：净现金不得为负（手续费>持仓价值且现金不够覆盖）→ 不可执行。
        let newCash = cash + q.proceeds
        guard newCash.isFinite, newCash >= 0 else { return .failure(.insufficientCash) }
        return .success(q)
    }

    /// fee-aware 可买上限：满足 totalCost(N) ≤ cash 的最大 100 股整数倍。
    public static func maxBuyableShares(cash: Double, price: Double, fees: FeeSnapshot) -> Int {
        guard price > 0, cash > 0, price.isFinite, cash.isFinite else { return 0 }
        // codex R-plan-6-1：守卫费率 finite 且 ≥0 → (1+rate)≥1>0 不除零、无 inf。
        guard fees.commissionRate.isFinite, fees.commissionRate >= 0 else { return 0 }
        // codex R-plan-10-2：极小有限价会令商 +inf 或 > Int.max → robustFloor 的 Int() trap；
        // 守卫商有限且在 Int 转换界内（degenerate 行情 → 返 0 禁买，不崩）。
        let quotient = cash / (price * (1 + fees.commissionRate))
        guard quotient.isFinite, quotient < Double(Int.max) else { return 0 }
        // 上界 = 忽略 min 佣金的估值（lot 数）；min 佣金只增成本 → 真值 ≤ 此上界。
        let hiBound = robustFloor(quotient) / shareLotSize
        guard hiBound >= 1 else { return 0 }
        // totalCost(lots) 对 lots **单调增**（notional 增、commission = max(notional×rate, min) 增/平）→ 可二分。
        func totalCost(_ lots: Int) -> Double {
            let n = Double(lots * shareLotSize) * price
            return n + computeCommission(notional: n, fees: fees)
        }
        // codex R-plan-15-1：用**二分**取代逐手递减循环（tiny 价+免5 时递减可达千万次 → UI 卡死）。O(log) ≤ ~60 次。
        guard totalCost(1) <= cash else { return 0 }              // 1 手都买不起
        if totalCost(hiBound) <= cash { return hiBound * shareLotSize }   // 上界即可行
        var lo = 1, hi = hiBound                                  // lo 可行、hi 不可行
        while lo + 1 < hi {
            let mid = lo + (hi - lo) / 2
            if totalCost(mid) <= cash { lo = mid } else { hi = mid }
        }
        return lo * shareLotSize
    }

    /// 比例 → 买入快捷股数（1/5..4/5 = cash 基准 lot-floor；全仓 = maxBuyableShares）。
    public static func sharesForBuyTier(cash: Double, price: Double, tier: PositionTier,
                                        fees: FeeSnapshot) -> Int {
        if tier == .tier5 { return maxBuyableShares(cash: cash, price: price, fees: fees) }
        guard price > 0, cash >= 0, price.isFinite, cash.isFinite else { return 0 }
        // R-plan-10-2：同 maxBuyableShares，极小价令商溢出 → 守卫后 robustFloor 不 trap。
        let quotient = cash * ratio(of: tier) / price
        guard quotient.isFinite, quotient < Double(Int.max) else { return 0 }
        let raw = robustFloor(quotient)
        return (raw / shareLotSize) * shareLotSize
    }

    /// 比例 → 卖出快捷股数（1/5..4/5 = holding 基准 lot-floor；清仓 = 全部持仓含奇数）。
    public static func sharesForSellTier(holding: Int, tier: PositionTier) -> Int {
        guard holding > 0 else { return 0 }
        if tier == .tier5 { return holding }
        return (robustFloor(Double(holding) * ratio(of: tier)) / shareLotSize) * shareLotSize
    }

    /// 成交占比 → 最近档（仅供 TradeOperation.positionTier 记录展示，D4；不参与算术）。
    public static func tierForFraction(_ fraction: Double) -> PositionTier {
        let n = max(1, min(5, Int((fraction * 5).rounded(.toNearestOrAwayFromZero))))
        switch n {
        case 1: return .tier1
        case 2: return .tier2
        case 3: return .tier3
        case 4: return .tier4
        default: return .tier5
        }
    }
```

- [ ] **Step 4: 跑测试确认通过 + mutation-verify maxBuyable 边界**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter "TradeCalculatorBuySharesTests|TradeCalculatorSellSharesTests|TradeCalculatorShareHelperTests"`
Expected: 全 PASS。
Mutation-verify：临时把 `maxBuyableShares` 的 `<= cash` 改成 `< cash`，确认 `maxBuyable`（恰好够=1000）测试 FAIL（证明边界非空洞），改回。

- [ ] **Step 5: settings 非负信任边界（R-plan-6-1 费率 + R-plan-16-1 资金）—— 每个边界都守**

> `commissionRate` 与 `total_capital` 都是**非负**量；非负不变量必须落到 **load / save 双边界**（否则 legacy/腐坏负值能绕过 setTotalCapital 直接经 loadSettings 成为权威，R-plan-16-1）。
> ① `SettingsDAOImpl.parseDouble`：现仅拒非有限，扩为**拒负**（`< 0` → `.persistence(.dbCorrupted)`，与现 malformed 同路径）。`parseDouble` 同时服务 commission_rate 与 total_capital，二者均非负 → 统一拒负即可（fail-closed；负值=腐坏，靠 reset 恢复）。
> ② `SettingsDAOImpl.saveSettings`：现仅 `isFinite` 守卫，加 `commissionRate >= 0` **且** `totalCapital >= 0`（负 → `.internalError` 拒写）。
> ③ `SettingsDAOImpl.setTotalCapital`：已在 Task 3 加 `finite && >= 0`（R-plan-13-1）。
> ④ `SettingsPanelContent`：用户输入费率校验拒负（沿用该文件现有数值校验范式）。
> 测试（`DefaultSettingsDAOTests` XCTest）：`saveSettings(commissionRate: -0.1)` / `saveSettings(totalCapital: -1)` throws；含 `commission_rate=-0.1` 或 **`total_capital=-1`** 的库 `loadSettings()` throws `.dbCorrupted`。

```swift
// SettingsDAOImpl.parseDouble 守卫扩展（示意）：拒非有限 + 拒负
guard let v = Double(raw), v.isFinite, v >= 0 else { throw AppError.persistence(.dbCorrupted) }
// SettingsDAOImpl.saveSettings 守卫扩展（示意）
guard s.commissionRate.isFinite, s.commissionRate >= 0 else {
    throw AppError.internalError(module: "P4-SettingsDAO", detail: "saveSettings refused: commissionRate invalid (\(s.commissionRate))")
}
guard s.totalCapital.isFinite, s.totalCapital >= 0 else {
    throw AppError.internalError(module: "P4-SettingsDAO", detail: "saveSettings refused: totalCapital invalid (\(s.totalCapital))")
}
```

- [ ] **Step 6: 跑确认通过 + 提交**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter "TradeCalculator|DefaultSettingsDAO"` → PASS

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift
git commit -m "feat(A1): TradeCalculator 按股数 API + maxBuyable/helpers（D7）+ 费率信任边界守卫（R-plan-6-1 防负费率 trap）"
```

---

### Task 2: TrainingEngine 按股数交易入口 + positionTier 反推（host 测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（加 `buy(panel:shares:)`/`sell(panel:shares:)`，**保留** tier 版到 Task 9）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/`（追加 `TrainingEngineSharesTradeTests.swift`，沿用现有 engine 测试构造 fixture 的范式 —— 实现前先 grep 一个现成 engine 测试看 `TrainingEngine.make`/preview 构造法）

**Interfaces:**
- Consumes: Task 1 的 `quoteBuy(cash:shares:)`/`quoteSell(holding:shares:)`/`tierForFraction`；现有 `position`/`cashBalance`/`currentPrice`/`markers`/`tradeOperations`/`advanceAndAccount`/`candleDatetime`/`period(of:)`/`flow.canBuySell()`。
- Produces（Task 8 依赖）:
  - `func buy(panel: PanelId, shares: Int) -> Result<TradeOperation, AppError>`
  - `func sell(panel: PanelId, shares: Int) -> Result<TradeOperation, AppError>`

- [ ] **Step 1: 写失败测试**

实现前先 `grep -rn "TrainingEngine.make\|TrainingEngine.preview" ios/Contracts/Tests/KlineTrainerContractsTests/ | head` 找现成构造范式，照搬一个能 buy/sell 的 Normal engine fixture。测试断言：
- `engine.buy(panel:.lower, shares:200)` 成功 → `position.shares` 增 200、`cashBalance` 减 quote.totalCost、`tradeOperations.last!.shares==200 && .direction==.buy && .positionTier` 为反推档。
- `engine.buy(panel:.lower, shares:250)`（非整手）→ `.failure(.trade(.invalidShareCount))`。
- 先全仓买、再 `engine.sell(panel:.lower, shares: position.shares)`（清仓，可能奇数）→ `position.shares==0`。
- `engine.sell` 超持仓 → `.failure(.trade(.insufficientHolding))`。
- **R-plan-8-1 溢出原子 no-op**（等价现有 `forceCloseManuallyNoOpOnFiniteOverflowPrice`）：构造一个使 `shares*price` 溢出非有限的极端有限价 tick（沿用现有 force-close 溢出测试的价/股构造），有持仓时 `engine.sell(panel:shares:)` → `.failure(.trade(.invalidShareCount))` 且 **`position`/`cashBalance`/`tradeOperations` 全不变**（整笔 no-op，不写非有限值）。
- **R-plan-12-1 净负现金 no-op**：低价小手 + **免5 下限**（`minCommissionEnabled` fees）、现金近零，卖该手 `quote.proceeds<0` 使 `newCash<0` → `engine.sell(panel:shares:)` → `.failure(.trade(.insufficientCash))` 且 `position`/`cashBalance`/`tradeOperations` **全不变**（保非负资金不变量，autosave 不出负现金）。

（测试体照搬现成 engine fixture 构造；断言用上述行为。）

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter TrainingEngineSharesTradeTests`
Expected: 编译失败（`buy(panel:shares:)` 未定义）。

- [ ] **Step 3: 实现**（在 `TrainingEngine.swift` 现有 `buy(panel:tier:)`/`sell(panel:tier:)` 之后追加）

```swift
    // MARK: - RFC-A 按股数交易入口（A1）

    public func buy(panel: PanelId, shares: Int) -> Result<TradeOperation, AppError> {
        guard flow.canBuySell() else { return .failure(.trade(.disabled)) }
        let price = currentPrice
        let entryTick = tick.globalTickIndex
        let p = period(of: panel)
        let cashBefore = cashBalance
        switch TradeCalculator.quoteBuy(cash: cashBefore, shares: shares, price: price, fees: fees) {
        case .failure(let reason):
            return .failure(.trade(reason))
        case .success(let quote):
            position.buy(shares: quote.shares, totalCost: quote.totalCost)
            cashBalance -= quote.totalCost
            markers.append(TradeMarker(globalTick: entryTick, price: price, direction: .buy))
            // D4：positionTier 仅记录展示，由占比反推（cashBefore>0 已由 quote 成功保证）
            let tier = TradeCalculator.tierForFraction(cashBefore > 0 ? quote.totalCost / cashBefore : 1)
            let op = TradeOperation(
                globalTick: entryTick, period: p, direction: .buy, price: price,
                shares: quote.shares, positionTier: tier,
                commission: quote.commission, stampDuty: 0,
                totalCost: quote.totalCost, createdAt: candleDatetime(atTick: entryTick))
            tradeOperations.append(op)
            advanceAndAccount(panel: panel)
            return .success(op)
        }
    }

    public func sell(panel: PanelId, shares: Int) -> Result<TradeOperation, AppError> {
        guard flow.canBuySell() else { return .failure(.trade(.disabled)) }
        let price = currentPrice
        let entryTick = tick.globalTickIndex
        let p = period(of: panel)
        let holdingBefore = position.shares
        // R-plan-14-1：经集中契约的 quoteSell(cash:…)——success 已保证「输出有限 + cashBalance+proceeds≥0」，
        // 故下方直接 mutate（与 TradeBoxContent 同一可执行性判定，UI/engine 不再发散）。
        switch TradeCalculator.quoteSell(cash: cashBalance, holding: holdingBefore, shares: shares, price: price, fees: fees) {
        case .failure(let reason):
            return .failure(.trade(reason))
        case .success(let quote):
            position.sell(shares: quote.shares)
            cashBalance += quote.proceeds               // quoteSell 已保证 cashBalance+proceeds 有限且 ≥0
            markers.append(TradeMarker(globalTick: entryTick, price: price, direction: .sell))
            let tier = TradeCalculator.tierForFraction(
                holdingBefore > 0 ? Double(quote.shares) / Double(holdingBefore) : 1)
            let op = TradeOperation(
                globalTick: entryTick, period: p, direction: .sell, price: price,
                shares: quote.shares, positionTier: tier,
                commission: quote.commission, stampDuty: quote.stampDuty,
                totalCost: quote.proceeds, createdAt: candleDatetime(atTick: entryTick))
            tradeOperations.append(op)
            advanceAndAccount(panel: panel)
            return .success(op)
        }
    }
```

> 买入路径 R-plan-8-1 已安全：`quoteBuy` 的 `guard totalCost <= cash` 对 `+inf`/`NaN` 返 false → `.insufficientCash`，故 success 必含有限 `totalCost`（且 ≤ cash → `cashBalance - totalCost` 有限非负），`position.buy(totalCost:)` precondition 不会被非有限值触发。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter TrainingEngineSharesTradeTests`
Expected: 全 PASS。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineSharesTradeTests.swift
git commit -m "feat(A1): TrainingEngine buy/sell(panel:shares:) + positionTier 反推记录（D4）"
```

---

### Task 3: A4 资金权威字段 — finalize 写 / startingCapital 直读 / reset 保留记录

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/SessionFinalizationPort.swift`（`finalizeSession` 返回 `Int64` → `(id:Int64, totalCapital:Double)`）+ **所有 conformer 同步**（`DefaultAppDB` 真实现 + 任何 InMemory/fake finalization port；编译报错指明）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（`finalizeSession` 事务内从持久记录派生资金并随返回值产出；`resetAllTrainingProgress` 去 `deleteAll`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`（加 `refreshTotalCapital(_:)` 纯缓存刷新）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（`startingCapital` 直读 DB；`finalize` 用 finalizeSession 返回的权威值刷活缓存）
- Test: `TrainingResetPortTests.swift`（reset 保留记录）+ `SessionFinalizationPortTests.swift`（finalize 返回+写权威资金 + retry 返回首次值）+ SettingsStore 测（`refreshTotalCapital`）+ coordinator 测（finalize→活缓存 + 刷缓存用返回值非 engine 现值）

**Interfaces:**
- Consumes: `SettingsDAOImpl.setTotalCapital`、`RecordRepositoryImpl.insertRecord`、`PendingTrainingRepositoryImpl.clearPending`、`SettingsDAO.loadSettings`、`SettingsStore`。
- Produces（Task 5 依赖）: `settings.total_capital` 权威当前资金；`finalizeSession(...) -> (id:Int64, totalCapital:Double)`（事务内产出权威资金随成功返回，retry 幂等）；`SettingsStore.refreshTotalCapital(_:)`（用返回的权威值同步活缓存，主页即时反映）。

- [ ] **Step 1: 写失败测试**

`TrainingResetPortTests.swift` 加（沿用 `AppDBFixture.makeFreshDB()` + `DefaultAppDB` 范式）：

```swift
func test_reset_keeps_records_and_sets_capital_100k() throws {
    // 先入一条 record（用 finalizeSession 或直接 insert helper，沿用本文件现有 insert 范式）
    // …插入 1 条 training_records…
    try db.resetAllTrainingProgress(toCapital: 100_000)
    let stats = try db.statistics()                       // 经 RecordRepository
    XCTAssertEqual(stats.totalCount, 1)                   // 记录保留（不再 deleteAll）
    XCTAssertEqual(try db.loadSettings().totalCapital, 100_000)
}
```

`SessionFinalizationPortTests.swift` 加（`someRecord`：total_capital=100_000, profit=23_456 → 派生 123_456）：

```swift
func test_finalize_returns_and_writes_capital_from_persisted_record() throws {
    let r = try db.finalizeSession(record: someRecord, ops: [], drawings: [], sessionKey: "k1")
    XCTAssertGreaterThan(r.id, 0)
    XCTAssertEqual(r.totalCapital, 123_456, accuracy: 1e-6)                      // 返回的权威值
    XCTAssertEqual(try db.loadSettings().totalCapital, 123_456, accuracy: 1e-6)  // 写入 DB = 同值
}
// codex R-plan-2-1/5-1：同 sessionKey retry 用「发散现值」record，返回值 + DB 仍=首次值（无更晚 session）
func test_finalize_retry_same_key_returns_first_capital() throws {
    _ = try db.finalizeSession(record: someRecord, ops: [], drawings: [], sessionKey: "k1")  // 123_456
    let divergent = someRecordWithProfit(999_999)
    let r2 = try db.finalizeSession(record: divergent, ops: [], drawings: [], sessionKey: "k1")
    XCTAssertEqual(r2.totalCapital, 123_456, accuracy: 1e-6)                      // 重复路径返回当前权威值(=首次)
    XCTAssertEqual(try db.loadSettings().totalCapital, 123_456, accuracy: 1e-6)   // DB 不被覆盖
}
// codex R-plan-9-1：finalize k1 → finalize k2(更新) → 过期重试 k1，权威资金**不回退**到 k1。
// recordWithCapital(v)：构造 total_capital+profit==v 的记录。
func test_stale_retry_after_newer_session_keeps_newer_capital() throws {
    _ = try db.finalizeSession(record: recordWithCapital(110_000), ops: [], drawings: [], sessionKey: "k1")
    _ = try db.finalizeSession(record: recordWithCapital(130_000), ops: [], drawings: [], sessionKey: "k2")
    let r = try db.finalizeSession(record: recordWithCapital(110_000), ops: [], drawings: [], sessionKey: "k1")  // 过期重试
    XCTAssertEqual(r.totalCapital, 130_000, accuracy: 1e-6)                       // 返回当前(k2)，不回退
    XCTAssertEqual(try db.loadSettings().totalCapital, 130_000, accuracy: 1e-6)   // DB 仍 k2
}
// codex R-plan-10-1：过期 finalize 重试不得清掉**他人**在飞 pending。
func test_stale_retry_does_not_clear_unrelated_pending() throws {
    _ = try db.finalizeSession(record: someRecord, ops: [], drawings: [], sessionKey: "k1")  // k1 finalize
    try db.savePending( /* 新 in-progress 局，session_key="k2"（沿用本套件 savePending 范式）*/ )
    _ = try db.finalizeSession(record: someRecord, ops: [], drawings: [], sessionKey: "k1")  // k1 过期重试
    XCTAssertNotNil(try db.loadPending())                       // k2 pending 仍在（未被误清）
    XCTAssertEqual(try db.loadPending()?.sessionKey, "k2")
}
// codex R-plan-12-2：重复重试遇**损坏**的 total_capital（非有限/畸形）→ finalize 抛 .dbCorrupted（不静默兜底 10万）。
func test_retry_with_corrupt_capital_fails_closed() throws {
    // 畸形（非数字）+ 负值（R-plan-17-1）两路都 fail-closed，不返非负/不刷负缓存。
    for bad in ["abc", "-1.0", "inf"] {
        _ = try db.finalizeSession(record: someRecord, ops: [], drawings: [], sessionKey: "k1")
        try db.rawWriteSetting("total_capital", bad)   // 绕过 setTotalCapital 守卫，模拟 DB 损坏
        XCTAssertThrowsError(try db.finalizeSession(record: someRecord, ops: [], drawings: [], sessionKey: "k1"),
                             "bad=\(bad)") { e in
            guard case AppError.persistence(.dbCorrupted) = e else { return XCTFail("expected .dbCorrupted for \(bad), got \(e)") }
        }
        try db.rawWriteSetting("total_capital", String(AppSettings.defaultTotalCapital))   // 复位供下一轮
    }
}
// codex R-plan-13-1：退化局（total_capital+profit < 0）→ 权威资金 floor 到 0（不写负值）。
func test_finalize_floors_negative_net_capital_to_zero() throws {
    let r = try db.finalizeSession(record: recordWithCapital(-5_000), ops: [], drawings: [], sessionKey: "kNeg")
    XCTAssertEqual(r.totalCapital, 0, accuracy: 1e-6)                        // 返回 floor 后 0
    XCTAssertEqual(try db.loadSettings().totalCapital, 0, accuracy: 1e-6)    // DB 写 0
}
```

`DefaultSettingsDAOTests` 加（R-plan-13-1：setTotalCapital 拒负）：`XCTAssertThrowsError(try db.setTotalCapital(-1))`（经端口/直调，沿用本套件范式）。

SettingsStore 单测（沿用该文件现成测试框架 + `SettingsStore.preview()`/`InMemorySettingsDAO`）：

```swift
@MainActor func test_refreshTotalCapital_updates_cache() {
    let store = SettingsStore.preview()
    store.refreshTotalCapital(250_000)
    #expect(store.settings.totalCapital == 250_000)   // 活缓存即时反映（不依赖 reload/重启）
}
```

coordinator 测（codex R-plan-3-1：finalize → 注入的活 `SettingsStore` 缓存即为新权威资金；沿用 `TrainingSessionPersistenceTests` 的 coordinator+AppDB+注入 SettingsStore 构造范式）：

```swift
func test_finalize_refreshes_live_settings_cache() async throws {
    // …startNewNormalSession → buy/sell 产生盈亏 → finalize…
    let id = try await coordinator.finalize(engine: engine)
    XCTAssertNotNil(id)
    // 同一注入的 SettingsStore：缓存值 == DB 权威值（无需重启/reload）
    XCTAssertEqual(injectedSettingsStore.settings.totalCapital,
                   try appDB.loadSettings().totalCapital, accuracy: 1e-6)
}

// codex R-plan-5-1：coordinator 刷缓存用 finalizeSession **返回的权威值**，非 engine 现值。
// 注入 stub SessionFinalizationPort 返回 (id:1, totalCapital:777_000)（刻意 ≠ engine.currentTotalCapital），
// 模拟「retry 时 DB 锚定首次记录值」；断言活缓存 == 777_000（返回值），非 engine 现值。
func test_finalize_refreshes_cache_from_returned_authority_not_engine() async throws {
    // …构造 coordinator 注入 stubFinalization(返回 (1, 777_000)) + injectedSettingsStore
    //   + 一个 currentTotalCapital≠777_000 的活跃 engine…
    _ = try await coordinator.finalize(engine: engine)
    XCTAssertEqual(injectedSettingsStore.settings.totalCapital, 777_000, accuracy: 1e-6)
}
// codex R-plan-13-1（局终自动强平退化局，整合）：构造低价持仓 + 免5 fees，使 maxTick 处自动 forceClose
// 净 proceeds 为负、currentTotalCapital<0 的 Normal 局；跑完 finalize 后断言 **DB/缓存 settings.total_capital >= 0**
// （floor 生效，非负权威资金；不动冻结的 performForceClose 记账，记录可仍记负 profit）。
func test_auto_end_force_close_negative_proceeds_floors_capital() async throws {
    // …startNewNormalSession（低价 fixture）→ 买满 → 推进到 maxTick 触发 forceCloseIfEnded → finalize…
    let id = try await coordinator.finalize(engine: engine)
    XCTAssertNotNil(id)
    XCTAssertGreaterThanOrEqual(try appDB.loadSettings().totalCapital, 0)            // 权威资金不为负
    XCTAssertGreaterThanOrEqual(injectedSettingsStore.settings.totalCapital, 0)      // 活缓存亦然
}
```

（`someRecord`/`someRecordWithProfit`/insert/coordinator 装配/stubFinalization 用本文件/`TrainingSessionPersistenceTests` 现成范式；stub = 实现 `SessionFinalizationPort` 返回固定 `(id, totalCapital)`。）

- [ ] **Step 2: 跑确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter "TrainingResetPortTests|SessionFinalizationPortTests"`
Expected: 编译失败（`finalizeSession` 现返回 `Int64`、测试用 `r.totalCapital`）+ reset 测试 FAIL（仍 deleteAll → totalCount==0）。

- [ ] **Step 3a: 改 `SessionFinalizationPort.finalizeSession` 返回类型 → `(id:Int64, totalCapital:Double)`，事务内派生权威资金随成功返回**

> codex R-plan-2-1 + R-plan-5-1：`insertRecord` 对重复 sessionKey 返**已存 id 不插入**（0004 幂等锚），故 DB 资金须从**持久记录** `total_capital+profit` 派生（retry 安全）。且 coordinator 刷缓存**不能用 retry engine 现值**（同 key retry 会与 DB 锚定的首次记录发散）→ 改为 `finalizeSession` **在写事务内产出权威值、随成功返回 `(id, totalCapital)`**：缓存从返回值刷 = 恒 == DB 权威（retry 也对）+ 值随成功返回（无 fallible 后置读，满足 R-plan-4-2）。代价 = 改 `SessionFinalizationPort` 返回类型 → **所有 conformer（含 fake）同步**（编译报错指明）。

`SessionFinalizationPort.swift` 协议方法返回 `Int64` → `(id: Int64, totalCapital: Double)`。`DefaultAppDB`：

```swift
    public func finalizeSession(record: TrainingRecord, ops: [TradeOperation],
                                drawings: [DrawingObject], sessionKey: String)
        throws -> (id: Int64, totalCapital: Double) {
        do {
            return try dbQueue.write { db in
                // R-plan-9-1：插入前判定「是否已存在该 sessionKey」——区分「新 finalize」vs「重复重试」。
                let alreadyExisted = try Int64.fetchOne(db, sql:
                    "SELECT id FROM training_records WHERE session_key = ?", arguments: [sessionKey]) != nil
                let id = try RecordRepositoryImpl.insertRecord(
                    db, record: record, ops: ops, drawings: drawings, sessionKey: sessionKey)
                // R-plan-10-1：仅清「属于本次 finalize sessionKey」的 pending（pending_training 单例 id=1，0004 加了
                // session_key）。过期重试 k1 时若当前 pending 是更新的 k2 在飞局 → key 不符 → 不清 → 防误删数据。
                let pendingKey = try String.fetchOne(db, sql:
                    "SELECT session_key FROM pending_training WHERE id = 1")
                if pendingKey == sessionKey {
                    try PendingTrainingRepositoryImpl.clearPending(db)
                }
                if alreadyExisted {
                    // 重复 sessionKey（含「更晚 session 已 finalize 后、旧 session 的过期重试」）：
                    // **不改权威资金**（否则会把 settings.total_capital 回退到旧 session 值）；
                    // 返回**当前**权威 settings 值 → coordinator 缓存刷新为 no-op，不回退。
                    // codex R-plan-12-2：与 SettingsDAOImpl.loadSettings 同口径 fail-closed——缺失→默认；
                    // 存在但畸形/非有限→抛 .dbCorrupted（**不静默兜底 10万**，否则掩盖 DB 损坏）。
                    let txt = try String.fetchOne(db, sql:
                        "SELECT value FROM settings WHERE key = 'total_capital'")
                    let current: Double
                    if let txt {
                        guard let v = Double(txt), v.isFinite, v >= 0 else { throw AppError.persistence(.dbCorrupted) }  // R-plan-17-1：含拒负
                        current = v
                    } else {
                        current = AppSettings.defaultTotalCapital   // 缺失 = 从未设置，合法默认
                    }
                    return (id, current)
                }
                // 新插入（当前 session 首次 finalize）→ 推进权威资金 = 本记录 total_capital+profit。
                guard let row = try Row.fetchOne(db, sql:
                    "SELECT total_capital, profit FROM training_records WHERE id = ?",
                    arguments: [id]) else {
                    throw AppError.internalError(module: "P4-finalize",
                                                 detail: "persisted record id=\(id) not found")
                }
                let tc: Double = row["total_capital"]
                let p: Double = row["profit"]
                // codex R-plan-13-1（user 拍板：持久化边界 floor）：权威资金不得为负（"不能欠钱"不变量）。
                // 退化局（局终强平 手续费>持仓价值 → currentTotalCapital<0）→ floor 到 0（=破产；记录仍如实记负 profit）。
                let authoritativeCapital = max(0, tc + p)
                try SettingsDAOImpl.setTotalCapital(db, authoritativeCapital)   // setTotalCapital 自带 finite + ≥0 守卫
                return (id, authoritativeCapital)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
```

**同时给 `SettingsDAOImpl.setTotalCapital` 加 `≥0` 守卫（R-plan-13-1 持久化边界，防任何 caller 写负权威资金）**——现仅 `value.isFinite`，扩为：

```swift
    static func setTotalCapital(_ db: Database, _ value: Double) throws {
        guard value.isFinite, value >= 0 else {       // R-plan-13-1：权威资金不得为负
            throw AppError.internalError(module: "P4-SettingsDAO",
                detail: "setTotalCapital refused: value invalid (\(value))")
        }
        try db.execute(sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                       arguments: [keyTotalCapital, String(value)])
    }
```
（`SettingsDAOImpl.swift` 已在 Task 1 Step 5 改过 commissionRate；此处同文件加 capital 守卫。）

- [ ] **Step 3b: 改 `DefaultAppDB.resetAllTrainingProgress`**（去 `deleteAll`，保留记录）

```swift
    public func resetAllTrainingProgress(toCapital: Double) throws {
        do {
            try dbQueue.write { db in
                // RFC-A：保留历史记录（去掉 deleteAll，推翻 #123）；仅清 pending + 置资金
                try PendingTrainingRepositoryImpl.clearPending(db)
                try SettingsDAOImpl.setTotalCapital(db, toCapital)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
```

- [ ] **Step 3c: `SettingsStore.refreshTotalCapital` + `startingCapital()` 直读 DB + `finalize()` 成功后刷活缓存**

> codex R-plan-3-1：`finalizeSession` 只写 DB，活 `SettingsStore` 缓存（`AppRouter.loadHome` 读 `settings.settings.totalCapital`）不变 → 结算返主页显示陈旧资金直到重启。必须 finalize 成功后同步刷缓存。reset 路径已刷（`SettingsStore.resetAllProgress` 设 `settings.totalCapital`）。

`SettingsStore` 加纯缓存刷新（DB 已由 finalize 写，此处仅同步内存；`@MainActor`，`@Observable` 触发 UI 更新）：

```swift
    /// A4：finalize/外部写库后把权威 total_capital 同步进活缓存（不再写库）。
    public func refreshTotalCapital(_ value: Double) {
        settings.totalCapital = value
    }
```

`startingCapital()`（直读 DB，绕开缓存陈旧）：

```swift
    private func startingCapital() throws -> Double {
        try settingsDAO.loadSettings().totalCapital
    }
```

`finalize()` 用 `finalizeSession` **随成功返回的 DB 权威值**刷活缓存（返回类型已改 `(id, totalCapital)`）：

```swift
        let result = try finalization.finalizeSession(record: record,
                                                      ops: engine.tradeOperations,
                                                      drawings: engine.drawings,
                                                      sessionKey: key)
        // R-plan-5-1：刷缓存用「事务内产出、随成功返回的 DB 权威值」result.totalCapital —— retry 也 = 持久
        // 记录值（非 retry engine 现值）→ 缓存恒 == DB 权威；R-plan-4-2：值随成功返回、无 fallible 后置读。
        settings.refreshTotalCapital(result.totalCapital)
        return result.id
```

- [ ] **Step 3d: pending 保存边界 floor cash（codex R-plan-18-2）**

> 退化局（局终自动强平 手续费>持仓价值 → `engine.cashBalance < 0`）若在 finalize 前被 autosave 写进 pending，
> 且 app 在 finalize 清 pending 前被杀 → 下次 `TrainingEngine.make` 拒负 `initialCashBalance` → **resume 被 brick**。
> finalize 的「权威资金 floor」管不到 pending 的原始 cashBalance。user 的「持久化边界 floor」决策**延伸到 pending 边界**：
> `saveProgress` 持久化 `pending.cashBalance` 时取 `max(0, engine.cashBalance)`（grep coordinator `saveProgress`/`PendingTraining(` 构造点，cashBalance 字段处 floor）。

测试（沿用 `TrainingSessionPersistenceTests` 范式）：构造负现金退化局，**注入 finalize 失败/模拟重启**（直接 saveProgress 后 loadPending + `TrainingEngine.make`），断言 pending 的 `cashBalance >= 0` 且 resume **不抛**（不 brick）。

- [ ] **Step 4: 跑确认通过 + 全量回归**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter "TrainingResetPortTests|SessionFinalizationPortTests"` → PASS
Run: `swift test` 全量。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/SessionFinalizationPort.swift ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingResetPortTests.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/SessionFinalizationPortTests.swift
git commit -m "feat(A4): settings.total_capital 权威化（finalize 原子写 + startingCapital 直读 DB + reset 保留记录）"
```

---

### Task 4: A4 迁移 0005 — 单键 total_capital 回填（user_version 2→3）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift`（`makeMigrator()` 末尾注册 `0005`）
- Modify: `ios/sql/app_schema_v1.sql`（baseline `PRAGMA user_version` 注释同步说明，无结构变更）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDB0005MigrationTests.swift`（新建）

**Interfaces:**
- Consumes: `DatabaseMigrator` 注册范式（同 `0004`）；**裸临时 URL + partial-migrator** 升级路径范式（同 `AppDBMigrationsTests` 的 `test_0004_upgrade_*`）；`makeFreshDB` 仅用于 fresh-install 终态断言。
- Produces: 升级后 `settings.total_capital` = 末条 `training_records`(total_capital+profit)（`created_at DESC, id DESC`）。

- [ ] **Step 1: 写失败测试**（新建 `AppDB0005MigrationTests.swift`，沿用 `AppDBMigrationsTests` 的 partial-migrator 升级范式）

```swift
import XCTest
import GRDB
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

final class AppDB0005MigrationTests: XCTestCase {
    // codex R-plan-2-2：setUp 建**裸临时 URL**（不跑任何 migrator），升级测试才能从真 pre-0005 起。
    private var dbURL: URL!
    override func setUp() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appdb-0005-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("app.sqlite")   // 裸文件，无 migrator
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

    // fresh-install 终态：单独用 makeFreshDB（跑完整 migrator）断言 user_version=3
    func test_fresh_install_full_migrator_user_version_3() throws {
        let freshURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: freshURL.deletingLastPathComponent()) }
        let q = try AppDBFixture.openRaw(at: freshURL)
        let v: Int = try q.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        XCTAssertEqual(v, 3)
    }

    func test_0005_backfills_total_capital_from_last_record_and_keeps_other_keys() throws {
        let q = try DatabaseQueue(path: dbURL.path)   // 裸库
        try Self.migrateTo0004(q)                     // partial：仅 0001/0003/0004 → user_version 2
        XCTAssertEqual(try q.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }, 2)  // 0005 未应用（真 pre-0005）
        try q.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('commission_rate','0.0003')")
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('min_commission_enabled','true')")
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('display_mode','dark')")
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('total_capital','100000.0')")
            // 2 条记录，同 created_at，id 大者 total+profit=130000
            try Self.insertRecord(db, createdAt: 1000, total: 100_000, profit: 20_000)   // id=1
            try Self.insertRecord(db, createdAt: 1000, total: 120_000, profit: 10_000)   // id=2 → 130000 胜
        }
        try AppDBMigrations.makeMigrator().migrate(q)   // 完整 migrator：0005 在此真跑
        XCTAssertEqual(try q.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }, 3)
        let s = try q.read { db -> [String:String] in
            var d: [String:String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT key,value FROM settings") { d[r["key"]] = r["value"] }
            return d
        }
        XCTAssertEqual(Double(s["total_capital"]!)!, 130_000, accuracy: 1e-6)   // tie-break id DESC
        XCTAssertEqual(s["commission_rate"], "0.0003")          // 其它键不变
        XCTAssertEqual(s["min_commission_enabled"], "true")
        XCTAssertEqual(s["display_mode"], "dark")
    }

    func test_0005_no_records_leaves_capital_unchanged() throws {
        let q = try DatabaseQueue(path: dbURL.path)
        try Self.migrateTo0004(q)
        try q.write { db in try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('total_capital','100000.0')") }
        try AppDBMigrations.makeMigrator().migrate(q)
        let cap = try q.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='total_capital'") }
        XCTAssertEqual(Double(cap!)!, 100_000, accuracy: 1e-6)   // 无记录不动
    }

    // codex R-plan-8-2：legacy 记录派生值溢出/非有限 → 0005 跳过写（保留默认）+ user_version=3，
    //   后续 loadSettings 不判 dbCorrupted（资金仍合法）。
    func test_0005_skips_write_on_non_finite_derived_capital() throws {
        let q = try DatabaseQueue(path: dbURL.path)
        try Self.migrateTo0004(q)
        try q.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('total_capital','100000.0')")
            // total_capital + profit 溢出为 +inf（两个接近 Double.greatestFiniteMagnitude 的有限值）
            try Self.insertRecord(db, createdAt: 1000, total: .greatestFiniteMagnitude, profit: .greatestFiniteMagnitude)
        }
        try AppDBMigrations.makeMigrator().migrate(q)
        XCTAssertEqual(try q.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }, 3)   // 仍推进
        let cap = try q.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='total_capital'") }
        XCTAssertEqual(Double(cap!)!, 100_000, accuracy: 1e-6)   // 非有限派生 → 不写，保留默认（合法）
    }
    // codex R-plan-16-1：legacy 负 total_capital + 无记录 → 迁移清为默认（避免升级后 loadSettings 拒负 brick）。
    func test_0005_cleans_legacy_negative_capital_no_records() throws {
        let q = try DatabaseQueue(path: dbURL.path)
        try Self.migrateTo0004(q)
        try q.write { db in try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('total_capital','-1.0')") }
        try AppDBMigrations.makeMigrator().migrate(q)
        let cap = try q.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='total_capital'") }
        XCTAssertEqual(Double(cap!)!, 100_000, accuracy: 1e-6)   // 负值已清为默认 10万（非负）
        // 迁移后 loadSettings 不再因负值抛 .dbCorrupted（开局不 brick）
        XCTAssertNoThrow(try DefaultAppDB(dbPath: dbURL).loadSettings())
    }
    // codex R-plan-19-1：legacy 负 commission_rate 升级前 → 迁移清为默认 → loadSettings 不 brick（与 capital 对称）。
    func test_0005_cleans_legacy_negative_commission_rate() throws {
        let q = try DatabaseQueue(path: dbURL.path)
        try Self.migrateTo0004(q)
        try q.write { db in try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('commission_rate','-0.1')") }
        try AppDBMigrations.makeMigrator().migrate(q)
        let rate = try q.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='commission_rate'") }
        XCTAssertEqual(Double(rate!)!, 0.0001, accuracy: 1e-9)   // 负费率已清为默认 0.0001
        XCTAssertNoThrow(try DefaultAppDB(dbPath: dbURL).loadSettings())   // 升级后开局不 brick
    }

    // helpers：migrateTo0004(_:) 注册 0001/0003/0004（**与 AppDBMigrations 同 id 同体**，含 0001 用
    //   `AppDBMigrations.v1_4_baselineDDL`），跑 partial migration → grdb_migrations 标记三者 applied，
    //   后续完整 migrator 跳过它们只跑 0005（同 AppDBMigrationsTests test_0004_upgrade_* 范式）。
    //   insertRecord 插一条最小合法 training_records 行（列清单照搬 AppDBMigrationsTests / DefaultRecordRepositoryTests）。
    // （实现时照搬 AppDBMigrationsTests 的 partial-migrator 与 training_records insert 列清单。）
}
```

- [ ] **Step 2: 跑确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter AppDB0005MigrationTests`
Expected: FAIL（user_version 仍 2；total_capital 仍 100000，未回填）。

- [ ] **Step 3: 实现 0005**（在 `makeMigrator()` 的 `return migrator` 之前追加）

> **codex R-plan-18-3**：`AppDBMigrations.swift` 现仅 `import Foundation`/`GRDB`，下方片段用 `AppSettings.defaultTotalCapital` → 须在该文件加 **`import KlineTrainerContracts`**（Persistence 已依赖 Contracts，无循环；用单一来源常量而非硬编码 10万 magic number）。

```swift
        // 0005：RFC-A A4 资金权威化数据迁移（user_version 2→3）。
        // 仅 key='total_capital' 单键回填 = 末条记录(total_capital+profit)，排序对齐 statistics()
        // (created_at DESC, id DESC) 防同时间戳非确定性。无记录则不动（保留默认 10 万）。
        // 禁止无 WHERE 的 UPDATE settings（会覆盖 commission/主题等所有键 → DB 判损）。
        migrator.registerMigration("0005_v1.7_capital_authoritative") { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT total_capital, profit FROM training_records
                ORDER BY created_at DESC, id DESC LIMIT 1
                """) {
                let tc: Double = row["total_capital"]
                let p: Double = row["profit"]
                // codex R-plan-8-2：非有限（溢出）跳过写、保留默认（否则 loadSettings 判 .dbCorrupted + 版本号挡重试）。
                // codex R-plan-13-1：负派生值 floor 到 0（与 finalize 同口径，权威资金不得为负）。
                if (tc + p).isFinite {
                    let authoritative = max(0, tc + p)
                    try db.execute(sql:
                        "INSERT OR REPLACE INTO settings(key, value) VALUES ('total_capital', ?)",
                        arguments: [String(authoritative)])
                }
            }
            // codex R-plan-16-1/19-1：清理 legacy 腐坏的非负 settings 键（负/非有限/畸形）为安全默认（无记录也清）——
            // 否则升级后 loadSettings 的「拒负/拒畸形 fail-closed」会让老用户开局即 .dbCorrupted brick。
            // **total_capital 与 commission_rate 都是非负量、parseDouble 都已拒负 → 两键对称清理**。
            // 缺失 → 不写（loadSettings 缺键默认）；合法非负有限 → 不动；其余（负/非有限/非数字）→ 写默认。
            func cleanNonNegativeSettingKey(_ key: String, default def: Double) throws {
                guard let txt = try String.fetchOne(db, sql:
                    "SELECT value FROM settings WHERE key = ?", arguments: [key]) else { return }
                if let v = Double(txt), v.isFinite, v >= 0 { return }   // 合法 → 不动
                try db.execute(sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                               arguments: [key, String(def)])
            }
            try cleanNonNegativeSettingKey("total_capital", default: AppSettings.defaultTotalCapital)
            try cleanNonNegativeSettingKey("commission_rate", default: AppSettings.default.commissionRate)
            try db.execute(sql: "PRAGMA user_version = 3")
        }
```

同步 `ios/sql/app_schema_v1.sql` 顶部注释：标注「runtime user_version 终态由 migrator 推进至 3（0005 资金权威化，无结构变更）」（baseline DDL 的 `PRAGMA user_version = 1` 不改）。

- [ ] **Step 4: 跑确认通过**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter AppDB0005MigrationTests` → PASS
Run: `swift test --filter AppDBMigrationsTests`（确认现有 0004 测试若断言「终态 user_version==2」需更新为 3——若有，在本任务同步改并在 commit 说明）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift ios/sql/app_schema_v1.sql ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDB0005MigrationTests.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift
git commit -m "feat(A4): migration 0005 单键 total_capital 回填（user_version 2→3，排序对齐 statistics）"
```

---

### Task 5: D6 — 当前资金显示消费者统一读权威字段

> codex R-plan-4-1：`HomeContent.swift:51` 现为 `let capitalToShow = statistics.totalCount == 0 ? configuredCapital : statistics.currentCapital` —— **totalCount>0 时显派生 `statistics.currentCapital`**。reset 保留记录后末条记录仍驱动派生值 → 主页显**陈旧**资金。必须改为恒用权威 `configuredCapital`（AppRouter 已传 `settings.settings.totalCapital` 活缓存，Task 3 已 finalize/reset 刷新）。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift`（`capitalToShow` 恒用权威 `configuredCapital`，删 `totalCount>0 ? statistics.currentCapital` 派生分支）。
- Modify（R-plan-7-1 reset 后重建 homeContent）：`ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift`（加 `resetAllProgressAndReload()` = `resetAllProgress()` + `loadHome()`）+ `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift`（reset 确认动作改调路由的 reset-and-reload，经注入闭包）。
- Modify（R-plan-7-2 文案）：`ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift`（reset 三串文案改为「保留记录 + 资金回 10 万 + 仅清未完成局」）。
- Test: `HomeContentTests.swift`（HomeContent 恒权威）+ AppRouter 测（reset-and-reload 后 `homeContent.totalCapital == "¥ 100,000.00"` 且记录保留）+ `SettingsPanelContentTests`（文案断言）。
- 审计：`grep -rn "statistics()\.currentCapital\|\.currentCapital" ios/Contracts/Sources` 确认 **HomeContent 是唯一资金显示消费者**（其余 `currentCapital` 出现处 = `statistics()` 定义 / `startingCapital` 已 Task 3 改走 / 本测试）。

**Interfaces:**
- Consumes: AppRouter 注入的 `configuredCapital = settings.settings.totalCapital`（权威活缓存，Task 3 已 finalize/reset 刷新）。
- Produces: 主页当前资金恒 = 权威 `settings.total_capital`（reset 后显 10 万、finalize 后显新值，均不被末条记录派生值污染）。

- [ ] **Step 1: 写失败测试**（沿用 `HomeContentTests` 范式）

```swift
@Test("totalCount>0 时当前资金用权威 configuredCapital，非派生 currentCapital")
func capitalUsesAuthoritative() {
    let c = HomeContent(statistics: (totalCount: 3, winCount: 1, currentCapital: 999_999),
                        configuredCapital: 100_000, records: [],
                        hasPending: false, hasCachedSets: false)
    #expect(c.totalCapital == "¥ 100,000.00")   // 权威 settings 值，非派生 999_999
}
```

（确认 `formatCapital` 输出格式，校准断言字符串。）

- [ ] **Step 2: 跑确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter HomeContent`
Expected: FAIL（现逻辑 totalCount=3 → 取 `statistics.currentCapital`=999_999）。

- [ ] **Step 3: 实现**（`HomeContent.swift:51-52`）

```swift
        // RFC-A D6（codex R-plan-4-1）：当前资金恒用权威 settings.total_capital（经 configuredCapital 注入，
        // 活缓存已 finalize/reset 刷新）；不再用 statistics.currentCapital 派生（reset 保留记录后派生值会陈旧）。
        self.totalCapital = Self.formatCapital(configuredCapital)
```

（`statistics.currentCapital` 不再驱动资金显示；`statistics` 仍供局数/胜率。审计确认无其它资金显示消费者。）

- [ ] **Step 4: 跑确认通过**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter HomeContent` → PASS

- [ ] **Step 5: reset 后重建 homeContent（R-plan-7-1）**

> `SettingsPanel:100` 现直接 `try await settings.resetAllProgress()`，不重建 `router.homeContent` → reset 后主页仍显旧资金直到 reload/重启。改为路由中介：reset 后立即 `loadHome()` 重建。

`AppRouter` 加（`settings`/`loadHome` 均已在 AppRouter）：

```swift
    public func resetAllProgressAndReload() async throws {
        try await settings.resetAllProgress()   // Task3：去 deleteAll(保留记录) + 置 10 万 + 刷活缓存
        await loadHome()                         // 用新 settings.totalCapital 重建 homeContent
    }
```

`SettingsPanel` reset 确认动作（:100）由直接 `settings.resetAllProgress()` 改调路由 `resetAllProgressAndReload()`（经注入闭包 `onConfirmReset: () async throws -> Void`，在 SettingsPanel 实例化处接 `router.resetAllProgressAndReload`；按现成注入范式接线）。

测试（AppRouter，沿用现成 router+AppDB+SettingsStore 构造范式）：
```swift
func test_reset_and_reload_home_shows_100k_and_keeps_records() async throws {
    // …先入 N 条记录（末条派生资金 ≠ 10 万）…
    try await router.resetAllProgressAndReload()
    XCTAssertEqual(router.homeContent.totalCapital, "¥ 100,000.00")   // 主页即时显 10 万权威
    XCTAssertEqual(try appDB.statistics().totalCount, N)              // 记录保留
}
```

- [ ] **Step 6: reset 文案改非破坏性（R-plan-7-2）**

`SettingsPanelContent.swift:42-44` 三串（现说「清空记录/删除全部/不可撤销」，与保留记录新行为矛盾）改为：

```swift
    public static let resetButtonLabel = "重置资金（→ ¥100,000，保留记录）"
    public static let resetConfirmTitle = "确认重置资金？"
    public static let resetConfirmMessage = "资金恢复为 ¥100,000，并清除当前未完成的对局；历史训练记录保留。"
```

测试（`SettingsPanelContentTests`）：断言三串含「保留」「¥100,000」、**不含**「删除全部 / 清空记录 / 不可撤销」（负向断言用 `if …{ … }` 非 `! grep`；`#expect(!str.contains(...))`）。

- [ ] **Step 7: 跑确认通过 + 提交**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter "HomeContent|AppRouter|SettingsPanelContent"` → PASS

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift ios/Contracts/Tests/KlineTrainerContractsTests/
git commit -m "feat(A4/D6): 主页资金恒权威 + reset 路由重建 homeContent + reset 文案改非破坏性"
```

---

### Task 6: A3 顶栏「浮动盈亏」改持仓未实现盈亏（host 测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift`（init 加 `currentPrice`；新增 `holdingPnL` 计算，标签仍「浮动盈亏」）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（topBar 调用点传 `currentPrice: engine.currentPrice`；第 5 格 bind 改 `bar.holdingPnL`——实现时 grep topBar render 找到现 `bar.returnRate` bind 行替换）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift`（追加 holdingPnL 用例）

**Interfaces:**
- Consumes: `engine.currentPrice`、`position.averageCost`、`position.shares`。
- Produces: `TrainingTopBarContent(totalCapital:averageCost:shares:returnRate:positionTier:stockName:stockCode:currentPrice:)` + `holdingPnL: String`。

- [ ] **Step 1: 写失败测试**

```swift
@Test("持仓>0：浮动盈亏 = (现价-成本)*股数，元+%")
func holdingPnLPositive() {
    let c = TrainingTopBarContent(totalCapital: 100_000, averageCost: 10, shares: 1000,
                                  returnRate: 0.05, positionTier: 1,
                                  stockName: nil, stockCode: nil, currentPrice: 12)
    // (12-10)*1000 = +2000；(12-10)/10 = +20.00%
    #expect(c.holdingPnL == "+¥ 2,000.00 (+20.00%)")
}
@Test("持仓=0：浮动盈亏 +¥ 0.00 (+0.00%)")
func holdingPnLZero() {
    let c = TrainingTopBarContent(totalCapital: 100_000, averageCost: 0, shares: 0,
                                  returnRate: 0, positionTier: 0,
                                  stockName: nil, stockCode: nil, currentPrice: 12)
    #expect(c.holdingPnL == "+¥ 0.00 (+0.00%)")
}
@Test("亏损：负号 + 负%")
func holdingPnLNegative() {
    let c = TrainingTopBarContent(totalCapital: 100_000, averageCost: 10, shares: 1000,
                                  returnRate: -0.1, positionTier: 1,
                                  stockName: nil, stockCode: nil, currentPrice: 9)
    #expect(c.holdingPnL == "-¥ 1,000.00 (-10.00%)")
}
```

（确认现有 `TrainingTopBarContentTests` 文件路径与 `@Suite` 名后追加；¥ 口径 = `¥ ` + 千分位 + 2 位小数，同 `currency()`。）

- [ ] **Step 2: 跑确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter TrainingTopBarContent`
Expected: 编译失败（init 无 `currentPrice` / 无 `holdingPnL`）。

- [ ] **Step 3: 实现**（改 `TrainingTopBarContent`：加字段、init 参数、计算 + 格式化）

在 struct 加 `public let holdingPnL: String`；init 末尾加参数 `currentPrice: Double` 并计算：

```swift
        // RFC-A A3：持仓浮动盈亏（元 + %）= (现价 − 每股成本) × 股数。
        if shares > 0 && averageCost > 0 {
            let amount = (currentPrice - averageCost) * Double(shares)
            let pct = (currentPrice - averageCost) / averageCost
            self.holdingPnL = "\(Self.signedCurrency(amount)) (\(Self.percent(pct)))"
        } else {
            self.holdingPnL = "\(Self.signedCurrency(0)) (\(Self.percent(0)))"
        }
```

加私有格式化（带符号货币，复用 `percent` 的 ±0 归一）：

```swift
    /// 带符号 `+¥ 1,234.56` / `-¥ 1,234.56`（±0 归一为 `+`）。
    private static func signedCurrency(_ value: Double) -> String {
        let v = (value == 0) ? 0.0 : value
        let sign = v >= 0 ? "+" : "-"
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal; f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.decimalSeparator = "."; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        let body = f.string(from: NSNumber(value: abs(v))) ?? String(format: "%.2f", abs(v))
        return "\(sign)¥ \(body)"
    }
```

（`percent` 已存在，输出如 `+20.00%`。）

- [ ] **Step 4: 改 `TrainingView` 调用点 + bind**

`topBar`（line 184-189）`TrainingTopBarContent(...)` 末尾加 `, currentPrice: engine.currentPrice)`。然后 grep `topBar` render 里第 5 格的 `bar.returnRate` bind，改成 `bar.holdingPnL`（标签文案保持「浮动盈亏」）。

- [ ] **Step 5: 跑确认通过 + 提交**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter TrainingTopBarContent` → PASS

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift
git commit -m "feat(A3): 顶栏浮动盈亏改持仓未实现盈亏（元+%）"
```

---

### Task 7: A2 TradeBoxContent 纯值（host 测）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxContent.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeBoxContentTests.swift`

**Interfaces:**
- Consumes: `TradeAction`（现有，TradeBarContent.swift）、`TradeCalculator.maxBuyableShares`/`sharesForBuyTier`/`sharesForSellTier`/`quoteBuy`/`quoteSell`/`shareLotSize`、`FeeSnapshot`、`PositionTier`。
- Produces（Task 8 依赖）: `TradeBoxContent` —— 给定 (action, price, cash, holding, fees, qty) 输出可买/可卖/预估/各档填入/确认使能。

- [ ] **Step 1: 写失败测试**（沿用 `TradeBarContentTests` 的 `import Testing` + `@Suite`/`@Test` 范式）

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TradeBoxContent")
struct TradeBoxContentTests {
    private let noMin = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false)

    @Test("buy: 可买上限 + 预估 + 标题红")
    func buy() {
        let c = TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0,
                                fees: noMin, qty: 2000)
        #expect(c.limitShares == 9900)                 // maxBuyable(100000,10)=9900
        #expect(c.limitLabel == "可买 9,900 股")
        #expect(c.estimateLabel == "预估 ¥ 20,002")    // totalCost 2000*10+2
        #expect(c.confirmLabel == "买入 2,000 股")
        #expect(c.confirmEnabled == true)
    }
    @Test("sell: 可卖=持仓 + 清仓奇数股")
    func sell() {
        let c = TradeBoxContent(action: .sell, price: 20, cash: 0, holding: 150,
                                fees: noMin, qty: 150)
        #expect(c.limitShares == 150)
        #expect(c.limitLabel == "可卖 150 股")
        #expect(c.confirmLabel == "卖出 150 股")
        #expect(c.confirmEnabled == true)               // 清仓放行奇数
    }
    @Test("R-plan-14-1：UI 与 engine 同源——净负卖出框禁用、预估占位")
    func sellNegativeProceedsDisabled() {
        let withMin = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        // 100 股 ×0.01=1，免5 → proceeds≈-4，cash=0 → quoteSell(cash:) 失败 → confirmEnabled false / 预估占位
        let c = TradeBoxContent(action: .sell, price: 0.01, cash: 0, holding: 100, fees: withMin, qty: 100)
        #expect(c.confirmEnabled == false)
        #expect(c.estimateLabel == "预估 —")
    }
    @Test("R-plan-14-1：极端价输出非有限 → 卖出框禁用（不格式化非有限）")
    func sellNonFiniteDisabled() {
        let c = TradeBoxContent(action: .sell, price: .greatestFiniteMagnitude, cash: 1e300,
                                holding: 1_000_000, fees: noMin, qty: 1_000_000)
        #expect(c.confirmEnabled == false)
        #expect(c.estimateLabel == "预估 —")
    }
    @Test("非整手买入 250 → effectiveShares 200，显示==提交，使能")
    func buyNonLotNormalizes() {
        let c = TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0, fees: noMin, qty: 250)
        #expect(c.effectiveShares == 200)
        #expect(c.confirmLabel == "买入 200 股")        // 显示=提交（不再 250 显示/200 提交）
        #expect(c.confirmEnabled == true)
    }
    @Test("部分卖非整手（holding 150 输 50）→ effectiveShares 0，禁用")
    func sellPartialOddDisabled() {
        let c = TradeBoxContent(action: .sell, price: 20, cash: 0, holding: 150, fees: noMin, qty: 50)
        #expect(c.effectiveShares == 0)                 // 50 lot-floor=0（非清仓，不放行奇数）
        #expect(c.confirmEnabled == false)
    }
    @Test("清仓 holding 150 输 150 → effectiveShares 150，放行，显示==提交")
    func sellClearOddEnabled() {
        let c = TradeBoxContent(action: .sell, price: 20, cash: 0, holding: 150, fees: noMin, qty: 150)
        #expect(c.effectiveShares == 150)               // 清仓例外
        #expect(c.confirmLabel == "卖出 150 股")
        #expect(c.confirmEnabled == true)
    }
    @Test("qty=0 / 超限 → effectiveShares 受限、确认禁用或 clamp")
    func disabledAndClamp() {
        #expect(TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0,
                                fees: noMin, qty: 0).confirmEnabled == false)
        // 超可买：effectiveShares clamp 到 limit(9900)，仍是合法可买量 → 使能且显示 clamp 后值
        let over = TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0, fees: noMin, qty: 100_000)
        #expect(over.effectiveShares == 9900)
        #expect(over.confirmLabel == "买入 9,900 股")
        #expect(over.confirmEnabled == true)
    }
    @Test("快捷档填入股数：买 1/5/全仓；卖 1/5/清仓")
    func tierFills() {
        let b = TradeBoxContent(action: .buy, price: 10, cash: 100_000, holding: 0, fees: noMin, qty: 0)
        #expect(b.fillShares(.tier1) == 2000)
        #expect(b.fillShares(.tier5) == 9900)           // 全仓 = 可买上限
        let s = TradeBoxContent(action: .sell, price: 20, cash: 0, holding: 1000, fees: noMin, qty: 0)
        #expect(s.fillShares(.tier2) == 400)
        #expect(s.fillShares(.tier5) == 1000)           // 清仓
    }
    @Test("快捷标签：买末档=全仓 / 卖末档=清仓")
    func tierLabels() {
        #expect(TradeBoxContent(action: .buy, price: 10, cash: 1, holding: 0, fees: noMin, qty: 0)
                    .tierLabels == ["1/5","2/5","3/5","4/5","全仓"])
        #expect(TradeBoxContent(action: .sell, price: 10, cash: 0, holding: 1, fees: noMin, qty: 0)
                    .tierLabels.last == "清仓")
    }
}
```

- [ ] **Step 2: 跑确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter TradeBoxContent`
Expected: 编译失败（`TradeBoxContent` 未定义）。

- [ ] **Step 3: 实现**（新建 `TradeBoxContent.swift`）

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxContent.swift
// RFC-A A2：买卖框纯值。给定 action/price/cash/holding/fees/qty → 可买可卖/预估/各档填入/确认使能。
// 仅 import Foundation —— host 全测。TradeAction 复用 TradeBarContent.swift 定义。

import Foundation

public struct TradeBoxContent: Equatable, Sendable {
    public let action: TradeAction
    public let price: Double
    public let cash: Double
    public let holding: Int
    public let fees: FeeSnapshot
    public let qty: Int

    public init(action: TradeAction, price: Double, cash: Double, holding: Int,
                fees: FeeSnapshot, qty: Int) {
        self.action = action; self.price = price; self.cash = cash
        self.holding = holding; self.fees = fees; self.qty = qty
    }

    /// 可买（买=fee-aware 上限）/ 可卖（卖=全部持仓）。
    public var limitShares: Int {
        switch action {
        case .buy:  return TradeCalculator.maxBuyableShares(cash: cash, price: price, fees: fees)
        case .sell: return holding
        }
    }

    public var limitLabel: String {
        let n = Self.grouped(limitShares)
        return action == .buy ? "可买 \(n) 股" : "可卖 \(n) 股"
    }

    /// 唯一有效下单股数（codex R-plan-1）：预估/确认文案/使能/提交全用它，杜绝「显示≠提交」。
    /// D7 卖清仓例外：qty==holding(>0) → 原值（含奇数）；否则 lot-floor 后 clamp [0, limitShares]。
    public var effectiveShares: Int {
        if action == .sell && qty == holding && holding > 0 { return holding }
        let lot = (qty / TradeCalculator.shareLotSize) * TradeCalculator.shareLotSize
        return min(max(0, lot), limitShares)
    }

    /// 预估：买=totalCost / 卖=proceeds；用 effectiveShares 经 quote 校验，非法 → "—"。
    public var estimateLabel: String {
        let s = effectiveShares
        switch action {
        case .buy:
            if case .success(let q) = TradeCalculator.quoteBuy(cash: cash, shares: s, price: price, fees: fees) {
                return "预估 ¥ \(Self.currency(q.totalCost))"
            }
        case .sell:
            if case .success(let q) = TradeCalculator.quoteSell(cash: cash, holding: holding, shares: s, price: price, fees: fees) {
                return "预估 ¥ \(Self.currency(q.proceeds))"
            }
        }
        return "预估 —"
    }

    /// 确认使能 = effectiveShares 经 quote 精确校验成功（非仅 ≤limit；非整手/0 → 禁用）。
    public var confirmEnabled: Bool {
        let s = effectiveShares
        guard s > 0 else { return false }
        switch action {
        case .buy:
            if case .success = TradeCalculator.quoteBuy(cash: cash, shares: s, price: price, fees: fees) { return true }
        case .sell:
            if case .success = TradeCalculator.quoteSell(cash: cash, holding: holding, shares: s, price: price, fees: fees) { return true }
        }
        return false
    }

    /// 确认文案 = effectiveShares（与提交一致）。
    public var confirmLabel: String {
        let verb = action == .buy ? "买入" : "卖出"
        return "\(verb) \(Self.grouped(effectiveShares)) 股"
    }

    /// 比例快捷填入股数（点击后填入数量框）。
    public func fillShares(_ tier: PositionTier) -> Int {
        switch action {
        case .buy:  return TradeCalculator.sharesForBuyTier(cash: cash, price: price, tier: tier, fees: fees)
        case .sell: return TradeCalculator.sharesForSellTier(holding: holding, tier: tier)
        }
    }

    /// 5 档标签：1/5..4/5 + 末档（买=全仓 / 卖=清仓）。
    public var tierLabels: [String] {
        PositionTier.allCases.map { tier in
            tier == .tier5 ? (action == .buy ? "全仓" : "清仓") : tier.rawValue
        }
    }

    private static func grouped(_ v: Int) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal; f.usesGroupingSeparator = true; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    private static func currency(_ v: Double) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal; f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.minimumFractionDigits = 0; f.maximumFractionDigits = 0   // 预估取整元，避免小数噪声
        return f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v.rounded()))"
    }
}
```

- [ ] **Step 4: 跑确认通过 + 提交**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter TradeBoxContent` → PASS
（若 `estimateLabel` 的 `20,002` 与 formatter 0 位小数不符，按实际 formatter 输出校准断言——`totalCost=20002` 整数 → `20,002`。）

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxContent.swift ios/Contracts/Tests/KlineTrainerContractsTests/UI/TradeBoxContentTests.swift
git commit -m "feat(A2): TradeBoxContent 纯值（可买可卖/预估/快捷填入/确认使能）"
```

---

### Task 8: A2 TradeBoxView + 接入 TrainingView（UI 切到按股数）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxView.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（overlay 换 `TradeBoxView`；`performTrade` 改 shares；保留防漂移守卫）

**Interfaces:**
- Consumes: `TradeBoxContent`（Task 7）、`engine.buy/sell(panel:shares:)`（Task 2）、现有 `tradeStrip`/`TradeStripRequest`/`tradeStripStillValid`/`TradeFeedback`/`engine.cashBalance`/`position.shares`/`engine.currentPrice`/`engine.fees`。
- Produces: 点买卖 → active 图底部弹数量框；确认前 `tradeStripStillValid` 守卫；红框/anchor 不变。

- [ ] **Step 1: 实现 `TradeBoxView`**（SwiftUI 薄壳；UI 壳本仓不写 host 单元测，靠 Catalyst build + §11 验收。沿用 `TradeBarView` 平台无关 + `@escaping` 范式）

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxView.swift
// RFC-A A2：买卖框（方案 D）。数量框 + −/＋(±100) + 比例快捷填入 + 可买可卖 + 预估 + 右上✕ + 全宽确认。
// 弹出位置/红框由 caller(TrainingView) 的 active-panel overlay 决定（沿用 RFC-B 机制）。

import SwiftUI

public struct TradeBoxView: View {
    private let content: TradeBoxContent
    @State private var qty: Int
    private let onConfirm: (Int) -> Void
    private let onCancel: () -> Void

    public init(action: TradeAction, price: Double, cash: Double, holding: Int,
                fees: FeeSnapshot, initialQty: Int,
                onConfirm: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self._qty = State(initialValue: initialQty)
        self.content = TradeBoxContent(action: action, price: price, cash: cash,
                                       holding: holding, fees: fees, qty: initialQty)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    // 用当前 qty 重算的瞬时 content（步进/填入后刷新标签）
    private var live: TradeBoxContent {
        TradeBoxContent(action: content.action, price: content.price, cash: content.cash,
                        holding: content.holding, fees: content.fees, qty: qty)
    }
    private var tint: Color { content.action == .buy ? .red : .green }

    public var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(content.action == .buy ? "买入" : "卖出").foregroundStyle(tint).bold()
                Text("现价 ¥\(String(format: "%.2f", content.price))").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(live.limitLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                Button(action: onCancel) { Image(systemName: "xmark") }.buttonStyle(.bordered)
                    .accessibilityLabel("关闭")
            }
            HStack(spacing: 8) {
                Button("−100") { qty = max(0, live.effectiveShares - TradeCalculator.shareLotSize) }
                    .buttonStyle(.bordered).accessibilityLabel("减100股")
                TextField("数量", value: $qty, format: .number)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("数量")
                    .onSubmit { qty = live.effectiveShares }   // 提交时规范化进 state → 显示==提交
                Button("+100") { qty = min(live.limitShares, live.effectiveShares + TradeCalculator.shareLotSize) }
                    .buttonStyle(.bordered).accessibilityLabel("加100股")
            }
            Text(live.estimateLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Array(zip(PositionTier.allCases, live.tierLabels)), id: \.0) { tier, label in
                    Button(label) { qty = live.fillShares(tier) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        .accessibilityLabel(label)
                }
            }
            Button(action: { onConfirm(live.effectiveShares) }) {   // 提交 = 显示的 effectiveShares（显示==提交）
                Text(live.confirmLabel).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).tint(tint).disabled(!live.confirmEnabled)
            .accessibilityLabel(live.confirmLabel)
        }
        .padding(12).background(.thinMaterial)
    }
}
```

- [ ] **Step 2: 改 `TrainingView.performTrade` 为按股数**（line 268-284）

```swift
    private func performTrade(_ action: TradeAction, panel: PanelId, shares: Int) {
        let result: Result<TradeOperation, AppError>
        switch action {
        case .buy:  result = engine.buy(panel: panel, shares: shares)
        case .sell: result = engine.sell(panel: panel, shares: shares)
        }
        if case .success = result { lifecycle.autosave(immediate: true) }
        let feedback = TradeFeedback(result: result)
        if feedback.firesHaptic { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
        if let message = feedback.toastMessage { presentToast(message) }
    }
```

- [ ] **Step 3: 改 `panel(_:)` overlay 用 `TradeBoxView`**（line 240-259，保留 `tradeStripStillValid` 守卫）

```swift
            .overlay(alignment: .bottom) {
                if showsTradeButtons, let strip = tradeStrip, strip.panel == id {
                    TradeBoxView(
                        action: strip.action, price: engine.currentPrice,
                        cash: engine.cashBalance, holding: engine.position.shares,
                        fees: engine.fees, initialQty: 0,
                        onConfirm: { shares in
                            guard tradeStripStillValid(capturedPeriod: strip.period,
                                                       currentPeriod: currentPeriod(of: id),
                                                       capturedTick: strip.tick,
                                                       currentTick: engine.tick.globalTickIndex) else {
                                tradeStrip = nil; return
                            }
                            performTrade(strip.action, panel: id, shares: shares)
                            tradeStrip = nil
                        },
                        onCancel: { tradeStrip = nil })
                }
            }
```

（红框 overlay、`onChange` 防漂移守卫、`TradeActionBar` 调用点全部**不动**。`engine.fees` 若非 public 需在 engine 暴露只读——grep 确认；现 `fees` 是 `public let`。）

- [ ] **Step 4: 删旧 `TradeBarView`/`TradeBarContent`？**

不在本任务删（Task 9 一并清理无用件）。本任务只让 overlay 不再实例化 `TradeBarView`。

- [ ] **Step 5: 构建验证 + 提交**

Run（Catalyst build-for-testing，UI 壳无 host 单测）：
`cd "/Users/maziming/Coding/Prj_Kline trainer" && xcodebuild build-for-testing -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBoxView.swift ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "feat(A2): TradeBoxView 数量框接入 TrainingView（点买卖弹框，performTrade 改 shares，防漂移守卫保留）"
```

---

### Task 9: D3 — 退役 tier-based 交易路径 + buyEnabled 改 maxBuyable

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（改 `buyEnabled`；删 `buy(panel:tier:)`/`sell(panel:tier:)`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift`（删 `quoteBuy(totalCapital:…)`/`quoteSell(holding:averageCost:tier:…)`）
- Modify: 测试迁移 —— **rg 驱动**（codex R-plan-18-1：之前硬编码的「4 处」不全，`TrainingEngineActionsTests`/`TrainingEnginePanLinkageTests`/`TrainingEngineInteractionTests` 等还有引用）：先 `rg -n "buy\(panel:.*tier|sell\(panel:.*tier|quoteBuy\(totalCapital|quoteSell\(holding:.*averageCost|quoteSell\(.*tier" ios/Contracts` 穷举**全部**引用，逐个**有意**迁移（非盲删；行为测试要换成等价 shares 语义）。

> **⚠️ 前置确认修正（R-plan-18-1）**：早期 Agent 的「仅 4 处测试」接线调查**不完整**。删 tier API 前**必须**用 rg 穷举全部调用点并逐个迁移，再过删前负向门（Step 4），否则留悬挂符号引用编译失败 + 漏迁移行为测试。tier-based `engine.buy/sell(panel:tier:)` / `quoteBuy(totalCapital:)` / tier `quoteSell` 的生产调用方 = UI（Task 8 切走）+ `buyEnabled`（本任务改）；测试调用方 = rg 全集（非硬编码）。

- [ ] **Step 1: 改 `buyEnabled`**（line 299-310）

```swift
    public var buyEnabled: Bool {
        guard flow.canBuySell() else { return false }
        // RFC-A：能买至少 1 手即使能（fee-aware）。
        return TradeCalculator.maxBuyableShares(cash: cashBalance, price: currentPrice, fees: fees)
            >= TradeCalculator.shareLotSize
    }
```

- [ ] **Step 2: 跑回归确认无破坏 + buyEnabled 负费率不崩（R-plan-6-1）**

加 engine 测：用 `commissionRate = -1` 的 `FeeSnapshot` 构造一个有现金的 Normal engine（沿用 Task 2 fixture 范式），断言 `engine.buyEnabled == false` 且**不崩**（maxBuyableShares 守卫返 0 < shareLotSize → false；证明渲染交易屏对坏费率不 trap）。
Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test`（应仍全绿——若有断言 buyEnabled 在 0 现金时 true 之类，按新语义修）。

- [ ] **Step 3: rg 驱动迁移全部 tier 引用 + 删 tier 方法（R-plan-18-1）**

3a. `TradeCalculatorTests.swift` 的 Buy/Sell 两个 tier `@Suite` 逐个迁移为按股数等价（Task 1 已加按股数覆盖；删现有 tier 测试避免引用已删方法）。保留 ForceClose suite（`forceCloseOnEnd` 不删）。
3b. **rg 穷举**所有 `engine.buy/sell(panel:tier:)` 调用点（含 `TrainingEngineActionsTests`/`TrainingEnginePanLinkageTests`/`TrainingEngineInteractionTests`/`TrainingSessionPersistenceTests`/`TrainingSessionCrossFeatureTests`/`UI/TrainingSessionLifecycleTests` 及 rg 发现的任何其它）→ **逐个有意迁移**：把 `tier:.tierN` 换成等价 `shares:`（用 `sharesForBuyTier`/`sharesForSellTier` 算等价股数，**保留该测试原本校验的行为语义**，不盲删）。
3c. 删 `TradeCalculator.swift` 的 `quoteBuy(totalCapital:cash:tier:price:fees:)` 与 `quoteSell(holding:averageCost:tier:price:fees:)`（旧冻结 tier 报价）。
3d. 删 `TrainingEngine.swift` 的 `buy(panel:tier:)` 与 `sell(panel:tier:)`。

- [ ] **Step 4: 删前负向门 + 跑确认全绿（R-plan-18-1）**

**删除 API 前**先过负向 grep 门（确认无残留引用，沿用 [[feedback_acceptance_grep_anchoring]] 的 `if … exit 1` 范式，非 `! grep`）：
```bash
if rg -n "buy\(panel:.*tier|sell\(panel:.*tier|quoteBuy\(totalCapital|quoteSell\(holding:.*averageCost" ios/Contracts; then
  echo "残留 tier API 引用，先迁移完再删"; exit 1
fi
```
Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test`
Expected: 全 PASS，且编译通过（无悬挂符号 = 负向门 + 编译双证）。

- [ ] **Step 5: 删无用 UI 件 + 提交**

确认 `TradeBarView`/`TradeBarContent` 已无引用（`grep -rn "TradeBarView\|TradeBarContent" ios/Contracts/Sources` 仅剩自身定义 + 测试）→ 删 `TradeBarView.swift`、`TradeBarContent.swift`（保留 `TradeAction` —— 移到 `TradeBoxContent.swift` 或保留在某处；grep 确认 `TradeAction` 使用点后定其归宿）及对应 `TradeBarContentTests.swift`。

```bash
git add -A && git commit -m "refactor(D3): 退役 tier-based 交易路径（buyEnabled 改 maxBuyable，删 quoteBuy(totalCapital)/engine.buy(tier)，迁移 tier 测试）"
```

---

### Task 10: D8 — bump CONTRACT_VERSION 1.6→1.7 + m01 记录

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift`（line 7）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift`（line 5-10）
- Modify: `docs/governance/m01-schema-versioning-contract.md`（加 bump 记录 → **触发 CODEOWNERS approve**）

- [ ] **Step 1: 改测试断言为 1.7（失败先行）**

```swift
@Suite("Contract version")
struct ContractVersionTests {
    @Test func contractVersionIs1_7() {
        #expect(CONTRACT_VERSION == "1.7")
    }
}
```

- [ ] **Step 2: 跑确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter ContractVersionTests`
Expected: FAIL（常量仍 "1.6"）。

- [ ] **Step 3: bump 常量 + m01 记录**

`Models.swift` line 7：`public let CONTRACT_VERSION = "1.7"`。
`m01-schema-versioning-contract.md` §bump 记录 增一条：

```markdown
> **bump 记录（2026-06-22，RFC-A 顺位 3）**：顶层 `CONTRACT_VERSION` `"1.6"` → `"1.7"`。触发 = A 类「改既有语义」：`settings.total_capital` 语义从「配置起始本金」改为「权威滚动当前资金」+ reset 改为保留记录 + migration `0005`（app.sqlite DML 数据 migration，user_version 2→3）。无表结构变更（settings KV 键已存在）。同 E2 1.4→1.5「reader 侧改既有语义」先例。详见 `docs/superpowers/specs/2026-06-22-trade-position-capital-design.md` §11。
```

同步矩阵表 `CONTRACT_VERSION` 当前版本 cell `"1.5"`→`"1.7"`（注：m01 矩阵 cell 当前 stale 为 "1.5"，本次校正到 "1.7"，并在记录里说明 1.5→1.6 的历史 bump 由前序 PR 落地）。

- [ ] **Step 4: 跑确认通过**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter ContractVersionTests` → PASS

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift docs/governance/m01-schema-versioning-contract.md
git commit -m "chore(D8): bump CONTRACT_VERSION 1.6→1.7（m01 A类改既有语义）+ m01 bump 记录"
```

---

### Task 11: 验收（host 全绿 + Catalyst + app build）+ 整体 review 准备

**Files:** 无生产改动（验证 + acceptance doc）

- [ ] **Step 1: host 全量**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test 2>&1 | tail -15`
Expected: 全 PASS，0 failures。

- [ ] **Step 2: Mac Catalyst build-for-testing**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer" && xcodebuild build-for-testing -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`

- [ ] **Step 3: iOS app build**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer" && xcodebuild build -scheme KlineTrainer -destination 'platform=iOS Simulator,id=DE0BA39D-C749-459D-A407-4418599B61CA' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 写 acceptance 清单**

按 spec §10 的 12 条，落到 `docs/superpowers/acceptance/` 下 RFC-A 验收 md（action/expected/pass-fail，中文，二值可判）。

- [ ] **Step 5: 提交 + 整体 codex review 准备**

```bash
git add -A && git commit -m "test(A): RFC-A 验收清单 + 三绿验证"
```

整体 branch-diff codex review：`.claude/scripts/codex-attest.sh --scope branch-diff --head feat/trade-position-capital --base main`，收敛到 approve。

---

## Self-Review（plan 对 spec 覆盖核对）

- **A1 股数化**：Task 1（计算器按股数+helpers+D7）+ Task 2（引擎 shares 入口+D4）+ Task 9（D3 退役 tier + buyEnabled）✓
- **A2 买卖框**：Task 7（TradeBoxContent）+ Task 8（TradeBoxView+接线，沿用 active-panel overlay+防漂移）✓
- **A3 持仓盈亏**：Task 6 ✓
- **A4 资金**：Task 3（finalize 写/startingCapital 直读/reset 保留）+ Task 4（migration 0005 单键+排序）+ Task 5（D6 消费者）✓
- **D7 清仓奇数股**：Task 1（quoteSell）+ Task 7（confirmEnabled）+ Task 8（normalizedQty 放行）✓
- **D8 bump 1.6→1.7 + m01 + CODEOWNERS**：Task 10 ✓
- **不做项**（#10 replay 续局 / per-period 取价）：plan 无任务 = 正确不实现 ✓
- **验收 §10 12 条**：Task 11 ✓
- **xcscheme（无关变更）**：plan 不纳入任何提交 ✓（独立提请 user 处理）

> 风险（执行时注意）：Task 3 `finalizeSession` **改返回类型** `(id,totalCapital)` → 所有 conformer（含 fake）同步（编译报错指明）；资金从持久记录派生（retry 幂等，R-plan-2-1）、随成功返回（无 fallible 后置读，R-plan-4-2）、coordinator 用返回值刷缓存（缓存恒==DB 权威，R-plan-5-1）。Task 5 HomeContent 恒用权威 configuredCapital（R-plan-4-1）。Task 9 删冻结契约方法须 Task 8 先完成 UI 迁移。
