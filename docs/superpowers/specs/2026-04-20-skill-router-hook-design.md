# Skill Router Hook · 入口提醒设计

**日期**：2026-04-20
**状态**：Draft（codex:adversarial-review 进行中，Round 1 已完成）
**分类**：governance / process / toolchain change
**分支**：`gov/skill-router-hook`
**作者**：Claude（起草），Codex（对抗性 review 执行中）
**关联治理**：这是 gov-bootstrap-hardening-4 合并后的**第一个痛点驱动**治理增量；明确**不属于** hardening 系列延续（hardening-5 已于 2026-04-20 终止）。

> **⚠️ 重要边界声明**：本 spec 是**提醒（reminder）**而非**强制（enforcer）**。用户 § 1 需求 1 原话是"Hook 强制执行"，但经 § 3 tradeoff 显式评估后，用户选择**方案 D（软注入 + 自律）**而非强制拦截。本 spec 的名字从"入口守卫"改为"入口提醒"以反映真实行为。强化到硬拦截是显式的**将来升级路径**（§ 7.2 情形 A/B），不在本次 scope。

---

## 0. 背景

### 0.1 为什么现在做

现有 skill-gate 机制（`stop-response-check.sh` + `skill-gate-drift.jsonl`）**只检查 Claude 回复首行有没有声明 skill，不检查 Claude 有没有先触发对的 skill**。失败模式：

1. 长对话里 Claude 淡忘 SessionStart 注入的规则 → 直接写代码，跳过 brainstorming
2. 简单请求 Claude 过度 exempt → 漏用应该用的 skill
3. 首行声明 ≠ 实际执行：声明 `superpowers:brainstorming` 但并未调用 skill 工具

用户 2026-04-20 会话中指出："有时候会调用，有时候不会调用"——直接对应失败模式 1。

### 0.2 本设计的 scope（窄）

**只解决"入口触发"问题**（Option D / 方案 4）：每次用户消息前注入固定提醒，强化 Claude 的分类与声明自觉。

**明确不在本 scope**（将来按痛点增量）：
- 外部分类器（关键词规则 / Codex 分类）→ 方案 1/2/3
- 管线阶段守卫（task-log.jsonl + 阶段证据）→ H5 未达成的目标
- F1 residual（codex-attest 防伪）→ 独立议题

### 0.3 与 hardening-5 的界限

H5 尝试构建阶段守卫（task-log.jsonl + 每阶段证据比对），跑 11 轮 Codex review 未收敛，于 2026-04-20 中止。

本 spec **刻意不触碰 H5 涉及的任何机制**：无 task-log.jsonl、无阶段证据、无 hook-owned state 写入。本 spec 新增的 `.claude/hooks/user-prompt-skill-reminder.sh` 是**无状态的纯文本注入**，独立于 H5 域。这是为避免重蹈 H5 收敛性陷阱的显式设计选择。

---

## 1. 用户需求（原话精炼）

1. Hook **强化** superpowers 工作流触发；不完全靠 Claude 自律
   - 原话是"强制"，但 § 3 tradeoff 里用户显式选择**方案 D（软提醒 + 现有 drift-log）**而非方案 B/C（硬拦截）
   - 本 spec 只满足"强化"，**不满足"强制"**——强制是后续升级路径
2. 所有 review 由 Codex 做（保留，本 spec 将进 codex-attest review）
3. **不打扰用户**——Codex 3 轮收敛就自动进下一步
4. **简单优先**——已觉得现有治理太复杂，不再堆
5. **痛点驱动**——今天只修今天遇到的痛（"hook 有时候没触发对的 skill"）
6. 最终 PR/merge 仍走现有 `gh pr merge` + `ask` 权限 + 用户 CODEOWNERS Approve
7. 代码审查继续走 `codex-attest.sh` shell 路径，不切到 `codex:adversarial-review` skill 路径（不降低防伪）

### 1.1 需求 1 与方案 D 之间的显式 gap

| 维度 | 用户原话要的（需求 1） | 方案 D 实际给的 | Gap |
|---|---|---|---|
| 触发强化 | 强制 | 软提醒注入 | 方案 D 给 |
| 错 skill 自动抓 | 期望（隐含） | 放弃外部校验 | **方案 D 不给** |
| 跳过 skill 时硬拦 | 期望（隐含） | fail-open 不拦 | **方案 D 不给** |
| 错用 exempt 时抓 | 期望（隐含） | 靠用户肉眼 | **方案 D 不给** |

此 gap **不是 bug、是显式 tradeoff**。接受此 gap 的理由见 § 3；若此 gap 上线后痛，按 § 7.2 升级到方案 1/3。

---

## 2. 核心设计洞察

**真实失败模式是"遗忘"而不是"故意违规"**。

系统 prompt + CLAUDE.md + SessionStart hook 注入的规则，在长对话里会被 Claude 淡忘。外部分类器（方案 1/2）能抓"错分类"，但代价是分类器本身的维护成本 + false positive 误伤。

**最小可行干预 = 每轮对话前重新注入提醒**。不做分类、不建状态、不对比校验，只是**提高规则在 Claude 当前注意力窗口中的权重**。放弃外部审计精度（换简单性）是显式、经过 tradeoff 评估的设计选择。

---

## 3. 根本 tradeoff（方案 4 定稿）

| 对立面 | 本 spec 选择 |
|---|---|
| 准确分类 vs 简单实现 | **简单**：不分类，只提醒 |
| 外部审计 vs 自律 | **自律**：放弃"Claude 声明 vs 应有 skill"的外部比对 |
| 精度 vs 误伤 | **零误伤**：无外部判据 = 无 false positive |
| 立即发现错配 vs 事后观察 | **事后**：你肉眼监督；未来痛点驱动再升级 |
| 强制力 vs 不打扰 | **软注入**：hook fail-open；最坏退回到今天的状态 |

---

## 4. 工件清单

### 4.1 § 1 架构

```
用户消息
   │
   ▼
UserPromptSubmit hook（新）
   │   .claude/hooks/user-prompt-skill-reminder.sh
   │   作用：cat stdin（不解析）+ echo 固定提醒文本 + exit 0
   │
   ▼
Claude 收到：用户消息 + hook 注入的提醒
   │   按提醒的 skill_entry_map 自分类
   │   首行声明 `Skill gate: <skill>` 或 `Skill gate: exempt(<reason>)`
   │
   ▼
Claude 执行工作
   │
   ▼
Stop hook（现有 stop-response-check.sh，不改）
   │   查首行语法 + 白名单 exempt reason
   │
   ▼
skill-gate-drift.jsonl（若首行漏/不合法 → 记录）
```

**关键不变量：**

- **只新增 1 个 hook**，现有 7 个全部不动
- **无 state 文件**，无分类逻辑，hook 是无状态的
- **Stop hook 不改**（自分类对错靠 Claude + 用户肉眼）
- **每轮消息都提醒**，不走"短消息跳过"之类的条件化（避免新判断逻辑）

### 4.2 § 2 组件

**新增：**

| 路径 | 类型 | 用途 |
|---|---|---|
| `.claude/hooks/user-prompt-skill-reminder.sh` | bash 脚本 | UserPromptSubmit hook 实现 |
| `tests/hooks/test-user-prompt-skill-reminder.sh` | bash 测试 | 4 个用例，含反漂移守卫 |

**修改：**

| 路径 | 变更 |
|---|---|
| `.claude/settings.json` | 新增 `UserPromptSubmit` hook 节点，timeout=2s |

**不修改：**

- 现有 7 个 hook 脚本全部不动
- `.claude/workflow-rules.json` 不动（`skill_entry_map` 已存在，提醒文本从其语义中派生但不读取）
- `CLAUDE.md` 不动（§ 0.2 scope 边界）
- `stop-response-check.sh` 不动

**Trust boundary：**

- `.claude/hooks/**` 和 `.claude/settings.json` 均在 `trust_boundary_globs` → 本 PR 需 Codex adversarial review
- `.claude/hooks/**` 在 `codeowners_required_globs` → merge 需用户 CODEOWNERS Approve
- `codex-attest.sh` 要求对 spec + plan 做 file-level attest

**settings.json 变更预览：**

```json
"hooks": {
  "UserPromptSubmit": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "bash .claude/hooks/user-prompt-skill-reminder.sh",
          "timeout": 2
        }
      ]
    }
  ]
  // 其余现有 hook 节点保持不变
}
```

### 4.3 § 3 数据流

**3.1 hook 执行流程**

```
Claude Code 触发 UserPromptSubmit
  ↓ 传 {"prompt": "<用户原话>", ...} 到 hook stdin
  ↓
user-prompt-skill-reminder.sh:
  1. 读 stdin 丢弃（只为避免 pipe buffer 阻塞）
  2. echo 固定提醒文本（heredoc）
  3. exit 0
  ↓
Claude 收到：用户消息 + hook stdout 内容
```

**3.2 提醒文本来源**

**决策：硬编码在 hook 脚本里**（`<<'EOF'` 形式 heredoc，禁用变量展开）。

对比过的方案：

| 来源 | 选 / 弃 | 理由 |
|---|---|---|
| 硬编码 heredoc | ✅ | 零依赖、单文件、调试可读 |
| 运行时读 `workflow-rules.json` | ❌ | 需 jq；解析失败风险；慢 50-100ms |
| 独立模板文件 | ❌ | 多一个文件；增加 codex review surface |

同步风险（skill_entry_map 变更时提醒文本不同步）由 § 5 反漂移测试守卫。

**3.3 提醒文本内容**

```
[skill-router] Choose the correct skill before acting. Match your request against:

  • New feature / component / behavior change  → superpowers:brainstorming
  • Execute an approved plan                    → superpowers:writing-plans
                                                  superpowers:executing-plans
  • Execute plan with independent subtasks      → superpowers:subagent-driven-development
  • 2+ independent investigations               → superpowers:dispatching-parallel-agents
  • Write production code (feature/bug/refactor)→ superpowers:test-driven-development
  • Bug / test failure / unexpected behavior    → superpowers:systematic-debugging
  • Before claiming done / passing / commit     → superpowers:verification-before-completion
  • UI / frontend code                          → frontend-design:frontend-design
  • Self-review before merge                    → superpowers:requesting-code-review
  • Receive review feedback                     → superpowers:receiving-code-review
  • Create / modify a skill                     → superpowers:writing-skills
  • Multi-PR parallel / isolation needed        → superpowers:using-git-worktrees
  • Finishing a development branch              → superpowers:finishing-a-development-branch
  • Session start / cross-session resume        → superpowers:using-superpowers
  • Governance / hooks / workflow rules change  → superpowers:brainstorming  then
                                                  codex:adversarial-review
  • Read-only query / trivial one-step          → exempt(read-only-query) or
                                                  exempt(single-step-no-semantic-change)

First line of your response MUST be exactly:
  Skill gate: <skill-name>
OR:
  Skill gate: exempt(<whitelist-reason>)

Whitelist reasons: behavior-neutral | user-explicit-skip | read-only-query |
                   single-step-no-semantic-change
```

**覆盖范围说明**：提醒文本包含 `skill_entry_map` 里所有 non-exempt 路由值，跨 `superpowers:*`、`frontend-design:*`、`codex:*` 三个 namespace。T4 测试强制双向覆盖（见 § 5）。

**3.4 触发频率**

**无条件触发**，每条用户消息都注入提醒。不做"短消息跳过"或"会话前 N 轮"之类条件化，原因：

- 任何条件化都引入新判断逻辑（退化为方案 1 的分类问题）
- 短回复（"ok"/"继续"）情境下 Claude 可合法声明 `exempt(single-step-no-semantic-change)`，无额外负担
- 上下文开销评估见 § 7.1

**3.5 不改变的既有数据流**

- `stop-response-check.sh` 继续查首行 + 维护 drift-log
- `skill-gate-drift.jsonl` 继续积累事后审计
- 其余 hook 链路不受影响

### 4.4 § 4 错误处理

| 失败情形 | 处理 |
|---|---|
| stdin 空 / JSON 损坏 | 不解析，丢弃 → 不会 fail |
| echo / heredoc 自身失败 | bash 进程挂 → exit != 0 → Claude Code 报 hook 失败；**不阻止** Claude 回复（UserPromptSubmit 非阻塞型） |
| 超时（> 2s） | 极不可能——hook 只 cat+echo；timeout=2s 硬杀 |
| shell 特殊字符被误展开 | heredoc 使用 `<<'EOF'`（单引号）完全禁用变量展开和命令替换 |
| 脚本权限缺失（不可执行） | Claude Code 报错；**不影响** Claude 回复；降级到"无提醒"（= 今天现状）|
| hook 文件被误删 | 同上，降级 |

**降级策略：** 任何失败 **fail-open**（不阻塞用户请求）。本 hook 是**提醒层**，不是安全门；失败等价于回退到 spec 实施前的状态。

### 4.5 § 5 测试策略

**文件：** `tests/hooks/test-user-prompt-skill-reminder.sh`

**5 个用例：**

```bash
# T1: 正常跑，输出非空，exit 0
echo '{"prompt":"任意消息"}' | bash .claude/hooks/user-prompt-skill-reminder.sh
assert exit_code == 0
assert stdout non-empty

# T2: 输出包含关键锚点
stdout | grep -q "Skill gate:"
stdout | grep -q "superpowers:brainstorming"
stdout | grep -q "exempt("

# T3: 不卡 stdin（垃圾输入不 hang）
echo "non-json garbage" | timeout 3 bash .claude/hooks/user-prompt-skill-reminder.sh
assert exit_code == 0  # timeout 超时会返回 124

# T4（反漂移守卫 · 双向）: skill_entry_map 里所有 non-exempt 值都必须在 hook 文本里出现；反之亦然
#
#   方向 A：hook → map（hook 文本里引用的必须是 map 里存在的，防拼错）
#   方向 B：map → hook（map 里所有 non-exempt 路由必须在 hook 文本里，防遗漏）
#
# 覆盖所有 namespace：superpowers:* / frontend-design:* / codex:* 以及未来新增

expected_skills=$(jq -r \
  '.skill_entry_map | to_entries | map(.value) | .[] | select(startswith("(exempt") | not)' \
  .claude/workflow-rules.json | sort -u)

actual_skills=$(grep -oE '(superpowers|frontend-design|codex):[a-z-]+' \
  .claude/hooks/user-prompt-skill-reminder.sh | sort -u)

# 方向 A
for s in $actual_skills; do
  echo "$expected_skills" | grep -Fxq "$s" || fail "T4A: $s in hook but not in skill_entry_map"
done

# 方向 B
for s in $expected_skills; do
  echo "$actual_skills" | grep -Fxq "$s" || fail "T4B: $s in skill_entry_map but not in hook"
done

# T5（settings 挂载守卫·新增 · Codex R1-F2 + R2-F1 修复）:
# settings.json 必须真的挂载了这个 hook，防止测试通过但 hook 从未被触发
#
# R2-F1 修复：原先的 jq 链式表达式语法错误
#   `.hooks.UserPromptSubmit | type == "array" and length > 0 | .hooks[0].hooks[] | select(...)`
# 会把 `type == "array" and length > 0` 的布尔值当作下一步的输入，导致
# "Cannot index boolean with string" 错误。拆成两步独立的 jq -e 判断。

# 步骤 1：UserPromptSubmit 节点必须是非空数组
jq -e '.hooks.UserPromptSubmit | type == "array" and length > 0' \
  .claude/settings.json > /dev/null \
  || fail "T5-a: .hooks.UserPromptSubmit is not a non-empty array"

# 步骤 2：至少有一条 hook 条目 command + timeout + type 三项全对
jq -e '
  .hooks.UserPromptSubmit[]?.hooks[]?
  | select(.command == "bash .claude/hooks/user-prompt-skill-reminder.sh"
        and .timeout == 2
        and .type == "command")
' .claude/settings.json > /dev/null \
  || fail "T5-b: no UserPromptSubmit hook entry with correct command/timeout/type"
```

**反漂移守卫 T4 双向作用：**
- **方向 A**：hook 里写了 `superpowers:brainstormingXXX` 但 map 没这个值 → fail（防拼错）
- **方向 B**：map 新增 `ui_frontend_code` 路由到 `frontend-design:frontend-design`，但 hook 没更新 → fail（防遗漏，Codex R1-F3 识别的真实漏洞）

**挂载守卫 T5 作用：** 保证 `.claude/settings.json` 里有正确 wire 的 UserPromptSubmit 节点（command / timeout / type 三项都对）；防止 hook 文件存在但 Claude Code 运行时根本不触发（Codex R1-F2 识别的漏洞）。

**不测的（显式放弃）：**

- 不测"Claude 收到提醒后行为是否改变"——LLM 非确定性，不可靠单元测试；靠 drift-log 事后统计
- 不测"Claude 实际在新会话里声明首行是对的"——这是 § 6 验收 3 的端到端手工步骤，不在自动化测试范畴

### 4.6 § 6 验收清单（Phase Delivery · 中文三段式 · 用户执行）

phase_delivery: true；验收内容为**机制验证**（非业务功能）。

#### 验收 1：Hook 脚本文件落地

**动作（Action）：**
1. 终端：`ls -l .claude/hooks/user-prompt-skill-reminder.sh`
2. 终端：`bash tests/hooks/test-user-prompt-skill-reminder.sh`

**预期（Expected）：**
1. 第 1 条命令输出一行，包含文件名且权限含 `x`
2. 第 2 条命令最后一行显示 `All 5 tests passed`

**通过判据（Pass/Fail）：**
- 通过：两条命令均按预期输出
- 失败：任一条缺失文件 / 报错 / 测试未全部 pass

#### 验收 2：`settings.json` 正确挂载

**动作：**
1. 打开 `.claude/settings.json`
2. 搜索 `UserPromptSubmit`

**预期：**
1. 文件里有 `UserPromptSubmit` 节点
2. 节点下 `command` 值为 `bash .claude/hooks/user-prompt-skill-reminder.sh`
3. `timeout` 值为 `2`

**通过判据：**
- 通过：三条全部命中
- 失败：任一条不符 / 节点不存在

#### 验收 3：新会话中 hook 生效（端到端）

**动作：**
1. 开一个**全新** Claude Code 会话
2. 第一句话输入：「帮我加一个新功能：RSI 指标的计算模块」
3. 看 Claude 回复的**第一行**

**预期：**
1. Claude 回复第一行是 `Skill gate: superpowers:brainstorming`
2. Claude 随后行为是进入 brainstorming 流程（问你问题、不直接写代码）

**通过判据：**
- 通过：首行字符串**精确等于** `Skill gate: superpowers:brainstorming` **且** Claude 没有直接开写代码
- 失败：首行是别的 skill / 首行缺失 / Claude 忽略提醒直接改文件

#### 验收 4：只读请求识别正确

**动作：**
1. 同一会话继续输入：「查一下当前分支叫什么」
2. 看 Claude 回复的第一行

**预期：**
1. Claude 回复第一行是 `Skill gate: exempt(read-only-query)` 或 `Skill gate: exempt(single-step-no-semantic-change)`
2. Claude 用 1-2 个 bash 命令直接回答，不启动 brainstorming

**通过判据：**
- 通过：首行 exempt + 白名单 4 reason 之一；行为简短直接
- 失败：首行声明 skill 把简单查询复杂化 / 首行缺失

#### 验收 5（反漂移守卫）：改 workflow-rules.json 要同步 hook

**动作：**
1. 临时改 `.claude/workflow-rules.json`，把 `skill_entry_map` 里任意 `superpowers:brainstorming` 值改成 `superpowers:brainstormingXXX`
2. 跑 `bash tests/hooks/test-user-prompt-skill-reminder.sh`
3. 改回原样

**预期：**
1. T4 fail，输出提示 `skill ...XXX not in skill_entry_map`

**通过判据：**
- 通过：测试 fail 到 T4
- 失败：测试全 pass（反漂移守卫形同虚设）

### 4.7 § 7 风险 + 回滚

#### 7.1 已识别风险

| 风险 | 严重度 | 处理 |
|---|---|---|
| **上下文污染**（提醒 ~300 tokens × 每轮） | 低-中 | 实测 100 轮 ≈ 30k，Claude Code 1M context 可承受；触压缩再动态化 |
| **Claude 过度 exempt** | 中 | 你肉眼能看到，口头纠正；多了就切换到方案 1+4 混合（加关键字判据） |
| **Claude 忽略提醒**（类似 H2 硬拦失效） | 中 | H2 硬拦失败，但本方案是**软注入 + 首行强制声明**双重机制，理论上比 H2 场景更强 |
| **误报无法自动抓**（架构缺陷） | 中 | 明知代价；接受；按痛点再决定升级 |
| **hook 挂了降级无提醒** | 低 | fail-open 设计；等价于 spec 实施前状态；零破坏 |
| **未来多个 UserPromptSubmit hook 冲突** | 低 | 当前第一个此类 hook；后续按 settings.json 声明顺序执行 |

#### 7.2 触发升级方案的条件

上线 1-2 周后：
- **情形 A**：误报率 > 20%（Claude 频繁 exempt 偷懒）→ 升级到**方案 1**（加关键字判据）
- **情形 B**：首行声明正确率 < 80% → 方案 4 失败，考虑方案 3 或回退到只靠 SessionStart
- **情形 C**：上下文压缩触发 → 改条件化注入（只在会话前 N 轮）

#### 7.3 回滚手顺

1. `git revert <merge-commit-sha>`
2. 删除 `.claude/hooks/user-prompt-skill-reminder.sh`
3. 从 `.claude/settings.json` 移除 `UserPromptSubmit` 节点
4. 删除 `tests/hooks/test-user-prompt-skill-reminder.sh`
5. **无 state 清理**：本 hook 不写 `.claude/state/*`
6. 现有 `stop-response-check.sh` + `skill-gate-drift.jsonl` 继续工作

回滚代价**极低**：无数据迁移、无副作用、无下游依赖。

---

## 5. 落地序列

1. 本 spec commit 到 `gov/skill-router-hook` 分支
2. 跑 `codex-attest.sh --scope working-tree --focus docs/superpowers/specs/2026-04-20-skill-router-hook-design.md` → Codex 对抗性 review 第 1 轮
3. 根据 Codex findings 修订 / push back（记录每轮响应）
4. 最多 3 轮：
   - 收敛 → 进入 `superpowers:writing-plans` 写实施 plan
   - 不收敛 → **升级给用户**（附 verdict 序列 + 未解 findings + Claude rationale + tradeoff + bypass 选项）
5. Plan 也走同样 codex-attest 3 轮流程
6. TDD 执行 plan，写 hook + 测试 + 改 settings.json
7. 代码 PR 走 guard-attest-ledger.sh 守卫的正常 push → codex review PR → CODEOWNERS Approve → `gh pr merge` (`ask` 权限弹你确认)
8. merge 后在新会话中执行 § 4.6 验收 1-5

---

## 6. 未决项（留给 writing-plans 阶段细化）

1. hook 脚本具体代码（heredoc 精确排版）
2. 测试脚本 assertion 辅助函数（bash `set -e` + `assert_eq` 风格）
3. settings.json diff 的具体位置（UserPromptSubmit 节点插入位置）
4. 提醒文本里是否需要项目特定的 skill（如 `frontend-design:frontend-design`、`codex:adversarial-review`）的显式列举
5. 是否需要 `.claude/hooks/user-prompt-skill-reminder.sh` 加可执行位（chmod +x）的落地步骤

---

## 7. 非目标（显式声明）

- ❌ 不替换 / 削弱现有 7 个 hook
- ❌ 不动 `codex-attest.sh` / `attest-ledger.json`（和 F1 residual 无关）
- ❌ 不改 `stop-response-check.sh` 的声明检查逻辑
- ❌ 不做"Claude 声明的 skill 是否等于应调 skill"的外部校验（方案 4 显式放弃）
- ❌ 不引入新的 state 文件 / 外部依赖（jq 仅测试时用，运行时无）
- ❌ 不修改 `CLAUDE.md`（scope 外）
- ❌ 不复刻 H5 的任何机制（task-log.jsonl / 阶段证据 / hook-owned state write）
- ❌ 不做 UserPromptSubmit 之外的其他新 hook 类型

---

## 8. Review 历史

### Round 1

**Target:** branch-diff gov/skill-router-hook @ 7f1d6eb1 vs origin/main @ b90d36c0
**Verdict:** needs-attention
**Verdict digest:** （见 codex-attest 输出 TMP_OUT sha256）

**Findings:**

- **[high] F1**：spec 言必称"强制"，但方案 4 明确是自分类 + fail-open + 无外部校验；措辞与实际行为矛盾。推荐：要么把 artifact 重新定位成 best-effort 提醒且去掉 force/guard 措辞；要么加真正的硬检查（code Edit/Write 要求 TDD skill / trust-boundary 要求 codex review 证据 / 非法 exempt 拦截）。
- **[medium] F2**：`.claude/settings.json` 是否正确 wire UserPromptSubmit 从不自动化测试；hook 脚本可以 pass 所有单元测试的同时在 settings 里根本没挂载 / 挂错名字 / 错 timeout / 漏配。推荐：加 pre-merge 自动测试解析 settings.json，断言 `hooks.UserPromptSubmit` 存在且 command + timeout 正确。
- **[medium] F3**：T4 反漂移只单向（hook → map），map 新加路由但 hook 没同步不会 fail；且 regex 只覆盖 `superpowers:*` / `codex:*`，遗漏 `frontend-design:*` 等 namespace；具体漏洞：`ui_frontend_code` 在 map 里但不在 hook 提醒里。推荐：T4 改双向 + 覆盖所有 namespace。

**Claude 响应（半轮 1）：**

- **F1（partial accept + partial push back）**：
  - **Accept**：重命名 spec 标题 "入口守卫" → "入口提醒"；加显式边界声明（首段）；§ 1 需求 1 加 "强化 ≠ 强制" 澄清；新增 § 1.1 显式列出 gap table
  - **Push back**：不加硬检查（TDD 强制 / trust-boundary gate / exempt 拦截）。理由：用户在 brainstorming 里**显式评估了方案 A/B/C/D 后选 D**，并原话说"太复杂了"。增加硬检查等于偷偷把 scope 改回 B/C，违背用户选择；升级路径显式保留在 § 7.2 情形 A/B/C
- **F2（fully accept）**：新增 T5 测试用例解析 settings.json 校验 UserPromptSubmit 正确 wire（command + timeout + type 三项）
- **F3（fully accept）**：T4 改双向（方向 A + 方向 B）+ 覆盖 `superpowers:` / `frontend-design:` / `codex:` 三个 namespace；提醒文本扩充加入 `frontend-design:frontend-design` + 其余所有 `skill_entry_map` non-exempt 路由

**Round 1 产出 sha：** 本 commit 后的 spec blob sha（见 git log）

### Round 2

**Target:** branch-diff gov/skill-router-hook @ e5e65711 vs origin/main @ b90d36c0
**Verdict:** needs-attention
**Status:** R1 F1 / F3 接受（不再提）；R1 F2 落地实现有 bug，新 finding：

**Findings:**

- **[medium] R2-F1**：T5 的 jq 表达式链式错误——`.hooks.UserPromptSubmit | type == "array" and length > 0 | .hooks[0].hooks[]` 的中间管道段返回布尔值，下一段 `.hooks[0]` 报 "Cannot index boolean with string"。实际运行会把 T5 变成假阳性或被实施者弱化移除，R1 F2 的修复形同虚设。另：§6 验收 1 仍写 `All 4 tests passed` 但 spec 已定义 5 条测试。

**Claude 响应（半轮 2）：**

- **R2-F1（fully accept）**：拆 T5 为两步独立的 `jq -e` 调用：
  - 步骤 1：`.hooks.UserPromptSubmit | type == "array" and length > 0` 单独验证数组存在
  - 步骤 2：`.hooks.UserPromptSubmit[]?.hooks[]? | select(...)` 单独验证至少一条正确条目
  - 本地用 mock JSON 验证三组 case（正确配置 / 错 command / 空 array）全部预期行为
- **验收文本修正**：全文 `All 4 tests passed` → `All 5 tests passed`（单处）

**Round 2 产出 sha：** 本 commit 后的 spec blob sha

---

## Appendix A · 与现有文档的关系

| 文档 | 关系 |
|---|---|
| `CLAUDE.md` | 本 spec 不修改；backstop 第 4 条（首行 Skill gate 强制）继续有效，本 spec 强化其触发 |
| `.claude/workflow-rules.json` | 本 spec 不修改；`skill_entry_map` 是提醒文本的语义源（但不运行时读取） |
| H1-H4 specs | 本 spec 独立于 hardening 系列；不做延续 |
| H5 spec（2026-04-20 中止） | 本 spec 刻意避开 H5 scope（阶段守卫 / task-log），避免重蹈收敛陷阱 |
| `codex-attest.sh` + `attest-ledger.json` | 本 spec 依赖其作为 review 通道；不修改 |
| `docs/governance/signing-rules.md` | 本 spec 不改；`hat_signoff_verification` 规则按现状执行 |
