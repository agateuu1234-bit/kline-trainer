-- Kline Trainer PostgreSQL schema v1.4
-- 覆盖范围：stocks / klines / training_sets
-- Baseline：v1.4 fresh state（含 lease 三列 + content_hash CHAR(8) NOT NULL + UNIQUE）
-- 变更策略：加列只追加；破坏性变更走 migration forward/rollback（Wave 1 B3 owner）

BEGIN;

CREATE TABLE IF NOT EXISTS stocks (
    code VARCHAR(10) PRIMARY KEY,
    name VARCHAR(50) NOT NULL
);

CREATE TABLE IF NOT EXISTS klines (
    id BIGSERIAL PRIMARY KEY,
    stock_code VARCHAR(10) NOT NULL REFERENCES stocks(code),
    period VARCHAR(10) NOT NULL,
    datetime BIGINT NOT NULL,
    open DECIMAL(10,2) NOT NULL,
    high DECIMAL(10,2) NOT NULL,
    low DECIMAL(10,2) NOT NULL,
    close DECIMAL(10,2) NOT NULL,
    volume BIGINT NOT NULL,
    amount DECIMAL(16,2),
    ticket_index INTEGER,
    ma66 DECIMAL(10,4),
    boll_upper DECIMAL(10,4),
    boll_mid DECIMAL(10,4),
    boll_lower DECIMAL(10,4),
    macd_diff DECIMAL(10,6),
    macd_dea DECIMAL(10,6),
    macd_bar DECIMAL(10,6),
    UNIQUE(stock_code, period, datetime)
);

CREATE INDEX IF NOT EXISTS idx_klines_lookup ON klines(stock_code, period, datetime);

CREATE TABLE IF NOT EXISTS training_sets (
    id SERIAL PRIMARY KEY,
    stock_code VARCHAR(10) NOT NULL,
    stock_name VARCHAR(50) NOT NULL,
    start_datetime BIGINT NOT NULL,
    end_datetime BIGINT NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1,
    file_path VARCHAR(255) NOT NULL,
    content_hash CHAR(8) NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    status VARCHAR(10) NOT NULL DEFAULT 'unsent',
    lease_id UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    reserved_at TIMESTAMPTZ NULL,
    CONSTRAINT uq_stock_start UNIQUE (stock_code, start_datetime),
    -- v1.4 M0.1 runtime invariants (codex round 8 finding)
    CONSTRAINT ck_content_hash_crc32_lowercase CHECK (content_hash ~ '^[0-9a-f]{8}$'),
    CONSTRAINT ck_status_enum CHECK (status IN ('unsent', 'reserved', 'sent')),
    CONSTRAINT ck_lease_state_invariant CHECK (
        (status = 'unsent'
            AND lease_id IS NULL
            AND lease_expires_at IS NULL
            AND reserved_at IS NULL)
        OR
        (status IN ('reserved', 'sent')
            AND lease_id IS NOT NULL
            AND lease_expires_at IS NOT NULL
            AND reserved_at IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_training_sets_lease
  ON training_sets(lease_id) WHERE lease_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_training_sets_lease_expire
  ON training_sets(lease_expires_at) WHERE status = 'reserved';

COMMENT ON COLUMN training_sets.content_hash
  IS 'zip 文件 CRC32 十六进制（8 字符，小写），由 B2 生成、P2 校验。';
COMMENT ON COLUMN training_sets.status
  IS '状态机：unsent → reserved → sent（详见 modules v1.4 M0.1 状态机不变量表）。';

COMMIT;
