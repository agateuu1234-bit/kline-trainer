# backend/tests/test_qmt_normalize.py
from __future__ import annotations
import datetime as dt
import pandas as pd
import pytest
from zoneinfo import ZoneInfo
from qmt_normalize import trading_date, parse_qmt_datetime

SH = ZoneInfo("Asia/Shanghai")

def _epoch(y, mo, d, h, mi, s):
    return int(dt.datetime(y, mo, d, h, mi, s, tzinfo=SH).timestamp())

def test_trading_date_sh_midnight_and_intraday_same_date():
    # 沪午夜 daily 与盘中 3m 归到同一交易日（UTC 日期差一天也不错位）
    daily = _epoch(2026, 7, 3, 0, 0, 0)      # 20260703 00:00 沪
    intr = _epoch(2026, 7, 3, 9, 33, 0)      # 20260703 09:33 沪
    assert trading_date(daily) == dt.date(2026, 7, 3)
    assert trading_date(intr) == dt.date(2026, 7, 3)

def test_parse_qmt_datetime_1m_14digit():
    s = pd.Series([20260703093000, 20260703150000])
    out = parse_qmt_datetime(s, "1m")
    assert list(out) == [_epoch(2026, 7, 3, 9, 30, 0), _epoch(2026, 7, 3, 15, 0, 0)]

def test_parse_qmt_datetime_daily_8digit_is_sh_midnight():
    s = pd.Series([19910105, 20260703])
    out = parse_qmt_datetime(s, "daily")
    assert list(out) == [_epoch(1991, 1, 5, 0, 0, 0), _epoch(2026, 7, 3, 0, 0, 0)]
