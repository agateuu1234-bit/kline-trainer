# PR 4b — P5 CacheManager + P6 SettingsStore 生产实现 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 Wave 0 顺位 8 的两个持久化生产模块——P5 `FileSystemCacheManager`（spec §P5 line 1950-1968；本地训练组缓存：临时文件 + atomic rename + LRU evict ≤20）+ P6 `SettingsStore` 生产实现（spec §P6 line 1970-1983；把 PR #40 的 `fatalError` 类壳替换为真实经 `SettingsDAO` 持久化的 `@Observable @MainActor` 实现）。两个模块均**不改协议签名**（PR #40 已冻结），只新增 `Default*` 类与 `SettingsStore` 内部成员实做。

**Architecture:**
- P5：`KlineTrainerPersistence/DefaultFileSystemCacheManager.swift`——内部用 serial `DispatchQueue` 串行 `store/touch/delete`；元数据**完全 filesystem-derived**（mtime / ctime / 文件名前缀），不引入 sidecar JSON 也不加 SQLite 表（§Design Decision §1 详述根因）
- P6：改 `KlineTrainerContracts/Settings/SettingsStore.swift` 内部 init/update/resetCapital 实现，签名不动；`SettingsDAO` 错误**eager-load with fallback**（init 不能 throws，捕获 → zero-value default + os_log warning，§Design Decision §6 详述）
- 内部错误翻译 `Internal/CacheErrorMapping.swift` 复用 `PersistenceErrorMapping` 模式（PR #40 / PR4a 既有约定）
- 测试：`KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift` + `KlineTrainerContractsTests/SettingsStoreProductionTests.swift`，整合到现有 `swift test` suite

**Tech Stack:** Swift 6.0 / SwiftPM / Foundation / GRDB 6.29（仅 P6 间接通过 `SettingsDAO`）/ os.log

---

## File Structure

| 文件 | 责任 | 状态 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerPersistence/DefaultFileSystemCacheManager.swift` | P5 生产实现：cache 目录管理 + serial queue + atomic rename + LRU evict | Create |
| `ios/Contracts/Sources/KlineTrainerPersistence/Internal/CacheErrorMapping.swift` | FileManager / NSError → AppError 边界翻译（diskFull / fileNotFound / ioError）| Create |
| `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift` | 替换 `fatalError` 类壳：init eager-load + update + resetCapital 实做（签名不变）| Modify |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift` | P5 单元测试：store happy / 失败 / listAvailable / pickRandom / touch / delete / evict / 并发 | Create |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/CacheFixture.swift` | test helper：在 `.temporaryDirectory` 下建 cache root + 写 N 个 fake .sqlite + clean teardown | Create |
| `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift` | P6 单元测试：eager-load happy / dao throws fallback / update persists / resetCapital persists / snapshotFees | Create |
| `ios/Contracts/Tests/KlineTrainerContractsTests/StubSettingsDAO.swift` | test helper：可控 `loadSettings` 返回值 + `throws` 注入 + `saveSettings` capture | Create |
| `docs/acceptance/2026-05-04-pr4b-cache-settings.md` | 验收清单（中文，非 coder 可执行）| Create |

**预估 prod LOC（硬规则 ≤500）**：
- `DefaultFileSystemCacheManager.swift`：≈ 200 LOC（含 doc comments）
- `Internal/CacheErrorMapping.swift`：≈ 35 LOC
- `Settings/SettingsStore.swift` 改动：净增 ≈ 50 LOC（init/update/resetCapital 实做替换原 `fatalError` 占位）
- 合计：**≈ 285 prod LOC** ✓ 在 500 内

**预估 test LOC**：≈ 450（无硬规则）

---

## Design Decisions（plan-time 锁定，codex review 抓变动）

### §1 P5 元数据存储策略 = filesystem-derived（拒 sidecar / 拒新 SQLite 表）

**Spec 字面证据（不充分定）：**
- spec L1950-1968 只给协议体 + 一行 hint：「`store()` = 临时文件 → rename 原子 → 更新 lastAccessedAt → 自动 evict 到 ≤ 20」「串行队列处理」
- spec L232 关于 P2 journal 的设计决策："journal 属 P2 业务语义，**落 app.sqlite 由 P4 提供 DAO**（而非独立文件——避免 cache 文件与 app 状态双写一致性问题）"——文字明确说"避免 cache 文件 vs app 状态**双写**"，**没说**禁止 cache manager 自己持久化元数据；这个决策只锁定 journal 不要独立文件，并未强制 cache manager 用 SQLite

**3 选项评估：**

| 方案 | 优点 | 缺点 | 选/拒 |
|---|---|---|---|
| **A. filesystem-derived**（mtime/ctime + 文件名前缀） | 无新状态；`store/touch` 各 1 系统调用即原子；无双写一致性问题；零 schema 演进负担 | 依赖 APFS preserve mtime（iOS 17 sandbox 下确认 OK）；`touch()` 改 mtime 需 setAttributes | ✅ 选 |
| B. sidecar JSON per file | 自描述；可加 future 字段 | 每条 cache 2 文件 → 40 文件；写 `<id>__<filename>.sqlite` + `<id>__<filename>.sqlite.meta.json` 不原子（中间崩溃孤儿）| ❌ 拒（双写 + 孤儿） |
| C. 加 app.sqlite `training_set_files` 表 | LRU = SQL ORDER BY；txn 原子 | 需新 migration `0002`；引入 P4 ↔ P5 跨模块耦合；spec L232 精神反对 cache vs app 双写状态；scope 远超 0.5d | ❌ 拒（scope creep） |

**A 方案细节：**
- **cache root**：`FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first! + "/KlineTrainerCache"`（Apple 官方建议；不暴露给 Files.app；自动备份策略可后续 `URL.setResourceValues(.excludedFromBackup)` 关——本 PR 不做，留 backlog）
- **文件命名**：`<id>__<filename>` 双下划线分隔 id 和原 filename；`id` 反解 = 取 `<basename>.split("__", maxSplits: 1).first`
- **`schemaVersion`**：通过临时打开 sqlite `PRAGMA user_version` 读取（每次 `listAvailable` 不重读，只在 `store` 时读一次缓存进文件名？——拒，理由：filename 已经够长。改：listAvailable 时**惰性**读 `PRAGMA user_version`，每条 cache 多一次 I/O；20 条 ≤ 20 次 PRAGMA 查询，可接受）
- **`lastAccessedAt`**：`FileAttributeKey.modificationDate` → `Date.timeIntervalSince1970` → `Int64`；`touch()` = `setAttributes([.modificationDate: Date()])`
- **`downloadedAt`**：`FileAttributeKey.creationDate` → 同样转 Int64

**反驳"PRAGMA user_version 20 次查询慢"**：spec maxCachedSets=20 是 cap；GRDB 打开 sqlite + 单 PRAGMA + 关闭 ≈ 1ms / file，20 个 ≈ 20ms，listAvailable 不在 hot path（只在 home view 启动时调用）。可接受。

### §2 P5 store() 参数语义 = 接收已解压的 .sqlite URL（spec drift 接受）

**Spec literal**：`func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile`（L1956）

**Reality**：v1.4 acceptance flow（L1804-1812）已经把"解压"职责拆给 P2 内部端口 `ZipExtracting.extract(zipURL:) -> URL`（步骤 3，PR #43 已落），步骤 4 `dbFactory.openAndVerify` + 步骤 5 `dataVerifier.verifyNonEmpty` 都对**已解压的 sqlite URL** 操作；步骤 6 `cache.store(...)` 若再次解压会丢失"verified sqlite"语义（拿到不同 bytes）。

**结论**：`downloadedZip:` 参数名是 v1.3 拆 P2 端口前的 spec drift，本 PR 接受这个事实——**实现上把入参当作"已解压 + 已 verify 的 sqlite URL"**，doc comment 明示"参数名为历史遗留，实际语义 = extracted sqlite URL"。

**为什么不在 PR4b 改协议名**：
- 协议在 `KlineTrainerContracts` 是 trust boundary
- 改名会破坏 `InMemoryCacheManager` fake（PR #40 已 merge）+ 任何 future caller 的 call site
- 重命名属"contract change PR"，不应混进生产实现 PR
- 留 backlog 单独 PR（或 v1.5 spec 修订时一起改）

### §3 P5 atomic rename + serial queue

**spec L687："文件系统：P5 `store()` 采用临时文件 + rename 原子化。"**
**spec L692："❌ 并发多次 `CacheManager.store()` 写同一目标路径"**

**实现：**
- 入参 `downloadedZip: URL`（实为 .sqlite URL）来自 caller 的 `temporaryDirectory`（P2 ZipExtractor 输出）
- target path = `<cacheRoot>/<id>__<meta.filename>`
- 串行 `DispatchQueue(label: "kline.cache.serial")`，store/touch/delete 全部 `queue.sync { ... }` —— 保证同一 target path 不可能并发写
- store 内部步骤：
  1. `queue.sync` 进入串行段
  2. 创建 cache root（若不存在）
  3. 检查 target 是否已存在 → 存在则先 `removeItem`（覆盖语义；同 id 重新下载即覆盖）
  4. `FileManager.moveItem(at: srcSqliteURL, to: targetURL)`——`moveItem` 在 same volume 内是 atomic rename；跨 volume fallback copy+delete（caller 给 `/tmp`，target 给 `Application Support`，这两个**很可能**在同一 volume / 都在 Data partition；若不是，`moveItem` 仍能跑，只是非原子）
  5. 读 `PRAGMA user_version` 拿 schemaVersion
  6. 用 mtime/ctime 构造 `TrainingSetFile`
  7. 触发 `evictIfNeeded()`
- touch：`queue.sync { try? FileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.localURL.path) }`——失败不抛（spec hint 没要求 touch 抛错；调用方语义是 "best-effort 更新 LRU 时序"）
- delete：`queue.sync { try FileManager.removeItem(at: file.localURL) }`——抛 AppError（spec 协议签名 `throws`）

### §4 P5 LRU evict policy

**spec L1962："static let maxCachedSets = 20"** + **L692 + R1 modification 21（L2367）："maxCachedSets=20 + 自动 evict"**

**算法：**
- 触发点：每次 `store(...)` 成功后调用 `evictIfNeeded()`
- 实现：`listAvailable()` 内部已按 mtime 排序拿到全部条目；超出 20 → 从最老（mtime 最小）开始 `removeItem` 直到 ≤ 20
- evict 失败（如某文件被外部进程占用）→ 单条 `try?` 跳过 + os_log warning，不阻塞 store 返回（spec hint "自动 evict" 没要求 evict 失败=store 失败；调用方语义是"刚下载的成功了"）

**为什么用 mtime 而不是 atime（access time）**：
- APFS atime 默认禁用（性能原因），不能依赖
- spec L1968 只说 "更新 lastAccessedAt"，没说必须用 OS atime；"lastAccessedAt" 是 cache 自己定义的语义
- mtime 通过 `touch()` 显式 maintain，比 atime 可靠

**`pickRandom()` 实现**：`listAvailable()` 后 `randomElement()`；空 → 返 nil（spec 协议签名 `?`）

### §5 P5 错误边界翻译

**翻译表**：
- `NSCocoaErrorDomain.NSFileWriteOutOfSpaceError`（28 = ENOSPC）→ `.persistence(.diskFull)`
- `NSCocoaErrorDomain.NSFileNoSuchFileError` / `NSFileReadNoSuchFileError` → `.trainingSet(.fileNotFound)`（与 PR4a `ZipErrorMapping` 一致：训练组语义）
- `NSCocoaErrorDomain.NSFileWriteFileExistsError` → `.persistence(.ioError("file_exists"))`（不应发生，store 已先 removeItem，但 race-of-os 保护性映射）
- 兜底 → `.persistence(.ioError("filesystem_error"))`
- 已是 `AppError` 直通

**复用既有 `PersistenceErrorMapping`？**
- 拒——`PersistenceErrorMapping` 处理 GRDB DatabaseError + Decoding（数据库语义），cache manager 处理纯 FileManager（文件系统语义），混在一起会让 GRDB 路径多一层无关 NSError 分支。新建 `CacheErrorMapping` 边界明确。

### §6 P6 SettingsStore eager-load fallback 策略

**Spec literal**：`init(settingsDAO: SettingsDAO)`（L1979，无 throws）+ "`@MainActor` `@Observable`"（L1973-1975）

**问题**：`SettingsDAO.loadSettings() throws -> AppSettings`（PR #42 已落），但 init 不能 throws。

**3 选项：**

| 方案 | 优点 | 缺点 | 选/拒 |
|---|---|---|---|
| **A. eager-load with try? + fallback + log** | 签名不变；调用方代码无须改；启动 fast path | dbCorrupted 时静默 zero-default + log，用户看不到错误；首次启动新 DB（settings 表空）走 SettingsDAO 内部 missing→default 已正确处理，不会 throw | ✅ 选（详见 §6.1） |
| B. init 改 throws | 错误立即上抛 | 破坏协议；改所有 caller；E6 preview() 必须改 | ❌ 拒（破坏契约） |
| C. lazy load on first access + Bool didLoad | init 不动；错误延迟到访问时上抛 | snapshotFees 是 sync 的，不能 throws；@Observable settings 字段必须有初值，本质上还是要个 default | ❌ 拒（架构丑） |

**§6.1 A 方案语义边界（codex 必抓点，预防辩论）：**
- `SettingsDAO.loadSettings()` 的失败类型只有两种（PR #42 SettingsDAOImpl L19-58）：
  - **missing**：key 不存在（首次启动 / 新增 key）→ 返回 zero-value，**不 throw**
  - **malformed**：key 存在但 value 非法（NaN / inf / 非法 enum）→ throw `.persistence(.dbCorrupted)`
- 所以 init eager-load throws 的唯一路径 = dbCorrupted；这种情况**任何 fallback 都是有损的**：
  - 选 A（zero-default + log）：用户损失原 commission/capital 设置，但 UI 还能用
  - 选 B（init throws）：app 启动崩溃 / 进入 error UI，更"诚实"但用户体验更差
- 取舍：**选 A**——理由：dbCorrupted 是极罕见事故（用户主动改 sqlite 才会触发），fallback 让用户至少能进 UI 改设置；os_log `.error` 级别记录，崩溃上报里能看到；后续可由 U4 SettingsPanel 检测 `commissionRate == 0 && totalCapital == 0` 提示用户"检测到设置异常，请重新配置"（U4 是 Wave 2 scope，本 PR 不做）

**§6.2 update / resetCapital 异步实现**

`SettingsDAO.saveSettings(_:) throws` 和 `resetCapital() throws` 都是 sync。`SettingsStore.update(_:)` 是 `async throws`，`resetCapital()` 也是 `async throws`。

**实现：**
- 用 `Task.detached`（or `await Task.detached(priority: .userInitiated) { ... }.value`）把 sync DAO 调用从 MainActor hop 到后台线程，避免 GRDB write 阻塞 main thread
- 写成功后 hop 回 MainActor 更新 `self.settings`（@Observable 触发 UI 重渲染）
- 写失败 → 抛上去，本地 `self.settings` 不更新（保持上次成功状态）

**snapshotFees() 实现**：直接读 `self.settings.commissionRate` + `minCommissionEnabled` 构造 `FeeSnapshot`——纯读 MainActor 字段，无 IO，无需 async（spec L1981 签名就是 sync）。PR #40 类壳已经写对了，不动。

### §7 测试 isolation

P5 测试用 `FileManager.default.temporaryDirectory.appendingPathComponent("CacheTest-\(UUID())")` 作 cache root（不是 prod 的 Application Support，避免污染 simulator）。每个测试 setUp 创建 + tearDown 删除。

P6 测试用 `StubSettingsDAO`（注入返回值 + throws），不依赖 GRDB。

**为什么不用 in-process app.sqlite + DefaultAppDB**：单元测试 scope 应隔离。P5 测试不需要 sqlite，P6 测试用 stub 比真 GRDB 快百倍且无 fixture 依赖。

### §8 trust-boundary 影响评估（codex review 必问）

| 文件 | trust-boundary? | 评估 |
|---|---|---|
| `Settings/SettingsStore.swift` | ✅ `ios/**/*.swift` 在 globs 内 | 仅改 init/update/resetCapital body；**不改 public 签名**；不破坏 PR #40 contract |
| `DefaultFileSystemCacheManager.swift` | ✅ 同上 | 新文件 = 新 public class；CacheManager 协议在 PR #40，本 PR 实现一个 conformer，无新公共 API surface |
| `Internal/CacheErrorMapping.swift` | ✅ 同上 | `internal` 范围，不暴露 |
| `*Tests.swift` | ✅ `tests/**` 在 globs 内 | 测试新增，不破坏既有 |
| `docs/acceptance/...md` | ✅ `docs/**` 在 globs 内 | 验收清单，doc-only |

**结论**：本 PR 不改任何 public 协议签名（CacheManager / SettingsStore 类签名 / SettingsDAO 全部冻结），属"实现填充"，trust-boundary 风险面低。

---

## Tasks

### Task 1: P5 cache root + filename 工具 + happy-path store

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultFileSystemCacheManager.swift`
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift`
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/CacheFixture.swift`

- [ ] **Step 1.1: 写 CacheFixture helper**

```swift
// ios/Contracts/Tests/KlineTrainerPersistenceTests/CacheFixture.swift
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerPersistence
import KlineTrainerContracts

enum CacheFixture {
    /// 创建唯一 cache root in temp，调用方负责 teardown
    static func makeTempCacheRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 写一个最小有效 sqlite（含 PRAGMA user_version=schemaVersion）到 temp，返回 URL
    static func makeValidSqlite(schemaVersion: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sqlite-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
        }
        // 显式 close（drop queue 触发 close）
        return url
    }

    static func meta(id: Int, filename: String) -> TrainingSetMetaItem {
        TrainingSetMetaItem(
            id: id, stockCode: "sh.000001", stockName: "Test",
            filename: filename, schemaVersion: 1,
            contentHash: "deadbeef")
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 1.2: 写第一个失败测试 — store happy path**

```swift
// ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift
import Foundation
import Testing
@testable import KlineTrainerPersistence
import KlineTrainerContracts

@Suite("DefaultFileSystemCacheManager")
struct DefaultFileSystemCacheManagerTests {

    @Test("store: 把 src sqlite move 到 cache root，返回 TrainingSetFile 字段对齐")
    func store_happyPath_movesFileAndReturnsTrainingSetFile() throws {
        let cacheRoot = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(cacheRoot) }

        let cache = DefaultFileSystemCacheManager(cacheRoot: cacheRoot)
        let src = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        let meta = CacheFixture.meta(id: 42, filename: "stock_42.sqlite")

        let result = try cache.store(downloadedZip: src, meta: meta)

        #expect(result.id == 42)
        #expect(result.filename == "stock_42.sqlite")
        #expect(result.schemaVersion == 1)
        #expect(result.localURL.lastPathComponent == "42__stock_42.sqlite")
        #expect(FileManager.default.fileExists(atPath: result.localURL.path))
        #expect(!FileManager.default.fileExists(atPath: src.path),
                "src 应被 move 走，原位置不存在")
        #expect(result.lastAccessedAt > 0)
        #expect(result.downloadedAt > 0)
    }
}
```

- [ ] **Step 1.3: 跑测试确认 fail**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts --filter DefaultFileSystemCacheManagerTests 2>&1 | tail -8`
Expected: 编译 fail "cannot find type 'DefaultFileSystemCacheManager' in scope"

- [ ] **Step 1.4: 写最小实现使第一个测试通过**

```swift
// ios/Contracts/Sources/KlineTrainerPersistence/DefaultFileSystemCacheManager.swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts
import os.log

/// P5 缓存管理生产实现。
/// Spec: kline_trainer_modules_v1.4.md §P5 (line 1950-1968)
///
/// 设计要点（plan §Design Decisions §1-§5）：
/// - 元数据 filesystem-derived（mtime/ctime + filename `<id>__<filename>` 前缀），无 sidecar
/// - serial DispatchQueue 串行 store/touch/delete，防并发写同一 path（spec L692）
/// - atomic rename via FileManager.moveItem（same volume）
/// - LRU by mtime，maxCachedSets=20，evict 失败 log 不抛
/// - param `downloadedZip` 实为已解压 + 已 verify 的 .sqlite URL（spec drift 详 plan §2）
public final class DefaultFileSystemCacheManager: CacheManager, @unchecked Sendable {

    public static let maxCachedSets = 20

    private let cacheRoot: URL
    private let queue = DispatchQueue(label: "kline.cache.serial")
    private let log = Logger(subsystem: "kline.trainer", category: "cache")

    /// `cacheRoot` 应为 Application Support 子目录（生产）或 temp 子目录（测试）
    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
    }

    public func listAvailable() -> [TrainingSetFile] {
        queue.sync { listAvailableLocked() }
    }

    public func pickRandom() -> TrainingSetFile? {
        queue.sync { listAvailableLocked().randomElement() }
    }

    public func store(downloadedZip src: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile {
        try queue.sync {
            try ensureCacheRootExists()
            let target = cacheRoot.appendingPathComponent("\(meta.id)__\(meta.filename)")
            // 同 id 重新下载 → 覆盖
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            do {
                try FileManager.default.moveItem(at: src, to: target)
            } catch {
                throw CacheErrorMapping.translate(error)
            }
            let attrs = try fileAttributes(target)
            evictIfNeededLocked()
            return TrainingSetFile(
                id: meta.id,
                filename: meta.filename,
                localURL: target,
                schemaVersion: try readSchemaVersion(target),
                lastAccessedAt: attrs.mtime,
                downloadedAt: attrs.ctime)
        }
    }

    public func touch(_ file: TrainingSetFile) {
        queue.sync {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: file.localURL.path)
        }
    }

    public func delete(_ file: TrainingSetFile) throws {
        try queue.sync {
            do {
                try FileManager.default.removeItem(at: file.localURL)
            } catch {
                throw CacheErrorMapping.translate(error)
            }
        }
    }

    // MARK: - Internal (locked = caller already in queue.sync)

    private func ensureCacheRootExists() throws {
        if !FileManager.default.fileExists(atPath: cacheRoot.path) {
            do {
                try FileManager.default.createDirectory(
                    at: cacheRoot, withIntermediateDirectories: true)
            } catch {
                throw CacheErrorMapping.translate(error)
            }
        }
    }

    private func listAvailableLocked() -> [TrainingSetFile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var results: [TrainingSetFile] = []
        for entry in entries {
            guard entry.pathExtension.lowercased() == "sqlite" else { continue }
            let basename = entry.deletingPathExtension().lastPathComponent
            // basename = "<id>__<filenameWithoutExt>"；split 取 id
            let parts = basename.components(separatedBy: "__")
            guard parts.count >= 2, let id = Int(parts[0]) else { continue }
            let filename = parts.dropFirst().joined(separator: "__") + ".sqlite"
            guard let attrs = try? fileAttributes(entry),
                  let schemaVersion = try? readSchemaVersion(entry) else { continue }
            results.append(TrainingSetFile(
                id: id, filename: filename, localURL: entry,
                schemaVersion: schemaVersion,
                lastAccessedAt: attrs.mtime,
                downloadedAt: attrs.ctime))
        }
        // 按 mtime desc 排序（newest first）
        return results.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    private func evictIfNeededLocked() {
        let all = listAvailableLocked()
        guard all.count > Self.maxCachedSets else { return }
        let toEvict = all.suffix(all.count - Self.maxCachedSets)  // 最老的（mtime 最小）
        for f in toEvict {
            do {
                try FileManager.default.removeItem(at: f.localURL)
            } catch {
                log.error("cache evict failed for \(f.localURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func fileAttributes(_ url: URL) throws -> (mtime: Int64, ctime: Int64) {
        let raw = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (raw[.modificationDate] as? Date) ?? Date()
        let ctime = (raw[.creationDate] as? Date) ?? mtime
        return (Int64(mtime.timeIntervalSince1970), Int64(ctime.timeIntervalSince1970))
    }

    private func readSchemaVersion(_ url: URL) throws -> Int {
        do {
            let q = try DatabaseQueue(path: url.path)
            return try q.read { db in
                let row = try Row.fetchOne(db, sql: "PRAGMA user_version")
                return row.map { ($0[0] as Int64?) ?? 0 }.map(Int.init) ?? 0
            }
        } catch {
            throw CacheErrorMapping.translate(error)
        }
    }
}
```

```swift
// ios/Contracts/Sources/KlineTrainerPersistence/Internal/CacheErrorMapping.swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// FileManager / Foundation IO 错误到 AppError 的边界翻译（per docs/governance/m04-apperror-translation-gate.md）。
/// 仅 KlineTrainerPersistence 模块内部使用。
enum CacheErrorMapping {
    static func translate(_ error: Error) -> AppError {
        if let app = error as? AppError { return app }

        // GRDB 路径（PRAGMA user_version 读失败）
        if let dbErr = error as? DatabaseError {
            if dbErr.resultCode == .SQLITE_CANTOPEN || dbErr.resultCode == .SQLITE_NOTADB
                || dbErr.resultCode == .SQLITE_CORRUPT {
                return .persistence(.dbCorrupted)
            }
            return .persistence(.ioError("sqlite_error_\(dbErr.resultCode.rawValue)"))
        }

        let nsErr = error as NSError
        if nsErr.domain == NSCocoaErrorDomain {
            switch nsErr.code {
            case NSFileWriteOutOfSpaceError:
                return .persistence(.diskFull)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .trainingSet(.fileNotFound)
            case NSFileWriteFileExistsError:
                return .persistence(.ioError("file_exists"))
            default:
                return .persistence(.ioError("filesystem_error"))
            }
        }
        return .persistence(.ioError("filesystem_error"))
    }
}
```

- [ ] **Step 1.5: 跑测试确认 happy path 通过**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts --filter DefaultFileSystemCacheManager 2>&1 | tail -8`
Expected: 1 test passed

- [ ] **Step 1.6: Commit**

```bash
cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings'
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultFileSystemCacheManager.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/CacheErrorMapping.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/CacheFixture.swift
git commit -m "feat(P5-cache): DefaultFileSystemCacheManager store happy path + CacheErrorMapping"
```

---

### Task 2: P5 listAvailable / pickRandom / touch / delete tests

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift`

- [ ] **Step 2.1: 加测试 — listAvailable 返回所有 store 过的 + 按 mtime desc**

```swift
@Test("listAvailable: 多次 store 后按 mtime desc 列出")
func listAvailable_returnsStoredFilesSortedByMtimeDesc() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    let src1 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    _ = try cache.store(downloadedZip: src1, meta: CacheFixture.meta(id: 1, filename: "a.sqlite"))
    Thread.sleep(forTimeInterval: 1.1)  // mtime 至少差 1s（filesystem 精度）
    let src2 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    _ = try cache.store(downloadedZip: src2, meta: CacheFixture.meta(id: 2, filename: "b.sqlite"))

    let all = cache.listAvailable()
    #expect(all.count == 2)
    #expect(all[0].id == 2, "newest first")
    #expect(all[1].id == 1)
}

@Test("pickRandom: 空 cache 返 nil；非空返其中一个")
func pickRandom_returnsNilWhenEmpty_returnsAnyWhenNonEmpty() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    #expect(cache.pickRandom() == nil)

    let src = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    _ = try cache.store(downloadedZip: src, meta: CacheFixture.meta(id: 7, filename: "x.sqlite"))

    let picked = cache.pickRandom()
    #expect(picked?.id == 7)
}

@Test("touch: 更新 mtime，listAvailable 排序受影响")
func touch_updatesMtime_changesListSortOrder() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    let s1 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    let f1 = try cache.store(downloadedZip: s1, meta: CacheFixture.meta(id: 1, filename: "a.sqlite"))
    Thread.sleep(forTimeInterval: 1.1)
    let s2 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    _ = try cache.store(downloadedZip: s2, meta: CacheFixture.meta(id: 2, filename: "b.sqlite"))
    // 现 list[0]=2, list[1]=1
    Thread.sleep(forTimeInterval: 1.1)
    cache.touch(f1)  // 把 1 的 mtime 推到 now
    let after = cache.listAvailable()
    #expect(after[0].id == 1, "touch 后 1 应排到最前")
}

@Test("delete: 删除指定文件，listAvailable 不再包含")
func delete_removesFile_listAvailableExcludesIt() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    let f = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: 9, filename: "x.sqlite"))
    try cache.delete(f)
    #expect(cache.listAvailable().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.localURL.path))
}

@Test("delete: 不存在的文件抛 .trainingSet(.fileNotFound)")
func delete_nonExistentThrowsFileNotFound() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    let ghost = TrainingSetFile(
        id: 0, filename: "ghost.sqlite",
        localURL: root.appendingPathComponent("0__ghost.sqlite"),
        schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)
    #expect(throws: AppError.trainingSet(.fileNotFound)) {
        try cache.delete(ghost)
    }
}
```

- [ ] **Step 2.2: 跑测试确认全过**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts --filter DefaultFileSystemCacheManager 2>&1 | tail -8`
Expected: 6 tests passed（含 Task 1 的 1 个）

- [ ] **Step 2.3: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift
git commit -m "test(P5-cache): listAvailable / pickRandom / touch / delete behaviors"
```

---

### Task 3: P5 LRU evict + 覆盖语义 + 并发 store 安全

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift`

- [ ] **Step 3.1: 加 evict 测试（store 第 21 个时驱逐最老）**

```swift
@Test("store: 超 maxCachedSets=20 时驱逐 mtime 最老的")
func store_evictsOldestWhenExceedsMaxCachedSets() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    // 写 20 个，每个间隔确保 mtime 单调
    var firstFile: TrainingSetFile?
    for i in 1...20 {
        let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        let f = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: i, filename: "f\(i).sqlite"))
        if i == 1 { firstFile = f }
        if i < 20 { Thread.sleep(forTimeInterval: 1.1) }
    }
    #expect(cache.listAvailable().count == 20)

    Thread.sleep(forTimeInterval: 1.1)
    // 第 21 个 → 应驱逐 id=1（mtime 最老）
    let s21 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    _ = try cache.store(downloadedZip: s21, meta: CacheFixture.meta(id: 21, filename: "f21.sqlite"))

    let after = cache.listAvailable()
    #expect(after.count == 20)
    #expect(!after.contains { $0.id == 1 }, "id=1 应被驱逐")
    #expect(after.contains { $0.id == 21 }, "id=21 应在")
    if let f = firstFile {
        #expect(!FileManager.default.fileExists(atPath: f.localURL.path),
                "id=1 物理文件应被删")
    }
}
```

- [ ] **Step 3.2: 加同 id 覆盖测试**

```swift
@Test("store: 同 id 重新 store 覆盖旧文件，listAvailable 仍只 1 条")
func store_sameIdOverwritesOldFile() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    let s1 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    _ = try cache.store(downloadedZip: s1, meta: CacheFixture.meta(id: 5, filename: "x.sqlite"))
    let s2 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    let r2 = try cache.store(downloadedZip: s2, meta: CacheFixture.meta(id: 5, filename: "x.sqlite"))

    let all = cache.listAvailable()
    #expect(all.count == 1)
    #expect(all[0].id == 5)
    #expect(all[0].localURL == r2.localURL)
}
```

- [ ] **Step 3.3: 加并发 store 安全测试**

```swift
@Test("store: 并发 10 次不同 id 全部成功 + listAvailable count=10")
func store_concurrentDifferentIds_allSucceed() async throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for i in 1...10 {
            group.addTask {
                let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
                _ = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: i, filename: "p\(i).sqlite"))
            }
        }
        try await group.waitForAll()
    }
    #expect(cache.listAvailable().count == 10)
}
```

- [ ] **Step 3.4: 跑测试**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts --filter DefaultFileSystemCacheManager 2>&1 | tail -8`
Expected: 9 tests passed

注：evict 测试 含 21 次 1.1s sleep ≈ 23s，可接受单测时长。

- [ ] **Step 3.5: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift
git commit -m "test(P5-cache): LRU evict + same-id overwrite + concurrent store"
```

---

### Task 4: P5 错误路径测试 + AppError gate 验证

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift`
- Create: `scripts/check_p5_apperror_gate.sh`

- [ ] **Step 4.1: 加错误路径测试**

```swift
@Test("store: src 文件不存在抛 .trainingSet(.fileNotFound)")
func store_srcMissingThrowsFileNotFound() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    let ghost = FileManager.default.temporaryDirectory
        .appendingPathComponent("nonexistent-\(UUID()).sqlite")
    #expect(throws: AppError.trainingSet(.fileNotFound)) {
        try cache.store(downloadedZip: ghost,
                        meta: CacheFixture.meta(id: 1, filename: "x.sqlite"))
    }
}

@Test("store: src 不是合法 sqlite 抛 .persistence(.dbCorrupted)（PRAGMA 读失败）")
func store_invalidSqliteThrowsDbCorrupted() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("bogus-\(UUID()).sqlite")
    try Data("not a sqlite".utf8).write(to: bogus)
    #expect(throws: AppError.persistence(.dbCorrupted)) {
        try cache.store(downloadedZip: bogus,
                        meta: CacheFixture.meta(id: 1, filename: "x.sqlite"))
    }
}
```

- [ ] **Step 4.2: 写 AppError gate script**

```bash
# scripts/check_p5_apperror_gate.sh
#!/usr/bin/env bash
# 验证 DefaultFileSystemCacheManager 不裸抛非 AppError 错误（M0.4 trust-boundary gate）
# 规则：所有 throw 必须 throw AppError.* 或 throw CacheErrorMapping.translate(...)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/ios/Contracts/Sources/KlineTrainerPersistence/DefaultFileSystemCacheManager.swift"
if [ ! -f "$F" ]; then
  echo "FAIL: $F 不存在"
  exit 1
fi
# 抓所有 throw 行，排除 throw AppError / throw CacheErrorMapping.translate
BAD=$(grep -nE '^\s*throw\s+' "$F" \
  | grep -vE 'throw\s+AppError\.' \
  | grep -vE 'throw\s+CacheErrorMapping\.translate' \
  || true)
if [ -n "$BAD" ]; then
  echo "FAIL: P5 DefaultFileSystemCacheManager 含未走 AppError 边界的 throw："
  echo "$BAD"
  exit 1
fi
echo "OK: P5 DefaultFileSystemCacheManager 全部 throw 走 AppError 边界"
```

- [ ] **Step 4.3: 跑测试 + 跑 gate**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts --filter DefaultFileSystemCacheManager 2>&1 | tail -3`
Expected: 11 tests passed

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && chmod +x scripts/check_p5_apperror_gate.sh && bash scripts/check_p5_apperror_gate.sh`
Expected: `OK: P5 DefaultFileSystemCacheManager 全部 throw 走 AppError 边界`

- [ ] **Step 4.4: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultFileSystemCacheManagerTests.swift \
        scripts/check_p5_apperror_gate.sh
git commit -m "test(P5-cache): error path tests + M0.4 AppError gate script"
```

---

### Task 5: P6 SettingsStore eager-load init

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/StubSettingsDAO.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`

- [ ] **Step 5.1: 写 StubSettingsDAO helper**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/StubSettingsDAO.swift
import Foundation
@testable import KlineTrainerContracts

public final class StubSettingsDAO: SettingsDAO, @unchecked Sendable {
    public var stubLoadResult: Result<AppSettings, Error>
    public private(set) var savedSettings: AppSettings?
    public private(set) var resetCalled = false
    public var saveError: Error?

    public init(load: Result<AppSettings, Error> = .success(.zero)) {
        self.stubLoadResult = load
    }

    public func loadSettings() throws -> AppSettings {
        switch stubLoadResult {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }

    public func saveSettings(_ s: AppSettings) throws {
        if let e = saveError { throw e }
        savedSettings = s
    }

    public func resetCapital() throws {
        resetCalled = true
    }
}

extension AppSettings {
    /// 测试 helper：zero-value
    public static let zero = AppSettings(
        commissionRate: 0, minCommissionEnabled: false,
        totalCapital: 0, displayMode: .system)
}
```

- [ ] **Step 5.2: 写 P6 第一个失败测试 — eager-load happy**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift
import Foundation
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("SettingsStore production")
struct SettingsStoreProductionTests {

    @Test("init: dao 返合法 settings → settings 字段对齐 dao 返回值")
    func init_loadsSettingsFromDAO() throws {
        let want = AppSettings(
            commissionRate: 0.0001, minCommissionEnabled: true,
            totalCapital: 100_000, displayMode: .dark)
        let dao = StubSettingsDAO(load: .success(want))

        let store = SettingsStore(settingsDAO: dao)
        #expect(store.settings == want)
    }

    @Test("init: dao throws .dbCorrupted → fallback 到 zero-value，不崩")
    func init_daoThrowsCorrupted_fallsBackToZero() throws {
        let dao = StubSettingsDAO(load: .failure(AppError.persistence(.dbCorrupted)))
        let store = SettingsStore(settingsDAO: dao)
        #expect(store.settings == .zero)
    }
}
```

- [ ] **Step 5.3: 跑测试确认 fail（既有 stub init 用 zero-default 不调 dao）**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts --filter SettingsStoreProductionTests 2>&1 | tail -8`
Expected: `init_loadsSettingsFromDAO` fail（settings 是 zero 不是 want）

- [ ] **Step 5.4: 改 SettingsStore.init 实现 eager-load**

把 `SettingsStore.swift` 的 init 替换为：

```swift
public init(settingsDAO: SettingsDAO) {
    self.settingsDAO = settingsDAO
    // Production impl: eager-load via SettingsDAO
    // dao failure (only path = .persistence(.dbCorrupted) per SettingsDAOImpl) → zero-value fallback + os_log
    // 详见 plan §6.1：missing key 已被 SettingsDAO 内部处理为 default，不抛
    do {
        self.settings = try settingsDAO.loadSettings()
    } catch {
        // dbCorrupted → 用 zero-value 让 UI 还能跑；用户后续可通过 U4 SettingsPanel 重置
        self.settings = AppSettings(
            commissionRate: 0, minCommissionEnabled: false,
            totalCapital: 0, displayMode: .system)
        Logger(subsystem: "kline.trainer", category: "settings").error(
            "SettingsStore.init: loadSettings failed, fallback to zero-value: \(String(describing: error), privacy: .public)")
    }
}
```

加 import：

```swift
import os.log
```

- [ ] **Step 5.5: 跑测试确认通过**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts --filter SettingsStoreProductionTests 2>&1 | tail -8`
Expected: 2 tests passed

- [ ] **Step 5.6: 验证 PR #40 既有测试不破**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts 2>&1 | tail -3`
Expected: 全套 ≥187 tests 全过（185 baseline + 11 P5 - rough，最终验证）

- [ ] **Step 5.7: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/StubSettingsDAO.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift
git commit -m "feat(P6-settings): SettingsStore.init eager-load via SettingsDAO + fallback"
```

---

### Task 6: P6 update / resetCapital 实现

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift`

- [ ] **Step 6.1: 加 update 测试**

```swift
@Test("update: mutate block 修改 settings 后 dao.saveSettings 被调；本地 settings 同步更新")
func update_persistsViaDAO_updatesLocalSettings() async throws {
    let dao = StubSettingsDAO(load: .success(.zero))
    let store = SettingsStore(settingsDAO: dao)

    try await store.update { s in
        s.commissionRate = 0.0003
        s.totalCapital = 50_000
    }

    #expect(dao.savedSettings?.commissionRate == 0.0003)
    #expect(dao.savedSettings?.totalCapital == 50_000)
    #expect(store.settings.commissionRate == 0.0003)
    #expect(store.settings.totalCapital == 50_000)
}

@Test("update: dao.saveSettings throws → 错误上抛 + 本地 settings 不变")
func update_daoSaveThrows_localUnchanged() async throws {
    let initial = AppSettings(
        commissionRate: 0.0001, minCommissionEnabled: false,
        totalCapital: 10_000, displayMode: .system)
    let dao = StubSettingsDAO(load: .success(initial))
    dao.saveError = AppError.persistence(.diskFull)
    let store = SettingsStore(settingsDAO: dao)

    await #expect(throws: AppError.persistence(.diskFull)) {
        try await store.update { s in s.commissionRate = 0.99 }
    }
    #expect(store.settings == initial)
}

@Test("resetCapital: dao.resetCapital 被调；本地 settings.totalCapital 归 0")
func resetCapital_callsDAOAndZerosLocalCapital() async throws {
    let initial = AppSettings(
        commissionRate: 0.0001, minCommissionEnabled: true,
        totalCapital: 999, displayMode: .dark)
    let dao = StubSettingsDAO(load: .success(initial))
    let store = SettingsStore(settingsDAO: dao)

    try await store.resetCapital()
    #expect(dao.resetCalled)
    #expect(store.settings.totalCapital == 0)
    // 其它字段不变
    #expect(store.settings.commissionRate == 0.0001)
    #expect(store.settings.minCommissionEnabled == true)
    #expect(store.settings.displayMode == .dark)
}
```

- [ ] **Step 6.2: 改 SettingsStore.update / resetCapital 实做**

把 update 和 resetCapital 实现替换为：

```swift
public func update(_ mutate: (inout AppSettings) -> Void) async throws {
    var copy = self.settings
    mutate(&copy)
    let snapshot = copy
    let dao = settingsDAO
    try await Task.detached(priority: .userInitiated) {
        try dao.saveSettings(snapshot)
    }.value
    // 写成功后回 MainActor 更新（detached.value resume 在原 actor）
    self.settings = snapshot
}

public func resetCapital() async throws {
    let dao = settingsDAO
    try await Task.detached(priority: .userInitiated) {
        try dao.resetCapital()
    }.value
    self.settings.totalCapital = 0
}
```

- [ ] **Step 6.3: 跑测试**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts --filter SettingsStoreProductionTests 2>&1 | tail -8`
Expected: 5 tests passed（含 Task 5 的 2 个）

- [ ] **Step 6.4: 跑全套**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts 2>&1 | tail -3`
Expected: ≥199 tests passed

- [ ] **Step 6.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift
git commit -m "feat(P6-settings): SettingsStore.update/resetCapital production impl"
```

---

### Task 7: 验收文档 + 全套绿灯 + 推到 PR

**Files:**
- Create: `docs/acceptance/2026-05-04-pr4b-cache-settings.md`

- [ ] **Step 7.1: 写验收清单**

```markdown
# PR4b P5 CacheManager + P6 SettingsStore 验收清单

> 验收人：用户（非 coder 可执行）
> Spec 锚点：`kline_trainer_modules_v1.4.md` §P5 line 1950-1968 + §P6 line 1970-1983
> Plan：`docs/superpowers/plans/2026-05-04-pr4b-cache-settings.md`

## 一、SwiftPM 编译 + 全套测试

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 1 | 在终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings" && swift build --package-path ios/Contracts` | 输出含 `Build complete!`，无 error / warning | 看到 `Build complete!` 且无红字 = ✅ |
| 2 | 在终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings" && swift test --package-path ios/Contracts 2>&1 \| tail -3` | 末行：`Test run with N tests in M suites passed`，N ≥ 199 | 末行 `passed` 且 N ≥ 199 = ✅ |
| 3 | 在终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings" && bash scripts/check_p5_apperror_gate.sh` | 输出 `OK: P5 DefaultFileSystemCacheManager 全部 throw 走 AppError 边界` | 看到 `OK:` 行 = ✅ |

## 二、文件结构存在

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 4 | 终端执行 `ls "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings/ios/Contracts/Sources/KlineTrainerPersistence/" \| grep -E "DefaultFileSystemCacheManager"` | 输出 `DefaultFileSystemCacheManager.swift` | 看到该文件 = ✅ |
| 5 | 终端执行 `ls "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings/ios/Contracts/Sources/KlineTrainerPersistence/Internal/" \| grep CacheErrorMapping` | 输出 `CacheErrorMapping.swift` | 看到该文件 = ✅ |

## 三、签名冻结（trust-boundary 不变）

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 6 | 终端执行 `grep -c "fatalError" "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings/ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift"` | 输出 `0`（生产实现替换全部 fatalError 类壳）| 输出 `0` = ✅ |
| 7 | 终端执行 `grep -E "public protocol CacheManager" "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings/ios/Contracts/Sources/KlineTrainerContracts/Persistence/CacheManager.swift"` | 输出 1 行 `public protocol CacheManager: Sendable {` | 输出该行 = ✅（协议未改）|

## 失败兜底
- 任意命令 fail → 修复后重跑；不 push PR
- AppError gate 失败 → 加 try/catch 边界，禁止裸 throw NSError
- 测试数 < 199 → 检查是否有测试被跳过 / 编译失败导致测试集减少
```

- [ ] **Step 7.2: 跑最终全套确认**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift build --package-path ios/Contracts 2>&1 | tail -3`
Expected: `Build complete!`

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts 2>&1 | tail -3`
Expected: ≥199 tests passed

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && bash scripts/check_p5_apperror_gate.sh`
Expected: `OK:` 行

- [ ] **Step 7.3: Commit + push**

```bash
git add docs/acceptance/2026-05-04-pr4b-cache-settings.md
git commit -m "docs(PR4b): acceptance checklist (Chinese, non-coder runnable)"
git push -u origin pr4b-cache-settings
```

---

## Self-Review Checklist

- [ ] **Spec coverage**：
  - P5 5 方法（listAvailable / pickRandom / store / touch / delete）全部覆盖 → Task 1-3 ✓
  - P5 maxCachedSets=20 + 自动 evict（spec L1962, L2367）→ Task 3 ✓
  - P5 临时文件 + atomic rename（spec L687）→ Task 1 store impl 用 moveItem ✓
  - P5 串行队列防并发同 path（spec L692）→ Task 1 + Task 3 并发测试 ✓
  - P6 init(settingsDAO:) + 4 方法（spec L1979-1982）→ Task 5-6 ✓
  - P6 @MainActor @Observable（spec L1973-1975）→ 既有 PR #40 类壳已标，不动 ✓
  - P6 snapshotFees 同步实现 → 既有 PR #40 类壳已写正确，不动 ✓

- [ ] **No placeholders**：所有 throw / fallback / log 路径都有具体代码；无 TODO / TBD ✓

- [ ] **Type consistency**：
  - `TrainingSetFile` 字段名（id/filename/localURL/schemaVersion/lastAccessedAt/downloadedAt）与 PR #40 已 freeze 的 `AppState.swift:130-149` 完全一致
  - `AppSettings` 字段名与 PR #40 freeze（commissionRate/minCommissionEnabled/totalCapital/displayMode）完全一致
  - `AppError` 枚举 case（.persistence(.diskFull/.dbCorrupted/.ioError) / .trainingSet(.fileNotFound)）与 `AppError.swift` 既有定义对齐

- [ ] **Trust-boundary 评估**：§Design Decision §8 已列；不改任何 public 协议签名

- [ ] **LOC 预算**：≈ 285 prod LOC < 500 硬规则 ✓

- [ ] **TDD discipline**：每个 task 都是 test → fail → impl → pass → commit；Task 1/5 严格 TDD（先写测试），Task 2/3/4/6 是 additive 测试

- [ ] **Commit ritual**：每个 task 末尾独立 commit；7 commits 总数

---

## Out-of-Scope（明确不做）

- ❌ DownloadAcceptanceRunner 编排（依赖 P1 APIClient 未交付，Wave 1 scope）
- ❌ U4 SettingsPanel UI（Wave 2 scope）
- ❌ `URL.setResourceValues(.excludedFromBackup)` for cache files（cache 是可重新下载的，理论上应排除 iCloud backup；本 PR 不做，留 backlog）
- ❌ CacheManager 协议签名改名 `downloadedZip` → `extractedSqlite`（contract change PR；不混进生产实现 PR）
- ❌ `cache_index.json` / `app.sqlite training_set_files` 表（§Design Decision §1 已拒）
- ❌ touch() 抛错路径（spec hint 是 best-effort，无业务语义需要）
