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

**⚠️ 关于 `branch-protection-config-self-check` 的诚实定性（codex spec R2 #3）**：它虽在目标必需集里，但**当前是个恒绿 no-op**——读古典 protection、404、`exit 0`，**并不校验活动 ruleset**。留它当必需是因为它每 PR 都 post SUCCESS、无害、不阻塞；但别把它当作能挡住「未来 ruleset 漂移或手误编辑」的真门（它挡不住）。**把它升级为查 rulesets API、不匹配即 fail** 是一项独立改进，列入下一轮治理（与 smoke 重构 + codex-verify 修复同批）。本轮不改它、仅如实记录其 no-op 性质。

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

GET 当前 ruleset → jq 只改 `required_status_checks` rule 的 contexts 数组、其余原样 → PUT 回（最小爆炸半径）。以下 jq 变换**已对真 ruleset JSON 实测**：输出仅含 `name/target/enforcement/conditions/bypass_actors/rules` 六个 PUT 相关顶层字段（剥离 `id/_links/created_at` 等只读字段）；`deletion/non_fast_forward/pull_request` 三条 rule 及 `strict_required_status_checks_policy:false`、admin `bypass_actors` 全保留；required contexts 恰为目标 6 个。

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
# 落库前肉眼复核 /tmp/rs-put.json 的 contexts 恰为 6 个：
jq -r '.rules[]|select(.type=="required_status_checks").parameters.required_status_checks[].context' /tmp/rs-put.json
gh api --method PUT "repos/$REPO/rulesets/$RS" --input /tmp/rs-put.json
```

（`integration_id: 15368` = GitHub Actions，本 ruleset 所有 context 皆用之。）

## 验证

1. `gh api repos/$REPO/rules/branches/main` → `required_status_checks` 恰为目标 6 个。
2. 下一个正常 PR（如本设计文档自己的 PR，若在应用后开）`mergeStateStatus` 应为 `CLEAN`（非 `BLOCKED`），无需 admin。
3. 6 个必需 context 在该 PR 上全 SUCCESS。

## 显式时限化风险接受 + 有界后续（codex spec R1 #1/#2 回应）

本轮从必需集移除 4 个 smoke/codex 检查，会在移除到「下一轮补回」之间留一段**受控 gap**。经 user 明确批准（2 次 AskUserQuestion），作为**时限化风险接受**记录如下：

| 移除项 | pre-merge gap | 缓解（现存，非新增） | 补回计划 |
|---|---|---|---|
| `openapi-smoke` / `schema-smoke` / `swift-contracts-smoke` | 碰 `backend/openapi.yaml`/`backend/sql/**`/`ios/Contracts/**`/`ios/KlineTrainer/**` 的 PR 不再被 smoke pre-merge 门拦 | **3 个 workflow 的 `push: branches:[main]` 无 paths 过滤 → 合并后在 main 上必跑**，回归会红 main（检测从 pre-merge 移到 post-merge，非「无检测」） | **紧邻下一轮治理**：仿 `hardening_6_gate` 把 3 个 workflow 改 always-post + short-circuit（无关时快速 SUCCESS、碰路径时跑真 smoke）+ 按 job **显示名**（`OpenAPI 3.0 spec + contract invariants` / `PostgreSQL 15 ephemeral deploy` / `SQLite training-set + app schemas` / `swift test on macos-15`）加回必需集。**须逐个验证 short-circuit 不静默放行**（否则比移除更糟）。swift-contracts 在 macos-15，always-run 有成本，单独评估。 |
| `codex-review-verify` | codex CI 判决门被禁用（但**本就 0 次真评审、零实际强制**——merge-base bug 致从未产 verdict，见上） | **本地 `codex-attest.sh` 仍在每次评审跑并写 ledger**（不可自证的那层在本地保留）；治理条款#1 的 CI 强制本就已失效，本轮不使其更坏 | **同下一轮**：修 `codex-review-verify.yml` line 132 去 `--depth=1`（拉全 base 祖先，`merge-base` 才算得出）+ ruleset 必需名改 `codex-verify-pass`（workflow 实际 post 的名，且 `branch-protection-config-self-check` 已硬编码期望此名）+ 决定 codex CI 判决是否硬阻断（配额脆弱性）。 |

**回滚（sanitized，已实测）**：**不能**直接 PUT 原始 `/tmp/rs.json`——它是 GET 原件、含 `id/_links/created_at` 等只读字段，PUT 可能被拒（codex spec R2 #2）。用与 applier 同骨架、contexts 换回原 11 个的 payload（已实测：输出仅 6 个 PUT 字段、11 context 与原始集合逐一相符）：

```bash
jq '{
  name, target, enforcement, conditions, bypass_actors,
  rules: (.rules | map(
    if .type == "required_status_checks"
    then .parameters.required_status_checks = ([
      "branch-protection-config-self-check","codeowners-config-check","codex-review-collect",
      "codex-review-rerun","codex-review-verify","openapi-smoke","schema-smoke",
      "swift-contracts-smoke","check-bootstrap-used-once","hardening_6_gate",
      "Mac Catalyst build-for-testing on macos-15"
    ] | map({context: ., integration_id: 15368}))
    else . end
  ))
}' /tmp/rs.json > /tmp/rs-rollback.json
gh api --method PUT "repos/$REPO/rulesets/$RS" --input /tmp/rs-rollback.json
```

## 其它非本轮目标

- **不动** 3 个 smoke workflow 的文件（本轮纯 ruleset 编辑；always-post 重构在下一轮）。
- **不加** `backend pytest (full suite)` 进必需集（PR #142 已明确不设必需）。

## 流程

治理/ruleset 变更：brainstorming（本文档）→ codex:adversarial-review（file scope）→ writing-plans（应用 + 验证）→ user 应用 ruleset 编辑 → 验证。ruleset 编辑本身是仓库设置、无文件 PR；本设计文档 = 审计留痕（走 PR + codex review）。
