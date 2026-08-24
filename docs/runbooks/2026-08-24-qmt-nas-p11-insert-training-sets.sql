-- docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql
-- P11：写入 3 行真数据。字段值取自 Mac 上 qmt-trial 容器的 kline_trial 库
--      （2026-08-24 直接读出，见 spec §2.5-e 的权威表）。
-- file_path 写**容器内**路径：宿主目录怎么变都不用改数据库（spec §4-D3）。
\set ON_ERROR_STOP on
BEGIN;
INSERT INTO training_sets
    (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES
    ('000001.SZ', '000001.SZ', 1756656000, 1777996799, 1,
     '/data/training-sets/000001.SZ_1756656000.zip', '851f9444'),
    ('600519.SH', '600519.SH', 1762099200, 1782835199, 1,
     '/data/training-sets/600519.SH_1762099200.zip', '32892a5f'),
    ('000001.SZ', '000001.SZ', 1762099200, 1782835199, 1,
     '/data/training-sets/000001.SZ_1762099200.zip', '150d8d6c');
DO $$
DECLARE n int; bad int;
BEGIN
    SELECT count(*) INTO n FROM training_sets;
    IF n <> 3 THEN RAISE EXCEPTION 'P11 GATE FAIL: 期望恰好 3 行，实际 % 行', n; END IF;
    SELECT count(*) INTO bad FROM training_sets WHERE status <> 'unsent';
    IF bad > 0 THEN RAISE EXCEPTION 'P11 GATE FAIL: % 行不是 unsent', bad; END IF;
    SELECT count(*) INTO bad FROM training_sets
     WHERE file_path NOT LIKE '/data/training-sets/%';
    IF bad > 0 THEN RAISE EXCEPTION 'P11 GATE FAIL: % 行的 file_path 不是容器内路径', bad; END IF;
    RAISE NOTICE 'P11 GATE PASS: 3 行、全 unsent、file_path 全为容器内路径';
END $$;
COMMIT;
SELECT id, stock_code, content_hash, status, file_path FROM training_sets ORDER BY id;
