# Hardening-6 Skill Invoke Check Framework 设计 Spec

**Status**: drafted 2026-04-22；brainstorming 输出；后续走 writing-plans → subagent-driven-development → codex adversarial review → PR（逐 skill flip 走 H6.1-H6.N 后续 PR）。

**上游触发痛点**：Plan 1f 2026-04-22 实施后用户 audit 发现 **3 个 skill silent skip**（`verification-before-completion` / `requesting-code-review` / `receiving-code-review`），我全程只用 first-line `Skill gate: X` 贴 label，没有通过 Skill 工具 invoke skill content 走流程。memory `feedback_skill_pipeline_3_gaps.md` + `feedback_autonomous_execution_mandate.md` 已登记此 pattern 是反复踩坑的。

## 1. 目标

在现有 `.claude/hooks/` + `.claude/state/` 基础设施之上，**添加一层 Stop-hook** 校验：响应 first-line `Skill gate: X` 与该响应内 Skill tool 实际 invoke 记录的**匹配性**。

### 1.1 Goal

- **层 1 enforcement**：当 Claude 在响应里声明使用某 skill（`Skill gate: X`），该响应必须包含对 X 的 Skill tool 调用（或满足 exempt 白名单）
- **config 驱动**：13 skill 在 `.claude/config/skill-invoke-enforced.json`（新文件）里分档管理（`observe` / `block`）
- **滚动激活**：H6.0 建框架（所有 skill 初始 `observe`），后续 H6.1-N 每 PR 翻一个 skill 到 `block`
- **审计可追溯**：drift 写入 `.claude/state/skill-invoke-drift.jsonl`

### 1.2 Non-Goal（明确排除，防 hardening-5 重蹈）

- **层 2 artifact check**（检查 skill 是否真产出了预期文件 / 测试 / commit）→ 登记 **H7 backlog**，等痛点驱动逐 skill 加
- **auto-inject skill content**（自动给 Claude load skill content）→ 不做，超出 scope
- **codex:adversarial-review 纳入本 hook**→ 不做，独立 `attest-ledger` + `guard-attest-ledger` 已完整 enforce
- **writing-skills / frontend-design** → 本项目不用，不进 config
- **修改现有 `stop-response-check.sh`**→ 不动；新 hook 作为 **独立 Stop-hook**，互不影响

## 2. 架构

### 2.1 新增文件

| 文件 | 作用 | 预估行数 |
|---|---|---|
| `.claude/hooks/skill-invoke-check.sh` | Stop-hook 主脚本：解析 first-line + scan tool uses + 查 config + 写 drift log / BLOCK | ~150 |
| `.claude/config/skill-invoke-enforced.json` | 13 skill 的 `mode` / `flip_phase` / `exempt_rule` 配置 | ~60 |
| `.claude/state/skill-invoke-drift.jsonl` | append-only drift log（空初始化）| 0（新建）|
| `.claude/settings.json` | 新增 `Stop.skill-invoke-check` hook 节点 | +4 行 |
| `tests/hooks/test_skill_invoke_check.sh` | 单元测试（每种触发/豁免/block 路径）| ~200 |

### 2.2 Hook 逻辑流（Stop trigger）

```
Claude 响应完成 → Stop event → 本 hook 触发
│
▼
解析 response first-line
│
├─ 空 / 非 `Skill gate:` 格式 → exit 0（既有 `stop-response-check.sh` 已 drift-log 此情况，本 hook 不重复）
│
├─ `Skill gate: exempt(<reason>)` 
│   ├─ reason ∈ 白名单（behavior-neutral / user-explicit-skip / read-only-query / single-step-no-semantic-change）→ exit 0
│   └─ reason 不在白名单 → exit 2 BLOCK（既有 hook 也会 block；此处重复 check 作为防御）
│
├─ `Skill gate: <skill-name>`
│   │
│   ├─ skill-name 不在 `skill-invoke-enforced.json` → drift-log 记 "未知 skill gate"，exit 0（不 block，让手动 skill 也能过）
│   │
│   ├─ skill-name ∈ config
│   │   │
│   │   ├─ 扫响应内 tool_uses，查是否有 `Skill` 工具调用且 skill 参数 == skill-name
│   │   │   ├─ 有 → exit 0（OK）
│   │   │   └─ 无 → 检查 exempt_rule
│   │   │       │
│   │   │       ├─ exempt_rule == "plan-doc-spec-frozen-note"（仅 brainstorming 用）
│   │   │       │   └─ 当前 response 是否产出 plan doc 且 doc 含 "brainstorming skipped: spec frozen" 字串？→ exit 0
│   │   │       │
│   │   │       ├─ exempt_rule == "plan-start-in-worktree"（仅 using-git-worktrees 用）
│   │   │       │   └─ 当前 cwd 是否在 `.worktrees/` 下？→ exit 0
│   │   │       │
│   │   │       └─ 无 exempt 匹配
│   │   │           ├─ config.mode == "observe" → drift-log，exit 0
│   │   │           └─ config.mode == "block" → drift-log + exit 2 BLOCK + stderr 提示用户如何修复
│
└─ 错误 / 解析失败 → exit 0 fail-open（不拦截，防 hook 自身 bug 卡死工作流）
```

### 2.3 Config 文件 schema

`.claude/config/skill-invoke-enforced.json`：

```json
{
  "version": "1",
  "description": "Hardening-6 skill-invoke-check enforcement config. mode=observe 记 drift 不 block；mode=block 缺 invoke 直接拒响应。flip_phase 追踪何时从 observe 翻 block。",
  "enforce": {
    "superpowers:brainstorming": {
      "mode": "observe",
      "flip_phase": "H6.5",
      "exempt_rule": "plan-doc-spec-frozen-note"
    },
    "superpowers:writing-plans": {
      "mode": "observe",
      "flip_phase": "H6.6"
    },
    "superpowers:subagent-driven-development": {
      "mode": "observe",
      "flip_phase": "H6.7"
    },
    "superpowers:test-driven-development": {
      "mode": "observe",
      "flip_phase": "H6.8"
    },
    "superpowers:verification-before-completion": {
      "mode": "observe",
      "flip_phase": "H6.1"
    },
    "superpowers:requesting-code-review": {
      "mode": "observe",
      "flip_phase": "H6.2"
    },
    "superpowers:receiving-code-review": {
      "mode": "observe",
      "flip_phase": "H6.3"
    },
    "superpowers:finishing-a-development-branch": {
      "mode": "observe",
      "flip_phase": "H6.9"
    },
    "superpowers:using-git-worktrees": {
      "mode": "observe",
      "flip_phase": "H6.4",
      "exempt_rule": "plan-start-in-worktree"
    },
    "superpowers:using-superpowers": {
      "mode": "observe",
      "flip_phase": "永久",
      "note": "meta skill, auto-loaded at session start"
    },
    "superpowers:executing-plans": {
      "mode": "observe",
      "flip_phase": "永久",
      "note": "本项目用 subagent-driven-development，保留列表但不 flip"
    },
    "superpowers:systematic-debugging": {
      "mode": "observe",
      "flip_phase": "永久",
      "note": "低频触发，先观察"
    },
    "superpowers:dispatching-parallel-agents": {
      "mode": "observe",
      "flip_phase": "永久",
      "note": "偶尔 POC 并行，低频"
    }
  }
}
```

**合计 13 个 skill，0 个 block**（初始全 observe）。

### 2.4 Drift log 格式

`.claude/state/skill-invoke-drift.jsonl`（append-only），每行一条 JSON：

```json
{
  "time_utc": "2026-04-22T08:00:00Z",
  "session_id": "019db3a4-xxxx...",
  "response_sha": "sha256:abc123...",
  "gate_skill": "superpowers:verification-before-completion",
  "config_mode": "observe",
  "invoked": false,
  "exempt_rule_matched": null,
  "drift_kind": "gate_declared_no_invoke"
}
```

**字段获取**：
- `session_id`: 从环境变量 `$CLAUDE_SESSION_ID` 读取；若无则 `"unknown"`
- `response_sha`: `shasum -a 256` 对 response text（去掉 first-line）计算
- `gate_skill`: 从 first-line 正则捕获
- `invoked` / `exempt_rule_matched`: hook 逻辑输出
- `drift_kind`: 5 种之一（见下）

5 种 `drift_kind`：
- `gate_declared_no_invoke`（本 hook 主逻辑）
- `unknown_skill_in_gate`（不在 config）
- `exempt_rule_no_match`（有 exempt_rule 但条件不满足）
- `parse_error`（first-line 解析失败，fail-open 前记录）
- `block_triggered`（mode=block 且 check fail，记录后 exit 2）

## 3. 豁免条款详述

### 3.1 `plan-doc-spec-frozen-note`（brainstorming 专用）

**触发场景**：用户在 spec 已冻结的项目里做 module plan（Plan 1/1b/1c/1d/1f 都是这场景），跳过 brainstorming 直接 writing-plans 合理。

**检测逻辑**：
- 响应里检测有 `Skill gate: superpowers:writing-plans` first-line
- 且响应内有 Write/Edit 到 `docs/superpowers/plans/*.md` 的 tool_use
- 且写入的 plan doc 内容包含 `brainstorming skipped: spec <X> frozen`（正则：`brainstorming skipped.*spec.*frozen`）
- 所有条件满足 → pass（即使 config[brainstorming].mode=block 也 pass）

**设计意图**：不让 spec-frozen 场景被 block，但强制 **显式注记**（防遗忘）。

### 3.2 `plan-start-in-worktree`（using-git-worktrees 专用）

**触发场景**：新 plan 起手，response first-line 贴 `Skill gate: superpowers:using-git-worktrees`。

**检测逻辑**：
- 响应内有 Bash 调用含 `git worktree add` 字串 → pass
- 或响应内 pwd 已在 `.worktrees/` 下（worktree 已存在复用）→ pass
- 否则 → drift/block

**设计意图**：worktree 操作是 CLI 操作，不是 Skill 工具调用。豁免规则适配其特殊性。

## 4. 滚动激活计划（H6.0 - H6.9）

| PR | 内容 | 改动文件 | 预估 codex 轮数 |
|---|---|---|---|
| **H6.0** | 建框架：新 hook + config + settings 挂钩 + tests（13 skill 全 observe） | hook.sh + config.json + settings.json + tests + spec + plan + acceptance | 2-3 |
| H6.1 | flip `verification-before-completion` → block | config.json 1 行 + 新单元测试 | 1-2 |
| H6.2 | flip `requesting-code-review` → block | 同 | 1-2 |
| H6.3 | flip `receiving-code-review` → block | 同 | 1-2 |
| H6.4 | flip `using-git-worktrees` → block（带 plan-start-in-worktree 豁免）| config + hook 豁免逻辑测试 | 2-3 |
| H6.5 | flip `brainstorming` → block（带 plan-doc-spec-frozen-note 豁免）| config + hook 豁免逻辑测试 | 2-3 |
| H6.6-H6.9 | flip writing-plans / subagent-driven-development / test-driven-development / finishing-a-development-branch | 同 config 1 行 | 每 1-2 |

**每 PR 硬约束**（吸收 hardening-5 教训）：
- **3 轮 codex 内收敛**，超 3 轮主动 escalate 用户选 residual accept 或继续修
- scope 锁定 config + hook 改动，不扩到"顺便监控 Y"

## 5. 组件 / 数据流

### 5.1 组件拓扑

```
┌─────────────────────────────────────────────────────┐
│ Claude response (text + tool uses)                  │
│   ↓ Stop event                                      │
└──────────────────┬──────────────────────────────────┘
                   │
    ┌──────────────▼──────────────────────────┐
    │ Existing: stop-response-check.sh        │
    │  (first-line exist check, drift-log)    │
    │  不动                                    │
    └──────────────┬──────────────────────────┘
                   │
    ┌──────────────▼──────────────────────────┐
    │ NEW: skill-invoke-check.sh              │
    │  1. parse first-line                    │
    │  2. scan tool_uses for Skill invoke     │
    │  3. lookup config                       │
    │  4. check exempt_rule if needed         │
    │  5. drift-log OR block OR pass          │
    └──────────────┬──────────────────────────┘
                   │
            ┌──────┴──────┐
            ▼             ▼
    ┌───────────────┐ ┌────────────────┐
    │ drift log     │ │ block (exit 2) │
    │ (append)      │ │ stderr msg     │
    └───────────────┘ └────────────────┘
```

### 5.2 Tool uses parser

**关键问题**：Stop-hook 读取 response 的方式。

现有 `stop-response-check.sh` 通过 `CLAUDE_RESPONSE_TEXT` 环境变量或 stdin 读响应文本。Skill tool call 在 response 里以 XML 格式嵌入（`<function_calls>` 块）。需要在 bash 里 parse XML（有限功能）。

**实现思路**（简化）：
```bash
# 扫响应里的 Skill invoke（grep 级 pattern，不做完整 XML parse）
invoked_skill=$(echo "$RESPONSE_TEXT" | grep -oE '<invoke name="Skill">.*?<parameter name="skill">[^<]+' | head -1 | sed -E 's/.*<parameter name="skill">//')
```

**局限**：若响应里多个 Skill 调用，只取第 1 个。这足够——per skill 原则"1 response 1 skill"。如果 Claude 调多个，后续补 multi-match。

### 5.3 Exempt rule dispatcher

不同 skill 的 exempt_rule 逻辑不同，集中在一个 shell function：

```bash
check_exempt() {
    local rule="$1"
    local response_text="$2"
    case "$rule" in
      "plan-doc-spec-frozen-note")
        # 检测 plan doc 写入 + spec-frozen note
        echo "$response_text" | grep -qE 'brainstorming skipped.*spec.*frozen'
        ;;
      "plan-start-in-worktree")
        # 检测 worktree 操作或 cwd in .worktrees
        echo "$response_text" | grep -qE 'git worktree add' \
          || [[ "$PWD" == */\.worktrees/* ]]
        ;;
      *)
        return 1  # unknown rule = no exempt
        ;;
    esac
}
```

## 6. 测试策略

### 6.1 单元测试

`tests/hooks/test_skill_invoke_check.sh`（bash-based，参考现有 `tests/hooks/test_*.py` 模式）：

| 测试场景 | 期望行为 |
|---|---|
| first-line = `Skill gate: exempt(read-only-query)` | pass |
| first-line = `Skill gate: exempt(invalid-reason)` | exit 2 block |
| first-line = `Skill gate: unknown-skill` | drift-log + exit 0 |
| first-line = `Skill gate: superpowers:X` + response 有 Skill invoke X | pass |
| first-line = `Skill gate: superpowers:X` + response 无 Skill invoke + mode=observe | drift-log + exit 0 |
| first-line = `Skill gate: superpowers:X` + response 无 Skill invoke + mode=block | drift-log + exit 2 |
| brainstorming 缺 invoke + plan doc 含 spec-frozen note | pass（豁免） |
| brainstorming 缺 invoke + plan doc 无 spec-frozen note + mode=block | exit 2 |
| using-git-worktrees 缺 invoke + response 含 `git worktree add` | pass（豁免） |
| using-git-worktrees 缺 invoke + response 无 worktree + mode=block | exit 2 |

**覆盖率目标**：每个 `case` 分支 ≥ 1 个测试。

### 6.2 集成测试

`scripts/acceptance/hardening_6_framework.sh`：
- hook 文件存在且可执行
- config 文件合法 JSON 且含 13 skill
- drift log 可写（权限 + 目录存在）
- settings.json 含 `Stop.skill-invoke-check` 节点
- 单元测试全绿
- 不 regression 现有 Plan 1/1b/1c/1f acceptance

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| Hook 自身 bug 卡住所有响应 | fail-open 策略：parse error / unknown state → exit 0 drift-log + WARN stderr，不阻塞 |
| First-line parser false positive/negative | 现有 `stop-response-check.sh` 已有成熟 parser 可复用 |
| Stop hook 过多性能拖慢响应 | hook 全 bash + 只 grep，单次 <100ms；新 hook 独立可被 disable |
| Config 脏数据（手改错）| 单元测试加 config 合法性 check，CI 兜底 |
| 豁免规则漏检（如 spec-frozen note 用户用不同措辞） | 第一版用正则 `brainstorming skipped.*spec.*frozen`；如实战 false-positive 多，H6.N 调整 |
| 累积 drift log 过大 | 默认 append；H6.N 补 rollup/rotate 脚本（不在 H6.0 scope） |

## 8. 依赖 / 不依赖

**依赖（hard prereq）**：
- PR #22 skill-router-hook 已 merged（UserPromptSubmit 注入路由表）
- PR #19 hardening-2 已 merged（drift-log 基础设施 + stop-response-check.sh）
- `.claude/scripts/ledger-lib.sh` 可复用（jsonl append 模式）

**不依赖**：
- codex:adversarial-review（独立机制）
- 任何业务 Plan（Plan 1f 已 merged；Plan 2/3 未开）
- Plan 1e 本地 branch（artifacts 与本 plan 无关）

## 9. 跨 Plan 后续 backlog

**H7 层 2 artifact check**（痛点驱动加）：
- brainstorming → 检查是否新增 `docs/superpowers/specs/YYYY-*.md`
- writing-plans → 检查是否新增 `docs/superpowers/plans/YYYY-*.md`
- test-driven-development → 检查是否有测试 commit
- subagent-driven-development → 检查是否有 Agent tool 调用 ≥ N 次
- verification-before-completion → 检查响应是否有 Bash tool 跑测试命令
- finishing-a-development-branch → 检查是否有 push / PR 操作

**每个 artifact check 独立小 PR**，单个 skill scope。等实际痛点触发（某次又发现 skill tool 调了但没产 artifact）再做。

**override 频率监控 backlog**：
- attest-override-log.jsonl 每月 rollup
- 检测 override 率是否超阈值（如 >5 次/月）
- 超阈值时警告 user 是否该再次 pivot 治理

## 10. 执行切换提示

Spec approved → 进入 writing-plans，起草 H6.0 的 task 列表（2-3 个 task：框架 hook + config + tests）。

H6.0 plan 走完 subagent-driven-development + codex review + PR 后，后续 H6.1-H6.9 每个都是 **"config 1 行改动 + 新测试用例 + 新单元测试"** 的极小 PR，预计每个 ≤30 分钟。

---

**Spec 自查清单（skill §Spec Self-Review 4 项）**：

1. Placeholder scan — `<if available>` 占位（§2.4 drift log session_id）需澄清：写入 log 时取 `$CLAUDE_SESSION_ID` 环境变量，若无则 `"unknown"`。**已修**
2. 内部一致性 — 13 skill 数：§2.3 config + §1.1 Goal + §4 rollout 表一致；豁免规则数：§3 两条 + §2.3 config 两条一致
3. Scope check — 单个 spec，1 个 H6.0 框架 PR；后续 H6.1-H6.9 每个独立 PR。scope 是 "H6.0 框架" 本身，不包含 flip
4. Ambiguity check — "first-line 严格格式" 已定（`^Skill gate: (exempt\([a-z-]+\)|[a-z-]+:[a-z-]+)$`）；"tool_uses parser" 已说明用 grep
