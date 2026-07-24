# backend/tests/_qmt_fixtures.py
"""QMT B1 装配层测试 fixture 生成器（Task2/6/9 共用）。
造「足够 B2 出一个训练组」的最小合法输入：日线数年（≥39 个月边界）、1m 覆盖近一年、
每交易日精确 241 根（session 分钟 09:30-11:30 + 13:01-15:00）、零 drop、OHLC 合法、
volume 正整数、amount 有限。返回 (src_1m: QmtSource, src_daily: QmtSource, entry_1m, entry_daily)。
"""
from __future__ import annotations

import datetime as dt
from zoneinfo import ZoneInfo

import pandas as pd
import pytest

from qmt_ingest import ExportLogEntry
from qmt_normalize import QmtSource

_SH = ZoneInfo("Asia/Shanghai")
SESSION_MIN = list(range(9 * 60 + 30, 11 * 60 + 30 + 1)) + list(range(13 * 60 + 1, 15 * 60 + 0 + 1))  # 241


def _epoch(d, minute):
    h, m = divmod(minute, 60)
    return int(dt.datetime(d.year, d.month, d.day, h, m, tzinfo=_SH).timestamp())


def gen_valid_sources(code="000001.SZ", n_years_daily=4, n_days_1m=250):
    # 交易日：跳周末（够用即可，无需真实节假日）
    days, d = [], dt.date(2020, 1, 2)
    while len(days) < n_years_daily * 250:
        if d.weekday() < 5:
            days.append(d)
        d += dt.timedelta(days=1)
    # daily：volume/amount 必须 == 1m 日聚合（否则 reconcile_sources 的 D10 值对账 ohlcv_mismatch）。
    # 每日 241 根 1m，各 volume=10/amount=102 → 日聚合 volume=2410, amount=24582。
    # OHLC：1m open=首=10.0 / close=尾=10.2 / high=max=10.5 / low=min=9.5 → 日 bar 同值。
    # dense span 外的深历史日无 1m、D10 不对账 → 用同值即可（不影响对账）。
    DAILY_VOL, DAILY_AMT = 241 * 10, round(241 * 102.0, 2)
    drows = [{"datetime": _epoch(x, 0), "open": 10.0, "high": 10.5, "low": 9.5,
              "close": 10.2, "volume": DAILY_VOL, "amount": DAILY_AMT} for x in days]
    df_daily = pd.DataFrame(drows)
    # 1m：最后 n_days_1m 个交易日，每日 241 根
    m1 = []
    for x in days[-n_days_1m:]:
        for mnt in SESSION_MIN:
            m1.append({"datetime": _epoch(x, mnt), "open": 10.0, "high": 10.5,
                       "low": 9.5, "close": 10.2, "volume": 10, "amount": 102.0})
    df_1m = pd.DataFrame(m1)
    s1 = QmtSource(code, "1m", df_1m)
    sd = QmtSource(code, "daily", df_daily)
    e1 = ExportLogEntry(code, "1m", "ok", len(df_1m), int(df_1m.iloc[0]["datetime"]),
                        int(df_1m.iloc[-1]["datetime"]), code)
    ed = ExportLogEntry(code, "daily", "ok", len(df_daily), int(df_daily.iloc[0]["datetime"]),
                        int(df_daily.iloc[-1]["datetime"]), code)
    return s1, sd, e1, ed


@pytest.fixture
def gen():
    return gen_valid_sources
