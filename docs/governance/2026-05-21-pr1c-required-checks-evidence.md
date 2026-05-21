# PR 1c — Required-checks admin execute 证据（redacted）

> 本文件记录 1c 对 origin `main` ruleset 执行 1b runbook 的 redacted 证据。
> 源脚本（未改动）：`scripts/governance/admin-configure-required-checks.sh` + `verify-required-checks.sh`。
> 所有 token 已由 runbook `redact()` 剥离（`$GH_TOKEN` 实值 + GitHub token 样式串）。

## 执行 meta
- plan 编写日期：2026-05-21；**实际执行日期：2026-05-22**
- 执行人：@agateuu1234-bit（仓库管理员，本机 `gh` admin scope）
- 仓库：`agateuu1234-bit/kline-trainer`（所有命令显式 `--repo` 固定）
- canonical safe invocation：所有 origin 命令带 `env -u REPO -u MOCK_FIXTURE -u MOCK_LOG -u MOCK_PUT_FAIL -u MOCK_LIST_ID GH_HOST=github.com GH_CMD="$GH_BIN"` + `--repo agateuu1234-bit/kline-trainer`（grounding #10：清 ambient env + 强制 host=github.com + pin gh 绝对路径，防对 fork/mock/错 host/PATH-wrapper 误跑）
- host/gh guard（**sanitized**，codex R10-F2：不记原始 auth/URL，origin URL 已 `sed` 剥 userinfo）：
  `GH_BIN=/opt/homebrew/bin/gh | host=github.com auth OK | origin fetch(sanitized)=https://github.com/agateuu1234-bit/kline-trainer.git | push(sanitized)=https://github.com/agateuu1234-bit/kline-trainer.git | guard OK`
- clean script-tree HEAD（grounding #12）：`9edb7c02efd96478ac03e810f60d52fde74de276`
- default_branch 断言（H8/H10 close 双谓词之一，codex R2-F2）：`default_branch=main` == `main` ✅（live 核实，补 assert 内部 `~DEFAULT_BRANCH` 不 live 之缺）
- 执行路径：**路径 A（no-op，零 mutation）**（grounding #11/#13；路径 B 不在 1c 执行 = fail-closed 退回 1b）

## 1. dry-run（确认幂等 no-op，未 mutate）
```
== [1] 发现 ruleset id ==
== [2] snapshot（GET#1：raw 供计算 + redacted 审计副本）==
== [3] preflight（对 raw snapshot，不额外 GET）==
OK: preflight（main branch ruleset + 绑默认分支 + active + 有 required_status_checks 规则 + bypass 仅 admin）
== [4] build 双 payload（从 raw snapshot）==
== [5] dry-run（不 mutate）==
diff（payload vs 当前 required_status_checks）:
  （无变更——已是 desired 状态，幂等 no-op）
dry-run 完成；加 --apply 才真改。artifact: /tmp/pr1c-artifacts
```
判定：**no-op（→ Path A）**。

## 2. 落实/确认
- 路径 A（no-op，本次执行路径）：**未跑 `--apply`、零 mutation**；仅 host guard + 独立 live assert（见 §3）。
- 路径 B（需变更）：本次未触发；若触发则 1c fail-closed 退回 1b 补 `--expected-payload-sha` + host pin 契约（grounding #13），不在 1c mutate。

## 3. 独立 live assert（H10 机器可检查谓词，权威断言）
命令：`env ... GH_HOST=github.com GH_CMD="$GH_BIN" ... verify-required-checks.sh --mode assert --repo agateuu1234-bit/kline-trainer`
```
OK: main branch ruleset + 绑默认分支 + active + 'Mac Catalyst build-for-testing on macos-15' 在位 + integration_id=15368 + bypass 仅 admin
退出码=0
```
退出码：`0`（host/gh guard 见 meta 的 sanitized 行）。
另：A-Step2 对**即将提交的同一份 snapshot** 做了 offline assert——`FINAL = no-op + assert(offline,绑定同一 snapshot) OK（gate 在位）`。

## 4. 完整 redacted snapshot（post-assert 最终态，绑定 sha256）
- 文件：`docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json`（取自**最后一次 assert 之后**的 fresh dry-run `/tmp/pr1c-final/ruleset-snapshot.json`，反映 origin 最终受保护状态，已剥 token——codex R2-F1；`cmp -s` + 双向 sha256 机器绑定）
- sha256：`2901c81f500bcf2270771398b75e68058ccb946f15f9d5cda2f93c1a0fd1e38e`
- 关键字段速览：
  - `name=main`、`target=branch`、`enforcement=active`
  - `conditions.ref_name.include=["~DEFAULT_BRANCH"]`、`exclude=[]`（绑默认分支）
  - `bypass_actors=[{actor_id:5, actor_type:RepositoryRole, bypass_mode:always}]`（仅 admin）
  - 规则类型：`deletion` / `non_fast_forward` / `pull_request` / `required_status_checks`
  - `required_status_checks`（11 条，全部 `integration_id=15368`）：`branch-protection-config-self-check`、`codeowners-config-check`、`codex-review-collect`、`codex-review-rerun`、`codex-review-verify`、`openapi-smoke`、`schema-smoke`、`swift-contracts-smoke`、`check-bootstrap-used-once`、`hardening_6_gate`、**`Mac Catalyst build-for-testing on macos-15`** ✅
