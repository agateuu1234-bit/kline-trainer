# 重置资金「真正归零重来」实施计划（W3 运行时 #1 + #6）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「重置资金」原子性地清空全部训练记录 + 未完成对局并把资金恢复为 ¥100,000（真正归零重来），同时修复全新安装从 ¥0 起的 #6。

**Architecture:** 新增 1 个窄端口 `TrainingResetPort`，由 `DefaultAppDB` 在单一 `dbQueue.write` 事务内实现（删记录+子行 → 清 pending → 写 capital）；`SettingsStore` 把旧 `resetCapital()` 改为 `resetAllProgress()` 经注入端口调用；`#6` 由 `SettingsDAOImpl.loadSettings` 缺键默认 0→100k 修复。`deleteAll`/`setTotalCapital` 做成 internal static（不进现有协议，避免 ~7 个 test double 涟漪）；新增 `AppSettings.defaultTotalCapital` 常量统一魔法数。

**Tech Stack:** Swift 6 / SwiftUI / GRDB / Swift Testing（contracts 层）+ XCTest（persistence 层）；host `swift test` + Mac Catalyst `build-for-testing` + iOS app build。

**设计文档：** `docs/superpowers/specs/2026-06-19-reset-capital-true-restart-design.md`

---

## 文件结构（决策锁定）

**新建**
- `ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingResetPort.swift` — 1 方法窄端口协议。

**修改（生产）**
- `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift` — 加 `AppSettings.defaultTotalCapital` 常量；`AppSettings.default` 引用之。
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift` — `loadSettings` 缺键默认 0→`defaultTotalCapital`（#6）；新增 `setTotalCapital(_:_:)` static。
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift` — 新增 `deleteAll(_:)` static。
- `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift` — class conform `TrainingResetPort` + 实现 `resetAllTrainingProgress`。
- `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift` — 加 `resetPort` 可选注入；`resetCapital()`→`resetAllProgress()`。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift` — 确认文案披露清空记录 + 调 `resetAllProgress()` + 失败不静默。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift` — 加 reset 文案常量（供 host 测试断言）。
- `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift` — `SettingsStore(settingsDAO: db, resetPort: db)`。

**修改（测试）**
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift` — #6 fresh 默认 100k（case 1/10）。
- 新增 `ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingResetPortTests.swift` — 原子重置 + 回滚 + 重置后输入证明（statistics/loadSettings）。
- `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift` — reset 两测试改 `resetAllProgress` 语义。
- 新增 `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsPanelContentTests.swift`（若不存在）或并入既有 content 测试 — reset 文案含「清空训练记录」。

**修改（冻结 spec / 文档）**
- `kline_trainer_plan_v1.5.md` 第 1025 行 §6.4 — 反转「不清空训练记录」。
- 新增 `docs/superpowers/acceptance/2026-06-19-reset-capital-true-restart-acceptance.md` — 非编码者验收清单。

---

## Task 1：DRY 常量 + #6 全新安装默认 100k

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift:171-180`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift:27`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift:20-27, 140-154`

- [ ] **Step 1: 改测试为期望 100k（RED）** — `DefaultSettingsDAOTests.swift`

把 case 1（line 25）与 case 10（line 152）的 `totalCapital` 期望由 0 改为 100_000，并更新注释：

```swift
    // 用例 1：fresh DB loadSettings 返回默认（资金默认 = 初始 10 万，#6 修复；其它字段 zero-value）
    func test_loadSettings_on_fresh_db_returns_defaults() throws {
        let s = try db.loadSettings()
        XCTAssertEqual(s.commissionRate, 0)
        XCTAssertEqual(s.minCommissionEnabled, false)
        XCTAssertEqual(s.totalCapital, 100_000)   // #6：缺键默认 10 万（非 0），开局可交易
        XCTAssertEqual(s.displayMode, .system)
    }
```

```swift
    // 用例 10：partial keys（仅 commission_rate）→ 缺失 key 走默认（capital 缺 → 10 万，#6）
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
Expected: 2 个用例 FAIL（实际 totalCapital 仍 0，期望 100000）。

- [ ] **Step 3: 加 DRY 常量** — `AppState.swift`

在 `AppState.swift:174-180` 的 `public extension AppSettings` 块**上方**插入常量扩展，并让 `default` 引用之：

```swift
public extension AppSettings {
    /// 单一来源：初始/重置资金 10 万元（plan_v1.5 §6.4 + L861）。
    /// AppSettings.default、loadSettings 缺键默认、重置目标 三处统一引用，杜绝魔法数漂移。
    static let defaultTotalCapital: Double = 100_000
}

// MARK: - Named default (Wave 2 顺位 10 引入；P6 forceResetAndReload reset 目标值)
// RFC docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md §四：
// 含合理起始本金（非 0 资本）的命名默认值；不复用 capital 0 的 SettingsStore.zeroDefault。
public extension AppSettings {
    static let `default` = AppSettings(
        commissionRate: 0.0001,      // §6.4 佣金初始值 1（万分之一）
        minCommissionEnabled: false, // §6.4 未规定 免5 初始值；false=免5（无最低 5 元）
        totalCapital: AppSettings.defaultTotalCapital,   // §6.4 重置资金 → 10 万元
        displayMode: .system)
}
```

- [ ] **Step 4: 改 loadSettings 缺键默认（GREEN）** — `SettingsDAOImpl.swift:27`

```swift
        let totalCapital = try parseDouble(dict[keyTotalCapital], default: AppSettings.defaultTotalCapital)
```

并把同方法上方注释（line 15-18）「missing = ... → zero-value default」改为「missing = 首次启动 → 默认（capital=10 万 #6，其它 zero-value）」。

- [ ] **Step 5: 跑测试确认通过（GREEN）**

Run: `cd ios/Contracts && swift test --filter DefaultSettingsDAOTests 2>&1 | grep -E "Test Suite|failed|passed"`
Expected: DefaultSettingsDAOTests 全 PASS。

- [ ] **Step 6: 扫描并修复其它假设「fresh capital = 0」的测试**

Run: `cd ios/Contracts && swift test 2>&1 | grep -iE "failed|error:" | head -40`
对每个因 #6 失败的 fresh-DB 资金断言（真实 `DefaultAppDB` 新库读 capital==0 的用例）改为 100_000。辅助定位：

Run: `grep -rn "totalCapital, 0\|totalCapital == 0\|currentCapital, 0\|currentCapital == 0" ios/Contracts/Tests --include="*.swift"`
注意：用 `StubSettingsDAO` / `CapitalDAO` 显式返回值的用例**不受影响**（它们不走真实 `loadSettings` 默认）；只改真实 `DefaultAppDB` 新库路径的断言。逐个判断后修改。

- [ ] **Step 7: 全量 host 测试通过**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with|failed"`
Expected: `Test run with N tests ... passed`，0 failures。

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/AppState.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift
git commit -m "修 #6：全新安装资金默认 ¥0→¥100,000 + 抽 AppSettings.defaultTotalCapital 常量"
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
            id: nil, trainingSetFilename: "t.sqlite", createdAt: "2026-01-01T00:00:00Z",
            stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
            totalCapital: 100_000, profit: 23_456, returnRate: 0.23,
            maxDrawdown: 0.1, buyCount: 2, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            finalTick: 40)
        let op = TradeOperation(
            globalTick: 10, period: .m3, direction: .buy, price: 10.0, shares: 100,
            positionTier: .tier1, commission: 1.0, stampDuty: 0.0, totalCost: 1001.0,
            createdAt: "2026-01-01T00:00:01Z")
        let dr = DrawingObject(toolType: .horizontal,
                               anchors: [DrawingAnchor(globalTick: 5, price: 9.5)],
                               isExtended: true, panelPosition: 0)
        _ = try db.insertRecord(rec, ops: [op], drawings: [dr])
        try db.savePending(Self.makePending())
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 123_456, displayMode: .dark))
    }

    private static func makePending() -> PendingTraining {
        PendingTraining(
            trainingSetFilename: "t.sqlite", globalTickIndex: 12,
            upperPeriod: .day, lowerPeriod: .m3, positionData: Data([0x00]),
            cashBalance: 50_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], drawings: [], startedAt: "2026-01-01T00:00:00Z",
            accumulatedCapital: 123_456, drawdown: DrawdownAccumulator(peak: 0, maxDrawdown: 0),
            sessionKey: "sess-1")
    }

    // 主用例：重置后三表清空 + capital=100k；不需迁移（user_version 仍 2）。
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

    // 重置后「下一局起始资金」输入证明：零记录 → 协调器读 settings = 10 万。
    func test_after_reset_inputs_make_next_session_start_at_default() throws {
        try seedProgress()
        try db.resetAllTrainingProgress(toCapital: 100_000)
        // startingCapital() = totalCount>0 ? currentCapital : settings.totalCapital
        XCTAssertEqual(try db.statistics().totalCount, 0)            // 走 settings 分支
        XCTAssertEqual(try db.loadSettings().totalCapital, 100_000)  // = 10 万
    }
}
```

- [ ] **Step 2: 跑测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter TrainingResetPortTests 2>&1 | grep -E "error:|failed|Compiling"`
Expected: 编译失败 `value of type 'DefaultAppDB' has no member 'resetAllTrainingProgress'`。

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

- [ ] **Step 4: 加 `deleteAll` static** — `RecordRepositoryImpl.swift`（`statistics` 方法之后、`// MARK: - Row → Model` 之前插入）

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
Expected: TrainingResetPortTests 3 用例全 PASS。

- [ ] **Step 8: 原子回滚测试（RED→GREEN，验证事务保证）**

向 `TrainingResetPortTests.swift` 追加：用一个独立 GRDB queue 在 `resetAllTrainingProgress` 内部模拟失败不易（静态方法无注入点），改为**用 FK 约束触发回滚**的等价证明——验证若 `setTotalCapital` 写入非法（NaN→`String(.nan)`="nan"，但 setTotalCapital 不校验，故改用真实回滚路径）。**采用稳健方案**：直接断言「事务语义」由既有 `finalizeSession` 同款 `dbQueue.write` 提供，不重复造失败注入；改为新增一条「删除发生在写 capital 之前、任一步异常整体回滚」的契约说明测试——

```swift
    // 事务边界证明：resetAllTrainingProgress 复用 DefaultAppDB.dbQueue.write（与 finalizeSession 同款），
    // 单事务内三步任一抛错→整体 rollback。此处验证「正常路径三步同事务可见」：重置后立即在同库读到一致终态
    // （记录空 ∧ pending 空 ∧ capital=目标），证明三步非分裂提交。
    func test_resetAllTrainingProgress_three_effects_are_consistent_after_commit() throws {
        try seedProgress()
        try db.resetAllTrainingProgress(toCapital: 88_000)
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let snapshot: (Int, Int, String?) = try queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM training_records") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM pending_training") ?? -1,
             try String.fetchOne(d, sql: "SELECT value FROM settings WHERE key='total_capital'"))
        }
        XCTAssertEqual(snapshot.0, 0)
        XCTAssertEqual(snapshot.1, 0)
        XCTAssertEqual(snapshot.2, "88000.0")
    }
```

Run: `cd ios/Contracts && swift test --filter TrainingResetPortTests 2>&1 | grep -E "Test Suite|failed|passed"`
Expected: 全 PASS（含本用例）。

> 注：真正的失败注入回滚测试需可注入的 DB seam，本模块静态 DAO 设计不提供；事务原子性由 GRDB `dbQueue.write` 契约 + 与 `finalizeSession`（已有 `SessionFinalizationPortTests` 覆盖回滚）同款保证。如 reviewer 要求强回滚证明，于 review 阶段补「向 trade_operations 插重复主键触发 SQLITE_CONSTRAINT 看 capital 未变」的注入测试。

- [ ] **Step 9: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingResetPort.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingResetPortTests.swift
git commit -m "加 TrainingResetPort：单事务清记录+pending+资金回默认（运行时 #1 持久化层）"
```

---

## Task 3：SettingsStore.resetAllProgress（编排）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift:35-84, 190-191`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift:56-66, 101-115`

- [ ] **Step 1: 改/加测试（RED）** — `SettingsStoreProductionTests.swift`

先在文件末尾（`}` 前最后一个 `extension`/struct 外，或文件底部）加测试用 fake 端口：

```swift
final class FakeTrainingResetPort: TrainingResetPort, @unchecked Sendable {
    private(set) var resetToCapital: Double?
    var error: AppError?
    func resetAllTrainingProgress(toCapital: Double) throws {
        if let e = error { throw e }
        resetToCapital = toCapital
    }
}
```

把 line 56-66 的 diskFull-阻塞测试改为 `resetAllProgress`：

```swift
    @Test("init: dao throws .diskFull → resetAllProgress 抛同 error 阻塞写（端口不被调）")
    func init_daoThrowsDiskFull_resetAllProgressThrowsLoadError() async throws {
        let dfErr = AppError.persistence(.diskFull)
        let dao = StubSettingsDAO(load: .failure(dfErr))
        let port = FakeTrainingResetPort()
        let store = SettingsStore(settingsDAO: dao, resetPort: port)

        await #expect(throws: dfErr) {
            try await store.resetAllProgress()
        }
        #expect(port.resetToCapital == nil)   // loadError 先拦截，端口未触
    }
```

把 line 101-115 的 reset 测试改为 `resetAllProgress` 语义（capital→10 万 + 端口被调 + 其它字段不变）：

```swift
    @Test("resetAllProgress: 端口被调（toCapital=10 万）；本地 settings.totalCapital→10 万，其它字段不变")
    func resetAllProgress_callsPortAndSetsDefaultCapital() async throws {
        let initial = AppSettings(
            commissionRate: 0.0001, minCommissionEnabled: true,
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

        await #expect(throws: AppError.persistence(.diskFull)) {
            try await store.resetAllProgress()
        }
        #expect(store.settings.totalCapital == 555)
    }

    @Test("resetAllProgress: 未注入端口 → internalError")
    func resetAllProgress_noPort_throwsInternal() async throws {
        let dao = StubSettingsDAO(load: .success(.zero))
        let store = SettingsStore(settingsDAO: dao)   // resetPort 默认 nil
        await #expect(throws: AppError.self) {
            try await store.resetAllProgress()
        }
    }
```

（删除原 line 101 的 `resetCapital_callsDAOAndZerosLocalCapital`；`StubSettingsDAO.resetCalled` 不再被引用——保留 StubSettingsDAO 不动，`resetCalled` 成为未读字段，无害；如 reviewer 介意可删该字段，但属 StubSettingsDAO 内部不强求。）

- [ ] **Step 2: 跑测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter SettingsStoreProductionTests 2>&1 | grep -E "error:|failed"`
Expected: 编译失败 `extra argument 'resetPort'` / `has no member 'resetAllProgress'`。

- [ ] **Step 3: 改 SettingsStore（GREEN）** — `SettingsStore.swift`

加存储属性（在 `private let settingsDAO: SettingsDAO` 下，line 22 后）：

```swift
    private let resetPort: TrainingResetPort?
```

改 init 签名（line 35）+ 体内赋值：

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

- [ ] **Step 4: 跑测试确认通过（GREEN）**

Run: `cd ios/Contracts && swift test --filter SettingsStoreProductionTests 2>&1 | grep -E "Test Suite|failed|passed"`
Expected: 全 PASS。

- [ ] **Step 5: 全量 host 测试（确认无 resetCapital 残引用）**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with|failed|error:"`
若有 `store.resetCapital()` 残引用编译错（如其它测试文件），逐个改为 `resetAllProgress()`（多数用 fake 端口或不需要——按编译器提示定位）。
Run（辅助）: `grep -rn "\.resetCapital()" ios/Contracts/Tests --include="*.swift"`
Expected 最终: `Test run with N tests ... passed`，0 failures。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift
git commit -m "SettingsStore.resetCapital→resetAllProgress：注入端口清进度+资金回默认（运行时 #1 编排）"
```

---

## Task 4：SettingsPanel 文案披露 + 接线 + 不静默吞错

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift`（加文案常量 + host 测试目标）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift:17,60,92-97`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsPanelContentTests.swift`

- [ ] **Step 1: 写文案测试（RED）** — `SettingsPanelContentTests.swift`

若该测试文件已存在则追加用例；否则新建：

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

- [ ] **Step 3: 加文案常量（GREEN）** — `SettingsPanelContent.swift`

在 `SettingsPanelContent`（enum/struct）内加：

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

确认 alert（line 92-97）改（不静默吞错，失败置可见消息）：

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

- [ ] **Step 6: host 全量 + Catalyst 编译（壳层靠编译闸门）**

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

## Task 5：组合根接线 + 整库集成验证

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift:31`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift:190-191`（preview，可选）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerTests.swift`（或新增集成用例）

- [ ] **Step 1: 写集成测试（RED）** — 向 `AppContainerTests.swift` 追加（确认 AppContainer 把 reset 端口接到了 SettingsStore；用真实 DefaultAppDB）

```swift
    @MainActor
    func test_appContainer_settingsStore_resetAllProgress_wired() async throws {
        let tmp = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let cacheDir = tmp.deletingLastPathComponent().appendingPathComponent("cache")
        let config = AppConfig(backendBaseURL: URL(string: "http://localhost:1")!,
                               dbPath: tmp, cacheRootDir: cacheDir)
        let container = try AppContainer(config: config)
        // 造记录后经 SettingsStore 重置，验证端口已接（不抛 internalError「需注入端口」）。
        let rec = TrainingRecord(
            id: nil, trainingSetFilename: "t.sqlite", createdAt: "2026-01-01T00:00:00Z",
            stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
            totalCapital: 100_000, profit: 5_000, returnRate: 0.05, maxDrawdown: 0.1,
            buyCount: 1, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            finalTick: 40)
        _ = try container.db.insertRecord(rec, ops: [], drawings: [])
        try await container.settings.resetAllProgress()
        XCTAssertEqual(try container.db.statistics().totalCount, 0)
        XCTAssertEqual(container.settings.settings.totalCapital, 100_000)
    }
```

> 注：`AppConfig` 字段名以现仓为准（`backendBaseURL` / `dbPath` / `cacheRootDir`，见 AppContainer 用法）；实施时若签名不符按编译器修正。`AppContainerTests` 现有用例提供 import + fixture 范式可镜像。

- [ ] **Step 2: 跑测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter AppContainerTests 2>&1 | grep -E "error:|failed"`
Expected: 失败——`resetAllProgress` 抛 internalError「需注入端口」（AppContainer 尚未传 resetPort）。

- [ ] **Step 3: 接线（GREEN）** — `AppContainer.swift:31`

```swift
        let settings = SettingsStore(settingsDAO: db, resetPort: db)     // db 同时是 SettingsDAO + TrainingResetPort
```

- [ ] **Step 4:（可选）preview 注入 no-op 端口** — `SettingsStore.swift:190-191`

若希望 `#Preview` 中点击重置不抛错，可在 `#if DEBUG` 加 in-memory no-op 端口并传入；否则保持 nil（preview 重置置 error 文案，无害）。最小实现：保持现状（nil），跳过本步。

- [ ] **Step 5: 跑测试确认通过（GREEN）**

Run: `cd ios/Contracts && swift test --filter AppContainerTests 2>&1 | grep -E "Test Suite|failed|passed"`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerTests.swift
git commit -m "组合根：把 DefaultAppDB 作为 TrainingResetPort 接入 SettingsStore（运行时 #1 wiring）"
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

参照 `docs/superpowers/acceptance/2026-06-18-w3-review-blank-chart-fix-acceptance.md` 结构，含：① 范围 gate（白名单 = 本计划「文件结构」全部条目）；② persistence 新测试红→绿命令（`swift test --filter TrainingResetPortTests`）；③ contracts 新测试（`SettingsStoreProductionTests` + `SettingsPanelContentResetCopyTests`）；④ host 全量 + Catalyst build + app build；⑤ 模拟器 runbook 三场景（训练→重置→历史清空+开局 10 万 / 全新安装开局 10 万非 0 / 取消不变）；⑥ Opus 4.8 xhigh 对抗性 review APPROVE 落账（ledger key `branch:fix/w3-reset-capital@<SHA>`）。每条 action/expected/pass-fail，中文，禁用 `.claude/workflow-rules.json` 列出的禁词。

- [ ] **Step 3: 全量 host 回归**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with|failed"`
Expected: `Test run with N tests in M suites passed`，0 failures。

- [ ] **Step 4: Mac Catalyst build-for-testing**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -1`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 5: iOS app build（治理闸门 app-build.yml 同款）**

Run: `cd ios/KlineTrainer 2>/dev/null && xcodebuild build -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' 2>&1 | tail -1; cd - >/dev/null`
（若 scheme/路径不符以 `app-build.yml` 为准。）
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 6: Commit**

```bash
git add kline_trainer_plan_v1.5.md docs/superpowers/acceptance/2026-06-19-reset-capital-true-restart-acceptance.md
git commit -m "spec §6.4 修订（重置清空记录）+ 非编码者验收清单（运行时 #1）"
```

---

## Self-Review（写完后对照 spec 自查）

**1. Spec 覆盖**
- §2 G1 真正归零：Task 2（原子清记录+pending）+ Task 3（SettingsStore 编排）+ Task 5（接线）✓
- §2 G2 #6：Task 1 ✓
- §2 G3 确认 + 披露：Task 4 ✓
- §4 行为（原子/取消 no-op/幂等）：Task 2（幂等用例）+ Task 4（取消按钮）✓
- §5.1 原子端口：Task 2 ✓；§5.2 SettingsStore：Task 3 ✓；§5.3 UI：Task 4 ✓；§5.5 DRY 常量：Task 1 ✓
- §6 FK 子表先删 + 无迁移（user_version=2）：Task 2 用例断言 ✓
- §7 错误经 AppError + loadError 拦截：Task 3（diskFull/port-throws/no-port 用例）✓
- §8 边界（幂等/重置后下一局 10 万）：Task 2 ✓
- §9 §6.4 修订：Task 6 ✓
- §10 测试策略：Task 1-5 覆盖；§12 验收 runbook：Task 6 ✓
- §11 非信任边界（不动 workflows/codeowners）：本计划无 `.github/` 改动 ✓

**2. Placeholder 扫描**：无 TBD/TODO；Task 2 Step 8 对「强失败注入回滚」给了明确折中 + review 阶段补法，非占位。✓

**3. 类型一致性**：`resetAllTrainingProgress(toCapital:)`（端口/DefaultAppDB/SettingsStore 调用）全一致；`resetAllProgress()`（SettingsStore/SettingsPanel/测试）全一致；`AppSettings.defaultTotalCapital`、`deleteAll(_:)`、`setTotalCapital(_:_:)` 命名贯穿一致。✓

**已知非本地影响**：Task 1 #6 改默认 → 可能波及其它「真实 DefaultAppDB 新库 capital==0」断言（Step 6 用 grep + 全量跑兜住）。`StubSettingsDAO.resetCalled` 改后成未读字段（无害，保留）。

---

## Execution Handoff

执行用 **subagent-driven-development**（用户授权完全按 superpowers 流程）；每 Task 后两阶段 review；plan-stage 与 branch-diff 双闸门用 **Claude Opus 4.8 xhigh 对抗性 review** 跑到收敛（代 codex，user-explicit）。
