---
phase_delivery: true
phase_delivery_note: governance/infrastructure plan → acceptance = mechanism verification（脚本机制可复现 + verify 谓词 + 全部 mutation safety contract 测过），非业务功能验收
anchor: Wave 1 顺位 1b
source_outline: docs/superpowers/specs/2026-05-19-wave1-outline-design.md（§二 1b 行 + §3.3）
ledger: docs/governance/2026-05-17-wave0-signoff-ledger.md（H8 / H10）
---

# Wave 1 顺位 1b — Required-checks 治理脚本 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐 task 实施本 plan。步骤用 checkbox（`- [ ]`）追踪。

**Goal:** Ship 可复现 / 幂等 / 机器可检查的治理工具（builder + 三模式 verifier + admin runbook），用于管理 `main` 分支 ruleset 的 required status checks——确保 Catalyst check 绑定 GitHub Actions app（`integration_id=15368`），并附带全部 mutation safety 契约（artifact schema / redaction / rollback / serialization / idempotency / preflight / failure-mode），全部 against fixtures 测过，**不动 origin**。

**Architecture:** 三个 `scripts/governance/` 脚本——`build-protection-put-payload.py`（纯函数：ruleset GET JSON → 幂等 PUT payload，确定性序列化，无网络）；`verify-required-checks.sh`（三模式 preflight/assert/diff，源真相 = Rulesets API）；`admin-configure-required-checks.sh`（1c 执行的 runbook：preflight → snapshot → build → PUT → assert → rollback-on-failure，缺省 dry-run）。测试经 `tests/scripts/governance/`：fixtures + mock `gh` shim 注入，零网络零 origin mutation。单命令入口 `run-all.sh`。

**Tech Stack:** Python 3.11（仅 stdlib `json`/`argparse`）、Bash（`set -euo pipefail`）、`gh` CLI（生产；测试用 mock）、pytest（对齐 `tests/hooks/`）、bash 测试脚本（对齐 `tests/scripts/`）。

---

## 关键 grounding（写 plan 前已 grep-first 核实，2026-05-20）

1. **源真相 = Rulesets API，不是 legacy branch-protection。** `gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection` 返回 **404 "Branch not protected"**；`main` 的保护规则全在 ruleset（`gh api .../rulesets` → `id=15660830 name=main target=branch enforcement=active`）。
2. **Catalyst check 当前已在该 ruleset 内**：`required_status_checks` 规则的 `parameters.required_status_checks` 数组含 `{"context": "Mac Catalyst build-for-testing on macos-15", "integration_id": 15368}`。因此 1c 将来跑 apply 是**幂等 no-op**（最安全首跑）；但 rollback / preflight / failure-mode 仍需用 fixture 在 1b 测全。
3. **ledger H10 的验证命令 stale**：H10 写的是 `gh api .../branches/main/protection --jq '.required_status_checks.checks[] | ... .app_id==15368'`——指向 legacy protection API（会 404）+ legacy 字段 `.app_id`。Rulesets API 用 `integration_id`（不是 `app_id`）。**1b 把工具做对（读 rulesets + `integration_id`）+ 在本 plan / acceptance 记录该 finding；ledger 文字修正归 1c（H10 close），1b 不动 `docs/governance/`。**
4. **既有 ruleset 字段形状**（builder 规范化的依据）：GET 返回 `{id,node_id,name,target,source,source_type,enforcement,conditions,rules,bypass_actors,created_at,updated_at,_links,...}`；PUT 只接受 `{name,target,enforcement,conditions,rules,bypass_actors}`（其余只读字段必须剥离）。`required_status_checks` 规则形如 `{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":false,"required_status_checks":[{"context":...,"integration_id":15368},...]}}`。
5. **测试基建**：python → pytest（`tests/hooks/test_*.py` 先例）；bash → `.sh`（`tests/scripts/test-codex-attest.sh` 先例）。无既有 bats。
6. **scope 守约**：3 子项（3 脚本）/ prod ≈ 400 行（≤500，per `feedback_planner_packaging_bias`）；测试/fixtures/mock 不计 prod 行；**不动 `.github/workflows/`**（user 2026-05-20 选项：本地脚本 + verify 作机器可检查证据，符合 governance budget cap）。
7. **codex plan-stage R1 两个 high finding 的设计决策**（已并入 Task 1/3）：
   - **rollback 形状（R1-F1）**：rollback **不能**用 raw GET snapshot 当 PUT payload——raw GET 含只读字段（`id/node_id/_links/source/source_type/created_at/updated_at`），GitHub PUT 会 422 拒绝，恰好在 post-assert 失败最需要 rollback 时挂掉。修：builder 加 `--normalize-only`（只剥离只读字段、不动 check，忠实复制原状态）生成 `rollback-payload.json`；rollback PUT 用它而非 raw snapshot。mock PUT **拒绝含只读字段的 payload**（模拟 GitHub 422）→ 测试能抓到原 bug。
   - **乐观并发（R1-F2，best-effort）**：snapshot→PUT 之间他人改 ruleset 会被 stale 覆盖。修：runbook 在 PUT **前** re-read 一次 ruleset，规范化（`--normalize-only`，剥离 `updated_at` 等易变字段避免假阳性）后与 snapshot 规范化比对；不一致即 **abort（不 mutate）**。mock 支持 `MOCK_FIXTURE_N<k>` 在第 k 次单 GET 返回 drift fixture → 专门 race 测试。不依赖 ETag/If-Match（rulesets PUT 是否支持条件请求不确定；re-read 比对全平台可靠）。
8. **codex plan-stage R2 四个 finding 的处理**（已并入 Task 0/3）：
   - **no-op apply skip（R2-F1，high）**：apply 前比对 `payload.json` 与 `rollback-payload.json`；相同 = 已合规 → **skip PUT**，只跑 live assert + 写 evidence（避免无谓 governance mutation / audit 噪音）。with-check apply 测试改断言**无 PUT**。
   - **PUT 失败状态歧义（R2-F2，high）**：PUT 非零（超时 / 5xx / 断连，可能 GitHub 已 apply）后**不能**假设无 mutation。修：PUT 失败 → re-read 一次 → normalize 比对：== desired → 视为已 apply，offline assert 该 re-read + 写 evidence（exit 0）；== 原状态 → 干净失败无 mutation（exit 1）；其它 → 尝试 rollback + 显式 manual-intervention（exit 1）。mock 用 `MOCK_PUT_FAIL` + `MOCK_FIXTURE_N<k>` 模拟"PUT 报错但状态已变"。
   - **TOCTOU 残留（R2-F3，medium）→ 接受为文档化 residual**：re-read→PUT 之间仍有窗口；非原子。**接受理由**：单管理员内网仓（per `feedback_branch_protection_single_dev`，无并发管理员）+ 1c 由 admin 手动单次执行 + GitHub Rulesets PUT 是否支持 If-Match/ETag 条件请求未经证实（不凭空声称）+ 分布式锁 = overkill（YAGNI + `feedback_governance_budget_cap`）。codex R2-F3 明确接受"at minimum document the residual race"。本 plan 文档化 + acceptance 标注；不实现 ETag/lock。
   - **redaction 源污染（R2-F4，medium）**：snapshot 经 `redact()` 后又被当 builder 输入——若 ruleset 合法值含 token 样子的子串（如某 context 名）会被 redact 误改、PUT 回去即损坏 ruleset。修：raw snapshot 存临时文件（chmod 600，trap 清理，**不进 durable artifact-dir**）供 builder/rollback/re-read 计算；durable artifact-dir 只放 redacted 副本（audit）+ `rollback-payload.json`（功能性原状态，ruleset config 无 secret，需 unredacted 才能正确 PUT 回滚）。`ruleset-tokenish.json` fixture + 测试断言 `payload.json` 保留 token 样 context。
9. **codex plan-stage R3 三个 finding 的处理**（已并入 Task 0/2/3）：
   - **观测失败误 rollback（R3-F1，high）**：post-PUT live assert 的 exit 1（谓词假）与读/传输失败不能混。修：verifier **exit code 分层**（0 pass / 1 谓词假 / 2 用法 / 3 观测失败）；runbook post-PUT：arc==3（观测失败）→ **不 rollback**，人工确认；arc==1（谓词假）→ **rollback 前再 re-read** 确认仍假（若 race 已被他人修复则不 rollback）。测试 11（注入 malformed → exit 3 → 不 rollback）+ 测试 6（re-read 确认后 rollback）。
   - **mock 不证明 PUT 改了状态（R3-F2，high）**：mock 改为**有状态**（成功 PUT 校验+持久化提交 payload，后续 GET 返回它）；测试 3 断言 `mock.state == payload.json`（PUT body 即提交内容）+ `恰一条 Catalyst+integration_id 15368`。
   - **offline verifier 认证错 ruleset（R3-F3，medium）**：preflight/assert **离线也强制** `target==branch` + `name==main`（防 tag/非 main ruleset 误作 H10 证据）；加 `ruleset-tag.json` / `ruleset-wrongname.json` negative fixture + verifier 测试。
10. **codex plan-stage R4 两个 finding 的处理**（已并入 Task 3）：
   - **自动 rollback 覆盖并发合法改动（R4-F1，high）**：**取消自动 rollback**。post-mutation（PUT 成功或非零都一样）走统一 `post_put_classify`：re-read → 对其跑 `verify assert`（谓词检查，非字节比对）：满足→成功（含并发追加的无关 rule，测试 6a）；==原状态→PUT 未生效；未知/部分→**人工介入不自动 PUT rollback**（测试 6b），`rollback-payload.json` 仅作手动还原 artifact。观测失败→人工介入（测试 11）。
   - **PUT stderr 原始落 durable（R4-F2，medium）**：原始 stderr 只写 chmod-600 临时 `RAW_PUT_ERR`（trap 清理）；durable artifact 只放 `redact()` 后的 `put-error.txt`。测试 12（PUT-fail stderr 带 token → artifact 无 token）。
11. **codex plan-stage R5 一个 finding 的处理**（已并入 Task 0/2/3）：
   - **非 active ruleset 被部分 mutate（R5-F1，high）**：preflight 原先只查 name/target/有 rsc 规则，`enforcement==active` 拖到 assert——若 ruleset 漂移成 evaluate/disabled，preflight 放行→PUT 改 checks→assert 必败→分类器判未知不 rollback→ruleset 被改但 gate 仍不生效。修：**enforcement==active 提到 preflight 即 fail-closed**（name/target 之后、build/PUT 之前）；非 active → 不 mutate。加 `ruleset-inactive.json` fixture + verifier 测试（preflight/assert inactive→1）+ runbook 测试 8b（inactive→1 无 PUT）。
12. **codex plan-stage R6 两个 finding 的处理**（已并入 Task 0/2/3；user 选项 1 决议）：
   - **verifier 没校验 conditions 真绑 main（R6-F1，high）**：光 name=main/target=branch 不够——branch ruleset 可 ref 指向别处或排除 main。修：preflight/assert 加 `conditions.ref_name.include` 须含 `~DEFAULT_BRANCH`/`refs/heads/main`/`main` 且 `exclude` 不命中 main，否则 fail-closed。加 `ruleset-wrong-include.json` / `ruleset-exclude-main.json` negative + verifier 测试。live discovery 选出的唯一 name=main/target=branch ruleset 仍经 preflight 的 conditions 检查（fail-closed，不 mutate）。
   - **post-PUT 只看 Catalyst 谓词、放过保护流失（R6-F2，high）**：full-ruleset PUT 若把 `deletion`/`non_fast_forward`/`pull_request`/bypass/别的 check 改没但 Catalyst 还在，旧分类器 assert 通过 → 静默削弱保护还报绿。修：**post_put_classify 成功判据改为「保留不变量」`preservation_ok(payload, reread)`**——按集合判 `desired ⊆ actual`（name/target/enforcement/conditions 不可变；rule 类型 / required checks 不得缺失，**容许额外追加**；bypass actors 见 R7-F1 改精确相等）。少任何一个目标保护元素 = 不成功 → 人工介入不自动 rollback。同时满足 R4-F1（并发合法追加→成功、偏离不 clobber）与 R6-F2（保护流失→不报成功）；按集合比也稳健于 GitHub 服务端规范化/排序（不依赖字节相等）。加 `ruleset-missing-rule.json` fixture + 测试 6a（合法追加→0）/ 6b（无 Catalyst 未知→1）/ 6c（Catalyst 在但少 deletion 规则→1）。
13. **codex plan-stage R7 三个 finding 的处理 + plan-stage codex 收口**（user 选项 1：第 7 轮再冒新 high → 修干净的、residual 脆弱的，plan-stage codex 在此收口；实施后 branch-diff codex 为第二道背靠）：
   - **preservation 容许新增 bypass actor（R7-F1，high）→ 修**：新增任何 bypass actor 都会架空 required check（trust-boundary 洞）。`preservation_ok` 的 bypass 由 `<=` 改 **`!=` 精确相等**。加 `ruleset-extra-bypass.json` fixture + 测试 6d（多 bypass→人工 exit 1）。
   - **conditions 漏通配排除 main（R7-F2，high）→ 修**：`_binds_main` 只认精确 token，漏 `refs/heads/*` / `*` 等通配 exclude。改用 **GitHub 兼容通配语义**（`fnmatch` 对 `refs/heads/main`+`main`，外加 `~DEFAULT_BRANCH`/`~ALL`）判 include/exclude 是否命中 main。加 `ruleset-wildcard-exclude.json` fixture + verifier 测试。
   - **preservation 非 rsc 规则只比 type、漏 param 削弱（R7-F3，medium）→ 已实施**：branch-diff codex R3 重新提出此 finding；user 决策关闭此 gap（conservative-fail 方向可接受，与 I1 conditions 精确相等同类）。实施方式：非 rsc 规则改为**整对象 canonical 比对**（`json.dumps(sort_keys=True)` 集合子集，catch param 漂移/删除，容许追加）；rsc 的 `strict_required_status_checks_policy` / `do_not_enforce_on_create` policy 字段**精确保留**。新增 fixture `ruleset-weakened-policy.json`（R7-F3 negative：`do_not_enforce_on_create=true` 削弱）+ 测试 6e（param 削弱 → 人工介入 exit 1）。6a（并发合法追加 extra check，同 non-rsc rules + same policy）仍 exit 0 确认无 false-negative。
   - **最终 code-review I1（非 blocker）**：preservation 的 conditions 精确相等理论上可能因 GitHub round-trip 规范化保守误报；失败方向安全（不静默削弱）；1c real-apply 前再评估，rollback-payload.json 为权威还原源。
14. **branch-diff codex（实施后第二道）finding**：
   - **assert 不查 bypass_actors（high）→ 修**：preflight/assert 原本只查 name/target/enforcement/conditions + Catalyst check，未查 bypass——预存的非 admin bypass actor 能绕过 required check 却仍输出 GATE PASS（假 H10 证据）。修：preflight/assert 加 **admin-only bypass 校验**（镜像 `verify-freeze-tag.sh`：`OrganizationAdmin` 或 `RepositoryRole`+`actor_id=5`），含非 admin → fail-closed exit 1。加 verifier negative（assert/preflight extra-bypass→1）+ runbook 8c（snapshot 非 admin bypass → preflight fail-closed 无 PUT）。
   - **run-all 在 codex sandbox exit 1 = 误报**：codex 的 `/bin/zsh -lc` shell 缺 pytest；fresh worktree at HEAD 复现为 `pytest 8.4.2` 在 + `ALL GREEN` exit 0。非代码 bug；用户/CI 环境 pytest 在。
   - **R7-F3 param 削弱 branch-diff R3 重提 → 实施**：branch-diff codex R3 重新提出 R7-F3（preservation 非 rsc 规则整对象 + rsc policy 字段精确）；user 决策由 residual 改为实施（conservative-fail 方向可接受）。非 rsc 规则整对象 canonical 比对 + rsc policy exact。新增 `ruleset-weakened-policy.json` fixture + 测试 6e。6a 验证无 false-negative。residual 条目在 grounding #13 更新为已实施。

---

## File Structure

| 文件 | 类型 | 责任 |
|---|---|---|
| `scripts/governance/build-protection-put-payload.py` | prod (新建) | 纯函数：ruleset GET JSON → 幂等规范化 PUT payload；确定性序列化；无网络 |
| `scripts/governance/verify-required-checks.sh` | prod (新建) | 三模式校验（preflight/assert/diff）；源真相 rulesets API；离线可注入 `--ruleset-json` |
| `scripts/governance/admin-configure-required-checks.sh` | prod (新建) | 1c runbook：preflight→snapshot→build→PUT→assert→rollback；缺省 dry-run；`GH_CMD` 可注入 mock |
| `tests/scripts/governance/test_build_payload.py` | test (新建) | builder pytest：happy/idempotency/serialization/schema/redaction/fail-closed |
| `tests/scripts/governance/test-verify-required-checks.sh` | test (新建) | verifier 三模式 + failure-mode against fixtures |
| `tests/scripts/governance/test-admin-runbook.sh` | test (新建) | runbook：dry-run / apply / rollback / redaction / preflight-fail / put-fail（mock gh） |
| `tests/scripts/governance/mockgh.sh` | test (新建) | mock `gh` shim：list/get/put 按 fixture + env 模拟成败，记录调用日志 |
| `tests/scripts/governance/fixtures/*.json` | test (新建) | 5 个 ruleset fixture（见 Task 0） |
| `tests/scripts/governance/run-all.sh` | test (新建) | 单命令入口：跑 pytest + 两个 bash 测试脚本；任一失败非零退出 |

---

## Task 0 — §15.3 评审策略前置 + 测试 fixtures + mock gh

> 前置任务，完成才进 Task 1。per `docs/governance/wave1-plan-template.md`。

- [ ] **§15.3 评审策略声明**：本 plan 适用 **局部对抗性评审（必）**——1b scope 内 `codex:adversarial-review`，4-5 轮内收敛或 escalate（per `feedback_codex_plan_budget_overshoot`）。不适用集成层评审（无 C8/E5 桥接）/ 性能评审（非 Phase 5）。

- [ ] **Step 1：建 fixtures 目录与 5 个 ruleset fixture**

Create `tests/scripts/governance/fixtures/ruleset-with-check.json`（happy：check 在位 + integration_id 15368 + enforcement active + target branch + 有 rsc 规则；含若干只读字段以验证剥离）：

```json
{
  "id": 15660830,
  "node_id": "RRS_lACfake",
  "name": "main",
  "target": "branch",
  "source_type": "Repository",
  "source": "agateuu1234-bit/kline-trainer",
  "enforcement": "active",
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-05-01T00:00:00Z",
  "_links": {"self": {"href": "https://api.github.com/x"}},
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request"},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "do_not_enforce_on_create": false,
      "required_status_checks": [
        {"context": "swift-contracts-smoke", "integration_id": 15368},
        {"context": "Mac Catalyst build-for-testing on macos-15", "integration_id": 15368}
      ]
    }}
  ]
}
```

Create `tests/scripts/governance/fixtures/ruleset-without-check.json`（同上但删掉 Catalyst entry——只保留 `swift-contracts-smoke` 那条）。

Create `tests/scripts/governance/fixtures/ruleset-anysource.json`（Catalyst entry 在位但**无 `integration_id`**——any-source 伪造风险；assert 须 FAIL，builder 须补 integration_id）：把 Catalyst entry 写成 `{"context": "Mac Catalyst build-for-testing on macos-15"}`。

Create `tests/scripts/governance/fixtures/ruleset-no-rsc.json`（`rules` 数组**无** `required_status_checks` 规则——只有 deletion/non_fast_forward/pull_request；builder + preflight 须 fail-closed）。

Create `tests/scripts/governance/fixtures/ruleset-malformed.json`（**非法 JSON**，故意写坏）：

```
{ "name": "main", "rules": [  BROKEN
```

Create `tests/scripts/governance/fixtures/ruleset-tokenish.json`（合规——含 Catalyst check + integration_id 15368——但 required_status_checks 里**有一个 context 长得像 token**：`ghp_lookslikeatoken_ctx`；验证 builder 从 raw（非 redacted）snapshot 计算，PUT payload 保留该 context 不被 redact 误伤——codex R2-F4）。基于 `ruleset-with-check.json`，把 `required_status_checks` 改为：

```json
[
  {"context": "ghp_lookslikeatoken_ctx", "integration_id": 15368},
  {"context": "Mac Catalyst build-for-testing on macos-15", "integration_id": 15368}
]
```

Create `tests/scripts/governance/fixtures/ruleset-tag.json`（**错 scope** negative：基于 `ruleset-with-check.json` 但 `"target": "tag"` + `"name": "wave0-frozen-protected"`；verify 离线须拒——R3-F3，防把 tag ruleset 误认证为 main 的 H10 证据）。

Create `tests/scripts/governance/fixtures/ruleset-wrongname.json`（**错名** negative：基于 `ruleset-with-check.json` 但 `"name": "develop"`（`target` 仍 `branch`）；verify 离线须拒——R3-F3）。

Create `tests/scripts/governance/fixtures/ruleset-extra-valid.json`（**并发合法改动**：基于 `ruleset-with-check.json`，required_status_checks 多一条无关 check（Catalyst 仍在位+绑 app）；模拟 PUT 后他人追加了别的 check——assert 仍 PASS，runbook 须视为成功**不 rollback**——R4-F1）：

```json
[
  {"context": "swift-contracts-smoke", "integration_id": 15368},
  {"context": "Mac Catalyst build-for-testing on macos-15", "integration_id": 15368},
  {"context": "extra-smoke", "integration_id": 15368}
]
```

Create `tests/scripts/governance/fixtures/ruleset-partial.json`（**未知/部分状态**：基于 `ruleset-without-check.json`（无 Catalyst）但多一条 `extra-smoke`——既不满足谓词、又 != 原状态；runbook 须人工介入**不自动 rollback**——R4-F1）：

```json
[
  {"context": "swift-contracts-smoke", "integration_id": 15368},
  {"context": "extra-smoke", "integration_id": 15368}
]
```

Create `tests/scripts/governance/fixtures/ruleset-inactive.json`（**enforcement 漂移** negative：基于 `ruleset-without-check.json`（name=main/target=branch/有 rsc 规则）但 `"enforcement": "evaluate"`；preflight 须 fail-closed 不 mutate——R5-F1：避免在「谓词永不达标」的非 active ruleset 上改 checks）。

Create `tests/scripts/governance/fixtures/ruleset-wrong-include.json`（**conditions 不绑 main** negative：基于 `ruleset-with-check.json` 但 `"conditions": {"ref_name": {"include": ["refs/heads/release/*"], "exclude": []}}`；verify 须拒——R6-F1：name=main 但实际不绑默认分支）。

Create `tests/scripts/governance/fixtures/ruleset-exclude-main.json`（**conditions 排除 main** negative：基于 `ruleset-with-check.json` 但 `"conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": ["refs/heads/main"]}}`；verify 须拒——R6-F1）。

Create `tests/scripts/governance/fixtures/ruleset-wildcard-exclude.json`（**通配排除 main** negative：基于 `ruleset-with-check.json` 但 `"conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": ["refs/heads/*"]}}`；通配 exclude 命中 main，verify 须拒——R7-F2）。

Create `tests/scripts/governance/fixtures/ruleset-extra-bypass.json`（**多出 bypass actor**：基于 `ruleset-with-check.json` 但 `bypass_actors` 多一条非 admin（如 `{"actor_id": 99, "actor_type": "Team", "bypass_mode": "always"}`）；模拟 PUT 后被加了能架空 gate 的 bypass——preservation 须判 bypass 精确相等→失败→人工介入——R7-F1）。

Create `tests/scripts/governance/fixtures/ruleset-weakened-policy.json`（**R7-F3 negative：rsc policy 字段被削弱**：基于 `ruleset-with-check.json` 但 `required_status_checks` 规则的 `parameters.do_not_enforce_on_create` 改为 `true`（从默认 `false` 削弱）；其余全部相同；preservation_ok 须判 rsc policy 字段漂移→失败→人工介入——R7-F3）。

Create `tests/scripts/governance/fixtures/ruleset-missing-rule.json`（**保护规则缺失**：基于 `ruleset-with-check.json` 但 `rules` 删掉 `deletion`（Catalyst 仍在位+绑 app）；模拟 PUT 后别的保护被一起改没——post_put_classify 状态 != 目标 payload → 人工介入不算成功——R6-F2）。`rules` 仅保留：

```json
[
  {"type": "non_fast_forward"},
  {"type": "pull_request"},
  {"type": "required_status_checks", "parameters": {
    "strict_required_status_checks_policy": false,
    "do_not_enforce_on_create": false,
    "required_status_checks": [
      {"context": "swift-contracts-smoke", "integration_id": 15368},
      {"context": "Mac Catalyst build-for-testing on macos-15", "integration_id": 15368}
    ]
  }}
]
```

- [ ] **Step 2：写 mock gh shim**

Create `tests/scripts/governance/mockgh.sh`（mock `gh`：支持 `api repos/.../rulesets`（list）、`api repos/.../rulesets/ID`（GET）、`api -X PUT .../rulesets/ID`（PUT）；用 env 选 fixture + 模拟成败；记录每次调用到 `$MOCK_LOG`）：

```bash
#!/usr/bin/env bash
# mockgh.sh — 测试用 gh 替身。不发网络。由 GH_CMD 注入。
# 有状态：成功 PUT 校验并持久化提交的 payload 到 ${MOCK_LOG}.state；后续单 GET 返回该 state
# （除非 MOCK_FIXTURE_N<k> 显式注入 drift/失败覆盖）——R3-F2：让 happy 路径真证明 PUT 改了状态。
# env:
#   MOCK_FIXTURE         初始单 ruleset GET 状态（首个 GET 用它初始化 state）
#   MOCK_FIXTURE_N<k>    第 k 次单 GET 返回它并设为新 state（显式注入 drift / PUT 后状态不符 / malformed）
#   MOCK_LIST_ID         list rulesets 返回的 id（缺省 15660830）
#   MOCK_PUT_FAIL        非空 → PUT 返回非零（不持久化）
#   MOCK_LOG             调用日志；单 GET 计数 ${MOCK_LOG}.getcount；状态 ${MOCK_LOG}.state
set -euo pipefail
: "${MOCK_LOG:=/dev/null}"
: "${MOCK_LIST_ID:=15660830}"
STATE="${MOCK_LOG}.state"
printf '%s\n' "$*" >> "$MOCK_LOG"

[ "${1:-}" = "api" ] || { echo "mockgh: unsupported $*" >&2; exit 99; }
shift

METHOD="GET"; INPUT_FILE=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) METHOD="$2"; shift 2 ;;
    --input) INPUT_FILE="$2"; shift 2 ;;
    -f|--field|-F|--raw-field) shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
PATH_ARG="${ARGS[0]:-}"

# GitHub Rulesets PUT 会拒绝（422）含这些只读字段的 payload
REJECT_KEYS='id node_id created_at updated_at _links source source_type current_user_can_bypass'

case "$METHOD:$PATH_ARG" in
  GET:*rulesets)        # list（不计入单 GET 计数）
    echo "[{\"id\": ${MOCK_LIST_ID}, \"name\": \"main\", \"target\": \"branch\", \"enforcement\": \"active\"}]" ;;
  GET:*rulesets/*)      # single GET：计数；N<n> 注入覆盖并更新 state；否则返回 state（首次用 MOCK_FIXTURE 初始化）
    cf="${MOCK_LOG}.getcount"
    n=$(( $( [ -f "$cf" ] && cat "$cf" || echo 0 ) + 1 )); echo "$n" > "$cf"
    eval "ovr=\${MOCK_FIXTURE_N${n}:-}"
    if [ -n "$ovr" ]; then cp "$ovr" "$STATE"
    elif [ ! -f "$STATE" ]; then cp "${MOCK_FIXTURE:?MOCK_FIXTURE required for GET ruleset}" "$STATE"; fi
    cat "$STATE" ;;
  PUT:*rulesets/*)      # mutation：拒只读字段；成功则持久化提交 payload 为新 state
    # stderr 故意含 token（测 R4-F2：runbook 须只把 redacted 副本落 durable artifact）
    [ -z "${MOCK_PUT_FAIL:-}" ] || { echo "mockgh: PUT rejected (simulated) token=${GH_TOKEN:-none}" >&2; exit 1; }
    [ -n "$INPUT_FILE" ] || { echo "mockgh: PUT 无 --input" >&2; exit 1; }
    for k in $REJECT_KEYS; do
      if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in d else 1)" "$INPUT_FILE" "$k"; then
        echo "mockgh: PUT 拒绝——payload 含只读字段 '$k'（GitHub 会 422）" >&2; exit 1
      fi
    done
    cp "$INPUT_FILE" "$STATE"; cat "$STATE" ;;
  *) echo "mockgh: unrecognized $METHOD $PATH_ARG" >&2; exit 98 ;;
esac
```

- [ ] **Step 3：建测试入口骨架（先空，Task 4 填全）**

Create `tests/scripts/governance/run-all.sh`（占位，Task 4 补全）：

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "TODO: filled in Task 4"
```

- [ ] **Step 4：commit fixtures + mock**

```bash
chmod +x tests/scripts/governance/mockgh.sh tests/scripts/governance/run-all.sh
git add tests/scripts/governance/
git commit -m "test(1b): ruleset fixtures + mock gh shim + §15.3 review strategy"
```

---

## Task 1 — `build-protection-put-payload.py`（builder）

**Files:**
- Create: `scripts/governance/build-protection-put-payload.py`
- Test: `tests/scripts/governance/test_build_payload.py`

- [ ] **Step 1：写失败测试**

Create `tests/scripts/governance/test_build_payload.py`：

```python
import importlib.util, json, pathlib, subprocess, sys
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[3]
FIX = pathlib.Path(__file__).resolve().parent / "fixtures"
SCRIPT = ROOT / "scripts/governance/build-protection-put-payload.py"

def _load():
    spec = importlib.util.spec_from_file_location("build_payload", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

mod = _load()
CATALYST = "Mac Catalyst build-for-testing on macos-15"
APP_ID = 15368

def _ruleset(name):
    return json.loads((FIX / name).read_text())

def _catalyst_entries(payload):
    rsc = next(r for r in payload["rules"] if r["type"] == "required_status_checks")
    return [c for c in rsc["parameters"]["required_status_checks"] if c["context"] == CATALYST]

# happy：缺 check 时补上，绑 integration_id
def test_adds_missing_check():
    out = mod.build_payload(_ruleset("ruleset-without-check.json"))
    es = _catalyst_entries(out)
    assert len(es) == 1 and es[0]["integration_id"] == APP_ID

# 幂等：已在位时不重复添加
def test_idempotent_when_present():
    out = mod.build_payload(_ruleset("ruleset-with-check.json"))
    assert len(_catalyst_entries(out)) == 1

# any-source 漂移修复：补 integration_id
def test_fixes_anysource_drift():
    out = mod.build_payload(_ruleset("ruleset-anysource.json"))
    es = _catalyst_entries(out)
    assert len(es) == 1 and es[0]["integration_id"] == APP_ID

# 保留其它 check 不丢
def test_preserves_other_checks():
    out = mod.build_payload(_ruleset("ruleset-with-check.json"))
    rsc = next(r for r in out["rules"] if r["type"] == "required_status_checks")
    ctxs = {c["context"] for c in rsc["parameters"]["required_status_checks"]}
    assert "swift-contracts-smoke" in ctxs

# artifact schema：只读字段被剥离，PUT 字段保留
def test_strips_readonly_fields():
    out = mod.build_payload(_ruleset("ruleset-with-check.json"))
    for ro in ("id", "node_id", "created_at", "updated_at", "_links", "source", "source_type"):
        assert ro not in out
    for k in ("name", "target", "enforcement", "conditions", "rules", "bypass_actors"):
        assert k in out

# serialization 确定性：两次序列化字节一致
def test_deterministic_serialization():
    rs = _ruleset("ruleset-without-check.json")
    a = mod.serialize(mod.build_payload(rs))
    b = mod.serialize(mod.build_payload(_ruleset("ruleset-without-check.json")))
    assert a == b

# 幂等不动点：apply 输出再 build 一次 == 同结果
def test_fixpoint():
    rs = _ruleset("ruleset-without-check.json")
    first = mod.build_payload(rs)
    second = mod.build_payload(json.loads(mod.serialize(first)))
    assert mod.serialize(first) == mod.serialize(second)

# builder 不 redact 合法的 token 样 context 名（R2-F4：源不污染）
def test_builder_preserves_tokenish_context():
    out = mod.serialize(mod.build_payload(_ruleset("ruleset-tokenish.json")))
    assert "ghp_lookslikeatoken_ctx" in out
    assert "github_pat_" not in out

# fail-closed：无 rsc 规则 → ValueError
def test_fail_closed_no_rsc_rule():
    with pytest.raises(ValueError):
        mod.build_payload(_ruleset("ruleset-no-rsc.json"))

# CLI：malformed JSON → 非零退出 + stderr FAIL
def test_cli_malformed_json():
    p = subprocess.run([sys.executable, str(SCRIPT), "--ruleset-json", str(FIX / "ruleset-malformed.json")],
                       capture_output=True, text=True)
    assert p.returncode == 1 and "FAIL" in p.stderr

# normalize-only（rollback 形状）：剥离只读字段、不添加 Catalyst（忠实复制原状态）
def test_normalize_only_preserves_without_adding():
    out = mod.build_payload(_ruleset("ruleset-without-check.json"), ensure_catalyst=False)
    assert _catalyst_entries(out) == []   # 不添加
    for ro in ("id", "node_id", "_links", "source", "source_type", "created_at", "updated_at"):
        assert ro not in out   # 只读字段已剥离（否则 rollback PUT 会 422）

# normalize-only 不要求 rsc 规则（rollback 要忠实复制原状态，无论原 rules 是什么）
def test_normalize_only_no_rsc_ok():
    out = mod.build_payload(_ruleset("ruleset-no-rsc.json"), ensure_catalyst=False)
    assert "rules" in out and "id" not in out

# CLI --normalize-only：退出 0 且输出无只读字段
def test_cli_normalize_only():
    p = subprocess.run([sys.executable, str(SCRIPT), "--normalize-only",
                        "--ruleset-json", str(FIX / "ruleset-without-check.json")],
                       capture_output=True, text=True)
    assert p.returncode == 0
    out = json.loads(p.stdout)
    assert "id" not in out and out.get("name") == "main"
```

- [ ] **Step 2：跑测试确认失败**

Run: `cd "$(git rev-parse --show-toplevel)" && python3 -m pytest tests/scripts/governance/test_build_payload.py -q`
Expected: FAIL（`build-protection-put-payload.py` 不存在 → 收集错误 / ModuleNotFound）

- [ ] **Step 3：写 builder 实现**

Create `scripts/governance/build-protection-put-payload.py`：

```python
#!/usr/bin/env python3
"""build-protection-put-payload.py — 从 main 分支 ruleset GET JSON 构造幂等 PUT payload。

确保 required_status_checks 规则内存在 Catalyst check 且绑 GitHub Actions app
(integration_id=15368)，防止任意来源伪造同名 status 满足 gate（trust-boundary spoof）。
纯函数式：不发任何网络请求。确定性序列化（sort_keys + 紧凑分隔符）保证幂等可 diff。

源真相 = Rulesets API（main 的 legacy branches/main/protection 返回 404）。
Spec: docs/superpowers/plans/2026-05-20-pr1b-required-checks-scripts.md
Usage:
  build-protection-put-payload.py --ruleset-json ruleset.json [--out payload.json]
  gh api repos/OWNER/REPO/rulesets/ID | build-protection-put-payload.py
"""
import argparse
import json
import sys

GITHUB_ACTIONS_INTEGRATION_ID = 15368   # GitHub Actions app 全局 id（UI: source = GitHub Actions）
CATALYST_CONTEXT = "Mac Catalyst build-for-testing on macos-15"
# GitHub rulesets PUT 接受的字段；其余（id/node_id/created_at/updated_at/_links/source/source_type 等）只读，必须剥离
PUT_FIELDS = ("name", "target", "enforcement", "conditions", "rules", "bypass_actors")


def build_payload(ruleset, ensure_catalyst=True):
    """从 GET ruleset 构造规范化 PUT payload。

    剥离只读字段（id/node_id/created_at/updated_at/_links/source/source_type 等），保证 PUT 可接受。
    ensure_catalyst=True：幂等确保 Catalyst check 在位且绑 app（正常 apply payload）。
    ensure_catalyst=False：仅规范化、不动 check（rollback 形状——忠实复制原状态；
      用 raw GET 当 rollback PUT 会被 GitHub 422 拒绝，见 codex R1-F1）。
    """
    if "rules" not in ruleset:
        raise ValueError("ruleset 缺 'rules' 字段；不是合法 ruleset GET 响应")

    payload = {k: ruleset[k] for k in PUT_FIELDS if k in ruleset}

    if not ensure_catalyst:
        return payload   # normalize-only：仅剥离只读字段，保留原状态

    rsc_rule = next((r for r in payload.get("rules", [])
                     if r.get("type") == "required_status_checks"), None)
    if rsc_rule is None:
        # fail-closed：不自动新建整条规则（结构性变更须 admin 显式处理；preflight 也会拦）
        raise ValueError("ruleset 无 required_status_checks 规则；拒绝自动新建（请 admin 先在 UI 建该规则）")

    params = rsc_rule.setdefault("parameters", {})
    checks = params.setdefault("required_status_checks", [])

    catalyst = [c for c in checks if c.get("context") == CATALYST_CONTEXT]
    if catalyst:
        # 修复 any-source 漂移：强制 integration_id 正确
        for c in catalyst:
            c["integration_id"] = GITHUB_ACTIONS_INTEGRATION_ID
        # 去重：多于一条则压成唯一一条
        if len(catalyst) > 1:
            others = [c for c in checks if c.get("context") != CATALYST_CONTEXT]
            others.append({"context": CATALYST_CONTEXT, "integration_id": GITHUB_ACTIONS_INTEGRATION_ID})
            params["required_status_checks"] = others
    else:
        checks.append({"context": CATALYST_CONTEXT, "integration_id": GITHUB_ACTIONS_INTEGRATION_ID})

    return payload


def serialize(payload):
    """确定性序列化：sort_keys 保证幂等可 diff。"""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def main(argv=None):
    ap = argparse.ArgumentParser(description="构造 main ruleset required-checks PUT payload")
    ap.add_argument("--ruleset-json", help="ruleset GET JSON 文件；缺省读 stdin")
    ap.add_argument("--out", help="输出 payload 文件；缺省 stdout")
    ap.add_argument("--normalize-only", action="store_true",
                    help="仅规范化（剥离只读字段、不动 check）；用于 rollback payload")
    args = ap.parse_args(argv)

    raw = open(args.ruleset_json).read() if args.ruleset_json else sys.stdin.read()
    try:
        ruleset = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"FAIL: ruleset JSON 解析失败: {e}", file=sys.stderr)
        return 1
    try:
        payload = build_payload(ruleset, ensure_catalyst=not args.normalize_only)
    except ValueError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1

    out = serialize(payload) + "\n"
    if args.out:
        open(args.out, "w").write(out)
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4：跑测试确认通过**

Run: `cd "$(git rev-parse --show-toplevel)" && python3 -m pytest tests/scripts/governance/test_build_payload.py -q`
Expected: PASS（13 passed）

- [ ] **Step 5：commit**

```bash
chmod +x scripts/governance/build-protection-put-payload.py
git add scripts/governance/build-protection-put-payload.py tests/scripts/governance/test_build_payload.py
git commit -m "feat(1b): build-protection-put-payload.py 幂等 PUT payload builder + tests"
```

---

## Task 2 — `verify-required-checks.sh`（三模式 verifier）

**Files:**
- Create: `scripts/governance/verify-required-checks.sh`
- Test: `tests/scripts/governance/test-verify-required-checks.sh`

**三模式定义：**
- `--mode preflight`：mutation 前——ruleset 可读 + 是 main branch ruleset 结构（有 `required_status_checks` 规则）；不满足 exit 1。
- `--mode assert`：H10 机器可检查谓词——Catalyst check 在位 **且** `integration_id==15368` **且** `enforcement=="active"`；不满足 exit 1。
- `--mode diff`：调 builder 算出 desired，打印「会新增/修正」的 entry vs 当前；非 mutating，永远 exit 0（除非读取失败）。

**输入源**：缺省 live（`gh api` 发现 `target=branch name=main` 的唯一 ruleset id 再 GET）；`--ruleset-json FILE` 离线注入（测试用）。

- [ ] **Step 1：写失败测试**

Create `tests/scripts/governance/test-verify-required-checks.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIX="$ROOT/tests/scripts/governance/fixtures"
V="$ROOT/scripts/governance/verify-required-checks.sh"
fail=0
check() { # desc expected_rc actual_rc
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected rc=$2 got $3)"; fail=1; fi
}

# assert：happy fixture → 0
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-with-check.json" >/dev/null 2>&1; rc=$?; set -e
check "assert happy → 0" 0 "$rc"

# assert：缺 check → 1
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-without-check.json" >/dev/null 2>&1; rc=$?; set -e
check "assert missing → 1" 1 "$rc"

# assert：any-source（无 integration_id）→ 1（防伪造）
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-anysource.json" >/dev/null 2>&1; rc=$?; set -e
check "assert anysource → 1" 1 "$rc"

# preflight：happy → 0
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-with-check.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight happy → 0" 0 "$rc"

# preflight：无 rsc 规则 → 1（谓词为假，fail-closed）
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-no-rsc.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight no-rsc → 1" 1 "$rc"

# preflight：malformed JSON → 3（观测失败，非谓词假——R3-F1）
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-malformed.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight malformed → 3" 3 "$rc"

# R3-F3：错 scope ruleset 离线也被拒（防误认证 H10 证据）
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-tag.json" >/dev/null 2>&1; rc=$?; set -e
check "assert target=tag → 1" 1 "$rc"
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-tag.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight target=tag → 1" 1 "$rc"
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-wrongname.json" >/dev/null 2>&1; rc=$?; set -e
check "assert name!=main → 1" 1 "$rc"
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-wrongname.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight name!=main → 1" 1 "$rc"

# R5-F1：enforcement 非 active 的 ruleset，preflight 即 fail-closed（不等 assert）
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-inactive.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight inactive → 1" 1 "$rc"
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-inactive.json" >/dev/null 2>&1; rc=$?; set -e
check "assert inactive → 1" 1 "$rc"

# R6-F1：conditions 未真绑默认分支 / 排除 main → verify 拒
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-wrong-include.json" >/dev/null 2>&1; rc=$?; set -e
check "assert wrong-include → 1" 1 "$rc"
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-wrong-include.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight wrong-include → 1" 1 "$rc"
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-exclude-main.json" >/dev/null 2>&1; rc=$?; set -e
check "assert exclude-main → 1" 1 "$rc"
# R7-F2：通配 exclude（refs/heads/*）命中 main 也须拒
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-wildcard-exclude.json" >/dev/null 2>&1; rc=$?; set -e
check "assert wildcard-exclude → 1" 1 "$rc"
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-wildcard-exclude.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight wildcard-exclude → 1" 1 "$rc"

# 最终 review：含非 admin bypass actor → assert/preflight 都拒（防绕过 required check）
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-extra-bypass.json" >/dev/null 2>&1; rc=$?; set -e
check "assert extra-bypass → 1" 1 "$rc"
set +e; "$V" --mode preflight --ruleset-json "$FIX/ruleset-extra-bypass.json" >/dev/null 2>&1; rc=$?; set -e
check "preflight extra-bypass → 1" 1 "$rc"

# diff：anysource → 0 且输出含 "Mac Catalyst"（显示将修正）
set +e; out=$("$V" --mode diff --ruleset-json "$FIX/ruleset-anysource.json" 2>&1); rc=$?; set -e
check "diff anysource → 0" 0 "$rc"
echo "$out" | grep -q "Mac Catalyst" && echo "PASS: diff shows change" || { echo "FAIL: diff shows change"; fail=1; }

# bad mode → 2
set +e; "$V" --mode bogus --ruleset-json "$FIX/ruleset-with-check.json" >/dev/null 2>&1; rc=$?; set -e
check "bad mode → 2" 2 "$rc"

exit $fail
```

- [ ] **Step 2：跑测试确认失败**

Run: `cd "$(git rev-parse --show-toplevel)" && bash tests/scripts/governance/test-verify-required-checks.sh`
Expected: FAIL（脚本不存在 / 报错非零）

- [ ] **Step 3：写 verifier 实现**

Create `scripts/governance/verify-required-checks.sh`（嵌入 python heredoc + env 传 JSON，对齐 `verify-freeze-tag.sh` 的 R1 finding 修复——不用 stdin pipe + heredoc）：

```bash
#!/usr/bin/env bash
# verify-required-checks.sh — 三模式校验 main ruleset required-checks（rulesets API 源真相）
#
# 源真相 = Rulesets API（main 的 legacy branches/main/protection 返回 404；保护全在 ruleset）。
# H10 机器可检查谓词：Catalyst check 在位 + integration_id=15368（GitHub Actions app，防伪造）+ enforcement=active。
#
# Modes:
#   --mode preflight  mutation 前：main branch ruleset（name=main + target=branch）+ 有 required_status_checks 规则
#   --mode assert     断言 main branch ruleset + Catalyst check 在位 + 绑 app(15368) + active（= 1c 跑的 H10 gate）
#   --mode diff       打印 payload 会做的变更 vs 当前；非 mutating
#
# Exit codes（R3-F1 分层，供 runbook 区分 rollback vs 人工介入）：
#   0 = pass / 1 = 谓词为假（状态可读但不达标）/ 2 = 用法错误 / 3 = 观测失败（gh/传输/JSON 解析，状态未知）
#
# Input: 缺省 live（gh api 发现 target=branch name=main 的唯一 ruleset id）；或 --ruleset-json FILE 离线/测试。
# 注意：离线 --ruleset-json 也强制 name=main + target=branch（R3-F3：防把 tag/非 main ruleset 误认证为 H10 证据）。
# Spec: docs/superpowers/plans/2026-05-20-pr1b-required-checks-scripts.md
set -euo pipefail

REPO="${REPO:-agateuu1234-bit/kline-trainer}"
GH_CMD="${GH_CMD:-gh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="$SCRIPT_DIR/build-protection-put-payload.py"
MODE=""
RULESET_JSON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --ruleset-json) RULESET_JSON="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 --mode preflight|assert|diff [--ruleset-json FILE] [--repo OWNER/NAME]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in preflight|assert|diff) ;; *) echo "FAIL: --mode preflight|assert|diff required" >&2; exit 2 ;; esac

# 取 main branch ruleset JSON：离线优先 --ruleset-json，否则 live 发现。观测失败 exit 3（状态未知）
get_ruleset_json() {
  if [ -n "$RULESET_JSON" ]; then
    cat "$RULESET_JSON" || { echo "FAIL: 读 --ruleset-json 失败（观测失败）" >&2; exit 3; }
    return
  fi
  local list rid
  list=$("$GH_CMD" api "repos/$REPO/rulesets") || { echo "FAIL: gh api rulesets 失败（观测失败）" >&2; exit 3; }
  rid=$(RULESETS_JSON="$list" python3 <<'PY'
import json, os, sys
data = json.loads(os.environ['RULESETS_JSON'])
ids = [str(r['id']) for r in data if r.get('target') == 'branch' and r.get('name') == 'main']
if len(ids) != 1:
    print(f"期望恰好 1 个 target=branch name=main ruleset，实得 {ids}", file=sys.stderr); sys.exit(1)
print(ids[0])
PY
) || { echo "FAIL: ruleset 发现失败（观测失败）: $rid" >&2; exit 3; }
  "$GH_CMD" api "repos/$REPO/rulesets/$rid" || { echo "FAIL: gh api ruleset GET 失败（观测失败）" >&2; exit 3; }
}

set +e
RULESET=$(get_ruleset_json)
GET_EXIT=$?
set -e
[ "$GET_EXIT" -eq 0 ] || exit "$GET_EXIT"

case "$MODE" in
  preflight|assert)
    set +e
    RESULT=$(RULESET_JSON="$RULESET" MODE="$MODE" python3 <<'PY'
import json, os, sys, fnmatch
APP_ID = 15368
CATALYST = "Mac Catalyst build-for-testing on macos-15"
mode = os.environ['MODE']
try:
    rs = json.loads(os.environ['RULESET_JSON'])
except Exception as e:
    print(f"FAIL: ruleset JSON 解析失败（观测失败）: {e}"); sys.exit(3)

# R3-F3：main branch ruleset 不变量（离线也强制；防 tag/非 main 误认证为 H10 证据）
if rs.get('target') != 'branch' or rs.get('name') != 'main':
    print(f"FAIL: 非 main branch ruleset（name={rs.get('name')} target={rs.get('target')}）"); sys.exit(1)
# R5-F1：enforcement 必须 active —— preflight 即 fail-closed，避免在「谓词永不达标」的 ruleset
# （evaluate/disabled）上 mutate checks（PUT 后 assert 必败 → 部分 mutate 却无 rollback）
if rs.get('enforcement') != 'active':
    print(f"FAIL: enforcement={rs.get('enforcement')} != active（gate 不会生效；fail-closed 不 mutate）"); sys.exit(1)

# R6-F1 / R7-F2：conditions.ref_name 必须真绑默认分支（用 GitHub 兼容通配语义；
# 防 name=main 但 ref 指向别处，或用通配 exclude（refs/heads/* / *）把 main 排除掉）
ref_cond = (rs.get('conditions') or {}).get('ref_name') or {}
include = ref_cond.get('include') or []
exclude = ref_cond.get('exclude') or []
def _matches_main(p):  # 该 pattern 是否命中 main 分支
    if p in ('~DEFAULT_BRANCH', '~ALL'):
        return True
    return fnmatch.fnmatchcase('refs/heads/main', p) or fnmatch.fnmatchcase('main', p)
if not any(_matches_main(p) for p in include):
    print(f"FAIL: conditions.include 未绑默认分支/main（include={include}）"); sys.exit(1)
if any(_matches_main(p) for p in exclude):
    print(f"FAIL: conditions.exclude 命中并排除 main（exclude={exclude}）"); sys.exit(1)

# 最终 branch-diff review：bypass_actors 必须仅 admin —— 否则非 admin 可绕过 required check（gate 形同虚设 / 假 H10 证据）。
# admin 判定镜像 verify-freeze-tag.sh：RepositoryRole+actor_id=5 或 OrganizationAdmin。
def _is_admin_bypass(b):
    at = b.get('actor_type', ''); aid = b.get('actor_id', 0)
    return at == 'OrganizationAdmin' or (at == 'RepositoryRole' and aid == 5)
non_admin_bypass = [b for b in (rs.get('bypass_actors') or []) if not _is_admin_bypass(b)]
if non_admin_bypass:
    print(f"FAIL: bypass_actors 含非 admin（可绕过 required check）: {non_admin_bypass}"); sys.exit(1)

rules = rs.get('rules') or []
rsc = next((r for r in rules if r.get('type') == 'required_status_checks'), None)
if rsc is None:
    print("FAIL: 无 required_status_checks 规则"); sys.exit(1)
checks = (rsc.get('parameters') or {}).get('required_status_checks') or []

if mode == 'preflight':
    print("OK: preflight（main branch ruleset + 绑默认分支 + active + 有 required_status_checks 规则 + bypass 仅 admin）"); sys.exit(0)

# assert（enforcement/name/target 已在上面 fail-closed，这里只判 Catalyst check）
reasons = []
cat = [c for c in checks if c.get('context') == CATALYST]
if not cat:
    reasons.append(f"缺 required check '{CATALYST}'")
else:
    for c in cat:
        if c.get('integration_id') != APP_ID:
            reasons.append(f"'{CATALYST}' integration_id={c.get('integration_id')} != {APP_ID}（any-source 伪造风险）")
if reasons:
    print("FAIL: " + " | ".join(reasons)); sys.exit(1)
print(f"OK: main branch ruleset + 绑默认分支 + active + '{CATALYST}' 在位 + integration_id={APP_ID} + bypass 仅 admin"); sys.exit(0)
PY
)
    PY_EXIT=$?
    set -e
    echo "$RESULT"
    exit $PY_EXIT
    ;;
  diff)
    # 调 builder 算 desired；对比当前 vs payload 的 required_status_checks
    DESIRED=$(printf '%s' "$RULESET" | python3 "$BUILDER") || { echo "FAIL: builder 失败" >&2; exit 1; }
    set +e
    RESULT=$(CURRENT_JSON="$RULESET" DESIRED_JSON="$DESIRED" python3 <<'PY'
import json, os
CATALYST = "Mac Catalyst build-for-testing on macos-15"
def checks(d):
    rsc = next((r for r in (d.get('rules') or []) if r.get('type') == 'required_status_checks'), None)
    return (rsc.get('parameters') or {}).get('required_status_checks') or [] if rsc else []
cur = {c.get('context'): c for c in checks(json.loads(os.environ['CURRENT_JSON']))}
des = {c.get('context'): c for c in checks(json.loads(os.environ['DESIRED_JSON']))}
changes = []
for ctx, c in des.items():
    if ctx not in cur:
        changes.append(f"  + 新增 {ctx} (integration_id={c.get('integration_id')})")
    elif cur[ctx].get('integration_id') != c.get('integration_id'):
        changes.append(f"  ~ 修正 {ctx} integration_id {cur[ctx].get('integration_id')} -> {c.get('integration_id')}")
print("diff（payload vs 当前 required_status_checks）:")
print("\n".join(changes) if changes else "  （无变更——已是 desired 状态，幂等 no-op）")
PY
)
    PY_EXIT=$?
    set -e
    echo "$RESULT"
    [ "$PY_EXIT" -eq 0 ] || { echo "FAIL: diff 计算失败（观测失败）" >&2; exit 3; }
    exit 0
    ;;
esac
```

- [ ] **Step 4：跑测试确认通过**

Run: `cd "$(git rev-parse --show-toplevel)" && bash tests/scripts/governance/test-verify-required-checks.sh`
Expected: 全 PASS，退出 0

- [ ] **Step 5：commit**

```bash
chmod +x scripts/governance/verify-required-checks.sh tests/scripts/governance/test-verify-required-checks.sh
git add scripts/governance/verify-required-checks.sh tests/scripts/governance/test-verify-required-checks.sh
git commit -m "feat(1b): verify-required-checks.sh 三模式 verifier (preflight/assert/diff) + tests"
```

---

## Task 3 — `admin-configure-required-checks.sh`（runbook + mutation safety contracts）

**Files:**
- Create: `scripts/governance/admin-configure-required-checks.sh`
- Test: `tests/scripts/governance/test-admin-runbook.sh`

**Runbook 流程**（1c 执行；1b 仅 against mock 测过、不动 origin）：
1. 解析 `--apply`（缺省 dry-run）/ `--repo` / `--artifact-dir`。
2. **discover + snapshot**：发现 main branch ruleset id → GET#1 → 写 **raw snapshot 临时文件**（chmod 600，trap 清理，供计算）；redacted 副本 → `<artifact-dir>/ruleset-snapshot.json`（durable 审计）。
3. **preflight**：`verify --mode preflight --ruleset-json <raw-snapshot>`（不额外 GET）。fail → exit 1（不 mutate）。
4. **build 双 payload**（均从 **raw** snapshot，避免 redact 污染——R2-F4）：
   - `payload.json` = `builder`（PUT 形状 + Catalyst 确保）。
   - `rollback-payload.json` = `builder --normalize-only`（PUT 形状的**原状态**；无只读字段——R1-F1）。
5. **dry-run**（缺省）：`verify --mode diff --ruleset-json <raw-snapshot>` 打印将变更，**不 mutate**，exit 0。
6. **no-op skip（R2-F1）**：`payload.json` == `rollback-payload.json` → 已合规 → **不 PUT**，只跑 live assert + 写 evidence → exit 0（assert fail 则 exit 1）。
7. **apply 且需变更**（`--apply` 且非 no-op）：
   - **乐观并发 re-read（R1-F2，best-effort）**：GET#2 → normalize → 与 `rollback-payload.json`（原状态）比对；不一致 = 并发漂移 → **abort exit 1（不 PUT）**。残留 TOCTOU 见 grounding #8。
   - PUT `payload.json`（成功/非零都不假设结果；非零时把 stderr redacted 落 `put-error.txt`，原始只存 chmod-600 临时——R4-F2）。
   - **统一 re-read 分类器（R4-F1，绝不自动 rollback）**：再 re-read 当前状态 → 对其跑 `verify assert`：谓词满足→成功 exit 0（含并发追加的合法 rule）；观测失败(3)→人工介入 exit 1；谓词假且==原状态→PUT 未生效 exit 1；谓词假且未知/部分→人工介入（留 `rollback-payload.json` 供手动决策，不自动 PUT）exit 1。
8. **redaction**：写入 durable artifact（snapshot 审计副本 / evidence / put-error 副本）经 `redact()` 剥离 token；**raw 计算文件 + 原始 PUT stderr 不进 durable**（chmod-600 临时，trap 清理；避免 R2-F4 污染 + R4-F2 泄漏）。

- [ ] **Step 1：写失败测试**（16 场景：dry-run / no-op skip / mutate happy(+PUT body 断言) / PUT 干净失败 / PUT 报错但已 apply / 并发合法追加→成功 / 未知状态→人工 / 保护流失→人工 / 多 bypass actor→人工 / 并发漂移 abort / preflight-fail(no-rsc) / inactive fail-closed / GH_TOKEN redaction / token 样 context 保留 / 观测失败不 rollback / PUT-failure artifact redaction）

Create `tests/scripts/governance/test-admin-runbook.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
G="$ROOT/tests/scripts/governance"
FIX="$G/fixtures"
R="$ROOT/scripts/governance/admin-configure-required-checks.sh"
MOCK="$G/mockgh.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (exp rc=$2 got $3)"; fail=1; fi; }
no_readonly() { # file desc：断言 PUT payload 无只读字段（否则 GitHub 422）
  local k
  for k in id node_id created_at updated_at _links source source_type; do
    if python3 -c "import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)" "$1" "$k" 2>/dev/null; then
      echo "FAIL: $2 含只读字段 $k"; fail=1; return; fi
  done
  echo "PASS: $2 无只读字段"
}
one_catalyst() { # file desc：断言 PUT body 恰含一条 Catalyst + integration_id 15368（R3-F2）
  python3 - "$1" <<'PY' && echo "PASS: $2 恰一条 Catalyst+15368" || { echo "FAIL: $2 Catalyst 校验未过"; fail=1; }
import json, sys
d = json.load(open(sys.argv[1]))
rsc = next((r for r in d.get('rules', []) if r.get('type') == 'required_status_checks'), {})
cat = [c for c in (rsc.get('parameters', {}).get('required_status_checks') or [])
       if c.get('context') == 'Mac Catalyst build-for-testing on macos-15']
sys.exit(0 if len(cat) == 1 and cat[0].get('integration_id') == 15368 else 1)
PY
}
newdir() { mktemp -d; }
WITH="$FIX/ruleset-with-check.json"
WITHOUT="$FIX/ruleset-without-check.json"

# 1) dry-run（缺省）：不 mutate → 0，无 PUT
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_LOG="$log" "$R" --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "dry-run → 0" 0 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: dry-run 不应有 PUT"; fail=1; } || echo "PASS: dry-run 无 PUT"

# 2) apply no-op（已合规）：payload==原状态 → skip PUT → 0（R2-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITH" MOCK_LOG="$log" "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "apply no-op → 0" 0 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: no-op 不应 PUT"; fail=1; } || echo "PASS: no-op 无 PUT"
[ -f "$d/ruleset-snapshot.json" ] && echo "PASS: snapshot 落地" || { echo "FAIL: 无 snapshot"; fail=1; }
no_readonly "$d/payload.json" "payload.json"
no_readonly "$d/rollback-payload.json" "rollback-payload.json"

# 3) apply mutate happy：snapshot 缺 check → PUT 1 次 → 有状态 mock 持久化 payload → post-assert 读到 → 0
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_LOG="$log" "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "apply mutate → 0" 0 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: mutate PUT 恰 1 次" || { echo "FAIL: 期望 PUT=1 得 $put_count"; fail=1; }
# R3-F2：mock 持久化的 state == 提交的 payload（证明 PUT body 正确）+ 恰一条 Catalyst+15368
diff -q "$log.state" "$d/payload.json" >/dev/null && echo "PASS: PUT body == payload.json（mock 持久化提交内容）" || { echo "FAIL: PUT body 与 payload.json 不符"; fail=1; }
one_catalyst "$d/payload.json" "PUT body"

# 4) PUT 干净失败（PUT 非零 + re-read 仍原状态）→ 无 mutation → 1
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_PUT_FAIL=1 MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "PUT 干净失败 → 1" 1 "$rc"

# 5) PUT 报错但已 apply（PUT 非零 + post-fail re-read 见 desired，N3）→ 0（R2-F2）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_PUT_FAIL=1 MOCK_FIXTURE_N3="$WITH" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "PUT 报错但已 apply → 0" 0 "$rc"

# 6a) 并发合法追加（PUT 后 re-read 保留全部目标保护 + 多一条无关 check，N3）→ 保留齐全 → 成功 → 0
#     （R4-F1：容许并发合法追加、不 rollback；与 6c 保护流失对照）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-extra-valid.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "并发合法追加 → 0（保留齐全）" 0 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 合法追加未误 rollback（PUT 恰 1）" || { echo "FAIL: PUT=$put_count"; fail=1; }

# 6c) 保护流失（PUT 后 re-read Catalyst 在但 deletion 规则没了，N3）→ 不算成功 → 人工介入不 rollback → 1（R6-F2）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-missing-rule.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "保护流失(Catalyst在但少规则) → 1" 1 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 保护流失未被当成功 + 未自动 rollback（PUT 恰 1）" || { echo "FAIL: PUT=$put_count"; fail=1; }

# 6d) 多出 bypass actor（PUT 后 re-read Catalyst 在但加了能架空 gate 的 bypass，N3）→ 不算成功 → 人工 → 1（R7-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-extra-bypass.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "多 bypass actor → 1（人工介入）" 1 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 新增 bypass 未被当成功 + 未自动 rollback（PUT 恰 1）" || { echo "FAIL: PUT=$put_count"; fail=1; }

# 6e) 规则 param 削弱（PUT 后 re-read rsc policy do_not_enforce_on_create 翻转，N3）→ 不算成功 → 人工 → 1（R7-F3）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-weakened-policy.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "param 削弱 → 1（人工介入）" 1 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: param 削弱未被当成功 + 未自动 rollback（PUT 恰 1）" || { echo "FAIL: PUT=$put_count"; fail=1; }

# 6b) 未知/部分状态（PUT 后 re-read 无 Catalyst 且 != 原状态，N3）→ 人工介入不自动 rollback → 1（R4-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-partial.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "未知状态 → 1（人工介入）" 1 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 未知状态未自动 rollback（PUT 恰 1）" || { echo "FAIL: 不应自动 rollback，PUT=$put_count"; fail=1; }

# 7) 并发漂移：PUT 前 re-read（N2）与 snapshot 不一致 → abort，无 PUT（R1-F2）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N2="$WITH" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "并发漂移 → 1 abort" 1 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: 漂移检测后不应 PUT"; fail=1; } || echo "PASS: 漂移检测后无 PUT"

# 8) preflight 失败（GET 回 no-rsc）→ 1，无 PUT
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$FIX/ruleset-no-rsc.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "preflight-fail → 1" 1 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: preflight 失败不应 PUT"; fail=1; } || echo "PASS: preflight 失败无 PUT"

# 8b) enforcement 非 active（inactive）→ preflight fail-closed → 1，无 PUT（R5-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$FIX/ruleset-inactive.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "inactive → 1（fail-closed）" 1 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: inactive 不应 PUT"; fail=1; } || echo "PASS: inactive 无 PUT"

# 8c) snapshot 含非 admin bypass → preflight fail-closed → 1，无 PUT（最终 review bypass gap）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$FIX/ruleset-extra-bypass.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "非admin bypass → 1（fail-closed）" 1 "$rc"
grep -q "PUT" "$log" && { echo "FAIL: 非admin bypass 不应 PUT"; fail=1; } || echo "PASS: 非admin bypass 无 PUT"

# 9) redaction：注入假 GH_TOKEN，断言 artifact 文件不含它
d=$(newdir); log="$d/calls.log"
set +e
GH_TOKEN="ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE1234" GH_CMD="$MOCK" MOCK_FIXTURE="$WITH" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1
set -e
if grep -rq "ghp_FAKE" "$d" 2>/dev/null; then echo "FAIL: token 泄漏进 artifact"; fail=1; else echo "PASS: redaction 无 token 泄漏"; fi

# 10) token 样 context 保留：payload.json（mutation 源，从 raw 计算）保留；redacted 审计副本被脱敏（R2-F4）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$FIX/ruleset-tokenish.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1
set -e
grep -q "ghp_lookslikeatoken_ctx" "$d/payload.json" && echo "PASS: payload 保留 token 样 context" || { echo "FAIL: payload 误脱敏 token 样 context"; fail=1; }
grep -q "ghp_lookslikeatoken" "$d/ruleset-snapshot.json" && { echo "FAIL: 审计副本未脱敏"; fail=1; } || echo "PASS: 审计副本已脱敏"

# 11) PUT 成功但 post-assert 观测失败（注入 N3=malformed → verify exit 3）→ 不 rollback → 1，PUT 恰 1（R3-F1）
d=$(newdir); log="$d/calls.log"
set +e
GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_FIXTURE_N3="$FIX/ruleset-malformed.json" MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1; rc=$?
set -e
check "观测失败 → 1（不 rollback）" 1 "$rc"
put_count=$(grep -c "PUT" "$log" || true)
[ "$put_count" -eq 1 ] && echo "PASS: 观测失败未触发 rollback（PUT 恰 1）" || { echo "FAIL: 观测失败误 rollback，PUT=$put_count"; fail=1; }

# 12) PUT-failure artifact redaction：mock PUT-fail stderr 带 token → durable artifact 不得含它（R4-F2）
d=$(newdir); log="$d/calls.log"
set +e
GH_TOKEN="ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE1234" GH_CMD="$MOCK" MOCK_FIXTURE="$WITHOUT" MOCK_PUT_FAIL=1 MOCK_LOG="$log" \
  "$R" --apply --artifact-dir "$d" >/dev/null 2>&1
set -e
[ -f "$d/put-error.txt" ] && echo "PASS: PUT-error redacted 副本落地" || { echo "FAIL: 无 put-error.txt"; fail=1; }
if grep -rq "ghp_FAKE" "$d" 2>/dev/null; then echo "FAIL: PUT stderr token 泄漏进 artifact"; fail=1; else echo "PASS: PUT-failure artifact 无 token"; fi

exit $fail
```

- [ ] **Step 2：跑测试确认失败**

Run: `cd "$(git rev-parse --show-toplevel)" && bash tests/scripts/governance/test-admin-runbook.sh`
Expected: FAIL（runbook 不存在）

- [ ] **Step 3：写 runbook 实现**

Create `scripts/governance/admin-configure-required-checks.sh`：

```bash
#!/usr/bin/env bash
# admin-configure-required-checks.sh — 1c admin 执行的 runbook：幂等配置 main ruleset 的 Catalyst required check。
#
# 缺省 dry-run（只打印 diff 不 mutate）；--apply 才真改。源真相 = Rulesets API。
# mutation safety：discover+snapshot(raw 计算 / redacted 审计分离) → preflight(name/target/绑默认分支/active/有 rsc 规则) →
#   build(payload + rollback-payload) → no-op skip → [乐观并发 re-read → PUT → post_put_classify]。
# post_put_classify 成功判据 = 状态完全等于目标 payload（R6-F2）；**绝不自动 rollback**（R4-F1）——
#   rollback-payload（normalize-only 原状态，非 raw snapshot——R1-F1）仅作手动还原 artifact。
# 残留 TOCTOU（re-read→PUT 窗口）见 plan grounding #8（单管理员仓 + 手动执行，接受）。
# 测试经 GH_CMD 注入 mock；1b 不动 origin，1c 才对 origin 跑（首跑因 check 已在位 = no-op skip）。
# Spec: docs/superpowers/plans/2026-05-20-pr1b-required-checks-scripts.md
set -euo pipefail

REPO="${REPO:-agateuu1234-bit/kline-trainer}"
GH_CMD="${GH_CMD:-gh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="$SCRIPT_DIR/build-protection-put-payload.py"
VERIFY="$SCRIPT_DIR/verify-required-checks.sh"
APPLY=0
ARTIFACT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --artifact-dir) ARTIFACT_DIR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 [--apply] [--artifact-dir DIR] [--repo OWNER/NAME]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ARTIFACT_DIR" ] || ARTIFACT_DIR="$(mktemp -d)"
mkdir -p "$ARTIFACT_DIR"

# raw 临时文件（不进 durable artifact-dir；chmod 600；trap 清理）：
#   R2-F4 避免 redact 污染 PUT 源；R4-F2 原始 PUT stderr 不落 durable（只落 redacted 副本）
RAW_SNAP=$(mktemp); REREAD_RAW=$(mktemp); RAW_PUT_ERR=$(mktemp); chmod 600 "$RAW_SNAP" "$REREAD_RAW" "$RAW_PUT_ERR"
trap 'rm -f "$RAW_SNAP" "$REREAD_RAW" "$RAW_PUT_ERR"' EXIT

# redact：剥离 GH_TOKEN 实值 + token 样式串（仅用于 durable 审计副本 / evidence，不碰 raw 计算文件）
redact() {
  local s; s=$(cat)
  if [ -n "${GH_TOKEN:-}" ]; then s=${s//"$GH_TOKEN"/[REDACTED]}; fi
  printf '%s' "$s" | sed -E 's/ghp_[A-Za-z0-9]+/[REDACTED]/g; s/github_pat_[A-Za-z0-9_]+/[REDACTED]/g'
}

discover_rid() {
  local list
  list=$("$GH_CMD" api "repos/$REPO/rulesets") || { echo "FAIL: gh api rulesets 失败" >&2; exit 1; }
  RULESETS_JSON="$list" python3 <<'PY'
import json, os, sys
data = json.loads(os.environ['RULESETS_JSON'])
ids = [str(r['id']) for r in data if r.get('target') == 'branch' and r.get('name') == 'main']
if len(ids) != 1:
    print(f"期望恰好 1 个 target=branch name=main ruleset，实得 {ids}", file=sys.stderr); sys.exit(1)
print(ids[0])
PY
}

# assert 已应用状态 + 写 evidence（live=--repo / offline=--ruleset-json FILE）。
# 保留 VERIFY 真实退出码（0 pass / 1 谓词假 / 3 观测失败）——R3-F1：runbook 据此区分 rollback vs 人工介入。
# 最终 branch-diff review：evidence redact/写盘失败 → fail-closed（不假绿）。
assert_and_evidence() {
  local rc=0 tmp
  tmp=$(mktemp); chmod 600 "$tmp"
  "$VERIFY" "$@" > "$tmp" || rc=$?
  if ! redact < "$tmp" > "$ARTIFACT_DIR/verify-evidence.txt" || [ ! -s "$ARTIFACT_DIR/verify-evidence.txt" ]; then
    rm -f "$tmp"; echo "FAIL: evidence redact/写盘失败或为空（审计不可信）— 人工介入" >&2; return 1
  fi
  rm -f "$tmp"
  if [ "$rc" -eq 0 ]; then
    echo "GATE PASS：Catalyst required check 已绑 app + active。evidence: $ARTIFACT_DIR/verify-evidence.txt"
  fi
  return "$rc"
}

# 保留不变量检查（R6-F2）：reread 是否保留 payload 的全部保护元素（容许额外追加）。
# 退出码：0=保留齐全 / 1=有缺失（保护流失/未生效）/ 2=观测失败（JSON 解析）。按集合比，稳健于 GitHub 服务端规范化/排序。
# 非 rsc 规则：desired 每条完整对象必须在 actual（R7-F3：catch param 漂移/删除；容许追加）。
# rsc policy 字段（strict_required_status_checks_policy / do_not_enforce_on_create）精确保留（R7-F3）。
preservation_ok() { # args: desired-payload.json reread-raw.json
  python3 - "$1" "$2" <<'PY'
import json, sys
desired = json.load(open(sys.argv[1]))
try:
    actual = json.loads(open(sys.argv[2]).read())
except Exception:
    sys.exit(2)
def rsc(d):
    return next((x for x in (d.get('rules') or []) if x.get('type') == 'required_status_checks'), {})
def checks(d):
    return {(c.get('context'), c.get('integration_id'))
            for c in ((rsc(d).get('parameters') or {}).get('required_status_checks') or [])}
def nonrsc(d):  # 非 rsc 规则整对象 canonical：catch param 削弱/删除，容许额外追加
    return {json.dumps(r, sort_keys=True) for r in (d.get('rules') or []) if r.get('type') != 'required_status_checks'}
def bypass(d):
    return {(b.get('actor_id'), b.get('actor_type'), b.get('bypass_mode')) for b in (d.get('bypass_actors') or [])}
# 标量 + conditions 不可变
for k in ('name', 'target', 'enforcement', 'conditions'):
    if actual.get(k) != desired.get(k): sys.exit(1)
# 非 rsc 规则：desired 每条完整对象必须在 actual（R7-F3：catch param 漂移/删除；容许追加）
if not nonrsc(desired) <= nonrsc(actual): sys.exit(1)
# rsc policy 字段精确保留（R7-F3）
dp = rsc(desired).get('parameters') or {}; ap = rsc(actual).get('parameters') or {}
for pf in ('strict_required_status_checks_policy', 'do_not_enforce_on_create'):
    if dp.get(pf) != ap.get(pf): sys.exit(1)
# required checks：desired ⊆ actual（容许额外 check）
if not checks(desired) <= checks(actual): sys.exit(1)
# bypass actors：**精确相等**（R7-F1：新增任何 bypass actor 都会架空 required check，不能容许追加）
if bypass(desired) != bypass(actual): sys.exit(1)
sys.exit(0)
PY
}

# post-mutation 统一分类器（R4-F1 绝不自动 rollback；R6-F2 成功判据 = 保留不变量，非仅 Catalyst 谓词）。
# re-read 实际状态 → preservation_ok(payload, reread)：
#   保留齐全(0)  → 成功（容许并发合法追加）；再 assert 写 evidence，return 0
#   观测失败(2)  → 状态未知，人工介入，return 1
#   有缺失(1)    → 区分：==原状态→PUT 未生效；否则保护流失/部分/并发改动→人工介入。一律不自动 rollback。
post_put_classify() {
  "$GH_CMD" api "repos/$REPO/rulesets/$RID" > "$REREAD_RAW" \
    || { echo "FAIL: re-read 失败 — 状态未知，人工介入" >&2; return 1; }
  local pc=0
  preservation_ok "$ARTIFACT_DIR/payload.json" "$REREAD_RAW" || pc=$?
  if [ "$pc" -eq 2 ]; then echo "FAIL: re-read 观测失败（无法解析）— 状态未知，人工介入" >&2; return 1; fi
  if [ "$pc" -eq 0 ]; then
    echo "re-read 保留全部目标保护（容许额外追加）→ 成功" >&2
    local arc=0
    assert_and_evidence --mode assert --ruleset-json "$REREAD_RAW" || arc=$?
    [ "$arc" -eq 0 ] && return 0
    echo "FAIL: 保留检查通过但 assert 未过（exit=$arc，1=谓词假/3=观测失败）— 人工介入" >&2; return 1
  fi
  # pc==1 有缺失：判 PUT 是否根本没生效（仍为原状态）
  local norm; norm=$(python3 "$BUILDER" --normalize-only --ruleset-json "$REREAD_RAW") \
    || { echo "FAIL: 规范化失败 — 状态未知，人工介入" >&2; return 1; }
  if [ "$norm" = "$(cat "$ARTIFACT_DIR/rollback-payload.json")" ]; then
    echo "FAIL: 状态仍为原始（PUT 未生效）；无需 rollback" >&2; return 1
  fi
  echo "FAIL: 目标保护有缺失（保护流失 / 部分应用 / 并发改动）→ 不自动 rollback；须人工核对（rollback-payload 已备）" >&2
  return 1
}

echo "== [1] 发现 ruleset id =="
RID=$(discover_rid) || exit 1

echo "== [2] snapshot（GET#1：raw 供计算 + redacted 审计副本）=="
"$GH_CMD" api "repos/$REPO/rulesets/$RID" > "$RAW_SNAP"
[ -s "$RAW_SNAP" ] || { echo "FAIL: snapshot 为空" >&2; exit 1; }
redact < "$RAW_SNAP" > "$ARTIFACT_DIR/ruleset-snapshot.json"

echo "== [3] preflight（对 raw snapshot，不额外 GET）=="
"$VERIFY" --mode preflight --ruleset-json "$RAW_SNAP" \
  || { echo "FAIL: preflight 未过，终止（不 mutate）" >&2; exit 1; }

echo "== [4] build 双 payload（从 raw snapshot）=="
python3 "$BUILDER" --ruleset-json "$RAW_SNAP" --out "$ARTIFACT_DIR/payload.json" \
  || { echo "FAIL: builder 失败" >&2; exit 1; }
python3 "$BUILDER" --normalize-only --ruleset-json "$RAW_SNAP" --out "$ARTIFACT_DIR/rollback-payload.json" \
  || { echo "FAIL: rollback-payload builder 失败" >&2; exit 1; }

if [ "$APPLY" -ne 1 ]; then
  echo "== [5] dry-run（不 mutate）=="
  "$VERIFY" --mode diff --ruleset-json "$RAW_SNAP"
  echo "dry-run 完成；加 --apply 才真改。artifact: $ARTIFACT_DIR"
  exit 0
fi

# no-op skip（R2-F1）：desired == 原状态 → 不 PUT，仅 live assert
if diff -q "$ARTIFACT_DIR/payload.json" "$ARTIFACT_DIR/rollback-payload.json" >/dev/null; then
  echo "== [5] 已合规（payload == 原状态）→ skip PUT，仅 live assert =="
  assert_and_evidence --mode assert --repo "$REPO" && exit 0
  echo "FAIL: 已合规但 live assert 未过（状态在 snapshot 后被改？）" >&2; exit 1
fi

echo "== [5] 乐观并发 re-read（GET#2，PUT 前防 stale 覆盖；残留 TOCTOU 见 plan #8）=="
"$GH_CMD" api "repos/$REPO/rulesets/$RID" > "$REREAD_RAW"
REREAD_NORM=$(python3 "$BUILDER" --normalize-only --ruleset-json "$REREAD_RAW") \
  || { echo "FAIL: re-read 规范化失败" >&2; exit 1; }
if [ "$REREAD_NORM" != "$(cat "$ARTIFACT_DIR/rollback-payload.json")" ]; then
  echo "FAIL: 并发漂移——snapshot 与 PUT 前 re-read 不一致；abort（不 mutate）" >&2
  exit 1
fi

echo "== [6] apply（PUT payload）→ re-read 分类（PUT 成功/非零都不假设结果）=="
if "$GH_CMD" api -X PUT "repos/$REPO/rulesets/$RID" --input "$ARTIFACT_DIR/payload.json" >/dev/null 2>"$RAW_PUT_ERR"; then
  echo "PUT 返回成功；re-read 确认实际状态（防 eventual-consistency / 并发）" >&2
else
  # R4-F2：原始 stderr 只写 chmod-600 临时；durable artifact 只放 redacted 副本
  echo "FAIL: PUT 非零（状态歧义，可能已 apply）；re-read 判定" >&2
  redact < "$RAW_PUT_ERR" > "$ARTIFACT_DIR/put-error.txt"
fi
# 统一分类器（R4-F1：绝不自动 rollback；并发的合法 ruleset 改动若仍满足谓词则视为成功）
if post_put_classify; then exit 0; fi
exit 1
```

> **注意 mock 契约**：mockgh **有状态**——成功 PUT 校验并持久化提交的 payload 为新 state，后续 GET 返回它（除非 `MOCK_FIXTURE_N<k>` 注入第 k 次 GET 的状态）。apply 路径单 GET 序：GET#1 snapshot、GET#2 并发 re-read、GET#3 = `post_put_classify` 的 re-read（PUT 成功/非零都走它）。因此 N3 注入即模拟「PUT 后实际状态」：`with`=已 apply、`extra-valid`=并发合法改动、`partial`=未知/部分、`malformed`=观测失败、缺省=PUT 未生效（==原状态）。`verify --mode preflight/diff` 与 classifier 的 assert 都走 `--ruleset-json`（离线，不额外 GET）。mockgh PUT 拒绝含只读字段（GitHub 422）→ 手动 rollback-payload 必须 normalize-only。各场景 fixture 组合见下方测试。

- [ ] **Step 4：跑测试确认通过**

Run: `cd "$(git rev-parse --show-toplevel)" && bash tests/scripts/governance/test-admin-runbook.sh`
Expected: 全 PASS，退出 0

- [ ] **Step 5：commit**

```bash
chmod +x scripts/governance/admin-configure-required-checks.sh tests/scripts/governance/test-admin-runbook.sh
git add scripts/governance/admin-configure-required-checks.sh tests/scripts/governance/test-admin-runbook.sh
git commit -m "feat(1b): admin-configure-required-checks.sh runbook + mutation safety contracts + tests"
```

---

## Task 4 — 单命令入口 `run-all.sh` + 全量验证

**Files:**
- Modify: `tests/scripts/governance/run-all.sh`

- [ ] **Step 1：补全 run-all.sh**

Overwrite `tests/scripts/governance/run-all.sh`：

```bash
#!/usr/bin/env bash
# run-all.sh — 1b 全部脚本测试单命令入口（pytest builder + 两个 bash 测试脚本）。
# Usage: bash tests/scripts/governance/run-all.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
rc=0
echo "### pytest: build-protection-put-payload"
python3 -m pytest tests/scripts/governance/test_build_payload.py -q || rc=1
echo "### bash: verify-required-checks"
bash tests/scripts/governance/test-verify-required-checks.sh || rc=1
echo "### bash: admin-runbook"
bash tests/scripts/governance/test-admin-runbook.sh || rc=1
if [ "$rc" -eq 0 ]; then echo "ALL GREEN"; else echo "SOME FAILED"; fi
exit $rc
```

- [ ] **Step 2：跑全量套件**

Run: `cd "$(git rev-parse --show-toplevel)" && bash tests/scripts/governance/run-all.sh`
Expected: `ALL GREEN`，退出 0

- [ ] **Step 3：commit**

```bash
git add tests/scripts/governance/run-all.sh
git commit -m "test(1b): run-all.sh 单命令入口（pytest + 2 bash 套件）"
```

---

## Self-Review（writing-plans 自查，写完 plan 后跑）

**1. Spec coverage**（outline §二 1b 行 + §3.3 1b 子项）：
- builder ✅ Task 1 / 三模式 verifier ✅ Task 2 / admin runbook ✅ Task 3 / 测试矩阵 ✅ run-all + 各 task / mutation safety contracts：artifact schema ✅(test_strips_readonly_fields + payload.json/rollback-payload.json 落地 + no_readonly 断言) / redaction ✅(test_no_token_in_output + runbook redaction 测试) / rollback ✅(assert-fail→rollback PUT>=2，**用 normalize-only rollback-payload 非 raw snapshot**——codex R1-F1) / serialization ✅(test_deterministic_serialization) / idempotency ✅(test_idempotent_when_present + test_fixpoint) / preflight ✅(preflight 模式 + preflight-fail 测试) / failure-mode ✅(malformed/no-rsc/put-fail/non-admin via anysource/**并发漂移 abort**——codex R1-F2)。**不动 origin** ✅（全 mock + dry-run 缺省）。
- H10 finding（ledger stale）✅ 记录在「关键 grounding」#3，归 1c close。
- codex plan R1 两个 high finding ✅（grounding #7）：rollback 形状（normalize-only）+ 乐观并发 re-read（PUT 前比对 abort），均带专门测试。
- codex plan R2 四个 finding ✅（grounding #8）：no-op skip（测试 2）+ PUT-fail 状态分类（测试 4/5）+ TOCTOU 文档化 residual + redaction 源分离（raw 计算 / redacted 审计；测试 10），均带测试或文档。
- codex plan R3 三个 finding ✅（grounding #9）：verifier exit-code 分层 + post-PUT observe-fail 不 rollback（测试 11）+ 有状态 mock 证明 PUT body（测试 3）+ offline verifier name/target 守卫（verifier 测试 tag/wrongname negative）。
- codex plan R4 两个 finding ✅（grounding #10）：取消自动 rollback、统一 `post_put_classify`（谓词检查非字节比对；并发合法改动→成功 测试 6a，未知→人工不 rollback 测试 6b）+ PUT stderr 只落 redacted 副本（测试 12）。
- codex plan R5 一个 finding ✅（grounding #11）：enforcement==active 提到 preflight fail-closed（测试 8b inactive→无 PUT + verifier inactive negative）。
- codex plan R6 两个 finding ✅（grounding #12，user 选项 1）：verifier 加 conditions.ref_name 绑 main 校验（verifier wrong-include/exclude-main negative）+ post_put_classify 成功判据改为「保留不变量 desired ⊆ actual」（测试 6a 合法追加→0 / 6b 未知→1 / 6c 保护流失→1）。
- codex plan R7 三个 finding（grounding #13，user 选项 1 收口）：F1 bypass 精确相等 ✅（测试 6d）+ F2 conditions 通配语义 ✅（verifier wildcard-exclude negative）+ F3 rule-param 深度保留 → **residual**（GitHub 默认 param 回填会 false-negative + 单管理员近乎空操作）。**plan-stage codex 7 轮收口**（findings 2→4→3→2→1→2→3，治理 runbook edge-mining 模式，per `feedback_codex_round6_self_contradiction` + `feedback_outline_no_inline_implementation`）；branch-diff codex 为第二道背靠。

**2. Placeholder scan**：无 TBD/TODO（run-all.sh Task 0 占位明确在 Task 4 补全，非交付残留）。

**3. Type consistency**：`CATALYST_CONTEXT` / `CATALYST` 常量值字节一致（"Mac Catalyst build-for-testing on macos-15"）；`GITHUB_ACTIONS_INTEGRATION_ID` / `APP_ID` = 15368 跨 builder/verifier/test 一致；`build_payload` / `serialize` 函数名跨 script 与 test 一致；`GH_CMD` 注入点跨 verifier + runbook + 测试一致。

---

## 验收 checklist（中文，交付时落 `docs/acceptance/2026-05-20-pr1b-required-checks-scripts.md`）

| # | action（动作） | expected（预期） | pass/fail |
|---|---|---|---|
| 1 | 终端跑 `bash tests/scripts/governance/run-all.sh` | 末行打印 `ALL GREEN`，命令退出码 0 | 退出 0 且见 ALL GREEN = pass |
| 2 | 跑 `bash scripts/governance/verify-required-checks.sh --mode assert --ruleset-json tests/scripts/governance/fixtures/ruleset-with-check.json` | 打印 `OK: 'Mac Catalyst build-for-testing on macos-15' 在位 + integration_id=15368 + enforcement=active`，退出 0 | 见 OK 且退出 0 = pass |
| 3 | 跑 `bash scripts/governance/verify-required-checks.sh --mode assert --ruleset-json tests/scripts/governance/fixtures/ruleset-anysource.json` | 打印含 `integration_id=None != 15368（any-source 伪造风险）`，退出 1 | 见 FAIL 且退出 1 = pass |
| 4 | 跑 `bash scripts/governance/admin-configure-required-checks.sh --artifact-dir /tmp/1b GH_CMD=...`（dry-run，mock 注入见 Task 3） | 打印将变更 diff，**无 PUT**，退出 0 | dry-run 无 mutation = pass |
| 5 | 确认新脚本无 legacy protection API **功能调用**：`git grep -nE 'api[^#]*branches/[^ "'"'"']*/protection' -- scripts/governance/` 零命中（注：脚本注释/docstring 里提到 `branches/main/protection` 是解释「为何改用 rulesets」，不算依赖） | 新脚本仅经 Rulesets API，不调用已 404 的 legacy protection API | 功能调用 grep 零命中 = pass |
| 6 | 确认 1b 改动**不含** `.github/workflows/` 与 `docs/governance/` 文件 | `git diff --name-only main...HEAD` 列表无这两类路径 | 无命中 = pass |
| 7 | run-all 输出里确认 mutation-safety 测试均 PASS：`rollback-payload 无只读字段`（R1-F1）/ `并发漂移 → 1 abort`（R1-F2）/ `apply no-op → 0`（R2-F1）/ `PUT 干净失败 → 1` + `PUT 报错但已 apply → 0`（R2-F2）/ `payload 保留 token 样 context`（R2-F4）/ `PUT body == payload.json`（R3-F2）/ verifier `assert target=tag → 1` + `assert name!=main → 1`（R3-F3）/ `并发合法改动 → 0（不 rollback）` + `未知状态 → 1（人工介入）` + `观测失败 → 1（不 rollback）`（R4-F1）/ `PUT-failure artifact 无 token`（R4-F2）/ `inactive → 1（fail-closed）`（R5-F1）/ verifier `assert wrong-include → 1` + `assert exclude-main → 1` + `assert wildcard-exclude → 1`（R6-F1/R7-F2）/ `并发合法追加 → 0` + `保护流失(Catalyst在但少规则) → 1`（R6-F2）/ `多 bypass actor → 1`（R7-F1） | codex R1-R7 全部 finding 的契约落实（R7-F3 见 plan grounding #13 residual） | 全部 PASS = pass |

> 禁忌词自查（per `.claude/workflow-rules.json`）：本 checklist 不含「验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine」。

---

## Execution Handoff

Plan 完成保存至 `docs/superpowers/plans/2026-05-20-pr1b-required-checks-scripts.md`。
按 user 指令流程：先 `codex:adversarial-review`（plan-stage）到收敛 → `subagent-driven-development` 实施 → `verification-before-completion` → `requesting-code-review` → `codex:adversarial-review`（branch-diff）到收敛。
