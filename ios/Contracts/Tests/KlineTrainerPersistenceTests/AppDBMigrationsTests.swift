import XCTest
import GRDB
import KlineTrainerContracts
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
