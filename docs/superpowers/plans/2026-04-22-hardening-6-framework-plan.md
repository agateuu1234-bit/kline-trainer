# Hardening-6 Framework (H6.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建 skill pipeline enforcement 框架 (ζ scope, 5 层)：新 `skill-invoke-check.sh` hook + 升级 `stop-response-check.sh` + `skill-invoke-enforced.json` config + per-worktree/session mini-state + drift log；初始全 observe，最后一个 commit flip `enforcement_mode: drift-log → block`。

**Architecture:** 2 个 Stop hooks 串联（既有 stop-response-check.sh 升级 L1/L3 强制 + 新 skill-invoke-check.sh 做 L2/L4/L5）；JSON config 驱动 13 个 skill 的 mode 和 legal_next_set；mini-state 按 worktree hash + session_id 隔离原子 write；codex gate 读 attest-ledger.json + attest-override-log.jsonl 做 target-bound + revision-bound 证据检查（不改既有 codex hook）。

**Tech Stack:** bash 4 + `jq` / `python3` / POSIX regex / JSONL append-only log。复用既有 `ledger-lib.sh` pattern。测试用 Python (匹配既有 `tests/hooks/test_*.py` pattern)。

**依赖（hard prereq）**：
- PR #17 hardening-1 merged（settings.json Edit/Write catch-all + `.claude/hooks/` 基础）
- PR #19 hardening-2 merged（drift-log + `skill-gate-drift.jsonl` + `stop-response-check.sh` 骨架）
- PR #22 skill-router-hook merged（UserPromptSubmit 提醒 hook）
- 既有 `.claude/scripts/codex-attest.sh` / `attest-override.sh` / `ledger-lib.sh`（不改，仅读其 ledger 输出）

**Spec**：`docs/superpowers/specs/2026-04-22-hardening-6-framework-design.md` v9 已 codex approve at `94d618f`。

## Scope 边界

**In scope**：建框架 + 13 skill observe（**不 block 任何 per-skill 调用**；仅 L1/L3 全局 hard-block 通过 flip `enforcement_mode`）

**Out of scope**：
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

- [ ] **Step 0: 确认既有 first-line regex 覆盖所有合法 gate（v6 R6 prerequisite）**

既有 `.claude/hooks/stop-response-check.sh` line 49 的 first-line regex 是：
```bash
'^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\([a-z-]+\))'
```

此 regex **已经**接受所有 4 类合法 first-line：
- `Skill gate: superpowers:<name>`（含 brainstorming / writing-plans 等 14 skill）
- `Skill gate: codex:adversarial-review`
- `Skill gate: frontend-design:<name>`
- `Skill gate: exempt(<reason>)`

**重要（v6 R6 HIGH finding fix）**：本 Task 的 Step 2 加 block 分支仅在**既有 drift-log 分支**内嵌入（既有逻辑：regex match fail → drift-log，加 block 变为 drift-log + exit 2）。**不改既有 regex**。因此 Task 9 flip 到 block 后，`Skill gate: superpowers:brainstorming` 仍走既有 match 路径 pass，不被误 block。Task 4 含 `test_valid_first_line_both_modes_pass` 已验证此场景。

读 hook 确认：

```bash
grep -n "Skill gate:" .claude/hooks/stop-response-check.sh | head -3
```

Expected: 第 49 行输出含 `superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\(`

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

# Find last user entry index (current turn begins after it)
last_user_idx = -1
for i, e in enumerate(entries):
    if e.get('type') == 'user':
        last_user_idx = i

# Aggregate all tool_uses from assistant entries after last user
last_tool_uses = []
for e in entries[last_user_idx + 1:]:
    if e.get('type') == 'assistant':
        content = e.get('message', {}).get('content', [])
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get('type') == 'tool_use':
                    last_tool_uses.append(c)

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
    # Strict allowlist: Read/Grep/Glob or specific safe Bash patterns
    # Safe Bash: complete regex match; NO pipes, redirects, compound commands, NO newlines/CR/tab
    safe_bash = re.compile(
        r'^(pwd|true|false)$'
        r'|^echo +["\'][^"\'|<>;&`$()]*["\']$'
        r'|^(ls|cat|head|tail|wc) +[^|<>;&`$(){}\-]+$'  # no -flag to avoid --delete/--output
    )
    for tu in last_tool_uses:
        name = tu.get('name', '')
        if name in ('Read', 'Grep', 'Glob'):
            continue
        if name == 'Bash':
            cmd = get_cmd(tu)
            # v17 R16 F1 fix: reject control chars (newline/CR/tab/NUL) BEFORE allowlist
            # Prevents 'ls .\nrm x' bypass where newline separates commands
            if CONTROL_CHARS_RE.search(cmd):
                print(f"BLOCK: exempt(read-only-query) Bash 含 newline/CR/tab/NUL 控制字符（多行 shell 命令）: {cmd[:80]!r}")
                sys.exit(0)
            # Reject any pipe/redirect/compound regardless of prefix match
            if re.search(r'[|<>;&`$]', cmd) or '||' in cmd or '&&' in cmd:
                print(f"BLOCK: exempt(read-only-query) Bash 含管道/重定向/复合命令: {cmd[:80]}")
                sys.exit(0)
            if not safe_bash.fullmatch(cmd):  # v17: fullmatch not match (prevents prefix-only)
                print(f"BLOCK: exempt(read-only-query) Bash 不在严格白名单: {cmd[:80]}")
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

# user-explicit-skip: trust user, no content check

print("OK")
PY
}
```

- [ ] **Step 2: L1 block 模式逻辑（insert 在既有 drift-log 块后）**

在 `echo "[skill-gate-drift] ..."` 之后的 `fi` 后添加：

```bash
  # L1 block mode (H6.9 flip): if enforcement_mode=block, hard block missing first-line
  RULES=".claude/workflow-rules.json"
  ENF_MODE=$(jq -r '.skill_gate_policy.enforcement_mode // "drift-log"' "$RULES" 2>/dev/null)
  if [ "$ENF_MODE" = "block" ]; then
    block "first-line Skill gate 缺失或格式无效；当前 first_line=\"$first_line\""
  fi
```

- [ ] **Step 3: L3 exempt integrity allowlist (v6：委托 Python helper，避免 shell IFS bypass)**

在既有 `# 2) Exempt reason whitelist` 块之后，添加 L3 integrity check：

```bash
# L3 exempt integrity (v6 H6 R5 F1+F2 fix): delegate to Python validator
# Avoids shell IFS='|' parsing that let 'cat x | tee y' bypass allowlist
# Also handles Write/Edit path check for behavior-neutral
if echo "$first_line" | grep -qE '^Skill gate: exempt\('; then
  reason=$(echo "$first_line" | sed -E 's/^Skill gate: exempt\(([^)]+)\).*/\1/')
  # reason 已在 §2 被白名单过滤，这里只检 integrity
  result=$(validate_exempt_integrity "$tpath" "$reason")
  if [[ "$result" == BLOCK:* ]]; then
    block "${result#BLOCK: }"
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

def _write_transcript(tmp_path, assistant_text, tool_uses=None):
    """Write mock transcript JSONL with one assistant message."""
    content = [{"type": "text", "text": assistant_text}]
    if tool_uses:
        for tu in tool_uses:
            content.append({"type": "tool_use", "name": tu["name"], "input": tu["input"]})
    entry = {"type": "assistant", "message": {"content": content}}
    tp = tmp_path / "transcript.jsonl"
    tp.write_text(json.dumps(entry) + "\n")
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
                 "^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\\([a-z-]+\\))"],
                input=line, capture_output=True, text=True,
            )
            assert r.returncode == 0, f"regex rejected valid gate: {line}"

    def test_valid_first_line_both_modes_pass(self, tmp_path):
        """Verify all 4 gate forms pass Hook 1 in both modes (R6 F1 verification).
        
        After Task 9 flips enforcement_mode to block, ordinary skill-gated
        responses must still pass through Hook 1 (既有 regex line 49 accepts
        superpowers:/codex:/frontend-design:/exempt(...)).
        """
        gate_samples = [
            "Skill gate: superpowers:brainstorming\n\nSome text",
            "Skill gate: superpowers:writing-plans\n\ntext",
            "Skill gate: superpowers:verification-before-completion\n\ntext",
            "Skill gate: codex:adversarial-review\n\ntext",
            "Skill gate: frontend-design:frontend-design\n\ntext",
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
# Find last user index; current turn = all assistant entries after it
last_user_idx = -1
for i, e in enumerate(entries):
    if e.get('type') == 'user':
        last_user_idx = i
# Aggregate tool_uses across all assistant entries after last user;
# text = text from LAST assistant entry (first_line 取自最后一条)
for e in entries[last_user_idx + 1:]:
    if e.get('type') == 'assistant':
        content = e.get('message', {}).get('content', [])
        if isinstance(content, list):
            last_text_this_entry = ""
            for c in content:
                if isinstance(c, dict):
                    if c.get('type') == 'text':
                        last_text_this_entry = c.get('text', '')
                    elif c.get('type') == 'tool_use':
                        tool_uses.append({'name': c.get('name'), 'input': c.get('input', {})})
            if last_text_this_entry:
                text = last_text_this_entry
print(json.dumps({'text': text, 'tool_uses': tool_uses}))
PY
)
LAST_TEXT=$(echo "$TXT_AND_USES" | jq -r '.text')
[ -z "$LAST_TEXT" ] && exit 0

FIRST_LINE=$(echo "$LAST_TEXT" | head -1)
GATE_RE='^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\([a-z-]+\))'
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

# Look up config
IN_CONFIG=$(jq -r --arg s "$SKILL_NAME" '.enforce[$s] // empty' "$CONFIG")
if [ -z "$IN_CONFIG" ]; then
  # Unknown gate
  if [ "$ENF_MODE" = "block" ] && [ "${ALLOW_UNKNOWN_GATE:-0}" != "1" ]; then
    drift_log "unknown_skill_in_gate"
    block "Skill gate '$SKILL_NAME' 未在 skill-invoke-enforced.json 配置；block mode fail-closed"
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
      # Defeats absolute out-of-repo paths like /tmp/docs/superpowers/specs/x.md
      # that previously survived sed-based normalization and bound codex
      # evidence to a file outside the repo.
      CANDIDATES=$(echo "$TXT_AND_USES" | python3 - "$PWD" <<'PY' 2>/dev/null || true
import json, sys, re
from pathlib import Path
pwd = Path(sys.argv[1]).resolve()
spec_plan_re = re.compile(r'^docs/superpowers/(specs|plans)/.+\.md$')
seen = set()
try:
    data = json.loads(sys.stdin.read())
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

# ---- workflow-rules enforcement_mode 合法值 ----
run "rules: enforcement_mode valid" \
  bash -c "jq -re '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json | grep -qE '^(drift-log|block)$'"

# ---- Unit tests ----
# v9 R8 F3 fix: preserve pytest exit via -o pipefail; output capture separate
run "unit: test_stop_response_check" \
  bash -o pipefail -c "pytest tests/hooks/test_stop_response_check.py -q > /tmp/pytest-stop.log 2>&1; ec=\$?; tail -3 /tmp/pytest-stop.log; exit \$ec"
run "unit: test_skill_invoke_check" \
  bash -o pipefail -c "pytest tests/hooks/test_skill_invoke_check.py -q > /tmp/pytest-invoke.log 2>&1; ec=\$?; tail -3 /tmp/pytest-invoke.log; exit \$ec"

# ---- Regression ----
run "regression: Plan 1 DDL" \
  bash -c "./scripts/acceptance/plan_1_m0_1_db_schema.sh > /tmp/p1.log 2>&1"
run "regression: Plan 1f schema versioning" \
  bash -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/p1f.log 2>&1"

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

- [ ] **Step 2: 跑一遍**

```bash
./scripts/acceptance/hardening_6_framework.sh
```

Expected: `HARDENING 6 PASS` + 11 passed 0 failed（部分 unit test 数量依实际）

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
      - name: Run hardening-6 acceptance
        if: steps.changes.outputs.relevant == 'true'
        run: |
          bash scripts/acceptance/hardening_6_framework.sh
      - name: Verify enforcement_mode gate
        if: steps.changes.outputs.relevant == 'true'
        run: |
          mode=$(jq -r '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json)
          if [ "$mode" = "block" ]; then
            echo "enforcement_mode=block confirmed; acceptance gate must have passed"
          else
            echo "enforcement_mode=$mode (pre-flip or non-H6.0); acceptance gate not required"
          fi
      # v24 R23 F1 fix: self-check branch protection includes this workflow
      # as required status check. If not, flip to block is unsafe.
      # v28 R28 F3: runs regardless of relevant changes so required-check
      # self-audit posts on every PR.
      - name: Verify branch protection requires this check
        if: github.event.pull_request.base.ref == 'main'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          checks=$(gh api "repos/${GITHUB_REPOSITORY}/branches/main/protection" --jq '.required_status_checks.contexts[]?' 2>/dev/null || echo "")
          mode=$(jq -r '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json)
          if [ "$mode" = "block" ] && ! echo "$checks" | grep -q 'hardening-6'; then
            echo "::error::enforcement_mode=block but branch protection does not require hardening-6 gate."
            echo "::error::Configure: gh api -X PUT repos/${GITHUB_REPOSITORY}/branches/main/protection \\"
            echo "::error::  -f 'required_status_checks[contexts][]=hardening-6 framework gate / acceptance' ..."
            exit 1
          fi
          echo "Branch protection check: mode=$mode, contexts include hardening-6 if needed"
```

- [ ] **Step 2: commit**

```bash
git add .github/workflows/hardening_6_gate.yml
git commit -m "hardening-6 Task 8.75: CI acceptance gate required before Task 9 flip"
```

---

## Task 9: Flip `workflow-rules.json` `enforcement_mode` → `block`（最后一个 commit）

**Files:**
- Modify: `.claude/workflow-rules.json:168`

**背景**：bootstrap chicken-egg 解决方案——本 PR 所有开发时保持 `drift-log`（既有 hook 不会 block 我自己的开发响应）；PR 最后一个 commit 才 flip；merge 后全局生效。

- [ ] **Step 1: 修改文件**

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

- [ ] **Step 4: commit（LAST COMMIT）**

```bash
git add .claude/workflow-rules.json
git commit -m "hardening-6 Task 9: flip enforcement_mode drift-log -> block (LAST COMMIT of H6.0 PR)

After this merges, the L1 gate + L3 exempt integrity are hard-blocking.
Per-skill L2/L4/L5 enforcement stays observe until H6.1-H6.10 flip them
individually. Bootstrap chicken-egg: this commit is the last on the PR;
during PR review the mode is still drift-log so codex/reviewers can
operate normally."
```

---

## 非 coder 验收清单（CLAUDE.md §2 / `workflow-rules.json` `verification_template`）

| 项 | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | `./scripts/acceptance/hardening_6_framework.sh` | `HARDENING 6 PASS` | 两齐 = PASS |
| 2 | `jq '.enforce \| length' .claude/config/skill-invoke-enforced.json; jq -e '.enforce["codex:adversarial-review"]' .claude/config/skill-invoke-enforced.json` | 第 1 输出 `14`；第 2 jq -e exit 0 | 两者齐 = PASS |
| 3 | `jq '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json` | 输出 `"block"`（最后 commit 后）| `block` = PASS |
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
