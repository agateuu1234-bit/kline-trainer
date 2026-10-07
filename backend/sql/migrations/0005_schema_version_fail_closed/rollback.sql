-- Rollback for 0005_schema_version_fail_closed
-- 引用治理：docs/governance/m01-schema-versioning-contract.md §Migration Rollback
--
-- ✅ 无数据风险（与 0004 的 rollback 相反，那一份有两条有损警告）：
--   · DROP DEFAULT / SET DEFAULT 只改列的元数据，不重写任何已有行；
--   · 回滚不删表、不改列类型、不收窄长度 ⇒ 没有任何既有数据会被截断或删除。
-- ⛔ 「声称无风险」比「声称有风险」更需要证明，所以这条断言由
--    rehearse.sh Part 3 实地跑出来，不是写在这里就算。
--
-- 因此本文件**刻意不设**破坏性确认守卫（0004 的 rollback 有
-- `kline.rollback_confirm` 那一道）—— 那道守卫的存在理由是「真有东西会丢」，
-- 本次没有东西会丢。为一个不存在的风险加确认步骤，只会让下一个读者以为这里有风险。
--
-- ⚠️ 回滚**之后**的副作用（不是数据损失，但要知道）：默认值装回去之后，
--    漏填 schema_version 的写入会重新被静默补成 1。回滚只应在「本片引入的
--    fail-closed 行为本身导致停机」时执行。

BEGIN;

ALTER TABLE training_sets ALTER COLUMN schema_version SET DEFAULT 1;

COMMENT ON COLUMN training_sets.schema_version IS NULL;
-- 注释必须一起撤掉：留着「刻意不设默认值」这句话、而库里默认值已经装回去了，
-- 等于在库里留一条说谎的注释，而没有任何闸门会发现它。

COMMIT;
