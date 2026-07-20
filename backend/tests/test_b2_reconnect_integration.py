# backend/tests/test_b2_reconnect_integration.py
# Plan 2b Task 6：B2 生产装配重接的端到端集成测。
#
# 「假」的只有 asyncpg conn（沿用 test_scheduler.py 的 _FakeConn 约定，本仓零真-PG
# 测试基建，且 backend-tests.yml 对任何 skipped>0 即 fail → 不能用"没 docker 就 skip"）。
# 被测的是**真实生产函数链**：generate_one_training_set → build_training_windows
# （D2 dense 门 + D6 + D9 per-day 硬门 + bounded retry）→ assemble_from_windows →
# 真 SQLite → 真 zip → 真 CRC32 → _register_training_set。
#
# 本文件守的核心断言 = Plan 2 的验收线：真实 sweep 产出 ≥1 registered training set。
from __future__ import annotations

import asyncio
import datetime as dt
import functools
import json
import random
import sqlite3
import sys
import types
import zipfile
from zoneinfo import ZoneInfo

import pandas as pd
import pytest

from generate_training_sets import (
    GenerateSkipException,
    PERIODS,
    generate_batch,
    generate_one_training_set,
)
from qmt_normalize import trading_date        # PF2-R7-F3：dense_day_count 测的过滤要用

SH = ZoneInfo("Asia/Shanghai")


def _trading_days(start: dt.date, n: int) -> list:
    """n 个工作日（周一至周五）。本测不建真节假日历——D9 门只关心
    "在 trading_dates 里的日子桶数是否精确"，工作日集合足以驱动全部分支。"""
    out, d = [], start
    while len(out) < n:
        if d.weekday() < 5:
            out.append(d)
        d += dt.timedelta(days=1)
    return out


def _midnight(d: dt.date) -> int:
    return int(dt.datetime(d.year, d.month, d.day, 0, 0, 0, tzinfo=SH).timestamp())


def _intraday_epochs(d: dt.date, n: int) -> list:
    """某交易日 n 根盘中 bar 的 epoch（从 09:33 起每 3 分钟一根，仅作占位刻度）。"""
    base = dt.datetime(d.year, d.month, d.day, 9, 33, 0, tzinfo=SH)
    return [int((base + dt.timedelta(minutes=3 * i)).timestamp()) for i in range(n)]


def _ohlcv(dts: list) -> pd.DataFrame:
    """给定 datetime 列表 → 合法单调 OHLCV + 指标列（值本身不参与断言）。"""
    rows = []
    for i, e in enumerate(dts):
        c = 10.0 + i * 0.01
        rows.append({"datetime": int(e), "open": c, "high": c + 0.05,
                     "low": c - 0.05, "close": c, "volume": 1000 + i,
                     "amount": (1000 + i) * c, "ma66": c, "boll_upper": c + 0.1,
                     "boll_mid": c, "boll_lower": c - 0.1, "macd_diff": 0.01,
                     "macd_dea": 0.01, "macd_bar": 0.0})
    return pd.DataFrame(rows).sort_values("datetime").reset_index(drop=True)


_INTRADAY_N = {"3m": 80, "15m": 16, "60m": 4}


@functools.lru_cache(maxsize=4)
def _cached_fixture(start: dt.date, n_days: int):
    """**性能**（dry-run 实测）：fixture 每周期约 8 万行，逐测重建会让本文件跑 ~59s、
    整个后端套件从 3.5s 涨到 63s。输入确定 → 缓存。返回**浅拷贝**：个别测试会
    `bars["daily"] = ...` 重绑定某周期（不原地改 DataFrame），浅拷贝即可隔离缓存。"""
    return _build_pg_fixture(_trading_days(start, n_days))


def _pg_fixture(start: dt.date, n_days: int) -> dict:
    return dict(_cached_fixture(start, n_days))


def _build_pg_fixture(days: list) -> dict:
    """造一份"PG 里该股全部 klines"：日/周/月标组内首交易日午夜（OPEN 语义，R3-F1），
    盘中每交易日精确 80/16/4 根（满足 D9 per-day 硬门）。"""
    bars = {}
    bars["daily"] = _ohlcv([_midnight(d) for d in days])
    seen = {}
    for d in days:
        seen.setdefault((d.isocalendar()[0], d.isocalendar()[1]), d)
    bars["weekly"] = _ohlcv([_midnight(d) for d in sorted(seen.values())])
    seen_m = {}
    for d in days:
        seen_m.setdefault((d.year, d.month), d)
    bars["monthly"] = _ohlcv([_midnight(d) for d in sorted(seen_m.values())])
    for p, n in _INTRADAY_N.items():
        eps = []
        for d in days:
            eps.extend(_intraday_epochs(d, n))
        bars[p] = _ohlcv(eps)
    return bars


class _FakeConn:
    """最小 asyncpg conn 替身：按 SQL 子串分派。沿用 test_scheduler.py 的假件约定。

    只实现被测路径真正用到的四类查询 + 一个 INSERT；任何未预期的 SQL 都
    **主动抛错**（而不是返回空），否则生产代码改了查询、测试会静默变成 vacuous。
    """

    def __init__(self, stock_code: str, bars: dict, coverage: dict | None,
                 *, steal_first_insert: bool = False):
        self.stock_code = stock_code
        self.bars = bars
        self.coverage = coverage
        self.registered: list = []      # 模拟 training_sets 表
        self._next_id = 1
        # 模拟"并发 sweep 在预检之后抢先登记同一起点"：首次 INSERT 撞 ON CONFLICT
        self.steal_first_insert = steal_first_insert
        self._rows_cache: dict = {}     # 见 fetch()：8 万行 to_dict 的结果缓存

    async def fetch(self, query: str, *args):
        if "FROM klines" in query:
            _, period = args
            df = self.bars.get(period)
            if df is None or df.empty:
                return []
            # **性能**（dry-run 实测）：每周期 8 万行，逐次 to_dict 是主要耗时来源 → 按 id 缓存
            key = id(df)
            hit = self._rows_cache.get(key)
            if hit is None:
                hit = df.to_dict("records")
                self._rows_cache[key] = hit
            return hit
        if "SELECT start_datetime FROM training_sets" in query:
            return [{"start_datetime": r["start_datetime"]} for r in self.registered]
        if "SELECT code FROM stocks" in query:
            return [{"code": self.stock_code}]
        raise AssertionError(f"_FakeConn 收到未预期的 fetch: {query}")

    async def fetchrow(self, query: str, *args):
        if "FROM stock_coverage" in query:
            return self.coverage
        if "FROM training_sets WHERE stock_code" in query:
            code, start = args
            hit = any(r["stock_code"] == code and r["start_datetime"] == start
                      for r in self.registered)
            return {"exists": 1} if hit else None
        raise AssertionError(f"_FakeConn 收到未预期的 fetchrow: {query}")

    async def fetchval(self, query: str, *args):
        if "INSERT INTO training_sets" in query:
            assert "ON CONFLICT" in query, (
                "登记 SQL 必须用 ON CONFLICT DO NOTHING 原子处理 uq_stock_start"
                "（codex PF2-R2-F2）")
            code, start = args[0], args[2]
            if self.steal_first_insert:
                self.steal_first_insert = False
                return None                      # 模拟 ON CONFLICT DO NOTHING
            if any(r["stock_code"] == code and r["start_datetime"] == start
                   for r in self.registered):
                return None                      # 真冲突
            row = {"id": self._next_id, "stock_code": code, "stock_name": args[1],
                   "start_datetime": start, "end_datetime": args[3],
                   "schema_version": args[4], "file_path": args[5],
                   "content_hash": args[6]}
            self.registered.append(row)
            self._next_id += 1
            return row["id"]
        raise AssertionError(f"_FakeConn 收到未预期的 fetchval: {query}")


def _coverage_row(days: list, dropped: list | None = None) -> dict:
    dropped = dropped or []
    return {"dense_1m_start_date": days[0], "dense_1m_end_date": days[-1],
            "dropped_1m_dates": json.dumps([d.isoformat() for d in dropped]),
            # 权威天数必须与 B2 重建出的 dense_dates 一致（PF2-R6-F1 交叉校验）
            "dense_day_count": len([d for d in days if d not in set(dropped)])}


def _fixture_conn(dropped: list | None = None, n_days: int = 1000):
    # n_days 必须 ≥ ~820 个工作日：eligible_start_indices 要求月边界数 ≥ 31+months(8)=39，
    # 1000 个工作日 ≈ 46 个月边界 → 8 个候选。500 个工作日只有 ~23 个月边界，
    # 会直接抛「月边界仅 23，不足 39」，全部集成测 FAIL。
    days = _trading_days(dt.date(2022, 1, 3), n_days)
    return _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), n_days),
                     _coverage_row(days, dropped)), days


# ===== 核心验收：真实 sweep 产出 ≥1 registered training set =====

def test_real_sweep_registers_at_least_one_training_set(tmp_path):
    """Plan 2 的核心断言。Plan 1 停用期间本测必然失败（NotImplementedError）。"""
    conn, _ = _fixture_conn()
    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert len(conn.registered) >= 1, "sweep 未登记任何 training set"
    row = conn.registered[0]
    assert row["stock_code"] == "000001.SZ"
    assert row["file_path"] == str(gts.path)
    assert row["content_hash"] == gts.content_hash


def test_registered_zip_exists_and_hash_matches(tmp_path):
    """登记的 file_path 必须真能打开（模拟 B3 按路径下载），hash 对得上。"""
    from generate_training_sets import crc32_hex
    conn, _ = _fixture_conn()
    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert gts.path.exists()
    assert crc32_hex(gts.path.read_bytes()) == gts.content_hash
    with zipfile.ZipFile(gts.path) as z:
        names = z.namelist()
    assert names == [f"000001.SZ_{gts.start_datetime}.db"]


def test_registered_content_hash_is_8_lowercase_hex(tmp_path):
    """schema.sql 有 CHECK(content_hash ~ '^[0-9a-f]{8}$')，写坏会被 PG 拒。"""
    import re
    conn, _ = _fixture_conn()
    asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path, random.Random(7)))
    assert re.fullmatch(r"[0-9a-f]{8}", conn.registered[0]["content_hash"])


def test_intermediate_db_removed_only_zip_kept(tmp_path):
    """中间 .db 必须删掉，只留登记的 .zip（否则输出目录翻倍、且 .db 未被登记）。"""
    conn, _ = _fixture_conn()
    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert gts.path.exists()
    # 中间 .db 建在临时目录、随 with 块清掉，最终目录从来不该出现它
    assert not gts.path.with_suffix(".db").exists()


def test_training_set_sqlite_has_all_six_periods(tmp_path):
    """产物内容真的可用：六周期齐全 + 3m 有 global_index。"""
    conn, _ = _fixture_conn()
    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    with zipfile.ZipFile(gts.path) as z:
        z.extractall(tmp_path / "x")
    db = sqlite3.connect(str(tmp_path / "x" / f"000001.SZ_{gts.start_datetime}.db"))
    try:
        periods = {r[0] for r in db.execute("SELECT DISTINCT period FROM klines")}
        n_gi = db.execute(
            "SELECT COUNT(*) FROM klines WHERE period='3m' AND global_index IS NOT NULL"
        ).fetchone()[0]
    finally:
        db.close()
    assert periods == set(PERIODS)
    assert n_gi > 0, "3m 应有 global_index"


# ===== end_datetime 正确性（codex whole-branch I2）=====

def test_end_datetime_matches_eight_month_boundary(tmp_path):
    """`generate_one_training_set` 里 `compute_after_end(month_boundaries, idx)` 依赖
    **两个各自独立的 `months=8` 默认值**保持一致——`build_training_windows` 的默认
    （决定窗口范围）与 `compute_after_end` 自己的默认（决定 meta.end_datetime 标注）。
    没有任何东西把它俩钉在一起：任何人给 build_training_windows 传 months= 就会
    静默产出一个「声明的结束时间与实际数据不符」的训练组。

    直接用裸下标运算算期望值（不经过 compute_after_end 本身，避免测试只是在
    验证 compute_after_end 内部自洽），才能抓住"生产调用点传的 months 与窗口
    选择用的 months 不一致"这类回归。"""
    from qmt_resample import period_boundaries
    conn, _ = _fixture_conn()
    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    month_boundaries = period_boundaries(conn.bars["daily"], "monthly")
    idx = month_boundaries.index(gts.start_datetime)
    expected_end = int(month_boundaries[idx + 8]) - 1
    assert gts.end_datetime == expected_end


# ===== dropped_1m_dates 排除生效（codex whole-branch I3；D2 dense 门存在的全部意义）=====

def test_dropped_1m_date_never_spanned_by_selected_window(tmp_path):
    """`_fetch_dense_coverage` 返回的 `dropped_1m_dates` 必须真的把该日从 dense_dates
    里减掉——此前 `_fixture_conn(dropped=...)` / `_coverage_row(days, dropped)` 虽然
    都收 dropped 参数，但全仓 13 个调用点无一传值，死参数伪装成覆盖。

    此前版本用固定下标 `days[500]` 作 dropped 日，声称它"落在候选窗口范围中段"——
    但这句话与 seed(7) 实际选中的窗口对不上（早一年多），断言 `assert not (...)`
    从未有机会失败（复审实测证实：即使 D2 门成员检查被禁用、或排除逻辑保基数
    换错日期，测试依旧全绿）。

    这里改为**动态推导** dropped 日，而非硬编码下标：先直接调纯函数
    `build_training_windows`（dense_dates 传全量交易日）算出"dense_dates 的
    `- dropped` 排除逻辑是空操作"时 seed(7) 会自然选中的窗口（baseline）。
    刻意**不**经 `generate_one_training_set`，只为算这条前提——它自带
    `dense_day_count` 交叉校验（codex PF2-R6-F1，守另一条不相关的不变量），
    若拿它来跑 baseline，baseline 用的是"未传 dropped"的覆盖行、交叉校验按
    "无 drop"算权威天数，一旦生产 dense_dates 计算本身被改坏（如本测试要抓的
    M-b 那类"基数不变但减错日期"的坏改法），baseline 这条腿会先撞交叉校验掉进
    错误分支，而不是让下面真正要守的核心断言去接住它。

    取 baseline 窗口中段一个交易日作 dropped 日：它必然落在"若不排除会被跨越"
    的窗口内，且今后 fixture / seed / 候选逻辑变化时会跟着 baseline 一起重新
    对齐，不会像旧写法那样静默退化成死断言。随后**显式断言这个重叠前提本身
    成立**（若不成立，直接报错而不是继续绿着），再验证真正传入 dropped 后
    （这次真的经 `generate_one_training_set` 全链路，含 `_fetch_dense_coverage`
    + dense_dates 计算 + `eligible_start_indices` 成员检查），被选中的窗口确实
    不再跨越它。"""
    from generate_training_sets import build_training_windows, compute_after_end, PERIOD_BEFORE_CAP
    from qmt_resample import period_boundaries

    days = _trading_days(dt.date(2022, 1, 3), 1000)
    bars = _pg_fixture(dt.date(2022, 1, 3), 1000)
    daily = bars["daily"]
    trading_dates = sorted({trading_date(int(e)) for e in daily["datetime"]})
    month_boundaries = period_boundaries(daily, "monthly")

    # 前提构造：dense_dates 传全量交易日 = 排除逻辑形同虚设时会选中的窗口。
    baseline_start, _ = build_training_windows(
        bars, month_boundaries, random.Random(7),
        dense_dates=set(trading_dates), trading_dates=trading_dates,
        before_caps=PERIOD_BEFORE_CAP)
    baseline_idx = month_boundaries.index(baseline_start)
    baseline_end = compute_after_end(month_boundaries, baseline_idx)

    window_days = [d for d in days if baseline_start <= _midnight(d) <= baseline_end]
    assert len(window_days) >= 10, (
        f"baseline 窗口只覆盖 {len(window_days)} 个交易日，中段取点不再具代表性——"
        "fixture / gate 参数可能发生了大改动，请重新评估本测试的构造前提")
    dropped_date = window_days[len(window_days) // 2]
    dropped_epoch = _midnight(dropped_date)

    # 显式前提：若不排除该日，seed(7) 会选中一个跨越它的窗口——下面的核心断言
    # 由此才真的有机会失败。这条前提不成立时必须报错，而不是让测试继续静默绿着。
    assert baseline_start <= dropped_epoch <= baseline_end, (
        f"前提不成立：dropped 日 {dropped_date} 未落在 baseline 窗口 "
        f"[{baseline_start}, {baseline_end}] 内——本测试对 D2 "
        "dense 门排除逻辑已失去鉴别力（vacuous），需要重新选点，而不是让下面的核心"
        "断言继续静默通过"
    )

    conn, _ = _fixture_conn(dropped=[dropped_date])
    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert not (gts.start_datetime <= dropped_epoch <= gts.end_datetime), (
        f"选中窗口 [{gts.start_datetime}, {gts.end_datetime}] 跨越了被 drop 的日期 "
        f"{dropped_date}（dense_dates 未真正排除 dropped 日）"
    )


# ===== fail-closed：门控真的在守 =====

def test_missing_coverage_artifact_skips_fail_closed(tmp_path):
    """D11：无 stock_coverage 行 → 无权威 dense 判定 → 必须 skip，
    **不得**退化成"从 klines 反推"或"不门控直接产"。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), None)
    with pytest.raises(GenerateSkipException, match="stock_coverage"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []
    assert list(tmp_path.iterdir()) == [], "fail-closed 路径不得留下任何产物（含暂存目录）"


def test_uq_stock_start_not_reused(tmp_path):
    """同股连生两组：起点必须不同（exclude_starts 生效），且两组都登记成功。"""
    conn, _ = _fixture_conn()
    a = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path, random.Random(7)))
    b = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path, random.Random(7)))
    assert a.start_datetime != b.start_datetime
    assert len(conn.registered) == 2


# ===== 坏覆盖行必须降级成 skip、不得中止整轮 sweep（codex PF2-R2-F1）=====

@pytest.mark.parametrize("bad_dropped, label", [
    ("{not json", "非法 JSON"),
    ('{"a": 1}', "JSON 对象而非数组"),
    ('["2024-13-99"]', "非法日期"),
    ("[123]", "数组元素非字符串"),
])
def test_malformed_coverage_row_skips_not_crashes(tmp_path, bad_dropped, label):
    """坏行必须抛 GenerateSkipException（可被 generate_batch 捕获），
    **不得**抛 JSONDecodeError/ValueError/TypeError——后者会穿出 sweep 循环、
    在 B4 常驻进程里一路冒泡。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    cov = {"dense_1m_start_date": days[0], "dense_1m_end_date": days[-1],
           "dropped_1m_dates": bad_dropped, "dense_day_count": len(days)}
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), cov)
    with pytest.raises(GenerateSkipException, match="dropped_1m_dates"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []
    assert list(tmp_path.iterdir()) == [], "坏行路径不得留下产物"


def test_dense_day_count_mismatch_skips(tmp_path):
    """codex PF2-R6-F1：带内某交易日的 daily 行缺失时，那天会同时从 dense_dates 与
    D9 span 里消失——两道门都瞎。dense_day_count 交叉校验是唯一能抓到它的东西。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    bars = _pg_fixture(dt.date(2022, 1, 3), 1000)
    missing = days[len(days) // 2]
    # 从 daily 里抠掉带内一个交易日（模拟 B1 半途导入 / 行丢失）
    bars["daily"] = bars["daily"][
        bars["daily"]["datetime"].map(lambda e: trading_date(int(e))) != missing
    ].reset_index(drop=True)
    cov = {"dense_1m_start_date": days[0], "dense_1m_end_date": days[-1],
           "dropped_1m_dates": "[]", "dense_day_count": len(days)}   # 权威计数仍是全量
    conn = _FakeConn("000001.SZ", bars, cov)
    with pytest.raises(GenerateSkipException, match="dense 日历不一致"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []


def test_reversed_coverage_band_skips(tmp_path):
    """覆盖带反向（start > end）→ 可诊断 skip（DB 有 CHECK，但历史行/别的库可能没有）。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    cov = {"dense_1m_start_date": days[-1], "dense_1m_end_date": days[0],
           "dropped_1m_dates": "[]", "dense_day_count": len(days)}
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), cov)
    with pytest.raises(GenerateSkipException, match="反向"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))


def test_malformed_coverage_does_not_abort_batch(tmp_path, capsys):
    """整轮 sweep 级证据：坏行只让该股 skip，generate_batch 正常返回（非抛异常）。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    cov = {"dense_1m_start_date": days[0], "dense_1m_end_date": days[-1],
           "dropped_1m_dates": "{not json", "dense_day_count": len(days)}
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), cov)
    out = asyncio.run(generate_batch(conn, 2, tmp_path, random.Random(3)))
    assert out == []
    assert "dropped_1m_dates" in capsys.readouterr().out


# ===== uq_stock_start TOCTOU 原子处理（codex PF2-R2-F2）=====

def test_registration_conflict_skips_without_crashing(tmp_path):
    """`ON CONFLICT DO NOTHING` 作廉价保险：唯一冲突返回 None → 干净 skip，
    而不是 UniqueViolationError 穿出 generate_batch 中止整轮 sweep。

    注：**生产上并发不可能**（scheduler_main D14 `pg_try_advisory_lock` 集群级单例
    + APScheduler max_instances=1）。本保险只覆盖「运维手工跑 B2 CLI 时调度器也在跑」
    这个**不受支持**的操作场景（见文末 PF2-R5 接受残留）。"""
    conn, _ = _fixture_conn()
    conn.steal_first_insert = True
    with pytest.raises(GenerateSkipException, match="已登记"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []


def test_stale_db_from_crash_does_not_block_regeneration(tmp_path):
    """codex PF2-R5-F1：崩溃可能在最终目录留下 `{code}_{start}.db`。
    `_TRAINING_SET_DDL` 是裸 `CREATE TABLE`，若装配仍往那个路径写，就会撞
    `table meta already exists`（sqlite3.OperationalError，**不是**
    GenerateSkipException）→ 中止整轮 sweep。中间 .db 改建在临时目录后，
    最终目录里的陈旧 .db 只是无害垃圾，不得影响生成。"""
    conn, _ = _fixture_conn()
    probe = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                  random.Random(7)))
    stale_db = tmp_path / f"000001.SZ_{probe.start_datetime}.db"
    stale_db.write_bytes(b"not a sqlite file at all")     # 陈旧残渣
    conn.registered.clear()

    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert gts.start_datetime == probe.start_datetime
    assert len(conn.registered) == 1


def test_orphan_zip_from_crash_is_self_healing(tmp_path):
    """崩溃窗口（zip 已落盘、登记前进程死）= 孤儿 zip + 无数据库行 → **自愈**。

    没有行引用它、`exclude_starts` 也不含该起点 → 下次 sweep 可重选同一起点、
    覆盖孤儿并登记成功。这正是「先写文件后登记」优于「先登记后发布」的地方：
    后者会留下 uq_stock_start 被占、B3 反复预定却 404 的**永久卡死行**。"""
    from generate_training_sets import crc32_hex
    conn, _ = _fixture_conn()
    probe = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                  random.Random(7)))
    orphan = probe.path
    conn.registered.clear()                        # 模拟：文件落盘了，登记那步没发生
    orphan.write_bytes(b"stale partial content")   # 且内容是坏的/半截的

    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert gts.start_datetime == probe.start_datetime, "该起点被永久占用了（未自愈）"
    assert gts.path.read_bytes() != b"stale partial content", "坏孤儿未被覆盖"
    assert crc32_hex(gts.path.read_bytes()) == gts.content_hash
    assert len(conn.registered) == 1


def test_generate_batch_surfaces_first_skip_reason(tmp_path, capsys):
    """诚实义务 1（codex PF2-R1-F1）：`stock_coverage` 空表时欠产输出必须带原因。
    否则「Plan 3 落地前的预期状态」与「真回归」在日志里长得一模一样，
    运维只看到「仅生成 0/2」无从判断。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), None)   # 无覆盖行
    out = asyncio.run(generate_batch(conn, 2, tmp_path, random.Random(3)))
    assert out == []
    printed = capsys.readouterr().out
    assert "stock_coverage" in printed, f"欠产输出未带首条 skip 原因：{printed!r}"


def test_generate_batch_produces_requested_count(tmp_path):
    """B4 补货入口：Plan 1 停用期间恒返 0（库存永远生不出来）；重接后必须真出货。"""
    conn, _ = _fixture_conn()
    out = asyncio.run(generate_batch(conn, 2, tmp_path, random.Random(3)))
    assert len(out) == 2
    assert len(conn.registered) == 2


# ===== B2 生成互斥锁（Task 5 Step 10b 的防线；测试按 PF2-R8-F1 放在本文件）=====

async def _must_not_run(*a, **k):
    raise AssertionError("拿不到 B2 生成锁时不得调用 generate_batch")


def test_cli_refuses_when_b2_lock_held(tmp_path, monkeypatch, capsys):
    """codex PF2-R5-F2 + R6-F2：CLI 侧的锁必须真存在且真拦住。
    拿不到锁 → 非零退出 + 明确报错，**不得**继续生成（继续会覆盖已登记的 zip、
    让 content_hash 失配）。"""
    import generate_training_sets as G

    class _LockedConn:
        async def fetchval(self, q, *a):
            assert "pg_try_advisory_lock" in q
            return False
        async def execute(self, q, *a):
            raise AssertionError("拿不到锁时不应 unlock")
        async def close(self):
            return None

    async def _connect(dsn):
        return _LockedConn()

    fake = types.ModuleType("asyncpg")
    fake.connect = _connect
    monkeypatch.setitem(sys.modules, "asyncpg", fake)
    monkeypatch.setattr(G, "generate_batch", _must_not_run)

    rc = G.main(["--dsn", "postgres://x", "--output", str(tmp_path)])
    assert rc != 0, "拿不到 B2 锁时 CLI 必须非零退出"
    assert "锁" in capsys.readouterr().out


def test_gen_adapter_returns_zero_when_b2_lock_held(tmp_path, caplog):
    """B4 侧：拿不到 B2 生成锁 → 本次 sweep 生成 0 + 告警，**不**与手工 CLI
    竞争同一产物路径。"""
    import logging
    from app.scheduler import build_generate_batch

    class _LockedConn:
        async def fetchval(self, q, *a):
            assert "pg_try_advisory_lock" in q
            return False
        async def execute(self, q, *a):
            raise AssertionError("拿不到锁时不应 unlock")

    class _Acq:
        async def __aenter__(self): return _LockedConn()
        async def __aexit__(self, *a): return False

    class _Pool:
        def acquire(self): return _Acq()

    gen = build_generate_batch(_Pool(), str(tmp_path))
    with caplog.at_level(logging.WARNING):
        assert asyncio.run(gen(5)) == 0
    assert "B2 生成锁" in caplog.text


def test_gen_adapter_releases_b2_lock_even_if_generate_batch_raises(tmp_path, monkeypatch):
    """codex whole-branch I4：`_gen`（`build_generate_batch` 内部闭包，B4 常驻调度器的
    生产主路径）拿到锁后若 `generate_batch` 抛异常，锁也必须被释放——否则 session 级
    advisory lock 泄漏在池化连接上会**永久把 CLI 挡在外面**。CLI 侧 `_amain` 已有
    `test_amain_releases_b2_lock_even_if_generate_batch_raises` 覆盖同一性质的顺序断言，
    B4 侧此前只测了「拿不到锁」那一支（`test_gen_adapter_returns_zero_when_b2_lock_held`），
    缺这一支——对齐补齐。"""
    import generate_training_sets as G
    from app.scheduler import build_generate_batch

    calls: list = []

    class _Conn:
        async def fetchval(self, q, *a):
            if "pg_try_advisory_lock" in q:
                calls.append("lock")
                return True
            raise AssertionError(f"未预期 fetchval: {q}")
        async def execute(self, q, *a):
            if "pg_advisory_unlock" in q:
                calls.append("unlock")
                return None
            raise AssertionError(f"未预期 execute: {q}")

    class _Acq:
        async def __aenter__(self): return _Conn()
        async def __aexit__(self, *a): return False

    class _Pool:
        def acquire(self): return _Acq()

    async def _boom(conn, count, out_dir, rng):
        calls.append("batch")
        raise RuntimeError("boom")

    monkeypatch.setattr(G, "generate_batch", _boom)

    gen = build_generate_batch(_Pool(), str(tmp_path))
    with pytest.raises(RuntimeError):
        asyncio.run(gen(5))
    assert calls == ["lock", "batch", "unlock"], calls


# ===== Task 6 补充（brief 之外，Task 5 遗留必补覆盖，详见 task-6-report.md 对照表）=====

def test_predecheck_does_not_delete_concurrent_winners_file(tmp_path, monkeypatch):
    """codex a7b009d（Task 5 评审修复）回归锁：`_exists_start` 预检命中时**不得**
    unlink 最终路径文件——并发写者 B 与已登记的 A 撞同一 (stock_code,
    start_datetime) 时，B 命中的正是 A 已登记指向的文件（`assemble_from_windows`
    早已把它覆盖重写）；旧写法会 unlink 掉它，让 training_sets 里 A 那一行
    file_path 指向不存在的文件（数据丢失，评审实测复现过）。

    复现手法（复用双写者 / 共享 registry 的 FakeConn 思路）：B 的 exclude_starts
    快照必须发生在 A 登记**之前**才会撞车——自然路径下 exclude_starts 会天然
    避开已登记起点，测不到这条回归，故 monkeypatch `_fetch_existing_starts`
    让 B 看不到 A 的登记（模拟 TOCTOU 快照过期）。两次调用共享同一 rng seed +
    同一 conn（同 bars/coverage）→ 纯函数链在相同输入下确定性选出同一起点。
    """
    import generate_training_sets as G

    conn, _ = _fixture_conn()

    gts_a = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                  random.Random(7)))
    assert gts_a.path.exists()
    assert len(conn.registered) == 1

    async def _stale_existing_starts(c, code):
        return set()          # TOCTOU：B 看不到 A 刚登记的起点

    monkeypatch.setattr(G, "_fetch_existing_starts", _stale_existing_starts)

    with pytest.raises(GenerateSkipException, match="已登记"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))

    # 核心断言：预检命中时，A 已登记指向的文件不得被删除
    assert gts_a.path.exists(), "预检不得删除并发赢家已登记的文件（a7b009d 回归）"
    assert len(conn.registered) == 1, "B 的登记必须被跳过（只 A 那一行）"


@pytest.mark.parametrize("null_field", ["start", "end"])
def test_coverage_row_null_endpoint_skips_fail_closed(tmp_path, null_field):
    """`_fetch_dense_coverage` 坏行降级分支之一：stock_coverage **行存在**但端点
    为 NULL（区别于 test_missing_coverage_artifact_skips_fail_closed 的"整行缺失"，
    是不同的代码路径——`row is None` vs `row["dense_1m_start_date"] is None`）。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    cov = {"dense_1m_start_date": None if null_field == "start" else days[0],
           "dense_1m_end_date": None if null_field == "end" else days[-1],
           "dropped_1m_dates": "[]", "dense_day_count": len(days)}
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), cov)
    with pytest.raises(GenerateSkipException, match="NULL"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []


def test_fetch_existing_starts_returns_registered_set(tmp_path):
    """`_fetch_existing_starts` 直接单测：返回该股已登记的全部 start_datetime 集合
    （exclude_starts 的数据来源，独立于 generate_one_training_set 端到端断言）。"""
    from generate_training_sets import _fetch_existing_starts
    conn, _ = _fixture_conn()
    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    starts = asyncio.run(_fetch_existing_starts(conn, "000001.SZ"))
    assert starts == {gts.start_datetime}


def test_register_training_set_atomic_conflict_returns_none(tmp_path):
    """`_register_training_set` 直接单测：对已登记的 (stock_code, start_datetime)
    再次调用，`ON CONFLICT DO NOTHING RETURNING id` 命中 → fetchval 返回 None，
    函数原样透传（不吞、不抛）。"""
    from generate_training_sets import _register_training_set
    conn, _ = _fixture_conn()
    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert len(conn.registered) == 1
    row_id_dup = asyncio.run(_register_training_set(conn, gts))
    assert row_id_dup is None
    assert len(conn.registered) == 1, "冲突登记不得追加行"


def test_generate_batch_prefixes_unprefixed_skip_reason(tmp_path, capsys):
    """`generate_batch` 的 first_skip 前缀去重逻辑的另一半分支：来自更深处
    （`eligible_start_indices` 等）的 GenerateSkipException 消息**不带**
    "{code}: " 前缀，generate_batch 必须补上（否则运维看不出是哪只股跳的）。

    构造手法：n_days 只给 100 个工作日 → 月边界远不足 eligible_start_indices
    要求的 39 → 抛不带前缀的 "月边界仅 N，不足 39"（区别于
    test_generate_batch_surfaces_first_skip_reason 覆盖的"已带前缀"分支，
    那条走的是 stock_coverage 缺失，消息本身已含 "{code}: "）。"""
    days = _trading_days(dt.date(2022, 1, 3), 100)
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 100), _coverage_row(days))
    out = asyncio.run(generate_batch(conn, 1, tmp_path, random.Random(3)))
    assert out == []
    printed = capsys.readouterr().out
    assert "000001.SZ: 月边界仅" in printed, f"未带前缀的 skip 原因未被补前缀：{printed!r}"


def test_amain_acquires_and_releases_b2_lock_on_success(tmp_path, monkeypatch):
    """CLI 侧 `_amain` 成功路径：拿到 B2 锁 → 跑 generate_batch → 无论如何都要
    unlock（拿锁/放锁的顺序与配对，区别于 test_cli_refuses_when_b2_lock_held
    覆盖的"拿不到锁就拒绝"分支）。"""
    import generate_training_sets as G

    calls: list = []

    class _Conn:
        async def fetchval(self, q, *a):
            if "pg_try_advisory_lock" in q:
                calls.append("lock")
                return True
            raise AssertionError(f"未预期 fetchval: {q}")
        async def execute(self, q, *a):
            if "pg_advisory_unlock" in q:
                calls.append("unlock")
                return None
            raise AssertionError(f"未预期 execute: {q}")
        async def close(self):
            calls.append("close")

    async def _connect(dsn):
        return _Conn()

    fake = types.ModuleType("asyncpg")
    fake.connect = _connect
    monkeypatch.setitem(sys.modules, "asyncpg", fake)

    async def _fake_batch(conn, count, out_dir, rng):
        calls.append("batch")
        return []

    monkeypatch.setattr(G, "generate_batch", _fake_batch)

    rc = G.main(["--dsn", "postgres://x", "--output", str(tmp_path)])
    assert rc == 0
    assert calls == ["lock", "batch", "unlock", "close"], calls


def test_amain_releases_b2_lock_even_if_generate_batch_raises(tmp_path, monkeypatch):
    """`generate_batch` 抛非 GenerateSkipException 异常也不得漏放锁——`_amain`
    用 try/finally 包裹，锁的释放不能依赖 generate_batch 正常返回。"""
    import generate_training_sets as G

    calls: list = []

    class _Conn:
        async def fetchval(self, q, *a):
            if "pg_try_advisory_lock" in q:
                return True
            raise AssertionError(f"未预期 fetchval: {q}")
        async def execute(self, q, *a):
            if "pg_advisory_unlock" in q:
                calls.append("unlock")
                return None
            raise AssertionError(f"未预期 execute: {q}")
        async def close(self):
            calls.append("close")

    async def _connect(dsn):
        return _Conn()

    fake = types.ModuleType("asyncpg")
    fake.connect = _connect
    monkeypatch.setitem(sys.modules, "asyncpg", fake)

    async def _boom(conn, count, out_dir, rng):
        raise RuntimeError("boom")

    monkeypatch.setattr(G, "generate_batch", _boom)

    with pytest.raises(RuntimeError):
        G.main(["--dsn", "postgres://x", "--output", str(tmp_path)])
    assert calls == ["unlock", "close"], calls
