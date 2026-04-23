# Hardening-6 Framework (H6.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **⚠️ PR scope notice (v46 R46 F1 HIGH fix):** This document is a **plan**,
> not a completed delivery. The H6.0 framework PR MUST include BOTH this
> plan/spec AND the implementation artifacts listed in the File Structure
> table (hooks, config, settings, tests, acceptance script, CI workflow).
> A PR that contains ONLY this plan/spec file is NOT a valid H6.0 framework
> delivery — the non-coder checklist (`scripts/acceptance/hardening_6_framework.sh`)
> must pass against real files in the PR before any merge claim. Reviewers
> (codex/human) seeing a docs-only branch should REJECT as "implementation
> missing" regardless of plan content quality.

**Goal (v39 R38 F2 + v40 R39 F1 scope correction):** 建 skill pipeline enforcement 框架 **骨架 + 全 observe** (ζ scope, 5 层)：新 `skill-invoke-check.sh` hook + 升级 `stop-response-check.sh` + `skill-invoke-enforced.json` config + per-worktree/session mini-state + drift log + CI workflow。**H6.0 只落 observe-mode 骨架**；`enforcement_mode` 全程保持 `drift-log`。**L1/L3 global hard-block 的 flip 不在本 PR** — 拆到后续单独 PR `H6.0-flip`，前置条件为 admin 手动确认 branch protection / rulesets 已配置 required status check。

**Architecture:** 2 个 Stop hooks 串联（既有 stop-response-check.sh 升级 L1/L3 + 新 skill-invoke-check.sh 做 L2/L4/L5；所有 block 逻辑已就位，但当前 enforcement_mode=drift-log 时都走 drift-log 分支）；JSON config 驱动 14 个 skill 的 mode 和 legal_next_set；mini-state 按 worktree hash + session_id 隔离原子 write；codex gate 读 attest-ledger.json + attest-override-log.jsonl 做 target-bound + revision-bound 证据检查（不改既有 codex hook）。

**Tech Stack:** bash 4 + `jq` / `python3` / POSIX regex / JSONL append-only log。复用既有 `ledger-lib.sh` pattern。测试用 Python (匹配既有 `tests/hooks/test_*.py` pattern)。

**依赖（hard prereq）**：
- PR #17 hardening-1 merged（settings.json Edit/Write catch-all + `.claude/hooks/` 基础）
- PR #19 hardening-2 merged（drift-log + `skill-gate-drift.jsonl` + `stop-response-check.sh` 骨架）
- PR #22 skill-router-hook merged（UserPromptSubmit 提醒 hook）
- 既有 `.claude/scripts/codex-attest.sh` / `attest-override.sh` / `ledger-lib.sh`（不改，仅读其 ledger 输出）

**Spec**：`docs/superpowers/specs/2026-04-22-hardening-6-framework-design.md` v9 已 codex approve at `94d618f`。

## Scope 边界

**In scope**：建框架骨架 + 14 skill observe（**不 block 任何 per-skill 调用**；`enforcement_mode` 全程 drift-log；所有 block 代码已就位但仅在 enforcement_mode=block 时激活）

**Out of scope**（v39 R38 F2 defer）：
- **`enforcement_mode` drift-log → block flip（H6.0-flip 单独 PR，要求 admin 先配 branch protection）**
- per-skill flip 到 block（H6.1-H6.10 后续 PR）
- 完整 state machine β（H7）
- Artifact check γ（H7）
- State cleanup（H7 backlog）
- 任何改 `codex-attest.sh` / `guard-attest-ledger.sh` / `attest-override.sh`（Non-Goal 硬约束）

## File Structure

新增 / 修改文件清单（共 11）：

| 文件 | 动作 | 所有 Task | 预估行 |
|---|---|---|---|
| `.claude/config/skill-invoke-enforced.json` | 新增 | Task 1 | ~120 JSON |
| ~~`.claude/state/skill-stage/.gitkeep`~~ | runtime 创建（gitignored）| Task 2 验证 gitignore | 0（不 commit）|
| ~~`.claude/state/skill-invoke-drift.jsonl`~~ | runtime 创建（gitignored）| Task 2 验证 gitignore | 0（不 commit）|
| `.claude/hooks/stop-response-check.sh` | 升级 | Task 3 | +90 |
| `tests/hooks/test_stop_response_check.py` | 扩充 | Task 4 | +150 |
| `.claude/hooks/skill-invoke-check.sh` | 新增 | Task 5 | ~280 |
| `tests/hooks/test_skill_invoke_check.py` | 新增 | Task 6 | ~320 |
| `.claude/settings.json` | 修改 | Task 7 | +4 |
| `scripts/acceptance/hardening_6_framework.sh` | 新增 | Task 8 | ~90 |
| `.claude/workflow-rules.json` | 修改 | Task 9 | 1 行 |
| `.github/workflows/hardening_6_gate.yml` | 新增 | Task 8.75 | ~30 |

---

## Task 1: Create `skill-invoke-enforced.json` config

**Files:**
- Create: `.claude/config/skill-invoke-enforced.json`

**背景**：定义 13 skill（含 codex:adversarial-review）的 `mode` / `flip_phase` / `exempt_rule`；定义 `legal_next_set` 转换表；定义 `wildcard_always_allowed` + `reset_triggers`。

- [ ] **Step 1: 写 config 文件**

```bash
mkdir -p .claude/config
cat > .claude/config/skill-invoke-enforced.json <<'EOF'
{
  "version": "1",
  "description": "Hardening-6 v9: 5-layer skill pipeline enforcement (L1 gate presence / L2 Skill tool invoke / L3 exempt integrity / L4 mini-state / L5 codex target-bound + revision-bound evidence). Initial全 observe; per-skill flip 在 H6.1-H6.10.",
  "unknown_gate_policy": {
    "drift-log_mode": "drift-log_then_pass",
    "block_mode": "fail_closed_unless_ALLOW_UNKNOWN_GATE=1"
  },
  "enforce": {
    "codex:adversarial-review": {
      "mode": "observe",
      "flip_phase": "H6.10",
      "exempt_rule": "codex-evidence-bound-to-target",
      "note": "v3 first-class; ledger/override-log path A/B only; no stdout path C; revision-bound for file targets"
    },
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
      "mode": "observe",
      "flip_phase": "H6.4",
      "exempt_rule": "plan-start-in-worktree"
    },
    "superpowers:using-superpowers": { "mode": "observe", "flip_phase": "永久" },
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
    "_note_wildcard": "v15 R14 F1 fix: hook 对 wildcard skill NOT 更新 last_stage (避免 wildcard 后下一步看到空 legal_next_set). systematic-debugging 已有 legal_next_set entry (见上); using-superpowers 和 dispatching-parallel-agents 不需要 entry 因为 wildcard 路径直接 pass 不更新 state",
    "reset_triggers": {
      "new_worktree": {
        "signal": "response tool_uses contains Bash with command matching 'git worktree add'",
        "effect": "last_stage reset to _initial"
      },
      "finishing_branch_pushed": {
        "signal": "response tool_uses contains Bash with command matching 'git push' AND '(gh pr create|gh pr merge)'",
        "effect": "last_stage reset to _initial"
      },
      "session_switch": {
        "signal": "state file {wt_hash8}-{session_id8}.json not found for current session",
        "effect": "implicit _initial (new file created on first write)"
      }
    }
  }
}
EOF
```

- [ ] **Step 2: 验证 JSON 合法 + 所有 skill 列全**

```bash
jq -e '.enforce | length == 14' .claude/config/skill-invoke-enforced.json
# v15 R14 F1 fix: legal_next_set covers only NON-wildcard skills + _initial
# wildcards (using-superpowers/systematic-debugging/dispatching-parallel-agents):
#   - systematic-debugging DOES have an entry (it's in wildcard for always-allowed
#     to enter from any state, but also its own transitions are defined)
#   - using-superpowers / dispatching-parallel-agents don't need entries: hook
#     pass-through without state update
# Compute expected: enforce keys - {using-superpowers, dispatching-parallel-agents}
# = 14 - 2 = 12 non-wildcard skills + _initial + systematic-debugging = 14 entries total
jq -e '.mini_state.legal_next_set | length == 14' .claude/config/skill-invoke-enforced.json
# Keyset check: non-wildcard-exempt enforce skills ⊆ legal_next_set keys
# (systematic-debugging counted as having entry even though also wildcard)
jq -r '(.enforce | keys) - (["superpowers:using-superpowers", "superpowers:dispatching-parallel-agents"]) | .[]' .claude/config/skill-invoke-enforced.json | sort > /tmp/enforce-keys
jq -r '.mini_state.legal_next_set | keys[] | select(. != "_initial")' .claude/config/skill-invoke-enforced.json | sort > /tmp/state-keys
diff /tmp/enforce-keys /tmp/state-keys && echo "OK: 两表 skill 一致（排除 state-less wildcards）"
```

Expected: `OK: 两表 skill 一致`

- [ ] **Step 3: commit**

```bash
git add .claude/config/skill-invoke-enforced.json
git commit -m "hardening-6 Task 1: skill-invoke-enforced.json 13-skill config + legal_next_set"
```

---

## Task 2: State infrastructure（v10 R9 F3 fix：runtime 创建，不 commit）

**Files:**
- None commited. Hook runtime 自动创建 `.claude/state/skill-stage/` 目录和 `.claude/state/skill-invoke-drift.jsonl` 文件（每次 append 之前 `mkdir -p` + `touch` 隐式）。

**背景**：`.gitignore` 规则已忽略 `.claude/state/*`（运行时 telemetry 不该进 git）。若强行 `git add -f` 会违背设计。hook 代码在 Task 5 已含 `mkdir -p "$STATE_DIR"` 和 Python open('a') 隐式创建文件。

- [ ] **Step 1: 验证 .gitignore 规则**

```bash
git check-ignore -q .claude/state/skill-stage/foo.json && echo "OK: gitignore 覆盖 state 目录"
git check-ignore -q .claude/state/skill-invoke-drift.jsonl && echo "OK: gitignore 覆盖 drift log"
```

Expected: 2 行 OK（确认 hook 运行时创建的文件不会被 git track）

- [ ] **Step 2: 无需 commit**

```bash
# 本 task 不 commit 任何文件；仅确认 .gitignore 行为正确
echo "Task 2: no commit (runtime artifacts)"
```

---

## Task 3: Upgrade `stop-response-check.sh` (L1 block + L3 exempt integrity)

**Files:**
- Modify: `.claude/hooks/stop-response-check.sh`（当前 128 行，添加 L1 block 分支 + L3 allowlist check）

**背景**：既有 hook 已做 first-line format 检查，当前是 drift-log 模式。H6 升级增加：
1. 读 `workflow-rules.json.skill_gate_policy.enforcement_mode`。若 = `block` 且 first-line 缺失/格式 invalid → block（既有行为在 H6.9 flip 后变 block）
2. exempt 合理性 allowlist（L3）：read-only-query / behavior-neutral / single-step-no-semantic-change 下严格限制 tool_uses

- [ ] **Step 0: 收紧既有 first-line regex（v44 R44 F1 HIGH final fix：H6 scope only）**

**v44 R44 F1 HIGH final fix**：codex 在 R33→R38→R44 经过三轮反复后给出终局结论——**非-H6 plugin gate（frontend-design:* 等）必须从 L1 regex 移除**。v38 曾尝试用 L2 invoke-match 兜底，但 codex R44 指出这仍是 durable bypass：agent 可声明 `Skill gate: frontend-design:web`、调用 frontend-design skill、完全绕过 H6 required transitions (brainstorming → writing-plans → codex review)。

**终局策略**：L1 regex **只接受 H6-scoped gate**（superpowers:* + codex:* + exempt(...))。非-H6 plugin 用户两条路：
1. 用 H6 gate（如 `Skill gate: superpowers:subagent-driven-development`），在 response 内部调 frontend-design Skill tool（当作 sub-skill），正常走 L2/L4/L5
2. 显式注册 frontend-design:<name> 到 `.claude/config/skill-invoke-enforced.json`（带自己的 legal_next_set + mode），走完整 L2/L4/L5

既有 `.claude/hooks/stop-response-check.sh` line 49 regex 改成：
```bash
# v44 final: H6 scope only; non-H6 plugins go through superpowers gate or register
'^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|exempt\([a-z-]+\))'
```

L1 regex 接受 3 类：
- `Skill gate: superpowers:<name>`（14 H6 skill；完整 L2/L4/L5）
- `Skill gate: codex:<name>`（codex:adversarial-review 有 L5 契约；未注册 codex:* 走 unknown-gate fail-closed）
- `Skill gate: exempt(<reason>)`

`frontend-design:*` / 其他未注册 plugin **不是合法 L1 gate**；response 若以此开头，L1 match fail → block（Task 9 后）。

**重要（v6 R6 HIGH finding fix）**：本 Task 的 Step 2 加 block 分支仅在**既有 drift-log 分支**内嵌入（既有逻辑：regex match fail → drift-log，加 block 变为 drift-log + exit 2）。因此 Task 9 flip 到 block 后，`Skill gate: superpowers:brainstorming` 仍走既有 match 路径 pass，不被误 block。Task 4 含 `test_valid_first_line_both_modes_pass` 已验证此场景。

**Step 0 修改命令**：
```bash
sed -i.bak -E "s|frontend-design:\\[a-z-\\]\\+\\||g" .claude/hooks/stop-response-check.sh
grep -n "Skill gate:" .claude/hooks/stop-response-check.sh | head -3
```

Expected: regex **不含** `frontend-design:`；只保留 `superpowers:[a-z-]+|codex:[a-z-]+|exempt\(`

**v7 R7 finding 澄清（false positive 驳回）**：正则字符集 `[a-z-]+` 含 `-`，完整 match `adversarial-review` 这种 hyphenated name。证明：

```bash
echo 'Skill gate: codex:adversarial-review' | grep -qE '^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\([a-z-]+\))'
echo "exit=$?"  # Expected: exit=0 (match)
```

Codex R7 误读为"only one hyphen-free segment"；实则 `[a-z-]+` 正则类中的 `-` 在字符集末尾位置被 POSIX 视为字面 hyphen 字符，可匹配任意含 `-` 的 a-z 串。Task 4 含专门 TestCodexGateRegexExplicit 回归测试锁定此行为。

- [ ] **Step 1: 加 Python exempt validator helper（R5 F1 fix：用 Python 而非 shell parsing 避免 IFS='|' bypass）**

在 hook 开头（set -eo pipefail 之后）加 helper：

```bash
# helper: validate exempt integrity entirely in Python (avoid shell IFS parsing bypass)
# Input: transcript path + exempt reason
# Output: prints "OK" on pass; prints "BLOCK: <reason>" on fail
# Exit 0 always (hook uses output parsing)
validate_exempt_integrity() {
  python3 - "$1" "$2" <<'PY'
import json, sys, re

tpath, reason = sys.argv[1], sys.argv[2]

# Extract tool_uses from ALL assistant entries since last user entry
# (R12 F2 HIGH fix: aggregate whole turn, not just last assistant message
# earlier assistant entries may contain side-effecting tool calls while final
# one has only text)
entries = []
try:
    with open(tpath) as f:
        for line in f:
            try:
                d = json.loads(line)
                if d.get('type') in ('user', 'assistant'):
                    entries.append(d)
            except Exception:
                continue
except Exception as e:
    print(f"BLOCK: transcript parse error: {e}")
    sys.exit(0)

# v34 R34 F1 fix: distinguish HUMAN user prompt from tool_result user turn.
# Anthropic transcripts represent BOTH as type="user": human prompts have
# content as string OR list of {type:"text"} blocks; tool_result turns have
# content as list containing {type:"tool_result", ...} blocks. Using
# type=="user" as the turn boundary incorrectly dropped earlier assistant
# tool_uses before tool_result pseudo-user turns → a response could
# side-effect (Bash rm), receive tool_result, then announce exempt(read-only)
# and pass L3 check because earlier tool_use looked "in previous turn".
def is_human_user_entry(e):
    if e.get('type') != 'user':
        return False
    content = e.get('message', {}).get('content', '')
    # String content → human prompt
    if isinstance(content, str):
        return True
    # List content → human if any block is text/input-text and none is tool_result
    if isinstance(content, list):
        has_tool_result = any(
            isinstance(c, dict) and c.get('type') == 'tool_result'
            for c in content
        )
        if has_tool_result:
            return False  # tool_result pseudo-user turn
        # Otherwise treat as human if there's text content (most common shape)
        has_text = any(
            isinstance(c, dict) and c.get('type') in ('text', 'input-text')
            for c in content
        )
        return has_text or True  # default: real user (conservative)
    return False

# Find last HUMAN user entry index (current turn begins after it)
last_user_idx = -1
for i, e in enumerate(entries):
    if is_human_user_entry(e):
        last_user_idx = i

# Aggregate all tool_uses from assistant entries after last HUMAN user
last_tool_uses = []
for e in entries[last_user_idx + 1:]:
    if e.get('type') == 'assistant':
        content = e.get('message', {}).get('content', [])
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get('type') == 'tool_use':
                    last_tool_uses.append(c)

# v31 R31 F1 fix: extract last user message text for user-explicit-skip
# verification (previously trust-without-evidence was the whole L1 bypass)
last_user_text = ""
if last_user_idx >= 0:
    umsg = entries[last_user_idx].get('message', {})
    ucontent = umsg.get('content', '')
    if isinstance(ucontent, str):
        last_user_text = ucontent
    elif isinstance(ucontent, list):
        parts = []
        for c in ucontent:
            if isinstance(c, dict) and c.get('type') == 'text':
                parts.append(c.get('text', ''))
            elif isinstance(c, str):
                parts.append(c)
        last_user_text = '\n'.join(parts)

def get_cmd(tu):
    return tu.get('input', {}).get('command', '')

def get_path(tu):
    return tu.get('input', {}).get('file_path', '')

# R5 F1 fix: each tool use is a complete object; no |-split parsing
# R5 F2 fix: for behavior-neutral, check Write/Edit/NotebookEdit paths against allowlist
# R5 F3 not relevant here (target regex is in skill-invoke-check, not this hook)

# v18 R17 F2 fix: hoist CONTROL_CHARS_RE to module-level (was inside read-only branch)
CONTROL_CHARS_RE = re.compile(r'[\r\n\t\x00]')  # reject multi-line shell payloads

if reason == 'read-only-query':
    # v41 R41 F1 HIGH fix: safe_bash previously allowed `cat ~/.ssh/id_rsa`
    # because the regex checked argument charset but not path semantics.
    # The Stop hook runs AFTER the Bash already executed, so allowing the
    # exempt response means the secret has already been read into the turn.
    # v41 splits into two tiers:
    #   - pwd/true/false/echo-literal: zero-path commands, stay regex-based
    #   - ls/cat/head/tail/wc: must have one repo-relative path arg that
    #     Path.resolve()s inside repo_root and is not under a denylist
    #     (~, /Users except current repo, /etc, .ssh, .aws, credentials
    #     patterns, .env). Parsed via shlex for robust argument split.
    import shlex
    zero_path_re = re.compile(
        r'^(pwd|true|false)$'
        r'|^echo +["\'][^"\'|<>;&`$()]*["\']$'
    )
    file_read_tools = {'ls', 'cat', 'head', 'tail', 'wc'}
    sensitive_name_re = re.compile(
        r'(\.ssh|\.aws|\.gnupg|\.kube|credentials|secrets?|\.env(\..+)?|'
        r'id_[rd]sa|\.pem|\.key|\.pgpass|\.netrc)$',
        re.IGNORECASE,
    )
    for tu in last_tool_uses:
        name = tu.get('name', '')
        if name in ('Read', 'Grep', 'Glob'):
            continue
        if name == 'Bash':
            cmd = get_cmd(tu)
            # v17 R16 F1 fix: reject control chars BEFORE allowlist
            if CONTROL_CHARS_RE.search(cmd):
                print(f"BLOCK: exempt(read-only-query) Bash 含 newline/CR/tab/NUL 控制字符: {cmd[:80]!r}")
                sys.exit(0)
            if re.search(r'[|<>;&`$]', cmd) or '||' in cmd or '&&' in cmd:
                print(f"BLOCK: exempt(read-only-query) Bash 含管道/重定向/复合命令: {cmd[:80]}")
                sys.exit(0)
            # Tier 1: zero-path commands (regex match; no args or literal echo)
            if zero_path_re.fullmatch(cmd):
                continue
            # Tier 2: file-read commands - parse via shlex, verify path safety
            try:
                parts = shlex.split(cmd)
            except ValueError:
                print(f"BLOCK: exempt(read-only-query) Bash 解析失败: {cmd[:80]}")
                sys.exit(0)
            if not parts or parts[0] not in file_read_tools:
                print(f"BLOCK: exempt(read-only-query) Bash 不在白名单命令集: {cmd[:80]}")
                sys.exit(0)
            # Exactly one path arg after the command (no flags, no globs)
            args = parts[1:]
            if len(args) != 1:
                print(f"BLOCK: exempt(read-only-query) {parts[0]} 必须恰好 1 个路径参数（不允许 flags/globs）: {cmd[:80]}")
                sys.exit(0)
            path_arg = args[0]
            if path_arg.startswith('-') or any(c in path_arg for c in '*?[]{}') or path_arg.startswith('~'):
                print(f"BLOCK: exempt(read-only-query) 路径含 flag/glob/home-expansion: {path_arg}")
                sys.exit(0)
            # Resolve and verify repo containment + sensitive path denylist
            import os
            from pathlib import Path
            repo_root = Path(os.getcwd()).resolve()
            try:
                resolved = (repo_root / path_arg).resolve() if not os.path.isabs(path_arg) else Path(path_arg).resolve()
                rel = resolved.relative_to(repo_root)
            except (ValueError, OSError):
                print(f"BLOCK: exempt(read-only-query) 路径 resolve 到仓库外或不可 resolve: {path_arg}")
                sys.exit(0)
            rel_str = str(rel).replace(os.sep, '/')
            # Sensitive-name check on any path component
            for component in rel_str.split('/'):
                if sensitive_name_re.search(component):
                    print(f"BLOCK: exempt(read-only-query) 路径含敏感名 (ssh/aws/credentials/env/key/pem): {rel_str}")
                    sys.exit(0)
            continue
        print(f"BLOCK: exempt(read-only-query) 不允许工具 {name}")
        sys.exit(0)

elif reason == 'behavior-neutral':
    # R5 F2 + R8 F1 + R11 F1 CRITICAL + R12 F1 HIGH fix:
    # Write allowlist EXCLUDES .claude/state/* AND docs/superpowers/**
    # - .claude/state/: L5 evidence 文件 (R11)
    # - docs/superpowers/specs/**: brainstorming 产出, 只能 brainstorming skill 写
    # - docs/superpowers/plans/**: writing-plans 产出, 只能 writing-plans skill 写
    # 允许 docs/ 下其他文件 (如 docs/governance/, README.md 等文档)
    safe_path = re.compile(r'^(\./)?docs/.*\.md$')
    # 两个 deny 必须先于 allow 检查
    deny_path = re.compile(r'(^|/)(\.claude/state/|docs/superpowers/)')
    # Same strict Bash allowlist as read-only (prevents rm/sed-i/python writes/redirects)
    safe_bash = re.compile(
        r'^(pwd|true|false)$'
        r'|^echo +["\'][^"\'|<>;&`$()]*["\']$'
        r'|^(ls|cat|head|tail|wc|grep|rg|jq) +[^|<>;&`$(){}\-]+$'  # no -flag to avoid --output/--delete
        r'|^(git +(status|log))$'
    )
    for tu in last_tool_uses:
        name = tu.get('name', '')
        if name in ('Write', 'Edit', 'NotebookEdit', 'MultiEdit'):
            fp = get_path(tu)
            import os
            from pathlib import Path
            # v28 R28 F1 fix: resolve real path and require it inside repo root,
            # then derive repo-relative path. Defeats `/docs/release.md` and
            # `/tmp/../etc/docs/x.md` bypasses where `lstrip('/')` would
            # silently convert an absolute out-of-repo path into a relative
            # `docs/...` that passes safe_path.
            repo_root = Path(os.getcwd()).resolve()
            try:
                fp_resolved = (repo_root / fp).resolve() if not os.path.isabs(fp) else Path(fp).resolve()
            except Exception:
                print(f"BLOCK: exempt(behavior-neutral) 路径不可 resolve: {fp}")
                sys.exit(0)
            # Require resolved path strictly inside repo root
            try:
                fp_rel = fp_resolved.relative_to(repo_root)
            except ValueError:
                print(f"BLOCK: exempt(behavior-neutral) 路径 resolve 到仓库外: {fp} → {fp_resolved}")
                sys.exit(0)
            fp = str(fp_rel).replace(os.sep, '/')
            # R11 F1 CRITICAL + R12 F1 HIGH + R24 F1 + R28 F1 fix: deny
            # .claude/state/* AND docs/superpowers/** (specs/plans need
            # brainstorming/writing-plans skills)
            if deny_path.search(fp):
                print(f"BLOCK: exempt(behavior-neutral) Write/Edit 到 {fp} 禁止"
                      f"（.claude/state = L5 evidence; docs/superpowers = skill 产出区）")
                sys.exit(0)
            if not safe_path.match(fp):
                print(f"BLOCK: exempt(behavior-neutral) Write/Edit 路径不在白名单 (仅 docs/*.md): {fp}")
                sys.exit(0)
        elif name == 'Bash':
            cmd = get_cmd(tu)
            # v17 R16 F1 fix: reject control chars before allowlist
            if CONTROL_CHARS_RE.search(cmd):
                print(f"BLOCK: exempt(behavior-neutral) Bash 含 newline/CR/tab/NUL: {cmd[:80]!r}")
                sys.exit(0)
            # Reject any side-effecting command
            if re.search(r'[|<>;&`$]', cmd) or '&&' in cmd or '||' in cmd:
                print(f"BLOCK: exempt(behavior-neutral) Bash 含管道/重定向/复合命令: {cmd[:80]}")
                sys.exit(0)
            if not safe_bash.fullmatch(cmd):  # v17: fullmatch
                print(f"BLOCK: exempt(behavior-neutral) Bash 不在严格白名单（同 read-only 集）: {cmd[:80]}")
                sys.exit(0)
        elif name in ('Read', 'Grep', 'Glob'):
            continue
        else:
            # Other tools not explicitly allowed
            print(f"BLOCK: exempt(behavior-neutral) 不允许工具 {name}")
            sys.exit(0)

elif reason == 'single-step-no-semantic-change':
    # R8 F1 fix: also apply strict Bash allowlist (not just push/PR block)
    if len(last_tool_uses) > 2:
        print(f"BLOCK: exempt(single-step-no-semantic-change) tool_uses 超 2 ({len(last_tool_uses)})")
        sys.exit(0)
    safe_bash_single = re.compile(
        r'^(pwd|true|false)$'
        r'|^echo +["\'][^"\'|<>;&`$()]*["\']$'
        r'|^(ls|cat|head|tail|wc|grep|rg|jq) +[^|<>;&`$(){}\-]+$'  # no -flag to avoid --output/--delete
        # v22 R21 F1 inline (previously only in Task 8.5 guidance):
        # Allow codex-attest.sh / attest-override.sh with args for mode ii
        # (run codex first response, announce gate next response)
        r'|^\.claude/scripts/(codex-attest|attest-override)\.sh( +[-A-Za-z0-9_./:=@]+)*$'
    )
    for tu in last_tool_uses:
        name = tu.get('name', '')
        if name in ('Read', 'Grep', 'Glob'):
            continue
        if name == 'Bash':
            cmd = get_cmd(tu)
            # v17 R16 F1 fix: reject control chars before allowlist
            if CONTROL_CHARS_RE.search(cmd):
                print(f"BLOCK: exempt(single-step) Bash 含 newline/CR/tab/NUL: {cmd[:80]!r}")
                sys.exit(0)
            if re.search(r'[|<>;&`$]', cmd) or '&&' in cmd or '||' in cmd:
                print(f"BLOCK: exempt(single-step) Bash 含管道/重定向/复合命令: {cmd[:80]}")
                sys.exit(0)
            if not safe_bash_single.fullmatch(cmd):  # v17: fullmatch
                print(f"BLOCK: exempt(single-step) Bash 不在严格白名单: {cmd[:80]}")
                sys.exit(0)
            continue
        print(f"BLOCK: exempt(single-step) 不允许工具 {name}")
        sys.exit(0)

# v31 R31 F1 fix: user-explicit-skip MUST carry an auditable current-turn
# authorization. Previously "trust user, no content check" was an L1 bypass:
# any response could declare exempt(user-explicit-skip) and skip L2/L4/L5.
# v31 requires the MOST RECENT user message to contain one of the explicit
# phrases (case-insensitive, Chinese or English). If missing, BLOCK so the
# bypass can only be used by actual user instruction, not by Claude alone.
elif reason == 'user-explicit-skip':
    AUTH_PHRASES = [
        r'skip\s*skill',          # en: "skip skill"
        r'no\s*skill',            # en: "no skill"
        r'without\s*skill',       # en: "without skill"
        r'exempt.*skill',         # en: "exempt skill" / "use exempt"
        r'bypass\s*skill',        # en: "bypass skill"
        r'跳过\s*skill',          # zh: "跳过 skill"
        r'不用\s*skill',          # zh: "不用 skill"
        r'免\s*skill',            # zh: "免 skill"
        r'/no-?skill',            # slash marker
    ]
    auth_re = re.compile('|'.join(AUTH_PHRASES), re.IGNORECASE)
    if not auth_re.search(last_user_text):
        print(f"BLOCK: exempt(user-explicit-skip) 需当前 user message 含显式授权短语（skip skill / 跳过skill / 不用skill / 免skill / /no-skill 等）")
        sys.exit(0)
    # Authorization found: pass; the hook's caller still drift-logs the skip

print("OK")
PY
}
```

- [ ] **Step 2: L1 block 模式逻辑（insert 在既有 drift-log 块后）**

在 `echo "[skill-gate-drift] ..."` 之后的 `fi` 后添加：

```bash
  # L1 block mode (H6.9 flip): if enforcement_mode=block, hard block missing first-line
  # v36 R36 F1 + v43 R43 F1 fix: rescue mode-i codex flow ONLY.
  # Real rescue scenario: final assistant (after tool_result) lacks gate
  # because mode-i = same-response announce + codex-attest Bash. Rescue
  # does NOT apply to exempt(...) gates — exempt responses do not need
  # tool_use for exempt semantics, and allowing exempt rescue would let
  # an earlier exempt gate pass L1 while L3 exempt validator skips
  # (because it reads original ungated first_line) → bypass: exempt +
  # disallowed Bash + tool_result + ungated final could run.
  RULES=".claude/workflow-rules.json"
  ENF_MODE=$(jq -r '.skill_gate_policy.enforcement_mode // "drift-log"' "$RULES" 2>/dev/null)
  if [ "$ENF_MODE" = "block" ]; then
    # Scan current turn ONLY for non-exempt skill gates (codex:*/superpowers:*/
    # v45 R45 F1 final: rescue ONLY non-exempt H6-scoped gates (superpowers:*
    # or codex:*). frontend-design:* was still in rescue regex after v44 dropped
    # it from the primary L1 regex — that left a bypass where earlier
    # frontend-design gate rescued, final ungated, Hook 2 H6-only regex ignored
    # the plugin gate, effectively passing without H6 enforcement. Drop
    # frontend-design:* here too.
    CUR_TURN_GATE=$(python3 - "$tpath" <<'PY'
import json, re, sys
# v45 R45 F1: rescue ONLY H6 non-exempt gates. exempt/plugin rescue bypass L3/L2.
GATE_RE = re.compile(r'^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+)')
entries = []
try:
    for line in open(sys.argv[1]):
        try:
            entries.append(json.loads(line))
        except Exception: continue
except Exception: pass
def is_human(e):
    if e.get('type') != 'user': return False
    c = e.get('message', {}).get('content', '')
    if isinstance(c, str): return True
    if isinstance(c, list):
        if any(isinstance(x, dict) and x.get('type') == 'tool_result' for x in c):
            return False
    return True
lui = -1
for i, e in enumerate(entries):
    if is_human(e): lui = i
for e in entries[lui+1:]:
    if e.get('type') != 'assistant': continue
    content = e.get('message', {}).get('content', [])
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get('type') == 'text':
                fl = (c.get('text','').splitlines() or [''])[0]
                m = GATE_RE.match(fl)
                if m:
                    print(m.group(1)); sys.exit(0)
PY
)
    if [ -z "$CUR_TURN_GATE" ]; then
      block "first-line Skill gate 缺失或格式无效（当前 turn 无任何 assistant 含合法非-exempt gate；exempt rescue 不允许）；当前 first_line=\"$first_line\""
    fi
    # Current turn has a non-exempt gate on an earlier assistant (mode-i
    # pattern: codex:adversarial-review). Pass L1. L3 exempt integrity is
    # NOT triggered here because rescued gate is non-exempt by construction.
  fi
```

- [ ] **Step 3: L3 exempt integrity allowlist (v6：委托 Python helper，避免 shell IFS bypass)**

在既有 `# 2) Exempt reason whitelist` 块之后，添加 L3 integrity check：

```bash
# L3 exempt integrity (v6 H6 R5 F1+F2 fix): delegate to Python validator
# Avoids shell IFS='|' parsing that let 'cat x | tee y' bypass allowlist
# Also handles Write/Edit path check for behavior-neutral
# v45 R45 F2 fix: respect enforcement_mode. In drift-log mode, integrity
# violations drift-log only (do not block). Task 9 flip activates block.
# Previously unconditional `block` violated observe-only H6.0 rollout
# boundary — H6.0 would start rejecting exempt responses before the
# branch-protection checkpoint and before false-positive data collection.
if echo "$first_line" | grep -qE '^Skill gate: exempt\('; then
  reason=$(echo "$first_line" | sed -E 's/^Skill gate: exempt\(([^)]+)\).*/\1/')
  # reason 已在 §2 被白名单过滤，这里只检 integrity
  result=$(validate_exempt_integrity "$tpath" "$reason")
  if [[ "$result" == BLOCK:* ]]; then
    # v45 R45 F2: drift-log in observe; block only in enforcement=block
    ENF_MODE_L3=$(jq -r '.skill_gate_policy.enforcement_mode // "drift-log"' .claude/workflow-rules.json 2>/dev/null)
    DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
    mkdir -p "$(dirname "$DRIFT_LOG")"
    printf '{"time_utc":"%s","kind":"l3_integrity_violation","first_line":%s,"reason":%s,"block_message":%s,"enforcement_mode":"%s","blocked":%s}\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      "$(printf '%s' "$first_line" | jq -Rs .)" \
      "$(printf '%s' "$reason" | jq -Rs .)" \
      "$(printf '%s' "${result#BLOCK: }" | jq -Rs .)" \
      "$ENF_MODE_L3" \
      "$([ "$ENF_MODE_L3" = "block" ] && echo true || echo false)" \
      >> "$DRIFT_LOG"
    if [ "$ENF_MODE_L3" = "block" ]; then
      block "${result#BLOCK: }"
    fi
    # drift-log mode: emit stderr warning but pass
    echo "[l3-drift] ${result#BLOCK: } (enforcement_mode=$ENF_MODE_L3; not blocking)" >&2
  fi
fi
```

- [ ] **Step 4: 测试本 hook 手工跑一遍**

```bash
# Mock transcript with missing first-line
cat > /tmp/mock_transcript.jsonl <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Some response without gate"}]}}
EOF
echo '{"transcript_path":"/tmp/mock_transcript.jsonl"}' | .claude/hooks/stop-response-check.sh
```

Expected: stderr 有 `[skill-gate-drift]` 提示；exit 0（drift-log，enforcement_mode 仍是 drift-log）

- [ ] **Step 5: commit**

```bash
git add .claude/hooks/stop-response-check.sh
git commit -m "hardening-6 Task 3: upgrade stop-response-check.sh L1 block + L3 exempt integrity allowlist"
```

---

## Task 4: Tests for stop-response-check.sh upgrade

**Files:**
- Modify: `tests/hooks/test_stop_response_check.py`（扩充现有测试文件）

- [ ] **Step 1: 阅读既有测试文件 pattern**

```bash
head -40 tests/hooks/test_stop_response_check.py
```

Expected: 既有 Python pytest 风格；知道如何构造 mock transcript + invoke hook

- [ ] **Step 2: 追加新测试 cases 到文件末尾**

追加：

```python
# === Hardening-6 Task 4: L1 block mode + L3 exempt integrity tests ===

import json
import os
import subprocess
import tempfile
import pytest

HOOK = ".claude/hooks/stop-response-check.sh"

def _run_hook(transcript_path):
    """Invoke hook with stdin JSON; return (exit_code, stdout, stderr)."""
    proc = subprocess.run(
        ["bash", HOOK],
        input=json.dumps({"transcript_path": str(transcript_path)}),
        capture_output=True, text=True, timeout=10,
    )
    return proc.returncode, proc.stdout, proc.stderr

def _write_transcript(tmp_path, assistant_text, tool_uses=None, user_text=None,
                      prior_assistant_tool_uses=None):
    """Write mock transcript JSONL. Optionally includes a preceding user message
    (needed for v31 R31 F1 user-explicit-skip tests which validate last-user-text).
    v34 R34 F1: prior_assistant_tool_uses lets tests build transcripts like
    [user prompt, assistant+tool_uses, tool_result user pseudo-turn,
     final assistant with gate] to verify hook aggregates across tool_result
     pseudo-turns correctly."""
    lines = []
    if user_text is not None:
        user_entry = {"type": "user", "message": {"content": user_text}}
        lines.append(json.dumps(user_entry))
    if prior_assistant_tool_uses:
        prior_content = []
        for tu in prior_assistant_tool_uses:
            prior_content.append({"type": "tool_use", "id": tu.get("id", "tu_prior"),
                                   "name": tu["name"], "input": tu["input"]})
        lines.append(json.dumps({"type": "assistant", "message": {"content": prior_content}}))
        # tool_result pseudo-user turn (what Anthropic transcripts actually have)
        tool_result_entry = {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": prior_assistant_tool_uses[0].get("id", "tu_prior"),
             "content": "ok"}
        ]}}
        lines.append(json.dumps(tool_result_entry))
    content = [{"type": "text", "text": assistant_text}]
    if tool_uses:
        for tu in tool_uses:
            content.append({"type": "tool_use", "name": tu["name"], "input": tu["input"]})
    entry = {"type": "assistant", "message": {"content": content}}
    lines.append(json.dumps(entry))
    tp = tmp_path / "transcript.jsonl"
    tp.write_text('\n'.join(lines) + '\n')
    return tp

def _set_enforcement_mode(mode):
    """Temporarily set workflow-rules.json enforcement_mode."""
    import shutil, pathlib
    p = pathlib.Path(".claude/workflow-rules.json")
    shutil.copy(p, str(p) + ".bak")
    rules = json.loads(p.read_text())
    rules["skill_gate_policy"]["enforcement_mode"] = mode
    p.write_text(json.dumps(rules, indent=2))
    return str(p) + ".bak"

def _restore_enforcement_mode(backup):
    import shutil
    shutil.move(backup, backup[:-4])

class TestL1BlockMode:
    def test_missing_first_line_block_mode_blocks(self, tmp_path):
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(tmp_path, "No gate declaration here")
            rc, stdout, stderr = _run_hook(tp)
            assert rc == 0  # hook uses JSON output for block
            assert '"decision":"block"' in stdout or '"decision": "block"' in stdout
        finally:
            _restore_enforcement_mode(bak)

    def test_missing_first_line_drift_mode_pass(self, tmp_path):
        bak = _set_enforcement_mode("drift-log")
        try:
            tp = _write_transcript(tmp_path, "No gate declaration here")
            rc, stdout, stderr = _run_hook(tp)
            assert rc == 0
            assert "skill-gate-drift" in stderr
            assert '"decision"' not in stdout  # not block
        finally:
            _restore_enforcement_mode(bak)

    def test_codex_adversarial_review_gate_regex_explicit(self, tmp_path):
        """R7 F1 regression: prove regex [a-z-]+ accepts codex:adversarial-review.
        
        Codex R7 incorrectly inferred that codex:[a-z-]+ allows only single
        hyphen-free segment. In POSIX character classes, the literal - can
        be placed at end/start of class and matches any hyphen - so
        [a-z-]+ matches adversarial-review (mix of a-z and -).
        """
        # Test the exact first-line string Task 1 requires
        for mode in ("drift-log", "block"):
            bak = _set_enforcement_mode(mode)
            try:
                tp = _write_transcript(tmp_path, "Skill gate: codex:adversarial-review\n\nText")
                rc, stdout, stderr = _run_hook(tp)
                assert rc == 0
                assert '"decision":"block"' not in stdout.replace(" ", ""), f"mode={mode} blocked 'codex:adversarial-review' - Hook 1 regex bug"
                # No skill-gate-drift WARN either (means regex matched)
                assert "skill-gate-drift" not in stderr, f"mode={mode} drift-logged 'codex:adversarial-review' - regex didn't match"
            finally:
                _restore_enforcement_mode(bak)

        # Additional sanity: raw grep test of the regex
        import subprocess as sp
        for line in [
            "Skill gate: codex:adversarial-review",
            "Skill gate: superpowers:verification-before-completion",
            "Skill gate: superpowers:requesting-code-review",
            "Skill gate: superpowers:finishing-a-development-branch",
        ]:
            r = sp.run(
                ["grep", "-qE",
                 "^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|exempt\\([a-z-]+\\))"],  # v44 R44 F1 final: H6 scope only
                input=line, capture_output=True, text=True,
            )
            assert r.returncode == 0, f"regex rejected valid gate: {line}"

    def test_valid_first_line_both_modes_pass(self, tmp_path):
        """Verify 3 legal gate forms pass Hook 1 in both modes (R6 F1 verification).

        v44 R44 F1 final: L1 scope restricted to H6 only
        (superpowers:* + codex:* + exempt(...)). Non-H6 plugins (frontend-design
        etc.) either go through superpowers:* gate as sub-skill, or register
        in skill-invoke-enforced.json with their own L2/L4/L5 contract.
        """
        gate_samples = [
            "Skill gate: superpowers:brainstorming\n\nSome text",
            "Skill gate: superpowers:writing-plans\n\ntext",
            "Skill gate: superpowers:verification-before-completion\n\ntext",
            "Skill gate: codex:adversarial-review\n\ntext",
            "Skill gate: exempt(read-only-query)\n\ntext",
            "Skill gate: exempt(behavior-neutral)\n\ntext",
        ]
        for mode in ("drift-log", "block"):
            bak = _set_enforcement_mode(mode)
            try:
                for gate in gate_samples:
                    tp = _write_transcript(tmp_path, gate)
                    rc, stdout, stderr = _run_hook(tp)
                    assert rc == 0
                    # Skill gate (non-exempt) or exempt passed whitelist → no block
                    assert '"decision":"block"' not in stdout.replace(" ", ""), f"mode={mode} gate={gate[:60]} unexpectedly blocked"
            finally:
                _restore_enforcement_mode(bak)


class TestL3ExemptIntegrityReadOnly:
    def test_read_only_with_read_tool_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\nLooking at a file.",
            tool_uses=[{"name": "Read", "input": {"file_path": "/tmp/foo.txt"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_read_only_with_edit_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\nActually editing",
            tool_uses=[{"name": "Edit", "input": {"file_path": "/tmp/foo.txt", "old_string": "a", "new_string": "b"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_bash_pwd_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "pwd"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_read_only_with_bash_git_push_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git push origin main"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_bash_pipe_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git log | tee out.txt"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_find_delete_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "find . -delete"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # v30 R30 F1 regression tests: spec §3.1 R2 F2 hardening — git fully blocked
    # in read-only-query. Earlier spec diagram (pre-v30) listed git as legal,
    # which contradicted the authoritative §3.1 policy. These tests lock the
    # hardened policy so future spec drift can't silently relax it.
    def test_read_only_with_git_status_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git status"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_git_diff_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git diff HEAD~1"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_with_git_log_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git log --oneline"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # v41 R41 F1 regression: read-only exempt Bash cat/head/tail/wc MUST
    # reject sensitive paths (~/.ssh/id_rsa, ~/.aws/credentials, .env) and
    # repo-outside absolute paths. Previously safe_bash regex charset check
    # allowed these, and Stop hook fires AFTER Bash already ran → exempt
    # approval would let a response containing secrets be emitted.
    def test_read_only_cat_ssh_key_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "cat ~/.ssh/id_rsa"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_cat_aws_credentials_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "cat /Users/x/.aws/credentials"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_cat_dotenv_blocks(self, tmp_path):
        """Repo-relative .env files are still blocked (sensitive by name)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "cat .env"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_cat_abs_out_of_repo_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "cat /etc/passwd"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_read_only_cat_repo_relative_passes(self, tmp_path):
        """Repo-relative non-sensitive path (e.g., README.md) passes."""
        # Create a harmless file to cat
        f = Path("README.md")
        created = False
        if not f.exists():
            f.write_text("readme")
            created = True
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: exempt(read-only-query)\n\n",
                tool_uses=[{"name": "Bash", "input": {"command": "cat README.md"}}],
            )
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' not in stdout.replace(" ", "")
        finally:
            if created:
                f.unlink(missing_ok=True)

    # v45 R45 F1 regression: mode-i rescue MUST NOT rescue frontend-design
    # (or other plugin gates outside H6 scope). Attack shape: earlier
    # `Skill gate: frontend-design:web` + plugin tool_use + tool_result
    # + ungated final. Without fix: L1 rescue accepts plugin gate, Hook 2
    # H6-only regex skips plugin gate → effectively passes without H6
    # state machine or codex evidence enforcement.
    def test_block_mode_frontend_design_rescue_rejected_r45_f1(self, tmp_path):
        """Earlier frontend-design gate + tool_result + ungated final MUST
        BLOCK in block mode (rescue refuses non-H6-scoped gates)."""
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Implementation done.",
                user_text="add a form component",
            )
            lines = tp.read_text().splitlines()
            gated = json.dumps({
                "type": "assistant",
                "message": {"content": [
                    {"type": "text", "text": "Skill gate: frontend-design:web\n\ndesigning"},
                    {"type": "tool_use", "id": "tu_fd",
                     "name": "Skill",
                     "input": {"skill": "frontend-design:web"}},
                ]},
            })
            tool_result = json.dumps({
                "type": "user",
                "message": {"content": [
                    {"type": "tool_result", "tool_use_id": "tu_fd",
                     "content": "design ok"},
                ]},
            })
            new_lines = [lines[0], gated, tool_result, lines[1]]
            tp.write_text('\n'.join(new_lines) + '\n')
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' in stdout.replace(" ", ""), \
                f"frontend-design rescue bypass must block; stdout={stdout[:400]}"
        finally:
            _restore_enforcement_mode(bak)

    # v45 R45 F2 regression: L3 integrity violations MUST drift-log (not
    # block) when enforcement_mode=drift-log. Block only activates after
    # Task 9/H6.0-flip.
    def test_l3_violation_drift_logs_in_observe_mode_r45_f2(self, tmp_path):
        """drift-log mode + exempt(read-only-query) + disallowed Bash →
        drift-log entry written, NO block decision."""
        bak = _set_enforcement_mode("drift-log")
        drift_log = Path(".claude/state/skill-gate-drift.jsonl")
        drift_log.parent.mkdir(parents=True, exist_ok=True)
        before_size = drift_log.stat().st_size if drift_log.exists() else 0
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: exempt(read-only-query)\n\n",
                tool_uses=[{"name": "Bash", "input": {"command": "cat /etc/passwd"}}],
            )
            rc, stdout, _ = _run_hook(tp)
            # observe mode: no block decision, but drift record appended
            assert '"decision":"block"' not in stdout.replace(" ", ""), \
                f"drift-log mode should NOT block L3 violations; stdout={stdout[:400]}"
            # drift log should have new record with kind=l3_integrity_violation
            if drift_log.exists():
                tail = drift_log.read_text()[before_size:]
                assert "l3_integrity_violation" in tail, \
                    f"drift log should record L3 violation; new content={tail[:400]!r}"
        finally:
            _restore_enforcement_mode(bak)

    # v43 R43 F1 regression: mode-i rescue MUST NOT rescue exempt gates.
    # Attack shape: earlier assistant with `Skill gate: exempt(read-only-query)`
    # + disallowed Bash (e.g., cat ~/.ssh/id_rsa), tool_result pseudo-user,
    # final assistant ungated. Without this fix:
    #   L1 rescue finds exempt earlier → passes L1
    #   L3 reads ungated final first_line → no exempt reason → skips validator
    #   → disallowed Bash bypasses L3 allowlist
    def test_block_mode_exempt_rescue_rejected_r43_f1(self, tmp_path):
        """Earlier exempt gate + disallowed Bash + tool_result + ungated final
        MUST BLOCK (rescue refuses exempt gates)."""
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(
                tmp_path,
                # final assistant text: no gate line
                "This run is done.",
                user_text="check things",
                prior_assistant_tool_uses=[
                    # First prior-assistant-in-turn has the exempt gate + Bash
                    # (We encode the gate text via a hack: include a text
                    # block via prior_assistant_tool_uses extension below)
                ],
            )
            # Manually overwrite transcript to add the exempt gate + Bash in
            # an earlier assistant entry, plus a tool_result pseudo-user,
            # plus the ungated final assistant (already written above).
            lines = tp.read_text().splitlines()
            # Expected order from helper: [user, ?prior_assistant+tool_result, final assistant]
            # Since prior_assistant_tool_uses=[] above, lines = [user, final_assistant].
            # Insert gated assistant + tool_result BEFORE final assistant.
            gated_assistant = json.dumps({
                "type": "assistant",
                "message": {"content": [
                    {"type": "text",
                     "text": "Skill gate: exempt(read-only-query)\n\nrunning"},
                    {"type": "tool_use", "id": "tu_bypass",
                     "name": "Bash",
                     "input": {"command": "cat /tmp/secret-evidence"}},
                ]},
            })
            tool_result_pseudo = json.dumps({
                "type": "user",
                "message": {"content": [
                    {"type": "tool_result", "tool_use_id": "tu_bypass",
                     "content": "stolen secret contents"}
                ]},
            })
            new_lines = [lines[0], gated_assistant, tool_result_pseudo, lines[1]]
            tp.write_text('\n'.join(new_lines) + '\n')
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' in stdout.replace(" ", ""), \
                f"Exempt rescue bypass must block; stdout={stdout[:400]}"
        finally:
            _restore_enforcement_mode(bak)

    # v34 R34 F1 regression: tool_result pseudo-user turn must NOT reset
    # the "current turn" — prior assistant tool_use still counts for L3.
    # Previously last_user_idx found the tool_result user turn → dropped
    # earlier assistant tool_use → read-only check passed despite side
    # effect already done in prior assistant entry.
    def test_read_only_tool_result_pseudo_turn_still_sees_prior_bash(self, tmp_path):
        """Transcript: [user, assistant with 'rm -rf /x' Bash, tool_result
        pseudo-user, final assistant gate] — the Bash tool_use MUST be
        detected and block read-only (side effect in the same turn)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(read-only-query)\n\n",
            user_text="do something read-only",
            prior_assistant_tool_uses=[
                {"name": "Bash", "input": {"command": "rm -rf /tmp/x"}, "id": "tu1"},
            ],
            tool_uses=[],  # final assistant has only text (the gate line)
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", ""), \
            f"tool_result pseudo-turn must not hide prior Bash side-effect; stdout={stdout[:400]}"


class TestL3ExemptIntegrityBehaviorNeutral:
    def test_behavior_neutral_with_doc_edit_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Write", "input": {"file_path": "docs/foo.md", "content": "x"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_behavior_neutral_with_commit_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "git commit -m 'x'"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    # v30 R30 F2 regression tests: spec §3.1 R11 F1 CRITICAL + R17 F1 CRITICAL
    # hardening — ALL .claude/state/ writes are blocked in behavior-neutral
    # (both .json like attest-ledger and .jsonl like override-log can forge
    # L5 evidence). Earlier spec carveout ".claude/state/*.jsonl" is removed
    # and these tests lock the hardened policy.
    def test_behavior_neutral_with_claude_state_jsonl_blocks(self, tmp_path):
        """R11 hardening: .claude/state/*.jsonl writes blocked — override-log
        forgery path must stay closed."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Write", "input": {
                "file_path": ".claude/state/attest-override-log.jsonl",
                "content": "forged entry",
            }}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_with_claude_state_json_blocks(self, tmp_path):
        """R11 hardening: .claude/state/attest-ledger.json writes blocked."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Write", "input": {
                "file_path": ".claude/state/attest-ledger.json",
                "content": '{"entries":{}}',
            }}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")

    def test_behavior_neutral_with_drift_jsonl_blocks(self, tmp_path):
        """R11 hardening: even seemingly-innocent drift-log writes are blocked —
        drift log must be hook-written, never response-written."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(behavior-neutral)\n\n",
            tool_uses=[{"name": "Write", "input": {
                "file_path": ".claude/state/skill-invoke-drift.jsonl",
                "content": '{"fake":"entry"}',
            }}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")


class TestL3ExemptIntegritySingleStep:
    def test_single_step_with_one_tool_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[{"name": "Bash", "input": {"command": "ls"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_single_step_with_three_tools_blocks(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\n",
            tool_uses=[
                {"name": "Bash", "input": {"command": "ls"}},
                {"name": "Read", "input": {"file_path": "/a"}},
                {"name": "Read", "input": {"file_path": "/b"}},
            ],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")


class TestL3ExemptIntegrityUserExplicitSkip:
    """v31 R31 F1 hardening: user-explicit-skip MUST carry auditable user
    authorization in the current-turn user message. Previously it was
    "trust user, no content check" which was an unrestricted L1 bypass —
    any Claude response could self-declare this reason and skip all
    L2/L4/L5 checks once block mode global."""

    def test_user_explicit_skip_without_auth_phrase_blocks(self, tmp_path):
        """No authorization phrase in user message → BLOCK."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            user_text="修一下这个 bug",  # no skip authorization
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")
        assert "user-explicit-skip" in stdout or "授权" in stdout

    def test_user_explicit_skip_with_en_skip_skill_passes(self, tmp_path):
        """'skip skill' in user message → pass."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            user_text="just run ls, skip skill for this one",
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_user_explicit_skip_with_zh_phrase_passes(self, tmp_path):
        """中文 '跳过 skill' → pass."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            user_text="直接跑 ls, 跳过 skill",
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_user_explicit_skip_with_slash_marker_passes(self, tmp_path):
        """'/no-skill' slash marker → pass."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            user_text="/no-skill ls",
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout

    def test_user_explicit_skip_no_user_message_blocks(self, tmp_path):
        """No user message at all → BLOCK (can't verify authorization)."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(user-explicit-skip)\n\n",
            # user_text omitted → transcript has only assistant entry
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' in stdout.replace(" ", "")
```

- [ ] **Step 3: 跑测试**

```bash
pytest tests/hooks/test_stop_response_check.py -v --tb=short 2>&1 | tail -30
```

Expected: 新增 10+ 测试通过。既有测试不 regression。

- [ ] **Step 4: commit**

```bash
git add tests/hooks/test_stop_response_check.py
git commit -m "hardening-6 Task 4: tests for stop-response-check L1 block + L3 integrity"
```

---

## Task 5: Create `skill-invoke-check.sh`

**Files:**
- Create: `.claude/hooks/skill-invoke-check.sh`

**背景**：Stop hook v2；读 first-line，若是 `Skill gate: <skill>`，查 config 做 L2/L4/L5 检查。

- [ ] **Step 1: 写 hook 脚本**

```bash
cat > .claude/hooks/skill-invoke-check.sh <<'HOOK_EOF'
#!/usr/bin/env bash
# skill-invoke-check.sh (hardening-6 v19 ζ)
# Stop hook: L2 invoke match + L4 mini-state + L5 codex evidence + unknown gate fail-closed
set -eo pipefail

# v19 R18 F1 fix: anchor all relative paths to project root regardless of cwd
# (Claude Code may invoke Stop hooks from any directory; paths must work reliably)
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT" || { echo "[skill-invoke-check] cannot cd to REPO_ROOT=$REPO_ROOT; fail-open" >&2; exit 0; }

CONFIG=".claude/config/skill-invoke-enforced.json"
RULES=".claude/workflow-rules.json"
STATE_DIR=".claude/state/skill-stage"
DRIFT_LOG=".claude/state/skill-invoke-drift.jsonl"
LEDGER=".claude/state/attest-ledger.json"
OVERRIDE_LOG=".claude/state/attest-override-log.jsonl"

# Fail-open ONLY for parse/infra errors; NOT for enforcement paths
# v8 R8 F2 fix: remove global ERR trap which could swallow pipefail errors
# in codex target computation; handle expected empty results explicitly with || true

input=$(cat)
tpath=$(echo "$input" | jq -r '.transcript_path // ""')
[ -z "$tpath" ] && exit 0
[ ! -f "$tpath" ] && exit 0
[ ! -f "$CONFIG" ] && exit 0

# Extract current-turn assistant: text (last) + tool_uses (aggregated across ALL
# assistant entries since last user entry) — v15 R14 F2 fix
TXT_AND_USES=$(python3 - "$tpath" <<'PY'
import json, sys
text = ""
tool_uses = []
entries = []
try:
    with open(sys.argv[1]) as f:
        for line in f:
            try:
                d = json.loads(line)
                if d.get('type') in ('user', 'assistant'):
                    entries.append(d)
            except Exception:
                continue
except Exception:
    pass
# v34 R34 F1 fix: distinguish HUMAN user prompt from tool_result pseudo-user
# (see stop-response-check.sh for full rationale — same bypass: tool_result
# turns between assistant tool_use and final assistant would drop earlier
# tool_uses → L2 invoke check + codex target derivation silently miss them).
def is_human_user_entry(e):
    if e.get('type') != 'user':
        return False
    content = e.get('message', {}).get('content', '')
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        has_tool_result = any(
            isinstance(c, dict) and c.get('type') == 'tool_result'
            for c in content
        )
        if has_tool_result:
            return False
        has_text = any(
            isinstance(c, dict) and c.get('type') in ('text', 'input-text')
            for c in content
        )
        return has_text or True
    return False

# Find last HUMAN user index; current turn = all assistant entries after it
last_user_idx = -1
for i, e in enumerate(entries):
    if is_human_user_entry(e):
        last_user_idx = i
# v36 R36 F1 fix: FIRST_LINE must cover mode-i flow (same-response announce
# + codex-attest run). Real transcripts after a tool_use have:
#   assistant N  : text("Skill gate:...") + tool_use
#   user N+1     : tool_result (pseudo-turn, not human)
#   assistant N+2: final text (MAY NOT repeat gate)
# Previous code took text from the LAST assistant only → final ungated →
# L1 blocks the legit codex gate flow. Fix: scan all assistant entries in
# the current turn; take FIRST_LINE from the first assistant that has a
# gate-shaped first line. Fall back to last assistant text if none.
import re
GATE_RE = re.compile(r'^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|exempt\([a-z-]+\))')  # v44 R44 F1 final: H6 scope only
gated_text = ""
last_text_any = ""
for e in entries[last_user_idx + 1:]:
    if e.get('type') == 'assistant':
        content = e.get('message', {}).get('content', [])
        if isinstance(content, list):
            text_this_entry = ""
            for c in content:
                if isinstance(c, dict):
                    if c.get('type') == 'text':
                        text_this_entry = c.get('text', '')
                    elif c.get('type') == 'tool_use':
                        tool_uses.append({'name': c.get('name'), 'input': c.get('input', {})})
            if text_this_entry:
                last_text_any = text_this_entry
                # First gate-matching text wins
                if not gated_text and GATE_RE.match(text_this_entry.splitlines()[0] if text_this_entry else ""):
                    gated_text = text_this_entry
text = gated_text or last_text_any
print(json.dumps({'text': text, 'tool_uses': tool_uses}))
PY
)
LAST_TEXT=$(echo "$TXT_AND_USES" | jq -r '.text')
[ -z "$LAST_TEXT" ] && exit 0

FIRST_LINE=$(echo "$LAST_TEXT" | head -1)
GATE_RE='^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|exempt\([a-z-]+\))'  # v44 R44 F1 final: H6 scope only
if ! echo "$FIRST_LINE" | grep -qE "$GATE_RE"; then
  exit 0  # existing stop-response-check.sh handles missing first-line
fi

# Extract skill-name (not exempt)
if echo "$FIRST_LINE" | grep -qE '^Skill gate: exempt\('; then
  exit 0  # exempt handled by stop-response-check.sh
fi
SKILL_NAME=$(echo "$FIRST_LINE" | sed -E 's/^Skill gate: (.*)/\1/')

# Session start (v4 R3 F3 fix: ULID first, env fallback - aligns with spec §3.4)
SESSION_START_UTC=""
if [ -n "$CLAUDE_SESSION_ID" ]; then
  # Primary: ULID timestamp decode (first 10 chars base32 → ms since epoch)
  SESSION_START_UTC=$(python3 -c "
import sys
try:
    s = '$CLAUDE_SESSION_ID'[:10].upper()
    alph = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
    n = 0
    for c in s:
        n = n*32 + alph.index(c)
    import datetime
    print(datetime.datetime.utcfromtimestamp(n/1000).strftime('%Y-%m-%dT%H:%M:%SZ'))
except Exception:
    pass
" 2>/dev/null)
fi
# Fallback: env var (only if ULID failed/absent)
if [ -z "$SESSION_START_UTC" ]; then
  SESSION_START_UTC="${CLAUDE_SESSION_START_UTC:-}"
fi
SESSION_UNKNOWN=0
[ -z "$SESSION_START_UTC" ] && SESSION_UNKNOWN=1

ENF_MODE=$(jq -r '.skill_gate_policy.enforcement_mode // "drift-log"' "$RULES" 2>/dev/null)

block() {
  jq -nc --arg r "$1" '{decision: "block", reason: $r}'
  exit 0
}

drift_log() {
  # $1 = drift_kind; $2 = invoked; $3 = exempt_matched; $4 = last_stage_before
  # $5 = blocked (v27 R26 F3 fix; default inferred from BLOCK_MODE_PENDING env)
  # R11 F2 fix: mkdir -p parent dir (fresh checkout may not have .claude/state/)
  local kind="$1"
  local invoked="${2:-false}"
  local exempt_matched="${3:-null}"
  local last_stage_before="${4:-null}"
  # v27 R26 F3: blocked reflects whether this drift_log call precedes a block()
  # Passed explicitly by caller (default false if not passed)
  local blocked="${5:-false}"
  local rsha=$(printf '%s' "$LAST_TEXT" | shasum -a 256 | awk '{print $1}')
  mkdir -p "$(dirname "$DRIFT_LOG")" 2>/dev/null || true
  python3 - "$DRIFT_LOG" "$kind" "$SKILL_NAME" "$invoked" "$exempt_matched" "$last_stage_before" "$rsha" "${CLAUDE_SESSION_ID:-unknown}" "$blocked" <<'PY'
import json, sys, time, os
p, kind, skill, invoked, exempt_m, last_stage, rsha, sid, blocked = sys.argv[1:10]
entry = {
    'time_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'session_id': sid,
    'response_sha': f'sha256:{rsha}',
    'gate_skill': skill,
    'config_mode': os.environ.get('CONFIG_MODE', 'unknown'),
    'invoked': invoked == 'true',
    'exempt_rule_matched': None if exempt_m == 'null' else exempt_m,
    'last_stage_before': None if last_stage == 'null' else last_stage,
    'drift_kind': kind,
    'blocked': blocked == 'true',
}
# Ensure parent dir exists (fresh checkout fix R11 F2)
os.makedirs(os.path.dirname(p) or '.', exist_ok=True)
with open(p, 'a') as f:
    f.write(json.dumps(entry) + '\n')
PY
}

# v27 R26 F3 fix: helper that calls drift_log with blocked=true then block()
drift_log_and_block() {
  # Usage: drift_log_and_block <drift_kind> <reason>
  drift_log "$1" "false" "null" "$LAST_STAGE" "true"
  block "$2"
}

# v44 R44 F1 HIGH final fix: unknown-gate fail-closed in block mode.
# Previous v38 plugin-format-invoke-match passthrough was durable bypass:
# agent could declare `Skill gate: frontend-design:web` + invoke
# frontend-design, skipping required H6 transitions (brainstorming →
# writing-plans → codex:adversarial-review). Codex R44 final verdict:
# scope L1 + L2 to H6 only. Non-H6 users either:
# 1. Use superpowers:* gate + call plugin as Skill sub-invoke (normal H6 flow)
# 2. Explicitly register plugin gate in skill-invoke-enforced.json

# Look up config
IN_CONFIG=$(jq -r --arg s "$SKILL_NAME" '.enforce[$s] // empty' "$CONFIG")
if [ -z "$IN_CONFIG" ]; then
  # Unknown gate: fail-closed in block mode (no plugin-format passthrough).
  if [ "$ENF_MODE" = "block" ] && [ "${ALLOW_UNKNOWN_GATE:-0}" != "1" ]; then
    drift_log "unknown_skill_in_gate"
    block "Skill gate '$SKILL_NAME' 未在 skill-invoke-enforced.json 配置；block mode fail-closed。非-H6 plugin 请：(1) 用 superpowers:* gate 把该 plugin 当 Skill sub-invoke 调用，或 (2) 注册 plugin gate 到 config"
  fi
  drift_log "unknown_skill_in_gate"
  exit 0
fi

CONFIG_MODE=$(echo "$IN_CONFIG" | jq -r '.mode')
EXEMPT_RULE=$(echo "$IN_CONFIG" | jq -r '.exempt_rule // ""')
export CONFIG_MODE

# Load mini-state
WT_HASH8=$(printf '%s' "$PWD" | shasum -a 256 | awk '{print $1}' | cut -c1-8)
# v27 R26 F1 fix: SHA256 hash of FULL CLAUDE_SESSION_ID (not :0:8 prefix which
# is ULID timestamp data, collides across sessions in same time bucket).
# v28 R27 F1 fix: in block mode, fail-closed when CLAUDE_SESSION_ID absent
# (PPID+epoch fallback creates new state file per invocation → LAST_STAGE
# resets to _initial → L4 mini-state silently bypassed). In observe mode,
# retain pid+time fallback for drift telemetry continuity.
if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
  SID_HASH=$(printf '%s' "$CLAUDE_SESSION_ID" | shasum -a 256 | awk '{print $1}' | cut -c1-8)
else
  if [ "$CONFIG_MODE" = "block" ]; then
    drift_log "session_id_absent_l4_fail_closed" false null "_initial"
    block "CLAUDE_SESSION_ID 不可读; block mode L4 fail-closed（PPID+time fallback 会每次重置 last_stage=_initial，等效绕过 mini-state）；export CLAUDE_SESSION_ID 或降级 observe mode"
  fi
  # observe mode only: per-process unique fallback (drift telemetry continuity)
  SID_HASH=$(printf 'noSess-%s-%s' "$PPID" "$(date +%s)" | shasum -a 256 | awk '{print $1}' | cut -c1-8)
fi
STATE_FILE="$STATE_DIR/${WT_HASH8}-${SID_HASH}.json"
LAST_STAGE="_initial"
if [ -f "$STATE_FILE" ]; then
  LAST_STAGE=$(jq -r '.last_stage // "_initial"' "$STATE_FILE" 2>/dev/null || echo "_initial")
fi

# Special path for codex:adversarial-review (L5)
if [ "$SKILL_NAME" = "codex:adversarial-review" ]; then
  # Compute target (v4 R3 F2 fix: explicit from response; block on ambiguity)
  TARGET=""
  case "$LAST_STAGE" in
    "superpowers:brainstorming"|"superpowers:writing-plans")
      # v29 R29 F1 fix: resolve each Write/Edit path to absolute, require
      # relative_to(repo_root) inside repo, THEN match docs/superpowers/(specs|plans)/.
      # v33 R33 F1 fix: pass TXT_AND_USES via env var, NOT stdin pipe.
      # Previous `echo "$TXT_AND_USES" | python3 - "$PWD" <<'PY'` had
      # conflicting stdin: `python3 -` reads SCRIPT from stdin, AND heredoc
      # also occupies stdin → heredoc wins → python ran the script but
      # sys.stdin.read() then returned empty / the script text itself,
      # so json.loads always failed silently → CANDIDATES always empty →
      # codex gate after valid spec/plan edit would block with no_target.
      CANDIDATES=$(TXT_AND_USES_JSON="$TXT_AND_USES" python3 - "$PWD" <<'PY' 2>/dev/null || true
import json, os, sys, re
from pathlib import Path
pwd = Path(sys.argv[1]).resolve()
spec_plan_re = re.compile(r'^docs/superpowers/(specs|plans)/.+\.md$')
seen = set()
try:
    data = json.loads(os.environ.get('TXT_AND_USES_JSON', ''))
except Exception:
    sys.exit(0)
for tu in data.get('tool_uses', []):
    if tu.get('name') not in ('Write', 'Edit', 'NotebookEdit', 'MultiEdit'):
        continue
    fp = tu.get('input', {}).get('file_path', '')
    if not fp:
        continue
    try:
        fp_abs = (pwd / fp).resolve() if not Path(fp).is_absolute() else Path(fp).resolve()
        rel = fp_abs.relative_to(pwd)
    except (ValueError, OSError):
        continue
    rel_str = str(rel).replace('\\', '/')
    if spec_plan_re.match(rel_str) and rel_str not in seen:
        seen.add(rel_str)
        print(rel_str)
PY
)
      CAND_COUNT=$(echo "$CANDIDATES" | grep -cv '^$' 2>/dev/null || echo 0)
      if [ "$CAND_COUNT" = "1" ]; then
        RECENT_FILE="$CANDIDATES"
        TARGET="file:$RECENT_FILE"
      elif [ "$CAND_COUNT" -gt 1 ]; then
        drift_log "codex_gate_ambiguous_target"
        [ "$CONFIG_MODE" = "block" ] && block "codex:adversarial-review target 模糊（last_stage=$LAST_STAGE, 候选 $CAND_COUNT 个）；请响应内显式编辑/写入单一 spec/plan 文件，或设置 env TARGET"
        exit 0
      fi
      # v18 R17 F3 HIGH + v26 R25 F1 + v28 R27 F2 fix:
      # When no explicit tool_use (e.g., codex run-only response), ONLY
      # fall back to mini-state recorded artifact with blob consistency check.
      # v28 R27 F2: REMOVED `git log -1 --name-only` fallback — that committed
      # file's blob may not match CURRENT file blob if user has uncommitted
      # edits; binding to committed blob silently approves stale content.
      # mini-state records path+blob at brainstorming/writing-plans time and
      # is compared to CURRENT git hash-object output, so blob mismatch →
      # explicit refresh required.
      if [ "$CAND_COUNT" = "0" ] && [ -f "$STATE_FILE" ]; then
        RECENT_ART=$(jq -r '.recent_artifact_path // ""' "$STATE_FILE" 2>/dev/null)
        RECENT_BLOB=$(jq -r '.recent_artifact_blob // ""' "$STATE_FILE" 2>/dev/null)
        if [ -n "$RECENT_ART" ] && [ -f "$RECENT_ART" ]; then
          # v26 R25 F1: verify current file blob matches stored blob
          # If file was modified after state recorded, state is stale →
          # require explicit current Write/Edit tool_use or state refresh
          CUR_BLOB_OF_ART=$(git hash-object "$RECENT_ART" 2>/dev/null)
          if [ -n "$RECENT_BLOB" ] && [ "$CUR_BLOB_OF_ART" = "$RECENT_BLOB" ]; then
            TARGET="file:$RECENT_ART"
            CAND_COUNT=1
          else
            drift_log "codex_gate_stale_artifact_target"
            [ "$CONFIG_MODE" = "block" ] && block "codex:adversarial-review: state recorded blob ($RECENT_BLOB) != current ($CUR_BLOB_OF_ART) for $RECENT_ART; 需响应内显式 Write/Edit spec/plan 或重新触发 brainstorming/writing-plans 刷新 state"
            exit 0
          fi
        fi
      fi
      # CAND_COUNT == 0 AND no state artifact → TARGET stays empty, falls through
      ;;
    "superpowers:subagent-driven-development"|"superpowers:requesting-code-review"|"superpowers:finishing-a-development-branch")
      HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
      CUR_BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      [ -n "$HEAD_SHA" ] && TARGET="branch:${CUR_BR}@${HEAD_SHA}"
      ;;
    "_initial")
      # Allow without target at session start
      TARGET="_initial"
      ;;
  esac

  if [ -z "$TARGET" ]; then
    if [ "$CONFIG_MODE" = "block" ] && [ "${ALLOW_EMPTY_CODEX_TARGET:-0}" != "1" ]; then
      drift_log "codex_gate_no_target"
      block "codex:adversarial-review target 为空（last_stage=$LAST_STAGE）; block mode fail-closed"
    fi
    drift_log "codex_gate_no_target"
    exit 0
  fi

  # Session unknown handling
  if [ "$SESSION_UNKNOWN" = "1" ]; then
    drift_log "session_start_unknown"
    if [ "$CONFIG_MODE" = "block" ]; then
      block "session_start 不可确定; block mode L5 fail-closed (export CLAUDE_SESSION_START_UTC 或确保 CLAUDE_SESSION_ID 可读)"
    fi
    exit 0
  fi

  # Path A: ledger
  EVIDENCE_PASS=0
  if [ "$TARGET" = "_initial" ]; then
    EVIDENCE_PASS=1
  elif [ -f "$LEDGER" ]; then
    ENTRY=$(jq -c --arg k "$TARGET" '.entries[$k] // .[$k] // empty' "$LEDGER" 2>/dev/null)
    if [ -n "$ENTRY" ]; then
      ATTEST_TIME=$(echo "$ENTRY" | jq -r '.attest_time_utc // ""')
      VDIGEST=$(echo "$ENTRY" | jq -r '.verdict_digest // ""')
      if [ -n "$ATTEST_TIME" ] && [ -n "$VDIGEST" ] && [[ "$ATTEST_TIME" > "$SESSION_START_UTC" ]]; then
        # Revision bind for file target
        if [[ "$TARGET" =~ ^file: ]]; then
          FILE_PATH="${TARGET#file:}"
          if [ -f "$FILE_PATH" ]; then
            CUR_BLOB=$(git hash-object "$FILE_PATH" 2>/dev/null)
            LEDGER_BLOB=$(echo "$ENTRY" | jq -r '.blob_sha // .blob // ""')
            if [ -n "$CUR_BLOB" ] && [ "$CUR_BLOB" = "$LEDGER_BLOB" ]; then
              EVIDENCE_PASS=1
            fi
          fi
        elif [[ "$TARGET" =~ ^branch: ]]; then
          # v14 R13 F1 fix: branch target 也必须 payload SHA match (不止 key match)
          BR_SHA_FROM_TARGET="${TARGET##*@}"
          ENTRY_HEAD_SHA=$(echo "$ENTRY" | jq -r '.head_sha // .blob_or_head_sha // .head_sha_for_patch // ""')
          if [ -n "$BR_SHA_FROM_TARGET" ] && [ "$BR_SHA_FROM_TARGET" = "$ENTRY_HEAD_SHA" ]; then
            EVIDENCE_PASS=1
          fi
        else
          # Unknown target kind (shouldn't reach here but fail-closed)
          :
        fi
      fi
    fi
  fi

  # Path B: ledger override entry (v18 R17 F1 CRITICAL fix)
  # Raw override-log jsonl line is NOT sufficient (can be forged with Write).
  # Require keyed ledger entry with override:true field AND matching audit_log_line
  # reference, then cross-verify the audit log line matches the ledger entry.
  if [ "$EVIDENCE_PASS" = "0" ] && [ -f "$LEDGER" ]; then
    OV_ENTRY=$(jq -c --arg k "$TARGET" '.entries[$k] // .[$k] // empty' "$LEDGER" 2>/dev/null)
    if [ -n "$OV_ENTRY" ]; then
      IS_OVERRIDE=$(echo "$OV_ENTRY" | jq -r '.override // false')
      OV_TIME=$(echo "$OV_ENTRY" | jq -r '.override_time_utc // .attest_time_utc // ""')
      AUDIT_LINE=$(echo "$OV_ENTRY" | jq -r '.audit_log_line // ""')
      if [ "$IS_OVERRIDE" = "true" ] && [[ "$OV_TIME" > "$SESSION_START_UTC" ]] && [ -n "$AUDIT_LINE" ]; then
        # Cross-verify: audit log line N in override-log.jsonl must reference same target
        if [ -f "$OVERRIDE_LOG" ]; then
          AUDIT_CONTENT=$(sed -n "${AUDIT_LINE}p" "$OVERRIDE_LOG" 2>/dev/null)
          if [ -n "$AUDIT_CONTENT" ]; then
            AUDIT_TARGET=$(echo "$AUDIT_CONTENT" | jq -r '.target // ""')
            AUDIT_KIND=$(echo "$AUDIT_CONTENT" | jq -r '.kind // ""')
            # Match target path/branch + kind + revision
            if [[ "$TARGET" =~ ^file: ]] && [ "$AUDIT_KIND" = "file" ] && [ "$AUDIT_TARGET" = "${TARGET#file:}" ]; then
              FILE_PATH="${TARGET#file:}"
              CUR_BLOB=$(git hash-object "$FILE_PATH" 2>/dev/null)
              AUDIT_BLOB=$(echo "$AUDIT_CONTENT" | jq -r '.blob_or_head_sha // ""')
              [ "$CUR_BLOB" = "$AUDIT_BLOB" ] && EVIDENCE_PASS=1
            elif [[ "$TARGET" =~ ^branch: ]] && [ "$AUDIT_KIND" = "branch" ]; then
              BR_NAME=$(echo "$TARGET" | sed -E 's/branch:([^@]+)@.*/\1/')
              BR_SHA="${TARGET##*@}"
              AUDIT_BR_SHA=$(echo "$AUDIT_CONTENT" | jq -r '.blob_or_head_sha // ""')
              [ "$AUDIT_TARGET" = "$BR_NAME" ] && [ "$AUDIT_BR_SHA" = "$BR_SHA" ] && EVIDENCE_PASS=1
            fi
          fi
        fi
      fi
    fi
  fi

  if [ "$EVIDENCE_PASS" = "0" ]; then
    drift_log "codex_gate_no_evidence" false null "$LAST_STAGE"
    if [ "$CONFIG_MODE" = "block" ]; then
      block "codex:adversarial-review 无 target-bound 有效证据 (target=$TARGET); 需跑 codex-attest.sh or attest-override.sh"
    fi
    exit 0
  fi

  # L5 pass → L4 mini-state update
  SKIP_L2=1  # skip Skill invoke match (codex unique)
else
  SKIP_L2=0
fi

# L2: Skill invoke match (v4: exact canonical match only, no short-name alias)
# R3 F1 fix: reject `brainstorming` invoke when gate is `superpowers:brainstorming`
# (or vice versa); require .input.skill == $SKILL_NAME exactly as configured
if [ "$SKIP_L2" = "0" ]; then
  INVOKED=$(echo "$TXT_AND_USES" | jq -r --arg s "$SKILL_NAME" '
    .tool_uses[] 
    | select(.name == "Skill") 
    | select(.input.skill == $s) 
    | "true"
  ' | head -1)

  if [ "$INVOKED" != "true" ]; then
    # Check exempt_rule
    EXEMPT_MATCHED=""
    case "$EXEMPT_RULE" in
      "plan-doc-spec-frozen-note")
        echo "$LAST_TEXT" | grep -qE 'brainstorming skipped.*spec.*frozen' && EXEMPT_MATCHED="$EXEMPT_RULE"
        ;;
      "plan-start-in-worktree")
        if echo "$TXT_AND_USES" | jq -r '.tool_uses[] | select(.name=="Bash") | .input.command' | grep -qE 'git worktree add'; then
          EXEMPT_MATCHED="$EXEMPT_RULE"
        elif [[ "$PWD" == */\.worktrees/* ]]; then
          EXEMPT_MATCHED="$EXEMPT_RULE"
        fi
        ;;
    esac

    if [ -z "$EXEMPT_MATCHED" ]; then
      drift_log "gate_declared_no_invoke" false null "$LAST_STAGE"
      if [ "$CONFIG_MODE" = "block" ]; then
        block "Skill gate '$SKILL_NAME' 声明但响应未 Skill tool invoke; 且 exempt_rule ($EXEMPT_RULE) 不匹配"
      fi
      exit 0
    fi
  fi
fi

# L4 mini-state check
# wildcard
WILDCARD=$(jq -r --arg s "$SKILL_NAME" '.mini_state.wildcard_always_allowed[] | select(. == $s)' "$CONFIG")
if [ -n "$WILDCARD" ]; then
  # v25 R24 F2 fix: distinguish between "state-less wildcards" and
  # "wildcards WITH legal_next_set entry":
  # - state-less (using-superpowers, dispatching-parallel-agents):
  #   pass without state update (no entry means no meaningful "next")
  # - has legal_next_set entry (systematic-debugging):
  #   wildcard-entry is allowed from any last_stage, BUT state MUST
  #   update to this skill so subsequent transitions check its
  #   legal_next_set (e.g., systematic-debugging -> test/verification)
  HAS_LNS=$(jq -r --arg s "$SKILL_NAME" '.mini_state.legal_next_set[$s] // empty' "$CONFIG")
  if [ -z "$HAS_LNS" ]; then
    # State-less wildcard: pass, no state update
    exit 0
  fi
  # Wildcard with legal_next_set: fall through to state update block below
else
  # legal_next_set check
  LEGAL=$(jq -r --arg k "$LAST_STAGE" --arg s "$SKILL_NAME" '
    .mini_state.legal_next_set[$k][]? | select(. == $s)
  ' "$CONFIG" | head -1)
  if [ -z "$LEGAL" ]; then
    drift_log "illegal_transition" true null "$LAST_STAGE"
    if [ "$CONFIG_MODE" = "block" ]; then
      LEGAL_SET=$(jq -r --arg k "$LAST_STAGE" '.mini_state.legal_next_set[$k][]? // empty' "$CONFIG" | tr '\n' ',' | sed 's/,$//')
      block "非法 transition: last_stage=$LAST_STAGE, current=$SKILL_NAME; expected: {$LEGAL_SET}"
    fi
    exit 0
  fi
fi

# Atomic update last_stage
mkdir -p "$STATE_DIR"
# v28 R27 F3 fix: mktemp inside $STATE_DIR guarantees same-filesystem rename
# (default mktemp uses $TMPDIR or /tmp, which on Linux tmpfs is a different
# filesystem → mv becomes copy+unlink, not atomic; concurrent reader can
# observe partial write). Same-FS mv is rename(2) = atomic.
TMP=$(mktemp "$STATE_DIR/.tmp.XXXXXX")
python3 - "$STATE_FILE" "$TMP" "$SKILL_NAME" "$PWD" "${CLAUDE_SESSION_ID:-}" "$TXT_AND_USES" <<'PY'
import json, sys, time, os, subprocess
sf, tmp, skill, pwd, sid, txt_uses_json = sys.argv[1:7]
history = []
recent_artifact = ""
recent_artifact_blob = ""
if os.path.exists(sf):
    try:
        d = json.load(open(sf))
        history = d.get('transition_history', [])
        recent_artifact = d.get('recent_artifact_path', '')
        recent_artifact_blob = d.get('recent_artifact_blob', '')
    except Exception:
        pass
history.append({'stage': skill, 'time': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})

# v18 R17 F3 fix: if brainstorming/writing-plans writes a spec/plan, record path+blob
# so next codex run-only response can recover target from state
# v29 R29 F1 fix: resolve path to absolute, require relative_to(repo_root) inside
# repo before accepting. Previous lstrip('/') converted /tmp/docs/superpowers/...
# → tmp/docs/superpowers/... which still contained docs/superpowers/ substring
# in some regex variants, or more broadly bound state to out-of-repo files.
if skill in ('superpowers:brainstorming', 'superpowers:writing-plans'):
    try:
        tu_data = json.loads(txt_uses_json)
        import re
        from pathlib import Path
        pwd_real = Path(pwd).resolve()
        spec_plan_re = re.compile(r'^docs/superpowers/(specs|plans)/.+\.md$')
        for tu in tu_data.get('tool_uses', []):
            if tu.get('name') in ('Write', 'Edit', 'MultiEdit', 'NotebookEdit'):
                fp = tu.get('input', {}).get('file_path', '')
                if not fp:
                    continue
                try:
                    fp_abs = (pwd_real / fp).resolve() if not Path(fp).is_absolute() else Path(fp).resolve()
                    rel = fp_abs.relative_to(pwd_real)
                except (ValueError, OSError):
                    continue  # out-of-repo / unresolvable → skip
                rel_str = str(rel).replace('\\', '/')
                if spec_plan_re.match(rel_str):
                    recent_artifact = rel_str
                    try:
                        recent_artifact_blob = subprocess.check_output(
                            ['git', 'hash-object', rel_str], text=True, stderr=subprocess.DEVNULL
                        ).strip()
                    except Exception:
                        recent_artifact_blob = ''
                    break
    except Exception:
        pass

state = {
    'version': '1',
    'last_stage': skill,
    'last_stage_time_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'worktree_path': pwd,
    'session_id': sid,
    'drift_count': 0,
    'transition_history': history[-50:],
    'recent_artifact_path': recent_artifact,
    'recent_artifact_blob': recent_artifact_blob,
}
json.dump(state, open(tmp, 'w'), indent=2)
PY
mv "$TMP" "$STATE_FILE"

# Reset triggers (v9 per config.mini_state.reset_triggers)
# 1. new_worktree: git worktree add detected in this response
# 2. finishing_branch_pushed: git push + gh pr create/merge detected
# Note: session_switch is implicit (new session_id → new state file)
BASH_CMDS=$(echo "$TXT_AND_USES" | jq -r '.tool_uses[] | select(.name=="Bash") | .input.command' 2>/dev/null || echo "")
RESET=0
if echo "$BASH_CMDS" | grep -qE 'git worktree add'; then
  RESET=1
elif echo "$BASH_CMDS" | grep -qE 'git push' && echo "$BASH_CMDS" | grep -qE 'gh pr (create|merge)'; then
  RESET=1
fi
if [ "$RESET" = "1" ]; then
  # Reset last_stage to _initial for NEXT invocation (current response already updated state above)
  python3 - "$STATE_FILE" <<'PY'
import json, sys, time
sf = sys.argv[1]
try:
    d = json.load(open(sf))
    d['last_stage'] = '_initial'
    d['last_stage_time_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    d.setdefault('transition_history', []).append({'stage': '_initial', 'time': d['last_stage_time_utc'], 'reason': 'reset_trigger'})
    json.dump(d, open(sf, 'w'), indent=2)
except Exception:
    pass
PY
fi

exit 0
HOOK_EOF
chmod +x .claude/hooks/skill-invoke-check.sh
```

- [ ] **Step 2: 手工测试基本流程**

```bash
cat > /tmp/h6_test_transcript.jsonl <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Skill gate: superpowers:brainstorming\n\nStarting brainstorming"},{"type":"tool_use","name":"Skill","input":{"skill":"superpowers:brainstorming"}}]}}
EOF
echo '{"transcript_path":"/tmp/h6_test_transcript.jsonl"}' | .claude/hooks/skill-invoke-check.sh
echo "exit=$?"
```

Expected: exit 0（声明 + invoke 匹配，observe mode）

- [ ] **Step 3: commit**

```bash
git add .claude/hooks/skill-invoke-check.sh
git commit -m "hardening-6 Task 5: skill-invoke-check.sh L2 invoke + L4 state + L5 codex evidence"
```

---

## Task 6: Tests for `skill-invoke-check.sh`

**Files:**
- Create: `tests/hooks/test_skill_invoke_check.py`

- [ ] **Step 1: 写测试文件**

```python
"""Hardening-6 skill-invoke-check.sh unit tests (ζ v9)."""
import json
import os
import shutil
import subprocess
import tempfile
import pytest
from pathlib import Path

HOOK = ".claude/hooks/skill-invoke-check.sh"

def _run_hook(transcript_path, env_extra=None):
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        ["bash", HOOK],
        input=json.dumps({"transcript_path": str(transcript_path)}),
        capture_output=True, text=True, timeout=15, env=env,
    )
    return proc.returncode, proc.stdout, proc.stderr

def _write_transcript(tmp_path, assistant_text, tool_uses=None):
    content = [{"type": "text", "text": assistant_text}]
    if tool_uses:
        for tu in tool_uses:
            content.append({"type": "tool_use", "name": tu["name"], "input": tu["input"]})
    entry = {"type": "assistant", "message": {"content": content}}
    tp = tmp_path / "t.jsonl"
    tp.write_text(json.dumps(entry) + "\n")
    return tp

def _set_mode(skill, mode):
    p = Path(".claude/config/skill-invoke-enforced.json")
    bak = str(p) + ".bak"
    shutil.copy(p, bak)
    d = json.loads(p.read_text())
    if skill in d["enforce"]:
        d["enforce"][skill]["mode"] = mode
    p.write_text(json.dumps(d, indent=2))
    return bak

def _restore(bak):
    shutil.move(bak, bak[:-4])

# v36 R36 F2 fix: local helpers for workflow-rules.json enforcement_mode
# mutation (needed by TestL1RegexTightening). Previously these were
# referenced-but-not-defined → NameError at pytest collection.
def _set_enforcement_mode(mode):
    p = Path(".claude/workflow-rules.json")
    bak = str(p) + ".enf.bak"
    shutil.copy(p, bak)
    d = json.loads(p.read_text())
    d["skill_gate_policy"]["enforcement_mode"] = mode
    p.write_text(json.dumps(d, indent=2))
    return bak

def _restore_enforcement_mode(bak):
    import pathlib
    shutil.move(bak, bak[:-len(".enf.bak")])


class TestL2InvokeMatch:
    def test_valid_invoke_passes(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_missing_invoke_observe_drift(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Read", "input": {"file_path": "/a"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        # observe mode default → no block
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_missing_invoke_block_blocks(self, tmp_path):
        bak = _set_mode("superpowers:brainstorming", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:brainstorming\n\nx",
                tool_uses=[{"name": "Read", "input": {"file_path": "/a"}}],
            )
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            _restore(bak)


class TestUnknownGate:
    def test_unknown_skill_drift_pass(self, tmp_path):
        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:typo-skill\n\nx",
            tool_uses=[],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_unknown_skill_block_mode_blocks(self, tmp_path):
        # We can't flip enforcement_mode globally here; test via config key absent
        # But block mode is global via workflow-rules.json, not per skill
        # For this test we simulate via env ALLOW_UNKNOWN_GATE=0 default + forcing block via mode
        # Actually unknown gate block depends on ENF_MODE=block globally
        import json as _j
        rules_p = Path(".claude/workflow-rules.json")
        bak = str(rules_p) + ".bak"
        shutil.copy(rules_p, bak)
        try:
            d = _j.loads(rules_p.read_text())
            d["skill_gate_policy"]["enforcement_mode"] = "block"
            rules_p.write_text(_j.dumps(d, indent=2))
            tp = _write_transcript(tmp_path, "Skill gate: superpowers:typo-skill\n\nx")
            rc, stdout, _ = _run_hook(tp)
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            shutil.move(bak, str(rules_p))

    def test_unknown_skill_allow_flag_pass(self, tmp_path):
        import json as _j
        rules_p = Path(".claude/workflow-rules.json")
        bak = str(rules_p) + ".bak"
        shutil.copy(rules_p, bak)
        try:
            d = _j.loads(rules_p.read_text())
            d["skill_gate_policy"]["enforcement_mode"] = "block"
            rules_p.write_text(_j.dumps(d, indent=2))
            tp = _write_transcript(tmp_path, "Skill gate: superpowers:typo-skill\n\nx")
            rc, stdout, _ = _run_hook(tp, env_extra={"ALLOW_UNKNOWN_GATE": "1"})
            assert '"decision":"block"' not in stdout.replace(" ", "")
        finally:
            shutil.move(bak, str(rules_p))


class TestMiniStateTransition:
    def _reset_state(self):
        import hashlib
        p = Path(".claude/state/skill-stage")
        for f in p.glob("*.json"):
            f.unlink()

    def test_initial_to_brainstorming_passes(self, tmp_path):
        self._reset_state()
        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_illegal_transition_observe(self, tmp_path):
        """brainstorming → test-driven-development is NOT legal."""
        self._reset_state()
        # Step 1: establish last_stage=brainstorming via first call
        tp1 = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
        )
        _run_hook(tp1)
        # Step 2: illegal jump
        tp2 = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:test-driven-development\n\ny",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:test-driven-development"}}],
        )
        rc, stdout, _ = _run_hook(tp2)
        # observe mode → drift-log only; no block
        assert '"decision":"block"' not in stdout.replace(" ", "")

    def test_illegal_transition_block(self, tmp_path):
        self._reset_state()
        bak = _set_mode("superpowers:test-driven-development", "block")
        try:
            tp1 = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:brainstorming\n\nx",
                tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
            )
            _run_hook(tp1)
            tp2 = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:test-driven-development\n\ny",
                tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:test-driven-development"}}],
            )
            rc, stdout, _ = _run_hook(tp2)
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            _restore(bak)


class TestL5CodexGate:
    """L5 codex evidence gate tests with real fixtures (plan R2 F1 fix).
    
    Each test establishes last_stage != _initial (so target computes to a file:
    or branch: path) and sets ledger / override-log content to drive specific
    pass/block outcomes.
    """

    # v28 R28 F2 fix: deterministic session ID + SHA256 hash matching the hook
    # v27 R26 F1 changed hook to hash FULL CLAUDE_SESSION_ID via SHA256[:8];
    # test fixture previously used CLAUDE_SESSION_ID[:8] → hook and fixture
    # wrote/read different filenames → L5 evidence tests silently exercised
    # _initial path, not the intended brainstorming/plan path. All block-mode
    # tests MUST pass DETERMINISTIC_SESSION_ID via env; fixture hashes it
    # identically to the hook.
    DETERMINISTIC_SESSION_ID = "01HQTESTAAAAAAAAAAAAAAAAAA"  # ULID-shaped, 26 chars

    def _sid_hash8(self, session_id=None):
        import hashlib
        sid = session_id or os.environ.get("CLAUDE_SESSION_ID") or self.DETERMINISTIC_SESSION_ID
        return hashlib.sha256(sid.encode()).hexdigest()[:8]

    def _setup_brainstorming_stage(self, spec_file, session_id=None):
        """Force state to last_stage=superpowers:brainstorming with file target
        pointing at spec_file. Uses state filename identical to the hook's
        SHA256-based scheme (v27 R26 F1).
        """
        import hashlib
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = self._sid_hash8(session_id)
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        state = {
            "version": "1",
            "last_stage": "superpowers:brainstorming",
            "last_stage_time_utc": "2026-04-22T00:00:00Z",
            "worktree_path": os.getcwd(),
            "session_id": session_id or os.environ.get("CLAUDE_SESSION_ID") or self.DETERMINISTIC_SESSION_ID,
            "drift_count": 0,
            "transition_history": [],
        }
        sf.write_text(json.dumps(state))
        return sf

    def _write_ledger_entry(self, key, blob_sha, attest_time="2026-04-22T09:00:00Z"):
        """Write a mock approve entry to attest-ledger.json."""
        ledger_p = Path(".claude/state/attest-ledger.json")
        bak = str(ledger_p) + ".testbak"
        if ledger_p.exists():
            shutil.copy(ledger_p, bak)
            ledger = json.loads(ledger_p.read_text())
        else:
            ledger = {}
            bak = None
        ledger[key] = {
            "attest_time_utc": attest_time,
            "verdict_digest": "sha256:testdigest",
            "blob_sha": blob_sha,
            "round": 1,
        }
        ledger_p.parent.mkdir(parents=True, exist_ok=True)
        ledger_p.write_text(json.dumps(ledger, indent=2))
        return bak

    def _restore_ledger(self, bak):
        ledger_p = Path(".claude/state/attest-ledger.json")
        if bak and Path(bak).exists():
            shutil.move(bak, ledger_p)
        elif ledger_p.exists() and not bak:
            ledger_p.unlink()

    def test_codex_no_evidence_observe_drift_only(self, tmp_path):
        """No ledger entry in observe mode → drift-log, no block."""
        tp = _write_transcript(
            tmp_path,
            "Skill gate: codex:adversarial-review\n\nx",
            tool_uses=[],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout.replace(" ", "")

    # v28 R28 F2 fix: block-mode evidence tests MUST provide deterministic
    # CLAUDE_SESSION_ID so the L4 fail-closed gate (v27 R26 F1 + v28 R27 F1)
    # does not short-circuit before the intended L5 evidence code path runs.
    # Each test asserts a SPECIFIC block reason substring, so that any
    # regression that routes the test to a different (earlier) gate fails
    # the assertion explicitly.
    def _block_env(self):
        return {
            "CLAUDE_SESSION_ID": self.DETERMINISTIC_SESSION_ID,
            "CLAUDE_SESSION_START_UTC": "2026-04-22T00:00:00Z",
        }

    def test_codex_no_evidence_block_blocks(self, tmp_path):
        """Block mode + last_stage=brainstorming + no ledger → BLOCK (evidence missing)."""
        # Create a real spec file so target computes
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("test")
        sf = self._setup_brainstorming_stage(spec)
        bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
            # v28 R28 F2: assert evidence-missing reason (not session_id_absent)
            assert ("no_evidence" in stdout or "ledger" in stdout or "evidence" in stdout)
        finally:
            _restore(bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_ledger_match_block_mode_passes(self, tmp_path):
        """Block mode + ledger has entry with matching file blob + attest > session_start → pass."""
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("test-content-v1")
        blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        sf = self._setup_brainstorming_stage(spec)
        ledger_bak = self._write_ledger_entry(f"file:{spec}", blob)
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' not in stdout.replace(" ", "")
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_ledger_blob_mismatch_blocks(self, tmp_path):
        """Ledger entry exists but file content changed (blob mismatch) → BLOCK (revision check)."""
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("original-content")
        old_blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        spec.write_text("edited-content-different-blob")
        sf = self._setup_brainstorming_stage(spec)
        ledger_bak = self._write_ledger_entry(f"file:{spec}", old_blob)
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
            # v28 R28 F2: assert blob-mismatch reason explicitly
            assert ("blob" in stdout or "revision" in stdout)
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_ledger_stale_time_blocks(self, tmp_path):
        """Ledger entry exists but attest_time_utc < SESSION_START → BLOCK."""
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("content")
        blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        sf = self._setup_brainstorming_stage(spec)
        ledger_bak = self._write_ledger_entry(f"file:{spec}", blob, attest_time="2026-04-21T00:00:00Z")
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_ledger_wrong_target_blocks(self, tmp_path):
        """Ledger has entry for different file → BLOCK."""
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("content")
        sf = self._setup_brainstorming_stage(spec)
        ledger_bak = self._write_ledger_entry("file:docs/superpowers/specs/UNRELATED.md", "dummyblob")
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra=self._block_env())
            assert '"decision":"block"' in stdout.replace(" ", "")
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)

    def test_codex_session_start_unknown_block_mode_blocks(self, tmp_path):
        """No CLAUDE_SESSION_ID + no CLAUDE_SESSION_START_UTC + block mode → BLOCK (fail-closed)."""
        spec = Path("docs/superpowers/specs/2026-04-22-test-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("content")
        blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        sf = self._setup_brainstorming_stage(spec)
        ledger_bak = self._write_ledger_entry(f"file:{spec}", blob)
        mode_bak = _set_mode("codex:adversarial-review", "block")
        # Unset both session envs
        env_no_sess = {k: v for k, v in os.environ.items()
                       if k not in ("CLAUDE_SESSION_ID", "CLAUDE_SESSION_START_UTC")}
        try:
            # v5 R4 F1 fix: include Write tool_use so target derives from response
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "x"}}],
            )
            proc = subprocess.run(
                ["bash", HOOK],
                input=json.dumps({"transcript_path": str(tp)}),
                capture_output=True, text=True, timeout=15, env=env_no_sess,
            )
            assert '"decision":"block"' in proc.stdout.replace(" ", "")
        finally:
            _restore(mode_bak)
            self._restore_ledger(ledger_bak)
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)


class TestStateIsolation:
    def test_different_session_ids_independent(self, tmp_path):
        """Two session_ids produce two state files."""
        state_dir = Path(".claude/state/skill-stage")
        before = set(state_dir.glob("*.json"))

        tp = _write_transcript(
            tmp_path,
            "Skill gate: superpowers:brainstorming\n\nx",
            tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
        )
        _run_hook(tp, env_extra={"CLAUDE_SESSION_ID": "01HQAAAAAAAAAAAAAAAAAAAAAA"})
        _run_hook(tp, env_extra={"CLAUDE_SESSION_ID": "01HQBBBBBBBBBBBBBBBBBBBBBB"})

        after = set(state_dir.glob("*.json"))
        new_files = after - before
        assert len(new_files) >= 2

    def test_no_session_id_block_mode_fails_closed_v28(self, tmp_path):
        """v28 R27 F1: non-codex skill invocation with no CLAUDE_SESSION_ID in
        block mode MUST block (PPID+time fallback would reset last_stage=_initial,
        silently bypassing L4 mini-state)."""
        mode_bak = _set_mode("superpowers:brainstorming", "block")
        env_no_sess = {k: v for k, v in os.environ.items()
                       if k not in ("CLAUDE_SESSION_ID",)}
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:brainstorming\n\nx",
                tool_uses=[{"name": "Skill", "input": {"skill": "superpowers:brainstorming"}}],
            )
            proc = subprocess.run(
                ["bash", HOOK],
                input=json.dumps({"transcript_path": str(tp)}),
                capture_output=True, text=True, timeout=15, env=env_no_sess,
            )
            assert '"decision":"block"' in proc.stdout.replace(" ", "")
            assert "session_id_absent_l4_fail_closed" in proc.stdout or "CLAUDE_SESSION_ID" in proc.stdout
        finally:
            _restore(mode_bak)


class TestOutOfRepoPathRejection:
    """v29 R29 F1: codex target derivation and recent_artifact recording MUST
    reject absolute out-of-repo paths (Path.resolve + relative_to check).
    Previously sed/lstrip('/') could normalize /tmp/docs/superpowers/specs/x.md
    into a repo-relative-looking string and bind codex evidence to a file
    outside the repo."""

    OUT_OF_REPO_PATHS = [
        "/tmp/docs/superpowers/specs/x.md",
        "/docs/superpowers/specs/x.md",
        "../outside/docs/superpowers/specs/x.md",
    ]

    def _deterministic_env(self):
        return {
            "CLAUDE_SESSION_ID": "01HQTESTAAAAAAAAAAAAAAAAAA",
            "CLAUDE_SESSION_START_UTC": "2026-04-22T00:00:00Z",
        }

    def test_codex_target_rejects_out_of_repo_paths(self, tmp_path):
        """codex:adversarial-review gate MUST NOT bind to absolute out-of-repo
        spec/plan paths in the response tool_uses."""
        import hashlib
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = hashlib.sha256(b"01HQTESTAAAAAAAAAAAAAAAAAA").hexdigest()[:8]
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        sf.write_text(json.dumps({
            "version": "1",
            "last_stage": "superpowers:brainstorming",
            "last_stage_time_utc": "2026-04-22T00:00:00Z",
            "worktree_path": os.getcwd(),
            "session_id": "01HQTESTAAAAAAAAAAAAAAAAAA",
            "drift_count": 0,
            "transition_history": [],
        }))
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            for bad_path in self.OUT_OF_REPO_PATHS:
                tp = _write_transcript(
                    tmp_path,
                    "Skill gate: codex:adversarial-review\n\nx",
                    tool_uses=[{"name": "Write", "input": {"file_path": bad_path, "content": "x"}}],
                )
                rc, stdout, _ = _run_hook(tp, env_extra=self._deterministic_env())
                # Out-of-repo path must not produce a file: TARGET.
                # Either blocks with no_target/stale or fails on evidence —
                # in no case does it pass silently.
                assert '"decision":"block"' in stdout.replace(" ", ""), \
                    f"Out-of-repo path {bad_path!r} should not pass codex gate; stdout={stdout[:300]}"
        finally:
            _restore(mode_bak)
            sf.unlink(missing_ok=True)

    def test_recent_artifact_state_rejects_out_of_repo_paths(self, tmp_path):
        """State recorded recent_artifact_path MUST NOT be set to an
        out-of-repo absolute path even when brainstorming/writing-plans
        response carries such a Write tool_use."""
        import hashlib
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        # Clean slate: remove existing state for this test's sid hash
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = hashlib.sha256(b"01HQTESTAAAAAAAAAAAAAAAAAA").hexdigest()[:8]
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        sf.unlink(missing_ok=True)
        try:
            # Stage brainstorming with an out-of-repo Write tool_use
            tp = _write_transcript(
                tmp_path,
                "Skill gate: superpowers:brainstorming\n\nx",
                tool_uses=[
                    {"name": "Skill", "input": {"skill": "superpowers:brainstorming"}},
                    {"name": "Write", "input": {
                        "file_path": "/tmp/docs/superpowers/specs/evil.md",
                        "content": "hijack",
                    }},
                ],
            )
            _run_hook(tp, env_extra=self._deterministic_env())
            assert sf.exists(), "brainstorming should create state file"
            state = json.loads(sf.read_text())
            recent = state.get("recent_artifact_path", "")
            # Out-of-repo path MUST NOT be recorded
            assert not recent.startswith("/"), \
                f"recent_artifact_path should not be absolute: {recent!r}"
            assert recent != "tmp/docs/superpowers/specs/evil.md", \
                f"out-of-repo path leaked via lstrip: {recent!r}"
            # Either empty or an actual in-repo docs/superpowers/... path
            if recent:
                assert recent.startswith("docs/superpowers/"), \
                    f"recent_artifact_path must be in-repo docs/superpowers/: {recent!r}"
                # And the corresponding file must actually exist in repo
                assert Path(recent).exists(), \
                    f"recent_artifact_path should point at a real in-repo file: {recent!r}"
        finally:
            sf.unlink(missing_ok=True)


class TestCodexTargetInResponseOnly:
    """v33 R33 F1 regression: codex target MUST derive from CURRENT response
    Write/Edit tool_use when present. Previous `echo $X | python3 - <<'PY'`
    had stdin conflict between pipe and heredoc → CANDIDATES always empty →
    valid codex gate after spec/plan edit blocked with no_target."""

    def test_codex_target_from_response_write_in_block_mode(self, tmp_path):
        """Block mode + brainstorming stage + response has Write to spec +
        ledger has matching entry → PASS (target derives from response)."""
        import hashlib
        spec = Path("docs/superpowers/specs/2026-04-22-r33-f1-fixture.md")
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text("v33-r33-f1-content")
        blob = subprocess.check_output(
            ["git", "hash-object", str(spec)], text=True
        ).strip()
        # Stage brainstorming so codex target path executes
        state_dir = Path(".claude/state/skill-stage")
        state_dir.mkdir(parents=True, exist_ok=True)
        wt_h = hashlib.sha256(os.getcwd().encode()).hexdigest()[:8]
        sid_h = hashlib.sha256(b"01HQTESTAAAAAAAAAAAAAAAAAA").hexdigest()[:8]
        sf = state_dir / f"{wt_h}-{sid_h}.json"
        sf.write_text(json.dumps({
            "version": "1",
            "last_stage": "superpowers:brainstorming",
            "last_stage_time_utc": "2026-04-22T00:00:00Z",
            "worktree_path": os.getcwd(),
            "session_id": "01HQTESTAAAAAAAAAAAAAAAAAA",
            "drift_count": 0,
            "transition_history": [],
        }))
        ledger_p = Path(".claude/state/attest-ledger.json")
        ledger_bak = str(ledger_p) + ".r33bak"
        if ledger_p.exists():
            shutil.copy(ledger_p, ledger_bak)
            ledger = json.loads(ledger_p.read_text())
        else:
            ledger = {"entries": {}}
            ledger_bak = None
        ledger.setdefault("entries", {})[f"file:{spec}"] = {
            "attest_time_utc": "2026-04-22T09:00:00Z",
            "verdict_digest": "sha256:testdigest",
            "blob_sha": blob,
            "round": 1,
        }
        ledger_p.parent.mkdir(parents=True, exist_ok=True)
        ledger_p.write_text(json.dumps(ledger, indent=2))
        mode_bak = _set_mode("codex:adversarial-review", "block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:adversarial-review\n\nx",
                tool_uses=[{"name": "Write", "input": {"file_path": str(spec), "content": "updated"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra={
                "CLAUDE_SESSION_ID": "01HQTESTAAAAAAAAAAAAAAAAAA",
                "CLAUDE_SESSION_START_UTC": "2026-04-22T00:00:00Z",
            })
            # Target MUST derive from response Write → file:<spec> → ledger
            # entry found → pass. If R33 F1 stdin bug regresses, CANDIDATES
            # is empty → target falls back to state/_initial → would block
            # with no_target.
            assert '"decision":"block"' not in stdout.replace(" ", ""), \
                f"Valid codex gate with response Write should pass; stdout={stdout[:400]}"
            assert "codex_gate_no_target" not in stdout, \
                "If CANDIDATES empty, hook would drift_log codex_gate_no_target — stdin-pipe bug regressed"
        finally:
            _restore(mode_bak)
            if ledger_bak:
                shutil.move(ledger_bak, ledger_p)
            elif ledger_p.exists():
                ledger_p.unlink()
            sf.unlink(missing_ok=True)
            spec.unlink(missing_ok=True)


class TestH6ScopeOnlyL1L2:
    """v44 R44 F1 final regression: L1 + L2 scoped to H6 only. Non-H6
    plugin gates MUST be rejected (neither passthrough nor invoke-match
    bypass). Rationale: codex R44 verified that plugin-format passthrough
    lets agents bypass required H6 transitions (brainstorming → writing-plans
    → codex:adversarial-review) by routing through an unrelated plugin gate."""

    def test_frontend_design_gate_l1_rejects_in_block_mode(self, tmp_path):
        """frontend-design:web declared as L1 gate → L1 regex fails (H6 scope).
        In block mode, stop-response-check.sh hard-blocks missing/invalid gate."""
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: frontend-design:web\n\nx",
                tool_uses=[{"name": "Skill", "input": {"skill": "frontend-design:web"}}],
            )
            # Run the L1 stop-response-check (owns L1 regex).
            stop_hook = ".claude/hooks/stop-response-check.sh"
            if Path(stop_hook).exists():
                proc = subprocess.run(
                    ["bash", stop_hook],
                    input=json.dumps({"transcript_path": str(tp)}),
                    capture_output=True, text=True, timeout=15,
                )
                combined = proc.stdout + proc.stderr
                assert '"decision":"block"' in combined.replace(" ", "") \
                    or proc.returncode == 2 \
                    or "Skill gate" in combined, \
                    f"frontend-design:web must not pass L1 in block mode; stdout={proc.stdout[:400]}"
        finally:
            _restore_enforcement_mode(bak)

    def test_unregistered_codex_prefix_l2_fail_closed(self, tmp_path):
        """codex:rescue / codex:<anything> not in config → L2 unknown-gate
        fail-closed in block mode (no plugin-format invoke-match bypass)."""
        bak = _set_enforcement_mode("block")
        try:
            tp = _write_transcript(
                tmp_path,
                "Skill gate: codex:rescue\n\nx",
                tool_uses=[{"name": "Skill", "input": {"skill": "codex:rescue"}}],
            )
            rc, stdout, _ = _run_hook(tp, env_extra={
                "CLAUDE_SESSION_ID": "01HQTESTAAAAAAAAAAAAAAAAAA",
            })
            assert '"decision":"block"' in stdout.replace(" ", ""), \
                f"codex:rescue not in config must block at L2; stdout={stdout[:400]}"
            assert "未在 skill-invoke-enforced" in stdout or "未在" in stdout \
                or "block mode" in stdout, \
                f"Block reason should indicate unregistered gate; stdout={stdout[:400]}"
        finally:
            _restore_enforcement_mode(bak)
```

- [ ] **Step 2: 跑测试**

```bash
pytest tests/hooks/test_skill_invoke_check.py -v --tb=short 2>&1 | tail -30
```

Expected: 绝大多数 pass（部分 edge case 可能因 harness 限制 skip）。

- [ ] **Step 3: commit**

```bash
git add tests/hooks/test_skill_invoke_check.py
git commit -m "hardening-6 Task 6: tests for skill-invoke-check.sh L2/L4/L5"
```

---

## Task 7: Wire up `settings.json`

**Files:**
- Modify: `.claude/settings.json`

- [ ] **Step 1: 加 Stop.skill-invoke-check hook 节点**

读现有 settings.json 的 `hooks.Stop` 数组，向内追加：

```bash
# v21 R20 F1 fix: wrapper resolves repo root with CLAUDE_PROJECT_DIR fallback
# to git rev-parse. Handles both missing env var AND paths with spaces (R19 F1).
# Command invokes bash -c wrapper that computes REPO_ROOT safely then exec's hook.
jq '.hooks.Stop += [{"hooks":[{"type":"command","command":"bash -c '\''cd \"${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}\" && exec bash .claude/hooks/skill-invoke-check.sh'\''"}]}]' .claude/settings.json > /tmp/new-settings.json
mv /tmp/new-settings.json .claude/settings.json
```

- [ ] **Step 2: 验证 JSON 合法**

```bash
jq -e '.hooks.Stop | length >= 2' .claude/settings.json  # 既有 + 新增
jq -e '.hooks.Stop[] | select(.hooks[0].command | contains("skill-invoke-check")) | .hooks[0].command' .claude/settings.json
```

Expected: 2 行 output

- [ ] **Step 3: commit**

```bash
git add .claude/settings.json
git commit -m "hardening-6 Task 7: settings.json add Stop.skill-invoke-check hook"
```

---

## Task 8: Acceptance script

**Files:**
- Create: `scripts/acceptance/hardening_6_framework.sh`

- [ ] **Step 1: 写脚本**

```bash
cat > scripts/acceptance/hardening_6_framework.sh <<'ACC_EOF'
#!/usr/bin/env bash
# Hardening-6 框架验收（H6.0 Task 8）
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0; declare -a FAILED
run() {
  local label="$1"; shift
  echo ""; echo "========== $label =========="
  if "$@"; then echo "OK: $label"; PASS=$((PASS+1))
  else echo "NG: $label"; FAIL=$((FAIL+1)); FAILED+=("$label"); fi
}

# ---- Files 存在 + 可执行 ----
run "file: config"   test -s .claude/config/skill-invoke-enforced.json
run "file: new hook" test -x .claude/hooks/skill-invoke-check.sh
# v10 R9 F3: state dir/drift log are runtime artifacts (ignored by git);
# check .gitignore covers them instead of requiring file existence
run "gitignore: state dir covered" \
  bash -c "git check-ignore -q .claude/state/skill-stage/test.json || test -d .claude/state/skill-stage"
run "gitignore: drift log covered" \
  bash -c "git check-ignore -q .claude/state/skill-invoke-drift.jsonl || test -f .claude/state/skill-invoke-drift.jsonl"

# ---- Config schema ----
run "config: 14 skill"     bash -c "[ \"\$(jq '.enforce | length' .claude/config/skill-invoke-enforced.json)\" = '14' ]"
# v15 R14 F1: legal_next_set has 12 non-wildcard skills + systematic-debugging + _initial = 14 keys
# (using-superpowers / dispatching-parallel-agents are state-less wildcards)
run "config: legal_next_set 14 keys (12 non-wildcard + sys-debug + _initial)" bash -c "[ \"\$(jq '.mini_state.legal_next_set | length' .claude/config/skill-invoke-enforced.json)\" = '14' ]"
run "config: state-aware wildcards (systematic-debugging) + non-wildcards all covered by legal_next_set" \
  bash -c "diff <(jq -r '(.enforce | keys) - [\"superpowers:using-superpowers\", \"superpowers:dispatching-parallel-agents\"] | .[]' .claude/config/skill-invoke-enforced.json | sort) <(jq -r '.mini_state.legal_next_set | keys[] | select(. != \"_initial\")' .claude/config/skill-invoke-enforced.json | sort)"
run "config: codex entry exists"    bash -c "jq -e '.enforce[\"codex:adversarial-review\"]' .claude/config/skill-invoke-enforced.json > /dev/null"

# ---- settings.json wired ----
run "settings: skill-invoke-check wired" \
  bash -c "jq -e '.hooks.Stop | map(.hooks[]?.command) | flatten | any(. | contains(\"skill-invoke-check\"))' .claude/settings.json > /dev/null"

# ---- workflow-rules enforcement_mode (v34 R33 F3 + v35 R35 F1 fix) ----
# Task 1-8 runs in bootstrap mode where enforcement_mode is still drift-log
# (Task 9 flip is deliberately the last commit). If we hard-required block
# here, Task 8 acceptance could NEVER pass → push 开发者改破窗绕开。
# Split: default mode accepts drift-log OR block; --final (pre-merge/CI)
# requires block. Task 8 calls default; CI workflow passes --final.
FINAL_MODE=0
for a in "$@"; do [ "$a" = "--final" ] && FINAL_MODE=1; done
if [ "$FINAL_MODE" = "1" ]; then
  run "rules: enforcement_mode == block (pre-merge gate; Task 9 flip 必须已完成)" \
    bash -c "jq -e '.skill_gate_policy.enforcement_mode == \"block\"' .claude/workflow-rules.json > /dev/null"
else
  run "rules: enforcement_mode ∈ {drift-log, block} (bootstrap mode)" \
    bash -c "jq -re '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json | grep -qE '^(drift-log|block)$'"
fi

# ---- Unit tests ----
# v9 R8 F3 fix: preserve pytest exit via -o pipefail; output capture separate
run "unit: test_stop_response_check" \
  bash -o pipefail -c "pytest tests/hooks/test_stop_response_check.py -q > /tmp/pytest-stop.log 2>&1; ec=\$?; tail -3 /tmp/pytest-stop.log; exit \$ec"
run "unit: test_skill_invoke_check" \
  bash -o pipefail -c "pytest tests/hooks/test_skill_invoke_check.py -q > /tmp/pytest-invoke.log 2>&1; ec=\$?; tail -3 /tmp/pytest-invoke.log; exit \$ec"

# ---- Regression ----
# v46 R46 F2 fix: regression scripts must emit their exact success sentinel.
# Previously only exit code was checked; a script that internally skipped
# or caught failures while returning 0 would pass acceptance. Now we
# require the sentinel line to appear in the captured log.
run "regression: Plan 1 DDL" \
  bash -c "./scripts/acceptance/plan_1_m0_1_db_schema.sh > /tmp/p1.log 2>&1 && grep -Fxq 'PLAN 1 PASS' /tmp/p1.log"
run "regression: Plan 1f schema versioning" \
  bash -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/p1f.log 2>&1 && grep -Fxq 'PLAN 1f PASS' /tmp/p1f.log"

echo ""; echo "============================================"
echo "Hardening-6 framework acceptance: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed items:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "HARDENING 6 FAIL"; exit 1
fi
echo "HARDENING 6 PASS"
ACC_EOF
chmod +x scripts/acceptance/hardening_6_framework.sh
```

- [ ] **Step 2: 跑一遍（bootstrap mode；enforcement_mode 仍是 drift-log）**

```bash
# v35 R35 F1: Task 8 跑 default mode（不带 --final），accept drift-log 或 block。
# Task 9 flip 之后 CI 会用 --final 跑，require block。
./scripts/acceptance/hardening_6_framework.sh
```

Expected: `HARDENING 6 PASS` + 11 passed 0 failed（部分 unit test 数量依实际）

**注**：Task 9 commit 之后，本脚本也可以用 `--final` 再跑一次验证 block mode 状态正确。但 local Task 8 verification 不带 --final，避免 Task 8 必然 fail 的 chicken-and-egg（codex R35 F1 HIGH fix）。

- [ ] **Step 3: commit**

```bash
git add scripts/acceptance/hardening_6_framework.sh
git commit -m "hardening-6 Task 8: acceptance script"
```

---

## Task 8.5: L5 Codex Gate Rollout 使用指南（v16 R15 F1 fix，Task 9 前置）

**问题**（Codex R15 HIGH）：Task 9 flip `enforcement_mode=block` 后，任何 response first-line 不是合法 `Skill gate:` 的都会被 L1 block。codex review 工作流若走 "先 run codex-attest 在一响应，再 announce gate 下一响应"（spec §2.2 模式 ii），那 run-only 响应可能被 L1 block。

**本项目使用 L5 codex gate 的**正确模式**（v16 明确化）：

### 模式 i（同响应 announce + run，**推荐**）

Claude 的响应结构：
```
Skill gate: codex:adversarial-review
<正文：本 response 将跑 codex-attest 验证 spec/plan/branch>
<tool_use: Bash: .claude/scripts/codex-attest.sh --scope branch-diff --base ... --head ...>
```

- L1：first-line 是 `Skill gate: codex:adversarial-review` → 合法 → pass
- L2：skip（codex 走 L5 特殊路径，L2 不做 Skill tool invoke match）
- L3：skip（非 exempt）
- L5：Bash 完成后 ledger update，path A 查 target 匹配的 entry → pass

### 模式 ii（先 run 再 announce，**不推荐**在 Task 9 后）

flip 后 run-only 响应必须用 first-line `Skill gate: exempt(single-step-no-semantic-change)` + 跑 codex-attest.sh。但 L3 single-step Bash allowlist 不含 `.claude/scripts/codex-attest.sh`，会被 block。

**v16 解决**：扩 single-step Bash allowlist 允许 codex-attest.sh / attest-override.sh：

在 Task 3 Step 1 `safe_bash_single` 正则（validate_exempt_integrity 中）追加 alternative：

```python
safe_bash_single = re.compile(
    r'^(pwd|true|false)$'
    r'|^echo +["\'][^"\'|<>;&`$()]*["\']$'
    r'|^(ls|cat|head|tail|wc|grep|rg|jq) +[^|<>;&`$(){}\-]+$'
    r'|^\.claude/scripts/(codex-attest|attest-override)\.sh(\s|$)'  # v16 R15 F1
)
```

### Task 6 新增测试

在 `test_skill_invoke_check.py` `TestL5CodexGate` 加：

```python
def test_codex_mode_i_same_response_announce_and_run(self, tmp_path):
    """v16 R15 F1: 模式 i (announce + run same response) must pass L1 in block mode."""
    # Set enforcement_mode=block globally
    import shutil as _sh
    rp = Path(".claude/workflow-rules.json")
    bak = str(rp) + ".bak"
    _sh.copy(rp, bak)
    try:
        d = json.loads(rp.read_text())
        d["skill_gate_policy"]["enforcement_mode"] = "block"
        rp.write_text(json.dumps(d, indent=2))
        # Response has codex gate + Bash codex-attest (mode i)
        tp = _write_transcript(
            tmp_path,
            "Skill gate: codex:adversarial-review\n\nRunning attest.",
            tool_uses=[{"name": "Bash", "input": {"command": ".claude/scripts/codex-attest.sh --scope branch-diff --head my-branch"}}],
        )
        rc, stdout, _ = _run_hook(tp, env_extra={"CLAUDE_SESSION_START_UTC": "2026-04-22T00:00:00Z"})
        # L1 must not block (first-line is valid codex gate)
        # L5 may drift-log (observe mode for codex in H6.0) but not block
        assert '"decision":"block"' not in stdout.replace(" ", "")
    finally:
        _sh.move(bak, str(rp))

def test_codex_mode_ii_run_only_via_single_step_exempt(self, tmp_path):
    """v16 R15 F1: 模式 ii run-only via exempt(single-step) must pass when
    Bash is codex-attest.sh (in safe_bash_single allowlist)."""
    import shutil as _sh
    rp = Path(".claude/workflow-rules.json")
    bak = str(rp) + ".bak"
    _sh.copy(rp, bak)
    try:
        d = json.loads(rp.read_text())
        d["skill_gate_policy"]["enforcement_mode"] = "block"
        rp.write_text(json.dumps(d, indent=2))
        tp = _write_transcript(
            tmp_path,
            "Skill gate: exempt(single-step-no-semantic-change)\n\nRunning attest only.",
            tool_uses=[{"name": "Bash", "input": {"command": ".claude/scripts/codex-attest.sh --scope branch-diff --head my-branch"}}],
        )
        rc, stdout, _ = _run_hook(tp)
        assert '"decision":"block"' not in stdout.replace(" ", ""), \
            "single-step exempt with codex-attest.sh should be allowed by safe_bash_single v16 alt"
    finally:
        _sh.move(bak, str(rp))
```

这两个 tests **必须在 Task 9 flip 前加入并通过**。

---

## Task 8.75: CI acceptance gate（v23 R22 F1 fix，Task 9 前置）

**背景**：codex R22 指出 Task 9 flip 只靠 "ordering discipline"不可靠——若 Task 1-8 任一 commit 不完整就 flip，全局 block 会拦合法响应。需要 CI 作为 hard gate。

**Files:**
- Create: `.github/workflows/hardening_6_gate.yml`

- [ ] **Step 1: 写 CI workflow**

```yaml
name: hardening-6 framework gate
# v28 R28 F3 fix: REMOVED pull_request.paths filter. When this workflow is
# required by branch protection, GitHub only creates status checks for PRs
# matching paths; PRs that don't touch those paths would never report a
# status → required check waits forever → branch protection deadlocks all
# unrelated PRs. Fix: always run on every PR; the job itself short-circuits
# (fast pass) when no relevant file changed.
on:
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  acceptance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # need history to diff against origin/main
      - name: Install jq
        run: sudo apt-get install -y jq
      # v41 R41 F3 fix: acceptance invokes pytest via scripts/acceptance/*.sh;
      # without pytest installed on clean runners, CI would fail BEFORE
      # exercising hardening checks → deadlock status.
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - name: Install Python test dependencies
        run: |
          set -euo pipefail
          python -m pip install --upgrade pip
          # Install root dev deps if present (pytest + plugins), plus any
          # backend-specific test deps the acceptance scripts may invoke.
          for req in requirements-dev.txt backend/requirements-dev.txt backend/requirements.txt; do
            [ -f "$req" ] && python -m pip install -r "$req"
          done
          # Ensure pytest is available even if no requirements files
          python -m pip install pytest || true
      # v28 R28 F3: determine whether any hardening-6-relevant file changed
      - name: Detect relevant changes
        id: changes
        run: |
          set -euo pipefail
          git fetch origin main --depth=50
          CHANGED=$(git diff --name-only origin/main...HEAD)
          echo "$CHANGED" | tee /tmp/h6-changed.txt
          if echo "$CHANGED" | grep -qE '^(\.claude/hooks/(stop-response-check|skill-invoke-check)\.sh|\.claude/config/skill-invoke-enforced\.json|\.claude/settings\.json|\.claude/workflow-rules\.json|tests/hooks/test_(stop_response_check|skill_invoke_check)\.py|scripts/acceptance/hardening_6_framework\.sh|\.github/workflows/hardening_6_gate\.yml)$'; then
            echo "relevant=true" >> "$GITHUB_OUTPUT"
          else
            echo "relevant=false" >> "$GITHUB_OUTPUT"
          fi
      - name: Skip when nothing relevant changed
        if: steps.changes.outputs.relevant == 'false'
        run: echo "No hardening-6 framework files touched in this PR; acceptance skipped (status = success)."
      - name: Run hardening-6 acceptance (mode auto-detected from PR state)
        # v35 R35 F1 + v40 R40 F1 fix: call --final ONLY when this PR's HEAD
        # has enforcement_mode=block (i.e., it IS the H6.0-flip PR).
        # Framework PR (H6.0, drift-log) runs default mode → passes.
        # Flip PR (H6.0-flip, block) runs --final → requires block.
        # Prevents chicken-egg: framework PR's own CI can't fail by requiring
        # a state the framework PR intentionally doesn't set (v39 R38 F2).
        if: steps.changes.outputs.relevant == 'true'
        run: |
          set -euo pipefail
          mode=$(jq -r '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json)
          if [ "$mode" = "block" ]; then
            echo "PR has enforcement_mode=block → running acceptance in --final mode."
            bash scripts/acceptance/hardening_6_framework.sh --final
          else
            echo "PR has enforcement_mode=$mode → running acceptance in bootstrap mode."
            bash scripts/acceptance/hardening_6_framework.sh
          fi
      # v24 R23 F1 + v37 R37 F1 fix: self-check branch protection includes
      # this workflow as required status check. ADVISORY ONLY (not
      # fail-blocking) because:
      # - Repos may use rulesets (new API) instead of branch protection
      # - GITHUB_TOKEN may lack repo admin read on /branches/*/protection
      # - Protection may not yet be configured on bootstrap PR
      # A hard fail here would deadlock EVERY PR (documentation-only included)
      # the moment enforcement_mode=block is merged. Instead emit ::warning::
      # + job summary; opt-in STRICT mode via H6_BRANCH_PROTECTION_STRICT=1
      # env (only set after admin confirms protection configured).
      - name: Verify branch protection requires this check (advisory)
        if: github.event.pull_request.base.ref == 'main'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          H6_BRANCH_PROTECTION_STRICT: ${{ vars.H6_BRANCH_PROTECTION_STRICT || '0' }}
        run: |
          set -u  # no -e: we tolerate missing/unreadable protection
          mode=$(jq -r '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json)
          echo "enforcement_mode=$mode"
          if [ "$mode" != "block" ]; then
            echo "Not block mode; skipping branch-protection advisory."
            exit 0
          fi
          # Try branch protection API; tolerate 404 (no protection) and 403 (no read perm)
          api_out=$(gh api "repos/${GITHUB_REPOSITORY}/branches/main/protection" 2>&1) || api_rc=$?
          api_rc=${api_rc:-0}
          if [ "$api_rc" != "0" ]; then
            echo "::warning::branch-protection API unreadable (rc=$api_rc). Cannot verify required-context config."
            echo "::warning::api response: $api_out"
            if [ "$H6_BRANCH_PROTECTION_STRICT" = "1" ]; then
              echo "::error::STRICT mode on (H6_BRANCH_PROTECTION_STRICT=1) and API unreadable → fail."
              exit 1
            fi
            exit 0
          fi
          checks=$(echo "$api_out" | jq -r '.required_status_checks.contexts[]?' 2>/dev/null || echo "")
          if echo "$checks" | grep -q 'hardening-6'; then
            echo "Branch protection includes hardening-6 gate. ✓"
          else
            echo "::warning::enforcement_mode=block but branch protection doesn't list hardening-6 gate."
            echo "::warning::Configure via: gh api -X PUT repos/${GITHUB_REPOSITORY}/branches/main/protection -f 'required_status_checks[contexts][]=hardening-6 framework gate / acceptance' ..."
            if [ "$H6_BRANCH_PROTECTION_STRICT" = "1" ]; then
              echo "::error::STRICT mode on and missing context → fail."
              exit 1
            fi
          fi
```

- [ ] **Step 2: commit**

```bash
git add .github/workflows/hardening_6_gate.yml
git commit -m "hardening-6 Task 8.75: CI acceptance gate required before Task 9 flip"
```

---

## Task 9: Flip `workflow-rules.json` `enforcement_mode` → `block`（**v38 R38 F2: 延迟到后续 PR**）

**v38 R38 F2 HIGH**：codex 指出 Task 9 在同一 PR 里 flip + 依靠 advisory CI gate =
flip 能在 repo 没正确配置 branch protection 的情况下 merge；那么框架上线但 CI
gate 不是 required → 后续 PR 能绕过。必须**拆为两个 PR**：

- **此 PR（H6.0 framework）**：实现 Task 1-8.75；`enforcement_mode` 保持 `drift-log`。
  所有 hook + tests + CI workflow 已 in place，只是仍是 observe mode。
- **H6.0-flip PR（人类 checkpoint 后单独 PR）**：只改 `workflow-rules.json`
  一行；前置条件必须由 admin 手动确认：
  1. 本 PR 已 merge 到 main
  2. Branch protection（或 rulesets）已配置 `hardening-6 framework gate / acceptance`
     为 required status check
  3. Repo variable `H6_BRANCH_PROTECTION_STRICT=1` 已设置
  4. CI advisory step 在 main 分支跑时不再 emit `::warning::`

**实施者不 auto-flip**；此 Task 9 仅在当前 plan 留作 "post-merge human handoff"
记录，**不作为本 PR 的 commit**。

**Files:**
- Modify: `.claude/workflow-rules.json:168` (ONLY in 后续单独 PR)

**背景**：bootstrap chicken-egg 解决方案——本 PR 全程 `drift-log`；框架通过 CI
验收；merge 后 admin 手动配置 branch protection；然后用户单独起 PR 做 flip，
此时 CI 已是 enforceable required status。

- [ ] **Step 1（后续 PR，不在本 PR 执行）: 修改文件**

```bash
jq '.skill_gate_policy.enforcement_mode = "block"' .claude/workflow-rules.json > /tmp/new-rules.json
mv /tmp/new-rules.json .claude/workflow-rules.json
```

- [ ] **Step 2: 确认 diff 只 1 行**

```bash
git diff .claude/workflow-rules.json | grep -E '^[+-]' | grep -v '^[+-]{3}'
```

Expected：
```
-    "enforcement_mode": "drift-log",
+    "enforcement_mode": "block",
```

- [ ] **Step 3: 最终本地验收 (pre-commit)**

```bash
./scripts/acceptance/hardening_6_framework.sh
```

Expected: `HARDENING 6 PASS`

- [ ] **Step 3.5: 确认 CI workflow 存在 (v23 R22 F1 gate)**

```bash
test -f .github/workflows/hardening_6_gate.yml && echo "OK: CI gate in place"
```

Expected: `OK: CI gate in place`（Task 8.75 已完成）

CI 会在 PR 上自动跑 acceptance。本 commit merge 时，GitHub Actions required status check 必须 PASS 否则 merge 被阻。

- [ ] **Step 4（后续 PR）: commit + PR**

```bash
git add .claude/workflow-rules.json
git commit -m "hardening-6 H6.0-flip: enforcement_mode drift-log -> block

Prerequisites (manually confirmed by admin):
1. PR #XX (hardening-6 framework H6.0) merged to main
2. Branch protection / rulesets configured with required status check:
   'hardening-6 framework gate / acceptance'
3. Repo variable H6_BRANCH_PROTECTION_STRICT=1 set
4. Previous CI run on main emitted no ::warning:: from advisory step

After this merges, L1 first-line gate + L3 exempt integrity are
hard-blocking. Per-skill L2/L4/L5 enforcement flips individually via
H6.1-H6.10. CI gate is now enforceable (required + advisory→strict)."
```

**本 H6.0 PR 的 Task 列表到 Task 8.75 结束**；Task 9 单独成 PR，记于上方作
post-merge handoff。

---

## 非 coder 验收清单（CLAUDE.md §2 / `workflow-rules.json` `verification_template`）

| 项 | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | `./scripts/acceptance/hardening_6_framework.sh` | `HARDENING 6 PASS` | 两齐 = PASS |
| 2 | `jq '.enforce \| length' .claude/config/skill-invoke-enforced.json; jq -e '.enforce["codex:adversarial-review"]' .claude/config/skill-invoke-enforced.json` | 第 1 输出 `14`；第 2 jq -e exit 0 | 两者齐 = PASS |
| 3 | `jq '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json` | **H6.0 框架 PR**：输出 `"drift-log"`（Task 9 flip 不在本 PR，v39 R38 F2 defer）；**后续 H6.0-flip PR**：输出 `"block"` | 见 Expected 二选一 = PASS |
| 4 | `git check-ignore -q .claude/state/skill-stage/test.json; echo "exit=$?"` | 输出 `exit=0`（gitignored runtime 目录）| `exit=0` = PASS（state 目录是 runtime 创建，不 commit；per v10 R9 F3 fix）|
| 5 | `test -x .claude/hooks/skill-invoke-check.sh && echo OK` | `OK` | = PASS |
| 6 | `pytest tests/hooks/test_stop_response_check.py tests/hooks/test_skill_invoke_check.py -q` | 末行 `N passed` + 0 failed | 0 failed = PASS |
| 7 | PR files 数组含本 plan 10 个新/改文件 (`gh pr view <PR> --json files`) | 仅这 10 个路径 | 仅 10 个 = PASS |
| 8 | codex verdict 贴 PR（对 branch HEAD）= `approve` 或 `attest-override 仪式` | 有 comment | 有 = PASS |

---

## Self-Review

### Spec 覆盖

| Spec 要求 | 实现 Task |
|---|---|
| L1 声明强制（升级 stop-response-check.sh drift-log → block）| Task 3 + Task 9（flip 触发）|
| L2 invoke 强制（新 skill-invoke-check.sh）| Task 5 |
| L3 exempt allowlist 严格 | Task 3 |
| L4 mini-state 按 worktree+session 隔离 | Task 5（`STATE_FILE` 逻辑）|
| L5 codex target-bound + revision-bound | Task 5（codex 特殊路径）|
| unknown gate fail-closed in block mode | Task 5 |
| 13 skill config + legal_next_set | Task 1 |
| state 目录 + drift log | Task 2 |
| Tests | Task 4 + Task 6 |
| Acceptance | Task 8 |

### Placeholder 扫描
- 无 TBD / TODO。Task 2 Step 1 是"touch 空文件"，意图明确
- 所有 Bash / Python / JSON 代码块完整

### Type 一致性
- `SKILL_NAME` / `CONFIG_MODE` / `LAST_STAGE` 全 hook 一致
- config 字段名 (`mode` / `flip_phase` / `exempt_rule` / `legal_next_set`) 与 spec §2.3 一致

### Codex review 预估
- plan 阶段 codex：预估 1-3 轮；scope 明确，spec 已 approve
- PR 阶段 codex：预估 3-5 轮（实施层面 edge cases，如 ULID decode / shell regex escape）

---

## 执行切换提示

按 user autonomous mandate + 本 plan scope（9 task 单线性依赖）→ **Subagent-Driven**。

1. 每 task 派 fresh subagent（implementer）+ spec-compliance reviewer + code-quality reviewer（两层 review）
2. Task 9 是 **bootstrap-chicken-egg 的关键位点**：必须最后 commit，否则 dev 期间 hook 会 block 开发响应
3. 所有 task 完成后：
   - `superpowers:verification-before-completion` invoke + 跑 acceptance script
   - `superpowers:requesting-code-review` invoke（self-review branch）
   - codex adversarial review（branch-diff）—— 含 PR 阶段
   - push + PR + 用户跑 8 项非 coder 验收清单
