# backend/tests/test_import_csv.py
# Spec: kline_trainer_modules_v1.4.md §四 B1 + plan 2026-05-29-pr-b1-import-csv.md Task 1
# 纯函数层：全部 in-memory DataFrame，不连 PostgreSQL（写库壳由 B3/NAS 集成测试覆盖，D14）。
from __future__ import annotations

import math
from pathlib import Path

import pandas as pd
import pytest

from import_csv import (
    CsvSchemaError,
    clean,
    compute_indicators,
    parse_csv,
    to_kline_records,
)

FIXTURE = Path(__file__).parent / "fixtures" / "sample_1m.csv"


def _synthetic(n: int) -> pd.DataFrame:
    """n 行单调递增 1m 数据（datetime 秒，close 0.10 递增）。"""
    rows = []
    base = 1_704_159_000  # 2024-01-02 09:30:00 UTC 秒（断言只看相对，不校时区）
    for i in range(n):
        close = 10.0 + i * 0.10
        rows.append({
            "datetime": base + i * 60,
            "open": round(close - 0.10, 2),
            "high": round(close + 0.10, 2),
            "low": round(close - 0.12, 2),
            "close": round(close, 2),
            "volume": 1000 + i,
            "amount": round(close * (1000 + i), 2),
        })
    return pd.DataFrame(rows)


# ---- D7 parse + schema error ----

def test_parse_csv_reads_fixture_columns():
    df = parse_csv(FIXTURE)
    assert {"datetime", "open", "high", "low", "close", "volume"} <= set(df.columns)
    assert len(df) >= 66  # 足够触发 MA66

def test_parse_csv_missing_required_column_raises():
    bad = pd.DataFrame({"datetime": [1], "open": [1.0]})  # 缺 high/low/close/volume
    with pytest.raises(CsvSchemaError):
        clean(bad)  # clean 先校验必需列存在

# ---- D9 cleaning（R04 A股异常）----

def test_clean_drops_nonpositive_price():
    df = _synthetic(3)
    df.loc[1, "close"] = 0.0  # 非正价
    out = clean(df)
    assert len(out) == 2
    assert 0.0 not in out["close"].values

def test_clean_drops_high_lt_low():
    df = _synthetic(3)
    df.loc[1, "high"] = 1.0
    df.loc[1, "low"] = 9.0  # high < low
    out = clean(df)
    assert len(out) == 2

def test_clean_dedupes_on_datetime_keep_last():
    # R1-H1：变异 volume（非 OHLC 校验字段），dup 行才不会被有效性过滤先丢掉，
    # 这样 drop_duplicates(keep="last") 的"保留后一条"才可观测。
    df = _synthetic(2)
    dup = df.iloc[[1]].copy()
    dup.loc[dup.index[0], "volume"] = 999_999  # schema-valid 变异
    df2 = pd.concat([df, dup], ignore_index=True)
    out = clean(df2)
    assert len(out) == 2
    last_dt = out["datetime"].max()
    assert int(out.loc[out["datetime"] == last_dt, "volume"].iloc[0]) == 999_999

def test_clean_sorts_ascending_by_datetime():
    df = _synthetic(3).iloc[::-1].reset_index(drop=True)  # 倒序
    out = clean(df)
    assert list(out["datetime"]) == sorted(out["datetime"])

# ---- D3 MA66 ----

def test_ma66_null_before_window_and_exact_at_66():
    df = compute_indicators(clean(_synthetic(66)))
    assert df["ma66"].iloc[:65].isna().all()           # 前 65 行 NULL
    # 第 66 行（idx 65）= close[0..65] 均值；close = 10.00,10.10,...,16.50
    expected = round(sum(10.0 + i * 0.10 for i in range(66)) / 66, 4)
    assert df["ma66"].iloc[65] == pytest.approx(expected, abs=1e-4)

# ---- D4 BOLL ----

def test_boll_20_window_population_std():
    df = compute_indicators(clean(_synthetic(25)))
    assert df["boll_mid"].iloc[:19].isna().all()
    window = [10.0 + i * 0.10 for i in range(20)]      # idx 0..19
    mid = sum(window) / 20
    var = sum((x - mid) ** 2 for x in window) / 20      # ddof=0 总体
    std = math.sqrt(var)
    assert df["boll_mid"].iloc[19] == pytest.approx(round(mid, 4), abs=1e-4)
    assert df["boll_upper"].iloc[19] == pytest.approx(round(mid + 2 * std, 4), abs=1e-4)
    assert df["boll_lower"].iloc[19] == pytest.approx(round(mid - 2 * std, 4), abs=1e-4)

# ---- D5 MACD ----

def test_macd_ewm_adjust_false_and_bar_times_two():
    close = pd.Series([10.0 + i * 0.10 for i in range(40)])
    ema12 = close.ewm(span=12, adjust=False).mean()
    ema26 = close.ewm(span=26, adjust=False).mean()
    dif = ema12 - ema26
    dea = dif.ewm(span=9, adjust=False).mean()
    bar = (dif - dea) * 2
    df = compute_indicators(clean(_synthetic(40)))
    assert df["macd_diff"].iloc[-1] == pytest.approx(round(dif.iloc[-1], 6), abs=1e-6)
    assert df["macd_dea"].iloc[-1] == pytest.approx(round(dea.iloc[-1], 6), abs=1e-6)
    assert df["macd_bar"].iloc[-1] == pytest.approx(round(bar.iloc[-1], 6), abs=1e-6)

def test_macd_columns_present_from_first_row():
    df = compute_indicators(clean(_synthetic(30)))
    assert not df["macd_diff"].isna().any()   # ewm adjust=False 从首行起有值

# ---- to_records + 精度 ----

def test_to_kline_records_shape_and_period_stock():
    df = compute_indicators(clean(_synthetic(70)))
    records = to_kline_records(df, stock_code="600519", period="1m")
    assert len(records) == 70
    r = records[-1]
    assert r["stock_code"] == "600519" and r["period"] == "1m"
    assert set(r) >= {"datetime", "open", "high", "low", "close", "volume",
                      "amount", "ma66",
                      "boll_upper", "boll_mid", "boll_lower",
                      "macd_diff", "macd_dea", "macd_bar"}

def test_to_kline_records_nan_becomes_none():
    df = compute_indicators(clean(_synthetic(10)))  # MA66 全 NaN（<66 行）
    records = to_kline_records(df, stock_code="X", period="1m")
    assert records[0]["ma66"] is None  # NaN → None（asyncpg 写 NULL）

def test_to_kline_records_integer_columns_are_python_int():
    # R1-H2：BIGINT/INTEGER 列必须是 Python int（非 numpy.float64/int64），否则 asyncpg codec 拒收
    df = compute_indicators(clean(_synthetic(70)))
    rec = to_kline_records(df, stock_code="X", period="1m")[-1]
    for col in ("datetime", "volume"):
        assert type(rec[col]) is int, f"{col} 应是 Python int，实得 {type(rec[col])}"
    for col in ("close", "ma66"):  # ma66 在第 70 行有值（≥66）
        assert type(rec[col]) is float, f"{col} 应是 Python float，实得 {type(rec[col])}"


# ---- D3/R12-F1：ticket_index 停止写入（列保留、新行 NULL）----

def test_to_kline_records_omits_ticket_index():
    """D3：Python 侧不再产出 ticket_index；PG 列保留、新行为 NULL。"""
    df = compute_indicators(clean(_synthetic(70)))
    records = to_kline_records(df, stock_code="600519", period="1m")
    assert records, "fixture 应产出记录"
    assert "ticket_index" not in records[0], "ticket_index 应已停写"


def test_kline_insert_sql_has_no_ticket_index():
    """INSERT 语句不得再含该列——留着会让 executemany 元组数与占位符错位。"""
    from import_csv import _KLINE_INSERT
    assert "ticket_index" not in _KLINE_INSERT


def test_kline_insert_placeholder_count_matches_columns():
    """防"删列名忘删占位符"：列数必须与 $N 最大编号一致。"""
    import re
    from import_csv import _KLINE_INSERT
    cols = _KLINE_INSERT.split("INSERT INTO klines (")[1].split(")")[0]
    n_cols = len([c for c in cols.split(",") if c.strip()])
    n_ph = max(int(m) for m in re.findall(r"\$(\d+)", _KLINE_INSERT))
    assert n_cols == n_ph == 16, f"列 {n_cols} vs 占位符 {n_ph}，期望均为 16"


def test_compute_ticket_index_symbol_removed():
    """函数已删除；残留即说明停写没做干净。"""
    import import_csv
    assert not hasattr(import_csv, "compute_ticket_index")
