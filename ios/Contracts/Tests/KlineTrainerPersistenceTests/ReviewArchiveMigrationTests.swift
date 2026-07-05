import Testing
import GRDB
@testable import KlineTrainerPersistence

@Suite struct ReviewArchiveMigrationTests {
    // Fresh install：空 DB 跑全 migrator（0001→…→0008）
    @Test func freshInstallHasReviewArchiveV5() throws {
        let queue = try DatabaseQueue()   // in-memory
        try AppDBMigrations.makeMigrator().migrate(queue)
        try queue.read { db in
            let exists = try Bool.fetchOne(db, sql:
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='review_archive'") ?? false
            #expect(exists)
            #expect((try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1) == 7)
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
        try migrator.migrate(queue)                                     // 跑剩余（0007+0008+0009）
        try queue.read { db in
            #expect((try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1) == 7)   // 升级到 v7
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
