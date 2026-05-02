# E6 TrainingSessionCoordinator 契约 + init 签名 + preview() Fixture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 项目记忆 `project_executing_plans_excluded` 明确：本项目只用 subagent-driven-development，不用 executing-plans。每个 batch 派一个 fresh sonnet 4.6 high-effort subagent；批与批之间主线 review。

**Goal:** 落地 spec §10 line 2110 整条 deliverable——**「E6 TrainingSessionCoordinator 契约 + init 签名 + preview() Fixture」**：
- E6 `TrainingSessionCoordinator` class（`@MainActor @Observable`）+ 6 参数 init + 7 方法签名（方法体 `fatalError("Wave 2 E6 impl")`）+ `TrainingSessionCoordinator.preview()` 静态工厂
- 6 个依赖 protocol（P3a `TrainingSetDBFactory` / P3b `TrainingSetReader` / P4 `RecordRepository` / P4 `PendingTrainingRepository` / P4 `SettingsDAO` / P5 `CacheManager`）
- P6 `SettingsStore` class 壳 + `SettingsStore.preview()` 静态工厂
- E5 `TrainingEngine` 最小类型壳（`fileprivate init { fatalError }`，本 PR 任何路径不实例化）
- 5 个 in-memory fakes（`PreviewTrainingSetDBFactory` / `InMemoryRecordRepository` / `InMemoryPendingTrainingRepository` / `InMemorySettingsDAO` / `InMemoryCacheManager`），方法体均为 `fatalError("Wave 0 fake: not exercised in preview path")` 或 trivial 默认值；`InMemorySettingsDAO.loadSettings()` 返回 zero-value `AppSettings` 让 `SettingsStore.preview()` 能 succeed

**显式不交付**（推迟到后续 PR）：
- spec §10 line 2111 `TrainingEnginePreviewFactory`（`TrainingEngine.preview(mode:)`）—— 需要 Wave 2 E5 完整 init + E4 flows（`NormalFlow` / `ReviewFlow` / `ReplayFlow`）+ M0.3 fixture 扩展（`KLineCandle.previewFixture` / `FeeSnapshot.preview` / `TrainingRecord.previewRecord`）。dep-graph 真阻塞，本 PR 无法落
- 5 个非 E6-preview-path 的 fake：`InMemoryAcceptanceJournalDAO` / `PreviewTrainingSetReader` / `FakeZipIntegrityVerifier` / `FakeZipExtractor` / `FakeTrainingSetDataVerifier` / `FakeDownloadAcceptanceCleaner` / `FakeAPIClient`（spec §11.3 列；属于 PR 5 Fixture/Mock Ports 的剩余范围）
- E5 `TrainingEngine` 的 stored properties / public init / mutator / accessors / scenePhase 中继（Wave 2 E5 实现 PR）
- TSC 7 个方法的实际业务逻辑（Wave 2 E6 实现 PR）

**Architecture:** Contract-first，单 PR 落 spec §10 line 2110 整条 bullet，避免 spec 单一 bullet 跨 PR 切片。Round 1 review 验证：TSC.preview()（spec line 1689-1700）只 construct TSC，**不** instantiate TrainingEngine、**不** 调用 E4 flows、**不** 依赖 fixture 扩展，故能与本 PR 共栖。增量约 +90 prod LOC（5 fakes 60 + TSC.preview 15 + SettingsStore.preview 5 + 内部 wiring 10），仍在 ≤500 prod LOC 预算内。

**Tech Stack:** Swift 6（toolchain 6.3.1，strict concurrency on）+ SwiftPM（`KlineTrainerContracts` package，root: `ios/Contracts/`）+ Swift Testing macros（`@Test` / `@Suite` / `#expect`）+ `@MainActor` + `@Observable`。

**Design Doc:** 无独立 design doc——本 PR 完全照 spec §10 line 1623-1667（E6）+ line 1689-1700（preview Fixture）+ line 1970-1983（P6）+ line 1827-1850（P3a/P3b）+ line 1870-1904（P4×3）+ line 1953-1959（P5）落地，无设计自由度。

---

## Pre-flight Gate (Step 0 — subagent must run before Task 1)

避免 Round 1 C1 类 spec drift：subagent 在写代码前 grep baseline 真签名，按实测对齐 plan stubs。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts/Sources/KlineTrainerContracts"
grep -n "public init" AppState.swift Models.swift RESTDTOs.swift
```

期望输出（已实测 2026-05-02 main HEAD e9c00ad）：
- `AppState.swift:159        public init(commissionRate: Double, minCommissionEnabled: Bool, totalCapital: Double, displayMode: DisplayMode) {`（**字段名 `totalCapital`，不是 `initialCapital`**；参数顺序按上面）
- `Models.swift:147          public init(commissionRate: Double, minCommissionEnabled: Bool) {`
- 其余类型本 PR 不构造，只引用类型名

若 grep 实测与上方不符，subagent 以 grep 为准修正所有 stubs，并在 PR body 标 D-#。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts"
swift test 2>&1 | tail -3
```
期望输出：`Test run with 125 tests in 26 suites passed`（已实测 main HEAD e9c00ad）。这是 baseline。

---

## File Structure

| File | Responsibility | LOC budget |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingSetDBFactory.swift` | P3a protocol（spec §P3a line 1827-1832） | ≤25 行 prod |
| `ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingSetReader.swift` | P3b protocol（spec §P3b line 1843-1850） | ≤25 行 prod |
| `ios/Contracts/Sources/KlineTrainerContracts/Persistence/RecordRepository.swift` | P4 protocol（spec §P4 line 1870-1877） | ≤25 行 prod |
| `ios/Contracts/Sources/KlineTrainerContracts/Persistence/PendingTrainingRepository.swift` | P4 protocol（spec §P4 line 1879-1883） | ≤20 行 prod |
| `ios/Contracts/Sources/KlineTrainerContracts/Persistence/SettingsDAO.swift` | P4 protocol（spec §P4 line 1885-1889） | ≤20 行 prod |
| `ios/Contracts/Sources/KlineTrainerContracts/Persistence/CacheManager.swift` | P5 protocol（spec §P5 line 1953-1959） | ≤25 行 prod |
| `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | 5 in-memory fakes（PreviewTrainingSetDBFactory / InMemoryRecordRepository / InMemoryPendingTrainingRepository / InMemorySettingsDAO / InMemoryCacheManager） | ≤90 行 prod |
| `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift` | P6 class shell + `static func preview()` | ≤55 行 prod |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | E5 minimal type shell（fileprivate init） | ≤15 行 prod |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` | E6 class + init + 7 methods + `static func preview()` | ≤105 行 prod |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift` | 5 个 `@Suite`：契约形状 / SettingsStore / TrainingEngine 类型 / InMemoryFakes / TSC | ≤230 行 |

**总 prod LOC 预算**：25×6 + 90 + 55 + 15 + 105 = **415 行**（≤500 LOC 上限，留 85 行 headroom）。

**总测试新增**：6 (Task 1) + 3 (Task 2) + 1 (Task 3) + 5 (Task 4) + 9 (Task 5) = **24 tests / 5 suites**

**最终预期**：125 + 24 = **149 tests pass / 26 + 5 = 31 suites / 0 warnings**

**Working directory**：`/Users/maziming/Coding/Prj_Kline trainer/.worktrees/e6-coordinator/ios/Contracts/`（SwiftPM root；执行时由主线创建 worktree）

**iOS gate 命令**（探针法，不依赖 SwiftPM Xcode integration）：
```bash
swiftc -typecheck \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios17.0-simulator \
  ios/Contracts/Sources/KlineTrainerContracts/Persistence/*.swift \
  ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/*.swift \
  ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift \
  ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/*.swift \
  ios/Contracts/Sources/KlineTrainerContracts/Models.swift \
  ios/Contracts/Sources/KlineTrainerContracts/AppState.swift \
  ios/Contracts/Sources/KlineTrainerContracts/AppError.swift \
  ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift \
  ios/Contracts/Sources/KlineTrainerContracts/RESTDTOs.swift \
  ios/Contracts/Sources/KlineTrainerContracts/Theme/*.swift \
  ios/Contracts/Sources/KlineTrainerContracts/Geometry/*.swift
```
exit 0 = `@MainActor` / `@Observable` / Sendable 在 iOS 17 Simulator SDK 下解析全过。

---

## Task 1: 6 dependency protocols（P3a / P3b / P4×3 / P5）

**Strategy**：1 个 batch / 一个 sonnet 4.6 high-effort subagent。6 个 protocol 都是 spec 照搬，逐文件落 + 1 个 `@Suite` 6 tests 验证 protocol 形状不拼错。

**Files**:
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingSetDBFactory.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingSetReader.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/RecordRepository.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/PendingTrainingRepository.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/SettingsDAO.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/CacheManager.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift`

- [ ] **Step 1.1: Write the failing test**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

// MARK: - 6 dep protocols 形状 conformance

@Suite("PersistenceProtocolsShape")
struct PersistenceProtocolsShapeTests {

    // P3a
    @Test("TrainingSetDBFactory: openAndVerify 签名照 spec line 1827")
    func dbFactoryShape() {
        struct Stub: TrainingSetDBFactory {
            func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
                fatalError("test stub")
            }
        }
        let _: TrainingSetDBFactory = Stub()
    }

    // P3b: protocol 是 AnyObject + Sendable，class stub 须显式 @unchecked Sendable
    // 否则 Swift 6 strict concurrency 会 warn（与 0-warnings gate 冲突）
    @Test("TrainingSetReader: AnyObject + Sendable + 3 方法照 spec line 1843")
    func readerShape() {
        final class Stub: TrainingSetReader, @unchecked Sendable {
            func loadMeta() throws -> TrainingSetMeta { fatalError() }
            func loadAllCandles() throws -> [Period: [KLineCandle]] { fatalError() }
            func close() {}
        }
        let _: any TrainingSetReader = Stub()
    }

    // P4 RecordRepository
    @Test("RecordRepository: Sendable + 4 方法照 spec line 1870")
    func recordRepoShape() {
        struct Stub: RecordRepository {
            func insertRecord(_: TrainingRecord, ops: [TradeOperation], drawings: [DrawingObject]) throws -> Int64 { fatalError() }
            func listRecords(limit: Int?) throws -> [TrainingRecord] { [] }
            func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) { fatalError() }
            func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) { (0, 0, 0) }
        }
        let _: any RecordRepository = Stub()
    }

    // P4 PendingTrainingRepository
    @Test("PendingTrainingRepository: Sendable + 3 方法照 spec line 1879")
    func pendingRepoShape() {
        struct Stub: PendingTrainingRepository {
            func savePending(_: PendingTraining) throws {}
            func loadPending() throws -> PendingTraining? { nil }
            func clearPending() throws {}
        }
        let _: any PendingTrainingRepository = Stub()
    }

    // P4 SettingsDAO —— init 签名按 baseline grep 实测对齐
    // AppState.swift baseline: AppSettings(commissionRate:minCommissionEnabled:totalCapital:displayMode:)
    @Test("SettingsDAO: Sendable + 3 方法照 spec line 1885")
    func settingsDAOShape() {
        struct Stub: SettingsDAO {
            func loadSettings() throws -> AppSettings {
                AppSettings(commissionRate: 0,
                            minCommissionEnabled: false,
                            totalCapital: 0,
                            displayMode: .system)
            }
            func saveSettings(_: AppSettings) throws {}
            func resetCapital() throws {}
        }
        let _: any SettingsDAO = Stub()
    }

    // P5 CacheManager
    @Test("CacheManager: 5 方法照 spec line 1953")
    func cacheManagerShape() {
        struct Stub: CacheManager {
            func listAvailable() -> [TrainingSetFile] { [] }
            func pickRandom() -> TrainingSetFile? { nil }
            func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile { fatalError() }
            func touch(_: TrainingSetFile) {}
            func delete(_: TrainingSetFile) throws {}
        }
        let _: any CacheManager = Stub()
    }
}
```

- [ ] **Step 1.2: Run test to verify failure**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/e6-coordinator/ios/Contracts"
swift test --filter "PersistenceProtocolsShape"
```
Expected: `error: cannot find type 'TrainingSetDBFactory' in scope` ×6.

- [ ] **Step 1.3: Create P3a `TrainingSetDBFactory.swift`**

```swift
// Kline Trainer Swift Contracts — P3a
// Spec: kline_trainer_modules_v1.4.md §P3a (line 1822-1838，protocol 体 1827-1832)

import Foundation

public protocol TrainingSetDBFactory: Sendable {
    /// 打开训练组 sqlite 文件并校验 schema_version / 基本元数据。
    /// - 失败时 throw AppError.trainingSet(.versionMismatch / .fileNotFound / .emptyData)
    /// - 每次调用产生新 reader 实例（绑定独立 DatabaseQueue）
    func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader
}
```

- [ ] **Step 1.4: Create P3b `TrainingSetReader.swift`**

```swift
// Kline Trainer Swift Contracts — P3b
// Spec: kline_trainer_modules_v1.4.md §P3b (line 1840-1856，protocol 体 1843-1850)

public protocol TrainingSetReader: AnyObject, Sendable {
    /// 从已 openAndVerify 的 sqlite 加载元数据
    func loadMeta() throws -> TrainingSetMeta
    /// 加载全部周期 candles
    func loadAllCandles() throws -> [Period: [KLineCandle]]
    /// 关闭 reader（释放 DatabaseQueue）；调用方应在 session 结束时调用
    func close()
}
```

- [ ] **Step 1.5: Create P4 `RecordRepository.swift`**

```swift
// Kline Trainer Swift Contracts — P4 RecordRepository
// Spec: kline_trainer_modules_v1.4.md §P4 (line 1863-1937，protocol 体 1870-1877)

public protocol RecordRepository: Sendable {
    func insertRecord(_: TrainingRecord,
                      ops: [TradeOperation],
                      drawings: [DrawingObject]) throws -> Int64
    func listRecords(limit: Int?) throws -> [TrainingRecord]
    func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject])
    func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double)
}
```

- [ ] **Step 1.6: Create P4 `PendingTrainingRepository.swift`**

```swift
// Kline Trainer Swift Contracts — P4 PendingTrainingRepository
// Spec: kline_trainer_modules_v1.4.md §P4 (line 1863-1937，protocol 体 1879-1883)

public protocol PendingTrainingRepository: Sendable {
    func savePending(_: PendingTraining) throws
    func loadPending() throws -> PendingTraining?
    func clearPending() throws
}
```

- [ ] **Step 1.7: Create P4 `SettingsDAO.swift`**

```swift
// Kline Trainer Swift Contracts — P4 SettingsDAO
// Spec: kline_trainer_modules_v1.4.md §P4 (line 1863-1937，protocol 体 1885-1889)

public protocol SettingsDAO: Sendable {
    func loadSettings() throws -> AppSettings
    func saveSettings(_: AppSettings) throws
    func resetCapital() throws
}
```

- [ ] **Step 1.8: Create P5 `CacheManager.swift`**

```swift
// Kline Trainer Swift Contracts — P5 CacheManager
// Spec: kline_trainer_modules_v1.4.md §P5 (line 1950-1968，protocol 体 1953-1959)

import Foundation

public protocol CacheManager: Sendable {
    func listAvailable() -> [TrainingSetFile]
    func pickRandom() -> TrainingSetFile?
    func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile
    func touch(_: TrainingSetFile)
    func delete(_: TrainingSetFile) throws
}
```

- [ ] **Step 1.9: Run tests to verify they pass**

```bash
swift test --filter "PersistenceProtocolsShape"
```
Expected: 6/6 PASS, 0 warnings.

- [ ] **Step 1.10: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift
git commit -m "feat(E6): 6 dep protocols（P3a/P3b/P4×3/P5）+ shape tests"
```

---

## Task 2: P6 SettingsStore 类壳（暂不含 preview()）

**Files**:
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`

> SettingsStore.preview() 在 Task 5 加（依赖 Task 4 的 InMemorySettingsDAO）。本 Task 只落基础类壳。

- [ ] **Step 2.1: Write the failing test**

Append to `TrainingSessionCoordinatorTests.swift`:

```swift
@MainActor
@Suite("SettingsStoreShape")
struct SettingsStoreShapeTests {

    private struct StubDAO: SettingsDAO {
        func loadSettings() throws -> AppSettings {
            AppSettings(commissionRate: 0.0001,
                        minCommissionEnabled: false,
                        totalCapital: 0,
                        displayMode: .system)
        }
        func saveSettings(_: AppSettings) throws {}
        func resetCapital() throws {}
    }

    @Test("init(settingsDAO:) 签名照 spec line 1979 编译")
    func initSignature() {
        let store = SettingsStore(settingsDAO: StubDAO())
        // settings 默认值取自 stub init 内部初始化（Wave 0 stub：zero-value AppSettings）
        // Wave 2 P6 PR 改为 init 内 try? settingsDAO.loadSettings() 实际加载
        _ = store
    }

    @Test("snapshotFees() 签名 -> FeeSnapshot")
    func snapshotFeesSignature() {
        let store = SettingsStore(settingsDAO: StubDAO())
        let _: FeeSnapshot = store.snapshotFees()
    }

    @Test("update / resetCapital 签名编译期解析（不调用 fatalError 体）")
    func mutatorSignatures() {
        let store = SettingsStore(settingsDAO: StubDAO())
        let _: ((inout AppSettings) -> Void) async throws -> Void = store.update
        let _: () async throws -> Void = store.resetCapital
    }
}
```

- [ ] **Step 2.2: Run test to verify failure**

```bash
swift test --filter "SettingsStoreShape"
```
Expected: `cannot find 'SettingsStore' in scope`.

- [ ] **Step 2.3: Create `Settings/SettingsStore.swift`**

```swift
// Kline Trainer Swift Contracts — P6 SettingsStore (Wave 0 类壳)
// Spec: kline_trainer_modules_v1.4.md §P6 (line 1970-1983)
// Wave 0 范围：init(settingsDAO:) 签名 + 4 方法签名 + zero-value 默认 settings
// Wave 2 P6 PR 改为 init 内调用 settingsDAO.loadSettings() 实际加载
// preview() 静态工厂在 Task 5 添加（依赖 Task 4 的 InMemorySettingsDAO）

#if canImport(Observation)
import Observation
#endif

@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: AppSettings

    private let settingsDAO: SettingsDAO

    public init(settingsDAO: SettingsDAO) {
        self.settingsDAO = settingsDAO
        // Wave 0 stub: 默认 zero-value AppSettings（commissionRate=0 是有效的小数率，spec line 1976 只约束单位）
        // 字段顺序按 baseline grep（AppState.swift:160）：commissionRate / minCommissionEnabled / totalCapital / displayMode
        self.settings = AppSettings(commissionRate: 0,
                                    minCommissionEnabled: false,
                                    totalCapital: 0,
                                    displayMode: .system)
    }

    public func update(_ mutate: (inout AppSettings) -> Void) async throws {
        fatalError("Wave 2 P6 impl")
    }

    public func resetCapital() async throws {
        fatalError("Wave 2 P6 impl")
    }

    public func snapshotFees() -> FeeSnapshot {
        FeeSnapshot(commissionRate: settings.commissionRate,
                    minCommissionEnabled: settings.minCommissionEnabled)
    }
}
```

- [ ] **Step 2.4: Run tests to verify pass**

```bash
swift test --filter "SettingsStoreShape"
```
Expected: 3/3 PASS, 0 warnings.

- [ ] **Step 2.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Settings/
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift
git commit -m "feat(P6): SettingsStore 类壳（init + 4 方法签名）"
```

---

## Task 3: E5 TrainingEngine 最小类型壳

**Scope**：本 PR 只引入 `TrainingEngine` **类型壳**——`@MainActor @Observable final class TrainingEngine` + `fileprivate init { fatalError }`，不可外部实例化。E6 TSC 7 个方法返回 `TrainingEngine`，但所有方法体都是 `fatalError`，永不真返回 instance。

**Files**:
- Create: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`

- [ ] **Step 3.1: Write the failing test**

Append to `TrainingSessionCoordinatorTests.swift`:

```swift
@MainActor
@Suite("TrainingEngineShell")
struct TrainingEngineShellTests {

    @Test("TrainingEngine 类型存在且 @MainActor 可解析")
    func typeExists() {
        // 本 stub 不可外部实例化（fileprivate init 触发 fatalError）；
        // 只验类型存在，能作为 TSC 方法返回值类型
        let _: TrainingEngine.Type = TrainingEngine.self
    }
}
```

- [ ] **Step 3.2: Run test to verify failure**

```bash
swift test --filter "TrainingEngineShell"
```
Expected: `cannot find 'TrainingEngine' in scope`.

- [ ] **Step 3.3: Create `TrainingEngine/TrainingEngine.swift`**

```swift
// Kline Trainer Swift Contracts — E5 TrainingEngine (Wave 0 类型壳)
// Spec: kline_trainer_modules_v1.4.md §E5 (line 1563-1621)
// Wave 0 范围：仅类型存在，使 E6 TSC 方法签名可返回 TrainingEngine
// stored properties / public init / mutators / scenePhase 中继 / accessors：Wave 2 E5 实现 PR
// 故意 fileprivate init 防外部构造 + fatalError 防误调用

#if canImport(Observation)
import Observation
#endif

@MainActor
@Observable
public final class TrainingEngine {
    fileprivate init() {
        fatalError("Wave 0 stub: TrainingEngine 不可实例化；Wave 2 E5 PR 提供完整 init")
    }
}
```

- [ ] **Step 3.4: Run tests to verify pass**

```bash
swift test --filter "TrainingEngineShell"
```
Expected: 1/1 PASS, 0 warnings.

- [ ] **Step 3.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift
git commit -m "feat(E5): TrainingEngine 类型壳（fileprivate init，不可实例化）"
```

---

## Task 4: 5 in-memory fakes for E6.preview() path

**Scope**：spec §11.3 列了 11 个 fake；本 PR 只落 E6.preview() 调用路径上的 5 个：
- `PreviewTrainingSetDBFactory`（P3a fake）
- `InMemoryRecordRepository`（P4 fake）
- `InMemoryPendingTrainingRepository`（P4 fake）
- `InMemorySettingsDAO`（P4 fake；`loadSettings()` 返回 zero-value AppSettings 让 SettingsStore.preview 能成功）
- `InMemoryCacheManager`（P5 fake）

非 preview-path 的 6 个 fake（`InMemoryAcceptanceJournalDAO` / `PreviewTrainingSetReader` / `FakeZipIntegrityVerifier` / `FakeZipExtractor` / `FakeTrainingSetDataVerifier` / `FakeDownloadAcceptanceCleaner` / `FakeAPIClient`）属于 PR 5 Fixture/Mock Ports 范围，本 PR 不交付。

**全部 fake 方法体 = `fatalError("Wave 0 fake: not exercised in preview path")`**，唯一例外：
- `InMemorySettingsDAO.loadSettings()` 返回 zero-value AppSettings（因为 SettingsStore.preview() 必须能成功 init）
- `InMemorySettingsDAO.saveSettings/resetCapital` = no-op（preview path 不调用，但 0-warnings gate 要求方法体非空时不能 unused-warning，no-op 即可）

设计原则：fake 不是为了 PR 5 复用，而是为了让 spec line 1689-1700 的 TSC.preview() 编译期 + 运行期能 succeed。PR 5 完整实现 fake 时若需要更丰富语义，按需替换。

**Files**:
- Create: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`

- [ ] **Step 4.1: Write the failing test**

Append to `TrainingSessionCoordinatorTests.swift`:

```swift
@Suite("InMemoryFakes")
struct InMemoryFakesTests {

    @Test("PreviewTrainingSetDBFactory 实例化")
    func dbFactoryInstantiates() {
        let _: any TrainingSetDBFactory = PreviewTrainingSetDBFactory()
    }

    @Test("InMemoryRecordRepository.listRecords 返回空 / statistics 返回零")
    func recordRepoDefaults() throws {
        let repo = InMemoryRecordRepository()
        #expect(try repo.listRecords(limit: nil).isEmpty)
        let stats = try repo.statistics()
        #expect(stats.totalCount == 0)
        #expect(stats.winCount == 0)
        #expect(stats.currentCapital == 0)
    }

    @Test("InMemoryPendingTrainingRepository.loadPending 返回 nil")
    func pendingRepoDefault() throws {
        let repo = InMemoryPendingTrainingRepository()
        #expect(try repo.loadPending() == nil)
    }

    @Test("InMemorySettingsDAO.loadSettings 返回 zero-value AppSettings")
    func settingsDAODefault() throws {
        let dao = InMemorySettingsDAO()
        let s = try dao.loadSettings()
        #expect(s.commissionRate == 0)
        #expect(s.totalCapital == 0)
        #expect(s.displayMode == .system)
    }

    @Test("InMemoryCacheManager.listAvailable 返回空 / pickRandom 返回 nil")
    func cacheManagerDefaults() {
        let cache = InMemoryCacheManager()
        #expect(cache.listAvailable().isEmpty)
        #expect(cache.pickRandom() == nil)
    }
}
```

- [ ] **Step 4.2: Run test to verify failure**

```bash
swift test --filter "InMemoryFakes"
```
Expected: `cannot find 'PreviewTrainingSetDBFactory' in scope`（5 个未声明）.

- [ ] **Step 4.3: Create `PreviewFakes/InMemoryFakes.swift`**

```swift
// Kline Trainer Swift Contracts — Wave 0 In-Memory Fakes for E6.preview() path
// Spec: kline_trainer_modules_v1.4.md §11.3 Test Fixture Ports list (line 2195-2206)
// 本 PR 只落 5 个 E6.preview() 调用路径上的 fake；其余 6 个属 PR 5 Fixture/Mock Ports
// `#if DEBUG` 包裹与 spec line 1671-1713 preview Fixture 一致：fakes 不进 Release binary

#if DEBUG

import Foundation

// MARK: - P3a fake

public struct PreviewTrainingSetDBFactory: TrainingSetDBFactory {
    public init() {}
    public func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
        fatalError("Wave 0 fake: not exercised in preview path")
    }
}

// MARK: - P4 fakes

public final class InMemoryRecordRepository: RecordRepository, @unchecked Sendable {
    public init() {}
    public func insertRecord(_: TrainingRecord, ops: [TradeOperation], drawings: [DrawingObject]) throws -> Int64 {
        fatalError("Wave 0 fake: not exercised in preview path")
    }
    public func listRecords(limit: Int?) throws -> [TrainingRecord] { [] }
    public func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) {
        fatalError("Wave 0 fake: not exercised in preview path")
    }
    public func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) { (0, 0, 0) }
}

public final class InMemoryPendingTrainingRepository: PendingTrainingRepository, @unchecked Sendable {
    public init() {}
    public func savePending(_: PendingTraining) throws {}
    public func loadPending() throws -> PendingTraining? { nil }
    public func clearPending() throws {}
}

public final class InMemorySettingsDAO: SettingsDAO, @unchecked Sendable {
    public init() {}
    public func loadSettings() throws -> AppSettings {
        // zero-value 让 SettingsStore.preview() 能 succeed
        AppSettings(commissionRate: 0,
                    minCommissionEnabled: false,
                    totalCapital: 0,
                    displayMode: .system)
    }
    public func saveSettings(_: AppSettings) throws {}
    public func resetCapital() throws {}
}

// MARK: - P5 fake

public final class InMemoryCacheManager: CacheManager, @unchecked Sendable {
    public init() {}
    public func listAvailable() -> [TrainingSetFile] { [] }
    public func pickRandom() -> TrainingSetFile? { nil }
    public func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile {
        fatalError("Wave 0 fake: not exercised in preview path")
    }
    public func touch(_: TrainingSetFile) {}
    public func delete(_: TrainingSetFile) throws {}
}

#endif
```

> **Sendable 笔记**：3 个 P4 fakes + InMemoryCacheManager 用 `final class @unchecked Sendable` —— class 默认非 Sendable，protocol 要求 Sendable，empty class 实际线程安全（无 mutable state），用 `@unchecked` 显式声明。`PreviewTrainingSetDBFactory` 是 struct，自动 Sendable 不需 `@unchecked`。

> **`#if DEBUG` 笔记**：整文件 `#if DEBUG` 包裹与 spec line 1671 preview Fixture 一致；保证 fakes 不会 link 进 Release iOS binary（PR 5 时若需要在 Release 调用 fakes 再调整条件编译）。Step 4.1 测试 + Step 5 TSC.preview() 都在 DEBUG / test target 内，fakes 符号可见。

- [ ] **Step 4.4: Run tests to verify pass**

```bash
swift test --filter "InMemoryFakes"
```
Expected: 5/5 PASS, 0 warnings.

- [ ] **Step 4.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift
git commit -m "feat(fakes): 5 in-memory fakes for E6.preview() path（Wave 0 部分交付，spec §11.3）"
```

---

## Task 5: E6 TrainingSessionCoordinator 类 + init + 7 方法签名 + preview() + SettingsStore.preview() 扩展

**Files**:
- Create: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`（在末尾追加 `static func preview()` 扩展，依赖 Task 4 InMemorySettingsDAO）

- [ ] **Step 5.1: Write the failing test**

Append to `TrainingSessionCoordinatorTests.swift`:

```swift
@MainActor
@Suite("TrainingSessionCoordinatorShape")
struct TrainingSessionCoordinatorShapeTests {

    // 复用 Task 4 in-memory fakes 构造 TSC
    private func makeCoordinator() -> TrainingSessionCoordinator {
        TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(),
            recordRepo: InMemoryRecordRepository(),
            pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(),
            cache: InMemoryCacheManager(),
            settings: SettingsStore(settingsDAO: InMemorySettingsDAO())
        )
    }

    @Test("init 6 参数签名照 spec line 1639-1644 编译 + 初始 active state 为 nil")
    func initSignature() {
        let coord = makeCoordinator()
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    // 7 个方法签名编译期解析（不调用 fatalError 体）
    @Test("startNewNormalSession() async throws -> TrainingEngine 签名")
    func startNewSignature() {
        let coord = makeCoordinator()
        let _: () async throws -> TrainingEngine = coord.startNewNormalSession
    }

    @Test("resumePending() async throws -> TrainingEngine? 签名")
    func resumeSignature() {
        let coord = makeCoordinator()
        let _: () async throws -> TrainingEngine? = coord.resumePending
    }

    @Test("review(recordId:) async throws -> TrainingEngine 签名")
    func reviewSignature() {
        let coord = makeCoordinator()
        let _: (Int64) async throws -> TrainingEngine = coord.review
    }

    @Test("replay(recordId:) async throws -> TrainingEngine 签名")
    func replaySignature() {
        let coord = makeCoordinator()
        let _: (Int64) async throws -> TrainingEngine = coord.replay
    }

    @Test("saveProgress(engine:) async throws 签名")
    func saveProgressSignature() {
        let coord = makeCoordinator()
        let _: (TrainingEngine) async throws -> Void = coord.saveProgress
    }

    @Test("finalize(engine:) async throws -> Int64? 签名")
    func finalizeSignature() {
        let coord = makeCoordinator()
        let _: (TrainingEngine) async throws -> Int64? = coord.finalize
    }

    @Test("endSession() async 签名（spec line 1666 不 throws）")
    func endSessionSignature() {
        let coord = makeCoordinator()
        let _: () async -> Void = coord.endSession
    }

    // spec line 1689-1700 TSC.preview() smoke
    @Test("TrainingSessionCoordinator.preview() 构造成功 + 初始 active state 为 nil")
    func previewSmoke() {
        let coord = TrainingSessionCoordinator.preview()
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }
}
```

> **测试覆盖说明**：上方 9 个 test 覆盖：init 1 + 7 方法签名 + 1 preview。spec line 1666 `endSession()` 不 throws，单独标注以防 subagent 误加 throws。Round 1 review 提到的 `initialActives` 与 `initSignature` 重复 —— 已合并为单一 `initSignature` 同时验证 init 与 active state。

- [ ] **Step 5.2: Run test to verify failure**

```bash
swift test --filter "TrainingSessionCoordinatorShape"
```
Expected: `cannot find 'TrainingSessionCoordinator' in scope`.

- [ ] **Step 5.3: Create `TrainingEngine/TrainingSessionCoordinator.swift`**

```swift
// Kline Trainer Swift Contracts — E6 TrainingSessionCoordinator (Wave 0 契约 + preview)
// Spec: kline_trainer_modules_v1.4.md §E6 (line 1623-1700)
// Wave 0 范围：class + init + 7 方法签名（fatalError 体）+ static func preview()
// TrainingEnginePreviewFactory（TrainingEngine.preview(mode:)）：spec line 2111，
//   依赖 Wave 2 E5 完整 init + E4 flows，dep-graph 阻塞，本 PR 不交付

#if canImport(Observation)
import Observation
#endif

@MainActor
@Observable
public final class TrainingSessionCoordinator {
    private let dbFactory: TrainingSetDBFactory       // P3a
    private let recordRepo: RecordRepository          // P4
    private let pendingRepo: PendingTrainingRepository // P4
    private let settingsDAO: SettingsDAO              // P4
    private let cache: CacheManager                   // P5
    private let settings: SettingsStore               // P6

    public private(set) var activeEngine: TrainingEngine?
    public private(set) var activeReader: (any TrainingSetReader)?

    public init(dbFactory: TrainingSetDBFactory,
                recordRepo: RecordRepository,
                pendingRepo: PendingTrainingRepository,
                settingsDAO: SettingsDAO,
                cache: CacheManager,
                settings: SettingsStore) {
        self.dbFactory = dbFactory
        self.recordRepo = recordRepo
        self.pendingRepo = pendingRepo
        self.settingsDAO = settingsDAO
        self.cache = cache
        self.settings = settings
        self.activeEngine = nil
        self.activeReader = nil
    }

    /// 开始新 Normal 训练（spec line 1647）
    public func startNewNormalSession() async throws -> TrainingEngine {
        fatalError("Wave 2 E6 impl")
    }

    /// 继续中断训练（spec line 1650）
    public func resumePending() async throws -> TrainingEngine? {
        fatalError("Wave 2 E6 impl")
    }

    /// Review 模式（spec line 1653）
    public func review(recordId: Int64) async throws -> TrainingEngine {
        fatalError("Wave 2 E6 impl")
    }

    /// Replay 模式（spec line 1656）
    public func replay(recordId: Int64) async throws -> TrainingEngine {
        fatalError("Wave 2 E6 impl")
    }

    /// 保存进度（spec line 1659）
    public func saveProgress(engine: TrainingEngine) async throws {
        fatalError("Wave 2 E6 impl")
    }

    /// 正式结束（spec line 1663）
    public func finalize(engine: TrainingEngine) async throws -> Int64? {
        fatalError("Wave 2 E6 impl")
    }

    /// session 结束清理（spec line 1666，不 throws）
    public func endSession() async {
        fatalError("Wave 2 E6 impl")
    }
}

// MARK: - Preview Fixture (spec line 1689-1700)

#if DEBUG
@MainActor
extension TrainingSessionCoordinator {
    public static func preview() -> TrainingSessionCoordinator {
        TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(),
            recordRepo: InMemoryRecordRepository(),
            pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(),
            cache: InMemoryCacheManager(),
            settings: SettingsStore.preview()
        )
    }
}
#endif
```

- [ ] **Step 5.4: Modify `Settings/SettingsStore.swift` to add `preview()` extension**

在文件末尾追加：

```swift

// MARK: - Preview Fixture (spec line 1689-1700 配套；依赖 InMemorySettingsDAO from PreviewFakes)

#if DEBUG
@MainActor
extension SettingsStore {
    public static func preview() -> SettingsStore {
        SettingsStore(settingsDAO: InMemorySettingsDAO())
    }
}
#endif
```

> **`#if DEBUG` 注**：spec line 1671 用 `#if DEBUG`，本 plan 沿用。`extension TrainingSessionCoordinator` 与 `extension SettingsStore` 都包在 `#if DEBUG` 内。Test target 默认包含 DEBUG，所以测试可以调用 `.preview()`。Production iOS build（Release）不包含 fakes 链接路径，避免 fatalError fakes 进入 release binary。

- [ ] **Step 5.5: Run tests to verify pass**

```bash
swift test --filter "TrainingSessionCoordinatorShape"
```
Expected: 9/9 PASS, 0 warnings.

- [ ] **Step 5.6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift
git add ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift
git commit -m "feat(E6): TrainingSessionCoordinator 契约 + 7 方法签名 + preview() Fixture"
```

---

## Task 6: 整体 verification + iOS gate + PR push

- [ ] **Step 6.1: 全量 swift test**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/e6-coordinator/ios/Contracts"
swift test 2>&1 | tail -10
```
Expected: 125 baseline + 24 new = **149 tests pass / 31 suites / 0 warnings**

> 计数细节：
> - Task 1 添加 6 tests（PersistenceProtocolsShape suite）
> - Task 2 添加 3 tests（SettingsStoreShape suite）
> - Task 3 添加 1 test（TrainingEngineShell suite）
> - Task 4 添加 5 tests（InMemoryFakes suite）
> - Task 5 添加 9 tests（TrainingSessionCoordinatorShape suite）
> = 24 tests / 5 new suites
> 125 + 24 = 149 / 26 + 5 = 31

- [ ] **Step 6.2: iOS Simulator SDK typecheck gate**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/e6-coordinator"
swiftc -typecheck \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios17.0-simulator \
  ios/Contracts/Sources/KlineTrainerContracts/Persistence/*.swift \
  ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/*.swift \
  ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift \
  ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/*.swift \
  ios/Contracts/Sources/KlineTrainerContracts/Models.swift \
  ios/Contracts/Sources/KlineTrainerContracts/AppState.swift \
  ios/Contracts/Sources/KlineTrainerContracts/AppError.swift \
  ios/Contracts/Sources/KlineTrainerContracts/TickEngine.swift \
  ios/Contracts/Sources/KlineTrainerContracts/RESTDTOs.swift \
  ios/Contracts/Sources/KlineTrainerContracts/Theme/*.swift \
  ios/Contracts/Sources/KlineTrainerContracts/Geometry/*.swift
```
Expected: exit 0（`@MainActor` / `@Observable` / Sendable 在 iOS 17 SDK 下解析全过）.

> 若 typecheck fail（例如某 protocol 没标 Sendable / 某类没标 @MainActor），subagent 修正后重跑。

- [ ] **Step 6.3: macOS 0 warnings 复核（Sendable / unused / strict concurrency）**

```bash
swift build 2>&1 | grep -i "warning" | head -10
swift test 2>&1 | grep -i "warning" | head -10
```
Expected: 空输出（无 warnings）.

- [ ] **Step 6.4: 主线调用 superpowers:verification-before-completion**

主线（不是 subagent）跑：
- `swift test` 完整输出贴对话
- iOS gate exit code
- `git diff main --stat` 列文件 + LOC
- 列「未交付」清单（spec line 2111 TrainingEnginePreviewFactory / 6 个非 preview-path fakes / Wave 2 完整 impl）

- [ ] **Step 6.5: 主线 push branch + open PR**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/e6-coordinator"
git push -u origin e6-coordinator
gh pr create --title "feat(E6): TrainingSessionCoordinator 契约 + preview() Fixture（Wave 0 anchor #4）" --body "..."
```

PR body（中文，per `feedback_pr_language_chinese`）必须列：
- 本 PR 落地内容（5 个 sub-items + spec line 2110 整条 deliverable 完成）
- **Scope 决策**：5 commits 一次性落 spec line 2110 单一 bullet「契约 + init 签名 + preview() Fixture」；实测 prod LOC 282 远低于 ≤500 切片硬规则；Round 2 spot-check ACCEPT。**评估为单一 spec deliverable，不再切片**
- 与 spec §10 line 2111 `TrainingEnginePreviewFactory` 的 deliverable 对照（dep-graph 阻塞推迟原因）
- 与 spec §11.3 11 个 fake 的部分交付对照（5 个落，6 个推到 PR 5）
- 测试计数 baseline 125 → 新 149，suite 26 → 31
- iOS gate exit code
- 已知 residuals

---

## Self-Review

**1. Spec coverage：**
- spec §10 line 2110「E6 TrainingSessionCoordinator 契约 + init 签名 + preview() Fixture」✅（Tasks 1-5 全交付）
- spec §10 line 2111「TrainingEnginePreviewFactory」❌ 推迟（dep-graph 阻塞，Goal 段已说明）
- E6 § class + init + 7 方法签名 + 2 active state ✅（Task 5）
- E6 § preview() 静态工厂 ✅（Task 5；depends Task 4）
- P3a § openAndVerify 签名 ✅（Task 1）
- P3b § AnyObject + Sendable + 3 方法 ✅（Task 1）
- P4 § 3 protocol（Record / Pending / SettingsDAO）✅（Task 1）
- P5 § 5 方法 ✅（Task 1）
- P6 § class + init + 4 方法签名 + preview() 静态工厂 ✅（Tasks 2 + 5）
- E5 § class type shell ✅（Task 3）
- spec §11.3 5 个 in-memory fakes（preview-path 那 5 个）✅（Task 4）
- spec §11.3 6 个非 preview-path fakes ❌ 推迟到 PR 5
- spec §三 §M0.5 `@MainActor` 清单（line 2187：E5/E6/P6/F2/C6 DrawingToolManager）✅（Tasks 2/3/5 全部 `@MainActor`）

**2. Placeholder scan：**
- 无 TBD / TODO / "implement later"。所有 fatalError 体均显式标注「Wave 2 P6 / E5 / E6 impl」 或「Wave 0 fake: not exercised in preview path」，是 contract-only 设计的核心机制不是 placeholder。
- Pre-flight Step 0 已 codify subagent 必须 grep baseline 后再写代码（防 Round 1 C1 类 spec drift）。

**3. Type consistency：**
- `TrainingSetReader` Task 1 declared `protocol AnyObject, Sendable`，Task 5 用 `(any TrainingSetReader)?` ✅
- `TrainingEngine` Task 3 declared，Task 5 引用作返回值类型（fatalError 不真返回，所以不触发 fileprivate init）✅
- `SettingsStore` Task 2 declared 类，Task 5 用作 `init.settings` 参数 + 在 Task 5.4 加 preview() 扩展 ✅
- `InMemorySettingsDAO` Task 4 declared，Task 5.4 SettingsStore.preview() 引用 ✅
- 6 个 protocol 名字 / 方法签名在 Task 1 declared，在 Task 4 fakes / Task 5 stubs / Task 5 TSC init 中复用 ✅
- `AppSettings(commissionRate:minCommissionEnabled:totalCapital:displayMode:)` 签名 baseline grep 实测对齐 plan stubs（AppState.swift:160）✅
- `FeeSnapshot(commissionRate:minCommissionEnabled:)` 签名 baseline grep 实测对齐 plan（Models.swift:148）✅

**4. Round 1 review fixes 校核：**
- C1 AppSettings init 签名 → 全部 4 处已改为 baseline `(commissionRate:minCommissionEnabled:totalCapital:displayMode:)` ✅
- C2 baseline 测试数 → 已改为实测 125/26 → 149/31 ✅
- C3 `final class Stub: TrainingSetReader` → 已加 `, @unchecked Sendable` ✅
- M1 scope → 选 (a) 把 TSC.preview() + 5 fakes + SettingsStore.preview() 加进本 PR ✅
- M2 spec citation → 改为「(line A-B，protocol 体 C-D)」双指针 ✅
- M3 redundant initialActives → 已合并为单一 `initSignature` ✅
- m1 TrainingEngine LOC budget → 改为 ≤15 行 ✅
- m2 Self-Review 漏 baseline grep → 已加 Pre-flight Step 0 + 此处 §3 显式校核 ✅
- m3 -package-name 旗标 → 已删 ✅
- m4 prod LOC delta → 已显式列总 415 行 / ≤500 上限 ✅
- m5 stub structs `private struct` → 已显式注「Sendable 自动 derive，不要切换 class」（Step 4.3 Sendable 笔记段）✅

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-02-e6-coordinator-contract.md`.

**用户已指定 review 流：plan → opus 4.7 xhigh 对抗性 review 收敛 → subagent 执行 → verification → requesting-code-review → opus 4.7 xhigh 对抗性 review 收敛**

下一步：plan v2 提交给 opus 4.7 xhigh 对抗性 reviewer 做 spot-check（reviewer Round 1 verdict 已说明若 mechanical 修订 + M1 选 (a) 则 spot-check 即可，无需完整 Round 2）。spot-check 通过即进 superpowers:subagent-driven-development。
