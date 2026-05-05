# PR 5a — Fixture/Mock DB-domain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 Wave 0 顺位 9 的 DB-domain 测试 fixture——把 PR #40 在 `InMemoryFakes.swift` 留下的 4 个 P4 stub fake（`InMemoryRecordRepository` / `InMemoryPendingTrainingRepository` / `InMemorySettingsDAO` / `InMemoryAcceptanceJournalDAO`，全部 `fatalError` 或返回空集合）升级为真有内存状态、能 round-trip 的 fake；新增 P3 `PreviewTrainingSetReader` 与升级 `PreviewTrainingSetDBFactory` 走 value-injected 模式。覆盖 spec §11.3（line 2195-2200）DB-domain 5 项；port-domain 6 项（`InMemoryCacheManager` 等）留 PR 5b。

**Architecture:**
- 4 个 P4 fake 保持独立 class（spec §P4 v1.3 修订意图：3-Repo + 1-DAO 独立 mock 粒度，line 1945-1947）；不合并成 `InMemoryAppDB` 巨石
- 内部状态 = pure Swift `Dictionary` / 单值 slot，无文件系统、无 GRDB；线程安全用 `NSLock` 包裹（`@unchecked Sendable` 已是 PR #40 约定）
- 全部 `#if DEBUG` guard（PR #40 文件级既有约定，与 spec L1671-1713 preview Fixture 一致：fakes 不进 Release binary）
- `PreviewTrainingSetReader` = 新增 `final class` + value-injected `meta` + `candles`；`PreviewTrainingSetDBFactory` 升级为 init 接收 `meta` + `candles`，`openAndVerify` 忽略 `file` 参数返回内置 reader（带 default 空构造保 PR #40 既有 callsite 不破）
- 不动 `InMemoryCacheManager`（PR 5b scope）；不动协议签名（`KlineTrainerContracts/Persistence/*.swift`）
- 测试在已有 `KlineTrainerContractsTests` target 内新增 `InMemoryFakesTests.swift` + 1 个 `PreviewTrainingSetReaderTests.swift`；现有 `AcceptanceJournalDAOContractTests` 的 `Wave 0 fake 不实际持久化` 行为断言要随升级翻面（旧断言已矛盾于 PR 5a 目标）

**Tech Stack:** Swift 6.0 / SwiftPM / Foundation / `NSLock` / XCTest

---

## File Structure

| 文件 | 责任 | 状态 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | 4 个 P4 fake 升级为真 in-memory 状态；`PreviewTrainingSetDBFactory` 升级为 value-injected | Modify |
| `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/PreviewTrainingSetReader.swift` | 新增 P3b 预览 reader：constructor-injected meta + candles | Create |
| `ios/Contracts/Tests/KlineTrainerContractsTests/InMemoryFakesTests.swift` | 4 个 P4 fake 行为测试：round-trip insert/list、save/load/clear、resetCapital → 0、upsert 同 (id,lease) 替换、listByState 过滤、deleteByIdLease 0 行删除合法、stateEnteredAt 单调、并发安全 | Create |
| `ios/Contracts/Tests/KlineTrainerContractsTests/PreviewTrainingSetReaderTests.swift` | reader meta/candles 透传 + factory 透传 reader + close() 是 no-op | Create |
| `ios/Contracts/Tests/KlineTrainerContractsTests/AcceptanceJournalDAOContractTests.swift` | 升级 `test_InMemoryAcceptanceJournalDAO_can_instantiate_and_satisfies_protocol`：从「不持久化」翻面成 round-trip 行为断言 | Modify |
| `docs/acceptance/2026-05-05-pr5a-db-fixtures.md` | 验收清单（中文，非 coder 可执行）| Create |

**预估 prod LOC（硬规则 ≤500；R1 / R2 / R3 修订上调）：**
- `InMemoryFakes.swift` 净增 ≈ 215 LOC（4 fake 各加内部状态 + lock + 真实 method 体；AcceptanceJournalDAO 全镜像 production state machine + invariants + COALESCE +60 LOC；R2 SettingsDAO finite-value guard +12 LOC；PreviewTrainingSetDBFactory 升级 +15 LOC）
- `PreviewTrainingSetReader.swift` 新增 ≈ 110 LOC（init / loadMeta / loadAllCandles / close + R2 isClosed lock + ensureOpen + R3 validateCandles helper ~50 LOC）
- 合计：**≈ 325 prod LOC** ✓ 仍低于 500 上限

**预估 test LOC**：≈ 580（R1 加 state machine 12 + id-tiebreak 2 +100；R2 加 NaN/inf 2 + close-then-read 1 +50；R3 加 candle 校验 9 +150 行）

**子项数**（per memory feedback "硬规则 ≤3 子项"）：
1. P4 4 fake 升级（一个文件内的内聚改动，spec 列在同一 §11.3 子清单 #1-4）
2. P3 PreviewTrainingSetReader + factory 升级（spec §11.3 #5 配对）
3. 验收清单 + 已有测试翻面修订
合计 **3 子项** ✓

---

## Design Decisions（plan-time 锁定，codex review 抓变动）

### §1 不合并 4 个 P4 fake 为一个 `InMemoryAppDB` 巨石

**Spec 字面证据：**
- L1865 spec 解释 v1.3 拆分：「原单一 `protocol AppDB` 把 record / pending / settings 全塞在一个端口，**违反 §零原则 4（独立验收 Mock 粒度过大）**」
- L1945-1947 显式 Mock 粒度收益：「`SettingsStore` 只依赖 `SettingsDAO`，Mock 三个方法即可」「`TrainingSessionCoordinator` 依赖 `RecordRepository + PendingTrainingRepository`，**不需要 Mock settings 路径**」
- §11.3（L2195-2200）测试 fixture 清单按 4 个独立类列出，不是 1 个

**3 选项评估：**

| 方案 | 优点 | 缺点 | 选/拒 |
|---|---|---|---|
| **A. 4 个独立 class（spec 直译）** | mock 粒度 = protocol 粒度；spec literal；PR #40 既有 stub 形状一致 | 4 个 lock，更多重复 init 样板 | ✅ 选 |
| B. 单 `InMemoryAppDB` 实现 4 协议复合 | 一处 lock；少行数 | 违反 spec L1865 拆分意图；测试要 mock SettingsDAO 时被迫拖入 RecordRepository 状态 | ❌ 拒 |
| C. shared `InMemoryStore` 类 + 4 个 wrapper class 转发 | mock 粒度保持 + 共享状态 | 3 层间接；fake 不做跨协议事务，没有共享必要 | ❌ 拒（YAGNI） |

**结论**：选 A。`production` 端 `DefaultAppDB` 在 spec L1931 用 `typealias AppDB = RecordRepository & PendingTrainingRepository & SettingsDAO & AcceptanceJournalDAO` 复合，是「生产侧合成 root」；fake 端故意不合成、保持独立 mock 粒度。

### §2 线程安全 = `NSLock`，不用 `actor`

**理由：**
- protocol 体全部 sync `throws`（不是 `async`），actor 包裹后 `await` 调用所有 method 会强制改 protocol 签名 → trust-boundary change 出 PR5a scope
- PR #40 已经把所有 fake 标 `@unchecked Sendable`，约定就是「自管同步」
- `NSLock` ≈ 5 行样板（`lock.lock(); defer { lock.unlock() }; ...`），重复 4 份可以接受；Swift `Mutex` 仅 macOS 15+，iOS 17 不支持

**反驳「为什么不 `DispatchQueue.sync`」：** 同步路径上 `NSLock` 比 queue thunk 快 ~10x；fake 不在性能 hot path 上但「不用 queue 也无成本」。

### §3 `PreviewTrainingSetDBFactory` 升级 = init(meta:candles:) + 默认空构造

**Spec literal**：`func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader`（L1830）

**Reality**：fake 在 preview / 单测里没有真 sqlite 文件可打开，`file:` 参数注定被忽略；spec §15.1 #9（L2456）只要求 `TrainingEngine.preview(mode:)` 能在 `#Preview` 渲染——意味着 fake 必须返回**有意义的 reader**（载入 fixture candles）。

**接口形状选择：**
- factory 加 `public init(meta: TrainingSetMeta? = nil, candles: [Period: [KLineCandle]] = [:])`
- `openAndVerify` 忽略 `file` / `expectedSchemaVersion`，把构造期注入的 meta+candles 包成 reader 返回
- meta 为 nil 时（PR #40 既有空构造 callsite）返回带「占位 meta」的 reader：`TrainingSetMeta(stockCode: "PREVIEW", stockName: "Preview Stock", startDatetime: 0, endDatetime: 0)`——保 callsite 不破

**为什么不让 `openAndVerify` 抛 `fileNotFound`：** spec L1832 错误清单是 production 行为；fake 设计就是「不 open file」，模拟「永远成功」更适配 preview 场景。

### §4 `InMemoryRecordRepository.statistics` + `listRecords` 计算口径（R1 修订：含 id DESC tiebreaker）

**Spec 字面无 statistics SQL 给出**（L1870 仅给 protocol 签名）。Production `RecordRepositoryImpl`（`Internal/RecordRepositoryImpl.swift`）：
- `listRecords`：`ORDER BY created_at DESC, id DESC` + 可选 `LIMIT ?`（line 60）
- `statistics`：
  - `totalCount` = `COUNT(*)`
  - `winCount` = `COUNT(profit > 0)`
  - `currentCapital` = `latest.totalCapital + latest.profit`（按 `created_at DESC, id DESC LIMIT 1`，line 99），无记录时 = 0

**R1 修订（codex round-1 med-2）**：production 把 `id DESC` 加进 tiebreaker 是 codex med-1 的修订（line 58 注释明示）；fake 必须**同口径**镜像，否则同 createdAt 多条插入时 fake/production 行为分叉，使用方测试失败模式不一致。

Fake 实现：
- `nextId` 自增 → records 字典的 key（`var records: [Int64: TrainingRecord]`）
- `listRecords`：`records.values.sorted { ($0.createdAt, $0.id ?? 0) > ($1.createdAt, $1.id ?? 0) }` 用 lexicographic tuple 比较实现 `(createdAt desc, id desc)`
- `statistics().currentCapital`：用同 sort 取首条
- 加测试：3 条 record `createdAt = 100`，按 insert 顺序 id = 1/2/3，断言 `listRecords[0].id == 3`（id 最大者排首）+ `statistics().currentCapital` 用第 3 条计算

### §5 `InMemorySettingsDAO` = resetCapital 只置 0 + saveSettings 拒 NaN/inf（R2 修订：codex round-2 med-2）

**Production 行为 1**（`SettingsDAOImpl.resetCapital`，line 87-91）：`UPDATE settings SET total_capital = '0.0'`，**只动 totalCapital，不动其他字段**。Fake 镜像同口径。

**R2 修订（codex round-2 med-2）—— Production 行为 2**（`SettingsDAOImpl.saveSettings`，line 62-85）：在写入前拒非有限值：
- `commissionRate` 若不是 finite（NaN / +inf / -inf）→ `throw AppError.internalError(module: "P4-SettingsDAO", detail: "saveSettings refused: commissionRate not finite (...)")`
- `totalCapital` 若不是 finite → 同上 detail 改 totalCapital

Fake 必须镜像同 guard：
- `saveSettings` 检查 `s.commissionRate.isFinite && s.totalCapital.isFinite`
- 任一不 finite → `throw AppError.internalError(module: "PR5a-InMemorySettingsDAO", detail: "saveSettings refused: ...")`
- **不修改内部 settings 字段**（mirror production 拒收前直接抛，不动 DB row）

**为什么必须**：若 fake 接受 NaN/inf 然后 round-trip 出去，使用 fake 写的测试会让 SettingsStore 等下游模块的 fee/P&L 计算被 NaN 污染（production 拒收，fake 接受）—— 计算路径相关测试会出现 fake-pass / production-fail 分叉。

### §6 `InMemoryAcceptanceJournalDAO` 镜像 production state machine + invariants + COALESCE（R1 修订：codex round-1 high-1）

**Spec 主键**（M0.1 line 230-289 `download_acceptance_journal`）：`UNIQUE(training_set_id, lease_id)`。Fake 用 `[String: AcceptanceJournalRow]` 字典，key = `"\(trainingSetId)::\(leaseId)"`。

**`stateEnteredAt`**（spec L241）：`Int64` Unix 秒 UTC，由实现侧 stamp。Fake 在每次接受的 `upsert` 时 `Int64(Date().timeIntervalSince1970)`。

**`id` 自增**：fake 用 `var nextId: Int64 = 1`，每次接受的 `upsert` **新行**（key 不存在）时 ++；已存在 key 的 upsert **保留原 id**（mirror SQLite UNIQUE 约束 + REPLACE 行为）。

**R1 修订（codex round-1 high-1）—— 镜像 `AcceptanceJournalDAOImpl` 全部 production guards**：

Production `AcceptanceJournalDAOImpl.upsert`（`Internal/AcceptanceJournalDAOImpl.swift` line 71-120）执行的逻辑：

1. **首插必须 `.downloaded`**：`(training_set_id, lease_id)` 不存在时，`state != .downloaded` → `throw AppError.internalError(...)`（line 102-106）
2. **next-state allowlist**（`nextAllowed` map line 18-29）：
   - `.downloaded → {.crcOK, .rejected}`
   - `.crcOK → {.unzipped, .rejected}`
   - `.unzipped → {.dbVerified, .rejected}`
   - `.dbVerified → {.stored, .rejected}`
   - `.stored → {.confirmPending, .rejected}`
   - `.confirmPending → {.confirmed, .rejected}`
   - `.confirmed → {}`（吸收）
   - `.rejected → {}`（吸收）
3. **同 state retry 允许**（`canApply` line 36 `if new == old { return true }`）：用于失败重试同 state 续 stamp
4. **不合法转换 = silent NOOP**（line 90-92 `logger.info` + `return`）—— **不抛错**
5. **state-dependent invariants**（`validateInvariants` line 43-63）：
   - `state ∈ {.stored, .confirmPending, .confirmed}` 时 `resolvedPath = newPath ?? existingPath` 必须非 nil，否则 throw
   - `state == .stored` 时 `resolvedHash` 必须是 8-char 小写 hex CRC32，否则 throw
6. **COALESCE 字段保留**（line 131-133 `COALESCE(?, last_error)` / `COALESCE(?, sqlite_local_path)` / `COALESCE(?, content_hash)`）：upsert 传 nil 时**保留 existing 值**，不覆盖

Fake 必须复刻同样行为，否则 P2 runner / E6 coordinator 等使用 fake 写的测试会接受 production 拒绝的非法 sequence（codex round-1 finding 1 verbatim：`downloaded → stored`、`confirmed → rejected`、缺 stored metadata、nil retries 擦掉 path/hash 等）。

**fake 实现位置**：在 `InMemoryAcceptanceJournalDAO` 内部加 3 个 private static helper（`nextAllowed` / `canApply` / `validateInvariants` / `isValidCRC32Hex`）—— 直接照抄 production 函数体（不 import production 模块；这是允许的代码克隆，源在 `KlineTrainerPersistence` 模块且 fake 在 `KlineTrainerContracts` DEBUG-only，跨模块依赖会破 wave 0 拓扑）。文件头加注释明示「mirror of `AcceptanceJournalDAOImpl` line 14-138；production 改 → fake 同步改」并在 plan §6 + 文件 SS-1 处双重 anchor。

**`AppError.internalError(module:detail:)` 复用**：fake 抛错时 `module: "PR5a-InMemoryAcceptanceJournalDAO"` 与 production 同 case 但区分 module 字段（便于排查）。

**fake-specific 简化**：production logger.info NOOP / logger.error refuse 路径，fake 不 emit log（fake 不持有 `os.Logger` 资源）；只静默 NOOP / 抛错。

### §7 `PreviewTrainingSetReader` 是 class + 镜像 production isClosed 生命周期 + 数据校验（R2/R3 修订）

**Spec literal**：`public protocol TrainingSetReader: AnyObject, Sendable`（L1842）—— `AnyObject` 强制 reference type。`final class` + immutable stored property + `@unchecked Sendable`（值 capture 后不变）。

**R2 修订（codex round-2 high-1）—— 镜像 `DefaultTrainingSetReader` 的 isClosed 生命周期**：

Production `DefaultTrainingSetReader` (`KlineTrainerPersistence/DefaultTrainingSetReader.swift` line 15-16, 184-191)：
- `isClosed` Bool flag + `NSLock`
- `close()` 设 `isClosed = true` + queue = nil 释放 ARC
- `ensureOpen()` 检查 `!isClosed` 否则 `throw AppError.internalError(module: "P3b", detail: "reader closed")`
- `loadMeta()` / `loadAllCandles()` 都先 `try ensureOpen()`

Fake 必须镜像同生命周期：
- 加 `private var isClosed: Bool = false` + `private let lock = NSLock()`
- `close()` lock 内设 `isClosed = true`
- `loadMeta()` / `loadAllCandles()` lock 内检查 `isClosed`，若 closed `throw AppError.internalError(module: "PR5a-PreviewTrainingSetReader", detail: "reader closed")`

**为什么必须**：若 fake `close()` 是 no-op，consumer 误用 close 后再 read 的代码在 fake 上通过测试，到 production 撞 `.internalError` 崩溃。fake/production 行为发散就是 codex round-2 finding 1 拒收的根因。

**R3 修订（codex round-3 high-1）—— 镜像 production 数据校验**：

Production `DefaultTrainingSetReader.loadAllCandles()` (`KlineTrainerPersistence/DefaultTrainingSetReader.swift` line 28-174) 在返回 candles 前做大量校验：

1. **OHLC finite + positive**（line 97-100）：`open / high / low / close` 都必须 `.isFinite && > 0`
2. **OHLC 序关系**（line 101-102）：`high >= max(open, close, low)` AND `low <= min(open, close, high)`
3. **volume 非负**（line 103）：`volume >= 0`
4. **可选指标 finite**（line 107-112）：`amount / ma66 / boll{Upper,Mid,Lower} / macd{Diff,Dea,Bar}` 若非 nil 必须 finite
5. **amount 非负**（line 113-115）：`amount` 若非 nil 必须 ≥ 0
6. **endGlobalIndex per-period 严格递增**（line 90-93）：相邻同 period candle 必须 strict increasing
7. **非 m3 endGlobalIndex 非负**（line 137-143）：除 m3 外所有 period 的 endGlobalIndex 必须 ≥ 0
8. **m3 global-axis 不变量**（line 153-160）：m3 candle 必须 `globalIndex == endGlobalIndex == array index`（即从 0 开始严格递增 0, 1, 2, ...）
9. **非 m3 endGlobalIndex ≤ m3Max**（line 162-168）：其它 period 的 endGlobalIndex 不超过 m3 最大 endGlobalIndex
10. **m3 缺失但 result 非空 → 拒**（line 169-172）：除非整库 result 全空（允许）

任一违反 → `throw AppError.persistence(.dbCorrupted)`。

Fake 必须镜像同套校验，否则 consumer 依赖「reader 返回 = 已校验」的代码（如 chart geometry 假设 OHLC 正、E5 二分查找假设 globalIndex 单调）会在 fake 上通过测试，到 production 因数据 reject 失败。

**实现位置**：`PreviewTrainingSetReader` 内部加 `private static func validateCandles(_ candles:) throws`，在 `loadAllCandles()` 内 close 检查后调用：

```swift
public func loadAllCandles() throws -> [Period: [KLineCandle]] {
    try ensureOpen()
    try Self.validateCandles(candles)
    return candles
}
```

**fake-specific 简化**：production 在 SQL 层先做 `typeof()` 校验（line 36-58）防 silent coerce — fake 入参本身已是 typed `KLineCandle`（Swift 静态类型，无 coerce 风险），跳过 typeof 那一段。production 也在 raw `KLineRow` 上做校验后再构造 `KLineCandle` — fake 反过来在 `KLineCandle` 上直接读 property 校验。

**已存在 fake 注入路径**：`PreviewTrainingSetDBFactory(meta:candles:)` 默认 `candles: [:]`（空字典）—— 空字典无 m3，但**也无非空 result**，符合 line 169-172 的「整库 result 全空允许」分支，validateCandles 通过。所以 PR #40 既有空构造 callsite 不破。

### §8 不在 PR5a 内做 Preview Fixture 数据（KLineCandle.previewFixture / FeeSnapshot.preview / TrainingRecord.previewRecord）

**Spec §11.3 (line 2188-2194)** 列了 6 项 Preview Fixture 数据，与 §11.3 (line 2195-2200) 11 项 Test Fixture Ports 是**两个独立清单**。v6 outline PR5a/5b 拆分对应**后者的前 5 / 后 6**；前者 6 项 Preview 数据已由 PR #40（`SettingsStore.preview()` + `TrainingSessionCoordinator.preview()` callsite）部分落地，剩余几项 v6 outline 未列入 Wave 0 强制锚——按「实施 plan 打包偏差」memory rule，**不超 scope 提前合并**。若 codex 提，按 spec 双清单引用 reject。

---

## Task 1: 4 个 P4 in-memory fake 升级为真状态

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/InMemoryFakesTests.swift`

### Step 1.1 — 写 4 个 P4 fake 行为测试（fail first）

- [ ] **写测试文件 InMemoryFakesTests.swift（XCTest，与 `AcceptanceJournalDAOContractTests` 同 target `KlineTrainerContractsTests`）**

> **类型签名锚点（按当前 `Models.swift` / `AppState.swift` / `AppError.swift` 真实形状）：**
> - `Period` cases：`m3 / m15 / m60 / daily / weekly / monthly`（**没有 `.day` / `.min15`**；测试用 `.daily` + `.m15`）
> - `PositionTier` cases：`tier1 / tier2 / tier3 / tier4 / tier5`（**没有 `.heavy`**；测试用 `.tier3`）
> - `DrawingToolType` cases：`ray / trend / horizontal / golden / wave / cycle / time`（**没有 `.horizontalLine`**；测试用 `.horizontal`）
> - `DrawingObject(toolType:, anchors:, isExtended:, panelPosition:)`（**没有 `id` / `createdAt` / `tool`**）
> - `KLineCandle(period:, datetime:, open:, high:, low:, close:, volume:, amount:, ma66:, bollUpper:, bollMid:, bollLower:, macdDiff:, macdDea:, macdBar:, globalIndex:, endGlobalIndex:)`
> - `AppError.persistence` cases：`diskFull / dbCorrupted / schemaMismatch / ioError`（**没有 `.notFound`**；fake 缺 record 抛 `.dbCorrupted` 与 production `RecordRepositoryImpl.swift` line 74 同步）

```swift
import XCTest
@testable import KlineTrainerContracts

#if DEBUG
final class InMemoryFakesTests: XCTestCase {

    // MARK: - InMemoryRecordRepository

    func test_recordRepo_insertRecord_assigns_id_and_persists() throws {
        let repo = InMemoryRecordRepository()
        let rec = makeRecord(id: nil, profit: 100, total: 1000)
        let id = try repo.insertRecord(rec, ops: [], drawings: [])
        XCTAssertEqual(id, 1)
        let listed = try repo.listRecords(limit: nil)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, 1)  // server-assigned id 写回
    }

    func test_recordRepo_loadRecordBundle_returns_inserted_ops_and_drawings() throws {
        let repo = InMemoryRecordRepository()
        let op = makeOp(direction: .buy)
        let dr = makeDrawing()
        let id = try repo.insertRecord(makeRecord(id: nil), ops: [op], drawings: [dr])
        let bundle = try repo.loadRecordBundle(id: id)
        XCTAssertEqual(bundle.0.id, id)
        XCTAssertEqual(bundle.1.count, 1)
        XCTAssertEqual(bundle.1.first?.direction, .buy)
        XCTAssertEqual(bundle.2.count, 1)
    }

    func test_recordRepo_loadRecordBundle_throws_dbCorrupted_for_unknown_id() {
        // mirror production RecordRepositoryImpl.swift line 74
        let repo = InMemoryRecordRepository()
        XCTAssertThrowsError(try repo.loadRecordBundle(id: 999)) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                XCTFail("expected .dbCorrupted, got \(err)"); return
            }
        }
    }

    func test_recordRepo_listRecords_limit_and_order_desc_by_createdAt() throws {
        let repo = InMemoryRecordRepository()
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 300), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 200), ops: [], drawings: [])
        let all = try repo.listRecords(limit: nil)
        XCTAssertEqual(all.map(\.createdAt), [300, 200, 100])
        let topTwo = try repo.listRecords(limit: 2)
        XCTAssertEqual(topTwo.count, 2)
        XCTAssertEqual(topTwo.map(\.createdAt), [300, 200])
    }

    /// R1 修订（codex round-1 med-2）：同 createdAt 多条时按 id DESC tiebreak（mirror production line 60）
    func test_recordRepo_listRecords_id_desc_tiebreaker_for_same_createdAt() throws {
        let repo = InMemoryRecordRepository()
        // 3 条 createdAt 全 = 100；插入顺序赋 id = 1, 2, 3
        let id1 = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 1), ops: [], drawings: [])
        let id2 = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 2), ops: [], drawings: [])
        let id3 = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 3), ops: [], drawings: [])
        XCTAssertEqual([id1, id2, id3], [1, 2, 3])

        let all = try repo.listRecords(limit: nil)
        // (createdAt desc, id desc) → id 3 / 2 / 1
        XCTAssertEqual(all.map(\.id), [3, 2, 1])
    }

    func test_recordRepo_statistics_currentCapital_uses_latest_by_createdAt() throws {
        let repo = InMemoryRecordRepository()
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 100, total: 1000), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 200, profit: 200, total: 1000), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 300, profit: -50, total: 1000), ops: [], drawings: [])
        let s = try repo.statistics()
        XCTAssertEqual(s.totalCount, 3)
        XCTAssertEqual(s.winCount, 2)
        XCTAssertEqual(s.currentCapital, 1000 + (-50))
    }

    /// R1 修订（codex round-1 med-2）：statistics.currentCapital 同 createdAt 时取 id 最大者（mirror production line 99）
    func test_recordRepo_statistics_id_desc_tiebreaker_for_same_createdAt() throws {
        let repo = InMemoryRecordRepository()
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 100, total: 1000), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: 200, total: 1000), ops: [], drawings: [])
        _ = try repo.insertRecord(makeRecord(id: nil, createdAt: 100, profit: -50, total: 1000), ops: [], drawings: [])
        // 最后插入 id=3 的 profit=-50；同 createdAt 下 id 最大胜出
        let s = try repo.statistics()
        XCTAssertEqual(s.currentCapital, 1000 + (-50))
    }

    func test_recordRepo_statistics_empty_returns_zero() throws {
        let repo = InMemoryRecordRepository()
        let s = try repo.statistics()
        XCTAssertEqual(s.totalCount, 0)
        XCTAssertEqual(s.winCount, 0)
        XCTAssertEqual(s.currentCapital, 0)
    }

    // MARK: - InMemoryPendingTrainingRepository

    func test_pendingRepo_save_load_clear_round_trip() throws {
        let repo = InMemoryPendingTrainingRepository()
        XCTAssertNil(try repo.loadPending())

        try repo.savePending(makePending(filename: "S001.sqlite"))
        XCTAssertEqual(try repo.loadPending()?.trainingSetFilename, "S001.sqlite")

        try repo.savePending(makePending(filename: "S002.sqlite"))
        XCTAssertEqual(try repo.loadPending()?.trainingSetFilename, "S002.sqlite")

        try repo.clearPending()
        XCTAssertNil(try repo.loadPending())

        // clear 在已 nil 时合法
        try repo.clearPending()
    }

    // MARK: - InMemorySettingsDAO

    func test_settingsDAO_default_load_returns_zero_AppSettings() throws {
        let dao = InMemorySettingsDAO()
        let s = try dao.loadSettings()
        XCTAssertEqual(s.commissionRate, 0)
        XCTAssertEqual(s.totalCapital, 0)
        XCTAssertFalse(s.minCommissionEnabled)
        XCTAssertEqual(s.displayMode, .system)
    }

    func test_settingsDAO_save_then_load_round_trip() throws {
        let dao = InMemorySettingsDAO()
        let s = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: 50_000, displayMode: .dark)
        try dao.saveSettings(s)
        XCTAssertEqual(try dao.loadSettings(), s)
    }

    func test_settingsDAO_resetCapital_only_zeroes_totalCapital() throws {
        let dao = InMemorySettingsDAO()
        try dao.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: 50_000, displayMode: .dark))
        try dao.resetCapital()
        let after = try dao.loadSettings()
        XCTAssertEqual(after.totalCapital, 0)
        XCTAssertEqual(after.commissionRate, 0.0003)
        XCTAssertTrue(after.minCommissionEnabled)
        XCTAssertEqual(after.displayMode, .dark)
    }

    /// R2 修订（codex round-2 med-2）：mirror production saveSettings 拒 NaN / +inf / -inf
    func test_settingsDAO_saveSettings_rejects_nonfinite_commissionRate_and_does_not_mutate() throws {
        let dao = InMemorySettingsDAO()
        let baseline = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: 1000, displayMode: .dark)
        try dao.saveSettings(baseline)

        for bad in [Double.nan, .infinity, -.infinity] {
            let payload = AppSettings(commissionRate: bad, minCommissionEnabled: true, totalCapital: 1000, displayMode: .dark)
            XCTAssertThrowsError(try dao.saveSettings(payload)) { err in
                guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
            }
        }
        // 拒收后 settings 未被改（仍是 baseline）
        XCTAssertEqual(try dao.loadSettings(), baseline)
    }

    func test_settingsDAO_saveSettings_rejects_nonfinite_totalCapital_and_does_not_mutate() throws {
        let dao = InMemorySettingsDAO()
        let baseline = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: 1000, displayMode: .dark)
        try dao.saveSettings(baseline)

        for bad in [Double.nan, .infinity, -.infinity] {
            let payload = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true, totalCapital: bad, displayMode: .dark)
            XCTAssertThrowsError(try dao.saveSettings(payload)) { err in
                guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
            }
        }
        XCTAssertEqual(try dao.loadSettings(), baseline)
    }

    // MARK: - InMemoryAcceptanceJournalDAO（R1 修订：state machine + invariants + COALESCE 全镜像 production）

    // 1) 首插必须 .downloaded
    func test_journalDAO_first_insert_must_be_downloaded() {
        let dao = InMemoryAcceptanceJournalDAO()
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK,
                                            sqliteLocalPath: nil, contentHash: nil, lastError: nil)) { err in
            guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
        }
        // .downloaded OK
        XCTAssertNoThrow(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                                        sqliteLocalPath: nil, contentHash: nil, lastError: nil))
    }

    // 2) 合法转换 downloaded → crcOK 接受
    func test_journalDAO_legal_transition_downloaded_to_crcOK() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                       sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK,
                       sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try dao.listByState(.downloaded).count, 0)
        XCTAssertEqual(try dao.listByState(.crcOK).count, 1)
    }

    // 3) 跳跃转换 = silent NOOP（不抛、不改 state）—— mirror production logger.info + return
    func test_journalDAO_skip_transition_downloaded_to_stored_is_noop() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                       sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        // 越级到 .stored —— 即使带齐 path+hash，也应被 nextAllowed 拒（NOOP）
        XCTAssertNoThrow(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                        sqliteLocalPath: "/tmp/x.sqlite", contentHash: "deadbeef",
                                        lastError: nil))
        // state 仍是 .downloaded
        XCTAssertEqual(try dao.listByState(.stored).count, 0)
        XCTAssertEqual(try dao.listByState(.downloaded).count, 1)
    }

    // 4) 终态 confirmed 不可再转
    func test_journalDAO_terminal_confirmed_to_rejected_is_noop() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        // 走完 downloaded → ... → confirmed
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified, sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored, sqliteLocalPath: "/tmp/x.sqlite", contentHash: "deadbeef", lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .confirmPending, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .confirmed, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try dao.listByState(.confirmed).count, 1)

        // confirmed → rejected = NOOP
        XCTAssertNoThrow(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .rejected,
                                        sqliteLocalPath: nil, contentHash: nil, lastError: "x"))
        XCTAssertEqual(try dao.listByState(.confirmed).count, 1) // 仍 confirmed
        XCTAssertEqual(try dao.listByState(.rejected).count, 0)
    }

    // 5) 任何 state 都可推 .rejected（除终态）
    func test_journalDAO_any_state_to_rejected_allowed() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .rejected, sqliteLocalPath: nil, contentHash: nil, lastError: "fail")
        XCTAssertEqual(try dao.listByState(.rejected).count, 1)
        XCTAssertEqual(try dao.listByState(.rejected).first?.lastError, "fail")
    }

    // 6) 同 state retry 允许（new == old → canApply true，重新 stamp）
    func test_journalDAO_same_state_retry_allowed_and_stamp_advances() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                       sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let firstAt = try XCTUnwrap(try dao.listByState(.downloaded).first?.stateEnteredAt)
        Thread.sleep(forTimeInterval: 1.05)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded,
                       sqliteLocalPath: nil, contentHash: nil, lastError: "retry")
        let secondAt = try XCTUnwrap(try dao.listByState(.downloaded).first?.stateEnteredAt)
        XCTAssertGreaterThan(secondAt, firstAt)
    }

    // 7) state ∈ {.stored, .confirmPending, .confirmed} 缺 sqliteLocalPath → throw
    func test_journalDAO_stored_requires_path() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        // 走到 .dbVerified（合法且不要 path——production validateInvariants 只对 stored/confirmPending/confirmed 要 path）
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified, sqliteLocalPath: nil, contentHash: nil, lastError: nil)

        // .stored 缺 path 应抛
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: nil, contentHash: "deadbeef", lastError: nil)) { err in
            guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
        }
    }

    // 8) .stored 缺 contentHash / hash 非 8-char 小写 hex → throw
    func test_journalDAO_stored_requires_valid_crc32_hex() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified, sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: nil)

        // hash nil
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: nil))
        // hash 长度错（7 字符）
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: "/tmp/x.sqlite", contentHash: "deadbee", lastError: nil))
        // hash 大写（production 要小写）
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: "/tmp/x.sqlite", contentHash: "DEADBEEF", lastError: nil))
        // hash 含非 hex 字符
        XCTAssertThrowsError(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                            sqliteLocalPath: "/tmp/x.sqlite", contentHash: "zzzzzzzz", lastError: nil))
        // 合法 8-char 小写 hex 通过
        XCTAssertNoThrow(try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                                        sqliteLocalPath: "/tmp/x.sqlite", contentHash: "deadbeef", lastError: nil))
    }

    // 9) COALESCE：nil 入参不覆盖 existing 字段
    func test_journalDAO_coalesce_preserves_existing_path_and_hash_on_nil_inputs() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .unzipped, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .dbVerified, sqliteLocalPath: "/tmp/x.sqlite", contentHash: nil, lastError: "first")
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored, sqliteLocalPath: nil, contentHash: "deadbeef", lastError: nil)

        // .stored 入参 sqliteLocalPath = nil；COALESCE 应保留 .dbVerified 时写入的 "/tmp/x.sqlite"
        let row = try XCTUnwrap(try dao.listByState(.stored).first)
        XCTAssertEqual(row.sqliteLocalPath, "/tmp/x.sqlite")  // 未被 nil 覆盖
        XCTAssertEqual(row.contentHash, "deadbeef")            // 新写入
        XCTAssertEqual(row.lastError, "first")                 // 未被 nil 覆盖

        // 再 upsert 同 state 带新 lastError，hash 入 nil → 保留 deadbeef
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .stored,
                       sqliteLocalPath: nil, contentHash: nil, lastError: "second")
        let row2 = try XCTUnwrap(try dao.listByState(.stored).first)
        XCTAssertEqual(row2.contentHash, "deadbeef")
        XCTAssertEqual(row2.lastError, "second")
    }

    // 10) upsert 合法转换保留 id（mirror SQLite UNIQUE + REPLACE）
    func test_journalDAO_legal_transition_keeps_id() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let firstId = try XCTUnwrap(try dao.listByState(.downloaded).first?.id)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .crcOK, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        XCTAssertEqual(try dao.listByState(.crcOK).first?.id, firstId)
    }

    // 11) listByState 按 id ASC（mirror production line 143 ORDER BY id ASC）
    func test_journalDAO_listByState_orders_by_id_asc() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.upsert(trainingSetId: 2, leaseId: "L2", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.upsert(trainingSetId: 3, leaseId: "L3", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        let rows = try dao.listByState(.downloaded)
        XCTAssertEqual(rows.map(\.id), [1, 2, 3]) // 按 insertion id ASC
    }

    // 12) deleteByIdLease 0 行删除合法
    func test_journalDAO_deleteByIdLease_zero_row_legal() throws {
        let dao = InMemoryAcceptanceJournalDAO()
        try dao.deleteByIdLease(trainingSetId: 1, leaseId: "L1")
        try dao.upsert(trainingSetId: 1, leaseId: "L1", state: .downloaded, sqliteLocalPath: nil, contentHash: nil, lastError: nil)
        try dao.deleteByIdLease(trainingSetId: 1, leaseId: "L1")
        XCTAssertEqual(try dao.listByState(.downloaded).count, 0)
    }

    // MARK: - 并发安全 smoke

    func test_recordRepo_concurrent_inserts_no_data_race_or_lost_writes() throws {
        let repo = InMemoryRecordRepository()
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        for i in 0..<200 {
            group.enter()
            q.async {
                _ = try? repo.insertRecord(self.makeRecord(id: nil, createdAt: Int64(i)), ops: [], drawings: [])
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(try repo.listRecords(limit: nil).count, 200)
    }

    // MARK: - Helpers

    private func makeRecord(id: Int64?, createdAt: Int64 = 0, profit: Double = 0, total: Double = 1000) -> TrainingRecord {
        TrainingRecord(id: id, trainingSetFilename: "x.sqlite", createdAt: createdAt,
                       stockCode: "000001", stockName: "S", startYear: 2020, startMonth: 1,
                       totalCapital: total, profit: profit, returnRate: 0, maxDrawdown: 0,
                       buyCount: 0, sellCount: 0,
                       feeSnapshot: FeeSnapshot(commissionRate: 0, minCommissionEnabled: false),
                       finalTick: 0)
    }

    private func makeOp(direction: TradeDirection) -> TradeOperation {
        TradeOperation(globalTick: 0, period: .daily, direction: direction,
                       price: 10, shares: 100, positionTier: .tier3,
                       commission: 0, stampDuty: 0, totalCost: 0, createdAt: 0)
    }

    private func makeDrawing() -> DrawingObject {
        DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
    }

    private func makePending(filename: String) -> PendingTraining {
        PendingTraining(trainingSetFilename: filename, globalTickIndex: 0,
                        upperPeriod: .daily, lowerPeriod: .m15,
                        positionData: Data(), cashBalance: 0,
                        feeSnapshot: FeeSnapshot(commissionRate: 0, minCommissionEnabled: false),
                        tradeOperations: [], drawings: [],
                        startedAt: 0, accumulatedCapital: 0,
                        drawdown: .initial)
    }
}
#endif
```

- [ ] **运行测试，确认全部 fail**

```bash
cd ios/Contracts && swift test --filter InMemoryFakesTests 2>&1 | tail -30
```

Expected: 编译过 + 22 个测试**全部 fail**（state machine guards 缺失 → 越级 / 终态转换不被 NOOP；id-tiebreak 顺序错；invariants 缺 → stored 接受 nil path/bad hash；fatalError 还在等）

### Step 1.2 — 升级 `InMemoryFakes.swift` 4 个 P4 fake 实现

- [ ] **改 `InMemoryRecordRepository`：加 NSLock + records 字典 + ops/drawings 字典 + nextId + id DESC tiebreak**

```swift
public final class InMemoryRecordRepository: RecordRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Int64: TrainingRecord] = [:]
    private var ops: [Int64: [TradeOperation]] = [:]
    private var drawings: [Int64: [DrawingObject]] = [:]
    private var nextId: Int64 = 1

    public init() {}

    public func insertRecord(_ rec: TrainingRecord,
                             ops opsIn: [TradeOperation],
                             drawings drawingsIn: [DrawingObject]) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        // 把 server-assigned id 写回 record（mirror production INSERT lastInsertedRowID）
        let stored = TrainingRecord(
            id: id, trainingSetFilename: rec.trainingSetFilename, createdAt: rec.createdAt,
            stockCode: rec.stockCode, stockName: rec.stockName,
            startYear: rec.startYear, startMonth: rec.startMonth,
            totalCapital: rec.totalCapital, profit: rec.profit, returnRate: rec.returnRate,
            maxDrawdown: rec.maxDrawdown, buyCount: rec.buyCount, sellCount: rec.sellCount,
            feeSnapshot: rec.feeSnapshot, finalTick: rec.finalTick)
        records[id] = stored
        ops[id] = opsIn
        drawings[id] = drawingsIn
        return id
    }

    public func listRecords(limit: Int?) throws -> [TrainingRecord] {
        lock.lock(); defer { lock.unlock() }
        // R1 修订（codex round-1 med-2）：mirror production line 60 "ORDER BY created_at DESC, id DESC"
        let sorted = records.values.sorted { (a, b) in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return (a.id ?? 0) > (b.id ?? 0)
        }
        if let limit = limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    public func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject]) {
        lock.lock(); defer { lock.unlock() }
        guard let r = records[id] else {
            // mirror production RecordRepositoryImpl.swift line 74：未知 id = caller 编程错误
            throw AppError.persistence(.dbCorrupted)
        }
        return (r, ops[id] ?? [], drawings[id] ?? [])
    }

    public func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double) {
        lock.lock(); defer { lock.unlock() }
        let total = records.count
        let wins = records.values.filter { $0.profit > 0 }.count
        // R1 修订（codex round-1 med-2）：mirror production line 99 "ORDER BY created_at DESC, id DESC LIMIT 1"
        let latest = records.values.sorted { (a, b) in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return (a.id ?? 0) > (b.id ?? 0)
        }.first
        let cap = latest.map { $0.totalCapital + $0.profit } ?? 0
        return (total, wins, cap)
    }
}
```

- [ ] **改 `InMemoryPendingTrainingRepository`：加 lock + 单 slot**

```swift
public final class InMemoryPendingTrainingRepository: PendingTrainingRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: PendingTraining?

    public init() {}

    public func savePending(_ p: PendingTraining) throws {
        lock.lock(); defer { lock.unlock() }
        pending = p
    }

    public func loadPending() throws -> PendingTraining? {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    public func clearPending() throws {
        lock.lock(); defer { lock.unlock() }
        pending = nil
    }
}
```

- [ ] **改 `InMemorySettingsDAO`：加 lock + `var settings` + R2 修订 finite-value guard**

```swift
public final class InMemorySettingsDAO: SettingsDAO, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings = AppSettings(
        commissionRate: 0,
        minCommissionEnabled: false,
        totalCapital: 0,
        displayMode: .system)

    public init() {}

    public func loadSettings() throws -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func saveSettings(_ s: AppSettings) throws {
        // R2 修订（codex round-2 med-2）：mirror production SettingsDAOImpl.saveSettings line 64-73
        // 在 lock 外做 guard：拒收时不应锁也不应改字段
        guard s.commissionRate.isFinite else {
            throw AppError.internalError(
                module: "PR5a-InMemorySettingsDAO",
                detail: "saveSettings refused: commissionRate not finite (\(s.commissionRate))")
        }
        guard s.totalCapital.isFinite else {
            throw AppError.internalError(
                module: "PR5a-InMemorySettingsDAO",
                detail: "saveSettings refused: totalCapital not finite (\(s.totalCapital))")
        }
        lock.lock(); defer { lock.unlock() }
        settings = s
    }

    public func resetCapital() throws {
        lock.lock(); defer { lock.unlock() }
        // mirror production: 只动 totalCapital
        settings = AppSettings(commissionRate: settings.commissionRate,
                               minCommissionEnabled: settings.minCommissionEnabled,
                               totalCapital: 0,
                               displayMode: settings.displayMode)
    }
}
```

- [ ] **改 `InMemoryAcceptanceJournalDAO`：加 lock + 字典 + nextId + 全镜像 production state machine + invariants + COALESCE**

```swift
// R1 修订（codex round-1 high-1）：fake 必须镜像 AcceptanceJournalDAOImpl 的 state machine + invariants + COALESCE
// 否则 P2 runner / E6 coordinator 等使用 fake 写的测试会接受 production 拒绝的非法 sequence。
// 镜像源：ios/Contracts/Sources/KlineTrainerPersistence/Internal/AcceptanceJournalDAOImpl.swift line 14-138
// 维护契约：production 的 nextAllowed / canApply / validateInvariants / isValidCRC32Hex 改了 → 这里同步改。
public final class InMemoryAcceptanceJournalDAO: AcceptanceJournalDAO, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: AcceptanceJournalRow] = [:]
    private var nextId: Int64 = 1

    public init() {}

    private static func key(_ trainingSetId: Int, _ leaseId: String) -> String {
        "\(trainingSetId)::\(leaseId)"
    }

    // mirror production line 18-29
    private static func nextAllowed(_ s: P2JournalState) -> Set<P2JournalState> {
        switch s {
        case .downloaded:     return [.crcOK, .rejected]
        case .crcOK:          return [.unzipped, .rejected]
        case .unzipped:       return [.dbVerified, .rejected]
        case .dbVerified:     return [.stored, .rejected]
        case .stored:         return [.confirmPending, .rejected]
        case .confirmPending: return [.confirmed, .rejected]
        case .confirmed:      return []
        case .rejected:       return []
        }
    }

    // mirror production line 35-38
    private static func canApply(new: P2JournalState, over old: P2JournalState) -> Bool {
        if new == old { return true }
        return nextAllowed(old).contains(new)
    }

    // mirror production line 43-63
    private static func validateInvariants(state: P2JournalState,
                                            existingPath: String?, existingHash: String?,
                                            newPath: String?, newHash: String?) throws {
        let resolvedPath = newPath ?? existingPath
        let resolvedHash = newHash ?? existingHash
        let needsPath: Set<P2JournalState> = [.stored, .confirmPending, .confirmed]
        if needsPath.contains(state), resolvedPath == nil {
            throw AppError.internalError(
                module: "PR5a-InMemoryAcceptanceJournalDAO",
                detail: "state \(state.rawValue) requires sqliteLocalPath but neither new nor existing has it")
        }
        if state == .stored {
            guard let h = resolvedHash, isValidCRC32Hex(h) else {
                throw AppError.internalError(
                    module: "PR5a-InMemoryAcceptanceJournalDAO",
                    detail: ".stored requires contentHash matching 8-char lowercase hex (CRC32)")
            }
        }
    }

    // mirror production line 66-69
    private static func isValidCRC32Hex(_ s: String) -> Bool {
        guard s.count == 8 else { return false }
        return s.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
    }

    public func upsert(trainingSetId: Int, leaseId: String,
                       state: P2JournalState,
                       sqliteLocalPath: String?,
                       contentHash: String?,
                       lastError: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let k = Self.key(trainingSetId, leaseId)
        let stamp = Int64(Date().timeIntervalSince1970)

        if let existing = rows[k] {
            // 已存在 → 检查 transition 是否合法（mirror production line 90-92：不合法 = silent NOOP）
            if !Self.canApply(new: state, over: existing.state) {
                return  // NOOP（不抛、不修改）
            }
            try Self.validateInvariants(state: state,
                                        existingPath: existing.sqliteLocalPath,
                                        existingHash: existing.contentHash,
                                        newPath: sqliteLocalPath,
                                        newHash: contentHash)
            // COALESCE：nil 入参保留 existing 字段（mirror production line 131-133）
            rows[k] = AcceptanceJournalRow(
                id: existing.id,  // 保留 id（mirror UNIQUE + UPDATE）
                trainingSetId: trainingSetId, leaseId: leaseId,
                state: state, stateEnteredAt: stamp,
                lastError: lastError ?? existing.lastError,
                sqliteLocalPath: sqliteLocalPath ?? existing.sqliteLocalPath,
                contentHash: contentHash ?? existing.contentHash)
        } else {
            // 首插：mirror production line 102-106：state 必须 .downloaded
            guard state == .downloaded else {
                throw AppError.internalError(
                    module: "PR5a-InMemoryAcceptanceJournalDAO",
                    detail: "first INSERT must be .downloaded; got .\(state.rawValue) for tid=\(trainingSetId) lid=\(leaseId)")
            }
            try Self.validateInvariants(state: state,
                                        existingPath: nil, existingHash: nil,
                                        newPath: sqliteLocalPath, newHash: contentHash)
            let id = nextId
            nextId += 1
            rows[k] = AcceptanceJournalRow(
                id: id, trainingSetId: trainingSetId, leaseId: leaseId,
                state: state, stateEnteredAt: stamp,
                lastError: lastError, sqliteLocalPath: sqliteLocalPath, contentHash: contentHash)
        }
    }

    public func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] {
        lock.lock(); defer { lock.unlock() }
        return rows.values.filter { $0.state == state }.sorted { $0.id < $1.id }
    }

    public func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {
        lock.lock(); defer { lock.unlock() }
        rows.removeValue(forKey: Self.key(trainingSetId, leaseId))
    }
}
```

- [ ] **运行测试，确认 24 个 P4 测试全过 + 既有 contract 测试不退化**

```bash
cd ios/Contracts && swift test --filter InMemoryFakesTests 2>&1 | tail -10
cd ios/Contracts && swift test --filter AcceptanceJournalDAOContractTests 2>&1 | tail -10
cd ios/Contracts && swift test --filter TrainingSessionCoordinatorTests 2>&1 | tail -10
```

Expected:
- `InMemoryFakesTests`: 24 个全 PASS（含 R1 加的 id-tiebreak 2 + state-machine 12，R2 加的 SettingsDAO NaN/inf 拒收 2）
- `AcceptanceJournalDAOContractTests`: 旧 `test_InMemoryAcceptanceJournalDAO_can_instantiate_and_satisfies_protocol` **会 fail**（旧断言 `XCTAssertEqual(rows.count, 0)` 与新行为冲突）—— Step 3.1 修
- `TrainingSessionCoordinatorTests`: 应保持 PASS（PR #40 测试用 listRecords/loadPending/loadSettings 都是「空状态」断言；新 fake 默认空状态语义不变）

### Step 1.3 — 提交

- [ ] **commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/InMemoryFakesTests.swift
git commit -m "feat(PR5a): 4 P4 in-memory fakes 升级真状态 + 14 行为测试"
```

---

## Task 2: PreviewTrainingSetReader 新增 + factory 升级

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/PreviewTrainingSetReader.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`（升级 `PreviewTrainingSetDBFactory`）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/PreviewTrainingSetReaderTests.swift`

### Step 2.1 — 写测试（fail first）

- [ ] **写 PreviewTrainingSetReaderTests.swift**

```swift
import XCTest
import Foundation
@testable import KlineTrainerContracts

#if DEBUG
final class PreviewTrainingSetReaderTests: XCTestCase {

    func test_reader_loadMeta_returns_injected_meta() throws {
        let meta = TrainingSetMeta(stockCode: "600519", stockName: "贵州茅台",
                                   startDatetime: 1_700_000_000, endDatetime: 1_700_086_400)
        let reader = PreviewTrainingSetReader(meta: meta, candles: [:])
        XCTAssertEqual(try reader.loadMeta(), meta)
    }

    func test_reader_loadAllCandles_returns_injected_dict() throws {
        // KLineCandle 真实签名：period/datetime/open/high/low/close/volume/amount/ma66/boll*/macd*/globalIndex/endGlobalIndex
        let candle = KLineCandle(period: .daily, datetime: 0,
                                 open: 1, high: 2, low: 0.5, close: 1.5,
                                 volume: 100, amount: nil,
                                 ma66: nil,
                                 bollUpper: nil, bollMid: nil, bollLower: nil,
                                 macdDiff: nil, macdDea: nil, macdBar: nil,
                                 globalIndex: 0, endGlobalIndex: 0)
        let dict: [Period: [KLineCandle]] = [.daily: [candle]]
        let reader = PreviewTrainingSetReader(
            meta: TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0),
            candles: dict)
        let loaded = try reader.loadAllCandles()
        XCTAssertEqual(loaded[.daily]?.count, 1)
        XCTAssertEqual(loaded[.daily]?.first?.close, 1.5)
    }

    /// R2 修订（codex round-2 high-1）：close 后 loadMeta / loadAllCandles 必须 throw（mirror production DefaultTrainingSetReader.ensureOpen）
    func test_reader_close_then_loadMeta_throws_internalError() {
        let reader = PreviewTrainingSetReader(
            meta: TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0),
            candles: [:])
        // close 前可读
        XCTAssertNoThrow(try reader.loadMeta())

        reader.close()

        // close 后 loadMeta 抛 internalError
        XCTAssertThrowsError(try reader.loadMeta()) { err in
            guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
        }
        // close 后 loadAllCandles 也抛
        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
        }
        // close 重复调用合法（mirror production NSLock 不抛）
        reader.close()
    }

    // MARK: - Factory

    func test_factory_default_init_returns_reader_with_placeholder_meta() throws {
        let factory = PreviewTrainingSetDBFactory()
        // file URL + expectedSchemaVersion 都被忽略；不抛
        let reader = try factory.openAndVerify(
            file: URL(fileURLWithPath: "/dev/null"),
            expectedSchemaVersion: 1)
        let meta = try reader.loadMeta()
        XCTAssertEqual(meta.stockCode, "PREVIEW") // §3 决策：占位 meta
    }

    func test_factory_value_injected_returns_reader_with_provided_meta() throws {
        let meta = TrainingSetMeta(stockCode: "300750", stockName: "宁德时代",
                                   startDatetime: 1, endDatetime: 2)
        let factory = PreviewTrainingSetDBFactory(meta: meta, candles: [:])
        let reader = try factory.openAndVerify(
            file: URL(fileURLWithPath: "/dev/null"),
            expectedSchemaVersion: 1)
        XCTAssertEqual(try reader.loadMeta().stockCode, "300750")
    }

    func test_factory_returns_independent_reader_per_call() throws {
        // spec L1830 注释：「每次调用产生新 reader 实例」——fake 也镜像
        let factory = PreviewTrainingSetDBFactory()
        let r1 = try factory.openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1)
        let r2 = try factory.openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1)
        XCTAssertFalse(r1 === r2)
    }

    // MARK: - R3 修订：数据校验（mirror production DefaultTrainingSetReader 全套 invariants）

    /// Helper: 构造一根有效 m3 candle (globalIndex == endGlobalIndex == idx)
    private func validM3(_ idx: Int, close: Double = 1.5) -> KLineCandle {
        KLineCandle(period: .m3, datetime: Int64(idx),
                    open: 1, high: 2, low: 0.5, close: close,
                    volume: 100, amount: nil, ma66: nil,
                    bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil,
                    globalIndex: idx, endGlobalIndex: idx)
    }
    /// Helper: 构造 valid 单根 daily candle (endGlobalIndex 落在指定值)
    private func validDaily(eg: Int, close: Double = 1.5) -> KLineCandle {
        KLineCandle(period: .daily, datetime: 0,
                    open: 1, high: 2, low: 0.5, close: close,
                    volume: 100, amount: nil, ma66: nil,
                    bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil,
                    globalIndex: nil, endGlobalIndex: eg)
    }

    func test_reader_validation_OHLC_must_be_finite_and_positive() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)

        // Open = NaN → corrupt
        let badNaN = KLineCandle(period: .m3, datetime: 0,
                                 open: .nan, high: 2, low: 0.5, close: 1,
                                 volume: 100, amount: nil, ma66: nil,
                                 bollUpper: nil, bollMid: nil, bollLower: nil,
                                 macdDiff: nil, macdDea: nil, macdBar: nil,
                                 globalIndex: 0, endGlobalIndex: 0)
        let r1 = PreviewTrainingSetReader(meta: meta, candles: [.m3: [badNaN]])
        XCTAssertThrowsError(try r1.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else { XCTFail("expected dbCorrupted"); return }
        }

        // Open = 0 → corrupt
        let bad0 = KLineCandle(period: .m3, datetime: 0,
                               open: 0, high: 2, low: 0.5, close: 1,
                               volume: 100, amount: nil, ma66: nil,
                               bollUpper: nil, bollMid: nil, bollLower: nil,
                               macdDiff: nil, macdDea: nil, macdBar: nil,
                               globalIndex: 0, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad0]]).loadAllCandles())
    }

    func test_reader_validation_OHLC_ordering_high_max_low_min() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // high < open (违反 high >= max(open, close, low))
        let bad = KLineCandle(period: .m3, datetime: 0,
                              open: 5, high: 2, low: 0.5, close: 1,
                              volume: 100, amount: nil, ma66: nil,
                              bollUpper: nil, bollMid: nil, bollLower: nil,
                              macdDiff: nil, macdDea: nil, macdBar: nil,
                              globalIndex: 0, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad]]).loadAllCandles())
    }

    func test_reader_validation_volume_nonnegative() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        let bad = KLineCandle(period: .m3, datetime: 0,
                              open: 1, high: 2, low: 0.5, close: 1,
                              volume: -1, amount: nil, ma66: nil,
                              bollUpper: nil, bollMid: nil, bollLower: nil,
                              macdDiff: nil, macdDea: nil, macdBar: nil,
                              globalIndex: 0, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad]]).loadAllCandles())
    }

    func test_reader_validation_optional_indicators_must_be_finite_when_set() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // ma66 = inf
        let bad = KLineCandle(period: .m3, datetime: 0,
                              open: 1, high: 2, low: 0.5, close: 1,
                              volume: 100, amount: nil, ma66: .infinity,
                              bollUpper: nil, bollMid: nil, bollLower: nil,
                              macdDiff: nil, macdDea: nil, macdBar: nil,
                              globalIndex: 0, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad]]).loadAllCandles())
    }

    func test_reader_validation_endGlobalIndex_strictly_increasing_per_period() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // 同 period 两根 endGlobalIndex 相等 → 非严格递增
        let dup1 = validM3(0)
        let dup2 = KLineCandle(period: .m3, datetime: 1,
                               open: 1, high: 2, low: 0.5, close: 1,
                               volume: 100, amount: nil, ma66: nil,
                               bollUpper: nil, bollMid: nil, bollLower: nil,
                               macdDiff: nil, macdDea: nil, macdBar: nil,
                               globalIndex: 0, endGlobalIndex: 0)  // 重复 0
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [dup1, dup2]]).loadAllCandles())
    }

    func test_reader_validation_m3_globalIndex_must_equal_endGlobalIndex_and_array_index() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // m3[0] 但 globalIndex = 5（应等于 array idx = 0）
        let bad = KLineCandle(period: .m3, datetime: 0,
                              open: 1, high: 2, low: 0.5, close: 1,
                              volume: 100, amount: nil, ma66: nil,
                              bollUpper: nil, bollMid: nil, bollLower: nil,
                              macdDiff: nil, macdDea: nil, macdBar: nil,
                              globalIndex: 5, endGlobalIndex: 5)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad]]).loadAllCandles())

        // m3 globalIndex = nil 也违反（must non-nil + equal endGlobalIndex + array idx）
        let badNil = KLineCandle(period: .m3, datetime: 0,
                                 open: 1, high: 2, low: 0.5, close: 1,
                                 volume: 100, amount: nil, ma66: nil,
                                 bollUpper: nil, bollMid: nil, bollLower: nil,
                                 macdDiff: nil, macdDea: nil, macdBar: nil,
                                 globalIndex: nil, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [badNil]]).loadAllCandles())
    }

    func test_reader_validation_non_m3_endGlobalIndex_must_be_nonneg_and_within_m3Max() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // m3 max endGlobalIndex = 2；daily 一根 endGlobalIndex = 5 → 越界
        let m3 = [validM3(0), validM3(1), validM3(2)]
        let dailyOob = validDaily(eg: 5)
        XCTAssertThrowsError(try PreviewTrainingSetReader(
            meta: meta, candles: [.m3: m3, .daily: [dailyOob]]
        ).loadAllCandles())

        // daily endGlobalIndex = -1（非负要求）
        let dailyNeg = validDaily(eg: -1)
        XCTAssertThrowsError(try PreviewTrainingSetReader(
            meta: meta, candles: [.m3: m3, .daily: [dailyNeg]]
        ).loadAllCandles())
    }

    func test_reader_validation_higher_period_without_m3_is_corrupt() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // 只有 daily 没有 m3，且非空 → corrupt
        XCTAssertThrowsError(try PreviewTrainingSetReader(
            meta: meta, candles: [.daily: [validDaily(eg: 0)]]
        ).loadAllCandles())
    }

    func test_reader_validation_empty_dict_is_legal() throws {
        // 整库 result 全空 = 允许（mirror production line 169-172 else 分支不触发）
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        let r = PreviewTrainingSetReader(meta: meta, candles: [:])
        XCTAssertEqual(try r.loadAllCandles().count, 0)
    }

    func test_reader_validation_valid_m3_plus_daily_passes() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        let m3 = [validM3(0), validM3(1), validM3(2)]
        let daily = [validDaily(eg: 2)]  // 落在 m3 范围内
        let r = PreviewTrainingSetReader(meta: meta, candles: [.m3: m3, .daily: daily])
        let loaded = try r.loadAllCandles()
        XCTAssertEqual(loaded[.m3]?.count, 3)
        XCTAssertEqual(loaded[.daily]?.count, 1)
    }
}
#endif
```

> `KLineCandle` 真实初始化器签名已按 `Models.swift` line 75-101 当前形状对齐（period/datetime/open/high/low/close/volume/amount/ma66/boll{Upper,Mid,Lower}/macd{Diff,Dea,Bar}/globalIndex/endGlobalIndex）。其它类型签名按 `Models.swift` 当前形状对齐——若发现 plan 与源不符，按编译器报错对齐 init 顺序，**不改测试语义断言**。

- [ ] **运行 → 全部 fail（type / 文件不存在）**

```bash
cd ios/Contracts && swift test --filter PreviewTrainingSetReaderTests 2>&1 | tail -20
```

Expected: compile error (`PreviewTrainingSetReader` 类型未定义 / `PreviewTrainingSetDBFactory(meta:candles:)` init 不存在)

### Step 2.2 — 实施 reader + 升级 factory

- [ ] **新增 `PreviewTrainingSetReader.swift`（R2 修订：mirror production isClosed 生命周期）**

```swift
// Kline Trainer Swift Contracts — Preview/Test Fixture: P3b TrainingSetReader fake
// Spec: kline_trainer_modules_v1.4.md §11.3 line 2200 (PreviewTrainingSetDBFactory + PreviewTrainingSetReader)
//       protocol 体 §P3b line 1840-1856
// R2 修订（codex round-2 high-1）：mirror DefaultTrainingSetReader 的 isClosed + ensureOpen
//       (KlineTrainerPersistence/DefaultTrainingSetReader.swift line 15-16, 184-191)
// R3 修订（codex round-3 high-1）：mirror DefaultTrainingSetReader.loadAllCandles 全套数据校验
//       (KlineTrainerPersistence/DefaultTrainingSetReader.swift line 84-173)
//       维护契约：production validateCandles 改了 → 这里同步改。
// fake 不持有 DatabaseQueue，但必须镜像 close-then-read = throw + data invariants 才能让
// consumer 的 "reader 返回 = 已校验" 假设在测试和生产都成立。

#if DEBUG

import Foundation

public final class PreviewTrainingSetReader: TrainingSetReader, @unchecked Sendable {
    private let meta: TrainingSetMeta
    private let candles: [Period: [KLineCandle]]
    private var isClosed: Bool = false
    private let lock = NSLock()

    public init(meta: TrainingSetMeta, candles: [Period: [KLineCandle]]) {
        self.meta = meta
        self.candles = candles
    }

    public func loadMeta() throws -> TrainingSetMeta {
        try ensureOpen()
        return meta
    }

    public func loadAllCandles() throws -> [Period: [KLineCandle]] {
        try ensureOpen()
        try Self.validateCandles(candles)
        return candles
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        isClosed = true
    }

    private func ensureOpen() throws {
        lock.lock(); defer { lock.unlock() }
        if isClosed {
            throw AppError.internalError(
                module: "PR5a-PreviewTrainingSetReader",
                detail: "reader closed")
        }
    }

    /// mirror of DefaultTrainingSetReader.loadAllCandles validation (line 84-173)
    /// 任一不变量违反 → AppError.persistence(.dbCorrupted)
    private static func validateCandles(_ data: [Period: [KLineCandle]]) throws {
        // 1) per-period strictly increasing endGlobalIndex（line 90-93）
        // 2) OHLC finite + positive + 序关系 + volume nonneg（line 97-105）
        // 3) optional indicator finite + amount nonneg（line 107-115）
        for (period, list) in data {
            var lastEnd: Int? = nil
            for c in list {
                if let prev = lastEnd, c.endGlobalIndex <= prev {
                    throw AppError.persistence(.dbCorrupted)
                }
                lastEnd = c.endGlobalIndex

                guard c.open.isFinite, c.open > 0,
                      c.high.isFinite, c.high > 0,
                      c.low.isFinite, c.low > 0,
                      c.close.isFinite, c.close > 0,
                      c.high >= max(c.open, c.close, c.low),
                      c.low <= min(c.open, c.close, c.high),
                      c.volume >= 0 else {
                    throw AppError.persistence(.dbCorrupted)
                }
                for opt in [c.amount, c.ma66, c.bollUpper, c.bollMid, c.bollLower,
                            c.macdDiff, c.macdDea, c.macdBar] {
                    if let v = opt, !v.isFinite {
                        throw AppError.persistence(.dbCorrupted)
                    }
                }
                if let a = c.amount, a < 0 {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
            // 非 m3 endGlobalIndex 非负（line 137-143）
            if period != .m3 {
                for c in list {
                    if c.endGlobalIndex < 0 {
                        throw AppError.persistence(.dbCorrupted)
                    }
                }
            }
        }
        // 4) m3 global-axis invariants（line 153-160）+ 非 m3 ≤ m3Max（line 162-168）
        // 5) 非空 result 但缺 m3 → corrupt（line 169-172）
        if let m3 = data[.m3] {
            for (i, c) in m3.enumerated() {
                guard let g = c.globalIndex,
                      g == c.endGlobalIndex,
                      g == i else {
                    throw AppError.persistence(.dbCorrupted)
                }
            }
            let m3Max = m3.last?.endGlobalIndex ?? -1
            for (period, list) in data where period != .m3 {
                for c in list {
                    if c.endGlobalIndex > m3Max {
                        throw AppError.persistence(.dbCorrupted)
                    }
                }
            }
        } else if !data.isEmpty {
            throw AppError.persistence(.dbCorrupted)
        }
    }
}

#endif
```

- [ ] **改 `InMemoryFakes.swift` 的 `PreviewTrainingSetDBFactory`**

```swift
public struct PreviewTrainingSetDBFactory: TrainingSetDBFactory {
    private let meta: TrainingSetMeta
    private let candles: [Period: [KLineCandle]]

    public init(meta: TrainingSetMeta? = nil,
                candles: [Period: [KLineCandle]] = [:]) {
        self.meta = meta ?? TrainingSetMeta(
            stockCode: "PREVIEW",
            stockName: "Preview Stock",
            startDatetime: 0,
            endDatetime: 0)
        self.candles = candles
    }

    public func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
        // file / expectedSchemaVersion 在 fake 中被忽略（§3 决策）；
        // 每次调用产生新 reader（spec L1830 契约）
        PreviewTrainingSetReader(meta: meta, candles: candles)
    }
}
```

- [ ] **运行测试**

```bash
cd ios/Contracts && swift test --filter PreviewTrainingSetReaderTests 2>&1 | tail -10
```

Expected: 15 个全 PASS（6 reader/factory 基础 + 9 R3 candle 校验）

- [ ] **commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/PreviewTrainingSetReader.swift \
        ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/PreviewTrainingSetReaderTests.swift
git commit -m "feat(PR5a): PreviewTrainingSetReader + factory 升级 value-injected"
```

---

## Task 3: 既有测试翻面修订 + 验收清单

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/AcceptanceJournalDAOContractTests.swift`
- Create: `docs/acceptance/2026-05-05-pr5a-db-fixtures.md`

### Step 3.1 — 翻面 `AcceptanceJournalDAOContractTests.test_InMemoryAcceptanceJournalDAO_can_instantiate_and_satisfies_protocol`

旧测试断言 `Wave 0 fake 不实际持久化`，与 PR5a 目标矛盾。改为：

- [ ] **改测试 body**

```swift
#if DEBUG
func test_InMemoryAcceptanceJournalDAO_can_instantiate_and_satisfies_protocol() throws {
    let fake: AcceptanceJournalDAO = InMemoryAcceptanceJournalDAO()
    // PR 5a 升级：首插必须 .downloaded（mirror production state machine）
    try fake.upsert(trainingSetId: 1, leaseId: "x", state: .downloaded,
                    sqliteLocalPath: nil, contentHash: nil, lastError: nil)
    let rows = try fake.listByState(.downloaded)
    XCTAssertEqual(rows.count, 1)  // PR 5a 升级：fake 现在真持久化
    XCTAssertEqual(rows.first?.trainingSetId, 1)
    try fake.deleteByIdLease(trainingSetId: 1, leaseId: "x")
    XCTAssertEqual(try fake.listByState(.downloaded).count, 0)
}
#endif
```

- [ ] **检查 `TrainingSessionCoordinatorTests` 既有 3 个 fake instantiation 测试是否仍 PASS**

```bash
cd ios/Contracts && swift test --filter TrainingSessionCoordinatorTests 2>&1 | tail -20
```

Expected: 全 PASS（默认空状态下 `listRecords / loadPending / loadSettings` 行为不变）

- [ ] **跑全 suite 确认无回归**

```bash
cd ios/Contracts && swift test 2>&1 | tail -30
```

Expected: 0 failures（含 PR #37-44 既有所有测试）

### Step 3.2 — 写中文非 coder 验收清单

- [ ] **创建 `docs/acceptance/2026-05-05-pr5a-db-fixtures.md`**

模板参考 `docs/acceptance/2026-05-04-pr4b-cache-settings.md`。结构：

```markdown
# PR 5a 验收清单（DB-domain 测试 fixture）

## 范围
本次改动新增 5 个测试用 in-memory fake：
- 4 个数据库相关 fake（成交记录 / 待续训练 / 设置 / 验收日志）
- 1 个训练组数据库读取器 fake

## 验收步骤（终端逐条复制粘贴执行）

### 1. 编译通过
| 操作 | 期望 | 通过条件 |
|---|---|---|
| `cd ios/Contracts && swift build 2>&1 \| tail -3` | 看到 `Build complete!` | 没有红色 error 行 |

### 2. 测试全过
| 操作 | 期望 | 通过条件 |
|---|---|---|
| `cd ios/Contracts && swift test 2>&1 \| tail -5` | 看到 `Test Suite 'All tests' passed` 或 `Executed XX tests, with 0 failures` | 数字 failures = 0 |

### 3. 新增测试存在
| 操作 | 期望 | 通过条件 |
|---|---|---|
| `cd ios/Contracts && swift test --filter InMemoryFakesTests 2>&1 \| grep "Test Case"` | 看到 14 个 `passed` 行 | 14 行全部含 `passed` |
| `cd ios/Contracts && swift test --filter PreviewTrainingSetReaderTests 2>&1 \| grep "Test Case"` | 看到 6 个 `passed` 行 | 6 行全部含 `passed` |

### 4. 不影响 PR #37-44 既有测试
| 操作 | 期望 | 通过条件 |
|---|---|---|
| `cd ios/Contracts && swift test --filter TickEngineTests 2>&1 \| tail -3` | 全过 | 0 failures |
| `cd ios/Contracts && swift test --filter GeometryTests 2>&1 \| tail -3` | 全过 | 0 failures |
| `cd ios/Contracts && swift test --filter ThemeTests 2>&1 \| tail -3` | 全过 | 0 failures |
| `cd ios/Contracts && swift test --filter SettingsStoreProductionTests 2>&1 \| tail -3` | 全过 | 0 failures |
| `cd ios/Contracts && swift test --filter TrainingSessionCoordinatorTests 2>&1 \| tail -3` | 全过 | 0 failures |
| `cd ios/Contracts && swift test --filter AcceptanceJournalDAOContractTests 2>&1 \| tail -3` | 全过 | 0 failures |

### 5. 验证生产代码 0 改动（R2 修订：codex round-2 med-3 — pathspec 用目录递归而非单 `*.swift`）
| 操作 | 期望 | 通过条件 |
|---|---|---|
| `git diff main..HEAD --name-only -- 'ios/Contracts/Sources/KlineTrainerPersistence/'` | 输出为空（生产实现 + Internal 子目录全部 0 改动）| 输出为空字符串 |
| `git diff main..HEAD --name-only -- 'ios/Contracts/Sources/KlineTrainerContracts/Persistence/'` | 输出为空（contract 协议 0 改动）| 输出为空字符串 |

### 6. 验证只在 DEBUG 编译产物里
| 操作 | 期望 | 通过条件 |
|---|---|---|
| `grep -c '^#if DEBUG' ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | 输出 `1` | 等于 1 |
| `grep -c '^#if DEBUG' ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/PreviewTrainingSetReader.swift` | 输出 `1` | 等于 1 |

## 失败处理
任何步骤通过条件不满足，**不要继续合并**——把终端完整输出贴给 Claude 让它修。
```

- [ ] **commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/AcceptanceJournalDAOContractTests.swift \
        docs/acceptance/2026-05-05-pr5a-db-fixtures.md
git commit -m "test(PR5a): contract test 翻面 + 验收清单"
```

---

## 完工自检（subagent 不要早停）

- [ ] `cd ios/Contracts && swift test 2>&1 | tail -5` 显示 `0 failures`
- [ ] `git log main..HEAD --oneline` 显示 3 commits（Task 1/2/3 各一）
- [ ] `git diff main..HEAD --stat` 各文件改动行数与 plan 预估对齐（±20% 内）：
  - `InMemoryFakes.swift` 净增 ≤ 130 LOC
  - `PreviewTrainingSetReader.swift` ≤ 50 LOC
  - 测试文件总行数 ≤ 350 LOC
- [ ] **没有**改动以下任何路径（`git diff main..HEAD --stat` 应不出现）：
  - `ios/Contracts/Sources/KlineTrainerPersistence/**`
  - `ios/Contracts/Sources/KlineTrainerContracts/Persistence/*.swift`（协议本体）
  - `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift`
  - `ios/Contracts/Sources/KlineTrainerContracts/Models.swift`
  - `ios/Contracts/Sources/KlineTrainerContracts/AppError.swift`
  - `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`
  - `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- [ ] **`InMemoryFakes.swift` 内 `InMemoryCacheManager` 类**（PR 5b scope）`git diff main..HEAD ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` **不出现** `InMemoryCacheManager` 行的修改
- [ ] `swift build -c release 2>&1 | tail -3` 不出错（确认 `#if DEBUG` 守卫使 release build 不带 fake 类型）

---

## 不在本 PR 范围（codex 提即 reject 引用）

| 项 | 原因 | 归属 |
|---|---|---|
| `InMemoryCacheManager` 升级真状态 | spec §11.3 line 2201（port-domain）| PR 5b |
| 6 项 port-domain fake（FakeZipExtractor 等）| spec §11.3 line 2202-2206 | PR 5b |
| `KLineCandle.previewFixture` / `FeeSnapshot.preview` / `TrainingRecord.previewRecord` | spec §11.3 line 2188-2194 是另一份清单（Preview Fixture 数据，非 Test Fixture Ports）；v6 outline 不在 Wave 0 强制锚 | backlog |
| 协议签名调整（如改 `downloadedZip` 参数名）| trust-boundary change PR | 独立 PR / v1.5 spec |
| `DefaultTrainingSetReader` / `DefaultTrainingSetDBFactory` 改动 | 生产实现，PR #41 已 merge | N/A |
| Production `RecordRepositoryImpl` / `SettingsDAOImpl` 任何变更 | 生产实现已 merge | N/A |

---

## 自检（plan 写完后跑）

**1. Spec coverage：**
- §11.3 line 2196 InMemoryRecordRepository → Task 1 ✅
- §11.3 line 2197 InMemoryPendingTrainingRepository → Task 1 ✅
- §11.3 line 2198 InMemorySettingsDAO → Task 1 ✅
- §11.3 line 2199 InMemoryAcceptanceJournalDAO → Task 1 ✅
- §11.3 line 2200 PreviewTrainingSetDBFactory + PreviewTrainingSetReader → Task 2 ✅
- §11.3 line 2201-2206 port-domain → 显式排除 PR 5b（"不在本 PR 范围"表）✅

**2. Placeholder 扫描：** 无 TBD / TODO / 「适当处理」类占位

**3. Type 一致性：**
- `AppError.persistence(.dbCorrupted)`：fake unknown id 抛此 case，与 `RecordRepositoryImpl.swift` line 74 同步（**不**用 `.notFound`，该 case 在 `AppError.swift` 不存在）
- `Period` cases = `m3 / m15 / m60 / daily / weekly / monthly`（**没有 `.day` / `.min15`**；测试 helper 用 `.daily` + `.m15`）
- `PositionTier` = `tier1..tier5`（**没有 `.heavy`**）；`DrawingToolType` = `ray/trend/horizontal/golden/wave/cycle/time`（**没有 `.horizontalLine`**）
- `DrawingObject(toolType:, anchors:, isExtended:, panelPosition:)`（**没有 `id` / `createdAt` / `tool`**）
- `KLineCandle(period:, datetime:, open:, high:, low:, close:, volume:, amount:, ma66:, bollUpper:, bollMid:, bollLower:, macdDiff:, macdDea:, macdBar:, globalIndex:, endGlobalIndex:)`
- `PreviewTrainingSetDBFactory` 默认 init 占位 meta（`stockCode = "PREVIEW"`）在 §3 决策 + Step 2.1 测试 + Step 2.2 实施三处一致引用
- `nextId` 自增策略在 RecordRepository 与 AcceptanceJournalDAO 都明示「新 key ++ / 旧 key 保留」
- `InMemoryAcceptanceJournalDAO` mirror 的 4 个 helper（`nextAllowed` / `canApply` / `validateInvariants` / `isValidCRC32Hex`）签名与 production `AcceptanceJournalDAOImpl.swift` line 18-69 完全一致

**4. R1 修订对接（codex round-1 findings 吸收）：**
- finding 1 (high) AcceptanceJournal state machine → §6 重写 + Task 1 测试 12 条 + 实施代码 4 helper + 测试翻面 Step 3.1
- finding 2 (medium) Record id-tiebreak → §4 修订 + Task 1 测试 2 条 + 实施代码 listRecords/statistics 双处

**5. R2 修订对接（codex round-2 findings 吸收）：**
- finding 1 (high) PreviewTrainingSetReader close 生命周期 → §7 加 isClosed 镜像 + Task 2 测试翻面（close 后 read 抛 internalError）+ 实施加 NSLock + ensureOpen
- finding 2 (medium) InMemorySettingsDAO 拒 NaN/inf → §5 修订 + Task 1 测试 2 条 + 实施 saveSettings 加 finite-value guard
- finding 3 (medium) acceptance pathspec 漏 Internal/ → 验收清单 §5 改用目录 pathspec（`'..../KlineTrainerPersistence/'` 而非 `'..../KlineTrainerPersistence/*.swift'`），覆盖 Internal 子目录

**6. R3 修订对接（codex round-3 findings 吸收）：**
- finding 1 (high) PreviewTrainingSetReader candle 校验 → §7 加 R3 段 + Task 2 测试 9 条 + 实施 validateCandles helper（mirror DefaultTrainingSetReader.loadAllCandles line 84-173 全套校验：OHLC finite/positive/序关系、volume/amount nonneg、optional finite、endGlobalIndex 严格递增、m3 global-axis 不变量、非 m3 ≤ m3Max、空 dict 允许）

**7. 后续轮次预算**：plan 已在 round 3 收 6 个 findings（R1 2 + R2 3 + R3 1）。round 4 若再撞同模式「production 有 X validation，fake 也要」类 finding，按 memory `feedback_codex_round6_self_contradiction` 评估：fake 已镜像 4 处主要 production guards（state machine + isClosed + finite settings + candle validation），剩余可能的「次级保护」属边际收益低。round 4 起若新 finding 不能引向具体 production 行为分叉案例，pushback + accept residual。
