import Foundation
@preconcurrency import GRDB

/// app.sqlite GRDB DatabaseMigrator 注册表。
/// **Schema 必须 mirror `ios/sql/app_schema_v1.sql`**（CI 脚本 `scripts/check_app_schema_drift.sh` 校验）。
/// 添加新 migration：注册到 `makeMigrator()` 末尾，新 ID 命名 `00NN_v<ver>_<purpose>`。
enum AppDBMigrations {

    /// v1.4 baseline schema DDL（与 ios/sql/app_schema_v1.sql 严格相等，不含注释头）。
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

        return migrator
    }
}
