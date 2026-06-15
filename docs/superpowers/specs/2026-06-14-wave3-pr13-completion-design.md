# Wave 3 顺位 13 收尾 + 10b-deferred（10c）落地 —— 设计文档

**前置**：Wave 3 顺位 1–12 全 merged（PR #92–#107；最后 10b 持久化集成 PR #107 `bcf32b1` merged 2026-06-14）。本设计文档规划 Wave 3 **最后一个 anchor（顺位 13 收尾）**，并吸收 PR #107（10b）显式 deferred 的 4 项残留（项目内部 label「10c」，非 outline anchor；见 `project_pr107_wave3_pr10b_merged.md` line 30 + outline §三.3 + §四）。

**为什么 10b-deferred 与顺位 13 同一工作流**：outline §三.3 把「顺位 13 收尾 + freeze tag」的阻塞依赖定义为 **Wave 3 全交互运行时矩阵的 device/sim 实测结果已记录**；而该矩阵「无法在真 app 跑」——需先交付 §C 全 app fixture provisioning。故 10b-deferred 的 fixture/smoke/边界/touch 必须**先于或并入**顺位 13（`project_pr107` line 30：「这 4 项须并入/先于顺位 13 收尾」）。

**完成 claim 边界（沿用 outline §三.3 / codex R1-F1）**：Wave 3 = **客户端 feature 完整 + 端到端 fixture 验证可玩**，**不**等于「可上架商店」。真实上架剩余门 = PR11-R1（生产 backendBaseURL）+ W1-R2（真实样本训练组数据，需 NAS）。本工作流**不** claim store-ready，收尾 doc 显式列此二门。

**抽象纪律**：沿用 outline / RFC「不内联 DDL / RGBA / 阈值常量」纪律——本设计为 source-of-truth 设计文档；具体测试 case 矩阵、文案字面、launch-arg 名、seed 数据形态细节由各 PR plan-stage 承担 + 自有评审闭环。

---

## 一、Scope（4 deferred 项 + 收尾）

| 项 | 来源 | 性质 | 归属 PR |
|---|---|---|---|
| **A. cache touch-on-use** | E6a-R3（`project_wave2_completion` §三；10b deferred #4）| 行为修正（read 路径 touch）| 13a |
| **B. 边界错误统一 Toast 层** | 10b deferred #3 + RFC §4.6 item 5 +「下载中断/磁盘满/解析失败/网络」可见性（outline §四 L204 / §三.3）| 新增可复用 UI 组件 + 接线现有静默错误 | 13a |
| **C. 全 app fixture provisioning** | 10b deferred #1 + codex R3-F2（outline §三.3 / §四 L209）| 新增 `#if DEBUG` seed 机制 | 13b |
| **D. 生产路径 E2E smoke** | 10b deferred #2 + codex R1-F1（outline §四 L210）| 新增/扩展真实栈集成测试 | 13b |
| **E. Wave 3 收尾** | 顺位 13（outline L68 / §三.3）| doc-only（completion + 矩阵 runbook + residual 回填 + freeze 决策）| 13c |

**OUT of scope**（明列，§六）：Phase 4 完整画线工具、NAS/部署（PR11-R1 + W1-R2）、iPad 横屏 layout、把现有 blocking alert 改造成 toast。

---

## 二、Baseline reconciliation（grep-first，核实 2026-06-14）

| 断言 | 证据 |
|---|---|
| `CacheManager.touch()` 已实现 + 已测，但 read 路径不调用 | `CacheManager.swift:6-12` 协议含 `touch(_:)`；`DefaultFileSystemCacheManager.swift:82-89,191-199` 实现 setAttributes mtime；`DefaultFileSystemCacheManagerTests.swift:88-103` 测 touch 改 LRU 序；`TrainingSessionCoordinator` 四处成功 `openReader` 点 **`:146`（`startNewNormalSession` 方法 :134）/ `:183`（`resumePending` :177）/ `:231`（`review` :225）/ `:268`（`replay` :262）** 后**无** `cache.touch` 调用（损坏分支 `cache.delete` 在 :148/:185/:233/:270）|
| 现有 toast = trade-specific 但呈现壳通用 | `TrainingView.swift:33-34`（`toastMessage:String?` + `toastToken`）/ `:141-151`（`.overlay(.top)` regularMaterial Capsule）/ `:230-238`（`presentToast` 2s latest-wins）；内容决策走 `TradeFeedback`（纯值） |
| `lastAutosaveError` 已存但从未 surface | `TrainingSessionCoordinator.swift:61` `public private(set) var lastAutosaveError: AppError?`；set on autosave catch（:84-87），clear on success/endSession/reset；RFC §4.6 item 5「失败可见」明指归本工作流 surface（`project_pr107` R2 Minor 已记延后） |
| 下载 per-item 失败原因被丢弃 | `SettingsPanel.swift:136-154` `startDownload`：仅 `downloadStatus = "完成：\(ok)/\(results.count) 成功"`；`[AcceptanceResult].rejected(AppError)` 的 reason **silently discarded**；仅 `reserveTrainingSets`/`runBatch` throw 才显 `userMessage` |
| `AppError` 已有 `userMessage`/`isRecoverable`/`shouldShowToast` | `AppError.swift:53-127`，全 case 中文文案就绪（`.diskFull`→"存储空间不足" 等）|
| 组合根 = `AppContainer.init(config:)`，无 debug seed / launch-arg hook | `AppContainer.swift`（建 `DefaultAPIClient`/`DefaultAppDB`/`DefaultFileSystemCacheManager`/`SettingsStore`/`DownloadAcceptanceRunner`/`TrainingSessionCoordinator`/`AppRouter`）；`KlineTrainerApp.swift:18` 硬编码 `http://kline-trainer.local`；无 `CommandLine`/`ProcessInfo` 解析 |
| HomeView 不拒启动，但无缓存→空局；矩阵需真数据 | `HomeView.swift:77-85` 空缓存仅弹 alert；`AppRouter.loadHome` `hasCached = !cache.listAvailable().isEmpty` |
| 真实栈集成测试已存在（download→confirm，无 availability 断言）| `DownloadAcceptanceRunnerIntegrationTests.swift:27-90` `run_realPipeline_happyPath_storesAndConfirms()` 用真 `DefaultFileSystemCacheManager`/`DefaultZipIntegrityVerifier`/`DefaultZipExtractor`/`DefaultTrainingSetDBFactory`/`DefaultDownloadAcceptanceCleaner` + `FakeAPIClient`；断言 confirmed + cache 有文件 + journal 序，**未**断言下游可消费 |
| baseline 绿 | `swift test` = **972 tests / 137 suites / 0 failures**（fresh run 2026-06-14，本 worktree origin/main `bcf32b1`，ios/ 与 `bcf32b1` 字节相同仅多本设计 doc）。注：PR #107 merge memory 记 962/135 = 当时较早快照；同代码 fresh run = 972/137，delta 为 measurement-snapshot 非代码差异 |

**结论**：4 项均为「机制在位、未接线 / 未交付测试 harness」类残留，非从零实现；行为面改动最小化。

---

## 三、PR 拆分与 DAG

3 PR，串行 merge（单一 required-check 管道；一锚 merge 其余 rebase onto main）：

```
13a (robustness)  ─┐
                   ├─→ 13c (收尾 doc：回填 13a+13b residual + 矩阵经 13b fixture 跑)
13b (test harness)─┘
```

- **13a ← origin/main**：cache touch-on-use（§A）+ 边界错误统一 Toast 层（§B）。2 子项 ≤3；预估 prod ~110–190 行。文件集 = `Contracts`/UI + Coordinator read 路径。
- **13b ← origin/main**（与 13a 文件不相交，但仍串行 merge）：fixture provisioning（§C）+ 生产路径 E2E smoke（§D）。2 子项；预估 prod ~150–250 行（多在 app target + `#if DEBUG`）+ 测试。
- **13c ← 13a + 13b merged**：doc-only 收尾（§E）。依赖二者 merged 以回填其 residual + 矩阵 runbook 引用 §C fixture。

**拆分理由**：①packaging（≤3 子项 / ≤500 prod 行）；②关注点正交（运行期健壮性 vs 测试 harness vs 治理 doc），各自独立可评审/可回滚；③DAG 清晰：13c 是真正的「收尾」，须在前两者落地后才能诚实回填 residual 终态。**若 13a/13b plan-stage 实测某项极小（如 §A ~10 行），planner 可酌情合并以减 PR 数，但不得使单 PR 超 ≤3 子项 / ≤500 prod 行。**

---

## 四、设计（逐项）

### §A cache touch-on-use（E6a-R3）— 13a

**意图**：LRU 缓存的「touch-on-use」= cached 训练组被**真实读取使用**时刷新其 last-accessed（mtime），使驱逐策略反映真实使用而非仅「最近下载」。基础设施已全在（`touch()` + mtime 驱逐 + 测试），唯缺 read 路径调用。

**改动**：`TrainingSessionCoordinator` 四处成功打开 cached reader 后调用 `cache.touch(file)`：
- `startNewNormalSession`（方法 :134）：`opened = (try openReader(for: file), file)`（:146）成功后 → `cache.touch(file)`（在 retry-on-corrupt while 循环内，仅成功分支）。
- `resumePending`（:177，openReader :183）/ `review`（:225，:231）/ `replay`（:262，:268）：`reader = try openReader(for: file)` 成功后 → `cache.touch(file)`。

**不变量 / 边界**：
- touch 是 best-effort（`touch(_:)` 协议无 throws，内部 `try?`），失败不影响会话开局——与现有契约一致。
- 仅在 `openReader` **成功**后 touch（损坏 → 走 `isCorruptTrainingSet` 删除分支，不 touch 一个将被删的文件）。
- `AppRouter.loadHome` 的 `cache.listAvailable()` 是**存在性检查**非「真实使用」→ **不** touch（避免每次回首页都刷新全部，扭曲 LRU）。

**测试**：注入 spy `CacheManager`（记录 `touch` 调用的 file id），断言：开局/恢复/复盘/replay 成功后恰 touch 对应 file 一次；损坏文件路径**不** touch（被 delete）。复用 `InMemoryCacheManager` 或扩 spy 包装。

**风险**：极低（additive 调用，已测的 touch 实现）。

---

### §B 边界错误统一 Toast 层 — 13a

**意图（RFC §4.6 item 5 +「下载中断/磁盘满/解析失败/网络」可见性，outline §四 L204 / §三.3）**：把当前**静默**的边界错误以**非阻塞**方式 surface，并统一非阻塞错误的呈现机制。

**B.1 抽出可复用 toast 组件 + host-testable 调度核**：把 `TrainingView` 内联 toast（`:141-151` 呈现 + `:230-238` latest-wins/2s 自动消失）抽为：
- **(i) 纯调度核（host-testable）**：把 latest-wins token + auto-dismiss 计时逻辑抽为一个**可注入时钟/调度器**的纯单元（如 `ToastScheduler`，沿用 coordinator 已有的 `now: () -> Int64` / `makeSessionKey` 依赖注入 pattern）——`present(message)` 递增 token，`dismiss(after:)` 经注入 scheduler 触发，断言「token latest-wins / 到期清空」可在 `swift test` host 真测（**取代原「snapshot 守护」空头承诺**——本仓无 snapshot infra，UI 壳仅 Catalyst compile-gated）。
- **(ii) SwiftUI 呈现壳**：content-agnostic view-modifier（如 `.errorToast(_ message: Binding<String?>)`），保留现行视觉（top / regularMaterial Capsule / 2s），仅 Catalyst compile-gated。
- `TrainingView` 的 trade toast **迁移到 (i)+(ii)**。「行为不变」由 (i) 的 host 测 + (ii) 的 Catalyst 编译守护（**不**声称 snapshot 守护）。

**B.2 接线 in-session autosave 失败（核心 RFC 义务）**：surface coordinator 的 autosave 失败为非阻塞 toast（`userMessage`，如 `.diskFull`→"存储空间不足"），**非阻塞、不 teardown**（与 finalize 失败 blocking alert 区分，RFC §4.6 item 5 / §4.7a）。两个 load-bearing 设计点（plan-stage **必须**坐实，非留白）：
- **(a) 可观察路径可行性**：`lastAutosaveError`（:61）是 `@ObservationIgnored`（10b 决议不参与渲染 diff）；且 `TrainingView` 不直接观察 coordinator——它持 `lifecycle`（`TrainingSessionLifecycle` 是**值类型 struct**，`:14`，内含 `let coordinator` :16）。故新增一个 **Observation-tracked user-facing 信号字段**（如 `autosaveErrorBanner: AppError?`，与内部 `lastAutosaveError` 解耦，仅作 UI 信号，置位不入 autosave 状态机）后，plan-stage **须证一条 working Observation 路径**：coordinator 字段 → 穿过值类型 lifecycle wrapper → 在 `TrainingView` body 被读取并触发 re-render（若值类型 wrapper 阻断 Observation，则改 wrapper 或直接观察 coordinator）。**不得**仅写「`.onChange` 轮询」而不证可行。
- **(b) clear-on-teardown（防 stale toast）**：新信号字段**必须**在 `endSession`（:405）与 `resetAutosaveState`（:510）随 `lastAutosaveError` 一同清零；否则局终 / 下一局开局复活旧错误 toast = UI resurrection bug。acceptance 加「endSession 后信号清零」断言。
- **不变量**：新字段为纯 UI 信号，与 10b autosave coalescing sync-repo 不变量 + 终态 fence（§4.7d）**解耦**——catch block 内同步置位无新挂起点，不破 coalescing/fence（plan-stage 复核）。

**B.3 接线下载 per-item 失败原因**：`SettingsPanel.startDownload`（:136-154）当前丢弃 `[AcceptanceResult].rejected(AppError)`。改：收集 distinct `rejected` 的 `userMessage`（dedupe，限前 N 条），经 §B.1 toast 组件呈现（如「N 个失败：训练组文件校验失败 / 网络超时」）。**保留**现有 `downloadStatus` 进度+aggregate 标签（"下载中…" / "完成：ok/total 成功"）——toast 补**失败原因可见性**，不替换进度 UX。

**边界错误类 → 处置映射（明确「统一」边界，供 §E.3 ledger 精确回填）**：outline §四 L204 残留枚举为「训练组损坏 / 下载中断 / 磁盘满 + 统一错误处理」。本工作流的「统一」= **统一复用 §B.1 非阻塞 toast 机制承载此前静默的 transient 错误**，blocking 错误保留正确的 blocking UX：

| 错误类（`AppError`）| 发生场景 | 处置 | 依据 |
|---|---|---|
| autosave 失败（`.persistence` diskFull/dbCorrupted/ioError）| in-session 周期保存 | **新 toast（§B.2）**| RFC §4.6 item5；此前静默 |
| 下载中断 / 网络（`.network` timeout/offline/serverError）| 下载验收 per-item | **新 toast（§B.3）**| outline §四；此前 reason 丢弃 |
| 磁盘满（`.persistence.diskFull`）下载时 | 下载验收 per-item | **新 toast（§B.3）**| outline §四；此前 reason 丢弃 |
| 解析失败 / 训练组损坏-下载时（`.trainingSet` crc/unzip/empty）| 下载验收 per-item | **新 toast（§B.3）**| outline §四；此前 reason 丢弃 |
| 训练组损坏-开局时（`startNewNormalSession`/`resumePending` 的 delete+retry）| 会话开局 | **保留现状（自动删+重试，silent）**；非 RFC 硬 surface 义务，倾向不加 toast（YAGNI；若 plan 认为值得则 additive 一条「已跳过损坏训练组」）| §4.7f：training-set 可弃 |
| app.sqlite 损坏（`.persistence.dbCorrupted` app 源）| 启动/恢复 | **保留 blocking**（`AppRouter.errorMessage` alert + §P6 fail-closed）；**禁**降级 toast | RFC §4.7f 安全红线 |
| finalize/back 失败 | 局终/退出 | **保留 blocking** retry/discard alert（`TrainingView:103-136`）| RFC §4.7a |
| home/nav-scope 其它（fileNotFound 等）| 启动/路由 | **保留** `AppRouter.errorMessage` blocking alert | 现状正确 UX |

§E.3 ledger 据此把残留标 CLOSED 时附注「'统一' = 新 toast 承载 transient（autosave + 下载 per-item）；blocking 错误故意保留 alert（surgical，不回归 §4.7f/§4.7a 安全语义）」，**不**声称单一 uniform handler 吞掉所有错误类。

**明确 OUT（保留现状 = 正确 blocking UX，不改造，见上表）**：`AppRouter.errorMessage` alert / finalize-back alert / app.sqlite fail-closed。

**测试**：①§B.1 (i) 调度核 host 测（latest-wins token / 注入 clock 到期清空）；②autosave 失败注入 → 信号字段置位 + toast 文案 = `userMessage` + session 不 teardown + **endSession 后信号清零**；③`shouldShowToast=false`（如 `.internalError`）不弹；④下载 batch 部分 rejected → 失败原因（distinct userMessage）经 toast + status 标签仍显 aggregate。content 决策抽纯值函数（如 `BoundaryErrorFeedback`，沿用 `TradeFeedback` 模式）便于 host 测。

**风险**：中——§B.2(a) 值类型 lifecycle 的 Observation 穿透是真难点（plan-stage 须证可行，不可留白）；§B.2(b) 漏 clear 即 stale toast。二者已升为 plan-stage 硬约束。

---

### §C 全 app fixture provisioning（debug-only seed）— 13b

**意图（codex R3-F2，outline §三.3）**：运行时矩阵须在**真 composition root** 跑（手动强平 / save-resume / 复盘 / replay 结算端到端验证），但真 app 硬编码 `.local` + 无数据资产 + 空缓存只能空局。故交付**确定性 debug-only seed**：经 `AppContainer` 注入 缓存 + pending + history，使矩阵可玩。

**机制**：
- **触发**：`#if DEBUG` only + 显式 opt-in（launch argument 或 env var，如 `-KLineSeedFixture` / `KLINE_SEED_FIXTURE`）。**Release 构建零影响**（编译期排除）。默认关闭——不污染正常 debug 启动。
- **注入点**：`AppContainer.init` 增 `#if DEBUG` 分支（或 `KlineTrainerApp.init` 读 launch-arg 决定是否 seed）：在构造完真实 `DefaultAppDB` + `DefaultFileSystemCacheManager` + `SettingsStore` 后，若 seed flag 开 **且 store 为空**（幂等：已 seed 不重复），写入确定性 fixture：
  - **cache**：经真 `DownloadAcceptanceRunner` 或直接 `cache.store(...)` 落 ≥1 个有效训练组 sqlite（复用 `TrainingSetSQLiteFixture` 思路；fixture 资产形态 plan 定）——使 `listAvailable()` 非空、可 `openReader`。
  - **history**：经 `RecordRepository.insertRecord`/`SessionFinalizationPort` 落 ≥1 条 `TrainingRecord`（+ ops/drawings）使 HomeView 历史/统计非空。
  - **pending**（可选 fixture 变体）：经 `PendingTrainingRepository.savePending` 落 1 条 in-flight 使「继续训练」路径可测。
  - **settings**：合理默认（capital 100k 等），若 store 已有则不覆写。
- **数据真实性**：seed 写入**真实 sqlite / 真实 cache 文件**（不是 in-memory fake）——矩阵经真 `DefaultAppDB`/`DefaultFileSystemCacheManager` 读，验证真路径。
- **fixture 生成代码须新写在 `#if DEBUG` Sources 位置（不可复用测试 target）**：现有 `TrainingSetSQLiteFixture`/`ZipFixture`/`CacheFixture` 仅在 `ios/Contracts/Tests/KlineTrainerPersistenceTests/`，**app / Sources target 无法 import**。故 §C 必须在一个 **Sources 目标的 `#if DEBUG` 块**（如 `KlineTrainerPersistence` 下 `#if DEBUG` 文件）**新写** seed 用的训练组 sqlite 生成 + cache/record/pending 落库代码——这是新增可 ship-target `.swift`（trust-boundary，见 §五），非「思路 reuse」。可参照测试 fixture 的写法但代码独立。
- **seed 数据集须 rich 到足以驱动 §E.2 全矩阵交互（stated acceptance criterion，非留白）**：现有测试 fixture 仅 2 根 m3 + 1 根 daily（maxTick≈1）——**不足以**测 pinch zoom/clamp、跨缩放画水平线、跨周期十字光标 snap、局中手动强平、save-resume、replay 结算。故 seed 数据集**必须**：多周期（≥m3+daily）、足够多蜡烛（可缩放 + 可推多 tick 至局终 + 有 ≥1 仓位可强平）、预计算指标（MA66/BOLL/MACD）就位。**「seed 足以端到端驱动 §E.2 每条交互」是 §C 的硬验收项**（§C 存在的全部理由），非 plan deferred 细节。
- **backend URL**：seed 模式下 backend 仍是 `.local`（不需要网络——数据已 seed 进缓存）。下载路径的真实性由 §D smoke 单独覆盖。

**不变量 / 安全**：
- `#if DEBUG` 编译期门 + 运行期 opt-in（launch-arg/env）双层——**Release 二进制零 seed 代码 + 零 fixture 资产引用**（SPM/archive Release build DEBUG 未定义 → 整块剔除）；CI Catalyst `build-for-testing`（Debug config）默认 opt-in 关，seed 不触发、不破坏正常 build（plan-stage 须实测 Catalyst 绿）。
- 幂等 + 不毁真实数据：seed 仅在 store **空**时写（防覆盖开发者真实 history/pending/settings）；写真 `app.sqlite`（`DefaultAppDB(dbPath:)`），**遵 §4.7f 禁自动删**——不删用户 app.sqlite。
- **reset 故事（明示）**：cache 可经独立 seed 目录隔离；但 `app.sqlite` 是 singleton（AppContainer 单 dbPath wiring），**无法**用「独立目录」并存。故 seed 进 app.sqlite 后，重置唯一途径 = **删 app 重装**（「仅 store 空时 seed」+ 删 app）——对 DEBUG-only 工具可接受，doc 注明。
- 确定性：固定 fixture（无随机），使矩阵可重复。

**测试**：seed builder 的纯逻辑（构造 fixture records/cache 描述 + 训练组蜡烛生成）host 可测；seed 注入端到端经真 `AppContainer`（DEBUG 测试）断言 seed 后 `cache.listAvailable()` 非空 + 训练组可 `openAndVerify` + `loadHome` 统计/历史非空 + pending 变体可恢复 + seed 数据集满足矩阵规模下限（蜡烛数/周期/可强平仓位）。

**风险**：中——①Release 隔离须 plan-stage 实测（grep Release 产物无 seed symbol / 或断言 `#if DEBUG` 包裹完整）；②rich seed 生成（含指标）是真实工作量，非 trivial；③seed 默认关须不破 Catalyst CI。

---

### §D 生产路径 E2E smoke — 13b

**意图（codex R1-F1，outline §四 L210）**：走**真实 `DownloadAcceptanceRunner` 代码路径**的 fixture E2E（下载→确认→**训练组可用**），无真实网络。现有集成测试（`DownloadAcceptanceRunnerIntegrationTests:27-90`）已覆盖 download→confirm→cache 落盘+journal 序，但**未断言下游可用**（训练组真能被会话打开消费）。

**改动**：扩展（或新增并列）一个真实栈 smoke：
- 真组件：`DefaultFileSystemCacheManager`（temp root）/ `DefaultZipIntegrityVerifier` / `DefaultZipExtractor` / `DefaultTrainingSetDBFactory` / `DefaultDownloadAcceptanceCleaner` + `FakeAPIClient`（feed fixture zip，无网络）+ journal（`InMemoryAcceptanceJournalDAO` 或真 `DefaultAppDB`）。
- 链：`runBatch`/`run` → `.confirmed(file)` → **断言 `cache.listAvailable()` 含该 file** → **真 `DefaultTrainingSetDBFactory.openAndVerify(file)` 成功**（证「训练组可用」= 下游可消费，而非仅落盘）。可选再断言经 coordinator `startNewNormalSession` 能基于该 seed 开局（若不引入循环依赖）。
- fixture：复用 `TrainingSetSQLiteFixture.make()` + `ZipFixture.makeMinimalSqliteZip()`（真 CRC32）。

**与 §C 的关系**：§C seed 是「跳过下载、直接 provision」给运行时矩阵用；§D smoke 是「真实下载验收路径」的自动化覆盖。二者互补——§D 证下载链真能产出可用训练组，§C 用 seed 让矩阵免依赖网络。

**测试**：smoke 本身即测试（test-only，0 prod 行）。断言 download→verify→commit→**available→openable** 全链 + journal 终态 confirmed + temp 清理 + reader close 序。

**风险**：低（test-only；复用现有 fixture + 真组件已被集成测试验证）。

---

### §E Wave 3 收尾（13c, doc-only）

**E.1 收尾 doc（`docs/governance/2026-06-14-wave3-completion.md`，沿用 `2026-06-09-wave2-completion.md` 结构）**：

**关键 reconcile（outline §3.3 硬门 vs 本 doc 的诚实范围，解 spec-review R1-High）**：outline §三.3 / L181 把「Wave 3 全交互运行时矩阵的 device/sim **实测结果已记录**」定为**顺位 13 收尾本身**的硬前提（原文「其**完成是 Wave 3 关闭的硬前提，非「某天再说」**」），不仅是 freeze tag 的前提。本工作流交付矩阵 **runbook + fixture provisioning**（使其可执行），但**不代跑 device/sim 实测**（用户职责）。故 13c merge 时该硬门**未满足** → **13c 不得 claim Wave 3 已正式「关闭」**。

处置（reframe，不静默改写 outline）：
- 本 doc 标题/定位 = **「Wave 3 功能交付确认 + 运行时验收待回填」**，**非**「Wave 3 正式关闭」。明列：13c 交付后 Wave 3 处于「功能完整 + fixture 可玩 + 运行时验收 runbook 就绪、device 实测待用户回填」状态；**正式关闭** = 用户跑完 §E.2 矩阵并记录结果后（届时若需冻结，走 §E.4 tag）。
- 显式引用 + 承认 outline §3.3 该硬门，说明本 doc 为何**不**僭越宣布 closure（诚实，对齐 codex R1-F1）。Wave 1/2 先例（均未跑 device runbook 仍记「completion」）作为「功能交付确认」语义的旁证，但**不**用以推翻 outline §3.3 「非某天再说」的更严表述——本 doc 用「待回填」如实表达。
- Wave 3 全 anchor 落地清单（PR #92–#107 + 13a/13b/13c）+ squash SHA。
- **诚实 claim（codex R1-F1）**：「客户端 feature 完整 + fixture 端到端可玩」，**非** store-ready、**非** 已正式关闭（运行时实测待回填）。
- **未完成 ship 门显式列**：PR11-R1（生产 backendBaseURL）+ W1-R2（真实样本训练组数据，H7，需 NAS）——不计入 Wave 3 功能完成度，且为正式上架前提。

**E.2 运行时矩阵 runbook**（`docs/acceptance/` 或 governance）：列 Wave 3 全新交互的 device/sim 验收步骤（非-coder 可执行），覆盖经 §C fixture seed 可达的 **happy-path** 交互：pinch 聚焦/clamp（顺位 3）、水平线绘制+跨缩放还原（4）、十字光标 snap/HUD（5）、手动强平（7）、replay 结算窗（8）、主题切换视觉（9）、边缘 bounce（11）、**+ 经 §C fixture seed 的 save-resume / 复盘 / replay 端到端**。
- 各交互的运行时 runbook 条目此前已随锚交付（outline §三.3）；本 doc **汇总成单一矩阵** + 标注「经 §C fixture 执行」。
- **§B toast 可见性（autosave 失败 / 下载失败）的覆盖归属澄清（spec-review R2-Med）**：§C seed 仅 provision **有效**数据（无 fault injection：不模拟磁盘满 / 不强制下载 reject），故 device 矩阵**无法**经 happy-path seed 触发这两条 toast。其**自动化证明归 §B host 测**（test 项 ②/④，注入失败 → 断言 toast 文案/不 teardown），**非** device 矩阵。device 矩阵仅验 happy-path seeded 交互；§B toast 由 §B host 测覆盖（除非 13b plan 选择性加 debug fault-injection 开关，则可纳入矩阵——属 plan-stage 可选）。
- **device/sim 实测结果回填 = 用户 device 职责**；runbook 提供步骤 + 结果记录表格（待填）。

**E.3 residual 终态回填**：更新 residual ledger（`project_wave2_completion` §三 / outline §四 风格）——A/B/C/D 四项从 DEFERRED → CLOSED（引 13a/13b PR）；运行时矩阵 = PARTIAL（runbook 交付，device 实测待用户）；PR11-R1 + W1-R2 = OPEN（NAS）。

**E.4 freeze tag 决策**：
- outline §3.3 / L185：freeze tag 阻塞依赖 = **运行时矩阵 device/sim 结果已记录**；语义 = 冻结客户端功能完整性（非 store-ship）。**与 §E.1 一致**：recorded 矩阵同时是「顺位 13 正式关闭」与「freeze tag」的共同硬前提——二者都在用户回填矩阵后才发生。
- 本工作流交付矩阵 runbook 但**不执行 device 实测**（用户职责）→ tag（及正式关闭）的硬前提（recorded 结果）在 13c merge 时**未满足**。
- **决策（推荐）**：13c **不打 freeze tag**，沿用 Wave 1/2 轻量收尾先例（`project_wave1_completion`：未打 tag）。completion doc 记「freeze 决策 = deferred-pending-recorded-matrix」：用户在 device 跑完矩阵并记录后，若希望冻结功能完整性，可走独立 tag ceremony（轻流程）。**理由**：①诚实——无 recorded 矩阵不满足 outline 硬门；②ship 门（PR11-R1/W1-R2）未关，store-frozen 语义不成立；③与前两 wave 一致。
- 此为 product/governance 决策；按用户「尽可能不要找我」自主裁决为「不打 tag + 文档化 deferred + 推荐」。若用户事后希望打 tag，属 follow-up，不阻塞 Wave 3 功能完成。

**风险**：低（doc-only）。13c 须经 codex 对抗 review（治理 doc 类）。

---

## 五、测试与验收策略

- **TDD**：13a §A/§B、13b §C/§D 均先写测试（§A spy-touch、§B toast/feedback 逻辑 + 注入失败、§C seed 端到端、§D 真实栈 smoke）再实现。
- **host 优先**：纯逻辑（toast 内容决策 `BoundaryErrorFeedback`、seed fixture builder、touch spy）走 `swift test` host；UI 壳最小化。
- **评审通道（trust-boundary，必须）**：§A/§B（13a）+ §C/§D（13b）均改 `ios/**/*.swift`（coordinator / TrainingView / SettingsPanel / AppContainer / 可能 app target），命中 `.claude/workflow-rules.json` `trust_boundary_globs`（`ios/**/*.swift` / `**/project.pbxproj` / `**/*.xcassets/**`）+ CLAUDE.md backstop #1 → **13a 与 13b 均须经 `codex:adversarial-review`**（唯一 review 通道）；codex 周配额耗尽时方 fallback opus 4.8 xhigh（documented，沿用 Wave 1/2 各 anchor 先例）。13c（doc-only）亦经 codex 对抗 review（治理 doc 类）。
- **Catalyst CI**：13a/13b 触 `Mac Catalyst build-for-testing on macos-15` required check（本地绿≠CI 绿，per `feedback_swift_local_toolchain_blindspot`）+ app-build（顺位 2 守护，若改 app target）。
- **非-coder acceptance checklist**（每 PR 必交，CLAUDE.md governance §2；action/expected/pass-fail；中文；禁用语见 `.claude/workflow-rules.json`）。13c 额外交运行时矩阵 runbook（本身即 device acceptance）。
- **grep gate**（13c）：断言 residual ledger A/B/C/D 标 CLOSED + ship 门 PR11-R1/W1-R2 标 OPEN + completion doc 无「store-ready / 可上架」误 claim。

---

## 六、OUT of scope（明列）

- **不改造现有 blocking alert → toast**（`AppRouter.errorMessage` / finalize/back / app.sqlite fail-closed P6）——blocking 是正确 UX，改造 = 行为回归 + 违 §3 surgical。
- **Phase 4 完整 6 种画线工具**、**iPad 横屏 layout 功能**——非 Wave 3。
- **NAS / 部署**：PR11-R1（生产 endpoint）+ W1-R2（真实样本数据）——收尾 doc 列为未完成 ship 门，不实施。
- **不执行 device/sim 运行时矩阵实测**（用户职责）——本工作流交付可执行 runbook + fixture provisioning，不代跑。
- **不强制打 freeze tag**（见 §E.4）。

---

## 七、风险与开放点

1. **§B `lastAutosaveError` 可观察化**：须不破 10b 的 `@ObservationIgnored` + autosave coalescing sync-repo 不变量。plan-stage 证解耦（新 UI 信号字段 vs 复用内部状态）。
2. **§C Release 隔离**：`#if DEBUG` 严格包裹 seed + fixture 资产，CI build 默认关；plan-stage 证 Release 二进制零 seed 代码。
3. **packaging**：13a/13b 各 ≤3 子项 / ≤500 prod 行；plan-stage 实测超则再拆（§A 极小可与 §B 合并仍计 2 子项）。
4. **freeze tag**：自主裁决「不打 + 文档 deferred」（§E.4）；若用户偏好不同，属 13c review 可调（doc-only，低成本改）。

---

## 八、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-14 | v1 (draft) | 起草；4 deferred 项（A touch-on-use / B 统一 Toast / C fixture provisioning / D E2E smoke）+ E 顺位 13 收尾；3-PR 拆分（13a robustness / 13b harness / 13c 收尾 doc）；grep-first baseline 核实（972 tests 绿）；freeze tag = 自主裁决不打 + 文档 deferred-pending-matrix |
| 2026-06-14 | v2 (opus 4.8 xhigh 对抗 review R1 修) | 全 9 finding 应用：**High**——§E 不再 claim Wave 3 正式关闭（outline §3.3「recorded 矩阵」是顺位 13 收尾本身硬门，未满足）→ reframe「功能交付确认 + 运行时验收待回填」+ 显式 reconcile outline §3.3，正式关闭 + tag 均 post-matrix。**Med**：§C 明确 fixture 生成须新写 `#if DEBUG` Sources（测试 target 不可 import）+ seed 数据集 rich 到驱动全 §E.2 矩阵作硬验收项 + reset 故事（app.sqlite singleton 删 app 重置）；§B.1 latest-wins/auto-dismiss 抽 host-testable 注入时钟调度核（取代空头 snapshot 守护）；§B.2 升 plan-stage 硬约束（值类型 lifecycle 的 Observation 穿透须证可行 + 新信号字段须在 endSession:405/resetAutosaveState:510 清零防 stale toast）；§B 加边界错误类→处置映射表（明确「统一」= transient 走新 toast、blocking 保留 alert）；§五 加 13a/13b trust-boundary（`ios/**/*.swift`）须经 codex:adversarial-review。**Low**：baseline 972 vs PR#107 962 = snapshot delta 注；§A/§二 line 号校正（openReader :146/:183/:231/:268）|
| 2026-06-14 | v2.1 (opus 4.8 xhigh 对抗 review R2 = APPROVE) | R2 复核 R1 全 9 finding RESOLVED + 无 Critical/High。折入 R2 新 1 Med：§E.2 澄清 §C happy-path seed 无 fault-injection → autosave/下载失败 toast 的覆盖归 §B host 测（注入失败），非 device 矩阵（device 矩阵仅 happy-path seeded 交互）。carry 到 plan-stage 的 1 Low（disposition 表 row1 autosave `.dbCorrupted` toast 文案「本地数据损坏」措辞精炼，不违 §4.7f——§4.7f 管 app.sqlite *读/恢复*，§4.6-item5 管 autosave *写* 不 teardown）。**spec 收敛。** |
