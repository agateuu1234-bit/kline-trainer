# 重置资金「真正归零重来」实施计划（W3 运行时 #1 + #6）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「重置资金」原子性地清空全部训练记录 + 未完成对局并把资金恢复为 ¥100,000（真正归零重来），同时修复全新安装从 ¥0 起的 #6。

**Architecture:** 新增 1 个窄端口 `TrainingResetPort`，由 `DefaultAppDB` 在单一 `dbQueue.write` 事务内实现（删记录+子行 → 清 pending → 写 capital）；`SettingsStore` 把旧 `resetCapital()` 改为 `resetAllProgress()` 经注入端口调用；`#6` 由 `SettingsDAOImpl.loadSettings` 缺键默认 0→100k 修复。`deleteAll`/`setTotalCapital` 做成 internal static（不进现有协议，避免 ~9 个 conformer 涟漪）；新增 `AppSettings.defaultTotalCapital` 常量统一魔法数。DAO 层遗留 `resetCapital` 保留（协议兼容）但其写值由 `"0.0"` 改为默认 10 万，消除「未用方法写错值」地雷。

**Tech Stack:** Swift 6 / SwiftUI / GRDB / Swift Testing（contracts 层）+ XCTest（persistence 层）；host `swift test` + Mac Catalyst `build-for-testing` + iOS app build。

**设计文档：** `docs/superpowers/specs/2026-06-19-reset-capital-true-restart-design.md`

**已验证的真实 model 签名（plan-stage review R1 修正，勿再凭记忆）：**
- `Period`：`.m3 .m15 .m60 .daily .weekly .monthly`（**无 `.day`**）。
- `TrainingRecord.createdAt: Int64`；`TradeOperation.createdAt: Int64`；`PendingTraining.startedAt: Int64`（**均整数 epoch，非 String**）。
- `DrawingAnchor(period: Period, candleIndex: Int, price: Double)`。
- `DrawdownAccumulator(peakCapital: Double, maxDrawdown: Double)`（有 `.initial`）。
- `TradeOperation(globalTick:period:direction:price:shares:positionTier:commission:stampDuty:totalCost:createdAt:)`；`.tier1`/`.buy`/`.horizontal` 均存在。
- `DefaultAppDB.dbQueue` 为 `internal let`（`@testable` persistence 测试可访问）；`RecordRepositoryImpl`/`SettingsDAOImpl`/`PendingTrainingRepositoryImpl` 均 internal enum static。

---

## 文件结构（决策锁定）

**新建**
- `ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingResetPort.swift` — 1 方法窄端口协议。

**修改（生产）**
- `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift` — 加 `AppSettings.defaultTotalCapital` 常量；`AppSettings.default` 引用之。
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift` — `loadSettings` 缺键默认 0→`defaultTotalCapital`（#6）；`resetCapital` 写值 0→`defaultTotalCapital`（去地雷）；新增 `setTotalCapital(_:_:)` static。
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift` — 新增 `deleteAll(_:)` static。
- `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift` — class conform `TrainingResetPort` + 实现 `resetAllTrainingProgress`。
- `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift` — 加 `resetPort` 可选注入；`resetCapital()`→`resetAllProgress()`。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift` — 确认文案披露清空记录 + 调 `resetAllProgress()` + 失败不静默。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift` — 加 reset 文案常量（供 host 测试断言）。
- `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift` — `SettingsStore(settingsDAO: db, resetPort: db)`。

**修改（测试）**
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift` — #6 fresh 默认 100k（case 1/10）；resetCapital→100k（case 4/5）。
- 新增 `ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingResetPortTests.swift` — 原子重置 + 真回滚 + 重置后输入快照。
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift` — 对照测试改用 records/pending 区分（非 capital）；新增 seeded→reset→开局 真协调器路径。
- `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift` — 3 个 reset 测试改 `resetAllProgress` 语义 + FakeTrainingResetPort。
- `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift` — `mutatorSignatures` 的 `store.resetCapital` 方法引用改 `resetAllProgress`。
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerTests.swift` — 新增 reset 端口接线集成用例。
- 新增/并入 `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsPanelContentTests.swift` — reset 文案含「清空训练记录」。

**修改（冻结 spec / 文档）**
- `kline_trainer_plan_v1.5.md` 第 1025 行 §6.4 — 反转「不清空训练记录」。
- 新增 `docs/superpowers/acceptance/2026-06-19-reset-capital-true-restart-acceptance.md` — 非编码者验收清单。

---

## Task 1：DRY 常量 + #6 默认 100k + 去 resetCapital 写 0 地雷

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift:171-180`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift:27, 87-91`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift`（case 1/4/5/10）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift`（对照测试 line 42-49）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift:259-266`（`InMemorySettingsDAO.resetCapital` 镜像同步写默认 10 万）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/InMemoryDBFakesTests.swift:144-153`（断言改 100_000）

- [ ] **Step 1: 改 4 个 DAO 测试为新默认（RED）** — `DefaultSettingsDAOTests.swift`

case 1（line 25）与 case 10（line 152）`totalCapital` 期望 0→100_000；case 4（line 66）与 case 5（line 80）期望 resetCapital 后为默认 10 万：

```swift
    // 用例 1：fresh DB loadSettings 返回默认（资金默认=初始 10 万 #6；其它字段 zero-value）
    func test_loadSettings_on_fresh_db_returns_defaults() throws {
        let s = try db.loadSettings()
        XCTAssertEqual(s.commissionRate, 0)
        XCTAssertEqual(s.minCommissionEnabled, false)
        XCTAssertEqual(s.totalCapital, 100_000)   // #6：缺键默认 10 万（非 0），开局可交易
        XCTAssertEqual(s.displayMode, .system)
    }
```

```swift
    // 用例 4：resetCapital 把 total_capital 写回默认 10 万，其它字段保留
    func test_resetCapital_sets_default_capital_other_fields_intact() throws {
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 50_000, displayMode: .dark))
        try db.resetCapital()
        let loaded = try db.loadSettings()
        XCTAssertEqual(loaded.totalCapital, 100_000)   // 去地雷：写默认 10 万（非 0）
        XCTAssertEqual(loaded.commissionRate, 0.0003, accuracy: 1e-9)
        XCTAssertEqual(loaded.minCommissionEnabled, true)
        XCTAssertEqual(loaded.displayMode, .dark)
    }

    // 用例 5：resetCapital fresh DB 创建 total_capital=默认 10 万 行
    func test_resetCapital_on_fresh_db_creates_default_capital_row() throws {
        try db.resetCapital()
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let val: String? = try queue.read { db in
            try String.fetchOne(db, sql:
                "SELECT value FROM settings WHERE key = 'total_capital'")
        }
        XCTAssertEqual(val, "100000.0")
    }
```

```swift
    // 用例 10：partial keys（仅 commission_rate）→ 缺失 key 走默认（capital 缺→10 万 #6）
    func test_loadSettings_partial_keys_missing_uses_default() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["commission_rate", "0.0005"])
        }
        let s = try db.loadSettings()
        XCTAssertEqual(s.commissionRate, 0.0005, accuracy: 1e-9)
        XCTAssertEqual(s.minCommissionEnabled, false)
        XCTAssertEqual(s.totalCapital, 100_000)   // #6
        XCTAssertEqual(s.displayMode, .system)
    }
```

- [ ] **Step 2: 跑测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter DefaultSettingsDAOTests 2>&1 | grep -E "Test Suite|failed|passed"`
Expected: case 1/4/5/10 FAIL（实际仍 0 / "0.0"）。

- [ ] **Step 3: 加 DRY 常量** — `AppState.swift`

在 `AppState.swift:174` 的 `public extension AppSettings { static let default ... }` 块**上方**插入：

```swift
public extension AppSettings {
    /// 单一来源：初始/重置资金 10 万元（plan_v1.5 §6.4 + L861）。
    /// AppSettings.default、loadSettings 缺键默认、resetCapital、TrainingResetPort 重置目标 统一引用，杜绝魔法数漂移。
    static let defaultTotalCapital: Double = 100_000
}
```

并把 `AppSettings.default` 的 `totalCapital: 100_000`（line 178）改为：

```swift
        totalCapital: AppSettings.defaultTotalCapital,   // §6.4 重置资金 → 10 万元
```

- [ ] **Step 4: 改 SettingsDAOImpl（GREEN）** — `SettingsDAOImpl.swift`

line 27 缺键默认（#6）：

```swift
        let totalCapital = try parseDouble(dict[keyTotalCapital], default: AppSettings.defaultTotalCapital)
```

并把 line 15-18 注释里「missing = ... → zero-value default」改为「missing = 首次启动 → 默认（capital=10 万 #6，其它 zero-value）」。

`resetCapital(_:)`（line 87-91）写值改默认 + 去地雷注释：

```swift
    /// 遗留 capital-only 重置（协议兼容；当前 UI 改用 TrainingResetPort 全量重置）。
    /// 运行时 #1：写值由 "0.0" 改为默认 10 万，避免「未用方法写错值」地雷（与 §6.4 一致）。
    static func resetCapital(_ db: Database) throws {
        try db.execute(sql:
            "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
            arguments: [keyTotalCapital, String(AppSettings.defaultTotalCapital)])
    }
```

- [ ] **Step 5: 跑测试确认通过（GREEN）**

Run: `cd ios/Contracts && swift test --filter DefaultSettingsDAOTests 2>&1 | grep -E "Test Suite|failed|passed"`
Expected: DefaultSettingsDAOTests 全 PASS。

- [ ] **Step 6: 修 #6 已知波及测试①——AppContainerDebugSeedTests 对照测试（去 vacuous）**

`noSeed_settingsIsZeroDefault`（line 42-49）的 capital 断言因 #6 既会失败、又失去区分力（seeded 与 unseeded 现都是 100k）。改用 records/pending 这些 seed **确实**改变、unseeded **确实**为空的字段区分，并改名：

```swift
    @Test("未 seed（debugSeedFixtures:false）：cache/records/pending 皆空（对照，证 seed 测非 vacuous）")
    func noSeed_isEmptyProgress() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: false)
        #expect(c.cache.listAvailable().isEmpty)
        #expect(try c.db.statistics().totalCount == 0)   // 区分：seeded 测断言 >= 2
        #expect(try c.db.loadPending() == nil)           // 区分：seeded 测断言 != nil
        #expect(c.settings.settings.totalCapital == 100_000)  // #6：空库现也默认 10 万（非 0）
    }
```

（seeded 测 `seed_populatesAll_andFreshSettings` line 39 的 `totalCapital == 100_000` 保持——seed 写 settings=10 万，#6 后空库亦 10 万，该行不再区分但不错；区分力已由 cache/records/pending 多条断言承担，无需改。）

- [ ] **Step 7: 修 #6 已知波及测试②——全量扫描其余 fresh-DB capital 断言**

Run: `cd ios/Contracts && swift test 2>&1 | grep -iE "failed|error:" | head -40`
Run（辅助定位）: `grep -rn "totalCapital, 0\|totalCapital == 0\|currentCapital, 0\|currentCapital == 0" ios/Contracts/Tests --include="*.swift"`
对每个走**真实 `DefaultAppDB` 新库**且断言 capital/currentCapital==0 的用例改为 100_000；用 `StubSettingsDAO`/`CapitalDAO`/`InMemorySettingsDAO` 显式返回值或 `AppSettings.zero` 的用例**不受影响**（不走真实 `loadSettings` 默认）——逐个判断后修改。

**另**（plan-stage R2 Low）：把 `InMemorySettingsDAO.resetCapital`（`InMemoryFakes.swift:259-266`）与生产 DAO 对齐——写 `AppSettings.defaultTotalCapital` 并改注释为「mirror production: resetCapital→默认 10 万」；其测试 `InMemoryDBFakesTests.swift:149` 断言由 `0` 改 `100_000`、用例名 `..._setsDefaultCapital`。保持 fake 为诚实镜像（虽 DAO 层 resetCapital 已被 TrainingResetPort 取代，但 fake 仍应与生产同语义）。

- [ ] **Step 8: 全量 host 测试通过**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with|failed"`
Expected: `Test run with N tests ... passed`，0 failures。

- [ ] **Step 9: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/AppState.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift
git commit -m "修 #6：全新安装资金默认 ¥0→¥100,000 + resetCapital 去写 0 地雷 + 抽 defaultTotalCapital 常量"
```

---

## Task 2：原子重置端口（持久化层）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingResetPort.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift`（加 `deleteAll`）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift`（加 `setTotalCapital`）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift:13`（conform）+ 新方法
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingResetPortTests.swift`

- [ ] **Step 1: 写失败测试（RED）** — 新建 `TrainingResetPortTests.swift`

> 模型签名已对真实代码核实（见计划顶部「已验证签名」）：时间戳 `Int64`、`DrawingAnchor(period:candleIndex:price:)`、`DrawdownAccumulator(peakCapital:maxDrawdown:)`、`Period.daily`。

```swift
import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence
@preconcurrency import GRDB

final class TrainingResetPortTests: XCTestCase {
    private var dbURL: URL!
    private var db: DefaultAppDB!

    override func setUp() async throws {
        dbURL = try AppDBFixture.makeFreshDB()
        db = try DefaultAppDB(dbPath: dbURL)
    }
    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }

    // 造一条带 ops + drawings 的记录 + 一个 pending 行 + 旧 capital。
    private func seedProgress() throws {
        let rec = TrainingRecord(
            id: nil, trainingSetFilename: "t.sqlite", createdAt: 1_735_689_600,
            stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
            totalCapital: 100_000, profit: 23_456, returnRate: 0.23,
            maxDrawdown: 0.1, buyCount: 2, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            finalTick: 40)
        let op = TradeOperation(
            globalTick: 10, period: .m3, direction: .buy, price: 10.0, shares: 100,
            positionTier: .tier1, commission: 1.0, stampDuty: 0.0, totalCost: 1001.0,
            createdAt: 1_735_689_601)
        let dr = DrawingObject(toolType: .horizontal,
                               anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 9.5)],
                               isExtended: true, panelPosition: 0)
        _ = try db.insertRecord(rec, ops: [op], drawings: [dr])
        try db.savePending(Self.makePending())
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 123_456, displayMode: .dark))
    }

    private static func makePending() -> PendingTraining {
        PendingTraining(
            trainingSetFilename: "t.sqlite", globalTickIndex: 12,
            upperPeriod: .daily, lowerPeriod: .m3, positionData: Data([0x00]),
            cashBalance: 50_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], drawings: [], startedAt: 1_735_689_600,
            accumulatedCapital: 123_456, drawdown: DrawdownAccumulator(peakCapital: 0, maxDrawdown: 0),
            sessionKey: "sess-1")
    }

    // 主用例：重置后三表清空 + capital=10 万；不需迁移（user_version 仍 2）。
    func test_resetAllTrainingProgress_wipes_records_pending_and_sets_capital() throws {
        try seedProgress()
        XCTAssertEqual(try db.statistics().totalCount, 1)        // 前置：确有记录
        XCTAssertNotNil(try db.loadPending())                    // 前置：确有 pending

        try db.resetAllTrainingProgress(toCapital: 100_000)

        XCTAssertEqual(try db.statistics().totalCount, 0)        // 记录清空
        XCTAssertNil(try db.loadPending())                       // pending 清空
        XCTAssertEqual(try db.loadSettings().totalCapital, 100_000)  // 资金回 10 万

        // 物理验证：子表无 FK 残留。
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let counts: (Int, Int, Int) = try queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM trade_operations") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM drawings") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM training_records") ?? -1)
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        let uv: Int = try queue.read { d in try Int.fetchOne(d, sql: "PRAGMA user_version") ?? -1 }
        XCTAssertEqual(uv, 2)   // 纯数据操作，无新迁移
    }

    // 幂等：空库重置也合法，只确保 capital。
    func test_resetAllTrainingProgress_on_empty_db_is_idempotent() throws {
        try db.resetAllTrainingProgress(toCapital: 100_000)
        XCTAssertEqual(try db.statistics().totalCount, 0)
        XCTAssertNil(try db.loadPending())
        XCTAssertEqual(try db.loadSettings().totalCapital, 100_000)
    }

    // 真原子回滚证明（Medium-9）：用同款 dbQueue.write 事务，deleteAll 之后人为抛错，
    // 断言记录/pending/capital 全保持原样——证 resetAllTrainingProgress 依赖的事务边界确实回滚。
    // db.dbQueue 为 internal（@testable 可见）；deleteAll 为 internal static。
    func test_dbQueue_transaction_rolls_back_deleteAll_on_later_failure() throws {
        try seedProgress()
        XCTAssertThrowsError(try db.dbQueue.write { d in
            try RecordRepositoryImpl.deleteAll(d)
            try PendingTrainingRepositoryImpl.clearPending(d)
            throw AppError.persistence(.ioError("injected mid-transaction failure"))
        })
        // 整体回滚：三者都未变。
        XCTAssertEqual(try db.statistics().totalCount, 1)
        XCTAssertNotNil(try db.loadPending())
        XCTAssertEqual(try db.loadSettings().totalCapital, 123_456)
    }

    // 重置后「下一局起始资金」输入快照（注：本测试仅验持久层输入，不经协调器；
    // 真协调器路径由 Task 5 AppContainerDebugSeedTests.test_after_reset_freshStart_startsAtDefault 验证）。
    func test_after_reset_persistence_inputs_snapshot() throws {
        try seedProgress()
        try db.resetAllTrainingProgress(toCapital: 100_000)
        XCTAssertEqual(try db.statistics().totalCount, 0)            // startingCapital 将走 settings 分支
        XCTAssertEqual(try db.loadSettings().totalCapital, 100_000)  // = 10 万
    }
}
```

- [ ] **Step 2: 跑测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter TrainingResetPortTests 2>&1 | grep -E "error:|failed|Compiling"`
Expected: 编译失败 `value of type 'DefaultAppDB' has no member 'resetAllTrainingProgress'`（model 签名应已正确，不应有 model 编译错）。

- [ ] **Step 3: 加端口协议** — 新建 `TrainingResetPort.swift`

```swift
// Kline Trainer Swift Contracts — 重置资金「真正归零重来」原子端口
// Spec: docs/superpowers/specs/2026-06-19-reset-capital-true-restart-design.md §5.1
// 运行时 #1：重置在单一事务内清空全部训练记录 + 未完成对局 + 资金回默认值。

/// 单事务训练进度重置：删除全部训练记录（含 ops/drawings 子行）、清空 pending、
/// 将 total_capital 写为 `toCapital` —— 要么全成要么全不（`DefaultAppDB.dbQueue.write` 事务边界）。
public protocol TrainingResetPort: Sendable {
    func resetAllTrainingProgress(toCapital: Double) throws
}
```

- [ ] **Step 4: 加 `deleteAll` static** — `RecordRepositoryImpl.swift`（`statistics` 之后、`// MARK: - Row → Model` 之前）

```swift
    /// 删除全部训练记录及其 FK 子行（drawings / trade_operations）。
    /// schema 无 ON DELETE CASCADE，故子表先删；调用方负责 dbQueue.write 事务包裹。
    static func deleteAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM drawings")
        try db.execute(sql: "DELETE FROM trade_operations")
        try db.execute(sql: "DELETE FROM training_records")
    }
```

- [ ] **Step 5: 加 `setTotalCapital` static** — `SettingsDAOImpl.swift`（`resetCapital(_:)` 之后）

```swift
    /// 参数化写 total_capital（供 TrainingResetPort 原子事务复用；不改其它 key）。
    static func setTotalCapital(_ db: Database, _ value: Double) throws {
        try db.execute(sql:
            "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
            arguments: [keyTotalCapital, String(value)])
    }
```

- [ ] **Step 6: conform + 实现 `resetAllTrainingProgress`** — `DefaultAppDB.swift`

class 声明（line 13）改为：

```swift
public final class DefaultAppDB: AppDB, TrainingResetPort {
```

在 `// MARK: - SettingsDAO` 区块之后（`resetCapital()` 之后）插入：

```swift
    // MARK: - TrainingResetPort（重置资金「真正归零重来」，运行时 #1）

    /// 单事务：删全部记录(+ops+drawings 子行) + clearPending + setTotalCapital。
    /// dbQueue.write 即事务边界 —— 任一步抛错整体 rollback（要么都成要么都不成）。
    public func resetAllTrainingProgress(toCapital: Double) throws {
        do {
            try dbQueue.write { db in
                try RecordRepositoryImpl.deleteAll(db)
                try PendingTrainingRepositoryImpl.clearPending(db)
                try SettingsDAOImpl.setTotalCapital(db, toCapital)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
```

- [ ] **Step 7: 跑测试确认通过（GREEN）**

Run: `cd ios/Contracts && swift test --filter TrainingResetPortTests 2>&1 | grep -E "Test Suite|failed|passed"`
Expected: TrainingResetPortTests 4 用例全 PASS（含真回滚）。

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingResetPort.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingResetPortTests.swift
git commit -m "加 TrainingResetPort：单事务清记录+pending+资金回默认（运行时 #1 持久化层，含真回滚证明）"
```

---

## Task 3：SettingsStore.resetAllProgress（编排）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift:22, 35-49, 70-84`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift:56-66, 101-115, 176-192`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift:116-122`

- [ ] **Step 1: 加 fake 端口 + 改/加测试（RED）** — `SettingsStoreProductionTests.swift`

文件末尾（`struct` 外）加测试用 fake：

```swift
/// 测试 fake：单线程 MainActor 测试中使用。写发生在被 await 的 Task.detached 内，
/// `try await task.value` 建立 happens-before，读在 await 之后，故 @unchecked Sendable 安全。
final class FakeTrainingResetPort: TrainingResetPort, @unchecked Sendable {
    private(set) var resetToCapital: Double?
    var error: AppError?
    func resetAllTrainingProgress(toCapital: Double) throws {
        if let e = error { throw e }
        resetToCapital = toCapital
    }
}
```

line 56-66 diskFull-阻塞测试改 `resetAllProgress`：

```swift
    @Test("init: dao throws .diskFull → resetAllProgress 抛同 error 阻塞写（端口不被调）")
    func init_daoThrowsDiskFull_resetAllProgressThrowsLoadError() async throws {
        let dfErr = AppError.persistence(.diskFull)
        let dao = StubSettingsDAO(load: .failure(dfErr))
        let port = FakeTrainingResetPort()
        let store = SettingsStore(settingsDAO: dao, resetPort: port)
        await #expect(throws: dfErr) { try await store.resetAllProgress() }
        #expect(port.resetToCapital == nil)   // loadError 先拦截，端口未触
    }
```

line 101-115 reset 测试改 `resetAllProgress` 语义：

```swift
    @Test("resetAllProgress: 端口被调（toCapital=10 万）；本地 totalCapital→10 万，其它字段不变")
    func resetAllProgress_callsPortAndSetsDefaultCapital() async throws {
        let initial = AppSettings(commissionRate: 0.0001, minCommissionEnabled: true,
                                  totalCapital: 999, displayMode: .dark)
        let dao = StubSettingsDAO(load: .success(initial))
        let port = FakeTrainingResetPort()
        let store = SettingsStore(settingsDAO: dao, resetPort: port)
        try await store.resetAllProgress()
        #expect(port.resetToCapital == 100_000)
        #expect(store.settings.totalCapital == 100_000)
        #expect(store.settings.commissionRate == 0.0001)
        #expect(store.settings.minCommissionEnabled == true)
        #expect(store.settings.displayMode == .dark)
    }

    @Test("resetAllProgress: 端口抛错 → 上抛 + 本地 capital 不变")
    func resetAllProgress_portThrows_localUnchanged() async throws {
        let initial = AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                                  totalCapital: 555, displayMode: .system)
        let dao = StubSettingsDAO(load: .success(initial))
        let port = FakeTrainingResetPort()
        port.error = .persistence(.diskFull)
        let store = SettingsStore(settingsDAO: dao, resetPort: port)
        await #expect(throws: AppError.persistence(.diskFull)) { try await store.resetAllProgress() }
        #expect(store.settings.totalCapital == 555)
    }

    @Test("resetAllProgress: 未注入端口 → internalError")
    func resetAllProgress_noPort_throwsInternal() async throws {
        let store = SettingsStore(settingsDAO: StubSettingsDAO(load: .success(.zero)))  // resetPort 默认 nil
        await #expect(throws: AppError.self) { try await store.resetAllProgress() }
    }
```

line 176-192 的并发测试 `concurrentUpdate_andReset_resetWins` 改为经端口（High-6；原断言 `==0` 现错）：

```swift
    // R1 H-3 regression: 并发 update + resetAllProgress（端口设 10 万，不被 update 旧值覆盖）
    @Test("concurrent update+reset: reset 不被 update 旧 totalCapital overwrite")
    func concurrentUpdate_andReset_resetWins() async throws {
        let initial = AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                                  totalCapital: 50_000, displayMode: .system)
        let dao = StubSettingsDAO(load: .success(initial))
        let port = FakeTrainingResetPort()
        let store = SettingsStore(settingsDAO: dao, resetPort: port)

        async let a: Void = store.update { s in s.commissionRate = 0.0009 }
        async let b: Void = store.resetAllProgress()
        _ = try await (a, b)

        #expect(store.settings.totalCapital == 100_000)   // 串行结果稳定：reset 设默认 10 万
        #expect(store.settings.commissionRate == 0.0009)
    }
```

（删除原 `resetCapital_callsDAOAndZerosLocalCapital`；`StubSettingsDAO.resetCalled` 不再被引用——保留 StubSettingsDAO 不动，该字段成未读，无害。）

- [ ] **Step 2: 改 TrainingSessionCoordinatorTests 的方法引用（RED 编译）** — `TrainingSessionCoordinatorTests.swift:116-122`

`mutatorSignatures`（line 121）引用的是 `store.resetCapital`（**方法引用、无括号**，grep `\.resetCapital()` 抓不到）。改为 `resetAllProgress`：

```swift
    @Test("update / resetAllProgress 签名编译期解析")
    func mutatorSignatures() {
        let store = SettingsStore(settingsDAO: StubDAO())
        let _: (@escaping @Sendable (inout AppSettings) -> Void) async throws -> Void = store.update
        let _: () async throws -> Void = store.resetAllProgress
    }
```

- [ ] **Step 3: 跑测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter SettingsStoreProductionTests 2>&1 | grep -E "error:|failed"`
Expected: 编译失败 `extra argument 'resetPort'` / `has no member 'resetAllProgress'`。

- [ ] **Step 4: 改 SettingsStore（GREEN）** — `SettingsStore.swift`

加存储属性（line 22 `private let settingsDAO: SettingsDAO` 下）：

```swift
    private let resetPort: TrainingResetPort?
```

改 init（line 35）签名 + 赋值（其余 body 不变）：

```swift
    public init(settingsDAO: SettingsDAO, resetPort: TrainingResetPort? = nil) {
        self.settingsDAO = settingsDAO
        self.resetPort = resetPort
        do {
            self.settings = try settingsDAO.loadSettings()
        } catch {
            self.settings = SettingsStore.zeroDefault
            self._loadError = (error as? AppError)
                ?? .internalError(module: "P6", detail: String(describing: error))
            Logger(subsystem: "kline.trainer", category: "settings").error(
                "loadSettings: blocked write (loadError set): \(String(describing: error), privacy: .public)")
        }
    }
```

把 `resetCapital()`（line 70-84）整段替换为 `resetAllProgress()`：

```swift
    /// 重置资金「真正归零重来」(运行时 #1)：经注入端口在单事务内清空全部训练记录 +
    /// 未完成对局，并把资金恢复为 AppSettings.defaultTotalCapital。
    /// 复用 loadError 写阻塞 + pendingMutations 串行化（与 update 同机制）。
    public func resetAllProgress() async throws {
        if let e = _loadError { throw e }   // block writes 直到 reload 成功
        guard let port = resetPort else {
            throw AppError.internalError(module: "P6", detail: "resetAllProgress 需注入 TrainingResetPort")
        }
        let prev = pendingMutations
        let task = Task { [weak self] in
            _ = try? await prev?.value
            guard let self = self else { return }
            try await Task.detached(priority: .userInitiated) {
                try port.resetAllTrainingProgress(toCapital: AppSettings.defaultTotalCapital)
            }.value
            self.settings.totalCapital = AppSettings.defaultTotalCapital
        }
        pendingMutations = task
        try await task.value
    }
```

- [ ] **Step 5: 跑测试确认通过（GREEN）+ 扫残引用**

Run: `cd ios/Contracts && swift test --filter SettingsStoreProductionTests 2>&1 | grep -E "Test Suite|failed|passed"`
Run（扫所有 store 级 resetCapital 残引用，含无括号方法引用）: `grep -rn "store\.resetCapital\|\.resetCapital\b" ios/Contracts/Tests --include="*.swift"`
对剩余 store 级引用改 `resetAllProgress`（注意区分 `db.resetCapital()` DAO 级——那是合法保留的）。
Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with|failed|error:"`
Expected: 全量 `passed`，0 failures。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift
git commit -m "SettingsStore.resetCapital→resetAllProgress：注入端口清进度+资金回默认（运行时 #1 编排）"
```

---

## Task 4：SettingsPanel 文案披露 + 接线 + 不静默吞错

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift:17, 60, 92-97`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsPanelContentTests.swift`

- [ ] **Step 1: 写文案测试（RED）** — `SettingsPanelContentTests.swift`（已存在则追加 suite）

```swift
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("SettingsPanelContent 重置资金文案")
struct SettingsPanelContentResetCopyTests {
    @Test("确认文案披露将清空训练记录（破坏性如实告知）")
    func resetConfirmDisclosesRecordClearing() {
        #expect(SettingsPanelContent.resetConfirmTitle.contains("清空训练记录"))
        #expect(SettingsPanelContent.resetConfirmTitle.contains("100,000")
                || SettingsPanelContent.resetConfirmMessage.contains("100,000"))
    }
    @Test("按钮文案保留资金语义")
    func resetButtonMentionsCapital() {
        #expect(SettingsPanelContent.resetButtonLabel.contains("重置"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter SettingsPanelContentResetCopyTests 2>&1 | grep -E "error:|failed"`
Expected: 编译失败 `has no member 'resetConfirmTitle'`。

- [ ] **Step 3: 加文案常量（GREEN）** — `SettingsPanelContent.swift`（在该 enum/struct 内）

```swift
    /// 重置资金按钮 + 二次确认文案（运行时 #1：破坏性，须如实披露清空训练记录）。
    static let resetButtonLabel = "重置资金（清空记录 → ¥100,000）"
    static let resetConfirmTitle = "确认重置？将清空训练记录"
    static let resetConfirmMessage = "此操作会删除全部训练记录与未完成的对局，并将资金恢复为 ¥100,000，且不可撤销。"
```

- [ ] **Step 4: 跑测试确认通过（GREEN）**

Run: `cd ios/Contracts && swift test --filter SettingsPanelContentResetCopyTests 2>&1 | grep -E "Test Suite|failed|passed"`
Expected: PASS。

- [ ] **Step 5: 接线 SettingsPanel** — `SettingsPanel.swift`

加错误态（line 22 区域 `@State` 群）：

```swift
    @State private var resetErrorMessage = ""
```

按钮（line 60）改：

```swift
            // 3. 重置资金（运行时 #1：清记录 + 资金回 10 万）
            Button(SettingsPanelContent.resetButtonLabel) { showResetConfirm = true }
            if !resetErrorMessage.isEmpty {
                Text(resetErrorMessage).font(.caption).foregroundStyle(.red)
            }
```

确认 alert（line 92-97）改（不静默吞错）：

```swift
        // 重置资金二次确认（破坏性：清空训练记录）
        .alert(SettingsPanelContent.resetConfirmTitle, isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                Task {
                    do { try await settings.resetAllProgress(); resetErrorMessage = "" }
                    catch { resetErrorMessage = "重置失败：\((error as? AppError)?.userMessage ?? "未知错误")" }
                }
            }
        } message: {
            Text(SettingsPanelContent.resetConfirmMessage)
        }
```

- [ ] **Step 6: host 全量 + Catalyst 编译**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with|failed"`
Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -1`
Expected: host `passed`；Catalyst `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 7: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/SettingsPanelContentTests.swift
git commit -m "SettingsPanel：重置文案披露清空记录 + 接 resetAllProgress + 失败可见（运行时 #1 UI）"
```

---

## Task 5：组合根接线 + 真协调器路径集成验证

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift:31`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerTests.swift`（wiring 用例）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift`（真协调器路径，Medium-10）

- [ ] **Step 1: 写集成测试（RED）**

(a) `AppContainerTests.swift` 追加 wiring 用例（确认 reset 端口已接，不抛「需注入端口」）。`AppConfig` 字段名以现仓为准（`dbPath`/`cacheRootDir`/`backendBaseURL`，见 `AppContainerDebugSeedTests.makeConfig`）：

```swift
    @MainActor
    func test_appContainer_settingsStore_resetAllProgress_wired() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResetWire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = AppConfig(dbPath: dir.appendingPathComponent("app.sqlite"),
                            cacheRootDir: dir.appendingPathComponent("training-sets"),
                            backendBaseURL: URL(string: "http://debug.local")!)
        let c = try AppContainer(config: cfg)
        let rec = TrainingRecord(
            id: nil, trainingSetFilename: "t.sqlite", createdAt: 1_735_689_600,
            stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
            totalCapital: 100_000, profit: 5_000, returnRate: 0.05, maxDrawdown: 0.1,
            buyCount: 1, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            finalTick: 40)
        _ = try c.db.insertRecord(rec, ops: [], drawings: [])
        try await c.settings.resetAllProgress()   // 未接端口会抛 internalError
        XCTAssertEqual(try c.db.statistics().totalCount, 0)
        XCTAssertEqual(c.settings.settings.totalCapital, 100_000)
    }
```

(b) `AppContainerDebugSeedTests.swift`（DEBUG，有 seed + cache）追加真协调器路径用例（Medium-10：重置后开新局，顶栏起始资金=10 万）：

```swift
    // 运行时 #1 端到端：seeded（有记录+pending+cache）→ resetAllProgress（清记录/pending，cache 保留）
    // → startNewNormalSession（cache 仍在可开局）→ 零记录使 startingCapital 走 settings 分支 → 顶栏 10 万。
    @Test("重置后开新局：startingCapital 走 settings=10 万（真协调器路径）")
    func test_after_reset_freshStart_startsAtDefault() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: true)
        #expect(try c.db.statistics().totalCount >= 2)        // 前置：seed 有记录
        try await c.settings.resetAllProgress()
        #expect(try c.db.statistics().totalCount == 0)        // 记录已清
        #expect(try c.db.loadPending() == nil)                // pending 已清
        #expect(!c.cache.listAvailable().isEmpty)             // cache 保留（可开局）
        let engine = try await c.coordinator.startNewNormalSession()
        // currentTotalCapital = cashBalance + shares*price；开局无持仓 → = 起始资金。
        #expect(engine.currentTotalCapital == 100_000)
    }
```

> 注：`engine.currentTotalCapital` 为顶栏所读的公开起始资金（TrainingEngine）。若实际公开 accessor 名不同（如 `initialCapital`），按编译器/真实定义改；语义=「开局无持仓时的总资金」。

- [ ] **Step 2: 跑测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter AppContainerTests 2>&1 | grep -E "error:|failed"`
Run: `cd ios/Contracts && swift test --filter AppContainerDebugSeedTests/test_after_reset_freshStart_startsAtDefault 2>&1 | grep -E "error:|failed"`
Expected: wiring 用例失败（`resetAllProgress` 抛 internalError「需注入端口」）；真路径用例同因未接端口失败。

- [ ] **Step 3: 接线（GREEN）** — `AppContainer.swift:31`

```swift
        let settings = SettingsStore(settingsDAO: db, resetPort: db)     // db 同时是 SettingsDAO + TrainingResetPort
```

- [ ] **Step 4: 跑测试确认通过（GREEN）**

Run: `cd ios/Contracts && swift test --filter AppContainerTests 2>&1 | grep -E "Test Suite|failed|passed"`
Run: `cd ios/Contracts && swift test --filter AppContainerDebugSeedTests 2>&1 | grep -E "Test run with|failed|passed"`
Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerTests.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift
git commit -m "组合根接 TrainingResetPort + 真协调器路径验证（重置后开局顶栏 10 万）（运行时 #1 wiring）"
```

---

## Task 6：冻结 spec §6.4 修订 + 验收清单 + 全量回归

**Files:**
- Modify: `kline_trainer_plan_v1.5.md:1025`
- Create: `docs/superpowers/acceptance/2026-06-19-reset-capital-true-restart-acceptance.md`

- [ ] **Step 1: 修订 §6.4 冻结文本** — `kline_trainer_plan_v1.5.md:1025`

将：
```
| **重置资金** 按钮 | 弹出二次确认，确认后将总资金重置为 10 万元（不清空训练记录） |
```
改为：
```
| **重置资金** 按钮 | 弹出二次确认（提示将清空训练记录）；确认后在单一事务内原子性地：清空全部训练记录与未完成的对局，并将总资金重置为 10 万元。取消则不做任何改动。 |
```

- [ ] **Step 2: 写非编码者验收清单** — 新建 acceptance md

参照 `docs/superpowers/acceptance/2026-06-18-w3-review-blank-chart-fix-acceptance.md` 结构，含：① 范围 gate（白名单 = 本计划「文件结构」全部条目，`git diff --name-only origin/main...HEAD` 比对）；② persistence 新测试命令（`swift test --filter TrainingResetPortTests` 含真回滚 + `--filter AppContainerDebugSeedTests`）；③ contracts 新测试（`SettingsStoreProductionTests` + `SettingsPanelContentResetCopyTests`）；④ host 全量 + Catalyst build + app build；⑤ 模拟器 runbook 三场景（训练→重置→历史清空+开局 10 万 / 全新安装开局 10 万非 0 / 取消不变）；⑥ Opus 4.8 xhigh 对抗性 review APPROVE 落账（ledger key `branch:fix/w3-reset-capital@<SHA>`）。每条 action/expected/pass-fail，中文，禁用 `.claude/workflow-rules.json` 列出的禁词。

- [ ] **Step 3: 全量 host 回归**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with|failed"`
Expected: `Test run with N tests in M suites passed`，0 failures。

- [ ] **Step 4: Mac Catalyst build-for-testing**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -1`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 5: iOS app build（治理闸门 app-build.yml 同款）**

以 `.github/workflows/app-build.yml` 的 scheme/destination 为准运行（不臆造路径）。
Expected: `** BUILD SUCCEEDED **`（无 anchored `error:`）。

- [ ] **Step 6: Commit**

```bash
git add kline_trainer_plan_v1.5.md docs/superpowers/acceptance/2026-06-19-reset-capital-true-restart-acceptance.md
git commit -m "spec §6.4 修订（重置清空记录）+ 非编码者验收清单（运行时 #1）"
```

---

## Self-Review（对照 spec + R1 findings）

**Spec 覆盖**：G1 真正归零=Task 2+3+5；G2 #6=Task 1；G3 确认+披露=Task 4；§4 原子/取消/幂等=Task 2+4；§5.1 端口=Task 2；§5.2 编排=Task 3；§5.5 DRY=Task 1；§6 FK 序+无迁移=Task 2 断言；§7 AppError+loadError 拦截=Task 3；§8 边界（重置后开局）=Task 5 真路径；§9 §6.4=Task 6；§11 非信任边界=无 `.github`/codeowners 改动。✓

**R1 findings 落实**：Critical 1-4（model 签名）→ Task 2 全用真实签名 + 顶部「已验证签名」；High-5（无括号方法引用）→ Task 3 Step 2 显式改 + Step 5 broadened grep；High-6（concurrent reset 测试）→ Task 3 Step 1 改 `==100_000`+端口；High-7（seed 对照 vacuous）→ Task 1 Step 6 改用 records/pending 区分；Medium-8（resetCapital 写 0 地雷）→ Task 1 改写默认 10 万 + 注释；Medium-9（回滚空洞）→ Task 2 真 dbQueue 注入回滚；Medium-10（startingCapital 输入复述）→ Task 5 真协调器 startNewNormalSession + 顶栏 10 万，Task 2 输入测试如实更名；Low-12（@unchecked 注释）→ Task 3 fake 带 happens-before 注释。

**Placeholder/类型一致**：无 TBD；`resetAllTrainingProgress(toCapital:)`/`resetAllProgress()`/`defaultTotalCapital`/`deleteAll(_:)`/`setTotalCapital(_:_:)`/`FakeTrainingResetPort` 全文一致。

---

## Execution Handoff

执行用 **subagent-driven-development**（用户授权完全按 superpowers 流程）；每 Task 后两阶段 review；plan-stage 与 branch-diff 双闸门用 **Claude Opus 4.8 xhigh 对抗性 review** 跑到收敛（代 codex，user-explicit）。
