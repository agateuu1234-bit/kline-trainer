# backend/tests/test_qmt_resample.py
from __future__ import annotations
import datetime as dt
import pandas as pd
from zoneinfo import ZoneInfo
from qmt_resample import resample_intraday, resample_calendar, period_boundaries, compute_dense_coverage, reconcile_sources
from qmt_normalize import trading_date

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

def _day_1m(day, n=241) -> list[dict]:
    """某日前 n 根 1m（n=241 完整；<241 模拟缺分钟）。close=1 占位。"""
    times = []
    t = 930
    while t <= 1130:
        times.append(t); m = t%100; t = t + (1 if m<59 else 41)
    t = 1301
    while t <= 1500:
        times.append(t); m = t%100; t = t + (1 if m<59 else 41)
    times = times[:n]
    return [{"datetime": _ep(hh, day), "open":1.0,"high":1.0,"low":1.0,"close":1.0,
             "volume":1,"amount":1.0} for hh in times]

def test_dense_coverage_complete_days_only():
    rows = _day_1m((2026,7,1)) + _day_1m((2026,7,2)) + _day_1m((2026,7,3))
    cov = compute_dense_coverage(pd.DataFrame(rows))
    assert cov.complete_dates == [dt.date(2026,7,1), dt.date(2026,7,2), dt.date(2026,7,3)]
    assert cov.dropped_dates == []
    assert (cov.start_date, cov.end_date) == (dt.date(2026,7,1), dt.date(2026,7,3))

def test_dense_coverage_drops_partial_day_whole():
    # 7-2 缺 1 根(240) → 整日 dropped、不进 complete
    rows = _day_1m((2026,7,1)) + _day_1m((2026,7,2), n=240) + _day_1m((2026,7,3))
    cov = compute_dense_coverage(pd.DataFrame(rows))
    assert dt.date(2026,7,2) not in cov.complete_dates
    assert dt.date(2026,7,2) in cov.dropped_dates
    assert cov.complete_dates == [dt.date(2026,7,1), dt.date(2026,7,3)]

def test_dense_coverage_rejects_dup_plus_missing_still_241():
    # 行数仍=241 但 11:30 缺失、09:31 重复 → 时间戳集≠期望 → 不 dense（codex PF1-F1）
    df = pd.DataFrame(_day_1m((2026,7,1)))
    df = df[df["datetime"] != _ep(1130, (2026,7,1))]                       # 去 11:30 → 240
    df = pd.concat([df, df[df["datetime"] == _ep(931, (2026,7,1))]], ignore_index=True)  # 复制 09:31 → 241
    assert len(df) == 241
    cov = compute_dense_coverage(df)
    assert dt.date(2026,7,1) in cov.dropped_dates and dt.date(2026,7,1) not in cov.complete_dates

def test_dense_coverage_rejects_out_of_session_row_still_241():
    # 241 根但一根落盘外(11:31)替掉盘内 11:30 → 不 dense
    df = pd.DataFrame(_day_1m((2026,7,1)))
    df.loc[df["datetime"] == _ep(1130, (2026,7,1)), "datetime"] = _ep(1131, (2026,7,1))   # 11:30 → 11:31(盘外)
    assert len(df) == 241
    cov = compute_dense_coverage(df)
    assert dt.date(2026,7,1) in cov.dropped_dates

def test_dense_coverage_rejects_nonzero_seconds_still_241():
    # 241 根但 09:30:00 → 09:30:30（分钟相同、epoch 不同）→ 不 dense（codex PF1-R3-F1）
    df = pd.DataFrame(_day_1m((2026,7,1)))
    df.loc[df["datetime"] == _ep(930, (2026,7,1)), "datetime"] = _ep(930, (2026,7,1)) + 30
    assert len(df) == 241
    cov = compute_dense_coverage(df)
    assert dt.date(2026,7,1) in cov.dropped_dates

def test_build_intraday_drops_partial_day_from_all_periods():
    # 安全入口：240 根的 7-2 → 三周期该日均 0 桶（codex PF1-R4-F1）
    from qmt_resample import build_intraday
    rows = _day_1m((2026,7,1)) + _day_1m((2026,7,2), n=240) + _day_1m((2026,7,3))
    windows, cov = build_intraday(pd.DataFrame(rows))
    assert dt.date(2026,7,2) not in cov.complete_dates
    for p in ("3m", "15m", "60m"):
        got = {trading_date(e) for e in windows[p]["datetime"]}
        assert dt.date(2026,7,2) not in got            # 损坏日 → 0 桶
        assert {dt.date(2026,7,1), dt.date(2026,7,3)} <= got

def _daily_from_1m(rows_1m: list[dict]) -> pd.DataFrame:
    """由 1m 聚合出一致的日线（open=首/close=尾/high=max/low=min/vol,amt=Σ）。"""
    df = pd.DataFrame(rows_1m); df["_d"] = df["datetime"].map(trading_date)
    out = []
    for d, g in df.groupby("_d"):
        g = g.sort_values("datetime")
        out.append({"datetime": int(dt.datetime(d.year,d.month,d.day,0,0,0,tzinfo=SH).timestamp()),
                    "open": g.iloc[0]["open"], "high": g["high"].max(), "low": g["low"].min(),
                    "close": g.iloc[-1]["close"], "volume": int(g["volume"].sum()),
                    "amount": float(g["amount"].sum())})
    return pd.DataFrame(out)

def test_reconcile_ok_when_consistent():
    r1 = _day_1m((2026,7,1)) + _day_1m((2026,7,2))
    res = reconcile_sources(pd.DataFrame(r1), _daily_from_1m(r1))
    assert res.ok and res.reason == ""

def test_reconcile_fail_stale_daily_tail():
    r1 = _day_1m((2026,7,1)) + _day_1m((2026,7,2))
    daily = _daily_from_1m(_day_1m((2026,7,1)))   # 日线只到 7-1，尾部截断（比 1m 旧）
    res = reconcile_sources(pd.DataFrame(r1), daily)
    assert not res.ok and res.reason == "daily_not_cover_dense"

def test_reconcile_fail_date_set_mismatch():
    # 7-2 在 1m 侧因 partial(n=240) 被 dense 剔除，但日线仍聚合出 7-2 一行 →
    # 端点覆盖(7-1..7-3)仍通过 gate3，但 dense={7-1,7-3} != daily_in_span={7-1,7-2,7-3} → gate4
    r1 = _day_1m((2026,7,1)) + _day_1m((2026,7,2), n=240) + _day_1m((2026,7,3))
    daily = _daily_from_1m(r1)   # 日线含 7-1/7-2/7-3（7-2 由不完整 240 根聚合，但仍记一行）
    res = reconcile_sources(pd.DataFrame(r1), daily)
    assert not res.ok and res.reason == "date_set_mismatch"

def test_reconcile_fail_ohlcv_mismatch():
    r1 = _day_1m((2026,7,1))
    daily = _daily_from_1m(r1); daily.loc[0, "close"] = daily.loc[0, "close"] + 5.0  # 篡改 close
    res = reconcile_sources(pd.DataFrame(r1), daily)
    assert not res.ok and res.reason == "ohlcv_mismatch"

def test_reconcile_fail_when_export_log_not_ok():
    # export_log status 非 'ok' → fail-closed（即使 df 内部自洽，codex PF1-R8-F2）
    r1 = _day_1m((2026,7,1)); daily = _daily_from_1m(r1)
    assert reconcile_sources(pd.DataFrame(r1), daily, status_1m="error").reason == "export_log_not_ok"
    assert reconcile_sources(pd.DataFrame(r1), daily, status_daily="empty").reason == "export_log_not_ok"
    assert reconcile_sources(pd.DataFrame(r1), daily, status_1m="ok", status_daily="ok").ok is True
