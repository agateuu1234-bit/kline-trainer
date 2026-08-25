# QMT NAS 部署 · PR-1「配置覆盖守卫 + `/health` 暴露 repository」Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「后端到底有没有连上真 PostgreSQL」从不可验证变成一条 `curl`，并用机械守卫钉住「配置样例文件必须覆盖后端代码真正读的那些环境变量名」。

**Architecture:** 两处独立改动，零耦合。① `backend/.env.example` 补上 `DATABASE_URL`（后端代码真正读的名字），并新增一条 AST + shell 双侧枚举式扫描测试，把「配置样例 ⟷ 真实消费者」的一致性钉死；② `GET /health` 响应新增 `repository` 字段，取值恰好 `"asyncpg"` / `"inmemory"` 两个字面量，请求时求值。

**Tech Stack:** Python 3.11 · FastAPI 0.115.12 · pytest 8.4.2 · 标准库 `ast`（无新依赖）

**Spec:** `docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md`（本 PR 实现其 §5 的 C1-6 / C1-7 与 T2 / T3 两族判据；判据形状的 2026-08-24 订正见该 spec 的 §2.5-a）

---

## Global Constraints

以下是 spec 的项目级要求，**每个 Task 的要求都隐含包含本节**。数值逐字抄自 spec，不得凭记忆改写。

1. **禁述**（spec §1 + §13.0）：本 PR 的任何文档 / 提交信息 / PR 描述**不得**出现「pilot 已完成」「100 股已出货」「真实数据接入完成」「PR11-R1 已关闭」「生产后端地址已接通」「backendBaseURL 已可配置（不带 debug-only 限定）」。
2. **CI 依赖边界**（`feedback_test_imports_must_not_need_optional_deps`）：新增测试**不得**在模块顶层 import CI 未安装的包。`backend/requirements-test.txt` 实测内容为 `pytest / httpx / pglast / openapi-spec-validator / pyyaml / fastapi / apscheduler / pandas / numpy` —— **没有 asyncpg，也没有 uvicorn**。
3. **CI 把任何 skip 判为失败**（`.github/workflows/backend-tests.yml` 实测：解析 junit XML，`skipped > 0` 即 `exit 1`）→ **不许**用 `pytest.mark.skipif` / `importorskip` 绕过缺失依赖。
4. **每条新测试必须变异验证**，且由**控制者亲跑**，不接受 subagent 自证（`feedback_controller_must_run_gates_himself`）。变异纪律见下方「变异验证标准配方」。
5. **不得用 Bash 读写任何含 `.env` 字样的路径**：本仓 `.claude/settings.json` 有 `Bash(cat **/.env*)` / `Bash(git show *.env*)` / `Bash(git grep *.env*)` 等 deny 规则。改 `backend/.env.example` **必须走 Read / Edit / Write 工具**，也**不得**用 Bash 绕过该规则（`feedback_no_bash_bypass_deny_rule`）。
6. **`/health` 不进 `openapi.yaml`**：该文件恰好 3 条 path 且被 `backend/tests/test_openapi.py::test_three_endpoints_present` 精确锁死（实测）。本 PR **不改** `openapi.yaml`。
7. **不改** `backend/sql/`、`tests/contract-fixtures/`、`scripts/nas-preflight.sh`（spec §5.3 + §11-R9：R9 是**先于**本次改动就存在的既有不一致，本次不修、也不新增破坏）。
8. **CLAUDE.md §3 外科式改动**：每一行改动都要能追溯到本 plan 的某个 Task。不顺手改相邻代码 / 注释 / 排版。

### 变异验证标准配方（每次变异都照抄这套，别省步骤）

```bash
PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
WT="/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-backend"
```

1. **备份**：`cp <目标文件> /tmp/mut-backup-<名字>` —— ⛔ 复原**绝不**用 `git checkout <file>`（会静默抹掉未提交改动，`feedback_git_checkout_destroys_uncommitted_work`）。
2. **改**：只改**要证明的那一条判据**，别顺手弄坏语法或参数个数（`feedback_mutation_must_target_the_exact_predicate`）。
3. **确认变异真的生效**：`diff /tmp/mut-backup-<名字> <目标文件>` 必须有输出。
4. **清字节码后跑**（⚠️ 必做，`feedback_python_stale_pyc_defeats_mutation`：失效判据是 `(mtime秒, size)`，等长改动 + 同秒复原会让旧 `.pyc` 继续生效，**危险方向是反的** —— 变异后显示绿会让人误判「测试没判别力」，进而去改一条本来正确的测试）：
   ```bash
   find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
   cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/<文件> -q 2>&1 | tail -20
   ```
5. **记下红的是「具名的哪一条」**——「有测试变红」是假信号（`feedback_mutation_must_target_the_exact_predicate`）。把测试函数名抄进 Task 的验证记录里。
6. **复原**：`cp /tmp/mut-backup-<名字> <目标文件>`，再清一次 `__pycache__`，重跑确认回绿。

---

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `backend/.env.example` | 修改 | 部署配置样例。本 PR 补一行 `DATABASE_URL=`（后端代码读的名字）+ 两条用途注释。**保留** `DB_URL`（`scripts/nas-preflight.sh` 的必需变量循环读它，删了会直接打断该脚本）。 |
| `backend/tests/test_env_example_coverage.py` | 新建 | T2 全族：AST 扫 `backend/` 下非 tests 的 `.py`、正则扫「真的 `source` 了 `.env` 的 `.sh`」，得到消费者全集，与分类表精确相等比对；并断言「该进配置样例的那些」在 `.env.example` 里都有同名 `KEY=` 行。 |
| `backend/app/routes.py` | 修改 | 新增一个纯查询函数 `current_repository_kind()`，返回当前进程装配的 repository 种类。**只加函数，不改任何既有行为**。 |
| `backend/app/main.py` | 修改 | `/health` 响应体新增 `repository` 字段（一行）。 |
| `backend/tests/test_health.py` | 修改 | 既有 `test_health_returns_200` 的精确相等断言随契约更新；新增 T3-1 / T3-2 两条正向档 + T3-3 的 `status` 保持档。 |

**为什么 `repository_kind` 放 `routes.py` 而不是 `main.py`**：`_default_repo` 是 `routes.py` 的模块级私有全局；判定逻辑跟它放一起，`main.py` 里只剩一行调用。反过来会逼 `main.py` 去读别人的私有变量。

**已知且接受的取舍（写进代码注释，供评审看）**：`current_repository_kind()` 读的是模块全局 `_default_repo`，**不经** FastAPI 的 `Depends(get_repository)`。后果是——测试里用 `app.dependency_overrides[get_repository]` 注入的假件**不会**反映到 `/health`。这在生产路径上没有分歧（生产从不用 overrides），且换成 `Depends` 会引入一个更糟的后果：`_default_repo is None` 时 `get_repository()` 抛 `RuntimeError` → **健康检查端点变成 500**。健康检查不该在任何情况下崩。

---

## Task 1: `.env.example` 覆盖守卫（C1-6 / T2 全族）

**Files:**
- Create: `backend/tests/test_env_example_coverage.py`
- Modify: `backend/.env.example`（⚠️ 只能用 Read / Edit / Write 工具，见 Global Constraints 第 5 条）

**Interfaces:**
- Consumes: 无（本 Task 是本 PR 的第一个）
- Produces: 无导出符号。产出的是一条常驻守卫；后续任何 PR 新增读环境变量的 Python 消费者、或新增一个 `source .env` 的 shell 脚本，都会被它拦下要求归类。

- [ ] **Step 1: 写扫描守卫测试（此刻应当是红的）**

新建 `backend/tests/test_env_example_coverage.py`，内容如下（逐字）：

```python
# backend/tests/test_env_example_coverage.py
"""C1-6 / T2：`.env.example` 必须覆盖「消费 backend/.env 的那一族」环境变量。

背景（spec §2.5-a，2026-08-24 实测）：`app/main.py` / `app/scheduler_main.py` /
`import_csv.py` / `generate_training_sets.py` 四处读 `DATABASE_URL`，而
`.env.example` 当时只定义 `DB_URL` —— 名字对不上，是个真 bug。而且
`app/main.py:16-22` 在 DSN 缺失时会**静默**回落 InMemoryLeaseRepository，
所以这个名字对不上不报错，只会让手机拉到一个空库（假绿）。

判据形状（spec T2-1 的 2026-08-24 订正版）：
  ① discovered == ENV_FILE_KEYS | OUT_OF_SCOPE_KEYS  （精确相等，两个方向同时成立）
  ② ENV_FILE_KEYS <= `.env.example` 里解析出的 KEY 集合

判据①是**反向断言**，同时兜住两种失效：
  - 扫描器坏掉 / 扫不到文件 → discovered 为空 → 不相等 → 红（防空转）；
  - 有人新增、改名、删除一个消费者而没更新分类表 → 不相等 → 红（枚举性）。
所以「变量名写在本文件里」在这里**不构成恒真**：被比较的另一侧是扫出来的，
不是写死的。
"""
from __future__ import annotations

import ast
import re
from pathlib import Path

# backend/tests/<本文件> → parents[0]=tests, [1]=backend, [2]=仓库根
REPO_ROOT = Path(__file__).resolve().parents[2]
BACKEND_DIR = REPO_ROOT / "backend"
ENV_EXAMPLE = BACKEND_DIR / ".env.example"

# ── 分类表 ──────────────────────────────────────────────────────────────
# 该进 `.env.example` 的：部署时由 backend/.env 提供。
ENV_FILE_KEYS = {
    "DATABASE_URL",       # 后端代码读；容器内走 compose 内网 db:5432
    "DB_URL",             # 宿主侧管理用 DSN；scripts/nas-preflight.sh 的必需变量循环读
    "NAS_HOST",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_DB",
}

# 明确**不**进 `.env.example` 的，每条都要有理由（spec §2.5-a 实测全表）。
OUT_OF_SCOPE_KEYS = {
    # 人工验证脚本的 DSN：每次在命令行显式传，从不读 .env。
    "DSN",
    "DSN2",
    # 破坏性/清理开关：故意要求每次手打，写进配置样例等于给它发通行证。
    "QMT_VERIFY_ALLOW_DESTRUCTIVE",
    "QMT_VERIFY_ALLOW_REMOTE",
    "QMT_VERIFY_FORCE_CLEANUP",
    # B4 调度器本次不部署（spec §5.3）。将来部署调度器时必须重新归类到 ENV_FILE_KEYS。
    "TRAINING_SETS_DIR",
}


class _EnvKeyVisitor(ast.NodeVisitor):
    """收集 os.environ.get("X") / os.environ["X"] / os.getenv("X") 的**字面量**键名。

    刻意只认字面量：`os.environ.get(name)` 这种动态键本来就无法静态归类，
    漏掉它不会造成假绿——它读的名字连人也看不出来，要靠代码评审拦。
    刻意用 AST 而不是正则：`backend/scripts/_pilot_verify_harness.py` 里有一段
    **字符串字面量**形式的 `os\\.environ\\.get\\("(DSN\\d*)"\\)` 正则源码，
    正则扫描会把它当成真消费者，AST 不会。
    """

    def __init__(self) -> None:
        self.keys: set[str] = set()

    @staticmethod
    def _literal(node: ast.expr) -> str | None:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        return None

    def visit_Call(self, node: ast.Call) -> None:
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr in ("get", "getenv"):
            base = func.value
            is_environ_get = isinstance(base, ast.Attribute) and base.attr == "environ"
            is_os_getenv = (
                isinstance(base, ast.Name) and base.id == "os" and func.attr == "getenv"
            )
            if (is_environ_get or is_os_getenv) and node.args:
                key = self._literal(node.args[0])
                if key is not None:
                    self.keys.add(key)
        self.generic_visit(node)

    def visit_Subscript(self, node: ast.Subscript) -> None:
        value = node.value
        if isinstance(value, ast.Attribute) and value.attr == "environ":
            key = self._literal(node.slice)
            if key is not None:
                self.keys.add(key)
        self.generic_visit(node)


def _python_consumer_files() -> list[Path]:
    """backend/ 下的全部 .py，排除测试与字节码缓存。

    扫描根刻意限定在 backend/：仓库根的 tests/hooks/*.py 是治理工具链，
    读的是 PATH / CLAUDE_SESSION_ID 之类，与部署配置无关。
    """
    out: list[Path] = []
    for path in sorted(BACKEND_DIR.rglob("*.py")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        if rel.startswith("backend/tests/") or "__pycache__" in rel:
            continue
        out.append(path)
    return out


def _scan_python_keys() -> set[str]:
    keys: set[str] = set()
    for path in _python_consumer_files():
        visitor = _EnvKeyVisitor()
        visitor.visit(ast.parse(path.read_text(encoding="utf-8"), filename=str(path)))
        keys |= visitor.keys
    return keys


# 「这个脚本真的 source 了一个 .env」：`source x/.env` 或 `. x/.env`
_SOURCES_DOTENV_RE = re.compile(r"^\s*(?:source|\.)\s+\S*\.env\b", re.MULTILINE)
# 该脚本自己声明的必需变量列表：`for var in A B C D; do`
_REQUIRED_LOOP_RE = re.compile(r"for\s+var\s+in\s+([A-Za-z0-9_\s]+?);\s*do")


def _shell_consumer_files() -> list[Path]:
    return sorted(
        list(BACKEND_DIR.rglob("*.sh")) + list((REPO_ROOT / "scripts").glob("*.sh"))
    )


def _scan_shell_keys() -> set[str]:
    """真的 source 了 .env 的 shell 脚本，取它自己声明的必需变量列表。

    fail-closed（对齐 feedback_guard_skip_conflates_not_a_site_with_unknown）：
    如果一个脚本 source 了 .env 却找不到必需变量循环，**抛异常**而不是当成
    「零消费者」静默跳过——那会把「判据够不着」伪装成「断定不是目标」。
    """
    keys: set[str] = set()
    for path in _shell_consumer_files():
        text = path.read_text(encoding="utf-8")
        if not _SOURCES_DOTENV_RE.search(text):
            continue
        match = _REQUIRED_LOOP_RE.search(text)
        if match is None:
            raise AssertionError(
                f"{path.relative_to(REPO_ROOT)} source 了 .env 却没有 "
                "`for var in ...; do` 必需变量声明 —— 本扫描器够不到它读了哪些名字。"
                "请在该脚本里补上必需变量循环，或改本扫描器（不要让它静默漏扫）。"
            )
        keys |= set(match.group(1).split())
    return keys


def _env_example_keys() -> set[str]:
    keys: set[str] = set()
    for line in ENV_EXAMPLE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", stripped)
        if match:
            keys.add(match.group(1))
    return keys


def test_classification_table_is_disjoint():
    """两张分类表不得重叠——重叠会让判据①的语义变得含混。"""
    overlap = ENV_FILE_KEYS & OUT_OF_SCOPE_KEYS
    assert overlap == set(), f"同一个名字同时出现在两张分类表里: {sorted(overlap)}"


def test_discovered_keys_match_classification():
    """判据① —— 扫描全集与分类表精确相等（两个方向）。

    红了怎么办：
      - 多出来的名字 = 你新增/改名了一个消费者。把它归到 ENV_FILE_KEYS
        （部署时要配）或 OUT_OF_SCOPE_KEYS（附理由）。
      - 少了的名字 = 分类表有陈旧条目，或扫描器坏了。先确认扫描器还能扫到东西。
    """
    discovered = _scan_python_keys() | _scan_shell_keys()
    expected = ENV_FILE_KEYS | OUT_OF_SCOPE_KEYS
    assert discovered == expected, (
        f"扫描全集与分类表不符\n"
        f"  扫到但没归类: {sorted(discovered - expected)}\n"
        f"  归类了但没扫到: {sorted(expected - discovered)}"
    )


def test_env_file_keys_are_all_defined_in_env_example():
    """判据② —— 该进配置样例的名字，每一个都要有同名 `KEY=` 行。"""
    defined = _env_example_keys()
    missing = ENV_FILE_KEYS - defined
    assert missing == set(), (
        f".env.example 缺少这些消费者读取的名字: {sorted(missing)}"
        f"（已定义: {sorted(defined)}）"
    )
```

- [ ] **Step 2: 跑测试，确认它**因为正确的理由**变红**

```bash
PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
WT="/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-backend"
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_env_example_coverage.py -q 2>&1 | tail -25
```

预期：**恰好 1 条红** —— `test_env_file_keys_are_all_defined_in_env_example`，失败信息里 `缺少这些消费者读取的名字: ['DATABASE_URL']`。

⚠️ 若 `test_discovered_keys_match_classification` 也红，说明扫描全集与 spec §2.5-a 的实测表对不上（可能是 main 又前进了）。**先查清楚多/少了什么再动手**，不要直接改分类表凑绿。

- [ ] **Step 3: 补 `.env.example`（用 Edit 工具，不要用 Bash）**

把 `backend/.env.example` 改成：

```
# NAS 端 PostgreSQL 配置
NAS_HOST=192.168.1.xxx
POSTGRES_USER=kline
POSTGRES_PASSWORD=changeme
POSTGRES_DB=kline_trainer
# 宿主侧管理用 DSN（scripts/nas-preflight.sh 的必需变量循环读它）：从宿主连 NAS 的 5433 端口。
DB_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${NAS_HOST}:5433/${POSTGRES_DB}
# 后端代码读的 DSN（app/main.py / app/scheduler_main.py / import_csv.py / generate_training_sets.py）。
# 容器内走 compose 内网服务名 db:5432，不经宿主端口。
# ⚠️ 缺失或为空串时 app/main.py 会**静默**回落 InMemory 假件——手机会「下载成功」却一个训练组都没有。
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}
# FastAPI
API_HOST=0.0.0.0
API_PORT=8000
```

⚠️ **`DB_URL` 那一行的取值一个字都不要动**（spec C1-6：改名会直接打断 `nas-preflight.sh` 的必需变量检查）。本步只加注释和新的一行。

- [ ] **Step 4: 跑测试，确认三条全绿**

```bash
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_env_example_coverage.py -q 2>&1 | tail -10
```

预期：`3 passed`。（这就是 T2-6 正向档。）

- [ ] **Step 5: 变异验证 T2-2 —— 从 `.env.example` 删掉 `DATABASE_URL`**

按「变异验证标准配方」执行。变异动作：删掉 `DATABASE_URL=` 那一行（**保留**注释，证明判据认的是 `KEY=` 行不是注释）。

预期红的**具名**测试：`test_env_file_keys_are_all_defined_in_env_example`，且只有它。

- [ ] **Step 6: 变异验证 T2-3 —— 从 `.env.example` 删掉 `DB_URL`**

这一档专门证明「扫描真的覆盖了 shell 消费者那一半」，不是只测了 Python 那一半。

预期红的**具名**测试：`test_env_file_keys_are_all_defined_in_env_example`（信息里 `缺少 ... ['DB_URL']`）。

⚠️ 删 `DB_URL=` 行时，下面 `DATABASE_URL=` 行里的 `${POSTGRES_USER}` 等不受影响（`.env.example` 只是文本样例，不求值）。

- [ ] **Step 7: 变异验证 T2-4 —— 改代码侧的名字**

变异 `backend/app/main.py:16`：`os.environ.get("DATABASE_URL")` → `os.environ.get("DATABASE_URL_RENAMED")`。

预期红的**具名**测试：`test_discovered_keys_match_classification`，失败信息里 `扫到但没归类: ['DATABASE_URL_RENAMED']`。

⚠️ 注意 `test_env_file_keys_are_all_defined_in_env_example` **不会**红（另外三个文件仍在读 `DATABASE_URL`，分类表没变）。这正是两条判据分工不同的证据——**把红的具名测试抄进记录**。

- [ ] **Step 8: 变异验证 T2-5 —— 新增一个读未定义变量的消费者**

变异动作：在 `backend/` 下新建一个临时文件 `backend/_mut_probe.py`，内容一行：

```python
import os; _ = os.environ.get("TOTALLY_NEW_DSN")
```

预期红的**具名**测试：`test_discovered_keys_match_classification`，`扫到但没归类: ['TOTALLY_NEW_DSN']`。

这一档证明扫描是**枚举式**的，不是写死那几个名字。

复原：`rm backend/_mut_probe.py` + 清 `__pycache__` + 重跑回绿。

- [ ] **Step 9: 变异验证「防空转」—— 把扫描器打瘸**

变异 `_python_consumer_files()`：`return out` → `return []`。

预期红的**具名**测试：`test_discovered_keys_match_classification`（`归类了但没扫到` 里出现全部 Python 侧的名字）。

这一档证明判据①真的是反向断言：扫描器坏掉不会静默变绿。

- [ ] **Step 10: 变异验证 shell 侧 fail-closed**

变异 `scripts/nas-preflight.sh`：把 `for var in NAS_HOST POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB DB_URL; do` 这一行改成 `for v in NAS_HOST POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB DB_URL; do`（把 `var` 改成 `v`，模拟「换了个写法，扫描器够不着了」）。

预期：`test_discovered_keys_match_classification` 红，且失败原因是 `_scan_shell_keys()` **抛出 AssertionError**，信息里含「source 了 .env 却没有 ... 必需变量声明」。

⚠️ 这证明扫描器**不会**把「判据够不着」伪装成「零消费者」静默通过。

复原后重跑回绿。⚠️ 本步改的是 `scripts/nas-preflight.sh`，**复原务必用 `cp` 回来**并 `git status` 确认该文件回到未修改状态。

- [ ] **Step 11: 跑全量后端套件，确认零回归**

```bash
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/ -q 2>&1 | tail -15
```

预期：全绿，**且 `skipped` 为 0**（CI 把任何 skip 判失败）。判绿读**执行量与结论行本身**，不要只看有没有 `error` 字样。

- [ ] **Step 12: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-backend"
git add backend/.env.example backend/tests/test_env_example_coverage.py
git commit -m "fix(backend): .env.example 补 DATABASE_URL + 消费者覆盖守卫（C1-6/T2）

后端代码读的是 DATABASE_URL，而 .env.example 只定义了 DB_URL —— 名字对不上。
app/main.py:16-22 在 DSN 缺失时静默回落 InMemory 假件，所以这个错不会报出来，
只会让手机「下载成功」却一个训练组都没有。

守卫形状：AST 扫 backend/ 下非 tests 的 .py + 正则扫真的 source 了 .env 的 .sh，
得到消费者全集，与分类表精确相等比对（两个方向），再断言该进配置样例的名字
都有同名 KEY= 行。反向断言使扫描器坏掉时变红而不是静默变绿。

DB_URL 保留不动：scripts/nas-preflight.sh 的必需变量循环读它，改名会直接打断它。"
```

---

## Task 2: `/health` 暴露 repository 种类（C1-7 / T3 全族）

**Files:**
- Modify: `backend/app/routes.py`（新增一个函数）
- Modify: `backend/app/main.py:37-39`（`/health` 响应体加一个字段）
- Test: `backend/tests/test_health.py`（改既有断言 + 加三条）

**Interfaces:**
- Consumes: 无（与 Task 1 零耦合，可独立评审）
- Produces:
  - `app.routes.current_repository_kind() -> str` —— 取值恰好 `"asyncpg"` 或 `"inmemory"`。
  - `GET /health` 响应体：`{"status": "ok", "repository": "asyncpg" | "inmemory"}`。
  - 部署 runbook 的 P8 判据依赖这个字段；PR-2 的 compose 不依赖它。

- [ ] **Step 1: 先写失败测试**

把 `backend/tests/test_health.py` 整个替换为：

```python
# backend/tests/test_health.py
"""C1-7 / T3：/health 除 status 外还要暴露当前装配的 repository 种类。

为什么需要（spec §4-D5）：app/main.py 在 DATABASE_URL 缺失时**静默**回落
InMemoryLeaseRepository。手机拉到假数据时表面一切正常——这正是本仓反复踩的
假绿家族。这个字段把「有没有走 asyncpg」从不可验证变成一条 curl。

⚠️ /health 不在 openapi.yaml 里（该文件恰好 3 条 path，被 test_openapi.py
   ::test_three_endpoints_present 精确锁死），所以加字段不触碰契约冻结文件。
⚠️ 本文件不得 import asyncpg —— requirements-test.txt 里没有它，CI 会整套收集失败。
   T3-2 用一个不做任何事的假 pool 对象构造 AsyncpgLeaseRepository（其 __init__
   只是把 pool 存起来，实测 lease_repo.py:112-113）。
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import routes
from app.lease_repo import AsyncpgLeaseRepository, InMemoryLeaseRepository
from app.main import app

client = TestClient(app)


@pytest.fixture
def restore_default_repo():
    """存档/复原进程级默认 repo，避免污染同进程里的其它测试。

    （test_scheduler.py:346 也在做同样的复原动作——这个全局是共享的。）
    """
    saved = routes._default_repo
    yield
    routes.set_default_repo(saved)


def test_health_returns_200(restore_default_repo):
    """既有回归档，随 C1-7 更新为新契约：status 仍在，且多一个 repository 字段。"""
    routes.set_default_repo(InMemoryLeaseRepository())
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "repository": "inmemory"}


def test_health_reports_inmemory_when_inmemory_repo_assembled(restore_default_repo):
    """T3-1 正向档：装配 InMemory → repository == "inmemory"。"""
    routes.set_default_repo(InMemoryLeaseRepository())
    assert client.get("/health").json()["repository"] == "inmemory"


def test_health_reports_asyncpg_when_asyncpg_repo_assembled(restore_default_repo):
    """T3-2 正向档：装配 Asyncpg → repository == "asyncpg"。

    用假 pool，不需要真 PG，也不需要 asyncpg 这个包本身。
    """
    routes.set_default_repo(AsyncpgLeaseRepository(pool=object()))
    assert client.get("/health").json()["repository"] == "asyncpg"


def test_health_still_reports_status_ok(restore_default_repo):
    """T3-3：status 字段不得因为加了新字段而丢失（既有消费者不能被打断）。"""
    routes.set_default_repo(InMemoryLeaseRepository())
    assert client.get("/health").json()["status"] == "ok"
```

⚠️ `AsyncpgLeaseRepository(pool=object())` 用关键字实参 —— 实测其签名是 `def __init__(self, pool) -> None`（`lease_repo.py:112`），关键字名就是 `pool`。

- [ ] **Step 2: 跑测试，确认它**因为正确的理由**变红**

```bash
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_health.py -q 2>&1 | tail -25
```

预期：**3 条红**（`test_health_returns_200` / `..._reports_inmemory_...` / `..._reports_asyncpg_...`），红的原因都是响应体里**没有** `repository` 键（`KeyError: 'repository'` 或字典不相等）。`test_health_still_reports_status_ok` 应当**是绿的**（`status` 本来就在）。

- [ ] **Step 3: 在 `routes.py` 里加判定函数**

在 `backend/app/routes.py` 的 `get_repository()` 之后（第 35 行后）插入：

```python
def current_repository_kind() -> str:
    """当前进程装配的 repository 种类，取值**恰好**两个字面量（spec §4-D5）。

    - 请求时求值：lifespan 会在 startup 把 _default_repo 换成 Asyncpg 版本。
    - 固定字面量而非类名派生：类名派生会得到 "asyncpgleaserepository" 这种。
    - 不写第三个取值：_default_repo 未设的第三态在组合根不可达
      （app/main.py 模块 import 即 set_default_repo(InMemoryLeaseRepository())），
      按 CLAUDE.md §2 不为不可达场景写分支；isinstance 对 None 自然落到 "inmemory"。
    - 刻意读模块全局而非经 Depends(get_repository)：后者在 _default_repo is None 时
      抛 RuntimeError，会让健康检查端点变成 500。代价是测试里的 dependency_overrides
      不会反映到 /health —— 生产路径不用 overrides，无分歧。
    """
    return "asyncpg" if isinstance(_default_repo, AsyncpgLeaseRepository) else "inmemory"
```

并把 `routes.py` 第 17 行的 import 改为：

```python
from app.lease_repo import AsyncpgLeaseRepository, LeaseRepository
```

⚠️ 这个 import 是安全的：`app/lease_repo.py` **顶层不 import asyncpg**（实测 `lease_repo.py:1-20`，注释里写明「asyncpg 局部 import」），所以在没装 asyncpg 的 CI 上照样能 import。

- [ ] **Step 4: 在 `main.py` 里接上**

把 `backend/app/main.py` 结尾的 `/health` 改为：

```python
@app.get("/health")
async def health():
    # repository 字段（spec §4-D5）：DATABASE_URL 缺失时后端会静默回落 InMemory，
    # 这个字段让「有没有真连上 PG」变成一条可 curl 的判据。
    return {"status": "ok", "repository": routes.current_repository_kind()}
```

- [ ] **Step 5: 跑测试，确认四条全绿**

```bash
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_health.py -q 2>&1 | tail -10
```

预期：`4 passed`。

- [ ] **Step 6: 变异验证 T3-4 方向一 —— 写死 `"inmemory"`**

变异 `routes.py` 的 `current_repository_kind`：整个函数体改成 `return "inmemory"`。

预期红的**具名**测试：`test_health_reports_asyncpg_when_asyncpg_repo_assembled`（**只有它**）。

- [ ] **Step 7: 变异验证 T3-4 方向二 —— 写死 `"asyncpg"`**

变异同一个函数：函数体改成 `return "asyncpg"`。

预期红的**具名**测试：`test_health_reports_inmemory_when_inmemory_repo_assembled` **和** `test_health_returns_200`（后者是精确相等断言）。

⚠️ 两个方向都要跑。只跑一个方向的话，一个「无条件返回某个值」的空实现会让另一半判据形同虚设（`feedback_all_reject_suite_masks_always_throwing_guard` 同型）。

- [ ] **Step 8: 变异验证 T3-3 —— 删掉 `status` 字段**

变异 `main.py` 的 `/health`：`return {"repository": routes.current_repository_kind()}`（删掉 `"status": "ok"`）。

预期红的**具名**测试：`test_health_still_reports_status_ok` **和** `test_health_returns_200`。

- [ ] **Step 9: 验证「CI 上没有 asyncpg」这条约束真的成立**

⚠️ **本机 `.venv` 里装了 asyncpg 0.31.0（实测），而 CI 的 `requirements-test.txt` 里没有** —— 也就是说本机跑绿**对这条约束零判别力**。必须模拟：

```bash
SHIM=/private/tmp/claude-501/-Users-maziming-Coding-Prj-Kline-trainer/be126ed9-ea66-4272-a8a9-2f3710a7c21c/scratchpad/noasyncpg
mkdir -p "$SHIM"
printf 'raise ImportError("asyncpg is not installed (simulated CI)")\n' > "$SHIM/asyncpg.py"
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$SHIM" "$PY" -m pytest tests/test_health.py -q 2>&1 | tail -10
```

预期：仍然 `4 passed`。若这里红了，说明测试或 `routes.py` 的 import 链在某处需要 asyncpg —— **必须修好再往下**，否则 CI 会整套收集失败（`feedback_test_imports_must_not_need_optional_deps`）。

- [ ] **Step 10: 跑全量后端套件，确认零回归**

```bash
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/ -q 2>&1 | tail -15
```

预期：全绿且 `skipped` 为 0。

⚠️ 特别注意 `tests/test_openapi.py::test_three_endpoints_present` 必须仍然绿（证明我们没有把 `/health` 混进契约冻结文件）。

- [ ] **Step 11: 用 `PYTHONPATH` 模拟 CI 再跑一次全量**

```bash
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$SHIM" "$PY" -m pytest tests/ -q 2>&1 | tail -15
```

预期：全绿。（若既有某个测试本来就需要 asyncpg，这里会红 —— 那是**先于本 PR 存在**的情况，记下来别顺手改，回报给控制者判断。）

- [ ] **Step 12: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-backend"
git add backend/app/routes.py backend/app/main.py backend/tests/test_health.py
git commit -m "feat(backend): /health 暴露当前装配的 repository 种类（C1-7）

DATABASE_URL 缺失时 app/main.py 会静默回落 InMemory 假件，服务照样 200 地跑着，
只是一行数据都没有。这个字段把「有没有真连上 PG」从不可验证变成一条 curl。

取值恰好两个字面量 asyncpg / inmemory，请求时求值（lifespan 会在 startup 换掉
_default_repo）。不写第三个取值：未设态在组合根不可达。

/health 不在 openapi.yaml 里（该文件恰好 3 条 path 且被测试锁死），未触碰契约冻结文件。
既有 test_health_returns_200 的精确相等断言随契约一并更新。"
```

---

## Task 3: 非程序员验收清单

**Files:**
- Create: `docs/superpowers/plans/2026-08-24-qmt-nas-pr1-acceptance.md`

**Interfaces:**
- Consumes: Task 1 与 Task 2 的成品
- Produces: 一份 user 可独立执行的清单（CLAUDE.md 治理底线第 2 条要求每个交付都带）

- [ ] **Step 1: 写清单**

新建 `docs/superpowers/plans/2026-08-24-qmt-nas-pr1-acceptance.md`：

````markdown
# PR-1 验收清单（配置覆盖守卫 + `/health` 暴露 repository）

> 面向非程序员。一行一条命令，从上往下照做。命令里出现的 `PY=` 一行只需在**每个新开的终端窗口**跑一次。
> 本 PR **不涉及** NAS、不涉及手机、不部署任何东西 —— 它只改仓库里的三个文件加两个测试文件。

## 准备（每个新终端窗口跑一次）

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 粘贴：`PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"` | 没有任何输出 | 光标回到新的一行 |
| 粘贴：`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-backend/backend"` | 没有任何输出 | 光标回到新的一行 |

## 一、看得见的行为：健康检查现在会告诉你连的是真库还是假库

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 粘贴：`"$PY" -c "from fastapi.testclient import TestClient; from app.main import app; print(TestClient(app).get('/health').json())"` | 屏幕打印一行字典 | 那一行**恰好**是 `{'status': 'ok', 'repository': 'inmemory'}` |

这条的意思：没给数据库地址时，后端用的是**内存里的假库**，而现在它会**明说**。改这个字段之前，它只回一句 `ok`，你无法分辨手机拉到的是真数据还是空气。

## 二、自动检查：三条守卫都在岗

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 粘贴：`"$PY" -m pytest tests/test_env_example_coverage.py tests/test_health.py -q` | 最后一行出现测试统计 | 最后一行含 `7 passed`，且**不含** `failed`、`error`、`skipped` |

## 三、整套后端测试没有被弄坏

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 粘贴：`"$PY" -m pytest tests/ -q` | 跑几十秒后打印统计 | 最后一行含 `passed`，且**不含** `failed`、`error`、`skipped` |

⚠️ 出现 `skipped` 也算不通过 —— 本仓的持续集成把「跳过」当失败处理。

## 四、配置样例文件确实补上了

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 用「文本编辑」打开 `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-backend/backend/.env.example` | 看到 9 行左右的配置样例 | 文件里**同时**有 `DB_URL=` 开头的一行**和** `DATABASE_URL=` 开头的一行 |

这条的意思：两个名字**都要在**。`DB_URL` 是从你的电脑连 NAS 用的，`DATABASE_URL` 是后端程序自己读的 —— 之前只有前者，所以后端一直读不到，会悄悄换成假库。

## 五、本 PR **没有**做到的事（防止误以为已完成）

- 后端**还没有**部署到 NAS，手机**还拉不到**任何东西。
- `/health` 现在能报 `asyncpg`，但那要等后端真的连上 NAS 上的数据库之后才会出现。
- 训练组数据**没有**被搬动，NAS 上什么都没变。
````

- [ ] **Step 2: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-backend"
git add docs/superpowers/plans/2026-08-24-qmt-nas-pr1-acceptance.md
git commit -m "docs(qmt-nas): PR-1 非程序员验收清单（动作/预期/通过条件三列）"
```

---

## 收尾：绿门（控制者亲跑，缺一不可）

⚠️ **控制者必须亲手跑一遍，不接受实施者报的数字**（`feedback_controller_must_run_gates_himself`）。每条命令都要**同时打印 branch 与 HEAD**，防「叙述的 HEAD ≠ 实际跑的 HEAD」。

- [ ] **门 1 · 全量后端套件**

```bash
WT="/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-backend"
PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
cd "$WT" && echo "branch=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)"
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/ -q 2>&1 | tail -15
```

判绿：结论行含 `passed`、**不含** `failed` / `error` / `skipped`。⛔ 别用 `| tail -1` 判（多行汇总会被砍掉，`feedback_gate_pipe_swallows_exit_code` 同族）。

- [ ] **门 2 · 模拟 CI（无 asyncpg）全量套件**

同上，命令前加 `PYTHONPATH="$SHIM"`。判绿标准同门 1。

- [ ] **门 3 · 变异验证账目齐全**

逐条核对下表，每一行都要有「红的具名测试」实测记录，不许留空：

| 编号 | 变异 | 应变红的具名测试 |
|---|---|---|
| T2-2 | `.env.example` 删 `DATABASE_URL=` 行 | `test_env_file_keys_are_all_defined_in_env_example` |
| T2-3 | `.env.example` 删 `DB_URL=` 行 | `test_env_file_keys_are_all_defined_in_env_example` |
| T2-4 | `main.py` 改读 `DATABASE_URL_RENAMED` | `test_discovered_keys_match_classification` |
| T2-5 | 新增 `backend/_mut_probe.py` 读新变量 | `test_discovered_keys_match_classification` |
| T2-防空转 | `_python_consumer_files()` 返回 `[]` | `test_discovered_keys_match_classification` |
| T2-shell | `nas-preflight.sh` 的 `for var` 改 `for v` | `test_discovered_keys_match_classification`（AssertionError 路径） |
| T3-4a | `current_repository_kind` 写死 `"inmemory"` | `test_health_reports_asyncpg_when_asyncpg_repo_assembled` |
| T3-4b | `current_repository_kind` 写死 `"asyncpg"` | `test_health_reports_inmemory_when_inmemory_repo_assembled` + `test_health_returns_200` |
| T3-3 | `/health` 删 `"status": "ok"` | `test_health_still_reports_status_ok` + `test_health_returns_200` |

- [ ] **门 4 · 工作树干净**

```bash
cd "$WT" && git status --porcelain
```

判绿：**零输出**。若有残留，多半是某次变异没复原（尤其 `scripts/nas-preflight.sh` 与 `backend/_mut_probe.py`）。

- [ ] **门 5 · 改动范围符合 plan**

```bash
cd "$WT" && git diff --stat origin/main...HEAD
```

判绿：改动文件**恰好**是——`backend/.env.example`、`backend/tests/test_env_example_coverage.py`、`backend/app/routes.py`、`backend/app/main.py`、`backend/tests/test_health.py`、`docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md`、`docs/superpowers/plans/2026-08-24-qmt-nas-pr1-config-coverage-and-health.md`、`docs/superpowers/plans/2026-08-24-qmt-nas-pr1-acceptance.md`。多一个都要解释。

---

## 收尾：对抗性评审

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
bash .claude/scripts/codex-attest.sh --scope branch-diff --head feat/qmt-nas-backend --base origin/main
```

纪律（`feedback_codex_focus_narrowing_false_approve` / `feedback_codex_attest_unknown_arg_becomes_focus`）：

- **零 focus 窄化**，只认 `--scope branch-diff`；
- ⛔ **绝不传未知参数**（含 `--help`）—— 兜底分支会把任何未知参数当 focus 目标 → 假 approve + 写脏账本；
- 出裁决后进程**不自退**，要手动 kill；⛔ 别用 `| tail` 接它的输出（会缓冲到命令结束才吐字，看起来像没跑）；
- 被杀（日志里**没有** `Verdict:` 行）**不计轮次**，重跑；
- attest 之后**别 rebase**；账本必须 **Read 文件**核实 `head_sha` == 实际 HEAD；
- 拿到 approve 先确认它**真跑了测试**；没真 approve 就如实写 needs-attention / 接受残留 / override，**不得**写「收敛」。

---

## Self-Review（写完计划后自查，已执行）

**1. spec 覆盖**

| spec 条目 | 落在哪 |
|---|---|
| C1-6（`.env.example` 覆盖消费者） | Task 1 Step 3 |
| C1-7（`/health` 加 `repository`） | Task 2 Step 3-4 |
| T2-1（整族扫描，订正版判据） | Task 1 Step 1 的两条断言 |
| T2-2 / T2-3 / T2-4 / T2-5 / T2-6 | Task 1 Step 5 / 6 / 7 / 8 / 4 |
| T3-1 / T3-2 / T3-3 / T3-4 | Task 2 Step 1 的四条测试 + Step 6/7/8 变异 |
| §5.2「已知会变红的既有测试」（`test_health_returns_200`） | Task 2 Step 1 已按新契约更新，Step 2 明确它是预期先红 |
| §9.3 验收清单形态（中文/三列/非程序员可执行） | Task 3 |
| §12 流程（TDD 先红 / 变异验证 / branch-diff 评审） | 每个 Task 的 Step 2 + 「收尾」两节 |

**不在本 PR 的 spec 条目**（归 PR-2 / PR-3，已在各自 plan 里）：C1-1..C1-5、C1-8、C1-9、T1、T4、T5、T6、T7、§6 全部、§7 runbook。

**2. 占位符扫描**：无 TBD / TODO / 「类似 Task N」/「适当处理错误」。每个代码步骤都给了逐字内容。

**3. 类型一致性**：`current_repository_kind()` 在 Task 2 Step 3 定义、Step 4 调用、收尾门 3 的变异表里引用 —— 三处同名。`AsyncpgLeaseRepository(pool=...)` 的关键字实参名与实测签名 `def __init__(self, pool)` 一致。测试函数名在 Task 2 Step 1 定义、Step 6/7/8 与门 3 引用 —— 逐条同名。
