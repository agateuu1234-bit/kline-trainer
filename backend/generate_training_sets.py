# backend/generate_training_sets.py
# Spec: kline_trainer_modules_v1.4.md §四 B2 (L725-753) + M0.1 CRC32 (L163-219)
#       + kline_trainer_plan_v1.5.md §8.3 (L1097-1144) + 训练组 SQLite DDL §3.2
#       + backend/sql/training_set_schema_v1.sql（本 PR 只读不改）
#
# 双层（D1）：纯装配层（crc32_hex / compute_after_end / select_period_window /
#   eligible_start_indices / select_valid_window / per_day_intraday_complete /
#   build_training_windows / assign_global_indices / build_training_set_sqlite /
#   zip_and_hash）host pytest 全测、不碰 PostgreSQL；旧未门控 assemble_training_set 已
#   fail-closed 停用（codex PF1-R10-F1，重接 build_training_windows 留 Plan 2）；
#   薄 asyncpg PG 壳 + CLI 在同文件下半（Task 2，D13，CI 不单测，B3/NAS scope）。
#
# 决议：
# - D2 最小周期 = 3m，global_index 仅赋 3m（其它 NULL）
# - D3 content_hash = format(zlib.crc32(zip_file_bytes) & 0xFFFFFFFF, '08x')（8 字符小写；modules L750 字面）
# - D4 end_global_index = bisect_right(3m_dts, [open,下一open) 上界) - 1，clamp[0,N-1]
# - D5 起始 idx ∈ [30, len-9]，rng 可注入；月线<39 → GenerateSkipException
# - D6 before=min(pivot,cap)（monthly=ALL），after=[start, after_end]；per-period before≥30 & after≥1 硬校验
# - D8 SQLite 逐字 training_set_schema_v1.sql；numpy→python int/float，NaN→None
from __future__ import annotations

import datetime as _dt
import random
import sqlite3
import tempfile
import zipfile
import zlib
from bisect import bisect_left, bisect_right
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Sequence

import pandas as pd

from qmt_normalize import trading_date

SCHEMA_VERSION = 1
MIN_PERIOD = "3m"
# 训练组包含的周期（plan §8.3 period_configs；最细=3m）
PERIODS = ("monthly", "weekly", "daily", "60m", "15m", "3m")
# 各周期"起始前"取根数上限；None = 全取（monthly）
# 本模块暂无引用（旧 assemble_training_set 已 fail-closed 停用）：Plan 2 重接生产装配时
# 作 build_training_windows(..., before_caps=PERIOD_BEFORE_CAP) 传入。
PERIOD_BEFORE_CAP = {"monthly": None, "weekly": 120, "daily": 150,
                     "60m": 150, "15m": 150, "3m": 150}


class GenerateSkipException(Exception):
    """月线不足 / "之后" 窗口为空 / 起始点冲突 → 跳过重选（modules L737）。"""


@dataclass
class GeneratedTrainingSet:
    path: Path                 # zip 文件路径
    content_hash: str          # zip 文件 CRC32 8 字符小写十六进制（D3）
    stock_code: str
    stock_name: str
    start_datetime: int
    end_datetime: int
    schema_version: int = SCHEMA_VERSION


def crc32_hex(data: bytes) -> str:
    """D3：zip 字节 CRC32 → 8 字符小写十六进制（modules v1.3 L750 字面公式）。"""
    return format(zlib.crc32(data) & 0xFFFFFFFF, "08x")


def select_period_window(bars: pd.DataFrame, start_datetime: int, before_cap: Optional[int],
                         after_end: int, period: str, month_boundaries=None) -> pd.DataFrame:
    """D6：单周期窗口 = 起始前 min(pivot, cap) 根 + datetime∈[start, after_end] 的所有根。
    bars 须按 datetime 升序。**两侧周期边界校验**（codex PF1-R5）：weekly 额外——
    after 排除周末 > after_end 的 trailing 跨月周；before 排除周末 >= start 的跨 start 周
    （其含 post-start 数据，作 before-context 会 lookahead）。月/日与边界天然对齐无 straddle。"""
    b = bars.sort_values("datetime").reset_index(drop=True)
    dts = b["datetime"].tolist()
    pivot = bisect_left(dts, start_datetime)               # 第一根 datetime >= start 的下标
    before_count = pivot if before_cap is None else min(pivot, before_cap)
    before = b.iloc[pivot - before_count: pivot]
    after = b[(b["datetime"] >= start_datetime) & (b["datetime"] <= after_end)]

    def _week_end_date(open_epoch):
        d = trading_date(open_epoch)
        return d + _dt.timedelta(days=(6 - d.weekday()))   # 该周周日

    if period == "weekly":
        ae_date = trading_date(after_end)
        st_date = trading_date(start_datetime)
        after = after[after["datetime"].map(lambda e: _week_end_date(e) <= ae_date)]   # trailing 跨月周
        before = before[before["datetime"].map(lambda e: _week_end_date(e) < st_date)] # PF1-R5: 跨 start 周不作 before-context

    return pd.concat([before, after]).reset_index(drop=True)


def compute_after_end(month_boundaries: list[int], start_idx: int, months: int = 8) -> int:
    """第 (start_idx+months) 月边界 open − 1 秒 = 第 `months` 个完整前向月月末（调用方保证
    start_idx+months < len）。`months` 默认 8（生产）；单测可传小值缩小 fixture。"""
    return int(month_boundaries[start_idx + months]) - 1


def eligible_start_indices(month_boundaries, rng, *, dense_dates, trading_dates, months: int = 8) -> list:
    """全部 dense 覆盖的候选起点下标（随机序），供 bounded retry（codex PF1-F2/PF1-R3-F2）：
    按**交易日历**遍历——[start..after_end] 内该股每个交易日（∈ trading_dates）都 ∈ dense_dates；
    周末/假期不在 trading_dates、不误拒。"""
    n = len(month_boundaries)
    if n < 31 + months:
        raise GenerateSkipException(f"月边界仅 {n}，不足 {31 + months}")
    lo, hi = 30, n - 1 - months
    candidates = list(range(lo, hi + 1))
    rng.shuffle(candidates)                       # random.Random.shuffle
    out = []
    for idx in candidates:
        d0 = trading_date(int(month_boundaries[idx]))
        d1 = trading_date(compute_after_end(month_boundaries, idx, months))
        window_trading = [d for d in trading_dates if d0 <= d <= d1]   # 按交易日历、非日历日
        if window_trading and all(d in dense_dates for d in window_trading):
            out.append(idx)
    return out


def select_valid_window(month_boundaries, rng, *, dense_dates, trading_dates,
                        try_assemble, max_retries: int = 8, months: int = 8,
                        exclude_starts=frozenset()):
    """bounded candidate retry（codex R12-F2/PF1-R3-F2）：逐 eligible 候选调 try_assemble(start)；
    首个不抛的返回 (start, 其返回值)；抛 GenerateSkipException → 试下一个；穷尽 → skip。

    `exclude_starts`（Plan 2b）：已登记的 start_datetime（uq_stock_start）。**必须在切
    `cands[:max_retries]` 之前过滤**——若放进循环再拒，每个被排除者会吃掉一个重试名额，
    股票累积训练组后 shuffle 把已登记的排前面，就会明明还有可用起点却整股被跳过、
    且非确定性（B4 库存莫名欠产）。codex PF2-R1-F2。"""
    cands = eligible_start_indices(month_boundaries, rng, dense_dates=dense_dates,
                                   trading_dates=trading_dates, months=months)
    if exclude_starts:
        cands = [i for i in cands if int(month_boundaries[i]) not in exclude_starts]
    for idx in cands[:max_retries]:
        start = int(month_boundaries[idx])
        try:
            return start, try_assemble(start)
        except GenerateSkipException:
            continue
    raise GenerateSkipException("bounded retry 穷尽：无通过的候选起点")


_INTRADAY_EXPECTED = {"3m": 80, "15m": 16, "60m": 4}


def build_training_windows(period_bars, month_boundaries, rng, *, dense_dates, trading_dates,
                           before_caps, months: int = 8, intraday_expected=None,
                           before_min: int = 30, max_retries: int = 8,
                           exclude_starts=frozenset()):
    """**生产纯入口（codex PF1-R6-F2）**：组合 compute_after_end / select_period_window(两侧周边界) /
    D6 per-period before-after / D9 per_day 硬门 + bounded retry。返回 `(start_datetime, windows)`。
    **Plan 2 的 `generate_one_training_set` 必须调本入口**（而非旧 select_start_index/monthly_after_end），
    再做 SQLite/zip/register/起点唯一性。gate 参数（`months`/`intraday_expected`/`before_min`）可调以便端到端单测。

    `exclude_starts` 透传给 `select_valid_window`（uq_stock_start → **候选资格**，
    在重试预算之前过滤；**不要**改成在 `_try` 里拒，那会吃掉重试名额，见该函数 docstring）。"""
    idx_of = {int(b): i for i, b in enumerate(month_boundaries)}

    def _try(start):
        idx = idx_of[int(start)]
        after_end = compute_after_end(month_boundaries, idx, months)
        windows = {p: select_period_window(bars, start, before_caps[p], after_end, p)
                   for p, bars in period_bars.items()}
        for p, w in windows.items():                       # D6 per-period before>=before_min & after>=1
            before_n = int((w["datetime"] < start).sum()); after_n = int((w["datetime"] >= start).sum())
            if before_n < before_min or after_n < 1:
                raise GenerateSkipException(f"{p} before {before_n}(<{before_min}) / after {after_n}(<1)")
        intraday = {p: windows[p] for p in ("3m", "15m", "60m") if p in windows}
        if not per_day_intraday_complete(intraday, trading_dates, after_end, intraday_expected,
                                         full_bars=period_bars):     # PF2-R7-F2 边界日对照全量
            raise GenerateSkipException("D9 per-day 硬门失败")
        return windows

    return select_valid_window(month_boundaries, rng, dense_dates=dense_dates, trading_dates=trading_dates,
                               try_assemble=_try, max_retries=max_retries, months=months,
                               exclude_starts=exclude_starts)


def per_day_intraday_complete(windows, trading_dates, after_end, expected=None,
                              *, full_bars=None) -> bool:
    """D9 per-day 硬门（codex PF1-R2/PF1-R4-F2/PF1-R6-F1 + Plan 2b 边界日修正）：
    **每个盘中周期**在 `[该周期首选中日, trading_date(after_end)]` 内、每个交易日
    （∈ trading_dates）桶数精确 == 应有数（3m=80/15m=16/60m=4）；**首日 d0 同样精确验**，
    只是判据换成「**该日在 `full_bars` 里是完整的**」（d0 只是被 before_cap 切片的那天，
    窗口内不足是切片产物；但它在库里必须有满 need 根）。不传 `full_bars` 则退回严格
    全量，向后兼容既有调用。
    **跨度终点用 `after_end`、非 `dates.max()`**——否则 after_end 附近盘中全缺的
    尾日会落在 max 之外、漏检（高周期 bar 覆盖了无盘中回放的日期）。任一周期任一日不符 → False。"""
    expected = expected or _INTRADAY_EXPECTED
    ae_date = trading_date(after_end)
    for period, need in expected.items():
        win = windows.get(period)
        if win is None or win.empty:
            return False
        dates = pd.Series([trading_date(e) for e in win["datetime"]])
        d0 = dates.min()
        span = [d for d in trading_dates if d0 <= d <= ae_date]     # 到 after_end（含尾日）、非 dates.max()
        counts = dates.value_counts().to_dict()
        # **边界日 d0 对照全量 bars 校验，内部日对照窗口校验**（codex PF2-R7-F2）。
        #
        # 为什么 d0 不能用窗口里的根数判：`select_period_window` 取「起点前
        # min(pivot, cap) 根」，生产 cap(150) 不是每日根数(80/16/4)的整数倍 → d0 必然
        # 只被切到部分根（3m 70/80）。要求它 == need 的话，**完美数据也 0 候选通过**
        # （Plan 1 的 D9 测全用 cap=2/cap=0 等对齐值，生产 cap 从未被测过）。
        #
        # 为什么也不能用「从窗口反推的余数」判（本轮实测否掉的写法）：
        # `boundary_need = (before_n % need) or need` 里的 before_n 若从**窗口自身**算，
        # 该公式是**自指**的——边界日被损坏 → before_n 同步变小 → 期望值跟着变小 →
        # 恰好匹配损坏值 → 漏检。（实测：边界日 80→60 时该写法返回 True。）
        #
        # 正解：d0 只是被切片的那天，但**它在库里必须是完整的**。故对照 full_bars
        # 数该日在 PG 里的实际根数，要求 == need。非自指、且直接命中要防的坏数据。
        # 注：若某 before-context 日被整日 drop，切片会往更早取够根数 → d0 前移、
        # 空洞落进 [d0, ae] → 由下面的内部精确门抓住。
        if full_bars is None:
            boundary_ok = counts.get(d0, 0) == need      # 向后兼容既有调用：严格全量
        else:
            fb = full_bars.get(period)
            d0_full = 0 if fb is None or fb.empty else int(
                sum(1 for e in fb["datetime"] if trading_date(e) == d0))
            boundary_ok = d0_full == need
        if not boundary_ok:
            return False
        if not all(counts.get(d, 0) == need for d in span if d != d0):
            return False
    return True


def assign_global_indices(windows: dict[str, pd.DataFrame]) -> dict[str, pd.DataFrame]:
    """D2/D4：3m 升序赋 global_index 0,1,2…（其它周期 NULL）；所有周期(含3m)
    end_global_index = 覆盖区间 [open, 下一根 open) 内最后一根 3m 的 global_index
    = bisect_right(3m_dts, upper) - 1，clamp[0, N3-1]（datetime 二分匹配）。"""
    three = windows[MIN_PERIOD].sort_values("datetime").reset_index(drop=True)
    three_dts = three["datetime"].tolist()
    n3 = len(three_dts)
    if n3 == 0:
        raise GenerateSkipException("3m 窗口为空，无法建 global_index")

    out: dict[str, pd.DataFrame] = {}
    for period, df in windows.items():
        d = df.sort_values("datetime").reset_index(drop=True).copy()
        opens = d["datetime"].tolist()
        egi = []
        for i, _open in enumerate(opens):
            nxt = opens[i + 1] if i + 1 < len(opens) else None
            upper = (nxt - 1) if nxt is not None else three_dts[-1]
            j = bisect_right(three_dts, upper) - 1
            egi.append(max(0, min(j, n3 - 1)))
        d["end_global_index"] = egi
        d["global_index"] = list(range(len(d))) if period == MIN_PERIOD else None
        out[period] = d
    return out


def _int_or_none(v: Any) -> Optional[int]:
    # pd.isna 统一处理 None / float NaN / pd.NA（标量），避免 int(pd.NA) 抛 TypeError
    if v is None or pd.isna(v):
        return None
    return int(v)


def _float_or_none(v: Any) -> Optional[float]:
    if v is None or pd.isna(v):
        return None
    return float(v)


# 训练组 SQLite DDL（逐字 backend/sql/training_set_schema_v1.sql，D8；本 PR 只读不改源文件）
# 注：`PRAGMA user_version = 1` 用字面 1（== SCHEMA_VERSION）以逐字对齐冻结 schema 文件
# （原 f-string `{SCHEMA_VERSION}` 渲染后不含子串 "user_version = 1"，会让验收 grep 锚失配）。
_TRAINING_SET_DDL = """
PRAGMA user_version = 1;
CREATE TABLE meta (
    stock_code TEXT NOT NULL, stock_name TEXT NOT NULL,
    start_datetime INTEGER NOT NULL, end_datetime INTEGER NOT NULL
);
CREATE TABLE klines (
    id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT NOT NULL,
    datetime INTEGER NOT NULL, open REAL NOT NULL, high REAL NOT NULL,
    low REAL NOT NULL, close REAL NOT NULL, volume INTEGER NOT NULL, amount REAL,
    ma66 REAL, boll_upper REAL, boll_mid REAL, boll_lower REAL,
    macd_diff REAL, macd_dea REAL, macd_bar REAL,
    global_index INTEGER, end_global_index INTEGER NOT NULL
);
CREATE INDEX idx_period_endidx ON klines(period, end_global_index);
CREATE INDEX idx_period_datetime ON klines(period, datetime);
"""

_KLINE_INSERT = (
    "INSERT INTO klines (period, datetime, open, high, low, close, volume, amount, "
    "ma66, boll_upper, boll_mid, boll_lower, macd_diff, macd_dea, macd_bar, "
    "global_index, end_global_index) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
)


def build_training_set_sqlite(db_path: Path, *, stock_code: str, stock_name: str,
                              start_datetime: int, end_datetime: int,
                              windows: dict[str, pd.DataFrame]) -> None:
    """D8：写独立训练组 SQLite（schema=training_set_schema_v1.sql）。
    sqlite3 不接受 numpy 标量 → 用 to_dict('records') 逐列 cast 成 Python int/float，NaN→None。"""
    conn = sqlite3.connect(str(db_path))
    try:
        conn.executescript(_TRAINING_SET_DDL)
        conn.execute("INSERT INTO meta (stock_code, stock_name, start_datetime, end_datetime) "
                     "VALUES (?,?,?,?)", (stock_code, stock_name, int(start_datetime), int(end_datetime)))
        for period in PERIODS:
            for row in windows[period].to_dict("records"):
                conn.execute(_KLINE_INSERT, (
                    period, _int_or_none(row.get("datetime")),
                    _float_or_none(row.get("open")), _float_or_none(row.get("high")),
                    _float_or_none(row.get("low")), _float_or_none(row.get("close")),
                    _int_or_none(row.get("volume")), _float_or_none(row.get("amount")),
                    _float_or_none(row.get("ma66")), _float_or_none(row.get("boll_upper")),
                    _float_or_none(row.get("boll_mid")), _float_or_none(row.get("boll_lower")),
                    _float_or_none(row.get("macd_diff")), _float_or_none(row.get("macd_dea")),
                    _float_or_none(row.get("macd_bar")),
                    _int_or_none(row.get("global_index")), _int_or_none(row.get("end_global_index")),
                ))
        conn.commit()
    finally:
        conn.close()


def zip_and_hash(db_path: Path, zip_path: Path) -> str:
    """D3：把 .db 压进 zip → 返回整个 zip 文件字节的 CRC32（8 字符小写）。"""
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.write(db_path, arcname=db_path.name)
    return crc32_hex(zip_path.read_bytes())


def assemble_from_windows(output_dir: Path, *, stock_code: str, stock_name: str,
                          start_datetime: int, end_datetime: int,
                          windows: dict[str, pd.DataFrame]) -> GeneratedTrainingSet:
    """纯装配（不碰 PG）：已门控的 windows → 赋 index → 建 SQLite → zip → CRC32。

    **取代 Plan 1 里 fail-closed 停用的 assemble_training_set**（codex PF1-R10-F1）：
    旧函数自带"月线里随机选起点"，绕过 D2 dense 覆盖门与 D9 per-day 硬门；本函数
    **不选起点**——起点/窗口由安全纯入口 build_training_windows 门控后传入，
    本函数只负责序列化。文件名/end_datetime 语义沿用 PR #74 既有契约（B3 按路径下载）。"""
    windows = assign_global_indices(windows)
    fname = f"{stock_code}_{start_datetime}"
    zip_path = output_dir / f"{fname}.zip"
    # 中间 .db 建在**临时目录**（codex PF2-R5-F1）：它是纯构建中间产物——从不登记、
    # 无人引用。放最终目录会留崩溃残渣，而 `_TRAINING_SET_DDL` 是裸 `CREATE TABLE`
    # （无 IF NOT EXISTS）→ 下次同起点重试撞 `table meta already exists`
    # （`sqlite3.OperationalError`，**不是** GenerateSkipException）→ 中止整轮 sweep。
    # 文件名仍用 `{code}_{start}.db` 以保持 zip 内 arcname 契约不变。
    # 注：zip 直接写最终路径不受此影响——`ZipFile(path, "w")` 会截断重写，天然自愈。
    with tempfile.TemporaryDirectory() as _tmp:
        db_path = Path(_tmp) / f"{fname}.db"
        build_training_set_sqlite(db_path, stock_code=stock_code, stock_name=stock_name,
                                  start_datetime=start_datetime, end_datetime=end_datetime,
                                  windows=windows)
        content_hash = zip_and_hash(db_path, zip_path)
    return GeneratedTrainingSet(path=zip_path, content_hash=content_hash,
                                stock_code=stock_code, stock_name=stock_name,
                                start_datetime=start_datetime, end_datetime=end_datetime,
                                schema_version=SCHEMA_VERSION)


# ===== 薄 asyncpg PG 壳 + CLI（D1/D13：不单测，B3/NAS 集成 scope）=====
import argparse
import asyncio
import os

# klines 列：复制进训练组 SQLite 的列（指标由 B1 预计算，D15 B2 不重算）
_KLINE_SELECT_COLS = ("period, datetime, open, high, low, close, volume, amount, "
                      "ma66, boll_upper, boll_mid, boll_lower, macd_diff, macd_dea, macd_bar")


async def _fetch_period_bars(conn, stock_code: str, period: str) -> pd.DataFrame:
    """读某股某周期全部 klines（升序）→ DataFrame。指标列已由 B1 算好（D15）。"""
    rows = await conn.fetch(
        f"SELECT {_KLINE_SELECT_COLS} FROM klines "
        "WHERE stock_code=$1 AND period=$2 ORDER BY datetime", stock_code, period)
    return pd.DataFrame([dict(r) for r in rows])


async def _exists_start(conn, stock_code: str, start_datetime: int) -> bool:
    """D7：幂等预检——schema.sql 有 uq_stock_start UNIQUE(stock_code,start_datetime) 作硬底线；
    本 SELECT 预检让冲突走"重选起始点"的干净 UX（而非撞 UNIQUE 抛 UniqueViolationError）。"""
    row = await conn.fetchrow(
        "SELECT 1 FROM training_sets WHERE stock_code=$1 AND start_datetime=$2",
        stock_code, start_datetime)
    return row is not None


async def _register_training_set(conn, gts: GeneratedTrainingSet) -> int:
    """登记 training_sets 行（status 默认 'unsent'）。返回新行 id。"""
    return await conn.fetchval(
        "INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, "
        "schema_version, file_path, content_hash) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id",
        gts.stock_code, gts.stock_name, gts.start_datetime, gts.end_datetime,
        gts.schema_version, str(gts.path), gts.content_hash)


def _stock_name_of(stock_code: str) -> str:
    """训练组生成不查 stocks 表，stock_name 简化为 code（B3/前端用 stocks.name 显示）。"""
    return stock_code


async def generate_one_training_set(conn, stock_code: str, output_dir: Path,
                                    rng: Optional[random.Random] = None,
                                    max_retries: int = 8) -> GeneratedTrainingSet:
    """D7：取各周期 bars → 装配 → 幂等预检（冲突重选）→ 登记。
    重试耗尽 / 月线不足 / 周期数据不足 → GenerateSkipException。"""
    rng = rng or random.Random()
    period_bars = {p: await _fetch_period_bars(conn, stock_code, p) for p in PERIODS}
    for _ in range(max_retries):
        gts = assemble_training_set(output_dir, stock_code=stock_code,
                                    stock_name=_stock_name_of(stock_code),
                                    period_bars=period_bars, rng=rng)
        if await _exists_start(conn, stock_code, gts.start_datetime):
            gts.path.unlink(missing_ok=True)                     # 重选：删掉冲突产物
            gts.path.with_suffix(".db").unlink(missing_ok=True)
            continue
        await _register_training_set(conn, gts)
        gts.path.with_suffix(".db").unlink(missing_ok=True)      # 仅保留 .zip（库登记的产物），删中间 .db
        return gts
    raise GenerateSkipException(f"{stock_code}: {max_retries} 次起始点全冲突，跳过")


async def generate_batch(conn, target_count: int, output_dir: Path,
                         rng: Optional[random.Random] = None) -> list:
    """D10：B4 调度器直接调用。循环生成直到 target_count 个或连续 skip 超限（防死循环）。"""
    rng = rng or random.Random()
    codes = [r["code"] for r in await conn.fetch("SELECT code FROM stocks ORDER BY code")]
    if not codes:
        return []
    out: list = []
    skips = 0
    max_skips = max(target_count * 4, 4)
    i = 0
    while len(out) < target_count and skips < max_skips:
        code = codes[i % len(codes)]
        i += 1
        try:
            out.append(await generate_one_training_set(conn, code, output_dir, rng))
        except GenerateSkipException:
            skips += 1
    if len(out) < target_count:
        print(f"[B2] 警告：仅生成 {len(out)}/{target_count}（skip {skips} 次）")
    return out


async def backfill_content_hash(conn) -> int:
    """D11：v1.3 回迁——重算 status='unsent' AND content_hash IS NULL 行的 CRC32 并回写。返回回填行数。"""
    rows = await conn.fetch(
        "SELECT id, file_path FROM training_sets "
        "WHERE status='unsent' AND content_hash IS NULL")
    n = 0
    for r in rows:
        zip_bytes = Path(r["file_path"]).read_bytes()
        await conn.execute("UPDATE training_sets SET content_hash=$1 WHERE id=$2",
                           crc32_hex(zip_bytes), r["id"])
        n += 1
    print(f"[B2] backfill：回填 {n} 行 content_hash")
    return n


async def _amain(args) -> int:
    import asyncpg                          # 局部 import：纯装配层不依赖 asyncpg（单测不装也能跑）
    conn = await asyncpg.connect(args.dsn)
    try:
        out_dir = Path(args.output)
        out_dir.mkdir(parents=True, exist_ok=True)
        if args.backfill:
            await backfill_content_hash(conn)
            return 0
        try:
            sets = await generate_batch(conn, args.count, out_dir, random.Random(args.seed))
        except NotImplementedError as exc:
            # codex whole-branch review high：assemble_training_set 已 fail-closed 停用；
            # CLI 人工调用，比裸 traceback 更清楚地报错并非零退出（而非静默/丢生成结果）。
            print(f"[B2] 错误：{exc}")
            return 1
        for g in sets:
            print(f"[B2] {g.path.name} crc32={g.content_hash} start={g.start_datetime}")
        print(f"[B2] 完成：生成 {len(sets)} 个训练组")
        return 0
    finally:
        await conn.close()


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="生成训练组 SQLite + zip + 登记 training_sets (B2)")
    ap.add_argument("--dsn", default=os.environ.get("DATABASE_URL"), help="PostgreSQL DSN")
    ap.add_argument("--count", type=int, default=100, help="目标生成个数")
    ap.add_argument("--output", required=True, help="训练组 .zip 输出目录")
    ap.add_argument("--seed", type=int, default=None, help="随机种子（可复现）")
    ap.add_argument("--backfill", action="store_true", help="仅回迁 content_hash（v1.3 迁移）")
    args = ap.parse_args(argv)
    if not args.dsn:
        ap.error("需要 --dsn 或环境变量 DATABASE_URL")
    return asyncio.run(_amain(args))


if __name__ == "__main__":
    raise SystemExit(main())
