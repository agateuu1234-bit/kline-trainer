# backend/qmt_resample.py
"""QMT 合成层（纯函数）。Spec: 2026-07-06-qmt-data-ingestion-pilot-design.md §4.2。"""
from __future__ import annotations
import datetime as _dt
from zoneinfo import ZoneInfo
import pandas as pd
from qmt_normalize import trading_date

_SH = ZoneInfo("Asia/Shanghai")
# 合成输出统一 OHLCV 列；空结果也带此 schema，避免 pd.DataFrame([]).sort_values 抛 KeyError（PF1-R9-F2/F3）
_OHLCV_COLS = ["datetime", "open", "high", "low", "close", "volume", "amount"]
# 段名义起点（分钟数，自 00:00 起算）与每段时长
_MORNING_START = 9 * 60 + 30    # 09:30
_AFTERNOON_START = 13 * 60      # 13:00
_SESSION_MINUTES = 120

def _mins_of_day(epoch: int) -> int:
    t = _dt.datetime.fromtimestamp(epoch, _SH)
    return t.hour * 60 + t.minute

def _bucket_label_minute(close_min: int, minutes: int) -> int | None:
    """1m 收盘分钟(自 00:00) → 其所属桶的 label 分钟；跨午休/盘外返回 None。"""
    for start in (_MORNING_START, _AFTERNOON_START):
        lo, hi = start, start + _SESSION_MINUTES
        if start <= close_min <= hi:
            # 上午首桶含左端点 start（集竞）；其余桶 (b-N, b]
            k = max(1, -(-(close_min - start) // minutes))  # ceil，但 close_min==start → k=1
            if close_min == start:
                k = 1
            return start + k * minutes
    return None

def _agg(members: pd.DataFrame) -> dict:
    m = members.sort_values("datetime")
    return {"open": float(m.iloc[0]["open"]), "close": float(m.iloc[-1]["close"]),
            "high": float(m["high"].max()), "low": float(m["low"].min()),
            "volume": int(m["volume"].sum()), "amount": float(m["amount"].sum())}

def resample_intraday(df_1m: pd.DataFrame, minutes: int) -> pd.DataFrame:
    if df_1m.empty:
        return df_1m.copy()
    df = df_1m.copy()
    df["_date"] = df["datetime"].map(trading_date)
    df["_cm"] = df["datetime"].map(_mins_of_day)
    df["_label_min"] = df["_cm"].map(lambda c: _bucket_label_minute(c, minutes))
    df = df[df["_label_min"].notna()]
    out_rows = []
    for (d, lm), grp in df.groupby(["_date", "_label_min"]):
        h, mnt = divmod(int(lm), 60)
        label_epoch = int(_dt.datetime(d.year, d.month, d.day, h, mnt, 0, tzinfo=_SH).timestamp())
        out_rows.append({"datetime": label_epoch, **_agg(grp)})
    # PF1-R9-F2：全盘外输入 → out_rows 空；带列构造避免 sort_values 抛 KeyError（空 resample，覆盖层负责 drop 该日）
    return pd.DataFrame(out_rows, columns=_OHLCV_COLS).sort_values("datetime").reset_index(drop=True)

def _period_key(d, rule: str):
    if rule == "weekly":
        iso = d.isocalendar()
        return (iso[0], iso[1])
    return (d.year, d.month)      # monthly

def _first_day_midnight_epoch(d) -> int:
    return int(_dt.datetime(d.year, d.month, d.day, 0, 0, 0, tzinfo=_SH).timestamp())

def period_boundaries(df_daily: pd.DataFrame, rule: str) -> list[int]:
    """每周期首交易日午夜 Unix 秒（含当前 partial 周期哨兵；≠ emit 的 bar）。"""
    dates = sorted({trading_date(e) for e in df_daily["datetime"]})
    bounds, seen = [], set()
    for d in dates:
        k = _period_key(d, rule)
        if k not in seen:
            seen.add(k); bounds.append(_first_day_midnight_epoch(d))
    return bounds

def resample_calendar(df_daily: pd.DataFrame, rule: str) -> pd.DataFrame:
    if df_daily.empty:
        return df_daily.copy()
    df = df_daily.copy()
    df["_d"] = df["datetime"].map(trading_date)
    df["_k"] = df["_d"].map(lambda d: _period_key(d, rule))
    all_keys = sorted(set(df["_k"]))
    complete_keys = set(all_keys[:-1])   # 除最后一个周期（当前 partial，无后续周期）外都完整
    out_rows = []
    for k, grp in df.groupby("_k"):
        if k not in complete_keys:
            continue
        first_d = min(grp["_d"])
        out_rows.append({"datetime": _first_day_midnight_epoch(first_d), **_agg(grp)})
    # PF1-R9-F3：仅一个周期（当前 partial）→ complete_keys 空 → out_rows 空；带列构造避免 sort_values 抛 KeyError
    return pd.DataFrame(out_rows, columns=_OHLCV_COLS).sort_values("datetime").reset_index(drop=True)
