"""Validate backend/sql/schema.sql: PostgreSQL 15 syntax + expected AST objects.

Uses pglast (libpg_query bindings) so no Docker or daemon is required.
Production deployment validation (on NAS PostgreSQL) is Wave 1 B3 owner scope.
"""
from __future__ import annotations

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
    assert table_names == {"stocks", "klines", "training_sets"}, (
        f"expected {{stocks,klines,training_sets}}, got {table_names}"
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
