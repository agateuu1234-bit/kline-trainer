# PR 5b — Fixture/Mock port-domain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 Wave 0 顺位 10 的 port-domain 测试 fixture——把 PR #40 在 `InMemoryFakes.swift` 留下的 `InMemoryCacheManager` stub（store 抛 `fatalError`、listAvailable 永远空）升级为有内存状态、能 round-trip 的 fake；新增 4 个 P2 内部端口的 fake（`FakeZipIntegrityVerifier` / `FakeZipExtractor` / `FakeTrainingSetDataVerifier` / `FakeDownloadAcceptanceCleaner`），覆盖 spec §11.3 #6–#10。**spec §11.3 #11 `FakeAPIClient` 推迟**：P1 `APIClient` Swift protocol 在代码层还未落地（spec L1728-1741 是 spec 描述，未进 `KlineTrainerContracts` 模块），无 protocol 可做 fake；按 memory rule "B1-B4 backend 推到 Wave 1（与 P1 APIClient 联调一起做）"，FakeAPIClient 与 P1 一起进 Wave 1，本 PR 不实现。

**Architecture:**
- `InMemoryCacheManager` 保持 `final class` + `@unchecked Sendable`（PR #40 既有形状），内部加 `var store: [Int: TrainingSetFile]` + `NSLock`；store/touch/delete 镜像 `DefaultFileSystemCacheManager`（filename safety、`.zip → .sqlite` 规范化、LRU sort、20-cap 驱逐、touch 更新 `lastAccessedAt`、delete 缺失抛 `.ioError`）；不读 sqlite 文件（fake 无真实文件），`schemaVersion` 用 caller 在 `meta.schemaVersion` 注入的值
- 4 个 P2 fake 是 stateless behavior stub：`init(throwing:)` 注入错误（`.success` = no-op、`.failure(AppError)` = 抛该错），`FakeZipExtractor` 额外接 `returnURL`，`FakeDownloadAcceptanceCleaner` 记录 `cleanedURLs` 调用列表（用于 P2 runner future test 断言；其它 3 个无副作用，不必记录）
- 4 个 P2 fake 在新文件 `PreviewFakes/P2Fakes.swift`（不挤进 InMemoryFakes.swift，按 PR5a 的 PreviewTrainingSetReader 单文件分离前例；4 fake 同 P2 模块内聚一处）
- 全部 `#if DEBUG` guard（PR #40 / PR #45 既有约定）；测试 `@testable import KlineTrainerContracts`
- 不动协议签名（`KlineTrainerContracts/DownloadAcceptance/*.swift` 4 个 protocol 文件 + `Persistence/CacheManager.swift`）
- 不动 `InMemoryDBFakesTests.swift` / `PreviewTrainingSetReaderTests.swift`（PR5a 已落）；现有 `TrainingSessionCoordinatorTests.swift:170 cacheManagerDefaults` 测试 `fresh fake → empty` 仍成立（升级后 fresh init 内部 dict 为空 → `listAvailable().isEmpty == true`），不翻面

**Tech Stack:** Swift 6.0 / SwiftPM / Foundation / `NSLock` / XCTest

---

## File Structure

| 文件 | 责任 | 状态 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | `InMemoryCacheManager` 升级真状态：dict<id,TrainingSetFile> + NSLock + store/touch/delete + LRU sort + 20-cap evict + filename safety + `.zip → .sqlite` 规范化 | Modify |
| `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/P2Fakes.swift` | 4 个 P2 fake：`FakeZipIntegrityVerifier` / `FakeZipExtractor` / `FakeTrainingSetDataVerifier` / `FakeDownloadAcceptanceCleaner` | Create |
| `ios/Contracts/Tests/KlineTrainerContractsTests/InMemoryCacheManagerTests.swift` | 升级版 InMemoryCacheManager 行为测试：store/round-trip、`.zip → .sqlite`、filename safety、touch 更新 mtime、delete 缺失抛错、20-cap evict、LRU sort、并发安全 | Create |
| `ios/Contracts/Tests/KlineTrainerContractsTests/P2FakesTests.swift` | 4 个 P2 fake 行为测试：init throwing 路径、success 路径、cleaner 调用记录 | Create |
| `docs/acceptance/2026-05-06-pr5b-port-fixtures.md` | 验收清单（中文，非 coder 可执行）| Create |

**预估 prod LOC（硬规则 ≤500，R1 修订后）：**
- `InMemoryFakes.swift` 净增 ≈ 160 LOC（升级 InMemoryCacheManager + basename helper；保留 file-level `#if DEBUG` 包裹）
- `P2Fakes.swift` 新增 ≈ 130 LOC（4 fake + 文件头 doc comment）
- 合计：**≈ 290 prod LOC** ✓ 低于 500 上限

**预估 test LOC（R1 修订后）**：≈ 410（cache 测试 ~280 含 H-2 basename test + L-2 same-slot test，P2 fake 测试 ~130）

**子项数**（per memory feedback "硬规则 ≤3 子项"）：
1. P5 InMemoryCacheManager 升级（spec §11.3 #6）
2. P2 4 fake 新增（spec §11.3 #7-10）
3. 验收清单 + spec §11.3 #11 FakeAPIClient defer note
合计 **3 子项** ✓

---

## Design Decisions（plan-time 锁定，codex review 抓变动）

### §1 不实现 `FakeAPIClient`（spec §11.3 #11）—— 推迟到 Wave 1

**Spec 字面证据：**
- §11.3 #11（L2206）列 `FakeAPIClient（驱动 lease/download/confirm 各分支的 stub）`
- §P1 APIClient（L1728-1741）只是 spec 文本描述，**Swift protocol 文件不在 `ios/Contracts/Sources/KlineTrainerContracts/` 树**：`grep -rn "protocol APIClient" ios/Contracts/Sources/` 返回 0 命中（仅 `AppError.swift:106` 注释引用 P1 名）
- v6 outline PR 5b scope = "Fixture/Mock port-domain"；P1 APIClient **不在 Wave 0 已 merged 模块清单**（PR #37-#45 全部模块 = E1/C1a/F2/E6/P3a/P3b/P4/P2 4 ports/P5/P6/PR5a fakes，P1 缺）
- memory `project_modules_v1.4_frozen.md` + `project_spec_v1.4_rest_design_residuals.md` 双重锚定：P1 APIClient 与 B1-B4 backend 一起进 Wave 1（v6 outline "B1-B4 backend：推到 Wave 1（与 P1 APIClient 联调一起做）"）

**结论：** 没有 P1 protocol → 无 fake 可写。**不在本 PR 引入 P1 protocol**（出 scope，违反"每 PR ≤3 子项"硬规则；P1 落地需 plan + codex review 一整轮）。在本 plan §10 + 验收清单显式声明 deferred，并在 PR 描述链接 spec §11.3 #11 → Wave 1 P1 plan。

### §2 InMemoryCacheManager 镜像 production 哪些行为 / 不镜像哪些

**镜像（fake/production 行为不发散）：**

| # | 行为 | production 出处 | 镜像理由 |
|---|---|---|---|
| 1 | filename safety check（拒空、`/`、`\\`、`..`、`\0`、`.staging-` 前缀）| `DefaultFileSystemCacheManager.swift:132-143` | 防 caller 注入路径绕过 cacheRoot；fake 接受 prod 拒绝的 filename → consumer 测试 fake-pass / production-fail 分叉 |
| 2 | `.zip → .sqlite` 文件名规范化；`.sqlite` 直传；其它扩展抛 `.internalError` | `DefaultFileSystemCacheManager.swift:148-159`（codex post-impl R7） | REST DTO `TrainingSetMetaItem.filename` 是 `.zip`，cache 层规范化为 `.sqlite`；fake 不规范化 → caller test 看到 fake `.zip filename` 但 production `.sqlite` |
| 3 | listAvailable 排序：lastAccessedAt desc → downloadedAt desc → **basename desc**（basename = `"\(id)__\(filename)"`，mirror production `entry.deletingPathExtension().lastPathComponent`）| `DefaultFileSystemCacheManager.swift:253-257`（mtime → ctime → basename） | LRU 语义；R1-H2 修订：production tiebreaker 用 basename desc 不是 id desc，跨数量级 id 时字典序与 id 序发散（"10__a" < "2__a"）→ fake 不镜像会让 consumer 测试在边界 case 上 fake-pass / production-fail |
| 4 | 新插入 mtime = now（`lastAccessedAt = now`）| `:40-80`（stage→replace + immediate touch line 61） | 测试 "新存入应排首位" 行为 |
| 5 | maxCachedSets = 20；超容量驱逐尾部 | `:17`（`maxCachedSets = 20`）+ `:261-272`（evictIfNeededLocked） | LRU 驱逐语义 |
| 6 | touch: 更新 `lastAccessedAt = now`；缺失 silent no-op（不抛）| `:82-89`（`try?` swallow） | spec L1958 协议签名 `func touch(_:)` 无 throws |
| 7 | delete: 缺失抛 **`AppError.trainingSet(.fileNotFound)`** | `:91-97` + `Internal/CacheErrorMapping.swift:24-25`（`NSFileNoSuchFileError → .trainingSet(.fileNotFound)`）+ production test `DefaultFileSystemCacheManagerTests.swift:118-128 delete_nonExistentThrowsFileNotFound` | spec L1959 `func delete(_:) throws`；R1-H1 修订：production 真抛 `.trainingSet(.fileNotFound)`，不是 `.persistence(.ioError)` |
| 8 | 全部 method 走 NSLock（serial）| `:20`（`DispatchQueue` serial） | 多线程 store/touch/delete 不交叉腐化 dict |

**不镜像（fake-specific 简化）：**

| # | production 行为 | fake 简化 | 理由 |
|---|---|---|---|
| A | 读 sqlite `PRAGMA user_version` 拿 schemaVersion | 用 caller 在 `meta.schemaVersion` 注入的值 | fake 没真 sqlite 文件可读；preview 路径 caller 已知 schema |
| B | stage→validate→atomic replace 三步（POSIX rename2 / replaceItemAt）| 直接 dict 写入 | fake 不动文件系统 |
| C | `.staging-*` orphan 清扫（lazy one-shot）| 无 staging 概念 | fake 无文件系统 staging |
| D | `cleanStaleStaging`、`evictIfNeededLocked` 真 removeFile | dict.removeValue | fake 不动文件系统 |
| E | downloadedZip src URL 必须存在 + 可读 | 接受任意 URL（不读文件） | fake 不读 sqlite；caller 给的 URL 只用于 store 后存进 TrainingSetFile.localURL（不验证可读性）|
| F | log via `os.Logger`（subsystem=kline.trainer）| 无 log | fake 不持有 logger 资源 |
| G | replace 失败 rollback | 简单 dict 替换 | fake 不会失败 |

**fake 文件头 + InMemoryCacheManager doc comment 加显式 limitation 声明**（mirror PR5a §3 R5 修订模式）：

```swift
/// **Scope: preview/happy-path only.**
/// 此 fake 不读 sqlite 文件——`schemaVersion` 来自 caller 注入的 `meta.schemaVersion`，
/// `downloadedZip` URL 不被读取（只存进 `TrainingSetFile.localURL` 字段供 caller 持有）。
/// 需要测试真 sqlite IO 错误（diskFull / dbCorrupted via PRAGMA failure）的用例，
/// 请用 `DefaultFileSystemCacheManager` + 真临时目录 fixture，不要 fork 本 fake。
```

### §3a 同 id 替换：lastAccessedAt = now / downloadedAt 保留（**fake-specific 简化**，§2 表 #4 不含此条）

**production replaceItemAt ctime 行为（fake 不镜像）**：production `replaceItemAt` 在 APFS 上 ctime 也变成 staging 的 ctime ≈ now（即同 id 重新 store 后 production 看到 downloadedAt 重置），fake 反过来保留原 downloadedAt。理由：「同训练组重新 store = 元数据更新」语义对 caller 直觉更友好；replaceItemAt ctime swap 是 production 文件系统副作用，不是 spec 强语义。

**§10 不在范围**显式声明：production replaceItemAt ctime 边界用 `DefaultFileSystemCacheManager` + 真临时目录 fixture 测，不绕道 fake。

### §3b store: 同 id 替换 vs 单调累加

**Production 行为**（`DefaultFileSystemCacheManager.swift:40-80`）：
- 同 id 同 filename → `replaceItemAt`：APFS swap，target 的 ctime 在 swap 后是 staging 的 ctime（≈ now）
- 同 id 不同 filename → 形成两个 disk 文件（`{id}__filename1.sqlite` + `{id}__filename2.sqlite`）；listAvailable 按 basename 解析 id，**两条都返回**

**实际语义**：
- production 用 disk 文件名前缀 `{id}__{filename}.sqlite` 当 key，**id+filename 联合唯一**，不是单 id 唯一
- 但 PR4b 后 store post-impl R7 把 caller 的 `.zip` filename 都规范化成 `.sqlite`，且 caller 端 `meta.id + meta.filename` 是 1:1（同一训练组只有一个 sqlite 名）

**fake 决策**：用 `[Int: TrainingSetFile]` dict（id 唯一）。理由：
1. 内部单用户 / 单训练组场景，spec L692 没给「同 id 多 filename 共存」用例
2. PR #44 production R7 后规范化路径下 id ↔ filename 实际 1:1
3. 「同 id 不同 filename 共存」是 production 边界 case，不是 spec 强语义；fake 不背这种 corner case（YAGNI）
4. 若未来 caller 真用同 id 不同 filename 路径，fake 行为 = 后写覆盖前写（dict 语义）；这是合理简化，不是误导（fake 文件头 doc comment 声明此 simplification）

**downloadedAt（ctime）行为**（详见 §3a 已 spelled out）：
- 新插入 id 不存在 → `downloadedAt = now`
- 替换 id 已存在 → 保留原 `downloadedAt`，只更新 `lastAccessedAt = now`

### §4 4 P2 fake 设计：stateless stub + init(throwing:)

**Spec 字面证据**：§11.3 #7（L2202）`FakeZipIntegrityVerifier（固定返回 OK / 失败）`—— spec 措辞 "固定返回 OK / 失败" = 配置型 stub，**不是 stateful in-memory state**（与 P4 fakes 的 round-trip 语义对比鲜明）。

**接口形状**：每个 fake 一个 `init(throwing: AppError? = nil)`：
- `nil` = 默认 success / no-op 路径
- 非 nil = 该 method 调用时 throw 给定 AppError

```swift
public struct FakeZipIntegrityVerifier: ZipIntegrityVerifying {
    private let throwing: AppError?
    public init(throwing: AppError? = nil) { self.throwing = throwing }
    public func verify(zipURL: URL, expectedCRC32Hex: String) throws {
        if let err = throwing { throw err }
    }
}
```

**`FakeZipExtractor` 多一个返回 URL 注入**（因 protocol 签名要求返回 URL）：
```swift
public struct FakeZipExtractor: ZipExtracting {
    private let throwing: AppError?
    private let returnURL: URL
    public init(returnURL: URL = URL(fileURLWithPath: "/tmp/fake.sqlite"),
                throwing: AppError? = nil) {
        self.returnURL = returnURL
        self.throwing = throwing
    }
    public func extract(zipURL: URL) throws -> URL {
        if let err = throwing { throw err }
        return returnURL
    }
}
```

**`FakeDownloadAcceptanceCleaner` 记录调用列表**（理由：production cleanup 不抛、不返回值；唯一可观测点是「被调用了什么 URL」）：
```swift
public final class FakeDownloadAcceptanceCleaner: DownloadAcceptanceCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var _cleanedURLs: [URL] = []
    public init() {}
    public func cleanup(tempURLs: [URL]) {
        lock.lock(); defer { lock.unlock() }
        _cleanedURLs.append(contentsOf: tempURLs)
    }
    /// 测试断言用。
    public func cleanedURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return _cleanedURLs
    }
}
```

**反驳「为什么不给 FakeZip... 也加 callRecording」：** YAGNI。3 个 fake 的 throws 路径已是「测试 P2 runner 该方法是否被调用」的可断言信号（runner 把 throws 包成 AcceptanceResult.rejected → 用 .rejected 是否传递判断 fake 是否 throw 即可）。Cleaner 唯一缺断言点（无 return / 无 throw），所以单独加 cleanedURLs。

### §5 不镜像 production NSError → AppError 翻译细节

**Production**：`Default*` 实现内部 `do/catch` 把 NSError 翻译成 AppError（见 `DefaultZipIntegrityVerifier.swift:14-15` ZipErrorMapping、`DefaultFileSystemCacheManager.swift:127` CacheErrorMapping）。

**Fake**：直接抛 caller 注入的 AppError，不需要翻译——caller 想测试 `.unzipFailed` 路径就 `init(throwing: .trainingSet(.unzipFailed))`。

**反驳「fake 应该也接 NSError 然后翻译」：** 出 scope。NSError 翻译是 production internal logic，fake 是 protocol 层面 stub。如未来需要 ZipErrorMapping 单测，应直接测 `Internal/ZipErrorMapping.swift`（已有 `ZipErrorMappingTests.swift`），不绕道 fake。

### §6 4 P2 fake 不需要 `@unchecked Sendable` 标注（除 Cleaner）

3 个 stateless struct fake 满足 protocol `Sendable`（spec L1753-1769 protocol 标 Sendable）：
- `FakeZipIntegrityVerifier` / `FakeZipExtractor` / `FakeTrainingSetDataVerifier`：value type struct + 全部 stored property 是 `let` + `Sendable` types（`AppError` Sendable / `URL` Sendable）→ Swift 6 自动推导 Sendable，**不必标 `@unchecked`**

**例外：** `FakeDownloadAcceptanceCleaner` 是 reference type class + 内部 mutable `_cleanedURLs`（lock 守护）→ 显式标 `@unchecked Sendable`（与 PR5a `InMemoryRecordRepository` 等同模式）。

### §7 测试目标：覆盖 §2 8 条镜像行为 + §3 dict 单 id 语义 + §4 init(throwing:) 各分支

**InMemoryCacheManagerTests** 必含（R1 修订后 20 个测试）：
1. fresh init 后 listAvailable 空 / pickRandom nil（mirror 现有 cacheManagerDefaults，不破现有测试）
2. store + listAvailable round-trip：1 条插入后 listAvailable.count == 1，TrainingSetFile 字段全等
3. `.zip` filename → 内部存 `.sqlite`（codex post-impl R7 镜像）：`store(meta: filename="x.zip")` → `listAvailable[0].filename == "x.sqlite"`
4. `.sqlite` 直传 → 原样：filename = "x.sqlite" → listAvailable[0].filename == "x.sqlite"
5. 非法扩展抛 `.internalError`：filename = "x.txt" → throw
6. filename safety：6 个非法 case 全抛 `.internalError`（empty / contains "/" / contains "\\" / contains ".." / contains "\0" / 前缀 ".staging-"）
7. 同 id 替换：store(id=1, file="a") + store(id=1, file="b") → listAvailable.count == 1，filename 是后写的 "b.sqlite"
8. 替换保留 downloadedAt：上一步后 listAvailable[0].downloadedAt 等于第一次 store 时的 ctime（不是第二次 now）
9. 替换更新 lastAccessedAt：上一步后 listAvailable[0].lastAccessedAt > 第一次 store 时的 mtime
10. listAvailable LRU 排序：3 条，按 store 顺序 1/2/3 → listAvailable 顺序 = 3/2/1（最近 store = 最近访问）
11. listAvailable 同 lastAccessedAt 用 downloadedAt desc → **basename desc** tiebreak（R1-H2：mirror production basename 字典序，含跨数量级 id 反例 id=2 vs id=10）
12. touch 更新 lastAccessedAt：store + touch → listAvailable[0].lastAccessedAt 比 store 时新
13. touch 缺失 id silent no-op：touch 一个未 store 的 file 不抛（best-effort）
14. delete: store + delete → listAvailable 空
15. delete 缺失 id 抛 `.trainingSet(.fileNotFound)`（R1-H1+M3：紧到具体子 case，mirror production CacheErrorMapping.swift:24-25 + production test delete_nonExistentThrowsFileNotFound）
16. 20-cap evict：store 21 条 → listAvailable.count == 20，最早 store 的（lastAccessedAt 最旧）被驱逐
17. evict 后保留最近 20：第 1 条被驱逐，2-21 留下
18. pickRandom 非空 dict 返回非 nil 元素属于 listAvailable
19. 并发安全：N 线程同时 store 不同 id → 最终 listAvailable.count == 实际写入数（≤20）
20. **并发同 id 撞 slot**（R1-L2）：100 次 concurrentPerform store 同 id → 收敛到 1 条 dict slot（无 lock 时会 trap / lose write）

**P2FakesTests** 必含（每 fake 1 happy + 1 throwing path）：
20. FakeZipIntegrityVerifier success：`init()` + verify → 不抛
21. FakeZipIntegrityVerifier throwing：`init(throwing: .trainingSet(.crcFailed))` + verify → 抛 .crcFailed
22. FakeZipExtractor success default URL：`init()` + extract → 返回 `/tmp/fake.sqlite`
23. FakeZipExtractor success custom URL：`init(returnURL: ...)` + extract → 返回该 URL
24. FakeZipExtractor throwing：`init(throwing: .trainingSet(.unzipFailed))` + extract → 抛 .unzipFailed
25. FakeTrainingSetDataVerifier success：`init()` + verifyNonEmpty → 不抛
26. FakeTrainingSetDataVerifier throwing：`init(throwing: .trainingSet(.emptyData))` + verifyNonEmpty → 抛 .emptyData
27. FakeDownloadAcceptanceCleaner records calls：cleanup([url1, url2]) + cleanup([url3]) → cleanedURLs() == [url1, url2, url3]
28. FakeDownloadAcceptanceCleaner empty input no-op：cleanup([]) → cleanedURLs() 空
29. FakeDownloadAcceptanceCleaner thread safety：N 线程同时 cleanup 不同 URL → 最终 cleanedURLs.count == 实际调用数

### §8 不在 PR5b 内做的事

- `FakeAPIClient`（spec §11.3 #11）→ Wave 1 P1 plan
- 引入 P1 APIClient protocol（出 scope，违反 ≤3 子项）
- 改 P2 / P5 protocol 签名（trust-boundary，要 codex review）
- 改 production `DefaultFileSystemCacheManager` 行为（不在 5b 范围）
- 翻面已有 `cacheManagerDefaults` 测试（fresh fake → empty 仍成立）
- 写 `DownloadAcceptanceRunner` 集成测试（runner 还未存在）
- production replaceItemAt ctime 边界 case 镜像（§3 显式声明简化）

### §9 子项硬规则自检

| 子项 | spec §11.3 项 | prod LOC | test LOC |
|---|---|---|---|
| 1. P5 InMemoryCacheManager 升级 | #6 | ~160（R1 +basename helper +1 测试 +文档）| ~280（R1 +tiebreaker fix +concurrent same-slot test）|
| 2. P2 4 fake 新增 | #7-10 | ~130 | ~130 |
| 3. 验收清单 + #11 defer note | (清单 + doc) | 0 | 0 |
| **合计** | **5/6 项**（#11 defer）| **~290** | **~410** |

✅ 3 子项；✅ <500 prod LOC；✅ 单 PR 收敛性合理（5b 应有的 fake 全到位，剩 1 项 P1 依赖未到位 deferred）

### §10 不在本 PR 范围（防 codex 越界扩 scope）

| 项 | 推迟到 | 理由 |
|---|---|---|
| `FakeAPIClient` | Wave 1 P1 plan | P1 APIClient Swift protocol 不存在（spec L1728 是 spec 文本，未进 contracts 模块） |
| P1 `APIClient` Swift protocol | Wave 1 | 业务 module，不属 fixture 范畴 |
| `DownloadAcceptanceRunner` | Wave 1（spec L1777） | 顶层 orchestrator，依赖 P1 + P2 + P3a + P4 + P5 全到位，集成层 |
| InMemoryCacheManager 同 id 多 filename 行为 | 不计划做 | YAGNI（§3 §10 显式声明简化）；用真 `DefaultFileSystemCacheManager` 测此边界 |
| InMemoryCacheManager replaceItemAt ctime swap 行为 | 不计划做 | fake-specific 简化（§3）|
| ZipErrorMapping / CacheErrorMapping NSError 翻译 | 已 PR4a/PR4b 落 | production internal，不绕道 fake 测 |
| TSC.preview() 路径行为变更 | 不动 | 现有 cacheManagerDefaults 测试不翻面 |

---

## Task 1: P5 InMemoryCacheManager 升级真状态

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/InMemoryCacheManagerTests.swift`

### Step 1.1 — 写 InMemoryCacheManager 行为测试（fail first）

- [ ] **写测试文件 InMemoryCacheManagerTests.swift（XCTest，target = `KlineTrainerContractsTests`）**

> **类型签名锚点（按 `AppState.swift:130-149` / `RESTDTOs.swift` / `AppError.swift` 真实形状）：**
> - `TrainingSetFile(id: Int, filename: String, localURL: URL, schemaVersion: Int, lastAccessedAt: Int64, downloadedAt: Int64)`（Equatable, Sendable）
> - `TrainingSetMetaItem(id: Int, stockCode: String, stockName: String, filename: String, schemaVersion: Int, contentHash: String)`（Codable, Sendable）
> - `AppError.persistence(.diskFull / .dbCorrupted / .schemaMismatch / .ioError(String))`
> - `AppError.trainingSet(.crcFailed / .unzipFailed / .emptyData / .versionMismatch / .fileNotFound)`（**delete 缺失抛 `.fileNotFound`**，R1-H1 修订）
> - `AppError.internalError(module: String, detail: String)`

```swift
import XCTest
@testable import KlineTrainerContracts

#if DEBUG
final class InMemoryCacheManagerTests: XCTestCase {

    // MARK: - 测试 helpers

    private func makeMeta(id: Int, filename: String, schemaVersion: Int = 1) -> TrainingSetMetaItem {
        TrainingSetMetaItem(
            id: id, stockCode: "TEST", stockName: "Test Stock",
            filename: filename, schemaVersion: schemaVersion,
            contentHash: "deadbeef"
        )
    }

    private let dummyZip = URL(fileURLWithPath: "/tmp/dummy.zip")

    // MARK: - 1. fresh init 默认空（保不破 cacheManagerDefaults 测试）

    func test_freshInit_listAvailable_isEmpty_and_pickRandom_nil() {
        let cache = InMemoryCacheManager()
        XCTAssertTrue(cache.listAvailable().isEmpty)
        XCTAssertNil(cache.pickRandom())
    }

    // MARK: - 2-4. store + filename 规范化

    func test_store_round_trip_listAvailable_returns_inserted_file() throws {
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip,
                                meta: makeMeta(id: 1, filename: "a.sqlite"))
        XCTAssertEqual(f.id, 1)
        XCTAssertEqual(f.filename, "a.sqlite")
        XCTAssertEqual(f.schemaVersion, 1)
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0], f)
    }

    func test_store_zip_filename_normalized_to_sqlite() throws {
        // codex post-impl R7：REST meta.filename 是 .zip，cache 层规范化为 .sqlite
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip,
                                meta: makeMeta(id: 1, filename: "600519_202001.zip"))
        XCTAssertEqual(f.filename, "600519_202001.sqlite")
        XCTAssertEqual(cache.listAvailable()[0].filename, "600519_202001.sqlite")
    }

    func test_store_sqlite_filename_passes_through() throws {
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip,
                                meta: makeMeta(id: 1, filename: "x.sqlite"))
        XCTAssertEqual(f.filename, "x.sqlite")
    }

    // MARK: - 5-6. filename safety

    func test_store_other_extension_throws_internalError() {
        let cache = InMemoryCacheManager()
        XCTAssertThrowsError(try cache.store(
            downloadedZip: dummyZip,
            meta: makeMeta(id: 1, filename: "x.txt")
        )) { err in
            guard case AppError.internalError = err else {
                XCTFail("expected internalError, got \(err)"); return
            }
        }
    }

    func test_store_unsafe_filename_throws_internalError() {
        let cache = InMemoryCacheManager()
        let bad = ["", "a/b.sqlite", "a\\b.sqlite", "../x.sqlite", "a\u{0}b.sqlite", ".staging-x.sqlite"]
        for f in bad {
            XCTAssertThrowsError(try cache.store(
                downloadedZip: dummyZip,
                meta: makeMeta(id: 1, filename: f)
            )) { err in
                guard case AppError.internalError = err else {
                    XCTFail("filename '\(f)' expected internalError, got \(err)"); return
                }
            }
        }
    }

    // MARK: - 7-9. 同 id 替换 + downloadedAt 保留 + lastAccessedAt 更新

    func test_store_same_id_replaces_and_preserves_downloadedAt() throws {
        let cache = InMemoryCacheManager()
        let f1 = try cache.store(downloadedZip: dummyZip,
                                 meta: makeMeta(id: 1, filename: "a.sqlite"))
        let originalDownloadedAt = f1.downloadedAt

        // 等 1 秒确保 mtime 时间戳变化（Int64 秒精度）
        Thread.sleep(forTimeInterval: 1.1)

        let f2 = try cache.store(downloadedZip: dummyZip,
                                 meta: makeMeta(id: 1, filename: "b.sqlite"))
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].filename, "b.sqlite")
        XCTAssertEqual(listed[0].downloadedAt, originalDownloadedAt, "downloadedAt 替换后应保留原值")
        XCTAssertGreaterThan(listed[0].lastAccessedAt, f1.lastAccessedAt,
                             "lastAccessedAt 替换后应更新到 now")
        _ = f2  // 抑制 unused warning
    }

    // MARK: - 10-11. listAvailable LRU sort + tiebreaker

    func test_listAvailable_sorts_by_lastAccessedAt_desc() throws {
        let cache = InMemoryCacheManager()
        let f1 = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 1, filename: "a.sqlite"))
        Thread.sleep(forTimeInterval: 1.1)
        let f2 = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 2, filename: "b.sqlite"))
        Thread.sleep(forTimeInterval: 1.1)
        let f3 = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 3, filename: "c.sqlite"))
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.map(\.id), [3, 2, 1])
        _ = (f1, f2, f3)
    }

    /// §2 行为 #3 + §7 测试 #11：同 lastAccessedAt 用 downloadedAt desc → basename desc（mirror production line 256）。
    /// basename = `"\(id)__\(filename)"`（production `entry.deletingPathExtension().lastPathComponent`，
    /// 对 fake 等价：所有项同 `.sqlite` 后缀，basename `>` 与 `id__filename` 字符串 `>` 同序）。
    func test_listAvailable_tiebreaker_downloadedAt_desc_then_basename_desc() throws {
        // R1-H2 修订：basename 字典序，不是 id 序——故意用「id=10」+「id=2」反例覆盖跨数量级
        let cache = InMemoryCacheManager()
        let now: Int64 = 1_000
        let earlier: Int64 = 500
        let urlA = URL(fileURLWithPath: "/tmp/a.sqlite")
        // f1: 同 mtime / 较老 ctime → 排末尾
        let f1 = TrainingSetFile(id: 1, filename: "a.sqlite", localURL: urlA, schemaVersion: 1,
                                 lastAccessedAt: now, downloadedAt: earlier)
        // f2 / f10：同 mtime / 同 ctime → basename desc 比较
        // basename(f10) = "10__b.sqlite"；basename(f2) = "2__b.sqlite"
        // 字典序 "2..." > "10..." → f2 在 f10 前
        let f2  = TrainingSetFile(id: 2,  filename: "b.sqlite", localURL: urlA, schemaVersion: 1,
                                  lastAccessedAt: now, downloadedAt: now)
        let f10 = TrainingSetFile(id: 10, filename: "b.sqlite", localURL: urlA, schemaVersion: 1,
                                  lastAccessedAt: now, downloadedAt: now)
        cache._seedForTesting([f1, f2, f10])
        let listed = cache.listAvailable()
        // 期望顺序：[f2, f10, f1]
        // - f2 在 f10 前：同 mtime/ctime，basename "2__b" > "10__b" 字典序
        // - f1 末尾：ctime 较老
        XCTAssertEqual(listed.map(\.id), [2, 10, 1])
    }

    // MARK: - 12-13. touch

    func test_touch_updates_lastAccessedAt() throws {
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 1, filename: "a.sqlite"))
        Thread.sleep(forTimeInterval: 1.1)
        cache.touch(f)
        XCTAssertGreaterThan(cache.listAvailable()[0].lastAccessedAt, f.lastAccessedAt)
    }

    func test_touch_missing_id_is_silent_noop() {
        let cache = InMemoryCacheManager()
        let phantom = TrainingSetFile(id: 999, filename: "ghost.sqlite",
                                      localURL: URL(fileURLWithPath: "/tmp/g.sqlite"),
                                      schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)
        cache.touch(phantom)  // 不抛
        XCTAssertTrue(cache.listAvailable().isEmpty)
    }

    // MARK: - 14-15. delete

    func test_delete_removes_file() throws {
        let cache = InMemoryCacheManager()
        let f = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 1, filename: "a.sqlite"))
        try cache.delete(f)
        XCTAssertTrue(cache.listAvailable().isEmpty)
    }

    /// R1-H1 修订：production CacheErrorMapping 把缺失文件 NSFileNoSuchFileError 翻成 `.trainingSet(.fileNotFound)`
    /// 不是 `.persistence(.ioError)`（见 `Internal/CacheErrorMapping.swift:24-25` + production
    /// test `DefaultFileSystemCacheManagerTests.swift:118-128`）。R1-M3 修订：紧到具体子 case 避免通配 false-positive。
    func test_delete_missing_throws_trainingSet_fileNotFound() {
        let cache = InMemoryCacheManager()
        let phantom = TrainingSetFile(id: 999, filename: "ghost.sqlite",
                                      localURL: URL(fileURLWithPath: "/tmp/g.sqlite"),
                                      schemaVersion: 1, lastAccessedAt: 0, downloadedAt: 0)
        XCTAssertThrowsError(try cache.delete(phantom)) { err in
            XCTAssertEqual(err as? AppError, .trainingSet(.fileNotFound))
        }
    }

    // MARK: - 16-17. 20-cap evict

    func test_store_21st_evicts_oldest_lastAccessedAt() throws {
        let cache = InMemoryCacheManager()
        // store id=1...20 各间隔 dummy 时间（用 _seedForTesting 直接灌入 20 条）
        var files: [TrainingSetFile] = []
        for i in 1...20 {
            files.append(TrainingSetFile(
                id: i, filename: "f\(i).sqlite",
                localURL: URL(fileURLWithPath: "/tmp/\(i).sqlite"),
                schemaVersion: 1,
                lastAccessedAt: Int64(i),  // i=1 最旧, i=20 最新
                downloadedAt: Int64(i)
            ))
        }
        cache._seedForTesting(files)
        XCTAssertEqual(cache.listAvailable().count, 20)
        // 第 21 条 store 通过正常路径
        _ = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: 21, filename: "f21.sqlite"))
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.count, 20, "20-cap 触发驱逐")
        XCTAssertNil(listed.first(where: { $0.id == 1 }), "id=1（lastAccessedAt 最旧）应被驱逐")
        XCTAssertNotNil(listed.first(where: { $0.id == 21 }), "新 store 的 id=21 应在")
    }

    // MARK: - 18. pickRandom

    func test_pickRandom_returns_member_when_nonempty() throws {
        let cache = InMemoryCacheManager()
        for i in 1...3 {
            _ = try cache.store(downloadedZip: dummyZip, meta: makeMeta(id: i, filename: "f\(i).sqlite"))
        }
        let picked = cache.pickRandom()
        XCTAssertNotNil(picked)
        XCTAssertTrue(cache.listAvailable().contains(picked!))
    }

    // MARK: - 19. 并发安全

    func test_concurrent_store_does_not_corrupt() {
        let cache = InMemoryCacheManager()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for i in 1...10 {
            group.enter()
            queue.async {
                _ = try? cache.store(downloadedZip: self.dummyZip,
                                     meta: self.makeMeta(id: i, filename: "f\(i).sqlite"))
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(cache.listAvailable().count, 10)
        XCTAssertEqual(Set(cache.listAvailable().map(\.id)), Set(1...10))
    }

    /// R1-L2 修订：mirror PR4b `DefaultFileSystemCacheManagerTests:194-200` 撞同 slot 模式——
    /// 100 次并发 store 同 id 应收敛到 1 条 dict slot（无 lock 时 dict 撞写会 trap 或 lose write）。
    func test_concurrent_store_same_id_converges_to_single_slot() {
        let cache = InMemoryCacheManager()
        let id = 42
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            _ = try? cache.store(
                downloadedZip: self.dummyZip,
                meta: self.makeMeta(id: id, filename: "racer-\(i).sqlite")
            )
        }
        let listed = cache.listAvailable()
        XCTAssertEqual(listed.count, 1, "100 次同 id 并发 store 应收敛到 1 条")
        XCTAssertEqual(listed[0].id, id)
    }
}
#endif
```

- [ ] **Step 1.2 — 运行测试验证 fail**

> R2-H1 修订：filter 用 struct 名 `InMemoryCacheManagerTests`（不带 target prefix）。

Run: `cd ios/Contracts && swift test --filter InMemoryCacheManagerTests`
Expected: 全部 17 个测试函数 FAIL（`store` 调用 `fatalError`、`_seedForTesting` 未定义编译失败）

> 测试函数数 = 17，覆盖 §7 列出的 20 个语义点（R2-L1：`#7/#8/#9` 折叠为 `test_store_same_id_replaces_and_preserves_downloadedAt` 一个；`#16/#17` 折叠为 `test_store_21st_evicts_oldest_lastAccessedAt` 一个；`#18` `pickRandom` 单测 1 个；其余 1:1）。

**注意**：`_seedForTesting` 是 Step 1.3 引入的 testable internal helper，初次运行编译会报 missing。这是 TDD 期望流程：先看 fail，再补实现。

### Step 1.3 — 实现 InMemoryCacheManager 升级（pass）

- [ ] **修改 InMemoryFakes.swift 的 InMemoryCacheManager（不动其它 fake）**

> **替换 InMemoryFakes.swift 当前 `// MARK: - P5 fake` 段（line 305-316）**

```swift
// MARK: - P5 fake

/// **Scope: preview/happy-path only.**
///
/// 此 fake 不读 sqlite 文件——`schemaVersion` 来自 caller 注入的 `meta.schemaVersion`，
/// `downloadedZip` URL 不被读取（只存进 `TrainingSetFile.localURL` 字段供 caller 持有）。
///
/// 镜像 production `DefaultFileSystemCacheManager` 行为（plan §2 8 条）：
/// - filename safety check（拒空 / `/` / `\` / `..` / `\0` / `.staging-` 前缀）
/// - `.zip → .sqlite` 文件名规范化（codex post-impl R7）
/// - listAvailable 排序：lastAccessedAt desc → downloadedAt desc → **basename desc**（R1-H2 修订；basename = `"\(id)__\(filename)"`，mirror production line 256）
/// - store: 同 id 替换；新插入 mtime = now；替换保留原 downloadedAt，lastAccessedAt = now
/// - maxCachedSets = 20；超容量驱逐尾部
/// - touch: best-effort，缺失 silent no-op
/// - delete: 缺失抛 **`.trainingSet(.fileNotFound)`**（R1-H1 修订；mirror `Internal/CacheErrorMapping.swift:24-25` `NSFileNoSuchFileError → .trainingSet(.fileNotFound)`）
/// - 全部 method 走 NSLock 串行
///
/// **不镜像**（fake-specific 简化）：
/// - PRAGMA user_version 读取（用 caller 注入 schemaVersion）
/// - 文件系统 stage / replaceItemAt / staging orphan 清扫
/// - 同 id 多 filename 共存（dict 单 id 唯一；后写覆盖前写）
/// - replaceItemAt ctime swap 边界
///
/// 需要测试真 sqlite IO 错误（diskFull / dbCorrupted via PRAGMA failure）的用例，
/// 请用 `DefaultFileSystemCacheManager` + 真临时目录 fixture，不要 fork 本 fake。
public final class InMemoryCacheManager: CacheManager, @unchecked Sendable {

    public static let maxCachedSets = 20

    private let lock = NSLock()
    private var store: [Int: TrainingSetFile] = [:]

    public init() {}

    public func listAvailable() -> [TrainingSetFile] {
        lock.lock(); defer { lock.unlock() }
        return sortedLocked()
    }

    public func pickRandom() -> TrainingSetFile? {
        lock.lock(); defer { lock.unlock() }
        return sortedLocked().randomElement()
    }

    public func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile {
        lock.lock(); defer { lock.unlock() }
        let cacheFilename = try Self.normalizedFilename(meta.filename)
        let now = Int64(Date().timeIntervalSince1970)
        let preservedDownloadedAt = self.store[meta.id]?.downloadedAt ?? now
        let file = TrainingSetFile(
            id: meta.id,
            filename: cacheFilename,
            localURL: downloadedZip,
            schemaVersion: meta.schemaVersion,
            lastAccessedAt: now,
            downloadedAt: preservedDownloadedAt
        )
        self.store[meta.id] = file
        evictIfNeededLocked()
        return file
    }

    public func touch(_ file: TrainingSetFile) {
        lock.lock(); defer { lock.unlock() }
        guard let existing = self.store[file.id] else { return }   // best-effort silent no-op
        let now = Int64(Date().timeIntervalSince1970)
        self.store[file.id] = TrainingSetFile(
            id: existing.id, filename: existing.filename, localURL: existing.localURL,
            schemaVersion: existing.schemaVersion,
            lastAccessedAt: now,
            downloadedAt: existing.downloadedAt
        )
    }

    public func delete(_ file: TrainingSetFile) throws {
        lock.lock(); defer { lock.unlock() }
        // R1-H1 修订：mirror production CacheErrorMapping `NSFileNoSuchFileError → .trainingSet(.fileNotFound)`
        // (Internal/CacheErrorMapping.swift:24-25)；production test 期望同 case
        // (DefaultFileSystemCacheManagerTests.swift:118-128 delete_nonExistentThrowsFileNotFound)
        guard self.store.removeValue(forKey: file.id) != nil else {
            throw AppError.trainingSet(.fileNotFound)
        }
    }

    // MARK: - Internal helpers

    /// `.zip → .sqlite` 规范化 + filename safety；mirror `DefaultFileSystemCacheManager.normalizedCacheFilename` (line 148-159) + `validateFilenameSafety` (line 132-143)
    private static func normalizedFilename(_ raw: String) throws -> String {
        // safety check（先于扩展名规范化，避免被规范化掩盖）
        if raw.isEmpty
            || raw.contains("/")
            || raw.contains("\\")
            || raw.contains("..")
            || raw.contains("\0")
            || raw.hasPrefix(".staging-") {
            throw AppError.internalError(
                module: "PR5b-InMemoryCacheManager",
                detail: "invalid filename rejected: \(raw)"
            )
        }
        let lower = raw.lowercased()
        if lower.hasSuffix(".sqlite") {
            return raw
        }
        if lower.hasSuffix(".zip") {
            return String(raw.dropLast(4)) + ".sqlite"
        }
        throw AppError.internalError(
            module: "PR5b-InMemoryCacheManager",
            detail: "filename must end in .sqlite or .zip (case-insensitive): \(raw)"
        )
    }

    /// caller 已 lock。listAvailable 排序：lastAccessedAt desc → downloadedAt desc → basename desc。
    /// R1-H2 修订：mirror production `DefaultFileSystemCacheManager.swift:253-257`
    /// （basename = `entry.deletingPathExtension().lastPathComponent` = `"\(id)__\(filename_no_ext)"`；
    /// fake 等价比较 `"\(id)__\(filename)"` —— 所有项同 `.sqlite` 后缀，字符串 `>` 与 production 同序）。
    private func sortedLocked() -> [TrainingSetFile] {
        store.values.sorted { lhs, rhs in
            if lhs.lastAccessedAt != rhs.lastAccessedAt { return lhs.lastAccessedAt > rhs.lastAccessedAt }
            if lhs.downloadedAt != rhs.downloadedAt { return lhs.downloadedAt > rhs.downloadedAt }
            return Self.basename(lhs) > Self.basename(rhs)
        }
    }

    private static func basename(_ f: TrainingSetFile) -> String {
        "\(f.id)__\(f.filename)"
    }

    /// caller 已 lock。20-cap 驱逐：保留排序后前 20。
    private func evictIfNeededLocked() {
        if store.count <= Self.maxCachedSets { return }
        let keep = Set(sortedLocked().prefix(Self.maxCachedSets).map(\.id))
        for id in Array(store.keys) where !keep.contains(id) {
            store.removeValue(forKey: id)
        }
    }
}

/// 仅供 InMemoryCacheManagerTests 直接灌入预构造 file（绕过 store 路径，
/// 用于测 listAvailable tiebreaker / 20-cap 驱逐边界）。
/// R1-M2 修订：不嵌套 `#if DEBUG`——本 extension 已在文件级 `#if DEBUG` 块内（line 6 起）。
internal extension InMemoryCacheManager {
    func _seedForTesting(_ files: [TrainingSetFile]) {
        lock.lock(); defer { lock.unlock() }
        for f in files {
            store[f.id] = f
        }
    }
}
```

> **位置**：上面 `// MARK: - P5 fake` 整段（class + extension）放在 `InMemoryFakes.swift` 文件级 `#if DEBUG ... #endif` 块内（既有 line 6 / 文件末 `#endif`），**不再嵌套 second-level `#if DEBUG`**。Class 替换 line 305-316 既有 stub；extension 紧跟 class 后、文件级 `#endif` 之前。

- [ ] **Step 1.4 — 运行测试验证 pass**

Run: `cd ios/Contracts && swift test --filter InMemoryCacheManagerTests`
Expected: 17 个测试函数 PASS

- [ ] **Step 1.5 — 顺手验证 cacheManagerDefaults 仍 pass（不破 PR #40 既有测试）**

> R2-H1 修订：实测 `swift test list` 返回 ID 格式 `KlineTrainerContractsTests.InMemoryFakesTests/cacheManagerDefaults()`——struct 名 `InMemoryFakesTests`（带 Tests 后缀），不是 `@Suite` 显示名 "InMemoryFakes" 也不是文件名 `TrainingSessionCoordinatorTests`。`swift test --filter InMemoryFakesTests` 实测命中 5 个 test ✓（验证：本仓库 `swift test --filter InMemoryFakesTests` 输出 `Test run with 5 tests in 1 suite passed`）。

Run: `cd ios/Contracts && swift test --filter InMemoryFakesTests`
Expected: `Test run with 5 tests in 1 suite passed`（含 `InMemoryCacheManager.listAvailable 返回空 / pickRandom 返回 nil`：fresh fake → empty list / nil pickRandom 仍成立）

- [ ] **Step 1.6 — Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/InMemoryCacheManagerTests.swift
git commit -m "feat(PR5b): InMemoryCacheManager 升级真状态 + 17 行为测试

mirror DefaultFileSystemCacheManager (plan §2):
- filename safety + .zip → .sqlite 规范化
- listAvailable LRU sort (mtime → ctime → id desc)
- store 同 id 替换 / 保留 downloadedAt
- 20-cap evict / touch best-effort / delete 缺失抛 .ioError
- NSLock 串行

fake-specific 简化（plan §2 表）：
- 不读 sqlite (schemaVersion from caller)
- 同 id 单 filename (dict 语义)
- 不模拟 staging / replaceItemAt ctime swap

不破 PR #40 cacheManagerDefaults (fresh fake → empty)。"
```

---

## Task 2: P2 4 个 fake 新增

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/P2Fakes.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/P2FakesTests.swift`

### Step 2.1 — 写 P2 fake 测试（fail first，文件未创建会编译失败）

- [ ] **写测试文件 P2FakesTests.swift**

```swift
import XCTest
@testable import KlineTrainerContracts

#if DEBUG
final class P2FakesTests: XCTestCase {

    // MARK: - FakeZipIntegrityVerifier

    func test_zipIntegrity_default_init_does_not_throw() throws {
        let f = FakeZipIntegrityVerifier()
        XCTAssertNoThrow(try f.verify(zipURL: URL(fileURLWithPath: "/tmp/x.zip"),
                                      expectedCRC32Hex: "deadbeef"))
    }

    func test_zipIntegrity_throwing_init_throws_given_error() {
        let f = FakeZipIntegrityVerifier(throwing: .trainingSet(.crcFailed))
        XCTAssertThrowsError(try f.verify(zipURL: URL(fileURLWithPath: "/tmp/x.zip"),
                                          expectedCRC32Hex: "deadbeef")) { err in
            XCTAssertEqual(err as? AppError, .trainingSet(.crcFailed))
        }
    }

    // MARK: - FakeZipExtractor

    func test_zipExtractor_default_init_returns_default_url() throws {
        let f = FakeZipExtractor()
        let out = try f.extract(zipURL: URL(fileURLWithPath: "/tmp/x.zip"))
        XCTAssertEqual(out, URL(fileURLWithPath: "/tmp/fake.sqlite"))
    }

    func test_zipExtractor_custom_returnURL() throws {
        let custom = URL(fileURLWithPath: "/tmp/custom.sqlite")
        let f = FakeZipExtractor(returnURL: custom)
        XCTAssertEqual(try f.extract(zipURL: URL(fileURLWithPath: "/tmp/x.zip")), custom)
    }

    func test_zipExtractor_throwing_init_throws_given_error() {
        let f = FakeZipExtractor(throwing: .trainingSet(.unzipFailed))
        XCTAssertThrowsError(try f.extract(zipURL: URL(fileURLWithPath: "/tmp/x.zip"))) { err in
            XCTAssertEqual(err as? AppError, .trainingSet(.unzipFailed))
        }
    }

    // MARK: - FakeTrainingSetDataVerifier

    func test_dataVerifier_default_init_does_not_throw() throws {
        let f = FakeTrainingSetDataVerifier()
        let reader = StubReader()
        XCTAssertNoThrow(try f.verifyNonEmpty(reader: reader))
    }

    func test_dataVerifier_throwing_init_throws_given_error() {
        let f = FakeTrainingSetDataVerifier(throwing: .trainingSet(.emptyData))
        XCTAssertThrowsError(try f.verifyNonEmpty(reader: StubReader())) { err in
            XCTAssertEqual(err as? AppError, .trainingSet(.emptyData))
        }
    }

    // MARK: - FakeDownloadAcceptanceCleaner

    func test_cleaner_records_calls_in_order() {
        let c = FakeDownloadAcceptanceCleaner()
        let u1 = URL(fileURLWithPath: "/tmp/a")
        let u2 = URL(fileURLWithPath: "/tmp/b")
        let u3 = URL(fileURLWithPath: "/tmp/c")
        c.cleanup(tempURLs: [u1, u2])
        c.cleanup(tempURLs: [u3])
        XCTAssertEqual(c.cleanedURLs(), [u1, u2, u3])
    }

    func test_cleaner_empty_input_no_op() {
        let c = FakeDownloadAcceptanceCleaner()
        c.cleanup(tempURLs: [])
        XCTAssertTrue(c.cleanedURLs().isEmpty)
    }

    func test_cleaner_concurrent_records_all() {
        let c = FakeDownloadAcceptanceCleaner()
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        for i in 1...20 {
            group.enter()
            q.async {
                c.cleanup(tempURLs: [URL(fileURLWithPath: "/tmp/u\(i)")])
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(c.cleanedURLs().count, 20)
    }

    // MARK: - 辅助 stub reader（fake 不需要真 reader 内容）

    private final class StubReader: TrainingSetReader, @unchecked Sendable {
        func loadMeta() throws -> TrainingSetMeta {
            // 满足 production sanity（mirror PR5a §3 R4 修订占位）
            TrainingSetMeta(stockCode: "PREVIEW", stockName: "Preview Stock",
                            startDatetime: 1, endDatetime: 1)
        }
        func loadAllCandles() throws -> [Period: [KLineCandle]] { [:] }
        func close() {}
    }
}
#endif
```

- [ ] **Step 2.2 — 运行测试验证 fail（文件 P2Fakes.swift 未创建 → 编译错误）**

Run: `cd ios/Contracts && swift test --filter P2FakesTests`
Expected: 编译失败，`Cannot find 'FakeZipIntegrityVerifier' in scope` 等

### Step 2.3 — 实现 P2Fakes.swift（pass）

- [ ] **创建 P2Fakes.swift**

```swift
// Kline Trainer Swift Contracts — PR5b P2 内部端口 Fakes
// Spec: kline_trainer_modules_v1.4.md §11.3 #7-#10 (line 2202-2205)
//
// 4 个 stateless behavior stub，覆盖 P2 4 内部端口（spec §P2 line 1751-1775）。
// 每个 fake 的设计哲学：spec L2202 措辞 "固定返回 OK / 失败" = 配置型 stub，
// 不是 stateful in-memory（与 P4 InMemoryRecordRepository 等 round-trip fake 对比）。
//
// **接口形状**：
// - `init(throwing: AppError? = nil)`：`nil` = success / no-op；非 nil = 该 method 抛该错
// - `FakeZipExtractor` 额外接 `returnURL`（protocol 签名要求返回 URL）
// - `FakeDownloadAcceptanceCleaner` 记录调用列表（production cleanup 不抛、不返回值，
//   唯一可观测点是「被调用了什么 URL」；其它 3 fake 的 throws 路径已是可断言信号）
//
// **不镜像**（不属本 fake 范畴）：
// - NSError → AppError 翻译细节（production internal logic，由 ZipErrorMapping / CacheErrorMapping 测）
// - production 严格 zip shape 校验（exactly 1 sqlite file 等；fake caller 关心的是 throw 与否，不关心翻译路径）

#if DEBUG

import Foundation

// MARK: - P2 port 1 fake

public struct FakeZipIntegrityVerifier: ZipIntegrityVerifying {
    private let throwing: AppError?

    public init(throwing: AppError? = nil) {
        self.throwing = throwing
    }

    public func verify(zipURL: URL, expectedCRC32Hex: String) throws {
        if let err = throwing { throw err }
    }
}

// MARK: - P2 port 2 fake

public struct FakeZipExtractor: ZipExtracting {
    private let throwing: AppError?
    private let returnURL: URL

    public init(returnURL: URL = URL(fileURLWithPath: "/tmp/fake.sqlite"),
                throwing: AppError? = nil) {
        self.returnURL = returnURL
        self.throwing = throwing
    }

    public func extract(zipURL: URL) throws -> URL {
        if let err = throwing { throw err }
        return returnURL
    }
}

// MARK: - P2 port 3 fake

public struct FakeTrainingSetDataVerifier: TrainingSetDataVerifying {
    private let throwing: AppError?

    public init(throwing: AppError? = nil) {
        self.throwing = throwing
    }

    public func verifyNonEmpty(reader: TrainingSetReader) throws {
        if let err = throwing { throw err }
    }
}

// MARK: - P2 port 4 fake (recording)

/// 记录所有 `cleanup` 调用的 URL 顺序，用于测试断言「runner 是否在状态机分支中正确清理临时文件」。
/// production `DefaultDownloadAcceptanceCleaner` 不抛、不返回值——recording 是 fake 唯一观测点。
public final class FakeDownloadAcceptanceCleaner: DownloadAcceptanceCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var _cleanedURLs: [URL] = []

    public init() {}

    public func cleanup(tempURLs: [URL]) {
        lock.lock(); defer { lock.unlock() }
        _cleanedURLs.append(contentsOf: tempURLs)
    }

    /// 按 cleanup 调用顺序展开的 URL 列表（多次调用平铺）。
    public func cleanedURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return _cleanedURLs
    }
}

#endif
```

- [ ] **Step 2.4 — 运行测试验证 pass**

Run: `cd ios/Contracts && swift test --filter P2FakesTests`
Expected: 10 个测试 PASS

- [ ] **Step 2.5 — Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/P2Fakes.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/P2FakesTests.swift
git commit -m "feat(PR5b): 4 P2 内部端口 fake (stateless stubs)

spec §11.3 #7-#10:
- FakeZipIntegrityVerifier (throwing init)
- FakeZipExtractor (throwing init + returnURL)
- FakeTrainingSetDataVerifier (throwing init)
- FakeDownloadAcceptanceCleaner (records cleanedURLs)

10 行为测试 (init throwing 路径 / success 路径 / cleaner 调用记录 / 并发安全)。"
```

---

## Task 3: 验收清单 + spec §11.3 #11 defer note

**Files:**
- Create: `docs/acceptance/2026-05-06-pr5b-port-fixtures.md`

### Step 3.1 — 写中文非 coder 验收清单

- [ ] **写 docs/acceptance/2026-05-06-pr5b-port-fixtures.md**

```markdown
# PR5b 验收清单 — Wave 0 顺位 10 端口域 Fixture

> 本清单面向**非 coder**：每条「动作」可在终端复制粘贴执行；「期望」是看到的输出关键字；「通过条件」二选一非常明确。

**PR 范围：**
- 升级 `InMemoryCacheManager` 从 stub 到真状态 fake（spec §11.3 #6）
- 新增 4 个 P2 内部端口 fake（spec §11.3 #7–#10）
- **不含** `FakeAPIClient`（spec §11.3 #11，已 defer 到 Wave 1，理由见本清单 §5）

---

## 1. 仓库构建编译验证

**动作：**
```
cd ios/Contracts && swift build 2>&1 | tail -10
```

**期望：** 输出末尾包含 `Build complete!`（不含 `error:`）

**通过条件：** 通过 = 看到 `Build complete!`；不通过 = 看到 `error:` 任意一行

---

## 2. PR5b 新增测试全部通过

> R2-H1 修订：filter 用 Swift class/struct 名（不带 target prefix）。

**动作：**
```
cd ios/Contracts && swift test --filter InMemoryCacheManagerTests 2>&1 | tail -5
cd ios/Contracts && swift test --filter P2FakesTests 2>&1 | tail -5
```

**期望：** 两次输出末尾都看到 `with 0 failures` 或 `Test run with N tests in ... passed`，**没有 `failed` 字样**。

**通过条件：** 通过 = 两个 suite 全 `passed`；不通过 = 任一 `failed`

---

## 3. PR #40 既有 InMemoryFakes 测试不破

> R2-H1 修订：`swift test --filter` 用 Swift struct 名（`InMemoryFakesTests`，含 Tests 后缀），不是 `@Suite` 显示名 "InMemoryFakes" 也不是文件名。实测命中 5 测试。

**动作：**
```
cd ios/Contracts && swift test --filter InMemoryFakesTests 2>&1 | tail -5
```

**期望：** 输出含 `Test run with 5 tests in 1 suite passed`，特别确认有 `InMemoryCacheManager.listAvailable 返回空 / pickRandom 返回 nil`（fresh fake 仍成立）

**通过条件：** 通过 = `passed`；不通过 = `failed` 字样

---

## 4. PR5a 既有测试不破

**动作：**
```
cd ios/Contracts && swift test --filter InMemoryDBFakesTests 2>&1 | tail -3
cd ios/Contracts && swift test --filter PreviewTrainingSetReaderTests 2>&1 | tail -3
```

**期望：** 两次输出末尾都含 `with 0 failures` 或 `passed`

**通过条件：** 通过 = 两个 suite 全 `passed`；不通过 = 任一 `failed`

---

## 5. spec §11.3 #11 FakeAPIClient defer 验证

**动作：**
```
grep -rn "protocol APIClient" ios/Contracts/Sources/ 2>&1 | head -3
```

**期望：** **没有命中**（grep 输出为空）。这证明 P1 APIClient Swift protocol 在代码层不存在。FakeAPIClient 无 protocol 可 fake，按 memory rule "B1-B4 backend：推到 Wave 1（与 P1 APIClient 联调一起做）" defer 到 Wave 1 P1 plan。

**通过条件：** 通过 = grep 0 命中；不通过 = grep 命中（说明 P1 已落地，本 PR 应补 FakeAPIClient 不能 defer）

---

## 6. M0.4 AppError 边界 grep（fake 抛 AppError 不泄露内部错误）

**动作：**
```
grep -nE "throw NSError|throw URLError|throw .*Error\\(" ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/P2Fakes.swift 2>&1
```

**期望：** **没有命中**（fake 只抛 `AppError.persistence(...)` / `AppError.internalError(...)` / caller 注入的 `AppError`，不抛 NSError / URLError 等私有错误）

**通过条件：** 通过 = grep 0 命中；不通过 = 任一命中

---

## 7. 总测试数 baseline

**动作：**
```
cd ios/Contracts && swift test 2>&1 | grep -E "Test Suite '.*' (passed|failed)" | tail -1
```

**期望：** 末行是顶层 `Test Suite 'All tests' passed at ...`，无 failed

**通过条件：** 通过 = `passed`；不通过 = `failed`
```

- [ ] **Step 3.2 — Commit**

```bash
git add docs/acceptance/2026-05-06-pr5b-port-fixtures.md
git commit -m "docs(PR5b): 验收清单（中文非 coder 可执行 / spec §11.3 #11 defer 验证）"
```

---

## Self-Review（writing-plans 内置 checklist）

### 1. Spec 覆盖

| spec §11.3 项 | plan 覆盖位置 | ✓ |
|---|---|---|
| #6 InMemoryCacheManager | Task 1（升级真状态）| ✓ |
| #7 FakeZipIntegrityVerifier | Task 2（P2Fakes.swift）| ✓ |
| #8 FakeZipExtractor | Task 2 | ✓ |
| #9 FakeTrainingSetDataVerifier | Task 2 | ✓ |
| #10 FakeDownloadAcceptanceCleaner | Task 2 | ✓ |
| #11 FakeAPIClient | §1 + §10 + 验收清单 §5 显式 defer | ✓（defer）|

PR4a P2 4 production / PR4b P5 production 行为镜像点（plan §2 8 行为 + §3 dict 单 id 简化）：全部在 Step 1.3 实现 / Step 1.1 测试覆盖。

### 2. Placeholder 扫描

无 "TBD"、"add validation"、"similar to ..."；每个 step 都给完整代码块或完整命令；测试代码 19+10 个 case 全部具体。

### 3. 类型一致性

- `TrainingSetFile`：用法（plan §2-3 + Step 1.1 测试 + Step 1.3 实现）字段顺序与 `AppState.swift:130-149` 一致
- `TrainingSetMetaItem`：用法与 `RESTDTOs.swift` 一致
- `AppError.persistence(.ioError(String))`：mirror prod CacheErrorMapping，参数 String detail
- `AppError.internalError(module:detail:)`：spec §M0.4 / `AppError.swift:18`
- `AppError.trainingSet(.crcFailed / .unzipFailed / .emptyData)`：`AppError.swift:43-49`（**没有** `.notFound`，确认）
- protocol 名：`ZipIntegrityVerifying` / `ZipExtracting` / `TrainingSetDataVerifying` / `DownloadAcceptanceCleaning` / `CacheManager`（按 `Sources/KlineTrainerContracts/DownloadAcceptance/` + `Persistence/CacheManager.swift` 实际文件名）
- `TrainingSetReader.loadMeta() throws -> TrainingSetMeta`：与 P2FakesTests StubReader 一致

### 4. 子项硬规则

3 子项 ✓ ；prod LOC ~280 ✓ <500；deferred 1 项（#11）显式声明，理由有 memory rule + grep 证据。

---

## Revision History

### v1.0 → v1.1 (R1: opus 4.7 xhigh adversarial review)

| Finding | 类型 | 修订 |
|---|---|---|
| H-1 | production behavior drift | `delete` 缺失抛 `.trainingSet(.fileNotFound)` 不是 `.persistence(.ioError)`（mirror `CacheErrorMapping.swift:24-25` + production test `delete_nonExistentThrowsFileNotFound`）。§2 行 #7、Step 1.3 实现、Step 1.1 测试 #15 + 测试名 + 测试 case 全部同步改 |
| H-2 | production behavior drift | listAvailable tiebreaker 改 **basename desc** 不是 id desc（mirror `DefaultFileSystemCacheManager.swift:256` `lhs.basename > rhs.basename`）。§2 行 #3、Step 1.3 `sortedLocked` + 加 `basename` helper、Step 1.1 测试 #11 改用跨数量级 id 反例（id=2 vs id=10，basename 字典序 "2__b" > "10__b"） |
| M-1 | acceptance gate filter syntax | `--filter KlineTrainerContractsTests.InMemoryFakesTests` 不命中（无独立文件 + Swift Testing `@Suite` 不与 XCTest 同 filter）→ 改用 `--filter TrainingSessionCoordinatorTests`，按 PR5a acceptance pattern。Step 1.5 + acceptance §3 同步 |
| M-2 | nested `#if DEBUG` 留 implementation 决策 | 直接定死扁平：`_seedForTesting` extension 紧跟 class、文件级 `#endif` 之前；删 plan 自陈"如不编译则改扁平"的 if-then 分支 |
| M-3 | test #15 false-positive 通配 | `case AppError.persistence` 通配改 `XCTAssertEqual(err as? AppError, .trainingSet(.fileNotFound))` 紧 case |
| L-1 | dead Period 提示 | self-review 锚点表删 PR5a 教训复述（本 plan 不直接用 Period.allCases）改成本 plan 用得到的 `AppError.trainingSet` 全 cases 锚点 |
| L-2 | concurrent 测试样本弱 | 加 test #20 `concurrentPerform iterations: 100` 撞同 id slot → 收敛到 1 条（mirror PR4b 模式）|
| L-3 | §2 行 #4 vs §3 文字混层 | 拆出 `§3a 同 id 替换 fake-specific 简化` 段落把"replaceItemAt ctime swap fake 不镜像"从 §2 镜像列搬到 §3a + §10 不在范围 |

R1 收敛 → R2 验收。

### v1.1 → v1.2 (R2: opus 4.7 xhigh 验收 + 新 finding)

R2 verdict = APPROVE（R1 8 项中 7 项真修；M-1 acceptance filter 是搬家未真修，升级为 R2 H-1）。

| Finding | 类型 | 修订 |
|---|---|---|
| R2-H-1 | acceptance gate filter 仍不命中 | 实测 `swift test list` 真实 ID 格式 = `<TargetName>.<SwiftStructName>/<test>()`；修订前 `--filter TrainingSessionCoordinatorTests`（文件名）命中 0 测试。改 `--filter InMemoryFakesTests`（struct 名，本地实测命中 5 测试 ✓）。Step 1.2 / 1.4 / 1.5 / 2.2 / 2.4 + acceptance §2 / §3 / §4 同步全部 filter 删 target prefix + 用 struct 名 |
| R2-M-1 | stale doc comment（delete 抛 case）| Step 1.3 InMemoryCacheManager class doc comment 行 "delete: 缺失抛 .persistence(.ioError)" 改 "缺失抛 .trainingSet(.fileNotFound)" 与代码一致 |
| R2-M-2 | stale doc comment（tiebreaker 排序键）| Step 1.3 class doc comment 行 "listAvailable 排序：... → id desc" 改 "→ basename desc" 与代码一致 |
| R2-L-1 | 测试数字声明三处不一致（17 实际 / 19 / 20）| §7 注一行说明 17 测试函数覆盖 20 语义点（折叠 #7-9 / #16-17）；Step 1.2 / 1.4 / commit message 数字改 17 |
| R2-L-2 | `_seedForTesting` invariant 文档 | LOW，不阻塞；保留为 implementation 期 lint 提示 |
| R2-L-3 | `cleanedURLs()` concurrent 顺序文档 | LOW，不阻塞；保留为 implementation 期 lint 提示 |

R2 收敛 → APPROVE，进 implementation。

## Execution Handoff

**Plan v1.1 complete and saved to `docs/superpowers/plans/2026-05-06-pr5b-port-fixtures.md`.**

Per memory `feedback_subagent_model_selection` + project established workflow，下一步将先做第 2 轮对抗性 review（opus 4.7 xhigh effort 验收 R1 修订），收敛后走 **subagent-driven-development** 派 sonnet 4.6 high effort 实施 Task 1-3。超 5 轮按 `feedback_codex_round6_self_contradiction` reject + escalate 路径。
