# Wave 2 顺位 1 RFC — baseline reconciliation + H1 闭环 + P6 恢复契约

**性质**：纯文档 governance RFC（**0 业务代码**）。沿用 E2 RFC 先例（`project_pr64_e2rfc_merged`）：改 spec 本身 = governance，走单独设计文档。

**前置**：Wave 2 outline（`docs/superpowers/specs/2026-06-02-wave2-outline-design.md`）§三.1 已批准本锚 scope（user 2026-06-02 选 option a）。本设计把 outline §三.1 的 8 项 scope 落为精确编辑目标 + 决策钉死。

---

## 一、目标

三类契约变更经单一 RFC 钉死，避免散落各实施 PR（沿用 Wave 2 outline §三.3「契约变更集中在顺位 1 RFC」原则）：

- **(A) H1「同 PR」措辞松绑**：解「production handler 集成测试 C8+E5 落地时同 PR」与「≤500 行/PR + 按依赖拆 anchor」硬规则的直接冲突。语义要求是三模块（C2/C8/E5）**同时在场**时验证 orchestration，不要求**同一 PR 编写**；集成测试自然落在依赖链末端 C8 anchor。
- **(B) baseline reconciliation**：回填 `P4 DefaultAppDB` + `P2 4 内部端口`已 Wave 0 落地（PR #42/#43），消除全部 stale「Wave 2 待办」源，防 plan-stage grep 命中权威化的「重做已完成模块」指令。
- **(C) P6 `forceResetAndReload()` 恢复契约定义**：给 `SettingsStore.loadError` 死锁一条应用内恢复路径（PR4b 显式 defer 到此）。新公共 API 须有 spec owner，故契约在本 RFC 定义，顺位 10 U4 据此实施。

---

## 二、编辑范围边界（核心纪律）

只 reconcile **live 权威源**；**冻结的历史 plan/spec 文档是 point-in-time 记录，一律不改写**。

全仓 `同 PR` 命中 20+ 处，分三类：

| 类别 | 例子 | 处理 |
|---|---|---|
| **H1 live 权威源** | `kline_trainer_modules_v1.4.md` L1180/L1182；`docs/governance/2026-05-17-wave0-signoff-ledger.md` L32；`docs/governance/2026-06-01-wave1-completion.md` L43；`docs/superpowers/specs/2026-05-19-wave1-outline-design.md` L54/L124 | ✅ reconcile |
| **E2 顺位 8 bump「同 PR」**（语义完全不同：CONTRACT_VERSION bump 须与 decoder 同 PR） | `kline_trainer_modules_v1.4.md` L1494；`kline_trainer_plan_v1.5.md` L711；E2 RFC 系列 | ❌ 绝不碰，grep gate 显式排除 |
| **冻结历史 plan/spec**（point-in-time 记录） | `docs/superpowers/plans/2026-05-20-pr1a-*.md`；`docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md`；`docs/superpowers/specs/2026-05-17-pr9-wave0-freeze-design.md` 等 | ❌ 不改写 |

**例外（live 规划 doc，非冻结）**：`docs/superpowers/specs/2026-06-02-wave2-outline-design.md`（Wave 2 outline）是后续 anchor 的**当前**规划输入，不是 point-in-time 记录 → 列为 reconcile 目标 5b（§三），加 supersede banner（不删历史「现状/张力」引用，但标记已 superseded + 谓词 (e) 守护）。

---

## 三、Scope 八项 + 精确编辑目标

| # | 项 | 文件:行 | 动作 |
|---|---|---|---|
| 1 | §C1b 闸门#4 F3 措辞松绑 | `kline_trainer_modules_v1.4.md` L1180 + L1182 | 「C8 ChartContainerView + E5 TrainingEngine **落地时同 PR 内**」→「集成测试在 **C8 集成 anchor** 内验证（此时 E5a/E5b + C2 均已 merged，三模块在场）」；L1182 理由块补「同时在场 ≠ 同一 PR 编写；C8 是依赖链末端，集成测试自然落 C8 anchor」松绑理由 |
| 2 | §Wave 2 checklist 回填 | 同上 L2176（P2）+ L2177（P4） | 标注「✅ 已 Wave 0 落地（PR #42/#43）」；明确 Wave 2 仅剩 **P2 runner orchestration**（4 端口已做）；P4 整项已完成不再列待办 |
| 3 | ledger §28 H1 行 | `docs/governance/2026-05-17-wave0-signoff-ledger.md` L32 | 「真正闭环 = Wave 2 C8 集成 PR（C2/C8/E5 orchestration 同 PR）」→「真正闭环 = Wave 2 C8 集成 anchor（C2/C8/E5 三模块在场时验证）」 |
| 4 | completion H1 + §五 | `docs/governance/2026-06-01-wave1-completion.md` L43 + L80-82 | L43 H1 行措辞同步（同 #3）；§五 Wave 2 边界（L82）标注「P4 + P2 4 端口已 Wave 0 落地，Wave 2 仅 P2 runner」 |
| 5 | wave1-outline §六 | `docs/superpowers/specs/2026-05-19-wave1-outline-design.md` L54 + L124 | L124 Wave 2 范围列表标注「P4 DefaultAppDB + P2 4 内部端口已 Wave 0 落地（PR #42/#43），Wave 2 仅 P2 runner」；L54 H1 措辞同步 |
| 5b | **Wave 2 outline §三.1 supersede banner**（codex plan R4-high#1） | `docs/superpowers/specs/2026-06-02-wave2-outline-design.md` §3.1 | outline 是后续 anchor 规划输入，§3.1 仍含 stale `落地时同 PR 内`/`C2/C8/E5 orchestration 同 PR`（作历史「现状/张力」描述）。不删历史引用，加 supersede banner（含 marker `本节措辞已 superseded`）使后续 plan 读者先撞标记、不据旧字面重建约束。谓词 (e) 断言 banner 在位 |
| 6 | fee-callsite 措辞 | `kline_trainer_modules_v1.4.md` L2000 + L2040 | 「Coordinator.startNewNormalSession 内部调用 `settings.snapshotFees()`」→「调用 `settings.snapshotFeesIfReady()`（loadError 时 throws，禁 fail-open）」+ 写明交易路径 fail-closed 理由 |
| 7 | **P6 恢复契约定义** | RFC 本文件 §四 + `kline_trainer_modules_v1.4.md` §P6（L1988-2012 区块）补契约引用 | 见 §四 |
| 8 | grep gate | RFC 本文件 §五 + `docs/acceptance/<PR>.md` | 见 §五 |

**0 业务代码改动**（仅 spec/governance/RFC 文档 + acceptance + 1 验证 shell 脚本 `scripts/governance/verify-wave2-pr1-rfc.sh`；无 `.swift`/`.py`）。

---

## 四、P6 `forceResetAndReload()` 恢复契约（选项 1：SettingsStore 新增公共方法，不改 DAO）

### 4.1 问题

`SettingsStore`（`ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`）现状：init eager-load 失败 → `_loadError` set → `update`/`resetCapital` 全阻塞（L50/L69）；`snapshotFeesIfReady()` throws（L96）。**重启对持久损坏 DB 无效**（每次 load 都失败）→ 用户无应用内恢复手段。L40 注释显式 defer：「极端情况靠 Wave 2 U4 显式 reset 按钮（本 PR 不做）」。PR4b plan L190/L222 同 defer。

### 4.2 契约定义（RFC 钉死，顺位 10 U4 据此实施，不自定义公共面）

- **API 形态**：`SettingsStore` 新增 `public func forceResetAndReload() async throws`。**不改** Wave 0 冻结的 `SettingsDAO` 协议（现 3 方法 `loadSettings`/`saveSettings`/`resetCapital`）。
  - **理由**：恢复逻辑（loadError 下仍允许、清错误位、解阻交易）是 SettingsStore 状态机职责，非 DAO 存储职责；现有 DAO surface（`saveSettings` 幂等覆盖 + `loadSettings`）已足以拼出恢复语义，无需动多实现 + fake 的冻结协议。
- **前置条件**：**`loadError` set 下仍允许执行**——这是唯一绕过 loadError 写守卫的路径（`update`/`resetCapital` 仍被阻塞）。
- **语义（须显式状态转移，防解阻后读 stale settings；codex plan R2-high 修）**：`saveSettings(AppSettings.default)` 覆盖损坏状态 → `let loaded = try loadSettings()` 验证 → **在 MainActor 上先 `self.settings = loaded` 再 `_loadError = nil`**（解阻 `update`/`resetCapital`/交易 `snapshotFeesIfReady`）。**关键不变量**：必须先把 reloaded 值赋回 `settings` 再清错误位——`SettingsStore` 进 loadError 时 `settings` 是 init 的 `zeroDefault`（zero fee/capital），若只清错误位不刷新 `settings`，解阻后 `snapshotFeesIfReady()` 仍读 stale zero settings，重新引入本 RFC 要防的 zero-fee/zero-capital 失败。
- **reset 目标值**：`AppSettings.default` —— **命名默认值，含合理起始本金（非 0 资本）**，使 reset 后用户能直接开始训练。清全部 4 字段（`commissionRate`/`minCommissionEnabled`/`totalCapital`/`displayMode`）到 default。该常量在**顺位 10 实施时引入**（顺位 1 docs-only 不写代码；当前 `AppSettings` 仅有 init，`SettingsStore` 内 private `zeroDefault` 是 capital 0，不复用为 reset 目标）。
- **错误处理**：若 `saveSettings`/重 load 仍失败（DB 物理不可写）→ throws，`_loadError` **保持**（不静默清成功态；调用方据 throws 提示用户/上报）。
- **acceptance（顺位 10 验收）**：malformed settings → `loadError` set → `forceResetAndReload()` → load 成功 → `loadError == nil` **且 `store.settings == AppSettings.default`**（状态已刷新非 stale zeroDefault）→ `update`/交易解阻 **且 `snapshotFeesIfReady()` 返回 `AppSettings.default` 对应 fee snapshot（非 zero）**；失败路径 → `loadError` 保留 + throws。

---

## 五、grep gate 精确化（acceptance 项，非裸 grep）

三谓词，**全部锚定具体短语 + 排除已知合法残留**，防 codex 拿裸 `同 PR` 无限挑战（per `feedback_acceptance_grep_anchoring` + `feedback_codex_distributed_reliability_drilldown`）：

- **(a) 无 H1「同 PR」残留**：锚定精确短语 `C2/C8/E5 orchestration 同 PR` 与「落地时同 PR 内」，搜索范围**仅限 4 个 live 权威源**（modules + ledger + wave1-completion + wave1-outline §六）；**显式排除** E2 顺位 8 bump 短语（`MANDATORY 与 decoder 代码同 PR` / `顺位 8` 上下文）与 `docs/superpowers/plans/` `docs/superpowers/specs/`（changelog/历史）下文档。pass = 4 源命中 0。
- **(b) 交易路径不调 fail-open `snapshotFees()`**：grep modules `startNewNormalSession` 费用打包上下文（L2000/L2040 区块）须为 `snapshotFeesIfReady`，不出现裸 `snapshotFees()` 作为交易路径调用。pass = 交易路径区块命中 0 个裸 `snapshotFees()`。
- **(c) 无 stale「P4 DefaultAppDB / P2 4 内部端口」列为 Wave 2 待办**：锚定「Wave 2 checklist 未勾选 `- [ ]`」语境，**全部 3 个 live 权威源都查**（codex plan R2-medium 修，最终 gate 不得漏源）：(c1) modules §Wave 2 未勾选项不含 `P4 .DefaultAppDB. 实现`/`4 内部端口默认实现`；(c2) wave1-outline §六不含 `P4 DefaultAppDB 实施`/`4 内部端口真实现`；(c3) wave1-completion §五不含旧边界串 `C8 / E5 / E6 / P2 / P4 / U1`。**排除**架构描述性提及（modules L19/L53/L59/L1736 等非 todo）、本 RFC 自身引用、Wave 2 outline §〇、changelog。pass = 三源全 0 命中。

- **(e) Wave 2 outline supersede marker 在位**（codex plan R4-high#1）：`grep -F "本节措辞已 superseded" docs/superpowers/specs/2026-06-02-wave2-outline-design.md` 命中 ≥1；防后续 anchor plan 读 outline §3.1 旧「同 PR」字面重建约束。

**grep gate 实现归属**：谓词封装为独立 fail-closed 脚本 `scripts/governance/verify-wave2-pr1-rfc.sh`，acceptance `docs/acceptance/<PR>.md` 调它（per `feedback_acceptance_grep_anchoring`：负向断言用 `if grep ...; then exit 1`，不用 `set -e` 下 `! grep` 死闸门）。**fail-closed 要求（codex plan R3/R4-high）**：(1) 源路径用**数组**（仓库默认 zsh 不 word-split 标量，`grep $SCALAR` 把整串当单一文件名 → 读取失败被转成 PASS）；(2) 跑前 `-r` 断言每个源可读；(3) grep 包 helper 区分 rc 0(命中)/1(无命中)/**>1(读错误/坏正则 → 立即 exit 2)**，不用 `grep ... || true`（会把 exit 2 也吞成 PASS）；(4) 排除/过滤用纯 bash `case` 不用 `grep|grep -v`。脚本须实测：未编辑 repo → GATE FAIL exit 1；源不可读 → exit 2。

---

## 六、明确 OUT of scope

- 不执行任何 `CONTRACT_VERSION`/m01 bump（本 RFC 无业务代码语义收紧；P6 恢复 API 是新增公共面非已 shipped 语义收紧）
- 不改写冻结历史 plan/spec（§二）
- 不实施 `forceResetAndReload()` 代码 / 不引入 `AppSettings.default` 常量（均顺位 10 U4）
- 不改 `SettingsDAO` 协议（Wave 0 冻结）
- 不打 tag（Wave 2 沿用轻量收尾，outline §三.3 预声明）
- 后端 / NAS / 部署类 residual 不在 Wave 2 scope

---

## 七、codex review 策略（Task 0，per outline §五）

- plan-stage：`codex-attest.sh --scope working-tree --focus <plan>`；4-5 轮内收敛。
- branch-diff：`codex-attest.sh --scope branch-diff`；4-5 轮内收敛。
- 超 5 轮 escalate user → attestation residual + admin merge（**不绕 required checks**；per `feedback_codex_plan_budget_overshoot` + `feedback_big_pr_codex_noncovergence`）。
- 本 PR docs-only，不触 Catalyst CI required check（无 iOS 代码改动）。codex 周配额耗尽则 opus 4.7/4.8 xhigh fallback（per `feedback_subagent_quota_fallback_must_ask`：先问）。

---

## 八、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-03 | v1 | 起草；落 Wave 2 outline §三.1 的 8 项 scope 为精确编辑目标；P6 恢复契约选项 1（user 2026-06-03 确认）；grep gate 三谓词精确化；编辑范围限 live 权威源 |
