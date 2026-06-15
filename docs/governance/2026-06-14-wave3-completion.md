# Wave 3 功能交付确认（非『Wave 3 正式关闭』，运行时验收待回填）

**日期**：2026-06-14
**性质**：Wave 3 outline（PR #92）全 anchor 落地后的**功能交付确认 + 运行时验收待回填**——residual 终态回填 + completion 确认 + 单一运行时矩阵 runbook 交付。**非『Wave 3 正式关闭』**：outline §三.3 把「Wave 3 全交互运行时矩阵的 device/sim 实测结果已记录」定为顺位 13 收尾本身的硬前提，该硬门在本 doc merge 时**未满足**（runbook + fixture 已交付可执行，device 实测待用户回填）。**不打 freeze tag**（见 §五）。0 业务代码 / 0 CI / 0 ruleset 改动。

<!-- WAVE3-STATUS (machine-readable; consumed by scripts/governance/verify-wave3-completion.sh — DO NOT reword keys/values)
status: feature-complete-fixture-playable
store-ready: NO
formal-closure: PENDING-runtime-matrix-device-record
runtime-matrix: PARTIAL
freeze-tag: NOT-TAGGED
residual-A-cache-touch-on-use: CLOSED 13a #108
residual-B-unified-toast-layer: CLOSED 13a #108
residual-C-fixture-provisioning: CLOSED 13b #109
residual-D-e2e-smoke: CLOSED 13b #109
residual-W3-11-R1-bounce-live-wiring: OPEN
ship-gate-PR11-R1-prod-backend-url: OPEN
ship-gate-W1-R2-sample-data: OPEN
-->

---

## 一、Wave 3 anchor 交付清单（全 merged）

| 顺位 | Anchor | PR | squash SHA |
|---|---|---|---|
| — | Wave 3 outline（非 anchor，列为起点） | #92 | `fe0a23a` |
| 1 | spec-gap 治理 RFC（7 契约，纯文档） | #94 | `8aa0c02` |
| 2 | app-target CI 守护 + 竖屏/窗口策略 | #93 | `cf43a43` |
| 3 | Pinch 缩放（engine-owned zoom） | #98 | `3187072` |
| 4 | 水平线绘线 MVP + 画线 source-of-truth 全链路 | #103 | `364af1f` |
| 5 | 十字光标吸附 + HUD | #101 | `567cb69` |
| 6a | TrainingEngine 手动强平 + currentPositionTier | #95 | `33f3903` |
| 6b | appendDrawing + replaySettlementPayload engine 契约 | #97 | `ddc96ea` |
| 7 | U2 交易 UI 接线 + 交易反馈（仓位 X/5 + 手动强平 + Toast/触觉） | #100 | `d991c77` |
| 8 | Replay 结算窗（UI/routing-only） | #102 | `d61cbe1` |
| 9 | 夜间模式（白天/夜间/跟随系统） | #106 | `c537458` |
| 10a | 持久化基础（原子 finalize port + session-key schema 迁移） | #99 | `b4f0e2a` |
| 10b | 持久化集成（周期 autosave + 终态 fence + provenance 恢复） | #107 | `bcf32b1` |
| 11 | C2 边缘 bounce 动画（组件层隔离） | #96 | `7eaf00b` |
| 12 | 性能评审 + 帧预算判据 + Bitmap Cache 决议 | #104 | `836acba` |
| 13a | cache touch-on-use + 边界错误统一 Toast 层 | #108 | `9400361` |
| 13b | 全 app fixture provisioning + 生产路径 E2E smoke | #109 | `fc46fef` |
| 13c | Wave 3 收尾 doc（本 PR） | 本 PR | （merge 后回填） |

**全 17 行 anchor merged**（顺位编号 = 稳定 ID 非执行序，per outline §二编号语义；顺位 6/10/13 各拆 a/b 两 PR）。每 anchor 的验收清单见各自 `docs/acceptance/` / `docs/runbooks/` 文件；每 anchor 的 merge 记录见 memory `project_pr<N>_*_merged`。SHA 已据 `git log origin/main`（2026-06-14）核实。

**非-anchor 并行治理 PR（脚注，不计入 anchor 序）**：#105 `2d2e28f`（本地 codex-attest 解耦自动更新插件缓存）——Wave 3 窗口内的治理 PR，非 outline anchor，不计入 Wave 3 功能完成度。

---

## 二、reconcile outline §三.3 硬门：为何不宣布 closure

**outline §三.3 / L181 原文**：「**顺位 13 收尾 + 任何 freeze tag 阻塞依赖 = 上述 Wave 3 运行时矩阵（经顺位 10 fixture provisioning 执行）+ Wave 2 两份 runbook 的 device/simulator 实测结果已记录 + Instruments 帧预算实测数值已回填。运行时验收是 user device 职责，但其完成是 Wave 3 关闭的硬前提，非「某天再说」。**」

该硬门把「实测结果已记录」定为**顺位 13 收尾本身**（非仅 freeze tag）的硬前提。本 doc 交付：

- **运行时矩阵 runbook**（`docs/acceptance/2026-06-14-wave3-runtime-matrix.md`）：汇总 6 条 device happy-path 交互 + §C fixture 端到端，每行 device pass/fail 留空。
- **§C fixture provisioning**（13b PR #109 已 merged）：经 `KLINE_SEED_FIXTURE=1` 在真 composition root provision 缓存 + 历史 + pending + 设置，使矩阵**可执行**。

**§三.3 硬门是三连合取，正式关闭须三者皆回填（不止本矩阵）**：上引原文把关闭/freeze 阻塞依赖定为 **①Wave 3 运行时矩阵（经 §C fixture，= 本 doc 交付的 runbook）+ ②Wave 2 两份 runbook 的 device/sim 实测已记录 + ③Instruments 帧预算实测数值已回填**。本 doc 交付的运行时矩阵 runbook 仅覆盖合取项 ①（Wave 3 新交互）；合取项 ②③ 由各自既有 runbook 承载、实测同样 pending：
- ② Wave 2 减速/帧预算 + 手势：`docs/runbooks/2026-06-07-c8b-runtime-acceptance.md` + `docs/runbooks/2026-06-07-u2-gesture-runtime-acceptance.md`。
- ③ Instruments 帧预算（顺位 12）：`docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`（`____` 占位待回填）。
矩阵 runbook 的「关闭前其余硬门」节汇总此二指针，避免用户误以为跑完 ① 即满足硬门。

本 doc **不代跑 device/sim 实测**（运行时验收是用户 device 职责，per outline §三.3）。故该硬门（三合取）在 13c merge 时**未满足** → 本 doc 定位 = **「功能交付确认 + 运行时验收待回填」**，**不**宣布「Wave 3 正式关闭」。正式关闭 = 用户跑完**三连硬门全部**（① 本 Wave 3 矩阵 runbook + ② Wave 2 两份 runbook + ③ Instruments 帧预算 runbook）并记录三者 device 结果后（届时若需冻结，走 §五 tag ceremony）。

**Wave 1/2 先例作语义旁证（不推翻 §三.3）**：Wave 1（`project_wave1_completion`）/ Wave 2（`docs/governance/2026-06-09-wave2-completion.md` §二）均在 device runbook 未实测时记「completion / 功能交付确认」，运行时实测标 pending（用户职责）。本 doc 沿用「功能交付确认」语义，但**不**用 Wave 1/2 先例推翻 outline §三.3「非某天再说」的更严表述——本 doc 用 WAVE3-STATUS 的 `formal-closure: PENDING-runtime-matrix-device-record` + `runtime-matrix: PARTIAL` 如实表达「待回填」。

**点名对 spec §E.2 矩阵清单的 bounce 纠正（ledger 完整性优先）**：spec §E.2（`docs/superpowers/specs/2026-06-14-wave3-pr13-completion-design.md` L181）把「边缘 bounce（顺位 11）」列进运行时矩阵 happy-path 交互。经核实，顺位 11 acceptance（`docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md:1-3`）头部明文「**无实时可见运行时接线**（接线 deferred 为 residual `W3-11-R1`）」——真 app 屏幕**无可见回弹运行时**，组件层物理仅确定性单测闭合。把 bounce 列进 device 运行时矩阵属 **overclaim**。本 doc 如实纠正：**W3-11-R1 标 OPEN**（见三节）+ **运行时矩阵不列 bounce device happy-path 行**（矩阵 runbook 在「排除/OPEN」节单列 W3-11-R1）。本 doc **不回改 spec §E.2**（spec 已冻结，散文措辞留待 doc 维护），但 residual ledger 须完整——ledger 完整性优先于逐字照搬 spec 的错误清单。故 device happy-path 矩阵实为 **6** 条交互（pinch 3 / 水平线 4 / 十字光标 5 / 手动强平 7 / replay 结算 8 / 主题 9）+ §C fixture 的 save-resume/复盘/replay 端到端。

---

## 三、Wave 3 residual 终态回填

| Residual | 来源 | 13c 终态 | 证据指针 |
|---|---|---|---|
| **A. cache touch-on-use**（E6a-R3） | §107 deferred #4 / Wave 2 §三 | **CLOSED** | 13a PR #108 `9400361`（coordinator 4 read 路径 startNewNormalSession/resumePending/review/replay 成功打开后 touch-on-use；损坏文件不 touch） |
| **B. 边界错误统一 Toast 层** | outline §四 L204（损坏/中断/磁盘满 + 统一错误） | **CLOSED** | 13a PR #108 `9400361`（ToastState/ToastOverlay 承载 transient：autosave 失败可见 + 下载 per-item 失败可见；blocking 错误故意保留 alert，不回归 §4.7f/§4.7a 安全语义） |
| **C. 全 app fixture provisioning** | §107 deferred / spec §C | **CLOSED** | 13b PR #109 `fc46fef`（`AppContainer+DebugSeed` `#if DEBUG` seed 经 `AppContainer.init(debugSeedFixtures:)` 注入 cache+history+pending+settings，全 6 周期；全空 guard 不破坏真实数据） |
| **D. 生产路径 E2E smoke** | §107 deferred / spec §D | **CLOSED** | 13b PR #109 `fc46fef`（真 `DownloadAcceptanceRunner` 下游可消费 smoke：download→verify→commit→available→openable 全链） |
| **运行时矩阵（device/sim 实测）** | outline §三.3 硬门 | **PARTIAL** | runbook 交付（`docs/acceptance/2026-06-14-wave3-runtime-matrix.md`）+ §C fixture 使其可执行；device 实测结果待用户回填 |
| **W3-11-R1**（bounce live 接线） | 顺位 11 #96 设计 D8 / bounce acceptance L3 | **OPEN** | 组件层物理已确定性单测闭合（`docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md`）；**真 app 无可见回弹运行时** → **不**入 device 矩阵；live 接线 = fast-follow 独立 PR |
| **PR11-R1**（生产 backendBaseURL） | Wave 2 §三 carried（见四节） | **OPEN** | NAS 部署 PR（out-of-Wave-3-scope ship 门；`KlineTrainerApp.swift` 硬编码 `http://kline-trainer.local`） |
| **W1-R2**（真实样本训练组数据，H7） | Wave 1 §四 carried（见四节） | **OPEN** | 需 NAS 真实 CSV 数据源 + B1/B2 真跑 |

**13a/13b PR-内 residual 终态（脚注，不重复逐条列举，避免双重账本）**：13a-R1/R2/R3（confirm-state 反馈精度 / 跨 lease cache 误删 pre-existing / touch-on-use TOCTOU）已在 `docs/acceptance/2026-06-14-wave3-pr13a-robustness.md` 标 **OUT of 13a scope**（归独立 P2-confirm-reliability / P5-cache-pinning RFC）+ codex review accept residual + user TTY attest-override；13b-R1/R2/R3（极端 partial-seed / settings-row 零值歧义 / §D verifier 用 fake）已在 `docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md` 标 **accept residual**（debug-only 边角 / trust-boundary 协议扩展 = 过度工程）+ codex review accept residual + user TTY attest-override。**均非协议级悬挂**，指针见各自 acceptance；本 completion doc 不进位本 ledger。

---

## 四、carried residual（仍 OPEN，不在 Wave 3 scope）

| ID | residual | 状态 |
|---|---|---|
| **PR11-R1** | 生产 backendBaseURL placeholder（`KlineTrainerApp.swift` 硬编码 `http://kline-trainer.local`） | **OPEN**：out-of-Wave-3-scope；归 NAS 部署 PR。outline §三.3 / §六明列「部署/NAS 类」为未完成 ship 门，不计入 Wave 3 功能完成度 |
| **W1-R2** | 真实样本训练组数据未生成（H7，3-5 组） | **OPEN**：需 NAS 真实 CSV 数据源 + B1/B2 真跑。归 NAS 部署 / 数据生产任务；正式上架前提，不计入 Wave 3 功能完成度 |

二者为正式上架的剩余 ship 门（per outline §三.3 完成 claim 诚实条款 / spec L7）。Wave 3 = 客户端 feature 完整 + 端到端 fixture 验证可玩，**不**等于「可上架商店」。

---

## 五、freeze tag 决策：不打 freeze tag

**决策**：13c **不打 freeze tag**，沿用 Wave 1/2 轻量收尾先例（`project_wave1_completion` / `docs/governance/2026-06-09-wave2-completion.md` §五均未打 tag）。WAVE3-STATUS 记 `freeze-tag: NOT-TAGGED`。

**3 理由**：

1. **无 recorded 矩阵不满足 outline §三.3 硬门**：outline §三.3 / L181 把「Wave 3 运行时矩阵 + Wave 2 两份 runbook device 实测已记录 + Instruments 帧预算已回填」（**三连合取**，见 §二）定为 freeze tag 与正式关闭的**共同**硬前提；本 doc 交付 runbook 但不代跑 device 实测，三合取均未满足 → tag 语义不成立。
2. **ship 门未关 store-frozen 语义不成立**：PR11-R1（生产 backendBaseURL）+ W1-R2（真实样本数据）= OPEN（四节），store-ship readiness 未达 → 无可冻结的「上架就绪」语义。
3. **与 Wave 1/2 一致**：前两 wave 均轻量收尾不打 tag；Wave 3 为客户端功能完成 wave（非 spec 契约首冻），无散落各实施 PR 的契约首冻语义。

**后续**：用户在 device 跑完**三连硬门全部**（Wave 3 矩阵 runbook + Wave 2 两份 runbook + Instruments 帧预算 runbook，见 §二）并记录结果后，若希望冻结客户端功能完整性，可走独立 tag ceremony（轻流程，per outline §三.3 / spec §E.4）。本决策按用户「尽可能不要找我」自主裁决为「不打 tag + 文档化 deferred-pending-recorded-matrix + 推荐」；若用户事后希望打 tag，属 follow-up，不阻塞 Wave 3 功能交付确认。

---

## 六、评审通道说明

13c 为 doc-only（0 业务代码 / 0 CI / 0 ruleset），经 `codex:adversarial-review`（治理 doc 类，唯一 review 通道，per CLAUDE.md backstop #1）。codex 周配额耗尽时方 fallback opus 4.8 xhigh（documented，沿用 Wave 1/2 + 13a/13b 各 anchor 先例）。grep gate（`scripts/governance/verify-wave3-completion.sh`）作机器可校验断言：A/B/C/D CLOSED + W3-11-R1/PR11-R1/W1-R2 OPEN + WAVE3-STATUS 诚实（store-ready=NO / formal-closure=PENDING / matrix=PARTIAL / freeze=NOT-TAGGED）+ 矩阵 fixture 机制就位。

---

## 七、评审记录

（待回填 review verdict）
