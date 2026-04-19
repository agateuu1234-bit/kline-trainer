# gov-bootstrap-hardening-4 设计 spec

**Date:** 2026-04-19
**Status:** Draft（待 codex:adversarial-review 收敛）
**Scope:** H2-3 — branch-diff 真 review target SHA 的 diff（替代"codex 实际只审当前 checkout"的老行为）
**Out of scope:** H3-3 shell parser / G3 pipeline / subagent 强制 / CI rollup / CI reject / 集成测试 / Cellar 泛化 → hardening-5+

**Prereqs:**
- PR #17 `gov-bootstrap-hardening` (commit `56c8d31`)
- PR #18 `Plan 0a v3` (commit `5cd0402`)
- PR #19 `gov-bootstrap-hardening-2` (commit `e8b2558`)
- PR #20 `gov-bootstrap-hardening-3` (commit `dbc585e`)

---

## 1. 背景

hardening-1 时 `.claude/scripts/codex-attest.sh --scope branch-diff` 路径设计为："生成 target 分支 diff patch → 传给 codex-companion 审 patch"。实际 codex-companion CLI 不认 `--focus <patch>` 为"要审的内容"，只把它当 free-form text，review 目标由当前 cwd + HEAD 决定。

后果：**每次 hardening-N bootstrap（PR #18/#19/#20）都要 override ceremony 绕过 branch-diff attest**，因为：
- codex 实际审查当前 checkout（= hardening-N 分支本身，内容正确）
- 但 attest-attest 语义"为 branch:X@SHA 这个指纹背书"名实不符

H2-3 目的：让 `--scope branch-diff` 名实一致——codex 看到的**就是** target SHA 的 diff，ledger 写的指纹**就是**被审的内容。

## 2. 目标

- codex-attest.sh 在 `--scope branch-diff` 模式下：
  1. 冻结 `HEAD_SHA_FROZEN` = `git rev-parse $HEAD_BR`
  2. 创建临时 git worktree at `HEAD_SHA_FROZEN`
  3. 调 codex-companion 用 `--cwd <worktree>` 让 codex 在 worktree 里审
  4. 审完检查 `HEAD_BR` 没漂移（已有 H2-R2 race 防护保留）
  5. trap cleanup worktree
- 后果：branch-diff 真正对应 target SHA 的代码；不再需要 override ceremony 做分支级 attest 的"冒充"路径

## 3. 非目标（本 PR 显式不做）

- H3-3 shell parser heredoc 重做
- G3 skill pipeline 顺序强制
- subagent-driven 执行强制
- CI skill-gate drift rollup required check
- CI attest-override/ack-drift reject
- Hook 集成测试框架（用真实 codex-companion 的端到端）
- Homebrew Cellar allowlist 通用化

## 4. 架构

### 4.1 文件改动清单

| 类型 | 文件 | 改动 |
|---|---|---|
| 改动 script | `.claude/scripts/codex-attest.sh` | branch-diff 模式插入 worktree lifecycle；替换 `--focus <patch>` 为 `--cwd <worktree>` |
| 改动 test | `tests/hooks/test_codex_attest_ledger_write.py` | 加 2 测试：cross-checkout + worktree cleanup |

### 4.2 branch-diff 新流程（伪码）

```bash
if [ "$SCOPE" = "branch-diff" ]; then
    HEAD_SHA_FROZEN=$(git rev-parse "$HEAD_BR")
    # Create worktree at frozen SHA
    WORKTREE=$(mktemp -d -t codex-attest-wt.XXXXXX)
    # Cleanup on any exit (incl Ctrl+C / non-zero)
    trap 'git worktree remove --force "$WORKTREE" 2>/dev/null || true; rm -rf "$WORKTREE" 2>/dev/null || true' EXIT
    git worktree add --detach "$WORKTREE" "$HEAD_SHA_FROZEN" || {
        echo "[codex-attest] ERROR: cannot create worktree at $HEAD_SHA_FROZEN" >&2
        exit 14
    }
    # Invoke codex in the worktree; no --focus patch trick
    REVIEW_ARGS="--base $BASE --cwd $WORKTREE"
else
    REVIEW_ARGS="$FOCUS"
fi

# ... existing node invocation + verdict parse ...

# Post-review ref drift check (H2-R2 preserved)
if [ "$SCOPE" = "branch-diff" ]; then
    HEAD_SHA_AFTER=$(git rev-parse "$HEAD_BR")
    if [ "$HEAD_SHA_AFTER" != "$HEAD_SHA_FROZEN" ]; then
        echo "[codex-attest] ERROR: $HEAD_BR moved during review ($HEAD_SHA_FROZEN -> $HEAD_SHA_AFTER); ledger NOT updated" >&2
        exit 13
    fi
    # ... existing ledger_write_branch with frozen SHA + fingerprint ...
fi
```

**关键差异 vs hardening-1 版**：
- 不再 `git diff $BASE...$HEAD_BR > $TMP_PATCH` + `--focus $TMP_PATCH`
- 新增 `git worktree add --detach $WORKTREE $HEAD_SHA_FROZEN`
- 传 `--cwd $WORKTREE` 给 codex-companion
- trap 清 worktree（replace 原先清 patch 文件的 trap）

### 4.3 Worktree 路径选择

使用 `/tmp/codex-attest-wt.XXXXXX`（`mktemp -d` 随机后缀）。

理由：
- `/tmp` 不被 state catch-all deny (`Bash(*.claude/state*)`) 影响
- `mktemp` 保证并发安全（多个 attest 并行互不冲突）
- 系统会定期清理 `/tmp`，即使 trap 失败也有兜底
- **不**用 `.claude/state/worktrees/`——那会被 state 保护 deny 挡住 worktree 操作

### 4.4 Trap cleanup 语义

```bash
trap 'git worktree remove --force "$WORKTREE" 2>/dev/null || true; rm -rf "$WORKTREE" 2>/dev/null || true' EXIT
```

幂等；失败不抛错（trap 里抛错会 mask 原始 exit code）；双保险：
- `git worktree remove --force` 正常路径
- `rm -rf` 兜底（worktree metadata 损坏等情况）

### 4.5 失败路径

| 情况 | 行为 |
|---|---|
| `git worktree add` 失败 | exit 14 + stderr 含 "cannot create worktree at $HEAD_SHA_FROZEN"；无 ledger 写 |
| codex-companion crash / 非零退出 | trap 清 worktree；ledger 不更新；exit 非零 |
| verdict ≠ approve | trap 清 worktree；ledger 不更新；exit 7（现有逻辑）|
| HEAD_BR ref 漂移检测 | exit 13（现有 H2-R2 逻辑）+ worktree trap 清 |
| Worktree 目录已存在（mktemp 极罕见冲突）| 重试一次；仍失败 → exit 14 |

## 5. 测试策略

### 单元测试

`tests/hooks/test_codex_attest_ledger_write.py` 新增：

**TestWorktreeBranchReviewH23**：
- `test_branch_diff_reviews_target_sha_not_current_checkout`：
  1. Repo 在 main；创建 feature-X 分支；往 feature-X commit 特殊标记文件（e.g. `marker-only-in-feat-X.txt`）
  2. `git checkout main`（回到不含 marker 的分支）
  3. 用 stubbed node（检查 `--cwd` 参数指向的目录里**有** marker 文件 → echo approve；否则 needs-attention）跑 `codex-attest --scope branch-diff --base origin/main --head feature-X`
  4. 断言：stub 看到 marker（证明 cwd 是 worktree at feature-X 不是当前 main）+ ledger 写入 `branch:feature-X@<feat-sha>`
- `test_worktree_cleaned_on_success`：
  1. 跑成功一次 attest
  2. 断言：`/tmp/codex-attest-wt.*` 没有残留（`find` 结果为空或只含其他 PID 的）
- `test_worktree_cleaned_on_failure`：
  1. Stub node 返回 needs-attention verdict（exit 7 路径）
  2. 断言：ledger 无新条目 + worktree 已清理
- `test_ref_drift_during_review_aborts`：
  1. 用一个 stub node 在"review 中间"修改 target branch（advance ref）
  2. 断言：script exit 13 + stderr 含 "moved during review" + ledger 无条目 + worktree 清理

## 6. 非 coder 验收清单

（中文；action / expected / pass_fail）

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | 在 main 分支跑 `.claude/scripts/codex-attest.sh --scope branch-diff --base origin/main --head gov-bootstrap-hardening-4` | codex 看到 hardening-4 分支内容（含本 PR 改动），不是 main | codex 输出引用本 PR 的改动 = PASS |
| 2 | 脚本退出后查 `ls /tmp/codex-attest-wt.* 2>/dev/null \| wc -l` | 0（或只有并发其他脚本的）| 无残留 = PASS |
| 3 | review 期间手工 `git commit --allow-empty` 到 target branch | ledger 不写；stderr 含 "moved during review" | abort 行为 = PASS |
| 4 | `python3 -m pytest tests/hooks/ -q` | 105 + 4 新 = 109 passing | all green = PASS |
| 5 | 下次 Plan-level bootstrap PR（如 hardening-5）`--scope branch-diff` 跑得出 approve | 不再需要 override ceremony | 无 override log = PASS |

## 7. 依赖与边界

- 依赖：hardening-3 merged on main（H3-1 guard-env-read 不影响 worktree 操作；H3-2 drift ceiling 依旧 live）
- 依赖：`git worktree` 命令（Git 2.5+，macOS / Linux 通用）
- 不依赖：新外部工具 / OpenAI API 版本变化
- 副作用：本 PR 后，所有 branch-diff attest 会多一次 worktree create/remove（~1-3s），但本来是非 hot-path

## 8. codex 收敛预期

基于历史：
- hardening-3 spec 1 轮 / plan 1 轮 / branch-diff 3 轮（1 轮 drop H3-3）
- hardening-2 spec 2 轮 / plan 2 轮 / branch-diff 3 轮 drop-by-override
- hardening-1 spec 6 轮 / plan 2 轮 / branch-diff 未过（全 override）

本 PR 最窄（1 script 1 test 文件）。hardening-3 drop H3-3 后 attack surface 显著缩小。估 spec 1 轮 / plan 1 轮 / branch-diff **1-2 轮收敛**（首次有望真接近 approve — 因为 H2-3 就是要让 branch-diff attest 真生效）。

## 9. Round-by-round responses

（空；待 codex 评审后填）
