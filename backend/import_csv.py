# backend/import_csv.py
# Spec: kline_trainer_modules_v1.4.md §四 B1 (L718-723) + plan v1.5 §6.4.1 + klines DDL L325-363
#
# 双层（D1）：纯函数层（parse/clean/compute_indicators/compute_ticket_index/to_kline_records）
# host pytest 全测、不碰 DB；薄 asyncpg 写库壳 + CLI 在同文件下半（D14，CI 不单测，B3/NAS scope）。
#
# 决议：
# - D2 指标用 pandas 内建 rolling/ewm 直算（非 pandas-ta，beta 不稳定 + 要可测精确值；前端只读 B1 输出）
# - D3 MA66 = SMA(close,66)，前 65 行 NULL，round(4)
# - D4 BOLL = SMA(close,20) ± 2*std(ddof=0 总体)，前 19 行 NULL，round(4)
# - D5 MACD: DIF=EMA12-EMA26 / DEA=EMA(DIF,9) / BAR=(DIF-DEA)*2；ewm(adjust=False)；round(6)
# - D6 ticket_index：1m 升序 0,1,2…；其它周期 searchsorted 到 1m 基准
# - D7 必需列 datetime/open/high/low/close/volume；datetime→Unix 秒 Int64；缺列抛 CsvSchemaError
# - D9 清洗丢 NaN/非正价/high<low/越界 + 去重(keep last) + 升序
from __future__ import annotations

from pathlib import Path
from typing import Any, Optional, Sequence

import numpy as np
import pandas as pd

REQUIRED_COLUMNS = ("datetime", "open", "high", "low", "close", "volume")
_PRICE_COLS = ("open", "high", "low", "close")


class CsvSchemaError(ValueError):
    """CSV 缺必需列 / 无法解析。"""


def parse_csv(path: Path) -> pd.DataFrame:
    """读 CSV → DataFrame；datetime 解析为 Unix 秒 Int64（D7）。"""
    df = pd.read_csv(path)
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise CsvSchemaError(f"CSV 缺必需列: {missing}")
    df["datetime"] = _to_unix_seconds(df["datetime"])
    return df


def _to_unix_seconds(s: pd.Series) -> pd.Series:
    """接受整数秒或 'YYYY-MM-DD HH:MM:SS' 字符串 → Int64 秒。"""
    if pd.api.types.is_numeric_dtype(s):
        return s.astype("int64")
    dt = pd.to_datetime(s, utc=True, errors="coerce")
    if dt.isna().any():
        raise CsvSchemaError("datetime 列存在无法解析的值")
    # R1-M1：Series.view 在 pandas 2.2.3 已 deprecated；用 astype("int64") 取 ns 再 //1e9。
    return (dt.astype("int64") // 1_000_000_000).astype("int64")


def clean(df: pd.DataFrame) -> pd.DataFrame:
    """D9：校验必需列 → 丢异常行 → 去重(keep last) → datetime 升序。"""
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise CsvSchemaError(f"缺必需列: {missing}")
    out = df.copy()
    out = out.dropna(subset=list(REQUIRED_COLUMNS))
    for c in _PRICE_COLS:
        out = out[out[c] > 0]
    out = out[out["high"] >= out["low"]]
    out = out[out["high"] >= out[["open", "close"]].max(axis=1)]
    out = out[out["low"] <= out[["open", "close"]].min(axis=1)]
    out = out.drop_duplicates(subset=["datetime"], keep="last")
    out = out.sort_values("datetime").reset_index(drop=True)
    return out


def compute_indicators(df: pd.DataFrame) -> pd.DataFrame:
    """D2-D5：MA66 / BOLL(20,2,ddof=0) / MACD(12,26,9, BAR×2)。返回带指标列的新 df。"""
    out = df.copy()
    close = out["close"].astype(float)

    out["ma66"] = close.rolling(window=66, min_periods=66).mean().round(4)

    mid = close.rolling(window=20, min_periods=20).mean()
    std = close.rolling(window=20, min_periods=20).std(ddof=0)
    out["boll_mid"] = mid.round(4)
    out["boll_upper"] = (mid + 2 * std).round(4)
    out["boll_lower"] = (mid - 2 * std).round(4)

    ema12 = close.ewm(span=12, adjust=False).mean()
    ema26 = close.ewm(span=26, adjust=False).mean()
    dif = ema12 - ema26
    dea = dif.ewm(span=9, adjust=False).mean()
    out["macd_diff"] = dif.round(6)
    out["macd_dea"] = dea.round(6)
    out["macd_bar"] = ((dif - dea) * 2).round(6)
    return out


def compute_ticket_index(
    df: pd.DataFrame,
    period: str,
    baseline_1m_datetimes: Optional[Sequence[int]],
) -> list[int]:
    """D6：1m → 升序 0,1,2…；其它周期 → searchsorted 到 1m 基准 datetime 数组。"""
    if period == "1m":
        return list(range(len(df)))
    if baseline_1m_datetimes is None:
        raise ValueError(f"period={period} 需要 1m 基准 datetimes 才能映射 ticket_index")
    base = np.asarray(sorted(baseline_1m_datetimes), dtype="int64")
    return [int(np.searchsorted(base, int(dt))) for dt in df["datetime"]]


# R1-H2：BIGINT/INTEGER 列必须是 Python int，其余 DECIMAL 列是 Python float。
# df.iterrows() 会把整行升格成单一 float64 dtype → datetime/volume/ticket_index 变 numpy.float64
# → asyncpg int8/int4 codec 拒收。故按列显式 cast，不用 iterrows()。
_INT_COLS = ("datetime", "volume", "ticket_index")
_FLOAT_COLS = ("open", "high", "low", "close", "amount", "ma66",
               "boll_upper", "boll_mid", "boll_lower",
               "macd_diff", "macd_dea", "macd_bar")


def _int_or_none(v: Any) -> Optional[int]:
    if v is None:
        return None
    if isinstance(v, float) and np.isnan(v):
        return None
    return int(v)


def _float_or_none(v: Any) -> Optional[float]:
    if v is None:
        return None
    fv = float(v)
    if np.isnan(fv):
        return None
    return fv


def to_kline_records(df: pd.DataFrame, stock_code: str, period: str) -> list[dict]:
    """把带指标 + ticket_index 的 df 转成入库 record dict 列表。
    R1-H2：整数列 → Python int，浮点列 → Python float（非 numpy 标量），NaN → None。
    用 to_dict('records') 保留各列原 dtype，再逐列 cast（避免 iterrows() float64 升格）。"""
    rows = df.to_dict("records")
    records: list[dict] = []
    for row in rows:
        rec: dict[str, Any] = {"stock_code": stock_code, "period": period}
        for c in _INT_COLS:
            rec[c] = _int_or_none(row.get(c))
        for c in _FLOAT_COLS:
            rec[c] = _float_or_none(row.get(c))
        records.append(rec)
    return records
