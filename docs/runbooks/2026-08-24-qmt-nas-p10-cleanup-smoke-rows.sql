-- docs/runbooks/2026-08-24-qmt-nas-p10-cleanup-smoke-rows.sql
-- P10：清理 P9 烟测插入的临时行，并断言表为空（这是 P11 插真数据的前置硬门）。
--
-- ⚠️ 本文件 R2 版（codex 评审 R3 的 high finding）。R1 版直接写 `DELETE FROM training_sets;`
--    —— 无条件全表删除，安全性**完全**依赖操作者按 P9→P10→P11 的次序执行。
--    只要 P10 在 P11 之后被重跑一次（或恢复流程里被误触），3 行真数据会被**静默删光**，
--    而紧随其后的「count = 0」断言会把这次删除**报成成功**。
--    这正是本仓最忌讳的形状：闸门一边毁数据一边报绿。
--
-- 现在的判据（全部在**一个事务**里，任一条不满足就整体回滚）：
--   ① 若表已空 → 幂等通过（P10 重跑安全）；
--   ② 若表里有**任何非烟测行** → 拒绝删除并报错（说明此刻是错误的时点，真数据已在库里）；
--   ③ 只删带烟测标记的行（stock_code 为 SMOKE-A / SMOKE-B），**不做无条件全表删除**；
--   ④ 删完再断言表为空。
--
-- 判别力已实测（2026-08-24，本机真 PostgreSQL 15.12）：
--   空表 → 幂等通过；只有烟测行 → 删净通过；混入真数据行 → 拒绝且**真数据一行不少**；
--   只有真数据行（模拟 P11 之后误跑 P10）→ 拒绝且真数据一行不少。

\set ON_ERROR_STOP on

BEGIN;

-- ⚠️ 表级排他锁（codex plan-R13 F2）：本脚本「先校验、后写」，而 PostgreSQL 默认
--    READ COMMITTED 下，校验之后、写之前提交的一次预占会被**悄悄覆盖** ——
--    客户端手里还攥着它以为有效的租约，同一批数据却又变成可下载了（重复投递 +
--    随后 confirm 失效）。关掉对外端点**并不能**排空「已经被接受的请求」，
--    也挡不住 NAS 本机直连后端的流量。故在第一条校验之前就把表锁住。
LOCK TABLE training_sets IN ACCESS EXCLUSIVE MODE;

DO $$
DECLARE n_total int; n_smoke int; n_other int;
BEGIN
    SELECT count(*) INTO n_total FROM training_sets;
    SELECT count(*) INTO n_smoke FROM training_sets
     WHERE stock_code IN ('SMOKE-A', 'SMOKE-B');
    n_other := n_total - n_smoke;

    IF n_other > 0 THEN
        RAISE EXCEPTION
            'P10 GATE FAIL: 表里有 % 行不是烟测行，拒绝删除（本次一行都没动）。'
            ' 这说明 P10 被在错误的时点执行了 —— 真数据已经在库里。'
            ' 不要重跑 P10；若要复位那 3 行，走 §7.1 的 P15 复位脚本。', n_other;
    END IF;

    IF n_total = 0 THEN
        RAISE NOTICE 'P10 GATE PASS（幂等）: 表本来就是空的，无需清理';
    ELSE
        RAISE NOTICE 'P10: 待清理烟测行 % 条，无任何非烟测行', n_smoke;
    END IF;
END $$;

DELETE FROM training_sets WHERE stock_code IN ('SMOKE-A', 'SMOKE-B');

DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM training_sets;
    IF n <> 0 THEN
        RAISE EXCEPTION 'P10 GATE FAIL: 清理后表里还剩 % 行（应为 0）', n;
    END IF;
    RAISE NOTICE 'P10 GATE PASS: 表已清空，可以执行 P11';
END $$;

COMMIT;
