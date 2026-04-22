# Hardening-6 Skill Pipeline Enforcement Framework 设计 Spec（ζ scope, v3）

**Status**: drafted 2026-04-22；v3（post codex R1 3 findings + user 提议 codex:adversarial-review 纳入 first-class）；scope 仍 ζ 不动。

**v3 relative v2 变化**：
1. 新增 **L5 codex:adversarial-review 强制**（不改既有 codex hook，在新 hook 里识别 `codex-attest.sh` 调用 / ledger entry）
2. 修 Codex R1 HIGH #1：unknown skill gate 在 block mode 下 **fail-closed**
3. 修 Codex R1 HIGH #2：exempt-integrity 从黑名单 → **allowlist**
4. 修 Codex R1 MEDIUM #3：mini-state 按 **worktree hash + session_id** 隔离

**关键：不改既有 codex hook**（`codex-attest.sh` / `guard-attest-ledger.sh` / `attest-override.sh`）。只在新 hook 里识别 codex 合规信号。

---

## 1. 目标

### 1.1 Goal（ζ scope, 5 层强制）

| 层 | 覆盖场景 | 机制 | v3 补充 |
|---|---|---|---|
| L1 声明强制 | **A**：Claude 忘贴 first-line | 升级 `stop-response-check.sh` drift-log → hard block | — |
| L2 invoke 强制 | **D**：声明了没 invoke | 新 `skill-invoke-check.sh` 扫 tool_uses Skill 调用 | — |
| L3 exempt 合理性 | exempt 滥用 | Hook 1 exempt-integrity check | **v3 改 allowlist** |
| L4 mini-state | 部分 **C**：流程必然性 | `.claude/state/skill-stage/<wt-hash>-<session>.json` 记 last_stage + legal-next-set | **v3 按 worktree/session 隔离** |
| **L5 codex 强制** | **spec/plan 后没跑 codex 对抗性 review 就下一步** | 新 hook 识别 `codex-attest.sh` Bash 调用 / `attest-ledger.json` entry | **v3 新增** |

**未覆盖**：
- 场景 B（故意选错 skill）→ 需 LLM 意图判断
- 完整 state machine β / artifact check γ → H7 backlog

### 1.2 Non-Goal

- 完整 state machine（H7 β）
- per-skill artifact check（H7 γ）
- UserPromptSubmit 增强 expected-skill 推断
- auto-inject skill content
- **改既有 codex hook**（`codex-attest.sh` / `guard-attest-ledger.sh` / `attest-override.sh`）：坚决不动；只在新 hook 里复用其信号（Bash 调用 + ledger 文件）
- writing-skills / frontend-design（本项目不用）

## 2. 架构

### 2.1 新增 / 修改文件

| 文件 | 动作 | 作用 | 预估行数 |
|---|---|---|---|
| `.claude/hooks/stop-response-check.sh` | **升级** | drift-log → hard-block + exempt-integrity allowlist | +70 |
| `.claude/hooks/skill-invoke-check.sh` | 新增 | L2 invoke + L4 mini-state（按 worktree/session）+ L5 codex 识别 + unknown gate fail-closed | ~250 |
| `.claude/config/skill-invoke-enforced.json` | 新增 | 14 skill config + legal_next_set 含 codex + wildcard + migration flag | ~120 |
| `.claude/state/skill-stage/` | 新增目录 | 按 `<wt-hash>-<session>` 存 stage 文件 | — |
| `.claude/state/skill-invoke-drift.jsonl` | 新增 | append-only drift log（空初始化）| 0 |
| `.claude/workflow-rules.json` | 修改 | `skill_gate_policy.enforcement_mode`: `drift-log` → `block`（PR 最后一个 commit） | 1 行 |
| `.claude/settings.json` | 修改 | 加 Stop.skill-invoke-check hook 节点 | +4 行 |
| `tests/hooks/test_stop_response_check_block.py` | 新增 | L1/L3 block + allowlist 单元测试 | ~200 |
| `tests/hooks/test_skill_invoke_check.py` | 新增 | L2/L4/L5 + unknown gate 单元测试 | ~350 |
| `scripts/acceptance/hardening_6_framework.sh` | 新增 | 聚合验收 | ~100 |

### 2.2 Hook 逻辑流（Stop trigger，两 hook 串联）

```
Claude 响应完成 → Stop event
    │
    ▼
Hook 1: stop-response-check.sh（升级版）
    │
    ├─ first-line 解析
    │   ├─ 缺失 → BLOCK
    │   ├─ 格式 invalid → BLOCK
    │   ├─ exempt(<reason>) 且 reason ∉ 白名单 → BLOCK
    │   ├─ exempt(<reason>) 且 reason ∈ 白名单
    │   │   └─ L3 exempt-integrity check（allowlist 版 — 权威策略见 §3.3）
    │   │       ├─ reason = "read-only-query"
    │   │       │   └─ 响应 tool_uses 必须**全部**在严格白名单内：
    │   │       │       {Read, Grep, Glob} ∪ {Bash 严格完整命令正则：
    │   │       │         `pwd|true|false|echo "<literal>"|ls|cat|head|tail|wc`（单参数）}
    │   │       │       **R2 F2 hardening**：`git`/`find`/`sed`/`tee`/管道/重定向/复合
    │   │       │       一律拒绝（否则 find -delete / git log | tee 等 bypass）
    │   │       │       任一 tool_use 超白名单 → BLOCK
    │   │       ├─ reason = "behavior-neutral"
    │   │       │   └─ 响应 Write/Edit 只允许 `docs/**/*.md`（repo-containment 检查后）；
    │   │       │       `.claude/state/**` 全部拒（**R11 F1 CRITICAL + R17 F1 CRITICAL
    │   │       │       hardening**：attest-ledger.json / override-log.jsonl forgery 路径）；
    │   │       │       Bash 同 read-only 严格白名单 + 额外禁 commit/push/tag/PR → 否则 BLOCK
    │   │       ├─ reason = "user-explicit-skip"
    │   │       │   └─ **R31 F1 hardening**：MUST 验证当前 turn user message 含授权短语
    │   │       │       (skip skill / 跳过 skill / 不用 skill / 免 skill / /no-skill 等)
    │   │       │       缺失 → BLOCK（否则 Claude 可单方面声明 exempt 绕过全部 L2/L4/L5）
    │   │       ├─ reason = "single-step-no-semantic-change" → 响应 tool_uses ≤ 2
    │   │       │   且不含 push/merge/PR → 否则 BLOCK
    │   │       └─ 未知 reason（已在上面白名单检查拒）→ 不会到此
    │   └─ `Skill gate: <skill-name>` → 不 block，传给 Hook 2
    │
    ▼
Hook 2: skill-invoke-check.sh（v3）
    │
    ├─ skill-name ∈ config.enforce？
    │   │
    │   ├─ **否**（unknown gate）
    │   │   ├─ enforcement_mode = "drift-log"（observe 迁移期）→ drift-log + exit 0
    │   │   ├─ 环境变量 ALLOW_UNKNOWN_GATE=1 → pass + drift-log WARN
    │   │   └─ 其他（含 block mode）→ **BLOCK**（R1 F1 fix：fail-closed）
    │   │
    │   └─ 是（已知 skill）
    │       │
    │       ├─ 特殊：skill-name == "codex:adversarial-review"（L5 路径，v5 精化）
    │       │   ├─ 计算当前 target key（同 §3.4）
    │       │   │
    │       │   ├─ 豁免检查 exempt_rule = "codex-evidence-bound-to-target"
    │       │   │   ├─ **路径 A（approve ledger, revision-bound）**：attest-ledger.json
    │       │   │   │     `.entries[target]` 存在 + attest_time_utc 非空 + verdict_digest
    │       │   │   │     非空 + time > SESSION_START + file target 需 blob_sha == 当前
    │       │   │   │     `git hash-object` → pass
    │       │   │   ├─ **路径 B（override ledger entry, revision-bound）** — **R17 F1
    │       │   │   │     CRITICAL hardening**：MUST 查 attest-ledger.json `.entries[target]`
    │       │   │   │     entry 且 `override:true` 且 audit_log_line 指向真实 override-log
    │       │   │   │     行（cross-verify）；raw override-log.jsonl 行单独不足以 pass
    │       │   │   │     （否则 behavior-neutral Write 到 override-log 就伪造 L5 证据）
    │       │   │   └─ 否则 → mode 判断 drift / block
    │       │   │
    │       │   │   （v5 删除 path C：stdout-based 证据无法 bind target，参 §3.4 说明）
    │       │   │
    │       │   └─ L5 pass 后**也进 L4 mini-state 更新**（v4 R2 F3 fix）
    │       │       └─ L4 legal_next_set 检查 + atomic update last_stage 到 "codex:adversarial-review"
    │       │
    │       └─ 普通 skill（非 codex）
    │           ├─ 扫响应 tool_uses 找 Skill invoke 名==skill-name
    │           │   ├─ 匹配 → 进 L4 mini-state check
    │           │   └─ 不匹配 → 查 exempt_rule
    │           │       ├─ "plan-doc-spec-frozen-note" 且 plan doc 含注记 → L4
    │           │       ├─ "plan-start-in-worktree" 且响应有 `git worktree add` 或
    │           │       │   cwd ∈ `.worktrees/` → L4
    │           │       └─ 否则 mode 判断 drift / block
    │           │
    │           └─ L4 mini-state check（隔离版）
    │               ├─ state_file = f".claude/state/skill-stage/{wt_hash8}-{session_id_hash8}.json"
    │               │   wt_hash8 = sha256($PWD)[0:8]
    │               │   **R26 F1 + R27 F1 hardening**：
    │               │   session_id_hash8 = sha256(FULL $CLAUDE_SESSION_ID)[0:8]（非 ULID 前缀）
    │               │   CLAUDE_SESSION_ID 缺失 + block mode → fail-closed BLOCK
    │               │   （pid+time fallback 会每次重置 last_stage=_initial，等效绕过 L4）
    │               │   observe mode → pid+time fallback 仅用于 drift 遥测
    │               ├─ 读 last_stage（文件不存在或 parse 失败 → "_initial"）
    │               ├─ 查 legal_next_set(last_stage)
    │               ├─ skill-name ∈ wildcard_always_allowed → pass + 更新 last_stage
    │               ├─ skill-name ∈ legal_next_set → pass + 更新 last_stage（原子 write：tmp + rename）
    │               └─ 非法 transition
    │                   ├─ mode = observe → drift-log "illegal_transition"
    │                   └─ mode = block → BLOCK + stderr "expected next: {set}"
    │
    └─ exit 0 / exit 2
```

### 2.3 Config schema（v3）

`.claude/config/skill-invoke-enforced.json`：

```json
{
  "version": "1",
  "description": "Hardening-6 v3: 5-layer enforcement; codex:adversarial-review first-class.",
  "unknown_gate_policy": {
    "drift-log_mode": "drift-log_then_pass",
    "block_mode": "fail_closed_unless_ALLOW_UNKNOWN_GATE=1"
  },
  "enforce": {
    "codex:adversarial-review": {
      "mode": "observe",
      "flip_phase": "H6.10",
      "exempt_rule": "codex-attest-script-run-or-ledger",
      "note": "first-class v3: Skill tool disable-model-invocation; 改走 codex-attest.sh Bash 调用 / attest-ledger entry 检查"
    },
    "superpowers:brainstorming": {
      "mode": "observe", "flip_phase": "H6.5",
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
    "superpowers:using-superpowers": { "mode": "observe", "flip_phase": "永久", "note": "meta" },
    "superpowers:executing-plans": { "mode": "observe", "flip_phase": "永久" },
    "superpowers:systematic-debugging": { "mode": "observe", "flip_phase": "永久" },
    "superpowers:dispatching-parallel-agents": { "mode": "observe", "flip_phase": "永久" }
  },
  "mini_state": {
    "enabled": true,
    "state_dir": ".claude/state/skill-stage/",
    "file_template": "{wt_hash8}-{session_id8}.json",
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
        "codex:adversarial-review",
        "superpowers:using-git-worktrees"
      ],
      "codex:adversarial-review": [
        "superpowers:writing-plans",
        "superpowers:subagent-driven-development",
        "superpowers:executing-plans",
        "superpowers:receiving-code-review",
        "superpowers:finishing-a-development-branch",
        "superpowers:brainstorming"
      ],
      "superpowers:writing-plans": [
        "codex:adversarial-review",
        "superpowers:using-git-worktrees"
      ],
      "superpowers:subagent-driven-development": [
        "superpowers:test-driven-development",
        "superpowers:verification-before-completion",
        "superpowers:requesting-code-review",
        "superpowers:receiving-code-review",
        "superpowers:systematic-debugging",
        "superpowers:finishing-a-development-branch",
        "superpowers:dispatching-parallel-agents",
        "codex:adversarial-review"
      ],
      "superpowers:executing-plans": [
        "superpowers:test-driven-development",
        "superpowers:verification-before-completion",
        "superpowers:systematic-debugging",
        "superpowers:finishing-a-development-branch",
        "codex:adversarial-review"
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
        "codex:adversarial-review",
        "superpowers:test-driven-development"
      ],
      "superpowers:receiving-code-review": [
        "superpowers:test-driven-development",
        "superpowers:verification-before-completion",
        "superpowers:requesting-code-review",
        "superpowers:subagent-driven-development",
        "superpowers:executing-plans",
        "superpowers:systematic-debugging",
        "codex:adversarial-review"
      ],
      "superpowers:systematic-debugging": [
        "superpowers:test-driven-development",
        "superpowers:verification-before-completion"
      ],
      "superpowers:finishing-a-development-branch": [
        "codex:adversarial-review",
        "_initial"
      ]
    },
    "wildcard_always_allowed": [
      "superpowers:using-superpowers",
      "superpowers:systematic-debugging",
      "superpowers:dispatching-parallel-agents"
    ],
    "reset_triggers": [
      "response 含 `git worktree add` → 新 plan 起手，last_stage ← _initial",
      "response 含 push + PR 且 ledger 记录 approve → last_stage ← _initial",
      "session 切换（session_id 变）→ 新 state file 自动初始化"
    ]
  }
}
```

**关键流程（含 codex）**：

```
_initial → brainstorming (spec 起草)
         → codex:adversarial-review (spec review gate) ← L5 强制
         → writing-plans (plan 起草)
         → codex:adversarial-review (plan review gate) ← L5 强制
         → subagent-driven-development (执行)
           → TDD / verify / review loops...
         → requesting-code-review / finishing-a-development-branch
         → codex:adversarial-review (PR review gate) ← L5 强制
         → _initial (合入，周期重置)
```

### 2.4 Mini-state 数据结构（v3 隔离版）

**目录**：`.claude/state/skill-stage/`（新建，`.gitignore` 已覆盖 `.claude/state/`）

**文件命名**：`{wt_hash8}-{session_id_hash8}.json`
- `wt_hash8` = `sha256($PWD)` 前 8 字符
- `session_id_hash8` = `sha256($CLAUDE_SESSION_ID)` 前 8 字符（**R26 F1 hardening** — ULID
  前 10 位是时间戳，前 8 字符前缀易在同时间桶冲突）
- **R27 F1 hardening**：block mode 下 `CLAUDE_SESSION_ID` 缺失 → fail-closed BLOCK
  （PPID+time fallback 每次生成新 state file → last_stage 永远 _initial → L4 等效绕过）；
  observe mode 下允许 PPID+time fallback 仅用于 drift 遥测连续性

**每文件 schema**：
```json
{
  "version": "1",
  "last_stage": "superpowers:writing-plans",
  "last_stage_time_utc": "2026-04-22T10:00:00Z",
  "worktree_path": "/Users/maziming/.../plan-1g/topic",
  "session_id": "019db3a4-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "drift_count": 0,
  "transition_history": [
    {"stage": "superpowers:using-git-worktrees", "time": "2026-04-22T09:00:00Z"},
    {"stage": "superpowers:brainstorming", "time": "2026-04-22T09:30:00Z"},
    {"stage": "codex:adversarial-review", "time": "2026-04-22T09:45:00Z"},
    {"stage": "superpowers:writing-plans", "time": "2026-04-22T10:00:00Z"}
  ]
}
```

**原子写**：`mktemp + rename`（不是直接 write），防多 hook 并发覆盖。

**fail-open**：JSON parse 失败 → 视作 `_initial`，drift-log 但不 block。

**清理策略**（不在 H6.0 scope，留 backlog）：超 30 天无更新的 state file 可清理；H6.0 只新建不清理。

### 2.5 Drift log（v3）

`.claude/state/skill-invoke-drift.jsonl`，新增 1 种 kind（总 8 种）：

- `missing_first_line`（L1）
- `invalid_exempt_reason`（L1）
- `exempt_integrity_violation`（L3）
- `gate_declared_no_invoke`（L2）
- `unknown_skill_in_gate`（L2，v3 fail-closed 时）
- `illegal_transition`（L4）
- **`codex_gate_no_evidence`**（L5 v3 新增）：`Skill gate: codex:adversarial-review` 但响应无 codex-attest.sh 调用 + ledger 无新 entry
- `parse_error`（fail-open）

## 3. 豁免规则详述（v3）

### 3.1 exempt-integrity rules（L3，allowlist 版）

| exempt reason | 规则 |
|---|---|
| `read-only-query` | **v4 严格白名单**：tool_uses 必须全部是 **Read / Grep / Glob** 工具；**Bash 基本禁用**，仅允许 argv-parse 后匹配以下**严格完整命令模式**（正则必须完整匹配整个 command 字符串，**禁止管道/重定向/复合命令/任何 flag 不在白名单内**）：`^(pwd\|true\|false)$` 或 `^echo [^|<>;&$()\`'\"]*$`（echo literal 无变量/重定向） 或 `^(ls\|cat\|head\|tail\|wc)\s+[^|<>;&$(){}]+$`（单文件参数，无管道/重定向）。**明确禁**：`find` / `git diff` / `tee` / `sed` / 管道 `\|` / 重定向 `> < >>` / 复合 `;` `&&` `\|\|`。复杂查询应改用 Read/Grep/Glob tool 或选其他 exempt reason。v4 fix R2 F2：find -delete / git diff --output / git log \| tee 等 bypass 被关死 |
| `behavior-neutral` | 禁 commit / push / tag / PR create-merge；允许 Edit/Write 到 `docs/**/*.md`（排除 `docs/superpowers/**`，brainstorming/writing-plans 产出区；repo-containment 检查后）；**R11 F1 CRITICAL + R17 F1 CRITICAL hardening**：`.claude/state/**` 全部拒（含 attest-ledger.json 和 override-log.jsonl — L5 evidence forgery 路径）；其他写操作 → BLOCK |
| `user-explicit-skip` | **R31 F1 hardening**：MUST 验证当前 turn user message 含授权短语：`skip skill` / `no skill` / `without skill` / `exempt .* skill` / `bypass skill` / `跳过 skill` / `不用 skill` / `免 skill` / `/no-skill`（case-insensitive）。缺失 → BLOCK（previously trust-without-evidence was L1 bypass — any response could self-declare exempt 绕过 L2/L4/L5 全部）。授权存在 → pass + drift-log 记录 |
| `single-step-no-semantic-change` | tool_uses ≤ 2，且不含 push/merge/PR → 否则 BLOCK |

**Block 时给用户清晰 stderr 提示**："read-only-query exempt 不允许 `<具体命令>`；如真是 read-only 用 Read 或 grep 级命令，否则选其他 exempt 或真正声明 skill"。

### 3.2 plan-doc-spec-frozen-note（brainstorming 专用，未变）

`Skill gate: superpowers:writing-plans` + 响应写 `docs/superpowers/plans/*.md` + plan 内容含 `brainstorming skipped.*spec.*frozen` → brainstorming L2 豁免。

### 3.3 plan-start-in-worktree（using-git-worktrees 专用，未变）

`Skill gate: superpowers:using-git-worktrees` + 响应有 `git worktree add` 或 cwd ∈ `.worktrees/` → L2 豁免。

### 3.4 codex-evidence-bound-to-target（codex:adversarial-review 专用，v4）

v4 fix R2 F1：**必须证据绑定到当前 target**，不接受跨文件/跨分支的 stale ledger entry。

**Target 计算**：
- last_stage ∈ {brainstorming, writing-plans}：target = `file:<最近修改的 spec 或 plan 路径>`
- last_stage ∈ {subagent-driven-development, requesting-code-review, finishing-a-development-branch}：target = `branch:<current_branch>@<HEAD_sha>`
- last_stage == `_initial`：target = 空，**不 block**（允许 session 起点 codex 声明）
- **v6 fix R4 F2**：其他情况（state 异常 / parse fail 后 fallback / legal 但不在上面枚举的 stage）→ target = 空 → **block mode 下 BLOCK**（failing-closed，防止 state 损坏导致 L5 降级到 observe）
  豁免：需配置 `ALLOW_EMPTY_CODEX_TARGET=1` 环境变量明确允许

**满足任一路径即 pass**（v7 加 revision binding, R5 F1 fix）：

- **A（approve ledger, revision-bound）**：`.claude/state/attest-ledger.json` 查 key == target 的 entry：
  - 必有字段 `attest_time_utc`（非 `time_utc`）
  - `verdict_digest` 非空（= approve 了）
  - `attest_time_utc > SESSION_START_UTC`
  - **v7 R5 F1 fix：revision bind**
    - **file target**：ledger entry `blob_sha` 必须 == 当前 `git hash-object <file>`（如 file 在本响应被 edit 后 blob 会变，stale ledger 就失效）
    - **branch target**：ledger key 内含 `@<sha>`，自然 bind 到那个 sha；若 branch HEAD 后续有新 commit → target 变成新 key，path A 查不到 → BLOCK
- **B（override ledger entry, revision-bound）** — **R17 F1 CRITICAL hardening**：
  MUST 查 `attest-ledger.json` `.entries[target]` entry 且 `override:true` 且
  `audit_log_line` 指向真实 `attest-override-log.jsonl` 行（cross-verify 该行
  target/time_utc/kind 与 ledger entry 一致）；**raw override-log.jsonl 行单独不足以
  pass**（否则 behavior-neutral Write 伪造 override-log 行即可伪造 L5 证据）。
  `time_utc > SESSION_START_UTC` + file kind 要求 `blob_or_head_sha` 匹配当前
  `git hash-object`（v7 加）

**v6 关键说明（R4 F1 fix：死锁消除）**：

**时序事实**：Claude Code Stop hook 在响应**完成后**触发。如果响应里含 Bash 调用 `codex-attest.sh`，Bash 已同步跑完 + ledger 已 update，Stop hook 能立即读到新 entry。所以**首次声明 + 同响应 Bash 调用 + Stop hook path A 查 ledger** 的流程是可行的，不会死锁。

**Claude 的正确模式**（两种都可）：
- **模式 i（同响应 announce + run）**：同一响应内首行 `Skill gate: codex:adversarial-review` + Bash 跑 `codex-attest.sh`。Bash 跑完 ledger update → Stop hook path A pass
- **模式 ii（先 run 再 announce）**：上一响应跑 `codex-attest.sh`（ledger 已 update）；下一响应首行 `Skill gate: codex:adversarial-review` + 正文引用 ledger → path A 仍 pass（entry 仍在 session 内）

**禁止模式（v6 明确）**：首行 `Skill gate: codex:adversarial-review` + **响应内不调 codex-attest.sh** + **ledger 无该 session 内的 target-bound entry** → BLOCK。要修的话：补调 Bash 或转去跑。

**path C 为什么删**（R3 F1 重申）：原 path C "stdout 含 Verdict:approve" 不验证 argv target，Claude 可以 attest 文件 X 但声明 gate 在 file Y → stdout 显示 approve 但 target 不匹配 → bypass。
正确做法留 path A/B：ledger entry **自然 bind target**（ledger key 就是 file:X 或 branch:Y），stdout 不必要。

**`SESSION_START_UTC` 获取（v9，R6 + R7 fix）**：
- 首选：`$CLAUDE_SESSION_ID` 是 ULID，前 10 字符时间戳解码
- 退化：env var `$CLAUDE_SESSION_START_UTC`（hook setup 时设置）
- **两者都不可用时**（v9 严格化）：
  - **L5 evidence 判定 = FAIL**（无论 block / observe）——因为无法验证 `attest_time_utc > SESSION_START_UTC`，任何 ledger entry 在不知 session start 的前提下都视作"stale/不可信"，**不得** pass L5
  - drift-log 记 `session_start_unknown`（独立 kind）
  - 行为差异仅在"响应是否被 block"：
    - **block mode** → 响应 BLOCK（fail-closed 响应层）
    - **observe mode** → 响应 pass（drift-log only），但 **telemetry 仍将该响应计为 L5 non-compliant**（用于观察期决定何时 flip block）
  - stderr 提示用户 export `CLAUDE_SESSION_START_UTC` 或确保 `CLAUDE_SESSION_ID` 可读
- **完全不允许 12-hour rolling fallback**（R6 F1）
- **关键区分**（v9 R7 F1）：mode=observe 让响应**不被 block**（以便观察期收集数据）≠ L5 evidence 判定合规。两者分离：evidence 判 FAIL 时总是 drift-log，只 mode=block 时才 exit 2

## 4. 滚动激活计划（H6.0 - H6.10）

| PR | 内容 | 文件改动 | 预估 codex 轮数 |
|---|---|---|---|
| **H6.0** | 建框架（全部 observe）：2 hook + config + state dir + settings + tests | 11 新/改文件 | **3-5**（ζ 含 codex 增加复杂度）|
| H6.1 | flip `verification-before-completion` → block | config.json 1 行 + 新单元测试 | 1-2 |
| H6.2 | flip `requesting-code-review` → block | 同 | 1-2 |
| H6.3 | flip `receiving-code-review` → block | 同 | 1-2 |
| H6.4 | flip `using-git-worktrees` → block | config + 豁免测试 | 2-3 |
| H6.5 | flip `brainstorming` → block（spec-frozen 豁免）| config + 豁免测试 | 2-3 |
| H6.6-H6.9 | 其他 flow skill flip | config 1 行 | 每 1-2 |
| **H6.10** | flip `codex:adversarial-review` → block（L5 硬强制）| config 1 行 + 诈骗测试（无 codex 调用 → block） | 2-3 |

**每 PR 硬约束**：
- 3 轮 codex 内收敛；超 3 轮 escalate
- H6.0 超 5 轮 → **降级到 α''**（砍 mini-state + L5）
- α'' 超 5 轮 → 降级到 α（仅 L2）

## 5. 测试策略（v3 扩展）

### 5.1 单元测试新增用例

**stop-response-check.sh 升级（L3 v4 严格 allowlist，R2 F2 fix 验证）**：
- `read-only-query` + Read / Grep / Glob → pass
- `read-only-query` + Bash `pwd` / `true` / `echo "hi"` → pass
- `read-only-query` + Bash `ls .` / `cat file.txt` / `head -20 log` → pass
- `read-only-query` + Bash `python -c ...` → **BLOCK**（python 不在白名单）
- `read-only-query` + Bash `git status` → **BLOCK**（v4 严格：git 也不在白名单；用 Bash with git 请选别的 exempt 或声明 skill）
- `read-only-query` + Bash `find . -delete` → BLOCK（find 禁）
- `read-only-query` + Bash `git diff --output=x.patch` → BLOCK（git 禁）
- `read-only-query` + Bash `git log \| tee out` → BLOCK（管道禁 + tee 禁）
- `read-only-query` + Bash `rm x.txt` / `mv a b` / `sed -i ...` → BLOCK
- `read-only-query` + Bash `cat file.txt > other` → BLOCK（重定向禁）
- `read-only-query` + Bash `echo hi; rm x` → BLOCK（复合禁）
- `behavior-neutral` + Edit docs/*.md → pass
- `behavior-neutral` + commit → BLOCK

**skill-invoke-check.sh（v4 L5 精化 + R1/R2 fix）**：
- `Skill gate: superpowers:invalid-typo` + mode=drift-log → drift-log, pass
- `Skill gate: superpowers:invalid-typo` + mode=block → BLOCK（R1 F1 fix 验证）
- `Skill gate: superpowers:invalid-typo` + mode=block + ALLOW_UNKNOWN_GATE=1 → pass + drift-log WARN
- **L5 codex evidence 测试（v7，仅 ledger/override-log 路径，R5 F2 fix 对齐 spec）**：
  - ledger 有无关 target 的 entry + 无本 target entry → BLOCK
  - ledger 有本 target 的 entry 但 `attest_time_utc < SESSION_START` → BLOCK（stale session）
  - ledger 有本 target（file kind） entry, `attest_time_utc > SESSION_START`, 但 `blob_sha != git hash-object <file>` → BLOCK（**v7 R5 F1 revision-bound 测试**）
  - ledger 有本 target（file kind） entry, `blob_sha == git hash-object <file>` + `verdict_digest` 非空 + `attest_time_utc > SESSION_START` → pass
  - ledger 有本 target（branch kind） entry（key 已 bind HEAD sha）+ 所有条件 → pass
  - branch HEAD 向前 commit 后 target key 变，path A 查不到新 key → BLOCK
  - attest-override-log 最近行 target 匹配 + file blob 匹配（v7）→ pass
  - attest-override-log 最近行 file kind 但 blob_or_head_sha mismatch → BLOCK（v7 加）
  - （**v7 不再测试 stdout-based path C**，它 v5 已删）
- **L5 mini-state update（v4 R2 F3 fix）**：
  - 起点 last_stage=brainstorming；codex pass；last_stage 更新为 codex → pass
  - 紧接 writing-plans（legal from codex）→ pass（不再卡 brainstorming）
- mini-state isolation（R1 F3）：session A 和 session B 独立 state file
- mini-state 原子 write 测试（kill -9 mid-write → 原文件不损坏）

### 5.2 集成测试

`scripts/acceptance/hardening_6_framework.sh`：
- 2 hooks executable + syntax check
- config JSON schema valid + 14 skill（含 codex）列全
- legal_next_set 每个 key 的 values 都是已定义 skill
- state_dir 可写
- workflow-rules `enforcement_mode` 值合法
- settings.json Stop 节点有 skill-invoke-check
- 单元测试全绿
- Plan 1/1b/1c/1f regression（间接）

## 6. 风险与缓解（v3）

| 风险 | 缓解 |
|---|---|
| allowlist 覆盖不全，频繁误拦 | H6.0 先 observe（drift-log 不 block），收集真实 false-positive 数据；H6.N flip 前按数据调整 allowlist |
| mini-state 文件 corrupt | JSON parse 失败 fail-open drift-log；atomic mktemp+rename |
| state 目录无限增长 | 登记 cleanup backlog；H6.0 只新建 |
| codex-attest.sh 签名变动 / 路径重命名 | 检测点固化：exempt_rule 文档写明检查字符串；H6.N 加 breaking-change detection |
| Session id 不可用时多 plan state 冲突 | fallback session_id = "noSessID"，全局 fallback state file；drift-log 警告 |
| bootstrap 自指（H6.0 开发时 hook 可能 block 开发）| workflow-rules.json enforcement_mode 保 drift-log 到 H6.0 PR 最后一个 commit；merge 后才 block |
| H6.10 flip codex 到 block 后，push 仪式被额外 gate 层反复问 | 确认无新 block：既有 attest-ledger + 新 hook 配合，attest-override.sh 继续走 bypass 路径 |
| legal_next_set 枚举不完 | H6.0 提供 config 1 行补全机制；drift-log illegal_transition 积累数据指导加条目 |

## 7. 依赖 / 不依赖

**依赖**：
- PR #22 skill-router-hook merged
- PR #19 hardening-2 merged（drift-log infra + ledger-lib.sh）
- `.claude/scripts/codex-attest.sh` 存在（本 hook 读其调用信号，不改脚本）

**不依赖**：
- 任何业务 Plan
- Plan 1e / Plan 1g（后续业务）

## 8. 跨 Plan 后续 backlog

**H7 升级路径**（痛点驱动）：

1. 完整 state machine（β）
2. Artifact check per skill（γ）
3. UserPromptSubmit expected-skill 推断
4. State file cleanup（30 天）
5. Override 频率监控

## 9. 执行切换提示

Spec approved → writing-plans H6.0 task 分解（~9-11 task：config / state / stop-check 升级 / invoke-check 新增 / settings 挂钩 / acceptance / 2 tests / workflow-rules flip / bootstrap 测试）。

---

## 附录 A：Design Decision Log

### A.1 Plan 1f audit 场景分布

| skill 漏点 | 漏点类型 | 次数 |
|---|---|---|
| verification-before-completion | D | 1 |
| requesting-code-review | A | ~3 |
| receiving-code-review | 4A + 1D | 5 |

### A.2 4 种场景对照

| 场景 | Plan 1f 实测 | 能否 hook detect |
|---|---|---|
| A 忘贴 first-line | ~5 次 | ✅ L1 |
| B 故意选错 skill | 0 次 | ❌ LLM 才能 |
| C 跳阶段 | 偶见 | ⚠️ L4 部分 |
| D 贴了没 invoke | ~2 次 | ✅ L2 |

### A.3 4 种 scope 方案对比

| | 范围 | 复杂度 | hardening-5 相似度 |
|---|---|---|---|
| α | 仅 D | 低 | 低 |
| α'' | A + D + L3 exempt | 中低 | 低 |
| **ζ（最终）** | A + D + L3 + 部分 C + L5 codex | 中 | 中 |
| β | A + B(部分) + C + D + γ | 高 | 高（hardening-5 类） |

### A.4 为何选 ζ 不选 β

hardening-5 数据：spec 尝试 1（full G3）11 轮不收敛；尝试 2（5.1 拆解）6 轮不收敛。沉没成本：直接 ζ ~3h vs β 若失败降 ζ ~12h。

### A.5 β / γ 升级触发

- β 触发：H6 ship 后 2-3 业务 plan drift log `illegal_transition` 频率 > 每 plan 3 次
- γ 触发："声明 + invoke 了但没产 artifact" 频繁

### A.6 并行 3 对话不可行

`.claude/` 共享一份（hook 互相 clobber）；3 方案嵌套（α'' ⊂ ζ ⊂ β）。

### A.7 Codex R1 3 findings 处理（2026-04-22）

| Finding | 严重 | 处理 |
|---|---|---|
| F1 unknown gate bypass | HIGH | v3 block mode fail-closed + `ALLOW_UNKNOWN_GATE=1` migration flag |
| F2 exempt integrity blacklist 漏 | HIGH | v3 改 allowlist（严格白名单 + 无重定向 + 无复合命令）|
| F3 mini-state 全局单文件 | MEDIUM | v3 按 `<wt-hash8>-<session8>.json` 隔离，原子 write |

### A.14 Codex R7 1 finding 处理（2026-04-22）

| Finding | 严重 | 处理（v9） |
|---|---|---|
| F1 HIGH observe mode + session_start 未知 仍接受 stale evidence | HIGH | 明确区分"响应 block / pass"与"L5 evidence 判定"。session_start 未知时 **evidence 永远判 FAIL**，drift-log `session_start_unknown`；响应层行为：block mode → BLOCK 响应，observe mode → pass 响应但 **telemetry 记为 non-compliant**（观察期数据仍正确反映问题）|

v9 新增测试：
- block mode + session_start 未知 + 有 target-bound ledger entry → **BLOCK**（即使 entry 存在）
- observe mode + session_start 未知 + 有 target-bound ledger entry → drift-log `session_start_unknown` + `codex_gate_stale_evidence`，响应 pass（mode=observe 语义），但**不**视作合规

### A.13 Codex R6 1 finding 处理（2026-04-22）

| Finding | 严重 | 处理（v8） |
|---|---|---|
| F1 HIGH 12H fallback 可绕 | HIGH | 去 12H rolling fallback；session_start 两个源都不可用时 evidence 判 FAIL |

### A.12 Codex R5 2 findings 处理（2026-04-22）

| Finding | 严重 | 处理（v7） |
|---|---|---|
| F1 HIGH L5 file target 不 revision-bound | HIGH | path A/B 对 file target 增加 `blob_sha == git hash-object <file>` 校验；如 attest 后 edit 同文件，blob 变 → ledger entry 成 stale → BLOCK。branch target 天然 bind HEAD sha（ledger key 里）|
| F2 MEDIUM 测试 plan 仍包含已删 path C 测试 | MEDIUM | §5.1 L5 测试列表重写：删除所有 stdout `Verdict: approve` 测试；加 file blob mismatch / branch HEAD 移动 / override file kind blob mismatch 测试 |

### A.11 Codex R4 2 findings 处理（2026-04-22）

| Finding | 严重 | 处理（v6） |
|---|---|---|
| F1 HIGH L5 首次声明死锁假定 | HIGH | 时序澄清：Stop hook 在响应完成**后**触发，响应内 Bash 调 codex-attest.sh 跑完时 ledger 已 update，path A 能查到。正确模式（i + ii）spec 明文写。禁止模式：声明 gate 但响应不跑 Bash 且 ledger 无 entry → BLOCK。无死锁 |
| F2 MEDIUM empty target 降级到 observe | MEDIUM | empty target 在 block mode 下 BLOCK（除非 last_stage=`_initial` 或 env `ALLOW_EMPTY_CODEX_TARGET=1`）。防止 state 损坏 bypass |

### A.10 Codex R3 2 findings 处理（2026-04-22）

| Finding | 严重 | 处理（v5） |
|---|---|---|
| F1 Path C (command stdout) 不绑 target | HIGH | 删除 Path C；codex-attest.sh / attest-override.sh 跑完会自己 update ledger/override-log，下一次响应走 L5 时 Path A/B 自然抓到。`Skill gate: codex:adversarial-review` 响应本身不保证 pass—必须等 attest 跑完 ledger 写好（下一次响应）才 pass |
| F2 receiving-code-review 合法 next 太窄 | MEDIUM | legal_next_set 加 `systematic-debugging` + `executing-plans`，覆盖 review 后 reproduce-bug / execute-fix 循环 |

### A.9 Codex R2 3 findings 处理（2026-04-22）

| Finding | 严重 | 处理（v4） |
|---|---|---|
| F1 L5 接受错的证据（needs-attention 通过 / 无关 ledger entry 通过）| HIGH | 精化 exempt_rule：A 路径必须 ledger key 匹配 target + `attest_time_utc` 非空；B 路径必须 override-log 匹配 target；C 路径解析 codex-attest stdout，`Verdict: approve` 才 pass；needs-attention BLOCK |
| F2 read-only allowlist 仍可 find -delete / git diff --output / git log \| tee | HIGH | Bash 几乎全禁；仅允许 `pwd/true/false/echo literal/ls/cat/head/tail/wc` 严格模式；禁管道/重定向/复合；复杂查询用 Read/Grep/Glob tool |
| F3 codex stage 不更新 mini-state | MEDIUM | L5 pass 后**也进 L4** 检查 legal_next_set + atomic update last_stage 为 "codex:adversarial-review" |

### A.8 User 2026-04-22 新增要求：codex:adversarial-review 纳入 first-class

理由：Plan 1f audit 发现我会忘跑 codex on spec（上一轮就漏了）。原 spec 把 codex 完全排除 hook 体系，靠"自觉"。现在纳入：
- config.enforce 加 `codex:adversarial-review` entry
- legal_next_set 里 `brainstorming → codex → writing-plans`、`writing-plans → codex → impl`、`finishing → codex → _initial` 全部把 codex 写入
- 豁免：检测 `codex-attest.sh` / `attest-override.sh` Bash 调用 或 attest-ledger 最近 entry
- **不改既有 codex 任何 hook**（纯新 hook 里识别信号）

---

## 附录 B：Spec 自查（skill §Spec Self-Review 4 项）

1. **Placeholder** 无 TBD/TODO
2. **一致性**：14 skill（含 codex）数在 §1.1 / §2.3 / §4 / §A.8 一致
3. **Scope** 单 spec 单 H6.0 PR
4. **Ambiguity**：allowlist 正则、wt_hash8 / session_id8 计算、legal_next_set 表都显式
