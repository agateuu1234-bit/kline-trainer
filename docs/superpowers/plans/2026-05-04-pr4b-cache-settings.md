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

**预估 prod LOC（硬规则 ≤500；R1 修订上调）**：
- `DefaultFileSystemCacheManager.swift`：≈ 250 LOC（含 R1 stage/replace/touch helpers + defer cleanup + `.staging-` skip 逻辑）
- `Internal/CacheErrorMapping.swift`：≈ 35 LOC
- `Settings/SettingsStore.swift` 改动：净增 ≈ 70 LOC（R1 inflight Task chain + init eager-load + update/resetCapital）
- 合计：**≈ 355 prod LOC** ✓ 仍在 500 内

**预估 test LOC**：≈ 580（R1 加 H-1/H-2/H-3 三组 regression 测试，约 +130 行）

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

### §3 P5 atomic rename + serial queue（R1 重写：rollback-safe + explicit mtime touch）

**spec L687："文件系统：P5 `store()` 采用临时文件 + rename 原子化。"**
**spec L692："❌ 并发多次 `CacheManager.store()` 写同一目标路径"**

**R1 codex finding H-1（rollback safety）+ H-2（mtime preservation 导致立刻 evict）已采纳，重写如下：**

**算法（rollback-safe two-stage）：**

- 入参 `downloadedZip: URL`（实为 .sqlite URL）来自 caller 的 `temporaryDirectory`（P2 ZipExtractor 输出）
- final target path = `<cacheRoot>/<id>__<meta.filename>`
- staging path = `<cacheRoot>/.staging-<UUID>__<id>__<meta.filename>`（cacheRoot 内同一目录 → `replaceItemAt` 走 fast atomic 路径；`.staging-` 前缀让 `listAvailable` 能 skip）
- 串行 `DispatchQueue(label: "kline.cache.serial")`，store/touch/delete 全部 `queue.sync { ... }` 保证同 target path 不可能并发写

**store 内部 6 步（必要时用 cleanup defer 防 staging 残留）：**

  1. `queue.sync` 进入串行段
  2. `ensureCacheRootExists()` → 创建 cache root（已封装 do/catch + translate）
  3. **stage**：`stageFile(from: src, to: stagingURL)` → 把 src 移入 cacheRoot 同目录的 staging 路径（move 失败 → translate + throw；defer 注册 staging cleanup，验证失败时清理）
  4. **touch staging**：`touchFile(stagingURL)` → 立即 `setAttributes([.modificationDate: Date()])`，让 mtime = now（防 H-2 老 mtime 立刻被 evict；wrap 内部）
  5. **validate**：`readSchemaVersion(stagingURL)` 打开 GRDB DatabaseQueue 读 PRAGMA user_version → 失败（无效 sqlite / 损坏）即抛 AppError，defer 清 staging，target **不动** ✓
  6. **atomic replace**：`try replaceFile(at: target, with: stagingURL)`（封装 `FileManager.replaceItemAt(target, withItemAt: staging)`）
     - same-directory replace 用 `rename(2)` POSIX 系统调用，atomic 在 APFS 上保证 ✓
     - 旧 target 存在 → swap；不存在 → 创建 target；任何情况下 staging 路径在 replaceItemAt 后**消失**（被 rename 走或 swap 走），cleanup defer 是 no-op
     - replace 失败 → defer 清 staging，target **不动** ✓
  7. 读 attrs（mtime 应 ≈ now / ctime 来自 src 文件创建时刻；wrap 内部）
  8. `evictIfNeededLocked()` → 现在 newest mtime 必为 now，evict 不会误删本次 store 的项
  9. 返回 `TrainingSetFile { id, filename, localURL: target, schemaVersion, lastAccessedAt: nowMtime, downloadedAt: ctime }`

**为什么先 stage 再 validate 再 replace（R0 的 "先删 target 再 move" 错在哪）**：
- R0 顺序：`removeItem(target)` → `moveItem(src, target)` → `readSchemaVersion(target)` → 若 PRAGMA fail，旧 target 已被删，新文件留在 target 但损坏。**用户 data loss + 留 corrupt cache** 双输。
- R1 顺序：staging → validate → atomic replace。validate fail 时 staging 已被 defer 删干净 + 旧 target **从未触动**；replace fail 时同样 target 不动。**任意失败均 rollback-safe** ✓

**为什么 touch staging 而不是 touch target**：
- `setAttributes([.modificationDate: Date()])` 修改 inode mtime；`replaceItemAt` 走 rename 后 mtime 跟随 inode 走 → target mtime = now ✓
- 若 touch target（after replace），`replaceItemAt` 在某些 APFS 路径会重建 inode → touch 用错 path 拿到 stale handle 的可能性更高，复杂度更高
- 顺序：`touch staging → replace → 读 target attrs` 更直白

**touch（公开方法，spec 协议）**：`queue.sync { try? touchFile(file.localURL) }`——失败不抛（spec hint 没要求 touch 抛错；语义 "best-effort 更新 LRU 时序"）

**delete（公开方法，spec 协议）**：`queue.sync { try removeFile(file.localURL) }`——helper 内部 wrap，throws AppError

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

### §5 P5 错误边界翻译（R1 强化：所有 helper 内部 wrap，public 方法零 raw try）

**翻译表**：
- `NSCocoaErrorDomain.NSFileWriteOutOfSpaceError`（28 = ENOSPC）→ `.persistence(.diskFull)`
- `NSCocoaErrorDomain.NSFileNoSuchFileError` / `NSFileReadNoSuchFileError` → `.trainingSet(.fileNotFound)`（与 PR4a `ZipErrorMapping` 一致：训练组语义）
- `NSCocoaErrorDomain.NSFileWriteFileExistsError` → `.persistence(.ioError("file_exists"))`（不应发生，replaceItemAt 已 swap；race 保护映射）
- `DatabaseError.SQLITE_CANTOPEN / SQLITE_NOTADB / SQLITE_CORRUPT` → `.persistence(.dbCorrupted)`
- 兜底 → `.persistence(.ioError("filesystem_error"))` / `.persistence(.ioError("sqlite_error_<code>"))`
- 已是 `AppError` 直通

**复用既有 `PersistenceErrorMapping`？**
- 拒——`PersistenceErrorMapping` 处理 GRDB DatabaseError + Decoding（数据库语义），cache manager 处理纯 FileManager（文件系统语义），混在一起会让 GRDB 路径多一层无关 NSError 分支。新建 `CacheErrorMapping` 边界明确。

**R1 强化：M-4 codex finding 采纳，封装策略 = "public 方法零 raw try"：**

所有 `try FileManager.default.X()` / `try DatabaseQueue` 调用必须在 named private helpers 内部（`stageFile / touchFile / replaceFile / removeFile / fileAttributes / readSchemaVersion / ensureCacheRootExists`），每个 helper 内部 do/catch wrap → throw AppError。public 方法（store / touch / delete / listAvailable / pickRandom）只调 helpers，不出现 raw `try FileManager.` / `try DatabaseQueue`。

**Gate script（Task 4 详）增强**：
1. 既有规则：禁裸 `throw NSError|throw .*Error`（PR4a 套路）
2. 新增规则：`grep -E 'try FileManager|try DatabaseQueue' DefaultFileSystemCacheManager.swift` 命中的每行必须出现在 private helper 内（即所在函数签名为 `private func`），public 方法体内（`public func`）一行都不能有
3. 新增规则：每个 private helper 内若含 `try FileManager` / `try DatabaseQueue`，文件内必须存在对应的 do/catch + `CacheErrorMapping.translate` 引用

### §6 P6 SettingsStore eager-load fallback 策略

**Spec literal**：`init(settingsDAO: SettingsDAO)`（L1979，无 throws）+ "`@MainActor` `@Observable`"（L1973-1975）

**问题**：`SettingsDAO.loadSettings() throws -> AppSettings`（PR #42 已落），但 init 不能 throws。

**3 选项：**

| 方案 | 优点 | 缺点 | 选/拒 |
|---|---|---|---|
| **A. eager-load with try? + fallback + log** | 签名不变；调用方代码无须改；启动 fast path | dbCorrupted 时静默 zero-default + log，用户看不到错误；首次启动新 DB（settings 表空）走 SettingsDAO 内部 missing→default 已正确处理，不会 throw | ✅ 选（详见 §6.1） |
| B. init 改 throws | 错误立即上抛 | 破坏协议；改所有 caller；E6 preview() 必须改 | ❌ 拒（破坏契约） |
| C. lazy load on first access + Bool didLoad | init 不动；错误延迟到访问时上抛 | snapshotFees 是 sync 的，不能 throws；@Observable settings 字段必须有初值，本质上还是要个 default | ❌ 拒（架构丑） |

**§6.1 A 方案语义边界（R4 修订 codex R4-H1：dbCorrupted 也阻塞写，无特例）：**

- `SettingsDAO.loadSettings()` 的失败 surface（per `PersistenceErrorMapping`）：
  - **missing**：key 不存在 → zero-value，**不 throw** ✓
  - **malformed**：value 非法（NaN/inf/非法 enum）→ throw `.persistence(.dbCorrupted)`
  - **transient I/O**：sqlite_busy / locked / 短暂 ENOENT → `.persistence(.ioError(...))`
  - **diskFull / schemaMismatch / 其它**：`.persistence(.diskFull/.schemaMismatch)`

**R0/R1/R2/R3 的 H-3 残留 bug**（codex R4 抓的最终形态）：
- SettingsDAO 是 **key-value** 表（4 个 row：commission_rate / min_commission_enabled / total_capital / display_mode）
- dbCorrupted 可由**单一 key 的 malformed value** 触发（譬如 `display_mode='INVALID'`），但**其它 3 个 key 是合法的**（用户已设的 commission / capital / minCommission）
- R2/R3 设计：dbCorrupted → zero-default + 允许后续 update
- 用户改 displayMode 触发 update → `saveSettings` 把 self.settings 全 4 字段写回 → **zero 覆盖了原本合法的 commission/capital/minCommission** = data loss

**R4 修订 (A''，最终形态)**：
- 任何 load 失败（含 dbCorrupted）→ 同时 `loadError = e` + zero-default UI
- `update / resetCapital` 入口 `if let e = loadError { throw e }` —— 阻塞写直到下次成功 load
- 用户唯一恢复路径 = 重启 app 触发 init 重新 load；如重启仍失败，需 Wave 2 U4 SettingsPanel 提供显式 "重置全部 settings" 按钮（本 PR 不做）
- snapshotFees 不阻塞（read-only，spec 签名无 throws）

**为什么不分 dbCorrupted 和其它**：
- 都可能伴随**部分合法 keys**（dbCorrupted 来自单 key malformed；transient I/O 也可能只锁单行）
- 让 SettingsDAO 区分并 surface "哪些 key OK / 哪些 bad" 是 SettingsDAO 内部改造，超 PR4b scope（属 Wave 2 U4 配合）
- 当前 SettingsDAO API 只能 all-or-nothing load；client 端**无法区分** "整体 corrupt" vs "单 key corrupt"，必须 conservative 阻塞

```swift
private var loadError: AppError?

public init(settingsDAO: SettingsDAO) {
    self.settingsDAO = settingsDAO
    do {
        self.settings = try settingsDAO.loadSettings()
    } catch {
        // R4 H-1: 任何错误（含 dbCorrupted）都阻塞写，避免 silent 覆盖部分合法 keys
        self.settings = SettingsStore.zeroDefault
        self.loadError = (error as? AppError) ?? .internalError(module: "P6", detail: "load failed")
        Logger(subsystem: "kline.trainer", category: "settings").error(
            "loadSettings: blocked write (loadError set): \(String(describing: error), privacy: .public)")
    }
}

private static let zeroDefault = AppSettings(
    commissionRate: 0, minCommissionEnabled: false,
    totalCapital: 0, displayMode: .system)
```

**取舍说明**：
- "重启 app + 极端情况 Wave 2 显式 reset" 比 "silent 覆盖部分合法 keys" 安全
- spec init 签名无 throws，A'' 不破契约
- 后续 U4 SettingsPanel 加 `forceResetAndReload()` API（Wave 2 scope，本 PR 不做）
- 短期代价：dbCorrupted 用户不能改 settings；但 dbCorrupted 是极罕见事故（用户主动改 sqlite / DB 真损坏）；强制重启 + 后续重置比 silent data loss 好

**§6.3 R5 修订：snapshotFees 路径不能 silent 返 zero（codex R5-H1）**

spec L1981 签名：`func snapshotFees() -> FeeSnapshot` —— sync 无 throws，不能直接 throw 自报错误。

**问题**（codex R5-H1）：loadError 状态下 self.settings 是 zero-default，snapshotFees 返 `FeeSnapshot(commissionRate: 0, minCommissionEnabled: false)`，下游 trade calculator 会用 zero fee 算交易成本 → P&L 错。这个错误**看不到**（valid-looking FeeSnapshot），比 throw 还危险。

**修订方案**：
1. **暴露 public read-only `loadError`** —— `public var loadError: AppError? { _loadError }`（同名 alias 把私有 sentinel 露出）
2. **caller 契约**：E6/E5/U4 在调 snapshotFees 前必须先 guard `loadError == nil`，loadError 非 nil 时不能进入 trading flow（spec §11 Test Fixture / §15 acceptance 的 caller 文档加这条）
3. **snapshotFees 自身实现不变**（保 spec sync 签名）：返当前 settings 的 zero fees；caller 没 guard 是 caller bug
4. **defense-in-depth**（本 PR 加）：snapshotFees 内部 `if let e = _loadError { Logger(...).error("snapshotFees called while loadError set: \(e)") }` 但**不抛**——日志能让运维抓到 caller bug

**为什么不改 snapshotFees 签名**：
- 改 throws 等同打破 spec L1981 + PR #40 类壳契约（H-2 同类问题）
- E6 Coordinator (Wave 2) 调 snapshotFees 是 sync 路径（在 startNewNormalSession 内），改 throws 强制 E6 整链路 throws
- 暴露 loadError 作为 explicit gate 比 throws 更明确 + 更易 testable

**测试加**（Task 6）：
- snapshotFees_loadErrorSet_returnsZeroAndLogs：loadError 非 nil 时 snapshotFees 仍返 zero（不 throw），verify Logger 日志（用 mock OSLog 或 `@available` skip）
- loadError 公开 readable：assert `store.loadError == .persistence(.diskFull)` after init

**§6.2 update / resetCapital 异步实现（R1 重写：inflight Task 链串行化，防 H-3 数据丢失）**

`SettingsDAO.saveSettings(_:) throws` 和 `resetCapital() throws` 都是 sync。`SettingsStore.update(_:)` 是 `async throws`，`resetCapital()` 也是 `async throws`。

**R0 算法的 H-3 bug**（codex R1 抓的）：
```swift
// R0 (BUG)
public func update(_ mutate: ...) async throws {
    var copy = self.settings           // ← 读 settings @ MainActor T0
    mutate(&copy)
    try await Task.detached { ...saveSettings(snapshot)... }.value  // ← await，MainActor 释放
    // ↑ 在此 await 期间，另一 update / resetCapital 可以入场：读旧 settings、mutate、save、回写
    self.settings = snapshot           // ← 我恢复后 overwrite 别人的写入；并发更新丢失 ✗
}
```

`@MainActor` 是 cooperative，await 处会 yield；reentrant 入场是 well-defined Swift 行为，不算 race，但 LWW（last-writer-wins）语义对"互不冲突字段的并发 update"是数据丢失。

**R1 算法（inflight Task 链串行化）：**

```swift
private var pendingMutations: Task<Void, Error>?

public func update(_ mutate: @escaping @Sendable (inout AppSettings) -> Void) async throws {
    let prev = pendingMutations  // 捕获前一个 in-flight（如有）
    let task = Task { [weak self, mutate] in
        _ = try? await prev?.value  // 等前一个完成（错误不级联）
        guard let self = self else { return }
        // 此处 self 是 MainActor isolated，read settings 拿到 prev 写完的 freshest 值
        var copy = self.settings
        mutate(&copy)
        let snapshot = copy
        let dao = self.settingsDAO
        try await Task.detached(priority: .userInitiated) {
            try dao.saveSettings(snapshot)
        }.value
        self.settings = snapshot  // 写成功后回 MainActor 更新
    }
    pendingMutations = task
    try await task.value
}
```

**关键点**：
- 每个 update 调用都创建一个 Task，其内部第一行就 `await prev?.value` 让自己排在上一个 task 后面
- `pendingMutations = task` 让下一个 update 调用能把 `task` 当作它的 prev，形成单链队列
- chain 内部读 settings 在 prev 完成后 → 拿到最新值；mutate 应用在最新值上 → 不丢前面 update 的字段修改 ✓
- 错误用 `try?` 接住 prev 的异常（前一个失败不阻塞下一个；前一个写失败时本地 settings 也不会被更新，所以下一个 read 还是写失败前的值，行为对）
- weak self 防 SettingsStore deinit 后 task 泄漏

**resetCapital 同模式**：

```swift
public func resetCapital() async throws {
    let prev = pendingMutations
    let task = Task { [weak self] in
        _ = try? await prev?.value
        guard let self = self else { return }
        let dao = self.settingsDAO
        try await Task.detached(priority: .userInitiated) {
            try dao.resetCapital()
        }.value
        self.settings.totalCapital = 0
    }
    pendingMutations = task
    try await task.value
}
```

**测试**（Task 6 增加）：
- 并发触发 2 个 update（一个改 commissionRate，一个改 totalCapital）→ 两个字段都应在 dao.saveSettings 最后一次调用中 visible
- 并发触发 update + resetCapital → resetCapital 不应被 update 的旧 totalCapital overwrite

**snapshotFees() 实现**（R5 H-1 修订）：直接读 `self.settings.commissionRate` + `minCommissionEnabled` 构造 `FeeSnapshot`——纯读 MainActor 字段，无 IO，无需 async（spec L1981 签名就是 sync）。PR #40 类壳基本写对，本 PR 加 1 行 defense-in-depth log（loadError 非 nil 时记录 caller 没 guard 的 misuse；不抛、不改返回值，详 §6.3）：

```swift
public func snapshotFees() -> FeeSnapshot {
    if let e = _loadError {
        // R5 H-1 defense-in-depth: caller 应 guard loadError；这里仅 log 不抛
        Logger(subsystem: "kline.trainer", category: "settings").error(
            "snapshotFees called while loadError set (caller bug): \(String(describing: e), privacy: .public)")
    }
    return FeeSnapshot(
        commissionRate: settings.commissionRate,
        minCommissionEnabled: settings.minCommissionEnabled)
}

// R6 H-1 partial fix: additive API，让 trading-flow caller 用 enforced 路径
// snapshotFees 保持 spec L1981 sync 签名不动；新加 throws variant 强制 caller 处理 loadError
// E5/E6 (Wave 2) trading 入口应用 snapshotFeesIfReady()，普通 UI 显示用 snapshotFees()
public func snapshotFeesIfReady() throws -> FeeSnapshot {
    if let e = _loadError { throw e }
    return snapshotFees()
}
```

### §7 测试 isolation

P5 测试用 `FileManager.default.temporaryDirectory.appendingPathComponent("CacheTest-\(UUID())")` 作 cache root（不是 prod 的 Application Support，避免污染 simulator）。每个测试 setUp 创建 + tearDown 删除。

P6 测试用 `StubSettingsDAO`（注入返回值 + throws），不依赖 GRDB。

**为什么不用 in-process app.sqlite + DefaultAppDB**：单元测试 scope 应隔离。P5 测试不需要 sqlite，P6 测试用 stub 比真 GRDB 快百倍且无 fixture 依赖。

### §8 trust-boundary 影响评估（R5 修订：明示签名增强）

| 文件 | trust-boundary? | 评估 |
|---|---|---|
| `Settings/SettingsStore.swift` | ✅ `ios/**/*.swift` 在 globs 内 | 改 init/update/resetCapital body **+ 2 处签名增强**（详 §8.1）|
| `DefaultFileSystemCacheManager.swift` | ✅ 同上 | 新文件 = 新 public class；CacheManager 协议在 PR #40，本 PR 实现一个 conformer，无新公共 API surface |
| `Internal/CacheErrorMapping.swift` | ✅ 同上 | `internal` 范围，不暴露 |
| `*Tests.swift` | ✅ `tests/**` 在 globs 内 | 测试新增，不破坏既有 |
| `docs/acceptance/...md` | ✅ `docs/**` 在 globs 内 | 验收清单，doc-only |

**§8.1 签名增强清单（R5 H-2 修订：诚实暴露，不再藏在注释里）**

PR #40 SettingsStore 类壳是 fatalError 占位，**没有任何 production caller**。本 PR 落地生产实现时不可避免引入 2 处 strict-concurrency 必需的签名增强：

1. **`update(_ mutate:)` 加 `@escaping @Sendable`**（原：`(inout AppSettings) -> Void`；新：`@escaping @Sendable (inout AppSettings) -> Void`）
   - **原因**：序列化并发 update 必须把 mutate 推到 inflight Task chain 跨 await；Swift 6 strict concurrency 要求 Task 闭包 sendable context 内捕获 sendable 闭包
   - **替代方案评估（codex R5 推荐"redesign 不捕获 closure"）**：
     - **A. mutate 同步 apply on MainActor + 只序列化 save** —— 拒：concurrent updates 都从 baseline 读 → mutate 之间互相覆盖（同 H-3 数据丢失模式）
     - **B. actor SaveSerializer + optimistic settings 更新 + 失败 revert** —— 拒：revert 在 concurrent 场景 overwrite 后续 update 仍丢；新引入 actor reentrance 复杂度
     - **C. @escaping @Sendable 闭包捕获**（本 PR 选）—— 接受：caller 写纯 mutate（如 `s.commissionRate = 0.0001`）天然 Sendable；Swift 6 编译可强制 caller 不传含非 Sendable 捕获的闭包
   - **caller 影响**：PR #40 类壳无 caller；首批 caller 是 Wave 2 U4 SettingsPanel + E6 Coordinator，本 PR 落契约后他们按 @Sendable 写即可；无 binary 兼容问题

2. **`loadError: AppError?` 公开 read-only 属性**（PR #40 类壳无此属性；新增 public getter）
   - **原因**：R5 H-1，snapshotFees 不能改签名 throw，必须暴露 loadError 让 caller guard
   - **caller 影响**：新增 read-only API，不破坏既有，是 strictly additive

3. **`snapshotFeesIfReady() throws -> FeeSnapshot`**（R6 H-1 部分修；新增 throws variant）
   - **原因**：R6 H-1 codex 不接受 "log + 公开 loadError" 作为 enforcement，要求 fail-closed API
   - **方案选择**：spec L1981 `snapshotFees -> FeeSnapshot` 不能改 sync→throws（破 spec），故新增 additive `snapshotFeesIfReady() throws`；trading flow caller (Wave 2 E5/E6) 用此变体；snapshotFees 保留给 UI 显示路径
   - **caller 影响**：strictly additive，不破坏既有

**为什么这 3 处不属"破坏 trust-boundary"**：
- 全部 strictly additive 或 strict-concurrency 必需的强化，**没有任何旧 API 被删除或语义改变**
- PR #40 SettingsStore 类壳明示 "Wave 2 P6 PR 改为 init 内调用 settingsDAO.loadSettings() 实际加载"，本 PR 就是那个落地 PR；signature 强化是落地不可避免的副产品
- codex review 链路本身就是 trust-boundary check，本 PR 全程经 ≥6 轮 codex review，每轮显式列签名变化

**§8.2 R6 reject residual（接受未修）**

**R6-M3：codex 重申 update @Sendable 签名 source-breaking，建议改用 actor / async lock + nonescaping mutate**

- 这是 R5-H2 的复述（codex R5 已提，我已在 §8.1 列拒方案 A/B 理由）
- 进一步分析 codex R6 推荐的 actor-based 替代方案：
  - 设 `private actor SaveLock`，`update` 内 mutate 同步 apply on MainActor (no escaping) + optimistic settings 写 + saveLock.withLock save + revert on fail
  - **数据一致性反例**：concurrent update1 + update2，update1 save fail 时，settings 已被 update2 optimistic 覆盖；revert 把 update2 的写入也回滚 → in-memory s0 / DB s12 inconsistency
  - revert 要"基于 prevSnapshot 但只回退自己的写"是 not-trivially-feasible（需要 diff 而非 swap，OS-level 单 atomic snapshot 不存在）
- 本 PR 选 @Sendable closure 捕获是 **correctness-required**；codex R6 推荐方案在并发场景反而引入更严重的 in-memory/DB 不一致
- per `feedback_codex_round6_self_contradiction` rule（≥6 轮命中复述模式 → REJECT 不修）+ `feedback_codex_plan_budget_overshoot` rule（5 轮必 escalate）
- **REJECT 接受 residual**：update 签名加 `@escaping @Sendable`；caller 影响详见 §8.1 第 1 项；user 已 acknowledge

**结论**：本 PR 引入 3 处 SettingsStore 签名增强（additive `loadError` getter + additive `snapshotFeesIfReady` + strengthening `@escaping @Sendable` on `update`）；CacheManager 协议**完全冻结**（不动）。这 3 处增强已在 codex R5+R6 留痕认知；R6-M3 reject 接受 residual 并入 PR description 提示 reviewer。

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
        // R6 M-2: src 用 copy，不被 move 走；caller 自己负责清 src
        #expect(FileManager.default.fileExists(atPath: src.path), "src 应保留（caller retry-safe）")
        #expect(result.lastAccessedAt > 0)
        #expect(result.downloadedAt > 0)
    }

    // R6 M-2 regression: store fail 后 src 仍可用于 retry
    @Test("store: PRAGMA validation fail 后 src 仍存在，可 retry")
    func store_validationFail_srcRemainsForRetry() throws {
        let root = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(root) }
        let cache = DefaultFileSystemCacheManager(cacheRoot: root)

        // src 不是合法 sqlite → PRAGMA 读 fail → store throws
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("bogus-\(UUID()).sqlite")
        try Data("not sqlite".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        #expect(throws: AppError.persistence(.dbCorrupted)) {
            try cache.store(downloadedZip: bogus, meta: CacheFixture.meta(id: 1, filename: "x.sqlite"))
        }
        // src 必须仍在（caller 可换 fixture 重试 or report）
        #expect(FileManager.default.fileExists(atPath: bogus.path),
                "src 不应因 store fail 被消耗")
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

    /// R5 M-3: lazy 一次性清残留 .staging-* 文件（前次 process kill 留下的 orphan）
    /// 由 store 首次调用触发；不影响 listAvailable / pickRandom 性能（它们也调）
    /// 用 NSLock 而非 queue.sync 因 caller 已在 queue.sync 内（递归 deadlock）
    private var cleanStaleStagingDone = false

    public func listAvailable() -> [TrainingSetFile] {
        queue.sync { listAvailableLocked() }
    }

    public func pickRandom() -> TrainingSetFile? {
        queue.sync { listAvailableLocked().randomElement() }
    }

    public func store(downloadedZip src: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile {
        try queue.sync {
            try ensureCacheRootExists()
            // R5 M-3: 清前一次 store 进程崩溃残留的 .staging-* 文件（防 orphan 绕过 LRU cap）
            // 一次性 lazy（cleanStaleStagingDone flag）；首次 store 触发，零 overhead 后续 store
            cleanStaleStagingIfNeededLocked()
            // R3 H-2: 验证 meta.filename 不带 path 分隔符 / traversal / 空 / staging 前缀
            try validateFilename(meta.filename)
            let target = try cacheURL(forId: meta.id, filename: meta.filename)
            let staging = cacheRoot.appendingPathComponent(".staging-\(UUID().uuidString)__\(meta.id)__\(meta.filename)")

            // R1 H-1 fix: stage → validate → atomic replace；任意失败均不动 target
            try stageFile(from: src, to: staging)
            var stagingCleanupNeeded = true
            defer {
                if stagingCleanupNeeded {
                    // best-effort 清理 staging（验证失败 / replace 失败时）
                    try? FileManager.default.removeItem(at: staging)
                }
            }

            // R1 H-2 fix: 立即 touch staging，让新 store 的项 mtime = now，evict 不会立刻挑中
            try touchFile(staging)

            // R1 H-1 fix: 验证 sqlite 可读 + 拿 schemaVersion；失败 → throw + defer 清 staging，target 不动
            let schemaVersion = try readSchemaVersion(staging)

            // atomic replace（POSIX rename(2) 在同目录 APFS 上原子）
            try replaceFile(at: target, with: staging)
            stagingCleanupNeeded = false  // staging 已被 replace 走 / swap 走

            let attrs = try fileAttributes(target)
            evictIfNeededLocked()
            return TrainingSetFile(
                id: meta.id,
                filename: meta.filename,
                localURL: target,
                schemaVersion: schemaVersion,
                lastAccessedAt: attrs.mtime,
                downloadedAt: attrs.ctime)
        }
    }

    public func touch(_ file: TrainingSetFile) {
        queue.sync {
            // R3 H-2: 不信任 caller 传的 file.localURL；从 id+filename 内部重新派生 cache 内 path
            // 防止 caller 把 localURL 指到 app.sqlite / 其它 app 数据被误 touch
            guard let url = try? cacheURL(forId: file.id, filename: file.filename) else { return }
            // best-effort：失败不抛（spec hint：协议签名无 throws）
            try? touchFile(url)
        }
    }

    public func delete(_ file: TrainingSetFile) throws {
        try queue.sync {
            // R3 H-2: 同上，从 id+filename 重新派生；防 caller localURL 引导删 cache 外文件
            let url = try cacheURL(forId: file.id, filename: file.filename)
            try removeFile(url)
        }
    }

    // MARK: - Internal helpers (all FileManager / DatabaseQueue I/O wrapped here)
    // M-4 gate 强制：public 方法零 raw `try FileManager.` / `try DatabaseQueue`，全部走以下 helpers。

    /// R5 M-3: 清前次 process kill 残留的 `.staging-*` 文件。
    /// 调用时机：store 首次进 queue.sync 时（lazy）；listAvailable 是 read，不触发 cleanup。
    /// caller 已在 queue.sync 内，本函数不再额外 lock。
    private func cleanStaleStagingIfNeededLocked() {
        if cleanStaleStagingDone { return }
        cleanStaleStagingDone = true
        // 用 includingPropertiesForKeys=nil + producesRelativePathURLs=false 列出全部
        // 注意：包含 hidden（不传 .skipsHiddenFiles）
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: nil, options: [])) ?? []
        for entry in entries {
            let basename = entry.deletingPathExtension().lastPathComponent
            if basename.hasPrefix(".staging-") {
                do {
                    try removeFile(entry)
                    log.info("removed stale staging: \(entry.lastPathComponent, privacy: .public)")
                } catch {
                    log.error("failed to remove stale staging \(entry.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

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

    /// R3 H-2 + R4 H-2: 验证 caller-supplied filename
    /// - 拒 path traversal（/ \ ..）/ staging 前缀冲突 / 空
    /// - 必须以 ".sqlite"（小写）结尾——否则 listAvailable 按 .sqlite 过滤会让该文件孤儿绕过 LRU cap
    private func validateFilename(_ filename: String) throws {
        if filename.isEmpty
            || filename.contains("/")
            || filename.contains("\\")
            || filename.contains("..")
            || filename.contains("\0")  // R4 defense-in-depth: NULL byte
            || filename.hasPrefix(".staging-")
            || !filename.lowercased().hasSuffix(".sqlite") {
            throw AppError.internalError(module: "P5-cache",
                detail: "invalid filename rejected by cache boundary")
        }
    }

    /// R3 H-2: cache 内 URL 的唯一构造路径；调用方禁止直接拼 cacheRoot.appendingPathComponent
    /// 派生后用 standardizedFileURL.path.hasPrefix 兜底 cacheRoot 内
    private func cacheURL(forId id: Int, filename: String) throws -> URL {
        try validateFilename(filename)
        let candidate = cacheRoot.appendingPathComponent("\(id)__\(filename)")
        // defense-in-depth：standardize 后必须 still under cacheRoot
        let stdCand = candidate.standardizedFileURL.path
        let stdRoot = cacheRoot.standardizedFileURL.path
        guard stdCand.hasPrefix(stdRoot + "/") else {
            throw AppError.internalError(module: "P5-cache",
                detail: "derived cache URL escaped cacheRoot")
        }
        return candidate
    }

    /// R6 M-2 fix: 用 copy 而非 move——src 保留给 caller retry（validation/replace 失败时 src 不丢）
    /// 代价：store 窗口内 ~MB 临时双倍磁盘；store 成功后 caller 应清自己的 src（来自 ZipExtractor 的 tmp）
    private func stageFile(from src: URL, to staging: URL) throws {
        do {
            try FileManager.default.copyItem(at: src, to: staging)
        } catch {
            throw CacheErrorMapping.translate(error)
        }
    }

    private func touchFile(_ url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path)
        } catch {
            throw CacheErrorMapping.translate(error)
        }
    }

    private func replaceFile(at target: URL, with staging: URL) throws {
        // R2 H-1 fix: replaceItemAt 是 "safe-save" API，文档假定 target 已存在；首次 store
        // 走 replaceItemAt 会 throw "file doesn't exist"。分支：
        //   target 存在 → replaceItemAt（atomic swap）
        //   target 不存在 → moveItem（atomic rename(2)）
        // 在 queue.sync 串行段内，fileExists/replaceItemAt 之间无竞态。
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
        } catch {
            throw CacheErrorMapping.translate(error)
        }
    }

    private func removeFile(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CacheErrorMapping.translate(error)
        }
    }

    // MARK: - Internal listing (locked = caller already in queue.sync)

    private func listAvailableLocked() -> [TrainingSetFile] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: cacheRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles])
        } catch {
            // listAvailable 协议签名非 throws；目录不存在 / 不可读 → 返空
            return []
        }
        // R2 H-2 fix: 内部 sort 用 Date（APFS 纳秒精度）+ tiebreaker（ctime Date / basename），
        // 防 rapid same-second stores 同 mtime 时 LRU 顺序不稳定 → 误 evict 新存的。
        // public TrainingSetFile.lastAccessedAt 仍 Int64 秒（struct 契约不变）。
        struct CacheEntry { let file: TrainingSetFile; let mtimeDate: Date; let ctimeDate: Date; let basename: String }
        var staged: [CacheEntry] = []
        for entry in entries {
            guard entry.pathExtension.lowercased() == "sqlite" else { continue }
            let basename = entry.deletingPathExtension().lastPathComponent
            if basename.hasPrefix(".staging-") { continue }  // skip in-flight staging
            let parts = basename.components(separatedBy: "__")
            guard parts.count >= 2, let id = Int(parts[0]) else { continue }
            let filename = parts.dropFirst().joined(separator: "__") + ".sqlite"
            guard let dates = try? fileDateAttributes(entry),
                  let schemaVersion = try? readSchemaVersion(entry) else { continue }
            let file = TrainingSetFile(
                id: id, filename: filename, localURL: entry,
                schemaVersion: schemaVersion,
                lastAccessedAt: Int64(dates.mtime.timeIntervalSince1970),
                downloadedAt: Int64(dates.ctime.timeIntervalSince1970))
            staged.append(CacheEntry(file: file, mtimeDate: dates.mtime, ctimeDate: dates.ctime, basename: basename))
        }
        staged.sort { lhs, rhs in
            if lhs.mtimeDate != rhs.mtimeDate { return lhs.mtimeDate > rhs.mtimeDate }
            if lhs.ctimeDate != rhs.ctimeDate { return lhs.ctimeDate > rhs.ctimeDate }
            return lhs.basename > rhs.basename
        }
        return staged.map { $0.file }
    }

    private func evictIfNeededLocked() {
        let all = listAvailableLocked()
        guard all.count > Self.maxCachedSets else { return }
        let toEvict = all.suffix(all.count - Self.maxCachedSets)
        for f in toEvict {
            do {
                try removeFile(f.localURL)
            } catch {
                log.error("cache evict failed for \(f.localURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func fileAttributes(_ url: URL) throws -> (mtime: Int64, ctime: Int64) {
        let dates = try fileDateAttributes(url)
        return (Int64(dates.mtime.timeIntervalSince1970), Int64(dates.ctime.timeIntervalSince1970))
    }

    /// R2 H-2: 内部 sort 用的纳秒精度 Date（APFS preserves nanosecond mtime）。
    private func fileDateAttributes(_ url: URL) throws -> (mtime: Date, ctime: Date) {
        let raw: [FileAttributeKey: Any]
        do {
            raw = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw CacheErrorMapping.translate(error)
        }
        let mtime = (raw[.modificationDate] as? Date) ?? Date()
        let ctime = (raw[.creationDate] as? Date) ?? mtime
        return (mtime, ctime)
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

// R1 H-1 regression: 同 id 重新 store 的 src 损坏时，旧 cache 应保留
@Test("store: 已存在 id 的 src 损坏时旧 cache 不丢（rollback safe）")
func store_invalidNewSqlite_oldCachePreserved() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    let valid1 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    let f1 = try cache.store(downloadedZip: valid1, meta: CacheFixture.meta(id: 5, filename: "stk.sqlite"))
    #expect(FileManager.default.fileExists(atPath: f1.localURL.path))

    // 第二次 store 同 id 但 src 损坏
    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("bogus-\(UUID()).sqlite")
    try Data("not a sqlite".utf8).write(to: bogus)
    #expect(throws: AppError.persistence(.dbCorrupted)) {
        try cache.store(downloadedZip: bogus,
                        meta: CacheFixture.meta(id: 5, filename: "stk.sqlite"))
    }

    // 旧 cache 应仍在 + 仍可读
    #expect(FileManager.default.fileExists(atPath: f1.localURL.path), "旧 cache 文件应保留")
    let listed = cache.listAvailable()
    #expect(listed.count == 1)
    #expect(listed[0].id == 5)
    #expect(listed[0].schemaVersion == 1)

    // 不应有 staging 残留
    let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
    let stagingResidue = entries.filter { $0.hasPrefix(".staging-") }
    #expect(stagingResidue.isEmpty, "staging 文件应被 defer 清理：\(stagingResidue)")
}

// R1 H-2 regression: src 文件 mtime 老不影响 evict
@Test("store: src 文件 mtime 远古，store 后新 cache 不会被立刻 evict")
func store_oldMtimeSrc_doesNotEvictNewCache() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    // 准备 19 个 fresh cache
    for i in 1...19 {
        let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: i, filename: "f\(i).sqlite"))
    }

    // 第 20 个：src 的 mtime 设到 2000-01-01（远古）
    let oldSrc = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 946_684_800)],  // 2000-01-01
        ofItemAtPath: oldSrc.path)
    let f20 = try cache.store(downloadedZip: oldSrc, meta: CacheFixture.meta(id: 20, filename: "f20.sqlite"))

    // 第 21 个 → 应驱逐 mtime 最老的；id=20 因 store 时 touch 过，mtime=now，不应被驱逐
    let s21 = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    _ = try cache.store(downloadedZip: s21, meta: CacheFixture.meta(id: 21, filename: "f21.sqlite"))

    let after = cache.listAvailable()
    #expect(after.count == 20)
    #expect(after.contains { $0.id == 20 }, "id=20 不应因 src 老 mtime 被 evict")
    #expect(after.contains { $0.id == 21 })
    #expect(FileManager.default.fileExists(atPath: f20.localURL.path))
}

// R2 H-1 regression: 空 cache 首次 store 不应 throw（replaceItemAt 假定 target 存在）
@Test("store: 空 cache 首次 store 走 moveItem 路径 success（不走 replaceItemAt）")
func store_emptyCacheFirstStore_succeeds() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)
    // 确认 cache 是空的
    #expect(cache.listAvailable().isEmpty)

    let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    let r = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: 99, filename: "first.sqlite"))
    #expect(r.id == 99)
    #expect(FileManager.default.fileExists(atPath: r.localURL.path))
    #expect(cache.listAvailable().count == 1)
}

// R2 H-2 regression: 21 rapid same-second stores LRU 顺序稳定
@Test("store: 21 个连续 store（无 sleep，多数同秒）evict 应删 id=1（最早 store）")
func store_21RapidStores_evictsOldestStored() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    // 21 个连续 store，无 sleep。每次 setAttributes 调用 takes ~us，纳秒精度 mtime 差异化。
    for i in 1...21 {
        let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
        _ = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: i, filename: "r\(i).sqlite"))
    }

    let after = cache.listAvailable()
    #expect(after.count == 20)
    // id=21 必在（刚 store 的）
    #expect(after.contains { $0.id == 21 })
    // 按"最早 store 应最先被 evict"逻辑，id=1 应被删（21 个里 mtime/ctime 最旧）
    #expect(!after.contains { $0.id == 1 }, "首次 store 的 id=1 应被 evict")
}

// R3 H-2 + R4 H-2 regression: caller 传带 path traversal 或非 .sqlite 扩展的 filename → 拒收
@Test("store: filename 含 / .. \\ NULL / staging 前缀 / 非 .sqlite 扩展应拒")
func store_filenameValidationRejectsBadInputs() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)
    let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)

    let bad: [String] = [
        "../escape.sqlite",
        "sub/dir.sqlite",
        "with\\back.sqlite",
        "..",
        "",
        ".staging-stealth.sqlite",
        "with\u{0000}null.sqlite",
        // R4 H-2: 非 .sqlite 扩展应拒，否则 listAvailable 按 .sqlite 过滤 → 孤儿绕 LRU cap
        "foo.db",
        "noext",
        "trailingdot.sqlite.",
    ]
    for name in bad {
        #expect(throws: (any Error).self, "应拒 filename: \(name)") {
            try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: 1, filename: name))
        }
    }
}

// R3 H-2 regression: caller 给 file.localURL 指向 cache 外文件 → delete 不删该外部文件
@Test("delete: 不信任 file.localURL，从 id+filename 内部派生；外部文件不被删")
func delete_doesNotTrustLocalURL_externalFileSafe() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    // 在 cache 外创建一个 victim 文件
    let victim = FileManager.default.temporaryDirectory
        .appendingPathComponent("victim-\(UUID()).sqlite")
    try Data("important".utf8).write(to: victim)
    defer { try? FileManager.default.removeItem(at: victim) }

    // 构造一个 TrainingSetFile：id+filename 指向 cache 内一个不存在的项；localURL 指 victim
    let evil = TrainingSetFile(
        id: 999, filename: "ghost.sqlite",
        localURL: victim,  // ← caller 引导 cache 操作 victim
        schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)

    // delete 应基于 id+filename 派生 → 派生路径 = cacheRoot/999__ghost.sqlite，不存在 → fileNotFound
    #expect(throws: AppError.trainingSet(.fileNotFound)) {
        try cache.delete(evil)
    }
    // victim 必须仍在
    #expect(FileManager.default.fileExists(atPath: victim.path), "外部文件不应被 cache 操作影响")
}

// R5 M-3 regression: pre-existing .staging-* 文件被清，不绕 LRU cap
@Test("store: cache root 内残留 .staging-* 文件首次 store 时被清")
func store_firstCallCleansStaleStagingFiles() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    // 预 - 留 2 个残留 staging 文件
    let stale1 = root.appendingPathComponent(".staging-OLD1__99__leftover.sqlite")
    let stale2 = root.appendingPathComponent(".staging-OLD2__88__leftover.sqlite")
    try Data("dummy".utf8).write(to: stale1)
    try Data("dummy".utf8).write(to: stale2)
    #expect(FileManager.default.fileExists(atPath: stale1.path))
    #expect(FileManager.default.fileExists(atPath: stale2.path))

    let cache = DefaultFileSystemCacheManager(cacheRoot: root)
    // 触发 cleanup（首次 store 进 queue.sync 内调）
    let s = try CacheFixture.makeValidSqlite(schemaVersion: 1)
    _ = try cache.store(downloadedZip: s, meta: CacheFixture.meta(id: 7, filename: "x.sqlite"))

    // 残留 staging 应被清
    #expect(!FileManager.default.fileExists(atPath: stale1.path), "stale1 应被清")
    #expect(!FileManager.default.fileExists(atPath: stale2.path), "stale2 应被清")
    // 当前 store 的 cache 应在
    #expect(cache.listAvailable().count == 1)
}

// R3 H-2 regression: touch 同样不信任 localURL
@Test("touch: 不信任 file.localURL，外部文件 mtime 不变")
func touch_doesNotTrustLocalURL_externalFileMtimeUnchanged() throws {
    let root = CacheFixture.makeTempCacheRoot()
    defer { CacheFixture.cleanup(root) }
    let cache = DefaultFileSystemCacheManager(cacheRoot: root)

    let victim = FileManager.default.temporaryDirectory
        .appendingPathComponent("victim-\(UUID()).sqlite")
    try Data("important".utf8).write(to: victim)
    defer { try? FileManager.default.removeItem(at: victim) }
    // 设 victim mtime = 2000-01-01
    let oldDate = Date(timeIntervalSince1970: 946_684_800)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: victim.path)

    let evil = TrainingSetFile(
        id: 1234, filename: "fake.sqlite", localURL: victim,
        schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)
    cache.touch(evil)  // best-effort，不抛；内部派生路径不存在 → no-op

    // victim mtime 必须仍为 2000-01-01
    let attrs = try FileManager.default.attributesOfItem(atPath: victim.path)
    let actualMtime = (attrs[.modificationDate] as? Date) ?? Date()
    #expect(abs(actualMtime.timeIntervalSince1970 - oldDate.timeIntervalSince1970) < 1,
            "外部文件 mtime 不应被 cache.touch 影响")
}
```

- [ ] **Step 4.2: 写 AppError gate script（R1 强化 M-4 finding）**

```bash
# scripts/check_p5_apperror_gate.sh
#!/usr/bin/env bash
# 验证 DefaultFileSystemCacheManager 不裸抛非 AppError 错误（M0.4 trust-boundary gate）
# R1 强化 (codex M-4)：增 2 条规则
#   规则 1（PR4a 套路）：所有 throw 必须 throw AppError.* 或 throw CacheErrorMapping.translate(...)
#   规则 2：public 方法体内禁止 raw `try FileManager.` / `try DatabaseQueue` —— 必须走 helper
#   规则 3：所有含 raw try FileManager / try DatabaseQueue 的 private helper 内必须有 do/catch + CacheErrorMapping.translate
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/ios/Contracts/Sources/KlineTrainerPersistence/DefaultFileSystemCacheManager.swift"
if [[ ! -f "$F" ]]; then
  echo "FAIL: $F 不存在"
  exit 1
fi

FAIL=0

# === 规则 1：throw 走 AppError 边界 ===
# 剔除注释行；抓所有 throw 行；排除 throw AppError / throw CacheErrorMapping.translate
BAD_THROW=$(grep -vE '^\s*//' "$F" | grep -nE '^\s*throw\s+' \
  | grep -vE 'throw\s+AppError\.' \
  | grep -vE 'throw\s+CacheErrorMapping\.translate' \
  | grep -vE 'throw\s+error\b' \
  || true)
if [[ -n "$BAD_THROW" ]]; then
  echo "FAIL[规则1]: 含未走 AppError 边界的 throw："
  echo "$BAD_THROW"
  FAIL=1
fi

# === 规则 2：public 方法体内禁 raw try FileManager / try DatabaseQueue ===
# 用 awk 跟踪 public func 块的开闭：检测到 `public func` 进入 public 区，遇到顶层 `}` 退出
# 简化：CacheManager protocol surface 的 5 个 public 方法是 store/touch/delete/listAvailable/pickRandom + init
# 若这 5 个方法体内出现 `try FileManager` / `try DatabaseQueue` / `try q.read` 即 fail
PUBLIC_BAD=$(awk '
  /^    public (func|init)/ { in_pub = 1; depth = 0; method = $0; next }
  in_pub == 1 && /\{/ { depth += gsub(/\{/, "{") }
  in_pub == 1 && /\}/ { depth -= gsub(/\}/, "}"); if (depth <= 0) { in_pub = 0; depth = 0 } }
  in_pub == 1 && /try FileManager\.|try DatabaseQueue|try q\.read|try [a-z][a-zA-Z0-9_]*\.read[ {]/ {
    print FILENAME ":" NR ": " $0 " (in public method: " method ")"
  }
' "$F")
if [[ -n "$PUBLIC_BAD" ]]; then
  echo "FAIL[规则2]: public 方法体内含 raw try FileManager / try DatabaseQueue（应走 private helper）："
  echo "$PUBLIC_BAD"
  FAIL=1
fi

# === 规则 3：含 raw try FileManager / try DatabaseQueue 的行附近必有 CacheErrorMapping.translate ===
# 简化检查：每行 raw try 后 ±10 行内必出现 "CacheErrorMapping.translate" 或本行就在 catch block 里
RAW_TRY_LINES=$(grep -nE 'try FileManager\.|try DatabaseQueue|try q\.read' "$F" | grep -v '^\s*//' | cut -d: -f1)
for ln in $RAW_TRY_LINES; do
  start=$((ln > 10 ? ln - 10 : 1))
  end=$((ln + 10))
  block=$(sed -n "${start},${end}p" "$F")
  if ! echo "$block" | grep -qE 'CacheErrorMapping\.translate'; then
    echo "FAIL[规则3]: 行 $ln 的 raw try 附近 ±10 行无 CacheErrorMapping.translate："
    sed -n "${ln}p" "$F"
    FAIL=1
  fi
done

if [[ $FAIL -eq 0 ]]; then
  echo "OK: P5 DefaultFileSystemCacheManager 全部 throw 走 AppError 边界 + public 方法零 raw try"
fi
exit $FAIL
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

    // R4 H-1 regression: dbCorrupted 也阻塞写（防 silent 覆盖部分合法 keys）
    @Test("init: dbCorrupted 后 update 抛 dbCorrupted 阻塞，不持久化 zero")
    func init_dbCorrupted_updateBlocked() async throws {
        let dbErr = AppError.persistence(.dbCorrupted)
        let dao = StubSettingsDAO(load: .failure(dbErr))
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: dbErr) {
            try await store.update { s in s.commissionRate = 0.0007 }
        }
        // dao.saveSettings 不应被调
        #expect(dao.savedSettings == nil)
    }

    // R2 H-3 regression: transient I/O 错误后 update 必须 throw 不能 silent 覆盖
    @Test("init: dao throws .ioError → update 抛同 error 阻塞写")
    func init_daoThrowsIOError_updateThrowsLoadError() async throws {
        let ioErr = AppError.persistence(.ioError("transient_lock"))
        let dao = StubSettingsDAO(load: .failure(ioErr))
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: ioErr) {
            try await store.update { s in s.commissionRate = 0.0009 }
        }
        // dao.saveSettings 不应被调
        #expect(dao.savedSettings == nil)
    }

    @Test("init: dao throws .diskFull → resetCapital 抛同 error 阻塞写")
    func init_daoThrowsDiskFull_resetCapitalThrowsLoadError() async throws {
        let dfErr = AppError.persistence(.diskFull)
        let dao = StubSettingsDAO(load: .failure(dfErr))
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: dfErr) {
            try await store.resetCapital()
        }
        #expect(!dao.resetCalled)
    }
}
```

- [ ] **Step 5.3: 跑测试确认 fail（既有 stub init 用 zero-default 不调 dao）**

Run: `cd '/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings' && swift test --package-path ios/Contracts --filter SettingsStoreProductionTests 2>&1 | tail -8`
Expected: `init_loadsSettingsFromDAO` fail（settings 是 zero 不是 want）

- [ ] **Step 5.4: 改 SettingsStore.init 实现 eager-load（R2 H-3 + R3 H-1：与 §6.1 设计同步）**

`SettingsStore.swift` 改动：
1. 加 `private var loadError: AppError?` 成员
2. 加 `private static let zeroDefault = AppSettings(...)` 常量
3. init 区分 `.dbCorrupted`（zero+允许写）vs 其它（zero+保 loadError 阻塞写）
4. 加 import `import os.log`

```swift
import os.log
// ...

@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: AppSettings

    private let settingsDAO: SettingsDAO
    private var pendingMutations: Task<Void, Error>?
    /// R2 H-3 + R3 H-1 + R4 H-1：所有 load 失败（含 dbCorrupted）都阻塞写。
    /// R5 H-1：暴露为 public read-only，让 caller (E6/E5) 在调 snapshotFees / 进 trade flow 前 guard。
    private var _loadError: AppError?
    public var loadError: AppError? { _loadError }

    private static let zeroDefault = AppSettings(
        commissionRate: 0, minCommissionEnabled: false,
        totalCapital: 0, displayMode: .system)

    public init(settingsDAO: SettingsDAO) {
        self.settingsDAO = settingsDAO
        do {
            self.settings = try settingsDAO.loadSettings()
        } catch {
            // R4 H-1: 任何错误（含 dbCorrupted）都设 loadError 阻塞写
            // SettingsDAO 是 key-value，dbCorrupted 可能伴随部分合法 keys；conservative 阻塞防 silent 覆盖
            // 用户恢复路径：重启 app 重新 load；极端情况靠 Wave 2 U4 显式 reset 按钮（本 PR 不做）
            self.settings = SettingsStore.zeroDefault
            self._loadError = (error as? AppError)
                ?? .internalError(module: "P6", detail: String(describing: error))
            Logger(subsystem: "kline.trainer", category: "settings").error(
                "loadSettings: blocked write (loadError set): \(String(describing: error), privacy: .public)")
        }
    }

    // ... update/resetCapital 见 Step 6.2（已含 if let e = loadError { throw e } 早返）
}
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
    #expect(store.settings.commissionRate == 0.0001)
    #expect(store.settings.minCommissionEnabled == true)
    #expect(store.settings.displayMode == .dark)
}

// R1 H-3 regression: 并发 update 不丢字段
@Test("concurrent update: 并发改不同字段，最终 dao 写入和本地都包含两次修改")
func concurrentUpdate_differentFields_neitherLost() async throws {
    let initial = AppSettings(
        commissionRate: 0, minCommissionEnabled: false,
        totalCapital: 0, displayMode: .system)
    let dao = StubSettingsDAO(load: .success(initial))
    let store = SettingsStore(settingsDAO: dao)

    async let a: Void = store.update { s in s.commissionRate = 0.0005 }
    async let b: Void = store.update { s in s.totalCapital = 77_777 }
    _ = try await (a, b)

    // 两个字段都应保留（chain 串行 + 后写包含前写）
    #expect(store.settings.commissionRate == 0.0005)
    #expect(store.settings.totalCapital == 77_777)
    // dao 最后一次写入也应同时含两个字段
    #expect(dao.savedSettings?.commissionRate == 0.0005)
    #expect(dao.savedSettings?.totalCapital == 77_777)
}

// R5 H-1 regression: snapshotFees 在 loadError 状态下返 zero（不 throw 不 crash），caller 可读 loadError guard
@Test("snapshotFees: loadError 非 nil 时返 zero fees + loadError 公开 readable")
func snapshotFees_loadErrorState_returnsZeroAndExposesLoadError() async throws {
    let dfErr = AppError.persistence(.diskFull)
    let dao = StubSettingsDAO(load: .failure(dfErr))
    let store = SettingsStore(settingsDAO: dao)

    // R5 H-1 contract: caller MUST guard via loadError before snapshotFees
    #expect(store.loadError == dfErr)

    // snapshotFees 不阻塞不抛；返当前 settings (zero-default) 的 fees
    let fees = store.snapshotFees()
    #expect(fees.commissionRate == 0)
    #expect(fees.minCommissionEnabled == false)

    // loadError 状态下 update / resetCapital 仍阻塞（同 H-3 测试已验）
}

// R6 H-1 partial regression: snapshotFeesIfReady throws on loadError
@Test("snapshotFeesIfReady: loadError 时 throws；happy 时返正常 fees")
func snapshotFeesIfReady_throwsOnLoadError_returnsFeesOnHappy() async throws {
    let dfErr = AppError.persistence(.diskFull)
    let failDao = StubSettingsDAO(load: .failure(dfErr))
    let failStore = SettingsStore(settingsDAO: failDao)
    #expect(throws: dfErr) {
        try failStore.snapshotFeesIfReady()
    }

    let goodSettings = AppSettings(
        commissionRate: 0.0001, minCommissionEnabled: true,
        totalCapital: 1000, displayMode: .dark)
    let goodDao = StubSettingsDAO(load: .success(goodSettings))
    let goodStore = SettingsStore(settingsDAO: goodDao)
    let fees = try goodStore.snapshotFeesIfReady()
    #expect(fees.commissionRate == 0.0001)
    #expect(fees.minCommissionEnabled == true)
}

// R1 H-3 regression: 并发 update + resetCapital
@Test("concurrent update+reset: reset 不被 update 旧 totalCapital overwrite")
func concurrentUpdate_andReset_resetWins() async throws {
    let initial = AppSettings(
        commissionRate: 0.0001, minCommissionEnabled: false,
        totalCapital: 50_000, displayMode: .system)
    let dao = StubSettingsDAO(load: .success(initial))
    let store = SettingsStore(settingsDAO: dao)

    async let a: Void = store.update { s in s.commissionRate = 0.0009 }
    async let b: Void = store.resetCapital()
    _ = try await (a, b)

    // commissionRate 修改应保留；totalCapital 必为 0（resetCapital 是后排还是前排都行，串行结果稳定）
    #expect(store.settings.totalCapital == 0)
    #expect(store.settings.commissionRate == 0.0009)
}
```

- [ ] **Step 6.2: 改 SettingsStore.update / resetCapital 实做（R1 串行化版）**

`SettingsStore.swift` 加成员 `private var pendingMutations: Task<Void, Error>?`，update 和 resetCapital 实现替换为：

```swift
public func update(_ mutate: @escaping @Sendable (inout AppSettings) -> Void) async throws {
    if let e = _loadError { throw e }  // R2 H-3 + R4 H-1: block writes 直到 reload 成功
    let prev = pendingMutations
    let task = Task { [weak self, mutate] in
        _ = try? await prev?.value  // 等前一个完成（错误不级联）
        guard let self = self else { return }
        var copy = self.settings
        mutate(&copy)
        let snapshot = copy
        let dao = self.settingsDAO
        try await Task.detached(priority: .userInitiated) {
            try dao.saveSettings(snapshot)
        }.value
        self.settings = snapshot
    }
    pendingMutations = task
    try await task.value
}

public func resetCapital() async throws {
    if let e = _loadError { throw e }  // R2 H-3 + R4 H-1: block writes 直到 reload 成功
    let prev = pendingMutations
    let task = Task { [weak self] in
        _ = try? await prev?.value
        guard let self = self else { return }
        let dao = self.settingsDAO
        try await Task.detached(priority: .userInitiated) {
            try dao.resetCapital()
        }.value
        self.settings.totalCapital = 0
    }
    pendingMutations = task
    try await task.value
}
```

注：`update` 签名加 `@escaping @Sendable` —— closure 被 Task 捕获跨 await + Swift 6 strict concurrency 要求 Task 操作闭包是 Sendable context；不加 `@Sendable` 编译 fail（codex R4 H-3）。既有 PR #40 类壳是 fatalError 不需要 escaping/Sendable。本 PR 改签名 = behavior-only 强化（PR #40 还无 production caller），无 binary contract 影响。caller 传纯 mutate（如 `s.commissionRate = 0.0001`）天然满足 @Sendable。

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
  - P5 临时文件 + atomic rename（spec L687）→ Task 1 store impl 用 stage→replaceItemAt ✓
  - P5 串行队列防并发同 path（spec L692）→ Task 1 + Task 3 并发测试 ✓
  - P6 init(settingsDAO:) + 4 方法（spec L1979-1982）→ Task 5-6 ✓
  - P6 @MainActor @Observable（spec L1973-1975）→ 既有 PR #40 类壳已标，不动 ✓
  - P6 snapshotFees 同步实现 → 既有 PR #40 类壳已写正确，不动 ✓

- [ ] **No placeholders**：所有 throw / fallback / log 路径都有具体代码；无 TODO / TBD ✓

- [ ] **Type consistency**：
  - `TrainingSetFile` 字段名（id/filename/localURL/schemaVersion/lastAccessedAt/downloadedAt）与 PR #40 已 freeze 的 `AppState.swift:130-149` 完全一致
  - `AppSettings` 字段名与 PR #40 freeze（commissionRate/minCommissionEnabled/totalCapital/displayMode）完全一致
  - `AppError` 枚举 case（.persistence(.diskFull/.dbCorrupted/.ioError) / .trainingSet(.fileNotFound)）与 `AppError.swift` 既有定义对齐

- [ ] **Trust-boundary 评估**：§Design Decision §8 已列；不改任何 public 协议签名（`update` 加 `@escaping` 是 closure 标注，不破坏 caller 二进制兼容；PR #40 当时 fatalError 类壳无 production caller）

- [ ] **LOC 预算**：≈ 355 prod LOC < 500 硬规则 ✓

- [ ] **TDD discipline**：每个 task 都是 test → fail → impl → pass → commit；Task 1/5 严格 TDD（先写测试），Task 2/3/4/6 是 additive 测试 + R1 regression（H-1/H-2/H-3）

- [ ] **Commit ritual**：每个 task 末尾独立 commit；7 commits 总数

- [ ] **R1 codex finding 全覆盖**：
  - H-1 rollback safety → §3 算法重写 + Task 4 `store_invalidNewSqlite_oldCachePreserved` ✓
  - H-2 explicit mtime touch → §3 staging touch + Task 4 `store_oldMtimeSrc_doesNotEvictNewCache` ✓
  - H-3 settings 串行化 → §6.2 inflight Task chain + Task 6 `concurrentUpdate_*` 两测试 ✓
  - M-4 gate 强化 → Task 4 增 3 规则（throw/public-no-raw-try/translate-near-raw-try）✓

- [ ] **R2 codex finding 全覆盖**：
  - R2-H1 replaceItemAt 假定 target 存在 → §3 + helper `replaceFile` 分支（exists → replaceItemAt; not → moveItem）+ Task 4 `store_emptyCacheFirstStore_succeeds` ✓
  - R2-H2 mtime 截到秒 LRU 不稳 → §3 + listAvailableLocked 用 Date 多级 tiebreaker（mtime/ctime/basename）+ Task 4 `store_21RapidStores_evictsOldestStored` ✓
  - R2-H3 init catch all silent zero → §6.1 所有 load 失败均设 loadError 阻塞 update/reset（R4 修订：取消 dbCorrupted 特例）+ Task 5 三测试（dbCorrupted 阻塞、ioError 阻塞、diskFull 阻塞）✓

- [ ] **R3 codex finding 全覆盖**：
  - R3-H1 Step 5.4 task code 与 §6.1 设计脱节（catch all + 无 loadError）→ Step 5.4 重写 + 加 `loadError` 成员 + 加 `zeroDefault` 静态常量 ✓（R4 进一步取消 dbCorrupted 特例）
  - R3-H2 touch/delete 信任 caller localURL → 加 `validateFilename` + `cacheURL(forId:filename:)` 内部派生 + standardize hasPrefix(cacheRoot) 兜底 + Task 4 三测试（filename traversal 拒、delete victim 安全、touch victim mtime 不变）✓

- [ ] **R4 codex finding 全覆盖**：
  - R4-H1 dbCorrupted zero-default 仍危险（key-value DAO 单 key 坏不代表全坏）→ §6.1 取消特例，所有 load 失败均设 loadError 阻塞写 + Step 5.4 同步 + 测试改为 `init_dbCorrupted_updateBlocked`（断言 throws + 不调 saveSettings）✓
  - R4-H2 validateFilename 不限 .sqlite → 必须 lowercased.hasSuffix(".sqlite") + NULL byte 也拒 + 测试加 foo.db / noext / trailingdot.sqlite. 三 case ✓
  - R4-H3 mutate closure 缺 `@Sendable`，Swift 6 strict concurrency 编译 fail → 签名改 `@escaping @Sendable (inout AppSettings) -> Void` ✓

- [ ] **R5 codex finding 全覆盖**：
  - R5-H1 snapshotFees 不阻塞 loadError → silent zero fees → P&L 错算（valid-looking）→ §6.3 + Step 6 加 defense-in-depth log + 暴露 `public var loadError: AppError?` 让 caller guard + 测试 `snapshotFees_loadErrorState_returnsZeroAndExposesLoadError` ✓
  - R5-H2 update @Sendable 改 PR #40 frozen contract（自我矛盾） → §8.1 诚实暴露 2 处签名增强：`update` 加 `@escaping @Sendable` + 加 public `loadError` getter；列拒 A/B 替代方案理由 ✓
  - R5-M3 staging 残留绕过 LRU cap → 加 `cleanStaleStagingIfNeededLocked()` lazy 一次性扫 + 测试 `store_firstCallCleansStaleStagingFiles` ✓

- [ ] **R6 codex finding 处理（部分接受 + 1 reject）**：
  - R6-H1 snapshotFees 仍 fail-open（R5-H1 升级版）→ 部分修：加 additive `snapshotFeesIfReady() throws -> FeeSnapshot`，trading-flow caller (Wave 2 E5/E6) 必须用此 enforced 变体；snapshotFees 保留给 UI 显示路径 + 测试 `snapshotFeesIfReady_throwsOnLoadError_returnsFeesOnHappy` ✓
  - R6-M2 src 被 move 消耗 → caller retry 失败 → fix：stageFile 用 copyItem 而非 moveItem；happy-path 测试 flip + 加 retry-safe 测试 `store_validationFail_srcRemainsForRetry` ✓
  - **R6-M3 update @Sendable 签名（R5-H2 复述）→ REJECT 接受 residual**：详 §8.2，actor 替代方案在并发 + revert 路径下引入更严重 in-memory/DB 不一致；per `feedback_codex_round6_self_contradiction` rule ≥6 轮命中复述模式立即 reject ✗

---

## Out-of-Scope（明确不做）

- ❌ DownloadAcceptanceRunner 编排（依赖 P1 APIClient 未交付，Wave 1 scope）
- ❌ U4 SettingsPanel UI（Wave 2 scope）
- ❌ `URL.setResourceValues(.excludedFromBackup)` for cache files（cache 是可重新下载的，理论上应排除 iCloud backup；本 PR 不做，留 backlog）
- ❌ CacheManager 协议签名改名 `downloadedZip` → `extractedSqlite`（contract change PR；不混进生产实现 PR）
- ❌ `cache_index.json` / `app.sqlite training_set_files` 表（§Design Decision §1 已拒）
- ❌ touch() 抛错路径（spec hint 是 best-effort，无业务语义需要）
