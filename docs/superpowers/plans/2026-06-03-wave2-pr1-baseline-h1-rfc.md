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

## Task 3b：modules risk-table 残留 fee 指引 reconcile（codex plan R8-high#1）

**Files:**
- Modify: `kline_trainer_modules_v1.4.md:2293,2401`

**为何**：除 L2000/L2040，risk-table L2293（R36）+ L2401 仍指 `SettingsStore.snapshotFees`（fail-open）给 NormalFlow.fees/U1 打包——后续 E6/U1 规划读到会重建 fail-open 零费用路径。改指 `snapshotFeesIfReady`。

- [ ] **Step 1：编辑 L2293（R36 行）**

OLD:
```
| **R36** | **NormalFlow.fees 打包时机不明**（v1.2） | **P2** | U1 启动时 SettingsStore.snapshotFees | U1/E4 |
```
NEW:
```
| **R36** | **NormalFlow.fees 打包时机不明**（v1.2） | **P2** | U1 启动时 SettingsStore.snapshotFeesIfReady（顺位 1 RFC：交易流 fail-closed，禁 fail-open snapshotFees） | U1/E4 |
```

- [ ] **Step 2：编辑 L2401**

OLD:
```
| 36 | R2-Cloud-新增 | — | P2 | U1/P6 | NormalFlow.fees 打包时机明确（U1 + SettingsStore.snapshotFees） |
```
NEW:
```
| 36 | R2-Cloud-新增 | — | P2 | U1/P6 | NormalFlow.fees 打包时机明确（U1 + SettingsStore.snapshotFeesIfReady；顺位 1 RFC fail-closed） |
```

- [ ] **Step 3：跑断言验证全仓 fee 打包指引无裸 snapshotFees（谓词 (b) 双向）**

Run:
```bash
grep -nE "snapshotFees" kline_trainer_modules_v1.4.md | grep -vE "snapshotFeesIfReady|fail-open|UI 显示" | grep -E "startNewNormalSession|NormalFlow.fees|打包"
```
Expected: 输出空（L2000/2040/2293/2401 全已改 IfReady 或标 fail-open）

- [ ] **Step 4：commit**

```bash
git add kline_trainer_modules_v1.4.md
git commit -m "顺位1 RFC Task3b：reconcile risk-table L2293/L2401 fee 指引改 snapshotFeesIfReady fail-closed"
```

---

## Task 4：modules §P6 写入 forceResetAndReload 恢复契约

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（§P6 code block L2000 区 + L2015 后加契约 prose）

- [ ] **Step 1：写验证断言（精确签名 + 不变量四锚，非仅计数；codex R6/R7）**

```bash
# 两精确方法签名（仅 code fence 有 `func ... async throws`；prose 无 func 前缀）
grep -nF "func retryReload() async throws" kline_trainer_modules_v1.4.md
grep -nF "func forceResetAndReload(confirmation: SettingsResetConfirmation) async throws" kline_trainer_modules_v1.4.md
# 不变量锚（prose 块）
grep -nE "AppSettings\.default" kline_trainer_modules_v1.4.md
grep -nE "self\.settings = loaded" kline_trainer_modules_v1.4.md
grep -nE "loadError != nil|loadError == nil" kline_trainer_modules_v1.4.md
grep -nF "_retryReloadFailed" kline_trainer_modules_v1.4.md
grep -nE "try\? loadSettings" kline_trainer_modules_v1.4.md   # 破坏前最后非破坏 reload（R10-high#1）
```

- [ ] **Step 2：跑断言（当前全 = 空，待 Step 3/4 写入）**

Expected: 七条均输出空

- [ ] **Step 3：在 §P6 protocol code block 加两个恢复方法（在 Task3 改后的 snapshotFeesIfReady 行下方）**

在 `func snapshotFeesIfReady() throws -> FeeSnapshot ...` 行下方插入：
```
    func retryReload() async throws                                          // Wave 2 顺位 1 RFC：非破坏性 transient 恢复（重读，保留真实设置；失败置 _retryReloadFailed）
    func forceResetAndReload(confirmation: SettingsResetConfirmation) async throws  // Wave 2 顺位 1 RFC：破坏性 last-resort（state 强制 _retryReloadFailed + confirmation marker）
```

- [ ] **Step 4：在 §P6 code fence（L2015 ``` 收尾）之后插入契约 prose 块**

在 `// E3 TradeCalculator / E5 TrainingEngine / P4 SettingsDAO 一律使用小数率。` 行后的 ` ``` ` 之后插入：
```

**P6 loadError 两层恢复契约（Wave 2 顺位 1 RFC 定义；顺位 10 U4 实施）**：`loadError` set 后 `update`/`resetCapital`/交易（`snapshotFeesIfReady`）全阻塞，重启对持久损坏 DB 无效。**`loadError` 任何 init load 失败都 set（含 transient I/O/磁盘故障，非仅 malformed）**，故恢复分两层（codex plan R8-high#2）：**① `retryReload() async throws`（非破坏，transient 首选）**——要求 `loadError != nil`；`let loaded = try loadSettings()` 成功 → MainActor 先 `self.settings = loaded` 再清 `loadError`（**保留 DB 真实用户设置**）；仍失败 → 置内部 `_retryReloadFailed = true` + loadError 保留 + throws；**不写库**。**② `forceResetAndReload(confirmation: SettingsResetConfirmation) async throws`（破坏性 last-resort）**——**守卫编码进 state（非 prose；codex R9-high#1）**：`confirmation: SettingsResetConfirmation` 是 deliberate-intent 信号（caller 须显式构造、防误调；**非**抗 determined caller 的安全边界，init 归属顺位 10 定；codex R11-high#2）；**真正数据安全 = runtime 守卫 + 破坏前最后非破坏 reload**：in-method 强制 `loadError != nil` **且 `_retryReloadFailed == true`**，任一不满足（健康态/未先 retryReload）→ **throws 且不调 `saveSettings`**（零破坏）；通过守卫后 **破坏前最后非破坏重试 `if let loaded = try? loadSettings()` → 成功（transient 已恢复）则 `self.settings = loaded` + 清 `loadError`+flag + return（不 `saveSettings`，保留真实设置，零破坏；codex R10-high#1）**；仅当该最后 load 仍失败 → `saveSettings(AppSettings.default)` → reload → MainActor 先 `self.settings = loaded` 再清 `loadError`+flag。**恢复顺序契约（state 强制）**：先 `retryReload()`，仅当它 throws（置 flag）才在确认后 `forceResetAndReload(confirmation:)`。**前置条件（R7-high）**：两者健康态（`loadError == nil`）→ throws 且不改 `settings`（防误抹合法 commissionRate/minCommissionEnabled/totalCapital/displayMode）。**关键不变量（R2-high）**：必须先把 reloaded 值赋回 `settings` 再清错误位——否则解阻后 `snapshotFeesIfReady()` 仍读 init 时 `zeroDefault`（zero fee/capital），架空契约。reset 目标 `AppSettings.default` = 含合理起始本金（非 0 资本）的命名默认值，顺位 10 引入（不复用 capital 0 的 `zeroDefault`）。**不改** Wave 0 冻结的 `SettingsDAO` 协议。详 `docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md` §四。
```

- [ ] **Step 5：跑断言验证（两精确签名 + 不变量锚全在位 = 谓词 (d)）**

Run:
```bash
grep -nF "func retryReload() async throws" kline_trainer_modules_v1.4.md                                      # 非破坏签名
grep -nF "func forceResetAndReload(confirmation: SettingsResetConfirmation) async throws" kline_trainer_modules_v1.4.md  # 破坏性签名（含 confirmation marker）
grep -nE "AppSettings\.default|self\.settings = loaded|loadError != nil|_retryReloadFailed" kline_trainer_modules_v1.4.md  # 不变量锚
```
Expected: 两签名各命中 1；不变量锚均命中。等价于谓词 (d) PASS 条件。

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

**为何独立 fail-closed 脚本（codex plan R3-R6 修）**：(1) 标量 `SOURCES` zsh 不 word-split → 读错误 fail-open PASS（R3）；(2) `grep ... || true` 吞 grep exit 2 → PASS（R4）；(3) 谓词 (d) 仅计数 `forceResetAndReload` 不验 P6 不变量（R6-high#1）；(4) marker 仅查存在不绑位置（R6-med#3）；(5) scope 用 `git diff main...HEAD` 依赖本地 main + `.swift/.py` 黑名单不 fail-closed（R6-high#2）。综合修：**数组 + `-r` 可读断言 + grep helper 区分 rc 0/1/>1(→exit2) + 纯 bash `case` 过滤 + (d) 验关键不变量短语 + (e) 位置绑定 heading<marker<stale + (f) merge-base diff allowlist**。(6) 过滤循环用 `done <<< "$HITS"` here-string，在不可写 TMPDIR 下静默失败 → 循环跳过 → fail-open（codex 最终 review FR1）。综合修加：**过滤循环改 `IFS=换行 + set -f` for-loop（无 here-string/临时文件依赖）+ 启动自检探针（迭代机制坏 → exit 2）**。下方脚本**已实测**：未编辑 repo → a-e FAIL（抓全部 stale）；源不可读 → exit 2；**不可写 TMPDIR → 仍正常判定不 fail-open**；(e) good/bad fixture 正确区分；zsh/bash 双兼容。

- [ ] **Step 1：读禁忌词清单**

Run: `grep -i "forbidden\|禁忌\|禁用" .claude/workflow-rules.json`
（确认 acceptance 文档不含禁忌措辞）

- [ ] **Step 2：写 fail-closed 验证脚本（逐字照抄，已实测）**

Create `scripts/governance/verify-wave2-pr1-rfc.sh`：
```bash
#!/usr/bin/env bash
# verify-wave2-pr1-rfc.sh — Wave 2 顺位 1 RFC grep gate (fail-closed)
# fail-closed 设计（codex plan R3-R6）：
#   - 源路径数组（zsh 不 word-split 标量）；跑前 -r 断言可读，不可读 → exit 2
#   - grep helper 区分 rc 0/1/>1（>1 读错误 → exit 2）；过滤用纯 bash case
#   - (d) 验 P6 恢复契约关键不变量（非仅计数）
#   - (e) marker 位置绑定（heading 后、首个 stale 短语前）
#   - (f) scope allowlist（merge-base diff，非 main 本地 ref；任何非白名单路径硬失败）
set -uo pipefail

sources=(
  "kline_trainer_modules_v1.4.md"
  "docs/governance/2026-05-17-wave0-signoff-ledger.md"
  "docs/governance/2026-06-01-wave1-completion.md"
  "docs/superpowers/specs/2026-05-19-wave1-outline-design.md"
)
outline="docs/superpowers/specs/2026-06-02-wave2-outline-design.md"
spec="docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md"
modules="kline_trainer_modules_v1.4.md"

allowlist=(
  "$spec"
  "docs/superpowers/plans/2026-06-03-wave2-pr1-baseline-h1-rfc.md"
  "$modules"
  "docs/governance/2026-05-17-wave0-signoff-ledger.md"
  "docs/governance/2026-06-01-wave1-completion.md"
  "docs/superpowers/specs/2026-05-19-wave1-outline-design.md"
  "$outline"
  "docs/acceptance/2026-06-03-wave2-pr1-baseline-h1-rfc.md"
  "scripts/governance/verify-wave2-pr1-rfc.sh"
)

for f in "${sources[@]}" "$outline" "$spec"; do
  [ -r "$f" ] || { echo "GATE FAIL: unreadable source $f"; exit 2; }
done

gg()  { HITS=$(grep -nE "$@"); local r=$?; [ "$r" -gt 1 ] && { echo "GATE FAIL: grep -E error rc=$r ($*)"; exit 2; }; return 0; }
ggF() { HITS=$(grep -nF "$@"); local r=$?; [ "$r" -gt 1 ] && { echo "GATE FAIL: grep -F error rc=$r ($*)"; exit 2; }; return 0; }
nonblank() { printf '%s' "$1" | tr -d '[:space:]'; }
lineno()  { grep -nE "$2" "$1" | head -1 | cut -d: -f1; }
linenoF() { grep -nF "$2" "$1" | head -1 | cut -d: -f1; }

# 行迭代 helper：用 IFS=换行 + noglob for-loop（无 here-string/临时文件依赖；codex 最终 review FR1：
# `done <<< "$HITS"` 在不可写 TMPDIR 下静默失败 → 循环跳过 → fail-open）。
# 启动自检：若行过滤机制坏掉 → exit 2（fail-closed），不进任何谓词。
probe=""; _oi=$IFS; IFS=$'\n'; set -f
for _l in $(printf 'keep\ndrop\n'); do case "$_l" in drop) continue ;; *) probe+="$_l" ;; esac; done
set +f; IFS=$_oi
[ "$probe" = "keep" ] || { echo "GATE FAIL: line-filter mechanism broken (TMPDIR/shell?)"; exit 2; }

rc=0

# (a) 4 源无 H1「同 PR」残留（纯 bash 过滤 E2 顺位8 + 1b/1c runbook）
gg "同 PR" "${sources[@]}"
a_hits=""; _oi=$IFS; IFS=$'\n'; set -f
for line in $HITS; do
  [ -z "$line" ] && continue
  case "$line" in
    *decoder*|*"顺位 8"*|*CONTRACT_VERSION*|*position_data*|*三连而非*) continue ;;
    *) a_hits+="$line"$'\n' ;;
  esac
done
set +f; IFS=$_oi
if [ -n "$(nonblank "$a_hits")" ]; then echo "(a) FAIL"; printf '%s' "$a_hits"; rc=1; else echo "(a) PASS"; fi

# (b) modules 交易/费用打包路径不调 fail-open snapshotFees（双向上下文，含 startNewNormalSession/NormalFlow.fees/打包；codex R8-high#1）
gg "snapshotFees" "$modules"
b_hits=""; _oi=$IFS; IFS=$'\n'; set -f
for line in $HITS; do
  [ -z "$line" ] && continue
  # context-first（codex R9-high#2：先判交易/打包语境，不让 fail-open 字样先掩盖）
  case "$line" in
    *startNewNormalSession*|*"NormalFlow.fees"*|*"打包"*) : ;;   # 有交易/打包语境 → 继续判定
    *) continue ;;                                               # 无语境（如 feature-name checklist）→ 跳过
  esac
  # 该语境行：用 fail-closed IfReady = 合法；否则（裸 fail-open snapshotFees 指引）→ FLAG
  case "$line" in *snapshotFeesIfReady*) continue ;; *) b_hits+="$line"$'\n' ;; esac
done
set +f; IFS=$_oi
# (b2) positive：snapshotFeesIfReady 签名在位（交易流 fail-closed 变体存在）
ggF "func snapshotFeesIfReady() throws -> FeeSnapshot" "$modules"; b2="$HITS"
if [ -n "$(nonblank "$b_hits")" ]; then echo "(b) FAIL: fee 打包仍指 fail-open snapshotFees"; printf '%s' "$b_hits"; rc=1;
elif [ -z "$b2" ]; then echo "(b) FAIL: 缺 snapshotFeesIfReady 签名（fail-closed 变体）"; rc=1;
else echo "(b) PASS"; fi

# (c) 3 源无 stale P4/P2 端口列 Wave 2 待办
c_hits=""
gg  "^- \[ \].*(P4 .DefaultAppDB. 实现|4 内部端口默认实现)" "$modules"; c_hits+="$HITS"$'\n'
gg  "P4 DefaultAppDB 实施|4 内部端口真实现" "docs/superpowers/specs/2026-05-19-wave1-outline-design.md"; c_hits+="$HITS"$'\n'
ggF "C8 / E5 / E6 / P2 / P4 / U1" "docs/governance/2026-06-01-wave1-completion.md"; c_hits+="$HITS"$'\n'
if [ -n "$(nonblank "$c_hits")" ]; then echo "(c) FAIL"; printf '%s' "$c_hits"; rc=1; else echo "(c) PASS"; fi

# (d) P6 恢复契约关键不变量写入 modules（非仅计数；codex R6-high#1 + R7-med#2）
#     必含：精确方法签名（code fence）+ AppSettings.default + reload-before-clear（settings=loaded）
#          + 失败保留 loadError + healthy-state 前置条件（loadError != / == nil）+ spec≥1
d_ok=1
ggF "func retryReload() async throws" "$modules"; [ -n "$HITS" ] || d_ok=0            # 非破坏签名（R8-high#2）
ggF "func forceResetAndReload(confirmation: SettingsResetConfirmation) async throws" "$modules"; [ -n "$HITS" ] || d_ok=0   # 破坏性签名 + confirmation marker（R7-med#2 + R9-high#1）
ggF "AppSettings.default"  "$modules"; [ -n "$HITS" ] || d_ok=0
gg  "self\.settings = loaded" "$modules"; [ -n "$HITS" ] || d_ok=0
gg  "保留.{0,4}loadError|loadError.{0,6}保留" "$modules"; [ -n "$HITS" ] || d_ok=0
gg  "loadError != nil|loadError == nil" "$modules"; [ -n "$HITS" ] || d_ok=0          # healthy-state 前置条件（R7-high#1）
ggF "_retryReloadFailed" "$modules"; [ -n "$HITS" ] || d_ok=0                          # state-enforced 顺序 flag（R9-high#1）
gg  "try\? loadSettings" "$modules"; [ -n "$HITS" ] || d_ok=0                            # 破坏前最后非破坏 reload（R10-high#1）
s=$(grep -cF "forceResetAndReload" "$spec"); [ $? -gt 1 ] && { echo "GATE FAIL: grep -c spec"; exit 2; }
[ "${s:-0}" -ge 1 ] || d_ok=0
if [ "$d_ok" -eq 1 ]; then echo "(d) PASS"; else echo "(d) FAIL: P6 恢复契约不全（modules 缺 精确签名/AppSettings.default/settings=loaded/保留 loadError/healthy-state 守卫 或 spec 缺）"; rc=1; fi

# (e) marker 位置绑定：### 3.1 heading 行 < marker 行 < 首个 stale 短语行（codex R6-med#3）
eh=$(linenoF "$outline" "### 3.1 顺位 1")
em=$(linenoF "$outline" "本节措辞已 superseded")
es=$(lineno  "$outline" "落地时同 PR 内|C2/C8/E5 orchestration 同 PR")
eh=${eh:-}; em=${em:-}; es=${es:-}
if [ -n "${eh}" ] && [ -n "${em}" ] && [ -n "${es}" ] && [ "${eh}" -lt "${em}" ] && [ "${em}" -lt "${es}" ]; then
  echo "(e) PASS"
else
  echo "(e) FAIL: supersede marker location wrong (need heading lt marker lt stale; heading=${eh} marker=${em} stale=${es})"; rc=1
fi

# (f) scope allowlist：merge-base diff 内每个改动文件须在白名单（codex R6-high#2）
base=$(git merge-base origin/main HEAD 2>/dev/null) || { echo "(f) FAIL: cannot compute merge-base origin/main"; exit 2; }
changed=$(git diff --name-only "$base" HEAD) || { echo "(f) FAIL: git diff error"; exit 2; }
f_bad=""; _oi=$IFS; IFS=$'\n'; set -f
for path in $changed; do
  [ -z "$path" ] && continue
  ok=0
  for a in "${allowlist[@]}"; do [ "$path" = "$a" ] && { ok=1; break; }; done
  [ "$ok" -eq 0 ] && f_bad+="$path"$'\n'
done
set +f; IFS=$_oi
if [ -n "$(nonblank "$f_bad")" ]; then echo "(f) FAIL: 非白名单改动文件（疑似 ios/SQL/YAML/.swift/.py/冻结 doc）:"; printf '%s' "$f_bad"; rc=1; else echo "(f) PASS"; fi

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
Expected: `(a) PASS` / `(b) PASS` / `(c) PASS` / `(d) PASS` / `(e) PASS` / `(f) PASS` / `ALL PASS` / `exit=0`
**注**：谓词 (f) 已用 merge-base diff + 显式 allowlist fail-closed 守护 scope（codex R6-high#2，取代旧 `git diff main...HEAD` + `.swift/.py` 黑名单）；任何非白名单路径（ios/SQL/YAML/冻结 doc 等）→ (f) FAIL。

- [ ] **Step 2：人工二次确认改动文件清单（与 (f) allowlist 互证）**

Run: `git diff --name-only "$(git merge-base origin/main HEAD)" HEAD`
Expected: 恰好 9 文件 = RFC spec + 本 plan + modules + ledger + wave1-completion + wave1-outline + wave2-outline + acceptance.md + verify-wave2-pr1-rfc.sh；**无** `docs/superpowers/plans/2026-05-*`、**无** `kline_trainer_plan_v1.5.md`、**无** `ios/`/`.swift`/`.py`/`.sql`/`.yml`

---

## Self-Review（plan↔spec 覆盖核对）

- **spec §三 scope**：item1→Task1；item2→Task2；item3→Task5；item4→Task6；item5→Task7；**item5b→Task7b**；item6→Task3 **+ Task3b（risk-table L2293/L2401，R8-high#1）**；item7→Task4；item8→Task8 ✅ 全覆盖
- **spec §四 P6 两层恢复契约**：Task4（retryReload 非破坏 + forceResetAndReload(confirmation:) 破坏性，**守卫编码进 state**：confirmation marker + _retryReloadFailed flag，R9-high#1；含 R2-high 状态转移 + R7-high healthy 守卫 + R8-high#2 两层）+ 谓词 (d) 验两签名 + flag ✅
- **spec §五 grep gate 六谓词 (a)-(f)**：Task8 fail-closed 脚本（已实测：a-e 抓 stale / (b) **context-first** 抓 adversarial fail-open 打包行〔R9-high#2〕/ 源不可读 exit2 / (e) 位置 fixture / (d) 签名 vs prose / (f) allowlist）✅
- **spec §二 编辑范围边界**：谓词 (f) merge-base allowlist 守护（仅 9 文件 / 非白名单硬 FAIL / 不碰 E2+冻结历史；Wave2 outline 是 live 例外 reconcile 目标）✅
- **类型/命名一致**：`forceResetAndReload` / `snapshotFeesIfReady` / `AppSettings.default` / marker `本节措辞已 superseded` 各处一致 ✅
- **无占位符**：所有编辑含 exact OLD/NEW；脚本逐字可照抄已实测；grep 谓词含 exact 命令 ✅
