-- docs/runbooks/2026-08-24-qmt-nas-p15-reset-training-sets.sql
-- P15：验收失败重跑时的库侧复位（spec §7.1）。
-- 幂等：无条件 UPDATE，已经是 unsent 时重复执行同样安全（已验）。
-- ⚠️ 设备侧还必须删掉 App 重装 —— 只复位库侧的话，G2/G4 会在上一轮残留的
--    本地缓存上假绿，观察结果作废。
\set ON_ERROR_STOP on
BEGIN;
-- §7.1 库侧复位：无条件 UPDATE（幂等：已经是 unsent 时重复执行同样安全）。
-- ⚠️ lease 三列必须**同时**置 NULL —— ck_lease_state_invariant 规定 unsent 行
--    的 lease 三列必须全空，漏一列整条 UPDATE 会被 CHECK 拒绝。
UPDATE training_sets
   SET status = 'unsent',
       lease_id = NULL,
       lease_expires_at = NULL,
       reserved_at = NULL;
DO $$
DECLARE bad int; n int;
BEGIN
    SELECT count(*) INTO n FROM training_sets;
    IF n <> 3 THEN RAISE EXCEPTION 'P15 GATE FAIL: 期望恰好 3 行，实际 % 行', n; END IF;
    SELECT count(*) INTO bad FROM training_sets
     WHERE status <> 'unsent' OR lease_id IS NOT NULL
        OR lease_expires_at IS NOT NULL OR reserved_at IS NOT NULL;
    IF bad > 0 THEN RAISE EXCEPTION 'P15 GATE FAIL: % 行没有回到 unsent + 三列全 NULL', bad; END IF;
    RAISE NOTICE 'P15 GATE PASS: 3 行全部 unsent 且 lease 三列全 NULL';
END $$;
COMMIT;
