# QMT NAS 部署 · PR-2「后端容器化」Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> ⚠️ **本 plan 的分支必须在 PR-1 合并进 main 之后**从新的 `origin/main` 切出。理由：PR-1 与本 PR 都改 `backend/.env.example`（前者加 `DATABASE_URL`，后者加 `TRAINING_SETS_HOST_DIR`），先合后切可以完全避开叠 PR 的两个已知坑（改 base 静默丢门 / 前片 squash 后必然冲突）。

**Goal:** 让后端能以容器方式跑起来（`docker compose up` 即可），镜像只装运行 API 真正需要的三个包，供应链按 digest 钉死，且**数据库地址缺失时立刻拒绝启动**而不是静默用假库。

**Architecture:** 三个文件，一条链：`requirements-api.txt` 定义裁剪后的依赖 → `Dockerfile` 用「精确 patch 版本 + 多架构 digest」的基础镜像装它 → `docker-compose.yml` 新增 `api` 服务，与既有 `db` 服务同项目（显式项目名 `kline-trainer`），`db` 带健康检查、`api` 等它健康后才起、训练组目录只读挂进 `/data/training-sets`。

**Tech Stack:** Docker Engine 28.5.2 / Compose v2.40.3（NAS 实测版本）· python:3.11.14-slim · postgres:15.12 · pytest + pyyaml（结构断言）

**Spec:** `docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md`（本 PR 实现 §5 的 C1-1..C1-5、C1-8、C1-9 与 T1 / T4 / T5 / T6 / T7 五族判据）

---

## Global Constraints

1. **禁述**：同 PR-1（spec §1 + §13.0 的禁述族），逐条照搬。
2. **CI 无 Docker，且任何 skip 判失败** → 需要 `docker` 可执行文件的判据**一律不做成 pytest**，归验收清单 / runbook。pytest 里只做**结构断言**（pyyaml 解析 + 文本解析）。
3. **`requirements-test.txt` 有 `pyyaml==6.0.3`**（实测）→ compose 结构测试可以用它。
4. **每条新测试必须变异验证**，控制者亲跑。变异配方同 PR-1（`PYTHONDONTWRITEBYTECODE=1` + 每次清 `__pycache__` + `cp` 复原，⛔ 不用 `git checkout <file>`）。
5. **不得用 Bash 读写含 `.env` 字样的路径**；改 `backend/.env.example` 走 Read / Edit / Write 工具。
6. **⛔ 不得出现 `tailscale` 与 `funnel` 连写的字样**（spec §4-D1 硬禁令），本 PR 的任何文件与文档都不例外。
7. **不改** `backend/sql/`、`backend/openapi.yaml`、`tests/contract-fixtures/`、`scripts/nas-preflight.sh`、`backend/requirements.txt`（后者只被读，不被改）。
8. **不部署 B4 调度器**（spec §5.3）：compose 里不新增 scheduler 服务。

### 本 plan 内嵌的数值全部经 2026-08-24 实测

⚠️ 下面这些值不是抄文档，是本机真跑出来的（`feedback_plan_embedded_facts_unreliable`：内嵌的**事实**必须逐条实测）。实施时**仍须**按 Task 里的步骤各自复验一次。

| 值 | 怎么测的 |
|---|---|
| `postgres:15.12` digest `sha256:8f6fbd24a12304d2adc332a2162ee9ff9d6044045a0b07f94d6e53e73125e11c`，OCI image index，含 `linux/amd64` + `linux/arm64/v8` | `docker buildx imagetools inspect postgres:15.12` |
| `python:3.11.14-slim` digest `sha256:c8271b1f627d0068857dce5b53e14a9558603b527e46f1f901722f935b786a39`，OCI image index，含 `linux/amd64` + `linux/arm64/v8` | 同上 |
| 三个 pin 与 `requirements.txt` 一致：`fastapi==0.115.12` / `uvicorn==0.34.2` / `asyncpg==0.30.0` | 读 `backend/requirements.txt` |
| 本 compose + Dockerfile **真跑通了**：`config` 退 0 且 stderr 为空、`build` 成功、`up -d` 后 `db` 变 `healthy` 且 `api` 随后启动、镜像名为 `kline-trainer-api`、卷名为 `kline-trainer_pgdata`、`/data/training-sets` 在容器内**只读**（`touch` 报 `Read-only file system`）、端口只绑 `127.0.0.1` | 2026-08-24 在 Mac 上整套跑过一遍，随后 `down -v` 清理干净 |
| `${DATABASE_URL:?…}` 对**未设**与**空串**都退出 1 且消息可读；合法值退出 0 | 三档各跑一次 `docker compose config` |
| 完整数据链路可用：`reserve(count=3)` 返回 3 条 → 三个 zip 下载后 CRC32 **逐个吻合** → `confirm` 全 200 → 库里 3 行变 `sent` → 再 `reserve` 返回 0 条 | 本机用真 zip 跑完整流程 |

---

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `backend/requirements-api.txt` | 新建 | API 容器专用依赖，恰好 `{fastapi, uvicorn, asyncpg}`，每个精确 pin 且与 `requirements.txt` 同名包一致。 |
| `backend/Dockerfile` | 新建 | API 镜像定义。基础镜像 = 精确 patch tag + 多架构 index digest；装 `requirements-api.txt`（**不是** `requirements.txt`，后者含已知安装陷阱 `pandas-ta`）。 |
| `backend/docker-compose.yml` | 修改 | 加顶层显式项目名 `kline-trainer`；`db` 加 healthcheck 与 image digest；新增 `api` 服务。 |
| `backend/.env.example` | 修改 | 新增 `TRAINING_SETS_HOST_DIR=`（宿主训练组目录，无默认值必须显式给）+ 两条可选变量的注释说明。 |
| `backend/tests/test_requirements_api.py` | 新建 | T1 族：依赖裁剪与 pin 一致性（双向）。 |
| `backend/tests/test_dockerfile.py` | 新建 | T5 族：基础镜像形态 + 装的是哪份依赖清单。 |
| `backend/tests/test_compose_deployment.py` | 新建 | T4 / T6 / T7-1s 族：compose 结构断言。 |

**⚠️ `.env.example` 新增的 `TRAINING_SETS_HOST_DIR` 不要加进 PR-1 那张分类表**（`backend/tests/test_env_example_coverage.py` 的 `ENV_FILE_KEYS`）。理由：那张表的判据①是「**扫描全集**与分类表精确相等」，而扫描器只扫 Python 与 shell 消费者、**不扫 compose**；把一个扫不到的名字加进 `ENV_FILE_KEYS` 会让判据① 立刻红在「归类了但没扫到」。判据② 是 `ENV_FILE_KEYS ⊆ 已定义`，所以 `.env.example` 里多出来的键**不会**让任何测试变红——已复核。

---

## Task 1: `requirements-api.txt` + 依赖一致性守卫（C1-1 / T1）

**Files:**
- Create: `backend/requirements-api.txt`
- Test: `backend/tests/test_requirements_api.py`

**Interfaces:**
- Consumes: 无
- Produces: `backend/requirements-api.txt` —— Task 2 的 Dockerfile 会 `pip install -r` 它。

- [ ] **Step 1: 先写失败测试**

新建 `backend/tests/test_requirements_api.py`：

```python
# backend/tests/test_requirements_api.py
"""C1-1 / T1：API 容器依赖清单必须裁剪且与主清单 pin 一致。

为什么要裁剪（spec §4-D2）：`requirements.txt` 含 `pandas-ta==0.3.14b1`，
那是数据导入脚本用的，且是已知的安装陷阱。API 运行只需 fastapi / uvicorn / asyncpg
（读 `backend/app/*.py` 的 import 得到）。

为什么要双向锁 pin：两份清单各自漂移会让「本地 pytest 用的版本」与
「容器里真跑的版本」悄悄分家 —— 那是最难查的一类线上问题。
"""
from __future__ import annotations

import re
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
MAIN_REQS = BACKEND_DIR / "requirements.txt"
API_REQS = BACKEND_DIR / "requirements-api.txt"

EXPECTED_API_PACKAGES = {"fastapi", "uvicorn", "asyncpg"}

# 只认精确 pin：`name==version`。任何 >= / <= / ~= / > / < 都不算。
_EXACT_PIN_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;]+)$")


def _parse(path: Path) -> dict[str, str]:
    """requirements 文件 → {包名小写: 版本}。跳过空行与整行注释。

    不容忍无法解析的行：解析不了就抛，避免「读进来是空的 → 断言恒真」。
    """
    pins: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = _EXACT_PIN_RE.match(line)
        if match is None:
            raise AssertionError(
                f"{path.name} 里这一行不是精确 pin（name==version）: {raw!r}"
            )
        pins[match.group(1).lower()] = match.group(2)
    return pins


def test_api_requirements_is_not_empty():
    """防空转：解析结果为空时下面所有断言都会恒真。"""
    assert _parse(API_REQS), "requirements-api.txt 解析结果为空 —— 判据已失效"


def test_api_requirements_package_set_is_exact():
    """T1-4：包集合恰好三项，多一个少一个都红。"""
    assert set(_parse(API_REQS)) == EXPECTED_API_PACKAGES


def test_api_requirements_pins_match_main_requirements():
    """T1-1 / T1-2 / T1-3：每个包在主清单里存在，且版本逐字相同（两个方向都会红）。"""
    api = _parse(API_REQS)
    main = _parse(MAIN_REQS)
    for name, version in sorted(api.items()):
        assert name in main, f"{name} 在 requirements.txt 里不存在"
        assert version == main[name], (
            f"{name} 版本不一致: requirements-api.txt={version} / requirements.txt={main[name]}"
        )


def test_api_requirements_has_no_version_ranges():
    """T1-5：全精确 pin。_parse 遇到 range 会抛 AssertionError，这里显式跑一次证明。"""
    _parse(API_REQS)  # 不抛即通过


def test_api_requirements_excludes_pandas_ta():
    """C1-1 的意图档：那个已知安装陷阱绝不能溜进 API 镜像。"""
    assert "pandas-ta" not in _parse(API_REQS)
```

- [ ] **Step 2: 跑测试确认红**

```bash
PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
WT="<本 PR 的 worktree 绝对路径>"
find "$WT/backend" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cd "$WT/backend" && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_requirements_api.py -q 2>&1 | tail -20
```

预期：5 条全红，原因都是 `FileNotFoundError`（`requirements-api.txt` 还不存在）。

- [ ] **Step 3: 建 `backend/requirements-api.txt`**

```
# API 容器专用依赖（spec §4-D2 / C1-1）。
# 恰好三项：读 backend/app/*.py 的 import 得到 —— API 运行只需要这些。
# ⚠️ 刻意**不含** pandas-ta（那是数据导入脚本用的，且是已知安装陷阱）。
# ⚠️ 每个 pin 必须与 backend/requirements.txt 中同名包逐字相同，
#    由 tests/test_requirements_api.py 双向锁定（改任一侧都会红）。
fastapi==0.115.12
uvicorn==0.34.2
asyncpg==0.30.0
```

- [ ] **Step 4: 跑测试确认 5 条全绿**（T1-1 正向档）

- [ ] **Step 5: 变异验证 T1-2 —— 改 `requirements-api.txt` 的 pin**

`fastapi==0.115.12` → `fastapi==0.115.11`。
预期红的**具名**测试：`test_api_requirements_pins_match_main_requirements`。

- [ ] **Step 6: 变异验证 T1-3 —— 改另一侧（`requirements.txt`）的 pin**

`fastapi==0.115.12` → `fastapi==0.115.11`（改主清单）。
预期红的**具名**测试：`test_api_requirements_pins_match_main_requirements`。

⚠️ 两个方向都要验。只验一侧的话，一个「只在 api 侧看」的实现会放过主清单的漂移。

- [ ] **Step 7: 变异验证 T1-4 —— 往 `requirements-api.txt` 加一行 `pandas-ta==0.3.14b1`**

预期红的**具名**测试：`test_api_requirements_package_set_is_exact` **和** `test_api_requirements_excludes_pandas_ta`。

- [ ] **Step 8: 变异验证 T1-5 —— 把某行改成 range**

`fastapi==0.115.12` → `fastapi>=0.115`。
预期红：`test_api_requirements_has_no_version_ranges` 等多条（`_parse` 抛 AssertionError）。**把实际红的具名清单抄进记录。**

- [ ] **Step 9: 变异验证防空转 —— 把 `requirements-api.txt` 清空**

预期红的**具名**测试：`test_api_requirements_is_not_empty`（**首先**）。这证明「解析成空集」不会让后面的集合断言恒真通过。

- [ ] **Step 10: Commit**

```bash
git add backend/requirements-api.txt backend/tests/test_requirements_api.py
git commit -m "feat(backend): API 容器依赖清单（裁剪 + 与主清单双向锁 pin）(C1-1/T1)

API 运行只需 fastapi / uvicorn / asyncpg；requirements.txt 里的 pandas-ta 是数据
导入脚本用的，且是已知安装陷阱，不该进 API 镜像。

守卫双向：改任一侧的 pin 都会红，避免「本地测试用的版本」与「容器里真跑的版本」
悄悄分家。解析器对非精确 pin 直接抛错，并配一条防空转档。"
```

---

## Task 2: `Dockerfile`（C1-2 / T5 / T6-5）

**Files:**
- Create: `backend/Dockerfile`
- Test: `backend/tests/test_dockerfile.py`

**Interfaces:**
- Consumes: `backend/requirements-api.txt`（Task 1）
- Produces: 一份可 `docker compose build` 的镜像定义；产出镜像由 compose 项目名派生为 `kline-trainer-api`（Task 3 依赖这一点）。

- [ ] **Step 1: 先写失败测试**

新建 `backend/tests/test_dockerfile.py`：

```python
# backend/tests/test_dockerfile.py
"""C1-2 / T5 / T6-5：API 镜像的基础镜像形态与依赖来源。

供应链固定（spec C1-8 ①②）按服务类型分两条：
  - 拉取型服务（compose 里有 image: 无 build:）→ image: 必须带 @sha256: digest；
  - 构建型服务（有 build:）→ 供应链固定由**本文件的 FROM** 承担。
所以这里的 FROM 必须同时具备「精确 patch tag」与「@sha256: digest」。

⚠️ 本文件只做**文本结构**断言。「digest 是不是多架构 index」需要网络 + Docker
（`docker buildx imagetools inspect`），CI 不保证有，且本仓 CI 把任何 skip 判失败
→ 那条归验收清单 / runbook（spec T6-7）。
"""
from __future__ import annotations

import re
from pathlib import Path

DOCKERFILE = Path(__file__).resolve().parents[1] / "Dockerfile"

# python:<major>.<minor>.<patch>-slim@sha256:<64 hex>
_FROM_RE = re.compile(
    r"^FROM\s+python:(\d+\.\d+\.\d+)-slim@sha256:([0-9a-f]{64})\s*$"
)


def _lines() -> list[str]:
    return DOCKERFILE.read_text(encoding="utf-8").splitlines()


def _from_lines() -> list[str]:
    return [ln for ln in _lines() if ln.strip().startswith("FROM ")]


def test_dockerfile_has_exactly_one_from():
    """防空转 + 防多阶段意外：本镜像是单阶段的。"""
    assert len(_from_lines()) == 1, f"期望恰好 1 条 FROM，实际 {len(_from_lines())} 条"


def test_base_image_is_exact_patch_tag_with_digest():
    """T5-1 / T6-5：精确 patch tag **且**带 digest。

    `python:3.11-slim`（浮动 minor）、`python:3.11.14-slim`（无 digest）、
    `python:latest` 三种写法都会在这里红。
    """
    line = _from_lines()[0].strip()
    assert _FROM_RE.match(line), (
        f"FROM 行不符合「python:<x.y.z>-slim@sha256:<64位>」形态: {line!r}"
    )


def test_no_latest_anywhere():
    """T6-4 的 Dockerfile 侧：不得出现 :latest。"""
    for line in _lines():
        assert ":latest" not in line, f"Dockerfile 出现 :latest: {line!r}"


def test_installs_api_requirements_not_main_requirements():
    """T5-2：装的是裁剪后的清单。

    注意 `requirements.txt` **不是** `requirements-api.txt` 的子串，
    所以下面这条否定断言不会误伤。
    """
    text = DOCKERFILE.read_text(encoding="utf-8")
    assert "requirements-api.txt" in text, "Dockerfile 没有引用 requirements-api.txt"
    assert "requirements.txt" not in text, (
        "Dockerfile 引用了 requirements.txt —— 那份含 pandas-ta 安装陷阱"
    )
```

- [ ] **Step 2: 跑测试确认红**（4 条全红，`FileNotFoundError`）

- [ ] **Step 3: 建 `backend/Dockerfile`**

```dockerfile
# backend/Dockerfile —— API 镜像（spec §4-D2 / C1-2 / C1-8②）
#
# 基础镜像必须是「精确 patch tag + @sha256: digest」：
#   - 精确 patch tag 让人看得出装的是哪个 Python；
#   - digest 才是真正钉死供应链的那一半（tag 可以被重新指向）。
# digest 取的是**多架构 manifest list（OCI image index）**的顶层 digest，
# 不是单平台 manifest 的 —— 否则镜像会被钉死在一个架构上（Mac arm64 / NAS amd64）。
# 2026-08-24 实测：该 index 同时覆盖 linux/amd64 与 linux/arm64/v8。
FROM python:3.11.14-slim@sha256:c8271b1f627d0068857dce5b53e14a9558603b527e46f1f901722f935b786a39

# 刻意不叫 /app —— 应用包本身就叫 app，两者同名会让 COPY 目标很难读。
WORKDIR /srv

# 依赖层单独 COPY，改应用代码时不用重装依赖。
COPY requirements-api.txt ./
RUN pip install --no-cache-dir -r requirements-api.txt

COPY app ./app

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

⚠️ `--host 0.0.0.0` 是**容器内**监听地址，不是宿主暴露面。宿主侧的暴露由 compose 的 `${API_BIND_HOST:-127.0.0.1}:8010:8000` 控制（C1-4），默认只绑回环。

- [ ] **Step 4: 跑测试确认 4 条全绿**

- [ ] **Step 5: 变异验证 T5-1a —— 去掉 digest**

`FROM python:3.11.14-slim@sha256:c827...` → `FROM python:3.11.14-slim`。
预期红的**具名**测试：`test_base_image_is_exact_patch_tag_with_digest`。

- [ ] **Step 6: 变异验证 T5-1b —— 换成浮动 minor tag**

→ `FROM python:3.11-slim@sha256:c827...`（保留 digest，只把 tag 变浮动）。
预期红的**具名**测试：`test_base_image_is_exact_patch_tag_with_digest`。

⚠️ 这一档单独存在的理由：只验「有没有 digest」的守卫会放过浮动 tag，而浮动 tag 会让人读不出装的是哪个 Python。

- [ ] **Step 7: 变异验证 T5-2 —— 改成装主清单**

`requirements-api.txt` → `requirements.txt`（三处都改：COPY 与 RUN）。
预期红的**具名**测试：`test_installs_api_requirements_not_main_requirements`。

- [ ] **Step 8: 变异验证 T6-4 —— 塞一个 `:latest`**

预期红的**具名**测试：`test_no_latest_anywhere`。

- [ ] **Step 9: Commit**

```bash
git add backend/Dockerfile backend/tests/test_dockerfile.py
git commit -m "feat(backend): API 镜像定义（精确 patch tag + 多架构 index digest）(C1-2/T5)

装的是裁剪后的 requirements-api.txt，不是含 pandas-ta 的主清单。
FROM 同时钉住精确 patch tag 与 @sha256: digest —— 前者让人读得出装的是哪个 Python，
后者才真正钉死供应链。digest 取多架构 index 的顶层值，避免把镜像钉在单一架构上
（Mac arm64 / NAS amd64 两边都要能构建）。

结构断言配了两档变异：去掉 digest、把 tag 换成浮动 minor —— 各自单独会红。
「digest 是不是多架构 index」需要网络 + Docker，归验收清单，不做成 pytest。"
```

---

## Task 3: `docker-compose.yml` 新增 `api` 服务（C1-3 / C1-3b / C1-4 / C1-5 / C1-8 / C1-9）

**Files:**
- Modify: `backend/docker-compose.yml`
- Modify: `backend/.env.example`（只加 `TRAINING_SETS_HOST_DIR` 与两条注释；⚠️ 用 Edit 工具）
- Test: `backend/tests/test_compose_deployment.py`

**Interfaces:**
- Consumes: `backend/Dockerfile`（Task 2）、`backend/requirements-api.txt`（Task 1）
- Produces: 一个可 `docker compose up -d` 的完整栈。镜像名 `kline-trainer-api`、卷名 `kline-trainer_pgdata`（均由项目名 `kline-trainer` 派生，2026-08-24 实测）。runbook 的 P6/P8 依赖这两个名字。

- [ ] **Step 1: 先写失败测试**

新建 `backend/tests/test_compose_deployment.py`：

```python
# backend/tests/test_compose_deployment.py
"""C1-3 / C1-3b / C1-4 / C1-5 / C1-8 / C1-9：部署编排的结构判据。

⚠️ 本文件只做结构断言。三类东西**结构断言抓不到**，归验收清单 / runbook：
  - `build:` 与带 digest 的 `image:` 同时存在这类坏配置 —— 实测
    `docker compose config` 对它**返回 0**，要到 `docker compose build` 才报
    `failed to solve: build tag cannot contain a digest`（spec T6-6）；
  - 「digest 是不是多架构 index」—— 单平台 digest 完全满足结构判据，
    却会在另一个架构上失败（spec T6-7）；
  - `${VAR:?}` 的**运行时行为** —— 需要 docker 可执行文件（spec T7-0）。
"""
from __future__ import annotations

from pathlib import Path

import yaml

COMPOSE_PATH = Path(__file__).resolve().parents[1] / "docker-compose.yml"

TRAINING_SETS_CONTAINER_PATH = "/data/training-sets"


def _compose() -> dict:
    return yaml.safe_load(COMPOSE_PATH.read_text(encoding="utf-8"))


def _services() -> dict:
    return _compose()["services"]


def _pull_type_services() -> dict:
    """拉取型 = 有 image、无 build。"""
    return {n: s for n, s in _services().items() if "image" in s and "build" not in s}


def _build_type_services() -> dict:
    """构建型 = 有 build。"""
    return {n: s for n, s in _services().items() if "build" in s}


# ── 防空转：两类服务都必须真的存在，否则下面的循环恒真 ──────────────────
def test_both_service_classes_are_non_empty():
    assert _pull_type_services(), "没有拉取型服务 —— digest 判据会恒真通过"
    assert _build_type_services(), "没有构建型服务 —— 反向 digest 判据会恒真通过"


def test_project_name_is_explicit():
    """T4-1：显式项目名。

    两个理由（spec §4-D2 + §2.5-c）：
      ① NAS 上已有一个 2026-04 的 `backend-api:latest` 遗留镜像，默认项目名会撞车；
      ② NAS 上**已经存在**卷 `backend_pgdata` —— 默认项目名会静默复用那个旧卷，
         而 schema.sql 全是 CREATE TABLE IF NOT EXISTS，会什么都不修却报成功。
    """
    assert _compose().get("name") == "kline-trainer"


def test_api_service_exists():
    assert "api" in _services()


def test_db_has_healthcheck():
    """T4-1c：没有健康检查，下面的 service_healthy 就无从谈起。"""
    assert "healthcheck" in _services()["db"]


def test_api_depends_on_db_being_healthy():
    """T4-1b：必须是 condition 形式，不是裸列表。

    裸 `depends_on: [db]` 只保证「db 容器启动了」，不保证「PG 能接受连接」。
    NAS 断电重启时 api 会先起来 → create_pool 抛错 → FastAPI startup 失败。
    """
    depends = _services()["api"]["depends_on"]
    assert isinstance(depends, dict), f"depends_on 必须是映射形式，实际: {depends!r}"
    assert depends["db"]["condition"] == "service_healthy"


def test_api_has_restart_policy():
    """T4-1d。"""
    assert "restart" in _services()["api"]


def test_api_host_port_defaults_to_loopback():
    """T4-2 / C1-4：默认只绑回环，不得默认对局域网开放。"""
    ports = _services()["api"]["ports"]
    assert any(str(p).startswith("${API_BIND_HOST:-127.0.0.1}:") for p in ports), (
        f"api 的宿主端口绑定默认值不是 127.0.0.1: {ports!r}"
    )


def test_training_sets_mount_is_readonly_at_fixed_container_path():
    """T4-3 / C1-5：只读，且容器内路径固定。

    容器内路径固定很重要：`training_sets.file_path` 存的就是这个路径，
    宿主目录怎么变都不用改数据库。
    """
    volumes = [str(v) for v in _services()["api"]["volumes"]]
    matching = [v for v in volumes if f":{TRAINING_SETS_CONTAINER_PATH}:" in v]
    assert matching, f"api 没有挂到 {TRAINING_SETS_CONTAINER_PATH}: {volumes!r}"
    for entry in matching:
        assert entry.endswith(":ro"), f"训练组挂载不是只读: {entry!r}"


def test_pull_type_images_are_digest_pinned():
    """T6-1 / T6-2 / C1-8①：拉取型服务的 image 必须带 digest。"""
    for name, svc in _pull_type_services().items():
        assert "@sha256:" in str(svc["image"]), (
            f"拉取型服务 {name} 的 image 没有 @sha256: digest: {svc['image']!r}"
        )


def test_build_type_services_have_no_digest_in_image():
    """T6-3 / C1-8②：构建型服务**不得**在 image 里带 digest。

    ⚠️ 这条是反向档，不能只测「有 digest」。spec 的 R3-F1 就是这个坑：
    `build:` + `image: x@sha256:…` 会让 `docker compose build` 直接报
    `failed to solve: build tag cannot contain a digest`，而
    `docker compose config` 对这份坏配置**返回 0**。
    """
    for name, svc in _build_type_services().items():
        image = str(svc.get("image", ""))
        assert "@sha256:" not in image, (
            f"构建型服务 {name} 的 image 带了 digest —— docker compose build 会直接失败"
        )


def test_no_latest_tag_anywhere():
    """T6-4。"""
    for name, svc in _services().items():
        image = str(svc.get("image", ""))
        assert ":latest" not in image, f"服务 {name} 用了 :latest: {image!r}"


def test_database_url_uses_required_variable_syntax():
    """T7-1s / C1-9：必须是 `${DATABASE_URL:?…}`，不是 `${DATABASE_URL}` 也不是 `:-`。

    为什么（spec §4-D5 补强）：`.env` 丢失或在错误目录 `up` 时，插值会得到**空串**，
    而 `os.environ.get("DATABASE_URL")` 对空串返回假值 → 后端静默回落 InMemory，
    服务照样 200 地跑着，只是一行数据都没有。空串比未设更阴险，`:-` 只挡未设。
    """
    value = str(_services()["api"]["environment"]["DATABASE_URL"])
    assert value.startswith("${DATABASE_URL:?"), (
        f"DATABASE_URL 没有用必需变量语法: {value!r}"
    )
    assert value.endswith("}")
    assert "${DATABASE_URL:-" not in value, "用了默认值语法 —— 挡不住空串"


def test_training_sets_host_dir_uses_required_variable_syntax():
    """宿主训练组目录同样没有合理默认值：配错会导致 download 一律 404，症状很难认。"""
    volumes = [str(v) for v in _services()["api"]["volumes"]]
    matching = [v for v in volumes if f":{TRAINING_SETS_CONTAINER_PATH}:" in v]
    assert matching, "找不到训练组挂载项"
    assert all(v.startswith("${TRAINING_SETS_HOST_DIR:?") for v in matching), (
        f"训练组宿主目录没有用必需变量语法: {matching!r}"
    )
```

- [ ] **Step 2: 跑测试确认红**

预期：多条红（`name` 键不存在、`api` 服务不存在、`db` 无 healthcheck、image 无 digest 等）。`test_both_service_classes_are_non_empty` 会因为**没有构建型服务**而红 —— 这正是它该有的行为。

- [ ] **Step 3: 改 `backend/docker-compose.yml`**

整个文件替换为：

```yaml
# backend/docker-compose.yml —— kline-trainer 部署编排（spec §4-D2）
#
# ⚠️ 顶层 name 是硬要求，不是装饰（C1-3 + spec §2.5-c）：
#    compose 默认拿**目录名**当项目名。本文件在 backend/ 目录下，默认项目名就是
#    `backend` —— 而 NAS 上**已经存在**卷 `backend_pgdata` 和镜像 `backend-api:latest`
#    （2026-04 的遗留）。漏了这一行会静默挂上那个旧卷，而 sql/schema.sql 建表全是
#    CREATE TABLE IF NOT EXISTS → 什么都不修却报成功，后面所有验收都跑在一个
#    没被校验过的 schema 上。
#
# ⚠️ 不写 `version:` 键：compose v2 已忽略它并对其报警告，而部署时需要干净的输出
#    才能判断有没有真警告。
name: kline-trainer

services:
  db:
    # 拉取型服务（有 image 无 build）→ 供应链固定靠这里的 digest（C1-8①）。
    # digest 取多架构 index 顶层值（含 linux/amd64 + linux/arm64/v8，2026-08-24 实测），
    # 不是单平台 manifest 的 —— 否则镜像会被钉死在一个架构上。
    image: postgres:15.12@sha256:8f6fbd24a12304d2adc332a2162ee9ff9d6044045a0b07f94d6e53e73125e11c
    restart: unless-stopped
    env_file:
      - .env
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    ports:
      # 默认只绑 localhost（127.0.0.1）— 避免 changeme 默认密码暴露到 LAN
      # NAS 部署若需要跨机访问，需在 .env 里显式设 DB_BIND_HOST=0.0.0.0 并同步改掉默认密码
      # 本地开发如无冲突可把 5433 改回 5432
      - "${DB_BIND_HOST:-127.0.0.1}:5433:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    # $$ 转义：让 pg_isready 读**容器自己**的环境变量，而不是被 compose 先插值掉。
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10

  api:
    # 构建型服务（有 build）→ 供应链固定由 Dockerfile 的 FROM …@sha256: 承担（C1-8②）。
    # ⚠️ 刻意**不写** image: 键。写了并带 digest 会让 `docker compose build` 直接报
    #    `failed to solve: build tag cannot contain a digest`，而 `compose config`
    #    对这份坏配置返回 0（实测）—— 所以这条只能靠「不写」和反向测试守住。
    #    镜像名由项目名派生为 kline-trainer-api（2026-08-24 实测）。
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    # 刻意**不用** env_file：api 只需要 DATABASE_URL 一个变量，
    # 把整份 .env（含 POSTGRES_PASSWORD）注进 api 容器是不必要的扩散。
    # ${...} 的插值本来就自动读项目目录下的 .env，与 env_file 无关。
    environment:
      # 必需变量语法（C1-9）：未设**或空串**都会让 `docker compose up` 当场失败。
      # 不这么写的话，插值得到空串 → app/main.py 静默回落 InMemory 假件 →
      # 服务照样 200 地跑着，手机却一个训练组都拉不到。
      DATABASE_URL: ${DATABASE_URL:?DATABASE_URL 未设或为空 —— 后端会静默回落 InMemory 假件，拒绝启动}
    depends_on:
      # condition 形式（C1-3b）：等 PG 真的能接受连接，不只是「容器起来了」。
      # NAS 断电重启时 api 先起 → create_pool 抛错 → FastAPI startup 失败 → 容器退出。
      db:
        condition: service_healthy
    ports:
      # 默认只绑回环（C1-4）。对外暴露由 NAS 上的 tailscale serve 承担，不在这里开。
      - "${API_BIND_HOST:-127.0.0.1}:8010:8000"
    volumes:
      # 只读挂载（C1-5）。容器内路径固定为 /data/training-sets —— training_sets.file_path
      # 存的就是这个路径，宿主目录怎么变都不用改数据库（D3）。
      - ${TRAINING_SETS_HOST_DIR:?TRAINING_SETS_HOST_DIR 未设 —— 训练组 zip 宿主目录必须显式指定}:/data/training-sets:ro

volumes:
  pgdata:
```

- [ ] **Step 4: 改 `backend/.env.example`（用 Edit 工具）**

在文件末尾追加：

```
# 训练组 zip 所在的**宿主**目录（绝对路径）。容器内固定挂到 /data/training-sets（只读）。
# 无默认值：配错会让下载一律 404，症状很难认，所以要求显式指定。
TRAINING_SETS_HOST_DIR=/vol1/1000/agate1234/kline-trainer/training-sets
# 可选：宿主端口绑定地址，都默认 127.0.0.1（只绑回环）。
# 对外暴露由 NAS 上的 tailscale serve 承担，不要在这里改成 0.0.0.0。
# API_BIND_HOST=127.0.0.1
# DB_BIND_HOST=127.0.0.1
```

⚠️ **不要**把 `TRAINING_SETS_HOST_DIR` 加进 `tests/test_env_example_coverage.py` 的 `ENV_FILE_KEYS`（理由见本 plan 的 File Structure 一节）。

- [ ] **Step 5: 跑 compose 测试确认全绿**

- [ ] **Step 6: 跑全量后端套件，确认零回归 + 零 skip**

⚠️ 特别核 `tests/test_env_example_coverage.py` 三条仍绿（证明 Step 4 的新增键没有打断 PR-1 的守卫）。

- [ ] **Step 7: 变异验证（逐条，每条都要记下红的具名测试）**

| 编号 | 变异 | 应变红的具名测试 |
|---|---|---|
| T4-1 | 删掉顶层 `name: kline-trainer` | `test_project_name_is_explicit` |
| T4-1b | `depends_on` 改成裸列表 `[db]` | `test_api_depends_on_db_being_healthy` |
| T4-1c | 删掉 `db` 的 `healthcheck` 整块 | `test_db_has_healthcheck` |
| T4-1d | 删掉 `api` 的 `restart` | `test_api_has_restart_policy` |
| T4-2 | `${API_BIND_HOST:-127.0.0.1}` → `0.0.0.0` | `test_api_host_port_defaults_to_loopback` |
| T4-3 | 训练组挂载去掉结尾 `:ro` | `test_training_sets_mount_is_readonly_at_fixed_container_path` |
| T6-2 | `db` 的 image 去掉 `@sha256:…` | `test_pull_type_images_are_digest_pinned` |
| T6-3 | 给 `api` 加 `image: kline-trainer-api@sha256:<64位>` | `test_build_type_services_have_no_digest_in_image` |
| T6-4 | 把 `db` 的 image 换成 `postgres:latest` | `test_no_latest_tag_anywhere`（`test_pull_type_images_are_digest_pinned` 也会红） |
| T7-1s-a | `${DATABASE_URL:?…}` → `${DATABASE_URL}` | `test_database_url_uses_required_variable_syntax` |
| T7-1s-b | `${DATABASE_URL:?…}` → `${DATABASE_URL:-…}` | `test_database_url_uses_required_variable_syntax` |
| 防空转 | 删掉 `api` 整个服务 | `test_both_service_classes_are_non_empty` + `test_api_service_exists` |

- [ ] **Step 8: Commit**

```bash
git add backend/docker-compose.yml backend/.env.example backend/tests/test_compose_deployment.py
git commit -m "feat(backend): compose 新增 api 服务 + 显式项目名 + 必需变量语法 (C1-3..C1-9)

顶层 name: kline-trainer 是硬要求不是装饰：compose 默认拿目录名当项目名，本文件在
backend/ 下 → 默认项目名就是 backend，而 NAS 上已经存在卷 backend_pgdata 和镜像
backend-api:latest（四月遗留）。漏了这一行会静默挂上旧卷，而 schema.sql 建表全是
IF NOT EXISTS → 什么都不修却报成功。

DATABASE_URL 用必需变量语法 \${VAR:?…}：未设**或空串**都当场失败。不这么写的话
插值得到空串 → app/main.py 静默回落 InMemory 假件，服务照样 200 地跑着。

api 是构建型服务，刻意不写 image: 键 —— 写了并带 digest 会让 docker compose build
直接失败，而 compose config 对这份坏配置返回 0，只能靠反向测试守住。

db 加 healthcheck + api 用 condition: service_healthy：NAS 断电重启时 api 先起会
create_pool 抛错、FastAPI startup 失败。

去掉 version: 键（compose v2 已忽略并报警告，部署时需要干净输出才能判断真警告）。"
```

---

## Task 4: 按实际实现复核部署 runbook

**Files:**
- Modify（如有出入才改）: `docs/runbooks/2026-08-24-qmt-nas-deployment.md` 及其三个配套 `.sql`

⚠️ runbook 与三段 SQL **已随 PR-1 落在 main 上**（本次 writing-plans 一并交付，且三段 SQL 已在本机真 PostgreSQL 上验过判别力）。本 Task **不是**重写它，而是拿**实际实现出来的**编排/镜像去核它内嵌的每一条陈述。

- [ ] **Step 1: 逐条核对 runbook 里写死的名字与实现是否一致**

| runbook 里的陈述 | 核对方法 |
|---|---|
| 容器名 `kline-trainer-db-1` / `kline-trainer-api-1` | 本机 `docker compose up -d` 后 `docker compose ps` 读实际名字 |
| 卷名 `kline-trainer_pgdata` | `docker inspect kline-trainer-db-1 --format '{{range .Mounts}}{{.Name}}{{end}}'` |
| `/health` 输出**恰好**是 `{"status":"ok","repository":"asyncpg"}` | 本机连真 PG 起栈后 `curl` 一次，逐字比对（含有无空格） |
| P5 那条写配置的命令生成的 5 个变量名，恰好是编排真正需要的 | `docker compose config` 在只有这 5 个变量时能退出 0 |
| P8 的只读判据（`touch` 报 `Read-only file system`） | 本机 `docker exec ... touch /data/training-sets/x` |

- [ ] **Step 2: 有出入就改 runbook（以实现为准），无出入则不改**

⚠️ 改 runbook 时同步检查禁述族（不得出现 `tailscale` 与 `funnel` 连写、不得出现「PR11-R1 已关闭」等）。

- [ ] **Step 3: Commit（仅在真有改动时）**

```bash
git add docs/runbooks/
git commit -m "docs(qmt-nas): runbook 按实际实现复核（<写明改了哪几条>）"
```

---

## Task 5: 非程序员验收清单

**Files:**
- Create: `docs/superpowers/plans/2026-08-24-qmt-nas-pr2-acceptance.md`

- [ ] **Step 1: 写清单**（三列：动作 / 预期 / 通过条件；中文；一行一条命令）

清单必须含下列**需要真跑 Docker** 的条目（它们是 spec T6-6 / T6-7 / T7-2r / T7-3r 的归宿，pytest 覆盖不到）：

| 编号 | 动作 | 预期 | 通过条件 |
|---|---|---|---|
| A1 | 粘贴 `docker buildx imagetools inspect postgres:15.12` | 打印一段清单信息 | 输出里 `MediaType` 含 `image.index`，且 `Platform` 列表里**同时**看得到 `linux/amd64` 与 `linux/arm64/v8`；`Digest` 与 compose 里那串**逐字相同** |
| A2 | 粘贴 `docker buildx imagetools inspect python:3.11.14-slim` | 同上 | 同上，`Digest` 与 Dockerfile 的 `FROM` 那串逐字相同 |
| A3 | 在 `backend/` 下粘贴 `docker compose build` | 构建过程刷屏，最后一行是完成信息 | 出现 `Built`，且**没有** `failed to solve` 字样 |
| A4 | 粘贴 `docker compose config` | 打印展开后的编排 | 命令**没有**报错；输出第一行是 `name: kline-trainer` |
| A5 | 临时把 `.env` 里 `DATABASE_URL` 那一行整行删掉，再粘贴 `docker compose config` | 应当**报错** | 屏幕出现 `required variable DATABASE_URL is missing a value`；**恢复那一行**后重跑应恢复正常 |
| A6 | 把 `DATABASE_URL=` 后面清空（留等号），再粘贴 `docker compose config` | 应当**报错** | 同 A5 的报错；**恢复原值**后重跑恢复正常 |

⚠️ A5/A6 之后**务必**把 `.env` 改回去，否则后面的部署会起不来。

- [ ] **Step 2: Commit**

---

## 收尾：绿门（控制者亲跑）

- [ ] 门 1 · 全量后端套件全绿、零 skip（命令同 PR-1，先打印 branch/HEAD）
- [ ] 门 2 · 模拟 CI（`PYTHONPATH` 塞入抛 ImportError 的假 `asyncpg`）再跑一次全量，仍全绿
- [ ] 门 3 · 真跑一次 `docker compose build` 并读结论行（**必做**，spec T6-6：结构断言抓不到 `build tag cannot contain a digest` 这类错，而 `compose config` 对它返回 0）
- [ ] 门 4 · 两个 digest 各跑一次 `docker buildx imagetools inspect`，逐条核 index + 双架构（spec T6-7）
- [ ] 门 5 · 变异账目齐全（Task 1/2/3 三张表逐行有实测记录）
- [ ] 门 6 · `git status --porcelain` 零输出
- [ ] 门 7 · `git diff --stat origin/main...HEAD` 的文件清单与 File Structure 一致

⛔ 判绿一律读**输出内容**，别读退出码经管道后的值。本会话实测：harness 的 shell 是 **zsh**，`${PIPESTATUS[0]}` 取不到值（zsh 里是小写 `pipestatus` 且下标从 1 起）。要退出码请用 `set -o pipefail` 或不接管道。

## 收尾：对抗性评审

命令与纪律同 PR-1（`--scope branch-diff --head <本分支> --base origin/main`，零 focus 窄化，绝不传未知参数，被杀不计轮次）。

---

## Self-Review

**1. spec 覆盖**：C1-1→Task1；C1-2→Task2；C1-3/C1-3b/C1-4/C1-5/C1-8/C1-9→Task3；T1 族→Task1 Step 4-9；T5/T6-5→Task2 Step 4-8；T4/T6-1..4/T7-1s→Task3 Step 5-7；T6-6/T6-7/T7-2r/T7-3r→Task5 的 A1-A6 + 收尾门 3/4；§7 runbook→Task4；§9.3 清单形态→Task5。
**未覆盖且属他 PR**：C1-6/C1-7/T2/T3（PR-1 已交付）；§6 全部（PR-3）。
**2. 占位符扫描**：无 TBD / TODO。runbook 内容在单独文件里逐条给全，不是「见后文」的空指针。
**3. 类型一致性**：`TRAINING_SETS_CONTAINER_PATH` 在测试里定义并被两条测试引用；`${TRAINING_SETS_HOST_DIR:?…}` 在 compose、`.env.example`、两条测试里同名；镜像名 `kline-trainer-api` / 卷名 `kline-trainer_pgdata` 在注释与 runbook 中同名（且均为实测值）。
