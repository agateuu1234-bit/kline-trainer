-- docs/runbooks/2026-08-24-qmt-nas-p15-reset-training-sets.sql
-- P15：验收失败重跑时的库侧复位（spec §7.1）。
--
-- ⚠️ 本文件 R2 版。R1 版是**无条件全表 UPDATE**，而且「先改、后断言」——
--    与 codex 评审 R3 打回 P10 的是同一类缺陷（守则：改判据要按判据本身穷尽全仓，
--    不是只补被点名的那一处）。虽然它包在事务里、断言失败会回滚，但判据只数了行数，
--    并不确认「这 3 行就是本次那 3 行」。
--
-- 现在的判据（全部在一个事务里，任一条不满足就整体回滚、一行都不动）：
--   ① 前置身份门：表里必须**恰好 3 行**，且这 3 行的 content_hash 恰好是本次那三个；
--   ② UPDATE 也带 WHERE，只动这三个 content_hash 的行（与①互为双保险）；
--   ③ 后置断言：3 行全部 unsent 且 lease 三列全 NULL。
--
-- 幂等：已经是 unsent 时重复执行同样安全（已验）。
-- ⚠️ lease 三列必须**同时**置 NULL —— ck_lease_state_invariant 规定 unsent 行的
--    lease 三列必须全空，漏一列整条 UPDATE 会被 CHECK 拒绝（已验）。
-- ⚠️ 设备侧还必须删掉 App 重装 —— 只复位库侧的话，G2/G4 会在上一轮残留的
--    本地缓存上假绿，观察结果作废。

\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE n_total int; n_ours int;
BEGIN
    SELECT count(*) INTO n_total FROM training_sets;
    SELECT count(*) INTO n_ours FROM training_sets
     WHERE content_hash IN ('851f9444', '32892a5f', '150d8d6c');
    IF n_total <> 3 OR n_ours <> 3 THEN
        RAISE EXCEPTION
            'P15 GATE FAIL: 表里不是「恰好本次那 3 行」（共 % 行，其中本次的 % 行），'
            ' 拒绝复位，一行都没动。先查清楚库里到底是什么再决定。', n_total, n_ours;
    END IF;
END $$;

UPDATE training_sets
   SET status = 'unsent',
       lease_id = NULL,
       lease_expires_at = NULL,
       reserved_at = NULL
 WHERE content_hash IN ('851f9444', '32892a5f', '150d8d6c');

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
