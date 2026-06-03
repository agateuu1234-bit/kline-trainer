# Wave 2 顺位 1 RFC 实施 Plan — baseline reconciliation + H1 闭环 + P6 恢复契约

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 纯文档 governance RFC：松绑 H1「同 PR」措辞 + reconcile P4/P2 端口已 Wave 0 落地的全部 stale 源 + 定义 P6 `forceResetAndReload()` 恢复契约 + fee-callsite fail-closed 措辞 + grep gate acceptance。

**Architecture:** 0 业务代码。编辑 4 个 live 权威源（modules / ledger / wave1-completion / wave1-outline）+ 1 RFC 设计文档已 commit + 1 acceptance 文档。冻结历史 plan/spec 不动。每个编辑用 grep 断言作「测试」：先跑见旧措辞在/新措辞缺 → 编辑 → 再跑见旧措辞绝/新措辞在 → commit。

**Tech Stack:** Markdown + bash grep（acceptance 谓词）。

**Spec:** `docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md`

**编辑范围纪律**：只改 live 权威源；E2 顺位 8 bump 的「同 PR」（modules L1494 等）+ 冻结历史文档（`docs/superpowers/plans/`、pr9-freeze）**绝不碰**。

---

## Task 0：评审策略前置（§15.3）

- [ ] **Step 1：确认 codex 通道**

plan-stage：`codex-attest.sh --scope working-tree --focus docs/superpowers/plans/2026-06-03-wave2-pr1-baseline-h1-rfc.md`，4-5 轮内收敛。
branch-diff：`codex-attest.sh --scope branch-diff`，4-5 轮内收敛。
超 5 轮 escalate user → attestation residual + admin merge（不绕 required checks）。codex 配额耗尽 → opus xhigh fallback（**先问 user**，per `feedback_subagent_quota_fallback_must_ask`）。
本 PR docs-only，不触 Catalyst CI required check。

---

## Task 1：modules §C1b 闸门#4 F3 H1 措辞松绑

**Files:**
- Modify: `kline_trainer_modules_v1.4.md:1180,1182`

- [ ] **Step 1：写验证断言（4 源 H1「同 PR」残留检查）**

```bash
# 数组而非标量（zsh 不 word-split 标量；codex plan R3-high）
sources=(kline_trainer_modules_v1.4.md docs/governance/2026-05-17-wave0-signoff-ledger.md docs/governance/2026-06-01-wave1-completion.md docs/superpowers/specs/2026-05-19-wave1-outline-design.md)
# 排除 E2 顺位 8 bump 的合法「同 PR」（decoder/顺位 8/CONTRACT_VERSION/position_data）
grep -nE "同 PR" "${sources[@]}" | grep -vE "decoder|顺位 8|CONTRACT_VERSION|position_data"
```

- [ ] **Step 2：跑断言（当前应命中 = 待修证据）**

Run: 上述命令
Expected: 命中 modules L1180/L1182、ledger L32、completion L43、wave1-outline L54（共 ≥4 行 H1「同 PR」）

- [ ] **Step 3：编辑 L1180（Wave 2 验收行）**

OLD:
```
  - **Wave 2 验收**（C8 ChartContainerView + E5 TrainingEngine 落地时同 PR 内；C2 DecelerationAnimator 已于 Wave 1 顺位 3 落地）：production handler 集成测试 — 模拟延迟 animator 回调，验证 handler 必须**先**调用 `animator.stop()` 再计算 range；drawing 退出后无 `offsetApplied` 到达 reducer
```
NEW:
```
  - **Wave 2 验收**（集成测试在 **Wave 2 顺位 7 C8 集成 anchor** 内验证；彼时 C2 DecelerationAnimator〔Wave 1 顺位 3〕+ E5a/E5b TrainingEngine〔Wave 2 顺位 2/3〕+ C8 ChartContainerView〔本 anchor〕三模块均已 merged 在场）：production handler 集成测试 — 模拟延迟 animator 回调，验证 handler 必须**先**调用 `animator.stop()` 再计算 range；drawing 退出后无 `offsetApplied` 到达 reducer
```

- [ ] **Step 4：编辑 L1182（理由块）**

OLD:
```
  **理由**：production handler 涉及 C2/C8/E5 三模块 orchestration，非 Wave 0 单模块 scope；reducer 契约测试已覆盖契约面，handler 集成测试在生产代码落地的同 PR 验证更准。C8/E5 属 Wave 2（见 Wave 1 outline §六），故集成测试在 Wave 2 C8 集成 PR 内闭环（Wave 1 顺位 1a 仅 reclassify wording）。
```
NEW:
```
  **理由**：production handler 涉及 C2/C8/E5 三模块 orchestration，非 Wave 0 单模块 scope；reducer 契约测试已覆盖契约面，handler 集成测试需三模块**同时在场**时验证 orchestration 正确——语义要求是三模块**都已合入代码库**，不要求**同一个 PR 编写**。C8 是依赖链末端（需 E5），故集成测试自然落在 Wave 2 顺位 7 C8 集成 anchor（彼时 C2 + E5a/E5b 均已 merged）。〔Wave 2 顺位 1 RFC 松绑措辞为「C8 anchor 内三模块在场验证」，见 `docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md`；Wave 1 顺位 1a 仅 reclassify Wave 1→Wave 2 wording。〕
```

- [ ] **Step 5：跑断言验证 modules 两行已绝**

Run: `grep -nE "同 PR" kline_trainer_modules_v1.4.md | grep -vE "decoder|顺位 8|CONTRACT_VERSION|position_data"`
Expected: 不再命中 L1180/L1182（modules 仅剩 L1494 E2 行被 grep -v 排除 → 输出空）

- [ ] **Step 6：commit**

```bash
git add kline_trainer_modules_v1.4.md
git commit -m "顺位1 RFC Task1：modules §C1b 闸门#4 F3 H1「同 PR」措辞松绑（C8 anchor 三模块在场验证）"
```

---

## Task 2：modules §Wave 2 checklist 回填 P4/P2

**Files:**
- Modify: `kline_trainer_modules_v1.4.md:2176,2177`

- [ ] **Step 1：写验证断言（未勾选项不含 P4/P2 端口 Wave2 待办）**

```bash
grep -nE "^- \[ \].*(P4 .DefaultAppDB. 实现|4 内部端口默认实现)" kline_trainer_modules_v1.4.md
```

- [ ] **Step 2：跑断言（当前应命中 L2176/L2177）**

Expected: 命中 L2176（P2 4 内部端口默认实现）+ L2177（P4 DefaultAppDB 实现）

- [ ] **Step 3：编辑 L2176**

OLD:
```
- [ ] P2 DownloadAcceptanceRunner 及 4 内部端口默认实现 + `retryPendingConfirmations`（v1.3）
```
NEW（注：不含精确短语 `4 内部端口默认实现`，否则自伤谓词 (c)；codex plan R1-high 修）:
```
- [ ] P2 DownloadAcceptanceRunner orchestration + `retryPendingConfirmations`（v1.3）〔baseline reconcile：4 个内部端口 ✅ 已 Wave 0 落地 PR #43；Wave 2 仅剩 runner〕
```

- [ ] **Step 4：编辑 L2177**

OLD:
```
- [ ] P4 `DefaultAppDB` 实现（组合 4 个 protocol + `AcceptanceJournalDAO`）
```
NEW:
```
- [x] ~~P4 `DefaultAppDB` 实现~~ ✅ 已 Wave 0 落地（PR #42/#43；`KlineTrainerPersistence/DefaultAppDB.swift`）——baseline reconcile：不在 Wave 2
```

- [ ] **Step 5：跑断言验证已绝**

Run: `grep -nE "^- \[ \].*(P4 .DefaultAppDB. 实现|4 内部端口默认实现)" kline_trainer_modules_v1.4.md`
Expected: 输出空

- [ ] **Step 6：commit**

```bash
git add kline_trainer_modules_v1.4.md
git commit -m "顺位1 RFC Task2：modules §Wave2 checklist 回填 P4/P2 端口已 Wave0 落地"
```

---

## Task 3：modules fee-callsite fail-closed 措辞

**Files:**
- Modify: `kline_trainer_modules_v1.4.md:2000,2040`

- [ ] **Step 1：写验证断言（交易路径不调 fail-open snapshotFees）**

```bash
grep -nE "startNewNormalSession.*snapshotFees\(\)|snapshotFees\(\).*startNewNormalSession" kline_trainer_modules_v1.4.md | grep -v "snapshotFeesIfReady"
```

- [ ] **Step 2：跑断言（当前应命中 L2000/L2040）**

Expected: 命中 L2000（def 行注释 startNewNormalSession 内部调用）+ L2040（coordinator 调 snapshotFees()）

- [ ] **Step 3：编辑 L2000（拆 fail-open def 注释 + 加 IfReady 行）**

OLD:
```
    func snapshotFees() -> FeeSnapshot                   // v1.2：Coordinator.startNewNormalSession 内部调用
```
NEW:
```
    func snapshotFees() -> FeeSnapshot                   // fail-open（仅 UI 显示路径；loadError 时返回零费用不抛）
    func snapshotFeesIfReady() throws -> FeeSnapshot     // fail-closed：loadError 时 throws；Coordinator.startNewNormalSession 等交易流必须用此变体
```

- [ ] **Step 4：编辑 L2040**

OLD:
```
// fees 打包现在由 coordinator.startNewNormalSession 内部调用 settings.snapshotFees()，
```
NEW:
```
// fees 打包现在由 coordinator.startNewNormalSession 内部调用 settings.snapshotFeesIfReady()（fail-closed：loadError 时 throws；禁交易流用 fail-open snapshotFees() 误算零费用），
```

- [ ] **Step 5：跑断言验证已绝**

Run: `grep -nE "startNewNormalSession.*snapshotFees\(\)|snapshotFees\(\).*startNewNormalSession" kline_trainer_modules_v1.4.md | grep -v "snapshotFeesIfReady"`
Expected: 输出空

- [ ] **Step 6：commit**

```bash
git add kline_trainer_modules_v1.4.md
git commit -m "顺位1 RFC Task3：modules fee-callsite 改 snapshotFeesIfReady fail-closed（防 E6a 照 stale 字面造零费用）"
```

---

## Task 4：modules §P6 写入 forceResetAndReload 恢复契约

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（§P6 code block L2000 区 + L2015 后加契约 prose）

- [ ] **Step 1：写验证断言（契约已写入）**

```bash
grep -nc "forceResetAndReload" kline_trainer_modules_v1.4.md
```

- [ ] **Step 2：跑断言（当前 = 0）**

Expected: `0`

- [ ] **Step 3：在 §P6 protocol code block 加方法（在 Task3 改后的 snapshotFeesIfReady 行下方加一行）**

在 `func snapshotFeesIfReady() throws -> FeeSnapshot ...` 行下方插入：
```
    func forceResetAndReload() async throws              // Wave 2 顺位 1 RFC：loadError 恢复路径（顺位 10 U4 实施）
```

- [ ] **Step 4：在 §P6 code fence（L2015 ``` 收尾）之后插入契约 prose 块**

在 `// E3 TradeCalculator / E5 TrainingEngine / P4 SettingsDAO 一律使用小数率。` 行后的 ` ``` ` 之后插入：
```

**P6 loadError 恢复契约（Wave 2 顺位 1 RFC 定义；顺位 10 U4 实施）**：`loadError` set 后 `update`/`resetCapital`/交易（`snapshotFeesIfReady`）全阻塞，重启对持久损坏 DB 无效（每次 load 都失败）。`forceResetAndReload() async throws` 是**唯一绕过 loadError 写守卫的恢复路径**：`saveSettings(AppSettings.default)` 覆盖损坏状态 → `let loaded = try loadSettings()` 验证 → **在 MainActor 上先 `self.settings = loaded` 再清 `loadError`**（解阻 update/resetCapital/交易）；仍失败则 throws + **保留** loadError（不静默清成功态）。**关键不变量（codex plan R2-high）**：必须先把 reloaded 值赋回 `settings` 再清错误位——否则解阻后 `snapshotFeesIfReady()` 仍读 init 时 `zeroDefault`（zero fee/capital），架空契约。reset 目标 `AppSettings.default` = 含合理起始本金（非 0 资本）的命名默认值，顺位 10 引入（不复用 SettingsStore 内 capital 0 的 `zeroDefault`）。**不改** Wave 0 冻结的 `SettingsDAO` 协议（恢复逻辑是 Store 状态机职责非 DAO 存储职责）。详 `docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md` §四。
```

- [ ] **Step 5：跑断言验证（≥2：code block 方法 + prose 块；不含 spec 文档引用计在 modules 内 = 2）**

Run: `grep -nc "forceResetAndReload" kline_trainer_modules_v1.4.md`
Expected: `2`

- [ ] **Step 6：commit**

```bash
git add kline_trainer_modules_v1.4.md
git commit -m "顺位1 RFC Task4：modules §P6 写入 forceResetAndReload() loadError 恢复契约"
```

---

## Task 5：ledger §28 H1 行措辞同步

**Files:**
- Modify: `docs/governance/2026-05-17-wave0-signoff-ledger.md:32`

- [ ] **Step 1：编辑 L32（H1 行）**

OLD:
```
| H1 | C1b 闸门 #4 F3 production handler 集成测试（modules §C1b L1180 区块） | PR #50 plan-residual | 顺位 1a spec amendment：modules §C1b 闸门 #4 reclassify Wave 1→Wave 2（C8/E5 属 Wave 2）；真正闭环 = Wave 2 C8 ChartContainerView 集成 PR（C2/C8/E5 orchestration 同 PR） |
```
NEW:
```
| H1 | C1b 闸门 #4 F3 production handler 集成测试（modules §C1b L1180 区块） | PR #50 plan-residual | 顺位 1a spec amendment：modules §C1b 闸门 #4 reclassify Wave 1→Wave 2（C8/E5 属 Wave 2）；真正闭环 = Wave 2 顺位 7 C8 集成 anchor（C2 + E5a/E5b + C8 三模块在场时验证 orchestration；Wave 2 顺位 1 RFC 松绑措辞，见 `docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md`） |
```

- [ ] **Step 2：跑断言验证 ledger 无 H1「同 PR」**

Run: `grep -nE "同 PR" docs/governance/2026-05-17-wave0-signoff-ledger.md | grep -vE "decoder|顺位 8|CONTRACT_VERSION|position_data"`
Expected: 输出空

- [ ] **Step 3：commit**

```bash
git add docs/governance/2026-05-17-wave0-signoff-ledger.md
git commit -m "顺位1 RFC Task5：ledger §28 H1 行措辞同步（C8 anchor 三模块在场验证）"
```

---

## Task 6：wave1-completion H1 行 + §五 Wave 2 边界

**Files:**
- Modify: `docs/governance/2026-06-01-wave1-completion.md:43,82`

- [ ] **Step 1：编辑 L43（H1 终态行）**

OLD:
```
| H1 | **→ Wave 2**：1a (#56) 已做 spec amendment（modules §C1b 闸门 #4 reclassify Wave 1→Wave 2）；真正闭环 = Wave 2 C8 ChartContainerView 集成 PR（C2/C8/E5 orchestration 同 PR） | #56 |
```
NEW:
```
| H1 | **→ Wave 2**：1a (#56) 已做 spec amendment（modules §C1b 闸门 #4 reclassify Wave 1→Wave 2）；真正闭环 = Wave 2 顺位 7 C8 集成 anchor（C2 + E5a/E5b + C8 三模块在场时验证；Wave 2 顺位 1 RFC 松绑措辞） | #56 |
```

- [ ] **Step 2：编辑 L82（§五 Wave 2 边界）**

OLD:
```
Wave 1 outline §六明列 Wave 2 范围：**C8 / E5 / E6 / P2 / P4 / U1 / U2 / U4** + H1 真正闭环（C8 ChartContainerView 集成）。Wave 2 outline 排序为独立规划 session（brainstorming + writing-plans），不在本轻量收尾内。
```
NEW:
```
Wave 1 outline §六明列 Wave 2 范围：**C8 / E5 / E6 / P2 runner / U1 / U2 / U4** + H1 真正闭环（C8 ChartContainerView 集成）。〔baseline reconcile（Wave 2 顺位 1 RFC）：**P4 `DefaultAppDB` + P2 4 内部端口已 Wave 0 落地（PR #42/#43），不在 Wave 2；Wave 2 仅 P2 runner**。〕Wave 2 outline 排序为独立规划 session（brainstorming + writing-plans），不在本轻量收尾内。
```

- [ ] **Step 3：跑断言验证（无 H1「同 PR」+ §五 不列 P4/P2 端口待办）**

Run:
```bash
grep -nE "同 PR" docs/governance/2026-06-01-wave1-completion.md | grep -vE "decoder|顺位 8|CONTRACT_VERSION|position_data"
grep -nE "C8 / E5 / E6 / P2 / P4 / U1" docs/governance/2026-06-01-wave1-completion.md
```
Expected: 两条均输出空

- [ ] **Step 4：commit**

```bash
git add docs/governance/2026-06-01-wave1-completion.md
git commit -m "顺位1 RFC Task6：wave1-completion H1 行 + §五 Wave2 边界 reconcile（P4/P2 端口已 Wave0）"
```

---

## Task 7：wave1-outline §六 + H1 措辞 reconcile

**Files:**
- Modify: `docs/superpowers/specs/2026-05-19-wave1-outline-design.md:54,124`

- [ ] **Step 1：编辑 L54（H1 段）**

OLD:
```
**H1 不在 Wave 1 PR 顺位（仅在 1a spec amendment 内 reclassify）**：spec L1180-1182 字面要求 "production handler 集成测试" 与 C2+C8+E5 三模块 orchestration **同 PR 落地**。C8 / E5 实施在 Wave 2，因此 H1 真正闭环在 Wave 2 C8 ChartContainerView 集成 PR；1a 内 spec amendment 仅 reclassify。
```
NEW:
```
**H1 不在 Wave 1 PR 顺位（仅在 1a spec amendment 内 reclassify）**：spec L1180-1182 要求 "production handler 集成测试" 在 C2+C8+E5 三模块**同时在场**时验证 orchestration。C8 / E5 实施在 Wave 2，因此 H1 真正闭环在 Wave 2 顺位 7 C8 集成 anchor（彼时三模块均已 merged）；1a 内 spec amendment 仅 reclassify。〔Wave 2 顺位 1 RFC 松绑措辞，见 `docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md`。〕
```

- [ ] **Step 2：编辑 L124（Wave 2 范围列表）**

OLD:
```
- **Wave 2 范围**：C8 ChartContainerView 集成（含 H1 真正闭环）、E5 TrainingEngine 实施、E6 TrainingSessionCoordinator 实施、P2 DownloadAcceptanceRunner 4 内部端口真实现、P4 DefaultAppDB 实施、U1 HomeView、U2 TrainingView、U4 SettingsPanel
```
NEW:
```
- **Wave 2 范围**：C8 ChartContainerView 集成（含 H1 真正闭环）、E5 TrainingEngine 实施、E6 TrainingSessionCoordinator 实施、P2 DownloadAcceptanceRunner orchestration（**4 内部端口已 Wave 0 落地 PR #43**）、U1 HomeView、U2 TrainingView、U4 SettingsPanel〔baseline reconcile（Wave 2 顺位 1 RFC）：**P4 `DefaultAppDB` 已 Wave 0 落地 PR #42/#43，不在 Wave 2**〕
```

- [ ] **Step 3：跑断言验证（无 H1「同 PR 落地」+ 无 P4 实施/4 内部端口真实现 todo）**

Run:
```bash
grep -nE "同 PR" docs/superpowers/specs/2026-05-19-wave1-outline-design.md | grep -vE "decoder|顺位 8|CONTRACT_VERSION|position_data|三连而非"
grep -nE "P4 DefaultAppDB 实施|4 内部端口真实现" docs/superpowers/specs/2026-05-19-wave1-outline-design.md
```
Expected: 两条均输出空（L79「三连而非 2 PR」的 runbook 同 PR 是 1b/1c governance 上下文，非 H1，已 grep -v 排除）

- [ ] **Step 4：commit**

```bash
git add docs/superpowers/specs/2026-05-19-wave1-outline-design.md
git commit -m "顺位1 RFC Task7：wave1-outline §六 + H1 措辞 reconcile（P4/P2 端口已 Wave0）"
```

---

## Task 7b：Wave 2 outline §三.1 supersede banner（codex plan R4-high#1）

**Files:**
- Modify: `docs/superpowers/specs/2026-06-02-wave2-outline-design.md`（§3.1 heading 后插 banner）

**为何**：Wave 2 outline 是后续 anchor 的规划输入，§3.1 仍含 stale `落地时同 PR 内` / `C2/C8/E5 orchestration 同 PR`（作「现状字面/张力」描述）。不删这些历史引用，但加 supersede banner，使后续 plan 读者先撞标记、不据旧字面重建约束。谓词 (e) 断言 banner 在位。

- [ ] **Step 1：在 §3.1 heading（`### 3.1 顺位 1：...`）下方插入 banner**

在 `### 3.1 顺位 1：baseline reconciliation + H1 闭环 RFC（先松绑「同 PR」措辞）` 行的下一行插入：
```
> **【顺位 1 RFC 已落地 2026-06-03，本节措辞已 superseded】**：本节描述的「同 PR」张力已由顺位 1 RFC（`docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md`）松绑为「集成测试在顺位 7 C8 集成 anchor 内、C2 + E5a/E5b + C8 三模块在场时验证」。下文「现状字面」「张力」引用为**松绑前历史描述**；顺位 7 C8 plan 以 modules L1180 松绑后措辞为准，**勿据本节旧「同 PR」字面重建约束**。
```

- [ ] **Step 2：跑断言验证 marker 在位**

Run: `grep -nF "本节措辞已 superseded" docs/superpowers/specs/2026-06-02-wave2-outline-design.md`
Expected: 命中 1 行

- [ ] **Step 3：commit**

```bash
git add docs/superpowers/specs/2026-06-02-wave2-outline-design.md
git commit -m "顺位1 RFC Task7b：Wave2 outline §三.1 supersede banner（防后续 anchor 读旧同 PR 约束）"
```

---

## Task 8：fail-closed 验证脚本 + acceptance checklist 文档

**Files:**
- Create: `scripts/governance/verify-wave2-pr1-rfc.sh`（fail-closed bash gate）
- Create: `docs/acceptance/2026-06-03-wave2-pr1-baseline-h1-rfc.md`（中文 non-coder checklist）

**为何独立 fail-closed 脚本（codex plan R3/R4-high 修）**：(1) 标量 `SOURCES="a b c"` 在仓库默认 zsh 下**不 word-split** → `grep $SOURCES` 把整串当一个文件名 → 读错误 → `if...else` 转成 PASS（fail-open）；(2) `grep ... || true` 把 grep **exit 2（读错误/坏正则）**也吞成空 → PASS。修：**数组 `sources=(...)` + 跑前 `-r` 可读断言 + grep helper 区分 rc 0(命中)/1(无命中)/>1(读错误→exit 2) + 过滤/排除用纯 bash `case` 不再 `grep|grep -v||true`**。下方脚本已实测：当前未编辑 repo → GATE FAIL exit 1（抓全部 stale）；源不可读 → exit 2；zsh/bash 双兼容。

- [ ] **Step 1：读禁忌词清单**

Run: `grep -i "forbidden\|禁忌\|禁用" .claude/workflow-rules.json`
（确认 acceptance 文档不含禁忌措辞）

- [ ] **Step 2：写 fail-closed 验证脚本（逐字照抄，已实测）**

Create `scripts/governance/verify-wave2-pr1-rfc.sh`：
```bash
#!/usr/bin/env bash
# verify-wave2-pr1-rfc.sh — Wave 2 顺位 1 RFC grep gate (fail-closed)
# fail-closed 设计（codex plan R3/R4）：
#   - 源路径用数组（zsh 不 word-split 标量）
#   - 跑前断言每个源可读（-r）；不可读 → exit 2
#   - grep 包成 helper：rc 0=命中 / rc 1=无命中 / rc>1=读错误 → 立即 exit 2
#   - 排除/过滤用纯 bash case（不再用 `grep | grep -v || true` 吞错误）
set -uo pipefail

sources=(
  "kline_trainer_modules_v1.4.md"
  "docs/governance/2026-05-17-wave0-signoff-ledger.md"
  "docs/governance/2026-06-01-wave1-completion.md"
  "docs/superpowers/specs/2026-05-19-wave1-outline-design.md"
)
outline="docs/superpowers/specs/2026-06-02-wave2-outline-design.md"
spec="docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md"

for f in "${sources[@]}" "$outline" "$spec"; do
  [ -r "$f" ] || { echo "GATE FAIL: unreadable source $f"; exit 2; }
done

# grep helper：命中写 HITS；rc>1（读错误/坏正则）硬退出 2
gg()  { HITS=$(grep -nE "$@"); local r=$?; [ "$r" -gt 1 ] && { echo "GATE FAIL: grep -E error rc=$r ($*)"; exit 2; }; return 0; }
ggF() { HITS=$(grep -nF "$@"); local r=$?; [ "$r" -gt 1 ] && { echo "GATE FAIL: grep -F error rc=$r ($*)"; exit 2; }; return 0; }
nonblank() { printf '%s' "$1" | tr -d '[:space:]'; }

rc=0

# (a) 4 源无 H1「同 PR」残留（纯 bash 过滤 E2 顺位8 + 1b/1c runbook）
gg "同 PR" "${sources[@]}"
a_hits=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    *decoder*|*"顺位 8"*|*CONTRACT_VERSION*|*position_data*|*三连而非*) continue ;;
    *) a_hits+="$line"$'\n' ;;
  esac
done <<< "$HITS"
if [ -n "$(nonblank "$a_hits")" ]; then echo "(a) FAIL"; printf '%s' "$a_hits"; rc=1; else echo "(a) PASS"; fi

# (b) modules 交易路径不调 fail-open snapshotFees()
gg "startNewNormalSession.*snapshotFees\(\)|snapshotFees\(\).*startNewNormalSession" "kline_trainer_modules_v1.4.md"
b_hits=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in *snapshotFeesIfReady*) continue ;; *) b_hits+="$line"$'\n' ;; esac
done <<< "$HITS"
if [ -n "$(nonblank "$b_hits")" ]; then echo "(b) FAIL"; printf '%s' "$b_hits"; rc=1; else echo "(b) PASS"; fi

# (c) 3 源无 stale P4/P2 端口列 Wave 2 待办
c_hits=""
gg  "^- \[ \].*(P4 .DefaultAppDB. 实现|4 内部端口默认实现)" "kline_trainer_modules_v1.4.md"; c_hits+="$HITS"$'\n'
gg  "P4 DefaultAppDB 实施|4 内部端口真实现" "docs/superpowers/specs/2026-05-19-wave1-outline-design.md"; c_hits+="$HITS"$'\n'
ggF "C8 / E5 / E6 / P2 / P4 / U1" "docs/governance/2026-06-01-wave1-completion.md"; c_hits+="$HITS"$'\n'
if [ -n "$(nonblank "$c_hits")" ]; then echo "(c) FAIL"; printf '%s' "$c_hits"; rc=1; else echo "(c) PASS"; fi

# (d) P6 契约已写入（modules ≥2 + spec ≥1）
m=$(grep -cE "forceResetAndReload" "kline_trainer_modules_v1.4.md"); [ $? -gt 1 ] && { echo "GATE FAIL: grep -c modules"; exit 2; }
s=$(grep -cE "forceResetAndReload" "$spec"); [ $? -gt 1 ] && { echo "GATE FAIL: grep -c spec"; exit 2; }
if [ "${m:-0}" -ge 2 ] && [ "${s:-0}" -ge 1 ]; then echo "(d) PASS"; else echo "(d) FAIL: modules=$m spec=$s"; rc=1; fi

# (e) Wave 2 outline §三.1 含 supersede marker（防后续 anchor 规划读旧「同 PR」约束；codex R4-high#1）
ggF "本节措辞已 superseded" "$outline"
if [ -n "$HITS" ]; then echo "(e) PASS"; else echo "(e) FAIL: outline 缺 supersede marker"; rc=1; fi

[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "GATE FAIL"
exit "$rc"
```

- [ ] **Step 3：跑脚本验证 fail-closed 行为（证伪 + 证实）**

Run:
```bash
chmod +x scripts/governance/verify-wave2-pr1-rfc.sh
# 反例（源不可读）：必 GATE FAIL exit 2（证 fail-closed，读失败≠PASS）
( cd scripts && bash governance/verify-wave2-pr1-rfc.sh ); echo "unreadable-source exit=$?"
# 正例（仓库根，Task1-7b 已改完）：ALL PASS exit 0
bash scripts/governance/verify-wave2-pr1-rfc.sh; echo "exit=$?"
```
Expected：
- 反例（在 scripts/ 下跑，源相对路径不可读）打印 `GATE FAIL: unreadable source ...` + `unreadable-source exit=2`（**exit 2 = 读失败硬退出，非语义 fail；与脚本 `-r` 守卫契约一致**）
- 正例（仓库根）打印 `(a)-(e) PASS` / `ALL PASS` + `exit=0`
- 注：exit 1 仅保留给语义 stale-content 失败（谓词命中残留）；exit 2 = 源读取失败；exit 0 = 全过

- [ ] **Step 4：写 acceptance 文档**

Create `docs/acceptance/2026-06-03-wave2-pr1-baseline-h1-rfc.md`：中文 non-coder checklist，含 (1) 元信息（PR / 锚 / docs-only / 0 业务代码）；(2) 唯一验收命令 `bash scripts/governance/verify-wave2-pr1-rfc.sh`（action / expected `ALL PASS` exit 0 / pass-fail ☐）；(3) 8 项 scope 逐项 action（具体 grep 或目视行号）/ expected / ☐ 表；(4) P6 契约目视核对项。**禁忌词**（Step 1 清单）不得出现。负向断言已封装在脚本内（fail-closed），acceptance 只调脚本不再裸 `! grep`。

- [ ] **Step 5：commit**

```bash
git add scripts/governance/verify-wave2-pr1-rfc.sh docs/acceptance/2026-06-03-wave2-pr1-baseline-h1-rfc.md
git commit -m "顺位1 RFC Task8：fail-closed 验证脚本（数组+pipefail+存在断言）+ acceptance checklist"
```

---

## Task 9：全仓最终验收 + 漂移自检

- [ ] **Step 1：跑 fail-closed 验证脚本全绿**

Run: `bash scripts/governance/verify-wave2-pr1-rfc.sh; echo "exit=$?"`
Expected: `(a) PASS` / `(b) PASS` / `(c) PASS` / `(d) PASS` / `(e) PASS` / `ALL PASS` / `exit=0`

- [ ] **Step 2：确认未碰 E2/冻结历史文档**

Run: `git diff --name-only main...HEAD`
Expected: 仅 9 文件 — RFC spec + 本 plan + modules + ledger + wave1-completion + wave1-outline + **wave2-outline** + acceptance.md + verify-wave2-pr1-rfc.sh；**无** `docs/superpowers/plans/2026-05-*`、**无** `kline_trainer_plan_v1.5.md`、**无** ios/ 代码

- [ ] **Step 3：确认 0 业务代码改动**

Run: `git diff --name-only main...HEAD | grep -E "\.swift$|\.py$"`
Expected: 输出空

---

## Self-Review（plan↔spec 覆盖核对）

- **spec §三 scope**：item1→Task1；item2→Task2；item3→Task5；item4→Task6；item5→Task7；**item5b→Task7b**；item6→Task3；item7→Task4；item8→Task8 ✅ 全覆盖
- **spec §四 P6 契约**：Task4（modules 写入，含 R2-high 显式状态转移）+ 谓词 (d) 验 ✅
- **spec §五 grep gate 五谓词 (a)-(e)**：Task8 fail-closed 脚本（已实测）✅
- **spec §二 编辑范围边界**：Task9 Step2/3 守护（仅 9 文件 / 0 `.swift`/`.py` / 不碰 E2+冻结历史；Wave2 outline 是 live 例外 reconcile 目标）✅
- **类型/命名一致**：`forceResetAndReload` / `snapshotFeesIfReady` / `AppSettings.default` / marker `本节措辞已 superseded` 各处一致 ✅
- **无占位符**：所有编辑含 exact OLD/NEW；脚本逐字可照抄已实测；grep 谓词含 exact 命令 ✅
