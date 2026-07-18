-- Rollback for 0004_qmt_price_double_and_coverage
-- 引用治理：docs/governance/m01-schema-versioning-contract.md §Migration Rollback
--
-- ⚠️ 有损回滚警告 ⚠️
-- 本回滚把 klines OHLC 从 DOUBLE PRECISION 收窄回 DECIMAL(10,2)，**丢精度**：
--   - QMT 前复权价是 float64（如 11.790828206557329）→ 回滚后截断为 11.79
--   - 老 K 线被前复权缩得极小（如 1991 年 0.61...）→ 2 位截断会压塌整条老 K 线
--   - **精度不可恢复**。执行前必须先备份 klines，或确认该库无 QMT 前复权数据。
-- 同理 file_path 收窄回 VARCHAR(255)：若存量有 >255 字符的绝对路径，本语句会**报错中止**
-- （PostgreSQL 拒绝截断）——这是刻意的 fail-closed，先人工清理超长路径再回滚。

BEGIN;

-- 3. 删覆盖契约表（新表，回滚不丢既有业务数据）
DROP TABLE IF EXISTS stock_coverage;

-- 2. file_path 收窄（存量值须 ≤255，否则本语句报错中止）
ALTER TABLE training_sets ALTER COLUMN file_path TYPE VARCHAR(255);

-- 1. 价格列降精度 —— 丢精度，见顶部警告
-- 1b. 先删价格 CHECK（codex R3-F1 加的）——必须早于收窄列类型：
-- 约束表达式里有 `'NaN'::double precision` 字面量，列类型变回 numeric 后该表达式不再成立。
ALTER TABLE klines DROP CONSTRAINT IF EXISTS ck_klines_price_ordering;
ALTER TABLE klines DROP CONSTRAINT IF EXISTS ck_klines_price_finite_positive;

ALTER TABLE klines ALTER COLUMN open  TYPE DECIMAL(10,2);
ALTER TABLE klines ALTER COLUMN high  TYPE DECIMAL(10,2);
ALTER TABLE klines ALTER COLUMN low   TYPE DECIMAL(10,2);
ALTER TABLE klines ALTER COLUMN close TYPE DECIMAL(10,2);

COMMIT;
