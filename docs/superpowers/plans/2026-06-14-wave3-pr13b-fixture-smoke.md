# Wave 3 PR 13b — 全 app fixture provisioning + 生产路径 E2E smoke 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 闭合 Wave 3 10b-deferred 的 §C（debug-only 全 app fixture provisioning：经组合根 seed 缓存+pending+history，使运行时矩阵可在真 app 跑）+ §D（生产路径 E2E smoke：真实 `DownloadAcceptanceRunner` 路径断言下载组下游可消费）。

**Architecture:** §C = 一个 `#if DEBUG` **Sources-target**（`KlineTrainerPersistence`）确定性 fixture 生成器（rich 多周期蜡烛 sqlite + records + pending + settings 描述）+ `AppContainer.seedDebugFixturesIfEmpty()` 经真 `DefaultAppDB`/`DefaultFileSystemCacheManager` 落库 + `KlineTrainerApp` 的 `#if DEBUG` env-var 触发。幂等（仅 store 空时 seed）+ Release 编译期剔除。§D = 扩展既有真实栈集成测试，断言 stored 组经真 `DefaultTrainingSetDBFactory.openAndVerify` + `loadAllCandles` 下游可消费。

**Tech Stack:** Swift 6 / GRDB / Swift Testing；`ios/Contracts` SwiftPM（host `swift test` + Catalyst）+ `ios/KlineTrainer` app target（app-build CI）。

**Source-of-truth spec:** `docs/superpowers/specs/2026-06-14-wave3-pr13-completion-design.md` §C/§D。

**评审通道（trust-boundary）:** 改 `ios/**/*.swift`（+ 可能 app target）→ 须经 `codex:adversarial-review`（codex 配额耗尽方 fallback opus 4.8 xhigh）+ Catalyst + app-build required check。

**关键既有事实（已 grep 核实 worktree `bcf32b1`）:**
- 组合根 `AppContainer.init(config:) throws`（`ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift`）构造 `DefaultAPIClient`/`DefaultAppDB`(=`db`, 即 `AppDB` = RecordRepository & PendingTrainingRepository & SettingsDAO & SessionFinalizationPort & AcceptanceJournalDAO)/`DefaultFileSystemCacheManager`(=`cache`)/`SettingsStore`(=`settings`)/`DownloadAcceptanceRunner`/`TrainingSessionCoordinator`/`AppRouter`。`db`/`cache`/`settings` 是 public let。
- `KlineTrainerApp.swift`（`ios/KlineTrainer/KlineTrainer/`）`@MainActor init()`：建 `AppConfig` + `try AppContainer(config:)`；**无** launch-arg/env 读取；backendBaseURL 硬编码 `.local`。
- seed API：`SessionFinalizationPort.finalizeSession(record:ops:drawings:sessionKey:) throws -> Int64`（`db`）；`PendingTrainingRepository.savePending(_:) throws`（`db`）；`SettingsDAO.saveSettings(_:) throws`（`db`）；`CacheManager.store(downloadedZip:meta:) throws -> TrainingSetFile`（`cache`，参数 `downloadedZip` 实为**已解压 sqlite** URL，store 校验 PRAGMA user_version==meta.schemaVersion，不校验 CRC）。
- 类型 init（全字段）：`TrainingRecord`(id:trainingSetFilename:createdAt:stockCode:stockName:startYear:startMonth:totalCapital:profit:returnRate:maxDrawdown:buyCount:sellCount:feeSnapshot:finalTick:)；`PendingTraining`(trainingSetFilename:globalTickIndex:upperPeriod:lowerPeriod:positionData:cashBalance:feeSnapshot:tradeOperations:drawings:startedAt:accumulatedCapital:drawdown:sessionKey:)；`AppSettings`(commissionRate:minCommissionEnabled:totalCapital:displayMode:) + `.default`（0.0001/false/100_000/.system）；`TrainingSetMetaItem`(id:stockCode:stockName:filename:schemaVersion:contentHash:)。
- 训练组 sqlite schema（`TrainingSetSQLiteFixture` + `DefaultTrainingSetDBFactory`）：`PRAGMA user_version=1`；`meta(stock_code,stock_name,start_datetime,end_datetime NOT NULL)`；`klines(id PK, period, datetime, open, high, low, close, volume, amount, ma66, boll_upper, boll_mid, boll_lower, macd_diff, macd_dea, macd_bar, global_index, end_global_index NOT NULL)` + 2 索引。
- **reader 校验不变量**（`DefaultTrainingSetReader`）：m3 蜡烛 `global_index == end_global_index`、0 基、严格递增；OHLC finite + positive + `high >= max(open,close,low)` + `low <= min(open,close,high)` + `volume >= 0`；其它周期 `end_global_index <= max m3 end_global_index`；指标列 nullable。
- `AppRouter.loadHome()` 读 `recordRepo.listRecords(limit:nil)` + `recordRepo.statistics()` + `pendingRepo.loadPending()` + `cache.listAvailable()` 填 `HomeContent`（**property 名 `isResuming`/`hasCachedSets`**/statistics/records；`hasPending` 仅 init 参数名 → 存为 `isResuming`，断言用 `isResuming`）。
- 既有真实栈集成测试 `DownloadAcceptanceRunnerIntegrationTests.swift`（`KlineTrainerPersistenceTests`）：`run_realPipeline_happyPath_storesAndConfirms`——真 `DefaultFileSystemCacheManager`/`DefaultZipIntegrityVerifier`/`DefaultZipExtractor`/`DefaultTrainingSetDBFactory`/`DefaultDownloadAcceptanceCleaner` + `FakeAPIClient` + `TrainingSetSQLiteFixture`/`ZipFixture`/`CacheFixture`；断言 `.confirmed` + 文件存在 + schemaVersion==1 + journal confirmed + zip 已清；**未**断言下游可 open+loadAllCandles。
- `DefaultTrainingSetReader.loadAllCandles() throws -> [Period: [KLineCandle]]` + `loadMeta() throws -> TrainingSetMeta`；`DefaultTrainingSetDBFactory.openAndVerify(file:expectedSchemaVersion:) throws -> TrainingSetReader`。
- `#if DEBUG` 在 Contracts 包广用（PreviewFakes/preview）；app target 可直接用 `#if DEBUG`。

**Baseline:** `swift test`（`ios/Contracts`）绿（13a 合并后 rebase；本计划在 13a-merged baseline 上执行，测试基数以届时实测为准）。

---

## 范围决策（plan-stage 明示，供 review）

- **rich seed 数据集**：≥240 根 m3 蜡烛（确定性 sin 价格走势，足以 pinch 缩放/平移/画水平线/跨缩放还原 + 步进至局终 replay/手动强平）+ 3 根 daily（跨周期十字光标 snap）+ 有效 OHLC + 0 基严格递增 global_index。**指标**：计算 **MA66**（简单 rolling mean，主叠加层渲染，证指标渲染路径）；**BOLL/MACD 留 NULL**（schema nullable；交互矩阵测 pinch/draw/crosshair/trade/replay，非指标渲染精度——full BOLL/MACD parity 是 backend `import_csv` 职责，不在 debug seed 必需面，deferred 记 13b 范围注）。
- **seed 注入**：`AppContainer` 加 `#if DEBUG` 方法 `seedDebugFixturesIfEmpty()`（幂等：仅 `cache.listAvailable().isEmpty` 时 seed）；`KlineTrainerApp.init` 在 `#if DEBUG` + env `KLINE_SEED_FIXTURE == "1"` 时调它。Release 二进制零 seed 代码。
- **cache seed 走 `cache.store` 直注**（非真 download 路径）：store 不校验 CRC，故 contentHash 用占位；下载路径真实性由 §D smoke 独立覆盖。
- **reset 故事**：app.sqlite singleton 无法独立目录隔离 → 删 app 重置（DEBUG-only 可接受，doc 注明）。

---

## File Structure

- **Create** `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift` — `#if DEBUG` 纯生成器（确定性蜡烛 [period→rows] + MA66 + records/pending/settings 描述）。host 可测。
- **Create** `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugTrainingSetWriter.swift` — `#if DEBUG` 把生成的蜡烛写成训练组 sqlite（GRDB，schema 对齐）。
- **Create** `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift` — `#if DEBUG` `AppContainer.seedDebugFixturesIfEmpty()`（幂等，经 db/cache/settings 落库）。
- **Modify** `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift` — `#if DEBUG` env-var 触发 seed。
- **Create** tests:
  - `ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift` — §C 生成器不变量。
  - `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift` — §C seed 端到端（真 DefaultAppDB+cache temp）。
  - extend `ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift` — §D 下游可消费 smoke。
- **Create** `docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md` — 非-coder 验收清单。

---

## Task 1: §C 确定性 fixture 生成器（host-testable 纯值）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift`
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
import Foundation
@testable import KlineTrainerPersistence
import KlineTrainerContracts

#if DEBUG
@Suite("DebugFixtureData：确定性 rich 训练组蜡烛生成（§C，host 全测）")
struct DebugFixtureDataTests {

    @Test("m3 蜡烛满足 reader 不变量：0 基严格递增 + global==end + 有效 OHLC + volume>=0")
    func m3Candles_satisfyReaderInvariants() {
        let data = DebugFixtureData.make(m3Count: 240)
        let m3 = data.candles.first(where: { $0.period == .m3 })!.rows
        #expect(m3.count == 240)
        for (i, c) in m3.enumerated() {
            #expect(c.globalIndex == i)
            #expect(c.endGlobalIndex == i)
            #expect(c.high >= max(c.open, c.close, c.low))
            #expect(c.low <= min(c.open, c.close, c.high))
            #expect(c.open > 0 && c.close > 0 && c.high > 0 && c.low > 0)
            #expect(c.open.isFinite && c.close.isFinite && c.high.isFinite && c.low.isFinite)
            #expect(c.volume >= 0)
        }
    }

    @Test("daily 蜡烛：global_index nil + end_global_index <= max m3 end + 递增")
    func dailyCandles_endIndexWithinM3Range() {
        let data = DebugFixtureData.make(m3Count: 240)
        let m3 = data.candles.first(where: { $0.period == .m3 })!.rows
        let maxM3End = m3.map(\.endGlobalIndex).max()!
        let daily = data.candles.first(where: { $0.period == .daily })!.rows
        #expect(!daily.isEmpty)
        var prevEnd = -1
        for c in daily {
            #expect(c.globalIndex == nil)
            #expect(c.endGlobalIndex <= maxM3End)
            #expect(c.endGlobalIndex > prevEnd)   // 递增
            prevEnd = c.endGlobalIndex
        }
        #expect(daily.last!.endGlobalIndex == maxM3End)   // 末根覆盖到最后
    }

    @Test("MA66：前 65 根 NULL，第 66 根起 = 近 66 根 close 均值")
    func ma66_rollingMean() {
        let data = DebugFixtureData.make(m3Count: 240)
        let m3 = data.candles.first(where: { $0.period == .m3 })!.rows
        #expect(m3[0].ma66 == nil)
        #expect(m3[64].ma66 == nil)
        let expected65 = (0...65).map { m3[$0].close }.reduce(0, +) / 66.0
        #expect(abs((m3[65].ma66 ?? -1) - expected65) < 1e-9)
    }

    @Test("确定性：两次生成完全相同（无随机）")
    func deterministic() {
        let a = DebugFixtureData.make(m3Count: 100)
        let b = DebugFixtureData.make(m3Count: 100)
        let am3 = a.candles.first(where: { $0.period == .m3 })!.rows
        let bm3 = b.candles.first(where: { $0.period == .m3 })!.rows
        #expect(am3.map(\.close) == bm3.map(\.close))
    }

    @Test("records/pending/settings 描述非空且自洽")
    func seedDescriptors_present() {
        let data = DebugFixtureData.make(m3Count: 240)
        #expect(data.records.count >= 2)
        #expect(data.pending != nil)
        #expect(data.settings.totalCapital == 100_000)
        #expect(data.trainingSetFilename.hasSuffix(".sqlite"))
        // pending 引用同一训练组（可恢复）
        #expect(data.pending!.trainingSetFilename == data.trainingSetFilename)
    }
}
#endif
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter DebugFixtureDataTests`
Expected: FAIL（`DebugFixtureData` 未定义）。

- [ ] **Step 3: 实现 `DebugFixtureData`**

```swift
// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift
// Kline Trainer — debug-only fixture 数据生成（Wave 3 PR 13b §C）
//
// #if DEBUG only：确定性（无随机）生成 rich 训练组蜡烛 + records/pending/settings 描述，供
// AppContainer 全 app fixture provisioning。Release 编译期剔除（整文件 #if DEBUG）。
// 蜡烛满足 DefaultTrainingSetReader 不变量（0 基严格递增 global==end / 有效 OHLC / volume>=0 /
// daily end<=max m3 end）。指标：MA66 rolling mean；BOLL/MACD 留 NULL（nullable；交互矩阵不需指标精度，
// full parity 归 backend import_csv，见 plan 范围注）。

#if DEBUG
import Foundation
import KlineTrainerContracts

public enum DebugFixtureData {

    /// 单根蜡烛行（period 内）。global_index：m3=i；daily=nil。
    public struct CandleRow: Equatable, Sendable {
        public let datetime: Int64
        public let open: Double, high: Double, low: Double, close: Double
        public let volume: Int
        public let ma66: Double?
        public let globalIndex: Int?
        public let endGlobalIndex: Int
    }

    public struct PeriodCandles: Equatable, Sendable {
        public let period: Period
        public let rows: [CandleRow]
    }

    public struct Seed {
        public let trainingSetFilename: String     // 缓存内文件名（.sqlite）
        public let meta: TrainingSetMeta            // 训练组 meta（写入 sqlite）
        public let candles: [PeriodCandles]
        public let records: [TrainingRecord]        // 历史
        public let pending: PendingTraining?        // 待恢复局
        public let settings: AppSettings
    }

    /// 起始 epoch（确定性；不依赖当前时间——Date.now 在确定性 fixture 不可取）。
    private static let baseEpoch: Int64 = 1_700_000_000
    private static let m3Step: Int64 = 180          // 3 分钟
    private static let dailySpan = 80               // 每 80 根 m3 = 1 个 daily

    public static func make(m3Count: Int = 240) -> Seed {
        let filename = "debug-fixture-600001.sqlite"
        // 1) m3 蜡烛（确定性 sin 价格走势）
        var m3Rows: [CandleRow] = []
        var closes: [Double] = []
        for i in 0..<m3Count {
            let close = 10.0 + 2.0 * sin(Double(i) * 0.15)
            let open = 10.0 + 2.0 * sin(Double(max(0, i - 1)) * 0.15)
            let high = max(open, close) + 0.3
            let low = min(open, close) - 0.3
            closes.append(close)
            let ma66: Double? = i >= 65
                ? closes[(i - 65)...i].reduce(0, +) / 66.0
                : nil
            m3Rows.append(CandleRow(
                datetime: baseEpoch + Int64(i) * m3Step,
                open: open, high: high, low: low, close: close,
                volume: 1000 + i * 10, ma66: ma66,
                globalIndex: i, endGlobalIndex: i))
        }
        // 2) daily 蜡烛（每 dailySpan 根 m3 聚合一根；end_global_index 指向该 day 末根 m3）
        var dailyRows: [CandleRow] = []
        var start = 0
        while start < m3Count {
            let end = min(start + dailySpan - 1, m3Count - 1)
            let slice = m3Rows[start...end]
            let o = slice.first!.open, c = slice.last!.close
            let hi = slice.map(\.high).max()!, lo = slice.map(\.low).min()!
            dailyRows.append(CandleRow(
                datetime: m3Rows[start].datetime,
                open: o, high: hi, low: lo, close: c,
                volume: slice.map(\.volume).reduce(0, +), ma66: nil,
                globalIndex: nil, endGlobalIndex: end))
            start += dailySpan
        }
        let candles = [PeriodCandles(period: .m3, rows: m3Rows),
                       PeriodCandles(period: .daily, rows: dailyRows)]

        let meta = TrainingSetMeta(
            stockCode: "600001", stockName: "示例训练股",
            startDatetime: m3Rows.first!.datetime, endDatetime: m3Rows.last!.datetime)

        // 3) 历史 records（≥2，确定性）
        let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false)
        let records = [
            TrainingRecord(id: nil, trainingSetFilename: filename, createdAt: baseEpoch,
                           stockCode: "600001", stockName: "示例训练股", startYear: 2023, startMonth: 11,
                           totalCapital: 100_000, profit: 8_900, returnRate: 0.089, maxDrawdown: -0.05,
                           buyCount: 3, sellCount: 2, feeSnapshot: fees, finalTick: m3Count - 1),
            TrainingRecord(id: nil, trainingSetFilename: filename, createdAt: baseEpoch + 86_400,
                           stockCode: "600001", stockName: "示例训练股", startYear: 2023, startMonth: 11,
                           totalCapital: 108_900, profit: -2_100, returnRate: -0.019, maxDrawdown: -0.08,
                           buyCount: 1, sellCount: 1, feeSnapshot: fees, finalTick: m3Count - 1),
        ]

        // 4) pending（可恢复局：空仓、推进到中段、引用同一训练组）
        let emptyPosition = try! JSONEncoder().encode(PositionManager())
        let pending = PendingTraining(
            trainingSetFilename: filename, globalTickIndex: m3Count / 2,
            upperPeriod: .m3, lowerPeriod: .daily,
            positionData: emptyPosition, cashBalance: 100_000, feeSnapshot: fees,
            tradeOperations: [], drawings: [], startedAt: baseEpoch + 172_800,
            accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0),
            sessionKey: "debug-fixture-pending")

        return Seed(trainingSetFilename: filename, meta: meta, candles: candles,
                    records: records, pending: pending, settings: .default)
    }
}
#endif
```

**注（已 grep 核实 `Models.swift`/`PositionManager.swift`/`AppState.swift`）**：`PositionManager(shares:averageCost:totalInvested:)` 全默认 → `PositionManager()` 合法；`FeeSnapshot(commissionRate:minCommissionEnabled:)`（无 `.preview`，已用显式值）；`DrawdownAccumulator(peakCapital:maxDrawdown:)`（无空 init，已用显式值）；`TrainingSetMeta(stockCode:stockName:startDatetime:endDatetime:)`（Models.swift:122）；`Period.m3.rawValue == "3m"` / `.daily.rawValue == "daily"`（writer 用 `period.rawValue`，与 `TrainingSetSQLiteFixture` 同口径）。上方代码已按真实签名定稿。

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter DebugFixtureDataTests`
Expected: PASS（5/5）。若 `PositionManager()`/`FeeSnapshot.preview` 编译错 → 按 Step 3 注 grep 修正 init 后重跑。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift
git commit -m "feat(13b): DebugFixtureData 确定性 rich 训练组生成器（§C，#if DEBUG，5 tests）"
```

---

## Task 2: §C 训练组 sqlite 写入器

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugTrainingSetWriter.swift`
- Test: 并入 `AppContainerDebugSeedTests`（Task 3），本 Task 仅交付写入器 + 一条独立 open 验证测试

- [ ] **Step 1: 写失败测试（写入器产出经真 factory 可 open + loadAllCandles）**

追加到新文件 `ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugTrainingSetWriterTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerPersistence
import KlineTrainerContracts

#if DEBUG
@Suite("DebugTrainingSetWriter：生成 sqlite 经真 factory 可 open + 读全蜡烛（§C）")
struct DebugTrainingSetWriterTests {

    @Test("写出的训练组 sqlite：openAndVerify 成功 + loadAllCandles 含 m3/daily")
    func writtenSqlite_isDownstreamConsumable() throws {
        let seed = DebugFixtureData.make(m3Count: 240)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(seed.trainingSetFilename)

        try DebugTrainingSetWriter.write(seed: seed, to: url)

        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: url, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let meta = try reader.loadMeta()
        #expect(meta.stockCode == "600001")
        let candles = try reader.loadAllCandles()
        #expect((candles[.m3]?.count ?? 0) == 240)
        #expect((candles[.daily]?.isEmpty == false))
        // m3 0 基严格递增（reader 已校验；此处再断言读回一致）
        #expect(candles[.m3]?.first?.globalIndex == 0)
    }
}
#endif
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter DebugTrainingSetWriterTests`
Expected: FAIL（`DebugTrainingSetWriter` 未定义）。

- [ ] **Step 3: 实现 `DebugTrainingSetWriter`**

```swift
// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugTrainingSetWriter.swift
// Kline Trainer — debug fixture 训练组 sqlite 写入（Wave 3 PR 13b §C）
//
// #if DEBUG only：把 DebugFixtureData.Seed 的蜡烛 + meta 写成符合训练组 schema（user_version=1 +
// meta + klines）的 sqlite，供 cache.store 直注。schema 对齐 TrainingSetSQLiteFixture / DefaultTrainingSetDBFactory。

#if DEBUG
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

public enum DebugTrainingSetWriter {

    public static func write(seed: DebugFixtureData.Seed, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(TRAINING_SET_SCHEMA_VERSION)")
            try db.execute(sql: """
            CREATE TABLE meta (
                stock_code TEXT NOT NULL, stock_name TEXT NOT NULL,
                start_datetime INTEGER NOT NULL, end_datetime INTEGER NOT NULL)
            """)
            try db.execute(sql: """
            INSERT INTO meta (stock_code, stock_name, start_datetime, end_datetime) VALUES (?, ?, ?, ?)
            """, arguments: [seed.meta.stockCode, seed.meta.stockName,
                             seed.meta.startDatetime, seed.meta.endDatetime])
            try db.execute(sql: """
            CREATE TABLE klines (
                id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT NOT NULL, datetime INTEGER NOT NULL,
                open REAL NOT NULL, high REAL NOT NULL, low REAL NOT NULL, close REAL NOT NULL,
                volume INTEGER NOT NULL, amount REAL, ma66 REAL,
                boll_upper REAL, boll_mid REAL, boll_lower REAL,
                macd_diff REAL, macd_dea REAL, macd_bar REAL,
                global_index INTEGER, end_global_index INTEGER NOT NULL)
            """)
            try db.execute(sql: "CREATE INDEX idx_period_endidx ON klines(period, end_global_index)")
            try db.execute(sql: "CREATE INDEX idx_period_datetime ON klines(period, datetime)")
            for pc in seed.candles {
                for r in pc.rows {
                    try db.execute(sql: """
                    INSERT INTO klines (period, datetime, open, high, low, close, volume, amount, ma66,
                        boll_upper, boll_mid, boll_lower, macd_diff, macd_dea, macd_bar,
                        global_index, end_global_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?)
                    """, arguments: [pc.period.rawValue, r.datetime, r.open, r.high, r.low, r.close,
                                     r.volume, r.ma66, r.globalIndex, r.endGlobalIndex])
                }
            }
        }
    }
}
#endif
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter DebugTrainingSetWriterTests`
Expected: PASS（1/1）。若 reader 校验失败（OHLC/索引不变量），按报错回查 Task 1 生成器（最可能：daily OHLC 或 end_global_index）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugTrainingSetWriter.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugTrainingSetWriterTests.swift
git commit -m "feat(13b): DebugTrainingSetWriter 训练组 sqlite 写入器（§C，downstream-open 测试）"
```

---

## Task 3: §C `AppContainer.seedDebugFixturesIfEmpty()`（幂等端到端 seed）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift`
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift`

- [ ] **Step 1: 写失败测试（经真 DefaultAppDB + cache temp 端到端）**

```swift
import Testing
import Foundation
@testable import KlineTrainerPersistence
import KlineTrainerContracts

#if DEBUG
@Suite("AppContainer debug seed：经真 DefaultAppDB+cache 落库，loadHome 非空、可恢复、可开局（§C）")
@MainActor
struct AppContainerDebugSeedTests {

    private func makeContainer() throws -> (AppContainer, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeedTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = AppConfig(dbPath: dir.appendingPathComponent("app.sqlite"),
                            cacheRootDir: dir.appendingPathComponent("training-sets"),
                            backendBaseURL: URL(string: "http://debug.local")!)
        return (try AppContainer(config: cfg), dir)
    }

    @Test("seed 后：cache 非空 + history 非空 + pending 可恢复")
    func seed_populatesCachePendingHistory() async throws {
        let (c, dir) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        try c.seedDebugFixturesIfEmpty()
        // cache 非空且可 open
        #expect(!c.cache.listAvailable().isEmpty)
        let file = c.cache.listAvailable().first!
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: file.localURL, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        reader.close()
        // history 非空
        #expect(try c.db.statistics().totalCount >= 2)
        #expect(try c.db.listRecords(limit: nil).count >= 2)
        // pending 可恢复
        #expect(try c.db.loadPending() != nil)
        // loadHome 反映非空
        await c.router.loadHome()
        #expect(c.router.homeContent?.hasCachedSets == true)
        #expect(c.router.homeContent?.isResuming == true)   // HomeContent 暴露 isResuming（非 hasPending；后者仅 init 参数名）
    }

    @Test("幂等：已 seed（cache 非空）再调 → no-op，不叠加")
    func seed_idempotent() async throws {
        let (c, dir) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        try c.seedDebugFixturesIfEmpty()
        let recCount1 = try c.db.listRecords(limit: nil).count
        let cacheCount1 = c.cache.listAvailable().count
        try c.seedDebugFixturesIfEmpty()   // 再调
        #expect(try c.db.listRecords(limit: nil).count == recCount1, "幂等：records 不叠加")
        #expect(c.cache.listAvailable().count == cacheCount1, "幂等：cache 不叠加")
    }

    @Test("seed 的训练组可真开局（resumePending 重建引擎）")
    func seed_pendingResumable() async throws {
        let (c, dir) = try makeContainer()
        defer { try? FileManager.default.removeItem(at: dir) }
        try c.seedDebugFixturesIfEmpty()
        let engine = try await c.coordinator.resumePending()
        #expect(engine != nil)
    }
}
#endif
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter AppContainerDebugSeedTests`
Expected: FAIL（`seedDebugFixturesIfEmpty` 未定义）。

- [ ] **Step 3: 实现 `AppContainer+DebugSeed`**

```swift
// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift
// Kline Trainer — debug-only 全 app fixture provisioning（Wave 3 PR 13b §C）
//
// #if DEBUG only：经组合根的真 db/cache/settings 落库一份确定性 fixture（缓存训练组 + 历史 + pending + 设置），
// 使运行时矩阵可在真 app（真 composition root）跑。幂等（仅 cache 空时 seed，防覆盖开发者真实数据 / 叠加）。
// 触发由 KlineTrainerApp（#if DEBUG + env KLINE_SEED_FIXTURE）控制；Release 二进制零本代码。

#if DEBUG
import Foundation
import KlineTrainerContracts

extension AppContainer {

    /// 幂等 seed：仅当缓存为空（视为未 seed / 全新安装）时写入 fixture。已有数据 → no-op。
    public func seedDebugFixturesIfEmpty() throws {
        guard cache.listAvailable().isEmpty else { return }   // 幂等护栏（不覆盖 / 不叠加）

        let seed = DebugFixtureData.make(m3Count: 240)

        // 1) 训练组 sqlite → cache.store 直注（store 校验 user_version；CRC 不校验，contentHash 占位）
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugSeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sqliteURL = tmpDir.appendingPathComponent(seed.trainingSetFilename)
        try DebugTrainingSetWriter.write(seed: seed, to: sqliteURL)
        let meta = TrainingSetMetaItem(
            id: 1, stockCode: seed.meta.stockCode, stockName: seed.meta.stockName,
            filename: seed.trainingSetFilename, schemaVersion: TRAINING_SET_SCHEMA_VERSION,
            contentHash: "00000000")
        _ = try cache.store(downloadedZip: sqliteURL, meta: meta)

        // 2) settings
        try db.saveSettings(seed.settings)

        // 3) history records（用 RecordRepository.insertRecord——非事务、不耦合 pending，避免 finalize 清 pending）
        for rec in seed.records {
            _ = try db.insertRecord(rec, ops: [], drawings: [])
        }

        // 4) pending（可恢复局）——在 records 之后落（insertRecord 不动 pending，顺序无关，仍置后以示意终态）
        if let pending = seed.pending {
            try db.savePending(pending)
        }
    }
}
#endif
```

**注**：用 `db.insertRecord(_:ops:drawings:)`（`RecordRepository`，`db` 即 `AppDB` 含之）落 history——非事务、不触 `pending_training`，故与 `savePending` 无清除耦合（不用 `finalizeSession`，后者单事务会 `clearPending`）。`insertRecord` 签名经 explore 核实：`(_ : TrainingRecord, ops: [TradeOperation], drawings: [DrawingObject]) throws -> Int64`。

- [ ] **Step 4: 运行确认通过 + 全量回归**

Run: `cd ios/Contracts && swift test --filter AppContainerDebugSeedTests`
Expected: PASS（3/3）。
Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: 全绿，0 failures（新增 §C 测试计入）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift
git commit -m "feat(13b): AppContainer.seedDebugFixturesIfEmpty 幂等全 app fixture provisioning（§C，3 tests）"
```

---

## Task 4: §C `KlineTrainerApp` env-var 触发（app target，Release 隔离）

**Files:**
- Modify: `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift`

- [ ] **Step 1: 在 init 成功构造 container 后，#if DEBUG + env 触发 seed**

把 `init()` 的 `_container = State(initialValue: try AppContainer(config: cfg))` 改为先构造再条件 seed：

```swift
            let container = try AppContainer(config: cfg)
            #if DEBUG
            // 运行时 opt-in（默认关）：仅 env KLINE_SEED_FIXTURE=1 时 seed fixture，使运行时验收矩阵
            // 可在真 composition root 跑。幂等（仅 cache 空时写）。Release 二进制无本块（#if DEBUG）。
            if ProcessInfo.processInfo.environment["KLINE_SEED_FIXTURE"] == "1" {
                try container.seedDebugFixturesIfEmpty()
            }
            #endif
            _container = State(initialValue: container)
```

- [ ] **Step 2: app target 编译确认（Release 隔离 + Debug 含 seed）**

本步改 app target（`KlineTrainer.xcodeproj`），由 app-build CI 验证。本地若有 xcodebuild app scheme 可跑：
Run: `cd ios/KlineTrainer && xcodebuild build -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' -configuration Debug 2>&1 | tail -3`
Expected: BUILD SUCCEEDED（Debug 含 seed 调用）。
（若本地无 app scheme/destination，注明依赖 CI app-build job 验证——per `feedback_swift_local_toolchain_blindspot` 不可仅凭本地。）

- [ ] **Step 3: Commit**

```bash
git add ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift
git commit -m "feat(13b): KlineTrainerApp #if DEBUG env KLINE_SEED_FIXTURE 触发 fixture seed（§C，Release 隔离）"
```

---

## Task 5: §D 生产路径 E2E smoke（扩展真实栈集成测试）

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift`

- [ ] **Step 1: 追加下游可消费 smoke 测试**

在 `DownloadAcceptanceRunnerIntegrationTests` 套件内（`run_realPipeline_happyPath_storesAndConfirms` 之后）追加：

```swift
    @Test func run_realPipeline_storedSetIsDownstreamConsumable() async throws {
        // 1) 真训练组 sqlite（user_version=1 + meta + klines）→ 字节
        let (sqliteFixtureURL, cleanupSqlite) = try TrainingSetSQLiteFixture.make()
        defer { cleanupSqlite() }
        let sqliteBytes = try Data(contentsOf: sqliteFixtureURL)

        // 2) 真 zip + 真 CRC
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2Smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(
            in: workDir, sqliteFileName: "training.sqlite", sqlitePayload: sqliteBytes)

        // 3) 真 P2-P5 栈（dataVerifier fake 放行）+ 真 confirm
        let cacheRoot = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(cacheRoot) }
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = DownloadAcceptanceRunner(
            api: FakeAPIClient(download: .success(zipURL), confirmError: nil),
            cache: DefaultFileSystemCacheManager(cacheRoot: cacheRoot),
            dbFactory: DefaultTrainingSetDBFactory(),
            journal: journal,
            integrity: DefaultZipIntegrityVerifier(),
            extractor: DefaultZipExtractor(),
            dataVerifier: FakeTrainingSetDataVerifier(),
            cleaner: DefaultDownloadAcceptanceCleaner())
        let meta = TrainingSetMetaItem(
            id: 77, stockCode: "600001", stockName: "测试股票",
            filename: "training.zip", schemaVersion: 1, contentHash: crcHex)

        // 4) 真实下载→验收→confirm
        let result = await runner.run(meta: meta, leaseId: "22222222-2222-2222-2222-222222222222")
        guard case .confirmed(let file) = result else {
            Issue.record("expected .confirmed via real pipeline, got \(result)"); return
        }

        // 5) §D 核心断言：stored 组**下游可消费**——经真 factory open + 读 meta + 读全蜡烛（含 m3）
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: file.localURL, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let loadedMeta = try reader.loadMeta()
        #expect(loadedMeta.stockCode == "600001")
        let candles = try reader.loadAllCandles()
        #expect((candles[.m3]?.isEmpty == false), "下载组真能被会话读取消费（m3 蜡烛非空）")
        #expect(candles[.m3]?.first?.globalIndex == 0)
    }
```

- [ ] **Step 2: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter DownloadAcceptanceRunnerIntegrationTests`
Expected: PASS（既有 1 + 新增 1 = 2）。新测试证：真实 download→verify→commit→**open→loadAllCandles** 全链下游可消费（既有测试仅到「落盘 + journal confirmed」）。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift
git commit -m "test(13b): 生产路径 E2E smoke——下载组下游可消费（§D，真 factory open+loadAllCandles）"
```

---

## Task 6: 非-coder 验收清单 + 全量验证

**Files:**
- Create: `docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md`

- [ ] **Step 1: 写验收清单**

```markdown
# PR Wave 3 13b 验收清单（中文非-coder 可执行）

**PR 范围**：§C debug-only 全 app fixture provisioning（经 AppContainer seed 缓存+pending+history，使运行时矩阵可在真 app 跑）+ §D 生产路径 E2E smoke（真实 DownloadAcceptanceRunner 下游可消费）。改 `ios/**/*.swift` + app target；新增 host 测；0 schema/CI workflow 改动（app-build 既有）。

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR | 见 `DebugFixtures/` 3 新文件（`#if DEBUG`）+ `KlineTrainerApp.swift` 改 + 4 测试文件 + 本 acceptance | □ Pass / □ Fail |
| 2 | 看 `DebugFixtureData.swift` | 整文件 `#if DEBUG` 包裹；确定性（无随机）；m3 0 基递增 global==end + 有效 OHLC + MA66 rolling | □ Pass / □ Fail |
| 3 | 看 `DebugFixtureDataTests.swift` | 含 5 测试：m3 不变量 / daily end<=max / MA66 / 确定性 / 描述自洽 | □ Pass / □ Fail |
| 4 | 看 `DebugTrainingSetWriter.swift` | `#if DEBUG`；schema 对齐（user_version=1 + meta + klines + 索引） | □ Pass / □ Fail |
| 5 | 看 `AppContainer+DebugSeed.swift` | `#if DEBUG`；`seedDebugFixturesIfEmpty` 幂等（仅 cache 空时 seed）；经真 db/cache/settings 落库 | □ Pass / □ Fail |
| 6 | 看 `AppContainerDebugSeedTests.swift` | 含 3 测试：seed 填 cache/history/pending + loadHome 非空 / 幂等不叠加 / pending 可 resume | □ Pass / □ Fail |
| 7 | 看 `KlineTrainerApp.swift` diff | `#if DEBUG` + env `KLINE_SEED_FIXTURE==1` 才 seed；Release 无本块 | □ Pass / □ Fail |
| 8 | 看 `DownloadAcceptanceRunnerIntegrationTests.swift` diff | 新增 `run_realPipeline_storedSetIsDownstreamConsumable`：真栈 download→confirm→**open+loadAllCandles** | □ Pass / □ Fail |
| 9 | 看 CI 「swift test on macos-15」 | 绿（全量 + 新增 §C/§D 测试无失败） | □ Pass / □ Fail |
| 10 | 看 CI 「Mac Catalyst build-for-testing」+「app-build」 | 均绿（含 app target Debug 编译） | □ Pass / □ Fail |
| 11 | 看 codex 对抗 review verdict | APPROVE（或 codex 配额耗尽→opus 4.8 xhigh fallback APPROVE / accept residual + override） | □ Pass / □ Fail |

## Release 隔离守卫

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 12 | grep `DebugFixtures/` 所有文件首行 | 均 `#if DEBUG`（Release 编译期剔除整 seed 路径 + fixture 资产引用） | □ Pass / □ Fail |
| 13 | 看 `KlineTrainerApp` seed 调用 | 在 `#if DEBUG` 内 + 运行期 env opt-in 默认关（正常 debug 启动不 seed） | □ Pass / □ Fail |

## 范围注（plan 决策）

- 指标：seed 计算 MA66（主叠加渲染）；BOLL/MACD 留 NULL（schema nullable；交互矩阵不需指标精度，full parity 归 backend import_csv）。
- reset：app.sqlite singleton → 删 app 重置（DEBUG-only 可接受）。
- 运行时矩阵的 device/sim 实测执行归顺位 13c（runbook）+ 用户 device 职责。
```

- [ ] **Step 2: 全量 host 测**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: 全绿，0 failures（baseline + §C 5+1+3 + §D 1 = +10 测试）。

- [ ] **Step 3: Catalyst 全量编译闸门**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived-13b 2>&1 | grep -E "TEST BUILD SUCCEEDED|error:|warning:" | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`，无 error/warning。

- [ ] **Step 4: Commit**

```bash
git add docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md
git commit -m "docs(13b): 非-coder 验收清单（fixture provisioning + E2E smoke）"
```

---

## Self-Review（核对 spec §C/§D）

- **spec §C 覆盖**：rich seed（240 m3 + daily + MA66，满足 reader 不变量，Task 1/2）+ 经 AppContainer 真 db/cache/settings 落库（Task 3）+ env 触发 + Release 隔离（Task 4）+ 幂等 + 可 resume + loadHome 非空（Task 3 测试）。✓ indicators 范围注明示（MA66 计算 / BOLL/MACD NULL）。
- **spec §D 覆盖**：扩展真实栈集成测试断言下游可消费（open+loadAllCandles，Task 5）。✓ 非 vacuous（既有测试未覆盖 open+读蜡烛）。
- **Release 隔离**（spec §C 硬约束）：全 seed 代码 `#if DEBUG` + 运行期 env opt-in（Task 4 + acceptance Step 12/13）。✓
- **类型一致性**：`DebugFixtureData.make(m3Count:)`/`Seed`/`CandleRow`/`PeriodCandles`、`DebugTrainingSetWriter.write(seed:to:)`、`seedDebugFixturesIfEmpty()` 全文一致。✓
- **placeholder 扫描**：无 TBD。所有外部 init/方法已 grep 核实定稿（`PositionManager()` 全默认 ✓ / `FeeSnapshot(commissionRate:minCommissionEnabled:)` ✓ / `DrawdownAccumulator(peakCapital:maxDrawdown:)` ✓ / `TrainingSetMeta(...)` ✓ / `Period.rawValue`="3m"/"daily" ✓ / history 用 `insertRecord` 非 finalizeSession ✓）。唯一留待 implementer 现场确认：`AppConfig` init 签名（dbPath/cacheRootDir/backendBaseURL，已见 KlineTrainerApp 用法）+ `db.listRecords(limit:)`/`db.statistics()` 返回形（测试用）——均已在 explore 报告中出现，低风险。

---

## Execution Handoff

执行用 **superpowers:subagent-driven-development**。Task 间串行（Task 2/3 依赖 Task 1 类型；Task 4 依赖 Task 3）。implementer 在 Task 1 Step 3 / Task 3 Step 3 **先 grep 核实** `PositionManager`/`DrawdownAccumulator`/`FeeSnapshot`/`finalizeSession` 真实 init/签名再定稿（避免编译错）。
