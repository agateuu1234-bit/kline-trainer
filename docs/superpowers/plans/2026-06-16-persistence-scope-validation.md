# Persistence-Scope 校验 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在数据信任边界补「`.m3` datetime 严格递增 + 聚合 open 落 `endGlobalIndex` 窗口」校验，使损坏训练集在 load 期被拒（codex R4 真修）。

**Architecture:** 两处闸门。**Reader**（`DefaultTrainingSetReader.loadAllCandles`，生产主校验）加两项检查，抛 `AppError.persistence(.dbCorrupted)`。**make**（`TrainingEngine.make`，纵深防御）镜像校验 1（m3 datetime 单调），抛 `AppError.trainingSet(.emptyData)`，保护非 GRDB 源。校验 1 必须在校验 2 的 `partitioningIndex` 之前执行（m3 数组按 endGlobalIndex 存储，仅校验 1 证明其 datetime 升序）。

**Tech Stack:** Swift 6；reader 测试 XCTest（`KlineTrainerPersistenceTests`，GRDB fixture）；make 测试 Swift Testing（`KlineTrainerContractsTests`）；`swift test`（host）+ Mac Catalyst `build-for-testing`。

**Spec:** `docs/superpowers/specs/2026-06-16-persistence-scope-validation-design.md`（v1.2，opus 4.8 xhigh 已 APPROVE）。

---

## Task 0: 基线快照

**Files:** 无改动（仅记录）。

- [ ] **Step 1: 记录基线测试数与绿状态**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: 末行形如 `Test Suite 'All tests' passed`，`0 failures`。记下「N tests / M suites」用于 Task 4 验收对比。

---

## Task 1: Reader 校验 1 —— `.m3` datetime 严格递增

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift`（`loadAllCandles` 内 `if let m3Candles = result[.m3]` 块，约 L153-172）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetReaderTests.swift`

- [ ] **Step 1: 写失败测试（datetime 下降）**

在 `DefaultTrainingSetReaderTests.swift` 末尾 `}` 前加：

```swift
    // MARK: - .m3 datetime 严格递增（persistence-scope RFC 校验 1）

    /// .m3 datetime 随 endGlobalIndex 递增而下降（endGlobalIndex 仍严格递增，隔离校验 1，不触 L90）→ .dbCorrupted
    func test_loadAllCandles_m3DatetimeDescending_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(200, 0, 0), (100, 1, 1)]),   // datetime 200 → 100 下降；endGIdx 0,1 严格递增
            (.daily, [(100, nil, 1)]),
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    /// .m3 datetime 重复（500,500），endGlobalIndex 严格递增 0,1 → 隔离校验 1（非 L90）→ .dbCorrupted
    func test_loadAllCandles_m3DatetimeDuplicate_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(500, 0, 0), (500, 1, 1)]),
            (.daily, [(500, nil, 1)]),
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter "DefaultTrainingSetReaderTests/test_loadAllCandles_m3Datetime" 2>&1 | tail -5`
Expected: 两条均 FAIL（当前 reader 不校验 datetime，`loadAllCandles` 不抛 → `XCTAssertThrowsError` 失败）。

- [ ] **Step 3: 实现校验 1**

在 `DefaultTrainingSetReader.swift` 的 `if let m3Candles = result[.m3] {` 块内，**紧接** 现有 m3-axis 校验 for 循环（`guard let g = c.globalIndex …` 那段）之后、`let m3Max = …` 之前，插入：

```swift
            // 校验 1（persistence-scope RFC）：.m3 datetime 严格递增。synthesize/candleDatetime 的
            // partitioningIndex{datetime>=X} 依赖此单调；非单调 → 定位错 start。必须在校验 2 之前
            // （m3 按 endGlobalIndex 存储，仅此校验证明其 datetime 升序）。
            for i in m3Candles.indices.dropFirst() {
                guard m3Candles[i].datetime > m3Candles[i - 1].datetime else {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
```

- [ ] **Step 4: 跑测试确认通过 + 不回归**

Run: `cd ios/Contracts && swift test --filter "DefaultTrainingSetReaderTests" 2>&1 | tail -5`
Expected: 全部 PASS（含两条新测试 + 既有 happy `test_loadAllCandles_groupsByPeriod`，其 m3 datetime 1000/1180/1360 严格递增不受影响）。

- [ ] **Step 5: Mutation-verify（证明非 vacuous）**

临时把 Step 3 的 `>` 改成 `>=`，Run: `cd ios/Contracts && swift test --filter "test_loadAllCandles_m3DatetimeDuplicate" 2>&1 | tail -3`
Expected: 该测试 FAIL（重复 datetime 在 `>=` 下被放过 → 不抛）。确认后改回 `>`，重跑确认 PASS。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetReaderTests.swift
git commit -m "feat(persistence): reader 校验 1 — .m3 datetime 严格递增 (R4 真修)"
```

---

## Task 2: Reader 校验 2 —— 聚合 open 落 `endGlobalIndex` 窗口

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift`（同一 `if let m3Candles` 块，`m3Max` 跨周期循环之后）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetReaderTests.swift`

- [ ] **Step 1: 写失败测试（窗口越界 + future-overflow + pre-window 通过）**

在 `DefaultTrainingSetReaderTests.swift` 末尾 `}` 前加：

```swift
    // MARK: - 聚合 open 落 endGlobalIndex 窗口（persistence-scope RFC 校验 2）

    /// 聚合 open datetime 解析到 s > endGlobalIndex（open 越窗末）→ .dbCorrupted
    /// 强 fixture：m3 5 根，daily datetime=1360 → s=2，但 endGlobalIndex=1（s 在 m3 范围内但 > 窗末）。
    func test_loadAllCandles_aggregateOpenPastWindowEnd_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1000, 0, 0), (1180, 1, 1), (1360, 2, 2), (1540, 3, 3), (1720, 4, 4)]),
            (.daily, [(1360, nil, 1)]),   // s=partitioningIndex{>=1360}=2 > endGlobalIndex=1
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    /// 聚合 datetime 大于所有 m3（future-overflow）→ s=m3.count > endGlobalIndex → .dbCorrupted
    func test_loadAllCandles_aggregateFutureOverflow_throwsDbCorrupted() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1000, 0, 0), (1180, 1, 1), (1360, 2, 2), (1540, 3, 3), (1720, 4, 4)]),
            (.daily, [(9999, nil, 4)]),   // s=5 (=m3.count) > endGlobalIndex=4
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }

    /// pre-window 聚合（datetime < m3[0]、endGlobalIndex=0 后端 clamp）→ s=0 ≤ 0 → 通过（R1-H1 不回归 killer）
    func test_loadAllCandles_preWindowAggregate_loadsSuccessfully() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1000, 0, 0), (1180, 1, 1), (1360, 2, 2)]),
            (.daily, [(500, nil, 0)]),    // datetime 500 < m3[0] 1000 → s=0 ≤ endGlobalIndex=0
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        let candles = try reader.loadAllCandles()
        XCTAssertEqual(candles[.m3]?.count, 3)
        XCTAssertEqual(candles[.daily]?.count, 1)
        reader.close()
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter "DefaultTrainingSetReaderTests/test_loadAllCandles_aggregate" 2>&1 | tail -6`
Expected: 两条 `aggregate*` 越界测试 FAIL（当前不校验窗口 → 不抛）。`preWindowAggregate` 当前已 PASS（无校验时 daily 通过既有检查；加校验后仍须 PASS）。

- [ ] **Step 3: 实现校验 2**

在 `DefaultTrainingSetReader.swift` 同一 `if let m3Candles = result[.m3]` 块内，**紧接** 现有「其它周期 endGlobalIndex <= m3Max」for 循环之后（仍在 `if let` 块内），插入：

```swift
            // 校验 2（persistence-scope RFC）：聚合 open 落 endGlobalIndex 窗口。bucket=[s,endGlobalIndex]，
            // s=首个 datetime>=聚合 datetime 的 m3（= synthesize rawStart）。s>endGlobalIndex = 空 bucket /
            // open 越窗末 / future-overflow → corrupt。依赖校验 1 已过（m3 datetime 单调 → partitioningIndex 良定义）。
            for (period, candles) in result where period != .m3 {
                for c in candles {
                    let s = m3Candles.partitioningIndex { $0.datetime >= c.datetime }
                    guard s <= c.endGlobalIndex else {
                        throw AppError.persistence(.dbCorrupted)
                    }
                }
            }
```

- [ ] **Step 4: 跑测试确认通过 + 不回归**

Run: `cd ios/Contracts && swift test --filter "DefaultTrainingSetReaderTests" 2>&1 | tail -5`
Expected: 全部 PASS（含三条新测试 + 既有 happy `test_loadAllCandles_groupsByPeriod`：daily datetime=1000 → s=0 ≤ endGlobalIndex=2 通过）。

- [ ] **Step 5: Mutation-verify**

临时把 Step 3 的 `guard s <= c.endGlobalIndex` 改成 `guard s <= c.endGlobalIndex + 100`（放宽），Run: `cd ios/Contracts && swift test --filter "test_loadAllCandles_aggregateOpenPastWindowEnd" 2>&1 | tail -3`
Expected: 该测试 FAIL（越界被放过 → 不抛）。确认后改回 `guard s <= c.endGlobalIndex`，重跑确认 PASS。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetReaderTests.swift
git commit -m "feat(persistence): reader 校验 2 — 聚合 open 落 endGlobalIndex 窗口 (R4 真修)"
```

---

## Task 3: make 校验 1 镜像（纵深防御）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（`make` 工厂 isContiguousM3Axis guard 之后；新 helper 在 `isContiguousM3Axis` 旁，约 L538）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift`

- [ ] **Step 1: 写失败测试（含 happy 回归 + 可信 mutation 前提）**

在 `TrainingEngineCoreTests.swift` 的 `makeThrowsOnGappedM3()`（约 L324）之后插入。注意 `initialUpperPeriod/.m3 + initialLowerPeriod: .m3` 让面板校验用 .m3（仅供 m3 dict），从而 **去掉校验 1 后 make 会成功** → mutation-verify 可信：

```swift
    @Test func makeThrowsOnNonMonotonicM3Datetime() {
        // 合法连续轴（globalIndex==endGlobalIndex==i），datetime 非单调（100 → 50）→ 纵深防御抛 .emptyData
        func m3c(_ i: Int, _ dt: Int64) -> KLineCandle {
            KLineCandle(period: .m3, datetime: dt, open: 10, high: 10, low: 10, close: 10,
                        volume: 1, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: i, endGlobalIndex: i)
        }
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 1),
                                    allCandles: [.m3: [m3c(0, 100), m3c(1, 50)]],
                                    initialCapital: 100_000, initialCashBalance: 100_000,
                                    initialUpperPeriod: .m3, initialLowerPeriod: .m3)
        }
    }

    @Test func makeSucceedsOnMonotonicM3Datetime() throws {
        func m3c(_ i: Int, _ dt: Int64) -> KLineCandle {
            KLineCandle(period: .m3, datetime: dt, open: 10, high: 10, low: 10, close: 10,
                        volume: 1, amount: nil, ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil, globalIndex: i, endGlobalIndex: i)
        }
        let e = try TrainingEngine.make(.normal(fees: Self.fees, maxTick: 1),
                                        allCandles: [.m3: [m3c(0, 50), m3c(1, 100)]],
                                        initialCapital: 100_000, initialCashBalance: 100_000,
                                        initialUpperPeriod: .m3, initialLowerPeriod: .m3)
        #expect(e.maxTick == 1)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter "TrainingEngineCoreTests/makeThrowsOnNonMonotonicM3Datetime|TrainingEngineCoreTests/makeSucceedsOnMonotonicM3Datetime" 2>&1 | tail -5`
Expected: `makeThrowsOnNonMonotonicM3Datetime` FAIL（当前 make 不校验 datetime → 不抛）；`makeSucceedsOnMonotonicM3Datetime` PASS（happy）。

- [ ] **Step 3: 实现 helper + guard**

在 `TrainingEngine.swift` 的 `isContiguousM3Axis` 函数（约 L538，`return true` 后的 `}`）之后，新增 helper：

```swift
    /// persistence-scope RFC 纵深防御：.m3 datetime 严格递增（synthesize 的 partitioningIndex{datetime>=X}
    /// 谓词单调性前提）。reader 是生产主校验；此为 fake/非 GRDB 源喂 make 的普适末线——消除未定义行为，
    /// 不保证窗口正确性（窗口越界由 synthesize 的 min(rawStart,tick) clamp 兜底为 bounded-GIGO）。
    private static func isStrictlyIncreasingM3Datetime(_ m3: [KLineCandle]) -> Bool {
        for i in m3.indices.dropFirst() {
            guard m3[i].datetime > m3[i - 1].datetime else { return false }
        }
        return true
    }
```

在 `make` 中，**紧接** 现有 `guard TrainingEngine.isContiguousM3Axis(m3) else { … }`（约 L209-211）之后，插入：

```swift
        guard TrainingEngine.isStrictlyIncreasingM3Datetime(m3) else {
            throw AppError.trainingSet(.emptyData)            // .m3 datetime 非严格递增（损坏 / 非 GRDB 源）
        }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter "TrainingEngineCoreTests" 2>&1 | tail -5`
Expected: 全部 PASS（含两条新测试；既有 `makeThrowsOnUnsortedM3`/`makeThrowsOnGappedM3` 仍 PASS——其 `isContiguousM3Axis` 在新 guard 之前先抛 .emptyData）。

- [ ] **Step 5: Mutation-verify**

临时注释掉 Step 3 的 `guard TrainingEngine.isStrictlyIncreasingM3Datetime(m3)` 整段，Run: `cd ios/Contracts && swift test --filter "makeThrowsOnNonMonotonicM3Datetime" 2>&1 | tail -3`
Expected: FAIL（去掉 guard 后 m3 轴合法 + 面板 .m3 存在 → make 成功 → `#expect(throws:)` 失败）。确认后恢复 guard，重跑确认 PASS。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineCoreTests.swift
git commit -m "feat(engine): make 纵深防御 — .m3 datetime 严格递增镜像 (R4 真修)"
```

---

## Task 4: 全量验证 + 验收清单 + spec 收尾

**Files:**
- Create: `docs/acceptance/2026-06-16-persistence-scope-validation.md`
- Modify: `docs/superpowers/specs/2026-06-16-persistence-scope-validation-design.md`（状态 → 已实施）

- [ ] **Step 1: 全量 host 测试（必须含意外回归扫描）**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: `0 failures`，count = Task 0 基线 + 7（新增 5 reader + 2 make）。**若有 happy-path make/engine 测试因新 datetime 校验失败**（理论上无——既有 happy 测试均用严格递增 datetime；已审 RenderStateBuilderTests/TrainingEngineCoreTests），则该测试 fixture 用了非严格 datetime：改为严格递增 datetime（test-only，真实数据恒严格），不得弱化生产校验。

- [ ] **Step 2: Mac Catalyst build-for-testing**

Run（worktree 根）:
```bash
xcodebuild build-for-testing -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -3
```
Expected: `** TEST BUILD SUCCEEDED **`（命令具体 scheme/destination 以仓库既有 catalyst CI job 为准；若本地无 Xcode，则记录 PR CI `Mac Catalyst build-for-testing on macos-15` 结果）。

- [ ] **Step 3: 写验收清单（非编码者可执行；Chinese；二元判定；禁 forbidden_phrases）**

写 `docs/acceptance/2026-06-16-persistence-scope-validation.md`（N 用 Step 1 实测数填）：

```markdown
# 验收清单 — persistence-scope 校验（R4 真修：reader+make datetime/聚合窗口边界）

## 自动化校验（命令行可执行）

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | `<N> tests` 全过，`0 failures`（N=基线+7） | ☐ |
| 2 | `git diff origin/main...HEAD --stat -- ios/ docs/` | 改动集 ⊆ {DefaultTrainingSetReader.swift, DefaultTrainingSetReaderTests.swift, TrainingEngine.swift, TrainingEngineCoreTests.swift, 本 spec/plan/acceptance}；无 .sql/schema/workflow/CONTRACT_VERSION 改动 | ☐ |
| 3 | `cd ios/Contracts && swift test --filter "test_loadAllCandles_m3DatetimeDescending\|test_loadAllCandles_m3DatetimeDuplicate" 2>&1 \| tail -2` | 两条均 PASS（m3 datetime 非单调被拒 .dbCorrupted） | ☐ |
| 4 | `cd ios/Contracts && swift test --filter "test_loadAllCandles_aggregateOpenPastWindowEnd\|test_loadAllCandles_aggregateFutureOverflow" 2>&1 \| tail -2` | 两条均 PASS（聚合 open 越窗被拒 .dbCorrupted） | ☐ |
| 5 | `cd ios/Contracts && swift test --filter "test_loadAllCandles_preWindowAggregate" 2>&1 \| tail -2` | PASS（pre-window 聚合 load 成功，R1-H1 不回归） | ☐ |
| 6 | `cd ios/Contracts && swift test --filter "makeThrowsOnNonMonotonicM3Datetime" 2>&1 \| tail -2` | PASS（make 纵深防御拒 .emptyData） | ☐ |
| 7 | `grep -nc "isStrictlyIncreasingM3Datetime" ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 输出 `2`（helper 定义 + make 调用各 1） | ☐ |
| 8 | PR checks 页查 `Mac Catalyst build-for-testing on macos-15` | SUCCESS | ☐ |
| 9 | PR checks 页查 app build required check | SUCCESS | ☐ |

## Residuals
- R-A：DefaultTrainingSetDataVerifier（warmup/content 计数）仍仅在下载验收路径跑，未接 load 路径（内容策略，另案）。
- R-B：聚合周期 datetime 整体单调未校验；唯一消费者 CrosshairLayout 时间轴标签（显示用，乱序仅错标签非泄漏）。
- R-C：reader 内容校验失败经内层 catch 上抛、不自动 cache.delete+重试（既有行为，本 RFC 不改）。
```

> 说明：表中每行「Expected」均为二元可判定值，避免「验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine」。

- [ ] **Step 4: 更新 spec 状态**

把 spec 头部 `- **状态：** 已收敛（…）→ 进 writing-plans` 改为 `- **状态：** 已实施（plan 全任务完成，待 codex:adversarial-review）`。

- [ ] **Step 5: Commit**

```bash
git add docs/acceptance/2026-06-16-persistence-scope-validation.md docs/superpowers/specs/2026-06-16-persistence-scope-validation-design.md
git commit -m "docs(persistence-scope): 验收清单 + spec 状态 → 已实施"
```

---

## Self-Review（写完计划后自查）

**1. Spec coverage：**
- §4.1 校验 1（m3 datetime 严格递增）→ Task 1（reader）+ Task 3（make 镜像）。✓
- §4.2 校验 2（聚合 open 落窗口，仅 reader）→ Task 2。✓
- §4.2 N2 硬性顺序（校验 1 在校验 2 前）→ Task 1 插点在 m3-axis 后、Task 2 插点在 m3Max 后，文本顺序保证 1 先于 2。✓
- §5 失败模式（reader .dbCorrupted / make .emptyData，不改恢复）→ 各 Task 的错误类型 + 不动 coordinator。✓
- §6 不 bump CONTRACT_VERSION → 验收 #2 断言无 CONTRACT_VERSION 改动。✓
- §7 测试策略（mutation-verify + 强 fixture + 重复-datetime 保 endGIdx 严格）→ 各 Task Step 5 + Task 1/2 fixture。✓
- §8 residuals（R-A/R-B/R-C）→ 验收 doc Residuals 段。✓
- §9 验收 → Task 4 acceptance doc。✓

**2. Placeholder scan：** 无 TBD/TODO；每个改码步骤含完整代码；命令含预期输出。Task 4 Step 1 的「N」是实测数记录（非占位）。✓

**3. Type consistency：** `isStrictlyIncreasingM3Datetime`（Task 3 定义 + make 调用 + 验收 #7 grep）名称一致；`partitioningIndex`（public on RandomAccessCollection，Persistence 可用）；`AppError.persistence(.dbCorrupted)` / `AppError.trainingSet(.emptyData)` 与既有一致；fixture 元组 `(datetime:Int64, gIdx:Int?, endGIdx:Int)` 与 `TrainingSetSQLiteFixture.ConfigOptions.candles` 一致。✓
