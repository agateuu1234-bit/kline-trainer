-- docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql
-- P6b 硬门（spec §7）：直接查数据库的**实际形状**，不看建表语句的返回值。
--
-- 为什么需要：backend/sql/schema.sql 建表建索引全是 IF NOT EXISTS —— 旧卷/漂移卷
-- 会让它静默什么都不修，而 \dt 照样列出 4 张表。
--
-- ⚠️ 本文件 R3 版。两轮 codex 评审各挖出一条 high，两条都实测坐实：
--   R1：只比对约束**名字**，不看所属表也不看定义 → 「同名改定义」与「同名换表」
--       两种漂移实测都被放行（退出码 0）。后者会让 klines 的价格排序约束整个消失。
--   R2：只查 6 个选定列 + 只看 CHECK/UNIQUE（contype IN ('c','u')）→ 主键、外键、
--       索引、可空性、默认值、其余列类型**全部不查**。少了 klines→stocks 的外键会产生
--       孤儿行；少了两条 lease 部分索引会让预占查询退化；主键缺失会产生重复身份。
--
-- 现在的判据 = **完整 schema 契约**，三类各自双向集合相等（缺、多、漂移都红）：
--   ① 列：每张表每一列的 format_type（含长度/精度）、可空性、默认值表达式；
--   ② 约束：PRIMARY KEY / FOREIGN KEY / UNIQUE / CHECK 全部四类，按 (所属表, 名字)
--      匹配、比对 pg_get_constraintdef() 完整定义，限定 connamespace='public'；
--   ③ 索引：pg_indexes 的完整 indexdef（**含部分索引的 WHERE 谓词与有序列**）。
--
-- ⚠️ 本文件是 backend/sql/schema.sql 在 PostgreSQL 15.12 上产出形状的**快照**：
--    schema.sql md5 = 2e4b074d5a4607d53a00c849855434d5
--    若 schema.sql 变了，本文件必须重新生成（症状：在**全新空卷**上本门也会红 ——
--    全新卷还红就说明是快照过期，不是部署有问题）。
--
-- 判别力已逐档实测（2026-08-24，本机真 PostgreSQL 15.12），见 runbook 的 P6b 一节。

\set ON_ERROR_STOP on

CREATE TEMP VIEW p6b_want_col(tbl, col, want_type, want_null, want_default) AS VALUES
    ('klines', 'id', $p6b$bigint$p6b$, $p6b$NOT NULL$p6b$, $p6b$nextval('klines_id_seq'::regclass)$p6b$),
    ('klines', 'stock_code', $p6b$character varying(10)$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('klines', 'period', $p6b$character varying(10)$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('klines', 'datetime', $p6b$bigint$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('klines', 'open', $p6b$double precision$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('klines', 'high', $p6b$double precision$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('klines', 'low', $p6b$double precision$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('klines', 'close', $p6b$double precision$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('klines', 'volume', $p6b$bigint$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('klines', 'amount', $p6b$numeric(16,2)$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('klines', 'ticket_index', $p6b$integer$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('klines', 'ma66', $p6b$numeric(10,4)$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('klines', 'boll_upper', $p6b$numeric(10,4)$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('klines', 'boll_mid', $p6b$numeric(10,4)$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('klines', 'boll_lower', $p6b$numeric(10,4)$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('klines', 'macd_diff', $p6b$numeric(10,6)$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('klines', 'macd_dea', $p6b$numeric(10,6)$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('klines', 'macd_bar', $p6b$numeric(10,6)$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('stock_coverage', 'stock_code', $p6b$text$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('stock_coverage', 'dense_1m_start_date', $p6b$date$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('stock_coverage', 'dense_1m_end_date', $p6b$date$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('stock_coverage', 'dropped_1m_dates', $p6b$jsonb$p6b$, $p6b$NOT NULL$p6b$, $p6b$'[]'::jsonb$p6b$),
    ('stock_coverage', 'dense_day_count', $p6b$integer$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('stocks', 'code', $p6b$character varying(10)$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('stocks', 'name', $p6b$character varying(50)$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('training_sets', 'id', $p6b$integer$p6b$, $p6b$NOT NULL$p6b$, $p6b$nextval('training_sets_id_seq'::regclass)$p6b$),
    ('training_sets', 'stock_code', $p6b$character varying(10)$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('training_sets', 'stock_name', $p6b$character varying(50)$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('training_sets', 'start_datetime', $p6b$bigint$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('training_sets', 'end_datetime', $p6b$bigint$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('training_sets', 'schema_version', $p6b$integer$p6b$, $p6b$NOT NULL$p6b$, $p6b$1$p6b$),
    ('training_sets', 'file_path', $p6b$text$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('training_sets', 'content_hash', $p6b$character(8)$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),
    ('training_sets', 'created_at', $p6b$timestamp without time zone$p6b$, $p6b$NULL$p6b$, $p6b$now()$p6b$),
    ('training_sets', 'status', $p6b$character varying(10)$p6b$, $p6b$NOT NULL$p6b$, $p6b$'unsent'::character varying$p6b$),
    ('training_sets', 'lease_id', $p6b$uuid$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('training_sets', 'lease_expires_at', $p6b$timestamp with time zone$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$),
    ('training_sets', 'reserved_at', $p6b$timestamp with time zone$p6b$, $p6b$NULL$p6b$, $p6b$$p6b$);

CREATE TEMP VIEW p6b_want_con(tbl, conname, want_def) AS VALUES
    ('klines', 'ck_klines_price_finite_positive', $p6b$CHECK (((open > (0)::double precision) AND (open <> 'NaN'::double precision) AND (open <> 'Infinity'::double precision) AND (high > (0)::double precision) AND (high <> 'NaN'::double precision) AND (high <> 'Infinity'::double precision) AND (low > (0)::double precision) AND (low <> 'NaN'::double precision) AND (low <> 'Infinity'::double precision) AND (close > (0)::double precision) AND (close <> 'NaN'::double precision) AND (close <> 'Infinity'::double precision)))$p6b$),
    ('klines', 'ck_klines_price_ordering', $p6b$CHECK (((high >= low) AND (high >= GREATEST(open, close)) AND (low <= LEAST(open, close))))$p6b$),
    ('klines', 'klines_pkey', $p6b$PRIMARY KEY (id)$p6b$),
    ('klines', 'klines_stock_code_fkey', $p6b$FOREIGN KEY (stock_code) REFERENCES stocks(code)$p6b$),
    ('klines', 'klines_stock_code_period_datetime_key', $p6b$UNIQUE (stock_code, period, datetime)$p6b$),
    ('stock_coverage', 'ck_stock_coverage_day_count', $p6b$CHECK ((dense_day_count >= 0))$p6b$),
    ('stock_coverage', 'ck_stock_coverage_dropped_is_array', $p6b$CHECK ((jsonb_typeof(dropped_1m_dates) = 'array'::text))$p6b$),
    ('stock_coverage', 'ck_stock_coverage_range', $p6b$CHECK ((dense_1m_start_date <= dense_1m_end_date))$p6b$),
    ('stock_coverage', 'stock_coverage_pkey', $p6b$PRIMARY KEY (stock_code)$p6b$),
    ('stocks', 'stocks_pkey', $p6b$PRIMARY KEY (code)$p6b$),
    ('training_sets', 'ck_content_hash_crc32_lowercase', $p6b$CHECK ((content_hash ~ '^[0-9a-f]{8}$'::text))$p6b$),
    ('training_sets', 'ck_lease_state_invariant', $p6b$CHECK (((((status)::text = 'unsent'::text) AND (lease_id IS NULL) AND (lease_expires_at IS NULL) AND (reserved_at IS NULL)) OR (((status)::text = ANY ((ARRAY['reserved'::character varying, 'sent'::character varying])::text[])) AND (lease_id IS NOT NULL) AND (lease_expires_at IS NOT NULL) AND (reserved_at IS NOT NULL))))$p6b$),
    ('training_sets', 'ck_status_enum', $p6b$CHECK (((status)::text = ANY ((ARRAY['unsent'::character varying, 'reserved'::character varying, 'sent'::character varying])::text[])))$p6b$),
    ('training_sets', 'training_sets_pkey', $p6b$PRIMARY KEY (id)$p6b$),
    ('training_sets', 'uq_stock_start', $p6b$UNIQUE (stock_code, start_datetime)$p6b$);

CREATE TEMP VIEW p6b_want_idx(tbl, idxname, want_def) AS VALUES
    ('klines', 'idx_klines_lookup', $p6b$CREATE INDEX idx_klines_lookup ON public.klines USING btree (stock_code, period, datetime)$p6b$),
    ('klines', 'klines_pkey', $p6b$CREATE UNIQUE INDEX klines_pkey ON public.klines USING btree (id)$p6b$),
    ('klines', 'klines_stock_code_period_datetime_key', $p6b$CREATE UNIQUE INDEX klines_stock_code_period_datetime_key ON public.klines USING btree (stock_code, period, datetime)$p6b$),
    ('stock_coverage', 'stock_coverage_pkey', $p6b$CREATE UNIQUE INDEX stock_coverage_pkey ON public.stock_coverage USING btree (stock_code)$p6b$),
    ('stocks', 'stocks_pkey', $p6b$CREATE UNIQUE INDEX stocks_pkey ON public.stocks USING btree (code)$p6b$),
    ('training_sets', 'idx_training_sets_lease', $p6b$CREATE INDEX idx_training_sets_lease ON public.training_sets USING btree (lease_id) WHERE (lease_id IS NOT NULL)$p6b$),
    ('training_sets', 'idx_training_sets_lease_expire', $p6b$CREATE INDEX idx_training_sets_lease_expire ON public.training_sets USING btree (lease_expires_at) WHERE ((status)::text = 'reserved'::text)$p6b$),
    ('training_sets', 'training_sets_pkey', $p6b$CREATE UNIQUE INDEX training_sets_pkey ON public.training_sets USING btree (id)$p6b$),
    ('training_sets', 'uq_stock_start', $p6b$CREATE UNIQUE INDEX uq_stock_start ON public.training_sets USING btree (stock_code, start_datetime)$p6b$);

CREATE TEMP VIEW p6b_got_col AS
SELECT c.relname AS tbl, a.attname AS col,
       format_type(a.atttypid, a.atttypmod) AS got_type,
       CASE WHEN a.attnotnull THEN 'NOT NULL' ELSE 'NULL' END AS got_null,
       COALESCE(pg_get_expr(d.adbin, d.adrelid), '') AS got_default
FROM pg_attribute a
JOIN pg_class c     ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped;

CREATE TEMP VIEW p6b_got_con AS
SELECT c.relname AS tbl, con.conname, pg_get_constraintdef(con.oid) AS got_def
FROM pg_constraint con
JOIN pg_class c     ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND con.contype IN ('p', 'f', 'u', 'c');

CREATE TEMP VIEW p6b_got_idx AS
SELECT tablename AS tbl, indexname AS idxname, indexdef AS got_def
FROM pg_indexes WHERE schemaname = 'public';

-- ① 列：缺 / 类型漂移 / 可空性漂移 / 默认值漂移
CREATE TEMP VIEW p6b_col_report AS
SELECT 'col' AS kind, w.tbl || '.' || w.col AS name,
       w.want_type || ' | ' || w.want_null || ' | ' || w.want_default AS expected,
       COALESCE(g.got_type || ' | ' || g.got_null || ' | ' || g.got_default, '<<MISSING>>') AS actual,
       CASE WHEN g.col IS NULL              THEN 'FAIL-missing'
            WHEN g.got_type    <> w.want_type    THEN 'FAIL-type-mismatch'
            WHEN g.got_null    <> w.want_null    THEN 'FAIL-nullability-drift'
            WHEN g.got_default <> w.want_default THEN 'FAIL-default-drift'
            ELSE 'pass' END AS verdict
FROM p6b_want_col w LEFT JOIN p6b_got_col g ON g.tbl = w.tbl AND g.col = w.col
UNION ALL
SELECT 'col', g.tbl || '.' || g.col, '<<NOT EXPECTED>>', g.got_type, 'FAIL-unexpected'
FROM p6b_got_col g LEFT JOIN p6b_want_col w ON w.tbl = g.tbl AND w.col = g.col
WHERE w.col IS NULL;

-- ② 约束：PK / FK / UNIQUE / CHECK 四类全覆盖
CREATE TEMP VIEW p6b_con_report AS
SELECT 'con' AS kind, w.tbl || '.' || w.conname AS name, w.want_def AS expected,
       COALESCE(g.got_def, '<<MISSING>>') AS actual,
       CASE WHEN g.conname IS NULL      THEN 'FAIL-missing'
            WHEN g.got_def <> w.want_def THEN 'FAIL-definition-drift'
            ELSE 'pass' END AS verdict
FROM p6b_want_con w LEFT JOIN p6b_got_con g ON g.tbl = w.tbl AND g.conname = w.conname
UNION ALL
SELECT 'con', g.tbl || '.' || g.conname, '<<NOT EXPECTED>>', g.got_def, 'FAIL-unexpected'
FROM p6b_got_con g LEFT JOIN p6b_want_con w ON w.tbl = g.tbl AND w.conname = g.conname
WHERE w.conname IS NULL;

-- ③ 索引：含部分索引的 WHERE 谓词与有序列
CREATE TEMP VIEW p6b_idx_report AS
SELECT 'idx' AS kind, w.tbl || '.' || w.idxname AS name, w.want_def AS expected,
       COALESCE(g.got_def, '<<MISSING>>') AS actual,
       CASE WHEN g.idxname IS NULL      THEN 'FAIL-missing'
            WHEN g.got_def <> w.want_def THEN 'FAIL-definition-drift'
            ELSE 'pass' END AS verdict
FROM p6b_want_idx w LEFT JOIN p6b_got_idx g ON g.tbl = w.tbl AND g.idxname = w.idxname
UNION ALL
SELECT 'idx', g.tbl || '.' || g.idxname, '<<NOT EXPECTED>>', g.got_def, 'FAIL-unexpected'
FROM p6b_got_idx g LEFT JOIN p6b_want_idx w ON w.tbl = g.tbl AND w.idxname = g.idxname
WHERE w.idxname IS NULL;

CREATE TEMP VIEW p6b AS
SELECT * FROM p6b_col_report
UNION ALL SELECT * FROM p6b_con_report
UNION ALL SELECT * FROM p6b_idx_report;

-- 只打印不合格项（合格项 62 条，全打出来会淹没结论）
SELECT kind, name, verdict, left(expected, 70) AS expected_head, left(actual, 70) AS actual_head
FROM p6b WHERE verdict <> 'pass' ORDER BY kind, name;

DO $$
DECLARE bad int; n_col int; n_con int; n_idx int; n_pass int;
BEGIN
    SELECT count(*) INTO n_col FROM p6b_want_col;
    SELECT count(*) INTO n_con FROM p6b_want_con;
    SELECT count(*) INTO n_idx FROM p6b_want_idx;
    IF n_col <> 38 OR n_con <> 15 OR n_idx <> 9 THEN
        RAISE EXCEPTION 'P6b GATE FAIL: 期望表被改坏了（列 %/38，约束 %/15，索引 %/9）', n_col, n_con, n_idx;
    END IF;
    SELECT count(*) FILTER (WHERE verdict <> 'pass'), count(*) FILTER (WHERE verdict = 'pass')
      INTO bad, n_pass FROM p6b;
    IF bad > 0 THEN
        RAISE EXCEPTION 'P6b GATE FAIL: % 条不符（见上表）—— 停止，销毁卷重来，不得往下插数据', bad;
    END IF;
    IF n_pass <> 62 THEN
        RAISE EXCEPTION 'P6b GATE FAIL: 合格项 % 条，期望 62 条 —— 判据本身没跑满', n_pass;
    END IF;
    RAISE NOTICE 'P6b GATE PASS: 38 列 + 15 约束（含主键/外键）+ 9 索引，逐条吻合且无多余项';
END $$;
