# gov-bootstrap-hardening-3 设计 spec

**Date:** 2026-04-19
**Status:** Draft（待 codex:adversarial-review 收敛）
**Final Scope (2026-04-19 post-review):** H3-1 env-guard hook + H3-2 skill-gate auto-inject (a2+a3)
**Dropped during review:** H3-3 heredoc stripping（round 3 escalation，user option A，moved to hardening-4）
**Out of scope:** H2-3 worktree / G3 pipeline / subagent 强制 / CI attest-override reject / Cellar 泛化 / 集成测试 → hardening-4+

**Prereqs:**
- `gov-bootstrap-hardening` PR #17 (commit `56c8d31`)
- `Plan 0a v3` PR #18 (commit `5cd0402`)
- `gov-bootstrap-hardening-2` PR #19 (commit `e8b2558`)

---

## 1. 背景

hardening-2 收官时明确留 3 条 residual + 1 条新发现 heredoc 误报，本 PR 收尾这 3 条核心痛点：

| ID | 痛点 | 上下文 |
|---|---|---|
| H3-1 | hardening-2 H2-5 枚举模型对 compound suffix fall-through（`.env.local.backup` / `.env.production.local` 等）| codex hardening-2 round 2/3 反复指出；用户 γ 接受为 residual |
| H3-2 | hardening-2 H2-1 drift-log 无 hard-enforce；多 session 违规累积无边界 | codex hardening-2 round 2/3 反复指出；用户 Q2=d 授权 drift-log 但承诺 hardening-3 加强制边界 |
| H3-3 | guard-attest-ledger.sh detect_scenario 对 heredoc body 里的 `git push` / `gh pr create` / `gh pr merge` 字面量误报 BLOCK_UNPARSEABLE | Plan 0a v3 session 踩坑一次（写 acceptance 文档时） |

## 2. 目标

**H3-1**：新增 PreToolUse Read/Edit/Write hook `guard-env-read.sh`，**fail-closed** deny `**/.env*` with **allow-list** `.env.example` / `.env.sample` / `.env.template` / `.env.dist`。任何 compound suffix 默认 deny。替代 hardening-2 的 35 条枚举。

**H3-2**：两层强制
- **a2 (sofcter prompt)**：stop-response-check.sh drift 时在 stderr 输出**多行醒目格式**含推断 skill 名 + 当前累积 drift 次数 + 明确指令
- **a3 (ceiling)**：guard-attest-ledger.sh 在 scenario A/B/C 进入前读 drift log + push cursor。`new_drift_since_last_push > DRIFT_PUSH_THRESHOLD`（默认 5）→ block 带 `ack-drift.sh` 指引
- 新脚本 `.claude/scripts/ack-drift.sh`：tty + nonce 确认（同 attest-override 模式），前推 cursor 到当前 drift log 行数

**H3-3**：guard-attest-ledger.sh `detect_scenario` 先剥离 heredoc body（检测 `<<TAG` / `<<'TAG'` / `<<-TAG` 格式），只对 outer tokens 跑 push/pr 检测。

## 3. 非目标（本 PR 显式不做）

- H2-3 branch-diff worktree 真 review 目标 SHA diff → hardening-4
- G3 skill pipeline 顺序强制 → 专设计周期
- Plan 执行默认 subagent-driven → 后续
- CI attest-override reject → 后续
- Homebrew Cellar allowlist 通用化 → 后续
- 集成测试框架 → 后续

## 4. 架构

### 4.1 架构件清单

| 类型 | 路径 | 说明 |
|---|---|---|
| 新增 hook | `.claude/hooks/guard-env-read.sh` | PreToolUse Read/Edit/Write；匹配 `**/.env*` → allow if in sample list, else exit 2 |
| 新增 script | `.claude/scripts/ack-drift.sh` | 手工 cursor 前推；tty + nonce + append audit log |
| 新增 state | `.claude/state/skill-gate-push-cursor.txt` | 存上次成功 push 时 drift 行数；runtime gitignored |
| 新增 state | `.claude/state/ack-drift-log.jsonl` | ack-drift audit 日志 |
| 改动 settings | `.claude/settings.json` | 删除 `.env` 所有变体枚举（35 条），保留 `Read/Edit/Write(**/.env)` 基础；挂载 guard-env-read 到 PreToolUse[Read,Edit,Write] 无 if |
| 改动 hook | `.claude/hooks/stop-response-check.sh` | drift stderr 格式增强（多行 + drift count + 指令）|
| 改动 hook | `.claude/hooks/guard-attest-ledger.sh` | 加 drift ceiling 检查 + heredoc stripping |

### 4.2 guard-env-read.sh 逻辑

```
输入（stdin JSON）：
  {"tool_name": "Read"|"Edit"|"Write", "tool_input": {"file_path": "/abs/path/or/rel"}}

步骤：
  1. 解析 tool_name + tool_input.file_path
  2. 若 tool_name 不在 {Read, Edit, Write} → exit 0 放行
  3. basename = $(basename "$file_path")
  4. 若 basename 不以 `.env` 开头 → exit 0 放行
  5. 若 basename 精确匹配白名单 {`.env.example`, `.env.sample`, `.env.template`, `.env.dist`} → exit 0 放行 + stderr info
  6. 其他（含 `.env`, `.env.local`, `.env.local.backup`, `.env.abc123`）→ exit 2 + BLOCK 提示
```

**关键**：basename 比对，不依赖 Claude Code 权限 glob 语义。compound suffix 默认 deny。

### 4.3 drift ceiling 机制（H3-2 a3）

`skill-gate-push-cursor.txt` 格式：单行纯数字，表示上次成功 push 时 drift log 的 `wc -l` 值。

guard-attest-ledger.sh scenario A/B/C 开头：
```bash
DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
CURSOR_FILE=".claude/state/skill-gate-push-cursor.txt"
DRIFT_PUSH_THRESHOLD="${DRIFT_PUSH_THRESHOLD:-5}"
current_drift=$([ -f "$DRIFT_LOG" ] && wc -l < "$DRIFT_LOG" | tr -d ' ' || echo 0)
cursor=$([ -f "$CURSOR_FILE" ] && cat "$CURSOR_FILE" | tr -d ' \n' || echo 0)
new_drift=$((current_drift - cursor))
if [ "$new_drift" -gt "$DRIFT_PUSH_THRESHOLD" ] && [ "${DRIFT_PUSH_OVERRIDE:-0}" != "1" ]; then
    block "Skill gate drift count since last push = $new_drift, exceeds threshold $DRIFT_PUSH_THRESHOLD. Run .claude/scripts/ack-drift.sh in real tty to acknowledge + advance cursor, or set DRIFT_PUSH_OVERRIDE=1 in your shell (NOT in Claude Bash tool) to bypass once."
fi
```

Push 成功后（不在 hook 责任内 — push 由 git 处理；hook 只做 pre-check），cursor 不自动前推 — **这是设计**：cursor 只由 `ack-drift.sh` 显式前推。理由：push 成功 ≠ drift 被"认领"；用户应该主动 acknowledge。

### 4.4 ack-drift.sh（同 attest-override ceremony 模式）

```
用户 tty 跑 .claude/scripts/ack-drift.sh
脚本：
  1. 读 drift log 当前行数 = N
  2. 读 cursor 当前值 = M
  3. new = N - M
  4. 若 new == 0 → "nothing to ack"；exit 0
  5. 打印随机 nonce（short sha of drift log tail N 条）
  6. read -p "Type 'ACK-DRIFT-<nonce>' to advance cursor from $M to $N: " ans
  7. 检查 `[ -t 0 ]` + PPID 非 Claude-like（同 attest-override.sh 模式）
  8. ans 正确 → 写入 cursor file：N；append `.claude/state/ack-drift-log.jsonl` 一行 {time, nonce, old_cursor, new_cursor, drift_count, git_user, parent_cmd}
  9. 错误 → exit 非 0，不变 cursor
```

settings.json deny：`Bash(*ack-drift.sh*)`（同 attest-override，Claude 不能调）

### 4.5 heredoc 剥离（H3-3）

guard-attest-ledger.sh `detect_scenario` 开头，先对 CMD 做 heredoc 剥离：

```bash
# Strip heredoc body: match <<TAG ... TAG or <<'TAG' ... TAG or <<-TAG ... TAG
stripped_cmd=$(python3 - <<'PY'
import re, sys
cmd = sys.stdin.read()
# Greedy remove from <<[-]?['"]?TAG['"]? ... \nTAG\n (TAG alphanum)
cmd = re.sub(r"<<-?[\"']?(\w+)[\"']?[^\n]*\n.*?\n\1\s*\n?", " ", cmd, flags=re.DOTALL)
# Also remove heredoc-style `<<(EOF)` inline simpler variants
print(cmd)
PY
<<< "$CMD")
# Use $stripped_cmd for all downstream detect_scenario logic
```

注：Python heredoc 里嵌套 bash heredoc 本身繁琐；impl 可能用 shell awk 替代。Plan 阶段定最终实现。

## 5. 数据流

### 场景 1：Claude Read `.env.production.local`
1. Claude Code PreToolUse Read hook 触发 guard-env-read.sh
2. basename = `.env.production.local`，不在白名单 → exit 2 block
3. Claude 看到 deny 拒绝

### 场景 2：Claude Read `.env.example`
1. 同上 hook 触发
2. basename = `.env.example`，在白名单 → exit 0
3. Claude 正常读

### 场景 3：多 session 累积 drift 后 push
1. hardening-2 drift log 有 9 条（上次 push 时 cursor=7，新 drift=2）
2. Claude 跑 `git push` → guard-attest-ledger 发现 new_drift=2 < threshold 5 → 不拦
3. 但下次漏 4 次（drift=13, new=6 > 5）→ 拦
4. 用户 `ack-drift.sh` → cursor 前推到 13 → 再 push 放行

### 场景 4：Bash 命令 heredoc body 含 `git push`
1. `cat > doc.md <<'EOF' ... git push ... EOF`
2. hook stripped_cmd = `cat > doc.md   ` （heredoc body 剥离）
3. detect_scenario 无 push/pr 匹配 → exit 0 放行

## 6. 异常处理

| 情况 | 行为 |
|---|---|
| drift log 文件不存在 | current_drift = 0；若 cursor 也不存在 → new_drift = 0；不拦 |
| cursor file 损坏（非数字） | fallback 0；stderr warn |
| heredoc 剥离 python3 失败 | fallback：对原 CMD 跑 detect_scenario（退化回当前行为）|
| guard-env-read 路径参数缺失 | exit 2 + "malformed hook input"；fail-closed |
| ack-drift 非 tty | 同 attest-override：`[ -t 0 ]` 断言失败 → exit 5 |
| DRIFT_PUSH_OVERRIDE=1 从 Claude Bash 设置 | 不阻止（Claude 可以自己 export 变量）；但 settings.json deny `Bash(*DRIFT_PUSH_OVERRIDE*)` 应覆盖。具体 pattern 列 plan 阶段 |

## 7. 测试策略

### 单元测试

- `tests/hooks/test_guard_env_read.py`（新）：
  - Read `.env.local` → deny
  - Read `.env.production.local` → deny（compound suffix）
  - Read `.env.example` → allow
  - Read `backend/app/main.py` → allow (non-env)
  - Edit/Write 同样矩阵
  - 6-8 测试

- `tests/hooks/test_stop_response_check.py`（改）：
  - drift stderr 包含 `Drift count since last push: N` 格式
  - 2 测试

- `tests/hooks/test_guard_attest_ledger.py`（改）：
  - drift count < threshold → push pass
  - drift count > threshold → push block
  - threshold override via env var → push pass
  - heredoc body 含 `git push` → scenario detection 跳过
  - 4 测试

- `tests/hooks/test_ack_drift.py`（新）：
  - non-tty stdin → exit 5
  - PPID like claude → exit 9
  - valid tty + nonce → cursor 前推 + audit log 追加
  - 3 测试

- `tests/hooks/test_settings_json_shape.py`（改）：
  - `.env.*` 枚举已删除（assertion）
  - guard-env-read mounted on Read/Edit/Write
  - ack-drift not in allow
  - 3-4 测试

### 集成验证

本 PR 不加 integration test（延 hardening-4 #8）。

## 8. 非 coder 验收清单

（中文；action / expected / pass_fail；无"should work / looks fine"）

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | 让 Claude Read `backend/.env.production.local`（compound suffix） | deny；返回错误 | deny = PASS（hardening-2 会 fall through 到 allow） |
| 2 | 让 Claude Read `backend/.env.example` | 内容返回 | 返回 = PASS |
| 3 | 让 Claude Read `backend/.env.custom_suffix_abc123` | deny | deny = PASS（hardening-2 会 fall through） |
| 4 | 让 Claude 故意漏 6 次 `Skill gate:` 首行然后跑 `git push` | hook block，含 "drift count since last push = 6" 字样 | block + 数字 = PASS |
| 5 | 用户 tty 跑 `.claude/scripts/ack-drift.sh`，敲正确 nonce | cursor 前推；"Cursor advanced from X to Y" | 输出两行匹配 = PASS |
| 6 | 重试 push | pass | pass = PASS |
| 7 | Claude Bash 跑 `cat > /tmp/x.md <<'EOF'\n some text with git push inside\nEOF`（heredoc 里有 `git push` 字面）| hook **不**报 BLOCK_UNPARSEABLE | 成功执行 = PASS |
| 8 | `python3 -m pytest tests/hooks/ -q` | 78 baseline + N 新 = 全绿 | all green = PASS |

## 9. 依赖与边界

- 依赖：hardening-2 merged on main
- 不依赖：新外部工具；OpenAI API
- 与 hardening-4 接口：drift cursor schema / ack-drift audit log schema 稳定，以便将来 CI rollup 读取

## 10. 收敛预期

基于历史：
- hardening-2 spec 2 轮
- hardening-2 plan 2 轮（未真正 code review）
- hardening-2 branch-diff 3 轮不收敛（用户 override 收尾）

本 spec 比 hardening-2 略小（3 item vs 4 item，但机制稍复杂）。估 spec 1-2 / plan 1-2 / branch-diff 可能同样 3 轮 + override。

## 11. Round-by-round responses

### Branch-diff Round 1 (commit 021f410)

| Finding | 处置 |
|---|---|
| H3R1-F1 [critical]: `bash <<EOF git push EOF` executes heredoc body; strip-heredoc hid detection | **修**（`47a584d`）：strip-heredoc.py 增加 `is_executing_heredoc` 检查 prefix token，对 bash/sh/zsh/ksh/python/ruby/perl/node/env 等解释器保留 heredoc |
| H3R1-F2 [high]: `.envrc` / `.envlocal` / `.envsomething` (no-dot suffix) fall through | **修**（`47a584d`）：guard-env-read.sh 案件匹配从 `.env\|.env.*` 拓宽到 `.env*`，所有 `.env` 前缀的 basename 都进检查流程 |

### Branch-diff Round 2 (commit 47a584d)

| Finding | 处置 |
|---|---|
| H3R2-F1 [high]: `cat <<EOF \| sh ... EOF` 管道送 shell 执行；prefix token 是 cat，my check 漏掉 | **修**（`b3c3986`）：strip-heredoc.py 增加 fail-closed 规则——任何命令含 shell 复合构造（\|, &&, \|\|, ;, $(, backtick, &）一律不 strip |

### Branch-diff Round 3 (commit b3c3986)

| Finding | 处置 |
|---|---|
| H3R3-F1 [critical]: `tee >(sh) <<EOF ... EOF` 进程替换 + `xargs sh -c` 等绕过；复合构造清单无法穷尽 | **用户 option A 决策**：drop H3-3 entirely（`7ef43a3`）。Regex-based shell parsing 是 adversarial 不可穷尽领域；每轮 codex 都找新 class。revert 删 strip-heredoc.py + hook prologue 复原。Plan 0a v3 doc-writing workaround 改为 "用 Write 工具写文件"。**H3-3 移入 hardening-4 backlog**，考虑改用 shell parser（tree-sitter-bash 或 shlex+AST）重做。TestHeredocAttacksStillBlocked 新测试验证 BLOCK_UNPARSEABLE fallback 继续拦住实际绕过。 |

Review loop 终止于 round 3。最终 hardening-3 scope = H3-1 (env-guard) + H3-2 (skill-gate drift ceiling + stderr)。
