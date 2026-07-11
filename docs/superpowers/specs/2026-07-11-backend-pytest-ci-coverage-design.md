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

1. **套件依赖面（已实测厘清）**：`asyncpg` **无任何被测模块顶层 import**、`uvicorn` 只出现在一句注释、`pandas_ta` **后端代码零引用** → 三者排除。但 `apscheduler` **被 `test_scheduler.py` 4 处 `importorskip`**，缺它这 4 个用例静默 skip（`166 passed + 4 skipped`）→ **必须纳入**。装 9 个直接依赖的全新 venv：`170 passed, 0 skipped`（`--collect-only` 恒收 170，skip 只在运行期发生，故验证口径必须含「0 skipped」而非只看 passed 数）。
2. **`pandas-ta` 是安装陷阱**：`requirements.txt` 里的 `pandas-ta==0.3.14b1` 用了已被删除的 `numpy.NaN`，在现代 numpy 上安装/导入即失败——且它对测试毫无用处。故 CI 依赖清单**刻意排除**它。
3. **`sys.path` 机制（已实测厘清）**：测试靠 `from app.main import app` / `from qmt_normalize import ...` 这类顶层导入（模块住在 `backend/`）。存在 `backend/tests/__init__.py`（tests 是包），pytest 的 `prepend` 导入模式向上找到最顶层非包目录 = `backend/`，将其注入 `sys.path`。**该机制与 CWD、与裸 `pytest`/`python -m pytest` 均无关**——实测四种组合（仓库根 / `backend/` × 裸 / `python -m`）都 `170 passed`。故 `working-directory: backend` **非** import 硬性所需，仅为本地开发习惯 + 让 `requirements-test.txt` 路径就近；CI 采用 **`python -m pytest`** 是取其「保证 CWD 入 `sys.path`」的稳健标准形，非因裸 `pytest` 会失败。
4. **根 `pytest.ini`**：仓库根有被 git 跟踪的 `pytest.ini`（`testpaths=tests` + `python_files/classes/functions` 收集规则），pytest 认它为 `configfile`、rootdir=仓库根。改动它可影响后端测试的收集/执行，故必须纳入 workflow 的 `paths:` 触发集（否则改 `pytest.ini` 的 PR 不会触发后端测试 = 静默覆盖缺口。codex plan review R1 medium finding）。

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
apscheduler==3.10.4
pandas==2.2.3
numpy==2.4.6
```

- `httpx`：`fastapi.testclient.TestClient` 需要（`test_health` / `test_routes`）。
- `fastapi`：拉起 `starlette` + `anyio`（传递依赖，pip 自动解析）。
- `pglast` / `openapi-spec-validator` / `pyyaml`：来自 `requirements-dev.txt` 的既有测试依赖。
- `fastapi` / `pandas` / `numpy`：来自 `requirements.txt` 的生产依赖里测试真正 import 的。
- **`apscheduler`（实测必需）**：`test_scheduler.py` 有 4 处 `pytest.importorskip("apscheduler")`，缺它这 4 个用例静默 skip → `166 passed + 4 skipped` 而非 `170 passed`。缺它 = 覆盖缺口，故纳入。
- **排除**：`pandas-ta`（陷阱，零引用）、`uvicorn`（仅注释）、`asyncpg`（无测试顶层或 importorskip 依赖它；补 apscheduler 后 `from app.scheduler import build_scheduler` 无需 asyncpg 即成功）。

**已知取舍**：这是独立于 `requirements.txt` 的第三个依赖文件，存在漂移风险——未来若某个测试真的 import 了 `asyncpg`，CI 会报 `ImportError` 当场变红（**可见失败，非静默失效**），届时补进本文件即可。选它是因为装 `requirements.txt` 会撞上 `pandas-ta` 陷阱。**验证口径升级**：不止「170 passed」，还须 **0 skipped**（否则可能又漏了某个 importorskip 依赖）。

### 文件 2：`.github/workflows/backend-tests.yml`（新增）

```yaml
name: Backend Tests

on:
  pull_request:
    paths:
      - 'backend/**'
      - 'pytest.ini'
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
      - name: Run full backend suite (fail on any skip)
        working-directory: backend
        run: |
          python -m pytest tests/ -q -rs --junitxml="${RUNNER_TEMP:-/tmp}/pytest-report.xml"
          python - <<'PY'
          import os, sys, xml.etree.ElementTree as ET
          path = os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "pytest-report.xml")
          root = ET.parse(path).getroot()
          skipped = sum(int(s.get("skipped", 0)) for s in root.iter("testsuite"))
          if skipped:
              print(f"FAIL: {skipped} skipped test(s) — requirements-test.txt 漂移/覆盖缺口，CI 拒绝静默 skip")
              sys.exit(1)
          print("OK: 0 skipped")
          PY
```

对齐仓库 trust-boundary 硬化约定：
- `permissions: contents: read`（最小权限，无写作用域）。
- 所有 action 钉到**完整 SHA**（与 `schema-smoke.yml` / `openapi-smoke.yml` 一致；实施时复制它们已用的 SHA）。
- `paths:` 只触发后端相关改动——因为**不设必需检查**，路径过滤是纯收益（省 iOS-only PR 的 CI 时间），恰好避开「路径过滤 + 被设必需 = 永久阻塞」那个既有坑。
- `push: branches: [main]` 无路径过滤，保证 main 每次推都全量跑。
- **skip 守卫（codex branch review medium finding）**：裸 `pytest -q` 对 skip 仍返回 0 → 若 `requirements-test.txt` 漂移丢了 `apscheduler` 之类 `importorskip` 依赖，CI 会绿着 skip 掉正是本工作要保护的 scheduler 覆盖。故解析 junit XML，`skipped>0` 即 fail。双向 mutation 实证：全依赖→`OK: 0 skipped (passed=170)` 退 0；卸 apscheduler→`FAIL: 4 skipped` 退 1。

## 验证

1. **实施前置门**：在 scratchpad 建**全新** 3.11 venv，只 `pip install -r requirements-test.txt`，跑 `python -m pytest tests/ -q` 必须 `170 passed`——证明依赖清单自足（不靠我现有 venv 里多装的包）。
2. **空环境负向基线**：同一全新 venv 在**未装依赖**前跑测试必须失败（`ModuleNotFoundError`），证明 170 passed 是依赖清单的功劳、非宿主残留。
3. **CI 验证**：PR 上 `Backend Tests` job 绿、报 `170 passed`。

## 流程

治理/CI 变更，`.github/workflows` 是 trust-boundary：
brainstorming（本文档）→ writing-plans → 实施 → **codex:adversarial-review** → user 真终端开 PR。
