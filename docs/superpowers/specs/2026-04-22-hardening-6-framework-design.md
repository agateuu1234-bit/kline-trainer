# Hardening-6 Skill Pipeline Enforcement Framework 设计 Spec（ζ scope）

**Status**: drafted 2026-04-22；brainstorming 输出（含 6 轮 Q&A 后 scope 升级）；后续走 writing-plans → subagent-driven-development → codex adversarial review → PR（逐 skill flip 走 H6.1-H6.N 后续 PR）。

**重要**：本 spec 历经 **α → α'' → ζ 3 次 scope 迭代**（详见附录 A 决策日志）。最终 scope **ζ 中等野心**，覆盖 Plan 1f 实测的主要漏点（场景 A + D + exempt 滥用），含 mini state 1-step lookahead。完整 state machine β 留 H7，artifact check γ 留 H7。

**痛点触发**：Plan 1f 2026-04-22 audit 发现至少 **5 次场景 A + 2 次场景 D**（详见附录 A §1），涉及 3 个核心 skill（verification-before-completion / requesting-code-review / receiving-code-review）silent skip；既有 `stop-response-check.sh` 因 hardening-2 H2-1 降级为 drift-log advisory，失去强制力。

---

## 1. 目标

### 1.1 Goal（ζ scope）

新增 / 升级 `.claude/hooks/` 若干脚本，做到以下**4 层强制**：

| 层 | 覆盖场景 | 机制 |
|---|---|---|
| L1 声明强制 | **A**：Claude 忘贴 first-line `Skill gate: ...` | 升级 `stop-response-check.sh` 从 drift-log → **hard block**（exempt 白名单放行）|
| L2 invoke 强制 | **D**：声明了但没 Skill tool invoke | **新增** `skill-invoke-check.sh` 扫 tool_uses 匹配 |
| L3 exempt 合理性 | exempt 滥用（如 `read-only-query` 下仍 Edit/Write） | 扩 `stop-response-check.sh` exempt-integrity check |
| L4 mini-state 流程必然性 | 部分 **C**：writing-plans 完 → 必须走 worktree / subagent-driven-development / executing-plans（不能跳 verify / finish） | 新增 `.claude/state/skill-stage.json` 记录上一次成功 stage；hook 查 legal-next-set 表 |

**未覆盖（承认 scope 局限）**：
- 场景 B：Claude 故意选错 skill（需 LLM 判断意图，bash 做不到）
- 完整 state machine（14 skill × transitions × exempts）：留 H7（β）
- Artifact check（声明 brainstorming 必须产 spec.md）：留 H7（γ）

### 1.2 Non-Goal（明确排除，防 hardening-5 重蹈）

- 完整 state machine + 所有 transition rules + per-stage exit conditions → **H7（β）**
- per-skill artifact check（spec 文件 / plan 文件 / 测试结果 / commit 计数）→ **H7（γ）**
- UserPromptSubmit 增强 expected-skill 推断（需 NLP）→ H7
- auto-inject skill content → 不做
- codex:adversarial-review 纳入本 hook → 不做（独立 attest-ledger 完整 enforced）
- writing-skills / frontend-design → 本项目不用
- 修改 `guard-attest-ledger.sh` / `guard-env-read.sh` → 不动

## 2. 架构

### 2.1 新增 / 修改文件

| 文件 | 动作 | 作用 | 预估行数 |
|---|---|---|---|
| `.claude/hooks/stop-response-check.sh` | **升级** | drift-log → hard-block（exempt 白名单放行） + 加 exempt-integrity 校验 | +50 / 改 |
| `.claude/hooks/skill-invoke-check.sh` | **新增** | 扫 Skill tool invoke + mini-state 检查 | ~180 |
| `.claude/config/skill-invoke-enforced.json` | 新增 | 13 skill config (observe/block) + legal-next-set 表 | ~80 |
| `.claude/state/skill-stage.json` | 新增 | mini-state: 记录最近一次成功 skill stage | small |
| `.claude/state/skill-invoke-drift.jsonl` | 新增 | append-only drift log | 空初始化 |
| `.claude/workflow-rules.json` | **修改** | `skill_gate_policy.enforcement_mode`: `drift-log` → `block` | 1 行 |
| `.claude/settings.json` | 修改 | 新增 `Stop.skill-invoke-check` hook 节点 | +4 行 |
| `tests/hooks/test_stop_response_check_block.sh` | 新增 | 升级部分的单元测试 | ~150 |
| `tests/hooks/test_skill_invoke_check.sh` | 新增 | 新 hook 单元测试 | ~250 |

### 2.2 Hook 逻辑流（Stop trigger，两 hook 串联）

```
Claude 响应完成 → Stop event
    │
    ▼
Hook 1: stop-response-check.sh（升级版）
    │
    ├─ first-line 解析
    │   ├─ 缺失 first-line → BLOCK + stderr 提示（"required Skill gate: ..."）
    │   ├─ 格式 invalid → BLOCK
    │   ├─ exempt(<reason>) 且 reason ∈ 白名单 
    │   │   └─ exempt-integrity check（L3）
    │   │       ├─ reason == "read-only-query"
    │   │       │   └─ 响应含 Edit/Write/Bash 非只读 → BLOCK（exempt 滥用）
    │   │       ├─ reason == "behavior-neutral"
    │   │       │   └─ 响应含任何 runtime-affecting 改动 → BLOCK
    │   │       └─ 其他 reason → pass（"user-explicit-skip" 和 "single-step-no-semantic-change" 不做 integrity check，信任用户）
    │   ├─ exempt(<reason>) 且 reason ∉ 白名单 → BLOCK
    │   └─ Skill gate: <skill-name> → pass to Hook 2
    │
    ▼
Hook 2: skill-invoke-check.sh（新增）
    │
    ├─ first-line gate 的 skill-name 在 config？
    │   ├─ 否 → drift-log "unknown_skill_in_gate"，exit 0
    │   └─ 是
    │       │
    │       ├─ 扫响应 tool_uses 找 Skill invoke with matching skill name
    │       │   ├─ 匹配 → L2 pass；进 L4 mini-state check
    │       │   └─ 不匹配 → 查 exempt_rule
    │       │       ├─ "plan-doc-spec-frozen-note" 且 plan doc 含 skip 注记 → pass
    │       │       ├─ "plan-start-in-worktree" 且响应有 `git worktree add` 或 cwd ∈ .worktrees → pass
    │       │       └─ 无匹配豁免
    │       │           ├─ mode == observe → drift-log，exit 0
    │       │           └─ mode == block → BLOCK + stderr
    │       │
    │       └─ L4 mini-state check
    │           ├─ 读 `.claude/state/skill-stage.json` 拿 last_stage
    │           ├─ 查 legal-next-set(last_stage) 表
    │           ├─ 当前 skill ∈ legal-next-set → pass + 更新 last_stage
    │           └─ 当前 skill ∉ legal-next-set
    │               ├─ mode == observe → drift-log "illegal_transition"
    │               └─ mode == block → BLOCK + stderr 提示 "expected next: {legal_set}"
    │
    └─ pass → exit 0
```

**两 hook 配合**：Hook 1 管 "有没有声明 + 声明是否合法"；Hook 2 管 "声明的是否匹配 invoke + 流程顺序"。职责分离。

### 2.3 Config 文件 schema

`.claude/config/skill-invoke-enforced.json`：

```json
{
  "version": "1",
  "description": "Hardening-6 skill invoke check + mini-state enforcement.",
  "enforce": {
    "superpowers:brainstorming": {
      "mode": "observe",
      "flip_phase": "H6.5",
      "exempt_rule": "plan-doc-spec-frozen-note"
    },
    "superpowers:writing-plans": { "mode": "observe", "flip_phase": "H6.6" },
    "superpowers:subagent-driven-development": { "mode": "observe", "flip_phase": "H6.7" },
    "superpowers:test-driven-development": { "mode": "observe", "flip_phase": "H6.8" },
    "superpowers:verification-before-completion": { "mode": "observe", "flip_phase": "H6.1" },
    "superpowers:requesting-code-review": { "mode": "observe", "flip_phase": "H6.2" },
    "superpowers:receiving-code-review": { "mode": "observe", "flip_phase": "H6.3" },
    "superpowers:finishing-a-development-branch": { "mode": "observe", "flip_phase": "H6.9" },
    "superpowers:using-git-worktrees": {
      "mode": "observe", "flip_phase": "H6.4",
      "exempt_rule": "plan-start-in-worktree"
    },
    "superpowers:using-superpowers": { "mode": "observe", "flip_phase": "永久", "note": "meta, auto-loaded" },
    "superpowers:executing-plans": { "mode": "observe", "flip_phase": "永久", "note": "本项目用 subagent-driven-development" },
    "superpowers:systematic-debugging": { "mode": "observe", "flip_phase": "永久", "note": "低频" },
    "superpowers:dispatching-parallel-agents": { "mode": "observe", "flip_phase": "永久", "note": "偶尔 POC 并行" }
  },
  "mini_state": {
    "enabled": true,
    "state_file": ".claude/state/skill-stage.json",
    "legal_next_set": {
      "_initial": [
        "superpowers:using-git-worktrees",
        "superpowers:brainstorming",
        "superpowers:writing-plans",
        "superpowers:systematic-debugging",
        "superpowers:finishing-a-development-branch"
      ],
      "superpowers:using-git-worktrees": [
        "superpowers:brainstorming",
        "superpowers:writing-plans"
      ],
      "superpowers:brainstorming": [
        "superpowers:writing-plans",
        "superpowers:using-git-worktrees"
      ],
      "superpowers:writing-plans": [
        "superpowers:subagent-driven-development",
        "superpowers:executing-plans",
        "superpowers:using-git-worktrees"
      ],
      "superpowers:subagent-driven-development": [
        "superpowers:test-driven-development",
        "superpowers:verification-before-completion",
        "superpowers:requesting-code-review",
        "superpowers:receiving-code-review",
        "superpowers:systematic-debugging",
        "superpowers:finishing-a-development-branch",
        "superpowers:dispatching-parallel-agents"
      ],
      "superpowers:executing-plans": [
        "superpowers:test-driven-development",
        "superpowers:verification-before-completion",
        "superpowers:systematic-debugging",
        "superpowers:finishing-a-development-branch"
      ],
      "superpowers:test-driven-development": [
        "superpowers:verification-before-completion",
        "superpowers:systematic-debugging",
        "superpowers:requesting-code-review",
        "superpowers:receiving-code-review",
        "superpowers:subagent-driven-development",
        "superpowers:executing-plans"
      ],
      "superpowers:verification-before-completion": [
        "superpowers:requesting-code-review",
        "superpowers:finishing-a-development-branch",
        "superpowers:test-driven-development",
        "superpowers:subagent-driven-development",
        "superpowers:executing-plans"
      ],
      "superpowers:requesting-code-review": [
        "superpowers:receiving-code-review",
        "superpowers:finishing-a-development-branch",
        "superpowers:test-driven-development"
      ],
      "superpowers:receiving-code-review": [
        "superpowers:test-driven-development",
        "superpowers:verification-before-completion",
        "superpowers:requesting-code-review",
        "superpowers:subagent-driven-development"
      ],
      "superpowers:systematic-debugging": [
        "superpowers:test-driven-development",
        "superpowers:verification-before-completion"
      ],
      "superpowers:finishing-a-development-branch": [
        "_initial"
      ]
    },
    "wildcard_always_allowed": [
      "superpowers:using-superpowers",
      "superpowers:systematic-debugging",
      "superpowers:dispatching-parallel-agents"
    ],
    "reset_triggers": [
      "new worktree 创建 (detected via git worktree add in response)",
      "finishing-a-development-branch 完成 push/PR"
    ]
  }
}
```

**wildcard_always_allowed**：这 3 个 skill 可以从**任何** stage 进入（不受 legal-next-set 约束），因为它们是 cross-cutting 或 debugging 辅助。

### 2.4 Mini-state 数据结构

`.claude/state/skill-stage.json`：

```json
{
  "version": "1",
  "last_stage": "superpowers:writing-plans",
  "last_stage_time_utc": "2026-04-22T10:00:00Z",
  "session_id": "019db3a4-xxxx",
  "worktree_path": "/Users/maziming/.../plan-1g/topic",
  "drift_count_since_reset": 0
}
```

- Hook 每次 pass 更新 `last_stage`
- `reset_triggers` 触发时 `last_stage = "_initial"`（开新 plan）
- drift_count 超阈值（如 5）触发额外 stderr 警告

### 2.5 Drift log 格式

`.claude/state/skill-invoke-drift.jsonl`（append-only）：

```json
{
  "time_utc": "2026-04-22T08:00:00Z",
  "session_id": "019db3a4-xxxx",
  "response_sha": "sha256:abc123...",
  "gate_skill": "superpowers:verification-before-completion",
  "config_mode": "observe",
  "invoked": false,
  "exempt_rule_matched": null,
  "last_stage_before": "superpowers:writing-plans",
  "drift_kind": "gate_declared_no_invoke",
  "blocked": false
}
```

**7 种 `drift_kind`**：
- `missing_first_line`（L1 触发）
- `invalid_exempt_reason`（L1）
- `exempt_integrity_violation`（L3，如 read-only 下做了写操作）
- `gate_declared_no_invoke`（L2）
- `unknown_skill_in_gate`
- `illegal_transition`（L4）
- `parse_error`（fail-open 前记录）

## 3. 豁免条款详述

### 3.1 exempt-integrity rules（L3，Hook 1 负责）

| exempt reason | Integrity 规则 |
|---|---|
| `read-only-query` | 响应 tool_uses **不得含** Edit / Write / NotebookEdit，**不得含** Bash with pattern `git push\|git commit\|git worktree add\|gh pr\|echo.*>` |
| `behavior-neutral` | 响应不得有任何 commit / push / PR 操作 |
| `user-explicit-skip` | 响应附近需有用户明确授权信号（如用户 message 含 "跳过" / "skip" / "exempt"）→ 简化为"信任用户"，不做 content check |
| `single-step-no-semantic-change` | 响应 tool_uses 数 ≤ 1 或仅限 Bash/Read 单次 |

Violating integrity → BLOCK（exempt 应该真的是"exempt"，不能拿着免死金牌做实事）。

### 3.2 plan-doc-spec-frozen-note（brainstorming 专用）

`Skill gate: superpowers:writing-plans` + 响应写 `docs/superpowers/plans/*.md` + plan 内容含 `brainstorming skipped.*spec.*frozen` → brainstorming 的 L2 豁免（即 brainstorming 的 gate declared 但没 invoke 不算 drift）。

### 3.3 plan-start-in-worktree（using-git-worktrees 专用）

`Skill gate: superpowers:using-git-worktrees` + 响应有 `git worktree add` 调用，或 cwd 已在 `.worktrees/` 下 → L2 豁免。

## 4. 滚动激活计划（H6.0 - H6.9）

| PR | 内容 | 文件改动 | 预估 codex 轮数 |
|---|---|---|---|
| **H6.0** | 建框架（全部 `observe`）：2 hook + config + state file + settings + tests | 9 新/改文件 | **3-4**（ζ scope 可能 codex 挖 transition table edge case）|
| H6.1 | flip `verification-before-completion` → block | config.json 1 行 + 新单元测试 | 1-2 |
| H6.2 | flip `requesting-code-review` → block | 同 | 1-2 |
| H6.3 | flip `receiving-code-review` → block | 同 | 1-2 |
| H6.4 | flip `using-git-worktrees` → block（带 plan-start-in-worktree 豁免）| config + hook 豁免逻辑测试 | 2-3 |
| H6.5 | flip `brainstorming` → block（带 plan-doc-spec-frozen-note 豁免）| config + hook 豁免逻辑测试 | 2-3 |
| H6.6-H6.9 | 其他 flow skill flip | config 1 行 | 每 1-2 |

**每 PR 硬约束**（吸收 hardening-5 教训）：
- **3 轮 codex 内收敛**，超 3 轮主动 escalate 用户选 residual accept 或降级
- **H6.0 超 5 轮 → 降级到 α''**（砍掉 mini-state 部分，保留 L1+L2+L3）
- α'' 超 5 轮 → 降级到 α（仅 L2，即原 α scope，跟现有 drift-log 一致但改 block）

## 5. 测试策略

### 5.1 单元测试（两 hook 共 ~30 测试用例）

**stop-response-check.sh 升级版**：
| 场景 | 期望 |
|---|---|
| first-line 缺失 → BLOCK |
| `Skill gate: ` 后面空 → BLOCK |
| `Skill gate: exempt(invalid)` → BLOCK |
| `Skill gate: exempt(read-only-query)` + 响应仅 Read/Bash(grep/cat) → pass |
| `Skill gate: exempt(read-only-query)` + 响应有 Edit → BLOCK(integrity) |
| `Skill gate: exempt(read-only-query)` + 响应有 Bash(git push) → BLOCK |
| `Skill gate: exempt(behavior-neutral)` + 响应 docs/*.md 改动 → pass |
| `Skill gate: exempt(behavior-neutral)` + 响应有 commit → BLOCK |
| `Skill gate: exempt(user-explicit-skip)` → pass（信任）|
| `Skill gate: superpowers:X` → 传递给 Hook 2 |

**skill-invoke-check.sh**：
| 场景 | 期望 |
|---|---|
| gate=X, X ∉ config → drift-log, pass |
| gate=X, X ∈ config, invoke X → mini-state check |
| gate=X, X ∈ config, 无 invoke, mode=observe → drift-log |
| gate=X, X ∈ config, 无 invoke, mode=block → BLOCK |
| gate=X, 无 invoke, exempt_rule=plan-doc-spec-frozen-note 满足 → pass |
| gate=X, 无 invoke, exempt_rule=plan-start-in-worktree 满足 → pass |
| mini-state: last=writing-plans, current=subagent-driven → pass |
| mini-state: last=writing-plans, current=finishing-branch → BLOCK(illegal) |
| mini-state: last=writing-plans, current=systematic-debugging → pass(wildcard) |
| mini-state: last=writing-plans, current=using-superpowers → pass(wildcard) |
| reset_trigger: new worktree → last_stage reset 到 _initial |
| reset_trigger: finishing-branch pushed → last_stage reset |

### 5.2 集成测试

`scripts/acceptance/hardening_6_framework.sh`：
- hooks 存在 + executable
- config 合法 JSON + 13 skill 列全 + legal_next_set 有效
- state file 初始 content 合法
- workflow-rules.json `enforcement_mode = "block"`
- settings.json 含两 hook 节点
- 所有单元测试 passing
- 不 regression Plan 1/1b/1c/1f 既有 acceptance

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 升级 stop-response-check 到 block 后 false positive 频发 | 豁免白名单已有 4 种；H6.0 起先 block 带 `ENFORCE_BOOTSTRAP=1` 环境变量（默认 off 便于 bootstrap 自己过）；测试覆盖各 exempt 路径 |
| mini-state 文件 corrupt | JSON parse 失败 → fail-open（drift-log + WARN），不 block；H6.0 含 state-reset.sh 工具 |
| legal_next_set 表枚举不完 | 出现新合法 transition 时，config 1 行加到对应条目；起手表依据今天 Plan 1f 实际流程 + 14 skill 关系图 |
| hook 自身 bug 卡住 Claude | fail-open 策略：parse error → exit 0 drift-log |
| exempt-integrity check false positive | 严格 whitelist： read-only 只放 Read/Grep/某些 Bash；其他 tool_use 全 block |
| Hook performance | 2 hooks 串联 + JSON parse + grep；预估 <200ms；性能监测加 WARN 如 >1s |
| bootstrap chicken-egg（H6.0 自己开发时 hook 可能 block 开发）| workflow-rules.json 保持 `drift-log` 到 H6.0 merge 前；merge 后才 flip 到 block（通过 PR 自身最后一个 commit） |

## 7. 依赖 / 不依赖

**依赖（hard prereq）**：
- PR #22 skill-router-hook merged（UserPromptSubmit 提醒 hook）
- PR #19 hardening-2 merged（drift-log + stop-response-check.sh 骨架）
- `.claude/scripts/ledger-lib.sh` 可复用（jsonl append pattern）

**不依赖**：
- codex:adversarial-review（独立）
- 任何业务 Plan（Plan 1f 已 merged，Plan 1g / Plan 2 未开）
- Plan 1e aborted branch artifacts

## 8. 跨 Plan 后续 backlog

**H7 升级路径**（痛点驱动，不主动做）：

1. **完整 state machine（β）**：
   - 触发：H6 运行 2-3 业务 plan 后 drift log 仍频繁出现 `illegal_transition` 或场景 C（选错 skill）
   - Scope：legal_next_set 表扩为 full transition graph + per-stage exit conditions + 多分支豁免
   - 预估风险：hardening-5 模式，需用户批准才开

2. **Artifact check per skill（γ）**：
   - 触发：H6 运行后发现"声明 + invoke 了但没按 skill 做"（场景 D' 变种）
   - Scope：每 skill 独立 PR 加 artifact check（brainstorming → spec.md，writing-plans → plan.md 等）
   - 预估：单 skill 小 PR 可 3 轮收敛

3. **UserPromptSubmit 增强**（expected skill 推断）：
   - 触发：skill-router 静态提示不够用，用户 prompt 含复杂上下文
   - Scope：识别 prompt 里的触发词 → 在下一响应检查 Claude first-line 是否匹配期望
   - 风险：NLP 难度中

4. **override 频率监控**：
   - attest-override-log.jsonl 每月 rollup
   - 检测 override 率超阈值（>5 次/月）→ 警告

## 9. 执行切换提示

Spec approved → 进 writing-plans，起草 H6.0 plan（~5-7 task：stop-check 升级 / invoke-check 新增 / config / state / workflow-rules flip / settings / tests / acceptance）。

**关键：H6.0 scope 超 5 轮 codex 不收敛 → 降级到 α''**（砍 mini-state 部分），这条降级路径已固化在本 spec 附录 A。

---

## 附录 A：Design Decision Log（2026-04-22 brainstorming Q&A 记录）

### A.1 Plan 1f audit 场景分布（实测数据）

| skill 漏点 | 漏点类型 | 次数 |
|---|---|---|
| verification-before-completion | D（声明了没 invoke） | 1 |
| requesting-code-review | A（完全没声明） | ~3（push 前 / PR 前各节点） |
| receiving-code-review | A（5 次 codex feedback 只 1 次声明 receiving-code-review）+ D（剩 1 次声明了没 invoke） | 4A + 1D |

**结论**：主漏点是**场景 A**（silent skip 不声明），不是 D。这修正了我最初 α scope 假设。

### A.2 4 种场景对照（brainstorming 中与用户梳理）

| 场景 | 描述 | Plan 1f 出现 | 能否 hook detect |
|---|---|---|---|
| A | 忘贴 first-line Skill gate | ~5 次 | ✅ hook 可查缺失 |
| B | 贴了但选错 skill（故意作弊）| 0 次 | ❌ 需 LLM 判意图 |
| C | 贴了对的 skill 但流程乱（跳阶段） | 偶见 | ⚠️ 部分（mini-state）|
| D | 贴了 + 没 Skill tool invoke | ~2 次 | ✅ hook 可扫 invoke |

### A.3 4 种 scope 方案对比

| | 覆盖范围 | 技术复杂度 | hardening-5 相似度 | 推荐度 |
|---|---|---|---|---|
| α（原 spec） | 仅 D | 低 | 低 | ❌ 不覆盖主漏点 A |
| α''（α + L1 block + L3 exempt integrity） | A + D + 部分 exempt 滥用 | 中低 | 低 | ⚠️ 不覆盖流程必然性 |
| **ζ（α'' + L4 mini-state）** ✅ | A + D + exempt + 部分 C | 中 | 中 | **推荐**（最终选择）|
| β（ζ + 完整 state machine + artifact check）| A + B（部分）+ C + D | 高 | 高（~hardening-5）| ❌ 预估 11 轮不收敛 |

### A.4 为什么最终选 ζ（不选 β）

**hardening-5 数据**：
- spec 尝试 1（full G3）：11 轮 codex 27 findings 不收敛
- spec 尝试 2（5.1 拆解）：6 轮 codex 13 findings 仍不收敛
- 用户选 option E 中止

**沉没成本分析**：
- 直接 ζ 起步 → 3-5 轮收敛 → ship（~3h）
- β 起步若 11 轮不收敛 → 降 ζ（废弃 β 80% 代码重写）→ 3-5 轮 → ship（~12h）

**为何不是 α''（更保守）**：
- 用户提出"流程必然性"关切有价值——仅声明 + invoke 不阻止 Claude 跳阶段
- mini-state 只做"1-step lookahead"（不是完整 state machine），scope 比 β 小得多
- ζ 是 α'' 的**自然延伸**，成本增量小

### A.5 β / γ 什么时候考虑

**触发升级 β 的数据信号**（H7）：
- H6 ship 后 2-3 个业务 plan 观察期
- drift log 出现 illegal_transition 频率 > 每 plan 3 次
- 或 user audit 发现 Claude 频繁"声明对 skill 但跳阶段完成任务"

**触发 γ（artifact check）的数据信号**：
- 出现"声明 + invoke 了但没产 artifact"的实证（场景 D' 变种）
- 某个 skill 上述 pattern 频发 → 单 skill 小 PR 加 artifact check

### A.6 并行 3 对话 α''/ζ/β 方案评估（用户一度提议）

**结论：技术不可行**
- 3 worktree 共享同一 `.claude/` 目录（Claude 读主 repo 的 .claude/），hook 互相 clobber
- 3 方案嵌套（α'' ⊂ ζ ⊂ β），并行 = 做 3 次重复工作
- 代替方案：**单线 ζ 起步 + 自带降级路径**（H6.0 超 5 轮降 α''，超 8 轮降 α）

---

## 附录 B：Spec 自查清单（skill §Spec Self-Review 4 项）

1. **Placeholder scan**：无 TBD / TODO；state file schema 字段 `session_id` / `response_sha` 获取方式已说明
2. **内部一致性**：13 skill 数在 §2.3 config block、§4 rollout、§1.1 一致；legal_next_set 表覆盖所有 13 skill（12 显式 + _initial）
3. **Scope check**：单 spec，一个 H6.0 实施 PR + 9 个 flip PR；scope 是 H6.0 框架本身
4. **Ambiguity check**：
   - exempt-integrity 规则用正则严格白名单
   - legal_next_set 表显式枚举
   - H6.0 bootstrap 自指问题通过 workflow-rules flip 延迟到 PR 最后一个 commit 处理
