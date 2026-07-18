"""Validate backend/sql/schema.sql: PostgreSQL 15 syntax + expected AST objects.

Uses pglast (libpg_query bindings) so no Docker or daemon is required.
Production deployment validation (on NAS PostgreSQL) is Wave 1 B3 owner scope.
"""
from __future__ import annotations

import re
from pathlib import Path

import pglast
from pglast.ast import (
    Constraint,
    CreateStmt,
    IndexStmt,
)

SCHEMA_PATH = Path(__file__).parent.parent / "sql" / "schema.sql"


def _parse_schema() -> list:
    sql = SCHEMA_PATH.read_text(encoding="utf-8")
    return pglast.parse_sql(sql)


def test_schema_is_valid_postgres_syntax():
    """Schema must parse without error via libpg_query (same parser real Postgres uses)."""
    stmts = _parse_schema()
    assert len(stmts) > 0, "empty parse result"


def test_three_tables_created():
    """Expect CREATE TABLE for stocks, klines, training_sets."""
    stmts = _parse_schema()
    table_names = {
        s.stmt.relation.relname
        for s in stmts
        if isinstance(s.stmt, CreateStmt)
    }
    assert table_names == {"stocks", "klines", "training_sets", "stock_coverage"}, (
        f"expected {{stocks,klines,training_sets,stock_coverage}}, got {table_names}"
    )


def test_training_sets_content_hash_char8_not_null():
    """training_sets.content_hash must be CHAR(8) NOT NULL."""
    stmts = _parse_schema()
    training_sets = next(
        s.stmt
        for s in stmts
        if isinstance(s.stmt, CreateStmt)
        and s.stmt.relation.relname == "training_sets"
    )
    col = next(
        e for e in training_sets.tableElts
        if hasattr(e, "colname") and e.colname == "content_hash"
    )
    type_names = [n.sval for n in col.typeName.names]
    # pglast expresses CHAR(N) as pg_catalog.bpchar with typmods=[N]
    assert type_names[-1] in ("bpchar", "char"), f"content_hash type: {type_names}"
    typmods = col.typeName.typmods or ()
    assert len(typmods) == 1
    assert typmods[0].val.ival == 8, f"content_hash length: {typmods[0].val.ival}"
    not_null = any(
        getattr(c, "contype", None) is not None
        and c.contype == pglast.enums.ConstrType.CONSTR_NOTNULL
        for c in (col.constraints or ())
    )
    assert not_null, "content_hash must be NOT NULL"


def test_training_sets_has_uq_stock_start():
    """Table-level UNIQUE(stock_code, start_datetime) must be named uq_stock_start."""
    stmts = _parse_schema()
    training_sets = next(
        s.stmt
        for s in stmts
        if isinstance(s.stmt, CreateStmt)
        and s.stmt.relation.relname == "training_sets"
    )
    table_constraints = [
        e for e in training_sets.tableElts if isinstance(e, Constraint)
    ]
    names = [c.conname for c in table_constraints if c.conname]
    assert "uq_stock_start" in names, f"constraints: {names}"


def test_training_sets_has_lease_columns():
    """Expect lease_id UUID / lease_expires_at TIMESTAMPTZ / reserved_at TIMESTAMPTZ."""
    stmts = _parse_schema()
    training_sets = next(
        s.stmt
        for s in stmts
        if isinstance(s.stmt, CreateStmt)
        and s.stmt.relation.relname == "training_sets"
    )
    cols = {
        e.colname: [n.sval for n in e.typeName.names]
        for e in training_sets.tableElts
        if hasattr(e, "colname")
    }
    assert cols.get("lease_id", [])[-1:] == ["uuid"], f"lease_id: {cols.get('lease_id')}"
    assert cols.get("lease_expires_at", [])[-1:] == ["timestamptz"], cols.get("lease_expires_at")
    assert cols.get("reserved_at", [])[-1:] == ["timestamptz"], cols.get("reserved_at")


def test_training_sets_partial_indexes_exist():
    """idx_training_sets_lease (partial WHERE lease_id IS NOT NULL) + idx_training_sets_lease_expire."""
    stmts = _parse_schema()
    indexes = {
        s.stmt.idxname: s.stmt
        for s in stmts
        if isinstance(s.stmt, IndexStmt)
    }
    assert "idx_training_sets_lease" in indexes
    assert "idx_training_sets_lease_expire" in indexes
    assert "idx_klines_lookup" in indexes
    assert indexes["idx_training_sets_lease"].whereClause is not None, \
        "idx_training_sets_lease must be partial (WHERE lease_id IS NOT NULL)"
    assert indexes["idx_training_sets_lease_expire"].whereClause is not None, \
        "idx_training_sets_lease_expire must be partial (WHERE status='reserved')"


def test_klines_unique_stock_period_datetime():
    """klines needs UNIQUE(stock_code, period, datetime) (inline table constraint)."""
    stmts = _parse_schema()
    klines = next(
        s.stmt
        for s in stmts
        if isinstance(s.stmt, CreateStmt) and s.stmt.relation.relname == "klines"
    )
    uniques = [
        c for c in klines.tableElts
        if isinstance(c, Constraint) and c.contype == pglast.enums.ConstrType.CONSTR_UNIQUE
    ]
    found = False
    for c in uniques:
        keys = [k.sval for k in (c.keys or ())]
        if set(keys) == {"stock_code", "period", "datetime"}:
            found = True
            break
    assert found, "klines UNIQUE(stock_code, period, datetime) missing"


def test_training_sets_has_required_check_constraints():
    """v1.4 M0.1 runtime invariants (codex round 8): three CHECK constraints by name."""
    stmts = _parse_schema()
    training_sets = next(
        s.stmt
        for s in stmts
        if isinstance(s.stmt, CreateStmt)
        and s.stmt.relation.relname == "training_sets"
    )
    checks = [
        c for c in training_sets.tableElts
        if isinstance(c, Constraint) and c.contype == pglast.enums.ConstrType.CONSTR_CHECK
    ]
    names = {c.conname for c in checks if c.conname}
    required = {
        "ck_content_hash_crc32_lowercase",
        "ck_status_enum",
        "ck_lease_state_invariant",
    }
    missing = required - names
    assert not missing, f"missing CHECK constraints: {missing}; got {names}"


# ---- Plan 2a：D1 DDL（OHLC DOUBLE / file_path TEXT / stock_coverage）----

def _column_type_names(table: str) -> dict:
    """表名 → {列名: 小写类型名}（pglast AST，TypeName.names 末段即类型名）。"""
    stmts = _parse_schema()
    create = next(
        s.stmt for s in stmts
        if isinstance(s.stmt, CreateStmt) and s.stmt.relation.relname == table
    )
    out = {}
    for elt in create.tableElts:
        colname = getattr(elt, "colname", None)
        typename = getattr(elt, "typeName", None)
        if colname and typename is not None:
            out[colname] = typename.names[-1].sval.lower()
    return out


def test_klines_ohlc_are_double_precision():
    """D1：前复权 float64 全精度入库；DECIMAL(10,2) 会压塌老 K 线。"""
    cols = _column_type_names("klines")
    for c in ("open", "high", "low", "close"):
        assert cols[c] == "float8", f"klines.{c} 期望 double precision，实为 {cols[c]}"


def test_klines_amount_and_indicators_stay_decimal():
    """D1 明确只改价格列；amount/指标列不变（改了就是超范围 DDL）。"""
    cols = _column_type_names("klines")
    assert cols["amount"] == "numeric"
    for c in ("ma66", "boll_upper", "boll_mid", "boll_lower",
              "macd_diff", "macd_dea", "macd_bar"):
        assert cols[c] == "numeric", f"klines.{c} 不应被改动"


def test_klines_ticket_index_column_retained():
    """D3/R12-F1：ticket_index 只停写、列必须保留（删列 = 不可逆迁移违规）。"""
    cols = _column_type_names("klines")
    assert "ticket_index" in cols, "ticket_index 列被删了——违反 m01 不可逆迁移禁令"


def test_training_sets_file_path_is_text():
    """R16-F2：绝对路径任意长，VARCHAR(255) 会让登记 INSERT 失败留 orphan。"""
    cols = _column_type_names("training_sets")
    assert cols["file_path"] == "text", f"file_path 期望 text，实为 {cols['file_path']}"


def test_stock_coverage_table_columns():
    """D11：B1 写 / B2 读的覆盖契约表五列。"""
    cols = _column_type_names("stock_coverage")
    assert set(cols) == {"stock_code", "dense_1m_start_date", "dense_1m_end_date",
                         "dropped_1m_dates", "dense_day_count"}
    assert cols["dropped_1m_dates"] == "jsonb", "须为 JSONB 以便 DB 层校验数组类型"


def test_stock_coverage_has_integrity_checks():
    """codex PF2-R2-F1：坏覆盖行会让 B2 reader 抛非-Skip 异常、中止整轮 sweep。
    约束必须在 DB 层可执行，不能只靠 reader 兜底。"""
    # 同 PF2-R3-F2：schema.sql 也用多空格对齐（`dense_1m_end_date   DATE NOT NULL`），
    # 必须先压平空白再子串断言，否则本测必挂。需在本文件顶部加 `import re`。
    sql = re.sub(r"\s+", " ", re.sub(r"--[^\n]*", " ",
                 SCHEMA_PATH.read_text(encoding="utf-8"))).lower()
    seg = sql.split("create table if not exists stock_coverage")[1].split(");")[0]
    assert "jsonb_typeof(dropped_1m_dates) = 'array'" in seg, "缺 dropped 数组类型检查"
    assert "dense_1m_start_date <= dense_1m_end_date" in seg, "缺覆盖带非反向检查"
    assert "dense_day_count >= 0" in seg, "缺计数非负检查"
    for col in ("dense_1m_start_date", "dense_1m_end_date", "dense_day_count"):
        assert f"{col} date not null" in seg or f"{col} integer not null" in seg, \
            f"{col} 应为 NOT NULL"
