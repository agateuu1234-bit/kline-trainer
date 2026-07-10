# backend/tests/test_qmt_resample.py
from __future__ import annotations
import datetime as dt
import pandas as pd
from zoneinfo import ZoneInfo
from qmt_resample import resample_intraday, resample_calendar, period_boundaries

SH = ZoneInfo("Asia/Shanghai")

def _ep(hhmm: int, day=(2026, 7, 3)) -> int:
    h, m = divmod(hhmm, 100)
    return int(dt.datetime(*day, h, m, 0, tzinfo=SH).timestamp())

def _full_day_1m() -> pd.DataFrame:
    """完整交易日 241 根：0930..1130(121) + 1301..1500(120)。close=递增序号便于定位。"""
    times = []
    t = 930
    while t <= 1130:                       # 上午 121
        times.append(t); m = t % 100; t = t + (1 if m < 59 else 41)
    t = 1301
    while t <= 1500:                       # 下午 120
        times.append(t); m = t % 100; t = t + (1 if m < 59 else 41)
    rows = [{"datetime": _ep(hh), "open": float(i), "high": float(i) + 0.5,
             "low": float(i) - 0.5, "close": float(i), "volume": 1, "amount": 1.0}
            for i, hh in enumerate(times)]
    return pd.DataFrame(rows)

def test_intraday_full_day_totals():
    df = _full_day_1m()
    assert len(resample_intraday(df, 3)) == 80
    assert len(resample_intraday(df, 15)) == 16
    assert len(resample_intraday(df, 60)) == 4

def test_intraday_3m_first_bucket_includes_open_auction():
    df = _full_day_1m()
    out = resample_intraday(df, 3).sort_values("datetime").reset_index(drop=True)
    # 上午首桶 label=0933，成员 {0930,0931,0932,0933}=4 根 → open=首成员 open(=idx0 的 open=0.0)
    first = out.iloc[0]
    assert first["datetime"] == _ep(933)
    assert first["open"] == 0.0                      # 09:30 集竞根 open
    assert first["close"] == 3.0                     # 0933 根 close（成员序号 0,1,2,3）
    assert first["volume"] == 4                       # 4 根 1m

def test_intraday_no_cross_lunch():
    df = _full_day_1m()
    out = resample_intraday(df, 60).sort_values("datetime").reset_index(drop=True)
    labels = [dt.datetime.fromtimestamp(x, SH).strftime("%H%M") for x in out["datetime"]]
    assert labels == ["1030", "1130", "1400", "1500"]  # 4 桶、午休不并

def test_intraday_out_of_session_only_returns_empty_no_crash():
    # PF1-R9-F2：非空输入但全部盘外（午休 12:00）→ 空结果 + 正确 schema，不抛 KeyError
    rows = [{"datetime": int(dt.datetime(2026, 7, 1, 12, 0, 0, tzinfo=SH).timestamp()),
             "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0, "volume": 1, "amount": 1.0}]
    out = resample_intraday(pd.DataFrame(rows), 3)
    assert out.empty
    assert list(out.columns) == ["datetime", "open", "high", "low", "close", "volume", "amount"]

def _daily(dates: list[tuple[int,int,int]]) -> pd.DataFrame:
    rows = [{"datetime": int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp()),
             "open": float(i), "high": float(i)+1, "low": float(i)-1, "close": float(i)+0.5,
             "volume": 10, "amount": 100.0} for i,(y,mo,d) in enumerate(dates)]
    return pd.DataFrame(rows)

def test_monthly_only_complete_periods_drops_export_month():
    # 2026-05, 2026-06 完整（有后续月），2026-07 是 export 当月 partial（无后续月）→ 不 emit
    df = _daily([(2026,5,4),(2026,5,29),(2026,6,1),(2026,6,30),(2026,7,1),(2026,7,3)])
    out = resample_calendar(df, "monthly").sort_values("datetime").reset_index(drop=True)
    months = [dt.datetime.fromtimestamp(x, SH).strftime("%Y%m") for x in out["datetime"]]
    assert months == ["202605", "202606"]     # 202607 partial 不发

def test_monthly_open_label_is_first_trading_day_midnight():
    df = _daily([(2026,5,4),(2026,5,29),(2026,6,1),(2026,6,30)])
    out = resample_calendar(df, "monthly").sort_values("datetime").reset_index(drop=True)
    first = out.iloc[0]
    assert first["datetime"] == int(dt.datetime(2026,5,4,0,0,0,tzinfo=SH).timestamp())  # 5月首交易日午夜
    assert first["open"] == 0.0   # 组内首日 open

def test_period_boundaries_include_partial_sentinel():
    # 边界序列含 202607 哨兵（即使其 bar 不 emit），供 after_end 用
    df = _daily([(2026,5,4),(2026,6,1),(2026,7,1)])
    bounds = period_boundaries(df, "monthly")
    labels = [dt.datetime.fromtimestamp(x, SH).strftime("%Y%m") for x in bounds]
    assert labels == ["202605", "202606", "202607"]   # 含 partial 当月哨兵

def test_calendar_single_month_returns_empty_no_crash():
    # PF1-R9-F3：仅一个月（当前 partial，无后续周期）→ 无完整周期 → 空结果，不抛 KeyError
    df = _daily([(2026, 7, 1), (2026, 7, 2), (2026, 7, 3)])
    out = resample_calendar(df, "monthly")
    assert out.empty
    assert list(out.columns) == ["datetime", "open", "high", "low", "close", "volume", "amount"]

def test_calendar_single_week_returns_empty_no_crash():
    # PF1-R9-F3：仅一个 ISO 周（当前 partial）→ 无完整周期 → 空结果，不抛 KeyError
    df = _daily([(2026, 7, 6), (2026, 7, 7)])   # 2026-07-06 Mon / 07-07 Tue 同 ISO 周
    out = resample_calendar(df, "weekly")
    assert out.empty
    assert list(out.columns) == ["datetime", "open", "high", "low", "close", "volume", "amount"]
