# Wave 2 顺位 11 — 生产组合根 + 路由 + 启动恢复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 替换模板 app entry，构造生产依赖图（DefaultAppDB/SettingsStore/E6 coordinator/P2 runner）+ 把 HomeView→TrainingView（start/continue/review/replay）+ gear→SettingsPanel 路由接成闭环 + 启动跑一次 `retryPendingConfirmations()`。

**Architecture:** 三层分布——`AppRouter`（导航状态机，纯逻辑，host-test）+ `AppRootView`（SwiftUI 薄壳，Catalyst-build）落 `KlineTrainerContracts`；`AppContainer`（构造全部 `Default*` 具体依赖 + 预建 router）落 `KlineTrainerPersistence`（因 Contracts 不可 import Persistence）；薄 `KlineTrainerApp.swift` 落 xcodeproj，构造 AppContainer + 渲染 AppRootView，DB 打开失败渲染错误屏。

**Tech Stack:** Swift 6.0 / SwiftUI（`#if canImport(UIKit)` 门）/ Observation（`@Observable`）/ Swift Testing（`import Testing` + `#expect`）/ GRDB（经 DefaultAppDB）。

**Spec:** `docs/superpowers/specs/2026-06-08-wave2-pr11-composition-root-design.md`（R3 APPROVE 收敛）。

---

## 文件结构

| 文件 | 模块 | 职责 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift` | Contracts | 导航状态机 + home 数据装配 + 会话构造 + 启动恢复 + 结算路由（纯逻辑，host-test） |
| `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift` | Contracts | SwiftUI 根壳：NavigationStack(home→training) + 互斥 sheet（`#if canImport(UIKit)`） |
| `ios/Contracts/Sources/KlineTrainerPersistence/AppConfig.swift` | Persistence | 纯值配置（dbPath/cacheRootDir/backendBaseURL） |
| `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift` | Persistence | 组合根：构造 9 具体依赖 + 预建 router（`@MainActor`，init throws） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift` | Contracts test | router 全行为 host 测 + `CountingAPIClient` test double + journal seed helper |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerTests.swift` | Persistence test | 图实例化 + DB 打开失败 throws |
| `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift`（改） | xcodeproj | 薄 @main：构造 AppContainer → AppRootView / 失败 → AppLaunchErrorView |
| `ios/KlineTrainer/KlineTrainer/AppLaunchErrorView.swift`（新） | xcodeproj | 最简 DB-fail 错误屏 |
| `ios/KlineTrainer/KlineTrainer/ContentView.swift`（删） | xcodeproj | 模板 Hello World，删除 |
| `ios/KlineTrainer/KlineTrainer.xcodeproj/project.pbxproj`（改） | xcodeproj | 加本地 SPM 包 `../Contracts` + link 两 product |
| `ios/KlineTrainer/KlineTrainer.xcodeproj/xcshareddata/xcschemes/KlineTrainer.xcscheme`（新） | xcodeproj | shared scheme（稳定本地 `xcodebuild -scheme KlineTrainer`） |

**任务顺序（依赖拓扑）**：Task 1-3 AppRouter（Contracts）→ Task 4 AppContainer（Persistence，构造 router）→ Task 5 AppRootView（Contracts）→ Task 6 app entry + pbxproj + scheme（xcodeproj）→ Task 7 整体验证 + acceptance。

---

## Task 0：评审策略 + scope 确认（§15.3 / outline §五 step 1）

- [ ] **Step 1：确认评审通道**

本 PR 评审走 **opus 4.8 xhigh 对抗性 review**（plan-stage + branch-diff 双闸门，per user explicit；codex 周配额耗尽 fallback 先例 memory `project_pr*`）。merge 经 attest-override + admin（不绕 Catalyst CI）。

- [ ] **Step 2：确认单 PR（不拆 11a/11b）**

生产代码估算 AppRouter ~200 + AppRootView ~140 + AppContainer ~80 + AppConfig ~15 + entry ~45 + errorView ~20 ≈ **500 临界**。决策：**单 PR**；Task 6 实施后若 `git diff --stat` 生产 swift 净增 > 550 行，按 outline 预授权拆 11a（Task 1-4）/11b（Task 5-7）。无代码改动，记录决策即继续。

---

## Task 1：AppRouter 核心状态 + loadHome（Contracts）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift`

- [ ] **Step 1：写失败测试（loadHome 装配 + 空态）**

创建 `AppRouterTests.swift`：
```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@MainActor
@Suite("AppRouter")
struct AppRouterTests {

    // MARK: - fixtures（复用 PR #45/#46 public fakes + E6 coordinator 范式）

    static func validCandles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int, close: Double) -> KLineCandle {
            KLineCandle(period: p, datetime: Int64(gi) * 180, open: 10, high: 11, low: 9,
                        close: close, volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: gi, endGlobalIndex: egi)
        }
        let m3 = (0..<m3Count).map { c(.m3, gi: $0, egi: $0, close: 10 + Double($0) * 0.1) }
        let last = m3Count - 1
        let m60 = [c(.m60, gi: 0, egi: last / 2, close: 10.3),
                   c(.m60, gi: last / 2 + 1, egi: last, close: 10.7)]
        let daily = [c(.daily, gi: 0, egi: last, close: 10.7)]
        return [.m3: m3, .m60: m60, .daily: daily]
    }

    struct CapitalDAO: SettingsDAO {
        let capital: Double
        var loadErr: AppError?
        func loadSettings() throws -> AppSettings {
            if let e = loadErr { throw e }
            return AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                               totalCapital: capital, displayMode: .system)
        }
        func saveSettings(_: AppSettings) throws {}
        func resetCapital() throws {}
    }

    static func cachedFile(id: Int = 1) -> TrainingSetFile {
        TrainingSetFile(id: id, filename: "set\(id).sqlite",
                        localURL: URL(fileURLWithPath: "/tmp/set\(id).sqlite"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    static func record(id: Int64, profit: Double = 0) -> TrainingRecord {
        TrainingRecord(id: id, trainingSetFilename: "t.sqlite", createdAt: 0,
                       stockCode: "000001", stockName: "测试股", startYear: 2020, startMonth: 1,
                       totalCapital: 100_000, profit: profit, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0, feeSnapshot: FeeSnapshot.zero, finalTick: 2)
    }

    /// 组装一个 router + 暴露其内部依赖供测试断言/seed。
    static func makeRouter(
        candles: [Period: [KLineCandle]] = validCandles(),
        capital: Double = 100_000,
        settingsLoadError: AppError? = nil,
        seedFiles: [TrainingSetFile] = [cachedFile()],
        seedRecords: [TrainingRecord] = [],
        api: any APIClient = CountingAPIClient()
    ) -> (router: AppRouter, records: InMemoryRecordRepository,
          pending: InMemoryPendingTrainingRepository, journal: InMemoryAcceptanceJournalDAO,
          cache: InMemoryCacheManager, api: any APIClient) {
        let records = InMemoryRecordRepository()
        for r in seedRecords { try? records.insertRecord(r) }
        let pending = InMemoryPendingTrainingRepository()
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        cache._seedForTesting(seedFiles)
        let settings = SettingsStore(settingsDAO: CapitalDAO(capital: capital, loadErr: settingsLoadError))
        let coordinator = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: candles),
            recordRepo: records, pendingRepo: pending,
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: settings)
        let runner = DownloadAcceptanceRunner(
            api: api, cache: cache, dbFactory: PreviewTrainingSetDBFactory(candles: candles),
            journal: journal, integrity: FakeZipIntegrityVerifier(),
            extractor: FakeZipExtractor(), dataVerifier: FakeTrainingSetDataVerifier(),
            cleaner: FakeDownloadAcceptanceCleaner())
        let router = AppRouter(coordinator: coordinator, settings: settings, acceptance: runner,
                               recordRepo: records, pendingRepo: pending, cache: cache)
        return (router, records, pending, journal, cache, api)
    }

    @Test("loadHome 装配 statistics/capital/hasPending/hasCachedSets/records")
    func loadHome_assembles() async {
        let f = Self.makeRouter(capital: 88_000,
                                seedRecords: [Self.record(id: 1, profit: 100), Self.record(id: 2, profit: -50)])
        await f.router.loadHome()
        #expect(f.router.homeContent.configuredCapital == 88_000)
        #expect(f.router.homeContent.hasCachedSets == true)
        #expect(f.router.homeContent.hasPending == false)
        #expect(f.router.errorMessage == nil)
    }

    @Test("loadHome 空态：0 records + 无缓存 + settings loadError 不 crash")
    func loadHome_emptyState() async {
        let f = Self.makeRouter(settingsLoadError: .persistence(.dbCorrupted),
                                seedFiles: [], seedRecords: [])
        await f.router.loadHome()
        #expect(f.router.homeContent.hasCachedSets == false)
        #expect(f.router.homeContent.hasPending == false)
    }
}
```

- [ ] **Step 2：跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter AppRouter`
Expected: FAIL（`cannot find 'AppRouter'`/`CountingAPIClient` in scope）。

- [ ] **Step 3：写 AppRouter 核心 + CountingAPIClient**

创建 `App/AppRouter.swift`：
```swift
// Wave 2 顺位 11 — 生产组合根导航状态机（spec 2026-06-08 §4.3）。
// 平台无关纯逻辑（host 全测）：只依赖抽象端口，被 AppContainer(Persistence) 预建、AppRootView(Contracts) 驱动。
import Foundation
import Observation

@MainActor
@Observable
public final class AppRouter {
    public enum Modal: Identifiable {
        case settings
        case history(TrainingRecord)
        case settlement(TrainingRecord)
        public var id: String {
            switch self {
            case .settings:          return "settings"
            case .history(let r):    return "history-\(r.id ?? -1)"       // TrainingRecord.id 是 Int64?；持久 record 恒有 id，?? -1 仅消插值警告
            case .settlement(let r): return "settlement-\(r.id ?? -1)"
            }
        }
    }

    public struct ActiveTraining {
        public let lifecycle: TrainingSessionLifecycle
        public init(lifecycle: TrainingSessionLifecycle) { self.lifecycle = lifecycle }
    }

    private let coordinator: TrainingSessionCoordinator
    private let settings: SettingsStore
    private let acceptance: DownloadAcceptanceRunner
    private let recordRepo: any RecordRepository
    private let pendingRepo: any PendingTrainingRepository
    private let cache: any CacheManager

    public private(set) var homeContent: HomeContent
    public private(set) var activeTraining: ActiveTraining?
    public var activeModal: Modal?
    public private(set) var errorMessage: String?

    private var records: [TrainingRecord] = []
    private var didRunLaunchRecovery = false

    public init(coordinator: TrainingSessionCoordinator, settings: SettingsStore,
                acceptance: DownloadAcceptanceRunner, recordRepo: any RecordRepository,
                pendingRepo: any PendingTrainingRepository, cache: any CacheManager) {
        self.coordinator = coordinator
        self.settings = settings
        self.acceptance = acceptance
        self.recordRepo = recordRepo
        self.pendingRepo = pendingRepo
        self.cache = cache
        self.homeContent = AppRouter.emptyHome()
    }

    static func emptyHome() -> HomeContent {
        HomeContent(statistics: (totalCount: 0, winCount: 0, currentCapital: 0),
                    configuredCapital: 0, records: [], hasPending: false, hasCachedSets: false)
    }

    public func loadHome() async {
        do {
            let recs = try recordRepo.listRecords(limit: nil)
            let stats = try recordRepo.statistics()
            let hasPending = (try pendingRepo.loadPending()) != nil
            let hasCached = !cache.listAvailable().isEmpty
            self.records = recs
            self.homeContent = HomeContent(statistics: stats,
                                           configuredCapital: settings.settings.totalCapital,
                                           records: recs, hasPending: hasPending, hasCachedSets: hasCached)
        } catch {
            self.records = []
            self.homeContent = AppRouter.emptyHome()
            setError(error)
        }
    }

    func setError(_ error: Error) {
        errorMessage = (error as? AppError)?.userMessage ?? "操作失败"
    }
}
```

在 `AppRouterTests.swift` 顶部（`@testable import` 之后、`@Suite` 之前）加 test double：
```swift
/// confirm 抛非-404/409 网络错误 → journal 行停留 confirmPending（可重扫）→ 坏 guard 给 2N、好 guard 给 N。
actor CountingAPIClient: APIClient {
    private(set) var confirmCount = 0
    func reserveTrainingSets(count: Int) async throws -> LeaseResponse { throw AppError.network(.offline) }
    func downloadTrainingSet(id: Int) async throws -> URL { throw AppError.network(.offline) }
    func confirmTrainingSet(id: Int, leaseId: String) async throws {
        confirmCount += 1
        throw AppError.network(.offline)   // 非 serverError(404/409) → attemptConfirm 归 .pending，行留 confirmPending
    }
}
```

- [ ] **Step 4：跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter AppRouter`
Expected: PASS（loadHome_assembles + loadHome_emptyState）。

- [ ] **Step 5：commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift
git commit -m "顺位11 Task1：AppRouter 核心状态 + loadHome + CountingAPIClient test double"
```

---

## Task 2：AppRouter 会话意图（start/continue/select/review/replay/openSettings/exit）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift`

- [ ] **Step 1：写失败测试**

在 `AppRouterTests` 内加：
```swift
@Test("startTraining 成功 → activeTraining 非 nil（normal 模式）")
func startTraining_success() async {
    let f = Self.makeRouter()
    await f.router.startTraining()
    #expect(f.router.activeTraining != nil)
    #expect(f.router.activeTraining?.lifecycle.engine.flow.mode == .normal)
    #expect(f.router.errorMessage == nil)
}

@Test("startTraining 失败（无缓存集）→ errorMessage 且 activeTraining nil")
func startTraining_noCache_error() async {
    let f = Self.makeRouter(seedFiles: [])
    await f.router.startTraining()
    #expect(f.router.activeTraining == nil)
    #expect(f.router.errorMessage != nil)
}

@Test("continueTraining 无 pending → 不 push")
func continue_noPending() async {
    let f = Self.makeRouter()
    await f.router.continueTraining()
    #expect(f.router.activeTraining == nil)
}

@Test("selectRecord → activeModal=.history(对应 record)")
func selectRecord_setsHistoryModal() async {
    let f = Self.makeRouter(seedRecords: [Self.record(id: 7)])
    await f.router.loadHome()              // 填 router.records 缓存
    f.router.selectRecord(id: 7)
    if case .history(let r)? = f.router.activeModal { #expect(r.id == 7) } else { Issue.record("expected .history") }
}

@Test("review(id) → push review 模式 engine")
func review_pushesReviewMode() async {
    let f = Self.makeRouter(seedRecords: [Self.record(id: 3)])
    await f.router.review(id: 3)
    #expect(f.router.activeModal == nil)
    #expect(f.router.activeTraining?.lifecycle.engine.flow.mode == .review)
}

@Test("exitTraining → activeTraining nil + reload home")
func exitTraining_clears() async {
    let f = Self.makeRouter()
    await f.router.startTraining()
    await f.router.exitTraining()
    #expect(f.router.activeTraining == nil)
}
```

- [ ] **Step 2：跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter AppRouter`
Expected: FAIL（`startTraining`/`selectRecord` 等未定义）。

- [ ] **Step 3：写意图方法**

在 `AppRouter` 内 `loadHome()` 之后加：
```swift
    public func startTraining() async {
        do {
            let engine = try await coordinator.startNewNormalSession()
            activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
        } catch { setError(error) }
    }

    public func continueTraining() async {
        do {
            if let engine = try await coordinator.resumePending() {
                activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
            }
        } catch { setError(error) }
    }

    public func selectRecord(id: Int64) {
        if let r = records.first(where: { $0.id == id }) { activeModal = .history(r) }
    }

    public func review(id: Int64) async {
        activeModal = nil
        do {
            let engine = try await coordinator.review(recordId: id)
            activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
        } catch { setError(error) }
    }

    public func replay(id: Int64) async {
        activeModal = nil
        do {
            let engine = try await coordinator.replay(recordId: id)
            activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
        } catch { setError(error) }
    }

    public func openSettings() { activeModal = .settings }

    public func exitTraining() async {
        activeTraining = nil            // 经 TrainingView「返回」按钮触发，其 lifecycle.back() 已 saveProgress+endSession；此处不再 endSession 防双调
        await loadHome()
    }
```

- [ ] **Step 4：跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter AppRouter`
Expected: PASS（全部 Task1+Task2 用例）。

- [ ] **Step 5：commit**

```bash
git add -A && git commit -m "顺位11 Task2：AppRouter 会话意图 start/continue/select/review/replay/openSettings/exit"
```

---

## Task 3：AppRouter 启动恢复 + 结算路由 + teardown（含 exactly-once）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift`

- [ ] **Step 1：写失败测试（exactly-once + 三路 sessionEnded + confirm）**

在 `AppRouterTests` 内加 journal seed helper + 测试：
```swift
/// 走状态机种入一条 confirmPending 行（downloaded→…→stored→confirmPending）。
static func seedConfirmPending(_ j: InMemoryAcceptanceJournalDAO, tsId: Int, lease: String) throws {
    let path = "/tmp/\(tsId).sqlite"; let hash = "abcd1234"   // 8-char lowercase hex(CRC32)
    try j.upsert(trainingSetId: tsId, leaseId: lease, state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
    try j.upsert(trainingSetId: tsId, leaseId: lease, state: .crcOK, sqliteLocalPath: nil, contentHash: hash, lastError: nil)
    try j.upsert(trainingSetId: tsId, leaseId: lease, state: .unzipped, sqliteLocalPath: path, contentHash: hash, lastError: nil)
    try j.upsert(trainingSetId: tsId, leaseId: lease, state: .dbVerified, sqliteLocalPath: path, contentHash: hash, lastError: nil)
    try j.upsert(trainingSetId: tsId, leaseId: lease, state: .stored, sqliteLocalPath: path, contentHash: hash, lastError: nil)
    try j.upsert(trainingSetId: tsId, leaseId: lease, state: .confirmPending, sqliteLocalPath: path, contentHash: hash, lastError: nil)
}

@Test("runLaunchRecovery 恰一次：连调两次 → confirmCount==N 非 2N（router didRunLaunchRecovery 门）")
func launchRecovery_exactlyOnce() async throws {
    let counting = CountingAPIClient()
    let f = Self.makeRouter(api: counting)
    try Self.seedConfirmPending(f.journal, tsId: 1, lease: "L1")
    await f.router.runLaunchRecovery()
    await f.router.runLaunchRecovery()
    #expect(await counting.confirmCount == 1)
}

@Test("sessionEnded normal recordId → activeModal=.settlement(record)")
func sessionEnded_normalShowsSettlement() async {
    let f = Self.makeRouter(seedRecords: [Self.record(id: 9)])
    await f.router.startTraining()                 // activeTraining = normal
    await f.router.sessionEnded(recordId: 9)
    if case .settlement(let r)? = f.router.activeModal { #expect(r.id == 9) } else { Issue.record("expected .settlement") }
}

@Test("sessionEnded normal nil（finalize 抛）→ errorMessage + activeTraining nil")
func sessionEnded_normalNilError() async {
    let f = Self.makeRouter()
    await f.router.startTraining()
    await f.router.sessionEnded(recordId: nil)     // mode==normal + nil → 入账失败分支
    #expect(f.router.activeTraining == nil)
    #expect(f.router.errorMessage != nil)
}

@Test("sessionEnded replay nil → retreat：activeTraining nil 且无 settlement")
func sessionEnded_replayRetreat() async {
    let f = Self.makeRouter(seedRecords: [Self.record(id: 4)])
    await f.router.replay(id: 4)                    // activeTraining = replay
    await f.router.sessionEnded(recordId: nil)
    #expect(f.router.activeTraining == nil)
    #expect(f.router.activeModal == nil)
}

@Test("teardown：replay 结束后能立即再 startTraining（证 reader 已 endSession 关闭）")
func sessionEnded_replayTearsDownReader() async {
    let f = Self.makeRouter(seedRecords: [Self.record(id: 4)])
    await f.router.replay(id: 4)
    await f.router.sessionEnded(recordId: nil)      // retreat 须 endAfterSettlement
    await f.router.startTraining()                  // 若 reader 未关 → coordinator 抛 → activeTraining nil
    #expect(f.router.activeTraining != nil)
}

@Test("confirmSettlement → activeTraining nil + modal nil + reload")
func confirmSettlement_clears() async {
    let f = Self.makeRouter(seedRecords: [Self.record(id: 9)])
    await f.router.startTraining()
    await f.router.sessionEnded(recordId: 9)
    await f.router.confirmSettlement()
    #expect(f.router.activeTraining == nil)
    #expect(f.router.activeModal == nil)
}
```

- [ ] **Step 2：跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter AppRouter`
Expected: FAIL（`runLaunchRecovery`/`sessionEnded`/`confirmSettlement` 未定义）。

- [ ] **Step 3：写恢复 + 结算方法**

在 `AppRouter` 内加：
```swift
    public func runLaunchRecovery() async {
        guard !didRunLaunchRecovery else { return }   // 恰一次门：runner 每次全量重扫不去重，property 来自此门
        didRunLaunchRecovery = true                   // 同步置位（首次 await 前）防并发双跑
        await acceptance.retryPendingConfirmations()
        await loadHome()
    }

    public func sessionEnded(recordId: Int64?) async {
        let mode = activeTraining?.lifecycle.engine.flow.mode
        if let id = recordId {
            // Normal 正常结束：结算窗（reader 在结算期间保持开，confirm 时才关）
            do {
                let record = try recordRepo.loadRecordBundle(id: id).0
                activeModal = .settlement(record)
            } catch {
                await activeTraining?.lifecycle.endAfterSettlement()   // 取 record 失败也须关 reader
                setError(error); activeTraining = nil; await loadHome()
            }
        } else {
            // recordId==nil：replay 结束（retreat）或 normal finalize 失败——两者均须先关 reader
            await activeTraining?.lifecycle.endAfterSettlement()
            if mode == .normal { errorMessage = "结算入账失败，请重试" }   // replay 不报错（正常 retreat）
            activeTraining = nil
            await loadHome()
        }
    }

    public func confirmSettlement() async {
        await activeTraining?.lifecycle.endAfterSettlement()
        activeModal = nil
        activeTraining = nil
        await loadHome()
    }
```

- [ ] **Step 4：跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter AppRouter`
Expected: PASS（全部 router 用例）。**注**：若 `launchRecovery_exactlyOnce` 因 journal 状态机 upsert 报错（如 `.crcOK` 需 hash），调整 seed helper 各 upsert 的 path/hash 满足 `validateInvariants`（`.stored`/`.confirmPending` 需 path；`.stored` 需 8-char hex）。

- [ ] **Step 5：commit**

```bash
git add -A && git commit -m "顺位11 Task3：AppRouter 启动恢复(恰一次)+结算路由(retreat/teardown)+confirm"
```

---

## Task 4：AppConfig + AppContainer（Persistence 组合根）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/AppConfig.swift`
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerTests.swift`

- [ ] **Step 1：写失败测试**

创建 `AppContainerTests.swift`：
```swift
import Testing
import Foundation
@testable import KlineTrainerPersistence
import KlineTrainerContracts

@MainActor
@Suite("AppContainer")
struct AppContainerTests {
    static func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("有效 config → 依赖图实例化（router 可达）+ 不抛")
    func validConfig_buildsGraph() throws {
        let dir = Self.tmpDir()
        let cfg = AppConfig(dbPath: dir.appendingPathComponent("app.sqlite"),
                            cacheRootDir: dir.appendingPathComponent("cache"),
                            backendBaseURL: URL(string: "http://kline-trainer.local")!)
        let container = try AppContainer(config: cfg)
        _ = container.router          // 预建 router 可达
        _ = container.coordinator
        _ = container.acceptance
    }

    @Test("DB 路径不可写 → init throws（DefaultAppDB 上抛）")
    func badDBPath_throws() {
        let cfg = AppConfig(dbPath: URL(fileURLWithPath: "/nonexistent-root-xyz/app.sqlite"),
                            cacheRootDir: FileManager.default.temporaryDirectory,
                            backendBaseURL: URL(string: "http://x.local")!)
        #expect(throws: (any Error).self) { _ = try AppContainer(config: cfg) }
    }
}
```

- [ ] **Step 2：跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter AppContainer`
Expected: FAIL（`AppConfig`/`AppContainer` 未定义）。

- [ ] **Step 3：写 AppConfig + AppContainer**

创建 `AppConfig.swift`：
```swift
import Foundation

public struct AppConfig: Sendable {
    public let dbPath: URL
    public let cacheRootDir: URL
    public let backendBaseURL: URL
    public init(dbPath: URL, cacheRootDir: URL, backendBaseURL: URL) {
        self.dbPath = dbPath
        self.cacheRootDir = cacheRootDir
        self.backendBaseURL = backendBaseURL
    }
}
```

创建 `AppContainer.swift`：
```swift
// Wave 2 顺位 11 — 生产组合根（spec 2026-06-08 §4.2）。
// 构造全部 Default* 具体依赖（只能落 Persistence，因 Contracts 不可 import Persistence）+ 预建 AppRouter。
import Foundation
import KlineTrainerContracts

@MainActor                          // 持 @MainActor props（settings/coordinator/router）；MainActor-confined（刻意非 Sendable）
public final class AppContainer {
    public let api: any APIClient
    public let db: any AppDB
    public let cache: any CacheManager
    public let settings: SettingsStore
    public let acceptance: DownloadAcceptanceRunner
    public let coordinator: TrainingSessionCoordinator
    public let router: AppRouter

    public init(config: AppConfig) throws {
        let api = DefaultAPIClient(baseURL: config.backendBaseURL)
        let db = try DefaultAppDB(dbPath: config.dbPath)                  // 唯一 throws 点（migration/IO）
        let cache = DefaultFileSystemCacheManager(cacheRoot: config.cacheRootDir)
        let dbFactory = DefaultTrainingSetDBFactory()
        let settings = SettingsStore(settingsDAO: db)                     // db 同时是 SettingsDAO
        let acceptance = DownloadAcceptanceRunner(
            api: api, cache: cache, dbFactory: dbFactory, journal: db,
            integrity: DefaultZipIntegrityVerifier(), extractor: DefaultZipExtractor(),
            dataVerifier: DefaultTrainingSetDataVerifier(), cleaner: DefaultDownloadAcceptanceCleaner())
        let coordinator = TrainingSessionCoordinator(
            dbFactory: dbFactory, recordRepo: db, pendingRepo: db,
            settingsDAO: db, cache: cache, settings: settings)
        let router = AppRouter(coordinator: coordinator, settings: settings, acceptance: acceptance,
                               recordRepo: db, pendingRepo: db, cache: cache)
        self.api = api; self.db = db; self.cache = cache; self.settings = settings
        self.acceptance = acceptance; self.coordinator = coordinator; self.router = router
    }
}
```

- [ ] **Step 4：跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter AppContainer`
Expected: PASS。**注**：若 `validConfig_buildsGraph` 因 cache 目录不存在报错（`DefaultFileSystemCacheManager` 可能要求 cacheRoot 存在），在 AppContainer 构造 cache 前 `try? FileManager.default.createDirectory(at: config.cacheRootDir, withIntermediateDirectories: true)`；并核实 DefaultAppDB 是否自建父目录，否则同样先建 `config.dbPath.deletingLastPathComponent()`。

- [ ] **Step 5：跑全量 swift test 确认无回归**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: 全绿（既有 ~6xx 测 + 新增 router/container 测）。

- [ ] **Step 6：commit**

```bash
git add -A && git commit -m "顺位11 Task4：AppConfig + AppContainer 组合根（Persistence）+ 图实例化测试"
```

---

## Task 5：AppRootView（Contracts SwiftUI 薄壳）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift`

- [ ] **Step 1：写 AppRootView（无 host 测，靠 Catalyst build；含 `#Preview`）**

创建 `App/AppRootView.swift`：
```swift
// Wave 2 顺位 11 — 生产根视图薄壳（spec 2026-06-08 §4.4）。
// 不含路由逻辑：全部 delegate AppRouter；只吃 Contracts 抽象（不吃 AppContainer）。
#if canImport(UIKit)
import SwiftUI

public struct AppRootView: View {
    @State private var router: AppRouter
    private let settings: SettingsStore
    private let api: any APIClient
    private let cache: any CacheManager
    private let acceptance: DownloadAcceptanceRunner

    public init(router: AppRouter, settings: SettingsStore, api: any APIClient,
                cache: any CacheManager, acceptance: DownloadAcceptanceRunner) {
        self._router = State(initialValue: router)
        self.settings = settings; self.api = api; self.cache = cache; self.acceptance = acceptance
    }

    private var trainingBinding: Binding<Bool> {
        Binding(get: { router.activeTraining != nil },
                set: { if !$0 { Task { await router.exitTraining() } } })   // 系统返回键已隐藏，仅程序化 pop
    }

    public var body: some View {
        NavigationStack {
            HomeView(content: router.homeContent,
                     onStartTraining: { Task { await router.startTraining() } },
                     onContinueTraining: { Task { await router.continueTraining() } },
                     onSelectRecord: { id in router.selectRecord(id: id) },
                     onOpenSettings: { router.openSettings() })
                .navigationDestination(isPresented: trainingBinding) {
                    if let t = router.activeTraining {
                        TrainingView(lifecycle: t.lifecycle,
                                     onExit: { Task { await router.exitTraining() } },
                                     onSessionEnded: { id in Task { await router.sessionEnded(recordId: id) } })
                            .navigationBarBackButtonHidden(true)            // 抑制系统返回+back-swipe，强制经「返回」按钮 teardown
                    }
                }
        }
        .sheet(item: $router.activeModal) { modal in
            switch modal {
            case .settings:
                SettingsPanel(settings: settings, api: api, cache: cache, acceptance: acceptance)
            case .history(let r):
                HistoryActionSheet(record: r,
                                   onReview: { Task { await router.review(id: r.id ?? -1) } },
                                   onReplay: { Task { await router.replay(id: r.id ?? -1) } },
                                   onCancel: { router.activeModal = nil })
            case .settlement(let r):
                SettlementView(record: r, onConfirm: { Task { await router.confirmSettlement() } })
            }
        }
        .alert("出错了", isPresented: Binding(get: { router.errorMessage != nil },
                                            set: { if !$0 { router.clearError() } })) {
            Button("好", role: .cancel) { router.clearError() }
        } message: { Text(router.errorMessage ?? "") }
        .task { await router.runLaunchRecovery() }
    }
}
#endif
```
**注**：`onSelectRecord`/`HistoryActionSheet` 用 `r.id ?? -1`——持久 record 恒有 id；review/replay 经 `coordinator.review(recordId:)` 取 `Int64`。HomeView/HistoryActionSheet 的 onReview 回调按既有签名（PR #89/#72）；若 onReview 不带参由 sheet 内部触发，则 `r` 由 capture 提供（已 capture）。

- [ ] **Step 2：AppRouter 加 `clearError()`**

在 `AppRouter` 内加：
```swift
    public func clearError() { errorMessage = nil }
```

- [ ] **Step 3：本地 Catalyst build 验证编译**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived 2>&1 | tail -15`
Expected: `** TEST BUILD SUCCEEDED **`，无 error/warning。若 HomeView/SettlementView/HistoryActionSheet/SettingsPanel 的 init 标签与 spec §一不符，按编译器报错对齐真实签名（见各 UI 文件）。

- [ ] **Step 4：commit**

```bash
git add -A && git commit -m "顺位11 Task5：AppRootView SwiftUI 根壳（NavigationStack+互斥 sheet+启动 task）"
```

---

## Task 6：app entry 替换 + pbxproj 接线 + shared scheme（xcodeproj）

**Files:**
- Modify: `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift`
- Create: `ios/KlineTrainer/KlineTrainer/AppLaunchErrorView.swift`
- Delete: `ios/KlineTrainer/KlineTrainer/ContentView.swift`
- Modify: `ios/KlineTrainer/KlineTrainer.xcodeproj/project.pbxproj`
- Create: `ios/KlineTrainer/KlineTrainer.xcodeproj/xcshareddata/xcschemes/KlineTrainer.xcscheme`

- [ ] **Step 1：替换 KlineTrainerApp.swift**

```swift
import SwiftUI
import KlineTrainerContracts
import KlineTrainerPersistence

@main
struct KlineTrainerApp: App {
    @State private var container: AppContainer?
    @State private var initError: Error?

    init() {
        do {
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let cfg = AppConfig(dbPath: support.appendingPathComponent("app.sqlite"),
                                cacheRootDir: caches.appendingPathComponent("training-sets"),
                                backendBaseURL: URL(string: "http://kline-trainer.local")!)  // TODO(NAS) PR11-R1：部署后替换
            _container = State(initialValue: try AppContainer(config: cfg))
        } catch {
            _initError = State(initialValue: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let c = container {
                AppRootView(router: c.router, settings: c.settings, api: c.api, cache: c.cache, acceptance: c.acceptance)
            } else {
                AppLaunchErrorView(message: (initError as? AppError)?.userMessage ?? "应用数据初始化失败")
            }
        }
    }
}
```
**注**：`App` 协议成员在 SwiftUI 是 `@MainActor` 隔离 → `init()` 可调 `@MainActor AppContainer.init`。若 Swift 6 报 init 非 MainActor，在 `init` 前加 `@MainActor`（`@MainActor init()`）。

- [ ] **Step 2：建 AppLaunchErrorView.swift**

```swift
import SwiftUI

struct AppLaunchErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
            Text("启动失败").font(.headline)
            Text(message).font(.callout).multilineTextAlignment(.center)
        }
        .padding()
    }
}
```

- [ ] **Step 3：删 ContentView.swift**

```bash
git rm ios/KlineTrainer/KlineTrainer/ContentView.swift
```

- [ ] **Step 4：pbxproj 加本地 SPM 包依赖**（基于真实 object ID，见 spec §一/explore）

按以下 5 处编辑 `project.pbxproj`（新 object ID 用 24-hex；下用 `AA00…0001`~`AA00…0005`，确保仓内唯一）：

(a) `PBXBuildFile` section（GRDB build file 旁）加两行：
```
		AA00000000000000000001 /* KlineTrainerContracts in Frameworks */ = {isa = PBXBuildFile; productRef = AA00000000000000000003 /* KlineTrainerContracts */; };
		AA00000000000000000002 /* KlineTrainerPersistence in Frameworks */ = {isa = PBXBuildFile; productRef = AA00000000000000000004 /* KlineTrainerPersistence */; };
```

(b) `PBXFrameworksBuildPhase`（`files = ( ... )` 内 GRDB 行后）加：
```
			AA00000000000000000001 /* KlineTrainerContracts in Frameworks */,
			AA00000000000000000002 /* KlineTrainerPersistence in Frameworks */,
```

(c) target 的 `packageProductDependencies = ( ... )`（GRDB 行后）加：
```
				AA00000000000000000003 /* KlineTrainerContracts */,
				AA00000000000000000004 /* KlineTrainerPersistence */,
```

(d) PBXProject 的 `packageReferences = ( ... )`（GRDB remote ref 行后）加本地包：
```
				AA00000000000000000005 /* XCLocalSwiftPackageReference "Contracts" */,
```

(e) 文件尾新增两个 section（紧邻既有 `XCRemoteSwiftPackageReference`/`XCSwiftPackageProductDependency` section）：
```
/* Begin XCLocalSwiftPackageReference section */
		AA00000000000000000005 /* XCLocalSwiftPackageReference "Contracts" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ../Contracts;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section（追加，不重复既有 GRDB 块）*/
		AA00000000000000000003 /* KlineTrainerContracts */ = {
			isa = XCSwiftPackageProductDependency;
			package = AA00000000000000000005 /* XCLocalSwiftPackageReference "Contracts" */;
			productName = KlineTrainerContracts;
		};
		AA00000000000000000004 /* KlineTrainerPersistence */ = {
			isa = XCSwiftPackageProductDependency;
			package = AA00000000000000000005 /* XCLocalSwiftPackageReference "Contracts" */;
			productName = KlineTrainerPersistence;
		};
```
（既有 `XCSwiftPackageProductDependency` section 已存在 GRDB 块——把上面两个 product 块并入该 section，勿重复 `/* Begin/End */` 标记。）

- [ ] **Step 5：建 shared scheme**

创建 `xcshareddata/xcschemes/KlineTrainer.xcscheme`（standard build+test scheme，BuildableReference 指向 KlineTrainer app target，BlueprintIdentifier = target ID `CFF11F9C2F90FB4300467161`，BlueprintName/BuildableName = `KlineTrainer.app`，container = `container:KlineTrainer.xcodeproj`）。最小可用 scheme（BuildAction + LaunchAction 即可）。

- [ ] **Step 6：本地 app build 验证接线**（CI 不覆盖 app target，本地是唯一编译闸门）

Run: `cd ios/KlineTrainer && xcodebuild build -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/app-derived 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`。若 pbxproj 解析报错（synchronized group/package 引用），逐处对照真实 GRDB 块结构修正；若本地 Xcode 无法解析新本地包，记 PR11-R3（本地 build 失败但 Contracts 侧全 host-test+Catalyst 覆盖）并在 acceptance 如实标注。

- [ ] **Step 7：commit**

```bash
git add -A && git commit -m "顺位11 Task6：替换 app entry 接生产依赖图 + pbxproj 本地包 + shared scheme + DB-fail 错误屏"
```

---

## Task 7：整体验证 + acceptance（verification-before-completion）

**Files:**
- Create: `docs/acceptance/2026-06-08-wave2-pr11-composition-root.md`

- [ ] **Step 1：全量 swift test**

Run: `cd ios/Contracts && swift test 2>&1 | tail -6`
Expected: 全绿，0 failures（既有 + AppRouter*（~14 用例）+ AppContainer（2 用例））。**贴真实输出到 acceptance doc。**

- [ ] **Step 2：Catalyst build-for-testing（镜像 CI 闸门）**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived 2>&1 | grep -E "TEST BUILD SUCCEEDED|error:|warning:" | tail`
Expected: `** TEST BUILD SUCCEEDED **`，无 error/warning。

- [ ] **Step 3：本地 app build（Task6 已跑，复核）**

Run: `cd ios/KlineTrainer && xcodebuild build -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/app-derived 2>&1 | grep -E "BUILD SUCCEEDED|error:" | tail`
Expected: `** BUILD SUCCEEDED **`（或如失败按 PR11-R3 如实记录）。

- [ ] **Step 4：写 acceptance checklist**

创建 `docs/acceptance/2026-06-08-wave2-pr11-composition-root.md`：非 coder 可执行（中文 action/expected/pass-fail；禁忌词见 `.claude/workflow-rules.json`），覆盖：
  - 依赖图实例化（AppContainerTests 通过 + 本地 app build 成功）。
  - 从启动可达训练/设置（AppRouterTests start/review/replay/openSettings + 手动运行时验收 runbook 占位）。
  - 启动孤儿确认恢复（launchRecovery_exactlyOnce 通过）。
  - residuals PR11-R1（baseURL placeholder）/ PR11-R2（replay 结算 deferred）/ PR11-R3（app target 无 CI）。
  - 含「C2/C7/C8 运行时 + 从启动可达」手动 simulator 验收条目（沿用 C8b/U2 runbook 范式；运行时部分若无设备则标 deferred 运行时验收）。

- [ ] **Step 5：commit**

```bash
git add -A && git commit -m "顺位11 Task7：整体验证（swift test + Catalyst + app build）+ acceptance checklist"
```

---

## Self-Review 检查表（writing-plans 收尾）

- **spec 覆盖**：组合根(Task4) / 路由(Task1-3) / 根视图(Task5) / app entry+pbxproj+scheme(Task6) / 启动恢复(Task3) / 结算 retreat(Task3) / CI gap(Task6-7) / 验收映射(Task7) ——全 spec 章节有对应 task。
- **占位扫描**：无 TBD；test double/fixture/pbxproj 均给真实代码（journal seed、CountingAPIClient、pbxproj object ID）。
- **类型一致**：`AppRouter`/`AppContainer`/`AppConfig`/`Modal`/`ActiveTraining` 跨 task 命名一致；`activeTraining`/`activeModal`/`homeContent`/`errorMessage`/`records` 状态名贯穿；方法名 `startTraining/continueTraining/selectRecord/review/replay/openSettings/exitTraining/sessionEnded/confirmSettlement/runLaunchRecovery/loadHome/clearError/emptyHome` 一致。
- **风险点**（实施时核对真实签名，编译器/Catalyst 兜底）：HomeView/SettlementView/HistoryActionSheet/SettingsPanel init 标签（Task5）；journal upsert validateInvariants 顺序（Task3）；DefaultFileSystemCacheManager/DefaultAppDB 是否自建目录（Task4）；pbxproj 本地包格式（Task6）；`TrainingMode` 枚举名与 `.normal/.review/.replay`（Task2-3）。
