# Ruleset 必需检查清理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 main ruleset `15660830` 的必需状态检查从 11 个（仅 4 个可满足）改成正确的 6 个，让正常 PR 不再需要 admin bypass。

**Architecture:** 纯 GitHub 仓库设置编辑（ruleset），无代码/文件改动。user 真终端跑已实测的 applier（GET → jq 换 required contexts → PUT）；Claude 只做验证。design/plan 文档走 PR 作审计留痕。

**Tech Stack:** `gh api`（GET/PUT ruleset）、`jq`。

## Global Constraints

- **`gh api PUT` / mutating gh api 对 Claude 封禁** → ruleset 编辑必须 user 真终端跑；Claude 只做只读 GET 验证。
- **目标必需集（6 个，逐字）**：`branch-protection-config-self-check`、`codeowners-config-check`、`check-bootstrap-used-once`、`Mac Catalyst build-for-testing on macos-15`、`acceptance`、`collect`。
- **applier 与 rollback 均已对真 ruleset JSON 实测**（见 spec §应用 / §回滚）：输出仅 6 个 PUT 字段（剥离 `id/_links/created_at` 只读字段）、保留 `deletion/non_fast_forward/pull_request` 三 rule + `strict:false` + admin `bypass_actors`。
- **已知接受残留（codex 未 approve，user override）**：移除 3 smoke（openapi/schema/swift-contracts）留 pre-merge gap 到下一轮补回；缓解=3 者 `push:main` 无 paths 过滤仍跑。**不在本计划**：smoke always-post 重构、自检升级为真校验 ruleset、codex-review-verify 修复——全部紧邻下一轮治理。
- **提交纪律**：只 `git add` 明确列出的文件，绝不 `git add -A`（未跟踪的 `docs/superpowers/mockups/2026-06-29-topbar-distribution.html` 保持未跟踪）。

---

### Task 1: 应用 ruleset 编辑（user 真终端）+ 验证

**Files:** 无（仓库设置编辑，非文件）。

**Interfaces:**
- Consumes: spec §应用 的实测 applier。
- Produces: ruleset `15660830` 的 `required_status_checks` = 目标 6 个。

- [ ] **Step 1: user 真终端应用 applier**

user 在真实终端跑（Claude 的 `gh api PUT` 被封禁）：
```bash
RS=15660830; REPO=agateuu1234-bit/kline-trainer
gh api "repos/$REPO/rulesets/$RS" > /tmp/rs.json
jq '{
  name, target, enforcement, conditions, bypass_actors,
  rules: (.rules | map(
    if .type == "required_status_checks"
    then .parameters.required_status_checks = ([
      "branch-protection-config-self-check","codeowners-config-check","check-bootstrap-used-once",
      "Mac Catalyst build-for-testing on macos-15","acceptance","collect"
    ] | map({context: ., integration_id: 15368}))
    else . end
  ))
}' /tmp/rs.json > /tmp/rs-put.json
# 落库前肉眼复核 contexts 恰 6 个：
jq -r '.rules[]|select(.type=="required_status_checks").parameters.required_status_checks[].context' /tmp/rs-put.json
gh api --method PUT "repos/$REPO/rulesets/$RS" --input /tmp/rs-put.json
```
Expected: PUT 返回 200 + 更新后的 ruleset JSON；复核命令列出恰好 6 个 context。

- [ ] **Step 2: Claude 只读验证 ruleset 现为 6 个**

Run（Claude 可跑，只读）：
```bash
gh api repos/agateuu1234-bit/kline-trainer/rules/branches/main | \
  python3 -c "import json,sys; rs=json.load(sys.stdin); \
c=[x['parameters']['required_status_checks'] for x in rs if x['type']=='required_status_checks'][0]; \
names=sorted(k['context'] for k in c); \
exp=sorted(['branch-protection-config-self-check','codeowners-config-check','check-bootstrap-used-once','Mac Catalyst build-for-testing on macos-15','acceptance','collect']); \
print('实际:',names); print('OK' if names==exp else 'MISMATCH')"
```
Expected: `OK`（6 个 context 恰为目标集）。若 `MISMATCH`：user 用 spec §回滚 的 sanitized rollback 还原，排查后重试。

- [ ] **Step 3: 验证正常 PR 不再需 admin bypass**

本设计+计划文档的 PR（Task 2 建）本身就是「正常 PR」样本。应用 ruleset 编辑后，查它：
```bash
gh pr view <本 PR#> --json mergeable,mergeStateStatus --jq '{mergeable,mergeStateStatus}'
```
Expected: `mergeStateStatus` = `CLEAN`（非 `BLOCKED`）、`mergeable` = `MERGEABLE`——即 6 个必需 context 全 SUCCESS、无需 admin。
（注：若本 PR 在应用 ruleset 前就开，需 re-run 其 checks 或看最新状态。）

---

### Task 2: 审计留痕 PR（design + plan 文档）

**Files:**
- 已提交：`docs/superpowers/specs/2026-07-12-ruleset-required-checks-cleanup-design.md`
- 已提交：`docs/superpowers/plans/2026-07-12-ruleset-required-checks-cleanup.md`（本文件）

**Interfaces:**
- Consumes: 无。
- Produces: 记录本轮 ruleset 变更决策 + 实测 applier/rollback + 接受残留的可审计 PR。

- [ ] **Step 1: 整分支 codex 评审（含接受残留）**

`bash .claude/scripts/codex-attest.sh --scope branch-diff --head ci/ruleset-required-checks-cleanup --base origin/main`
Expected: 大概率仍 needs-attention 且**仅**剩 #1（smoke gap 设计分歧，已 user 接受）。若出现**新** finding → 处理；若仅 #1 → 接受残留、走 override 收口（不写「收敛」，如实记 codex 未 approve）。

- [ ] **Step 2: user 真终端 push + PR（Claude push/PR 被 guard 拦）**

顺序建议：**先应用 ruleset 编辑（Task 1）再开本 PR**，则本 PR 直接 CLEAN（顺带验证 Task 1 Step 3）。
```bash
# 若 skill-gate drift 累计 > 5，先真终端 .claude/scripts/ack-drift.sh
git push -u origin ci/ruleset-required-checks-cleanup
gh pr create --base main --head ci/ruleset-required-checks-cleanup \
  --title "ci: ruleset 必需检查清理 — 11→6，正常 PR 不再需 admin bypass" \
  --body-file <中文正文，Claude 提供>
```
Expected: PR 开出；本 PR 的必需检查全绿、CLEAN。

- [ ] **Step 3: 合并 + 确认 main**

若本 PR 因残留（codex 未 approve）或 attest ledger 缺失被拦，走 override/admin（user 真终端）。合后 `gh run watch` 确认 main 绿。

---

## Self-Review

**1. Spec coverage**：
- spec §目标必需集（6）→ Task 1 Step 1 applier 逐字一致 ✅
- spec §应用（实测 applier）→ Task 1 Step 1 ✅
- spec §验证（ruleset 显 6 + PR CLEAN）→ Task 1 Step 2/3 ✅
- spec §回滚（sanitized）→ Task 1 Step 2 失败分支引用 ✅
- spec §时限化风险接受（残留 #1 + 后续）→ Global Constraints + Task 2 Step 1 ✅
- spec §审计留痕（doc PR）→ Task 2 ✅

**2. Placeholder scan**：`<本 PR#>` / `<中文正文，Claude 提供>` 是执行期才知的运行值（PR 号、正文由 Claude 在 finishing 提供），非设计占位符；其余命令/context/SHA 均实际值。✅

**3. Type consistency**：目标 6 个 context 在 Global Constraints、Task 1 Step 1 applier、Task 1 Step 2 验证三处逐字一致。✅
