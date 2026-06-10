# 顺位 2 — app-build required-check post-merge admin runbook + evidence 模板

> 本文件是 **post-merge** 由仓库管理员对 origin `main` ruleset 执行的 runbook（把第 12 条 required check
> `iOS app build-for-running on macos-15` 加入 ruleset）+ redacted evidence 回填模板。
> 源脚本（本 PR 已泛化）：`scripts/governance/admin-configure-required-checks.sh` + `verify-required-checks.sh`
> + `build-protection-put-payload.py`（canonical `REQUIRED_CONTEXTS` = Catalyst + app-build）。
> 镜像先例：`docs/governance/2026-05-21-pr1c-required-checks-evidence.md`（1c 是 no-op；**本次是真实 mutation**）。

## 0. 前置时序硬约束（codex H1，关键 — 不可跳过）

加第 12 条 required context 后，**任何 head 推送早于「main 含 `.github/workflows/app-build.yml`」的 open PR**
（典型：与本锚真并行的 **顺位 1 RFC**，其 `docs/`-only 分支无该 workflow → 新 job 永不在其上运行 →
该 required check 永久停在「Expected — waiting for status」→ 非 admin 无法 merge）会被**卡死**。

故 `--apply` 只能在以下条件**之一**满足后执行：
1. 所有其它 in-flight PR 已 `rebase` 到含 `app-build.yml` 的 main（其分支上新 job 会运行报告）；**或**
2. 顺位 1 已先 merge（无并行 docs-only PR 悬空）。

这与 outline §二「一锚 merge，其余 worktree rebase onto main」纪律一致——本锚新增的仅是
「`--apply` 必须落在该 rebase 之后」这一时序点。admin bypass 可临时解卡，但不作正常路径。

## 1. canonical safe invocation（沿用 1c grounding #10）

所有 origin 命令带：
```
env -u REPO -u MOCK_FIXTURE -u MOCK_LOG -u MOCK_PUT_FAIL -u MOCK_LIST_ID \
  GH_HOST=github.com GH_CMD="$GH_BIN" \
  scripts/governance/admin-configure-required-checks.sh --repo agateuu1234-bit/kline-trainer ...
```
（清 ambient mock env + 强制 host=github.com + pin gh 绝对路径，防对 fork/mock/错 host 误跑。）

## 2. dry-run（确认是真实 mutation，非 no-op）

```
env ... admin-configure-required-checks.sh --repo agateuu1234-bit/kline-trainer
```
**预期**（与 1c 的 no-op 不同）：dry-run diff 显示
```
diff（payload vs 当前 required_status_checks）:
  + 新增 iOS app build-for-running on macos-15 (integration_id=15368)
```
判定：**真实 mutation（→ 需 --apply）**。若 dry-run 反而显示「无变更/no-op」，说明 ruleset 已含 app-build
（可能此前已配），则与 1c 同走 no-op + live assert，无需 PUT。

## 3. apply（PUT，加第 12 条）

```
env ... admin-configure-required-checks.sh --apply --artifact-dir <durable-dir> --repo agateuu1234-bit/kline-trainer
```
脚本内置 mutation safety：snapshot → preflight → build 双 payload → 乐观并发 re-read → PUT → post_put_classify
（保留不变量判成功；绝不自动 rollback；失败一律人工介入）。

## 4. post-apply 独立 assert（权威断言：两 context + 既有 11 check 不回归）

```
env ... verify-required-checks.sh --mode assert --repo agateuu1234-bit/kline-trainer
```
**预期**：
```
OK: main branch ruleset + 绑默认分支 + active + required contexts ['Mac Catalyst build-for-testing on macos-15', 'iOS app build-for-running on macos-15'] 全在位 + integration_id=15368 + bypass 仅 admin
退出码=0
```

## 5. evidence 回填（user 执行后补）

- 实际执行日期：`<TODO 执行后填>`
- 执行人：@agateuu1234-bit（仓库管理员，本机 `gh` admin scope）
- host/gh guard（sanitized）：`<TODO>`
- dry-run 判定：`<TODO：真实 mutation / no-op>`
- 执行路径：`<TODO：apply（PUT 1 次）/ no-op skip>`
- post-apply assert 退出码：`<TODO：0>`
- 完整 redacted snapshot（post-assert 最终态，sha256 机器绑定）：`<TODO 文件 + sha256>`
  - 关键字段速览：`required_status_checks` 应为 **12 条**，全 `integration_id=15368`，含
    `Mac Catalyst build-for-testing on macos-15` + **`iOS app build-for-running on macos-15`**。
