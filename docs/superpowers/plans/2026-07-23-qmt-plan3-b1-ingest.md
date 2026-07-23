# QMT Plan 3：B1 接规整/合成层 + 写 stock_coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 B1（`import_csv.py` 侧）接上 Plan 1 已 merge 但零调用方的 QMT 规整/合成层，导入时原子写入六周期 `klines` + `stock_coverage`，从而解除 B2/B4 恒产 0 的根因，并清掉 Plan 2b「coverage 与六周期 klines 无统一快照」残留。

**Architecture:** 新建纯装配层 `backend/qmt_ingest.py`（`parse_qmt_csv→QmtSource`、`parse_export_log`、`build_stock_import` + 全部导入期门），B2 读路径加按股非阻塞锁 + `REPEATABLE READ READ ONLY` 快照事务，`import_csv.py` 加破坏性替换写入器 `write_qmt_stock`（含 `validate_import_bundle` 结构性防御 + 重导入互锁）与通用路径 fail-closed 护栏，CLI 加 `--qmt` 模式，最后补 L1（CI 假件端到端）+ L2（真 PG 真链路脚本）。

**Tech Stack:** Python 3.11（pandas 2.2.3 / pytest 8.4.2 / asyncpg）、PostgreSQL 15、既有 `qmt_normalize`/`qmt_resample`/`generate_training_sets` 纯函数。

**权威 spec:** `docs/superpowers/specs/2026-07-23-qmt-plan3-b1-ingest-coverage-design.md`（决策 P3-D1..D12 全文；本 plan 每个 Task 隐含引用对应决策，遇冲突以 spec 为准）。

## Global Constraints

- **Python 解释器**：一律用仓库根 `.venv`（Python 3.11.x）。host `python3` 是 3.14、跑 pandas 段错误。所有 pytest 命令 `cd backend && ../.venv/bin/python -m pytest ...`。
- **基线**：`main` `08d70d2` = `feat/qmt-plan3-b1-ingest` base；`cd backend && ../.venv/bin/python -m pytest tests/ -q` = **255 passed**（本 plan 开工首步实测确认）。任何 Task 结束测试数只增不减、**0 failed / 0 skipped**。
- **CI 禁 skip**：`.github/workflows/backend-tests.yml` 解析 junit，任何 `skipped>0` 即 fail。**禁止**新增任何 `pytest.mark.skip`/`xfail`/条件 skip；L2 真 PG 脚本**不进** pytest 套件（是独立 `backend/scripts/*.py`）。
- **信任检查禁 `assert`**：所有 fail-closed 校验（身份一致、bundle 校验、值校验）一律 `if 条件: raise SomeError(...)`，**不得用 `assert`**（`python -O` 会剥）。
- **负向断言禁 `! grep`**：验收脚本用 `if grep -q ...; then exit 1; fi`。
- **每 PR ≤3 子项 ≤500 行**：3a=Task1-2，3b=Task3-5，3c=Task6-8，3d=Task9-10。不得合并成一个 PR。
- **codex review 用 `--scope branch-diff`**；获取全文 findings **别 `| tail`**（会截断 codex 输出）——直接重定向到文件读全文。
- **闸门读输出内容判绿、不看 exit code**；`cmd | tail` 后 `$?` 是 tail 的 → 用 `set -o pipefail` 或 `cmd; echo EXIT=$?`；每条 git/闸门命令同时打印 `branch` + `HEAD`。

## 现有可复用构件（已核实签名，勿重写）

| 构件 | 位置 | 签名/返回 |
|---|---|---|
| `parse_qmt_filename(name)` | `qmt_normalize.py:43` | `-> (code, name, period)`；`period∈{"1m","daily"}` |
| `parse_qmt_csv(path, src_period)` | `qmt_normalize.py:49` | `-> DataFrame`（本 plan Task1 改成产 `QmtSource`） |
| `is_valid_stock_code(code)` | `qmt_normalize.py:38` | `-> bool` |
| `trading_date(epoch)` | `qmt_normalize.py:25` | `-> date` |
| `clean(df)` | `import_csv.py:53` | `-> DataFrame`（丢 NaN/非正价/非有限/high<low + 去重 + 升序）**不改** |
| `compute_indicators(df)` | `import_csv.py:75` | `-> DataFrame`（MA66/BOLL/MACD）**不改** |
| `to_kline_records(df, stock_code, period)` | `import_csv.py:124` | `-> list[dict]` **不改** |
| `_INT_COLS` / `_FLOAT_COLS` | `import_csv.py:101-104` | 记录字段清单 |
| `compute_dense_coverage(df_1m)` | `qmt_resample.py:115` | `-> DenseCoverage(complete_dates, dropped_dates, start_date, end_date)` |
| `build_intraday(df_1m)` | `qmt_resample.py:131` | `-> (windows: dict[str,DataFrame], DenseCoverage)`（只保留 dense 完整日） |
| `resample_calendar(df_daily, rule)` | `qmt_resample.py:76` | `-> DataFrame`（rule∈{"weekly","monthly"}，只发完整周期） |
| `period_boundaries(df_daily, rule)` | `qmt_resample.py:66` | `-> list[int]`（含 partial 当期哨兵） |
| `reconcile_sources(df_1m, df_daily, *, status_1m, status_daily, price_rtol)` | `qmt_resample.py:150` | `-> ReconcileResult(ok, reason)` |
| `build_training_windows(period_bars, month_boundaries, rng, *, dense_dates, trading_dates, before_caps, months=8, ..., exclude_starts, dropped)` | `generate_training_sets.py:165` | 抛 `GenerateSkipException` 若无可行窗口 |
| `PERIODS` / `PERIOD_BEFORE_CAP` / `B2_GENERATION_LOCK_KEY` | `generate_training_sets.py:42/45/51` | 六周期 / before-cap 表 / 全局锁 key |
| `generate_one_training_set(conn, stock_code, output_dir, ...)` | `generate_training_sets.py:487` | Task4 改：加按股锁 + RR 快照 |
| `write_to_postgres(dsn, stock_code, stock_name, records)` | `import_csv.py:205` | Task7 改：加护栏 |

---

## 文件结构

**PR 3a 触及：**

| 文件 | 责任 |
|---|---|
| `backend/qmt_normalize.py`（改） | `parse_qmt_csv` 返回 `QmtSource`；新增 `@dataclass QmtSource(code, period, df)` |
| `backend/qmt_ingest.py`（建） | `ExportLogEntry` / `parse_export_log` / `QmtIngestRejected` / `build_stock_import` + 全部导入期门 |
| `backend/tests/test_qmt_ingest.py`（建） | 全部门的正/负向测 + mutation 说明 |
| `backend/tests/test_qmt_normalize.py`（改） | `parse_qmt_csv` 返回类型迁移的既有测调整 |

**PR 3b 触及：**

| 文件 | 责任 |
|---|---|
| `backend/generate_training_sets.py`（改） | `IMPORT_GEN_LOCK_KEY` + `stock_lock_key`；`generate_one_training_set` 加按股非阻塞锁 + RR 快照事务 |
| `backend/tests/test_generate_training_sets.py`（改） | `stock_lock_key` 纯函数测 + 假件读路径顺序/事务参数测 |
| `backend/scripts/verify_repeatable_read_snapshot.py`（建） | 真 PG 语义脚本（6 断言，不进 CI） |

**PR 3c 触及：**

| 文件 | 责任 |
|---|---|
| `backend/import_csv.py`（改） | `validate_import_bundle` / `write_qmt_stock`（替换+互锁+D8a+coverage 存在断言）/ `write_to_postgres` 护栏 / `_assert_stock_coverage_exists` / CLI `--qmt` |
| `backend/tests/test_import_csv.py`（改） | validate/write_qmt_stock/护栏 假件测 |

**PR 3d 触及：**

| 文件 | 责任 |
|---|---|
| `backend/tests/test_qmt_e2e_generation.py`（建） | L1：fixture 生成器 → build_stock_import → 假 conn 存储 → 真 generate_batch → ≥1 zip |
| `backend/scripts/verify_qmt_pg_chain.py`（建） | L2：真 PG 真链路（合并前控制者跑、输出贴 PR body） |

---

## Task 0：环境前置 + 基线确认

- [ ] **Step 1: 确认 venv + 基线**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
echo "branch=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)"
cd backend && ../.venv/bin/python -m pytest tests/ -q 2>&1 | tail -3; echo "EXIT=${PIPESTATUS[0]}"
```
Expected: `branch=feat/qmt-plan3-b1-ingest`；`255 passed`；EXIT=0。若 venv 缺失，`python3.11 -m venv ../.venv && ../.venv/bin/pip install -r requirements-test.txt`。

---

# PR 3a — 规整/合成装配层（Task 1-2）

## Task 1：`QmtSource` + `parse_export_log` + `ExportLogEntry`

**Files:**
- Modify: `backend/qmt_normalize.py`（`parse_qmt_csv` 返回 `QmtSource`；加 `@dataclass QmtSource`）
- Create: `backend/qmt_ingest.py`（先放 `ExportLogEntry` / `parse_export_log` / `QmtIngestRejected`）
- Test: `backend/tests/test_qmt_ingest.py`（新建）；`backend/tests/test_qmt_normalize.py`（改既有）

**Interfaces:**
- Produces:
  - `QmtSource(code: str, period: str, df: pd.DataFrame)`（frozen dataclass；`qmt_normalize`）
  - `parse_qmt_csv(path: Path, src_period: str) -> QmtSource`（`code` 从 `parse_qmt_filename(path.name)` 派生）
  - `ExportLogEntry(code, period, status, rows, first_time, last_time, source)`（frozen；`qmt_ingest`）
  - `parse_export_log(path: Path) -> dict[tuple[str,str], ExportLogEntry]`
  - `class QmtIngestRejected(Exception)`（带机器可读 `reason`；`str(exc)` == reason）

- [ ] **Step 1: 写 `QmtSource` 失败测**

`backend/tests/test_qmt_normalize.py` 加：
```python
from qmt_normalize import parse_qmt_csv, QmtSource

def test_parse_qmt_csv_returns_source_with_filename_identity(tmp_path):
    p = tmp_path / "000001.SZ_平安银行_日K线_前复权.csv"
    p.write_text("time,open,high,low,close,volume,amount\n"
                 "20200102,1.0,1.1,0.9,1.05,100,1050.0\n", encoding="utf-8-sig")
    src = parse_qmt_csv(p, "daily")
    assert isinstance(src, QmtSource)
    assert src.code == "000001.SZ"
    assert src.period == "daily"
    assert list(src.df.columns) == ["datetime", "open", "high", "low", "close", "volume", "amount"]
```

- [ ] **Step 2: 跑测确认失败**

Run: `cd backend && ../.venv/bin/python -m pytest tests/test_qmt_normalize.py::test_parse_qmt_csv_returns_source_with_filename_identity -v`
Expected: FAIL（`cannot import name 'QmtSource'`）。

- [ ] **Step 3: 改 `qmt_normalize.py`**

在文件顶部 import 区加 `from dataclasses import dataclass`。在 `parse_qmt_filename` 之后加：
```python
@dataclass(frozen=True)
class QmtSource:
    """携带来源身份的 QMT 数据（P3-D1/R14-F1：身份随数据端到端，不作为独立参数漂）。"""
    code: str
    period: str
    df: pd.DataFrame
```
把 `parse_qmt_csv` 尾部 `return df[[...]]` 改为从文件名派生 code 后包装：
```python
def parse_qmt_csv(path: Path, src_period: str) -> "QmtSource":
    df = pd.read_csv(path, encoding="utf-8-sig")   # utf-8-sig 剥 BOM
    missing = [c for c in _QMT_COLUMNS if c not in df.columns]
    if missing:
        raise QmtSchemaError(f"QMT CSV 缺必需列: {missing}")
    df = df.rename(columns={"time": "datetime"})
    df["datetime"] = parse_qmt_datetime(df["datetime"], src_period)
    df = df[["datetime", "open", "high", "low", "close", "volume", "amount"]]
    code, _name, period = parse_qmt_filename(Path(path).name)
    return QmtSource(code=code, period=period, df=df)
```

- [ ] **Step 4: 跑 Step 1 测 + 既有 qmt_normalize 测**

Run: `cd backend && ../.venv/bin/python -m pytest tests/test_qmt_normalize.py -v`
Expected: 新测 PASS。**既有测若断言 `parse_qmt_csv(...)` 返回 DataFrame 会红** → 逐个改成 `parse_qmt_csv(...).df`（这是签名迁移，不是回归）。全绿后继续。

- [ ] **Step 5: 写 `ExportLogEntry`/`parse_export_log` 测**

`backend/tests/test_qmt_ingest.py`（新建）：
```python
import pytest
from qmt_ingest import ExportLogEntry, parse_export_log, QmtIngestRejected
from qmt_normalize import QmtSchemaError

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
```

- [ ] **Step 6: 跑测确认失败**

Run: `cd backend && ../.venv/bin/python -m pytest tests/test_qmt_ingest.py -v`
Expected: FAIL（`No module named 'qmt_ingest'`）。

- [ ] **Step 7: 建 `qmt_ingest.py`（本 Task 部分）**

```python
# backend/qmt_ingest.py
"""QMT B1 装配层（纯函数，无 asyncpg）。Spec: 2026-07-23-qmt-plan3-b1-ingest-coverage-design.md。"""
from __future__ import annotations

import datetime as _dt
import math
from dataclasses import dataclass

import pandas as pd

from qmt_normalize import (QmtSchemaError, parse_qmt_datetime, parse_qmt_filename,
                           trading_date)

_STOCK_COL_CANDIDATES = ("stock", "code", "stock_code", "file", "filename")
_LABEL_TO_PERIOD = {"1分钟K线": "1m", "日K线": "daily", "1m": "1m", "daily": "daily"}
_REQUIRED_LOG_COLS = ("period", "status", "rows", "first_time", "last_time")


class QmtIngestRejected(Exception):
    """一只股被某道导入期门拒；str(exc) 即机器可读 reason。"""


@dataclass(frozen=True)
class ExportLogEntry:
    code: str
    period: str
    status: str
    rows: int
    first_time: int
    last_time: int
    source: str


def _norm_code(raw: str) -> str:
    """标识值若形如 QMT 文件名 → 取 code；否则按裸 code 返回。"""
    try:
        code, _n, _p = parse_qmt_filename(str(raw))
        return code
    except QmtSchemaError:
        return str(raw).strip()


def parse_export_log(path) -> dict[tuple[str, str], ExportLogEntry]:
    df = pd.read_csv(path, encoding="utf-8-sig", dtype=str)
    missing = [c for c in _REQUIRED_LOG_COLS if c not in df.columns]
    if missing:
        raise QmtSchemaError(f"export_log 缺列: {missing}")
    id_col = next((c for c in _STOCK_COL_CANDIDATES if c in df.columns), None)
    if id_col is None:
        raise QmtSchemaError(f"export_log 无股票标识列（候选 {_STOCK_COL_CANDIDATES}）")
    out: dict[tuple[str, str], ExportLogEntry] = {}
    for _, row in df.iterrows():
        period = _LABEL_TO_PERIOD.get(str(row["period"]).strip())
        if period is None:
            continue
        code = _norm_code(row[id_col])
        key = (code, period)
        if key in out:
            raise QmtSchemaError(f"export_log_duplicate: {key} 出现多行")
        # first_time/last_time 用同一套 QMT 打包整数解析（解析不出 → 报错停下）
        ft = int(parse_qmt_datetime(pd.Series([row["first_time"]]), period).iloc[0])
        lt = int(parse_qmt_datetime(pd.Series([row["last_time"]]), period).iloc[0])
        out[key] = ExportLogEntry(code=code, period=period, status=str(row["status"]).strip(),
                                  rows=int(row["rows"]), first_time=ft, last_time=lt,
                                  source=str(row[id_col]))
    return out
```

- [ ] **Step 8: 跑测确认通过**

Run: `cd backend && ../.venv/bin/python -m pytest tests/test_qmt_ingest.py tests/test_qmt_normalize.py -v`
Expected: 全 PASS。

- [ ] **Step 9: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add backend/qmt_normalize.py backend/qmt_ingest.py backend/tests/test_qmt_ingest.py backend/tests/test_qmt_normalize.py
git commit -m "QMT Plan 3 Task1：parse_qmt_csv→QmtSource（身份随数据）+ parse_export_log/ExportLogEntry（重复行 fail-closed）"
```

---

## Task 2：`build_stock_import` + 全部导入期门

**Files:**
- Modify: `backend/qmt_ingest.py`（加 `ImportBundle` / `CoverageArtifact` / `build_stock_import`）
- Test: `backend/tests/test_qmt_ingest.py`

**Interfaces:**
- Consumes: `QmtSource`（Task1）、`ExportLogEntry`（Task1）、`build_intraday`/`resample_calendar`/`period_boundaries`/`compute_dense_coverage`/`reconcile_sources`（qmt_resample）、`clean`/`compute_indicators`/`to_kline_records`（import_csv）、`build_training_windows`/`PERIOD_BEFORE_CAP`/`PERIODS`/`GenerateSkipException`（generate_training_sets）
- Produces:
  - `CoverageArtifact(start_date, end_date, dropped_dates: list, dense_day_count: int)`
  - `ImportBundle(records: dict[str, list[dict]], coverage: CoverageArtifact)`
  - `build_stock_import(src_1m: QmtSource, src_daily: QmtSource, *, stock_code: str, stock_name: str, entry_1m: ExportLogEntry, entry_daily: ExportLogEntry) -> ImportBundle`

**门执行顺序（spec §4.1）**：四方身份一致 → 拷贝完整性(clean 前 raw 行数) → `clean` → 原始值门(1m+daily amount/volume + daily len-无损) → `reconcile_sources` → `build_intraday`+`resample_calendar`×2+daily → 出货可行性预检(`build_training_windows` 全门 + 传 `dropped`) → 逐周期 `compute_indicators` → `to_kline_records`。**任一门失败抛 `QmtIngestRejected(reason)`，零部分产出。**

- [ ] **Step 1: 写门的负向测（每门一条 reason）**

`test_qmt_ingest.py` 加一个 fixture 生成器 `_make_valid_sources(...)`（造能全过的最小合法输入）+ 逐门篡改：
```python
import numpy as np, pandas as pd, datetime as dt
from qmt_normalize import QmtSource
from qmt_ingest import (ExportLogEntry, build_stock_import, QmtIngestRejected, ImportBundle)

# 见 helper 章：_gen_valid(...) 造 src_1m/src_daily/entry_1m/entry_daily（足够 B2 出货）

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
```

> **`gen` fixture** 造「日线数年（≥39 月边界）+ 1m 近一年、每交易日精确 241 根、无 drop」的最小可出货输入，见文末 **Helper：fixture 生成器**（Task9 也复用，抽到 `tests/_qmt_fixtures.py`）。

- [ ] **Step 2: 跑测确认失败**

Run: `cd backend && ../.venv/bin/python -m pytest tests/test_qmt_ingest.py -k "identity or status or copy or volume or amount or valid" -v`
Expected: FAIL（`cannot import name 'build_stock_import'`）。

- [ ] **Step 3: 实现 `build_stock_import`（qmt_ingest.py 追加）**

```python
import numpy as np                      # PF3：_assert_values_ok 用 np.isfinite/np.floor，必须 import
import random as _random
from qmt_resample import (build_intraday, compute_dense_coverage, period_boundaries,
                          reconcile_sources, resample_calendar)
from import_csv import clean, compute_indicators, to_kline_records, _INT_COLS
from generate_training_sets import (PERIODS, PERIOD_BEFORE_CAP, build_training_windows,
                                    GenerateSkipException)


@dataclass(frozen=True)
class CoverageArtifact:
    start_date: object
    end_date: object
    dropped_dates: list
    dense_day_count: int


@dataclass(frozen=True)
class ImportBundle:
    records: dict
    coverage: CoverageArtifact


def _reject(reason: str):
    raise QmtIngestRejected(reason)


def _assert_values_ok(df, label: str):
    """1m/daily 每行 amount 有限非空 + volume 有限整数 >= 0（P3-D9(c)/R15-F2/R16-F2）。"""
    amt = df["amount"].to_numpy(dtype="float64")
    if not np.all(np.isfinite(amt)):
        _reject("bad_amount_or_volume")
    vol = df["volume"].to_numpy(dtype="float64")
    if not np.all(np.isfinite(vol)) or np.any(vol < 0) or np.any(vol != np.floor(vol)):
        _reject("bad_amount_or_volume")


def build_stock_import(src_1m, src_daily, *, stock_code, stock_name, entry_1m, entry_daily):
    # 门1：四方身份一致（R14-F1/R15-F1，if/raise 非 assert）
    for obj, per in ((src_1m, "1m"), (src_daily, "daily"),
                     (entry_1m, "1m"), (entry_daily, "daily")):
        if obj.code != stock_code or obj.period != per:
            _reject("source_identity_mismatch")

    raw_1m, raw_daily = src_1m.df, src_daily.df

    # 门2：拷贝完整性（clean 前 raw 行数/端点 vs export_log，P3-D9(b)）
    for raw, ent in ((raw_1m, entry_1m), (raw_daily, entry_daily)):
        if (len(raw) != ent.rows
                or int(raw.iloc[0]["datetime"]) != ent.first_time
                or int(raw.iloc[-1]["datetime"]) != ent.last_time):
            _reject("export_log_mismatch")

    # clean
    cln_1m, cln_daily = clean(raw_1m), clean(raw_daily)

    # 门3：原始值门（1m+daily amount/volume；daily 另加 clean-len 无损，P3-D9(c)）
    _assert_values_ok(cln_1m, "1m")
    _assert_values_ok(cln_daily, "daily")
    if len(cln_daily) != len(raw_daily) or raw_daily["datetime"].duplicated().any():
        _reject("daily_clean_dropped_rows")

    # 门4：D10 双源对账（status 门在此，P3-D3）
    rc = reconcile_sources(cln_1m, cln_daily,
                           status_1m=entry_1m.status, status_daily=entry_daily.status)
    if not rc.ok:
        _reject(rc.reason)

    # 合成
    intraday, cov = build_intraday(cln_1m)
    weekly = resample_calendar(cln_daily, "weekly")
    monthly = resample_calendar(cln_daily, "monthly")
    period_dfs = {"monthly": monthly, "weekly": weekly, "daily": cln_daily,
                  "60m": intraday["60m"], "15m": intraday["15m"], "3m": intraday["3m"]}
    for p in PERIODS:
        if period_dfs[p].empty:
            _reject("no_intraday_after_dense_filter" if p in ("3m", "15m", "60m") else "empty_period")

    # 门5：出货可行性预检 = 跑 B2 出货本体 build_training_windows 全门 + 传 dropped（P3-D9(a)/R16-F1）
    dense_dates = set(cov.complete_dates)
    trading_dates = sorted({trading_date(int(e)) for e in cln_daily["datetime"]})
    month_boundaries = period_boundaries(cln_daily, "monthly")
    n_cand = max(1, len(month_boundaries))
    try:
        build_training_windows(period_dfs, month_boundaries, _random.Random(0),
                               dense_dates=dense_dates, trading_dates=trading_dates,
                               before_caps=PERIOD_BEFORE_CAP,
                               dropped=frozenset(cov.dropped_dates),
                               max_retries=n_cand)
    except GenerateSkipException:
        _reject("no_eligible_training_window")

    # 逐周期指标 + records
    records = {p: to_kline_records(compute_indicators(period_dfs[p].copy()), stock_code, p)
               for p in PERIODS}
    coverage = CoverageArtifact(start_date=cov.start_date, end_date=cov.end_date,
                                dropped_dates=list(cov.dropped_dates),
                                dense_day_count=len(cov.complete_dates))
    return ImportBundle(records=records, coverage=coverage)
```

> **实施注意**：`build_training_windows` 期望 `period_bars` 的各周期 DataFrame 有 `datetime` 列（合成层已保证）；预检在 `compute_indicators` 之前跑（它不读指标列，spec §P3-D9(a) 注）。若实测 `build_training_windows` 需要额外列，以其真实签名为准（dry-run 时读源码 `generate_training_sets.py:165`）。

- [ ] **Step 4: 跑门测 + 补 coverage/周期分工正向测**

Run: `cd backend && ../.venv/bin/python -m pytest tests/test_qmt_ingest.py -v`
Expected: 全 PASS。若 `gen` fixture 造得不够喂饱 B2（预检抛 `no_eligible_training_window`），调 fixture 的日线年数/1m 天数（见 Helper），**不要**削弱门。

- [ ] **Step 5: mutation 复验（控制者本人跑，非 subagent 自证）**

逐条临时改坏门、跑对应测必须由 PASS 变 FAIL，再改回：
- `_assert_values_ok` 里 volume `< 0` 判据删掉 → `test_daily_negative_volume_rejects` / `test_1m_bad_amount_rejects` 必挂
- 门1 四方循环删掉 → `test_identity_mismatch_rejects` 必挂
- 预检 `dropped=frozenset(...)` 改成 `dropped=frozenset()` → 需另有 dropped-日测（见 Task2 补充测 ⑥，Helper 造）必挂
- 门5 整段删 → 用「日线够但 dense 1m 短」输入的测必挂

记录每条 mutation 的 PASS→FAIL→PASS 于 commit message 或 PR body。

- [ ] **Step 6: Commit**

```bash
git add backend/qmt_ingest.py backend/tests/test_qmt_ingest.py backend/tests/_qmt_fixtures.py
git commit -m "QMT Plan 3 Task2：build_stock_import + 全导入期门（身份/拷贝完整/值/D10/出货可行性预检）"
```

**PR 3a 收尾**：非-coder 验收清单（见文末 §验收）+ 本地 `pytest tests/ -q` 全绿 + requesting-code-review + whole-branch codex（`--scope branch-diff`，全文别 tail）。

---

# PR 3b — B2 快照一致性 + 按股锁（Task 3-5）

## Task 3：`stock_lock_key` + `IMPORT_GEN_LOCK_KEY`

**Files:**
- Modify: `backend/generate_training_sets.py`（加常量 + 纯函数）
- Test: `backend/tests/test_generate_training_sets.py`

**Interfaces:**
- Produces: `IMPORT_GEN_LOCK_KEY: int`（与 `B2_GENERATION_LOCK_KEY` 不同）；`stock_lock_key(stock_code: str) -> int`（落 int4 正区间，同 code 恒定）

- [ ] **Step 1: 写测**

`test_generate_training_sets.py` 加：
```python
from generate_training_sets import stock_lock_key, IMPORT_GEN_LOCK_KEY, B2_GENERATION_LOCK_KEY

def test_stock_lock_key_deterministic_and_int4():
    a = stock_lock_key("000001.SZ"); b = stock_lock_key("000001.SZ")
    assert a == b and 0 <= a <= 0x7FFFFFFF
    assert stock_lock_key("000002.SZ") != a or True   # 允许碰撞、不允许非确定
    assert IMPORT_GEN_LOCK_KEY != B2_GENERATION_LOCK_KEY
```

- [ ] **Step 2: 跑测确认失败** — `pytest tests/test_generate_training_sets.py::test_stock_lock_key_deterministic_and_int4 -v` → FAIL。

- [ ] **Step 3: 实现**（`generate_training_sets.py`，`B2_GENERATION_LOCK_KEY` 定义之后）：
```python
import zlib
# 与 B2_GENERATION_LOCK_KEY 刻意不同（同用会让 B1 导入把 B2 挡在启动外）。
IMPORT_GEN_LOCK_KEY = 0x42345CF0

def stock_lock_key(stock_code: str) -> int:
    """按股 advisory lock 的第二参数：crc32 落 int4 正区间。
    碰撞只影响并发度、不影响正确性（B1 import 侧也 import 本函数，保证两端同一把 key）。"""
    return zlib.crc32(stock_code.encode("utf-8")) & 0x7FFFFFFF
```

- [ ] **Step 4: 跑测确认通过** — PASS。
- [ ] **Step 5: Commit** — `git commit -m "QMT Plan 3 Task3：IMPORT_GEN_LOCK_KEY + stock_lock_key（B1/B2 共用同一把 key）"`

## Task 4：`generate_one_training_set` 加按股非阻塞锁 + RR 快照事务

**Files:**
- Modify: `backend/generate_training_sets.py:487`（`generate_one_training_set`）
- Test: `backend/tests/test_generate_training_sets.py`（假 asyncpg conn）

**Interfaces:**
- Consumes: `stock_lock_key`/`IMPORT_GEN_LOCK_KEY`（Task3）
- Behavior（spec §P3-D5/D8）：最外层 try **session 级** `pg_try_advisory_lock(IMPORT_GEN_LOCK_KEY, stock_lock_key(code))`（拿不到→`GenerateSkipException`「该股正被导入」）→ coverage + 6 周期读包进 `conn.transaction(isolation="repeatable_read", readonly=True)` → 其余（交叉校验/选窗/全局锁/写/登记）不变 → `finally` 先放全局锁再放按股锁。

- [ ] **Step 1: 写假件读路径顺序测**

用现有 test 里的假 conn（读 `test_generate_training_sets.py` / `test_b2_reconnect_integration.py` 已有的假 conn 模式复用）。断言：
```python
# 伪代码骨架——按现有假 conn fixture 适配
async def test_gen_takes_stock_lock_before_rr_snapshot(fake_conn):
    # fake_conn 记录 fetchval("SELECT pg_try_advisory_lock", KEY, subkey) 与 transaction(...) 调用序
    await generate_one_training_set(fake_conn, "000001.SZ", tmp_output, rng=Random(0))
    ops = fake_conn.calls
    assert ops.index("advisory_lock(IMPORT_GEN)") < ops.index("transaction(repeatable_read,readonly)")
    assert ops.index("transaction_open") < ops.index("fetch:_fetch_dense_coverage")
    assert ops.index("fetch:_fetch_existing_starts") > ops.index("transaction_commit")

async def test_gen_stock_lock_busy_skips(fake_conn_lock_busy):
    with pytest.raises(GenerateSkipException):
        await generate_one_training_set(fake_conn_lock_busy, "000001.SZ", tmp_output)
```
> 假件只能证「按预期参数/顺序调用」，RR/锁**语义**由 Task5 真 PG 脚本证（spec §5.2 界限说明）。

- [ ] **Step 2: 跑测确认失败** — 现有 `generate_one_training_set` 无按股锁 → 顺序断言 FAIL。

- [ ] **Step 3: 改 `generate_one_training_set`**

在函数体最外层包一层按股锁 + 把「读 coverage + 6 周期」移进 RR 只读事务。**其余逻辑（`_fetch_existing_starts`/全局锁/`_exists_start`/写/登记）保持在事务外、一字不动**：
```python
async def generate_one_training_set(conn, stock_code, output_dir, rng=None, max_retries=8):
    rng = rng or random.Random()
    if not is_valid_stock_code(stock_code):
        raise GenerateSkipException(f"{stock_code}: 非法 stock_code")
    sk = stock_lock_key(stock_code)
    if not await conn.fetchval("SELECT pg_try_advisory_lock($1,$2)", IMPORT_GEN_LOCK_KEY, sk):
        raise GenerateSkipException(f"{stock_code}: 正被导入（按股锁被占），跳过")
    try:
        async with conn.transaction(isolation="repeatable_read", readonly=True):
            start_date, end_date, dropped, dense_day_count = await _fetch_dense_coverage(conn, stock_code)
            if start_date is None or end_date is None:
                raise GenerateSkipException(f"{stock_code}: stock_coverage 无覆盖 artifact")
            period_bars = {p: await _fetch_period_bars(conn, stock_code, p) for p in PERIODS}
        # —— 以下全部在 RR 事务外、逻辑与原实现一致 ——（交叉校验/选窗/全局锁/写/登记，原样迁移）
        ...  # 原 522 行之后的代码整体搬到这里，不改
    finally:
        await conn.fetchval("SELECT pg_advisory_unlock($1,$2)", IMPORT_GEN_LOCK_KEY, sk)
```
> **迁移纪律**：原 `generate_one_training_set` 里「早退检查 + 六周期读」原本在函数顶层顺序执行；本 Task 只把这两段包进 RR 事务、并在最外层套按股锁。**全局 `B2_GENERATION_LOCK_KEY` 的取/放位置、`_exists_start`、`assemble_from_windows`、`_register_training_set` 一律不动**（它们已在事务外，正确）。dry-run 时逐行 diff 确保零语义漂移。

- [ ] **Step 4: 跑测 + 全套件** — `pytest tests/ -q` 全绿（含既有 b2 集成测；若既有假 conn 不支持 `transaction(isolation=...)` 参数，扩假 conn 支持记录该参数）。

- [ ] **Step 5: mutation** — 把 `transaction(isolation="repeatable_read", readonly=True)` 改成默认 `transaction()` → Task5 真 PG 脚本第 3 条会挂（此处假件测断言参数、也应挂）。把按股锁 `try` 改成恒 True → busy-skip 测挂。

- [ ] **Step 6: Commit** — `git commit -m "QMT Plan 3 Task4：generate_one_training_set 加按股非阻塞锁 + coverage/6周期读入 RR 只读快照"`

## Task 5：`verify_repeatable_read_snapshot.py`（真 PG，不进 CI）

**Files:**
- Create: `backend/scripts/verify_repeatable_read_snapshot.py`

**Interfaces:** 参照 `backend/scripts/verify_advisory_lock_reentrancy.py` 形态（docker `postgres:15.12` + asyncpg，`DSN` 环境变量，退出码 0=全 PASS）。6 条断言见 spec §5.3：① RR 事务内二读看旧值；② 事务外看新值；③ `SHOW transaction_isolation`==repeatable read + 事务内写被拒；④ 导入事务未提交外部看不到；⑤ 按股锁互斥（同 s1 False、异 s2 True）；⑥ B1 事务级锁提交即释放 + 反向对照阻塞。

- [ ] **Step 1: 写脚本**（逐断言打印 `OK/FAIL`，任一 FAIL 非零退出；结构照抄 `verify_advisory_lock_reentrancy.py` 的 main/asyncpg 骨架）。**不进 pytest**（CI 禁 skip、需 Docker）。
- [ ] **Step 2: 本地真跑一次**（控制者，需 Docker PG）：
```bash
docker run --rm -d -p 5433:5432 -e POSTGRES_PASSWORD=postgres --name pg-r17 postgres:15.12
sleep 3
DSN='postgresql://postgres:postgres@localhost:5433/postgres' .venv/bin/python backend/scripts/verify_repeatable_read_snapshot.py; echo "EXIT=$?"
docker rm -f pg-r17
```
Expected: 6 行 OK + `PASS`；EXIT=0。**判绿读输出行、不看 exit code**（但也确认 EXIT=0）。
- [ ] **Step 3: Commit** — `git commit -m "QMT Plan 3 Task5：verify_repeatable_read_snapshot.py（真 PG 6 语义断言，不进 CI）"`

**PR 3b 收尾**：`pytest tests/ -q` 全绿 + 验收清单 + requesting-code-review + whole-branch codex。**PR body 贴 Task5 真跑输出。**

---

# PR 3c — 写库壳 + 护栏 + CLI（Task 6-8）

## Task 6：`validate_import_bundle` + `write_qmt_stock`

**Files:**
- Modify: `backend/import_csv.py`（加 `validate_import_bundle` / `write_qmt_stock` / 异常类 / `_assert_stock_coverage_exists`）
- Test: `backend/tests/test_import_csv.py`

**Interfaces:**
- Consumes: `ImportBundle`/`CoverageArtifact`（qmt_ingest）、`stock_lock_key`/`IMPORT_GEN_LOCK_KEY`（generate_training_sets）、`PERIODS`、`_KLINE_INSERT`/`_assert_klines_price_columns_double`（import_csv 现有）
- Produces:
  - `class InvalidImportBundleError(ValueError)` / `class ImportBusyError(RuntimeError)` / `class ReimportBlockedError(RuntimeError)`
  - `validate_import_bundle(bundle, stock_code) -> None`（不合规 `raise InvalidImportBundleError`，全 `if/raise`）
  - `write_qmt_stock(dsn, stock_code, stock_name, bundle) -> dict[str, int]`

- [ ] **Step 1: 写 `validate_import_bundle` 纯函数测**（全 `if/raise`；spec §P3-D12 逐条）：
```python
from import_csv import validate_import_bundle, InvalidImportBundleError
# 用 qmt_ingest.gen fixture 造合法 bundle，逐条篡改：
# 少周期/多周期/空列表/period≠key/period∉PERIODS/stock_code串股/缺字段/amount=inf/volume=-5/
# volume分数/重复datetime/coverage start>end/count对不上/端点不在daily集/dropped非日期/dropped落区间外(应放行)
def test_bundle_period_mismatch_rejects(valid_bundle):
    valid_bundle.records["3m"][0]["period"] = "1m"
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(valid_bundle, "000001.SZ")
def test_bundle_cross_stock_rejects(valid_bundle):
    valid_bundle.records["3m"][0]["stock_code"] = "000002.SZ"
    with pytest.raises(InvalidImportBundleError):
        validate_import_bundle(valid_bundle, "000001.SZ")
def test_bundle_dropped_outside_span_allowed(valid_bundle_with_boundary_drop):
    validate_import_bundle(valid_bundle_with_boundary_drop, "000001.SZ")  # 不抛
# ... 其余逐条
```

- [ ] **Step 2: 跑测确认失败** — FAIL（未定义）。

- [ ] **Step 3: 实现 `validate_import_bundle`**（import_csv.py；**全 if/raise、禁 assert**）：
```python
import datetime as _dt
from qmt_normalize import trading_date

class InvalidImportBundleError(ValueError): pass
class ImportBusyError(RuntimeError): pass
class ReimportBlockedError(RuntimeError): pass

_QMT_PERIODS = ("monthly", "weekly", "daily", "60m", "15m", "3m")

def validate_import_bundle(bundle, stock_code: str) -> None:
    recs = bundle.records
    if set(recs.keys()) != set(_QMT_PERIODS):
        raise InvalidImportBundleError("period 集合 ≠ 六周期")
    seen_codes = set()
    for per, rows in recs.items():
        if per not in _QMT_PERIODS:
            raise InvalidImportBundleError(f"未知 period {per}")
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
            if amt is None or not math.isfinite(float(amt)):
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
```
（`import math` 已在文件顶部则复用；否则加。）

- [ ] **Step 4: 跑 validate 测确认通过** — 全 PASS。

- [ ] **Step 5: 写 `write_qmt_stock` 假 conn 测**（顺序 = 校验→按股 xact 锁→schema 守卫→互锁 SELECT 1→DELETE→INSERT×6→coverage UPSERT）：
```python
async def test_write_qmt_stock_order_and_atomicity(fake_conn, valid_bundle):
    await write_qmt_stock("dsn", "000001.SZ", "平安", valid_bundle)
    ops = fake_conn.calls   # 记录 SQL 关键字序 + transaction 边界
    assert ops.index("validate") < ops.index("advisory_xact_lock")
    assert ops.index("assert_double") < ops.index("DELETE")
    assert ops.index("SELECT 1 training_sets") < ops.index("DELETE")
    assert ops.index("DELETE") < ops.index("INSERT klines")
    # 所有写在同一 transaction 内
async def test_write_qmt_stock_reimport_blocked(fake_conn_has_training_set, valid_bundle):
    with pytest.raises(ReimportBlockedError):
        await write_qmt_stock("dsn", "000001.SZ", "平安", valid_bundle)
    assert "DELETE" not in fake_conn_has_training_set.calls   # 零写入
async def test_write_qmt_stock_lock_busy(fake_conn_lock_busy, valid_bundle):
    with pytest.raises(ImportBusyError):
        await write_qmt_stock("dsn", "000001.SZ", "平安", valid_bundle)
```

- [ ] **Step 6: 实现 `write_qmt_stock`**（import_csv.py；替换语义 + 按股 xact 锁 + 互锁）：
```python
async def _assert_stock_coverage_exists(conn):
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

async def write_qmt_stock(dsn, stock_code, stock_name, bundle) -> dict:
    from generate_training_sets import IMPORT_GEN_LOCK_KEY, stock_lock_key
    import json, asyncpg
    validate_import_bundle(bundle, stock_code)          # 取连接前，零 DB 往返
    sk = stock_lock_key(stock_code)
    conn = await asyncpg.connect(dsn)
    try:
        async with conn.transaction():
            if not await conn.fetchval("SELECT pg_try_advisory_xact_lock($1,$2)",
                                       IMPORT_GEN_LOCK_KEY, sk):
                raise ImportBusyError(f"{stock_code}: 正被 B2 生成，稍后重试")
            await conn.execute("LOCK TABLE klines, stock_coverage IN ROW EXCLUSIVE MODE")
            await _assert_klines_price_columns_double(conn)
            await _assert_stock_coverage_exists(conn)
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
        await conn.close()
```
> `SchemaDriftError` 已存在于 `import_csv.py`（`write_to_postgres` 用）；复用。

- [ ] **Step 7: 跑测 + mutation**（`if/raise` 全部；把互锁 `SELECT 1` 挪到 DELETE 之后 → reimport 测挂；把按股锁改恒 True → busy 测挂）。

- [ ] **Step 8: Commit** — `git commit -m "QMT Plan 3 Task6：validate_import_bundle（全 if/raise）+ write_qmt_stock（替换语义 + 按股 xact 锁 + 重导入互锁 + coverage UPSERT）"`

## Task 7：通用路径 `write_to_postgres` fail-closed 护栏

**Files:** Modify `backend/import_csv.py:205`（`write_to_postgres`）；Test `test_import_csv.py`

**Interfaces:** Consumes `stock_lock_key`/`IMPORT_GEN_LOCK_KEY`（generate_training_sets）、`LegacyImportBlockedError`（新）

- [ ] **Step 1: 写测**（该股有 coverage 行 → `LegacyImportBlockedError` 零 INSERT；records-参数身份不一致 → `ValueError` 零写入、取锁前拒；无 coverage 行 → 行为与改前一致）。
- [ ] **Step 2: 跑测失败。**
- [ ] **Step 3: 改 `write_to_postgres`**：事务内、任何 INSERT 前依次——`if {r["stock_code"] for r in records} != {stock_code}: raise ValueError(...)`（取锁前）→ `pg_try_advisory_xact_lock(IMPORT_GEN_LOCK_KEY, stock_lock_key(stock_code))` 拿不到 `raise ImportBusyError` → `if await conn.fetchval("SELECT 1 FROM stock_coverage WHERE stock_code=$1", stock_code): raise LegacyImportBlockedError("用 --qmt 模式")`。`LegacyImportBlockedError(RuntimeError)` 新增。
- [ ] **Step 4: 跑测通过**（既有通用 CSV 测应全绿——无 coverage 行的股行为不变）。
- [ ] **Step 5: mutation** — 去掉护栏 → 被管理股改脏测挂。
- [ ] **Step 6: Commit** — `git commit -m "QMT Plan 3 Task7：write_to_postgres 通用路径 fail-closed 护栏（身份一致 + 非阻塞锁 + coverage 有行即拒）"`

## Task 8：CLI `--qmt` 模式

**Files:** Modify `backend/import_csv.py`（`main`/`_amain`）；Test `test_import_csv.py`（参数解析纯逻辑）

**Interfaces:** `--qmt` 与 `--period` 互斥；`--export-log` 默认 `<input>/export_log.csv`；递归 glob `{code}_*_1分钟K线_前复权.csv` / `{code}_*_日K线_前复权.csv` 命中数 ≠1 报错。

- [ ] **Step 1: 写参数解析测**（`--qmt`+`--period` 同给 → argparse error；glob 命中 0/2 → 报错退出码 2）。

- [ ] **Step 2: 写「scheduler 活动 → 拒绝导入」测**（PF1/spec §P3-D8 R17-F1，rollout drain 机器可检）：
```python
async def test_qmt_import_refuses_when_scheduler_active(fake_conn_global_lock_held):
    # fake_conn 让 pg_try_advisory_lock(B2_GENERATION_LOCK_KEY) 返回 False
    rc = await _amain_qmt(args_with_qmt, conn=fake_conn_global_lock_held)
    assert rc != 0   # 退非零 + 打印 drain 提示
    assert "DELETE" not in fake_conn_global_lock_held.calls   # 零写入
async def test_qmt_import_probe_released_on_success(fake_conn_global_lock_free):
    # 探测拿到后立即 unlock，再继续导入
    await _amain_qmt(...); ops = fake_conn_global_lock_free.calls
    assert ops.index("advisory_lock(B2_GEN)") < ops.index("advisory_unlock(B2_GEN)") < ops.index("write_qmt_stock")
```

- [ ] **Step 3: 加 `--qmt` 分支 + 全局锁探测**（`import_csv.py`）：
```python
# --qmt 分支，连库后、任何解析/写入之前，探测全局 B2 锁作 rollout drain 闸（spec §P3-D8/R17-F1）
from generate_training_sets import B2_GENERATION_LOCK_KEY
conn = await asyncpg.connect(args.dsn)
try:
    got = await conn.fetchval("SELECT pg_try_advisory_lock($1)", B2_GENERATION_LOCK_KEY)
    if not got:
        print("[B1] 拒绝导入：检测到活动的 B2/B4 调度器（全局锁被占）。"
              "首次 QMT 导入前请先重启/drain 调度器。", file=sys.stderr)
        return 2
    await conn.fetchval("SELECT pg_advisory_unlock($1)", B2_GENERATION_LOCK_KEY)  # 立即释放，只做探测
finally:
    await conn.close()
# —— 探测通过后再进主流程 ——
s1 = parse_qmt_csv(f_1m, "1m"); sd = parse_qmt_csv(f_daily, "daily")
entries = parse_export_log(args.export_log or Path(args.input) / "export_log.csv")
bundle = build_stock_import(s1, sd, stock_code=args.stock, stock_name=s1_name,
                            entry_1m=entries[(args.stock, "1m")],
                            entry_daily=entries[(args.stock, "daily")])
counts = await write_qmt_stock(args.dsn, args.stock, s1_name, bundle)
```
> **诚实标注**（写进代码注释 + 帮助文本）：全局锁探测 catch「导入时刻有 B2 在写」，但**无法** fence「旧 B2 已无锁读完、正等登记」那一瞬——完全封死靠部署 drain（spec §P3-D8）。成功打印每周期行数 / dense 带 / 日线首末 + 月边界数；`ImportBusyError`/`ReimportBlockedError`/`LegacyImportBlockedError`/`QmtIngestRejected` → 打印 reason 退非零。

- [ ] **Step 4: 跑测通过。**
- [ ] **Step 5: Commit** — `git commit -m "QMT Plan 3 Task8：CLI --qmt 模式 + rollout drain 全局锁探测（有活动 scheduler 即拒）"`

**PR 3c 收尾**：`pytest tests/ -q` 全绿 + 验收清单 + requesting-code-review + whole-branch codex。

---

# PR 3d — 端到端（Task 9-10）

## Task 9：L1 端到端集成测（CI 内，假件存储）

**Files:** Create `backend/tests/test_qmt_e2e_generation.py`；`backend/tests/_qmt_fixtures.py`（fixture 生成器，Task2 已建、此处扩充）

**Interfaces:** `QMT fixture → build_stock_import → 假 conn 充当存储 → 真 generate_batch → ≥1 zip + training_sets 有登记行`

- [ ] **Step 1: 写 L1 测**：fixture 生成器造「日线多年 + 1m 近一年、每交易日 241 根、零 drop」→ `build_stock_import` 得 bundle → 用记录型假 conn（把 bundle.records 当 klines 存、coverage 当 stock_coverage 存、training_sets 内存表）→ `await generate_batch(fake_conn, 1, tmp_output)` → 断言磁盘 ≥1 `.zip`、假 training_sets ≥1 行、zip `content_hash` 与字节一致。
- [ ] **Step 2: 跑测**（可能要迭代假 conn 让 `_fetch_period_bars`/`_fetch_dense_coverage`/`_fetch_existing_starts`/`_register_training_set`/RR `transaction` 全部可跑）。fixture **不进仓**（生成器造 DataFrame/临时 CSV）。若单测慢，把 1m 跨度收到刚好喂饱 B2 的最小天数（实测决定）。
- [ ] **Step 3: Commit** — `git commit -m "QMT Plan 3 Task9：L1 端到端集成测（fixture→build_stock_import→假件→真 generate_batch→≥1 zip）"`

## Task 10：L2 真 PG 真链路脚本（合并前控制者跑）

**Files:** Create `backend/scripts/verify_qmt_pg_chain.py`

**Interfaces:** 真 PG 跑真 `build_stock_import`+真 `write_qmt_stock`+真 `generate_one_training_set`，时序严格 = 导入 → 未生成时重导入证替换 → 生成 → 已生成后重导入证互锁 → 通用路径证护栏（spec §5.4）。

- [ ] **Step 1: 写脚本**（docker `postgres:15.12` + 应用 `schema.sql`；断言链见 spec §5.4 ①-⑤；不进 pytest）。
- [ ] **Step 2: 本地真跑**（控制者，Docker PG）→ 全 PASS、EXIT=0；**输出留存贴 PR body**。
- [ ] **Step 3: Commit** — `git commit -m "QMT Plan 3 Task10：verify_qmt_pg_chain.py（L2 真 PG 真链路，合并前必跑、输出贴 PR body）"`

**PR 3d 收尾**：`pytest tests/ -q` 全绿 + 验收清单 + requesting-code-review + whole-branch codex。**PR body 必写三条口径**：① 贴 L2 完整输出；② 「CI 绿 ≠ 链路已证，凭 L2 输出」；③ 「重导入不作废旧训练组、改以互锁禁止已出货股重导入，作废/版本化拆独立 plan」+「rollout 首次导入前须 drain 调度器」。**禁写「pilot 已完成」「100 股已出货」。**

---

## Helper：fixture 生成器（`backend/tests/_qmt_fixtures.py`）

Task2/6/9 共用。造「足够 B2 出一个训练组」的最小合法输入：日线数年（≥39 个月边界，即 ≥ ~3.25 年）、1m 覆盖近一年、**每交易日精确 241 根**（session 分钟 09:30–11:30 + 13:01–15:00）、零 drop、OHLC 合法、volume 正整数、amount 有限。返回 `(src_1m: QmtSource, src_daily: QmtSource, entry_1m, entry_daily)`。

```python
# 骨架（实施时按真实 session 分钟集补全，参照 qmt_resample._EXPECTED_SORTED）
import datetime as dt, pandas as pd
from zoneinfo import ZoneInfo
from qmt_normalize import QmtSource
from qmt_ingest import ExportLogEntry
_SH = ZoneInfo("Asia/Shanghai")
SESSION_MIN = list(range(9*60+30, 11*60+30+1)) + list(range(13*60+1, 15*60+0+1))  # 241

def _epoch(d, minute):
    h, m = divmod(minute, 60)
    return int(dt.datetime(d.year, d.month, d.day, h, m, tzinfo=_SH).timestamp())

def gen_valid_sources(code="000001.SZ", n_years_daily=4, n_days_1m=250):
    # 交易日：跳周末（够用即可，无需真实节假日）
    days, d = [], dt.date(2020, 1, 2)
    while len(days) < n_years_daily * 250:
        if d.weekday() < 5: days.append(d)
        d += dt.timedelta(days=1)
    # daily：volume/amount 必须 == 1m 日聚合（否则 reconcile_sources 的 D10 值对账 ohlcv_mismatch，PF2）。
    # 每日 241 根 1m，各 volume=10/amount=102 → 日聚合 volume=2410, amount=24582。
    # OHLC：1m open=首=10.0 / close=尾=10.2 / high=max=10.5 / low=min=9.5 → 日 bar 同值。
    # dense span 外的深历史日无 1m、D10 不对账 → 用同值即可（不影响对账）。
    DAILY_VOL, DAILY_AMT = 241 * 10, round(241 * 102.0, 2)
    drows = [{"datetime": _epoch(x, 0), "open": 10.0, "high": 10.5, "low": 9.5,
              "close": 10.2, "volume": DAILY_VOL, "amount": DAILY_AMT} for x in days]
    df_daily = pd.DataFrame(drows)
    # 1m：最后 n_days_1m 个交易日，每日 241 根
    m1 = []
    for x in days[-n_days_1m:]:
        for mnt in SESSION_MIN:
            m1.append({"datetime": _epoch(x, mnt), "open": 10.0, "high": 10.5,
                       "low": 9.5, "close": 10.2, "volume": 10, "amount": 102.0})
    df_1m = pd.DataFrame(m1)
    s1 = QmtSource(code, "1m", df_1m); sd = QmtSource(code, "daily", df_daily)
    e1 = ExportLogEntry(code, "1m", "ok", len(df_1m), int(df_1m.iloc[0]["datetime"]),
                        int(df_1m.iloc[-1]["datetime"]), code)
    ed = ExportLogEntry(code, "daily", "ok", len(df_daily), int(df_daily.iloc[0]["datetime"]),
                        int(df_daily.iloc[-1]["datetime"]), code)
    return s1, sd, e1, ed
```
> **实测校准**：跑 `build_stock_import(gen_valid_sources())` 若 `no_eligible_training_window`，加大 `n_years_daily`（月边界不足）或调 1m 天数（前向窗口/before-context 不足）。**这些数字必须 dry-run 实测坐实**（spec 内嵌数字不可靠原则）。日线值全相等会让 D10 值对账通过（1m 聚合==日线 bar），刻意如此。

---

## 验收清单（每 PR 一份，非-coder 可执行；动作/预期/通过否；中文；禁「大概/应该/基本」）

**PR 3a：**
| 动作 | 预期 | ☐ |
|---|---|---|
| `cd backend && ../.venv/bin/python -m pytest tests/test_qmt_ingest.py tests/test_qmt_normalize.py -q` | 全 passed、0 failed、0 skipped | ☐ |
| 看 PR diff 里 `build_stock_import` 的门顺序 | 与 spec §4.1 一致（身份→拷贝完整→clean→值→D10→合成→预检） | ☐ |

**PR 3b：**
| 动作 | 预期 | ☐ |
|---|---|---|
| `../.venv/bin/python -m pytest tests/ -q` | 全 passed、测试数 ≥ 3a 后的数 | ☐ |
| 起 Docker PG 跑 `verify_repeatable_read_snapshot.py`（命令见 Task5 Step2） | 打印 6 行 OK + PASS，退出码 0 | ☐ |

**PR 3c：**
| 动作 | 预期 | ☐ |
|---|---|---|
| `../.venv/bin/python -m pytest tests/ -q` | 全 passed | ☐ |
| 看 `write_qmt_stock` 源码 | 无 `assert` 于校验；互锁 SELECT 1 在 DELETE 之前 | ☐ |

**PR 3d：**
| 动作 | 预期 | ☐ |
|---|---|---|
| `../.venv/bin/python -m pytest tests/test_qmt_e2e_generation.py -q` | passed，产 ≥1 zip | ☐ |
| 起 Docker PG 跑 `verify_qmt_pg_chain.py` | 全 PASS、真磁盘出 zip、退出码 0 | ☐ |
| 读 PR body「当前局限」 | 明写：CI 绿≠链路已证（凭 L2 输出）；重导入不作废旧训练组（拆独立 plan）；首次导入前 drain 调度器 | ☐ |
