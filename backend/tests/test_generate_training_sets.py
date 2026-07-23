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

# ===== Task 7: B2 pure selection logic (compute_after_end / eligible_start_indices /
#   select_valid_window / per_day_intraday_complete / build_training_windows) =====
import datetime as dt
from zoneinfo import ZoneInfo
from generate_training_sets import (
    GenerateSkipException, compute_after_end, eligible_start_indices, select_valid_window,
    per_day_intraday_complete, build_training_windows,
)
from qmt_normalize import trading_date
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

def _weekday_range(d0: dt.date, d1: dt.date) -> list:
    """[d0,d1] 内工作日升序 list（既有 _weekday_trading_dates 返回 set，取不了第 k 天）。"""
    return sorted(_weekday_trading_dates(d0, d1))

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

def test_per_day_intraday_complete_catches_dropped_day_in_before_context():
    """R6-F1：某 dropped 1m 日落在 before-context、且 daily 也缺（∉ trading_dates）→ 内部逐日
    counts 门看不见它（不在 span）、eligible 的 dropped 门只覆盖 [start,after_end] 前向也够不到
    → 静默盘中空洞。前后交易日都有满根 bar、唯独 dropped 日无 bar（d0<D_drop<尾日）。
    不传 dropped（默认空）→ 旧的静默 True（正是 bug）；传 dropped={D_drop} → False（修）。"""
    D_before, D_drop, D1, D2 = (2026,6,29), (2026,6,30), (2026,7,1), (2026,7,2)
    trading = {dt.date(*D_before), dt.date(*D1), dt.date(*D2)}   # daily 缺 D_drop → 不在 trading_dates
    ae = _ae(2026,7,2)
    windows = {"3m": pd.DataFrame(_mk_bars(D_before,80)+_mk_bars(D1,80)+_mk_bars(D2,80)),
               "15m": pd.DataFrame(_mk_bars(D_before,16)+_mk_bars(D1,16)+_mk_bars(D2,16)),
               "60m": pd.DataFrame(_mk_bars(D_before,4)+_mk_bars(D1,4)+_mk_bars(D2,4))}
    assert per_day_intraday_complete(windows, trading, ae) is True                 # bug：内部门漏检 → 静默通过
    assert per_day_intraday_complete(windows, trading, ae,
                                     dropped={dt.date(*D_drop)}) is False           # 修：dropped 独立门抓住

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


def test_build_training_windows_rejects_dropped_day_in_before_context():
    """R6-F1 端到端（codex R6 next-step）：唯一候选的 before-context 跨过一个 dropped-both-missing
    日 D（daily+盘中都缺、d0<D<start）。前向 [start,after_end] 干净 → eligible 通过、其 dropped 门
    只覆盖前向也够不到 D。不传 dropped → 静默注册（bug）；传 dropped={D} → per_day 的 dropped 独立门
    抓住 → 唯一候选穷尽 → GenerateSkipException（而非登记带空洞的训练组）。"""
    from generate_training_sets import build_training_windows
    bounds = _n_month_boundaries(32)                       # months=1 → 唯一候选 idx=30(start=2022-07)
    D_drop = dt.date(2022, 6, 30)
    all_days = _weekday_range(dt.date(2022, 6, 1), dt.date(2022, 7, 31))
    days = [d for d in all_days if d != D_drop]            # daily+dense+盘中都缺 D_drop
    trading = set(days); dense = set(days)
    def _bars(dlist, n):
        rows = []
        for d in dlist:
            base = int(dt.datetime(d.year, d.month, d.day, 9, 33, 0, tzinfo=SH).timestamp())
            rows += [{"datetime": base + i*180, "open": 1.0, "high": 1.0, "low": 1.0,
                      "close": 1.0, "volume": 1, "amount": 1.0} for i in range(n)]
        return pd.DataFrame(rows)
    pb = {"3m": _bars(days, 2), "15m": _bars(days, 2), "60m": _bars(days, 1), "daily": _bars(days, 1)}
    caps = {"3m": 2, "15m": 2, "60m": 2, "daily": 2}       # 短 before-context：跨过 D_drop 取到更早交易日
    kw = dict(months=1, intraday_expected={"3m": 2, "15m": 2, "60m": 1}, before_min=1, max_retries=8)
    # 不传 dropped：before-context 空洞漏检 → 成功注册（正是 bug）
    start, _w = build_training_windows(pb, bounds, random.Random(0), dense_dates=dense,
                                       trading_dates=trading, before_caps=caps, **kw)
    assert start == bounds[30]
    # 传 dropped={D_drop}：唯一候选 before-context 含 D → per_day dropped 门拒 → 穷尽 → skip
    with pytest.raises(GenerateSkipException):
        build_training_windows(pb, bounds, random.Random(0), dense_dates=dense,
                               trading_dates=trading, before_caps=caps, dropped={D_drop}, **kw)


# ===== final whole-branch review Finding 1：D6 per-period before/after 硬门补测（Task8 删旧测试造成的
#   覆盖回归——旧 assemble_training_set 路径的等价测试未在新生产入口 build_training_windows 上重建）=====

def _intraday_bars_per_day(days, n):
    """每交易日固定 n 根盘中 bar（3m/15m/60m 占位）；供 D9 per_day 硬门"真正过关"用，
    避免该周期缺席时 per_day_intraday_complete 因 windows.get(period) is None 而"意外"失败，
    掩盖 D6 门本身是否被触发（vacuous-test 陷阱）。"""
    rows = []
    for d in days:
        base = int(dt.datetime(d.year, d.month, d.day, 9, 33, 0, tzinfo=SH).timestamp())
        rows += [{"datetime": base + i * 180, "open": 1.0, "high": 1.0, "low": 1.0,
                 "close": 1.0, "volume": 1, "amount": 1.0} for i in range(n)]
    return pd.DataFrame(rows)

def _d6_isolated_fixture(daily_rows):
    """n=32+months=1 → 唯一候选 idx=30；3m/15m/60m 铺满 forward span 且 before_caps=0（D9 必过，
    与 daily 隔离），daily 周期由调用方注入待测的 before/after 行。返回 (bounds, pb, kwargs)。"""
    bounds = _n_month_boundaries(32)
    trading = _weekday_trading_dates(dt.date(2022, 7, 1), dt.date(2022, 7, 31))
    dense = set(trading)
    forward_days = sorted(trading)                      # d0..ae_date 全交易日、D9 span 与之精确重合
    pb = {"daily": pd.DataFrame(daily_rows),
         "3m": _intraday_bars_per_day(forward_days, 2),
         "15m": _intraday_bars_per_day(forward_days, 2),
         "60m": _intraday_bars_per_day(forward_days, 1)}
    caps = {"daily": 150, "3m": 0, "15m": 0, "60m": 0}   # 3m/15m/60m before-context=0 → 窗口=严格 forward span
    kwargs = dict(dense_dates=dense, trading_dates=trading, before_caps=caps, months=1,
                 intraday_expected={"3m": 2, "15m": 2, "60m": 1}, before_min=30, max_retries=8)
    return bounds, pb, kwargs

def test_build_training_windows_raises_when_before_context_too_thin():
    # daily 周期只给 5 根 before-context(<before_min=30 默认) → 唯一候选在 D6 gate 失败
    # → bounded retry 穷尽 → GenerateSkipException（选项 a：全部候选都不过此门，直接钉死该 gate；
    # retry 行为已由 test_select_valid_window_retries_past_bad_candidate /
    # test_build_training_windows_end_to_end_* 另行覆盖）。3m/15m/60m 铺满、D9 必过，隔离出 D6 本身。
    bounds0 = _n_month_boundaries(32)
    start = bounds0[30]
    before_dt = [start - (i + 1) * 86400 for i in range(5)]
    daily_rows = [{"datetime": d, "open": 1.0, "high": 1.0, "low": 1.0,
                  "close": 1.0, "volume": 1, "amount": 1.0} for d in before_dt + [start]]
    bounds, pb, kwargs = _d6_isolated_fixture(daily_rows)
    with pytest.raises(GenerateSkipException):
        build_training_windows(pb, bounds, random.Random(0), **kwargs)

def test_build_training_windows_raises_when_after_window_empty():
    # 同一 D6 gate 的另一分支：before-context 充足(35>=30)，但 [start, after_end] 内 daily 无一根
    # → after_n=0<1 → 唯一候选失败 → GenerateSkipException。3m/15m/60m 同上铺满、D9 必过。
    bounds0 = _n_month_boundaries(32)
    start = bounds0[30]
    before_dt = [start - (i + 1) * 86400 for i in range(35)]
    daily_rows = [{"datetime": d, "open": 1.0, "high": 1.0, "low": 1.0,
                  "close": 1.0, "volume": 1, "amount": 1.0} for d in before_dt]
    bounds, pb, kwargs = _d6_isolated_fixture(daily_rows)
    with pytest.raises(GenerateSkipException):
        build_training_windows(pb, bounds, random.Random(0), **kwargs)


# ===== Plan 2b Task 4：D9 门边界日修复（Plan 1 遗留 bug 的回归锁）=====
# 本段用到 trading_date，若本文件尚未 import 需补：`from qmt_normalize import trading_date`
#
# 实测过的失败现象（修复前）：46 个月历史 + 每交易日精确 80/16/4 根 + 零 drop 的
# **完美** fixture 下，8 个 dense 候选全被 D9 拒 → build_training_windows 抛
# GenerateSkipException → 产 0 训练组。根因 = 生产 before_cap(150) 不是每日根数
# (80/16/4) 的整数倍 → 窗口首日被切成部分根 → 门把「切片边界」当「数据洞」。

_GOLDEN_PER_DAY = {"3m": 80, "15m": 16, "60m": 4}


def _golden_intraday(days, per_day: int, *, skip=None, short=None) -> pd.DataFrame:
    """按 golden 每日根数铺盘中 bar（09:33 起每 3 分钟一根，仅作刻度）。
    skip=某日整日缺席（模拟 B1 drop）；short={日: n} 令某日只有 n 根（模拟 PG 里的
    partial 日——B1 不变量下不该存在，用来证明门仍会抓）。"""
    rows = []
    for d in days:
        if skip and d in skip:
            continue
        n = (short or {}).get(d, per_day)
        base = dt.datetime(d.year, d.month, d.day, 9, 33, 0, tzinfo=SH)
        rows += [{"datetime": int((base + dt.timedelta(minutes=3 * i)).timestamp()),
                  "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0,
                  "volume": 1, "amount": 1.0} for i in range(n)]
    return pd.DataFrame(rows)


def _production_cap_windows(days, *, skip=None, short=None, caps=None):
    """用**生产** PERIOD_BEFORE_CAP 切出的盘中窗口（首日必然是部分根——正是本 Task 的靶心）。
    返回 `(wins, after_end, full_bars)`：`full_bars` 必须传给
    per_day_intraday_complete，边界日要对照它判完整性（PF2-R7-F2）。"""
    from generate_training_sets import PERIOD_BEFORE_CAP
    caps = caps or PERIOD_BEFORE_CAP
    start = _mid(days[len(days) // 2].year, days[len(days) // 2].month,
                 days[len(days) // 2].day)
    after_end = int(dt.datetime(days[-1].year, days[-1].month, days[-1].day,
                                23, 59, 59, tzinfo=SH).timestamp())
    wins, full = {}, {}
    for p, n in _GOLDEN_PER_DAY.items():
        full[p] = _golden_intraday(days, n, skip=skip, short=short)
        wins[p] = select_period_window(full[p], start, caps[p], after_end, p)
    return wins, after_end, full


def test_per_day_gate_passes_under_production_before_caps():
    """靶心：生产 cap(150) + 完美数据（每日精确 80/16/4、零 drop）必须过门。
    修复前此测必挂（首日 3m 只有 70 根被判洞）。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    wins, ae, full = _production_cap_windows(days)
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is True


def test_per_day_gate_still_catches_interior_missing_day():
    """不得放松真洞：窗口内某交易日**整日缺席**（B1 drop 的表现）仍必须被拒。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    hole = days[len(days) // 2 + 5]        # 落在 forward 窗口内部
    wins, ae, full = _production_cap_windows(days, skip={hole})
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is False


def test_per_day_gate_still_catches_interior_short_day():
    """只豁免首日：窗口**内部**某日根数不足（非首日）仍必须被拒——
    证明修复没有把「部分日一律放行」。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    bad = days[len(days) // 2 + 5]
    wins, ae, full = _production_cap_windows(days, short={bad: 79})
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is False


def test_per_day_gate_catches_corrupt_boundary_day():
    """codex PF2-R7-F2：边界日在**库里**残缺时，D9 门整体仍必须拒绝。

    生产 cap 下窗口只切到该日 70/80 根（正常）；但把它在**全量 bars** 里改成 60 根
    （真损坏）→ 必须判失败。**注意**：这里的损坏日不是全量历史最早一天，短根后
    `select_period_window` 会往更早多回填一天补足 150 根，把损坏日从窗口自身的
    d0 位置"挤"成内部日——实际抓住它的是内部日的窗口自身精确校验
    （`counts.get(d,0)==need`），**不是** `full_bars` 的 d0 边界判据本身（codex 评审
    mutation 实测复核：把 `boundary_ok` 恒设 `True` 此测试仍绿，证明它未孤立该判据）。
    真正孤立 `full_bars`/d0 判据（损坏日钉死在全量历史第一天、reach-back 无处可回）
    见 `test_per_day_gate_catches_corrupt_boundary_day_when_pinned_at_history_start`。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    probe, _, _ = _production_cap_windows(days)
    d0 = min(trading_date(e) for e in probe["3m"]["datetime"])
    wins, ae, full = _production_cap_windows(days, short={d0: 60})   # 全量里该日只剩 60
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is False


def test_per_day_gate_catches_corrupt_boundary_day_when_pinned_at_history_start():
    """codex 评审补测：真正孤立 `full_bars` 的 d0 边界判据本身（而非靠内部日精确校验
    间接兜底——上一条 `test_per_day_gate_catches_corrupt_boundary_day` 的 fixture 做不到
    这点，见其 docstring）。

    构造：损坏日 D1 = 全量历史里最早的一天（没有更早的日子可回填，`select_period_window`
    的"按根数往前补"逃不开它）；D1 只有 75/80 根（真损坏），紧跟 1 个完整日 D2（80 根）。
    cap=150：切片取「起点前最后 150 根」= D2 全部 80 根 + D1 最后 70 根 → 窗口自身的
    d0 恰好落在 D1 上、窗口自身计数 70（长得像正常的切片边界，不像坏数据——只有对照
    `full_bars` 里 D1 的真实根数 75 != 80 才能识破）。

    codex 评审 mutation 实测验证：未 mutate 时门正确返回 `False`；把 `boundary_ok`
    强制恒 `True` 后门翻转为 `True`（本测试应变红）——证明这条 fixture 真正孤立了
    `full_bars` 判据本身，不像上一条那样被内部日精确校验兜底。"""
    D1, D2 = (2024, 1, 2), (2024, 1, 3)
    need = _GOLDEN_PER_DAY["3m"]
    full_3m = pd.DataFrame(_mk_bars(D1, 75) + _mk_bars(D2, 80))   # D1 损坏：75/80，且是全量最早一天
    start = _mid(2024, 1, 4)                                      # 越过 D1+D2 全部 155 根，pivot=155
    ae = _ae(2024, 1, 3)                                          # span 止于 D2
    win_3m = select_period_window(full_3m, start, 150, ae, "3m")  # 切最后 150 根：丢 D1 前 5 根 → D1 剩 70
    trading = {dt.date(*D1), dt.date(*D2)}
    assert per_day_intraday_complete({"3m": win_3m}, trading, ae, {"3m": need},
                                     full_bars={"3m": full_3m}) is False


def test_per_day_gate_passes_when_cap_is_exact_multiple():
    """cap 恰为每日根数整数倍（边界日被完整切入窗口）→ 仍应通过。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    caps = {p: n * 2 for p, n in _GOLDEN_PER_DAY.items()}
    wins, ae, full = _production_cap_windows(days, caps=caps)
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is True


def test_per_day_gate_passes_with_zero_before_cap():
    """cap=0（纯 forward 窗口，无 before-context）→ 边界日就是首个前向交易日，应通过。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    wins, ae, full = _production_cap_windows(days, caps={p: 0 for p in _GOLDEN_PER_DAY})
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is True


def test_build_training_windows_succeeds_under_production_config():
    """端到端：生产 PERIOD_BEFORE_CAP + 完美数据 → 生产入口必须**选得出**起点。
    这条就是「Plan 2 能不能出货」的最小可执行证据。"""
    from generate_training_sets import PERIOD_BEFORE_CAP
    from qmt_resample import period_boundaries
    days = _weekday_range(dt.date(2022, 1, 3), dt.date(2025, 12, 31))
    daily = pd.DataFrame([{"datetime": _mid(d.year, d.month, d.day), "open": 1.0,
                           "high": 1.0, "low": 1.0, "close": 1.0, "volume": 1,
                           "amount": 1.0} for d in days])
    first_m, first_w = {}, {}
    for d in days:
        first_m.setdefault((d.year, d.month), d)
        first_w.setdefault(d.isocalendar()[:2], d)
    def _cal(sel):
        return pd.DataFrame([{"datetime": _mid(d.year, d.month, d.day), "open": 1.0,
                              "high": 1.0, "low": 1.0, "close": 1.0, "volume": 1,
                              "amount": 1.0} for d in sorted(sel)])
    pb = {"daily": daily, "monthly": _cal(first_m.values()), "weekly": _cal(first_w.values())}
    for p, n in _GOLDEN_PER_DAY.items():
        pb[p] = _golden_intraday(days, n)
    mb = period_boundaries(daily, "monthly")
    start, windows = build_training_windows(
        pb, mb, random.Random(0), dense_dates=set(days), trading_dates=days,
        before_caps=PERIOD_BEFORE_CAP)
    assert start in [int(b) for b in mb]
    assert not windows["3m"].empty


# ===== Plan 2b Task 5：assemble_from_windows（取代已删的 assemble_training_set）=====

def test_assemble_from_windows_produces_zip_and_matching_hash(tmp_path):
    """纯装配：windows → assign_global_indices → SQLite → zip → CRC32。
    content_hash 必须等于 zip 文件字节的 CRC32（D3）。"""
    from generate_training_sets import assemble_from_windows
    windows = {p: _bars(p, 40) for p in PERIODS}
    start = int(windows["monthly"]["datetime"].iloc[10])
    end = int(windows["monthly"]["datetime"].iloc[-1])
    gts = assemble_from_windows(tmp_path, stock_code="000001.SZ", stock_name="平安银行",
                                start_datetime=start, end_datetime=end, windows=windows)
    assert gts.path.exists() and gts.path.suffix == ".zip"
    assert gts.content_hash == crc32_hex(gts.path.read_bytes())
    assert gts.stock_code == "000001.SZ" and gts.start_datetime == start
    assert gts.end_datetime == end and gts.schema_version == SCHEMA_VERSION


def test_assemble_from_windows_filename_is_code_underscore_start(tmp_path):
    """文件名契约 {stock_code}_{start_datetime}（沿用 PR #74 既有约定，B3 下载按此路径）。"""
    from generate_training_sets import assemble_from_windows
    windows = {p: _bars(p, 40) for p in PERIODS}
    start = int(windows["monthly"]["datetime"].iloc[10])
    gts = assemble_from_windows(tmp_path, stock_code="600519", stock_name="X",
                                start_datetime=start, end_datetime=start + 100,
                                windows=windows)
    assert gts.path.name == f"600519_{start}.zip"


def test_assemble_from_windows_writes_all_periods_into_sqlite(tmp_path):
    """六周期都要进训练组 SQLite；漏一个 = App 少一个周期可看。"""
    from generate_training_sets import assemble_from_windows
    import zipfile as _zf
    windows = {p: _bars(p, 40) for p in PERIODS}
    start = int(windows["monthly"]["datetime"].iloc[10])
    gts = assemble_from_windows(tmp_path, stock_code="X", stock_name="X",
                                start_datetime=start, end_datetime=start + 100,
                                windows=windows)
    with _zf.ZipFile(gts.path) as z:
        z.extractall(tmp_path / "x")
    conn = sqlite3.connect(str(tmp_path / "x" / f"X_{start}.db"))
    try:
        got = {r[0] for r in conn.execute("SELECT DISTINCT period FROM klines")}
    finally:
        conn.close()
    assert got == set(PERIODS)


def test_assemble_from_windows_leaves_only_zip_in_output_dir(tmp_path):
    """中间 .db 建在临时目录（codex PF2-R5-F1），不落在 output_dir：留渣会让下次同起点重试
    撞 `table meta already exists`（DDL 裸 CREATE TABLE 无 IF NOT EXISTS）。
    非 brief 逐字给出的测试——补充覆盖此守卫（实施者自查发现无测试覆盖）。"""
    from generate_training_sets import assemble_from_windows
    windows = {p: _bars(p, 40) for p in PERIODS}
    start = int(windows["monthly"]["datetime"].iloc[10])
    gts = assemble_from_windows(tmp_path, stock_code="Y", stock_name="Y",
                                start_datetime=start, end_datetime=start + 100,
                                windows=windows)
    assert {p.name for p in tmp_path.iterdir()} == {gts.path.name}


# ===== Plan 2b Task 5：exclude_starts（uq_stock_start 变成候选资格）=====

def _production_fixture():
    """生产配置下可用的完整 fixture（复用 Task 4 的 _weekday_range / _golden_intraday）：
    4 年工作日、每交易日精确 80/16/4 根盘中、日/周/月标组内首交易日午夜、全程 dense。
    返回 (period_bars, month_boundaries, days)。"""
    from qmt_resample import period_boundaries
    days = _weekday_range(dt.date(2022, 1, 3), dt.date(2025, 12, 31))

    def _cal(sel):
        return pd.DataFrame([{"datetime": _mid(d.year, d.month, d.day), "open": 1.0,
                              "high": 1.0, "low": 1.0, "close": 1.0, "volume": 1,
                              "amount": 1.0} for d in sorted(sel)])

    first_m, first_w = {}, {}
    for d in days:
        first_m.setdefault((d.year, d.month), d)
        first_w.setdefault(d.isocalendar()[:2], d)
    pb = {"daily": _cal(days), "monthly": _cal(first_m.values()),
          "weekly": _cal(first_w.values())}
    for p, n in _GOLDEN_PER_DAY.items():
        pb[p] = _golden_intraday(days, n)
    return pb, period_boundaries(pb["daily"], "monthly"), days


def test_build_training_windows_skips_excluded_start():
    """uq_stock_start：已登记的起点不得再被选中，且不能因此误杀该股——
    应换下一个候选并成功（而非整股失败）。"""
    from generate_training_sets import PERIOD_BEFORE_CAP
    pb, mb, days = _production_fixture()
    kw = dict(dense_dates=set(days), trading_dates=days, before_caps=PERIOD_BEFORE_CAP)
    s1, _ = build_training_windows(pb, mb, random.Random(0), **kw)
    s2, w2 = build_training_windows(pb, mb, random.Random(0),
                                    exclude_starts=frozenset({s1}), **kw)
    assert s2 != s1
    assert not w2["3m"].empty


def test_build_training_windows_all_candidates_excluded_raises():
    """全部候选都已登记 → 该股确实无可用起点 → GenerateSkipException（非静默产坏组）。
    注意 max_retries 默认 8，故排除集须覆盖所有月边界才能确保穷尽。"""
    from generate_training_sets import PERIOD_BEFORE_CAP
    pb, mb, days = _production_fixture()
    with pytest.raises(GenerateSkipException):
        build_training_windows(pb, mb, random.Random(0), dense_dates=set(days),
                               trading_dates=days, before_caps=PERIOD_BEFORE_CAP,
                               exclude_starts=frozenset(int(b) for b in mb))


def test_select_valid_window_excludes_before_retry_budget():
    """codex PF2-R1-F2：前 max_retries(8) 个候选全已登记 → 仍须选中之后的有效候选。

    排除必须发生在 `cands[:max_retries]` 切片**之前**。若让被排除者进循环再拒（我最初的
    设计），每个都会吃掉一个重试名额 → 股票累积训练组后、shuffle 恰好把已登记的排前面，
    就会**明明还有可用起点却整股被跳过**，且非确定性（B4 库存会莫名欠产）。
    直接注入 try_assemble，不建重 fixture。"""
    bounds = _n_month_boundaries(60)                    # n=60 → 候选 idx 30..51 共 22 个
    days = _weekday_range(dt.date(2020, 1, 1), dt.date(2025, 12, 31))
    dense, trading = set(days), days
    # 用同一 seed 先取 shuffle 顺序，令断言确定（eligible_start_indices 内部 rng.shuffle）
    order = eligible_start_indices(bounds, random.Random(1), dense_dates=dense,
                                   trading_dates=trading)
    assert len(order) > 9, "fixture 须提供多于 max_retries 的候选，否则本测 vacuous"
    excluded = frozenset(int(bounds[i]) for i in order[:9])   # 排除前 9 个（> max_retries=8）
    survivor = int(bounds[order[9]])
    start, _ = select_valid_window(bounds, random.Random(1), dense_dates=dense,
                                   trading_dates=trading,
                                   try_assemble=lambda s: {"ok": True},
                                   exclude_starts=excluded)
    assert start == survivor, "被排除的候选吃掉了重试名额（修复前必挂）"


from generate_training_sets import stock_lock_key, IMPORT_GEN_LOCK_KEY, B2_GENERATION_LOCK_KEY

def test_stock_lock_key_deterministic_and_int4():
    a = stock_lock_key("000001.SZ"); b = stock_lock_key("000001.SZ")
    assert a == b and 0 <= a <= 0x7FFFFFFF          # 同 code 恒定、落 int4 正区间
    assert isinstance(stock_lock_key("000002.SZ"), int)  # 别股也返 int（碰撞允许，故不断言不等）
    assert IMPORT_GEN_LOCK_KEY != B2_GENERATION_LOCK_KEY
