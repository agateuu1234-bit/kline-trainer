# Wave 2 完成确认（轻量收尾，doc-only）

**日期**：2026-06-09
**性质**：Wave 2 outline（v7，PR #78）的 11 个 anchor 全部 merged 后的轻量收尾——residual 终态回填 + 完成确认 + 收口一个 doc loose end（C8b plan 还原）。**不打 freeze tag**（见 §五 决策）。0 业务代码 / 0 CI / 0 ruleset 改动。

---

## 一、11 anchor 交付清单（全 merged）

| 顺位 | Anchor | PR | squash SHA |
|---|---|---|---|
| — | Wave 2 outline v7（非 anchor，列为起点） | #78 | `77c79e8` |
| 1 | baseline reconciliation + H1 RFC + P6 两层恢复契约 | #79 | `354218a` |
| 2 | E5a TrainingEngine 核心（替换 Wave 0 壳） | #80 | `f3a5d7a` |
| 3 | E5b TrainingEngine 交易动作（buy/sell/holdOrObserve） | #81 | `ea23fbd` |
| 4 | E6a TrainingSessionCoordinator 会话构造 | #83 | `feb3d3e` |
| 5 | E6b TrainingSessionCoordinator 持久化生命周期 | #86 | `5463c32` |
| 6 | P2 DownloadAcceptanceRunner 编排 + retryPendingConfirmations | #82 | `57fce77` |
| 7a | C8a ChartContainerView 渲染路径 | #84 | `22c88de` |
| 7b | C8b 图表交互路径 + H1 闭环 | #87 | `c0c19e0` |
| 8 | U1 HomeView（view-only shell） | #89 | `af62bea` |
| 9 | U2 TrainingView + E6 生命周期接线 | #88 | `c72f868` |
| 10 | U4 SettingsPanel + SettingsStore loadError 两层恢复 | #85 | `449bb74` |
| 11 | 生产组合根 + 路由接线 + 启动恢复 | #90 | `cf562d2` |

**11 anchor = 顺位 1-11，全部 merged**（顺位 7 拆 C8a #84 + C8b #87 两 PR）。每 anchor 的验收清单见各自 `docs/acceptance/` 文件；每 anchor 的 merge 记录见 memory `project_pr<N>_*_merged`。SHA 已据 `git log origin/main`（2026-06-09）核实。

---

## 二、H1 闭环 + C2/C7/C8 运行时 gate 终态

| 项 | 终态 | 依据 |
|---|---|---|
| **H1 production handler 集成测试** | **CLOSED** ✓ | 顺位 1 RFC (#79) 松绑「同 PR」措辞（集成测试落 C8 集成 anchor，三模块在场时验证）；顺位 7 C8b (#87) 交付 `TrainingEngineDrawingHandlerH1Tests`（host 集成测试），验证 modules §C1b 闸门 #4 F3 Wave 2 要求。Wave 0 §15.4 ledger H1 行可标 close |
| **C2 CADisplayLink 减速运行时** | **runbook 就位 / user 手动验收 pending** | `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md`（5 项：惯性衰减 / 减速中点交易立停 / 帧 < 4ms / 后台前台无跳帧）。device/simulator 手动执行 + 帧预算实测回填属 user 职责 |
| **C7 手势仲裁运行时** | **runbook 就位 / user 手动验收 pending** | `docs/runbooks/2026-06-07-u2-gesture-runtime-acceptance.md`（6 项：单指 pan / 两指周期切换 / 长按十字光标 / 模式交易行为 / 局终自动） |
| **C8 性能（buildRenderState/draw < 4ms @ 120Hz）** | **验收判据就位 / user Instruments 实测回填 pending** | 同 c8b runbook item #3（Instruments Time Profiler / Core Animation 录制单帧 ms） |
| **C3-C6 渲染收口（交 C8 的渲染 residual）** | **CLOSED** ✓ | C8a (#84) `RenderStateBuilder` 折入 + C8b 交互渲染路径 |

**说明（不 overclaim）**：outline §四 L121/§五 L149 要求 C2/C7/C8 运行时 gate 须**具体验收 artifact**（非仅编译）。**artifact（两份 runbook + 验收判据）已交付**；但**运行时本身的 device/simulator 手动执行 + 帧预算实测数值回填仍 pending（user 职责）**。本收尾**不**据此宣告运行时已验证——仅确认 artifact 就位、自动化部分（H1 host 集成测试 + Catalyst build-for-testing）已绿。运行时实测回填后可在各 runbook 内勾选，无需再开 PR。

---

## 三、Wave 2 净 residual 终态

| ID | residual | 终态 | target |
|---|---|---|---|
| H1 集成测试 | production handler 三模块在场验证 | **CLOSED**（#79 RFC + #87 C8b） | — |
| fee-callsite reconcile | 交易流 fail-closed `snapshotFeesIfReady` | **CLOSED**（#79 RFC + #83 E6a 实施 + grep gate `verify-wave2-pr1-rfc.sh` 谓词 b/c） | — |
| baseline reconcile | P4/P2 端口已 Wave 0 落地 stale 列消除 | **CLOSED**（#79 reconcile 全 stale 源 + grep gate c） | — |
| holdOrObserve 第三动作 | 常驻可用推进当前周期 | **CLOSED**（#81 E5b + #88 U2 acceptance 覆盖） | — |
| E6a fail-closed 费用快照 | 构造 NormalFlow 前 snapshotFeesIfReady/守 loadError | **CLOSED**（#83 E6a） | — |
| U2 E6 持久化生命周期 | back/auto-end/settlement/review/replay 5 路径 | **CLOSED**（#88 U2 5 路径矩阵） | — |
| C7 手势 arbiter 生产接线 | attach-once + 路由 callback 进 engine/reducer | **CLOSED**（#87 C8b 接线；运行时证据见 §二 runbook） | — |
| SettingsStore loadError 两层恢复 | retryReload + forceResetAndReload(confirmation:) | **CLOSED**（#79 P6 契约 RFC + #85 U4 实施） | — |
| 生产组合根 + 路由 + 启动恢复 | 替换 app entry + 依赖图 + 路由 + retryPendingConfirmations | **CLOSED**（#90 顺位 11） | — |
| **C8b-R1** | C8b plan doc 未随 #87 提交（ChartContainerView.swift:4 dangling ref） | **CLOSED（本收尾）**：从 pending-artifacts 备份还原 `docs/superpowers/plans/2026-06-07-pr-c8b-chart-interaction-h1.md` | 本 PR |
| C8 性能 / C2/C7 运行时实测 | 帧预算 + 减速/手势运行时 | **DEFERRED（user 手动）**：runbook 就位，待 device/simulator 执行回填 | user 验收 |
| E6b-R1 | 「结束总资金」vs「当前总资金」显示（total_capital vs +profit） | **DEFERRED → Wave 3**：plan v1.5 显示语义 dispute，UI 打磨 | Wave 3 UI |
| E6a-R3 | cache touch-on-use（DAO 运维优化） | **DEFERRED → Wave 3** | Wave 3 |
| C8a 视口硬编码 | visibleCount=80 / candleWidthRatio=0.7（pinch 缩放） | **DEFERRED → Wave 3**：缩放手势属 Wave 3 | Wave 3 gesture |
| U2-R1 | 手动「结束本局」按钮（强平） | **DEFERRED → Wave 3**：E5 无手动强平方法 | Wave 3 trading |
| U2-R2 | 画线工具面板（DrawingInputController） | **DEFERRED → Wave 3**：画线输入 | Wave 3 drawing |
| U2-R3 | 顶栏「仓位 X/5」 | **DEFERRED → Wave 3**：tier 公式未定，拒臆造 | Wave 3 |
| PR11-R1 | 生产 backendBaseURL placeholder | **DEFERRED → NAS 部署**：out-of-Wave-2-scope | NAS 部署 PR |
| PR11-R2 | replay 结束结算窗（U2-R4 retreat） | **DEFERRED → Wave 3**：忠实结算需触碰冻结 E5/E6/SettlementView | Wave 3 replay |
| PR11-R3 | app target 无 CI 构建守护 | **DEFERRED → Wave 3 / infra**：本地 build + 手动运行时验收兜底 | Wave 3+ infra |

**已闭合不另列行的 residual**：E6a-R1（`TRAINING_SET_SCHEMA_VERSION` 共享常量）**CLOSED**（顺位 6 P2 #82 `DownloadAcceptanceRunner.swift` 定义 `TRAINING_SET_SCHEMA_VERSION = 1`）；E6a-R2（既存 activeReader 清理归 endSession）**CLOSED**（顺位 5 E6b #86 `TrainingSessionCoordinator.endSession()` + `endSession_closesReaderClearsActive` 测试）；E6b-R2（maxDrawdown 换算）**CLOSED**（#86 finalize）。

**净结果**：Wave 2 协议级 / 集成级 residual（fail-closed fees / loadError 恢复 / arbiter 接线 / E6 生命周期 / 组合根等）**全部 CLOSED（实现完成）**；其余明确 **DEFERRED**（Wave 3 打磨 / NAS 部署 / user 运行时回填），均有 target + 证据指针。C8b-R1 doc loose end 在本收尾 CLOSED。Wave 2 scope 内无悬挂承诺。

---

## 四、carried residual（W1 系列，仍 OPEN，不在 Wave 2 scope）

| ID | residual | 状态 |
|---|---|---|
| W1-R1 | `docker-compose.yml` image digest pin 未做（用 tag `postgres:15.12`；backend deps 已 `==` exact pin） | **OPEN**：supply-chain 加固，归 NAS 部署 PR（改 `postgres@sha256:<digest>`）。outline §六明列「部署/NAS 类」不在 Wave 2 |
| W1-R2 | 3-5 样本训练组数据未生成（H7） | **OPEN**：需 NAS 真实 CSV 数据源 + B1/B2 真跑。归 NAS 部署 / 数据生产任务 |

两者 Wave 2 outline §六（L156）已明列「部署/NAS 类」不在 Wave 2 顺位，确认排除 Wave 2 scope。

---

## 五、决策：Wave 2 不打 freeze tag

**与 Wave 0 的区别**：Wave 0 freeze ceremony（PR #54 + tag `wave0-frozen-v1.4`）冻结的是 **spec 契约首版**。Wave 2 主体是**按已冻 spec 实现「集成层」**——spec 契约变更集中在单一 governance RFC（顺位 1 #79 三项：H1 措辞松绑 + baseline reconciliation + P6 两层恢复 API 契约），均经 RFC + 逐 PR review，无散落各实施 PR 的契约首冻语义。

**决策**（outline §三.3 预声明 + 沿用 Wave 1 收尾模式 `project_wave1_completion_2026_06_01`）：Wave 2 **不**新建 signoff ledger、**不**打 `wave2-frozen` tag、**不**改 README freeze 章节。理由：
1. 无 spec 契约首冻语义（契约变更集中单一 RFC #79，已逐 PR review）。
2. 每 anchor 已各自经 opus 4.8 xhigh 对抗审查 + acceptance + memory，provenance 已分布式留痕。
3. freeze tag / signoff ledger 成本（三层 protected-tag gate + 三角色签字）对「集成 Wave」收益低。
4. 若后续需正式冻结点（如 Wave 3 启动前基线），可届时补打 tag。

**评审通道说明**：Wave 2 全程用 **opus 4.8 xhigh 对抗审查**（非 codex；codex 周配额耗尽 fallback，per 各 anchor memory），merge 经 `--admin` 绕 `codex-verify-pass`（Catalyst/swift test required check 真绿不绕）。

---

## 六、Wave 3 边界（确认，不在本收尾 scope）

Wave 3 候选范围（汇总自各 anchor DEFERRED）：
- **图表手势打磨**：pinch 缩放（C8a 硬编码 visibleCount/ratio）、画线输入（U2-R2）、十字光标吸附/HUD。
- **交易功能**：手动强平按钮（U2-R1）、仓位档位显示（U2-R3，需先定 tier 公式）、replay 结算窗（PR11-R2）。
- **UI 打磨**：结束总资金 vs 当前总资金显示语义（E6b-R1）。
- **基础设施**：app target CI 守护（PR11-R3）、cache 运维（E6a-R3）。
- **部署 / NAS**：W1-R1（image digest pin）、W1-R2（样本数据）、PR11-R1（backendBaseURL）。

Wave 3 排序为独立规划 session（brainstorming + writing-plans），不在本轻量收尾内。

---

## 七、评审记录

本收尾 doc 经 **opus 4.8 xhigh 对抗审查 R1 = APPROVE**（13 SHA 逐一核 git log 精确 / H1 闭环不 overclaim / 运行时 gate 诚实"pending"〔c8b runbook #3 `____ ms` 未填实证〕/ C8b-R1 闭口已验〔plan 确不在 #87，现还原内容匹配 ChartContainerView.swift:4〕/ W1-R1·R2 正确 OPEN / doc-only 0 code/CI/ruleset）。E6a-R1/R2/E6b-R2 已闭合补注（§三 footnote）。

**已知 pre-existing nit（不在本 PR scope，mention 不 fix per 仓 §3 surgical-changes）**：`docs/superpowers/specs/2026-06-02-wave2-outline-design.md:1` 标题写 `（v2）` 但 changelog 至 v7（L171）+ #78 subject "11 anchor"——本 doc 引用「outline（v7，PR #78）」是正确版本号；outline 标题 stale 留待后续 doc 维护。
