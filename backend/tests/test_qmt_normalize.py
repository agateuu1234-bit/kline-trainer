# backend/tests/test_qmt_normalize.py
from __future__ import annotations
import datetime as dt
import pandas as pd
import pytest
from zoneinfo import ZoneInfo
from pathlib import Path
from qmt_normalize import trading_date, parse_qmt_datetime, parse_qmt_csv, parse_qmt_filename, QmtSchemaError, QmtSource

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

def test_parse_qmt_filename_three_markets():
    assert parse_qmt_filename("000001.SZ_平安银行_1分钟K线_前复权.csv") == ("000001.SZ", "平安银行", "1m")
    assert parse_qmt_filename("600519.SH_贵州茅台_日K线_前复权.csv") == ("600519.SH", "贵州茅台", "daily")
    assert parse_qmt_filename("920000.BJ_安徽凤凰_1分钟K线_前复权.csv") == ("920000.BJ", "安徽凤凰", "1m")

def test_parse_qmt_filename_fullwidth_name():
    assert parse_qmt_filename("000002.SZ_万科Ａ_日K线_前复权.csv") == ("000002.SZ", "万科Ａ", "daily")

def test_parse_qmt_csv_strips_bom_and_parses(tmp_path: Path):
    p = tmp_path / "000001.SZ_平安银行_1分钟K线_前复权.csv"
    # utf-8-sig 写入 → 首字节 BOM；表头列名须为 datetime 不含 BOM
    p.write_text("time,open,high,low,close,volume,amount\n"
                 "20260703093000,10.29,10.29,10.29,10.29,10899,11215071.0\n",
                 encoding="utf-8-sig")
    df = parse_qmt_csv(p, "1m").df
    assert list(df.columns) == ["datetime", "open", "high", "low", "close", "volume", "amount"]
    assert df.loc[0, "datetime"] == int(df.loc[0, "datetime"])  # Unix 秒 Int64
    assert df.loc[0, "open"] == 10.29

def test_parse_qmt_csv_missing_col_raises(tmp_path: Path):
    p = tmp_path / "y.csv"
    p.write_text("time,open,high,low,close\n20260703093000,1,1,1,1\n", encoding="utf-8-sig")
    with pytest.raises(QmtSchemaError):
        parse_qmt_csv(p, "1m")

def test_parse_qmt_csv_malformed_time_raises_schema_error(tmp_path: Path):
    """FIX2：time 列坏值——parse_qmt_datetime 裸抛 ValueError，须归一化为
    QmtSchemaError（CLI --qmt 的 except 只认域异常，不然裸 traceback）。"""
    p = tmp_path / "000001.SZ_平安银行_1分钟K线_前复权.csv"
    p.write_text("time,open,high,low,close,volume,amount\n"
                 "notadate,10.29,10.29,10.29,10.29,10899,11215071.0\n",
                 encoding="utf-8-sig")
    with pytest.raises(QmtSchemaError):
        parse_qmt_csv(p, "1m")

def test_parse_qmt_csv_empty_raises_schema_error(tmp_path: Path):
    """FIX2：空/只有表头的 QMT CSV（零数据行）须干净拒绝，不是下游裸 IndexError。"""
    p = tmp_path / "000001.SZ_平安银行_1分钟K线_前复权.csv"
    p.write_text("time,open,high,low,close,volume,amount\n", encoding="utf-8-sig")
    with pytest.raises(QmtSchemaError):
        parse_qmt_csv(p, "1m")

def test_parse_qmt_csv_returns_source_with_filename_identity(tmp_path):
    p = tmp_path / "000001.SZ_平安银行_日K线_前复权.csv"
    p.write_text("time,open,high,low,close,volume,amount\n"
                 "20200102,1.0,1.1,0.9,1.05,100,1050.0\n", encoding="utf-8-sig")
    src = parse_qmt_csv(p, "daily")
    assert isinstance(src, QmtSource)
    assert src.code == "000001.SZ"
    assert src.period == "daily"
    assert list(src.df.columns) == ["datetime", "open", "high", "low", "close", "volume", "amount"]
