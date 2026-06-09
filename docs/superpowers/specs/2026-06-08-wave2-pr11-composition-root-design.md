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
| `DefaultFileSystemCacheManager` | Persistence | `init(cacheRoot: URL)` | 满足 `CacheManager` |
| `DefaultTrainingSetDBFactory` | Persistence | `init()`（无参） | 满足 `TrainingSetDBFactory` |
| 4× P2 default 端口 | Persistence | `DefaultZipIntegrityVerifier()`/`DefaultZipExtractor()`/`DefaultTrainingSetDataVerifier()`/`DefaultDownloadAcceptanceCleaner()` 全 `init()` 无参 | runner 的 integrity/extractor/dataVerifier/cleaner |
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
@MainActor                                          // [M] 修：容器持 @MainActor props（settings/coordinator/router）+ @MainActor init → 容器自身标 @MainActor（MainActor-confined，刻意非 Sendable；app entry/AppRootView 均在 MainActor）
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
3. `cache = DefaultFileSystemCacheManager(cacheRoot: config.cacheRootDir)`（**核实**：init label 是 `cacheRoot:` 非 `rootDir:`）
4. `dbFactory = DefaultTrainingSetDBFactory()` + 4× P2 default 端口 `DefaultZipIntegrityVerifier()`/`DefaultZipExtractor()`/`DefaultTrainingSetDataVerifier()`/`DefaultDownloadAcceptanceCleaner()`（**核实**：全部 `init()` 无参）
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
public enum Modal: Identifiable {             // 互斥 sheet；只需 Identifiable（.sheet(item:) 用），不需 Equatable
    case settings
    case history(TrainingRecord)              // [C] 修：直接携带已解析 record（router 同步从 records 取），sheet builder 同步可用
    case settlement(TrainingRecord)           // [C] 修：router 异步 loadRecordBundle 预取后携带
    // [M] 修：case-tagged id 防 history(id=5)/settlement(id=5) 碰撞致 .sheet 不重呈现
    // [L] 修：`TrainingRecord.id` 是 `Int64?`（AppState.swift:20）→ 显式 `?? -1` 避免 `\(r.id)` 插值出 "Optional(5)" 警告 + 错 id；持久 record 恒有 id，`-1` 仅消警不触发
    public var id: String {
        switch self {
        case .settings:            return "settings"
        case .history(let r):      return "history-\(r.id ?? -1)"
        case .settlement(let r):   return "settlement-\(r.id ?? -1)"
        }
    }
}
@MainActor 状态：
  var homeContent: HomeContent = .emptyState  // 见下「空态」；非 optional，避免 ?? 与不存在的 .empty
  private var records: [TrainingRecord] = []  // [C] 修：loadHome 缓存原始 records（HomeContent 只暴露格式化 rows 无 TrainingRecord）；selectRecord 据此 O(n) 查
  var activeTraining: ActiveTraining?         // nil=首页；非 nil=已 push 训练页（仅单层，故用 isPresented 绑定非 path 数组）
  var activeModal: Modal?
  var errorMessage: String?                   // 转换失败 → alert
  private var didRunLaunchRecovery = false
```
**`ActiveTraining`**（router 内值/引用，**非** NavigationStack path 元素，规避 Hashable 约束）：持 `lifecycle: TrainingSessionLifecycle`（engine+coordinator）；`mode` 读自 `lifecycle.engine.flow.mode`（`flow` 是 `public let`，`mode` public，已核实可达）。router 在 `sessionEnded(nil)` 时仍持有它（pop 前），用于区分 replay vs error。
**空态 HomeContent**（[C] 修：`HomeContent` 是冻结 U1 纯值类型，**无** `.empty` 静态成员）：router 用零值显式构造 `HomeContent(statistics:(0,0,0), configuredCapital:0, records:[], hasPending:false, hasCachedSets:false)` 作为 `.emptyState`（在 AppRouter 内定义的私有 helper，不改 HomeContent）。

**意图方法**（async，捕获 coordinator throws → errorMessage，不 crash）：
| 入口 | 行为 |
|---|---|
| `runLaunchRecovery()` | 幂等门 `didRunLaunchRecovery`（**恰一次属性来自此 router 门，非 runner——runner 每次全量重扫不去重**）；`await acceptance.retryPendingConfirmations()`；然后 `await loadHome()` |
| `loadHome()` | `let recs = try recordRepo.listRecords(limit:)` → 存 `self.records = recs`；从 recs + recordRepo.statistics() + settings.settings.totalCapital + pendingRepo.loadPending() + cache.listAvailable() 装配 `HomeContent`；读失败 → errorMessage + `.emptyState` + `records=[]` |
| `startTraining()` | `engine = try await coordinator.startNewNormalSession()` → `activeTraining = ActiveTraining(lifecycle:)`；throw → errorMessage（如 loadError/无缓存集） |
| `continueTraining()` | `if let e = try await coordinator.resumePending() { activeTraining = … }`，nil → 忽略（或刷新 home） |
| `selectRecord(id)` | `if let r = records.first(where: { $0.id == id }) { activeModal = .history(r) }`（[C] 修：从 router 缓存 records 取，非 homeContent） |
| `review(id)` | `activeModal=nil` → `engine = try await coordinator.review(recordId:)` → `activeTraining = …` |
| `replay(id)` | `activeModal=nil` → `engine = try await coordinator.replay(recordId:)` → `activeTraining = …` |
| `openSettings()` | `activeModal = .settings` |
| `exitTraining()` | `activeTraining = nil` → `await loadHome()`（**注**：经 TrainingView「返回」按钮触发，其 `lifecycle.back()` 已 saveProgress+endSession，故此处不再 endSession 防双调；back-swipe 经 §4.4 隐藏系统返回键禁用） |
| `sessionEnded(recordId:)` | 见 4.5 结算路由 |
| `confirmSettlement()` | `await activeTraining?.lifecycle.endAfterSettlement()` → `activeModal=nil` → `activeTraining=nil` → `await loadHome()` |

### 4.4 `AppRootView`（Contracts，SwiftUI 薄壳，`#if canImport(UIKit)`）
**init**：`init(router: AppRouter, settings: SettingsStore, api: any APIClient, cache: any CacheManager, acceptance: DownloadAcceptanceRunner)`——只吃 Contracts 抽象（**不**吃 `AppContainer`，避免 Contracts 依赖 Persistence）。settings/api/cache/acceptance 仅为构造 `SettingsPanel` 透传；其余路由全经 router。
- `NavigationStack { HomeView(content: router.homeContent, onStartTraining:{ Task{ await router.startTraining() }}, …).navigationDestination(isPresented: trainingBinding) { if let t = router.activeTraining { TrainingView(lifecycle: t.lifecycle, onExit:{ Task{ await router.exitTraining() }}, onSessionEnded:{ id in Task{ await router.sessionEnded(recordId: id) }}).navigationBarBackButtonHidden(true) } } }`。
  - **单层 push 用 `navigationDestination(isPresented:)`**（非 `path:` 数组）——规避非-Hashable lifecycle；training 只一层。
  - **显式 binding**：`trainingBinding = Binding(get: { router.activeTraining != nil }, set: { if !$0 { Task { await router.exitTraining() } } })`。
  - **`.navigationBarBackButtonHidden(true)`**（[L]/[H] 修）：抑制系统返回键 + back-swipe，强制经 TrainingView「返回」按钮退出（其 `lifecycle.back()` 做 saveProgress+endSession）→ 杜绝 back-swipe 绕过 teardown 泄漏 reader。
- `.sheet(item: $router.activeModal)`：`.settings` → `SettingsPanel(settings:api:cache:acceptance:)`；`.history(let r)` → `HistoryActionSheet(record: r, onReview:{ Task{ await router.review(id: r.id) }}, onReplay:{ Task{ await router.replay(id: r.id) }}, onCancel:{ router.activeModal=nil })`；`.settlement(let r)` → `SettlementView(record: r, onConfirm:{ Task{ await router.confirmSettlement() }})`。**record 由 Modal 直接携带（router 已预取）**——sheet builder 同步，无需 await。
- `.alert(router.errorMessage)`、`.task { await router.runLaunchRecovery() }`（幂等门保证仅一次）。
- **不含路由逻辑**——全部 delegate router 方法（壳仅绑定 + 渲染，同 TrainingView 范式）。

### 4.5 结算路由（D2 + U2-R4 决策：retreat）
`TrainingView.onSessionEnded(Int64?)` → `router.sessionEnded(recordId:)`。`recordId` 来自 `lifecycle.finalizeForSettlement()`；`TrainingView.maybeAutoEnd` 在 finalize 抛错时也回调 `onSessionEnded(nil)`（`TrainingView.swift:116-120`），故 `nil` 在 replay-成功 与 normal-finalize-失败 间二义。router 用**它仍持有的** `activeTraining.lifecycle.engine.flow.mode` 消歧（pop 前 mode 可读）：

**[H] reader teardown 不变量**（`finalize()` **不**调 `endSession()`——`TrainingSessionCoordinator.swift:54,120` 契约「caller 须先 endSession()」）：`finalizeForSettlement()` 跑后 `activeReader`/`activeEngine` 仍开；**任何**离开训练页的分支若已调 finalize，须在 nil-ing 前 `await activeTraining?.lifecycle.endAfterSettlement()`（= `coordinator.endSession()`，非抛 async），否则下个 `startNewNormalSession/review/replay` 在 `activeReader != nil` 下启动违反契约 + 泄漏 reader。

| 情形 | 判据 | 行为 |
|---|---|---|
| Normal 正常结束 | `recordId != nil` | `if let id = recordId`（[L] 修：先解包 `Int64?`→`Int64`，`loadRecordBundle(id:)` 取 `Int64`）→ `let rec = try? recordRepo.loadRecordBundle(id: id).0`（异步预取，弃 ops/drawings；nil→errorMessage+teardown 回 home）→ `activeModal = .settlement(rec)` → SettlementView → confirm → `confirmSettlement()`（含 `endAfterSettlement`）→ 回 home。**注**：此分支 reader 在结算窗期间保持开（正常，confirm 时才 endSession） |
| Replay 结束 | `recordId == nil` 且 `mode == .replay` | **retreat**：**先 `await activeTraining?.lifecycle.endAfterSettlement()`**（[H] 修，关 reader）→ `activeTraining=nil` → `loadHome()`，**不弹结算**。U2-R4 作 **PR11-R2 deferred** carry-forward |
| Normal finalize 失败 | `recordId == nil` 且 `mode == .normal` | **先 `await activeTraining?.lifecycle.endAfterSettlement()`**（[H] 修，关 reader）→ `errorMessage`（结算入账失败）→ `activeTraining=nil` → `loadHome()` |

**为何 retreat（替代 v1 的「构造 ephemeral record」首选）**：审查 [H] 实证——`SettlementContent` 渲染 `stockName/stockCode/startYear/startMonth`（`SettlementContent.swift:27-28,44`），但 `TrainingEngine` 不暴露这些（仅 capital/returnRate/tradeOps/drawdown/initialCapital，`TrainingEngine.swift`），stock/月份元信息在 `reader.loadMeta()` 被 coordinator 私有持有且 replay() 返回后丢弃。**无法**从 engine 末态构造完整 record；用 `loadRecordBundle(原id)` 又会显示**原局**而非本次 replay 的 P&L（replay 不入账）——语义错误。忠实实现需触碰冻结 E5/E6（surfacing meta）或冻结 SettlementView（改签名）= scope creep。故 replay 结束直接回首页（行为正确但最简），settlement 窗作 PR11-R2 显式 deferred。outline §四 顺位 11 验收项（依赖图实例化 / 从启动可达训练设置 / 恢复路径）**不含** replay 结算，retreat 不损核心验收。

### 4.6 `KlineTrainerApp.swift`（xcodeproj，薄 @main）+ DB-fail 兜底
**[M] 修：钉死 @main DB-fail idiom**——`App.init` 不能 throw 且 `body` 须返 Scene，故构造失败用「init 捕获存状态 + body 分支」标准式（不 crash）：
```swift
@main
struct KlineTrainerApp: App {
    @State private var container: AppContainer?      // 构造成功
    @State private var initError: Error?             // 构造失败（DB 打开/migration）
    init() {
        do {
            let cfg = AppConfig(dbPath: <App Support>/app.sqlite,
                                cacheRootDir: <Caches>/training-sets,
                                backendBaseURL: URL(string: "http://kline-trainer.local")!) // TODO(NAS) PR11-R1
            _container = State(initialValue: try AppContainer(config: cfg))   // @MainActor init：App.init 主线程，OK
        } catch { _initError = State(initialValue: error) }
    }
    var body: some Scene {
        WindowGroup {
            if let c = container {
                AppRootView(router: c.router, settings: c.settings, api: c.api, cache: c.cache, acceptance: c.acceptance)
            } else {
                AppLaunchErrorView(error: initError)   // 简单文案 + 重试（重试 = 重建 container）；本 PR 最简错误视图
            }
        }
    }
}
```
路径用 `FileManager.default.url(for: .applicationSupportDirectory…)` / `.cachesDirectory`（plan 阶段核实）。`AppLaunchErrorView` 是本 PR 新增最简错误屏（不滥用，仅满足「DB 打开失败不 crash」）。

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
TrainingView（系统返回键/back-swipe 已隐藏，只走「返回」按钮）
  ├ 返回 → lifecycle.back()(saveProgress+endSession) → onExit → exitTraining → loadHome
  └ 自动结束 → lifecycle.finalizeForSettlement() → onSessionEnded(recordId?)
        ├ normal recordId → loadRecordBundle(id).0 → sheet SettlementView → confirm(endAfterSettlement) → 回 home
        ├ replay nil（mode==replay）→ endAfterSettlement(关 reader) → 直接回 home（U2-R4 deferred PR11-R2）
        └ normal nil（finalize 抛）→ endAfterSettlement(关 reader) → errorMessage → 回 home
```

---

## 六、测试策略

**host 全测（swift test）**：
- `AppRouterTests`（Contracts）。**测试替身**（[M] 修——现存 `FakeAPIClient` 全 `private` 于各 test 文件不可复用）：复用 `InMemoryRecordRepository`/`InMemoryPendingTrainingRepository`/`InMemoryCacheManager`/`InMemoryAcceptanceJournalDAO`/`InMemorySettingsDAO`（PR #45/#46，public）+ `Fake*` P2 端口（P2Fakes，public）+ **本 PR 新写 `CountingAPIClient`**（Contracts test target 内的 APIClient 测试 double，记 `confirmTrainingSet` 调用数）。coordinator/settings 用真类吃 InMemory DAO。覆盖：
  - **launch recovery 恰一次**（[M] 修——属性来自 router `didRunLaunchRecovery` 门，非 runner）：journal 预置 N 条 `.stored`/`.confirmPending` 行 + `CountingAPIClient`；连调 `runLaunchRecovery()` 两次 → `confirmCount == N`（不是 `2N`），证 router 门拦住第二次重扫。
  - loadHome 装配正确（statistics/records/capital/hasPending/hasCachedSets 映射）。
  - **空态**：0 records + 无缓存集 + settings loadError-降级 → loadHome 得 `.emptyState`-等价值不 crash。
  - startTraining 成功 → `activeTraining != nil` / 失败（settings loadError 或无缓存集）→ errorMessage 且 `activeTraining == nil`。
  - continue：有 pending → `activeTraining != nil`；无 → 仍 nil。
  - selectRecord → `activeModal == .history(record)`（record.id 匹配）；review/replay → `activeTraining` 持对应 mode engine。
  - sessionEnded：normal recordId → `activeModal == .settlement(record)`；normal nil → errorMessage + `activeTraining==nil`；replay nil → `activeTraining==nil` 且无 settlement（retreat）。
  - **[H] teardown 验证**：replay-nil 与 normal-nil 两路径**结束后 coordinator 可立即再 `startNewNormalSession()` 成功**（证 reader 已关；若 endSession 漏调，第二次会因 `activeReader != nil` 抛/破契约）——用此正向序列断言 teardown，无需私有状态。
  - confirmSettlement → endAfterSettlement 调用 + `activeTraining==nil` + reload。
- `AppContainerTests`（Persistence）：临时目录真 `DefaultAppDB` → `try AppContainer(config:)` 各依赖（含 router）非 nil；不可写路径 → init throws。

**非 host-测（编译/运行时兜底）**：
- `AppRootView` + `KlineTrainerApp.swift`：Catalyst build（Contracts 部分）+ 本地 `xcodebuild -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer build`（app 部分，CI 不覆盖）。**[H] 修**：app target **当前无 shared scheme**（`xcshareddata/xcschemes/` 不存在）→ 本 PR pbxproj 改动须**创建并 commit** `KlineTrainer.xcscheme`（shared），否则 `-scheme KlineTrainer` 依赖未提交的 autogen scheme 不稳定。
- 运行时可达性（从启动到训练/设置、恢复路径）：手动 simulator/device 验收（runbook，沿用 C8b/U2 运行时验收 doc 范式），满足 outline §四 顺位 11「从启动可达训练/设置 + 恢复路径」要求。

---

## 七、CI 覆盖 gap + 决策

**app target 不被任何 CI 构建**（Catalyst CI 只 build `KlineTrainerContracts` scheme）。决策：
- **不**新增 app-build CI job——那是 trust-boundary/workflow 变更（需 codex review + 扩 scope），outline 顺位 11 未要求；且 app target 历来不 CI-build。
- 改 pbxproj（加本地 SPM 包依赖 + link 两 product）+ **创建并 commit shared `KlineTrainer.xcscheme`** + app entry 后，**本地** `xcodebuild -scheme KlineTrainer build` 验证编译链接（local toolchain 是此处唯一编译验证，与 `feedback_swift_local_toolchain_blindspot` 方向相反——此处 CI 根本不覆盖 app，本地是唯一闸门）。
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
- **PR11-R1**：生产 `backendBaseURL` = placeholder（NAS 部署后替换；download/reserve 真实网络路径在 NAS 上线前不通——本就 out-of-scope）。
- **PR11-R2**：replay 结束结算窗（U2-R4）**deferred**——retreat 决策（§4.5），replay 结束直接回首页，结算窗忠实实现需触碰冻结 E5/E6/SettlementView，留后续 anchor。
- **PR11-R3**：app target 无 CI 构建守护（本地 `xcodebuild -scheme KlineTrainer` + 运行时验收兜底）。

## 十二、待 plan 阶段核实（v2：端口 init 已核实并入正文，下列为剩余）
- 生产 app.sqlite / cache 目录的标准 iOS 路径（App Support vs Documents；Caches）。
- pbxproj 加本地 SPM 包依赖的正确改法（XCLocalSwiftPackageReference + 两 product link）+ shared scheme 文件格式。
- `loadRecordBundle(id:)` 在刚 finalize 的 id 上确不会因事务可见性返回空（预期 finalize 已提交，立即可读；plan 测试以 InMemory repo 验证调用序）。

## 十三、v2 对抗性审查（opus 4.8 xhigh）响应
spec 经一轮 opus 4.8 xhigh 对抗性审查，2C+4H+3M+2L 全部 valid（无驳回），逐条修入正文：
- **[C] cache init label** `rootDir:`→`cacheRoot:`（§一/§4.2，自 grep 独立确认）。
- **[C] `HomeContent.empty` 不存在**（冻结 U1 类型）→ router 显式零值 `.emptyState` helper（§4.3）。
- **[H] replay ephemeral record 不可行**（SettlementContent 需 stock/月份元信息，engine 不暴露）→ retreat，U2-R4 deferred PR11-R2（§4.5）。
- **[H] `onSessionEnded(nil)` 二义** → router 读 retained `activeTraining.lifecycle.engine.flow.mode` 消歧（§4.3/§4.5）。
- **[H] app target 无 shared scheme** → 本 PR 创建并 commit `KlineTrainer.xcscheme`（§六/§七）。
- **[M] 无可复用 APIClient fake** → 新写 `CountingAPIClient` test double（§六）。
- **[M] exactly-once 是 router 级非 runner 级** → 经 `CountingAPIClient.confirmCount==N`（非 2N）断言（§六）。
- **[M] Normal 结算 re-fetch** → `loadRecordBundle(id:).0` + throws 处理（§4.5）。
- **[L] DBFactory/4 端口 init** → 全 `init()` 无参（§4.2，已核实）。
- 设计自查另修：`NavigationStack(path:)` 须 Hashable 元素 vs lifecycle 不可 Hashable → 改 `navigationDestination(isPresented:)` 单层 push（§4.3/§4.4）。

**v3 对抗性审查（opus 4.8 xhigh）R2**：8 个 R1 修正全部 VERIFIED 落地正确；R2 新增 1C+1H+2M+1L 全部 valid（无驳回），修入正文：
- **[C] `HomeContent` 不暴露 `records`**（只有格式化 `rows: [HomeHistoryRow]`）→ router 自留 `private var records: [TrainingRecord]`（loadHome 缓存），Modal 直接携带已解析 `TrainingRecord`（§4.3/§4.4）。
- **[H] retreat 两 nil 路径泄漏 reader**（`finalize()` 不 endSession）→ replay-nil/normal-nil 均先 `endAfterSettlement()` 关 reader 再 nil；正向「结束后能立即再开局」断言 teardown（§4.5/§六）。
- **[M] AppContainer Swift 6 隔离** → 标 `@MainActor`（MainActor-confined，§4.2）。
- **[M] `Modal.id` 未定义碰撞** → case-tagged String id（§4.3）。
- **[L] back-swipe 绕过 teardown** → 训练目的地 `.navigationBarBackButtonHidden(true)` + 显式 binding（§4.4）。
- R2 verified-clean：AppDB typealias / SettingsStore / runner / APIClient 协议（CountingAPIClient 可行）/ `settings.totalCapital` 为 configuredCapital 正源 / 行数临界但方案 C 兜。

**v3.1 对抗性审查（opus 4.8 xhigh）R3 = `APPROVE`（收敛）**：R2 全部修正 VERIFIED；binding 无 re-entrancy；`.navigationBarBackButtonHidden(true)` 在 iOS16+ NavigationStack 确同时抑制 back-swipe（leak 真闭）；disambiguation 可达。仅 2 项非阻塞 plan-stage refinement，已折入：
- **[M] @main DB-fail idiom 钉死**（§4.6）：`init(){do{container=try…}catch{initError=…}}` + body 切 `AppLaunchErrorView`/`AppRootView`（App.init 主线程 @MainActor 可调 @MainActor 容器 init）。
- **[L] `TrainingRecord.id: Int64?`**（AppState.swift:20）：`Modal.id` 用 `?? -1` 消 Optional 插值警告（§4.3）；Normal 结算分支先 `if let id = recordId` 解包再喂 `loadRecordBundle(id:)`（§4.5）。
**spec 收敛于 R3 APPROVE，进 writing-plans。**
