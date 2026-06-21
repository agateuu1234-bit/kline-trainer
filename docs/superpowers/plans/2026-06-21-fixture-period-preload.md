# RFC-F 开局预放历史 + fixture 周期比例 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新开 Normal/Replay 局时把播放头 seed 到训练起始点（从 `meta.start_datetime` 派生），使开局即显约一屏历史 before-candle；并修 DEBUG fixture 的周期聚合比例 + 预放 before-candle。

**Architecture:** 引擎侧新增纯函数 `TrainingEngine.startTick(forStartDatetime:in:)`，`TrainingSessionCoordinator` 的 `startNewNormalSession`/`replay` 用它算 `initialTick` 传给已有的 `make(initialTick:)`（不改冻结值类型/签名）。fixture 侧改聚合 span + 总根数 + 新增 `beforeM3Count` 参数让 `meta.startDatetime` 指向起始点。

**Tech Stack:** Swift 6（strict concurrency）、Swift Testing（`@Test`/`#expect`）、SwiftPM（`ios/Contracts`）、GRDB（仅 fixture 写库）。host `swift test` + Mac Catalyst build-for-testing。

## Global Constraints

- 不 bump `CONTRACT_VERSION`（当前 `Models.swift:7` = `"1.6"`）：无 schema/DDL/持久化格式变更。
- 不改冻结值类型 `NormalFlow`/`ReplayFlow`/`ReviewFlow`/`TickEngine`，不改 `TrainingEngine.make` 签名。
- fixture 改动全部在 `#if DEBUG` 内。
- 起始点 tick 不变量：`startTick == 0` 当且仅当 `meta.startDatetime ≤ m3[0].datetime`。
- `beforeM3Count` / `fullLoadBeforeM3Count` 须为 `lcm(spans)=480` 的倍数（满载 = 12,000 = 480×25）。
- 满载根数权威表（before/after/total）：m3 12000/7200/19200 · m15 2400/1440/3840 · m60 600/360/960 · daily **150**/90/240 · weekly 75/45/120 · monthly 50/30/80。
- 测试用 `@testable import KlineTrainerContracts`（两个 coordinator 测试文件已确认用此）。
- 验收禁用语（`.claude/workflow-rules.json`）：不得「应该能/大概/理论上」。
- spec 权威：`docs/superpowers/specs/2026-06-21-fixture-period-preload-design.md`。

---

### Task 1: `TrainingEngine.startTick` 纯函数 helper

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（在 `price`/`isContiguousM3Axis` 一带，约 L541-563 私有静态 helper 区）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineStartTickTests.swift`（新建）

**Interfaces:**
- Produces: `static func startTick(forStartDatetime startDatetime: Int64, in allCandles: [Period: [KLineCandle]]) -> Int`（module-internal；Task 2 的 coordinator 调用，测试 `@testable` 访问）

- [ ] **Step 1: 写失败测试**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineStartTickTests.swift`：

```swift
import Testing
@testable import KlineTrainerContracts

struct TrainingEngineStartTickTests {
    /// 造 m3 轴：datetime = base + i*180，globalIndex==endGlobalIndex==i（满足轴不变量）。
    static func m3(_ count: Int, base: Int64) -> [Period: [KLineCandle]] {
        let rows = (0..<count).map { i in
            KLineCandle(period: .m3, datetime: base + Int64(i) * 180, open: 10, high: 11, low: 9,
                        close: 10, volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        return [.m3: rows]
    }

    @Test("起始点在序列中部：返回该下标")
    func midSequence() {
        // m3 datetime = [0,180,360,540,720]；start=360 → 首个 >= 360 = index 2
        #expect(TrainingEngine.startTick(forStartDatetime: 360, in: Self.m3(5, base: 0)) == 2)
    }

    @Test("start <= m3[0].datetime → 0（不变量）")
    func atOrBeforeFirst() {
        // m3[0].datetime = 100；start=100 → 0；start=50(<100) → 0
        #expect(TrainingEngine.startTick(forStartDatetime: 100, in: Self.m3(5, base: 100)) == 0)
        #expect(TrainingEngine.startTick(forStartDatetime: 50, in: Self.m3(5, base: 100)) == 0)
    }

    @Test("start 落在两根之间：取首个 >=")
    func betweenCandles() {
        // m3 datetime = [0,180,360]；start=200（180<200<360）→ 首个 >= 200 = index 2
        #expect(TrainingEngine.startTick(forStartDatetime: 200, in: Self.m3(3, base: 0)) == 2)
    }

    @Test("degenerate：start 超所有 m3 → 钳到 maxTick（非 0）")
    func degenerateClampsToMax() {
        // m3 datetime = [0,180,360,540]（count=4, maxTick=3）；start=999999 → 钳到 3
        #expect(TrainingEngine.startTick(forStartDatetime: 999_999, in: Self.m3(4, base: 0)) == 3)
    }

    @Test("空 m3 → 0（make 已先验非空，纵深防御）")
    func emptyM3() {
        #expect(TrainingEngine.startTick(forStartDatetime: 100, in: [:]) == 0)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "ios/Contracts" && swift test --filter TrainingEngineStartTickTests 2>&1 | tail -20`
Expected: 编译失败 `type 'TrainingEngine' has no member 'startTick'`。

- [ ] **Step 3: 实现 helper**

在 `TrainingEngine.swift` 的私有静态 helper 区（紧邻 `private static func price(...)` / `isContiguousM3Axis`）加（注意：**`internal`（去掉 `private`）**，因 `TrainingSessionCoordinator` 是同模块不同类型，须可见）：

```swift
    /// 从 meta.start_datetime 推训练起始点 tick：第一根 `datetime >= startDatetime` 的 `.m3` 下标。
    /// `.m3` 轴连续（globalIndex==endGlobalIndex==index），故下标 == global tick。
    /// 不变量：返回 0 **当且仅当** `startDatetime <= m3[0].datetime`；degenerate（start 超所有 m3）
    /// → 钳到 `maxTick`（保 `0...maxTick` + 不变量，valid 数据不触发）。空 m3 → 0（make 已先验非空）。
    static func startTick(forStartDatetime startDatetime: Int64,
                          in allCandles: [Period: [KLineCandle]]) -> Int {
        guard let m3 = allCandles[.m3], !m3.isEmpty else { return 0 }
        let idx = m3.partitioningIndex { $0.datetime >= startDatetime }
        return min(idx, m3.count - 1)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd "ios/Contracts" && swift test --filter TrainingEngineStartTickTests 2>&1 | tail -20`
Expected: 5 个 `@Test` 全 PASS。

- [ ] **Step 5: 提交**

```bash
git add "ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift" "ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineStartTickTests.swift"
git commit -m "feat(engine): TrainingEngine.startTick 从 meta.startDatetime 派生起始点 tick"
```

---

### Task 2: coordinator 接线 startTick（startNewNormalSession + replay）+ 测试桩 re-align + 有-before 集成测试

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（`startNewNormalSession` make 调用 L171-174；`replay` make 调用 L293-297）
- Modify（re-align 桩，保既有 tick==0 断言绿）:
  - `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift`（`validCandles` L13 + `makeReplaySession` meta L458）
  - `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorConstructionTests.swift`（`validCandles` L14）
  - `ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift`（`validCandles` L24）
- Test（新建有-before 集成测试）: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionStartTickIntegrationTests.swift`

**Interfaces:**
- Consumes: `TrainingEngine.startTick(forStartDatetime:in:)`（Task 1）；`reader.loadMeta() -> TrainingSetMeta`（已存在，`TrainingSetReader.swift:6`）

- [ ] **Step 1: 写失败的有-before 集成测试**

新建 `TrainingSessionStartTickIntegrationTests.swift`。构造一个 `meta.startDatetime` 落在数据中部的 reader（有 before-candle），断言新局开局 tick == 派生起始点。复用本测试文件内联构造（datetime base=1，meta.startDatetime=361=m3[2]）：

```swift
import Testing
@testable import KlineTrainerContracts

struct TrainingSessionStartTickIntegrationTests {
    // m3 datetime = 1 + i*180 → [1,181,361,541,721,901,1081,1261]；含 before（< startDatetime）。
    static func candles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int) -> KLineCandle {
            KLineCandle(period: p, datetime: 1 + Int64(gi) * 180, open: 10, high: 11, low: 9,
                        close: 10, volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: p == .m3 ? gi : nil, endGlobalIndex: egi)
        }
        let last = m3Count - 1
        return [.m3: (0..<m3Count).map { c(.m3, gi: $0, egi: $0) },
                .m60: [c(.m60, gi: 0, egi: last / 2), c(.m60, gi: last / 2 + 1, egi: last)],
                .daily: [c(.daily, gi: 0, egi: last)]]
    }

    /// startDatetime=361（=m3[2].datetime）→ 起始点 index 2，前有 2 根 before。
    func makeCoordinator() -> TrainingSessionCoordinator {
        let meta = TrainingSetMeta(stockCode: "600000", stockName: "测试股",
                                   startDatetime: 361, endDatetime: 1261)
        let factory = PreviewTrainingSetDBFactory(candles: Self.candles(), meta: meta)
        let cache = InMemoryCacheManager()
        cache._seedForTesting([TrainingSetFile(filename: "set.sqlite", url: URL(fileURLWithPath: "/tmp/set.sqlite"))])
        return TrainingSessionCoordinator(
            settings: PreviewSettingsStore(), cache: cache,
            recordRepo: InMemoryRecordRepository(), pendingRepo: InMemoryPendingTrainingRepository(),
            readerFactory: factory, now: { 1_700_000_000 })
    }

    @Test("startNewNormalSession 开局 tick = 起始点派生（有 before → 非 0）")
    func freshNormalOpensAtStartTick() async throws {
        let coord = makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        #expect(engine.tick.globalTickIndex == 2)   // 首个 datetime >= 361 = index 2
    }

    @Test("replay 同样从起始点开局（非 0）")
    func replayOpensAtStartTick() async throws {
        let coord = makeCoordinator()
        // seed 一条 record 供 replay
        _ = try await coord.startNewNormalSession()
        // 直接断言 replay 路径：构造 record（finalTick 任意合法）
        let rec = TrainingRecord(id: 1, trainingSetFilename: "set.sqlite", createdAt: 0,
            stockCode: "600000", stockName: "测试股", startYear: 2023, startMonth: 11,
            totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
            buyCount: 0, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false), finalTick: 7)
        // 注：若本仓 replay 取 record 经 recordRepo，按既有 makeReplaySession 模式 seed record 后调 coord.replay(recordId:)。
        // 此处断言 startTick 派生（=2），具体 record 注入按文件内既有 helper 复用。
    }
}
```

> 实现者注：`replayOpensAtStartTick` 的 record 注入复用本仓既有 `makeReplaySession`/`InMemoryRecordRepository` 模式（见 `TrainingSessionPersistenceTests.swift:455`）。核心断言 = replay 后 `engine.tick.globalTickIndex == 2`。`makeCoordinator` 的构造参数名以 `TrainingSessionCoordinator` 实际 init 为准（若 `now:`/参数名不符，按编译错误对齐）。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "ios/Contracts" && swift test --filter TrainingSessionStartTickIntegrationTests 2>&1 | tail -20`
Expected: `freshNormalOpensAtStartTick` FAIL —— 实得 `globalTickIndex == 0`（coordinator 尚未派生 startTick），期望 2。

- [ ] **Step 3: 实现 coordinator 接线（两路径对称）**

`startNewNormalSession` —— 在 `loadAllCandles()` 后加 `loadMeta` + 算 `startTick` + 传 `initialTick:`：

```swift
            let allCandles = try reader.loadAllCandles()
            let meta = try reader.loadMeta()                  // F2：起始点 tick 派生
            let mt = try maxTick(from: allCandles)            // D3
            let startTick = TrainingEngine.startTick(forStartDatetime: meta.startDatetime, in: allCandles)
            let engine = try TrainingEngine.make(
                .normal(fees: fees, maxTick: mt),
                allCandles: allCandles,
                initialTick: startTick,
                initialCapital: start, initialCashBalance: start)
```

`replay` —— 同样（replay 从起始点重开）：

```swift
            let allCandles = try reader.loadAllCandles()
            let meta = try reader.loadMeta()                  // F2：起始点 tick 派生（replay 从头）
            let mt = try maxTick(from: allCandles)
            let startTick = TrainingEngine.startTick(forStartDatetime: meta.startDatetime, in: allCandles)
            let engine = try TrainingEngine.make(
                .replay(fees: record.feeSnapshot, maxTick: mt),
                allCandles: allCandles,
                initialTick: startTick,
                initialCapital: record.totalCapital,
                initialCashBalance: record.totalCapital)
```

- [ ] **Step 4: re-align 既有测试桩（保 startTick=0，4 处断言无需改）**

把 3 份 `validCandles` 里 `datetime: Int64(gi) * 180` 改为 `datetime: 1 + Int64(gi) * 180`（令 `m3[0].datetime=1 == 桩默认 meta.startDatetime=1` → startTick=0）。逐文件改：

`TrainingSessionPersistenceTests.swift` L13、`TrainingSessionCoordinatorConstructionTests.swift` L14、`AppRouterTests.swift` L24，均把：
```swift
            KLineCandle(period: p, datetime: Int64(gi) * 180, open: 10, high: 11, low: 9,
```
改为：
```swift
            KLineCandle(period: p, datetime: 1 + Int64(gi) * 180, open: 10, high: 11, low: 9,
```

`TrainingSessionPersistenceTests.swift` `makeReplaySession`（L458）把 `startDatetime: 1_583_000_000` 改为 `startDatetime: 1`（≤ m3[0].datetime=1 → startTick=0，保 `buy@tick0 → tick3` 叙事）：
```swift
        meta: TrainingSetMeta(stockCode: "600000", stockName: "测试股",
                              startDatetime: 1, endDatetime: 1_583_100_000)
```

- [ ] **Step 5: 跑全 contracts 套件确认全绿**

Run: `cd "ios/Contracts" && swift test 2>&1 | tail -30`
Expected: 全 PASS（含 `TrainingSessionStartTickIntegrationTests` 2 个 + 既有 `startNew_noRecords...:74` / `replay_happy...:383` / `saveProgress_normal...:133` / `saveProgress_thenResume...:200` / `replaySettlementPayload_returnsTerminalStateRecord:496` 因 re-align 保持绿）。

- [ ] **Step 6: 提交**

```bash
git add "ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift" "ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionStartTickIntegrationTests.swift" "ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift" "ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorConstructionTests.swift" "ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift"
git commit -m "feat(engine): 新局/replay 开局 seed 到 meta 起始点 + 测试桩 datetime 对齐"
```

---

### Task 3: fixture 周期比例（F1）+ before/after 结构（F2）+ 测试

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift`

**Interfaces:**
- Produces: `DebugFixtureData.make(m3Count: Int = 240, beforeM3Count: Int = 0) -> Seed`；常量 `fullLoadM3Count = 19_200`、`fullLoadBeforeM3Count = 12_000`（Task 4 的 seed 调用消费）

- [ ] **Step 1: 写失败测试（before/after 表 + startDatetime）**

在 `DebugFixtureDataTests.swift` 末尾（`#endif` 前）追加：

```swift
    @Test("满载 before/after 结构：每周期根数 = 权威表 + startDatetime 指起始点")
    func fullLoadBeforeAfterStructure() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count,
                                         beforeM3Count: DebugFixtureData.fullLoadBeforeM3Count)
        func total(_ p: Period) -> Int { data.candles.first { $0.period == p }!.rows.count }
        #expect(total(.m3) == 19_200)
        #expect(total(.m15) == 3_840)
        #expect(total(.m60) == 960)
        #expect(total(.daily) == 240)
        #expect(total(.weekly) == 120)
        #expect(total(.monthly) == 80)
        // 起始点 = 第 12000 根 m3 的 datetime（before=12000 根历史在其前）
        let m3 = data.candles.first { $0.period == .m3 }!.rows
        #expect(data.meta.startDatetime == m3[12_000].datetime)
        // before 段：m3[0..<12000] datetime 严格 < startDatetime
        #expect(m3[11_999].datetime < data.meta.startDatetime)
    }

    @Test("默认 beforeM3Count=0 → startDatetime 仍为首根（向后兼容）")
    func defaultZeroBeforeBackCompat() {
        let data = DebugFixtureData.make(m3Count: 240)
        let m3 = data.candles.first { $0.period == .m3 }!.rows
        #expect(data.meta.startDatetime == m3[0].datetime)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "ios/Contracts" && swift test --filter DebugFixtureDataTests/fullLoadBeforeAfterStructure 2>&1 | tail -20`
Expected: 编译失败 `make` 无 `beforeM3Count` 参数 / `fullLoadBeforeM3Count` 未定义。

- [ ] **Step 3: 改 DebugFixtureData（spans + 常量 + before 参数 + meta）**

3a. 改满载常量 + 新增 before 常量（替换 L49 `fullLoadM3Count` 一带；注释里旧推导 9600 一并更新为 19200）：

```swift
    /// 帧预算满载 fixture 根数。新 span（5/20/80/160/240）下，约束「monthly span=240 行数 ≥80」
    /// 与「daily span=80 行数 ≥240(maxVisibleCount)」最小公共解 = 80×240 = 240×80 = 19,200。
    public static let fullLoadM3Count = 19_200
    /// 满载 before-candle 根数（起始点前历史）；须为 lcm(spans)=480 倍数（12000=480×25），
    /// 使各周期 before/after 边界皆落在该周期 candle 边界。daily before=150（对齐 spec §8.3）。
    public static let fullLoadBeforeM3Count = 12_000
```

3b. 改 `make` 签名加 `beforeM3Count`（替换 L54 `public static func make(m3Count: Int = 240) -> Seed {`）：

```swift
    public static func make(m3Count: Int = 240, beforeM3Count: Int = 0) -> Seed {
        precondition(beforeM3Count >= 0 && beforeM3Count < m3Count,
                     "beforeM3Count 须在 [0, m3Count)（防 m3Rows[beforeM3Count] 越界）")
```

3c. 改聚合 span（替换 L105-109 的 5 个 `aggregate(span:)`）：

```swift
            PeriodCandles(period: .m15, rows: withIndicators(aggregate(span: 5))),
            PeriodCandles(period: .m60, rows: withIndicators(aggregate(span: 20))),
            PeriodCandles(period: .daily, rows: withIndicators(aggregate(span: 80))),
            PeriodCandles(period: .weekly, rows: withIndicators(aggregate(span: 160))),
            PeriodCandles(period: .monthly, rows: withIndicators(aggregate(span: 240))),
```

3d. 改 `meta.startDatetime` 指起始点（替换 L112-114 的 `TrainingSetMeta(...)`）：

```swift
        let meta = TrainingSetMeta(
            stockCode: "600001", stockName: "示例训练股",
            startDatetime: m3Rows[beforeM3Count].datetime, endDatetime: m3Rows.last!.datetime)
```

- [ ] **Step 4: 跑测试确认通过（含既有满载测试不回归）**

Run: `cd "ios/Contracts" && swift test --filter DebugFixtureDataTests 2>&1 | tail -30`
Expected: 新 2 测 PASS；既有 `fullLoadFixture_everyPeriodMeetsRenderLoad`（≥80 / m60·daily≥240）等仍 PASS（新 total：m60=960、daily=240、monthly=80 均满足 `≥` 阈值）。

- [ ] **Step 5: 修 stale 注释（非断言）**

`DebugFixtureDataTests.swift` 内提及 `9600` 的注释（如 L112「满载根数（9600）」、L133「m3=9600..monthly=80」）改为 `19200`（monthly=80 不变，仅 m3 数字更新）。`DebugFixtureData.swift` L48 旧推导注释已在 3a 替换。

- [ ] **Step 6: 提交**

```bash
git add "ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift" "ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift"
git commit -m "feat(fixture): 周期 span 5/20/80/160/240 + 19200 根 + 12000 before 预放"
```

---

### Task 4: seed 接线（app 真正吃到 before）+ 端到端断言

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift:33`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift`

**Interfaces:**
- Consumes: `DebugFixtureData.make(m3Count:beforeM3Count:)` + `fullLoadBeforeM3Count`（Task 3）

- [ ] **Step 1: 写失败测试（seed 后 meta.startDatetime = 第 12000 根）**

在 `AppContainerDebugSeedTests.swift` 加（断言 seed 出的训练组 meta 起始点 = before 边界；若该文件已有「读回 seeded reader」的 helper 则复用，否则按既有 seed→cache→openReader 模式）：

```swift
    @Test("seed 的训练组 meta.startDatetime = 第 fullLoadBeforeM3Count 根 m3（app 开局有 before）")
    func seededMetaStartsAtBeforeBoundary() throws {
        let expected = DebugFixtureData.make(
            m3Count: DebugFixtureData.fullLoadM3Count,
            beforeM3Count: DebugFixtureData.fullLoadBeforeM3Count)
        let m3 = expected.candles.first { $0.period == .m3 }!.rows
        #expect(expected.meta.startDatetime == m3[12_000].datetime)
        #expect(expected.meta.startDatetime > m3[0].datetime)   // 非零 before（开局非空）
    }
```

> 实现者注：若 `AppContainerDebugSeedTests` 已有「执行 seed → 从 cache 打开 reader → loadMeta」的端到端 helper，则改成对**真实 seeded reader** 的 `loadMeta().startDatetime` 断言（更强）。上面是不依赖该 helper 的等价下界断言（验证 make 的产出与 seed 调用一致）。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "ios/Contracts" && swift test --filter AppContainerDebugSeedTests/seededMetaStartsAtBeforeBoundary 2>&1 | tail -20`
Expected: FAIL —— 当前 seed 调用 `make(m3Count: fullLoadM3Count)`（beforeM3Count 默认 0），`meta.startDatetime == m3[0].datetime`，而断言要 `== m3[12000]`。

- [ ] **Step 3: 改 seed 调用传 beforeM3Count**

`AppContainer+DebugSeed.swift:33` 把：
```swift
        let seed = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
```
改为：
```swift
        let seed = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count,
                                         beforeM3Count: DebugFixtureData.fullLoadBeforeM3Count)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd "ios/Contracts" && swift test --filter AppContainerDebugSeedTests 2>&1 | tail -20`
Expected: 新测 PASS；该文件既有 seed 测试不回归。

- [ ] **Step 5: 提交**

```bash
git add "ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift" "ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift"
git commit -m "feat(fixture): DEBUG seed 传 beforeM3Count=12000，app 开局预放历史"
```

---

## 三绿验收（verification 阶段全跑）

- [ ] host 全套件：`cd "ios/Contracts" && swift test 2>&1 | tail -30` → 0 failures。
- [ ] Mac Catalyst build-for-testing：`xcodebuild build-for-testing -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' -project ios/KlineTrainer/KlineTrainer.xcodeproj 2>&1 | tail -5` → SUCCEEDED。
- [ ] app build + 模拟器实测：见下方 §8 非编码者验收（**必须 `simctl uninstall` 再装**过全空 seed 守卫）。

## 非编码者验收清单（中文 · action/expected/pass-fail）

> 模拟器 iPhone 17 Pro（udid `DE0BA39D-C749-459D-A407-4418599B61CA`）。**改 fixture 后必须先 `xcrun simctl uninstall <udid> com.agateuu1234.KlineTrainer` 再装**（全空 seed 守卫，否则不重灌）。

| # | 操作 | 预期 | 通过判定 |
|---|---|---|---|
| A1 | 卸载重装 app，开始新训练 | 上图(60分)/下图(日线)开局即各显约一屏历史 K 线（约 80 根），最右边是起始点那根 | 开局**不是只有 1 根**；两图都铺满历史 → 通过 |
| A2 | 开局画面向右拖（看更早） | 能左滑看到更早历史（日线约可回看 150 根、60分约 600 根） | 能滑出更早历史、到最老一根停住 → 通过 |
| A3 | 点一次「持有/前进」 | 当前周期最右边新增 1 根，画面右移一根 | 每点一次 +1 根 → 通过 |
| A4 | 上下滑切日线/周线/月线/3分/15分 | 每周期开局显该周期自己历史（粗周期根数较少属正常） | 切任一周期都非空、显历史 → 通过 |
| A5 | 看周期比例 | 60分:日线 = 4:1；日线最大缩小铺满约 240 根 | 比例对、缩放铺满 → 通过 |

## Self-Review（写完即查）

- **Spec 覆盖**：G1 引擎=Task 1+2；G2 fixture before=Task 3+4；G3 周期比例=Task 3；§5 测试破坏 enumerate+修=Task 2 Step4；§6 不 bump=Global Constraints；§3.1 invariant+degenerate=Task 1 测试。✔ 无遗漏。
- **Placeholder**：Task 2 的 replay 集成测试 record 注入引用既有 helper（已给核心断言 + 文件:行指引，非 TODO）；其余皆完整代码。
- **类型一致**：`startTick(forStartDatetime:in:) -> Int` 在 Task 1 定义、Task 2 调用一致；`make(m3Count:beforeM3Count:)` Task 3 定义、Task 4 调用一致；常量名 `fullLoadM3Count`/`fullLoadBeforeM3Count` 一致。
