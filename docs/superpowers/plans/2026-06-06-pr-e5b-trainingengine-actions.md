# E5b TrainingEngine 交易动作 + 周期组合 + 可用性门 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 E5a 落地的 `TrainingEngine` 运行时核心补全为可操作引擎：实现 `buy`/`sell`/`holdOrObserve`/`switchPeriodCombo` 四个动作 + `buyEnabled`/`sellEnabled` 两个可用性门 + 局终自动强平，覆盖「点击买卖/持有/观察按钮→执行交易→记 marker/operation→推进 tick→联动→局终强平」完整闭环。

**Architecture:** 在现有 `TrainingEngine.swift`（`@MainActor @Observable final class`）内**只新增方法**，不改 E5a 的存储态/init/make/accessor/preview。交易经 E3 `TradeCalculator`（`Result` 通道，入口 1a）→ E2 `PositionManager.buy/sell`（precondition 信任边界，§4.2.1）。tick 推进经 E1 `TickEngine.advance(steps:)`，步数由被点击面板周期的 `endGlobalIndex` 二分得出（plan v1.5 §4.1）。面板状态变更经 C1 `PanelViewState.reduce(.tradeTriggered/.periodComboSwitched)`（硬切 autoTracking）。局终强平经 E3 `forceCloseOnEnd`（裸 `SellQuote`，入口 1b）。

**Tech Stack:** Swift 6（strict concurrency）、Swift Testing（`@Test`/`@Suite`）、SwiftPM（`ios/Contracts`）；依赖既有 `TradeCalculator` / `PositionManager` / `TickEngine` / `PanelViewState` / `DrawdownAccumulator` / `BinarySearch.partitioningIndex`。

---

## 0. Scope（用户 2026-06-06 三项裁决落地）

**In scope（E5b 本 PR）：**
- `buy(panel:tier:) -> Result<TradeOperation, AppError>`
- `sell(panel:tier:) -> Result<TradeOperation, AppError>`
- `holdOrObserve(panel:)`
- `switchPeriodCombo(direction:)`
- `buyEnabled: Bool` / `sellEnabled: Bool`（D4 从 E5a 下放本 PR）
- 局终自动强平（§4.2.1 入口 1b；advance 到顶且有持仓时触发）

**Deferred（不在本 PR）：**
- `activateDrawingTool(_:)` / `deleteDrawing(at:)` —— **延后到 Wave 2 顺位 7 C8**（用户裁决 1）。理由：画线「激活」编排需 C8 viewport 计算 candleRange（C1 reducer effect `requestDrawingSnapshotAfterStoppingAnimator` 合约要求 handler 停动画→算 candleRange→派发 `setDrawingSnapshot`），viewport 在 C8（顺位 7）；C6 `DrawingToolManager` 自身注释也把 reducer 集成归后续 wave。E5a 的 `drawings: [DrawingObject]` 存储态保留不动。

**关键设计裁决（codex/opus 评审锚点）：**

| ID | 决策 | 依据 / 偏离声明 |
|---|---|---|
| **D1** | `buyEnabled` = `flow.canBuySell() && (∃ tier∈PositionTier.allCases: quoteBuy 成功)`；`sellEnabled` = `flow.canBuySell() && position.shares > 0` | 用户裁决 2（功能式）。**不臆造 tier 推导公式**（plan v1.5 L730 只说档位 caller-derived 未给公式）。满仓(现金耗尽)时所有档 `quoteBuy` 因 `totalCost<=cash` 失败→`buyEnabled=false`(disabled，符合 L734「满仓灰置」)；部分档成功(现金够某些档)→`true`，点不可买的档由 `buy` 返 `.insufficientCash`(toast，符合 L735「资金不足 toast」)。**偏离**：spec L1637-1638 把两门列 E5 accessor 块，E5a D4 已将「动作门」整体推 E5b，本 PR 实现。 |
| **D2** | 交易执行在「当前 tick 价」，记账后**才** advance | plan v1.5 §4.1「点按钮→推进 N 步」+「买入价=成交时收盘价」。entryTick=advance 前 `tick.globalTickIndex`；marker/operation 用 entryTick。 |
| **D3** | 步进量 = 被点击面板周期的 `stepsForPeriod`（首个 `endGlobalIndex > currentTick` 的 candle 的 `endGlobalIndex - currentTick`） | plan v1.5 §4.1 字面公式。`panel:PanelId` 决定取 upper/lower 哪个面板的 period。 |
| **D4** | buy/sell/holdOrObserve 均对**两个面板**派发 `.tradeTriggered`（硬切 autoTracking） | plan v1.5 L235「买入/卖出/持有/观察触发时：两面板立即中断 free-scrolling，硬切 auto-tracking」。 |
| **D5** | `TradeOperation.createdAt` = 成交 tick 的 `.m3` candle `datetime` | schema `created_at INTEGER NOT NULL` 与 spec/modules **未定义来源**。E5a init 已冻结、不引入新注入依赖；用成交 tick 的 m3 candle datetime = 确定性「模拟成交时刻」，与价源(.m3)同源、随 tick 单调，可测。**偏离登记**：非真实墙钟 created_at；若 codex 坚持墙钟则需改 E5a init 注入 clock(走 E6 RFC)。 |
| **D6** | `TradeOperation.totalCost`：buy=`quote.totalCost`(成本)，sell/强平=`quote.proceeds`(到手) | schema L437「total_cost = 本笔总成本/到手金额」字面双义。buy 无 stampDuty→`stampDuty:0`(BuyQuote 无该字段)。 |
| **D7** | 局终强平 operation：`period:.m3`、`positionTier:.tier5`、`direction:.sell`、`price`=maxTick 的 m3 收盘价 | plan v1.5 L751「按最后一根最小周期K线收盘价强制全平」；强平非面板点击事件，period 归驱动序列 .m3(与价源同)。 |
| **D8** | `switchPeriodCombo` 守 target 周期有数据(no-op 否则) + 守当前组合∈序列(no-op 否则) + 边界 no-op；**不** advance tick | 防 `stepsForPeriod`/渲染落在无数据周期(spec `stepsForPeriod` 用 `allCandles[period]!` 强解包)。周期切换非交易，不推进时间。损坏 resume 数据(组合∉序列)→no-op 不 trap。 |
| **D9** | `stepsForPeriod` 用 `allCandles[period] ?? []`(缺数据→0 步=不推进，不 crash)；`buy/sell` 失败/`holdOrObserve` 在 review 全 no-op/Result.failure，**不 trap** | 比 spec 强解包更防御。buy/sell 返 `Result` 是设计边界(§4.2 入口 1a 上游 E3 已守)，mode 门用 `.trade(.disabled)`(shouldShowToast=false=按钮态)。holdOrObserve 守 `flow.canAdvance()`(review=false→no-op)。 |

---

## 1. File Structure

| 文件 | 操作 | 责任 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | **Modify**（仅追加方法 + 更新顶部 scope 注释） | 新增 6 个 public 成员（`buy`/`sell`/`holdOrObserve`/`switchPeriodCombo`/`buyEnabled`/`sellEnabled`）+ 4 个 private helper（`period(of:)`/`stepsForPeriod`/`candleDatetime(atTick:)`/`advanceAndAccount(panel:)`/`forceCloseIfEnded`）。**不动** E5a 存储态/init/make/accessor/preview。 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift` | **Create** | E5b 动作专属测试 suite（`@MainActor @Suite`）。**新建独立文件**，不污染 E5a 的 `TrainingEngineCoreTests.swift`。 |
| `scripts/acceptance/plan_e5b_trainingengine_actions.sh` | **Create** | Linux 可跑结构闸门（want/wantn）。 |
| `docs/acceptance/2026-06-06-pr-e5b-trainingengine-actions.md` | **Create** | 非 coder 可执行验收清单（中文，action/expected/pass-fail）。 |

**为什么新建测试文件而非追加 E5a 文件：** E5a 的 `TrainingEngineCoreTests.swift` 是冻结交付（验收脚本 G9 锚定）；E5b 动作是独立行为面，单独 suite 更清晰、避免误改 E5a 测试。两文件可共存（不同 `@Suite` struct，Swift Testing 支持）。

---

## 2. 共享测试 fixture（Task 1 先落地，后续 Task 复用）

测试用 `@testable` 通道直调 internal `init`（绕过 `make` 的面板数据校验，便于构造最小 fixture）。

**两类 fixture：**
- **单周期交易 fixture**：双面板都设 `.m3`，则 `stepsForPeriod(.m3)` 每次 = 1（隔离交易机制，与多周期步进解耦）。
- **多周期 fixture**：含 `.m3`+其它周期，用于 `stepsForPeriod` 多周期步进 + `switchPeriodCombo`。

---

## Task 1: `buyEnabled` / `sellEnabled` 可用性门 + 共享 fixture

**Files:**
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift`（Create）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`

- [ ] **Step 1: 写失败测试 + fixture helper**

创建 `TrainingEngineActionsTests.swift`：

```swift
// E5b TrainingEngine 交易动作测试（Wave 2 顺位 3）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite struct TrainingEngineActionsTests {

    static let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)

    /// 单周期(.m3)交易 fixture：双面板都 .m3 → 每个动作步进 1 tick。
    /// closes[i] 对应 globalIndex==endGlobalIndex==i 的一根 .m3 K 线。
    static func tradeEngine(closes: [Double] = [10, 10, 10, 10, 10],
                            cash: Double = 100_000,
                            capital: Double = 100_000,
                            position: PositionManager = .init(),
                            mode: TrainingMode = .normal) -> TrainingEngine {
        let maxTick = closes.count - 1
        let flow: TrainingFlowController = switch mode {
        case .normal: NormalFlow(fees: fees, maxTick: maxTick)
        case .replay: ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: maxTick)
        case .review: ReviewFlow(record: previewRecord(finalTick: maxTick))
        }
        return TrainingEngine(
            flow: flow,
            allCandles: m3Candles(closes),
            maxTick: maxTick,
            initialCapital: capital,
            initialCashBalance: cash,
            initialPosition: position,
            initialUpperPeriod: .m3,
            initialLowerPeriod: .m15)
    }

    static func m3Candles(_ closes: [Double]) -> [Period: [KLineCandle]] {
        let arr = closes.enumerated().map { (i, c) in
            KLineCandle(period: .m3, datetime: Int64(i) * 180,
                        open: c, high: c, low: c, close: c,
                        volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        return [.m3: arr]
    }

    static func previewRecord(finalTick: Int) -> TrainingRecord {
        TrainingRecord(id: 1, trainingSetFilename: "t.sqlite", createdAt: 0,
                       stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 1,
                       totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: finalTick)
    }

    // MARK: - buyEnabled / sellEnabled

    @Test func buyEnabledTrueWhenAffordable() {
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 100_000, capital: 100_000)
        #expect(e.buyEnabled == true)
    }

    @Test func buyEnabledFalseWhenCashExhausted() {
        // 现金≈0（满仓态 emulation）：任何档 quoteBuy 都 totalCost>cash 失败 → false（disabled）
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 100_000,
                                 position: PositionManager(shares: 10_000, averageCost: 10, totalInvested: 100_000))
        #expect(e.buyEnabled == false)
    }

    @Test func buyEnabledFalseInReviewMode() {
        let e = Self.tradeEngine(cash: 100_000, mode: .review)
        #expect(e.buyEnabled == false)   // canBuySell()==false 短路
    }

    @Test func sellEnabledTrueWhenHolding() {
        let e = Self.tradeEngine(position: PositionManager(shares: 100, averageCost: 10, totalInvested: 1000))
        #expect(e.sellEnabled == true)
    }

    @Test func sellEnabledFalseWhenFlat() {
        let e = Self.tradeEngine(position: .init())
        #expect(e.sellEnabled == false)
    }

    @Test func sellEnabledFalseInReviewMode() {
        let e = Self.tradeEngine(position: PositionManager(shares: 100, averageCost: 10, totalInvested: 1000),
                                 mode: .review)
        #expect(e.sellEnabled == false)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 编译失败（`buyEnabled`/`sellEnabled` 未声明）。**本机若无 swift → 记录 `deferred-to-CI`，不得声称已跑。**

- [ ] **Step 3: 实现 `buyEnabled` / `sellEnabled`**

在 `TrainingEngine.swift` 的 `// MARK: - 派生 accessor` 区块**之后**新增（紧跟现有 accessor，复用 `currentPrice`/`currentTotalCapital`）：

```swift
    // MARK: - 动作可用性门（E5b / D1：功能式 ∃tier，无 tier 推导公式）

    /// 买入按钮可用：当前模式允许交易 **且** 存在某档 `quoteBuy` 成功。
    /// 满仓(现金耗尽)→所有档 totalCost>cash 失败→false(disabled，plan v1.5 L734)。
    /// 部分档成功→true；点不可买的档由 `buy` 返 `.insufficientCash`(toast，L735)——单一真值源，无 tier 公式臆造。
    public var buyEnabled: Bool {
        guard flow.canBuySell() else { return false }
        let total = currentTotalCapital, cash = cashBalance, price = currentPrice
        return PositionTier.allCases.contains { tier in
            if case .success = TradeCalculator.quoteBuy(totalCapital: total, cash: cash,
                                                        tier: tier, price: price, fees: fees) {
                return true
            }
            return false
        }
    }

    /// 卖出按钮可用：当前模式允许交易 **且** 有持仓（plan v1.5 L733 空仓灰置）。
    public var sellEnabled: Bool {
        flow.canBuySell() && position.shares > 0
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 6 个测试全 PASS，`0 failures`。本机无 swift → `deferred-to-CI`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift
git commit -m "feat(E5b): buyEnabled/sellEnabled 可用性门（功能式 ∃tier，D1）"
```

---

## Task 2: `switchPeriodCombo(direction:)` 周期组合切换

**Files:**
- Test: `TrainingEngineActionsTests.swift`
- Modify: `TrainingEngine.swift`

- [ ] **Step 1: 写失败测试**

追加多周期 fixture helper + 测试到 suite：

```swift
    // MARK: - switchPeriodCombo fixture

    /// 全 6 周期 fixture（switchPeriodCombo 需 target 周期有数据）。
    /// 各周期 endGlobalIndex 覆盖 0...maxEnd；m3 为驱动序列（连续 0..n）。
    static func sixPeriodCandles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, idx: Int, end: Int) -> KLineCandle {
            KLineCandle(period: p, datetime: Int64(idx) * 180,
                        open: 10, high: 11, low: 9, close: 10,
                        volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: idx, endGlobalIndex: end)
        }
        let m3 = (0..<m3Count).map { c(.m3, idx: $0, end: $0) }
        // 其它周期：每根覆盖一段 m3 tick，末根 endGlobalIndex == m3Count-1（覆盖 maxTick）
        let m15 = [c(.m15, idx: 0, end: 3), c(.m15, idx: 1, end: m3Count - 1)]
        let m60 = [c(.m60, idx: 0, end: 3), c(.m60, idx: 1, end: m3Count - 1)]
        let daily = [c(.daily, idx: 0, end: m3Count - 1)]
        let weekly = [c(.weekly, idx: 0, end: m3Count - 1)]
        let monthly = [c(.monthly, idx: 0, end: m3Count - 1)]
        return [.m3: m3, .m15: m15, .m60: m60, .daily: daily, .weekly: weekly, .monthly: monthly]
    }

    /// 用指定初始组合构造（默认 60m/日，与 spec L777 一致）。
    static func comboEngine(upper: Period = .m60, lower: Period = .daily) -> TrainingEngine {
        let candles = sixPeriodCandles()
        let maxTick = 7
        return TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: maxTick),
            allCandles: candles, maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: upper, initialLowerPeriod: lower)
    }

    // MARK: - switchPeriodCombo

    @Test func switchToLargerMovesComboUp() {
        let e = Self.comboEngine(upper: .m60, lower: .daily)   // index 2
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.upperPanel.period == .daily)
        #expect(e.lowerPanel.period == .weekly)
    }

    @Test func switchToSmallerMovesComboDown() {
        let e = Self.comboEngine(upper: .m60, lower: .daily)
        e.switchPeriodCombo(direction: .toSmaller)
        #expect(e.upperPanel.period == .m15)
        #expect(e.lowerPanel.period == .m60)
    }

    @Test func switchToLargerAtTopBoundaryNoops() {
        let e = Self.comboEngine(upper: .weekly, lower: .monthly)   // 末组合
        let before = (e.upperPanel.period, e.lowerPanel.period, e.upperPanel.revision)
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.upperPanel.period == before.0)
        #expect(e.lowerPanel.period == before.1)
        #expect(e.upperPanel.revision == before.2)   // 边界 no-op：无 revision bump
    }

    @Test func switchToSmallerAtBottomBoundaryNoops() {
        let e = Self.comboEngine(upper: .m3, lower: .m15)   // 首组合
        let before = (e.upperPanel.period, e.lowerPanel.period)
        e.switchPeriodCombo(direction: .toSmaller)
        #expect(e.upperPanel.period == before.0)
        #expect(e.lowerPanel.period == before.1)
    }

    @Test func switchResetsPanelsToAutoTrackingAndBumpsRevision() {
        let e = Self.comboEngine(upper: .m60, lower: .daily)
        // 先把面板推到 freeScrolling（模拟用户拖动）
        _ = e.upperPanel.reduce(.panStarted)
        let revBefore = e.upperPanel.revision
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision > revBefore)   // periodComboSwitched bump
    }

    @Test func switchDoesNotAdvanceTick() {
        let e = Self.comboEngine(upper: .m60, lower: .daily)
        let tickBefore = e.tick.globalTickIndex
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.tick.globalTickIndex == tickBefore)
    }

    @Test func switchNoopsWhenTargetPeriodHasNoData() {
        // 构造缺 .weekly 数据的 fixture（toLarger from 60m/日 需要 日/周）
        var candles = Self.sixPeriodCandles()
        candles[.weekly] = nil
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 7),
                               allCandles: candles, maxTick: 7,
                               initialCapital: 100_000, initialCashBalance: 100_000,
                               initialUpperPeriod: .m60, initialLowerPeriod: .daily)
        e.switchPeriodCombo(direction: .toLarger)
        #expect(e.upperPanel.period == .m60)   // 守卫 no-op
        #expect(e.lowerPanel.period == .daily)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 编译失败（`switchPeriodCombo` 未声明）。本机无 swift → `deferred-to-CI`。

- [ ] **Step 3: 实现 `switchPeriodCombo`**

新增区块（在动作门之后）：

```swift
    // MARK: - 周期组合切换（E5b / D8）

    /// 完整组合序列（plan v1.5 L782）：3m/15m ←→ 15m/60m ←→ 60m/日 ←→ 日/周 ←→ 周/月。
    /// upper=较细、lower=较粗，整体随 direction 平移一档。
    private static let periodCombos: [(upper: Period, lower: Period)] = [
        (.m3, .m15), (.m15, .m60), (.m60, .daily), (.daily, .weekly), (.weekly, .monthly)
    ]

    /// 两指上下滑切换周期组合（plan v1.5 §4.4）。
    /// - 边界 / 当前组合不在序列(损坏 resume) / target 周期无数据 → no-op（不 advance、不 bump）。
    /// - 命中 → 改双面板 period + 对两面板派发 `.periodComboSwitched`（硬切 autoTracking + clearPendingDrawing；
    ///   后者 effect 在 E5b 无消费者，画线延后顺位 7，故无 pending 可清，忽略安全）。
    public func switchPeriodCombo(direction: PeriodDirection) {
        let combos = TrainingEngine.periodCombos
        guard let cur = combos.firstIndex(where: {
            $0.upper == upperPanel.period && $0.lower == lowerPanel.period
        }) else { return }   // 当前组合不在序列（损坏 resume 数据）→ no-op
        let target = direction == .toLarger ? cur + 1 : cur - 1
        guard combos.indices.contains(target) else { return }   // 边界 → no-op
        let next = combos[target]
        // D8 数据完整性守卫：避免后续 stepsForPeriod/渲染落在无数据周期
        guard let u = allCandles[next.upper], !u.isEmpty,
              let l = allCandles[next.lower], !l.isEmpty else { return }
        upperPanel.period = next.upper
        lowerPanel.period = next.lower
        _ = upperPanel.reduce(.periodComboSwitched)
        _ = lowerPanel.reduce(.periodComboSwitched)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 新增 7 个测试 PASS。本机无 swift → `deferred-to-CI`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift
git commit -m "feat(E5b): switchPeriodCombo 周期组合切换（5 组合序列 + 数据守卫，D8）"
```

---

## Task 3: `holdOrObserve(panel:)` + advance/记账 helper

**Files:**
- Test: `TrainingEngineActionsTests.swift`
- Modify: `TrainingEngine.swift`

- [ ] **Step 1: 写失败测试**

```swift
    // MARK: - holdOrObserve

    @Test func holdOrObserveAdvancesOneTickSamePeriod() {
        let e = Self.tradeEngine(closes: [10, 11, 12, 13])   // 双面板 .m3，步进 1
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 1)
    }

    @Test func holdOrObserveRecordsNoMarkerOrOperation() {
        let e = Self.tradeEngine(closes: [10, 11, 12])
        e.holdOrObserve(panel: .upper)
        #expect(e.markers.isEmpty)
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func holdOrObserveHardSwitchesPanelsToAutoTracking() {
        let e = Self.tradeEngine(closes: [10, 11, 12])
        _ = e.upperPanel.reduce(.panStarted)   // → freeScrolling
        e.holdOrObserve(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.lowerPanel.interactionMode == .autoTracking)
    }

    @Test func holdOrObserveNoopsInReviewMode() {
        let e = Self.tradeEngine(closes: [10, 11, 12], mode: .review)
        // review initialTick == finalTick == maxTick == 2
        let before = e.tick.globalTickIndex
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == before)   // canAdvance()==false → no-op
    }

    @Test func holdOrObserveUpdatesDrawdownAtNewTick() {
        // 持仓 + 价格下跌：advance 后总资金下降 → maxDrawdown 上升
        let e = Self.tradeEngine(closes: [10, 8], cash: 0, capital: 1000,
                                 position: PositionManager(shares: 100, averageCost: 10, totalInvested: 1000))
        // tick0: total = 0 + 100*10 = 1000；advance 到 tick1 价 8：total = 800
        #expect(e.maxDrawdown == 0)
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.maxDrawdown == 200)   // peak 1000 - current 800
    }

    @Test func holdOrObserveStepsByClickedPanelPeriod() {
        // 多周期：upper=.m60（首根 end=3），从 tick0 点 upper → 步进到 3
        let e = Self.comboEngine(upper: .m60, lower: .daily)
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 3)   // stepsForPeriod(.m60) = 3 - 0
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 编译失败（`holdOrObserve` 未声明）。本机无 swift → `deferred-to-CI`。

- [ ] **Step 3: 实现 `holdOrObserve` + 三个 private helper**

```swift
    // MARK: - 持有 / 观察（E5b）

    /// 持有(有仓)/观察(空仓)：仅推进 tick（plan v1.5 L944「直接推进 1 根当前周期 K 线」），
    /// 无成交、无 marker/operation。review 模式 canAdvance()==false → no-op（capability matrix L836）。
    public func holdOrObserve(panel: PanelId) {
        guard flow.canAdvance() else { return }
        advanceAndAccount(panel: panel)
    }

    // MARK: - 私有：步进 + 联动 + 记账（buy/sell/holdOrObserve 共用）

    /// 被点击面板对应的周期。
    private func period(of panel: PanelId) -> Period {
        switch panel {
        case .upper: return upperPanel.period
        case .lower: return lowerPanel.period
        }
    }

    /// 步进量（plan v1.5 §4.1）：该周期首个 `endGlobalIndex > currentTick` 的 K 线的
    /// `endGlobalIndex - currentTick`；无后续 K 线 → 0（已到该周期末尾）。
    /// 用 `?? []`（D9）：缺数据 → 0 步=不推进，不 crash（比 spec 强解包防御）。
    private func stepsForPeriod(_ period: Period) -> Int {
        let candles = allCandles[period] ?? []
        let current = tick.globalTickIndex
        let idx = candles.partitioningIndex { $0.endGlobalIndex > current }
        guard idx < candles.count else { return 0 }
        return candles[idx].endGlobalIndex - current
    }

    /// 两面板硬切 autoTracking（D4，plan v1.5 L235）→ 推进 tick → 更新回撤 → 局终强平（Task 6 接入）。
    private func advanceAndAccount(panel: PanelId) {
        _ = upperPanel.reduce(.tradeTriggered)
        _ = lowerPanel.reduce(.tradeTriggered)
        _ = tick.advance(steps: stepsForPeriod(period(of: panel)))
        drawdown.update(currentCapital: currentTotalCapital)
        // Task 6 在此后追加 forceCloseIfEnded()
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 新增 6 个测试 PASS。本机无 swift → `deferred-to-CI`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift
git commit -m "feat(E5b): holdOrObserve + advance/记账 helper（步进 + 双面板硬切 + 回撤，D3/D4）"
```

---

## Task 4: `buy(panel:tier:)`

**Files:**
- Test: `TrainingEngineActionsTests.swift`
- Modify: `TrainingEngine.swift`

- [ ] **Step 1: 写失败测试**

```swift
    // MARK: - buy

    @Test func buySuccessDeductsCashAddsPositionAndAdvances() {
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 100_000, capital: 100_000)
        // tier1 = 20% of 100_000 / 10 = 2000 股；notional 20000；commission max(20000*0.0001=2,5)=5；totalCost 20005
        let r = e.buy(panel: .upper, tier: .tier1)
        guard case .success(let op) = r else { Issue.record("expected success"); return }
        #expect(e.position.shares == 2000)
        #expect(e.cashBalance == 100_000 - 20_005)
        #expect(op.direction == .buy)
        #expect(op.shares == 2000)
        #expect(op.positionTier == .tier1)
        #expect(op.price == 10)
        #expect(op.commission == 5)
        #expect(op.stampDuty == 0)
        #expect(op.totalCost == 20_005)
        #expect(op.globalTick == 0)        // entryTick（advance 前）
        #expect(op.period == .m3)
        #expect(op.createdAt == 0)          // tick0 m3 datetime = 0*180
        #expect(e.tick.globalTickIndex == 1)   // advance 1
    }

    @Test func buyRecordsBuyMarkerAtEntryTick() {
        let e = Self.tradeEngine(closes: [10, 10, 10])
        _ = e.buy(panel: .upper, tier: .tier1)
        #expect(e.markers.count == 1)
        #expect(e.markers[0].direction == .buy)
        #expect(e.markers[0].globalTick == 0)
        #expect(e.markers[0].price == 10)
    }

    @Test func buyUsesEntryTickPriceNotPostAdvancePrice() {
        // 价格在 advance 后变化；成交价必须是 entryTick 价(10)，非 advance 后价(99)
        let e = Self.tradeEngine(closes: [10, 99, 99])
        let r = e.buy(panel: .upper, tier: .tier1)
        guard case .success(let op) = r else { Issue.record("expected success"); return }
        #expect(op.price == 10)
    }

    @Test func buyFailureInsufficientCashLeavesStateUnchanged() {
        // 现金不足买任何一手：cash 50，price 100 → 任何档取整 0 股 或 totalCost>cash
        let e = Self.tradeEngine(closes: [100, 100, 100], cash: 50, capital: 50)
        let before = (e.position.shares, e.cashBalance, e.tick.globalTickIndex)
        let r = e.buy(panel: .upper, tier: .tier1)
        #expect(r == .failure(.trade(.insufficientCash)))
        #expect(e.position.shares == before.0)
        #expect(e.cashBalance == before.1)
        #expect(e.tick.globalTickIndex == before.2)   // 失败不 advance
        #expect(e.markers.isEmpty)
        #expect(e.tradeOperations.isEmpty)
    }

    @Test func buyFailsInReviewModeWithDisabled() {
        let e = Self.tradeEngine(closes: [10, 10, 10], mode: .review)
        let r = e.buy(panel: .upper, tier: .tier1)
        #expect(r == .failure(.trade(.disabled)))
    }

    @Test func buyHardSwitchesBothPanels() {
        let e = Self.tradeEngine(closes: [10, 10, 10])
        _ = e.upperPanel.reduce(.panStarted)
        _ = e.lowerPanel.reduce(.panStarted)
        _ = e.buy(panel: .upper, tier: .tier1)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.lowerPanel.interactionMode == .autoTracking)
    }

    @Test func buyAppendsTradeOperation() {
        let e = Self.tradeEngine(closes: [10, 10, 10])
        _ = e.buy(panel: .upper, tier: .tier1)
        #expect(e.tradeOperations.count == 1)
        #expect(e.tradeOperations[0].direction == .buy)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 编译失败（`buy` 未声明）。本机无 swift → `deferred-to-CI`。

- [ ] **Step 3: 实现 `buy` + `candleDatetime` helper**

```swift
    // MARK: - 买入（E5b / §4.2.1 入口 1a：E3 Result 通道 → position.buy precondition）

    /// 买入：当前 tick 价成交 → 记 marker/operation(entryTick) → 推进 → 联动 → 局终强平。
    /// 失败(模式不允许 / E3 校验失败)返 `.failure(.trade(...))`，**不** mutate、**不** advance（D9）。
    public func buy(panel: PanelId, tier: PositionTier) -> Result<TradeOperation, AppError> {
        guard flow.canBuySell() else { return .failure(.trade(.disabled)) }
        let price = currentPrice
        let entryTick = tick.globalTickIndex
        let p = period(of: panel)
        switch TradeCalculator.quoteBuy(totalCapital: currentTotalCapital, cash: cashBalance,
                                        tier: tier, price: price, fees: fees) {
        case .failure(let reason):
            return .failure(.trade(reason))
        case .success(let quote):
            position.buy(shares: quote.shares, totalCost: quote.totalCost)
            cashBalance -= quote.totalCost
            markers.append(TradeMarker(globalTick: entryTick, price: price, direction: .buy))
            let op = TradeOperation(
                globalTick: entryTick, period: p, direction: .buy, price: price,
                shares: quote.shares, positionTier: tier,
                commission: quote.commission, stampDuty: 0,   // D6：买入无印花税
                totalCost: quote.totalCost, createdAt: candleDatetime(atTick: entryTick))
            tradeOperations.append(op)
            advanceAndAccount(panel: panel)
            return .success(op)
        }
    }

    /// 成交时刻（D5）：成交 tick 的 `.m3` candle datetime；超末根夹取末根，缺数据 0。
    private func candleDatetime(atTick target: Int) -> Int64 {
        let m3 = allCandles[.m3] ?? []
        guard let last = m3.last else { return 0 }
        let idx = m3.partitioningIndex { $0.endGlobalIndex >= target }
        return idx < m3.count ? m3[idx].datetime : last.datetime
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 新增 7 个测试 PASS。本机无 swift → `deferred-to-CI`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift
git commit -m "feat(E5b): buy 买入（E3 Result→position.buy + marker/op + advance，D2/D5/D6）"
```

---

## Task 5: `sell(panel:tier:)`

**Files:**
- Test: `TrainingEngineActionsTests.swift`
- Modify: `TrainingEngine.swift`

- [ ] **Step 1: 写失败测试**

```swift
    // MARK: - sell

    @Test func sellSuccessAddsCashReducesPositionAndAdvances() {
        // 持仓 1000 股 @avg10；tier5 全清；price 10；notional 10000；commission max(1,5)=5；
        // stampDuty 10000*0.0005=5；proceeds 10000-5-5=9990
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        let r = e.sell(panel: .upper, tier: .tier5)
        guard case .success(let op) = r else { Issue.record("expected success"); return }
        #expect(e.position.shares == 0)
        #expect(e.cashBalance == 9990)
        #expect(op.direction == .sell)
        #expect(op.shares == 1000)
        #expect(op.positionTier == .tier5)
        #expect(op.commission == 5)
        #expect(op.stampDuty == 5)
        #expect(op.totalCost == 9990)        // D6：sell totalCost = proceeds
        #expect(op.globalTick == 0)
        #expect(e.tick.globalTickIndex == 1)
    }

    @Test func sellRecordsSellMarker() {
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        _ = e.sell(panel: .upper, tier: .tier5)
        #expect(e.markers.count == 1)
        #expect(e.markers[0].direction == .sell)
        #expect(e.markers[0].globalTick == 0)
    }

    @Test func sellPartialTierKeepsRemainingShares() {
        // 1000 股 tier1(20%)：目标 200 股 → floor100 = 200 股卖出；剩 800
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        let r = e.sell(panel: .upper, tier: .tier1)
        guard case .success(let op) = r else { Issue.record("expected success"); return }
        #expect(op.shares == 200)
        #expect(e.position.shares == 800)
    }

    @Test func sellFailsWhenFlatWithDisabled() {
        let e = Self.tradeEngine(closes: [10, 10, 10], position: .init())
        let r = e.sell(panel: .upper, tier: .tier5)
        #expect(r == .failure(.trade(.disabled)))   // quoteSell holding==0 → .disabled
    }

    @Test func sellFailsInsufficientHoldingWhenRoundsToZero() {
        // 持仓 50 股(<100)，非 tier5：floor(50*0.2=10 /100)*100 = 0 → insufficientHolding
        let e = Self.tradeEngine(closes: [10, 10, 10], cash: 0, capital: 500,
                                 position: PositionManager(shares: 50, averageCost: 10, totalInvested: 500))
        let r = e.sell(panel: .upper, tier: .tier1)
        #expect(r == .failure(.trade(.insufficientHolding)))
        #expect(e.position.shares == 50)        // 失败不 mutate
        #expect(e.tick.globalTickIndex == 0)    // 失败不 advance
    }

    @Test func sellFailsInReviewModeWithDisabled() {
        let e = Self.tradeEngine(closes: [10, 10, 10], mode: .review,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        let r = e.sell(panel: .upper, tier: .tier5)
        #expect(r == .failure(.trade(.disabled)))
    }
```

> 注：`tradeEngine` 的 `position` 参数已存在（Task 1 签名含 `position`）；review 模式 + position 组合测试直接传入。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 编译失败（`sell` 未声明）。本机无 swift → `deferred-to-CI`。

- [ ] **Step 3: 实现 `sell`**

```swift
    // MARK: - 卖出（E5b / §4.2.1 入口 1a）

    /// 卖出：当前 tick 价成交 → 记 marker/operation(entryTick) → 推进 → 联动 → 局终强平。
    public func sell(panel: PanelId, tier: PositionTier) -> Result<TradeOperation, AppError> {
        guard flow.canBuySell() else { return .failure(.trade(.disabled)) }
        let price = currentPrice
        let entryTick = tick.globalTickIndex
        let p = period(of: panel)
        switch TradeCalculator.quoteSell(holding: position.shares, averageCost: position.averageCost,
                                         tier: tier, price: price, fees: fees) {
        case .failure(let reason):
            return .failure(.trade(reason))
        case .success(let quote):
            position.sell(shares: quote.shares)
            cashBalance += quote.proceeds
            markers.append(TradeMarker(globalTick: entryTick, price: price, direction: .sell))
            let op = TradeOperation(
                globalTick: entryTick, period: p, direction: .sell, price: price,
                shares: quote.shares, positionTier: tier,
                commission: quote.commission, stampDuty: quote.stampDuty,
                totalCost: quote.proceeds,   // D6：sell totalCost = 到手 proceeds
                createdAt: candleDatetime(atTick: entryTick))
            tradeOperations.append(op)
            advanceAndAccount(panel: panel)
            return .success(op)
        }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 新增 6 个测试 PASS。本机无 swift → `deferred-to-CI`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift
git commit -m "feat(E5b): sell 卖出（E3 Result→position.sell + 印花税 + proceeds，D6）"
```

---

## Task 6: 局终自动强平（`forceCloseIfEnded`，接入 `advanceAndAccount`）

**Files:**
- Test: `TrainingEngineActionsTests.swift`
- Modify: `TrainingEngine.swift`

- [ ] **Step 1: 写失败测试**

```swift
    // MARK: - 局终强平

    @Test func advancingToEndWithHoldingForceCloses() {
        // maxTick=1；持仓 1000@10；price 末根 10。holdOrObserve 推进到 tick1(=maxTick)→强平
        let e = Self.tradeEngine(closes: [10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.position.shares == 0)             // 已强平
        #expect(e.cashBalance == 9990)              // proceeds：notional10000 - comm5 - stamp5
        // 强平记 sell marker + operation
        #expect(e.markers.contains { $0.direction == .sell && $0.globalTick == 1 })
        let fc = e.tradeOperations.last
        #expect(fc?.direction == .sell)
        #expect(fc?.positionTier == .tier5)
        #expect(fc?.period == .m3)                  // D7
        #expect(fc?.globalTick == 1)
        #expect(fc?.shares == 1000)
        #expect(fc?.stampDuty == 5)
    }

    @Test func advancingToEndWithoutHoldingDoesNotForceClose() {
        let e = Self.tradeEngine(closes: [10, 10], position: .init())
        e.holdOrObserve(panel: .upper)
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.tradeOperations.isEmpty)          // 无持仓 → 无强平
        #expect(e.markers.isEmpty)
    }

    @Test func forceCloseIsIdempotentAcrossRepeatedEndAdvances() {
        let e = Self.tradeEngine(closes: [10, 10], cash: 0, capital: 10_000,
                                 position: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000))
        e.holdOrObserve(panel: .upper)              // 到顶强平
        let opsAfterFirst = e.tradeOperations.count
        e.holdOrObserve(panel: .upper)              // 已到顶 + 已空仓 → 无新强平
        #expect(e.tradeOperations.count == opsAfterFirst)
        #expect(e.position.shares == 0)
    }

    @Test func buyThatAdvancesToEndTriggersForceClose() {
        // maxTick=1，tick0 买入推进到 tick1(=maxTick) → 持仓被强平
        let e = Self.tradeEngine(closes: [10, 10], cash: 100_000, capital: 100_000)
        let r = e.buy(panel: .upper, tier: .tier1)
        guard case .success = r else { Issue.record("expected success"); return }
        #expect(e.tick.globalTickIndex == 1)
        #expect(e.position.shares == 0)             // 买入后立即被局终强平
        // tradeOperations：buy + 强平 sell 两笔
        #expect(e.tradeOperations.count == 2)
        #expect(e.tradeOperations[0].direction == .buy)
        #expect(e.tradeOperations[1].direction == .sell)
        #expect(e.tradeOperations[1].positionTier == .tier5)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 4 个新测试 FAIL（强平未接入，advance 到顶后持仓仍在）。本机无 swift → `deferred-to-CI`。

- [ ] **Step 3: 实现 `forceCloseIfEnded` + 接入 `advanceAndAccount`**

在 `advanceAndAccount` 末尾追加调用：

```swift
    private func advanceAndAccount(panel: PanelId) {
        _ = upperPanel.reduce(.tradeTriggered)
        _ = lowerPanel.reduce(.tradeTriggered)
        _ = tick.advance(steps: stepsForPeriod(period(of: panel)))
        drawdown.update(currentCapital: currentTotalCapital)
        forceCloseIfEnded()
    }
```

新增方法（在 sell 之后）：

```swift
    // MARK: - 局终自动强平（E5b / §4.2.1 入口 1b / D7）

    /// 推进到 `>= maxTick` 且仍有持仓 → 按末根 .m3 收盘价强制全平（plan v1.5 L751）。
    /// 走 E3 `forceCloseOnEnd`（裸 SellQuote，holding==position.shares 满足入口 1b caller 不变量）。
    /// 幂等：强平后 shares==0，再次到顶 guard 短路。
    private func forceCloseIfEnded() {
        guard tick.globalTickIndex >= tick.maxTick, position.shares > 0 else { return }
        let price = currentPrice
        let quote = TradeCalculator.forceCloseOnEnd(
            holding: position.shares, averageCost: position.averageCost, price: price, fees: fees)
        guard quote.shares > 0 else { return }   // 全零报价(非法 price)→ no-op
        let tickAtClose = tick.globalTickIndex
        position.sell(shares: quote.shares)
        cashBalance += quote.proceeds
        markers.append(TradeMarker(globalTick: tickAtClose, price: price, direction: .sell))
        tradeOperations.append(TradeOperation(
            globalTick: tickAtClose, period: .m3, direction: .sell, price: price,
            shares: quote.shares, positionTier: .tier5,
            commission: quote.commission, stampDuty: quote.stampDuty,
            totalCost: quote.proceeds, createdAt: candleDatetime(atTick: tickAtClose)))
        drawdown.update(currentCapital: currentTotalCapital)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingEngineActionsTests`
Expected: 全部新测试 PASS；E5b 全套绿。本机无 swift → `deferred-to-CI`。

- [ ] **Step 5: 全量回归 + Commit**

Run: `cd ios/Contracts && swift test`
Expected: 全量 `0 failures`（无 E5a/其它模块回归）。本机无 swift → `deferred-to-CI`。

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift
git commit -m "feat(E5b): 局终自动强平 forceCloseIfEnded（§4.2.1 入口1b + 幂等，D7）"
```

---

## Task 7: scope 注释更新 + 验收脚本 + 验收清单

**Files:**
- Modify: `TrainingEngine.swift`（顶部注释）
- Create: `scripts/acceptance/plan_e5b_trainingengine_actions.sh`
- Create: `docs/acceptance/2026-06-06-pr-e5b-trainingengine-actions.md`

- [ ] **Step 1: 更新 `TrainingEngine.swift` 顶部 scope 注释**

把现有 L1-7 注释块的 E5b 说明改为（surgical，只改这段）：

旧：
```swift
// 范围：init + 运行时状态 + accessors + onSceneActivated（scenePhase 中继）+ preview。
//   交易动作 buy/sell/holdOrObserve/switchPeriodCombo/activateDrawingTool/deleteDrawing
//   属 E5b（Wave 2 顺位 3），本 PR 不实现。
// 设计判定见 docs/superpowers/plans/2026-06-05-pr-e5a-trainingengine-core.md D1-D8。
```

新：
```swift
// 范围（E5a 顺位 2）：init + 运行时状态 + accessors + onSceneActivated（scenePhase 中继）+ preview。
// E5b（顺位 3，本文件后半）：buy/sell/holdOrObserve/switchPeriodCombo + buyEnabled/sellEnabled
//   + 局终自动强平（§4.2.1 入口 1b）。
//   activateDrawingTool/deleteDrawing 延后 Wave 2 顺位 7 C8（画线激活编排需 C8 viewport，用户 2026-06-06 裁决）。
// 设计判定见 docs/superpowers/plans/2026-06-05-pr-e5a-trainingengine-core.md（E5a）
//   + docs/superpowers/plans/2026-06-06-pr-e5b-trainingengine-actions.md（E5b D1-D9）。
```

- [ ] **Step 2: 创建验收脚本**

`scripts/acceptance/plan_e5b_trainingengine_actions.sh`：

```bash
#!/usr/bin/env bash
# 验收脚本 — E5b TrainingEngine 交易动作（Wave 2 顺位 3）
# 仅含 Linux 可跑的结构闸门；swift test / Catalyst 见验收清单 CI 行。
set -uo pipefail
cd "$(dirname "$0")/../.."
TE="ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift"
TS="ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift"
fail=0
ok(){ echo "OK:   $1"; }
bad(){ echo "FAIL: $1"; fail=1; }
want(){  if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # 期望命中
wantn(){ if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # 期望不命中

echo "== G1: 6 个 E5b public 成员落地 =="
want "buy(panel:tier:)"            "grep -qE 'public func buy\(panel: PanelId, tier: PositionTier\)' '$TE'"
want "sell(panel:tier:)"           "grep -qE 'public func sell\(panel: PanelId, tier: PositionTier\)' '$TE'"
want "holdOrObserve(panel:)"       "grep -qE 'public func holdOrObserve\(panel: PanelId\)' '$TE'"
want "switchPeriodCombo(direction:)" "grep -qE 'public func switchPeriodCombo\(direction: PeriodDirection\)' '$TE'"
want "buyEnabled"                  "grep -qE 'public var buyEnabled: Bool' '$TE'"
want "sellEnabled"                 "grep -qE 'public var sellEnabled: Bool' '$TE'"

echo "== G2: 画线方法延后顺位 7（本 PR 不实现）=="
wantn "未越界实现 activateDrawingTool" "grep -qE 'func activateDrawingTool' '$TE'"
wantn "未越界实现 deleteDrawing"       "grep -qE 'func deleteDrawing' '$TE'"

echo "== G3: 关键设计锚点 =="
want "buyEnabled 功能式 ∃tier（D1）"      "grep -q 'PositionTier.allCases.contains' '$TE'"
want "买卖经 E3 Result 通道（入口 1a）"   "grep -q 'TradeCalculator.quoteBuy' '$TE'"
want "卖出 quoteSell"                    "grep -q 'TradeCalculator.quoteSell' '$TE'"
want "局终强平 forceCloseOnEnd（入口 1b）" "grep -q 'TradeCalculator.forceCloseOnEnd' '$TE'"
want "强平接入 advance 路径"             "grep -q 'forceCloseIfEnded' '$TE'"
want "两面板硬切 tradeTriggered（D4）"    "grep -q 'reduce(.tradeTriggered)' '$TE'"
want "周期切换 periodComboSwitched"      "grep -q 'reduce(.periodComboSwitched)' '$TE'"
want "周期组合序列（D8）"                "grep -q 'periodCombos' '$TE'"
want "步进二分（D3）"                    "grep -q 'partitioningIndex' '$TE'"
want "createdAt 用 m3 datetime（D5）"     "grep -q 'candleDatetime' '$TE'"

echo "== G4: E5a 既有面未被破坏（仍在）=="
want "make() 仍是 public 构造路径"  "grep -qE 'public static func make\(' '$TE'"
want "currentTotalCapital accessor" "grep -q 'public var currentTotalCapital' '$TE'"
want "onSceneActivated 仍在"        "grep -q 'public func onSceneActivated' '$TE'"

echo "== G5: 测试存在且用 Swift Testing =="
want "测试文件存在"  "test -f '$TS'"
want "import Testing" "grep -q 'import Testing' '$TS'"
want "@Test 用例"     "grep -q '@Test' '$TS'"
want "强平测试"       "grep -q 'ForceClose' '$TS'"
want "buyEnabled 测试" "grep -q 'buyEnabled' '$TS'"

echo "== G6: 作用域 —— diff 只动允许文件 =="
base="$(git merge-base origin/main HEAD 2>/dev/null || echo origin/main)"
changed="$(git diff --name-only "$base"...HEAD 2>/dev/null || true)"
if [ -n "$changed" ]; then
  bados="$(echo "$changed" | grep -vE '^(ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine\.swift|ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests\.swift|scripts/acceptance/plan_e5b_trainingengine_actions\.sh|docs/(acceptance|superpowers/plans)/.*)$' || true)"
  if [ -n "$bados" ]; then bad "越界文件: $bados"; else ok "diff 仅含允许文件"; fi
else
  ok "无 diff（或 base 不可解析，CI 再核）"
fi

echo
if [ "$fail" = 0 ]; then echo "=== ALL E5b ACCEPTANCE CHECKS PASSED ==="; else echo "=== E5b ACCEPTANCE FAILED ==="; fi
exit $fail
```

设可执行：`chmod +x scripts/acceptance/plan_e5b_trainingengine_actions.sh`

- [ ] **Step 3: 跑验收脚本**

Run: `bash scripts/acceptance/plan_e5b_trainingengine_actions.sh; echo exit=$?`
Expected: 末行 `=== ALL E5b ACCEPTANCE CHECKS PASSED ===`，`exit=0`。

- [ ] **Step 4: 创建验收清单**（非 coder 可执行，中文，二元可决）

`docs/acceptance/2026-06-06-pr-e5b-trainingengine-actions.md`：

```markdown
# 验收清单 — E5b TrainingEngine 交易动作（Wave 2 顺位 3）

> 语言：中文；判定二元可决。本模块给 E5a 运行时核心补全「可操作」能力：买入/卖出/持有观察
> 四个动作 + 买卖按钮可用性门 + 局终自动强平。画线方法（activateDrawingTool/deleteDrawing）
> 延后顺位 7 C8。**本机 Linux 无 swift**，标注 [CI] 的行在 GitHub Actions（macos-15）执行，
> 不可在本机谎称通过。

## 一、自动闸门（命令可机器核验）

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | `bash scripts/acceptance/plan_e5b_trainingengine_actions.sh; echo exit=$?` | 末行 `=== ALL E5b ACCEPTANCE CHECKS PASSED ===`，`exit=0` | ☐ |
| 2 | [CI] `cd ios/Contracts && swift build` | `Build complete!` | ☐ |
| 3 | [CI] `cd ios/Contracts && swift test --filter TrainingEngineActionsTests` | `0 failures`，全部 @Test 绿 | ☐ |
| 4 | [CI] `cd ios/Contracts && swift test` | 全量 `0 failures`（无回归） | ☐ |
| 5 | [CI Catalyst 必绿闸门] `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/e5b-catalyst` | `** TEST BUILD SUCCEEDED **`（required check `Mac Catalyst build-for-testing on macos-15`，不可 bypass） | ☐ |

## 二、业务规则验收（映射到具名测试）

| # | 规则 | 验证测试 | 期望 | 通过 |
|---|---|---|---|---|
| 6 | 买入：当前 tick 价成交、扣现金、加持仓、推进、记 buy marker + operation（entryTick） | `buySuccessDeductsCashAddsPositionAndAdvances` / `buyRecordsBuyMarkerAtEntryTick` | PASS | ☐ |
| 7 | 买入用 entryTick 价（非 advance 后价） | `buyUsesEntryTickPriceNotPostAdvancePrice` | PASS | ☐ |
| 8 | 买入失败（资金不足）不 mutate、不 advance、返 `.trade(.insufficientCash)` | `buyFailureInsufficientCashLeavesStateUnchanged` | PASS | ☐ |
| 9 | review 模式买入返 `.trade(.disabled)` | `buyFailsInReviewModeWithDisabled` | PASS | ☐ |
| 10 | 卖出：加现金（proceeds）、减持仓、印花税>0、tier5 清仓、totalCost=proceeds | `sellSuccessAddsCashReducesPositionAndAdvances` / `sellPartialTierKeepsRemainingShares` | PASS | ☐ |
| 11 | 卖出失败：空仓 `.disabled`、取整为 0 `.insufficientHolding`、review `.disabled` | `sellFailsWhenFlatWithDisabled` / `sellFailsInsufficientHoldingWhenRoundsToZero` / `sellFailsInReviewModeWithDisabled` | PASS | ☐ |
| 12 | 持有/观察：仅推进 tick、无 marker/operation、按点击面板周期步进、更新回撤 | `holdOrObserveAdvancesOneTickSamePeriod` / `holdOrObserveRecordsNoMarkerOrOperation` / `holdOrObserveStepsByClickedPanelPeriod` / `holdOrObserveUpdatesDrawdownAtNewTick` | PASS | ☐ |
| 13 | 持有/观察 review 模式 no-op（canAdvance false） | `holdOrObserveNoopsInReviewMode` | PASS | ☐ |
| 14 | 买卖持观均硬切两面板 autoTracking（plan L235） | `buyHardSwitchesBothPanels` / `holdOrObserveHardSwitchesPanelsToAutoTracking` | PASS | ☐ |
| 15 | 局终强平：到顶有持仓→全平、加 proceeds、记 tier5/.m3/.sell marker+operation（D7） | `advancingToEndWithHoldingForceCloses` | PASS | ☐ |
| 16 | 局终强平：无持仓不触发；幂等（重复到顶不重复平） | `advancingToEndWithoutHoldingDoesNotForceClose` / `forceCloseIsIdempotentAcrossRepeatedEndAdvances` | PASS | ☐ |
| 17 | 买入推进到顶触发强平（buy + 强平两笔 operation） | `buyThatAdvancesToEndTriggersForceClose` | PASS | ☐ |
| 18 | buyEnabled：可买 true / 现金耗尽 false / review false | `buyEnabledTrueWhenAffordable` / `buyEnabledFalseWhenCashExhausted` / `buyEnabledFalseInReviewMode` | PASS | ☐ |
| 19 | sellEnabled：有仓 true / 空仓 false / review false | `sellEnabledTrueWhenHolding` / `sellEnabledFalseWhenFlat` / `sellEnabledFalseInReviewMode` | PASS | ☐ |
| 20 | 周期组合：toLarger/toSmaller 平移、边界 no-op、重置 autoTracking+bump、不 advance、无数据 no-op | `switchToLargerMovesComboUp` / `switchToSmallerMovesComboDown` / `switchToLargerAtTopBoundaryNoops` / `switchToSmallerAtBottomBoundaryNoops` / `switchResetsPanelsToAutoTrackingAndBumpsRevision` / `switchDoesNotAdvanceTick` / `switchNoopsWhenTargetPeriodHasNoData` | PASS | ☐ |

## 三、流程合规与偏差

| # | 项 | 期望 | 通过 |
|---|---|---|---|
| 21 | 作用域守卫：G2 无画线方法（延后顺位 7）+ G4 E5a 面未破坏 | grep 命中/不命中均如期 | ☐ |
| 22 | 偏差登记：D5（createdAt=m3 datetime，非墙钟）/ D8（switchPeriodCombo 数据守卫）/ D9（防御式 ?? []）/ 画线延后顺位 7 | PR body 已列 | ☐ |
| 23 | codex/opus 对抗性评审 branch-diff | verdict `approve`（收敛） | ☐ |
```

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift scripts/acceptance/plan_e5b_trainingengine_actions.sh docs/acceptance/2026-06-06-pr-e5b-trainingengine-actions.md
git commit -m "chore(E5b): scope 注释更新 + 验收脚本 + 非 coder 验收清单"
```

---

## 3. 验收（completion gate）

- [ ] 本地结构闸门：`bash scripts/acceptance/plan_e5b_trainingengine_actions.sh` → `exit=0`
- [ ] [CI] `cd ios/Contracts && swift build` → `Build complete!`
- [ ] [CI] `cd ios/Contracts && swift test` → 全量 `0 failures`
- [ ] [CI] Mac Catalyst `build-for-testing` → `** TEST BUILD SUCCEEDED **`
- [ ] opus 4.8 xhigh `--scope branch-diff` 对抗性评审 → `approve`（收敛）

---

## 4. Self-Review（写完计划后自查）

**1. Spec coverage（逐项 vs modules §E5 L1618-1638 + plan v1.5 §4.1-4.4 / §5.0）：**
- `buy` L1618 → Task 4 ✅；`sell` L1619 → Task 5 ✅；`holdOrObserve` L1620 → Task 3 ✅；`switchPeriodCombo` L1621 → Task 2 ✅；`buyEnabled`/`sellEnabled` L1637-1638 → Task 1 ✅。
- 步进规则 plan §4.1 → Task 3 `stepsForPeriod` ✅；交易数学 §4.2 → 全经 E3（已落地）✅；marker §4.3 → buy/sell/强平 append ✅；周期组合 §4.4 → Task 2 ✅；局终强平 §4.2.1 入口 1b + L751 → Task 6 ✅；硬切 autoTracking L235 → `advanceAndAccount` ✅。
- **有意 OUT-OF-SCOPE（用户裁决）**：`activateDrawingTool`/`deleteDrawing` → 顺位 7 C8。
- **保持 E5a 不动**：存储态/init/make/accessor/preview/onSceneActivated。

**2. Placeholder scan：** 无 TBD/TODO/"add error handling"；每个 code step 含完整可编译代码。

**3. Type consistency：**
- `TradeCalculator.quoteBuy(totalCapital:cash:tier:price:fees:)` / `quoteSell(holding:averageCost:tier:price:fees:)` / `forceCloseOnEnd(holding:averageCost:price:fees:)` —— 对齐 `TradeCalculator.swift` 实签名 ✅。
- `BuyQuote.{shares,notional,commission,totalCost}` / `SellQuote.{shares,notional,commission,stampDuty,proceeds}` ✅。
- `PositionManager.buy(shares:totalCost:)` / `sell(shares:)`（mutating，precondition）✅。
- `TickEngine.advance(steps:)`（mutating → Bool）✅。
- `PanelViewState.reduce(_:) -> ChartReduceEffect`，`.period` 是 `var`（可直接赋值）✅；`ChartAction.{tradeTriggered,periodComboSwitched,panStarted}` ✅。
- `TradeOperation(globalTick:period:direction:price:shares:positionTier:commission:stampDuty:totalCost:createdAt:)` ✅；`TradeMarker(globalTick:price:direction:)` ✅。
- `DrawdownAccumulator.update(currentCapital:)`（mutating）✅。
- `partitioningIndex(where:)` 返 Index（`Array` 下 == Int）✅。
- `PositionTier.allCases`（CaseIterable）✅；`PeriodDirection.{toLarger,toSmaller}` ✅；`PanelId.{upper,lower}` ✅；`AppError.trade(TradeReason)` ✅。
- E5a 已有 `currentPrice`(private) / `currentTotalCapital` / `fees` / `tick`/`position`/`cashBalance`/`markers`/`tradeOperations`/`drawdown`/`upperPanel`/`lowerPanel`（均 `private(set) var`，类内可写）✅。

**4. TDD/粒度：** 每 Task = 失败测试→跑失败→最小实现→跑通过→commit；helper 随首消费者引入并经 public API 测试。

**5. 风险登记（交对抗性评审）：**
- D5 createdAt=m3 datetime：非墙钟，确定性优先（E5a init 冻结不注入 clock）。
- D8 switchPeriodCombo 数据守卫 + 组合∉序列 no-op：比 spec 强解包防御；周期切换不 advance。
- D9 `stepsForPeriod` 用 `?? []`、buy/sell mode 门返 `.trade(.disabled)`：防御 + Result 边界，不 trap。
- 强平 period=.m3 / 强平 op 不作为 buy/sell 返回值（仅记 tradeOperations）：D7 / 局终副作用。
```

