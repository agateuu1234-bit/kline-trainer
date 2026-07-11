# Ruleset 必需检查清理 — 设计

**日期**：2026-07-12
**类型**：治理 / ruleset 变更（GitHub 仓库设置，非文件改动）
**分支**：`ci/ruleset-required-checks-cleanup`（base = `main` @ `7bde8d5`）
**范围**：本轮只清理 ruleset 必需检查，让正常 PR 不再需要 admin bypass。**不修** codex-review-verify 本体（推迟下一轮）。

## 问题

main 的合并闸门在 **ruleset `15660830`**（`gh api repos/agateuu1234-bit/kline-trainer/rules/branches/main`），`required_status_checks` 列 **11 个 context**。GitHub 按 **check-run 名（= job 名）精确匹配**。对照一个正常 PR（#142）GitHub 自己算的 `statusCheckRollup`，**11 个里只有 4 个真被满足** → 其余 7 个恒 pending → `mergeStateStatus: BLOCKED` → **每个 PR 都必须 `gh pr merge --admin`**（#140/#141/#142 皆然）。

7 个未满足的必需 context，分三类：

| context | 类别 | 实况 |
|---|---|---|
| `codex-review-collect` | **名字错** | workflow 名；job/check 实际叫 `collect`（每 PR 都 post SUCCESS） |
| `hardening_6_gate` | **名字错** | workflow 名；job/check 实际叫 `acceptance`（每 PR 都 post SUCCESS） |
| `openapi-smoke` | paths 过滤 | 只在碰 `backend/openapi.yaml` 等时跑；正常 PR 不 post |
| `schema-smoke` | paths 过滤 | 只在碰 `backend/sql/**` 等时跑 |
| `swift-contracts-smoke` | paths 过滤 | 只在碰 `ios/Contracts/**` 等时跑 |
| `codex-review-rerun` | 评论触发 | 只在 PR 评论 `/codex-review` 时跑；正常 PR 不 post |
| `codex-review-verify` | **坏 + 名字错** | ① `git fetch <base> --depth=1` 致 `merge-base` 失败、codex 从不产 verdict；② 就算修好也 post `codex-verify-pass` 非 `codex-review-verify`。修复推迟下一轮。 |

依据（`branch-protection-config-self-check.yml` 自证）：该自检的期望必需名硬编码为 **`codex-verify-pass`**（非 `codex-review-verify`）——佐证 codex 闸门的必需名从一开始就写错。且该自检读**古典** branch protection API（本仓用 ruleset，古典返 404）→ 恒 `exit 0`、**不校验 ruleset**，故改 ruleset 不会弄坏它，也无「提交在仓库的 ruleset 配置源」需同步。

## 目标必需集（6 个）

改 ruleset `15660830` 的 `required_status_checks` 为：

```
branch-protection-config-self-check
codeowners-config-check
check-bootstrap-used-once
Mac Catalyst build-for-testing on macos-15
acceptance          ← 由 hardening_6_gate 改名
collect             ← 由 codex-review-collect 改名
```

- **保留**（名字对、每 PR post SUCCESS、真门）：前 4 个。
- **改名**（真门，只是 ruleset 写了 workflow 名、应写 job 名）：`hardening_6_gate`→`acceptance`、`codex-review-collect`→`collect`。二者均已确认无 paths 过滤（`hardening_6_gate.yml` 顶部注释 v28 R28 F3 明确「为当必需检查而删除 paths 过滤」）、每 PR 都 post。
- **移除**（正常 PR 上永不上报）：`openapi-smoke`/`schema-smoke`/`swift-contracts-smoke`/`codex-review-rerun`/`codex-review-verify`。

**效果**：6 个必需 context 在正常 PR 上全 post SUCCESS → 不再需要 admin bypass；同时保留配置自检、CODEOWNERS、bootstrap-once、Catalyst 构建、hardening-6 验收、codex 流水线启动这 6 道真门的强制。

## 应用（user 真终端；`gh api PUT` 对 Claude 封禁）

用脚本 GET 当前 ruleset → 只改 `required_status_checks` rule 的 contexts → PUT 回（最小爆炸半径，不动 deletion/non_fast_forward/pull_request 等其它 rule）。脚本随实施提供；核心：

```bash
RS=15660830; REPO=agateuu1234-bit/kline-trainer
gh api "repos/$REPO/rulesets/$RS" > /tmp/rs.json
# 用 jq 把 required_status_checks rule 的 required_status_checks 数组替换为目标 6 个
#（保留每项的 integration_id: 15368）
jq '(.rules[] | select(.type=="required_status_checks").parameters.required_status_checks) |=
    [ "branch-protection-config-self-check","codeowners-config-check","check-bootstrap-used-once",
      "Mac Catalyst build-for-testing on macos-15","acceptance","collect" ]
    | map({context: ., integration_id: 15368})' /tmp/rs.json > /tmp/rs-new.json
# PUT 回需要 name/target/enforcement/conditions/rules 顶层字段（从 GET 结果保留）
gh api --method PUT "repos/$REPO/rulesets/$RS" --input /tmp/rs-put.json
```

## 验证

1. `gh api repos/$REPO/rules/branches/main` → `required_status_checks` 恰为目标 6 个。
2. 下一个正常 PR（如本设计文档自己的 PR，若在应用后开）`mergeStateStatus` 应为 `CLEAN`（非 `BLOCKED`），无需 admin。
3. 6 个必需 context 在该 PR 上全 SUCCESS。

## 推迟到下一轮（明确非本轮目标）

- **修复 codex 评审闸门**：① `codex-review-verify.yml` line 132 `git fetch origin <base> --depth=1` → 去掉 `--depth=1`（拉全 base 祖先，`merge-base` 才能算）；② ruleset 必需名 `codex-verify-pass`（workflow 实际 post 的名）加回必需集；③ 涉及策略决定：codex CI 判决硬阻断 PR（配额脆弱性）——单独 brainstorming。
- **不动** 3 个 paths-filtered workflow 的文件（本轮只从必需列表移除；未来若要它们当必需，须仿 `hardening_6_gate` 删 paths 过滤 + 加 short-circuit）。
- **不加** `backend pytest (full suite)` 进必需集（PR #142 已明确不设必需）。

## 流程

治理/ruleset 变更：brainstorming（本文档）→ codex:adversarial-review（file scope）→ writing-plans（应用 + 验证）→ user 应用 ruleset 编辑 → 验证。ruleset 编辑本身是仓库设置、无文件 PR；本设计文档 = 审计留痕（走 PR + codex review）。
