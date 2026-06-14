# Wave 3 顺位 10b — 持久化集成（周期 autosave + 终态 fence + discard 持久终态 + provenance 恢复）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落实 RFC §4.6（周期 autosave 参数化）+ §4.7 (d) 终态 fence + (e) discard 持久终态 + (f) provenance-aware 恢复，把 10a 的「单事务 finalize 基础」集成为完整的会话持久化生命周期：脏状态周期落盘、终态前栅栏排空 autosave、放弃/返回失败时 durable 清局或保留重试、训练组 DB 损坏自动删重下而 `app.sqlite` 损坏 fail-closed 禁删。

**Architecture:** 全部新机制为 `TrainingSessionCoordinator`（`@MainActor @Observable` 引用类型）的内部状态机 —— autosave 单写者协程（dirty-flag + latest-wins coalescing，`@ObservationIgnored`）+ `terminating` 栅栏标志（finalize/discard 前 `await` 排空在飞 autosave 并拒绝新请求）+ `discardSession()`（fence→清 pending→endSession）+ training-set 打开路径的 source-based 损坏路由（删缓存文件重试，**永不删 app.sqlite**）。UI 层（`TrainingView`）仅做薄触发接线（脏动作后 `requestAutosave`、scenePhase 后台 `flushAutosave`、放弃走 discard、返回失败保留），不持有状态。无 spec 改动（modules §E6 L1747/L1752/L1753 已由顺位 1 RFC 钉死契约 marker，本 PR 纯实现）。

**Tech Stack:** Swift 6 / SwiftPM（`ios/Contracts`，macOS host 全测 + Mac Catalyst 编译闸门）、GRDB 6.29（`DatabaseQueue` 单写者）、Swift Testing（`@Test/#expect`/`await #expect(throws:)`）+ XCTest（既有迁移测试范式）、Swift Concurrency（`Task { @MainActor }` + `await task.value` 排空）。

**不在本 PR（归顺位 10c，见文末「§ 范围与 10c 切分」）：** 全 app fixture provisioning（debug seed 经 `AppContainer`）、生产路径 fixture E2E smoke（真实 `DownloadAcceptanceRunner`）、边界错误统一 Toast 层（下载中断/磁盘满网络可见性）、cache touch-on-use（E6a-R3）。这些是「运行时矩阵 enablement + 磨光」，与本 PR 的「§4.6/§4.7d/e/f 契约闭合」正交，按 RFC §4.7「总实施归属」（10b = d+e+f+autosave+跨 feature 故障注入）+ outline「~500+ 行 plan 须拆」纪律切出。

---

## 契约出处（权威，不复述）

- **RFC §4.6**（`docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md:176-189`；modules `kline_trainer_modules_v1.4.md:1747`）：autosave 触发 = 任何 state-dirtying mutation（tick 推进 + buy/sell + 画线 commit/delete）；cadence floor `AUTOSAVE_TICK_INTERVAL = N`（默认 1，可上调 `≤ AUTOSAVE_MAX_INTERVAL`，不变量：未落盘丢失 ≤ N tick 等价脏窗）；coalescing 单写者 latest-wins（in-flight 写中又脏→写完再存一次，不排队堆积）；background/inactive flush（scenePhase `.inactive`/`.background` 立即 flush，**additive** 到 `.active → onSceneActivated` 链，不替换）；失败可见、不 teardown session。
  > **代码现状校正（plan-review H1）**：RFC item 1 的措辞「buy/sell 改 position/cash **但不推 tick**」**与当前 engine 实现不符**——`TrainingEngine.buy(:376)`/`sell(:411)` 均调 `advanceAndAccount(:361)`，内部 `tick.advance(:367)` + `forceCloseIfEnded(:369)` = **buy/sell 确实推 tick**。该 RFC/modules 措辞是顺位 1 冻结 scope，**本 PR 不改 spec**；但本 plan 的 rationale **以代码为准**：真正「不推 tick 的脏动作」= **画线 commit/delete**（`appendDrawing`/`deleteDrawing` 不动 tick）。buy/sell 推 tick → tick `.onChange` 已覆盖其落盘；本 plan 仍对 buy/sell 额外挂 immediate autosave 的理由 = **成功成交后即时 durable**（不等 N-tick cadence + 与 tick `.onChange` 经 coalescing 合一，无双写）。
- **RFC §4.7d**（`:212`；modules `:1752`）：finalize/discard 前 drain/cancel 排队 autosave + finalization 启动后拒绝新 autosave。防终态脏写在 finalize 后重建 `pending_training` → 重启重复 finalize/record。测试 save-before/after-finalize 双序 + 无 pending resurrection + 无 duplicate。
- **RFC §4.7e**（`:214`；modules `:1752`）：discard = fence autosaves → 清 `pending_training` → endSession → exit（durable 终态，不复活）。清 pending 失败 → 保留 active session 供 retry（不 teardown）。测试 discard-with-existing-autosave + relaunch 无复活。
- **RFC §4.7f**（`:216-219`；modules `:1753`，**安全红线**）：按 **source**（哪个 DB）分流，非 `.dbCorrupted` error 类型（二者现同类型，调用点 source 已知）。training-set DB 损坏可弃（自动删 + 重下 DownloadAcceptanceRunner 路径）；**`app.sqlite` 损坏 fail-closed 禁自动删**（history/pending/settings 不可逆）。防顺位 10 据「都报 dbCorrupted」误对 app.sqlite 做训练组式 auto-delete。

## 现状证据（核实 2026-06-14，worktree HEAD = origin/main `836acba`，含 #103 顺位4 / #104 顺位12）

- **autosave 不存在**：`coordinator.saveProgress`（`TrainingSessionCoordinator.swift:188-211`）仅 Normal 持久化，**仅 Back 触发**（`TrainingSessionLifecycle.back():31-34` = `saveProgress` + `endSession`）。`saveProgress` 体内**无 await 真挂起**（`encodePosition` + `pendingRepo.savePending` 均同步），标 async 仅为契约一致；写在 `@MainActor` 上同步完成。
- **无 fence**：`finalize`（`:218-253`）直接调 `finalization.finalizeSession(...)`（10a 单事务），**无排空 autosave 前置**。`endSession`（`:293-300`）仅关 reader + 清 active context（含 10a 的 `activeSessionKey = nil`），**不清 `pending_training`**。
- **discard 非 durable**：`TrainingView.swift:92-93` 放弃按钮 = `Task { await lifecycle.endAfterSettlement(); onExit() }` → `endAfterSettlement` = `endSession`（关 reader+清 context），**pending 留存** → 首页/重启复活（10a 明列「durable discard 归 10b」）。
- **back-save 失败丢数据**：`TrainingView.swift:124` 返回 = `Task { try? await lifecycle.back(); onExit() }`——`back()` 的 `saveProgress` 失败被 `try?` 吞 + 仍 `onExit()`（注：`back()` 失败时 `endSession` 因 throw 跳过 → reader 未关，但 view 仍退出 = reader 泄漏 + 进度丢失，codex R3-F1）。
- **provenance 未分流**：训练组打开（`openReader(for:):311-315` → `dbFactory.openAndVerify`）与 app.sqlite DAO（`recordRepo`/`pendingRepo`）损坏**均**经 `PersistenceErrorMapping.translate`（`PersistenceErrorMapping.swift:29` SQLITE_NOTADB/CORRUPT → `.persistence(.dbCorrupted)`；`:39` DecodingError → 同）映同一类型。调用点 source 已知（openReader=训练组只读 DB；DAO=app.sqlite）但错误不可区分。`CacheManager` 有 `delete(_) throws`（`CacheManager.swift:11`）+ `pickRandom()`（`:8`）。
- **fake 形态**（`PreviewFakes/InMemoryFakes.swift`）：`InMemoryCacheManager`（`:377`）`pickRandom()`（`:393`）= `sortedLocked().randomElement()`（**真随机** → provenance 测试须经注入确定化，见 Task 0 D8）；`delete(_)`（`:426`）；`_seedForTesting`。`InMemoryPendingTrainingRepository`（`NSLock` single-slot）。`PreviewTrainingSetDBFactory(candles:)` happy-path（忽略 file/version）。
- **UI 触发锚**：`TrainingView.swift:157` `engine.holdOrObserve(panel:)`（tick 推进）；`:165` `performTrade`（buy/sell）；`ChartContainerView.swift:139` `engine.appendDrawing`（画线 commit；engine.drawings 单一真相，#103）；`:75` `.onChange(of: engine.tick.globalTickIndex) { _,_ in maybeAutoEnd() }`；`:76-78` scenePhase `.onChange`（仅 `.active → onSceneActivated`）。`TrainingEngine` 是 `@MainActor @Observable`，`drawings`/`tick`/`cashBalance` 均 `public private(set)`（突变即被观察）。
- **基线**：`swift test` **942 tests / 131 suites** 全 pass（2026-06-14 实测，本 worktree）。

## 设计决策

**D1 — autosave coalescing = 单写者协程 + dirty 标志 + latest-wins（@MainActor 上的 Task 跨 runloop hop 自然合并）。** coordinator 加内部状态（全 `@ObservationIgnored`，不入观察/不改 init）：
```
private var autosaveTask: Task<Void, Never>?     // 在飞写协程句柄（fence drain 用 await .value）
private var autosaveDirty = false                // 写中又脏 → 写完再存一次
private var terminating = false                  // §4.7d 栅栏：拒绝新 autosave
private var ticksSinceAutosave = 0               // N-tick cadence 计数
private(set) var lastAutosaveError: AppError?    // §4.6 失败可见（@testable + UI 读）
var autosaveTickInterval = AUTOSAVE_TICK_INTERVAL // 可注入（测试覆盖 N）
```
`requestAutosave(engine:immediate:)`：`terminating` 或非 Normal → no-op；非 immediate 走 N-tick 节流；置 dirty；若无在飞 Task 则建一个 `Task { @MainActor }`。同一 runloop 内多次同步请求（如 buy 推 tick 同时触发 trade 钩子 + tick `.onChange`）只建一个 Task → 合并为一次写。**理由**：`saveProgress` 同步完成，"in-flight" 仅跨 runloop hop；Task 调度天然把同 hop 的 burst 合一，满足 §4.6 latest-wins，不排队堆积。`immediate=true`（buy/sell/画线/background flush）绕过 N-tick 节流。**stale-engine 兜底**：Task 捕获传入 `engine`；若活跃 engine 已变，`saveProgress` 的 `guard activeEngine === engine`（`:192`）拒绝并抛 `.internalError` → 记入 `lastAutosaveError`，**不会写错存档**（plan-review L5 确认）。

**D2 — fence = `terminating=true` 先行 + `await autosaveTask?.value` 排空，排空时 Task 见 terminating 即退出不写。** `fenceAndDrainAutosaves()` 置 `terminating=true` 再 `await autosaveTask?.value`：在飞/已排队的 Task 的 `while autosaveDirty && !terminating` 循环条件因 terminating 为 false → **不落盘排队脏** 即退出。**理由**：finalize 紧接 `clearPending`（单事务）/ discard 紧接 `clearPending`——终态由 record 或「无 pending」表达，排队脏写不应在其后复活 `pending_training`。drop 排队脏 = §4.7d「无 pending resurrection」。单线程 @MainActor 保证 finalize/discard 与 Task 不并发执行（finalize `await` 时 Task 运行并见 terminating）。退出后 `autosaveDirty` 可能残留 true，由 `endSession` 清零（无泄漏，plan-review L4 确认）。

**D3 — terminating 重置点 = session 启动成功路径（startNewNormalSession/resumePending）。** finalize 失败保留（§4.7a）后 session 仍活跃但已在末态结算（无新 gameplay 脏写），terminating 维持 true 至 teardown 无害；retry finalize/discard 复用已 fence 态。**discard 失败保留（§4.7e）同理**：session 经「放弃」按钮进入，无回 gameplay 路径，terminating 维持 true（autosave 永久 fence 至 retry/teardown）= 预期行为非 bug（plan-review M4）。`endSession()` 额外 `autosaveTask?.cancel()` + 清全 autosave 标志（防 task 句柄跨 session 泄漏）。startNew/resume 成功路径重置 `terminating=false`、`autosaveDirty=false`、`ticksSinceAutosave=0`、`lastAutosaveError=nil`。

**D4 — discard durable = coordinator `discardSession()`（新 public async throws 方法），lifecycle `discard()` 薄转发。** `discardSession`：`fenceAndDrainAutosaves()` → `try pendingRepo.clearPending()` → `await endSession()`。clearPending 抛 → **不 endSession**（保留 active session 供 retry），透传 AppError（§4.7e）。`endSession` 在 clearPending 成功后才跑 = reader 关、context 清、durable 无 pending。lifecycle 加 `func discard() async throws { try await coordinator.discardSession() }`。**review/replay 语义注（plan-review M3）**：`clearPending` 是**无条件 DB 写**（生产 `DELETE FROM pending_training`，review/replay 无行 = 删 0 行无害）；若该写抛（disk full），discard 对 review/replay 亦保留 session（reader 不关）——统一语义，对 review/replay 良性（无可丢进度）。

**D5 — back-save 失败保留 = view 层（§4.7a 同型）。** `back()` 契约不改（`saveProgress` 抛则 `endSession` 因 throw 跳过 = reader 未关、session 留存——已正确）。**仅修 view**：`TrainingView` 返回按钮从 `try? back(); onExit()` 改为 `do { try back(); onExit() } catch { backFailed = true }`，弹 alert「重试/放弃」——重试复跑 `back()`；放弃走 `discardSession()`（durable 清局退出）。**理由**：`back()` 已具失败保留语义（throw 不 endSession），数据丢失根因在 view 的 `try?`+无条件 `onExit`。

**D6 — provenance 路由 = 按调用点 source 内联，非按 error 类型。** 训练组打开（`openReader`）是已知 source = 训练组只读 DB：
- **startNewNormalSession**：`pickRandom`→`openReader` 包进**有界重试循环**（≤ `cache.listAvailable().count + 1` 次，防无限——即便 `try? cache.delete` 静默失败，`attempts` 上限仍终止循环，plan-review 4）：捕获 `isCorruptTrainingSet(error)` → `try? cache.delete(file)` → 重 `pickRandom` 重试；非损坏错误（diskFull/internalError）直接透传；缓存耗尽 → `throw .trainingSet(.fileNotFound)`（caller=AppRouter 走既有空缓存下载路径重下，**不需注入 runner**）。**`startingCapital()` 上移到循环外**（它调 `recordRepo.statistics()` = app.sqlite source，其 `.dbCorrupted` 绝不能进训练组删重试，plan-review 3）。
- **resumePending**：pending 指定文件损坏 → `try? cache.delete(file)` + `try pendingRepo.clearPending()`（孤儿 pending 不可恢复，durable 清）+ `return nil`（首页降级到新局）。
- **review/replay**：record 指定文件损坏 → `try? cache.delete(file)` + 透传 `.dbCorrupted`（无法替代，surface 给用户）。
- **app.sqlite fail-closed（安全红线）**：DAO 路径（`recordRepo`/`pendingRepo`/`finalization` 损坏，如 `loadPending`/`loadRecordBundle`/`statistics` 抛 `.dbCorrupted`）**永不触 `cache.delete`**——这些调用全在 `openReader` catch **之外**（如 `resumePending:94` `loadPending` 先于 `openReader:96`），其错误原样透传 surface；coordinator 不持有 app.sqlite 删除能力（`DefaultAppDB` 无 delete API），本 PR **不新增任何 app.sqlite 自动删/重置路径**。

**D7 — `isCorruptTrainingSet(_ error:) -> Bool` 判据 = `.persistence(.dbCorrupted)` 或 `.trainingSet(.emptyData/.versionMismatch/.crcFailed/.unzipFailed)`。** 这些是 `dbFactory.openAndVerify` 对坏训练组文件抛的可弃错误（`DefaultTrainingSetDBFactory` 三阶段校验）。**不含** `.trainingSet(.fileNotFound)`（文件缺失非损坏，删无意义）、`.diskFull`（环境错误，删文件不解决）、`.internalError`（bug，不掩盖）。仅在 `openReader` 调用栈内用 → app.sqlite source 永不命中（安全红线）。

**D8 — fake 失败注入 + 确定性选取（plan-review H2/H3/M1）。**
- `InMemoryPendingTrainingRepository` 加 `failNextSavePending`/`failNextClearPending`/`failNextLoadPending: AppError?` + `saveCount`（抛前零状态变更）。
- `PreviewTrainingSetDBFactory` 加 `corruptFilenames: Set<String>`（按 `file.lastPathComponent` 命中 → 抛 `.persistence(.dbCorrupted)`）+ `openErrorAll: AppError?`（命中任意 file → 抛该错误，测非损坏错误不删）。**匹配字段注**：`openAndVerify(file: URL)` 收的是 `file.localURL`；provenance fixture 构造 `TrainingSetFile` 时须令 `localURL.lastPathComponent == filename`（mirror 既有 `cachedFile()` 约定 `/tmp/<filename>`），使 `corruptFilenames`（filename）与 cache `delete`（`file.filename`）一致。
- `InMemoryCacheManager` 加 `pickOverride: (([TrainingSetFile]) -> TrainingSetFile?)?`（默认 nil = 既有 `randomElement()`；provenance 测试注入确定化，根治 H2 flake）+ `deletedFilenames: [String]` spy。

**D9 — UI autosave 触发全在 `TrainingView`（持有 lifecycle/coordinator），不下钻 `ChartContainerView`。** 画线 commit 在 `ChartContainerView.swift:139` 改 `engine.drawings`（**不推 tick** → 真 inter-tick 脏动作）；`TrainingView` 经 `.onChange(of: engine.drawings.count)` 观察到 → immediate autosave。tick 经 `.onChange(of: engine.tick.globalTickIndex)`（与既有 `maybeAutoEnd` 合并到同一 closure）→ throttled autosave（覆盖 holdOrObserve + buy/sell 推 tick）。buy/sell 另在 `performTrade` **成功路径**追加 immediate autosave（即时 durable；与 tick `.onChange` 经 coalescing 合一，无双写；**失败 `.failure` 不触**——无状态变更，plan-review L3）。**理由**：避免把 coordinator 引用 plumbing 进 render 层；`engine.drawings.count` 变化覆盖 commit/delete 两路。

**D10 — `AUTOSAVE_TICK_INTERVAL = 1` / `AUTOSAVE_MAX_INTERVAL = 5`（module 常量，mirror `CONTRACT_VERSION` 风格）落 `TrainingSessionCoordinator.swift` 顶层。** N=1 = 每脏即存（coalesced）；tick 推进是用户显式动作（holdOrObserve 点按 / buy/sell；**非自动滚动**——viewport offset 不推 tick），频率低，N=1 不致雪崩。MAX=5 为未来实测调优上限占位（本 PR 不上调）。grep gate（RFC §五a）要 `AUTOSAVE_TICK_INTERVAL` 在 modules——已在 L1747；本 PR 在代码补同名常量（机器锚一致）。

---

## File Structure（创建/修改全列）

| 文件 | 动作 | 责任 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` | Modify | autosave 状态机 + fence + `discardSession` + provenance 路由 + 常量（Task 1/2/3/4） |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift` | Modify | `discard()` 转发 + autosave/flush 转发（Task 3/5） |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | Modify | autosave 触发接线 + scenePhase flush + 放弃→discard + 返回失败保留（Task 5） |
| `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` | Modify | fake 失败注入 + pickOverride + spy（Task 0 落地，Task 1/3/4 用） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/PersistenceIntegrationFixtures.swift` | Create | 共享测试 fixture（`PIFixtures.makeCoordinator()` 无参 + `makeProvenanceCoordinator` + `sampleDrawing`）（Task 0） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionAutosaveTests.swift` | Create | autosave coalescing/cadence/失败可见（Task 1） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionFenceTests.swift` | Create | 终态 fence 双序 + discard durable（Task 2/3） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionProvenanceTests.swift` | Create | provenance 删重试 + app.sqlite fail-closed（Task 4） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCrossFeatureTests.swift` | Create | 画线/交易/replay 跨 feature 故障注入（Task 6） |
| `docs/acceptance/2026-06-14-wave3-pr10b-persistence-integration.md` | Create | 中文非-coder 验收清单（Task 6） |

预估 prod delta ≈ 300 行（coordinator ~200 + lifecycle ~15 + view ~50 + fakes ~40），≤500 内；子项 = 3（autosave+fence / discard+back-save / provenance）。

---

## Task 0: 共享测试 fixture + fake 失败注入/确定性 knobs

> 先建测试基建（fake knobs + 无参 `makeCoordinator`），后续 Task 全复用，根治 plan-review H2（随机 pick flake）/ H3（无参 helper 未定义）/ M1（匹配字段）。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/PersistenceIntegrationFixtures.swift`

- [ ] **Step 0: grep 既有 fake/fixture 形态（接线对齐，不靠记忆）**

Run: `grep -n "class InMemoryPendingTrainingRepository\|class InMemoryCacheManager\|class PreviewTrainingSetDBFactory\|func savePending\|func clearPending\|func loadPending\|func pickRandom\|func delete\|func openAndVerify\|_seedForTesting" ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift`
Run: `grep -n "static func makeCoordinator\|static func validCandles\|static func cachedFile\|CapitalDAO\|struct TrainingSetFile\|struct DrawingObject" ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift ios/Contracts/Sources/KlineTrainerContracts/AppState.swift ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift`
Expected: 确认 `TrainingSessionPersistenceTests.validCandles()`/`cachedFile()`（in-module static，跨文件可见）、`CapitalDAO` 形态、`TrainingSetFile`/`DrawingObject` init 字段。fixture 实现以此为准接线。

- [ ] **Step 1: InMemoryFakes 加 knobs（fake 先行）**

`InMemoryPendingTrainingRepository`（既有 `NSLock` single-slot）追加属性 + 在各方法体最前（取锁后）插失败注入、`savePending` 成功末尾 `saveCount += 1`：

```swift
    /// 注入下一次 savePending/clearPending/loadPending 抛错（消费后自动清除）；mirror 生产：抛前零状态变更。
    public var failNextSavePending: AppError?
    public var failNextClearPending: AppError?
    public var failNextLoadPending: AppError?
    /// savePending 成功落盘次数（coalescing/cadence 断言用）。
    public private(set) var saveCount = 0
```
- `savePending` 体最前：`if let e = failNextSavePending { failNextSavePending = nil; throw e }`；成功路径末 `saveCount += 1`。
- `clearPending` 体最前：`if let e = failNextClearPending { failNextClearPending = nil; throw e }`。
- `loadPending` 体最前：`if let e = failNextLoadPending { failNextLoadPending = nil; throw e }`。

`PreviewTrainingSetDBFactory`（**`struct` 值类型 `InMemoryFakes.swift:16`** —— knobs 必须作 `let` + **加进既有 init**（defaulted），禁 `let factory` 后赋值 stored prop，plan-review R2-1g）：

```swift
    public let corruptFilenames: Set<String>     // 命中 file.lastPathComponent → .dbCorrupted
    public let openErrorAll: AppError?           // 任意 file 抛此错误（测非损坏不删）；优先于 corruptFilenames
    // 既有 init（含 candles 参数）末尾追加两个 defaulted 参数 + 赋值（现有 `PreviewTrainingSetDBFactory()`/
    // `(candles:)` 调用点因默认值不受影响）：
    //   init(... 既有参数 ..., corruptFilenames: Set<String> = [], openErrorAll: AppError? = nil) {
    //       ...; self.corruptFilenames = corruptFilenames; self.openErrorAll = openErrorAll
    //   }
```
并在 `openAndVerify(file:expectedSchemaVersion:)`（非 mutating，读 `let` 即可）体最前插：

```swift
        if let e = openErrorAll { throw e }
        if corruptFilenames.contains(file.lastPathComponent) { throw AppError.persistence(.dbCorrupted) }
```

`InMemoryCacheManager` 追加（`pickRandom` 改为先查 override）：

```swift
    /// 测试可注入确定性选取（默认 nil = randomElement）。根治 provenance 测试 flake。
    public var pickOverride: (([TrainingSetFile]) -> TrainingSetFile?)?
    /// delete 调用文件名记录（provenance 删重试断言）。
    public private(set) var deletedFilenames: [String] = []
```
- `pickRandom()` 体改为：`let fs = sortedLocked(); if let o = pickOverride { return o(fs) }; return fs.randomElement()`（取锁范式以文件现状为准）。
- `delete(_ file:)` 成功路径记 `deletedFilenames.append(file.filename)`。

- [ ] **Step 2: 共享 fixture 文件**

新文件 `PersistenceIntegrationFixtures.swift`（Swift Testing 同 target；`validCandles()`/`cachedFile()`/`CapitalDAO` 复用 `TrainingSessionPersistenceTests` 同-module static——若 grep 显示它们 private/fileprivate 则在本文件重建等价，但默认 internal 可见）：

```swift
import Foundation
@testable import KlineTrainerContracts

/// Wave 3 顺位 10b 持久化集成测试共享 fixture（与 10a TrainingSessionPersistenceTests 同构）。
@MainActor
enum PIFixtures {

    /// 无参 Normal coordinator + 三 fake（autosave/fence/discard/cross-feature 复用）。
    static func makeCoordinator(capital: Double = 50_000)
        -> (TrainingSessionCoordinator, InMemoryRecordRepository,
            InMemoryPendingTrainingRepository, InMemorySessionFinalizationPort) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let cache = InMemoryCacheManager()
        cache._seedForTesting([TrainingSessionPersistenceTests.cachedFile()])
        let coord = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: TrainingSessionPersistenceTests.validCandles()),
            recordRepo: records, pendingRepo: pending, finalization: port,
            settingsDAO: InMemorySettingsDAO(), cache: cache,
            settings: SettingsStore(settingsDAO: TrainingSessionPersistenceTests.CapitalDAO(capital: capital)))
        return (coord, records, pending, port)
    }

    /// provenance coordinator：多缓存文件 + 损坏/错误注入 + 确定性 pick（按 filename 升序，删后顺移）。
    static func makeProvenanceCoordinator(files: [String], corrupt: Set<String>, openError: AppError? = nil)
        -> (TrainingSessionCoordinator, PreviewTrainingSetDBFactory,
            InMemoryCacheManager, InMemoryPendingTrainingRepository) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let port = InMemorySessionFinalizationPort(records: records, pending: pending)
        let cache = InMemoryCacheManager()
        cache._seedForTesting(files.map { Self.file(filename: $0) })
        cache.pickOverride = { fs in fs.sorted { $0.filename < $1.filename }.first }   // 确定性
        let factory = PreviewTrainingSetDBFactory(
            candles: TrainingSessionPersistenceTests.validCandles(),
            corruptFilenames: corrupt, openErrorAll: openError)   // knob 经 init（struct，禁后赋值）
        let coord = TrainingSessionCoordinator(
            dbFactory: factory, recordRepo: records, pendingRepo: pending, finalization: port,
            settingsDAO: InMemorySettingsDAO(), cache: cache,
            settings: SettingsStore(settingsDAO: TrainingSessionPersistenceTests.CapitalDAO(capital: 50_000)))
        return (coord, factory, cache, pending)
    }

    /// localURL.lastPathComponent == filename（使 corruptFilenames 与 cache.delete 字段一致，D8 M1）。
    /// 真实 init（`AppState.swift:142`，plan-review R2-1e）：id 是 Int（非 Int64）；mirror cachedFile() /tmp 约定。
    static func file(filename: String) -> TrainingSetFile {
        TrainingSetFile(id: abs(filename.hashValue), filename: filename,
                        localURL: URL(fileURLWithPath: "/tmp/\(filename)"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    /// 一条样本画线（真实 init `Models.swift:202`，plan-review R2-1f；复用 10a 具体样本）。
    static func sampleDrawing() -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.4)],
                      isExtended: false, panelPosition: 0)
    }
}
```

> **实施者注**：`PIFixtures` 引用的既有符号已核实（plan-review R2-1）：`TrainingSessionPersistenceTests.validCandles()`/`cachedFile()` 是 `internal static`（跨文件可见）；`CapitalDAO` 是 `TrainingSessionPersistenceTests` 的**嵌套类型**（须全限定 `TrainingSessionPersistenceTests.CapitalDAO`）；`_seedForTesting` 在 `#if DEBUG`（测试 DEBUG 跑，可见）。`TrainingSetFile.init(id:filename:localURL:schemaVersion:lastAccessedAt:downloadedAt:)`（`id: Int`）+ `DrawingObject.init(toolType:anchors:isExtended:panelPosition:)` 字段如上已对齐真实 init。Step 0 grep 仅作落地前最终复核。

- [ ] **Step 3: 编译确认（fixture + fakes 成立，无测试引用前先过编译）**

Run: `cd ios/Contracts && swift build --build-tests 2>&1 | tail -20`
Expected: 编译通过（新 knobs 加在既有 fake；fixture 引用既有类型）。若 `TrainingSetFile`/`DrawingObject` init 字段不符 → 按报错对齐（grep 真实 init）。

- [ ] **Step 4: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/PersistenceIntegrationFixtures.swift
git commit -m "test(10b): 共享持久化集成 fixture + fake 失败注入/确定性 pick knobs"
```

---

## Task 1: Autosave coalescing 核心 + 命名常量 + 失败可见

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionAutosaveTests.swift`

- [ ] **Step 1: 写失败测试（autosave 持久 / coalescing / N-cadence / 失败可见 / 非 Normal no-op）**

新文件 `TrainingSessionAutosaveTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TrainingSession autosave（周期落盘 + coalescing + 失败可见，RFC §4.6）")
@MainActor
struct TrainingSessionAutosaveTests {

    @Test("requestAutosave(immediate): Normal 活跃局 → 落 pending 含当前状态")
    func immediate_autosave_persists_current_state() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.holdOrObserve(panel: .upper)                  // 推一 tick = 脏
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        let loaded = try pending.loadPending()
        #expect(loaded != nil)
        #expect(loaded?.globalTickIndex == engine.tick.globalTickIndex)
    }

    @Test("coalescing: 同 runloop 多次 request → 合并为 1 次 savePending（latest-wins，不排队）")
    func coalescing_collapses_burst_to_single_write() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        for _ in 0..<5 { coord.requestAutosave(engine: engine, immediate: true) }  // 同 hop 连发
        await coord.drainAutosaveForTesting()
        #expect(pending.saveCount == 1)
    }

    @Test("N-cadence: 非 immediate 按 AUTOSAVE_TICK_INTERVAL 节流（N=3 → 每 3 次脏存 1 次）")
    func tick_cadence_throttles_non_immediate() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        coord.autosaveTickInterval = 3
        let engine = try await coord.startNewNormalSession()
        for _ in 0..<3 {
            engine.holdOrObserve(panel: .upper)
            coord.requestAutosave(engine: engine, immediate: false)
            await coord.drainAutosaveForTesting()
        }
        #expect(pending.saveCount == 1)                      // 第 3 次才落盘
    }

    @Test("失败可见: savePending 抛 → lastAutosaveError 置位 + session 不 teardown（§4.6）")
    func autosave_failure_is_visible_and_non_teardown() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        pending.failNextSavePending = .persistence(.diskFull)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.lastAutosaveError == .persistence(.diskFull))
        #expect(coord.activeEngine === engine)
        #expect(coord.activeReader != nil)
    }

    @Test("review/replay 非 Normal: requestAutosave no-op（无 pending 语义）")
    func autosave_noop_for_non_normal() async throws {
        let (coord, records, pending, _) = PIFixtures.makeCoordinator()
        let n = try await coord.startNewNormalSession()
        while n.tick.globalTickIndex < n.tick.maxTick { n.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: n)
        await coord.endSession()
        let r = try await coord.replay(recordId: id!)
        coord.requestAutosave(engine: r, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() == nil)
        _ = records
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingSessionAutosaveTests 2>&1 | tail -20`
Expected: 编译失败 —— `requestAutosave`/`drainAutosaveForTesting`/`lastAutosaveError`/`autosaveTickInterval` 未定义。

- [ ] **Step 3: 实现 autosave 状态机 + 常量**

`TrainingSessionCoordinator.swift` 顶层（`import Foundation` 后、`@MainActor class` 前）加：

```swift
/// RFC §4.6：周期 autosave cadence floor（命名契约常量，modules:1747）。
/// N=1 = 每 state-dirtying 动作即存（coalesced）；不变量：未落盘进度丢失 ≤ N tick 等价脏窗。
public let AUTOSAVE_TICK_INTERVAL = 1
/// cadence 上限（实测写延迟超帧预算时可上调 N ≤ 此值；本 PR 不上调）。
public let AUTOSAVE_MAX_INTERVAL = 5
```

class 内 `makeSessionKey` 声明（`:40`）后追加 autosave 状态：

```swift
    // MARK: - Wave 3 顺位 10b：周期 autosave 状态机（RFC §4.6）+ 终态 fence（§4.7d）

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?     // 在飞写句柄（fence drain）
    @ObservationIgnored private var autosaveDirty = false                // 写中又脏 → 写完再存一次
    @ObservationIgnored private var terminating = false                  // §4.7d 栅栏
    @ObservationIgnored private var ticksSinceAutosave = 0               // N-tick cadence 计数
    @ObservationIgnored var autosaveTickInterval = AUTOSAVE_TICK_INTERVAL // 可注入（@testable）
    /// §4.6 失败可见：最近一次 autosave 失败（非阻塞指示；UI/@testable 读；不 teardown）。
    @ObservationIgnored public private(set) var lastAutosaveError: AppError?

    /// 请求 autosave（脏动作后调）。immediate=交易/画线/background flush（绕 N 节流）；
    /// 非 immediate=tick 推进（按 autosaveTickInterval 节流）。terminating/非 Normal → no-op（§4.7d/§4.6）。
    public func requestAutosave(engine: TrainingEngine, immediate: Bool) {
        guard !terminating, engine.flow.mode == .normal else { return }
        if !immediate {
            ticksSinceAutosave += 1
            guard ticksSinceAutosave >= autosaveTickInterval else { return }
        }
        ticksSinceAutosave = 0
        autosaveDirty = true
        guard autosaveTask == nil else { return }            // 已排程 → 合并
        autosaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.autosaveDirty && !self.terminating {
                self.autosaveDirty = false
                do {
                    try await self.saveProgress(engine: engine)
                    self.lastAutosaveError = nil
                } catch {
                    self.lastAutosaveError = (error as? AppError)
                        ?? .internalError(module: "E6b", detail: "autosave: \(error)")
                }
            }
            self.autosaveTask = nil
        }
    }

    /// background/inactive 立即 flush（绕 N）+ 等写完成（OS 可能随后杀进程）。§4.6 item 4。
    public func flushAutosave(engine: TrainingEngine) async {
        requestAutosave(engine: engine, immediate: true)
        await autosaveTask?.value
    }

    #if DEBUG
    /// 测试钩子：等在飞 autosave 写完成（生产无 await 点，测试需确定性排空）。
    func drainAutosaveForTesting() async { await autosaveTask?.value }
    #endif
```

`startNewNormalSession` 成功路径（`:82` `activeSessionKey = makeSessionKey()` 后）+ `resumePending` 成功路径（`:118` `activeSessionKey = pending.sessionKey` 后）各插：

```swift
            resetAutosaveState()                     // 新 session：清栅栏/脏/cadence/错误（D3）
```

`endSession()`（`:293`）体最前插（D3 防句柄泄漏）：

```swift
        autosaveTask?.cancel(); autosaveTask = nil
        autosaveDirty = false; lastAutosaveError = nil; ticksSinceAutosave = 0
```

私有 helper 区（`markers(from:)` 后）加：

```swift
    /// session 启动重置 autosave 栅栏/状态（D3）。
    private func resetAutosaveState() {
        terminating = false
        autosaveDirty = false
        ticksSinceAutosave = 0
        lastAutosaveError = nil
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingSessionAutosaveTests 2>&1 | tail -10`
Expected: 5 测试 PASS。
Run: `cd ios/Contracts && swift test --filter "TrainingSessionPersistence|TrainingSessionCoordinator" 2>&1 | tail -5`
Expected: PASS（既有 saveProgress/finalize/key 行为不变）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionAutosaveTests.swift
git commit -m "feat(10b): 周期 autosave coalescing 状态机 + 失败可见 + N-cadence（RFC §4.6）"
```

---

## Task 2: 终态 fence（finalize 前 drain/reject autosave）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionFenceTests.swift`

- [ ] **Step 1: 写失败测试（save-before/after-finalize 双序 + 无 resurrection + 无 duplicate + 新局重置）**

新文件 `TrainingSessionFenceTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TrainingSession 终态 fence（finalize 前排空 autosave，RFC §4.7d）")
@MainActor
struct TrainingSessionFenceTests {

    @Test("save-before-finalize: 在飞 autosave 被 fence drain，finalize 后 pending 清且 record 1 条")
    func autosave_before_finalize_drained_no_resurrection() async throws {
        let (coord, records, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        coord.requestAutosave(engine: engine, immediate: true)   // 末态脏写排队
        let id = try await coord.finalize(engine: engine)        // fence → drain → 单事务
        #expect(id != nil)
        #expect(try pending.loadPending() == nil)
        #expect(try records.listRecords(limit: nil).count == 1)
    }

    @Test("save-after-finalize-start: finalize 后 requestAutosave 被拒（terminating），pending 不复活")
    func autosave_after_finalize_is_rejected() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        _ = try await coord.finalize(engine: engine)
        coord.requestAutosave(engine: engine, immediate: true)   // 终态后迟到脏写
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() == nil)
    }

    @Test("crash-after-commit relaunch: finalize 成功后无 pending → resume 返 nil（不二次 finalize）")
    func finalize_then_resume_returns_nil() async throws {
        let (coord, records, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        _ = try await coord.finalize(engine: engine)
        await coord.endSession()
        #expect(try await coord.resumePending() == nil)
        #expect(try records.listRecords(limit: nil).count == 1)
        _ = pending
    }

    @Test("新 session 重置栅栏: finalize 后开新局 → autosave 恢复工作（terminating 重置）")
    func new_session_resets_fence() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let e1 = try await coord.startNewNormalSession()
        while e1.tick.globalTickIndex < e1.tick.maxTick { e1.holdOrObserve(panel: .upper) }
        _ = try await coord.finalize(engine: e1)
        await coord.endSession()
        let e2 = try await coord.startNewNormalSession()         // terminating 须重置
        e2.holdOrObserve(panel: .upper)
        coord.requestAutosave(engine: e2, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() != nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingSessionFenceTests 2>&1 | tail -15`
Expected: `autosave_after_finalize_is_rejected` 等失败 —— finalize 未 fence。

- [ ] **Step 3: 实现 fence + finalize 集成**

`TrainingSessionCoordinator.swift` autosave 区（`flushAutosave` 后）加：

```swift
    /// §4.7d 终态栅栏：置 terminating（拒新 autosave）+ 排空在飞写（排空时见 terminating 即退出不落盘）。
    /// 单线程 @MainActor 保证 finalize/discard 与 autosave Task 不并发（await 时 Task 运行并见 terminating）。
    private func fenceAndDrainAutosaves() async {
        terminating = true
        await autosaveTask?.value
    }
```

`finalize(engine:)`（`:218`）体内，`guard engine.flow.shouldSaveRecord() else { return nil }`（`:219`）**之后**、active 上下文 guard（`:222`）**之前**插：

```swift
        await fenceAndDrainAutosaves()           // §4.7d：单事务入账前排空排队 autosave，防终态脏写复活 pending
```

（finalize 早返 nil 的 Review/Replay 分支在 fence 前 return，不受影响。）

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingSessionFenceTests 2>&1 | tail -8`
Expected: 4 测试 PASS。
Run: `cd ios/Contracts && swift test --filter "TrainingSessionPersistence" 2>&1 | tail -5`
Expected: PASS（10a finalize 幂等/失败保留不变）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionFenceTests.swift
git commit -m "feat(10b): 终态 fence —— finalize 前 drain/reject autosave（RFC §4.7d）"
```

---

## Task 3: discard 持久终态 + back-save 失败保留

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionFenceTests.swift`（同 suite 追加）

- [ ] **Step 1: 写失败测试（discard durable + 迟到拒绝 + clear 失败保留）**

`TrainingSessionFenceTests.swift` 追加：

```swift
    @Test("discard durable: fence → 清 pending → endSession；resume 返 nil（无复活）§4.7e")
    func discard_clears_pending_and_tears_down() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.holdOrObserve(panel: .upper)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() != nil)
        try await coord.discardSession()
        #expect(try pending.loadPending() == nil)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
        #expect(try await coord.resumePending() == nil)
    }

    @Test("discard 后迟到 autosave 被拒（terminating）→ 不重建 pending")
    func discard_fences_late_autosave() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.holdOrObserve(panel: .upper)
        try await coord.discardSession()
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() == nil)
    }

    @Test("discard clearPending 失败: 保留 active session（不 teardown）供 retry §4.7e")
    func discard_clear_failure_preserves_session() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.holdOrObserve(panel: .upper)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        pending.failNextClearPending = .persistence(.diskFull)
        await #expect(throws: AppError.self) { try await coord.discardSession() }
        #expect(coord.activeEngine === engine)
        #expect(coord.activeReader != nil)
        try await coord.discardSession()                 // retry 成功
        #expect(coord.activeEngine == nil)
        #expect(try pending.loadPending() == nil)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingSessionFenceTests 2>&1 | tail -15`
Expected: 编译失败 —— `discardSession` 未定义。

- [ ] **Step 3: 实现 `discardSession` + lifecycle 转发**

`TrainingSessionCoordinator.swift` `endSession()`（`:300` `}` 后）追加：

```swift
    /// §4.7e discard 持久终态：fence autosaves → 清 `pending_training` → endSession（durable 不复活）。
    /// 清 pending 失败 → 保留 active session（不 teardown）供 retry，透传 AppError。
    /// review/replay：clearPending 删 0 行无害（D4 M3），失败语义一致。
    public func discardSession() async throws {
        await fenceAndDrainAutosaves()
        do {
            try pendingRepo.clearPending()
        } catch {
            throw (error as? AppError)
                ?? .internalError(module: "E6b", detail: "discard clearPending: \(error)")
        }
        await endSession()
    }
```

`TrainingSessionLifecycle.swift`（`endAfterSettlement` 方法后）追加：

```swift
    /// §4.7e：durable 放弃当前局（清 pending + 关 reader + 清 context）。清 pending 失败抛（caller 保留重试）。
    public func discard() async throws {
        try await coordinator.discardSession()
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter TrainingSessionFenceTests 2>&1 | tail -10`
Expected: 7 测试（Task 2 的 4 + 本 3）PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionFenceTests.swift
git commit -m "feat(10b): discard 持久终态 —— fence→清 pending→endSession + 清失败保留（RFC §4.7e）"
```

---

## Task 4: provenance-aware 恢复（source-based 路由 + app.sqlite 安全红线）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionProvenanceTests.swift`

> fake knobs（`corruptFilenames`/`openErrorAll`/`pickOverride`/`deletedFilenames`/`failNextLoadPending`）已在 Task 0 落地。

- [ ] **Step 1: 写失败测试（训练组删重试 / 缓存耗尽 / app.sqlite fail-closed / 非损坏不删）**

新文件 `TrainingSessionProvenanceTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TrainingSession provenance 恢复（source-based 路由，RFC §4.7f）")
@MainActor
struct TrainingSessionProvenanceTests {

    @Test("训练组损坏: startNew 先选损坏文件（确定性）→ 删该文件 + 用好文件成功开局")
    func corrupt_training_set_is_deleted_and_recovered() async throws {
        // pickOverride 按 filename 升序 → 先选 "bad"（< "good"）；bad 删后选 good。
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(
            files: ["bad.sqlite", "good.sqlite"], corrupt: ["bad.sqlite"])
        let engine = try await coord.startNewNormalSession()
        #expect(engine.flow.mode == .normal)                       // 成功开局
        #expect(cache.deletedFilenames.contains("bad.sqlite"))     // 损坏文件被删（确定性，非 flake）
        #expect(!cache.deletedFilenames.contains("good.sqlite"))   // 好文件不删
    }

    @Test("全部损坏: 删尽 → throw .trainingSet(.fileNotFound)（caller 走重下路径）")
    func all_corrupt_exhausts_to_fileNotFound() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(
            files: ["a.sqlite", "b.sqlite"], corrupt: ["a.sqlite", "b.sqlite"])
        await #expect(throws: AppError.trainingSet(.fileNotFound)) {
            _ = try await coord.startNewNormalSession()
        }
        #expect(cache.deletedFilenames.count == 2)
    }

    @Test("app.sqlite 损坏 fail-closed: loadPending 抛 .dbCorrupted → 透传 + 零 cache.delete（安全红线）")
    func app_sqlite_corruption_never_deletes_cache() async throws {
        let (coord, _, cache, pending) = PIFixtures.makeProvenanceCoordinator(
            files: ["x.sqlite"], corrupt: [])
        pending.failNextLoadPending = .persistence(.dbCorrupted)   // app.sqlite source
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try await coord.resumePending()
        }
        #expect(cache.deletedFilenames.isEmpty)                    // 绝不删训练组缓存
    }

    @Test("非损坏错误不删: diskFull 透传，不误删训练组文件")
    func non_corruption_error_does_not_delete() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(
            files: ["y.sqlite"], corrupt: [], openError: .persistence(.diskFull))
        await #expect(throws: AppError.persistence(.diskFull)) {
            _ = try await coord.startNewNormalSession()
        }
        #expect(cache.deletedFilenames.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingSessionProvenanceTests 2>&1 | tail -15`
Expected: 失败 —— startNew 遇损坏文件直接 throw（无删重试）。

- [ ] **Step 3: 实现 provenance 路由**

`TrainingSessionCoordinator.swift`：

(a) 私有 helper 区加损坏判据（D7）：

```swift
    /// D7：训练组文件可弃损坏判据（dbFactory.openAndVerify 对坏文件抛的可恢复错误）。
    /// 仅在 openReader 调用栈内用 → 保证 app.sqlite source 永不命中（安全红线，§4.7f）。
    private func isCorruptTrainingSet(_ error: Error) -> Bool {
        switch error as? AppError {
        case .persistence(.dbCorrupted): return true
        case .trainingSet(.emptyData), .trainingSet(.versionMismatch),
             .trainingSet(.crcFailed), .trainingSet(.unzipFailed): return true
        default: return false                      // fileNotFound/diskFull/internalError 不删
        }
    }
```

(b) `startNewNormalSession`（`:64`）：原 `:66-70`：

```swift
        guard let file = cache.pickRandom() else {
            throw AppError.trainingSet(.fileNotFound)
        }
        let start = try startingCapital()
        let reader = try openReader(for: file)
```

改为（`startingCapital()` 上移到循环外——app.sqlite source 不进删重试，D6）：

```swift
        let start = try startingCapital()                    // app.sqlite source；reader 未开，throw 无副作用
        // §4.7f provenance：选训练组 → 打开；损坏（source=训练组只读 DB）→ 删 + 重试另一文件。
        var attempts = cache.listAvailable().count + 1       // 有界（即便 delete 静默失败仍终止）
        var openedReader: (any TrainingSetReader)?
        var openedFile: TrainingSetFile?
        while attempts > 0, openedReader == nil {
            attempts -= 1
            guard let file = cache.pickRandom() else {
                throw AppError.trainingSet(.fileNotFound)    // 缓存耗尽 → caller 重下
            }
            do {
                openedReader = try openReader(for: file)
                openedFile = file
            } catch where isCorruptTrainingSet(error) {
                try? cache.delete(file)                      // 删损坏训练组文件（可弃），重试
            }
        }
        guard let reader = openedReader, let file = openedFile else {
            throw AppError.trainingSet(.fileNotFound)
        }
```

（下游 `do { let allCandles = ...; activeFile = file ... }` 块不变。）

(c) `resumePending`（`:93`）：`:95-96`：

```swift
        let file = try cachedFile(filename: pending.trainingSetFilename)
        let reader = try openReader(for: file)
```

改为：

```swift
        let file = try cachedFile(filename: pending.trainingSetFilename)
        let reader: any TrainingSetReader
        do {
            reader = try openReader(for: file)
        } catch where isCorruptTrainingSet(error) {
            try? cache.delete(file)                          // 训练组损坏，孤儿 pending 不可恢复
            try pendingRepo.clearPending()                   // durable 清（app.sqlite 写，非删）
            return nil                                       // 首页降级到新局
        }
```

（注：`loadPending`（`:94`）在此 do/catch **之前** → 其 `.dbCorrupted`（app.sqlite）原样透传，不进 delete，安全红线。）

(d) `review`（`:132`）+ `replay`（`:162`）：各自 `let reader = try openReader(for: file)` 改为：

```swift
        let reader: any TrainingSetReader
        do {
            reader = try openReader(for: file)
        } catch where isCorruptTrainingSet(error) {
            try? cache.delete(file)                          // 训练组损坏可弃；record 仍在 app.sqlite（不删）
            throw AppError.persistence(.dbCorrupted)         // 无法替代，surface
        }
```

（注：`loadRecordBundle`（review `:133`/replay `:163`）在 do/catch **之前** → app.sqlite `.dbCorrupted` 透传不删。）

**安全红线复核**：以上四处 `cache.delete` 全在 `openReader` catch 内；app.sqlite DAO（`statistics`/`loadPending`/`loadRecordBundle`）调用全在各 catch 之外 → 其 `.dbCorrupted` 透传 fail-closed。

- [ ] **Step 4: 跑测试确认通过 + 既有不回归**

Run: `cd ios/Contracts && swift test --filter TrainingSessionProvenanceTests 2>&1 | tail -8`
Expected: 4 测试 PASS。
Run: `cd ios/Contracts && swift test --filter "TrainingSessionCoordinator|TrainingSessionPersistence|TrainingSessionConstruction" 2>&1 | tail -5`
Expected: PASS（startNew/resume/review/replay happy-path 不变）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionProvenanceTests.swift
git commit -m "feat(10b): provenance-aware 恢复 —— 训练组损坏删重试 + app.sqlite fail-closed（RFC §4.7f）"
```

---

## Task 5: UI 接线（autosave 触发 + background flush + 放弃 discard + 返回失败保留）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`

> UI 薄壳：autosave 逻辑已在 coordinator（Task 1-4 全测）；本 task 仅接线 + Catalyst 编译闸门验证。无新单元测试（SwiftUI 壳，per 仓库 U1/U2/U3 范式经 Catalyst build-for-testing 守护）。**line ref 以符号锚定**（实施前 grep 对齐当前行号）。

- [ ] **Step 1: lifecycle 加 autosave/flush 转发**

`TrainingSessionLifecycle.swift`（`discard()` 后）追加：

```swift
    /// 脏状态动作后请求 autosave（immediate=交易/画线；非 immediate=tick 推进按 N 节流）。§4.6。
    public func autosave(immediate: Bool) {
        coordinator.requestAutosave(engine: engine, immediate: immediate)
    }

    /// scenePhase 后台/失活：立即 flush + 等写完成（OS 可能随后杀进程）。§4.6 item 4。
    public func flushForBackground() async {
        await coordinator.flushAutosave(engine: engine)
    }
```

- [ ] **Step 2: TrainingView autosave 触发 + scenePhase flush 接线**

`TrainingView.swift`（grep 锚 `engine.tick.globalTickIndex` / `scenePhase` / `performTrade` / `engine.drawings` 定位）：

(a) scenePhase `.onChange`（符号 `.onChange(of: scenePhase)`，现 `:76-78`，仅 `.active`）扩为 additive 后台 flush：

```swift
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                engine.onSceneActivated()                       // modules §U2 既有动画链（不替换）
            case .inactive, .background:
                Task { await lifecycle.flushForBackground() }   // §4.6：后台立即 flush
            @unknown default:
                break
            }
        }
```

(b) tick autosave：把既有单语句 `.onChange(of: engine.tick.globalTickIndex) { _, _ in maybeAutoEnd() }`（符号锚，现 `:75`——**合并进同一 closure，不另建重复 onChange**）改为：

```swift
        .onChange(of: engine.tick.globalTickIndex) { _, _ in
            lifecycle.autosave(immediate: false)                // §4.6：tick 推进按 N 节流
            maybeAutoEnd()
        }
```

(c) 画线 autosave：加观察 `engine.drawings.count`（commit/delete 单一真相，不推 tick → 真 inter-tick，D9）：

```swift
        .onChange(of: engine.drawings.count) { _, _ in
            lifecycle.autosave(immediate: true)                 // §4.6：画线即存
        }
```

(d) 交易 autosave：`performTrade`（符号锚 `private func performTrade`，现 `:165`）体内，**仅成功路径**追加（buy/sell 推 tick 也会触发 (b) 的 onChange，coalescing 合一；失败不触，plan-review L3）。在既有 `let result: Result<...>` / `switch action { ... }` 之后、`feedback` 构造处插：

```swift
        if case .success = result {
            lifecycle.autosave(immediate: true)                 // §4.6：buy/sell 成交即时 durable
        }
```

- [ ] **Step 3: 放弃→discard（durable）+ 返回失败保留**

(a) 放弃按钮（符号锚 `Button("放弃"`，现 `:92-94`）从 `endAfterSettlement`（留 pending）改 durable discard：

```swift
            Button("放弃", role: .cancel) {
                Task {
                    try? await lifecycle.discard()              // §4.7e：durable 清局（清 pending 失败则留存，可恢复）
                    onExit()
                }
            }
```

（discard 清 pending 失败用 `try?` 吞后仍 onExit 是可接受降级：失败时 pending 留存可从最近存档恢复，与 10a「放弃=进度保留至最近存档」措辞兼容；不引入新 alert 层避免 scope 膨胀。注释更新去掉「仅关 reader」旧描述。）

(b) 返回按钮（符号锚 `Button("返回")`，现 `:124`）从 `try? back(); onExit()` 改失败保留：

```swift
            Button("返回") {
                Task {
                    do { try await lifecycle.back(); onExit() }
                    catch { backFailed = true }                 // §4.7a/§4.6：保存失败留局内，不丢数据/不泄漏 reader
                }
            }
```

加状态 `@State private var backFailed = false`（与其它 `@State` 同处）+ alert（与既有 `finalizeFailed` alert 同级）：

```swift
        .alert("保存进度失败", isPresented: $backFailed) {
            Button("重试") {
                Task { do { try await lifecycle.back(); onExit() } catch { backFailed = true } }
            }
            Button("放弃", role: .destructive) {
                Task { try? await lifecycle.discard(); onExit() }   // durable 弃局退出
            }
        } message: {
            Text("当前进度未能写入存档。可重试保存，或放弃本局退出。")
        }
```

- [ ] **Step 4: 编译 + Catalyst build-for-testing 闸门**

Run: `cd ios/Contracts && swift build 2>&1 | tail -5`
Expected: 编译通过。
Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: 全量 PASS（autosave/fence/provenance + 既有 942 基线 + 本 PR 新测试）。
Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -3`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "feat(10b): U2 autosave 触发接线 + 后台 flush + 放弃 durable discard + 返回失败保留（RFC §4.6/§4.7e）"
```

---

## Task 6: 跨 feature 故障注入集成测试 + 验收文档

**Files:**
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCrossFeatureTests.swift`
- Create: `docs/acceptance/2026-06-14-wave3-pr10b-persistence-integration.md`

- [ ] **Step 1: 写跨 feature 集成测试（画线/交易/replay 加固 save/finalize/teardown）**

新文件 `TrainingSessionCrossFeatureTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TrainingSession 跨 feature 持久化加固（drawing/trade/replay × autosave/fence，10b）")
@MainActor
struct TrainingSessionCrossFeatureTests {

    @Test("交易成功后 autosave → resume 含该笔交易（buy 推 tick，§4.6 覆盖交易脏写）")
    func buy_then_autosave_then_resume_has_trade() async throws {
        let (coord, _, _, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        let before = engine.tradeOperations.count
        let r = engine.buy(panel: .upper, tier: .tier1)              // 改 position/cash + 推 tick
        guard case .success = r else { Issue.record("buy 须成功（50_000 本金可成交 tier1）"); return }
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        await coord.endSession()
        let resumed = try await coord.resumePending()
        #expect(resumed != nil)
        #expect((resumed?.tradeOperations.count ?? 0) > before)
    }

    @Test("画线 commit 后 autosave → resume 含该画线（engine.drawings 单一真相，#103×10b）")
    func draw_then_autosave_then_resume_has_drawing() async throws {
        let (coord, _, _, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.appendDrawing(PIFixtures.sampleDrawing())
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        await coord.endSession()
        let resumed = try await coord.resumePending()
        #expect((resumed?.drawings.count ?? 0) == 1)
    }

    @Test("replay 非持久不变量在 autosave 下成立：requestAutosave 不写 records/pending（§4.4e×§4.6）")
    func replay_nonpersisting_holds_under_autosave() async throws {
        let (coord, records, pending, _) = PIFixtures.makeCoordinator()
        let n = try await coord.startNewNormalSession()
        while n.tick.globalTickIndex < n.tick.maxTick { n.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: n)
        await coord.endSession()
        let r = try await coord.replay(recordId: id!)
        r.holdOrObserve(panel: .upper)
        coord.requestAutosave(engine: r, immediate: true)            // replay 下脏写
        await coord.drainAutosaveForTesting()
        #expect(try pending.loadPending() == nil)                    // 不触 pending
        #expect(try records.listRecords(limit: nil).count == 1)      // 不增 record
    }

    @Test("discard 画线局 → resume 无复活（drawing checkpoint 被 durable 清）")
    func discard_drawing_session_no_resurrection() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.appendDrawing(PIFixtures.sampleDrawing())
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        try await coord.discardSession()
        #expect(try await coord.resumePending() == nil)
        _ = pending
    }
}
```

- [ ] **Step 2: 跑测试确认通过 + 全量基线**

Run: `cd ios/Contracts && swift test --filter TrainingSessionCrossFeatureTests 2>&1 | tail -8`
Expected: 4 测试 PASS。
Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `Test run with <≥942+本PR新增> tests in <N> suites passed`，0 failures。

- [ ] **Step 3: 写验收文档**

`docs/acceptance/2026-06-14-wave3-pr10b-persistence-integration.md`（中文非-coder 可执行；action/expected/pass-fail；禁用 `.claude/workflow-rules.json` 列的禁止措辞）：
- 标题 + PR 范围（§4.6 autosave / §4.7d fence / §4.7e discard / §4.7f provenance；明列**不含** 10c 项）
- 步骤表（浏览器看 Files changed 新文件 / `AUTOSAVE_TICK_INTERVAL` 常量在 coordinator / `requestAutosave`/`fenceAndDrainAutosaves`/`discardSession`/`isCorruptTrainingSet` 方法在位 / 三 required check 全绿 / CI `swift test` 末行 tests passed / 各 suite 测试名命中）
- 本地复核命令（`swift test 2>&1 | tail -3` / Catalyst build-for-testing）
- 范围外（10c）：fixture provisioning / E2E smoke / 边界 Toast / touch-on-use

- [ ] **Step 4: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCrossFeatureTests.swift \
        docs/acceptance/2026-06-14-wave3-pr10b-persistence-integration.md
git commit -m "test(10b): 跨 feature 持久化故障注入集成测试 + 中文验收清单"
```

---

## § 范围与 10c 切分（RFC §4.7 总实施归属 + outline「~500+ 行 plan 须拆」）

**本 PR（10b 核心，~300 prod / 3 子项）闭合的 RFC 契约：** §4.6 周期 autosave（触发面 tick/buy/sell/draw + N-cadence + coalescing latest-wins + background flush + 失败可见非 teardown）/ §4.7d 终态 fence / §4.7e discard 持久终态 / §4.7f provenance（训练组删重试 / app.sqlite fail-closed 安全红线）/ 跨 feature 故障注入（drawing/trade/replay × autosave/fence）。

**切出至顺位 10c：** 全 app fixture provisioning（debug seed 经 `AppContainer`，outline §三.3 R3-F2）/ 生产路径 fixture E2E smoke（真实 `DownloadAcceptanceRunner`，R1-F1）/ 边界错误统一 Toast 层 / cache touch-on-use（E6a-R3）。

**10c 须先于顺位 13 收尾**（outline `docs/superpowers/specs/2026-06-09-wave3-outline-design.md` §三.3 L180-181：「顺位 13 收尾 + 任何 freeze tag 阻塞依赖 = Wave 3 运行时矩阵〔经顺位 10 fixture provisioning 执行〕」——13 的运行时矩阵硬依赖 fixture provisioning）。

**切分理由**：core 四契约共享 coordinator autosave/fence 状态机 + 训练组打开路径，紧耦合、可独立测试闭合；10c 是 app-composition + 运行时矩阵 enablement，与持久化生命周期契约正交（不同文件 `AppContainer`/`HomeView`/runbook）。合入则 PR >500 行 + 8 子项违 ≤500/≤3 纪律 + 触发 codex distributed-reliability drilldown 风险。RFC §4.7「总实施归属」（L221）明列 10b = (d)+(e)+(f)+跨 feature 故障注入；fixture/smoke 是 outline §三.3 residual 非 RFC 契约，归 10c 不违 RFC。

---

## Self-Review（plan 作者自查，per writing-plans skill）

**1. Spec coverage**：§4.6（Task 1+5）/ §4.7d（Task 2）/ §4.7e（Task 3+5）/ §4.7f（Task 4）/ 跨 feature 故障注入（Task 6）/ 失败可见（Task 1）/ background flush（Task 5）/ back-save 失败保留（Task 5 D5）—— 全 RFC 10b 项有对应 task。10c 项显式标注切出（引 outline §三.3 依赖）。✅
**2. Placeholder scan**：无 TBD/TODO；每 code step 有完整代码；测试有具体断言。fixture 骨架（`PIFixtures.file`/`sampleDrawing`）标注「字段按 grep 真实 init 对齐」——这些是既有类型非本 PR 新增，骨架+grep 注非 placeholder。✅
**3. Type consistency**：`requestAutosave(engine:immediate:)` / `flushAutosave(engine:)` / `fenceAndDrainAutosaves()` / `discardSession()` / `isCorruptTrainingSet(_:)` / `resetAutosaveState()` / `autosaveTickInterval` / `lastAutosaveError` 跨 Task 1-6 一致；lifecycle `autosave(immediate:)`/`flushForBackground()`/`discard()` 一致；fake knobs `failNextSavePending`/`failNextClearPending`/`failNextLoadPending`/`saveCount`/`corruptFilenames`/`openErrorAll`/`pickOverride`/`deletedFilenames` 一致；fixture `PIFixtures.makeCoordinator`/`makeProvenanceCoordinator`/`file`/`sampleDrawing` 一致。✅
**plan-review（opus xhigh R1）应用**：H1（buy/sell 推 tick 校正 prose + 测试 `.success` 断言）/ H2（pickOverride 确定性根治 flake）/ H3（`PIFixtures` 无参 helper 显式定义）/ M1（localURL.lastPathComponent 匹配）/ M3（review/replay clearPending 写语义）/ M4（discard-failure fence-lock 显式）/ M5（10c→13 引 outline §三.3）/ L1-L3（无 1.5 残留、符号锚 line ref、performTrade 仅成功触发）全数纳入。
