# Wave 2 outline（v2）—— 集成 wave 单线顺位

**前置**：Wave 1 全 21 anchor 已 merged（PR #56-#77；轻量收尾 PR #77 merged 2026-06-01，**未打 freeze tag**，见 `docs/governance/2026-06-01-wave1-completion.md`）。本 outline 规划 Wave 2「集成」阶段的执行顺位。

**目的**：列出 Wave 2 全部 anchor PR 的顺序 + 范围概要 + 依赖 + residual 折入策略，作为后续每锚 `superpowers:brainstorming` + `writing-plans` 的输入索引。本文件**仅**是顺位 + Phase + residual 映射 outline；每个顺位 PR 的实施细节（init 签名 / 测试矩阵 / orchestration 接线 / acceptance 详情）由该顺位 plan-stage 文档承担 + 自有 codex review 闭环。

**outline 抽象层级纪律（沿用 Wave 1 v18 strip 教训）**：本 outline **不内联** 具体 API 签名、测试 case 矩阵、orchestration 命令序列、DDL/schema。Wave 1 outline v1-v17 因在表内联实施细节触发 branch-diff codex 18 轮"挖边界"无止境模式；v18 strip 至 outline 应有抽象层级才收敛。本文件遵守同一纪律——所有约束表达为**契约归属**而非代码。

---

## 〇、Wave 2 真实缺失面核实（baseline reconciliation）

**关键校正（codex branch-diff R1 finding 1）**：modules §Wave 2 checklist（`kline_trainer_modules_v1.4.md` L2171-2180）与 Wave 1 outline §六 列出的 8 个 Wave 2 模块**部分 stale**——其中 **P4 与 P2 的 4 内部端口实际已在 Wave 0 落地**。本 outline 以下表为权威（基于 `git log` + 实际代码文件核实，2026-06-02）：

| spec 列出的 Wave 2 项 | 实际状态 | 证据 | 归属 |
|---|---|---|---|
| C8 ChartContainerView | **缺失** | 无 ChartContainerView.swift（仅 `Render/KLineRenderState.swift` 引用） | **Wave 2** |
| E5 TrainingEngine | **stub** | `TrainingEngine/TrainingEngine.swift` init 即 `fatalError("Wave 0 stub")` | **Wave 2** |
| E6 TrainingSessionCoordinator | **stub** | `TrainingEngine/TrainingSessionCoordinator.swift` 8 个 `fatalError` | **Wave 2** |
| P2 DownloadAcceptanceRunner + 4 内部端口 | **端口已做 / runner 缺失** | 4 Default 端口已 production impl（`KlineTrainerPersistence/DefaultZipIntegrityVerifier.swift` 等 + `Internal/AcceptanceJournalDAOImpl.swift`，PR #43 PR4a Wave 0）；`DownloadAcceptanceRunner` 未建 | **Wave 2 = 仅 runner** |
| P4 `DefaultAppDB` 实现 | **已完成（Wave 0）** | `KlineTrainerPersistence/DefaultAppDB.swift` 真实 GRDB composition root + migrator + 4 extension（PR #42/#43 + P4-record/pending/settings/journal commits） | **不在 Wave 2** |
| U1 HomeView | **缺失** | `UI/` 仅 Wave 1 的 U3/U5/U6 | **Wave 2** |
| U2 TrainingView | **缺失** | 同上 | **Wave 2** |
| U4 SettingsPanel | **缺失** | 同上 | **Wave 2** |

**结论**：Wave 2 真实缺失面 = **7 模块**（C8 / E5 / E6 / P2-runner / U1 / U2 / U4），**P4 已完成不列入**，**P2 仅缺 runner orchestration（4 端口已做）**。顺位 1 RFC 一并把此 reconciliation 回填进 spec checklist（见 §三.1），消除 stale 列。

---

## 一、排序策略

- **单线 anchor**：沿用 Wave 0 v6 / Wave 1 v20 单线模式（用户 2026-06-02 确认全部按推荐）。
- **每 PR ≤3 子项 / ≤500 行 prod**（per memory `feedback_planner_packaging_bias`）。E5/E6 两个大模块预计单模块 >500 行，按需拆为子 anchor（见 §三.2）。
- **codex 4-5 轮内收敛**（per `feedback_codex_plan_budget_overshoot`；超 5 轮 escalate user）。
- **scope shrink before split**：先 grep 验证文档归属（per `feedback_brainstorming_grep_first`）；同模块 brainstorming abort ≥2 次 = 换 anchor 或开独立 spec 升级窗口（per `feedback_module_level_abort_signal`）。
- **依赖拓扑驱动顺位**：关键链 `E5 → {E6, C8}`；`E6 → U1`；`C8 → U2`；`P2-runner → {U1, U4}`。

---

## 二、顺位总览（10 anchor）

| 顺位 | Anchor | 组 | 范围估算 | 依赖（仅列上游 Wave 2） | 关键 residual 折入 |
|---|---|---|---|---|---|
| 1 | **baseline reconciliation + H1 RFC**（modules §C1b 闸门 #4 F3「同 PR」措辞松绑 + §Wave 2 checklist 回填 P4/P2-端口已完成 + §15.4 ledger H1 行 + wave1-completion.md H1 行 全部 reconcile） | governance | 仅 spec/ledger/governance 文档；0 业务代码 | — | H1 措辞松绑 + baseline reconcile（见 §三.1） |
| 2 | E5a TrainingEngine 核心（init + 运行时状态 + accessors） | 业务逻辑 | ~300 行 | — | — |
| 3 | E5b TrainingEngine 动作（buy/sell + 模式切换 + onSceneActivated 中继） | 业务逻辑 | ~300 行 | E5a | — |
| 4 | E6a TrainingSessionCoordinator 会话构造（start/resume/review/replay + DI init） | 业务逻辑 | ~300 行 | E5（a+b） | — |
| 5 | E6b TrainingSessionCoordinator 持久化生命周期（saveProgress/finalize/endSession） | 业务逻辑 | ~250 行 | E6a | — |
| 6 | P2 DownloadAcceptanceRunner orchestration + `retryPendingConfirmations`（接线已有 4 端口 + 7 步 journal 状态机） | 持久化 | ~300-500 行（plan 阶段若超 500 再拆 run/runBatch + retry） | — | — |
| 7 | **C8 ChartContainerView + H1 production handler 集成测试** | 图表集成 | ~250 行 + 集成测试 | E5（a+b） | **H1 close** + C3-C6 渲染收口 + C8 性能（见 §四） |
| 8 | U1 HomeView | UI | ~250 行 SwiftUI | E6（a+b） + P2 | — |
| 9 | U2 TrainingView | UI | ~300 行 SwiftUI | E5（a+b） + C8 | C2/C7 运行时验收（见 §四） |
| 10 | U4 SettingsPanel | UI | ~250 行 SwiftUI | P2 | — |

**Phase 划分**：
- A 治理前置（1：baseline reconciliation + H1 RFC）
- B 训练运行时 + 会话编排（2-5：E5a/E5b/E6a/E6b）
- C 下载验收编排（6：P2 runner）
- D 图表集成 + H1 闭环（7：C8）
- E UI 顶层装配（8-10：U1/U2/U4）

**依赖满足校验**（每锚上游均在更早顺位 merged 或 Wave 0/1 已完成）：2 E5a(无 Wave 2 依赖) → 3 E5b(需 2) → 4 E6a(需 2+3；P4/P3a/P5/P6 Wave 0 已完成) → 5 E6b(需 4) → 6 P2(无 Wave 2 依赖；4 端口/P1/P4-journal/P5 Wave 0 已完成) → 7 C8(需 2+3，C2 Wave 1 已落) → 8 U1(需 4+5+6) → 9 U2(需 3+7) → 10 U4(需 6)。无逆向依赖。

---

## 三、关键决策

### 3.1 顺位 1：baseline reconciliation + H1 闭环 RFC（先松绑「同 PR」措辞）

**现状字面**（modules §C1b 闸门 #4 F3，v1.4，仓库 L1178-1182）：production handler 集成测试的 **Wave 2 验收**（L1180）写明「C8 ChartContainerView + E5 TrainingEngine **落地时同 PR 内**」；§15.4 ledger H1 行（仓库 L32）与 `docs/governance/2026-06-01-wave1-completion.md` H1 行同样写「C2/C8/E5 orchestration 同 PR」。

**张力**：E5 单模块预计 >500 行需拆 E5a/E5b（§三.2）；C8 是桥接层独立 anchor。「同 PR 落地」与「≤500 行/PR + 按依赖拆 anchor」硬规则直接冲突。

**决策（user 2026-06-02 选 option a）**：顺位 1 开**纯文档 governance PR**（沿用 E2 RFC 先例，per `project_pr64_e2rfc_merged`），重审并松绑措辞——把「C8 + E5 **落地**同 PR」改为「集成测试在 **C8 集成 anchor** 内验证（此时 E5a/E5b + C2 均已 merged，三模块在场）」。

**理由**：production handler 集成测试的语义要求是「C2 + C8 + E5 三模块**同时在场**时验证 orchestration 正确（handler 先 `animator.stop()` 再算 range；drawing 退出后无 `offsetApplied` 到达 reducer）」——这要求三模块**都已合入代码库**，不要求**同一个 PR 编写**。C8 是依赖链末端（需 E5），集成测试自然落在 C8 anchor。先经 RFC 把 spec 措辞钉死，避免 codex 在 C8 实施 PR 中途拿 spec 字面"同 PR"无限挑战（per `feedback_codex_distributed_reliability_drilldown` 同类无止境下钻风险）。

**顺位 1 RFC scope（codex R1 F2：必须 reconcile 全部 live governance 权威源，否则 stale 措辞保留同一挑战路径）**：
1. `kline_trainer_modules_v1.4.md` §C1b 闸门 #4 F3 Wave 2 验收措辞松绑 + 写明松绑理由块。
2. `kline_trainer_modules_v1.4.md` §Wave 2 checklist（L2171-2180）回填：P4 + P2 4 端口标注「已 Wave 0 落地」（消除 §〇 所列 stale 项）。
3. `docs/governance/2026-05-17-wave0-signoff-ledger.md` §28 H1 行措辞同步。
4. `docs/governance/2026-06-01-wave1-completion.md` H1 行（仓库 L43）措辞同步。
5. **grep gate**（acceptance 项）：RFC merge 后断言全仓无未被 supersede 的 `同 PR` / `C2/C8/E5 orchestration 同 PR` 残留措辞（除本 outline + RFC 自身的引用 / changelog）。
- 0 业务代码改动。

**顺位 7 C8**：ChartContainerView 桥接实现 + production handler 集成测试落地 → **H1 真正闭环**；严格按 RFC 决议；撞 ≥3 轮 codex 立即 escalate（per `feedback_big_pr_codex_noncovergence`）。

### 3.2 E5 / E6 拆子 anchor；P2 单 anchor（端口已 Wave 0 做）；P4 不列入

**Why split E5/E6**：两模块各自全量实现预计 >500 行 prod（含 tests），违反 `feedback_planner_packaging_bias`「≤3 子项 / ≤500 行」硬规则 + 大 PR codex 易陷长轮次 needs-attention（per C7 十五轮 / B4 十轮教训）。

- **E5 → E5a + E5b**：E5a = init + 运行时状态（tick/position/cashBalance/drawdown/markers/drawings/panels/tradeOperations）+ accessors（currentTotalCapital/holdingCost/returnRate/maxDrawdown/buyEnabled/sellEnabled）；E5b = 交易动作（buy/sell → Result）+ 模式切换（switchPeriodCombo/activateDrawingTool/deleteDrawing）+ onSceneActivated 场景生命周期中继。**拆点理由**：状态/读取面与变更/副作用面分离，E5b 依赖 E5a 已建状态。
- **E6 → E6a + E6b**：E6a = 4 个构造 engine 的方法（startNewNormalSession/resumePending/review/replay）+ DI init；E6b = 持久化生命周期（saveProgress/finalize/endSession）。**拆点理由**：构造面（读 + 装配 engine）与回写面（写 record/pending + 清理）分离。

- **P2 单 anchor（不拆 P2a/P2b）**：原计划的 4 内部端口默认实现（P2a）**已在 Wave 0 PR #43 落地**（§〇）。Wave 2 仅剩 runner orchestration（run/runBatch/retryPendingConfirmations 接线已有端口 + 7 步 journal 状态机）→ 单 anchor。plan 阶段实测若超 500 行再拆 run/runBatch 与 retry。
- **P4 不列入**：`DefaultAppDB` 已 Wave 0 完成（§〇）。

---

### 3.3 Wave 2 收尾：沿用轻量收尾，不打 freeze tag（预声明）

**决策（user 2026-06-02 选轻量）**：Wave 2 是按已冻 spec 实现「集成层」（spec 契约仅 H1 措辞 + baseline reconciliation RFC，已逐 PR review），**无 spec 契约首冻语义**——沿用 Wave 1 收尾模式（per `project_wave1_completion_2026_06_01`）：结尾走轻量 completion doc（anchor 清单 + residual 终态回填）+ **不打 `wave2-frozen` tag / 不建 signoff ledger / 不改 README freeze 章节**。

**说明**：此为 outline 预声明方向；Wave 2 末再正式确认。若届时需要正式冻结基线（如 Wave 3 启动前），可后补 tag。

---

## 四、Residual 处理映射

| Residual | 来源 | 处理方式 | 顺位 |
|---|---|---|---|
| H1 production handler 集成测试 | Wave 0 §15.4 ledger / `project_pr50_pr7b3_merged` | 顺位 1 RFC 松绑措辞 + 顺位 7 C8 集成测试落地真正闭环 | 1 + 7 |
| C3-C6 渲染 residual（交 C8 Wave 2 的渲染收口项） | `project_pr66/67/68/69_merged` | 折入顺位 7 C8 集成 PR 评估（buildRenderState 计算 volumeRange/macdRange 用 `NonDegenerateRange.make`；C8 plan 阶段逐项核对各 C3-C6 deferred 项是否在 C8 scope） | 7 |
| C8 性能（buildRenderState <4ms / 120Hz） | spec Phase 1 §10 + modules §C8 | 顺位 7 C8 acceptance 项（plan 阶段定验证方式；Instruments 或等价；**须具体验收证据，非仅编译通过**） | 7 |
| **C2/C7 运行时 gate**（CADisplayLink 运行时验证 / 双识别器手势运行时行为；Catalyst CI 仅 build-for-testing 编译，不跑运行时） | `project_pr60/61_merged` 接受 residual | **纳入 Wave 2 净 residual 责任**（codex R1 F3）：顺位 7 C8（CADisplayLink/buildRenderState 运行时）+ 顺位 9 U2（手势仲裁运行时）须产出**具体验收 artifact**（simulator/device 手动证据 或 专门 test-infra PR）方可在收尾 doc 标 close；不得仅凭编译通过宣告 Wave 2 clean | 7 + 9 |
| W1-R1 docker image digest pin | `project_wave1_completion_2026_06_01` | **不在 Wave 2 scope**：归 NAS 部署 PR | — |
| W1-R2 3-5 样本训练组数据 | 同上（H7） | **不在 Wave 2 scope**：需 NAS 真实数据源 | — |
| B4-R1/R4/R5/R6（清理职责3 / 部署编排 / advisory lock conn-scoped / near-term retry） | `project_pr76_b4_scheduler_merged` | **不在 Wave 2 scope**：归后续部署 / 可靠性加固 PR | — |

**Wave 2 净 residual 责任**：H1（顺位 1+7 闭环）+ C3-C6 渲染收口（顺位 7）+ C8 性能（顺位 7，须具体证据）+ **C2/C7 运行时 gate（顺位 7+9，须具体验收 artifact）**；后端 / 部署 / NAS 类 residual 明确**不在 Wave 2 scope**。

---

## 五、每锚 plan 流程统一约束

每个 Wave 2 anchor PR 走以下流程（沿用 Wave 1，per `docs/governance/wave1-plan-template.md`）：

1. **Task 0 §15.3 评审策略前置**（codex attest 通道 / opus xhigh fallback 触发条件）
2. **brainstorming**（superpowers:brainstorming）：scope / 路线 / 关键风险点
3. **grep-first 验证文档归属**（per `feedback_brainstorming_grep_first`）—— **特别核实模块实际代码状态（非仅读 spec checklist；§〇 教训：spec Wave 2 列可能 stale）**
4. **writing-plans**（superpowers:writing-plans）+ codex plan-stage adversarial review（4-5 轮内收敛；`codex-attest.sh --scope working-tree --focus <plan>`）
5. **subagent-driven-development** 实施 + verification-before-completion + requesting-code-review
6. **codex branch-diff adversarial review**（`--scope branch-diff`；4-5 轮内收敛；超 5 轮 escalate user 走 attestation residual + admin merge 路径，**不绕过 required checks**）
7. **non-coder acceptance checklist**（中文，action / expected / pass-fail；禁忌词见 `.claude/workflow-rules.json`）
8. **memory 落地**：merge 后写 `project_pr<N>_<anchor>_merged.md` + 更新 `MEMORY.md` index

**iOS PR Catalyst CI 强制**：顺位 2-10 均触 `Mac Catalyst build-for-testing on macos-15` required check（Wave 1 1a/1c 已建 always-trigger workflow + required gate）；本地 swift test 绿不等于 CI 绿（per `feedback_swift_local_toolchain_blindspot`）。**注**：Catalyst required check 仅验证 build-for-testing（编译 + 链接），**不执行运行时**——C2/C7/C8 的运行时行为须另行验收（见 §四 C2/C7 行）。

---

## 六、不在 Wave 2 顺位的工作

- **Wave 3 范围**：Phase 2.5 水平线 MVP / Phase 3 完整流程（normal/review/replay 端到端）/ Phase 5 磨光。
- **部署 / NAS 类**：W1-R1（image digest pin）、W1-R2（样本数据生产）、B4 部署编排 residual —— 归独立 NAS 部署 / 数据生产任务。
- **已完成（不重做）**：P4 `DefaultAppDB`、P2 4 内部端口默认实现（均 Wave 0 已落，§〇）。

---

## 七、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-02 | v1 (draft) | 起草；12 anchor 单线（含 P4 + P2a/P2b）；user 2026-06-02 确认全部按推荐（option a RFC / 按需拆 / 轻量收尾） |
| 2026-06-02 | v2 (branch-diff codex R1 修) | **F1**（high）：核实 P4 `DefaultAppDB` + P2 4 端口已 Wave 0 落地 → 删 P4 anchor、P2 收缩为单一 runner anchor、加 §〇 baseline reconciliation 表（文件/commit 证据）、12→10 anchor、依赖图重算；**F2**（high）：顺位 1 RFC scope 扩到 `wave1-completion.md` H1 行 + modules §Wave 2 checklist 回填 + grep gate 防残留「同 PR」，更名为「baseline reconciliation + H1 RFC」；**F3**（med）：C2/C7 运行时 gate 纳入 Wave 2 净 residual 责任 + 要求顺位 7/9 具体验收 artifact（非仅编译）+ §五 注明 Catalyst CI 仅编译不跑运行时 |
