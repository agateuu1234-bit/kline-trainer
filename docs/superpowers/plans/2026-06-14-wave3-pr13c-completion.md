# Wave 3 PR 13c — 收尾 doc（completion + 运行时矩阵 runbook + residual 回填 + freeze 决策）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付 Wave 3 顺位 13 收尾的 doc-only 三件套（completion doc + 单一运行时矩阵 runbook + 机器可校验 grep gate + 非-coder 验收清单），如实回填 13a/13b residual 并诚实声明「功能交付确认 + 运行时验收待回填」（非「Wave 3 正式关闭」）。

**Architecture:** 纯文档 PR，0 业务代码 / 0 CI workflow / 0 ruleset 改动。沿用 `docs/governance/2026-06-09-wave2-completion.md` 结构写 completion doc；把 6 份既有 per-anchor 运行时 runbook 汇总成单一矩阵并标注「经 §C fixture（`KLINE_SEED_FIXTURE=1`）执行」；新写 `scripts/governance/verify-wave3-completion.sh` grep gate（3 谓词：A/B/C/D CLOSED + ship 门 OPEN + 机器可读 store-ready=NO 状态行），fail-closed。completion doc 嵌一个机器可读 `WAVE3-STATUS` 注释块，使 grep gate 不靠脆弱的散文措辞匹配（规避 `feedback_acceptance_grep_anchoring` 的负向断言陷阱）。

**Tech Stack:** Markdown 文档；bash grep gate（`set -euo pipefail` + 显式 `if grep … then exit 1`，不用 `! grep` 负向断言）。

**Source-of-truth:** spec `docs/superpowers/specs/2026-06-14-wave3-pr13-completion-design.md` §E（E.1–E.4）+ §五（评审/grep gate）；outline `docs/superpowers/specs/2026-06-09-wave3-outline-design.md` §三.3（硬门原文）/§四（residual 映射）；前例 `docs/governance/2026-06-09-wave2-completion.md`。

**前置（已满足）:** 13a = PR #108 squash `9400361`（merged）；13b = PR #109 squash `fc46fef`（merged）。本分支 `wave3-pr13c` 从 `origin/main`（`fc46fef`）切出。

---

## 关键诚实边界（贯穿全 plan，opus/codex review 重点）

1. **不 claim「Wave 3 正式关闭」**：outline §三.3 把「Wave 3 全交互运行时矩阵的 device/sim **实测结果已记录**」定为**顺位 13 收尾本身**的硬前提（原文「其完成是 Wave 3 关闭的硬前提，非『某天再说』」）。本工作流交付矩阵 **runbook + fixture provisioning**（使其可执行），但**不代跑 device/sim 实测**（用户职责）→ 该硬门在 13c merge 时**未满足** → completion doc 定位 = **「功能交付确认 + 运行时验收待回填」**，显式承认该硬门、说明为何不僭越宣布 closure。
2. **不 claim store-ready**：真实上架剩余门 = PR11-R1（生产 backendBaseURL）+ W1-R2（真实样本训练组数据，需 NAS）→ ship 门标 **OPEN**。
3. **运行时矩阵 = PARTIAL**：runbook 交付（可执行），device 实测待用户回填。
4. **freeze tag = 不打**：沿用 Wave 1/2 轻量收尾先例；理由 = 无 recorded 矩阵不满足 outline 硬门 + ship 门未关 + 与前两 wave 一致。
5. **§B toast 覆盖归属**：§C seed 仅 provision 有效数据（无 fault injection）→ device happy-path 矩阵**无法**触发 autosave 失败 / 下载失败 toast；其自动化证明归 **§B host 测**（13a），矩阵 runbook 须显式注明此归属，**不**把这两条 toast 列为 device 矩阵项。
6. **bounce（顺位 11）不入 device 矩阵**（opus plan-review C1）：bounce live 接线 = **W3-11-R1 OPEN**（真 app 无可见回弹运行时，组件层物理仅单测闭合）。spec §E.2 把 bounce 列进运行时矩阵属 overclaim → completion doc **如实纠正**：W3-11-R1 标 OPEN residual + 矩阵**不列** bounce device happy-path 行；诚实边界节点名此对 spec §E.2 矩阵清单的纠正（ledger 完整性优先于逐字照搬 spec 的错误）。device happy-path 矩阵实为 **6** 条交互（pinch 3 / 水平线 4 / 十字光标 5 / 手动强平 7 / replay 结算 8 / 主题 9）+ §C fixture 的 save-resume/复盘/replay 端到端。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `docs/governance/2026-06-14-wave3-completion.md` | E.1 anchor 清单 + reconcile outline §3.3 + E.3 residual 终态回填 + E.4 freeze 决策 + 机器可读 WAVE3-STATUS 块 | Create |
| `docs/acceptance/2026-06-14-wave3-runtime-matrix.md` | E.2 单一运行时矩阵 runbook（汇总 6 份 per-anchor runbook + §C fixture 执行说明 + save-resume/复盘/replay 端到端 + §B toast 归属澄清） | Create |
| `scripts/governance/verify-wave3-completion.sh` | grep gate（3 谓词 fail-closed） | Create |
| `docs/acceptance/2026-06-14-wave3-pr13c-completion.md` | 非-coder 验收清单（含跑 grep gate 步骤） | Create |

**Anchor SHA 权威表**（据 `git log origin/main` 2026-06-14；顺位编号 = 稳定 ID 非执行序，per outline §二编号语义）：

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
| 11 | C2 边缘 bounce 动画 | #96 | `7eaf00b` |
| 12 | 性能评审 + 帧预算判据 + Bitmap Cache 决议 | #104 | `836acba` |
| 13a | cache touch-on-use + 边界错误统一 Toast 层 | #108 | `9400361` |
| 13b | 全 app fixture provisioning + 生产路径 E2E smoke | #109 | `fc46fef` |
| 13c | Wave 3 收尾 doc（本 PR） | 本 PR | （merge 后回填） |

**非-anchor 并行治理 PR（脚注，不计入 anchor 序）**：#105 `2d2e28f`（本地 codex-attest 解耦自动更新插件缓存）——Wave 3 窗口内的治理 PR，非 outline anchor。

**residual 回填映射表**（E.3，源自 §107 4 项 deferred「10c」label + outline §四）：

| Residual | 来源 | 13c 终态 | 证据指针 |
|---|---|---|---|
| **A. cache touch-on-use**（E6a-R3） | §107 deferred #4 / Wave 2 §三 | **CLOSED** | 13a PR #108 `9400361`（coordinator 4 read 路径 touch-on-use） |
| **B. 边界错误统一 Toast 层** | outline §四 L204（损坏/中断/磁盘满 + 统一错误） | **CLOSED** | 13a PR #108 `9400361`（ToastState/ToastOverlay 承载 transient；blocking 保留 alert） |
| **C. 全 app fixture provisioning** | §107 deferred / spec §C | **CLOSED** | 13b PR #109 `fc46fef`（DebugFixtures #if DEBUG seed 经 AppContainer 注入 cache+history+pending+settings，全 6 周期） |
| **D. 生产路径 E2E smoke** | §107 deferred / spec §D | **CLOSED** | 13b PR #109 `fc46fef`（真 DownloadAcceptanceRunner 下游可消费 smoke） |
| **运行时矩阵（device/sim 实测）** | outline §三.3 硬门 | **PARTIAL** | runbook 交付（`2026-06-14-wave3-runtime-matrix.md`）；device 实测待用户回填 |
| **W3-11-R1**（bounce live 接线） | 顺位 11 #96 设计 D8 / pinch acceptance L30 | **OPEN** | 组件层物理已单测闭合（`docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md`）；live 接线 = 顺位 3 后 fast-follow 独立 PR，**真 app 无可见回弹运行时** → **不**入 device 矩阵 |
| **PR11-R1**（生产 backendBaseURL） | Wave 2 §三 carried | **OPEN** | NAS 部署 PR（out-of-Wave-3-scope ship 门） |
| **W1-R2**（真实样本训练组数据，H7） | Wave 1 §四 carried | **OPEN** | 需 NAS 真实 CSV 数据源 + B1/B2 真跑 |

> **W3-11-R1 由 opus plan-review C1 补入**（spec §E.2 + outline §三.3 漏列）：bounce（顺位 11）头部明文「无实时可见运行时接线，接线 deferred 为 residual W3-11-R1」。spec §E.2 把 bounce 列进运行时矩阵 = overclaim（真 app 看不到回弹）→ completion doc 如实把 W3-11-R1 标 OPEN + **矩阵不列 bounce device 行**。completion doc 诚实边界节须点名此处对 spec §E.2 矩阵清单的纠正（不回改 spec，但 ledger 须完整）。

**13a/13b 各自的 PR-内 residual（13b-R1/R2/R3 等）**：已在各自 acceptance doc + merge 内 accept residual + override 处置；本 completion doc **不**重复逐条列举，仅在 §三脚注指针引用（避免双重账本）。

---

## Task 1: Completion doc（E.1 + reconcile §3.3 + E.3 residual + E.4 freeze + WAVE3-STATUS 块）

**Files:**
- Create: `docs/governance/2026-06-14-wave3-completion.md`

**结构**（沿用 `2026-06-09-wave2-completion.md` 七节骨架，按 Wave 3 调整）：
- 头部：日期 2026-06-14 + 性质（**功能交付确认 + 运行时验收待回填，非正式关闭**；0 业务代码/CI/ruleset）。
- **机器可读 WAVE3-STATUS 块**（紧跟头部，供 grep gate 消费，见下方 Step 2 字面）。
- 一、Wave 3 anchor 交付清单（上方「Anchor SHA 权威表」全 17 行 + 非-anchor #105 脚注）。
- 二、reconcile outline §三.3 硬门（**关键 High，解 spec-review R1**）：引用原文「实测结果已记录是顺位 13 收尾本身硬前提，非『某天再说』」→ 说明本 doc 交付 runbook+fixture（可执行）但不代跑 → 故**不**宣布 closure；Wave 1/2 先例作「功能交付确认」语义旁证但**不**用以推翻 §三.3 更严表述。
- 三、Wave 3 residual 终态回填（上方「residual 回填映射表」**8 行**〔含 W3-11-R1〕+ 13a/13b PR-内 residual 终态核对脚注，见 Step 1b）。
- 四、carried residual（PR11-R1 / W1-R2 仍 OPEN，NAS scope）。
- 五、freeze tag 决策（**不打**；3 理由：无 recorded 矩阵不满足 §三.3 硬门 + ship 门未关 store-frozen 语义不成立 + 与 Wave 1/2 一致；用户跑完矩阵后若需冻结走独立轻流程 tag ceremony）。
- 六、评审通道说明（13c doc-only 经 codex:adversarial-review 治理 doc 类；codex 周配额耗尽 fallback opus 4.8 xhigh）。
- 七、评审记录（留空待回填 review verdict）。

- [ ] **Step 1: 写 completion doc 主体（七节 + 两表）**

按上方结构与两张权威表逐节写。**硬要求**：
- 一节 anchor 表 17 行 SHA 与「Anchor SHA 权威表」逐字一致。
- 二节须含 outline §三.3 原文引用 + 「为何不宣布 closure」论证 + **点名对 spec §E.2 矩阵清单的 bounce 纠正**（W3-11-R1 OPEN，见诚实边界 #6）。
- 三节 residual 表 **8 行**（含 W3-11-R1 OPEN），A/B/C/D 行各含字面 `CLOSED` + 对应 13a/13b PR 号；运行时矩阵行含 `PARTIAL`；W3-11-R1/PR11-R1/W1-R2 行含 `OPEN`。
- 五节 freeze 决策含字面「不打 freeze tag」。
- 标题/性质含字面「功能交付确认」+「非正式关闭」（或「非『Wave 3 正式关闭』」）。

- [ ] **Step 1b: 核对 13a/13b PR-内 residual 终态（opus plan-review M3）**

Run（确认 13a/13b 各自 acceptance 的 PR-内 residual 均 CLOSED 或 accept-residual+override，否则未 close 的须进位本 doc ledger）：
```bash
grep -nE "Residual|13a-R|13b-R|accept residual|CLOSED|override" docs/acceptance/2026-06-14-wave3-pr13a-robustness.md docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md
```
Expected: 13a-R1/R2/R3 + 13b-R1/R2/R3 均已在各自 doc accept residual + override 处置（debug-only / surgical 边角）。completion doc §三脚注据此写「13a/13b PR-内 residual（13a-R1/R2/R3、13b-R1/R2/R3）已在各自 acceptance accept-residual+override，均非协议级悬挂，指针见各 acceptance」。**若发现任一未处置** → 进位本 doc ledger 作 OPEN/PARTIAL 并加 WAVE3-STATUS 行。

- [ ] **Step 2: 嵌入机器可读 WAVE3-STATUS 块（含 residual ledger，grep gate 单行精确消费）**

在头部之后插入（grep gate 谓词 1/2/3 全消费此块——每项一行固定串，杜绝散文/跨行假 PASS，per opus plan-review H1）。**人读 residual 表（三节）与本机器块须事实一致**：

> ⚠️ **SUPERSEDED — 下方为 plan-stage 初稿示意，非最终权威（codex review R6-Med）**。最终权威 WAVE3-STATUS ledger = **`docs/governance/2026-06-14-wave3-completion.md` 机器块**（经 codex:adversarial-review R1–R6 演进）。本 plan 是规划 source-of-truth（任务结构/判据），**非状态 ledger**；下方块已同步至最终值仅供参照，权威以 completion doc 为准。

```markdown
<!-- WAVE3-STATUS (machine-readable; consumed by scripts/governance/verify-wave3-completion.sh — DO NOT reword keys/values)
status: anchors-merged-fixture-playable
feature-completeness: PENDING-W3-11-R1-bounce-live-wiring
store-ready: NO
formal-closure: PENDING-runtime-matrix-device-record
runtime-matrix: PARTIAL
freeze-tag: NOT-TAGGED
residual-A-cache-touch-on-use: CLOSED 13a #108
residual-B-unified-toast-layer: CLOSED 13a #108
residual-C-fixture-provisioning: CLOSED 13b #109
residual-D-e2e-smoke: PARTIAL 13b #109
residual-W3-11-R1-bounce-live-wiring: OPEN
known-defect-13a-R2-cross-lease-cache-deletion: OPEN
ship-gate-PR11-R1-prod-backend-url: OPEN
ship-gate-W1-R2-sample-data: OPEN
-->
```

- [ ] **Step 3: Commit**

```bash
git add docs/governance/2026-06-14-wave3-completion.md
git commit -m "docs(13c): Wave 3 completion doc（功能交付确认 + reconcile §3.3 + residual 回填 + freeze 不打）"
```

---

## Task 2: 运行时矩阵 runbook（E.2 单一矩阵 + §C fixture 执行 + §B toast 归属）

**Files:**
- Create: `docs/acceptance/2026-06-14-wave3-runtime-matrix.md`

**汇总源**（**6** 份既有 per-anchor 运行时 runbook/acceptance；矩阵**引用**而非复制其细节。bounce 顺位 11 **不在内**——见下方排除说明）：
- 顺位 3 Pinch：`docs/acceptance/2026-06-13-wave3-pr3-pinch-zoom.md`
- 顺位 4 水平线绘制+跨缩放还原：`docs/acceptance/2026-06-13-wave3-pr4-drawing-mvp.md`
- 顺位 5 十字光标 snap/HUD：`docs/acceptance/2026-06-13-wave3-pr5-crosshair-snap-hud.md`
- 顺位 7 手动强平 + 交易反馈：`docs/runbooks/2026-06-13-wave3-pr7-trade-ui-runtime-acceptance.md`
- 顺位 8 replay 结算窗：`docs/runbooks/2026-06-13-wave3-pr8-replay-settlement-runtime-acceptance.md`
- 顺位 9 主题切换视觉：`docs/runbooks/2026-06-14-wave3-pr9-night-mode-runtime-acceptance.md`

**bounce（顺位 11）排除**（opus plan-review C1）：bounce 头部明文「无实时可见运行时接线，接线 deferred = W3-11-R1 OPEN」（`docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md:1-3`）→ 真 app 无可见回弹运行时 → **不**列 device happy-path 矩阵；改在矩阵的「排除/OPEN」节单列 W3-11-R1 OPEN（组件层物理已单测闭合，live 接线 = fast-follow PR）。

- [ ] **Step 1: 核实 6 anchor 的 runbook 路径存在 + bounce 确无 runtime runbook**

Run:
```bash
ls docs/runbooks/2026-06-13-wave3-pr7-trade-ui-runtime-acceptance.md \
   docs/runbooks/2026-06-13-wave3-pr8-replay-settlement-runtime-acceptance.md \
   docs/runbooks/2026-06-14-wave3-pr9-night-mode-runtime-acceptance.md \
   docs/acceptance/2026-06-13-wave3-pr3-pinch-zoom.md \
   docs/acceptance/2026-06-13-wave3-pr4-drawing-mvp.md \
   docs/acceptance/2026-06-13-wave3-pr5-crosshair-snap-hud.md \
   docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md
```
Expected: 7 路径全存在（前 6 = device 矩阵引用源；第 7 = bounce 组件层 acceptance，证 bounce 无 runtime runbook、属 W3-11-R1 OPEN，矩阵据此排除而非列入）。

- [ ] **Step 2: 写矩阵 runbook 主体**

结构：
- 头部：性质（device/sim **手动**验收，非-coder 可执行；CI 仅 Catalyst/app-build 编译守护不验运行时）+ **前置（关键）**：在 Xcode scheme 的 Run → Arguments → Environment Variables 设 `KLINE_SEED_FIXTURE=1`，启动 `KlineTrainer` app target → 经 §C fixture seed 自动 provision 缓存训练组（全 6 周期）+ 历史 + pending + 设置，使下列交互可达（引用机制 `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift:19-23`）。
- **汇总矩阵表**（每行：顺位 / 交互 / 经 §C fixture 可达性 / 详细 runbook 指针 / device pass-fail 留空）：覆盖 **6** 条 happy-path 交互——pinch 聚焦/clamp（3）、水平线绘制+跨缩放还原（4）、十字光标 snap/HUD（5）、手动强平（7）、replay 结算窗（8）、主题切换视觉（9）。
- **§C fixture 端到端附加行**：save-resume（推几 tick → 杀 app → 重启 resume pending）、复盘（review 既有 record）、replay（replay 既有 record + 结算）——三者经 seed 的 history/pending 可达。
- **排除/OPEN 节**：bounce（顺位 11）= **W3-11-R1 OPEN**，组件层物理已单测闭合，真 app 无可见回弹 device 运行时，**不**列上表；live 接线 = fast-follow PR（引 `docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md`）。
- **§B toast 覆盖归属澄清块**（关键，解 spec-review R2-Med / R2 新 Med）：明确 §C seed 仅 provision **有效**数据（无 fault injection：不模拟磁盘满 / 不强制下载 reject）→ device happy-path 矩阵**无法**触发 autosave 失败 / 下载失败 toast → 其自动化证明归 **§B host 测**（13a PR #108 的 Toast 测试），**非** device 矩阵。
- 尾部：回填说明（device 跑完逐行填 pass/fail；本矩阵是顺位 13 正式关闭 + freeze tag 的共同硬前提，per outline §三.3）。

- [ ] **Step 3: Commit**

```bash
git add docs/acceptance/2026-06-14-wave3-runtime-matrix.md
git commit -m "docs(13c): Wave 3 运行时矩阵 runbook（汇总 6 device 交互 + §C fixture 执行 + bounce/W3-11-R1 排除 + §B toast 归属）"
```

---

## Task 3: grep gate 脚本（3 谓词 fail-closed）+ 跑绿

**Files:**
- Create: `scripts/governance/verify-wave3-completion.sh`

**设计纪律**（per `feedback_acceptance_grep_anchoring` + opus plan-review H1）：用 `grep -Fq "$固定串" || fail` 显式分支（fail 即 `exit 1`），**不**用 `set -e` 下的 `! grep`（负向断言会因 `set -e` 提前死闸或假 PASS）；**全部谓词消费 completion doc 头部的机器可读 WAVE3-STATUS 块**——每项一行固定串（`residual-X: CLOSED` / `ship-gate-Y: OPEN` / `store-ready: NO`），单行精确匹配，杜绝「标签出现于 ledger 行 + 脚注两处 → 跨行假 PASS」（H1 的根因：旧谓词 `grep -F item | grep -q CLOSED` 在多行下 CLOSED 可被别行满足）。

- [ ] **Step 1: 写 grep gate 脚本**

```bash
#!/usr/bin/env bash
# verify-wave3-completion.sh — Wave 3 13c 收尾 doc grep gate（fail-closed，全谓词消费机器可读 WAVE3-STATUS 块）
# 谓词 1：residual A/B/C/D 标 CLOSED（机器块单行精确，杜绝跨行假 PASS，per opus plan-review H1）
# 谓词 2：W3-11-R1 + ship 门 PR11-R1 / W1-R2 标 OPEN
# 谓词 3：高层状态 store-ready=NO + formal-closure=PENDING + matrix PARTIAL + freeze NOT-TAGGED（无误 claim 上架/已关闭）
# 谓词 3b：矩阵 runbook 含 §C fixture 启动机制
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$ROOT/docs/governance/2026-06-14-wave3-completion.md"
MATRIX="$ROOT/docs/acceptance/2026-06-14-wave3-runtime-matrix.md"

fail() { echo "[verify-wave3-completion] FAIL: $1" >&2; exit 1; }

[ -f "$DOC" ] || fail "completion doc 缺失：$DOC"
[ -f "$MATRIX" ] || fail "运行时矩阵 runbook 缺失：$MATRIX"

# 谓词 1：residual A/B/C/D = CLOSED（单行固定串，机器块）
for line in \
  "residual-A-cache-touch-on-use: CLOSED" \
  "residual-B-unified-toast-layer: CLOSED" \
  "residual-C-fixture-provisioning: CLOSED" \
  "residual-D-e2e-smoke: CLOSED"; do
  grep -Fq "$line" "$DOC" || fail "residual ledger 缺『$line』"
done

# 谓词 2：W3-11-R1 + ship 门 = OPEN（单行固定串，机器块）
for line in \
  "residual-W3-11-R1-bounce-live-wiring: OPEN" \
  "ship-gate-PR11-R1-prod-backend-url: OPEN" \
  "ship-gate-W1-R2-sample-data: OPEN"; do
  grep -Fq "$line" "$DOC" || fail "OPEN 门缺『$line』"
done

# 谓词 3：高层状态（无 store-ready / 正式关闭 误 claim）
grep -Fq "store-ready: NO" "$DOC" || fail "WAVE3-STATUS 缺 store-ready: NO（防 store-ready 误 claim）"
grep -Fq "formal-closure: PENDING" "$DOC" || fail "WAVE3-STATUS 缺 formal-closure: PENDING（防『正式关闭』误 claim）"
grep -Fq "runtime-matrix: PARTIAL" "$DOC" || fail "WAVE3-STATUS 缺 runtime-matrix: PARTIAL"
grep -Fq "freeze-tag: NOT-TAGGED" "$DOC" || fail "WAVE3-STATUS 缺 freeze-tag: NOT-TAGGED"

# 谓词 3b：矩阵 runbook 须含 §C fixture 启动机制
grep -Fq "KLINE_SEED_FIXTURE=1" "$MATRIX" || fail "矩阵 runbook 缺 §C fixture 启动机制 KLINE_SEED_FIXTURE=1"

echo "[verify-wave3-completion] PASS：A/B/C/D CLOSED + W3-11-R1/PR11-R1/W1-R2 OPEN + WAVE3-STATUS 诚实 + 矩阵 fixture 机制就位"
```

- [ ] **Step 2: 赋可执行 + 跑（须 PASS）**

Run:
```bash
chmod +x scripts/governance/verify-wave3-completion.sh
bash scripts/governance/verify-wave3-completion.sh
```
Expected: 退出码 0，末行 `[verify-wave3-completion] PASS：…`。

- [ ] **Step 3: 红验证 ×3（证 3 类谓词各有判别力，非 vacuous；per opus plan-review H2）**

Run（逐一临时破坏 → 须 FAIL → 还原 → 须 PASS）：
```bash
cp docs/governance/2026-06-14-wave3-completion.md /tmp/w3doc.bak

# 红 1：谓词 1（CLOSED）—— residual-A CLOSED→TODO 须 FAIL
sed -i '' 's/residual-A-cache-touch-on-use: CLOSED/residual-A-cache-touch-on-use: TODO/' docs/governance/2026-06-14-wave3-completion.md
bash scripts/governance/verify-wave3-completion.sh; echo "红1 exit=$?"   # 期望 exit=1
cp /tmp/w3doc.bak docs/governance/2026-06-14-wave3-completion.md

# 红 2：谓词 2（OPEN）—— ship-gate-PR11-R1 OPEN→CLOSED 须 FAIL
sed -i '' 's/ship-gate-PR11-R1-prod-backend-url: OPEN/ship-gate-PR11-R1-prod-backend-url: CLOSED/' docs/governance/2026-06-14-wave3-completion.md
bash scripts/governance/verify-wave3-completion.sh; echo "红2 exit=$?"   # 期望 exit=1
cp /tmp/w3doc.bak docs/governance/2026-06-14-wave3-completion.md

# 红 3：谓词 3（store-ready）—— store-ready NO→YES 须 FAIL
sed -i '' 's/store-ready: NO/store-ready: YES/' docs/governance/2026-06-14-wave3-completion.md
bash scripts/governance/verify-wave3-completion.sh; echo "红3 exit=$?"   # 期望 exit=1
cp /tmp/w3doc.bak docs/governance/2026-06-14-wave3-completion.md

# 还原后须 PASS
bash scripts/governance/verify-wave3-completion.sh; echo "还原 exit=$?"   # 期望 exit=0
```
Expected: 红1/红2/红3 各 `exit=1`（分别 FAIL 于谓词 1/2/3）；还原后 `exit=0`（PASS）。证三类谓词均真有判别力。

- [ ] **Step 4: Commit**

```bash
git add scripts/governance/verify-wave3-completion.sh
git commit -m "test(13c): verify-wave3-completion grep gate（机器块消费：A/B/C/D CLOSED + W3-11-R1/ship 门 OPEN + 状态诚实，红验证 ×3 过）"
```

---

## Task 4: 非-coder 验收清单

**Files:**
- Create: `docs/acceptance/2026-06-14-wave3-pr13c-completion.md`

- [ ] **Step 1: 写验收清单**

结构（沿用 13a/13b acceptance 风格；中文；action/expected/pass-fail；禁用语见 `.claude/workflow-rules.json`）：
- PR 范围 + source-of-truth + 评审通道（doc-only 经 codex:adversarial-review 治理 doc 类）。
- 非-coder 可执行步骤表，至少含：
  1. 浏览器打开 PR，见 4 新文件（completion doc + 矩阵 runbook + grep gate + 本 acceptance），0 业务/CI/ruleset 改动。
  2. 看 completion doc 一节 anchor 表 17 行 SHA 与 git log 一致。
  3. 看二节 reconcile：含 outline §三.3 原文引用 + 「不宣布 closure」论证。
  4. 看三节 residual 表（8 行）：A/B/C/D = CLOSED（引 13a/13b PR）；运行时矩阵 = PARTIAL；**W3-11-R1**（bounce live 接线）/ PR11-R1 / W1-R2 = OPEN。
  5. 看五节 freeze 决策 = 不打 tag（3 理由）。
  6. 跑 `bash scripts/governance/verify-wave3-completion.sh` → PASS。
  7. 看矩阵 runbook：含 `KLINE_SEED_FIXTURE=1` 启动机制 + **6** happy-path 交互（3/4/5/7/8/9）+ save-resume/复盘/replay 端到端 + **bounce/W3-11-R1 排除节** + §B toast 归属澄清块。
  8. 看 codex 对抗 review verdict = APPROVE（或配额耗尽 fallback opus 4.8 xhigh / accept residual + override）。
- 范围注：device/sim 运行时矩阵实测执行 = 用户职责（本 PR 仅交付可执行 runbook）；正式关闭 + freeze tag 待用户回填矩阵后。
- Residual 表（如有 review 残留）+ codex 收敛说明。

- [ ] **Step 2: Commit**

```bash
git add docs/acceptance/2026-06-14-wave3-pr13c-completion.md
git commit -m "docs(13c): 非-coder 验收清单（completion + 矩阵 + grep gate 步骤）"
```

---

## Self-Review

**1. Spec 覆盖**（§E.1–E.4 + §五）：
- E.1 completion doc → Task 1 ✓（anchor 表 + reconcile §3.3 + bounce/W3-11-R1 纠正点名）
- E.2 运行时矩阵 runbook → Task 2 ✓（汇总 6 device runbook + §C fixture + bounce 排除 + §B toast 归属）
- E.3 residual 终态回填 → Task 1 三节 ✓（A/B/C/D CLOSED + 矩阵 PARTIAL + W3-11-R1/PR11-R1/W1-R2 OPEN）
- E.4 freeze 决策 → Task 1 五节 ✓（不打 tag + 3 理由）
- §五 grep gate → Task 3 ✓（谓词 1/2/3/3b fail-closed + 红验证 ×3）
- §五 非-coder acceptance → Task 4 ✓
- §五 13c 经 codex 对抗 review → 交付后流程（plan 外，merge 仪式覆盖）✓

**2. Placeholder 扫描**：grep gate 脚本为完整 bash（无 TODO）；completion doc / 矩阵 / acceptance 的散文主体由实施时按结构 + 权威表写实（表数据全部内联此 plan，非留白）。七节骨架 + 两权威表 + WAVE3-STATUS 字面块均给全 → 无 "类似 Task N" / "TBD"。

**3. 类型/标识一致性**（grep gate 与 doc 是同一份字面契约）：grep gate **全部谓词消费 WAVE3-STATUS 机器块的固定串**——`residual-A-cache-touch-on-use: CLOSED` / `residual-B-unified-toast-layer: CLOSED` / `residual-C-fixture-provisioning: CLOSED` / `residual-D-e2e-smoke: CLOSED` / `residual-W3-11-R1-bounce-live-wiring: OPEN` / `ship-gate-PR11-R1-prod-backend-url: OPEN` / `ship-gate-W1-R2-sample-data: OPEN` / `store-ready: NO` / `formal-closure: PENDING` / `runtime-matrix: PARTIAL` / `freeze-tag: NOT-TAGGED`（在 completion doc）+ `KLINE_SEED_FIXTURE=1`（在矩阵）——与 Task 1 Step 2 WAVE3-STATUS 块 key/value **逐字一致**（不再依赖散文标签子串匹配，消除 L3 「差『层』字靠巧合」隐患 + H1 跨行假 PASS）。实施时若调机器块措辞须同步改 gate。

**潜在风险已消解（含 opus plan-review R1 全 finding）**：①grep 负向断言陷阱（旧 H1 跨行假 PASS）→ 全谓词改消费机器块单行固定串；②红验证仅覆盖谓词 3（旧 H2）→ 红验证 ×3 覆盖谓词 1/2/3；③bounce 无 live 运行时却列 device 矩阵（旧 C1）→ 排除 bounce + 补 W3-11-R1 OPEN residual + 诚实边界 #6 点名 spec §E.2 纠正；④13a/13b PR-内 residual 仅脚注未核终态（旧 M3）→ Task 1 Step 1b 实开 acceptance 核对；⑤双重 residual 账本 → 13a/13b PR-内 residual 仅脚注指针不重列。
