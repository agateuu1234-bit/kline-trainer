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

from pathlib import Path
from typing import Any, Optional, Sequence

import numpy as np
import pandas as pd

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


async def write_to_postgres(dsn: str, stock_code: str, stock_name: str,
                            records: list[dict]) -> int:
    """D11：stocks + klines 幂等 UPSERT。返回写入 kline 行数。"""
    import asyncpg  # 局部 import：纯函数层不依赖 asyncpg（单测不装也能跑）
    conn = await asyncpg.connect(dsn)
    try:
        async with conn.transaction():
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


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="导入 CSV 行情到 PostgreSQL (B1)")
    ap.add_argument("--input", required=True, help="CSV 目录")
    ap.add_argument("--stock", required=True, help="股票代码")
    ap.add_argument("--period", default=None, help="只导该周期；省略=导全部")
    ap.add_argument("--name", default=None, help="股票名（缺省取 CSV name 列或代码）")
    ap.add_argument("--dsn", default=os.environ.get("DATABASE_URL"), help="PostgreSQL DSN")
    args = ap.parse_args(argv)
    if not args.dsn:
        ap.error("需要 --dsn 或环境变量 DATABASE_URL")
    # R4-1（Task2 code-quality）：拒绝 typo/未知 --period，避免静默 0 行"成功"导入。
    if args.period and args.period not in KNOWN_PERIODS:
        ap.error(f"未知 --period {args.period!r}（合法值：{', '.join(KNOWN_PERIODS)}）")

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
