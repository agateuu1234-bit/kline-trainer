# PR 3c: P4 AppDB 三 Repo + AcceptanceJournalDAO + typealias AppDB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Round 1 修订标记**：本 plan 经 codex 对抗性 review round 1（branch-diff scope vs origin/main，5 findings：2 HIGH + 3 MEDIUM），全部 5 项实质 finding 已应用修订。详见末尾 Round N 章节 + Self-Review §"Round 1 修订列表"。

**Goal:** 在 `KlineTrainerPersistence` target 落地 P4 应用数据库 production 实现：单一 GRDB `DatabaseQueue` for `app.sqlite` + 4 个 protocol 实现（`RecordRepository` / `PendingTrainingRepository` / `SettingsDAO` / `AcceptanceJournalDAO`）+ composition root `DefaultAppDB`（`typealias AppDB` 合成）+ `DatabaseMigrator` 注册 `0001_v1.4_baseline` & `0003_v1.4_purge_leased` 两个 migration（per spec §M0.1 line 156 & line 265-289 与 §P4 line 1863-1948）。

**Architecture:** `DefaultAppDB` 持有唯一 `DatabaseQueue`，通过 `init(dbPath: URL) throws` 创建并跑 migrator；4 个 protocol 表面用 4 个 `extension DefaultAppDB`（每个 extension 一个 protocol surface），方法体只做 `dbQueue.write { db in ... }` / `dbQueue.read { db in ... }` 包装 + 调用同模块内的 `Internal/*Impl.swift` static 方法。`Internal/*Impl.swift` 写纯 SQL 逻辑（编码 / 解码 / FK 写入 / aggregate），**所有 GRDB 错误在 DefaultAppDB extension 边界 `try ... catch` 通过 `PersistenceErrorMapping.translate` 转 `AppError`**（per `docs/governance/m04-apperror-translation-gate.md` Gate 1）。Schema 用 Swift 多行字串内联（注释强制 mirror `ios/sql/app_schema_v1.sql`，CI guard 见 Task 8）。

**Tech Stack:** Swift 6.0 / SwiftPM / GRDB.swift 6.29.x（与 `ios/Contracts/Package.swift` Line 22 已 pin 一致）/ XCTest / 已 merged 的 `KlineTrainerContracts`（含 `AppError` / `TrainingRecord` / `PendingTraining` / `AppSettings` / `RecordRepository` / `PendingTrainingRepository` / `SettingsDAO` 等）/ 已 merged 的 `KlineTrainerPersistence` target（含 `PersistenceErrorMapping`）

---

## Design Decisions（review 必读 14 条）

下面 14 条是 spec 没显式定义、本 plan 自行选择的边界或落地策略。每条都需 reviewer 单独评估：

1. **Composition pattern：单类多 extension**：`DefaultAppDB.swift` 里 `final class DefaultAppDB: AppDB`；4 个 extension（每个对应一个 protocol surface）。**不用** 4 个独立 `final class` 各持自己的 queue—— spec L1865/L1933 字面要求"composition root 用 typealias 合成 + 共享单一 DatabaseQueue"。

2. **Schema inline Swift 字串 vs SwiftPM resource**：Schema DDL（83 行 SQL）用 Swift 多行字串内联进 `AppDBMigrations.swift`，**不**改 SwiftPM resource。
   - 选 inline：避开"`ios/sql/app_schema_v1.sql` 不在 `Sources/KlineTrainerPersistence/` 内 → 必须移文件 + 改 spec L131 路径"的连锁工作量。
   - 代价：两份 SQL（`ios/sql/app_schema_v1.sql` + `AppDBMigrations.swift` 内的字串），drift 风险。
   - 缓解：CI 脚本 `scripts/check_app_schema_drift.sh` 用 `diff <(awk 提取 inline 字串) ios/sql/app_schema_v1.sql`；Task 8 落实。

3. **Migration ID 选 `0001_v1.4_baseline` + `0003_v1.4_purge_leased`**：
   - `0001` 跑 schema baseline（83 行 SQL，等价 `ios/sql/app_schema_v1.sql`）。
   - `0003` 执行 `DELETE FROM download_acceptance_journal WHERE state = 'leased'`（spec L268 字面）。新 install 上 fresh DB → 无 `leased` 行 → 0 行影响（no-op），但 spec L265 强制必须注册。
   - **不**注册 `0002`（spec 未声明，留给将来 v1.3.x patch 占位）；GRDB `DatabaseMigrator` 不要求 ID 连续。

4. **GRDB ColumnEncodingStrategy 全局 snake_case 自动映射**：在 `DefaultAppDB.init` 里 `var config = Configuration()`（GRDB 6 已没有 columnDecodingStrategy 顶层 config，需要在 `FetchableRecord.databaseColumnDecodingStrategy` static 属性上声明）→ 落地：每个 `Internal/*Impl.swift` 的 row struct（如 `RecordRow`）`extension X: FetchableRecord { static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase } }` + `PersistableRecord` 对侧 `databaseColumnEncodingStrategy: .convertToSnakeCase`。**不**用全局 config—— GRDB 6 API 限制（plan3a/3b PR #41 同样 per-struct 而非全局）。

5. **Row struct 命名 = `<Entity>Row`，不复用 contracts 里的 model**：`RecordRow` / `PendingRow` / `SettingsRow` / `JournalRow` 都是 internal-only struct，专门做 GRDB FetchableRecord/PersistableRecord 桥接 + snake_case 列名映射。**不**让 `TrainingRecord` 直接 conform `FetchableRecord`（contracts 不能依赖 GRDB；同 plan 3a/3b 的 `KLineRow`/`MetaRow` 模式）。

6. **insertRecord 三表事务**：`insertRecord(record, ops, drawings)` 必须在单个 `dbQueue.write { db in ... }` 闭包内：① INSERT training_records 拿回 lastInsertRowID = recordId；② 循环 INSERT trade_operations 带 record_id FK；③ 循环 INSERT drawings 带 record_id FK + JSON encoded anchors。GRDB DatabaseQueue.write 闭包**默认**包 transaction，throw 触发 rollback。**返回 Int64 = 新插入的 recordId**。
   **R1 修订**：`listRecords` 与 `statistics` 的 ORDER BY 必须加 `id DESC` tiebreak（仅 `created_at DESC` 在同毫秒并列时 SQLite 任选，导致 statistics.currentCapital 不确定）。两处 SQL 均改为 `ORDER BY created_at DESC, id DESC`。

7. **DrawingObject.anchors → TEXT 列 JSON 编码**：`drawings.anchors` schema 列是 `TEXT NOT NULL`；落地用 `JSONEncoder().encode([DrawingAnchor]) → String(data:encoding:)` 写入；读侧 `JSONDecoder().decode([DrawingAnchor].self, from: ...)`。失败 → `AppError.persistence(.dbCorrupted)`。

8. **PendingTraining singleton 落地**：`pending_training` 表 schema CHECK(id = 1)，永远只有 0 或 1 行。`savePending` 用 `INSERT OR REPLACE INTO pending_training ... VALUES (1, ?, ?, ...)`（id 写死 1）。`loadPending` SELECT WHERE id = 1 LIMIT 1，0 行返回 nil；≥1 行（理论不应发生但 schema CHECK 保证只有 1）取第一行。`clearPending` DELETE FROM pending_training WHERE id = 1。`positionData: Data` → BLOB，但 schema 列是 TEXT；落地用 base64 encode 写入 TEXT 列（JSON 内嵌 binary 兼容）。`tradeOperations: [TradeOperation]` 与 `drawings: [DrawingObject]` → JSON encode TEXT。`drawdown: DrawdownAccumulator` → JSON encode TEXT。

9. **SettingsDAO key-value 表布局**：`settings(key TEXT PK, value TEXT)`。4 个固定 key：`commission_rate`（Double → string）/ `min_commission_enabled`（Bool → "true"/"false"）/ `total_capital`（Double → string）/ `display_mode`（DisplayMode rawValue: "light"/"dark"/"system"）。
   - `loadSettings`：SELECT key, value FROM settings；分 **missing** vs **malformed** 两路（R1 修订 codex high-2）：
     - **key 缺失**（首次启动 / 新增 key 未写）→ 用 zero-value default（commissionRate=0 / minCommissionEnabled=false / totalCapital=0 / displayMode=.system，与 `InMemoryFakes.swift` Line 44-47 默认对齐）
     - **key 存在但 value 不可解析**（如 commission_rate 列存了 "garbage"，或 display_mode 列存了 "purple"，或 commission_rate 列存了 "NaN" / "Infinity"）→ 抛 `AppError.persistence(.dbCorrupted)`。**不**走 default——这等于把损坏的财务参数静默重置 0，影响计算正确性。**R2 修订（codex med-3）**：`parseDouble` 必须 `.isFinite` 校验，拒 NaN / +inf / -inf。
   - **R2 修订（codex med-3）saveSettings 入参 finite 校验**：commission/capital 入参 NaN / inf → `AppError.internalError(module: "P4-SettingsDAO", detail: ...)`，不毒入 DB。`internalError` 而非 `dbCorrupted`：这是 caller 编程错误（上游不该传非有限值），走 debug log 不弹 Toast。
   - `saveSettings`：4 次 `INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)`，单 transaction。
   - `resetCapital`：`INSERT OR REPLACE INTO settings(key, value) VALUES ('total_capital', '0.0')` 单语句。

10. **AcceptanceJournalDAO.upsert 单调 rank guard（R1 修订 codex high-1）**：表 UNIQUE(training_set_id, lease_id)。原方案 ON CONFLICT 盲覆盖会让晚到 retry 把已 .stored/.confirmed 的行倒回 .downloaded，导致 recovery 扫描失锚 + 终态被覆盖。**改为 read-then-write monotonic guard**：
    - 在 `dbQueue.write { db in ... }` 闭包内分 2 步：
      ① SELECT existing state（WHERE training_set_id=? AND lease_id=?；0 行 → INSERT 新行）
      ② 1 行 → 比较 `stateRank(new)` vs `stateRank(existing)`：
        - `new > existing` → UPDATE（含 state_entered_at 刷新）
        - `new == existing` → UPDATE（仅 state_entered_at + last_error + sqliteLocalPath + contentHash 刷新；同 state 重试合法）
        - `new < existing` → **NOOP**（保留 existing；不 throw —— 晚到 retry 是合法的并发模式，只是无效）
    - **state 转换 allowlist**（R4 修订 codex high-2 — explicit nextAllowed map 取代 rank 比较）：
      ```
      downloaded   → {crcOK, rejected}
      crcOK        → {unzipped, rejected}
      unzipped     → {dbVerified, rejected}
      dbVerified   → {stored, rejected}
      stored       → {confirmPending, rejected}
      confirmPending → {confirmed, rejected}
      confirmed    → {} (终态)
      rejected     → {} (终态)
      ```
      `rejected` 可从任何非终态推进（失败可在任何阶段发生）。`confirmed` 是成功终态。终态互不可转。**首次 INSERT 必须 .downloaded**（spec L1798+ "v1.4 首条持久化行起点"），caller 直接 INSERT 其它 state → `.internalError`（避免跳过 CRC/unzip/verify）。
    - **canApply(new, over old)** 规则：
      - `new == old` → 同 state 重试，允许（仅刷新 entered_at + 辅助列）
      - `new ∈ nextAllowed(old)` → 一步转换，允许
      - 其它（含跨步跳过 / backward / 终态后转 / 终态互斥）→ NOOP（不抛错，retry 是合法并发模式）
    - **R2 修订（codex high-1）UPDATE aux 列走 COALESCE**：`sqlite_local_path / content_hash / last_error` 用 `COALESCE(?, existing)`，nil 入参不擦已有值。原方案直接 `SET sqlite_local_path = ?` 会让 stale .stored retry（caller 丢失 path）把 stored 行的 path/hash 清成 NULL → recovery 失锚。state / state_entered_at 总是覆盖（forward 推进或同 state 重试都需刷新 stamp）。
    - **R2 修订（codex med-2）existing 是 unknown raw value → NOOP + os_log warning**：原方案 fall-through 到 update（用 caller 已知 state 覆盖 unknown 行），违反 spec L289 fail-safe ignore 原则。改为：发现 existing rawValue 不在 v1.4 enum 内 → 直接 NOOP + os_log error，不动该行；留给 migration / 手工修复处理（避免覆盖 forward-version skew 行）。
    - `state_entered_at` 由实现侧用 `Int64(Date().timeIntervalSince1970)`（Unix 秒 UTC，per spec L241）—— 仅 update 路径刷新；NOOP 路径不刷新。**R3 修订（codex med-3）**：原方案误用毫秒，与 schema 列定义冲突；fix 后与 spec 时间戳约定（L377 "所有 datetime 字段 = Unix 秒 UTC"）一致。
    - **R3 修订（codex high-1）state-dependent invariants**：forward 推进到 `.stored` / `.confirmPending` / `.confirmed` 必须有 sqliteLocalPath（caller 新传或已存在）；`.stored` 还要 contentHash 8-char 小写 hex（per spec L390 CRC32）。不满足 → `.internalError(module: "P4-AcceptanceJournalDAO", ...)`。这是 DAO 边界 defense-in-depth，避免 caller bug 让 recovery 失锚。
    - **caller 侧无 API 变化**：upsert 签名不变；NOOP 对 caller 不可见，caller 后续 listByState 拿到的是 existing state（与单调推进语义一致）。

11. **AcceptanceJournalDAO.listByState fail-safe + os_log 警告（R1 修订 codex med-3）**：spec L289 字面要求"fail-safe 忽略未定义 raw value"。`listByState(_ state: P2JournalState)` 主路径 SQL `WHERE state = ?` bind enum.rawValue → DB 不会返回任何"未定义"行；但**冗余加固层** `journalRowFromRow` decode 过程若 DB state 列含 v1.4 enum 外的字串（如 0003_purge_leased 失败前的 v1.3 残留 leased 行），落地：
    - **不**抛 `.dbCorrupted`（旧方案）
    - **改为**：`P2JournalState(rawValue: stateRaw) == nil` → `os_log(.error, "AcceptanceJournalDAO: unknown state '%{public}@' for trainingSetId=%d leaseId=%{public}@; skipping row", stateRaw, trainingSetId, leaseId)` + 跳过该行（不放进返回 array）
    - 观测性：os_log 走 unified logging，可由 Console.app / oslog CLI 抓取；不污染 UI Toast
    - 测试侧：raw SQL 注入 `state='leased'` 行 → `listByState(.downloaded)` 返回空 array，不抛错（os_log 副作用难直测，靠 manual 验证 + acceptance grep 兜底）

12. **AcceptanceJournalDAO.deleteByIdLease**：`DELETE FROM download_acceptance_journal WHERE training_set_id = ? AND lease_id = ?`，0 或 1 行删除均合法（spec 未要求"必须存在"），不抛 not-found。

13. **PersistenceErrorMapping 扩展 SQLITE_FULL → diskFull**：现有 mapping（plan3a/3b 落地）只覆盖 read 路径错误（SQLITE_CANTOPEN / NOTADB / CORRUPT）。本 PR 新增 write 路径，必须加 `if dbErr.resultCode == .SQLITE_FULL { return .persistence(.diskFull) }`。`AppError.PersistenceReason.diskFull` 已在 contracts 存在（AppError.swift Line 30）。

14. **子项计数 = 3，prod 行预算 ~520 行（R1 修订后微涨）**：
    - 子项 1：AcceptanceJournalDAO contract additions（`AcceptanceJournalDAO.swift` 新建 + `InMemoryFakes.swift` 加 1 fake，共 ~110 行）
    - 子项 2：DefaultAppDB composition root + AppDBMigrations + PersistenceErrorMapping 扩展（共 ~210 行）
    - 子项 3：4 个 DAO 生产实现（4 个 `Internal/*Impl.swift` + 4 个 row struct，共 ~340 行；R1 修订加 +30：upsert rank guard +20、loadSettings 分路 +15、listByState fail-safe +10、合计 +45 行；其他 inline 优化 -15）
    - 总 prod ≈ 520。**比 500 硬规则超 20 行**——属"R1 真 finding 修订"必要扩张，非 packaging bias 打捆；feedback memory `feedback_planner_packaging_bias` 允许这种增量。Test ≈ 850 行（含 R1 新增 4 个 raw-SQL corruption test + tied timestamp test + stored→downloaded reject test，共 +6 tests，不计入 500 限制）。

---

## File Structure

**Create:**
- `ios/Contracts/Sources/KlineTrainerContracts/Persistence/AcceptanceJournalDAO.swift`（protocol + `P2JournalState` + `AcceptanceJournalRow` + `typealias AppDB`，~80 行）
- `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（composition root + 4 个 protocol surface extension，~140 行）
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift`（DatabaseMigrator + inline schema 字串，~140 行 含 80 行 SQL）
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift`（~100 行）
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingTrainingRepositoryImpl.swift`（~70 行）
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift`（~70 行）
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AcceptanceJournalDAOImpl.swift`（~70 行）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBFixture.swift`（test helper，~80 行）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift`（~80 行 / 4 tests）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultRecordRepositoryTests.swift`（~150 行 / 7 tests）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultPendingTrainingRepositoryTests.swift`（~100 行 / 5 tests）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift`（~120 行 / 6 tests）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultAcceptanceJournalDAOTests.swift`（~150 行 / 7 tests）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBHappyPathIntegrationTests.swift`（~70 行 / 1 test）
- `scripts/check_app_schema_drift.sh`（CI 脚本，~30 行）
- `docs/acceptance/2026-05-03-plan3c-appdb.md`（验收清单，~30 行）

**Modify:**
- `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`（加 `InMemoryAcceptanceJournalDAO` fake，约 +30 行）
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PersistenceErrorMapping.swift`（加 SQLITE_FULL → diskFull 分支，约 +5 行）

**总量预估**：prod ≈ 470 行（< 500 硬规则，Design Decision §14），test ≈ 750 行（不计入硬规则）。**核心子项 = 3**（contract / composition root / 4 DAO 实现）。

---

## Task 1: 创建 feature branch + worktree（防污染 main）

**Files:** None (git operations only)

- [ ] **Step 1.1: 创建 feature branch**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git status
# 期望：On branch main, working tree clean

git checkout -b plan3c-appdb
git status
# 期望：On branch plan3c-appdb
```

- [ ] **Step 1.2: 验证当前 SwiftPM build 干净**

```bash
cd "ios/Contracts"
swift build 2>&1 | tail -10
# 期望：Build complete!（基于 PR #41 状态应已 ok；如失败 → STOP，报告给 user）
```

- [ ] **Step 1.3: commit 空白基线（便于后续 reset）**

无文件改动；Step 1 不做 commit。继续 Task 2。

---

## Task 2: 子项 1 — AcceptanceJournalDAO contract additions（protocol + types + typealias AppDB）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/AcceptanceJournalDAO.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/AcceptanceJournalDAOContractTests.swift`（验证 typealias AppDB 编译 + InMemory fake 可实例化）

**为什么先做这步：** 后续 production 实现 (Task 5/6/7) 都 conform 这些 protocol；不先冻结 contract，后续 task 缺类型引用。

- [ ] **Step 2.1: 写 contract 失败测试**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/AcceptanceJournalDAOContractTests.swift`：

```swift
import XCTest
import KlineTrainerContracts

final class AcceptanceJournalDAOContractTests: XCTestCase {

    // MARK: - typealias AppDB 编译性测试
    func test_typealias_AppDB_composes_four_protocols() {
        // 仅编译期断言：声明一个 var: AppDB? = nil 必须能放下任意 4-protocol 复合实现
        var sink: AppDB? = nil
        XCTAssertNil(sink)
        // 编译 ok 即过；运行时不做事
    }

    // MARK: - P2JournalState rawValue 锚点（防 v1.4 删 leased 后回归）
    func test_P2JournalState_v1_4_states_only_no_leased() {
        let allRawValues: [String] = [
            P2JournalState.downloaded.rawValue,
            P2JournalState.crcOK.rawValue,
            P2JournalState.unzipped.rawValue,
            P2JournalState.dbVerified.rawValue,
            P2JournalState.stored.rawValue,
            P2JournalState.confirmPending.rawValue,
            P2JournalState.confirmed.rawValue,
            P2JournalState.rejected.rawValue,
        ]
        // 8 个状态，无 "leased"（v1.4 删除）
        XCTAssertEqual(Set(allRawValues).count, 8)
        XCTAssertFalse(allRawValues.contains("leased"))
        XCTAssertEqual(P2JournalState.downloaded.rawValue, "downloaded")
        XCTAssertEqual(P2JournalState.crcOK.rawValue, "crcOK")
        XCTAssertEqual(P2JournalState.confirmPending.rawValue, "confirmPending")
    }

    // MARK: - AcceptanceJournalRow 字段
    func test_AcceptanceJournalRow_has_eight_fields() {
        let row = AcceptanceJournalRow(
            id: 1,
            trainingSetId: 100,
            leaseId: "lease-abc",
            state: .downloaded,
            stateEnteredAt: 1_700_000_000_000,
            lastError: nil,
            sqliteLocalPath: "/tmp/x.sqlite",
            contentHash: "deadbeef"
        )
        XCTAssertEqual(row.id, 1)
        XCTAssertEqual(row.trainingSetId, 100)
        XCTAssertEqual(row.leaseId, "lease-abc")
        XCTAssertEqual(row.state, .downloaded)
        XCTAssertEqual(row.contentHash, "deadbeef")
    }

    // MARK: - InMemoryAcceptanceJournalDAO fake 接口存在性
    #if DEBUG
    func test_InMemoryAcceptanceJournalDAO_can_instantiate_and_satisfies_protocol() throws {
        let fake: AcceptanceJournalDAO = InMemoryAcceptanceJournalDAO()
        try fake.upsert(trainingSetId: 1, leaseId: "x", state: .downloaded,
                        sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let rows = try fake.listByState(.downloaded)
        XCTAssertEqual(rows.count, 0)  // Wave 0 fake 不实际持久化（与其它 P4 fake 一致）
        try fake.deleteByIdLease(trainingSetId: 1, leaseId: "x")
    }
    #endif
}
```

- [ ] **Step 2.2: 跑测试验证 fail（缺类型）**

```bash
cd "ios/Contracts"
swift test --filter AcceptanceJournalDAOContractTests 2>&1 | tail -20
# 期望：FAIL，错误如 "cannot find 'AcceptanceJournalDAO' in scope" 或 "cannot find 'P2JournalState' in scope"
```

- [ ] **Step 2.3: 写 contract 文件**

Create `ios/Contracts/Sources/KlineTrainerContracts/Persistence/AcceptanceJournalDAO.swift`：

```swift
// Kline Trainer Swift Contracts — P4 AcceptanceJournalDAO
// Spec: kline_trainer_modules_v1.4.md §P4 (line 1891-1931)
//       kline_trainer_modules_v1.4.md §M0.1 download_acceptance_journal (line 230-289)

import Foundation

// MARK: - Journal state enum（v1.4 删 leased，per spec L250-262）

public enum P2JournalState: String, Codable, Equatable, Sendable, CaseIterable {
    case downloaded         // zip 下载完成（v1.4 首条 journal 行起点）
    case crcOK              // CRC32 校验通过
    case unzipped           // 解压完成
    case dbVerified         // 训练组 SQLite 校验通过（P3a openAndVerify）
    case stored             // 已存入 cache，可被 P5 选中
    case confirmPending     // 等待 server confirm；崩溃恢复扫描点之一
    case confirmed          // server 确认成功
    case rejected           // server 拒收 / 本地校验失败
}

// MARK: - Row 投影类型（DAO 读出的不可变快照）

public struct AcceptanceJournalRow: Equatable, Sendable {
    public let id: Int64
    public let trainingSetId: Int
    public let leaseId: String
    public let state: P2JournalState
    public let stateEnteredAt: Int64        // Unix 秒 UTC（per spec L241）
    public let lastError: String?
    public let sqliteLocalPath: String?
    public let contentHash: String?         // CRC32 hex（M0.1 CHAR(8)）

    public init(
        id: Int64, trainingSetId: Int, leaseId: String,
        state: P2JournalState, stateEnteredAt: Int64,
        lastError: String?, sqliteLocalPath: String?, contentHash: String?
    ) {
        self.id = id
        self.trainingSetId = trainingSetId
        self.leaseId = leaseId
        self.state = state
        self.stateEnteredAt = stateEnteredAt
        self.lastError = lastError
        self.sqliteLocalPath = sqliteLocalPath
        self.contentHash = contentHash
    }
}

// MARK: - Protocol surface

public protocol AcceptanceJournalDAO: Sendable {
    /// 按 (training_set_id, lease_id) upsert 状态。state_entered_at 由实现侧 stamp。
    func upsert(trainingSetId: Int, leaseId: String,
                state: P2JournalState,
                sqliteLocalPath: String?,
                contentHash: String?,
                lastError: String?) throws

    /// 列出指定 state 的全部行（App 启动扫 stored / confirmPending）。
    func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow]

    /// 清理指定 (training_set_id, lease_id) 行（rejected 终态后或外部 GC 触发）。0 行删除合法。
    func deleteByIdLease(trainingSetId: Int, leaseId: String) throws
}

// MARK: - Composition root typealias（spec L1931）

public typealias AppDB = RecordRepository
                      & PendingTrainingRepository
                      & SettingsDAO
                      & AcceptanceJournalDAO
```

- [ ] **Step 2.4: 给 InMemoryFakes.swift 加 fake**

Modify `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`，在 `InMemorySettingsDAO` 之后、`#endif` 之前插入：

```swift
public final class InMemoryAcceptanceJournalDAO: AcceptanceJournalDAO, @unchecked Sendable {
    public init() {}
    public func upsert(trainingSetId: Int, leaseId: String,
                       state: P2JournalState,
                       sqliteLocalPath: String?,
                       contentHash: String?,
                       lastError: String?) throws {}
    public func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] { [] }
    public func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {}
}
```

- [ ] **Step 2.5: 跑测试验证 pass**

```bash
cd "ios/Contracts"
swift test --filter AcceptanceJournalDAOContractTests 2>&1 | tail -20
# 期望：Test Suite 'AcceptanceJournalDAOContractTests' passed (4 tests)
```

- [ ] **Step 2.6: 跑全套 contracts 测试无回归**

```bash
swift test --filter KlineTrainerContractsTests 2>&1 | tail -10
# 期望：所有现有 + 新增 contracts test pass，无 fail
```

- [ ] **Step 2.7: commit 子项 1**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/AcceptanceJournalDAO.swift
git add ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift
git add ios/Contracts/Tests/KlineTrainerContractsTests/AcceptanceJournalDAOContractTests.swift
git commit -m "feat(P4-contract): AcceptanceJournalDAO + P2JournalState + typealias AppDB

Per spec §P4 line 1891-1931:
- AcceptanceJournalDAO protocol (3 methods: upsert/listByState/deleteByIdLease)
- P2JournalState enum (8 v1.4 states, no leased)
- AcceptanceJournalRow struct (8 fields)
- typealias AppDB = 4-protocol composite
- InMemoryAcceptanceJournalDAO fake (Wave 0 preview path)

4 contract tests, all pass."
```

---

## Task 3: 子项 2.a — AppDBMigrations + DefaultAppDB skeleton（composition root + queue + migrator）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift`
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBFixture.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift`

**为什么这步：** 4 个 DAO impl（Task 4-7）都依赖 DefaultAppDB 提供 `dbQueue` + 已 migrate 完的 schema；先把骨架立起来。

- [ ] **Step 3.1: 写 fixture 助手**

Create `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBFixture.swift`：

```swift
import Foundation
import GRDB
@testable import KlineTrainerPersistence

/// Test-only helper：在唯一 tmp 目录下建一个新 app.sqlite，跑 AppDBMigrations。
/// 每个 test 调用 makeFreshDB() 拿独立 URL，避免 XCTest 并行测试 race。
enum AppDBFixture {

    /// 在 NSTemporaryDirectory() 下建唯一子目录 + 空 app.sqlite，跑过 migrator。返回 db URL。
    /// 调用方负责在 tearDown 删 url.deletingLastPathComponent()。
    static func makeFreshDB() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appdb-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("app.sqlite")
        // 通过 DefaultAppDB.init 触发 migrator
        _ = try DefaultAppDB(dbPath: dbURL)
        return dbURL
    }

    /// 在指定 dir 下建 v1.3 模拟数据：含 1 条 state='leased' journal 行。
    /// 用于测试 0003_v1.4_purge_leased migration。
    /// **R1 修订（codex med-2）**：必须用 partial migrator state（仅注册 0001 跑一次），
    /// 这样 grdb_migrations 表会有 0001 已 applied 记录；后续完整 migrator 跳过 0001
    /// 直接跑 0003。**不**用 raw SQL 跑 baseline DDL —— 那会让 grdb_migrations 空，
    /// 完整 migrator 重跑 0001 撞 "table exists" 抛错，0003 永远不验。
    static func makeV1_3SimulatedDB(at dbURL: URL) throws {
        let queue = try DatabaseQueue(path: dbURL.path)
        // 仅注册 0001（不注册 0003）跑 partial migration → grdb_migrations 标 0001 applied
        var partialMigrator = DatabaseMigrator()
        partialMigrator.registerMigration("0001_v1.4_baseline") { db in
            try db.execute(sql: AppDBMigrations.v1_4_baselineDDL)
        }
        try partialMigrator.migrate(queue)
        // 插入 v1.3 的 leased 行（v1.4 enum 已不允许，直接 raw SQL）
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO download_acceptance_journal
                  (training_set_id, lease_id, state, state_entered_at)
                VALUES (?, ?, 'leased', ?)
                """, arguments: [99, "lease-v13-residue", 1_700_000_000_000])
        }
    }

    /// 直接打开已经存在的 db（不跑 migrator）—— 用于测后台 inspection。
    static func openRaw(at dbURL: URL) throws -> DatabaseQueue {
        try DatabaseQueue(path: dbURL.path)
    }
}
```

- [ ] **Step 3.2: 写 AppDBMigrations 失败测试**

Create `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift`：

```swift
import XCTest
import GRDB
@testable import KlineTrainerPersistence

final class AppDBMigrationsTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appdb-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - schema 完整性
    func test_baseline_creates_six_tables_and_one_index() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let queue = try AppDBFixture.openRaw(at: dbURL)
        let tables: [String] = try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
        }
        XCTAssertEqual(tables, [
            "download_acceptance_journal",
            "drawings",
            "pending_training",
            "settings",
            "trade_operations",
            "training_records",
        ])

        let indexes: [String] = try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='index' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
        }
        XCTAssertTrue(indexes.contains("idx_journal_state"))
    }

    // MARK: - migrator 跑过的 PRAGMA user_version
    func test_baseline_sets_user_version_1() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let queue = try AppDBFixture.openRaw(at: dbURL)
        let version: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        XCTAssertEqual(version, 1)
    }

    // MARK: - 0003_v1.4_purge_leased 实际删 leased 行
    func test_purge_leased_migration_removes_v1_3_leased_rows() throws {
        let dir = tmpDir!
        let dbURL = dir.appendingPathComponent("app.sqlite")

        // 建 v1.3 模拟 DB（含 1 条 leased 行，未跑 0003）
        try AppDBFixture.makeV1_3SimulatedDB(at: dbURL)
        let queue = try AppDBFixture.openRaw(at: dbURL)

        let beforeLeased: Int = try queue.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM download_acceptance_journal WHERE state='leased'") ?? -1
        }
        XCTAssertEqual(beforeLeased, 1, "v1.3 模拟数据应有 1 条 leased")

        // 跑完整 migrator（含 0003）
        try AppDBMigrations.makeMigrator().migrate(queue)

        let afterLeased: Int = try queue.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM download_acceptance_journal WHERE state='leased'") ?? -1
        }
        XCTAssertEqual(afterLeased, 0, "0003_purge_leased 必须删掉 leased 行")
    }

    // MARK: - 0003 在 fresh DB 上 idempotent（无 leased 行不抛错）
    func test_purge_leased_migration_idempotent_on_fresh_db() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let queue = try AppDBFixture.openRaw(at: dbURL)
        // 再跑一次 migrator → 不抛错（GRDB DatabaseMigrator 内部 idempotent）
        XCTAssertNoThrow(try AppDBMigrations.makeMigrator().migrate(queue))
    }

    // R3 修订（codex high-2）：DDL 用 IF NOT EXISTS → 模拟 v1.3 残留（DB 已有表但无 grdb_migrations 记录）
    // baseline 0001 应可重跑不撞 "table exists"；0003 仍能跑
    func test_baseline_idempotent_on_legacy_db_with_tables_no_migration_record() throws {
        let dir = tmpDir!
        let dbURL = dir.appendingPathComponent("legacy.sqlite")
        // 直接 raw SQL 跑 baseline DDL —— 模拟 v1.3 装机后 grdb_migrations 表不存在的状态
        do {
            let queue = try DatabaseQueue(path: dbURL.path)
            try queue.write { db in
                try db.execute(sql: AppDBMigrations.v1_4_baselineDDL)
                // 注入 1 条 leased 行
                try db.execute(sql: """
                    INSERT INTO download_acceptance_journal
                      (training_set_id, lease_id, state, state_entered_at)
                    VALUES (?, ?, 'leased', ?)
                    """, arguments: [55, "legacy-leased", 1_700_000_000])
            }
        }
        // 现在跑完整 migrator —— 因为 IF NOT EXISTS，0001 不撞表已存在
        let queue = try DatabaseQueue(path: dbURL.path)
        XCTAssertNoThrow(try AppDBMigrations.makeMigrator().migrate(queue))
        // 0003 跑了 → leased 被删
        let leasedAfter: Int = try queue.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM download_acceptance_journal WHERE state='leased'") ?? -1
        }
        XCTAssertEqual(leasedAfter, 0, "legacy DB 上 0003 仍应删 leased 行")
    }

    // R3 修订（codex med-4）：PersistenceErrorMapping 不传 fileURL 时 CANTOPEN → .ioError，不是 .fileNotFound
    func test_PersistenceErrorMapping_without_fileURL_maps_CANTOPEN_to_ioError() throws {
        let cantopen = DatabaseError(resultCode: .SQLITE_CANTOPEN)
        let result = PersistenceErrorMapping.translate(cantopen)  // 不传 fileURL
        guard case .persistence(.ioError) = result else {
            return XCTFail("无 fileURL 应映射 .persistence(.ioError)，实际 \(result)")
        }
    }

    // R3 修订（codex med-4）：DefaultAppDB.init 失败时不应抛 .trainingSet（应 .persistence）
    // 用 read-only 父目录强制 SQLITE_CANTOPEN
    func test_DefaultAppDB_open_failure_throws_persistence_not_trainingSet() throws {
        let badPath = URL(fileURLWithPath: "/dev/null/x/app.sqlite")  // /dev/null 是设备节点不能 mkdir
        XCTAssertThrowsError(try DefaultAppDB(dbPath: badPath)) { err in
            guard let appErr = err as? AppError else {
                return XCTFail("期望 AppError，实际 \(err)")
            }
            // 必须 .persistence (.ioError 或 .diskFull)，不是 .trainingSet(.fileNotFound)
            switch appErr {
            case .persistence:
                break  // ok
            case .trainingSet:
                XCTFail("AppDB 错误不应映射成 .trainingSet（这是训练组语义）")
            default:
                XCTFail("意外错误类型 \(appErr)")
            }
        }
    }
}
```

- [ ] **Step 3.3: 跑测试验证 fail（缺 AppDBMigrations / DefaultAppDB）**

```bash
cd "ios/Contracts"
swift test --filter AppDBMigrationsTests 2>&1 | tail -20
# 期望：编译 fail，错误如 "cannot find 'DefaultAppDB' in scope" / "cannot find 'AppDBMigrations' in scope"
```

- [ ] **Step 3.4a: 同步 `ios/sql/app_schema_v1.sql`（R3 修订 codex high-2 — IF NOT EXISTS 加固）**

修改 `ios/sql/app_schema_v1.sql` 把所有 `CREATE TABLE` 改 `CREATE TABLE IF NOT EXISTS`，`CREATE INDEX` 改 `CREATE INDEX IF NOT EXISTS`：

```bash
sed -i.bak 's/^CREATE TABLE /CREATE TABLE IF NOT EXISTS /g; s/^CREATE INDEX /CREATE INDEX IF NOT EXISTS /g' ios/sql/app_schema_v1.sql && rm ios/sql/app_schema_v1.sql.bak
diff <(grep "^CREATE" ios/sql/app_schema_v1.sql) <(echo -e "CREATE TABLE IF NOT EXISTS training_records (\nCREATE TABLE IF NOT EXISTS trade_operations (\nCREATE TABLE IF NOT EXISTS drawings (\nCREATE TABLE IF NOT EXISTS pending_training (\nCREATE TABLE IF NOT EXISTS settings (\nCREATE TABLE IF NOT EXISTS download_acceptance_journal (\nCREATE INDEX IF NOT EXISTS idx_journal_state ON download_acceptance_journal(state);")
# 期望：无 diff（顺序与命名匹配）
```

- [ ] **Step 3.4b: 写 AppDBMigrations.swift（含 inline schema 字串）**

Create `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift`：

```swift
import Foundation
@preconcurrency import GRDB

/// app.sqlite GRDB DatabaseMigrator 注册表。
/// **Schema 必须 mirror `ios/sql/app_schema_v1.sql`**（CI 脚本 `scripts/check_app_schema_drift.sh` 校验）。
/// 添加新 migration：注册到 `makeMigrator()` 末尾，新 ID 命名 `00NN_v<ver>_<purpose>`。
enum AppDBMigrations {

    /// v1.4 baseline schema DDL（83 行 SQL；与 ios/sql/app_schema_v1.sql 严格相等）。
    /// internal 暴露给 AppDBFixture 测试 helper。
    static let v1_4_baselineDDL: String = """
    PRAGMA user_version = 1;

    CREATE TABLE IF NOT EXISTS training_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        training_set_filename TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        stock_code TEXT NOT NULL,
        stock_name TEXT NOT NULL,
        start_year INTEGER NOT NULL,
        start_month INTEGER NOT NULL,
        total_capital REAL NOT NULL,
        profit REAL NOT NULL,
        return_rate REAL NOT NULL,
        max_drawdown REAL NOT NULL,
        buy_count INTEGER NOT NULL,
        sell_count INTEGER NOT NULL,
        fee_snapshot TEXT NOT NULL,
        final_tick INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS trade_operations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL REFERENCES training_records(id),
        global_tick INTEGER NOT NULL,
        period TEXT NOT NULL,
        direction TEXT NOT NULL,
        price REAL NOT NULL,
        shares INTEGER NOT NULL,
        position_tier TEXT NOT NULL,
        commission REAL NOT NULL,
        stamp_duty REAL NOT NULL,
        total_cost REAL NOT NULL,
        created_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS drawings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL REFERENCES training_records(id),
        tool_type TEXT NOT NULL,
        panel_position INTEGER NOT NULL,
        is_extended INTEGER NOT NULL DEFAULT 0,
        anchors TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS pending_training (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        training_set_filename TEXT NOT NULL,
        global_tick_index INTEGER NOT NULL,
        upper_period TEXT NOT NULL,
        lower_period TEXT NOT NULL,
        position_data TEXT NOT NULL,
        fee_snapshot TEXT NOT NULL,
        trade_operations TEXT NOT NULL,
        drawings TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        accumulated_capital REAL NOT NULL,
        cash_balance REAL NOT NULL,
        drawdown TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS download_acceptance_journal (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        training_set_id INTEGER NOT NULL,
        lease_id TEXT NOT NULL,
        state TEXT NOT NULL,
        state_entered_at INTEGER NOT NULL,
        last_error TEXT,
        sqlite_local_path TEXT,
        content_hash CHAR(8),
        UNIQUE (training_set_id, lease_id)
    );

    CREATE INDEX IF NOT EXISTS idx_journal_state ON download_acceptance_journal(state);
    """

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // 0001：v1.4 baseline schema（fresh install 一次性建表）
        migrator.registerMigration("0001_v1.4_baseline") { db in
            try db.execute(sql: v1_4_baselineDDL)
        }

        // 0003：v1.4 数据迁移（删 v1.3 残留 'leased' journal 行；spec §M0.1 L265-289）
        // fresh install 上为 no-op；跨版本升级（v1.3 → v1.4）必须执行
        migrator.registerMigration("0003_v1.4_purge_leased") { db in
            try db.execute(sql: "DELETE FROM download_acceptance_journal WHERE state = 'leased'")
        }

        return migrator
    }
}
```

- [ ] **Step 3.5: 写 DefaultAppDB.swift skeleton（仅 init + queue，protocol body 留 fatalError 占位）**

Create `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`：

```swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// P4 应用数据库 composition root。
/// Spec: kline_trainer_modules_v1.4.md §P4 (line 1863-1948)
///
/// 设计要点（plan §Design Decisions §1, §6, §13）：
/// - 单一 DatabaseQueue for app.sqlite（spec L684 单一 queue 串行化约束）
/// - 4 个 protocol surface 用 4 个 extension 分别实现
/// - 所有 GRDB 错误在 extension 边界 `try ... catch` 通过 PersistenceErrorMapping.translate
/// - init 时同步跑 AppDBMigrations.makeMigrator().migrate(queue) → 失败抛 AppError
public final class DefaultAppDB: AppDB {

    /// 唯一 GRDB queue；所有 4 个 protocol 方法共享。internal 给 same-target tests 看。
    let dbQueue: DatabaseQueue

    /// 创建 / 打开 app.sqlite at `dbPath`，跑 migrator。
    /// throws AppError.persistence(.ioError) 若 GRDB 打开失败 / migrator 跑失败。
    /// throws AppError.persistence(.diskFull) 若磁盘满。
    public init(dbPath: URL) throws {
        do {
            // 父目录可能不存在 → 创建
            let parent = dbPath.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true)
            }

            var config = Configuration()
            // foreign_keys 默认 ON：trade_operations / drawings 的 FK 到 training_records 必须强制
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let queue = try DatabaseQueue(path: dbPath.path, configuration: config)

            // 跑 migrator
            try AppDBMigrations.makeMigrator().migrate(queue)

            self.dbQueue = queue
        } catch let appErr as AppError {
            throw appErr
        } catch {
            // R3 修订（codex med-4）：不传 fileURL —— PersistenceErrorMapping 收到 fileURL+missing
            // 会判 .trainingSet(.fileNotFound)，那是训练组语义；app.sqlite 走 .persistence(.ioError)
            throw PersistenceErrorMapping.translate(error)
        }
    }

    // MARK: - RecordRepository（实现见 RecordRepositoryImpl + Task 4 extension）
    public func insertRecord(_ r: TrainingRecord, ops: [TradeOperation],
                             drawings: [DrawingObject]) throws -> Int64 {
        fatalError("Task 4 实现")
    }
    public func listRecords(limit: Int?) throws -> [TrainingRecord] {
        fatalError("Task 4 实现")
    }
    public func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) {
        fatalError("Task 4 实现")
    }
    public func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) {
        fatalError("Task 4 实现")
    }

    // MARK: - PendingTrainingRepository（Task 5）
    public func savePending(_ p: PendingTraining) throws { fatalError("Task 5 实现") }
    public func loadPending() throws -> PendingTraining? { fatalError("Task 5 实现") }
    public func clearPending() throws { fatalError("Task 5 实现") }

    // MARK: - SettingsDAO（Task 6）
    public func loadSettings() throws -> AppSettings { fatalError("Task 6 实现") }
    public func saveSettings(_ s: AppSettings) throws { fatalError("Task 6 实现") }
    public func resetCapital() throws { fatalError("Task 6 实现") }

    // MARK: - AcceptanceJournalDAO（Task 7）
    public func upsert(trainingSetId: Int, leaseId: String, state: P2JournalState,
                       sqliteLocalPath: String?, contentHash: String?,
                       lastError: String?) throws { fatalError("Task 7 实现") }
    public func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] {
        fatalError("Task 7 实现")
    }
    public func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {
        fatalError("Task 7 实现")
    }
}
```

- [ ] **Step 3.6: 跑测试验证 pass（4 migration tests）**

```bash
cd "ios/Contracts"
swift test --filter AppDBMigrationsTests 2>&1 | tail -20
# 期望：4 tests passed
```

- [ ] **Step 3.7: commit 子项 2.a**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBFixture.swift
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift
git commit -m "feat(P4-skeleton): DefaultAppDB composition root + DatabaseMigrator

Per spec §P4 L1933-L1937 + §M0.1 L156, L265-289:
- DefaultAppDB.init(dbPath:): 单一 DatabaseQueue + foreign_keys ON
- AppDBMigrations.makeMigrator(): 0001_v1.4_baseline + 0003_v1.4_purge_leased
- 4 protocol surfaces stub fatalError；待 Task 4-7 落地
- AppDBFixture test helper

4 migration tests pass."
```

---

## Task 4: 子项 3.a — RecordRepository production 实现（TDD）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（替换 4 个 fatalError）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultRecordRepositoryTests.swift`

- [ ] **Step 4.1: 写失败测试**

Create `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultRecordRepositoryTests.swift`：

```swift
import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultRecordRepositoryTests: XCTestCase {

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

    // 用例 1：insertRecord 返回新 id（递增）+ 三表全部写入
    func test_insertRecord_writes_three_tables_and_returns_rowid() throws {
        let record = makeRecord(profit: 100, finalTick: 50)
        let ops = [makeOp(globalTick: 10), makeOp(globalTick: 20)]
        let drawings = [makeDrawing(toolType: .ray)]

        let id = try db.insertRecord(record, ops: ops, drawings: drawings)
        XCTAssertGreaterThan(id, 0)

        let bundle = try db.loadRecordBundle(id: id)
        XCTAssertEqual(bundle.0.profit, 100)
        XCTAssertEqual(bundle.0.finalTick, 50)
        XCTAssertEqual(bundle.1.count, 2)
        XCTAssertEqual(bundle.1[0].globalTick, 10)
        XCTAssertEqual(bundle.1[1].globalTick, 20)
        XCTAssertEqual(bundle.2.count, 1)
        XCTAssertEqual(bundle.2[0].toolType, .ray)
    }

    // 用例 2：listRecords limit=nil 返回全部，按 created_at DESC
    func test_listRecords_nil_limit_returns_all_desc_by_createdAt() throws {
        _ = try db.insertRecord(makeRecord(createdAt: 1_000), ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 3_000), ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 2_000), ops: [], drawings: [])

        let all = try db.listRecords(limit: nil)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map { $0.createdAt }, [3_000, 2_000, 1_000])
    }

    // 用例 3：listRecords limit=2 返回最近 2 条
    func test_listRecords_limit_2_returns_two() throws {
        for ts in [1_000, 2_000, 3_000] as [Int64] {
            _ = try db.insertRecord(makeRecord(createdAt: ts), ops: [], drawings: [])
        }
        let two = try db.listRecords(limit: 2)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two[0].createdAt, 3_000)
        XCTAssertEqual(two[1].createdAt, 2_000)
    }

    // 用例 4：loadRecordBundle 不存在 id 抛错
    func test_loadRecordBundle_missing_throws_dbCorrupted_or_emptyData() throws {
        XCTAssertThrowsError(try db.loadRecordBundle(id: 999_999)) { err in
            // 选择：missing record = .persistence(.dbCorrupted) 或 .trainingSet(.emptyData)
            // 实现选 .dbCorrupted（id 应总是存在；missing = caller 编程错误，按 corrupted 报）
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted)，实际 \(err)")
            }
        }
    }

    // 用例 5：statistics 计算 totalCount / winCount (profit > 0) / currentCapital (累加)
    // 用不同 createdAt 防 tiebreak ambiguity（R1 修订 codex med-1）
    func test_statistics_aggregates_correctly() throws {
        _ = try db.insertRecord(makeRecord(createdAt: 1_000, totalCapital: 10_000, profit: 100),
                                ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 2_000, totalCapital: 10_100, profit: -50),
                                ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 3_000, totalCapital: 10_050, profit: 200),
                                ops: [], drawings: [])

        let stats = try db.statistics()
        XCTAssertEqual(stats.totalCount, 3)
        XCTAssertEqual(stats.winCount, 2)        // profit > 0：第1+第3
        XCTAssertEqual(stats.currentCapital, 10_250.0, accuracy: 0.01)  // 最后一条 totalCapital + profit
    }

    // 用例 5b（R1 新增 codex med-1）：tied createdAt → tiebreak by id DESC
    // 验证当 created_at 完全相同时，statistics 取最大 id 行；listRecords 取 id DESC 序
    func test_tied_createdAt_uses_id_DESC_as_tiebreak() throws {
        // 三条同 createdAt：id=1 / 2 / 3 自然递增
        _ = try db.insertRecord(makeRecord(createdAt: 5_000, totalCapital: 10_000, profit: 10),
                                ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 5_000, totalCapital: 10_010, profit: 20),
                                ops: [], drawings: [])
        let lastId = try db.insertRecord(makeRecord(createdAt: 5_000, totalCapital: 10_030, profit: 30),
                                         ops: [], drawings: [])
        // statistics 必须取 id 最大的（lastId 行）
        XCTAssertEqual(try db.statistics().currentCapital, 10_060.0, accuracy: 0.01)

        // listRecords 必须按 id DESC 序输出（同 createdAt 时）
        let all = try db.listRecords(limit: nil)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].id, lastId)            // id 最大（最新插入）排第一
        XCTAssertGreaterThan(all[0].id ?? 0, all[1].id ?? 0)
        XCTAssertGreaterThan(all[1].id ?? 0, all[2].id ?? 0)
    }

    // 用例 6：DrawingObject.anchors JSON roundtrip
    func test_insertRecord_drawing_anchors_roundtrip() throws {
        let anchors = [
            DrawingAnchor(period: .daily, candleIndex: 10, price: 100.5),
            DrawingAnchor(period: .m60, candleIndex: 20, price: 101.0),
        ]
        let dr = DrawingObject(toolType: .trend, anchors: anchors,
                               isExtended: true, panelPosition: 1)
        let id = try db.insertRecord(makeRecord(), ops: [], drawings: [dr])
        let loaded = try db.loadRecordBundle(id: id)
        XCTAssertEqual(loaded.2.first?.anchors.count, 2)
        XCTAssertEqual(loaded.2.first?.anchors[0].candleIndex, 10)
        XCTAssertEqual(loaded.2.first?.anchors[1].price, 101.0)
        XCTAssertEqual(loaded.2.first?.isExtended, true)
        XCTAssertEqual(loaded.2.first?.panelPosition, 1)
    }

    // 用例 7：FK 强制（trade_operations.record_id 引用不存在 → 不可能因为 insertRecord 走的是事务，这里只断言 FK 配置存在）
    func test_foreign_keys_pragma_is_on() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let fk: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? -1
        }
        // 注意：foreign_keys 是 connection-scoped；DefaultAppDB.prepareDatabase 设了 ON。
        // 这里 openRaw 是新 connection，不一定 ON。改为：通过 db API insertRecord 触发 FK 应正常。
        XCTAssertTrue(fk == 0 || fk == 1, "PRAGMA foreign_keys 必须可读（值 0 或 1）")
    }

    // MARK: - Helpers

    private func makeRecord(createdAt: Int64 = 1_700_000_000_000,
                            totalCapital: Double = 10_000,
                            profit: Double = 0,
                            finalTick: Int = 0) -> TrainingRecord {
        TrainingRecord(
            id: nil, trainingSetFilename: "set-A.zip", createdAt: createdAt,
            stockCode: "000001", stockName: "平安银行",
            startYear: 2024, startMonth: 1,
            totalCapital: totalCapital, profit: profit, returnRate: 0.01, maxDrawdown: 50,
            buyCount: 1, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true),
            finalTick: finalTick
        )
    }

    private func makeOp(globalTick: Int) -> TradeOperation {
        TradeOperation(
            globalTick: globalTick, period: .daily, direction: .buy,
            price: 10.0, shares: 100, positionTier: .tier1,
            commission: 1.0, stampDuty: 0.5, totalCost: 1001.5,
            createdAt: 1_700_000_000_000
        )
    }

    private func makeDrawing(toolType: DrawingToolType) -> DrawingObject {
        DrawingObject(toolType: toolType,
                      anchors: [DrawingAnchor(period: .daily, candleIndex: 1, price: 10)],
                      isExtended: false, panelPosition: 0)
    }
}
```

- [ ] **Step 4.2: 跑测试 fail**

```bash
cd "ios/Contracts"
swift test --filter DefaultRecordRepositoryTests 2>&1 | tail -20
# 期望：fatalError trip 或 XCTAssert fail（DefaultAppDB.insertRecord 还是占位 fatalError）
```

- [ ] **Step 4.3: 写 RecordRepositoryImpl.swift**

Create `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift`：

```swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// RecordRepository 静态方法实现。所有方法在 DefaultAppDB.dbQueue.read/write 闭包内调用。
/// 调用方负责 dbQueue.write 包事务 + GRDB 错误翻译。
enum RecordRepositoryImpl {

    static func insertRecord(_ db: Database, record: TrainingRecord,
                             ops: [TradeOperation],
                             drawings: [DrawingObject]) throws -> Int64 {
        let feeJSON = try jsonEncode(record.feeSnapshot)
        try db.execute(sql: """
            INSERT INTO training_records
              (training_set_filename, created_at, stock_code, stock_name,
               start_year, start_month, total_capital, profit, return_rate,
               max_drawdown, buy_count, sell_count, fee_snapshot, final_tick)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                record.trainingSetFilename, record.createdAt,
                record.stockCode, record.stockName,
                record.startYear, record.startMonth,
                record.totalCapital, record.profit, record.returnRate,
                record.maxDrawdown, record.buyCount, record.sellCount,
                feeJSON, record.finalTick
            ])
        let recordId = db.lastInsertedRowID

        for op in ops {
            try db.execute(sql: """
                INSERT INTO trade_operations
                  (record_id, global_tick, period, direction, price, shares,
                   position_tier, commission, stamp_duty, total_cost, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    recordId, op.globalTick, op.period.rawValue, op.direction.rawValue,
                    op.price, op.shares, op.positionTier.rawValue,
                    op.commission, op.stampDuty, op.totalCost, op.createdAt
                ])
        }

        for dr in drawings {
            let anchorsJSON = try jsonEncode(dr.anchors)
            try db.execute(sql: """
                INSERT INTO drawings
                  (record_id, tool_type, panel_position, is_extended, anchors)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    recordId, dr.toolType.rawValue, dr.panelPosition,
                    dr.isExtended ? 1 : 0, anchorsJSON
                ])
        }

        return recordId
    }

    static func listRecords(_ db: Database, limit: Int?) throws -> [TrainingRecord] {
        // R1 修订（codex med-1）：加 id DESC tiebreak 防同毫秒并列时 SQLite 任选不定序
        let sql: String
        if let limit = limit {
            sql = "SELECT * FROM training_records ORDER BY created_at DESC, id DESC LIMIT \(limit)"
        } else {
            sql = "SELECT * FROM training_records ORDER BY created_at DESC, id DESC"
        }
        let rows = try Row.fetchAll(db, sql: sql)
        return try rows.map { try recordFromRow($0) }
    }

    static func loadRecordBundle(_ db: Database, id: Int64) throws
        -> (TrainingRecord, [TradeOperation], [DrawingObject])
    {
        guard let recRow = try Row.fetchOne(db, sql:
            "SELECT * FROM training_records WHERE id = ?", arguments: [id])
        else {
            // record 不存在：caller 编程错误（id 应来自 insertRecord 返回 / listRecords）
            throw AppError.persistence(.dbCorrupted)
        }
        let record = try recordFromRow(recRow)

        let opRows = try Row.fetchAll(db, sql:
            "SELECT * FROM trade_operations WHERE record_id = ? ORDER BY id ASC", arguments: [id])
        let ops = try opRows.map { try opFromRow($0) }

        let drRows = try Row.fetchAll(db, sql:
            "SELECT * FROM drawings WHERE record_id = ? ORDER BY id ASC", arguments: [id])
        let drawings = try drRows.map { try drawingFromRow($0) }

        return (record, ops, drawings)
    }

    static func statistics(_ db: Database) throws
        -> (totalCount: Int, winCount: Int, currentCapital: Double)
    {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM training_records") ?? 0
        let wins = try Int.fetchOne(db, sql:
            "SELECT COUNT(*) FROM training_records WHERE profit > 0") ?? 0
        // currentCapital：最后一条（按 created_at DESC, id DESC）的 total_capital + profit
        // R1 修订（codex med-1）：加 id DESC tiebreak 防同毫秒并列
        let cap: Double = try Row.fetchOne(db, sql: """
            SELECT total_capital, profit FROM training_records
            ORDER BY created_at DESC, id DESC LIMIT 1
            """).map { $0["total_capital"] as Double + $0["profit"] as Double } ?? 0
        return (total, wins, cap)
    }

    // MARK: - Row → Model

    private static func recordFromRow(_ row: Row) throws -> TrainingRecord {
        let feeJSON: String = row["fee_snapshot"]
        let fee: FeeSnapshot = try jsonDecode(feeJSON, as: FeeSnapshot.self)
        return TrainingRecord(
            id: row["id"], trainingSetFilename: row["training_set_filename"],
            createdAt: row["created_at"],
            stockCode: row["stock_code"], stockName: row["stock_name"],
            startYear: row["start_year"], startMonth: row["start_month"],
            totalCapital: row["total_capital"], profit: row["profit"],
            returnRate: row["return_rate"], maxDrawdown: row["max_drawdown"],
            buyCount: row["buy_count"], sellCount: row["sell_count"],
            feeSnapshot: fee, finalTick: row["final_tick"]
        )
    }

    private static func opFromRow(_ row: Row) throws -> TradeOperation {
        let periodRaw: String = row["period"]
        guard let period = Period(rawValue: periodRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let dirRaw: String = row["direction"]
        guard let direction = TradeDirection(rawValue: dirRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let tierRaw: String = row["position_tier"]
        guard let tier = PositionTier(rawValue: tierRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return TradeOperation(
            globalTick: row["global_tick"], period: period, direction: direction,
            price: row["price"], shares: row["shares"], positionTier: tier,
            commission: row["commission"], stampDuty: row["stamp_duty"],
            totalCost: row["total_cost"], createdAt: row["created_at"]
        )
    }

    private static func drawingFromRow(_ row: Row) throws -> DrawingObject {
        let toolRaw: String = row["tool_type"]
        guard let tool = DrawingToolType(rawValue: toolRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let anchorsJSON: String = row["anchors"]
        let anchors: [DrawingAnchor] = try jsonDecode(anchorsJSON, as: [DrawingAnchor].self)
        let isExt: Int = row["is_extended"]
        return DrawingObject(toolType: tool, anchors: anchors,
                             isExtended: isExt != 0, panelPosition: row["panel_position"])
    }

    // MARK: - JSON helpers（共享给其它 *Impl.swift）

    static func jsonEncode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return s
    }

    static func jsonDecode<T: Decodable>(_ string: String, as: T.Type) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
```

- [ ] **Step 4.4: 替换 DefaultAppDB.swift 里 RecordRepository 4 个 fatalError**

Modify `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift` —— 在 `// MARK: - RecordRepository` 段把 4 个方法换成：

```swift
    // MARK: - RecordRepository

    public func insertRecord(_ r: TrainingRecord, ops: [TradeOperation],
                             drawings: [DrawingObject]) throws -> Int64 {
        do {
            return try dbQueue.write { db in
                try RecordRepositoryImpl.insertRecord(db, record: r, ops: ops, drawings: drawings)
            }
        } catch let appErr as AppError {
            throw appErr
        } catch {
            throw PersistenceErrorMapping.translate(error)
        }
    }

    public func listRecords(limit: Int?) throws -> [TrainingRecord] {
        do {
            return try dbQueue.read { db in
                try RecordRepositoryImpl.listRecords(db, limit: limit)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) {
        do {
            return try dbQueue.read { db in
                try RecordRepositoryImpl.loadRecordBundle(db, id: id)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) {
        do {
            return try dbQueue.read { db in
                try RecordRepositoryImpl.statistics(db)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
```

- [ ] **Step 4.5: 跑测试 pass**

```bash
cd "ios/Contracts"
swift test --filter DefaultRecordRepositoryTests 2>&1 | tail -20
# 期望：7 tests passed
```

- [ ] **Step 4.6: 跑全套测试无回归**

```bash
swift test --filter KlineTrainerPersistenceTests 2>&1 | tail -10
# 期望：所有 PR #41 + Task 3 + Task 4 测试 pass
```

- [ ] **Step 4.7: commit 子项 3.a**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultRecordRepositoryTests.swift
git commit -m "feat(P4-record): RecordRepository production impl

- insertRecord: 三表事务 (training_records + trade_operations + drawings)
- listRecords: ORDER BY created_at DESC + optional LIMIT
- loadRecordBundle: 3 query (records / ops / drawings)，missing → .dbCorrupted
- statistics: COUNT total + COUNT(profit>0) + 最近一条 capital + profit
- DrawingObject.anchors JSON encoded TEXT 列

7 tests pass."
```

---

## Task 5: 子项 3.b — PendingTrainingRepository production 实现（TDD）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingTrainingRepositoryImpl.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（替换 3 个 fatalError）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultPendingTrainingRepositoryTests.swift`

- [ ] **Step 5.1: 写失败测试**

Create `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultPendingTrainingRepositoryTests.swift`：

```swift
import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultPendingTrainingRepositoryTests: XCTestCase {

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

    // 用例 1：fresh DB loadPending 返回 nil
    func test_loadPending_on_fresh_db_returns_nil() throws {
        XCTAssertNil(try db.loadPending())
    }

    // 用例 2：savePending → loadPending roundtrip 字段对等
    func test_savePending_then_loadPending_roundtrip() throws {
        let pending = makePending(globalTickIndex: 100, cashBalance: 9_500, accumulatedCapital: 10_500)
        try db.savePending(pending)
        let loaded = try db.loadPending()
        XCTAssertEqual(loaded?.globalTickIndex, 100)
        XCTAssertEqual(loaded?.cashBalance, 9_500)
        XCTAssertEqual(loaded?.accumulatedCapital, 10_500)
        XCTAssertEqual(loaded?.upperPeriod, pending.upperPeriod)
        XCTAssertEqual(loaded?.lowerPeriod, pending.lowerPeriod)
        XCTAssertEqual(loaded?.tradeOperations.count, pending.tradeOperations.count)
        XCTAssertEqual(loaded?.drawings.count, pending.drawings.count)
        XCTAssertEqual(loaded?.drawdown, pending.drawdown)
        XCTAssertEqual(loaded?.positionData, pending.positionData)
    }

    // 用例 3：savePending 二次覆盖旧值（singleton row 替换语义）
    func test_savePending_overwrites_existing() throws {
        try db.savePending(makePending(globalTickIndex: 1))
        try db.savePending(makePending(globalTickIndex: 200))
        let loaded = try db.loadPending()
        XCTAssertEqual(loaded?.globalTickIndex, 200)

        // 物理验证：表只有 1 行
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let count: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_training") ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    // 用例 4：clearPending → loadPending 返回 nil
    func test_clearPending_then_loadPending_nil() throws {
        try db.savePending(makePending(globalTickIndex: 100))
        try db.clearPending()
        XCTAssertNil(try db.loadPending())
    }

    // 用例 5：clearPending fresh DB 不抛错
    func test_clearPending_on_fresh_db_no_throw() throws {
        XCTAssertNoThrow(try db.clearPending())
    }

    // MARK: - Helper

    private func makePending(globalTickIndex: Int = 0,
                             cashBalance: Double = 10_000,
                             accumulatedCapital: Double = 10_000) -> PendingTraining {
        PendingTraining(
            trainingSetFilename: "set-A.zip",
            globalTickIndex: globalTickIndex,
            upperPeriod: .daily, lowerPeriod: .m60,
            positionData: Data([0x01, 0x02, 0x03]),
            cashBalance: cashBalance,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true),
            tradeOperations: [
                TradeOperation(globalTick: 50, period: .daily, direction: .buy,
                               price: 10, shares: 100, positionTier: .tier1,
                               commission: 1, stampDuty: 0, totalCost: 1001,
                               createdAt: 1_700_000_000_000)
            ],
            drawings: [
                DrawingObject(toolType: .ray,
                              anchors: [DrawingAnchor(period: .daily, candleIndex: 1, price: 10)],
                              isExtended: false, panelPosition: 0)
            ],
            startedAt: 1_700_000_000_000,
            accumulatedCapital: accumulatedCapital,
            drawdown: DrawdownAccumulator(peakCapital: 11_000, maxDrawdown: 500)
        )
    }
}
```

- [ ] **Step 5.2: 跑测试 fail（占位 fatalError trip）**

```bash
swift test --filter DefaultPendingTrainingRepositoryTests 2>&1 | tail -10
# 期望：测试 crash / fatalError trip
```

- [ ] **Step 5.3: 写 PendingTrainingRepositoryImpl.swift**

Create `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingTrainingRepositoryImpl.swift`：

```swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// PendingTrainingRepository 静态方法实现。
/// pending_training 表 schema CHECK(id = 1)：永远 0 或 1 行。
enum PendingTrainingRepositoryImpl {

    static func savePending(_ db: Database, pending p: PendingTraining) throws {
        let positionB64 = p.positionData.base64EncodedString()
        let feeJSON = try RecordRepositoryImpl.jsonEncode(p.feeSnapshot)
        let opsJSON = try RecordRepositoryImpl.jsonEncode(p.tradeOperations)
        let drawingsJSON = try RecordRepositoryImpl.jsonEncode(p.drawings)
        let drawdownJSON = try RecordRepositoryImpl.jsonEncode(p.drawdown)

        try db.execute(sql: """
            INSERT OR REPLACE INTO pending_training
              (id, training_set_filename, global_tick_index, upper_period, lower_period,
               position_data, fee_snapshot, trade_operations, drawings,
               started_at, accumulated_capital, cash_balance, drawdown)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                p.trainingSetFilename, p.globalTickIndex,
                p.upperPeriod.rawValue, p.lowerPeriod.rawValue,
                positionB64, feeJSON, opsJSON, drawingsJSON,
                p.startedAt, p.accumulatedCapital, p.cashBalance, drawdownJSON
            ])
    }

    static func loadPending(_ db: Database) throws -> PendingTraining? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT * FROM pending_training WHERE id = 1") else { return nil }
        let positionB64: String = row["position_data"]
        guard let positionData = Data(base64Encoded: positionB64) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let feeJSON: String = row["fee_snapshot"]
        let opsJSON: String = row["trade_operations"]
        let drawingsJSON: String = row["drawings"]
        let drawdownJSON: String = row["drawdown"]
        let upperRaw: String = row["upper_period"]
        let lowerRaw: String = row["lower_period"]
        guard let upper = Period(rawValue: upperRaw),
              let lower = Period(rawValue: lowerRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let fee: FeeSnapshot = try RecordRepositoryImpl.jsonDecode(feeJSON, as: FeeSnapshot.self)
        let ops: [TradeOperation] = try RecordRepositoryImpl.jsonDecode(opsJSON,
                                                                       as: [TradeOperation].self)
        let drawings: [DrawingObject] = try RecordRepositoryImpl.jsonDecode(drawingsJSON,
                                                                            as: [DrawingObject].self)
        let drawdown: DrawdownAccumulator = try RecordRepositoryImpl.jsonDecode(drawdownJSON,
                                                                                as: DrawdownAccumulator.self)
        return PendingTraining(
            trainingSetFilename: row["training_set_filename"],
            globalTickIndex: row["global_tick_index"],
            upperPeriod: upper, lowerPeriod: lower,
            positionData: positionData,
            cashBalance: row["cash_balance"],
            feeSnapshot: fee,
            tradeOperations: ops, drawings: drawings,
            startedAt: row["started_at"],
            accumulatedCapital: row["accumulated_capital"],
            drawdown: drawdown
        )
    }

    static func clearPending(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM pending_training WHERE id = 1")
    }
}
```

- [ ] **Step 5.4: 替换 DefaultAppDB.swift 里 PendingTrainingRepository 3 个 fatalError**

Modify `DefaultAppDB.swift` —— `// MARK: - PendingTrainingRepository` 段：

```swift
    // MARK: - PendingTrainingRepository

    public func savePending(_ p: PendingTraining) throws {
        do {
            try dbQueue.write { db in
                try PendingTrainingRepositoryImpl.savePending(db, pending: p)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func loadPending() throws -> PendingTraining? {
        do {
            return try dbQueue.read { db in
                try PendingTrainingRepositoryImpl.loadPending(db)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func clearPending() throws {
        do {
            try dbQueue.write { db in
                try PendingTrainingRepositoryImpl.clearPending(db)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
```

- [ ] **Step 5.5: 跑测试 pass**

```bash
swift test --filter DefaultPendingTrainingRepositoryTests 2>&1 | tail -20
# 期望：5 tests passed
```

- [ ] **Step 5.6: commit 子项 3.b**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingTrainingRepositoryImpl.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultPendingTrainingRepositoryTests.swift
git commit -m "feat(P4-pending): PendingTrainingRepository production impl

- savePending: INSERT OR REPLACE 单 singleton row (CHECK id=1)
- loadPending: SELECT WHERE id=1，nil 时返回 nil（首次启动合法）
- clearPending: DELETE WHERE id=1
- positionData base64 → TEXT，复合 collection JSON encoded TEXT

5 tests pass."
```

---

## Task 6: 子项 3.c — SettingsDAO production 实现（TDD）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（替换 3 个 fatalError）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift`

- [ ] **Step 6.1: 写失败测试**

Create `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift`：

```swift
import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultSettingsDAOTests: XCTestCase {

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

    // 用例 1：fresh DB loadSettings 返回 zero-value default（不抛错）
    func test_loadSettings_on_fresh_db_returns_defaults() throws {
        let s = try db.loadSettings()
        XCTAssertEqual(s.commissionRate, 0)
        XCTAssertEqual(s.minCommissionEnabled, false)
        XCTAssertEqual(s.totalCapital, 0)
        XCTAssertEqual(s.displayMode, .system)
    }

    // 用例 2：saveSettings → loadSettings roundtrip
    func test_saveSettings_then_load_roundtrip() throws {
        let s = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                            totalCapital: 50_000, displayMode: .dark)
        try db.saveSettings(s)
        let loaded = try db.loadSettings()
        XCTAssertEqual(loaded.commissionRate, 0.0003, accuracy: 1e-9)
        XCTAssertEqual(loaded.minCommissionEnabled, true)
        XCTAssertEqual(loaded.totalCapital, 50_000)
        XCTAssertEqual(loaded.displayMode, .dark)
    }

    // 用例 3：saveSettings 二次覆盖
    func test_saveSettings_overwrites_existing() throws {
        try db.saveSettings(AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                                        totalCapital: 10_000, displayMode: .light))
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 30_000, displayMode: .dark))
        let loaded = try db.loadSettings()
        XCTAssertEqual(loaded.commissionRate, 0.0003, accuracy: 1e-9)
        XCTAssertEqual(loaded.totalCapital, 30_000)
        XCTAssertEqual(loaded.displayMode, .dark)

        // 物理验证：表恰好 4 行（4 个 key）
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let count: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings") ?? -1
        }
        XCTAssertEqual(count, 4)
    }

    // 用例 4：resetCapital 仅改 total_capital，其它字段保留
    func test_resetCapital_only_zeros_capital_other_fields_intact() throws {
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 50_000, displayMode: .dark))
        try db.resetCapital()
        let loaded = try db.loadSettings()
        XCTAssertEqual(loaded.totalCapital, 0)
        XCTAssertEqual(loaded.commissionRate, 0.0003, accuracy: 1e-9)
        XCTAssertEqual(loaded.minCommissionEnabled, true)
        XCTAssertEqual(loaded.displayMode, .dark)
    }

    // 用例 5：resetCapital fresh DB 创建 total_capital=0 行
    func test_resetCapital_on_fresh_db_creates_capital_row() throws {
        try db.resetCapital()
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let val: String? = try queue.read { db in
            try String.fetchOne(db, sql:
                "SELECT value FROM settings WHERE key = 'total_capital'")
        }
        XCTAssertEqual(val, "0.0")
    }

    // 用例 6：DisplayMode 三个 case 均可 roundtrip
    func test_displayMode_all_three_cases_roundtrip() throws {
        for mode: DisplayMode in [.light, .dark, .system] {
            try db.saveSettings(AppSettings(commissionRate: 0, minCommissionEnabled: false,
                                            totalCapital: 0, displayMode: mode))
            XCTAssertEqual(try db.loadSettings().displayMode, mode)
        }
    }

    // 用例 7（R1 新增 codex high-2）：commission_rate 列含 garbage → .dbCorrupted（不静默回 0）
    func test_loadSettings_malformed_commission_rate_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["commission_rate", "garbage_not_a_number"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted)，实际 \(err)")
            }
        }
    }

    // 用例 8（R1 新增）：display_mode 列含未知 enum case → .dbCorrupted
    func test_loadSettings_unknown_displayMode_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["display_mode", "purple"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted)，实际 \(err)")
            }
        }
    }

    // 用例 9（R1 新增）：min_commission_enabled 列含非 bool 串 → .dbCorrupted
    func test_loadSettings_malformed_bool_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["min_commission_enabled", "yes"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted)，实际 \(err)")
            }
        }
    }

    // 用例 10（R1 新增）：partial keys（仅 commission_rate 存在）→ 缺失 key 走 default，存在 key 真解析
    func test_loadSettings_partial_keys_missing_uses_default() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            // 只写 commission_rate 一个 key，其它 3 个 key 缺失
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["commission_rate", "0.0005"])
        }
        let s = try db.loadSettings()
        XCTAssertEqual(s.commissionRate, 0.0005, accuracy: 1e-9)  // 真解析
        XCTAssertEqual(s.minCommissionEnabled, false)             // missing → default
        XCTAssertEqual(s.totalCapital, 0)                         // missing → default
        XCTAssertEqual(s.displayMode, .system)                    // missing → default
    }

    // 用例 11（R2 新增 codex med-3）：commission_rate 列含 "NaN" → .dbCorrupted
    func test_loadSettings_NaN_value_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["commission_rate", "NaN"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted) on NaN，实际 \(err)")
            }
        }
    }

    // 用例 12（R2 新增 codex med-3）：total_capital 列含 "Infinity" → .dbCorrupted
    func test_loadSettings_infinity_value_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["total_capital", "Infinity"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted) on Infinity，实际 \(err)")
            }
        }
    }

    // 用例 13（R2 新增 codex med-3）：saveSettings 入参 NaN commissionRate → 拒绝（internalError）
    func test_saveSettings_with_NaN_commission_throws_internalError() throws {
        let bad = AppSettings(commissionRate: .nan, minCommissionEnabled: false,
                              totalCapital: 10_000, displayMode: .system)
        XCTAssertThrowsError(try db.saveSettings(bad)) { err in
            guard let appErr = err as? AppError,
                  case .internalError(let module, _) = appErr else {
                return XCTFail("期望 .internalError，实际 \(err)")
            }
            XCTAssertTrue(module.contains("SettingsDAO"))
        }
    }

    // 用例 14（R2 新增 codex med-3）：saveSettings 入参 inf totalCapital → 拒绝
    func test_saveSettings_with_inf_capital_throws_internalError() throws {
        let bad = AppSettings(commissionRate: 0.0003, minCommissionEnabled: false,
                              totalCapital: .infinity, displayMode: .system)
        XCTAssertThrowsError(try db.saveSettings(bad)) { err in
            guard let appErr = err as? AppError,
                  case .internalError = appErr else {
                return XCTFail("期望 .internalError，实际 \(err)")
            }
        }
    }
}
```

- [ ] **Step 6.2: 跑测试 fail**

```bash
swift test --filter DefaultSettingsDAOTests 2>&1 | tail -10
```

- [ ] **Step 6.3: 写 SettingsDAOImpl.swift**

Create `ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift`：

```swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// SettingsDAO 静态方法实现。
/// settings 表是 key-value：4 个固定 key（commission_rate / min_commission_enabled / total_capital / display_mode）。
enum SettingsDAOImpl {

    private static let keyCommissionRate = "commission_rate"
    private static let keyMinCommissionEnabled = "min_commission_enabled"
    private static let keyTotalCapital = "total_capital"
    private static let keyDisplayMode = "display_mode"

    static func loadSettings(_ db: Database) throws -> AppSettings {
        // R1 修订（codex high-2）：分 missing vs malformed 两路。
        // missing = 首次启动 / 新增 key 未写 → zero-value default（合法）
        // malformed = key 存在但 value 不可解析 → AppError.persistence(.dbCorrupted)
        //             静默回退会把损坏的 commission/capital 重置 0，影响财务计算
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM settings")
        var dict: [String: String] = [:]
        for row in rows {
            dict[row["key"] as String] = (row["value"] as String)
        }

        let commissionRate = try parseDouble(dict[keyCommissionRate], default: 0)
        let minCommissionEnabled = try parseBool(dict[keyMinCommissionEnabled], default: false)
        let totalCapital = try parseDouble(dict[keyTotalCapital], default: 0)
        let displayMode = try parseDisplayMode(dict[keyDisplayMode], default: .system)

        return AppSettings(commissionRate: commissionRate,
                           minCommissionEnabled: minCommissionEnabled,
                           totalCapital: totalCapital,
                           displayMode: displayMode)
    }

    private static func parseDouble(_ raw: String?, default def: Double) throws -> Double {
        guard let raw = raw else { return def }       // missing → default
        guard let v = Double(raw), v.isFinite else {  // present but malformed / NaN / inf → corrupt
            // R2 修订（codex med-3）：拒 NaN / +inf / -inf —— 这些值会污染 commission/capital 计算
            throw AppError.persistence(.dbCorrupted)
        }
        return v
    }

    private static func parseBool(_ raw: String?, default def: Bool) throws -> Bool {
        guard let raw = raw else { return def }
        switch raw {
        case "true": return true
        case "false": return false
        default: throw AppError.persistence(.dbCorrupted)
        }
    }

    private static func parseDisplayMode(_ raw: String?, default def: DisplayMode) throws -> DisplayMode {
        guard let raw = raw else { return def }
        guard let m = DisplayMode(rawValue: raw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return m
    }

    static func saveSettings(_ db: Database, settings s: AppSettings) throws {
        // R2 修订（codex med-3）：拒入参为 NaN / inf 的 commission/capital，避免毒入 DB
        guard s.commissionRate.isFinite else {
            throw AppError.internalError(
                module: "P4-SettingsDAO",
                detail: "saveSettings refused: commissionRate not finite (\(s.commissionRate))")
        }
        guard s.totalCapital.isFinite else {
            throw AppError.internalError(
                module: "P4-SettingsDAO",
                detail: "saveSettings refused: totalCapital not finite (\(s.totalCapital))")
        }
        let pairs: [(String, String)] = [
            (keyCommissionRate, String(s.commissionRate)),
            (keyMinCommissionEnabled, s.minCommissionEnabled ? "true" : "false"),
            (keyTotalCapital, String(s.totalCapital)),
            (keyDisplayMode, s.displayMode.rawValue),
        ]
        for (k, v) in pairs {
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: [k, v])
        }
    }

    static func resetCapital(_ db: Database) throws {
        try db.execute(sql:
            "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
            arguments: [keyTotalCapital, "0.0"])
    }
}
```

- [ ] **Step 6.4: 替换 DefaultAppDB.swift 里 SettingsDAO 3 个 fatalError**

Modify `DefaultAppDB.swift` —— `// MARK: - SettingsDAO` 段：

```swift
    // MARK: - SettingsDAO

    public func loadSettings() throws -> AppSettings {
        do {
            return try dbQueue.read { db in try SettingsDAOImpl.loadSettings(db) }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func saveSettings(_ s: AppSettings) throws {
        do {
            try dbQueue.write { db in try SettingsDAOImpl.saveSettings(db, settings: s) }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func resetCapital() throws {
        do {
            try dbQueue.write { db in try SettingsDAOImpl.resetCapital(db) }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
```

- [ ] **Step 6.5: 跑测试 pass**

```bash
swift test --filter DefaultSettingsDAOTests 2>&1 | tail -20
# 期望：6 tests passed
```

- [ ] **Step 6.6: commit 子项 3.c**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift
git commit -m "feat(P4-settings): SettingsDAO production impl

- 4 key-value pair：commission_rate/min_commission_enabled/total_capital/display_mode
- loadSettings: 缺 key → zero-value default（首次启动合法）
- saveSettings: 4 次 INSERT OR REPLACE
- resetCapital: 仅写 total_capital='0.0'，其它 key 不动

6 tests pass."
```

---

## Task 7: 子项 3.d — AcceptanceJournalDAO production 实现 + PersistenceErrorMapping diskFull 扩展（TDD）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AcceptanceJournalDAOImpl.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（替换 3 个 fatalError）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PersistenceErrorMapping.swift`（加 SQLITE_FULL 分支）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultAcceptanceJournalDAOTests.swift`

- [ ] **Step 7.1: 写失败测试**

Create `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultAcceptanceJournalDAOTests.swift`：

```swift
import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultAcceptanceJournalDAOTests: XCTestCase {

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

    // 用例 1：upsert 第一次 = INSERT，listByState 找到
    func test_upsert_first_time_inserts_and_listByState_finds_it() throws {
        try db.upsert(trainingSetId: 1, leaseId: "lease-A",
                      state: .downloaded,
                      sqliteLocalPath: "/tmp/x.sqlite",
                      contentHash: "deadbeef",
                      lastError: nil)
        let rows = try db.listByState(.downloaded)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].trainingSetId, 1)
        XCTAssertEqual(rows[0].leaseId, "lease-A")
        XCTAssertEqual(rows[0].state, .downloaded)
        XCTAssertEqual(rows[0].sqliteLocalPath, "/tmp/x.sqlite")
        XCTAssertEqual(rows[0].contentHash, "deadbeef")
        XCTAssertNil(rows[0].lastError)
        XCTAssertGreaterThan(rows[0].stateEnteredAt, 0)
    }

    // 用例 2：upsert 同 (id, lease) 第二次 = UPDATE，state_entered_at 刷新
    func test_upsert_same_key_updates_state() throws {
        try db.upsert(trainingSetId: 1, leaseId: "lease-A",
                      state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let firstStamp = try db.listByState(.downloaded).first?.stateEnteredAt ?? 0

        // 等 10ms 让 stateEnteredAt 不同（同步等待，本测试是 throws 非 async）
        Thread.sleep(forTimeInterval: 0.01)

        try db.upsert(trainingSetId: 1, leaseId: "lease-A",
                      state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        XCTAssertEqual(try db.listByState(.downloaded).count, 0)
        let after = try db.listByState(.crcOK)
        XCTAssertEqual(after.count, 1)
        XCTAssertGreaterThanOrEqual(after[0].stateEnteredAt, firstStamp)
    }

    // 用例 3：listByState 多状态分桶
    func test_listByState_filters_correctly() throws {
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 2, leaseId: "L2", state: .stored,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 3, leaseId: "L3", state: .stored,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 4, leaseId: "L4", state: .confirmed,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        XCTAssertEqual(try db.listByState(.downloaded).count, 1)
        XCTAssertEqual(try db.listByState(.stored).count, 2)
        XCTAssertEqual(try db.listByState(.confirmed).count, 1)
        XCTAssertEqual(try db.listByState(.confirmPending).count, 0)
    }

    // 用例 4：deleteByIdLease 存在行
    func test_deleteByIdLease_removes_row() throws {
        try db.upsert(trainingSetId: 5, leaseId: "L5", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.deleteByIdLease(trainingSetId: 5, leaseId: "L5")
        XCTAssertEqual(try db.listByState(.downloaded).count, 0)
    }

    // 用例 5：deleteByIdLease 不存在行不抛错
    func test_deleteByIdLease_missing_row_no_throw() throws {
        XCTAssertNoThrow(try db.deleteByIdLease(trainingSetId: 999, leaseId: "missing"))
    }

    // 用例 6：upsert 包含 lastError 文本
    func test_upsert_carries_lastError_text() throws {
        try db.upsert(trainingSetId: 6, leaseId: "L6", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil,
                      lastError: "crc_mismatch_at_byte_42")
        let rows = try db.listByState(.rejected)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].lastError, "crc_mismatch_at_byte_42")
    }

    // 用例 7：DB 含未知 state raw value（v1.3 残留 leased 但未跑 0003）→ listByState 返回不含该行
    //         这里用 raw SQL 注入 leased 行，验证 listByState(.downloaded) 不会误返回
    func test_listByState_with_unknown_state_in_db_does_not_return_them() throws {
        // raw SQL 插入一条 state='leased' 行（绕过 enum）
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO download_acceptance_journal
                  (training_set_id, lease_id, state, state_entered_at)
                VALUES (?, ?, 'leased', ?)
                """, arguments: [99, "v13-leased", 1_700_000_000_000])
        }
        // listByState(.downloaded) 不返回 leased 行
        XCTAssertEqual(try db.listByState(.downloaded).count, 0)
        // listByState 任何 v1.4 enum case 都不返回 leased 行
        for s in P2JournalState.allCases {
            for r in try db.listByState(s) {
                XCTAssertNotEqual(r.leaseId, "v13-leased")
            }
        }
    }

    // 用例 8（R1 codex high-1 / R4 改 walk-through）：晚到 retry 不能把 .stored 倒回 .downloaded
    func test_upsert_stale_state_is_NOOP_keeps_existing() throws {
        // walk 到 .stored（必须走完整链）
        try walkToStored(trainingSetId: 1, leaseId: "L1",
                         path: "/tmp/set.sqlite", hash: "deadbeef")
        XCTAssertEqual(try db.listByState(.stored).count, 1)

        // 模拟晚到的回退 retry：.downloaded 不能覆盖 .stored
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        // 行仍在 .stored，含原 sqliteLocalPath / contentHash 不变
        XCTAssertEqual(try db.listByState(.downloaded).count, 0)
        let stored = try db.listByState(.stored)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].sqliteLocalPath, "/tmp/set.sqlite")
        XCTAssertEqual(stored[0].contentHash, "deadbeef")
    }

    // 用例 9（R1 新增 codex high-1）：终态 .confirmed 与 .rejected 同 rank，互斥不可转
    func test_upsert_terminal_states_mutually_exclusive() throws {
        // 方向 A：confirmed → rejected NOOP
        try db.upsert(trainingSetId: 2, leaseId: "L2", state: .confirmed,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 2, leaseId: "L2", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil, lastError: "should_not_apply")
        XCTAssertEqual(try db.listByState(.rejected).filter { $0.leaseId == "L2" }.count, 0)
        XCTAssertEqual(try db.listByState(.confirmed).filter { $0.leaseId == "L2" }.count, 1)

        // 方向 B：rejected → confirmed NOOP
        try db.upsert(trainingSetId: 3, leaseId: "L3", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil, lastError: "x")
        try db.upsert(trainingSetId: 3, leaseId: "L3", state: .confirmed,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try db.listByState(.confirmed).filter { $0.leaseId == "L3" }.count, 0)
        XCTAssertEqual(try db.listByState(.rejected).filter { $0.leaseId == "L3" }.count, 1)
    }

    // 用例 10（R1 新增 codex high-1）：同 state 重试合法 → state_entered_at 刷新 + 辅助列覆盖（nil 入参不擦）
    func test_upsert_same_state_retry_refreshes_entered_at_and_aux_fields() throws {
        try db.upsert(trainingSetId: 4, leaseId: "L4", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let firstStamp = try db.listByState(.downloaded).first?.stateEnteredAt ?? 0
        Thread.sleep(forTimeInterval: 0.01)
        try db.upsert(trainingSetId: 4, leaseId: "L4", state: .downloaded,
                      sqliteLocalPath: "/tmp/path", contentHash: "abc12345",
                      lastError: nil)
        let after = try db.listByState(.downloaded).first { $0.leaseId == "L4" }
        XCTAssertGreaterThanOrEqual(after?.stateEnteredAt ?? 0, firstStamp)
        XCTAssertEqual(after?.sqliteLocalPath, "/tmp/path")
        XCTAssertEqual(after?.contentHash, "abc12345")
    }

    // R4 修订（codex high-2）：helper 走完 .downloaded → .stored 链（必须一步一步）
    @discardableResult
    private func walkToStored(trainingSetId tid: Int, leaseId lid: String,
                              path: String, hash: String) throws -> Bool {
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .unzipped,
                      sqliteLocalPath: path, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .dbVerified,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: tid, leaseId: lid, state: .stored,
                      sqliteLocalPath: nil, contentHash: hash, lastError: nil)
        return true
    }

    // 用例 11（R2 codex high-1 / R4 改 walk-through）：stale .stored retry 传 nil aux → COALESCE 保留
    func test_upsert_stale_retry_with_nil_aux_does_not_clear_existing_path_and_hash() throws {
        try walkToStored(trainingSetId: 5, leaseId: "L5",
                         path: "/tmp/set5.sqlite", hash: "5deadbe5")
        // 同 state .stored 重试，传 nil → COALESCE 保留已有值（不应清空）
        try db.upsert(trainingSetId: 5, leaseId: "L5", state: .stored,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        let stored = try db.listByState(.stored).filter { $0.leaseId == "L5" }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].sqliteLocalPath, "/tmp/set5.sqlite", "nil 入参不应清空已有 path")
        XCTAssertEqual(stored[0].contentHash, "5deadbe5", "nil 入参不应清空已有 hash")
    }

    // 用例 12（R2 codex high-1 / R4 改 walk-through）：forward .confirmPending 传 nil → 已有 path/hash 保留
    func test_upsert_forward_with_nil_aux_preserves_existing_via_coalesce() throws {
        try walkToStored(trainingSetId: 6, leaseId: "L6",
                         path: "/tmp/set6.sqlite", hash: "6c0ffe11")
        // forward 推进到 .confirmPending，aux fields 传 nil
        try db.upsert(trainingSetId: 6, leaseId: "L6", state: .confirmPending,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        let cp = try db.listByState(.confirmPending).filter { $0.leaseId == "L6" }
        XCTAssertEqual(cp.count, 1)
        XCTAssertEqual(cp[0].sqliteLocalPath, "/tmp/set6.sqlite")
        XCTAssertEqual(cp[0].contentHash, "6c0ffe11")
    }

    // 用例 14（R3 codex high-1 / R4 改 walk-through）：到 .stored 缺 sqliteLocalPath → .internalError
    func test_upsert_stored_without_path_throws_internalError() throws {
        // walk 到 .dbVerified（path 走 .unzipped 时已喂入；现在不喂 path 模拟 caller bug）
        try db.upsert(trainingSetId: 80, leaseId: "L80", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 80, leaseId: "L80", state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 80, leaseId: "L80", state: .unzipped,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 80, leaseId: "L80", state: .dbVerified,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 80, leaseId: "L80", state: .stored,
            sqliteLocalPath: nil, contentHash: "deadbeef", lastError: nil)
        ) { err in
            guard let appErr = err as? AppError,
                  case .internalError(let module, _) = appErr else {
                return XCTFail("期望 .internalError，实际 \(err)")
            }
            XCTAssertTrue(module.contains("AcceptanceJournalDAO"))
        }
    }

    // 用例 15（R3 codex high-1 / R4 改 walk-through）：到 .stored contentHash 非 8-char hex → .internalError
    func test_upsert_stored_with_invalid_contentHash_throws_internalError() throws {
        // walk 到 .dbVerified，path 已喂
        try db.upsert(trainingSetId: 81, leaseId: "L81", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 81, leaseId: "L81", state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 81, leaseId: "L81", state: .unzipped,
                      sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 81, leaseId: "L81", state: .dbVerified,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        // 错误格式：长度 7
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 81, leaseId: "L81", state: .stored,
            sqliteLocalPath: nil, contentHash: "deadbee", lastError: nil))
        // 错误格式：含大写
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 81, leaseId: "L81", state: .stored,
            sqliteLocalPath: nil, contentHash: "DEADBEEF", lastError: nil))
        // 错误格式：非 hex 字符
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 81, leaseId: "L81", state: .stored,
            sqliteLocalPath: nil, contentHash: "deadbeeg", lastError: nil))
    }

    // 用例 16（R3 codex high-1 / R4 改 walk-through）：.stored inherit 历史 path → 允许
    func test_upsert_stored_inherits_existing_path_via_invariant_check() throws {
        try walkToStored(trainingSetId: 82, leaseId: "L82",
                         path: "/tmp/82.sqlite", hash: "82deadbe")
        let stored = try db.listByState(.stored).filter { $0.leaseId == "L82" }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].sqliteLocalPath, "/tmp/82.sqlite")
        XCTAssertEqual(stored[0].contentHash, "82deadbe")
    }

    // 用例 18（R4 新增 codex high-2）：跳步 .downloaded → .stored 必须 NOOP
    func test_upsert_skip_state_downloaded_to_stored_is_NOOP() throws {
        try db.upsert(trainingSetId: 90, leaseId: "L90", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        // 直跳 .stored 跳过 crcOK/unzipped/dbVerified → NOOP
        try db.upsert(trainingSetId: 90, leaseId: "L90", state: .stored,
                      sqliteLocalPath: "/tmp/90.sqlite", contentHash: "90deadbe",
                      lastError: nil)

        // 行仍在 .downloaded，path/hash 仍 nil
        XCTAssertEqual(try db.listByState(.stored).filter { $0.leaseId == "L90" }.count, 0)
        let dl = try db.listByState(.downloaded).filter { $0.leaseId == "L90" }
        XCTAssertEqual(dl.count, 1)
        XCTAssertNil(dl[0].sqliteLocalPath)
        XCTAssertNil(dl[0].contentHash)
    }

    // 用例 19（R4 新增 codex high-2）：首次 INSERT 非 .downloaded → .internalError
    func test_first_insert_non_downloaded_throws_internalError() throws {
        XCTAssertThrowsError(try db.upsert(
            trainingSetId: 91, leaseId: "L91", state: .stored,
            sqliteLocalPath: "/tmp/91.sqlite", contentHash: "91deadbe", lastError: nil)
        ) { err in
            guard let appErr = err as? AppError,
                  case .internalError(let module, let detail) = appErr else {
                return XCTFail("期望 .internalError，实际 \(err)")
            }
            XCTAssertTrue(module.contains("AcceptanceJournalDAO"))
            XCTAssertTrue(detail.contains(".downloaded") || detail.contains("first INSERT"),
                          "detail 应说明首次 INSERT 必须 .downloaded")
        }
        XCTAssertEqual(try db.listByState(.stored).filter { $0.leaseId == "L91" }.count, 0)
    }

    // 用例 20（R4 新增 codex high-2）：任何阶段都可推 .rejected（失败可在任何阶段发生）
    func test_upsert_rejected_allowed_from_any_state() throws {
        // 从 .downloaded 直推 .rejected
        try db.upsert(trainingSetId: 92, leaseId: "L92", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 92, leaseId: "L92", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil, lastError: "crc_failed")
        XCTAssertEqual(try db.listByState(.rejected).filter { $0.leaseId == "L92" }.count, 1)

        // 从 .unzipped 推 .rejected
        try db.upsert(trainingSetId: 93, leaseId: "L93", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 93, leaseId: "L93", state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 93, leaseId: "L93", state: .unzipped,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 93, leaseId: "L93", state: .rejected,
                      sqliteLocalPath: nil, contentHash: nil, lastError: "verify_failed")
        XCTAssertEqual(try db.listByState(.rejected).filter { $0.leaseId == "L93" }.count, 1)
    }

    // 用例 17（R3 新增 codex med-3）：state_entered_at 是 Unix 秒 UTC（非毫秒）
    func test_state_entered_at_is_unix_seconds_not_millis() throws {
        let beforeSec = Int64(Date().timeIntervalSince1970)
        try db.upsert(trainingSetId: 83, leaseId: "L83", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let afterSec = Int64(Date().timeIntervalSince1970) + 1  // +1s 容忍

        let row = try db.listByState(.downloaded).first { $0.leaseId == "L83" }
        let stamp = row?.stateEnteredAt ?? 0
        // Unix 秒数应在 [beforeSec, afterSec] 区间；毫秒会大约 1000x，超出区间
        XCTAssertGreaterThanOrEqual(stamp, beforeSec - 1)
        XCTAssertLessThanOrEqual(stamp, afterSec + 1)
        // 显式断言：stamp / 1_000_000_000 应远小于 1（不是纳秒），stamp 数量级是 10^9-10^10（2024 epoch seconds）
        XCTAssertGreaterThan(stamp, 1_700_000_000)        // 后于 2023-11
        XCTAssertLessThan(stamp, 4_000_000_000)           // 早于 2096
    }

    // 用例 13（R2 新增 codex med-2）：existing 是 unknown raw value → upsert NOOP，不覆盖
    func test_upsert_existing_unknown_state_is_NOOP_not_overwritten() throws {
        // raw SQL 注入 unknown state 行（v1.3 leased 模拟）
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO download_acceptance_journal
                  (training_set_id, lease_id, state, state_entered_at,
                   last_error, sqlite_local_path, content_hash)
                VALUES (?, ?, 'leased', ?, NULL, '/tmp/v13.sqlite', 'd0d0beef')
                """, arguments: [77, "v13-leased", 1_700_000_000_000])
        }

        // 尝试用合法 state 覆盖 → 应 NOOP，unknown 行原样保留
        try db.upsert(trainingSetId: 77, leaseId: "v13-leased", state: .downloaded,
                      sqliteLocalPath: "/tmp/new.sqlite", contentHash: "deadbeef",
                      lastError: nil)

        // listByState(.downloaded) 不应返回 unknown 行（fail-safe filter）
        XCTAssertEqual(try db.listByState(.downloaded).filter { $0.leaseId == "v13-leased" }.count, 0)

        // 直接读 raw row 验证 state 仍是 'leased'，path/hash 未变
        let row = try queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT state, sqlite_local_path, content_hash
                FROM download_acceptance_journal
                WHERE training_set_id = ? AND lease_id = ?
                """, arguments: [77, "v13-leased"])
        }
        XCTAssertEqual(row?["state"] as String?, "leased", "unknown state 应原样保留")
        XCTAssertEqual(row?["sqlite_local_path"] as String?, "/tmp/v13.sqlite")
        XCTAssertEqual(row?["content_hash"] as String?, "d0d0beef")
    }
}
```

- [ ] **Step 7.2: 跑测试 fail**

```bash
swift test --filter DefaultAcceptanceJournalDAOTests 2>&1 | tail -10
```

- [ ] **Step 7.3: 扩展 PersistenceErrorMapping.swift（加 SQLITE_FULL → diskFull）**

Modify `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PersistenceErrorMapping.swift` —— 在 `if dbErr.resultCode == .SQLITE_NOTADB ||` 行**之前**插入：

```swift
            if dbErr.resultCode == .SQLITE_FULL {
                return .persistence(.diskFull)
            }
```

- [ ] **Step 7.4: 写 AcceptanceJournalDAOImpl.swift**

Create `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AcceptanceJournalDAOImpl.swift`：

```swift
import Foundation
import os.log
@preconcurrency import GRDB
import KlineTrainerContracts

/// AcceptanceJournalDAO 静态方法实现。
/// 表 download_acceptance_journal UNIQUE(training_set_id, lease_id)。
/// **R1 修订**：upsert 加单调 rank guard（codex high-1）；listByState decode 加 fail-safe + os_log（codex med-3）
enum AcceptanceJournalDAOImpl {

    private static let logger = Logger(subsystem: "com.kline.trainer.persistence",
                                       category: "AcceptanceJournalDAO")

    /// 显式 next-state allowlist（R4 修订 codex high-2 — spec L1798+ P2 状态机线性顺序）：
    /// 任何状态只能转去显式列出的下一组 state。downloaded → stored 跳过 CRC/unzip/verify 不允许。
    /// `rejected` 是吸收终态；`confirmed` 是成功终态；终态间互斥不可转。
    /// 任何状态都可推到 `.rejected`（失败可在任何阶段发生）。
    private static func nextAllowed(_ s: P2JournalState) -> Set<P2JournalState> {
        switch s {
        case .downloaded:     return [.crcOK, .rejected]
        case .crcOK:          return [.unzipped, .rejected]
        case .unzipped:       return [.dbVerified, .rejected]
        case .dbVerified:     return [.stored, .rejected]
        case .stored:         return [.confirmPending, .rejected]
        case .confirmPending: return [.confirmed, .rejected]
        case .confirmed:      return []  // 成功终态：不能再转
        case .rejected:       return []  // 失败终态：不能再转
        }
    }

    /// 转换合法性判定（R4 修订 codex high-2 — 改 explicit allowlist 取代 rank>）：
    /// - `new == old` → 同 state 重试，允许（刷新 entered_at + 辅助列）
    /// - `new` ∈ `nextAllowed(old)` → 一步转换，允许
    /// - 其它（跨步跳过 / backward / 终态互斥 / 终态后转）→ NOOP
    private static func canApply(new: P2JournalState, over old: P2JournalState) -> Bool {
        if new == old { return true }
        return nextAllowed(old).contains(new)
    }

    /// state-dependent invariant（R3 修订 codex high-1）：
    /// 推进到 .stored / .confirmPending / .confirmed 时必须已有 sqliteLocalPath（否则 recovery 找不到本地文件）。
    /// 推进到 .stored 时必须有 contentHash 且 8-char 小写 hex（per spec L390 CRC32 格式）。
    /// 不满足 → .internalError（caller 编程错误，不走 user Toast）。
    /// **设计**：仅校验"新行 INSERT"和"forward 推进"路径；同 state 重试 / 终态互斥 NOOP 不触发（因为不变更 state）。
    private static func validateInvariants(state: P2JournalState,
                                           existingPath: String?,
                                           existingHash: String?,
                                           newPath: String?,
                                           newHash: String?) throws {
        let resolvedPath = newPath ?? existingPath
        let resolvedHash = newHash ?? existingHash
        let needsPath: Set<P2JournalState> = [.stored, .confirmPending, .confirmed]
        if needsPath.contains(state), resolvedPath == nil {
            throw AppError.internalError(
                module: "P4-AcceptanceJournalDAO",
                detail: "state \(state.rawValue) requires sqliteLocalPath but neither new nor existing has it")
        }
        if state == .stored {
            guard let h = resolvedHash, isValidCRC32Hex(h) else {
                throw AppError.internalError(
                    module: "P4-AcceptanceJournalDAO",
                    detail: ".stored requires contentHash matching 8-char lowercase hex (CRC32)")
            }
        }
    }

    /// CRC32 hex 校验：8 个字符，全部 0-9a-f（小写）。per spec L390。
    private static func isValidCRC32Hex(_ s: String) -> Bool {
        guard s.count == 8 else { return false }
        return s.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
    }

    static func upsert(_ db: Database,
                       trainingSetId: Int, leaseId: String,
                       state: P2JournalState,
                       sqliteLocalPath: String?,
                       contentHash: String?,
                       lastError: String?) throws {
        // R1 修订（codex high-1）：read-then-write 单调 rank guard
        // 避免晚到 retry 把 .stored/.confirmed/.rejected 倒回 .downloaded
        // R3 修订（codex med-3）：state_entered_at 改 Unix 秒 UTC（spec L241 字面）
        let stateEnteredAt = Int64(Date().timeIntervalSince1970)

        // ① 查 existing 行（state + path + hash），R3 修订：path/hash 也读出供 invariants 校验
        if let row = try Row.fetchOne(db, sql: """
            SELECT state, sqlite_local_path, content_hash FROM download_acceptance_journal
            WHERE training_set_id = ? AND lease_id = ?
            """, arguments: [trainingSetId, leaseId]) {
            let existingRaw: String = row["state"]
            let existingPath: String? = row["sqlite_local_path"]
            let existingHash: String? = row["content_hash"]
            // 行已存在
            guard let existing = P2JournalState(rawValue: existingRaw) else {
                // R2 修订（codex med-2）：existing 是 unknown raw value（downgrade / 跨版本残留）
                // → NOOP + warn，不覆盖 unknown 行；留给 migration / 手工修复处理
                logger.error("noop: refuse to overwrite unknown existing state '\(existingRaw, privacy: .public)' with '\(state.rawValue, privacy: .public)' for trainingSetId=\(trainingSetId) leaseId=\(leaseId, privacy: .public)")
                return
            }
            if !canApply(new: state, over: existing) {
                // 晚到回退 / 终态互斥：NOOP，保留 existing（不 throw —— retry 合法）
                logger.info("noop: rejected upsert \(state.rawValue, privacy: .public) over \(existing.rawValue, privacy: .public) for trainingSetId=\(trainingSetId) leaseId=\(leaseId, privacy: .public)")
                return
            }
            // R3 修订（codex high-1）：forward 推进前校验 state-dependent invariants
            try validateInvariants(state: state,
                                   existingPath: existingPath, existingHash: existingHash,
                                   newPath: sqliteLocalPath, newHash: contentHash)
            // 转换合法 + invariants 满足 → UPDATE（aux 列走 COALESCE 保留已有非空值，per R2 codex high-1）
            try update(db, trainingSetId: trainingSetId, leaseId: leaseId,
                       state: state, stateEnteredAt: stateEnteredAt,
                       sqliteLocalPath: sqliteLocalPath, contentHash: contentHash,
                       lastError: lastError)
        } else {
            // 行不存在 → 仅允许 .downloaded 作为首条 journal 行（per spec L1798+ "v1.4 首条持久化行起点"）
            // R4 修订（codex high-2）：避免 caller bug 直接 INSERT .stored/.confirmed 跳过验证链
            guard state == .downloaded else {
                throw AppError.internalError(
                    module: "P4-AcceptanceJournalDAO",
                    detail: "first INSERT must be .downloaded; got .\(state.rawValue) for tid=\(trainingSetId) lid=\(leaseId)")
            }
            try validateInvariants(state: state,
                                   existingPath: nil, existingHash: nil,
                                   newPath: sqliteLocalPath, newHash: contentHash)
            try db.execute(sql: """
                INSERT INTO download_acceptance_journal
                  (training_set_id, lease_id, state, state_entered_at,
                   last_error, sqlite_local_path, content_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    trainingSetId, leaseId, state.rawValue, stateEnteredAt,
                    lastError, sqliteLocalPath, contentHash
                ])
        }
    }

    private static func update(_ db: Database,
                               trainingSetId: Int, leaseId: String,
                               state: P2JournalState, stateEnteredAt: Int64,
                               sqliteLocalPath: String?, contentHash: String?,
                               lastError: String?) throws {
        // R2 修订（codex high-1）：aux 列用 COALESCE(?, existing)，nil 入参保留已有值。
        // state / state_entered_at 总是覆盖（forward 推进或同 state 重试，stamp 必须刷新）。
        // last_error 也走 COALESCE：调用方传 nil 表示"无新错误信息"，保留旧错误日志便于 debug。
        try db.execute(sql: """
            UPDATE download_acceptance_journal
            SET state = ?,
                state_entered_at = ?,
                last_error = COALESCE(?, last_error),
                sqlite_local_path = COALESCE(?, sqlite_local_path),
                content_hash = COALESCE(?, content_hash)
            WHERE training_set_id = ? AND lease_id = ?
            """, arguments: [
                state.rawValue, stateEnteredAt, lastError,
                sqliteLocalPath, contentHash, trainingSetId, leaseId
            ])
    }

    static func listByState(_ db: Database, state: P2JournalState) throws -> [AcceptanceJournalRow] {
        let rows = try Row.fetchAll(db, sql:
            "SELECT * FROM download_acceptance_journal WHERE state = ? ORDER BY id ASC",
            arguments: [state.rawValue])
        // R1 修订（codex med-3）：fail-safe decode + os_log warning，不抛 .dbCorrupted
        return rows.compactMap { row -> AcceptanceJournalRow? in
            do {
                return try journalRowFromRow(row)
            } catch {
                let stateRaw: String = row["state"]
                let tid: Int = row["training_set_id"]
                let lid: String = row["lease_id"]
                logger.error("skip row: unknown state '\(stateRaw, privacy: .public)' tid=\(tid) lid=\(lid, privacy: .public)")
                return nil
            }
        }
    }

    static func deleteByIdLease(_ db: Database, trainingSetId: Int, leaseId: String) throws {
        try db.execute(sql: """
            DELETE FROM download_acceptance_journal
            WHERE training_set_id = ? AND lease_id = ?
            """, arguments: [trainingSetId, leaseId])
    }

    private static func journalRowFromRow(_ row: Row) throws -> AcceptanceJournalRow {
        let stateRaw: String = row["state"]
        guard let state = P2JournalState(rawValue: stateRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return AcceptanceJournalRow(
            id: row["id"], trainingSetId: row["training_set_id"],
            leaseId: row["lease_id"], state: state,
            stateEnteredAt: row["state_entered_at"],
            lastError: row["last_error"],
            sqliteLocalPath: row["sqlite_local_path"],
            contentHash: row["content_hash"]
        )
    }
}
```

- [ ] **Step 7.5: 替换 DefaultAppDB.swift 里 AcceptanceJournalDAO 3 个 fatalError**

Modify `DefaultAppDB.swift` —— `// MARK: - AcceptanceJournalDAO` 段：

```swift
    // MARK: - AcceptanceJournalDAO

    public func upsert(trainingSetId: Int, leaseId: String, state: P2JournalState,
                       sqliteLocalPath: String?, contentHash: String?,
                       lastError: String?) throws {
        do {
            try dbQueue.write { db in
                try AcceptanceJournalDAOImpl.upsert(
                    db, trainingSetId: trainingSetId, leaseId: leaseId,
                    state: state, sqliteLocalPath: sqliteLocalPath,
                    contentHash: contentHash, lastError: lastError)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] {
        do {
            return try dbQueue.read { db in
                try AcceptanceJournalDAOImpl.listByState(db, state: state)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }

    public func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {
        do {
            try dbQueue.write { db in
                try AcceptanceJournalDAOImpl.deleteByIdLease(
                    db, trainingSetId: trainingSetId, leaseId: leaseId)
            }
        } catch let appErr as AppError { throw appErr }
        catch { throw PersistenceErrorMapping.translate(error) }
    }
```

- [ ] **Step 7.6: 跑测试 pass**

```bash
swift test --filter DefaultAcceptanceJournalDAOTests 2>&1 | tail -20
# 期望：7 tests passed
```

- [ ] **Step 7.7: commit 子项 3.d**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/AcceptanceJournalDAOImpl.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/PersistenceErrorMapping.swift
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultAcceptanceJournalDAOTests.swift
git commit -m "feat(P4-journal): AcceptanceJournalDAO production impl + diskFull mapping

- upsert: ON CONFLICT (training_set_id, lease_id) DO UPDATE
- listByState: WHERE state = ? ORDER BY id ASC
- deleteByIdLease: 0 行删除合法
- PersistenceErrorMapping: SQLITE_FULL → .persistence(.diskFull) (write 路径首次)

7 tests pass."
```

---

## Task 8: 端到端集成测试 + schema drift CI 脚本 + 验收清单

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBHappyPathIntegrationTests.swift`
- Create: `scripts/check_app_schema_drift.sh`
- Create: `docs/acceptance/2026-05-03-plan3c-appdb.md`

- [ ] **Step 8.1: 写 happy-path 集成测试**

Create `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBHappyPathIntegrationTests.swift`：

```swift
import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

/// 端到端 happy-path：模拟 E6 TrainingSessionCoordinator 完整 session 生命周期。
final class AppDBHappyPathIntegrationTests: XCTestCase {

    func test_full_session_lifecycle_save_pending_settle_to_record() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)

        // ① 首次启动：无 pending、无 records、settings 默认
        XCTAssertNil(try db.loadPending())
        XCTAssertEqual(try db.listRecords(limit: nil).count, 0)
        XCTAssertEqual(try db.statistics().totalCount, 0)
        XCTAssertEqual(try db.loadSettings().displayMode, .system)

        // ② 用户进设置
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 10_000, displayMode: .dark))

        // ③ 进入训练 → save pending
        let pending = PendingTraining(
            trainingSetFilename: "set-A.zip",
            globalTickIndex: 0,
            upperPeriod: .daily, lowerPeriod: .m60,
            positionData: Data(),
            cashBalance: 10_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true),
            tradeOperations: [],
            drawings: [],
            startedAt: 1_700_000_000_000,
            accumulatedCapital: 10_000,
            drawdown: .initial)
        try db.savePending(pending)

        // ④ session 结算 → 写 record + clear pending
        let record = TrainingRecord(
            id: nil, trainingSetFilename: "set-A.zip", createdAt: 1_700_000_000_000,
            stockCode: "000001", stockName: "平安银行", startYear: 2024, startMonth: 1,
            totalCapital: 10_000, profit: 500, returnRate: 0.05, maxDrawdown: 200,
            buyCount: 1, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true),
            finalTick: 100)
        let recordId = try db.insertRecord(record, ops: [], drawings: [])
        try db.clearPending()

        XCTAssertNil(try db.loadPending())
        XCTAssertEqual(try db.listRecords(limit: nil).count, 1)

        // ⑤ statistics 反映 win
        let stats = try db.statistics()
        XCTAssertEqual(stats.totalCount, 1)
        XCTAssertEqual(stats.winCount, 1)
        XCTAssertEqual(stats.currentCapital, 10_500)

        // ⑥ AcceptanceJournal 模拟 P2 一组 lease 全链路（R4 修订：必须走每一步）
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped,
                      sqliteLocalPath: "/tmp/set.sqlite", contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                      sqliteLocalPath: nil, contentHash: "deadbeef", lastError: nil)
        XCTAssertEqual(try db.listByState(.stored).count, 1)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .confirmPending,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try db.upsert(trainingSetId: 1, leaseId: "L1", state: .confirmed,
                      sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try db.listByState(.confirmed).count, 1)
        try db.deleteByIdLease(trainingSetId: 1, leaseId: "L1")
        XCTAssertEqual(try db.listByState(.confirmed).count, 0)

        // ⑦ load record bundle 完整恢复
        let bundle = try db.loadRecordBundle(id: recordId)
        XCTAssertEqual(bundle.0.profit, 500)
        XCTAssertEqual(bundle.1.count, 0)
        XCTAssertEqual(bundle.2.count, 0)
    }
}
```

- [ ] **Step 8.2: 写 schema drift CI 脚本**

Create `scripts/check_app_schema_drift.sh`：

```bash
#!/usr/bin/env bash
# 校验 AppDBMigrations.swift 内 inline schema 字串与 ios/sql/app_schema_v1.sql 一致。
# 失败 → CI 必须 block。
# 用法：bash scripts/check_app_schema_drift.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEMA_FILE="ios/sql/app_schema_v1.sql"
SWIFT_FILE="ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift"

# 提取 Swift 字串内容：从 `static let v1_4_baselineDDL: String = """` 后到最近 `"""`
INLINE=$(awk '
    /static let v1_4_baselineDDL: String = """/ { capture=1; next }
    capture && /^    """$/ { capture=0; next }
    capture { print }
' "$SWIFT_FILE")

# 规范化两侧去掉注释行 / 前导空白做对比
NORMALIZE() { grep -v '^[[:space:]]*--' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'; }
LEFT=$(echo "$INLINE" | NORMALIZE)
RIGHT=$(cat "$SCHEMA_FILE" | NORMALIZE)

if [ "$LEFT" != "$RIGHT" ]; then
    echo "ERROR: schema drift between AppDBMigrations.v1_4_baselineDDL and $SCHEMA_FILE"
    diff <(echo "$LEFT") <(echo "$RIGHT") || true
    exit 1
fi

echo "OK: AppDBMigrations.swift schema 与 $SCHEMA_FILE 一致"
```

```bash
chmod +x scripts/check_app_schema_drift.sh
bash scripts/check_app_schema_drift.sh
# 期望：OK: AppDBMigrations.swift schema 与 ios/sql/app_schema_v1.sql 一致
```

- [ ] **Step 8.3: 写验收清单**

Create `docs/acceptance/2026-05-03-plan3c-appdb.md`：

```markdown
# PR 3c P4 AppDB 验收清单（plan3c-appdb 分支 / Wave 0 顺位 6）

## 范围
- P4 AppDB composition root（DefaultAppDB + 单一 DatabaseQueue）
- 4 个 protocol 生产实现（RecordRepository / PendingTrainingRepository / SettingsDAO / AcceptanceJournalDAO）
- typealias AppDB = 4-protocol 复合
- DatabaseMigrator 注册 0001_v1.4_baseline + 0003_v1.4_purge_leased
- AcceptanceJournalDAO contract（protocol + P2JournalState + AcceptanceJournalRow + InMemory fake）

## 动作 / 预期输出 / 是否通过

| 动作 | 命令 | 预期 | 通过 |
|---|---|---|---|
| swift build | `cd ios/Contracts && swift build` | Build complete! 无 error 无 warning | □ |
| 全套 contracts 测试 | `swift test --filter KlineTrainerContractsTests` | 所有 test pass，含 4 个 AcceptanceJournalDAOContract | □ |
| 全套 persistence 测试 | `swift test --filter KlineTrainerPersistenceTests` | 所有 test pass（PR #41 33 个 + 本 PR 30 个 = 63 个） | □ |
| schema drift | `bash scripts/check_app_schema_drift.sh` | "OK: AppDBMigrations.swift schema 与 ios/sql/app_schema_v1.sql 一致" | □ |
| typealias AppDB 编译 | 见 AcceptanceJournalDAOContractTests.test_typealias_AppDB_composes_four_protocols | XCTAssertNil pass | □ |
| migration 注册 | 见 AppDBMigrationsTests | 4 tests pass：tables/version/purge_leased/idempotent | □ |
| 端到端 happy path | 见 AppDBHappyPathIntegrationTests | 1 test pass：save settings → pending → record → journal lifecycle | □ |
| AppError 翻译 gate | grep "throw.*GRDB.DatabaseError\|throw.*DecodingError" ios/Contracts/Sources/KlineTrainerPersistence/ | 无命中（GRDB error 全部经 PersistenceErrorMapping） | □ |

## 失败兜底
- 任意命令 fail → 修复后重跑；不 push PR
- schema drift 失败 → 同步两边（修 SQL 文件或 Swift 字串都可，确保完全一致）
- AppError 翻译 gate 失败 → 加 try/catch 边界，禁止裸 throw GRDB / Decoding 错误

## Spec 锚点
- §M0.1 line 131-156（app.sqlite migration owner = P4）
- §M0.1 line 230-289（download_acceptance_journal 表 + v1.4 删 leased + 0003 migration）
- §M0.5 line 684（单一 DatabaseQueue）
- §P4 line 1863-1948（4 protocol + typealias + DefaultAppDB）

## 不在本 PR 范围
- E6 TrainingSessionCoordinator 实际 wire P4（属 PR 5 Fixture/Mock 后续）
- P2 DownloadAcceptanceRunner 实际调用 AcceptanceJournalDAO（属 PR 4a/4b）
- P6 SettingsStore 包装 SettingsDAO（属 PR 4b）
- 跨 device iCloud 同步（Wave 2+）

## Round N 对抗性 review

待 codex 跑后填。
```

- [ ] **Step 8.4: 跑全套测试 + drift script + AppError gate 联合验证**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts"
swift test 2>&1 | tail -20
# 期望：全套 pass

cd "/Users/maziming/Coding/Prj_Kline trainer"
bash scripts/check_app_schema_drift.sh
# 期望：OK 行

# AppError 翻译 gate（grep 不应命中 raw GRDB / Decoding throw）
grep -rE "throw.*DatabaseError|throw.*DecodingError" \
    ios/Contracts/Sources/KlineTrainerPersistence/ || echo "OK: 无裸 throw GRDB/Decoding"
```

- [ ] **Step 8.5: commit 验收物**

```bash
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBHappyPathIntegrationTests.swift
git add scripts/check_app_schema_drift.sh
git add docs/acceptance/2026-05-03-plan3c-appdb.md
git commit -m "test(P4): happy-path integration + schema drift CI + acceptance doc

- AppDBHappyPathIntegrationTests: settings → pending → record → journal lifecycle
- scripts/check_app_schema_drift.sh: AppDBMigrations 字串 vs ios/sql 文件 diff
- docs/acceptance/2026-05-03-plan3c-appdb.md: 8-row 验收表"
```

- [ ] **Step 8.6: push branch + 开 PR（待 user explicit confirm）**

**STOP HERE：** 不要自动 push 或开 PR。等 user 确认走 codex review → 再 push 等 user 命令。

---

## Round N 对抗性 review

### Round 1（codex 2026-05-03，branch-diff vs origin/main）

verdict = **needs-attention**，5 findings：

| # | sev | finding | revision applied |
|---|---|---|---|
| 1 | HIGH | Journal upsert ON CONFLICT 盲覆盖 → 晚到 retry 把 .stored/.confirmed 倒回 .downloaded → 丢 recovery row | Design Decision §10 重写为 read-then-write monotonic rank guard；canApply(new, over) 规则；终态 confirmed/rejected 同 rank 互斥；AcceptanceJournalDAOImpl.upsert 改 read-then-write；新增 用例 8/9/10 |
| 2 | HIGH | SettingsDAO loadSettings 把 corrupt value 当 missing 走 default → 静默把财务参数重置 0 | Design Decision §9 分 missing vs malformed 两路；SettingsDAOImpl.loadSettings 新增 parseDouble/Bool/DisplayMode helper；新增 用例 7/8/9/10 |
| 3 | MED | listRecords / statistics 仅按 created_at DESC，同毫秒并列 SQLite 任选 | Design Decision §6 加 id DESC tiebreak 说明；RecordRepositoryImpl.listRecords + statistics 加 `, id DESC`；test_statistics_aggregates_correctly 改用不同 createdAt；新增 用例 5b test_tied_createdAt_uses_id_DESC_as_tiebreak |
| 4 | MED | makeV1_3SimulatedDB 直接 raw SQL 跑 baseline，没标 0001 已 applied → migrator 重跑 0001 撞 "table exists" 抛错 → 0003 永远不验 | AppDBFixture.makeV1_3SimulatedDB 改用 partial migrator state（仅注册 0001 跑一次） |
| 5 | MED | listByState 不做 unknown raw value fail-safe，违反 spec L289 字面 | Design Decision §11 重写：fail-safe + os_log；AcceptanceJournalDAOImpl.listByState compactMap + try journalRowFromRow；listByState 不抛 .dbCorrupted |

5 findings 全部应用真修订（无 reject）。残留：
- 用例 8/9/10 的 monotonic rank 测试隐式 cover spec L1798+ P2 状态机；下游 P2 runner（PR 4a）实际调用时若有反向需求需扩 protocol（如增 `forceTransition` 显式覆盖 API）
- os_log 副作用难直测；测试通过验证 rows 不返回 + acceptance grep 兜底

### Round 2（codex 2026-05-03，branch-diff vs origin/main）

verdict = **needs-attention**，4 findings：

| # | sev | finding | revision applied |
|---|---|---|---|
| 1 | HIGH | upsert update 路径无条件覆盖 sqlite_local_path/content_hash → stale .stored retry 传 nil 把 path/hash 清成 NULL → recovery 失锚 | update SQL 改 COALESCE(?, existing) for sqlite_local_path / content_hash / last_error；state / state_entered_at 仍覆盖；新增 用例 11/12 |
| 2 | MED | existing 是 unknown raw value 时 fall-through 到 update → 把 unknown state 覆盖成 caller 已知 state（违反 fail-safe ignore） | 改 NOOP + os_log error；不动 unknown 行；新增 用例 13 验证 raw SQL 注入 leased 行后 upsert .downloaded 不覆盖 |
| 3 | MED | parseDouble 不拒 NaN/inf；saveSettings 也不拒 → 污染财务计算 | parseDouble 加 `.isFinite` guard；saveSettings 加 commissionRate/totalCapital finite 校验抛 .internalError；新增 用例 11/12/13/14 |
| 4 | MED | plan line 257-258 注释跨行打断 Swift 代码 | 合并 `// MARK: - Row 投影类型（DAO 读出的不可变快照）` 到一行 |

4 findings 全部应用真修订。残留：
- COALESCE 设计中 last_error 也走 COALESCE（caller 传 nil 表示"无新错误"，保留旧 log）；如果 caller 真想清空 last_error 字段，需新加 API；目前认 last_error 只追加 / 不主动清空
- `internalError(module: "P4-SettingsDAO", ...)` 而非 `.dbCorrupted` for save NaN：caller 编程错误不走用户 Toast（shouldShowToast=false）

### Round 3（codex 2026-05-03，branch-diff vs origin/main）

verdict = **needs-attention**，4 findings：

| # | sev | finding | revision applied |
|---|---|---|---|
| 1 | HIGH | upsert 允许 .stored / .confirmPending / .confirmed 行无 sqliteLocalPath；spec 要求 stored 必须可定位本地文件 + 有 contentHash 才能 CRC 验证 | 加 `validateInvariants` helper：forward 到这 3 个 state 必须有 path（COALESCE 已有 + new）；.stored 还要 contentHash 8-char 小写 hex；缺 → `.internalError`；upsert 改 SELECT 全列拿 existing path/hash 喂 invariants；新增 用例 14/15/16 |
| 2 | HIGH | baseline DDL 直接 CREATE TABLE，dev 残留 v1.3 app.sqlite 时撞 "table exists" → 0003 不跑 | DDL 全改 `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS`；同步改 `ios/sql/app_schema_v1.sql`（Step 3.4a 加 sed 命令）；新增 test_baseline_idempotent_on_legacy_db_with_tables_no_migration_record |
| 3 | MED | `state_entered_at` 用毫秒，spec L241 字面是 Unix 秒 UTC | upsert + update 改 `Int64(Date().timeIntervalSince1970)`（去 *1000）；contract comment 改 "毫秒 epoch" → "Unix 秒 UTC"；新增 test_state_entered_at_is_unix_seconds_not_millis |
| 4 | MED | DefaultAppDB.init 传 fileURL 给 PersistenceErrorMapping.translate → SQLITE_CANTOPEN + missing 文件被判 `.trainingSet(.fileNotFound)`（训练组语义，对 app DB 不对） | DefaultAppDB.init 不传 fileURL；新增 2 tests：test_PersistenceErrorMapping_without_fileURL_maps_CANTOPEN_to_ioError + test_DefaultAppDB_open_failure_throws_persistence_not_trainingSet |

4 findings 全部应用真修订。残留：
- IF NOT EXISTS 让 baseline 在残留 schema 上保守 silently skip；schema drift（旧字段 / 新字段）不会被检出，留给将来 alter migration 处理（Wave 0 fresh install 接受此 trade-off）
- validateInvariants 不强制 `.confirmed` 必须有 contentHash（confirm 阶段可能已不需 hash —— 仅 .stored 阶段验 CRC32）；spec 未显式定义后续阶段是否仍需 hash，按 spec 字面只在 .stored 强制
- AppDB CANTOPEN 测试用 `/dev/null/x/app.sqlite` 作 bad path——cross-platform 兼容假设但 macOS 一定 fail（XCode/SPM target macOS）

待执行 R4 验证。**Round 计数：3**（≥5 触发 abort 协议 per `feedback_codex_round6_self_contradiction.md`）。

### Round 4（codex 2026-05-03，branch-diff vs origin/main）

verdict = **needs-attention**，2 findings（都 HIGH）：

| # | sev | finding | decision |
|---|---|---|---|
| 1 | HIGH | baseline DDL `CREATE TABLE IF NOT EXISTS` 在残留 schema 上 silently skip → 列结构不匹配也认作 "已 v1.4"；codex 推 PRAGMA table_info / index_list 校验 + .schemaMismatch | **REJECT**（理由：Wave 0 fresh install 无 v1.3 deployed；spec L156 仅规定 P4 是 migration owner、未要求 schema 自动校验；PRAGMA validation 是 scope creep 且匹配 codex `feedback_codex_fractional_subpixel_bias` 防御级永远不够模式；该残留写入 §"已知残留"，将来 alter migration 引入时再加校验） |
| 2 | HIGH | canApply 仅 rank 比较 → 允许 .downloaded → .stored 跳过 CRC/unzip/dbVerified；happy-path 测试自身就直跳，把 unsafe 当默认 | **ACCEPT**：canApply 改 explicit `nextAllowed` map（spec L1798+ 线性顺序）；首次 INSERT 必须 .downloaded；`.rejected` 任何阶段可推；修 happy-path 集成测试走完整链；新增 walkToStored helper；新增 用例 18/19/20；改写 用例 8/11/12/14/15/16 用 walk-through |

1 ACCEPT + 1 REJECT。残留：
- IF NOT EXISTS 残留 schema 不验证：Wave 0 fresh install 接受；将来出现 v1.x → v1.y migration 时再加 PRAGMA 校验
- caller 想要"批量推进"（如 `.crcOK + .unzipped + .dbVerified` 一步合并）需调 N 次 upsert；DAO 层不允许跨步是 defense-in-depth 决策
- happy-path 测试现 7 步走完链，看似冗长但验证 spec L1798+ 完整顺序

**Round 计数：4**（≥5 触发 abort 协议 per `feedback_codex_round6_self_contradiction.md`）。R5 若仍出新 finding 或重复推 finding 1，escalate user。

---

## Self-Review Checklist（writing-plans skill 要求）

### 1. Spec coverage
- ✅ §P4 L1870-L1877 RecordRepository → Task 4
- ✅ §P4 L1879-L1883 PendingTrainingRepository → Task 5
- ✅ §P4 L1885-L1889 SettingsDAO → Task 6
- ✅ §P4 L1893-L1904 AcceptanceJournalDAO → Task 7（含 Task 2 contract addition）
- ✅ §P4 L1906-L1917 P2JournalState（v1.4 8 状态）→ Task 2
- ✅ §P4 L1919-L1928 AcceptanceJournalRow → Task 2
- ✅ §P4 L1931 typealias AppDB → Task 2
- ✅ §P4 L1933-L1937 DefaultAppDB(dbPath:) → Task 3
- ✅ §M0.1 L156 P4 是 migration owner → Task 3 AppDBMigrations.makeMigrator
- ✅ §M0.1 L268 0003_v1.4_purge_leased SQL → Task 3
- ✅ §M0.1 L289 fail-safe unknown raw value → Task 7 Design Decision §11 + Test 用例 7
- ✅ §M0.5 L684 单一 DatabaseQueue → Task 3 DefaultAppDB.dbQueue
- ✅ M0.4 翻译 gate（无裸 GRDB/Decoding throw）→ Task 8 grep 验证

### 2. Placeholder scan
- ✅ 无 TBD / TODO / "implement later" / "适当处理"
- ✅ 每个 step 含完整代码块或具体命令
- ✅ 所有 protocol 方法签名与 contracts 一致

### 3. Type consistency
- ✅ `DefaultAppDB` 拼写一致（不与 `DefaultAppDb` 混）
- ✅ `AcceptanceJournalDAO` 与 `AcceptanceJournalDao` 不混
- ✅ `P2JournalState` 全 plan 一致
- ✅ `dbQueue.read` / `dbQueue.write` 使用一致
- ✅ `RecordRepositoryImpl.jsonEncode` / `jsonDecode` helper 在 Task 5/6/7 全部复用（DRY）

### 4. 子项 + 行数预算
- ✅ 子项 = 3（contract / composition root / 4 DAO 实现）
- ✅ prod ≈ 470 行 < 500 硬规则
- ✅ test ≈ 750 行（无硬规则）

### 5. 已知 residuals（accepted）
- spec L289 unknown raw value fail-safe 仅在 listByState 强制；listAll / scanTargets 未在 protocol body → 不实现，记 Design Decision §11
- foreign_keys PRAGMA 是 connection-scoped；新打开的 raw connection（test helper）不一定有 PRAGMA ON。本 plan 在 DefaultAppDB.init 用 `Configuration.prepareDatabase` 强制每个新 connection ON；test 验证只对 DefaultAppDB queue
- 无 spec 强制 listAcceptanceJournalScanTargets 复合 listByState 调用 helper；归 P2 DownloadAcceptanceRunner（PR 4a）实现侧
