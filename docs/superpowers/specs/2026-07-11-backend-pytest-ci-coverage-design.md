# 后端完整 pytest CI 覆盖 — 设计

**日期**：2026-07-11
**类型**：治理 / CI 变更（`.github/workflows` 属 trust-boundary）
**分支**：`ci/backend-pytest-coverage`（base = `main` @ `b4ec1e6`）

## 问题

仓库**没有任何 workflow 跑 `backend/tests/` 全套件**。现状覆盖：

| 现有 workflow | 跑的测试 | 用例数 |
|---|---|---|
| `openapi-smoke.yml` | 仅 `tests/test_openapi.py`（且 `paths:` 过滤） | 19 |
| `schema-smoke.yml` | 仅 `tests/test_schema.py`（PR 事件被 `paths:` 挡，见注） | 8 |

后端实际有 **11 个测试文件、170 个用例**。**143 个用例零 CI 覆盖**，其中包括刚合并的 QMT Plan 1 的 4 个文件（`test_qmt_normalize.py` 7 + `test_qmt_resample.py` 25 + `test_generate_training_sets.py` 26 + `test_scheduler.py` 22 = 80 个用例）。`170 passed` 目前只有本地 Python 3.11 venv 背书，GitHub 上无第二双眼睛。

> 注：`schema-smoke` 在 PR 上也受 `paths: backend/sql/**` 过滤，QMT PR #141 未碰该路径故未触发；它只在 main 的 push 上跑过。

## 目标

新增一个 CI job，在每个改动后端的 PR 上跑**完整** `backend/tests/`，达到 `170 passed`，与本地一致。

**非目标**（本次明确不做）：
- 不把新 job 设为 ruleset 必需检查（留给「拆掉 3 个坏必需检查」那一轮一起做）。
- 不修 `codex-review-verify` 的浅克隆 bug（独立议题）。
- 不改任何现有 workflow / 现有测试 / 生产代码。

## 关键事实（均实测）

1. **套件不需要重依赖**：`asyncpg` / `apscheduler` **无任何被测模块顶层 import**；`uvicorn` 只出现在一句注释；`pandas_ta` **后端代码零引用**。只装 8 个直接依赖的 venv，`pytest --collect-only` 收齐 **170 tests collected**、`pytest -q` 得 **170 passed**。
2. **`pandas-ta` 是安装陷阱**：`requirements.txt` 里的 `pandas-ta==0.3.14b1` 用了已被删除的 `numpy.NaN`，在现代 numpy 上安装/导入即失败——且它对测试毫无用处。故 CI 依赖清单**刻意排除**它。
3. **`sys.path` 命门**：`backend/` 下无 `conftest.py`、无 `pytest.ini`。测试靠 `from app.main import app` / `from qmt_normalize import ...` 这类顶层导入，只有在 `backend/` 目录内用 **`python -m pytest`**（而非裸 `pytest`）才会把 `backend/` 注入 `sys.path`。CI 步骤必须 `working-directory: backend` + `python -m pytest`，否则 collection error。

## 设计

### 文件 1：`backend/requirements-test.txt`（新增）

跑测试所需的最小依赖集，版本对齐本地跑绿的 3.11 venv：

```
pytest==8.4.2
httpx==0.28.1
pglast==7.13
openapi-spec-validator==0.7.2
pyyaml==6.0.3
fastapi==0.115.12
pandas==2.2.3
numpy==2.4.6
```

- `httpx`：`fastapi.testclient.TestClient` 需要（`test_health` / `test_routes`）。
- `fastapi`：拉起 `starlette` + `anyio`（传递依赖，pip 自动解析）。
- `pglast` / `openapi-spec-validator` / `pyyaml`：来自 `requirements-dev.txt` 的既有测试依赖。
- `fastapi` / `pandas` / `numpy`：来自 `requirements.txt` 的生产依赖里测试真正 import 的三个。
- **排除**：`pandas-ta`（陷阱，零引用）、`uvicorn`（仅注释）、`asyncpg` / `apscheduler`（测试不 import）。

**已知取舍**：这是独立于 `requirements.txt` 的第三个依赖文件，存在漂移风险——未来若某个测试真的 import 了 `asyncpg`，CI 会报 `ImportError` 当场变红（**可见失败，非静默失效**），届时补进本文件即可。选它是因为装 `requirements.txt` 会撞上 `pandas-ta` 陷阱。

### 文件 2：`.github/workflows/backend-tests.yml`（新增）

```yaml
name: Backend Tests

on:
  pull_request:
    paths:
      - 'backend/**'
      - '.github/workflows/backend-tests.yml'
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  pytest:
    name: backend pytest (full suite)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<pinned-full-sha>
      - name: Setup Python 3.11
        uses: actions/setup-python@<pinned-full-sha>
        with:
          python-version: '3.11'
      - name: Install test deps
        working-directory: backend
        run: python -m pip install -r requirements-test.txt
      - name: Run full backend suite
        working-directory: backend
        run: python -m pytest tests/ -q
```

对齐仓库 trust-boundary 硬化约定：
- `permissions: contents: read`（最小权限，无写作用域）。
- 所有 action 钉到**完整 SHA**（与 `schema-smoke.yml` / `openapi-smoke.yml` 一致；实施时复制它们已用的 SHA）。
- `paths:` 只触发后端相关改动——因为**不设必需检查**，路径过滤是纯收益（省 iOS-only PR 的 CI 时间），恰好避开「路径过滤 + 被设必需 = 永久阻塞」那个既有坑。
- `push: branches: [main]` 无路径过滤，保证 main 每次推都全量跑。

## 验证

1. **实施前置门**：在 scratchpad 建**全新** 3.11 venv，只 `pip install -r requirements-test.txt`，跑 `python -m pytest tests/ -q` 必须 `170 passed`——证明依赖清单自足（不靠我现有 venv 里多装的包）。
2. **CI 验证**：PR 上 `Backend Tests` job 绿、报 `170 passed`。
3. **负向确认**：确认 job 在裸 `pytest`（非 `python -m`）下会 collection error——证明 `working-directory` + `python -m` 这两点确实必要（仅本地演示，不写进 CI）。

## 流程

治理/CI 变更，`.github/workflows` 是 trust-boundary：
brainstorming（本文档）→ writing-plans → 实施 → **codex:adversarial-review** → user 真终端开 PR。
