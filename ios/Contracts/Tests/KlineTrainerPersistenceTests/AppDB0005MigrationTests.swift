import XCTest
import GRDB
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

final class AppDB0005MigrationTests: XCTestCase {
    // codex R-plan-2-2：setUp 建**裸临时 URL**（不跑任何 migrator），升级测试才能从真 pre-0005 起。
    private var dbURL: URL!
    override func setUp() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appdb-0005-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("app.sqlite")   // 裸文件，无 migrator
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

    // fresh-install 终态：单独用 makeFreshDB（跑完整 migrator）断言 user_version=3
    func test_fresh_install_full_migrator_user_version_3() throws {
        let freshURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: freshURL.deletingLastPathComponent()) }
        let q = try AppDBFixture.openRaw(at: freshURL)
        let v: Int = try q.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        XCTAssertEqual(v, 3)
    }

    func test_0005_backfills_total_capital_from_last_record_and_keeps_other_keys() throws {
        let q = try DatabaseQueue(path: dbURL.path)   // 裸库
        try Self.migrateTo0004(q)                     // partial：仅 0001/0003/0004 → user_version 2
        XCTAssertEqual(try q.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }, 2)  // 0005 未应用（真 pre-0005）
        try q.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('commission_rate','0.0003')")
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('min_commission_enabled','true')")
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('display_mode','dark')")
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('total_capital','100000.0')")
            // 2 条记录，同 created_at，id 大者 total+profit=130000
            try Self.insertRecord(db, createdAt: 1000, total: 100_000, profit: 20_000)   // id=1
            try Self.insertRecord(db, createdAt: 1000, total: 120_000, profit: 10_000)   // id=2 → 130000 胜
        }
        try AppDBMigrations.makeMigrator().migrate(q)   // 完整 migrator：0005 在此真跑
        XCTAssertEqual(try q.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }, 3)
        let s = try q.read { db -> [String: String] in
            var d: [String: String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT key,value FROM settings") { d[r["key"]] = r["value"] }
            return d
        }
        XCTAssertEqual(Double(s["total_capital"]!)!, 130_000, accuracy: 1e-6)   // tie-break id DESC
        XCTAssertEqual(s["commission_rate"], "0.0003")          // 其它键不变
        XCTAssertEqual(s["min_commission_enabled"], "true")
        XCTAssertEqual(s["display_mode"], "dark")
    }

    func test_0005_no_records_leaves_capital_unchanged() throws {
        let q = try DatabaseQueue(path: dbURL.path)
        try Self.migrateTo0004(q)
        try q.write { db in try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('total_capital','100000.0')") }
        try AppDBMigrations.makeMigrator().migrate(q)
        let cap = try q.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='total_capital'") }
        XCTAssertEqual(Double(cap!)!, 100_000, accuracy: 1e-6)   // 无记录不动
    }

    // codex R-plan-8-2：legacy 记录派生值溢出/非有限 → 0005 跳过写（保留默认）+ user_version=3，
    //   后续 loadSettings 不判 dbCorrupted（资金仍合法）。
    func test_0005_skips_write_on_non_finite_derived_capital() throws {
        let q = try DatabaseQueue(path: dbURL.path)
        try Self.migrateTo0004(q)
        try q.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('total_capital','100000.0')")
            // total_capital + profit 溢出为 +inf（两个接近 Double.greatestFiniteMagnitude 的有限值）
            try Self.insertRecord(db, createdAt: 1000, total: .greatestFiniteMagnitude, profit: .greatestFiniteMagnitude)
        }
        try AppDBMigrations.makeMigrator().migrate(q)
        XCTAssertEqual(try q.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }, 3)   // 仍推进
        let cap = try q.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='total_capital'") }
        XCTAssertEqual(Double(cap!)!, 100_000, accuracy: 1e-6)   // 非有限派生 → 不写，保留默认（合法）
    }

    // codex R-plan-16-1：legacy 负 total_capital + 无记录 → 迁移清为默认（避免升级后 loadSettings 拒负 brick）。
    func test_0005_cleans_legacy_negative_capital_no_records() throws {
        let q = try DatabaseQueue(path: dbURL.path)
        try Self.migrateTo0004(q)
        try q.write { db in try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('total_capital','-1.0')") }
        try AppDBMigrations.makeMigrator().migrate(q)
        let cap = try q.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='total_capital'") }
        XCTAssertEqual(Double(cap!)!, 100_000, accuracy: 1e-6)   // 负值已清为默认 10万（非负）
        // 迁移后 loadSettings 不再因负值抛 .dbCorrupted（开局不 brick）
        XCTAssertNoThrow(try DefaultAppDB(dbPath: dbURL).loadSettings())
    }

    // codex R-plan-19-1：legacy 负 commission_rate 升级前 → 迁移清为默认 → loadSettings 不 brick（与 capital 对称）。
    func test_0005_cleans_legacy_negative_commission_rate() throws {
        let q = try DatabaseQueue(path: dbURL.path)
        try Self.migrateTo0004(q)
        try q.write { db in try db.execute(sql: "INSERT OR REPLACE INTO settings(key,value) VALUES ('commission_rate','-0.1')") }
        try AppDBMigrations.makeMigrator().migrate(q)
        let rate = try q.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key='commission_rate'") }
        XCTAssertEqual(Double(rate!)!, 0.0001, accuracy: 1e-9)   // 负费率已清为默认 0.0001
        XCTAssertNoThrow(try DefaultAppDB(dbPath: dbURL).loadSettings())   // 升级后开局不 brick
    }

    // MARK: - helpers

    // partial migrator：注册 0001/0003/0004（**与 AppDBMigrations 同 id 同体**），跑至 user_version 2，
    // 后续完整 migrator 跳过它们只跑 0005（同 AppDBMigrationsTests test_0004_upgrade_* 范式）。
    private static func migrateTo0004(_ queue: DatabaseQueue) throws {
        var partial = DatabaseMigrator()
        partial.registerMigration("0001_v1.4_baseline") { db in
            try db.execute(sql: AppDBMigrations.v1_4_baselineDDL)
        }
        partial.registerMigration("0003_v1.4_purge_leased") { db in
            try db.execute(sql: "DELETE FROM download_acceptance_journal WHERE state = 'leased'")
        }
        partial.registerMigration("0004_v1.6_session_key") { db in
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
        try partial.migrate(queue)
    }

    // insertRecord：最小合法 training_records 行（列清单照搬 AppDBMigrationsTests）。
    private static func insertRecord(_ db: Database, createdAt: Int, total: Double, profit: Double) throws {
        try db.execute(sql: """
            INSERT INTO training_records
              (training_set_filename, created_at, stock_code, stock_name, start_year,
               start_month, total_capital, profit, return_rate, max_drawdown,
               buy_count, sell_count, fee_snapshot, final_tick)
            VALUES ('test.sqlite', ?, 'C', 'N', 2020, 1, ?, ?, 0, 0, 0, 0, '{}', 0)
            """, arguments: [createdAt, total, profit])
    }
}
