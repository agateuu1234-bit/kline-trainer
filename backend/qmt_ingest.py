# backend/qmt_ingest.py
"""QMT B1 装配层（纯函数，无 asyncpg）。Spec: 2026-07-23-qmt-plan3-b1-ingest-coverage-design.md。"""
from __future__ import annotations

import random as _random
from dataclasses import dataclass

import numpy as np
import pandas as pd

from generate_training_sets import (GenerateSkipException, PERIOD_BEFORE_CAP, PERIODS,
                                    build_training_windows)
from import_csv import _INT_COLS, clean, compute_indicators, to_kline_records
from qmt_normalize import (QmtSchemaError, parse_qmt_datetime, parse_qmt_filename,
                           trading_date)
from qmt_resample import (build_intraday, compute_dense_coverage, period_boundaries,
                          reconcile_sources, resample_calendar)

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


@dataclass(frozen=True)
class CoverageArtifact:
    start_date: object
    end_date: object
    dropped_dates: list
    dense_day_count: int


@dataclass(frozen=True)
class ImportBundle:
    records: dict
    coverage: CoverageArtifact


def _reject(reason: str):
    raise QmtIngestRejected(reason)


def _assert_values_ok(df, label: str):
    """1m/daily 每行 amount 有限非空 + volume 有限整数 >= 0（P3-D9(c)/R15-F2/R16-F2）。"""
    amt = df["amount"].to_numpy(dtype="float64")
    if not np.all(np.isfinite(amt)):
        _reject("bad_amount_or_volume")
    vol = df["volume"].to_numpy(dtype="float64")
    if not np.all(np.isfinite(vol)) or np.any(vol < 0) or np.any(vol != np.floor(vol)):
        _reject("bad_amount_or_volume")


def build_stock_import(src_1m, src_daily, *, stock_code, stock_name, entry_1m, entry_daily):
    """一只股的六周期装配（B1 核心）：逐门跑过导入期全部校验，任一门失败抛
    `QmtIngestRejected(reason)`，零部分产出。门执行顺序见 spec §4.1（模块 docstring）。"""
    # 门1：四方身份一致（R14-F1/R15-F1，if/raise 非 assert）
    for obj, per in ((src_1m, "1m"), (src_daily, "daily"),
                     (entry_1m, "1m"), (entry_daily, "daily")):
        if obj.code != stock_code or obj.period != per:
            _reject("source_identity_mismatch")

    raw_1m, raw_daily = src_1m.df, src_daily.df

    # 门2：拷贝完整性（clean 前 raw 行数/端点 vs export_log，P3-D9(b)）
    for raw, ent in ((raw_1m, entry_1m), (raw_daily, entry_daily)):
        if (len(raw) != ent.rows
                or int(raw.iloc[0]["datetime"]) != ent.first_time
                or int(raw.iloc[-1]["datetime"]) != ent.last_time):
            _reject("export_log_mismatch")

    # clean
    cln_1m, cln_daily = clean(raw_1m), clean(raw_daily)

    # 门3：原始值门（1m+daily amount/volume；daily 另加 clean-len 无损，P3-D9(c)）
    _assert_values_ok(cln_1m, "1m")
    _assert_values_ok(cln_daily, "daily")
    if len(cln_daily) != len(raw_daily) or raw_daily["datetime"].duplicated().any():
        _reject("daily_clean_dropped_rows")

    # 门4：D10 双源对账（status 门在此，P3-D3）
    rc = reconcile_sources(cln_1m, cln_daily,
                           status_1m=entry_1m.status, status_daily=entry_daily.status)
    if not rc.ok:
        _reject(rc.reason)

    # 合成
    intraday, cov = build_intraday(cln_1m)
    weekly = resample_calendar(cln_daily, "weekly")
    monthly = resample_calendar(cln_daily, "monthly")
    period_dfs = {"monthly": monthly, "weekly": weekly, "daily": cln_daily,
                  "60m": intraday["60m"], "15m": intraday["15m"], "3m": intraday["3m"]}
    for p in PERIODS:
        if period_dfs[p].empty:
            _reject("no_intraday_after_dense_filter" if p in ("3m", "15m", "60m") else "empty_period")

    # 门5：出货可行性预检 = 跑 B2 出货本体 build_training_windows 全门 + 传 dropped（P3-D9(a)/R16-F1）
    dense_dates = set(cov.complete_dates)
    trading_dates = sorted({trading_date(int(e)) for e in cln_daily["datetime"]})
    month_boundaries = period_boundaries(cln_daily, "monthly")
    n_cand = max(1, len(month_boundaries))
    try:
        build_training_windows(period_dfs, month_boundaries, _random.Random(0),
                               dense_dates=dense_dates, trading_dates=trading_dates,
                               before_caps=PERIOD_BEFORE_CAP,
                               dropped=frozenset(cov.dropped_dates),
                               max_retries=n_cand)
    except GenerateSkipException:
        _reject("no_eligible_training_window")

    # 逐周期指标 + records
    records = {p: to_kline_records(compute_indicators(period_dfs[p].copy()), stock_code, p)
               for p in PERIODS}
    coverage = CoverageArtifact(start_date=cov.start_date, end_date=cov.end_date,
                                dropped_dates=list(cov.dropped_dates),
                                dense_day_count=len(cov.complete_dates))
    return ImportBundle(records=records, coverage=coverage)
