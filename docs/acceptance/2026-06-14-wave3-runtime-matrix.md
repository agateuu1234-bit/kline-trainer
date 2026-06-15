# Wave 3 运行时验收矩阵 runbook（device/sim 手动，中文非-coder 可执行）

**性质**：device/simulator **手动**验收，非编码者可执行。CI 仅 `Mac Catalyst build-for-testing on macos-15` 编译守护（验 build + 链接），**不执行**手势/动画/触觉/Toast/路由/像素重渲染等运行时行为。本矩阵汇总 6 份既有 per-anchor 运行时 runbook 为单一矩阵，经 §C fixture（`KLINE_SEED_FIXTURE=1`）在真 composition root 执行。

**用法**：照「前置」启动 app 后，逐行照「详细 runbook 指针」打开对应 per-anchor runbook 执行细节步骤，把 device 实测结果填进本表的「device pass/fail」列（留空 = 未跑）。本矩阵是顺位 13 正式关闭 + freeze tag 硬前提的**合取项 ①**（per outline §三.3 三连合取：① 本矩阵 + ② Wave 2 两 runbook + ③ Instruments 帧预算，见下方「关闭前其余硬门」节）；**仅**回填本矩阵不满足硬门，三者皆 device 实测回填后，Wave 3 方可正式关闭（见 `docs/governance/2026-06-14-wave3-completion.md` §二/§五）。

---

## 前置（关键）：经 §C fixture seed 启动可玩状态

1. 用 Xcode 打开 `ios/KlineTrainer/KlineTrainer.xcodeproj`，选 `KlineTrainer` app target + iPhone/iPad device 或 simulator（Debug config）。
2. 在 scheme：**Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**，新增一行 `KLINE_SEED_FIXTURE` = `1`。
3. 运行 app target。`#if DEBUG` 下读 env `KLINE_SEED_FIXTURE=1` → 经 §C fixture seed 在真 composition root 自动 provision：缓存训练组（全 6 周期）+ 历史记录 + pending（in-flight）+ 设置默认，使下列交互可达（机制见 `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift:19-27`）。
4. 首页应见非空历史 + 统计（非「空局」），可进一局 Normal 训练以观察图表交互。

**幂等 + 安全**：seed 仅在 store 全空时写（不破坏真实数据）；Release 二进制无 seed 代码（`#if DEBUG` 编译期排除）。若需重置 seed → 删 app 重装（`app.sqlite` 为 singleton，per §C reset 故事）。

---

## device happy-path 矩阵（7 项：6 数据交互 + 顺位 2 竖屏/窗口）

| 顺位 | 交互 | 经 §C fixture 可达性 | 详细 runbook 指针 | device pass/fail |
|---|---|---|---|---|
| 2 | 竖屏锁 + iPad 全屏窗口（Portrait lock / Split View / Stage Manager 不泄漏） | app 启动即可（不强依赖 seed 数据；iPad 多任务须 iPadOS 16+ Stage Manager device/sim） | `docs/runbooks/2026-06-10-wave3-orientation-runtime-acceptance.md` | ☐ |
| 3 | Pinch 缩放（聚焦 / clamp 20-240） | seed 缓存训练组（足够蜡烛可缩放）进一局 Normal | `docs/acceptance/2026-06-13-wave3-pr3-pinch-zoom.md` | ☐ |
| 4 | 水平线绘制 + 跨缩放还原 | 同上一局 Normal，开画线模式绘水平线后缩放 | `docs/acceptance/2026-06-13-wave3-pr4-drawing-mvp.md` | ☐ |
| 5 | 十字光标吸附 / HUD（跨周期 snap） | 同上一局 Normal，长按图表起十字光标 + 切周期 | `docs/acceptance/2026-06-13-wave3-pr5-crosshair-snap-hud.md` | ☐ |
| 7 | 手动强平 + 交易反馈（仓位 X/5 + Toast/触觉） | seed 缓存训练组进一局 Normal，建仓后手动强平 | `docs/runbooks/2026-06-13-wave3-pr7-trade-ui-runtime-acceptance.md` | ☐ |
| 8 | Replay 结算窗（不入账） | seed 历史记录 → 首页对一条记录选「再来一次」进 Replay 局 | `docs/runbooks/2026-06-13-wave3-pr8-replay-settlement-runtime-acceptance.md` | ☐ |
| 9 | 主题切换视觉（白天/夜间/跟随系统） | 设置面板「显示模式」分段选择器 + 已缓存训练组观察图表 | `docs/runbooks/2026-06-14-wave3-pr9-night-mode-runtime-acceptance.md` | ☐ |

---

## §C fixture 端到端附加行

| 端到端路径 | 经 §C fixture 可达性 | 步骤要点 | device pass/fail |
|---|---|---|---|
| save-resume | seed pending（in-flight） | 进一局 Normal 推几 tick → 杀 app → 重启 → 经 pending resume 恢复该局现场 | ☐ |
| 复盘（review） | seed 历史记录 | 首页对一条历史记录选「复盘」→ 进 Review 局回放既有 record | ☐ |
| replay（再来一次 + 结算） | seed 历史记录 | 首页对一条历史记录选「再来一次」→ 进 Replay 局 → 局终见结算窗（不入账，统计不变） | ☐ |

---

## 排除 / OPEN 节：bounce（顺位 11）= W3-11-R1 OPEN

**边缘 bounce（顺位 11）不列上方 device happy-path 矩阵**。顺位 11 acceptance（`docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md:1-3`）头部明文「**无实时可见运行时接线**（接线 deferred 为 residual `W3-11-R1`）」——真 app 屏幕**无可见回弹运行时**，组件层物理（`EdgeBounceModel` / `DecelerationModel` boundary-aware 推进 / `DecelerationAnimator` bounce 启动面）仅确定性单测闭合。

故 bounce **不**进 device 矩阵：device 验收无可肉眼观察的回弹对象（device 验收本身 BLOCKED 在 W3-11-R1 live 接线上）。`W3-11-R1` 标 **OPEN**，且它是 **Wave 3 功能完成门 + 正式关闭前提**（顺位 11 承诺交互未上线 → Wave 3 功能完整性 PENDING-W3-11-R1，codex review High）——**非**可无视的 fast-follow nice-to-have。解门 = 实现 live 接线（fast-follow 实施 PR）+ 回填本节 bounce 运行时 acceptance。本 runbook 据此排除出**上方 device 矩阵**而非列入（ledger 完整性见 `docs/governance/2026-06-14-wave3-completion.md` §二/§三/§五）。

> spec §E.2 把 bounce 列进运行时矩阵 = overclaim（真 app 看不到回弹）→ completion doc 如实纠正：W3-11-R1 OPEN + 矩阵不列 bounce device 行。**但排除 ≠ 抹账**：bounce 是承诺的 Wave 3 交互，W3-11-R1 升为功能完成/关闭门，Wave 3 功能完整性标 PENDING-W3-11-R1。不回改 spec，但 ledger 完整。

---

## §B toast 覆盖归属澄清

**autosave 失败 toast / 下载失败 toast 不在 device happy-path 矩阵**。§C seed 仅 provision **有效**数据（无 fault injection：不模拟磁盘满 / 不强制下载 reject），故 device happy-path 矩阵**无法**经 seeded 交互触发这两条 toast。

其自动化证明归 **§B host 测**（13a PR #108 的 Toast 测试）：注入 autosave 失败 → 断言信号字段置位 + toast 文案 = `userMessage` + session 不 teardown + endSession 后清零；下载 batch 部分 rejected → 断言失败原因 distinct userMessage 经 toast。**非** device 矩阵项（device happy-path seed 无 fault injection，无法触发）。

---

## 关闭前其余硬门（§三.3 同列，非本矩阵）

outline §三.3 的关闭/freeze 阻塞依赖是**三连合取**：①本 Wave 3 运行时矩阵（上表，经 §C fixture）+ **②Wave 2 两份 runbook device/sim 实测已记录 + ③Instruments 帧预算实测数值已回填**。本矩阵仅覆盖合取项 ①（Wave 3 新交互）；合取项 ②③ 由各自既有 runbook 承载、实测同样 pending——**跑完本矩阵 ≠ 满足硬门**，须连同下列一并回填：

| 合取项 | runbook 指针 | 内容 | device pass/fail |
|---|---|---|---|
| ② Wave 2 减速/帧预算 | `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md` | 惯性衰减 / 减速中点交易立停 / 帧 < 4ms / 后台前台无跳帧 | ☐ |
| ② Wave 2 手势 | `docs/runbooks/2026-06-07-u2-gesture-runtime-acceptance.md` | 单指 pan / 两指周期切换 / 长按十字光标 / 模式交易行为 / 局终自动 | ☐ |
| ③ Instruments 帧预算（顺位 12） | `docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md` | Instruments Time Profiler 录制各交互**单帧 `RenderStateBuilder.make` + `KLineView.draw(_:)` 合并峰值 < 4ms**（`____` ms 占位待回填）+ Equatable 短路验证 | ☐ |

> **§C seed（Debug）↔ 帧预算 runbook（Release）衔接 + 已知 fragility（codex review R5-Med / R6-High）**：§C fixture seed 是 **Debug-only**（`#if DEBUG`，Release 编译期剔除），而 Instruments 帧预算 runbook 要求 **Release（优化）包**（Debug 未优化虚高单帧耗时，不可用作 <4ms 判据）。**衔接路径**：①先以 Debug 包 + `KLINE_SEED_FIXTURE=1` 启动一次 seed，②**不删 app**，直接对同 bundle id 构建并 Profile（⌘I）**Release 包**——Release 不再 seed 但**读取**已 seed 的数据。
> **存储位置精确（R6-High 纠正前文「非 Caches-only」误述）**：`KlineTrainerApp.swift:16-17` 实际把 `app.sqlite`（history/pending/settings）放 **Application Support（持久）**，但**训练组缓存 `cacheRootDir` 放 `.cachesDirectory`（iOS 可单独清除！）**。
> **已知 fragility（OPEN 限制，关联 13b-R1）**：iOS 若在 Debug-seed 与 Release-profile 之间清除 Caches，则训练组缓存丢失、而 `app.sqlite` 的 history/pending/settings 仍在 → **全空 guard 拒绝重 seed**（非全空）、Release 又无 seed 代码 → Release run **无训练组数据**、帧预算落空局/错误路径。根治需把训练组缓存移 Application Support 或加 Release-兼容 provisioning（超 13c doc-only scope）。
> **强制 pre-profile 自检（R6-High）**：采集任何计时**前**，须先确认首页见非空缓存训练组 + 能进一局见蜡烛渲染（= 缓存未被清）。**若缓存已被清**（首页空局/无缓存）→ 删 app → Debug-seed → **立即**（不留 app 闲置）Release-profile 重试；仍不可达则该 device 帧预算 = **OPEN（未测）记录于回填表，禁以 Debug 虚高数值或空局假 PASS**。

---

## 回填说明

- device 跑完逐行填上方矩阵 + 端到端表 + 「关闭前其余硬门」表的 pass/fail。
- **关闭判据 = 全部 PASS，非「仅回填」（codex review R3-Med）**：顺位 13 正式关闭 + freeze tag 的硬前提 = 上述全部行（本 Wave 3 矩阵 ① + 端到端 + Wave 2 两份 runbook ② + Instruments 帧预算 ③）**每行显式 PASS**——**任一行留空 / 标 FAIL / 帧预算实测 ≥ 4ms = 关闭前提未满足**（记录到一个 FAIL = 运行时 build 已知坏，**禁**据此正式关闭/freeze）。**仅**跑完本矩阵 ① 不满足硬门；三连合取**全部 PASS** 后，Wave 3 方可从「功能交付确认」转「正式关闭」（见 `docs/governance/2026-06-14-wave3-completion.md` §二/§五）。
- W3-11-R1（bounce live 接线）+ 13a-R2（跨 lease cache data-loss）+ PR11-R1（生产 backendBaseURL）+ W1-R2（真实样本数据）= OPEN，不在本矩阵 device 验收范围（见 completion doc §三/§四）；其中 W3-11-R1 + 13a-R2 是关闭前须解的功能/缺陷门。
