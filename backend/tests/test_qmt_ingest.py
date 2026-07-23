import datetime as dt

import numpy as np
import pandas as pd
import pytest
from qmt_ingest import ExportLogEntry, ImportBundle, build_stock_import, parse_export_log, QmtIngestRejected
from qmt_normalize import QmtSchemaError
from tests._qmt_fixtures import gen

def _write_log(tmp_path, rows):
    import csv
    p = tmp_path / "export_log.csv"
    with open(p, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f); w.writerow(["stock", "period", "status", "rows", "first_time", "last_time"])
        for r in rows: w.writerow(r)
    return p

def test_parse_export_log_basic(tmp_path):
    p = _write_log(tmp_path, [["000001.SZ", "1m", "ok", "241", "20200102093000", "20200102150000"]])
    d = parse_export_log(p)
    e = d[("000001.SZ", "1m")]
    assert e.code == "000001.SZ" and e.period == "1m" and e.status == "ok" and e.rows == 241

def test_parse_export_log_missing_column_raises(tmp_path):
    import csv
    p = tmp_path / "export_log.csv"
    with open(p, "w", newline="", encoding="utf-8-sig") as f:
        csv.writer(f).writerow(["stock", "period", "status"])   # 缺 rows/first/last
    with pytest.raises(QmtSchemaError):
        parse_export_log(p)

def test_parse_export_log_duplicate_key_raises(tmp_path):
    p = _write_log(tmp_path, [
        ["000001.SZ", "1m", "error", "1", "20200102093000", "20200102093000"],
        ["000001.SZ", "1m", "ok", "241", "20200102093000", "20200102150000"]])
    with pytest.raises(QmtSchemaError) as ei:
        parse_export_log(p)
    assert "export_log_duplicate" in str(ei.value)


def test_parse_export_log_bad_rows_raises_schema_error(tmp_path):
    p = _write_log(tmp_path, [["000001.SZ", "1m", "ok", "abc", "20200102093000", "20200102150000"]])
    with pytest.raises(QmtSchemaError) as ei:
        parse_export_log(p)
    assert "export_log 行解析失败" in str(ei.value)


def test_parse_export_log_malformed_first_time_raises_schema_error(tmp_path):
    p = _write_log(tmp_path, [["000001.SZ", "1m", "ok", "241", "not-a-timestamp", "20200102150000"]])
    with pytest.raises(QmtSchemaError) as ei:
        parse_export_log(p)
    assert "export_log 行解析失败" in str(ei.value)


# ===== build_stock_import：全部导入期门 =====

def _entry(code, period, df):
    return ExportLogEntry(code=code, period=period, status="ok", rows=len(df),
                          first_time=int(df.iloc[0]["datetime"]),
                          last_time=int(df.iloc[-1]["datetime"]), source=code)


def test_identity_mismatch_rejects(gen):   # A 的 df + B 的 stock_code
    s1, sd, e1, ed = gen("000001.SZ")
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000002.SZ", stock_name="x",
                           entry_1m=e1, entry_daily=ed)
    assert "source_identity_mismatch" in str(ei.value)


def test_export_log_status_error_rejects(gen):
    s1, sd, e1, ed = gen("000001.SZ")
    e1_bad = ExportLogEntry(**{**e1.__dict__, "status": "error"})
    with pytest.raises(QmtIngestRejected):
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1_bad, entry_daily=ed)


def test_copy_integrity_rows_mismatch_rejects(gen):
    s1, sd, e1, ed = gen("000001.SZ")
    e1_bad = ExportLogEntry(**{**e1.__dict__, "rows": e1.rows + 1})
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1_bad, entry_daily=ed)
    assert "export_log_mismatch" in str(ei.value)


def test_daily_negative_volume_rejects(gen):
    s1, sd, e1, ed = gen("000001.SZ")
    sd.df.iloc[0, sd.df.columns.get_loc("volume")] = -5   # 深历史坏 volume
    ed = _entry("000001.SZ", "daily", sd.df)
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1, entry_daily=ed)
    assert "bad_amount_or_volume" in str(ei.value)


def test_1m_bad_amount_rejects(gen):
    s1, sd, e1, ed = gen("000001.SZ")
    s1.df.iloc[0, s1.df.columns.get_loc("amount")] = np.inf   # 241 齐全但坏值
    e1 = _entry("000001.SZ", "1m", s1.df)
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1, entry_daily=ed)
    assert "bad_amount_or_volume" in str(ei.value)


def test_valid_returns_bundle(gen):
    s1, sd, e1, ed = gen("000001.SZ")
    b = build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="平安",
                           entry_1m=e1, entry_daily=ed)
    assert isinstance(b, ImportBundle)
    assert set(b.records.keys()) == {"monthly", "weekly", "daily", "60m", "15m", "3m"}
    assert b.coverage.dense_day_count >= 1
    assert b.coverage.start_date <= b.coverage.end_date


def test_short_1m_history_no_eligible_window_rejects(gen):
    """日线够（≥39 月边界）但 1m dense 覆盖太短（仅 5 天）→ 任何 8 个月前向窗口都凑不齐
    dense 交易日 → 门5 出货可行性预检必拒（no_eligible_training_window）。"""
    s1, sd, e1, ed = gen("000001.SZ", n_years_daily=4, n_days_1m=5)
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1, entry_daily=ed)
    assert "no_eligible_training_window" in str(ei.value)


def test_dropped_day_blocks_training_window_rejects(gen):
    """P3-D9(a)/R16-F1：某日 1m 残缺（未满 241，落 DenseCoverage.dropped_dates）且其
    daily 行也同步缺失（B1 半途导入场景）——此时该日既不在 trading_dates 也不在
    dense_dates 判据能看到的窗口交易日集合里，`build_training_windows` 的常规
    dense-check 对它完全失明，只有独立传入的 `dropped=frozenset(cov.dropped_dates)`
    阻断器能拦住。默认 gen() 的 4 个可行候选窗口 [2022-12-01..2023-10-31] 共同覆盖
    2023-05-02，挖掉它必使全部候选出局 → no_eligible_training_window。"""
    from qmt_normalize import QmtSource, trading_date as _td
    s1, sd, e1, ed = gen("000001.SZ")
    target = dt.date(2023, 5, 2)   # 落在全部 4 个候选窗口 [d0,d1] 交集 [2023-03-01,2023-07-31] 内
    is_target_daily = sd.df["datetime"].map(lambda e: _td(e) == target)
    assert is_target_daily.sum() == 1
    daily2 = sd.df[~is_target_daily].reset_index(drop=True)
    is_target_1m = s1.df["datetime"].map(lambda e: _td(e) == target)
    assert is_target_1m.sum() == 241
    target_rows = s1.df[is_target_1m].iloc[:100]          # 残缺：100/241 根 → dropped 非 complete
    m1_2 = pd.concat([s1.df[~is_target_1m], target_rows]).sort_values("datetime").reset_index(drop=True)
    s1b = QmtSource(s1.code, s1.period, m1_2)
    sdb = QmtSource(sd.code, sd.period, daily2)
    e1b = _entry("000001.SZ", "1m", m1_2)
    edb = _entry("000001.SZ", "daily", daily2)
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1b, sdb, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1b, entry_daily=edb)
    assert "no_eligible_training_window" in str(ei.value)
