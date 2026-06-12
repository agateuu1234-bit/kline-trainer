import XCTest
import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class AppDBMigrationsTests: XCTestCase {

    /// 统一 fixture 工厂：每个 test 自己拿独立 tmp dir + db url + cleanup defer。
    /// 避免 setUp/tearDown 与 AppDBFixture.makeFreshDB() 双 cleanup 路径冲突（codex review I-1）。
    private func makeTmpDB(named name: String = "app.sqlite") throws -> (dir: URL, dbURL: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appdb-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent(name))
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

    // MARK: - 0003_v1.4_purge_leased 实际删 leased 行
    func test_purge_leased_migration_removes_v1_3_leased_rows() throws {
        let (dir, dbURL) = try makeTmpDB()
        defer { try? FileManager.default.removeItem(at: dir) }

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
        let (dir, dbURL) = try makeTmpDB(named: "legacy.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
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
}
