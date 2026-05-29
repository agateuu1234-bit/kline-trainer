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
    GeneratedTrainingSet,
    GenerateSkipException,
    PERIODS,
    SCHEMA_VERSION,
    assemble_training_set,
    assign_global_indices,
    build_training_set_sqlite,
    crc32_hex,
    monthly_after_end,
    select_period_window,
    select_start_index,
    zip_and_hash,
)

_STEP = {"monthly": 2_592_000, "weekly": 604_800, "daily": 86_400,
         "60m": 3_600, "15m": 900, "3m": 180}
_CSTEP = {"monthly": 100, "weekly": 60, "daily": 40, "60m": 30, "15m": 20, "3m": 10}
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


def _period_bars(*, monthly_n: int = 39) -> dict:
    base = 100_000
    span = monthly_n * _CSTEP["monthly"]
    pb = {}
    for p in PERIODS:
        step = _CSTEP[p]
        pb[p] = _bars(p, span // step + 1, base=base, step=step)
    pb["monthly"] = _bars("monthly", monthly_n, base=base, step=_CSTEP["monthly"])
    return pb


def test_crc32_hex_known_value_lowercase_8():
    expected = format(zlib.crc32(b"kline") & 0xFFFFFFFF, "08x")
    got = crc32_hex(b"kline")
    assert got == expected
    assert len(got) == 8 and got == got.lower()

def test_crc32_hex_zero_padded():
    got = crc32_hex(b"")
    assert got == "00000000"

def test_select_start_index_in_valid_range_deterministic():
    dts = list(range(50))
    idx = select_start_index(dts, random.Random(42))
    assert 30 <= idx <= len(dts) - 9
    assert idx == select_start_index(dts, random.Random(42))

def test_select_start_index_too_few_monthly_raises():
    with pytest.raises(GenerateSkipException):
        select_start_index(list(range(38)), random.Random(1))

def test_monthly_after_end_is_eighth_bar_inclusive():
    dts = [100 + i * 10 for i in range(20)]
    start = dts[5]
    assert monthly_after_end(dts, start) == dts[12]

def test_monthly_after_end_no_bar_after_raises():
    dts = [100, 110, 120]
    with pytest.raises(GenerateSkipException):
        monthly_after_end(dts, 999)

def test_select_period_window_before_cap_respected():
    bars = _bars("daily", 400)
    start = int(bars["datetime"].iloc[300])
    after_end = int(bars["datetime"].iloc[310])
    win = select_period_window(bars, start, before_cap=150, after_end_time=after_end)
    before = win[win["datetime"] < start]
    assert len(before) == 150

def test_select_period_window_monthly_before_all():
    bars = _bars("monthly", 50)
    start = int(bars["datetime"].iloc[40])
    after_end = int(bars["datetime"].iloc[47])
    win = select_period_window(bars, start, before_cap=None, after_end_time=after_end)
    before = win[win["datetime"] < start]
    assert len(before) == 40

def test_select_period_window_after_inclusive_bounds():
    bars = _bars("daily", 400)
    start = int(bars["datetime"].iloc[300])
    after_end = int(bars["datetime"].iloc[305])
    win = select_period_window(bars, start, before_cap=150, after_end_time=after_end)
    after = win[win["datetime"] >= start]
    assert after["datetime"].min() == start
    assert after["datetime"].max() == after_end
    assert (after["datetime"] <= after_end).all()

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

def test_assemble_training_set_end_to_end(tmp_path):
    gts = assemble_training_set(tmp_path, stock_code="600519", stock_name="测试股",
                                period_bars=_period_bars(), rng=random.Random(7))
    assert isinstance(gts, GeneratedTrainingSet)
    assert gts.path.exists() and gts.path.suffix == ".zip"
    assert len(gts.content_hash) == 8 and gts.content_hash == gts.content_hash.lower()
    assert gts.schema_version == SCHEMA_VERSION
    assert gts.start_datetime < gts.end_datetime
    with zipfile.ZipFile(gts.path) as zf:
        data = zf.read(zf.namelist()[0])
    db2 = tmp_path / "extracted.db"
    db2.write_bytes(data)
    conn = sqlite3.connect(str(db2))
    try:
        three_dt = [r[0] for r in conn.execute(
            "SELECT datetime FROM klines WHERE period='3m' ORDER BY datetime")]
        assert min(three_dt) < gts.start_datetime <= max(three_dt)
        gi = [r[0] for r in conn.execute(
            "SELECT global_index FROM klines WHERE period='3m' ORDER BY datetime")]
        assert gi == list(range(len(gi))) and len(gi) > 0
        n3 = len(gi)
        nulls = conn.execute(
            "SELECT COUNT(*) FROM klines WHERE end_global_index IS NULL").fetchone()[0]
        assert nulls == 0
        egi15 = [r[0] for r in conn.execute(
            "SELECT end_global_index FROM klines WHERE period='15m'")]
        assert any(0 < e < n3 - 1 for e in egi15)
    finally:
        conn.close()

def test_assemble_skip_when_monthly_insufficient(tmp_path):
    with pytest.raises(GenerateSkipException):
        assemble_training_set(tmp_path, stock_code="X", stock_name="X",
                              period_bars=_period_bars(monthly_n=20), rng=random.Random(1))

def test_assemble_skip_when_period_before_under_30(tmp_path):
    pb = _period_bars()
    pb = {**pb, "3m": _bars("3m", 80, base=102_950, step=10)}
    with pytest.raises(GenerateSkipException):
        assemble_training_set(tmp_path, stock_code="X", stock_name="X",
                              period_bars=pb, rng=random.Random(7))
