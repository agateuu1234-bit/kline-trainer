# PR 1a — Catalyst CI workflow split + H1 spec reclassify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `catalyst-build` CI job 从 `swift-contracts-smoke.yml`（带 `paths` filter）拆成独立的 always-trigger workflow，消除 §15.4 ledger H9「paths filter 跳过 → required check 永不报告 → PR 死锁」架构性矛盾；同步把 §C1b 闸门 #4 production handler 集成测试 residual（H1）从 "Wave 1 验收" reclassify 为 "Wave 2 验收"。

**Architecture:** GitHub branch protection 的 required status check 以 **check-run 名（= job 的 `name:` 字段）** 匹配，与所在 workflow 文件名/workflow 名无关。因此把 job 整体搬到新文件、保持 job `name` byte-identical（`Mac Catalyst build-for-testing on macos-15`），既能让 required check 配置继续命中，又因新 workflow 无 `paths` filter 而在**每个** PR 都运行并报告，解开 H9 死锁。spec/ledger 改动是纯 wording reclassify（C8 ChartContainerView + E5 TrainingEngine 属 Wave 2，故依赖三模块 orchestration 的集成测试只能在 Wave 2 闭环）。

**Tech Stack:** GitHub Actions YAML、Markdown（spec + ledger）。**0 业务代码**（无 Swift / Python 改动）。

**Scope（3 子项，对齐 Wave 1 outline 顺位 1a + `feedback_planner_packaging_bias` ≤3 子项）：**
1. Workflow split：新建 `.github/workflows/catalyst-build.yml`（always-trigger）+ 从 `swift-contracts-smoke.yml` 移除 `catalyst-build` job → 解 H9。
2. H1 spec amendment：`kline_trainer_modules_v1.4.md` §C1b 闸门 #4（L1178 + L1180 + L1182）"Wave 1" → "Wave 2"。
3. §15.4 ledger sync：`docs/governance/2026-05-17-wave0-signoff-ledger.md` H1 行 reclassify Wave 2 + H9 行标记 ✅ 已解（option B）。

**Trust-boundary / 授权说明（重要）：** 本 PR 触及 `.github/**`、`kline_trainer_modules*.md`、`docs/governance/**`、`docs/superpowers/plans/**` —— 全部落在 `.claude/workflow-rules.json` 的 `trust_boundary_globs` **且** `codeowners_required_globs`。因此合并前需：(a) `codex:adversarial-review` 通过；(b) **user Approve**（codeowners_required_globs 变更的额外门）。

**明确非目标（不在 1a scope）：**
- 不动 origin / branch protection / required check 配置本身（admin 配置 = H8 / H10，属顺位 1c）。
- 不改 `swift-contracts-smoke.yml` 的 `paths` filter 或 `swift-test` job（`swift test on macos-15` **不是** required check，留 paths filter 无死锁风险）。
- 不修改 `catalyst-build` job 的任何 step 内容（**只搬不改**；保证 CI 行为零变化）。
- 不碰工作树里已存在的无关改动 `scripts/governance/verify-freeze-tag.sh`（上个 session 残留 cosmetic `$TARGET_REF`→`${TARGET_REF}`，不纳入本 PR）。
- README 不改（outline 1a scope 未含）。

---

## Task 0 — §15.3 评审策略前置（per `docs/governance/wave1-plan-template.md`）

- [ ] **声明本 plan 适用的评审形式**

本 PR 为 governance / CI 基础设施变更，0 业务代码。按 spec §15.3：

- **局部对抗性评审（必）**：本 plan scope 内 `codex:adversarial-review`；4-5 轮内收敛或 escalate user（per `feedback_codex_plan_budget_overshoot`）。先 plan-stage review，实施后再 branch-diff review。
- **集成层评审（不适用）**：本 PR 不含 C8 桥接 / E5 编排。
- **性能评审（不适用）**：本 PR 不含 Phase 5 磨光 / 渲染热点。

无需写代码即可完成 Task 0；声明完成后进 Task 1。

---

## Task 1 — Workflow split：catalyst-build 独立 always-trigger workflow（解 H9）

**Files:**
- Create: `.github/workflows/catalyst-build.yml`
- Modify: `.github/workflows/swift-contracts-smoke.yml`（删除 `catalyst-build` job，行 41-74）

**关键不变量（codex 重点审查项）：**
- 新 workflow 的 job `name:` 必须**逐字节等于** `Mac Catalyst build-for-testing on macos-15`（required check context 靠此匹配；改名 = 重新引入死锁）。
- `catalyst-build` job 的 4 个 step（checkout / Assert Xcode / build-for-testing / Gate）必须与移动前**逐字节相同**（只搬不改 → CI 行为零变化）。
- 新 workflow 的 `on.pull_request` **不得**含 `paths:`（无 filter = 每 PR 必跑必报 = 解 H9）。

- [ ] **Step 1: 写新 workflow 文件 `.github/workflows/catalyst-build.yml`**

```yaml
name: Mac Catalyst Build

# H9 resolution（Wave 1 顺位 1a，option B）：catalyst-build 从 swift-contracts-smoke.yml
# 拆出为独立 always-trigger workflow（无 paths filter），使 required check
# "Mac Catalyst build-for-testing on macos-15" 在每个 PR 都运行并报告，消除
# "paths filter 跳过 → required check 永不报告 → PR 死锁" 架构性矛盾（§15.4 ledger H9）。
# 注意：required check 以 job name 匹配；job name 必须保持不变。
on:
  pull_request:
  push:
    branches: [main]

# Trust-boundary hardening（对齐 swift-contracts-smoke.yml / codeowners-config-check.yml）:
# - Least-privilege token: read-only repo contents
# - actions/checkout pinned to full SHA
permissions:
  contents: read

jobs:
  catalyst-build:
    name: Mac Catalyst build-for-testing on macos-15
    runs-on: macos-15
    timeout-minutes: 15
    # 依赖 runner 默认 Xcode（macos-15 image 预装 Xcode 16）提供 xcodebuild。
    # 不硬编码 /Applications/Xcode_16.app 路径（镜像 swift-test job 已有的 codex Plan 1c R2
    # finding 修订 pattern；GHA image 刷新时路径可能变 → fail-fast 给清晰诊断）。
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      - name: Assert Xcode >= 16
        run: |
          xcodebuild -version
          XCODE_VER=$(xcodebuild -version | head -1 | awk '{print $2}')
          MAJOR=$(echo "$XCODE_VER" | cut -d. -f1)
          if [[ -z "$XCODE_VER" || "$MAJOR" -lt 16 ]]; then
            echo "FAIL: Xcode 16+ required (Swift 6.0 + Catalyst destination)；runner provides $XCODE_VER"
            echo "Available Xcode installs:"
            ls -la /Applications | grep -i xcode || true
            exit 1
          fi
          echo "Xcode $XCODE_VER OK"
      - name: Mac Catalyst build-for-testing
        working-directory: ios/Contracts
        run: |
          set -o pipefail
          xcodebuild build-for-testing \
            -scheme KlineTrainerContracts \
            -destination 'platform=macOS,variant=Mac Catalyst' \
            -derivedDataPath /tmp/derived 2>&1 | tee /tmp/catalyst-build.log
      - name: Gate — TEST BUILD SUCCEEDED + no error/warning
        run: |
          grep -F "** TEST BUILD SUCCEEDED **" /tmp/catalyst-build.log || { echo "BUILD SUCCEEDED 缺失"; exit 1; }
          ! grep -E "(^|[[:space:]])(error|warning):" /tmp/catalyst-build.log || { echo "error/warning 触发 gate"; exit 1; }
          echo "GATE PASS: §15.1 #3 闸门关闭（Catalyst CI 持续守护）"
```

- [ ] **Step 2: 从 `swift-contracts-smoke.yml` 删除 `catalyst-build` job**

删除该文件中 `catalyst-build:` 整段（原行 41-74，从 `  catalyst-build:` 到最后一行 `          echo "GATE PASS: §15.1 #3 闸门关闭（Catalyst CI 持续守护）"`）。删除后文件以 `swift-test` job 的最后一步 `        run: swift test` 结尾，保留 `name` / `on`（含 paths filter）/ `permissions` / `swift-test` job 不变。

删除后 `swift-contracts-smoke.yml` 完整内容应为：

```yaml
name: Swift Contracts Smoke Test

on:
  pull_request:
    paths:
      - 'ios/Contracts/**'
      - 'ios/KlineTrainer/**'
      - '.github/workflows/swift-contracts-smoke.yml'
  push:
    branches: [main]

# Trust-boundary hardening（对齐 Plan 1 R10 / Plan 1b / Plan 1c project convention）:
# - Least-privilege token: read-only repo contents
# - actions/checkout pinned to full SHA (same as codeowners-config-check.yml / schema-smoke.yml / openapi-smoke.yml)
permissions:
  contents: read

jobs:
  swift-test:
    name: swift test on macos-15
    runs-on: macos-15
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      # 依赖 runner 默认 Xcode（macos-15 image 预装 Xcode 16）提供 Swift 6.0+。
      # 不硬编码 /Applications/Xcode_16.0.app 路径（GHA image 刷新时路径可能变；
      # codex Plan 1c round 2 finding）。只断言 swift 版本，不满足则 fail-fast 给清晰诊断。
      - name: Assert Swift >= 6.0
        run: |
          swift --version
          SWIFT_VER=$(swift --version | grep -oE 'Apple Swift version [0-9]+\.[0-9]+' | awk '{print $NF}')
          MAJOR=$(echo "$SWIFT_VER" | cut -d. -f1)
          if [[ -z "$SWIFT_VER" || "$MAJOR" -lt 6 ]]; then
            echo "FAIL: Swift 6.0+ required (Swift Testing framework + Package.swift-tools-version: 6.0); runner provides $SWIFT_VER"
            exit 1
          fi
          echo "Swift $SWIFT_VER OK"
      - name: Run swift test
        working-directory: ios/Contracts
        run: swift test
```

- [ ] **Step 3: 验证新 workflow YAML 合法**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/catalyst-build.yml')); print('YAML OK')"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/swift-contracts-smoke.yml')); print('YAML OK')"
```
Expected: 两行 `YAML OK`。

- [ ] **Step 4: 验证 job name 保留（required check context 不破）**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
grep -F 'name: Mac Catalyst build-for-testing on macos-15' .github/workflows/catalyst-build.yml && echo "JOB NAME PRESERVED OK"
```
Expected: 命中该行 + `JOB NAME PRESERVED OK`。

- [ ] **Step 5: 验证新 workflow 无 paths filter（解 H9 的核心）**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
! grep -q 'paths:' .github/workflows/catalyst-build.yml && echo "NO PATHS FILTER OK"
```
Expected: `NO PATHS FILTER OK`。

- [ ] **Step 6: 验证旧 workflow 已移除 catalyst-build + 全仓 job-name 唯一（context 不歧义）**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
# 6a 旧 workflow 不再含该 job
! grep -q 'catalyst-build:' .github/workflows/swift-contracts-smoke.yml && \
! grep -q 'Mac Catalyst build-for-testing' .github/workflows/swift-contracts-smoke.yml && \
echo "REMOVED FROM OLD OK"
# 6b 全仓恰好 1 个 job 用该 name（codex R1 finding 2：repo-wide uniqueness；多处同名会让 required-check 信号歧义）
COUNT=$(grep -rh 'name: Mac Catalyst build-for-testing on macos-15' .github/workflows/ | wc -l | tr -d ' ')
[ "$COUNT" = "1" ] && echo "JOB NAME UNIQUE OK (count=$COUNT)" || { echo "FAIL: 期望全仓恰好 1 个 job name，实际 $COUNT"; exit 1; }
```
Expected: `REMOVED FROM OLD OK` + `JOB NAME UNIQUE OK (count=1)`。

- [ ] **Step 7: 验证 step 只搬不改（CI 行为零变化）**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
# 抽出移动前旧文件里的 catalyst-build job（从 HEAD），与新文件 job 段做内容比对
git show HEAD:.github/workflows/swift-contracts-smoke.yml | sed -n '/^  catalyst-build:/,$p' > /tmp/old-job.yml
sed -n '/^  catalyst-build:/,$p' .github/workflows/catalyst-build.yml > /tmp/new-job.yml
diff /tmp/old-job.yml /tmp/new-job.yml && echo "JOB BODY IDENTICAL OK"
```
Expected: `diff` 无输出 + `JOB BODY IDENTICAL OK`（job 段从 `  catalyst-build:` 起逐字节相同）。

- [ ] **Step 8: actionlint 静态检查（强制；codex R1 finding 3：yaml.safe_load 不验 Actions schema）**

`yaml.safe_load`（Step 3）只验 YAML 语法，不验 GitHub Actions schema（event keys / runner labels / job 结构）；语法合法但 Actions 无效的 workflow 会被 GitHub 忽略 → required check 永不报告 → H9 未解。故 actionlint **必跑**，未安装则先装：

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
if ! command -v actionlint >/dev/null 2>&1; then
  brew install actionlint || go install github.com/rhysd/actionlint/cmd/actionlint@latest || { echo "FAIL: actionlint 无法安装；改用 Task 5 push 后 check-run 实际出现作为强制替代验证"; exit 1; }
fi
# 判定标准 = 本 PR 不引入 NEW finding（非「零 finding」）。源文件 swift-contracts-smoke.yml 的 catalyst-build job
# 自带 1 条 pre-existing shellcheck SC2010 警告（`ls -la /Applications | grep -i xcode` 诊断行，仅 Xcode<16 失败分支跑）。
# 本 PR 字节级搬移该 job（Step 7 diff 已证），故 SC2010 随之平移：拆分前后总 finding 数恒为 1，无新增。
# SC2010 是 style 警告非 schema error，GitHub 照常运行 workflow → 不影响 H9。按 surgical / 只搬不改 invariant **不修** pre-existing 警告。
TOTAL=$(actionlint .github/workflows/catalyst-build.yml .github/workflows/swift-contracts-smoke.yml 2>&1 | grep -c 'shellcheck reported issue')
[ "$TOTAL" = "1" ] && echo "ACTIONLINT OK (仅 1 条 pre-existing SC2010，无新增 schema error)" || { echo "FAIL: actionlint finding 数 =$TOTAL，期望 1（出现新增 finding 或 schema error）"; actionlint .github/workflows/catalyst-build.yml .github/workflows/swift-contracts-smoke.yml; exit 1; }
```
Expected: `ACTIONLINT OK (仅 1 条 pre-existing SC2010，无新增 schema error)`。若本机彻底无法安装 actionlint，则以 **Task 5「push 后 required check-run 实际出现」**（权威 ground-truth = acceptance #6 的 `gh pr checks`）作为强制替代验证，必须 binary 勾选。

- [ ] **Step 9: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add .github/workflows/catalyst-build.yml .github/workflows/swift-contracts-smoke.yml
git commit -m "ci: split catalyst-build into always-trigger workflow (resolve H9 deadlock)"
```

---

## Task 2 — H1 spec amendment：§C1b 闸门 #4 "Wave 1" → "Wave 2"

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（L1178、L1180、L1182；§C1b Deceleration stop 契约测试块）

**背景：** §15.4 ledger H1 残留 = §C1b 闸门 #4 F3 的 production handler 集成测试。该测试依赖 C2 + C8 + E5 三模块 orchestration；按 Wave 1 outline §六，**C8 ChartContainerView + E5 TrainingEngine 属 Wave 2**（C2 在 Wave 1 顺位 3）。因此集成测试只能在 Wave 2 C8 集成 PR 内闭环。当前 spec 把它写为 "移 Wave 1" / "Wave 1 验收" —— 需 reclassify 为 Wave 2。

**grep-first 已验证：** "Wave 1" 在该块出现 **两处**（L1178 + L1180）；只改一处会留下内部矛盾，必须两处都改。

- [ ] **Step 1: 改 L1178（块标题里的 "移 Wave 1"）**

把：
```
- **Deceleration stop 契约测试**（闸门 #4 F3 修订 v1.4 — **Wave 0 仅 reducer 契约测试；production handler 集成测试移 Wave 1**）：
```
改为：
```
- **Deceleration stop 契约测试**（闸门 #4 F3 修订 v1.4 — **Wave 0 仅 reducer 契约测试；production handler 集成测试移 Wave 2**；Wave 1 顺位 1a reclassify，理由见下）：
```

- [ ] **Step 2: 改 L1180（"Wave 1 验收" 行）**

把：
```
  - **Wave 1 验收**（C2 DecelerationAnimator + C8 ChartContainerView 落地时同 PR 内）：production handler 集成测试 — 模拟延迟 animator 回调，验证 handler 必须**先**调用 `animator.stop()` 再计算 range；drawing 退出后无 `offsetApplied` 到达 reducer
```
改为：
```
  - **Wave 2 验收**（C8 ChartContainerView + E5 TrainingEngine 落地时同 PR 内；C2 DecelerationAnimator 已于 Wave 1 顺位 3 落地）：production handler 集成测试 — 模拟延迟 animator 回调，验证 handler 必须**先**调用 `animator.stop()` 再计算 range；drawing 退出后无 `offsetApplied` 到达 reducer
```

- [ ] **Step 3: 改 L1182（理由行，补 Wave 2 闭环依据）**

把：
```
  **理由**：production handler 涉及 C2/C8/E5 三模块 orchestration，非 Wave 0 单模块 scope；reducer 契约测试已覆盖契约面，handler 集成测试在生产代码落地的同 PR 验证更准。
```
改为：
```
  **理由**：production handler 涉及 C2/C8/E5 三模块 orchestration，非 Wave 0 单模块 scope；reducer 契约测试已覆盖契约面，handler 集成测试在生产代码落地的同 PR 验证更准。C8/E5 属 Wave 2（见 Wave 1 outline §六），故集成测试在 Wave 2 C8 集成 PR 内闭环（Wave 1 顺位 1a 仅 reclassify wording）。
```

- [ ] **Step 4: 验证两处 "Wave 1" 已清除、"Wave 2" 已就位**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
# 该块内不再出现 production handler 配 Wave 1
! grep -n 'production handler 集成测试移 Wave 1' kline_trainer_modules_v1.4.md && echo "L1178 OK"
! grep -n '\*\*Wave 1 验收\*\*（C2 DecelerationAnimator + C8 ChartContainerView' kline_trainer_modules_v1.4.md && echo "L1180 OK"
# Wave 2 措辞已就位
grep -n 'production handler 集成测试移 Wave 2' kline_trainer_modules_v1.4.md && echo "WAVE2 TITLE OK"
grep -n '\*\*Wave 2 验收\*\*（C8 ChartContainerView + E5 TrainingEngine' kline_trainer_modules_v1.4.md && echo "WAVE2 ACCEPT OK"
```
Expected: `L1178 OK`、`L1180 OK`、`WAVE2 TITLE OK`、`WAVE2 ACCEPT OK` 四行全出现。

- [ ] **Step 5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add kline_trainer_modules_v1.4.md
git commit -m "docs(spec): reclassify H1 deceleration integration test Wave 1->Wave 2"
```

---

## Task 3 — §15.4 ledger sync：H1 reclassify + H9 标记已解 + H8/H10 context name 修正

**Files:**
- Modify: `docs/governance/2026-05-17-wave0-signoff-ledger.md`（H1 行 L32、H8 行 L39、H9 行 L40、H10 行 L41）

**codex R1 finding 1（high）背景：** required-check context = job 的 `name:`（`Mac Catalyst build-for-testing on macos-15`），**不是** job key（`catalyst-build`）。现 H8/H10 行让 1c admin 去 require / assert `catalyst-build` —— 若 1c 照旧执行，会把 branch protection 配到新 workflow **永不报告**的 context 上，重建 H9 死锁。故必须在同次 ledger sync 把 H8/H10 的 context 名改对。此为 H9 修订的同族行，非 scope creep。

- [ ] **Step 1: 改 H1 行（reclassify Wave 2 + 修正陈旧 L1167 引用）**

把（L32）：
```
| H1 | L1167 production handler 集成测试 | PR #50 plan-residual | Spec §6 C1b 闸门 #4 F3 v1.4 修订移 Wave 1（PR 9 子项 1） |
```
改为：
```
| H1 | C1b 闸门 #4 F3 production handler 集成测试（modules §C1b L1180 区块） | PR #50 plan-residual | 顺位 1a spec amendment：modules §C1b 闸门 #4 reclassify Wave 1→Wave 2（C8/E5 属 Wave 2）；真正闭环 = Wave 2 C8 ChartContainerView 集成 PR（C2/C8/E5 orchestration 同 PR） |
```

- [ ] **Step 2: 改 H9 行（标记 ✅ 已解 option B）**

把（L40）：
```
| H9 | workflow `paths` filter 与 required check 架构性矛盾 | plan v6 codex R6 finding 1 | 独立后续 governance PR 决议：(A) 移除 paths filter 全 PR 跑；(B) 拆 catalyst-build 独立 workflow；(C) conditional skip + always-success 短路 |
```
改为：
```
| H9 | workflow `paths` filter 与 required check 架构性矛盾 | plan v6 codex R6 finding 1 | ✅ 顺位 1a 决议（option B）：catalyst-build 拆至独立 always-trigger workflow `.github/workflows/catalyst-build.yml`（无 paths filter，每 PR 必跑必报）；job name 保持 `Mac Catalyst build-for-testing on macos-15` 不变以保留 required check context。required check 配置 + machine-checkable 验证（H8/H10）仍在顺位 1c |
```

- [ ] **Step 3: 改 H8 行（required-check context 名修正为 job name）**

把（L39）：
```
| H8 | Catalyst CI required merge gate enforcement | spec v9 §6.G | PR 9 merge 后 admin 在 GitHub repo Settings → Branches → main → Required status checks 加 `catalyst-build`；GitHub UI 手动步骤 |
```
改为（codex branch-diff R1：加 GitHub Actions app-source 绑定，防同名 status 伪造）：
```
| H8 | Catalyst CI required merge gate enforcement | spec v9 §6.G | 顺位 1c admin 在 GitHub repo Settings → Branches → main → Required status checks 加 context `Mac Catalyst build-for-testing on macos-15`（= job `name`，**非** job key `catalyst-build`；顺位 1a 拆 workflow 后 context 仍为此名），并**绑定来源为 GitHub Actions app**（UI 选 source = GitHub Actions / Ruleset 设 integration_id=15368），**不可留 "any source"**——否则任意 integration 可写同名 status 伪造满足 gate（trust-boundary spoof）；GitHub UI 手动步骤 |
```

- [ ] **Step 4: 改 H10 行（machine-checkable 断言的 context 名同步修正）**

把（L41）：
```
| H10 | acceptance §G 缺 machine-checkable required check 验证 | plan v6 codex R6 finding 2 | PR 9 merge 后 admin 配 required check + 跑 `gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection --jq '.required_status_checks.contexts'` 断言含 `catalyst-build`；ledger 回填 verification 输出 |
```
改为（codex branch-diff R1：断言绑定 GitHub Actions app_id，legacy `.contexts` source-agnostic 不可作唯一依据）：
```
| H10 | acceptance §G 缺 machine-checkable required check 验证 | plan v6 codex R6 finding 2 | 顺位 1c admin 配 required check + 跑 `gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection --jq '.required_status_checks.checks[] | select(.context=="Mac Catalyst build-for-testing on macos-15")'` 断言该 entry 存在**且 `.app_id==15368`（GitHub Actions app，防伪造来源）**（job name context，**非** `catalyst-build`；legacy `.contexts` 数组不绑来源、source-agnostic，不可作唯一依据）；ledger 回填 verification 输出 |
```

- [ ] **Step 5: 验证 ledger 改动落位**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
grep -n 'reclassify Wave 1→Wave 2' docs/governance/2026-05-17-wave0-signoff-ledger.md && echo "H1 ROW OK"
grep -n '✅ 顺位 1a 决议（option B）' docs/governance/2026-05-17-wave0-signoff-ledger.md && echo "H9 ROW OK"
# H8/H10 已无裸 `catalyst-build` context 引用（仅允许说明性的「非 job key catalyst-build」）
grep -nE '加 `catalyst-build`|断言含 `catalyst-build`' docs/governance/2026-05-17-wave0-signoff-ledger.md && { echo "FAIL: H8/H10 仍有旧 context 名"; exit 1; } || echo "H8/H10 CONTEXT OK"
# 确认未误删/误改其它 residual 行（行数仍为 10 项 H1-H10）
grep -cE '^\| H[0-9]+ ' docs/governance/2026-05-17-wave0-signoff-ledger.md
```
Expected: `H1 ROW OK`、`H9 ROW OK`、`H8/H10 CONTEXT OK`，且最后一行计数为 `10`。

- [ ] **Step 6: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add docs/governance/2026-05-17-wave0-signoff-ledger.md
git commit -m "docs(ledger): sync H1 (Wave 2 reclassify) + H9 (resolved option B) + H8/H10 context name"
```

---

## Task 4 — 中文 non-coder acceptance checklist（CLAUDE.md backstop 原则 2）

**Files:**
- Create: `docs/acceptance/2026-05-20-pr1a-workflow-split-h1.md`

acceptance checklist 用中文，三段式 action / expected / pass-fail；二元可判定；禁忌词（`验证通过即可` / `看起来正常` / `应该没问题` / `should work` / `looks fine`）不得出现（`.claude/workflow-rules.json` forbidden_phrases）。

- [ ] **Step 1: 写 acceptance 文档**

```markdown
# PR 1a 验收清单 — Catalyst CI workflow split + H1 reclassify

> 面向非编码者：逐条照做，把每条「实际结果」与「预期」对比，勾选「通过 / 不通过」。任一条不通过 → 不合并，退回修复。

## 一、Workflow split（解 H9）

| # | 动作（在仓库根目录终端执行） | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 运行 `actionlint .github/workflows/catalyst-build.yml .github/workflows/swift-contracts-smoke.yml 2>&1 | grep -c 'shellcheck reported issue'`（actionlint 未装则先 `brew install actionlint`） | 打印 `1`（仅 1 条 pre-existing SC2010 `ls\|grep` 警告，随 job 字节级平移而来，本 PR 无新增 finding、无 schema error） | ☐ |
| 2 | 运行 `grep -F 'name: Mac Catalyst build-for-testing on macos-15' .github/workflows/catalyst-build.yml` | 打印出该行（job 名未改 → required check 不破） | ☐ |
| 3 | 运行 `grep -c 'paths:' .github/workflows/catalyst-build.yml` | 打印 `0`（新 workflow 无 paths filter → 每个 PR 都会跑） | ☐ |
| 4 | 运行 `grep -c 'catalyst-build:' .github/workflows/swift-contracts-smoke.yml` | 打印 `0`（旧文件已移除该 job，无重复定义） | ☐ |
| 5 | 运行 `grep -rh 'name: Mac Catalyst build-for-testing on macos-15' .github/workflows/ | wc -l` | 打印 `1`（全仓恰好一个 job 用该 name → required-check 信号不歧义） | ☐ |
| 6 | **（权威 H9 证明，push 后）** 运行 `gh pr checks <本 PR 号>`（或看 PR「Checks」页） | 列表含名为 `Mac Catalyst build-for-testing on macos-15` 的检查且状态是 pending/pass（**不是** skipped、**不是** 缺失） | ☐ |

## 二、H1 spec amendment（modules §C1b 闸门 #4）

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 7 | 运行 `grep -c 'production handler 集成测试移 Wave 2' kline_trainer_modules_v1.4.md` | 打印 `1` | ☐ |
| 8 | 运行 `grep -c 'production handler 集成测试移 Wave 1' kline_trainer_modules_v1.4.md` | 打印 `0`（旧 Wave 1 措辞已清除，无内部矛盾） | ☐ |
| 9 | 运行 `grep -c '\*\*Wave 2 验收\*\*（C8 ChartContainerView + E5 TrainingEngine' kline_trainer_modules_v1.4.md` | 打印 `1` | ☐ |

## 三、§15.4 ledger sync

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 10 | 运行 `grep -c 'reclassify Wave 1→Wave 2' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `1`（H1 行已 reclassify） | ☐ |
| 11 | 运行 `grep -c '✅ 顺位 1a 决议（option B）' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `1`（H9 行已标记已解） | ☐ |
| 12 | 运行 `grep -cE '加 .catalyst-build|断言含 .catalyst-build' docs/governance/2026-05-17-wave0-signoff-ledger.md`（`.` 通配反引号，避免转义；修订前此命令返回 `2`，修订后返回 `0`） | 打印 `0`（H8/H10 不再让 admin 把 job key `catalyst-build` 当 context；已改为 job name） | ☐ |
| 13 | 运行 `grep -cE '^\| H[0-9]+ ' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `10`（10 条 residual 一条不少，未误删） | ☐ |

## 四、范围隔离

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 14 | 运行 `git diff --name-only main...HEAD`（或在 PR「Files changed」页看） | 仅出现：`.github/workflows/catalyst-build.yml`、`.github/workflows/swift-contracts-smoke.yml`、`kline_trainer_modules_v1.4.md`、`docs/governance/2026-05-17-wave0-signoff-ledger.md`、`docs/acceptance/2026-05-20-pr1a-workflow-split-h1.md`、`docs/superpowers/plans/2026-05-20-pr1a-workflow-split-h1-amendment.md`；**不含** `scripts/governance/verify-freeze-tag.sh` | ☐ |

## 证据留存

把第 1-5、7-14 条命令输出截图 / 文本，连同第 6 条 `gh pr checks` 输出，贴到 PR 评论区。
```

- [ ] **Step 2: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add docs/acceptance/2026-05-20-pr1a-workflow-split-h1.md
git commit -m "docs(acceptance): PR 1a non-coder checklist"
```

---

## Task 5 — Verification before completion：push 后 required check-run 权威验证（codex R2 finding 2）

**为何独立成 task：** authoring-time grep（Task 1）+ actionlint（Step 8）只是先验；H9 是否真解的 **ground-truth** = 新 workflow 被 GitHub 接受、在 PR 上真的生成名为 `Mac Catalyst build-for-testing on macos-15` 的 check-run（不是 skipped、不是缺失）。此为 verification-before-completion 阶段的强制完成闸，也是 actionlint 无法安装时的强制替代验证。

- [ ] **Step 1: push 分支并开 PR**（branch / PR 细节见 Execution Handoff）

- [ ] **Step 2: 断言 required check-run 实际出现且未被 skip**

Run（`<PR>` 替换为本 PR 号）：
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
gh pr checks <PR> | tee /tmp/pr1a-checks.txt
grep -F 'Mac Catalyst build-for-testing on macos-15' /tmp/pr1a-checks.txt && echo "CHECK-RUN PRESENT OK" || { echo "FAIL: required check-run 未出现（workflow 未被 GitHub 接受 / 未触发）→ H9 未解"; exit 1; }
# 确认该 check-run 不是 skipped（skip 状态也不会满足 required check → 死锁）
! grep -iE 'Mac Catalyst build-for-testing on macos-15.*skipp' /tmp/pr1a-checks.txt && echo "NOT SKIPPED OK" || { echo "FAIL: check-run 被 skip"; exit 1; }
```
Expected: `CHECK-RUN PRESENT OK` + `NOT SKIPPED OK`。这是 acceptance #6 的机器化对应；通过即证 H9 真解。

- [ ] **Step 3: 把 Step 2 输出贴 PR 评论作为 H9 闭环证据**（per `.claude/workflow-rules.json` acceptance_evidence_upload）

---

## Self-Review（writing-plans 收尾自查）

**1. Spec coverage（对 Wave 1 outline 顺位 1a 三子项）：**
- ✅ Workflow split（catalyst-build 独立 always-trigger）→ Task 1
- ✅ H1 spec L1178/L1180/L1182 改 Wave 2 → Task 2
- ✅ §15.4 ledger H1 同步 + H9 标记已解 → Task 3
- ✅ 解 H9 deadlock → Task 1（option B）；H1 reclassify → Task 2 + Task 3

**2. Placeholder scan：** 无 TBD / "适当处理" / "类似上面"；每个文件改动给出完整 before/after 文本 + 精确 grep 验证命令。

**3. Type / 引用一致性：**
- job name `Mac Catalyst build-for-testing on macos-15` 在 Task 1 / acceptance / ledger H9 行三处一致。
- "Wave 2" reclassify 在 Task 2（spec）+ Task 3（ledger）+ Task 4（acceptance #6-8）一致。
- residual 计数断言（10 条）防止误删其它 H 行。

**4. 已知 residual / 风险（交 codex + 1c 续闭）：**
- **branch protection 配置本身**（admin 在 GitHub Settings 把 context `Mac Catalyst build-for-testing on macos-15` 设为 required + `gh api` 断言）属 H8/H10，顺位 1c admin step。1a 在 Task 3 已把 H8/H10 ledger 的 context 名从错误的 job key `catalyst-build` 改正为 job name（codex R1 finding 1），避免 1c 误配；但实际 admin 操作仍在 1c。
- **权威 H9 证明 = push 后 required check-run 实际出现**（acceptance #6 `gh pr checks` binary）：authoring-time grep（Task 1 Step 4/5）+ actionlint（Step 8）是先验；真正确认新 workflow 被 GitHub 接受并运行，以 verification-before-completion 阶段 push 后的 check-run 出现为 ground-truth（codex R1 finding 3）。
- macOS runner 成本：新 workflow 每个 PR（含 docs-only）都跑 catalyst-build（option B 的已知 trade-off，outline 已决；option C 短路更省但更复杂，未采）。
- **pre-existing SC2010 actionlint 警告**（impl 阶段发现）：源 catalyst-build job 的 `ls -la /Applications | grep -i xcode` 诊断行带 1 条 shellcheck SC2010 style 警告（仅 Xcode<16 失败分支跑）。本 PR 字节级搬移该 job（Step 7 diff 已证），警告随之平移，拆分前后总 finding 恒为 1、无新增、无 schema error，GitHub 照常运行 → 不影响 H9。按 surgical / 只搬不改 invariant **不在本 PR 修**；如要清理另开独立 PR（pre-existing tech debt，非 1a scope）。
- **H8/H10 required-check source 绑定**（codex branch-diff R1）：1a 仅修 ledger wording 让 1c 配对 context（job name + GitHub Actions app_id=15368 绑定，防同名 status 伪造）；实际 branch protection / Ruleset 配置 + app-bound 断言执行仍在顺位 1c admin step。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-20-pr1a-workflow-split-h1-amendment.md`.

下一步按用户指定流程：**先 `codex:adversarial-review` plan-stage 到收敛**，再 subagent-driven-development 实施。
