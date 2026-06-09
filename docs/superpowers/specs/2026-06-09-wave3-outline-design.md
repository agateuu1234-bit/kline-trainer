# Wave 3 outline（v1）—— 端到端可上架 wave 单线顺位

**前置**：Wave 2 全 11 anchor 已 merged（PR #78-#91；轻量收尾 PR #91 `8ab0a52` merged 2026-06-09，**未打 freeze tag**，见 `docs/governance/2026-06-09-wave2-completion.md`）。本 outline 规划 Wave 3「端到端可上架」阶段的执行顺位。

**目的**：列出 Wave 3 全部 anchor PR 的顺序 + 范围概要 + 依赖 + residual 折入策略，作为后续每锚 `superpowers:brainstorming` + `writing-plans` 的输入索引。本文件**仅**是顺位 + Phase + residual 映射 outline；每个顺位 PR 的实施细节（手势状态机 / 测试矩阵 / tier 公式 / 错误处理策略 / acceptance 详情）由该顺位 plan-stage 文档承担 + 自有 codex review 闭环。

**outline 抽象层级纪律（沿用 Wave 1 v18 strip + Wave 2 教训）**：本 outline **不内联** 具体 API 签名、测试 case 矩阵、手势阈值常量、调色板 RGBA 值、DDL/schema。Wave 1 outline v1-v17 因在表内联实施细节触发 branch-diff codex 18 轮"挖边界"无止境模式；v18 strip 至 outline 应有抽象层级才收敛。本文件遵守同一纪律——所有约束表达为**契约归属**而非代码。

---

## 〇、Wave 3 真实起点核实（baseline reconciliation）

**关键校正（沿用 Wave 2 §〇 grep-first 教训）**：`kline_trainer_plan_v1.5.md` §Phase 3（L1204-1214）列的 9 项页面/逻辑/持久化，**大部分已在 Wave 0-2 落地**——不可据 plan 字面把 Phase 3 当作「从零实现」。本 outline 以下表为权威（基于 `git log origin/main` + 实际代码文件核实，2026-06-09）：

| plan §Phase 3 项 | 实际状态 | 证据 / 归属 |
|---|---|---|
| TrainingFlowController + Normal/Review/Replay | **已完成** | E4 PR #63（Wave 1）+ E5/E6 Wave 2 |
| GRDB 模型 + 训练记录/交易/绘线 CRUD | **已完成** | P3/P4 Wave 0（PR #41/#42/#43） |
| 训练进度保存/恢复（pending_training） | **已完成** | E6b PR #86（Wave 2） |
| 离线缓存下载（验收状态机 + LRU） | **已完成** | P2 PR #82（Wave 2） |
| HomeView / TrainingView / SettingsPanel 壳 | **已完成** | U1/U2/U4 Wave 2（#89/#88/#85） |
| 历史复盘（Review）/ 再来一次（Replay）逻辑 | **已完成** | E4 + E6 Wave 1/2 |
| 生产组合根 + 路由 + 启动恢复 | **已完成** | 顺位 11 PR #90（Wave 2） |

**结论**：Wave 3 真实工作面 = **Wave 2 收尾 doc §六汇总的 DEFERRED residual + 尚未实现的交互/磨光功能**，即把 app 从「壳已接好、能路由」推到「端到端真能玩、可上架」。**不重做** 已完成的逻辑/持久化/view 壳。具体未做项见 §四 residual 映射。

**未冻结说明**：Wave 2 未打 freeze tag（`project_wave2_completion` §五）。E5/E6/SettlementView 等 Wave 2 模块**未冻结**，Wave 3 可按需扩展（手动强平方法 / tier accessor / replay 结算窗），但扩展边界须先经顺位 1 RFC 钉死契约（见 §三.1）。

---

## 一、排序策略

- **单线 anchor**：沿用 Wave 0 v6 / Wave 1 v20 / Wave 2 v7 单线模式（用户 2026-06-09 确认全包、单线、前置 RFC）。
- **每 PR ≤3 子项 / ≤500 行 prod**（per memory `feedback_planner_packaging_bias`）。某锚 plan 阶段实测 >500 行按需拆子 anchor。
- **codex 4-5 轮内收敛**（per `feedback_codex_plan_budget_overshoot`；超 5 轮 escalate user，per `feedback_big_pr_codex_noncovergence`）。
- **scope shrink before split**：先 grep 验证文档归属（per `feedback_brainstorming_grep_first`）；同模块 brainstorming abort ≥2 次 = 换 anchor 或开独立 spec 升级窗口（per `feedback_module_level_abort_signal`）。
- **依赖拓扑驱动顺位**：治理 RFC（1）先行钉死契约 → 手势打磨（2-4，依赖 C5/C6/C7/C8 已落）→ 交易补全（5-7，依赖 RFC + 扩 E5/E6）→ 磨光（8-11）→ 收尾（12）。
- **契约前置**：所有 spec gap（tier 公式 / 结束总资金显示语义 / 夜间调色板 / E5·E6 扩展边界 / replay 结算契约）集中顺位 1 RFC 钉死，实施锚不得现编未治理公共面（沿用 Wave 2 顺位 1 + E2 RFC 先例）。

---

## 二、顺位总览（12 anchor）

| 顺位 | Anchor | 组 | 范围估算 | 依赖（仅列上游 Wave 3） | 关键 residual 折入 |
|---|---|---|---|---|---|
| 1 | **spec-gap 治理 RFC**（tier 公式 + 结束总资金显示语义 + 夜间调色板 + E5/E6 扩展边界 + replay 结算契约 公式化钉死 + grep gate） | A 治理 | 仅 spec/governance 文档；0 业务代码 | — | U2-R3 / E6b-R1 / PR11-R2 契约定义（见 §三.1） |
| 2 | **Pinch 缩放**（C8a 去硬编码 `visibleCount=80`/`candleWidthRatio=0.7` + 两指 pinch 手势与 C7 仲裁器集成〔pinch vs 两指周期切换的仲裁归 plan〕 + clamp 边界 + 缩放后视口还原） | B 手势 | ~250-350 行 | — | C8a 视口硬编码 |
| 3 | **水平线绘线 MVP**（Phase 2.5：drawing 模式 pan 截获 → `DrawingAnchor{period,candleIndex,price}` → commit → 跨缩放/平移还原） | B 手势 | ~250-350 行 | 2（跨缩放还原验收需缩放在场） | U2-R2（仅水平线；6 种完整工具属 Phase 4，排除） |
| 4 | **十字光标吸附 + HUD**（snap 到最近蜡烛 + 价格/时间 label 显示） | B 手势 | ~200-300 行 | — | Phase 2.5 收口 |
| 5 | **E5/E6 交易扩展**（手动强平方法 + tier 公式 accessor，严格按顺位 1 RFC） | C 交易 | ~250-350 行 | 1 RFC | U2-R1 / U2-R3（逻辑面） |
| 6 | **U2 交易 UI 接线**（手动强平按钮 + 顶栏「仓位 X/5」+ 结束总资金显示语义，按 RFC） | C 交易 | ~250-350 行 SwiftUI | 5 + 1 RFC | U2-R1 / U2-R3（UI 面）/ E6b-R1 |
| 7 | **Replay 结算窗**（replay 结束触发忠实结算窗，按 RFC 契约；触碰 E5/E6/SettlementView 扩展边界） | C 交易 | ~250-350 行 | 5 + 6 + 1 RFC | PR11-R2 |
| 8 | **夜间模式**（白天/夜间/跟随系统 + 暗色调色板，按 RFC + F2 ThemeController 基础设施） | D 磨光 | ~250-350 行 | 1 RFC | Phase 5 显示模式 |
| 9 | **边界 + 统一错误处理**（训练组损坏/下载中断/磁盘满 + 网络 Toast/解析失败提示/SQLite 损坏自动清理重下 + cache touch-on-use 运维） | D 磨光 | ~300-450 行 | 各模块 | Phase 5 边界 / E6a-R3 |
| 10 | **边缘 bounce 动画**（DecelerationAnimator 扩展：到边界回弹） | D 磨光 | ~200-300 行 | — | Phase 5 |
| 11 | **app target CI 守护 + 性能评审**（CI 构建 app target〔trust-boundary workflow〕+ Instruments 性能 pass；Bitmap Cache 仅当实测单帧 >4ms 才引入；含 user 运行时回填判据） | D 磨光 + infra | CI workflow + 条件性 Bitmap Cache | 全渲染在场 | PR11-R3 / C8 性能 / C2·C7 运行时回填 |
| 12 | **Wave 3 收尾**（completion doc + residual 终态回填 + **freeze tag 决策此处定**：产品完成 wave 是否打 `wave3-frozen` ceremony vs 轻量收尾） | E 收尾 | doc-only（freeze 走则 + tag ceremony） | 全部 | — |

**Phase 划分**：
- A 治理前置（1：spec-gap RFC，先钉死全部契约）
- B 图表手势/交互打磨（2-4：Pinch 缩放 / 水平线绘线 MVP / 十字光标 HUD）
- C 交易功能补全（5-7：E5·E6 扩展 / U2 交易 UI / Replay 结算窗）
- D 磨光（8-11：夜间模式 / 边界+错误 / 边缘 bounce / CI 守护+性能）
- E 收尾（12：completion doc + freeze tag 决策）

**依赖满足校验**（每锚上游均在更早顺位 merged 或 Wave 0/1/2 已完成）：1 RFC(无依赖) → 2 Pinch(C7/C8 Wave 2 已落) → 3 绘线(需 2；C6 Wave 1 已落) → 4 十字光标(C5 Wave 1 已落) → 5 E5/E6 扩展(需 1) → 6 U2 交易 UI(需 5+1) → 7 Replay 结算(需 5+6+1) → 8 夜间(需 1；F2 Wave 0 已落) → 9 边界(各模块已落) → 10 bounce(C2 Wave 1 已落) → 11 CI+性能(全渲染已在场) → 12 收尾(需全部)。无逆向依赖。

---

## 三、关键决策

### 3.1 顺位 1：spec-gap 治理 RFC（前置钉死全部未定契约）

**决策（user 2026-06-09 选「前置一个治理 RFC 锁住」）**：顺位 1 开**纯文档 governance PR**（沿用 Wave 2 顺位 1 + E2 RFC `project_pr64_e2rfc_merged` 先例），把 Wave 3 全部 spec gap 一次性公式化钉死，再进入实施锚。理由：实施锚不会被 codex 拿未定 spec 字面无限挑战（per `feedback_codex_distributed_reliability_drilldown` 同类无止境下钻风险）。

**顺位 1 RFC 须钉死的契约（每项给出权威定义 + 设计理由块）**：
1. **tier 公式（仓位档位 X/5）**：U2-R3「顶栏仓位 X/5」所需的档位计算公式。Wave 2 明确「tier 公式未定，拒臆造」——RFC 须定义档位语义（基于持仓比例 / 资金比例 / 固定 5 档边界？由 plan v1.5 仓位选择 HUD 语义反推）+ 显示规则（空仓 = 0/5？）。
2. **结束总资金 vs 当前总资金 显示语义（E6b-R1）**：plan v1.5 显示语义 dispute。RFC 须定义结算窗与顶栏分别显示 `total_capital`（结束总资金）还是 `currentCapital`（含浮盈当前总资金）+ 各自适用场景（结算 vs 训练中）。
3. **夜间调色板（Phase 5 显示模式）**：F2 ThemeController + 13 默认色 + RGBA 层基础设施已在（Wave 0 PR #39）。RFC 须定义 暗色色板取值来源 + 「跟随系统」语义（监听 `colorScheme`）+ 切换持久化（settings 表 `display_mode` key）。
4. **E5/E6 扩展边界**：Wave 2 未冻结但扩展须治理。RFC 须钉死 (a) 手动强平方法的契约（U2-R1：调用时机 / 与自动局终强平的关系 / 不变量）；(b) tier accessor 暴露面。
5. **Replay 结算契约（PR11-R2）**：replay 结束触发结算窗的契约——「忠实结算需触碰冻结 E5/E6/SettlementView」。RFC 须定义 replay 模式结束时 settlement 数据来源 + 复用原局 FeeSnapshot 的语义。
6. **grep gate**（acceptance 项）：RFC merge 后断言全仓无「tier 公式未定 / 拒臆造」「显示语义 dispute」等未决措辞残留（除本 outline §三 + RFC 自身引用 / changelog）。
- 0 业务代码改动（仅 spec/governance 文档）。顺位 5/6/7/8 据此契约实施，不自行定义公共面。

**撞 ≥3 轮 codex 立即 escalate**（per `feedback_big_pr_codex_noncovergence`）；RFC 类设计文档若 codex 反复就同一 spec 论点复述 ≥3 次 = permanent-bias，走 attestation residual + admin merge（per `feedback_codex_round6_self_contradiction`）。

### 3.2 anchor 拆分 / 排除项理由

- **手势三锚（2/3/4）拆点**：Pinch 缩放（视口几何变换）、水平线绘线（drawing 输入状态机 + 坐标存储）、十字光标 HUD（只读叠加层）三者职责正交，各自独立可测；绘线（3）依赖缩放（2）仅为「跨缩放还原」验收点，非编译依赖。
- **交易三锚（5/6/7）拆点**：逻辑面（E5/E6 扩展，5）与 UI 面（U2 接线，6）分离（沿用 Wave 2 U2 view / E6 逻辑拆法）；Replay 结算窗（7）依赖前两者 + 单独触碰 SettlementView，独立 anchor。
- **磨光四锚（8-11）拆点**：夜间模式（主题切换）、边界+错误处理（跨模块健壮性）、边缘 bounce（动画扩展）、CI 守护+性能（infra）四者无强耦合，按风险/领域分锚。
- **顺位 11 trust-boundary**：app target CI 守护改 `.github/workflows`（trust boundary），强制 codex review（per `.claude/workflow-rules.json`）。Bitmap Cache 为**条件性**引入（仅当 Instruments 实测单帧 >4ms），plan 阶段若实测达标则该子项 no-op，仅交付 CI 守护 + 性能评审 artifact。
- **排除项**（§六明列）：Phase 4 完整 6 种画线工具（射线/趋势线/黄金分割/波浪尺/周期线/时间尺）、NAS 部署/样本数据、iPad 横屏。

### 3.3 Wave 3 收尾：freeze tag 决策延至顺位 12

**预声明（user 2026-06-09 确认延后定）**：Wave 3 是「端到端可上架」产品完成 wave，与 Wave 1/2「实现/集成」性质不同——可能需正式冻结点（沿用 Wave 0 freeze ceremony 模式 + tag）。**但此决策延至顺位 12 收尾时正式定**（届时视产品完成度 + 是否需 spec 契约首冻语义判断）。outline 仅占位顺位 12，不预设打/不打 tag。

---

## 四、Residual 处理映射

| Residual | 来源 | 处理方式 | 顺位 |
|---|---|---|---|
| C8a 视口硬编码（visibleCount=80 / candleWidthRatio=0.7） | `project_wave2_completion` §三 | 顺位 2 Pinch 缩放去硬编码 | 2 |
| U2-R2 画线工具面板（DrawingInputController，水平线） | `project_wave2_completion` §三 | 顺位 3 水平线绘线 MVP（Phase 2.5）；6 种完整工具排除 | 3 |
| U2-R1 手动「结束本局」按钮（强平） | `project_wave2_completion` §三 | 顺位 1 RFC 定契约 + 顺位 5 E5/E6 扩展 + 顺位 6 U2 按钮 | 1 + 5 + 6 |
| U2-R3 顶栏「仓位 X/5」（tier 公式未定） | `project_wave2_completion` §三 | 顺位 1 RFC 定 tier 公式 + 顺位 5 accessor + 顺位 6 显示 | 1 + 5 + 6 |
| E6b-R1 结束总资金 vs 当前总资金 显示语义 | `project_wave2_completion` §三 | 顺位 1 RFC 定显示语义 + 顺位 6 实施 | 1 + 6 |
| PR11-R2 replay 结束结算窗（U2-R4 retreat） | `project_wave2_completion` §三 | 顺位 1 RFC 定契约 + 顺位 7 实施 | 1 + 7 |
| 夜间模式（白天/夜间/跟随系统） | plan v1.5 §Phase 5 | 顺位 1 RFC 定调色板 + 顺位 8 实施 | 1 + 8 |
| 边界处理（训练组损坏/下载中断/磁盘满）+ 统一错误处理 | plan v1.5 §Phase 5 | 顺位 9 | 9 |
| E6a-R3 cache touch-on-use（DAO 运维优化） | `project_wave2_completion` §三 | 折入顺位 9 运维健壮性 | 9 |
| 边缘 bounce 动画 | plan v1.5 §Phase 5 | 顺位 10 DecelerationAnimator 扩展 | 10 |
| PR11-R3 app target 无 CI 构建守护 | `project_wave2_completion` §三 | 顺位 11（trust-boundary CI workflow） | 11 |
| C8 性能（buildRenderState/draw < 4ms @ 120Hz） | Wave 2 §二 runbook #3（实测 pending） | 顺位 11 性能评审 + Bitmap Cache 按需 | 11 |
| C2/C7 运行时实测（减速/手势帧预算） | Wave 2 §二 runbook（user 手动 pending） | 顺位 11 回填判据 + user device/simulator 执行 | 11 + user |

---

## 五、CI / 评审通道说明

- **iOS PR Catalyst CI 强制**：顺位 2-11 均触 `Mac Catalyst build-for-testing on macos-15` required check（Wave 1 1a/1c 已建 always-trigger workflow + required gate）。本地 swift test 绿不等于 CI 绿（per `feedback_swift_local_toolchain_blindspot`）。Catalyst required check 仅验证 build-for-testing（编译 + 链接），**不执行运行时**——顺位 2/4/10 的手势/动画运行时行为须另行 runbook 验收（沿用 Wave 2 §二模式）。
- **顺位 11 新增 app target CI 守护**：现有 Catalyst job 构建 SwiftPM 包；顺位 11 补 app target（`KlineTrainer.xcodeproj`）的 CI 构建守护（PR11-R3），消除「app target 无 CI 构建守护」residual。
- **评审通道**：spec/RFC + 实施锚走 codex 对抗性 review（`codex:adversarial-review`，唯一通道）；codex 周配额耗尽时 fallback opus 4.8 xhigh（per Wave 2 各 anchor memory）。本 outline 自身（顺位 0 文档）走 codex 对抗性 review 到收敛（user 2026-06-09 明确要求）。

---

## 六、不在 Wave 3 顺位的工作

- **Phase 4 完整画线工具**：6 种剩余工具（射线 / 趋势线 / 黄金分割 / 波浪尺 / 周期线 / 时间尺）+ DrawingToolManager 完整工具选择/互斥/快捷按钮。Wave 3 仅 Phase 2.5 水平线 MVP（单锚点）。归独立后续 track。
- **部署 / NAS 类**：W1-R1（image digest pin）、W1-R2（3-5 样本训练组数据生产，H7）、PR11-R1（生产 backendBaseURL placeholder）—— 归独立 NAS 部署 / 数据生产任务。**注**：W1-R2 样本数据未生成前，端到端流程只能用 fixture 验证，真实数据跑通依赖 NAS track。
- **iPad 横屏**：plan v1.5 §Phase 5「v1 锁定竖屏，上架前评估横屏需求」——v1 保持锁竖屏，横屏属上架后评估。
- **已完成（不重做）**：plan §Phase 3 的逻辑/持久化/view 壳（§〇 表）均 Wave 0-2 已落。

---

## 七、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-09 | v1 (draft) | 起草；12 anchor 单线（A 治理 RFC → B 手势 3 → C 交易 3 → D 磨光 4 → E 收尾）；user 2026-06-09 确认全包可上架端到端 / 前置治理 RFC 锁契约 / Phase 4 完整画线 + NAS + iPad 横屏排除；freeze tag 决策延至顺位 12 |
