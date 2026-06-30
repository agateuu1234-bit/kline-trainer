# Replay 续局 + 复盘可步进重演 实现 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 replay 中途状态可持久化/续局（单槽 `pending_replay`），历史弹窗 replay 钮文案「再次训练」↔「返回训练」、去「取消」钮；复盘改可步进只读重演（起点=训练起 tick + 「快进到结尾」）。

**Architecture:** 镜像已有 Normal 暂存机制建独立 replay 暂存槽（不碰 Normal 路径）；replay 复用既有 autosave 协程（仅放开入口门控）；复盘改 `ReviewFlow` 能力矩阵 + 新 `jumpToEnd` + 新 review 专用控件条；K线/标记渐显自动（slice≤currentIdx）。

**Tech Stack:** Swift 6 / Swift Testing（`import Testing`，`@Test`/`#expect`）+ 部分 XCTest；GRDB（app.sqlite）；SwiftUI（UIKit-gated 部分走 Catalyst build）。

## Global Constraints

- `CONTRACT_VERSION` 1.7→**1.8**（`ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`）。仅本 PR bump 一次。
- **绝不修改** `ios/sql/app_schema_v1.sql` 与 `AppDBMigrations.v1_4_baselineDDL`（v1.4 冻结基线，CI `scripts/check_app_schema_drift.sh` 校验严格相等）。新表只走 migration 0006。
- 持久化 repo 方法 **sync `throws`**（不得 async）——`requestAutosave` 协程的 coalescing/fence 不变量依赖 save 同步（`TrainingSessionCoordinator.swift:87-90`）。
- 各 `TrainingFlowController` 实现**显式**写每个能力方法（不用协议默认；矩阵权威，沿用 E4 D2 教训）。
- ReviewFlow **`shouldShowSettlement` 保持 `false`**（`shouldAutoFinalize` 靠它抑制复盘到 maxTick 误结算；改了会破坏）。
- replay **不累积资金/不写 training_records/结算 ephemeral**；复盘**不持久进度**。
- 测试命令：host = `cd "ios/Contracts" && swift test`（过滤 `--filter <Name>`）。Catalyst 编译闸门见 Task B4/验收。
- 评审通道＝真 Codex：`.claude/scripts/codex-attest.sh --scope branch-diff --head worktree-feat+replay-resume-review-playback --base origin/main`。
- 每个 Task 末尾 commit；commit message 末行 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。

---

## 文件结构总览

**新增**
- `ios/Contracts/Sources/KlineTrainerContracts/Persistence/PendingReplayRepository.swift` — 协议
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingReplayRepositoryImpl.swift` — GRDB 静态实现
- `ios/Contracts/Sources/KlineTrainerContracts/UI/ReviewControlBar.swift` — 复盘控件条（内容 + 薄壳）

**修改**
- `TrainingEngine/TrainingFlowController.swift`（+`shouldPersistProgress` +`canJumpToEnd`；ReviewFlow `init(record:,startTick:)`/range/canAdvance）
- `TrainingEngine/TrainingEngine.swift`（`FlowInput.review(record:,startTick:)` + `make` `.review` 分支 + preview；+`jumpToEnd()`）
- `TrainingEngine/TrainingSessionCoordinator.swift`（deps/init、autosave 门、saveProgress 路由、replay startedAt、resumePendingReplay、hasResumableReplay、replaySettlementPayload async fence+clear、discard、review startTick）
- `AppState.swift`（+`PendingReplay`）
- `Models/Models.swift`（CONTRACT_VERSION）
- `PreviewFakes/InMemoryFakes.swift`（+`InMemoryPendingReplayRepository`）
- `KlineTrainerPersistence/Internal/AppDBMigrations.swift`（+0006）
- `KlineTrainerPersistence/DefaultAppDB.swift`（conform `PendingReplayRepository` + reset 清 replay）
- `KlineTrainerPersistence/AppContainer.swift`（注入）
- `App/AppRouter.swift`（replay 分流）
- `App/AppRootView.swift`（历史弹窗传 `hasResumableReplay`）
- `UI/HistoryActionSheet.swift`（去取消钮 + 文案切换）
- `UI/TrainingSessionLifecycle.swift`（`replaySettlementRecord()` async）
- `UI/TrainingView.swift`（review 控件条 + routeEndOfSession Task）

---

## Task A1: Flow 能力 `shouldPersistProgress()`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngine/TrainingFlowControllerTests.swift`（若已存在则追加；否则新建）

**Interfaces:**
- Produces: `TrainingFlowController.shouldPersistProgress() -> Bool`（Normal=true, Review=false, Replay=true）

- [ ] **Step 1: 写失败测试**（追加到 flow 测试文件；若新建则含 `import Testing` + `@testable import KlineTrainerContracts`）

```swift
@Test func shouldPersistProgress_matrix() {
    let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    #expect(NormalFlow(fees: fees, maxTick: 100).shouldPersistProgress() == true)
    #expect(ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: 100).shouldPersistProgress() == true)
    // Review 用最小 record 构造（finalTick 任意；B1 之后 init 增 startTick——见 Task B1，届时本行同步改）
    let rec = TrainingRecord(id: 1, trainingSetFilename: "x.sqlite", createdAt: 0, stockCode: "1", stockName: "n",
                             startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
                             maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 100)
    #expect(ReviewFlow(record: rec).shouldPersistProgress() == false)
}
```

- [ ] **Step 2: 跑测试确认失败** — `cd "ios/Contracts" && swift test --filter shouldPersistProgress_matrix` → FAIL（方法不存在，编译错）。

- [ ] **Step 3: 协议加方法 + 三 struct 实现**

`TrainingFlowController.swift` 协议块加一行（在 `shouldShowSettlement()` 附近）：
```swift
    func shouldPersistProgress() -> Bool
```
NormalFlow 实现块加：
```swift
    public func shouldPersistProgress() -> Bool { true }
```
ReviewFlow 实现块加：
```swift
    public func shouldPersistProgress() -> Bool { false }
```
ReplayFlow 实现块加：
```swift
    public func shouldPersistProgress() -> Bool { true }
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter shouldPersistProgress_matrix` → PASS。

- [ ] **Step 5: 全量 host 编译/测试不回归** — `cd "ios/Contracts" && swift test` → 0 失败（确认协议加方法未漏实现点）。

- [ ] **Step 6: commit**
```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngine/TrainingFlowControllerTests.swift
git commit -m "feat(A1): TrainingFlowController.shouldPersistProgress (N/R=true, Review=false)"
```

---

## Task A2: `PendingReplay` 模型 + 协议 + InMemory 替身

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift`（加 `PendingReplay`）
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/PendingReplayRepository.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`（加 `InMemoryPendingReplayRepository`，`#if DEBUG`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Persistence/PendingReplayTests.swift`（新建）

**Interfaces:**
- Produces:
  - `struct PendingReplay: Codable, Equatable, Sendable`（字段＝`PendingTraining` 去 `sessionKey` + 加 `recordId: Int64`）
  - `protocol PendingReplayRepository: Sendable { func saveReplay(_:) throws; func loadReplay() throws -> PendingReplay?; func clearReplay() throws }`
  - `final class InMemoryPendingReplayRepository: PendingReplayRepository`（含 `saveCount`、`failNextSaveReplay/failNextLoadReplay/failNextClearReplay`）

- [ ] **Step 1: 写失败测试**（`PendingReplayTests.swift`）
```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Test func pendingReplay_codableRoundTrip() throws {
    let p = PendingReplay(
        recordId: 42,
        trainingSetFilename: "a.sqlite", globalTickIndex: 7,
        upperPeriod: .m60, lowerPeriod: .daily,
        positionData: Data([1, 2, 3]), cashBalance: 99_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [],
        startedAt: 1_700_000_000, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000))
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(PendingReplay.self, from: data)
    #expect(back == p)
}

@Test func inMemoryPendingReplay_saveLoadClear() throws {
    let repo = InMemoryPendingReplayRepository()
    #expect(try repo.loadReplay() == nil)
    let p = PendingReplay(recordId: 5, trainingSetFilename: "b.sqlite", globalTickIndex: 1,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000))
    try repo.saveReplay(p)
    #expect(try repo.loadReplay() == p)
    #expect(repo.saveCount == 1)
    try repo.clearReplay()
    #expect(try repo.loadReplay() == nil)
}
```
> 注：`DrawdownAccumulator` 的真实初始化器以源码为准（implementer 用 `DrawdownAccumulator` 现有 init；上面 `peakCapital:` 仅示意，若签名不同改用真实 init）。

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter pendingReplay_codableRoundTrip` → FAIL（类型不存在）。

- [ ] **Step 3a: `AppState.swift` 加 `PendingReplay`**（紧邻 `PendingTraining` 之后）
```swift
public struct PendingReplay: Codable, Equatable, Sendable {
    public let recordId: Int64
    public let trainingSetFilename: String
    public let globalTickIndex: Int
    public let upperPeriod: Period
    public let lowerPeriod: Period
    public let positionData: Data
    public let cashBalance: Double
    public let feeSnapshot: FeeSnapshot
    public let tradeOperations: [TradeOperation]
    public let drawings: [DrawingObject]
    public let startedAt: Int64
    public let accumulatedCapital: Double
    public let drawdown: DrawdownAccumulator

    public init(
        recordId: Int64,
        trainingSetFilename: String,
        globalTickIndex: Int,
        upperPeriod: Period,
        lowerPeriod: Period,
        positionData: Data,
        cashBalance: Double,
        feeSnapshot: FeeSnapshot,
        tradeOperations: [TradeOperation],
        drawings: [DrawingObject],
        startedAt: Int64,
        accumulatedCapital: Double,
        drawdown: DrawdownAccumulator
    ) {
        self.recordId = recordId
        self.trainingSetFilename = trainingSetFilename
        self.globalTickIndex = globalTickIndex
        self.upperPeriod = upperPeriod
        self.lowerPeriod = lowerPeriod
        self.positionData = positionData
        self.cashBalance = cashBalance
        self.feeSnapshot = feeSnapshot
        self.tradeOperations = tradeOperations
        self.drawings = drawings
        self.startedAt = startedAt
        self.accumulatedCapital = accumulatedCapital
        self.drawdown = drawdown
    }
}
```

- [ ] **Step 3b: 新建 `Persistence/PendingReplayRepository.swift`**
```swift
// PendingReplayRepository.swift
// replay 续局单槽仓储（新需求10）。镜像 PendingTrainingRepository（sync throws，不得 async——
// autosave 协程 coalescing/fence 不变量依赖 save 同步，见 TrainingSessionCoordinator.swift:87-90）。

public protocol PendingReplayRepository: Sendable {
    func saveReplay(_: PendingReplay) throws
    func loadReplay() throws -> PendingReplay?
    func clearReplay() throws
}
```

- [ ] **Step 3c: `InMemoryFakes.swift` 加 fake**（紧邻 `InMemoryPendingTrainingRepository`，同 `#if DEBUG` 块内）
```swift
public final class InMemoryPendingReplayRepository: PendingReplayRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: PendingReplay?

    private var _failNextSaveReplay: AppError?
    public var failNextSaveReplay: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextSaveReplay }
        set { lock.lock(); defer { lock.unlock() }; _failNextSaveReplay = newValue }
    }
    private var _failNextClearReplay: AppError?
    public var failNextClearReplay: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextClearReplay }
        set { lock.lock(); defer { lock.unlock() }; _failNextClearReplay = newValue }
    }
    private var _failNextLoadReplay: AppError?
    public var failNextLoadReplay: AppError? {
        get { lock.lock(); defer { lock.unlock() }; return _failNextLoadReplay }
        set { lock.lock(); defer { lock.unlock() }; _failNextLoadReplay = newValue }
    }
    private var _saveCount = 0
    public var saveCount: Int { lock.lock(); defer { lock.unlock() }; return _saveCount }

    public init() {}

    public func saveReplay(_ p: PendingReplay) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextSaveReplay { _failNextSaveReplay = nil; throw e }
        pending = p
        _saveCount += 1
    }
    public func loadReplay() throws -> PendingReplay? {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextLoadReplay { _failNextLoadReplay = nil; throw e }
        return pending
    }
    public func clearReplay() throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextClearReplay { _failNextClearReplay = nil; throw e }
        pending = nil
    }
}
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter "pendingReplay_codableRoundTrip"` 和 `--filter "inMemoryPendingReplay_saveLoadClear"` → PASS。

- [ ] **Step 5: commit**
```bash
git add ios/Contracts/Sources/KlineTrainerContracts/AppState.swift ios/Contracts/Sources/KlineTrainerContracts/Persistence/PendingReplayRepository.swift ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift ios/Contracts/Tests/KlineTrainerContractsTests/Persistence/PendingReplayTests.swift
git commit -m "feat(A2): PendingReplay model + PendingReplayRepository + in-memory fake"
```

---

## Task A3: migration 0006 + CONTRACT bump + GRDB Impl + DefaultAppDB 接口

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`（1.7→1.8）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift`（加 0006）
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingReplayRepositoryImpl.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（conform `PendingReplayRepository`）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/PendingReplayPersistenceTests.swift`（新建）

**Interfaces:**
- Consumes: `PendingReplay`/`PendingReplayRepository`（A2）
- Produces: `DefaultAppDB: PendingReplayRepository`；migration `0006_v1.8_pending_replay`（`user_version=4`）

- [ ] **Step 1: 写失败测试**（用现有 persistence 测试的 in-memory GRDB 构造方式——mirror 现有 `PendingTraining` 持久化测试 / `AppDBFixture`；若有 helper 建空 app.sqlite 并跑 migrator 用之）
```swift
import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerContracts
@testable import KlineTrainerPersistence

@MainActor
@Test func migration0006_createsTable_userVersion4() throws {
    let queue = try DatabaseQueue()        // in-memory
    try AppDBMigrations.makeMigrator().migrate(queue)
    let uv = try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
    #expect(uv == 4)
    let exists = try queue.read {
        try Int.fetchOne($0, sql:
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='pending_replay'")
    }
    #expect(exists == 1)
}

@MainActor
@Test func pendingReplayImpl_roundTripAndClear() throws {
    let queue = try DatabaseQueue()
    try AppDBMigrations.makeMigrator().migrate(queue)
    let p = PendingReplay(recordId: 9, trainingSetFilename: "z.sqlite", globalTickIndex: 3,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]), cashBalance: 88_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 123, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000))
    try queue.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: p) }
    let back = try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }
    #expect(back == p)
    try queue.write { try PendingReplayRepositoryImpl.clearReplay($0) }
    #expect(try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) } == nil)
}
```

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter migration0006_createsTable_userVersion4` → FAIL。

- [ ] **Step 3a: CONTRACT bump** — `Models/Models.swift:7`：`public let CONTRACT_VERSION = "1.7"` → `"1.8"`。

- [ ] **Step 3b: migration 0006**（`AppDBMigrations.makeMigrator()` 内 `return migrator` 之前，紧接 0005 之后）
```swift
        // 0006：replay 续局持久化（新需求10，v1.8）。additive：新建 pending_replay 单行表
        // （CHECK(id=1)），与 pending_training 同构 + record_id（来源历史记录），无 session_key
        // （replay 不写 training_records、无 finalize 幂等）。**只走 migration，不动 v1_4_baselineDDL/
        // app_schema_v1.sql（v1.4 冻结基线，drift-checked）**。fresh install 经 0001→…→0006 链建全表。
        migrator.registerMigration("0006_v1.8_pending_replay") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pending_replay (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    record_id INTEGER NOT NULL,
                    training_set_filename TEXT NOT NULL,
                    global_tick_index INTEGER NOT NULL,
                    upper_period TEXT NOT NULL,
                    lower_period TEXT NOT NULL,
                    position_data TEXT NOT NULL,
                    fee_snapshot TEXT NOT NULL,
                    trade_operations TEXT NOT NULL,
                    drawings TEXT NOT NULL,
                    started_at INTEGER NOT NULL,
                    accumulated_capital REAL NOT NULL,
                    cash_balance REAL NOT NULL,
                    drawdown TEXT NOT NULL
                )
                """)
            try db.execute(sql: "PRAGMA user_version = 4")
        }
```

- [ ] **Step 3c: 新建 `PendingReplayRepositoryImpl.swift`**（镜像 `PendingTrainingRepositoryImpl`；列含 record_id、无 session_key）
```swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// PendingReplayRepository 静态方法实现。pending_replay 表 CHECK(id = 1)：永远 0 或 1 行。
/// 镜像 PendingTrainingRepositoryImpl（去 session_key，加 record_id）。
enum PendingReplayRepositoryImpl {

    static func saveReplay(_ db: Database, replay p: PendingReplay) throws {
        let positionB64 = p.positionData.base64EncodedString()
        let feeJSON = try RecordRepositoryImpl.jsonEncode(p.feeSnapshot)
        let opsJSON = try RecordRepositoryImpl.jsonEncode(p.tradeOperations)
        let drawingsJSON = try RecordRepositoryImpl.jsonEncode(p.drawings)
        let drawdownJSON = try RecordRepositoryImpl.jsonEncode(p.drawdown)

        try db.execute(sql: """
            INSERT OR REPLACE INTO pending_replay
              (id, record_id, training_set_filename, global_tick_index, upper_period, lower_period,
               position_data, fee_snapshot, trade_operations, drawings,
               started_at, accumulated_capital, cash_balance, drawdown)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                p.recordId, p.trainingSetFilename, p.globalTickIndex,
                p.upperPeriod.rawValue, p.lowerPeriod.rawValue,
                positionB64, feeJSON, opsJSON, drawingsJSON,
                p.startedAt, p.accumulatedCapital, p.cashBalance, drawdownJSON
            ])
    }

    static func loadReplay(_ db: Database) throws -> PendingReplay? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT * FROM pending_replay WHERE id = 1") else { return nil }
        let positionB64: String = row["position_data"]
        guard let positionData = Data(base64Encoded: positionB64) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let feeJSON: String = row["fee_snapshot"]
        let opsJSON: String = row["trade_operations"]
        let drawingsJSON: String = row["drawings"]
        let drawdownJSON: String = row["drawdown"]
        let upperRaw: String = row["upper_period"]
        let lowerRaw: String = row["lower_period"]
        guard let upper = Period(rawValue: upperRaw),
              let lower = Period(rawValue: lowerRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let fee: FeeSnapshot = try RecordRepositoryImpl.jsonDecode(feeJSON, as: FeeSnapshot.self)
            .sanitizedForLegacyCorruption()  // WB-1：清除 legacy 负/非有限 commissionRate
        let ops: [TradeOperation] = try RecordRepositoryImpl.jsonDecode(opsJSON, as: [TradeOperation].self)
        let drawings: [DrawingObject] = try RecordRepositoryImpl.jsonDecode(drawingsJSON, as: [DrawingObject].self)
        let drawdown: DrawdownAccumulator = try RecordRepositoryImpl.jsonDecode(drawdownJSON, as: DrawdownAccumulator.self)
        return PendingReplay(
            recordId: row["record_id"],
            trainingSetFilename: row["training_set_filename"],
            globalTickIndex: row["global_tick_index"],
            upperPeriod: upper, lowerPeriod: lower,
            positionData: positionData,
            cashBalance: row["cash_balance"],
            feeSnapshot: fee,
            tradeOperations: ops, drawings: drawings,
            startedAt: row["started_at"],
            accumulatedCapital: row["accumulated_capital"],
            drawdown: drawdown
        )
    }

    static func clearReplay(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM pending_replay WHERE id = 1")
    }
}
```

- [ ] **Step 3d: `DefaultAppDB.swift` conform `PendingReplayRepository`**（紧邻现有 pending_training 三方法，镜像其错误映射）
```swift
public func saveReplay(_ p: PendingReplay) throws {
    do {
        try dbQueue.write { db in
            try PendingReplayRepositoryImpl.saveReplay(db, replay: p)
        }
    } catch let appErr as AppError { throw appErr }
    catch { throw PersistenceErrorMapping.translate(error) }
}

public func loadReplay() throws -> PendingReplay? {
    do {
        return try dbQueue.read { db in
            try PendingReplayRepositoryImpl.loadReplay(db)
        }
    } catch let appErr as AppError { throw appErr }
    catch { throw PersistenceErrorMapping.translate(error) }
}

public func clearReplay() throws {
    do {
        try dbQueue.write { db in
            try PendingReplayRepositoryImpl.clearReplay(db)
        }
    } catch let appErr as AppError { throw appErr }
    catch { throw PersistenceErrorMapping.translate(error) }
}
```
并在 `DefaultAppDB` 的类型声明处加 `PendingReplayRepository` 一致性（找 `: ... PendingTrainingRepository ...` 处追加 `, PendingReplayRepository`）。

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter migration0006_createsTable_userVersion4` 和 `--filter pendingReplayImpl_roundTripAndClear` → PASS。

- [ ] **Step 5: 全量 host + schema-drift 不回归** — `cd "ios/Contracts" && swift test` → 0 失败；`bash scripts/check_app_schema_drift.sh`（若该脚本可本地跑）→ PASS（确认未碰 baseline）。

- [ ] **Step 6: commit**
```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingReplayRepositoryImpl.swift ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/PendingReplayPersistenceTests.swift
git commit -m "feat(A3): pending_replay migration 0006 + impl + DefaultAppDB conformance + CONTRACT 1.8"
```

---

## Task A4: Coordinator 依赖 + autosave 门 + saveProgress 路由 + replay startedAt

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngine/CoordinatorReplayPersistenceTests.swift`（新建）

**Interfaces:**
- Consumes: `PendingReplayRepository`（A2）、`shouldPersistProgress()`（A1）、`InMemoryPendingReplayRepository`（A2）
- Produces: `TrainingSessionCoordinator` 新增 `pendingReplayRepo` 依赖；`saveProgress` 对 replay 写 `pending_replay`；`requestAutosave` 对 replay/normal 启用、review no-op。

> **测试构造说明**：mirror 现有 coordinator 测试的 helper（用 in-memory fakes 组装 coordinator + 用 fixture reader/cache 让 `replay(recordId:)` 可跑）。下方测试用 `InMemoryPendingReplayRepository` 注入并断言其 `saveCount`/`loadReplay()`。implementer 复用现有 coordinator 测试 setUp 模式（已有 replay() 测试，照搬其会话装配）。

- [ ] **Step 1: 写失败测试**
```swift
@MainActor
@Test func saveProgress_replay_writesPendingReplay() async throws {
    let h = try CoordinatorTestHarness.make()           // 复用现有 coordinator 测试 harness
    let engine = try await h.coordinator.replay(recordId: h.seededRecordId)
    // 模拟前进一根触发脏状态后保存
    engine.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: engine)
    let saved = try h.pendingReplayRepo.loadReplay()
    #expect(saved?.recordId == h.seededRecordId)
    #expect(saved?.globalTickIndex == engine.tick.globalTickIndex)
    // normal 槽不被污染
    #expect(try h.pendingRepo.loadPending() == nil)
}

@MainActor
@Test func requestAutosave_replayEnabled_reviewNoOp() async throws {
    let h = try CoordinatorTestHarness.make()
    let replayEngine = try await h.coordinator.replay(recordId: h.seededRecordId)
    h.coordinator.requestAutosave(engine: replayEngine, immediate: true)
    await h.coordinator.drainAutosaveForTesting()
    #expect(h.pendingReplayRepo.saveCount >= 1)

    await h.coordinator.endSession()
    let reviewEngine = try await h.coordinator.review(recordId: h.seededRecordId)
    let before = h.pendingReplayRepo.saveCount
    h.coordinator.requestAutosave(engine: reviewEngine, immediate: true)
    await h.coordinator.drainAutosaveForTesting()
    #expect(h.pendingReplayRepo.saveCount == before)   // review 不存
}
```
> 若现无 `CoordinatorTestHarness`，implementer 以现有 coordinator 测试的 setUp 内联等价构造（关键：注入 `InMemoryPendingReplayRepository` 并 seed 一条 record + fixture training-set 让 `replay()` 成功）。

- [ ] **Step 2: 跑测试确认失败** — FAIL（init 签名不含 pendingReplayRepo / saveProgress 不路由）。

- [ ] **Step 3a: 加依赖 + init 参数**
`TrainingSessionCoordinator.swift` 存储属性区（紧邻 `pendingRepo`）加：
```swift
    private let pendingReplayRepo: PendingReplayRepository  // 新需求10：replay 续局单槽
```
init 签名加参数（在 `pendingRepo:` 之后）+ 体内赋值：
```swift
                pendingRepo: PendingTrainingRepository,
                pendingReplayRepo: PendingReplayRepository,
```
```swift
        self.pendingReplayRepo = pendingReplayRepo
```

- [ ] **Step 3b: autosave 入口门**（L79）
```swift
        guard !terminating, engine.flow.mode == .normal else { return }
```
→
```swift
        guard !terminating, engine.flow.shouldPersistProgress() else { return }
```

- [ ] **Step 3c: `saveProgress` 路由**（L326-327 guard + 体内分流）
将 `guard engine.flow.mode == .normal else { return }` 改为 `guard engine.flow.shouldPersistProgress() else { return }`；在构造/写库处按 mode 分流：normal 走原 `PendingTraining`+`pendingRepo.savePending`；replay 走新分支：
```swift
        if engine.flow.mode == .replay {
            guard let recordId = activeRecord?.id, let started = activeStartedAt else { return }
            let replay = PendingReplay(
                recordId: recordId,
                trainingSetFilename: <file.filename，同 normal 取活跃文件>,
                globalTickIndex: engine.tick.globalTickIndex,
                upperPeriod: engine.upperPanel.period,
                lowerPeriod: engine.lowerPanel.period,
                positionData: <encodePosition(engine.position)，同 normal>,
                cashBalance: max(0, engine.cashBalance),
                feeSnapshot: engine.fees,
                tradeOperations: engine.tradeOperations,
                drawings: engine.drawings,
                startedAt: started,
                accumulatedCapital: engine.initialCapital,
                drawdown: engine.drawdown)
            try pendingReplayRepo.saveReplay(replay)
            return
        }
        // 以下为原 normal 分支（一字不改）...
```
> implementer：`<...>` 处复用 `saveProgress` 现有 normal 分支取 `activeFile`/`encodePosition` 的同款代码（同方法内已有，照抄字段）。replay 不需要 `activeSessionKey`。

- [ ] **Step 3d: `replay(recordId:)` 设 startedAt** — 在 `replay(recordId:)` 装配成功、设 `activeRecord = record` 附近加：
```swift
        activeStartedAt = now()    // 新需求10：replay 会话起始，供 PendingReplay.started_at
```
（**不**前置 `clearReplay`——单槽靠首存 INSERT OR REPLACE 覆盖；失败装配不丢旧档。）

- [ ] **Step 3e: AppContainer 注入** — `AppContainer.swift` 构造处：
```swift
let coordinator = TrainingSessionCoordinator(
    dbFactory: dbFactory, recordRepo: db, pendingRepo: db,
    pendingReplayRepo: db,
    finalization: db,
    settingsDAO: db, cache: cache, settings: settings)
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter saveProgress_replay_writesPendingReplay` 和 `--filter requestAutosave_replayEnabled_reviewNoOp` → PASS。

- [ ] **Step 5: 全量 host 不回归** — `cd "ios/Contracts" && swift test` → 0 失败（normal autosave/saveProgress 回归不变；所有 coordinator 构造点已补 pendingReplayRepo）。

- [ ] **Step 6: commit**
```bash
git add -A
git commit -m "feat(A4): coordinator replay autosave gate + saveProgress routing + startedAt + DI"
```

---

## Task A5: `resumePendingReplay` + `hasResumableReplay` + AppRouter 分流

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift`
- Test: 同 `CoordinatorReplayPersistenceTests.swift` 追加 + `ios/Contracts/Tests/KlineTrainerContractsTests/App/AppRouterReplayBranchTests.swift`（若可 host 测路由谓词）

**Interfaces:**
- Produces:
  - `coordinator.resumePendingReplay(recordId: Int64) async throws -> TrainingEngine?`
  - `coordinator.hasResumableReplay(recordId: Int64) -> Bool`
- Consumes: `pendingReplayRepo`（A4）、`recordRepo.loadRecordBundle`（既有）

> **错误纪律（codex plan-R1-F1，精确镜像 `resumePending`）**：瞬态/未分类错误 **传播**（不清档、不覆盖槽）；**只在 openReader「已验证损坏」(`isCorruptTrainingSet`)** 时 `cache.delete + clearReplay + 返回 nil`。`loadReplay()`/`loadRecordBundle`/`loadAllCandles`/`make` 的错误**一律传播**（含 `.dbCorrupted`——fail-closed，同 resumePending 的 loadPending 传播）。记录不会被单独删除（reset 保留记录 + 连带清 replay 槽，无孤儿）→ `loadRecordBundle` 错误必为瞬态 → 传播。**路由 = resume-first 权威**（不再用 `hasResumableReplay` 当路由门）：transient throw → router setError → **不 fresh、不覆盖槽**。

- [ ] **Step 1: 写失败测试**
```swift
@MainActor
@Test func resumePendingReplay_restoresState() async throws {
    let h = try CoordinatorTestHarness.make()
    let e1 = try await h.coordinator.replay(recordId: h.seededRecordId)
    e1.holdOrObserve(panel: .upper)
    let savedTick = e1.tick.globalTickIndex
    try await h.coordinator.saveProgress(engine: e1)
    await h.coordinator.endSession()

    #expect(h.coordinator.hasResumableReplay(recordId: h.seededRecordId) == true)
    let e2 = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
    #expect(e2 != nil)
    #expect(e2?.tick.globalTickIndex == savedTick)
    #expect(e2?.flow.mode == .replay)
}

@MainActor
@Test func resumePendingReplay_recordIdMismatch_returnsNil_noClear() async throws {
    let h = try CoordinatorTestHarness.make()
    let e1 = try await h.coordinator.replay(recordId: h.seededRecordId)
    e1.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: e1)
    await h.coordinator.endSession()
    #expect(h.coordinator.hasResumableReplay(recordId: 999999) == false)
    let e = try await h.coordinator.resumePendingReplay(recordId: 999999)
    #expect(e == nil)
    // 不匹配不清档：另一记录的槽仍在
    #expect(try h.pendingReplayRepo.loadReplay() != nil)
}

@MainActor
@Test func resumePendingReplay_transientLoadFailure_propagates_keepsSlot() async throws {
    let h = try CoordinatorTestHarness.make()
    let e1 = try await h.coordinator.replay(recordId: h.seededRecordId)
    e1.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: e1)
    await h.coordinator.endSession()
    // 注入一次瞬态 loadReplay 失败：resumePendingReplay 须抛（不返 nil、不清档）
    h.pendingReplayRepo.failNextLoadReplay = .internalError(module: "test", detail: "transient")
    await #expect(throws: (any Error).self) {
        _ = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
    }
    // 槽仍在（failNext 已消费，本次 load 成功）
    #expect(try h.pendingReplayRepo.loadReplay() != nil)
}
```

- [ ] **Step 2: 跑测试确认失败** — FAIL（方法不存在）。

- [ ] **Step 3a: `hasResumableReplay`**（coordinator 加；**display-only / advisory**）
```swift
/// 新需求10：该记录是否有可续局 replay 暂存。**display-only/advisory**（历史弹窗按钮文案）。
/// 读失败保守返 false 安全：路由是 resume-first 权威（replay(id:) 总先试 resumePendingReplay），
/// 故此处一次瞬态 false 至多让按钮文案短暂误显「再次训练」，点击仍走 resume-first 不会丢槽。
public func hasResumableReplay(recordId: Int64) -> Bool {
    (try? pendingReplayRepo.loadReplay())?.recordId == recordId
}
```

- [ ] **Step 3b: `resumePendingReplay`**（coordinator 加，**精确镜像 `resumePending` 错误纪律**）
```swift
/// 新需求10：续局 replay。镜像 resumePending：载暂存→校验记录→open reader→按存档 tick/状态重建 replay 引擎。
/// 错误纪律：loadReplay/loadRecordBundle/loadAllCandles/make 错误**传播**（不清档）；**仅 openReader 已验证损坏
/// (isCorruptTrainingSet)** 才 cache.delete + clearReplay + 返回 nil。无槽 / recordId 不匹配 → 返回 nil（不清档）。
public func resumePendingReplay(recordId: Int64) async throws -> TrainingEngine? {
    // loadReplay 错误传播（含 .dbCorrupted，fail-closed 同 resumePending 的 loadPending）；无槽/不匹配 → nil（不清档）
    guard let pending = try pendingReplayRepo.loadReplay(), pending.recordId == recordId else { return nil }
    // 记录不会被单独删除（reset 连带清槽，无孤儿）→ loadRecordBundle 错误必瞬态 → 传播（不清档）
    let bundle = try recordRepo.loadRecordBundle(id: pending.recordId)
    let file = try cachedFile(filename: pending.trainingSetFilename)
    let reader: any TrainingSetReader
    do {
        reader = try openReader(for: file)
    } catch where isCorruptTrainingSet(error) {
        try? cache.delete(file)                 // best-effort：训练组损坏，孤儿槽不可恢复
        try pendingReplayRepo.clearReplay()      // durable 清（唯一清档点）
        return nil                               // 调用方回退从头 replay
    }
    do {
        let allCandles = try reader.loadAllCandles()
        let mt = try maxTick(from: allCandles)
        let position = try decodePosition(pending.positionData)
        let engine = try TrainingEngine.make(
            .replay(fees: pending.feeSnapshot, maxTick: mt),
            allCandles: allCandles,
            initialTick: pending.globalTickIndex,
            initialCapital: pending.accumulatedCapital,
            initialCashBalance: pending.cashBalance,
            initialPosition: position,
            initialMarkers: markers(from: pending.tradeOperations),
            initialDrawings: pending.drawings,
            initialTradeOperations: pending.tradeOperations,
            initialDrawdown: pending.drawdown,
            initialUpperPeriod: pending.upperPeriod,
            initialLowerPeriod: pending.lowerPeriod)
        activeReader = reader
        activeEngine = engine
        activeFile = file
        cache.touch(file)                        // §A touch-on-use（同 resumePending）
        activeRecord = bundle.record             // replay 续局需 record（fees/标的名 + 终局 payload）
        activeStartedAt = pending.startedAt
        activeSessionKey = nil                    // replay 无 sessionKey
        resetAutosaveState()                      // 新 session：清栅栏/脏/cadence/错误
        return engine
    } catch {
        reader.close()
        throw (error as? AppError) ?? .internalError(module: "E6b", detail: String(describing: error))
    }
}
```
> implementer：`maxTick(from:)`/`decodePosition`/`markers(from:)`/`resetAutosaveState()`/`cache.touch` 均为 `resumePending` 同款既有 helper（精确签名以源码为准）。`bundle` 解构若编译器需具名用 `let bundle = try recordRepo.loadRecordBundle(...)` 后取 `bundle.0`/`.record`（以 `loadRecordBundle` 返回类型为准）。

- [ ] **Step 3c: AppRouter 分流（resume-first 权威，codex plan-R1-F1）** — `App/AppRouter.swift` `replay(id:)`：
```swift
public func replay(id: Int64) async {
    activeModal = nil
    do {
        // resume-first：总先试续局；返 nil（无槽/不匹配/已验证损坏已清）才从头。
        // throw（瞬态）→ setError → 不 fresh、不覆盖槽（防丢有效暂停档）。
        let engine: TrainingEngine
        if let resumed = try await coordinator.resumePendingReplay(recordId: id) {
            engine = resumed
        } else {
            engine = try await coordinator.replay(recordId: id)   // 从头
        }
        activeTraining = ActiveTraining(lifecycle: TrainingSessionLifecycle(engine: engine, coordinator: coordinator))
    } catch { setError(error) }
}
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter resumePendingReplay_restoresState` / `--filter resumePendingReplay_recordIdMismatch_returnsNil` → PASS。

- [ ] **Step 5: 全量 host 不回归** — `swift test` → 0 失败。

- [ ] **Step 6: commit**
```bash
git add -A
git commit -m "feat(A5): resumePendingReplay + hasResumableReplay + AppRouter replay branch"
```

---

## Task A6: 终局清档(fence) + discard + reset 清 replay

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（`replaySettlementPayload` async + fence+clear；`discardSession` 清 replay）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift`（`replaySettlementRecord()` async）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（`routeEndOfSession` replay 分支 `Task{}`）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift`（`resetAllTrainingProgress` 加 `clearReplay`）
- Test: `CoordinatorReplayPersistenceTests.swift` 追加

**Interfaces:**
- Produces: `replaySettlementPayload(engine:) async throws -> TrainingRecord`（签名由 sync 改 async，fence+clearReplay）；`discardSession` 清 replay；`resetAllTrainingProgress` 清 replay。

- [ ] **Step 1: 写失败测试**
```swift
@MainActor
@Test func replayTerminal_fencesAndClears_evenWithQueuedAutosave() async throws {
    let h = try CoordinatorTestHarness.make()
    let e = try await h.coordinator.replay(recordId: h.seededRecordId)
    e.holdOrObserve(panel: .upper)
    h.coordinator.requestAutosave(engine: e, immediate: false)   // 排队一个 autosave
    _ = try await h.coordinator.replaySettlementPayload(engine: e)  // 终局：fence + clear
    await h.coordinator.drainAutosaveForTesting()
    #expect(try h.pendingReplayRepo.loadReplay() == nil)          // 不被排队 autosave 复活
}

@MainActor
@Test func discardSession_replay_clears() async throws {
    let h = try CoordinatorTestHarness.make()
    let e = try await h.coordinator.replay(recordId: h.seededRecordId)
    e.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: e)
    try await h.coordinator.discardSession()
    #expect(try h.pendingReplayRepo.loadReplay() == nil)
}

@MainActor
@Test func replayTerminal_clearFailureAfterPayload_keepsSlot_retryable() async throws {
    // codex plan-R1-F2：清档在 payload 构建成功之后；clearReplay 抛 → 方法抛 + 槽保留（可重试）
    let h = try CoordinatorTestHarness.make()
    let e = try await h.coordinator.replay(recordId: h.seededRecordId)
    e.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: e)
    h.pendingReplayRepo.failNextClearReplay = .internalError(module: "test", detail: "transient clear")
    await #expect(throws: (any Error).self) {
        _ = try await h.coordinator.replaySettlementPayload(engine: e)
    }
    #expect(try h.pendingReplayRepo.loadReplay() != nil)      // 槽保留
    // 重试成功（failNext 已消费）→ 清空
    _ = try await h.coordinator.replaySettlementPayload(engine: e)
    #expect(try h.pendingReplayRepo.loadReplay() == nil)
}
```
> reset 清档在 persistence 层测（A3 的 `PendingReplayPersistenceTests` 追加：写一行 pending_replay 后调 `db.resetAllTrainingProgress(toCapital:)`，断言 `loadReplay()==nil` 且 `loadPending()==nil`）。

- [ ] **Step 2: 跑测试确认失败** — FAIL（replaySettlementPayload sync / discard 不清 replay / reset 不清 replay）。

- [ ] **Step 3a: `replaySettlementPayload` 改 async + fence→构建 payload→成功后才 clear**（codex plan-R1-F2：清档**不得**早于 payload 全部 throwing 工作成功，否则 loadMeta 抛会"既删槽又无结算"）。
签名 `public func replaySettlementPayload(engine:) throws -> TrainingRecord` → `... async throws -> TrainingRecord`。**顺序**：①两 `guard`（mode+活跃上下文）→ ②`await fenceAndDrainAutosaves()`（排空排队 autosave，此后无并发写）→ ③`let meta = try reader.loadMeta()` + 构造 `record`（**全部 throwing payload 工作，槽仍在**，字段计算不变）→ ④`try pendingReplayRepo.clearReplay()`（**仅在 payload 构建成功后**）→ ⑤`return record`。
即在 `return TrainingRecord(...)` 之前先 `let record = TrainingRecord(...)`，然后：
```swift
        // 新需求10：fence 已在上方排空 autosave；payload 构建成功后才清槽（codex plan-R1-F2）。
        // clearReplay 抛 → 整个方法抛、record 不返回 → caller 保留 session+槽、可重试（见 TrainingView）。
        try pendingReplayRepo.clearReplay()
        return record
```
（`await fenceAndDrainAutosaves()` 插在两 guard 之后、`loadMeta` 之前。）

- [ ] **Step 3b: `discardSession` 清 replay** — `discardSession()` 内（已 `await fenceAndDrainAutosaves()`）在清 pending 处加 replay 分支：
```swift
        // 新需求10：replay 局 discard 清 replay 槽（normal 清 pending_training，原逻辑）
        if activeEngine?.flow.mode == .replay {
            try pendingReplayRepo.clearReplay()
        } else {
            try pendingRepo.clearPending()    // 原逻辑
        }
```
> implementer：以 `discardSession` 现有清 pending 代码为准做最小分流（保持原 normal 行为字节不变）。

- [ ] **Step 3c: lifecycle `replaySettlementRecord()` async** —
```swift
public func replaySettlementRecord() async throws -> TrainingRecord {
    try await coordinator.replaySettlementPayload(engine: engine)
}
```

- [ ] **Step 3d: `TrainingView` replay 终局 async + 失败保留 session 可重试**（codex plan-R1-F2：失败**不** `onSessionEnded(nil)` 拆毁）。
加 `@State private var replaySettlementFailed = false`。新增 `runReplaySettlement()`（镜像 `runFinalize` 的 `finalizing` 重入门 + 失败置 alert，**不拆 session**）：
```swift
    // replay 终局：fence→构建 payload→清槽（coordinator）。失败=保留 session+槽（不 onSessionEnded(nil)），
    // 弹可重试 alert（镜像 runFinalize）。didFinalize 已由 maybeAutoEnd/endManually 置 true，防 onChange 重入；
    // 重试=显式 alert 按钮再调本方法（fence/payload/clear 均幂等）。
    private func runReplaySettlement() {
        guard !finalizing else { return }
        finalizing = true
        Task {
            defer { finalizing = false }
            do {
                let record = try await lifecycle.replaySettlementRecord()
                onReplaySettlement(record)
            } catch {
                replaySettlementFailed = true
            }
        }
    }
```
`routeEndOfSession` replay 分支改调它：
```swift
    private func routeEndOfSession() {
        guard engine.flow.mode == .replay else { runFinalize(); return }
        runReplaySettlement()
    }
```
加 alert（紧邻既有 `结算入账失败` alert）：
```swift
        .alert("结算失败", isPresented: $replaySettlementFailed) {
            Button("重试") { runReplaySettlement() }
            Button("退出本局", role: .cancel) { onSessionEnded(nil) }   // 用户显式选退出
        } message: {
            Text("本局结算未能完成。可重试，或退出本局（暂存进度保留，可在历史记录返回训练）。")
        }
```

- [ ] **Step 3e: `DefaultAppDB.resetAllTrainingProgress` 加 clearReplay**
```swift
public func resetAllTrainingProgress(toCapital: Double) throws {
    do {
        try dbQueue.write { db in
            try PendingTrainingRepositoryImpl.clearPending(db)
            try PendingReplayRepositoryImpl.clearReplay(db)     // 新需求10：reset 连带清 replay 槽
            try SettingsDAOImpl.setTotalCapital(db, toCapital)
        }
    } catch let appErr as AppError { throw appErr }
    catch { throw PersistenceErrorMapping.translate(error) }
}
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter replayTerminal_fencesAndClears_evenWithQueuedAutosave` / `--filter discardSession_replay_clears` + reset 测 → PASS。

- [ ] **Step 5: 全量 host 不回归** — `swift test` → 0 失败（注意：`replaySettlementPayload`/`replaySettlementRecord` 的现有调用点已全部 await 化）。

- [ ] **Step 6: commit**
```bash
git add -A
git commit -m "feat(A6): replay terminal fence+clear (async) + discard/reset clear pending_replay"
```

---

## Task A7: HistoryActionSheet 去取消钮 + 文案切换 + AppRootView 接线

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionSheetTests.swift`（追加；若仅有 content 测则加 host-test 谓词）

**Interfaces:**
- Produces: `HistoryActionSheet(record:, hasResumableReplay:, onReview:, onReplay:, onCancel:)`；replay 钮文案 = `hasResumableReplay ? "返回训练" : "再次训练"`；无「取消」按钮（遮罩 onCancel 仍在）。

- [ ] **Step 1: 写失败测试**（纯逻辑：把文案选择抽成可测 static，或断言 view 树文案。优先抽 static helper）
在 `HistoryActionSheet` 内加可测 static：
```swift
public static func replayButtonTitle(hasResumableReplay: Bool) -> String {
    hasResumableReplay ? "返回训练" : "再次训练"
}
```
测试：
```swift
@Test func replayButtonTitle_toggles() {
    #expect(HistoryActionSheet.replayButtonTitle(hasResumableReplay: false) == "再次训练")
    #expect(HistoryActionSheet.replayButtonTitle(hasResumableReplay: true) == "返回训练")
}
```

- [ ] **Step 2: 跑测试确认失败** — FAIL。

- [ ] **Step 3a: 改 `HistoryActionSheet`**
- init 加参数 `hasResumableReplay: Bool`（存为属性）。
- 删除「取消」按钮那段 `Button(action: onCancel) { Text("取消") ... }`（含上方 `Spacer().frame(height: 8)`）；**保留** `onCancel` 属性与遮罩的 `.onTapGesture { onCancel() }`。
- replay 钮文案 `Text("再来一次")` → `Text(Self.replayButtonTitle(hasResumableReplay: hasResumableReplay))`。
- 卡片更小：去掉一钮后视觉自然收紧（`maxWidth: 280` 可保留或按 plan 微调；本步不强制改宽度）。
- 加上面 Step 1 的 static helper。
- 更新文件内 `#Preview`（传 `hasResumableReplay: false`）。

- [ ] **Step 3b: `AppRootView` 接线** — `HistoryActionSheet(...)` 构造处：
```swift
HistoryActionSheet(record: r,
                   hasResumableReplay: router.coordinator.hasResumableReplay(recordId: r.id ?? -1),
                   onReview: { Task { await router.review(id: r.id ?? -1) } },
                   onReplay: { Task { await router.replay(id: r.id ?? -1) } },
                   onCancel: { router.activeModal = nil })
```
> 若 `router.coordinator` 非 public，加一个 `router.hasResumableReplay(id:)` 透传方法（read-only 谓词），AppRootView 调它。implementer 视 AppRouter 可见性择一（优先加透传方法，避免暴露 coordinator）。

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter replayButtonTitle_toggles` → PASS。

- [ ] **Step 5: 全量 host 不回归** — `swift test` → 0 失败（HistoryActionSheet 既有测试若断言「取消」按钮存在，同步更新为断言其不存在 + 文案切换）。

- [ ] **Step 6: commit**
```bash
git add -A
git commit -m "feat(A7): HistoryActionSheet drop 取消 + 再次训练/返回训练 toggle + AppRootView wiring"
```

---

## Task B1: ReviewFlow 可步进 + `canJumpToEnd` + FlowInput + make + preview

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（`FlowInput.review`、`make` `.review`、preview fixture）
- Test: `TrainingFlowControllerTests.swift` 追加

**Interfaces:**
- Produces:
  - `TrainingFlowController.canJumpToEnd() -> Bool`（Review=true, Normal=false, Replay=false）
  - `ReviewFlow.init(record:, startTick:)`；`initialTick=startTick`；`allowedTickRange = startTick...record.finalTick`；`canAdvance()=true`
  - `TrainingEngine.FlowInput.review(record:, startTick:)`

- [ ] **Step 1: 写失败测试**
```swift
@Test func reviewFlow_playable_matrix() {
    let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    let rec = TrainingRecord(id: 1, trainingSetFilename: "x.sqlite", createdAt: 0, stockCode: "1", stockName: "n",
        startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
        maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 1000)
    let rf = ReviewFlow(record: rec, startTick: 200)
    #expect(rf.initialTick == 200)
    #expect(rf.allowedTickRange == 200...1000)
    #expect(rf.canAdvance() == true)
    #expect(rf.canBuySell() == false)
    #expect(rf.canJumpToEnd() == true)
    #expect(rf.shouldShowSettlement() == false)
    #expect(NormalFlow(fees: fees, maxTick: 100).canJumpToEnd() == false)
    #expect(ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: 100).canJumpToEnd() == false)
}
```
（同时把 Task A1 的 `shouldPersistProgress_matrix` 里 `ReviewFlow(record:)` 改成 `ReviewFlow(record:, startTick:rec.finalTick)` 以编译。）

- [ ] **Step 2: 跑测试确认失败** — FAIL。

- [ ] **Step 3a: 协议加 `canJumpToEnd`**（`TrainingFlowController` 协议 + 三 struct）
协议：`func canJumpToEnd() -> Bool`；NormalFlow `{ false }`；ReplayFlow `{ false }`；ReviewFlow `{ true }`。

- [ ] **Step 3b: 改 `ReviewFlow`**
```swift
public struct ReviewFlow: TrainingFlowController {
    public let record: TrainingRecord
    public let startTick: Int

    public init(record: TrainingRecord, startTick: Int) {
        self.record = record
        self.startTick = startTick
    }

    public var mode: TrainingMode { .review }
    public var feeSnapshot: FeeSnapshot { record.feeSnapshot }
    public var initialTick: Int { startTick }
    public var allowedTickRange: ClosedRange<Int> { startTick...record.finalTick }

    public func canBuySell() -> Bool { false }
    public func canAdvance() -> Bool { true }          // 新需求10：复盘可步进重演
    public func shouldSaveRecord() -> Bool { false }
    public func shouldAccumulateCapital() -> Bool { false }
    public func shouldShowSettlement() -> Bool { false }
    public func shouldGiveHapticFeedback() -> Bool { false }
    public func shouldPersistProgress() -> Bool { false }
    public func canJumpToEnd() -> Bool { true }
}
```

- [ ] **Step 3c: `FlowInput.review` 带 startTick + `make` 分支 + preview**
- `FlowInput`：`case review(record: TrainingRecord)` → `case review(record: TrainingRecord, startTick: Int)`。
- `make` 内 `case .review:`：
```swift
        case .review(let record, let startTick):
            maxTick = record.finalTick
            flow = ReviewFlow(record: record, startTick: startTick)
```
- preview fixture 分支（`make` 的 DEBUG `case .review:`）：用 `ReviewFlow(record: previewRecord(fees: fees, finalTick: maxTick), startTick: 0)`。

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter reviewFlow_playable_matrix` → PASS。

- [ ] **Step 5: 全量 host 不回归** — `swift test` → 0 失败（所有 `.review(record:)`/`ReviewFlow(record:)` 调用点已补 startTick；Task B3 改 coordinator.review 真实派生，本 task 内其余调用点用 record.finalTick 或合理值过编译）。

- [ ] **Step 6: commit**
```bash
git add -A
git commit -m "feat(B1): ReviewFlow playable (startTick/range/canAdvance) + canJumpToEnd + FlowInput"
```

---

## Task B2: `TrainingEngine.jumpToEnd()`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngine/TrainingEngineJumpToEndTests.swift`（新建）

**Interfaces:**
- Produces: `TrainingEngine.jumpToEnd()`（guard `canJumpToEnd()`；`tick.reset(to: tick.maxTick)` + 镜头吸附 + drawdown.update）

- [ ] **Step 1: 写失败测试**（用 preview/fixture 引擎构造 review 引擎，起点 < maxTick）
```swift
@MainActor
@Test func jumpToEnd_review_setsMaxTick() throws {
    let engine = try TrainingEngine.previewReview(startTick: 5)   // 复用 preview 构造 review 引擎（implementer 用现有 preview API）
    #expect(engine.tick.globalTickIndex < engine.tick.maxTick)
    engine.jumpToEnd()
    #expect(engine.tick.globalTickIndex == engine.tick.maxTick)
}

@MainActor
@Test func jumpToEnd_normal_noOp() throws {
    let engine = try TrainingEngine.previewNormal()
    let before = engine.tick.globalTickIndex
    engine.jumpToEnd()
    #expect(engine.tick.globalTickIndex == before)   // canJumpToEnd()==false
}
```
> implementer：用现有 `TrainingEngine.preview(...)` / fixture 构造 review/normal 引擎（preview 现已支持 `.review`；若需 startTick 用 B1 的 preview 改动）。

- [ ] **Step 2: 跑测试确认失败** — FAIL（jumpToEnd 不存在）。

- [ ] **Step 3: 实现 `jumpToEnd()`**（紧邻 `advanceAndAccount` / `holdOrObserve`）
```swift
/// 新需求10：复盘「快进到结尾」。仅 canJumpToEnd()（Review）生效；设 tick=maxTick + 镜头吸附 autoTracking。
/// 无成交、无 marker；无 forceClose（复盘无持仓）。K线/标记随 currentIdx 自动全揭示。
public func jumpToEnd() {
    guard flow.canJumpToEnd() else { return }
    stopAllDeceleration()
    tick.reset(to: tick.maxTick)
    _ = upperPanel.reduce(.tradeTriggered)
    _ = lowerPanel.reduce(.tradeTriggered)
    resetOffsetAfterAutoTracking(.upper)
    resetOffsetAfterAutoTracking(.lower)
    drawdown.update(currentCapital: currentTotalCapital)
}
```
> implementer：`stopAllDeceleration` / `reduce(.tradeTriggered)` / `resetOffsetAfterAutoTracking` 复用 `advanceAndAccount` 同款调用（以源码现有方法名为准）。

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter jumpToEnd_review_setsMaxTick` / `--filter jumpToEnd_normal_noOp` → PASS。

- [ ] **Step 5: 全量 host 不回归** — `swift test` → 0 失败。

- [ ] **Step 6: commit**
```bash
git add -A
git commit -m "feat(B2): TrainingEngine.jumpToEnd (review-only, tick=maxTick + camera snap)"
```

---

## Task B3: Coordinator `review()` 派生 startTick

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（`review(recordId:)`）
- Test: `CoordinatorReplayPersistenceTests.swift` 追加（或 review 专门测试文件）

**Interfaces:**
- Consumes: `FlowInput.review(record:, startTick:)`（B1）、`TrainingEngine.startTick(forStartDatetime:in:)`（既有）

- [ ] **Step 1: 写失败测试**
```swift
@MainActor
@Test func review_startsAtTrainingStartTick_notFinalTick() async throws {
    let h = try CoordinatorTestHarness.make()
    let engine = try await h.coordinator.review(recordId: h.seededRecordId)
    #expect(engine.flow.mode == .review)
    #expect(engine.tick.globalTickIndex == engine.flow.initialTick)
    #expect(engine.tick.globalTickIndex < h.seededRecordFinalTick)   // 起点不是末根
    #expect(engine.flow.allowedTickRange.upperBound == h.seededRecordFinalTick)
}
```
> harness 的 seeded record finalTick 须 > 派生 startTick（fixture 训练集 metadata 决定）。

- [ ] **Step 2: 跑测试确认失败** — FAIL（现 review 起点 = finalTick）。

- [ ] **Step 3: 改 `review(recordId:)`** — 在 `loadAllCandles()` 后、`make` 前派生 startTick 并经 FlowInput 传入：
```swift
        let meta = try reader.loadMeta()
        let startTick = TrainingEngine.startTick(forStartDatetime: meta.startDatetime, in: allCandles)
        let engine = try TrainingEngine.make(
            .review(record: record, startTick: startTick),
            allCandles: allCandles,
            initialCapital: record.totalCapital,
            initialCashBalance: record.totalCapital + record.profit,   // 末态全现金（不变，D-B3）
            initialMarkers: markers(from: ops),
            initialDrawings: drawings,
            initialTradeOperations: ops)
```
> implementer：`startTick(forStartDatetime:in:)` 精确签名以源码为准（replay 已用同款；参数名/`in:` 容器对齐 replay 的调用）。其余 review 装配（activeRecord/activeStartedAt=nil/activeSessionKey=nil）不变。

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter review_startsAtTrainingStartTick_notFinalTick` → PASS。

- [ ] **Step 5: 全量 host 不回归** — `swift test` → 0 失败。

- [ ] **Step 6: commit**
```bash
git add -A
git commit -m "feat(B3): coordinator review() starts at derived training startTick"
```

---

## Task B4: 复盘控件条（下一根 + 快进到结尾）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/ReviewControlBar.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/ReviewControlBarTests.swift`（新建，测纯内容/谓词）

**Interfaces:**
- Consumes: `engine.holdOrObserve(panel:)`（既有）、`engine.jumpToEnd()`（B2）、`canAdvance()/canBuySell()/canJumpToEnd()`（B1）
- Produces: `ReviewControlBar`（SwiftUI 薄壳）；`TrainingView.showsReviewControls`

- [ ] **Step 1: 写失败测试**（谓词纯逻辑 + 内容）
```swift
@Test func showsReviewControls_predicate() {
    // 用 flow 直接验证谓词组合：review=true、normal=false、replay=false
    let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    let rec = TrainingRecord(id: 1, trainingSetFilename: "x", createdAt: 0, stockCode: "1", stockName: "n",
        startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
        maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 100)
    func shows(_ f: TrainingFlowController) -> Bool { f.canAdvance() && !f.canBuySell() }
    #expect(shows(ReviewFlow(record: rec, startTick: 0)) == true)
    #expect(shows(NormalFlow(fees: fees, maxTick: 100)) == false)
    #expect(shows(ReplayFlow(feeSnapshotFromOriginal: fees, maxTick: 100)) == false)
}
```

- [ ] **Step 2: 跑测试确认失败/通过基线** — `swift test --filter showsReviewControls_predicate`（此谓词测试在 B1 后即可 PASS；作为回归锚）。

- [ ] **Step 3a: 新建 `ReviewControlBar.swift`**
```swift
import SwiftUI

/// 复盘专用控件条（新需求10）：仅复盘可步进态显示。「下一根」步进、「快进到结尾」展开整局。
/// 不含买/卖（canBuySell=false）。平台无关 SwiftUI 薄壳；动作经闭包上交。
public struct ReviewControlBar: View {
    private let showsJumpToEnd: Bool
    private let onStep: () -> Void
    private let onJumpToEnd: () -> Void

    public init(showsJumpToEnd: Bool,
                onStep: @escaping () -> Void,
                onJumpToEnd: @escaping () -> Void) {
        self.showsJumpToEnd = showsJumpToEnd
        self.onStep = onStep
        self.onJumpToEnd = onJumpToEnd
    }

    public var body: some View {
        HStack(spacing: 12) {
            Button(action: onStep) {
                Text("下一根").frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            if showsJumpToEnd {
                Button(action: onJumpToEnd) {
                    Text("快进到结尾").frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
    }
}
```

- [ ] **Step 3b: `TrainingView` 接线** — 加谓词 + 在 `showsTradeButtons` 那段 `else` 接复盘条：
```swift
    private var showsReviewControls: Bool { engine.flow.canAdvance() && !engine.flow.canBuySell() }
```
body 内 `if showsTradeButtons { TradeActionBar(...) }` 之后加：
```swift
            } else if showsReviewControls {
                ReviewControlBar(
                    showsJumpToEnd: engine.flow.canJumpToEnd(),
                    onStep: { engine.holdOrObserve(panel: activePanel) },
                    onJumpToEnd: { engine.jumpToEnd() })
```
> implementer：将其并入既有 `if showsTradeButtons { ... }` 结构为 `if ... {} else if showsReviewControls {}`（保持 TradeActionBar 块原样，仅追加 else-if 分支占同槽位）。

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter showsReviewControls_predicate` → PASS。

- [ ] **Step 5: 全量 host 不回归** — `swift test` → 0 失败。

- [ ] **Step 6: commit**
```bash
git add -A
git commit -m "feat(B4): ReviewControlBar (下一根 + 快进到结尾) + TrainingView review controls"
```

---

## 验证（Task 全部完成后，subagent-driven 末尾 / verification-before-completion）

- [ ] **三绿亲核**：
  1. host：`cd "ios/Contracts" && swift test`——Swift Testing 末行 0 failures **且** XCTest「All tests passed」（两框架分开打印，必看全；见 backlog 教训）。
  2. Catalyst：`KlineTrainerContracts` 包 scheme `build-for-testing` `SUCCEEDED`，CI-gate `grep -E "(error|warning):"` count 0（UIKit-gated 的 TrainingView/AppRootView/ReviewControlBar/coordinator 编译闸门——host swift test 对 `#if canImport(UIKit)` 编译为空，必须 Catalyst 补编译）。
  3. iOS Simulator app `BUILD SUCCEEDED`。
- [ ] schema-drift：确认未碰 `app_schema_v1.sql` / `v1_4_baselineDDL`。
- [ ] acceptance 清单产出：`docs/superpowers/acceptance/2026-06-30-replay-resume-review-playback.md`（Chinese，action/expected/pass-fail，非 coder 可执行；覆盖：replay 中途返回→历史显「返回训练」→续局回原 tick；replay 练到末尾→显「再次训练」；reset 后全显「再次训练」；复盘进入停在起点可步进；快进到结尾显整局；历史弹窗无「取消」钮、点遮罩取消）。

## Self-Review（plan 作者已核）
- spec 每节有对应 task：A.1-A.8→A2/A3/A4/A5/A6/A7；B.1-B.6→B1/B2/B3/B4。✓
- 三 codex spec finding 落 task：F1=A4(autosave 门)；F2=A6(终局 fence)；F3=A4(不前置 clear)。✓
- 类型一致：`PendingReplay`/`PendingReplayRepository.saveReplay/loadReplay/clearReplay`/`hasResumableReplay`/`resumePendingReplay`/`jumpToEnd`/`canJumpToEnd`/`shouldPersistProgress`/`ReviewFlow(record:,startTick:)`/`FlowInput.review(record:,startTick:)` 全 task 间一致。✓
- 无占位：`<...>` 标注处均为「复用同方法既有 normal/replay 代码」的明确指引（非 TODO），实现者读源码照搬同款字段。
