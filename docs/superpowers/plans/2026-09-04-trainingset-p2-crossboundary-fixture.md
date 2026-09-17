# 跨端接缝的生产者半边（切片一 · 第 2 片）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用**生产顶层装配函数** `assemble_from_windows` 从一组合成 bar 数据产出一个小训练组、把它作为跨端共用 fixture 提交进仓库，并让每次 CI 都把「当前生成器的输出」与「已提交的那份 fixture」按**逻辑内容**对齐。

**Architecture:** 三方钉在同一件产物上 —— ①**手写期望值**（逐周期索引向量，独立人工推算，⛔ 不由生成器算出）→ ②**已提交 fixture**（`tests/contract-fixtures/training-set/999002.SZ_1774972800.zip`）→ ③**现场重建的输出**（每次 CI 跑 `assemble_from_windows` 现产一份）。①↔② 与 ①↔③ 由「生产者半边断言」钉住，②↔③ 由「漂移闸」钉住。任何一方漂移都会红。切片二把 App 侧读取链路接到 ② 上，缝就闭合了。

**Tech Stack:** Python 3.11 / pandas / pytest（`backend/`，CI = `.github/workflows/backend-tests.yml`，Linux、零 skip、**无 paths 过滤器所以每个 PR 都跑**）；SQLite（`PRAGMA user_version`）；zipfile。

**Spec:** `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §4.1（含 note 1/2/3/4、正向对照四项，以及变异 B18 / B53 / B64）

## 本片在整条链子里的位置

| 片 | 范围 | 状态 |
|---|---|---|
| P1 | §3.1 `period_end` · §3.2 分流 · §3.3 第 1/2/3/4b/4c/4d 项 · 确定性压缩 | ✅ MERGED #183（main `db49f60`） |
| **P2（本计划）** | §4.1 跨端 fixture（生产者半边）+ CI 逻辑内容比对 | 本计划 |
| P3 | §3.3 其余：冻结契约 3b/3b-2nd/3b2/3c、`CONTRACT_VERSION` 1.13→1.14、3d 的 m01 矩阵锚、`INSERT` 补 `schema_version` 10 处 + 守卫、Mac 副本作废 + 文案守卫 | 待写 |
| P4 | §3.4 R0–R7 运维重建（Mac 源库 + NAS，人工执行，无测试闭环） | 待写 |

⚠️ **P2 单独可交付、CI 可全绿**，但它**只加测试与 fixture、不改生成器一行逻辑** —— 库里那 3 个训练组仍是第 1 代，App 侧仍消费不了任何真实训练组。

---

## Global Constraints

以下为 spec 的项目级要求，**每个 Task 的要求都隐含包含本节**：

- ⛔ **本片不碰任何 App 逻辑**（`ios/**` 一行不改）。切片二怎么接这份 fixture 是切片二的事，**本计划不替它开药方**，只保证 fixture 落在 `tests/contract-fixtures/` 下（该目录已有现成的 Swift 加载器 `ios/Contracts/Tests/KlineTrainerPersistenceTests/ContractFixtures.swift`，靠 `#filePath` 向上找仓库根，**与本片无耦合**）。
- ⛔ **本片不改 `backend/generate_training_sets.py` 的任何一行逻辑**。它是被测对象；本片只加测试、fixture 产物与再生脚本。
- ⛔ **期望值必须手写**，不得由「跑一遍生成器」得出 —— 否则生产者与校验者会**一起用错公式而全绿**，那正是缺陷藏住的机制（spec §4.1 note 3 / 变异 B18）。本计划里所有期望值均由**独立实现 §2.2 公式**（只用标准库，⛔ 不 import `generate_training_sets`）算出，推导写在各 Task 的注释里，逐条实测记录见 §「前置事实」。
- ⛔ **不得自己串调** `assign_global_indices` → `build_training_set_sqlite` → `zip_and_hash`：真正决定 zip 成员名的是 `assemble_from_windows` 里的 `f"{fname}.db"`（`backend/generate_training_sets.py:469`），绕过它的测试对该行**零敏感**（spec §4.1 note 1 / 变异 B64）。
- ⛔ **漂移闸只比【逻辑内容】，绝不比 zip 原始字节，也绝不断言任何 `content_hash` 字面量**。理由见 §「前置事实」F3（实测：SQLite 文件头 offset 96 存的是写库那台机器的 sqlite 版本号）。
- ⛔ **时区一律用 tz 数据库的 `Asia/Shanghai`**，不得写成固定 `+08:00`。
- 后端 CI 是 **Linux 且零容忍 skip**（`backend-tests.yml` 解析 junit XML，`skipped>0` 即 fail）⇒ ⛔ 本片**不得**出现任何 `pytest.mark.skip` / `skipif` / `importorskip`；fixture 文件缺失必须**红**，不得 skip。
- ⛔ 交付话术：可以说「跨端接缝的生产者半边已交付」；**不得说**「手机能用了」「真实数据链路打通」「跨端契约已闭合」—— App 侧一行未改，闭合归切片二。

---

## 前置事实（全部本机实测，⛔ 不得照抄，实施前请按给出的命令复跑）

> 依据 [[feedback_plan_embedded_facts_unreliable]]：计划里内嵌的**代码**经 dry-run 可靠，内嵌的**事实**必须逐条实测。以下每条都附了取得它的命令。

**F1 — 现有跨语言契约 fixture 的家在 `tests/contract-fixtures/`，两种语言都已在读它。**

```bash
grep -rn "contract-fixtures" backend/tests/test_openapi.py backend/tests/test_routes.py \
  ios/Contracts/Tests/KlineTrainerPersistenceTests/ContractFixtures.swift
```

实测：`test_openapi.py:121` 与 `test_routes.py:25` 都用 `Path(__file__).parent.parent.parent / "tests" / "contract-fixtures"`；Swift 侧 `ContractFixtures.swift:16` 用 `#filePath` 向上找含该目录的祖先当仓库根。⇒ **新增子目录 `tests/contract-fixtures/training-set/` 两侧都够得着，本片无需为切片二做任何布线**。

⚠️ 同时实测：两侧都是**按名字加载**（`(DIR / f"{name}.json")`），**没有任何测试枚举该目录的文件列表** ⇒ 加子目录不会打红既有用例。

**F2 — 后端 CI 每个 PR 都跑，且零容忍 skip。**

```bash
git show origin/main:.github/workflows/backend-tests.yml | sed -n '1,20p'
```

实测 `on: pull_request:` 下**没有 `paths:` 过滤器**（注释明写「别加回来」），且 job 里解析 junit XML、`skipped>0` 即 fail。⇒ spec §4.1 note 4 要求的「每次 CI 都比对」**用一条 pytest 用例即可兑现，不需要新建 workflow**。

⛔ **但它不是必需检查**（[[project_trainingset_p1_implemented]] 记的残留 F5）：`main` 的 ruleset `15660830` 的必需检查只有 6 条，`backend pytest (full suite)` 不在其中 ⇒ **这道闸今天全红也不阻止合并**。本片不修这个洞（见 §「已知残留」R3）。

**F3 — ⭐ SQLite 文件头 offset 96 存的是「最后写这个库的 sqlite 库的版本号」⇒ 比 zip 字节必然跨机假红。**

```bash
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" - <<'PY'
import sqlite3, struct, tempfile, pathlib
p = pathlib.Path(tempfile.mkdtemp())/"x.db"
sqlite3.connect(str(p)).executescript("CREATE TABLE t(a);")
print("offset96 =", struct.unpack(">I", p.read_bytes()[96:100])[0], " sqlite_version =", sqlite3.sqlite_version)
PY
```

本机实测输出：`offset96 = 3053003   sqlite_version = 3.53.3`（3053003 = 3×1000000 + 53×1000 + 3）。

⇒ 三条推论，全部写进判据：
1. ⛔ 漂移闸**不能比 zip 原始字节**（spec §4.1 note 4 的 ⛔ 本来给的理由是「zipfile 嵌 mtime」，那条理由已被 P1 的确定性压缩消解；**这一条是新的、且是真正成立的那条**）。
2. ⛔ **任何测试都不得断言 `content_hash` 的字面量** —— 换台机器就变。
3. ⚠️ 顺带暴露一条**给 P4 的**事实：`content_hash` 依赖写库机器的 sqlite 版本 ⇒ 「产物有疑就重跑 R2、必得同一批包」这条恢复前提**只在同一台机器同一 sqlite 版本下成立**。本片不解决（见 §「已知残留」R1）。

**F4 — 日历与期望值（独立推算，⛔ 未 import `generate_training_sets`）。**

用一份只依赖标准库（`datetime` / `zoneinfo` / `calendar` / `bisect`）的 §2.2 实现算出下表；随后又用**真的** `select_period_window` + `assemble_from_windows` 回读比对，**六个周期逐根全等**。

| 日期 | 星期 | 该周周日（`6 - weekday()`） |
|---|---|---|
| 2026-03-16 | Mon | 2026-03-22 |
| 2026-03-23 | Mon | 2026-03-29 |
| 2026-03-26 | Thu | 2026-03-29 |
| 2026-03-27 | Fri | 2026-03-29 |
| 2026-03-30 | Mon | 2026-04-05 |
| 2026-03-31 | Tue | 2026-04-05 |
| **2026-04-01** | **Wed** | 2026-04-05 |

⇒ 起点取 **2026-04-01（周三 = 周中，同时又是月边界、贴合生产里 start 总落在月边界）**，`select_period_window` 的 weekly before 过滤（`_week_end_date(e) < start 日`）会把 **2026-03-30 那根周线删掉**（其周末 04-05 ≥ 04-01）⇒ spec §4.1 特征③「被删的跨界周」**是真的被生产代码删的**，不是手工挑出来的。

**F5 — 生成器的 DDL 字面量与冻结 DDL 文件之间没有任何守卫。**

```bash
grep -rn "training_set_schema_v1\|_TRAINING_SET_DDL" backend/ scripts/ .github/ tools/ | grep -v '\.pyc'
```

实测：`backend/generate_training_sets.py:364` 只有一句注释宣称「逐字 `backend/sql/training_set_schema_v1.sql`」，**没有任何测试或 CI 步骤比对这两者**；而 `schema-smoke.yml:96` 那道硬门测的是**文件**，生产写库用的是**字面量**。⇒ 两者漂移时闸门会绿着放行。**本片不修**（见 §「已知残留」R2）。

---

## File Structure

| 文件 | 责任 | 本片动作 |
|---|---|---|
| `backend/tests/_trainingset_contract_fixture.py` | 跨端契约 fixture 的**唯一构造入口**：合成 bars → 生产切窗 → 生产装配。**只造输入，不算期望值** | **新建** |
| `backend/tests/test_trainingset_contract_fixture.py` | 生产者半边的全部断言：身份常量、三类特征前提、手写索引向量、漂移闸 | **新建** |
| `backend/scripts/regen_trainingset_contract_fixture.py` | 重新生成并覆盖已提交 fixture 的**唯一**入口（人工执行，带「重生 = 改契约」警告） | **新建** |
| `tests/contract-fixtures/training-set/999002.SZ_1774972800.zip` | 已提交的跨端共用 fixture 产物（二进制，实测 3090 字节） | **新建** |
| `tests/contract-fixtures/training-set/README.md` | 这份 fixture 是什么、怎么再生、⛔ 什么时候**不该**再生、逻辑形态速查 | **新建** |
| `tests/contract-fixtures/README.md` | 既有跨语言契约 fixture 说明 | **改**：加一节指向 `training-set/`（⛔ 只加一节，不动既有文字） |
| `docs/acceptance/2026-09-05-trainingset-p2-acceptance.md` | 非程序员可执行验收清单（治理底线第 2 条，非可豁免） | **新建** |
| `docs/acceptance/2026-09-05-trainingset-p2-mutation-log.md` | 变异验证逐条记录（红的是哪一条测试） | **新建** |

⛔ **本片不改 `backend/generate_training_sets.py`、不改 `backend/sql/**`、不改 `.github/workflows/**`、不改 `ios/**`。**

---

## Task 1: fixture 构造器模块 + 三类特征的前提自证

**Files:**
- Create: `backend/tests/_trainingset_contract_fixture.py`
- Create: `backend/tests/test_trainingset_contract_fixture.py`

**Interfaces:**
- Consumes: `generate_training_sets` 的 `PERIODS` / `PERIOD_BEFORE_CAP` / `select_period_window` / `assemble_from_windows` / `GeneratedTrainingSet`（全部已在 `main` 上存在，本片不改）
- Produces（Task 2–4 都要用）：
  - `STOCK_CODE: str` / `STOCK_NAME: str` / `START_DATETIME: int` / `END_DATETIME: int`
  - `FIXTURE_ZIP_NAME: str` / `FIXTURE_DB_NAME: str` / `FIXTURE_ZIP: pathlib.Path`
  - `RAW_DATETIMES: dict[str, list[int]]`
  - `build_windows() -> dict[str, pandas.DataFrame]`
  - `build_fixture(output_dir: Path) -> GeneratedTrainingSet`

**为什么模块名以 `_` 开头**：`backend/tests/` 已有同款约定（`_qmt_fixtures.py`，被 4 个测试文件以 `from tests._qmt_fixtures import ...` 导入）。下划线前缀让 pytest 的 `python_files = test_*.py` 不会去收集它。

**⚠️ 本 Task 的红绿从哪来**：被测的生成器逻辑在 P1 就已正确落地，所以这些用例**写完就是绿的**。它们是**防退化守卫**，判别力由 Task 5 的变异提供 —— 每写一条断言都要能回答那句口诀「**什么样的改动会让这条测试红？**」，答不上来就说明它判别力为零。本 Task 的三条答案分别是：改起点日期让它不再是周中（特征③消失）、改压缩日内轴让午休/跨日缺口消失（特征②消失）、把 `build_windows` 改成手工挑根不走 `select_period_window`（特征③变成假的）。

- [ ] **Step 1: 写构造器模块**

创建 `backend/tests/_trainingset_contract_fixture.py`：

```python
# backend/tests/_trainingset_contract_fixture.py
"""跨端契约 fixture 的**唯一**构造入口（spec §4.1）。

⭐ 生产者半边的三步全部走**生产代码**：合成 bars → `select_period_window` 切窗
   → `assemble_from_windows` 装配。
⛔ **不得**自己串调 `assign_global_indices` / `build_training_set_sqlite` / `zip_and_hash`：
   真正决定 zip 成员名的是 `assemble_from_windows` 里的 `f"{fname}.db"`，绕过它的测试对
   那一行**零敏感**（spec §4.1 note 1 / 变异 B64）。
⛔ 本模块**只造输入**。期望值（逐周期索引向量）是**手写字面量**，写在
   `test_trainingset_contract_fixture.py` 里 —— ⛔ 绝不由本模块或生成器算出，否则
   生产者与校验者会**一起用错公式而全绿**，那正是缺陷藏住的机制（spec §4.1 note 3 / 变异 B18）。
"""
from __future__ import annotations

import datetime as _dt
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd

from generate_training_sets import (
    PERIOD_BEFORE_CAP,
    PERIODS,
    GeneratedTrainingSet,
    assemble_from_windows,
    select_period_window,
)

_SH = ZoneInfo("Asia/Shanghai")   # ⛔ tz 数据库，不得写固定 +08:00


def _ep(y: int, m: int, d: int, H: int = 0, M: int = 0, S: int = 0) -> int:
    """Asia/Shanghai 的 Unix 秒。"""
    return int(_dt.datetime(y, m, d, H, M, S, tzinfo=_SH).timestamp())


# ── 身份：这三个常量决定 zip 与其内部成员的文件名，属**跨端契约**，改动 = 改契约
STOCK_CODE = "999002.SZ"        # 合成代码（合法格式、非真实上市股）；999001.SZ 已被
                                # backend/scripts/verify_qmt_pg_chain.py 占用
STOCK_NAME = "跨端契约样例"       # 刻意非 ASCII：顺带把 UTF-8 往返也钉进 fixture
START_DATETIME = _ep(2026, 4, 1)        # 周三 = **周中**（特征③的前提），同时是月边界
END_DATETIME = _ep(2026, 4, 2) - 1      # 起点当日 23:59:59

FIXTURE_ZIP_NAME = f"{STOCK_CODE}_{START_DATETIME}.zip"
FIXTURE_DB_NAME = f"{STOCK_CODE}_{START_DATETIME}.db"

# 仓库根 = backend/tests/ 的上上级（与 backend/tests/test_openapi.py:121 同款算法，
# ⇒ 与进程 CWD 无关；CI 是 `working-directory: backend` 跑的）。
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
FIXTURE_ZIP = REPO_ROOT / "tests" / "contract-fixtures" / "training-set" / FIXTURE_ZIP_NAME

# ── 压缩交易日（spec §4.1 note 3 ⭐ 明许）：每个交易日只放 6 根 3m，
#    照样覆盖「跨午休」（11:30 → 14:57）与「跨日」（15:00 → 次日 09:33）两条边界。
#    依据：`assemble_from_windows` 不校验每日根数（`per_day_intraday_complete` 只在
#    `build_training_windows` 里被调）⇒ 手写期望值控制在几十个量级。
_DAYS = ((2026, 3, 27), (2026, 3, 30), (2026, 3, 31), (2026, 4, 1))   # 五 / 一 / 二 / 三
_INTRADAY = ((9, 33), (9, 36), (11, 27), (11, 30), (14, 57), (15, 0))

RAW_DATETIMES: dict[str, list[int]] = {
    "3m":      [_ep(*day, *hm) for day in _DAYS for hm in _INTRADAY],
    "15m":     [_ep(*day, *hm) for day in _DAYS for hm in ((11, 30), (15, 0))],
    "60m":     [_ep(*day, 15, 0) for day in _DAYS],
    # 多给一根 03-26（起点前一天）：它的 period_end 早于 3m 轴首 ⇒ clamp 到 0
    "daily":   [_ep(2026, 3, 26)] + [_ep(*day) for day in _DAYS],
    # 03-30 那根会被 select_period_window 删掉（周末 04-05 ≥ 起点当日 04-01）⇒ 洞
    "weekly":  [_ep(2026, 3, 16), _ep(2026, 3, 23), _ep(2026, 3, 30)],
    # 前两根的月末都早于 3m 轴首 ⇒ 两根都 clamp 到 0 = spec §4.1 特征①
    "monthly": [_ep(2026, 1, 1), _ep(2026, 2, 1), _ep(2026, 3, 1), _ep(2026, 4, 1)],
}


def _synth_bars(period: str, datetimes: list[int]) -> pd.DataFrame:
    """确定性合成 bar：所有数值只由**该周期内的序号 i** 决定 ⇒ 同一输入恒等。

    `0.25` 在二进制里精确可表示，避免浮点累加漂移让 fixture 字节随平台变。
    指标列刻意全部给**真值而非 NULL**，让切片二的读取链路也要真的解一遍。
    """
    rows = []
    for i, e in enumerate(datetimes):
        close = 10.0 + i * 0.25
        rows.append({
            "period": period, "datetime": e,
            "open": close - 0.1, "high": close + 0.2, "low": close - 0.2, "close": close,
            "volume": 1000 + i, "amount": round(close * (1000 + i), 2),
            "ma66": round(close - 0.05, 4), "boll_upper": round(close + 1, 4),
            "boll_mid": round(close, 4), "boll_lower": round(close - 1, 4),
            "macd_diff": round(0.01 * i, 6), "macd_dea": round(0.008 * i, 6),
            "macd_bar": round(0.004 * i, 6),
        })
    return pd.DataFrame(rows)


def build_windows() -> dict[str, pd.DataFrame]:
    """走**生产**切窗函数 `select_period_window` 把合成 bars 切成 windows。

    ⛔ **不得**改成「手工挑几根塞进去」：spec §4.1 特征③要的是一处**真的被生产代码删掉**
    的跨界周。手工挑根的话，那条特征就是假的 —— 生产切窗逻辑哪天改了也不会有人红。
    """
    return {p: select_period_window(_synth_bars(p, RAW_DATETIMES[p]),
                                    START_DATETIME, PERIOD_BEFORE_CAP[p],
                                    END_DATETIME, p)
            for p in PERIODS}


def build_fixture(output_dir) -> GeneratedTrainingSet:
    """产出一份训练组 zip 到 `output_dir`，返回生成器自己的 `GeneratedTrainingSet`。"""
    return assemble_from_windows(Path(output_dir), stock_code=STOCK_CODE, stock_name=STOCK_NAME,
                                 start_datetime=START_DATETIME, end_datetime=END_DATETIME,
                                 windows=build_windows())
```

- [ ] **Step 2: 写前提自证测试**

创建 `backend/tests/test_trainingset_contract_fixture.py`：

⚠️ 下面这份 import 块**已经把 Task 2–4 要用的名字一起列全了**（`build_fixture` / `FIXTURE_ZIP` 在本 Task 里还用不上）—— 刻意如此，免得后面三个 Task 各改一次 import。本仓没有配 flake8 / ruff，未使用的 import 不会打红任何闸门（实测：`.github/workflows/` 下无任何 lint 步骤）。

```python
# backend/tests/test_trainingset_contract_fixture.py
"""跨端接缝的**生产者半边**（spec §4.1）。

三方钉在同一件产物上：
  ① 手写期望值（本文件里的字面量，独立人工推算）
  ② 已提交 fixture（tests/contract-fixtures/training-set/*.zip）
  ③ 现场重建的生成器输出（每次 CI 现产一份）
①↔② 与 ①↔③ 由「生产者半边断言」钉住，②↔③ 由「漂移闸」钉住。
切片二把 App 侧读取链路接到 ② 上，spec §1.4 那道缝才算闭合 —— **本片不做那一半**。
"""
from __future__ import annotations

import datetime as _dt
from zoneinfo import ZoneInfo

import pytest

from generate_training_sets import PERIODS
from tests._trainingset_contract_fixture import (
    END_DATETIME,
    FIXTURE_DB_NAME,
    FIXTURE_ZIP,
    FIXTURE_ZIP_NAME,
    RAW_DATETIMES,
    START_DATETIME,
    build_fixture,
    build_windows,
)

_SH = ZoneInfo("Asia/Shanghai")


def _ep(y, m, d, H=0, M=0, S=0):
    """测试内**独立**实现的 Asia/Shanghai 秒（⛔ 不复用被测模块的辅助函数）。"""
    return int(_dt.datetime(y, m, d, H, M, S, tzinfo=_SH).timestamp())


# ── Task 1：身份常量与三类特征的前提

def test_fixture_identity_constants_are_pinned():
    """文件名进跨端契约（切片二要按这个名字找它）⇒ 常量必须钉住字面量。

    ⚠️ 这里刻意写死数字而不是「再算一遍」：再算一遍等于把两边接到同一个公式上，
    公式错了两边一起错（同 spec 变异 B18 要防的机制）。
    """
    assert START_DATETIME == 1774972800      # 2026-04-01 00:00:00 +08:00
    assert END_DATETIME == 1775059199        # 2026-04-01 23:59:59 +08:00
    assert FIXTURE_ZIP_NAME == "999002.SZ_1774972800.zip"
    assert FIXTURE_DB_NAME == "999002.SZ_1774972800.db"


def test_start_datetime_is_midweek_wednesday():
    """特征③的前提：起点必须落在**周中** —— 落周一就没有跨界周可删了。"""
    got = _dt.datetime.fromtimestamp(START_DATETIME, _SH)
    assert (got.year, got.month, got.day) == (2026, 4, 1)
    assert got.strftime("%a") == "Wed"


def test_windows_carry_the_three_required_features():
    """spec §4.1 note 2 的**特征②③**必须真的在窗口里（而不是只写在注释里）。

    ⚪ 特征①（≥2 根落在 `end_global_index = 0`）在**窗口层面看不出来** —— 它是赋索引之后
       才成立的性质，由 Task 2 的 `monthly` 期望值 `[0, 0, 17, 23]` 断言。
    """
    w = build_windows()

    # 特征③：2026-03-30 那根周线在原始数据里有、在窗口里没有 ⇒ 被生产切窗删掉了
    weekly = [int(x) for x in w["weekly"]["datetime"]]
    assert _ep(2026, 3, 30) in RAW_DATETIMES["weekly"], "原始 weekly 里必须先有那根，否则删无可删"
    assert _ep(2026, 3, 30) not in weekly, "跨界周没被删 ⇒ 特征③是假的"
    assert weekly == [_ep(2026, 3, 16), _ep(2026, 3, 23)]

    # 特征②：3m 轴上必须同时存在跨午休缺口与跨日缺口
    axis = [int(x) for x in w["3m"]["datetime"]]
    assert len(axis) == 24
    assert axis[3] == _ep(2026, 3, 27, 11, 30), "轴上第 4 根应是上午收盘"
    assert axis[4] == _ep(2026, 3, 27, 14, 57), "紧邻的下一根应跨过午休"
    assert axis[5] == _ep(2026, 3, 27, 15, 0), "轴上第 6 根应是当日收盘"
    assert axis[6] == _ep(2026, 3, 30, 9, 33), "紧邻的下一根应跨到下一个交易日"

    # 各周期窗口根数（特征①的具体期望值在下一条用例里断言）
    assert {p: len(w[p]) for p in PERIODS} == {
        "monthly": 4, "weekly": 2, "daily": 5, "60m": 4, "15m": 8, "3m": 24}


def test_build_windows_goes_through_production_select_period_window(monkeypatch):
    """⛔ 窗口必须由**生产**切窗函数切出来，不得手工挑根。

    判据 = monkeypatch 掉 `_trainingset_contract_fixture` 里绑定的那个名字后，
    `build_windows()` 必须对**每个周期各调用一次**。
    若哪天有人把 `build_windows` 改成「自己挑几根塞进去」（**哪怕挑出来的结果与今天逐根相同**），
    spy 不会被调用 ⇒ 本测试红 —— 而上面那条只比较窗口内容的用例**抓不住这种改法**。
    ⭐ 本仓已有同款守卫：`test_generate_training_sets.py::test_week_end_date_is_module_level_and_shared`。
    ⚠️ 必须 patch **本 fixture 模块里绑定的那个名字**（`from ... import select_period_window`
       是模块级绑定）；patch `generate_training_sets` 那边的名字对本调用点无效，会得到一条恒绿的空测试。
    """
    import tests._trainingset_contract_fixture as fx

    calls: list[str] = []
    real = fx.select_period_window

    def spy(bars, start_datetime, before_cap, after_end, period, month_boundaries=None):
        calls.append(period)
        return real(bars, start_datetime, before_cap, after_end, period, month_boundaries)

    monkeypatch.setattr(fx, "select_period_window", spy)
    fx.build_windows()
    assert sorted(calls) == sorted(PERIODS), (
        f"build_windows 没有对每个周期各调一次生产切窗函数（实测 {calls}）"
        f"—— 说明它绕过了 select_period_window，特征③就成了手工摆出来的假象")
```

⭐ **这条守卫是任务级评审挖出来的**（原计划没有，2026-09-04 修复轮 1 补入）：只比较窗口**内容**的话，
「绕过 `select_period_window`、手工丢掉 03-30 那根」会产出与今天**逐根相同**的结果 ⇒ 上面那条用例照样绿，
「产物必须由生产代码产出」这条契约就只剩注释在管。控制者亲手跑过该变异实证：变异下**本条红、上面那条绿**。

- [ ] **Step 3: 跑，确认全绿**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_trainingset_contract_fixture.py -v
```

Expected: **4 passed**（`test_fixture_identity_constants_are_pinned` / `test_start_datetime_is_midweek_wednesday` / `test_windows_carry_the_three_required_features` / `test_build_windows_goes_through_production_select_period_window`）

⚠️ 本仓 worktree 里**没有 `.venv`**，Python 解释器在主仓根：`/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3`（裸 `python3` 会 `ModuleNotFoundError: No module named 'pandas'`）。

- [ ] **Step 4: 跑全套，确认没打红既有用例**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q 2>&1 | tail -5
```

Expected: `1125 passed`（`origin/main` 实测基线 **1121**，本 Task 加 4 条），**0 failed / 0 skipped**。

- [ ] **Step 5: Commit**

```bash
git add backend/tests/_trainingset_contract_fixture.py backend/tests/test_trainingset_contract_fixture.py
git commit -m "test(trainingset): 跨端契约 fixture 构造器 + 三类特征前提自证（P2 Task 1）"
```

---

## Task 2: 生产者半边断言（手写期望值）

**Files:**
- Modify: `backend/tests/test_trainingset_contract_fixture.py`（在 Task 1 的内容后追加）

**Interfaces:**
- Consumes: Task 1 的 `build_fixture`
- Produces: `_open_zip_db(zip_path)` 上下文管理器（Task 4 的漂移闸要复用）、`EXPECTED_END_GLOBAL_INDEX` 字典

**期望值怎么来的**（⛔ 未 import `generate_training_sets`；用只依赖标准库的 §2.2 实现算出，随后又用真代码回读比对、六个周期逐根全等）：

3m 轴 24 根，下标：

```
03-27(Fri)  0=09:33  1=09:36  2=11:27  3=11:30  4=14:57  5=15:00
03-30(Mon)  6=09:33  7=09:36  8=11:27  9=11:30 10=14:57 11=15:00
03-31(Tue) 12=09:33 13=09:36 14=11:27 15=11:30 16=14:57 17=15:00
04-01(Wed) 18=09:33 19=09:36 20=11:27 21=11:30 22=14:57 23=15:00
```

| 周期 | 窗口内 `datetime` | `period_end`（§2.2） | `bisect_right(轴, upper) − 1` 后 clamp | **新公式期望** | 旧公式（「下一根 − 1」）会给出 |
|---|---|---|---|---|---|
| `3m` | 轴本身 24 根 | 各自本身（收盘标注） | 逐根自指 | `[0..23]` | `[0..23]`（**同** ⇒ 正向对照） |
| `15m` | 每日 11:30 与 15:00，共 8 根 | 各自本身 | | `[3, 5, 9, 11, 15, 17, 21, 23]` | `[4, 8, 10, 14, 16, 20, 22, 23]`（**前 7 根全不同**：跨午休 / 跨日各晚一截） |
| `60m` | 每日 15:00，共 4 根 | 各自本身 | | `[5, 11, 17, 23]` | `[10, 16, 22, 23]`（**前 3 根全不同**） |
| `daily` | 03-26 / 03-27 / 03-30 / 03-31 / 04-01 | 当日 23:59:59 | 03-26 的早于轴首 ⇒ clamp 0 | `[0, 5, 11, 17, 23]` | `[0, 5, 11, 17, 23]`（**同** ⇒ 正向对照） |
| `weekly` | 03-16 / 03-23（03-30 被删） | 03-22 / 03-29 的 23:59:59 | 03-22 早于轴首 ⇒ 0；03-29 落在 03-27 与 03-30 之间 ⇒ 5 | `[0, 5]` | `[0, 23]`（末根退化到轴末 ⇒ **差 18 根**） |
| `monthly` | 01-01 / 02-01 / 03-01 / 04-01 | 01-31 / 02-28 / 03-31 / 04-30 的 23:59:59 | 前两根早于轴首 ⇒ 都 0；03-31 落在 03-31 15:00 与 04-01 09:33 之间 ⇒ 17；04-30 晚于轴末 ⇒ clamp 23 | `[0, 0, 17, 23]` | `[0, 0, 17, 23]`（**同** ⇒ 正向对照） |

⇒ spec §4.1 note 2 的三类特征逐条兑现：
- ①「至少一个非 m3 周期有 ≥2 根落在 `end_global_index = 0`」→ `monthly` 前两根都是 0（`weekly` 与 `daily` 各另有一根 0）；
- ②「含跨午休与跨日的日内边界」→ `15m` / `60m` 与旧公式差出来的就是这两条边界；
- ③「含一处被删的跨界周」→ `weekly` 只剩 2 根、`[0, 5]` 与旧公式差 18 根。

⇒ spec §4.1 正向对照 ① 兑现：`daily` / `monthly` / `3m` 三个周期**逐根不变** ⇒ 健康输入被放行，不是「全是拒了」的套件。

**⚠️ 本 Task 的红绿从哪来**：同 Task 1，判别力由 Task 5 的变异提供。这套断言要能回答「什么样的改动会让它红」：改 `period_end` 的分流（`15m`/`60m`/`weekly` 三条红）、把分流反过来（`daily`/`monthly` 红）、把 `assemble_from_windows` 的成员名后缀改掉（**不红** —— 那是 Task 4 的活，spec 变异 B64 明写这两条必须分开记）。

- [ ] **Step 1: 追加期望值与读取辅助**

在 `backend/tests/test_trainingset_contract_fixture.py` 末尾追加：

```python
# ── Task 2：生产者半边断言（spec §4.1 note 3）

import contextlib          # noqa: E402
import sqlite3             # noqa: E402
import tempfile            # noqa: E402
import zipfile             # noqa: E402
from pathlib import Path   # noqa: E402

# ⛔ 手写字面量。推导见本片计划 Task 2 的表格。
# ⛔ **绝不**允许写成运行时调 `period_end` / `assign_global_indices` 现算（spec 变异 B18）：
#    那样生产者与校验者接到同一个公式上，公式改错两边**一起绿**，缺陷原样藏住。
EXPECTED_END_GLOBAL_INDEX: dict[str, list[int]] = {
    # 收盘标注：各自指向自己那一刻
    "3m":      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
                12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23],
    "15m":     [3, 5, 9, 11, 15, 17, 21, 23],
    "60m":     [5, 11, 17, 23],
    # 开盘侧标注：指向所属日历周期的最后一刻
    "daily":   [0, 5, 11, 17, 23],
    "weekly":  [0, 5],                 # 03-30 那根被删 ⇒ 03-23 那根按【日历周末】落在 5
    "monthly": [0, 0, 17, 23],         # 前两根月末早于 3m 轴首 ⇒ clamp 0（特征①）
}


@contextlib.contextmanager
def _open_zip_db(zip_path):
    """打开训练组 zip 里那**唯一**一个成员，落临时文件后用 sqlite3 打开。

    顺带兑现 spec §4.1 note 3 的压缩包清单判据：恰好 1 个成员、无 sidecar。
    """
    zip_path = Path(zip_path)
    with zipfile.ZipFile(zip_path) as zf:
        members = zf.namelist()
        assert len(members) == 1, f"训练组 zip 必须恰好 1 个成员（无 sidecar），实测 {members}"
        blob = zf.read(members[0])
    with tempfile.TemporaryDirectory() as td:
        member_path = Path(td) / "member.db"
        member_path.write_bytes(blob)
        conn = sqlite3.connect(str(member_path))
        try:
            yield members, conn
        finally:
            conn.close()
```

- [ ] **Step 2: 追加生产者断言**

继续追加：

```python
@pytest.mark.parametrize("source", ["fresh"])
def test_fixture_matches_hand_written_expectations(source, tmp_path):
    """逐周期索引向量必须等于**独立人工推算**的期望（spec §4.1 note 3）。

    ⚠️ Task 3 会把 `source` 的取值扩成 ["fresh", "committed"]，让**已提交的那份产物**
    也过同一套断言 —— 现在还没有已提交产物，先只跑现场重建这一路。
    """
    zip_path = build_fixture(tmp_path).path if source == "fresh" else FIXTURE_ZIP

    with _open_zip_db(zip_path) as (members, conn):
        # 压缩包清单
        assert len(members) == 1
        assert Path(members[0]).suffix in (".sqlite", ".db"), (
            f"训练组 zip 成员后缀必须是 .sqlite 或 .db，实测 {members[0]!r}")
        # ⭐ 压缩**方法**也要钉（最终评审 Important 1，实证：改成 BZIP2 后全仓 126 passed / 0 failed）：
        # App 侧解压用 ZIPFoundation（`ios/Contracts/Package.swift` 钉 0.9.0..<1.0.0），
        # 它只实现 store 与 deflate ⇒ 换成 BZIP2 / LZMA 会在**手机上**解不开，而生产者半边
        # 与已提交 fixture **两边都还是绿的** —— 正是本切片要堵的那个「两边绿、缝里烂」机制。
        # ⚪ `compress_type` 是个**声明常量**（8 = deflate），不是压缩后的字节 ⇒ 跨机器稳定，
        #    不犯「比字节导致跨机假红」那类错（见本片计划 §前置事实 F3）。
        with zipfile.ZipFile(zip_path) as _zf:
            got_method = _zf.getinfo(members[0]).compress_type
        assert got_method == zipfile.ZIP_DEFLATED, (
            f"压缩方法必须是 deflate（{zipfile.ZIP_DEFLATED}），实测 {got_method}")
        # 产物代际（⛔ 写字面量 2，不 import SCHEMA_VERSION：import 会让断言自我实现）
        assert conn.execute("PRAGMA user_version").fetchone()[0] == 2

        # 逐周期索引向量
        for period, expected in EXPECTED_END_GLOBAL_INDEX.items():
            got = [r[0] for r in conn.execute(
                "SELECT end_global_index FROM klines WHERE period=? ORDER BY id", (period,))]
            assert got == expected, f"{period} 的 end_global_index 与手写期望不符：{got} != {expected}"

        # global_index：仅 3m 赋值、其余全 NULL（D2/D4 契约，本片顺带钉住）
        gi3 = [r[0] for r in conn.execute(
            "SELECT global_index FROM klines WHERE period='3m' ORDER BY id")]
        assert gi3 == EXPECTED_END_GLOBAL_INDEX["3m"]
        non_null = conn.execute(
            "SELECT count(*) FROM klines WHERE period<>'3m' AND global_index IS NOT NULL"
        ).fetchone()[0]
        assert non_null == 0, "非 3m 周期的 global_index 必须全为 NULL"

        # meta 单行（含非 ASCII 股票名的 UTF-8 往返）
        assert conn.execute(
            "SELECT stock_code, stock_name, start_datetime, end_datetime FROM meta").fetchall() == [
            ("999002.SZ", "跨端契约样例", 1774972800, 1775059199)]
        assert conn.execute("SELECT count(*) FROM klines").fetchone()[0] == 47   # 4+2+5+4+8+24
```

- [ ] **Step 3: 跑，确认绿**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_trainingset_contract_fixture.py -v
```

Expected: **5 passed**（新增 `test_fixture_matches_hand_written_expectations[fresh]`）

- [ ] **Step 4: 当场自测判别力（不进变异记录，只为确认这条断言不是恒真）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" - <<'PY'
# 临时把期望里 15m 的第一项改错，确认断言真的会红（不落盘、不改仓库文件）
import re, pathlib, subprocess, sys, tempfile, shutil, os
src = pathlib.Path("tests/test_trainingset_contract_fixture.py")
bak = pathlib.Path(tempfile.mkdtemp()) / "bak.py"
shutil.copyfile(src, bak)
try:
    t = src.read_text(encoding="utf-8").replace('"15m":     [3, 5,', '"15m":     [4, 5,', 1)
    src.write_text(t, encoding="utf-8")
    for p in pathlib.Path("tests").rglob("__pycache__"):
        shutil.rmtree(p, ignore_errors=True)
    r = subprocess.run([sys.executable, "-m", "pytest",
                        "tests/test_trainingset_contract_fixture.py", "-q"],
                       capture_output=True, text=True)
    print("退出码 =", r.returncode, "（应为非 0）")
    print([l for l in r.stdout.splitlines() if "15m" in l or "failed" in l][:5])
finally:
    shutil.copyfile(bak, src)
    for p in pathlib.Path("tests").rglob("__pycache__"):
        shutil.rmtree(p, ignore_errors=True)
PY
```

Expected: 退出码非 0，且失败信息里出现 `15m 的 end_global_index 与手写期望不符`。

⚠️ 复原用的是**事先 `cp` 的副本**，⛔ 不用 `git checkout <file>`（会连未提交改动一起抹掉）。跑完必须再看一次 `git status --short` 确认干净。

- [ ] **Step 5: Commit**

```bash
git status --short   # 必须为空
git add backend/tests/test_trainingset_contract_fixture.py
git commit -m "test(trainingset): 生产者半边手写期望值断言（P2 Task 2）"
```

---

## Task 3: 再生脚本 + 提交 fixture 产物 + README

**Files:**
- Create: `backend/scripts/regen_trainingset_contract_fixture.py`
- Create: `tests/contract-fixtures/training-set/999002.SZ_1774972800.zip`（**二进制产物**，由上面那个脚本产出）
- Create: `tests/contract-fixtures/training-set/README.md`
- Modify: `tests/contract-fixtures/README.md`（**只追加一节**）
- Modify: `backend/tests/test_trainingset_contract_fixture.py`（把 `source` 参数扩成两路 + 加一条「fixture 必须存在」）

**Interfaces:**
- Consumes: Task 1 的 `FIXTURE_ZIP` / `build_fixture`
- Produces: 仓库里那份已提交 fixture（Task 4 的漂移闸要拿它当比较基准）

- [ ] **Step 1: 写再生脚本**

创建 `backend/scripts/regen_trainingset_contract_fixture.py`：

```python
#!/usr/bin/env python3
"""重新生成跨端契约 fixture（spec §4.1）。

⚠️ **重新生成 = 改契约。** 这份 zip 是「当前生成器输出 / 已提交 fixture / App 侧读取链路」
   三方共同钉住的**同一件**产物；它一变，切片二的 App 侧链路必须重跑。
⛔ **不得**为了让 `test_committed_fixture_matches_current_generator` 变绿而顺手跑本脚本 ——
   那道闸红了说明**生成器行为变了**，先判断那是不是有意的改动。

用法（在仓库任意目录）：
    python3 backend/scripts/regen_trainingset_contract_fixture.py
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

# backend/ 本身要在 sys.path 上，才能 `from tests._trainingset_contract_fixture import ...`
# （与 backend/tests/ 下测试文件的隐式 import 方式一致；同 backend/scripts/verify_qmt_pg_chain.py）。
_BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(_BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(_BACKEND_DIR))

from tests._trainingset_contract_fixture import FIXTURE_ZIP, build_fixture  # noqa: E402


def main() -> int:
    old = FIXTURE_ZIP.read_bytes() if FIXTURE_ZIP.exists() else None
    FIXTURE_ZIP.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        gen = build_fixture(Path(td))
        # ⭐ **原子替换**：先落到同目录的临时名，再 `os.replace` 顶上去。
        # `shutil.copyfile` 是「先截断再写」——中途崩/断电/写满盘会让**已提交的契约产物**
        # 变成半截文件，而它正是三方共同钉住的那一件东西。同目录 ⇒ 同文件系统 ⇒ replace 原子。
        staged = FIXTURE_ZIP.parent / (FIXTURE_ZIP.name + ".tmp")
        try:
            shutil.copyfile(gen.path, staged)
            os.replace(staged, FIXTURE_ZIP)
        finally:
            staged.unlink(missing_ok=True)   # 复制失败时不留残渣
    new = FIXTURE_ZIP.read_bytes()

    with zipfile.ZipFile(FIXTURE_ZIP) as zf:
        members = zf.namelist()

    print(f"写入 {FIXTURE_ZIP}")
    print(f"  成员清单     : {members}")
    print(f"  字节数       : {len(new)}")
    print(f"  content_hash : {gen.content_hash}"
          f"   ⚠️ 随写库机器的 sqlite 版本变，⛔ 不得写进任何断言")
    if old is None:
        print("  （原先不存在，本次新建）")
    elif old == new:
        print("  内容与原先**逐字节相同**")
    else:
        print(f"  ⚠️ 内容变了（原 {len(old)} 字节）—— 这是**契约变更**，"
              f"切片二的 App 侧读取链路必须重跑")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: 跑它，产出 fixture**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" backend/scripts/regen_trainingset_contract_fixture.py
```

Expected（本机实测值，⚠️ `content_hash` 与字节数在别的 sqlite 版本上会不同，**以「成员清单只有 1 个且以 `.db` 结尾」为准，不要拿这两个数字当判据**）：

```
写入 .../tests/contract-fixtures/training-set/999002.SZ_1774972800.zip
  成员清单     : ['999002.SZ_1774972800.db']
  字节数       : 3090
  content_hash : f2586fd8   ⚠️ 随写库机器的 sqlite 版本变，⛔ 不得写进任何断言
  （原先不存在，本次新建）
```

- [ ] **Step 3: 写 fixture 目录 README**

创建 `tests/contract-fixtures/training-set/README.md`：

```markdown
# 训练组跨端契约 fixture

`999002.SZ_1774972800.zip` 是**唯一**一份跨端共用的训练组样本，由后端**生产**装配函数
`assemble_from_windows` 产出（spec `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §4.1）。

它同时被三方钉住：

1. **手写期望值** —— `backend/tests/test_trainingset_contract_fixture.py` 里的字面量，
   由人工按 spec §2.2 的公式独立推算，⛔ 不是「跑一遍生成器抄回来」的；
2. **已提交的这份产物** —— 就是本目录里的这个 zip；
3. **当前生成器的现场输出** —— 每次后端 CI 都重跑一次 `assemble_from_windows`，
   与本文件按**逻辑内容**比对（`test_committed_fixture_matches_current_generator`）。

⇒ 三方任何一方漂移都会红。切片二会把 App 侧的「解压 → 打开 → 读取」链路接到**这一份**上
（⛔ 不是另造一份），spec §1.4 那道「两侧静态 fixture 各自漂移」的缝才算闭合。

## 逻辑形态速查

| 项 | 值 |
|---|---|
| 压缩包成员 | 恰好 1 个：`999002.SZ_1774972800.db`（⛔ 无 sidecar） |
| `PRAGMA user_version` | `2` |
| `meta` | 1 行：`999002.SZ` / `跨端契约样例` / `1774972800` / `1775059199` |
| `klines` 行数 | 47 = monthly 4 + weekly 2 + daily 5 + 60m 4 + 15m 8 + 3m 24 |
| 3m 轴 | 4 个交易日（2026-03-27 / 03-30 / 03-31 / 04-01）× 每日 6 根（09:33 / 09:36 / 11:27 / 11:30 / 14:57 / 15:00） |
| `end_global_index` | `3m` `[0..23]` · `15m` `[3,5,9,11,15,17,21,23]` · `60m` `[5,11,17,23]` · `daily` `[0,5,11,17,23]` · `weekly` `[0,5]` · `monthly` `[0,0,17,23]` |

三类刻意做进去的特征（spec §4.1 note 2）：

- ① `monthly` 前两根落在 `end_global_index = 0`（月末早于 3m 轴首）；
- ② `15m` / `60m` 跨**午休**（11:30 → 14:57）与跨**日**（15:00 → 次日 09:33）两条边界；
- ③ 起点 2026-04-01 是**周三**，`select_period_window` 把 2026-03-30 那根周线删掉 ⇒ 周线序列**有洞**。

## ⛔ 没有记录 content_hash / 字节数，这是有意的

SQLite 文件头 offset 96 存的是「最后写这个库的 sqlite 库的版本号」（本机实测 `3053003` = 3.53.3）
⇒ 换一台机器、升一次 sqlite，zip 的字节与 CRC32 都会变。所以：

- ⛔ 任何测试都**不得**断言 `content_hash` 字面量，也**不得**比 zip 原始字节；
- ✅ 比对一律走**逻辑内容**：压缩包成员清单 + `PRAGMA user_version` + `sqlite_master` + `meta` 与 `klines` 的全部行。

## 怎么重新生成

```bash
python3 backend/scripts/regen_trainingset_contract_fixture.py
```

⚠️ **重新生成 = 改契约。**
⛔ 如果你是因为 `test_committed_fixture_matches_current_generator` 红了才来跑这条命令，**先停下**：
那道闸红了说明**生成器的行为变了**。先判断那是不是有意的 ——

- **有意**（比如又 bump 了一代产物）⇒ 重生 fixture，并把切片二的 App 侧读取链路一并重跑；
- **无意** ⇒ 这就是回归，该改的是生成器，不是 fixture。
```

- [ ] **Step 4: 在父 README 里加一节指路**

在 `tests/contract-fixtures/README.md` **末尾追加**（⛔ 不动既有文字）：

```markdown

## training-set/：训练组跨端契约 fixture

`training-set/` 下那份 zip 是训练组产物的跨端共用样本（后端生成器 ↔ App 读取链路），
形态、判据与再生方式见 `training-set/README.md`。它与本目录下的 JSON 是**两类**东西：
JSON 钉的是 HTTP 接口的响应形状，那份 zip 钉的是**下载下来的训练组文件本身**。
```

- [ ] **Step 5: 让已提交的那份也过生产者断言**

把 Task 2 那条用例的 `parametrize` 改成两路，并新增一条「fixture 必须存在」：

```python
def test_committed_fixture_file_exists():
    """⛔ 缺文件必须**红**，不得 skip —— 后端 CI 零容忍 skip，一条 skip 会被当成覆盖缺口。"""
    assert FIXTURE_ZIP.is_file(), (
        f"跨端契约 fixture 缺失：{FIXTURE_ZIP}\n"
        f"用 `python3 backend/scripts/regen_trainingset_contract_fixture.py` 生成它。")
```

并把

```python
@pytest.mark.parametrize("source", ["fresh"])
```

改成

```python
@pytest.mark.parametrize("source", ["fresh", "committed"])
```

并把该用例 docstring 里那句**已经过期**的话（`⚠️ Task 3 会把 source 的取值扩成 …—— 现在还没有已提交产物，先只跑现场重建这一路。`）替换成：

```python
    ⭐ **两路都要跑**：`fresh` = 现场重建的生成器输出，`committed` = 仓库里那份已提交 fixture。
    手写期望值同时钉住这两者 ⇒ 三方（手写期望 / 已提交产物 / 当前生成器）中任何一方漂移都会红。
    ⚠️ 若只跑 `fresh`，已提交那份产物就没有任何判据看着它，切片二会对着一份没人验过的产物开发。
```

⛔ **不改这句就会留下一份自相矛盾的文档**：`parametrize` 上写着 `["fresh", "committed"]`，紧邻两行下面的 docstring 却说「现在还没有已提交产物」。

- [ ] **Step 6: 跑，确认绿**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_trainingset_contract_fixture.py -v
```

Expected: **7 passed**（新增 `test_committed_fixture_file_exists` 与 `…[committed]`）

- [ ] **Step 7: 确认再生是幂等的（同机同 sqlite 下）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" backend/scripts/regen_trainingset_contract_fixture.py && \
git status --short tests/contract-fixtures/training-set/
```

Expected: 脚本打印「内容与原先**逐字节相同**」，且 `git status` 对该 zip **无输出**（未修改）。

- [ ] **Step 8: Commit**

```bash
git add backend/scripts/regen_trainingset_contract_fixture.py \
        tests/contract-fixtures/training-set/ tests/contract-fixtures/README.md \
        backend/tests/test_trainingset_contract_fixture.py
git commit -m "test(trainingset): 提交跨端契约 fixture 产物 + 再生脚本 + README（P2 Task 3）"
```

---

## Task 4: 漂移闸 —— 现场重建 vs 已提交 fixture 的逻辑内容比对

**Files:**
- Modify: `backend/tests/test_trainingset_contract_fixture.py`（追加）

**Interfaces:**
- Consumes: Task 2 的 `_open_zip_db`、Task 1 的 `build_fixture` / `FIXTURE_ZIP`
- Produces: 无（终点用例）

**这条闸挡的是什么**（spec §4.1 note 4 的 ⚠️）：生成器日后改了序列化 / DDL / 版本，**生产者侧的测试对着新鲜输出照样绿**，而 App 侧对着**陈旧的已提交 fixture** 也照样绿 —— 两边都绿，缺陷照旧静默。这一条是唯一把两者绑在一起的东西。

**⛔ 比什么、不比什么**：比**逻辑内容** = 压缩包成员清单 + `PRAGMA user_version` + `sqlite_master`（不含 `sqlite_` 开头的内部表）+ `meta` 全行 + `klines` 全行。⛔ **不比 zip 原始字节、不比 `content_hash`** —— 见 §「前置事实」F3。

- [ ] **Step 1: 追加漂移闸**

在 `backend/tests/test_trainingset_contract_fixture.py` 末尾追加：

```python
# ── Task 4：漂移闸（spec §4.1 note 4；变异 B53 / B64）

def _logical_content(zip_path) -> dict:
    """训练组 zip 的**逻辑内容**（⛔ 不含任何随机器/时间变化的东西）。"""
    with _open_zip_db(zip_path) as (members, conn):
        return {
            "members": list(members),
            "user_version": conn.execute("PRAGMA user_version").fetchone()[0],
            # DDL 也要比：spec §4.1 note 4 明写「生成器日后改了序列化 / DDL / 版本」都要被抓住
            "schema": conn.execute(
                "SELECT type, name, sql FROM sqlite_master "
                r"WHERE name NOT LIKE 'sqlite\_%' ESCAPE '\' ORDER BY type, name").fetchall(),
            # ⭐ 与 klines 一样用 `SELECT *`：显式列清单会让**日后新增的列**从此永远不进比较面
            # —— 加列那一次由 schema 抓到，之后那一列的取值漂移就再没人看着了（评审 Task4-I1）。
            "meta": conn.execute("SELECT * FROM meta").fetchall(),
            "klines": conn.execute("SELECT * FROM klines ORDER BY id").fetchall(),
        }


def test_committed_fixture_matches_current_generator(tmp_path):
    """每次 CI 都把【当前生成器的输出】与【已提交 fixture】对齐（spec §4.1 note 4）。

    ⛔ 比【逻辑内容】不比 zip 原始字节：SQLite 文件头 offset 96 存的是**写这个库的那个
       sqlite 库的版本号**（本机实测 3053003 = 3.53.3）⇒ 换机器 / 升 sqlite 后字节与 CRC32
       都会变，比字节必然假红。同理 ⛔ 不得断言 content_hash 字面量。
    """
    fresh = build_fixture(tmp_path)
    got = _logical_content(fresh.path)
    committed = _logical_content(FIXTURE_ZIP)
    if got != committed:
        drifted = [k for k in got if got[k] != committed[k]]
        pytest.fail(
            f"当前生成器的输出与已提交 fixture 不一致（差异字段：{drifted}）。\n"
            f"这说明**生成器的行为变了**。\n"
            f"⛔ 别急着跑再生脚本把它压绿 —— 先判断这是不是有意的改动：\n"
            f"  · 有意 ⇒ 跑 `python3 backend/scripts/regen_trainingset_contract_fixture.py` "
            f"重生 fixture，并按 tests/contract-fixtures/training-set/README.md "
            f"把切片二的 App 侧读取链路一并重跑；\n"
            f"  · 无意 ⇒ 这就是回归，该改的是生成器，不是 fixture。")


def test_drift_gate_compares_row_content_not_just_the_member_list():
    """自测：漂移闸的比较面必须**真的逐行逐列**地包含每张表（否则它只是个文件名检查）。

    ⚠️ 这条防的是「闸门写窄了」——只比成员清单的话，改公式（`end_global_index` 全变）
    也不会红，而那正是本切片存在的理由。

    ⛔ **只断言键名在不在是不够的**（评审 Task4-I2 实证）：把
       `"klines": SELECT * … .fetchall()` 换成 `"klines": SELECT count(*) … .fetchone()[0]`，
       **键名一个没少**、闸门却退化成一个行数检查 —— 而逐根改错的 `end_global_index`
       恰恰只有逐行比才抓得住。⇒ 本条必须断言每个键的**取值形状**，不只是它的名字。
    """
    c = _logical_content(FIXTURE_ZIP)
    assert set(c) == {"members", "user_version", "schema", "meta", "klines"}, (
        f"漂移闸的比较面被改窄/改宽了：{sorted(c)}")

    # members / user_version：本条规则对**每个**键都适用，不能只贯彻三个（最终评审 Important 3）
    assert isinstance(c["members"], list) and all(isinstance(m, str) for m in c["members"]), (
        f"members 必须是成员名清单，⛔ 不得退化成计数 —— 退化后 `.db`→`.sqlite` 这类改名"
        f"就没人看着了（实测 {c['members']!r}）")
    assert isinstance(c["user_version"], int), (
        f"user_version 必须是取回的那个整数值本身（实测 {type(c['user_version']).__name__}）")

    # klines：必须是【逐行 × 逐列】的完整表，⛔ 不得退化成计数或摘要
    assert isinstance(c["klines"], list) and len(c["klines"]) == 47, (
        f"klines 必须逐行比（期望 47 行的 list，实测 {type(c['klines']).__name__}）")
    assert all(isinstance(r, tuple) and len(r) == 18 for r in c["klines"]), (
        "klines 每行必须是完整的 18 列元组 —— 少一列，那一列的漂移就永远抓不到")

    # meta：同样必须是完整行
    assert isinstance(c["meta"], list) and len(c["meta"]) == 1 and len(c["meta"][0]) == 4, (
        f"meta 必须逐行逐列比（期望 1 行 × 4 列，实测 {c['meta']!r}）")

    # schema：必须比 DDL **原文**，否则列的增删改无人看着
    schema_sql = "\n".join(sql for *_, sql in c["schema"] if sql)
    assert "end_global_index" in schema_sql, (
        "schema 必须包含 DDL 原文（`sqlite_master.sql`）——只比表名的话，改列型/加列都不会红")
    assert not any(name.startswith("sqlite_") for _, name, _ in c["schema"]), (
        "sqlite_ 开头的内部表不得进比较面 —— 它们是 **SQLite 自己的实现细节**，不属于我们的契约面；"
        "纳入比较等于把这道闸绑到 SQLite 的内部实现上（⚠️ 理由**不是**「sqlite_sequence 的值会变」："
        "本 fixture 里它恒为 klines/47）")
```

- [ ] **Step 2: 跑，确认绿**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_trainingset_contract_fixture.py -v
```

Expected: **9 passed**

- [ ] **Step 3: 跑全套 + 冷缓存**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
find tests -name __pycache__ -type d -exec rm -rf {} + ; \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q 2>&1 | tail -5
```

Expected: `1130 passed`（`origin/main` 实测基线 **1121** + 本片 9），**0 failed / 0 skipped**。
⚠️ 若数字对不上，**先核实是不是别的 PR 已经改了基线**，不要直接改这里的数字了事。

- [ ] **Step 4: Commit**

```bash
git add backend/tests/test_trainingset_contract_fixture.py
git commit -m "test(trainingset): 漂移闸——现场重建与已提交 fixture 的逻辑内容比对（P2 Task 4）"
```

---

## Task 5: 变异验证 + 非程序员验收清单

**Files:**
- Create: `docs/acceptance/2026-09-05-trainingset-p2-mutation-log.md`
- Create: `docs/acceptance/2026-09-05-trainingset-p2-acceptance.md`

**为什么必须做**：`CLAUDE.md` 治理底线第 2 条（**非可豁免**）要求每个模块/阶段交付都带一份非程序员可执行的验收清单（动作 / 期望 / 通过判定；中文；禁用词见 `.claude/workflow-rules.json`）。变异记录则是本仓反复踩过的那条：「读代码发现不了恒真断言，变异验证是唯一能证伪『测试没在测它』的手段」。

**⛔ 变异纪律（每一条都栽过）**：

1. **一组变异一条命令**，⛔ 不把多组串在一条里 —— Bash 有 2 分钟超时，被掐死在「已施加变异、尚未复原」之间会留下一棵**带注入缺陷**的树；
2. 施加前先 `cp <file> /tmp/<name>.bak`，复原用 `cp` 回来，⛔ **不用 `git checkout <file>`**（会连未提交改动一起抹掉）；
3. 每组跑完**单独再看一次 `git status --short`**，不能因为「脚本里写了复原」就假定复原跑到了；
4. 每次跑前**清 `__pycache__`**：失效判据是 `(mtime 秒, size)`，等长变异 + 同秒复原会让陈旧字节码继续生效，两个方向的结论都可能是假的；
5. 判绿读**执行量与失败用例名**，⛔ 不读「成功」字样；
6. 记录必须写清**红的是哪一条测试**，而不是「有测试红了」。

- [ ] **Step 1: 逐组跑变异，边跑边记**

下表每一行独立跑一次。`GTS = backend/generate_training_sets.py`，`TCF = backend/tests/test_trainingset_contract_fixture.py`，`FIX = backend/tests/_trainingset_contract_fixture.py`。

| # | 变异（改哪一处） | 期望红的**具体用例** |
|---|---|---|
| **P1** | `GTS` 的 `assign_global_indices` 里 `upper = period_end(_open, period)` 改回旧式「下一根 open − 1」（末根退化为轴末） | `test_fixture_matches_hand_written_expectations[fresh]` 报 **`15m`** 不符；`[committed]` **不红**（它读的是已提交文件）；`test_committed_fixture_matches_current_generator` **红**（`klines` 字段漂移） |
| **P2** | `GTS` 的 `period_end` 把 `_CLOSE_LABELLED` 判断反过来（日内走开盘侧、日线及以上走收盘式）。⚠️ **按字面完全反过来是跑不通的**：`3m`/`15m`/`60m` 会落进 `period_end` 的 `else` 撞 `raise ValueError`，得到的是报错而不是干净的断言红。实测取的是可跑的那一半 —— 把 `_CLOSE_LABELLED` 扩成六个周期（即「日线及以上也走收盘式」） | 同上用例报 **`daily`** 或 **`monthly`** 不符 ⇒ 兑现 spec §4.1 正向对照 ①（健康输入被放行不是假的） |
| **P3** | `GTS` 的 `period_end` 里 `weekly` 分支改成 `last = d`（当天） | 同上用例报 **`weekly`** 不符（`[0, 5]` → `[0, 0]`） |
| **P4** | `GTS` 的 `assemble_from_windows` 里 `f"{fname}.db"` 改成 `f"{fname}.sqlite"`（spec 变异 **B64**） | ⭐ **必须分两条记**：`test_committed_fixture_matches_current_generator` **红**（`members` 漂移）；而 `test_fixture_matches_hand_written_expectations[fresh]` 里那条「后缀 ∈ {`.sqlite`,`.db`}」**不红** —— spec B64 明写这两条对该行的敏感度不同，混记就等于虚报判别力 |
| **P5** | `GTS` 的 `SCHEMA_VERSION` 改 `3` **且** `_TRAINING_SET_DDL` 里 `PRAGMA user_version = 2` 改 `3`，**不重生 fixture**（spec 变异 **B53**） | `test_fixture_matches_hand_written_expectations[fresh]` 红（`user_version != 2`）**且** `test_committed_fixture_matches_current_generator` 红（**只有 `user_version` 漂移**：⚠️ `PRAGMA user_version` **不存在于 `sqlite_master`**，所以 `schema` 不会跟着变 —— 本行原先预测「`user_version` + `schema`」是错的，实测见变异记录 P5）。⚪ 既有套件**不会**红：实测全仓没有任何测试断言 `SCHEMA_VERSION == 2` 字面量（`test_generate_training_sets.py:173` 断的是 `PRAGMA user_version == SCHEMA_VERSION`，两边一起改就仍相等）⇒ 观测量干净 |
| **P6** | `FIX` 的 `build_windows` 改成不走 `select_period_window`（weekly 直接把 `RAW_DATETIMES["weekly"]` 三根全塞进去） | `test_build_windows_goes_through_production_select_period_window` 红、`test_windows_carry_the_three_required_features` 红（03-30 那根没被删）**且** `…[fresh]` 报 `weekly` 不符 |
| **P6b** | 同上但**手工丢掉最后一根**（`RAW_DATETIMES["weekly"][:-1]`）⇒ 输出与今天**逐根相同** | ⭐ **只有** `test_build_windows_goes_through_production_select_period_window` 红，其余三条**全绿** —— 这正是加那条 spy 守卫的理由。控制者 2026-09-04 亲手跑过：`1 failed, 3 passed` |
| **P7** | `TCF` 的 `_logical_content` 只留 `{"members": …}` 一项（把闸门写窄） | `test_drift_gate_compares_row_content_not_just_the_member_list` 红；并**在此变异体上再叠加 P1**，确认 `test_committed_fixture_matches_current_generator` 这时**不红** ⇒ 证明「比每张表全部行」这一项确有判别力 |
| **P8**（⛔ 反面示范，记录为「这种写法必须被禁止」） | `TCF` 把 `EXPECTED_END_GLOBAL_INDEX` 改成运行时调 `assign_global_indices` 现算（共享 oracle），**再叠加 P1** | 两条断言**仍全绿** ⇒ 实证 spec 变异 **B18**：期望值一旦与被测代码共用公式，公式错了两边一起错。跑完必须**完整复原**成手写字面量 |

单组变异的标准跑法（以 P3 为例）：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
cp generate_training_sets.py /tmp/gts.bak && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" - <<'PY'
import pathlib
p = pathlib.Path("generate_training_sets.py")
t = p.read_text(encoding="utf-8")
old = '        last = _week_end_date(datetime_epoch)'
assert t.count(old) == 1, "锚点不唯一，变异未施加（⛔ 别继续）"
p.write_text(t.replace(old, '        last = d'), encoding="utf-8")
print("变异已施加")
PY
find tests -name __pycache__ -type d -exec rm -rf {} + ; \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_trainingset_contract_fixture.py -q 2>&1 | tail -15
```

复原（**单独一条命令**）：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
cp /tmp/gts.bak generate_training_sets.py && \
find tests -name __pycache__ -type d -exec rm -rf {} + && \
git status --short && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q 2>&1 | tail -3
```

Expected：`git status --short` 无输出 + 全套回到 `1130 passed / 0 failed / 0 skipped`。

- [ ] **Step 2: 写变异记录**

创建 `docs/acceptance/2026-09-05-trainingset-p2-mutation-log.md`，逐组记录：变异内容、施加命令、**跑出来的原始输出片段**、红的**具体用例名**、复原后的 `git status` 与全套计数。⛔ 不得只写「已验证」。

- [ ] **Step 3: 写非程序员验收清单**

创建 `docs/acceptance/2026-09-05-trainingset-p2-acceptance.md`，结构与 P1 那份（`docs/acceptance/2026-09-03-trainingset-p1-acceptance.md`）一致：每条一个**动作**（可复制的整行命令）、一个**期望**（看什么内容，⛔ 不是看「成功」字样）、一个**通过/不通过判定**。至少覆盖：

1. 后端全套跑通且零 skip；
2. 新用例 **9 条**全过（8 个函数、其中一个带两组参数 ⇒ 收集到 9 项）；
3. 仓库里那份 fixture 存在，且用 `unzip -l` 看到**恰好 1 个成员**、名字以 `.db` 结尾；
4. 再生脚本跑两遍，第二遍打印「内容与原先逐字节相同」，且 `git status` 对该 zip 无输出；
5. `ios/` 一行未改（`git diff --name-only origin/main...HEAD -- ios/ | wc -l` 得 `0`）；
6. `backend/generate_training_sets.py` 一行未改（同款命令得 `0`）；
7. 一节「**本片交付后仍不成立的事**」，把本计划 §「已知残留」的每一条都写进去（⛔ **不要按编号交叉引用** —— 两份文档的编号顺序不同，最终评审已实测到错位。验收清单里的编号是**它自己**的，以那份为准；本节只保证内容不漏）。

⛔ 禁用词见 `.claude/workflow-rules.json`，写完必须扫一遍确认 0 命中。

- [ ] **Step 4: Commit**

```bash
git add docs/acceptance/2026-09-05-trainingset-p2-mutation-log.md \
        docs/acceptance/2026-09-05-trainingset-p2-acceptance.md
git commit -m "docs(acceptance): P2 变异验证记录 + 非程序员验收清单"
```

---

## 已知残留（本片不解决，必须带进后续片）

- **R1 — `content_hash` 依赖写库机器的 sqlite 版本**（本片实测 F3）。⇒ P4 那条「产物有疑就重跑 R2、必得同一批包」的恢复前提，**只在同一台机器同一 sqlite 版本下成立**。P4 的 runbook 里写死的期望指纹同理：换机器重建就对不上。**归 P4**，本片只把事实钉在 `training-set/README.md` 与本计划里。
- **R2 — 生成器的 DDL 字面量与冻结 DDL 文件之间没有任何守卫**（本片实测 F5）。`schema-smoke.yml` 那道硬门测的是**文件**，而生产写库用的是 `generate_training_sets.py:369` 的**字面量**；两者漂移时闸门绿着放行。⇒ **建议归 P3**（P3 本来就在处理契约文本的一致性）。⛔ 本片刻意不修：它自 Plan B2 起就在，不由本片引入，混进来会把评审面搅浑。
- **R3 — `backend pytest (full suite)` 不是必需检查**（[[project_trainingset_p1_implemented]] 残留 F5 至今未修）。⇒ 本片新加的这道漂移闸**今天全红也不阻止合并**。修法是把它加进 ruleset `15660830` 的必需检查清单，**属独立 PR**，且需要 user 在 GitHub 上动配置。
- **R4 — 缝只闭合了一半**。本片只交付生产者半边；App 侧的「解压 → 打开 → 读取」链路一行未改，仍消费不了任何真实训练组（`DefaultZipExtractor.swift:26` 只认 `.sqlite` 成员，而产物内是 `.db`）。⇒ **归切片二**，必须用**这一份** fixture（⛔ 不是另造一份）。
- **R5 — 库里那 3 个训练组仍是第 1 代**（P1 残留，未变）。这段窗口 `api` / `scheduler` / 生成器 CLI **必须保持停止**。
- **R6 — 这份 fixture 照不到切窗器的另外两条路**（最终评审 Minor 7）：weekly 的**尾部**跨界过滤在本 fixture 上作用于空数据；`PERIOD_BEFORE_CAP` 的六个上限也全都远高于实际 before 根数（18/3/4/3/6/2）。⇒ **删掉这两处，本 fixture 一动不动**。这是有意的取舍（fixture 要小到期望值能手写），但**切片二与 P3 不得误以为它覆盖了整个切窗逻辑**。
- **R7 — `.github/workflows/backend-tests.yml` 的注释现在是错的**（最终评审 Minor 8）：它逐条列举了「谁会读 `tests/contract-fixtures/`」，写的是两处，本片加了第三处。本片被明令禁止碰 workflows ⇒ **只能记下来，由下一个动 CI 的 PR 顺手改**。
- **R8 — 再生脚本在极端时机会留 `.tmp` 残渣**（最终评审 Minor 10）：原子替换本身正确，但若进程恰好死在 `copyfile` 与 `os.replace` 之间，fixture 目录里会留下一个 `*.zip.tmp`。它会出现在 `git status` 里（不会被误提交），但无人自动清理。
- ⚠️ **两份文档的残留编号刻意不互相引用**：本节是 R1–R8，验收清单里那份是**它自己**的 R1–R9，顺序不同。⛔ **不要按编号交叉引用**（最终评审 Minor 6 实测到过错位）。

---

## Self-Review

**1. Spec 覆盖（§4.1 逐条对表）**

| spec §4.1 条目 | 落在哪 |
|---|---|
| note 1「用生产顶层装配函数 `assemble_from_windows`，⛔ 不得自己串调」 | Task 1 `build_fixture` + Global Constraints 第 4 条 |
| note 2 特征 ①②③ | Task 1 `test_windows_carry_the_three_required_features` + Task 2 期望值表 |
| note 3「压缩包清单 + 逐周期索引向量 vs 独立人工推算」 | Task 2 `test_fixture_matches_hand_written_expectations` |
| note 3 ⭐「压缩交易日即可」 | Task 1 `_DAYS` / `_INTRADAY`（4 日 × 6 根 = 24，期望值 47 个量级） |
| note 3 ⚪「行序不需要显式 ORDER BY」 | 本片仍显式写了 `ORDER BY id` —— 比 spec 更严，无害 |
| note 3 ⚠️「期望值必须手写」 | Global Constraints 第 3 条 + Task 2 的 ⛔ 注释 + Task 5 变异 P8 反面实证 |
| note 4「CI 每次比对，比逻辑内容不比字节」 | Task 4 `test_committed_fixture_matches_current_generator`（靠 `backend-tests.yml` 无 paths 过滤器，每 PR 都跑） |
| 正向对照 ①`daily`/`monthly`/`3m` 逐根不变 | Task 2 期望值表最后一列 + 变异 P2 |
| 正向对照 ④「上述 fixture 通过全部断言」 | Task 3 Step 5 把 `committed` 也纳入同一套断言 |
| 正向对照 ②③（重建出的 3 个包、R2 连跑两次） | ⛔ **不属本片** —— 那是 P4 的运维重建 |
| 「⚠️ B1 与 B3 必须互不掩盖，另配组合变异」 | ⛔ **P1 已交付**（`docs/acceptance/2026-09-03-trainingset-p1-mutation-log.md` 的组合变异一组），本片不重复 |
| 移交切片二 | §「已知残留」R4 + `training-set/README.md`（⛔ 只写事实，不替切片二开药方） |

**2. 占位符扫描**：无 TBD / TODO / 「类似 Task N」/ 无代码的代码步骤。每个 Task 的代码块都可直接落盘。

**3. 类型一致性**：`build_fixture` 返回 `GeneratedTrainingSet`（有 `.path` / `.content_hash`），Task 2/3/4 用的都是 `.path`；`FIXTURE_ZIP` 是 `pathlib.Path`，`_open_zip_db` 内部再 `Path(...)` 一次以容忍传入 str；`_logical_content` 的键集合在 Task 4 的自测用例里被钉死。

**4. 已知的计划自身弱点（交给实施者留意）**

- Task 1 / 2 的用例**写完就是绿的**（被测逻辑 P1 已落地）⇒ 它们的价值完全押在 Task 5 的变异上。若 Task 5 有任何一组跑不出预期的红，**不要改期望值让它红**，而要回来问「这条断言是不是根本没在测它」。
- `1130 passed` 这个数字是**推算**（实测基线 1121 + 9），⛔ 属计划内嵌的「事实」类，必须实测；对不上时先查是不是别的 PR 动了基线。
