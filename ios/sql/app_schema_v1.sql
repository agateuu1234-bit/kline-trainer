-- Kline Trainer app.sqlite schema v1（v1.4 fresh state）
-- GRDB DatabaseMigrator 在 P4 初始化时 registerMigration("0001_v1.4_baseline") 中执行本文件
-- 变更策略：破坏性变更新增 migration id + 反向 migration（P4 owner）

PRAGMA user_version = 1;

CREATE TABLE training_records (
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

CREATE TABLE trade_operations (
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

CREATE TABLE drawings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id INTEGER NOT NULL REFERENCES training_records(id),
    tool_type TEXT NOT NULL,
    panel_position INTEGER NOT NULL,
    is_extended INTEGER NOT NULL DEFAULT 0,
    anchors TEXT NOT NULL
);

CREATE TABLE pending_training (
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

CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE download_acceptance_journal (
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

CREATE INDEX idx_journal_state ON download_acceptance_journal(state);
