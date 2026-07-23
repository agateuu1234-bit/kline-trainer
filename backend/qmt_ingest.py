# backend/qmt_ingest.py
"""QMT B1 装配层（纯函数，无 asyncpg）。Spec: 2026-07-23-qmt-plan3-b1-ingest-coverage-design.md。"""
from __future__ import annotations

import datetime as _dt
import math
from dataclasses import dataclass

import pandas as pd

from qmt_normalize import (QmtSchemaError, parse_qmt_datetime, parse_qmt_filename,
                           trading_date)

_STOCK_COL_CANDIDATES = ("stock", "code", "stock_code", "file", "filename")
_LABEL_TO_PERIOD = {"1分钟K线": "1m", "日K线": "daily", "1m": "1m", "daily": "daily"}
_REQUIRED_LOG_COLS = ("period", "status", "rows", "first_time", "last_time")


class QmtIngestRejected(Exception):
    """一只股被某道导入期门拒；str(exc) 即机器可读 reason。"""


@dataclass(frozen=True)
class ExportLogEntry:
    code: str
    period: str
    status: str
    rows: int
    first_time: int
    last_time: int
    source: str


def _norm_code(raw: str) -> str:
    """标识值若形如 QMT 文件名 → 取 code；否则按裸 code 返回。"""
    try:
        code, _n, _p = parse_qmt_filename(str(raw))
        return code
    except QmtSchemaError:
        return str(raw).strip()


def parse_export_log(path) -> dict[tuple[str, str], ExportLogEntry]:
    df = pd.read_csv(path, encoding="utf-8-sig", dtype=str)
    missing = [c for c in _REQUIRED_LOG_COLS if c not in df.columns]
    if missing:
        raise QmtSchemaError(f"export_log 缺列: {missing}")
    id_col = next((c for c in _STOCK_COL_CANDIDATES if c in df.columns), None)
    if id_col is None:
        raise QmtSchemaError(f"export_log 无股票标识列（候选 {_STOCK_COL_CANDIDATES}）")
    out: dict[tuple[str, str], ExportLogEntry] = {}
    for _, row in df.iterrows():
        period = _LABEL_TO_PERIOD.get(str(row["period"]).strip())
        if period is None:
            continue
        code = _norm_code(row[id_col])
        key = (code, period)
        if key in out:
            raise QmtSchemaError(f"export_log_duplicate: {key} 出现多行")
        # first_time/last_time 用同一套 QMT 打包整数解析（解析不出 → 报错停下）
        ft = int(parse_qmt_datetime(pd.Series([row["first_time"]]), period).iloc[0])
        lt = int(parse_qmt_datetime(pd.Series([row["last_time"]]), period).iloc[0])
        out[key] = ExportLogEntry(code=code, period=period, status=str(row["status"]).strip(),
                                  rows=int(row["rows"]), first_time=ft, last_time=lt,
                                  source=str(row[id_col]))
    return out
