import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

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

        // 0005：RFC-A A4 资金权威化数据迁移（user_version 2→3）。
        // 仅 key='total_capital' 单键回填 = 末条记录(total_capital+profit)，排序对齐 statistics()
        // (created_at DESC, id DESC) 防同时间戳非确定性。无记录则不动（保留默认 10 万）。
        // 禁止无 WHERE 的 UPDATE settings（会覆盖 commission/主题等所有键 → DB 判损）。
        migrator.registerMigration("0005_v1.7_capital_authoritative") { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT total_capital, profit FROM training_records
                ORDER BY created_at DESC, id DESC LIMIT 1
                """) {
                let tc: Double = row["total_capital"]
                let p: Double = row["profit"]
                // codex R-plan-8-2：非有限（溢出）跳过写、保留默认（否则 loadSettings 判 .dbCorrupted + 版本号挡重试）。
                // codex R-plan-13-1：负派生值 floor 到 0（与 finalize 同口径，权威资金不得为负）。
                if (tc + p).isFinite {
                    let authoritative = max(0, tc + p)
                    try db.execute(sql:
                        "INSERT OR REPLACE INTO settings(key, value) VALUES ('total_capital', ?)",
                        arguments: [String(authoritative)])
                }
            }
            // codex R-plan-16-1/19-1：清理 legacy 腐坏的非负 settings 键（负/非有限/畸形）为安全默认（无记录也清）——
            // 否则升级后 loadSettings 的「拒负/拒畸形 fail-closed」会让老用户开局即 .dbCorrupted brick。
            // **total_capital 与 commission_rate 都是非负量、parseDouble 都已拒负 → 两键对称清理**。
            // 缺失 → 不写（loadSettings 缺键默认）；合法非负有限 → 不动；其余（负/非有限/非数字）→ 写默认。
            func cleanNonNegativeSettingKey(_ key: String, default def: Double) throws {
                guard let txt = try String.fetchOne(db, sql:
                    "SELECT value FROM settings WHERE key = ?", arguments: [key]) else { return }
                if let v = Double(txt), v.isFinite, v >= 0 { return }   // 合法 → 不动
                try db.execute(sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                               arguments: [key, String(def)])
            }
            try cleanNonNegativeSettingKey("total_capital", default: AppSettings.defaultTotalCapital)
            try cleanNonNegativeSettingKey("commission_rate", default: AppSettings.default.commissionRate)
            try db.execute(sql: "PRAGMA user_version = 3")
        }

        // 0006：replay 续局持久化（新需求10，v1.8）。additive：新建 pending_replay 单行表
        // （CHECK(id=1)），与 pending_training 同构 + record_id（来源历史记录），无 session_key
        // （replay 不写 training_records、无 finalize 幂等）。**只走 migration，不动 v1_4_baselineDDL/
        // app_schema_v1.sql（v1.4 冻结基线，drift-checked）**。fresh install 经 0001→…→0006 链建全表。
        migrator.registerMigration("0006_v1.8_pending_replay") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pending_replay (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    record_id INTEGER NOT NULL,
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
                )
                """)
            try db.execute(sql: "PRAGMA user_version = 4")
        }

        return migrator
    }
}
