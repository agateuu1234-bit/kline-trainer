-- Migration 0004: QMT 前复权价格精度 + B1→B2 覆盖契约
-- 引用治理：docs/governance/m01-schema-versioning-contract.md §Bump 策略 A
-- 触发：A 类 DDL「改类型」→ 顶层 CONTRACT_VERSION 1.11 → 1.12
-- Spec: docs/superpowers/specs/2026-07-06-qmt-data-ingestion-pilot-design.md §4.3 (D1/D5/D11)
--
-- 三项变更（同一 migration，同一次 bump 覆盖）：
--   1. klines OHLC DECIMAL(10,2) → DOUBLE PRECISION（前复权 float64 无损；2 位截断会压塌老 K 线）
--   2. training_sets.file_path VARCHAR(255) → TEXT（D5 绝对路径可任意长）
--   3. 新增 stock_coverage 表（D11：B1 写权威 dense 1m 覆盖，B2 读作 dense_dates）
--
-- 注：ticket_index 列「保留、停止写入」（D3），本 migration 对该列零 DDL。

BEGIN;

-- 1. 价格列升精度（DECIMAL→DOUBLE 是放宽，存量值无损上转）
ALTER TABLE klines ALTER COLUMN open  TYPE DOUBLE PRECISION;
ALTER TABLE klines ALTER COLUMN high  TYPE DOUBLE PRECISION;
ALTER TABLE klines ALTER COLUMN low   TYPE DOUBLE PRECISION;
ALTER TABLE klines ALTER COLUMN close TYPE DOUBLE PRECISION;

-- 2. file_path 去长度限（VARCHAR(255)→TEXT 是扩容，存量值无损）
ALTER TABLE training_sets ALTER COLUMN file_path TYPE TEXT;

-- 3. B1→B2 覆盖契约表（D11）
-- 约束在 DB 层可执行（codex PF2-R2-F1）：spec §4.3 原写 `TEXT DEFAULT '[]'` 无任何约束，
-- 坏行（非 JSON / 非数组 / 反向区间）会让 B2 reader 抛 ValueError 穿出 generate_batch
-- （它只捕 GenerateSkipException）→ **中止整轮 sweep** 而非跳过一只股。故收紧为
-- JSONB NOT NULL + 数组类型检查 + 区间/计数合法性检查。reader 侧另有降级兜底（防历史行）。
-- **刻意不用 IF NOT EXISTS**（codex PF2-R7-F1）：版本化 migration 必须对结果形状确定。
-- 若目标库已存在一张手工/试跑建出的旧形状 stock_coverage（TEXT、缺 dense_day_count、
-- 缺 CHECK），IF NOT EXISTS 会让 migration **静默成功**、库却低于所声明的 1.12 契约；
-- 故障随后从"迁移期"挪到"B4 运行期"（PR 2b 会 SELECT dense_day_count → UndefinedColumn）。
-- 裸 CREATE TABLE 在这种情况下直接报错中止 = 正确的 fail-closed。
CREATE TABLE stock_coverage (
    stock_code          TEXT PRIMARY KEY,
    dense_1m_start_date DATE NOT NULL,
    dense_1m_end_date   DATE NOT NULL,
    dropped_1m_dates    JSONB NOT NULL DEFAULT '[]'::jsonb,
    dense_day_count     INTEGER NOT NULL,
    CONSTRAINT ck_stock_coverage_range CHECK (dense_1m_start_date <= dense_1m_end_date),
    CONSTRAINT ck_stock_coverage_dropped_is_array
        CHECK (jsonb_typeof(dropped_1m_dates) = 'array'),
    CONSTRAINT ck_stock_coverage_day_count CHECK (dense_day_count >= 0)
);

COMMENT ON TABLE stock_coverage
  IS 'D11：B1 分钟级完整性判定后写入的权威 dense 1m 覆盖；B2 D2 从此表读 dense_dates（非从 klines 反推）。';
COMMENT ON COLUMN stock_coverage.dropped_1m_dates
  IS '带内被 drop 的交易日 JSON 数组（通常 []）；dense_dates = [start,end] 交易日 − 本列。';

COMMIT;
