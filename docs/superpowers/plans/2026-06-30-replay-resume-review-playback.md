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
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
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
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try repo.saveReplay(p)
    #expect(try repo.loadReplay() == p)
    #expect(repo.saveCount == 1)
    try repo.clearReplay()
    #expect(try repo.loadReplay() == nil)
}
```
> 注：`DrawdownAccumulator` 真实 init = `init(peakCapital: Double, maxDrawdown: Double)`（已勘实，AppState.swift:68），上方调用已用 2 参。

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
    /// 轻量元数据（只读 record_id/training_set_filename，**不解码 payload**）。codex plan-R11-F1：
    /// resume-first 用它先判槽归属，避免别记录的损坏 payload 阻塞所有 replay 入口。
    func loadReplaySlotInfo() throws -> ReplaySlotInfo?
    func clearReplay() throws                       // 无条件（reset 用）
    func clearReplay(ifRecordId: Int64) throws      // 仅当槽属于该记录才清（终局/discard 用，codex plan-R3-F1）
}

public struct ReplaySlotInfo: Equatable, Sendable {
    public let recordId: Int64
    public let trainingSetFilename: String
    public init(recordId: Int64, trainingSetFilename: String) {
        self.recordId = recordId
        self.trainingSetFilename = trainingSetFilename
    }
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
    /// 元数据读取**不消费** `failNextLoadReplay`（生产 Impl 只读简单列、不解码 payload，故不受 payload 损坏影响）。
    /// 这样测试可"slotInfo 成功（返 recordId）+ loadReplay 抛 .dbCorrupted"模拟损坏 payload 的本记录槽。
    public func loadReplaySlotInfo() throws -> ReplaySlotInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let p = pending else { return nil }
        return ReplaySlotInfo(recordId: p.recordId, trainingSetFilename: p.trainingSetFilename)
    }
    public func clearReplay() throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextClearReplay { _failNextClearReplay = nil; throw e }
        pending = nil
    }
    public func clearReplay(ifRecordId recordId: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = _failNextClearReplay { _failNextClearReplay = nil; throw e }
        if pending?.recordId == recordId { pending = nil }
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
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try queue.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: p) }
    let back = try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }
    #expect(back == p)
    try queue.write { try PendingReplayRepositoryImpl.clearReplay($0) }
    #expect(try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) } == nil)
}

// codex plan-R17-F1：GRDB-backed 测条件清的真 SQL（fake 测不护真 SQL：漏 WHERE record_id 会真丢档）
@MainActor
@Test func pendingReplayImpl_conditionalClear_onlyMatchingRecordId() throws {
    let queue = try DatabaseQueue()
    try AppDBMigrations.makeMigrator().migrate(queue)
    let slotA = PendingReplay(recordId: 101, trainingSetFilename: "a.sqlite", globalTickIndex: 1,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try queue.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: slotA) }
    try queue.write { try PendingReplayRepositoryImpl.clearReplay($0, ifRecordId: 202) }   // 不匹配 → 不删
    #expect(try queue.read { try PendingReplayRepositoryImpl.loadReplaySlotInfo($0) }?.recordId == 101)
    try queue.write { try PendingReplayRepositoryImpl.clearReplay($0, ifRecordId: 101) }   // 匹配 → 删
    #expect(try queue.read { try PendingReplayRepositoryImpl.loadReplaySlotInfo($0) } == nil)
}

// codex plan-R17-F1：payload 列损坏时 loadReplaySlotInfo 仍返元数据（不解码）；loadReplay 抛 .dbCorrupted（确定区分）
@MainActor
@Test func pendingReplayImpl_slotInfo_returnsMetadataDespiteCorruptPayload() throws {
    let queue = try DatabaseQueue()
    try AppDBMigrations.makeMigrator().migrate(queue)
    try queue.write { db in
        // 直接 SQL 插入：record_id/filename/period 合法，payload 列填非法 base64/JSON
        try db.execute(sql: """
            INSERT INTO pending_replay
              (id, record_id, training_set_filename, global_tick_index, upper_period, lower_period,
               position_data, fee_snapshot, trade_operations, drawings,
               started_at, accumulated_capital, cash_balance, drawdown)
            VALUES (1, 77, 'rec.sqlite', 1, '60m', 'daily', '!!notbase64!!', '{bad', '{bad', '{bad', 1, 100000, 100000, '{bad')
            """)
    }
    let info = try queue.read { try PendingReplayRepositoryImpl.loadReplaySlotInfo($0) }
    #expect(info?.recordId == 77)                       // 元数据不解码 → 返回
    #expect(info?.trainingSetFilename == "rec.sqlite")
    #expect(throws: AppError.self) {                    // 全量解码损坏 → .dbCorrupted
        _ = try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }
    }
}
```
> 注：`upper_period='60m'`/`lower_period='daily'` 须是合法 `Period.rawValue`（m60='60m'/daily='daily'）；position_data 非法 base64 → loadReplay 先抛 `.dbCorrupted`。

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

    // codex plan-R3-F1：条件清——仅当单槽属于该记录（终局/discard，防删别的记录的槽）。原子，无读写竞态。
    static func clearReplay(_ db: Database, ifRecordId recordId: Int64) throws {
        try db.execute(sql: "DELETE FROM pending_replay WHERE id = 1 AND record_id = ?", arguments: [recordId])
    }

    // codex plan-R11-F1：轻量元数据——只读 record_id/training_set_filename（简单列，不解码 payload），
    // 故损坏 payload 不会让本方法抛。resume-first 用它先判槽归属，避免一条损坏槽阻塞所有记录的 replay。
    static func loadReplaySlotInfo(_ db: Database) throws -> ReplaySlotInfo? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT record_id, training_set_filename FROM pending_replay WHERE id = 1") else { return nil }
        return ReplaySlotInfo(recordId: row["record_id"], trainingSetFilename: row["training_set_filename"])
    }
}
```
> **codex plan-R11-F1**：`loadReplay` 内**所有 payload 解码失败统一映射 `.dbCorrupted`**——base64/Period 已显式抛 `.dbCorrupted`；把 4 处 `RecordRepositoryImpl.jsonDecode(...)`（fee/ops/drawings/drawdown）包进 `do/catch { throw AppError.persistence(.dbCorrupted) }`（或确认 jsonDecode 失败经 DefaultAppDB 映射即为 `.dbCorrupted`）。目的：resumePendingReplay 能用"是否 `.dbCorrupted`"确定区分"已验证损坏槽（清+回退）"vs"瞬态（传播）"。

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

public func loadReplaySlotInfo() throws -> ReplaySlotInfo? {
    do {
        return try dbQueue.read { db in
            try PendingReplayRepositoryImpl.loadReplaySlotInfo(db)
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

public func clearReplay(ifRecordId recordId: Int64) throws {
    do {
        try dbQueue.write { db in
            try PendingReplayRepositoryImpl.clearReplay(db, ifRecordId: recordId)
        }
    } catch let appErr as AppError { throw appErr }
    catch { throw PersistenceErrorMapping.translate(error) }
}
```
并在 `DefaultAppDB` 的类型声明处加 `PendingReplayRepository` 一致性（找 `: ... PendingTrainingRepository ...` 处追加 `, PendingReplayRepository`）。

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter migration0006_createsTable_userVersion4` / `--filter pendingReplayImpl_roundTripAndClear` / `--filter pendingReplayImpl_conditionalClear_onlyMatchingRecordId` / `--filter pendingReplayImpl_slotInfo_returnsMetadataDespiteCorruptPayload` → PASS。

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
@Test func cleanFreshReplay_backOrBackground_preservesOtherSlot() async throws {
    // codex plan-R4-F1：A 有槽；开新 replay B 零操作 → back()(saveProgress) 与后台 flush 都不得覆盖 A
    let h = try CoordinatorTestHarness.make(seedRecordIds: [101, 202])
    let eA = try await h.coordinator.replay(recordId: 101)
    eA.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: eA)         // slot = 101
    await h.coordinator.endSession()
    let eB = try await h.coordinator.replay(recordId: 202)   // fresh B，零操作
    try await h.coordinator.saveProgress(engine: eB)         // back() 路径：clean → 跳过
    #expect(try h.pendingReplayRepo.loadReplay()?.recordId == 101)
    await h.coordinator.flushAutosave(engine: eB)            // 后台 flush：clean → 跳过
    await h.coordinator.drainAutosaveForTesting()
    #expect(try h.pendingReplayRepo.loadReplay()?.recordId == 101)   // A 仍在
    // B 做了进度后再存 → 覆盖（单槽 last-active wins）
    eB.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: eB)
    #expect(try h.pendingReplayRepo.loadReplay()?.recordId == 202)
}

@MainActor
@Test func replayPeriodChange_isDirty_persistsPeriods() async throws {
    // codex plan-R14-F1：replay 切周期组合（不动 tick/ops/drawings）须算脏并落盘 upper/lowerPeriod
    let h = try CoordinatorTestHarness.make()
    let e = try await h.coordinator.replay(recordId: h.seededRecordId)
    let origUpper = e.upperPanel.period
    e.switchPeriodCombo(.toLarger)               // 实际切周期 API（以源码为准）
    #expect(e.upperPanel.period != origUpper)    // 周期已变（tick/ops/drawings 未变）
    try await h.coordinator.saveProgress(engine: e)   // clean-skip 比较含周期 → 不跳过、写
    #expect(try h.pendingReplayRepo.loadReplay()?.upperPeriod == e.upperPanel.period)
    #expect(try h.pendingReplayRepo.loadReplay()?.lowerPeriod == e.lowerPanel.period)
}

@MainActor
@Test func freshReplayAfterTeardown_autosaveEnabled() async throws {
    // codex plan-R7-F1：前一会话 endSession 留 terminating=true；fresh replay 须 resetAutosaveState 重开栅栏，
    // 否则 tick/后台 autosave 全 no-op（只 back() 存）。验证 advance 后 flush 真写 pending_replay。
    let h = try CoordinatorTestHarness.make()
    let warmup = try await h.coordinator.replay(recordId: h.seededRecordId)
    await h.coordinator.endSession()                         // 留 terminating=true
    let e = try await h.coordinator.replay(recordId: h.seededRecordId)  // fresh：须重开栅栏
    e.holdOrObserve(panel: .upper)                           // dirty
    h.coordinator.requestAutosave(engine: e, immediate: false)  // tick 节流路径（terminating 若未重置则 no-op）
    await h.coordinator.flushAutosave(engine: e)
    await h.coordinator.drainAutosaveForTesting()
    #expect(try h.pendingReplayRepo.loadReplay()?.recordId == h.seededRecordId)  // 已写（栅栏已重开）
    _ = warmup
}

@MainActor
@Test func replayDrawingAddThenDelete_noStaleSlot() async throws {
    // codex plan-R6-F1：加画线→存(拥有槽)→删画线(count 回基线)→存 → 槽须更新为无画线（不被 clean-skip 残留）
    let h = try CoordinatorTestHarness.make()
    let e = try await h.coordinator.replay(recordId: h.seededRecordId)
    // 用引擎公共 API 加一条画线（appendDrawing；anchors 内容对本测试无关，空数组即可）
    e.appendDrawing(DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0))
    try await h.coordinator.saveProgress(engine: e)            // 写槽（含 1 画线）→ replayHasPersisted=true
    #expect(try h.pendingReplayRepo.loadReplay()?.drawings.count == 1)
    e.deleteDrawing(at: 0)                                     // 删除 → e.drawings.count 回到 0（==fresh 基线 count）
    try await h.coordinator.saveProgress(engine: e)            // 已拥有槽 → 不 clean-skip → 写无画线
    #expect(try h.pendingReplayRepo.loadReplay()?.drawings.isEmpty == true)   // 无残留
}

@MainActor
@Test func requestAutosave_replayEnabled_reviewNoOp() async throws {
    let h = try CoordinatorTestHarness.make()
    let replayEngine = try await h.coordinator.replay(recordId: h.seededRecordId)
    // clean fresh replay：immediate autosave 不写槽（clean-skip 守卫，codex plan-R4/R5-F1）
    h.coordinator.requestAutosave(engine: replayEngine, immediate: true)
    await h.coordinator.drainAutosaveForTesting()
    #expect(h.pendingReplayRepo.saveCount == 0)
    // 有进度后：autosave 才写
    replayEngine.holdOrObserve(panel: .upper)
    h.coordinator.requestAutosave(engine: replayEngine, immediate: true)
    await h.coordinator.drainAutosaveForTesting()
    #expect(h.pendingReplayRepo.saveCount >= 1)

    await h.coordinator.endSession()
    let reviewEngine = try await h.coordinator.review(recordId: h.seededRecordId)
    let before = h.pendingReplayRepo.saveCount
    h.coordinator.requestAutosave(engine: reviewEngine, immediate: true)
    await h.coordinator.drainAutosaveForTesting()
    #expect(h.pendingReplayRepo.saveCount == before)   // review 不存（shouldPersistProgress=false）
}
```
> 若现无 `CoordinatorTestHarness`，implementer 以现有 coordinator 测试的 setUp 内联等价构造（关键：注入 `InMemoryPendingReplayRepository` 并 seed 一条 record + fixture training-set 让 `replay()` 成功）。

- [ ] **Step 2: 跑测试确认失败** — FAIL（init 签名不含 pendingReplayRepo / saveProgress 不路由）。

- [ ] **Step 3a: 加依赖 + init 参数**
`TrainingSessionCoordinator.swift` 存储属性区（紧邻 `pendingRepo`）加：
```swift
    private let pendingReplayRepo: PendingReplayRepository  // 新需求10：replay 续局单槽
```
并加 replay 会话基线（codex plan-R4-F1：clean fresh/resumed replay 不写槽，防覆盖别记录的槽）：
```swift
    // 新需求10：当前 replay 会话创建时的状态基线（tick/交易数/画线数/上下周期）。
    // 含周期（codex plan-R14-F1）：单指竖滑切周期组合改 upper/lowerPanel.period 而不动 tick/ops/drawings，
    // 须纳入 clean-skip 比较，否则切周期后 Back/flush 被当 clean 跳过 → 丢 PendingReplay 序列化的 upper/lowerPeriod。
    @ObservationIgnored private var replayBaseline: (tick: Int, ops: Int, drawings: Int, upper: Period, lower: Period)?
    // 新需求10（codex plan-R6-F1）：本 replay 会话是否已成功写过槽（拥有槽）。
    // fresh=false、resumed=true（续局本就拥有该槽）、任一次成功 saveReplay 后=true。
    // clean-skip **仅在 !replayHasPersisted 时**生效——首写后永不跳过，否则"加画线→写→删画线(count 回基线)
    // →跳过"会残留已删画线。仅计数比较不足以判脏，故用"是否已拥有槽"门控。
    @ObservationIgnored private var replayHasPersisted = false
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
            // codex plan-R3-F2：fail-closed（镜像 normal saveProgress 的活跃上下文守卫）——
            // 缺上下文 throw（autosave/back 显错）而非静默 return（静默=用户无感的进度丢失）。
            guard activeEngine === engine, let file = activeFile,
                  let recordId = activeRecord?.id, let started = activeStartedAt else {
                throw AppError.internalError(module: "E6b", detail: "replay saveProgress without active session context")
            }
            // codex plan-R4-F1 + R6-F1：clean-skip **仅在尚未拥有槽时**生效。fresh 会话首写前、且当前态==基线
            // （无 tick/交易/画线变化）→ 跳过写，防 back()/后台 flush 用 fresh B 初始态覆盖另一记录 A 的槽。
            // **首写后(replayHasPersisted)永不跳过**——否则"加画线→写→删画线(count 回基线)→跳过"会残留已删画线。
            // 此 return 是"无进度可存"的正常跳过（≠ F2 缺上下文 throw）。
            if !replayHasPersisted,
               let base = replayBaseline,
               base.tick == engine.tick.globalTickIndex,
               base.ops == engine.tradeOperations.count,
               base.drawings == engine.drawings.count,
               base.upper == engine.upperPanel.period,      // codex plan-R14-F1：切周期也算脏
               base.lower == engine.lowerPanel.period {
                return
            }
            _ = file   // file.filename 同 normal 取活跃文件名（下方 trainingSetFilename 用）
            let replay = PendingReplay(
                recordId: recordId,
                trainingSetFilename: file.filename,
                globalTickIndex: engine.tick.globalTickIndex,
                upperPeriod: engine.upperPanel.period,
                lowerPeriod: engine.lowerPanel.period,
                positionData: try encodePosition(engine.position),   // 同 normal 分支的 encodePosition helper
                cashBalance: max(0, engine.cashBalance),
                feeSnapshot: engine.fees,
                tradeOperations: engine.tradeOperations,
                drawings: engine.drawings,
                startedAt: started,
                accumulatedCapital: engine.initialCapital,
                drawdown: engine.drawdown)
            try pendingReplayRepo.saveReplay(replay)
            replayHasPersisted = true     // codex plan-R6-F1：已拥有槽，此后 saveProgress 永不 clean-skip
            return
        }
        // 以下为原 normal 分支（一字不改）...
```
> implementer：`encodePosition`/`file.filename` 为 `saveProgress` 现有 normal 分支同款（同方法内已有，照抄）。`encodePosition` 是否 throwing 以源码为准（normal 分支怎么调就怎么调）。replay 不需要 `activeSessionKey`。

- [ ] **Step 3d: `replay(recordId:)` 设 startedAt + baseline + 重开 autosave 栅栏；`endSession()` 清** — 在 `replay(recordId:)` 装配成功块（`activeReader/activeEngine/activeFile = ...` 之后）**改/加**：
```swift
        // 原 `activeStartedAt = nil` 改为：
        activeStartedAt = now()    // 新需求10：replay 会话起始，供 PendingReplay.started_at
        activeRecord = record      // （原有）
        replayBaseline = (engine.tick.globalTickIndex, engine.tradeOperations.count, engine.drawings.count,
                          engine.upperPanel.period, engine.lowerPanel.period)  // fresh 基线（含周期，codex plan-R14-F1）
        replayHasPersisted = false  // fresh：尚未拥有槽（codex plan-R6-F1）
        resetAutosaveState()        // 新需求10（codex plan-R7-F1）：重开 autosave 栅栏（terminating=false 等）——
                                    // 否则前一会话 endSession 留的 terminating=true 会让 fresh replay 的 tick/后台
                                    // autosave 全 no-op（requestAutosave 现 guard !terminating），crash/后台杀=丢档。
                                    // 与 startNewNormalSession(L188)/resumePending(L235) 同款。
```
`endSession()` 末尾（清活跃上下文处）加 `replayBaseline = nil; replayHasPersisted = false`（会话结束清；新会话由 replay()/resume 重设，防御性清）。
（**不**前置 `clearReplay`——单槽靠首存 INSERT OR REPLACE 覆盖 + clean-skip 守 clean B；失败装配不丢旧档。）

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

> **错误纪律（codex plan-R1/R10/R11/R12-F1，权威——下方代码以此为准）**：
> - **元数据先判归属（R11）**：`loadReplaySlotInfo()` 只读 record_id/filename 不解码 → 非本记录/无槽返 nil（不被别记录损坏 payload 阻塞）。
> - **本记录全量 `loadReplay()`**：**`.dbCorrupted`（已验证损坏 payload）→ durable `try clearReplay()` + 返回 nil（清成功=回退从头 fresh；清失败=瞬态 DB → 传播可重试、槽留，R12-F1）**；**非 `.dbCorrupted`（瞬态）→ 传播**（不清、不 fresh，防丢有效档）。⚠️ **不是"含 .dbCorrupted 一律传播"**——那会让永久损坏槽卡死按钮（R13-F1）。
> - **其他清档点**：openReader `isCorruptTrainingSet`（`cache.delete + clearReplay`）、pending 文件名 ≠ 记录文件名（`clearReplay`，R10）、**scalar slot 越界/非有限（make 前预判，`clearReplay`，whole-branch R1-F1）**。`loadRecordBundle`/`loadAllCandles`/**真训练集故障的 make 抛错** 传播（记录不被单独删除，故 loadRecordBundle 必瞬态）。
> - **scalar 损坏槽分流（whole-branch R1-F1）**：`make`（L220/L236-240）对越界 `globalTickIndex` / 非有限·负 cash·capital·drawdown 抛 `.trainingSet(.emptyData)`，与真训练集故障不可区分 → 必须在 `make` **前**对 pending scalar 显式 guard，损坏 → durable `clearReplay + nil`（回退从头），否则 resume-first 永久 brick 该记录。
> - **路由 = resume-first 权威**（不用 `hasResumableReplay` 当路由门）：transient throw → router setError → **不 fresh、不覆盖槽**；返 nil（无槽/不匹配/已清损坏槽）→ fresh。

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

// 损坏槽测试用最小 PendingReplay 工厂（loadReplay 抛错先于文件名 guard，故 filename 无关）
@MainActor
func makeSlot(recordId: Int64, filename: String = "rec.sqlite") -> PendingReplay {
    PendingReplay(recordId: recordId, trainingSetFilename: filename,
        globalTickIndex: 1, upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(),
        cashBalance: 100_000, feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
}

@MainActor
@Test func resumePendingReplay_corruptSlot_nonMatchingRecord_notBlocked() async throws {
    // codex plan-R11-F1：record A 的损坏 payload 槽不得阻塞 record B 的 replay 入口
    let h = try CoordinatorTestHarness.make(seedRecordIds: [101, 202])
    try h.pendingReplayRepo.saveReplay(makeSlot(recordId: 101))
    h.pendingReplayRepo.failNextLoadReplay = .persistence(.dbCorrupted)  // 全量解码会抛（slotInfo 不受影响）
    // 对 record 202 续局：slotInfo 返 101 ≠ 202 → 直接 nil，**不触发全量 loadReplay**（A 的损坏不阻塞 B）
    let e = try await h.coordinator.resumePendingReplay(recordId: 202)
    #expect(e == nil)
    #expect(try h.pendingReplayRepo.loadReplaySlotInfo()?.recordId == 101)  // A 槽未被清（非本记录不动）
}

@MainActor
@Test func resumePendingReplay_corruptSlot_matchingRecord_clearsAndFallsBack() async throws {
    // codex plan-R11-F1：本记录损坏 payload 槽 → 清 + 返回 nil（router 回退从头 fresh）
    let h = try CoordinatorTestHarness.make()
    try h.pendingReplayRepo.saveReplay(makeSlot(recordId: h.seededRecordId))
    h.pendingReplayRepo.failNextLoadReplay = .persistence(.dbCorrupted)  // 本记录槽全量解码损坏
    let e = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
    #expect(e == nil)
    #expect(try h.pendingReplayRepo.loadReplaySlotInfo() == nil)  // 损坏槽已清
}

@MainActor
@Test func resumePendingReplay_corruptPositionJSON_clearsAndFallsBack() async throws {
    // codex plan-R18-F1：position_data 合法存在但非法 PositionManager JSON → decodePosition 抛 .dbCorrupted
    // → 与 loadReplay 损坏同路径：清槽 + nil（回退从头），不卡死
    let h = try CoordinatorTestHarness.make()
    var slot = makeSlot(recordId: h.seededRecordId)
    slot = PendingReplay(recordId: slot.recordId, trainingSetFilename: slot.trainingSetFilename,
        globalTickIndex: slot.globalTickIndex, upperPeriod: slot.upperPeriod, lowerPeriod: slot.lowerPeriod,
        positionData: Data("{not-valid-position-json".utf8),   // 合法 Data、非法 PositionManager JSON
        cashBalance: slot.cashBalance, feeSnapshot: slot.feeSnapshot, tradeOperations: slot.tradeOperations,
        drawings: slot.drawings, startedAt: slot.startedAt, accumulatedCapital: slot.accumulatedCapital,
        drawdown: slot.drawdown)
    try h.pendingReplayRepo.saveReplay(slot)   // fake 不解码 → loadReplay 成功返回；decodePosition 才抛
    let e = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
    #expect(e == nil)
    #expect(try h.pendingReplayRepo.loadReplaySlotInfo() == nil)   // 损坏槽已清
}

@MainActor
@Test func resumePendingReplay_corruptSlot_clearFails_propagatesKeepsSlot() async throws {
    // codex plan-R12-F1：本记录损坏槽 + 清档失败（瞬态 DB）→ 不吞、传播可重试错误、槽保留（不伪装"无暂存"开 fresh）
    let h = try CoordinatorTestHarness.make()
    try h.pendingReplayRepo.saveReplay(makeSlot(recordId: h.seededRecordId))
    h.pendingReplayRepo.failNextLoadReplay = .persistence(.dbCorrupted)
    h.pendingReplayRepo.failNextClearReplay = .internalError(module: "test", detail: "transient clear")
    await #expect(throws: (any Error).self) {
        _ = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
    }
    #expect(try h.pendingReplayRepo.loadReplaySlotInfo()?.recordId == h.seededRecordId)  // 清失败 → 槽仍在
}

@MainActor
@Test func resumePendingReplay_filenameMismatch_clearsAndReturnsNil() async throws {
    // codex plan-R10-F1：pending.recordId 匹配但 trainingSetFilename 与记录不符（stale/corrupt 槽）→ 清 + nil（不拿错文件续局）
    let h = try CoordinatorTestHarness.make()
    let bad = PendingReplay(
        recordId: h.seededRecordId, trainingSetFilename: "WRONG-not-the-record-file.sqlite",
        globalTickIndex: 1, upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(),
        cashBalance: 100_000, feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try h.pendingReplayRepo.saveReplay(bad)
    let e = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
    #expect(e == nil)
    #expect(try h.pendingReplayRepo.loadReplay() == nil)   // 损坏槽已清
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

// codex whole-branch R1-F1：损坏 scalar slot（越界 tick / 非有限 money）= 损坏槽 → make 前分流清档 + nil（不传播 brick）
// 种坏槽用全量 `PendingReplay(...)` 字面（仅改受测的那个 scalar）；`h.seededRecordFinalTick` == 训练集 maxTick。
@Test func resumePendingReplay_tickBeyondMaxTick_clearsAndReturnsNil() async throws {
    let h = try CoordinatorTestHarness.make()
    let badSlot = PendingReplay(recordId: h.seededRecordId, trainingSetFilename: "set.sqlite",
        globalTickIndex: h.seededRecordFinalTick + 1,   // 越界：> maxTick → scalar guard 检出（永不到 make）
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try h.pendingReplayRepo.saveReplay(badSlot)
    let e = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
    #expect(e == nil)                                            // 回退从头
    #expect(try h.pendingReplayRepo.loadReplaySlotInfo() == nil) // 槽已清
}

@Test func resumePendingReplay_nonFiniteMoney_clearsAndReturnsNil() async throws {
    let h = try CoordinatorTestHarness.make()
    let badSlot = PendingReplay(recordId: h.seededRecordId, trainingSetFilename: "set.sqlite",
        globalTickIndex: 1, upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(),
        cashBalance: .infinity,                          // 非有限 → scalar guard 检出（isFinite=false）
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try h.pendingReplayRepo.saveReplay(badSlot)
    let e = try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId)
    #expect(e == nil)
    #expect(try h.pendingReplayRepo.loadReplaySlotInfo() == nil) // 槽已清
}
```

- [ ] **Step 2: 跑测试确认失败** — FAIL（方法不存在）。

- [ ] **Step 3a: `hasResumableReplay`**（coordinator 加；**display-only / advisory**）
```swift
/// 新需求10：该记录是否有可续局 replay 暂存。**display-only/advisory**（历史弹窗按钮文案）。
/// 用轻量 `loadReplaySlotInfo`（不解码 payload，codex plan-R11-F1）：损坏 payload 不影响归属判断。
/// 读失败保守返 false 安全：路由是 resume-first 权威（replay(id:) 总先试 resumePendingReplay），
/// 故此处一次瞬态 false 至多让按钮文案短暂误显「再次训练」，点击仍走 resume-first 不会丢槽。
public func hasResumableReplay(recordId: Int64) -> Bool {
    ((try? pendingReplayRepo.loadReplaySlotInfo()) ?? nil)?.recordId == recordId
}
```

- [ ] **Step 3b: `resumePendingReplay`**（coordinator 加，**精确镜像 `resumePending` 错误纪律**）
```swift
/// 新需求10：续局 replay。元数据先判归属→本记录全量解码→校验记录/文件名→open reader→按存档 tick/状态重建。
/// 错误纪律：**本记录 loadReplay `.dbCorrupted` → durable clearReplay + nil（回退从头）**；
/// **非 `.dbCorrupted` 的 loadReplay / loadRecordBundle / loadAllCandles / make 错误 → 传播**（不清、不 fresh）；
/// 清档点 = openReader `isCorruptTrainingSet`（cache.delete+clearReplay）/ 文件名不一致（clearReplay）/ 本记录 `.dbCorrupted`。
/// 无槽 / recordId 不匹配 → nil（不清档）。**注意：不是"loadReplay 错误一律传播"**（那会让永久损坏槽卡死，R13-F1）。
public func resumePendingReplay(recordId: Int64) async throws -> TrainingEngine? {
    // 1) 轻量元数据先判归属（codex plan-R11-F1）：不解码 payload → 别记录的损坏槽不阻塞本记录的 replay。
    //    slotInfo 自身错误=DB 级瞬态（whole-db 不可达）→ 传播。无槽/不匹配 → nil（不清档）。
    guard let info = try pendingReplayRepo.loadReplaySlotInfo(), info.recordId == recordId else { return nil }
    // 2) 本记录槽：全量解码 **含 position（codex plan-R18-F1：position 的 PositionManager JSON 解码也是 slot
    //    payload，须与 loadReplay 同走 .dbCorrupted→清 路径；decodePosition 已把所有解码错误包成 .dbCorrupted）**。
    //    .dbCorrupted（已验证损坏 payload）→ 清 + 回退从头；其他（瞬态）→ 传播。
    let pending: PendingReplay
    let position: PositionManager
    do {
        guard let p = try pendingReplayRepo.loadReplay() else { return nil }   // 竞态：刚被清 → nil
        pending = p
        position = try decodePosition(p.positionData)   // slot payload 解码（移到此处，与 loadReplay 同 .dbCorrupted 路径）
    } catch let e as AppError {
        if case .persistence(.dbCorrupted) = e {
            // 本记录损坏槽（loadReplay JSON 或 position JSON）→ durable 清 + 回退从头（router fresh）。**不用 try?**
            // （codex plan-R12-F1）：清失败=瞬态 DB（满/不可用）→ 传播可重试错误，**不**伪装"无暂存"而留损坏行卡死。
            try pendingReplayRepo.clearReplay()
            return nil
        }
        throw e                                    // 瞬态 → 传播（不清、不 fresh）
    }
    // 记录不会被单独删除（reset 连带清槽，无孤儿）→ loadRecordBundle 错误必瞬态 → 传播（不清档）
    let bundle = try recordRepo.loadRecordBundle(id: pending.recordId)
    // codex plan-R10-F1：pending 的文件名须与记录一致——否则 stale/corrupt 槽会让记录 A 的 id 配文件 B 的
    // candles/metadata（显错标的、终局清理失准）。内部不一致=已验证损坏槽 → 清 + 返回 nil（router 回退从头 replay，用记录权威文件名）。
    guard pending.trainingSetFilename == bundle.record.trainingSetFilename else {
        try pendingReplayRepo.clearReplay()
        return nil
    }
    let file = try cachedFile(filename: pending.trainingSetFilename)
    let reader: any TrainingSetReader
    do {
        reader = try openReader(for: file)
    } catch where isCorruptTrainingSet(error) {
        try? cache.delete(file)                 // best-effort：训练组损坏，孤儿槽不可恢复
        try pendingReplayRepo.clearReplay()      // durable 清（唯一清档点）
        return nil                               // 调用方回退从头 replay
    }
    // candle-load 段（真训练集/transient 错误 → 传播）
    let allCandles: [Period: [KLineCandle]]
    let mt: Int
    do {
        allCandles = try reader.loadAllCandles()
        mt = try maxTick(from: allCandles)
    } catch {
        reader.close()
        throw (error as? AppError) ?? .internalError(module: "E6b", detail: String(describing: error))
    }
    // scalar 前置校验段（codex whole-branch R1-F1）：make L220/L236-240 对越界 tick / 非有限·负 money·drawdown
    // 抛 .trainingSet(.emptyData)，与真训练集故障不可区分；若交给 make 段宽 catch 传播 → 不清槽 → resume-first
    // 每次撞同一损坏 scalar 槽 → 记录永久 brick。故 make 前分流：损坏 scalar = 损坏槽 → reader.close + durable
    // clearReplay（try：清失败=瞬态传播可重试）+ nil（回退从头）。fee 已被 loadReplay sanitized，非 brick 向量。
    guard (0...mt).contains(pending.globalTickIndex),
          pending.cashBalance.isFinite, pending.cashBalance >= 0,
          pending.accumulatedCapital.isFinite, pending.accumulatedCapital >= 0,
          pending.drawdown.peakCapital.isFinite, pending.drawdown.peakCapital >= 0,
          pending.drawdown.maxDrawdown.isFinite, pending.drawdown.maxDrawdown >= 0
    else {
        reader.close()
        try pendingReplayRepo.clearReplay()
        return nil
    }
    // make 段：position 已在 step 2 解码（slot payload，.dbCorrupted 已处理）；此块仅真训练集/transient 错误 → 传播
    do {
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
        replayBaseline = (engine.tick.globalTickIndex, engine.tradeOperations.count, engine.drawings.count,
                          engine.upperPanel.period, engine.lowerPanel.period)  // 续局基线=resumed 态（含周期，codex plan-R4/R14-F1）
        replayHasPersisted = true                 // 续局本就拥有该记录的槽 → 永不 clean-skip（codex plan-R6-F1）
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
@Test func replayTerminal_missingRecordContext_throwsNotSilent() async throws {
    // codex plan-R8-F1：终局缺 activeRecord.id → throw、保留会话（不静默返回 record 而留陈旧槽）
    let h = try CoordinatorTestHarness.make()
    let e = try await h.coordinator.replay(recordId: h.seededRecordId)
    e.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: e)
    h.coordinator.setActiveRecordNilForTesting()   // DEBUG 钩子：制造缺上下文（见 Step 3）
    await #expect(throws: (any Error).self) {
        _ = try await h.coordinator.replaySettlementPayload(engine: e)
    }
    #expect(try h.pendingReplayRepo.loadReplay() != nil)   // 槽未被静默清
}

@MainActor
@Test func replayDiscard_missingRecordContext_throws() async throws {
    let h = try CoordinatorTestHarness.make()
    let e = try await h.coordinator.replay(recordId: h.seededRecordId)
    e.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: e)
    h.coordinator.setActiveRecordNilForTesting()
    await #expect(throws: (any Error).self) {
        try await h.coordinator.discardSession()
    }
}

@MainActor
@Test func replayTerminal_conditionalClear_preservesOtherRecordSlot() async throws {
    // codex plan-R3-F1：A 有暂停槽；开新 replay B 未成功保存即到终局（手动结束）→ 终局条件清不删 A
    let h = try CoordinatorTestHarness.make(seedRecordIds: [101, 202])   // 两条 record（harness 支持多 seed）
    let eA = try await h.coordinator.replay(recordId: 101)
    eA.holdOrObserve(panel: .upper)
    try await h.coordinator.saveProgress(engine: eA)        // slot = 101
    await h.coordinator.endSession()
    let eB = try await h.coordinator.replay(recordId: 202)  // 开新 B，零操作（slot 仍 = 101）
    _ = try await h.coordinator.replaySettlementPayload(engine: eB)   // B 终局：条件清 ifRecordId=202 → 不动 101
    let slot = try h.pendingReplayRepo.loadReplay()
    #expect(slot?.recordId == 101)                          // A 的槽仍在
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
签名 `public func replaySettlementPayload(engine:) throws -> TrainingRecord` → `... async throws -> TrainingRecord`。**顺序**：①两 `guard`（mode + 活跃上下文）——**把 `activeRecord?.id` 也纳入 guard 的 let 绑定**（`guard activeEngine === engine, let reader = activeReader, let file = activeFile, let recordId = activeRecord?.id else { throw .internalError(...) }`），**缺则 throw、保留会话**（fail-closed，codex plan-R8-F1；不可静默成功）→ ②`await fenceAndDrainAutosaves()`（排空排队 autosave，此后无并发写）→ ③`let meta = try reader.loadMeta()` + 构造 `record`（**全部 throwing payload 工作，槽仍在**，字段计算不变）→ ④**仅在 payload 构建成功后**用**条件清** `try pendingReplayRepo.clearReplay(ifRecordId: recordId)`（recordId 来自 guard 绑定；**绝不**用无条件 `clearReplay()`——那会误删别记录 A 的槽，codex plan-R3-F1/R5-F2；无条件 `clearReplay()` 仅 reset/corrupt-恢复用）→ ⑤`return record`。
即在 `return TrainingRecord(...)` 之前先 `let record = TrainingRecord(...)`，然后：
```swift
        // 新需求10：fence 已在上方排空 autosave；payload 构建成功后才清槽（codex plan-R1-F2）。
        // **条件清（codex plan-R3-F1）**：仅清属于当前 replay 记录的槽——防"开新 replay B 未存即到终局"
        // 误删另一记录 A 的暂停槽。recordId 来自顶部 guard 绑定（缺则已 throw=fail-closed，codex plan-R8-F1）。
        // clearReplay 抛 → 方法抛、record 不返回 → caller 保留 session+槽、可重试（见 TrainingView）。
        try pendingReplayRepo.clearReplay(ifRecordId: recordId)
        return record
```
（`await fenceAndDrainAutosaves()` 插在两 guard 之后、`loadMeta` 之前。）

- [ ] **Step 3b: `discardSession` 清 replay（条件清）** — `discardSession()` 内（已 `await fenceAndDrainAutosaves()`）在清 pending 处加 replay 分支：
```swift
        // 新需求10：replay 局 discard 条件清 replay 槽（仅属当前记录，防误删别的记录槽，codex plan-R3-F1）；
        // **fail-closed（codex plan-R8-F1）**：replay 缺 activeRecord.id → throw、保留会话（不静默结束留陈旧槽）；
        // normal 清 pending_training（原逻辑）。
        if activeEngine?.flow.mode == .replay {
            guard let activeId = activeRecord?.id else {
                throw AppError.internalError(module: "E6b", detail: "replay discard without active record")
            }
            try pendingReplayRepo.clearReplay(ifRecordId: activeId)
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

- [ ] **Step 3f: DEBUG 测试钩子**（coordinator，镜像现有 `drainAutosaveForTesting`，仅供 fail-closed 守卫测试制造缺上下文）：
```swift
    #if DEBUG
    func setActiveRecordNilForTesting() { activeRecord = nil }
    #endif
```

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter replayTerminal_fencesAndClears_evenWithQueuedAutosave` / `--filter discardSession_replay_clears` / `--filter replayTerminal_missingRecordContext_throwsNotSilent` / `--filter replayDiscard_missingRecordContext_throws` + reset 测 → PASS。

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

加 make 守卫测试（codex plan-R3-F3：startTick > finalTick 须可恢复报错而非 trap）：
```swift
@MainActor
@Test func make_review_startTickAfterFinalTick_throwsNotTrap() throws {
    let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    let rec = TrainingRecord(id: 1, trainingSetFilename: "x.sqlite", createdAt: 0, stockCode: "1", stockName: "n",
        startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
        maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 5)
    // startTick(10) > finalTick(5)：guard 在候选校验/flow 构造前抛 → 不触 ClosedRange trap
    #expect(throws: AppError.self) {
        _ = try TrainingEngine.make(.review(record: rec, startTick: 10),
                                    allCandles: [:],
                                    initialCapital: 100_000, initialCashBalance: 100_000)
    }
}
```
> implementer：`make` 其余参数若无默认值则补最小合法值；关键是断言抛 `AppError`（不崩）。

加 ReviewFlow 公共构造边界守卫测试（codex plan-R12-F2：直接用 public init 传坏 startTick 读 range 不得 trap）：
```swift
@Test func reviewFlow_directBadStartTick_noTrap_degenerateRange() {
    let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
    let rec = TrainingRecord(id: 1, trainingSetFilename: "x.sqlite", createdAt: 0, stockCode: "1", stockName: "n",
        startYear: 2021, startMonth: 1, totalCapital: 100000, profit: 0, returnRate: 0,
        maxDrawdown: 0, buyCount: 0, sellCount: 0, feeSnapshot: fees, finalTick: 5)
    let rf = ReviewFlow(record: rec, startTick: 10)   // startTick>finalTick：钳位为退化 5...5，不 trap
    #expect(rf.allowedTickRange == 5...5)
    #expect(rf.initialTick == 5)
}
```

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
    // codex plan-R12-F2：钳位防 `startTick...finalTick` ClosedRange trap（类型边界安全网——
    // public init 可被直接传坏 startTick/corrupt record；`make` 守卫是正确-错误路径，此处保证读 range 永不崩）。
    // 合法路径（0<=startTick<=finalTick）下 safeStart==startTick / safeFinal==finalTick，语义不变。
    private var safeFinalTick: Int { max(0, record.finalTick) }
    private var safeStartTick: Int { max(0, min(startTick, safeFinalTick)) }
    public var initialTick: Int { safeStartTick }
    public var allowedTickRange: ClosedRange<Int> { safeStartTick...safeFinalTick }

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
- `make` 内 `case .review:`（**先校验 `finalTick >= startTick >= 0` 再构造 flow**，codex plan-R3-F3：损坏 record 的 finalTick < startTick 会让 `startTick...finalTick` ClosedRange 构造 trap 崩溃；须在构造前 throw 可恢复错误）：
```swift
        case .review(let record, let startTick):
            // codex plan-R3-F3：startTick 越界（损坏 record/metadata）→ 可恢复 trainingSet 错误，非 ClosedRange trap
            guard startTick >= 0, record.finalTick >= startTick else {
                throw AppError.trainingSet(.emptyData)
            }
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

@MainActor
@Test func stepReviewForward_usesFinerPeriod_notCoarseDefault() throws {
    // codex plan-R9-F1：复盘"下一根"按更细周期逐根，而非默认 activePanel(.lower=粗周期)跳一整天
    let e = try TrainingEngine.previewReview(startTick: 5)   // combo 一细一粗（如 m60/daily）
    let t0 = e.tick.globalTickIndex
    e.stepReviewForward()
    let delta = e.tick.globalTickIndex - t0
    // 对照：粗周期(.lower)一根的 delta
    let coarse = try TrainingEngine.previewReview(startTick: 5)
    let c0 = coarse.tick.globalTickIndex
    coarse.holdOrObserve(panel: .lower)
    let coarseDelta = coarse.tick.globalTickIndex - c0
    #expect(delta > 0)
    #expect(delta < coarseDelta)   // 细周期步进 < 粗周期一根（不会一击跳整天）
}
```
> implementer：用现有 `TrainingEngine.preview(...)` / fixture 构造 review/normal 引擎（preview 现已支持 `.review`；若需 startTick 用 B1 的 preview 改动）。

- [ ] **Step 2: 跑测试确认失败** — FAIL（jumpToEnd 不存在）。

- [ ] **Step 3: 实现 `jumpToEnd()` + `stepReviewForward()`**（紧邻 `advanceAndAccount` / `holdOrObserve`）
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

/// 新需求10（codex plan-R9-F1）：复盘「下一根」逐根推进。**按两 panel 中更细（stepsForPeriod 更小）的周期步进**，
/// 而非 activePanel（复盘隐藏了周期选择条，activePanel 停在默认 .lower=粗周期会一击跳一整天）。复用 holdOrObserve
/// （canAdvance 门控 + 只读无成交）。用户可单指竖滑切周期组合改粒度。
public func stepReviewForward() {
    let finerPanel: PanelId =
        stepsForPeriod(upperPanel.period) <= stepsForPeriod(lowerPanel.period) ? .upper : .lower
    holdOrObserve(panel: finerPanel)
}
```
> implementer：`stopAllDeceleration` / `reduce(.tradeTriggered)` / `resetOffsetAfterAutoTracking` / `stepsForPeriod` 复用 `advanceAndAccount`/`holdOrObserve` 同款（以源码现有方法名/访问级为准；`stepsForPeriod` 已是引擎内部函数，本方法同文件可直接调）。

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

// 真红测（codex plan-R15-F2）：保护 ReviewControlBar UI 内容/动作面——B4 前 ReviewControlBarContent 不存在 → 编译失败/红。
// 谓词测试在 B1 后即绿、不足以要求 UI 存在；本测试要求内容模型存在且按 showsJumpToEnd 给出正确按钮+动作。
@Test func reviewControlBarContent_buttons() {
    #expect(ReviewControlBarContent(showsJumpToEnd: false).buttons
            == [ReviewControlButton(action: .step, title: "下一根")])
    #expect(ReviewControlBarContent(showsJumpToEnd: true).buttons
            == [ReviewControlButton(action: .step, title: "下一根"),
                ReviewControlButton(action: .jumpToEnd, title: "快进到结尾")])
}
```
> 说明：`ReviewControlBar`/`TrainingView` 的 onAction→`stepReviewForward()`/`jumpToEnd()` 接线属 UIKit-gated（host swift test 编译为空），由 **Catalyst build 编译闸门** + 真机/模拟器验收覆盖；`ReviewControlBarContent` 内容/动作面（按钮存在性+文案+动作枚举）由本 host 测保护，`stepReviewForward`/`jumpToEnd` 引擎行为由 B2 host 测保护——三者合起来覆盖"引擎能力 + UI 内容 + 接线编译"全链路。

- [ ] **Step 2: 跑测试确认失败** — `swift test --filter reviewControlBarContent_buttons` → **FAIL/编译错**（`ReviewControlBarContent` 未建）。`showsReviewControls_predicate` 作回归锚（B1 后已绿）。

- [ ] **Step 3a: 新建 `ReviewControlBar.swift`（纯内容模型 + 动作枚举 + 薄壳，codex plan-R15-F2）**——与 `TradeActionBarContent`/`SettlementContent` 同范式：内容 host-可测、薄壳 Catalyst 编译。
```swift
import SwiftUI

/// 复盘控件条动作（新需求10）。Hashable 供 SwiftUI ForEach id。
public enum ReviewControlAction: Hashable, Sendable { case step, jumpToEnd }

public struct ReviewControlButton: Equatable, Sendable {
    public let action: ReviewControlAction
    public let title: String
    public init(action: ReviewControlAction, title: String) { self.action = action; self.title = title }
}

/// 平台无关纯内容（host-可测）：决定复盘条按哪些按钮。`showsJumpToEnd` 决定是否含「快进到结尾」。
public struct ReviewControlBarContent: Equatable, Sendable {
    public let buttons: [ReviewControlButton]
    public init(showsJumpToEnd: Bool) {
        var b = [ReviewControlButton(action: .step, title: "下一根")]
        if showsJumpToEnd { b.append(ReviewControlButton(action: .jumpToEnd, title: "快进到结尾")) }
        self.buttons = b
    }
}

/// 复盘专用控件条 SwiftUI 薄壳：仅复盘可步进态显示；不含买/卖。动作经单一 onAction 闭包上交。
public struct ReviewControlBar: View {
    private let content: ReviewControlBarContent
    private let onAction: (ReviewControlAction) -> Void
    public init(showsJumpToEnd: Bool, onAction: @escaping (ReviewControlAction) -> Void) {
        self.content = ReviewControlBarContent(showsJumpToEnd: showsJumpToEnd)
        self.onAction = onAction
    }
    public var body: some View {
        HStack(spacing: 12) {
            ForEach(content.buttons, id: \.action) { btn in
                Button { onAction(btn.action) } label: {
                    Text(btn.title).frame(maxWidth: .infinity).padding(.vertical, 12)
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
                ReviewControlBar(showsJumpToEnd: engine.flow.canJumpToEnd()) { action in
                    switch action {
                    case .step:      engine.stepReviewForward()   // codex plan-R9-F1：按更细周期逐根（不依赖隐藏的 activePanel）
                    case .jumpToEnd: engine.jumpToEnd()
                    }
                }
```
> implementer：将其并入既有 `if showsTradeButtons { ... }` 结构为 `if ... {} else if showsReviewControls {}`（保持 TradeActionBar 块原样，仅追加 else-if 分支占同槽位）。

- [ ] **Step 3c: 周期变化触发 autosave（codex plan-R14-F1 crash-safety）** — 既有 `.onChange(of: engine.upperPanel.period)` / `.onChange(of: engine.lowerPanel.period)` 处理器（RFC-B 加，现仅 `tradeStrip = nil`）追加 `lifecycle.autosave(immediate: false)`：
```swift
        .onChange(of: engine.upperPanel.period) { _, _ in tradeStrip = nil; lifecycle.autosave(immediate: false) }
        .onChange(of: engine.lowerPanel.period) { _, _ in tradeStrip = nil; lifecycle.autosave(immediate: false) }
```
> normal/replay：周期变化即落盘（含 upper/lowerPeriod），防"切周期后立即 crash/后台"丢周期；review：`shouldPersistProgress=false` → autosave no-op，无害。配 baseline 含周期（A4），切周期=脏 → Back/flush 也写。

- [ ] **Step 4: 跑测试确认通过** — `swift test --filter reviewControlBarContent_buttons` 和 `--filter showsReviewControls_predicate` → PASS。

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
