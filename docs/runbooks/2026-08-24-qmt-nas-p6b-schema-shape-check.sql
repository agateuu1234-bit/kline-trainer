-- docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql
-- P6b 硬门（spec §7）：直接查数据库的**实际形状**，不看建表语句的返回值。
--
-- 为什么需要：backend/sql/schema.sql 建表全是 CREATE TABLE IF NOT EXISTS —— 旧卷/漂移卷
-- 会让它静默什么都不修，而 \dt 照样列出 4 张表。
--
-- ⚠️ 本文件 R2 版（codex 评审 R1 的 high finding，2026-08-24）。R1 版**只比对约束名字**，
--    不看它属于哪张表、定义是什么 —— 两种漂移都实测放行（exit=0）：
--      ① 同名但定义被改宽（ck_status_enum 多允许一个非法取值）；
--      ② 约束被整个挪到别的表（klines 的价格排序约束被删掉、同名约束建到 stocks 上）。
--    ②那种会让 high < low 的脏数据直接进库。
--    现在改成按 (所属表, 约束名) 匹配、比对 pg_get_constraintdef() 的**完整定义**，
--    并限定 connamespace = 'public'；UNIQUE 约束的定义本身就编码了**有序列集合**，
--    故 uq_stock_start 不再只靠名字。
--
-- ⚠️ 本文件是 backend/sql/schema.sql 在 PostgreSQL 15.12 上产出形状的**快照**：
--    schema.sql md5 = 2e4b074d5a4607d53a00c849855434d5
--    若 schema.sql 变了，本文件必须重新生成（症状：在**全新空卷**上本门也会红 ——
--    全新卷还红就说明是快照过期，不是部署有问题）。
--
-- 判别力已验（2026-08-24，本机真 PostgreSQL 15.12）：健康库 exit=0；
-- 五种破坏（缺约束 / 同名改定义 / 同名换表 / 多出约束 / 改列类型）各自 exit≠0。

\set ON_ERROR_STOP on

CREATE TEMP VIEW p6b_expected_col(tbl, col, want_type) AS VALUES
    ('klines', 'open', 'double precision'),
    ('klines', 'high', 'double precision'),
    ('klines', 'low', 'double precision'),
    ('klines', 'close', 'double precision'),
    ('training_sets', 'file_path', 'text'),
    ('training_sets', 'content_hash', 'character(8)');

CREATE TEMP VIEW p6b_expected_con(tbl, conname, want_def) AS VALUES
    ('klines', 'ck_klines_price_finite_positive', $p6b$CHECK (((open > (0)::double precision) AND (open <> 'NaN'::double precision) AND (open <> 'Infinity'::double precision) AND (high > (0)::double precision) AND (high <> 'NaN'::double precision) AND (high <> 'Infinity'::double precision) AND (low > (0)::double precision) AND (low <> 'NaN'::double precision) AND (low <> 'Infinity'::double precision) AND (close > (0)::double precision) AND (close <> 'NaN'::double precision) AND (close <> 'Infinity'::double precision)))$p6b$),
    ('klines', 'ck_klines_price_ordering', $p6b$CHECK (((high >= low) AND (high >= GREATEST(open, close)) AND (low <= LEAST(open, close))))$p6b$),
    ('klines', 'klines_stock_code_period_datetime_key', $p6b$UNIQUE (stock_code, period, datetime)$p6b$),
    ('stock_coverage', 'ck_stock_coverage_day_count', $p6b$CHECK ((dense_day_count >= 0))$p6b$),
    ('stock_coverage', 'ck_stock_coverage_dropped_is_array', $p6b$CHECK ((jsonb_typeof(dropped_1m_dates) = 'array'::text))$p6b$),
    ('stock_coverage', 'ck_stock_coverage_range', $p6b$CHECK ((dense_1m_start_date <= dense_1m_end_date))$p6b$),
    ('training_sets', 'ck_content_hash_crc32_lowercase', $p6b$CHECK ((content_hash ~ '^[0-9a-f]{8}$'::text))$p6b$),
    ('training_sets', 'ck_lease_state_invariant', $p6b$CHECK (((((status)::text = 'unsent'::text) AND (lease_id IS NULL) AND (lease_expires_at IS NULL) AND (reserved_at IS NULL)) OR (((status)::text = ANY ((ARRAY['reserved'::character varying, 'sent'::character varying])::text[])) AND (lease_id IS NOT NULL) AND (lease_expires_at IS NOT NULL) AND (reserved_at IS NOT NULL))))$p6b$),
    ('training_sets', 'ck_status_enum', $p6b$CHECK (((status)::text = ANY ((ARRAY['unsent'::character varying, 'reserved'::character varying, 'sent'::character varying])::text[])))$p6b$),
    ('training_sets', 'uq_stock_start', $p6b$UNIQUE (stock_code, start_datetime)$p6b$);

CREATE TEMP VIEW p6b_actual_col AS
SELECT table_name AS tbl, column_name AS col,
       CASE WHEN data_type = 'character'
            THEN 'character(' || character_maximum_length || ')'
            ELSE data_type END AS got_type
FROM information_schema.columns
WHERE table_schema = 'public';

CREATE TEMP VIEW p6b_actual_con AS
SELECT c.relname AS tbl, con.conname, pg_get_constraintdef(con.oid) AS got_def
FROM pg_constraint con
JOIN pg_class c      ON c.oid = con.conrelid
JOIN pg_namespace n  ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND con.contype IN ('c', 'u');

-- 列：类型必须逐个吻合
CREATE TEMP VIEW p6b_col_report AS
SELECT 'col' AS kind, e.tbl || '.' || e.col AS name,
       e.want_type AS expected, COALESCE(a.got_type, '<<MISSING>>') AS actual,
       CASE WHEN a.col IS NULL          THEN 'FAIL-missing'
            WHEN a.got_type <> e.want_type THEN 'FAIL-type-mismatch'
            ELSE 'pass' END AS verdict
FROM p6b_expected_col e
LEFT JOIN p6b_actual_col a ON a.tbl = e.tbl AND a.col = e.col;

-- 约束：按 (所属表, 名字) 匹配，比对**完整定义**
CREATE TEMP VIEW p6b_con_report AS
SELECT 'con' AS kind, e.tbl || '.' || e.conname AS name,
       e.want_def AS expected, COALESCE(a.got_def, '<<MISSING>>') AS actual,
       CASE WHEN a.conname IS NULL       THEN 'FAIL-missing'
            WHEN a.got_def <> e.want_def THEN 'FAIL-definition-drift'
            ELSE 'pass' END AS verdict
FROM p6b_expected_con e
LEFT JOIN p6b_actual_con a ON a.tbl = e.tbl AND a.conname = e.conname;

-- 反向：public 里不得有预期之外的 check/unique 约束（旧卷可能带着上一版的约束）
CREATE TEMP VIEW p6b_extra_report AS
SELECT 'con' AS kind, a.tbl || '.' || a.conname AS name,
       '<<NOT EXPECTED>>' AS expected, a.got_def AS actual,
       'FAIL-unexpected' AS verdict
FROM p6b_actual_con a
LEFT JOIN p6b_expected_con e ON e.tbl = a.tbl AND e.conname = a.conname
WHERE e.conname IS NULL;

CREATE TEMP VIEW p6b AS
SELECT * FROM p6b_col_report
UNION ALL SELECT * FROM p6b_con_report
UNION ALL SELECT * FROM p6b_extra_report;

SELECT kind, name, verdict,
       CASE WHEN verdict = 'pass' THEN '' ELSE left(expected, 60) END AS expected_head,
       CASE WHEN verdict = 'pass' THEN '' ELSE left(actual,   60) END AS actual_head
FROM p6b ORDER BY verdict DESC, kind, name;

DO $$
DECLARE bad int; n_col int; n_con int;
BEGIN
    SELECT count(*) INTO n_col FROM p6b_expected_col;
    SELECT count(*) INTO n_con FROM p6b_expected_con;
    IF n_col <> 6 OR n_con <> 10 THEN
        RAISE EXCEPTION 'P6b GATE FAIL: 期望表被改坏了（列 %/6，约束 %/10）', n_col, n_con;
    END IF;
    SELECT count(*) INTO bad FROM p6b WHERE verdict <> 'pass';
    IF bad > 0 THEN
        RAISE EXCEPTION 'P6b GATE FAIL: % 条不符（见上表 verdict 列）—— 停止，销毁卷重来，不得往下插数据', bad;
    END IF;
    RAISE NOTICE 'P6b GATE PASS: 6 列 + 10 约束全部逐条吻合，且无预期外约束';
END $$;
