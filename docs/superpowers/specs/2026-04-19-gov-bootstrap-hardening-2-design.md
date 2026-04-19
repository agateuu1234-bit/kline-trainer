# gov-bootstrap-hardening-2 设计 spec

**Date:** 2026-04-19
**Status:** Draft（待 codex:adversarial-review 收敛 + 用户 approve）
**Scope:** H2-1 (skill gate auto-inject) + H2-2 (parser take-first) + H2-4 (hook shell-op filter) + H2-5 (`.env.example` exemption)
**Out of scope:** H2-3 (branch-diff worktree) / G3 pipeline / subagent enforcement / CI detect / integration tests / allowlist generalization → hardening-3 及以后

**Prereqs:**
- `gov-bootstrap-hardening` (PR #17, commit `56c8d31`) on main — attest-ledger + guard-hook + attest-override 三件套已 live
- `Plan 0a v3` (PR #18, commit `5cd0402`) on main — 期间 inline 5 个 hardening hotfix 已 merge

---

## 1. 背景

`gov-bootstrap-hardening` 首次 bootstrap 暴露 10 条 backlog（见 memory `project_hardening2_backlog.md`）。按 α 策略分轮修，本 PR 修 4 条真痛点：

| ID | 问题 | 用户可感指标 |
|---|---|---|
| H2-1 | Skill gate 首行漏写 hook 只 block 不自愈 | 单 session 26 次违规打断 |
| H2-2 | Codex markdown parser 扫 last `Verdict:` 可被 finding body 污染 | 审查结论可伪造为 approve |
| H2-4 | Hook refspec parser 不过滤 shell 重定向 token | `git push foo 2>&1` 被 hook 错解析 |
| H2-5 | `**/.env.*` deny 误伤 `.env.example` 样例 | 读样例文件 Claude 拒执行 |

剩余 6 条归 hardening-3 等后续。

## 2. 目标

**H2-1**：改 stop-hook 策略从 "block + 等 Claude 重写" → "放行 + append drift log"。仍保留审计，但不打扰工作流。

**H2-2**：Codex verdict parser 取**首条** `Verdict:`（位于 markdown header 位置），并在检测到多个不一致 verdict 时 fail-closed。

**H2-4**：Hook `detect_scenario` 的 refspec 解析显式过滤 `2>&1 >& &> > < | && || ;` 等 shell operator + `origin`/`push` 保留字 + 所有 `-` 开头 flag。

**H2-5**：`.env.example` / `.env.sample` / `.env.template` 恢复可读。通过 **单级后缀枚举**（35 个变体）+ 已知样例不枚举即自动放行。

**H2-5 已知残余**（codex round 1/2 明示 + 本 spec 接受）：
- 复合后缀文件 `.env.local.backup` / `.env.production.local` / `.env.staging.bak` / `.env.abc123`（2 级后缀及以上）不在枚举内，落入 catch-all Read/Edit/Write allow。这是 pure-enumeration 模型的固有局限：笛卡尔积爆炸。**根治**延 hardening-3：PreToolUse Read/Edit/Write hook `guard-env-read.sh`，fail-closed deny `**/.env*` with explicit allow-list `.env.example` / `.sample` / `.template` / `.dist`。
- 本 PR 明示**不承诺** compound-suffix secret file 的读写防护；用户知情接受（单人项目、文件命名惯例以 `.env.local` / `.env.production` 为主，2 级后缀罕见）。

## 3. 非目标（本 PR 显式不做）

- H2-3：branch-diff 模式根治（需引入 detached worktree + `--cwd`，独立设计周期）
- G3：skill pipeline 顺序强制 / task-log.jsonl / skill-invocation verification
- Plan 执行强制 subagent-driven
- CI workflow 里 attest-override 拒跑
- 集成测试框架（用真实 codex-companion CLI record/replay）
- Homebrew Cellar allowlist 通用化

## 4. 架构

### 4.1 新增 / 改动件

| 类型 | 路径 | 说明 |
|---|---|---|
| 改动 hook | `.claude/hooks/stop-response-check.sh` | 不再 block；检测到 drift 则 append 到 `.claude/state/skill-gate-drift.jsonl` |
| 新增 state | `.claude/state/skill-gate-drift.jsonl` | append-only drift 审计日志（已被 gitignore 通配覆盖） |
| 改动 script | `.claude/scripts/codex-attest.sh` | Python 嵌段的 verdict parser 取首条 + fail-closed on duplicate |
| 改动 hook | `.claude/hooks/guard-attest-ledger.sh` | scenario A/B/C refspec 解析加 shell-op 过滤 |
| 改动 settings | `.claude/settings.json` | `**/.env.*` 枚举化：列出所有真实敏感变体 + 不列 example/sample/template |
| 新增 test | `tests/hooks/test_stop_response_check.py` | 测 drift log 追加行为 |
| 改动 test | `tests/hooks/test_codex_attest_ledger_write.py` | 加 parser duplicate 测试 |
| 改动 test | `tests/hooks/test_guard_attest_ledger.py` | 加 shell-op refspec 测试 |
| 改动 test | `tests/hooks/test_settings_json_shape.py` | 加 `.env.example` allow + `.env.local` deny 测试 |

### 4.2 H2-1 stop-hook 重写

```bash
# 现状（简化）：
first_line=$(echo "$last_text" | head -1)
if ! echo "$first_line" | grep -qE '^Skill gate: (...)'; then
  block "首行缺 ..."
fi

# 新版（概念）：
first_line=$(echo "$last_text" | head -1)
if ! echo "$first_line" | grep -qE '^Skill gate: (...)'; then
  # 不 block，改为 drift log
  DRIFT_LOG=".claude/state/skill-gate-drift.jsonl"
  mkdir -p "$(dirname "$DRIFT_LOG")"
  # 从 transcript 反向找最近一条合法 gate
  last_skill=$(python3 ... find last valid Skill gate line in transcript ...)
  [ -z "$last_skill" ] && last_skill="exempt(behavior-neutral)"
  printf '{"time_utc":"%s","first_line":%s,"inferred_skill":"%s","response_sha":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf %s "$first_line" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')" \
    "$last_skill" \
    "$(printf %s "$last_text" | shasum -a 256 | awk '{print $1}')" \
    >> "$DRIFT_LOG"
  echo "[stop-hook] drift logged (inferred: $last_skill); please include 'Skill gate: ...' next time" >&2
fi
exit 0
```

**保留**：exempt 白名单检查仍 block（防白名单理由乱用）。只对"完全漏首行"放行。

### 4.3 H2-2 parser 改写

现状 parser 扫 reversed splitlines 取最后一条 `Verdict:`。

新版：
```python
# Find ALL markdown "Verdict: <label>" occurrences
matches = []
for line in text.splitlines():
    m = re.match(r'^Verdict:\s*(approve|needs-attention|request-changes|reject|block)\s*$', line.strip())
    if m:
        matches.append(m.group(1))

if matches:
    if len(set(matches)) > 1:
        # Ambiguous: finding body or quoted text contains a different verdict than header
        print("ambiguous")
        sys.exit(0)
    print(matches[0])
    sys.exit(0)

# fall through to JSON fallbacks (unchanged)
```

外层脚本逻辑：`VERDICT != "approve"` → `exit 7`（已有行为），台账不更新。`ambiguous` 自动走该分支（非 approve）。

### 4.4 H2-4 hook shell-op 过滤

现状（guard-attest-ledger.sh scenario A refspec 解析）：
```bash
SRC_BRANCH=$(echo "$CMD" | awk '{
    for(i=NF;i>0;i--){
        if(substr($i,1,1)!="-"&&$i!="origin"&&$i!="push"){print $i;exit}
    }
}')
```

新版加 shell-op blacklist：
```bash
SRC_BRANCH=$(echo "$CMD" | awk '{
    for(i=NF;i>0;i--){
        tok=$i
        # Skip shell redirects/operators/keywords
        if(tok=="2>&1"||tok==">&"||tok=="&>"||tok==">"||tok=="<"||tok=="|"||tok=="&&"||tok=="||"||tok==";"||tok=="origin"||tok=="push") continue
        if(substr(tok,1,1)=="-") continue
        # Also skip tokens that LOOK LIKE redirects embedded (> + filename)
        if(tok ~ /^[0-9]*>&?[0-9]*$/) continue
        print tok; exit
    }
}')
```

同样过滤应用到 scenario B 的 `--head` 值解析（虽然 `--head` 后紧跟合法分支，但防御性一致）。

### 4.5 H2-5 `.env.example` 豁免

**删除** `.claude/settings.json` `deny` 中 3 条泛匹配（Read/Edit/Write `**/.env.*`）+ 对应 Bash 路径（`Bash(cat **/.env*)` 等如果用的是 `.*` 形式的也列入）。

**新增** 枚举版 deny：
```json
// Read
"Read(**/.env)",
"Read(**/.env.local)",
"Read(**/.env.dev)",
"Read(**/.env.development)",
"Read(**/.env.prod)",
"Read(**/.env.production)",
"Read(**/.env.staging)",
"Read(**/.env.test)",
"Read(**/.env.testing)",
"Read(**/.env.secret)",
"Read(**/.env.secrets)",
"Read(**/.env.override)",
"Read(**/.env.private)",
"Read(**/.env.local.*)",
// 相同枚举应用到 Edit(...) / Write(...)
// Bash
"Bash(cat **/.env)",
"Bash(cat **/.env.local)",
// ... (对每个 env 变体同 Bash cat)
```

**NOT-denied**（有意）:
- `**/.env.example`
- `**/.env.sample`
- `**/.env.template`
- `**/.env.dist`

这些样例文件自动通过 catch-all `Read` / `Edit` / `Write` allow 放行。

**Tradeoff**：枚举增加长度；优点是每个 deny 意图清晰 + example 类样例自然可读。

## 5. 数据流

### H2-1 flow（有人漏首行）

1. Claude 回复首行非 `Skill gate:`
2. Stop hook 读 transcript 最近 20 条 assistant 消息
3. 反向找首条首行合法的 Skill gate → 取 skill name
4. 写一行 JSON 到 `.claude/state/skill-gate-drift.jsonl`，含：time / 错首行 / 推断 skill / response sha
5. stderr warn 但 exit 0 放行
6. Claude 收到 warn，下一条回复应自觉补回 gate

### H2-2 flow（codex 有双 Verdict: 行）

1. codex-companion render markdown：header `Verdict: approve` + 后面 finding body 含 `"Verdict: needs-attention"` 引用
2. 新 parser 收集所有匹配行：`[approve, needs-attention]`
3. `set() = 2 个` → `print("ambiguous")`
4. 外层脚本 `VERDICT="ambiguous" != "approve"` → `exit 7`，台账不更新
5. 用户看到"verdict=ambiguous (not approve); ledger not updated"，知道要查真实 verdict

### H2-4 flow（Claude push 时带 `2>&1`）

1. Claude 的 Bash 工具跑 `git push -u origin feat 2>&1`
2. Hook 收到 `tool_input.command` = 该字串
3. detect_scenario 返回 A（git push prefix 匹配）
4. scenario_A 解析 refspec：新 parser 跳过 `2>&1`，取到 `feat`
5. 正常 ledger 检查 + 放行/拦截

### H2-5 flow（Claude 读 `.env.example`）

1. Claude Read tool `backend/.env.example`
2. 权限裁决：
   - `**/.env.example` 不在 deny（被删除枚举外）
   - 在 catch-all `Read` allow 内 → 放行
3. 内容返回 Claude

## 6. 异常处理

| 情况 | 行为 |
|---|---|
| Drift log 写入失败 | stderr warn；不 block hook |
| Transcript 反向扫描找不到任何 gate | 推断值设 `exempt(behavior-neutral)`，drift 仍记 |
| Codex 无 `Verdict:` 行 | parser 走 JSON fallback（原逻辑保留） |
| Shell-op 过滤后没剩任何 token | SRC_BRANCH 回退 `current HEAD`（原逻辑保留） |
| `.env.example` 改写后仍被某个 trust-boundary 路径 deny | 人工验证：test_settings_json_shape 加 assertion |

## 7. 测试策略

### 单元测试

`tests/hooks/test_stop_response_check.py`（新）：
- 首行合法 → exit 0 / 不写 drift log
- 首行缺失 → exit 0 + drift log 追加 1 行 + stderr 有"drift logged"
- exempt reason 不在白名单 → 仍 block（这条不受本 PR 改动影响）
- 反向扫描：transcript 含多条 assistant 消息，前面有 `Skill gate: superpowers:brainstorming` → drift log 里推断为 `superpowers:brainstorming`

`tests/hooks/test_codex_attest_ledger_write.py`（改）：
- 加 `TestVerdictParserFirstLine`：stub output with single header `Verdict: approve` → 返回 approve
- 加 `TestVerdictParserFailClosedOnDuplicate`：stub output with header `Verdict: approve` + body `Verdict: needs-attention` → 返回 `ambiguous` → 外层 exit 7 → ledger 不写

`tests/hooks/test_guard_attest_ledger.py`（改）：
- 加 `TestShellOpsFilterP1F4` / `TestShellRedirectFilter`：命令尾含 `2>&1`、`>&`、`&>`、`| cat` 等各变体 → 解析出真正 src-branch，不是 shell op

`tests/hooks/test_settings_json_shape.py`（改）：
- 加 `TestEnvExampleExemption`：
  - `Read(**/.env.example)` 不在 deny
  - `Read(**/.env.local)` 在 deny
  - `Read(**/.env)` 在 deny
  - `**/.env.*` 泛匹配**不再**出现在 deny（防 regression）

### 集成测试

本 PR 不加（归 hardening-3 的 #9）；依赖现有单元测试 + 手工 acceptance。

## 8. 非 coder 验收清单

（中文；action / expected / pass_fail；禁用"通过即可 / 看起来正常"等）

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | 在当前 Claude session 让我故意漏一次 `Skill gate:` 首行，查 `.claude/state/skill-gate-drift.jsonl` | 文件存在且末行是本次的 drift 记录（含 time / 错首行 / 推断 skill） | 行数 +1 且字段齐 = PASS |
| 2 | 查 stop-hook 退出码：应为 0（放行而非 block） | `echo $?` 非 2 即可 | exit 0 = PASS |
| 3 | 跑 `python3 -m pytest tests/hooks/test_codex_attest_ledger_write.py::TestVerdictParserFailClosedOnDuplicate -v` | 测试通过（parser 在 duplicate 时返回 ambiguous，外层 exit 7） | PASS |
| 4 | 让 Claude 跑 `git push -u origin some-branch 2>&1` 变体 | hook 解析 src-branch 为 `some-branch`（不是 `2>&1`），BLOCK 消息含正确 branch 名 | 正确 branch = PASS |
| 5 | 让 Claude `Read backend/.env.example` | 直接返回内容，无 ask 弹窗 | 返回内容 = PASS |
| 6 | 让 Claude `Read backend/.env.local` 或 `Read backend/.env` | deny 拒绝 | 拒绝 = PASS |
| 7 | 跑 `./scripts/acceptance/plan_0a_toolchain.sh` | 仍 `PLAN 0A PASS`（本 PR 不改 acceptance 契约） | PASS |
| 8 | 跑 `python3 -m pytest tests/hooks/ -q` | 全部 passing（原 61 + 本 PR 新增 N） | all green = PASS |

## 9. 依赖与边界

- **依赖**：hardening + Plan 0a v3 已 merged on main。本 PR 在此基础上增量。
- **不依赖**：新的外部工具 / 新的 codex-companion 版本。
- **与 hardening-3 接口**：drift log schema 稳定，以便未来 hardening-3 做 per-session drift rollup 或 CI 报告。

## 10. 收敛预期

基于历史：
- hardening spec 走 6 轮
- hardening plan 走 2 轮
- Plan 0a v3 branch-diff 走 3 轮

本 spec scope 比 hardening 小 3-5 倍，预期：
- spec 1-2 轮收敛
- plan 1 轮收敛

若超过，按 `workflow-rules.adversarial_review_loop.on_non_convergence` escalate。

## 11. Round-by-round responses

### Branch-diff Round 3 (commit 4ae8934)

触 `adversarial_review_loop.max_rounds=3` 上限。Codex 重复 F1/F2 同等意见不收敛。按 `on_non_convergence` escalate 用户裁决 → 用户 2026-04-19 选 **A**：接受两条 residual 交付本 PR，走 `attest-override.sh` ceremony。

| Finding | 处置 |
|---|---|
| H2R3-F1 [high]: env enumeration 对 compound suffix fall-through | **继承接受 residual**（同 H2R2-F1），不改本 PR。hardening-3 补 fail-closed `guard-env-read.sh` hook |
| H2R3-F2 [high]: drift-log 非 hard-enforce | **继承接受 residual**（同 H2R2-F2 + 用户原始 Q2=d 授权）。policy 文本（workflow-rules + CLAUDE.md §4）已对齐。hardening-3 可选实施"auto-inject 替代 drift-log" + CI rollup |

Review loop 终止于 round 3 / 用户选项 A。

### Branch-diff Round 2 (commit 868385d → 接受后 policy 对齐补丁见后续 commit)

| Finding | 处置 |
|---|---|
| H2R2-F1 [high]: 复合后缀 `.env.local.backup` / `.env.production.local` / `.env.staging.bak` / `.env.abc123` 不在枚举 → fall through | **接受为 residual**（γ 方案，用户 2026-04-19 授权）。本 spec §2 H2-5 已新增 compound-suffix residual 明示段 + 指向 hardening-3 `guard-env-read.sh` fail-closed hook 作为根治路径。本 PR 不做 cartesian-product 枚举（会爆炸），也不 shipping fail-closed hook（scope 扩张）。 |
| H2R2-F2 [high]: stop-hook drift-log = policy bypass | **接受 push-back + 补 policy 对齐**：本 commit 同步更新 `.claude/workflow-rules.json` `skill_gate_policy` 新增 `enforcement_mode: "drift-log"` + `enforcement_description` + `future_hardening_3_scope`；更新 `CLAUDE.md §governance §4` 明示 drift-log 语义。政策文本现与 hook 代码一致，不再 internal inconsistent。 |

### Branch-diff Round 1 (commit 8516cd5)

| Finding | 处置 |
|---|---|
| H2R1-F1 [high]: `.env.ci` / `.env.qa` / `.env.uat` / `.env.preview` / `.env.backup` 未枚举 → fall through 到 catch-all allow | **接受 + 修**（commit `67c12fc`）：enumeration 扩展 23 个变体（ci/qa/uat/preview/stage/pre, backup/bak/old/orig, shared/personal/remote, heroku/vercel/netlify/fly/render/railway, docker/compose/k8s, nas）。新测试 `test_env_ci_and_ops_variants_denied_H2R1` 覆盖。**残余风险**：真正未知的自定义后缀（如 `.env.abc123`）仍会 fall through；根治方案 = content-aware 样例识别 hook，延 hardening-3 |
| H2R1-F2 [high]: skill-gate stop-hook drift-log 不 block 等于绕过 pipeline | **不接受（push-back）**。此设计是用户在本 spec brainstorm Q2 里**显式选择的方案 d**（"自动推断 skill + drift log + `auto-injected` 审计标签"）。理由：spec §2 用户语境下本 session 观察到 29 次违规打扰；"fail-closed"方案已被证明对 Claude 的注意力扛不住依赖；drift log 保留审计可追溯，且后续 session 可统计读 log 做 rollup。本 PR 明示**不承诺** hard-block 政策；policy 文本对应调整应与此 PR 同步。如 reviewer 坚持此为 blocker，escalate 用户重新裁决 Q2 |

（后续 rounds 的 findings + 处置按需追加）
