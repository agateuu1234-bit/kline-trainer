# Wave 2 顺位 11 — 生产组合根 + 路由接线 + 启动恢复（设计 v1）

**Anchor**：Wave 2 outline（`docs/superpowers/specs/2026-06-02-wave2-outline-design.md`）顺位 11 / 末位。
**目的**：替换模板 `KlineTrainerApp.swift`/`ContentView.swift`，构造并接线生产依赖图（`DefaultAppDB`/`SettingsStore`/E6 coordinator/P2 runner），把 U1 HomeView → U2 TrainingView（start/continue/review/replay）+ gear → U4 SettingsPanel 的导航意图接成可达闭环，并在启动时跑一次 `retryPendingConfirmations()` 孤儿确认恢复。

**依赖（均已 merged）**：U1 HomeView（PR #89）、U2 TrainingView + E6 生命周期（PR #88）、U4 SettingsPanel（PR #85）、E6a/E6b coordinator（PR #83/#86）、P2 runner（PR #82）、E5a/E5b engine（PR #80/#81）、P4 DefaultAppDB（Wave 0）、P1 DefaultAPIClient（Wave 1 PR #59）、P5 cache + P6 SettingsStore（Wave 0）。

---

## 〇、baseline 核实（grep-first，§五 step 3）

实测代码状态（非仅读 spec checklist）：

| 事实 | 证据 |
|---|---|
| app entry 仍是模板 Hello World | `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift`（@main → `ContentView()`）+ `ContentView.swift`（VStack globe/"Hello, world!"） |
| app target **未**依赖 SPM 包 | `KlineTrainer.xcodeproj/project.pbxproj` 仅 `XCRemoteSwiftPackageReference "GRDB"`，无 `KlineTrainerContracts`/`KlineTrainerPersistence` product 依赖 |
| 模块依赖单向 | `Package.swift`：`KlineTrainerPersistence` → 依赖 `KlineTrainerContracts`（L21-22）。Contracts **不可** import Persistence（会循环） |
| 具体 `Default*` 类型只在 Persistence | `DefaultAppDB`/`DefaultAPIClient`/`DefaultFileSystemCacheManager`/`DefaultTrainingSetDBFactory`/`DefaultZipExtractor`/`DefaultZipIntegrityVerifier`/`DefaultDownloadAcceptanceCleaner` 全在 `Sources/KlineTrainerPersistence/` |
| 抽象端口 + runner + coordinator + views 在 Contracts | `DownloadAcceptanceRunner`、`TrainingSessionCoordinator`、`SettingsStore`、`HomeView`/`TrainingView`/`SettingsPanel`/`SettlementView`/`HistoryActionSheet` 全在 `Sources/KlineTrainerContracts/` |
| Catalyst CI 只 build Contracts scheme | `.github/workflows/catalyst-build.yml`：`xcodebuild build-for-testing -scheme KlineTrainerContracts`（job `Mac Catalyst build-for-testing on macos-15`）。**不 build app target** |
| swift test 覆盖两个包 | `.github/workflows/swift-contracts-smoke.yml`：`cd ios/Contracts && swift test`（job `swift test on macos-15`），含 Persistence 目标 |
| 全仓**无**生产 backend baseURL 常量 | grep 仅命中 `DefaultAPIClient(baseURL:)` 形参 + 训练集文件 `localURL`（无关）。生产 URL 未定义（NAS 部署归 Wave 2 scope 外，outline §六） |
| 结算路由是顺位 11 职责 | `TrainingView.swift` D2 注释「不呈现 SettlementView（顺位 11 路由+repo owner 负责）；finalizeForSettlement 仅返 recordId? 上交」；`TrainingSessionLifecycle` 暴露 `back()/finalizeForSettlement()/endAfterSettlement()` |

---

## 一、各依赖的真实公共 API（构造面）

| 组件 | 模块 | 构造 | 备注 |
|---|---|---|---|
| `DefaultAPIClient` | Persistence | `init(baseURL: URL, transport: HTTPRequesting = URLSession.shared)`（actor） | 非 throws；方法 async throws |
| `DefaultAppDB` | Persistence | `init(dbPath: URL) throws`（class） | **构造同步跑 migration，可 throw**（`.ioError`/`.diskFull`）；满足 `AppDB = RecordRepository & PendingTrainingRepository & SettingsDAO & AcceptanceJournalDAO` |
| `DefaultFileSystemCacheManager` | Persistence | （需核实 init 形参，预计 `init(rootDir: URL)`） | 满足 `CacheManager` |
| `DefaultTrainingSetDBFactory` | Persistence | （需核实） | 满足 `TrainingSetDBFactory` |
| 4× P2 default 端口 | Persistence | `DefaultZipIntegrityVerifier`/`DefaultZipExtractor`/`DefaultTrainingSetDataVerifier?`/`DefaultDownloadAcceptanceCleaner`（需核实各 init） | runner 的 integrity/extractor/dataVerifier/cleaner |
| `SettingsStore` | Contracts | `init(settingsDAO: SettingsDAO)`（@MainActor @Observable，**非 throws**，init 内 eager load，失败置 loadError 降级 zeroDefault） | |
| `DownloadAcceptanceRunner` | Contracts | `init(api:cache:dbFactory:journal:integrity:extractor:dataVerifier:cleaner:)`（final Sendable，非 throws）；`run/runBatch/retryPendingConfirmations() async` | retryPendingConfirmations 无 throw |
| `TrainingSessionCoordinator` | Contracts | `init(dbFactory:recordRepo:pendingRepo:settingsDAO:cache:settings:)`（@MainActor @Observable，非 throws）；`startNewNormalSession/resumePending/review/replay async throws` + `saveProgress/finalize/endSession` | |

**视图公共 init（路由消费面）**：
- `HomeView(content: HomeContent, onStartTraining:, onContinueTraining:, onSelectRecord: (Int64)->Void, onOpenSettings:)`（view-only 壳，吃预建 HomeContent）
- `HomeContent(statistics:(totalCount:winCount:currentCapital:), configuredCapital:, records:[TrainingRecord], hasPending:, hasCachedSets:, timeZone: = .current)`
- `TrainingView(lifecycle: TrainingSessionLifecycle, onExit:, onSessionEnded: (Int64?)->Void)`
- `TrainingSessionLifecycle(engine:coordinator:)`（@MainActor struct；`back()/finalizeForSettlement()->Int64?/endAfterSettlement()`）
- `SettingsPanel(settings: SettingsStore, api: any APIClient, cache: any CacheManager, acceptance: DownloadAcceptanceRunner)`
- `SettlementView(record: TrainingRecord, onConfirm:)`
- `HistoryActionSheet(record: TrainingRecord, onReview:, onReplay:, onCancel:)`

**HomeContent 数据来源**（顺位 11 负责装配，U1 PR #89 已把 HomeContent 定为纯值）：
- statistics + records ← `RecordRepository.statistics()` + `listRecords(limit:)`
- configuredCapital ← `SettingsStore.settings.totalCapital`
- hasPending ← `PendingTrainingRepository.loadPending() != nil`
- hasCachedSets ← `CacheManager.listAvailable().isEmpty == false`

---

## 二、架构：三层分布（沿用本仓 Content/shell 纪律，提升到 app 层）

```
┌─ xcodeproj app target（薄壳，CI 不构建 → 本地 xcodebuild + 手动运行时验收）
│   KlineTrainerApp.swift   @main；造 AppConfig(生产路径+baseURL placeholder) → try AppContainer → AppRootView(router:settings:api:cache:acceptance:)
│                            DB 打开失败 → 渲染 fatal 错误视图（不 crash）；启动跑一次 retryPendingConfirmations
│   （删 ContentView.swift 模板）
│   project.pbxproj          加本地 SPM 包引用 ios/Contracts + link 两个 product
│
├─ KlineTrainerContracts（host-test router + Catalyst-build view；只依赖抽象端口）
│   AppRouter            @MainActor @Observable 导航状态机（host 全测，复用已有 in-memory fakes）
│   AppRootView          SwiftUI 壳：NavigationStack(home→training) + sheets(settings/history/settlement)
│
└─ KlineTrainerPersistence（具体依赖图工厂；swift test host 覆盖）
    AppContainer         init(config: AppConfig) throws：按序造 9 个具体依赖，暴露给 router/views
    AppConfig            纯值：dbPath / cacheRootDir / backendBaseURL
```

**为什么这样分**：`AppContainer` 必须引用 Persistence 的 `Default*` 具体类型 → 只能落 Persistence（Contracts 不可 import Persistence）。`AppRouter`/`AppRootView` 只依赖抽象端口（coordinator/settings/acceptance/api/cache/repos）→ 落 Contracts，可被 host 测 + 复用 PR #45/#46 的 `InMemory*`/`Fake*` fakes，且被 Catalyst CI 编译守护。app entry 是不可消除的 `@main` 边界，落 xcodeproj。

**CI 覆盖矩阵**：
- `AppRouter`（路由逻辑，风险最高）→ `swift test`（host）**+** Catalyst build（在 Contracts 里）。
- `AppRootView`（SwiftUI 壳）→ Catalyst build（`#if canImport(UIKit)` 门，host 不编译，同 TrainingView 范式）。
- `AppContainer`（纯构造逻辑，无 UIKit）→ `swift test`（host，PersistenceTests）。**注**：与既有 `DefaultAppDB` 同覆盖档（Persistence 历来 host-test，非 Catalyst-build）。
- `KlineTrainerApp.swift` + pbxproj → **无 CI**（已知 gap，见 §七）→ 本地 `xcodebuild` app scheme + 手动运行时验收兜底。

---

## 三、考虑过的方案

**方案 A（推荐）：组合根 + 路由 + 根视图全进 SPM 包，app entry 薄壳。**
- AppContainer→Persistence，AppRouter+AppRootView→Contracts，KlineTrainerApp 薄壳渲染 `AppRootView(container:)`。
- 优点：路由/构造逻辑全部 host-test + Catalyst 覆盖；app entry 退化为 ~30-40 行不可测边界，最小化 CI 盲区；完全沿用本仓 Content/shell 纪律。
- 缺点：必须改 pbxproj 加本地包依赖（finicky，CI 不验）→ 用本地 `xcodebuild` 兜。

**方案 B：组合根 + 路由全写进 xcodeproj app target。**
- 优点：无需 pbxproj 加包依赖以外的拆分；概念上「组合根属于 app」。
- 缺点：路由逻辑（最高风险）完全逃逸 CI + host-test；违反本仓「逻辑进包、壳留薄」纪律。**否决**。

**方案 C：拆 11a（AppContainer + 图实例化测试）/ 11b（AppRouter + AppRootView + app entry + 启动恢复）。**
- 仅当方案 A 的生产代码实测 > 500 行时启用（outline 顺位 11 预授权拆「组合根+依赖图」与「路由+启动恢复」）。
- 预估：AppContainer ~80 + AppRouter ~220 + AppRootView ~150 + entry ~40 ≈ 490 行（不含测试），**临界**。plan 阶段实测 > 500 即按 C 拆，否则单 PR。

---

## 四、组件设计

### 4.1 `AppConfig`（Persistence，纯值）
```swift
public struct AppConfig: Sendable {
    public let dbPath: URL          // app.sqlite 绝对路径（生产 = App Support dir）
    public let cacheRootDir: URL    // 训练集缓存根（生产 = Caches dir）
    public let backendBaseURL: URL  // P1 API base（生产 = NAS 部署后填；本 PR placeholder）
    public init(dbPath:cacheRootDir:backendBaseURL:)
}
```
**生产 placeholder 决策**：后端 NAS 部署在 Wave 2 scope 外（outline §六：W1-R1/R2）。app entry 提供一个**显式标注的 placeholder** `backendBaseURL`（如 `http://kline-trainer.local`，附 `// TODO(NAS): 部署后替换` 注释 + 列为本 PR residual PR11-R1）。依赖图照常实例化（顺位 11 验收要求「依赖图实例化」），仅 download/reserve 真实网络路径在 NAS 上线前不通——该路径本就 out-of-scope。

### 4.2 `AppContainer`（Persistence，组合根）
```swift
public final class AppContainer {
    public let api: any APIClient
    public let db: any AppDB                       // typealias 合成 4 协议
    public let cache: any CacheManager
    public let settings: SettingsStore             // @MainActor
    public let acceptance: DownloadAcceptanceRunner
    public let coordinator: TrainingSessionCoordinator  // @MainActor
    public let router: AppRouter                   // @MainActor；Persistence 可 import Contracts → 在此构造预建 router

    @MainActor public init(config: AppConfig) throws
}
```
**为何 AppContainer 暴露 router**：`AppRootView`（Contracts）**不能**接 `AppContainer`（Persistence）类型（Contracts 不可 import Persistence）。故 AppContainer 在 Persistence 侧把 `db`(=recordRepo/pendingRepo) 接进 `AppRouter` 并暴露；app entry（可 import 两包）取 `container.router`/`container.api`/… 喂 `AppRootView`。
**构造顺序**（依赖拓扑）：
1. `api = DefaultAPIClient(baseURL: config.backendBaseURL)`
2. `db = try DefaultAppDB(dbPath: config.dbPath)` ← **唯一 throws 点**（migration/IO）；失败则整图无法构造 → 上抛，app entry 渲染错误视图
3. `cache = DefaultFileSystemCacheManager(rootDir: config.cacheRootDir)`
4. 4× P2 default 端口 + `dbFactory = DefaultTrainingSetDBFactory(...)`
5. `settings = SettingsStore(settingsDAO: db)`（db 同时是 SettingsDAO；非 throws，内部降级 loadError）
6. `acceptance = DownloadAcceptanceRunner(api:cache:dbFactory:journal:db, integrity:..., ...)`（journal = db）
7. `coordinator = TrainingSessionCoordinator(dbFactory:recordRepo:db, pendingRepo:db, settingsDAO:db, cache:settings:)`

`@MainActor init`：因构造 `SettingsStore`/`TrainingSessionCoordinator`（@MainActor）。**host 测**：用临时目录真 `DefaultAppDB`（GRDB 支持文件/内存）验证 `try AppContainer(config:)` 不抛 + 7 个依赖非 nil；DB 路径不可写 → init 抛。

### 4.3 `AppRouter`（Contracts，导航状态机，@MainActor @Observable）
**依赖注入**（全抽象端口，便于 host 测注 fakes）：
```swift
@MainActor @Observable
public final class AppRouter {
    public init(coordinator: TrainingSessionCoordinator,
                settings: SettingsStore,
                acceptance: DownloadAcceptanceRunner,
                recordRepo: any RecordRepository,
                pendingRepo: any PendingTrainingRepository,
                cache: any CacheManager)
}
```
（api 不入 router——SettingsPanel 直接吃 container.api；router 只管导航 + home 数据 + 会话构造。）

**导航状态**：
```swift
public enum Route: Equatable { case home }   // home 常驻根；training 用 NavigationStack path
public enum Modal: Identifiable, Equatable {  // 互斥 sheet
    case settings
    case history(recordId: Int64)
    case settlement(SettlementPayload)        // 见 4.5
}
@MainActor 状态：
  var homeContent: HomeContent?               // loadHome 后填
  var trainingPath: [TrainingDestination]     // NavigationStack 绑定（≤1 项）
  var activeModal: Modal?
  var errorMessage: String?                   // 转换失败 → alert
  private var didRunLaunchRecovery = false
```

**意图方法**（async，捕获 coordinator throws → errorMessage，不 crash）：
| 入口 | 行为 |
|---|---|
| `runLaunchRecovery()` | 幂等门 `didRunLaunchRecovery`；`await acceptance.retryPendingConfirmations()`；然后 `await loadHome()` |
| `loadHome()` | 从 recordRepo.statistics/listRecords + settings + pendingRepo + cache 装配 `HomeContent`；读失败 → errorMessage + 空 HomeContent |
| `startTraining()` | `engine = try await coordinator.startNewNormalSession()` → push `TrainingDestination(lifecycle:)`；throw → errorMessage（如 loadError/无缓存集） |
| `continueTraining()` | `if let e = try await coordinator.resumePending() { push }`，nil → 忽略（或刷新 home） |
| `selectRecord(id)` | `activeModal = .history(id)`（壳据 id 从 records 取 record 建 sheet） |
| `review(id)` | dismiss modal → `engine = try await coordinator.review(recordId:)` → push training |
| `replay(id)` | dismiss modal → `engine = try await coordinator.replay(recordId:)` → push training |
| `openSettings()` | `activeModal = .settings` |
| `exitTraining()` | pop trainingPath → `await loadHome()`（records 可能变） |
| `sessionEnded(recordId:)` | 见 4.5 结算路由 |
| `confirmSettlement()` | `await lifecycle.endAfterSettlement()` → dismiss → pop → `await loadHome()` |

**TrainingDestination**：持 `TrainingSessionLifecycle`（engine+coordinator）+ mode，供 AppRootView push `TrainingView`。

### 4.4 `AppRootView`（Contracts，SwiftUI 薄壳，`#if canImport(UIKit)`）
**init**：`init(router: AppRouter, settings: SettingsStore, api: any APIClient, cache: any CacheManager, acceptance: DownloadAcceptanceRunner)`——只吃 Contracts 抽象（**不**吃 `AppContainer`，避免 Contracts 依赖 Persistence）。settings/api/cache/acceptance 仅为构造 `SettingsPanel` 透传；其余路由全经 router。
- `NavigationStack(path: $router.trainingPath)`：根 = `HomeView(content: router.homeContent ?? .empty, onStartTraining: { Task{ await router.startTraining() }}, …)`；`.navigationDestination(for: TrainingDestination.self) { TrainingView(lifecycle:onExit:onSessionEnded:) }`。
- `.sheet(item: $router.activeModal)`：`.settings` → `SettingsPanel(...)`；`.history(id)` → 取 record → `HistoryActionSheet(onReview/onReplay/onCancel)`；`.settlement(payload)` → `SettlementView(record:onConfirm:)`。
- `.alert(router.errorMessage)`、`.task { await router.runLaunchRecovery() }`（幂等门保证仅一次）、`.onAppear`/return 后 `loadHome`。
- **不含路由逻辑**——全部 delegate router 方法（壳仅绑定 + 渲染，同 TrainingView 范式）。

### 4.5 结算路由（D2 + U2-R4）
`TrainingView.onSessionEnded(Int64?)`：
- **Normal 正常结束**：`recordId != nil` → 从 recordRepo 取 `TrainingRecord` → `activeModal = .settlement(.persisted(record))` → SettlementView → confirm → `endAfterSettlement` → 回 home。
- **error（finalize 抛，mode==normal，recordId==nil）**：直接 pop + loadHome（+ 可选 errorMessage）。router 据它持有的 `engine.flow.mode` 区分 replay vs error。
- **Replay 结束（mode==replay，recordId==nil，U2-R4）**：lifecycle 注释「结算窗由顺位 11 据 engine 末态呈现」。SettlementView 吃 `TrainingRecord`——replay 无持久 record。**scope 决策**：
  - **首选（若 ≤500 行且不改冻结 SettlementView）**：从 engine 末态构造**临时（非持久）`TrainingRecord`** 喂 SettlementView（`.settlement(.ephemeral(record))`）。需核实 `TrainingRecord` 可由 engine 末态字段无副作用构造。
  - **退路（若构造临时 record 触碰冻结类型语义或撑爆行数）**：replay 结束直接回 home，**U2-R4 作为 PR11-R2 residual 显式 carry-forward**（不静默丢）。
  - plan 阶段据 `TrainingRecord` 字段可达性 + 行数二择一，并在 acceptance 标注实际选择。

---

## 五、数据流（完整路由图）

```
启动 → AppRootView.task → router.runLaunchRecovery()
        → acceptance.retryPendingConfirmations()（扫 stored ∪ confirmPending，原 lease 重试 confirm）
        → loadHome() → HomeContent
HomeView
  ├ 开始训练 → coordinator.startNewNormalSession() → push TrainingView(normal)
  ├ 继续训练 → coordinator.resumePending() → push / 忽略
  ├ 点历史行(id) → sheet HistoryActionSheet
  │     ├ 复盘 → coordinator.review(id) → push TrainingView(review)
  │     └ 再来一次 → coordinator.replay(id) → push TrainingView(replay)
  └ gear → sheet SettingsPanel(settings/api/cache/acceptance)
TrainingView
  ├ 返回 → lifecycle.back()(saveProgress+endSession) → onExit → pop → loadHome
  └ 自动结束 → lifecycle.finalizeForSettlement() → onSessionEnded(recordId?)
        ├ normal recordId → sheet SettlementView(persisted) → confirm → endAfterSettlement → pop → loadHome
        ├ replay nil → sheet SettlementView(ephemeral) 或 直接 pop（U2-R4 二择一）
        └ error nil → pop → loadHome
```

---

## 六、测试策略

**host 全测（swift test）**：
- `AppRouterTests`（Contracts）：注 `InMemoryRecordRepository`/`InMemoryPendingTrainingRepository`/`InMemoryCacheManager`/`Fake*` P2 + 真 coordinator/settings（吃 InMemory DAO）。覆盖：
  - launch recovery 幂等（retryPendingConfirmations 恰一次：用计数 fake/journal 观察）。
  - loadHome 装配正确（statistics/records/capital/hasPending/hasCachedSets 映射）。
  - startTraining 成功 push / 失败（settings loadError 或无缓存）→ errorMessage 且不 push。
  - continue：有 pending → push；无 → 不 push。
  - selectRecord → modal=.history；review/replay → push 对应 mode engine。
  - sessionEnded：normal recordId → settlement(persisted)；error nil(normal) → 回 home；replay nil → 按 4.5 选择的分支。
  - confirmSettlement → endAfterSettlement 调用 + 回 home + reload。
- `AppContainerTests`（Persistence）：临时目录真 `DefaultAppDB` → `try AppContainer(config:)` 7 依赖非 nil；不可写路径 → init throws。

**非 host-测（编译/运行时兜底）**：
- `AppRootView` + `KlineTrainerApp.swift`：Catalyst build（Contracts 部分）+ 本地 `xcodebuild -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer build`（app 部分，CI 不覆盖）。
- 运行时可达性（从启动到训练/设置、恢复路径）：手动 simulator/device 验收（runbook，沿用 C8b/U2 运行时验收 doc 范式），满足 outline §四 顺位 11「从启动可达训练/设置 + 恢复路径」要求。

---

## 七、CI 覆盖 gap + 决策

**app target 不被任何 CI 构建**（Catalyst CI 只 build `KlineTrainerContracts` scheme）。决策：
- **不**新增 app-build CI job——那是 trust-boundary/workflow 变更（需 codex review + 扩 scope），outline 顺位 11 未要求；且 app target 历来不 CI-build。
- 改 pbxproj + app entry 后**本地** `xcodebuild` app scheme 验证编译链接（local toolchain 是此处唯一编译验证，与 `feedback_swift_local_toolchain_blindspot` 方向相反——此处 CI 根本不覆盖 app，本地是唯一闸门）。
- gap 显式记为 **PR11-R3 residual**：app target 无 CI 守护（依赖本地 build + 运行时验收）。

---

## 八、Scope 与 split 决策

- **目标单 PR**（顺位 11）；生产代码实测 > 500 行则按方案 C 拆 11a/11b（outline 预授权）。
- 保持各件最小（YAGNI）：错误处理仅 errorMessage alert（不做重试 UI）；导航仅 NavigationStack + 互斥 sheet（不做 deep-link/tab）。

## 九、不在本 PR scope
- backend NAS 部署 / 真实 baseURL（W1-R1/R2，outline §六）→ PR11-R1 placeholder。
- E5/E6/C8/P2 内部逻辑（已 merged，本 PR 只接线）。
- SettlementView/HomeView/TrainingView/SettingsPanel 内部改动（冻结视图，只构造+路由）。
- app-build CI job（trust-boundary，§七）。

## 十、验收映射（outline §四 顺位 11）
| outline 要求 | 本设计满足点 |
|---|---|
| 依赖图实例化 | `AppContainerTests` + 本地 app build |
| 从启动可达训练/设置 | `AppRouterTests`（start/review/replay/openSettings push/modal）+ 手动运行时验收 |
| 启动孤儿确认恢复 | `AppRouterTests` launch-recovery 幂等 + retryPendingConfirmations 恰一次 |

## 十一、residuals
- **PR11-R1**：生产 `backendBaseURL` = placeholder（NAS 部署后替换）。
- **PR11-R2**：replay 结束结算窗（U2-R4）——若退路则 carry-forward。
- **PR11-R3**：app target 无 CI 构建守护（本地 build + 运行时验收兜底）。

## 十二、待 plan 阶段核实
- `DefaultFileSystemCacheManager` / `DefaultTrainingSetDBFactory` / 4× P2 default 端口的真实 init 形参。
- `TrainingRecord` 能否由 engine 末态无副作用构造（决定 PR11-R2 首选 vs 退路）。
- 生产 app.sqlite / cache 目录的标准 iOS 路径（App Support vs Documents；Caches）。
- pbxproj 加本地 SPM 包依赖的正确改法（XCLocalSwiftPackageReference + 两 product link）。
