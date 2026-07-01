# 复盘(Review) 完整重设计 + replay 主界面标记 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把复盘(Review)重设计成"与训练界面一致、逐 tick 重算运行盈亏、可画线、可持久可续、结束存单槽存档"，并给主界面历史行加 `再次训练中/复盘中/已复盘` 三态标记，合并为一个 PR。

**Architecture:** 新增 per-record 持久化表 `review_archive`（migration 0007 + CONTRACT_VERSION 1.8→1.9）+ 仓 `ReviewArchiveRepository`（镜像 `PendingReplayRepository`）；新增纯组件 `ReviewLedger`（折叠已记录 `TradeOperation` 重算运行账户）；coordinator 加专用复盘持久化路径（committed 基线净改动判定 + 进程内单写者 fence）；复盘 UI 复用训练界面壳，仅底栏 3 键→2 键、解耦画线/红框门控、顶栏改读 ReviewLedger。

**Tech Stack:** Swift 6 / SwiftUI（`ios/Contracts/Sources/KlineTrainerContracts` 平台无关纯值 host 全测 + `#if canImport(UIKit)` SwiftUI 壳 Catalyst 编译闸门）；GRDB（`KlineTrainerPersistence`）；Swift Testing（`@Test`/`#expect`）。

## Global Constraints

- **权威 spec**：`docs/superpowers/specs/2026-07-02-review-redesign-design.md`（每个 task 的需求隐含包含它）。**已浏览器确认 mockup**：`docs/superpowers/mockups/2026-07-02-review-redesign.html`。
- **CONTRACT_VERSION**：`1.8` → `1.9`（`Models.swift`），`ModelsTests` 同步断言。
- **migration**：新增 `0007_v1.9_review_archive`（尾部追加，`PRAGMA user_version = 5`）；**不动**冻结基线 `v1_4_baselineDDL` / `ios/sql/app_schema_v1.sql`（drift-checked）。基线 DB（`d96b1f4`）现状 = 已过 0006、`user_version = 4`、有 `pending_replay`。
- **文案定稿**：行标记 `再次训练中`/`复盘中`/`已复盘`；action sheet 复盘钮 `复盘`/`返回复盘`、训练钮 `再次训练`/`返回训练`（无小字说明）；复盘底栏 `下单价`（保留原文案）；结束弹窗 `保存`/`不保存`/`取消`。
- **红涨绿跌**：盈=红、亏=绿（沿用 `HomeView.color(for:)` / `UIChartPalette`）。
- **复盘中 与 已复盘 互斥**（同一 review 维度）；replay `再次训练中` 与 review 标记正交（可并存）。
- **committed 基线**：复盘净改动判定一律"当前工作画线集 vs committed（`saved_drawings` 或 ∅）"，**不是** resume 载入的 working。
- **mark price 规范来源**：单一公开入口 `engine.markPrice(atTick: t)`（Task 9 Step 2b 暴露；内部 = `.m3` 收盘价、越界 clamp、非 nil）——`currentPrice`/finalize/ReviewLedger 共用同一入口，不重复实现。
- **等式 oracle**：`ReviewLedger` 在记录 finalTick 的 `profit(=totalCapital−initialCapital)`/`returnRate` **逐位等于** `record.profit`/`record.returnRate`（注意 `record.totalCapital` 字段存的是**初始资金**，不可用作运行总资金比对）。
- **复盘画线归属**：复盘新画线进 engine **`reviewDrawings`**（新字段，与只读的原训练 `drawings` 分离），**从不写回原训练记录**。
- **fail-closed**：`review_archive` 解码失败 → `AppError.persistence(.dbCorrupted)`；working 损坏 resume 清 working；saved 损坏进入复盘清 saved+移除标记+空基线重进+toast；返回/结束保存失败弹重试/放弃 alert。
- **本地工具链宽松**：SwiftUI `@MainActor`/`Sendable` 隔离错本地可能漏报；**合并后须 `gh run watch` 确认 CI macos-15 真绿**（参 memory `feedback_swift_local_ci_toolchain_strictness`）。可测纯 static helper 放非-View struct 或加 `nonisolated`。
- **测试运行**：host 测 `swift test`（工作目录 `ios/Contracts`）；SwiftUI 壳编译闸门 `xcodebuild ... -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing`。

---

## File Structure

**新建：**
- `ios/Contracts/Sources/KlineTrainerContracts/Persistence/ReviewArchiveRepository.swift` — 协议 + `ReviewArchive` 值类型 + `ReviewMarker` 枚举 + `ReviewArchiveSlotInfo`
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/ReviewArchiveRepositoryImpl.swift` — GRDB 实现
- `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/ReviewLedger.swift` — 纯折叠组件
- 测试：`ReviewLedgerTests.swift` / `ReviewArchiveRepositoryTests.swift` / `ReviewArchiveMigrationTests.swift` / `ReviewMarkersContentTests.swift` / `ReviewControlBarContentTests.swift` / `ReviewButtonTitleTests.swift`（放 `ios/Contracts/Tests/KlineTrainerContractsTests/` 或 `KlineTrainerPersistenceTests/`）

**修改：**
- `Models.swift`（CONTRACT_VERSION）
- `KlineTrainerPersistence/Internal/AppDBMigrations.swift`（0007）
- `KlineTrainerPersistence/DefaultAppDB.swift`（conform + reset 清表）
- `KlineTrainerPersistence/AppContainer.swift`（注入）
- `TrainingEngine/TrainingSessionCoordinator.swift`（init 参数 + 复盘持久化路径 + review() 基线 + resume + fence）
- `TrainingEngine/TrainingEngine.swift`（`stepReviewForward(panel:)` + `reviewDrawings`/`appendReviewDrawing`）
- `UI/ReviewControlBar.swift`（重设计 2 键 + 分段器 + 下单价）
- `UI/TrainingTopBarContent.swift`（复盘读 ReviewLedger）
- `Render/RenderStateBuilder.swift`（review 叠加两层画线）
- `UI/HomeContent.swift` + `UI/HomeView.swift`（行标记）
- `UI/HistoryActionSheet.swift`（`reviewButtonTitle`）
- `App/AppRootView.swift`（wiring）+ `App/AppRouter.swift`（review resume-first + loadHome 标记）
- `UI/TrainingView.swift` + `UI/TrainingSessionLifecycle.swift`（复盘集成）

---

## Task 1: CONTRACT_VERSION bump + migration 0007 + reset 清表 + 迁移链测试

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift`（CONTRACT_VERSION 常量）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift`（`makeMigrator()` 尾部 + baseline reset 若在此）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（`resetAllTrainingProgress` **非破坏**改动：只清 working、**保留 saved**——见 Step 5，**禁止** `DELETE FROM review_archive` 整表删）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift`（版本断言）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/ReviewArchiveMigrationTests.swift`（新建）

**Interfaces:**
- Produces: 表 `review_archive`（列 `record_id PK / saved_drawings TEXT? / working_step_tick INTEGER? / working_drawings TEXT? / updated_at INTEGER NOT NULL` + `CHECK ((working_step_tick IS NULL) = (working_drawings IS NULL))`）；`user_version = 5`；`CONTRACT_VERSION = "1.9"`。

- [ ] **Step 1: 写迁移链失败测试**

`ReviewArchiveMigrationTests.swift`：
```swift
import Testing
import GRDB
@testable import KlineTrainerPersistence

@Suite struct ReviewArchiveMigrationTests {
    // Fresh install：空 DB 跑全 migrator（0001→…→0007）
    @Test func freshInstallHasReviewArchiveV5() throws {
        let queue = try DatabaseQueue()   // in-memory
        try AppDBMigrations.makeMigrator().migrate(queue)
        try queue.read { db in
            let exists = try Bool.fetchOne(db, sql:
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='review_archive'") ?? false
            #expect(exists)
            #expect((try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1) == 5)
        }
    }

    // **已装用户升级路径（codex plan-R2-medium）**：先只迁到 0006（GRDB migrate(upTo:)）→ 造"停在 0006"
    // 的真实形态（user_version=4、有 pending_replay、无 review_archive），写入数据，再跑全 migrator（只应跑 0007）。
    @Test func upgradesExisting0006DbPreservingData() throws {
        let queue = try DatabaseQueue()
        let migrator = AppDBMigrations.makeMigrator()
        try migrator.migrate(queue, upTo: "0006_v1.8_pending_replay")   // 停在 0006
        try queue.write { db in
            #expect((try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1) == 4)   // 0006 落点
            let hasReview = try Bool.fetchOne(db, sql:
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='review_archive'") ?? false
            #expect(!hasReview)                                          // 升级前无 review_archive
            // 造既有数据：一条 pending_replay 单槽（列同 0006 表；用最小合法值或复用 PendingReplayRepositoryTests 造法）
            try db.execute(sql: "INSERT INTO pending_replay (id, record_id, training_set_filename, global_tick_index, upper_period, lower_period, position_data, fee_snapshot, trade_operations, drawings, started_at, accumulated_capital, cash_balance, drawdown) VALUES (1, 7, 'a.sqlite', 3, '3m', '15m', '', '{}', '[]', '[]', 0, 100000, 100000, '{}')")
        }
        try migrator.migrate(queue)                                     // 跑剩余（仅 0007）
        try queue.read { db in
            #expect((try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1) == 5)   // 升级到 v5
            let hasReview = try Bool.fetchOne(db, sql:
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='review_archive'") ?? false
            #expect(hasReview)                                          // review_archive 建表
            let slotStillThere = try Int.fetchOne(db, sql:
                "SELECT record_id FROM pending_replay WHERE id=1") ?? -1
            #expect(slotStillThere == 7)                               // 既有 pending_replay 数据留存
        }
    }

    // CHECK 拒半 working 行：只写 working_step_tick 不写 working_drawings → 抛
    @Test func checkRejectsHalfWorkingRow() throws {
        let queue = try DatabaseQueue()
        try AppDBMigrations.makeMigrator().migrate(queue)
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(sql:
                    "INSERT INTO review_archive (record_id, working_step_tick, working_drawings, updated_at) VALUES (1, 10, NULL, 0)")
            }
        }
    }

    // 幂等重跑不报错
    @Test func migratorIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try AppDBMigrations.makeMigrator().migrate(queue)
        try AppDBMigrations.makeMigrator().migrate(queue)   // 二次 no-op
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter ReviewArchiveMigrationTests`
Expected: FAIL（`review_archive` 不存在 / user_version==4）。

- [ ] **Step 3: 追加 migration 0007（`AppDBMigrations.swift` `return migrator` 之前）**

```swift
        // 0007：复盘存档 per-record（review-redesign RFC，v1.9）。additive：新建 review_archive
        // 单记录行表（record_id PK + ON DELETE CASCADE）。working 两列同生同灭由 CHECK 强制（防半行）。
        // 只走 migration，不动 v1_4_baselineDDL / app_schema_v1.sql（v1.4 冻结基线，drift-checked）。
        migrator.registerMigration("0007_v1.9_review_archive") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS review_archive (
                    record_id INTEGER PRIMARY KEY REFERENCES training_records(id) ON DELETE CASCADE,
                    saved_drawings TEXT,
                    working_step_tick INTEGER,
                    working_drawings TEXT,
                    updated_at INTEGER NOT NULL,
                    CHECK ((working_step_tick IS NULL) = (working_drawings IS NULL))
                )
                """)
            try db.execute(sql: "PRAGMA user_version = 5")
        }
```

- [ ] **Step 4: `CONTRACT_VERSION` 1.8→1.9 + `ModelsTests` 同步**

`Models.swift`：`public let CONTRACT_VERSION = "1.9"`（找现 `"1.8"` 改）。
`ModelsTests.swift`：把断言 `CONTRACT_VERSION == "1.8"` 改 `"1.9"`。

- [ ] **Step 5: reset 只清 working 复盘、保留 saved（codex plan-R1-high）**

`resetAllTrainingProgress(toCapital:)`（`DefaultAppDB.swift:264-273`）现清 pending + pending_replay + 置资金、**保留历史记录**。review_archive 是 per-record 数据（记录留存）：**禁止整表 `DELETE`**（会丢所有已复盘存档）。按 reset 语义（清未完成对局，与清 pending_replay 对称）：在同一 `dbQueue.write` 事务里追加"清 working、保留 saved"：
```swift
                // review-redesign：reset 清未完成复盘（working），保留已保存复盘存档（saved，记录留存 → 复盘留存）
                try db.execute(sql: "UPDATE review_archive SET working_step_tick = NULL, working_drawings = NULL, updated_at = ? WHERE working_step_tick IS NOT NULL",
                               arguments: [Int64(Date().timeIntervalSince1970)])
                try db.execute(sql: "DELETE FROM review_archive WHERE working_step_tick IS NULL AND saved_drawings IS NULL")
```
先写失败**回归测试**（`ReviewArchiveRepositoryTests` 或 reset 测试）：建记录 1（saved+working）、记录 2（仅 working）、记录 3（仅 saved）→ `resetAllTrainingProgress` → 断言 1 变 `.saved`（working 清、saved 留）、2 变 `.none`（删行）、3 仍 `.saved`（不动）。**记录本身不被 reset 删除**，故 review_archive 的 FK cascade 只在真正删记录时兜底（本仓无 per-record 删除路径）。

- [ ] **Step 6a: 更新现有 `user_version == 4` 全 migrator 断言（codex plan-R10-medium）**

bump terminal `user_version` 4→5 会让**现有**测试红。grep 定位并更新：`cd ios/Contracts && grep -rn "user_version" Tests/`，把**跑完整 migrator** 后断言 `== 4` 的（如 `AppDBMigrationsTests`/`PendingReplayPersistenceTests`/`TrainingResetPortTests` 等）改为 `== 5`；**保留**专门针对"迁到 0006 中间态"的断言（本 plan 新 `upgradesExisting0006DbPreservingData` 里 `migrate(upTo: 0006)` 后断言 `==4` 是**对的**，勿改）。CONTRACT_VERSION 断言已在 Step 4 改。

- [ ] **Step 6b: 运行 filtered + **不过滤**全量 host 测**

Run: `cd ios/Contracts && swift test --filter ReviewArchiveMigrationTests && swift test --filter ModelsTests`
Run（**必须**，防遗漏现有断言）：`cd ios/Contracts && swift test`（不过滤全量）
Expected: 全绿（含所有现有 suite）。**本 task 未过全量 `swift test` 不算完成**（本地工具链宽松，见 Global Constraints；合并后仍须 `gh run watch` 确认 CI 真绿）。

- [ ] **Step 7: Commit**

```bash
git add ios/Contracts/Sources ios/Contracts/Tests
git commit -m "feat(review): migration 0007 review_archive + CONTRACT_VERSION 1.9 + reset cleanup"
```

---

## Task 2: ReviewArchive 类型 + Repository 协议 + Impl + 组合根接线

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/ReviewArchiveRepository.swift`
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/ReviewArchiveRepositoryImpl.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（conform + 委托）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift`（注入 coordinator）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（init 加 `reviewArchiveRepo` 参数，仅存字段）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/ReviewArchiveRepositoryTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ReviewMarker: Equatable, Sendable { case none, inProgress, saved }
  public struct ReviewArchive: Equatable, Sendable {
      public let recordId: Int64
      public let savedDrawings: [DrawingObject]?
      public let workingStepTick: Int?
      public let workingDrawings: [DrawingObject]?
  }
  public struct ReviewWorking: Equatable, Sendable {
      public let stepTick: Int
      public let drawings: [DrawingObject]
  }
  public protocol ReviewArchiveRepository: Sendable {
      // **独立解码（codex plan-R1-high）**：saved 与 working 解码互不牵连——saved 坏不得害有效 working。
      func loadWorking(recordId: Int64) throws -> ReviewWorking?            // 仅解码 working 两列（saved 不碰）；working 坏→.dbCorrupted
      func loadSaved(recordId: Int64) throws -> [DrawingObject]?           // 仅解码 saved 列（working 不碰）；saved 坏→.dbCorrupted
      func loadArchive(recordId: Int64) throws -> ReviewArchive?           // 全量（测试/一次性用）；coordinator 走上面两个独立解码
      func saveWorking(recordId: Int64, stepTick: Int, drawings: [DrawingObject]) throws  // 原子：两 working 列同写，saved 不动
      func commitSaved(recordId: Int64, drawings: [DrawingObject]) throws   // saved=drawings，清 working（原子）
      func clearWorking(recordId: Int64) throws                            // 清 working；若 saved 亦 NULL → DELETE 行
      func clearSaved(recordId: Int64) throws                              // 仅清 saved（corrupt 恢复）；若 working 亦 NULL → DELETE 行
      func loadMarkers() throws -> [Int64: ReviewMarker]                   // 批量轻量（不解码 payload），供首页
      func reviewMarker(recordId: Int64) throws -> ReviewMarker            // 单条轻量，供 action sheet
  }
  ```
- Consumes: `DrawingObject`（Models）、`RecordRepositoryImpl.jsonEncode/jsonDecode`、`AppError.persistence(.dbCorrupted)`、`PersistenceErrorMapping.translate`。

- [ ] **Step 1: 写 Repository 失败测试（用真实 DefaultAppDB in-memory）**

`ReviewArchiveRepositoryTests.swift`（构造一条 training_records 行满足 FK，再测状态机）：
```swift
import Testing
import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite struct ReviewArchiveRepositoryTests {
    private func makeDB() throws -> DefaultAppDB {
        let db = try DefaultAppDB(inMemory: true)   // 若无 inMemory init，用现有测试 helper（见 AppDBFixture）
        // 插一条 training_records 满足 FK（用最小列；参 RecordRepositoryImpl.insertRecord 或直接 SQL）
        try db.insertMinimalRecord(id: 1)           // 见 Step 3 note：测试 helper
        return db
    }
    private func line(_ tick: Int) -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m3, candleIndex: tick, price: 10)],
                      isExtended: false, panelPosition: 0)
    }

    @Test func emptyIsNone() throws {
        let db = try makeDB()
        #expect(try db.loadArchive(recordId: 1) == nil)
        #expect(try db.reviewMarker(recordId: 1) == .none)
    }

    @Test func saveWorkingThenInProgress() throws {
        let db = try makeDB()
        try db.saveWorking(recordId: 1, stepTick: 42, drawings: [line(5)])
        let a = try #require(try db.loadArchive(recordId: 1))
        #expect(a.workingStepTick == 42)
        #expect(a.workingDrawings == [line(5)])
        #expect(a.savedDrawings == nil)
        #expect(try db.reviewMarker(recordId: 1) == .inProgress)
    }

    @Test func commitSavedClearsWorkingAndMarksSaved() throws {
        let db = try makeDB()
        try db.saveWorking(recordId: 1, stepTick: 42, drawings: [line(5)])
        try db.commitSaved(recordId: 1, drawings: [line(5)])
        let a = try #require(try db.loadArchive(recordId: 1))
        #expect(a.savedDrawings == [line(5)])
        #expect(a.workingStepTick == nil)
        #expect(a.workingDrawings == nil)
        #expect(try db.reviewMarker(recordId: 1) == .saved)
    }

    @Test func clearWorkingKeepsSavedElseDeletesRow() throws {
        let db = try makeDB()
        // 有 saved：清 working 回退 saved
        try db.commitSaved(recordId: 1, drawings: [line(5)])
        try db.saveWorking(recordId: 1, stepTick: 9, drawings: [line(5), line(7)])
        try db.clearWorking(recordId: 1)
        #expect(try db.reviewMarker(recordId: 1) == .saved)
        // 无 saved：清 working 删行
        try db.insertMinimalRecord(id: 2)
        try db.saveWorking(recordId: 2, stepTick: 3, drawings: [line(3)])
        try db.clearWorking(recordId: 2)
        #expect(try db.loadArchive(recordId: 2) == nil)
        #expect(try db.reviewMarker(recordId: 2) == .none)
    }

    @Test func inProgressTakesMarkerPrecedenceOverSaved() throws {
        let db = try makeDB()
        try db.commitSaved(recordId: 1, drawings: [line(5)])
        try db.saveWorking(recordId: 1, stepTick: 9, drawings: [line(5), line(7)])
        #expect(try db.reviewMarker(recordId: 1) == .inProgress)   // working 非空优先
    }

    @Test func loadMarkersBatch() throws {
        let db = try makeDB(); try db.insertMinimalRecord(id: 2); try db.insertMinimalRecord(id: 3)
        try db.commitSaved(recordId: 1, drawings: [line(5)])       // saved
        try db.saveWorking(recordId: 2, stepTick: 1, drawings: [line(1)])  // inProgress
        // 3 无行
        let m = try db.loadMarkers()
        #expect(m[1] == .saved); #expect(m[2] == .inProgress); #expect(m[3] == nil)
    }

    @Test func clearSavedForCorruptRecovery() throws {
        let db = try makeDB()
        try db.commitSaved(recordId: 1, drawings: [line(5)])
        try db.clearSaved(recordId: 1)
        #expect(try db.reviewMarker(recordId: 1) == .none)         // 无 working 亦无 saved → 删行
    }

    // codex plan-R1-high：saved 损坏不得害有效 working（独立解码）
    @Test func savedCorruptionDoesNotBreakLoadWorking() throws {
        let db = try makeDB()
        try db.commitSaved(recordId: 1, drawings: [line(2)])       // 先有 saved
        try db.saveWorking(recordId: 1, stepTick: 7, drawings: [line(7)])  // 再有 working
        try db.rawWrite("UPDATE review_archive SET saved_drawings = 'not-json' WHERE record_id = 1")  // 注入坏 saved
        let w = try #require(try db.loadWorking(recordId: 1))
        #expect(w.stepTick == 7 && w.drawings == [line(7)])        // working 完好可读
        #expect(throws: AppError.self) { _ = try db.loadSaved(recordId: 1) }  // 仅 saved 报 dbCorrupted
    }
}
```
> 测试 helper `rawWrite(_:)`：test-only，`try dbQueue.write { try $0.execute(sql: sql) }` 直写坏数据（放 test 扩展）。

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter ReviewArchiveRepositoryTests`
Expected: FAIL（类型/方法不存在）。

- [ ] **Step 3: 建协议 + 值类型（`ReviewArchiveRepository.swift`）**

粘贴 Interfaces 的 `ReviewMarker` / `ReviewArchive` / `ReviewArchiveRepository`（含 doc 注释）。
> Note（测试 helper）：若 `DefaultAppDB` 无 `inMemory` init 或 `insertMinimalRecord`，在 `KlineTrainerPersistenceTests` 加一个 fileprivate/test-only helper：用现有 `AppDBFixture`（`AppDBMigrations.v1_4_baselineDDL` internal 已暴露给测试）建 in-memory DB，并用 `RecordRepositoryImpl.insertRecord` 或直接 `INSERT INTO training_records(...) VALUES(...)` 插最小合法行。参 `PendingReplayRepositoryTests` 现有 setup 复用。

- [ ] **Step 4: 建 Impl（`ReviewArchiveRepositoryImpl.swift`）——镜像 `PendingReplayRepositoryImpl`**

```swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

enum ReviewArchiveRepositoryImpl {
    // 全量：saved/working JSON 解码，失败 → .dbCorrupted（saved 损坏由 caller 走 clearSaved 恢复）
    static func loadArchive(_ db: Database, recordId: Int64) throws -> ReviewArchive? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT record_id, saved_drawings, working_step_tick, working_drawings FROM review_archive WHERE record_id = ?",
            arguments: [recordId]) else { return nil }
        let savedJSON: String? = row["saved_drawings"]
        let workJSON: String? = row["working_drawings"]
        let stepTick: Int? = row["working_step_tick"]
        do {
            let saved = try savedJSON.map { try RecordRepositoryImpl.jsonDecode($0, as: [DrawingObject].self) }
            let work = try workJSON.map { try RecordRepositoryImpl.jsonDecode($0, as: [DrawingObject].self) }
            return ReviewArchive(recordId: recordId, savedDrawings: saved,
                                 workingStepTick: stepTick, workingDrawings: work)
        } catch let e as AppError { throw e } catch { throw AppError.persistence(.dbCorrupted) }
    }

    // 独立解码：只读 + 解码 working 两列（saved 列不 SELECT/不解码）→ saved 损坏不影响本方法。
    static func loadWorking(_ db: Database, recordId: Int64) throws -> ReviewWorking? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT working_step_tick, working_drawings FROM review_archive WHERE record_id = ?",
            arguments: [recordId]) else { return nil }
        guard let stepTick = row["working_step_tick"] as Int?,
              let workJSON = row["working_drawings"] as String? else { return nil }   // 无 working
        do { return ReviewWorking(stepTick: stepTick,
                                  drawings: try RecordRepositoryImpl.jsonDecode(workJSON, as: [DrawingObject].self)) }
        catch let e as AppError { throw e } catch { throw AppError.persistence(.dbCorrupted) }
    }

    // 独立解码：只读 + 解码 saved 列（working 列不碰）→ working 损坏不影响本方法。
    static func loadSaved(_ db: Database, recordId: Int64) throws -> [DrawingObject]? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT saved_drawings FROM review_archive WHERE record_id = ?", arguments: [recordId]),
              let savedJSON = row["saved_drawings"] as String? else { return nil }
        do { return try RecordRepositoryImpl.jsonDecode(savedJSON, as: [DrawingObject].self) }
        catch let e as AppError { throw e } catch { throw AppError.persistence(.dbCorrupted) }
    }

    static func saveWorking(_ db: Database, recordId: Int64, stepTick: Int, drawings: [DrawingObject]) throws {
        let json = try RecordRepositoryImpl.jsonEncode(drawings)
        // 原子 UPSERT：两 working 列同写，saved 保留（INSERT 时 saved=NULL；已有行时用 ON CONFLICT 只改 working）
        try db.execute(sql: """
            INSERT INTO review_archive (record_id, saved_drawings, working_step_tick, working_drawings, updated_at)
            VALUES (?, NULL, ?, ?, ?)
            ON CONFLICT(record_id) DO UPDATE SET
                working_step_tick = excluded.working_step_tick,
                working_drawings = excluded.working_drawings,
                updated_at = excluded.updated_at
            """, arguments: [recordId, stepTick, json, Self.now()])
    }

    static func commitSaved(_ db: Database, recordId: Int64, drawings: [DrawingObject]) throws {
        let json = try RecordRepositoryImpl.jsonEncode(drawings)
        try db.execute(sql: """
            INSERT INTO review_archive (record_id, saved_drawings, working_step_tick, working_drawings, updated_at)
            VALUES (?, ?, NULL, NULL, ?)
            ON CONFLICT(record_id) DO UPDATE SET
                saved_drawings = excluded.saved_drawings,
                working_step_tick = NULL, working_drawings = NULL,
                updated_at = excluded.updated_at
            """, arguments: [recordId, json, Self.now()])
    }

    static func clearWorking(_ db: Database, recordId: Int64) throws {
        try db.execute(sql: """
            UPDATE review_archive SET working_step_tick = NULL, working_drawings = NULL, updated_at = ?
            WHERE record_id = ?
            """, arguments: [Self.now(), recordId])
        try db.execute(sql: "DELETE FROM review_archive WHERE record_id = ? AND saved_drawings IS NULL",
                       arguments: [recordId])
    }

    static func clearSaved(_ db: Database, recordId: Int64) throws {
        try db.execute(sql: "UPDATE review_archive SET saved_drawings = NULL, updated_at = ? WHERE record_id = ?",
                       arguments: [Self.now(), recordId])
        try db.execute(sql: "DELETE FROM review_archive WHERE record_id = ? AND working_step_tick IS NULL",
                       arguments: [recordId])
    }

    static func loadMarkers(_ db: Database) throws -> [Int64: ReviewMarker] {
        var out: [Int64: ReviewMarker] = [:]
        let rows = try Row.fetchAll(db, sql:
            "SELECT record_id, saved_drawings, working_step_tick FROM review_archive")
        for row in rows {
            let id: Int64 = row["record_id"]
            let hasWorking = (row["working_step_tick"] as Int?) != nil
            let hasSaved = (row["saved_drawings"] as String?) != nil
            out[id] = hasWorking ? .inProgress : (hasSaved ? .saved : Optional<ReviewMarker>.none) ?? .none
        }
        return out.filter { $0.value != .none }   // 全 NULL 异常行不返回
    }

    static func reviewMarker(_ db: Database, recordId: Int64) throws -> ReviewMarker {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT saved_drawings, working_step_tick FROM review_archive WHERE record_id = ?",
            arguments: [recordId]) else { return .none }
        if (row["working_step_tick"] as Int?) != nil { return .inProgress }
        if (row["saved_drawings"] as String?) != nil { return .saved }
        return .none
    }

    // now(): epoch 秒。注入点参 RecordRepositoryImpl 的 now 约定；若无，用 Int64(Date().timeIntervalSince1970)。
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
}
```
> Note：`ON CONFLICT(record_id) DO UPDATE`（SQLite UPSERT）要求 `record_id` 是 PRIMARY KEY（是）。`Self.now()` 的时钟注入非关键（updated_at 仅信息列）；若项目禁 `Date()` 于纯层，本 Impl 在 Persistence 层允许（GRDB 层已用系统时钟）。

- [ ] **Step 5: `DefaultAppDB` conform + 委托（镜像 replay 段）**

类声明追加 `, ReviewArchiveRepository`；加一段（复制 replay 的 do/catch translate 范式，每方法 `dbQueue.write`/`read` 包 `ReviewArchiveRepositoryImpl.xxx`）：
```swift
    // MARK: - ReviewArchiveRepository
    public func loadArchive(recordId: Int64) throws -> ReviewArchive? {
        do { return try dbQueue.read { try ReviewArchiveRepositoryImpl.loadArchive($0, recordId: recordId) } }
        catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }
    public func saveWorking(recordId: Int64, stepTick: Int, drawings: [DrawingObject]) throws {
        do { try dbQueue.write { try ReviewArchiveRepositoryImpl.saveWorking($0, recordId: recordId, stepTick: stepTick, drawings: drawings) } }
        catch let e as AppError { throw e } catch { throw PersistenceErrorMapping.translate(error) }
    }
    // ...loadWorking / loadSaved / commitSaved / clearWorking / clearSaved / loadMarkers / reviewMarker 同范式（write for mutations, read for queries）
```

- [ ] **Step 6: coordinator init 加参数 + AppContainer 注入**

`TrainingSessionCoordinator.init`：在 `pendingReplayRepo:` 后加参数 `reviewArchiveRepo: ReviewArchiveRepository`，存 `self.reviewArchiveRepo = reviewArchiveRepo`（加 `private let reviewArchiveRepo: ReviewArchiveRepository` 字段）。
`AppContainer.swift` 构造 coordinator 处加 `reviewArchiveRepo: db,`（db 已 conform）。

- [ ] **Step 7: 运行测试 + Catalyst 编译**

Run: `cd ios/Contracts && swift test --filter ReviewArchiveRepositoryTests`
Expected: PASS。
Run（编译闸门）：Catalyst `build-for-testing`（见 Global Constraints）。Expected: BUILD SUCCEEDED。

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources ios/Contracts/Tests
git commit -m "feat(review): ReviewArchiveRepository (protocol+impl+wiring) mirroring replay"
```

---

## Task 3: ReviewLedger 纯折叠组件

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/ReviewLedger.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ReviewLedgerTests.swift`

**Interfaces:**
- Produces: `ReviewLedgerState { cash; shares; averageCost; totalCapital; returnRate; positionTier }` + `static func state(atTick:ops:initialCapital:markPriceAtTick:) throws -> ReviewLedgerState`。
- **fail-closed（codex plan-R3/R6/R9-high/medium）**：折叠**从不**把未校验 op 喂给 `PositionManager.buy/sell`（有 precondition 会 trap）。**方向感知**校验（**非**对所有 op 一刀切 totalCost>=0）：
  - **公共**：`shares > 0`、`price/commission/stampDuty` 均 finite 且 `>= 0`。
  - **buy 分支**：`totalCost` finite 且 **`> 0`**（`PositionManager.buy` 前置）+ 加法后 `totalInvested` 有限 + Int 防溢出。
  - **sell 分支**：`shares <= 当前持仓`（防 oversell/sell-before-buy）。**不对 sell 校验 `totalCost>=0`**——sell 的 `totalCost=proceeds` 引擎允许**为负**（低价清仓/force-close，只要 cash+proceeds≥0，见 `quoteSell` 语义）；ReviewLedger sell 现金增量自 `price*shares−commission−stampDuty` 计算（= 存储 proceeds），负值合法。
  - 任一违反 → `throw AppError.persistence(.dbCorrupted)`。
- Consumes: `TradeOperation`（`globalTick/direction/price/shares/commission/stampDuty/totalCost/createdAt`）、`PositionManager`、`AppError`。

- [ ] **Step 1: 写失败测试（确定性手算值）**

`ReviewLedgerTests.swift`：
```swift
import Testing
import KlineTrainerContracts

@Suite struct ReviewLedgerTests {
    private func op(_ tick: Int, _ dir: TradeDirection, price: Double, shares: Int,
                    commission: Double, stampDuty: Double, totalCost: Double) -> TradeOperation {
        TradeOperation(globalTick: tick, period: .m3, direction: dir, price: price, shares: shares,
                       positionTier: .tier1, commission: commission, stampDuty: stampDuty,   // ReviewLedger 忽略 positionTier；用合法 case（无 .zero）
                       totalCost: totalCost, createdAt: Int64(tick))
    }
    // 价：tick<10→10.00，>=10→12.00（含 clamp 语义由 caller 提供的闭包决定）
    private let price: (Int) -> Double = { $0 < 10 ? 10.00 : 12.00 }

    @Test func beforeAnyTradeIsFlat() throws {
        let s = try ReviewLedger.state(atTick: 4, ops: [], initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 0); #expect(s.cash == 100_000); #expect(s.totalCapital == 100_000)
        #expect(s.returnRate == 0); #expect(s.positionTier == 0)
    }

    @Test func afterBuyRunningValueTracks() throws {
        // buy 100 @10, commission 5, totalCost 1005, tick 5
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005)]
        let s = try ReviewLedger.state(atTick: 5, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 100)
        #expect(s.cash == 98_995)                 // 100000 - 1005
        #expect(s.averageCost == 10.05)           // 1005/100
        #expect(s.totalCapital == 99_995)         // 98995 + 100*10
        #expect(abs(s.returnRate - (-5.0/100_000)) < 1e-12)
    }

    @Test func opsWithFutureTickExcluded() throws {
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                   op(10, .sell, price: 12, shares: 100, commission: 6, stampDuty: 0.6, totalCost: 1200)]
        // at tick 8：只应用 buy（sell 在 tick 10 > 8）
        let s = try ReviewLedger.state(atTick: 8, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 100)
    }

    @Test func afterSellRealizes() throws {
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                   op(10, .sell, price: 12, shares: 100, commission: 6, stampDuty: 0.6, totalCost: 1200)]
        let s = try ReviewLedger.state(atTick: 10, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 0)
        // cash = 98995 + (12*100 - 6 - 0.6) = 98995 + 1193.4 = 100188.4
        #expect(abs(s.cash - 100_188.4) < 1e-9)
        #expect(abs(s.totalCapital - 100_188.4) < 1e-9)   // 0 仓 → 全现金
    }

    // codex plan-R3-high：损坏 ops 必须 fail-closed（throw .dbCorrupted），绝不 trap PositionManager
    @Test func corruptOpsThrowDBCorrupted() {
        func expectCorrupt(_ ops: [TradeOperation]) {
            #expect(throws: AppError.self) { _ = try ReviewLedger.state(atTick: 99, ops: ops, initialCapital: 100_000, markPriceAtTick: price) }
        }
        expectCorrupt([op(5, .sell, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005)])           // sell-before-buy
        expectCorrupt([op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                       op(6, .sell, price: 10, shares: 200, commission: 5, stampDuty: 0, totalCost: 1000)])          // oversell
        expectCorrupt([op(5, .buy, price: 10, shares: 0, commission: 5, stampDuty: 0, totalCost: 1005)])              // zero shares
        expectCorrupt([op(5, .buy, price: .nan, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005)])         // non-finite price
        expectCorrupt([op(5, .buy, price: 10, shares: -5, commission: 5, stampDuty: 0, totalCost: 1005)])            // negative shares
        expectCorrupt([op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 0)])             // 零成本 buy（PositionManager.buy 前置 totalCost>0，codex plan-R6-high）
        expectCorrupt([op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: .infinity)])     // 非有限 totalCost
        expectCorrupt([op(5, .buy, price: 1, shares: 1, commission: 0, stampDuty: 0, totalCost: .greatestFiniteMagnitude),
                       op(6, .buy, price: 1, shares: 1, commission: 0, stampDuty: 0, totalCost: .greatestFiniteMagnitude)])  // 累加 totalInvested 溢出 inf
        expectCorrupt([op(5, .buy, price: 1, shares: 1_000_000_000, commission: 0, stampDuty: 0, totalCost: 1_000_000_000),
                       op(6, .sell, price: 1e300, shares: 1_000_000_000, commission: 0, stampDuty: 0, totalCost: 1)])  // sell notional 1e300*1e9→inf（codex plan-R11-high）
    }

    // codex plan-R4-high：同 tick 的 buy→sell（插入序）不得被排序打乱成 sell→buy（否则误判 oversell）
    @Test func sameTickBuyThenSellKeepsInsertionOrder() throws {
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                   op(5, .sell, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1000)]  // 同 tick 5，插入序 buy 先
        let s = try ReviewLedger.state(atTick: 5, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 0)   // buy 后 sell → 平；若被排成 sell 先则会 throw oversell
    }

    // codex plan-R9-medium：sell 的 proceeds(=totalCost) 允许为负（低价清仓/force-close），不得判损坏
    @Test func negativeSellProceedsIsValidNotCorrupt() throws {
        let ops = [op(5, .buy, price: 10, shares: 100, commission: 5, stampDuty: 0, totalCost: 1005),
                   op(10, .sell, price: 0.01, shares: 100, commission: 5, stampDuty: 0, totalCost: -4)]  // proceeds=0.01*100-5 = -4（负、合法）
        let s = try ReviewLedger.state(atTick: 10, ops: ops, initialCapital: 100_000, markPriceAtTick: price)
        #expect(s.shares == 0)
        #expect(abs(s.cash - 98_991) < 1e-9)   // 98995 + (1 - 5) = 98991 ≥ 0 → 合法，不 throw
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter ReviewLedgerTests`
Expected: FAIL（`ReviewLedger` 未定义）。

- [ ] **Step 3: 实现 `ReviewLedger.swift`**

```swift
import Foundation

public struct ReviewLedgerState: Equatable, Sendable {
    public let cash: Double
    public let shares: Int
    public let averageCost: Double
    public let totalCapital: Double
    public let returnRate: Double
    public let positionTier: Int
}

/// 平台无关纯折叠：给定已记录 ops，重算截至某 global tick 的运行账户。
/// mark price 由 caller 注入（生产 = engine.markPrice(atTick:)，.m3 收盘、越界 clamp、非 nil）。
/// fail-closed（codex plan-R3-high）：损坏/非法 op 序列 → throw .dbCorrupted，**绝不** trap PositionManager。
/// 一致性：在记录 finalTick 处 profit/returnRate 逐位等于 record.profit/returnRate（复用引擎同款算术）。
public enum ReviewLedger {
    public static func state(atTick t: Int,
                             ops: [TradeOperation],
                             initialCapital: Double,
                             markPriceAtTick: (Int) -> Double) throws -> ReviewLedgerState {
        var position = PositionManager()
        var cash = initialCapital
        // 排序 tiebreaker = **仓库插入序（原始下标）**（codex plan-R4-high）：同 tick 的 buy/sell 必须保记录时序，
        // 否则同 createdAt 时 Swift 非稳定 sort 可能把 sell 排到 buy 前 → 误判 oversell。插入序=记录时序（时间单调）。
        let applicable = ops.enumerated()
            .filter { $0.element.globalTick <= t }
            .sorted { $0.element.globalTick != $1.element.globalTick ? $0.element.globalTick < $1.element.globalTick : $0.offset < $1.offset }
            .map { $0.element }
        for op in applicable {
            // fail-closed 校验：先验后用，杜绝 PositionManager precondition trap（codex plan-R3/R6-high）
            guard op.shares > 0,
                  op.price.isFinite, op.price >= 0,
                  op.commission.isFinite, op.commission >= 0,
                  op.stampDuty.isFinite, op.stampDuty >= 0
            else { throw AppError.persistence(.dbCorrupted) }
            switch op.direction {
            case .buy:
                // PositionManager.buy 前置 totalCost 有限且 **>0**（非 >=0）；且预检加法溢出（totalInvested→inf）+ Int 溢出
                guard op.totalCost.isFinite, op.totalCost > 0,
                      (position.totalInvested + op.totalCost).isFinite,
                      op.shares <= Int.max - position.shares
                else { throw AppError.persistence(.dbCorrupted) }
                position.buy(shares: op.shares, totalCost: op.totalCost)
                cash -= op.totalCost
            case .sell:
                guard op.shares <= position.shares else { throw AppError.persistence(.dbCorrupted) }  // oversell / sell-before-buy
                // 现金流有限性守卫（codex plan-R11-high）：finite 但极端值 price*shares 可能溢出 inf/NaN
                let notional = op.price * Double(op.shares)
                let proceeds = notional - op.commission - op.stampDuty   // proceeds 可为负（合法，R9），但须有限
                let newCash = cash + proceeds
                guard notional.isFinite, proceeds.isFinite, newCash.isFinite else { throw AppError.persistence(.dbCorrupted) }
                position.sell(shares: op.shares)
                cash = newCash
            }
        }
        let price = markPriceAtTick(t)
        let holdingValue = Double(position.shares) * price
        let total = cash + holdingValue
        guard holdingValue.isFinite, total.isFinite else { throw AppError.persistence(.dbCorrupted) }  // 末尾有限性守卫（codex plan-R11-high）
        let rate = initialCapital == 0 ? 0 : (total - initialCapital) / initialCapital
        let tier: Int
        if total > 0, total.isFinite, holdingValue.isFinite {
            let raw = (holdingValue / total * 5).rounded(.toNearestOrAwayFromZero)
            tier = min(max(Int(raw), 0), 5)
        } else { tier = 0 }
        return ReviewLedgerState(cash: cash, shares: position.shares, averageCost: position.averageCost,
                                 totalCapital: total, returnRate: rate, positionTier: tier)
    }
}
```
> Note（cash 约定校验）：buy 用 `op.totalCost`（= notional+commission，现金流出）；sell 用 `price*shares − commission − stampDuty`（现金流入）。**若测试 4 失败**，读 `TrainingEngine` 的 buy/sell 现金更新（grep `cashBalance -=`/`cashBalance +=`）核对 `op.totalCost` 的真实构造并对齐。

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter ReviewLedgerTests`
Expected: PASS。

- [ ] **Step 5: 加"终局等式 oracle" mutation 测试**

追加一个测试：构造一段 ops + 常数价，手算 finalTick 的 profit，断言 `state(atTick: finalTick).totalCapital - initialCapital == 手算 profit`；再改一个 op 的 totalCost（mutation）断言不等（证明测试非空洞）。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/ReviewLedger.swift ios/Contracts/Tests/KlineTrainerContractsTests/ReviewLedgerTests.swift
git commit -m "feat(review): ReviewLedger pure fold (running P&L) + oracle/mutation tests"
```

---

## Task 4: `stepReviewForward(panel:)` 引擎重载

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（新增按面板步进 + 保留旧 auto 语义作 fallback）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/`（新增或并入 engine 测试）

**Interfaces:**
- Produces: `public func stepReviewForward(panel: PanelId)` —— 步进指定面板一根；该面板已耗尽则步进另一面板；皆耗尽 no-op。旧无参 `stepReviewForward()` 保留（内部委托较细面板）以不破坏现有测试。

- [ ] **Step 1: 写失败测试**

新增测试：构造 review engine（用 `.preview()` 或现有 review 测试 fixture），记录初始 `tick.globalTickIndex`，调 `stepReviewForward(panel: .lower)`（较粗）与 `.upper`（较细），断言两者步长不同（粗周期一步 tick 增量 > 细周期）。参现有 `stepReviewForward` 测试（grep `stepReviewForward` in Tests）复用 fixture。

- [ ] **Step 2: 运行确认失败**（方法不存在）

- [ ] **Step 3: 实现**（`TrainingEngine.swift`，在现 `stepReviewForward()` 旁）

```swift
/// 复盘按指定面板步进一根（红框所选周期）。该面板已到末尾则步进另一面板；皆耗尽=到结尾 no-op。
public func stepReviewForward(panel requested: PanelId) {
    let requestedSteps = stepsForPeriod(requested == .upper ? upperPanel.period : lowerPanel.period)
    if requestedSteps > 0 {
        holdOrObserve(panel: requested); return
    }
    let other: PanelId = requested == .upper ? .lower : .upper
    let otherSteps = stepsForPeriod(other == .upper ? upperPanel.period : lowerPanel.period)
    if otherSteps > 0 { holdOrObserve(panel: other) }   // 所选耗尽 → 用另一面板；皆耗尽 → no-op
}
```
> `stepsForPeriod` 是现有 private helper（`stepReviewForward()` 已用）。保留无参版本不动。

- [ ] **Step 4: 运行确认通过 + 现有 engine 测试不回归**

Run: `cd ios/Contracts && swift test --filter TrainingEngine`（或相关 suite）
Expected: PASS，旧 `stepReviewForward()` 测试仍绿。

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(review): stepReviewForward(panel:) — step selected (red-frame) panel period"
```

---

## Task 5: coordinator 复盘持久化核心（committed 基线 + 净改动判定）

**Files:**
- Modify: `TrainingSessionCoordinator.swift`（新增复盘 session 态 + 持久化方法）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ReviewPersistenceTests.swift`（用 in-memory DefaultAppDB 经 coordinator）

**Interfaces:**
- Produces（coordinator 方法）：
  ```swift
  func hasReviewInProgress(recordId: Int64) -> Bool                 // reviewMarker == .inProgress（try? 兜底 false）
  func loadReviewMarkers() -> [Int64: ReviewMarker]                 // try? 兜底 [:]
  // 复盘 session 内（committed 基线 + 净改动）：
  func reviewNetChanged() -> Bool                                   // 当前 reviewDrawings vs committed 基线
  func persistReviewWorkingIfChanged(engine:) throws               // 有净改动→saveWorking(tick,reviewDrawings)；无→clearWorking（回退）
  func commitReview(engine:) throws                                 // saved=reviewDrawings，清 working
  func discardReviewWorking(engine:) throws                        // 清 working（回退 saved/删行）
  ```
- Coordinator 内新增 review session 态：`reviewCommittedBaseline: [DrawingObject]`（进入时 = saved ?? []）、`reviewRecordId: Int64?`。

- [ ] **Step 1: 写失败测试（状态机 + committed 基线回退）**

`ReviewPersistenceTests.swift`（构造 coordinator，模拟"进入→画线→返回→再进→删回→返回"）：
```swift
// 关键断言：
// 1) 进入 none 记录 → 画一条 → persistReviewWorkingIfChanged → reviewMarker==.inProgress
// 2) 进入 saved 记录（committed=saved）→ 不动 → persistReviewWorkingIfChanged → clearWorking → reviewMarker==.saved
// 3) 进入 saved → 画一条(≠saved) → persist → .inProgress；再删回=saved → persist → .saved（committed 基线回退，codex R5-high）
// 4) commitReview → .saved 且 saved==reviewDrawings；discardReviewWorking(有saved) → .saved
```
> 实现细节：测试直接调 coordinator 的 review 方法 + 用一个 test-only 钩子设置 `engine.reviewDrawings`（Task 10 加）。若 Task 10 未落，先用 coordinator 方法签名接收 `drawings: [DrawingObject]` 参数版本测试（`persistReviewWorkingIfChanged(recordId:stepTick:drawings:committedBaseline:)` 纯逻辑），把"vs committed"判定抽为可测纯函数 `ReviewNetChange.changed(working:committed:) -> Bool`（值相等比较，顺序无关用 multiset/排序比较）。

- [ ] **Step 2: 抽纯函数 `ReviewNetChange`（放 `ReviewArchiveRepository.swift` 或新文件）+ 测试**

```swift
public enum ReviewNetChange {
    /// 净改动 = 工作画线集与 committed 基线不等（顺序无关：按稳定序列化比较）。
    public static func changed(working: [DrawingObject], committed: [DrawingObject]) -> Bool {
        func key(_ d: DrawingObject) -> String {
            // 稳定序：toolType|panel|isExtended|anchors(period,candleIndex,price)
            let a = d.anchors.map { "\($0.period.rawValue):\($0.candleIndex):\($0.price)" }.joined(separator: ";")
            return "\(d.toolType.rawValue)|\(d.panelPosition)|\(d.isExtended)|\(a)"
        }
        return working.map(key).sorted() != committed.map(key).sorted()
    }
}
```
测试：空 vs 空=false；[line5] vs 空=true；[line5] vs [line5]=true?→false；[line5,line7] vs [line7,line5]=false（顺序无关）。

- [ ] **Step 3: 运行确认失败 → 实现 coordinator 方法 → 通过**

在 coordinator 实现：
```swift
private var reviewRecordId: Int64?
private var reviewCommittedBaseline: [DrawingObject] = []

public func hasReviewInProgress(recordId: Int64) -> Bool {
    ((try? reviewArchiveRepo.reviewMarker(recordId: recordId)) ?? .none) == .inProgress
}
public func loadReviewMarkers() -> [Int64: ReviewMarker] {
    (try? reviewArchiveRepo.loadMarkers()) ?? [:]
}
public func persistReviewWorkingIfChanged(engine: TrainingEngine) throws {
    guard let id = reviewRecordId else { return }
    if ReviewNetChange.changed(working: engine.reviewDrawings, committed: reviewCommittedBaseline) {
        try reviewArchiveRepo.saveWorking(recordId: id, stepTick: engine.tick.globalTickIndex, drawings: engine.reviewDrawings)
    } else {
        try reviewArchiveRepo.clearWorking(recordId: id)   // 回退到 committed（saved 或删行）
    }
}
public func commitReview(engine: TrainingEngine) throws {
    guard let id = reviewRecordId else { return }
    try reviewArchiveRepo.commitSaved(recordId: id, drawings: engine.reviewDrawings)
    reviewCommittedBaseline = engine.reviewDrawings   // 提交后基线前移
}
public func discardReviewWorking(engine: TrainingEngine) throws {
    guard let id = reviewRecordId else { return }
    try reviewArchiveRepo.clearWorking(recordId: id)
}
```
（`reviewRecordId`/`reviewCommittedBaseline` 在 Task 6 的 `review()`/`resumePendingReview()` 里设置。本 task 可先用 test-only setter 注入。）

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(review): coordinator review-persistence core + committed-baseline net-change"
```

---

## Task 6: coordinator resumePendingReview + review() 基线 + saved 损坏恢复

**Files:**
- Modify: `TrainingSessionCoordinator.swift`（`review(recordId:)` 载 saved/working 基线；新增 `resumePendingReview(recordId:)`；saved 损坏恢复）
- Test: 并入 `ReviewPersistenceTests.swift`

**Interfaces:**
- Produces: `func resumePendingReview(recordId: Int64) async throws -> TrainingEngine?`（resume-first：命中 in_progress → 从 `working_step_tick` 起 + 载 `working_drawings` 到 `engine.reviewDrawings`，committed 基线 = saved ?? []）；`review(recordId:)` 改造：进入时 `reviewRecordId=id`、`reviewCommittedBaseline = saved ?? []`、`engine.reviewDrawings = saved ?? []`；saved 解码 `.dbCorrupted` → `clearSaved` + toast 语义（返回一个标志或经 error 通道）+ 空基线继续。

- [ ] **Step 1: 写失败测试**
  - `resumePendingReview` 命中 in_progress → engine.tick == working_step_tick 且 engine.reviewDrawings == working_drawings；未命中 → nil。
  - `review()` 对 saved 记录 → engine.reviewDrawings == saved、committed 基线 == saved。
  - saved 损坏（注入坏 JSON 到 review_archive.saved_drawings）→ `review()` 不抛致命、reviewMarker 变 none、engine.reviewDrawings == []。
  - **saved 坏 且 `clearSaved` 抛（注入"clearSaved 失败"的 repo 替身）→ `review(recordId:)` 抛（可重试）、**不**以空基线开界面、坏 saved 行仍在**（codex plan-R4-high）。

- [ ] **Step 2: 实现 `resumePendingReview`（镜像 replay resume-first）**

```swift
public func resumePendingReview(recordId: Int64) async throws -> TrainingEngine? {
    guard ((try? reviewArchiveRepo.reviewMarker(recordId: recordId)) ?? .none) == .inProgress else { return nil }
    // working 独立解码（codex plan-R1-high）：working 坏 → 仅清 working、回退从头（不碰 saved）
    let working: ReviewWorking?
    do { working = try reviewArchiveRepo.loadWorking(recordId: recordId) }
    catch let e as AppError where e.isDBCorrupted {
        try reviewArchiveRepo.clearWorking(recordId: recordId); return nil
    }
    guard let w = working else { return nil }                     // 竞态：刚被清 → nil（router 从头）
    let baseline = try loadCommittedBaselineRecovering(recordId: recordId)   // saved 坏 → 仅清 saved + toast，保住有效 working
    return try await buildReviewEngine(recordId: recordId, startTickOverride: w.stepTick,
                                       reviewDrawings: w.drawings, committedBaseline: baseline)
}

/// committed 基线 = saved（独立解码）；saved 坏 → clearSaved + toast + ∅（**保 working 不动**，codex plan-R1-high）。
/// clearSaved 失败**不吞**（codex plan-R4-high）：只有清库成功才回退空基线+toast；清库失败 rethrow →
/// review 入口失败（`setError` 可重试），**绝不**在坏 saved 仍在库时以假空基线开界面。
private func loadCommittedBaselineRecovering(recordId: Int64) throws -> [DrawingObject] {
    do { return try reviewArchiveRepo.loadSaved(recordId: recordId) ?? [] }
    catch let e as AppError where e.isDBCorrupted {
        try reviewArchiveRepo.clearSaved(recordId: recordId)   // 失败即 throw（不 try?），review 不开
        self.pendingReviewCorruptToast = true
        return []
    }
}
```
把现 `review(recordId:)` 的引擎构造抽为 `private func buildReviewEngine(recordId:startTickOverride:reviewDrawings:committedBaseline:)`，`review()` 调用它时 `startTickOverride=nil`（用 meta.startDatetime 派生的 startTick）、`reviewDrawings = baseline`、`committedBaseline = baseline`（baseline 由 `loadCommittedBaselineRecovering` 得，saved 坏已恢复为 ∅）。buildReviewEngine 里设 `self.reviewRecordId = recordId; self.reviewCommittedBaseline = committedBaseline; engine.setReviewDrawings(reviewDrawings)`（Task 10 加 setter/init 入参）。

**入口 ops 校验 + 终局等式强制（codex plan-R3-high / R5-high）**：buildReviewEngine 构造 engine 后、返回前，折叠一次到末 tick 并**强制重算终局 == 记录终局**（review 引擎 `tick.maxTick == record.finalTick`，见现 make 语义）：
```swift
let finalState = try ReviewLedger.state(atTick: engine.tick.maxTick, ops: engine.tradeOperations,
                                        initialCapital: engine.initialCapital,
                                        markPriceAtTick: { engine.markPrice(atTick: $0) })
// 显式容差（FP 折叠序噪声 ~1e-9 相对；毛损坏必远超）：profit 绝对 1e-4 元、rate 绝对 1e-7
guard abs((finalState.totalCapital - engine.initialCapital) - record.profit) <= 1e-4,
      abs(finalState.returnRate - record.returnRate) <= 1e-7
else { reader.close(); throw AppError.persistence(.dbCorrupted) }
```
throw（损坏 op 序列或终局不符）→ `reader.close()` + 抛 `.dbCorrupted`（review 入口失败，`AppRouter.review(id:)` catch → `setError`、**不开复盘界面、不崩**）。这样顶栏每帧 `ReviewLedger.state` 可 `try?`（入口已验，永不兜底），杜绝逐帧 trap。
测试：① oversell/负股数/非有限记录 → `review(recordId:)` 抛 `.dbCorrupted`（不崩）；② **totalCost 与真实不一致（终局对不上）的记录 → 抛 `.dbCorrupted`**；③ 用真实/构造的一致记录 → `review()` 成功且 `finalState.profit ≈ record.profit`（finalTick 等式）。

- [ ] **Step 3: saved 损坏恢复（buildReviewEngine 用共享 helper，独立解码）**

`buildReviewEngine` 内载 saved 基线一律经 Step 2 的 `loadCommittedBaselineRecovering(recordId:)`（**只解码 saved**，working 不碰）：saved 坏 → `clearSaved` + `pendingReviewCorruptToast=true` + ∅ 基线继续。fresh `review()` 的 `reviewDrawings` 与 `committedBaseline` 都用该 baseline。
（`AppError.isDBCorrupted` 若无，加 helper `var isDBCorrupted: Bool { if case .persistence(.dbCorrupted) = self { return true }; return false }`。`pendingReviewCorruptToast` 为 coordinator `@Published`/普通 flag，UI（TrainingView.onAppear 或 AppRouter）读后清、经现有 toast 壳呈现「复盘存档损坏已清除，可重新复盘保存」。）

- [ ] **Step 4: 运行测试通过 + Commit**

```bash
git commit -am "feat(review): resumePendingReview + review() committed baseline + corrupt-saved recovery"
```

---

## Task 7: 复盘 autosave 单写者 fence（顺序/token/revision）

**Files:**
- Modify: `TrainingSessionCoordinator.swift`（review autosave 节流 + token/revision + drain）
- Modify: `UI/TrainingSessionLifecycle.swift`（暴露 review autosave/终态入口）
- Test: `ReviewPersistenceTests.swift`（延迟替身：终态 last-wins）

**Interfaces:**
- Produces（lifecycle）：`func autosaveReview(engine:)`（节流，画线/步进触发）、`func backReview(engine:) async throws`（drain → persistReviewWorkingIfChanged → endSession）、`func endReviewSave(engine:) async throws`（drain → commitReview → endSession）、`func endReviewDiscard(engine:) async throws`（drain → discardReviewWorking → endSession）。
- Coordinator 持 review autosave 态：`reviewSessionToken: UUID?`、`reviewRevision: Int`、`reviewAutosaveTask: Task<Void,Never>?`；每次进入复盘 mint 新 token；节流写携带 (token, revision)，写前比对当前 token/revision，陈旧丢弃；终态先 `cancel + await drain` 再权威写。

- [ ] **Step 1: 写失败测试（延迟替身）**

用一个 `SlowReviewArchiveRepo`（包装真 repo，saveWorking 前 `await Task.yield()` 多次模拟延迟），断言：快速多次 autosaveReview 后立即 backReview → 最终 review_archive 的 working == 最后一次状态（不被迟到写覆盖）；旧 token 的写被丢弃（token 变更后调用返回早退）。

- [ ] **Step 2: 实现 fence（镜像 replay autosave 的 terminating/dirty/coalesce）**

参 `TrainingSessionCoordinator` 现 replay autosave（`terminating` flag + dirty + cadence，L64-120）。review 版：
```swift
private var reviewSessionToken: UUID?
private var reviewRevision = 0
// autosaveReview：递增 revision，调度节流 Task，Task 内比对 token/revision 后 persistReviewWorkingIfChanged
// backReview/endReviewSave/endReviewDiscard：先 invalidate token（reviewSessionToken = nil）+ cancel 节流 Task，
//   再同步执行终态写（persist/commit/discard），保证 last-wins。
```
> 因 coordinator 是 @MainActor（单写者天然串行），token/revision 主要挡"上一会话的迟到 Task"。终态 invalidate token 后，迟到 Task 比对失败即早退。

- [ ] **Step 3: lifecycle 暴露 review 终态入口 + Step 1 测试通过**

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(review): single-writer autosave fence (token/revision/drain) — terminal last-wins"
```

---

## Task 8: ReviewControlBar 重设计（训练底栏样式，2 键 + 分段器 + 下单价）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/ReviewControlBar.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ReviewControlBarContentTests.swift`

**Interfaces:**
- Produces: `ReviewControlBarContent`（纯值）新增 `priceLabel: String`（复用 `TradeActionBarContent` 的 `"下单价 ¥ X.XX"` 格式）+ 保留 `buttons`（下一根 [+快进到结尾]）；`ReviewControlBar` 视图新增 `upperPeriod/lowerPeriod/activePanel binding/onStep/onJumpToEnd`，布局 = `[上图|下图]分段器(width104) + 下单价 + 下一根 + 快进到结尾`（`.bordered`、下一根 tint 蓝强调）。

- [ ] **Step 1: 写 content 失败测试**

```swift
@Test func priceLabelFormat() {
    let c = ReviewControlBarContent(showsJumpToEnd: true, price: 1718.0)
    #expect(c.priceLabel == "下单价 ¥ 1,718.00")
    #expect(c.buttons.map(\.title) == ["下一根", "快进到结尾"])
}
@Test func singleButtonWhenNoJump() {
    let c = ReviewControlBarContent(showsJumpToEnd: false, price: 10)
    #expect(c.buttons.map(\.title) == ["下一根"])
}
```

- [ ] **Step 2: 运行确认失败 → 扩 `ReviewControlBarContent`**

给 `ReviewControlBarContent` 加 `public let priceLabel: String` + `init(showsJumpToEnd:price:)`（价格格式复刻 `TradeActionBarContent.init(price:)` 的 formatter；可提取共享 static 或复制 8 行 formatter，沿用项目"避免 sibling 耦合"惯例=复制）。保留原 `init(showsJumpToEnd:)`? 改为新增 price 参数（更新调用点）。

- [ ] **Step 3: 重设计 `ReviewControlBar` 视图（`#if canImport(UIKit)`）**

```swift
public struct ReviewControlBar: View {
    private let content: ReviewControlBarContent
    let upperPeriod: Period
    let lowerPeriod: Period
    @Binding var activePanel: PanelId
    private let onAction: (ReviewControlAction) -> Void
    public init(showsJumpToEnd: Bool, price: Double, upperPeriod: Period, lowerPeriod: Period,
                activePanel: Binding<PanelId>, onAction: @escaping (ReviewControlAction) -> Void) { ... }
    public var body: some View {
        HStack(spacing: 8) {
            Picker("步进周期", selection: $activePanel) {
                Text(upperPeriod.shortLabel).tag(PanelId.upper)
                Text(lowerPeriod.shortLabel).tag(PanelId.lower)
            }.pickerStyle(.segmented).frame(width: 104).accessibilityLabel("步进周期")
            Text(content.priceLabel).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            ForEach(content.buttons, id: \.action) { btn in
                Button(btn.title) { onAction(btn.action) }
                    .frame(maxWidth: .infinity)
                    .tint(btn.action == .step ? .blue : nil)   // 下一根强调
            }
        }
        .buttonStyle(.bordered).controlSize(.regular).font(.system(size: 14).weight(.semibold))
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity).background(.bar, ignoresSafeAreaEdges: .bottom)
    }
}
```

- [ ] **Step 4: content 测试通过 + Catalyst 编译**（调用点 Task 10 更新；本 task 若破坏现 `TrainingView` 调用，用临时兼容或在 Task 10 一并接线——建议本 task 只改 content + 视图签名，`TrainingView` 调用点更新放 Task 10，故本 task 结束时 Catalyst 可能需 Task 10 才编译。**决策：把 `TrainingView` 现 `ReviewControlBar(...)` 调用点最小更新纳入本 task Step 5**，避免中间不可编译。）

- [ ] **Step 5: 更新 `TrainingView` 现调用点（最小）**

`TrainingView.swift:98-106` 的 `ReviewControlBar(showsJumpToEnd:)` 改为新签名（传 `price: engine.currentPrice, upperPeriod:, lowerPeriod:, activePanel: $activePanel, onAction:`，`.step` 分支改 `engine.stepReviewForward(panel: activePanel)`）。

- [ ] **Step 6: Commit**

```bash
git commit -am "feat(review): ReviewControlBar redesign (segmented+price+2 keys, step selected panel)"
```

---

## Task 9: 复盘顶栏读 ReviewLedger（去 R4 隐藏）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift`（新增按 ReviewLedger 值构造的路径 / 或保留 init 由调用方传运行值）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（复盘分支用 ReviewLedger.state 填顶栏，替换 `reviewAwareCapital/reviewAwareReturnRate`）
- Test: 复用现 `TrainingTopBarContentTests`（确保 normal/replay 不回归）+ 新增 review 顶栏组装测试（host 用 ReviewLedgerState → TrainingTopBarContent 值）

**Interfaces:**
- Consumes: `ReviewLedgerState`。复盘顶栏 5 格值：`totalCapital=state.totalCapital`、`averageCost=state.averageCost`、`shares=state.shares`、`returnRate=state.returnRate`、`positionTier=state.positionTier`；`sessionPnL* = totalCapital − initialCapital`（已由现 `TrainingTopBarContent.init` 内算）。

- [ ] **Step 1: 写测试**

构造 `ReviewLedgerState`（如 Task 3 的 buy 后：total=99995, shares=100, avgCost=10.05, tier=0, rate=-5/100000, initial=100000），传入 `TrainingTopBarContent.init(totalCapital: state.totalCapital, initialCapital: 100000, averageCost: state.averageCost, shares: state.shares, returnRate: state.returnRate, positionTier: state.positionTier, stockName:, stockCode:)`，断言 `sessionPnLAmount == "-¥5"`、`totalCapital == "¥99,995"`、`sessionPnLSign == -1`。

- [ ] **Step 2: 运行（应直接 PASS，因 `TrainingTopBarContent.init` 已支持任意值）→ 若 PASS 说明无需改 content**，只需改 `TrainingView` 复盘分支的取值。跳到 Step 3。

- [ ] **Step 2b: 暴露单一规范 mark-price API（codex plan-R3-medium）**

`TrainingEngine.price(in:atTick:)` 现为 **private static**。在 `TrainingEngine` 加**唯一**规范公开入口，并让 `currentPrice` 复用它（保证 review 与 finalize 同源、不重复实现）：
```swift
/// 规范 mark price：global tick t 处 .m3 收盘价（越界 clamp、非 nil）。review/finalize/currentPrice 共用同一实现。
public func markPrice(atTick t: Int) -> Double { TrainingEngine.price(in: allCandles, atTick: t) }
```
`currentPrice` 改为 `public var currentPrice: Double { markPrice(atTick: tick.globalTickIndex) }`（等价，收敛到单一入口）。
测试（host）：`#expect(engine.markPrice(atTick: engine.tick.globalTickIndex) == engine.currentPrice)`；`markPrice(atTick: -1)` 与 `markPrice(atTick: maxTick+9)` 非崩、返回端点收盘价（clamp）。

- [ ] **Step 3: `TrainingView` 复盘顶栏取值**

在 `topBar`（L218-272）里，按模式分流（ledger 逐帧 `try?`——入口已验，永不触发 nil 兜底，仅保编译安全）：
```swift
let isReview = engine.flow.mode == .review
let ledger: ReviewLedgerState? = isReview
    ? (try? ReviewLedger.state(atTick: engine.tick.globalTickIndex, ops: engine.tradeOperations,
                               initialCapital: engine.initialCapital,
                               markPriceAtTick: { engine.markPrice(atTick: $0) }))
    : nil
let bar = TrainingTopBarContent(
    totalCapital: ledger?.totalCapital ?? engine.currentTotalCapital,
    initialCapital: engine.initialCapital,
    averageCost: ledger?.averageCost ?? engine.position.averageCost,
    shares: ledger?.shares ?? engine.position.shares,
    returnRate: ledger?.returnRate ?? engine.returnRate,
    positionTier: ledger?.positionTier ?? engine.currentPositionTier,
    stockName: rec?.stockName, stockCode: rec?.stockCode)
```
删除对 `reviewAwareCapital/reviewAwareReturnRate` 的调用（normal/replay 直接用 engine 值；review 用 ledger）。这两个 static 函数：grep 确认无其他调用后删（减死代码），否则留。

- [ ] **Step 4: 运行 host 测 + Catalyst 编译**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(review): top bar shows ReviewLedger running P&L (replace R4 hide)"
```

---

## Task 10: engine.reviewDrawings + RenderStateBuilder 两层叠加 + 复盘画线路由

**Files:**
- Modify: `TrainingEngine.swift`（`reviewDrawings` 字段 + `appendReviewDrawing` + `setReviewDrawings` + init 入参 或 setter）
- Modify: `Render/RenderStateBuilder.swift`（review 叠加 `engine.drawings`(原训练,只读) + `engine.reviewDrawings`，均按 tick 渐显）
- Modify: 画线提交路径（`ChartContainerView` / 画线 commit 处）——复盘模式 commit 走 `appendReviewDrawing`
- Test: `RenderStateBuilder` review 叠加测试（host）

**Interfaces:**
- Produces: `engine.reviewDrawings: [DrawingObject]`（`public private(set)`）、`func appendReviewDrawing(_:)`、`func setReviewDrawings(_:)`。RenderStateBuilder review 模式 drawings = 两层并集按 `anchor.candleIndex <= currentCandleIndex(tick)` 过滤。

- [ ] **Step 1: 写 RenderStateBuilder review 叠加失败测试**

构造 review engine，engine.drawings=[原训练线 @tick2]、reviewDrawings=[复盘线 @tick8]；`make(tick=5)` → 只含原训练线（tick2<=5，复盘线 tick8>5 不显）；`make(tick=10)` → 两条都显。断言 render state 的 drawings 数量/内容。

- [ ] **Step 2: 运行确认失败 → 加 engine 字段**

```swift
public private(set) var reviewDrawings: [DrawingObject] = []
public func appendReviewDrawing(_ d: DrawingObject) { reviewDrawings.append(d) }
public func setReviewDrawings(_ ds: [DrawingObject]) { reviewDrawings = ds }
// 删除复盘线（画线工具的删除动作）：提供 removeReviewDrawing(at:) 或 setReviewDrawings 覆盖
```
（`TrainingEngine.make(.review...)` 增可选入参 `initialReviewDrawings: [DrawingObject] = []` 或由 coordinator 构造后 `setReviewDrawings`。）

- [ ] **Step 3: RenderStateBuilder review 叠加**

在 `make()` 的 drawings 过滤（L61-69）处，review 模式追加 reviewDrawings 层：
```swift
let base = engine.drawings
let overlay = (engine.flow.mode == .review) ? engine.reviewDrawings : []
let visible = (base + overlay).filter { drawing in
    drawing.panelPosition == (panel == .upper ? 0 : 1)
        && drawing.anchors.allSatisfy { $0.candleIndex <= currentCandleIndex(candles: engine.allCandles[$0.period] ?? [], tick: tick) }
}
// drawings: visible
```

- [ ] **Step 4: 复盘画线 commit 路由**

读画线提交路径（grep `appendDrawing(` 调用点，`ChartContainerView` / reducer 的 `.drawingCommitted`）。在 commit 处按 `engine.flow.mode == .review ? engine.appendReviewDrawing(d) : engine.appendDrawing(d)` 分流；删除动作同理指向 reviewDrawings。commit/删除后触发 `lifecycle.autosaveReview(engine:)`（Task 7）。
> 关键不变量：复盘 commit **不得** 调 `engine.appendDrawing`（那会污染原训练记录 drawings）。加一个 host 测断言"复盘 commit 后 engine.drawings.count 不变"。

- [ ] **Step 5: 运行测试通过 + Catalyst 编译**

- [ ] **Step 6: Commit**

```bash
git commit -am "feat(review): engine.reviewDrawings layer + progressive overlay + review draw routing"
```

---

## Task 11: 首页行标记（HomeContent + HomeView）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift`（`HomeHistoryRow` + init 加标记）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift`（chip 渲染）
- Modify: `App/AppRouter.swift`（`loadHome()` 取 replay 单槽 recordId + review markers 注入）
- Test: `ReviewMarkersContentTests.swift`

**Interfaces:**
- Produces: `HomeHistoryRow` 加 `public let replayInProgress: Bool` + `public let reviewMarker: ReviewMarker`；`HomeContent.init` 加参数 `replaySlotRecordId: Int64?`、`reviewMarkers: [Int64: ReviewMarker]`；`makeRow` 据此填每行。
- Consumes: `ReviewMarker`、`coordinator.loadReviewMarkers()`、`coordinator.hasResumableReplay`（或 `loadReplaySlotInfo` 的 recordId）。

- [ ] **Step 1: 写 content 失败测试**

```swift
// 构造 records [1,2,3,4]，replaySlotRecordId=1，reviewMarkers=[2:.inProgress, 3:.saved, 1:.inProgress]
// 断言 row1: replayInProgress && reviewMarker==.inProgress（正交并存）
//       row2: !replay && .inProgress; row3: !replay && .saved; row4: !replay && .none
```

- [ ] **Step 2: 运行确认失败 → 扩 `HomeHistoryRow`/`HomeContent.init`/`makeRow`**

`makeRow` 加参数：`replayInProgress: id == replaySlotRecordId`、`reviewMarker: reviewMarkers[id] ?? .none`。

- [ ] **Step 3: `HomeView` chip 渲染**

`historyRow(_:)`（L137-154）把 r3 改为 `HStack { Text(profitAndRate)...; Spacer(); markerCol }`，markerCol 右对齐、flex-wrap：
```swift
private func markerChips(_ row: HomeHistoryRow) -> some View {
    HStack(spacing: 5) {   // 或 FlowLayout；两 chip 并排/窄屏换行
        if row.replayInProgress { chip("再次训练中", .blue) }
        switch row.reviewMarker {
        case .inProgress: chip("复盘中", .orange)
        case .saved:      chip("已复盘", Color(red: 0.05, green: 0.62, blue: 0.56))  // teal
        case .none:       EmptyView()
        }
    }
}
private func chip(_ text: String, _ tint: Color) -> some View {
    Text(text).font(.system(size: 11)).fontWeight(.semibold)
        .padding(.horizontal, 8).padding(.vertical, 1.5)
        .background(tint.opacity(0.15), in: Capsule()).foregroundStyle(tint)
}
```
放在 profitAndRate 同行右侧（总资金正下方）。

- [ ] **Step 4: `AppRouter.loadHome()` 注入标记**

```swift
let reviewMarkers = coordinator.loadReviewMarkers()
let replaySlotId = (try? coordinator.replaySlotRecordId()) ?? nil   // 见 note
self.homeContent = HomeContent(statistics: stats, configuredCapital: settings.settings.totalCapital,
    records: recs, hasPending: hasPending, hasCachedSets: hasCached,
    replaySlotRecordId: replaySlotId, reviewMarkers: reviewMarkers)
```
> Note：加 `coordinator.replaySlotRecordId() -> Int64?`（= `loadReplaySlotInfo()?.recordId`，try? 兜底 nil）。

- [ ] **Step 5: host 测通过 + Catalyst 编译 + Commit**

```bash
git commit -am "feat(review): home row markers (再次训练中/复盘中/已复盘) orthogonal"
```

---

## Task 12: action sheet 文案 + 路由

**Files:**
- Modify: `UI/HistoryActionSheet.swift`（`reviewButtonTitle(inProgress:)` + 复盘钮文案 + 传 `hasReviewInProgress`）
- Modify: `App/AppRootView.swift`（传 `hasReviewInProgress` + review resume 路由）
- Modify: `App/AppRouter.swift`（`review(id:)` 改 resume-first + `hasReviewInProgress(id:)`）
- Test: `ReviewButtonTitleTests.swift`

**Interfaces:**
- Produces: `HistoryActionSheet.reviewButtonTitle(inProgress: Bool) -> String`（`inProgress ? "返回复盘" : "复盘"`，`nonisolated static`）；`HistoryActionSheet.init` 加 `hasReviewInProgress: Bool`；`AppRouter.review(id:)` resume-first；`AppRouter.hasReviewInProgress(id:)`。

- [ ] **Step 1: 写测试**

```swift
@Test func reviewTitleSwitch() {
    #expect(HistoryActionSheet.reviewButtonTitle(inProgress: false) == "复盘")
    #expect(HistoryActionSheet.reviewButtonTitle(inProgress: true) == "返回复盘")
}
```
（注意 `nonisolated static` 避免 @MainActor 隔离致非隔离测试编译红——参 memory `feedback_swift_local_ci_toolchain_strictness` 的 #137 教训。）

- [ ] **Step 2: 运行失败 → 加 `reviewButtonTitle` + 改复盘钮**

`HistoryActionSheet`：加 `private let hasReviewInProgress: Bool`（init 参数）；复盘 Button 文案 `Text(Self.reviewButtonTitle(inProgress: hasReviewInProgress))`。

- [ ] **Step 3: `AppRouter` resume-first review + hasReviewInProgress**

```swift
public func review(id: Int64) async {
    activeModal = nil
    do {
        let engine: TrainingEngine
        if let resumed = try await coordinator.resumePendingReview(recordId: id) { engine = resumed }
        else { engine = try await coordinator.review(recordId: id) }
        activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
    } catch { setError(error) }
}
public func hasReviewInProgress(id: Int64) -> Bool { coordinator.hasReviewInProgress(recordId: id) }
```

- [ ] **Step 4: `AppRootView` 传参**

`HistoryActionSheet(record: r, hasResumableReplay: router.hasResumableReplay(id:), hasReviewInProgress: router.hasReviewInProgress(id:), onReview:, onReplay:, onCancel:)`。

- [ ] **Step 5: host 测 + Catalyst 编译 + Commit**

```bash
git commit -am "feat(review): action sheet 复盘/返回复盘 + resume-first review routing"
```

---

## Task 13: TrainingView 复盘集成（底栏/画线钮/红框/结束保存弹窗/返回）

**Files:**
- Modify: `UI/TrainingView.swift`（解耦门控 + 结束按钮 + 保存弹窗 + 返回 review 分支 + 底栏接线）
- Modify: `UI/TrainingSessionLifecycle.swift`（review 终态入口已在 Task 7）
- Test: 少量 host 可测谓词（保存弹窗触发条件）；主要 Catalyst 编译闸门 + 手动验收

**Interfaces:**
- Consumes: Task 4/7/8/9/10 的 engine/lifecycle/ReviewControlBar/ReviewLedger。
- 新谓词：`showsDrawingTools = engine.flow.canBuySell() || engine.flow.mode == .review`；`showsActivePanelFrame` 同；复盘显示顶栏 `结束`。

- [ ] **Step 1: 解耦画线 FAB + 红框门控**

`TrainingView.swift`：
- `showsDrawingTools`（新计算属性）= `showsTradeButtons || engine.flow.mode == .review`。
- L211-215 画线 FAB overlay：`if showsDrawingTools`（替 `showsTradeButtons`）。
- L332-336 红框 overlay：`if showsDrawingTools && id == activePanel`（替 `showsTradeButtons`）。
- `toggleDrawing()`/`isDrawingActive` 复盘也可用（现已作用于 upperPanel；复盘按 activePanel 亦可，最小改可保持 upper 或改 activePanel）。

- [ ] **Step 2: 复盘顶栏「结束」按钮**

L247-254 顶栏右段：复盘也显示「结束」（现 review 为 `Color.clear` 占位）。改为：
```swift
if showsTradeButtons {
    Button("结束") { confirmingEnd = true }.font(.callout).tint(.red)
} else if engine.flow.mode == .review {
    Button("结束") { confirmingEndReview = true }.font(.callout).tint(.red).accessibilityLabel("结束复盘")
} else { Color.clear.frame(width: 36, height: 1) }
```

- [ ] **Step 3: 结束保存弹窗（有净改动才弹）**

新增 `@State private var confirmingEndReview = false`。**「结束」按钮 action**：先判 `lifecycle.reviewNetChanged()`——真 → `confirmingEndReview = true`（弹保存/不保存/取消）；假 → 直接 `performReviewEnd(.discard)`（不弹，清 working 回退）。confirmationDialog（仅净改动时弹）：
```swift
.confirmationDialog("结束复盘", isPresented: $confirmingEndReview, titleVisibility: .visible) {
    Button("保存") { performReviewEnd(.save) }
    Button("不保存", role: .destructive) { performReviewEnd(.discard) }
    Button("取消", role: .cancel) {}
} message: { Text("是否保存本次复盘记录？") }
```
**专用 review 失败态（codex plan-R8-high）**——捕获失败的**具体动作**，重试调**那个**动作（**不复用** `backFailed`，那会误走 `lifecycle.back()`=review no-op saveProgress → 丢 saved）：
```swift
private enum ReviewEndAction { case back, save, discard }
@State private var reviewFailedAction: ReviewEndAction?

private func performReviewEnd(_ action: ReviewEndAction) {
    guard !exitInFlight else { return }; exitInFlight = true
    Task {
        defer { exitInFlight = false }
        do {
            switch action {
            case .back:    try await lifecycle.backReview(engine: engine)      // drain→净改动 saveWorking / 否则 discardReviewWorking
            case .save:    try await lifecycle.endReviewSave(engine: engine)    // drain→commitReview
            case .discard: try await lifecycle.endReviewDiscard(engine: engine) // drain→discardReviewWorking
            }
            onExit()
        } catch { reviewFailedAction = action }   // 记住失败的具体动作，供重试
    }
}
```
专用 alert（重试=同一动作；放弃=丢弃工作副本退出，不动已存 saved）：
```swift
.alert("复盘保存失败", isPresented: Binding(get: { reviewFailedAction != nil },
                                       set: { if !$0 { reviewFailedAction = nil } })) {
    Button("重试") { if let a = reviewFailedAction { reviewFailedAction = nil; performReviewEnd(a) } }
    Button("放弃", role: .destructive) {
        reviewFailedAction = nil
        guard !exitInFlight else { return }; exitInFlight = true
        Task { defer { exitInFlight = false }; try? await lifecycle.endReviewDiscard(engine: engine); onExit() }
    }
} message: { Text("复盘进度未能写入。可重试，或放弃本次复盘改动退出（已保存的复盘存档不受影响）。") }
```
`lifecycle.reviewNetChanged()` = 转发 `coordinator.reviewNetChanged()`（Task 5，比 `engine.reviewDrawings` vs committed 基线）。
> 测试（host，经 coordinator + 失败替身 repo）：**保存失败重试** → 重试走 commit（非 back），成功后 `saved==working`；**不保存失败重试** → 重试走 discard；断言标记落到预期态（不会因走错路径丢 saved）。

- [ ] **Step 4: 复盘「返回」走 review 保存分支**

L235-243 顶栏「返回」按钮：按模式分流——review 走 `performReviewEnd(.back)`（失败进**专用** review alert，重试同动作），非 review 保持现 `lifecycle.back()` + `backFailed`：
```swift
Button("返回") {
    if engine.flow.mode == .review { performReviewEnd(.back); return }   // review 失败→专用 alert（不误走 back no-op）
    guard !exitInFlight else { return }; exitInFlight = true
    Task { defer { exitInFlight = false }
        do { try await lifecycle.back(); onExit() } catch { backFailed = true } }
}
```

- [ ] **Step 5: 底栏接线**（Task 8 已更新 ReviewControlBar 调用点；确认 `activePanel` 默认 review 也可用；`下一根` 调 `stepReviewForward(panel: activePanel)`；画线 commit 后 `lifecycle.autosaveReview`；步进后 `lifecycle.autosaveReview`）。在 `.onChange(of: engine.tick.globalTickIndex)` 里 review 模式追加 `lifecycle.autosaveReview(engine:)`。

- [ ] **Step 6: 少量 host 测（保存弹窗触发谓词）+ Catalyst 编译**

抽一个纯谓词 `ReviewEndPrompt.shouldPrompt(netChanged: Bool) -> Bool { netChanged }`（host 测），UI 用它。Catalyst `build-for-testing` BUILD SUCCEEDED。

- [ ] **Step 7: Commit**

```bash
git commit -am "feat(review): TrainingView review integration (2-key bar, draw/frame decouple, end-save dialog, back)"
```

---

## Task 14: 全链验证 + 验收清单定稿

**Files:**
- Modify: 无生产代码（除修 bug）；`docs/superpowers/plans/2026-07-02-review-redesign.md` 附最终验收清单（或 PR body）

- [ ] **Step 1: 全量 host 测**

Run: `cd ios/Contracts && swift test`
Expected: 全绿，新增 suite 全通过。

- [ ] **Step 2: Catalyst 编译闸门**

Run: Catalyst `build-for-testing`（Global Constraints 命令）。Expected: BUILD SUCCEEDED。

- [ ] **Step 3: DEBUG app 手动走查 spec §12 验收 1-12**（模拟器/真机）

逐条按 spec §12 acceptance（复盘逐根运行盈亏 / 到结尾等于成绩 / 复盘中画线返回续 / 结束保存→已复盘 / 再复盘揭示存档 / 不保存留旧档 / 双标记正交 / replay 单槽不受影响 / 纯浏览不误标 / 迟到写不覆盖 / 坏档恢复 / 续复盘删回不卡）。截图/录屏留证。

- [ ] **Step 4: 验收清单定稿**（中文 action/expected/pass_fail，禁用词见 workflow-rules：不得用「验证通过即可/看起来正常/应该没问题/should work/looks fine」）——用 spec §12 定稿到 PR body。

- [ ] **Step 5: Commit（若有收尾修改）**

---

## Self-Review 结果（写完自查）

- **Spec 覆盖**：§1 现状锚点→各 task 触点；§3 schema→Task 1；§4 状态机→Task 5/6；§5 ReviewLedger→Task 3/9；§6 画线归属/顺序→Task 7/10；§7 UI→Task 8/9/11/12/13；§8 路由→Task 6/12；§9 fail-closed→Task 6（saved 损坏）/Task 13（返回/结束失败 alert）；§10 迁移→Task 1；§11 组件测试→各 task；§12 验收→Task 14。**无遗漏**。
- **类型一致**：`ReviewMarker`/`ReviewArchive`/`ReviewLedgerState`/`ReviewNetChange`/`reviewDrawings`/`stepReviewForward(panel:)`/`reviewButtonTitle(inProgress:)`/`saveWorking/commitSaved/clearWorking/clearSaved/loadMarkers/reviewMarker` 跨 task 一致。
- **占位符**：无 TBD；测试均含真实代码/期望值/命令。
- **已知需实现期核对**（非占位，标注给 implementer）：ReviewLedger cash 约定 vs 引擎 buy/sell（Task 3 Step 3 note）；`DefaultAppDB` in-memory/insertMinimalRecord 测试 helper（Task 2 Step 3 note）；`price(in:atTick:)` 可访问性（Task 9 note）；画线 commit 路由点（Task 10 Step 4，需读真实 commit 路径）；reset 清表位置（Task 1 Step 5）。
