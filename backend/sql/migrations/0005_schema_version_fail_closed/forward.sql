-- Migration 0005: training_sets.schema_version 去掉 DEFAULT 1（fail-closed）
-- 引用治理：docs/governance/m01-schema-versioning-contract.md §Bump 策略 A
-- 触发：A 类 DDL「改既有语义」→ 顶层 CONTRACT_VERSION 1.14 → 1.15
-- Spec: docs/superpowers/specs/2026-10-06-ts1r1-schema-version-fail-closed-design.md §4
--
-- 一项变更（0004 是三项合一，本次只有这一项）：
--   training_sets.schema_version 去掉 DEFAULT 1，保留 NOT NULL
--
-- 为什么：有默认值时，漏填该列的 INSERT 被 PostgreSQL 静默补成 1 ——
-- 第 2 代产物被标成第 1 代，而写入方毫无察觉，错误一路流到 App 读取端。
-- 去掉默认值 + 保留 NOT NULL ⇒ 漏填当场报 `violates not-null constraint`。
--
-- 存量行不受影响：DROP DEFAULT 只改列的元数据，不重写任何已有行（由
-- rehearse.sh Part 2 实地证明，不是推理）。

BEGIN;

ALTER TABLE training_sets ALTER COLUMN schema_version DROP DEFAULT;

COMMENT ON COLUMN training_sets.schema_version
  IS '产物代号。⛔ 刻意不设默认值：漏填必须当场失败，不能被静默标成第 1 代。';
-- ⚠️ 这段文字必须与 schema.sql 里那条**逐字一致** —— 两份副本不一致时，
--    从 schema.sql 新建的库与跑过迁移的库注释会不同，而注释不被任何闸门覆盖
--    （P6b 查列/约束/索引，不查 comment）⇒ 无人发现。
--    由 test_migration_0005_comment_text_is_byte_identical_to_schema_sql 钉住。

COMMIT;
