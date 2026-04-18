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
| Claude 在当前会话里执行 `git push` / `gh pr create` / `gh pr merge` | ✅ 拦 | PreToolUse 生效 |
| Claude 在别的 session / 别的用户 CLI 执行上述命令 | ✅ 拦（同一仓库 hooks 生效） | 前提是 `.claude/hooks` + `.claude/state` 在同一工作区 |
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
| 改动 settings | `.claude/settings.json` | `allow` 加 `Write` / `Edit` / `Read` 三条裸名；`hooks.PreToolUse[Bash]` 挂新 hook；`deny` 新增 `Edit(.claude/scripts/attest-override.sh)` + `Write(...)` + `Bash(echo * \| .claude/scripts/attest-override.sh*)` 阻止 Claude 绕 tty |
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

**新方案**：

用户手工跑一条独立脚本 `.claude/scripts/attest-override.sh`（新增文件，trust-boundary 属 deny + 只 owner 可改）：

```bash
.claude/scripts/attest-override.sh <target-file-or-branch> <reason>
```

脚本逻辑：
1. 读取 target 的当前 blob_sha（file）或 head_sha + diff_fp（branch）
2. **要求 stdin 从真实 tty 读一行确认串**（`read -p "Type OVERRIDE-CONFIRM to authorize: " ans`；用 `[ -t 0 ]` 断言是 tty，否则拒跑 — Claude 的 Bash 工具没有 interactive tty 通道）
3. `ans` 必须精确等于 `OVERRIDE-CONFIRM-<short-blob-sha-prefix>`（短 sha 是脚本事先打印出来的，每次都变；防止用户事先录屏/复制）
4. 通过后：
   - 在 `.claude/state/attest-override-log.jsonl` 追加一行：`{"time_utc":"...","target":"...","kind":"file|branch","blob_or_head_sha":"...","reason":"...","git_user":"...","actor":"manual-cli"}`
   - 在 ledger 写 override 条目（带 `override:true` + `audit_log_line` 索引）
5. 日志行是 append-only，任何篡改导致 `wc -l` vs ledger `audit_log_line` 对不上 → hook block

**为什么这个比 marker 稳**：
- 不能从 Claude 工具链自主走完流程：`read -p` + `[ -t 0 ]` 的 tty 要求让 Claude 的 Bash 工具跑进去会立刻 exit 非零
- 用户必须主动 cd 到仓库根、在 zsh/bash 里敲这条命令 — 一次明确的 context switch
- 审计日志和 ledger 分开文件，互相验证（append-only + 行号索引）

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

---

## 8. 依赖与边界

- **依赖**：`codex-companion.mjs` 仍在 pinned path `$HOME/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts/codex-companion.mjs`；OpenAI API 可用或用户愿意手工跑 `attest-override.sh` 于真实 tty。
- **不依赖**：GitHub Actions 侧工作流的变更（codex-review-verify.yml 保持现状；本 PR 只改本地闸）。
- **与 G3 的接口**：`attest-ledger.json` 结构里预留 `codex_round` / `verdict_digest` 字段供 G3 未来的 task-log.jsonl 读取。

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
