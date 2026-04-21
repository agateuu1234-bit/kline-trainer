-- Kline Trainer 训练组 SQLite schema v1
-- 每个训练组生成为独立 .db 文件，PRAGMA user_version=1 标识版本
-- 不支持 rollback：schema 变更时 bump user_version，旧 version reader 直接拒收

PRAGMA user_version = 1;

CREATE TABLE meta (
    stock_code TEXT NOT NULL,
    stock_name TEXT NOT NULL,
    start_datetime INTEGER NOT NULL,
    end_datetime INTEGER NOT NULL
);

CREATE TABLE klines (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    period TEXT NOT NULL,
    datetime INTEGER NOT NULL,
    open REAL NOT NULL,
    high REAL NOT NULL,
    low REAL NOT NULL,
    close REAL NOT NULL,
    volume INTEGER NOT NULL,
    amount REAL,
    ma66 REAL,
    boll_upper REAL,
    boll_mid REAL,
    boll_lower REAL,
    macd_diff REAL,
    macd_dea REAL,
    macd_bar REAL,
    global_index INTEGER,
    end_global_index INTEGER NOT NULL
);

CREATE INDEX idx_period_endidx ON klines(period, end_global_index);
CREATE INDEX idx_period_datetime ON klines(period, datetime);
