# Plan 0a：工具链、工程、流程治理

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让仓库具备"可以往里提 PR、跑 codex review、走三 hat 签字"的完整开发基础设施。

**Architecture:** 仓库根目录建出 iOS / Backend / fixtures / scripts / docs / tools 六大区域；GitHub 分支保护 enforce_admins=true；PR 模板 + adversarial-review 模板 + 三 hat 签字规则；Xcode 空工程能编译；FastAPI 骨架能跑 health；NAS PostgreSQL 能连上。同时锁定 GRDB 等三方依赖版本（spec §十五.2）。

**Tech Stack:** GitHub CLI (`gh`)、Xcode 16+ (iOS 17 target)、Python 3.11+、FastAPI、PostgreSQL 15+、Docker

---

## File Structure

```
.github/
  PULL_REQUEST_TEMPLATE.md
  CODEOWNERS
docs/
  governance/
    signing-rules.md
    adversarial-review-template.md
scripts/
  acceptance/
    plan_0a_toolchain.sh
  nas-preflight.sh
backend/
  app/
    __init__.py
    main.py
  tests/
    __init__.py
    test_health.py
  requirements.txt
  docker-compose.yml
  .env.example
ios/
  KlineTrainer/
    KlineTrainer.xcodeproj/   (Xcode 生成)
    KlineTrainer/
      KlineTrainerApp.swift   (Xcode 生成)
fixtures/
  golden/
    m0/
      source/
        .gitkeep
      expected/
        .gitkeep
      manifest/
        .gitkeep
  contracts/
    m0/
      .gitkeep
tools/
  fixtures/
    .gitkeep
```

---

## Task 1: 仓库目录结构

**Files:**
- Create: `backend/app/__init__.py`
- Create: `backend/requirements.txt`
- Create: `backend/.env.example`
- Create: `backend/docker-compose.yml`
- Create: `ios/.gitkeep`
- Create: `fixtures/golden/m0/source/.gitkeep`
- Create: `fixtures/golden/m0/expected/.gitkeep`
- Create: `fixtures/golden/m0/manifest/.gitkeep`
- Create: `fixtures/contracts/m0/.gitkeep`
- Create: `tools/fixtures/.gitkeep`
- Create: `scripts/acceptance/.gitkeep`

- [ ] **Step 1: 创建 backend 骨架目录**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
mkdir -p backend/app
touch backend/app/__init__.py
```

- [ ] **Step 2: 写 requirements.txt（版本锁定，来自 spec §十五.2）**

```txt
fastapi==0.115.12
uvicorn==0.34.2
apscheduler==3.10.4
pandas==2.2.3
pandas-ta==0.3.14b1
asyncpg==0.30.0
```

- [ ] **Step 3: 写 .env.example（docker-compose 和 DB_URL 都从这里读）**

```env
# NAS 端 PostgreSQL 配置
NAS_HOST=192.168.1.xxx
POSTGRES_USER=kline
POSTGRES_PASSWORD=changeme
POSTGRES_DB=kline_trainer
DB_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${NAS_HOST}:5432/${POSTGRES_DB}
# FastAPI
API_HOST=0.0.0.0
API_PORT=8000
```

- [ ] **Step 4: 写 docker-compose.yml（PostgreSQL 15，密码从 .env 读，禁止 :latest）**

```yaml
version: "3.9"
services:
  db:
    image: postgres:15.12
    restart: unless-stopped
    env_file:
      - .env
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

- [ ] **Step 5: 创建 iOS / fixtures / tools / scripts 占位目录**

```bash
mkdir -p ios
mkdir -p fixtures/golden/m0/{source,expected,manifest}
mkdir -p fixtures/contracts/m0
mkdir -p tools/fixtures
mkdir -p scripts/acceptance
find fixtures tools scripts/acceptance ios -type d -empty -exec touch {}/.gitkeep \;
```

- [ ] **Step 6: 验证目录结构**

Run: `find . -not -path './.git/*' -not -path './.claude/*' -type f | sort`

Expected: 能看到 `backend/app/__init__.py`、`backend/requirements.txt`、`backend/.env.example`、`backend/docker-compose.yml` 和各 `.gitkeep` 文件。

- [ ] **Step 7: Commit**

```bash
git add backend/ ios/ fixtures/ tools/ scripts/
git commit -m "$(cat <<'EOF'
chore: scaffold repo directories for Plan 0a

backend/, ios/, fixtures/, tools/, scripts/ with version-locked
requirements.txt and docker-compose.yml (postgres:15.12).
docker-compose reads credentials from .env (no hardcoded passwords).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: GitHub 分支保护 + CODEOWNERS

**Files:**
- Create: `.github/CODEOWNERS`

- [ ] **Step 1: 创建 .github 目录 + CODEOWNERS**

```bash
mkdir -p .github
cat > .github/CODEOWNERS <<'EOF'
# 单人项目：所有文件都由仓库 owner review
* @agateuu1234-bit
EOF
```

- [ ] **Step 2: 验证当前分支保护状态**

Run: `gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection 2>&1 || echo "No protection yet"`

Expected: 可能返回 404（尚未设置）或已有的保护规则。

- [ ] **Step 3: 设置分支保护（enforce_admins=true）**

```bash
gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection \
  --method PUT \
  --input - <<'EOF'
{
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false
  },
  "enforce_admins": true,
  "required_status_checks": null,
  "restrictions": null
}
EOF
```

- [ ] **Step 4: 验证 enforce_admins 已开启**

Run: `gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection | python3 -c "import sys,json; d=json.load(sys.stdin); print('enforce_admins:', d.get('enforce_admins',{}).get('enabled','MISSING'))"`

Expected: `enforce_admins: True`

- [ ] **Step 5: Commit CODEOWNERS**

```bash
git add .github/CODEOWNERS
git commit -m "$(cat <<'EOF'
chore: add CODEOWNERS and enable branch protection

enforce_admins=true so admin cannot bypass PR requirement.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: PR 模板 + Adversarial-Review 模板 + 三 Hat 签字规则

**Files:**
- Create: `.github/PULL_REQUEST_TEMPLATE.md`
- Create: `docs/governance/signing-rules.md`
- Create: `docs/governance/adversarial-review-template.md`

- [ ] **Step 1: 创建 docs/governance 目录**

```bash
mkdir -p docs/governance
```

- [ ] **Step 2: 写 PR 模板**

写入 `.github/PULL_REQUEST_TEMPLATE.md`：

````markdown
## 变更摘要

<!-- 一句话说明这个 PR 做了什么 -->

## 变更类型

- [ ] 新功能
- [ ] Bug 修复
- [ ] 文档
- [ ] 基础设施 / 配置
- [ ] 重构

## 涉及的 Hat（至少勾选一个）

- [ ] Backend hat（后端 / PostgreSQL / API / migration）
- [ ] iOS hat（Swift / Xcode / 图表 / UI）
- [ ] Data hat（fixture / schema / 训练组 / CSV）

## 验收结果

<!-- 粘贴 scripts/acceptance/plan_XX_*.sh 的输出，或手工验收截图 -->

```
粘贴验收脚本输出...
```

## Signoff

<!-- PR 合并前，按涉及的 hat 逐条签字。格式固定，不要修改模板。 -->

- [ ] SIGNOFF (Backend hat): I reviewed B/M0.1/M0.2 changes and the backend acceptance script passed.
- [ ] SIGNOFF (iOS hat): I reviewed F/C/E/P/U changes and the iOS acceptance script passed.
- [ ] SIGNOFF (Data hat): I reviewed fixture/schema/migration changes and the data acceptance script passed.
````

- [ ] **Step 3: 写 adversarial-review 模板**

写入 `docs/governance/adversarial-review-template.md`：

````markdown
# Adversarial Review 模板

用于 codex:adversarial-review 闸门（CLAUDE.md 规则 2 强制类改动）。

## Review 维度

### 1. Spec 覆盖完整性
- 对照 plan/modules spec，逐条检查：有没有漏项？有没有超范围？

### 2. 代码正确性
- 语法、逻辑、边界条件、错误处理

### 3. 无代码经验者可执行性
- CLAUDE.md 规则 3：每模块验收必须无代码经验者可执行
- 操作步骤是否详细？预期现象是否明确？通过/失败判据是否清晰？

### 4. 安全 / 敏感信息
- 密码、token、.env 是否在 .gitignore
- 是否有硬编码的 secret

### 5. 内部一致性
- 文件路径、类型名、方法签名在各 task 间是否一致
- Step 编号是否连续

### 6. 与现有文件的兼容性
- 是否破坏现有 .gitignore / CLAUDE.md / settings.json

## 输出格式

每维度给：**PASS** / **NEEDS-ATTENTION** / **BLOCKER**

总判决：**approve** 或 **needs-attention**

## 闭环规则

- Claude 起草 → 开 PR → 跑 adversarial-review → 修 findings → 再跑
- 连续 3 轮未收敛 → 停止推进，提交用户决定
- 中间操作自动执行，不请示用户
- 用户仅在 approve 后手工 merge，或 3 轮未收敛时介入
````

- [ ] **Step 4: 写三 Hat 签字规则文档**

写入 `docs/governance/signing-rules.md`：

````markdown
# 三 Hat 签字规则（单人项目降级版）

来源：kline_trainer_modules_v1.4.md §十五.4

## 规则

单人项目下，原"3 方签字（后端 / iOS / 数据）"降级为：
**同一人在同一份 PR 里，按涉及的 hat 分别签字。**

### 签字格式（固定，不要修改）

```text
SIGNOFF (Backend hat): I reviewed B/M0.1/M0.2 changes and the backend acceptance script passed.
SIGNOFF (iOS hat): I reviewed F/C/E/P/U changes and the iOS acceptance script passed.
SIGNOFF (Data hat): I reviewed fixture/schema/migration changes and the data acceptance script passed.
```

### 何时签哪个 hat

| PR 涉及的文件 | 需要签的 hat |
|---|---|
| `backend/**`、`schema.sql`、`openapi.yaml`、migration SQL | Backend hat |
| `ios/**`、`.swift` 文件、Xcode 工程 | iOS hat |
| `fixtures/**`、`tools/fixtures/**`、训练组 SQLite、CSV、JSON schema | Data hat |
| `.github/**`、`CLAUDE.md`、`scripts/**` | 全部涉及的 hat |

### 签字前必须完成

1. GitHub PR 页面所有自动检查绿色（如果有 CI）
2. codex:adversarial-review 的每条 finding 已处理或记录接受风险
3. PR 只包含一个主行为面，无顺手重构
4. 本人运行验收脚本并看到 PASS
5. 本人在 PR 评论里粘贴签字语句
6. 本人点击 GitHub 网页上的 Merge 按钮

### Claude 不能代签

Claude 不能代替用户签字、不能代替用户点 Merge。
````

- [ ] **Step 5: 验证三个文件都存在**

Run: `ls -1 .github/PULL_REQUEST_TEMPLATE.md docs/governance/signing-rules.md docs/governance/adversarial-review-template.md`

Expected: 三个文件路径都列出来，无 `No such file`。

- [ ] **Step 6: Commit**

```bash
git add .github/PULL_REQUEST_TEMPLATE.md docs/governance/
git commit -m "$(cat <<'EOF'
docs: add PR template, adversarial-review template, and three-hat signing rules

Single-developer adaptation of spec §15.4 three-party signoff.
Adversarial-review template documents the codex review dimensions and
close-loop rules per CLAUDE.md rule 2.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Xcode 空工程

**Files:**
- Create: `ios/KlineTrainer/` (Xcode 生成，含 .xcodeproj + SwiftUI App)

- [ ] **Step 1: 在 Xcode 中创建项目（逐字 GUI 指南）**

> **给用户的操作步骤**（用户本人在 Mac 上执行）：
>
> 1. 打开 Xcode（从 Launchpad 或 Applications 文件夹）
> 2. 点击菜单栏 **File → New → Project...**
> 3. 在弹出窗口顶部选择 **iOS** 标签页
> 4. 选择 **App**，点 **Next**
> 5. 填写以下信息：
>    - **Product Name**: `KlineTrainer`
>    - **Team**: 选择你的 Apple ID（如果没有，点 Add Account 登录）
>    - **Organization Identifier**: `com.agateuu1234`
>    - **Interface**: **SwiftUI**
>    - **Language**: **Swift**
>    - **Storage**: **None**
>    - 不勾选 Include Tests（后续手动添加）
> 6. **重要**：如果底部出现 **"Create Git repository on my Mac"** 勾选框，**取消勾选**（项目已经在 git 仓库里，不要嵌套创建）
> 7. 点 **Next**
> 8. 在文件选择器里导航到项目的 `ios/` 目录：`/Users/maziming/Coding/Prj_Kline trainer/ios/`
> 9. 点 **Create**
> 10. Xcode 会打开新项目。**先不做任何修改**，直接关闭 Xcode。

- [ ] **Step 2: 设置 iOS Deployment Target 为 17.0**

> 在 Xcode 中：
> 1. 打开 `ios/KlineTrainer/KlineTrainer.xcodeproj`
> 2. 左侧文件树最上面点击蓝色 **KlineTrainer** 图标（项目根）
> 3. 中间面板选择 **KlineTrainer** target（不是 project）
> 4. 选择 **General** 标签
> 5. 找到 **Minimum Deployments** → 把版本改成 **17.0**
> 6. `Cmd+S` 保存

- [ ] **Step 3: 添加 GRDB Swift Package 依赖**

> 在 Xcode 中：
> 1. 菜单 **File → Add Package Dependencies...**
> 2. 右上角搜索框输入：`https://github.com/groue/GRDB.swift`
> 3. **Dependency Rule** 选择 **Up to Next Major Version**，填 `6.29.0`
> 4. 点 **Add Package**
> 5. 勾选 **GRDB** 库，点 **Add Package**
> 6. `Cmd+S` 保存

- [ ] **Step 4: 确认 iOS Simulator 可用**

Run: `xcrun simctl list devices available | grep -i "iphone" | head -5`

Expected: 至少看到一个 iPhone 设备（如 `iPhone 16`、`iPhone 15` 等）。

如果没有任何设备：
> 1. 打开 Xcode
> 2. 菜单 **Xcode → Settings... → Platforms**
> 3. 点左下角 **+** 按钮
> 4. 选择 **iOS 17.x** 或更高版本
> 5. 等待下载完成

- [ ] **Step 5: 验证 Xcode 工程能编译**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/ios/KlineTrainer" && xcodebuild -list 2>&1 | head -20`

Expected: 能看到 `Targets: KlineTrainer`，以及 `Build Configurations: Debug, Release`

Run（用第一个可用的 iPhone simulator）:

```bash
DEST=$(xcrun simctl list devices available | grep -i "iphone" | head -1 | sed 's/.*(\(.*\)).*/\1/')
cd "/Users/maziming/Coding/Prj_Kline trainer/ios/KlineTrainer"
xcodebuild -scheme KlineTrainer -destination "platform=iOS Simulator,id=$DEST" build 2>&1 | tail -5
```

Expected: 最后一行包含 `BUILD SUCCEEDED`

- [ ] **Step 6: Commit Xcode 工程**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/
git commit -m "$(cat <<'EOF'
chore: create Xcode project (iOS 17, SwiftUI, GRDB 6.29+)

Empty KlineTrainer app target. Deployment target iOS 17.0.
GRDB added via SPM.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: FastAPI 骨架 + health endpoint

**Files:**
- Create: `backend/tests/__init__.py`
- Create: `backend/tests/test_health.py`
- Create: `backend/app/main.py`

- [ ] **Step 1: 安装 Python 依赖**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && pip3 install -r requirements.txt pytest httpx 2>&1 | tail -3`

Expected: `Successfully installed ...`

- [ ] **Step 2: 创建 tests 目录**

```bash
mkdir -p backend/tests
touch backend/tests/__init__.py
```

- [ ] **Step 3: 写 test_health.py（TDD：先写测试）**

```python
from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)

def test_health_returns_200():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
```

- [ ] **Step 4: 运行测试，确认失败**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && python3 -m pytest tests/test_health.py -v 2>&1`

Expected: FAIL，报错 `ModuleNotFoundError: No module named 'app.main'` 或 `ImportError`

- [ ] **Step 5: 写 main.py 最小实现**

```python
from fastapi import FastAPI

app = FastAPI(title="Kline Trainer API", version="0.1.0")

@app.get("/health")
async def health():
    return {"status": "ok"}
```

- [ ] **Step 6: 运行测试，确认通过**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && python3 -m pytest tests/test_health.py -v 2>&1`

Expected: `PASSED`

- [ ] **Step 7: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add backend/app/main.py backend/tests/
git commit -m "$(cat <<'EOF'
feat: FastAPI health endpoint with TDD test

GET /health returns {status: ok}. Test-first approach.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: NAS 环境预检

**Files:**
- Create: `scripts/nas-preflight.sh`

- [ ] **Step 1: 确认 .gitignore 已覆盖 .env**

Run: `grep -q '^\.env$' .gitignore && echo "PASS: .env in .gitignore" || echo "FAIL"`

Expected: `PASS`（当前仓库 `.gitignore` 已有 `.env` 规则）

- [ ] **Step 2: 创建 backend/.env（用户手工操作）**

> **给用户的操作步骤**：
>
> 1. 打开 Terminal
> 2. 粘贴：`cp "/Users/maziming/Coding/Prj_Kline trainer/backend/.env.example" "/Users/maziming/Coding/Prj_Kline trainer/backend/.env"`
> 3. 用文本编辑器打开 `backend/.env`
> 4. 把 `192.168.1.xxx` 改成你 NAS 的真实 IP 地址
> 5. 把 `changeme` 改成你想用的 PostgreSQL 密码（`.env.example` 和 `docker-compose.yml` 共用这个变量，改一处即可）
> 6. 保存

- [ ] **Step 3: 写 NAS 预检脚本——骨架**

```bash
cat > scripts/nas-preflight.sh <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail

echo "=== NAS Environment Preflight ==="
SCRIPT
chmod +x scripts/nas-preflight.sh
```

- [ ] **Step 4: 添加 .env 检查**

追加到 `scripts/nas-preflight.sh`：

```bash
cat >> scripts/nas-preflight.sh <<'SCRIPT'

# 1. 检查 .env 是否存在
if [ ! -f backend/.env ]; then
    echo "FAIL: backend/.env not found."
    echo ""
    echo "  操作步骤："
    echo "  1. 打开 Terminal"
    echo "  2. 粘贴: cp backend/.env.example backend/.env"
    echo "  3. 用文本编辑器打开 backend/.env"
    echo "  4. 把 192.168.1.xxx 改成你 NAS 的真实 IP 地址"
    echo "  5. 把 changeme 改成你想用的 PostgreSQL 密码"
    echo "  6. 保存文件，重新运行此脚本"
    exit 1
fi

source backend/.env
SCRIPT
```

- [ ] **Step 5: 添加网络 + 端口检查**

追加到 `scripts/nas-preflight.sh`：

```bash
cat >> scripts/nas-preflight.sh <<'SCRIPT'

# 2. 检查 NAS 网络可达
echo -n "Checking NAS network ($NAS_HOST)... "
if ping -c 1 -W 3 "$NAS_HOST" > /dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL: Cannot reach $NAS_HOST"
    echo "  可能原因：NAS 没开机 / IP 填错 / 不在同一网络"
    exit 1
fi

# 3. 检查 PostgreSQL 端口
echo -n "Checking PostgreSQL port ($NAS_HOST:5432)... "
if nc -z -w 3 "$NAS_HOST" 5432 2>/dev/null; then
    echo "PASS"
else
    echo "FAIL: Port 5432 not open on $NAS_HOST"
    echo "  可能原因：NAS 上 PostgreSQL Docker 容器未启动"
    echo "  操作：SSH 到 NAS 执行 cd backend && docker compose up -d"
    exit 1
fi
SCRIPT
```

- [ ] **Step 6: 添加 PostgreSQL 连接检查 + 最终输出**

追加到 `scripts/nas-preflight.sh`：

```bash
cat >> scripts/nas-preflight.sh <<'SCRIPT'

# 4. 检查 PostgreSQL 连接
echo -n "Checking PostgreSQL connection... "
if python3 -c "
import sys
try:
    import asyncio, asyncpg
    async def check():
        conn = await asyncpg.connect('$DB_URL')
        ver = await conn.fetchval('SELECT version()')
        await conn.close()
        return ver
    ver = asyncio.run(check())
    print(f'PASS (PostgreSQL {ver.split(chr(44))[0]})')
except Exception as e:
    print(f'FAIL: {e}')
    sys.exit(1)
" 2>&1; then
    true
else
    echo "  可能原因：密码不对 / 数据库名不对 / asyncpg 没安装"
    exit 1
fi

echo ""
echo "=== NAS Preflight: ALL PASS ==="
SCRIPT
```

- [ ] **Step 7: 运行预检**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer" && bash scripts/nas-preflight.sh`

Expected: 全部 PASS，最后一行 `=== NAS Preflight: ALL PASS ===`

如果某步 FAIL：按脚本输出的中文提示操作，修复后重新运行。

- [ ] **Step 8: Commit**

```bash
git add scripts/nas-preflight.sh
git commit -m "$(cat <<'EOF'
chore: add NAS environment preflight script

Checks .env existence, network, port 5432, and PostgreSQL connection.
Provides step-by-step Chinese troubleshooting for each failure.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: 验收脚本 + 最终验证

**Files:**
- Create: `scripts/acceptance/plan_0a_toolchain.sh`

- [ ] **Step 1: 写验收脚本——骨架 + check 函数**

```bash
cat > scripts/acceptance/plan_0a_toolchain.sh <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/../.."
PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Plan 0a Acceptance Test ==="
echo ""
SCRIPT
chmod +x scripts/acceptance/plan_0a_toolchain.sh
```

- [ ] **Step 2: 添加目录结构检查**

```bash
cat >> scripts/acceptance/plan_0a_toolchain.sh <<'SCRIPT'

# 1. 目录结构
check "backend/app/__init__.py exists"     test -f backend/app/__init__.py
check "backend/requirements.txt exists"    test -f backend/requirements.txt
check "backend/docker-compose.yml exists"  test -f backend/docker-compose.yml
check "backend/.env.example exists"        test -f backend/.env.example
check "ios/ directory exists"              test -d ios
check "fixtures/golden/m0/ exists"         test -d fixtures/golden/m0/source
check "scripts/acceptance/ exists"         test -d scripts/acceptance
check "tools/fixtures/ exists"             test -d tools/fixtures
SCRIPT
```

- [ ] **Step 3: 添加 GitHub + 治理文档检查**

```bash
cat >> scripts/acceptance/plan_0a_toolchain.sh <<'SCRIPT'

# 2. GitHub + 治理
check "CODEOWNERS exists"                        test -f .github/CODEOWNERS
check "PR template exists"                       test -f .github/PULL_REQUEST_TEMPLATE.md
check "Signing rules doc exists"                 test -f docs/governance/signing-rules.md
check "Adversarial-review template exists"       test -f docs/governance/adversarial-review-template.md
check "PR template has Backend hat"              grep -q "Backend hat" .github/PULL_REQUEST_TEMPLATE.md
check "PR template has iOS hat"                  grep -q "iOS hat" .github/PULL_REQUEST_TEMPLATE.md
check "PR template has Data hat"                 grep -q "Data hat" .github/PULL_REQUEST_TEMPLATE.md

check "enforce_admins enabled" bash -c '
    gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); assert d[\"enforce_admins\"][\"enabled\"]"
'
SCRIPT
```

- [ ] **Step 4: 添加 Xcode + FastAPI + NAS 检查 + 最终输出**

```bash
cat >> scripts/acceptance/plan_0a_toolchain.sh <<'SCRIPT'

# 3. Xcode 工程
check "Xcode project exists" test -d ios/KlineTrainer/KlineTrainer.xcodeproj

# 4. FastAPI
check "FastAPI health test passes" bash -c '
    cd backend && python3 -m pytest tests/test_health.py -q 2>&1 | grep -q "1 passed"
'

# 5. NAS preflight
check "NAS preflight passes" bash scripts/nas-preflight.sh

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "PLAN 0A PASS"
    exit 0
else
    echo ""
    echo "PLAN 0A FAIL ($FAIL items)"
    exit 1
fi
SCRIPT
```

- [ ] **Step 5: 运行验收**

Run: `cd "/Users/maziming/Coding/Prj_Kline trainer" && bash scripts/acceptance/plan_0a_toolchain.sh`

Expected:
```
=== Plan 0a Acceptance Test ===

PASS  backend/app/__init__.py exists
PASS  backend/requirements.txt exists
...
PASS  NAS preflight passes

=== Results: N passed, 0 failed ===

PLAN 0A PASS
```

通过判据：**全部 PASS，最后一行显示 `PLAN 0A PASS`**。
失败判据：任意一行 FAIL。

- [ ] **Step 6: Commit**

```bash
git add scripts/acceptance/plan_0a_toolchain.sh
git commit -m "$(cat <<'EOF'
test: add Plan 0a acceptance script

Checks directory structure, GitHub protection, governance docs,
FastAPI health, and NAS connection.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## 验收总结

**给用户的最终验收步骤**：

1. 打开 Terminal
2. 进入项目目录：`cd "/Users/maziming/Coding/Prj_Kline trainer"`
3. 粘贴：`bash scripts/acceptance/plan_0a_toolchain.sh`
4. 看到 `PLAN 0A PASS` 就算通过
5. 如果有 FAIL，按每一条 FAIL 的提示操作，修复后重跑
