# backend/qmt_normalize.py
"""QMT 真实数据规整层（纯函数）。Spec: 2026-07-06-qmt-data-ingestion-pilot-design.md §4.1。"""
from __future__ import annotations
import datetime as _dt
import re
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo
import pandas as pd

_SH = ZoneInfo("Asia/Shanghai")

_QMT_COLUMNS = ("time", "open", "high", "low", "close", "volume", "amount")
_FILENAME_RE = re.compile(
    r"^(?P<code>\d+\.(?:SH|SZ|BJ))_(?P<name>.+)_(?P<label>1分钟K线|日K线)_前复权\.csv$"
)
_LABEL_TO_PERIOD = {"1分钟K线": "1m", "日K线": "daily"}
# 裸股票代码（非文件名）规范格式：数字 + 市场后缀。信任边界校验用——
# `../x`、`/tmp/x`、`a/b` 等一律不匹配（codex R4-F1：generate_training_sets 把
# DB 派生的 stock_code 直接拼进文件路径，坏码会致目录穿越/绝对路径逃逸）。
_STOCK_CODE_RE = re.compile(r"^\d+\.(?:SH|SZ|BJ)$")

class QmtSchemaError(ValueError):
    """QMT CSV 缺列 / 文件名不合规。"""

def trading_date(epoch: int) -> _dt.date:
    """Unix 秒 → Asia/Shanghai 交易日期（所有日期分组/比对的唯一入口，禁 UTC/naive）。"""
    return _dt.datetime.fromtimestamp(int(epoch), _SH).date()

def parse_qmt_datetime(series: pd.Series, src_period: str) -> pd.Series:
    """QMT 打包整数时间 → Unix 秒（Int64）。1m=YYYYMMDDHHMMSS(14 位)、daily=YYYYMMDD(8 位)，
    按 Asia/Shanghai 本地化（naive→带 tz→timestamp），非直接当 Unix 秒。"""
    fmt = "%Y%m%d%H%M%S" if src_period == "1m" else "%Y%m%d"
    def _one(v: int) -> int:
        naive = _dt.datetime.strptime(str(int(v)), fmt)
        return int(naive.replace(tzinfo=_SH).timestamp())
    return series.map(_one).astype("int64")

def is_valid_stock_code(code: str) -> bool:
    """裸股票代码是否符合规范格式（数字+`.`+SH/SZ/BJ）。信任边界校验入口
    ——调用方应在把任何 DB 派生的 stock_code 用于路径拼接前先过这一关。"""
    return bool(_STOCK_CODE_RE.match(code))

def parse_qmt_filename(name: str) -> tuple[str, str, str]:
    m = _FILENAME_RE.match(name)
    if not m:
        raise QmtSchemaError(f"文件名不符合 QMT 规则: {name!r}")
    return m["code"], m["name"], _LABEL_TO_PERIOD[m["label"]]

@dataclass(frozen=True)
class QmtSource:
    """携带来源身份的 QMT 数据（P3-D1/R14-F1：身份随数据端到端，不作为独立参数漂）。"""
    code: str
    period: str
    df: pd.DataFrame

def parse_qmt_csv(path: Path, src_period: str) -> "QmtSource":
    try:
        df = pd.read_csv(path, encoding="utf-8-sig")   # utf-8-sig 剥 BOM
    except (pd.errors.EmptyDataError, pd.errors.ParserError) as e:
        # R5-F1：零字节/截断/不可解析 CSV（中断的导出或拷贝）在读取处即抛 pandas
        # 非域异常，会绕过 CLI 的 QMT 域异常捕获 → 裸 traceback。归一化为
        # QmtSchemaError（CLI rc=2）。文件读是解析路径最外层，堵这里 = 读→列→值→时间三层全封。
        raise QmtSchemaError(f"QMT CSV 读取失败（空/截断/不可解析）: {e}") from e
    missing = [c for c in _QMT_COLUMNS if c not in df.columns]
    if missing:
        raise QmtSchemaError(f"QMT CSV 缺必需列: {missing}")
    if len(df) == 0:
        raise QmtSchemaError("QMT CSV 无数据行")
    df = df.rename(columns={"time": "datetime"})
    try:
        df["datetime"] = parse_qmt_datetime(df["datetime"], src_period)
    except (ValueError, TypeError) as e:
        raise QmtSchemaError(f"QMT CSV time 列解析失败: {e}") from e
    df = df[["datetime", "open", "high", "low", "close", "volume", "amount"]].copy()
    # 数值列坏值门（R4-F2）：非数值文本（如 open=bad）会让列停在 object dtype，
    # 下游 clean 的 `out[c] > 0` 抛 pandas TypeError → 裸 traceback 绕过 CLI 的
    # 域异常捕获。在解析边界一次性把六列强转为数值，非数值 → QmtSchemaError（CLI
    # rc=2）。空单元格已是 NaN（float），由下游值门/clean 判非有限拦下，不在此拒。
    for col in ("open", "high", "low", "close", "volume", "amount"):
        try:
            df[col] = pd.to_numeric(df[col])
        except (ValueError, TypeError) as e:
            raise QmtSchemaError(f"QMT CSV {col} 列含非数值: {e}") from e
    code, _name, period = parse_qmt_filename(Path(path).name)
    return QmtSource(code=code, period=period, df=df)
