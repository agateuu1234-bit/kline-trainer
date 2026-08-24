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


def test_parse_export_log_zero_byte_file_raises_schema_error(tmp_path):
    """R5-F1：零字节 export_log（中断的拷贝）在 pd.read_csv 处抛 pandas EmptyDataError，
    须在解析边界归一化为 QmtSchemaError，不裸 traceback。"""
    p = tmp_path / "export_log.csv"
    p.write_bytes(b"")
    with pytest.raises(QmtSchemaError):
        parse_export_log(p)


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


def test_daily_negative_amount_rejects(gen):
    s1, sd, e1, ed = gen("000001.SZ")
    sd.df.iloc[0, sd.df.columns.get_loc("amount")] = -0.01   # 深历史坏 amount（负数）
    ed = _entry("000001.SZ", "daily", sd.df)
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1, entry_daily=ed)
    assert "bad_amount_or_volume" in str(ei.value)


def test_1m_negative_amount_rejects(gen):
    s1, sd, e1, ed = gen("000001.SZ")
    s1.df.iloc[0, s1.df.columns.get_loc("amount")] = -0.01   # 241 齐全但坏值（负数）
    e1 = _entry("000001.SZ", "1m", s1.df)
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1, entry_daily=ed)
    assert "bad_amount_or_volume" in str(ei.value)


def test_1m_non_numeric_amount_rejects(gen):
    """FIX2：amount 列里混进非数字字符串——`to_numpy(dtype=float64)` 今裸抛
    ValueError；须归一化为域异常 QmtIngestRejected(bad_amount_or_volume)。"""
    s1, sd, e1, ed = gen("000001.SZ")
    s1.df["amount"] = s1.df["amount"].astype(object)
    s1.df.iloc[0, s1.df.columns.get_loc("amount")] = "bad"
    e1 = _entry("000001.SZ", "1m", s1.df)
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1, entry_daily=ed)
    assert "bad_amount_or_volume" in str(ei.value)


def test_1m_duplicate_datetime_rejects(gen):
    """FIX1：1m 源含重复 datetime 行——clean 去重(keep last)使 cln 变短，daily 已有的
    「clean 无损」门须在 1m 上同款生效（daily_clean_dropped_rows 的姊妹门）。"""
    from qmt_normalize import QmtSource
    s1, sd, e1, ed = gen("000001.SZ")
    dup_row = s1.df.iloc[5:6]
    m1 = pd.concat([s1.df, dup_row]).sort_values("datetime").reset_index(drop=True)
    s1 = QmtSource(s1.code, s1.period, m1)
    e1 = _entry("000001.SZ", "1m", m1)
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1, entry_daily=ed)
    assert "clean_dropped_rows_1m" in str(ei.value)


def test_1m_bad_ohlc_row_clean_dropped_rejects(gen):
    """FIX1：1m 源含 clean 会丢的坏 OHLC 行（high<low）——静默丢一行也须挡，不能让
    export_log 的原始行数与实际处理的行数悄悄对不上。"""
    from qmt_normalize import QmtSource
    s1, sd, e1, ed = gen("000001.SZ")
    m1 = s1.df.copy()
    m1.loc[5, "high"] = m1.loc[5, "low"] - 1.0   # high < low → clean 丢这一行
    s1 = QmtSource(s1.code, s1.period, m1)
    e1 = _entry("000001.SZ", "1m", m1)
    with pytest.raises(QmtIngestRejected) as ei:
        build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="x",
                           entry_1m=e1, entry_daily=ed)
    assert "clean_dropped_rows_1m" in str(ei.value)


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


# ============ 真实 QMT 导出格式的回归钉（2026-08-23 挂载实测坐实）============
# ⚠️ 上面那些用例造的 export_log 里 period 列写的是 "1m"/"daily" —— 那是**想象出来的
# 格式**。真实导出脚本（export_all_front_ratio_stocks_only.py:507/515）写死的是
# "1m"/"1d"，5608 只股 × 2 周期。测试测的格式与生产格式不一致，是这两个缺陷
# 三年没被发现的直接原因。

def _write_real_format_log(tmp_path, rows):
    """按**真实导出**的列与取值造 export_log（12 列、带 BOM、period 用 1m/1d）。"""
    import csv
    p = tmp_path / "export_log.csv"
    cols = ["dividend_type", "exchange", "file_path", "first_time", "label",
            "last_time", "name", "period", "rows", "status", "stock", "time"]
    with open(p, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    return p


def _real_row(stock, period, status="ok", rows="100",
              first="20250704101200", last="20260703150000"):
    label = "1分钟K线" if period == "1m" else "日K线"
    return {"dividend_type": "front_ratio", "exchange": "SZSE",
            "file_path": f"D:\\qmt_export\\x\\{stock}_名_{label}_前复权.csv",
            "first_time": first, "label": label, "last_time": last,
            "name": "名", "period": period, "rows": rows, "status": status,
            "stock": stock, "time": "2026-07-05 21:28:47"}


def test_real_format_daily_period_1d_is_not_silently_dropped(tmp_path):
    """缺陷①：真实 period 列的日线值是 `1d`，而 _LABEL_TO_PERIOD 里没有它 →
    `continue` **静默**跳过。实测后果：真实文件里 5607 条日线记录，解析结果 0 条。
    下游 build_stock_import 拿不到 entry_daily，每只股都导不进来 ——
    而且不报错、不计数，是本仓最讨厌的形态。"""
    p = _write_real_format_log(tmp_path, [
        _real_row("000001.SZ", "1m"),
        _real_row("000001.SZ", "1d", first="20201223", last="20260703"),
    ])
    d = parse_export_log(p)
    assert ("000001.SZ", "1m") in d, "1m 条目丢了"
    assert ("000001.SZ", "daily") in d, "日线条目被静默丢弃（缺陷①）"
    assert d[("000001.SZ", "daily")].status == "ok"


def test_real_format_bad_status_row_does_not_kill_the_whole_log(tmp_path):
    """缺陷②：status='empty' 的行 rows=0、first_time/last_time 为空 →
    parse_qmt_datetime 抛 ValueError → **整份 log 崩掉**，5607 只好股一只都导不进来。
    设计上本来就有一道 status 门要拒这种行，但解析阶段就死了、那道门根本够不到。"""
    p = _write_real_format_log(tmp_path, [
        _real_row("000001.SZ", "1m"),
        _real_row("000001.SZ", "1d", first="20201223", last="20260703"),
        _real_row("301583.SZ", "1m", status="empty", rows="0", first="", last=""),
        _real_row("301583.SZ", "1d", status="empty", rows="0", first="", last=""),
    ])
    d = parse_export_log(p)          # ← 不得抛异常
    # 好股必须一只不少
    assert ("000001.SZ", "1m") in d and ("000001.SZ", "daily") in d


def test_unknown_period_value_raises_instead_of_silently_skipping(tmp_path):
    """认不出的 period 取值必须**报错并点名那个值**，不许静默 continue。
    静默跳过时，「整批数据没进来」与「这批数据本来就没有」在外部完全不可区分
    —— 缺陷①能潜伏三年，病根就是这个静默。"""
    p = _write_real_format_log(tmp_path, [
        _real_row("000001.SZ", "1m"),
        _real_row("000001.SZ", "5m"),          # QMT 将来新增的周期
    ])
    with pytest.raises(QmtSchemaError, match="5m"):
        parse_export_log(p)


def test_bad_status_entry_is_kept_with_null_timestamps(tmp_path):
    """`status != ok` 的行保留成条目、时间戳为 None —— 让 build_stock_import
    门 4 的 status 门真正够得着（它本来就是为这种行设计的）。
    调用方 import_csv 是直接按键取值的，跳过会变成裸 KeyError。"""
    p = _write_real_format_log(tmp_path, [
        _real_row("301583.SZ", "1m", status="empty", rows="0", first="", last=""),
        _real_row("301583.SZ", "1d", status="empty", rows="0", first="", last=""),
    ])
    d = parse_export_log(p)
    e = d[("301583.SZ", "daily")]
    assert e.status == "empty"
    assert e.first_time is None and e.last_time is None
    assert e.rows == 0


def test_ok_row_with_missing_timestamp_still_raises(tmp_path):
    """反向档：status 说 ok 却缺时间戳，那是**真的** schema 异常，必须照旧报错。
    防止「宽容坏行」退化成「什么都宽容」。"""
    p = _write_real_format_log(tmp_path, [
        _real_row("000001.SZ", "1m", status="ok", first="", last=""),
    ])
    with pytest.raises(QmtSchemaError):
        parse_export_log(p)
