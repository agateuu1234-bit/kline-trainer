-- docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql
-- P11：写入 3 行真数据。
--
-- ⚠️ 这 3 行的权威值在 spec §2.5-e 的表里（2026-08-24 从 Mac 上 qmt-trial 容器的
--    kline_trial 库直接读出）。本文件与 p15-reset 各存了一份**必须逐字一致**的副本；
--    改任何一处都要三处同改（spec §2.5-e / 本文件 / P15）。
--    若两份 SQL 的副本发生分歧，P15 会在第一次重跑时拒绝复位 —— 那就是分歧的信号。
--
-- file_path 写**容器内**路径：宿主目录怎么变都不用改数据库（spec §4-D3）。
--
-- ⚠️ 本文件 R2 版：判据从「行数 + 全 unsent + 路径前缀」升级为与 P15 同一套
--    **完整七元组双向多重集相等**（codex plan-R5 打回 P15 时的同族问题）。
--    原判据只要求「3 行、都 unsent、路径以 /data/training-sets/ 开头」——
--    并不证明写进去的就是那 3 个训练组。
--
-- 判别力已实测（2026-08-24，本机真 PostgreSQL 15.12）。

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE p11_expected (
    stock_code     varchar(10),
    stock_name     varchar(50),
    start_datetime bigint,
    end_datetime   bigint,
    schema_version integer,
    file_path      text,
    content_hash   char(8)
) ON COMMIT DROP;

INSERT INTO p11_expected VALUES
    ('000001.SZ', '000001.SZ', 1756656000, 1777996799, 1,
     '/data/training-sets/000001.SZ_1756656000.zip', '851f9444'),
    ('600519.SH', '600519.SH', 1762099200, 1782835199, 1,
     '/data/training-sets/600519.SH_1762099200.zip', '32892a5f'),
    ('000001.SZ', '000001.SZ', 1762099200, 1782835199, 1,
     '/data/training-sets/000001.SZ_1762099200.zip', '150d8d6c');

-- 前置：表必须是空的（P10 的产物）。不空就拒绝，不往已有内容上叠加。
DO $$
DECLARE n int; n_exp int;
BEGIN
    SELECT count(*) INTO n_exp FROM p11_expected;
    IF n_exp <> 3 THEN
        RAISE EXCEPTION 'P11 GATE FAIL: 期望表被改坏了（% 行，应为 3 行）', n_exp;
    END IF;
    SELECT count(*) INTO n FROM training_sets;
    IF n <> 0 THEN
        RAISE EXCEPTION
            'P11 GATE FAIL: 表里已有 % 行，拒绝插入（本次一行都没动）。'
            ' P11 的前置是 P10 已把表清空。', n;
    END IF;
END $$;

INSERT INTO training_sets
    (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
SELECT stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash
  FROM p11_expected;

-- 后置：表内容与期望**完整七元组双向多重集相等**，且全部 unsent
DO $$
DECLARE n_total int; n_extra int; n_missing int; n_bad_state int;
BEGIN
    SELECT count(*) INTO n_total FROM training_sets;

    SELECT count(*) INTO n_extra FROM (
        SELECT stock_code, stock_name, start_datetime, end_datetime,
               schema_version, file_path, content_hash FROM training_sets
        EXCEPT ALL
        SELECT stock_code, stock_name, start_datetime, end_datetime,
               schema_version, file_path, content_hash FROM p11_expected
    ) AS x;

    SELECT count(*) INTO n_missing FROM (
        SELECT stock_code, stock_name, start_datetime, end_datetime,
               schema_version, file_path, content_hash FROM p11_expected
        EXCEPT ALL
        SELECT stock_code, stock_name, start_datetime, end_datetime,
               schema_version, file_path, content_hash FROM training_sets
    ) AS x;

    SELECT count(*) INTO n_bad_state FROM training_sets
     WHERE status <> 'unsent' OR lease_id IS NOT NULL
        OR lease_expires_at IS NOT NULL OR reserved_at IS NOT NULL;

    IF n_total <> 3 OR n_extra <> 0 OR n_missing <> 0 THEN
        RAISE EXCEPTION
            'P11 GATE FAIL: 表内容与期望不符（共 % 行；多 % 行；缺 % 行）',
            n_total, n_extra, n_missing;
    END IF;
    IF n_bad_state <> 0 THEN
        RAISE EXCEPTION 'P11 GATE FAIL: % 行不是 unsent 或 lease 三列非空', n_bad_state;
    END IF;
    RAISE NOTICE 'P11 GATE PASS: 恰好 3 行、逐字段与期望吻合、全部 unsent';
END $$;

COMMIT;

SELECT id, stock_code, content_hash, status, file_path FROM training_sets ORDER BY id;
