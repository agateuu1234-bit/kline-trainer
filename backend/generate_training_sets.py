# backend/generate_training_sets.py
# Spec: kline_trainer_modules_v1.4.md §四 B2 (L725-753) + M0.1 CRC32 (L163-219)
#       + kline_trainer_plan_v1.5.md §8.3 (L1097-1144) + 训练组 SQLite DDL §3.2
#       + backend/sql/training_set_schema_v1.sql（本 PR 只读不改）
#
# 双层（D1）：纯装配层（crc32_hex / select_start_index / monthly_after_end /
#   select_period_window / assign_global_indices / build_training_set_sqlite /
#   zip_and_hash / assemble_training_set）host pytest 全测、不碰 PostgreSQL；
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

import random
import sqlite3
import zipfile
import zlib
from bisect import bisect_left, bisect_right
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Sequence

import pandas as pd

SCHEMA_VERSION = 1
MIN_PERIOD = "3m"
# 训练组包含的周期（plan §8.3 period_configs；最细=3m）
PERIODS = ("monthly", "weekly", "daily", "60m", "15m", "3m")
# 各周期"起始前"取根数上限；None = 全取（monthly）
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


def select_start_index(monthly_datetimes: Sequence[int], rng: random.Random) -> int:
    """D5：随机选起始月线下标 ∈ [30, len-9]（前 ≥30、含起始之后 ≥8）。
    月线 <39 根 → GenerateSkipException。"""
    n = len(monthly_datetimes)
    if n < 39:                          # 需 [30, n-9] 非空 → n-9 >= 30 → n >= 39
        raise GenerateSkipException(f"月线仅 {n} 根，不足 39 根无法选起始点")
    return rng.randint(30, n - 9)


def monthly_after_end(monthly_datetimes: Sequence[int], start_datetime: int) -> int:
    """D6："之后"时间窗口 = 起始起 8 根月 K（含起始）的最后一根 datetime。"""
    after = [d for d in monthly_datetimes if d >= start_datetime][:8]
    if not after:
        raise GenerateSkipException("起始点之后无月线")
    return int(after[-1])


def select_period_window(bars: pd.DataFrame, start_datetime: int,
                         before_cap: Optional[int], after_end_time: int) -> pd.DataFrame:
    """D6：单周期窗口 = 起始前 min(pivot, cap) 根 + datetime∈[start, after_end] 的所有根。
    bars 须按 datetime 升序。"""
    b = bars.sort_values("datetime").reset_index(drop=True)
    dts = b["datetime"].tolist()
    pivot = bisect_left(dts, start_datetime)               # 第一根 datetime >= start 的下标
    before_count = pivot if before_cap is None else min(pivot, before_cap)
    before = b.iloc[pivot - before_count: pivot]
    after = b[(b["datetime"] >= start_datetime) & (b["datetime"] <= after_end_time)]
    return pd.concat([before, after]).reset_index(drop=True)


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


def assemble_training_set(output_dir: Path, *, stock_code: str, stock_name: str,
                          period_bars: dict[str, pd.DataFrame],
                          rng: random.Random) -> GeneratedTrainingSet:
    """纯装配（D1，不碰 PG）：已取到内存的各周期 bars → 选起始 → 窗口 → 赋 index →
    建 SQLite → zip → CRC32 → GeneratedTrainingSet。"""
    monthly = period_bars["monthly"].sort_values("datetime").reset_index(drop=True)
    monthly_dts = [int(x) for x in monthly["datetime"]]
    start_idx = select_start_index(monthly_dts, rng)
    start_datetime = monthly_dts[start_idx]
    after_end = monthly_after_end(monthly_dts, start_datetime)

    windows: dict[str, pd.DataFrame] = {}
    for period in PERIODS:
        win = select_period_window(period_bars[period], start_datetime,
                                   PERIOD_BEFORE_CAP[period], after_end)
        # D6 per-period 硬校验（spec §8.3 assert before_count>=30 + len(after_bars)>=1）：
        # 晚上市/稀疏数据 → 跳过该股票重选（L1144）。空窗口是 before<30 的子集。
        before_n = int((win["datetime"] < start_datetime).sum())
        after_n = int((win["datetime"] >= start_datetime).sum())
        if before_n < 30 or after_n < 1:
            raise GenerateSkipException(
                f"{period} 起始前 {before_n}(<30) 或 起始后 {after_n}(<1) 不足")
        windows[period] = win
    windows = assign_global_indices(windows)

    fname = f"{stock_code}_{start_datetime}"
    db_path = output_dir / f"{fname}.db"
    zip_path = output_dir / f"{fname}.zip"
    build_training_set_sqlite(db_path, stock_code=stock_code, stock_name=stock_name,
                              start_datetime=start_datetime, end_datetime=after_end,
                              windows=windows)
    content_hash = zip_and_hash(db_path, zip_path)
    return GeneratedTrainingSet(path=zip_path, content_hash=content_hash,
                                stock_code=stock_code, stock_name=stock_name,
                                start_datetime=start_datetime, end_datetime=after_end,
                                schema_version=SCHEMA_VERSION)
