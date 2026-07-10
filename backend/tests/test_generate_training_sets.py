# backend/tests/test_generate_training_sets.py
# Spec: kline_trainer_modules_v1.4.md §四 B2 + plan 2026-05-29-pr-b2-generate-training-sets.md Task 1
# 纯装配层：全部 in-memory bars + 本地临时文件，不连 PostgreSQL（PG 壳由 B3/NAS 集成测试覆盖，D1）。
from __future__ import annotations

import random
import sqlite3
import zipfile
import zlib

import pandas as pd
import pytest

from generate_training_sets import (
    GenerateSkipException,
    PERIODS,
    SCHEMA_VERSION,
    assemble_training_set,
    assign_global_indices,
    build_training_set_sqlite,
    crc32_hex,
    select_period_window,
    zip_and_hash,
)

_STEP = {"monthly": 2_592_000, "weekly": 604_800, "daily": 86_400,
         "60m": 3_600, "15m": 900, "3m": 180}
_BASE = 1_600_000_000


def _bars(period: str, n: int, *, base: int = _BASE, step: int = 0) -> pd.DataFrame:
    s = step if step else _STEP[period]
    rows = []
    for i in range(n):
        close = 10.0 + i * 0.01
        rows.append({
            "period": period,
            "datetime": base + i * s,
            "open": round(close - 0.01, 2), "high": round(close + 0.02, 2),
            "low": round(close - 0.02, 2), "close": round(close, 2),
            "volume": 1000 + i, "amount": round(close * (1000 + i), 2),
            "ma66": round(close, 4), "boll_upper": round(close + 0.5, 4),
            "boll_mid": round(close, 4), "boll_lower": round(close - 0.5, 4),
            "macd_diff": round(0.01 * i, 6), "macd_dea": round(0.008 * i, 6),
            "macd_bar": round(0.004 * i, 6),
        })
    return pd.DataFrame(rows)


def _df(period: str, datetimes: list) -> pd.DataFrame:
    rows = [{"period": period, "datetime": d, "open": 10.0, "high": 10.1,
             "low": 9.9, "close": 10.0, "volume": 1000, "amount": 10000.0,
             "ma66": None, "boll_upper": None, "boll_mid": None, "boll_lower": None,
             "macd_diff": None, "macd_dea": None, "macd_bar": None} for d in datetimes]
    return pd.DataFrame(rows)


def _index_windows() -> dict:
    return {
        "3m": _df("3m", [0, 10, 20, 30, 40, 50]),
        "15m": _df("15m", [0, 30, 60]),
        "60m": _df("60m", [-100, -90, 40]),
        "daily": _df("daily", [0, 50]),
        "weekly": _df("weekly", [50]),
        "monthly": _df("monthly", [-100, 20]),
    }


def test_crc32_hex_known_value_lowercase_8():
    expected = format(zlib.crc32(b"kline") & 0xFFFFFFFF, "08x")
    got = crc32_hex(b"kline")
    assert got == expected
    assert len(got) == 8 and got == got.lower()

def test_crc32_hex_zero_padded():
    got = crc32_hex(b"")
    assert got == "00000000"

def test_select_period_window_before_cap_respected():
    bars = _bars("daily", 400)
    start = int(bars["datetime"].iloc[300])
    after_end = int(bars["datetime"].iloc[310])
    win = select_period_window(bars, start, before_cap=150, after_end=after_end, period="daily")
    before = win[win["datetime"] < start]
    assert len(before) == 150

def test_select_period_window_monthly_before_all():
    bars = _bars("monthly", 50)
    start = int(bars["datetime"].iloc[40])
    after_end = int(bars["datetime"].iloc[47])
    win = select_period_window(bars, start, before_cap=None, after_end=after_end, period="monthly")
    before = win[win["datetime"] < start]
    assert len(before) == 40

def test_select_period_window_after_inclusive_bounds():
    bars = _bars("daily", 400)
    start = int(bars["datetime"].iloc[300])
    after_end = int(bars["datetime"].iloc[305])
    win = select_period_window(bars, start, before_cap=150, after_end=after_end, period="daily")
    after = win[win["datetime"] >= start]
    assert after["datetime"].min() == start
    assert after["datetime"].max() == after_end
    assert (after["datetime"] <= after_end).all()

def test_period_window_excludes_bar_whose_period_exceeds_after_end():
    # monthly bars 在 [start, after_end] 内，最后一根 open==after_end+? 的排除；此处验月界对齐 8 根
    # 构造 3m/日/月 简化：仅验 weekly straddle 排除（周末 > after_end）
    # weekly bars（open=周一午夜），after_end 落在某周中 → 该周（周末> after_end）被排除
    def _w(y,mo,d): return int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp())
    bars = pd.DataFrame([{"datetime": _w(2026,6,1),"open":1,"high":1,"low":1,"close":1,"volume":1,"amount":1},
                         {"datetime": _w(2026,6,8),"open":2,"high":2,"low":2,"close":2,"volume":1,"amount":1},
                         {"datetime": _w(2026,6,29),"open":3,"high":3,"low":3,"close":3,"volume":1,"amount":1}])
    start = _w(2026,6,1); after_end = _w(2026,7,1) - 1   # 6/29 那周跨到 7 月 → 排除
    out = select_period_window(bars, start, before_cap=150, after_end=after_end, period="weekly")
    got = sorted(dt.datetime.fromtimestamp(x, SH).strftime("%m%d") for x in out["datetime"])
    assert "0629" not in got     # 跨月界 trailing 周被排除

def test_period_window_excludes_start_straddling_weekly_before_context():
    # start=周三 2026-07-01；周 bar 2026-06-29(Mon, 含 7/1-7/3 post-start) 不得作 before-context（codex PF1-R5：防 lookahead）
    def _w(y,mo,d): return int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp())
    bars = pd.DataFrame([
        {"datetime": _w(2026,6,15),"open":1,"high":1,"low":1,"close":1,"volume":1,"amount":1},  # 完整过去周(end 6/21)
        {"datetime": _w(2026,6,22),"open":2,"high":2,"low":2,"close":2,"volume":1,"amount":1},  # 完整过去周(end 6/28)
        {"datetime": _w(2026,6,29),"open":3,"high":3,"low":3,"close":3,"volume":1,"amount":1},  # 跨 start 周(Mon 6/29, end 7/5)
        {"datetime": _w(2026,7,6),"open":4,"high":4,"low":4,"close":4,"volume":1,"amount":1},   # start 后完整周
    ])
    start = _w(2026,7,1); after_end = _w(2026,9,1) - 1
    out = select_period_window(bars, start, before_cap=150, after_end=after_end, period="weekly")
    got = {dt.datetime.fromtimestamp(x, SH).strftime("%m%d") for x in out["datetime"]}
    assert "0629" not in got                 # 跨 start 周（含 post-start 数据）不作 before-context
    assert "0622" in got and "0706" in got   # 完整过去周 + start 后周保留

def test_assign_3m_global_index_and_end_equal():
    out = assign_global_indices(_index_windows())
    assert list(out["3m"]["global_index"]) == [0, 1, 2, 3, 4, 5]
    assert list(out["3m"]["end_global_index"]) == [0, 1, 2, 3, 4, 5]

def test_assign_non_min_period_global_index_is_null():
    out = assign_global_indices(_index_windows())
    assert out["15m"]["global_index"].isna().all()
    assert out["60m"]["global_index"].isna().all()

def test_assign_end_global_index_interior_historical_trailing():
    out = assign_global_indices(_index_windows())
    assert list(out["15m"]["end_global_index"]) == [2, 5, 5]
    assert list(out["60m"]["end_global_index"]) == [0, 3, 5]
    assert list(out["monthly"]["end_global_index"]) == [1, 5]

def test_assign_end_global_index_monotonic_and_in_range():
    out = assign_global_indices(_index_windows())
    n3 = len(out["3m"])
    for period in ("monthly", "weekly", "daily", "60m", "15m", "3m"):
        egi = list(out[period]["end_global_index"])
        assert egi == sorted(egi)
        assert all(0 <= e <= n3 - 1 for e in egi)

def test_build_sqlite_user_version_meta_and_rowcount(tmp_path):
    windows = assign_global_indices(_index_windows())
    db = tmp_path / "t.db"
    build_training_set_sqlite(db, stock_code="600519", stock_name="测试股",
                              start_datetime=_BASE, end_datetime=_BASE + 999,
                              windows=windows)
    conn = sqlite3.connect(str(db))
    try:
        assert conn.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION
        meta = conn.execute("SELECT stock_code, stock_name, start_datetime, end_datetime FROM meta").fetchone()
        assert meta == ("600519", "测试股", _BASE, _BASE + 999)
        total = sum(len(windows[p]) for p in PERIODS)
        assert conn.execute("SELECT COUNT(*) FROM klines").fetchone()[0] == total
    finally:
        conn.close()

def test_build_sqlite_integer_columns_are_int_not_float(tmp_path):
    windows = assign_global_indices(_index_windows())
    db = tmp_path / "t.db"
    build_training_set_sqlite(db, stock_code="X", stock_name="X",
                              start_datetime=_BASE, end_datetime=_BASE + 1, windows=windows)
    conn = sqlite3.connect(str(db))
    try:
        row = conn.execute(
            "SELECT typeof(datetime), typeof(volume), typeof(end_global_index) "
            "FROM klines WHERE period='3m' LIMIT 1").fetchone()
        assert row == ("integer", "integer", "integer")
    finally:
        conn.close()

def test_zip_and_hash_content_hash_matches_zip_bytes(tmp_path):
    db = tmp_path / "t.db"
    db.write_bytes(b"SQLite format 3\x00fake")
    zp = tmp_path / "t.zip"
    h = zip_and_hash(db, zp)
    assert h == format(zlib.crc32(zp.read_bytes()) & 0xFFFFFFFF, "08x")
    with zipfile.ZipFile(zp) as zf:
        assert db.name in zf.namelist()

def test_assemble_training_set_fails_closed(tmp_path):
    # Task 8 (codex PF1-R10-F1)：旧未门控随机选起点路径已停用 → 显式 fail-closed。
    # period_bars={} 即可（fail-closed 首行即 raise、不访问 period_bars）。
    with pytest.raises(NotImplementedError) as ei:
        assemble_training_set(tmp_path, stock_code="X", stock_name="X",
                              period_bars={}, rng=random.Random(0))
    msg = str(ei.value)
    assert "build_training_windows" in msg and "Plan 2" in msg


# ===== Task 7: B2 pure selection logic (compute_after_end / eligible_start_indices /
#   select_valid_window / per_day_intraday_complete / build_training_windows) =====
import datetime as dt
from zoneinfo import ZoneInfo
from generate_training_sets import (
    GenerateSkipException, compute_after_end, eligible_start_indices, select_valid_window,
    per_day_intraday_complete, build_training_windows,
)
SH = ZoneInfo("Asia/Shanghai")
def _mid(y,mo,d): return int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp())

def test_compute_after_end_is_ninth_boundary_minus_one():
    bounds = [_mid(2020,1,1) + i for i in range(20)]   # 占位单调
    assert compute_after_end(bounds, 3) == bounds[11] - 1   # start_idx+8=11

import random

def _weekday_trading_dates(d0: dt.date, d1: dt.date) -> set:
    """[d0,d1] 内工作日（周一~周五）当交易日历——含跨越的周末间隙。"""
    out, cur = set(), d0
    while cur <= d1:
        if cur.weekday() < 5:
            out.add(cur)
        cur += dt.timedelta(days=1)
    return out

def _n_month_boundaries(n: int) -> list:
    bounds, y, mo = [], 2020, 1
    for _ in range(n):
        bounds.append(_mid(y, mo, 1)); mo += 1
        if mo > 12: y += 1; mo = 1
    return bounds

def test_eligible_start_indices_returns_all_dense_candidates():
    # ≥39 月边界，trading_dates=全程工作日，dense=全部工作日 → 返回非空候选列表（不因周末误拒）
    bounds = _n_month_boundaries(44)
    trading = _weekday_trading_dates(dt.date(2020,1,1), dt.date(2023,12,31))
    dense = set(trading)
    idxs = eligible_start_indices(bounds, random.Random(0), dense_dates=dense, trading_dates=trading)
    assert idxs and all(30 <= i <= len(bounds) - 9 for i in idxs)

def test_eligible_start_indices_empty_when_no_dense():
    bounds = _n_month_boundaries(44)
    trading = _weekday_trading_dates(dt.date(2020,1,1), dt.date(2023,12,31))
    idxs = eligible_start_indices(bounds, random.Random(0), dense_dates=set(), trading_dates=trading)
    assert idxs == []      # 空 dense → 每候选窗口都有非-dense 交易日 → 无候选（n≥39 不抛）

def test_eligible_start_indices_excludes_only_window_missing_a_trading_day():
    # 部分 dense（仅 idx=30 窗口首日缺失，其余全 dense）→ 仅排除 idx=30、idx=31 保留。
    # 验证判定是"整段每个交易日都需 dense"而非"任一交易日 dense 即可"——全 dense/全空 dense 两个
    # 原始用例不足以区分 all() vs any()（两者在这两个边界输入下结果相同），本测试补上这条 vacuous-test 缺口。
    bounds = _n_month_boundaries(44)
    trading = _weekday_trading_dates(dt.date(2020,1,1), dt.date(2023,12,31))
    idx30_start_date = dt.datetime.fromtimestamp(bounds[30], SH).date()
    dense = set(trading) - {idx30_start_date}
    idxs = eligible_start_indices(bounds, random.Random(0), dense_dates=dense, trading_dates=trading)
    assert 30 not in idxs
    assert 31 in idxs

def test_select_valid_window_retries_past_bad_candidate():
    # 注入 try_assemble：第一个被调的候选抛 skip（模拟 D9 漂移/切窗失败），之后成功 → 验证重试到下一候选
    bounds = _n_month_boundaries(44)
    trading = _weekday_trading_dates(dt.date(2020,1,1), dt.date(2023,12,31))
    dense = set(trading)
    calls = []
    def try_assemble(start):
        calls.append(start)
        if len(calls) == 1:
            raise GenerateSkipException("first candidate fails (D9 drift / per-period 不足)")
        return {"ok": start}
    start, result = select_valid_window(bounds, random.Random(0), dense_dates=dense,
                                        trading_dates=trading, try_assemble=try_assemble, max_retries=8)
    assert len(calls) == 2                 # 第一个失败、自动重试第二个
    assert result == {"ok": start}         # 返回第二个候选的组装结果（不因单坏候选放弃该股）

def _mk_bars(day, n):
    base = int(dt.datetime(*day, 9, 33, 0, tzinfo=SH).timestamp())
    return [{"datetime": base + i*180} for i in range(n)]   # 同日内、不跨日

def _ae(y,mo,d):  # after_end = 某日午夜（span 到该日）
    return int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp())

def test_per_day_intraday_complete_all_periods_hardgate():
    days = {dt.date(2026,7,1), dt.date(2026,7,2)}
    ae = _ae(2026,7,2)
    def _win(n3, n15, n60):
        return {"3m": pd.DataFrame(_mk_bars((2026,7,1),n3)+_mk_bars((2026,7,2),n3)),
                "15m": pd.DataFrame(_mk_bars((2026,7,1),n15)+_mk_bars((2026,7,2),n15)),
                "60m": pd.DataFrame(_mk_bars((2026,7,1),n60)+_mk_bars((2026,7,2),n60))}
    assert per_day_intraday_complete(_win(80,16,4), days, ae) is True
    assert per_day_intraday_complete(_win(80,15,4), days, ae) is False   # 3m 全但 15m 短 → False
    assert per_day_intraday_complete(_win(80,16,3), days, ae) is False   # 60m 短 → False
    assert per_day_intraday_complete(_win(79,16,4), days, ae) is False   # 3m 短 → False

def test_per_day_intraday_complete_catches_short_60m_before_context():
    # 60m 多一更早 before-context 日 D0 只 2 根 → 各周期按**自身跨度**校验 → False（codex PF1-R4-F2）
    D0, D1, D2 = (2026,6,30), (2026,7,1), (2026,7,2)
    trading = {dt.date(*D0), dt.date(*D1), dt.date(*D2)}; ae = _ae(2026,7,2)
    windows = {"3m": pd.DataFrame(_mk_bars(D1,80)+_mk_bars(D2,80)),
               "15m": pd.DataFrame(_mk_bars(D1,16)+_mk_bars(D2,16)),
               "60m": pd.DataFrame(_mk_bars(D0,2)+_mk_bars(D1,4)+_mk_bars(D2,4))}
    assert per_day_intraday_complete(windows, trading, ae) is False
    windows["60m"] = pd.DataFrame(_mk_bars(D0,4)+_mk_bars(D1,4)+_mk_bars(D2,4))
    assert per_day_intraday_complete(windows, trading, ae) is True

def test_per_day_intraday_complete_catches_missing_tail_day():
    # trading 含 D3, 但盘中都止于 D2; after_end 覆盖到 D3 → D3 在 span(0 桶) → False（codex PF1-R6-F1）
    D1, D2, D3 = (2026,7,1), (2026,7,2), (2026,7,3)
    trading = {dt.date(*D1), dt.date(*D2), dt.date(*D3)}; ae = _ae(2026,7,3)
    windows = {"3m": pd.DataFrame(_mk_bars(D1,80)+_mk_bars(D2,80)),   # 止于 D2
               "15m": pd.DataFrame(_mk_bars(D1,16)+_mk_bars(D2,16)),
               "60m": pd.DataFrame(_mk_bars(D1,4)+_mk_bars(D2,4))}
    assert per_day_intraday_complete(windows, trading, ae) is False   # D3 缺盘中 → False
    ae2 = _ae(2026,7,2)                                                # after_end 只到 D2 → 通过
    assert per_day_intraday_complete(windows, trading, ae2) is True

def test_build_training_windows_end_to_end_retries_on_tail_d9_fail():
    # 端到端生产入口（codex PF1-R6-F2）：months=1, 候选 {30(2022-07),31(2022-08)};
    # July 末交易日缺 3m → idx30 D9(尾日)失败 → 重试 idx31(Aug 完整)成功
    from generate_training_sets import build_training_windows
    bounds = _n_month_boundaries(33)      # 2020-01..2022-09 → month[30]=2022-07, [31]=2022-08
    tdays = [d for d in (dt.date(2022,6,1)+dt.timedelta(days=i) for i in range(120))
             if dt.date(2022,6,1) <= d <= dt.date(2022,8,31) and d.weekday() < 5]
    trading = set(tdays); dense = set(tdays)
    def _bars(days, n):
        rows = []
        for d in days:
            base = int(dt.datetime(d.year,d.month,d.day,9,33,0,tzinfo=SH).timestamp())
            rows += [{"datetime": base+i*180,"open":1.0,"high":1.0,"low":1.0,"close":1.0,
                      "volume":1,"amount":1.0} for i in range(n)]
        return pd.DataFrame(rows)
    july_early = min(d for d in tdays if d.month == 7)   # 早 July：在 idx30 forward 窗口内, 但不在 idx31 短 before-context 内
    pb = {"3m": _bars([d for d in tdays if d != july_early], 2),   # 早 July 日缺 3m
          "15m": _bars(tdays, 2), "60m": _bars(tdays, 1), "daily": _bars(tdays, 1)}
    caps = {"3m":2, "15m":2, "60m":2, "daily":2}         # **短 before-context**（codex PF1-R7）→ Aug 候选 before 不含 july_early
    start, windows = build_training_windows(
        pb, bounds, random.Random(0), dense_dates=dense, trading_dates=trading, before_caps=caps,
        months=1, intraday_expected={"3m":2,"15m":2,"60m":1}, before_min=1, max_retries=8)
    assert start == bounds[31]                       # idx30(July) forward 含 july_early 缺 3m→D9失败→idx31(Aug)成功
    assert {"3m","15m","60m","daily"} <= set(windows)
    # 双检（codex PF1-R7）：成功候选的盘中窗口确实过 per_day D9
    ae31 = compute_after_end(bounds, bounds.index(bounds[31]), months=1)
    assert per_day_intraday_complete({p: windows[p] for p in ("3m","15m","60m")}, trading, ae31,
                                     {"3m":2,"15m":2,"60m":1}) is True
