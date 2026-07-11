# 后端完整 pytest CI 覆盖 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增一个 GitHub Actions job，在每个改动后端的 PR 上跑完整 `backend/tests/`（170 用例），并新增一份最小测试依赖清单支撑它。

**Architecture:** 两个新文件，零改动现有文件。`backend/requirements-test.txt` 列出跑测试所需的 8 个依赖（刻意排除安装陷阱 `pandas-ta` 及测试用不到的 `uvicorn`/`asyncpg`/`apscheduler`）；`.github/workflows/backend-tests.yml` 在 `paths: backend/**` 触发下用 Python 3.11 + `working-directory: backend` + `python -m pytest tests/ -q` 跑全套。不设 ruleset 必需检查。

**Tech Stack:** GitHub Actions、Python 3.11、pytest 8.4.2、pip。

## Global Constraints

- **Python 版本 = 3.11**（对齐现有 `openapi-smoke.yml` / CI；宿主 `python3.11` = `/opt/homebrew/bin/python3.11` = 3.11.15）。
- **`sys.path` 命门**：`backend/` 下无 `conftest.py`/`pytest.ini`，测试靠 `from app.main import app` 等顶层导入 → 必须 `working-directory: backend` + **`python -m pytest`**（非裸 `pytest`），否则 collection error。
- **依赖清单刻意排除** `pandas-ta`（后端零引用，`0.3.14b1` 用了已删除的 `numpy.NaN`，新 numpy 上装/导入即失败）、`uvicorn`（仅注释）、`asyncpg`/`apscheduler`（测试不 import）。
- **trust-boundary 硬化约定**：`permissions: contents: read`；action 钉完整 SHA — checkout=`11bd71901bbe5b1630ceea73d27597364c9af683`、setup-python=`0b93645e9fea7318ecaed2b359559ac225c90a2b`（复制自现有 workflow，勿改）。
- **不设必需检查**：本 PR 只新增 workflow，不动 GitHub ruleset。
- **提交纪律**：只 `git add` 本任务明确列出的文件，绝不 `git add -A`（未跟踪的 `docs/superpowers/mockups/2026-06-29-topbar-distribution.html` 必须保持未跟踪）。

---

### Task 1: 测试依赖清单 `requirements-test.txt`

**Files:**
- Create: `backend/requirements-test.txt`

**Interfaces:**
- Consumes: 无。
- Produces: `backend/requirements-test.txt` — Task 2 的 workflow 用 `pip install -r requirements-test.txt` 安装它。

- [ ] **Step 1: 建立验证基线——全新 venv 未装依赖时测试必然失败**

先证明「空环境跑不起来」，确保后面的 170 passed 是依赖清单的功劳而非宿主残留。

Run:
```bash
SP=/private/tmp/claude-501/-Users-maziming-Coding-Prj-Kline-trainer/80380c0f-edac-4f2a-885d-6487d15b36a8/scratchpad
rm -rf "$SP/rt-venv"
/opt/homebrew/bin/python3.11 -m venv "$SP/rt-venv"
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && "$SP/rt-venv/bin/python" -m pytest tests/ -q 2>&1 | tail -5
```
Expected: 失败——`ModuleNotFoundError`（无 pytest / pandas 等），非 170 passed。

- [ ] **Step 2: 写依赖清单**

Create `backend/requirements-test.txt`（版本对齐 `requirements.txt` / `requirements-dev.txt` 与本地跑绿的 3.11 venv）：
```
# 后端测试专用依赖（仅跑 pytest 所需；与 requirements.txt 解耦以排除 pandas-ta 安装陷阱）
pytest==8.4.2
httpx==0.28.1
pglast==7.13
openapi-spec-validator==0.7.2
pyyaml==6.0.3
fastapi==0.115.12
pandas==2.2.3
numpy==2.4.6
```

- [ ] **Step 3: 在全新 venv 里只装本清单，跑全套件**

Run:
```bash
SP=/private/tmp/claude-501/-Users-maziming-Coding-Prj-Kline-trainer/80380c0f-edac-4f2a-885d-6487d15b36a8/scratchpad
"$SP/rt-venv/bin/pip" install -r "/Users/maziming/Coding/Prj_Kline trainer/backend/requirements-test.txt" 2>&1 | tail -3
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && "$SP/rt-venv/bin/python" -m pytest tests/ -q 2>&1 | tail -5
```
Expected: `170 passed`（无 error、无 skip 掩盖的 collection 失败）。若任何测试因缺依赖 `ImportError`，把缺的包按精确版本补进清单并重跑，直至 170 passed。

- [ ] **Step 4: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add backend/requirements-test.txt
git commit -m "test(ci): 新增 backend/requirements-test.txt 最小测试依赖清单

只列 pytest 所需 8 依赖，排除 pandas-ta 安装陷阱与测试不用的 uvicorn/asyncpg/apscheduler。
全新 3.11 venv 仅装本清单跑 backend/tests/ = 170 passed。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: CI workflow `backend-tests.yml`

**Files:**
- Create: `.github/workflows/backend-tests.yml`

**Interfaces:**
- Consumes: `backend/requirements-test.txt`（Task 1）。
- Produces: 名为 `Backend Tests` 的 workflow，job 名 `backend pytest (full suite)`（不设为 ruleset 必需检查）。

- [ ] **Step 1: 写 workflow**

Create `.github/workflows/backend-tests.yml`：
```yaml
name: Backend Tests

on:
  pull_request:
    paths:
      - 'backend/**'
      - '.github/workflows/backend-tests.yml'
  push:
    branches: [main]

# Trust-boundary 硬化（对齐 schema-smoke.yml / openapi-smoke.yml 约定）:
# - 最小权限：只读仓库内容，无写作用域
# - actions 钉完整 SHA
permissions:
  contents: read

jobs:
  pytest:
    name: backend pytest (full suite)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      - name: Setup Python 3.11
        uses: actions/setup-python@0b93645e9fea7318ecaed2b359559ac225c90a2b
        with:
          python-version: '3.11'
      - name: Install test deps
        working-directory: backend
        run: python -m pip install -r requirements-test.txt
      # sys.path 命门：backend/ 无 conftest.py/pytest.ini，
      # 必须 working-directory: backend + python -m pytest（非裸 pytest）
      - name: Run full backend suite
        working-directory: backend
        run: python -m pytest tests/ -q
```

- [ ] **Step 2: 校验 YAML 语法正确、结构符合预期**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
/opt/homebrew/bin/python3.11 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/backend-tests.yml')); \
assert d['jobs']['pytest']['steps'][2]['working-directory']=='backend'; \
assert d['jobs']['pytest']['steps'][3]['working-directory']=='backend'; \
assert 'python -m pytest' in d['jobs']['pytest']['steps'][3]['run']; \
assert d['permissions']['contents']=='read'; \
print('YAML OK: working-directory + python -m pytest + least-privilege 均就位')"
```
Expected: `YAML OK: ...`（任何 assert 失败即 workflow 写错，修正后重跑）。

- [ ] **Step 3: 本地模拟 CI 的确切命令，确认可跑绿**

复用 Task 1 已装好的 `rt-venv` 模拟 CI 的 install+run 两步（这两步与 workflow 的 `run:` 逐字一致）：
```bash
SP=/private/tmp/claude-501/-Users-maziming-Coding-Prj-Kline-trainer/80380c0f-edac-4f2a-885d-6487d15b36a8/scratchpad
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && "$SP/rt-venv/bin/python" -m pytest tests/ -q 2>&1 | tail -3
```
Expected: `170 passed`。

- [ ] **Step 4: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add .github/workflows/backend-tests.yml
git commit -m "ci: 新增 Backend Tests workflow 跑完整 pytest 套件

paths 过滤 backend/**；Python 3.11；working-directory:backend + python -m pytest
保 sys.path；最小权限 contents:read；action 钉 SHA。不设 ruleset 必需检查。
补齐仓库缺口：此前无任何 workflow 跑 backend/tests/ 全套，170 用例中 143 个零 CI 覆盖。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## 实施后（计划外，流程记录）

- 整分支走 `codex:adversarial-review`（`--scope branch-diff --head ci/backend-pytest-coverage --base origin/main`）到收敛。此时 diff 含 spec + 本计划 + 两个交付文件，codex 能真正评到 workflow YAML 与依赖清单。
- 收敛后 user 在真终端 `git push` + `gh pr create`（中文正文）+ 合并（guard 拦 Claude 的 push/PR/merge）。

## Self-Review

**1. Spec coverage**：
- spec「文件 1 requirements-test.txt / 8 依赖 / 排除 pandas-ta」→ Task 1 ✅
- spec「文件 2 backend-tests.yml / paths 过滤 / 3.11 / working-directory + python -m / 最小权限 / 钉 SHA / push main」→ Task 2 ✅
- spec「验证：全新 3.11 venv 仅装 requirements-test.txt 跑 170 passed」→ Task 1 Step 3 ✅
- spec「非目标：不设必需检查 / 不修 codex-review-verify / 不改现有文件」→ 全计划零改现有文件、无 ruleset 操作 ✅

**2. Placeholder scan**：无 TBD/TODO；所有 SHA、路径、命令、依赖版本均为实际值。✅

**3. Type consistency**：Task 2 引用的 `requirements-test.txt` 文件名与 Task 1 创建的一致；workflow 里 `python -m pytest tests/ -q` 与验证命令一致。✅
