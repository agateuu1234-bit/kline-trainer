---
phase_delivery: true
phase_delivery_note: governance/execution plan → acceptance = 机制验证（origin required check 已配且机器可断言 + redacted 证据可复现 + ledger H8/H10 close），非业务功能验收
anchor: Wave 1 顺位 1c
source_outline: docs/superpowers/specs/2026-05-19-wave1-outline-design.md（§二 1c 行 + §3.3）
upstream_plan: docs/superpowers/plans/2026-05-20-pr1b-required-checks-scripts.md（runbook + verifier + builder + 全部 mutation safety contracts）
ledger: docs/governance/2026-05-17-wave0-signoff-ledger.md（H8 / H10 close）
---

# Wave 1 顺位 1c — Required-checks admin execute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐 task 实施本 plan。步骤用 checkbox（`- [ ]`）追踪。
> **关键约束：本 plan 不引入新 script、不定义新 safety contract。** 若执行中发现 1b 的 artifact/rollback/preflight/redaction 任一契约缺失或 stale → **fail-closed 退回 1b 补**，不在 1c 内修脚本。

**Goal:** 由仓库管理员（@agateuu1234-bit）在本机执行 1b 已 ship 并测过的 `admin-configure-required-checks.sh`，对 origin `main` 分支 ruleset 落实 / 确认 Catalyst required check（context `Mac Catalyst build-for-testing on macos-15` + 绑 GitHub Actions app `integration_id=15368`），采集 redacted 证据 commit 进仓库，并回填 §15.4 ledger 关闭 H8 + H10。

**Architecture:** 1c **零生产代码 / 零新脚本 / 零 origin mutation**（预期路径 A）。四类仓库改动：(1) 新建 redacted 证据文件 + 完整 snapshot；(2) ledger H8 / H10 两行 backfill（标记 close + 修正 H10 stale 验证命令为 rulesets API + `verify-required-checks.sh --mode assert`）；(3) acceptance 清单；(4) 本 plan。origin 侧仅**只读** dry-run + assert（grounding #2：Catalyst check 已在位 = 幂等 no-op，**1c 从不跑 `--apply`**）；若 dry-run 显示 origin 已偏离需真 PUT（路径 B）→ fail-closed 退回 1b（grounding #13），真 mutation 不在 1c 做。本 session 的 `gh` 已被权限拒绝，故所有只读 origin 命令由 user 用 `!` 执行、Claude 据回贴输出回填证据。

**Tech Stack:** 既有 1b 脚本（`scripts/governance/admin-configure-required-checks.sh` + `verify-required-checks.sh` + `build-protection-put-payload.py`）、`gh` CLI（admin scope，user 本机已登录）、Markdown 文档。无新增依赖。

---

## 关键 grounding（写 plan 前已核实，2026-05-21）

1. **1c scope = 执行 + 回填，不写代码。** outline §3.3：「1c admin local execute 1b 已 ship 并测过的 runbook + commit redacted artifact + ledger 回填（**不引入新 script 代码、不定义新 safety contract**——若 1b contract 缺失或 stale，1c fail-closed 退回 1b 补）」。
2. **大概率幂等 no-op（最安全首跑）。** 1b plan grounding #2 记录：origin `main` ruleset 的 `required_status_checks` 数组已含 `{"context":"Mac Catalyst build-for-testing on macos-15","integration_id":15368}`。故 apply 走 runbook 的 **no-op skip 路径**（`payload.json == rollback-payload.json` → skip PUT，仅 live assert + 写 evidence → exit 0）。**dry-run 必须先确认此事实**；若 dry-run 显示有变更（check 被移除 / 解绑），则进真 PUT 路径——见 Task 2 分支处理 + 显式确认门。
3. **源真相 = Rulesets API，非 legacy branch-protection。** `gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection` 返回 404；保护全在 ruleset。verifier / runbook 已按此实现（读 `rulesets` + `integration_id`，非 `branches/main/protection` + `app_id`）。
4. **ledger H10 当前验证命令 stale，由 1c 修正。** 现 H10 行写 `gh api .../branches/main/protection --jq '.required_status_checks.checks[] | select(.context==...) | .app_id==15368'`——指向 legacy 404 API + legacy 字段 `.app_id`。1c 回填：改为 rulesets API 的机器可检查谓词，权威断言入口 = `bash scripts/governance/verify-required-checks.sh --mode assert`（assert OK 即 H10 谓词成立）。**1b 已记录该 finding 归 1c close（1b 不动 `docs/governance/`）。**
5. **catalyst-build 已是独立 always-trigger workflow（1a 交付）。** `.github/workflows/catalyst-build.yml` job name `Mac Catalyst build-for-testing on macos-15`（= required check context），无 paths filter（H9 已解）。1c 配 required gate 与该 workflow 配套闭合 H8。
6. **trust-boundary + codeowners 双重守护。** `docs/governance/**` 同时在 `trust_boundary_globs` 与 `codeowners_required_globs`（`.claude/workflow-rules.json` L13 / L83）。故本 PR：(a) 走 `codex:adversarial-review`；(b) 需 user CODEOWNERS Approve。
7. **runbook 缺省 dry-run，`--apply` 才 mutate；`--artifact-dir DIR` 落 4 件 artifact**：`ruleset-snapshot.json`（redacted，安全 commit）、`verify-evidence.txt`（redacted，安全 commit）、`payload.json` + `rollback-payload.json`（功能性 ruleset config，无 secret）。redact() 剥离 `$GH_TOKEN` 实值 + `ghp_*` / `github_pat_*` 样式串。**只 commit 两个 redacted 文件的内容**（snapshot + verify-evidence），payload/rollback 不入仓（噪音 + 非证据）。
8. **`~DEFAULT_BRANCH` residual（1b branch-diff R4）的 1c 处理**：1b 脚本把 `~DEFAULT_BRANCH` 无条件当 main，未 live 核实。1c **不改脚本**，但在执行证据中加一条只读断言 `gh api repos/agateuu1234-bit/kline-trainer --jq .default_branch` == `main`，**为本次执行**证明 `~DEFAULT_BRANCH`=main 成立（不消除 1b 的代码层 residual，仅为本 run 留痕）。
9. **本 session gh 受限 + `!` 是 Claude Code 前缀不是 shell 内容（codex R12-F1）**：Claude 的 `gh` 调用已被权限拒绝。故所有 origin 命令由 **user 执行**：在 **Claude Code 提示符**前面打 `!` 再粘贴下方 code block（`!` 是 Claude Code 的 run-bash 前缀，会在本会话跑、输出回到对话），**或**直接在终端跑 code block。**code block 内已不含 `!`**——`!` 一旦粘进 zsh/bash 会被当 history-expansion / pipeline 取反，破坏命令；故本 plan 所有 code block 从 `mkdir`/`cd`/`GH_BIN` 起头，user 自行决定加不加 Claude Code 的 `!` 前缀。Claude 据回贴输出回填证据。
10. **canonical safe invocation（codex plan-stage R1-F1 + R4-F1，防 ambient env / host 污染目标）**：1b 脚本 honor ambient `REPO="${REPO:-...}"` / `GH_CMD="${GH_CMD:-gh}"`，测试 harness 用 `GH_CMD`=mock + `MOCK_*` 注入无网络替身，且 `gh api repos/...` 用 ambient `GH_HOST`（若设，指向 enterprise host）。若 admin shell 残留这些 env，origin 命令可能对 fork / mock / 错 host 跑而证据却声称保护了真仓。**故所有 origin 命令必须**：(a) 清污染 env + 强制 host=github.com：`env -u REPO -u MOCK_FIXTURE -u MOCK_LOG -u MOCK_PUT_FAIL -u MOCK_LIST_ID GH_HOST=github.com`；(b) 显式 `--repo agateuu1234-bit/kline-trainer` 固定目标；(c) **pin 真 gh 绝对路径**（codex R6-F2：仅 `-u GH_CMD` 会回落 PATH 解析 `gh`，PATH wrapper / shell function / 同名 mock 可骗过 guard 喂假数据）——先 `GH_BIN=$(command -v gh)` 解析，断言落在 allowlist（`/opt/homebrew/bin/gh` | `/usr/local/bin/gh` | `/usr/bin/gh`，镜像 `codex-attest.sh` 的 node pin），再以 `GH_CMD="$GH_BIN"`（**非 `-u GH_CMD`**）传脚本 / 用 `"$GH_BIN" api` 调裸命令。**host/repo 前置 guard**（每次 origin 命令前跑一次）：`gh auth status --hostname github.com` + `git remote get-url origin` 含 `github.com[:/]agateuu1234-bit/kline-trainer`。本 plan 所有 origin 命令已带此 pin + 前缀/后缀；evidence 记录 `GH_BIN` 绝对路径 + host guard 输出。

**统一前缀（每条 origin 命令复用）**：`GH_BIN=$(command -v gh); case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL: 不可信 gh 路径 $GH_BIN" >&2; exit 1;; esac`
11. **no-op 不 apply（codex plan-stage R1-F2，防 stale 授权变 mutation）**：runbook `--apply` 在 apply 时取**新** snapshot，若该新 payload != rollback 就 PUT；它不校验"当前状态仍等于 user 授权 dry-run 时的状态"。Task1 dry-run→Task2 apply 之间的漂移会把已授权 no-op 变成未审 mutation。**故**：dry-run = no-op → **绝不跑 `--apply`**，仅跑 live assert（gate 已在位，assert OK 即闭 H8/H10）；dry-run = 需变更 → 见 grounding #13：**fail-closed 退回 1b**（1b 缺 pre-PUT payload 绑定契约，1c 不在缺契约下 mutate）。
12. **reviewed-tree 铁律（codex R3-F1 + R13-F1，防未审脚本驱动 origin）**：runbook 从 **working tree** 执行；若 `scripts/governance/`、`tests/scripts/governance/`、`.github/workflows/` 三路径有改动（**committed vs main 或 working-tree**），未审脚本会驱动 origin 而 branch-diff 仍显示"无脚本改动"。**故每条跑脚本的 origin 命令前**，须机器绑定（不靠人读 `echo "$?"`，codex R7-F2/R8-F1：`git status --porcelain` 脏也 exit 0）：base ref 真存在 + committed-scope 空 + working-tree 空（含未追踪）+ 无 staged/unstaged diff。**canonical guard 子 shell**（返回非零即偏离，`&&` 链在脚本前，偏离则脚本根本不跑；用字面路径不用 `$P`——zsh 不 word-split 无引号变量）：
```
( git rev-parse --verify main >/dev/null && [ -z "$(git diff --name-only main...HEAD -- scripts/governance tests/scripts/governance .github/workflows)" ] && [ -z "$(git status --porcelain -- scripts/governance tests/scripts/governance .github/workflows)" ] && git diff --quiet -- scripts/governance tests/scripts/governance .github/workflows && git diff --cached --quiet -- scripts/governance tests/scripts/governance .github/workflows )
```
任一不满足（base 缺失 / committed 改了脚本 / 未追踪文件 / 脏树）→ 子 shell 非零 → `&&` 短路阻断 origin 命令（即使 Task 0 后发生 commit/rebase/branch-switch 也每次重检——codex R13-F1）。clean HEAD SHA 记入 evidence。
13. **Path B（真 mutation）不在 1c scope —— fail-closed 退回 1b（codex plan-stage R3-F2 + R4-F2）**：真 PUT 的安全落实需要"apply 前按已审 payload sha 绑定、不符即 abort（PUT 之前）"，而 runbook `--apply` 是从 fresh snapshot 重建 payload 再 PUT、只能 PUT 之后才比对 sha——这要求 1b 脚本新增 `--expected-payload-sha` pre-PUT 绑定 + `--hostname` host pin。**1c 章程禁止改脚本/定义新契约**，故：dry-run 显示需变更（或 assert 失败）= origin 已偏离预期 no-op 基线 = **1b 契约不足以安全 mutate** → **1c fail-closed 停止，退回 1b 补 `--expected-payload-sha` + host pin 契约**，补完再以新 1c 续跑。**1c 只覆盖 Path A**（预期 no-op：dry-run 确认 + 独立 assert + 最终态 snapshot），不在 1c 内做真 PUT。grounding #2 表明 origin 当前已合规，Path A 即预期路径。

---

## File Structure

| 文件 | 类型 | 责任 |
|---|---|---|
| `docs/governance/2026-05-21-pr1c-required-checks-evidence.md` | 证据 (新建) | redacted dry-run diff + （no-op 路径）live assert 输出 / （需变更路径）apply 控制台输出 + `verify --mode assert` 输出 + default_branch 断言 + 完整 redacted snapshot 的 sha256 + 执行 meta（日期 / commit SHA / canonical safe invocation 声明） |
| `docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json` | 证据 (新建) | post-assert 最终态 origin `main` ruleset 的**完整 redacted** GET JSON（codex R1-F3：reviewer 可审计执行时的 conditions / bypass_actors / 全部 rules，而非 merge 后的 live 漂移）；其 sha256 在 evidence 文件中与 assert 输出绑定 |
| `docs/governance/2026-05-17-wave0-signoff-ledger.md` | ledger (改) | H8 行 + H10 行 backfill：标记 ✅ close + 修正 H10 stale 命令 + 指向 evidence 文件 + iOS 代表 sign-off 第 6 项 H8/H9/H10 收口注记（仅这几处，不动其它行） |
| `docs/acceptance/2026-05-21-pr1c-required-checks-admin-execute.md` | acceptance (新建) | 非编码者验收清单（动作 / 预期 / 通过判据；中文；禁忌词自查） |
| `docs/superpowers/plans/2026-05-21-pr1c-required-checks-admin-execute.md` | plan (本文件) | 本实施计划 |

**显式不动**：`scripts/governance/**`、`tests/scripts/governance/**`、`.github/workflows/**`、`kline_trainer_*.md`、任何业务代码。Task 0 用 git diff 守这条。

---

## Task 0 — §15.3 评审策略前置 + 1b 契约完整性门 + scope 守约

> 前置任务，完成才进 Task 1。per `docs/governance/wave1-plan-template.md`。

- [ ] **§15.3 评审策略声明**：本 plan 适用 **局部对抗性评审（必）**——1c scope 内 `codex:adversarial-review`，plan-stage + branch-diff 各 4-5 轮内收敛或 escalate（per `feedback_codex_plan_budget_overshoot`）。不适用集成层评审（无 C8/E5 桥接）/ 性能评审（非 Phase 5）。

- [ ] **Step 1：reviewed-tree gate（grounding #12 canonical guard；committed-scope + working-tree 双查）**

Run: `cd "$(git rev-parse --show-toplevel)" && ( git rev-parse --verify main >/dev/null && [ -z "$(git diff --name-only main...HEAD -- scripts/governance tests/scripts/governance .github/workflows)" ] && [ -z "$(git status --porcelain -- scripts/governance tests/scripts/governance .github/workflows)" ] && git diff --quiet -- scripts/governance tests/scripts/governance .github/workflows && git diff --cached --quiet -- scripts/governance tests/scripts/governance .github/workflows ); rc=$?; echo "guard 退出码=$rc"; [ "$rc" = 0 ] && git rev-parse HEAD`
Expected: `guard 退出码=0` + 打印 clean HEAD SHA（base ref 存在 + 三路径 committed vs main 无改动 + working-tree 无改动/未追踪 + 无 staged/unstaged diff）。

含义：脚本 / 测试 / workflow 三路径相对 main 必须**既未 committed 改动、也 working-tree 干净**——否则未审脚本会驱动 origin 而 branch-diff 仍假称"无脚本改动"。**rc≠0 → 停止**：还原误改，或（若 1b 真缺陷）fail-closed 退回 1b。**真正机械绑定**靠 grounding #12 canonical guard 用 `&&` 链在每条 origin 脚本命令前（Task 1 Step 3 / A-Step1 / A-Step2 均已内联，即使 Task 0 后 commit/rebase 也每次重检）。打印的 HEAD SHA 入 evidence。

- [ ] **Step 2：1b 契约完整性门（fail-closed 退回 1b 的判据）**

Run: `cd "$(git rev-parse --show-toplevel)" && bash tests/scripts/governance/run-all.sh`
Expected: 末行 `ALL GREEN`，退出码 `0`，统计 `PASS=60 / FAIL=0`。

含义：run-all 绿 = 1b 的全部 mutation safety contract（artifact schema / redaction / rollback / serialization / idempotency / preflight / failure-mode）在当前 HEAD 完整可复现。**若非 ALL GREEN → 立即停止 1c，退回 1b 修脚本/契约**（grounding #1 的 fail-closed 路径），不在 1c 内改 `scripts/governance/`。

- [ ] **Step 3：scope 守约——确认尚无越界改动（committed diff）**

Run: `cd "$(git rev-parse --show-toplevel)" && { git rev-parse --verify main >/dev/null && files=$(git diff --name-only main...HEAD -- scripts/governance tests/scripts/governance .github/workflows) && { [ -n "$files" ] && printf '%s\n' "$files"; [ -z "$files" ]; }; }; rc=$?; echo "scope 退出码=$rc"; [ "$rc" -eq 0 ]`
Expected: 无文件输出，`scope 退出码=0`，命令进程退 0（codex R9-F2 + R10-F1：`{ git rev-parse --verify main && files=$(git diff -- <paths>) && { 打印; [ -z "$files" ]; }; }; rc=$?` 把 base-ref 失败 / diff 失败 / 有越界文件全归入非零 rc；**末尾 `[ "$rc" -eq 0 ]` 令进程状态机械反映、不被 `echo` 掩盖**）。

含义：1c 全程不得改脚本 / 测试 / workflow（committed 层）。`scope 退出码≠0` → 有越界改动或 base ref 异常 → 停止。

- [ ] **Step 4：commit 本 plan 文档**

```bash
git add docs/superpowers/plans/2026-05-21-pr1c-required-checks-admin-execute.md
git commit -m "docs(1c): writing-plans — required-checks admin execute plan"
```

---

## Task 1 — Origin dry-run（确认 no-op / 发现真状态）

**Files:** 无文件改动（采集证据；写入 Task 3 的证据文件）。
**执行方式:** user 用 `!` 在终端跑（grounding #9）；Claude 据回贴输出判定。

- [ ] **Step 1：建本地 artifact 目录 + host/repo guard（user 跑；grounding #10）**

**所有 origin 命令前置门**：先复跑 Task 0 Step 1 clean-tree gate（grounding #12），再跑 host/gh guard。**guard 不 dump 原始 `auth status` / remote URL**（codex R10-F2：remote URL 可能内嵌 `user:token@`）——auth 仅断言成败、remote URL 先 `sed` 剥 userinfo 再断言匹配，只把 sanitized 结果记入 evidence：
```bash
cd "$(git rev-parse --show-toplevel)" && mkdir -p /tmp/pr1c-artifacts && GH_BIN=$(command -v gh) && { case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL: 不可信 gh 路径 $GH_BIN" >&2; exit 1;; esac; } && { "$GH_BIN" auth status --hostname github.com >/dev/null 2>&1 || { echo "FAIL: 未登录 github.com" >&2; exit 1; }; } && RE='^(https://github\.com/|git@github\.com:)agateuu1234-bit/kline-trainer(\.git)?$' && fsan=$(git remote get-url origin | sed -E 's#://[^/@]*@#://#') && psan=$(git remote get-url --push origin | sed -E 's#://[^/@]*@#://#') && printf '%s\n' "$fsan" | grep -qE "$RE" && printf '%s\n' "$psan" | grep -qE "$RE" && echo "GH_BIN=$GH_BIN | host=github.com auth OK | origin fetch(sanitized)=$fsan | push(sanitized)=$psan | guard OK"
```
Expected: 打印一行 `GH_BIN=<allowlist 绝对路径> | host=github.com auth OK | origin fetch(sanitized)=...github.com/agateuu1234-bit/kline-trainer... | push(sanitized)=... | guard OK`，命令进程退 0（codex R13-F2：host 用**锚定** regex `^(https://github\.com/|git@github\.com:)agateuu1234-bit/kline-trainer(\.git)?$` 拒 `evilgithub.com` / `github.com.evil.com`；fetch + push 双 remote 都校验）。任一断言失败 → 进程非零 → 停止 escalate user。**只把这行 sanitized 结果记入 evidence**（不记原始 auth/URL）。

- [ ] **Step 2：只读断言 default_branch == main（user 跑；grounding #8 + #10，pin host + gh）**

```bash
GH_BIN=$(command -v gh); { case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL: 不可信 gh 路径 $GH_BIN" >&2; exit 1;; esac; }; out=$(env GH_HOST=github.com "$GH_BIN" api repos/agateuu1234-bit/kline-trainer --jq '.default_branch'); echo "default_branch=$out"; [ "$out" = main ]
```
Expected: 打印 `default_branch=main`，命令进程**退出码 0**（pin `GH_HOST=github.com` + 绝对 `GH_BIN` 防 host/PATH 污染——codex R5-F1 + R6-F2；末尾 `[ "$out" = main ]` 令进程状态机械反映断言——codex R9-F1；此结果是 H8/H10 close 双谓词之一）。
判定：进程非 0（`out` 非 `main`）→ 停止，escalate user（1b 的 `~DEFAULT_BRANCH` 假设对本仓不再成立，需先处理）。

- [ ] **Step 3：dry-run runbook（user 跑；缺省不 mutate）**

**前置门已机械内联**：命令以 clean-tree 子 shell（grounding #12）`&&` 开头——脏树则脚本根本不跑（codex R8-F1）。

```bash
cd "$(git rev-parse --show-toplevel)" && ( git rev-parse --verify main >/dev/null && [ -z "$(git diff --name-only main...HEAD -- scripts/governance tests/scripts/governance .github/workflows)" ] && [ -z "$(git status --porcelain -- scripts/governance tests/scripts/governance .github/workflows)" ] && git diff --quiet -- scripts/governance tests/scripts/governance .github/workflows && git diff --cached --quiet -- scripts/governance tests/scripts/governance .github/workflows ) && GH_BIN=$(command -v gh) && { case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL: 不可信 gh 路径 $GH_BIN" >&2; exit 1;; esac; } && env -u REPO -u MOCK_FIXTURE -u MOCK_LOG -u MOCK_PUT_FAIL -u MOCK_LIST_ID GH_HOST=github.com GH_CMD="$GH_BIN" bash scripts/governance/admin-configure-required-checks.sh --repo agateuu1234-bit/kline-trainer --artifact-dir /tmp/pr1c-artifacts
```
（canonical safe invocation，grounding #10/#12：clean-tree `&&` 机械阻断 + 清 ambient env + 强制 `GH_HOST=github.com` + pin 绝对 `GH_CMD="$GH_BIN"` + 显式 `--repo`）
Expected（no-op 路径，grounding #2）：依次打印
- `== [1] 发现 ruleset id ==`
- `== [2] snapshot（GET#1：raw 供计算 + redacted 审计副本）==`
- `== [3] preflight（对 raw snapshot，不额外 GET）==` → `OK: preflight（...）`
- `== [4] build 双 payload（从 raw snapshot）==`
- `== [5] dry-run（不 mutate）==`
- `diff（payload vs 当前 required_status_checks）:` + `  （无变更——已是 desired 状态，幂等 no-op）`
- `dry-run 完成；加 --apply 才真改。artifact: /tmp/pr1c-artifacts`
退出码 `0`。

- [ ] **Step 4：判定 dry-run 结果（Claude 据回贴输出）**

- **若 diff 显示「（无变更——已是 desired 状态，幂等 no-op）」** → 确认 no-op → **Task 2 路径 A**（host guard + assert + 最终态 snapshot，零 mutation）。
- **若 diff 显示「+ 新增 Mac Catalyst...」或「~ 修正 ... integration_id」** → check 被移除/解绑，需真 mutation → **Task 2 路径 B：fail-closed 退回 1b**（grounding #13；不在 1c 做真 PUT）。
- **若 preflight FAIL（exit 1）** → ruleset 漂移（非 active / 不绑 main / 含非 admin bypass / 无 rsc 规则）。**停止**，escalate user：origin ruleset 处于不安全/不达标状态，1c 不在此状态下 mutate；需 admin 先在 GitHub UI 修复 ruleset 基线，或退回 1b 评估契约。

---

## Task 2 — Origin 落实/确认（仅 Path A 真执行；Path B fail-closed 退回 1b）

**Files:** 无文件改动（采集证据）。
**执行方式:** user 用 `!` 跑。**核心安全约束（grounding #11 + #13）：dry-run = no-op（Path A，预期）→ 绝不跑 `--apply`，仅 live assert + 最终态 snapshot；dry-run = 需变更 或 assert 失败（Path B）→ origin 已偏离 no-op 基线、1b 缺 pre-PUT payload 绑定契约 → 1c fail-closed 停止退回 1b，不在 1c 做真 PUT。** 远端写入永远要 user explicit confirm（per `feedback_reviewer_verdict_not_authorization`）。

### 路径 A — Task 1 dry-run = no-op（grounding #2 预期路径，**零 mutation**）

- [ ] **A-Step 1：host/repo guard + 独立 live assert（user 跑）**

**前置门**：先跑 Task 1 Step 1 host/gh guard（auth + remote）；assert 命令本身已 `&&` 内联 clean-tree 子 shell（脏树不跑）。

assert：
```bash
cd "$(git rev-parse --show-toplevel)" && ( git rev-parse --verify main >/dev/null && [ -z "$(git diff --name-only main...HEAD -- scripts/governance tests/scripts/governance .github/workflows)" ] && [ -z "$(git status --porcelain -- scripts/governance tests/scripts/governance .github/workflows)" ] && git diff --quiet -- scripts/governance tests/scripts/governance .github/workflows && git diff --cached --quiet -- scripts/governance tests/scripts/governance .github/workflows ) && GH_BIN=$(command -v gh) && { case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL: 不可信 gh 路径 $GH_BIN" >&2; exit 1;; esac; } && { env -u REPO -u MOCK_FIXTURE -u MOCK_LOG -u MOCK_PUT_FAIL -u MOCK_LIST_ID GH_HOST=github.com GH_CMD="$GH_BIN" bash scripts/governance/verify-required-checks.sh --mode assert --repo agateuu1234-bit/kline-trainer; rc=$?; echo "退出码=$rc"; [ "$rc" -eq 0 ]; }
```
Expected: 打印 `OK: main branch ruleset + 绑默认分支 + active + 'Mac Catalyst build-for-testing on macos-15' 在位 + integration_id=15368 + bypass 仅 admin`，`退出码=0`，且命令进程退 0（codex R9-F1：末尾 `[ "$rc" -eq 0 ]` 令进程状态机械反映 verify，不被 `echo` 掩盖；clean-tree / gh-pin 失败则 `&&` 短路、verify 根本不跑）。
含义：gate 已在位（no-op 即"已合规"），assert OK = H10 谓词在 origin 真成立 + H8 gate 已配置闭合。**全程零 PUT、零 mutation**。
判定：进程非 0 时看打印的 `退出码`——`退出码=1`（谓词假）→ 转**路径 B**；`退出码=3`（观测失败）→ 停止 escalate user。

- [ ] **A-Step 2：采集 post-assert 最终态 redacted snapshot（user 跑；codex R2-F1）**

assert 返回 `退出码=0` **之后**（时序铁律），跑 fresh dry-run 取最终态，并**机械**验证 no-op + 对**将提交的同一份 snapshot 文件**做 offline 断言（codex R11-F1 + R12-F2：dry-run 即使"会加 check"也 exit 0，不能靠人读；且 assert 必须断言**被提交的那份 JSON** 而非另一次 live 读，杜绝 snapshot↔assert 漂移）。`diff -q payload rollback` 仅当字节相等（= 幂等 no-op = gate 在位）才 0；随后 `verify --mode assert --ruleset-json /tmp/pr1c-final/ruleset-snapshot.json`（offline，断言即将 commit 的那份）；全 `&&` 链，任一失败即不出 sha、命令非零：
```bash
cd "$(git rev-parse --show-toplevel)" && ( git rev-parse --verify main >/dev/null && [ -z "$(git diff --name-only main...HEAD -- scripts/governance tests/scripts/governance .github/workflows)" ] && [ -z "$(git status --porcelain -- scripts/governance tests/scripts/governance .github/workflows)" ] && git diff --quiet -- scripts/governance tests/scripts/governance .github/workflows && git diff --cached --quiet -- scripts/governance tests/scripts/governance .github/workflows ) && GH_BIN=$(command -v gh) && { case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL: 不可信 gh 路径 $GH_BIN" >&2; exit 1;; esac; } && env -u REPO -u MOCK_FIXTURE -u MOCK_LOG -u MOCK_PUT_FAIL -u MOCK_LIST_ID GH_HOST=github.com GH_CMD="$GH_BIN" bash scripts/governance/admin-configure-required-checks.sh --repo agateuu1234-bit/kline-trainer --artifact-dir /tmp/pr1c-final && diff -q /tmp/pr1c-final/payload.json /tmp/pr1c-final/rollback-payload.json && bash scripts/governance/verify-required-checks.sh --mode assert --ruleset-json /tmp/pr1c-final/ruleset-snapshot.json >/dev/null && echo "FINAL = no-op + assert(offline,绑定同一 snapshot) OK（gate 在位）" && shasum -a 256 /tmp/pr1c-final/ruleset-snapshot.json
```
Expected:
- 打印 `FINAL = no-op + assert(offline,绑定同一 snapshot) OK（gate 在位）` + snapshot sha256，命令进程退 0。
- **若 check 在 A-Step1 后漂移走** → `diff -q payload rollback` 非零（payload 会重新加 check ≠ rollback）或 offline assert 失败 → `&&` 短路、不出 sha、命令非零 → **停止 escalate user**（不能用未受保护态 close H8/H10）。
- 此处 offline assert 断言的就是 `/tmp/pr1c-final/ruleset-snapshot.json`，即 Task 3 Step 2 将 `cp` 入仓的同一份——snapshot 与"通过断言的状态"字节一致。
Claude 操作（codex R6-F3：机器绑定，不手工转录）：用 `cp` 把 `/tmp/pr1c-final/ruleset-snapshot.json` **直接复制**为 `docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json`（Task 3 Step 2），并 `cmp -s` 核对 + 双方 sha256 一致后才入仓；sha256 记入 evidence §4。
**Claude 自检**：snapshot 不得含 `ghp_` / `github_pat_` / 疑似 token；若发现 → 停止，提示 redact 未生效（fail-closed 退回 1b 评估 redaction 契约）。

### 路径 B — Task 1 dry-run = 需变更 或 assert 失败（**fail-closed 退回 1b，不在 1c mutate**）

- [ ] **B（唯一步）：停止 + 退回 1b（grounding #13；codex R3-F2 + R4-F2）**

触发条件：Task 1 dry-run 显示需变更（check 缺失/解绑），**或** A-Step1 assert 返回谓词假。含义：origin 已偏离预期 no-op 基线，需对 ruleset 做真 PUT；而安全真 PUT 需"apply 前按已审 payload sha 绑定、不符即 PUT 之前 abort"——这是 1b 脚本缺的契约（`--expected-payload-sha` pre-PUT 绑定 + `--hostname` host pin）。

动作：**1c 在此 fail-closed 停止**，escalate user，发起 1b 增强（加 `--expected-payload-sha` pre-PUT 绑定 + `--hostname` host pin + 对应 fixtures/tests + run-all 覆盖），1b 补完 merge 后再以新一轮 1c 续跑真 apply。**1c 绝不在缺契约下做真 mutation。**

（理由：grounding #2 表明 origin 当前已合规，Path B 属意外漂移；与其在 1c 里用程序化补丁做带瑕疵的真 PUT 绑定——codex 已反复证明它只能"PUT 之后"检测不一致、无法"PUT 之前"abort——不如退回 1b 把绑定做进脚本，严格符合 1c「不定义新 safety contract / 契约缺失则 fail-closed 退回 1b」章程。）

---

## Task 3 — 新建 redacted 证据文件（含完整 snapshot）

**Files:**
- Create: `docs/governance/2026-05-21-pr1c-required-checks-evidence.md`
- Create: `docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json`（codex R1-F3：完整 redacted snapshot 入仓供审计）

- [ ] **Step 1：写证据文件**

Create `docs/governance/2026-05-21-pr1c-required-checks-evidence.md`，结构如下（`{...}` 由 Task 1/2 实际回贴输出填入；全部为 redacted 内容）：

```markdown
# PR 1c — Required-checks admin execute 证据（redacted）

> 本文件记录 1c 对 origin `main` ruleset 执行 1b runbook 的 redacted 证据。
> 源脚本（未改动）：`scripts/governance/admin-configure-required-checks.sh` + `verify-required-checks.sh`。
> 所有 token 已由 runbook `redact()` 剥离（`$GH_TOKEN` 实值 + `ghp_*` / `github_pat_*`）。

## 执行 meta
- 执行日期：2026-05-21
- 执行人：@agateuu1234-bit（仓库管理员，本机 `gh` admin scope）
- 仓库：`agateuu1234-bit/kline-trainer`（所有命令显式 `--repo` 固定）
- canonical safe invocation：所有 origin 命令带 `env -u REPO -u MOCK_FIXTURE -u MOCK_LOG -u MOCK_PUT_FAIL -u MOCK_LIST_ID GH_HOST=github.com GH_CMD="$GH_BIN"` + `--repo agateuu1234-bit/kline-trainer`（grounding #10：清 ambient env + 强制 host=github.com + pin gh 绝对路径，防对 fork/mock/错 host/PATH-wrapper 误跑）
- host/gh guard（**sanitized**，codex R10-F2：不记原始 auth/URL，origin URL 已 `sed` 剥 userinfo）：`{Task1 Step1 那行 "GH_BIN=... | host=github.com auth OK | origin(sanitized)=... | guard OK"}`
- clean script-tree HEAD（grounding #12）：`{git rev-parse HEAD}`
- default_branch 断言（H8/H10 close 双谓词之一，codex R2-F2）：`{Task1 Step2 输出}` == `main` ✅（live 核实，补 assert 内部 `~DEFAULT_BRANCH` 不 live 之缺）
- 执行路径：**路径 A（no-op，零 mutation）**（grounding #11/#13；路径 B 不在 1c 执行 = fail-closed 退回 1b）

## 1. dry-run（确认幂等 no-op，未 mutate）
```
{Task1 Step3 完整控制台输出}
```
判定：`{no-op（→ Path A） / 需变更（→ Path B：fail-closed 退回 1b）}`。

## 2. 落实/确认
- 路径 A（no-op，本次执行路径）：**未跑 `--apply`、零 mutation**；仅 host guard + 独立 live assert（见 §3）。
- 路径 B（需变更）：本次未触发；若触发则 1c fail-closed 退回 1b 补 `--expected-payload-sha` + host pin 契约（grounding #13），不在 1c mutate。

## 3. 独立 live assert（H10 机器可检查谓词，权威断言）
命令：`env ... GH_HOST=github.com ... verify-required-checks.sh --mode assert --repo agateuu1234-bit/kline-trainer`
```
{Task2 A-Step1 assert 输出}
```
退出码：`0`（host/gh guard 见 meta 的 sanitized 行）。

## 4. 完整 redacted snapshot（post-assert 最终态，绑定 sha256）
- 文件：`docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json`（取自**最后一次 assert 之后**的 fresh dry-run `/tmp/pr1c-final/ruleset-snapshot.json`，反映 origin 最终受保护状态，已剥 token——codex R2-F1）
- sha256：`{Task2 A-Step 2 shasum 输出}`
- 关键字段速览：required_status_checks 含 `Mac Catalyst build-for-testing on macos-15`（integration_id=15368）✅ + `{其它 check}`；enforcement=`active`；conditions.ref_name.include=`{...}`；bypass_actors=`{仅 admin}`。
```

- [ ] **Step 2：机器绑定复制完整 redacted snapshot 文件（codex R6-F3，不手工转录）**

直接 `cp` 生成的 artifact 入仓 + `cmp -s` 字节核对 + sha256 双向一致（绑定到 live 命令产物，杜绝转录/截断/编辑漂移）：
```bash
cd "$(git rev-parse --show-toplevel)" && cp /tmp/pr1c-final/ruleset-snapshot.json docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json && cmp -s /tmp/pr1c-final/ruleset-snapshot.json docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json && shasum -a 256 /tmp/pr1c-final/ruleset-snapshot.json docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json && echo "BOUND OK"
```
Expected: `cmp` 静默通过 + 两 sha256 相等 + 打印 `BOUND OK`。保留完整 conditions / bypass_actors / 全部 rules，供 reviewer 审计执行时真实状态。

- [ ] **Step 3：自检两个证据文件无 token + snapshot 仍绑定 artifact**

Run（fail-closed secret 扫描，codex R10-F2 + R11-F2：多个 `-e` 真 alternation，覆盖全 token 前缀 + basic-auth URL，发现即非零）: `cd "$(git rev-parse --show-toplevel)" && out=$(grep -nE -e 'gh[pousr]_' -e 'github_pat_' -e '://[^/[:space:]@]+:[^/[:space:]@]+@' docs/governance/2026-05-21-pr1c-required-checks-evidence.md docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json); if [ -n "$out" ]; then printf '%s\n' "$out"; echo "FAIL: 发现疑似 secret"; false; else echo "no secret OK"; fi`
Expected: 打印 `no secret OK`，命令进程退 0（两文件无任何 GitHub token 前缀 / URL 内嵌凭证；发现即 `false` → 进程非零）。先自测 scanner：`printf 'ghp_FAKE\ngithub_pat_FAKE\nhttps://u:p@h/x\n' | grep -cE -e 'gh[pousr]_' -e 'github_pat_' -e '://[^/[:space:]@]+:[^/[:space:]@]+@'` 应打印 `3`。

Run: `cd "$(git rev-parse --show-toplevel)" && cmp -s /tmp/pr1c-final/ruleset-snapshot.json docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json && shasum -a 256 docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json`
Expected: `cmp` 静默通过（入仓文件 == 原始 artifact 字节相等）+ 输出的 sha256 == evidence §4 记录值。

- [ ] **Step 4：commit 证据文件**

```bash
git add docs/governance/2026-05-21-pr1c-required-checks-evidence.md docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json
git commit -m "docs(1c): redacted required-checks admin-execute 证据 + 完整 snapshot（H8/H10）"
```

---

## Task 4 — ledger H8 / H10 backfill（close）

**Files:**
- Modify: `docs/governance/2026-05-17-wave0-signoff-ledger.md`（仅 H8 行、H10 行、iOS sign-off 第 6 项注记；不动其它）

- [ ] **Step 1：H10 行 backfill（修正 stale 命令 + close）**

把 ledger H10 行（现含 `gh api ... branches/main/protection ... .app_id==15368`）整行替换为：

```
| H10 | acceptance §G 缺 machine-checkable required check 验证 | plan v6 codex R6 finding 2 | ✅ **顺位 1c close（2026-05-21）**：机器可检查谓词权威断言 = `bash scripts/governance/verify-required-checks.sh --mode assert`（源真相 rulesets API；断言 Catalyst check 在位 + `integration_id=15368`（GitHub Actions app，防伪造来源）+ enforcement=active + 绑默认分支 + bypass 仅 admin）**且** live `gh api repos/agateuu1234-bit/kline-trainer --jq .default_branch == main`（codex R2-F2：assert 内部把 `~DEFAULT_BRANCH` 无条件当 main 不 live 核实，故 close 须双谓词同时成立）。**注**：旧验证命令（legacy `branches/main/protection` + `.app_id`）已 stale——该 endpoint 对 main 返回 404、rulesets API 用 `integration_id` 非 `app_id`；1c 已修正。证据：`docs/governance/2026-05-21-pr1c-required-checks-evidence.md` |
```

- [ ] **Step 2：H8 行 backfill（close + 指向 rulesets 实现；文案须与实际执行路径一致——codex R2-F3）**

1c 只走 Path A（no-op，未跑 `--apply`；grounding #13：Path B 退回 1b 而非在 1c mutate）。把 ledger H8 行（现描述 GitHub UI 手动配 required check）整行替换为：

```
| H8 | Catalyst CI required merge gate enforcement | spec v9 §6.G | ✅ **顺位 1c close（2026-05-21）**：origin `main` ruleset 已配 required check context `Mac Catalyst build-for-testing on macos-15`（= job name，非 job key `catalyst-build`）且绑 GitHub Actions app（`integration_id=15368`，非 "any source"，防 trust-boundary spoof）。1c 经 1b runbook **dry-run 确认幂等 no-op（gate 已在位，无需 mutation，未跑 `--apply`）** + 独立 `verify-required-checks.sh --mode assert` + live `default_branch==main` 双谓词确认；与 1a 拆出的 always-trigger workflow `.github/workflows/catalyst-build.yml`（H9 已解）配套，每 PR 必跑必报且 merge 受 gate。证据：`docs/governance/2026-05-21-pr1c-required-checks-evidence.md` |
```

- [ ] **Step 3：iOS 代表 sign-off 第 6 项注记 close**

iOS sign-off 现第 6 项末尾为「H8 + H9 + H10 配套闭合 required gate」。在该行末尾追加：`（**H8/H10 顺位 1c close 2026-05-21**；H9 顺位 1a；见 evidence doc）`。仅追加，不改其它语义。

- [ ] **Step 4：验证 backfill 不破坏 ledger 结构**

Run: `cd "$(git rev-parse --show-toplevel)" && grep -cE '^\| H[0-9]+ ' docs/governance/2026-05-17-wave0-signoff-ledger.md`
Expected: 打印 `10`（10 条 residual 行一条不少）。

Run: `cd "$(git rev-parse --show-toplevel)" && grep -c '✅ \*\*顺位 1c close' docs/governance/2026-05-17-wave0-signoff-ledger.md`
Expected: 打印 `2`（H8 + H10 两行已 close）。

Run: `cd "$(git rev-parse --show-toplevel)" && grep -cE 'api[^|]*branches/[^ |]*/protection.*app_id' docs/governance/2026-05-17-wave0-signoff-ledger.md`
Expected: 打印 `0`（stale legacy 验证命令已清除）。

- [ ] **Step 5：commit ledger backfill**

```bash
git add docs/governance/2026-05-17-wave0-signoff-ledger.md
git commit -m "docs(1c): ledger H8/H10 close + 修正 H10 stale 验证命令"
```

---

## Task 5 — 非编码者验收清单

**Files:**
- Create: `docs/acceptance/2026-05-21-pr1c-required-checks-admin-execute.md`

- [ ] **Step 1：写 acceptance 文档**

Create `docs/acceptance/2026-05-21-pr1c-required-checks-admin-execute.md`：

```markdown
# Wave 1 顺位 1c — Required-checks admin execute 验收清单

> 面向项目所有者（无代码经验）。每行：**动作** / **预期** / **通过判据**。
> 全部命令在仓库根目录终端执行。

**交付物**：对 origin `main` ruleset 落实/确认 Catalyst required check + 绑 GitHub Actions app（防伪造）+ redacted 证据 commit + ledger H8/H10 close。**1c 不改任何脚本 / 测试 / workflow / 业务代码。**

## 一、机器可检查验收（命令 + 退出码）

> **#1/#1b 已自带 fail-closed gh pin + 机械退出码**（codex R7-F1 + R9-F1）：子 shell `( ... )` 内先 allowlist 校验 `GH_BIN`，落 allowlist 外即 `exit 1`（子 shell 退出不杀终端）；末尾 `rc=$?; echo "退出码=$rc"; [ "$rc" -eq 0 ]` 令命令进程状态机械反映断言（不被 `echo` 掩盖）——untrusted/空 gh 或断言失败时进程必非 0。

| # | 动作（在终端粘贴运行） | 预期 | 通过判据 |
|---|---|---|---|
| 1 | `( GH_BIN=$(command -v gh); case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL 不可信 gh:$GH_BIN" >&2; exit 1;; esac; env -u REPO -u MOCK_FIXTURE -u MOCK_LOG -u MOCK_PUT_FAIL GH_HOST=github.com GH_CMD="$GH_BIN" bash scripts/governance/verify-required-checks.sh --mode assert --repo agateuu1234-bit/kline-trainer ); rc=$?; echo "退出码=$rc"; [ "$rc" -eq 0 ]` | 打印 `OK: main branch ruleset + 绑默认分支 + active + 'Mac Catalyst build-for-testing on macos-15' 在位 + integration_id=15368 + bypass 仅 admin`，`退出码=0` 且命令进程退 0 | 见 OK 且进程退 0 = 通过（= H10 谓词在 origin 真成立；fail-closed gh pin + 清 ambient env + 强制 host=github.com + 固定真仓） |
| 1b | `( GH_BIN=$(command -v gh); case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL 不可信 gh:$GH_BIN" >&2; exit 1;; esac; out=$(env GH_HOST=github.com "$GH_BIN" api repos/agateuu1234-bit/kline-trainer --jq '.default_branch'); echo "default_branch=$out"; [ "$out" = main ] ); rc=$?; echo "退出码=$rc"; [ "$rc" -eq 0 ]` | 打印 `default_branch=main`，命令进程退 0 | 进程退 0（`out`==`main`）= 通过（fail-closed gh pin + `GH_HOST=github.com` + 末尾 `[ "$out" = main ]` 机械判定）。**与 #1 共同构成 H8/H10 close 条件**——codex R2-F2：assert 内部把 `~DEFAULT_BRANCH` 无条件当 main 不 live 核实，故 close 须额外要 live `default_branch==main`；任一不满足 = 不通过 |
| 2 | `bash tests/scripts/governance/run-all.sh` | 末行 `ALL GREEN`，退出码 `0` | 见 ALL GREEN 且退出码 0 = 通过（1b 契约仍完整） |
| 3 | `{ git rev-parse --verify main >/dev/null && files=$(git diff --name-only main...HEAD -- scripts/governance tests/scripts/governance .github/workflows) && { [ -n "$files" ] && printf '%s\n' "$files"; [ -z "$files" ]; }; }; rc=$?; echo "scope 退出码=$rc"; [ "$rc" -eq 0 ]` | 无文件输出，`scope 退出码=0`，进程退 0 | 无输出 + 进程退 0 = 通过（codex R9-F2 + R10-F1：校验 base ref + `-- <paths>` 限定 + `[ -z "$files" ]` 机器判定 + 末尾 `[ "$rc" -eq 0 ]` 不被 `echo` 掩盖） |
| 4 | `git diff --name-only main...HEAD` | 仅出现 5 个 `docs/` 文件：`pr1c-required-checks-evidence.md`、`pr1c-ruleset-snapshot.redacted.json`、ledger `2026-05-17-wave0-signoff-ledger.md`、acceptance `2026-05-21-pr1c-...md`、plan `2026-05-21-pr1c-...md`。**绝不含** `scripts/` `tests/` `.github/` `kline_trainer*` | 仅这 5 个 docs 文件 = 通过 |
| 5 | `out=$(grep -nE -e 'gh[pousr]_' -e 'github_pat_' -e '://[^/[:space:]@]+:[^/[:space:]@]+@' docs/governance/2026-05-21-pr1c-required-checks-evidence.md docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json); if [ -n "$out" ]; then printf '%s\n' "$out"; echo FAIL; false; else echo "no secret OK"; fi` | 打印 `no secret OK`，进程退 0 | 见 `no secret OK` 且进程退 0 = 通过（codex R10-F2 + R11-F2：**多个 `-e` 真 alternation**，不用 `\|`（在表格里会被当字面管道）；`gh[pousr]_` 覆盖 ghp/gho/ghu/ghs/ghr + github_pat_ + basic-auth URL；发现即非零 fail-closed） |
| 5b | （scanner 自测，证明 fail-closed）`printf 'ghp_FAKE\ngithub_pat_FAKE\nhttps://u:p@github.com/x\n' \| grep -cE -e 'gh[pousr]_' -e 'github_pat_' -e '://[^/[:space:]@]+:[^/[:space:]@]+@'` | 打印 `3`（三种假凭证全被命中） | 打印 `3` = scanner 真能抓三类凭证（非空跑 #5 才有意义） |
| 6 | `grep -cE '^\| H[0-9]+ ' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `10` | 10 条 residual 一条不少 = 通过 |
| 7 | `grep -c '✅ \*\*顺位 1c close' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `2` | H8 + H10 均 close = 通过 |
| 8 | `grep -cE 'api[^|]*branches/[^ |]*/protection.*app_id' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `0` | stale legacy 命令已清除 = 通过 |

## 二、PR merge gate 真生效（GitHub 上人工确认）

| # | 动作 | 预期 | 通过判据 |
|---|---|---|---|
| 9 | 打开本 1c PR 的「Checks」页 | 含名为 `Mac Catalyst build-for-testing on macos-15` 的检查（pending/pass，非 skipped、非缺失） | 该检查在列 = 通过 |
| 10 | 看 PR 顶部 merge 区 | 在该检查为非 success 前，merge 被 required check 挡住（仅 admin 可 bypass） | merge 受 gate = 通过 |

## 三、本次执行采集到的真实证据（2026-05-21）

见 `docs/governance/2026-05-21-pr1c-required-checks-evidence.md`（dry-run no-op 判定 + apply 输出 + assert OK + redacted snapshot）。

## 四、已知 residual（不阻塞本交付）

- **`~DEFAULT_BRANCH` 脚本层未 live 核实**（1b branch-diff R4）：1c 已在本次执行证据中加只读断言 `default_branch == main`，**为本次执行**证明假设成立；脚本层完整修（live 查 + offline `--default-branch` 参数）仍属将来跨仓复用 / 默认分支改名场景，归 1b 脚本 backlog，不在 1c scope（1c 不改脚本）。

## 五、评审记录

- plan-stage codex 对抗性 review（收敛轮数执行时回填）。
- branch-diff codex 对抗性 review（收敛轮数执行时回填）。

> 禁忌词自查：本清单不含「验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine」。
```

- [ ] **Step 2：验证 acceptance 无禁忌词**

Run（fail-closed）: `cd "$(git rev-parse --show-toplevel)" && out=$(grep -nE '验证通过即可|看起来正常|应该没问题|should work|looks fine' docs/acceptance/2026-05-21-pr1c-required-checks-admin-execute.md); if [ -n "$out" ]; then printf '%s\n' "$out"; echo "FAIL: 含禁忌词"; false; else echo "no forbidden words OK"; fi`
Expected: 打印 `no forbidden words OK`，进程退 0。

- [ ] **Step 3：commit acceptance**

```bash
git add docs/acceptance/2026-05-21-pr1c-required-checks-admin-execute.md
git commit -m "docs(1c): 非编码者验收清单"
```

---

## 自检（Self-Review，写完 plan 后对 outline/1b 契约复核）

**1. Scope coverage（outline §3.3 + §四 residual 映射）：**
- 「admin execute 1b runbook」→ Task 1（dry-run）+ Task 2（路径 A no-op：host guard + assert + 最终态 snapshot；路径 B：fail-closed 退回 1b）✅
- 「commit redacted evidence」→ Task 3（evidence 文件 + 完整 redacted snapshot）✅
- 「ledger 回填」→ Task 4（H8 + H10 close）✅
- 「不引入新 script / 不定义新 safety contract」→ Task 0 Step 2 scope 守约 + acceptance #3/#4 ✅
- 「1b contract 缺失/stale 则 fail-closed 退回 1b」→ Task 0 Step 1（run-all 门）+ Task 1 Step 4（preflight FAIL 停止）+ Task 2 Step C（redact 失效停止）✅
- §四：H8 → 1c ✅；H10 → 1c ✅（含 stale 命令修正）；H5 延续（required gate）→ acceptance #9/#10 ✅

**2. Placeholder scan：** 证据文件的 `{...}` 是「执行时回贴输出填入」的占位，**这是 governance 执行 plan 的本质**（证据值在 origin 执行时才产生）——非 plan 失败式占位；结构 / 命令 / ledger 改写文本全部具体。命令均给出 + 预期输出 + 退出码。完整 redacted snapshot 原样入仓（非手工摘要），sha256 绑定。

**5. codex plan-stage R1 三 finding 全修（2026-05-21）：**
- R1-F1（high，ambient REPO/GH_CMD 污染）→ grounding #10 canonical safe invocation（`env -u` + 显式 `--repo`），贯穿 Task 1/2 + acceptance #1 ✅
- R1-F2（high，no-op 授权变 mutation）→ Task 2 路径 A no-op **绝不跑 `--apply`** 仅 assert；路径 B 不在 1c mutate（见 R4-F2 收口）✅
- R1-F3（medium，证据丢完整 snapshot）→ 新增 `2026-05-21-pr1c-ruleset-snapshot.redacted.json` 完整入仓 + sha256 绑定（Task 3）✅

**6. codex plan-stage R2 三 finding 全修（2026-05-21）：**
- R2-F1（high，snapshot 是 pre-mutation stale）→ Task 2 A-Step 2 改为**最后一次 assert 之后**跑 fresh dry-run 取最终态 snapshot 提交（时序铁律）✅
- R2-F2（high，acceptance 绕不开 `~DEFAULT_BRANCH` 假阳性）→ acceptance 加 #1b live `default_branch==main`；H8/H10 close 改为 assert + live default_branch **双谓词**（ledger H8/H10 + evidence 同步）✅
- R2-F3（medium，ledger 谎称 no-op 路径跑了 `--apply`）→ H8 backfill 文案与实际路径一致（1c 只走 Path A：dry-run + assert，明确"未跑 `--apply`"）✅

**7. codex plan-stage R3 三 finding 全修（2026-05-21）：**
- R3-F1（high，scope guard 忽略 working tree）→ grounding #12 clean script-tree 铁律 + Task 0 Step 1 门（`status --porcelain` + `diff --exit-code` + `diff --cached --exit-code`）+ 每条 origin 命令前复跑 ✅
- R3-F2（high，Path B 授权只比 check diff）→ **由 R4-F2 收口**：真 mutation 退回 1b（程序化 Path B 绑定无法 PUT 前 abort，不在 1c 做）✅
- R3-F3（medium，Path B rollback 只在 /tmp）→ **由 R4-F2 收口**：1c 不做真 mutation，无 /tmp rollback 持久化问题（真 apply 时由 1b 增强后的脚本负责）✅
- 残留（grounding #13）：完美原子 payload 绑定需 1b 脚本加 `--expected-payload-sha`（不改脚本，归 1b backlog；单管理员内网仓使窗口风险极低）。

**3. Type/名称一致性：** required check context 全程字节一致 `Mac Catalyst build-for-testing on macos-15`；`integration_id=15368` 跨 evidence/ledger/acceptance 一致；脚本路径 `scripts/governance/{admin-configure-required-checks,verify-required-checks}.sh` 与 1b File Structure 一致；artifact 文件名 `verify-evidence.txt` / `ruleset-snapshot.json` 与 runbook 实现一致。

**4. 不可逆动作门：** 1c 预期路径（Path A no-op）**零 mutation**——仅读 + assert；真 PUT（Path B）不在 1c 做，fail-closed 退回 1b（grounding #13）。origin 命令全部由 user 用 `!` 跑（grounding #9）+ host/repo guard（grounding #10）。

**8. codex plan-stage R4 两 finding 全修（2026-05-21）：**
- R4-F1（high，canonical invocation 没 pin GH_HOST）→ grounding #10 加 `GH_HOST=github.com` 强制 + `gh auth status --hostname github.com` + `git remote get-url origin` host/repo guard，贯穿 Task 2 + acceptance ✅
- R4-F2（high，Path B PUT 后才验 payload）→ **根治**：删除 1c 内的程序化 Path B 真 mutation 装置，改为 fail-closed 退回 1b（grounding #13）；真原子 pre-PUT 绑定（`--expected-payload-sha`）由 1b 脚本增强承担，1c 只覆盖 Path A no-op ✅

**9. codex plan-stage R5 两 finding 全修（2026-05-21，一致性收口）：**
- R5-F1（high，Task1/acceptance 的 default_branch + dry-run 没 pin GH_HOST）→ Task 1 加 host guard（Step 1）+ Step 2/3 与 acceptance #1/#1b 全部加 `GH_HOST=github.com`，host pin 跨所有 live 命令机械一致 ✅
- R5-F2（high，handoff/Architecture 仍写 1c 含 apply）→ Architecture + 执行交接 全部改为"1c 从不跑 `--apply`、零 mutation；Path B 退回 1b"，与安全规则一致 ✅

**10. codex plan-stage R6 三 finding 全修（2026-05-21）：**
- R6-F1（high，evidence 残留 Path B 真 PUT 措辞）→ evidence meta 执行路径改为"路径 A 零 mutation；Path B fail-closed 退回 1b"，清干净矛盾 ✅
- R6-F2（high，unset GH_CMD 回落 PATH 解析 gh）→ grounding #10 + 所有 origin 命令改为 pin 绝对 `GH_BIN`（`command -v gh` + allowlist `/opt/homebrew|/usr/local|/usr/bin`，镜像 codex-attest node pin）+ `GH_CMD="$GH_BIN"`；evidence 记 `GH_BIN` ✅
- R6-F3（medium，snapshot 手工转录）→ Task 3 Step 2 改为 `cp` artifact 直拷 + `cmp -s` + 双向 sha256，机器绑定到 live 产物 ✅

**11. codex plan-stage R7 两 finding 全修（2026-05-21，guard 自身 fail-closed 正确性）：**
- R7-F1（high，acceptance gh pin 失败臂只 echo 不 exit）→ acceptance #1/#1b 改自包含子 shell `( ... )`，allowlist 外 `exit 1`（子 shell 退出不杀终端），untrusted gh 不可能产假 OK ✅
- R7-F2（medium，clean-tree gate `git status --porcelain` 脏也 exit 0）→ Task 0 Step 1 + grounding #12 改 `st=$(git status --porcelain ...); [ -z "$st" ] && git diff --quiet && git diff --cached --quiet`，含未追踪文件机器失败 ✅

**12. codex plan-stage R8 一 finding 全修（2026-05-21）：**
- R8-F1（high，clean-tree gate 以 `echo "$?"` 收尾→进程恒退 0、未机械绑定 origin 命令）→ grounding #12 定义 canonical clean-tree **子 shell**（返回非零即脏）；Task 0 Step 1 用 `rc=$?` 真返回；**Task 1 Step 3 / A-Step1 / A-Step2 三条跑脚本的 origin 命令把该子 shell 用 `&&` 内联在脚本前**——脏树/未追踪文件机械短路、脚本根本不跑 ✅

**13. codex plan-stage R9 两 finding 全修（2026-05-21，全面硬化所有 gate 退出码）：**
- R9-F1（high，assert `; echo "$?"` 掩盖 verifier 失败）→ A-Step1 assert + acceptance #1 末尾改 `rc=$?; echo "退出码=$rc"; [ "$rc" -eq 0 ]`；default_branch（Task1 Step2 + acceptance #1b）改 `out=$(...); [ "$out" = main ]`——进程状态机械反映断言 ✅
- R9-F2（medium，scope guard `|grep` + 无 base-ref 校验）→ Task 0 Step 3 + acceptance #3 改 `git rev-parse --verify main && files=$(git diff --name-only main...HEAD -- <paths>); [ -z "$files" ]`——base ref 校验 + diff 失败与无匹配分离 ✅
- **一次性全面 pass**：本轮把全部 trust-boundary gate 命令（clean-tree / scope×2 / default_branch×2 / assert×2）统一改机械 fail-closed（非逐轮单条），杜绝 `echo "$?"` 掩盖类 whack-a-mole ✅

**14. codex plan-stage R10 两 finding 全修（2026-05-21）：**
- R10-F1（high，scope guard 仍以 `echo "$?"` 收尾 fail-open）→ Task 0 Step 3 + acceptance #3 改 `{ ...; }; rc=$?; echo "scope 退出码=$rc"; [ "$rc" -eq 0 ]`，末尾谓词机械返回；并全量审计：clean-tree(行69) / assert(行157) / default_branch / scope ×2 / secret scan ×2 / forbidden-words 全部以谓词或 `[ ]` 收尾 ✅
- R10-F2（high，evidence 可提交未脱敏凭证）→ host guard 不 dump 原始 auth/remote URL，`sed -E 's#://[^/@]*@#://#'` 剥 userinfo + 仅断言匹配 + 只记 sanitized 行；secret 扫描扩展 token 前缀 + basic-auth URL + 改 fail-closed（`if [ -n "$out" ]; then ...; false; fi`） ✅

**15. codex plan-stage R11 两 finding 全修 + 本地实测（2026-05-21）：**
- R11-F1（high，A-Step2 final dry-run 即使"会加 check"也 exit 0 → 可提交未保护态）→ A-Step2 链入 `diff -q payload rollback`（机械 no-op 判据）+ 复跑 `verify --mode assert`，全 `&&`；check 漂移走则短路、不出 sha、命令非零 ✅
- R11-F2（high，acceptance secret 扫描 `\|` 在 markdown 表里是字面管道 → 不匹配真 token）→ 改用多个 `-e`（真 alternation，无 `|`）+ `gh[pousr]_` 字符类；加 #5b 自测（假凭证应命中 3）✅
- **本地实测捕获 codex 未发现的 zsh bug**：clean-tree gate 原用 `$P` 无引号变量——zsh 默认不 word-split，`$P` 当单路径致 git 找错目录而**假绿**；改全字面路径，实测 clean→0 / 脏(未追踪)→1 ✅；secret scanner 正(3)/负(0) 实测；scope guard 实测 ✅

**16. codex plan-stage R12 两 finding 全修（2026-05-21）：**
- R12-F1（high，code block 行首字面 `!` 在 zsh/bash 取反 pipeline）→ 全部 origin code block 去掉 `! ` 前缀（从 `mkdir`/`cd`/`GH_BIN` 起头）；grounding #9 澄清 `!` 是 Claude Code run-bash 前缀（在提示符前打），不可粘进 raw shell ✅
- R12-F2（medium，提交的 snapshot 没绑定到 final assert）→ A-Step2 的最终断言改 `verify --mode assert --ruleset-json /tmp/pr1c-final/ruleset-snapshot.json`（offline，断言**即将 cp 入仓的同一份 JSON**），snapshot 与"通过断言的状态"字节一致 ✅（offline assert 对 GET 形 JSON 本地实测可用）

**17. codex plan-stage R13 两 finding 全修 + 本地实测（2026-05-21）：**
- R13-F1（high，origin 命令只查 working-tree、漏 committed-scope，Task 0 后 commit/rebase 可漂移）→ grounding #12 canonical guard 升级为 **committed-scope（`git diff main...HEAD -- <paths>` 空）+ working-tree** 双查，内联在每条 origin 脚本命令前每次重检；Task 0 Step 1 同步 ✅（clean 态实测退 0）
- R13-F2（high，host guard regex 未锚定，`evilgithub.com` 含子串 "github.com" 可绕过）→ 改**锚定** `^(https://github\.com/|git@github\.com:)agateuu1234-bit/kline-trainer(\.git)?$` + 校验 fetch & push 双 remote ✅（实测 ACCEPT 3 合法 / REJECT evilgithub.com + github.com.evil.com / 对真实 origin 退 0）

---

## Plan-stage codex 收敛记录（2026-05-21）

plan-stage `codex:adversarial-review`（working-tree scope）跑 **13 轮**，逐条真 finding 全修（无自相矛盾/重翻旧账）：
- R1–R4 架构级（ambient env 污染 / no-op→PUT / 证据丢 snapshot / Path B 真 mutation 无法 pre-PUT 绑定 → Path B 改 fail-closed 退回 1b）。
- R5–R13 信任边界 + shell 加固逐层变窄（GH_HOST pin / gh 二进制 allowlist / 全 gate 机械 fail-closed / 证据脱敏 / snapshot 机器绑定 / secret 扫描真 alternation / host regex 锚定防 evilgithub.com / committed-scope+working-tree 双查）。
- 本地实测额外捕获 codex 未发现的 zsh `$P` word-split 假绿 bug，已修+实测；关键 shell 片段（reviewed-tree gate / secret scanner / host guard / offline assert）全部本地验证。

**收口决策**：命中 `feedback_codex_round6_self_contradiction` + PR #1b 记录的 "governance-runbook permanent edge-mining" 模式（codex 在管理员 runbook 上无止境挖理论边界，不自然收敛）。per `feedback_codex_plan_budget_overshoot`（超 5 轮 escalate）+ 1b 先例，**2026-05-21 user explicit 选择「收口 plan-stage，进实施」（TTY override plan-stage gate）**。后续 subagent-driven 实施 + verification + requesting-code-review + **整体 branch-diff codex 再审一次真实现**为第二道背靠。

## 执行交接

Plan 完成并存 `docs/superpowers/plans/2026-05-21-pr1c-required-checks-admin-execute.md`。

按用户指定流程：**writing-plans（本步）→ codex 对抗性 review 到收敛 → subagent-driven-development → verification-before-completion → requesting-code-review → 整体 codex 对抗性 review 到收敛**。

> 注意：**1c 从不跑 `--apply`、零 origin mutation**（预期路径 A：只读 dry-run + assert）。1c 的「实施」含 user 用 `!` 亲手执行的**只读** origin 命令（dry-run / assert / default_branch / 最终态 snapshot），无法由 subagent 代跑；subagent-driven 阶段负责文件型 task（证据文件 / ledger / acceptance 撰写 + 验证）。若 dry-run 显示 origin 需真 PUT（路径 B）→ fail-closed 退回 1b，不在 1c mutate。
