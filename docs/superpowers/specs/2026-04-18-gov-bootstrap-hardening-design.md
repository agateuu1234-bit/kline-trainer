# gov-bootstrap-hardening 设计 spec

**Date:** 2026-04-18
**Status:** Draft（待 codex:adversarial-review 收敛 + 用户 approve）
**Scope:** G1（Edit/Write 放行修复） + G2（spec/plan/code adversarial-review hook 强制） + R（命名 plan-0b → gov-bootstrap）
**Out of scope:** G3（skill pipeline 流程强制）→ 后续 `gov-bootstrap-hardening-2`

---

## 1. 背景与目标

### 1.1 三个缺口的来源

在 Plan 0a v3 split 的 brainstorm 中暴露出 plan-0b（以下统称 **gov-bootstrap**）落地时的 regression 与未实现项：

- **G1**：历史上 commit `77a4442`（"chore: add Write/Edit/Read and common Bash commands to allow list"）已给 `.claude/settings.json` `allow` 加入 `Write` / `Edit` / `Read` 三条裸名（catch-all 放行普通文件编辑）；gov-bootstrap PR #14 重写 settings.json 时**删除**了这三条。结果：所有非 trust-boundary 文件的 Edit/Write 重新落回 Claude Code 默认 ask 行为，造成用户每改一个 doc 就要被打扰。
- **G2**：`.claude/workflow-rules.json` 的 `adversarial_review_loop` 把 spec / plan / code 三类制品都标为 `applies_to_artifacts`，但 hook 层**没有实现**：(a) spec/plan 的过闸依赖 Claude 自觉调 `codex-attest.sh`；(b) code 的 `.github/workflows/codex-review-verify.yml` 存在但**不是 required status check**（🅱️ 降级状态，OpenAI API 未充值）。结果：任何一轮 Claude 遗忘都会让未 review 的制品进入远端或 merge。
- **R**：gov-bootstrap 的本地 branch / spec / plan / memory 文件普遍使用 "plan-0b" 作为非正式工作名，与 Kline Trainer 项目计划的 **Plan 0B** 编号空间撞车，需要改名为 `gov-bootstrap`；本次修复整体命名 `gov-bootstrap-hardening`。

### 1.2 目标

- **G1**：恢复 `allow` 中的 `Write` / `Edit` / `Read` catch-all，依赖现有 deny 规则保护 trust-boundary 文件（deny 在 Claude Code 权限语义中以"具体 > 通配"胜出）。
- **G2**：新增一个 PreToolUse hook + 一张台账文件，在"外部可见动作"前强制校验 spec/plan 文件内容、code 分支 diff 必须先过 codex:adversarial-review。
- **R**：本地文件改名 + 文字引用更新 + memory 归档；已 merge 的远端历史（PR #14 title / branch / commit messages）不动。

### 1.3 非目标 / 威胁模型明示

- G3（skill pipeline 顺序强制 / `.claude/state/task-log.jsonl` hook 化 / skill 调用与声明匹配）— 延到 `gov-bootstrap-hardening-2`
- Codex API 充值 / 升回 🅰️ 方向（独立决策，与本 PR 解耦）
- PR #13 (Plan 0a v3) 的继续推进（被本 PR block，本 PR merge 后恢复）

**本 PR 的 hook 是"Claude-session 层次"的 first-layer gate，不是完整闸门**。明确覆盖范围：

| 路径 | 本 PR 是否 hook-block | 说明 |
|---|---|---|
| Claude 在当前 Claude Code 会话里执行 `git push` / `gh pr create` / `gh pr merge` | ✅ 拦 | PreToolUse 生效（hook 只收 Claude tool JSON） |
| Claude 在别的 Claude Code session 跑同上命令 | ✅ 拦 | 同一工作区的 hooks + ledger 共享 |
| 用户/任何人在**普通终端**（非 Claude Code 工具）跑同上命令 | ❌ **不拦** | PreToolUse 只触发于 Claude 的 tool_use，普通 shell 不经过 hook |
| 用户在 GitHub 网页点 **Merge** 按钮 | ❌ **不拦** | 本地 hook 无法 intercept 远端 UI 操作 |
| 外部 actor / bot 通过 API merge | ❌ **不拦** | 同上 |
| 用户在另一台机器 / 另一个 clone 执行 push/merge | ❌ **不拦** | ledger 在本地 `.claude/state/`；他机无台账 |

**完整 server-side 闸门**（把 `.github/workflows/codex-review-verify.yml` 设为 required status check）依赖 OpenAI API 可用，🅱️ 状态下无法实现 → **延到 `gov-bootstrap-hardening-3`**（与 API 充值同步启动）。本 PR 不 claim 全路径强制，仅承诺 Claude-session 层次闸门。

用户接受本 PR 的 scope 代表接受："若用户在网页 UI merge 未过 codex 的 PR，不会被本 PR 的 hook 拦住"。降低误伤面的同时，保留所有通过 Claude 的自动化操作必过 codex 的承诺。

---

## 2. 架构

### 2.1 新增 / 改动件清单

| 类型 | 路径 | 说明 |
|---|---|---|
| 新增 hook | `.claude/hooks/guard-attest-ledger.sh` | PreToolUse Bash，触发点 `git push:*` / `gh pr create:*` / `gh pr merge:*` |
| 新增 state | `.claude/state/attest-ledger.json` | 台账：记录每个 plan/spec 文件和每个 feature 分支 HEAD SHA 的"最近一次 approve 时的指纹" |
| 新增 state | `.claude/state/attest-override-log.jsonl` | append-only 审计日志，记录每次 override 事件（行号是 ledger override 条目的引用） |
| 新增 script | `.claude/scripts/attest-override.sh` | 手工豁免入口；要求真实 tty + 随机 nonce 确认串；写审计日志 + ledger（见 §2.5） |
| 改动 script | `.claude/scripts/codex-attest.sh` | 增加 `--scope branch-diff` 模式；成功 approve 后写入台账（以 head SHA 为 key 的一部分） |
| 改动 settings | `.claude/settings.json` | `allow` 加 `Write` / `Edit` / `Read` 三条裸名；`hooks.PreToolUse[Bash]` 挂新 hook；`deny` 扩展（见下）阻止 Claude 绕 override 脚本 + 绕写台账 |
| 改动 .gitignore | `.gitignore` | 新增 `.claude/state/*` + `!.claude/state/.gitkeep` 例外，阻止台账和 override log 进 git（F2）|
| 改动 pre-commit hook | `.claude/hooks/pre-commit-diff-scan.sh` | 扩展：若 staged 文件含 `.claude/state/attest-ledger.json` 或 `.claude/state/attest-override-log.jsonl` → block + 提示"不应提交本地 attestation 状态"（F2 staging 拦截）|

**settings.json `deny` 新增条目**（R3-F1 + R3-F2 + R4-F1 + R5-F1 + R5-F2）：

```
# --- .claude/state 访问用 allowlist 模型（R5-F1）---
# 旧版 blacklist（> / python / node / cat / printf / tee / sed）被 Codex round 5 证明不全（可绕：cp / mv / install / dd / perl / ruby / heredoc / 其他变种）。
# 新策略：catch-all 禁掉所有含 `.claude/state` 的 Bash 命令，再在 allow 里精确放行两个 attestation 入口脚本的调用。
Bash(*.claude/state*)                      # 任何 Bash 命令提到 .claude/state 路径 → 拒；只有下面 allow 中的 attest script 例外
Bash(*attest-override.sh*)                 # Claude 不能直接调用该脚本（防社工 tty 绕过尝试）

# --- .claude/state 文件编辑（仍保留旧 deny）---
Edit(.claude/state/**)
Write(.claude/state/**)

# --- secret 文件 + credential 类路径 deny（R4-F1 + R5-F2）---
# R5-F2：Codex 指出 naked Read 对未列举的 iOS/backend credential 有暴露风险。
# 策略二选一里本 spec 选 (b)：保留 naked Read 但把 credential 清单扩到工程常见类型。
# (a) 方案（改 allowlist Read）留作 hardening-3 候选；此 PR 不做。
Read(**/.env)
Read(**/.env.*)
Read(secrets/**)
Read(**/*.pem)
Read(**/*.key)
Read(**/id_rsa*)
Read(**/.ssh/**)
Read(**/.aws/credentials*)
Read(**/.npmrc)
Read(**/.netrc)
Read(**/.pypirc)
Read(**/.pgpass)
Read(**/*.p12)
Read(**/*.pfx)
Read(**/*.mobileprovision)
Read(**/GoogleService-Info.plist)
Read(**/private_keys/**)
Read(**/*_private.key)
Read(**/*_rsa)
Read(**/fastlane/**/Appfile)
Read(**/fastlane/**/Matchfile)
# 与以上同路径的 Edit / Write 也要 deny
Edit(**/.env)
Edit(**/.env.*)
Edit(secrets/**)
Edit(**/*.pem)
Edit(**/*.key)
Edit(**/id_rsa*)
Edit(**/.ssh/**)
Edit(**/.aws/credentials*)
Edit(**/.npmrc)
Edit(**/.netrc)
Edit(**/.pypirc)
Edit(**/.pgpass)
Edit(**/*.p12)
Edit(**/*.pfx)
Edit(**/*.mobileprovision)
Edit(**/GoogleService-Info.plist)
Edit(**/private_keys/**)
Edit(**/*_private.key)
Edit(**/*_rsa)
Edit(**/fastlane/**/Appfile)
Edit(**/fastlane/**/Matchfile)
Write(**/.env)
Write(**/.env.*)
Write(secrets/**)
Write(**/*.pem)
Write(**/*.key)
Write(**/id_rsa*)
Write(**/.ssh/**)
Write(**/.aws/credentials*)
Write(**/.npmrc)
Write(**/.netrc)
Write(**/.pypirc)
Write(**/.pgpass)
Write(**/*.p12)
Write(**/*.pfx)
Write(**/*.mobileprovision)
Write(**/GoogleService-Info.plist)
Write(**/private_keys/**)
Write(**/*_private.key)
Write(**/*_rsa)
Write(**/fastlane/**/Appfile)
Write(**/fastlane/**/Matchfile)
Bash(cat **/.env*)
Bash(cat **/secrets/**)
Bash(cat **/*.p12)
Bash(cat **/*.mobileprovision)
Bash(cat **/GoogleService-Info.plist)
Bash(cat **/.npmrc)
Bash(cat **/.netrc)
Bash(cat **/.pypirc)
Bash(* > **/.env*)
Bash(* > **/secrets/**)
```

**settings.json `allow` 新增条目**（对应上面 state catch-all deny 的精确放行）：

```
Bash(bash .claude/scripts/codex-attest.sh:*)
Bash(.claude/scripts/codex-attest.sh:*)
# attest-override 只允许用户 tty 手动调；Claude 禁 — 所以**不**加 allow
```

**例外处理**：`**/.env.example`（样例不敏感，但被 `**/.env.*` 匹配到 deny）；通过 allow 里加更具体的 `Read(**/.env.example)` / `Edit(...)` / `Write(...)` 覆盖。具体 > 泛化，但 deny > allow 仍是 Claude Code 的一级规则 — 本 plan 阶段**验证**该例外行为，必要时改 pattern 为 `**/.env` 和 `**/.env.{local,dev,prod,production,staging,test,test.*}` 等枚举式以绕开 `.env.example`。
| 改动 hook 注册 | `.claude/settings.json` | 将 `.claude/hooks/guard-attest-ledger.sh` 挂载到 PreToolUse[Bash] **无 if 条件**的 entry（覆盖 bare `git push` / `gh pr merge` 等前缀模式易遗漏的情况）；hook 内部 parse 后决定是否生效 |
| 多个文件改名 | memory + docs + MEMORY.md 索引 | R 任务 |

### 2.2 权限语义验证（G1 深度检查）

Claude Code 权限精度优先级：`deny > ask > allow`，且**更具体的 glob 胜过通配裸名**。验证链：
- `Edit` 裸名在 allow（最宽泛）
- `Edit(.claude/hooks/**)` 在 deny（具体） → **deny 胜**
- `Edit(CLAUDE.md)` 在 deny → **deny 胜**
- `Edit(/Users/maziming/Coding/Prj_Kline trainer/.claude/settings.json)` 在 ask → **ask 胜**（更具体）
- `Edit(docs/superpowers/plans/X.md)` 仅匹配裸名 `Edit` → **allow 放行** ✅

### 2.3 台账 `attest-ledger.json` schema

```json
{
  "version": 1,
  "entries": {
    "file:docs/superpowers/plans/2026-04-18-foo.md": {
      "kind": "file",
      "blob_sha": "abc123...",
      "attest_time_utc": "2026-04-18T15:30:00Z",
      "codex_round": 1,
      "verdict_digest": "sha256:..."
    },
    "branch:feature-X@d34db33f...": {
      "kind": "branch",
      "base": "origin/main",
      "head_sha": "d34db33f...",
      "diff_fingerprint": "sha256:...",
      "attest_time_utc": "2026-04-18T15:45:00Z",
      "codex_round": 1,
      "verdict_digest": "sha256:..."
    },
    "file:docs/superpowers/specs/2026-04-18-bar.md": {
      "kind": "file",
      "override": true,
      "override_reason": "Codex API 耗尽；手工继续",
      "override_time_utc": "2026-04-18T16:00:00Z",
      "audit_log_line": 3,
      "blob_or_head_sha_at_override": "xyz789..."
    }
  }
}
```

**key 设计要点**：
- 文件类用 `file:<relative-path>` — 同一路径 blob 一变就重新过闸
- 分支类用 `branch:<branch-name>@<head_sha>` — 同名分支被 reset / rebase 后 head SHA 变 → 旧台账不命中、必须重过；防止 finding #3 里"同分支历史曾过、后来 reset" 的旁路
- override 条目额外带 `blob_or_head_sha_at_override`，方便审计对账

### 2.4 hook `guard-attest-ledger.sh` 逻辑

```
输入（stdin JSON）：
  {"tool_name": "Bash", "tool_input": {"command": "<git push ... | gh pr create ... | gh pr merge ...>"}}

步骤：
  1. 解析 tool_input.command，匹配三种模式之一（否则 exit 0 放行）
  2. 初始化 ledger：若 .claude/state/attest-ledger.json 不存在，创建 {version:1, entries:{}} 后继续执行后续检查；**不 soft-pass**。首次运行时但凡 push/PR 涉及 plan/spec 或 code diff，一律视为 missing attestation → block（告知用户"ledger 首次初始化，请先跑 codex-attest 再重试"）
  3. 场景 A（`git push ...` — 含 bare `git push`、`-u`、`--set-upstream`、`HEAD:foo` refspec）：
     a. 解析被推送 refspec：从 command 里提取 `<src-branch>`。bare `git push` 时取 current HEAD + 其 tracked upstream
     b. 计算 commits-to-push：优先用 `git rev-list <src-branch> ^origin/<tracked-upstream>`；追踪关系缺失则回退到 `git rev-list <src-branch> ^origin/main` + stderr warn；仍失败 → block
     c. 对 commits-to-push 里每个 commit 取 `git diff-tree --name-only`，收集所有被动过的文件
     d. **文件级 plan/spec 检查**：过滤出 `docs/superpowers/plans/*.md` / `docs/superpowers/specs/*.md`；对每个文件在 src-branch HEAD 下读 `git ls-tree <src-branch> -- <file>` 的 blob sha；与 `entries["file:$path"].blob_sha` 比对；不一致 → 违规
     e. **code branch-diff 检查**：若 c 里任意文件**不属于** plan/spec 白名单，视为 code 改动；要求 `entries["branch:$src-branch@$src-head-sha"].diff_fingerprint` 存在且等于 sha256(`git diff origin/<tracked-or-main>...<src-head-sha>` 的 canonical output)；不一致 → 违规
     f. 任一违规 → decision=block + 完整清单（plan 违规提示"跑 codex-attest --scope working-tree --focus <file>"；code 违规提示"跑 codex-attest --scope branch-diff --base origin/<base> --head <src-branch>"）
  4. 场景 B（`gh pr create ...`）：
     a. **解析实际 PR 目标**：parse `--head <X>`（若存在）否则 current branch；parse `--base <Y>`（若存在）否则 main
     b. head_sha = `git rev-parse <head>`（必要时先 `git fetch origin <head>`）
     c. 执行场景 A 的文件级检查，但 blob 读自 head_sha 而非 current working tree
     d. 执行场景 A 的 code branch-diff 检查，key = `branch:$head@$head_sha`
     e. 不一致 → 违规 + 对应提示
  5. 场景 C（`gh pr merge ...` — 含 bare `gh pr merge`、`gh pr merge <N|URL|branch>`）：
     a. 解析 merge target：command 里若出现 `<N|URL|branch>` → 以此为 target；否则（bare `gh pr merge`）用 current branch 查 PR（`gh pr view --json ...`）
     b. `gh pr view <target> --json headRefName,headRefOid,baseRefName` 取真实 head/base 和 headRefOid
     c. **race 防护**：command 必须显式带 `--match-head-commit <X>` 且 `X` == headRefOid；不带或不匹配 → block + 强制提示"请改写为 `gh pr merge <target> --match-head-commit <headRefOid> ...` 确保 merge 的 SHA 与 ledger 校验一致"。此防护避免 `gh pr view` → `gh pr merge` 之间分支被 push 新 commit 导致 merge 到未经审 SHA 的竞态
     d. 用 headRefOid 作为 branch-diff 检查的 `head_sha`，读 `entries["branch:$headRefName@$headRefOid"]`；文件级检查读 headRefOid 下的 blob
     e. 不一致 → 违规
  6. exit code 2（block） or 0（pass）

**hook 挂载策略**（与 finding #2 对应）：在 `.claude/settings.json` 的 `hooks.PreToolUse[matcher:Bash]` 数组里挂一条**无 `if` 条件**的 entry 指向本 hook（让它对所有 Bash 调用都触发）；hook 内部先 parse command 再决定是否进入场景 A/B/C，非三者一律 exit 0 放行。这样 `git push`（bare）/`gh pr merge`（bare）/`git push:*` 一视同仁，避免 `if` 表达式的模式遗漏。
```

### 2.5 人工豁免机制（override，方案 Y 修订版）

**威胁模型澄清**：单操作者项目里，Claude 和用户共用同一台机器、同一套 git credential。所以"override 授权"不是密码学身份证明（无法阻止 Claude 自主 mint），而是**强制 ceremony**：让用户必须显式、分离地做一个动作，从而保留 audit trail + 降低"Claude 想当然帮你 override"的风险面。

**旧方案（已废弃）**：plan/spec 文件内嵌 `<!-- attest-override: ... -->` 注释 — Codex round 1 指出这是自授权，被保护的文件自己授权自己，任何写文件的 agent 都能绕闸。**作废，不采用**。

**诚实免责（基于 Round 3 Codex 实证）**：
Codex round 3 在它自己的 Bash 工具里实测 `[ -t 0 ]` 返回 tty，证明 PTY-capable 的 Bash 可以读脚本打印的 nonce 并通过"确认"。本地任何脚本都**无法真正分辨"人在打字"与"agent 通过 PTY 打字"**。因此：

- ⚠ 本 PR 的 override 机制是 **ceremony + audit-trail + defense-in-depth**，**不是 agent-proof security**。
- 完整 agent-proof 边界需要服务端审批（GitHub manual approval / required workflow），延到 `gov-bootstrap-hardening-3`（与 OpenAI API 充值同步）。
- 本 PR 承诺的是：**让 override 路径足够显眼 + 可审计 + 攻击成本抬高**，而非"Claude 无法 mint"。

**新方案（降级 claim 版）**：

用户手工跑独立脚本 `.claude/scripts/attest-override.sh`：

```bash
.claude/scripts/attest-override.sh <target-file-or-branch> <reason>
```

脚本逻辑：
1. 读取 target 的当前 blob_sha（file）或 head_sha + diff_fp（branch）
2. 打印随机 nonce（短 blob sha 前缀）+ prompt `read -p "Type OVERRIDE-CONFIRM-<nonce> to authorize: " ans`
3. **PPID 父进程启发式检查**（不是 security，提升攻击成本）：
   ```bash
   parent_cmd=$(ps -p $PPID -o comm= 2>/dev/null || echo unknown)
   case "$parent_cmd" in
     claude|node|*claude-code*|*claude.app*)
       echo "[attest-override] refuse: parent process '$parent_cmd' looks like Claude/agent."
       echo "If this is a false positive, set ATTEST_OVERRIDE_CONFIRM_PARENT=1 and rerun."
       [ "${ATTEST_OVERRIDE_CONFIRM_PARENT:-0}" = "1" ] || exit 9
       ;;
   esac
   ```
4. `ans` 精确等于 `OVERRIDE-CONFIRM-<nonce>` → 继续，否则 exit 非零
5. 通过后：
   - 在 `.claude/state/attest-override-log.jsonl` 追加一行 JSON `{"time_utc":"...","target":"...","kind":"file|branch","blob_or_head_sha":"...","reason":"...","git_user":"...","parent_cmd":"...","actor":"manual-cli"}`
   - 在 ledger 写 override 条目（带 `override:true` + `audit_log_line` 索引 + `blob_or_head_sha_at_override`）
6. 日志 append-only；hook 每次验证 `wc -l attest-override-log.jsonl` == 所有 ledger override 条目 `audit_log_line` 之最大值（+ 预设 header 行偏移）；不一致 → block + 提示 "override 日志已被篡改或丢失"

**Defense-in-depth 层**（见 §2.1 settings.json 变更）：
- `Bash(*attest-override.sh*)` 加入 deny（Claude 工具链无法直接调用该脚本，用户手工跑不走 Claude Bash 工具）
- `Bash(* > .claude/state*)`、`Bash(* > .claude/state/*)`、`Bash(python* .claude/state*)`、`Bash(node * .claude/state*)`、`Bash(cat * > .claude/state*)`、`Bash(printf * > .claude/state*)` 全部加 deny，防止 Claude 绕脚本直写台账
- 现有 deny 里 `Bash(* >> .claude/state*)`、`Bash(tee * .claude/*)`、`Bash(sed -i * .claude/*)`、`Bash(rm * .claude/*)`、`Bash(chmod * .claude/*)` 保留

**残余风险明示**：
- 即使全部 deny 命中，用户**本人**跑 attest-override.sh 仍然被 PPID 检查阻挡 Claude，但 Claude 若在交互会话引导用户"来，打一下这个命令"是可能绕过的社工路径 → 这是用户侧责任边界
- 若 Claude 在别的 session 设 `ATTEST_OVERRIDE_CONFIRM_PARENT=1` 绕 PPID 检查，仍能完成流程 → 审计日志会记录 `parent_cmd` 留痕
- 完整堵死：见 hardening-3

**降级门槛**：若 OpenAI API 不可用 + 用户也不愿手工 override → 本 PR 的闸门会 block 所有 plan/spec/code 外发 → 这是**故意的行为**，强迫用户面对 API 问题而非绕行。

### 2.6 codex-attest.sh 扩展

```bash
# 新增 CLI（branch-diff 模式必须显式指定 --head 以避免 current-branch 歧义）
.claude/scripts/codex-attest.sh --scope branch-diff --base origin/main --head <branch>

# 执行逻辑（伪码）：
#   1. 按 --scope 计算 review target（working-tree = 文件；branch-diff = diff）
#   2. 对 branch-diff：解析 --head <branch>（或默认 current），head_sha = git rev-parse <branch>
#      必须显式要求 --head 可查；若缺失或 ambiguous → exit 非零，不调 codex
#   3. 调 codex-companion ... adversarial-review --wait
#   4. 捕获 JSON verdict（codex-companion 已有机器可读输出）
#   5. 若 verdict.approve=true：
#      - working-tree/file：对每个 --focus 文件，从 HEAD 或 --ref 读 blob；写
#        entries["file:$path"] = {kind:"file", blob_sha=..., attest_time_utc, codex_round, verdict_digest}
#      - branch-diff：diff_fp = sha256(git diff <base>...<head_sha> canonical)；写
#        entries["branch:<branch>@<head_sha>"] = {kind:"branch", base:<base>, head_sha:<head_sha>, diff_fingerprint:<diff_fp>, attest_time_utc, codex_round, verdict_digest}
#      **key 格式必须与 guard-attest-ledger.sh 读取时严格一致**（单元测试显式覆盖此 round-trip）
#   6. 若 verdict.approve=false：不更新 ledger；打印 findings；非零 exit
```

---

## 3. 端到端数据流

### 场景 1：我写 plan-X，准备开 PR

1. `Edit docs/superpowers/plans/plan-X.md` → Claude 默认允许（G1 生效）
2. `git add && git commit -m "..."` → 放行（Q3=B，commit 本地私域）
3. `git push origin feature-X` → hook 触发：
   - plan-X.md blob ≠ ledger → **BLOCK**
   - stderr：`跑 .claude/scripts/codex-attest.sh --scope working-tree --focus docs/superpowers/plans/plan-X.md`
4. 我跑 codex-attest → verdict=approve → 台账自动写入
5. 重试 `git push` → blob == ledger → **PASS**
6. `gh pr create --base main --head feature-X`：
   - plan-X.md 文件级 check 通过
   - branch-diff 指纹 ≠ ledger → **BLOCK**
   - stderr：`跑 .claude/scripts/codex-attest.sh --scope branch-diff`
7. 跑 branch-diff attest → approve → ledger 写入 `branch:feature-X@<head_sha>`
8. 重试 `gh pr create` → **PASS**
9. 用户点网页 Merge → **网页路径不被 hook 拦**（明示非目标，见 §1.3）。或 `gh pr merge <N>` 时：hook 解析 `gh pr view <N>` 拿到 PR 真实 headRefOid → 比对 ledger `branch:<headRefName>@<headRefOid>` 命中放行；若分支被 reset 后 headRefOid 变 → BLOCK + 提示重跑 codex-attest

### 场景 2：Codex API 耗尽，手工豁免（方案 Y 修订版）

1. 跑 codex-attest 失败（API error / 额度耗尽）
2. 用户在终端主动跑：
   ```bash
   .claude/scripts/attest-override.sh docs/superpowers/plans/plan-X.md "API quota exhausted 2026-04-19; manually reviewed"
   ```
3. 脚本打印当前 blob 的短 sha（如 `a1b2c3d`）并要求输入 `OVERRIDE-CONFIRM-a1b2c3d`
4. 用户在 tty 里敲入上述串回车（Claude 的 Bash 工具没有 tty 通道，无法替用户输入）
5. 脚本写 `.claude/state/attest-override-log.jsonl` 一行 + ledger override 条目
6. `git push` → hook 命中 override 条目 + blob_sha 一致 → PASS + stderr 醒目 warn "OVERRIDE IN USE"
7. 后续再改该文件（blob 变）→ override 自动失效，必须重过 codex 或重跑 override 脚本

---

## 4. 异常处理

| 情况 | 行为 |
|---|---|
| ledger 文件不存在 | 创建 `{"version":1,"entries":{}}` 后**继续执行完整检查**（不 soft-pass）。涉及 plan/spec/branch-diff 的 push/PR 首次会 BLOCK，提示"首次初始化，请先跑 codex-attest 或 attest-override 再重试" |
| ledger JSON 损坏 | block + 提示 "台账损坏，请检查或从 git 恢复" |
| `git ls-tree <branch>` 失败 | block + 明示错误 |
| 要 push 的 commits 含多个 plan 改动 | 逐个检查，列出所有违规文件（不是首个命中就停） |
| push 的分支没追踪远端 | 退化：`git rev-list <branch> ^origin/main` + stderr warn；计算仍失败 → block |
| codex-attest 中途 Ctrl+C | ledger 不更新；状态保持一致 |
| `gh pr view <target>` 失败（网络 / target 不存在） | block + 提示"PR 解析失败，请检查 target" |
| attest-override.sh 在非 tty 环境调用（stdin 被 pipe） | 脚本 `[ -t 0 ]` 断言失败，立即 exit + stderr "override 必须在真实 tty 下手工执行" |
| override confirm 串不匹配 | exit + stderr 错误，不写任何状态 |
| PR base 不是 main | 场景 B/C 按 parse 到的 --base 计算 branch-diff；不做 main-only 限制 |

---

## 5. 测试策略

### 5.1 单元测试（hook）
- 模拟 stdin JSON，喂三类 command（push / pr create / pr merge），分别断言：
  - 无 plan/spec 改动 → exit 0
  - plan 改动但 ledger 命中（匹配 `file:<path>` blob sha） → exit 0
  - plan 改动且 ledger 不命中 → exit 2 + stderr 含文件路径
  - `gh pr create --head feature-other`（非当前分支） → 解析 --head 正确，按 feature-other 的 head SHA 查台账
  - `gh pr merge 42` → 调 `gh pr view 42` 得到真实 headRefOid，按该 SHA 查台账
  - ledger 首次不存在 → 自动创建 + **继续完整检查**，涉及 plan/spec 改动时 exit 2
  - override ledger 条目存在 + blob 一致 → exit 0 + stderr "OVERRIDE IN USE"
  - override 条目存在但当前 blob 已变 → override 失效，按普通 attestation 检查

### 5.2 集成测试（本仓库手工走一遍）
- 修改一个 plan 文件 → 尝试 push → 断言被拦
- 跑 codex-attest（若 API 不可用，按 §2.5 跑 `attest-override.sh` 于真实 tty 代替） → 断言台账写入
- 重试 push → 断言通过

### 5.3 override tty 防护专项
- 用 Claude 的 Bash 工具尝试 `.claude/scripts/attest-override.sh` 的多种绕过 pattern：
  - stdin pipe：`echo CONFIRM | ./attest-override.sh`
  - here-doc：`./attest-override.sh <<< "CONFIRM"`
  - `bash -c 'exec ./attest-override.sh ...'`
- 全部断言脚本 `[ -t 0 ]` 断言失败，exit 非零，不写任何状态文件

### 5.3 回归验证
- gov-bootstrap-hardening merge 后，Plan 0a v3 split 的 plan 文件若未改动 → push 不被拦
- 已有 CLAUDE.md / .claude/hooks/** 编辑仍然被 deny 挡

---

## 6. 改名（R）落地清单

### 6.1 ✅ 改（本次 PR）

| 原名 | 新名 |
|---|---|
| memory `project_plan0b_naming_informal.md` | `project_gov_bootstrap_naming.md`（内容保留 "曾用名 plan-0b" 注记） |
| memory `feedback_codex_review_direction_fallback.md` 中文字引用 | "plan-0b" → "gov-bootstrap"（文件名保留） |
| memory `feedback_post_bootstrap_audit_findings.md` 中文字引用 | 同上 |
| `docs/superpowers/plans/2026-04-18-claude-md-reset-plan.md` 中文字引用 | 同上 |
| `docs/superpowers/specs/2026-04-17-claude-md-reset-design.md` 中文字引用 | 同上 |
| MEMORY.md 索引行 | 更新链接与描述 |
| 本次新文件 spec / plan / PR title / branch name | 全用 `gov-bootstrap-hardening` |

### 6.2 ❌ 不改（保持历史原样）

- PR #14 title / body / merged branch 名称 `plan-0b/claude-md-reset-20260418`
- Commit messages（cf36890 / 819c1b4 等）
- 已关闭的对话/issue 历史

---

## 7. 非 coder 验收清单

（语言：中文；格式：action / expected / pass_fail；禁用 "通过即可 / 看起来正常 / 应该没问题 / should work / looks fine"）

| # | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 改动任一 `docs/superpowers/plans/*.md` → 在终端跑 `git push origin <feature-branch>` | 终端显示红色 BLOCK 提示，含文件路径和 "跑 codex-attest" 指令 | 出现 BLOCK 提示 = PASS；成功 push = FAIL |
| 2 | 接着跑 `.claude/scripts/codex-attest.sh --scope working-tree --focus <改过的文件>` 并等 Codex 返回 approve | `.claude/state/attest-ledger.json` 新增该文件的 blob_sha 条目 | ledger 有条目 = PASS；无变化 = FAIL |
| 3 | 再次 `git push origin <feature-branch>` | 命令执行完成，输出含 `To github.com/...` 或 `Everything up-to-date` | push 成功 = PASS；被拦 = FAIL |
| 4 | 改动 `docs/superpowers/specs/*.md` → 重复 #1 | 与 #1 相同 | 出现 BLOCK 提示 = PASS |
| 5 | 在 feature 分支改代码文件（如 `backend/app/main.py`） → `gh pr create --base main` | 终端显示红色 BLOCK 提示，含 "branch-diff fingerprint 不匹配" 和 "跑 codex-attest --scope branch-diff" 指令 | 出现 BLOCK = PASS；成功创 PR = FAIL |
| 6 | 跑 `.claude/scripts/codex-attest.sh --scope branch-diff --base origin/main` 等 approve | `.claude/state/attest-ledger.json` 新增形如 `branch:<分支名>@<head_sha>` 的条目 | 条目 key 含 head_sha = PASS；无变化或 key 不含 head_sha = FAIL |
| 7 | 再次 `gh pr create --base main` | PR 创建成功，终端输出 PR URL | PR URL 出现 = PASS；被拦 = FAIL |
| 8 | 用 Claude 让它 Edit `docs/superpowers/plans/<random>.md`（测 G1） | 终端**不弹** ask 窗，直接执行编辑 | 不弹窗 = PASS；弹窗 = FAIL |
| 9 | 用 Claude 让它 Edit `CLAUDE.md` 或 `.claude/hooks/guard-attest-ledger.sh`（测 deny 仍生效） | 终端显示 deny 拒绝（"tool use ... denied"） | 显示 deny = PASS；允许编辑 = FAIL |
| 10 | 用 Claude 让它 Edit `.claude/settings.json`（测 ask 仍生效） | 终端**仍弹** ask 窗要你确认 | 弹窗 = PASS；不弹 = FAIL |
| 11 | 用 Claude 让它 Read `.claude/hooks/guard-git-push.sh`（测 G1 对 Read 同样生效） | 终端**不弹** ask 窗，Claude 直接返回文件内容 | 不弹 + 返回内容 = PASS；弹窗 = FAIL |
| 12 | 在真实终端（非 Claude 工具）手工跑 `.claude/scripts/attest-override.sh docs/superpowers/plans/<file> "test override"` → 脚本打印随机短 sha → 用户敲入 `OVERRIDE-CONFIRM-<sha>` → 随后 `git push` | 脚本完成；`.claude/state/attest-override-log.jsonl` 追加一行；push 命中 override 放行且 stderr 出现 `OVERRIDE IN USE` | 三者皆满足 = PASS |
| 13 | 让 Claude 尝试用 Bash 工具 pipe 绕过 tty，如 `echo OVERRIDE-CONFIRM-xxx \| .claude/scripts/attest-override.sh ...` | 脚本拒跑（`[ -t 0 ]` 断言失败）；stderr 出现 "override 必须在真实 tty 下" | 拒跑 = PASS；被 pipe 绕过成功 = FAIL（G2 被 bypass） |
| 14 | 首次 clone 仓库（或删除 `.claude/state/attest-ledger.json`）后立即 `git push` 改过 plan 的分支 | 自动创建空 ledger + **仍然 BLOCK**（不 soft-pass），提示"首次初始化，请先跑 codex-attest" | BLOCK = PASS；soft-pass 放行 = FAIL（首次 bypass） |
| 15 | 在当前分支改 plan + `git push origin HEAD:feature-other`（推送到非 current 的分支名）| hook 解析 refspec 真实 src-branch 并校验；若 src 的 plan blob 未在 ledger → BLOCK | BLOCK = PASS；按 current 误判放行 = FAIL |
| 16 | 运行 `grep -r "plan-0b" docs/ memory/ MEMORY.md` | 输出**只**出现在 `project_gov_bootstrap_naming.md` 的"曾用名"注记段落中 | 仅注记段 = PASS；其他地方有残留 = FAIL |
| 17 | 访问 GitHub 网页 PR #14 | 标题 / branch / commit messages 仍显示 "plan-0b"（历史不改） | 保持原样 = PASS |
| 18 | 在 GitHub 网页点击 Merge 合并一个**未过 codex** 的新 PR（边界明示测试） | hook **不生效**；PR 被 merge；§1.3 明示此路径**不在本 PR 覆盖**，本次测试结果作为文档化的已知 gap | merge 成功 = PASS（本 PR 不承诺拦此路径）；误以为拦住并 claim 成功 = FAIL |
| 19 | 在 feature 分支**只改 code**（不动 plan/spec），跑 `git push origin HEAD` | hook 触发 code branch-diff 检查；ledger 未命中 → BLOCK，提示跑 `codex-attest --scope branch-diff` | BLOCK = PASS；code-only push 放行 = FAIL（对应 round2 #1） |
| 20 | bare `git push`（无参数）和 bare `gh pr merge`（无参数） | hook 照常触发并进行场景 A/C 检查 | 两者都被解析并检查 = PASS；任一绕过 = FAIL（对应 round2 #2） |
| 21 | 跑 `gh pr merge <N>` **不带** `--match-head-commit` | hook BLOCK，要求改写为 `gh pr merge <N> --match-head-commit <headRefOid>` | BLOCK = PASS；放行 = FAIL（对应 round2 #3） |
| 22 | 跑 `gh pr merge <N> --match-head-commit <X>`，其中 `<X>` ≠ `gh pr view <N>` 当前的 headRefOid | hook BLOCK，提示 SHA 不匹配 | BLOCK = PASS |
| 23 | 跑 `codex-attest.sh --scope branch-diff --head feature-X` 成功 approve 后，hook 在 `gh pr create --head feature-X` 时能命中台账 | ledger key = `branch:feature-X@<head_sha>` 与 hook 读的 key 严格一致 → PASS | 命中 = PASS；不命中（writer/reader key mismatch）= FAIL（对应 round2 #4） |
| 24 | 让 Claude 用 Bash 工具尝试直接调 `.claude/scripts/attest-override.sh`（任意形式） | settings.json deny 命中，拒绝执行 | 拒绝 = PASS（对应 round3 F1 defense-in-depth） |
| 25 | 让 Claude 用 Bash 尝试 `echo '{...}' > .claude/state/attest-ledger.json` 或等价的 python/node 写法绕过脚本直写台账 | deny 命中，拒绝执行 | 拒绝 = PASS（对应 round3 F1） |
| 26 | 用户手工在真实 tty 运行 `.claude/scripts/attest-override.sh <file> <reason>`，脚本读到 PPID 父进程不像 Claude 时正常往下走 | 打印 nonce + 等 input；用户敲入正确 `OVERRIDE-CONFIRM-<nonce>` 后脚本完成 + log/ledger 各加一条 | 全流程走通 + 日志/台账各 +1 = PASS |
| 27 | 让 Claude 在其 Bash 工具里（PTY 视为 tty）跑 attest-override 脚本，首先 deny 被命中（测 #24）；假定 deny 放行，脚本的 PPID 检查拒跑 | Claude Bash 父进程 comm 匹配 `claude\|node\|*claude-code*` → 脚本 exit 9 + 提示"parent process looks like Claude/agent" | exit 9 = PASS（attest 攻击成本抬高） |
| 28 | 在一个干净 clone 里 `.claude/state/attest-ledger.json` 和 `attest-override-log.jsonl` 都不应以 tracked 文件出现 | `git ls-files .claude/state/` 只输出 `.claude/state/.gitkeep` | 仅 .gitkeep = PASS；其他 state 文件 tracked = FAIL（对应 round3 F2） |
| 29 | 尝试 `git add .claude/state/attest-ledger.json` 后跑 `git commit` | pre-commit-diff-scan.sh 扩展命中；block + 提示"不应提交本地 attestation 状态" | block = PASS（对应 round3 F2 staging 拦截） |
| 30 | 查 Plan 0a v3 split 的 plan 文档（`docs/superpowers/plans/2026-04-18-plan-0a-v3-split.md`）Task 顺序 | 恢复 Plan 0a v3 前已按本 spec §8 的 F3 注解 reorder（codex-attest 前置），文档末尾或 Self-Review 有明确记录 | 已 reorder = PASS；仍是 push → codex = FAIL（Plan 0a v3 阻塞） |
| 31 | 让 Claude Read `.env` 或 `secrets/foo` 或 `~/.ssh/id_rsa`（测 R4-F1 secret deny） | Read 被 deny 拒绝 | 拒绝 = PASS；放行读取 = FAIL |
| 32 | 让 Claude Edit/Write 同类文件（测 R4-F1） | 同 #31 | 拒绝 = PASS |
| 33 | 让 Claude Bash `cat .env`、`cat secrets/foo`、`echo x > .env` | Bash deny 命中 | 拒绝 = PASS |
| 34 | 让 Claude Read `.env.example`（非 secret） | 允许读取（样例文件无密）| 读取成功 = PASS；被误拦 = FAIL（说明 pattern 过宽）|
| 35 | 让用户在**普通终端**（非 Claude Code 工具）执行 `git push origin feature-X`（feature-X 包含未过 codex 的 plan 改动）| push 成功（**hook 不生效**；明示非目标，见 §1.3）| push 成功 = PASS（本 PR 不承诺拦此路径）；误以为拦住并 claim 成功 = FAIL |
| 36 | 让 Claude 用 Bash 尝试伪造 ledger 的**各种写法变种**：`cp tmp.json .claude/state/attest-ledger.json` / `mv tmp.json .claude/state/...` / `install tmp.json .claude/state/...` / `dd if=tmp.json of=.claude/state/...` / `perl -e 'open(...).claude/state/...'` / `ruby -e 'File.open(".claude/state/...", "w")'` / `cat <<EOF > .claude/state/...\n{}\nEOF` | 所有变种均命中 `Bash(*.claude/state*)` 或类似 deny 被拒 | 全部拒绝 = PASS；任一放行 = FAIL（对应 round5 R5-F1）|
| 37 | 让 Claude 跑 `bash .claude/scripts/codex-attest.sh --scope working-tree --focus <file>` | allow 命中，正常执行（脚本内部读写 `.claude/state` 不再经过 Claude Code tool 权限检查，脚本进程自己完成）| 执行成功 = PASS；被 deny 误伤 = FAIL |
| 38 | 让 Claude Read `GoogleService-Info.plist`（iOS FCM 配置，常含 API key） | deny 命中，拒绝 | 拒绝 = PASS |
| 39 | 让 Claude Read `*.mobileprovision`（iOS 证书） | deny 命中，拒绝 | 拒绝 = PASS |
| 40 | 让 Claude Read `.npmrc` / `.netrc` / `.pypirc` / `.pgpass` | deny 命中，拒绝 | 拒绝 = PASS |
| 41 | 让 Claude Read `fastlane/Appfile` 或 `fastlane/Matchfile`（iOS 签名 / Match 仓库密钥路径） | deny 命中，拒绝 | 拒绝 = PASS |

---

## 8. 依赖与边界

- **依赖**：`codex-companion.mjs` 仍在 pinned path `$HOME/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts/codex-companion.mjs`；OpenAI API 可用或用户愿意手工跑 `attest-override.sh` 于真实 tty。
- **不依赖**：GitHub Actions 侧工作流的变更（codex-review-verify.yml 保持现状；本 PR 只改本地闸）。
- **与 G3 的接口**：`attest-ledger.json` 结构里预留 `codex_round` / `verdict_digest` 字段供 G3 未来的 task-log.jsonl 读取。
- **与 Plan 0a v3 的交互**（F3）：Plan 0a v3 split 当前 paused；其 plan 文件 Task 5/6 顺序是 "push → PR → 跑 codex"，与本 spec §2.4 "外部可见动作前必须 attested" 冲突。本 PR merge 后，恢复 Plan 0a v3 时必须先：
  1. reorder Task：新 Task 4.5 `跑 codex-attest --scope working-tree --focus <plan>` + 新 Task 4.6 `跑 codex-attest --scope branch-diff --head plan-0a/v3-split` 插在原 Task 5 之前
  2. 原 Task 6（post-PR codex）可保留作为 "server-side cross-check" 注释
  3. 重新跑一轮 spec 对抗评审确认 Plan 0a v3 修正后不再违反 G2

---

## 9. 开放问题（待 codex 评审或用户裁决）

1. ~~hook 判定"被推送的文件集合"~~ — 已收敛：优先 `git rev-list <src> ^origin/<tracked>`，缺失回退 `^origin/main` + warn，再失败 block。
2. ~~`gh pr merge` 场景~~ — 已收敛：hook 用 `gh pr view <target>` 拿 headRefOid，不依赖 current branch。
3. override reason 字段最小长度限制？当前不限；建议 ≥10 字符避免水回答 → **plan 阶段确定阈值**。
4. ledger 过期清理：已 merge 的分支条目何时删除？本 PR 不实现，留给 G3 或后续维护。
5. attest-override.sh 在 CI / 自动化场景（未来 GitHub Actions workflow 里调用）显然会缺 tty → 策略：CI 场景不应调用该脚本（server 侧应走 codex-review-verify.yml 的 workflow 路径）。是否需要在脚本里显式把"被 GitHub Actions 调用"也识别为 reject（用 `$CI` / `$GITHUB_ACTIONS` 环境变量）？→ **plan 阶段决定**。

## 10. 对 Codex 对抗评审 findings 的响应

### Round 1（commit b82ce27）

| Finding | 处置 |
|---|---|
| #1 critical: local hook 不能拦网页 merge | §1.3 新增明确"覆盖范围表"，承认本 PR 仅是 Claude-session 层闸门；完整 server-side 闸门延到 hardening-3（与 API 充值同步） |
| #2 high: override marker 自授权 | §2.5 完全重写：废弃 marker，改为真实 tty + 随机 nonce 手工脚本；§2.1 架构件清单新增 `.claude/scripts/attest-override.sh` 并在 settings.json deny 阻止 Claude 绕 tty |
| #3 high: PR checks bound to current branch | §2.4 场景 B/C 重写：parse `--head` / `gh pr view <target>` 拿真实 PR head；ledger key 用 `branch:<name>@<head_sha>` 确保 reset/rebase 后旧台账自动失效 |
| #4 high: missing ledger first-run bypass | §4 异常处理：ledger 不存在→创建后**继续完整检查**，首次涉及 plan/spec/branch-diff 必 BLOCK，不 soft-pass |

### Round 2（commit 466c987）

| Finding | 处置 |
|---|---|
| #1 high: push 路径漏掉 code branch-diff | §2.4 场景 A 新增 3.e 步"code branch-diff 检查"：push 若含 code 文件改动则同时要求 branch-diff 台账命中；§7 新增 #19 验收 |
| #2 high: hook 注册漏 bare 形式 | §2.1 + §2.4 末尾改为"挂载到 PreToolUse[Bash] **无 if 条件** + hook 内 parse 后再决定"，覆盖 bare `git push` / bare `gh pr merge`；§7 新增 #20 |
| #3 high: merge head-SHA race | §2.4 场景 C 新增 5.c 步强制要求 `--match-head-commit <headRefOid>`；不带或不匹配 → BLOCK；§7 新增 #21 #22 |
| #4 medium: codex-attest vs hook ledger key 不一致 | §2.6 codex-attest 伪码改写：branch-diff 必须写 `branch:<branch>@<head_sha>`，强制 `--head` 参数；加"round-trip 单元测试显式覆盖 writer/reader key 一致性"；§7 新增 #23 |

### Round 3（commit 988c507，用户 A3 授权进 Round 4）

| Finding | 处置（方案 Y1 + α） |
|---|---|
| F1 critical: tty 非真正 agent 屏障 | §2.5 完全重写："降级 claim + defense-in-depth" ：(a) 明示 tty 检查非 security 而是 ceremony；(b) 新增 PPID 父进程启发式检查拒 Claude-like 父进程；(c) §2.1 settings.json deny 新增 `Bash(*attest-override.sh*)` + 围堵 `.claude/state/*` 任意写法；(d) 明示完整 agent-proof 延到 hardening-3；§7 新增 #24/#25/#26/#27 验收 |
| F2 high: .claude/state/* 泄漏 git | §2.1 架构件清单新增 `.gitignore` 修改（`.claude/state/*` + `!.claude/state/.gitkeep` 例外）+ pre-commit-diff-scan.sh 扩展拦截 staging；§7 新增 #28/#29 |
| F3 high: Plan 0a v3 流程与 G2 冲突 | §8 依赖与边界新增 "与 Plan 0a v3 的交互" 条目：明示 Plan 0a v3 恢复前必须 reorder Task 5/6（将 codex-attest 前移），并重跑 spec 评审；§7 新增 #30 |

### Round 4（commit 22f944a，用户授权进 Round 5）

| Finding | 处置 |
|---|---|
| R4-F1 high: catch-all Read/Edit/Write 没配 secret deny | §2.1 settings.json `deny` 新增一大组 `Read/Edit/Write(**/.env*)` `secrets/**` `*.pem` `*.key` `id_rsa*` `.ssh/**` `.aws/credentials*` 及对应 Bash `cat`/`>`；`.env.example` 通过更具体的 allow 放行；§7 新增 #31-#34 |
| R4-F2 high: §1.3 覆盖表夸大同 clone 非 Claude 终端 | §1.3 表格改：原"别的 session / 别的用户 CLI ✅ 拦"拆成两行，Claude-session 仍拦，**普通终端 ❌ 不拦**；§7 新增 #35 边界明示测试 |
| R4-F3 high: Plan 0a v3 plan 文件本体未改 | 同步 reorder `docs/superpowers/plans/2026-04-18-plan-0a-v3-split.md`（本 round 另行改动，本 spec 记录关联）|

### Round 5（commit 6729dbb，用户选项 1 授权进 Round 6）

| Finding | 处置 |
|---|---|
| R5-F1 high: ledger 可通过 blacklist 未覆盖的 Bash 写法伪造（cp/mv/install/dd/perl/ruby/heredoc …）| settings.json 的 `.claude/state` 访问改成 **allowlist 模型**：`Bash(*.claude/state*)` catch-all deny；allow 里精确放行 `Bash(bash .claude/scripts/codex-attest.sh:*)` 和 `Bash(.claude/scripts/codex-attest.sh:*)` 两个入口（attest-override 不放行，仅供用户 tty 手工）；§7 新增 #36/#37 覆盖 cp/mv/perl/heredoc 等绕路断言被 deny |
| R5-F2 high: catch-all Read 把未枚举的 credential 放了 | §2.1 deny 扩到 iOS/backend 常见 credential 载体（`.npmrc` / `.netrc` / `.pypirc` / `.pgpass` / `*.p12` / `*.pfx` / `*.mobileprovision` / `GoogleService-Info.plist` / `private_keys/**` / `*_private.key` / `*_rsa` / `fastlane/Appfile` / `fastlane/Matchfile`）；`.env.example` 例外处理明确（plan 阶段验证）；§7 新增 #38-#41 覆盖 iOS 特有载体 |
