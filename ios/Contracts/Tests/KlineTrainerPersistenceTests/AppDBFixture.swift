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
