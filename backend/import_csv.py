# backend/import_csv.py
# Spec: kline_trainer_modules_v1.4.md §四 B1 (L718-723) + plan v1.5 §6.4.1 + klines DDL L325-363
#
# 双层（D1）：纯函数层（parse/clean/compute_indicators/to_kline_records）
# host pytest 全测、不碰 DB；薄 asyncpg 写库壳 + CLI 在同文件下半（D14，CI 不单测，B3/NAS scope）。
#
# 决议：
# - D2 指标用 pandas 内建 rolling/ewm 直算（非 pandas-ta，beta 不稳定 + 要可测精确值；前端只读 B1 输出）
# - D3 MA66 = SMA(close,66)，前 65 行 NULL，round(4)
# - D4 BOLL = SMA(close,20) ± 2*std(ddof=0 总体)，前 19 行 NULL，round(4)
# - D5 MACD: DIF=EMA12-EMA26 / DEA=EMA(DIF,9) / BAR=(DIF-DEA)*2；ewm(adjust=False)；round(6)
# - D6 ticket_index：已停止写入（QMT spec D3/R12-F1）。PG 列保留（m01 禁不可逆迁移），
#   新行该列 NULL；无下游消费者（B2 _KLINE_SELECT_COLS 不含、iOS 零引用）。
# - D7 必需列 datetime/open/high/low/close/volume；datetime→Unix 秒 Int64；缺列抛 CsvSchemaError
# - D9 清洗丢 NaN/非正价/high<low/越界 + 去重(keep last) + 升序
from __future__ import annotations

import datetime as _dt
import math
from pathlib import Path
from typing import Any, Optional, Sequence

import numpy as np
import pandas as pd

from qmt_normalize import trading_date

REQUIRED_COLUMNS = ("datetime", "open", "high", "low", "close", "volume")
_PRICE_COLS = ("open", "high", "low", "close")


class CsvSchemaError(ValueError):
    """CSV 缺必需列 / 无法解析。"""


def parse_csv(path: Path) -> pd.DataFrame:
    """读 CSV → DataFrame；datetime 解析为 Unix 秒 Int64（D7）。"""
    df = pd.read_csv(path)
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise CsvSchemaError(f"CSV 缺必需列: {missing}")
    df["datetime"] = _to_unix_seconds(df["datetime"])
    return df


def _to_unix_seconds(s: pd.Series) -> pd.Series:
    """接受整数秒或 'YYYY-MM-DD HH:MM:SS' 字符串 → Int64 秒。"""
    if pd.api.types.is_numeric_dtype(s):
        return s.astype("int64")
    dt = pd.to_datetime(s, utc=True, errors="coerce")
    if dt.isna().any():
        raise CsvSchemaError("datetime 列存在无法解析的值")
    # R1-M1：Series.view 在 pandas 2.2.3 已 deprecated；用 astype("int64") 取 ns 再 //1e9。
    return (dt.astype("int64") // 1_000_000_000).astype("int64")


def clean(df: pd.DataFrame) -> pd.DataFrame:
    """D9：校验必需列 → 丢异常行 → 去重(keep last) → datetime 升序。"""
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise CsvSchemaError(f"缺必需列: {missing}")
    out = df.copy()
    out = out.dropna(subset=list(REQUIRED_COLUMNS))
    for c in _PRICE_COLS:
        out = out[out[c] > 0]
    # codex 对抗评审 high：DOUBLE PRECISION 放宽后 inf 能穿过上面的 >0 校验
    # （inf > 0 为真），也能穿过下面的 high>=low / high>=max(open,close) 校验
    # （inf >= inf 为真），进而落库、污染训练组生成与读取（下游拒非有限蜡烛）。
    # 以前价格列是 DECIMAL 时数据库层会挡；现在必须在这里显式丢非有限行。
    out = out[np.isfinite(out[list(_PRICE_COLS)]).all(axis=1)]
    out = out[out["high"] >= out["low"]]
    out = out[out["high"] >= out[["open", "close"]].max(axis=1)]
    out = out[out["low"] <= out[["open", "close"]].min(axis=1)]
    out = out.drop_duplicates(subset=["datetime"], keep="last")
    out = out.sort_values("datetime").reset_index(drop=True)
    return out


def compute_indicators(df: pd.DataFrame) -> pd.DataFrame:
    """D2-D5：MA66 / BOLL(20,2,ddof=0) / MACD(12,26,9, BAR×2)。返回带指标列的新 df。"""
    out = df.copy()
    close = out["close"].astype(float)

    out["ma66"] = close.rolling(window=66, min_periods=66).mean().round(4)

    mid = close.rolling(window=20, min_periods=20).mean()
    std = close.rolling(window=20, min_periods=20).std(ddof=0)
    out["boll_mid"] = mid.round(4)
    out["boll_upper"] = (mid + 2 * std).round(4)
    out["boll_lower"] = (mid - 2 * std).round(4)

    ema12 = close.ewm(span=12, adjust=False).mean()
    ema26 = close.ewm(span=26, adjust=False).mean()
    dif = ema12 - ema26
    dea = dif.ewm(span=9, adjust=False).mean()
    out["macd_diff"] = dif.round(6)
    out["macd_dea"] = dea.round(6)
    out["macd_bar"] = ((dif - dea) * 2).round(6)
    return out


# R1-H2：BIGINT/INTEGER 列必须是 Python int，其余 DECIMAL 列是 Python float。
# df.iterrows() 会把整行升格成单一 float64 dtype → datetime/volume 变 numpy.float64
# → asyncpg int8/int4 codec 拒收。故按列显式 cast，不用 iterrows()。
_INT_COLS = ("datetime", "volume")
_FLOAT_COLS = ("open", "high", "low", "close", "amount", "ma66",
               "boll_upper", "boll_mid", "boll_lower",
               "macd_diff", "macd_dea", "macd_bar")


def _int_or_none(v: Any) -> Optional[int]:
    if v is None:
        return None
    if isinstance(v, float) and np.isnan(v):
        return None
    return int(v)


def _float_or_none(v: Any) -> Optional[float]:
    if v is None:
        return None
    fv = float(v)
    if np.isnan(fv):
        return None
    return fv


def to_kline_records(df: pd.DataFrame, stock_code: str, period: str) -> list[dict]:
    """把带指标的 df 转成入库 record dict 列表。
    R1-H2：整数列 → Python int，浮点列 → Python float（非 numpy 标量），NaN → None。
    用 to_dict('records') 保留各列原 dtype，再逐列 cast（避免 iterrows() float64 升格）。"""
    rows = df.to_dict("records")
    records: list[dict] = []
    for row in rows:
        rec: dict[str, Any] = {"stock_code": stock_code, "period": period}
        for c in _INT_COLS:
            rec[c] = _int_or_none(row.get(c))
        for c in _FLOAT_COLS:
            rec[c] = _float_or_none(row.get(c))
        records.append(rec)
    return records


# ===== 薄写库壳 + CLI（D14：不单测，B3/NAS 集成 scope）=====
import argparse
import asyncio
import os
import sys

_KLINE_INSERT = """
INSERT INTO klines (stock_code, period, datetime, open, high, low, close,
                    volume, amount, ma66,
                    boll_upper, boll_mid, boll_lower,
                    macd_diff, macd_dea, macd_bar)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
ON CONFLICT (stock_code, period, datetime) DO UPDATE SET
    open=EXCLUDED.open, high=EXCLUDED.high, low=EXCLUDED.low, close=EXCLUDED.close,
    volume=EXCLUDED.volume, amount=EXCLUDED.amount,
    ma66=EXCLUDED.ma66, boll_upper=EXCLUDED.boll_upper, boll_mid=EXCLUDED.boll_mid,
    boll_lower=EXCLUDED.boll_lower, macd_diff=EXCLUDED.macd_diff,
    macd_dea=EXCLUDED.macd_dea, macd_bar=EXCLUDED.macd_bar
"""


class SchemaDriftError(ValueError):
    """D8a：写库前置断言失败——目标库 klines 价格列类型与预期（double precision）不符。"""


_SCHEMA_CHECK_SQL = """
SELECT a.attname AS column_name,
       format_type(a.atttypid, a.atttypmod) AS data_type
FROM pg_attribute a
WHERE a.attrelid = to_regclass('klines')
  AND a.attname = ANY($1::text[])
  AND a.attnum > 0
  AND NOT a.attisdropped
"""


async def _assert_klines_price_columns_double(conn) -> None:
    """D8a（spec §4.3，codex 对抗评审 high 提前落地；R2 再收紧）：写库前 fail-closed
    断言——klines.open/high/low/close 必须已是 double precision。防目标库尚未跑
    migration 0004（仍是 DECIMAL(10,2)）时 PostgreSQL 静默四舍五入到 2 位，摧毁 QMT
    前复权价的 float64 精度。刻意不断言 ticket_index（该列保留、非本次范围）。

    R2（codex 对抗评审 high #2）：查询必须用 pg_catalog + to_regclass('klines')
    精确定位关系，不能用 information_schema.columns 按裸表名过滤。后者不限 schema——
    若库里多个 schema 各有一张 klines，会把多张表的行一起取回，调用处
    `{r["column_name"]: r["data_type"] for r in rows}` 按列名收敛时后取到的行覆盖
    先前的，另一 schema 里 double precision 的 klines 可能掩盖真正写入目标（由
    search_path 解析、INSERT 不带 schema 限定）里的 numeric，让本该 fail-closed 的
    旧库被静默放行。to_regclass('klines') 的解析规则与不带限定的裸表引用完全一致，
    保证这里检查的就是 INSERT 实际会命中的那一张表。
    format_type 对 float8 返回 "double precision"、对 DECIMAL(10,2) 返回
    "numeric(10,2)"——下面 `!= "double precision"` 判据不变，DECIMAL 仍会被正确
    判为漂移。表不存在时 to_regclass 返回 NULL，查不到任何行，四列全部落入
    「列缺失」分支，同样 fail-closed。"""
    rows = await conn.fetch(_SCHEMA_CHECK_SQL, list(_PRICE_COLS))
    found = {r["column_name"]: r["data_type"] for r in rows}
    bad = {c: found.get(c, "<列缺失>") for c in _PRICE_COLS
           if found.get(c) != "double precision"}
    if bad:
        detail = "、".join(f"{c}={t}" for c, t in bad.items())
        raise SchemaDriftError(
            f"klines 价格列类型与预期不符：{detail}（期望均为 double precision）。"
            "请先跑 migration 0004_qmt_price_double_and_coverage 再导入。"
        )


async def write_to_postgres(dsn: str, stock_code: str, stock_name: str,
                            records: list[dict]) -> int:
    """D11：stocks + klines 幂等 UPSERT。返回写入 kline 行数。
    D8a：写前 fail-closed 断言 klines 价格列已是 double precision（防陈旧 DECIMAL
    库静默截断精度）。

    **断言与写入必须原子**（codex R3-F2）：断言原先在事务之外，且那条 catalog 查询
    不锁 klines —— 检查通过之后、INSERT 取到表锁之前，若有人跑 rollback.sql 或手工
    ALTER TABLE 把价格列改回 numeric，守卫就被绕过、精度静默丢失。故改为在同一事务内
    先取一把与 ALTER TABLE 冲突的锁、再断言、再写。

    锁级别选 ROW EXCLUSIVE：这正是 INSERT 自身会取的级别，与 ALTER TABLE 的
    ACCESS EXCLUSIVE 冲突（堵住并发改表），但不与其它 ROW EXCLUSIVE 冲突
    （不会把并发导入白白串行化）。刻意不升到 SHARE 或更高。

    注：这与前一轮拒绝的「为不可能场景加机器」不是同一件事——那是给单写入者架构补并发
    防护；这里是把检查移进它所保护的事务、使检查-使用原子化，属于移除结构缺陷。

    P3-D11（Task7）：通用 CSV 路径不知道某支股票是否已被 QMT 接管（write_qmt_stock
    的替换语义），必须 fail-closed 而非静默共存/覆盖：
    1) records 与 stock_code 参数身份一致性——纯内存校验，取连接前拒绝，防调用方
       传一个未接管的 stock_code 参数、但 records 实际来自另一支已接管股票，绕过
       下面的 coverage 门（先取锁再校验就晚了）。
    2) 与 write_qmt_stock 共用同一把 (IMPORT_GEN_LOCK_KEY, stock_lock_key) 按股
       xact 锁——防与 B2 训练组生成并发写同一支股票。
    3) 若该股已有 stock_coverage 行（即已被 QMT 接管），直接拒绝——通用路径不是
       替换语义，继续写会与 QMT 的 dense/dropped 语义冲突。无 coverage 行的股票
       （纯 pre-QMT 测试数据）行为不变。
    三条全在写事务内、任何 INSERT 之前。"""
    record_codes = {r["stock_code"] for r in records}
    if record_codes and record_codes != {stock_code}:   # 空 records → 沿用旧「0 行」行为，不误报
        raise ValueError(
            f"records stock_code 与参数不一致：records={record_codes}, 参数={stock_code!r}"
        )
    import asyncpg  # 局部 import：纯函数层不依赖 asyncpg（单测不装也能跑）
    # 局部 import：import_csv 不能顶层依赖 generate_training_sets（循环 import 风险）。
    from generate_training_sets import IMPORT_GEN_LOCK_KEY, stock_lock_key
    conn = await asyncpg.connect(dsn)
    try:
        async with conn.transaction():
            if not await conn.fetchval("SELECT pg_try_advisory_xact_lock($1,$2)",
                                       IMPORT_GEN_LOCK_KEY, stock_lock_key(stock_code)):
                raise ImportBusyError(f"{stock_code}: 正被 B2 生成，稍后重试")
            # R7-F1：下面 `SELECT 1 FROM stock_coverage` 在未跑 migration 0004 的库上会抛裸
            # asyncpg UndefinedTable、绕过本模块受控的 SchemaDriftError「请先跑迁移」路径
            # （滚动/部分部署、陈旧本地库）。先 to_regclass 存在性探测（同 QMT 写路径），
            # 表缺 → SchemaDriftError，不是裸崩。
            await _assert_stock_coverage_exists(conn)
            if await conn.fetchval("SELECT 1 FROM stock_coverage WHERE stock_code=$1",
                                   stock_code):
                raise LegacyImportBlockedError(
                    f"{stock_code}: 已被 QMT 管理，请用 --qmt 模式导入")
            await conn.execute("LOCK TABLE klines IN ROW EXCLUSIVE MODE")
            await _assert_klines_price_columns_double(conn)
            await conn.execute(
                "INSERT INTO stocks(code, name) VALUES($1,$2) "
                "ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name",
                stock_code, stock_name,
            )
            await conn.executemany(_KLINE_INSERT, [
                (r["stock_code"], r["period"], r["datetime"], r["open"], r["high"],
                 r["low"], r["close"], r["volume"], r["amount"],
                 r["ma66"], r["boll_upper"], r["boll_mid"], r["boll_lower"],
                 r["macd_diff"], r["macd_dea"], r["macd_bar"])
                for r in records
            ])
        return len(records)
    finally:
        await conn.close()


# ===== QMT Plan 3 B1：write_qmt_stock（替换语义 + 按股 xact 锁 + 重导入互锁）=====

_QMT_PERIODS = ("monthly", "weekly", "daily", "60m", "15m", "3m")


class InvalidImportBundleError(ValueError):
    """P3-D12：ImportBundle 结构/自洽性校验失败——write_qmt_stock 销毁性 DELETE 前
    的最后一道门，全部 if/raise（禁 assert：python -O 会 strip assert，那样这道
    fail-closed 守卫会被静默剥离，销毁性写入将在坏数据上照跑不误）。"""


class ImportBusyError(RuntimeError):
    """按股互斥锁（IMPORT_GEN_LOCK_KEY, stock_lock_key）被 B2 训练组生成占用。"""


class ReimportBlockedError(RuntimeError):
    """该股已有 training_sets 行——重导入的作废/版本化尚未落地，暂不支持覆盖导入。"""


class LegacyImportBlockedError(RuntimeError):
    """P3-D11：write_to_postgres（通用 CSV 路径）发现该股已有 stock_coverage 行
    （即已被 QMT 接管，走 write_qmt_stock 替换语义）——通用路径 fail-closed 拒绝，
    不与 QMT 的 dense/dropped 语义静默共存/覆盖。"""


def validate_import_bundle(bundle, stock_code: str) -> None:
    """P3-D12：write_qmt_stock 销毁性 DELETE 前的结构校验——ImportBundle 必须六周期
    齐全、每条记录字段完整合法、coverage 与 daily 记录自洽。全部 if/raise，禁 assert。"""
    recs = bundle.records
    if set(recs.keys()) != set(_QMT_PERIODS):
        raise InvalidImportBundleError("period 集合 ≠ 六周期")
    seen_codes = set()
    for per, rows in recs.items():
        # per 一定 ∈ _QMT_PERIODS（上面已断言 key 集合恰好相等），无需再查。
        if not rows:
            raise InvalidImportBundleError(f"{per} 空列表")
        dts = set()
        for r in rows:
            if r.get("period") != per:
                raise InvalidImportBundleError("record period 与 key 不符")
            seen_codes.add(r.get("stock_code"))
            for c in ("datetime", "open", "high", "low", "close", "volume"):
                if r.get(c) is None:
                    raise InvalidImportBundleError(f"{per} 记录缺 {c}")
            amt, vol = r.get("amount"), r.get("volume")
            if amt is None or not math.isfinite(float(amt)) or float(amt) < 0:
                raise InvalidImportBundleError("amount 非有限")
            if not math.isfinite(float(vol)) or float(vol) < 0 or float(vol) != int(vol):
                raise InvalidImportBundleError("volume 非法")
            if r["datetime"] in dts:
                raise InvalidImportBundleError(f"{per} 重复 datetime")
            dts.add(r["datetime"])
    if seen_codes != {stock_code}:
        raise InvalidImportBundleError("记录 stock_code 与参数不一致")
    cov = bundle.coverage
    daily_dates = {trading_date(r["datetime"]) for r in recs["daily"]}
    in_span = {d for d in daily_dates if cov.start_date <= d <= cov.end_date}
    dropped = set(cov.dropped_dates)
    bad = (
        not (cov.start_date <= cov.end_date) or cov.dense_day_count < 1
        or cov.start_date not in daily_dates or cov.end_date not in daily_dates
        or not all(isinstance(d, _dt.date) for d in dropped)
        or not dropped.isdisjoint(in_span)
        or cov.dense_day_count != len(in_span - dropped)
    )
    if bad:
        raise InvalidImportBundleError("coverage 与 daily 记录不自洽")


async def _assert_stock_coverage_exists(conn) -> None:
    """写 stock_coverage 前置断言：目标库须已跑 migration 0004（表存在）。用
    to_regclass 探测而非直接把该表名交给 LOCK TABLE——若表不存在，PG 会在 LOCK
    处直接抛裸 UndefinedTable、绕过这里的 SchemaDriftError，故必须先于 LOCK 调用
    （见 write_qmt_stock 内注释）。"""
    if await conn.fetchval("SELECT to_regclass('stock_coverage')") is None:
        raise SchemaDriftError("stock_coverage 表不存在，请先跑 migration 0004")


_COVERAGE_UPSERT = """
INSERT INTO stock_coverage(stock_code, dense_1m_start_date, dense_1m_end_date,
                           dropped_1m_dates, dense_day_count)
VALUES($1,$2,$3,$4::jsonb,$5)
ON CONFLICT(stock_code) DO UPDATE SET
    dense_1m_start_date=EXCLUDED.dense_1m_start_date,
    dense_1m_end_date=EXCLUDED.dense_1m_end_date,
    dropped_1m_dates=EXCLUDED.dropped_1m_dates,
    dense_day_count=EXCLUDED.dense_day_count
"""


async def write_qmt_stock(dsn, stock_code, stock_name, bundle, *, conn=None) -> dict:
    """QMT B1 写入（替换语义）：validate（零 DB 往返）→ 按股 xact 锁 → stock_coverage
    存在性（早于 LOCK，见下方注释）→ LOCK TABLE → klines 价格列 double 断言 →
    training_sets 重导入互锁 → stocks UPSERT → DELETE 六周期旧行 → INSERT 六周期
    新行 → stock_coverage UPSERT。全在同一事务内，任一步失败整体回滚、零写入。

    `conn`（R9-F1）：调用方（_amain_qmt）已在 parse 前就在这条连接上拿了按股 session 锁、
    要持到本次写入完成以封住 fresh-sweep race；传入即复用它、由调用方负责开/关。下面的
    xact 级同键锁在同一 session 上**可重入**、照常拿到。conn=None（独立调用 / L2 脚本）时
    自开自关、行为不变。"""
    from generate_training_sets import IMPORT_GEN_LOCK_KEY, stock_lock_key
    import json, asyncpg
    validate_import_bundle(bundle, stock_code)          # 取连接前，零 DB 往返
    sk = stock_lock_key(stock_code)
    owns_conn = conn is None
    if owns_conn:
        conn = await asyncpg.connect(dsn)
    try:
        async with conn.transaction():
            if not await conn.fetchval("SELECT pg_try_advisory_xact_lock($1,$2)",
                                       IMPORT_GEN_LOCK_KEY, sk):
                raise ImportBusyError(f"{stock_code}: 正被 B2 生成，稍后重试")
            # 存在性检查（to_regclass，不需锁）**必须在 LOCK 之前**（codex plan-R2）：
            # 若把 stock_coverage 写进 LOCK TABLE 而它不存在，PG 会在 LOCK 处抛
            # UndefinedTable、绕过下面的 SchemaDriftError → fail-closed 守卫失效。
            await _assert_stock_coverage_exists(conn)
            await conn.execute("LOCK TABLE klines, stock_coverage IN ROW EXCLUSIVE MODE")
            await _assert_klines_price_columns_double(conn)
            if await conn.fetchval("SELECT 1 FROM training_sets WHERE stock_code=$1 LIMIT 1",
                                   stock_code):
                raise ReimportBlockedError(
                    f"{stock_code}: 已有训练组，重导入的作废/版本化尚未落地，暂不支持覆盖导入")
            await conn.execute("INSERT INTO stocks(code,name) VALUES($1,$2) "
                               "ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name",
                               stock_code, stock_name)
            await conn.execute("DELETE FROM klines WHERE stock_code=$1 AND period = ANY($2::text[])",
                               stock_code, list(_QMT_PERIODS))
            counts = {}
            for per in _QMT_PERIODS:
                recs = bundle.records[per]
                await conn.executemany(_KLINE_INSERT, [
                    (r["stock_code"], r["period"], r["datetime"], r["open"], r["high"],
                     r["low"], r["close"], r["volume"], r["amount"], r["ma66"],
                     r["boll_upper"], r["boll_mid"], r["boll_lower"],
                     r["macd_diff"], r["macd_dea"], r["macd_bar"]) for r in recs])
                counts[per] = len(recs)
            cov = bundle.coverage
            await conn.execute(_COVERAGE_UPSERT, stock_code, cov.start_date, cov.end_date,
                               json.dumps([d.isoformat() for d in cov.dropped_dates]),
                               cov.dense_day_count)
        return counts
    finally:
        if owns_conn:
            await conn.close()


def _resolve_stock_name(df: pd.DataFrame, cli_name: Optional[str], code: str) -> str:
    """D8：CSV name 列首非空 → --name → code。"""
    if "name" in df.columns:
        nonnull = df["name"].dropna()
        if len(nonnull) > 0 and str(nonnull.iloc[0]).strip():
            return str(nonnull.iloc[0]).strip()
    return cli_name or code


# schema klines.period 合法值（plan v1.5 L328 字面）
KNOWN_PERIODS = ("1m", "3m", "15m", "60m", "daily", "weekly", "monthly")


def _discover_period(csv_path: Path) -> str:
    """从文件名推断 period（如 '600519_1m.csv' → '1m'）；失败回 '1m'。"""
    stem = csv_path.stem.lower()
    for p in KNOWN_PERIODS:
        if stem.endswith(p) or f"_{p}" in stem:
            return p
    return "1m"


async def _amain_qmt(args) -> int:
    """`--qmt` 分支异步实现（P3-D6/P3-D8/R9-F1）：
    1) rollout-drain 全局锁探测（best-effort，非 fence）
    2) **按股 session 锁在 parse 前就拿、持到 write 完成**（R9-F1）
    3) 递归定位该股的两个 QMT CSV → parse → 查 export_log → build_stock_import →
       write_qmt_stock（替换语义，复用同一 conn）
    任一步失败：把 reason 打到 stderr、返回 2（非零）——不是裸 traceback。

    诚实标注（P3-D8）：全局探测 B2_GENERATION_LOCK_KEY 只能证"探测这一刻没有 B2/B4
    调度器持锁"；它挡不住一个已经在探测**之前**无锁读完自己快照、正等着登记训练组的旧
    B2——那个更早的窗口机器检查不出来，靠部署 drain 兜底（首次导入前先停/重启调度器）。
    R9-F1 补的是**探测之后**才启动的 fresh sweep 这个可机修的具体子情形：按股 session 锁
    从 parse 前持到 write 完成，B2 对同一股先取同一把锁才读数据，锁被占即 skip、连旧数据
    都读不到 → 不会用旧数据登记 training_set 把该股卡进重导互锁。
    """
    import asyncpg  # 局部 import：纯函数层不依赖 asyncpg（单测不装也能跑）
    # 局部 import：import_csv 不能顶层依赖 generate_training_sets（循环 import 风险，
    # 与 write_to_postgres/write_qmt_stock 同理）。
    from generate_training_sets import (B2_GENERATION_LOCK_KEY, IMPORT_GEN_LOCK_KEY,
                                        stock_lock_key)

    conn = await asyncpg.connect(args.dsn)
    try:
        got = await conn.fetchval("SELECT pg_try_advisory_lock($1)", B2_GENERATION_LOCK_KEY)
        if not got:
            print("[B1] 拒绝导入：检测到活动的 B2/B4 调度器（全局锁被占）。"
                  "首次 QMT 导入前请先 drain（停止/重启）调度器再重试。"
                  "（本探测只能证明此刻没有调度器持锁，无法 fence 一个已无锁读完快照、"
                  "正等登记的旧 B2——完全封死靠部署 drain，见 spec P3-D8）",
                  file=sys.stderr)
            return 2
        await conn.fetchval("SELECT pg_advisory_unlock($1)", B2_GENERATION_LOCK_KEY)  # 仅探测，立即释放

        # R9-F1：按股 session 锁在 parse/装配/write **之前**就拿、持到 write 完成（同一 conn）。
        sk = stock_lock_key(args.stock)
        if not await conn.fetchval("SELECT pg_try_advisory_lock($1,$2)",
                                   IMPORT_GEN_LOCK_KEY, sk):
            print(f"[B1] 拒绝导入：{args.stock} 正被 B2 生成（按股锁被占），请稍后重试",
                  file=sys.stderr)
            return 2
        try:
            return await _amain_qmt_import(args, conn)
        finally:
            await conn.fetchval("SELECT pg_advisory_unlock($1,$2)", IMPORT_GEN_LOCK_KEY, sk)
    finally:
        await conn.close()


async def _amain_qmt_import(args, conn) -> int:
    """R9-F1：在调用方（_amain_qmt）已持有该股 session 锁的连接上跑 glob→parse→build→
    write_qmt_stock。锁在本函数返回后才由 _amain_qmt 释放，故整个解析/装配/写窗口都在锁内。"""
    # ---- 递归定位该股的两个 QMT CSV ----
    input_dir = Path(args.input)
    f_1m_matches = sorted(input_dir.rglob(f"{args.stock}_*_1分钟K线_前复权.csv"))
    f_daily_matches = sorted(input_dir.rglob(f"{args.stock}_*_日K线_前复权.csv"))
    if len(f_1m_matches) != 1:
        print(f"[B1] 拒绝导入：{args.stock} 的 1 分钟K线 CSV 在 {input_dir} 下命中 "
              f"{len(f_1m_matches)} 个（期望恰好 1 个）", file=sys.stderr)
        return 2
    if len(f_daily_matches) != 1:
        print(f"[B1] 拒绝导入：{args.stock} 的日K线 CSV 在 {input_dir} 下命中 "
              f"{len(f_daily_matches)} 个（期望恰好 1 个）", file=sys.stderr)
        return 2
    f_1m, f_daily = f_1m_matches[0], f_daily_matches[0]

    # qmt_ingest 符号一律局部 import（防环——qmt_ingest 顶层 import 了 import_csv 的
    # clean/compute_indicators/to_kline_records；import_csv 若顶层 import qmt_ingest，
    # 会在 import_csv 自身加载期间去加载半初始化的 qmt_ingest，循环崩溃）。
    # parse_qmt_csv/parse_qmt_filename 来自 qmt_normalize，无环，一并局部 import。
    from qmt_ingest import QmtIngestRejected, build_stock_import, parse_export_log
    from qmt_normalize import QmtSchemaError, parse_qmt_csv, parse_qmt_filename

    export_log_path = Path(args.export_log) if args.export_log else input_dir / "export_log.csv"
    if not export_log_path.exists():
        print(f"[B1] 拒绝导入：export_log 文件不存在：{export_log_path}"
              "（--export-log 或默认 <input>/export_log.csv）", file=sys.stderr)
        return 2

    try:
        s1 = parse_qmt_csv(f_1m, "1m")
        sd = parse_qmt_csv(f_daily, "daily")
        _code, stock_name, _period = parse_qmt_filename(f_1m.name)
        entries = parse_export_log(export_log_path)
        # 缺 export_log 条目须是干净拒绝，不是裸 KeyError/traceback（Task1 review 遗留缺口）。
        missing = [f"{args.stock}/{p}" for p in ("1m", "daily") if (args.stock, p) not in entries]
        if missing:
            raise QmtIngestRejected(f"export_log 缺条目: {', '.join(missing)}")
        bundle = build_stock_import(s1, sd, stock_code=args.stock, stock_name=stock_name,
                                    entry_1m=entries[(args.stock, "1m")],
                                    entry_daily=entries[(args.stock, "daily")])
        counts = await write_qmt_stock(args.dsn, args.stock, stock_name, bundle, conn=conn)
    except (QmtIngestRejected, InvalidImportBundleError, ImportBusyError,
            ReimportBlockedError, LegacyImportBlockedError, QmtSchemaError,
            SchemaDriftError) as e:
        print(f"[B1] 拒绝导入：{e}", file=sys.stderr)
        return 2

    for per, rows in counts.items():
        print(f"[B1] period={per} rows={rows}")
    cov = bundle.coverage
    print(f"[B1] dense 1m 覆盖：{cov.start_date} ~ {cov.end_date}"
          f"（dense_day_count={cov.dense_day_count}）")
    daily_recs = bundle.records["daily"]
    first_date = trading_date(daily_recs[0]["datetime"])
    last_date = trading_date(daily_recs[-1]["datetime"])
    month_count = len(bundle.records["monthly"])
    print(f"[B1] 日线：{first_date} ~ {last_date}，月边界数={month_count}")
    print(f"[B1] {args.stock} QMT 导入完成")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="导入 CSV 行情到 PostgreSQL (B1)")
    ap.add_argument("--input", required=True, help="CSV 目录")
    ap.add_argument("--stock", required=True, help="股票代码")
    ap.add_argument("--period", default=None, help="只导该周期；省略=导全部（与 --qmt 互斥）")
    ap.add_argument("--name", default=None, help="股票名（缺省取 CSV name 列或代码）")
    ap.add_argument("--dsn", default=os.environ.get("DATABASE_URL"), help="PostgreSQL DSN")
    ap.add_argument("--qmt", action="store_true",
                     help="QMT 六周期端到端导入模式（替换语义，spec P3-D6）；与 --period 互斥。"
                          "导入前探测全局 B2/B4 调度器锁作 rollout drain 闸（P3-D8/R17-F1）——"
                          "只挡得住探测那一刻有调度器持锁，挡不住已无锁读完快照、正等登记的旧 "
                          "B2，完全封死靠部署 drain。")
    ap.add_argument("--export-log", default=None,
                     help="export_log.csv 路径；省略=<input>/export_log.csv（仅 --qmt 生效）")
    args = ap.parse_args(argv)
    if not args.dsn:
        ap.error("需要 --dsn 或环境变量 DATABASE_URL")
    if args.qmt and args.period:
        ap.error("--qmt 与 --period 互斥")
    # R4-1（Task2 code-quality）：拒绝 typo/未知 --period，避免静默 0 行"成功"导入。
    if args.period and args.period not in KNOWN_PERIODS:
        ap.error(f"未知 --period {args.period!r}（合法值：{', '.join(KNOWN_PERIODS)}）")

    if args.qmt:
        return asyncio.run(_amain_qmt(args))

    csv_dir = Path(args.input)
    all_files = sorted(csv_dir.glob("*.csv"))

    # 要写库的文件：--period 过滤。（原「1m 先写」优先级随 ticket_index 停写一并移除）
    write_files = all_files
    if args.period:
        write_files = [f for f in all_files if _discover_period(f) == args.period]
    write_files = sorted(write_files)

    total = 0
    for f in write_files:
        period = args.period or _discover_period(f)
        df2 = compute_indicators(clean(parse_csv(f)))
        name = _resolve_stock_name(df2, args.name, args.stock)
        records = to_kline_records(df2, stock_code=args.stock, period=period)
        n = asyncio.run(write_to_postgres(args.dsn, args.stock, name, records))
        total += n
        print(f"[B1] {f.name} period={period} rows={n}")
    print(f"[B1] 完成：共写入 {total} 行 klines")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
