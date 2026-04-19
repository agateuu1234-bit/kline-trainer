# Plan 0a v3 — PR #13 拆分替换 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **⚠ 依赖 `gov-bootstrap-hardening` PR 合入 main**：本 plan 的 Task 5 前置 codex-attest 依赖 hardening PR 提供的 `attest-ledger.json` + `guard-attest-ledger.sh` hook。hardening 未 merge 前请勿执行本 plan。

**Goal:** 把 PR #13（plan-0a/v2，被 gov-bootstrap #14 部分覆盖的过时 PR）拆分为仅含 hardening 未覆盖的纯增量 PR #17，然后关闭 PR #13，完成 Plan 0a 闭环。

**Architecture:** 从当前 `origin/main` 切新分支 `plan-0a/v3-split`；只从 `origin/plan-0a/v2` 提取 KEEP/MERGE 文件；治理类冲突文件（CLAUDE.md / .claude/settings.json / .github/CODEOWNERS）全部丢弃以防回退 plan-0b 成果；走本地 acceptance + codex:adversarial-review + 用户 PR 评论贴 verdict（🅱️ 降级路径）。

**Tech Stack:** git / gh / bash / codex-rescue 工具链。

**Per-file keep/drop 决策表**：

| 文件 | 决策 | 理由 |
|---|---|---|
| `.github/CODEOWNERS` | DROP | main plan-0b 版更精细，PR #13 `* @owner` 弱化保护 |
| `CLAUDE.md` | DROP | main 是 plan-0b 治理骨架，PR #13 旧版回退会丢规则 |
| `.claude/settings.json` | DROP | main 237 行 vs PR #13 148 行（多 hooks/permissions） |
| `.github/PULL_REQUEST_TEMPLATE.md` | KEEP | main 没有 |
| `.gitignore` | MERGE-ONLY | 仅追加 Xcode 段（xcuserdata/ DerivedData/ *.hmap *.ipa *.xcuserstate *.moved-aside） |
| `backend/**` (8 files) | KEEP | FastAPI 骨架 + tests |
| `ios/**` (9 files) | KEEP | Xcode 工程（当前本地 `ios/` untracked 会被覆盖） |
| `fixtures/**` (4 .gitkeep) | KEEP | 目录占位 |
| `docs/governance/signing-rules.md` | KEEP（需核对） | 提到 "CLAUDE.md 规则 2"，plan-0b 后规则结构不同，Task 3 里调整引用 |
| `docs/governance/adversarial-review-template.md` | KEEP（需核对） | 同上 |
| `scripts/acceptance/plan_0a_toolchain.sh` + `.gitkeep` | KEEP | acceptance 脚本 |
| `scripts/nas-preflight.sh` | KEEP | 预检脚本 |
| `tools/fixtures/.gitkeep` | KEEP | 目录占位 |

合计 KEEP 29 个文件 + MERGE 1 个文件（.gitignore 追加段）+ DROP 3 个文件。

---

## Task 1: 创建新分支并 checkout 所有 KEEP 文件

**Files:**
- Create: 分支 `plan-0a/v3-split` from `origin/main`
- Modify: 本地 ios/ 目录（当前 untracked，会被覆盖为 PR #13 版）

- [ ] **Step 1: 检查本地无未提交改动（ios/ untracked 除外）**

```bash
git status --short
```
预期：只有 `?? ios/` 一行。若还有其他变更，先 stash。

- [ ] **Step 2: 从 main 创建新分支**

```bash
git fetch origin
git checkout -B plan-0a/v3-split origin/main
```
预期：切到干净 main 头。

- [ ] **Step 3: 递归比对本地 untracked ios/ 与 PR #13 版本，并安全备份**

先列出双方文件集合做递归对比：

```bash
git ls-tree -r --name-only origin/plan-0a/v2 ios | sort > /tmp/ios-v2.txt
(cd . && find ios -type f | sort) > /tmp/ios-local.txt
diff -u /tmp/ios-v2.txt /tmp/ios-local.txt || true
```

对"仅本地有"的任何文件（`+` 行），逐条识别是 Xcode user state（可丢）还是用户未提交的真实工作（必须保留）。

**禁止 `rm -rf ios/`。** 如果需要腾位置给 Task 1 Step 4 的 checkout：

```bash
BACKUP=/tmp/ios-backup-$(date +%s)
mkdir -p "$BACKUP"
mv ios "$BACKUP"/
echo "backed up local ios/ to $BACKUP"
```

然后停下等用户口头 OK 才进 Step 4。备份目录保留至本 plan 全部 Task 完成 + PR #17 merge 之后再由用户手工删除。

- [ ] **Step 4: 从 PR #13 分支 checkout KEEP 文件**

```bash
git checkout origin/plan-0a/v2 -- \
  .github/PULL_REQUEST_TEMPLATE.md \
  backend/ \
  docs/governance/ \
  fixtures/ \
  ios/ \
  scripts/acceptance/ \
  scripts/nas-preflight.sh \
  tools/fixtures/
```
预期：`git status` 显示 29 个文件 staged。

- [ ] **Step 5: 验证 DROP 文件未被动**

```bash
git diff --cached --name-only | grep -E '(CODEOWNERS|CLAUDE\.md|\.claude/settings\.json)$'
```
预期：空输出。若有，`git reset HEAD <file> && git checkout -- <file>` 回滚。

- [ ] **Step 6: 提交**

```bash
git commit -m "feat(plan-0a v3): extract non-governance increments from PR #13"
```

---

## Task 2: 合并 .gitignore Xcode 段

**Files:**
- Modify: `.gitignore`（main 版基础上追加 Xcode 段）

- [ ] **Step 1: 查看待追加段**

```bash
git show origin/plan-0a/v2:.gitignore | grep -A 6 "# Xcode"
```
预期输出：
```
# Xcode
xcuserdata/
*.xcuserstate
*.moved-aside
DerivedData/
*.hmap
*.ipa
```

- [ ] **Step 2: 确认 main 版 .gitignore 没有 Xcode 段**

```bash
grep "^# Xcode" .gitignore || echo "NO-XCODE-SECTION"
```
预期：`NO-XCODE-SECTION`。

- [ ] **Step 3: 在 main 版 .gitignore 末尾追加 Xcode 段**

使用 Edit 工具，把上面 Step 1 的 7 行追加到文件末尾（前面空一行分隔）。

- [ ] **Step 4: 提交**

```bash
git add .gitignore
git commit -m "chore(gitignore): add Xcode exclusions"
```

---

## Task 3: 校正 docs/governance/*.md 对新 CLAUDE.md 的引用

**Files:**
- Modify: `docs/governance/signing-rules.md`（"CLAUDE.md 规则 2" 等引用）
- Modify: `docs/governance/adversarial-review-template.md`（"CLAUDE.md 规则 3" 等引用）

- [ ] **Step 1: 逐一读取两个文件找到对老 CLAUDE.md 的规则引用**

```bash
grep -n "CLAUDE.md 规则" docs/governance/*.md
```

- [ ] **Step 2: 对照当前 `CLAUDE.md` 的章节结构改写引用**

当前 CLAUDE.md 结构是 "1. Think Before Coding / 2. Simplicity First / 3. Surgical Changes / 4. Goal-Driven Execution" 加 "Repository governance backstop" 四条治理项。把旧引用（如"规则 2 强制类改动"）改为指向新的治理章节编号。

如果引用无法干净映射，改成指向 `.claude/workflow-rules.json` 的具体 key（例如 `adversarial_review_loop`）。

- [ ] **Step 3: 验证改写后文本不再含旧引用格式**

```bash
grep -n "CLAUDE\.md 规则 [0-9]" docs/governance/*.md || echo "NO-LEGACY-REFS"
```
预期：`NO-LEGACY-REFS`。

- [ ] **Step 4: 提交**

```bash
git add docs/governance/
git commit -m "docs(governance): align signing-rules & review-template with plan-0b CLAUDE.md"
```

---

## Task 4: 本地跑 acceptance

**Files:**
- Run: `scripts/acceptance/plan_0a_toolchain.sh`

- [ ] **Step 1: 脚本可执行位**

```bash
chmod +x scripts/acceptance/plan_0a_toolchain.sh scripts/nas-preflight.sh
```

- [ ] **Step 2: 运行 acceptance**

```bash
./scripts/acceptance/plan_0a_toolchain.sh
```
预期最后一行：`PLAN 0A PASS` 或类似；fail 数 = 0。

- [ ] **Step 3: 保存输出到文件（后面 PR body 要贴）**

```bash
./scripts/acceptance/plan_0a_toolchain.sh 2>&1 | tee /tmp/plan-0a-v3-acceptance.log
```

- [ ] **Step 4: 若有 FAIL**

逐条分析：是 plan-0b 环境差异（例：.claude/settings.json 已变）导致的脚本误判 → 修脚本；还是真实问题 → 停下来让用户决定。

---

## Task 5: codex-attest 前置评审（本 plan 文档 + branch-diff）

**Files:** n/a（本地脚本执行）

**依据**：`gov-bootstrap-hardening` spec §2.4 要求 — 任何外部可见动作前必须过 codex attest。Plan 0a v3 属于治理类改动（doc + 脚本），必须先过 file + branch-diff 两道。

- [ ] **Step 1: 对本 plan 文档跑 working-tree attest**

```bash
.claude/scripts/codex-attest.sh \
  --scope working-tree \
  --focus docs/superpowers/plans/2026-04-18-plan-0a-v3-split.md
```

预期：≤3 轮（按 workflow-rules.json adversarial_review_loop）收敛到 approve。每轮 needs-attention 都必须修 findings + 重提 commit + 重跑。

- [ ] **Step 2: 对分支 diff 跑 branch-diff attest**

```bash
.claude/scripts/codex-attest.sh \
  --scope branch-diff \
  --base origin/main \
  --head plan-0a/v3-split
```

预期：同上 ≤3 轮收敛到 approve；台账会写入 `branch:plan-0a/v3-split@<head_sha>`。

- [ ] **Step 3: 检查 `.claude/state/attest-ledger.json`**

```bash
cat .claude/state/attest-ledger.json | python3 -m json.tool
```

预期：两条新 entries（`file:docs/superpowers/plans/2026-04-18-plan-0a-v3-split.md` + `branch:plan-0a/v3-split@<head_sha>`）都有 `attest_time_utc` + `verdict_digest` 字段。

- [ ] **Step 4: 若 3 轮仍 needs-attention，按 workflow-rules `on_non_convergence` escalate 用户**

不擅自决定。

---

## Task 6: push + open PR

**Files:** n/a（远端动作）

⚠ 以下步骤外部可见，执行前需用户口头 OK。Task 5 已过闸时才应进 Task 6；若 hook 仍 BLOCK，说明 Task 5 未完成。

- [ ] **Step 1: push 分支**

```bash
git push -u origin plan-0a/v3-split
```

若 `gov-bootstrap-hardening` 已 merge，本步骤受本地 hook 保护：台账未命中会 block。

- [ ] **Step 2: open PR**

```bash
gh pr create --base main --head plan-0a/v3-split \
  --title "Plan 0a v3: PR #13 拆分后的纯增量（replaces #13）" \
  --body-file /tmp/pr17-body.md
```

其中 `/tmp/pr17-body.md` 内容要包含：
- 变更摘要（从 PR #13 body 迁移 + 注明哪些已被 plan-0b/gov-bootstrap 覆盖故删除）
- 验收结果（贴 Task 4 的 `/tmp/plan-0a-v3-acceptance.log` 关键片段）
- Task 5 两轮 attest 的 verdict digest 引用
- 三 Hat Signoff 三行占位符（留给用户签）
- 底部 "Closes #13"

- [ ] **Step 3: 记录新 PR 号**

```bash
gh pr view --json number,url
```

---

## Task 7: 在 PR 上贴 codex verdict 评论（server-side cross-check）

**Files:** n/a（走 gh pr comment；**由用户本人执行**，Claude 不代发评审结论）

**语义说明**：Task 5 已经是前置闸门；Task 7 只是把 verdict 沉淀到 PR 可见区域，便于人工复核。不再是唯一 review 发生地。

- [ ] **Step 1: 汇总 Task 5 两轮 attest 的 verdict 到一份 md**

```bash
mkdir -p artifacts/codex/plan-0a-v3
cat /tmp/codex-attest-plan0av3-*.log > artifacts/codex/plan-0a-v3/verdicts-combined.md
```

- [ ] **Step 2: 用户执行贴评论动作**

```bash
gh pr comment <NEW_NUMBER> --body-file artifacts/codex/plan-0a-v3/verdicts-combined.md
```

---

## Task 8: 关闭 PR #13

**Files:** n/a（远端动作）

⚠ 外部可见，执行前需用户 OK。

- [ ] **Step 1: 在 PR #13 留一条收尾评论**

由用户执行：

```bash
gh pr comment 13 --body "Superseded by PR #<NEW_NUMBER> (plan-0a v3 split — governance 文件已由 plan-0b #14 覆盖，此 PR 保留的过时版本会回退 plan-0b 成果)。"
```

- [ ] **Step 2: 关闭 PR #13（不删分支）**

由用户执行：

```bash
gh pr close 13
```

- [ ] **Step 3: PR #17 merge 由用户点网页 Merge 按钮**

（`docs/governance/signing-rules.md` 明确 "Claude 不能代替用户点 Merge"。）

---

## 非 coder 验收清单（CLAUDE.md 治理 §2 / workflow-rules.json verification_template）

按 `.claude/workflow-rules.json` 的 `verification_template` 要求：中文 / action-expected-pass_fail / 禁用"验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine"。

### 验收项 1：分支与 DROP 文件状态

| | 内容 |
|---|---|
| Action | 在仓库根目录终端运行 `git log --oneline plan-0a/v3-split ^origin/main` 和 `git diff origin/main...plan-0a/v3-split --name-only \| grep -E '(CODEOWNERS\|^CLAUDE\.md\|^\.claude/settings\.json)$'` |
| Expected | 第 1 条命令输出 3 条 commit（Task 1/2/3 各一条）；第 2 条命令输出为空 |
| Pass / Fail | 两条同时满足 = PASS；任一不满足 = FAIL |

### 验收项 2：acceptance 脚本

| | 内容 |
|---|---|
| Action | 运行 `./scripts/acceptance/plan_0a_toolchain.sh` |
| Expected | 末尾出现 `PLAN 0A PASS`（或等价的 "26/26 passed, 0 failed"） |
| Pass / Fail | 出现 PASS 且 FAIL 数 = 0 = PASS；否则 FAIL |

### 验收项 3：PR 闭环

| | 内容 |
|---|---|
| Action | 在浏览器打开 PR #17 页面；检查 (a) 有一条 codex verdict 评论；(b) 底部有 "Closes #13"；(c) PR #13 已是 Closed 状态 |
| Expected | (a) codex verdict 评论可见；(b) PR 页面显示会关联关闭 #13；(c) #13 页面顶部显示 Closed 徽章 |
| Pass / Fail | 三项同时满足 = PASS；任一缺失 = FAIL |

### 验收项 4：分支保护未被削弱

| | 内容 |
|---|---|
| Action | 运行 `gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection --jq '.enforce_admins.enabled, (.required_status_checks.contexts \| join(","))'` |
| Expected | 第 1 行 `true`；第 2 行包含 `codeowners-config-check,check-bootstrap-used-once`（顺序不限） |
| Pass / Fail | 两行都符合 = PASS；任一不符 = FAIL |

---

## Self-Review（起草后自查）

1. **Spec 覆盖**：本 plan 的 spec 是"B 方案（用户 04-18 裁决）"+ 决策表，每个 Task 对应决策表的动作；无遗漏。
2. **Placeholder 扫描**：所有 bash 命令都是完整可执行；`<NEW_NUMBER>` 是运行时产出值（Task 5 Step 3 记录），不算 placeholder。
3. **类型一致**：分支名 `plan-0a/v3-split` 各处一致；PR 编号留待 Task 5 生成后回填。
4. **governance 回退风险**：已通过 Task 1 Step 5 断言 DROP 文件未被 staged。
