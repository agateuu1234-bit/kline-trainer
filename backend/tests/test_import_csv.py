# backend/tests/test_import_csv.py
# Spec: kline_trainer_modules_v1.4.md §四 B1 + plan 2026-05-29-pr-b1-import-csv.md Task 1
# 纯函数层：全部 in-memory DataFrame，不连 PostgreSQL（写库壳由 B3/NAS 集成测试覆盖，D14）。
from __future__ import annotations

import asyncio
import copy
import dataclasses
import math
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

import import_csv
from import_csv import (
    CsvSchemaError,
    ImportBusyError,
    InvalidImportBundleError,
    LegacyImportBlockedError,
    ReimportBlockedError,
    SchemaDriftError,
    clean,
    compute_indicators,
    parse_csv,
    to_kline_records,
    validate_import_bundle,
    write_qmt_stock,
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

def test_clean_drops_nonfinite_price_rows():
    # codex 对抗评审 high：klines 价格列放宽到 DOUBLE PRECISION 后，inf 能穿过既有
    # 正数校验（inf > 0 为真）与 high>=low / high>=max(open,close) 校验（inf>=inf 为真），
    # 直接落库并污染下游（reader 拒非有限蜡烛）。
    df = _synthetic(3)
    df.loc[0, "open"] = float("inf")
    df.loc[0, "high"] = float("inf")   # 复现 codex 给出的最小复现：open/high 均为 inf
    df.loc[1, "close"] = float("-inf")
    out = clean(df)
    assert len(out) == 1
    assert out["datetime"].iloc[0] == df["datetime"].iloc[2]  # 唯一合法行仍在
    for c in ("open", "high", "low", "close"):
        assert bool(np.isfinite(out[c]).all()), f"{c} 列仍含非有限值"

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


# ---- D8a：写库前 schema fail-closed 断言（codex 对抗评审 high，spec §4.3 提前落地）----

def _dummy_kline_record() -> dict:
    return {
        "stock_code": "600519", "period": "1m", "datetime": 1,
        "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0,
        "volume": 10, "amount": None, "ma66": None,
        "boll_upper": None, "boll_mid": None, "boll_lower": None,
        "macd_diff": None, "macd_dea": None, "macd_bar": None,
    }


def _install_fake_asyncpg_for_schema_check(monkeypatch, *, data_type: str, calls: dict,
                                           lock_ok: bool = True,
                                           coverage_table_exists: bool = True,
                                           has_training_set: bool = False,
                                           coverage_row_exists: bool = False):
    """假 asyncpg 模块：pg_catalog（经 to_regclass 精确定位关系）查询返回 data_type 可控，
    execute/executemany/transaction 各自计数——用于断言 fail-closed 时一次写入都没发生。
    记录实际 query 文本到 calls["query"]，供调用方断言用的是 to_regclass 精确查询
    （而非按表名裸过滤、跨 schema 会取到无关表的 information_schema.columns）。

    task-6 扩展（write_qmt_stock 需要）：新增 fetchval（按 query 文本内容分派到
    按股 xact 锁 / stock_coverage 存在性 / training_sets 互锁三条查询，返回值受
    lock_ok/coverage_table_exists/has_training_set 三个开关控制），三个开关默认值
    维持 write_to_postgres 既有两个测试的原有行为（它们从不调用 fetchval）。

    task-7 扩展（write_to_postgres 通用路径 fail-closed 护栏需要）：新增
    coverage_row_exists 开关，控制 `SELECT 1 FROM stock_coverage WHERE stock_code=$1`
    （行存在性——与 write_qmt_stock 的 `to_regclass('stock_coverage')` 表存在性是
    两条不同查询，分开判据）。默认 False，维持既有两个 write_to_postgres 测试的
    原有行为（无 coverage 行）。"""
    import sys
    import types

    class _FakeTx:
        async def __aenter__(self):
            return None

        async def __aexit__(self, *a):
            return False

    class _FakeConn:
        async def fetch(self, query, *args):
            calls["fetch"] = calls.get("fetch", 0) + 1
            calls["query"] = query
            calls.setdefault("order", []).append(("fetch", query))
            return [{"column_name": c, "data_type": data_type}
                    for c in ("open", "high", "low", "close")]

        async def fetchval(self, query, *args):
            calls["fetchval"] = calls.get("fetchval", 0) + 1
            calls.setdefault("order", []).append(("fetchval", query))
            if "pg_try_advisory_xact_lock" in query:
                return lock_ok
            if "to_regclass('stock_coverage')" in query:
                return "stock_coverage" if coverage_table_exists else None
            if "SELECT 1 FROM stock_coverage" in query:
                return 1 if coverage_row_exists else None
            if "training_sets" in query:
                return 1 if has_training_set else None
            raise AssertionError(f"未预期的 fetchval 查询: {query}")

        async def execute(self, query, *args):
            calls["execute"] = calls.get("execute", 0) + 1
            calls.setdefault("order", []).append(("execute", query))
            return "ok"

        async def executemany(self, query, args_list):
            calls["executemany"] = calls.get("executemany", 0) + 1
            calls.setdefault("order", []).append(("executemany", query))

        def transaction(self):
            calls["transaction"] = calls.get("transaction", 0) + 1
            return _FakeTx()

        async def close(self):
            calls["closed"] = True

    fake = types.ModuleType("asyncpg")

    async def connect(dsn):
        return _FakeConn()

    fake.connect = connect
    monkeypatch.setitem(sys.modules, "asyncpg", fake)


def test_write_to_postgres_rejects_stale_decimal_schema_before_any_write(monkeypatch):
    # 目标库仍是旧 DECIMAL(10,2)（未跑 migration 0004）→ 必须 fail-closed 中止，
    # 且 execute/executemany/transaction 一次都不能被调用（否则 PG 会静默四舍五入丢精度）。
    # data_type 用 format_type(DECIMAL(10,2)) 的真实输出（"numeric(10,2)"），
    # 而非 information_schema.columns 的裸 "numeric"。
    calls: dict = {}
    _install_fake_asyncpg_for_schema_check(monkeypatch, data_type="numeric(10,2)", calls=calls)
    from import_csv import SchemaDriftError, write_to_postgres

    with pytest.raises(SchemaDriftError):
        asyncio.run(write_to_postgres("postgres://x", "600519", "贵州茅台",
                                       [_dummy_kline_record()]))
    # codex R3-F2 后断言已移进事务、且先取 ROW EXCLUSIVE 锁 → 事务与 LOCK 会发生，
    # 但**任何写入语句都不许发生**（这才是"零写入"的真正含义；只数 execute 次数
    # 会把 LOCK 误算成写入）。
    order = calls.get("order", [])
    kinds = [k for k, _ in order]
    assert "fetch" in kinds, "断言查询未发生"
    writes = [q for k, q in order
              if k == "executemany" or (k == "execute" and "LOCK TABLE" not in q)]
    assert writes == [], f"旧库情形下发生了写入: {writes}"
    # 顺序：先锁、再断言 —— 锁必须早于检查，否则检查与使用之间仍可被 ALTER 插入
    lock_i = next(i for i, (k, q) in enumerate(order)
                  if k == "execute" and "LOCK TABLE" in q)
    fetch_i = next(i for i, (k, _) in enumerate(order) if k == "fetch")
    assert lock_i < fetch_i, f"LOCK 必须早于断言查询，实际 order={kinds}"
    assert "ROW EXCLUSIVE" in order[lock_i][1], "锁级别应为 ROW EXCLUSIVE"
    assert calls.get("transaction", 0) == 1, "断言应发生在写事务内部" 
    # 断言查询锁定的是 to_regclass 精确解析出的关系，而非按表名裸过滤的
    # information_schema.columns（后者跨 schema 会取到无关 klines 表，按列名收敛
    # 时后取到的行覆盖先前的，可能让本该 fail-closed 的旧 DECIMAL 库被掩盖放行）。
    assert "to_regclass" in calls.get("query", "")
    assert "information_schema" not in calls.get("query", "")


def test_write_to_postgres_allows_double_precision_schema(monkeypatch):
    # 目标库已跑 migration 0004（double precision）→ 正常放行、照常写入。
    # format_type(float8) 的真实输出就是 "double precision"，与 information_schema 一致。
    calls: dict = {}
    _install_fake_asyncpg_for_schema_check(monkeypatch, data_type="double precision", calls=calls)
    from import_csv import write_to_postgres

    n = asyncio.run(write_to_postgres("postgres://x", "600519", "贵州茅台",
                                       [_dummy_kline_record()]))
    assert n == 1
    # 顺序契约（codex R3-F2）：LOCK TABLE → catalog 断言 → 写入。
    order = calls.get("order", [])
    lock_i = next(i for i, (k, q) in enumerate(order)
                  if k == "execute" and "LOCK TABLE" in q)
    fetch_i = next(i for i, (k, _) in enumerate(order) if k == "fetch")
    write_i = next(i for i, (k, q) in enumerate(order)
                   if k == "executemany" or (k == "execute" and "LOCK TABLE" not in q))
    assert lock_i < fetch_i < write_i, f"顺序应为 LOCK→断言→写入，实际 {[k for k, _ in order]}"
    assert "ROW EXCLUSIVE" in order[lock_i][1]
    assert calls.get("executemany", 0) == 1
    assert "to_regclass" in calls.get("query", "")


# ===== QMT Plan 3 Task7：write_to_postgres 通用路径 fail-closed 护栏 =====

def test_write_to_postgres_rejects_records_stock_code_mismatch(monkeypatch):
    """records 里的 stock_code 与 stock_code 参数不一致 → ValueError，取锁前拒绝
    （纯内存校验，asyncpg.connect 都不该被调用——用一个 connect 即报错的假 asyncpg
    module 证明真的没有发生任何 DB 往返）。"""
    import sys
    import types

    from import_csv import write_to_postgres

    fake = types.ModuleType("asyncpg")

    async def _connect_should_not_be_called(dsn):
        raise AssertionError("身份校验应在 asyncpg.connect 之前就拒绝")

    fake.connect = _connect_should_not_be_called
    monkeypatch.setitem(sys.modules, "asyncpg", fake)

    bad_record = dict(_dummy_kline_record())
    bad_record["stock_code"] = "600519"
    with pytest.raises(ValueError):
        asyncio.run(write_to_postgres("postgres://x", "000001", "平安", [bad_record]))


def test_write_to_postgres_rejects_qmt_managed_stock(monkeypatch):
    """该股已有 stock_coverage 行（已被 QMT 接管）→ LegacyImportBlockedError，
    零 INSERT（连 LOCK TABLE 都不该发生——coverage 门在 LOCK TABLE 之前）。"""
    calls: dict = {}
    _install_fake_asyncpg_for_schema_check(monkeypatch, data_type="double precision",
                                           calls=calls, coverage_row_exists=True)
    from import_csv import write_to_postgres

    with pytest.raises(LegacyImportBlockedError):
        asyncio.run(write_to_postgres("postgres://x", "600519", "贵州茅台",
                                       [_dummy_kline_record()]))
    order = calls.get("order", [])
    assert any(k == "fetchval" and "SELECT 1 FROM stock_coverage" in q for k, q in order), \
        "coverage 行存在性查询应已发生"
    assert not any(k == "execute" for k, q in order), "coverage 已占用时不该到达任何 execute（含 LOCK TABLE）"
    assert calls.get("executemany", 0) == 0


def test_write_to_postgres_lock_busy(monkeypatch):
    """按股 xact 锁被 B2 占用 → ImportBusyError，零 INSERT。"""
    calls: dict = {}
    _install_fake_asyncpg_for_schema_check(monkeypatch, data_type="double precision",
                                           calls=calls, lock_ok=False)
    from import_csv import write_to_postgres

    with pytest.raises(ImportBusyError):
        asyncio.run(write_to_postgres("postgres://x", "600519", "贵州茅台",
                                       [_dummy_kline_record()]))
    order = calls.get("order", [])
    assert not any(k == "execute" for k, q in order), "锁忙时不该到达任何 execute（含 LOCK TABLE）"
    assert calls.get("executemany", 0) == 0


# ===== QMT Plan 3 Task6：validate_import_bundle（P3-D12，全 if/raise）=====

from qmt_ingest import ExportLogEntry, build_stock_import  # noqa: E402
from qmt_normalize import QmtSource  # noqa: E402
from qmt_normalize import trading_date as _qmt_trading_date  # noqa: E402
from tests._qmt_fixtures import gen_valid_sources  # noqa: E402


def _qmt_entry(code, period, df):
    return ExportLogEntry(code=code, period=period, status="ok", rows=len(df),
                          first_time=int(df.iloc[0]["datetime"]),
                          last_time=int(df.iloc[-1]["datetime"]), source=code)


# build_stock_import 走全套门 + 出货预检，构造一个 ~6万行 bundle 约数秒。
# module-scope 只 build 一次；各测试拿 deepcopy（独立可变、mutation 不跨测泄漏），
# 把该文件从 >2min 降回秒级（原 function-scope 每测重建 ~21 次是唯一慢源）。
@pytest.fixture(scope="module")
def _valid_bundle_master():
    s1, sd, e1, ed = gen_valid_sources("000001.SZ")
    return build_stock_import(s1, sd, stock_code="000001.SZ", stock_name="平安",
                              entry_1m=e1, entry_daily=ed)


@pytest.fixture
def valid_bundle(_valid_bundle_master):
    return copy.deepcopy(_valid_bundle_master)


@pytest.fixture(scope="module")
def _valid_bundle_with_boundary_drop_master():
    """首个 1m dense 交易日残缺（100/241 根）→ 落 dropped_dates；因它是窗口最早一日，
    complete[0] 顺延到下一天 → 该 dropped 日期落在 [start_date,end_date] 之外——
    覆盖率"端点分区外部分残缺"合法场景，validate_import_bundle 必须放行（不拒）。"""
    s1, sd, e1, ed = gen_valid_sources("000001.SZ")
    first_date = min(_qmt_trading_date(e) for e in s1.df["datetime"])
    is_first = s1.df["datetime"].map(lambda e: _qmt_trading_date(e) == first_date)
    truncated = s1.df[is_first].iloc[:100]
    m1 = pd.concat([truncated, s1.df[~is_first]]).sort_values("datetime").reset_index(drop=True)
    s1b = QmtSource(s1.code, s1.period, m1)
    e1b = _qmt_entry("000001.SZ", "1m", m1)
    return build_stock_import(s1b, sd, stock_code="000001.SZ", stock_name="平安",
                              entry_1m=e1b, entry_daily=ed)


@pytest.fixture
def valid_bundle_with_boundary_drop(_valid_bundle_with_boundary_drop_master):
    return copy.deepcopy(_valid_bundle_with_boundary_drop_master)


def test_bundle_valid_passes(valid_bundle):
    validate_import_bundle(valid_bundle, "000001.SZ")  # 不抛


def test_bundle_missing_period_rejects(valid_bundle):
    recs = dict(valid_bundle.records)
    del recs["3m"]
    bad = dataclasses.replace(valid_bundle, records=recs)
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(bad, "000001.SZ")


def test_bundle_extra_period_rejects(valid_bundle):
    recs = dict(valid_bundle.records)
    recs["1m"] = recs["3m"]   # 六周期之外多出一个
    bad = dataclasses.replace(valid_bundle, records=recs)
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(bad, "000001.SZ")


def test_bundle_unknown_period_key_rejects(valid_bundle):
    """键集合含一个非 QMT 六周期名——同一条门（period 集合 ≠ 六周期）拦住。"""
    recs = dict(valid_bundle.records)
    del recs["3m"]
    recs["yearly"] = valid_bundle.records["3m"]
    bad = dataclasses.replace(valid_bundle, records=recs)
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(bad, "000001.SZ")


def test_bundle_empty_period_list_rejects(valid_bundle):
    recs = dict(valid_bundle.records)
    recs["3m"] = []
    bad = dataclasses.replace(valid_bundle, records=recs)
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(bad, "000001.SZ")


def test_bundle_period_mismatch_rejects(valid_bundle):
    valid_bundle.records["3m"][0]["period"] = "1m"
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(valid_bundle, "000001.SZ")


def test_bundle_cross_stock_rejects(valid_bundle):
    valid_bundle.records["3m"][0]["stock_code"] = "000002.SZ"
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(valid_bundle, "000001.SZ")


def test_bundle_missing_field_rejects(valid_bundle):
    valid_bundle.records["daily"][0]["close"] = None
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(valid_bundle, "000001.SZ")


def test_bundle_amount_inf_rejects(valid_bundle):
    valid_bundle.records["3m"][0]["amount"] = float("inf")
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(valid_bundle, "000001.SZ")


def test_bundle_volume_negative_rejects(valid_bundle):
    valid_bundle.records["3m"][0]["volume"] = -5
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(valid_bundle, "000001.SZ")


def test_bundle_volume_fractional_rejects(valid_bundle):
    valid_bundle.records["3m"][0]["volume"] = 10.5
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(valid_bundle, "000001.SZ")


def test_bundle_duplicate_datetime_rejects(valid_bundle):
    valid_bundle.records["3m"][1]["datetime"] = valid_bundle.records["3m"][0]["datetime"]
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(valid_bundle, "000001.SZ")


def test_bundle_coverage_start_after_end_rejects(valid_bundle):
    bad_cov = dataclasses.replace(valid_bundle.coverage,
                                  start_date=valid_bundle.coverage.end_date,
                                  end_date=valid_bundle.coverage.start_date)
    bad = dataclasses.replace(valid_bundle, coverage=bad_cov)
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(bad, "000001.SZ")


def test_bundle_dense_day_count_mismatch_rejects(valid_bundle):
    bad_cov = dataclasses.replace(valid_bundle.coverage,
                                  dense_day_count=valid_bundle.coverage.dense_day_count + 1)
    bad = dataclasses.replace(valid_bundle, coverage=bad_cov)
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(bad, "000001.SZ")


def test_bundle_endpoint_not_in_daily_set_rejects(valid_bundle):
    import datetime as _dtm
    bad_cov = dataclasses.replace(
        valid_bundle.coverage,
        end_date=valid_bundle.coverage.end_date + _dtm.timedelta(days=3650))
    bad = dataclasses.replace(valid_bundle, coverage=bad_cov)
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(bad, "000001.SZ")


def test_bundle_dropped_non_date_rejects(valid_bundle):
    bad_cov = dataclasses.replace(
        valid_bundle.coverage,
        dropped_dates=list(valid_bundle.coverage.dropped_dates) + ["not-a-date"])
    bad = dataclasses.replace(valid_bundle, coverage=bad_cov)
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(bad, "000001.SZ")


def test_bundle_dropped_outside_span_allowed(valid_bundle_with_boundary_drop):
    b = valid_bundle_with_boundary_drop
    assert len(b.coverage.dropped_dates) == 1
    assert b.coverage.dropped_dates[0] < b.coverage.start_date   # 确认真落在区间外
    validate_import_bundle(b, "000001.SZ")   # 不抛——合法的端点分区外部分残缺


# ===== QMT Plan 3 Task6：write_qmt_stock（替换语义 + 按股 xact 锁 + 重导入互锁）=====

@pytest.fixture
def fake_conn(monkeypatch):
    calls: dict = {}
    _install_fake_asyncpg_for_schema_check(monkeypatch, data_type="double precision", calls=calls)
    return calls


@pytest.fixture
def fake_conn_has_training_set(monkeypatch):
    calls: dict = {}
    _install_fake_asyncpg_for_schema_check(monkeypatch, data_type="double precision", calls=calls,
                                           has_training_set=True)
    return calls


@pytest.fixture
def fake_conn_lock_busy(monkeypatch):
    calls: dict = {}
    _install_fake_asyncpg_for_schema_check(monkeypatch, data_type="double precision", calls=calls,
                                           lock_ok=False)
    return calls


@pytest.fixture
def fake_conn_no_coverage_table(monkeypatch):
    calls: dict = {}
    _install_fake_asyncpg_for_schema_check(monkeypatch, data_type="double precision", calls=calls,
                                           coverage_table_exists=False)
    return calls


def _order_index(order, pred):
    return next(i for i, (k, q) in enumerate(order) if pred(k, q))


def test_write_qmt_stock_order_and_atomicity(monkeypatch, fake_conn, valid_bundle):
    calls = fake_conn
    real_validate = import_csv.validate_import_bundle

    def _validate_and_record(bundle, stock_code):
        calls.setdefault("order", []).append(("validate", "validate_import_bundle"))
        return real_validate(bundle, stock_code)

    monkeypatch.setattr(import_csv, "validate_import_bundle", _validate_and_record)

    counts = asyncio.run(write_qmt_stock("postgres://x", "000001.SZ", "平安", valid_bundle))

    assert counts == {p: len(valid_bundle.records[p]) for p in valid_bundle.records}
    order = calls["order"]
    assert order[0][0] == "validate"   # 取连接前先校验，零 DB 往返
    i_validate = _order_index(order, lambda k, q: k == "validate")
    i_lock = _order_index(order, lambda k, q: k == "fetchval" and "pg_try_advisory_xact_lock" in q)
    i_cov_exists = _order_index(order, lambda k, q: k == "fetchval" and "to_regclass('stock_coverage')" in q)
    i_lock_table = _order_index(order, lambda k, q: k == "execute" and "LOCK TABLE" in q)
    i_assert_double = _order_index(order, lambda k, q: k == "fetch")
    i_interlock = _order_index(order, lambda k, q: k == "fetchval" and "training_sets" in q)
    i_stocks = _order_index(order, lambda k, q: k == "execute" and "INSERT INTO stocks" in q)
    i_delete = _order_index(order, lambda k, q: k == "execute" and "DELETE FROM klines" in q)
    i_first_insert = _order_index(order, lambda k, q: k == "executemany")
    i_last_insert = max(i for i, (k, q) in enumerate(order) if k == "executemany")
    i_coverage_upsert = _order_index(order, lambda k, q: k == "execute" and "INSERT INTO stock_coverage" in q)

    assert (i_validate < i_lock < i_cov_exists < i_lock_table < i_assert_double
            < i_interlock < i_stocks < i_delete < i_first_insert)
    assert i_last_insert < i_coverage_upsert
    assert calls.get("executemany", 0) == 6
    assert calls.get("transaction", 0) == 1   # 所有写在同一 transaction 内


def test_write_qmt_stock_reimport_blocked(fake_conn_has_training_set, valid_bundle):
    calls = fake_conn_has_training_set
    with pytest.raises(ReimportBlockedError):
        asyncio.run(write_qmt_stock("postgres://x", "000001.SZ", "平安", valid_bundle))
    order = calls.get("order", [])
    assert any(k == "fetchval" and "training_sets" in q for k, q in order), "互锁查询应已发生"
    assert not any(k == "execute" and "DELETE FROM klines" in q for k, q in order), "零写入：DELETE 不应发生"
    assert calls.get("executemany", 0) == 0, "零写入：INSERT 不应发生"


def test_write_qmt_stock_lock_busy(fake_conn_lock_busy, valid_bundle):
    calls = fake_conn_lock_busy
    with pytest.raises(ImportBusyError):
        asyncio.run(write_qmt_stock("postgres://x", "000001.SZ", "平安", valid_bundle))
    order = calls.get("order", [])
    assert not any(k == "execute" for k, q in order), "锁忙时不该到达任何 execute（含 LOCK TABLE）"
    assert calls.get("executemany", 0) == 0


def test_write_qmt_stock_missing_coverage_table_raises_schema_drift(fake_conn_no_coverage_table, valid_bundle):
    calls = fake_conn_no_coverage_table
    with pytest.raises(SchemaDriftError):
        asyncio.run(write_qmt_stock("postgres://x", "000001.SZ", "平安", valid_bundle))
    order = calls.get("order", [])
    assert not any(k == "execute" and "LOCK TABLE" in q for k, q in order), "stock_coverage 缺表须早于 LOCK TABLE 拦下"
    assert not any(k == "execute" and "DELETE FROM klines" in q for k, q in order)
    assert calls.get("executemany", 0) == 0
