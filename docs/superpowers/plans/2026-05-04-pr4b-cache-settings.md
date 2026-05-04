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

**§6.1 A 方案语义边界（codex 必抓点，预防辩论）：**
- `SettingsDAO.loadSettings()` 的失败类型只有两种（PR #42 SettingsDAOImpl L19-58）：
  - **missing**：key 不存在（首次启动 / 新增 key）→ 返回 zero-value，**不 throw**
  - **malformed**：key 存在但 value 非法（NaN / inf / 非法 enum）→ throw `.persistence(.dbCorrupted)`
- 所以 init eager-load throws 的唯一路径 = dbCorrupted；这种情况**任何 fallback 都是有损的**：
  - 选 A（zero-default + log）：用户损失原 commission/capital 设置，但 UI 还能用
  - 选 B（init throws）：app 启动崩溃 / 进入 error UI，更"诚实"但用户体验更差
- 取舍：**选 A**——理由：dbCorrupted 是极罕见事故（用户主动改 sqlite 才会触发），fallback 让用户至少能进 UI 改设置；os_log `.error` 级别记录，崩溃上报里能看到；后续可由 U4 SettingsPanel 检测 `commissionRate == 0 && totalCapital == 0` 提示用户"检测到设置异常，请重新配置"（U4 是 Wave 2 scope，本 PR 不做）

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

public func update(_ mutate: @escaping (inout AppSettings) -> Void) async throws {
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
            // best-effort：失败不抛（spec hint：协议签名无 throws）
            try? touchFile(file.localURL)
        }
    }

    public func delete(_ file: TrainingSetFile) throws {
        try queue.sync {
            try removeFile(file.localURL)
        }
    }

    // MARK: - Internal helpers (all FileManager / DatabaseQueue I/O wrapped here)
    // M-4 gate 强制：public 方法零 raw `try FileManager.` / `try DatabaseQueue`，全部走以下 helpers。

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

    private func stageFile(from src: URL, to staging: URL) throws {
        do {
            try FileManager.default.moveItem(at: src, to: staging)
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
        do {
            // replaceItemAt 在 same volume + same dir 走 rename(2)，APFS 上 atomic
            // 旧 target 不存在也合法（创建 target）
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
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
        var results: [TrainingSetFile] = []
        for entry in entries {
            guard entry.pathExtension.lowercased() == "sqlite" else { continue }
            let basename = entry.deletingPathExtension().lastPathComponent
            // R1 strict: skip staging files (前缀 ".staging-")，避免 in-flight store 被列出
            if basename.hasPrefix(".staging-") { continue }
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
        return results.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
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
        let raw: [FileAttributeKey: Any]
        do {
            raw = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw CacheErrorMapping.translate(error)
        }
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
public func update(_ mutate: @escaping (inout AppSettings) -> Void) async throws {
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

注：`update` 签名加 `@escaping` —— 因 closure 被 Task 捕获跨 await。Swift 6 编译器会要求；既有 PR #40 类壳没有但当时 fatalError 不需要 escaping。本 PR 改签名 = behavior-only 改动（PR #40 还没 production caller），无 binary contract 影响。

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

---

## Out-of-Scope（明确不做）

- ❌ DownloadAcceptanceRunner 编排（依赖 P1 APIClient 未交付，Wave 1 scope）
- ❌ U4 SettingsPanel UI（Wave 2 scope）
- ❌ `URL.setResourceValues(.excludedFromBackup)` for cache files（cache 是可重新下载的，理论上应排除 iCloud backup；本 PR 不做，留 backlog）
- ❌ CacheManager 协议签名改名 `downloadedZip` → `extractedSqlite`（contract change PR；不混进生产实现 PR）
- ❌ `cache_index.json` / `app.sqlite training_set_files` 表（§Design Decision §1 已拒）
- ❌ touch() 抛错路径（spec hint 是 best-effort，无业务语义需要）
