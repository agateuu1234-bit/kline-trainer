# Wave 3 顺位 10a — 持久化基础（原子 finalize port + 失败保留 + session-key schema 迁移）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落实 RFC §4.7 (a)(b)(c)（`docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` + modules `kline_trainer_modules_v1.4.md:1749-1751`）：单事务 session-finalization port、finalize 失败保留 session（retry/discard，禁 `onSessionEnded(nil)` 拆毁路径）、durable session key + P4 additive schema 迁移（四态测试 + MANDATORY 版本 bump）。

**Architecture:** 新 public protocol `SessionFinalizationPort`（Contracts 层）把 `insertRecord + clearPending` 收进 `DefaultAppDB` 单一 `dbQueue.write` 事务；session key 由 coordinator 在 Normal session 启动时生成（UUID）、随 `pending_training` 持久化、finalize 时随 record 入库并以 UNIQUE index 做幂等锚（retry 同 key → 返已存 id，不重插）。TrainingView 的 finalize 失败路径从「`onSessionEnded(nil)` 拆毁」改为「保留 session + alert 重试/放弃」。schema 经 GRDB named migration `0004_v1.6_session_key` additive 演进（baseline DDL 不动 → `check_app_schema_drift.sh` 关系不变）。

**Tech Stack:** Swift 6 / SwiftPM（`ios/Contracts`，macOS host 全测 + Mac Catalyst 编译闸门）、GRDB 6.29（DatabaseMigrator / DatabaseQueue 单写者）、Swift Testing（`@Test/#expect`，Contracts 测试）+ XCTest（`AppDBMigrationsTests` 既有范式）。

**不在本 PR（10b 晚置，RFC §4.7 总实施归属）：** (d) 终态 fence、(e) discard 持久终态（清 `pending_training`）、(f) provenance-aware 恢复、周期 autosave（§4.6）、跨 feature 故障注入。本 PR 的「放弃」仅 = 关 reader + 清活跃上下文 + 退出（pending 留存，durable discard 归 10b）。

---

## 契约出处（权威，不复述）

- RFC §4.7(a)：finalize 失败 → 保留 active session（reader/activeTraining 不 teardown）+ retry/discard；**禁** `onSessionEnded(nil)` 拆毁路径；成功（含 retry 成功）才 teardown。
- RFC §4.7(b)：新 port 把 `insertRecord` + `clearPending` 收进单一 `DefaultAppDB` 事务；注入 coordinator；禁 unsafe concrete downcast。
- RFC §4.7(c)：durable session key（session 启动生成 → 落 pending → 随 record 入库）；additive named migration（`0004_*`）+ records 列 UNIQUE 约束（retry 同 key 幂等返已存 id）+ existing-row 回填；fresh-install/upgrade/crash-after-commit/retry 四态测试；版本 bump MANDATORY（`user_version` + `CONTRACT_VERSION` 现 "1.5"）；**列名/DDL/目标版本号由本 plan 定**（见 D2/D3）。

## 现状证据（核实 2026-06-13，本 worktree HEAD = main `ddc96ea`）

- `TrainingSessionCoordinator.swift:230-231`：`recordRepo.insertRecord(...)` 与 `pendingRepo.clearPending()` 两次分离写（insert 内部单事务，clear 独立事务）→ 中间崩溃 = 重启重复 record。
- `TrainingView.swift:118-119`：`catch { onSessionEnded(nil) }` → `AppRouter.sessionEnded(recordId: nil)`（`AppRouter.swift:136-142`）关 reader + 清 activeTraining = 已完成局拆毁。
- `AppDBMigrations.swift`：migrator 现 2 条（`0001_v1.4_baseline` 设 `PRAGMA user_version = 1` / `0003_v1.4_purge_leased`）。baseline 与 `ios/sql/app_schema_v1.sql` 由 `scripts/check_app_schema_drift.sh` 锁 mirror。
- `app_schema_v1.sql:14-30/56-70`：`training_records` 无唯一约束（AUTOINCREMENT id）；`pending_training` singleton `CHECK (id = 1)` 无 session 身份列。
- `Models.swift:7`：`public let CONTRACT_VERSION = "1.5"`。
- 基线：`swift test` 864 tests / 123 suites 全 pass（2026-06-13 实测）。

## 设计决策

**D1 — sessionKey 不进 `TrainingRecord` 模型，作 port 独立参数。** `TrainingRecord` 是展示/Codable 面（15 字段，被 U3/U6 preview、SettlementView、AppRouter、InMemory fake、大量测试构造）；session key 是 infra 幂等锚，不展示、不参与 Codable 契约。port 签名 `finalizeSession(record:ops:drawings:sessionKey:) throws -> Int64` 把 key 直通列写入。代价：`listRecords/loadRecordBundle` 读不到 key——无消费者（幂等判定只在 insert 路径用 SQL 查询）。`PendingTraining` 则**必须**加字段（key 须随 pending 原子持久化、resume 还原），见 D4。

**D2 — migration 命名 `0004_v1.6_session_key`；`user_version` 1→2；`CONTRACT_VERSION` "1.5"→"1.6"。** DDL（additive，全部在一条 named migration 内）：
```sql
ALTER TABLE pending_training ADD COLUMN session_key TEXT;
ALTER TABLE training_records ADD COLUMN session_key TEXT;
UPDATE pending_training SET session_key = <UUID> WHERE session_key IS NULL;  -- existing-row 回填（singleton ≤1 行）
CREATE UNIQUE INDEX IF NOT EXISTS idx_training_records_session_key ON training_records(session_key);
PRAGMA user_version = 2;
```
- `training_records` 既有行**不回填**（保持 NULL）：历史记录无 retry 幂等需求；SQLite UNIQUE index 把 NULL 视作互异 → 多条 legacy NULL 合法（这是「允许 legacy NULL」语义的实现）。
- `pending_training` 既有行**回填** fresh UUID：使升级后 resume → finalize 全链路恒有 key，loadPending 无 NULL 分支负担（防御性 NULL→`.dbCorrupted` 仍保留）。
- baseline `v1_4_baselineDDL` 与 `ios/sql/app_schema_v1.sql` **都不动** → drift gate 关系不变。0004 的 DDL 权威 = `AppDBMigrations.swift` migration 链（GRDB 演进权威；RFC 授权列名/DDL 归本 plan）。

**D3 — 幂等实现 = 事务内 pre-select + UNIQUE index 兜底。** `RecordRepositoryImpl.insertRecord` 加 `sessionKey: String? = nil` 参数：key 非 nil 时先 `SELECT id FROM training_records WHERE session_key = ?`，命中 → 直接返已存 id（不重插 record/ops/drawings——前次事务已 commit 才可能命中）；未命中 → INSERT（含 session_key 列）。单写者 DatabaseQueue + 事务内查询无 race；UNIQUE index 兜底任何逻辑漏洞（漏判 → SQLITE_CONSTRAINT 抛错而非静默重复）。既有 `RecordRepository.insertRecord` 协议面不变（缺省 nil → 行为不变）。

**D4 — `PendingTraining` 加 `sessionKey: String`（非 optional，init 末位参数）。** 列经 0004 回填 + savePending 恒写 → 升级后无 NULL；`loadPending` 读 `String?`，NULL → `.persistence(.dbCorrupted)`（防御，理论不可达）。Codable synthesized 加键无害（pending 持久化走列非 JSON blob；M0.3 round-trip 测试同步更新）。

**D5 — port 注入 = `AppDB` typealias 扩展 + coordinator 第 7 个 init 参数。** `AcceptanceJournalDAO.swift:67` 的 `typealias AppDB` 追加 `& SessionFinalizationPort` → `DefaultAppDB: AppDB` 自动要求实现 → `AppContainer` 现成 `db` 直接注入，零 downcast。coordinator `init` 加 `finalization: SessionFinalizationPort`（Wave 2 未冻结，RFC §4.7b 明文「注入 coordinator」授权 init 变更）。call sites 全列：`AppContainer.swift:26-28`、`preview()`（`TrainingSessionCoordinator.swift:363-372`）、测试 fixture（Task 4 列举）。

**D6 — coordinator session-key 生命周期 mirror 既有 `now` 可注入范式（D5 先例 `TrainingSessionCoordinator.swift:33`）。**
- `@ObservationIgnored private(set) var activeSessionKey: String?`（internal，@testable 可读）+ `@ObservationIgnored var makeSessionKey: () -> String = { UUID().uuidString }`（internal，测试可覆盖）。
- `startNewNormalSession` 成功路径置 `activeSessionKey = makeSessionKey()`；`resumePending` 置 `pending.sessionKey`；`review/replay` 置 nil；`endSession` 清 nil。
- `saveProgress`：现有 guard 扩为同时解包 key（Normal 活跃局恒有 key，缺 = 同类 `.internalError`）。
- `finalize`：guard 解包 key 后改调 `finalization.finalizeSession(...)`，删除原 `recordRepo.insertRecord` + `pendingRepo.clearPending` 两行。`recordRepo`/`pendingRepo` 其余用途（statistics/loadRecordBundle/loadPending/savePending）不变。

**D7 — TrainingView 失败保留 = `finalizeFailed` 状态 + alert 重试/放弃；`didFinalize` 不回退。**
- `maybeAutoEnd` 的 `catch` 改置 `finalizeFailed = true`（**删除** `onSessionEnded(nil)`——§4.7a 禁拆毁路径的字面落点）。
- `.alert("结算入账失败", isPresented: $finalizeFailed)`：「重试」→ 复跑同一 finalize Task 体（成功 → `onSessionEnded(id)`；再失败 → 重置 `finalizeFailed = true`）；「放弃」→ `Task { await lifecycle.endAfterSettlement(); onExit() }`（关 reader + 清 context + 回首页；pending 留存 = 可从最近存档恢复，durable discard 归 10b）。
- `didFinalize` 保持 true：阻 `.onChange` 重入；重试是显式用户动作不经 `maybeAutoEnd`。
- replay 路径不受影响：`finalizeForSettlement` 对 replay 是**不抛的早返 nil**（`shouldSaveRecord()==false`），仍走 `onSessionEnded(nil)` = 正常 retreat。失败 alert 只能由 throw 触达（仅 Normal 入账失败）。
- `AppRouter.sessionEnded` 行为不动（nil 分支对 replay retreat 必需；normal-nil 防御分支保留无害），仅更新 `AppRouter.swift:137` 注释去掉「normal finalize 失败」字样（该路径自本 PR 起不再由 TrainingView 触发）。

**D8 — InMemory fake：`InMemorySessionFinalizationPort` 组合既有两 fake + 失败注入。** 包装 `InMemoryRecordRepository` + `InMemoryPendingTrainingRepository`（保证 fake 状态一致），`var failNextFinalize: AppError?` 注入失败（**抛前零状态变更** = mirror 生产事务原子性），`keyed: [String: Int64]` 实现幂等。落 `PreviewFakes/InMemoryFakes.swift`（既有 fakes 同文件）。

**D9 — 原子性故障注入 = `PRAGMA max_page_count`。** PersistenceTests `@testable` 可达 `DefaultAppDB.dbQueue`（internal）：把 `max_page_count` 压到当前页数 → port 事务内 INSERT 分配新页 → SQLITE_FULL → 整事务 rollback → 断言 records 0 行 + pending 原样。payload 用足量 ops（如 200 条）保证触发页分配。

---

## File Structure（创建/修改全列）

| 文件 | 动作 | 责任 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Persistence/SessionFinalizationPort.swift` | Create | 新 port protocol（§4.7b） |
| `ios/Contracts/Sources/KlineTrainerContracts/Persistence/AcceptanceJournalDAO.swift` | Modify :67 | `typealias AppDB` 追加 `& SessionFinalizationPort` |
| `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift` | Modify | 注册 `0004_v1.6_session_key` |
| `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift` | Modify | `insertRecord` 加 `sessionKey:` 幂等参数 + INSERT 列 |
| `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingTrainingRepositoryImpl.swift` | Modify | save/load 带 `session_key` 列 |
| `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift` | Modify | `finalizeSession` 单事务实现 |
| `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift` | Modify | `PendingTraining` + `sessionKey: String` |
| `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | Modify :7 | `CONTRACT_VERSION` "1.5"→"1.6" |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` | Modify | init 第 7 参 + key 生命周期 + finalize 走 port |
| `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | Modify | `InMemorySessionFinalizationPort` |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | Modify | 失败保留 alert 重试/放弃 |
| `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift` | Modify :137 | 注释更新（行为不变） |
| `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift` | Modify :26-28 | coordinator 注入 `finalization: db` |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift` | Modify | fresh/upgrade 迁移测试 + 既有 user_version 断言 1→2（R1-C1） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift` | Modify :8 | `CONTRACT_VERSION` 断言 "1.5"→"1.6"（R1-C2） |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/SessionFinalizationPortTests.swift` | Create | retry 幂等 / crash-after-commit / 原子性 |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultPendingTrainingRepositoryTests.swift` | Modify | session_key 列 round-trip |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift` | Modify | key 生命周期 + 失败保留 + 幂等 retry（coordinator 层） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/`（编译波及） | Modify | `TrainingSessionCoordinator(`/`PendingTraining(` 构造点修编译（Task 4 Step 0 grep 全列） |
| `docs/acceptance/2026-06-13-wave3-pr10a-persistence-base.md` | Create | 中文非-coder 验收清单 |

预估 prod delta ≤300 行（上限 500 内；子项 = 3：port/失败保留/迁移）。

---

## Task 1: Migration `0004_v1.6_session_key` + 版本 bump

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift`

- [ ] **Step 1: 写失败测试（fresh-install 态 + upgrade 态）+ 改两个既有断言（plan-review R1-C1/C2）**

**先改两处既有断言（0004 落地后它们必须随契约更新，否则基线必破）：**

(a) `AppDBMigrationsTests.swift:50-59` 既有 `test_baseline_sets_user_version_1`（fresh 全 migrator 断言 `user_version == 1`）→ 0004 bump 后全 migrator 终态是 2。改名 + 改断言：

```swift
    // MARK: - migrator 跑过的 PRAGMA user_version（0004 起终态 = 2）
    func test_full_migrator_sets_user_version_2() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let queue = try AppDBFixture.openRaw(at: dbURL)
        let version: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        XCTAssertEqual(version, 2)   // 0001 置 1，0004 bump 至 2（RFC §4.7c MANDATORY bump）
    }
```

(b) `ModelsTests.swift:8` 既有 `#expect(CONTRACT_VERSION == "1.5")` → 改 `"1.6"`（测试名/注释如含 1.5 一并对齐）。

**再追加新测试**（XCTest，保持既有范式，fixture 用 `AppDBFixture`）：

```swift
// MARK: - 0004_v1.6_session_key（fresh-install 态）

func test_0004_fresh_install_has_session_key_columns_and_unique_index() throws {
    let dbURL = try AppDBFixture.makeFreshDB()
    defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
    let queue = try AppDBFixture.openRaw(at: dbURL)
    try queue.read { db in
        let pendingCols = try Row.fetchAll(db, sql: "PRAGMA table_info(pending_training)")
            .map { $0["name"] as String }
        XCTAssertTrue(pendingCols.contains("session_key"), "pending_training 须有 session_key 列")
        let recordCols = try Row.fetchAll(db, sql: "PRAGMA table_info(training_records)")
            .map { $0["name"] as String }
        XCTAssertTrue(recordCols.contains("session_key"), "training_records 须有 session_key 列")
        let idx = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'index' AND name = 'idx_training_records_session_key'
            """) ?? 0
        XCTAssertEqual(idx, 1, "session_key UNIQUE index 须存在")
    }
}

// MARK: - 0004（upgrade 态：v1.5 库含既有 pending 行 + 2 条 records → 回填/NULL 语义 + 数据无损）

func test_0004_upgrade_backfills_pending_key_and_leaves_record_keys_null() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("appdb-up-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("app.sqlite")

    // partial migrator（0001+0003，无 0004）模拟 v1.5 装机 —— AppDBFixture.makeV1_3SimulatedDB 同范式
    let queue = try DatabaseQueue(path: dbURL.path)
    var partial = DatabaseMigrator()
    partial.registerMigration("0001_v1.4_baseline") { db in
        try db.execute(sql: AppDBMigrations.v1_4_baselineDDL)
    }
    partial.registerMigration("0003_v1.4_purge_leased") { db in
        try db.execute(sql: "DELETE FROM download_acceptance_journal WHERE state = 'leased'")
    }
    try partial.migrate(queue)
    try queue.write { db in
        // 旧世界 pending 行（无 session_key 列时代写入）
        try db.execute(sql: """
            INSERT INTO pending_training
              (id, training_set_filename, global_tick_index, upper_period, lower_period,
               position_data, fee_snapshot, trade_operations, drawings,
               started_at, accumulated_capital, cash_balance, drawdown)
            VALUES (1, 'legacy.sqlite', 5, 'm60', 'm3', '', '{}', '[]', '[]', 100, 50000, 50000, '{}')
            """)
        // 2 条 legacy records
        for i in 0..<2 {
            try db.execute(sql: """
                INSERT INTO training_records
                  (training_set_filename, created_at, stock_code, stock_name, start_year,
                   start_month, total_capital, profit, return_rate, max_drawdown,
                   buy_count, sell_count, fee_snapshot, final_tick)
                VALUES ('legacy.sqlite', ?, 'C', 'N', 2020, 1, 50000, 0, 0, 0, 0, 0, '{}', 7)
                """, arguments: [100 + i])
        }
    }

    // 跑完整 migrator（含 0004）= 升级
    try AppDBMigrations.makeMigrator().migrate(queue)

    try queue.read { db in
        let pendingKey = try String.fetchOne(db,
            sql: "SELECT session_key FROM pending_training WHERE id = 1")
        XCTAssertNotNil(pendingKey, "升级须回填既有 pending 行的 session_key")
        XCTAssertFalse((pendingKey ?? "").isEmpty)
        let nullKeyRecords = try Int.fetchOne(db,
            sql: "SELECT COUNT(*) FROM training_records WHERE session_key IS NULL") ?? 0
        XCTAssertEqual(nullKeyRecords, 2, "legacy records 保持 NULL（不回填）")
        // 数据无损
        let recCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM training_records") ?? 0
        XCTAssertEqual(recCount, 2)
        let filename = try String.fetchOne(db,
            sql: "SELECT training_set_filename FROM pending_training WHERE id = 1")
        XCTAssertEqual(filename, "legacy.sqlite")
    }
}

// MARK: - 0004：legacy 多 NULL 与 UNIQUE index 共存（NULLs are distinct）

func test_0004_unique_index_allows_multiple_null_session_keys() throws {
    let dbURL = try AppDBFixture.makeFreshDB()
    defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
    let queue = try AppDBFixture.openRaw(at: dbURL)
    try queue.write { db in
        for i in 0..<2 {     // session_key 不给 → NULL；两条 NULL 不撞 UNIQUE
            try db.execute(sql: """
                INSERT INTO training_records
                  (training_set_filename, created_at, stock_code, stock_name, start_year,
                   start_month, total_capital, profit, return_rate, max_drawdown,
                   buy_count, sell_count, fee_snapshot, final_tick)
                VALUES ('f.sqlite', ?, 'C', 'N', 2020, 1, 1, 0, 0, 0, 0, 0, '{}', 0)
                """, arguments: [i])
        }
        let dup = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM training_records") ?? 0
        XCTAssertEqual(dup, 2)
        // 同非-NULL key 二次插入必撞 UNIQUE
        try db.execute(sql: """
            INSERT INTO training_records
              (training_set_filename, created_at, stock_code, stock_name, start_year,
               start_month, total_capital, profit, return_rate, max_drawdown,
               buy_count, sell_count, fee_snapshot, final_tick, session_key)
            VALUES ('f.sqlite', 9, 'C', 'N', 2020, 1, 1, 0, 0, 0, 0, 0, '{}', 0, 'K1')
            """)
        XCTAssertThrowsError(try db.execute(sql: """
            INSERT INTO training_records
              (training_set_filename, created_at, stock_code, stock_name, start_year,
               start_month, total_capital, profit, return_rate, max_drawdown,
               buy_count, sell_count, fee_snapshot, final_tick, session_key)
            VALUES ('f.sqlite', 10, 'C', 'N', 2020, 1, 1, 0, 0, 0, 0, 0, '{}', 0, 'K1')
            """), "同 session_key 第二次 INSERT 须撞 UNIQUE")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter "AppDBMigrationsTests|ModelsTests" 2>&1 | tail -20`
Expected: 新增 3 测试 + 改名的 user_version 测试 + ModelsTests CONTRACT_VERSION 断言 FAIL（无 session_key 列 / index / user_version 仍 1 / 版本仍 "1.5"）。

- [ ] **Step 3: 实现 0004 migration + CONTRACT_VERSION bump**

`AppDBMigrations.swift` `makeMigrator()` 末尾（`0003` 注册块后、`return migrator` 前）追加：

```swift
        // 0004：v1.6 session-key（RFC §4.7c，Wave 3 顺位 10a）
        // additive：pending_training + training_records 加 session_key 列；
        // records 列上 UNIQUE index = finalize retry 幂等锚（同 key 重试返已存 id，不重复入账）。
        // 既有 pending 行回填 fresh UUID（升级后 resume→finalize 全链路恒有 key）；
        // 既有 records 保持 NULL（历史记录无 retry 语义；SQLite UNIQUE 视 NULL 互异，多 NULL 合法）。
        migrator.registerMigration("0004_v1.6_session_key") { db in
            try db.execute(sql: "ALTER TABLE pending_training ADD COLUMN session_key TEXT")
            try db.execute(sql: "ALTER TABLE training_records ADD COLUMN session_key TEXT")
            try db.execute(sql: "UPDATE pending_training SET session_key = ? WHERE session_key IS NULL",
                           arguments: [UUID().uuidString])
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_training_records_session_key
                ON training_records(session_key)
                """)
            try db.execute(sql: "PRAGMA user_version = 2")
        }
```

`Models.swift:7`：`public let CONTRACT_VERSION = "1.5"` → `public let CONTRACT_VERSION = "1.6"`（注释如引用 1.5 一并对齐）。

- [ ] **Step 4: 跑测试确认通过 + drift gate 不破**

Run: `cd ios/Contracts && swift test --filter "AppDBMigrationsTests|ModelsTests" 2>&1 | tail -5`
Expected: PASS（含既有 0001/0003 测试 + 更新后的 user_version=2 / "1.6" 断言）。
Run: `bash scripts/check_app_schema_drift.sh`
Expected: `OK: AppDBMigrations.swift schema 与 ios/sql/app_schema_v1.sql 一致`（baseline 未动）。
Run: `grep -rn 'CONTRACT_VERSION' ios/Contracts --include="*.swift"`（Sources **和 Tests** 全扫，plan-review R1-C2）确认定义/断言只剩 "1.6"，无 stale "1.5"。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift
git commit -m "feat(10a): 0004_v1.6_session_key migration + CONTRACT_VERSION 1.6（RFC §4.7c）"
```

---

## Task 2: `PendingTraining.sessionKey` 字段 + 列读写

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift`（struct PendingTraining）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingTrainingRepositoryImpl.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultPendingTrainingRepositoryTests.swift`

- [ ] **Step 0: grep 全部 `PendingTraining(` 构造点**

Run: `grep -rn "PendingTraining(" ios/Contracts --include="*.swift" | grep -v "InMemoryPendingTrainingRepository\|protocol\|PendingTrainingRepository"`
已知站点：`TrainingSessionCoordinator.saveProgress`（Task 4 处理）、`PendingTrainingRepositoryImpl.loadPending`、`DefaultPendingTrainingRepositoryTests`、`TrainingSessionPersistenceTests`、`InMemoryDBFakesTests`、`AppStateTests`（如有）。本 task 只修 Persistence 侧 + 编译波及的测试构造（加 `sessionKey:` 实参）；coordinator 在 Task 4。

- [ ] **Step 1: 写失败测试（session_key 列 round-trip）**

`DefaultPendingTrainingRepositoryTests.swift` 是 **XCTest**（`final class … : XCTestCase`），既有 fixture 是**实例方法** `makePending(globalTickIndex:cashBalance:accumulatedCapital:)`（:70 起，plan-review R1-H1 核实）。给 `makePending` 加缺省参数 `sessionKey: String = "SK-default"`（构造 `PendingTraining` 时传入），再追加：

```swift
    func test_savePending_roundTrips_sessionKey() throws {
        let pending = makePending(globalTickIndex: 1, sessionKey: "SK-roundtrip-1")
        try db.savePending(pending)
        let loaded = try db.loadPending()
        XCTAssertEqual(loaded?.sessionKey, "SK-roundtrip-1")
    }
```

（`db` 用该文件既有 setUp/property 范式；以文件现状为准接线。）

- [ ] **Step 2: 编译失败确认**

Run: `cd ios/Contracts && swift build --build-tests 2>&1 | head -20`
Expected: FAIL —— `PendingTraining` 无 `sessionKey`。

- [ ] **Step 3: 实现**

`AppState.swift` `PendingTraining`：属性区追加 `public let sessionKey: String`（`drawdown` 后）；init 末位加 `sessionKey: String` 参数 + 赋值。结构体注释行「v1.3 denormalize」后追加一行 `// v1.6（Wave 3 10a）：+sessionKey（durable session key，RFC §4.7c）`。

`PendingTrainingRepositoryImpl.swift`：
- `savePending` SQL 列表加 `session_key`（13→14 列）、VALUES 加一个 `?`、arguments 末尾加 `p.sessionKey`。
- `loadPending`：读 `let keyOpt: String? = row["session_key"]`，`guard let key = keyOpt else { throw AppError.persistence(.dbCorrupted) }`（0004 回填后理论不可达，防御），构造时传 `sessionKey: key`。

全仓修编译：上述 grep 站点的测试构造统一加 `sessionKey: "SK-test"`（或语义化值）。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter "DefaultPendingTrainingRepository|AppState|InMemoryDBFakes" 2>&1 | tail -5`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add -A ios/Contracts
git commit -m "feat(10a): PendingTraining.sessionKey 字段 + session_key 列读写（RFC §4.7c）"
```

---

## Task 3: `SessionFinalizationPort` + `DefaultAppDB` 单事务实现 + 幂等 insert

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/SessionFinalizationPort.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/AcceptanceJournalDAO.swift:67`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/SessionFinalizationPortTests.swift`

- [ ] **Step 1: 写 port protocol + typealias 扩展（纯声明，先行——测试要引用类型）**

新文件 `SessionFinalizationPort.swift`：

```swift
// Kline Trainer Swift Contracts — Wave 3 顺位 10a session-finalization port
// Spec: kline_trainer_modules_v1.4.md:1749（§4.7b 单事务 port）+ :1751（§4.7c durable session key）
// RFC: docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md §4.7

/// 单事务会话终结：`insertRecord`（record+ops+drawings）与 `clearPending` 在**同一**
/// `DefaultAppDB` 事务内完成 —— 要么 record 入库且 pending 清，要么都不（§4.7b 原子契约）。
/// `sessionKey` 是幂等锚（§4.7c）：同 key 重试 → 不重插，返已存 recordId（前次事务已 commit 的场景）。
public protocol SessionFinalizationPort: Sendable {
    func finalizeSession(record: TrainingRecord,
                         ops: [TradeOperation],
                         drawings: [DrawingObject],
                         sessionKey: String) throws -> Int64
}
```

`AcceptanceJournalDAO.swift:67-70` typealias 改为：

```swift
public typealias AppDB = RecordRepository
                      & PendingTrainingRepository
                      & SettingsDAO
                      & AcceptanceJournalDAO
                      & SessionFinalizationPort
```

- [ ] **Step 2: 写失败测试（retry 幂等 / crash-after-commit / 原子 rollback）**

新文件 `SessionFinalizationPortTests.swift`（Swift Testing；fixture 复用 `AppDBFixture` + 一个本地 record builder）：

```swift
import Testing
import Foundation
import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite("SessionFinalizationPort（DefaultAppDB 单事务 + 幂等）")
struct SessionFinalizationPortTests {

    static func record(createdAt: Int64 = 1) -> TrainingRecord {
        TrainingRecord(id: nil, trainingSetFilename: "s.sqlite", createdAt: createdAt,
                       stockCode: "000001", stockName: "测试", startYear: 2020, startMonth: 3,
                       totalCapital: 50_000, profit: 1_000, returnRate: 0.02, maxDrawdown: -0.1,
                       buyCount: 1, sellCount: 1,
                       feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                       finalTick: 7)
    }

    static func op(tick: Int) -> TradeOperation {
        TradeOperation(globalTick: tick, period: .m3, direction: .buy, price: 10,
                       shares: 100, positionTier: .tier1, commission: 1,
                       stampDuty: 0, totalCost: 1001, createdAt: Int64(tick))
    }

    static func pending(sessionKey: String) -> PendingTraining {
        PendingTraining(trainingSetFilename: "s.sqlite", globalTickIndex: 7,
                        upperPeriod: .m60, lowerPeriod: .m3,
                        positionData: Data(), cashBalance: 50_000,
                        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                        tradeOperations: [], drawings: [], startedAt: 1,
                        accumulatedCapital: 50_000,
                        drawdown: .initial, sessionKey: sessionKey)
    }

    @Test("成功路径：record+ops+drawings 入库且 pending 清（单事务两效果）")
    func finalize_success_inserts_and_clears() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)
        try db.savePending(Self.pending(sessionKey: "SK-1"))
        let id = try db.finalizeSession(record: Self.record(), ops: [Self.op(tick: 1)],
                                        drawings: [], sessionKey: "SK-1")
        #expect(id > 0)
        #expect(try db.loadPending() == nil)
        let bundle = try db.loadRecordBundle(id: id)
        #expect(bundle.1.count == 1)
        // session_key 落列
        let key = try db.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT session_key FROM training_records WHERE id = ?",
                                arguments: [id])
        }
        #expect(key == "SK-1")
    }

    @Test("retry 幂等：同 sessionKey 第二次 finalize → 返同 id，不重插 record/ops")
    func finalize_same_key_is_idempotent() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)
        let id1 = try db.finalizeSession(record: Self.record(), ops: [Self.op(tick: 1)],
                                         drawings: [], sessionKey: "SK-R")
        let id2 = try db.finalizeSession(record: Self.record(createdAt: 99), ops: [Self.op(tick: 2)],
                                         drawings: [], sessionKey: "SK-R")
        #expect(id1 == id2)
        let counts = try db.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM training_records") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trade_operations") ?? -1)
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)   // 第二次的 ops 未重插
    }

    @Test("不同 sessionKey → 各自入库（幂等不误伤正常多局）")
    func finalize_distinct_keys_insert_separately() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)
        let a = try db.finalizeSession(record: Self.record(), ops: [], drawings: [], sessionKey: "SK-A")
        let b = try db.finalizeSession(record: Self.record(createdAt: 2), ops: [], drawings: [], sessionKey: "SK-B")
        #expect(a != b)
    }

    @Test("crash-after-commit：finalize 成功后重开 DB（模拟 relaunch）→ pending 无、record 恰 1 条")
    func finalize_commit_then_relaunch_no_duplicate_surface() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        do {
            let db = try DefaultAppDB(dbPath: dbURL)
            try db.savePending(Self.pending(sessionKey: "SK-C"))
            _ = try db.finalizeSession(record: Self.record(), ops: [], drawings: [], sessionKey: "SK-C")
        }   // db 出作用域 = 进程死前最后状态已 commit
        let relaunched = try DefaultAppDB(dbPath: dbURL)   // relaunch：migrator 幂等重跑
        #expect(try relaunched.loadPending() == nil)        // 无 pending → 不会 resume → 不会二次 finalize
        #expect(try relaunched.listRecords(limit: nil).count == 1)
    }

    @Test("原子性：事务内 INSERT 失败（SQLITE_FULL 注入）→ record 0 条 + pending 原样保留")
    func finalize_failure_rolls_back_both_effects() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)
        try db.savePending(Self.pending(sessionKey: "SK-F"))
        // 注入：页上限压到当前已用页数 → 后续页分配失败 SQLITE_FULL
        try db.dbQueue.write { d in
            let pages = try Int.fetchOne(d, sql: "PRAGMA page_count") ?? 1
            try d.execute(sql: "PRAGMA max_page_count = \(pages)")
        }
        let bigOps = (0..<2_000).map { Self.op(tick: $0) }   // 足量 payload 强制页分配
        #expect(throws: (any Error).self) {
            _ = try db.finalizeSession(record: Self.record(), ops: bigOps,
                                       drawings: [], sessionKey: "SK-F")
        }
        // 解除上限后验证两效果都未发生（rollback 双向）
        try db.dbQueue.write { d in try d.execute(sql: "PRAGMA max_page_count = 1073741823") }
        #expect(try db.loadPending() != nil, "pending 须原样保留")
        #expect(try db.listRecords(limit: nil).isEmpty, "record 须未入库")
    }
}
```

- [ ] **Step 3: 编译/测试失败确认**

Run: `cd ios/Contracts && swift build --build-tests 2>&1 | head -20`
Expected: FAIL —— `DefaultAppDB` 未实现 `finalizeSession`（typealias 扩展后 conformance 缺口）。

- [ ] **Step 4: 实现**

`RecordRepositoryImpl.swift` `insertRecord` 签名改：

```swift
    static func insertRecord(_ db: Database, record: TrainingRecord,
                             ops: [TradeOperation],
                             drawings: [DrawingObject],
                             sessionKey: String? = nil) throws -> Int64 {
        // §4.7c 幂等锚：同 key 已入库（前次事务已 commit）→ no-op 返已存 id，不重插 ops/drawings。
        // 单写者 DatabaseQueue + 事务内查询无 race；UNIQUE index 兜底逻辑漏洞（漏判 → SQLITE_CONSTRAINT）。
        if let key = sessionKey,
           let existing = try Int64.fetchOne(db, sql:
               "SELECT id FROM training_records WHERE session_key = ?", arguments: [key]) {
            return existing
        }
        let feeJSON = try jsonEncode(record.feeSnapshot)
        try db.execute(sql: """
            INSERT INTO training_records
              (training_set_filename, created_at, stock_code, stock_name,
               start_year, start_month, total_capital, profit, return_rate,
               max_drawdown, buy_count, sell_count, fee_snapshot, final_tick, session_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                record.trainingSetFilename, record.createdAt,
                record.stockCode, record.stockName,
                record.startYear, record.startMonth,
                record.totalCapital, record.profit, record.returnRate,
                record.maxDrawdown, record.buyCount, record.sellCount,
                feeJSON, record.finalTick, sessionKey
            ])
        let recordId = db.lastInsertedRowID
        // …（ops / drawings 两个 for 循环原样保留）
        return recordId
    }
```

（既有 `DefaultAppDB.insertRecord`（RecordRepository conformance）调用不带 `sessionKey:` → 缺省 nil → 行为不变。）

`DefaultAppDB.swift` `// MARK: - PendingTrainingRepository` 节前（insertRecord 后）追加：

```swift
    // MARK: - SessionFinalizationPort（Wave 3 顺位 10a，RFC §4.7b）

    /// 单事务：insert record(+ops+drawings, sessionKey 幂等) + clearPending。
    /// dbQueue.write 即事务边界 —— 任一步抛错整体 rollback（要么都成要么都不成）。
    public func finalizeSession(record: TrainingRecord, ops: [TradeOperation],
                                drawings: [DrawingObject], sessionKey: String) throws -> Int64 {
        do {
            return try dbQueue.write { db in
                let id = try RecordRepositoryImpl.insertRecord(
                    db, record: record, ops: ops, drawings: drawings, sessionKey: sessionKey)
                try PendingTrainingRepositoryImpl.clearPending(db)
                return id
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter SessionFinalizationPort 2>&1 | tail -5`
Expected: 5 测试 PASS。
Run: `cd ios/Contracts && swift test --filter "DefaultRecordRepository|AppDBHappyPath" 2>&1 | tail -5`
Expected: PASS（既有 insert 行为不变）。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/SessionFinalizationPort.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Persistence/AcceptanceJournalDAO.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/SessionFinalizationPortTests.swift
git commit -m "feat(10a): SessionFinalizationPort 单事务实现 + sessionKey 幂等 insert（RFC §4.7b/c）"
```

---

## Task 4: Coordinator 接线（init 注入 + key 生命周期 + finalize 走 port）+ InMemory fake

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift:26-28`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift`

- [ ] **Step 0: grep 全部 `TrainingSessionCoordinator(` 构造点**

Run: `grep -rn "TrainingSessionCoordinator(" ios/Contracts --include="*.swift" | grep -v "class TrainingSessionCoordinator"`
已知站点：`AppContainer.swift:26`、`preview()`（coordinator 文件内）、`TrainingSessionPersistenceTests.makeCoordinator` + `endSession_closesInjectedReader`、`TrainingSessionCoordinatorTests`、`TrainingSessionCoordinatorConstructionTests`、`AppRouterTests.makeRouter`、其它 grep 命中处。全部加 `finalization:` 实参。

- [ ] **Step 1: 实现 `InMemorySessionFinalizationPort`（fake 先行——测试要用）**

`InMemoryFakes.swift` `InMemoryPendingTrainingRepository` 之后追加：

```swift
/// Wave 3 顺位 10a：SessionFinalizationPort 的 in-memory fake。
/// 组合既有 record/pending 两 fake（保证 fake 状态一致）；mirror 生产单事务语义：
/// 失败注入时**零状态变更**（原子）；同 sessionKey 重试幂等返已存 id。
public final class InMemorySessionFinalizationPort: SessionFinalizationPort, @unchecked Sendable {
    private let lock = NSLock()
    private let records: InMemoryRecordRepository
    private let pending: InMemoryPendingTrainingRepository
    private var keyed: [String: Int64] = [:]
    /// 注入下一次 finalizeSession 抛错（消费后自动清除）。
    public var failNextFinalize: AppError?
    /// 调用计数（review/replay 不触 port 的断言用）。
    public private(set) var finalizeCallCount = 0

    public init(records: InMemoryRecordRepository, pending: InMemoryPendingTrainingRepository) {
        self.records = records
        self.pending = pending
    }

    public func finalizeSession(record: TrainingRecord, ops: [TradeOperation],
                                drawings: [DrawingObject], sessionKey: String) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        finalizeCallCount += 1
        if let err = failNextFinalize {
            failNextFinalize = nil
            throw err            // 原子：抛前零状态变更（mirror 生产事务 rollback）
        }
        if let existing = keyed[sessionKey] { return existing }   // 幂等
        let id = try records.insertRecord(record, ops: ops, drawings: drawings)
        keyed[sessionKey] = id
        try pending.clearPending()
        return id
    }
}
```

- [ ] **Step 2: 写失败测试（coordinator 层）**

`TrainingSessionPersistenceTests.swift`：`makeCoordinator` 改为同时返回 port fake（tuple 加一元），全文件构造点改用新 init；追加测试：

```swift
    /// makeCoordinator 改造后形态（供参照——返回值加 port）：
    static func makeCoordinator(
        candles: [Period: [KLineCandle]],
        capital: Double = 50_000,
        seedFile: TrainingSetFile? = cachedFile()
    ) -> (TrainingSessionCoordinator, InMemoryRecordRepository,
          InMemoryPendingTrainingRepository, InMemorySessionFinalizationPort) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let cache = InMemoryCacheManager()
        if let f = seedFile { cache._seedForTesting([f]) }
        let coord = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: candles),
            recordRepo: records,
            pendingRepo: pending,
            finalization: port,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: SettingsStore(settingsDAO: CapitalDAO(capital: capital)))
        return (coord, records, pending, port)
    }

    @Test("sessionKey 生命周期：startNew 生成 → saveProgress 落 pending → endSession 清空")
    func sessionKey_lifecycle_fresh_normal() async throws {
        let (coord, _, pending, _) = Self.makeCoordinator(candles: Self.validCandles())
        coord.makeSessionKey = { "SK-fixed" }
        let engine = try await coord.startNewNormalSession()
        #expect(coord.activeSessionKey == "SK-fixed")
        try await coord.saveProgress(engine: engine)
        #expect(try pending.loadPending()?.sessionKey == "SK-fixed")
        await coord.endSession()
        #expect(coord.activeSessionKey == nil)
    }

    @Test("sessionKey 生命周期：resumePending 还原存档 key（非新生成）")
    func sessionKey_lifecycle_resume_restores() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        coord.makeSessionKey = { "SK-original" }
        let e1 = try await coord.startNewNormalSession()
        try await coord.saveProgress(engine: e1)
        await coord.endSession()
        coord.makeSessionKey = { "SK-should-not-be-used" }
        let e2 = try await coord.resumePending()
        #expect(e2 != nil)
        #expect(coord.activeSessionKey == "SK-original")
    }

    @Test("sessionKey 生命周期：review/replay 不生成 key（nil）")
    func sessionKey_lifecycle_review_replay_nil() async throws {
        let (coord, records, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.startNewNormalSession()
        // 推到末态使 finalize 合法
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: engine)
        await coord.endSession()
        _ = try await coord.review(recordId: id!)
        #expect(coord.activeSessionKey == nil)
        await coord.endSession()
        _ = try await coord.replay(recordId: id!)
        #expect(coord.activeSessionKey == nil)
        await coord.endSession()
        _ = records   // silence unused
    }

    @Test("finalize 走 port：单调用 + 失败保留全 active 上下文 + retry 成功（§4.7a/b）")
    func finalize_failure_preserves_session_then_retry_succeeds() async throws {
        let (coord, _, pending, port) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        try await coord.saveProgress(engine: engine)
        port.failNextFinalize = .persistence(.ioError)
        await #expect(throws: AppError.self) {
            _ = try await coord.finalize(engine: engine)
        }
        // §4.7a 失败保留：active 上下文全在 + pending 未清
        #expect(coord.activeEngine === engine)
        #expect(coord.activeReader != nil)
        #expect(coord.activeSessionKey != nil)
        #expect(try pending.loadPending() != nil)
        // retry 成功 → record 入账 + pending 清
        let id = try await coord.finalize(engine: engine)
        #expect(id != nil)
        #expect(try pending.loadPending() == nil)
        #expect(port.finalizeCallCount == 2)
    }

    @Test("finalize 幂等端到端：port 已 commit 但调用方未收到 id（模拟）→ retry 返同 id 不重复入账")
    func finalize_retry_after_committed_returns_same_id() async throws {
        let (coord, records, _, port) = Self.makeCoordinator(candles: Self.validCandles())
        coord.makeSessionKey = { "SK-e2e" }
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        let id1 = try await coord.finalize(engine: engine)
        let id2 = try await coord.finalize(engine: engine)   // 同 key 二次（防御性 retry）
        #expect(id1 == id2)
        #expect(try records.listRecords(limit: nil).count == 1)
        #expect(port.finalizeCallCount == 2)
    }

    @Test("finalize review/replay：早返 nil，port 零调用（D2 不变量保持）")
    func finalize_review_replay_do_not_touch_port() async throws {
        let (coord, records, _, port) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: engine)
        await coord.endSession()
        let rev = try await coord.review(recordId: id!)
        #expect(try await coord.finalize(engine: rev) == nil)
        await coord.endSession()
        let rep = try await coord.replay(recordId: id!)
        #expect(try await coord.finalize(engine: rep) == nil)
        #expect(port.finalizeCallCount == 1)   // 仅 Normal 那次
        _ = records
    }
```

注意：既有 `finalize:`/`saveProgress:` 相关测试（如「清 pending」断言）继续 pass——port fake 组合同一 pending fake，行为镜像。

- [ ] **Step 3: 编译失败确认**

Run: `cd ios/Contracts && swift build --build-tests 2>&1 | head -20`
Expected: FAIL —— coordinator 无 `finalization`/`activeSessionKey`/`makeSessionKey`。

- [ ] **Step 4: 实现 coordinator + 接线**

`TrainingSessionCoordinator.swift`：
1. 存储属性区（`settings` 后）加 `private let finalization: SessionFinalizationPort`。
2. E6b 上下文区（`activeStartedAt` 后）加：
```swift
    /// 当前 Normal session 的 durable session key（RFC §4.7c）：fresh=makeSessionKey()；
    /// resume=pending.sessionKey；review/replay=nil；endSession 清空。finalize 幂等锚。
    @ObservationIgnored private(set) var activeSessionKey: String?
    /// 可注入 key 生成器（mirror `now` 范式，D5）。默认 UUID；@testable 测试可覆盖。
    @ObservationIgnored var makeSessionKey: () -> String = { UUID().uuidString }
```
3. init 签名 `pendingRepo:` 后加 `finalization: SessionFinalizationPort,` + 赋值（参数序与 AppContainer/测试 fixture 一致即可）。
4. `startNewNormalSession` 成功路径（`activeStartedAt = now()` 行后）加 `activeSessionKey = makeSessionKey()`。
5. `resumePending` 成功路径（`activeStartedAt = pending.startedAt` 行后）加 `activeSessionKey = pending.sessionKey`。
6. `review`/`replay` 成功路径（`activeStartedAt = nil` 行后）加 `activeSessionKey = nil`。
7. `saveProgress` guard 扩：`guard activeEngine === engine, let file = activeFile, let started = activeStartedAt, let key = activeSessionKey else { … }`；`PendingTraining(...)` 构造加 `sessionKey: key`。
8. `finalize`：guard 同样解包 `let key = activeSessionKey`；`:230-231` 两行替换为：
```swift
        let id = try finalization.finalizeSession(record: record, ops: engine.tradeOperations,
                                                  drawings: engine.drawings, sessionKey: key)
```
9. `endSession` 加 `activeSessionKey = nil`。
10. `preview()`：构造 records/pending 局部变量 + `InMemorySessionFinalizationPort(records:pending:)` 传入。

`AppContainer.swift:26-28`：`recordRepo: db, pendingRepo: db,` 后加 `finalization: db,`（`db: DefaultAppDB` 经扩展后的 `AppDB` typealias 自动满足 port——零 downcast）。

全仓修编译：Step 0 grep 站点逐一加 `finalization:` 实参（测试用 `InMemorySessionFinalizationPort(records:pending:)`，组合该 fixture 已有的两 fake）。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: 全量 PASS（864 基线 + 新增）。

- [ ] **Step 6: Commit**

```bash
git add -A ios/Contracts
git commit -m "feat(10a): coordinator 注入 SessionFinalizationPort + sessionKey 生命周期 + finalize 单事务化（RFC §4.7a/b/c）"
```

---

## Task 5: TrainingView 失败保留（重试/放弃 alert）+ AppRouter 注释

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift:137`（仅注释）
- Test: 既有 `AppRouterTests` 全绿（行为不变）；TrainingView 是 `#if canImport(UIKit)` Catalyst 编译闸门（host 不编译此文件，alert 行为由 acceptance 步骤 + Catalyst build 守护）

- [ ] **Step 1: 实现 TrainingView 失败保留**

`TrainingView.swift`：
1. `@State private var didFinalize = false` 后加：
```swift
    @State private var finalizeFailed = false
    @State private var finalizing = false      // R1-H2：in-flight 门，阻重试双击/并发 finalize Task
```
2. `body` 的 `.sheet(item:)` 后追加：
```swift
        .alert("结算入账失败", isPresented: $finalizeFailed) {
            Button("重试") { runFinalize() }
            // 放弃 = 关 reader + 清活跃上下文 + 回首页（§4.7a 用户显式选择；pending 留存可恢复，
            // durable discard〔清 pending + fence〕归顺位 10b §4.7e）
            Button("放弃", role: .cancel) {
                Task { await lifecycle.endAfterSettlement(); onExit() }
            }
        } message: {
            Text("本局结果尚未写入历史记录。可重试入账，或放弃结算退出（进度保留至最近存档）。")
        }
```
3. `maybeAutoEnd` 抽出共享 finalize 执行体 + catch 改保留（**删除 `onSessionEnded(nil)` 失败路径** = §4.7a 字面落点）：
```swift
    // D4/D5：判定下放 host-测 lifecycle.shouldAutoFinalize；壳仅持一次性 didFinalize + 触发 finalize。
    // .onAppear（resume-at-maxTick）与 .onChange(globalTickIndex)（步进至末态）双触发，!didFinalize 门保证仅一次。
    private func maybeAutoEnd() {
        guard lifecycle.shouldAutoFinalize(didFinalize: didFinalize) else { return }
        didFinalize = true
        runFinalize()
    }

    // §4.7a 失败保留：finalize 抛错 → 保留 session（不 onSessionEnded(nil) 拆毁）→ alert 重试/放弃。
    // didFinalize 保持 true：阻 .onChange 重入；重试是显式用户动作（alert 按钮）再次调用本方法。
    // finalizing in-flight 门（R1-H2）：阻重试双击产生并发 finalize Task（port 幂等兜数据层，
    // 此门兜 UI 层——防 onSessionEnded 双发/alert 与 settlement 路由交错）。@MainActor 串行置位无 race。
    // replay 的 finalizeForSettlement 是不抛的早返 nil（shouldSaveRecord()==false）→ 仍走
    // onSessionEnded(nil) = 正常 retreat 路径，不受本 alert 影响。
    private func runFinalize() {
        guard !finalizing else { return }
        finalizing = true
        Task {
            defer { finalizing = false }
            do {
                let id = try await lifecycle.finalizeForSettlement()
                onSessionEnded(id)
            } catch {
                finalizeFailed = true
            }
        }
    }
```
（TrainingView 为 `#if canImport(UIKit)` host 不编译——alert/重试行为无 host 单测，由 Catalyst 编译闸门 + acceptance 步骤守护；这是既有 U2 壳模式的已知边界。）

- [ ] **Step 2: AppRouter 注释更新（行为零改动）**

`AppRouter.swift:137` 注释 `// recordId==nil：replay 结束（retreat）或 normal finalize 失败——两者均须先关 reader` 改为：

```swift
            // recordId==nil：replay 结束（retreat）正常路径。normal finalize 失败自 Wave 3 10a 起
            // 不再走此路径（TrainingView 失败保留 + 重试/放弃，§4.7a）；normal-nil 分支保留作防御。
```

- [ ] **Step 3: host 全测 + Catalyst 编译验证**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: 全 PASS（AppRouterTests 行为未变）。
Run（Catalyst 编译闸门，本机有 Xcode 时）:
```bash
cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -3
```
Expected: `TEST BUILD SUCCEEDED`（TrainingView alert 块编译过）。

- [ ] **Step 4: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift \
        ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift
git commit -m "feat(10a): finalize 失败保留 session + 重试/放弃 alert，禁 onSessionEnded(nil) 拆毁路径（RFC §4.7a）"
```

---

## Task 6: 验收文档 + 全量验证

**Files:**
- Create: `docs/acceptance/2026-06-13-wave3-pr10a-persistence-base.md`

- [ ] **Step 1: 写中文非-coder 验收清单**（action / expected / pass_fail 三列；禁用语：「验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine」）

```markdown
# Wave 3 顺位 10a 持久化基础 验收清单（中文非-coder 可执行）

**PR 范围**：原子 finalize port + finalize 失败保留 session + session-key schema 迁移（RFC §4.7 a/b/c）。
13 个 prod/test 文件 + 本验收文档；不含 10b（autosave/终态 fence/discard 持久终态/provenance 恢复）。

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR 文件列表 | 见 `SessionFinalizationPort.swift` 新文件 + `AppDBMigrations.swift` 含 `0004_v1.6_session_key` | □ Pass / □ Fail |
| 2 | 在 PR 的 `AppDBMigrations.swift` diff 中查找 `0004_v1.6_session_key` | migration 块内含 `ALTER TABLE pending_training ADD COLUMN session_key`、`ALTER TABLE training_records ADD COLUMN session_key`、`CREATE UNIQUE INDEX`、`PRAGMA user_version = 2` 四条语句 | □ Pass / □ Fail |
| 3 | 在 PR 的 `Models.swift` diff 中查看第 7 行 | `CONTRACT_VERSION` 由 `"1.5"` 改为 `"1.6"` | □ Pass / □ Fail |
| 4 | 在 PR 的 `TrainingView.swift` diff 中搜索 `onSessionEnded(nil)` | catch 失败路径中**不再出现** `onSessionEnded(nil)`（替换为 `finalizeFailed = true`）；alert 含「重试」「放弃」两按钮 | □ Pass / □ Fail |
| 5 | 在 PR 的 `DefaultAppDB.swift` diff 中查看 `finalizeSession` | `dbQueue.write` 单闭包内先 `insertRecord` 后 `clearPending`（同一事务） | □ Pass / □ Fail |
| 6 | 打开 PR 的 Checks 页 | 全部 required checks 绿（含 macOS host tests、Mac Catalyst build、app-target build、schema drift） | □ Pass / □ Fail |
| 7 | 在 CI 日志（macOS host tests）搜索 `Test run with` | 测试总数 ≥ 880 且 `0 failures`（基线 864 + 本 PR 新增 ≥16） | □ Pass / □ Fail |
| 8 | 在 CI 日志搜索 `SessionFinalizationPort` | 套件含「retry 幂等」「crash-after-commit」「原子性」字样的测试名且全部 passed | □ Pass / □ Fail |
| 9 | 在 CI 日志搜索 `0004` | `AppDBMigrationsTests` 中 fresh-install / upgrade（回填 + legacy NULL）测试 passed | □ Pass / □ Fail |
```

（实施时按真实数字回填测试计数；CI job 名以 `.github/workflows` 现名为准。）

- [ ] **Step 2: 全量验证**

```bash
cd ios/Contracts && swift test 2>&1 | tail -3                  # 全量 host 测试
bash scripts/check_app_schema_drift.sh                          # drift gate
cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -3
```
Expected: 全 PASS / OK / TEST BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add docs/acceptance/2026-06-13-wave3-pr10a-persistence-base.md
git commit -m "docs(10a): 非-coder 验收清单"
```

---

## 变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-13 | v1 | 起草（契约出处 + 现状证据 + D1-D9 + 6 Tasks） |
| 2026-06-13 | v2 | opus 4.8 xhigh plan-stage 对抗评审 R1 = NEEDS-ATTENTION（2C+2H，premise 全 grep 实证）→ 全修：**R1-C1** 既有 `test_baseline_sets_user_version_1` 断言 1 必破 → Task 1 改名 `test_full_migrator_sets_user_version_2` + 断言 2；**R1-C2** `ModelsTests.swift:8` CONTRACT_VERSION "1.5" 断言必破 + stale-grep 只扫 Sources → 加 ModelsTests 修改项 + grep 扩 Tests；**R1-H1** Task 2 引用不存在的 `samplePending`/Swift Testing（实为 XCTest 实例 `makePending`）→ 改写为 XCTest + makePending 加 sessionKey 缺省参数；**R1-H2** TrainingView 重试无 in-flight 门（双击 → 并发 finalize Task → onSessionEnded 双发）→ 加 `finalizing` @State 门 + 注明 host 无单测边界 |

## Self-Review 记录（writing-plans 内置检查）

1. **Spec coverage**：§4.7a → Task 4（coordinator 保留测试）+ Task 5（TrainingView 禁拆毁 + retry/discard）；§4.7b → Task 3（port + 单事务 + 原子测试）+ Task 4（注入）；§4.7c → Task 1（迁移 + 四态中 fresh/upgrade + bump）+ Task 3（retry/crash-after-commit + 幂等）+ Task 2+4（key 生成→pending→record 全链路）。四态测试归位：fresh-install/upgrade=Task 1，crash-after-commit/retry=Task 3（DB 层）+ Task 4（coordinator 端到端）。
2. **Placeholder scan**：无 TBD/TODO；所有代码步骤给全文。
3. **Type consistency**：`finalizeSession(record:ops:drawings:sessionKey:)` / `InMemorySessionFinalizationPort(records:pending:)` / `activeSessionKey` / `makeSessionKey` / `sessionKey`（PendingTraining 末位参数）各 task 间一致。
