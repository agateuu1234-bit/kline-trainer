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
