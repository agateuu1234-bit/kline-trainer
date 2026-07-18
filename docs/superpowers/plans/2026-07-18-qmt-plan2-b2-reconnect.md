# QMT 数据接入 Plan 2：D1 DDL 地基 + B2 生产装配重接 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 解除 Plan 1 遗留的 `assemble_training_set` fail-closed 停用——让 `generate_one_training_set` 走安全纯入口 `build_training_windows`（dense_dates 读持久化 `stock_coverage` 表），并落地 D1 的 A 类 DDL 治理三件套（migration / `CONTRACT_VERSION` bump / m01 矩阵）。

> ## ⚠️ 本 plan **不会**让 B4 补货真的出货
>
> （codex PF2-R1-F1，high；user 2026-07-18 裁决 = 保持范围、如实改口径）
>
> Plan 2 交付的是**「代码通路打通且被测试证明可用」**，**不是**「生产真出训练组」。原因：
>
> - PR 2a 建 `stock_coverage` **表**，但本 plan **没有任何代码往里写行**；
> - `import_csv.py`（B1）至今只写 `stocks`/`klines`，且**根本不认 QMT 格式**——Plan 1 只做了纯函数 `qmt_normalize`/`qmt_resample`，从未接进 B1；
> - `generate_one_training_set` 读不到覆盖行时 fail-closed 跳过；
> - Task 6 集成测是用**假 conn 注入**覆盖行的。
>
> **所以真库跑起来：每只股票都跳过，`generate_batch` 依然产 0。** 相对今天只是把「代码抛 `NotImplementedError`」换成「前置数据缺失」——**库存产出没有变化**。真正解锁出货的是 **Plan 3（B1 接 QMT 规整/合成层 + 写 `stock_coverage`）**。
>
> **本 plan 因此承担三项诚实义务（均已写进对应 Task，不得省略）：**
> 1. `generate_batch` 必须**打印首条 skip 原因**（Task 5 Step 11a）——否则运维只看到「仅生成 0/100」而不知为何，正是 codex 指的"测试全绿、生产静默跳过"陷阱；
> 2. PR 2b 的 body 与非-coder 验收清单必须写明「B4 仍产 0，直到 Plan 3」（PR 2b 收尾 Step 2/5）；
> 3. **禁止**在任何 commit message / PR / 验收项里写「B4 补货已恢复」「库存已可生成」之类表述。

**Architecture:** 拆两个顺序 PR。**PR 2a**（DDL/契约地基）建 `backend/sql/migrations/0004_*/{forward,rollback}.sql`——同一 migration 内 OHLC `DECIMAL(10,2)→DOUBLE PRECISION` + `training_sets.file_path VARCHAR(255)→TEXT` + `CREATE TABLE stock_coverage`——并同步 `schema.sql` fresh baseline、bump `CONTRACT_VERSION`、更新 m01 矩阵、停写 `ticket_index`（保留列）。**PR 2b**（B2 重接）在 2a 建好的表上，把 `generate_one_training_set` 从已停用的 `assemble_training_set` 切到 `build_training_windows`，新增纯装配函数 `assemble_from_windows`，并补一条走真实生产函数链的集成测。

**Tech Stack:** Python 3.11（pandas 2.2.3 / pytest 8.4.2 / pglast 7.13）、PostgreSQL 15 DDL、Swift（仅版本常量 + 其测试）。

## Global Constraints

以下为全 plan 生效的硬约束，每个 Task 的要求隐含包含本节。

- **Python 解释器**：必须用仓库根 `.venv`（Python 3.11.15）。host `python3` 是 3.14.6，**跑 pandas 会段错误**。所有 pytest 命令一律 `cd backend && ../.venv/bin/python -m pytest ...`。venv 已建好；若缺失，重建命令见 Task 0。
- **基线**：`main` `7037934`，`cd backend && ../.venv/bin/python -m pytest tests/ -q` = **170 passed**。任何 Task 结束时测试数只增不减，且 **0 failed / 0 skipped**。
- **CI 禁 skip**：`.github/workflows/backend-tests.yml` 解析 junit XML，**任何 `skipped>0` 即 fail**。因此**禁止**新增任何 `pytest.mark.skip` / `xfail` / 条件 skip 的测试（含"没有 Docker 就 skip"）。本 plan 的集成测用假 asyncpg conn，不依赖真 PG。
- **`CONTRACT_VERSION` 权威当前值 = `"1.11"`**（`ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`），**不是 spec/memory 里写的 `"1.8"`**——spec（2026-07-06）之后 PR #132/#136/#139/#140 连续 bump 到 1.11。本 plan 的 bump 是 **1.11 → 1.12**。
- **`ticket_index` 只停写、不删列**（m01 禁 Wave 1+ 不可逆迁移）：`schema.sql` 保留 `ticket_index INTEGER`，migration 对该列**零 DDL**。
- **价格列禁 round**：OHLC 走 `DOUBLE PRECISION` 全精度；`amount DECIMAL(16,2)` 与指标列 `DECIMAL(10,4)/(10,6)` + `round(4/6)` **不变**。
- **负向断言禁 `! grep`**：验收脚本里用 `if grep -q ...; then exit 1; fi`（`set -e` 下 `! grep` 会死闸门）。
- **每 PR ≤3 子项 ≤500 行**：PR 2a = Task 1-3，PR 2b = Task 4-6。不得合并成一个 PR。
- **codex review 用 `--scope branch-diff`**，不用 `working-tree`（先 commit 再 working-tree = 空审假 approve）。

---

## 文件结构

**PR 2a 触及：**

| 文件 | 责任 |
|---|---|
| `backend/sql/migrations/0004_qmt_price_double_and_coverage/forward.sql`（建） | 三项 DDL 前向：OHLC→DOUBLE、file_path→TEXT、建 `stock_coverage` |
| `backend/sql/migrations/0004_qmt_price_double_and_coverage/rollback.sql`（建） | 对应回滚，**显式标注 OHLC 回滚丢精度** |
| `backend/sql/schema.sql`（改） | fresh baseline 同步到迁移后状态 |
| `backend/tests/test_schema.py`（改） | 表集合断言加 `stock_coverage`；新增 OHLC 类型 / file_path 类型断言 |
| `backend/tests/test_migrations.py`（建） | migration SQL 语法 + forward/rollback 对称性（pglast 静态解析，不需 Docker） |
| `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift`（改） | `CONTRACT_VERSION` 1.11→1.12（仅常量） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift`（改） | 期望值与测试名同步 |
| `docs/governance/m01-schema-versioning-contract.md`（改） | 矩阵两个 cell + bump 记录（含校正 stale 1.7） |
| `backend/import_csv.py`（改） | 删 `compute_ticket_index`、`_KLINE_INSERT` 去该列、CLI 去基准逻辑 |
| `backend/tests/test_import_csv.py`（改） | 删 3 个 ticket_index 专测 + 3 处 fixture 赋值；新增"停写"回归断言 |

**PR 2b 触及：**

| 文件 | 责任 |
|---|---|
| `backend/generate_training_sets.py`（改） | **修 D9 门首日边界**；删 `assemble_training_set`；加 `assemble_from_windows`；`build_training_windows` 加 `exclude_starts`；重接 `generate_one_training_set` + 加 `_fetch_dense_coverage`/`_fetch_existing_starts` |
| `backend/app/scheduler.py`（改） | 删已成孤儿的 `NotImplementedError` 捕获块 |
| `backend/tests/test_generate_training_sets.py`（改） | 加 D9 生产-cap 回归测；删 fail-closed 测；加 `assemble_from_windows` + `exclude_starts` 单测 |
| `backend/tests/test_b2_reconnect_integration.py`（建） | 假 asyncpg conn 上跑真实生产链 → 断言 ≥1 registered training set |

> **⚠️ PR 2b Task 4 是本 plan 实施期发现的 Plan 1 遗留 bug，不在原 spec 里。** 实测证据（完美 fixture：46 个月历史、每交易日精确 80/16/4 根、零 drop）：8 个 dense 候选**全部**被 D9 门拒，`build_training_windows` 抛 `GenerateSkipException: bounded retry 穷尽` → **完美数据也产 0 训练组**。不先修这条，Task 5 的重接与 Task 6 的核心验收断言都不可能通过。

---

## Task 0：环境前置（仅当 `.venv` 缺失时执行）

- [ ] **Step 1: 确认 venv 可用**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
.venv/bin/python -V
```

期望输出：`Python 3.11.15`。若报 "No such file"，执行：

```bash
/opt/homebrew/bin/python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r backend/requirements-test.txt
```

- [ ] **Step 2: 跑基线**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/ -q
```

期望：`170 passed`。数字对不上就**停下报告**，不要继续。

---

# PR 2a：D1 DDL 地基 + 契约 bump

分支：`qmt-plan2a-ddl-contract`（从 `main` `7037934` 切）。

---

## Task 1: PG migration 0004 + schema.sql fresh baseline

D1 的 A 类 DDL 落地。三项变更打进**同一个** migration（同一次 `CONTRACT_VERSION` bump 覆盖，无额外触发）。

**Files:**
- Create: `backend/sql/migrations/0004_qmt_price_double_and_coverage/forward.sql`
- Create: `backend/sql/migrations/0004_qmt_price_double_and_coverage/rollback.sql`
- Create: `backend/tests/test_migrations.py`
- Modify: `backend/sql/schema.sql:18-21`（OHLC 四列）、`:45`（file_path）、`:34` 后（新表）
- Modify: `backend/tests/test_schema.py:39`（表集合断言）

**Interfaces:**
- Consumes: 无（本 plan 首个 Task）
- Produces: PG 表 `stock_coverage(stock_code TEXT PK, dense_1m_start_date DATE NOT NULL, dense_1m_end_date DATE NOT NULL, dropped_1m_dates JSONB NOT NULL DEFAULT '[]'::jsonb, dense_day_count INTEGER NOT NULL)` + 三条 CHECK（区间非反向 / dropped 为 JSON 数组 / 计数非负）——Task 5 的 `_fetch_dense_coverage` 按这五列名读取。`klines.open/high/low/close` 类型 `double precision`。`training_sets.file_path` 类型 `text`。

- [ ] **Step 1: 写失败测试（migration 文件存在性 + 语法 + 对称性）**

创建 `backend/tests/test_migrations.py`：

```python
"""Validate backend/sql/migrations/*/{forward,rollback}.sql.

用 pglast（libpg_query 绑定）静态解析，不需要 Docker 或 PG daemon——与
test_schema.py 同约定；真库前向迁移验证属 B3/NAS owner scope。
"""
from __future__ import annotations

from pathlib import Path

import pglast

MIGRATIONS_DIR = Path(__file__).parent.parent / "sql" / "migrations"
MIG_0004 = MIGRATIONS_DIR / "0004_qmt_price_double_and_coverage"


def test_migration_0004_has_forward_and_rollback():
    """m01 §Migration Rollback：每个 migration 必须是 forward+rollback 成对。"""
    assert (MIG_0004 / "forward.sql").is_file(), "缺 forward.sql"
    assert (MIG_0004 / "rollback.sql").is_file(), "缺 rollback.sql"


def test_migration_0004_forward_is_valid_postgres():
    sql = (MIG_0004 / "forward.sql").read_text(encoding="utf-8")
    assert len(pglast.parse_sql(sql)) > 0


def test_migration_0004_rollback_is_valid_postgres():
    sql = (MIG_0004 / "rollback.sql").read_text(encoding="utf-8")
    assert len(pglast.parse_sql(sql)) > 0


def test_migration_0004_forward_converts_ohlc_to_double():
    """D1：四个价格列都必须被转成 double precision（少一列 = 静默截断残留）。"""
    sql = (MIG_0004 / "forward.sql").read_text(encoding="utf-8").lower()
    for col in ("open", "high", "low", "close"):
        assert f"alter column {col} type double precision" in sql, f"{col} 未转 DOUBLE"


def test_migration_0004_forward_creates_stock_coverage():
    """D11：B2 读 dense_dates 的权威 artifact 表。"""
    sql = (MIG_0004 / "forward.sql").read_text(encoding="utf-8").lower()
    assert "create table" in sql and "stock_coverage" in sql


def test_migration_0004_stock_coverage_carries_integrity_checks():
    """codex PF2-R2-F1：migration 建的表必须与 schema.sql 一样带约束，
    否则已部署库前向迁移后仍是无约束的坏行温床。"""
    sql = (MIG_0004 / "forward.sql").read_text(encoding="utf-8").lower()
    assert "jsonb" in sql
    assert "jsonb_typeof(dropped_1m_dates) = 'array'" in sql
    assert "dense_1m_start_date <= dense_1m_end_date" in sql


def test_migration_0004_forward_widens_file_path_to_text():
    """R16-F2：绝对路径可任意长，VARCHAR(255) 会让登记 INSERT 失败留 orphan。"""
    sql = (MIG_0004 / "forward.sql").read_text(encoding="utf-8").lower()
    assert "alter column file_path type text" in sql


def test_migration_0004_rollback_reverses_all_three_changes():
    """回滚必须覆盖三项：OHLC 回 DECIMAL、file_path 回 VARCHAR(255)、drop 新表。"""
    sql = (MIG_0004 / "rollback.sql").read_text(encoding="utf-8").lower()
    for col in ("open", "high", "low", "close"):
        assert f"alter column {col} type decimal(10,2)" in sql, f"{col} 未回滚"
    assert "alter column file_path type varchar(255)" in sql
    assert "drop table" in sql and "stock_coverage" in sql


def test_migration_0004_rollback_documents_precision_loss():
    """m01 要求：有损回滚必须在文件里显式标注（人工执行前要看得见）。"""
    text = (MIG_0004 / "rollback.sql").read_text(encoding="utf-8")
    assert "丢精度" in text, "rollback.sql 未标注 OHLC 回滚丢精度"


def test_migration_0004_does_not_touch_ticket_index():
    """D3/R12-F1：ticket_index 保留列、只停写。任何对该列的 DDL 都是不可逆迁移违规。"""
    for name in ("forward.sql", "rollback.sql"):
        sql = (MIG_0004 / name).read_text(encoding="utf-8").lower()
        assert "ticket_index" not in sql, f"{name} 不得对 ticket_index 做任何 DDL"
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_migrations.py -q
```

期望：全部 FAIL（`assert ... is_file()` 报 "缺 forward.sql"，其余 `FileNotFoundError`）。

- [ ] **Step 3: 写 forward.sql**

创建 `backend/sql/migrations/0004_qmt_price_double_and_coverage/forward.sql`：

```sql
-- Migration 0004: QMT 前复权价格精度 + B1→B2 覆盖契约
-- 引用治理：docs/governance/m01-schema-versioning-contract.md §Bump 策略 A
-- 触发：A 类 DDL「改类型」→ 顶层 CONTRACT_VERSION 1.11 → 1.12
-- Spec: docs/superpowers/specs/2026-07-06-qmt-data-ingestion-pilot-design.md §4.3 (D1/D5/D11)
--
-- 三项变更（同一 migration，同一次 bump 覆盖）：
--   1. klines OHLC DECIMAL(10,2) → DOUBLE PRECISION（前复权 float64 无损；2 位截断会压塌老 K 线）
--   2. training_sets.file_path VARCHAR(255) → TEXT（D5 绝对路径可任意长）
--   3. 新增 stock_coverage 表（D11：B1 写权威 dense 1m 覆盖，B2 读作 dense_dates）
--
-- 注：ticket_index 列「保留、停止写入」（D3），本 migration 对该列零 DDL。

BEGIN;

-- 1. 价格列升精度（DECIMAL→DOUBLE 是放宽，存量值无损上转）
ALTER TABLE klines ALTER COLUMN open  TYPE DOUBLE PRECISION;
ALTER TABLE klines ALTER COLUMN high  TYPE DOUBLE PRECISION;
ALTER TABLE klines ALTER COLUMN low   TYPE DOUBLE PRECISION;
ALTER TABLE klines ALTER COLUMN close TYPE DOUBLE PRECISION;

-- 2. file_path 去长度限（VARCHAR(255)→TEXT 是扩容，存量值无损）
ALTER TABLE training_sets ALTER COLUMN file_path TYPE TEXT;

-- 3. B1→B2 覆盖契约表（D11）
-- 约束在 DB 层可执行（codex PF2-R2-F1）：spec §4.3 原写 `TEXT DEFAULT '[]'` 无任何约束，
-- 坏行（非 JSON / 非数组 / 反向区间）会让 B2 reader 抛 ValueError 穿出 generate_batch
-- （它只捕 GenerateSkipException）→ **中止整轮 sweep** 而非跳过一只股。故收紧为
-- JSONB NOT NULL + 数组类型检查 + 区间/计数合法性检查。reader 侧另有降级兜底（防历史行）。
CREATE TABLE IF NOT EXISTS stock_coverage (
    stock_code          TEXT PRIMARY KEY,
    dense_1m_start_date DATE NOT NULL,
    dense_1m_end_date   DATE NOT NULL,
    dropped_1m_dates    JSONB NOT NULL DEFAULT '[]'::jsonb,
    dense_day_count     INTEGER NOT NULL,
    CONSTRAINT ck_stock_coverage_range CHECK (dense_1m_start_date <= dense_1m_end_date),
    CONSTRAINT ck_stock_coverage_dropped_is_array
        CHECK (jsonb_typeof(dropped_1m_dates) = 'array'),
    CONSTRAINT ck_stock_coverage_day_count CHECK (dense_day_count >= 0)
);

COMMENT ON TABLE stock_coverage
  IS 'D11：B1 分钟级完整性判定后写入的权威 dense 1m 覆盖；B2 D2 从此表读 dense_dates（非从 klines 反推）。';
COMMENT ON COLUMN stock_coverage.dropped_1m_dates
  IS '带内被 drop 的交易日 JSON 数组（通常 []）；dense_dates = [start,end] 交易日 − 本列。';

COMMIT;
```

- [ ] **Step 4: 写 rollback.sql**

创建 `backend/sql/migrations/0004_qmt_price_double_and_coverage/rollback.sql`：

```sql
-- Rollback for 0004_qmt_price_double_and_coverage
-- 引用治理：docs/governance/m01-schema-versioning-contract.md §Migration Rollback
--
-- ⚠️ 有损回滚警告 ⚠️
-- 本回滚把 klines OHLC 从 DOUBLE PRECISION 收窄回 DECIMAL(10,2)，**丢精度**：
--   - QMT 前复权价是 float64（如 11.790828206557329）→ 回滚后截断为 11.79
--   - 老 K 线被前复权缩得极小（如 1991 年 0.61...）→ 2 位截断会压塌整条老 K 线
--   - **精度不可恢复**。执行前必须先备份 klines，或确认该库无 QMT 前复权数据。
-- 同理 file_path 收窄回 VARCHAR(255)：若存量有 >255 字符的绝对路径，本语句会**报错中止**
-- （PostgreSQL 拒绝截断）——这是刻意的 fail-closed，先人工清理超长路径再回滚。

BEGIN;

-- 3. 删覆盖契约表（新表，回滚不丢既有业务数据）
DROP TABLE IF EXISTS stock_coverage;

-- 2. file_path 收窄（存量值须 ≤255，否则本语句报错中止）
ALTER TABLE training_sets ALTER COLUMN file_path TYPE VARCHAR(255);

-- 1. 价格列降精度 —— 丢精度，见顶部警告
ALTER TABLE klines ALTER COLUMN open  TYPE DECIMAL(10,2);
ALTER TABLE klines ALTER COLUMN high  TYPE DECIMAL(10,2);
ALTER TABLE klines ALTER COLUMN low   TYPE DECIMAL(10,2);
ALTER TABLE klines ALTER COLUMN close TYPE DECIMAL(10,2);

COMMIT;
```

- [ ] **Step 5: 跑 migration 测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_migrations.py -q
```

期望：`10 passed`。

- [ ] **Step 6: 写 schema.sql fresh baseline 的失败测试**

在 `backend/tests/test_schema.py` 末尾追加：

```python
# ---- Plan 2a：D1 DDL（OHLC DOUBLE / file_path TEXT / stock_coverage）----

def _column_type_names(table: str) -> dict:
    """表名 → {列名: 小写类型名}（pglast AST，TypeName.names 末段即类型名）。"""
    stmts = _parse_schema()
    create = next(
        s.stmt for s in stmts
        if isinstance(s.stmt, CreateStmt) and s.stmt.relation.relname == table
    )
    out = {}
    for elt in create.tableElts:
        colname = getattr(elt, "colname", None)
        typename = getattr(elt, "typeName", None)
        if colname and typename is not None:
            out[colname] = typename.names[-1].sval.lower()
    return out


def test_klines_ohlc_are_double_precision():
    """D1：前复权 float64 全精度入库；DECIMAL(10,2) 会压塌老 K 线。"""
    cols = _column_type_names("klines")
    for c in ("open", "high", "low", "close"):
        assert cols[c] == "float8", f"klines.{c} 期望 double precision，实为 {cols[c]}"


def test_klines_amount_and_indicators_stay_decimal():
    """D1 明确只改价格列；amount/指标列不变（改了就是超范围 DDL）。"""
    cols = _column_type_names("klines")
    assert cols["amount"] == "numeric"
    for c in ("ma66", "boll_upper", "boll_mid", "boll_lower",
              "macd_diff", "macd_dea", "macd_bar"):
        assert cols[c] == "numeric", f"klines.{c} 不应被改动"


def test_klines_ticket_index_column_retained():
    """D3/R12-F1：ticket_index 只停写、列必须保留（删列 = 不可逆迁移违规）。"""
    cols = _column_type_names("klines")
    assert "ticket_index" in cols, "ticket_index 列被删了——违反 m01 不可逆迁移禁令"


def test_training_sets_file_path_is_text():
    """R16-F2：绝对路径任意长，VARCHAR(255) 会让登记 INSERT 失败留 orphan。"""
    cols = _column_type_names("training_sets")
    assert cols["file_path"] == "text", f"file_path 期望 text，实为 {cols['file_path']}"


def test_stock_coverage_table_columns():
    """D11：B1 写 / B2 读的覆盖契约表五列。"""
    cols = _column_type_names("stock_coverage")
    assert set(cols) == {"stock_code", "dense_1m_start_date", "dense_1m_end_date",
                         "dropped_1m_dates", "dense_day_count"}
    assert cols["dropped_1m_dates"] == "jsonb", "须为 JSONB 以便 DB 层校验数组类型"


def test_stock_coverage_has_integrity_checks():
    """codex PF2-R2-F1：坏覆盖行会让 B2 reader 抛非-Skip 异常、中止整轮 sweep。
    约束必须在 DB 层可执行，不能只靠 reader 兜底。"""
    sql = SCHEMA_PATH.read_text(encoding="utf-8").lower()
    seg = sql.split("create table if not exists stock_coverage")[1].split(");")[0]
    assert "jsonb_typeof(dropped_1m_dates) = 'array'" in seg, "缺 dropped 数组类型检查"
    assert "dense_1m_start_date <= dense_1m_end_date" in seg, "缺覆盖带非反向检查"
    assert "dense_day_count >= 0" in seg, "缺计数非负检查"
    for col in ("dense_1m_start_date", "dense_1m_end_date", "dense_day_count"):
        assert f"{col} date not null" in seg or f"{col} integer not null" in seg, \
            f"{col} 应为 NOT NULL"
```

同时把 `backend/tests/test_schema.py:39` 的表集合断言从：

```python
    assert table_names == {"stocks", "klines", "training_sets"}, (
        f"expected {{stocks,klines,training_sets}}, got {table_names}"
    )
```

改成：

```python
    assert table_names == {"stocks", "klines", "training_sets", "stock_coverage"}, (
        f"expected {{stocks,klines,training_sets,stock_coverage}}, got {table_names}"
    )
```

- [ ] **Step 7: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_schema.py -q
```

期望：FAIL——表集合断言报缺 `stock_coverage`；`test_klines_ohlc_are_double_precision` 报实为 `numeric`；`test_stock_coverage_table_columns` 抛 `StopIteration`。

- [ ] **Step 8: 改 schema.sql**

`backend/sql/schema.sql` 三处改动。

其一，klines 四个价格列（第 18-21 行）：

```sql
    open DECIMAL(10,2) NOT NULL,
    high DECIMAL(10,2) NOT NULL,
    low DECIMAL(10,2) NOT NULL,
    close DECIMAL(10,2) NOT NULL,
```

改为：

```sql
    open DOUBLE PRECISION NOT NULL,
    high DOUBLE PRECISION NOT NULL,
    low DOUBLE PRECISION NOT NULL,
    close DOUBLE PRECISION NOT NULL,
```

其二，training_sets 的 file_path（第 45 行）：

```sql
    file_path VARCHAR(255) NOT NULL,
```

改为：

```sql
    file_path TEXT NOT NULL,
```

其三，在 `CREATE INDEX IF NOT EXISTS idx_klines_lookup ...`（第 36 行）之后、`CREATE TABLE IF NOT EXISTS training_sets` 之前插入新表：

```sql
-- D11（spec §4.3）：B1→B2 覆盖契约。B1 分钟级完整性判定后写入权威 dense 1m 覆盖，
-- B2 D2 从此表读 dense_dates（= [start,end] 交易日 − dropped_1m_dates），不从 klines 反推。
CREATE TABLE IF NOT EXISTS stock_coverage (
    stock_code          TEXT PRIMARY KEY,
    dense_1m_start_date DATE NOT NULL,
    dense_1m_end_date   DATE NOT NULL,
    dropped_1m_dates    JSONB NOT NULL DEFAULT '[]'::jsonb,
    dense_day_count     INTEGER NOT NULL,
    CONSTRAINT ck_stock_coverage_range CHECK (dense_1m_start_date <= dense_1m_end_date),
    CONSTRAINT ck_stock_coverage_dropped_is_array
        CHECK (jsonb_typeof(dropped_1m_dates) = 'array'),
    CONSTRAINT ck_stock_coverage_day_count CHECK (dense_day_count >= 0)
);

```

最后把文件头第 1 行的版本注释：

```sql
-- Kline Trainer PostgreSQL schema v1.4
```

改为：

```sql
-- Kline Trainer PostgreSQL schema v1.4 + migration 0004（QMT：OHLC DOUBLE / file_path TEXT / stock_coverage）
```

- [ ] **Step 9: 跑测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_schema.py tests/test_migrations.py -q
```

期望：全 passed，且 `test_klines_ticket_index_column_retained` 在其中（证明没顺手删列）。

- [ ] **Step 10: 跑全套件确认零回归**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/ -q
```

期望：`185 passed`（170 基线 + 10 migration + 5 schema）。**0 failed / 0 skipped**。

- [ ] **Step 11: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add backend/sql/migrations backend/sql/schema.sql backend/tests/test_migrations.py backend/tests/test_schema.py
git commit -m "$(cat <<'EOF'
Plan2a Task1: PG migration 0004（OHLC→DOUBLE + file_path→TEXT + stock_coverage 建表）

D1 A 类 DDL 落地：forward/rollback 成对，rollback 显式标注 OHLC 丢精度。
ticket_index 列保留、零 DDL（m01 禁 Wave1+ 不可逆迁移）。
schema.sql fresh baseline 同步；pglast 静态测覆盖三项变更 + 对称回滚。
EOF
)"
```

---

## Task 2: CONTRACT_VERSION 1.11 → 1.12 + m01 矩阵

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift:6-9`
- Modify: `docs/governance/m01-schema-versioning-contract.md:33`（顶层 cell）、`:34`（PG migration id cell）、`:38` 后（bump 记录）

**Interfaces:**
- Consumes: Task 1 的 migration 目录名 `0004_qmt_price_double_and_coverage`（写进 m01 矩阵的 PG schema cell）
- Produces: 无下游代码依赖（纯版本常量 + 文档）

- [ ] **Step 1: 改 Swift 测试期望（先测后码）**

`ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift` 第 6-9 行：

```swift
struct ContractVersionTests {
    @Test func contractVersionIs1_11() {
        #expect(CONTRACT_VERSION == "1.11")
    }
```

改为：

```swift
struct ContractVersionTests {
    @Test func contractVersionIs1_12() {
        #expect(CONTRACT_VERSION == "1.12")
    }
```

- [ ] **Step 2: 跑 Swift 测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter ContractVersionTests 2>&1 | tail -20
```

期望：FAIL，`#expect(CONTRACT_VERSION == "1.12")` 实际得到 `"1.11"`。

- [ ] **Step 3: 改常量**

`ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` 第 7 行：

```swift
public let CONTRACT_VERSION = "1.11"
```

改为：

```swift
public let CONTRACT_VERSION = "1.12"
```

- [ ] **Step 4: 跑 Swift 测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test --filter ContractVersionTests 2>&1 | tail -20
```

期望：PASS。

- [ ] **Step 5: 更新 m01 矩阵两个 cell**

`docs/governance/m01-schema-versioning-contract.md` 第 33-34 行：

```markdown
| `CONTRACT_VERSION`（顶层标识） | `"1.7"` | 跨系统或破坏性持久化变更 bump 联动；P2 本地 journal state 的**兼容新增**不联动 |
| PostgreSQL schema（`schema.sql` migration id） | `0003_v1.3` | 任何 PostgreSQL DDL 变更（含加列）；联动顶层 |
```

改为：

```markdown
| `CONTRACT_VERSION`（顶层标识） | `"1.12"` | 跨系统或破坏性持久化变更 bump 联动；P2 本地 journal state 的**兼容新增**不联动 |
| PostgreSQL schema（`schema.sql` migration id） | `0004_qmt_price_double_and_coverage` | 任何 PostgreSQL DDL 变更（含加列）；联动顶层 |
```

- [ ] **Step 6: 追加 bump 记录**

在 `docs/governance/m01-schema-versioning-contract.md` 第 38 行那条 2026-06-22 记录之后，插入：

```markdown
> **bump 记录（2026-07-18，QMT 数据接入 Plan 2a）**：顶层 `CONTRACT_VERSION` `"1.11"` → `"1.12"`。触发 = A 类「影响 DDL / 改类型」：PostgreSQL migration `0004_qmt_price_double_and_coverage` —— (1) `klines.open/high/low/close` `DECIMAL(10,2)` → `DOUBLE PRECISION`（QMT 前复权为 float64，2 位截断会压塌老 K 线并丢复权精度）；(2) `training_sets.file_path` `VARCHAR(255)` → `TEXT`（绝对路径任意长）；(3) 新增 `stock_coverage` 表（D11 B1→B2 覆盖契约）。PG schema sub-version 同步 `0003_v1.3` → `0004_qmt_price_double_and_coverage`。**iOS reader 逻辑零改动**（`KLineCandle` 本就 `Double`、训练组 SQLite 本就 `REAL`，端到端浮点），仅版本常量 + 其测试随顶层 bump 改。`ticket_index` 列**保留、仅停止写入**（非删列——m01 禁 Wave 1+ 不可逆迁移）。详见 `docs/superpowers/specs/2026-07-06-qmt-data-ingestion-pilot-design.md` §4.3。
>
> **矩阵 stale 校正（同次）**：顶层 cell 此前 stale 为 `"1.7"`，实际代码已在本次之前被四个 PR 连续 bump 至 `"1.11"` 而未同步本矩阵——#132 RFC-A 交易/仓位/资金（`1.7`→`1.8`）、#136 replay 续局 + 复盘步进（`1.8`→`1.9`）、#139 复盘完整重设计（`1.9`→`1.10`）、#140 划线工具 P1a 契约地基（`1.10`→`1.11`）。本次一并校正到 `"1.12"`（含本 plan 的 bump）。同 2026-06-22 记录里「cell 此前 stale 为 `1.5`」的先例处理方式。
```

- [ ] **Step 7: 验证矩阵无残留 stale 值**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
# 负向断言用 if/exit，不用 `! grep`（set -e 下会死闸门）
if grep -qE '^\| `CONTRACT_VERSION`（顶层标识） \| `"1\.(7|8|9|10|11)"`' docs/governance/m01-schema-versioning-contract.md; then
  echo "FAIL: 顶层 cell 仍是旧值"; exit 1
fi
grep -c '`"1.12"`' docs/governance/m01-schema-versioning-contract.md
```

期望：无 FAIL 输出；`grep -c` 返回 `2`（矩阵 cell 1 处 + bump 记录 1 处）。

- [ ] **Step 8: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift \
        docs/governance/m01-schema-versioning-contract.md
git commit -m "$(cat <<'EOF'
Plan2a Task2: CONTRACT_VERSION 1.11→1.12 + m01 矩阵（含校正 stale 1.7 cell）

migration 0004 是 A 类 DDL「改类型」→ 必须 bump 顶层。
iOS reader 逻辑零改动，仅常量 + 其测试。
矩阵顶层 cell 此前 stale 为 1.7（#132/#136/#139/#140 四次 bump 未同步），一并校正。
EOF
)"
```

---

## Task 3: ticket_index 停止写入（保留列）

D3/R12-F1：删 Python 侧计算与写入，**列不动**。已 grep 核实无下游消费者（B2 `_KLINE_SELECT_COLS` 不含该列、iOS 零 `.swift` 引用）。

**Files:**
- Modify: `backend/import_csv.py:4`、`:12`（头注释）、`:92-103`（删函数）、`:109`（`_INT_COLS`）、`:133`（docstring）、`:153-165`（`_KLINE_INSERT`）、`:180-186`（executemany 元组）、`:231-236`+`:243`+`:251`（CLI 基准逻辑）
- Modify: `backend/tests/test_import_csv.py:16`、`:127-148`（删 3 测）、`:154`、`:160`、`:166`、`:173`、`:175`

**Interfaces:**
- Consumes: 无
- Produces: `to_kline_records()` 返回的 dict **不再含** `ticket_index` 键；`_KLINE_INSERT` 变为 16 个占位符（原 17）

- [ ] **Step 1: 改测试——删 3 个 ticket_index 专测，加停写回归断言**

`backend/tests/test_import_csv.py` 第 16 行，从 import 块删掉 `compute_ticket_index,` 这一行。

删除第 127-148 行整块（`# ---- D6 ticket_index ----` 标题 + 三个 `test_ticket_index_*` 函数）。

第 154 行、166 行、173 行各有一行 `df["ticket_index"] = compute_ticket_index(df, period="1m", baseline_1m_datetimes=None)`，**三处全部删除**。

第 160 行的期望列元组里含 `"ticket_index",`，删掉该项。

第 175 行 `for col in ("datetime", "volume", "ticket_index"):` 改为：

```python
    for col in ("datetime", "volume"):
```

然后在文件末尾追加停写回归断言：

```python
# ---- D3/R12-F1：ticket_index 停止写入（列保留、新行 NULL）----

def test_to_kline_records_omits_ticket_index():
    """D3：Python 侧不再产出 ticket_index；PG 列保留、新行为 NULL。"""
    df = compute_indicators(clean(_synthetic(70)))
    records = to_kline_records(df, stock_code="600519", period="1m")
    assert records, "fixture 应产出记录"
    assert "ticket_index" not in records[0], "ticket_index 应已停写"


def test_kline_insert_sql_has_no_ticket_index():
    """INSERT 语句不得再含该列——留着会让 executemany 元组数与占位符错位。"""
    from import_csv import _KLINE_INSERT
    assert "ticket_index" not in _KLINE_INSERT


def test_kline_insert_placeholder_count_matches_columns():
    """防"删列名忘删占位符"：列数必须与 $N 最大编号一致。"""
    import re
    from import_csv import _KLINE_INSERT
    cols = _KLINE_INSERT.split("INSERT INTO klines (")[1].split(")")[0]
    n_cols = len([c for c in cols.split(",") if c.strip()])
    n_ph = max(int(m) for m in re.findall(r"\$(\d+)", _KLINE_INSERT))
    assert n_cols == n_ph == 16, f"列 {n_cols} vs 占位符 {n_ph}，期望均为 16"


def test_compute_ticket_index_symbol_removed():
    """函数已删除；残留即说明停写没做干净。"""
    import import_csv
    assert not hasattr(import_csv, "compute_ticket_index")
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_import_csv.py -q
```

期望：FAIL——`test_to_kline_records_omits_ticket_index` 报该键仍在；`test_kline_insert_sql_has_no_ticket_index` FAIL；占位符测报 `17`；`test_compute_ticket_index_symbol_removed` FAIL。

- [ ] **Step 3: 改 import_csv.py**

删除第 92-103 行整个 `compute_ticket_index` 函数（连同其上下空行）。

第 109 行：

```python
_INT_COLS = ("datetime", "volume", "ticket_index")
```

改为：

```python
_INT_COLS = ("datetime", "volume")
```

第 153-165 行 `_KLINE_INSERT` 整块改为：

```python
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
```

第 180-186 行 executemany 的元组生成，删掉 `r["ticket_index"],`：

```python
            await conn.executemany(_KLINE_INSERT, [
                (r["stock_code"], r["period"], r["datetime"], r["open"], r["high"],
                 r["low"], r["close"], r["volume"], r["amount"],
                 r["ma66"], r["boll_upper"], r["boll_mid"], r["boll_lower"],
                 r["macd_diff"], r["macd_dea"], r["macd_bar"])
                for r in records
            ])
```

CLI 段（第 231-236 行）整块删除——基准只为 ticket_index 服务，现已无用：

```python
    # R1-M2：总是先从 dir 里建 1m 基准（不依赖 DB），与 --period 过滤解耦。
    baseline: Optional[list[int]] = None
    one_min_files = [f for f in all_files if _discover_period(f) == "1m"]
    if one_min_files:
        base_df = compute_indicators(clean(parse_csv(one_min_files[0])))
        baseline = list(base_df["datetime"])
```

第 240-243 行的 `--period` 过滤块：

```python
    write_files = all_files
    if args.period:
        write_files = [f for f in all_files if _discover_period(f) == args.period]
        if args.period != "1m" and baseline is None:
            ap.error(f"--period {args.period} 需要同目录存在 1m CSV 以建 ticket_index 基准")
    write_files = sorted(write_files,
                         key=lambda f: 0 if _discover_period(f) == "1m" else 1)
```

改为（去掉 baseline 校验与 1m 优先排序——排序也只为基准来源行先入库）：

```python
    write_files = all_files
    if args.period:
        write_files = [f for f in all_files if _discover_period(f) == args.period]
    write_files = sorted(write_files)
```

第 251 行删除：

```python
        df2["ticket_index"] = compute_ticket_index(df2, period, baseline)
```

最后同步两处头注释。第 4 行：

```python
# 双层（D1）：纯函数层（parse/clean/compute_indicators/compute_ticket_index/to_kline_records）
```

改为：

```python
# 双层（D1）：纯函数层（parse/clean/compute_indicators/to_kline_records）
```

第 12 行：

```python
# - D6 ticket_index：1m 升序 0,1,2…；其它周期 searchsorted 到 1m 基准
```

改为：

```python
# - D6 ticket_index：已停止写入（QMT spec D3/R12-F1）。PG 列保留（m01 禁不可逆迁移），
#   新行该列 NULL；无下游消费者（B2 _KLINE_SELECT_COLS 不含、iOS 零引用）。
```

第 133 行 `to_kline_records` 的 docstring 首行：

```python
    """把带指标 + ticket_index 的 df 转成入库 record dict 列表。
```

改为：

```python
    """把带指标的 df 转成入库 record dict 列表。
```

- [ ] **Step 4: 清理 Task 自身造成的孤儿 import**

改动删掉了 `compute_ticket_index`，检查 `numpy`（`np`）和 `Sequence` 是否还有别的使用者：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && grep -n "np\.\|Sequence" import_csv.py
```

若 `np.` 仍有命中（`_int_or_none`/`_float_or_none` 里的 `np.isnan`）则保留 `import numpy as np`；若 `Sequence` 已零命中，从 `typing` import 里删掉它。**按 grep 实际结果决定，不要凭记忆删**。

- [ ] **Step 5: 跑测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_import_csv.py -q
```

期望：全 passed（含 4 个新停写断言）。

- [ ] **Step 6: 全套件 + 全仓 grep 双验**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/ -q
cd "/Users/maziming/Coding/Prj_Kline trainer"
# ticket_index 只应出现在 schema.sql（保留列）+ import_csv.py 头注释 + test_schema/test_import_csv 断言里，
# 绝不应再出现在任何 INSERT/计算路径
grep -rn "ticket_index" --include='*.py' --include='*.sql' backend/ | grep -v "^backend/tests/"
```

期望：pytest `186 passed`（185 − 3 删除的 ticket_index 测 + 4 新增）。grep 输出**只有** `backend/sql/schema.sql` 的列定义行 + `backend/import_csv.py` 的两行注释；**不得**出现任何 `INSERT`/`compute_`/`_INT_COLS` 行。

- [ ] **Step 7: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add backend/import_csv.py backend/tests/test_import_csv.py
git commit -m "$(cat <<'EOF'
Plan2a Task3: ticket_index 停止写入（PG 列保留）

D3/R12-F1：删 compute_ticket_index + INSERT 去该列 + CLI 去 1m 基准逻辑。
列不动（m01 禁 Wave1+ 不可逆迁移），新行 NULL；无下游消费者。
加占位符计数回归测，防"删列名忘删占位符"错位。
EOF
)"
```

---

## PR 2a 收尾

- [ ] **Step 1: 三绿验证**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/ -q
cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift build 2>&1 | tail -5
cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test 2>&1 | tail -10
```

期望：pytest `186 passed / 0 failed / 0 skipped`；swift build 无 error；swift test 全绿。

- [ ] **Step 2: 出非-coder 验收清单**

写 `docs/acceptance/2026-07-18-qmt-plan2a-ddl-contract.md`，动作/预期/通过-不通过三列中文表格，**禁用** `.claude/workflow-rules.json` 里列的模糊措辞。至少覆盖：migration forward/rollback 成对存在、rollback 有丢精度标注、schema.sql OHLC 为 DOUBLE、`ticket_index` 列仍在、`CONTRACT_VERSION` 为 `"1.12"`、m01 矩阵两 cell 已更新。

- [ ] **Step 3: codex 整体评审（branch-diff）**

用 `codex:adversarial-review`，`--scope branch-diff --base main`。收敛到 approve 或（≥5 轮/自相矛盾时）按守则 pause 问用户。

- [ ] **Step 4: 开 PR**

PR 标题/正文中文。**正文必须点名引用** `docs/governance/m01-schema-versioning-contract.md` §Bump 策略 A（m01 硬性要求）。说明 `CONTRACT_VERSION` 实际是 1.11→1.12（非 spec 写的 1.8→1.9）及原因。CODEOWNERS approve 必需（trust-boundary）。

---

# PR 2b：B2 生产装配重接

分支：`qmt-plan2b-b2-reconnect`（从 **PR 2a 合并后的 main** 切——依赖 `stock_coverage` 表存在）。

---

## Task 4: 修 D9 per-day 门的首日边界误判（Plan 1 遗留 bug）

**为什么必须先做**：`select_period_window` 取"起点前 `min(pivot, cap)` 根"，生产 `cap=150` **不是**每日根数 80/16/4 的整数倍 → 窗口首日必然被切成部分根（3m 70/80、15m 6/16、60m 2/4）。而 `per_day_intraday_complete` 要求 span 内**每一天**根数精确 == golden，把这个**切片边界**当成**数据洞**拒掉 → 完美数据也 0 候选通过。

**修法依据（这是安全的关键）**：B1 保证 PG 永无 partial 盘中日（D9(a)/R13-F2「全或无」——某日要么完整 80/16/4、要么整日 drop）。所以窗口内 `0 < count < need` **只可能**是 before_cap 切片边界；**真洞在 PG 里恒表现为整日缺席（`count == 0`）**。故首日 `d0` 只验"在不在"、其余日仍精确验根数，**不放过任何真洞**。

**为什么 Plan 1 没抓到**：该文件全部 D9 测试用的 `before_caps` 都是对齐值（`cap=2` 配 2 根/日、或 `cap=0`），生产 cap 从未被测过——典型 vacuous 覆盖（[[feedback_internal_review_misses_bad_data]]）。本 Task 补的就是这条缺失的测。

**Files:**
- Modify: `backend/generate_training_sets.py:164-181`（`per_day_intraday_complete`）
- Modify: `backend/tests/test_generate_training_sets.py`（末尾追加 4 测）

**Interfaces:**
- Consumes: 无（改的是 Plan 1 已有纯函数，签名不变）
- Produces: `per_day_intraday_complete(windows, trading_dates, after_end, expected=None) -> bool` 语义变更——span 首日只验存在性。Task 5/6 依赖它在生产 cap 下能通过。

- [ ] **Step 1: 写失败测试（生产 cap + 完美数据必须过门）**

在 `backend/tests/test_generate_training_sets.py` 末尾追加。注意本文件已有 `_mid` / `_weekday_trading_dates` / `_n_month_boundaries` / `_intraday_bars_per_day` 等 helper（第 206 行起），下面复用它们，只新增一个"按真实每日根数铺盘中"的 helper：

```python
# ===== Plan 2b Task 4：D9 门首日边界修复（Plan 1 遗留 bug 的回归锁）=====
#
# 实测过的失败现象（修复前）：46 个月历史 + 每交易日精确 80/16/4 根 + 零 drop 的
# **完美** fixture 下，8 个 dense 候选全被 D9 拒 → build_training_windows 抛
# GenerateSkipException → 产 0 训练组。根因 = 生产 before_cap(150) 不是每日根数
# (80/16/4) 的整数倍 → 窗口首日被切成部分根 → 门把「切片边界」当「数据洞」。

_GOLDEN_PER_DAY = {"3m": 80, "15m": 16, "60m": 4}


def _golden_intraday(days, per_day: int, *, skip=None, short=None) -> pd.DataFrame:
    """按 golden 每日根数铺盘中 bar（09:33 起每 3 分钟一根，仅作刻度）。
    skip=某日整日缺席（模拟 B1 drop）；short={日: n} 令某日只有 n 根（模拟 PG 里的
    partial 日——B1 不变量下不该存在，用来证明门仍会抓）。"""
    rows = []
    for d in days:
        if skip and d in skip:
            continue
        n = (short or {}).get(d, per_day)
        base = dt.datetime(d.year, d.month, d.day, 9, 33, 0, tzinfo=SH)
        rows += [{"datetime": int((base + dt.timedelta(minutes=3 * i)).timestamp()),
                  "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0,
                  "volume": 1, "amount": 1.0} for i in range(n)]
    return pd.DataFrame(rows)


def _production_cap_windows(days, *, skip=None, short=None):
    """用**生产** PERIOD_BEFORE_CAP 切出的盘中窗口（首日必然是部分根——正是本 Task 的靶心）。"""
    from generate_training_sets import PERIOD_BEFORE_CAP
    start = _mid(days[len(days) // 2].year, days[len(days) // 2].month,
                 days[len(days) // 2].day)
    after_end = int(dt.datetime(days[-1].year, days[-1].month, days[-1].day,
                                23, 59, 59, tzinfo=SH).timestamp())
    wins = {}
    for p, n in _GOLDEN_PER_DAY.items():
        bars = _golden_intraday(days, n, skip=skip, short=short)
        wins[p] = select_period_window(bars, start, PERIOD_BEFORE_CAP[p], after_end, p)
    return wins, after_end


def test_per_day_gate_passes_under_production_before_caps():
    """靶心：生产 cap(150) + 完美数据（每日精确 80/16/4、零 drop）必须过门。
    修复前此测必挂（首日 3m 只有 70 根被判洞）。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    wins, ae = _production_cap_windows(days)
    assert per_day_intraday_complete(wins, days, ae) is True


def test_per_day_gate_still_catches_interior_missing_day():
    """不得放松真洞：窗口内某交易日**整日缺席**（B1 drop 的表现）仍必须被拒。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    hole = days[len(days) // 2 + 5]        # 落在 forward 窗口内部
    wins, ae = _production_cap_windows(days, skip={hole})
    assert per_day_intraday_complete(wins, days, ae) is False


def test_per_day_gate_still_catches_interior_short_day():
    """只豁免首日：窗口**内部**某日根数不足（非首日）仍必须被拒——
    证明修复没有把「部分日一律放行」。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    bad = days[len(days) // 2 + 5]
    wins, ae = _production_cap_windows(days, short={bad: 79})
    assert per_day_intraday_complete(wins, days, ae) is False


def test_build_training_windows_succeeds_under_production_config():
    """端到端：生产 PERIOD_BEFORE_CAP + 完美数据 → 生产入口必须**选得出**起点。
    这条就是「Plan 2 能不能出货」的最小可执行证据。"""
    from generate_training_sets import PERIOD_BEFORE_CAP
    from qmt_resample import period_boundaries
    days = _weekday_range(dt.date(2022, 1, 3), dt.date(2025, 12, 31))
    daily = pd.DataFrame([{"datetime": _mid(d.year, d.month, d.day), "open": 1.0,
                           "high": 1.0, "low": 1.0, "close": 1.0, "volume": 1,
                           "amount": 1.0} for d in days])
    first_m, first_w = {}, {}
    for d in days:
        first_m.setdefault((d.year, d.month), d)
        first_w.setdefault(d.isocalendar()[:2], d)
    def _cal(sel):
        return pd.DataFrame([{"datetime": _mid(d.year, d.month, d.day), "open": 1.0,
                              "high": 1.0, "low": 1.0, "close": 1.0, "volume": 1,
                              "amount": 1.0} for d in sorted(sel)])
    pb = {"daily": daily, "monthly": _cal(first_m.values()), "weekly": _cal(first_w.values())}
    for p, n in _GOLDEN_PER_DAY.items():
        pb[p] = _golden_intraday(days, n)
    mb = period_boundaries(daily, "monthly")
    start, windows = build_training_windows(
        pb, mb, random.Random(0), dense_dates=set(days), trading_dates=days,
        before_caps=PERIOD_BEFORE_CAP)
    assert start in [int(b) for b in mb]
    assert not windows["3m"].empty
```

同时在文件的 helper 区（`_weekday_trading_dates` 定义之后）追加一个返回**有序 list** 的版本——上面几个测要按顺序取日子，而既有 `_weekday_trading_dates` 返回 `set`：

```python
def _weekday_range(d0: dt.date, d1: dt.date) -> list:
    """[d0,d1] 内工作日升序 list（既有 _weekday_trading_dates 返回 set，取不了第 k 天）。"""
    return sorted(_weekday_trading_dates(d0, d1))
```

- [ ] **Step 2: 跑测试确认失败（且失败原因正确）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_generate_training_sets.py -q -k "production_before_caps or production_config" --tb=short
```

期望：**2 FAIL**——`test_per_day_gate_passes_under_production_before_caps` 断言 `False is True`；`test_build_training_windows_succeeds_under_production_config` 抛 `GenerateSkipException: bounded retry 穷尽`。这两条失败就是 bug 本体的复现。

另外两条（`interior_missing_day` / `interior_short_day`）此时应已 **PASS**（修复前的门更严）——它们是防"修过头"的护栏。

- [ ] **Step 3: 改 `per_day_intraday_complete`**

`backend/generate_training_sets.py` 第 178-180 行：

```python
        counts = dates.value_counts().to_dict()
        if not all(counts.get(d, 0) == need for d in span):
            return False
```

改为：

```python
        counts = dates.value_counts().to_dict()
        # d0 = before_cap 切片的边界日。`select_period_window` 取「起点前 min(pivot, cap) 根」，
        # 生产 cap(150) 不是每日根数(80/16/4)的整数倍 → 首日必然只切到部分根（3m 70/80）。
        # 这是**切片产物、不是数据洞**：B1 保证 PG 永无 partial 盘中日（D9(a)/R13-F2「全或无」），
        # 真洞在 PG 里恒表现为整日缺席（count==0）→ 仍会被下面的精确门抓住。
        # 故首日只验存在性（d0 由 dates.min() 得出，必然存在），其余日仍精确验根数。
        # 不豁免的话：生产 cap 下**完美数据也 0 候选通过**（Plan 1 的 D9 测全用 cap=2/cap=0
        # 等对齐值，生产 cap 从未被测过 → 该 bug 未被任何测试覆盖）。
        if not all(counts.get(d, 0) == need for d in span if d != d0):
            return False
```

并同步更新该函数 docstring，把"每个交易日桶数精确 == 应有数"改为：

```python
    """D9 per-day 硬门（codex PF1-R2/PF1-R4-F2/PF1-R6-F1 + Plan 2b 首日边界修正）：
    **每个盘中周期**在 `[该周期首选中日, trading_date(after_end)]` 内、每个交易日
    （∈ trading_dates）桶数精确 == 应有数（3m=80/15m=16/60m=4）；**唯独首日 d0 豁免**
    ——它是 before_cap 切片边界、非数据洞（依据 B1「全或无」不变量，见函数体注释）。
    **跨度终点用 `after_end`、非 `dates.max()`**——否则 after_end 附近盘中全缺的
    尾日会落在 max 之外、漏检（高周期 bar 覆盖了无盘中回放的日期）。任一周期任一日不符 → False。"""
```

- [ ] **Step 4: 跑测试确认四条全通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_generate_training_sets.py -q
```

期望：全 passed，含新增 4 条。**特别确认既有的 3 条 D9 测（`test_per_day_intraday_complete_all_periods_hardgate` / `_catches_short_60m_before_context` / `_catches_missing_tail_day`）仍绿**——它们是"没修过头"的证据。

若 `test_per_day_intraday_complete_catches_short_60m_before_context` 挂了：读它，确认它测的是不是恰好就是首日。若是，说明该测原本锁的正是这个错误行为，需**改写**为测内部日（并在 commit message 里说明改了什么、为什么）；**不要直接删**。

- [ ] **Step 5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add backend/generate_training_sets.py backend/tests/test_generate_training_sets.py
git commit -m "$(cat <<'EOF'
Plan2b Task4: 修 D9 per-day 门把 before_cap 切片边界误判为数据洞

Plan 1 遗留 bug：生产 cap(150) 不是每日根数(80/16/4)的整数倍 → 窗口首日必被切成
部分根 → 门判洞 → **完美数据也产 0 训练组**（46 月历史/每日精确 80/16/4/零 drop
实测：8 个候选全拒）。Plan 1 的 D9 测全用 cap=2/cap=0 等对齐值，生产 cap 从未被测。

修法：首日 d0 只验存在性，其余日仍精确验根数。安全依据 = B1「全或无」不变量
（PG 永无 partial 盘中日，真洞恒为整日缺席 count==0）→ 不放过任何真洞。
补 4 测：生产 cap 必过门 + 端到端必选得出起点 + 内部整日缺席/内部根数不足仍被拒。
EOF
)"
```

---

## Task 5: generate_one_training_set 重接 build_training_windows

**核心 Task**：解除 `assemble_training_set` 的 `NotImplementedError` 停用（整个函数删除，而非改造——旧的"随机选起点"语义本身就是被否掉的不安全路径）。

**Files:**
- Modify: `backend/generate_training_sets.py:137-161`（`build_training_windows` 加 `exclude_starts`）、`:286-295`（删 `assemble_training_set`，换成 `assemble_from_windows`）、`:339-357`（重接 `generate_one_training_set`）、`:407-413`（CLI 去 `NotImplementedError` 捕获）
- Modify: `backend/app/scheduler.py:153-169`（删孤儿捕获块）
- Modify: `backend/tests/test_generate_training_sets.py:18`（import）、`:196-203`（删 fail-closed 测）

**Interfaces:**
- Consumes: Task 1 的 `stock_coverage` 表五列；Plan 1 已有的 `build_training_windows(period_bars, month_boundaries, rng, *, dense_dates, trading_dates, before_caps, months, intraday_expected, before_min, max_retries) -> (start_datetime, windows)`；`compute_after_end(month_boundaries, start_idx, months) -> int`；`qmt_resample.period_boundaries(df_daily, rule) -> list[int]`；`qmt_normalize.trading_date(epoch) -> date`
- Produces: `assemble_from_windows(output_dir, *, stock_code, stock_name, start_datetime, end_datetime, windows) -> GeneratedTrainingSet`（纯函数）；`build_training_windows` **与** `select_valid_window` 各新增 keyword-only 参数 `exclude_starts: frozenset[int] = frozenset()`（前者透传给后者，后者在切 `max_retries` **之前**过滤）；`_fetch_dense_coverage(conn, stock_code) -> tuple[date|None, date|None, set[date]]`（坏行抛 `GenerateSkipException`）；`_fetch_existing_starts(conn, stock_code) -> set[int]`；`_register_training_set(conn, gts) -> Optional[int]`（唯一冲突返回 `None`，**非**抛异常）。Task 6 的集成测依赖这四个符号。

- [ ] **Step 1: 写 `assemble_from_windows` 的失败测试**

在 `backend/tests/test_generate_training_sets.py` 末尾追加：

```python
# ===== Plan 2b Task 5：assemble_from_windows（取代已删的 assemble_training_set）=====

def test_assemble_from_windows_produces_zip_and_matching_hash(tmp_path):
    """纯装配：windows → assign_global_indices → SQLite → zip → CRC32。
    content_hash 必须等于 zip 文件字节的 CRC32（D3）。"""
    from generate_training_sets import assemble_from_windows
    windows = {p: _bars(p, 40) for p in PERIODS}
    start = int(windows["monthly"]["datetime"].iloc[10])
    end = int(windows["monthly"]["datetime"].iloc[-1])
    gts = assemble_from_windows(tmp_path, stock_code="000001.SZ", stock_name="平安银行",
                                start_datetime=start, end_datetime=end, windows=windows)
    assert gts.path.exists() and gts.path.suffix == ".zip"
    assert gts.content_hash == crc32_hex(gts.path.read_bytes())
    assert gts.stock_code == "000001.SZ" and gts.start_datetime == start
    assert gts.end_datetime == end and gts.schema_version == SCHEMA_VERSION


def test_assemble_from_windows_filename_is_code_underscore_start(tmp_path):
    """文件名契约 {stock_code}_{start_datetime}（沿用 PR #74 既有约定，B3 下载按此路径）。"""
    from generate_training_sets import assemble_from_windows
    windows = {p: _bars(p, 40) for p in PERIODS}
    start = int(windows["monthly"]["datetime"].iloc[10])
    gts = assemble_from_windows(tmp_path, stock_code="600519", stock_name="X",
                                start_datetime=start, end_datetime=start + 100,
                                windows=windows)
    assert gts.path.name == f"600519_{start}.zip"


def test_assemble_from_windows_writes_all_periods_into_sqlite(tmp_path):
    """六周期都要进训练组 SQLite；漏一个 = App 少一个周期可看。"""
    from generate_training_sets import assemble_from_windows
    import zipfile as _zf
    windows = {p: _bars(p, 40) for p in PERIODS}
    start = int(windows["monthly"]["datetime"].iloc[10])
    gts = assemble_from_windows(tmp_path, stock_code="X", stock_name="X",
                                start_datetime=start, end_datetime=start + 100,
                                windows=windows)
    with _zf.ZipFile(gts.path) as z:
        z.extractall(tmp_path / "x")
    conn = sqlite3.connect(str(tmp_path / "x" / f"X_{start}.db"))
    try:
        got = {r[0] for r in conn.execute("SELECT DISTINCT period FROM klines")}
    finally:
        conn.close()
    assert got == set(PERIODS)
```

`_bars` 是本文件第 31 行已有的 helper，签名 `_bars(period: str, n: int, *, base: int = _BASE, step: int = 0) -> pd.DataFrame`（`step=0` 时按 `_STEP[period]` 取该周期步长），故 `_bars(p, 40)` 可直接用。它产出的行含 `period/datetime/open/high/low/close/volume/amount`；指标列缺席时 `build_training_set_sqlite` 走 `row.get(...) -> None` 写 NULL，是合法的（训练组 SQLite 指标列可空）。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_generate_training_sets.py -q -k assemble_from_windows
```

期望：FAIL，`ImportError: cannot import name 'assemble_from_windows'`。

- [ ] **Step 3: 删 `assemble_training_set`，加 `assemble_from_windows`**

`backend/generate_training_sets.py` 第 286-295 行（整个 `assemble_training_set` 函数及其 docstring）替换为：

```python
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
    db_path = output_dir / f"{fname}.db"
    zip_path = output_dir / f"{fname}.zip"
    build_training_set_sqlite(db_path, stock_code=stock_code, stock_name=stock_name,
                              start_datetime=start_datetime, end_datetime=end_datetime,
                              windows=windows)
    content_hash = zip_and_hash(db_path, zip_path)
    return GeneratedTrainingSet(path=zip_path, content_hash=content_hash,
                                stock_code=stock_code, stock_name=stock_name,
                                start_datetime=start_datetime, end_datetime=end_datetime,
                                schema_version=SCHEMA_VERSION)
```

同时删掉 `backend/tests/test_generate_training_sets.py` 第 18 行 import 里的 `assemble_training_set,`，以及第 196-203 行的 `test_assemble_training_set_fails_closed` 整个函数（函数已删，fail-closed 守卫的目的由"路径彻底移除"达成）。

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_generate_training_sets.py -q
```

期望：全 passed。

- [ ] **Step 5: 写 `exclude_starts` 的失败测试**

`uq_stock_start UNIQUE(stock_code, start_datetime)` 意味着已登记过的起点不能再用。把它做成**候选资格的一部分**（而不是事后撞了再重来），复用既有 bounded retry。追加到 `backend/tests/test_generate_training_sets.py`：

```python
# ===== Plan 2b Task 5：exclude_starts（uq_stock_start 变成候选资格）=====

def _production_fixture():
    """生产配置下可用的完整 fixture（复用 Task 4 的 _weekday_range / _golden_intraday）：
    4 年工作日、每交易日精确 80/16/4 根盘中、日/周/月标组内首交易日午夜、全程 dense。
    返回 (period_bars, month_boundaries, days)。"""
    from qmt_resample import period_boundaries
    days = _weekday_range(dt.date(2022, 1, 3), dt.date(2025, 12, 31))

    def _cal(sel):
        return pd.DataFrame([{"datetime": _mid(d.year, d.month, d.day), "open": 1.0,
                              "high": 1.0, "low": 1.0, "close": 1.0, "volume": 1,
                              "amount": 1.0} for d in sorted(sel)])

    first_m, first_w = {}, {}
    for d in days:
        first_m.setdefault((d.year, d.month), d)
        first_w.setdefault(d.isocalendar()[:2], d)
    pb = {"daily": _cal(days), "monthly": _cal(first_m.values()),
          "weekly": _cal(first_w.values())}
    for p, n in _GOLDEN_PER_DAY.items():
        pb[p] = _golden_intraday(days, n)
    return pb, period_boundaries(pb["daily"], "monthly"), days


def test_build_training_windows_skips_excluded_start():
    """uq_stock_start：已登记的起点不得再被选中，且不能因此误杀该股——
    应换下一个候选并成功（而非整股失败）。"""
    from generate_training_sets import PERIOD_BEFORE_CAP
    pb, mb, days = _production_fixture()
    kw = dict(dense_dates=set(days), trading_dates=days, before_caps=PERIOD_BEFORE_CAP)
    s1, _ = build_training_windows(pb, mb, random.Random(0), **kw)
    s2, w2 = build_training_windows(pb, mb, random.Random(0),
                                    exclude_starts=frozenset({s1}), **kw)
    assert s2 != s1
    assert not w2["3m"].empty


def test_build_training_windows_all_candidates_excluded_raises():
    """全部候选都已登记 → 该股确实无可用起点 → GenerateSkipException（非静默产坏组）。
    注意 max_retries 默认 8，故排除集须覆盖所有月边界才能确保穷尽。"""
    from generate_training_sets import PERIOD_BEFORE_CAP
    pb, mb, days = _production_fixture()
    with pytest.raises(GenerateSkipException):
        build_training_windows(pb, mb, random.Random(0), dense_dates=set(days),
                               trading_dates=days, before_caps=PERIOD_BEFORE_CAP,
                               exclude_starts=frozenset(int(b) for b in mb))
```

再追加 codex 点名要求的重试预算回归测（**这条是 finding 的靶心**，与重 DataFrame 解耦、直接测 `select_valid_window`）：

```python
def test_select_valid_window_excludes_before_retry_budget():
    """codex PF2-R1-F2：前 max_retries(8) 个候选全已登记 → 仍须选中之后的有效候选。

    排除必须发生在 `cands[:max_retries]` 切片**之前**。若让被排除者进循环再拒（我最初的
    设计），每个都会吃掉一个重试名额 → 股票累积训练组后、shuffle 恰好把已登记的排前面，
    就会**明明还有可用起点却整股被跳过**，且非确定性（B4 库存会莫名欠产）。
    直接注入 try_assemble，不建重 fixture。"""
    bounds = _n_month_boundaries(60)                    # n=60 → 候选 idx 30..51 共 22 个
    days = _weekday_range(dt.date(2020, 1, 1), dt.date(2025, 12, 31))
    dense, trading = set(days), days
    # 用同一 seed 先取 shuffle 顺序，令断言确定（eligible_start_indices 内部 rng.shuffle）
    order = eligible_start_indices(bounds, random.Random(1), dense_dates=dense,
                                   trading_dates=trading)
    assert len(order) > 9, "fixture 须提供多于 max_retries 的候选，否则本测 vacuous"
    excluded = frozenset(int(bounds[i]) for i in order[:9])   # 排除前 9 个（> max_retries=8）
    survivor = int(bounds[order[9]])
    start, _ = select_valid_window(bounds, random.Random(1), dense_dates=dense,
                                   trading_dates=trading,
                                   try_assemble=lambda s: {"ok": True},
                                   exclude_starts=excluded)
    assert start == survivor, "被排除的候选吃掉了重试名额（修复前必挂）"
```

`_weekday_range` / `_golden_intraday` / `_GOLDEN_PER_DAY` / `_mid` / `_n_month_boundaries` 均来自 Task 4 与本文件既有 helper 区，不要重复定义。

- [ ] **Step 6: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_generate_training_sets.py -q -k exclude
```

期望：3 条全 FAIL，报 `TypeError: ... got an unexpected keyword argument 'exclude_starts'`（`select_valid_window` 与 `build_training_windows` 各命中）。

- [ ] **Step 7: 加 `exclude_starts`——在切 `max_retries` 之前过滤**

改**两个**函数。先是 `select_valid_window`（第 119-131 行），签名加 keyword-only 参数：

```python
def select_valid_window(month_boundaries, rng, *, dense_dates, trading_dates,
                        try_assemble, max_retries: int = 8, months: int = 8,
                        exclude_starts=frozenset()):
```

docstring 末尾追加：

```python
    `exclude_starts`（Plan 2b）：已登记的 start_datetime（uq_stock_start）。**必须在切
    `cands[:max_retries]` 之前过滤**——若放进循环再拒，每个被排除者会吃掉一个重试名额，
    股票累积训练组后 shuffle 把已登记的排前面，就会明明还有可用起点却整股被跳过、
    且非确定性（B4 库存莫名欠产）。codex PF2-R1-F2。
```

函数体在取到 `cands` 之后、进循环之前插入过滤：

```python
    cands = eligible_start_indices(month_boundaries, rng, dense_dates=dense_dates,
                                   trading_dates=trading_dates, months=months)
    if exclude_starts:
        cands = [i for i in cands if int(month_boundaries[i]) not in exclude_starts]
    for idx in cands[:max_retries]:
```

然后是 `build_training_windows`（第 137-161 行），签名加同名参数：

```python
def build_training_windows(period_bars, month_boundaries, rng, *, dense_dates, trading_dates,
                           before_caps, months: int = 8, intraday_expected=None,
                           before_min: int = 30, max_retries: int = 8,
                           exclude_starts=frozenset()):
```

docstring 末尾追加一句：

```python
    `exclude_starts` 透传给 `select_valid_window`（uq_stock_start → **候选资格**，
    在重试预算之前过滤；**不要**改成在 `_try` 里拒，那会吃掉重试名额，见该函数 docstring）。
```

并在末尾的 `return select_valid_window(...)` 调用里透传：

```python
    return select_valid_window(month_boundaries, rng, dense_dates=dense_dates, trading_dates=trading_dates,
                               try_assemble=_try, max_retries=max_retries, months=months,
                               exclude_starts=exclude_starts)
```

**`_try` 函数体不动**——排除逻辑不放这里（这正是 codex PF2-R1-F2 否掉的写法）。

- [ ] **Step 8: 跑测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_generate_training_sets.py -q
```

期望：全 passed（含 2 个 exclude 测）。

- [ ] **Step 9: Commit 纯函数层**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add backend/generate_training_sets.py backend/tests/test_generate_training_sets.py
git commit -m "$(cat <<'EOF'
Plan2b Task5a: 删 assemble_training_set，加 assemble_from_windows + exclude_starts

exclude_starts 在切 max_retries **之前**过滤（codex PF2-R1-F2）——放进循环再拒会吃掉
重试名额，股票累积训练组后会明明有可用起点却整股被跳过、且非确定性。

旧"随机选起点"路径整体移除（非改造）——它绕过 D2 dense 门与 D9 per-day 硬门。
新纯装配函数只序列化已门控的 windows，不选起点。
build_training_windows 加 exclude_starts，把 uq_stock_start 变成候选资格。
EOF
)"
```

- [ ] **Step 9a: 把 `_register_training_set` 改成原子处理唯一冲突**

`backend/generate_training_sets.py` 第 325-331 行整个函数替换为：

```python
async def _register_training_set(conn, gts: GeneratedTrainingSet) -> Optional[int]:
    """登记 training_sets 行（status 默认 'unsent'）。返回新行 id；
    **起点已被并发 sweep 抢先登记 → 返回 None**（codex PF2-R2-F2）。

    用 `ON CONFLICT (stock_code, start_datetime) DO NOTHING RETURNING id` 原子处理
    `uq_stock_start` 的 TOCTOU：否则并发 sweep 在预检与 INSERT 之间插入同一起点时，
    asyncpg 抛 UniqueViolationError → **穿出 generate_batch**（它只捕
    GenerateSkipException）→ 中止整轮 sweep，而不是干净跳过这一只股。"""
    return await conn.fetchval(
        "INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, "
        "schema_version, file_path, content_hash) VALUES ($1,$2,$3,$4,$5,$6,$7) "
        "ON CONFLICT (stock_code, start_datetime) DO NOTHING RETURNING id",
        gts.stock_code, gts.stock_name, gts.start_datetime, gts.end_datetime,
        gts.schema_version, str(gts.path), gts.content_hash)
```

- [ ] **Step 10: 重接 PG 壳——加两个读取函数 + 改写 generate_one_training_set**

`backend/generate_training_sets.py`，在 `_exists_start`（第 316 行）之前插入两个新读取函数：

```python
async def _fetch_dense_coverage(conn, stock_code: str):
    """D11：读 stock_coverage 权威 dense 1m 覆盖（**不从 klines 反推**——反推会在
    边角/retry/周期变更下与 B1 的决定漂移、且失败难诊断，codex R17-F1）。
    返回 (start_date, end_date, dropped_dates_set)；无该股行 → (None, None, set())。

    **坏行一律降级成 GenerateSkipException**（codex PF2-R2-F1）：schema 有 CHECK 兜底，
    但历史行 / 手工修补 / Plan 3 writer 半成品仍可能带非法内容（如 `["nope"]` 能过
    `jsonb_typeof` 数组检查却不是 ISO 日期）。裸 `json.loads` / `date.fromisoformat`
    抛的 JSONDecodeError·ValueError·TypeError **不被 generate_batch 捕获**（它只捕
    GenerateSkipException）→ **中止整轮 sweep** 而非跳过一只股，且在 B4 常驻进程里
    会一路冒泡。故在此转成带原因的 skip。"""
    row = await conn.fetchrow(
        "SELECT dense_1m_start_date, dense_1m_end_date, dropped_1m_dates "
        "FROM stock_coverage WHERE stock_code=$1", stock_code)
    if row is None:
        return None, None, set()
    start_date, end_date = row["dense_1m_start_date"], row["dense_1m_end_date"]
    if start_date is None or end_date is None:
        raise GenerateSkipException(
            f"{stock_code}: stock_coverage 覆盖带端点为 NULL（坏行）")
    if start_date > end_date:
        raise GenerateSkipException(
            f"{stock_code}: stock_coverage 覆盖带反向（{start_date} > {end_date}）")
    raw = row["dropped_1m_dates"]
    if raw is None:
        raw = "[]"
    try:
        # asyncpg 默认把 jsonb 当 str 返回；若调用方装了 json codec 则已是 list，两者都接
        parsed = json.loads(raw) if isinstance(raw, str) else raw
        if not isinstance(parsed, list):
            raise ValueError(f"非数组（{type(parsed).__name__}）")
        dropped = {_dt.date.fromisoformat(s) for s in parsed}
    except (ValueError, TypeError) as exc:      # JSONDecodeError ⊂ ValueError
        raise GenerateSkipException(
            f"{stock_code}: stock_coverage.dropped_1m_dates 非法（{exc}）") from exc
    return start_date, end_date, dropped


async def _fetch_existing_starts(conn, stock_code: str) -> set:
    """uq_stock_start：该股已登记的所有 start_datetime，作 build_training_windows
    的 exclude_starts（把唯一性变成候选资格，而非事后撞库重来）。"""
    rows = await conn.fetch(
        "SELECT start_datetime FROM training_sets WHERE stock_code=$1", stock_code)
    return {int(r["start_datetime"]) for r in rows}
```

文件顶部 import 区（第 22-30 行附近）补两个 import：

```python
import json
```

以及从 `qmt_resample` 引入月边界哨兵：

```python
from qmt_resample import period_boundaries
```

然后把第 339-357 行整个 `generate_one_training_set` 替换为：

```python
async def generate_one_training_set(conn, stock_code: str, output_dir: Path,
                                    rng: Optional[random.Random] = None,
                                    max_retries: int = 8) -> GeneratedTrainingSet:
    """D7 + Plan 2b 重接：取各周期 bars → 读 stock_coverage 权威 dense 覆盖 →
    走安全纯入口 build_training_windows（D2 dense 门 + D6 before/after + D9 per-day
    硬门 + bounded retry）→ 纯装配 → 登记。

    **不再经旧 assemble_training_set**（已删；它自带随机选起点、绕过全部门控）。
    月边界哨兵从**日线**求（period_boundaries），非从已发射的月 bar——后者不含当前
    partial 月的 open，会让最新完整月当不成第 8 前向月、白白少候选（codex R9-F1）。
    任一前置缺失（周期数据空 / 无覆盖 artifact）→ GenerateSkipException，fail-closed。"""
    rng = rng or random.Random()
    period_bars = {p: await _fetch_period_bars(conn, stock_code, p) for p in PERIODS}
    for p, bars in period_bars.items():
        if bars.empty:
            raise GenerateSkipException(f"{stock_code}: {p} 无 bars")

    start_date, end_date, dropped = await _fetch_dense_coverage(conn, stock_code)
    if start_date is None or end_date is None:
        raise GenerateSkipException(
            f"{stock_code}: stock_coverage 无覆盖 artifact（B1 未写入）→ 无法门控，跳过")

    daily = period_bars["daily"]
    trading_dates = sorted({trading_date(int(e)) for e in daily["datetime"]})
    dense_dates = {d for d in trading_dates if start_date <= d <= end_date} - dropped
    if not dense_dates:
        raise GenerateSkipException(f"{stock_code}: dense 覆盖为空")

    month_boundaries = period_boundaries(daily, "monthly")
    exclude = await _fetch_existing_starts(conn, stock_code)

    start_datetime, windows = build_training_windows(
        period_bars, month_boundaries, rng,
        dense_dates=dense_dates, trading_dates=trading_dates,
        before_caps=PERIOD_BEFORE_CAP, max_retries=max_retries,
        exclude_starts=frozenset(exclude))

    idx = month_boundaries.index(int(start_datetime))
    after_end = compute_after_end(month_boundaries, idx)

    gts = assemble_from_windows(output_dir, stock_code=stock_code,
                                stock_name=_stock_name_of(stock_code),
                                start_datetime=int(start_datetime),
                                end_datetime=int(after_end), windows=windows)
    def _discard():
        """R16-F2：任何不登记的出口都要删已建产物，否则留 orphan .zip 且重试不幂等。"""
        gts.path.unlink(missing_ok=True)
        gts.path.with_suffix(".db").unlink(missing_ok=True)

    # 纯优化：候选已按 exclude_starts 过滤，这条预检只为在常见情形下省掉一次白建 zip。
    # **真正的原子保证在 _register_training_set 的 ON CONFLICT**（TOCTOU 由它兜）。
    if await _exists_start(conn, stock_code, gts.start_datetime):
        _discard()
        raise GenerateSkipException(
            f"{stock_code}: start {gts.start_datetime} 已登记，跳过")
    try:
        row_id = await _register_training_set(conn, gts)
    except Exception:
        _discard()
        raise
    if row_id is None:
        # 并发 sweep 在预检之后抢先登记了同一起点 → 干净跳过（codex PF2-R2-F2）。
        # 走 GenerateSkipException 而非让 UniqueViolationError 冒泡中止整轮 sweep。
        _discard()
        raise GenerateSkipException(
            f"{stock_code}: start {gts.start_datetime} 被并发 sweep 抢先登记，跳过")
    gts.path.with_suffix(".db").unlink(missing_ok=True)   # 仅保留 .zip（登记的产物）
    return gts
```

- [ ] **Step 11a: `generate_batch` 打印首条 skip 原因（诚实义务 1）**

本 plan 合并后 `stock_coverage` 仍是空表 → 每股都 skip → 运维只会看到「仅生成 0/100（skip 400 次）」，**看不出是"缺前置数据"还是"代码坏了"**。这正是 codex PF2-R1-F1 指的"测试全绿、生产静默跳过"陷阱。加一条首因输出（只记**第一条**，避免 400 行刷屏）。

`backend/generate_training_sets.py` 的 `generate_batch`（第 360-380 行），把：

```python
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
```

改为：

```python
    out: list = []
    skips = 0
    first_skip: Optional[str] = None       # 首条 skip 原因（诊断用；不逐条刷屏）
    max_skips = max(target_count * 4, 4)
    i = 0
    while len(out) < target_count and skips < max_skips:
        code = codes[i % len(codes)]
        i += 1
        try:
            out.append(await generate_one_training_set(conn, code, output_dir, rng))
        except GenerateSkipException as exc:
            skips += 1
            if first_skip is None:
                first_skip = f"{code}: {exc}"
    if len(out) < target_count:
        # 欠产必须可诊断：只报数字会让"stock_coverage 空表"（Plan 3 前的预期状态）
        # 与"真回归"长得一模一样。
        print(f"[B2] 警告：仅生成 {len(out)}/{target_count}（skip {skips} 次）"
              f"；首条 skip 原因 = {first_skip}")
    return out
```

对应回归测追加到 `backend/tests/test_b2_reconnect_integration.py`（Task 6 建的文件，本 Step 先只改生产代码，测试在 Task 6 一并写）。

- [ ] **Step 11: 删 CLI 与 scheduler 里已成孤儿的 NotImplementedError 捕获**

`backend/generate_training_sets.py` 第 407-413 行：

```python
        try:
            sets = await generate_batch(conn, args.count, out_dir, random.Random(args.seed))
        except NotImplementedError as exc:
            # codex whole-branch review high：assemble_training_set 已 fail-closed 停用；
            # CLI 人工调用，比裸 traceback 更清楚地报错并非零退出（而非静默/丢生成结果）。
            print(f"[B2] 错误：{exc}")
            return 1
```

改为：

```python
        sets = await generate_batch(conn, args.count, out_dir, random.Random(args.seed))
```

`backend/app/scheduler.py` 第 153-169 行：

```python
    async def _gen(n: int) -> int:
        from generate_training_sets import generate_batch
        async with pool.acquire() as conn:
            try:
                produced = await generate_batch(conn, n, out, rng)
            except NotImplementedError as exc:
                # ...（整段注释）
                logger.error(...)
                return 0
            return len(produced)
```

改为：

```python
    async def _gen(n: int) -> int:
        from generate_training_sets import generate_batch
        async with pool.acquire() as conn:
            # Plan 2b：B2 装配路径已重接 build_training_windows（stock_coverage 门控），
            # 原 NotImplementedError 捕获已成孤儿，随重接一并移除。
            produced = await generate_batch(conn, n, out, rng)
            return len(produced)
```

- [ ] **Step 12: 全套件确认零回归**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/ -q
```

期望：全 passed、0 skipped。若 `test_scheduler.py` 有针对该捕获块的测试挂了，**读它再决定**：断言"B4 遇 NotImplementedError 返 0"的测试已随停用解除而失效，应删除；其余不得改。

- [ ] **Step 13: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add backend/generate_training_sets.py backend/app/scheduler.py backend/tests/
git commit -m "$(cat <<'EOF'
Plan2b Task5b: generate_one_training_set 重接 build_training_windows

读 stock_coverage 权威 dense 覆盖（D11，非从 klines 反推）；月边界哨兵从日线求
（含 partial 月 open，不浪费最新完整月）；uq_stock_start 走 exclude_starts。
登记失败/并发冲突均清理 orphan .zip/.db。
CLI + scheduler 的 NotImplementedError 捕获已成孤儿，一并移除。
EOF
)"
```

---

## Task 6: 端到端集成测（假 asyncpg conn 上跑真实生产链）

守住本 plan 的核心断言：**真实 sweep 能产出 ≥1 registered training set**。用户已拍板用假 conn（不引入容器化 PG——本仓零真-PG 测试基建，且 CI 禁 skip 会让"没 docker 就 skip"直接红）。假的只有 conn；`generate_one_training_set` / `build_training_windows` / `assemble_from_windows` / SQLite / zip / CRC32 全是真实生产函数。

**Files:**
- Create: `backend/tests/test_b2_reconnect_integration.py`

**Interfaces:**
- Consumes: Task 5 的 `generate_one_training_set`、`generate_batch`、`_fetch_dense_coverage`、`_fetch_existing_starts`
- Produces: 无（叶子测试）

- [ ] **Step 1: 写集成测**

创建 `backend/tests/test_b2_reconnect_integration.py`：

```python
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
import json
import random
import sqlite3
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

    async def fetch(self, query: str, *args):
        if "FROM klines" in query:
            _, period = args
            df = self.bars.get(period)
            if df is None or df.empty:
                return []
            return [dict(r) for r in df.to_dict("records")]
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
    return {"dense_1m_start_date": days[0], "dense_1m_end_date": days[-1],
            "dropped_1m_dates": json.dumps([d.isoformat() for d in (dropped or [])])}


def _fixture_conn(dropped: list | None = None, n_days: int = 1000):
    # n_days 必须 ≥ ~820 个工作日：eligible_start_indices 要求月边界数 ≥ 31+months(8)=39，
    # 1000 个工作日 ≈ 46 个月边界 → 8 个候选。500 个工作日只有 ~23 个月边界，
    # 会直接抛「月边界仅 23，不足 39」，全部集成测 FAIL。
    days = _trading_days(dt.date(2022, 1, 3), n_days)
    return _FakeConn("000001.SZ", _build_pg_fixture(days),
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


# ===== fail-closed：门控真的在守 =====

def test_missing_coverage_artifact_skips_fail_closed(tmp_path):
    """D11：无 stock_coverage 行 → 无权威 dense 判定 → 必须 skip，
    **不得**退化成"从 klines 反推"或"不门控直接产"。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    conn = _FakeConn("000001.SZ", _build_pg_fixture(days), None)
    with pytest.raises(GenerateSkipException, match="stock_coverage"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []
    assert list(tmp_path.iterdir()) == [], "fail-closed 路径不得留下任何产物"


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
           "dropped_1m_dates": bad_dropped}
    conn = _FakeConn("000001.SZ", _build_pg_fixture(days), cov)
    with pytest.raises(GenerateSkipException, match="dropped_1m_dates"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []
    assert list(tmp_path.iterdir()) == [], "坏行路径不得留下产物"


def test_reversed_coverage_band_skips(tmp_path):
    """覆盖带反向（start > end）→ 可诊断 skip（DB 有 CHECK，但历史行/别的库可能没有）。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    cov = {"dense_1m_start_date": days[-1], "dense_1m_end_date": days[0],
           "dropped_1m_dates": "[]"}
    conn = _FakeConn("000001.SZ", _build_pg_fixture(days), cov)
    with pytest.raises(GenerateSkipException, match="反向"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))


def test_malformed_coverage_does_not_abort_batch(tmp_path, capsys):
    """整轮 sweep 级证据：坏行只让该股 skip，generate_batch 正常返回（非抛异常）。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    cov = {"dense_1m_start_date": days[0], "dense_1m_end_date": days[-1],
           "dropped_1m_dates": "{not json"}
    conn = _FakeConn("000001.SZ", _build_pg_fixture(days), cov)
    out = asyncio.run(generate_batch(conn, 2, tmp_path, random.Random(3)))
    assert out == []
    assert "dropped_1m_dates" in capsys.readouterr().out


# ===== uq_stock_start TOCTOU 原子处理（codex PF2-R2-F2）=====

def test_concurrent_duplicate_registration_skips_cleanly(tmp_path):
    """并发 sweep 在预检之后抢先登记同一起点 → ON CONFLICT 返回 None →
    必须干净 skip + 清产物，而不是让 UniqueViolationError 中止整轮 sweep。"""
    conn, _ = _fixture_conn()
    conn.steal_first_insert = True
    with pytest.raises(GenerateSkipException, match="抢先登记"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []
    assert list(tmp_path.iterdir()) == [], "冲突路径留下了 orphan 产物"


def test_batch_survives_concurrent_duplicate(tmp_path):
    """sweep 级：一次抢先登记不该毁掉整轮——后续股票仍能成功产出。"""
    conn, _ = _fixture_conn()
    conn.steal_first_insert = True
    out = asyncio.run(generate_batch(conn, 1, tmp_path, random.Random(3)))
    assert len(out) == 1, "首次冲突后 sweep 应继续并最终产出"
    assert len(conn.registered) == 1


def test_generate_batch_surfaces_first_skip_reason(tmp_path, capsys):
    """诚实义务 1（codex PF2-R1-F1）：`stock_coverage` 空表时欠产输出必须带原因。
    否则「Plan 3 落地前的预期状态」与「真回归」在日志里长得一模一样，
    运维只看到「仅生成 0/2」无从判断。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    conn = _FakeConn("000001.SZ", _build_pg_fixture(days), None)   # 无覆盖行
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
```

- [ ] **Step 2: 跑集成测**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/test_b2_reconnect_integration.py -q
```

期望：全 passed。

**若有 FAIL**：不要改测试去迁就实现。先用 `-x --tb=long` 读真实报错——最可能的两类是 (a) fixture 的 bar 数量撑不起 `before≥30` + 8 个前向月（把 `n_days` 调大，**不是**把 `before_min` 调小）；(b) `_FakeConn` 抛 `AssertionError: 未预期的 SQL`（说明生产代码的查询与假件分派不匹配，按真实 SQL 补分派分支）。两类都是 fixture/假件问题，改 fixture；**门控阈值一律不许放宽**。

- [ ] **Step 3: 用 mutation 验证测试真的在守门**

测试全绿不等于门在守（[[feedback_internal_review_misses_bad_data]]：mutation 是唯一证明手段）。逐个临时改坏、确认对应测试**必挂**，然后**全部还原**：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend"
# 变异 1：去掉 coverage 缺失的 fail-closed → test_missing_coverage_artifact_skips_fail_closed 必挂
# 变异 2：exclude_starts 传 frozenset() → test_uq_stock_start_not_reused 必挂
# 变异 3：不删中间 .db → test_intermediate_db_removed_only_zip_kept 必挂
```

对每个变异：手工改 `generate_training_sets.py` → 跑 `../.venv/bin/python -m pytest tests/test_b2_reconnect_integration.py -q` → **确认对应测试 FAIL** → `git checkout backend/generate_training_sets.py` 还原。三个变异都验证完再继续。

若某个变异**没让任何测试挂**，说明那道门没有测试在守——补测试，不要跳过。

- [ ] **Step 4: 全套件三绿**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/ -q
cd "/Users/maziming/Coding/Prj_Kline trainer" && git status --short
```

期望：pytest 全 passed、**0 failed / 0 skipped**；`git status` 无 Step 3 变异残留（所有变异都已还原）。

- [ ] **Step 5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add backend/tests/test_b2_reconnect_integration.py
git commit -m "$(cat <<'EOF'
Plan2b Task6: B2 重接端到端集成测（真实 sweep 产出 ≥1 registered training set）

假件只有 asyncpg conn；生产函数链、SQLite、zip、CRC32 全真。
覆盖核心验收 + fail-closed（无 coverage artifact 必 skip 且不留产物）
+ uq_stock_start 不复用 + generate_batch 真出货。
未预期 SQL 主动抛错，防假件把测试变 vacuous。
EOF
)"
```

---

## PR 2b 收尾

- [ ] **Step 1: 三绿 + 旧停用路径已彻底移除的证据**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/ -q
cd "/Users/maziming/Coding/Prj_Kline trainer"
# 停用残留必须归零（负向断言用 if/exit，不用 ! grep）
if grep -rn "NotImplementedError" backend/generate_training_sets.py backend/app/scheduler.py; then
  echo "FAIL: fail-closed 停用残留未清"; exit 1
fi
if grep -rn "def assemble_training_set" backend/; then
  echo "FAIL: 旧未门控装配函数仍在"; exit 1
fi
```

期望：pytest 全绿；两个 grep 均无输出（`if` 不触发）。

- [ ] **Step 2: 出非-coder 验收清单**

写 `docs/acceptance/2026-07-18-qmt-plan2b-b2-reconnect.md`，动作/预期/通过-不通过三列中文。至少覆盖：跑 `pytest tests/test_b2_reconnect_integration.py` 全绿、`grep NotImplementedError` 无输出、`assemble_training_set` 已不存在、`generate_batch` 在**注入覆盖行的 fixture 上**能出 2 组。

**诚实义务 2（codex PF2-R1-F1，强制）**：清单必须含这么一条，且写在显眼位置——

| 动作 | 预期 | 通过/不通过 |
|---|---|---|
| 阅读本 PR 说明中「当前局限」一节 | 明确写着：本 PR **不会**让 B4 补货真的产出训练组；真库 `stock_coverage` 仍是空表，每股都会 skip、`generate_batch` 仍返回 0；解锁出货的是 Plan 3（B1 写覆盖表） | ☐ |

**诚实义务 3（强制）**：验收清单、commit message、PR body 内**禁止**出现「B4 补货已恢复」「库存已可生成」「训练组已能产出」等表述。收尾前自查（负向断言用 if/exit）：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
if grep -rnE "B4 ?补货已(恢复|打通)|库存已可生成|训练组已能产出|已恢复出货" \
     docs/acceptance/2026-07-18-qmt-plan2b-b2-reconnect.md; then
  echo "FAIL: 出现被禁止的过度宣称表述"; exit 1
fi
```

- [ ] **Step 3: requesting-code-review**

用 `superpowers:requesting-code-review` 自审整支。

- [ ] **Step 4: codex 整体评审（branch-diff）**

用 `.claude/scripts/codex-attest.sh --scope branch-diff --head <分支> --base main`（`codex:adversarial-review` 是斜杠命令、带 `disable-model-invocation: true`，Claude 无法自行调用）。

**预期 codex 会重点打的方向**（提前想好答案，别临场编）：坏数据下 `stock_coverage` 的 `dropped_1m_dates` 非法 JSON / 日期越界 / `dense_1m_start_date > end_date` 会怎样；`month_boundaries.index(start)` 找不到时的行为；并发 sweep 的 TOCTOU；D9 首日豁免会不会放过"窗口最早那天被 B1 drop"的情形（答：会，但**修复前也一样**——`span` 起点本就是 `dates.min()`，该情形不属本次回归）。

- [ ] **Step 5: 开 PR**

中文标题/正文，说明依赖 PR 2a（`stock_coverage` 表）。由用户 merge。

**PR body 必须含「当前局限」一节**（诚实义务 2），逐字表达以下三点：
1. 本 PR 打通的是**代码通路**，不是生产出货；
2. 真库 `stock_coverage` 仍无写入方 → 每股 skip → `generate_batch` 返回 0（与合并前的库存产出**没有变化**）；
3. 解锁出货 = **Plan 3**（B1 接 QMT 规整/合成层 + 写 `stock_coverage`）。

---

## Self-Review（写完本 plan 后已执行）

**Spec 覆盖核对**（spec §4.3 / §4.4 / §6 中属 Plan 2 范围的条目）：

| Spec 条目 | 覆盖 |
|---|---|
| D1 OHLC DECIMAL→DOUBLE + migration + bump + m01 | Task 1 + Task 2 |
| D5 / R16-F2 `file_path`→TEXT + 登记失败删 orphan | Task 1（列） + Task 5 Step 10（orphan 清理） |
| D11 `stock_coverage` 表 + B2 从 artifact 读 dense_dates | Task 1（建表） + Task 5（读取，非反推） |
| D3 `ticket_index` 保留列停写 | Task 3 |
| §4.4 重接 `build_training_windows` + 月边界哨兵从日线求 | Task 5 Step 10 |
| §6「真实 sweep ≥1 registered training set」 | Task 6 |
| R12-F2 候选 bounded retry | 复用 Plan 1 已实现的 `select_valid_window`；Task 5 的 `exclude_starts` 接入同一循环 |
| **（非 spec）D9 门首日边界 bug** | **Task 4**——spec §4.4 D9(b) 字面写"每个交易日桶数精确等于"，未区分「before_cap 切片边界日」与「真数据洞」，生产 cap 下自相矛盾。本 plan 实测复现后修正；**spec §4.4/§6 对应表述应在本 plan 合并后回写更新**（否则下一个读 spec 的人会照着写回同一个 bug） |

**明确不在本 plan（留 Plan 3 pilot）**：D8a 写库前 `information_schema` 断言、D8b `kline_pilot_` reset 护栏、D9(a)/D10 在 **B1** 的强制与 `stock_coverage` **写入**、pilot 运行脚本与 100 股储备池地板、SMB 真拉取、spec §5 的容器化 PG smoke（①②③⑤⑥⑦）。**这些都依赖 `import_csv.py` 接规整/合成层，属 B1 侧改动，与本 plan 的 B2 侧解耦。**

**类型一致性核对**：`assemble_from_windows` 的参数名（`start_datetime`/`end_datetime`/`windows`）在 Task 5 定义、Task 6 不直接调用（走 `generate_one_training_set`）；`_fetch_dense_coverage` 返回三元组与 Task 5 Step 10 的解包一致；`stock_coverage` 五个列名在 Task 1 建表、Task 5 查询、Task 6 假件三处一致（`dense_1m_start_date`/`dense_1m_end_date`/`dropped_1m_dates`）；`per_day_intraday_complete` 在 Task 4 改语义后，Task 5/6 均依赖其在生产 `PERIOD_BEFORE_CAP` 下可通过。

**helper 核实（已完成，无需实施者再猜）**：`test_generate_training_sets.py` 既有 helper 实际为 `_bars(period, n, *, base=_BASE, step=0)`（L31）、`_mid(y, mo, d)`（L215）、`_weekday_trading_dates(d0, d1) -> set`（L223）、`_n_month_boundaries(n) -> list`（L232）、`_intraday_bars_per_day(days, n)`（L355）。本 plan 新增的 `_weekday_range` / `_golden_intraday` / `_GOLDEN_PER_DAY` / `_production_fixture` 在 Task 4-5 内定义，不与既有名冲突（已 grep 核实）。**注意** `_bars` 在 `test_build_training_windows_end_to_end_retries_on_tail_d9_fail` 内被同名局部函数遮蔽，那是函数作用域内的既有写法，不要顺手「统一」掉。

---

## Codex 评审记录

### PF2-R1（2026-07-18，`--scope branch-diff --base main`，verdict = needs-attention）

- **F1 [high] B2 依赖一个本 plan 从不产生的 artifact**（`stock_coverage` 有表无写入方）。
  **核实 = 属实。** `import_csv.py` 只写 `stocks`/`klines` 且不认 QMT 格式；Task 6 集成测靠假 conn 注入覆盖行；真库跑起来每股都 skip、`generate_batch` 仍产 0。
  **处置 = user 2026-07-18 裁决「保持范围、如实改口径」**（不把 B1 接入吹进 Plan 2，避免破 ≤3 子项守则 / codex 不收敛）。落地为文首「⚠️ 本 plan 不会让 B4 补货真的出货」告警 + 三项诚实义务（Task 5 Step 11a 首因输出；PR 2b 收尾 Step 2/5 的验收条目、PR body「当前局限」节、过度宣称 grep 自查）。
  **未采纳 codex 的第一条建议**（把 B1 覆盖写入拉进本 plan）——理由已记录：需先接入整条 QMT B1 链，等于吞掉 Plan 3 大半。

- **F2 [medium] 被排除的起点会吃掉 bounded retry 预算**。
  **核实 = 属实，且是我的设计错误。** `select_valid_window` 只遍历 `cands[:max_retries]`（源码第 125 行），我原打算在 `_try` 里抛异常来复用重试机制 → 每个被排除者占一个名额 → 股票累积训练组后可能明明有可用起点却整股被跳过、非确定性。
  **处置 = 全盘采纳。** 改为在切 `max_retries` **之前**过滤（`select_valid_window` 加 `exclude_starts`，`build_training_windows` 透传），并按 codex 要求补 `test_select_valid_window_excludes_before_retry_budget`（前 9 个候选全排除、第 10 个必须被选中）。

**本轮另行自查修掉的 plan 自身缺陷**（非 codex 指出）：Task 6 的 `_fixture_conn` 原设 `n_days=500` ≈ 23 个月边界，低于 `eligible_start_indices` 要求的 39 → 全部集成测会直接抛「月边界不足」。已改 1000 并写明下限理由。

### PF2-R2（2026-07-18，verdict = needs-attention；两条**全新** finding，均 high、均属"坏数据"面）

- **F1 [high] 坏覆盖行会中止整轮 sweep**。
  **核实 = 属实。** `dropped_1m_dates` 原为无约束 `TEXT`（spec §4.3 D11 字面），reader 裸跑 `json.loads` + `date.fromisoformat`。抛出的 `JSONDecodeError`/`ValueError`/`TypeError` **不是** `GenerateSkipException`，而 `generate_batch` 只捕后者 → 一条坏行让整轮 sweep 中止，在 B4 常驻进程里还会一路冒泡。
  **处置 = 全盘采纳，双层设防。** ① DB 层可执行约束：`dropped_1m_dates JSONB NOT NULL DEFAULT '[]'::jsonb` + `jsonb_typeof(...)='array'` + `start<=end` + `count>=0` + 三列 NOT NULL（migration 与 `schema.sql` 同步，各配断言测）；② reader 层降级：端点 NULL / 区间反向 / 非数组 / 非 ISO 日期 一律转 `GenerateSkipException` 并带原因（防历史行、手工修补、Plan 3 writer 半成品——如 `["nope"]` 能过 `jsonb_typeof` 却不是日期）。补 4 参数化坏值测 + 反向区间测 + sweep 级"不中止"测。
  **偏离 spec 已知且刻意**：spec §4.3 写的是 `TEXT DEFAULT '[]'`，本 plan 收紧为带约束的 `JSONB NOT NULL`。理由 = [[project_app_public_release_intent]] 的耐久性标准；**spec 应在本 plan 合并后回写**。

- **F2 [high] TOCTOU 重复起点其实没被处理**。
  **核实 = 属实，且我的注释在撒谎。** 我写了「TOCTOU 兜底」，但 `_register_training_set` 是裸 INSERT，异常处理只删文件后 `raise` → asyncpg `UniqueViolationError` 穿出 `generate_batch` → 中止整轮 sweep，而非跳过该股。
  **处置 = 全盘采纳。** `INSERT ... ON CONFLICT (stock_code, start_datetime) DO NOTHING RETURNING id` 原子化；返回 `None` = 被并发抢先 → 清产物 + `GenerateSkipException`。`_exists_start` 预检降级为纯优化（省一次白建 zip），并在注释里如实标注。补假件冲突注入测（单股级 + sweep 级各一）。

**本轮教训**：两条都不是"不合 spec"，而是"坏数据/并发下会怎样"——正是 [[feedback_internal_review_misses_bad_data]] 记的那条：内部 review 只问合不合 spec，从不问坏数据。且 F2 证明**注释写了「兜底」不等于真兜底**，需按控制流实际走向验证。
