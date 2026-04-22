# Chore — `.gitignore` `.worktrees/` Implementation Plan

> **For agentic workers:** Single-commit chore PR. Uses cherry-pick from a local-only commit.

**Goal:** 把 `.worktrees/` 加入 `.gitignore`，防止未来 worktree 设置时误 `git add .` 污染主分支。

**Architecture:** 纯 `.gitignore` 追加 3 行（空行 + 注释 + pattern）。commit 已由 `superpowers:using-git-worktrees` skill 在 Plan 1d 开 worktree 前本地创建（`dfcb55e`），未 push；本 PR 走正规流程上传。

**Tech Stack:** `.gitignore` only。无代码、无测试、无 CI 变化。

**brainstorming-skip 注记**（per memory `feedback_skill_pipeline_3_gaps.md`）：spec = "把 `.worktrees/` 加入 `.gitignore`"，1 行 pattern，无设计空间。

## Scope

- **In**：cherry-pick `dfcb55e` → `f995f28`（3 行 `.gitignore` 追加）
- **Out**：不加 `.claude/state/*` 或其他隐私/lock 文件（已由 hardening-3 覆盖）；不改 worktrees skill 的默认路径（`.worktrees/` 是 skill 既定默认）

## File Structure

- **Modify**: `.gitignore`（尾部追加 3 行：空行 + `# Git worktrees...` 注释 + `.worktrees/`）

## Task 1：cherry-pick 验收

**Files:**
- Modify: `.gitignore`（+3 行 @ 尾部）

- [x] **Step 1**：worktree 建好 + cherry-pick 已完成（HEAD=`f995f28`）

- [ ] **Step 2**：本地 regression——Plan 1/1b/1c/1d 四条 acceptance 脚本全 PASS

```bash
./scripts/acceptance/plan_1_m0_1_db_schema.sh 2>&1 | tail -2
./scripts/acceptance/plan_1b_m0_2_rest_api.sh 2>&1 | tail -2
./scripts/acceptance/plan_1c_m0_3_swift_contracts.sh 2>&1 | tail -2
./scripts/acceptance/plan_1d_m0_4_apperror.sh 2>&1 | tail -2
```
Expected: 各脚本末尾 `PLAN N PASS`

- [ ] **Step 3**：`git check-ignore` 证实 `.worktrees/` 被忽略

```bash
git check-ignore -v .worktrees/foo && echo "IGNORED"
```
Expected: `.gitignore:<line>:.worktrees/<tab>.worktrees/foo` + `IGNORED`

- [ ] **Step 4**：commit 本 plan 文档（cherry-pick commit 已在 HEAD）

```bash
git add docs/superpowers/plans/2026-04-22-chore-gitignore-worktrees.md
git commit -m "plan(chore): gitignore .worktrees/ upstream"
```

## Task 2：用户非 coder 验收清单

- [ ] 验 1：Plan 1d acceptance 仍 PASS（`./scripts/acceptance/plan_1d_m0_4_apperror.sh` → `PLAN 1d PASS`）
- [ ] 验 2：`git check-ignore -v .worktrees/foo` → `.gitignore:<line>:.worktrees/<tab>...` + exit 0
- [ ] 验 3：`gh pr checks <PR#>` → `All checks were successful`
- [ ] 验 4：`grep -c '^\.worktrees/$' .gitignore` → `1`
- [ ] 验 5：`swift test` exit=0（contract 未动）
- [ ] 验 6：Plan 1/1b/1c regression 三条脚本 PASS

## 依赖（hard prereq）

- Plan 1d hotfix PR #27 已 merged（origin/main `3af65c0`）
- 本地 commit `dfcb55e` 真实存在（Plan 1d worktree 开启前的本地 setup）

## 流程合规 checklist

- ✅ worktree：`.worktrees/chore/gitignore-worktrees`
- ✅ brainstorming-skip：spec = "gitignore `.worktrees/`"（无设计空间）
- ✅ writing-plans：本文件
- ⏳ codex-attest branch-diff：3 行 .gitignore diff + 本 plan 文档
- ⏳ 用户非 coder 6 项验收 + PR 评论 evidence
- ⏳ 手动 merge
