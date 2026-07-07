# backend/qmt_normalize.py
"""QMT 真实数据规整层（纯函数）。Spec: 2026-07-06-qmt-data-ingestion-pilot-design.md §4.1。"""
from __future__ import annotations
import datetime as _dt
import re
from pathlib import Path
from zoneinfo import ZoneInfo
import pandas as pd

_SH = ZoneInfo("Asia/Shanghai")

_QMT_COLUMNS = ("time", "open", "high", "low", "close", "volume", "amount")
_FILENAME_RE = re.compile(
    r"^(?P<code>\d+\.(?:SH|SZ|BJ))_(?P<name>.+)_(?P<label>1分钟K线|日K线)_前复权\.csv$"
)
_LABEL_TO_PERIOD = {"1分钟K线": "1m", "日K线": "daily"}

class QmtSchemaError(ValueError):
    """QMT CSV 缺列 / 文件名不合规。"""

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

def parse_qmt_filename(name: str) -> tuple[str, str, str]:
    m = _FILENAME_RE.match(name)
    if not m:
        raise QmtSchemaError(f"文件名不符合 QMT 规则: {name!r}")
    return m["code"], m["name"], _LABEL_TO_PERIOD[m["label"]]

def parse_qmt_csv(path: Path, src_period: str) -> pd.DataFrame:
    df = pd.read_csv(path, encoding="utf-8-sig")   # utf-8-sig 剥 BOM
    missing = [c for c in _QMT_COLUMNS if c not in df.columns]
    if missing:
        raise QmtSchemaError(f"QMT CSV 缺必需列: {missing}")
    df = df.rename(columns={"time": "datetime"})
    df["datetime"] = parse_qmt_datetime(df["datetime"], src_period)
    return df[["datetime", "open", "high", "low", "close", "volume", "amount"]]
