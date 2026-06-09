# Wave 3 outline（v3）—— 客户端端到端功能完成 wave 单线顺位

**前置**：Wave 2 全 11 anchor 已 merged（PR #78-#91；轻量收尾 PR #91 `8ab0a52` merged 2026-06-09，**未打 freeze tag**，见 `docs/governance/2026-06-09-wave2-completion.md`）。本 outline 规划 Wave 3「客户端端到端功能完成」阶段的执行顺位。

**目的**：列出 Wave 3 全部 anchor PR 的顺序 + 范围概要 + 依赖 + residual 折入策略，作为后续每锚 `superpowers:brainstorming` + `writing-plans` 的输入索引。本文件**仅**是顺位 + Phase + residual 映射 outline；每个顺位 PR 的实施细节（手势状态机 / 测试矩阵 / tier 公式 / 错误处理策略 / acceptance 详情）由该顺位 plan-stage 文档承担 + 自有 codex review 闭环。

**outline 抽象层级纪律（沿用 Wave 1 v18 strip + Wave 2 教训）**：本 outline **不内联** 具体 API 签名、测试 case 矩阵、手势阈值常量、调色板 RGBA 值、DDL/schema。Wave 1 outline v1-v17 因在表内联实施细节触发 branch-diff codex 18 轮"挖边界"无止境模式；v18 strip 至 outline 应有抽象层级才收敛。本文件遵守同一纪律——所有约束表达为**契约归属**而非代码。

**完成 claim 边界（codex R1-F1 校正）**：Wave 3 目标是**客户端 feature 完整 + 端到端 fixture 验证可玩**，**不**等于「可上架商店」。真实上架还需 NAS track 的 (a) 生产 backendBaseURL 配置（PR11-R1）+ (b) 真实样本训练组数据（W1-R2，H7）——二者 §六明列为 Wave 3 下游显式 ship 门，**Wave 3 不 claim 已具备**。详见 §三.3 + §六。

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

**结论**：Wave 3 真实工作面 = **Wave 2 收尾 doc §六汇总的 DEFERRED residual + 尚未实现的交互/磨光功能**，即把 app 从「壳已接好、能路由」推到「端到端真能玩」。**不重做** 已完成的逻辑/持久化/view 壳。具体未做项见 §四 residual 映射。

**画线 source-of-truth 现状（codex R2-F2，核实 2026-06-09）**：`DrawingToolManager.completedDrawings`（commit 落点，`Drawing/DrawingToolManager.swift:21/70`）与 `TrainingEngine.drawings`（`TrainingEngine.swift:25`，被 `RenderStateBuilder.swift:42` 渲染 + `TrainingSessionCoordinator.swift:191/230` 持久化消费）之间**当前无投影路径**。C6 设计（`docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md` L35/36/41/42）**显式 defer 到 Wave 3**：DrawingInputController 实现、`completedDrawings→renderState.drawings` 投影、ChartReducer `.drawingCommitted/.drawingCancelled/.setDrawingSnapshot` 流转、drawings 持久化。故顺位 4 必须 own 这条全链路（见 §三.2）。

**CI baseline（codex R1-F2 校正）**：现有 `.github/workflows/catalyst-build.yml` 仅构建 `ios/Contracts` SwiftPM scheme（business/UI 逻辑包）。**`KlineTrainer.xcodeproj`（app target 外壳：`KlineTrainerApp`/`AppRootView`/`AppContainer`）当前无 CI 编译守护**（PR11-R3 residual）。Wave 3 顺位 2 即补此守护并前置（见 §三.2）。

**Orientation 现状（codex R2-F3，核实 2026-06-09）**：app target pbxproj（Debug `:278-279` + Release `:311-312`，iPad + iPhone）**当前启用 Landscape**——**非**已锁竖屏。plan v1.5 L1232「v1 锁定竖屏」要求竖屏，故顺位 2 须 own 锁竖屏改动（见 §三.2 + §六）。

**未冻结说明**：Wave 2 未打 freeze tag（`project_wave2_completion` §五）。E5/E6/SettlementView 等 Wave 2 模块**未冻结**，Wave 3 可按需扩展（手动强平方法 / tier accessor / 画线 engine mutation / replay 结算窗），但扩展边界须先经顺位 1 RFC 钉死契约（见 §三.1）。

---

## 一、排序策略

- **单线 anchor**：沿用 Wave 0 v6 / Wave 1 v20 / Wave 2 v7 单线模式（用户 2026-06-09 确认全包、单线、前置 RFC）。
- **每 PR ≤3 子项 / ≤500 行 prod**（per memory `feedback_planner_packaging_bias`）。某锚 plan 阶段实测 >500 行按需拆子 anchor。
- **codex 4-5 轮内收敛**（per `feedback_codex_plan_budget_overshoot`；超 5 轮 escalate user，per `feedback_big_pr_codex_noncovergence`）。
- **scope shrink before split**：先 grep 验证文档归属（per `feedback_brainstorming_grep_first`）；同模块 brainstorming abort ≥2 次 = 换 anchor 或开独立 spec 升级窗口（per `feedback_module_level_abort_signal`）。
- **依赖拓扑驱动顺位**：治理前置（1 RFC 钉死契约 + 2 app-target CI 守护/锁竖屏早置）→ 手势打磨（3-5，依赖 C5/C6/C7/C8 已落）→ 交易补全（6-8，依赖 RFC + 扩 E5/E6）→ 磨光（9-12）→ 收尾（13）。
- **契约前置**：所有 spec gap（tier 公式 / 结束总资金显示语义 / 夜间调色板 / E5·E6 扩展边界〔含手动强平 + tier accessor + **画线 engine mutation API**〕/ replay 结算契约）集中顺位 1 RFC 钉死，实施锚不得现编未治理公共面（沿用 Wave 2 顺位 1 + E2 RFC 先例）。
- **CI 守护前置**：app target 编译守护 + 锁竖屏（顺位 2）必须早于任何改 app target 的实施锚，并对顺位 3-12 强制 required check（codex R1-F2 / R2-F3；对齐 Wave 1 1a/1c CI 前置先例）。
- **运行时验收随锚交付**：每个引入新交互/动画的实施锚（3/4/5/7/8/9/11）须在 acceptance 内交付该交互的运行时 runbook 条目；顺位 13 收尾阻塞依赖 = 全 Wave 3 运行时矩阵的 device/sim 实测记录（codex R2-F1，见 §三.3）。

---

## 二、顺位总览（13 anchor）

| 顺位 | Anchor | 组 | 范围估算 | 依赖（仅列上游 Wave 3） | 关键 residual 折入 |
|---|---|---|---|---|---|
| 1 | **spec-gap 治理 RFC**（tier 公式 + 结束总资金显示语义 + 夜间调色板 + E5/E6 扩展边界〔手动强平 + tier accessor + 画线 engine mutation API〕 + replay 结算契约 公式化钉死 + grep gate） | A 治理 | 仅 spec/governance 文档；0 业务代码 | — | U2-R3 / E6b-R1 / PR11-R2 契约定义（见 §三.1） |
| 2 | **app-target CI 守护 + 锁竖屏**（`KlineTrainer.xcodeproj` build-for-testing 加入 CI〔trust-boundary workflow〕+ 设为 required check + 对顺位 3-12 实施 PR 强制 + pbxproj orientation Debug+Release/iPad+iPhone 去 Landscape 仅留 Portrait + 旋转验证） | A 治理 + infra | CI workflow + pbxproj 改动；0 业务代码 | — | PR11-R3 + 锁竖屏（codex R1-F2 / R2-F3） |
| 3 | **Pinch 缩放**（C8a 去硬编码 `visibleCount=80`/`candleWidthRatio=0.7` + 两指 pinch 手势与 C7 仲裁器集成〔pinch vs 两指周期切换的仲裁归 plan〕 + clamp 边界 + 缩放后视口还原 + 运行时 runbook 条目） | B 手势 | ~250-350 行 | 2 | C8a 视口硬编码 |
| 4 | **水平线绘线 MVP + 画线 source-of-truth 全链路**（Phase 2.5：input controller pan 截获→`DrawingAnchor{period,candleIndex,price}` → **`manager.completedDrawings`→`engine.drawings` 单一真相投影** + engine 画线 mutation〔按 RFC〕+ ChartReducer `.drawingCommitted/.drawingCancelled/.setDrawingSnapshot` 流转 + **pending 持久化/resume/review 还原**〔复用已有 `TrainingSessionCoordinator` engine.drawings 路径〕 + 跨缩放/平移还原 + E2E save/resume 测试 + 运行时 runbook 条目） | B 手势 | ~350-500 行（plan 若超 500 拆 4a 输入+投影 / 4b 持久化+还原） | 1 RFC + 2 + 3 | U2-R2 + C6 deferred 投影/持久化/reducer 集成（codex R2-F2；仅水平线，6 种完整工具属 Phase 4 排除） |
| 5 | **十字光标吸附 + HUD**（snap 到最近蜡烛 + 价格/时间 label 显示 + 运行时 runbook 条目） | B 手势 | ~200-300 行 | 2 | Phase 2.5 收口 |
| 6 | **E5/E6 交易扩展**（手动强平方法 + tier 公式 accessor，严格按顺位 1 RFC） | C 交易 | ~250-350 行 | 1 RFC + 2 | U2-R1 / U2-R3（逻辑面） |
| 7 | **U2 交易 UI 接线**（手动强平按钮 + 顶栏「仓位 X/5」+ 结束总资金显示语义，按 RFC + 运行时 runbook 条目） | C 交易 | ~250-350 行 SwiftUI | 6 + 1 RFC | U2-R1 / U2-R3（UI 面）/ E6b-R1 |
| 8 | **Replay 结算窗**（replay 结束触发忠实结算窗，按 RFC 契约；触碰 E5/E6/SettlementView 扩展边界 + 运行时 runbook 条目） | C 交易 | ~250-350 行 | 6 + 7 + 1 RFC | PR11-R2 |
| 9 | **夜间模式**（白天/夜间/跟随系统 + 暗色调色板，按 RFC + F2 ThemeController 基础设施 + 运行时 runbook 条目） | D 磨光 | ~250-350 行 | 1 RFC | Phase 5 显示模式 |
| 10 | **边界 + 统一错误处理 + 生产路径 fixture E2E smoke**（训练组损坏/下载中断/磁盘满 + 网络 Toast/解析失败/SQLite 损坏自动清理重下 + cache touch-on-use + **走真实 DownloadAcceptanceRunner 代码路径的 fixture 下载→确认→训练组可用 E2E smoke**） | D 磨光 | ~300-450 行 | 各模块 | Phase 5 边界 / E6a-R3 / 生产路径 smoke（codex R1-F1） |
| 11 | **边缘 bounce 动画**（DecelerationAnimator 扩展：到边界回弹 + 运行时 runbook 条目） | D 磨光 | ~200-300 行 | 2 | Phase 5 |
| 12 | **性能评审 + Bitmap Cache 按需**（Instruments 性能 pass；Bitmap Cache 仅当实测单帧 >4ms 才引入；交付帧预算验收判据） | D 磨光 | 条件性 Bitmap Cache | 全渲染在场 | C8 性能 / C2·C7 运行时回填判据 |
| 13 | **Wave 3 收尾**（completion doc + residual 终态回填 + **Wave 3 全交互运行时矩阵验收完成作阻塞依赖** + **freeze tag 决策**） | E 收尾 | doc-only（freeze 走则 + tag ceremony） | 全部 + **Wave 3 运行时矩阵记录**（见 §三.3） | C2/C7/C8 + 新交互运行时实测回填（codex R1-F3 / R2-F1） |

**Phase 划分**：
- A 治理前置（1：spec-gap RFC；2：app-target CI 守护 + 锁竖屏早置）
- B 图表手势/交互打磨（3-5：Pinch 缩放 / 水平线绘线 MVP+source-of-truth / 十字光标 HUD）
- C 交易功能补全（6-8：E5·E6 扩展 / U2 交易 UI / Replay 结算窗）
- D 磨光（9-12：夜间模式 / 边界+错误+生产路径 smoke / 边缘 bounce / 性能）
- E 收尾（13：completion doc + 运行时矩阵阻塞 + freeze tag 决策）

**依赖满足校验**（每锚上游均在更早顺位 merged 或 Wave 0/1/2 已完成）：1 RFC(无依赖) → 2 CI 守护+锁竖屏(无依赖；早于所有 app-target 改动) → 3 Pinch(需 2；C7/C8 Wave 2 已落) → 4 绘线全链路(需 1+2+3；C6 Wave 1 infra 已落) → 5 十字光标(需 2；C5 Wave 1 已落) → 6 E5/E6 扩展(需 1+2) → 7 U2 交易 UI(需 6+1) → 8 Replay 结算(需 6+7+1) → 9 夜间(需 1；F2 Wave 0 已落) → 10 边界+smoke(各模块已落) → 11 bounce(需 2；C2 Wave 1 已落) → 12 性能(全渲染已在场) → 13 收尾(需全部 + Wave 3 运行时矩阵记录)。无逆向依赖。

---

## 三、关键决策

### 3.1 顺位 1：spec-gap 治理 RFC（前置钉死全部未定契约）

**决策（user 2026-06-09 选「前置一个治理 RFC 锁住」）**：顺位 1 开**纯文档 governance PR**（沿用 Wave 2 顺位 1 + E2 RFC `project_pr64_e2rfc_merged` 先例），把 Wave 3 全部 spec gap 一次性公式化钉死，再进入实施锚。理由：实施锚不会被 codex 拿未定 spec 字面无限挑战（per `feedback_codex_distributed_reliability_drilldown` 同类无止境下钻风险）。

**顺位 1 RFC 须钉死的契约（每项给出权威定义 + 设计理由块）**：
1. **tier 公式（仓位档位 X/5）**：U2-R3「顶栏仓位 X/5」所需的档位计算公式。Wave 2 明确「tier 公式未定，拒臆造」——RFC 须定义档位语义（基于持仓比例 / 资金比例 / 固定 5 档边界？由 plan v1.5 仓位选择 HUD 语义反推）+ 显示规则（空仓 = 0/5？）。
2. **结束总资金 vs 当前总资金 显示语义（E6b-R1）**：plan v1.5 显示语义 dispute。RFC 须定义结算窗与顶栏分别显示 `total_capital`（结束总资金）还是 `currentCapital`（含浮盈当前总资金）+ 各自适用场景（结算 vs 训练中）。
3. **夜间调色板（Phase 5 显示模式）**：F2 ThemeController + 13 默认色 + RGBA 层基础设施已在（Wave 0 PR #39）。RFC 须定义 暗色色板取值来源 + 「跟随系统」语义（监听 `colorScheme`）+ 切换持久化（settings 表 `display_mode` key）。
4. **E5/E6 扩展边界**：Wave 2 未冻结但扩展须治理。RFC 须钉死 (a) 手动强平方法的契约（U2-R1：调用时机 / 与自动局终强平的关系 / 不变量）；(b) tier accessor 暴露面；(c) **画线 engine mutation API**（顺位 4 把 `manager.completedDrawings` 投影进 `engine.drawings` 所需的 TrainingEngine 公共 mutation 面——commit/append/同步语义；C6 deferred，须治理后实施）。
5. **Replay 结算契约（PR11-R2）**：replay 结束触发结算窗的契约——「忠实结算需触碰冻结 E5/E6/SettlementView」。RFC 须定义 replay 模式结束时 settlement 数据来源 + 复用原局 FeeSnapshot 的语义。
6. **grep gate**（acceptance 项）：RFC merge 后断言全仓无「tier 公式未定 / 拒臆造」「显示语义 dispute」等未决措辞残留（除本 outline §三 + RFC 自身引用 / changelog）。
- 0 业务代码改动（仅 spec/governance 文档）。顺位 4/6/7/8/9 据此契约实施，不自行定义公共面。

**撞 ≥3 轮 codex 立即 escalate**（per `feedback_big_pr_codex_noncovergence`）；RFC 类设计文档若 codex 反复就同一 spec 论点复述 ≥3 次 = permanent-bias，走 attestation residual + admin merge（per `feedback_codex_round6_self_contradiction`）。

### 3.2 anchor 拆分 / CI+锁竖屏前置 / 画线全链路 / 排除项理由

- **app-target CI 守护 + 锁竖屏前置（顺位 2，codex R1-F2 / R2-F3）**：现有 Catalyst job 仅构建 `ios/Contracts` SwiftPM 包；`KlineTrainer.xcodeproj` app target 无 CI 编译守护（PR11-R3）。若拖到末位，顺位 3-12 任一改 app target 的锚可在 app 编译不过时 merge，集成失败累积到末期才暴露（违 `feedback_swift_local_toolchain_blindspot`「本地绿≠CI绿」）。故前置为顺位 2 并对后续实施锚强制 required check（对齐 Wave 1 1a/1c CI 前置先例）。**同锚 own 锁竖屏**：当前 pbxproj 启用 Landscape（§〇），与 plan「v1 锁定竖屏」冲突 → 顺位 2 改 orientation 为仅 Portrait + 旋转验证。**trust-boundary**：改 `.github/workflows`，强制 codex review（per `.claude/workflow-rules.json`）。
- **画线 source-of-truth 全链路（顺位 4，codex R2-F2）**：C6（PR #69）仅落 manager 基础设施 + 框架，**显式 defer** input controller 实现、`completedDrawings→engine.drawings` 投影、reducer 流转、drawings 持久化到 Wave 3（§〇）。顺位 4 须 own 单一真相全链路（input → 投影 engine.drawings → reducer 流转 → 持久化/resume/review 还原 + E2E test），否则画线 transient、不从 engine 渲染、resume/复盘消失。engine 画线 mutation API 经顺位 1 RFC 治理。plan 阶段若 >500 行拆 4a（输入+投影）/ 4b（持久化+还原）。
- **手势三锚（3/4/5）拆点**：Pinch 缩放（视口几何变换）、水平线绘线全链路（drawing 输入+投影+持久化）、十字光标 HUD（只读叠加层）三者职责正交；绘线（4）依赖缩放（3）为「跨缩放还原」验收点。
- **交易三锚（6/7/8）拆点**：逻辑面（E5/E6 扩展，6）与 UI 面（U2 接线，7）分离（沿用 Wave 2 U2 view / E6 逻辑拆法）；Replay 结算窗（8）依赖前两者 + 单独触碰 SettlementView，独立 anchor。
- **磨光四锚（9-12）拆点**：夜间模式（主题切换）、边界+错误处理+生产路径 smoke（跨模块健壮性）、边缘 bounce（动画扩展）、性能评审（条件性 Bitmap Cache）四者无强耦合。Bitmap Cache 为**条件性**引入（仅当 Instruments 实测单帧 >4ms），plan 阶段若实测达标则该子项 no-op，仅交付性能评审 artifact。
- **排除项**（§六明列）：Phase 4 完整 6 种画线工具、NAS 部署/样本数据/生产 endpoint、iPad 横屏 layout 功能（锁竖屏本身 = 顺位 2 in-scope）。

### 3.3 Wave 3 收尾：运行时矩阵阻塞 + 完成 claim 诚实 + freeze tag 决策

**运行时验收矩阵作收尾阻塞依赖（codex R1-F3 / R2-F1）**：Wave 3 为「端到端可玩」wave，**不得**在新交互运行时无证据时关闭。Wave 2 两份 runbook（减速/帧预算 + 手势）仅覆盖 pan/周期切换/基础十字光标/旧结算，**不覆盖** Wave 3 新交互。故：
- **每个新交互锚交付自己的运行时 runbook 条目**：顺位 3 pinch 聚焦/clamp、4 水平线绘制+跨缩放还原、5 十字光标 snap/HUD、7 手动强平、8 replay 结算窗、9 主题切换视觉、11 边缘 bounce。
- **顺位 13 收尾 + 任何 freeze tag 阻塞依赖** = 上述 Wave 3 运行时矩阵 + Wave 2 两份 runbook 的 **device/simulator 实测结果已记录** + Instruments 帧预算实测数值已回填。运行时验收是 user device 职责，但其**完成**是 Wave 3 关闭的硬前提，非「某天再说」。

**完成 claim 诚实（codex R1-F1）**：Wave 3 收尾 doc **不得** claim「可上架商店」。Wave 3 交付 = 客户端 feature 完整 + 端到端 fixture 验证（含顺位 10 生产路径 fixture E2E smoke）+ 运行时矩阵记录。**真实上架剩余门**（§六）= NAS track 的生产 backendBaseURL（PR11-R1）+ 真实样本数据（W1-R2）——收尾 doc 须显式列此二门为「未完成的 ship 前提」，不计入 Wave 3 完成度。

**freeze tag 决策延至顺位 13**：Wave 3 是客户端功能完成 wave。若届时打 `wave3-frozen` tag，其语义 = **冻结客户端功能完整性**（非 store-ship readiness），且须先满足上述运行时矩阵阻塞 + 诚实 claim。**是否打 tag 延至顺位 13 收尾时正式定**（视产品完成度 + 是否需冻结点判断）。outline 仅占位顺位 13，不预设打/不打 tag。

---

## 四、Residual 处理映射

| Residual | 来源 | 处理方式 | 顺位 |
|---|---|---|---|
| PR11-R3 app target 无 CI 构建守护 | `project_wave2_completion` §三 | 顺位 2 前置 app-target CI 守护（trust-boundary workflow + required check） | 2 |
| 锁竖屏（app target 实际启用 Landscape，与 plan「v1 锁定竖屏」冲突） | codex R2-F3（pbxproj 核实） | 顺位 2 改 orientation → 仅 Portrait + 旋转验证 | 2 |
| C8a 视口硬编码（visibleCount=80 / candleWidthRatio=0.7） | `project_wave2_completion` §三 | 顺位 3 Pinch 缩放去硬编码 | 3 |
| U2-R2 画线工具面板（DrawingInputController，水平线）+ C6 deferred 投影/持久化/reducer 集成 | `project_wave2_completion` §三 + C6 设计 L35/36/41/42 | 顺位 4 水平线 MVP + source-of-truth 全链路（input→投影→reducer→持久化/还原+E2E）；6 种完整工具排除 | 4 |
| U2-R1 手动「结束本局」按钮（强平） | `project_wave2_completion` §三 | 顺位 1 RFC 定契约 + 顺位 6 E5/E6 扩展 + 顺位 7 U2 按钮 | 1 + 6 + 7 |
| U2-R3 顶栏「仓位 X/5」（tier 公式未定） | `project_wave2_completion` §三 | 顺位 1 RFC 定 tier 公式 + 顺位 6 accessor + 顺位 7 显示 | 1 + 6 + 7 |
| E6b-R1 结束总资金 vs 当前总资金 显示语义 | `project_wave2_completion` §三 | 顺位 1 RFC 定显示语义 + 顺位 7 实施 | 1 + 7 |
| PR11-R2 replay 结束结算窗（U2-R4 retreat） | `project_wave2_completion` §三 | 顺位 1 RFC 定契约 + 顺位 8 实施 | 1 + 8 |
| 夜间模式（白天/夜间/跟随系统） | plan v1.5 §Phase 5 | 顺位 1 RFC 定调色板 + 顺位 9 实施 | 1 + 9 |
| 边界处理（训练组损坏/下载中断/磁盘满）+ 统一错误处理 | plan v1.5 §Phase 5 | 顺位 10 | 10 |
| E6a-R3 cache touch-on-use（DAO 运维优化） | `project_wave2_completion` §三 | 折入顺位 10 运维健壮性 | 10 |
| 生产路径 fixture E2E smoke（下载→确认→训练组可用） | codex R1-F1 | 顺位 10 走真实 DownloadAcceptanceRunner 代码路径的 fixture E2E | 10 |
| 边缘 bounce 动画 | plan v1.5 §Phase 5 | 顺位 11 DecelerationAnimator 扩展 | 11 |
| C8 性能（buildRenderState/draw < 4ms @ 120Hz） | Wave 2 §二 runbook #3（实测 pending） | 顺位 12 性能评审 + Bitmap Cache 按需 | 12 |
| Wave 3 新交互运行时矩阵（pinch/绘线/HUD/手动强平/replay结算/主题/bounce） | codex R2-F1 | 各锚交付 runbook 条目 + 顺位 13 收尾**阻塞**依赖（记录的 device/sim 结果） | 3-11 + 13 |
| C2/C7/C8 既有运行时实测（减速/手势/帧预算） | Wave 2 §二 runbook（user 手动 pending） | 顺位 12 回填判据 + 顺位 13 收尾**阻塞**依赖 | 12 + 13 |

---

## 五、CI / 评审通道说明

- **iOS PR Catalyst CI 强制**：顺位 3-12 均触 `Mac Catalyst build-for-testing on macos-15` required check（Wave 1 1a/1c 已建 always-trigger workflow + required gate）。本地 swift test 绿不等于 CI 绿（per `feedback_swift_local_toolchain_blindspot`）。Catalyst required check 仅验证 build-for-testing（编译 + 链接），**不执行运行时**——顺位 3/4/5/7/8/9/11 的手势/动画/视觉运行时行为须各自交付 runbook 条目（§三.3），其完成是顺位 13 阻塞依赖。
- **顺位 2 新增 app target CI 守护 + 锁竖屏**：现有 Catalyst job 构建 SwiftPM 包；顺位 2 补 app target（`KlineTrainer.xcodeproj`）的 CI 构建守护（PR11-R3）+ pbxproj orientation 锁 Portrait（R2-F3），并对顺位 3-12 设为 required check（codex R1-F2）。
- **评审通道**：spec/RFC + 实施锚走 codex 对抗性 review（`codex:adversarial-review`，唯一通道）；codex 周配额耗尽时 fallback opus 4.8 xhigh（per Wave 2 各 anchor memory）。本 outline 自身（顺位 0 文档）走 codex 对抗性 review 到收敛（user 2026-06-09 明确要求）。

---

## 六、不在 Wave 3 顺位的工作

- **Phase 4 完整画线工具**：6 种剩余工具（射线 / 趋势线 / 黄金分割 / 波浪尺 / 周期线 / 时间尺）+ DrawingToolManager 完整工具选择/互斥/快捷按钮。Wave 3 仅 Phase 2.5 水平线 MVP（单锚点）。归独立后续 track。
- **部署 / NAS 类（= 真实上架剩余 ship 门，codex R1-F1）**：W1-R1（image digest pin）、W1-R2（3-5 样本训练组数据生产，H7）、PR11-R1（生产 backendBaseURL placeholder→真实生产 endpoint）—— 归独立 NAS 部署 / 数据生产任务。**这二门（PR11-R1 endpoint + W1-R2 数据）是 Wave 3 之后真实上架商店的显式前提**：未完成前，全新生产安装无法下载训练组，端到端只能 fixture 验证。Wave 3 收尾 doc 须显式列此为「未完成 ship 门」，**不**计入 Wave 3 完成度，**不** claim store-ready。
- **iPad 横屏 layout 功能**：plan v1.5 §Phase 5「v1 锁定竖屏，**上架前**评估横屏需求」。**注（codex R2-F3）**：当前 app target pbxproj（Debug+Release / iPad+iPhone）实际**启用了 Landscape**，非已锁竖屏。**锁竖屏改动本身 = 顺位 2 in-scope**（owns pbxproj orientation→Portrait + 旋转验证）；**横屏 layout 适配功能**（真正支持横屏 UI）排除，属上架前单独评估门。
- **已完成（不重做）**：plan §Phase 3 的逻辑/持久化/view 壳（§〇 表）均 Wave 0-2 已落。

---

## 七、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-09 | v1 (draft) | 起草；12 anchor 单线（A 治理 RFC → B 手势 3 → C 交易 3 → D 磨光 4 → E 收尾）；user 2026-06-09 确认全包可上架端到端 / 前置治理 RFC 锁契约 / Phase 4 完整画线 + NAS + iPad 横屏排除；freeze tag 决策延至收尾 |
| 2026-06-09 | v2 (codex branch-diff R1 修) | **F1**（high）：「可上架」claim 与排除生产路径自相矛盾 → 重述为「客户端端到端功能完成」+ §六明列二门为未完成 ship 门 + 顺位 10 加生产路径 fixture E2E smoke；**F2**（high）：app-target CI 守护从末位提为前置独立顺位 2 + 对顺位 3-12 强制 required check；**F3**（high）：运行时验收设为顺位 13 + freeze 阻塞依赖；anchor 12→13 |
| 2026-06-09 | v3 (codex branch-diff R2 修) | **F1**（high）：收尾仅依赖 Wave 2 两 runbook 不覆盖 Wave 3 新交互 → 每新交互锚（3/4/5/7/8/9/11）交付运行时 runbook 条目 + 顺位 13 阻塞全 Wave 3 运行时矩阵（§三.3）；**F2**（high）：画线 commit→engine.drawings 无投影路径（C6 显式 defer 到 Wave 3）→ 顺位 4 扩为 source-of-truth 全链路（input+投影+reducer+持久化/还原+E2E）+ engine mutation API 纳入顺位 1 RFC + 依赖加 1 + plan 超 500 拆 4a/4b + §〇 现状核实块；**F3**（med）：pbxproj 实际启用 Landscape 与 plan「锁竖屏」冲突 + v2 误写「上架后」→ 顺位 2 owns 锁竖屏（pbxproj→Portrait+旋转验证）+ §六 修「上架前」+ §〇 orientation 现状块；全表/依赖图/residual 同步 |
