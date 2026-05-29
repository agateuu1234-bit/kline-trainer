# PR B1 — import_csv 数据导入模块 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec §四 B1 + plan §6.4.1 字面要求的后端数据导入模块 `backend/import_csv.py`：CSV → pandas 清洗 → 计算 MA66/BOLL/MACD → 建立 1m 基准 `ticket_index` → 写 PostgreSQL（`stocks` + `klines`），CLI `python import_csv.py --input <csv_dir> --stock <code> [--period ...]` —— Wave 1 顺位 16 / 交付序第 18 个 PR per outline v20。同时折入 **H6-part1 deps 精确 pin**（`requirements-dev.txt` exact + docker-compose postgres image digest）。

**Architecture:** **双层**，与既有后端测试约定（`backend/tests/test_schema.py` 用 pglast 静态解析、不需 live PostgreSQL；"Production deployment validation 是 B3/NAS scope"）一致：
- **纯变换层**（`import_csv.py` 的纯函数：`parse_csv` / `clean` / `compute_indicators` / `compute_ticket_index`）—— 输入/输出都是 in-memory pandas DataFrame，**host pytest 全测、不碰 DB**。B1 的全部正确性（行数 / 时间连续性 / 指标值 / ticket_index 严格递增）都在这一层断言。
- **薄写库壳**（`write_to_postgres` + `main` CLI）—— asyncpg UPSERT 入库；**不在 CI 单测**（需 live PG = B3/NAS scope，按 test_schema.py 既定边界）；结构上留缝便于将来集成测试。

**Tech Stack:** Python 3.11+ / pandas 2.2.3 / asyncpg 0.30.0（已在 `backend/requirements.txt` == 锁定）/ pytest（dev dep）/ PostgreSQL 15（schema `backend/sql/schema.sql` 已冻，本 PR **不改 schema**）。

**Spec source:** `kline_trainer_modules_v1.4.md` §四 B1 (L718-723) + `kline_trainer_plan_v1.5.md` §6.4.1 (L1154) + klines DDL 注释 (L325-363) + outline v20 顺位 16 (L41) + §15.4 ledger H6 (deps pin) / H7 (sample 数据)。

**Constraint reminders（per outline v20 §3.2 + memory `feedback_planner_packaging_bias`）：**
- ≤ 3 sub-items（本 plan：3 Tasks）
- ≤ 500 行 prod（本 plan：~250 行 prod 估算）
- review budget：opus 4.7 xhigh 双闸门各 4-5 轮内收敛（user 本次显式指定走 opus 不走 codex）
- **本 PR 不碰 `.github/workflows`**（user 已决策"纯 opus xhigh，CI 延后"——见 Task 0 §CI 决策）；故 B1 pytest 在本地 + acceptance 脚本里跑，不进 CI；CI 接线作独立 codex 治理 PR 后续补
- 后端命令从 `backend/` 跑：`cd backend && python3 -m pytest tests/test_import_csv.py -v`
- Working branch：执行阶段由 `using-git-worktrees` 创建（EnterWorktree，分支名按 attest 名开 PR——见 memory `feedback_worktree_cwd_drift`）
- **memory `feedback_worktree_cwd_drift` 硬提醒**：每次 push / gh pr create 前先 `pwd && git branch --show-current && git rev-parse HEAD` 三连确认站在 worktree 正确分支

---

## 背景与既有接缝（实施者必读）

- **schema 已冻**（`backend/sql/schema.sql`，本 PR **只读不改**）：
  - `stocks(code VARCHAR(10) PK, name VARCHAR(50) NOT NULL)`
  - `klines(id BIGSERIAL PK, stock_code → stocks(code), period VARCHAR(10), datetime BIGINT, open/high/low/close DECIMAL(10,2), volume BIGINT, amount DECIMAL(16,2), ticket_index INTEGER, ma66 DECIMAL(10,4), boll_upper/mid/lower DECIMAL(10,4), macd_diff/dea/bar DECIMAL(10,6), UNIQUE(stock_code, period, datetime))`
  - DDL 注释权威（plan L328-336/L363）：`period` ∈ `{'1m','3m','15m','60m','daily','weekly','monthly'}`；`datetime` = Unix 时间戳**秒** Int64；`ticket_index` = **1m 周期唯一、全局递增 0,1,2...**，"3m 对应能被 3 整除的点，60m 对应能被 60 整除的点"。
- **前端 C3/C4 读预计算列**（`ios/.../Render/KLineView+Candles.swift` L29-30 字面："C3 MA66：**读预计算 candle.ma66** 折线"）→ **B1 是指标值的唯一真相源**，前端不重算、不存在需要"对齐"的前端公式。B1 按标准公式定义 canonical 指标即可。
- **后端测试不需 live PG**（`backend/tests/test_schema.py` 头注释："Uses pglast ... so no Docker or daemon is required. Production deployment validation (on NAS PostgreSQL) is Wave 1 B3 owner scope"）→ B1 纯函数层 pytest 同样不碰 DB；写库壳的真实 DB 测试推迟到 B3/NAS。
- **既有 deps**：`backend/requirements.txt` 已 `==` 精确锁（fastapi/uvicorn/apscheduler/pandas==2.2.3/pandas-ta==0.3.14b1/asyncpg==0.30.0）；`backend/requirements-dev.txt` 用 `>=`/`<` ranges（pytest/httpx/pglast/openapi-spec-validator/pyyaml）；`docker-compose.yml` 用 tag `postgres:15.12`（非 digest）。H6-part1 余量 = pin dev deps exact + docker image digest（均非 workflow 文件，opus xhigh 可审）。
- **CI 现状**：后端走**逐文件 path-gated workflow**（`schema-smoke.yml` 管 `backend/sql/**`+`test_schema.py`；`openapi-smoke.yml` 管 `openapi.yaml`+`test_openapi.py`）。新 `test_import_csv.py` **不被任何现有 workflow 触发**；加 workflow = trust-boundary = 强制 codex。user 已决策本 PR 不加 workflow（纯 opus xhigh）→ B1 pytest 仅本地 + acceptance 脚本跑，**merge 不依赖 backend pytest CI**（现有 required checks 对 backend-only 改动短路通过）。
- **pandas-ta 0.3.14b1 是 beta**，对新版 numpy/pandas 有已知兼容问题且非确定性封装；见 D2：本 PR 用 pandas 内建（rolling/ewm）按数学公式直算指标，可单测到精确值，spec "pandas + pandas-ta" 作生态提示不作库调用契约。

---

## Task 0 — §15.3 评审策略前置 + CI 决策 + spec 偏差裁决

per `docs/governance/wave1-plan-template.md`：本 plan 使用哪些评审形式。

- [ ] **局部对抗性评审（必）**：本 plan B1 scope 内 **Claude Opus 4.7 xhigh effort 双闸门**（plan-stage + branch-diff），**不走 codex**（per user 本次显式 prompt + memory `feedback_openai_quota_ci_pattern`）。4-5 轮内收敛或 escalate。
- [x] **集成层评审（N/A）**：B1 写库壳的跨模块集成（B2 消费 klines / B3 服务）在后续顺位；本 PR 是数据导入叶子工具，无下游被桥接 surface 在本 PR 落地。
- [x] **性能评审（N/A）**：plan §一性能门槛属前端渲染 Phase 5；B1 是离线批导入，无 60Hz 路径。

### CI 决策（user 2026-05-29 explicit）

user 在本 plan 起草前明确选择 **"纯 opus xhigh，CI 延后"**：B1 只含业务模块 + 本地/acceptance pytest + H6 deps pin + acceptance doc/script，**不碰 `.github/workflows`**。理由：加 backend pytest workflow = trust-boundary 改动 = 治理 backstop 强制 codex 评审，与 user 指定的 opus xhigh 评审路径冲突。CI 接线（path-gated backend pytest workflow）作**独立 codex 治理 PR 后续补**——记为 **residual B1-R1**（写进 acceptance §K + 收尾 memory）。

### Step ↔ Skill 显式映射（per memory `feedback_workflow_skill_invoke_explicit`）

| 阶段 | Skill | 何时调 | 不用 raw Agent 替代 |
|---|---|---|---|
| Plan-stage adversarial review | （主线 dispatch fresh opus 4.7 xhigh subagent，按 `adversarial-review-template.md`）| plan 写完后、Task 1 前 | 主线必须 dispatch 新 agent |
| Task 1-3 实施 | `superpowers:subagent-driven-development` | 每 Task fresh sonnet 4.6 high + paired sonnet reviewer | 不用 raw Agent / 不主线自写 |
| Verification | `superpowers:verification-before-completion` | Task 3 acceptance 脚本跑完前 | 不主线自宣"绿了" |
| Self-review | `superpowers:requesting-code-review` | branch-diff review 前 | 不跳 |
| Branch-diff adversarial review | （主线 dispatch fresh opus 4.7 xhigh subagent）| 全部实施 + self-review 后 + push 前 | 主线必须 dispatch 新 agent |

完成 Task 0（仅"局部对抗性评审"项为可执行待办）才进 Task 1。

### Spec 偏差裁决（D1-D15，全部写进代码注释 + 验收 §J）

| # | 偏差/歧义 | 裁决 | 权威依据 |
|---|---|---|---|
| **D1** | 双层 vs 一体 | **纯变换层（host pytest 全测）+ 薄 asyncpg 写库壳（CI 不单测，B3/NAS scope）**。 | `test_schema.py` 头注释 "Production deployment validation 是 B3 owner scope" + iOS 双层 mode 先例 |
| **D2** | pandas-ta vs pandas 内建算指标 | **用 pandas 内建 rolling/ewm 按数学公式直算**，不调 pandas-ta。理由：pandas-ta 0.3.14b1 beta 对新 numpy/pandas 不稳定 + 非确定性，无法单测到精确值；指标的**数学定义**才是契约（前端只读 B1 输出，无对齐对象）。spec "pandas + pandas-ta" 作生态提示。 | spec §一 "pandas + pandas-ta" + 前端读预计算 L29-30 + 可测性 |
| **D3** | MA66 公式 + 窗口不足 | `ma66 = SMA(close, window=66)`；前 65 行窗口不足 → `NULL`（NaN→DB NULL）。`round(4)` 配 DECIMAL(10,4)。 | 列名 MA66 + DECIMAL(10,4) |
| **D4** | BOLL 公式（中轨周期 / σ 倍数 / 总体 vs 样本 std） | `mid=SMA(close,20)`；`upper=mid+2*std`；`lower=mid-2*std`；**std 用总体标准差 ddof=0**（通达信/A股惯例）；前 19 行 → `NULL`；`round(4)`。 | A股 BOLL 通用 20/2 + 通达信 ddof=0 惯例 + DECIMAL(10,4) |
| **D5** | MACD 公式（EMA 周期 / BAR ×2 / EMA adjust） | `DIF=EMA(close,12)-EMA(close,26)`；`DEA=EMA(DIF,9)`；`BAR=(DIF-DEA)*2`（**×2**，通达信/A股惯例）；EMA 用 `ewm(span=N, adjust=False)`（递归 EMA，通达信式）；从首行起有值不置 NULL；`round(6)` 配 DECIMAL(10,6)。 | A股 MACD 通用 12/26/9 + BAR×2 通达信惯例 + DECIMAL(10,6) |
| **D6** | ticket_index 跨周期映射 | 1m：按 datetime 升序赋 0,1,2,…（严格递增）。其它周期：`ticket_index = searchsorted(1m_datetimes_sorted, bar_datetime)`（该 bar 时刻对应的 1m 全局序号）。**纯函数入参显式传 1m 基准 datetime 数组**（不在纯层查 DB）。 | plan L336/L363 字面 "1m 基准，3m 对应能被 3 整除的点" |
| **D7** | CSV 列契约 | 必需列 `datetime,open,high,low,close,volume`；可选列 `amount`,`name`。`datetime` 解析为 Unix **秒** Int64（接受 `YYYY-MM-DD HH:MM:SS` 或已是整数秒）。缺必需列 → 抛 `CsvSchemaError` fail-fast。 | klines DDL 列 + L335 "需求 CSV 包含 amount" + R04/R05 |
| **D8** | stocks.name 来源（NOT NULL，CLI 无 --name） | 优先 CSV `name` 列首个非空值；无则用 `--name` 参数；再无则 `name = code`（保证 NOT NULL 可落库）。 | stocks.name NOT NULL + CLI 仅 --stock |
| **D9** | 清洗规则（R04 A股异常数据） | 丢弃：OHLCV 任一为 NaN / 价格 ≤ 0 / `high < low` / `high < max(open,close)` / `low > min(open,close)` 的行；按 datetime 去重（保留最后一条）；按 datetime 升序排序。清洗后行数 < 原始记 warning 不报错。 | R04 "A股异常数据 pandas 清洗" + 验收"时间连续性" |
| **D10** | CLI 行为（--period 可选） | `--input <dir> --stock <code> [--period P] [--name N] [--dsn DSN]`。**无论 --period 是否给定，main() 总是先从 dir 里找 1m CSV 建 ticket_index 基准**（R09 "数据源必须含 1m CSV"）；再按 --period 过滤"要写库的文件"（--period 非 1m 时基准来自同 dir 的 1m 文件，不依赖 DB 查询——R1-M2 修，不声称未实现的 DB 路径）。`--period` 省略 → 导 dir 内所有识别到的周期。若 --period 非 1m 且 dir 内无 1m 文件 → fail-fast 报错（缺基准）。DSN 缺省读环境 `DATABASE_URL`。 | spec CLI L722 + R09 |
| **D11** | 写库幂等性 | `stocks` UPSERT `ON CONFLICT(code) DO UPDATE SET name=EXCLUDED.name`；`klines` UPSERT `ON CONFLICT(stock_code,period,datetime) DO UPDATE`（重导覆盖指标）。 | UNIQUE 约束 + 可重入导入 |
| **D12** | H6-part1 deps pin scope | `requirements-dev.txt` 全部 `>=`/`<` → `==` 精确（查当前已解析版本）；`docker-compose.yml` `postgres:15.12` → `postgres:15.12@sha256:<digest>`。`requirements.txt` 已 == 不动。 | §15.4 H6 + L2490 |
| **D13** | 不碰 .github/workflows | 本 PR 0 workflow 改动（user CI 决策）；B1 pytest 本地 + acceptance 脚本跑；CI 接线 = residual B1-R1 独立 codex PR。 | user 2026-05-29 explicit + 治理 backstop trust-boundary |
| **D14** | 写库壳是否 CI 单测 | **否**（需 live PG = B3/NAS scope）。`write_to_postgres` 结构上留缝（接受已构造好的 records 列表），真实 DB 测试推迟。纯层覆盖全部业务正确性。 | test_schema.py 边界先例 |
| **D15** | H7 sample 数据归属 | B1 = **导入工具 + 测试用微型 CSV fixture**（仅 tests/fixtures，非生产数据）；3-5 个**生产**样本训练组数据由 B2（顺位 17）生成 + ledger 回填。 | outline L100 "H7 折入 B1(导入)+B2(生成)" 拆分 |

---

## File Structure

### Production（2 文件，~250 行）

| 路径 | 动作 | 行数 | 职责 |
|---|---|---|---|
| `backend/import_csv.py` | **新建** | ~210 | 纯函数（`parse_csv` / `clean` / `compute_indicators` / `compute_ticket_index` / `to_kline_records`）+ 薄写库壳（`async write_to_postgres`）+ `main()` CLI（argparse + asyncio.run）。仅纯函数被单测。 |
| `backend/requirements-dev.txt` | **改** | — | `>=`/`<` → `==` 精确 pin（H6-part1）。 |
| `backend/docker-compose.yml` | **改** | 1 行 | `postgres:15.12` → `postgres:15.12@sha256:<digest>`（H6-part1）。 |

### Tests（1 文件，~240 行）

| 路径 | 动作 | 行数 | 测试 |
|---|---|---|---|
| `backend/tests/test_import_csv.py` | **新建** | ~250 | ~16 pytest：parse/schema-error 2 + clean(R04 异常) 4 + 指标(MA66/BOLL/MACD 精确值 + NULL 窗口) 4 + ticket_index(1m 递增 + 跨周期映射) 3 + to_records/NaN/类型 3（含 R1-H2 int 类型断言）。纯函数，无 DB。 |
| `backend/tests/fixtures/sample_1m.csv` | **新建** | — | 微型 1m CSV fixture（~70 行数据，够触发 MA66 窗口）供测试。 |

### Docs / Scripts（2 文件）

| 路径 | 动作 | 内容 |
|---|---|---|
| `docs/acceptance/2026-05-29-pr-b1-import-csv.md` | **新建** | 中文非程序员验收清单 §A-§K（文件存在 / pytest 全绿 / 指标公式 grep 锚 / ticket_index 语义 / deps pin / 不碰 workflow 反向验证 / residual B1-R1）。 |
| `scripts/acceptance/plan_b1_import_csv.sh` | **新建** | 机检 bash（`set -euo pipefail` + **负向断言一律 `if grep; then exit 1; fi`** per memory `feedback_acceptance_grep_anchoring`；human-grep 用行首/前缀锚）。 |

**Total：3 prod（1 新 + 2 改 deps）+ 1 test + 1 fixture + 1 doc + 1 script = 7 文件 / ~250 prod / ~250 test / ~16 新测试。**

---

## Task 1 — 纯变换层 `import_csv.py` 纯函数 + ~16 host pytest

**Files:**
- Create: `backend/import_csv.py`（先只写纯函数 + 模块级常量；写库壳 + CLI 在 Task 2）
- Create: `backend/tests/test_import_csv.py`
- Create: `backend/tests/fixtures/sample_1m.csv`

- [ ] **Step 1: 写 fixture `sample_1m.csv`**（~70 行 1m 数据，单调上升收盘价便于断言；含 amount + name 列）

```csv
datetime,open,high,low,close,volume,amount,name
2024-01-02 09:30:00,10.00,10.20,9.98,10.10,1000,10100.00,测试股
2024-01-02 09:31:00,10.10,10.30,10.05,10.20,1100,11220.00,测试股
2024-01-02 09:32:00,10.20,10.40,10.15,10.30,1200,12360.00,测试股
```
> 实施者：把上面 3 行扩到 **70 行**（datetime 每行 +60 秒，close 每行 +0.10 递增到约 16.9，open=上一 close，high=close+0.10，low=open-0.02，volume 任意正整数，amount=close*volume 取 2 位），保证 ≥66 行以触发 MA66 第 66 行起有值。所有价格 > 0、high≥max(open,close)、low≤min(open,close)。

- [ ] **Step 2: 写失败测试 `test_import_csv.py`**

```python
# backend/tests/test_import_csv.py
# Spec: kline_trainer_modules_v1.4.md §四 B1 + plan 2026-05-29-pr-b1-import-csv.md Task 1
# 纯函数层：全部 in-memory DataFrame，不连 PostgreSQL（写库壳由 B3/NAS 集成测试覆盖，D14）。
from __future__ import annotations

import math
from pathlib import Path

import pandas as pd
import pytest

from import_csv import (
    CsvSchemaError,
    clean,
    compute_indicators,
    compute_ticket_index,
    parse_csv,
    to_kline_records,
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

# ---- D6 ticket_index ----

def test_ticket_index_1m_strictly_increasing_from_zero():
    df = clean(_synthetic(10))
    idx = compute_ticket_index(df, period="1m", baseline_1m_datetimes=None)
    assert list(idx) == list(range(10))
    assert all(b > a for a, b in zip(idx, idx[1:]))  # 严格递增

def test_ticket_index_3m_maps_to_1m_baseline():
    one_min = clean(_synthetic(12))                       # datetimes base+0..base+660
    baseline = list(one_min["datetime"])
    # 构造 3m bar：取 1m 的第 0/3/6/9 个 datetime
    three = one_min.iloc[[0, 3, 6, 9]].reset_index(drop=True)
    idx = compute_ticket_index(three, period="3m", baseline_1m_datetimes=baseline)
    assert list(idx) == [0, 3, 6, 9]                     # "能被 3 整除的点"

def test_ticket_index_60m_divisible_by_60_point():
    one_min = clean(_synthetic(121))
    baseline = list(one_min["datetime"])
    hour = one_min.iloc[[0, 60, 120]].reset_index(drop=True)
    idx = compute_ticket_index(hour, period="60m", baseline_1m_datetimes=baseline)
    assert list(idx) == [0, 60, 120]

# ---- to_records + 精度 ----

def test_to_kline_records_shape_and_period_stock():
    df = compute_indicators(clean(_synthetic(70)))
    df["ticket_index"] = compute_ticket_index(df, period="1m", baseline_1m_datetimes=None)
    records = to_kline_records(df, stock_code="600519", period="1m")
    assert len(records) == 70
    r = records[-1]
    assert r["stock_code"] == "600519" and r["period"] == "1m"
    assert set(r) >= {"datetime", "open", "high", "low", "close", "volume",
                      "amount", "ticket_index", "ma66",
                      "boll_upper", "boll_mid", "boll_lower",
                      "macd_diff", "macd_dea", "macd_bar"}

def test_to_kline_records_nan_becomes_none():
    df = compute_indicators(clean(_synthetic(10)))  # MA66 全 NaN（<66 行）
    df["ticket_index"] = compute_ticket_index(df, period="1m", baseline_1m_datetimes=None)
    records = to_kline_records(df, stock_code="X", period="1m")
    assert records[0]["ma66"] is None  # NaN → None（asyncpg 写 NULL）

def test_to_kline_records_integer_columns_are_python_int():
    # R1-H2：BIGINT/INTEGER 列必须是 Python int（非 numpy.float64/int64），否则 asyncpg codec 拒收
    df = compute_indicators(clean(_synthetic(70)))
    df["ticket_index"] = compute_ticket_index(df, period="1m", baseline_1m_datetimes=None)
    rec = to_kline_records(df, stock_code="X", period="1m")[-1]
    for col in ("datetime", "volume", "ticket_index"):
        assert type(rec[col]) is int, f"{col} 应是 Python int，实得 {type(rec[col])}"
    for col in ("close", "ma66"):  # ma66 在第 70 行有值（≥66）
        assert type(rec[col]) is float, f"{col} 应是 Python float，实得 {type(rec[col])}"
```

- [ ] **Step 3: 跑测试确认全 fail（import 失败 / 函数未定义 → exit ≠ 0）**

Run:
```bash
cd backend && python3 -m pytest tests/test_import_csv.py -q > /tmp/b1-red.txt 2>&1; echo "exit=$?"
grep -iE "ModuleNotFoundError|ImportError|cannot import|error" /tmp/b1-red.txt | head -3
```
Expected：`exit=` 非 0 + import/未定义错误命中（用 exit code 不依赖 wording）。

- [ ] **Step 4: 写纯函数实现 `import_csv.py`（只到纯函数层 + 常量；写库壳 Task 2）**

```python
# backend/import_csv.py
# Spec: kline_trainer_modules_v1.4.md §四 B1 (L718-723) + plan v1.5 §6.4.1 + klines DDL L325-363
#
# 双层（D1）：纯函数层（parse/clean/compute_indicators/compute_ticket_index/to_kline_records）
# host pytest 全测、不碰 DB；薄 asyncpg 写库壳 + CLI 在同文件下半（D14，CI 不单测，B3/NAS scope）。
#
# 决议：
# - D2 指标用 pandas 内建 rolling/ewm 直算（非 pandas-ta，beta 不稳定 + 要可测精确值；前端只读 B1 输出）
# - D3 MA66 = SMA(close,66)，前 65 行 NULL，round(4)
# - D4 BOLL = SMA(close,20) ± 2*std(ddof=0 总体)，前 19 行 NULL，round(4)
# - D5 MACD: DIF=EMA12-EMA26 / DEA=EMA(DIF,9) / BAR=(DIF-DEA)*2；ewm(adjust=False)；round(6)
# - D6 ticket_index：1m 升序 0,1,2…；其它周期 searchsorted 到 1m 基准
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


def compute_ticket_index(
    df: pd.DataFrame,
    period: str,
    baseline_1m_datetimes: Optional[Sequence[int]],
) -> list[int]:
    """D6：1m → 升序 0,1,2…；其它周期 → searchsorted 到 1m 基准 datetime 数组。"""
    if period == "1m":
        return list(range(len(df)))
    if baseline_1m_datetimes is None:
        raise ValueError(f"period={period} 需要 1m 基准 datetimes 才能映射 ticket_index")
    base = np.asarray(sorted(baseline_1m_datetimes), dtype="int64")
    return [int(np.searchsorted(base, int(dt))) for dt in df["datetime"]]


# R1-H2：BIGINT/INTEGER 列必须是 Python int，其余 DECIMAL 列是 Python float。
# df.iterrows() 会把整行升格成单一 float64 dtype → datetime/volume/ticket_index 变 numpy.float64
# → asyncpg int8/int4 codec 拒收。故按列显式 cast，不用 iterrows()。
_INT_COLS = ("datetime", "volume", "ticket_index")
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
    """把带指标 + ticket_index 的 df 转成入库 record dict 列表。
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
```

- [ ] **Step 5: 跑测试确认 16 全绿**

Run: `cd backend && python3 -m pytest tests/test_import_csv.py -q 2>&1 | tail -5`
Expected：`16 passed`（或 N passed，0 failed）+ exit 0：
```bash
cd backend && python3 -m pytest tests/test_import_csv.py -q > /tmp/b1-green.txt 2>&1; echo "exit=$?"
```
Expected：`exit=0`。某测试 fail → 改实现不改断言（除非断言本身算错——那是 plan bug，报 DONE_WITH_CONCERNS）。

- [ ] **Step 6: Commit**

```bash
cd "<repo-root>"
git add backend/import_csv.py backend/tests/test_import_csv.py backend/tests/fixtures/sample_1m.csv
git commit -m "feat(b1): import_csv 纯变换层 + 16 host pytest (Task 1)

CSV parse/clean(R04 异常) + MA66/BOLL/MACD(pandas 直算,可测精确值) +
ticket_index(1m 基准 searchsorted) + to_records(NaN→None)。纯函数不碰 DB。
写库壳 + CLI 在 Task 2。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 — 薄 asyncpg 写库壳 + CLI

**Files:**
- Modify: `backend/import_csv.py`（追加 `write_to_postgres` + `main` CLI；不动 Task 1 纯函数）

> 本 Task **不加单测**（D14：写库需 live PG = B3/NAS scope）；正确性靠纯层（Task 1）+ Task 3 acceptance grep 锚验签名存在。

- [ ] **Step 1: 追加写库壳 + CLI 到 `import_csv.py` 末尾**

```python
# ===== 薄写库壳 + CLI（D14：不单测，B3/NAS 集成 scope）=====
import argparse
import asyncio
import os

_KLINE_INSERT = """
INSERT INTO klines (stock_code, period, datetime, open, high, low, close,
                    volume, amount, ticket_index, ma66,
                    boll_upper, boll_mid, boll_lower,
                    macd_diff, macd_dea, macd_bar)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)
ON CONFLICT (stock_code, period, datetime) DO UPDATE SET
    open=EXCLUDED.open, high=EXCLUDED.high, low=EXCLUDED.low, close=EXCLUDED.close,
    volume=EXCLUDED.volume, amount=EXCLUDED.amount, ticket_index=EXCLUDED.ticket_index,
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
                 r["low"], r["close"], r["volume"], r["amount"], r["ticket_index"],
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
    ap.add_argument("--period", default=None, help="只导该周期；省略=导全部，1m 先建基准")
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

    # R1-M2：总是先从 dir 里建 1m 基准（不依赖 DB），与 --period 过滤解耦。
    baseline: Optional[list[int]] = None
    one_min_files = [f for f in all_files if _discover_period(f) == "1m"]
    if one_min_files:
        base_df = compute_indicators(clean(parse_csv(one_min_files[0])))
        baseline = list(base_df["datetime"])

    # 要写库的文件：--period 过滤；1m 先写（保证基准来源行也入库）。
    write_files = all_files
    if args.period:
        write_files = [f for f in all_files if _discover_period(f) == args.period]
        if args.period != "1m" and baseline is None:
            ap.error(f"--period {args.period} 需要同目录存在 1m CSV 以建 ticket_index 基准")
    write_files = sorted(write_files,
                         key=lambda f: 0 if _discover_period(f) == "1m" else 1)

    total = 0
    for f in write_files:
        period = args.period or _discover_period(f)
        df2 = compute_indicators(clean(parse_csv(f)))
        df2["ticket_index"] = compute_ticket_index(df2, period, baseline)
        name = _resolve_stock_name(df2, args.name, args.stock)
        records = to_kline_records(df2, stock_code=args.stock, period=period)
        n = asyncio.run(write_to_postgres(args.dsn, args.stock, name, records))
        total += n
        print(f"[B1] {f.name} period={period} rows={n}")
    print(f"[B1] 完成：共写入 {total} 行 klines")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: 跑纯层测试确认零回归（写库壳追加不破坏纯函数 import）**

Run:
```bash
cd backend && python3 -m pytest tests/test_import_csv.py -q > /tmp/b1-task2.txt 2>&1; echo "exit=$?"
```
Expected：`exit=0`，仍 16 passed（写库壳的 `import asyncpg` 在函数内，纯层测试不触发；若 asyncpg 未装也不影响纯层）。

- [ ] **Step 3: 编译/语法自检（不连 DB）**

Run: `cd backend && python3 -c "import import_csv; print('main' in dir(import_csv), 'write_to_postgres' in dir(import_csv))"`
Expected：`True True`（模块可 import、CLI + 写库壳符号存在）。

- [ ] **Step 4: Commit**

```bash
cd "<repo-root>"
git add backend/import_csv.py
git commit -m "feat(b1): asyncpg 写库壳 + argparse CLI (Task 2)

D11 stocks/klines 幂等 UPSERT；D8 stock name 解析；D10 CLI(--input/--stock/
--period/--name/--dsn)，1m 先导建 ticket_index 基准。写库壳 import asyncpg 局部化，
纯层单测不依赖（D14 写库 CI 不测，B3/NAS scope）。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 — H6 deps pin + acceptance doc + 机检脚本

**Files:**
- Modify: `backend/requirements-dev.txt`（`>=`/`<` → `==`）
- Modify: `backend/docker-compose.yml`（postgres image → digest pin）
- Create: `docs/acceptance/2026-05-29-pr-b1-import-csv.md`
- Create: `scripts/acceptance/plan_b1_import_csv.sh`

- [ ] **Step 1: pin `requirements-dev.txt`**（先解析当前已安装版本，再写精确 `==`）

Run 先查实际版本：
```bash
cd backend && python3 -m pip show pytest httpx pglast openapi-spec-validator pyyaml 2>/dev/null | grep -E "^(Name|Version)"
```
然后把 `requirements-dev.txt` 改成精确 pin（用上一步查到的版本号，示例占位，实施者填真实值）：
```
pytest==8.x.y
httpx==0.27.z
pglast==6.x.y
openapi-spec-validator==0.7.z
pyyaml==6.x.y
```
> 实施者：版本号必须用 `pip show` 查到的**真实已解析版本**，不要猜。若 CI runner Python 版本解析出不同 patch，记为 residual（acceptance §K 说明：pin 反映本地解析快照）。

- [ ] **Step 2: pin docker-compose postgres image digest**

Run 查 digest：
```bash
docker pull postgres:15.12 >/dev/null 2>&1 && docker inspect --format='{{index .RepoDigests 0}}' postgres:15.12
```
把 `docker-compose.yml` 的 `image: postgres:15.12` 改为 `image: postgres:15.12@sha256:<查到的 digest>`。
> 若本地无 docker / 拉取失败：记 residual（acceptance §K：digest pin 待有 docker 环境补；本 PR 至少保留 tag pin）。**不要编造 digest**。

- [ ] **Step 3: 写 acceptance doc `docs/acceptance/2026-05-29-pr-b1-import-csv.md`**

完整内容（§A-§K）：

```markdown
# PR B1 验收清单（中文非程序员可执行）

> Wave 1 顺位 16 / 交付序第 18 个 PR。spec `kline_trainer_modules_v1.4.md` §四 B1 + `kline_trainer_plan_v1.5.md` §6.4.1。
> plan `docs/superpowers/plans/2026-05-29-pr-b1-import-csv.md`。

## §A 文件存在

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| A.1 | `ls backend/import_csv.py` | 存在 | 文件在 |
| A.2 | `ls backend/tests/test_import_csv.py backend/tests/fixtures/sample_1m.csv` | 两文件 | 都在 |
| A.3 | `test -f scripts/acceptance/plan_b1_import_csv.sh && echo OK` | OK | 输出 OK |

## §B 纯层 pytest 全绿（本地，无需 DB）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| B.1 | `cd backend && python3 -m pytest tests/test_import_csv.py -q` | `N passed`（N≥16），0 failed | exit=0 + 末行无 failed |

## §C 模块可导入 + CLI/写库符号存在

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| C.1 | `cd backend && python3 -c "import import_csv as m; print('main' in dir(m), 'write_to_postgres' in dir(m))"` | `True True` | 命中 |

## §D 指标公式落地（D2-D5 grep 锚）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| D.1 | `grep -nc 'rolling(window=66' backend/import_csv.py` | 1 (D3 MA66) | =1 |
| D.2 | `grep -nc 'std(ddof=0)' backend/import_csv.py` | 1 (D4 BOLL 总体 std) | =1 |
| D.3 | `grep -nc 'ewm(span=12, adjust=False)' backend/import_csv.py` | 1 (D5 EMA12) | =1 |
| D.4 | `grep -Fnc '(dif - dea) * 2' backend/import_csv.py` | 1 (D5 BAR×2；`-F` 固定串避免 `*` 被当通配符) | =1 |

## §E ticket_index 1m 基准语义（D6）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'searchsorted' backend/import_csv.py` | ≥1 (跨周期映射) | ≥1 |
| E.2 | `grep -nc 'return list(range(len(df)))' backend/import_csv.py` | 1 (1m 升序) | =1 |

## §F 双层边界：纯层不顶层依赖 asyncpg（D1/D14）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -ncE '^import asyncpg$' backend/import_csv.py` | 0 (asyncpg 只在函数内 import) | =0 |
| F.2 | `grep -nc 'import asyncpg  # 局部' backend/import_csv.py` | 1 (写库壳内局部 import) | =1 |

## §G H6-part1 deps 精确 pin（D12）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -cE '^[a-zA-Z0-9_.-]+==' backend/requirements-dev.txt` | =5 (全部 ==) | =5 |
| G.2 | `grep -cE '(>=|<)' backend/requirements-dev.txt` | 0 (无 range) | =0 |
| G.3 | `grep -nc 'postgres:15.12@sha256:' backend/docker-compose.yml` | 1 (digest pin) | =1（若无 docker 环境记 §K residual） |

## §H schema 未被改动（本 PR 只读 schema）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| H.1 | `git diff --name-only origin/main...HEAD -- backend/sql/` | 空 | 无输出 |

## §I 不碰 .github/workflows（D13 / user CI 决策）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| I.1 | `git diff --name-only origin/main...HEAD -- .github/` | 空 | 无输出 |

## §J 机检脚本自身

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_b1_import_csv.sh 2>&1 \| tail -2` | `✅ 所有 8 项 G1-G8 验收通过` | 末行 ✅ + exit 0 |

## §K Residuals

- **B1-R1**：backend pytest 未接 CI（user 2026-05-29 选"纯 opus xhigh，CI 延后"）。`test_import_csv.py` 仅本地 + 本脚本跑；接 path-gated CI workflow = trust-boundary，作独立 codex 治理 PR 后续补。
- **B1-R2**（条件性）：若实施时本地无 docker，§G.3 digest pin 待补，本 PR 保留 tag `postgres:15.12`。
- **B1-R3**：写库壳（`write_to_postgres`）+ CLI 无 CI 单测（D14，需 live PG = B3/NAS scope）；纯层覆盖全部业务正确性。
- **H7**：B1 仅提供测试用微型 fixture，3-5 个生产样本训练组数据由 B2（顺位 17）生成。
```

- [ ] **Step 4: 写机检脚本 `scripts/acceptance/plan_b1_import_csv.sh`**

```bash
#!/usr/bin/env bash
# Wave 1 顺位 16 (B1 import_csv) 机检验收
# 负向断言一律用 if/exit 1（per memory feedback_acceptance_grep_anchoring：set -e 下 ! grep 是死闸门）
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: 文件存在 =="
test -f backend/import_csv.py
test -f backend/tests/test_import_csv.py
test -f backend/tests/fixtures/sample_1m.csv
test -f docs/acceptance/2026-05-29-pr-b1-import-csv.md

echo "== G2: 纯层 pytest 全绿（无需 DB）=="
( cd backend && python3 -m pytest tests/test_import_csv.py -q 2>&1 | tee /tmp/b1-accept-pytest.txt | tail -3 )
if grep -qiE "failed|error" /tmp/b1-accept-pytest.txt; then echo "G2 FAIL: pytest 有失败"; exit 1; fi

echo "== G3: 模块可导入 + 符号存在 =="
( cd backend && python3 -c "import import_csv as m; assert 'main' in dir(m) and 'write_to_postgres' in dir(m)" )

echo "== G4: 指标公式落地（D2-D5）=="
grep -q 'rolling(window=66' backend/import_csv.py
grep -q 'std(ddof=0)' backend/import_csv.py
grep -q 'ewm(span=12, adjust=False)' backend/import_csv.py
grep -q '(dif - dea) \* 2' backend/import_csv.py

echo "== G5: ticket_index 1m 基准语义（D6）=="
grep -q 'searchsorted' backend/import_csv.py
grep -q 'return list(range(len(df)))' backend/import_csv.py

echo "== G6: 双层边界 — 纯层不顶层 import asyncpg（D1/D14）=="
if grep -qE '^import asyncpg$' backend/import_csv.py; then echo "G6 FAIL: asyncpg 不应顶层 import"; exit 1; fi
grep -q 'import asyncpg  # 局部' backend/import_csv.py

echo "== G7: H6 deps 精确 pin（D12）=="
PIN=$(grep -cE '^[a-zA-Z0-9_.-]+==' backend/requirements-dev.txt)
[ "$PIN" -ge 5 ] || { echo "G7 FAIL: requirements-dev.txt 应 ≥5 行 == pin，实得 $PIN"; exit 1; }
if grep -qE '(>=|<)' backend/requirements-dev.txt; then echo "G7 FAIL: requirements-dev.txt 仍有 range"; exit 1; fi

echo "== G8: schema 未改 + 不碰 workflows（H.1/I.1）=="
if git diff --name-only origin/main...HEAD -- backend/sql/ | grep -q .; then echo "G8 FAIL: 本 PR 不应改 schema"; exit 1; fi
if git diff --name-only origin/main...HEAD -- .github/ | grep -q .; then echo "G8 FAIL: 本 PR 不应碰 .github（CI 延后）"; exit 1; fi

echo
echo "✅ 所有 8 项 G1-G8 验收通过"
```

加可执行：`chmod +x scripts/acceptance/plan_b1_import_csv.sh`

- [ ] **Step 5: 跑机检脚本确认全绿**

Run: `bash scripts/acceptance/plan_b1_import_csv.sh 2>&1 | tail -2`
Expected：`✅ 所有 8 项 G1-G8 验收通过` + exit 0。

- [ ] **Step 6: Commit**

```bash
cd "<repo-root>"
git add backend/requirements-dev.txt backend/docker-compose.yml \
        docs/acceptance/2026-05-29-pr-b1-import-csv.md \
        scripts/acceptance/plan_b1_import_csv.sh
git commit -m "chore(b1): H6 deps 精确 pin + acceptance §A-§K + 机检脚本 (Task 3)

requirements-dev.txt == 精确 / docker postgres digest pin（H6-part1）；
非程序员验收 + 机检脚本（负向断言用 if/exit 1）；residual B1-R1 = CI 延后（codex PR）。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## R1 → v2 修订（plan-stage opus xhigh adversarial review）

R1 verdict **NEEDS-ATTENTION**（2H/2M/1L），reviewer 实测（装 pandas 2.2.3 跑真代码）验证。全部修：

| Finding | 严重度 | 修订方式 | 落地位置 |
|---|---|---|---|
| H1 `test_clean_dedupes_on_datetime_keep_last` 必失：dup 行 `close=99.0` 使 `high(10.2)<close` → 有效性过滤先丢掉，dedup 观测不到 | High | 改变异 `volume=999_999`（非 OHLC 校验字段），dup 行存活到 dedup；断言改查 volume | Task 1 Step 2 测试 |
| H2 `iterrows()` 把整行升格 float64 → datetime/volume/ticket_index 变 numpy.float64 → asyncpg int8/int4 codec 拒收（且 tested 纯代码里的真 bug 漏网） | High | `to_kline_records` 改 `to_dict("records")` + 按列显式 cast（`_INT_COLS`→int / `_FLOAT_COLS`→float，NaN→None）；加 `test_to_kline_records_integer_columns_are_python_int` 断言 `type(rec[c]) is int` | Task 1 Step 4 prod + Step 2 新测试 |
| M1 `_to_unix_seconds` 用 `.view("int64")` pandas 2.2.3 已 deprecated（FutureWarning，未来版本会断） | Medium | 改 `dt.astype("int64") // 1_000_000_000` | Task 1 Step 4 prod |
| M2 CLI `--period <非1m>` 把 1m 文件过滤掉 → baseline 仍 None → `compute_ticket_index` 抛 ValueError；D10 声称的"DB 查基准"从未实现 | Medium | `main()` 总是先从 dir 找 1m CSV 建 baseline（与 --period 过滤解耦）；非 1m 且无 1m 文件 → fail-fast；D10 措辞收紧不再声称 DB 路径 | D10 决议 + Task 2 Step 1 `main()` |
| L1 acceptance G2 `pytest|tee|tail` 在 pipefail 下 grep 门半死（pytest 非零先 abort）但净行为正确 | Low | **接受 residual**：reviewer 自评 "benign, no fix required"，失败 pytest 仍正确 fail 脚本 | — |

测试数：15 → 16（+`test_to_kline_records_integer_columns_are_python_int`；原 15 个 + 该 1 个 = 16，R3 prose 修：plan 早先误写 17）。reviewer 已实测确认 MA66/BOLL/MACD 数学 + ticket_index searchsorted + 17 列 INSERT 对齐 + NaN→None + grep 锚全部正确（"Verified correct" 清单）。R2（fresh opus xhigh）实测复核 APPROVE。

---

## R5 修订（Task 3 code-quality reviewer）

subagent-driven Task 3 code-quality review **NEEDS_FIXES**（1 Critical + 3 Minor），均 acceptance **doc-only**（机检脚本 8/8 真绿、G4 锚本就用 `\*` 正确）：

| Finding | 严重度 | 修订 |
|---|---|---|
| R5-C1 acceptance §D.4 human 命令 `grep -nc '(dif - dea) * 2'` 用 BRE 未转义 `*`（被当"零或多个空格"通配）→ 真 prod 行打印 `0` ≠ 期望 1 → 非程序员误判 correct tree FAILED（**第 6 个 PR 复发的注释/正则子串 bug-class**） | Critical（doc-only） | §D.4 改 `grep -Fnc '(dif - dea) * 2'`（`-F` 固定串）→ 实测打印 1；acceptance doc + plan 同步 |
| R5-M1 §J.1 表格 cell 内裸 `|` 破坏 markdown 渲染 | Minor | `2>&1 \| tail -2` 转义 |
| R5-M2 §J.1 期望 `所有 N 项` 占位 N vs 脚本输出 `8 项 G1-G8` | Minor | 改 `所有 8 项 G1-G8 验收通过` |
| R5-M3 §G.3 无对应脚本 gate（docker 缺，B1-R2 文档容忍） | Minor | **接受**：legitimate 文档容忍，非 defect |

R5-C1 只影响 human doc（机检脚本 G4 用 `grep -q '(dif - dea) \* 2'` BRE `\*`=字面，本就对）。修后脚本仍 8/8 绿。R5 不需新轮 review。

---

## R4 修订（Task 2 code-quality reviewer）

subagent-driven Task 2 code-quality review **APPROVED**（0 Critical/0 Important/3 Minor）。处理：

| Finding | 处理 |
|---|---|
| R4-1 typo/未知 `--period` 静默选 0 文件 → 打印"共写入 0 行"exit 0（看似成功的空导入，导入工具的操作 footgun） | **修**：`main()` 加 `KNOWN_PERIODS` 校验，未知 period → `ap.error` fail-fast；`_discover_period` 复用同常量。code + plan 同步。 |
| R4-2 `_resolve_stock_name` 取首个非 NaN（非首个非空白）name；whitespace-only 首行会落到 fallback | **接受 residual**：name 按约定每文件恒定，fallback（--name / code）安全；narrow edge。 |
| R4-3 每文件一个 `asyncio.run` 新事件循环/连接 | **接受 residual**：7 周期批量微不足道；复用连接增共享状态复杂度，CLAUDE.md §2 不值当。 |

R4-1 是 2 行 additive guard（不改业务逻辑/不改纯层/不改 17 列写库），16 纯层测试零回归。R4-2/R4-3 记 acceptance §K residual。R4 不需新轮 review。

---

## R3 修订（Task 1 implementer 抓 plan prose + 环境）

subagent-driven Task 1 implementer 报 DONE_WITH_CONCERNS，2 项均 plan/环境层（实现 16/16 真绿、逐字对齐）：

| Finding | 修订 |
|---|---|
| R3-1 plan prose 写"17 host pytest / 17 passed / N≥17"，但 Task 1 literal 测试块实为 **16** 个（原 15 + R1-H2 加的 1）。implementer 正确拒绝杜撰第 17 个测试。 | 全 prose 17→16（File Structure / Task 1 title / Step 5 / acceptance §B.1 N≥16 / R1→v2 note 改"15→16"）；指标分类 5→4（实为 4 个指标测试）。$17 列 INSERT / 顺位 17 (B2) 等"17"无关，保留。 |
| R3-2 本机只有 `python3` 无裸 `python`；plan 命令 + acceptance script/doc 用裸 `python` 在本地会 `command not found`（CI 已延后 → 脚本必须本地能跑） | plan 所有 `python -m pytest` / `python -c` / `python -m pip` → `python3`；Task 3 acceptance script + doc §B.1/§C.1/§J 同步用 `python3`。 |

R3 是 prose + 环境一致化，不改业务逻辑/测试断言（实现已 16/16 green）。R3 不需新轮 review。

---

## Self-Review（plan 写完后、push 给 reviewer 前）

**1. Spec 覆盖检查：**

| spec 要求 | 实现 task |
|---|---|
| §B1 职责 CSV→清洗→MA66/BOLL/MACD→ticket_index→PG | Task 1 纯函数 + Task 2 写库壳 |
| §B1 CLI `--input --stock [--period]` | Task 2 `main()` + 验收 C.1 |
| §B1 验收 row count / 时间连续性 / ticket_index 严格递增 | Task 1 `test_ticket_index_1m_strictly_increasing_from_zero` + clean 升序去重测试 |
| L335 amount 字段 | fixture 含 amount + to_kline_records 含 amount + 验收 |
| L336/L363 1m 基准 ticket_index + 能被 3/60 整除 | D6 + `test_ticket_index_3m/60m` |
| §15.4 H6 deps pin | Task 3 D12 + 验收 §G |
| §15.4 H7 sample 数据 | D15：B1 仅 fixture，生产数据 B2（residual §K） |

无 spec 要求缺 task。

**2. 占位扫描：** 无 "TBD/TODO/implement later"。注意 Task 3 Step 1/2 的版本号/digest 是**显式要求实施者用 `pip show`/`docker inspect` 查真实值填**（非占位——是"先查再填"指令，附"不要猜/编造"约束 + residual 兜底）。

**3. 类型一致性：** `parse_csv`/`clean`/`compute_indicators`/`compute_ticket_index`/`to_kline_records`/`write_to_postgres`/`main` 在 Task 1/2 定义与 test import 一致；`CsvSchemaError` 定义于 Task 1、test import 引用一致；record dict keys 与 `_KLINE_INSERT` $1..$17 顺序一致（17 列 = stock_code,period,datetime,open,high,low,close,volume,amount,ticket_index,ma66,boll_upper,boll_mid,boll_lower,macd_diff,macd_dea,macd_bar）。

**4. Acceptance/script 一致性：** §D/§E/§F/§G grep 锚与 script G4-G7 同字符串；负向断言（G6 asyncpg / G7 range / G8 schema+workflows）全用 `if grep; then exit 1; fi`（per memory `feedback_acceptance_grep_anchoring` C1）；human-grep §F.1 用 `^import asyncpg$` 行首锚、§G 用 `^...==` 行首锚避免注释子串碰撞（per 同 memory bug-class 2）。

**5. memory 教训落实：** 死闸门 idiom ✅ / 行首锚 ✅ / worktree cwd 三连确认提醒 ✅（constraint reminders）/ CI 决策已 user explicit ✅。

无 plan failure。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-pr-b1-import-csv.md`。

下一步走 user 已选定路径：先 **Plan-stage 对抗性 review = Claude Opus 4.7 xhigh effort**（主线 dispatch fresh subagent），收敛 APPROVE 后才进 **subagent-driven-development**（Task 1→2→3，每 Task fresh sonnet implementer + spec reviewer + code-quality reviewer 双道）→ verification-before-completion → requesting-code-review → branch-diff opus xhigh review 到收敛 → attest-override + admin merge。
