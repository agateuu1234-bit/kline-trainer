# backend/qmt_normalize.py
"""QMT 真实数据规整层（纯函数）。Spec: 2026-07-06-qmt-data-ingestion-pilot-design.md §4.1。"""
from __future__ import annotations
import datetime as _dt
from zoneinfo import ZoneInfo
import pandas as pd

_SH = ZoneInfo("Asia/Shanghai")

def trading_date(epoch: int) -> _dt.date:
    """Unix 秒 → Asia/Shanghai 交易日期（所有日期分组/比对的唯一入口，禁 UTC/naive）。"""
    return _dt.datetime.fromtimestamp(int(epoch), _SH).date()

def parse_qmt_datetime(series: pd.Series, src_period: str) -> pd.Series:
    """QMT 打包整数时间 → Unix 秒（Int64）。1m=YYYYMMDDHHMMSS(14 位)、daily=YYYYMMDD(8 位)，
    按 Asia/Shanghai 本地化（naive→带 tz→timestamp），非直接当 Unix 秒。"""
    fmt = "%Y%m%d%H%M%S" if src_period == "1m" else "%Y%m%d"
    def _one(v: int) -> int:
        naive = _dt.datetime.strptime(str(int(v)), fmt)
        return int(naive.replace(tzinfo=_SH).timestamp())
    return series.map(_one).astype("int64")
