# P2 DownloadAcceptanceRunner 实施计划（Wave 2 顺位 6）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 P2 顶层编排类 `DownloadAcceptanceRunner`（`run` / `runBatch` / `retryPendingConfirmations`），把已 Wave 0 落地的 4 内部端口 + P1/P3a/P4-journal/P5 接线为 7 步下载验收 journal 状态机，并提供启动时孤儿确认恢复。

**Architecture:** runner 是**纯编排逻辑**——只依赖协议（`APIClient`/`CacheManager`/`TrainingSetDBFactory`/`AcceptanceJournalDAO` + 4 端口），不直接碰 GRDB/ZIPFoundation。因此落在 `KlineTrainerContracts/DownloadAcceptance/`（与 4 端口协议同目录），用既有 `#if DEBUG` fakes + 测试目标内新增的可配置 `FakeAPIClient`/`StubDBFactory`/`RecordingJournalDAO` 在 `KlineTrainerContractsTests` 测试。所有依赖协议均 `: Sendable`，故 runner 声明 `final class … : Sendable`（全 `let` 存储），`runBatch` 可用有界 `TaskGroup` 并发。

**Tech Stack:** Swift 6 (strict concurrency)；Swift Testing（`import Testing` / `@Suite` / `@Test` / `#expect` / `#require`）；SwiftPM 包 `ios/Contracts`，target `KlineTrainerContracts` + testTarget `KlineTrainerContractsTests`。

---

## Task 0：评审策略前置（§15.3）

- **review 通道**：本 PR 按 user 显式指令走 **opus 4.8 xhigh 对抗性 review**（plan-stage + branch-diff 两道闸门，各自跑到收敛），不走 codex（codex 近期配额耗尽，per 最近多个 PR memory）。
- **escalate 规则**：单道闸门超 5 轮未收敛 → escalate user（per `feedback_big_pr_codex_noncovergence`）。
- **CI 强制**：merge 前 `Mac Catalyst build-for-testing on macos-15` required check 必须真绿（本地 `swift test` 绿 ≠ CI 绿，per `feedback_swift_local_toolchain_blindspot`）。Catalyst 只验证编译/链接，runner 是纯逻辑（无运行时 gate），不涉及 C2/C7/C8 类运行时验收 residual。

---

## 关键设计决策（spec 字面 + 代码现状交叉核实）

所有决策已 grep 核实实现现状（非仅读 spec checklist，per `feedback_explore_agent_stale_spec_trust`）：

1. **runner 落点 = `KlineTrainerContracts`（非 `KlineTrainerPersistence`）**：runner 不依赖 GRDB/Zip，仅依赖协议；放 Contracts 让测试直接复用既有 `#if DEBUG` fakes（`InMemoryCacheManager`/`InMemoryAcceptanceJournalDAO`/`FakeZip*` 等）。

2. **`run`/`runBatch` 不调用 `reserveTrainingSets`**：spec §P2 签名 `run(meta:leaseId:)` / `runBatch(lease:concurrency:)` 都已**接收** meta/lease——fetchMeta（= `api.reserveTrainingSets`）是上游 caller（顺位 11 组合根 / U1）职责，对应 spec step 0「仅在内存持有 lease_id，不写 journal 行」。runner scope = step 1（download）→ step 7（confirm）。

3. **状态机硬约束：`stored → confirmed` 非法直跳**（`AcceptanceJournalDAOImpl.nextAllowed` L18-29 + `InMemoryAcceptanceJournalDAO` L202-213 镜像一致）：`stored` 只能转 `{confirmPending, rejected}`，`confirmPending` 才能转 `{confirmed, rejected}`。非法转换 = **silent NOOP**（不抛）。因此 runner **必须在调 confirm 前先写 `confirmPending`**，confirm 成功再写 `confirmed`。此设计同时满足崩溃安全：confirm 调用中途被 kill → 留下 `confirmPending` 行，启动 `retryPendingConfirmations` 续做。

4. **confirm 错误分类（`DefaultAPIClient.confirmTrainingSet` L78-83 实证）**：
   - 200 → 成功 → `confirmed`
   - 409 → `AppError.network(.leaseExpired)` ┐ **明确 reject**：journal → `rejected` + 删本地 cache 副本
   - 404 → `AppError.network(.leaseNotFound)` ┘
   - 其余一切（`.network(.timeout)`/`.offline`/`.serverError`/`.internalError`/`CancellationError`）→ **网络不确定**：停留 `confirmPending`，**保留**本地文件待重试（spec L300「只有 409/404 才转 rejected 并清理」）。

5. **`AcceptanceResult` 只有 `.confirmed`/`.rejected` 两态，无 pending 态**（spec L1764-1767）。映射：网络不确定 confirm → `run` 返回 `.rejected(networkErr)`，但 **journal 行停 `confirmPending` + 本地文件保留**（return 值是同步结果，journal 是持久恢复态，两者语义分离）。差异只体现在 journal 状态 + 是否删本地文件，不体现在 return type。

6. **`cache.store` 入参 = 已解压 sqlite（参数名 `downloadedZip` 是 Wave 0 误导名）⚠️ + temp 清理契约**：生产 `DefaultFileSystemCacheManager.store`（`DefaultFileSystemCacheManager.swift` L40-78）把入参 `src` 当**已解压 sqlite 文件**——L45-46 注释「src 已是解压后的 sqlite」+ L52 `stageFile(copyItem)` + L64 `readSchemaVersion(staging)`（开 `DatabaseQueue` 读 `PRAGMA user_version`）。**传 zip 在生产必失败**（`DatabaseQueue` 打不开 zip 字节）。故 `run` step 6 传 `sqliteURL`（extractor 解压产物），**不是** `zipURL`。`InMemoryCacheManager` L349-365 不读文件内容 → 仅用 fake 测会 silent 放行此类错误，**必须配一条真 `DefaultFileSystemCacheManager` 集成测试**（见 Task 7）。清理：`DefaultZipExtractor` L39-49 把 sqlite 平展进独立临时目录 `ZipExtract-<UUID>/`，故 `sqliteURL.deletingLastPathComponent()` = 解压临时目录；cleanup 传 `[下载zip, 解压临时目录]`（删目录连带 sqlite）。cache 副本是 store 用 `copyItem` 从 `sqliteURL` 另建的拷贝（复制在 cleanup 删解压目录**之前**完成，由 `run` 顺序保证），不在 cleanup 范围。

7. **reader 生命周期**：`openAndVerify` 返回绑定独立 `DatabaseQueue` 的 reader（L1830 契约）；runner 在 `verifyNonEmpty` 后、`cache.store`/cleanup **之前** `close()`（用嵌套 `do { … defer { reader.close() } }`，避免 cleanup 删解压目录时 DatabaseQueue 仍持文件）。

8. **schema 版本**：`openAndVerify(expectedSchemaVersion:)` 传**客户端可读常量** `TRAINING_SET_SCHEMA_VERSION = 1`（spec §11.3 L2202「双方共享常量」，当前代码未定义 → 本 PR 定义），**不传 `meta.schemaVersion`**（后者是服务端声明；若服务端给 schema≠1 而客户端只会读 1，传 meta 值会误放行不可读文件）。本 PR 是该常量的**唯一定义点**（顶层 `public let` + 注释标明所有权）；后续 P3a / 其它模块 import 复用，**不得重复定义**（防 redeclaration 编译错误）。

9. **错误边界（M0.4 L659）**：runner 不接触私有错误，只消费 `AppError`。所有上游协议已 `throws AppError`；唯一例外是 `DefaultAPIClient` 对协作取消重抛 `CancellationError`（L148-150）→ runner `asAppError` 把它映射为 `.internalError(module:"P2", detail:"cancelled")`（归入「非 409/404」→ confirm 时停 confirmPending / 早期步骤 rejected）。

10. **`AcceptanceResult` 加 `Equatable`**（spec 只写 `Sendable`）：`TrainingSetFile`/`AppError` 均 `Equatable`，加 `Equatable` 仅为测试断言便利，无行为影响。**此为相对 spec 的唯一加法，已记录。**

---

## File Structure

- **Create** `ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift`
  - `public enum AcceptanceResult: Equatable, Sendable`（`.confirmed(TrainingSetFile)` / `.rejected(AppError)`）
  - `public let TRAINING_SET_SCHEMA_VERSION = 1`
  - `public final class DownloadAcceptanceRunner: Sendable`（init + `run` + `runBatch` + `retryPendingConfirmations` + 私有 `attemptConfirm` + `asAppError`）
- **Create** `ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift`
  - 单元测试套件（fake 端口）+ 测试本地 helper：`FakeAPIClient` / `StubDBFactory` / `StubReader` / `RecordingJournalDAO` / `ThrowingStoreCache`
- **Create** `ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift`
  - 真实管道集成测试（真 `DefaultFileSystemCacheManager`/`DefaultZipExtractor`/`DefaultZipIntegrityVerifier`/`DefaultTrainingSetDBFactory` + 真 sqlite/zip fixture）——R1 Critical 配套，抓 fake 掩盖的「传错文件给 store」类 bug
- **Create** `docs/acceptance/2026-06-06-wave2-p2-download-acceptance-runner.md`（非 coder 可执行验收清单，中文）
- 不改任何既有文件（runner 是纯新增；4 端口/journal/api/cache 已 Wave 0 落地）。

---

## Task 1：模块脚手架 + 构造测试

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift`

- [ ] **Step 1: 确认基线绿**

Run: `cd "ios/Contracts" && swift build && swift test 2>&1 | tail -5`
Expected: build 成功；既有测试全 pass（origin/main 基线）。

- [ ] **Step 2: 写测试文件骨架 + helper + 构造测试（失败）**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

// MARK: - 测试本地 helper（仅本套件用，不进 Sources 公共 fake 面）

/// 可配置 APIClient 替身：download 返回固定 URL 或抛错；confirm 按序列 / 默认值决定成功/抛错。
private final class FakeAPIClient: APIClient, @unchecked Sendable {
    private let lock = NSLock()
    private let _download: Result<URL, AppError>
    private var _confirmSeq: [AppError?]          // 按调用顺序消费；nil = 成功
    private let _confirmDefault: AppError?         // 序列耗尽后的默认
    private var _downloadCalls: [Int] = []
    private var _confirmCalls: [(id: Int, leaseId: String)] = []

    init(download: Result<URL, AppError> = .success(URL(fileURLWithPath: "/tmp/ZipExtract-test/dl.zip")),
         confirmError: AppError? = nil,
         confirmSequence: [AppError?] = []) {
        _download = download
        _confirmDefault = confirmError
        _confirmSeq = confirmSequence
    }

    func reserveTrainingSets(count: Int) async throws -> LeaseResponse {
        throw AppError.internalError(module: "test", detail: "reserve_unused")
    }
    func downloadTrainingSet(id: Int) async throws -> URL {
        lock.lock(); _downloadCalls.append(id); let r = _download; lock.unlock()
        switch r { case .success(let u): return u; case .failure(let e): throw e }
    }
    func confirmTrainingSet(id: Int, leaseId: String) async throws {
        lock.lock()
        _confirmCalls.append((id, leaseId))
        let err = _confirmSeq.isEmpty ? _confirmDefault : _confirmSeq.removeFirst()
        lock.unlock()
        if let err { throw err }
    }
    var confirmCallCount: Int { lock.lock(); defer { lock.unlock() }; return _confirmCalls.count }
    var downloadCallCount: Int { lock.lock(); defer { lock.unlock() }; return _downloadCalls.count }
}

/// 极简 reader：dataVerifier 是 fake 会忽略它；唯一观测点是 close() 是否被调用。
private final class StubReader: TrainingSetReader, @unchecked Sendable {
    private let lock = NSLock()
    private var _closed = false
    func loadMeta() throws -> TrainingSetMeta {
        TrainingSetMeta(stockCode: "T", stockName: "T", startDatetime: 1, endDatetime: 1)
    }
    func loadAllCandles() throws -> [Period: [KLineCandle]] { [:] }
    func close() { lock.lock(); _closed = true; lock.unlock() }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
}

/// 可配置 factory：成功返回可观测 StubReader；或抛注入错误（测 .versionMismatch 分支）。
private final class StubDBFactory: TrainingSetDBFactory, @unchecked Sendable {
    private let error: AppError?
    private let lock = NSLock()
    private var _lastReader: StubReader?
    private var _lastExpectedVersion: Int?
    init(error: AppError? = nil) { self.error = error }
    func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
        lock.lock(); _lastExpectedVersion = expectedSchemaVersion; lock.unlock()
        if let error { throw error }
        let r = StubReader()
        lock.lock(); _lastReader = r; lock.unlock()
        return r
    }
    var lastReader: StubReader? { lock.lock(); defer { lock.unlock() }; return _lastReader }
    var lastExpectedVersion: Int? { lock.lock(); defer { lock.unlock() }; return _lastExpectedVersion }
}

/// 包装 InMemoryAcceptanceJournalDAO，额外记录所有「未抛错的 upsert 意图」状态序列，
/// 用于断言 runner 的状态推进顺序（含 stored→confirmPending→confirmed 的中间态）。
private final class RecordingJournalDAO: AcceptanceJournalDAO, @unchecked Sendable {
    let inner = InMemoryAcceptanceJournalDAO()
    private let lock = NSLock()
    private var _seq: [P2JournalState] = []
    func upsert(trainingSetId: Int, leaseId: String, state: P2JournalState,
                sqliteLocalPath: String?, contentHash: String?, lastError: String?) throws {
        try inner.upsert(trainingSetId: trainingSetId, leaseId: leaseId, state: state,
                         sqliteLocalPath: sqliteLocalPath, contentHash: contentHash, lastError: lastError)
        lock.lock(); _seq.append(state); lock.unlock()
    }
    func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] { try inner.listByState(state) }
    func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {
        try inner.deleteByIdLease(trainingSetId: trainingSetId, leaseId: leaseId)
    }
    var sequence: [P2JournalState] { lock.lock(); defer { lock.unlock() }; return _seq }
}

// MARK: - 共享构造 helper

private func makeMeta(id: Int = 1, contentHash: String = "deadbeef") -> TrainingSetMetaItem {
    TrainingSetMetaItem(id: id, stockCode: "000001", stockName: "平安银行",
                        filename: "set\(id).zip", schemaVersion: 1, contentHash: contentHash)
}

@Suite("P2 DownloadAcceptanceRunner")
struct DownloadAcceptanceRunnerTests {

    @Test func constructs_withAllFakes_isSendable() {
        let runner = DownloadAcceptanceRunner(
            api: FakeAPIClient(),
            cache: InMemoryCacheManager(),
            dbFactory: StubDBFactory(),
            journal: InMemoryAcceptanceJournalDAO(),
            integrity: FakeZipIntegrityVerifier(),
            extractor: FakeZipExtractor(),
            dataVerifier: FakeTrainingSetDataVerifier(),
            cleaner: FakeDownloadAcceptanceCleaner())
        let _: any Sendable = runner   // 编译期断言 Sendable
    }
}
```

- [ ] **Step 3: 跑测试确认编译失败**

Run: `cd "ios/Contracts" && swift test --filter DownloadAcceptanceRunnerTests 2>&1 | tail -15`
Expected: 编译错误（`AcceptanceResult` / `TRAINING_SET_SCHEMA_VERSION` / `DownloadAcceptanceRunner` 未定义）。

- [ ] **Step 4: 写最小脚手架使其编译通过**

创建 `ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift`：

```swift
// Kline Trainer Swift Contracts — P2 DownloadAcceptanceRunner（Wave 2 顺位 6）
// Spec: kline_trainer_modules_v1.4.md §P2 (line 1761-1836) + M0.1 journal (230-300)
//
// 纯编排：只依赖协议（P1/P5/P3a/P4-journal + 4 内部端口），按 7 步 journal 状态机驱动；
// 提供 run / runBatch / retryPendingConfirmations（启动孤儿确认恢复）。
// 错误边界（M0.4 L659）：不接触私有错误，只消费 AppError。

import Foundation

/// 客户端可读的训练组 sqlite schema 版本（M0.1 共享常量，spec §11.3 L2202）。
/// 本 PR 是该常量的唯一定义点；P3a / 其它模块 import 复用，勿重复定义。
public let TRAINING_SET_SCHEMA_VERSION = 1

/// 下载验收的同步结果（spec §P2 L1764-1767）。
/// 注：`.rejected` 同时覆盖「服务端明确拒收(409/404)」与「网络不确定」两种结局——
/// 区别在 journal 状态 + 是否删本地文件，不在 return type（详见 plan 关键决策 5）。
public enum AcceptanceResult: Equatable, Sendable {
    case confirmed(TrainingSetFile)
    case rejected(AppError)
}

public final class DownloadAcceptanceRunner: Sendable {
    private let api: any APIClient
    private let cache: any CacheManager
    private let dbFactory: any TrainingSetDBFactory
    private let journal: any AcceptanceJournalDAO
    private let integrity: any ZipIntegrityVerifying
    private let extractor: any ZipExtracting
    private let dataVerifier: any TrainingSetDataVerifying
    private let cleaner: any DownloadAcceptanceCleaning

    public init(api: any APIClient,
                cache: any CacheManager,
                dbFactory: any TrainingSetDBFactory,
                journal: any AcceptanceJournalDAO,
                integrity: any ZipIntegrityVerifying,
                extractor: any ZipExtracting,
                dataVerifier: any TrainingSetDataVerifying,
                cleaner: any DownloadAcceptanceCleaning) {
        self.api = api
        self.cache = cache
        self.dbFactory = dbFactory
        self.journal = journal
        self.integrity = integrity
        self.extractor = extractor
        self.dataVerifier = dataVerifier
        self.cleaner = cleaner
    }

    public func run(meta: TrainingSetMetaItem, leaseId: String) async -> AcceptanceResult {
        fatalError("Task 2")
    }

    public func runBatch(lease: LeaseResponse, concurrency: Int = 1) async -> [AcceptanceResult] {
        fatalError("Task 6")
    }

    public func retryPendingConfirmations() async {
        fatalError("Task 5")
    }
}
```

- [ ] **Step 5: 跑测试确认 Task 1 通过**

Run: `cd "ios/Contracts" && swift test --filter "DownloadAcceptanceRunnerTests/constructs_withAllFakes_isSendable" 2>&1 | tail -8`
Expected: `constructs_withAllFakes_isSendable` PASS（其它测试尚未加）。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift
git commit -m "feat(P2): DownloadAcceptanceRunner 脚手架 + 测试 helper + 构造测试"
```

---

## Task 2：`run()` happy path → confirmed（全 7 步状态机）

**Files:**
- Modify: `DownloadAcceptanceRunner.swift`（实现 `run` + 私有 `attemptConfirm` + `asAppError`）
- Test: `DownloadAcceptanceRunnerTests.swift`

- [ ] **Step 1: 写 happy-path 测试（失败）**

在 `@Suite` 内追加：

```swift
    @Test func run_happyPath_returnsConfirmed_walksFullStateMachine() async throws {
        let meta = makeMeta(id: 7, contentHash: "0badf00d")
        let api = FakeAPIClient(confirmError: nil)               // confirm 成功
        let cache = InMemoryCacheManager()
        let journal = RecordingJournalDAO()
        let cleaner = FakeDownloadAcceptanceCleaner()
        let factory = StubDBFactory()
        let runner = DownloadAcceptanceRunner(
            api: api, cache: cache, dbFactory: factory, journal: journal,
            integrity: FakeZipIntegrityVerifier(),
            extractor: FakeZipExtractor(returnURL: URL(fileURLWithPath: "/tmp/ZipExtract-x/set7.sqlite")),
            dataVerifier: FakeTrainingSetDataVerifier(),
            cleaner: cleaner)

        let result = await runner.run(meta: meta, leaseId: "11111111-1111-1111-1111-111111111111")

        // 1) 返回 confirmed + file 落在 cache
        guard case .confirmed(let file) = result else {
            Issue.record("expected .confirmed, got \(result)"); return
        }
        #expect(file.id == 7)
        #expect(cache.listAvailable().contains(where: { $0.id == 7 }))

        // 2) 状态推进顺序（含中间态；stored→confirmed 必经 confirmPending）
        #expect(journal.sequence == [.downloaded, .crcOK, .unzipped, .dbVerified, .stored, .confirmPending, .confirmed])

        // 3) 最终 applied 状态 = confirmed（1 行）
        #expect(try journal.listByState(.confirmed).count == 1)
        #expect(try journal.listByState(.stored).isEmpty)

        // 4) reader 已关闭；expectedSchemaVersion 传共享常量
        #expect(factory.lastReader?.closed == true)
        #expect(factory.lastExpectedVersion == TRAINING_SET_SCHEMA_VERSION)

        // 5) temp 已清理（下载 zip + 解压临时目录），cache 副本不在清理列表
        let cleaned = cleaner.cleanedURLs().map(\.path)
        #expect(cleaned.contains("/tmp/ZipExtract-test/dl.zip"))
        #expect(cleaned.contains("/tmp/ZipExtract-x"))   // = sqlite.deletingLastPathComponent()
    }
```

- [ ] **Step 2: 跑确认失败**

Run: `cd "ios/Contracts" && swift test --filter "run_happyPath_returnsConfirmed_walksFullStateMachine" 2>&1 | tail -15`
Expected: crash/fail（`run` 当前是 `fatalError("Task 2")`）。

- [ ] **Step 3: 实现 `run` + `attemptConfirm` + `asAppError`**

替换 `DownloadAcceptanceRunner.swift` 中 `run` 的 `fatalError` 体，并在类内追加私有成员（放在 `retryPendingConfirmations` 之后、类结束前）：

```swift
    public func run(meta: TrainingSetMetaItem, leaseId: String) async -> AcceptanceResult {
        // Step 1：下载 zip（download 完成前不写 journal 行——spec L1820 step 0/1）
        let zipURL: URL
        do {
            zipURL = try await api.downloadTrainingSet(id: meta.id)
        } catch {
            return .rejected(Self.asAppError(error))   // 网络失败，无 journal 行
        }

        var tempURLs: [URL] = [zipURL]
        do {
            // 首条 journal 行 .downloaded
            try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .downloaded,
                               sqliteLocalPath: nil, contentHash: nil, lastError: nil)

            // Step 2：CRC32
            try integrity.verify(zipURL: zipURL, expectedCRC32Hex: meta.contentHash)
            try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .crcOK,
                               sqliteLocalPath: nil, contentHash: nil, lastError: nil)

            // Step 3：解压（解压临时目录 = sqlite 的父目录，纳入清理）
            let sqliteURL = try extractor.extract(zipURL: zipURL)
            tempURLs.append(sqliteURL.deletingLastPathComponent())
            try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .unzipped,
                               sqliteLocalPath: nil, contentHash: nil, lastError: nil)

            // Step 4+5：openAndVerify + verifyNonEmpty（reader 在 cache.store/cleanup 前关闭）
            do {
                let reader = try dbFactory.openAndVerify(file: sqliteURL,
                                                         expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
                defer { reader.close() }
                try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .dbVerified,
                                   sqliteLocalPath: nil, contentHash: nil, lastError: nil)
                try dataVerifier.verifyNonEmpty(reader: reader)   // 保持 dbVerified
            }

            // Step 6：把**解压后的 sqlite** 存入 cache。
            // ⚠️ store 参数名 `downloadedZip` 是 Wave 0 冻结代码的误导名——生产
            // DefaultFileSystemCacheManager.store 把入参当**已解压 sqlite**：stageFile(copyItem)
            // 后 readSchemaVersion 开 DatabaseQueue 读 PRAGMA user_version（DefaultFileSystemCacheManager.swift
            // L45-46 注释 + L52/L64）。传 zip 必失败。故传 sqliteURL（extractor 产物），不是 zipURL。
            let file = try cache.store(downloadedZip: sqliteURL, meta: meta)
            try journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .stored,
                               sqliteLocalPath: file.localURL.path, contentHash: meta.contentHash,
                               lastError: nil)

            // Step 7：confirm（stored → confirmPending → confirmed/rejected/停留）
            let outcome = await attemptConfirm(trainingSetId: meta.id, leaseId: leaseId,
                                               sqliteLocalPath: file.localURL.path)
            cleaner.cleanup(tempURLs: tempURLs)   // 清 temp zip + 解压目录（非 cache 副本）
            switch outcome {
            case .confirmed:
                return .confirmed(file)
            case .rejected(let e):                // 409/404 → 删本地 cache 副本
                try? cache.delete(file)
                return .rejected(e)
            case .pending(let e):                 // 网络不确定 → 保留 cache 副本待重试
                return .rejected(e)
            }
        } catch {
            let appErr = Self.asAppError(error)
            try? journal.upsert(trainingSetId: meta.id, leaseId: leaseId, state: .rejected,
                                sqliteLocalPath: nil, contentHash: nil, lastError: appErr.userMessage)
            cleaner.cleanup(tempURLs: tempURLs)
            return .rejected(appErr)
        }
    }

    // MARK: - confirm 子状态机（run + retry 共用）

    private enum ConfirmOutcome { case confirmed; case rejected(AppError); case pending(AppError) }

    /// 先标 confirmPending（状态机要求 + 崩溃安全），再调 confirm。
    /// 成功 → confirmed；409/404 → rejected；其余 → 停留 confirmPending。
    private func attemptConfirm(trainingSetId: Int, leaseId: String,
                                sqliteLocalPath: String?) async -> ConfirmOutcome {
        try? journal.upsert(trainingSetId: trainingSetId, leaseId: leaseId, state: .confirmPending,
                            sqliteLocalPath: sqliteLocalPath, contentHash: nil, lastError: nil)
        do {
            try await api.confirmTrainingSet(id: trainingSetId, leaseId: leaseId)
            try? journal.upsert(trainingSetId: trainingSetId, leaseId: leaseId, state: .confirmed,
                                sqliteLocalPath: sqliteLocalPath, contentHash: nil, lastError: nil)
            return .confirmed
        } catch {
            let e = Self.asAppError(error)
            switch e {
            case .network(.leaseExpired), .network(.leaseNotFound):
                try? journal.upsert(trainingSetId: trainingSetId, leaseId: leaseId, state: .rejected,
                                    sqliteLocalPath: nil, contentHash: nil, lastError: e.userMessage)
                return .rejected(e)
            default:
                return .pending(e)   // 停留 confirmPending；本地文件保留
            }
        }
    }

    /// 边界翻译：上游协议已 throws AppError；DefaultAPIClient 协作取消重抛 CancellationError → 标 P2 内部。
    private static func asAppError(_ error: Error) -> AppError {
        if let e = error as? AppError { return e }
        if error is CancellationError { return .internalError(module: "P2", detail: "cancelled") }
        return .internalError(module: "P2", detail: "unexpected")
    }
```

- [ ] **Step 4: 跑确认通过**

Run: `cd "ios/Contracts" && swift test --filter "run_happyPath_returnsConfirmed_walksFullStateMachine" 2>&1 | tail -10`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift
git commit -m "feat(P2): run() happy path 全 7 步状态机 → confirmed"
```

---

## Task 3：`run()` confirm 前各步失败 → rejected + journal rejected + cleanup

**Files:**
- Test: `DownloadAcceptanceRunnerTests.swift`（实现已在 Task 2 完成，本 Task 只加测试验证失败分支）

- [ ] **Step 1: 写各失败分支测试（应已通过，验证 Task 2 实现正确）**

追加：

```swift
    /// 构造一个除指定失败点外全成功的 runner。
    private func makeRunner(
        api: FakeAPIClient = FakeAPIClient(),
        cache: CacheManager = InMemoryCacheManager(),
        journal: AcceptanceJournalDAO = InMemoryAcceptanceJournalDAO(),
        factory: TrainingSetDBFactory = StubDBFactory(),
        integrity: ZipIntegrityVerifying = FakeZipIntegrityVerifier(),
        extractor: ZipExtracting = FakeZipExtractor(returnURL: URL(fileURLWithPath: "/tmp/ZipExtract-y/x.sqlite")),
        dataVerifier: TrainingSetDataVerifying = FakeTrainingSetDataVerifier(),
        cleaner: DownloadAcceptanceCleaning = FakeDownloadAcceptanceCleaner()
    ) -> DownloadAcceptanceRunner {
        DownloadAcceptanceRunner(api: api, cache: cache, dbFactory: factory, journal: journal,
                                 integrity: integrity, extractor: extractor,
                                 dataVerifier: dataVerifier, cleaner: cleaner)
    }

    @Test func run_downloadFails_rejected_noJournalRow() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cleaner = FakeDownloadAcceptanceCleaner()
        let runner = makeRunner(api: FakeAPIClient(download: .failure(.network(.offline))),
                                journal: journal, cleaner: cleaner)
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.network(.offline)))
        // 无 journal 行（download 完成前不写）
        for s in P2JournalState.allCases { #expect(try journal.listByState(s).isEmpty) }
        // download 未成功 → 无 temp 可清
        #expect(cleaner.cleanedURLs().isEmpty)
    }

    @Test func run_crcFails_rejected_journalRejected_cleaned() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cleaner = FakeDownloadAcceptanceCleaner()
        let runner = makeRunner(journal: journal,
                                integrity: FakeZipIntegrityVerifier(throwing: .trainingSet(.crcFailed)),
                                cleaner: cleaner)
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.trainingSet(.crcFailed)))
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(cleaner.cleanedURLs().map(\.path).contains("/tmp/ZipExtract-test/dl.zip"))
    }

    @Test func run_extractFails_rejected_journalRejected() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = makeRunner(journal: journal,
                                extractor: FakeZipExtractor(throwing: .trainingSet(.unzipFailed)))
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.trainingSet(.unzipFailed)))
        #expect(try journal.listByState(.rejected).count == 1)
    }

    @Test func run_openVerifyFails_rejected_versionMismatch() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = makeRunner(journal: journal,
                                factory: StubDBFactory(error: .trainingSet(.versionMismatch(expected: 1, got: 2))))
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.trainingSet(.versionMismatch(expected: 1, got: 2))))
        #expect(try journal.listByState(.rejected).count == 1)
    }

    @Test func run_verifyNonEmptyFails_rejected_emptyData_readerClosed() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let factory = StubDBFactory()
        let runner = makeRunner(journal: journal, factory: factory,
                                dataVerifier: FakeTrainingSetDataVerifier(throwing: .trainingSet(.emptyData)))
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.trainingSet(.emptyData)))
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(factory.lastReader?.closed == true)   // 失败路径也关闭 reader
    }

    @Test func run_cacheStoreFails_rejected_persistence() async throws {
        // 用抛错 cache：自定义一个只在 store 抛 diskFull 的替身
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = makeRunner(cache: ThrowingStoreCache(error: .persistence(.diskFull)), journal: journal)
        let result = await runner.run(meta: makeMeta(), leaseId: "lease")
        #expect(result == .rejected(.persistence(.diskFull)))
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(try journal.listByState(.stored).isEmpty)
    }
```

并在 helper 区追加抛错 cache：

```swift
/// store 固定抛错的 cache 替身（测 step 6 失败）。其它方法 no-op。
private final class ThrowingStoreCache: CacheManager, @unchecked Sendable {
    private let error: AppError
    init(error: AppError) { self.error = error }
    func listAvailable() -> [TrainingSetFile] { [] }
    func pickRandom() -> TrainingSetFile? { nil }
    func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile { throw error }
    func touch(_: TrainingSetFile) {}
    func delete(_: TrainingSetFile) throws {}
}
```

- [ ] **Step 2: 跑确认全通过**

Run: `cd "ios/Contracts" && swift test --filter "DownloadAcceptanceRunnerTests" 2>&1 | tail -12`
Expected: 全 PASS（Task 2 的 `run` 实现已覆盖这些分支）。若某分支失败 → 回 Task 2 修 `run`。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift
git commit -m "test(P2): run() confirm 前各步失败分支（crc/unzip/version/empty/store）"
```

---

## Task 4：`run()` confirm 步分支（409/404 reject+删文件 / 网络不确定保留 / 取消）

**Files:**
- Test: `DownloadAcceptanceRunnerTests.swift`

- [ ] **Step 1: 写 confirm 分支测试**

```swift
    @Test func run_confirm409_rejected_deletesLocalFile() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseExpired)),
                                cache: cache, journal: journal)
        let result = await runner.run(meta: makeMeta(id: 3), leaseId: "lease")
        #expect(result == .rejected(.network(.leaseExpired)))
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(cache.listAvailable().contains(where: { $0.id == 3 }) == false)  // 本地副本已删
    }

    @Test func run_confirm404_rejected_deletesLocalFile() async throws {
        let cache = InMemoryCacheManager()
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseNotFound)), cache: cache)
        let result = await runner.run(meta: makeMeta(id: 4), leaseId: "lease")
        #expect(result == .rejected(.network(.leaseNotFound)))
        #expect(cache.listAvailable().contains(where: { $0.id == 4 }) == false)
    }

    @Test func run_confirmNetworkUncertain_rejected_butKeepsFileAndPending() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.timeout)),
                                cache: cache, journal: journal)
        let result = await runner.run(meta: makeMeta(id: 5), leaseId: "lease")
        #expect(result == .rejected(.network(.timeout)))
        // 文件保留 + journal 停 confirmPending（待启动重试）
        #expect(cache.listAvailable().contains(where: { $0.id == 5 }))
        #expect(try journal.listByState(.confirmPending).count == 1)
        #expect(try journal.listByState(.rejected).isEmpty)
    }

    @Test func run_confirmServerError5xx_keepsFileAndPending() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.serverError(code: 503))),
                                cache: cache, journal: journal)
        let result = await runner.run(meta: makeMeta(id: 6), leaseId: "lease")
        #expect(result == .rejected(.network(.serverError(code: 503))))
        #expect(cache.listAvailable().contains(where: { $0.id == 6 }))   // 5xx 非 409/404 → 保留
        #expect(try journal.listByState(.confirmPending).count == 1)
    }
```

- [ ] **Step 2: 跑确认通过**

Run: `cd "ios/Contracts" && swift test --filter "DownloadAcceptanceRunnerTests" 2>&1 | tail -12`
Expected: 全 PASS。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift
git commit -m "test(P2): run() confirm 分支（409/404 删文件 / 网络不确定保留 confirmPending）"
```

---

## Task 5：`retryPendingConfirmations()` 启动孤儿确认恢复

**Files:**
- Modify: `DownloadAcceptanceRunner.swift`（实现 `retryPendingConfirmations`）
- Test: `DownloadAcceptanceRunnerTests.swift`

- [ ] **Step 1: 写 retry 测试（失败）**

```swift
    /// 直接在 journal 灌一条已 stored 的行（绕过 run，模拟「上次运行落盘后崩溃」）。
    private func seedStored(_ journal: AcceptanceJournalDAO, id: Int, leaseId: String,
                           path: String, hash: String = "0badf00d") throws {
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .downloaded,
                           sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .crcOK,
                           sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .unzipped,
                           sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .dbVerified,
                           sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try journal.upsert(trainingSetId: id, leaseId: leaseId, state: .stored,
                           sqliteLocalPath: path, contentHash: hash, lastError: nil)
    }

    @Test func retry_storedRow_confirmSuccess_becomesConfirmed() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        try seedStored(journal, id: 1, leaseId: "L1", path: "/tmp/a.sqlite")
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil), journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.confirmed).count == 1)
        #expect(try journal.listByState(.stored).isEmpty)
    }

    @Test func retry_confirmPendingRow_confirmSuccess_becomesConfirmed() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        try seedStored(journal, id: 2, leaseId: "L2", path: "/tmp/b.sqlite")
        try journal.upsert(trainingSetId: 2, leaseId: "L2", state: .confirmPending,
                           sqliteLocalPath: "/tmp/b.sqlite", contentHash: nil, lastError: nil)
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil), journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.confirmed).count == 1)
    }

    @Test func retry_scansBothStoredAndConfirmPending() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        try seedStored(journal, id: 1, leaseId: "L1", path: "/tmp/1.sqlite")          // stored
        try seedStored(journal, id: 2, leaseId: "L2", path: "/tmp/2.sqlite")
        try journal.upsert(trainingSetId: 2, leaseId: "L2", state: .confirmPending,
                           sqliteLocalPath: "/tmp/2.sqlite", contentHash: nil, lastError: nil)  // confirmPending
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil), journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.confirmed).count == 2)   // 两类都被扫到
    }

    @Test func retry_confirm409_rejectsAndDeletesCacheFile() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        // 先把文件灌进 cache（id=9）
        _ = try cache.store(downloadedZip: URL(fileURLWithPath: "/tmp/9.zip"), meta: makeMeta(id: 9))
        try seedStored(journal, id: 9, leaseId: "L9", path: "/tmp/9.sqlite")
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseNotFound)),
                                cache: cache, journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.rejected).count == 1)
        #expect(cache.listAvailable().contains(where: { $0.id == 9 }) == false)  // 本地副本已删
    }

    @Test func retry_confirmNetworkUncertain_staysPending_keepsFile() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = InMemoryCacheManager()
        _ = try cache.store(downloadedZip: URL(fileURLWithPath: "/tmp/8.zip"), meta: makeMeta(id: 8))
        try seedStored(journal, id: 8, leaseId: "L8", path: "/tmp/8.sqlite")
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.offline)),
                                cache: cache, journal: journal)
        await runner.retryPendingConfirmations()
        #expect(try journal.listByState(.confirmPending).count == 1)
        #expect(try journal.listByState(.rejected).isEmpty)
        #expect(cache.listAvailable().contains(where: { $0.id == 8 }))  // 保留
    }

    @Test func retry_emptyJournal_noCrash() async {
        let runner = makeRunner(journal: InMemoryAcceptanceJournalDAO())
        await runner.retryPendingConfirmations()   // 无行 → 安全 no-op
    }
```

- [ ] **Step 2: 跑确认失败**

Run: `cd "ios/Contracts" && swift test --filter "retry_" 2>&1 | tail -15`
Expected: crash/fail（`retryPendingConfirmations` 是 `fatalError("Task 5")`）。

- [ ] **Step 3: 实现 `retryPendingConfirmations`**

替换 `DownloadAcceptanceRunner.swift` 中 `retryPendingConfirmations` 的 `fatalError` 体：

```swift
    public func retryPendingConfirmations() async {
        let stored = (try? journal.listByState(.stored)) ?? []
        let pending = (try? journal.listByState(.confirmPending)) ?? []
        for row in stored + pending {
            let outcome = await attemptConfirm(trainingSetId: row.trainingSetId,
                                               leaseId: row.leaseId,
                                               sqliteLocalPath: row.sqliteLocalPath)
            if case .rejected = outcome {        // 409/404 → 清本地 cache 副本
                if let file = cache.listAvailable().first(where: { $0.id == row.trainingSetId }) {
                    try? cache.delete(file)
                }
            }
            // confirmed / pending：journal 已更新；pending 保留文件
        }
    }
```

- [ ] **Step 4: 跑确认通过**

Run: `cd "ios/Contracts" && swift test --filter "retry_" 2>&1 | tail -12`
Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift
git commit -m "feat(P2): retryPendingConfirmations 启动孤儿确认恢复（扫 stored ∪ confirmPending）"
```

---

## Task 6：`runBatch()` 有界并发 + 保序

**Files:**
- Modify: `DownloadAcceptanceRunner.swift`（实现 `runBatch`）
- Test: `DownloadAcceptanceRunnerTests.swift`

- [ ] **Step 1: 写 runBatch 测试（失败）**

```swift
    private func makeLease(ids: [Int], leaseId: String = "BL") -> LeaseResponse {
        LeaseResponse(leaseId: leaseId, expiresAt: "2026-12-31T00:00:00Z",
                      sets: ids.map { makeMeta(id: $0) })
    }

    @Test func runBatch_empty_returnsEmpty() async {
        let runner = makeRunner()
        let results = await runner.runBatch(lease: makeLease(ids: []))
        #expect(results.isEmpty)
    }

    @Test func runBatch_serial_resultsInInputOrder() async throws {
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil))
        let results = await runner.runBatch(lease: makeLease(ids: [10, 11, 12]), concurrency: 1)
        #expect(results.count == 3)
        for r in results { if case .rejected = r { Issue.record("expected all confirmed") } }
        // 保序：confirmed file.id 与输入顺序一致
        let ids = results.map { r -> Int? in if case .confirmed(let f) = r { return f.id } else { return nil } }
        #expect(ids == [10, 11, 12])
    }

    @Test func runBatch_concurrency2_allProcessed_orderPreserved() async throws {
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = makeRunner(api: FakeAPIClient(confirmError: nil), journal: journal)
        let results = await runner.runBatch(lease: makeLease(ids: [1, 2, 3, 4, 5]), concurrency: 2)
        let ids = results.map { r -> Int? in if case .confirmed(let f) = r { return f.id } else { return nil } }
        #expect(ids == [1, 2, 3, 4, 5])
        // 并发写不互相污染 journal：每个 id 各有独立 confirmed 行（R1 Low-2 修订）
        #expect(try journal.listByState(.confirmed).count == 5)
    }

    @Test func runBatch_mixedOutcomes_orderPreserved() async throws {
        // 全部 confirm 用 leaseNotFound → 全 rejected，但仍保序、数量正确
        let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseNotFound)))
        let results = await runner.runBatch(lease: makeLease(ids: [20, 21]), concurrency: 1)
        #expect(results.count == 2)
        #expect(results == [.rejected(.network(.leaseNotFound)), .rejected(.network(.leaseNotFound))])
    }
```

- [ ] **Step 2: 跑确认失败**

Run: `cd "ios/Contracts" && swift test --filter "runBatch_" 2>&1 | tail -15`
Expected: crash/fail（`runBatch` 是 `fatalError("Task 6")`）。

- [ ] **Step 3: 实现 `runBatch`**

替换 `DownloadAcceptanceRunner.swift` 中 `runBatch` 的 `fatalError` 体：

```swift
    public func runBatch(lease: LeaseResponse, concurrency: Int = 1) async -> [AcceptanceResult] {
        let sets = lease.sets
        guard !sets.isEmpty else { return [] }
        let limit = min(max(1, concurrency), sets.count)
        let leaseId = lease.leaseId
        var results = [AcceptanceResult?](repeating: nil, count: sets.count)

        await withTaskGroup(of: (Int, AcceptanceResult).self) { group in
            var next = 0
            // 初始注入至多 limit 个任务
            while next < limit {
                let i = next
                group.addTask { (i, await self.run(meta: sets[i], leaseId: leaseId)) }
                next += 1
            }
            // 完成一个补一个，维持在飞 ≤ limit
            while let (idx, res) = await group.next() {
                results[idx] = res
                if next < sets.count {
                    let i = next
                    group.addTask { (i, await self.run(meta: sets[i], leaseId: leaseId)) }
                    next += 1
                }
            }
        }
        // 每个 index 恰好被一个任务填充一次 → 全非 nil（force-unwrap 安全）。
        return results.map { $0! }
    }
```

- [ ] **Step 4: 跑确认通过**

Run: `cd "ios/Contracts" && swift test --filter "runBatch_" 2>&1 | tail -12`
Expected: 全 PASS。

- [ ] **Step 5: 全套件回归 + strict-concurrency 检查**

Run: `cd "ios/Contracts" && swift test 2>&1 | tail -8`
Expected: 全套件 PASS（含既有 + 新增 P2 测试），0 编译警告/strict-concurrency 错误。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift
git commit -m "feat(P2): runBatch 有界并发 TaskGroup + 输入序保结果"
```

---

## Task 7：真实管道集成测试（R1 Critical 配套）

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift`

**Why（R1 Critical）：** Task 1-6 全用 `InMemoryCacheManager`（不读文件内容）测——无法抓「runner 传错文件给 `cache.store`」类 bug，且 Catalyst CI 只 build-for-testing 不跑测试。本 Task 用**真实** `DefaultFileSystemCacheManager` + `DefaultZipIntegrityVerifier` + `DefaultZipExtractor` + `DefaultTrainingSetDBFactory` + 真 sqlite/zip fixture 跑一条 happy-path，证明 runner 传给真 store 的是**可被打开的 sqlite**（若 run() 误传 zipURL，真 store 开 DatabaseQueue 必失败 → 测试红）。

- [ ] **Step 1: 写真实管道集成测试**

创建 `ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift`：

```swift
import Testing
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

/// 本地 APIClient 替身（Persistence 测试目标用；与 Contracts 测试里的同名 helper 各自独立）。
private final class FakeAPIClient: APIClient, @unchecked Sendable {
    private let _download: Result<URL, AppError>
    private let _confirmError: AppError?
    init(download: Result<URL, AppError>, confirmError: AppError? = nil) {
        _download = download; _confirmError = confirmError
    }
    func reserveTrainingSets(count: Int) async throws -> LeaseResponse {
        throw AppError.internalError(module: "test", detail: "unused")
    }
    func downloadTrainingSet(id: Int) async throws -> URL {
        switch _download { case .success(let u): return u; case .failure(let e): throw e }
    }
    func confirmTrainingSet(id: Int, leaseId: String) async throws {
        if let e = _confirmError { throw e }
    }
}

@Suite("P2 DownloadAcceptanceRunner 真实管道集成")
struct DownloadAcceptanceRunnerIntegrationTests {

    @Test func run_realPipeline_happyPath_storesAndConfirms() async throws {
        // 1) 造真训练组 sqlite（user_version=1 + meta + klines），读出字节
        let (sqliteFixtureURL, cleanupSqlite) = try TrainingSetSQLiteFixture.make()
        defer { cleanupSqlite() }
        let sqliteBytes = try Data(contentsOf: sqliteFixtureURL)

        // 2) 把字节打进真 zip + 算真 CRC（meta.contentHash 必须 = 此 CRC，否则真 integrity 抛 crcFailed）
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2Integ-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(
            in: workDir, sqliteFileName: "training.sqlite", sqlitePayload: sqliteBytes)

        // 3) 真 cache root + 全真组件（dataVerifier 用 fake 放行——其规则由 DefaultTrainingSetDataVerifierTests 专测）
        let cacheRoot = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(cacheRoot) }
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = DownloadAcceptanceRunner(
            api: FakeAPIClient(download: .success(zipURL), confirmError: nil),
            cache: DefaultFileSystemCacheManager(cacheRoot: cacheRoot),
            dbFactory: DefaultTrainingSetDBFactory(),
            journal: journal,
            integrity: DefaultZipIntegrityVerifier(),
            extractor: DefaultZipExtractor(),
            dataVerifier: FakeTrainingSetDataVerifier(),
            cleaner: DefaultDownloadAcceptanceCleaner())

        let meta = TrainingSetMetaItem(
            id: 42, stockCode: "600001", stockName: "测试股票",
            filename: "training.zip", schemaVersion: 1, contentHash: crcHex)

        let result = await runner.run(meta: meta, leaseId: "11111111-1111-1111-1111-111111111111")

        // confirmed + cache 真落盘一个可打开的 sqlite（schemaVersion 由真 store 的 PRAGMA 读出）
        guard case .confirmed(let file) = result else {
            Issue.record("expected .confirmed via real pipeline, got \(result)"); return
        }
        #expect(file.id == 42)
        #expect(FileManager.default.fileExists(atPath: file.localURL.path))
        #expect(file.schemaVersion == TRAINING_SET_SCHEMA_VERSION)
        #expect(try journal.listByState(.confirmed).count == 1)

        // 真 cleaner 已清掉下载 zip（位于系统临时目录子树内）
        #expect(FileManager.default.fileExists(atPath: zipURL.path) == false)
    }
}
```

- [ ] **Step 2: 跑确认通过**

Run: `cd "ios/Contracts" && swift test --filter "DownloadAcceptanceRunnerIntegrationTests" 2>&1 | tail -12`
Expected: PASS。若 FAIL 且报 `.persistence(...)` / store 相关错 → 说明 `run()` 仍误传 `zipURL` 给 store，回 Task 2 改为 `sqliteURL`。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift
git commit -m "test(P2): 真实管道集成测试（真 cache/extract/factory，抓传错文件给 store）"
```

---

## Task 8：验收清单 + 最终验证

**Files:**
- Create: `docs/acceptance/2026-06-06-wave2-p2-download-acceptance-runner.md`

- [ ] **Step 1: 写非 coder 可执行验收清单（中文，action/expected/pass-fail）**

按 `.claude/workflow-rules.json` 禁忌词约束（禁「应该」「大概」「基本」等模糊词；用可观测断言）。覆盖：
1. 全套件 `swift test` 绿（给出命令 + 期望「0 failures」行）。
2. happy path：journal 状态序列 `downloaded→crcOK→unzipped→dbVerified→stored→confirmPending→confirmed`（指向 `run_happyPath...` 测试名 + 期望 PASS）。
3. 状态机硬约束：`stored` 不能直跳 `confirmed`（指向 happy-path 的 `listByState(.confirmed).count==1` + `listByState(.stored).isEmpty` 断言——该断言查 production 落库态，是该不变量的**真守卫**；序列断言仅辅助）。
4. confirm 409/404 删本地文件 / 网络不确定保留文件（指向对应测试名）。
5. retry 扫 `stored ∪ confirmPending`（指向 `retry_scansBothStoredAndConfirmPending`）。
6. runBatch 保序（指向 `runBatch_*_orderPreserved`）。
7. 真实管道集成：真 `DefaultFileSystemCacheManager` happy-path 落盘可打开 sqlite（指向 `run_realPipeline_happyPath_storesAndConfirms`）。
8. Catalyst CI required check 真绿（给出 PR 页 check 名 `Mac Catalyst build-for-testing on macos-15` + 期望 ✅）。

- [ ] **Step 2: 最终全量验证**

Run: `cd "ios/Contracts" && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build 成功；`Test run with N tests ... 0 failures`。

- [ ] **Step 3: grep 自检 — 无遗漏 fatalError / 无 TODO**

Run: `grep -n "fatalError\|TODO\|FIXME" ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift || echo "clean"`
Expected: `clean`（runner 内无残留 `fatalError`/TODO）。

- [ ] **Step 4: Commit**

```bash
git add docs/acceptance/2026-06-06-wave2-p2-download-acceptance-runner.md
git commit -m "docs(P2): 非 coder 验收清单 + 最终验证"
```

---

## Self-Review（写完计划后对照 spec 复查）

**1. Spec coverage**（§P2 L1761-1836 + M0.1 L230-300）：
- `run` 7 步状态机 → Task 2（happy）+ Task 3（失败分支）✅
- `runBatch(concurrency:)` → Task 6 ✅
- `retryPendingConfirmations` 扫 `stored ∪ confirmPending` → Task 5 ✅
- 4 内部端口接线（integrity/extract/dataVerify/cleaner）→ Task 2 happy + Task 3 各失败 ✅
- journal 状态机 + 崩溃恢复（stored/confirmPending 不清理本地文件；409/404 才删）→ Task 4/5 ✅
- `AcceptanceResult` / `TRAINING_SET_SCHEMA_VERSION` 定义 → Task 1 ✅
- 错误边界（只消费 AppError）→ `asAppError` Task 2 ✅
- 真实文件 IO 管道（真 cache.store 入参 = 解压 sqlite）→ Task 7 集成测试 ✅

**5. R1 评审修订（opus 4.8 xhigh plan-stage）**：
- **Critical**：`run` step 6 改传 `sqliteURL`（非 `zipURL`）给 `cache.store`——生产 store 把入参当已解压 sqlite 处理（决策 6）；新增 Task 7 真实管道集成测试守卫。
- **Medium-1**：验收项 3 改指向 `listByState` 落库断言（状态机硬约束的真守卫），非弱序列断言。
- **Medium-2**：`TRAINING_SET_SCHEMA_VERSION` 标注本 PR 唯一定义点（决策 8 + 代码注释）。
- **Low-2**：`runBatch_concurrency2` 加 `listByState(.confirmed).count==5` 断言（并发写不互污）。
- **Low-1（取消路径测试）**：不纳入——`asAppError` 取消映射逻辑已自洽（决策 9），加测属非阻塞增强，避免 scope 蔓延。

**2. Placeholder scan**：所有 step 含完整代码/命令/期望；无 TBD/TODO/"类似 Task N"。✅

**3. Type consistency**：`AcceptanceResult`/`ConfirmOutcome`/`attemptConfirm`/`asAppError`/`TRAINING_SET_SCHEMA_VERSION` 全计划一致；端口/上游协议签名与已落地源文件逐字对齐（`confirmTrainingSet(id:leaseId:)`/`store(downloadedZip:meta:)`/`openAndVerify(file:expectedSchemaVersion:)`/`upsert(trainingSetId:leaseId:state:sqliteLocalPath:contentHash:lastError:)`/`listByState(_:)`）。✅

**4. 已知 spec 偏差（1 项，已记录）**：`AcceptanceResult` 加 `Equatable`（spec 仅 `Sendable`）——仅测试便利，`TrainingSetFile`/`AppError` 均 `Equatable`，无行为影响。
