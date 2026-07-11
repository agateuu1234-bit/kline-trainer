# 后端完整 pytest CI 覆盖 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增一个 GitHub Actions job，在每个改动后端的 PR 上跑完整 `backend/tests/`（170 用例），并新增一份最小测试依赖清单支撑它。

**Architecture:** 两个新文件，零改动现有文件。`backend/requirements-test.txt` 列出跑测试所需的 8 个依赖（刻意排除安装陷阱 `pandas-ta` 及测试用不到的 `uvicorn`/`asyncpg`/`apscheduler`）；`.github/workflows/backend-tests.yml` 在 `paths: backend/**` 触发下用 Python 3.11 + `working-directory: backend` + `python -m pytest tests/ -q` 跑全套。不设 ruleset 必需检查。

**Tech Stack:** GitHub Actions、Python 3.11、pytest 8.4.2、pip。

## Global Constraints

- **Python 版本 = 3.11**（对齐现有 `openapi-smoke.yml` / CI；宿主 `python3.11` = `/opt/homebrew/bin/python3.11` = 3.11.15）。
- **`sys.path` 机制（已实测）**：`backend/tests/__init__.py` 使 tests 成包，pytest `prepend` 导入模式向上找到最顶层非包目录 `backend/` 并注入 `sys.path`，故 `from app.main import app` / `from qmt_normalize import ...` 可解析——**与 CWD、与裸/`python -m` 无关**（四组合均 170 passed）。CI 用 `working-directory: backend` + `python -m pytest` 是习惯 + 稳健标准形，非 import 硬性所需；勿在文档或注释中声称「裸 pytest 会 collection error」（假论断，codex R1 排查时厘清）。
- **根 `pytest.ini` 纳入 paths**：仓库根有跟踪的 `pytest.ini`（pytest 认它为 configfile），改它可影响后端测试收集 → workflow `paths:` 必须含 `pytest.ini`（codex plan R1 medium finding）。
- **依赖清单排除/纳入（已实测）**：排除 `pandas-ta`（后端零引用，`0.3.14b1` 用了已删除的 `numpy.NaN`，新 numpy 上装/导入即失败）、`uvicorn`（仅注释）、`asyncpg`（无测试顶层或 importorskip 依赖它；`app.scheduler` 不顶层 import 它）。**纳入 `apscheduler==3.10.4`**：`test_scheduler.py` 有 4 处 `pytest.importorskip("apscheduler")`，缺它会静默 skip（166 passed + 4 skipped，非 170）——这正是本工作要消灭的覆盖缺口。
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
apscheduler==3.10.4
pandas==2.2.3
numpy==2.4.6
```

- [ ] **Step 3: 在全新 venv 里只装本清单，跑全套件**

Run:
```bash
SP=/private/tmp/claude-501/-Users-maziming-Coding-Prj-Kline-trainer/80380c0f-edac-4f2a-885d-6487d15b36a8/scratchpad
"$SP/rt-venv/bin/pip" install -r "/Users/maziming/Coding/Prj_Kline trainer/backend/requirements-test.txt" 2>&1 | tail -3
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && "$SP/rt-venv/bin/python" -m pytest tests/ -rs -q 2>&1 | tail -6
```
Expected: **`170 passed`，且 `0 skipped`**（`-rs` 会列出任何 skip）。若出现 `N skipped`，说明清单漏了某个 `importorskip` 依赖（如 apscheduler），按 skip 原因把缺的包按精确版本补进清单并重建 venv 重跑，直至 `170 passed, 0 skipped`；若 `ImportError` 同理补齐。

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
      - 'pytest.ini'
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
      # backend/tests/__init__.py 使 pytest 把 backend/ 注入 sys.path（与 CWD 无关）；
      # working-directory: backend + python -m pytest 为习惯与稳健标准形。
      # skip 守卫（codex branch review medium）：本仓有 importorskip("apscheduler")，
      # 依赖漂移时裸 pytest 会绿着 skip = 静默覆盖缺口，故 skipped>0 即 fail。
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

- [ ] **Step 2: 校验 YAML 语法正确、结构符合预期**

> `.github/workflows/**` 对 Claude/subagent 的 Write/Edit 被 deny 硬拦（trust-boundary）。落地走 ceremony：内容写 `/tmp`（scratchpad），user 在输入框 `!cp <scratchpad>/backend-tests.yml .github/workflows/backend-tests.yml`。

Run（用装了 pyyaml 的 rt-venv 跑断言，宿主 python3.11 无 yaml）：
```bash
SP=/private/tmp/claude-501/-Users-maziming-Coding-Prj-Kline-trainer/80380c0f-edac-4f2a-885d-6487d15b36a8/scratchpad
cd "/Users/maziming/Coding/Prj_Kline trainer" && "$SP/rt-venv/bin/python" -c "
import yaml
d=yaml.safe_load(open('.github/workflows/backend-tests.yml'))
s=d['jobs']['pytest']['steps']
assert s[2]['working-directory']=='backend'
assert s[3]['working-directory']=='backend'
assert 'python -m pytest' in s[3]['run']
assert 'skipped' in s[3]['run']  # skip 守卫在
assert d['permissions']['contents']=='read'
assert 'pytest.ini' in d[True]['pull_request']['paths']  # 'on'→True
print('YAML OK')"
```
Expected: `YAML OK`（任何 assert 失败即 workflow 写错，修正后重跑）。

- [ ] **Step 3: 本地模拟 CI 的确切命令 + skip 守卫双向 mutation**

全新 venv 逐字复刻 CI 两步（install + run+skip 守卫）：
```bash
SP=/private/tmp/claude-501/-Users-maziming-Coding-Prj-Kline-trainer/80380c0f-edac-4f2a-885d-6487d15b36a8/scratchpad
rm -rf "$SP/rt-venv2"; /opt/homebrew/bin/python3.11 -m venv "$SP/rt-venv2"
cd "/Users/maziming/Coding/Prj_Kline trainer/backend"
"$SP/rt-venv2/bin/python" -m pip install -r requirements-test.txt 2>&1 | tail -1
"$SP/rt-venv2/bin/python" -m pytest tests/ -rs -q 2>&1 | tail -3
```
Expected: `170 passed`，`0 skipped`。**skip 守卫 mutation**（可选，实施时已验证）：卸掉 apscheduler 的 venv 跑守卫应 `FAIL: 4 skipped` 退 1。

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
