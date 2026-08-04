# QMT Plan 4a — pilot 数据库护栏 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「建 pilot 库」与「`--reset` DROP 库」这两个不可逆动作，在任何 DDL 执行之前先通过一组机器强制的归属证明，使工具既不能在错的集群上建库，也不能删掉不属于本次运行的库。

**Architecture:** 新增一个纯 DB 模块 `backend/qmt_pilot_db.py`，对外暴露「名字护栏（纯函数）+ 集群闸 + 库级五闸 + 两阶段建库」四组能力。所有闸都 **fail-closed**：任何「证明不了」都等价于「拒绝」。模块**不做文件 IO**——它需要的文件派生标量（两份 schema 的 sha256、`export_log_sha256`、`output_dir`）一律由调用方（后续 PR 4c）传入已校验的值。连接获取用**依赖注入**（`connect` 可调用对象），使集群闸与库级闸在 host pytest 里可以用假 conn 测形状与控制流，而**语义**（锁可重入、DROP 是否真被顶住、`relkind` 覆盖面）交给真 PG 的 L2 脚本。

**Tech Stack:** Python 3.11 / asyncpg 0.30.0 / pytest 8.4.2 / PostgreSQL 15.12（Docker，L2 用）

**Spec:** `docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md`
**权威性**：spec §4 是唯一权威；§5/§6/§9 是导出视图。本计划与 spec 冲突时以 spec §4 为准，并回头改本计划。

---

## Global Constraints

- **`if/raise` 而非 `assert`**：`python -O` 会剥掉 `assert`。本模块**任何**守卫、任何内部不变量检查都不得用 `assert`（spec §4 第 2 条；Plan 3 P3-D12 已踩过）。
- **fail-closed 无例外**：连不进去 / 读不出来 / 取不到值 = **拒绝**。**绝不 `try/except: continue`**（spec §4 O1-F10）。
- **明令禁止** `DROP DATABASE … WITH (FORCE)` 与 `pg_terminate_backend`（spec §4 O1-F2 规定 2）。
- **库名一律走 `psycopg.sql.Identifier` 等价物**：asyncpg 无该 API，故本仓用 `_quote_ident()`（Task 1 定义），且库名**在此之前**必须已过 `assert_pilot_db_allowed`。字符串比较位（`pg_database.datname = $1`、`pilot_create_intent.dbname = $1`）**一律绑定参数**（spec §4）。
- **正则一律 `re.fullmatch`**，不得 `re.match` + `$`（`$` 接受尾随换行 → 闸判定的库与 DDL 作用的库不是同一个；spec §4 O1-F11）。
- **`CONTRACT_VERSION = "1.12"`**，必须与 `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7` 逐字相等（Task 2 有回归钉）。
- **全部新增测试必须 mutation 验证**：中和被测守卫 → 该测必须变红 → 复原。**由控制者亲验，不接受 subagent 自证**（spec §6.1）。
- **交付表述**：禁述「pilot 已完成」「100 股已出货」「真实数据接入完成」。4a 合并时的正确表述是「护栏建好、用假件与真-PG 脚本验过」（spec §7）。
- **测试运行方式**：`cd backend && python -m pytest tests/... -v`（`backend/tests/__init__.py` 把 `backend/` 注入 `sys.path`）。

### ✅ PR 拆分（2026-07-29 user 拍板，已生效）

生产代码实测：Task 1 后 287 行、**Task 2 后 405 行**，Task 3/4 估至 ~615 行，另加两个 L2 脚本。
破了本仓「每 PR ≤3 子项 ≤500 行」的约定，故按 spec §3 的天然切口拆两个 PR：

| PR | 内容 | 状态 |
|---|---|---|
| **4a-1** | 子项①② = Task 1（名字护栏 + 集群闸）+ Task 2（两阶段建库 + 九键 + 令牌派生） | 代码已就绪（405 行）|
| **4a-2** | 子项③ = Task 3（库级五闸 + 零对象例外 + `--reset-foreign`）+ Task 4（`--init-cluster-marker`）+ 两个 L2 真 PG 脚本 | 待做，基于 4a-1 |

**4a-2 必须基于 4a-1**（Task 3 的 `read_pilot_meta` 复用 Task 1 的 `read_pilot_meta_rows`，
Task 4 复用 Task 1 的集群闸与 Task 2 的 `INTENT_TTL_SECONDS`）。

⚠️ **两个 PR 都要过 `codex:adversarial-review`（本仓必需门），而 codex 配额 2026-08-02 10:32 才恢复。**

### ⚠️ 规模预警（原始记录，已由上表取代）

本仓约定 **每 PR ≤3 子项 ≤500 行**。4a 的三个子项来自 spec §3，但 spec §4 的闸逻辑量很大（六条零对象例外、七组结构断言、九键 `pilot_meta`、两阶段建库 + 三档崩溃恢复）。**Task 1 完成后立刻 `git diff --stat main...HEAD` 复核**：

- 若生产代码累计 **> 500 行**（不含测试与 SQL 文件），**停下来向控制者报告**，并按 spec §3 的天然切口拆成两个 PR：**4a-1 = 子项①②**（名字护栏 + 集群闸 + 两阶段建库）、**4a-2 = 子项③**（库级五闸 + 令牌 + 零对象例外）。
- **不要**为了压行数而合并闸、省掉断言或跳过 mutation 验证——那是用安全性换行数。

---

## File Structure

| 文件 | 责任 | 谁碰 |
|---|---|---|
| `backend/qmt_pilot_db.py` | **新增**。名字护栏（纯函数）、集群闸、库级五闸、两阶段建库。唯一有状态依赖的是传入的 `connect`。 | Task 1/2/3 |
| `backend/sql/pilot_cluster_schema.sql` | **新增**。**维护库专用表集合** = `pilot_cluster_marker` + `pilot_create_intent`。**绝不与 `pilot_schema.sql` 合并**。 | Task 1 |
| `backend/sql/pilot_schema.sql` | **新增**。pilot 库专用表：`pilot_meta` + `pilot_stock_source`。**不含** `pilot_cluster_marker`。 | Task 2 |
| `backend/tests/test_qmt_pilot_db.py` | **新增**。L1 host pytest：负向表驱动 + 假 conn 控制流断言。 | Task 1/2/3 |
| `backend/scripts/verify_pilot_db_lifecycle.py` | **新增**。L2 真 PG：集群闸五档 / 两阶段建库 / 陈旧库四件套 / 破坏性分支 / 令牌三跑 / 闸 0− 三库 / `initializing` 两向 / 崩溃恢复三档。 | Task 3 |
| `backend/scripts/verify_pilot_concurrency.py` | **新增**。L2 真 PG：同 seed 不同 DSN 的两进程，advisory lock 立刻失败返回。 | Task 3 |

**不修改任何既有文件。** 4a 是纯新增；CLI 接线属于 4c。

---

### Task 1: 名字护栏 + 集群闸 + 维护库 schema

**Files:**
- Create: `backend/qmt_pilot_db.py`
- Create: `backend/sql/pilot_cluster_schema.sql`
- Create: `backend/tests/test_qmt_pilot_db.py`

**Interfaces:**
- Consumes: 无（本 task 是模块地基）
- Produces:
  - `SEED_RE: re.Pattern` / `PILOT_DB_NAME_RE: re.Pattern`
  - `MAINTENANCE_TABLES: tuple[str, ...]` — 【维护库专用表集合】，值为 `("pilot_cluster_marker", "pilot_create_intent")`
  - `class PilotDbBoundaryError(Exception)` — 属性 `code: str`、`identity: dict | None`、`confirm_token: str | None`
  - `class PilotClusterBoundaryError(Exception)` — 属性 `code: str`
  - `def derive_db_name(seed: str) -> str`
  - `def assert_pilot_db_allowed(db_name: str, *, reset: bool, destructive: bool) -> None`
  - `def quote_ident(name: str) -> str`
  - `ABSOLUTELY_EMPTY_QUERIES: tuple[str, ...]` — 6 条【绝对空】SQL
  - `MAINTENANCE_EXEMPT_QUERY: str` — 闸 (iii) 专用豁免 SQL
  - `MAINTENANCE_EMPTY_QUERIES: tuple[str, ...]` — 闸 (iii) 用；= 豁免版 pg_class + 【绝对空】其余五条
  - `async def read_pilot_meta_rows(conn) -> dict[str, str]` — 闸 0− 形状判据的唯一实现，闸 (ii) 与 Task 3 的 `read_pilot_meta` 共用
  - `async def assert_cluster_allowed(maint_conn, *, connect, target_db: str) -> None`

---

- [ ] **Step 1: 写失败测试 —— 名字护栏的负向表**

Create `backend/tests/test_qmt_pilot_db.py`:

```python
# backend/tests/test_qmt_pilot_db.py
"""Plan 4a 护栏 L1 单测。Spec: docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md"""
from __future__ import annotations

import pytest

from qmt_pilot_db import (MAINTENANCE_TABLES, PilotDbBoundaryError,
                         assert_pilot_db_allowed, derive_db_name, quote_ident)


@pytest.mark.parametrize("bad_name", [
    "",                                   # 空串
    "klinedb",                            # 非前缀
    "postgres",                           # 非前缀（系统库）
    "kline_pilot_",                       # 前缀但 seed 为空
    "kline_pilot_A",                      # 大写非法
    "kline_pilot_x-y",                    # 连字符非法
    "kline_pilot_x; DROP DATABASE y",     # 注入形
    "kline_pilot_x\n",                    # ⚠️ 尾随换行：re.match+$ 会放行（O1-F11）
    "kline_pilot_" + "a" * 33,            # 超长（seed 上限 32）
])
def test_assert_pilot_db_allowed_rejects_bad_names(bad_name):
    with pytest.raises(PilotDbBoundaryError) as ei:
        assert_pilot_db_allowed(bad_name, reset=True, destructive=False)
    assert ei.value.code == "illegal_db_name"


def test_assert_pilot_db_allowed_accepts_legal_name():
    assert_pilot_db_allowed("kline_pilot_probe", reset=True, destructive=False) is None


def test_destructive_action_requires_reset():
    """DROP DATABASE 而 reset 非 True → 拒绝。"""
    with pytest.raises(PilotDbBoundaryError) as ei:
        assert_pilot_db_allowed("kline_pilot_probe", reset=False, destructive=True)
    assert ei.value.code == "destructive_without_reset"


def test_destructive_action_with_reset_passes():
    assert_pilot_db_allowed("kline_pilot_probe", reset=True, destructive=True) is None


def test_derive_db_name_rejects_bad_seed():
    for bad in ["", "A", "x-y", "a" * 33, "x\n"]:
        with pytest.raises(PilotDbBoundaryError) as ei:
            derive_db_name(bad)
        assert ei.value.code == "illegal_seed"


def test_derive_db_name_happy():
    assert derive_db_name("probe_01") == "kline_pilot_probe_01"


def test_quote_ident_doubles_embedded_quotes():
    assert quote_ident('kline_pilot_x') == '"kline_pilot_x"'
    assert quote_ident('a"b') == '"a""b"'


def test_maintenance_tables_is_the_named_set():
    """【维护库专用表集合】必须是具名常量，不得在各处点名单表（spec O4-F1：同一个洞开过三次）。"""
    assert MAINTENANCE_TABLES == ("pilot_cluster_marker", "pilot_create_intent")
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'qmt_pilot_db'`

- [ ] **Step 3: 写最小实现 —— 纯函数部分**

Create `backend/qmt_pilot_db.py`:

```python
# backend/qmt_pilot_db.py
"""QMT Plan 4a：pilot 数据库护栏（纯 DB，零文件 IO，零网络）。

Spec: docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md

设计约束（逐条来自 spec §4，改动前先读 spec）：
  · 一切守卫用 if/raise，**绝不用 assert**（python -O 会剥掉它）。
  · 一切「证明不了」等价于「拒绝」——绝不 try/except: continue。
  · 本模块不做文件 IO：两份 schema 的 sha256、export_log_sha256、output_dir
    一律由调用方传入**已校验**的标量；取不到 = fail-closed，绝不跳过闸 0b。
"""
from __future__ import annotations

import re

# CLI 只收 --seed；库名恒为 kline_pilot_{seed}，用户无法传入任意库名。
SEED_RE = re.compile(r"[a-z0-9_]{1,32}")
PILOT_DB_NAME_RE = re.compile(r"kline_pilot_[a-z0-9_]{1,32}")

# 【维护库专用表集合】—— spec §4 的唯一权威定义。
# ⚠️ 凡涉及豁免一律引用本常量，**不得点名单张表**：同一个洞在 spec 里被打开过三次
# （P1-F4 只修索引豁免、P1r3-F1b 只修 SQL 块、O4-F1 才发现散文/§5/§9 三处从未跟上）。
MAINTENANCE_TABLES = ("pilot_cluster_marker", "pilot_create_intent")


class PilotDbBoundaryError(Exception):
    """库级边界失败。code 进 4c 报告的 db_boundary_error 字段。"""

    def __init__(self, code: str, message: str, *,
                 identity: dict | None = None, confirm_token: str | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.identity = identity
        # ⚠️ confirm_token 只进 stderr，**绝不进报告 JSON**（spec §9-1w：
        # 否则 wrapper 可「读报告取令牌再重跑」，知情同意退化成两步自动化）。
        self.confirm_token = confirm_token


class PilotClusterBoundaryError(Exception):
    """集群级边界失败。code 进 4c 报告的 cluster_boundary_error 字段。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def quote_ident(name: str) -> str:
    """把标识符包成双引号形式（asyncpg 无 psycopg.sql.Identifier 的等价物）。

    ⚠️ 这**不是**护栏：调用方必须已经让 name 过了 assert_pilot_db_allowed。
    """
    return '"' + name.replace('"', '""') + '"'


def derive_db_name(seed: str) -> str:
    if not isinstance(seed, str) or SEED_RE.fullmatch(seed) is None:
        raise PilotDbBoundaryError(
            "illegal_seed",
            f"--seed 必须匹配 ^[a-z0-9_]{{1,32}}$，实得 {seed!r}",
        )
    return f"kline_pilot_{seed}"


def assert_pilot_db_allowed(db_name: str, *, reset: bool, destructive: bool) -> None:
    """任何 DDL 之前调用。

    db_name 不匹配 ^kline_pilot_[a-z0-9_]{1,32}$ → raise；
    destructive（DROP DATABASE）而 reset 非 True → raise。

    ⚠️ 用 re.fullmatch 而不是 re.match + '$'：后者接受尾随换行，会让
    「闸判定的库」与「DDL 实际作用的库」不是同一个（spec O1-F11）。
    """
    if not isinstance(db_name, str) or PILOT_DB_NAME_RE.fullmatch(db_name) is None:
        raise PilotDbBoundaryError(
            "illegal_db_name",
            f"库名必须匹配 ^kline_pilot_[a-z0-9_]{{1,32}}$，实得 {db_name!r}",
        )
    if destructive and reset is not True:
        raise PilotDbBoundaryError(
            "destructive_without_reset",
            f"对 {db_name} 的破坏性动作需要 --reset；本次未带",
        )
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: PASS（9 个参数化 + 7 个用例全绿）

- [ ] **Step 5: mutation 验证纯函数守卫**

逐条中和守卫，确认对应测试变红，然后**复原**：

| 中和方式 | 必须变红的测试 |
|---|---|
| `PILOT_DB_NAME_RE.fullmatch` → `PILOT_DB_NAME_RE.match` | `test_assert_pilot_db_allowed_rejects_bad_names[kline_pilot_x\n]` |
| `if destructive and reset is not True:` → `if False:` | `test_destructive_action_requires_reset` |
| `SEED_RE.fullmatch` → `SEED_RE.match` | `test_derive_db_name_rejects_bad_seed` |

每条改完跑 `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`，**确认是预期的那一条变红**（不是别的），然后复原。**把三次的红色输出贴给控制者。**

> ⚠️ **复原方式：精确回退那一处改动（Edit 反向替换），不要 `git checkout <file>`。**
> mutation 通常发生在**本 task 尚未提交**的时候，`git checkout` 会把整个 task 的实现一起抹掉。
> （Task 2 的实施者识破了这条指令并自行改用精确回退——否则会丢掉一整个 task 的工作。）

- [ ] **Step 6: 写维护库 schema 文件**

Create `backend/sql/pilot_cluster_schema.sql`:

```sql
-- backend/sql/pilot_cluster_schema.sql
-- QMT Plan 4a：**维护库专用表集合**。apply 到 --maintenance-dsn 指向的那个库。
--
-- ⚠️ 绝不与 backend/sql/pilot_schema.sql 合并（spec §4 P1-F5）：
--   · 合并后 apply 到**维护库**会让它多出 pilot_meta / pilot_stock_source 两张表
--     + 两个 pkey 索引 → 闸 (iii)「维护库自身也是【绝对空】」永久不过 → 工具彻底不可用；
--   · 反过来把 marker 放进 pilot_schema.sql，会让**每个 pilot 库**都多出一张空的
--     pilot_cluster_marker，而闸 2 的七组闭合清单里既没有它、也没定义「遇到未登记的表怎么办」。
--
-- ⚠️ 本文件的表构成【维护库专用表集合】= qmt_pilot_db.MAINTENANCE_TABLES。
--   新增成员时必须同时改：MAINTENANCE_TABLES 常量 / 闸 (iii) 豁免 SQL 的 ARRAY /
--   闸 (i) 的形状断言 / spec §4 集合定义 / spec §5 / spec §9-1a。缺一即闸恒假。

-- 授权「碰这台集群」的凭据。闸 (i) 先验形状再读值。
CREATE TABLE IF NOT EXISTS pilot_cluster_marker (purpose TEXT PRIMARY KEY);

-- 零对象例外第 6 条的判据：证明「这个空库是本工具刚刚声明过要建的」。
-- 写在 CREATE DATABASE **之前**，故没有窗口。
CREATE TABLE IF NOT EXISTS pilot_create_intent (
    dbname     TEXT PRIMARY KEY,
    seed       TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

- [ ] **Step 7: 写失败测试 —— 【绝对空】SQL 与闸 (iii) 豁免 SQL 的形状**

Append to `backend/tests/test_qmt_pilot_db.py`:

```python
from qmt_pilot_db import ABSOLUTELY_EMPTY_QUERIES, MAINTENANCE_EXEMPT_QUERY


def test_absolutely_empty_is_whitelist_not_relkind_enumeration():
    """【绝对空】必须是白名单式：pg_class 不加 relkind 过滤。

    真 postgres:15.12 实测：一个只含**物化视图**（relkind='m'，1000 行真实数据）的库，
    在 information_schema.tables 与 relkind IN ('r','v','S') 两种写法下都返回 0
    → 被判成残骸 → 不过闸 0−/0/0b、不要令牌、无提示，直接 DROP DATABASE（spec O1-F1）。
    """
    joined = " ".join(ABSOLUTELY_EMPTY_QUERIES)
    assert "information_schema.tables" not in joined
    assert "relkind IN" not in joined and "relkind in" not in joined
    # 六个来源缺一不可
    for src in ("pg_class", "pg_namespace", "pg_proc", "pg_type",
                "pg_extension", "pg_largeobject_metadata"):
        assert src in joined, f"【绝对空】漏了 {src}"


def test_maintenance_exempt_query_covers_the_whole_set_via_to_regclass():
    """闸 (iii) 豁免必须覆盖【维护库专用表集合】的**全部**成员及各自索引。

    真 PG 四态实测（spec P1-F4 + P1r3-F1b + O4-F1）：
      · 只按表名排除 → 主键索引仍被计入 → 闸恒假；
      · 只豁免 marker → 两表齐全时返回 2 → 闸又一次恒假；
      · 用 ::regclass 而非 to_regclass → 表不存在时**抛异常**，--init-cluster-marker 永远跑不了。
    """
    for tbl in MAINTENANCE_TABLES:
        assert f"to_regclass('public.{tbl}')" in MAINTENANCE_EXEMPT_QUERY, f"豁免漏了 {tbl}"
    assert "::regclass" not in MAINTENANCE_EXEMPT_QUERY.replace("to_regclass", "")
    # 索引豁免：pg_index.indrelid（**不是** pg_depend——marker_pkey 的 refclassid 是
    # pg_constraint 而非 pg_class，用 pg_depend 会两个方向都错，spec P1r3-F1b 实测）
    assert "pg_index" in MAINTENANCE_EXEMPT_QUERY
    assert "indrelid" in MAINTENANCE_EXEMPT_QUERY
    assert "pg_depend" not in MAINTENANCE_EXEMPT_QUERY
```

- [ ] **Step 8: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -k "absolutely_empty or exempt" -v`
Expected: FAIL — `ImportError: cannot import name 'ABSOLUTELY_EMPTY_QUERIES'`

- [ ] **Step 9: 实现两组 SQL 常量**

Append to `backend/qmt_pilot_db.py`:

```python
# ── 【绝对空】的唯一判据（spec §4，O1-F1）───────────────────────────────
# 本 spec 唯一一条**无归属证明、无令牌**的 DROP DATABASE 授权就建立在它上面，
# 故必须是白名单式（「除了这些之外什么都不许有」），**不得枚举 relkind**：
# 真 postgres:15.12 实测，一个只含物化视图（relkind='m'）的库会逃过
# information_schema.tables 与 relkind IN ('r','v','S') 两种写法。
ABSOLUTELY_EMPTY_QUERIES = (
    """SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast'""",
    """SELECT count(*) FROM pg_namespace
        WHERE nspname NOT IN ('pg_catalog','information_schema','public') AND nspname !~ '^pg_'""",
    """SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema')""",
    # ⚠️ typtype 必须是**白名单** IN ('e','d','c','r')，且必须排除**表派生的复合类型**。
    #    写成 `typtype <> 'b'` 会数到每张表自带的复合行类型 → 维护库有那两张专用表时
    #    闸 (iii) **恒假**（= 同一个「闸恒假」的洞在 pg_type 维度上的第四次复现）。
    """SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND t.typtype IN ('e','d','c','r')
          AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid)""",
    "SELECT count(*) FROM pg_extension WHERE extname NOT IN ('plpgsql')",
    "SELECT count(*) FROM pg_largeobject_metadata",
)


# ── 闸 (iii) 专用豁免（**只用于 (iii)**）──────────────────────────────
# 闸 (ii) 的空库豁免与零对象例外第 3 条用**无豁免的裸【绝对空】**。
#
# ⚠️ ARRAY 的成员 = MAINTENANCE_TABLES 的全部成员；集合增长时**本处必须同步**。
# ⚠️ 索引豁免走 pg_index.indrelid，**不是 pg_depend**：真 PG 实测
#    pilot_cluster_marker_pkey 在 pg_depend 里的 refclassid 是 pg_constraint
#    （refobjid 是**约束**的 oid），用 pg_depend 写会两个方向都错。
# ⚠️ 用 to_regclass 而非 ::regclass：后者在表不存在时**抛异常**而不是返回 NULL，
#    于是 --init-cluster-marker（它的前置状态就是「表还不存在」）永远跑不了。
MAINTENANCE_EXEMPT_QUERY = """
WITH m AS (SELECT ARRAY(SELECT o FROM unnest(ARRAY[
             to_regclass('public.pilot_cluster_marker'),
             to_regclass('public.pilot_create_intent')]) AS o WHERE o IS NOT NULL) AS moids)
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, m
 WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^pg_toast'
   AND NOT (c.oid = ANY(m.moids))
   AND NOT (c.relkind = 'i' AND EXISTS (SELECT 1 FROM pg_index i
              WHERE i.indexrelid = c.oid AND i.indrelid = ANY(m.moids)))
"""
# ⚠️ 必须定义在 MAINTENANCE_EXEMPT_QUERY **之后**（否则 import 时 NameError）。
# 闸 (iii) 专用：【绝对空】六条中，**只有 pg_class 那条换成豁免版**，其余五条原样跑。
# 只跑豁免版那一条（= 只查 pg_class）会让空的 `CREATE SCHEMA production`、
# extension（`pg_stat_statements` 装在 postgres 库极常见）、函数、大对象**全部逃过**，
# 而闸 (iii) 存在的全部理由就是「挡住藏在默认库里的生产对象」。
MAINTENANCE_EMPTY_QUERIES = (MAINTENANCE_EXEMPT_QUERY,) + ABSOLUTELY_EMPTY_QUERIES[1:]
```

- [ ] **Step 10: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: PASS（全部）

- [ ] **Step 11: 写失败测试 —— 集群闸三条 (i)(ii)(iii)**

Append to `backend/tests/test_qmt_pilot_db.py`:

```python
import asyncio

from qmt_pilot_db import PilotClusterBoundaryError, assert_cluster_allowed


class _FakeConn:
    """按查询关键词返回预设值的假 conn。

    ⚠️ 它只能验**控制流与形状**，验不了语义（relkind 覆盖面、锁可重入、DROP 是否被顶住）。
    那些一律交给 backend/scripts/verify_pilot_db_lifecycle.py 的真 PG 断言
    （spec §6.2：假件会静默建模错误语义，本仓已实证吃过亏）。
    """

    def __init__(self, *, marker_rows=None, empty_counts=None, exempt_count=0,
                 databases=(), meta_rows=None, fail_connect=False):
        self.marker_rows = marker_rows if marker_rows is not None else [
            {"purpose": "qmt_pilot_disposable_cluster"}]
        self.empty_counts = empty_counts if empty_counts is not None else [0] * 6
        self.exempt_count = exempt_count
        self.databases = list(databases)
        self.meta_rows = meta_rows or []
        self.fail_connect = fail_connect
        self.closed = False
        self.executed: list[str] = []

    async def fetch(self, query, *args):
        if "pilot_cluster_marker" in query and "to_regclass" not in query:
            return list(self.marker_rows)
        if "pg_database" in query:
            return [{"datname": d} for d in self.databases]
        if "pilot_meta" in query:
            return list(self.meta_rows)
        raise AssertionError(f"_FakeConn 收到未预期的 fetch: {query[:80]}")

    async def fetchval(self, query, *args):
        if "to_regclass" in query:
            return self.exempt_count
        if "pg_class" in query or "pg_namespace" in query or "pg_proc" in query \
                or "pg_type" in query or "pg_extension" in query \
                or "pg_largeobject_metadata" in query:
            return self.empty_counts.pop(0)
        raise AssertionError(f"_FakeConn 收到未预期的 fetchval: {query[:80]}")

    async def execute(self, query, *args):
        self.executed.append(query)

    async def close(self):
        self.closed = True


def _connector(mapping):
    """返回一个 connect(dbname) -> conn 的可调用对象；dbname 不在 mapping 里即模拟连不上。"""
    async def _connect(dbname):
        if dbname not in mapping:
            raise ConnectionError(f"cannot connect to {dbname}")
        return mapping[dbname]
    return _connect


def test_cluster_gate_i_rejects_missing_marker():
    conn = _FakeConn(marker_rows=[])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "no_marker"
    assert conn.executed == [], "闸未过就不许执行任何 DDL"


def test_cluster_gate_i_rejects_two_marker_rows():
    """两行时 SELECT ... LIMIT 1（无 ORDER BY）与 EXISTS(...) 给出相反结论
    → 同一台集群能不能被建库/DROP 取决于实现细节（spec O1-F8）。"""
    conn = _FakeConn(marker_rows=[{"purpose": "qmt_pilot_disposable_cluster"},
                                  {"purpose": "something_else"}])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "no_marker"


def test_cluster_gate_ii_rejects_unrelated_database():
    conn = _FakeConn(databases=["production_db"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "unrelated_database"


def test_cluster_gate_ii_rejects_prefix_named_db_without_pilot_meta():
    """前缀名不是归属证明：共享集群上一个恰好叫 kline_pilot_xxx 的**非空**无关库，
    会让整台集群被误判为「干净」（spec R22-F1，「形状不是归属」的第五次）。"""
    other = _FakeConn(meta_rows=[], empty_counts=[3, 0, 0, 0, 0, 0])  # 非空
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": other}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_cluster_gate_ii_exempts_absolutely_empty_remnant():
    """零用户对象的同名库是「崩在 CREATE 与写 pilot_meta 之间的残骸」→ **放行集群闸**。
    不豁免的话，一个残骸会把整台集群对所有 seed 锁死（spec R55-F1）。"""
    remnant = _FakeConn(meta_rows=[], empty_counts=[0] * 6)
    conn = _FakeConn(databases=["kline_pilot_other"])
    asyncio.run(assert_cluster_allowed(
        conn, connect=_connector({"kline_pilot_other": remnant}),
        target_db="kline_pilot_probe"))  # 不抛 = 放行


def test_cluster_gate_ii_skips_target_db_itself():
    """目标库由闸 0−/0/0b 全权负责。不排除它的话，「目标库已存在、非空、无 pilot_meta」
    这一档会先被集群闸拒掉，报「这台集群不干净」，而真相是「你的目标库不是本工具建的」
    ——下一步动作「人工删这个库」与报告完全对不上（spec P1r3-F4）。"""
    conn = _FakeConn(databases=["kline_pilot_probe"])
    # connect 映射为空：若实现去连了目标库，会抛 ConnectionError 而非干净返回
    asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                       target_db="kline_pilot_probe"))


def test_cluster_gate_ii_connect_failure_is_fail_closed():
    """datallowconn=false / datconnlimit=0 / 无 CONNECT 权限 / 正被别的会话删除 ——
    任一导致「连进去验归属」抛异常时，判定为「无法证明归属」→ 拒绝。
    **绝不 try/except: continue**（那是 fail-open，spec O1-F10）。"""
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_cluster_gate_iii_rejects_dirty_maintenance_db():
    """「没有别的数据库」≠「这台集群没在用」——生产对象完全可以就放在默认 postgres 库里
    （spec R20-F2）。豁免后仍有 1 个对象即拒。"""
    conn = _FakeConn(exempt_count=1)
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "maintenance_db_not_empty"


def test_cluster_gate_iii_checks_all_six_absolute_empty_sources():
    """闸 (iii) 必须跑**六条**，不是只跑 pg_class 那条豁免版（O4-T1-B1）。

    只跑一条时，维护库里一个空的 `CREATE SCHEMA production`、一个 extension
    （`pg_stat_statements` 装在 postgres 库极常见）、一个函数、一个孤儿大对象
    **全部逃过**——而闸 (iii) 存在的全部理由就是「挡住藏在默认库里的生产对象」。
    """
    from qmt_pilot_db import MAINTENANCE_EMPTY_QUERIES
    assert len(MAINTENANCE_EMPTY_QUERIES) == 6
    assert MAINTENANCE_EMPTY_QUERIES[0] is MAINTENANCE_EXEMPT_QUERY
    for src in ("pg_namespace", "pg_proc", "pg_type", "pg_extension", "pg_largeobject_metadata"):
        assert any(src in q for q in MAINTENANCE_EMPTY_QUERIES[1:]), f"闸 (iii) 漏查 {src}"


@pytest.mark.parametrize("idx,label", [(1, "空的用户 schema"), (2, "用户函数"),
                                       (3, "自定义类型"), (4, "extension"), (5, "大对象")])
def test_cluster_gate_iii_rejects_each_non_pg_class_source(idx, label):
    """逐个来源造反例：第 idx 条判据不为 0 时闸 (iii) 必须拒。"""
    counts = [0] * 6
    counts[idx] = 1

    class _PerSource(_FakeConn):
        async def fetchval(self, query, *args):
            from qmt_pilot_db import MAINTENANCE_EMPTY_QUERIES
            for i, q in enumerate(MAINTENANCE_EMPTY_QUERIES):
                if q == query:
                    return counts[i]
            return await super().fetchval(query, *args)

    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(_PerSource(), connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "maintenance_db_not_empty", f"{label} 没被闸 (iii) 挡住"


def test_pg_type_query_excludes_table_derived_composite_types():
    """`typtype <> 'b'` 会数到每张表自带的复合行类型 → 维护库有那两张专用表时
    闸 (iii) **恒假**（同一个「闸恒假」的洞在 pg_type 维度上的第四次复现）。"""
    pg_type_q = [q for q in ABSOLUTELY_EMPTY_QUERIES if "pg_type" in q][0]
    assert "typtype IN ('e','d','c','r')" in pg_type_q, "typtype 必须白名单式"
    assert "<> 'b'" not in pg_type_q
    assert "c.reltype = t.oid" in pg_type_q, "必须排除表派生的复合类型"


def test_cluster_gate_ii_rejects_ambiguous_pilot_meta_in_other_db():
    """别的 pilot 库若 `key` 上没唯一约束、塞进两行 `tool`，裸 dict 推导式会**静默取最后一行**
    → 哪一行「赢」取决于 PG 的 tie-break → **同一台集群这次判干净、下次判不干净**
    （spec §4 P1-F7：这条纪律此前只落在 marker 上）。"""
    ambiguous = _FakeConn(
        meta_rows=[{"key": "tool", "value": "something_else"},
                   {"key": "tool", "value": "qmt_pilot"}],
        empty_counts=[3, 0, 0, 0, 0, 0])          # 非空 → 不走残骸豁免
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": ambiguous}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_cluster_gate_rejects_illegal_target_db_name():
    """`target_db` 会让闸 (ii) **整个跳过**那个名字的库，故它自己必须先过名字护栏（O4-W3）。

    传一个生产库的名字进来 → 闸 (ii) 不会枚举到它 → 三条闸全过 →
    工具在生产集群上建库灌数据（spec §1 的风险 ①）。
    """
    conn = _FakeConn(databases=["production_db"])
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="production_db"))
    assert ei.value.code == "illegal_db_name"


def test_cluster_gate_allows_none_target_for_init_path():
    """`--init-cluster-marker` 路径没有目标库，显式传 None 必须放行。"""
    asyncio.run(assert_cluster_allowed(_FakeConn(), connect=_connector({}), target_db=None))


def test_cluster_gate_ii_ownership_probe_failure_is_fail_closed():
    """spec O1-F10：**任一**导致「连进去验归属」抛异常时都判 `unowned_pilot_database`（O4-W4）。

    此前只包了 `connect()`；`_is_absolutely_empty` 或 `fetchval` 抛（该库被并发 DROP、
    连接 reset）会逃成裸 asyncpg 异常 → 4c 记成 `FAIL_INFRASTRUCTURE`，
    而 §9-1w 明令禁止「把一次成功的守卫记成环境故障」。
    """
    class _BoomOnEmptyCheck(_FakeConn):
        async def fetchval(self, query, *args):
            raise RuntimeError("模拟：探测【绝对空】时该库被并发 DROP")

    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": _BoomOnEmptyCheck(meta_rows=[])}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_cluster_gate_all_pass_executes_no_ddl():
    conn = _FakeConn()
    asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                       target_db="kline_pilot_probe"))
    assert conn.executed == []
```

- [ ] **Step 12: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -k cluster -v`
Expected: FAIL — `ImportError: cannot import name 'assert_cluster_allowed'`

- [ ] **Step 13: 实现集群闸**

Append to `backend/qmt_pilot_db.py`:

```python
MARKER_PURPOSE = "qmt_pilot_disposable_cluster"

# 系统库判据用 datistemplate，**不用名字 glob**：一个叫 `templates` 的**生产库**
# 会被 `template*` 跳过（spec O1-F3）。顺带解掉「维护 DSN 必须连 postgres」这个隐性约束。
_LIST_DATABASES_SQL = """
SELECT datname FROM pg_database
 WHERE datistemplate = false AND datname <> current_database()
"""

_READ_MARKER_SQL = "SELECT purpose FROM pilot_cluster_marker ORDER BY purpose"

_READ_META_SQL = "SELECT key, value FROM pilot_meta ORDER BY key"


async def read_pilot_meta_rows(conn) -> dict[str, str]:
    """读 `pilot_meta` 并**强制形状**：任一 key 出现多行即拒。

    这是「闸 0− 的形状判据」的**唯一实现**，闸 (ii)（验别的 pilot 库）与
    闸 0−（验目标库）**必须共用它**——spec §4 P1-F7 明写：marker 的「不得 LIMIT 1」
    纪律与闸 0− 此前「都只落在了各自发现它的那个对象上」。

    ⚠️ **「`key` 上有主键/唯一约束」这条断言属于闸 0−，不是闸 2**（O4-W2 更正）：
    spec §9-3c 解释过为什么它不能挂在闸 2 下 —— **闸 2 在 `--reset` 时不跑**，
    而 `--reset` 的破坏性恰恰建立在这张表上（R80-F1）。推给闸 2 就是把它修掉的洞放回来。
    本函数做的是**运行时**判据（真读到重复就拒）；「唯一约束是否存在」的**结构性**断言
    由 4a-2 的闸 0− 补上（`pilot_meta.key` 有主键或等价唯一约束、`value` 为 `text`）。
    ⚠️ **4a-2 的实施者：不要把这条推给闸 2。**

    表不存在等读失败**原样抛出**，由调用方按各自语义处置
    （闸 (ii)：落到「零用户对象即残骸」那档豁免；闸 0−：判 `not_owned`）。
    """
    seen: dict[str, str] = {}
    for r in await conn.fetch(_READ_META_SQL):
        key = r["key"]
        if key in seen:
            raise PilotDbBoundaryError(
                "pilot_meta_ambiguous",
                f"pilot_meta 里 {key!r} 出现多行——key 上缺唯一约束，"
                f"读到哪一行取决于实现",
            )
        seen[key] = r["value"]
    return seen


async def _is_absolutely_empty(conn) -> bool:
    """裸【绝对空】：六条查询全部返回 0 才算空。无任何豁免。"""
    for q in ABSOLUTELY_EMPTY_QUERIES:
        if await conn.fetchval(q) != 0:
            return False
    return True


async def assert_cluster_allowed(maint_conn, *, connect, target_db: str | None) -> None:
    """集群闸 (i)(ii)(iii) —— **每次运行都跑**，在任何 CREATE/DROP DATABASE/导入之前。

    (i)   维护库有合法 pilot_cluster_marker（先验形状再读值）
    (ii)  现查 pg_database 每一个非系统库**且非本次目标库**：名字不匹配 kline_pilot_* 即拒；
          匹配的逐个连进去验归属；零用户对象的同名库是残骸 → 放行
    (iii) 现查维护库自身，除【维护库专用表集合】外绝对空

    ⚠️ (ii) 必须**每次现查**，不能只在初始化时查一次（spec R17-F1，典型 TOCTOU）：
       标记只证明「有人曾声明过」，现查才证明「现在仍然成立」。

    raises: PilotClusterBoundaryError（code ∈ no_marker / unrelated_database /
            unowned_pilot_database / maintenance_db_not_empty）
    """
    # ⚠️ `target_db` 会让闸 (ii) **整个跳过**那个名字的库，故它自己必须先过名字护栏
    #    （O4-W3）：传进来的若是一个生产库的名字，闸 (ii) 就不会枚举到它 →
    #    三条闸全过 → 工具在生产集群上建库灌数据（spec §1 的风险 ①）。
    #    `--init-cluster-marker` 路径没有目标库，显式传 None。
    if target_db is not None:
        assert_pilot_db_allowed(target_db, reset=True, destructive=False)

    # ── (i) 标记存在且形状合规 ────────────────────────────────────────
    # 先验形状再读值（spec R21-F3：一个能授权删东西的结构，自己必须先被校验）。
    # ⚠️ 不得实现成 SELECT purpose FROM pilot_cluster_marker LIMIT 1（无 ORDER BY，
    #    返回行任意）——两行时它与 EXISTS(… WHERE purpose='…') 给出相反结论。
    try:
        rows = await maint_conn.fetch(_READ_MARKER_SQL)
    except Exception as exc:                      # 表不存在 / 无权限 / 连接问题
        raise PilotClusterBoundaryError(
            "no_marker",
            f"维护库读不出 pilot_cluster_marker：{exc}。"
            f"请先跑 qmt_pilot --init-cluster-marker --maintenance-dsn …",
        ) from exc
    if len(rows) != 1 or rows[0]["purpose"] != MARKER_PURPOSE:
        raise PilotClusterBoundaryError(
            "no_marker",
            f"pilot_cluster_marker 必须恰好一行且 purpose = {MARKER_PURPOSE!r}，"
            f"实得 {len(rows)} 行：{[r['purpose'] for r in rows]}",
        )

    # ── (ii) 现查 pg_database ─────────────────────────────────────────
    for row in await maint_conn.fetch(_LIST_DATABASES_SQL):
        name = row["datname"]
        if name == target_db:
            # 目标库由闸 0−/0/0b 全权负责（spec P1r3-F4）。
            continue
        if PILOT_DB_NAME_RE.fullmatch(name) is None:
            raise PilotClusterBoundaryError(
                "unrelated_database",
                f"集群里存在无关数据库 {name!r}——这台集群不是给 pilot 用的一次性环境",
            )
        # 前缀名不是归属证明：逐个连进去问它自己是谁（spec R22-F1）。
        # ⚠️ 连不进去 = 无法证明归属 = 拒绝。绝不 try/except: continue（fail-open）。
        try:
            other = await connect(name)
        except Exception as exc:
            raise PilotClusterBoundaryError(
                "unowned_pilot_database",
                f"连不进 {name!r}（{exc}）→ 无法证明它的归属。"
                f"datallowconn=false / datconnlimit=0 / 无 CONNECT 权限都会落到这里",
            ) from exc
        try:
            # ⚠️ **必须复用闸 0− 的同一组形状判据**（spec §4 P1-F7）：
            #    裸 `{r["key"]: r["value"] for r in rows}` 在重复 key 时**静默取最后一行**，
            #    于是一个 `key` 上没有唯一约束、塞进两行 `tool` 的库，
            #    哪一行「赢」取决于 PG 对同 ORDER BY 值的 tie-break → **同一台集群这次判干净、
            #    下次判不干净**。spec 明写这条纪律此前「只落在了各自发现它的那个对象上」。
            try:
                meta = await read_pilot_meta_rows(other)
            except Exception:
                # 表不存在 / 形状不合规（重复 key）→ **都不算合法归属证明**。
                # 不在这里拒绝：下面还有「零用户对象即残骸」这一档豁免（spec §4）。
                meta = {}
            if meta.get("tool") == "qmt_pilot":
                continue                          # 是本工具建的另一个 pilot 库，放行
            # 无合法 pilot_meta：零用户对象的是残骸（放行），非空的一律拒。
            if await _is_absolutely_empty(other):
                continue
            raise PilotClusterBoundaryError(
                "unowned_pilot_database",
                f"{name!r} 名字匹配 kline_pilot_* 但没有合法 pilot_meta 且非空"
                f"——前缀名不是归属证明",
            )
        except PilotClusterBoundaryError:
            raise                                   # 本闸自己的判定，原样上抛
        except Exception as exc:
            # ⚠️ spec §4 O1-F10 写的是「**任一**导致『连进去验归属』抛异常时 →
            #    unowned_pilot_database」。此前只包了 connect()，而 _is_absolutely_empty
            #    或 fetchval 抛（该库被并发 DROP、连接 reset）会逃成裸 asyncpg 异常
            #    → 4c 记成 FAIL_INFRASTRUCTURE，而 §9-1w 明令禁止
            #    （把一次成功的守卫记成环境故障）。
            raise PilotClusterBoundaryError(
                "unowned_pilot_database",
                f"验 {name!r} 的归属时失败（{exc}）→ 无法证明它的归属",
            ) from exc
        finally:
            # 读一律短连接：DROP 之前本进程对目标库的连接数必须为 0（spec O1-F2）。
            await other.close()

    # ── (iii) 维护库自身也是【绝对空】（除【维护库专用表集合】外）────────
    # spec §4：「在维护库里**按上面那组 SQL 查**……也不得有非默认的用户 schema」
    # ——「那组 SQL」是六条，不是一条。
    for idx, q in enumerate(MAINTENANCE_EMPTY_QUERIES):
        leftover = await maint_conn.fetchval(q)
        if leftover != 0:
            raise PilotClusterBoundaryError(
                "maintenance_db_not_empty",
                f"维护库除 {MAINTENANCE_TABLES} 外还有 {leftover} 个用户对象"
                f"（【绝对空】第 {idx + 1} 条判据不为 0）"
                f"——「没有别的数据库」不等于「这台集群没在用」",
            )
```

- [ ] **Step 14: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: PASS（全部，约 25 个用例）

- [ ] **Step 15: mutation 验证集群闸**

| 中和方式 | 必须变红的测试 |
|---|---|
| 闸 (i) 的 `len(rows) != 1` → `len(rows) < 1` | `test_cluster_gate_i_rejects_two_marker_rows` |
| 闸 (ii) 的 `except Exception as exc: raise ...` → `except Exception: continue` | `test_cluster_gate_ii_connect_failure_is_fail_closed` |
| 闸 (ii) 的 `if name == target_db: continue` 整块删掉 | `test_cluster_gate_ii_skips_target_db_itself` |
| 闸 (ii) 的 `if await _is_absolutely_empty(other): continue` 删掉 | `test_cluster_gate_ii_exempts_absolutely_empty_remnant` |
| 闸 (iii) 的 `if leftover != 0:` → `if False:` | `test_cluster_gate_iii_rejects_dirty_maintenance_db` |

每条改完跑一次，确认**是预期的那一条**变红，复原。**五次红色输出贴给控制者。**

- [ ] **Step 16: 复核 PR 规模（Global Constraints 的规模预警）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4"
git branch --show-current && git rev-parse --short HEAD
git diff --stat main...HEAD -- backend/qmt_pilot_db.py
```
生产代码若已 > 250 行，向控制者报告并讨论是否把 Task 3 拆成独立 PR。

- [ ] **Step 17: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4"
git add backend/qmt_pilot_db.py backend/sql/pilot_cluster_schema.sql backend/tests/test_qmt_pilot_db.py
git commit -m "feat(4a): 名字护栏 + 集群闸 (i)(ii)(iii) + 维护库专用表集合

- assert_pilot_db_allowed / derive_db_name 用 re.fullmatch（re.match+\$ 接受尾随换行）
- 一切守卫 if/raise，绝不用 assert（python -O 会剥掉）
- 【绝对空】白名单式，pg_class 不加 relkind 过滤（物化视图会逃过枚举式写法）
- 闸 (iii) 豁免覆盖【维护库专用表集合】全部成员及各自索引，走 pg_index.indrelid
  而非 pg_depend（marker_pkey 的 refclassid 是 pg_constraint），用 to_regclass 而非
  ::regclass（后者在表不存在时抛异常，--init-cluster-marker 永远跑不了）
- 闸 (ii) 连不进去 = 无法证明归属 = 拒绝，绝不 try/except: continue
- pilot_cluster_schema.sql 独立成文件，绝不与 pilot_schema.sql 合并"
```

---

### Task 2: 两阶段建库 + `pilot_meta` 九键 + pilot 库 schema

**Files:**
- Modify: `backend/qmt_pilot_db.py`
- Create: `backend/sql/pilot_schema.sql`
- Modify: `backend/tests/test_qmt_pilot_db.py`

**Interfaces:**
- Consumes: Task 1 的 `assert_pilot_db_allowed` / `derive_db_name` / `quote_ident` / `PilotDbBoundaryError` / `MAINTENANCE_TABLES`
- Produces:
  - `CONTRACT_VERSION: str` = `"1.12"`
  - `PILOT_META_KEYS: tuple[str, ...]` — 九键，顺序固定
  - `PILOT_META_PHASE1_KEYS` / `PILOT_META_PHASE2_KEYS` — 7/2 划分，两者**恰好划分**九键（有结构性回归钉）
  - `INTENT_TTL_SECONDS: int` = `86400`
  - `def derive_confirm_token(export_log_sha256: str, output_dir: str, created_at: str) -> str`
  - `async def create_pilot_database(maint_conn, *, connect, db_name, seed, schema_sql, pilot_schema_sql, schema_sha256, pilot_schema_sha256, export_log_sha256, output_dir, created_at) -> None`

---

- [ ] **Step 1: 写失败测试 —— 九键、令牌派生、契约版本**

Append to `backend/tests/test_qmt_pilot_db.py`:

```python
import pathlib

from qmt_pilot_db import (CONTRACT_VERSION, INTENT_TTL_SECONDS, PILOT_META_KEYS,
                         derive_confirm_token)

_REPO = pathlib.Path(__file__).resolve().parents[2]


def test_pilot_meta_has_exactly_nine_keys():
    assert PILOT_META_KEYS == (
        "tool", "seed", "schema_sha256", "pilot_schema_sha256", "contract_version",
        "export_log_sha256", "output_dir", "created_at", "state",
    )
    assert len(PILOT_META_KEYS) == 9


def test_contract_version_matches_swift_source_of_truth():
    """跨语言契约漂移钉：Python 侧的常量必须与 Swift 那份逐字相等。
    一次与 pilot 无关的 iOS 迁移 bump 会让复用闸对既有库全判失配——那是预期行为，
    但两边必须**同时**改，不能一边悄悄漂。"""
    swift = (_REPO / "ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift").read_text()
    assert f'CONTRACT_VERSION = "{CONTRACT_VERSION}"' in swift


def test_confirm_token_preimage_is_byte_exact():
    """preimage 逐字定义（spec O1-F14）：
    <export_log_sha256 全 64 位>|<output_dir 不带尾斜杠>|<created_at ISO-8601 basic UTC 微秒>
    取 sha256 的前 12 位十六进制。"""
    import hashlib
    sha = "a" * 64
    out = "/Users/me/pilot_out"
    at = "20260729T101530123456Z"
    expected = hashlib.sha256(f"{sha}|{out}|{at}".encode()).hexdigest()[:12]
    assert derive_confirm_token(sha, out, at) == expected


def test_confirm_token_strips_trailing_slash_from_output_dir():
    """尾斜杠必须被剥掉，否则同一个目录会派生出两个不同的令牌
    → 操作者照打印填了却对不上，reset 的唯一出路被自己焊死。"""
    assert derive_confirm_token("a" * 64, "/x/y/", "20260729T101530123456Z") == \
           derive_confirm_token("a" * 64, "/x/y", "20260729T101530123456Z")


def test_confirm_token_rejects_missing_created_at():
    """闸 0− 的四个授权键**不含** created_at，故绑定不符而该键缺失时派生不出令牌
    → 必须明确提示人工删库，而不是派生一个假令牌（spec O1-F14）。"""
    with pytest.raises(PilotDbBoundaryError) as ei:
        derive_confirm_token("a" * 64, "/x/y", "")
    assert ei.value.code == "confirm_token_underivable"


def test_intent_ttl_is_24h():
    """孤儿 intent 行是一条**永久有效的销毁授权**（spec O4-F2 撤回了上一轮
    「无害且自愈」的假断言）。TTL 把授权窗口从「永久」收窄到 24h。"""
    assert INTENT_TTL_SECONDS == 24 * 3600
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -k "nine_keys or contract_version or confirm_token or intent_ttl" -v`
Expected: FAIL — `ImportError: cannot import name 'CONTRACT_VERSION'`

- [ ] **Step 3: 实现常量与令牌派生**

Append to `backend/qmt_pilot_db.py`:

```python
import hashlib

# 与 ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift 的 CONTRACT_VERSION
# 逐字相等。两边必须同时改（test_contract_version_matches_swift_source_of_truth 是这条的钉）。
CONTRACT_VERSION = "1.12"

# pilot_meta 的九个键，顺序固定。
# created_at **不参与放行判定，但参与令牌派生**（spec O1-F14）。
PILOT_META_KEYS = (
    "tool", "seed", "schema_sha256", "pilot_schema_sha256", "contract_version",
    "export_log_sha256", "output_dir", "created_at", "state",
)

# ⚠️ **两阶段各写哪些键，由 spec §4「建库必须分两阶段」逐字规定，不得合并**（O4-T2-I1）：
#    阶段 1（apply pilot_schema.sql 之后、apply schema.sql 之前）只写这 7 个；
#    `schema_sha256` / `contract_version` **留到阶段 2**、与 `state='ready'` 同一次提交。
#    这不是风格问题：spec §5 的 `db_state_initializing` 那一档（O4-F8）的**论证前提**
#    逐字就是「阶段 1 只写 7 个键、schema_sha256/contract_version 尚未写入」——
#    一次写完九个会让那条修复的前提失真，也让「崩在 schema.sql 之前」的残骸
#    带着一份**完整且相符**的指纹，与「跑完了的库」在指纹维度上不可区分。
PILOT_META_PHASE1_KEYS = (
    "tool", "seed", "export_log_sha256", "output_dir", "created_at",
    "pilot_schema_sha256", "state",
)
PILOT_META_PHASE2_KEYS = ("schema_sha256", "contract_version")

# 闸 0− 的四个**授权键**：闸 0/0b 读到的值算不算数，由它们决定。
# 不含 created_at —— 故绑定不符而 created_at 缺失时派生不出令牌，须提示人工删库。
PILOT_META_AUTHORIZATION_KEYS = ("tool", "seed", "export_log_sha256", "output_dir")

# 孤儿 intent 行的新鲜度界（spec O4-F2）。
INTENT_TTL_SECONDS = 24 * 3600


# 顶层事务控制语句（用于判断一份 .sql 是否自带事务）。
# ⚠️ 只匹配**行首**：`CREATE TABLE …` 里出现 begin 之类的列名不会误判。
_OWN_TRANSACTION_RE = re.compile(r"^\s*(BEGIN|COMMIT|ROLLBACK|START\s+TRANSACTION)\b",
                                 re.IGNORECASE | re.MULTILINE)


def _has_own_transaction(sql: str) -> bool:
    """这份 .sql 是否自带事务控制语句。"""
    return _OWN_TRANSACTION_RE.search(sql) is not None


def derive_confirm_token(export_log_sha256: str, output_dir: str, created_at: str) -> str:
    """--reset-foreign 的确认令牌。

    preimage 逐字定义（spec O1-F14）：
      <export_log_sha256 全 64 位>|<output_dir 不带尾斜杠>|<created_at ISO-8601 basic UTC 微秒>

    ⚠️ 令牌**由目标库自身的身份派生**：脚本里写死的令牌对不上另一个库，
       只有真读过本次打印结果的人才可能填对。裸 --reset-foreign 只证明
       「命令行里有这个词」，不证明操作者看过那个即将被销毁的库是哪一个（spec R34-F1）。
    """
    if not export_log_sha256 or not output_dir or not created_at:
        raise PilotDbBoundaryError(
            "confirm_token_underivable",
            "该库的 pilot_meta 缺少派生确认令牌所需的键"
            "（export_log_sha256 / output_dir / created_at）"
            "——请在 pilot 工具之外人工确认并删除该库",
        )
    preimage = f"{export_log_sha256}|{output_dir.rstrip('/')}|{created_at}"
    return hashlib.sha256(preimage.encode()).hexdigest()[:12]
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: PASS（全部）

- [ ] **Step 5: 写 pilot 库 schema 文件**

Create `backend/sql/pilot_schema.sql`:

```sql
-- backend/sql/pilot_schema.sql
-- QMT Plan 4a：**pilot 库专用**表。apply 到 kline_pilot_<seed>。
--
-- ⚠️ 绝不放进 backend/sql/pilot_cluster_schema.sql，也绝不把 pilot_cluster_marker
--    放进本文件（spec §4 P1-F5，理由见那个文件的头注）。
-- ⚠️ 本文件的**字节** sha256 进 pilot_meta.pilot_schema_sha256 与指纹闸（spec R62-F1）。
--    改本文件一个字节 → 所有既有 pilot 库复用时被指纹闸拒绝，这是预期行为。
-- ⚠️ 绝不手写一段 DDL 现建这两张表（spec R64-F3 对 pilot_meta 的明令）。

-- 承载归属（tool + seed）与绑定（export_log_sha256 + output_dir）。
-- key 上的主键是安全关键：没有它就能塞进两行 seed，而归属闸/绑定闸随后读到哪一行
-- **取决于实现**——而 --reset 的破坏性正建立在这张表上（spec R79-F2）。
CREATE TABLE IF NOT EXISTS pilot_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- 唯一能挡住「export_log 逐字节未变而 K 线内容已换」那一档的守卫（spec R6-F1 + R12-F2）。
-- 缺了它，already_done 分支就没有比对基准。
CREATE TABLE IF NOT EXISTS pilot_stock_source (
    stock_code TEXT PRIMARY KEY,
    sha_1m     TEXT NOT NULL,
    sha_daily  TEXT NOT NULL
);
```

- [ ] **Step 6: 写失败测试 —— 两阶段建库的次序**

Append to `backend/tests/test_qmt_pilot_db.py`:

```python
from qmt_pilot_db import create_pilot_database


class _RecordingConn(_FakeConn):
    """记录 execute 的完整序列与事务边界，用于断言两阶段建库的次序与原子性。"""

    def __init__(self, **kw):
        super().__init__(**kw)
        self.log: list[tuple[str, tuple]] = []
        self.transactions = 0            # 进入过几次事务
        self.rolled_back = 0             # 回滚过几次
        self._depth = 0
        self.executes_outside_transaction: list[str] = []

    def transaction(self):
        conn = self

        class _Tx:
            async def __aenter__(self):
                conn.transactions += 1
                conn._depth += 1
                return conn

            async def __aexit__(self, exc_type, exc, tb):
                conn._depth -= 1
                if exc_type is not None:
                    conn.rolled_back += 1
                return False          # 不吞异常

        return _Tx()

    async def execute(self, query, *args):
        if self._depth == 0:
            self.executes_outside_transaction.append(query)
        self.log.append((query, args))
        self.executed.append(query)

    async def fetch(self, query, *args):
        if "pilot_meta" in query:
            return list(self.meta_rows)
        return await super().fetch(query, *args)


def _stage_sequence(conn):
    """把 execute 日志压成可断言的阶段序列。"""
    out = []
    for q, _ in conn.log:
        low = q.lower()
        if "insert into pilot_create_intent" in low:
            out.append("intent")
        elif "create database" in low:
            out.append("create_db")
        elif "insert into pilot_meta" in low:
            out.append("meta")
        elif "create table" in low and "pilot_meta" in low:
            out.append("apply_pilot_schema")
        elif "create table" in low:
            out.append("apply_schema")
        elif "update pilot_meta" in low and "ready" in low:
            out.append("ready")
    return out


def test_create_pilot_database_writes_intent_before_create():
    """intent 行写在 CREATE DATABASE **之前**，故没有窗口（spec P1r3-F2）。"""
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql="CREATE TABLE IF NOT EXISTS klines ();",
        pilot_schema_sql="CREATE TABLE IF NOT EXISTS pilot_meta ();",
        schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z"))
    seq = _stage_sequence(maint) + _stage_sequence(target)
    assert seq.index("intent") < seq.index("create_db"), "intent 必须先于 CREATE DATABASE"


def test_create_pilot_database_writes_meta_before_schema():
    """归属先于 schema（spec R55-F1）：CREATE DATABASE 之后**第一件事**就是写 pilot_meta。

    原序列 CREATE → apply schema → 写 pilot_meta 会在崩溃时留下一个**没有 pilot_meta 的
    kline_pilot_* 库**：集群闸 (ii) 判它「名字匹配但无合法 pilot_meta」→ 拒绝；归属闸也
    因缺 pilot_meta 而拒绝 DROP → **工具被自己的护栏锁死**。"""
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql="CREATE TABLE IF NOT EXISTS klines ();",
        pilot_schema_sql="CREATE TABLE IF NOT EXISTS pilot_meta ();",
        schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z"))
    seq = _stage_sequence(target)
    assert seq.index("meta") < seq.index("apply_schema"), "pilot_meta 必须先于 schema.sql"
    assert seq[-1] == "ready", "state='ready' 必须是最后一步"


def test_create_pilot_database_uses_template0():
    """一律 CREATE DATABASE … TEMPLATE template0（spec O1-F8，实测）：
    template1 里有一张表时，默认模板建出的库【绝对空】返回 1
    → **本工具自己的残骸不满足【绝对空】** → 集群闸豁免不成立
    → 整台集群对所有 seed 锁死，且 --reset 也清不掉。"""
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql="CREATE TABLE IF NOT EXISTS klines ();",
        pilot_schema_sql="CREATE TABLE IF NOT EXISTS pilot_meta ();",
        schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z"))
    create = [q for q, _ in maint.log if "CREATE DATABASE" in q][0]
    assert "TEMPLATE template0" in create


def test_phase_key_sets_partition_the_nine_keys():
    """7/2 两阶段键集合必须**恰好划分**九键——不重不漏（O4-T2-I1）。"""
    assert set(PILOT_META_PHASE1_KEYS) | set(PILOT_META_PHASE2_KEYS) == set(PILOT_META_KEYS)
    assert set(PILOT_META_PHASE1_KEYS) & set(PILOT_META_PHASE2_KEYS) == set()
    assert len(PILOT_META_PHASE1_KEYS) == 7 and len(PILOT_META_PHASE2_KEYS) == 2
    # spec §4 逐字规定：指纹两键必须留到阶段 2
    assert set(PILOT_META_PHASE2_KEYS) == {"schema_sha256", "contract_version"}


def test_both_phases_are_wrapped_in_transactions():
    """两阶段各自**必须**在一个事务里（O4-T2-C1）。

    少了 `transaction()`，asyncpg 每次 execute 都独立自动提交 → 崩在写键中途会留下
    「表已建、只有几行、`state` 缺失」的残骸；它不满足【绝对空】又无合法 `tool`，
    集群闸 (ii) 会拒绝，**整台集群对所有 seed 锁死**。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql="CREATE TABLE IF NOT EXISTS klines ();",
        pilot_schema_sql="CREATE TABLE IF NOT EXISTS pilot_meta ();",
        schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z"))
    assert target.transactions == 2, f"两阶段各一个事务，实得 {target.transactions}"
    # 每一条 execute 都必须落在某个事务内
    assert target.executes_outside_transaction == [], \
        f"这些语句在事务外执行了: {target.executes_outside_transaction}"


def test_meta_values_are_correct_not_just_key_names():
    """只断言键名集合的测试抓不到「值写反了」（O4-T2-I2）。

    把 `schema_sha256` 与 `pilot_schema_sha256` 的值写反、或把 `output_dir` 误写成
    `seed` 的值，只验键名的实现全绿。故逐键断言值。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql="CREATE TABLE IF NOT EXISTS klines ();",
        pilot_schema_sql="CREATE TABLE IF NOT EXISTS pilot_meta ();",
        schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
        export_log_sha256="a" * 64, output_dir="/x/y/",
        created_at="20260729T101530123456Z"))
    written = {args[0]: args[1] for q, args in target.log if "INSERT INTO pilot_meta" in q}
    assert written == {
        "tool": "qmt_pilot", "seed": "probe",
        "schema_sha256": "b" * 64, "pilot_schema_sha256": "c" * 64,
        "contract_version": CONTRACT_VERSION, "export_log_sha256": "a" * 64,
        "output_dir": "/x/y",                      # ← 尾斜杠必须已剥离
        "created_at": "20260729T101530123456Z", "state": "initializing",
    }


def test_failure_midway_keeps_intent_row_and_closes_connection():
    """崩在建库中途：intent 行**必须保留**（它是下次的销毁授权），连接必须关掉（O4-T2-I3）。

    spec 的设计是「崩了就留孤儿行、由 INTENT_TTL 与 --init-cluster-marker 收口」。
    若异常路径上也把 intent 行删了，下一次同名重跑走零对象例外时第 6 条不成立
    → 自己的残骸自己清不掉。
    """
    class _BoomConn(_RecordingConn):
        async def execute(self, query, *args):
            await super().execute(query, *args)
            if "INSERT INTO pilot_meta" in query and args[0] == "output_dir":
                raise RuntimeError("模拟：写第 4 个键时断连")

    maint, target = _RecordingConn(), _BoomConn()
    with pytest.raises(RuntimeError):
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql="CREATE TABLE IF NOT EXISTS klines ();",
            pilot_schema_sql="CREATE TABLE IF NOT EXISTS pilot_meta ();",
            schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z"))
    assert target.closed is True, "finally 必须关掉目标连接"
    assert not any("DELETE FROM pilot_create_intent" in q for q, _ in maint.log), \
        "异常路径上绝不能删 intent 行"
    assert target.rolled_back == 1, "阶段 1 的事务必须回滚"


def test_real_schema_files_have_the_transaction_ownership_the_code_assumes():
    """**用真文件、不用玩具串**——这是 C1 逃过 6 个建库测试的直接原因（O4-W1）。

    那 6 个测试传的都是 `schema_sql="CREATE TABLE IF NOT EXISTS klines ();"` 这种玩具串，
    于是「schema.sql 自带 BEGIN/COMMIT 会拆掉外层事务」这件事**在结构上不可能被看见**。
    """
    repo = pathlib.Path(__file__).resolve().parents[2]
    assert not _has_own_transaction((repo / "backend/sql/pilot_schema.sql").read_text()), \
        "pilot_schema.sql 不得自带事务——阶段 1 由本工具包裹"
    assert _has_own_transaction((repo / "backend/sql/schema.sql").read_text()), \
        "schema.sql 必须自带事务——阶段 2 依赖它自己的事务保证 DDL 原子性"


def test_schema_sql_is_executed_outside_any_transaction():
    """**行为钉**：`schema.sql` 必须在事务外执行（O4-W1，真 postgres:15.12 实测）。

    套进 `transaction()` 时，文件里那句 `COMMIT` 会提交掉外层事务，其后语句退化成
    autocommit；而 asyncpg 的 `__aexit__` 在事务已不存在时**静默返回**——
    没有任何测试会红、没有任何运行时错误会提示。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    biz_sql = (pathlib.Path(__file__).resolve().parents[2] / "backend/sql/schema.sql").read_text()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=biz_sql,
        pilot_schema_sql="CREATE TABLE IF NOT EXISTS pilot_meta (key TEXT PRIMARY KEY);",
        schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z"))
    assert biz_sql in target.executes_outside_transaction, \
        "schema.sql 必须在事务外执行，绝不能被 transaction() 包裹"
    assert target.transactions == 2, "阶段 1 与「两键 + ready」仍各自在一个事务里"


@pytest.mark.parametrize("pilot_sql,biz_sql,code", [
    ("BEGIN;\nCREATE TABLE t ();\nCOMMIT;", "BEGIN;\nCREATE TABLE u ();\nCOMMIT;",
     "schema_transaction_conflict"),
    ("CREATE TABLE t ();", "CREATE TABLE u ();", "schema_transaction_missing"),
])
def test_schema_transaction_ownership_is_fail_closed(pilot_sql, biz_sql, code):
    """两条守卫必须 fail-closed：靠约定不行——违反时是**静默**失去原子性，没有任何信号。"""
    maint, target = _RecordingConn(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=biz_sql, pilot_schema_sql=pilot_sql,
            schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z"))
    assert ei.value.code == code
    assert maint.log == [], "守卫未过就不许执行任何 DDL（连 intent 行都不写）"


def test_has_own_transaction_only_matches_line_start():
    """`_has_own_transaction` 只匹配行首，不得被列名/注释里的 begin 骗过。"""
    assert _has_own_transaction("BEGIN;\nCREATE TABLE t ();\nCOMMIT;")
    assert _has_own_transaction("  begin;\n")
    assert not _has_own_transaction("CREATE TABLE t (begin_at TIMESTAMPTZ, commit_id TEXT);")
    assert not _has_own_transaction("-- 注释里有 BEGIN 与 COMMIT 两个词\nCREATE TABLE t ();")


def test_create_pilot_database_rejects_illegal_name_before_any_ddl():
    maint, target = _RecordingConn(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({}),
            db_name="production_db", seed="probe",
            schema_sql="", pilot_schema_sql="",
            schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z"))
    assert ei.value.code == "illegal_db_name"
    assert maint.log == [], "护栏未过就不许执行任何 DDL"


def test_create_pilot_database_writes_all_nine_meta_keys():
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql="CREATE TABLE IF NOT EXISTS klines ();",
        pilot_schema_sql="CREATE TABLE IF NOT EXISTS pilot_meta ();",
        schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z"))
    written = {args[0] for q, args in target.log if "INSERT INTO pilot_meta" in q}
    assert written == set(PILOT_META_KEYS), f"九键缺 {set(PILOT_META_KEYS) - written}"
```

- [ ] **Step 7: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -k create_pilot -v`
Expected: FAIL — `ImportError: cannot import name 'create_pilot_database'`

- [ ] **Step 8: 实现两阶段建库**

Append to `backend/qmt_pilot_db.py`:

```python
_INSERT_INTENT_SQL = """
INSERT INTO pilot_create_intent (dbname, seed, created_at) VALUES ($1, $2, $3)
ON CONFLICT (dbname) DO UPDATE SET seed = EXCLUDED.seed, created_at = EXCLUDED.created_at
"""

_DELETE_INTENT_SQL = "DELETE FROM pilot_create_intent WHERE dbname = $1"

_INSERT_META_SQL = "INSERT INTO pilot_meta (key, value) VALUES ($1, $2)"

_SET_READY_SQL = "UPDATE pilot_meta SET value = 'ready' WHERE key = 'state'"


async def create_pilot_database(
    maint_conn, *, connect, db_name: str, seed: str,
    schema_sql: str, pilot_schema_sql: str,
    schema_sha256: str, pilot_schema_sha256: str,
    export_log_sha256: str, output_dir: str, created_at: str,
) -> None:
    """两阶段建库：归属先于 schema（spec R55-F1）。

    0. 维护连接 INSERT pilot_create_intent + COMMIT（在 CREATE DATABASE **之前**，故无窗口）
    1. CREATE DATABASE … TEMPLATE template0
    2. 连进去，**同一个事务**里 apply pilot_schema.sql + 写九键（state='initializing'）
    3. apply schema.sql
    4. state='ready'
    5. 干净收尾：删掉自己的 intent 行

    ⚠️ 调用方必须已经跑过 assert_cluster_allowed。本函数只再过一次名字护栏。
    """
    assert_pilot_db_allowed(db_name, reset=True, destructive=False)
    # ⚠️ 两条 fail-closed 守卫：两份 schema 的**事务归属**必须与代码假设一致（O4-W1）。
    #    靠约定不行——违反时是**静默**失去原子性，没有任何信号。
    if _has_own_transaction(pilot_schema_sql):
        raise PilotDbBoundaryError(
            "schema_transaction_conflict",
            "pilot_schema.sql 不得自带 BEGIN/COMMIT——阶段 1 由本工具包裹事务；"
            "自带会让本工具的 transaction() 在它的 COMMIT 处被拆开",
        )
    if not _has_own_transaction(schema_sql):
        raise PilotDbBoundaryError(
            "schema_transaction_missing",
            "schema.sql 必须自带 BEGIN/COMMIT——阶段 2 依赖它自己的事务保证 DDL 原子性；"
            "不自带则它的 DDL 会逐条 autocommit，失去原子性而无人察觉",
        )
    if derive_db_name(seed) != db_name:
        raise PilotDbBoundaryError(
            "seed_db_name_mismatch",
            f"db_name {db_name!r} 不是 seed {seed!r} 派生出来的",
        )

    # 0. 声明意图（零对象例外第 6 条的判据）
    await maint_conn.execute(_INSERT_INTENT_SQL, db_name, seed, created_at)

    # 1. 建库。TEMPLATE template0 是硬要求，理由见 test_create_pilot_database_uses_template0。
    #    ⚠️ 库名不能绑参（PG 不允许 DDL 里的标识符绑参），故走 quote_ident；
    #       它之前已经过了 assert_pilot_db_allowed。
    await maint_conn.execute(
        f"CREATE DATABASE {quote_ident(db_name)} TEMPLATE template0")

    values = {
        "tool": "qmt_pilot",
        "seed": seed,
        "schema_sha256": schema_sha256,
        "pilot_schema_sha256": pilot_schema_sha256,
        "contract_version": CONTRACT_VERSION,
        "export_log_sha256": export_log_sha256,
        "output_dir": output_dir.rstrip("/"),
        "created_at": created_at,
        "state": "initializing",
    }
    target = await connect(db_name)
    try:
        # 2. 阶段 1 —— **必须在同一个事务里**（O4-T2-C1）：
        #    apply pilot_schema.sql（建 pilot_meta + pilot_stock_source）+ 写 7 个键。
        #    ⚠️ 少了这层 `transaction()`，asyncpg 的每次 execute 都是独立自动提交的隐式事务
        #    → 崩在第 5 个键与第 6 个之间会留下「表已建、只有 5 行、`state` 键缺失」的残骸
        #    （`state` 恰是最后一个键）。该残骸**不满足【绝对空】**（两张表 + 各自 pkey 索引
        #    已在 pg_class 里）、又拿不到合法 `tool` → 集群闸 (ii) 判「名字匹配但无合法
        #    pilot_meta 且非空」→ **拒绝，且这一拒会挡住整台集群对所有 seed 的放行**。
        #    这正是两阶段设计与 TEMPLATE template0 专门要防的失效模式（spec R55-F1），
        #    只是从「缺失的事务边界」这个没堵上的窗口重新打开。
        #    PostgreSQL 的 DDL 是事务性的，故「有表但没行」这个中间态**不可能被别人看到**。
        async with target.transaction():
            await target.execute(pilot_schema_sql)
            for key in PILOT_META_PHASE1_KEYS:
                await target.execute(_INSERT_META_SQL, key, values[key])

        # 3. 阶段 2 —— ⚠️ **绝不包裹 schema.sql**（O4-W1，真 postgres:15.12 实测）：
        #    该文件自带 `BEGIN;`(第 6 行)/`COMMIT;`(第 111 行)，套进 transaction() 时
        #    **文件里那句 COMMIT 会提交掉外层事务**，其后语句全部退化成各自 autocommit；
        #    而 asyncpg 的 __aexit__ 在事务已不存在时**静默返回、不抛异常**
        #    （实测：包裹内 raise 之后，schema.sql 之后建的表**仍然存在** = 回滚没发生）。
        #    没有任何测试会红、没有任何运行时错误会提示。故由**它自己的事务**保证原子性。
        await target.execute(schema_sql)

        #    指纹两键 + state='ready' 另起一个事务。
        #    残余窗口（如实登记）：schema.sql 已提交、这三条未提交时崩 →
        #    「schema 齐全、state 仍是 initializing、指纹两键缺失」，由 O4-F8 兜底
        #    （复用被拒 + db_state_initializing，--reset 能清掉重来）。不可消除。
        async with target.transaction():
            for key in PILOT_META_PHASE2_KEYS:
                await target.execute(_INSERT_META_SQL, key, values[key])
            await target.execute(_SET_READY_SQL)
    finally:
        await target.close()

    # 5. 干净收尾：删掉自己的 intent 行。
    #    崩在这之前会留下孤儿行——它**不是**「无害且自愈」（spec O4-F2）：
    #    孤儿行是一条销毁授权，靠 INTENT_TTL 收窄，靠 --init-cluster-marker 清理。
    await maint_conn.execute(_DELETE_INTENT_SQL, db_name)
```

- [ ] **Step 9: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: PASS（全部）

> ⚠️ **本计划 Task 2 段内嵌的源码清单是「当轮」版本，已被后续三轮终审改过多处**
> （事务判据重写 / 键集合 7-2 拆分 / 守卫 / 异常收口）。
> **4a-2 的实施者请以 `backend/qmt_pilot_db.py` 的当前内容为准，不要照抄本节代码块**——
> 照抄会把已修掉的 fail-open 原样种回去。
>
> **⚠️ `test_create_pilot_database_writes_all_nine_meta_keys` 抓不到「常量写错」**（Task 2 实施者实测）：
> 它的断言是 `written == set(PILOT_META_KEYS)`，**期望值从被测常量自身派生** —— 常量少一个键时，
> 写入循环与断言**一起缩小、保持自洽**，测试照样绿。
> 它能抓的是「写入循环与常量漂移」，**不是**「常量本身是否等于 spec 要求的九个」。
> 后者由 `test_pilot_meta_has_exactly_nine_keys`（硬编码九个名字）单独钉住。
> **两条互补、缺一不可**——只留派生那条就是 vacuous 覆盖。

- [ ] **Step 10: mutation 验证两阶段建库（表内 18 行，逐条真跑）**

| 中和方式 | 必须变红的测试 |
|---|---|
| 把 `await target.execute(schema_sql)` 挪到写九键**之前** | `test_create_pilot_database_writes_meta_before_schema` |
| `CREATE DATABASE … TEMPLATE template0` → 去掉 `TEMPLATE template0` | `test_create_pilot_database_uses_template0` |
| 把 `_INSERT_INTENT_SQL` 那行挪到 `CREATE DATABASE` 之后 | `test_create_pilot_database_writes_intent_before_create` |
| `assert_pilot_db_allowed(...)` 那行删掉 | `test_create_pilot_database_rejects_illegal_name_before_any_ddl` |
| `PILOT_META_KEYS` 里删掉 `"pilot_schema_sha256"` | **只有** `test_pilot_meta_has_exactly_nine_keys`（硬编码九个名字的那条）|
| `CONTRACT_VERSION = "1.12"` → `"1.11"` | `test_contract_version_matches_swift_source_of_truth` |
| 去掉阶段 1 的 `async with target.transaction():`（改为直接顺序执行）| `test_both_phases_are_wrapped_in_transactions` |
| `PILOT_META_PHASE2_KEYS` 改成 `()`、阶段 1 改回写 `PILOT_META_KEYS` 全部九键 | `test_phase_key_sets_partition_the_nine_keys` |
| `values` 里把 `schema_sha256` 与 `pilot_schema_sha256` 的值对调 | `test_meta_values_are_correct_not_just_key_names` |
| 把删 intent 行那句从 `try/finally` 之后挪进 `finally` | `test_failure_midway_keeps_intent_row_and_closes_connection` |
| 把 `await target.execute(schema_sql)` 挪回 `async with target.transaction():` 里 | `test_schema_sql_is_executed_outside_any_transaction` |
| 删掉 `_transaction_statements(pilot_schema_sql)` 那条守卫 | `test_schema_transaction_ownership_is_fail_closed[...conflict]` |
| `_is_wrapped_in_transaction` 里 `if len(txn) != 2: return False` 改成 `pass` | `test_is_wrapped_in_transaction_probe_table[多事务块 + 中间裸 DDL]` |
| `_TXN_COMMIT_RE` 换成 `_TXN_END_RE`（收尾接受 ROLLBACK）| `test_is_wrapped_in_transaction_probe_table[ROLLBACK 收尾]` |
| `_sql_statements` 去掉 `.lstrip("\ufeff")` | `test_is_wrapped_in_transaction_probe_table[UTF-8 BOM]` |
| `_txn_control_lines(biz)` 的 `len(txn) == 2` 断言删掉 | 无测试会红 —— **这条是「独立判据」自身的自查**，请手工确认它仍穷尽 |
| 删掉 `assert_pilot_db_allowed(target_db, ...)` 那一行 | `test_cluster_gate_rejects_illegal_target_db_name` |
| 闸 (ii) 的 `except Exception as exc: raise PilotClusterBoundaryError` 改回只包 `connect()` | `test_cluster_gate_ii_ownership_probe_failure_is_fail_closed` |

复原后跑全量确认绿。**表内每一行都真跑，把红色输出贴给控制者**（标注「无测试会红」的那行除外——它是**人工自查项**，请改完后手工确认判据仍穷尽）。

- [ ] **Step 11: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4"
git add backend/qmt_pilot_db.py backend/sql/pilot_schema.sql backend/tests/test_qmt_pilot_db.py
git commit -m "feat(4a): 两阶段建库 + pilot_meta 九键 + 确认令牌派生

- 归属先于 schema：CREATE → 写九键(state=initializing) → apply schema → ready
  （原序列崩在中间会留下无 pilot_meta 的库，集群闸与归属闸双双拒绝 = 工具被自己锁死）
- intent 行写在 CREATE DATABASE 之前，故无窗口；干净收尾时删除
- TEMPLATE template0 是硬要求：template1 不干净时本工具自己的残骸不满足【绝对空】
- confirm_token preimage 逐字定义，尾斜杠剥离；created_at 缺失时派生不出令牌 →
  明确提示人工删库，不派生假令牌
- CONTRACT_VERSION 与 Swift 那份有跨语言漂移钉"
```

---

### Task 3: 库级五闸 + 零对象例外 + `--reset-foreign` 令牌 + L2 真 PG 脚本

**Files:**
- Modify: `backend/qmt_pilot_db.py`
- Modify: `backend/tests/test_qmt_pilot_db.py`
- Create: `backend/scripts/verify_pilot_db_lifecycle.py`
- Create: `backend/scripts/verify_pilot_concurrency.py`

**Interfaces:**
- Consumes: Task 1 与 Task 2 的全部产出
- Produces:
  - `async def read_pilot_meta(conn) -> dict[str, str]` — 闸 0− 的授权完整性检查在此
  - `async def assert_db_allowed_for_reuse(conn, *, seed, schema_sha256, pilot_schema_sha256, export_log_sha256, output_dir) -> None`
  - `async def assert_db_allowed_for_reset(conn, *, seed, export_log_sha256, output_dir, reset_foreign_token) -> None`
  - `async def try_empty_remnant_exception(maint_conn, target_conn, *, db_name, seed, holds_seed_lock, now_epoch) -> bool`

---

- [ ] **Step 1: 写失败测试 —— 闸 0− 授权完整性**

Append to `backend/tests/test_qmt_pilot_db.py`:

```python
from qmt_pilot_db import read_pilot_meta


def _meta_rows(**overrides):
    base = {
        "tool": "qmt_pilot", "seed": "probe",
        "schema_sha256": "b" * 64, "pilot_schema_sha256": "c" * 64,
        "contract_version": CONTRACT_VERSION, "export_log_sha256": "a" * 64,
        "output_dir": "/x/y", "created_at": "20260729T101530123456Z", "state": "ready",
    }
    base.update(overrides)
    return [{"key": k, "value": v} for k, v in base.items()]


def test_gate_0minus_rejects_duplicate_key_rows():
    """key 上没有唯一约束、塞进**两行 seed** 的库：指纹照样相符、结构闸照样放行，
    而归属闸与绑定闸随后读到哪一行**取决于实现**——而 --reset 的破坏性
    正建立在这张表上（spec R79-F2 + R80-F1）。"""
    rows = _meta_rows() + [{"key": "seed", "value": "other"}]
    conn = _FakeConn(meta_rows=rows)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(read_pilot_meta(conn))
    assert ei.value.code == "pilot_meta_ambiguous"


def test_gate_0minus_rejects_missing_authorization_key():
    rows = [r for r in _meta_rows() if r["key"] != "output_dir"]
    conn = _FakeConn(meta_rows=rows)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(read_pilot_meta(conn))
    assert ei.value.code == "pilot_meta_ambiguous"


def test_gate_0minus_missing_table_is_not_owned_not_ambiguous():
    """表不存在 → not_owned；表存在但形状/键不合规 → pilot_meta_ambiguous（spec O1-F6）。

    这两者必须可区分：前者「这个库不是本工具建的」，后者「这个库的授权凭据坏了」，
    操作者动作完全不同。
    """
    class _NoTable(_FakeConn):
        async def fetch(self, query, *args):
            if "pilot_meta" in query:
                raise RuntimeError('relation "pilot_meta" does not exist')
            return await super().fetch(query, *args)

    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(read_pilot_meta(_NoTable()))
    assert ei.value.code == "not_owned"


def test_gate_0minus_happy_returns_dict():
    got = asyncio.run(read_pilot_meta(_FakeConn(meta_rows=_meta_rows())))
    assert got["tool"] == "qmt_pilot" and got["seed"] == "probe"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -k gate_0minus -v`
Expected: FAIL — `ImportError: cannot import name 'read_pilot_meta'`

- [ ] **Step 3: 实现闸 0−**

Append to `backend/qmt_pilot_db.py`:

```python
async def read_pilot_meta(conn) -> dict[str, str]:
    """闸 0− —— pilot_meta 授权完整性（spec R80-F1）。

    它管的是「闸 0/0b **读到的值算不算数**」，故必须排在 0/0b **之前**，
    且 **DROP 与复用两条路径都跑**——DROP 路径根本不跑闸 2，
    把 pilot_meta 的断言只放进闸 2 会让最危险的那条路径原封不动（spec R80-F1）。

    ⚠️ 只对**已存在 pilot_meta 表**的库求值。表不存在这一档**不由 0− 处置**
       （否则残骸 + --reset 会在 0− 第一条就撞 pilot_meta_ambiguous
       「拒绝 DROP、库原样保留」→ **残骸永远清不掉**，spec O1-F5）。
    """
    # ⚠️ 形状判据**复用 Task 1 的 `read_pilot_meta_rows`**，不得另写一份
    #    （spec §4 P1-F7：这条纪律此前「只落在了各自发现它的那个对象上」）。
    try:
        seen = await read_pilot_meta_rows(conn)
    except PilotDbBoundaryError:
        raise                                  # 形状不合规 → pilot_meta_ambiguous，原样上抛
    except Exception as exc:
        # 表不存在 = 这个库不是本工具建的（spec O1-F6）。
        raise PilotDbBoundaryError(
            "not_owned",
            f"目标库没有 pilot_meta 表（{exc}）——它不是本次 pilot 建的。"
            f"如确需删除请在 pilot 工具之外手工执行",
        ) from exc

    missing = [k for k in PILOT_META_AUTHORIZATION_KEYS if k not in seen]
    if missing:
        raise PilotDbBoundaryError(
            "pilot_meta_ambiguous",
            f"pilot_meta 缺少授权键 {missing}——拒绝 DROP，库原样保留",
        )
    return seen
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: PASS

- [ ] **Step 5: 写失败测试 —— 复用四闸 + reset 两闸 + 令牌**

Append to `backend/tests/test_qmt_pilot_db.py`:

```python
from qmt_pilot_db import assert_db_allowed_for_reset, assert_db_allowed_for_reuse

_REUSE_OK = dict(seed="probe", schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
                 export_log_sha256="a" * 64, output_dir="/x/y")
_RESET_OK = dict(seed="probe", export_log_sha256="a" * 64, output_dir="/x/y",
                 reset_foreign_token=None)


def test_reuse_rejects_wrong_seed():
    conn = _FakeConn(meta_rows=_meta_rows(seed="other"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reuse(conn, **_REUSE_OK))
    assert ei.value.code == "not_owned"


def test_reuse_rejects_binding_mismatch():
    conn = _FakeConn(meta_rows=_meta_rows(output_dir="/other"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reuse(conn, **_REUSE_OK))
    assert ei.value.code == "binding_mismatch"


def test_reuse_rejects_initializing_before_fingerprint_gate():
    """state='initializing' 必须在**闸 1（指纹）之前**求值（spec O4-F8）。

    阶段 1 只写了九键里的一部分、schema_sha256 尚未定稿，闸 1 会先撞「键缺失」并报
    schema_fingerprint_mismatch → **db_state_initializing 永远产不出来**，
    恢复指引也从「用 --reset 重建」错成「schema 漂移」。
    """
    conn = _FakeConn(meta_rows=_meta_rows(state="initializing", schema_sha256="zzz"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reuse(conn, **_REUSE_OK))
    assert ei.value.code == "db_state_initializing", \
        "initializing 必须先于指纹闸命中，否则报的是 schema_fingerprint_mismatch"


def test_reuse_rejects_fingerprint_drift():
    conn = _FakeConn(meta_rows=_meta_rows(schema_sha256="d" * 64))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reuse(conn, **_REUSE_OK))
    assert ei.value.code == "schema_fingerprint_mismatch"


def test_reuse_rejects_pilot_schema_sha_drift():
    """指纹闸必须覆盖 pilot_schema_sha256（spec R63-F1）：
    只比 schema_sha256 + contract_version 的实现会让 pilot_stock_source 的
    schema 漂移完全失明。"""
    conn = _FakeConn(meta_rows=_meta_rows(pilot_schema_sha256="d" * 64))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reuse(conn, **_REUSE_OK))
    assert ei.value.code == "schema_fingerprint_mismatch"


def test_reuse_happy_path():
    asyncio.run(assert_db_allowed_for_reuse(_FakeConn(meta_rows=_meta_rows()), **_REUSE_OK))


def test_reset_allows_fingerprint_drift():
    """**反向钉（分寸不能过头，spec R49-F2）**：归属与绑定都相符、但 schema_sha256
    已漂移的库带 --reset → **必须放行到 DROP**。把指纹/结构闸也塞进 --reset 分支的实现
    会让陈旧 schema 的库连 reset 都做不了，而 reset 是它唯一的出路。"""
    conn = _FakeConn(meta_rows=_meta_rows(schema_sha256="d" * 64))
    asyncio.run(assert_db_allowed_for_reset(conn, **_RESET_OK))  # 不抛 = 放行


def test_reset_allows_initializing():
    """--reset 时 initializing 照常走归属闸 + 绑定闸（两者所需的键在阶段 1 就已写入），
    故**能被正常清掉重来**（spec R55-F1）。"""
    conn = _FakeConn(meta_rows=_meta_rows(state="initializing"))
    asyncio.run(assert_db_allowed_for_reset(conn, **_RESET_OK))


def test_reset_binding_mismatch_prints_token_and_refuses():
    conn = _FakeConn(meta_rows=_meta_rows(output_dir="/someone_else"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reset(conn, **_RESET_OK))
    assert ei.value.code == "binding_mismatch"
    assert ei.value.confirm_token == derive_confirm_token(
        "a" * 64, "/someone_else", "20260729T101530123456Z")
    assert ei.value.identity["output_dir"] == "/someone_else"


def test_reset_foreign_wrong_token_refused():
    conn = _FakeConn(meta_rows=_meta_rows(output_dir="/someone_else"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reset(
            conn, **{**_RESET_OK, "reset_foreign_token": "deadbeefcafe"}))
    assert ei.value.code == "reset_foreign_token_invalid"


def test_reset_foreign_correct_token_allowed():
    conn = _FakeConn(meta_rows=_meta_rows(output_dir="/someone_else"))
    token = derive_confirm_token("a" * 64, "/someone_else", "20260729T101530123456Z")
    asyncio.run(assert_db_allowed_for_reset(
        conn, **{**_RESET_OK, "reset_foreign_token": token}))


def test_reset_ownership_mismatch_never_offers_a_token():
    """归属不过时**不给令牌**——令牌只解「同 seed 但绑定不同」这一档。
    归属不符意味着这个库根本不是本工具建的，唯一出路是人工删（spec R3-F1）。"""
    conn = _FakeConn(meta_rows=_meta_rows(tool="something_else"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reset(conn, **_RESET_OK))
    assert ei.value.code == "not_owned"
    assert ei.value.confirm_token is None
```

- [ ] **Step 6: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -k "reuse or reset" -v`
Expected: FAIL — `ImportError: cannot import name 'assert_db_allowed_for_reuse'`

- [ ] **Step 7: 实现库级闸**

Append to `backend/qmt_pilot_db.py`:

```python
async def _assert_ownership(meta: dict[str, str], *, seed: str) -> None:
    """闸 0 —— 归属（tool + seed）。这个库**能不能被我碰**。"""
    if meta.get("tool") != "qmt_pilot" or meta.get("seed") != seed:
        raise PilotDbBoundaryError(
            "not_owned",
            f"该库的 pilot_meta 说它属于 tool={meta.get('tool')!r} / seed={meta.get('seed')!r}，"
            f"而本次 seed={seed!r}——该库不是本次 pilot 建的。"
            f"如确需删除请在 pilot 工具之外手工执行",
        )


def _binding_matches(meta: dict[str, str], *, export_log_sha256: str, output_dir: str) -> bool:
    return (meta.get("export_log_sha256") == export_log_sha256
            and meta.get("output_dir") == output_dir.rstrip("/"))


async def assert_db_allowed_for_reuse(
    conn, *, seed: str, schema_sha256: str, pilot_schema_sha256: str,
    export_log_sha256: str, output_dir: str,
) -> None:
    """复用路径：闸 0− → 0 → 0b → **state** → 1 → 2 全过才允许复用。

    ⚠️ state == 'initializing' 必须排在**闸 1（指纹）之前**（spec O4-F8）：
       阶段 1 尚未写定指纹键，闸 1 会先撞「键缺失」并报 schema_fingerprint_mismatch，
       于是 db_state_initializing 永远产不出来、恢复指引也走错。
    """
    meta = await read_pilot_meta(conn)                                # 闸 0−
    await _assert_ownership(meta, seed=seed)                          # 闸 0
    if not _binding_matches(meta, export_log_sha256=export_log_sha256,
                            output_dir=output_dir):                   # 闸 0b
        raise PilotDbBoundaryError(
            "binding_mismatch",
            "该库绑定的是另一份源快照/输出目录，请换 seed 或用 --reset 重建",
            identity={"export_log_sha256": meta.get("export_log_sha256", "")[:12],
                      "output_dir": meta.get("output_dir"),
                      "created_at": meta.get("created_at")},
        )
    if meta.get("state") != "ready":                                  # state（先于闸 1）
        raise PilotDbBoundaryError(
            "db_state_initializing",
            f"该库 state={meta.get('state')!r}，上次没跑完 apply schema——"
            f"一律拒绝复用，请用 --reset 重建",
        )
    if (meta.get("schema_sha256") != schema_sha256
            or meta.get("pilot_schema_sha256") != pilot_schema_sha256
            or meta.get("contract_version") != CONTRACT_VERSION):     # 闸 1
        raise PilotDbBoundaryError(
            "schema_fingerprint_mismatch",
            "schema.sql / pilot_schema.sql / contract_version 与建库时不一致——"
            "请用 --reset 重建",
        )
    # 闸 2（结构断言）由调用方在真库上跑；本函数只做 pilot_meta 侧那一组，
    # 其余七组需要 information_schema 查询，见 verify_pilot_db_lifecycle.py。


async def assert_db_allowed_for_reset(
    conn, *, seed: str, export_log_sha256: str, output_dir: str,
    reset_foreign_token: str | None,
) -> None:
    """--reset 路径：闸 0− → 0 → 0b 全过才允许 DROP。

    ⚠️ **指纹闸与结构闸不参与 DROP 判定**（spec R49-F2）：闸的分工不可倒置——
       归属管「能不能碰」，指纹管「能不能直接用」。把指纹塞进 DROP 路径会让一个
       陈旧 schema 的库连 reset 都做不了，而 reset 是它唯一的出路。
    """
    meta = await read_pilot_meta(conn)                                # 闸 0−
    await _assert_ownership(meta, seed=seed)                          # 闸 0
    if _binding_matches(meta, export_log_sha256=export_log_sha256,
                        output_dir=output_dir):                       # 闸 0b 通过
        return

    # 绑定不符：打印该库所绑身份 + 派生确认令牌，需 --reset-foreign 逐字相符才放行。
    identity = {"export_log_sha256": meta.get("export_log_sha256", "")[:12],
                "output_dir": meta.get("output_dir"),
                "created_at": meta.get("created_at")}
    token = derive_confirm_token(meta.get("export_log_sha256", ""),
                                 meta.get("output_dir", ""),
                                 meta.get("created_at", ""))
    if reset_foreign_token is None:
        raise PilotDbBoundaryError(
            "binding_mismatch",
            f"该库绑定的是另一套设置：{identity}。"
            f"确认要销毁它请重跑并带 --reset-foreign={token}",
            identity=identity, confirm_token=token)
    if reset_foreign_token != token:
        raise PilotDbBoundaryError(
            "reset_foreign_token_invalid",
            f"--reset-foreign 令牌不符（该库的令牌是 {token}）",
            identity=identity, confirm_token=token)
```

- [ ] **Step 8: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: PASS

- [ ] **Step 9: 写失败测试 —— 零对象例外六条**

Append to `backend/tests/test_qmt_pilot_db.py`:

```python
from qmt_pilot_db import try_empty_remnant_exception

_NOW = 1_800_000_000  # 任意固定 epoch 秒；测试不依赖真实时钟


class _IntentConn(_FakeConn):
    def __init__(self, intent_rows=(), **kw):
        super().__init__(**kw)
        self.intent_rows = list(intent_rows)

    async def fetch(self, query, *args):
        if "pilot_create_intent" in query:
            return list(self.intent_rows)
        return await super().fetch(query, *args)


def _intent(dbname="kline_pilot_probe", seed="probe", age_seconds=0,
            create_confirmed=True, oid_matches_now=True):
    # ⚠️ 字段必须与 _READ_INTENT_SQL 的输出**逐字一致**：判据读 inserted_at_epoch /
    #    create_confirmed / oid_matches_now，fixture 少给一个就是「测试在测另一个东西」。
    return [{"dbname": dbname, "seed": seed,
             "inserted_at_epoch": _NOW - age_seconds,
             "create_confirmed": create_confirmed,
             "oid_matches_now": oid_matches_now}]


def test_remnant_exception_all_six_conditions_pass():
    maint = _IntentConn(intent_rows=_intent())
    target = _FakeConn(empty_counts=[0] * 6 * 2)   # 判定一次 + DROP 前紧贴着重查一次
    assert asyncio.run(try_empty_remnant_exception(
        maint, target, db_name="kline_pilot_probe", seed="probe",
        holds_seed_lock=True, now_epoch=_NOW)) is True


def test_remnant_exception_requires_seed_lock():
    maint = _IntentConn(intent_rows=_intent())
    target = _FakeConn(empty_counts=[0] * 12)
    assert asyncio.run(try_empty_remnant_exception(
        maint, target, db_name="kline_pilot_probe", seed="probe",
        holds_seed_lock=False, now_epoch=_NOW)) is False


def test_remnant_exception_requires_absolutely_empty():
    """一个装着物化视图的库不是残骸。判据用【绝对空】那组白名单式 SQL，
    绝不用 information_schema.tables（物化视图会逃过它，spec O1-F1）。"""
    maint = _IntentConn(intent_rows=_intent())
    target = _FakeConn(empty_counts=[1, 0, 0, 0, 0, 0])
    assert asyncio.run(try_empty_remnant_exception(
        maint, target, db_name="kline_pilot_probe", seed="probe",
        holds_seed_lock=True, now_epoch=_NOW)) is False


def test_remnant_exception_requires_intent_row():
    """同事裸 CREATE DATABASE 与 pg_restore --create 都**没有** intent 行 → 拒
    （spec P1r3-F2：这是第 6 条存在的全部理由）。"""
    maint = _IntentConn(intent_rows=[])
    target = _FakeConn(empty_counts=[0] * 12)
    assert asyncio.run(try_empty_remnant_exception(
        maint, target, db_name="kline_pilot_probe", seed="probe",
        holds_seed_lock=True, now_epoch=_NOW)) is False


def test_remnant_exception_rejects_stale_intent_row():
    """孤儿 intent 行是一条**永久有效的销毁授权**（spec O4-F2）：
    此后任何人用这个名字建的空库都满足第 6 条、被直接 DROP。
    INTENT_TTL 把授权窗口从「永久」收窄到 24h。"""
    maint = _IntentConn(intent_rows=_intent(age_seconds=INTENT_TTL_SECONDS + 1))
    target = _FakeConn(empty_counts=[0] * 12)
    assert asyncio.run(try_empty_remnant_exception(
        maint, target, db_name="kline_pilot_probe", seed="probe",
        holds_seed_lock=True, now_epoch=_NOW)) is False


def test_remnant_exception_does_not_delete_stale_row():
    """判定时**不删**超期行——普通运行不替别的 seed 做决定（spec O4-F2 修正②）。
    清理只在 --init-cluster-marker 里做，且要逐行取 seed 锁。"""
    maint = _IntentConn(intent_rows=_intent(age_seconds=INTENT_TTL_SECONDS + 1))
    target = _FakeConn(empty_counts=[0] * 12)
    asyncio.run(try_empty_remnant_exception(
        maint, target, db_name="kline_pilot_probe", seed="probe",
        holds_seed_lock=True, now_epoch=_NOW))
    assert not any("DELETE" in q.upper() for q in maint.executed)


def test_remnant_exception_rechecks_empty_immediately_before_drop():
    """第 3 条与 DROP 之间不可原子：实测 pg_restore --create 存在
    「库已建、表还没建」的空窗 → 六条全成立 → **DROP 掉一个正在恢复中的库**
    （spec P1-F3）。故 DROP 前须**紧贴着**重查一次【绝对空】。"""
    maint = _IntentConn(intent_rows=_intent())
    # 第一次判定全 0（六条），紧贴着重查时第一条变 1（restore 刚建出第一张表）
    target = _FakeConn(empty_counts=[0] * 6 + [1, 0, 0, 0, 0, 0])
    assert asyncio.run(try_empty_remnant_exception(
        maint, target, db_name="kline_pilot_probe", seed="probe",
        holds_seed_lock=True, now_epoch=_NOW)) is False


def test_remnant_exception_requires_exact_db_name():
    """第 2 条是**全等**而非前缀——它把爆炸半径限制在本次 seed（spec R56-F1）。"""
    maint = _IntentConn(intent_rows=_intent(dbname="kline_pilot_other"))
    target = _FakeConn(empty_counts=[0] * 12)
    assert asyncio.run(try_empty_remnant_exception(
        maint, target, db_name="kline_pilot_probe", seed="probe",
        holds_seed_lock=True, now_epoch=_NOW)) is False
```

- [ ] **Step 10: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -k remnant -v`
Expected: FAIL — `ImportError: cannot import name 'try_empty_remnant_exception'`

- [ ] **Step 11: 实现零对象例外**

Append to `backend/qmt_pilot_db.py`:

```python
# ⚠️ 两处都是硬要求（O4-R14-C2，计划片段此前**两条都漏**）：
#   · `public.` 限定 —— 不限定时敌意 search_path 能把这条读到另一张伪造表上（O4-R4-C1 同族）；
#   · 必须取 `create_confirmed` 并在下面的 `fresh` 判据里**要求它为 true**（O4-R8-C2）——
#     intent 行写在 CREATE DATABASE **之前**，未确认的行证明不了「这个库是本次建的」；
#     拿它当授权会去 DROP **别人建的**同名空库，无 pilot_meta 归属、无 --reset-foreign 令牌。
_READ_INTENT_SQL = """
SELECT i.dbname, i.seed, i.create_confirmed,
       -- ⚠️ 新鲜度只看 `inserted_at`（库自己的时钟），**不看 created_at**（O4-R23-C1）：
       --    created_at 是调用方传进来的字符串，数据库既不生成也不校验 —— 很远的未来值
       --    让这行永远「新鲜」、永远抢不走；很远的过去值让活着的行立刻可被接管。
       EXTRACT(EPOCH FROM i.inserted_at)::bigint AS inserted_at_epoch,
       -- ⚠️ **确认位必须绑到当前这个数据库实例**（O4-R21-C1 / R25-C1）：
       --    只按名字判时，原库被删、别人用同名重建之后，陈旧的 create_confirmed=true
       --    会为那个**全新的、不是我们建的**库背书 —— 而这一行是 DROP 授权。
       (i.db_oid IS NOT NULL AND EXISTS (
            SELECT 1 FROM pg_database d
             WHERE d.datname::text = i.dbname AND d.oid = i.db_oid)) AS oid_matches_now
  FROM public.pilot_create_intent i WHERE i.dbname = $1
"""


async def try_empty_remnant_exception(
    maint_conn, target_conn, *, db_name: str, seed: str,
    holds_seed_lock: bool, now_epoch: int,
) -> bool:
    """零对象例外（spec §4，R56-F1 + P1r3-F2 + P1-F3 + O4-F2）。

    返回 True = 六条全成立且 DROP 前的紧贴复查也通过 → 允许直接 DROP + 两阶段重建，
    **不进闸 0−/0/0b、不需要 --reset-foreign**。返回 False = 不适用，走正常闸序。

    六条（**当且仅当**全部成立）：
      1. 本次带 --reset（由调用方保证：不带 --reset 时根本不调用本函数）
      2. 库名**恰等于** kline_pilot_<seed>（**全等**不是前缀——把爆炸半径限制在本次 seed）
      3. 该库满足**【绝对空】**（白名单式那组 SQL）
      4. 集群闸 (i)(ii)(iii) 已全过（由调用方保证）
      5. ①c 的按 seed advisory lock 已持有
      6. 维护库 public.pilot_create_intent 有本次库名的行、seed 相符、
         **create_confirmed = true**（O4-R8-C2）、**inserted_at**（库时钟，非 created_at）未超 INTENT_TTL

    **并且**：DROP 之前须**紧贴着**重查一次【绝对空】（第 3 条与 DROP 之间不可原子）。
    """
    # 2. 库名全等
    if db_name != derive_db_name(seed):
        return False
    # 5. 已持按 seed 锁
    if not holds_seed_lock:
        return False
    # 3. 【绝对空】
    if not await _is_absolutely_empty(target_conn):
        return False
    # 6. 新鲜的 intent 行
    rows = await maint_conn.fetch(_READ_INTENT_SQL, db_name)
    fresh = [r for r in rows
             if r["seed"] == seed
             # ⚠️ 未确认的行不是授权（O4-R8-C2）：它写在 CREATE DATABASE 之前，
             #    建库失败/歧义失败都会留下它，而本次可能什么都没造。
             and r["create_confirmed"]
             # ⚠️ 且这句确认必须指向**现在这个实例**（O4-R21-C1 / R25-C1）。
             and r["oid_matches_now"]
             and (now_epoch - int(r["inserted_at_epoch"])) < INTENT_TTL_SECONDS]
    if not fresh:
        # ⚠️ 超期行**不在这里删**——普通运行不该替别的 seed 做决定（spec O4-F2）。
        #    清理只在 --init-cluster-marker 里做，且须逐行 pg_try_advisory_lock。
        return False
    # DROP 前紧贴着重查（spec P1-F3：pg_restore --create 有「库已建、表还没建」的空窗）
    return await _is_absolutely_empty(target_conn)
```

- [ ] **Step 12: 跑测试确认通过 + mutation 验证**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: PASS

| 中和方式 | 必须变红的测试 |
|---|---|
| `state != "ready"` 那块挪到指纹闸**之后** | `test_reuse_rejects_initializing_before_fingerprint_gate` |
| `assert_db_allowed_for_reset` 里加上指纹比对 | `test_reset_allows_fingerprint_drift` |
| `reset_foreign_token != token` → `reset_foreign_token is None` | `test_reset_foreign_wrong_token_refused` |
| `read_pilot_meta` 的 `if key in seen: raise` 删掉 | `test_gate_0minus_rejects_duplicate_key_rows` |
| `try_empty_remnant_exception` 末行 `return await _is_absolutely_empty(...)` → `return True` | `test_remnant_exception_rechecks_empty_immediately_before_drop` |
| TTL 判断 `< INTENT_TTL_SECONDS` → `>= 0` | `test_remnant_exception_rejects_stale_intent_row` |
| `_binding_matches` 里去掉 `output_dir` 比较 | `test_reuse_rejects_binding_mismatch` |

复原后跑全量确认绿。**七次红色输出贴给控制者。**

- [ ] **Step 13: 写 L2 真 PG 生命周期脚本**

Create `backend/scripts/verify_pilot_db_lifecycle.py`.

**这一层是「假 conn 不得替代真 PG」这条纪律的唯一落地处**——假件对「同一 session 第二次取锁」和「第一次取锁」反应完全一样，也建模不出 `relkind` 覆盖面与 DROP 被顶住。脚本形态**照抄 `backend/scripts/verify_advisory_lock_reentrancy.py`**：模块 docstring 写清背景/用法/退出码语义，`async def main() -> int`，`asyncio.run` 收口，退出码 0 = 全部断言成立。

必须覆盖的档位（spec §6.2，逐条对应 §9-12）：

1. **集群闸五档**：无标记 / 有标记但集群含无关库 / 维护库含用户表 / 含无主 `kline_pilot_other` / 同场景下 `--init-cluster-marker` 也须拒绝
2. **两阶段建库 + `state` 流转**：`CREATE` 后立刻能读到 `pilot_meta` 且 `state='initializing'`；跑完为 `ready`
3. **陈旧库四件套 fail-closed**：OHLC 仍 `DECIMAL` / `file_path` 为 `VARCHAR` / 缺 `uq_stock_start` / 缺 `content_hash`
4. **归属闸与绑定闸的破坏性分支**：真验「目标库事后**仍然存在**」
5. **`--reset-foreign` 三跑**：裸 flag / 错令牌 / 正确令牌，每跑都真验目标库是否幸存
6. **闸 0− 三库**：`key` 无唯一约束且塞两行 `seed` / 缺 `output_dir` 键 / `value` 为 `varchar(8)` —— 每种都断言复用被拒且 DROP 从未执行；**带 `--reset` 跑同样被拒、库事后仍在**
7. **`state='initializing'` 单独一档、两条断言方向相反**：复用 → 拒 + `db_state_initializing`（负向）；**`--reset` → 必须 DROP + 重建成功**（正向钉）
   > ⚠️ **不要**写成「闸 0− 四库、`--reset` 也拒」——那是把 R55-F1 的锁死钉进 L2 门（spec O4-F6）。
8. **建库两阶段的崩溃恢复三档**
9. **【绝对空】的物化视图档**：建一个只含物化视图（1000 行真实数据）的同名库 + `--reset` → **必须拒绝且库事后仍在**
10. **集群闸遍历过目标库之后立刻 `--reset`** → 必须成功 DROP + 重建（spec O1-F2 规定 4：这一档证明「读一律短连接」真的做到了）
11. **零对象例外四态**：无 marker 表 / 只有 marker / 只有 intent / 两表齐全 —— 闸 (iii) 豁免 SQL 必须分别返回 `0 / 0 / 0 / 0`，且**不抛异常**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4" && docker run --rm -d -p 5433:5432 -e POSTGRES_PASSWORD=postgres --name pg4a postgres:15.12 && sleep 5 && DSN='postgresql://postgres:postgres@localhost:5433/postgres' .venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py; echo "EXIT=$?"; docker rm -f pg4a`

Expected: 每档打印 `PASS`，末行 `EXIT=0`

> ⚠️ **判绿读输出内容，不看 exit code**：`cmd | tail` 之后 `$?` 是 tail 的（本仓已踩过两次）。上面的命令用 `; echo "EXIT=$?"` 而非管道，就是为了这个。

- [ ] **Step 14: 写 L2 并发脚本**

Create `backend/scripts/verify_pilot_concurrency.py`：同 `--seed`、不同 `--maintenance-dsn` 的两个进程 —— 断言第二个在 `pg_try_advisory_lock` 处**立刻**失败返回（**须设短超时并断言它没有在等**），且未执行任何 `DROP`/`CREATE`；杀掉第一个后第二个能立即取得锁（会话级锁随连接断开自动释放）。

Run: 同上，换脚本名
Expected: `EXIT=0`

- [ ] **Step 15: 跑全量 host 测试 + 复核规模**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4"
git branch --show-current && git rev-parse --short HEAD
cd backend && python -m pytest tests/ -q; echo "EXIT=$?"
cd .. && git diff --stat main...HEAD
```
Expected: 既有测试**一条都没红**（4a 是纯新增，不改既有文件）；`EXIT=0`

- [ ] **Step 16: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4"
git add backend/qmt_pilot_db.py backend/tests/test_qmt_pilot_db.py \
        backend/scripts/verify_pilot_db_lifecycle.py backend/scripts/verify_pilot_concurrency.py
git commit -m "feat(4a): 库级五闸 + 零对象例外 + --reset-foreign 令牌 + L2 真 PG 脚本

- 闸 0−（pilot_meta 授权完整性）排在 0/0b 之前，**DROP 与复用两条路径都跑**
  （只放进闸 2 会让最危险的 DROP 路径原封不动——它根本不跑闸 2）
- state='initializing' 在**闸 1 之前**求值，否则 db_state_initializing 永远产不出来
- 指纹闸与结构闸**不参与 DROP 判定**：闸的分工不可倒置，否则陈旧 schema 的库
  连 reset 都做不了，而 reset 是它唯一的出路（含反向钉）
- 零对象例外六条 + DROP 前紧贴着重查【绝对空】（pg_restore --create 有空窗）
- intent 行加 INTENT_TTL(24h)：孤儿行是一条永久有效的销毁授权，判定时不删超期行
- confirm_token 只进 stderr、不进报告 JSON"
```

---

## 验收清单（非 coder 可执行）

> 本仓治理 backstop 要求每个模块交付都带一份非 coder 可执行的清单。以下每条只需照做并对照「期望」打勾。

| # | 动作 | 期望 | P/F |
|---|---|---|---|
| 1 | 在项目根跑 `cd backend && python -m pytest tests/test_qmt_pilot_db.py -q` | 末行显示 `passed`，无 `failed`/`error` | |
| 2 | 跑 `cd backend && python -m pytest tests/ -q; echo "EXIT=$?"` | `EXIT=0`，且既有测试数量比合并前只增不减 | |
| 3 | **[4a-2，本 PR 跳过]** 起 Docker PG 后跑 `verify_pilot_db_lifecycle.py`（命令见 Task 3 Step 13） | 每档打印 `PASS`，末行 `EXIT=0` | |
| 4 | **[4a-2，本 PR 跳过]** 跑 `verify_pilot_concurrency.py` | 末行 `EXIT=0` | |
| 5 | 打开 `backend/sql/pilot_cluster_schema.sql`，数一下 `CREATE TABLE` 有几条 | **恰好 2 条**（`pilot_cluster_marker`、`pilot_create_intent`），且**没有** `pilot_meta` | |
| 6 | 打开 `backend/sql/pilot_schema.sql`，数一下 `CREATE TABLE` 有几条 | **恰好 2 条**（`pilot_meta`、`pilot_stock_source`），且**没有** `pilot_cluster_marker` | |
| 7 | 在 `backend/qmt_pilot_db.py` 里搜 `assert ` （带空格） | **一处都搜不到**（守卫一律 if/raise） | |
| 8 | 在 `backend/qmt_pilot_db.py` 里搜 `WITH (FORCE)` 与 `pg_terminate_backend` | **两个都搜不到** | |
| 9 | 在 `backend/qmt_pilot_db.py` 里搜 `information_schema.tables` | **搜不到**（【绝对空】必须白名单式） | |
| 9b | **在仓库根目录**（不是 `backend/`）起 Docker PG 后跑 `DSN='postgresql://postgres:postgres@localhost:55432/postgres' .venv/bin/python backend/scripts/verify_pilot_two_phase_create.py`（命令见脚本头注） | 四档全 PASS，**末行 `✅ 四档断言全部成立`**。⚠️ 判绿读**输出内容**，不要看管道后的 exit code | |
| 9c | **先 `docker rm -f pg4a`**（放掉 9b 的容器），再**在仓库根目录**执行 `bash backend/scripts/selfcheck_c1_mutation.sh`（它自己完成「中和 → 跑 → 复原」）| 输出里第 ④ 档必须出现 **FAIL**（这证明 9b 不是空跑的），末行打印 `复原完成，git status 干净` | |
| 10 | 请贴出全部 mutation 验证的红色输出。**本 PR（4a-1）范围 = Task 1 + Task 2**，三张表实测 3 + 5 + 18 = **26 行**（Task 3 的 7 行与 Task 4 的 4 行属 4a-2）| 其中 1 行标注「无测试会红」= **人工自查项**，故应有 **25 次**红色输出 + 1 次自查确认。⚠️ 若某次**没变红**，先怀疑 mutation 自己写对没有 | |

**本 PR 合并时的正确表述**：「4a 护栏建好、用假件与真-PG 脚本验过」。
**禁述**：「pilot 已完成」「100 股已出货」「真实数据接入完成」——**一个字节的真 QMT 数据都还没流过**。

---

## Self-Review 结果

**1. Spec 覆盖**（逐条对照 spec §3 的三个子项与 §9 的验收表）：

| spec 要求 | 落在哪 | |
|---|---|---|
| `assert_pilot_db_allowed` 护栏 | Task 1 Step 3 | ✅ |
| 集群闸 (i)(ii)(iii) | Task 1 Step 13 | ✅ |
| 【绝对空】白名单式判据 | Task 1 Step 9 | ✅ |
| 闸 (iii) 豁免覆盖【维护库专用表集合】 | Task 1 Step 9 | ✅ |
| 两阶段建库（归属先于 schema） | Task 2 Step 8 | ✅ |
| `pilot_meta` 九键 | Task 2 Step 3 | ✅ |
| `confirm_token` preimage 逐字定义 | Task 2 Step 3 | ✅ |
| 闸 0−（授权完整性） | Task 3 Step 3 | ✅ |
| 闸 0（归属）/ 0b（绑定）/ 1（指纹） | Task 3 Step 7 | ✅ |
| 闸 2（结构断言七组） | **部分**：`pilot_meta` 那组在 Task 3 Step 7；其余七组需 `information_schema` 查询，落在 Task 3 Step 13 的 L2 脚本第 3 档 | ⚠️ 见下 |
| 零对象例外六条 + 紧贴复查 | Task 3 Step 11 | ✅ |
| `--reset-foreign` 令牌三跑 | Task 3 Step 7（L1）+ Step 13 第 5 档（L2） | ✅ |
| `--init-cluster-marker` 幂等 + 补建 intent 表 + 孤儿行清理取锁 | **未覆盖** | ❌ 见下 |
| DROP 前断言连接数为 0 | Task 3 Step 13 第 10 档（L2） | ✅ |

**发现两处缺口，已处理**：

- **闸 2 的七组结构断言只在 L2 有**：`klines.open/high/low/close` 为 `double precision`、`stock_coverage` 存在、`training_sets.file_path` 为 `text`、`content_hash` 列存在、`uq_stock_start` 约束存在、`pilot_stock_source` 形状——这六组都需要真的 `information_schema` 查询，用假 conn 测只能测「SQL 字符串长什么样」，是 vacuous 覆盖。**这是有意的分层**（spec §6.2「假件会静默建模错误语义」），已在 L2 脚本第 3 档明确列出。
- **`--init-cluster-marker` 子命令未覆盖**：spec §4 规定它的幂等语义（标记合法但 intent 表缺失/形状不符 → **补建再成功**）与孤儿行清理（逐行 `pg_try_advisory_lock`，取不到就跳过）。**它是 4a 的一部分，必须补**——见下方 Task 4。

**2. Placeholder 扫描**：无 TBD/TODO；每个 code step 都有完整可运行代码；每个 run step 都有确切命令与期望输出。

**3. 类型一致性**：`PilotDbBoundaryError.code` 在 Task 1 定义、Task 2/3 沿用；`_FakeConn` 在 Task 1 Step 11 定义、Task 2 的 `_RecordingConn` 与 Task 3 的 `_IntentConn` 都继承它；`connect` 的签名 `async def (dbname) -> conn` 三个 Task 一致；`read_pilot_meta` 返回 `dict[str, str]`，被 `assert_db_allowed_for_reuse` / `_for_reset` 消费。

---

### Task 4: `--init-cluster-marker` 幂等语义 + 孤儿行清理

> Self-Review 补出来的缺口。**它使 Task 3 的零对象例外真的可用**——没有它，一台由旧版本初始化的集群没有 `pilot_create_intent` 表，第 6 条恒不成立，残骸永远清不掉（spec O4-F7）。

**Files:**
- Modify: `backend/qmt_pilot_db.py`
- Modify: `backend/tests/test_qmt_pilot_db.py`

**Interfaces:**
- Consumes: Task 1 的 `assert_cluster_allowed` / `MAINTENANCE_TABLES` / `MARKER_PURPOSE`，Task 2 的 `INTENT_TTL_SECONDS`
- Produces: `async def init_cluster_marker(maint_conn, *, connect, cluster_schema_sql, now_epoch, try_seed_lock) -> None`

---

- [ ] **Step 1: 写失败测试**

Append to `backend/tests/test_qmt_pilot_db.py`:

```python
from qmt_pilot_db import init_cluster_marker

_CLUSTER_SQL = ("CREATE TABLE IF NOT EXISTS pilot_cluster_marker (purpose TEXT PRIMARY KEY);"
                "CREATE TABLE IF NOT EXISTS pilot_create_intent ("
                "dbname TEXT PRIMARY KEY, seed TEXT NOT NULL, created_at TEXT NOT NULL);")


class _InitConn(_IntentConn):
    def __init__(self, *, has_intent_table=True, existing_dbs=(), **kw):
        super().__init__(**kw)
        self.has_intent_table = has_intent_table
        self.existing_dbs = list(existing_dbs)

    async def fetch(self, query, *args):
        if "pilot_create_intent" in query and not self.has_intent_table:
            raise RuntimeError('relation "pilot_create_intent" does not exist')
        if "pg_database" in query and "datistemplate" in query:
            return [{"datname": d} for d in self.existing_dbs]
        return await super().fetch(query, *args)


def _always_lock(_seed):
    return True


def _never_lock(_seed):
    return False


def test_init_repairs_cluster_initialized_by_older_build():
    """旧版本没有 pilot_create_intent 表 → 第 6 条恒不成立 → 残骸永远清不掉。
    幂等短路成功的实现**修不好**这种集群（spec O4-F7）。"""
    conn = _InitConn(has_intent_table=False)
    asyncio.run(init_cluster_marker(conn, connect=_connector({}),
                                    cluster_schema_sql=_CLUSTER_SQL,
                                    now_epoch=_NOW, try_seed_lock=_always_lock))
    assert any("pilot_create_intent" in q for q in conn.executed), \
        "intent 表缺失时必须补建，不得短路成功"


def test_init_rejects_multi_row_marker():
    conn = _InitConn(marker_rows=[{"purpose": MARKER_PURPOSE}, {"purpose": "x"}])
    with pytest.raises(PilotClusterBoundaryError):
        asyncio.run(init_cluster_marker(conn, connect=_connector({}),
                                        cluster_schema_sql=_CLUSTER_SQL,
                                        now_epoch=_NOW, try_seed_lock=_always_lock))


def test_init_cleans_orphan_intent_rows_only_under_seed_lock():
    """--init-cluster-marker 不持任何 seed 锁时会删掉**一次正在进行的运行**的行
    → 那次运行随后判第 6 条不成立 → 自己的残骸自己清不掉（spec O4-F2 修正③）。"""
    rows = _intent(dbname="kline_pilot_running", seed="running", age_seconds=10)
    conn = _InitConn(intent_rows=rows, existing_dbs=[])
    asyncio.run(init_cluster_marker(conn, connect=_connector({}),
                                    cluster_schema_sql=_CLUSTER_SQL,
                                    now_epoch=_NOW, try_seed_lock=_never_lock))
    assert not any("DELETE" in q.upper() for q in conn.executed), \
        "取不到 seed 锁就必须跳过，不得删"


def test_init_cleans_stale_or_vanished_rows_when_lock_free():
    """清理判据 = **超期 OR 库不存在**（spec O4-F2 修正③）。"""
    rows = (_intent(dbname="kline_pilot_stale", seed="stale",
                    age_seconds=INTENT_TTL_SECONDS + 1)
            + _intent(dbname="kline_pilot_gone", seed="gone", age_seconds=10))
    conn = _InitConn(intent_rows=rows, existing_dbs=[])   # 两个库都不在 pg_database
    asyncio.run(init_cluster_marker(conn, connect=_connector({}),
                                    cluster_schema_sql=_CLUSTER_SQL,
                                    now_epoch=_NOW, try_seed_lock=_always_lock))
    deleted = [q for q in conn.executed if "DELETE" in q.upper()]
    assert len(deleted) == 2


def test_init_keeps_fresh_row_of_live_database():
    """既新鲜、库又真的存在 → 不是孤儿，不许删。"""
    conn = _InitConn(intent_rows=_intent(dbname="kline_pilot_live", seed="live",
                                         age_seconds=10),
                     existing_dbs=["kline_pilot_live"])
    asyncio.run(init_cluster_marker(conn, connect=_connector({}),
                                    cluster_schema_sql=_CLUSTER_SQL,
                                    now_epoch=_NOW, try_seed_lock=_always_lock))
    assert not any("DELETE" in q.upper() for q in conn.executed)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -k init_ -v`
Expected: FAIL — `ImportError: cannot import name 'init_cluster_marker'`

- [ ] **Step 3: 实现**

Append to `backend/qmt_pilot_db.py`:

```python
_WRITE_MARKER_SQL = """
-- ⚠️ `public.` 限定（O4-R4-C1）：不限定时由 search_path 决定写进哪个 schema。
INSERT INTO public.pilot_cluster_marker (purpose) VALUES ($1) ON CONFLICT (purpose) DO NOTHING
"""

_LIST_ALL_INTENT_SQL = """
-- ⚠️ 新鲜度只认库时钟（O4-R23-C1）；表名 `public.` 限定（O4-R4-C1）。
SELECT dbname, seed, EXTRACT(EPOCH FROM inserted_at)::bigint AS inserted_at_epoch
  FROM public.pilot_create_intent
"""


async def init_cluster_marker(maint_conn, *, connect, cluster_schema_sql: str,
                              now_epoch: int, try_seed_lock) -> None:
    """qmt_pilot --init-cluster-marker：把一台干净集群声明为 pilot 专用。

    幂等语义（spec §4 + O4-F7）：
      · 已存在合法单行标记 **且** pilot_create_intent 形状合规 → 直接成功；
      · 标记合法但 **intent 表缺失/形状不符 → 补建它再成功**
        （短路成功的实现修不好旧版本初始化的集群：旧版没有 intent 表 →
         零对象例外第 6 条恒不成立 → 残骸永远清不掉）；
      · 标记非法/多行 → **拒绝**，要求人工处理。

    孤儿行清理（spec O4-F2 修正③）：
      判据 = **超期 OR 库不存在**；**逐行先取该行 seed 的 advisory lock，取不到就跳过**
      （不加这一步会删掉一次正在进行的运行的行 → 那次运行随后判第 6 条不成立 →
       自己的残骸自己清不掉）。

    try_seed_lock: Callable[[str], bool] —— 由调用方注入（4c 持有锁的那条连接）。
    """
    # 写标记前同样跑 (ii) 与 (iii)（spec §4）。
    # 注意：此刻 marker 表可能还不存在，闸 (i) 会因此拒绝——故先建表再跑闸。
    await maint_conn.execute(cluster_schema_sql)

    rows = await maint_conn.fetch(_READ_MARKER_SQL)
    if len(rows) > 1 or (len(rows) == 1 and rows[0]["purpose"] != MARKER_PURPOSE):
        raise PilotClusterBoundaryError(
            "no_marker",
            f"pilot_cluster_marker 形状非法（{len(rows)} 行："
            f"{[r['purpose'] for r in rows]}）——请人工处理",
        )
    if not rows:
        # 首次初始化：先证明集群干净，再写标记。
        leftover = await maint_conn.fetchval(MAINTENANCE_EXEMPT_QUERY)
        if leftover != 0:
            raise PilotClusterBoundaryError(
                "maintenance_db_not_empty",
                f"维护库除 {MAINTENANCE_TABLES} 外还有 {leftover} 个用户对象，"
                f"拒绝把它声明为 pilot 专用集群",
            )
        for row in await maint_conn.fetch(_LIST_DATABASES_SQL):
            if PILOT_DB_NAME_RE.fullmatch(row["datname"]) is None:
                raise PilotClusterBoundaryError(
                    "unrelated_database",
                    f"集群里存在无关数据库 {row['datname']!r}，拒绝初始化",
                )
        await maint_conn.execute(_WRITE_MARKER_SQL, MARKER_PURPOSE)

    # 孤儿 intent 行清理
    live = {r["datname"] for r in await maint_conn.fetch(_LIST_DATABASES_SQL)}
    for r in await maint_conn.fetch(_LIST_ALL_INTENT_SQL):
        # ⚠️ 同 O4-R23-C1：孤儿清理的新鲜度判据也只认库时钟，不认调用方传的 created_at。
        stale = (now_epoch - int(r["inserted_at_epoch"])) >= INTENT_TTL_SECONDS
        vanished = r["dbname"] not in live
        if not (stale or vanished):
            continue
        if not try_seed_lock(r["seed"]):
            continue                       # 有运行正在用这个 seed —— 跳过，绝不删
        await maint_conn.execute(_DELETE_INTENT_SQL, r["dbname"])
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd backend && python -m pytest tests/test_qmt_pilot_db.py -v`
Expected: PASS（全部）

- [ ] **Step 5: mutation 验证**

| 中和方式 | 必须变红的测试 |
|---|---|
| `await maint_conn.execute(cluster_schema_sql)` 改成「若 marker 已存在就 return」 | `test_init_repairs_cluster_initialized_by_older_build` |
| `if not try_seed_lock(r["seed"]): continue` 删掉 | `test_init_cleans_orphan_intent_rows_only_under_seed_lock` |
| `if not (stale or vanished): continue` → `if False: continue` | `test_init_keeps_fresh_row_of_live_database` |
| `len(rows) > 1` → `len(rows) > 2` | `test_init_rejects_multi_row_marker` |

复原后跑全量。**四次红色输出贴给控制者**（验收清单第 10 项的总数由 21 更新为 **25**）。

- [ ] **Step 6: 把 `--init-cluster-marker` 的四档补进 L2 脚本**

Modify `backend/scripts/verify_pilot_db_lifecycle.py`，增加：

12. **旧版本集群的修复**：手工只建 `pilot_cluster_marker`（不建 intent 表）→ 跑 `init_cluster_marker` → 断言 intent 表**事后存在**且形状合规
13. **孤儿行清理的锁保护**：起两条连接，A 取住 `seed='running'` 的 advisory lock，B 跑 `init_cluster_marker` → 断言那一行**事后仍在**

Run: 同 Task 3 Step 13 的命令
Expected: 末行 `EXIT=0`

- [ ] **Step 7: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4"
git add backend/qmt_pilot_db.py backend/tests/test_qmt_pilot_db.py \
        backend/scripts/verify_pilot_db_lifecycle.py
git commit -m "feat(4a): --init-cluster-marker 幂等语义 + 孤儿 intent 行清理

- 标记合法但 intent 表缺失/形状不符 → **补建再成功**（短路成功修不好旧版本
  初始化的集群：旧版没有 intent 表 → 零对象例外第 6 条恒不成立 → 残骸永远清不掉）
- 孤儿行判据 = 超期 OR 库不存在；**逐行先取该行 seed 的 advisory lock，取不到就跳过**
  （不加这一步会删掉一次正在进行的运行的行）
- 首次初始化前先证明集群干净（闸 ii + iii），再写标记"
```

---

## 收尾：spec 五条机械检查

本 PR 引入了 spec 里没有的新错误码 `illegal_seed` / `seed_db_name_mismatch` / `confirm_token_underivable`。按 spec §4 的收尾必做：

- [ ] **1. 新错误码** → 它们进了 4c 的 `db_boundary_error` 枚举吗？触发哪个 verdict？
  - 三者都是 `FAIL_DB_BOUNDARY`。**在开 PR 之前**把它们补进 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3 的 `db_boundary_error` 枚举，并跑 `python3 tools/check_spec_consistency.py` 确认归零。
- [ ] **2. 新参数/枚举项** → `grep -rn 'illegal_seed\|seed_db_name_mismatch\|confirm_token_underivable' backend docs`，确认调用点/登记处数量对得上。
- [ ] **3. 新闸** → 本 PR 没有新增闸（只是实现 spec 已定义的）。
- [ ] **4. 改规则** → 本 PR 没有改 spec 的规则。
- [ ] **5. 新持久字段** → `pilot_create_intent` 的三列：**谁写** = `create_pilot_database` 第 0 步；**谁读** = `try_empty_remnant_exception` 第 6 条；**谁清** = `create_pilot_database` 第 5 步（自己的）+ `init_cluster_marker`（孤儿的，取锁后）。三问齐全。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-29-qmt-plan4a-db-guardrails.md`.
