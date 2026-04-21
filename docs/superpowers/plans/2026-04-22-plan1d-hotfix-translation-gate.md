# Plan 1d Hotfix — M0.4 Translation Gate Repo 化

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 把 M0.4 AppError trust-boundary 翻译规则 gate 从 session-local memory 迁到 repo 内 governance doc，让下游 Plan 2/3 PR 有稳定引用锚。

**Architecture:** 新建 `docs/governance/m04-apperror-translation-gate.md`（内容从 memory `project_m04_translation_gate.md` 拷贝重排） + 更新 Plan 1d acceptance 脚本加一条 gate-doc-exists 断言 + 更新 memory 指向 repo 文件。

**Tech Stack:** Markdown only。无代码变更。

**brainstorming-skip 注记**（per memory `feedback_skill_pipeline_3_gaps.md`）：codex post-merge attest 于 2026-04-22 对 Plan 1d PR #26 给出 `needs-attention`，唯一 medium finding = "promised translation gate not in repo"。finding Recommendation 即本 plan 的 spec。无设计空间探索需要。

## Scope

- **In**：1 新 doc + 1 acceptance 脚本 1 行 grep + 1 memory 文件 2 行改写
- **Out**：不改 AppError.swift / AppErrorTests.swift（merged contract 冻结，无 finding 触及）；不改 hooks / CI / workflow-rules.json（非 trust-boundary）

## File Structure

- **Create**: `docs/governance/m04-apperror-translation-gate.md`（从 memory 拷贝，去 frontmatter，调结构）
- **Modify**: `scripts/acceptance/plan_1d_m0_4_apperror.sh`（加 2 条 grep：doc 存在 + 含 Gate 1/Gate 2 关键词）
- **Memory**（非 repo，最后一步手动更新）: `project_m04_translation_gate.md` 改为 `@see docs/governance/m04-apperror-translation-gate.md`

---

### Task 1：新建 repo 内 translation gate doc

**Files:**
- Create: `docs/governance/m04-apperror-translation-gate.md`

- [ ] **Step 1：写 doc 内容**

内容必须含以下锚点（供 Task 2 grep）：
- 标题行：`# M0.4 AppError Trust-Boundary Translation Gate`
- 两条 Gate 章节标题：`## Gate 1`、`## Gate 2`
- Plan 2/3 应用范围矩阵表
- 语言：中文（matches memory 与 project 惯例）

完整 doc 内容见 Task 1-Step 1 附录（略，subagent 参考 memory `project_m04_translation_gate.md` 全文 + 去 frontmatter + 首行加 `> **Source**: 本文档由 Plan 1d hotfix 落地；原 session-local memory 已指向此文件。`）。

- [ ] **Step 2：验证 doc 存在**

```bash
test -s docs/governance/m04-apperror-translation-gate.md && \
  grep -q '^# M0.4 AppError Trust-Boundary Translation Gate' docs/governance/m04-apperror-translation-gate.md && \
  grep -q '^## Gate 1' docs/governance/m04-apperror-translation-gate.md && \
  grep -q '^## Gate 2' docs/governance/m04-apperror-translation-gate.md && \
  echo "doc OK"
```
Expected: `doc OK`

- [ ] **Step 3：commit**

```bash
git add docs/governance/m04-apperror-translation-gate.md
git commit -m "docs(gov): add M0.4 AppError translation gate repo artifact

Addresses codex post-merge review on PR #26:
promised translation gate artifact migrated from session-local memory
to repo doc for stable downstream Plan 2/3 referencing.
"
```

---

### Task 2：acceptance 脚本加 gate-doc 断言

**Files:**
- Modify: `scripts/acceptance/plan_1d_m0_4_apperror.sh`（在 `# ---- AppError.swift 包含...` 块前插入）

- [ ] **Step 1：加 2 条 run 行**

在 acceptance 脚本 L31（`# ---- AppError.swift 包含...` 注释）**之前**插入：

```bash
# ---- M0.4 翻译规则 gate 文档存在 + 含 Gate 1/Gate 2 锚点 (hotfix 2026-04-22) ----
run "file: translation gate doc"     test -s docs/governance/m04-apperror-translation-gate.md
run "grep: Gate 1 + Gate 2 anchors"  bash -c "grep -q '^## Gate 1' docs/governance/m04-apperror-translation-gate.md && grep -q '^## Gate 2' docs/governance/m04-apperror-translation-gate.md"
```

- [ ] **Step 2：跑脚本验证绿**

```bash
./scripts/acceptance/plan_1d_m0_4_apperror.sh
```
Expected: 末尾 `Plan 1d (M0.4 AppError) acceptance: 8 passed, 0 failed` + `PLAN 1d PASS`（原 6 项 + 新 2 项）

- [ ] **Step 3：commit**

```bash
git add scripts/acceptance/plan_1d_m0_4_apperror.sh
git commit -m "test(plan-1d): enforce translation gate doc existence in acceptance

Adds 2 assertions guarding the M0.4 AppError translation gate artifact:
- doc file exists at docs/governance/m04-apperror-translation-gate.md
- doc contains Gate 1 + Gate 2 anchor headings
"
```

---

### Task 3：用户非 coder 验收清单

**非 coder 可执行 6 项验收**（per CLAUDE.md §2 + memory `feedback_skill_pipeline_3_gaps.md`）

- [ ] 验 1：`./scripts/acceptance/plan_1d_m0_4_apperror.sh` → 末尾 `8 passed, 0 failed` + `PLAN 1d PASS`
- [ ] 验 2：`cd ios/Contracts && swift test; echo exit=$?` → `exit=0`（contract 未动，regression 断言）
- [ ] 验 3：`gh pr checks <PR#>` → `All checks were successful`
- [ ] 验 4：`test -s docs/governance/m04-apperror-translation-gate.md && echo EXISTS` → `EXISTS`
- [ ] 验 5：`grep -cE '^## Gate 1|^## Gate 2' docs/governance/m04-apperror-translation-gate.md` → `2`
- [ ] 验 6：Plan 1/1b/1c acceptance 无 regression（三脚本都 PASS）

---

## 依赖（hard prereq）

- Plan 1d PR #26 已 merged（`995980f`）— 本 hotfix 基于 origin/main
- Memory `project_m04_translation_gate.md` 存在且含 Gate 1 + Gate 2 定义（拷贝源）

## 流程合规 checklist

- ✅ worktree：`.worktrees/plan-1d-hotfix/translation-gate`
- ✅ brainstorming-skip：codex finding = spec（本 plan §Scope 注记）
- ⏳ writing-plans：本文件
- ⏳ codex-attest on plan：待执行
- ⏳ subagent-driven 或 inline 执行
- ⏳ verification-before-completion：2 Task 完成后 invoke
- ⏳ requesting-code-review：PR 前 invoke
- ⏳ codex-attest on branch-diff pre-push
- ⏳ 用户非 coder 6 项验收 + PR 评论 evidence
- ⏳ 手动 merge

## 后续

merge 后更新 memory `project_m04_translation_gate.md`：frontmatter `description` 加 `（已迁 repo，见 docs/governance/m04-apperror-translation-gate.md）`；正文首行改为 `@see docs/governance/m04-apperror-translation-gate.md（repo 内为权威副本，本 memory 为 session-local 提醒）`。
