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

import re
from pathlib import Path

import pglast

MIGRATIONS_DIR = Path(__file__).parent.parent / "sql" / "migrations"
MIG_0004 = MIGRATIONS_DIR / "0004_qmt_price_double_and_coverage"


def _sql_normalized(path: Path) -> str:
    """去 `--` 行注释 + 压平空白 + 转小写，供子串断言用。

    codex PF2-R3-F2：直接对原文做子串断言必挂——(a) 本仓 SQL 用多空格对齐
    （`ALTER COLUMN open  TYPE ...`），单空格 pattern 匹配不上；(b) 注释里出现的
    `ticket_index` 会让「不得含该词」的断言误判。正是
    feedback_acceptance_grep_anchoring 记的「注释子串误判」坑。
    （本仓 migration SQL 不含带 `--` 的字符串字面量，去注释安全。）"""
    text = re.sub(r"--[^\n]*", " ", path.read_text(encoding="utf-8"))
    return re.sub(r"\s+", " ", text).strip().lower()


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
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    for col in ("open", "high", "low", "close"):
        assert f"alter column {col} type double precision" in sql, f"{col} 未转 DOUBLE"


def test_migration_0004_forward_creates_stock_coverage():
    """D11：B2 读 dense_dates 的权威 artifact 表。"""
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    assert "create table" in sql and "stock_coverage" in sql


def test_migration_0004_stock_coverage_is_not_if_not_exists():
    """codex PF2-R7-F1：版本化 migration 里 `CREATE TABLE IF NOT EXISTS` 会让
    "已存在一张旧形状表"静默通过，库低于所声明契约，故障挪到 B4 运行期才炸。
    （schema.sql 那份 fresh baseline 用 IF NOT EXISTS 是对的，migration 不行。）"""
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    assert "create table stock_coverage" in sql
    assert "create table if not exists stock_coverage" not in sql


def test_migration_0004_stock_coverage_carries_integrity_checks():
    """codex PF2-R2-F1：migration 建的表必须与 schema.sql 一样带约束，
    否则已部署库前向迁移后仍是无约束的坏行温床。"""
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    assert "jsonb" in sql
    assert "jsonb_typeof(dropped_1m_dates) = 'array'" in sql
    assert "dense_1m_start_date <= dense_1m_end_date" in sql


def test_migration_0004_forward_widens_file_path_to_text():
    """R16-F2：绝对路径可任意长，VARCHAR(255) 会让登记 INSERT 失败留 orphan。"""
    sql = _sql_normalized(MIG_0004 / "forward.sql")
    assert "alter column file_path type text" in sql


def test_migration_0004_rollback_reverses_all_three_changes():
    """回滚必须覆盖三项：OHLC 回 DECIMAL、file_path 回 VARCHAR(255)、drop 新表。"""
    sql = _sql_normalized(MIG_0004 / "rollback.sql")
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
        # 用**去注释后的正文**断言：forward.sql 的说明注释里合法地提到了 ticket_index
        sql = _sql_normalized(MIG_0004 / name)
        assert "ticket_index" not in sql, f"{name} 正文不得对 ticket_index 做任何 DDL"
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
-- **刻意不用 IF NOT EXISTS**（codex PF2-R7-F1）：版本化 migration 必须对结果形状确定。
-- 若目标库已存在一张手工/试跑建出的旧形状 stock_coverage（TEXT、缺 dense_day_count、
-- 缺 CHECK），IF NOT EXISTS 会让 migration **静默成功**、库却低于所声明的 1.12 契约；
-- 故障随后从"迁移期"挪到"B4 运行期"（PR 2b 会 SELECT dense_day_count → UndefinedColumn）。
-- 裸 CREATE TABLE 在这种情况下直接报错中止 = 正确的 fail-closed。
CREATE TABLE stock_coverage (
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

在 `backend/tests/test_schema.py` 顶部 import 区加一行 `import re`（下面的 `test_stock_coverage_has_integrity_checks` 要用），然后在文件末尾追加：

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
    # 同 PF2-R3-F2：schema.sql 也用多空格对齐（`dense_1m_end_date   DATE NOT NULL`），
    # 必须先压平空白再子串断言，否则本测必挂。需在本文件顶部加 `import re`。
    sql = re.sub(r"\s+", " ", re.sub(r"--[^\n]*", " ",
                 SCHEMA_PATH.read_text(encoding="utf-8"))).lower()
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

期望：`186 passed`（170 基线 + 10 migration + 6 新 schema 测；`test_expected_tables_present` 是**改**既有测、不计新增）。**0 failed / 0 skipped**。

> 数字来自 dry-run 实测推导。若与实际差 1-2，**先核对是不是漏写/多写了某条测试**再改这里；硬性要求是 **0 failed / 0 skipped** 且新测试全部出现。

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

期望：pytest `187 passed`（186 − 3 删除的 ticket_index 测 + 4 新增）。grep 输出**只有** `backend/sql/schema.sql` 的列定义行 + `backend/import_csv.py` 的两行注释；**不得**出现任何 `INSERT`/`compute_`/`_INT_COLS` 行。

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
# ===== Plan 2b Task 4：D9 门边界日修复（Plan 1 遗留 bug 的回归锁）=====
# 本段用到 trading_date，若本文件尚未 import 需补：`from qmt_normalize import trading_date`
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


def _production_cap_windows(days, *, skip=None, short=None, caps=None):
    """用**生产** PERIOD_BEFORE_CAP 切出的盘中窗口（首日必然是部分根——正是本 Task 的靶心）。
    返回 `(wins, after_end, full_bars)`：`full_bars` 必须传给
    per_day_intraday_complete，边界日要对照它判完整性（PF2-R7-F2）。"""
    from generate_training_sets import PERIOD_BEFORE_CAP
    caps = caps or PERIOD_BEFORE_CAP
    start = _mid(days[len(days) // 2].year, days[len(days) // 2].month,
                 days[len(days) // 2].day)
    after_end = int(dt.datetime(days[-1].year, days[-1].month, days[-1].day,
                                23, 59, 59, tzinfo=SH).timestamp())
    wins, full = {}, {}
    for p, n in _GOLDEN_PER_DAY.items():
        full[p] = _golden_intraday(days, n, skip=skip, short=short)
        wins[p] = select_period_window(full[p], start, caps[p], after_end, p)
    return wins, after_end, full


def test_per_day_gate_passes_under_production_before_caps():
    """靶心：生产 cap(150) + 完美数据（每日精确 80/16/4、零 drop）必须过门。
    修复前此测必挂（首日 3m 只有 70 根被判洞）。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    wins, ae, full = _production_cap_windows(days)
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is True


def test_per_day_gate_still_catches_interior_missing_day():
    """不得放松真洞：窗口内某交易日**整日缺席**（B1 drop 的表现）仍必须被拒。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    hole = days[len(days) // 2 + 5]        # 落在 forward 窗口内部
    wins, ae, full = _production_cap_windows(days, skip={hole})
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is False


def test_per_day_gate_still_catches_interior_short_day():
    """只豁免首日：窗口**内部**某日根数不足（非首日）仍必须被拒——
    证明修复没有把「部分日一律放行」。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    bad = days[len(days) // 2 + 5]
    wins, ae, full = _production_cap_windows(days, short={bad: 79})
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is False


def test_per_day_gate_catches_corrupt_boundary_day():
    """codex PF2-R7-F2：边界日在**库里**残缺必须被抓。

    生产 cap 下窗口只切到该日 70/80 根（正常）；但把它在**全量 bars** 里改成 60 根
    （真损坏）→ 必须判失败。这条同时钉死一种已被实测否掉的错误写法：
    用「从窗口反推的余数」`(before_n % need) or need` 判边界日是**自指**的——
    损坏边界日会让 before_n 同步变小、期望值跟着变小、恰好匹配 → 漏检（实测返回 True）。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    probe, _, _ = _production_cap_windows(days)
    d0 = min(trading_date(e) for e in probe["3m"]["datetime"])
    wins, ae, full = _production_cap_windows(days, short={d0: 60})   # 全量里该日只剩 60
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is False


def test_per_day_gate_passes_when_cap_is_exact_multiple():
    """cap 恰为每日根数整数倍（边界日被完整切入窗口）→ 仍应通过。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    caps = {p: n * 2 for p, n in _GOLDEN_PER_DAY.items()}
    wins, ae, full = _production_cap_windows(days, caps=caps)
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is True


def test_per_day_gate_passes_with_zero_before_cap():
    """cap=0（纯 forward 窗口，无 before-context）→ 边界日就是首个前向交易日，应通过。"""
    days = _weekday_range(dt.date(2024, 1, 1), dt.date(2024, 6, 28))
    wins, ae, full = _production_cap_windows(days, caps={p: 0 for p in _GOLDEN_PER_DAY})
    assert per_day_intraday_complete(wins, days, ae, full_bars=full) is True


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

改**三处**。

其一，签名（第 164 行）加 keyword-only 参数：

```python
def per_day_intraday_complete(windows, trading_dates, after_end, expected=None,
                              *, full_bars=None) -> bool:
```

其二，第 178-180 行的判定：

```python
        counts = dates.value_counts().to_dict()
        if not all(counts.get(d, 0) == need for d in span):
            return False
```

改为：

```python
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
```

其三，同步 docstring：

```python
    """D9 per-day 硬门（codex PF1-R2/PF1-R4-F2/PF1-R6-F1 + Plan 2b 边界日修正）：
    **每个盘中周期**在 `[该周期首选中日, trading_date(after_end)]` 内、每个交易日
    （∈ trading_dates）桶数精确 == 应有数（3m=80/15m=16/60m=4）；**首日 d0 同样精确验**，
    只是判据换成「**该日在 `full_bars` 里是完整的**」（d0 只是被 before_cap 切片的那天，
    窗口内不足是切片产物；但它在库里必须有满 need 根）。不传 `full_bars` 则退回严格
    全量，向后兼容既有调用。
    **跨度终点用 `after_end`、非 `dates.max()`**——否则 after_end 附近盘中全缺的
    尾日会落在 max 之外、漏检（高周期 bar 覆盖了无盘中回放的日期）。任一周期任一日不符 → False。"""
```

其四，`build_training_windows._try` 里的调用要把 `period_bars` 传进去（第 156 行）：

```python
        if not per_day_intraday_complete(intraday, trading_dates, after_end, intraday_expected,
                                         full_bars=period_bars):     # PF2-R7-F2 边界日对照全量
            raise GenerateSkipException("D9 per-day 硬门失败")
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
- Produces: `assemble_from_windows(output_dir, *, stock_code, stock_name, start_datetime, end_datetime, windows) -> GeneratedTrainingSet`（纯函数）；`build_training_windows` **与** `select_valid_window` 各新增 keyword-only 参数 `exclude_starts: frozenset[int] = frozenset()`（前者透传给后者，后者在切 `max_retries` **之前**过滤）；`_fetch_dense_coverage(conn, stock_code) -> tuple[date|None, date|None, set[date], int|None]`（四元组，末位 `dense_day_count`；坏行抛 `GenerateSkipException`）；`_fetch_existing_starts(conn, stock_code) -> set[int]`；`_register_training_set(conn, gts) -> Optional[int]`（唯一冲突返回 `None`，**非**抛异常）。`generate_one_training_set` 直接产在 `output_dir`、**先写文件后登记**（崩溃窗口 = 自愈的孤儿 zip；并发已由 D14 advisory lock 单例排除，见文末 PF2-R5 决议）。Task 6 的集成测依赖这四个符号。

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

**先在文件顶部 import 区加一行**（codex PF2-R8-F2：下面的实现要用 `tempfile`，
若等到 Step 10 再加，Step 4 的第一个绿色检查点会直接 `NameError`）：

```python
import tempfile
```

然后把 `backend/generate_training_sets.py` 第 286-295 行（整个 `assemble_training_set`
函数及其 docstring）替换为：

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
        "SELECT dense_1m_start_date, dense_1m_end_date, dropped_1m_dates, dense_day_count "
        "FROM stock_coverage WHERE stock_code=$1", stock_code)
    if row is None:
        return None, None, set(), None
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
    return start_date, end_date, dropped, row["dense_day_count"]


async def _fetch_existing_starts(conn, stock_code: str) -> set:
    """uq_stock_start：该股已登记的所有 start_datetime，作 build_training_windows
    的 exclude_starts（把唯一性变成候选资格，而非事后撞库重来）。"""
    rows = await conn.fetch(
        "SELECT start_datetime FROM training_sets WHERE stock_code=$1", stock_code)
    return {int(r["start_datetime"]) for r in rows}
```

文件顶部 import 区（第 22-30 行附近）补一个 import（`tempfile` 已在 Task 5 Step 3 加过）：

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

    start_date, end_date, dropped, dense_day_count = await _fetch_dense_coverage(
        conn, stock_code)
    if start_date is None or end_date is None:
        raise GenerateSkipException(
            f"{stock_code}: stock_coverage 无覆盖 artifact（B1 未写入）→ 无法门控，跳过")

    daily = period_bars["daily"]
    trading_dates = sorted({trading_date(int(e)) for e in daily["datetime"]})
    dense_dates = {d for d in trading_dates if start_date <= d <= end_date} - dropped
    if not dense_dates:
        raise GenerateSkipException(f"{stock_code}: dense 覆盖为空")

    # **交叉校验重建出的日历 vs 权威计数**（codex PF2-R6-F1）。
    # 上面的 trading_dates 是从**现存的 daily klines** 反推的：若带内某个交易日的
    # daily 行本身缺失（B1 半途导入 / 行丢失），那天就同时从 dense_dates 与 D9 的
    # span 里**一起消失** —— 两道门都看不见它，窗口能带着整日空洞过关。
    # dense_day_count 是 B1 写下的权威天数，对不上即 fail-closed。
    if dense_day_count is None:
        raise GenerateSkipException(
            f"{stock_code}: stock_coverage.dense_day_count 为 NULL，无法交叉校验")
    if len(dense_dates) != int(dense_day_count):
        raise GenerateSkipException(
            f"{stock_code}: dense 日历不一致——artifact 记 {dense_day_count} 天，"
            f"由 daily klines 重建出 {len(dense_dates)} 天（带内有 daily 行缺失？）")

    month_boundaries = period_boundaries(daily, "monthly")
    exclude = await _fetch_existing_starts(conn, stock_code)

    start_datetime, windows = build_training_windows(
        period_bars, month_boundaries, rng,
        dense_dates=dense_dates, trading_dates=trading_dates,
        before_caps=PERIOD_BEFORE_CAP, max_retries=max_retries,
        exclude_starts=frozenset(exclude))

    idx = month_boundaries.index(int(start_datetime))
    after_end = compute_after_end(month_boundaries, idx)

    # 顺序 = **先写文件、后登记**（codex PF2-R4 后简化；见文末 PF2-R5 决议）。
    # 生产上并发生成不可能：B2 只在 B4 sweep 内跑，而 scheduler_main D14 用
    # `pg_try_advisory_lock` 强制**集群级单例**（第二个进程直接退出）+ APScheduler
    # `max_instances=1`/`coalesce=True` 防同进程重入。故不做暂存/两阶段发布——
    # 那套机器是给架构上不发生的场景加的，且每加一层都引入新失败面（R2→R3→R4）。
    #
    # 本顺序下的崩溃窗口 = 写完 zip、登记前进程死 → **孤儿 zip + 无数据库行**。
    # 它是**自愈**的：没有行引用它、exclude_starts 也不含该起点 → 下次 sweep 可重选
    # 同一起点、覆盖它并登记成功。（反之「先登记后发布」留下的是 uq_stock_start 被占、
    # B3 反复预定却 404 的**永久卡死行**，严格更糟。）
    gts = assemble_from_windows(output_dir, stock_code=stock_code,
                                stock_name=_stock_name_of(stock_code),
                                start_datetime=int(start_datetime),
                                end_datetime=int(after_end), windows=windows)

    # 预检：候选已按 exclude_starts 过滤，这条只是省掉常见情形下的一次白建 zip
    if await _exists_start(conn, stock_code, gts.start_datetime):
        gts.path.unlink(missing_ok=True)     # 中间 .db 在临时目录、已自动清
        raise GenerateSkipException(
            f"{stock_code}: start {gts.start_datetime} 已登记，跳过")

    # ON CONFLICT DO NOTHING = 廉价保险：唯一冲突返回 None 而非抛
    # UniqueViolationError（后者不被 generate_batch 捕获 → 中止整轮 sweep）。
    # 只覆盖「运维手工跑 CLI 时调度器也在跑」这个**不受支持**的操作场景；
    # 此时不删最终路径的文件（可能是对方的产物），只干净跳过。
    row_id = await _register_training_set(conn, gts)
    if row_id is None:
        raise GenerateSkipException(
            f"{stock_code}: start {gts.start_datetime} 已登记（并发 CLI？），跳过")
    return gts                       # 中间 .db 从不落在 output_dir，无需清理
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

- [ ] **Step 10b: 给 B2 生成加互斥 advisory lock（CLI + scheduler 两条路径）**

codex PF2-R5-F2：把「CLI 与调度器并跑」写成"不受支持"**不是强制手段**——CLI 依然可调用，
真发生时会覆盖已登记 `file_path` 背后的 zip，让 `content_hash` 对不上 → B3 下载校验失败
或静默坏产物（用户可见）。改为**真正互斥**，复用本仓 D14 已验证的模式（`scheduler_main.py:37`）。

用**新 key**（不复用 `SCHEDULER_LOCK_KEY`）：若复用，跑着的 CLI 会让 B4 守护进程启动即退出，
是更糟的运维事故。新 key 只互斥"B2 生成"这件事本身。

在 `backend/generate_training_sets.py` 顶部常量区（`SCHEMA_VERSION` 附近）加：

```python
# B2 生成互斥锁 key（codex PF2-R5-F2；与 scheduler_main.SCHEDULER_LOCK_KEY 刻意不同——
# 复用那把会让运行中的 CLI 把 B4 守护进程挡在启动之外）。CLI 与 B4 sweep 两条
# 调用 B2 的路径都必须先拿到它，杜绝同一 (stock_code,start) 被两个 writer 同时产出。
B2_GENERATION_LOCK_KEY = 0x42345CEE
```

CLI 侧（`_amain`，第 398-419 行）把 `generate_batch` 调用包进锁：

```python
        if not await conn.fetchval("SELECT pg_try_advisory_lock($1)",
                                   B2_GENERATION_LOCK_KEY):
            print("[B2] 错误：B2 生成锁被占（B4 调度器正在 sweep，或另一个 B2 CLI 在跑）。"
                  "并发生成会覆盖已登记的 .zip 并让 content_hash 失配，故拒绝启动。")
            return 1
        try:
            sets = await generate_batch(conn, args.count, out_dir, random.Random(args.seed))
        finally:
            await conn.execute("SELECT pg_advisory_unlock($1)", B2_GENERATION_LOCK_KEY)
```

scheduler 侧（`backend/app/scheduler.py` 的 `_gen`）同样加锁——注意 advisory lock 是
**按连接**持有的，必须在同一个 `conn` 上取/放：

```python
    async def _gen(n: int) -> int:
        from generate_training_sets import B2_GENERATION_LOCK_KEY, generate_batch
        async with pool.acquire() as conn:
            # codex PF2-R5-F2：与 B2 CLI 互斥。拿不到锁 = 有人手工在跑 B2 →
            # 本次 sweep 生成 0 并告警，等下次 cron，不与之竞争同一产物路径。
            if not await conn.fetchval("SELECT pg_try_advisory_lock($1)",
                                       B2_GENERATION_LOCK_KEY):
                logger.warning("B2 生成锁被占（有人手工在跑 B2 CLI？）；本次 sweep 生成 0，"
                               "等下次 cron 重试")
                return 0
            try:
                produced = await generate_batch(conn, n, out, rng)
            finally:
                await conn.execute("SELECT pg_advisory_unlock($1)", B2_GENERATION_LOCK_KEY)
            return len(produced)
```

（本 Step 同时完成 Step 11 要做的"删 scheduler 里孤儿 `NotImplementedError` 捕获"——
上面的新 `_gen` 已不含该捕获。）

**⚠️ 必须同步改既有测试，否则 3 个测试立刻挂**（dry-run 实测发现，8 轮评审均未指出）：
`_gen` 现在会先调 `conn.fetchval(...)`，而 `tests/test_scheduler.py` 的 `_fake_pool()`
里 `class _FakeConn: pass` **没有 `fetchval`** → `AttributeError`。把它改成：

```python
def _fake_pool(lock_ok: bool = True):
    class _FakeConn:
        # Plan 2b：_gen 现在先抢 B2_GENERATION_LOCK_KEY（codex PF2-R5-F2）
        async def fetchval(self, q, *a):
            assert "pg_try_advisory_lock" in q
            return lock_ok

        async def execute(self, q, *a):
            return "ok"
```

**并删除 `test_build_generate_batch_real_b2_fail_closed_logs_error_returns_zero`**——
它断言的是本 plan 已移除的 `NotImplementedError` 路径，还逐字断言了
"旧未门控随机选起点路径已停用" 这条被删掉的错误文案，**不可能再通过**。用等价的
锁行为测试取代（放同一位置）：

```python
def test_build_generate_batch_returns_zero_when_b2_lock_held(caplog, tmp_path):
    # Plan 2b（codex PF2-R5-F2）：取代原 fail-closed 测（NotImplementedError 捕获已随重接移除）。
    import logging

    from app.scheduler import build_generate_batch
    gen = build_generate_batch(_fake_pool(lock_ok=False), str(tmp_path / "ts_out"))
    with caplog.at_level(logging.WARNING, logger="app.scheduler"):
        assert asyncio.run(gen(5)) == 0
    assert "B2 生成锁" in caplog.text
```

- [ ] **Step 10c: 锁的测试——不在本步写**

codex PF2-R8-F1：锁的测试要落在 `backend/tests/test_b2_reconnect_integration.py`，
而**那个文件由 Task 6 创建**；若在本步先追加，会造出一个缺 import 的半截文件，
或者被 Task 6 的整file写入覆盖掉 —— 两种结果都会让「CLI/B4 并发生成」这条新防线
**根本没被验证**，而它正是能损坏已登记 zip / `content_hash` 的那条路径。

**故本步不写测试**：锁的两条测试（`test_cli_refuses_when_b2_lock_held` 与
`test_gen_adapter_returns_zero_when_b2_lock_held`）**已包含在 Task 6 的建file内容里**，
连同它们需要的 `sys` / `types` import。本步只改生产代码。

> **实施者注意**：因此 Task 5 结束时（Step 12 全套件）锁的行为**尚无测试覆盖**，
> 这是刻意的排序取舍。**Task 6 跑完前不得声称「并发防线已验证」**。

> **Step 11 已删除**（codex PF2-R6-F2）。原 Step 11 让实施者把 `_amain` 里那段
> 替换成**没有锁的** `sets = await generate_batch(...)`，会**撤销 Step 10b 刚加的 CLI
> advisory lock**，重新打开"手工 CLI 撞 B4 → 覆盖已登记 zip → content_hash 失配"的洞。
> Step 10b 给出的 `_amain` 片段**已经**是最终形态（既含锁、也已不含孤儿的
> `NotImplementedError` 捕获），无需后续步骤再动它。
>
> **实施者注意**：`_amain` 与 `_gen` 的最终代码以 **Step 10b** 为准，本 plan 其它任何
> 位置若出现不带锁的 `generate_batch(...)` 调用形态，一律以 Step 10b 覆盖。

- [ ] **Step 12: 全套件确认零回归**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && ../.venv/bin/python -m pytest tests/ -q
```

期望：全 passed、0 skipped。`test_scheduler.py` 需要的两处改动（`_fake_pool` 加
`fetchval`/`execute`、删掉 fail-closed 测并用锁测试取代）**已在 Step 10b 明确给出**，
照做即可；除此之外 `test_scheduler.py` 不得再改。

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
import functools
import json
import random
import sqlite3
import sys
import types
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
from qmt_normalize import trading_date        # PF2-R7-F3：dense_day_count 测的过滤要用

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


@functools.lru_cache(maxsize=4)
def _cached_fixture(start: dt.date, n_days: int):
    """**性能**（dry-run 实测）：fixture 每周期约 8 万行，逐测重建会让本文件跑 ~59s、
    整个后端套件从 3.5s 涨到 63s。输入确定 → 缓存。返回**浅拷贝**：个别测试会
    `bars["daily"] = ...` 重绑定某周期（不原地改 DataFrame），浅拷贝即可隔离缓存。"""
    return _build_pg_fixture(_trading_days(start, n_days))


def _pg_fixture(start: dt.date, n_days: int) -> dict:
    return dict(_cached_fixture(start, n_days))


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
        self._rows_cache: dict = {}     # 见 fetch()：8 万行 to_dict 的结果缓存

    async def fetch(self, query: str, *args):
        if "FROM klines" in query:
            _, period = args
            df = self.bars.get(period)
            if df is None or df.empty:
                return []
            # **性能**（dry-run 实测）：每周期 8 万行，逐次 to_dict 是主要耗时来源 → 按 id 缓存
            key = id(df)
            hit = self._rows_cache.get(key)
            if hit is None:
                hit = df.to_dict("records")
                self._rows_cache[key] = hit
            return hit
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
    dropped = dropped or []
    return {"dense_1m_start_date": days[0], "dense_1m_end_date": days[-1],
            "dropped_1m_dates": json.dumps([d.isoformat() for d in dropped]),
            # 权威天数必须与 B2 重建出的 dense_dates 一致（PF2-R6-F1 交叉校验）
            "dense_day_count": len([d for d in days if d not in set(dropped)])}


def _fixture_conn(dropped: list | None = None, n_days: int = 1000):
    # n_days 必须 ≥ ~820 个工作日：eligible_start_indices 要求月边界数 ≥ 31+months(8)=39，
    # 1000 个工作日 ≈ 46 个月边界 → 8 个候选。500 个工作日只有 ~23 个月边界，
    # 会直接抛「月边界仅 23，不足 39」，全部集成测 FAIL。
    days = _trading_days(dt.date(2022, 1, 3), n_days)
    return _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), n_days),
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
    # 中间 .db 建在临时目录、随 with 块清掉，最终目录从来不该出现它
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
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), None)
    with pytest.raises(GenerateSkipException, match="stock_coverage"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []
    assert list(tmp_path.iterdir()) == [], "fail-closed 路径不得留下任何产物（含暂存目录）"


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
           "dropped_1m_dates": bad_dropped, "dense_day_count": len(days)}
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), cov)
    with pytest.raises(GenerateSkipException, match="dropped_1m_dates"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []
    assert list(tmp_path.iterdir()) == [], "坏行路径不得留下产物"


def test_dense_day_count_mismatch_skips(tmp_path):
    """codex PF2-R6-F1：带内某交易日的 daily 行缺失时，那天会同时从 dense_dates 与
    D9 span 里消失——两道门都瞎。dense_day_count 交叉校验是唯一能抓到它的东西。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    bars = _pg_fixture(dt.date(2022, 1, 3), 1000)
    missing = days[len(days) // 2]
    # 从 daily 里抠掉带内一个交易日（模拟 B1 半途导入 / 行丢失）
    bars["daily"] = bars["daily"][
        bars["daily"]["datetime"].map(lambda e: trading_date(int(e))) != missing
    ].reset_index(drop=True)
    cov = {"dense_1m_start_date": days[0], "dense_1m_end_date": days[-1],
           "dropped_1m_dates": "[]", "dense_day_count": len(days)}   # 权威计数仍是全量
    conn = _FakeConn("000001.SZ", bars, cov)
    with pytest.raises(GenerateSkipException, match="dense 日历不一致"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []


def test_reversed_coverage_band_skips(tmp_path):
    """覆盖带反向（start > end）→ 可诊断 skip（DB 有 CHECK，但历史行/别的库可能没有）。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    cov = {"dense_1m_start_date": days[-1], "dense_1m_end_date": days[0],
           "dropped_1m_dates": "[]", "dense_day_count": len(days)}
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), cov)
    with pytest.raises(GenerateSkipException, match="反向"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))


def test_malformed_coverage_does_not_abort_batch(tmp_path, capsys):
    """整轮 sweep 级证据：坏行只让该股 skip，generate_batch 正常返回（非抛异常）。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    cov = {"dense_1m_start_date": days[0], "dense_1m_end_date": days[-1],
           "dropped_1m_dates": "{not json", "dense_day_count": len(days)}
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), cov)
    out = asyncio.run(generate_batch(conn, 2, tmp_path, random.Random(3)))
    assert out == []
    assert "dropped_1m_dates" in capsys.readouterr().out


# ===== uq_stock_start TOCTOU 原子处理（codex PF2-R2-F2）=====

def test_registration_conflict_skips_without_crashing(tmp_path):
    """`ON CONFLICT DO NOTHING` 作廉价保险：唯一冲突返回 None → 干净 skip，
    而不是 UniqueViolationError 穿出 generate_batch 中止整轮 sweep。

    注：**生产上并发不可能**（scheduler_main D14 `pg_try_advisory_lock` 集群级单例
    + APScheduler max_instances=1）。本保险只覆盖「运维手工跑 B2 CLI 时调度器也在跑」
    这个**不受支持**的操作场景（见文末 PF2-R5 接受残留）。"""
    conn, _ = _fixture_conn()
    conn.steal_first_insert = True
    with pytest.raises(GenerateSkipException, match="已登记"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == []


def test_stale_db_from_crash_does_not_block_regeneration(tmp_path):
    """codex PF2-R5-F1：崩溃可能在最终目录留下 `{code}_{start}.db`。
    `_TRAINING_SET_DDL` 是裸 `CREATE TABLE`，若装配仍往那个路径写，就会撞
    `table meta already exists`（sqlite3.OperationalError，**不是**
    GenerateSkipException）→ 中止整轮 sweep。中间 .db 改建在临时目录后，
    最终目录里的陈旧 .db 只是无害垃圾，不得影响生成。"""
    conn, _ = _fixture_conn()
    probe = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                  random.Random(7)))
    stale_db = tmp_path / f"000001.SZ_{probe.start_datetime}.db"
    stale_db.write_bytes(b"not a sqlite file at all")     # 陈旧残渣
    conn.registered.clear()

    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert gts.start_datetime == probe.start_datetime
    assert len(conn.registered) == 1


def test_orphan_zip_from_crash_is_self_healing(tmp_path):
    """崩溃窗口（zip 已落盘、登记前进程死）= 孤儿 zip + 无数据库行 → **自愈**。

    没有行引用它、`exclude_starts` 也不含该起点 → 下次 sweep 可重选同一起点、
    覆盖孤儿并登记成功。这正是「先写文件后登记」优于「先登记后发布」的地方：
    后者会留下 uq_stock_start 被占、B3 反复预定却 404 的**永久卡死行**。"""
    from generate_training_sets import crc32_hex
    conn, _ = _fixture_conn()
    probe = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                  random.Random(7)))
    orphan = probe.path
    conn.registered.clear()                        # 模拟：文件落盘了，登记那步没发生
    orphan.write_bytes(b"stale partial content")   # 且内容是坏的/半截的

    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert gts.start_datetime == probe.start_datetime, "该起点被永久占用了（未自愈）"
    assert gts.path.read_bytes() != b"stale partial content", "坏孤儿未被覆盖"
    assert crc32_hex(gts.path.read_bytes()) == gts.content_hash
    assert len(conn.registered) == 1


def test_generate_batch_surfaces_first_skip_reason(tmp_path, capsys):
    """诚实义务 1（codex PF2-R1-F1）：`stock_coverage` 空表时欠产输出必须带原因。
    否则「Plan 3 落地前的预期状态」与「真回归」在日志里长得一模一样，
    运维只看到「仅生成 0/2」无从判断。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), None)   # 无覆盖行
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


# ===== B2 生成互斥锁（Task 5 Step 10b 的防线；测试按 PF2-R8-F1 放在本文件）=====

async def _must_not_run(*a, **k):
    raise AssertionError("拿不到 B2 生成锁时不得调用 generate_batch")


def test_cli_refuses_when_b2_lock_held(tmp_path, monkeypatch, capsys):
    """codex PF2-R5-F2 + R6-F2：CLI 侧的锁必须真存在且真拦住。
    拿不到锁 → 非零退出 + 明确报错，**不得**继续生成（继续会覆盖已登记的 zip、
    让 content_hash 失配）。"""
    import generate_training_sets as G

    class _LockedConn:
        async def fetchval(self, q, *a):
            assert "pg_try_advisory_lock" in q
            return False
        async def execute(self, q, *a):
            raise AssertionError("拿不到锁时不应 unlock")
        async def close(self):
            return None

    async def _connect(dsn):
        return _LockedConn()

    fake = types.ModuleType("asyncpg")
    fake.connect = _connect
    monkeypatch.setitem(sys.modules, "asyncpg", fake)
    monkeypatch.setattr(G, "generate_batch", _must_not_run)

    rc = G.main(["--dsn", "postgres://x", "--output", str(tmp_path)])
    assert rc != 0, "拿不到 B2 锁时 CLI 必须非零退出"
    assert "锁" in capsys.readouterr().out


def test_gen_adapter_returns_zero_when_b2_lock_held(tmp_path, caplog):
    """B4 侧：拿不到 B2 生成锁 → 本次 sweep 生成 0 + 告警，**不**与手工 CLI
    竞争同一产物路径。"""
    import logging
    from app.scheduler import build_generate_batch

    class _LockedConn:
        async def fetchval(self, q, *a):
            assert "pg_try_advisory_lock" in q
            return False
        async def execute(self, q, *a):
            raise AssertionError("拿不到锁时不应 unlock")

    class _Acq:
        async def __aenter__(self): return _LockedConn()
        async def __aexit__(self, *a): return False

    class _Pool:
        def acquire(self): return _Acq()

    gen = build_generate_batch(_Pool(), str(tmp_path))
    with caplog.at_level(logging.WARNING):
        assert asyncio.run(gen(5)) == 0
    assert "B2 生成锁" in caplog.text
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

期望：pytest **`217 passed`**（187 + Task4/5 净 +9 + 本文件 21）、**0 failed / 0 skipped**；`git status` 无 Step 3 变异残留（所有变异都已还原）。

> **耗时提醒**（dry-run 实测）：本文件 21 条测试跑真实生产链 + 8 万行 fixture，加两处缓存优化后整套后端约 **42s**（基线 3.5s）。这是刻意取舍——集成测跑真函数链而非 mock。若明显超过 1 分钟，检查两处缓存（`_cached_fixture` / `_rows_cache`）是否落实。

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

### PF2-R3（2026-07-18，verdict = needs-attention；两条全新 finding）

- **F1 [high] 并发输家会删掉/覆写赢家已登记的产物**。
  **核实 = 属实，且比"不处理并发"更糟。** `assemble_from_windows` 写的是确定性最终路径 `{code}_{start}.zip`。两个 sweep 选中同一 `(stock_code, start_datetime)` 时：赢家登记成功，输家把**同名文件**写下去（覆写赢家）、`ON CONFLICT` 返回 `None` 后又 `unlink` 掉它 → `training_sets.file_path` 指向缺失/损坏文件 = **数据丢失**。我 R2 加的假件冲突测把冲突建模成"没有竞争行"，结构上抓不到这条。
  **处置 = 全盘采纳。** 改「暂存 → 登记 → 发布」：在 `output_dir` 内开唯一暂存目录装配，**只有 INSERT 真拿到行**才 `os.replace` 原子发布到最终路径；输家只清自己的暂存目录、**永不触碰最终路径**。测试按 codex 要求重写为"先造赢家的已登记 zip → 制造冲突 → 断言赢家文件逐字节不变"，另加成功路径无暂存残渣测。
  > **⚠️ 本条处置已被 PF2-R5 决议整体撤回**（见下）——暂存/两阶段发布是为架构上不发生的并发场景加的机器，且它本身又引出 R4-F1。最终设计 = 先写文件后登记。本条保留仅作决策留痕。

- **F2 [medium] Task 1 的 migration 测试对着 plan 自己给的 SQL 必挂**。
  **核实 = 属实。** (a) 我给的 forward/rollback 用多空格对齐（`ALTER COLUMN open  TYPE ...`），而断言写的是单空格 `alter column open type double precision`；(b) `test_migration_0004_does_not_touch_ticket_index` 断言全文不含 `ticket_index`，但同一份 forward.sql 的说明注释里就有这个词。Step 5「期望 10 passed」按原样不可达。
  **处置 = 全盘采纳。** 加 `_sql_normalized()`（去 `--` 行注释 + 压平空白 + 小写）供所有子串断言使用；`丢精度` 标注测仍读原文（它本就是在验注释存在）。
  **自查连带修**：我 R2 自己新增的 `test_stock_coverage_has_integrity_checks` 有同一毛病（`dense_1m_end_date   DATE NOT NULL` 三空格），codex 未点名，一并按同样方式修掉。
  **这是重犯**：[[feedback_acceptance_grep_anchoring]] 明确记过「human-grep 命中注释子串误判」，我又踩了一次。教训 = 凡对 SQL/源码做子串断言，**先规范化再断言**，不要对齐美观的原文直接 grep。

### PF2-R4（2026-07-18，verdict = needs-attention）+ PF2-R5 决议（架构 escalate + 接受残留）

- **R4-F1 [high] 数据库行先于产物可见**：`_register_training_set` 在 `os.replace` 之前提交，`status` 默认 `unsent` → INSERT 后、发布前崩溃 = 一条**持久的 unsent 行指向不存在的 zip**；B3 会预定它并 404，且 `uq_stock_start` 被占死、该起点无法重新生成。
  **核实 = 属实**（这正是我 R3 设计时自评"可接受"的崩溃窗口，我低估了它——关键在**不可回收**，不是窗口大小）。

**但 R5 决议 = 不按 R4 建议加 `building` 状态，而是把 R2~R4 的并发机器整体拆掉。**

**架构事实（前四轮 codex 与我都没核实过，我的责任）**：`backend/app/scheduler_main.py:37` 用 `pg_try_advisory_lock(0x42345CED)` 强制 **B4 调度器集群级单例**（第二个进程 log error 后直接退出，`test_scheduler_main_exits_when_lock_held` 有覆盖）；`scheduler.py:132` 另有 `max_instances=1` + `coalesce=True` 防同进程重入。B2 生成只在 B4 sweep 内发生 → **生产上并发生成同一 `(stock_code, start_datetime)` 在架构上不可能**。

**因果链证明这是下钻而非收敛**：R2-F2 的 `ON CONFLICT` 修复 → 造出 R3-F1（输家删赢家产物）→ R3 的暂存/发布修复 → 造出 R4-F1（行先于产物）。每层修复都在架构上不发生的场景里新增失败面。对应 [[feedback_codex_distributed_reliability_drilldown]]（codex 在分布式可靠性上无限下钻）与 CLAUDE.md §2（不为不可能场景写错误处理）。

**最终设计 = 先写文件、后登记**（回到 PR #74 的顺序，保留 `ON CONFLICT DO NOTHING`）：
- 崩溃窗口 = 孤儿 zip + 无数据库行 → **自愈**（无行引用、起点未被占 → 下次 sweep 覆盖重登记成功）。**严格优于 R2/R3/R4 任一设计**，尤其优于 R4 的永久卡死行。
- `ON CONFLICT DO NOTHING` 保留为廉价保险：把唯一冲突从 `UniqueViolationError`（中止整轮 sweep）降级为干净 skip。
- 不引入 `building` 状态——那要改 `ck_status_enum` 与 `ck_lease_state_invariant` 两条 CHECK，**动的是 M0.1 文档化的 `unsent→reserved→sent` 状态机**（trust-boundary 面远大于改列类型），还要同步 m01 状态机文档 + 写 building 行回收逻辑，为一个架构上不发生的场景付这个代价不划算。

**接受残留（user 2026-07-18 裁决）**：运维**手工跑 B2 CLI 的同时 B4 调度器在跑** = 不受支持的操作。此时 `ON CONFLICT` 保证不崩、干净跳过，但最终路径上的 zip 可能被覆盖成与已登记 `content_hash` 不符的内容。**不为此加机器**；如将来真要支持并发生成，正解是给 B2 也加 advisory lock（与 D14 同一模式），而非两阶段发布。
→ 收口方式 = `attest-override.sh`（user 真终端），reason 记本节。

### PF2-R5（2026-07-18，verdict = needs-attention；两条 high，**均采纳**）

- **F1 [high] 陈旧 `.db` 会让"自愈"失效**。
  **核实 = 属实，我 R5 决议里的自愈论证是半对的。** 我只推了 `.zip`（`ZipFile(path,"w")` 截断重写 → 确实自愈），漏了中间 `.db`：`assemble_from_windows` 把它写在最终目录、登记成功后才删。崩溃留下的 `{code}_{start}.db` 遇上裸 `CREATE TABLE meta`（`generate_training_sets.py:228`，无 `IF NOT EXISTS`）→ 下次同起点重试抛 `sqlite3.OperationalError: table meta already exists`，**不是** `GenerateSkipException` → 中止整轮 sweep。
  **处置 = 采纳。** 中间 `.db` 改建在 `tempfile.TemporaryDirectory()`——它本就是纯构建中间产物（从不登记、无人引用），**没有理由出现在输出目录**。顺带消掉两处 `.db` 清理代码。补 codex 要求的回归测（预置坏的陈旧 `.db` → 下次生成仍成功）。

- **F2 [high] "不受支持"不是强制手段**。
  **核实 = 属实。** 我 R5 把 CLI/B4 并跑列为接受残留，但 CLI 依然可调用、没有任何机制拦它；真发生时覆盖已登记 `file_path` 背后的 zip → `content_hash` 失配 → B3 下载校验失败或静默坏产物（**用户可见**）。
  **处置 = 采纳，撤回 R5 的接受残留。** codex 给的补救比我 R4 拒掉的 `building` 状态便宜得多，且复用本仓已验证的 D14 模式：新增 `B2_GENERATION_LOCK_KEY`，**CLI 与 B4 `_gen` 两条调用 B2 的路径都先 `pg_try_advisory_lock`**，拿不到就拒绝/本轮生成 0。零 schema 改动、零状态机改动、约 15 行。
  **刻意用新 key 而非复用 `SCHEDULER_LOCK_KEY`**：复用的话，一个跑着的 CLI 会让 B4 守护进程启动即退出（`scheduler_main` 拿不到锁就 `return`），那是更糟的运维事故。
  依据 [[project_app_public_release_intent]]：耐久性取舍默认选做，codex 坚持数据耐久性时照做。

> **R5 接受残留（CLI/B4 并跑）已作废** —— F2 的锁把它变成了强制不变量，**不再需要 `attest-override.sh` 收口**。

### PF2-R6（2026-07-18，verdict = needs-attention；两条 high，**均采纳**）

- **F1 [high] B2 用"可能不全的 daily 行"反推 dense 日历，两道门一起瞎**。
  **核实 = 属实，是一直存在的坏数据面。** `trading_dates` 从现存 daily klines 反推，`dense_dates` 又基于它。若带内某交易日的 **daily 行本身缺失**（B1 半途导入 / 行丢失），那天就同时从 `dense_dates`（D2 门）与 `per_day_intraday_complete` 的 `span`（D9 门）里消失——**两道门都看不见它**，窗口能带着整日空洞过关。我建了 `dense_day_count` 列、也在 Task 5 Interfaces 里声称读取表契约，却**从没真读过、更没校验**，等于让这列当摆设。
  **处置 = 采纳。** `_fetch_dense_coverage` 改返四元组（带 `dense_day_count`）；`generate_one_training_set` 交叉校验 `len(dense_dates) == dense_day_count`，不等 → fail-closed 且报出两个数字。补集成测（artifact 声称全量天数，但 daily 抠掉带内一天 → 必 skip）。所有 fixture 的 coverage 行同步补该字段。

- **F2 [high] 后面的 Step 会把前面刚加的 CLI 锁删掉**。
  **核实 = 属实，是我上一轮引入的 plan 自相矛盾。** Step 10b 给 `_amain` 加了 advisory lock，紧接着的 Step 11 又让实施者把同一段替换成**不带锁的** `sets = await generate_batch(...)`。照字面执行 = CLI 失去锁、scheduler 保留锁 → 重新打开 R5-F2 刚堵上的洞（手工 CLI 撞 B4 → 覆盖已登记 zip → `content_hash` 失配）。
  **处置 = 采纳。** 整个删除 Step 11（Step 10b 的片段本就已是最终形态：既含锁、也已不含孤儿 `NotImplementedError` 捕获），并留下醒目提示"`_amain`/`_gen` 最终代码一律以 Step 10b 为准"。另补 codex 要求的 **CLI 级**锁测试（原先只测了 scheduler 侧）。
  **同类重犯**：R3-F2 也是"plan 给的指令自相矛盾/不可执行"。教训 = 每轮改完 plan，必须把**同一个函数的所有出现处**一起看，不能只改新增段。

### PF2-R7（2026-07-18，verdict = needs-attention；2 条 [design] + 1 条 [doc]，**均采纳**）

按本轮设的停止规则：**出现 [design] 类 → 继续**（未触发"只剩 [doc] 即收工"）。

- **F1 [design·high] 版本化 migration 用了 `CREATE TABLE IF NOT EXISTS`**。
  **核实 = 属实。** 若目标库已存在一张旧形状 `stock_coverage`（TEXT、缺 `dense_day_count`、缺 CHECK），migration **静默成功**、库却低于所声明的 1.12 契约；故障从"迁移期"挪到"B4 运行期"（PR 2b `SELECT dense_day_count` → UndefinedColumn）。静态 schema 测只解析预期 SQL，抓不到这种漂移。
  **处置 = 采纳。** forward.sql 改裸 `CREATE TABLE`（已存在即报错中止 = 正确 fail-closed），补 `test_migration_0004_stock_coverage_is_not_if_not_exists`。注：`schema.sql` 那份 fresh baseline 保留 `IF NOT EXISTS` 是对的，两者语义不同。

- **F2 [design·high] D9 边界日豁免会放过真实空洞** —— 打的是我自己 PF2-R1 的修法。
  **核实 = 属实。** 我 R1 把 d0 无条件豁免（只验存在性），一个**真的**只剩几根的残缺边界日照样过关；且我拿"B1 保证全或无"当免检理由，而 PF2-R6-F1 刚证明上游承诺不能当免检理由。
  **处置 = 采纳，但 codex 建议的公式我实测否掉了、换了个正确的。** codex 建议"从 before_cap/pivot 算允许的边界余数"。我先按 `(before_n % need) or need` 写，**跑 probe 发现它是自指的**：before_n 从窗口算 → 边界日被损坏 → before_n 同步变小 → 期望值跟着变小 → 恰好匹配损坏值 → **漏检**（实测边界日 80→60 时返回 True，本该 False）。
  **最终判据 = 边界日对照全量 bars**：d0 只是被切片的那天，但**它在库里必须完整**（PG 里该交易日应有 need 根）。内部日仍按窗口精确验。非自指，直接命中要防的坏数据。
  **6 情形 probe 全部符合预期**：生产 cap+完美数据 PASS／边界日全量 80→60 FAIL／内部整日缺席 FAIL／内部日 80→79 FAIL／cap=整数倍 PASS／cap=0 PASS。测试改写为对照 `full_bars`，并在 docstring 里钉死"自指写法已被实测否掉"。

- **F3 [doc·medium] `dense_day_count` 回归测有 NameError**：测里用了 `trading_date`，但该文件只从 `generate_training_sets` import 了四个符号 → 测试在验到守卫前就 NameError，"全绿"是假的。
  **处置 = 采纳**，补 `from qmt_normalize import trading_date`。

**本轮教训（重要）**：D9 这道门我改了三次才对（R1 粗豁免 → R7 自指公式 → R7 全量对照）。**前两次都是"看着对"**——直到写 probe 跑真数据才暴露。凡是"判据"类改动（尤其带取模/边界算术的），**必须构造正反例实跑**，不能靠读代码自评。

### PF2-R8（2026-07-18，verdict = needs-attention；**2 条均 [doc] 类 → 触发停止规则**）

- **F1 [doc·high] 锁的测试被排在其测试模块创建之前**：Step 10c 要求把 advisory-lock 测试追加进 `test_b2_reconnect_integration.py`，但该文件由 **Task 6** 才创建；照字面执行会造出缺 import 的半截文件、或被 Task 6 整file写入覆盖 → 「CLI/B4 并发生成」这条新防线**根本没被验证**。
  **处置 = 采纳。** Step 10c 改为「本步不写测试」，两条锁测试（含 `_must_not_run` helper）**移入 Task 6 的建file内容**（`sys`/`types` import 本就在那里），并显式标注「Task 6 跑完前不得声称并发防线已验证」。
  *（修完自检又发现：删掉 Step 10c 时把测试定义一并删了，已补回 Task 6 并用脚本验证定义位置。）*

- **F2 [doc·medium] `tempfile` 在被 import 之前就使用**：`assemble_from_windows` 用了 `tempfile.TemporaryDirectory()`，但 `import tempfile` 排在 Step 10；照字面执行，Task 5a 的第一个绿色检查点（Step 4）直接 `NameError`。
  **处置 = 采纳**，`import tempfile` 移到引入 `assemble_from_windows` 的同一步（Step 3）之首。

---

## 计划评审收口（8 轮，**codex 从未 approve**）

**如实记录**：`codex-attest.sh` 8 轮全部返回 `verdict=needs-attention`，**ledger 未更新**（无 attest 记录）。不写"已收敛"。

**转入实施的依据 = 本轮触发了预设的停止规则**（user 2026-07-18 批准）：R7 尚有 2 条 `[design]` 故继续；**R8 两条均为 `[doc]` 类（计划文档执行次序缺陷），无 `[design]` 类** → 按规则停止计划层评审，转入实施，由**实施后的 whole-branch codex 评审真代码**接手（那一道能真跑测试，不靠推理）。

**16 条 finding 全部处置完毕，零误报，无一条被驳回**：
| 轮 | finding | 类别 | 处置 |
|---|---|---|---|
| R1 | stock_coverage 无写入方 / 重试预算 | design | user 裁决改口径 / 全采纳 |
| R2 | 坏覆盖行中止 sweep / TOCTOU 未处理 | design | 全采纳 |
| R3 | 输家删赢家产物 / migration 测必挂 | design+doc | 全采纳（前者后被 R5 撤回） |
| R4 | 行先于产物可见 | design | → 触发 R5 架构核实 |
| R5 | 陈旧 .db 破坏自愈 / 残留非强制 | design | 全采纳，撤回已批残留 |
| R6 | dense 日历双盲 / Step 自相矛盾 | design+doc | 全采纳 |
| R7 | migration IF NOT EXISTS / D9 边界豁免 / 测试 NameError | design×2+doc | 全采纳（F2 换判据，codex 建议的公式经 probe 证伪） |
| R8 | 锁测试次序 / tempfile 次序 | doc×2 | 全采纳 → **停止规则触发** |

**实施阶段务必带上的三条教训**：
1. **判据类改动必须构造正反例实跑**——D9 改三次才对，前两次都"看着对"（粗豁免 → 自指公式 → 全量对照），probe 一跑才现原形。
2. **改 plan 只看新增段会漏**——R3-F2 与 R6-F2 两次栽在同一坑：同一函数在文档里出现多处，只改一处。
3. **写防护前先查架构不变量**——R2/R3/R4 三轮都在防一个被 D14 advisory lock 排除的并发场景，查一次只要两分钟。

---

## Dry-run 实证（2026-07-18，取代第 9 轮计划评审）

user 裁决：与其再跑一轮推理型评审，不如**把计划里的代码真跑一遍**。在 scratchpad 建了两个一次性工作区，逐字照本 plan 施工并运行。

### PR 2a — 全绿（19/19）

把 plan 给的 `forward.sql`/`rollback.sql`/`schema.sql` 三处改动落盘，再把 plan 里写的**每一条测试逐字**跑一遍。

**验证了我凭空写、从未执行过的东西**：
- `_column_type_names` 的 pglast AST 遍历（`typeName.names[-1].sval`）**可用**；
- 断言值全部正确：`DOUBLE PRECISION`→`float8`、`DECIMAL`→`numeric`、`TEXT`→`text`、`JSONB`→`jsonb`（这些我是**猜**的，猜对了）；
- `_sql_normalized` 去注释压空白后，所有子串断言真命中（PF2-R3-F2 的修复有效）；
- 两个 migration 文件都通过 libpg_query 真解析。

### PR 2b — 全绿（200 passed），但**dry-run 抓到 3 个 8 轮评审都没发现的问题**

复制 `backend/` 到 scratch（基线 170 passed，需一并复制 repo 根的 `tests/contract-fixtures/`，否则 12 个 `test_routes` 因路径失败），逐字应用 Task 4/5 的代码改动与全部新测试。

1. **[plan gap] `_gen` 加锁会打挂 3 个既有 scheduler 测试**。`tests/test_scheduler.py` 的 `_fake_pool()` 里 `class _FakeConn: pass` 没有 `fetchval` → `AttributeError`。plan 原本**只字未提**要改它，Step 12「期望全 passed」不可达。→ 已把确切改法写进 Step 10b。
2. **[plan gap] `test_build_generate_batch_real_b2_fail_closed_logs_error_returns_zero` 必须删**。它断言的是被移除的 `NotImplementedError` 路径，还逐字断言了被删掉的错误文案。plan 原本只含糊写「若挂了读它再决定」——不是可执行指令。→ 已改为明确删除 + 给出取代它的锁行为测试。
3. **[perf] 集成测把后端套件从 3.5s 拖到 63s**。plan 完全没提。→ 加两处缓存（fixture `lru_cache` + fake conn 的 `to_dict` 结果缓存）降到 **42s**，两处都已写进 Task 6，并在 Step 4 写明预期耗时与自查点。

### 同时被实证确认成立的关键设计

| 断言 | 结果 |
|---|---|
| 核心验收：真实 sweep 产出 ≥1 registered training set | ✅ |
| D9 边界日「对照全量 bars」判据（PF2-R7-F2 换的新判据） | ✅ 6 情形全对 |
| `exclude_starts` 在切 `max_retries` 之前过滤 | ✅ 前 9 候选全排除仍选中第 10 个 |
| `eligible_start_indices` 同 seed 两次调用顺序可复现 | ✅（该测依赖此假设） |
| 4 类坏覆盖行 + 反向区间 + `dense_day_count` 不符 → 全部干净 skip 不崩 | ✅ |
| 孤儿 zip / 陈旧 `.db` 自愈 | ✅ |
| CLI 与 `_gen` 两条路径的锁拒绝行为 | ✅ |
| `_FakeConn` 的 SQL 分派与生产代码实际查询匹配（未触发「未预期 SQL」断言） | ✅ |

### 结论

**PR 2a 与 PR 2b 的计划代码均可执行、全绿**（2a 19/19；2b 200 passed / 0 failed / 0 skipped）。
三个 dry-run 发现已回写。实施阶段应当接近机械照做。

**这轮验证的价值明显高于第 9 轮推理评审**：8 轮 codex 评审没能发现「加锁会打挂既有测试」这类问题——**因为那要真跑才知道**。
