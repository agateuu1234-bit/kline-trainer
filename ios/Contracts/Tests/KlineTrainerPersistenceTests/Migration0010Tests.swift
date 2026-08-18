import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

@MainActor
@Suite("migration 0010：升级路径 + 全新安装")
struct Migration0010Tests {

    /// T8（**升级路径**，本组重点）：构造一个「0001–0009 已应用」的真 pre-0010 库，
    /// 种入既有行，再跑完整 migrator → 两张表都要长出新列，**且既有行必须活着**。
    ///
    /// ⚠️ **不能用 `makeFreshDB()`**（codex plan-P-R2 high）：那是从空库跑完整 migrator，
    ///    证明的是**全新安装**。把列加到 baseline / 早期迁移的实现，fresh 测试照样全绿，
    ///    而**线上 v7 用户永远拿不到这一列**。
    /// ⚠️ **种行必须用 legacy raw SQL，不能用 repo**（codex plan-P-R3 high）：
    ///    Task 5 会把 repo 的 INSERT 改成**带新列**，而此刻库还停在 0009（无该列）
    ///    ⇒ 在最终树上 repo 种行会直接报 `no such column`，测试跑不到 0010 就先炸了。
    ///    **下面的列清单是 0009 时代的形状，逐字写死，不得改成引用 repo。**
    @Test func upgrade_from_v7_adds_column_to_both_tables_and_keeps_existing_rows() throws {
        let queue = try DatabaseQueue()
        let migrator = AppDBMigrations.makeMigrator()

        // ① 停在 0009 —— 真 pre-0010 现场
        try migrator.migrate(queue, upTo: "0009_v1.11_drawing_style")
        #expect(try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 7)
        for t in ["pending_training", "pending_replay"] {
            let cols = try queue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(t))").map { $0["name"] as String }
            }
            #expect(!cols.contains("drawing_default_style"), "\(t) 在 0009 阶段就不该有新列")
        }

        // ② 用 **0009 时代的列清单** raw SQL 种既有行（此时无新列）
        // ⚠️ `upper_period` 必须写 **'60m'**（`Period.m60` 的 rawValue，`Models.swift:14`），
        //    写成 'm60' 会让 `Period(rawValue:)` 返 nil → load 抛 `.dbCorrupted`
        //    ⇒ 升级测试因**坏 fixture** 而红，而不是因为迁移有问题（false red，codex plan-P-R5 medium①）。
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO pending_training
                  (id, training_set_filename, global_tick_index, upper_period, lower_period,
                   position_data, fee_snapshot, trade_operations, drawings,
                   started_at, accumulated_capital, cash_balance, drawdown, session_key)
                VALUES (1, 'z.sqlite', 3, '60m', 'daily', 'BwA=',
                        '{"commissionRate":0.0001,"minCommissionEnabled":true}', '[]', '[]',
                        123, 100000.0, 88000.0,
                        '{"peakCapital":100000,"maxDrawdown":0}', 'k')
                """)
            try db.execute(sql: """
                INSERT INTO pending_replay
                  (id, record_id, training_set_filename, global_tick_index, upper_period, lower_period,
                   position_data, fee_snapshot, trade_operations, drawings,
                   started_at, accumulated_capital, cash_balance, drawdown)
                VALUES (1, 9, 'z.sqlite', 3, '60m', 'daily', 'BwA=',
                        '{"commissionRate":0.0001,"minCommissionEnabled":true}', '[]', '[]',
                        123, 100000.0, 88000.0,
                        '{"peakCapital":100000,"maxDrawdown":0}')
                """)
        }

        // ③ 跑完整 migrator（只应跑 0010）
        try migrator.migrate(queue)

        #expect(try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 8)
        for t in ["pending_training", "pending_replay"] {
            let cols = try queue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(t))").map { $0["name"] as String }
            }
            #expect(cols.contains("drawing_default_style"), "\(t) 升级后仍缺该列，实测：\(cols)")
        }
        // ④ 既有行必须活着；**此刻才允许用 repo 读**（列已存在）
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_training") } == 1)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_replay") } == 1)
        // ⚠️ 本 task 阶段 repo **尚未接线**读该列（那是后续 task），
        //    故这里**不能**断言字段值 —— 那会是恒真的。这两条只证一件事：
        //    新增列之后，既有读路径仍能正常解码出行（新列不会打穿 SELECT 的解码）。
        #expect(try queue.read { try PendingTrainingRepositoryImpl.loadPending($0) } != nil,
                "加列后 pending_training 的既有读路径应仍能解码出行")
        #expect(try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) } != nil,
                "加列后 pending_replay 的既有读路径应仍能解码出行")
    }

    /// T9（**全新安装**，与 T8 分开）：从空库跑完整 migrator → 终态 user_version = 8 且两表有列。
    @Test func fresh_install_reaches_v8_with_column() throws {
        let queue = try DatabaseQueue()
        try AppDBMigrations.makeMigrator().migrate(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 8)
        for t in ["pending_training", "pending_replay"] {
            let cols = try queue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(t))").map { $0["name"] as String }
            }
            #expect(cols.contains("drawing_default_style"), "\(t)")
        }
    }
}
