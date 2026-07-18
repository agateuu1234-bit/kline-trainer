"""Validate backend/sql/migrations/*/{forward,rollback}.sql.

用 pglast（libpg_query 绑定）静态解析，不需要 Docker 或 PG daemon——与
test_schema.py 同约定；真库前向迁移验证属 B3/NAS owner scope。
"""
from __future__ import annotations

import re
from pathlib import Path

import pglast

MIGRATIONS_DIR = Path(__file__).parent.parent / "sql" / "migrations"
MIG_0004 = MIGRATIONS_DIR / "0004_qmt_price_double_and_coverage"


def _sql_normalized(path: Path) -> str:
    """去 `--` 行注释 + 压平空白 + 转小写，供子串断言用。

    codex PF2-R3-F2：直接对原文做子串断言必挂——(a) 本仓 SQL 用多空格对齐
    （`ALTER COLUMN open  TYPE ...`），单空格 pattern 匹配不上；(b) 注释里出现的
    `ticket_index` 会让「不得含该词」的断言误判。正是
    feedback_acceptance_grep_anchoring 记的「注释子串误判」坑。
    （本仓 migration SQL 不含带 `--` 的字符串字面量，去注释安全。）"""
    text = re.sub(r"--[^\n]*", " ", path.read_text(encoding="utf-8"))
    return re.sub(r"\s+", " ", text).strip().lower()


def test_migration_0004_has_forward_and_rollback():
    """m01 §Migration Rollback：每个 migration 必须是 forward+rollback 成对。"""
    assert (MIG_0004 / "forward.sql").is_file(), "缺 forward.sql"
    assert (MIG_0004 / "rollback.sql").is_file(), "缺 rollback.sql"


def test_migration_0004_forward_is_valid_postgres():
    sql = (MIG_0004 / "forward.sql").read_text(encoding="utf-8")
    assert len(pglast.parse_sql(sql)) > 0


def test_migration_0004_rollback_is_valid_postgres():
    sql = (MIG_0004 / "rollback.sql").read_text(encoding="utf-8")
    assert len(pglast.parse_sql(sql)) > 0


def test_migration_0004_forward_converts_ohlc_to_double():
    """D1：四个价格列都必须被转成 double precision（少一列 = 静默截断残留）。"""
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    for col in ("open", "high", "low", "close"):
        assert f"alter column {col} type double precision" in sql, f"{col} 未转 DOUBLE"


def test_migration_0004_forward_creates_stock_coverage():
    """D11：B2 读 dense_dates 的权威 artifact 表。"""
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    assert "create table" in sql and "stock_coverage" in sql


def test_migration_0004_stock_coverage_is_not_if_not_exists():
    """codex PF2-R7-F1：版本化 migration 里 `CREATE TABLE IF NOT EXISTS` 会让
    "已存在一张旧形状表"静默通过，库低于所声明契约，故障挪到 B4 运行期才炸。
    （schema.sql 那份 fresh baseline 用 IF NOT EXISTS 是对的，migration 不行。）"""
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    assert "create table stock_coverage" in sql
    assert "create table if not exists stock_coverage" not in sql


def test_migration_0004_stock_coverage_carries_integrity_checks():
    """codex PF2-R2-F1：migration 建的表必须与 schema.sql 一样带约束，
    否则已部署库前向迁移后仍是无约束的坏行温床。"""
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    assert "jsonb" in sql
    assert "jsonb_typeof(dropped_1m_dates) = 'array'" in sql
    assert "dense_1m_start_date <= dense_1m_end_date" in sql


def test_migration_0004_forward_widens_file_path_to_text():
    """R16-F2：绝对路径可任意长，VARCHAR(255) 会让登记 INSERT 失败留 orphan。"""
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    assert "alter column file_path type text" in sql


def test_migration_0004_rollback_reverses_all_three_changes():
    """回滚必须覆盖三项：OHLC 回 DECIMAL、file_path 回 VARCHAR(255)、drop 新表。"""
    sql = _sql_normalized(MIG_0004 / "rollback.sql")
    for col in ("open", "high", "low", "close"):
        assert f"alter column {col} type decimal(10,2)" in sql, f"{col} 未回滚"
    assert "alter column file_path type varchar(255)" in sql
    assert "drop table" in sql and "stock_coverage" in sql


def test_migration_0004_rollback_documents_precision_loss():
    """m01 要求：有损回滚必须在文件里显式标注（人工执行前要看得见）。"""
    text = (MIG_0004 / "rollback.sql").read_text(encoding="utf-8")
    assert "丢精度" in text, "rollback.sql 未标注 OHLC 回滚丢精度"


def test_migration_0004_does_not_touch_ticket_index():
    """D3/R12-F1：ticket_index 保留列、只停写。任何对该列的 DDL 都是不可逆迁移违规。"""
    for name in ("forward.sql", "rollback.sql"):
        # 用**去注释后的正文**断言：forward.sql 的说明注释里合法地提到了 ticket_index
        sql = _sql_normalized(MIG_0004 / name)
        assert "ticket_index" not in sql, f"{name} 正文不得对 ticket_index 做任何 DDL"
