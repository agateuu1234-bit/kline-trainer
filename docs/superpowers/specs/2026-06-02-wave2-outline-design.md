# Wave 2 outline（v1）—— 集成 wave 单线顺位

**前置**：Wave 1 全 21 anchor 已 merged（PR #56-#77；轻量收尾 PR #77 merged 2026-06-01，**未打 freeze tag**，见 `docs/governance/2026-06-01-wave1-completion.md`）。本 outline 规划 Wave 2「集成」阶段的执行顺位。

**目的**：列出 Wave 2 全部 anchor PR 的顺序 + 范围概要 + 依赖 + residual 折入策略，作为后续每锚 `superpowers:brainstorming` + `writing-plans` 的输入索引。本文件**仅**是顺位 + Phase + residual 映射 outline；每个顺位 PR 的实施细节（init 签名 / 测试矩阵 / orchestration 接线 / acceptance 详情）由该顺位 plan-stage 文档承担 + 自有 codex review 闭环。

**outline 抽象层级纪律（沿用 Wave 1 v18 strip 教训）**：本 outline **不内联** 具体 API 签名、测试 case 矩阵、orchestration 命令序列、DDL/schema。Wave 1 outline v1-v17 因在表内联实施细节触发 branch-diff codex 18 轮"挖边界"无止境模式；v18 strip 至 outline 应有抽象层级才收敛。本文件遵守同一纪律——所有约束表达为**契约归属**而非代码。

---

## 一、排序策略

- **单线 anchor**：沿用 Wave 0 v6 / Wave 1 v20 单线模式（用户 2026-06-02 确认全部按推荐）。
- **每 PR ≤3 子项 / ≤500 行 prod**（per memory `feedback_planner_packaging_bias`）。E5/E6/P2 三个大模块预计单模块 >500 行，按需拆为子 anchor（见 §三.2）。
- **codex 4-5 轮内收敛**（per `feedback_codex_plan_budget_overshoot`；超 5 轮 escalate user）。
- **scope shrink before split**：先 grep 验证文档归属（per `feedback_brainstorming_grep_first`）；同模块 brainstorming abort ≥2 次 = 换 anchor 或开独立 spec 升级窗口（per `feedback_module_level_abort_signal`）。
- **依赖拓扑驱动顺位**：关键链 `P4 → E6 → U1`；`E5 → C8 → U2`；`P4 → P2 → {U1, U4}`。

---

## 二、顺位总览（12 anchor）

| 顺位 | Anchor | 组 | 范围估算 | 依赖（仅列上游 Wave 2） | 关键 residual 折入 |
|---|---|---|---|---|---|
| 1 | **H1 RFC**（modules §C1b 闸门 #4 F3 + §15.4 ledger H1 行措辞重审 governance PR） | governance | 仅 spec/ledger 文档；0 业务代码 | — | H1 措辞松绑（见 §三.1） |
| 2 | P4 `DefaultAppDB` 实现（组合 4 protocol over 单一 GRDB queue） | 持久化 | ~300-500 行 Swift（plan 阶段若超 500 再拆 record+pending / settings+journal） | — | — |
| 3 | E5a TrainingEngine 核心（init + 运行时状态 + accessors） | 业务逻辑 | ~300 行 | — | — |
| 4 | E5b TrainingEngine 动作（buy/sell + 模式切换 + onSceneActivated 中继） | 业务逻辑 | ~300 行 | E5a | — |
| 5 | E6a TrainingSessionCoordinator 会话构造（start/resume/review/replay + DI init） | 业务逻辑 | ~300 行 | P4 + E5（a+b） | — |
| 6 | E6b TrainingSessionCoordinator 持久化生命周期（saveProgress/finalize/endSession） | 业务逻辑 | ~250 行 | E6a | — |
| 7 | P2a DownloadAcceptanceRunner 4 内部端口默认实现 | 持久化 | ~300 行 | — | — |
| 8 | P2b DownloadAcceptanceRunner orchestration + `retryPendingConfirmations` | 持久化 | ~300 行 | P2a + P4 | — |
| 9 | **C8 ChartContainerView + H1 production handler 集成测试** | 图表集成 | ~250 行 + 集成测试 | E5（a+b） | **H1 close**（见 §三.1） |
| 10 | U1 HomeView | UI | ~250 行 SwiftUI | E6（a+b） + P2（a+b） | — |
| 11 | U2 TrainingView | UI | ~300 行 SwiftUI | E5（a+b） + C8 | — |
| 12 | U4 SettingsPanel | UI | ~250 行 SwiftUI | P2（a+b） | — |

**Phase 划分**：
- A 治理前置（1：H1 RFC）
- B 持久化根基（2：P4）
- C 训练运行时 + 会话编排（3-6：E5a/E5b/E6a/E6b）
- D 下载验收（7-8：P2a/P2b）
- E 图表集成 + H1 闭环（9：C8）
- F UI 顶层装配（10-12：U1/U2/U4）

**依赖满足校验**（每锚上游均在更早顺位 merged）：2 P4(无依赖) → 4 E5b(需 3) → 5 E6a(需 2+3+4) → 6 E6b(需 5) → 8 P2b(需 7+2) → 9 C8(需 3+4，C2 Wave 1 已落) → 10 U1(需 5+6+8) → 11 U2(需 4+9) → 12 U4(需 8)。无逆向依赖。

---

## 三、关键决策

### 3.1 H1 闭环：先 RFC 松绑「同 PR」措辞，再由 C8 anchor 闭环

**现状字面**（modules §C1b 闸门 #4 F3，v1.4，仓库 L1178-1182）：production handler 集成测试的 **Wave 2 验收**（L1180）写明「C8 ChartContainerView + E5 TrainingEngine **落地时同 PR 内**」；§15.4 ledger H1 行（仓库 L32）同样写「C2/C8/E5 orchestration 同 PR」。

**张力**：E5 单模块预计 >500 行需拆 E5a/E5b（§三.2）；C8 是桥接层独立 anchor。「同 PR 落地」与「≤500 行/PR + 按依赖拆 anchor」硬规则直接冲突。

**决策（user 2026-06-02 选 option a）**：顺位 1 开**纯文档 RFC governance PR**（沿用 E2 RFC 先例，per `project_pr64_e2rfc_merged`），重审并松绑措辞——把「C8 + E5 **落地**同 PR」改为「集成测试在 **C8 集成 anchor** 内验证（此时 E5a/E5b + C2 均已 merged，三模块在场）」。

**理由**：production handler 集成测试的语义要求是「C2 + C8 + E5 三模块**同时在场**时验证 orchestration 正确（handler 先 `animator.stop()` 再算 range；drawing 退出后无 `offsetApplied` 到达 reducer）」——这要求三模块**都已合入代码库**，不要求**同一个 PR 编写**。C8 是依赖链末端（需 E5），集成测试自然落在 C8 anchor。先经 RFC 把 spec 措辞钉死，避免 codex 在 C8 实施 PR 中途拿 spec 字面"同 PR"无限挑战（per `feedback_codex_distributed_reliability_drilldown` 同类无止境下钻风险）。

- **顺位 1 RFC**：仅修订 `kline_trainer_modules_v1.4.md` §C1b 闸门 #4 F3 Wave 2 验收措辞 + `docs/governance/2026-05-17-wave0-signoff-ledger.md` §28 H1 行；写明松绑理由块；0 业务代码。
- **顺位 9 C8**：ChartContainerView 桥接实现 + production handler 集成测试落地 → **H1 真正闭环**；严格按 RFC 决议；撞 ≥3 轮 codex 立即 escalate（per `feedback_big_pr_codex_noncovergence`）。

### 3.2 E5 / E6 / P2 大模块拆子 anchor

**Why**：三模块各自全量实现预计 >500 行 prod（含 tests），违反 `feedback_planner_packaging_bias`「≤3 子项 / ≤500 行」硬规则 + 大 PR codex 易陷长轮次 needs-attention（per C7 十五轮 / B4 十轮教训）。

- **E5 → E5a + E5b**：E5a = init + 运行时状态（tick/position/cashBalance/drawdown/markers/drawings/panels/tradeOperations）+ accessors（currentTotalCapital/holdingCost/returnRate/maxDrawdown/buyEnabled/sellEnabled）；E5b = 交易动作（buy/sell → Result）+ 模式切换（switchPeriodCombo/activateDrawingTool/deleteDrawing）+ onSceneActivated 场景生命周期中继。**拆点理由**：状态/读取面与变更/副作用面分离，E5b 依赖 E5a 已建状态。
- **E6 → E6a + E6b**：E6a = 4 个构造 engine 的方法（startNewNormalSession/resumePending/review/replay）+ DI init；E6b = 持久化生命周期（saveProgress/finalize/endSession）。**拆点理由**：构造面（读 + 装配 engine）与回写面（写 record/pending + 清理）分离。
- **P2 → P2a + P2b**：P2a = 4 内部端口默认实现（ZipIntegrityVerifying/ZipExtracting/TrainingSetDataVerifying/DownloadAcceptanceCleaning，均叶子可独立测）；P2b = runner orchestration（run/runBatch/retryPendingConfirmations，接线 4 端口 + 7 步 journal 状态机）。**拆点理由**：叶子端口先 ship + 测过，runner 才接线（沿用 Wave 1 1b/1c"先 ship 再编排"序列教训）。

**P4 暂不预拆**：~300-500 行边界，plan 阶段实测若超 500 再拆（record+pending / settings+journal）。outline 不预设。

### 3.3 Wave 2 收尾：沿用轻量收尾，不打 freeze tag（预声明）

**决策（user 2026-06-02 选轻量）**：Wave 2 是按已冻 spec 实现「集成层」（spec 契约仅 H1 措辞 RFC，已逐 PR review），**无 spec 契约首冻语义**——沿用 Wave 1 收尾模式（per `project_wave1_completion_2026_06_01`）：结尾走轻量 completion doc（anchor 清单 + residual 终态回填）+ **不打 `wave2-frozen` tag / 不建 signoff ledger / 不改 README freeze 章节**。

**说明**：此为 outline 预声明方向；Wave 2 末再正式确认。若届时需要正式冻结基线（如 Wave 3 启动前），可后补 tag。

---

## 四、Residual 处理映射

| Residual | 来源 | 处理方式 | 顺位 |
|---|---|---|---|
| H1 production handler 集成测试 | Wave 0 §15.4 ledger / `project_pr50_pr7b3_merged` | 顺位 1 RFC 松绑措辞 + 顺位 9 C8 集成测试落地真正闭环 | 1 + 9 |
| C3-C6 渲染 residual（交 C8 Wave 2 的渲染收口项） | `project_pr66/67/68/69_merged` | 折入顺位 9 C8 集成 PR 评估（buildRenderState 计算 volumeRange/macdRange 用 `NonDegenerateRange.make`；C8 plan 阶段逐项核对各 C3-C6 deferred 项是否在 C8 scope） | 9 |
| C8 性能（buildRenderState <4ms / 120Hz） | spec Phase 1 §10 + modules §C8 | 顺位 9 C8 acceptance 项（plan 阶段定验证方式；Instruments 或等价） | 9 |
| C2/C7 运行时 gate（CADisplayLink 运行时验证 / 双识别器运行时） | `project_pr60/61_merged` (B?-R) | C8/U2 集成时运行时验证窗口；plan 阶段核对 | 9 + 11 |
| W1-R1 docker image digest pin | `project_wave1_completion_2026_06_01` | **不在 Wave 2 scope**：归 NAS 部署 PR | — |
| W1-R2 3-5 样本训练组数据 | 同上（H7） | **不在 Wave 2 scope**：需 NAS 真实数据源 | — |
| B4-R1/R4/R5/R6（清理职责3 / 部署编排 / advisory lock conn-scoped / near-term retry） | `project_pr76_b4_scheduler_merged` | **不在 Wave 2 scope**：归后续部署 / 可靠性加固 PR | — |

**Wave 2 净 residual 责任**：H1（顺位 1+9 闭环）+ C3-C6 渲染收口 + C8 性能（均归顺位 9 评估）；后端 / 部署 / NAS 类 residual 明确**不在 Wave 2 scope**。

---

## 五、每锚 plan 流程统一约束

每个 Wave 2 anchor PR 走以下流程（沿用 Wave 1，per `docs/governance/wave1-plan-template.md`）：

1. **Task 0 §15.3 评审策略前置**（codex attest 通道 / opus xhigh fallback 触发条件）
2. **brainstorming**（superpowers:brainstorming）：scope / 路线 / 关键风险点
3. **grep-first 验证文档归属**（per `feedback_brainstorming_grep_first`）
4. **writing-plans**（superpowers:writing-plans）+ codex plan-stage adversarial review（4-5 轮内收敛；`codex-attest.sh --scope working-tree --focus <plan>`）
5. **subagent-driven-development** 实施 + verification-before-completion + requesting-code-review
6. **codex branch-diff adversarial review**（`--scope branch-diff`；4-5 轮内收敛；超 5 轮 escalate user 走 attestation residual + admin merge 路径，**不绕过 required checks**）
7. **non-coder acceptance checklist**（中文，action / expected / pass-fail；禁忌词见 `.claude/workflow-rules.json`）
8. **memory 落地**：merge 后写 `project_pr<N>_<anchor>_merged.md` + 更新 `MEMORY.md` index

**iOS PR Catalyst CI 强制**：顺位 2-12 均触 `Mac Catalyst build-for-testing on macos-15` required check（Wave 1 1a/1c 已建 always-trigger workflow + required gate）；本地 swift test 绿不等于 CI 绿（per `feedback_swift_local_toolchain_blindspot`）。

---

## 六、不在 Wave 2 顺位的工作

- **Wave 3 范围**：Phase 2.5 水平线 MVP / Phase 3 完整流程（normal/review/replay 端到端）/ Phase 5 磨光。
- **部署 / NAS 类**：W1-R1（image digest pin）、W1-R2（样本数据生产）、B4 部署编排 residual —— 归独立 NAS 部署 / 数据生产任务。

---

## 七、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-02 | v1 (draft) | 起草；12 anchor 单线（H1 RFC + P4 + E5a/E5b + E6a/E6b + P2a/P2b + C8 + U1/U2/U4）；user 2026-06-02 确认全部按推荐（option a RFC / 按需拆 / 轻量收尾） |
