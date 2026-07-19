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

-- 0. 破坏性保护：有数据可丢时 fail-closed（codex R5-F1）
--
-- 回滚是「出事时才跑」的应急路径——恰恰是操作者最紧张、最不会细读注释的时刻。
-- 光靠顶部的文字警告不够：本脚本会 DROP 掉 stock_coverage（B2 赖以门控的权威
-- 覆盖 artifact），并把 OHLC 收窄到 2 位小数（QMT 前复权价不可恢复地被截断）。
-- 故改为：**只要真有东西会丢，就拒绝执行**，除非操作者显式声明已备份。
--
-- 注：顶部注释原写「stock_coverage 是新表，回滚不丢既有业务数据」——那句话只在
-- B1 尚未写入覆盖数据时成立；Plan 3 落地后即不再成立。这里按最坏情况保护。
DO $$
DECLARE
  cov_rows  bigint := 0;
  lossy     bigint := 0;
  confirmed text   := coalesce(current_setting('kline.rollback_confirm', true), '');
BEGIN
  IF to_regclass('stock_coverage') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM stock_coverage' INTO cov_rows;
  END IF;

  -- 精度超过 2 位小数的价格，收窄后不可恢复
  SELECT count(*) INTO lossy FROM klines
   WHERE open::numeric  <> round(open::numeric,  2)
      OR high::numeric  <> round(high::numeric,  2)
      OR low::numeric   <> round(low::numeric,   2)
      OR close::numeric <> round(close::numeric, 2);

  IF (cov_rows > 0 OR lossy > 0) AND confirmed <> 'I_HAVE_A_BACKUP' THEN
    RAISE EXCEPTION
      'rollback 会造成不可恢复的数据损失：stock_coverage 将被删除的行数=%；klines 中精度超 2 位小数、收窄后不可恢复的行数=%',
      cov_rows, lossy
      USING HINT =
        '确认已备份后，在**同一会话**内先执行 SET kline.rollback_confirm = ''I_HAVE_A_BACKUP''; 再跑本脚本。'
        || ' 例如：psql -d <db> -v ON_ERROR_STOP=1 -c "SET kline.rollback_confirm=''I_HAVE_A_BACKUP''" -f rollback.sql';
  END IF;
END $$;

-- 3. 删覆盖契约表（**注意：B1 写入覆盖数据后，这一步会丢数据**，已由上面的守卫拦截）
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
