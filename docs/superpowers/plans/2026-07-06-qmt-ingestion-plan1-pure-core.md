# QMT 数据接入 Plan 1：纯函数核心（规整 + 合成 + 完整性/对账 + B2 纯逻辑）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 QMT 真实数据接入管线的**纯函数核心**（规整层 `qmt_normalize` + 合成层 `qmt_resample` + 完整性/对账 + B2 纯选择逻辑），全部 host `pytest` 可测、不碰任何数据库。

**Architecture:** 三个纯函数模块 + 对 `generate_training_sets.py` 的纯逻辑扩展。规整层把 QMT CSV（BOM / 北京打包整数时间 / 中文周期标签）转成与现有 `clean` 兼容的 DataFrame；合成层按 A 股交易时段/日历把 1m→3m/15m/60m、日线→周/月，并算出「dense 完整覆盖」+ 双源对账；B2 纯逻辑重定义 `after_end`、窗口纳入、按日期的起点选择、per-day 完整性硬门。DB 写库壳 / schema / pilot / 集成测试 在 **Plan 2**。

**Tech Stack:** Python 3, pandas, numpy, `zoneinfo`（标准库），pytest 8.4.2。

## Global Constraints

（每个 Task 的要求隐含包含本节；值逐字取自 spec `docs/superpowers/specs/2026-07-06-qmt-data-ingestion-pilot-design.md`）

- **纯函数层不碰 DB**，host `pytest` 全测；in-memory DataFrame。
- **前复权价 float64、OHLC 禁止四舍五入到 2 位**（`clean` 保精度）。
- **所有交易日期提取统一走单一 helper `trading_date(epoch) = datetime.fromtimestamp(epoch, ZoneInfo("Asia/Shanghai")).date()`**——禁 UTC/naive 日期提取。
- **合成严格按交易时段分段**（禁跨午休 `11:30↔13:01`、禁跨日）；周/月按**交易日历**分组（分组键用 `trading_date`）。
- **A 股完整交易日 = 241 根 1m**：上午 `09:30:00`–`11:30:00`（121，含开盘集竞）、下午 `13:01:00`–`15:00:00`（120，含收盘集竞）。
- **时间戳格式**：1m = `YYYYMMDDHHMMSS`、日线 = `YYYYMMDD`，北京时区 naive 打包整数 → Unix 秒（非直接当 Unix 秒）。
- 负向断言脚本用 `if ... then exit 1` 非 `! grep`（本 plan 无 shell 断言，纯 pytest）。
- 跑测试：`cd backend && python -m pytest tests/<file> -v`（pytest.ini `testpaths=tests`）。测试从模块名直接 import（如 `from qmt_normalize import ...`，`backend/` 在 sys.path，参现有 `test_import_csv.py`）。

---

## 文件结构

- Create: `backend/qmt_normalize.py` — 规整层纯函数（`trading_date` / `parse_qmt_datetime` / `parse_qmt_csv` / `parse_qmt_filename`）。
- Create: `backend/qmt_resample.py` — 合成层纯函数（`resample_intraday` / `resample_calendar` / `compute_dense_coverage` / `build_intraday`（安全入口）/ `reconcile_sources`）。
- Modify: `backend/generate_training_sets.py` — B2 纯逻辑（`compute_after_end` / `select_period_window`（改纳入规则）/ `eligible_start_indices` / `select_valid_window`（有界重试）/ `per_day_intraday_complete`（各周期自身跨度、到 after_end）/ **`build_training_windows`（生产纯入口，组合全部 gate + 重试）**）。
- Create: `backend/tests/test_qmt_normalize.py`
- Create: `backend/tests/test_qmt_resample.py`
- Modify: `backend/tests/test_generate_training_sets.py` — 加 B2 纯逻辑新测试。

---

## Phase 1 — 规整层 `qmt_normalize`

### Task 1: `trading_date` + `parse_qmt_datetime`（时区安全时间解析）

**Files:**
- Create: `backend/qmt_normalize.py`
- Test: `backend/tests/test_qmt_normalize.py`

**Interfaces:**
- Produces:
  - `trading_date(epoch: int) -> datetime.date` — Unix 秒 → Asia/Shanghai 交易日期。
  - `parse_qmt_datetime(series: pd.Series, src_period: str) -> pd.Series`（Int64 Unix 秒）；`src_period ∈ {"1m","daily"}`。

- [ ] **Step 1: 写失败测试**

```python
# backend/tests/test_qmt_normalize.py
from __future__ import annotations
import datetime as dt
import pandas as pd
import pytest
from zoneinfo import ZoneInfo
from qmt_normalize import trading_date, parse_qmt_datetime

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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_normalize.py -v`
Expected: FAIL（`ModuleNotFoundError: No module named 'qmt_normalize'`）

- [ ] **Step 3: 写最小实现**

```python
# backend/qmt_normalize.py
"""QMT 真实数据规整层（纯函数）。Spec: 2026-07-06-qmt-data-ingestion-pilot-design.md §4.1。"""
from __future__ import annotations
import datetime as _dt
from zoneinfo import ZoneInfo
import pandas as pd

_SH = ZoneInfo("Asia/Shanghai")

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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_normalize.py -v`
Expected: PASS（3 passed）

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_normalize.py backend/tests/test_qmt_normalize.py
git commit -m "feat(qmt): trading_date + parse_qmt_datetime (时区安全时间解析)"
```

### Task 2: `parse_qmt_csv`（剥 BOM）+ `parse_qmt_filename`

**Files:**
- Modify: `backend/qmt_normalize.py`
- Test: `backend/tests/test_qmt_normalize.py`

**Interfaces:**
- Consumes: `parse_qmt_datetime`（Task 1）。
- Produces:
  - `parse_qmt_csv(path: pathlib.Path, src_period: str) -> pd.DataFrame` — 列 `datetime`(Unix 秒)/`open/high/low/close/volume/amount`。
  - `parse_qmt_filename(name: str) -> tuple[str, str, str]` → `(code, stock_name, src_period)`；`src_period ∈ {"1m","daily"}`。
  - `class QmtSchemaError(ValueError)`。

- [ ] **Step 1: 写失败测试**

```python
# 追加到 backend/tests/test_qmt_normalize.py
from pathlib import Path
from qmt_normalize import parse_qmt_csv, parse_qmt_filename, QmtSchemaError

def test_parse_qmt_filename_three_markets():
    assert parse_qmt_filename("000001.SZ_平安银行_1分钟K线_前复权.csv") == ("000001.SZ", "平安银行", "1m")
    assert parse_qmt_filename("600519.SH_贵州茅台_日K线_前复权.csv") == ("600519.SH", "贵州茅台", "daily")
    assert parse_qmt_filename("920000.BJ_安徽凤凰_1分钟K线_前复权.csv") == ("920000.BJ", "安徽凤凰", "1m")

def test_parse_qmt_filename_fullwidth_name():
    assert parse_qmt_filename("000002.SZ_万科Ａ_日K线_前复权.csv") == ("000002.SZ", "万科Ａ", "daily")

def test_parse_qmt_csv_strips_bom_and_parses(tmp_path: Path):
    p = tmp_path / "x.csv"
    # utf-8-sig 写入 → 首字节 BOM；表头列名须为 datetime 不含 BOM
    p.write_text("time,open,high,low,close,volume,amount\n"
                 "20260703093000,10.29,10.29,10.29,10.29,10899,11215071.0\n",
                 encoding="utf-8-sig")
    df = parse_qmt_csv(p, "1m")
    assert list(df.columns) == ["datetime", "open", "high", "low", "close", "volume", "amount"]
    assert df.loc[0, "datetime"] == int(df.loc[0, "datetime"])  # Unix 秒 Int64
    assert df.loc[0, "open"] == 10.29

def test_parse_qmt_csv_missing_col_raises(tmp_path: Path):
    p = tmp_path / "y.csv"
    p.write_text("time,open,high,low,close\n20260703093000,1,1,1,1\n", encoding="utf-8-sig")
    with pytest.raises(QmtSchemaError):
        parse_qmt_csv(p, "1m")
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_normalize.py -v`
Expected: FAIL（`ImportError: cannot import name 'parse_qmt_csv'`）

- [ ] **Step 3: 写最小实现**

```python
# 追加到 backend/qmt_normalize.py
import re
from pathlib import Path

_QMT_COLUMNS = ("time", "open", "high", "low", "close", "volume", "amount")
_FILENAME_RE = re.compile(
    r"^(?P<code>\d+\.(?:SH|SZ|BJ))_(?P<name>.+)_(?P<label>1分钟K线|日K线)_前复权\.csv$"
)
_LABEL_TO_PERIOD = {"1分钟K线": "1m", "日K线": "daily"}

class QmtSchemaError(ValueError):
    """QMT CSV 缺列 / 文件名不合规。"""

def parse_qmt_filename(name: str) -> tuple[str, str, str]:
    m = _FILENAME_RE.match(name)
    if not m:
        raise QmtSchemaError(f"文件名不符合 QMT 规则: {name!r}")
    return m["code"], m["name"], _LABEL_TO_PERIOD[m["label"]]

def parse_qmt_csv(path: Path, src_period: str) -> pd.DataFrame:
    df = pd.read_csv(path, encoding="utf-8-sig")   # utf-8-sig 剥 BOM
    missing = [c for c in _QMT_COLUMNS if c not in df.columns]
    if missing:
        raise QmtSchemaError(f"QMT CSV 缺必需列: {missing}")
    df = df.rename(columns={"time": "datetime"})
    df["datetime"] = parse_qmt_datetime(df["datetime"], src_period)
    return df[["datetime", "open", "high", "low", "close", "volume", "amount"]]
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_normalize.py -v`
Expected: PASS（7 passed）

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_normalize.py backend/tests/test_qmt_normalize.py
git commit -m "feat(qmt): parse_qmt_csv(剥 BOM) + parse_qmt_filename(三市场/全角名)"
```

---

## Phase 2 — 合成层 `qmt_resample`

### Task 3: `resample_intraday`（按交易时段分桶 + golden 成员）

**Files:**
- Create: `backend/qmt_resample.py`
- Test: `backend/tests/test_qmt_resample.py`

**Interfaces:**
- Consumes: `trading_date`（Task 1）。
- Produces: `resample_intraday(df_1m: pd.DataFrame, minutes: int) -> pd.DataFrame` —— `df_1m` 列 `datetime`(Unix 秒)/OHLC/`volume`/`amount`；`minutes ∈ {3,15,60}`；返回列同 + `datetime`=桶收盘时刻 Unix 秒。**每桶实测 1m 成员数须 == 应有数**，否则该桶所属**交易日整日**不产出（由 `compute_dense_coverage` Task 5 统一判/drop；本函数只做纯分桶聚合，成员不足的桶仍聚合出来、由上层丢日）。

**分桶规则（spec §4.2 逐字）**：段名义起点上午 `09:30`、下午 `13:00`；周期 `N` 桶 label = 起点 + k·N（`k=1..120/N`）。成员按 1m 收盘 `t`（沪 wall-clock）：**上午首桶** `label=0930+N`、区间 `[0930, 0930+N]`（含 09:30 集竞）；**其余桶** `label=b`、区间 `(b−N, b]`。聚合：open=首成员 open、close=尾成员 close、high=max、low=min、volume=Σ、amount=Σ（成员按时间序）。

- [ ] **Step 1: 写失败测试**（用合成的完整一日 241 根，断言 golden 边界桶）

```python
# backend/tests/test_qmt_resample.py
from __future__ import annotations
import datetime as dt
import pandas as pd
from zoneinfo import ZoneInfo
from qmt_resample import resample_intraday

SH = ZoneInfo("Asia/Shanghai")

def _ep(hhmm: int, day=(2026, 7, 3)) -> int:
    h, m = divmod(hhmm, 100)
    return int(dt.datetime(*day, h, m, 0, tzinfo=SH).timestamp())

def _full_day_1m() -> pd.DataFrame:
    """完整交易日 241 根：0930..1130(121) + 1301..1500(120)。close=递增序号便于定位。"""
    times = []
    t = 930
    while t <= 1130:                       # 上午 121
        times.append(t); m = t % 100; t = t + (1 if m < 59 else 41)
    t = 1301
    while t <= 1500:                       # 下午 120
        times.append(t); m = t % 100; t = t + (1 if m < 59 else 41)
    rows = [{"datetime": _ep(hh), "open": float(i), "high": float(i) + 0.5,
             "low": float(i) - 0.5, "close": float(i), "volume": 1, "amount": 1.0}
            for i, hh in enumerate(times)]
    return pd.DataFrame(rows)

def test_intraday_full_day_totals():
    df = _full_day_1m()
    assert len(resample_intraday(df, 3)) == 80
    assert len(resample_intraday(df, 15)) == 16
    assert len(resample_intraday(df, 60)) == 4

def test_intraday_3m_first_bucket_includes_open_auction():
    df = _full_day_1m()
    out = resample_intraday(df, 3).sort_values("datetime").reset_index(drop=True)
    # 上午首桶 label=0933，成员 {0930,0931,0932,0933}=4 根 → open=首成员 open(=idx0 的 open=0.0)
    first = out.iloc[0]
    assert first["datetime"] == _ep(933)
    assert first["open"] == 0.0                      # 09:30 集竞根 open
    assert first["close"] == 3.0                     # 0933 根 close（成员序号 0,1,2,3）
    assert first["volume"] == 4                       # 4 根 1m

def test_intraday_no_cross_lunch():
    df = _full_day_1m()
    out = resample_intraday(df, 60).sort_values("datetime").reset_index(drop=True)
    labels = [dt.datetime.fromtimestamp(x, SH).strftime("%H%M") for x in out["datetime"]]
    assert labels == ["1030", "1130", "1400", "1500"]  # 4 桶、午休不并
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_resample.py -v`
Expected: FAIL（`ModuleNotFoundError: No module named 'qmt_resample'`）

- [ ] **Step 3: 写最小实现**

```python
# backend/qmt_resample.py
"""QMT 合成层（纯函数）。Spec: 2026-07-06-qmt-data-ingestion-pilot-design.md §4.2。"""
from __future__ import annotations
import datetime as _dt
from zoneinfo import ZoneInfo
import pandas as pd
from qmt_normalize import trading_date

_SH = ZoneInfo("Asia/Shanghai")
# 段名义起点（分钟数，自 00:00 起算）与每段时长
_MORNING_START = 9 * 60 + 30    # 09:30
_AFTERNOON_START = 13 * 60      # 13:00
_SESSION_MINUTES = 120

def _mins_of_day(epoch: int) -> int:
    t = _dt.datetime.fromtimestamp(epoch, _SH)
    return t.hour * 60 + t.minute

def _bucket_label_minute(close_min: int, minutes: int) -> int | None:
    """1m 收盘分钟(自 00:00) → 其所属桶的 label 分钟；跨午休/盘外返回 None。"""
    for start in (_MORNING_START, _AFTERNOON_START):
        lo, hi = start, start + _SESSION_MINUTES
        if start <= close_min <= hi:
            # 上午首桶含左端点 start（集竞）；其余桶 (b-N, b]
            k = max(1, -(-(close_min - start) // minutes))  # ceil，但 close_min==start → k=1
            if close_min == start:
                k = 1
            return start + k * minutes
    return None

def _agg(members: pd.DataFrame) -> dict:
    m = members.sort_values("datetime")
    return {"open": float(m.iloc[0]["open"]), "close": float(m.iloc[-1]["close"]),
            "high": float(m["high"].max()), "low": float(m["low"].min()),
            "volume": int(m["volume"].sum()), "amount": float(m["amount"].sum())}

def resample_intraday(df_1m: pd.DataFrame, minutes: int) -> pd.DataFrame:
    if df_1m.empty:
        return df_1m.copy()
    df = df_1m.copy()
    df["_date"] = df["datetime"].map(trading_date)
    df["_cm"] = df["datetime"].map(_mins_of_day)
    df["_label_min"] = df["_cm"].map(lambda c: _bucket_label_minute(c, minutes))
    df = df[df["_label_min"].notna()]
    out_rows = []
    for (d, lm), grp in df.groupby(["_date", "_label_min"]):
        h, mnt = divmod(int(lm), 60)
        label_epoch = int(_dt.datetime(d.year, d.month, d.day, h, mnt, 0, tzinfo=_SH).timestamp())
        out_rows.append({"datetime": label_epoch, **_agg(grp)})
    return pd.DataFrame(out_rows).sort_values("datetime").reset_index(drop=True)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_resample.py -v`
Expected: PASS（4 passed）

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_resample.py backend/tests/test_qmt_resample.py
git commit -m "feat(qmt): resample_intraday(按交易时段分桶, golden 80/16/4)"
```

### Task 4: `resample_calendar`（日历分组 + 只发完整周期 + OPEN 标签 + 边界哨兵）

**Files:**
- Modify: `backend/qmt_resample.py`
- Test: `backend/tests/test_qmt_resample.py`

**Interfaces:**
- Consumes: `trading_date`。
- Produces:
  - `resample_calendar(df_daily: pd.DataFrame, rule: str) -> pd.DataFrame` —— `rule ∈ {"weekly","monthly"}`；**只 emit 完整日历周期**（存在属于该周期之后的 daily bar 才 emit）；bar `datetime` = **组内首交易日午夜**（OPEN 标签）；聚合同 intraday。
  - `period_boundaries(df_daily: pd.DataFrame, rule: str) -> list[int]` —— 每周期首交易日午夜 Unix 秒**含当前 partial 周期的哨兵**（供 B2 `after_end`）；**≠ emit 的 bar**。

**分组键（spec §4.2/R8-F1）**：`weekly` = `trading_date` 的 ISO (year, week)；`monthly` = `(year, month)`。

- [ ] **Step 1: 写失败测试**

```python
# 追加到 backend/tests/test_qmt_resample.py
from qmt_resample import resample_calendar, period_boundaries

def _daily(dates: list[tuple[int,int,int]]) -> pd.DataFrame:
    rows = [{"datetime": int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp()),
             "open": float(i), "high": float(i)+1, "low": float(i)-1, "close": float(i)+0.5,
             "volume": 10, "amount": 100.0} for i,(y,mo,d) in enumerate(dates)]
    return pd.DataFrame(rows)

def test_monthly_only_complete_periods_drops_export_month():
    # 2026-05, 2026-06 完整（有后续月），2026-07 是 export 当月 partial（无后续月）→ 不 emit
    df = _daily([(2026,5,4),(2026,5,29),(2026,6,1),(2026,6,30),(2026,7,1),(2026,7,3)])
    out = resample_calendar(df, "monthly").sort_values("datetime").reset_index(drop=True)
    months = [dt.datetime.fromtimestamp(x, SH).strftime("%Y%m") for x in out["datetime"]]
    assert months == ["202605", "202606"]     # 202607 partial 不发

def test_monthly_open_label_is_first_trading_day_midnight():
    df = _daily([(2026,5,4),(2026,5,29),(2026,6,1),(2026,6,30)])
    out = resample_calendar(df, "monthly").sort_values("datetime").reset_index(drop=True)
    first = out.iloc[0]
    assert first["datetime"] == int(dt.datetime(2026,5,4,0,0,0,tzinfo=SH).timestamp())  # 5月首交易日午夜
    assert first["open"] == 0.0   # 组内首日 open

def test_period_boundaries_include_partial_sentinel():
    # 边界序列含 202607 哨兵（即使其 bar 不 emit），供 after_end 用
    df = _daily([(2026,5,4),(2026,6,1),(2026,7,1)])
    bounds = period_boundaries(df, "monthly")
    labels = [dt.datetime.fromtimestamp(x, SH).strftime("%Y%m") for x in bounds]
    assert labels == ["202605", "202606", "202607"]   # 含 partial 当月哨兵
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_resample.py -v`
Expected: FAIL（`ImportError: cannot import name 'resample_calendar'`）

- [ ] **Step 3: 写最小实现**

```python
# 追加到 backend/qmt_resample.py
def _period_key(d, rule: str):
    if rule == "weekly":
        iso = d.isocalendar()
        return (iso[0], iso[1])
    return (d.year, d.month)      # monthly

def _first_day_midnight_epoch(d) -> int:
    return int(_dt.datetime(d.year, d.month, d.day, 0, 0, 0, tzinfo=_SH).timestamp())

def period_boundaries(df_daily: pd.DataFrame, rule: str) -> list[int]:
    """每周期首交易日午夜 Unix 秒（含当前 partial 周期哨兵；≠ emit 的 bar）。"""
    dates = sorted({trading_date(e) for e in df_daily["datetime"]})
    bounds, seen = [], set()
    for d in dates:
        k = _period_key(d, rule)
        if k not in seen:
            seen.add(k); bounds.append(_first_day_midnight_epoch(d))
    return bounds

def resample_calendar(df_daily: pd.DataFrame, rule: str) -> pd.DataFrame:
    if df_daily.empty:
        return df_daily.copy()
    df = df_daily.copy()
    df["_d"] = df["datetime"].map(trading_date)
    df["_k"] = df["_d"].map(lambda d: _period_key(d, rule))
    all_keys = sorted(set(df["_k"]))
    complete_keys = set(all_keys[:-1])   # 除最后一个周期（当前 partial，无后续周期）外都完整
    out_rows = []
    for k, grp in df.groupby("_k"):
        if k not in complete_keys:
            continue
        first_d = min(grp["_d"])
        out_rows.append({"datetime": _first_day_midnight_epoch(first_d), **_agg(grp)})
    return pd.DataFrame(out_rows).sort_values("datetime").reset_index(drop=True)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_resample.py -v`
Expected: PASS（7 passed）

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_resample.py backend/tests/test_qmt_resample.py
git commit -m "feat(qmt): resample_calendar(只发完整周期+OPEN标签) + period_boundaries(含哨兵)"
```

---

## Phase 3 — 完整性 + 双源对账

### Task 5: `compute_dense_coverage`（分钟级完整性 → drop 整日 + 覆盖 artifact）

**Files:**
- Modify: `backend/qmt_resample.py`
- Test: `backend/tests/test_qmt_resample.py`

**Interfaces:**
- Consumes: `trading_date`。
- Produces: `compute_dense_coverage(df_1m: pd.DataFrame) -> DenseCoverage`，其中
  ```python
  @dataclass
  class DenseCoverage:
      complete_dates: list[datetime.date]   # 每交易日恰 241 根 1m 的日期（升序）
      dropped_dates: list[datetime.date]    # 有 1m 但根数≠241 的日期（内部洞/边界 partial）
      start_date: datetime.date | None      # complete_dates 首
      end_date: datetime.date | None        # complete_dates 末
  ```
  语义（spec §4.2 R4-F1/R9-F2/R13-F2）：**每存在的交易日 1m 精确 epoch 集 == canonical 241（含秒）才完整、否则整日 dropped**（不半发桶）。`complete_dates` 供 B2 `dense_dates`（Plan 2 写 `stock_coverage`）。
  - `build_intraday(df_1m) -> tuple[dict[str,pd.DataFrame], DenseCoverage]`（**安全入口，codex PF1-R4-F1**）：resample 3m/15m/60m 后**只保留 `complete_dates` 的桶**（损坏/partial 日整日 drop），返回 `({"3m":..,"15m":..,"60m":..}, coverage)`。**写库调用方必须用本入口**（非直接 `resample_intraday`），杜绝半日 partial 桶入 PG。

- [ ] **Step 1: 写失败测试**

```python
# 追加到 backend/tests/test_qmt_resample.py
from qmt_resample import compute_dense_coverage

def _day_1m(day, n=241) -> list[dict]:
    """某日前 n 根 1m（n=241 完整；<241 模拟缺分钟）。close=1 占位。"""
    times = []
    t = 930
    while t <= 1130:
        times.append(t); m = t%100; t = t + (1 if m<59 else 41)
    t = 1301
    while t <= 1500:
        times.append(t); m = t%100; t = t + (1 if m<59 else 41)
    times = times[:n]
    return [{"datetime": _ep(hh, day), "open":1.0,"high":1.0,"low":1.0,"close":1.0,
             "volume":1,"amount":1.0} for hh in times]

def test_dense_coverage_complete_days_only():
    rows = _day_1m((2026,7,1)) + _day_1m((2026,7,2)) + _day_1m((2026,7,3))
    cov = compute_dense_coverage(pd.DataFrame(rows))
    assert cov.complete_dates == [dt.date(2026,7,1), dt.date(2026,7,2), dt.date(2026,7,3)]
    assert cov.dropped_dates == []
    assert (cov.start_date, cov.end_date) == (dt.date(2026,7,1), dt.date(2026,7,3))

def test_dense_coverage_drops_partial_day_whole():
    # 7-2 缺 1 根(240) → 整日 dropped、不进 complete
    rows = _day_1m((2026,7,1)) + _day_1m((2026,7,2), n=240) + _day_1m((2026,7,3))
    cov = compute_dense_coverage(pd.DataFrame(rows))
    assert dt.date(2026,7,2) not in cov.complete_dates
    assert dt.date(2026,7,2) in cov.dropped_dates
    assert cov.complete_dates == [dt.date(2026,7,1), dt.date(2026,7,3)]

def test_dense_coverage_rejects_dup_plus_missing_still_241():
    # 行数仍=241 但 11:30 缺失、09:31 重复 → 时间戳集≠期望 → 不 dense（codex PF1-F1）
    df = pd.DataFrame(_day_1m((2026,7,1)))
    df = df[df["datetime"] != _ep(1130)]                       # 去 11:30 → 240
    df = pd.concat([df, df[df["datetime"] == _ep(931)]], ignore_index=True)  # 复制 09:31 → 241
    assert len(df) == 241
    cov = compute_dense_coverage(df)
    assert dt.date(2026,7,1) in cov.dropped_dates and dt.date(2026,7,1) not in cov.complete_dates

def test_dense_coverage_rejects_out_of_session_row_still_241():
    # 241 根但一根落盘外(11:31)替掉盘内 11:30 → 不 dense
    df = pd.DataFrame(_day_1m((2026,7,1)))
    df.loc[df["datetime"] == _ep(1130), "datetime"] = _ep(1131)   # 11:30 → 11:31(盘外)
    assert len(df) == 241
    cov = compute_dense_coverage(df)
    assert dt.date(2026,7,1) in cov.dropped_dates

def test_dense_coverage_rejects_nonzero_seconds_still_241():
    # 241 根但 09:30:00 → 09:30:30（分钟相同、epoch 不同）→ 不 dense（codex PF1-R3-F1）
    df = pd.DataFrame(_day_1m((2026,7,1)))
    df.loc[df["datetime"] == _ep(930), "datetime"] = _ep(930) + 30
    assert len(df) == 241
    cov = compute_dense_coverage(df)
    assert dt.date(2026,7,1) in cov.dropped_dates

def test_build_intraday_drops_partial_day_from_all_periods():
    # 安全入口：240 根的 7-2 → 三周期该日均 0 桶（codex PF1-R4-F1）
    from qmt_resample import build_intraday
    rows = _day_1m((2026,7,1)) + _day_1m((2026,7,2), n=240) + _day_1m((2026,7,3))
    windows, cov = build_intraday(pd.DataFrame(rows))
    assert dt.date(2026,7,2) not in cov.complete_dates
    for p in ("3m", "15m", "60m"):
        got = {trading_date(e) for e in windows[p]["datetime"]}
        assert dt.date(2026,7,2) not in got            # 损坏日 → 0 桶
        assert {dt.date(2026,7,1), dt.date(2026,7,3)} <= got
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_resample.py -v`
Expected: FAIL（`ImportError: cannot import name 'compute_dense_coverage'`）

- [ ] **Step 3: 写最小实现**

```python
# 追加到 backend/qmt_resample.py（文件顶部 import 处补 dataclass/date）
from dataclasses import dataclass, field
import datetime  # 若已有则忽略

def _expected_session_minutes() -> list[int]:
    """完整日精确 session 分钟集（自 00:00 起算）：0930..1130(121) + 1301..1500(120)=241。"""
    mins = list(range(9*60+30, 11*60+30 + 1)) + list(range(13*60+1, 15*60+0 + 1))
    return sorted(mins)

_EXPECTED_SORTED = _expected_session_minutes()   # 241 个唯一分钟值（升序）

def _expected_day_epochs(d) -> list[int]:
    """某交易日的精确 241 个 canonical epoch（session 分钟 + SS=00，Asia/Shanghai）。"""
    out = []
    for m in _EXPECTED_SORTED:
        h, mi = divmod(m, 60)
        out.append(int(_dt.datetime(d.year, d.month, d.day, h, mi, 0, tzinfo=_SH).timestamp()))
    return sorted(out)

@dataclass
class DenseCoverage:
    complete_dates: list
    dropped_dates: list
    start_date: object = None
    end_date: object = None

def compute_dense_coverage(df_1m: pd.DataFrame) -> DenseCoverage:
    """dense = 某交易日 1m **精确 epoch 集**（含秒）== canonical 241 epoch（codex PF1-F1/PF1-R3）——
    比对 epoch（非分钟）：`09:30:30` 替 `09:30:00` 分钟同但 epoch 不同 → drop；重复/缺失/盘外同样抓。"""
    if df_1m.empty:
        return DenseCoverage([], [], None, None)
    df = df_1m.copy()
    df["_d"] = df["datetime"].map(trading_date)
    complete, dropped = [], []
    for d, g in df.groupby("_d"):
        actual = sorted(int(e) for e in g["datetime"])
        (complete if actual == _expected_day_epochs(d) else dropped).append(d)
    complete.sort(); dropped.sort()
    return DenseCoverage(complete, dropped,
                         complete[0] if complete else None,
                         complete[-1] if complete else None)

def build_intraday(df_1m: pd.DataFrame):
    """**安全入口（codex PF1-R4-F1）**：resample 3m/15m/60m 并**只保留 dense 完整日的桶**
    （非 dense 日整日 drop，含损坏/边界 partial），返回 `(windows: dict[str,DataFrame], DenseCoverage)`。
    **写库调用方必须用本入口**（而非直接 resample_intraday），杜绝半日 partial 桶入 PG。"""
    cov = compute_dense_coverage(df_1m)
    dense = set(cov.complete_dates)
    windows = {}
    for period, minutes in (("3m", 3), ("15m", 15), ("60m", 60)):
        df = resample_intraday(df_1m, minutes)
        if not df.empty:
            df = df[df["datetime"].map(lambda e: trading_date(e) in dense)].reset_index(drop=True)
        windows[period] = df
    return windows, cov
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_resample.py -v`
Expected: PASS（9 passed）

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_resample.py backend/tests/test_qmt_resample.py
git commit -m "feat(qmt): compute_dense_coverage(缺分钟→drop整日, 覆盖 artifact)"
```

### Task 6: `reconcile_sources`（D10 双源对账：端点 + 日期集 + OHLCV）

**Files:**
- Modify: `backend/qmt_resample.py`
- Test: `backend/tests/test_qmt_resample.py`

**Interfaces:**
- Consumes: `trading_date`, `compute_dense_coverage`。
- Produces: `reconcile_sources(df_1m, df_daily, *, status_1m="ok", status_daily="ok", price_rtol=1e-6) -> ReconcileResult`（含 D10(a) export_log status 门）：
  ```python
  @dataclass
  class ReconcileResult:
      ok: bool
      reason: str    # "" | "daily_not_cover_dense" | "date_set_mismatch" | "ohlcv_mismatch"
  ```
  三门（spec §4.1 D10 / R6-F2/R10-F1/R11-F1）：(b) **端点覆盖**——`日线起 ≤ dense-1m 起 且 日线止 ≥ dense-1m 止`；(c) **对称日期集**——dense-1m 跨度内 dense-1m 日期集 == 日线日期集；(d) **OHLCV 容差**——每 dense 日 1m 聚合 OHLCV vs 日线 bar（价格相对 `price_rtol`、volume/amount 相等）。

- [ ] **Step 1: 写失败测试**

```python
# 追加到 backend/tests/test_qmt_resample.py
from qmt_resample import reconcile_sources

def _daily_from_1m(rows_1m: list[dict]) -> pd.DataFrame:
    """由 1m 聚合出一致的日线（open=首/close=尾/high=max/low=min/vol,amt=Σ）。"""
    df = pd.DataFrame(rows_1m); df["_d"] = df["datetime"].map(trading_date)
    out = []
    for d, g in df.groupby("_d"):
        g = g.sort_values("datetime")
        out.append({"datetime": int(dt.datetime(d.year,d.month,d.day,0,0,0,tzinfo=SH).timestamp()),
                    "open": g.iloc[0]["open"], "high": g["high"].max(), "low": g["low"].min(),
                    "close": g.iloc[-1]["close"], "volume": int(g["volume"].sum()),
                    "amount": float(g["amount"].sum())})
    return pd.DataFrame(out)

def test_reconcile_ok_when_consistent():
    r1 = _day_1m((2026,7,1)) + _day_1m((2026,7,2))
    res = reconcile_sources(pd.DataFrame(r1), _daily_from_1m(r1))
    assert res.ok and res.reason == ""

def test_reconcile_fail_stale_daily_tail():
    r1 = _day_1m((2026,7,1)) + _day_1m((2026,7,2))
    daily = _daily_from_1m(_day_1m((2026,7,1)))   # 日线只到 7-1，尾部截断（比 1m 旧）
    res = reconcile_sources(pd.DataFrame(r1), daily)
    assert not res.ok and res.reason == "daily_not_cover_dense"

def test_reconcile_fail_ohlcv_mismatch():
    r1 = _day_1m((2026,7,1))
    daily = _daily_from_1m(r1); daily.loc[0, "close"] = daily.loc[0, "close"] + 5.0  # 篡改 close
    res = reconcile_sources(pd.DataFrame(r1), daily)
    assert not res.ok and res.reason == "ohlcv_mismatch"

def test_reconcile_fail_when_export_log_not_ok():
    # export_log status 非 'ok' → fail-closed（即使 df 内部自洽，codex PF1-R8-F2）
    r1 = _day_1m((2026,7,1)); daily = _daily_from_1m(r1)
    assert reconcile_sources(pd.DataFrame(r1), daily, status_1m="error").reason == "export_log_not_ok"
    assert reconcile_sources(pd.DataFrame(r1), daily, status_daily="empty").reason == "export_log_not_ok"
    assert reconcile_sources(pd.DataFrame(r1), daily, status_1m="ok", status_daily="ok").ok is True
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_resample.py -v`
Expected: FAIL（`ImportError: cannot import name 'reconcile_sources'`）

- [ ] **Step 3: 写最小实现**

```python
# 追加到 backend/qmt_resample.py
import math

@dataclass
class ReconcileResult:
    ok: bool
    reason: str = ""

def reconcile_sources(df_1m: pd.DataFrame, df_daily: pd.DataFrame, *,
                      status_1m: str = "ok", status_daily: str = "ok",
                      price_rtol: float = 1e-6) -> ReconcileResult:
    # D10 (a) export_log status 门（codex PF1-R8-F2）：任一文件非 'ok' → fail-closed
    if status_1m != "ok" or status_daily != "ok":
        return ReconcileResult(False, "export_log_not_ok")
    cov = compute_dense_coverage(df_1m)
    if not cov.complete_dates:
        return ReconcileResult(False, "no_dense_1m")
    daily_dates = sorted({trading_date(e) for e in df_daily["datetime"]})
    if not daily_dates or daily_dates[0] > cov.start_date or daily_dates[-1] < cov.end_date:
        return ReconcileResult(False, "daily_not_cover_dense")          # 端点覆盖
    dense = set(cov.complete_dates)
    daily_in_span = {d for d in daily_dates if cov.start_date <= d <= cov.end_date}
    if dense != daily_in_span:
        return ReconcileResult(False, "date_set_mismatch")              # 对称日期集
    # OHLCV 对账
    d1 = df_1m.copy(); d1["_d"] = d1["datetime"].map(trading_date)
    dly = df_daily.copy(); dly["_d"] = dly["datetime"].map(trading_date)
    dly_by = {r["_d"]: r for _, r in dly.iterrows()}
    for d, g in d1.groupby("_d"):
        if d not in dense:
            continue
        g = g.sort_values("datetime"); b = dly_by[d]
        agg = {"open": g.iloc[0]["open"], "close": g.iloc[-1]["close"],
               "high": g["high"].max(), "low": g["low"].min(),
               "volume": int(g["volume"].sum()), "amount": float(g["amount"].sum())}
        for k in ("open", "high", "low", "close"):
            if not math.isclose(float(agg[k]), float(b[k]), rel_tol=price_rtol):
                return ReconcileResult(False, "ohlcv_mismatch")
        if int(agg["volume"]) != int(b["volume"]) or not math.isclose(
                float(agg["amount"]), float(b["amount"]), rel_tol=1e-6):
            return ReconcileResult(False, "ohlcv_mismatch")
    return ReconcileResult(True, "")
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_resample.py -v`
Expected: PASS（12 passed）

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_resample.py backend/tests/test_qmt_resample.py
git commit -m "feat(qmt): reconcile_sources(D10 三门: 端点覆盖+对称日期集+OHLCV容差)"
```

---

## Phase 4 — B2 纯选择逻辑（`generate_training_sets.py`）

> 说明：以下均为**纯函数**（不碰 PG）。现有 `generate_training_sets.py` 已有纯装配层；新增/改这些纯函数，DB 壳（读 `stock_coverage`、写库）在 Plan 2。

### Task 7: `compute_after_end` + `select_period_window`（纳入规则）+ `eligible_start_indices`/`select_valid_window`（候选迭代+有界重试）+ `per_day_intraday_complete`

**Files:**
- Modify: `backend/generate_training_sets.py`
- Test: `backend/tests/test_generate_training_sets.py`

**Interfaces:**
- Produces（均纯函数）：
  - `compute_after_end(month_boundaries: list[int], start_idx: int, months: int = 8) -> int` = `month_boundaries[start_idx + months] - 1`（第 `months` 完整月月末；`months` 默认 8，单测可缩小）。
  - `eligible_start_indices(month_boundaries, rng, *, dense_dates, trading_dates) -> list[int]`：候选下标 `[30, len-9]` **随机序**中，保留「`start`→`after_end` 之间该股交易日历（`trading_dates`）里每个交易日 ∈ `dense_dates`」的**全部候选**（**按交易日遍历、非日历日**，周末/假期不误拒；codex PF1-F2）；月边界 <39 抛 `GenerateSkipException`。
  - `select_valid_window(month_boundaries, rng, *, dense_dates, trading_dates, try_assemble, max_retries=8) -> tuple[int, object]`：**bounded candidate retry**（codex R12-F2/PF1-R3）——逐个 eligible 候选（随机序）调 `try_assemble(start_datetime)`；**返回首个不抛的 `(start_datetime, 其返回值)`**；`try_assemble` 抛 `GenerateSkipException`（切窗 per-period 不足 / D9 硬门失败 / 起点唯一冲突）→ 自动试下一候选；穷尽 `max_retries`/无候选 → `GenerateSkipException`。回调注入使重试循环可独立单测，且让 DB 壳（Plan 2）把「切窗+D9+唯一性」组进 `try_assemble`。
  - `build_training_windows(period_bars, month_boundaries, rng, *, dense_dates, trading_dates, before_caps, months=8, intraday_expected=None, before_min=30, max_retries=8) -> tuple[int, dict[str,pd.DataFrame]]`：**生产纯入口（codex PF1-R6-F2）**——组合 `compute_after_end` / `select_period_window`(两侧周边界) / D6 per-period `before≥before_min & after≥1` / D9 `per_day_intraday_complete` + bounded retry；返回 `(start_datetime, windows)`。**Plan 2 的 `generate_one_training_set` 必须调本入口**（非旧 `select_start_index`/`monthly_after_end`），再做 SQLite/zip/register/起点唯一性。gate 参数（`months`/`intraday_expected`/`before_min`）可调 → 端到端小 fixture 单测（Task7 e2e 测证候选重试 + 尾日 D9）。
  - `select_period_window(bars, start_datetime, before_cap, after_end, period, month_boundaries=None) -> pd.DataFrame`：改纳入规则——**两侧周期边界校验**：forward 纳入整段 period-end ≤ after_end；weekly 额外——**after** 排除周末 > `after_end` 的 trailing 跨月周、**before** 排除周末 ≥ `start` 的**跨 start 周**（含 post-start 数据、防 before-context lookahead；codex PF1-R5）。月/日与边界天然对齐无 straddle。
  - `per_day_intraday_complete(windows: dict[str, pd.DataFrame], trading_dates: set[datetime.date], after_end: int, expected: dict[str,int] = {"3m":80,"15m":16,"60m":4}) -> bool`：D9 per-day 硬门——每个盘中周期在 `[该周期首选中日, trading_date(after_end)]` 内每交易日桶数精确 == 应有数；**终点用 `after_end`、非 `dates.max()`**（否则尾日盘中全缺漏检，codex PF1-R6-F1）；各周期各自校验（before-context 深度不同，PF1-R4-F2）；任一不符 → False。

- [ ] **Step 1: 写失败测试**

```python
# 追加到 backend/tests/test_generate_training_sets.py
import datetime as dt
from zoneinfo import ZoneInfo
import pandas as pd
import pytest
from generate_training_sets import (
    GenerateSkipException, compute_after_end, eligible_start_indices, select_valid_window,
    per_day_intraday_complete, build_training_windows,
)
SH = ZoneInfo("Asia/Shanghai")
def _mid(y,mo,d): return int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp())

def test_compute_after_end_is_ninth_boundary_minus_one():
    bounds = [_mid(2020,1,1) + i for i in range(20)]   # 占位单调
    assert compute_after_end(bounds, 3) == bounds[11] - 1   # start_idx+8=11

import random

def _weekday_trading_dates(d0: dt.date, d1: dt.date) -> set:
    """[d0,d1] 内工作日（周一~周五）当交易日历——含跨越的周末间隙。"""
    out, cur = set(), d0
    while cur <= d1:
        if cur.weekday() < 5:
            out.add(cur)
        cur += dt.timedelta(days=1)
    return out

def _n_month_boundaries(n: int) -> list:
    bounds, y, mo = [], 2020, 1
    for _ in range(n):
        bounds.append(_mid(y, mo, 1)); mo += 1
        if mo > 12: y += 1; mo = 1
    return bounds

def test_eligible_start_indices_returns_all_dense_candidates():
    # ≥39 月边界，trading_dates=全程工作日，dense=全部工作日 → 返回非空候选列表（不因周末误拒）
    bounds = _n_month_boundaries(44)
    trading = _weekday_trading_dates(dt.date(2020,1,1), dt.date(2023,12,31))
    dense = set(trading)
    idxs = eligible_start_indices(bounds, random.Random(0), dense_dates=dense, trading_dates=trading)
    assert idxs and all(30 <= i <= len(bounds) - 9 for i in idxs)

def test_eligible_start_indices_empty_when_no_dense():
    bounds = _n_month_boundaries(44)
    trading = _weekday_trading_dates(dt.date(2020,1,1), dt.date(2023,12,31))
    idxs = eligible_start_indices(bounds, random.Random(0), dense_dates=set(), trading_dates=trading)
    assert idxs == []      # 空 dense → 每候选窗口都有非-dense 交易日 → 无候选（n≥39 不抛）

def test_select_valid_window_retries_past_bad_candidate():
    # 注入 try_assemble：第一个被调的候选抛 skip（模拟 D9 漂移/切窗失败），之后成功 → 验证重试到下一候选
    bounds = _n_month_boundaries(44)
    trading = _weekday_trading_dates(dt.date(2020,1,1), dt.date(2023,12,31))
    dense = set(trading)
    calls = []
    def try_assemble(start):
        calls.append(start)
        if len(calls) == 1:
            raise GenerateSkipException("first candidate fails (D9 drift / per-period 不足)")
        return {"ok": start}
    start, result = select_valid_window(bounds, random.Random(0), dense_dates=dense,
                                        trading_dates=trading, try_assemble=try_assemble, max_retries=8)
    assert len(calls) == 2                 # 第一个失败、自动重试第二个
    assert result == {"ok": start}         # 返回第二个候选的组装结果（不因单坏候选放弃该股）

def _mk_bars(day, n):
    base = int(dt.datetime(*day, 9, 33, 0, tzinfo=SH).timestamp())
    return [{"datetime": base + i*180} for i in range(n)]   # 同日内、不跨日

def _ae(y,mo,d):  # after_end = 某日午夜（span 到该日）
    return int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp())

def test_per_day_intraday_complete_all_periods_hardgate():
    days = {dt.date(2026,7,1), dt.date(2026,7,2)}
    ae = _ae(2026,7,2)
    def _win(n3, n15, n60):
        return {"3m": pd.DataFrame(_mk_bars((2026,7,1),n3)+_mk_bars((2026,7,2),n3)),
                "15m": pd.DataFrame(_mk_bars((2026,7,1),n15)+_mk_bars((2026,7,2),n15)),
                "60m": pd.DataFrame(_mk_bars((2026,7,1),n60)+_mk_bars((2026,7,2),n60))}
    assert per_day_intraday_complete(_win(80,16,4), days, ae) is True
    assert per_day_intraday_complete(_win(80,15,4), days, ae) is False   # 3m 全但 15m 短 → False
    assert per_day_intraday_complete(_win(80,16,3), days, ae) is False   # 60m 短 → False
    assert per_day_intraday_complete(_win(79,16,4), days, ae) is False   # 3m 短 → False

def test_per_day_intraday_complete_catches_short_60m_before_context():
    # 60m 多一更早 before-context 日 D0 只 2 根 → 各周期按**自身跨度**校验 → False（codex PF1-R4-F2）
    D0, D1, D2 = (2026,6,30), (2026,7,1), (2026,7,2)
    trading = {dt.date(*D0), dt.date(*D1), dt.date(*D2)}; ae = _ae(2026,7,2)
    windows = {"3m": pd.DataFrame(_mk_bars(D1,80)+_mk_bars(D2,80)),
               "15m": pd.DataFrame(_mk_bars(D1,16)+_mk_bars(D2,16)),
               "60m": pd.DataFrame(_mk_bars(D0,2)+_mk_bars(D1,4)+_mk_bars(D2,4))}
    assert per_day_intraday_complete(windows, trading, ae) is False
    windows["60m"] = pd.DataFrame(_mk_bars(D0,4)+_mk_bars(D1,4)+_mk_bars(D2,4))
    assert per_day_intraday_complete(windows, trading, ae) is True

def test_per_day_intraday_complete_catches_missing_tail_day():
    # trading 含 D3, 但盘中都止于 D2; after_end 覆盖到 D3 → D3 在 span(0 桶) → False（codex PF1-R6-F1）
    D1, D2, D3 = (2026,7,1), (2026,7,2), (2026,7,3)
    trading = {dt.date(*D1), dt.date(*D2), dt.date(*D3)}; ae = _ae(2026,7,3)
    windows = {"3m": pd.DataFrame(_mk_bars(D1,80)+_mk_bars(D2,80)),   # 止于 D2
               "15m": pd.DataFrame(_mk_bars(D1,16)+_mk_bars(D2,16)),
               "60m": pd.DataFrame(_mk_bars(D1,4)+_mk_bars(D2,4))}
    assert per_day_intraday_complete(windows, trading, ae) is False   # D3 缺盘中 → False
    ae2 = _ae(2026,7,2)                                                # after_end 只到 D2 → 通过
    assert per_day_intraday_complete(windows, trading, ae2) is True

def test_build_training_windows_end_to_end_retries_on_tail_d9_fail():
    # 端到端生产入口（codex PF1-R6-F2）：months=1, 候选 {30(2022-07),31(2022-08)};
    # July 末交易日缺 3m → idx30 D9(尾日)失败 → 重试 idx31(Aug 完整)成功
    from generate_training_sets import build_training_windows
    bounds = _n_month_boundaries(33)      # 2020-01..2022-09 → month[30]=2022-07, [31]=2022-08
    tdays = [d for d in (dt.date(2022,6,1)+dt.timedelta(days=i) for i in range(120))
             if dt.date(2022,6,1) <= d <= dt.date(2022,8,31) and d.weekday() < 5]
    trading = set(tdays); dense = set(tdays)
    def _bars(days, n):
        rows = []
        for d in days:
            base = int(dt.datetime(d.year,d.month,d.day,9,33,0,tzinfo=SH).timestamp())
            rows += [{"datetime": base+i*180,"open":1.0,"high":1.0,"low":1.0,"close":1.0,
                      "volume":1,"amount":1.0} for i in range(n)]
        return pd.DataFrame(rows)
    july_early = min(d for d in tdays if d.month == 7)   # 早 July：在 idx30 forward 窗口内, 但不在 idx31 短 before-context 内
    pb = {"3m": _bars([d for d in tdays if d != july_early], 2),   # 早 July 日缺 3m
          "15m": _bars(tdays, 2), "60m": _bars(tdays, 1), "daily": _bars(tdays, 1)}
    caps = {"3m":2, "15m":2, "60m":2, "daily":2}         # **短 before-context**（codex PF1-R7）→ Aug 候选 before 不含 july_early
    start, windows = build_training_windows(
        pb, bounds, random.Random(0), dense_dates=dense, trading_dates=trading, before_caps=caps,
        months=1, intraday_expected={"3m":2,"15m":2,"60m":1}, before_min=1, max_retries=8)
    assert start == bounds[31]                       # idx30(July) forward 含 july_early 缺 3m→D9失败→idx31(Aug)成功
    assert {"3m","15m","60m","daily"} <= set(windows)
    # 双检（codex PF1-R7）：成功候选的盘中窗口确实过 per_day D9
    ae31 = compute_after_end(bounds, bounds.index(bounds[31]), months=1)
    assert per_day_intraday_complete({p: windows[p] for p in ("3m","15m","60m")}, trading, ae31,
                                     {"3m":2,"15m":2,"60m":1}) is True
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_generate_training_sets.py -v`
Expected: FAIL（`ImportError: cannot import name 'compute_after_end'`）

- [ ] **Step 3: 写最小实现**

```python
# 追加到 backend/generate_training_sets.py（import 处补：import datetime as _dt; from zoneinfo import ZoneInfo; from qmt_normalize import trading_date）
_SH_B2 = ZoneInfo("Asia/Shanghai")

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
                        try_assemble, max_retries: int = 8, months: int = 8):
    """bounded candidate retry（codex R12-F2/PF1-R3-F2）：逐 eligible 候选调 try_assemble(start)；
    首个不抛的返回 (start, 其返回值)；抛 GenerateSkipException → 试下一个；穷尽 → skip。"""
    cands = eligible_start_indices(month_boundaries, rng, dense_dates=dense_dates,
                                   trading_dates=trading_dates, months=months)
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
                           before_min: int = 30, max_retries: int = 8):
    """**生产纯入口（codex PF1-R6-F2）**：组合 compute_after_end / select_period_window(两侧周边界) /
    D6 per-period before-after / D9 per_day 硬门 + bounded retry。返回 `(start_datetime, windows)`。
    **Plan 2 的 `generate_one_training_set` 必须调本入口**（而非旧 select_start_index/monthly_after_end），
    再做 SQLite/zip/register/起点唯一性。gate 参数（`months`/`intraday_expected`/`before_min`）可调以便端到端单测。"""
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
        if not per_day_intraday_complete(intraday, trading_dates, after_end, intraday_expected):
            raise GenerateSkipException("D9 per-day 硬门失败")
        return windows
    return select_valid_window(month_boundaries, rng, dense_dates=dense_dates, trading_dates=trading_dates,
                               try_assemble=_try, max_retries=max_retries, months=months)

def per_day_intraday_complete(windows, trading_dates, after_end, expected=None) -> bool:
    """D9 per-day 硬门（codex PF1-R2/PF1-R4-F2/PF1-R6-F1）：**每个盘中周期**在
    `[该周期首选中日, trading_date(after_end)]` 内、每个交易日（∈ trading_dates）桶数精确 == 应有数
    （3m=80/15m=16/60m=4）。**跨度终点用 `after_end`、非 `dates.max()`**——否则 after_end 附近盘中全缺的
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
        if not all(counts.get(d, 0) == need for d in span):
            return False
    return True
```

> 注：`eligible_start_indices`/`select_valid_window` 的 `rng` 用 `random.Random`（`.shuffle`）。`select_period_window` 的 weekly-straddle 排除在下一步补测试落地。`select_valid_window` 用注入的 `try_assemble` 回调（重试循环可独立单测）；真实 `try_assemble` 组装在 Plan 2。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_generate_training_sets.py -v`
Expected: PASS（3 passed）

- [ ] **Step 5: 写 `select_period_window` 纳入规则的失败测试**

```python
# 追加到 backend/tests/test_generate_training_sets.py
from generate_training_sets import select_period_window

def test_period_window_excludes_bar_whose_period_exceeds_after_end():
    # monthly bars 在 [start, after_end] 内，最后一根 open==after_end+? 的排除；此处验月界对齐 8 根
    # 构造 3m/日/月 简化：仅验 weekly straddle 排除（周末 > after_end）
    # weekly bars（open=周一午夜），after_end 落在某周中 → 该周（周末> after_end）被排除
    def _w(y,mo,d): return int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp())
    bars = pd.DataFrame([{"datetime": _w(2026,6,1),"open":1,"high":1,"low":1,"close":1,"volume":1,"amount":1},
                         {"datetime": _w(2026,6,8),"open":2,"high":2,"low":2,"close":2,"volume":1,"amount":1},
                         {"datetime": _w(2026,6,29),"open":3,"high":3,"low":3,"close":3,"volume":1,"amount":1}])
    start = _w(2026,6,1); after_end = _w(2026,7,1) - 1   # 6/29 那周跨到 7 月 → 排除
    out = select_period_window(bars, start, before_cap=150, after_end=after_end, period="weekly")
    got = sorted(dt.datetime.fromtimestamp(x, SH).strftime("%m%d") for x in out["datetime"])
    assert "0629" not in got     # 跨月界 trailing 周被排除

def test_period_window_excludes_start_straddling_weekly_before_context():
    # start=周三 2026-07-01；周 bar 2026-06-29(Mon, 含 7/1-7/3 post-start) 不得作 before-context（codex PF1-R5：防 lookahead）
    def _w(y,mo,d): return int(dt.datetime(y,mo,d,0,0,0,tzinfo=SH).timestamp())
    bars = pd.DataFrame([
        {"datetime": _w(2026,6,15),"open":1,"high":1,"low":1,"close":1,"volume":1,"amount":1},  # 完整过去周(end 6/21)
        {"datetime": _w(2026,6,22),"open":2,"high":2,"low":2,"close":2,"volume":1,"amount":1},  # 完整过去周(end 6/28)
        {"datetime": _w(2026,6,29),"open":3,"high":3,"low":3,"close":3,"volume":1,"amount":1},  # 跨 start 周(Mon 6/29, end 7/5)
        {"datetime": _w(2026,7,6),"open":4,"high":4,"low":4,"close":4,"volume":1,"amount":1},   # start 后完整周
    ])
    start = _w(2026,7,1); after_end = _w(2026,9,1) - 1
    out = select_period_window(bars, start, before_cap=150, after_end=after_end, period="weekly")
    got = {dt.datetime.fromtimestamp(x, SH).strftime("%m%d") for x in out["datetime"]}
    assert "0629" not in got                 # 跨 start 周（含 post-start 数据）不作 before-context
    assert "0622" in got and "0706" in got   # 完整过去周 + start 后周保留
```

- [ ] **Step 6: 改 `select_period_window` 纳入规则并跑测试通过**

在 `backend/generate_training_sets.py` 的 `select_period_window` 里，对 `period=="weekly"` **两侧都做周期边界校验**（codex PF1-R5）：**after** 段排除周末 `> trading_date(after_end)` 的 trailing 跨月周；**before** 段排除周末 `>= trading_date(start_datetime)` 的**跨 start 周**（其含 post-start 数据、作 before-context 会 lookahead）。实现：

```python
# 在 select_period_window 内，切出 before/after 后追加（period=="weekly" 分支）：
def _week_end_date(open_epoch):
    d = trading_date(open_epoch)
    return d + _dt.timedelta(days=(6 - d.weekday()))   # 该周周日
if period == "weekly":
    ae_date = trading_date(after_end)
    st_date = trading_date(start_datetime)
    after = after[after["datetime"].map(lambda e: _week_end_date(e) <= ae_date)]   # trailing 跨月周
    before = before[before["datetime"].map(lambda e: _week_end_date(e) < st_date)] # PF1-R5: 跨 start 周不作 before-context
```

Run: `cd backend && python -m pytest tests/test_generate_training_sets.py -k "period_window" -v`
Expected: PASS（2 passed）

- [ ] **Step 7: 全量回归 + 提交**

Run: `cd backend && python -m pytest tests/test_generate_training_sets.py -v`
Expected: PASS（现有测试 + 新增全绿）。**Task 8 会把公共装配入口 `assemble_training_set` 重接到 `build_training_windows` 并删旧选起点路径**（codex PF1-R8-F1：Plan 1 内即消除旧不安全路径，不推给 Plan 2）。

```bash
git add backend/generate_training_sets.py backend/tests/test_generate_training_sets.py
git commit -m "feat(b2): after_end 重定义 + 窗口纳入(周straddle) + eligible/select_valid_window(候选迭代+有界重试) + per-day硬门(3m/15m/60m)"
```

### Task 8: `assemble_training_set` 重接 `build_training_windows`（删旧选起点路径，codex PF1-R8-F1）

**Files:** Modify `backend/generate_training_sets.py` + `backend/tests/test_generate_training_sets.py`。

**Interfaces:** `assemble_training_set(output_dir, *, stock_code, stock_name, period_bars, month_boundaries, dense_dates, trading_dates, rng, months=8, intraday_expected=None, before_min=30) -> GeneratedTrainingSet` —— 内部走 `build_training_windows` -> `assign_global_indices` -> `build_training_set_sqlite` -> `zip_and_hash`；不再用旧 `select_start_index`/`monthly_after_end`。

- [ ] **Step 1: 写失败测试**（证明公共装配入口走新 D9 门——旧随机选起点不会因盘中不完整 skip）：`test_assemble_training_set_routes_through_d9_gate(tmp_path)`：33 月边界 + June–Aug 2022 工作日 dense/trading，`period_bars` 各周期每日仅 1 根 3m（应 2），`months=1, intraday_expected={"3m":2,"15m":1,"60m":1}, before_min=1` -> 全候选 D9 失败 -> `assemble_training_set(...)` 抛 `GenerateSkipException`（旧随机选起点不会抛）。fixture 与 `test_build_training_windows_end_to_end_*` 同构 + `tmp_path`。

- [ ] **Step 2: 跑测试确认失败** — `python -m pytest tests/test_generate_training_sets.py::test_assemble_training_set_routes_through_d9_gate -v` -> FAIL（旧签名无 `month_boundaries`/走旧路径不 raise）。

- [ ] **Step 3: 重接线 + 删旧**：把 `assemble_training_set` 里「`select_start_index` -> `monthly_after_end` -> 各周期 `select_period_window` + per-period 校验」整段换成 `build_training_windows(period_bars, month_boundaries, rng, dense_dates=dense_dates, trading_dates=trading_dates, before_caps=PERIOD_BEFORE_CAP, months=months, intraday_expected=intraday_expected, before_min=before_min)`（返回 `(start_datetime, windows)`）-> `assign_global_indices(windows)` -> `end_datetime = compute_after_end(month_boundaries, month_boundaries.index(start_datetime), months)` -> `build_training_set_sqlite`/`zip_and_hash`（现有函数不变）-> `GeneratedTrainingSet(...)`。**删除** `select_start_index`(旧)、`monthly_after_end` 及其旧专测（grep 定位删；新增 `eligible_start_indices`/`select_valid_window`/`build_training_windows` 测保留）。

- [ ] **Step 4: 跑测试确认通过** — `python -m pytest tests/test_generate_training_sets.py -v` -> PASS。
- [ ] **Step 5: 提交** — `git commit -m "feat(b2): assemble_training_set 重接 build_training_windows, 删旧随机选起点(PF1-R8-F1)"`

---

## Self-Review（对照 spec）

- **规整层**（§4.1）：BOM ✅(Task2) / 时区时间 ✅(Task1) / 文件名三市场+全角 ✅(Task2) / 缺列抛错 ✅(Task2)。`trading_date` 统一 ✅(Task1)。
- **合成层**（§4.2）：intraday golden 80/16/4 + 首桶含集竞 + 禁跨午休 ✅(Task3)；calendar 只发完整周期 + OPEN 标签 + 哨兵 ✅(Task4)；分钟级完整性(精确 epoch 含秒)drop 整日 + 覆盖 artifact + **安全入口 `build_intraday`（滤损坏日桶，PF1-R4-F1）** ✅(Task5)。
- **D10 对账**（§4.1）：端点+日期集+OHLCV 三门 ✅(Task6)。
- **B2 纯逻辑**（§4.4）：after_end=第8完整月末 ✅、窗口纳入**两侧**周边界校验(PF1-R5 无 lookahead) ✅、`eligible_start_indices` 按交易日历+dense ✅、`select_valid_window` 有界重试(R12-F2) ✅、per-day 硬门各周期自身跨度到 after_end(PF1-R6-F1) ✅、**`build_training_windows` 生产纯入口组合全部 gate + 端到端测(候选重试+尾日D9，PF1-R6-F2)** ✅(Task7)。
- **不在本 plan（→ Plan 2）**：schema/migration/CONTRACT_VERSION（§4.3 D1/D11 表）、import/generate DB 壳接线（D8a/D8b/写 klines+stock_coverage/读 dense_dates/file_path TEXT+cleanup/候选 retry 集成）、pilot（储备池/SMB/reset 护栏/市场地板）、容器化集成测试（§5 R15-F2）。
- **前复权精度**：本 plan 纯函数不 round OHLC ✅（`clean` 复用在 Plan 2 接线时验证）。
- **占位符扫描**：无 TBD/TODO；每步含真实测试+实现代码。
- **类型一致**：`DenseCoverage.complete_dates`(list[date]) → Plan 2 写 `stock_coverage.dropped_1m_dates`/`dense_1m_start/end_date`；`eligible_start_indices(...,dense_dates:set[date],trading_dates:set[date])->list[int]`、`select_valid_window(...,try_assemble)->(int, object)`、`per_day_intraday_complete(windows:dict[str,DataFrame],...)`；`compute_after_end(month_boundaries:list[int])` 与 `period_boundaries` 返回类型一致（list[int] Unix 秒）。

---

## Execution Handoff

见 skill 末尾选项（subagent-driven 推荐）。**Plan 2**（schema+DB壳+pilot+集成测试）在 Plan 1 落地 + codex review 后写。
