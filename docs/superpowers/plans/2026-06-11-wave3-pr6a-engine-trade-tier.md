# Wave 3 顺位 6a — TrainingEngine 交易/档位 engine 契约扩展 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 `TrainingEngine` 加两个 engine API —— on-demand 手动强平（§4.4a）+ 当前持仓档位 accessor `currentPositionTier`（§4.4b/§4.1）—— 为顺位 7 U2 交易 UI 接线提供冻结契约。

**Architecture:** 纯 additive engine API，只改 `TrainingEngine.swift` + 新增测试。手动强平**复用**既有 `forceCloseIfEnded` 的强平体（抽出 `performForceClose()`，两个入口仅触发门不同，杜绝两套强平逻辑漂移）；`currentPositionTier` 是 read-only computed（派生非状态）。零 schema / 零持久化 / 零 UI / 零路由改动（UI 态 + 结算路由归顺位 7/8）。

**Tech Stack:** Swift 6, Swift Testing（`@Test`/`#expect`），SwiftPM 包 `ios/Contracts`，`@MainActor` 隔离。

**权威输入：** `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` §4.1 + §4.4a + §4.4b（anchor #1 RFC，PR #94 merged）。本 plan 不重新设计公共面，仅落地 RFC 已钉死的契约。

**Scope 边界（RFC §4.4 anchor 6 拆分）：** 本 PR = **6a**（§4.4a 手动强平 + §4.4b tier accessor）。§4.4c `appendDrawing` / §4.4d zoom panel-state / §4.4e replay-settlement payload = **6b**（紧接的下一锚，同改 `TrainingEngine.swift`，轨内串行）。

**无 CONTRACT_VERSION / schema bump：** 6a 是纯 engine API 增量，不触 `pending_training`/`training_records`/任何 DDL。RFC §4.7c 的 MANDATORY-bump 门只对 10a 的 schema 迁移生效（§六明列），与 6a 无关。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | engine 状态 + 动作 | 修改：加 `currentPositionTier` computed（Task 1）；抽 `performForceClose()` + 加 `forceCloseManually()`（Task 2） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift` | 交易动作测试（E5b 起，trade-action 的既有归属） | 修改：加 `// MARK: - Wave 3 顺位 6a` 段，复用既有 `tradeEngine`/`m3Candles` 静态 fixture（Task 1 + Task 2） |
| `docs/acceptance/2026-06-11-wave3-pr6a-engine-trade-tier.md` | 非 coder 可执行验收清单 | 新建（Task 3） |

**测试归属决策：** 复用 `TrainingEngineActionsTests.swift` 内既有 `static func tradeEngine(...)` / `m3Candles(...)` fixture（DRY，避免重复声明），新增测试置于该 suite 末尾的 `// MARK: - Wave 3 顺位 6a` 段。这是 trade-action 测试的既有家；只增测试方法，不重构既有代码（surgical）。

---

## 关键事实（grep 核实 2026-06-11，origin/main `cf43a43`）

- `forceCloseIfEnded()`（`TrainingEngine.swift:417-436`）：`guard tick.globalTickIndex >= tick.maxTick, position.shares > 0 else { return }` → 之后是强平体（取 `currentPrice` → `TradeCalculator.forceCloseOnEnd` → `position.sell` + `cashBalance +=` + sell `TradeMarker` + `TradeOperation(positionTier: .tier5, period: .m3)` + 第二次 `drawdown.update`）。
- `flow.canBuySell()`（`TrainingFlowController.swift`）：Normal `true` / Review `false` / Replay `true`。RFC §4.4a 用它作前置（opus R1-L4：「结束按钮」capability 行的 intentional load-bearing proxy）。
- `currentPrice`（private，:230）= `.m3` 驱动序列首个 `endGlobalIndex >= 当前 tick` 的收盘价；`currentTotalCapital`（public，:235）= `cashBalance + shares × currentPrice`。无 `currentPositionTier`。
- `TradeCalculator.forceCloseOnEnd(holding:averageCost:price:fees:)`（`TradeCalculator.swift:88`）返回裸 `SellQuote`；`holding<=0 || price<=0 || !finite → 全零报价`。
- drawdown seed（:113-116）：`peakCapital = max(initialDrawdown.peakCapital, initialCapital, startTotal)`。
- 测试 fees：`FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)`；min 佣金 5；印花税率 0.0005（仅卖）。
- 测试 fixture：`tradeEngine(closes:[10,10,10,10,10], cash:100_000, capital:100_000, position:.init(), mode:.normal)` 直建 `TrainingEngine`（双面板 `.m3`，每动作步进 1 tick）。
- buy/sell **会推进 tick**（经 `advanceAndAccount`）；`currentPositionTier` 与 `forceCloseManually` **不推进 tick**（直接读/直接平）。
- 基线：799 tests / 120 suites pass（worktree off origin/main）。

---

### Task 1: §4.4b `currentPositionTier` accessor（当前持仓档位 X/5）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（在 `maxDrawdown`computed 之后、`// MARK: - 动作可用性门` 之前插入，约 :250 后）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift`（新增 `// MARK: - Wave 3 顺位 6a：currentPositionTier` 段）

**RFC §4.1 公式（权威）：**
```
holdingValue = position.shares × currentPrice
total        = currentTotalCapital            // = cashBalance + holdingValue
total <= 0  → 0
否则         → clamp( Int( (holdingValue / total × 5).rounded(.toNearestOrAwayFromZero) ), 0, 5 )
```

- [ ] **Step 1: 写失败测试（5 个）**

在 `TrainingEngineActionsTests.swift` 末尾（`}` 闭合 suite 之前）追加：

```swift
    // MARK: - Wave 3 顺位 6a：currentPositionTier（RFC §4.1 / §4.4b）

    @Test func currentPositionTierZeroWhenFlat() {
        let e = Self.tradeEngine(closes: [10, 10, 10], position: .init())
        #expect(e.currentPositionTier == 0)        // shares==0 → holdingValue 0 → 0/5
    }

    @Test func currentPositionTierZeroWhenTotalCapitalNonPositive() {
        // total == 0（cash 0 + 空仓）→ guard total>0 false → 0（不崩、不除零）
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 100_000, position: .init())
        #expect(e.currentPositionTier == 0)
    }

    @Test func currentPositionTierThreeAfterBuyingSixtyPercent() {
        // 买 3/5（60% of 100_000 / 10 = 6000 股），价不变：6000*10=60000 / (39994+60000=99994) = .60003 → ×5=3.0002 → round 3
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 100_000, capital: 100_000)
        _ = e.buy(panel: .upper, tier: .tier3)
        #expect(e.position.shares == 6000)
        #expect(e.currentPositionTier == 3)
    }

    @Test func currentPositionTierFiveWhenFullyInvested() {
        // 满仓态：10000 股 @10、cash 0 → holdingValue 100000 / total 100000 = 1.0 → ×5=5 → 5/5
        let e = Self.tradeEngine(closes: [10, 10], cash: 0, capital: 100_000,
                                 position: PositionManager(shares: 10_000, averageCost: 10, totalInvested: 100_000))
        #expect(e.currentPositionTier == 5)
    }

    @Test func currentPositionTierUsesMarketValueBasisNotStatefulBuyTier() {
        // RFC §4.1 acceptance 锁向量（opus R1-L5）：买 4/5 → 价 ×2 → 卖 持仓 2/5 → 期望 3/5（非 4/5）。
        // 钉死「持仓市值 / 当前总资金基准 + round」；stateful「记住买入档位」实现会卡在 4/5 → 第二个断言失败。
        // maxTick=3：buy@tick0→tick1、sell@tick1→tick2（tick2<3，不触局终强平）。
        let e = Self.tradeEngine(closes: [10, 20, 20, 20], cash: 100_000, capital: 100_000)
        _ = e.buy(panel: .upper, tier: .tier4)      // 80% of 100000 / 10 = 8000 股；advance→tick1（价 20）
        #expect(e.position.shares == 8000)
        #expect(e.currentPositionTier == 4)         // 8000*20=160000 / (19992+160000=179992) = .8889 → ×5=4.44 → round 4
        _ = e.sell(panel: .upper, tier: .tier2)     // 卖 持仓 40% = 3200 股；advance→tick2（价 20，不强平）
        #expect(e.position.shares == 4800)
        #expect(e.currentPositionTier == 3)         // 4800*20=96000 / (83953.6+96000=179953.6) = .5335 → ×5=2.667 → round 3
    }

    @Test func currentPositionTierZeroOnNonFiniteOverflow() {
        // codex plan R1-high：有限但极端的收盘价 × 持仓股数 溢出 Double → holdingValue = +inf（非 finite）。
        // 若无 isFinite 守卫，holdingValue/total = inf/inf = NaN，Int(NaN) **trap 崩溃**。守卫须返 0、不崩。
        let e = Self.tradeEngine(closes: [.greatestFiniteMagnitude, .greatestFiniteMagnitude],
                                 cash: 100_000, capital: 100_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        #expect(e.currentPositionTier == 0)         // 1000 × 1.8e308 → +inf → guard → 0（不 trap）
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter currentPositionTier 2>&1 | tail -20`
Expected: 编译失败 —— `value of type 'TrainingEngine' has no member 'currentPositionTier'`。

- [ ] **Step 3: 实现 accessor（最小）**

在 `TrainingEngine.swift` `public var maxDrawdown: Double { drawdown.maxDrawdown }`（:250）之后插入：

```swift
    /// 当前持仓档位 X/5（0...5），read-only computed（RFC §4.4b / §4.1）。
    /// 基准 = 持仓市值 / 当前总资金（与顶栏「总资金 = 现金 + 持仓市值」同口径，plan v1.5 L914），
    /// round（四舍五入）非 floor（反映用户意图档位）。**派生非状态**：每次从 live 状态算
    /// （buy 以总资金、sell 以持仓为基准，无单一持久 tier 字段）。顺位 7 顶栏「仓位 X/5」显示。
    /// **非有限守卫（codex plan R1）**：`shares × price` 在极端有限价下可溢出至 inf → `inf/inf=NaN`，
    /// `Int(NaN)` 会 trap 崩溃。`total > 0` 不挡 `+inf`（inf>0 为真），故须显式 `isFinite` 守卫
    /// （与 `forceCloseOnEnd` 的 `price.isFinite`、init 的 finite money 前置同风格）→ 退化 0/5 不崩。
    public var currentPositionTier: Int {
        let holdingValue = Double(position.shares) * currentPrice
        let total = currentTotalCapital
        guard total > 0, total.isFinite, holdingValue.isFinite else { return 0 }
        // 此处 holdingValue 有限、total 有限且 >0 → ratio 有限、×5 有限、rounded 有限 → Int 安全。
        let raw = (holdingValue / total * 5).rounded(.toNearestOrAwayFromZero)
        return min(max(Int(raw), 0), 5)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter currentPositionTier 2>&1 | tail -20`
Expected: PASS（5 tests，0 failures）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift
git commit -m "feat(6a): currentPositionTier accessor（RFC §4.4b/§4.1 市值基准 + round）"
```

---

### Task 2: §4.4a on-demand 手动强平 `forceCloseManually()`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（重构 `forceCloseIfEnded` 抽出 `performForceClose()`，:417-436；新增 `forceCloseManually()`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift`（新增 `// MARK: - Wave 3 顺位 6a：forceCloseManually` 段）

**RFC §4.4a 契约：** engine 暴露 on-demand 强平（语义等同 `forceCloseIfEnded` 体，但去掉 `>= maxTick` 门）。前置 `flow.canBuySell()`（Normal ✅ / Review ❌ / Replay ✅）；按 `currentPrice`（当前 tick 收盘，非 maxTick 末根）；幂等（shares==0 短路 no-op）；与 auto 共用同一强平体。**ended UI 态 / 结算路由归顺位 7/8，非 engine 契约** —— 本方法只平仓、不推进 tick、不路由。

- [ ] **Step 1: 写失败测试（6 个）**

在 `TrainingEngineActionsTests.swift` 末尾追加：

```swift
    // MARK: - Wave 3 顺位 6a：forceCloseManually（RFC §4.4a on-demand 强平）

    @Test func forceCloseManuallyClosesHoldingAtCurrentTickPrice() {
        // 局中（tick0 < maxTick2）主动结束：按当前 tick 价 10 全平，不推进 tick。
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        #expect(e.forceCloseManually() == true)         // 平仓成功 → 安全可结算（position.shares==0）
        #expect(e.position.shares == 0)                 // 已强平
        #expect(e.cashBalance == 9990)                  // proceeds：notional10000 - comm5 - stamp5
        #expect(e.tick.globalTickIndex == 0)            // **不推进 tick**（区别于 buy/sell）
        #expect(e.markers.contains { $0.direction == .sell && $0.globalTick == 0 })
        let fc = e.tradeOperations.last
        #expect(fc?.direction == .sell)
        #expect(fc?.positionTier == .tier5)
        #expect(fc?.period == .m3)
        #expect(fc?.globalTick == 0)
        #expect(fc?.shares == 1000)
        #expect(fc?.stampDuty == 5)
        #expect(e.maxDrawdown == 10)                    // peak(10000) - realized(9990)：第二次 drawdown.update 并入
    }

    @Test func forceCloseManuallyUsesCurrentTickPriceNotEndPrice() {
        // 末根价 99，当前 tick0 价 10：手动强平须按 10（当前价），非 99（末根）。杀「误用末根价」实现。
        let e = Self.tradeEngine(closes: [10, 99], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        e.forceCloseManually()
        #expect(e.tradeOperations.last?.price == 10)
    }

    @Test func forceCloseManuallyNoOpWhenFlat() {
        // 空仓 → 幂等短路 no-op：无 marker / 无 operation；已平 → 返 true（安全可结算）。
        let e = Self.tradeEngine(closes: [10, 10, 10], position: .init())
        #expect(e.forceCloseManually() == true)         // 已平（无新平仓）→ 安全可结算
        #expect(e.position.shares == 0)
        #expect(e.markers.isEmpty)
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func forceCloseManuallyDisabledInReviewMode() {
        // Review canBuySell()==false → 前置门 no-op：持仓不动、无 operation。
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000),
                                 mode: .review)
        #expect(e.forceCloseManually() == false)        // 持仓未平 → 不安全（不可结算）
        #expect(e.position.shares == 1000)              // 未平
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func forceCloseManuallyAllowedInReplayMode() {
        // Replay canBuySell()==true → 可手动强平。
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000),
                                 mode: .replay)
        #expect(e.forceCloseManually() == true)
        #expect(e.position.shares == 0)
        #expect(e.tradeOperations.last?.direction == .sell)
    }

    @Test func forceCloseManuallyIsIdempotent() {
        // 第二次调用 shares==0 → 短路，无新 operation；仍返 true（已平 = 安全可结算）。
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        #expect(e.forceCloseManually() == true)         // 首次平仓
        let opsAfterFirst = e.tradeOperations.count
        #expect(e.forceCloseManually() == true)         // 已平 → 仍 true，无新 operation
        #expect(e.tradeOperations.count == opsAfterFirst)
        #expect(e.position.shares == 0)
    }

    // —— codex plan R2-high：force-close 非法/溢出报价的原子 no-mutation（不写 NaN，不留半平仓态）——

    @Test func forceCloseManuallyNoOpOnZeroPrice() {
        // 当前价 0 → forceCloseOnEnd 的 `price > 0` 守 → 全零报价 → 原子 no-op：持仓与现金不动、无 operation、返 false。
        let e = Self.tradeEngine(closes: [0, 0], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        #expect(e.forceCloseManually() == false)
        #expect(e.position.shares == 1000)              // 未平
        #expect(e.cashBalance == 0)                     // 未写入
        #expect(e.tradeOperations.isEmpty)
        #expect(e.markers.isEmpty)
    }

    @Test func forceCloseManuallyNoOpOnNonFinitePrice() {
        // 当前价 inf → forceCloseOnEnd 的 `price.isFinite` 守 → 全零报价 → 原子 no-op。
        let e = Self.tradeEngine(closes: [.infinity, .infinity], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        #expect(e.forceCloseManually() == false)
        #expect(e.position.shares == 1000)
        #expect(e.cashBalance == 0)
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func forceCloseManuallyNoOpOnFiniteOverflowPrice() {
        // 有限但极端价 → makeSellQuote 的 notional/proceeds 溢出 inf/NaN（forceCloseOnEnd 的 price.isFinite 放行）。
        // performForceClose 的**新 quote-finite 守卫**须挡住 → 原子 no-op：现金不被写成 NaN、持仓保留、无 operation、返 false。
        let e = Self.tradeEngine(closes: [.greatestFiniteMagnitude, .greatestFiniteMagnitude],
                                 cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        #expect(e.forceCloseManually() == false)
        #expect(e.position.shares == 1000)              // 未平（不留半平仓态）
        #expect(e.cashBalance == 0)                     // **未写入 NaN**
        #expect(e.cashBalance.isFinite)                 // 显式守住「现金保持有限」
        #expect(e.tradeOperations.isEmpty)
        #expect(e.markers.isEmpty)
    }

    @Test func forceCloseManuallyReturnsFalseInFlatReviewMode() {
        // codex R3-medium：生产 Review engine 构造即空仓。Review 禁手动结束 → 即使空仓也**不得**返 true
        // 误导 caller 路由结算（绕过模式限制）。canBuySell()==false → 恒 false。
        let e = Self.tradeEngine(closes: [10, 10, 10], position: .init(), mode: .review)
        #expect(e.forceCloseManually() == false)
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func autoForceCloseOnOverflowPriceLeavesCashFinite() {
        // codex R3-high 回归：[10, .greatestFiniteMagnitude] reader-valid。tick0 买入 → advance 到 maxTick(1)
        // → auto forceCloseIfEnded 在末根极端价算出溢出 quote（proceeds NaN）。6a 的 quote-finite 守卫
        // （performForceClose 共用体）须挡住 → **不把 NaN 写进 cash**（pre-6a 会写 NaN）。
        // 残留终态（持仓未平 / 市值含 inf）的 finalize gating 归 RFC §4.7 顺位 10a/10b，**非 6a**；
        // 本测试只钉死 6a 不变量「force-close 体不腐蚀 cash」。
        let e = Self.tradeEngine(closes: [10, .greatestFiniteMagnitude], cash: 100_000, capital: 100_000)
        let r = e.buy(panel: .upper, tier: .tier1)      // tick0@10 买入 → advance→tick1(=maxTick) → auto force-close 触发
        guard case .success = r else { Issue.record("buy@tick0 应成功"); return }
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.cashBalance.isFinite)                 // **cash 未被写 NaN**（6a finite 守卫）
        #expect(e.cashBalance == 79_995)                // 仅 tick0 买入扣款（100000-20005）；末根强平因溢出 no-op，未再动 cash
    }

    @Test func forceCloseManuallyNoOpOnCashSumOverflow() {
        // codex R4-high：quote 各字段**有限**，但 `cashBalance + proceeds` 两有限值相加溢出 inf。
        // newCash.isFinite 守卫须在 mutation 前挡住 → 整笔原子 no-op：cash 不被写 inf、持仓保留、无 op、返 false。
        // 价 1e308（finite，notional 1×1e308 不溢出）；cash 1.5e308 → 和 = 2.5e308 > Double.max → inf。
        let e = Self.tradeEngine(closes: [1e308, 1e308], cash: 1.5e308, capital: 1.5e308,
                                 position: PositionManager(shares: 1, averageCost: 10, totalInvested: 10))
        #expect(e.forceCloseManually() == false)
        #expect(e.position.shares == 1)                 // 未平
        #expect(e.cashBalance == 1.5e308)               // **未写入 inf**
        #expect(e.cashBalance.isFinite)
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func autoForceCloseNoOpOnCashSumOverflow() {
        // codex R4-high（auto 路径同守）：holdOrObserve 推进到 maxTick → auto 强平算出有限 quote，但
        // cashBalance + proceeds 溢出 → 整笔原子 no-op，cash 保持有限不变。
        let e = Self.tradeEngine(closes: [1e308, 1e308], cash: 1.5e308, capital: 1.5e308,
                                 position: PositionManager(shares: 1, averageCost: 10, totalInvested: 10))
        e.holdOrObserve(panel: .upper)                  // tick0 → tick1(=maxTick) → auto forceCloseIfEnded
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.cashBalance == 1.5e308)               // 和溢出 → no-op，cash 未动
        #expect(e.cashBalance.isFinite)
        #expect(e.position.shares == 1)                 // 未平
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func forceCloseManuallyReturnsFalseWhenDrawdownNonFinite() {
        // codex R4-high：force-close 后 cash 有限、持仓已平，但 drawdown 在 advance 路径被病态价污染成非有限
        // （持仓 × 1e308 → inf 市值 → drawdown.update(inf) → peakCapital=inf）。isSettlementSafe 须据此返 false，
        // 不让 caller 路由结算去 finalize 持久化 NaN/inf。污染源（advance drawdown）根治归顺位 10，非 6a。
        // 序列 [10, 1e308, 10]：买@tick0 → 持有推进 tick1（污染 drawdown）→ 推进 tick2(=maxTick) 末根价 10 干净强平。
        let e = Self.tradeEngine(closes: [10, 1e308, 10], cash: 100_000, capital: 100_000)
        let r = e.buy(panel: .upper, tier: .tier1)      // tick0@10 买 2000 股 → advance tick1（价 1e308 → drawdown 污染 inf）
        guard case .success = r else { Issue.record("buy@tick0 应成功"); return }
        e.holdOrObserve(panel: .upper)                  // tick1 → tick2(=maxTick)，末根价 10 干净 auto 强平 → 持仓平、cash 有限
        #expect(e.position.shares == 0)                 // 已平
        #expect(e.cashBalance.isFinite)                 // cash 有限
        #expect(e.drawdown.peakCapital.isFinite == false)  // 但 drawdown 已被 tick1 病态价污染成非有限
        #expect(e.forceCloseManually() == false)        // → isSettlementSafe 据非有限 drawdown 返 false（安全降级）
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter forceCloseManually 2>&1 | tail -20`
Expected: 编译失败 —— `value of type 'TrainingEngine' has no member 'forceCloseManually'`。

- [ ] **Step 3: 重构抽出共用体 + 实现 on-demand 入口**

把 `TrainingEngine.swift:417-436` 现有 `forceCloseIfEnded()` 整块替换为下面三段（保留原注释意图；强平体逐字保留，仅移入 `performForceClose`）：

```swift
    /// 推进到 `>= maxTick` 且仍有持仓 → 按末根 .m3 收盘价强制全平（plan v1.5 L751）。
    /// 幂等：强平后 shares==0，再次到顶 guard 短路。
    private func forceCloseIfEnded() {
        guard tick.globalTickIndex >= tick.maxTick, position.shares > 0 else { return }
        performForceClose()
    }

    /// 手动 on-demand 强平（RFC §4.4a）：用户点「结束本局」时调用，去掉 `>= maxTick` 门。
    /// 前置 `flow.canBuySell()`（Normal/Replay ✅，Review ❌；opus R1-L4：「结束按钮」capability
    /// 行的 intentional load-bearing proxy，恰与「买卖按钮」行同值）。按当前 tick 价、不推进 tick。
    /// 幂等：空仓短路。**返回 `isSettlementSafe`** —— 顺位 7 caller 的路由信号（只在确认平仓**且**
    /// finalize 用到的全部派生财务量有限时才返 true；否则 false，caller 不路由结算）。
    /// **Review/disabled 恒返 false**（codex R3-medium：Review 禁手动结束，flat Review 不得误报可结算）。
    /// ended UI 态 / 结算路由本身归顺位 7/8，非 engine 契约。
    @discardableResult
    public func forceCloseManually() -> Bool {
        guard flow.canBuySell() else { return false }   // R3-medium：Review/disabled 永不经手动结束达成可结算
        if position.shares > 0 { performForceClose() }
        return isSettlementSafe
    }

    /// 终态结算安全谓词（codex plan R3/R4）：持仓已平 **且** finalize 用到的全部派生财务量有限
    /// （`currentTotalCapital` → totalCapital/profit/returnRate；`drawdown` → maxDrawdown 比率）。
    /// 即使 force-close 后 cash 有限，drawdown 也可能被 **advance 路径**在病态极端价上污染成非有限
    /// （`drawdown.update(currentTotalCapital)` 在持仓 × 1.8e308 时并入 inf 市值）。本谓词据此
    /// **安全降级**——任一非有限即 false，caller 不路由结算 → finalize 不持久化 NaN/inf。
    /// （污染源在 advance/init，根治归顺位 10 数据校验；6a 只在结算门诚实报告、不让 caller 误结算。）
    private var isSettlementSafe: Bool {
        position.shares == 0
            && currentTotalCapital.isFinite
            && drawdown.peakCapital.isFinite
            && drawdown.maxDrawdown.isFinite
    }

    /// 强平共用体（局终自动 + 手动 on-demand 共用，仅触发门不同 → 杜绝两套强平逻辑漂移）：
    /// 按 `currentPrice` 全量清仓 → 记 sell marker/operation(.tier5) → `drawdown.update` 把
    /// 已扣费 realized 总资金并入回撤（否则末根手续费造成的回撤被低报）。caller 须先验 `shares > 0`。
    /// 走 E3 `forceCloseOnEnd`（裸 SellQuote，holding==position.shares 满足入口 1b caller 不变量）。
    /// **整笔原子性（codex plan R2/R4）**：先算完整终态 `newCash = cashBalance + proceeds` 并校验
    /// quote 各被写字段 **+ newCash** 全有限，**全有限才提交任一 mutation**；否则整笔原子 no-op 返 false。
    /// 覆盖三类病态：①price≤0/非有限 → forceCloseOnEnd 返全零报价（shares==0 短路）；②有限极端价
    /// → `makeSellQuote` 的 notional/proceeds 溢出 inf/NaN（quote 字段守）；③两有限值相加溢出
    /// （`cashBalance + proceeds` → inf，newCash 守）。杜绝把非有限写进 cash/record / 留半平仓态。
    @discardableResult
    private func performForceClose() -> Bool {
        let price = currentPrice
        let quote = TradeCalculator.forceCloseOnEnd(
            holding: position.shares, averageCost: position.averageCost, price: price, fees: fees)
        let newCash = cashBalance + quote.proceeds
        guard quote.shares > 0,
              quote.proceeds.isFinite, quote.commission.isFinite, quote.stampDuty.isFinite,
              newCash.isFinite
        else { return false }   // 报价溢出 / cash 和溢出 → 校验在 mutation 之前 → 整笔原子 no-op
        let tickAtClose = tick.globalTickIndex
        position.sell(shares: quote.shares)
        cashBalance = newCash                       // 用预校验过的终值（codex R4：mutation 前已验完整终态）
        markers.append(TradeMarker(globalTick: tickAtClose, price: price, direction: .sell))
        tradeOperations.append(TradeOperation(
            globalTick: tickAtClose, period: .m3, direction: .sell, price: price,
            shares: quote.shares, positionTier: .tier5,
            commission: quote.commission, stampDuty: quote.stampDuty,
            totalCost: quote.proceeds, createdAt: candleDatetime(atTick: tickAtClose)))
        drawdown.update(currentCapital: currentTotalCapital)
        return true
    }
```

> **Scope 边界（codex plan R2/R3/R4 回应；核心 = 正确分层，非把全引擎健壮性塞进 6a）**：
> 1. **force-close 体（6a own）**：整笔原子 + finite 全守（quote 字段 + newCash 和），manual + auto 共用 → 任何病态价/溢出都**整笔 no-op**，绝不把 NaN/inf 写进 cash/record。pre-6a auto 路径在此类输入会写 NaN，6a 后保持有限。
> 2. **结算安全 Bool（6a own）**：`isSettlementSafe` 诚实校验 finalize 用到的全部派生量（total/drawdown）有限 → 非有限即拒报「可结算」，caller 不会被误导去结算 NaN/inf 终态（**安全降级**，无需在 6a 修污染源）。
> 3. **根因 + 结构性硬化（顺位 10，非 6a）**：病态价能进引擎的根因 = **reader 接受任意有限正价**（无量级上界）；其结构性修复——(a) reader 价格量级校验、(b) init 拒非有限派生 startTotal、(c) advance 路径 drawdown 污染、(d) buy/sell quote 溢出、(e) **finalize fail-closed gating**（持仓未平 / 非有限 → 拒持久化）——是 **RFC §4.7 + 数据校验层 charter 给顺位 10a/10b** 的契约。6a **不**改 `reader` / E5a `init` / `advanceAndAccount` / `buy`·`sell` / 冻结的 `TrainingSessionCoordinator.finalize` / `TrainingView` 路由。engine 无法从 1.8e308 病态价产出理智结算——理智化属数据边界（10），6a 止于「内部不腐蚀 + 结算门诚实」。

- [ ] **Step 4: 跑新测试 + 既有强平回归测试确认通过**

Run: `cd ios/Contracts && swift test --filter forceClose 2>&1 | tail -40`
Expected: PASS —— 包含新 14 个测试（10 `forceCloseManually*` 行为/失败模式 + 4 auto/cash-sum/drawdown：`NoOpOnZeroPrice`/`NoOpOnNonFinitePrice`/`NoOpOnFiniteOverflowPrice`/`NoOpOnCashSumOverflow`/`ReturnsFalseInFlatReviewMode`/`ReturnsFalseWhenDrawdownNonFinite`/`autoForceCloseOnOverflowPriceLeavesCashFinite`/`autoForceCloseNoOpOnCashSumOverflow`）**以及**既有 `advancingToEndWithHoldingForceCloses`/`advancingToEndWithoutHoldingDoesNotForceClose`/`forceCloseIsIdempotentAcrossRepeatedEndAdvances`/`buyThatAdvancesToEndTriggersForceClose`（证抽体重构未改 auto 行为；`advancingToEndWithHoldingForceCloses` 的 `maxDrawdown == 10` mutation killer 仍绿）。0 failures。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift
git commit -m "feat(6a): forceCloseManually on-demand 强平（RFC §4.4a，复用 performForceClose 共用体）"
```

---

### Task 3: 验收清单文档（非 coder 可执行）

**Files:**
- Create: `docs/acceptance/2026-06-11-wave3-pr6a-engine-trade-tier.md`

**约束（governance backstop #2 + workflow-rules）：** 中文；每条 action / expected / pass-fail 三段；pass 判据二元可决；禁用短语 `验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine`。6a 是 engine 逻辑层（无 UI/运行时），验收 = 机制 + 测试证据，不含 device runbook（运行时 runbook 随消费它的顺位 3/7/8 交付，见 outline §三.3）。

- [ ] **Step 1: 写验收文档**

```markdown
# 验收清单 — Wave 3 顺位 6a：TrainingEngine 交易/档位 engine 契约扩展

**交付物：** `forceCloseManually()`（RFC §4.4a 手动强平）+ `currentPositionTier`（RFC §4.4b/§4.1 当前持仓档位 X/5）两个 engine API。纯逻辑层增量，无 UI、无 schema、无持久化改动。

**前置：** 在 `ios/Contracts` 目录执行命令；macOS 装 Swift 6 工具链。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | `swift test --filter currentPositionTier` | 输出含 `Test run with` 行且 `0 failures`；6 个 `currentPositionTier*` 测试全 ✔（含 `currentPositionTierZeroOnNonFiniteOverflow` 溢出守卫） | 全 ✔ 且 0 failures = 通过；任一 ✘ 或非零 failures = 不通过 |
| 2 | `swift test --filter forceClose` | 14 个新测试全 ✔（含 `NoOpOnFiniteOverflowPrice`/`NoOpOnCashSumOverflow` 现金不被写 NaN/inf、`ReturnsFalseInFlatReviewMode`、`ReturnsFalseWhenDrawdownNonFinite` 安全降级、`autoForceCloseNoOpOnCashSumOverflow`）；既有 4 个 auto 强平测试仍 ✔ | 全 ✔ 且 0 failures = 通过；否则不通过 |
| 3 | `swift test --filter forceClose`（含既有局终自动强平） | 既有 `advancingToEndWithHoldingForceCloses` 仍 ✔（其 `maxDrawdown == 10` 断言证抽 `performForceClose` 共用体未改 auto 强平行为） | 既有强平测试仍 ✔ = 通过；任一既有测试因重构转 ✘ = 不通过 |
| 4 | `swift test`（全量回归） | `Test run with N tests`，`N ≥ 819`（基线 799 + 新增 20），`0 failures` | 0 failures = 通过；≥1 failure = 不通过 |
| 5 | 阅读 `git diff origin/main -- ios/Contracts/Sources` | 仅 `TrainingEngine.swift` 被改；无 `.sql` / 无 schema / 无 `CONTRACT_VERSION` 改动；新增 `currentPositionTier`、`forceCloseManually`、`isSettlementSafe`、`performForceClose` 符号（`forceCloseIfEnded` 改为调用 `performForceClose`）；**未改** `reader`/`init`/`advanceAndAccount`/`buy`/`sell`/`TrainingSessionCoordinator` | 改动文件集 = {TrainingEngine.swift} 且无 schema/version 改动且未触 coordinator/reader = 通过；否则不通过 |
| 6 | Mac Catalyst CI（PR 上 `Mac Catalyst build-for-testing on macos-15`） | required check 状态 = success（编译 + 链接通过） | check = success = 通过；failure = 不通过 |

**证据上传：** PR comment 附命令 #1–#4 的尾部输出（含 `Test run with ... 0 failures` 行）+ CI check 截图/链接。
```

- [ ] **Step 2: Commit**

```bash
git add docs/acceptance/2026-06-11-wave3-pr6a-engine-trade-tier.md
git commit -m "docs(6a): 验收清单（手动强平 + currentPositionTier）"
```

---

## Self-Review

**1. Spec coverage（RFC §4.4a + §4.4b + §4.1）：**
- §4.4a on-demand 强平：去 maxTick 门 ✓（Task 2 `forceCloseManually`）；前置 `canBuySell()` ✓（review no-op / replay allowed 测试）；当前价非末根 ✓（`UsesCurrentTickPriceNotEndPrice`）；幂等 ✓（`IsIdempotent` + flat no-op）；共用体不漂移 ✓（抽 `performForceClose`，既有 auto 测试回归）；**整笔原子 + finite 全守**（quote 字段 + newCash 和；codex R2/R4）✓（`NoOpOnZeroPrice`/`NoOpOnNonFinitePrice`/`NoOpOnFiniteOverflowPrice`/`NoOpOnCashSumOverflow` + auto 对偶）；**结算安全 Bool 诚实**（flat && total finite && drawdown finite，Review 恒 false；codex R3-medium/R4）✓（`ReturnsFalseInFlatReviewMode`/`ReturnsFalseWhenDrawdownNonFinite`）；auto-end 不腐蚀 cash（codex R3-high）✓（`autoForceCloseOnOverflowPriceLeavesCashFinite`/`autoForceCloseNoOpOnCashSumOverflow`）；结构性根因（reader/init/advance/finalize gating）= 顺位 10（RFC §4.7 + 数据校验，Scope 边界 3）。
- §4.4b/§4.1 tier accessor：市值/当前总资金基准 ✓；round ✓；空仓 0 ✓；total<=0 守 0 ✓；满仓 5 ✓；RFC acceptance 锁向量（4→×2→卖2/5→3）✓（`UsesMarketValueBasisNotStatefulBuyTier`）；非有限溢出守卫（codex plan R1-high，`Int(NaN/inf)` trap → isFinite 守 0）✓（`ZeroOnNonFiniteOverflow`）。
- §4.4a「ended UI 态 / 结算路由归 7/8」：本 plan 不实现 UI/路由 ✓（仅 engine 方法）。
- 无 schema/version bump（§六）✓（Task 3 验收 #5 守护）。

**2. Placeholder scan：** 无 TBD/TODO；每个 code step 给完整代码；每条测试给具体数值与预期。✓

**3. Type consistency：** `forceCloseManually()`（public，无参，无返回）/ `performForceClose()`（private）/ `forceCloseIfEnded()`（private，保留）/ `currentPositionTier: Int`（public computed）—— 全文一致。`TradeCalculator.forceCloseOnEnd`、`TradeMarker`、`TradeOperation`、`PositionManager`、`DrawdownAccumulator.update` 签名均取自现有代码。✓

---

## 评审策略（Task 0 / 用户要求）

- 实施前：本 plan 走 **codex `codex:adversarial-review`** 对抗评审到收敛（plan-stage 闸门）。
- 实施后：subagent-driven 完成 → verification-before-completion → requesting-code-review → **整体 codex 对抗评审到收敛**（branch-diff 闸门）。
- codex 周配额耗尽 → opus 4.8 xhigh fallback（per Wave 2 各 anchor 先例）；遇 token 限额则限额恢复后第一时间续；遇 API/网络问题则持续重试至恢复（user 2026-06-11 指示）。
- 撞 ≥3 轮 codex 同条 permanent-bias → escalate user + attestation residual + admin merge（不绕 required checks）。
- 本 PR 触 Catalyst required check（含 `.swift` 改动），不绕过。
```
