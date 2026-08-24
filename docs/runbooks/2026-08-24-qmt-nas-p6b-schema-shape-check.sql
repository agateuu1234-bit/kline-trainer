-- docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql
-- P6b 硬门（spec §7）：直接查数据库的**实际形状**，不看建表语句的返回值。
-- 理由：backend/sql/schema.sql 建表全是 CREATE TABLE IF NOT EXISTS —— 旧卷/漂移卷
--       会让它静默什么都不修，而 \dt 照样列出 4 张表。
-- 判别力已验（2026-08-24，本机真 PG）：全符合时退出 0；故意 DROP 掉一条 CHECK 后
--       退出码变 3 并打印 P6b GATE FAIL: 1 条不符。
\set ON_ERROR_STOP on
CREATE TEMP VIEW p6b AS
WITH expected(kind, name, detail) AS (VALUES
    ('col', 'klines.open',                'double precision'),
    ('col', 'klines.high',                'double precision'),
    ('col', 'klines.low',                 'double precision'),
    ('col', 'klines.close',               'double precision'),
    ('col', 'training_sets.file_path',    'text'),
    ('col', 'training_sets.content_hash', 'character(8)'),
    ('chk', 'ck_content_hash_crc32_lowercase',    ''),
    ('chk', 'ck_status_enum',                     ''),
    ('chk', 'ck_lease_state_invariant',           ''),
    ('chk', 'ck_klines_price_finite_positive',    ''),
    ('chk', 'ck_klines_price_ordering',           ''),
    ('chk', 'ck_stock_coverage_range',            ''),
    ('chk', 'ck_stock_coverage_dropped_is_array', ''),
    ('chk', 'ck_stock_coverage_day_count',        ''),
    ('uq',  'uq_stock_start',                     '')
), actual AS (
    SELECT 'col' AS kind,
           table_name || '.' || column_name AS name,
           CASE WHEN data_type = 'character'
                THEN 'character(' || character_maximum_length || ')'
                ELSE data_type END AS detail
    FROM information_schema.columns WHERE table_schema = 'public'
    UNION ALL
    SELECT 'chk', conname, '' FROM pg_constraint WHERE contype = 'c'
    UNION ALL
    SELECT 'uq',  conname, '' FROM pg_constraint WHERE contype = 'u'
)
SELECT e.kind, e.name, e.detail AS expected_detail,
       COALESCE(a.detail, '<<MISSING>>') AS actual_detail,
       CASE WHEN a.name IS NULL      THEN 'FAIL-missing'
            WHEN e.detail <> a.detail THEN 'FAIL-type-mismatch'
            ELSE 'pass' END AS verdict
FROM expected e
LEFT JOIN actual a ON a.kind = e.kind AND a.name = e.name;

SELECT * FROM p6b ORDER BY verdict DESC, kind, name;

DO $$
DECLARE bad int; total int;
BEGIN
    SELECT count(*) FILTER (WHERE verdict <> 'pass'), count(*) INTO bad, total FROM p6b;
    IF total <> 15 THEN
        RAISE EXCEPTION 'P6b GATE FAIL: 期望项应为 15 条，实际 % 条（判据本身被改坏了）', total;
    END IF;
    IF bad > 0 THEN
        RAISE EXCEPTION 'P6b GATE FAIL: % 条不符（见上表 verdict 列）—— 停止，销毁卷重来，不得往下插数据', bad;
    END IF;
    RAISE NOTICE 'P6b GATE PASS: 15/15 全部符合';
END $$;
