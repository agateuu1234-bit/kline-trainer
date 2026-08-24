-- docs/runbooks/2026-08-24-qmt-nas-p15-reset-training-sets.sql
-- P15：验收失败重跑时的库侧复位（spec §7.1）。
--
-- ⚠️ 本文件 R3 版。前两版都被打回，两次都实测坐实：
--   R1：无条件全表 UPDATE + 事后数行数（与 codex 打回 P10 的是同一类缺陷）。
--   R2：改成「按 content_hash 认身份」——**仍然不够**（codex plan-R5 high）。
--       content_hash 只有 8 位 CRC32，且表上**没有唯一约束**。判据只证明了
--       「这 3 行的指纹都属于期望集合」，没证明「每个指纹各出现一次」，
--       更没检查股票代码 / 时间区间 / 文件路径 / schema 版本。
--       实测：三行股票代码全错、file_path 指向 /tmp/WRONG-*.zip、三行共用同一个
--       期望指纹 —— **闸门通过，并把它们全部复位成 unsent（可下载），还打印 PASS**。
--       后果是让不该发的数据变成可下载。
--
-- 现在的判据（全部在一个事务里，任一条不满足就整体回滚、一行都不动）：
--   ① 期望集合写成**完整七元组**（stock_code / stock_name / start_datetime /
--      end_datetime / schema_version / file_path / content_hash）；
--   ② 与表内容做**双向 EXCEPT ALL**（`EXCEPT ALL` 保留重数）—— 多一行、少一行、
--      重复一行、任一字段不符，都会红；
--   ③ 再断言表内总行数恰好 3；
--   ④ UPDATE **按主键**进行（主键从步骤②通过后的精确匹配中取），不再用 CRC32 当身份。
--
-- 幂等：已经是 unsent 时重复执行同样安全（已验）。
-- ⚠️ lease 三列必须**同时**置 NULL —— ck_lease_state_invariant 规定 unsent 行的
--    lease 三列必须全空，漏一列整条 UPDATE 会被 CHECK 拒绝（已验）。
-- ⚠️ 设备侧还必须删掉 App 重装 —— 只复位库侧的话，G2/G4 会在上一轮残留的
--    本地缓存上假绿，观察结果作废。

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE p15_expected (
    stock_code     varchar(10),
    stock_name     varchar(50),
    start_datetime bigint,
    end_datetime   bigint,
    schema_version integer,
    file_path      text,
    content_hash   char(8)
) ON COMMIT DROP;

INSERT INTO p15_expected VALUES
    ('000001.SZ', '000001.SZ', 1756656000, 1777996799, 1,
     '/data/training-sets/000001.SZ_1756656000.zip', '851f9444'),
    ('600519.SH', '600519.SH', 1762099200, 1782835199, 1,
     '/data/training-sets/600519.SH_1762099200.zip', '32892a5f'),
    ('000001.SZ', '000001.SZ', 1762099200, 1782835199, 1,
     '/data/training-sets/000001.SZ_1762099200.zip', '150d8d6c');

CREATE TEMP TABLE p15_targets (id integer) ON COMMIT DROP;

DO $$
DECLARE n_total int; n_expected int; n_extra int; n_missing int;
BEGIN
    SELECT count(*) INTO n_expected FROM p15_expected;
    IF n_expected <> 3 THEN
        RAISE EXCEPTION 'P15 GATE FAIL: 期望表被改坏了（% 行，应为 3 行）', n_expected;
    END IF;

    SELECT count(*) INTO n_total FROM training_sets;

    -- 表里有、期望里没有（含重数）
    SELECT count(*) INTO n_extra FROM (
        SELECT stock_code, stock_name, start_datetime, end_datetime,
               schema_version, file_path, content_hash FROM training_sets
        EXCEPT ALL
        SELECT stock_code, stock_name, start_datetime, end_datetime,
               schema_version, file_path, content_hash FROM p15_expected
    ) AS x;

    -- 期望里有、表里没有（含重数）
    SELECT count(*) INTO n_missing FROM (
        SELECT stock_code, stock_name, start_datetime, end_datetime,
               schema_version, file_path, content_hash FROM p15_expected
        EXCEPT ALL
        SELECT stock_code, stock_name, start_datetime, end_datetime,
               schema_version, file_path, content_hash FROM training_sets
    ) AS x;

    IF n_total <> 3 OR n_extra <> 0 OR n_missing <> 0 THEN
        RAISE EXCEPTION
            'P15 GATE FAIL: 表内容不是「恰好本次那 3 行」，拒绝复位，一行都没动。'
            ' 表内共 % 行；表里多出 % 行不在期望中；期望里有 % 行表里没有。'
            ' 先查清楚库里到底是什么再决定 —— 不要放宽这道判据。',
            n_total, n_extra, n_missing;
    END IF;
END $$;

-- 主键从「完整七元组精确匹配」中取，不用 CRC32 当身份
INSERT INTO p15_targets (id)
SELECT t.id
  FROM training_sets t
  JOIN p15_expected e
    ON  e.stock_code     = t.stock_code
    AND e.stock_name     = t.stock_name
    AND e.start_datetime = t.start_datetime
    AND e.end_datetime   = t.end_datetime
    AND e.schema_version = t.schema_version
    AND e.file_path      = t.file_path
    AND e.content_hash   = t.content_hash;

DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM p15_targets;
    IF n <> 3 THEN
        RAISE EXCEPTION 'P15 GATE FAIL: 精确匹配到 % 个主键，期望 3 个', n;
    END IF;
END $$;

UPDATE training_sets
   SET status = 'unsent',
       lease_id = NULL,
       lease_expires_at = NULL,
       reserved_at = NULL
 WHERE id IN (SELECT id FROM p15_targets);

DO $$
DECLARE bad int;
BEGIN
    SELECT count(*) INTO bad FROM training_sets
     WHERE status <> 'unsent' OR lease_id IS NOT NULL
        OR lease_expires_at IS NOT NULL OR reserved_at IS NOT NULL;
    IF bad > 0 THEN
        RAISE EXCEPTION 'P15 GATE FAIL: % 行没有回到 unsent + 三列全 NULL', bad;
    END IF;
    RAISE NOTICE 'P15 GATE PASS: 3 行全部 unsent 且 lease 三列全 NULL';
END $$;

COMMIT;
