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

### 1.3 非目标

- G3（skill pipeline 顺序强制 / `.claude/state/task-log.jsonl` hook 化 / skill 调用与声明匹配）— 延到 `gov-bootstrap-hardening-2`
- Codex API 充值 / 升回 🅰️ 方向（独立决策，与本 PR 解耦）
- PR #13 (Plan 0a v3) 的继续推进（被本 PR block，本 PR merge 后恢复）

---

## 2. 架构

### 2.1 新增 / 改动件清单

| 类型 | 路径 | 说明 |
|---|---|---|
| 新增 hook | `.claude/hooks/guard-attest-ledger.sh` | PreToolUse Bash，触发点 `git push:*` / `gh pr create:*` / `gh pr merge:*` |
| 新增 state | `.claude/state/attest-ledger.json` | 台账：记录每个 plan/spec 文件和每个 feature 分支的"最近一次 approve 时的指纹" |
| 新增 state | `.claude/state/attest-override-log.jsonl` | append-only 审计日志，记录每次 override 事件 |
| 改动 script | `.claude/scripts/codex-attest.sh` | 增加 `--scope branch-diff` 模式；成功 approve 后写入台账 |
| 改动 settings | `.claude/settings.json` | `allow` 加 `Write` / `Edit` / `Read` 三条裸名；`hooks.PreToolUse[Bash]` 挂新 hook |
| 改动 hook 注册 | `.claude/settings.json` | 给 `.claude/hooks/guard-attest-ledger.sh` 加 `if` 条件，覆盖 push/pr create/pr merge |
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
    "branch:feature-X": {
      "kind": "branch",
      "base": "origin/main",
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
      "audit_log_line": 3
    }
  }
}
```

### 2.4 hook `guard-attest-ledger.sh` 逻辑

```
输入（stdin JSON）：
  {"tool_name": "Bash", "tool_input": {"command": "<git push ... | gh pr create ... | gh pr merge ...>"}}

步骤：
  1. 解析 tool_input.command，匹配三种模式之一（否则 exit 0 放行）
  2. 初始化 ledger：若 .claude/state/attest-ledger.json 不存在，创建 {version:1, entries:{}}，并给 stderr 打 "[attest-ledger] 首次初始化，本次软放行"，exit 0
  3. 场景 A（`git push ...`）：
     a. 解析被推送分支（默认 current HEAD）
     b. 计算 commits-to-push = `git log <remote-tracking>..<local-head>` 的文件变更集合
     c. 过滤出 plan/spec 文件：`docs/superpowers/plans/*.md` | `docs/superpowers/specs/*.md`
     d. 对每个文件：current_blob = `git hash-object $file`；ledger_blob = entries["file:$path"].blob_sha
     e. 不一致且无 override → 收集违规
     f. 检查 override marker（见 §2.5）：若文件包含 <!-- attest-override: ... -->，写 audit log、更新 ledger 为 override 状态、移除违规
     g. 任一违规 → 输出 decision=block + 完整清单 + "跑 .claude/scripts/codex-attest.sh --scope working-tree --focus <file>"
  4. 场景 B（`gh pr create ...`）：
     a. 推断 base = --base 参数 or 默认 main；head = 当前分支
     b. 执行场景 A 的文件级检查（plan/spec）
     c. 额外执行 branch-diff 检查：fingerprint = sha256(`git diff origin/$base...HEAD`)
     d. ledger_fp = entries["branch:$head"].diff_fingerprint
     e. 不一致 → 收集违规（提示 "跑 .claude/scripts/codex-attest.sh --scope branch-diff"）
  5. 场景 C（`gh pr merge ...`）：同场景 B
  6. exit code 2（block） or 0（pass）
```

### 2.5 override marker（人工豁免机制，方案 Y）

在 plan/spec 文件任意位置插入 HTML 注释：

```html
<!-- attest-override: reason="Codex API rate-limited; manual proceed" -->
```

hook 检测到后：
- 在 `.claude/state/attest-override-log.jsonl` 追加一条 JSON 行：`{"time_utc":"...","file":"...","reason":"...","git_user":"...","blob_sha":"..."}`
- 更新 ledger 条目为 override 状态
- 放行本次操作
- stderr 打醒目黄色 warn："[attest-ledger] OVERRIDE USED on <file>: <reason>"

override 条目在**文件内容再次变化时自动失效**（blob_sha 不一致）→ 必须重新加 marker 或过 codex。

### 2.6 codex-attest.sh 扩展

```bash
# 新增 CLI
.claude/scripts/codex-attest.sh --scope branch-diff --base origin/main

# 执行逻辑变化（伪码）：
#   1. 按 --scope 计算 review target（working-tree = 文件，branch-diff = diff）
#   2. 调 codex-companion ... adversarial-review --wait
#   3. 捕获 JSON verdict（codex-companion 已有机器可读输出）
#   4. 若 verdict.approve=true：
#      - working-tree/file：对每个 --focus 文件，写 entries["file:$path"] = {blob_sha=..., codex_round, verdict_digest}
#      - branch-diff：写 entries["branch:$current_branch"] = {diff_fingerprint=..., base=..., ...}
#   5. 若 verdict.approve=false：不更新 ledger；打印 findings；非零 exit
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
7. 跑 branch-diff attest → approve → ledger 写入 `branch:feature-X`
8. 重试 `gh pr create` → **PASS**
9. 后续用户点网页 Merge 或跑 `gh pr merge` → hook 再过一遍（分支 HEAD 没变则台账命中，放行）

### 场景 2：Codex API 耗尽，手工豁免

1. 跑 codex-attest 失败（API 错误）
2. 我在 plan-X.md 顶部加 `<!-- attest-override: reason="API quota exhausted 2026-04-18; manual review completed by user" -->`
3. `git commit --amend` + `git push` → hook 检测到 marker：
   - 追加 `attest-override-log.jsonl` 行
   - 更新 ledger `entries["file:..."] = {override: true, ...}`
   - stderr warn，放行
4. 后续再修该文件（blob 变化）→ override 失效，需要重新 marker 或过 codex

---

## 4. 异常处理

| 情况 | 行为 |
|---|---|
| ledger 文件不存在 | 自动 `echo '{"version":1,"entries":{}}' > $ledger`；本次软放行 + stderr warn |
| ledger JSON 损坏 | block + 提示 "台账损坏，请检查或从 git 恢复" |
| `git hash-object` 失败 | block + 明示错误 |
| 要 push 的 commits 含多个 plan 改动 | 逐个检查，列出所有违规文件（不是首个命中就停） |
| push 的分支没追踪远端（`git log <remote>..HEAD` 失败） | 退化：计算 `git log HEAD ^origin/main` 的文件改动集合；仍失败 → block + 提示 |
| codex-attest 中途 Ctrl+C | ledger 不更新；状态保持一致 |
| PR base 不是 main | 场景 B/C 仍按 --base 参数计算 branch-diff；不做 main-only 限制 |
| override marker 多行 reason | 正则只取 `reason="..."` 中的内容；未闭合 → block + 提示格式错 |

---

## 5. 测试策略

### 5.1 单元测试（hook）
- 模拟 stdin JSON，喂三类 command（push / pr create / pr merge），分别断言：
  - 无 plan/spec 改动 → exit 0
  - plan 改动但 ledger 命中 → exit 0
  - plan 改动且 ledger 不命中 → exit 2 + stderr 含文件路径
  - override marker 命中 → exit 0 + audit log 行数 +1

### 5.2 集成测试（本仓库手工走一遍）
- 修改一个 plan 文件 → 尝试 push → 断言被拦
- 跑 codex-attest（若 API 不可用，用 override marker 代替） → 断言台账写入
- 重试 push → 断言通过

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
| 6 | 跑 `.claude/scripts/codex-attest.sh --scope branch-diff --base origin/main` 等 approve | `.claude/state/attest-ledger.json` 新增 `branch:<current>` 条目 | ledger 有条目 = PASS；无变化 = FAIL |
| 7 | 再次 `gh pr create --base main` | PR 创建成功，终端输出 PR URL | PR URL 出现 = PASS；被拦 = FAIL |
| 8 | 用 Claude 让它 Edit `docs/superpowers/plans/<random>.md`（测 G1） | 终端**不弹** ask 窗，直接执行编辑 | 不弹窗 = PASS；弹窗 = FAIL |
| 9 | 用 Claude 让它 Edit `CLAUDE.md` 或 `.claude/hooks/guard-attest-ledger.sh`（测 deny 仍生效） | 终端显示 deny 拒绝（"tool use ... denied"） | 显示 deny = PASS；允许编辑 = FAIL |
| 10 | 用 Claude 让它 Edit `.claude/settings.json`（测 ask 仍生效） | 终端**仍弹** ask 窗要你确认 | 弹窗 = PASS；不弹 = FAIL |
| 11 | 用 Claude 让它 Read `.claude/hooks/guard-git-push.sh`（测 G1 对 Read 同样生效） | 终端**不弹** ask 窗，Claude 直接返回文件内容 | 不弹 + 返回内容 = PASS；弹窗 = FAIL |
| 12 | 在 plan 顶部加 `<!-- attest-override: reason="test override" -->` → `git push` | push 成功；`.claude/state/attest-override-log.jsonl` 追加一行含 reason=test override | push 成 + 日志行出现 = PASS |
| 13 | 运行 `grep -r "plan-0b" docs/ memory/ MEMORY.md` | 输出**只**出现在 `project_gov_bootstrap_naming.md` 的"曾用名"注记段落中 | 仅注记段 = PASS；其他地方有残留 = FAIL |
| 14 | 访问 GitHub 网页 PR #14 | 标题 / branch / commit messages 仍显示 "plan-0b"（历史不改） | 保持原样 = PASS |

---

## 8. 依赖与边界

- **依赖**：`codex-companion.mjs` 仍在 pinned path `$HOME/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts/codex-companion.mjs`；OpenAI API 可用或用户接受 override marker 路径。
- **不依赖**：GitHub Actions 侧工作流的变更（codex-review-verify.yml 保持现状；本 PR 只改本地闸）。
- **与 G3 的接口**：`attest-ledger.json` 结构里预留 `codex_round` / `verdict_digest` 字段供 G3 未来的 task-log.jsonl 读取。

---

## 9. 开放问题（待 codex 评审或用户裁决）

1. hook 在判定"被推送的文件集合"时，若 `git log <remote-tracking>..HEAD` 失败（如首次推送、无远端跟踪），应 block 还是退化到 `HEAD ^origin/main`？当前默认退化，可能漏算。
2. `gh pr merge` 场景下，台账命中的时间窗口是否足够？理论上 merge 前最后一刻 HEAD 可能和 PR create 时一致，若分支有新 push 则指纹变。当前方案：每次都 recompute 当前 HEAD vs base 的指纹；若分支 push 后未重跑 codex → block。
3. override 的 reason 字段最小长度限制？当前不限；建议 ≥10 字符避免水回答。
4. ledger 过期清理：已 merge 的分支条目何时删除？本 PR 不实现，留给 G3 或后续维护。
