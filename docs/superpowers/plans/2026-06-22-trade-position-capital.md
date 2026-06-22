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
- `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` — `startingCapital()` 直读 DB（`finalize()` 调用点不变）（Task 3）。
- `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift` — `finalizeSession` 事务内**从持久记录派生** `setTotalCapital`（签名不变，retry 幂等）；`resetAllTrainingProgress` 去 `deleteAll`（Task 3）。
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift` — 加 `0005`（Task 4）。
- `ios/sql/app_schema_v1.sql` — `PRAGMA user_version` baseline 注释同步（Task 4，无结构变更）。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` — `performTrade` 改 shares + overlay 换 `TradeBoxView` + topBar 传 currentPrice（Task 8）。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift` — 浮动盈亏改持仓 PnL（Task 6）。
- `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` + `ModelsTests.swift` — bump 1.7（Task 10）。
- `docs/governance/m01-schema-versioning-contract.md` — bump 记录（Task 10，触发 CODEOWNERS）。
- 「当前资金」显示消费者（Task 5 审计后定）。

**任务依赖序**：1（计算器加法）→ 2（引擎加法）→ 3（资金读写）→ 4（迁移）→ 5（D6 消费者）→ 6（A3 PnL）→ 7（A2 框纯值）→ 8（A2 框壳 + UI 接线，UI 切到 shares）→ 9（D3 删 tier，须在 8 之后）→ 10（bump）→ 11（验收）。

---

### Task 1: TradeCalculator 按股数 API + helpers（纯函数，host 测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift`（在 `enum TradeCalculator` 内、现有方法之后追加；现有 tier 方法本任务**不动**）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift`（追加 3 个新 `@Suite`）

**Interfaces:**
- Consumes: 现有 `BuyQuote`/`SellQuote`（字段不变）、`TradeReason`、`FeeSnapshot`、`shareLotSize`、`robustFloor`、`computeCommission`、`makeSellQuote`、`ratio(of:)`、`PositionTier`。
- Produces（Task 2/7/9 依赖这些精确签名）:
  - `static func quoteBuy(cash: Double, shares: Int, price: Double, fees: FeeSnapshot) -> Result<BuyQuote, TradeReason>`
  - `static func quoteSell(holding: Int, shares: Int, price: Double, fees: FeeSnapshot) -> Result<SellQuote, TradeReason>`
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
        let r = TradeCalculator.quoteSell(holding: 1000, shares: 400, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(q.shares == 400)
        #expect(approx(q.notional, 8_000))
        #expect(approx(q.commission, 0.8))      // 8000*0.0001
        #expect(approx(q.stampDuty, 4.0))       // 8000*0.0005
        #expect(approx(q.proceeds, 7_995.2))
    }
    @Test("D7 清仓: shares==holding 奇数股放行")
    func clearOddLot() {
        let r = TradeCalculator.quoteSell(holding: 150, shares: 150, price: 20, fees: noMin)
        guard case .success(let q) = r else { Issue.record("expected success, got \(r)"); return }
        #expect(q.shares == 150)
    }
    @Test("D7 部分卖非整手且≠holding → invalidShareCount")
    func partialOddLot() {
        #expect(TradeCalculator.quoteSell(holding: 150, shares: 50, price: 20, fees: noMin)
                == .failure(.invalidShareCount))
    }
    @Test("超持仓 → insufficientHolding")
    func overSell() {
        #expect(TradeCalculator.quoteSell(holding: 100, shares: 200, price: 20, fees: noMin)
                == .failure(.insufficientHolding))
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
        guard shares > 0, shares % shareLotSize == 0 else { return .failure(.invalidShareCount) }
        let notional = Double(shares) * price
        let commission = computeCommission(notional: notional, fees: fees)
        let totalCost = notional + commission
        guard totalCost <= cash else { return .failure(.insufficientCash) }
        return .success(BuyQuote(shares: shares, notional: notional,
                                 commission: commission, totalCost: totalCost))
    }

    /// 按股数卖出报价。D7：shares==holding（清仓）放行任意股数（含奇数）；部分卖要求整手。
    public static func quoteSell(holding: Int, shares: Int, price: Double,
                                 fees: FeeSnapshot) -> Result<SellQuote, TradeReason> {
        guard price > 0, holding >= 0, price.isFinite else { return .failure(.invalidShareCount) }
        guard shares > 0 else { return .failure(.invalidShareCount) }
        guard shares <= holding else { return .failure(.insufficientHolding) }
        if shares != holding {                      // 部分卖才要求整手（清仓例外）
            guard shares % shareLotSize == 0 else { return .failure(.invalidShareCount) }
        }
        return .success(makeSellQuote(shares: shares, price: price, fees: fees))
    }

    /// fee-aware 可买上限：满足 totalCost(N) ≤ cash 的最大 100 股整数倍。
    public static func maxBuyableShares(cash: Double, price: Double, fees: FeeSnapshot) -> Int {
        guard price > 0, cash > 0, price.isFinite, cash.isFinite else { return 0 }
        // 估算上界（忽略 min 佣金）：N ≤ cash / (price*(1+rate))
        let est = robustFloor(cash / (price * (1 + fees.commissionRate)))
        var lots = (est / shareLotSize) * shareLotSize
        // 向下校正：免5 下限 / FP 边界可能令估值略超 cash
        while lots > 0 {
            let notional = Double(lots) * price
            if notional + computeCommission(notional: notional, fees: fees) <= cash { break }
            lots -= shareLotSize
        }
        return max(0, lots)
    }

    /// 比例 → 买入快捷股数（1/5..4/5 = cash 基准 lot-floor；全仓 = maxBuyableShares）。
    public static func sharesForBuyTier(cash: Double, price: Double, tier: PositionTier,
                                        fees: FeeSnapshot) -> Int {
        if tier == .tier5 { return maxBuyableShares(cash: cash, price: price, fees: fees) }
        guard price > 0, cash >= 0, price.isFinite, cash.isFinite else { return 0 }
        let raw = robustFloor(cash * ratio(of: tier) / price)
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

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift ios/Contracts/Tests/KlineTrainerContractsTests/TradeCalculatorTests.swift
git commit -m "feat(A1): TradeCalculator 按股数 quoteBuy/quoteSell + maxBuyable/sharesForTier helpers（D7 清仓奇数股）"
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
        switch TradeCalculator.quoteSell(holding: holdingBefore, shares: shares, price: price, fees: fees) {
        case .failure(let reason):
            return .failure(.trade(reason))
        case .success(let quote):
            position.sell(shares: quote.shares)
            cashBalance += quote.proceeds
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
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（`finalizeSession` 事务内从持久记录派生 `setTotalCapital`，签名不变；`resetAllTrainingProgress` 去 `deleteAll`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`（加 `refreshTotalCapital(_:)` 纯缓存刷新）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（`startingCapital` 直读 DB；`finalize` 成功后刷活缓存）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingResetPortTests.swift`（reset 保留记录）+ `SessionFinalizationPortTests.swift`（finalize 派生写资金 + retry 幂等）+ SettingsStore 测（`refreshTotalCapital`）+ coordinator 测（finalize→活缓存即时反映）

**Interfaces:**
- Consumes: `SettingsDAOImpl.setTotalCapital`、`RecordRepositoryImpl.insertRecord`、`PendingTrainingRepositoryImpl.clearPending`、`SettingsDAO.loadSettings`、`SettingsStore`。
- Produces（Task 5 依赖）: `settings.total_capital` 权威当前资金；`finalizeSession(...)` 签名不变、retry 幂等；`SettingsStore.refreshTotalCapital(_:)`（finalize/外部写库后同步活缓存，主页即时反映）。

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
func test_finalize_writes_capital_from_persisted_record() throws {
    let id = try db.finalizeSession(record: someRecord, ops: [], drawings: [], sessionKey: "k1")
    XCTAssertGreaterThan(id, 0)
    XCTAssertEqual(try db.loadSettings().totalCapital, 123_456, accuracy: 1e-6)  // total_capital+profit
}
// codex R-plan-2-1：同 sessionKey retry 用「发散现值」record，资金仍=首次持久记录派生值（幂等锚）
func test_finalize_retry_same_key_keeps_first_capital() throws {
    _ = try db.finalizeSession(record: someRecord, ops: [], drawings: [], sessionKey: "k1")
    // divergent：同其余字段、profit 改 999_999（若提交会派生 1_099_999）
    let divergent = someRecordWithProfit(999_999)
    _ = try db.finalizeSession(record: divergent, ops: [], drawings: [], sessionKey: "k1")
    XCTAssertEqual(try db.loadSettings().totalCapital, 123_456, accuracy: 1e-6)  // 不被发散值覆盖
}
```

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
```

（`someRecord`/`someRecordWithProfit`/insert/coordinator 装配 用本文件/`TrainingSessionPersistenceTests` 现成范式。）

- [ ] **Step 2: 跑确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter "TrainingResetPortTests|SessionFinalizationPortTests"`
Expected: reset 测试 FAIL（仍 deleteAll → totalCount==0）；finalize 资金断言 FAIL（现 finalizeSession 不写 total_capital）。

- [ ] **Step 3a: 改 `DefaultAppDB.finalizeSession`**（事务内**从持久化记录派生** total_capital；**签名不变**，retry 幂等）

> codex R-plan-2-1：`insertRecord` 对重复 sessionKey 返**已存 id 不插入**（0004 幂等锚）；故资金**不能用 caller 现值**（retry 时会与持久记录发散、污染权威源）。改为从「插入或已存的持久记录」读 `total_capital+profit` 派生 → 与幂等记录恒一致，retry 安全。**不加 `newTotalCapital` 参数**（避免改 `SessionFinalizationPort` 协议签名 → 零 fake 波及）。

```swift
    public func finalizeSession(record: TrainingRecord, ops: [TradeOperation],
                                drawings: [DrawingObject], sessionKey: String) throws -> Int64 {
        do {
            return try dbQueue.write { db in
                let id = try RecordRepositoryImpl.insertRecord(
                    db, record: record, ops: ops, drawings: drawings, sessionKey: sessionKey)
                try PendingTrainingRepositoryImpl.clearPending(db)
                // A4（retry 幂等）：权威资金 = 该(幂等)持久记录的 total_capital+profit。
                // 读 DB 持久值而非 caller 现值——同 sessionKey 重试时 insertRecord 返已存 id，
                // 这里读到的仍是首次提交值 → 资金不会被发散现值覆盖。
                if let row = try Row.fetchOne(db, sql:
                    "SELECT total_capital, profit FROM training_records WHERE id = ?",
                    arguments: [id]) {
                    let tc: Double = row["total_capital"]
                    let p: Double = row["profit"]
                    try SettingsDAOImpl.setTotalCapital(db, tc + p)
                }
                return id
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
```

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

`finalize()` 在 `finalizeSession(...)` 成功后，把活缓存刷为持久权威值（`finalizeSession` 签名不变、无 fake 波及）：

```swift
        let id = try finalization.finalizeSession(record: record,
                                                  ops: engine.tradeOperations,
                                                  drawings: engine.drawings,
                                                  sessionKey: key)
        settings.refreshTotalCapital(try settingsDAO.loadSettings().totalCapital)  // R-plan-3-1：刷活缓存→主页即时反映
        return id
```

- [ ] **Step 4: 跑确认通过 + 全量回归**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter "TrainingResetPortTests|SessionFinalizationPortTests"` → PASS
Run: `swift test` 全量。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingResetPortTests.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/SessionFinalizationPortTests.swift
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
                try db.execute(sql:
                    "INSERT OR REPLACE INTO settings(key, value) VALUES ('total_capital', ?)",
                    arguments: [String(tc + p)])
            }
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

**Files:**
- 先审计：`grep -rn "statistics()\.currentCapital\|\.currentCapital\|currentCapital" ios/Contracts/Sources` 找所有「跨局当前资金」显示/使用点。
- 已知：`AppRouter.loadHome` 读 `settings.settings.totalCapital`（`SettingsStore` 活缓存）—— Task 3 已让该缓存在 finalize/reset 后即时刷新，故**主页天然权威、无需改 home**；本任务确认这点 + 处理任何**仍读 `statistics().currentCapital` 派生**的消费者。
- Modify（若有）：仍读 `statistics().currentCapital` 派生显示「当前资金」的消费者，改读权威 `SettingsStore.settings.totalCapital`（活缓存，已刷新）或 `settingsDAO.loadSettings().totalCapital`。
- Test: 对应消费者的 host 测（注入「有记录但 settings.total_capital 已 reset 为 10 万」→ 期望显 10 万权威，而非末条记录派生）。

**Interfaces:**
- Consumes: Task 3 的权威 `settings.total_capital` + 活缓存刷新。
- Produces: reset 后 / finalize 后显示均不与权威值背离。

- [ ] **Step 1: 审计 + 写失败测试**

Run 审计：`grep -rn "currentCapital" ios/Contracts/Sources`。逐一判定每个「显示跨局当前资金」点的数据源：
- 读 `SettingsStore.settings.totalCapital`（如 `AppRouter.loadHome`）→ **已权威**（Task 3 刷缓存），仅需回归确认（finalize→home / reset→home 显新值）。
- 仍读 `statistics().currentCapital` 派生 → 须改读权威字段；为其纯值层写失败测试（reset 后显 10 万，而非末条记录派生）。

> 注：若审计发现**没有**任何 UI 读 `statistics().currentCapital` 作资金显示（仅 `startingCapital` 用过、已在 Task 3 改走 settings），则本任务收敛为：在 plan 执行记录中**显式声明「无额外消费者，主页经活缓存已权威」**（非静默），`statistics().currentCapital` 字段保留供胜率统计同伴查询但不再作资金真相源。

- [ ] **Step 2: 跑确认失败 / 或确认无消费者**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter <新测试>`

- [ ] **Step 3: 实现**

把任何仍读派生值的消费者改读权威 `settings.total_capital`（活缓存或 DAO）。（具体改动随审计结果定；每处 = 把 `statistics().currentCapital` 换成权威读取。）

- [ ] **Step 4: 跑确认通过**

Run: `swift test`（相关 filter）→ PASS

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "feat(A4/D6): 跨局当前资金显示统一读权威 settings.total_capital"
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
            if case .success(let q) = TradeCalculator.quoteSell(holding: holding, shares: s, price: price, fees: fees) {
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
            if case .success = TradeCalculator.quoteSell(holding: holding, shares: s, price: price, fees: fees) { return true }
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
- Modify: 测试迁移 —— `TradeCalculatorTests.swift`（删/迁移 16 个 tier 测试到按股数等价）、`TrainingSessionPersistenceTests.swift:505/525`、`TrainingSessionCrossFeatureTests.swift:14`、`UI/TrainingSessionLifecycleTests.swift:159`（把 `engine.buy(panel:tier:)` 调用改 `engine.buy(panel:shares:)`）。

> **前置确认**（接线调查已完成，Agent 报告）：tier-based `engine.buy/sell(panel:tier:)` 与 `TradeCalculator.quoteBuy(totalCapital:)/quoteSell(…tier:)` 的生产调用方仅 = UI（Task 8 已切走）+ `buyEnabled`（本任务改）；其余皆测试。故可安全删除。

- [ ] **Step 1: 改 `buyEnabled`**（line 299-310）

```swift
    public var buyEnabled: Bool {
        guard flow.canBuySell() else { return false }
        // RFC-A：能买至少 1 手即使能（fee-aware）。
        return TradeCalculator.maxBuyableShares(cash: cashBalance, price: currentPrice, fees: fees)
            >= TradeCalculator.shareLotSize
    }
```

- [ ] **Step 2: 跑回归确认无破坏**（buyEnabled 改动）

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test`（应仍全绿——若有断言 buyEnabled 在 0 现金时 true 之类，按新语义修）。

- [ ] **Step 3: 迁移 tier 测试 + 删 tier 方法**

3a. 把 `TradeCalculatorTests.swift` 的 Buy/Sell 两个 `@Suite`（16 个 tier 测试）逐个迁移为按股数等价（已在 Task 1 加了按股数覆盖；此处删除现有 tier 测试，避免编译引用已删方法）。保留 ForceClose suite（`forceCloseOnEnd` 不删）。
3b. 改 4 处测试调用点：`engine.buy(panel:tier:.tierN)` → 先 `let n = TradeCalculator.sharesForBuyTier(...)` 再 `engine.buy(panel:shares:n)`（或直接传等价 shares）。`engine.sell` 同理。
3c. 删 `TradeCalculator.swift` 的 `quoteBuy(totalCapital:cash:tier:price:fees:)`（line 39-58）与 `quoteSell(holding:averageCost:tier:price:fees:)`（line 62-84）。
3d. 删 `TrainingEngine.swift` 的 `buy(panel:tier:)`（line 394-416）与 `sell(panel:tier:)`（line 429-452）。

- [ ] **Step 4: 跑确认全绿**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test`
Expected: 全 PASS，且无对已删方法的引用（编译通过即证明无残留调用方）。

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

> 风险（执行时注意）：Task 3 `finalizeSession` 不改签名（资金从持久记录派生，零 fake 波及）；finalize retry 幂等已由「读持久记录派生资金」保证（codex R-plan-2-1）；finalize 后须 `settings.refreshTotalCapital(...)` 同步活缓存，否则主页显陈旧资金（codex R-plan-3-1）。Task 5 D6 消费者集合以审计结果为准（主页经活缓存已权威；若无派生消费者则显式声明非静默）。Task 9 删冻结契约方法须 Task 8 先完成 UI 迁移。
