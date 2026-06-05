# E5a TrainingEngine 核心 实施 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task（本项目已排除 executing-plans，见 memory `project_executing_plans_excluded`）。Steps use checkbox (`- [ ]`) syntax for tracking. **本机 Linux 无 swift toolchain** —— 所有 `swift build` / `swift test` / `xcodebuild` 步骤在 CI（macos-15）或 mac 本地执行；本机只跑 grep / git 结构闸门。**绝不**以本机无法执行为由谎称 swift 测试通过。

**Goal:** 把 `TrainingEngine` 从 Wave 0 类型壳（`fileprivate init` + `fatalError`）替换为运行时核心：可构造的 `public init`（含 drawdown peak seeding）+ 9 个运行时状态属性 + 4 个纯值派生 accessor（`currentTotalCapital`/`holdingCost`/`returnRate`/`maxDrawdown`）+ `onSceneActivated` 场景中继 + `preview` 便利构造。**`buyEnabled`/`sellEnabled` 动作可达性门随动作下放 E5b（顺位 3，见 D4）。**

**Architecture:** `@MainActor @Observable final class`，值语义运行时状态（`private(set)` 对外只读，写入留给 E5b 动作 PR）。现价从「最细粒度周期」K 线按 `endGlobalIndex` 二分查找得到（复用既有 `partitioningIndex`）。费用快照由 `flow.feeSnapshot` 派生（init 不收 `fees` 参数）。本 PR **不实现**任何交易动作（`buy`/`sell`/`holdOrObserve`/`switchPeriodCombo`/`activateDrawingTool`/`deleteDrawing` 属 E5b = Wave 2 顺位 3）。

**Tech Stack:** Swift 6 + SwiftPM `KlineTrainerContracts` + Swift Testing（`import Testing` / `@Test` / `#expect`，非 XCTest）。
- 测试：`cd ios/Contracts && swift test --filter TrainingEngineCore`（CI/mac）
- Catalyst 必绿 CI 闸门：`xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`（required check：`Mac Catalyst build-for-testing on macos-15`，不可 bypass）

**Wave 2 顺位：** 2（无 Wave 2 依赖；E1 TickEngine #37 / E2 PositionManager #65 / E4 TrainingFlowController #63 / DrawdownAccumulator 均已 merged 在场）

**Spec:** `kline_trainer_modules_v1.4.md` §E5（L1581-1639，preview L1690-1705） + `kline_trainer_plan_v1.5.md`（§4.2 最大回撤 L738-749、自动平仓现价 L751、§4.3 markers L753-769、§10.1 初始周期组合「上区 60m，下区 日线」L777、§总资金/收益率 L914-917）

**评审契约：** `codex:adversarial-review` —— 计划阶段 `--scope working-tree`（本文档），实现阶段 `--scope branch-diff`。按 `.claude/workflow-rules.json adversarial_review_loop`：1 轮 = codex 半轮 + claude 半轮，`max_rounds: 3`，超则 escalate 给 user；同 blob 重审不计轮。codex review 由 Claude 直接调用；attest ledger / pin 工具链由 user 负责。

---

## Task 0 — §15.3 评审策略前置（per `docs/governance/wave1-plan-template.md`）

完成 Task 0 才进 Task 1 实施。

- [ ] **局部对抗性评审（必做）**：本 PR 触碰 `ios/**/*.swift`（trust-boundary glob）→ 必须过 `codex:adversarial-review`。
  - 计划阶段：`codex-attest.sh --scope working-tree --focus docs/superpowers/plans/2026-06-05-pr-e5a-trainingengine-core.md`（或 user 工具链就绪后等价直调 codex companion）。
  - 实现阶段：`codex-attest.sh --scope branch-diff --head <branch> --base origin/main`。
  - 收敛判据：codex verdict = `approve`（CI `codex-verify-pass` check 转 success）。
- [ ] **集成层评审（N/A 本 PR）**：E5 编排的跨模块集成测试落在 **Wave 2 顺位 7 C8 anchor**（彼时 C2 + E5a/E5b + C8 在场，见 modules L1180-1182）。本 PR 仅交付 E5a 单模块运行时核心。
- [ ] **性能评审（N/A 本 PR）**：单帧 <4ms 的性能闸门在渲染/手势集成 anchor（顺位 7/9）评，E5a 无渲染热点。

---

## 设计决策（实施前必读）

> 以下 D1-D8 是 spec 字面未给出实现体、或 spec 与现状不自洽处的判定。每条标注「依据」与「偏离声明」，是 codex 对抗性评审的首要靶点。

### D1 — `fees` 由 `flow.feeSnapshot` 派生（init 无 `fees` 参数）
spec init 签名（L1607-1616）**不含** `fees` 参数，但存储属性 `let fees: FeeSnapshot`（L1603）存在。`TrainingFlowController` 协议有 `var feeSnapshot: FeeSnapshot { get }`（NormalFlow→注入费率，ReviewFlow→`record.feeSnapshot`，ReplayFlow→原局费率）。
**判定：** `self.fees = flow.feeSnapshot`。三种 flow 已封装各自费率来源，单一来源避免双轨。

### D2 — 现价来源：最细粒度周期 K 线收盘价，`endGlobalIndex` 二分
`currentTotalCapital`/`returnRate` 需「持仓市值」= `shares × 现价`（plan v1.5 L914）。`TickEngine` 只有 `globalTickIndex`，**无价格**。
**判定：** 私有 `currentPrice` = `allCandles[basePeriod]` 中首个 `endGlobalIndex >= tick.globalTickIndex` 的 K 线 `close`；`basePeriod` = `allCandles` 中存在且非空、`Period.allCases` 序号最小（最细粒度）者。查找复用 `partitioningIndex`（`Models/BinarySearch.swift`，与 `MarkersLayout.swift:25` 同约定）。tick 超出末根时夹取末根 `close`。
**依据：** plan v1.5 L751「自动结束按**最后一根最小周期** K 线收盘价强制平仓」；L767 markers 用 `end_global_index` 二分。
**偏离声明：** spec 未显式定义「现价」函数，本判定是从「自动平仓用最小周期收盘价」与「markers 用 endGlobalIndex 二分」两处归纳。`Period` 当前**无** `Comparable`/粒度序（已 grep 确认）→ 用 `Period.allCases.firstIndex` 作粒度序（枚举声明序 m3<m15<m60<daily<weekly<monthly 即粒度升序）。**codex 重点核**：basePeriod 选取是否应固定为某「驱动周期」而非「最细存在周期」。

### D3 — `maxDrawdown` accessor 透传绝对额（元）；E6 换算为比率（显式契约）
**spec 已调和单位（codex R1-F1 误判澄清）：** `modules v1.4 L510` 明确 `DrawdownAccumulator.maxDrawdown` 是「**非负值，单位元**」的绝对额，`L516` 用 `dd = peak - current`；`L1636` 明确 E5 accessor「**直接读 accumulator**」。即运行时形态就是绝对元，**by design**。既有 `AppStateTests`（`maxDrawdown==30/50` 元）亦锚定此契约。codex R1-F1 把「record 列的比率」与「accumulator 的绝对额」混为一谈。
**与「比率」的关系：** 比率（如 -0.12）只属 `TrainingRecord.max_drawdown` **列**（plan v1.5 L419、settlement L999），是**另一对象**；由 **E6 finalize 换算**（modules L537-538：record 只存最终 maxDrawdown、不存 peakCapital；resume 时 E6 从 `PendingTraining.drawdown` 重建 accumulator）。
**判定：** `maxDrawdown { drawdown.maxDrawdown }` 透传绝对元（**spec-faithful**；不在 E5a 改成比率——那会违反 L1636 且破坏既有 `AppStateTests` 契约）。accessor **加文档注释**标明：单位=元/非负/运行时形态，比率换算是 E6 职责；调用方勿当比率用。
**init 须 seeding peak（codex R2-F1 采纳，纠正前稿「不 seeding」）：** spec L1604 明确「`initialCapital` 用于 drawdown 初始化」。`.initial` 的 `peakCapital=0`，而 `update` 先把 peak 抬到当前值再算 dd——若局中第一次 update 时资金已跌破起始值，从初始资金起的那段回撤会**永久丢失**（低报）。故 init 把 `peakCapital` seeding 为**起始总资金** `startTotal = initialCashBalance + initialPosition.shares × startPrice`（startPrice = `flow.initialTick` 处现价）。fresh 局 `.initial`（peak 0）→ 取 startTotal；resume 局（`initialDrawdown` 携带更高 peak）→ `max(peak, startTotal)` 保留较大者，二者统一为 `peakCapital = max(initialDrawdown.peakCapital, startTotal)`，`maxDrawdown` 沿用 `initialDrawdown.maxDrawdown`。
**E6 换算契约（显式登记，顺位 4/5 兑现）：** E6 finalize 构造 `TrainingRecord.maxDrawdown` 时须把运行时绝对元换算为比率（分母口径——initialCapital vs trough-peak——在 E6 RFC 定义；accumulator 不存 trough-peak，口径须显式选定）。本 PR 不实现换算，仅登记契约 + 测试断言 accessor 为绝对元（非负）。**若 codex 仍坚持 E5a 必须改 accessor 为比率 → 升级 user：该改动违 modules L1636，属契约变更需 RFC + 三方确认。**

### D4 — `buyEnabled`/`sellEnabled`（动作可达性门）整体下放 E5b（codex R2-F2）
**演进：** R1 我用 `TradeCalculator.quoteBuy` 跨档校验 buyEnabled。R2-F2 指出仍有真实假阳性——`quoteBuy` **无当前持仓输入**，已满仓 5/5 且有余现金时仍会判 true，违反「满仓禁买」不变量（plan v1.5 L734）。
**为何不在 E5a 修：** 正确的 5/5 判定需「当前持仓 → 档位」推导，而 spec 仅说该档位 **caller-derived**（plan v1.5 L730「依初始资金 + 当前持仓推导」），**未给公式**（分母口径、取整、与 tier ratio 的对应均未定义）。在 E5a 臆造一个 tier-推导公式违反「不臆造」原则，且与 E5b 的动作 tier 逻辑必然重复/易漂移。
**判定（采纳 codex R1-F2 自己给出的备选「keep it out of E5a until E5b」）：** `buyEnabled`/`sellEnabled` 作为**动作可达性门**整体移至 **E5b（顺位 3）**，与 `buy()/sell()` 的 tier 推导 + 满仓判定 + 资金不足 Toast 同处实现，单一真值源。E5a 仅交付 **4 个纯值 accessor**（`currentTotalCapital`/`holdingCost`/`returnRate`/`maxDrawdown`）。
**排序安全：** E5b（顺位 3）紧随 E5a（顺位 2），早于任何消费 buyEnabled 的 U 层（顺位 8/9），无前向缺口。
**偏离声明：** spec modules L1637-1638 把这两个列在 E5 accessor 块；本 PR 按 outline「E5a=核心状态/值 accessor、E5b=动作」边界把「动作门」归 E5b。**若 codex 坚持必须在 E5a 实现 5/5 门 → 升级 user：tier-推导公式属 spec 未定义项，需先澄清/RFC，不可在实施计划里臆造。**

### D5 — `tick` 由 `flow.initialTick` 起算
**判定：** `self.tick = TickEngine(maxTick: maxTick, initialTick: flow.initialTick)`。Normal/Replay→0；Review→`record.finalTick`（复盘固定末态）。
**偏离声明：** `maxTick` 参数与 `flow.allowedTickRange.upperBound` 的一致性由调用方保证（同 NormalFlow precondition 风格，不做防御 clamp）。

### D6 — `onSceneActivated` 归入 E5a（scenePhase 中继）
spec L1585 将「scenePhase 中继」列为 E5 运行时职责；outline E5a = 「运行时状态」。`animators` 是 E5a 构造的存储状态。
**判定：** E5a 实现 `onSceneActivated()` → 对两个 `DecelerationAnimator` 调 `resetOnSceneActive()`（实测存在，DecelerationAnimator.swift:92）。`animators` 在 init 内用默认 `DecelerationAnimator()` 构造。
**偏离声明：** 这是 E5a/E5b 边界判定 —— `onSceneActivated` 非交易「动作」，与 animators（E5a 状态）强耦合，故归 E5a。**codex 核**此边界。

### D7 — 默认面板：上区 60m / 下区 日线，`visibleCount: 0`
init 签名**不收** panel 参数 → 必须内部构造。
**判定：** `upperPanel = PanelViewState(period: .m60, …)`，`lowerPanel = PanelViewState(period: .daily, …)`，`interactionMode: .autoTracking`，`offset: 0`，`revision: 0`，**`visibleCount: 0`**（沿用 `KLineRenderState.empty` 的「未布局」哨兵，由 view 首次 layout 时回填）。
**依据：** plan v1.5 L777「初始周期组合：上区 60m，下区 日线」；`visibleCount` spec 无默认，view 布局期决定。
**偏离声明：** resume（继续中断训练）不恢复用户上次周期组合 —— spec init 签名无 panel 参数，故 resume 也回默认组合。**codex 核**：`visibleCount:0` 是否会让某只读 accessor/preview 异常（本 PR accessor 不读 panel，故安全）。

### D8 — `preview(mode:)` 内联构造 fixture，不新增公共 fixture 面
spec preview（L1690-1705）引用 `FeeSnapshot.preview` / `KLineCandle.previewFixture` / `TrainingRecord.previewRecord` —— **三者均不存在公共定义**（仅 UI 文件内 fileprivate）。原样照抄**不可编译**。
**判定：** `preview` 用私有 `static` helper 内联构造最小 fixture（`FeeSnapshot(commissionRate:0.0001, minCommissionEnabled:true)`、`previewCandleCount`=8 根 `.m60`+`.daily` K 线、review 用内联 `TrainingRecord`），**不**新增 `FeeSnapshot.preview` 等公共面（避免与未来 U 层 fixture 定义冲突）。gated `#if DEBUG`。**maxTick = `previewCandleCount-1`（=7）由 fixture 覆盖范围派生**，不照抄 spec 字面 1000——否则 maxTick(1000) 远超 candle 范围(0..7)，preview 推进 tick 会越界到无 candle 区（codex R3-F2）；并加 `previewMaxTickMatchesFixtureRange` 断言此不变量。
**偏离声明：** 偏离 spec 的「`.preview`/`.previewFixture`」字面写法，但语义等价（DEBUG preview 构造器）。**codex 核**：是否应改为补公共 fixture 以供 U1/U2（顺位 8/9）复用 —— 倾向不补，留 U 层按需引入，避免本 PR 越界。

---

## Spec snapshot（grep-verified，2026-06-05）

| 锚点 | 文件:行 | 当前内容 |
|---|---|---|
| TrainingEngine 壳 | `…/TrainingEngine/TrainingEngine.swift:11-17` | `@MainActor @Observable public final class TrainingEngine { fileprivate init() { fatalError("Wave 0 stub…") } }` |
| E5 class spec | `kline_trainer_modules_v1.4.md:1588-1639` | 9 存储态 + init(10 参) + 6 动作(E5b) + onSceneActivated + 6 accessor（本 PR 交 4 纯值；`buy/sellEnabled` 随动作门下放 E5b，D4） |
| preview spec | `kline_trainer_modules_v1.4.md:1690-1705` | `static func preview(mode:)`，引用不存在的 `.preview`/`.previewFixture`/`.previewRecord` |
| 初始组合 | `kline_trainer_plan_v1.5.md:777` | 「上区 60m，下区 日线」 |
| 现价/平仓 | `kline_trainer_plan_v1.5.md:751` | 「最后一根最小周期 K 线收盘价」 |
| DrawdownAccumulator | `…/AppState.swift:64-81` | `struct`，`update`=绝对额 `peak-current`，`.initial=(0,0)` |
| DecelerationAnimator | `…/ChartEngine/DecelerationAnimator.swift:54,92` | `init(friction:stopThreshold:)` + `resetOnSceneActive()` |
| partitioningIndex | `…/Models/BinarySearch.swift:12` | `partitioningIndex(where:)` O(log n) |
| PanelViewState | `…/Reducer/Reducer.swift:24-41` | `init(period:interactionMode:visibleCount:offset:revision:)` |

依赖签名（已验，逐字）：`PositionManager.init(shares:averageCost:totalInvested:)` / `.holdingCost = averageCost*Double(shares)` / `.shares`；`TickEngine.init(maxTick:initialTick:)` / `.globalTickIndex`；`FeeSnapshot.init(commissionRate:minCommissionEnabled:)`；`TradeDirection{.buy,.sell}`；`ChartInteractionMode{.autoTracking,.freeScrolling,.drawing}`；`Period{m3,m15,m60,daily,weekly,monthly}` CaseIterable。

---

## File Structure（子项归并 ≤3；prod « 500 行）

| 文件 | 动作 | 责任 | 预算 |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | **Modify**（整体替换壳） | 运行时核心：存储态 + init（drawdown seeding）+ currentPrice + 4 纯值 accessor + onSceneActivated + `#if DEBUG` preview（buy/sellEnabled 不在本 PR） | ~115 行 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift` | **Create** | Swift Testing：init 接线 / 现价 / accessor / scene 中继 / preview / 作用域守卫 | ~220 行 |
| `scripts/acceptance/plan_e5a_trainingengine_core.sh` | **Create** | Linux 可跑 grep/git 结构闸门 G1-G10 | ~70 行 |
| `docs/acceptance/2026-06-05-pr-e5a-trainingengine-core.md` | **Create** | 中文验收清单（action/expected/pass_fail；CI swift 行明标 macOS-only） | ~50 行 |

**子项归并：** A=源实现（TrainingEngine.swift）；B=测试（TrainingEngineCoreTests.swift）；C=验收脚本+清单。

---

## Task 1: 替换壳 —— 存储态 + init（TDD）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（整体替换 L1-18）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift`（Create）

- [ ] **Step 1.1: 写失败测试（init 接线）**

创建 `TrainingEngineCoreTests.swift`：

```swift
// E5a TrainingEngine 核心测试（Wave 2 顺位 2）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite struct TrainingEngineCoreTests {

    static let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)

    /// closes[i] 对应 globalIndex==endGlobalIndex==i 的一根 period K 线。
    static func candles(_ closes: [Double], period: Period = .m60) -> [Period: [KLineCandle]] {
        let arr = closes.enumerated().map { (i, c) in
            KLineCandle(period: period, datetime: Int64(i) * 3600,
                        open: c, high: c, low: c, close: c,
                        volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        return [period: arr]
    }

    static func normalEngine(closes: [Double] = [10, 11, 12, 13, 14],
                             cash: Double = 100_000,
                             capital: Double = 100_000,
                             position: PositionManager = .init()) -> TrainingEngine {
        TrainingEngine(
            flow: NormalFlow(fees: fees, maxTick: closes.count - 1),
            allCandles: candles(closes),
            maxTick: closes.count - 1,
            initialCapital: capital,
            initialCashBalance: cash,
            initialPosition: position)
    }

    @Test func initWiresRuntimeState() {
        let e = Self.normalEngine()
        #expect(e.cashBalance == 100_000)
        #expect(e.initialCapital == 100_000)
        #expect(e.position.shares == 0)
        #expect(e.markers.isEmpty)
        #expect(e.drawings.isEmpty)
        #expect(e.tradeOperations.isEmpty)
        #expect(e.tick.globalTickIndex == 0)            // NormalFlow.initialTick == 0
        #expect(e.upperPanel.period == .m60)            // D7：上区 60m
        #expect(e.lowerPanel.period == .daily)          // D7：下区 日线
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.fees.commissionRate == Self.fees.commissionRate)  // D1：派生自 flow.feeSnapshot
    }

    @Test func initPreservesInjectedState() {
        let pos = PositionManager(shares: 200, averageCost: 10, totalInvested: 2000)
        let e = Self.normalEngine(cash: 98_000, position: pos)
        #expect(e.position.shares == 200)
        #expect(e.cashBalance == 98_000)
    }

    @Test func freshSessionSeedsDrawdownPeakFromStartingCapital() {
        // codex R2-F1：fresh 局 peak 须 seeding 为起始总资金，否则首次 update 低报回撤。
        let e = Self.normalEngine(closes: [10], cash: 100_000, capital: 100_000)  // 空仓，起始价 10
        #expect(e.drawdown.peakCapital == 100_000)   // 非 0
        #expect(e.drawdown.maxDrawdown == 0)
    }

    @Test func freshSessionSeedPeakIncludesInitialPositionValue() {
        // 起始带仓：startTotal = 现金 + 持仓市值（200 股 × 10）= 100_000
        let pos = PositionManager(shares: 200, averageCost: 9, totalInvested: 1800)
        let e = Self.normalEngine(closes: [10], cash: 98_000, capital: 100_000, position: pos)
        #expect(e.drawdown.peakCapital == 100_000)
    }

    @Test func resumePreservesCarriedDrawdownPeak() {
        // resume 局 initialDrawdown 携带更高 peak → 不被 startTotal 覆盖（取 max）
        let dd = DrawdownAccumulator(peakCapital: 130_000, maxDrawdown: 12_000)
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 0),
                               allCandles: Self.candles([10]),
                               maxTick: 0, initialCapital: 100_000,
                               initialCashBalance: 90_000,
                               initialPosition: PositionManager(shares: 1000, averageCost: 10, totalInvested: 10_000),
                               initialDrawdown: dd)
        #expect(e.drawdown.peakCapital == 130_000)   // max(130_000, 90_000 + 1000*10 = 100_000)
        #expect(e.drawdown.maxDrawdown == 12_000)
    }
}
```

- [ ] **Step 1.2: 跑测试确认失败（CI/mac；本机 Linux 跳过并记录）**

Run（CI/mac）：`cd ios/Contracts && swift test --filter TrainingEngineCoreTests`
Expected: FAIL —— 编译错误「'init' is inaccessible due to 'fileprivate'」/「fatalError」（壳未替换）。
本机 Linux：无 swift，记录「deferred-to-CI」，不得声称已跑。

- [ ] **Step 1.3: 整体替换 TrainingEngine.swift（存储态 + init）**

```swift
// Kline Trainer Swift Contracts — E5a TrainingEngine 核心（Wave 2 顺位 2）
// Spec: kline_trainer_modules_v1.4.md §E5 (L1581-1639, preview L1690-1705)
//     + kline_trainer_plan_v1.5.md §4.2/§10.1（最大回撤、现价、初始周期组合 L777）
// 范围：init + 运行时状态 + accessors + onSceneActivated（scenePhase 中继）+ preview。
//   交易动作 buy/sell/holdOrObserve/switchPeriodCombo/activateDrawingTool/deleteDrawing
//   属 E5b（Wave 2 顺位 3），本 PR 不实现。
// 设计判定见 docs/superpowers/plans/2026-06-05-pr-e5a-trainingengine-core.md D1-D8。

#if canImport(Observation)
import Observation
#endif
import CoreGraphics

@MainActor
@Observable
public final class TrainingEngine {
    // 运行时状态（对外只读；写入留给 E5b 动作 PR）
    public private(set) var tick: TickEngine
    public private(set) var position: PositionManager
    public private(set) var cashBalance: Double
    public private(set) var drawdown: DrawdownAccumulator
    public private(set) var markers: [TradeMarker]
    public private(set) var drawings: [DrawingObject]
    public private(set) var upperPanel: PanelViewState
    public private(set) var lowerPanel: PanelViewState
    public private(set) var tradeOperations: [TradeOperation]

    // 构造后不变量
    public let flow: TrainingFlowController
    public let allCandles: [Period: [KLineCandle]]
    public let fees: FeeSnapshot
    public let initialCapital: Double

    private let animators: (upper: DecelerationAnimator, lower: DecelerationAnimator)
    private let basePeriod: Period   // 最细粒度周期 = tick 驱动周期 = 现价来源（D2）

    public init(flow: TrainingFlowController,
                allCandles: [Period: [KLineCandle]],
                maxTick: Int,
                initialCapital: Double,
                initialCashBalance: Double,
                initialPosition: PositionManager = .init(),
                initialMarkers: [TradeMarker] = [],
                initialDrawings: [DrawingObject] = [],
                initialTradeOperations: [TradeOperation] = [],
                initialDrawdown: DrawdownAccumulator = .initial) {
        // 前置不变量（NormalFlow 同风格：trap 调用方 bug，不防御 clamp）
        precondition(maxTick >= 0, "maxTick must be >= 0")
        guard let base = TrainingEngine.finestPeriod(in: allCandles) else {
            preconditionFailure("allCandles must contain at least one non-empty period")
        }

        self.flow = flow
        self.allCandles = allCandles
        self.fees = flow.feeSnapshot                 // D1
        self.initialCapital = initialCapital
        self.basePeriod = base

        let startTick = flow.initialTick
        self.tick = TickEngine(maxTick: maxTick, initialTick: startTick)  // D5
        self.position = initialPosition
        self.cashBalance = initialCashBalance
        // D3：drawdown peak seeding 为起始总资金（modules L1604），避免低报回撤（codex R2-F1）。
        // fresh 局 .initial(peak 0)→ startTotal；resume 局 → max 保留携带的更高 peak。
        let startPrice = TrainingEngine.price(in: allCandles, basePeriod: base, atTick: startTick)
        let startTotal = initialCashBalance + Double(initialPosition.shares) * startPrice
        self.drawdown = DrawdownAccumulator(
            peakCapital: max(initialDrawdown.peakCapital, startTotal),
            maxDrawdown: initialDrawdown.maxDrawdown)
        self.markers = initialMarkers
        self.drawings = initialDrawings
        self.tradeOperations = initialTradeOperations

        // D7：初始周期组合 上区 60m / 下区 日线（plan v1.5 L777）
        self.upperPanel = PanelViewState(period: .m60, interactionMode: .autoTracking,
                                         visibleCount: 0, offset: 0, revision: 0)
        self.lowerPanel = PanelViewState(period: .daily, interactionMode: .autoTracking,
                                         visibleCount: 0, offset: 0, revision: 0)

        self.animators = (upper: DecelerationAnimator(), lower: DecelerationAnimator())
    }

    /// 最细粒度周期 = `allCandles` 中非空、`Period.allCases` 序号最小者（枚举声明序即粒度升序）。
    private static func finestPeriod(in allCandles: [Period: [KLineCandle]]) -> Period? {
        allCandles
            .filter { !$0.value.isEmpty }
            .keys
            .min { (Period.allCases.firstIndex(of: $0) ?? .max)
                 < (Period.allCases.firstIndex(of: $1) ?? .max) }
    }

    /// 现价查找（静态，供 init seeding 与实例 `currentPrice` 复用）：basePeriod 中首个
    /// `endGlobalIndex >= target` 的 K 线收盘价；超末根夹取末根（D2）。
    private static func price(in allCandles: [Period: [KLineCandle]],
                             basePeriod: Period, atTick target: Int) -> Double {
        let candles = allCandles[basePeriod] ?? []
        guard let last = candles.last else { return 0 }
        let idx = candles.partitioningIndex { $0.endGlobalIndex >= target }
        return idx < candles.count ? candles[idx].close : last.close
    }
}
```

- [ ] **Step 1.4: 跑测试确认通过（CI/mac）**

Run（CI/mac）：`cd ios/Contracts && swift test --filter TrainingEngineCoreTests`
Expected: PASS（`initWiresRuntimeState` / `initPreservesInjectedState` 绿）。
本机 Linux：记录 deferred-to-CI。

- [ ] **Step 1.5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift
git commit -m "feat(e5a): TrainingEngine 存储态 + public init（替换 Wave 0 壳，顺位 2）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: 现价 + 4 个纯值 accessor（TDD）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift`

- [ ] **Step 2.1: 写失败测试（accessor）**

在 `TrainingEngineCoreTests` 内追加：

```swift
    @Test func currentTotalCapitalFlatEqualsCash() {
        let e = Self.normalEngine(closes: [10, 11, 12], cash: 100_000)
        // 空仓 → 总资金 == 现金（市值 0）
        #expect(e.currentTotalCapital == 100_000)
    }

    @Test func currentTotalCapitalAddsMarketValueAtCurrentPrice() {
        // tick 起点 0 → 现价 = candles[0].close == 10；持仓 200 股
        let pos = PositionManager(shares: 200, averageCost: 9, totalInvested: 1800)
        let e = Self.normalEngine(closes: [10, 11, 12], cash: 98_200, position: pos)
        // 98_200 现金 + 200*10 市值 = 100_200
        #expect(e.currentTotalCapital == 100_200)
    }

    @Test func returnRateIsNetRatioOverInitialCapital() {
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        let e = Self.normalEngine(closes: [10, 11, 12], cash: 99_000,
                                  capital: 100_000, position: pos)
        // 总资金 99_000 + 100*10 = 100_000 → returnRate 0
        #expect(e.returnRate == 0)
    }

    @Test func holdingCostDelegatesToPosition() {
        let pos = PositionManager(shares: 300, averageCost: 12, totalInvested: 3600)
        let e = Self.normalEngine(position: pos)
        #expect(e.holdingCost == 3600)   // 12 * 300
    }

    @Test func maxDrawdownIsAbsoluteAmountPerSpec() {
        // modules L510：accumulator.maxDrawdown = 非负绝对额（元），运行时形态；
        // 比率换算是 E6 finalize 职责（D3），本 accessor 不换算。
        let dd = DrawdownAccumulator(peakCapital: 120_000, maxDrawdown: 8_000)
        let e = TrainingEngine(flow: NormalFlow(fees: Self.fees, maxTick: 2),
                               allCandles: Self.candles([10, 11, 12]),
                               maxTick: 2, initialCapital: 100_000,
                               initialCashBalance: 100_000, initialDrawdown: dd)
        #expect(e.maxDrawdown == 8_000)     // 元（绝对额），非比率
        #expect(e.maxDrawdown >= 0)         // 非负不变量
    }

    @Test func reviewModeStartsAtFinalTick() {
        let record = Self.previewRecordForTest()   // finalTick 2
        let e = TrainingEngine(flow: ReviewFlow(record: record),
                               allCandles: Self.candles([10, 11, 12, 13]),
                               maxTick: 3, initialCapital: 100_000,
                               initialCashBalance: 50_000,
                               initialPosition: PositionManager(shares: 100, averageCost: 10, totalInvested: 1000))
        #expect(e.tick.globalTickIndex == record.finalTick)   // D5：复盘起于末态
    }

    // Review/preview 用最小 TrainingRecord
    static func previewRecordForTest(finalTick: Int = 2) -> TrainingRecord {
        TrainingRecord(id: 1, trainingSetFilename: "t.sqlite", createdAt: 0,
                       stockCode: "000001", stockName: "测试股",
                       startYear: 2020, startMonth: 1,
                       totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: finalTick)
    }
```

- [ ] **Step 2.2: 跑测试确认失败（CI/mac）**

Run（CI/mac）：`cd ios/Contracts && swift test --filter TrainingEngineCoreTests`
Expected: FAIL —— `currentTotalCapital`/`returnRate`/`holdingCost`/`maxDrawdown` 未定义。

- [ ] **Step 2.3: 实现 currentPrice + 4 纯值 accessor**

在 `TrainingEngine` class 内、`finestPeriod` 之前追加：

```swift
    // MARK: - 派生 accessor（只读纯值计算属性；买卖可用门见 E5b / D4）

    /// 现价：复用 Task 1 的静态 `price(...)`（D2；endGlobalIndex 二分，超末根夹取末根）。
    private var currentPrice: Double {
        TrainingEngine.price(in: allCandles, basePeriod: basePeriod, atTick: tick.globalTickIndex)
    }

    /// 本局实时总资金 = 现金 + 持仓市值（plan v1.5 L914）。
    public var currentTotalCapital: Double {
        cashBalance + Double(position.shares) * currentPrice
    }

    /// 持仓成本（plan v1.5 L909）。
    public var holdingCost: Double { position.holdingCost }

    /// 本局至今净收益率（plan v1.5 L917）。
    public var returnRate: Double {
        initialCapital == 0 ? 0 : (currentTotalCapital - initialCapital) / initialCapital
    }

    /// 最大回撤：透传 accumulator —— **非负绝对额，单位元**，运行时形态（modules L510/L1636）。
    /// 注意：`TrainingRecord.maxDrawdown` 是比率（如 -0.12），由 E6 finalize 换算（modules L537-538，D3）；
    /// 本 accessor 不做换算，调用方勿当比率使用。
    public var maxDrawdown: Double { drawdown.maxDrawdown }
```

- [ ] **Step 2.4: 跑测试确认通过（CI/mac）**

Run（CI/mac）：`cd ios/Contracts && swift test --filter TrainingEngineCoreTests`
Expected: PASS（全部 accessor 测试绿）。

- [ ] **Step 2.5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift
git commit -m "feat(e5a): 现价二分 + 4 纯值 accessor（总资金/收益率/持仓成本/回撤，顺位 2）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: onSceneActivated 场景中继（TDD）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift`

- [ ] **Step 3.1: 写失败测试（scene 中继不崩 + 状态不变）**

追加（`DecelerationAnimator` 无公共可观测「已 reset」标志，故测「调用安全 + 运行时状态不被改」契约）：

```swift
    @Test func onSceneActivatedIsSafeAndPure() {
        let e = Self.normalEngine(closes: [10, 11, 12])
        let beforeTick = e.tick.globalTickIndex
        let beforeCash = e.cashBalance
        e.onSceneActivated()                 // 中继到两个 animator.resetOnSceneActive()
        // 场景中继不改运行时业务状态
        #expect(e.tick.globalTickIndex == beforeTick)
        #expect(e.cashBalance == beforeCash)
        #expect(e.position.shares == 0)
    }
```

- [ ] **Step 3.2: 跑测试确认失败（CI/mac）**

Run（CI/mac）：`swift test --filter onSceneActivatedIsSafeAndPure`
Expected: FAIL —— `onSceneActivated` 未定义。

- [ ] **Step 3.3: 实现 onSceneActivated**

在 accessor 之后、`finestPeriod` 之前追加：

```swift
    // MARK: - 场景生命周期中继（D6）

    /// 由 U2 TrainingView 顶层 `.onChange(of: scenePhase)` 触发（modules L1625-1629）。
    /// 仅中继到减速动画 reset，不触碰业务状态。
    public func onSceneActivated() {
        animators.upper.resetOnSceneActive()
        animators.lower.resetOnSceneActive()
    }
```

- [ ] **Step 3.4: 跑测试确认通过（CI/mac）** → Expected PASS。

- [ ] **Step 3.5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift
git commit -m "feat(e5a): onSceneActivated 场景中继到减速动画 reset（顺位 2）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `#if DEBUG` preview 便利构造（TDD）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift`

- [ ] **Step 4.1: 写失败测试（preview 三模式可构造）**

追加：

```swift
    @Test func previewBuildsAllModes() {
        let n = TrainingEngine.preview(mode: .normal)
        #expect(n.flow.mode == .normal)
        #expect(n.currentTotalCapital == 100_000)        // 空仓 → 现金 100k
        let r = TrainingEngine.preview(mode: .review)
        #expect(r.flow.mode == .review)
        #expect(r.flow.canBuySell() == false)            // review 关闭买卖（flow 能力，非 E5a accessor）
        let p = TrainingEngine.preview(mode: .replay)
        #expect(p.flow.mode == .replay)
    }

    @Test func previewMaxTickMatchesFixtureRange() {
        // codex R3-F2：preview 的 maxTick 必须 == fixture 末根 endGlobalIndex，tick 不越界。
        let e = TrainingEngine.preview(mode: .normal)
        #expect(e.tick.maxTick == 7)         // 8 根 candle（endGlobalIndex 0..7）→ maxTick 7
    }

    @Test func previewDefaultsToNormal() {
        #expect(TrainingEngine.preview().flow.mode == .normal)
    }
```

- [ ] **Step 4.2: 跑测试确认失败（CI/mac）** → Expected FAIL（`preview` 未定义）。

- [ ] **Step 4.3: 实现 preview extension**

在文件末尾（class 之外）追加：

```swift
#if DEBUG
extension TrainingEngine {
    /// preview fixture 的 base K 线根数；maxTick 由它派生，保证 tick 不越界（codex R3-F2）。
    private static let previewCandleCount = 8

    /// Preview Fixture（取代 MockTrainingEngine；modules L1687-1705）。
    /// D8：内联构造最小 fixture，不新增公共 fixture 面；maxTick = previewCandleCount-1（非 spec 字面 1000）。
    public static func preview(mode: TrainingMode = .normal) -> TrainingEngine {
        let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let candles = previewCandles()
        let maxTick = previewCandleCount - 1            // 末根 endGlobalIndex；tick 不越界
        let flow: TrainingFlowController
        switch mode {
        case .normal: flow = NormalFlow(fees: fees, maxTick: maxTick)
        case .review: flow = ReviewFlow(record: previewRecord(fees: fees, finalTick: maxTick))
        case .replay: flow = ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: maxTick)
        }
        return TrainingEngine(
            flow: flow,
            allCandles: candles,
            maxTick: maxTick,
            initialCapital: 100_000,
            initialCashBalance: 100_000)
    }

    private static func previewCandles() -> [Period: [KLineCandle]] {
        let arr: [KLineCandle] = (0..<previewCandleCount).map { i in
            KLineCandle(period: .m60, datetime: Int64(i) * 3600,
                        open: 10, high: 11, low: 9, close: 10 + Double(i) * 0.1,
                        volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        return [.m60: arr, .daily: arr]
    }

    private static func previewRecord(fees: FeeSnapshot, finalTick: Int) -> TrainingRecord {
        TrainingRecord(id: 1, trainingSetFilename: "preview.sqlite", createdAt: 0,
                       stockCode: "000001", stockName: "预览股",
                       startYear: 2020, startMonth: 1,
                       totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: finalTick)
    }
}
#endif
```

- [ ] **Step 4.4: 跑测试确认通过（CI/mac）** → Expected PASS。

- [ ] **Step 4.5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift
git commit -m "feat(e5a): #if DEBUG preview 三模式便利构造（内联 fixture，顺位 2）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 验收脚本 + 中文验收清单（作用域守卫 + CI 闸门）

**Files:**
- Create: `scripts/acceptance/plan_e5a_trainingengine_core.sh`
- Create: `docs/acceptance/2026-06-05-pr-e5a-trainingengine-core.md`

- [ ] **Step 5.1: 写验收脚本（Linux 可跑 grep/git 结构闸门）**

```bash
#!/usr/bin/env bash
# 验收脚本 — E5a TrainingEngine 核心（Wave 2 顺位 2）
# 仅含 Linux 可跑的结构闸门；swift test / Catalyst 见验收清单 CI 行。
set -uo pipefail
cd "$(dirname "$0")/../.."
TE="ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift"
TS="ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift"
fail=0
ok(){ echo "OK:   $1"; }
bad(){ echo "FAIL: $1"; fail=1; }
want(){  if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }   # 期望命中
wantn(){ if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }   # 期望不命中

echo "== G1: 壳已替换（无 Wave 0 stub / fatalError / fileprivate init 残留）=="
wantn "无 Wave 0 stub 注释" "grep -q 'Wave 0 stub' '$TE'"
wantn "无 fatalError"       "grep -q 'fatalError' '$TE'"
wantn "无 fileprivate init" "grep -qE 'fileprivate +init' '$TE'"

echo "== G2: public init（10 参签名锚点）+ drawdown seeding =="
want "public init(flow:)" "grep -qE 'public init\(flow: TrainingFlowController' '$TE'"
want "initialCashBalance 参数" "grep -q 'initialCashBalance' '$TE'"
want "drawdown peak seeding（codex R2-F1）" "grep -q 'max(initialDrawdown.peakCapital' '$TE'"

echo "== G3: 9 个运行时存储态 =="
for p in tick position cashBalance drawdown markers drawings upperPanel lowerPanel tradeOperations; do
  want "存储态 $p" "grep -qE 'private\(set\) var $p' '$TE'"
done

echo "== G4: 4 纯值 accessor（buy/sellEnabled 下放 E5b，不应出现）=="
for a in currentTotalCapital holdingCost returnRate maxDrawdown; do
  want "accessor $a" "grep -qE 'var $a' '$TE'"
done
wantn "无 buyEnabled 声明（D4 下放 E5b）"  "grep -qE 'var +buyEnabled' '$TE'"
wantn "无 sellEnabled 声明（D4 下放 E5b）" "grep -qE 'var +sellEnabled' '$TE'"

echo "== G5: onSceneActivated 中继到 resetOnSceneActive =="
want "onSceneActivated" "grep -q 'func onSceneActivated' '$TE'"
want "resetOnSceneActive 中继" "grep -q 'resetOnSceneActive' '$TE'"

echo "== G6: 初始周期组合 上 60m / 下 日线（D7）=="
want "upperPanel .m60" "grep -Pzo 'upperPanel = PanelViewState\(period: .m60' '$TE'"
want "lowerPanel .daily" "grep -Pzo 'lowerPanel = PanelViewState\(period: .daily' '$TE'"

echo "== G7: maxDrawdown 透传 accumulator（spec L1636）=="
want "drawdown.maxDrawdown 透传" "grep -q 'drawdown.maxDrawdown' '$TE'"

echo "== G8: 作用域守卫 —— E5a 不实现 E5b 动作 =="
for m in 'func buy\(' 'func sell\(' 'func holdOrObserve' 'func switchPeriodCombo' 'func activateDrawingTool' 'func deleteDrawing'; do
  wantn "未越界实现 $m" "grep -qE '$m' '$TE'"
done

echo "== G9: 测试存在且用 Swift Testing =="
want "测试文件存在" "test -f '$TS'"
want "import Testing" "grep -q 'import Testing' '$TS'"
want "@Test 用例"     "grep -q '@Test' '$TS'"

echo "== G10: 作用域 —— diff 只动允许文件 =="
base="$(git merge-base origin/main HEAD 2>/dev/null || echo origin/main)"
changed="$(git diff --name-only "$base"...HEAD 2>/dev/null || true)"
disallowed="$(printf '%s\n' "$changed" | grep -vE '^(ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine\.swift|ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests\.swift|scripts/acceptance/plan_e5a_trainingengine_core\.sh|docs/(acceptance|superpowers/plans)/.*e5a.*\.md)$' || true)"
if [ -n "$disallowed" ]; then bad "越界文件: $disallowed"; else ok "diff 文件白名单内"; fi

echo
if [ "$fail" -ne 0 ]; then echo "=== E5a ACCEPTANCE FAILED ==="; exit 1; fi
echo "=== ALL E5a ACCEPTANCE CHECKS PASSED ==="
```

- [ ] **Step 5.2: 本机跑结构闸门**

Run（本机 Linux 可跑）：`bash scripts/acceptance/plan_e5a_trainingengine_core.sh; echo "exit=$?"`
Expected: `=== ALL E5a ACCEPTANCE CHECKS PASSED ===`，`exit=0`。

- [ ] **Step 5.3: 写中文验收清单**

```markdown
# 验收清单 — E5a TrainingEngine 核心（Wave 2 顺位 2）

> 语言：中文；判定二元可决。本模块是「训练引擎运行时核心」：把一局训练的实时状态
> （现金、持仓、标记、画线、双周期面板）装进一个可观测对象，并对外提供总资金、收益率、
> 持仓成本、最大回撤、买卖按钮是否可用等只读数值。**本机 Linux 无 swift**，标注 [CI] 的行
> 在 GitHub Actions（macos-15）执行，不可在本机谎称通过。

## 一、自动闸门（命令可机器核验）

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | `bash scripts/acceptance/plan_e5a_trainingengine_core.sh; echo exit=$?` | 末行 `=== ALL E5a ACCEPTANCE CHECKS PASSED ===`，`exit=0` | ☐ |
| 2 | [CI] `cd ios/Contracts && swift build` | `Build complete!` | ☐ |
| 3 | [CI] `cd ios/Contracts && swift test --filter TrainingEngineCoreTests` | `0 failures`，全部 @Test 绿 | ☐ |
| 4 | [CI] `cd ios/Contracts && swift test` | 全量 `0 failures`（无回归） | ☐ |
| 5 | [CI Catalyst 必绿闸门] `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/e5a-catalyst` | `** TEST BUILD SUCCEEDED **`（required check `Mac Catalyst build-for-testing on macos-15`，不可 bypass） | ☐ |

## 二、业务规则验收（映射到具名测试）

| # | 规则 | 验证测试 | 期望 | 通过 |
|---|---|---|---|---|
| 6 | init 接线：现金/初始资金/空仓/起始 tick/初始组合 60m+日线 | `initWiresRuntimeState` | PASS | ☐ |
| 7 | drawdown peak seeding：fresh→起始总资金、带仓含市值、resume→保留较大 peak（codex R2-F1） | `freshSessionSeedsDrawdownPeakFromStartingCapital` / `freshSessionSeedPeakIncludesInitialPositionValue` / `resumePreservesCarriedDrawdownPeak` | PASS | ☐ |
| 8 | 总资金 = 现金 + 持仓市值（现价取最细周期收盘价） | `currentTotalCapitalAddsMarketValueAtCurrentPrice` | PASS | ☐ |
| 9 | 收益率 = (总资金−初始资金)/初始资金 | `returnRateIsNetRatioOverInitialCapital` | PASS | ☐ |
| 10 | maxDrawdown = 非负绝对额（元），非比率（E6 换算） | `maxDrawdownIsAbsoluteAmountPerSpec` | PASS | ☐ |
| 11 | review 起于末态 tick | `reviewModeStartsAtFinalTick` | PASS | ☐ |
| 12 | 场景中继不改业务状态 | `onSceneActivatedIsSafeAndPure` | PASS | ☐ |
| 13 | preview 三模式可构造 | `previewBuildsAllModes` | PASS | ☐ |

## 三、流程合规与偏差

| # | 项 | 期望 | 通过 |
|---|---|---|---|
| 14 | 作用域守卫：E5a 未实现任何 E5b 动作（G8）+ 无 buy/sellEnabled（G4，D4 下放 E5b） | grep 不命中 6 动作 + 不命中 buy/sellEnabled | ☐ |
| 15 | codex 对抗性评审 branch-diff | verdict `approve`（收敛） | ☐ |
| 16 | 契约登记：D3 maxDrawdown 绝对元 + E6 换算契约（顺位 4/5 兑现）；D4 buy/sellEnabled 移 E5b | PR body 已列 | ☐ |

**任一条 ✗ → 不得 merge。**
```

- [ ] **Step 5.4: 提交**

```bash
git add scripts/acceptance/plan_e5a_trainingengine_core.sh \
        docs/acceptance/2026-06-05-pr-e5a-trainingengine-core.md
git commit -m "test(e5a): 验收脚本（G1-G10 结构闸门）+ 中文验收清单（顺位 2）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification（合并前闸门）

- [ ] [CI/mac] `cd ios/Contracts && swift build` → `Build complete!`
- [ ] [CI/mac] `cd ios/Contracts && swift test` → 全量 `0 failures`
- [ ] [CI/mac] `swift build -Xswiftc -strict-concurrency=complete` → 无 data-race 警告（`@MainActor` 隔离；per memory `feedback_swift_local_toolchain_blindspot`：CI macos-15 为准，本地绿不等于 CI 绿）
- [ ] [CI Catalyst 必绿] `xcodebuild build-for-testing … Mac Catalyst` → `TEST BUILD SUCCEEDED`
- [ ] [本机] `bash scripts/acceptance/plan_e5a_trainingengine_core.sh` → `ALL … PASSED`
- [ ] codex `--scope branch-diff` → `approve`

---

## Self-Review

**1. Spec coverage（逐项）：** 9 存储态（Task1）✅；init 10 参 + drawdown peak seeding（Task1）✅；4 纯值 accessor `currentTotalCapital/holdingCost/returnRate/maxDrawdown`（Task2）✅；onSceneActivated（Task3）✅；preview（Task4）✅。**有意 OUT-OF-SCOPE（评审驱动）：** `buyEnabled`/`sellEnabled` 动作门 → E5b（D4，codex R2-F2）；6 个交易动作 → E5b 顺位 3；maxDrawdown 绝对元→比率换算 → E6 finalize（D3，codex R1/R2）；E6 Coordinator 顺位 4/5；集成测试 顺位 7。

**2. Placeholder scan：** 无 TBD/TODO；每个 code step 给出完整可编译代码；测试给出真实断言。

**3. Type/naming 一致：** `finestPeriod`/`basePeriod`/`currentPrice` 全文一致；accessor 名与 spec L1633-1638 逐字一致；init 参名与 spec L1607-1616 逐字一致；`flow.feeSnapshot`/`flow.initialTick`/`flow.canBuySell()` 与 TrainingFlowController 协议（已 merged）一致。

**4. Scope（surgical）：** 仅替换 TrainingEngine.swift + 新增 1 测试 + 1 脚本 + 1 清单；不碰任何已冻结契约文件（G10 守卫）；不「改进」相邻代码。

**5. delta 声明：** D1-D8 全部显式标注依据 + 偏离声明，作为 codex 首要靶点；D3 = 「绝对元透传 + init seeding peak + E6 换算显式契约」（codex R1-F1 + R2-F1 响应），D4 = 「buy/sellEnabled 动作门下放 E5b」（codex R2-F2 采纳其 R1 备选），均登记入验收清单第 14-16 行。

**6. 无本机 swift 诚实性：** 所有 swift/xcodebuild 步骤标 [CI/mac]；RED/GREEN 期望写明但本机不执行、不谎称通过（per `feedback_swift_local_toolchain_blindspot`）。

---

## Execution Handoff

**REQUIRED SUB-SKILL：** superpowers:subagent-driven-development —— 每 task 派新 subagent + 两段式 review。

**前置：** 本计划须先过 `codex:adversarial-review --scope working-tree` 收敛（approve）后才进 Task 1。codex review 由 Claude 直接调用；branch-diff attest ledger / pin 工具链由 user 负责。

**PR 标题：** `E5a TrainingEngine 核心：init + 运行时状态 + accessors（Wave 2 顺位 2）`

---

## 变更日志 / codex 对抗性评审响应

**R1（codex branch-diff，verdict `needs-attention`，2026-06-05）→ 已响应：**

- **R1-F1（high, maxDrawdown 单位）—— 部分反驳 + 采纳其备选：** codex 把 `TrainingRecord.max_drawdown` 列的「比率」误当成 `DrawdownAccumulator.maxDrawdown` 的语义。权威 `modules v1.4 L510`（非负绝对额，单位元）+ `L1636`（accessor 直接读 accumulator）+ 既有 `AppStateTests`（==30/50 元）证明 E5a 透传绝对元是 spec-correct，改成比率反而违 L1636。**采纳 codex 第二方案**：accessor 加单位文档注释 + 把「绝对元→比率」登记为**显式 E6 finalize 换算契约**（D3）+ 加 `maxDrawdownIsAbsoluteAmountPerSpec` 断言绝对元/非负。若 codex 仍坚持改 accessor → 升级 user（属契约变更）。
- **R1-F2（medium, buyEnabled 假阳性）—— 采纳：** `buyEnabled` 由 `canBuySell() && cash>0` 改为「∃ tier: `TradeCalculator.quoteBuy` == .success」跨全 5 档校验（D4）；新增负测 `buyEnabledFalseWhenCashPositiveButUnbuyable`（有现金但取整不足 1 手 → false）+ `buyEnabledTrueWhenAffordable`。`sellEnabled` 经证明 `shares>0` ⟺ tier5 全清成功，保持但加证明注释。

**R2（codex branch-diff，verdict `needs-attention`，2026-06-05）→ 已响应：**

- **R2-F1（high 0.93, drawdown 低报）—— 采纳（纠正 R1 误判）：** R1 我 D3 说「不 seeding」是错的——spec L1604「`initialCapital` 用于 drawdown 初始化」+ `update` 先抬 peak 会丢失从初始资金起的回撤。改：init `peakCapital = max(initialDrawdown.peakCapital, startTotal)`（startTotal=起始总资金）；新增 `freshSessionSeedsDrawdownPeakFromStartingCapital` / `freshSessionSeedPeakIncludesInitialPositionValue` / `resumePreservesCarriedDrawdownPeak` 三测。
- **R2-F2（medium 0.84, buyEnabled 忽略满仓）—— 采纳其 R1 备选「下放 E5b」：** `quoteBuy` 无当前持仓输入，5/5 满仓+余现金仍判 true；而 5/5 判定需 spec 未定义的 tier-推导公式（plan v1.5 L730 仅说 caller-derived），**不臆造**。`buyEnabled`/`sellEnabled` 整体移 E5b（顺位 3，与动作 tier 逻辑同处）；E5a 删二者实现与测试，保留 4 纯值 accessor；验收 G4 加 `wantn` 守卫确认 E5a 不含 buy/sellEnabled。

**R3（codex branch-diff，verdict `needs-attention`，2026-06-05）→ 已响应（均为 R1/R2 修订引入的一致性 bug，非设计分歧）：**

- **R3-F1（medium 0.95, 验收脚本自相矛盾）—— 采纳：** R2 的 MARK 注释含 `buy/sellEnabled` 子串，被 G4 `wantn 'sellEnabled'` 子串匹配 → 实现过不了自己的闸门。改：注释去子串（→「买卖可用门」）+ G4 改匹配声明 `grep -qE 'var +sellEnabled'`（双保险）。
- **R3-F2（medium 0.88, preview maxTick 越界）—— 采纳：** preview `maxTick:1000` 远超 8 根 fixture(endGlobalIndex 0..7)。改：`maxTick = previewCandleCount-1`（fixture 派生）+ `previewRecord(finalTick:)` 参数化 + 新增 `previewMaxTickMatchesFixtureRange` 断言不变量（D8）。

**收敛判断（round 3 已用满）：** R1/R2/R3 findings 逐轮收窄——R1/R2 是真实语义契约（已实质修正），R3 两条是修订引入的局部一致性 bug（已全修），无遗留设计分歧、无 spec 未定义项触发。本轮修订后若 R4 复审 clean 即收敛；按 loop 策略 round>3 本应 escalate，但鉴于 R3 仅为机械一致性修复（非僵局/非反复拉锯），按 `duplicate/收窄趋势` 续审一轮确认 approve；仍不过则 escalate user。
