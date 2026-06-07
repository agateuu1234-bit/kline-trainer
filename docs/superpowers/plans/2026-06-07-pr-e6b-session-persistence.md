# E6b TrainingSessionCoordinator 进度保存/正式结束/会话清理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本项目只用 subagent-driven-development（不用 executing-plans）。每个 Task 派一个 fresh sonnet 4.6 high-effort subagent；Task 之间主线两阶段 review。

**Goal:** 把 E6a 已落地的 `TrainingSessionCoordinator` 中 3 个仍为 `fatalError("Wave 2 E6 impl")` 的会话**收尾**方法（`saveProgress` / `finalize` / `endSession`）替换为真实现：从运行时 `TrainingEngine` 状态打包 `PendingTraining`（进度保存）/ `TrainingRecord`+ops+drawings（正式结束入账），并在 session 结束时释放 reader。

**Architecture:** 在现有 `TrainingSessionCoordinator.swift`（`@MainActor @Observable final class`，6 依赖 DI init 已 Wave 0 冻结）内：① 新增 3 个 `@ObservationIgnored` 内部存储（`activeFile` / `activeStartedAt` / 可注入时钟 `now`）追踪「当前 session 的持久化上下文」——因为 `saveProgress`/`finalize` 需要训练组**文件名**与**起始年月/股票元数据**，而 `TrainingEngine` 不携带这些；② 在 E6a 已落地的 4 个 open 方法（`startNewNormalSession`/`resumePending`/`review`/`replay`）的成功分支各加 1-2 行记录该上下文；③ 实现 3 个收尾方法 + 私有 helper。`finalize` 走 `recordRepo.insertRecord` 入账并 `pendingRepo.clearPending`；`endSession` 关闭 `activeReader` 并清空全部活跃上下文。

**Tech Stack:** Swift 6（toolchain，strict concurrency on）+ SwiftPM（`KlineTrainerContracts` package，root `ios/Contracts/`）+ Swift Testing（`@Test`/`@Suite`/`#expect`）+ `@MainActor` + `@Observable` + Foundation（`JSONEncoder`/`Calendar`/`Date`/`TimeZone`）。依赖：E5 `TrainingEngine`（顺位 2/3，accessor 全只读）、E6a 4 open 方法 + 5 私有 helper（PR #83）、P4 `RecordRepository`/`PendingTrainingRepository`、P3b `TrainingSetReader.loadMeta()`、M0.3 `TrainingRecord`/`PendingTraining`/`DrawdownAccumulator`、M0.4 `AppError`。

**Design Doc / 上游契约:**
- `kline_trainer_modules_v1.4.md` §E6（L1676-1684 三方法契约）+ §M0.3（L488-535 `TrainingRecord`/`PendingTraining`/`DrawdownAccumulator` 字段）
- `kline_trainer_plan_v1.5.md` §6.2/§6.3（L417-419 records DDL 语义 + L988-1009 结算窗显示）+ §4.2（L738-748 最大回撤）+ §6.1（L860 胜率/累计资金）
- `docs/superpowers/plans/2026-06-07-pr-e6a-session-coordinator-construction.md`（E6a D1-D12 + 登记 residual E6a-R2/R3，本 plan 承接）
- **user 裁决（2026-06-07）**：`finalize` 写 `TrainingRecord.totalCapital = 本局起始资金`（方案 A，见 D1）

---

## Pre-flight Gate (Step 0 — subagent 必须在 Task 1 前跑)

避免 spec drift：subagent 写代码前 grep baseline 真签名，按实测对齐 plan。**§〇 教训（`feedback_explore_agent_stale_spec_trust`）：以实际代码为准，不信 spec checklist。**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6b-session-persistence/ios/Contracts"
# (1) E6b 三方法当前 fatalError 体 + E6a 已落地的 4 open 方法 + active 字段 + 私有 helper
grep -n "func saveProgress\|func finalize\|func endSession\|func startNewNormalSession\|func resumePending\|func review\|func replay\|activeEngine\|activeReader\|private func " \
  Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift
# (2) TrainingEngine 只读 accessor（finalize/saveProgress 读取源）
grep -n "public private(set) var\|public var\|public let\|var currentTotalCapital\|var returnRate\|var maxDrawdown" \
  Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift
# (3) TrainingFlowController 门控（finalize gating）+ TickEngine accessor
grep -n "func shouldSaveRecord\|var mode\|enum TrainingMode\|globalTickIndex\|var maxTick" \
  Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift \
  Sources/KlineTrainerContracts/TickEngine.swift \
  Sources/KlineTrainerContracts/Models/Models.swift
# (4) 数据模型字段（PendingTraining / TrainingRecord / DrawdownAccumulator / TrainingSetMeta / TradeOperation / TradeDirection）
grep -n "struct PendingTraining\|struct TrainingRecord\|struct DrawdownAccumulator\|let \|var " \
  Sources/KlineTrainerContracts/AppState.swift | head -60
grep -n "struct TrainingSetMeta\|enum TradeDirection\|case buy\|case sell" \
  Sources/KlineTrainerContracts/Models/Models.swift
# (5) 依赖协议签名 + Repo 真实现行为（statistics 累计模型）
grep -n "func " Sources/KlineTrainerContracts/Persistence/RecordRepository.swift \
  Sources/KlineTrainerContracts/Persistence/PendingTrainingRepository.swift \
  Sources/KlineTrainerContracts/Persistence/TrainingSetReader.swift
grep -n "totalCapital + .*profit\|func statistics\|func insertRecord\|func savePending\|func clearPending\|func loadPending" \
  Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift
# (6) PositionManager Codable（encode 点）+ AppError 案例
grep -n "Codable\|func encode\|case internalError\|case dbCorrupted" \
  Sources/KlineTrainerContracts/PositionManager.swift Sources/KlineTrainerContracts/AppError.swift
# (7) 时区先例（startYear/startMonth 派生口径）
grep -n "secondsFromGMT\|TimeZone" Sources/KlineTrainerContracts/Render/CrosshairLayout.swift
# (8) baseline 测试数（绿基线）
swift test 2>&1 | tail -3
```

期望（已实测 2026-06-07 worktree HEAD `22c88de`）：
- `saveProgress(engine:) async throws` / `finalize(engine:) async throws -> Int64?` / `endSession() async`（**非 throws**）三方法体 = `fatalError("Wave 2 E6 impl")`
- `activeEngine` / `activeReader` 为 `public private(set)`；E6a 私有 helper 已有 `startingCapital()`/`openReader(for:)`/`maxTick(from:)`/`cachedFile(filename:)`/`decodePosition(_:)`/`markers(from:)`
- `TrainingEngine`：`tick`/`position`/`cashBalance`/`drawdown`/`markers`/`drawings`/`upperPanel`/`lowerPanel`/`tradeOperations` 均 `public private(set)`；`flow`/`fees`/`initialCapital` 为 `public let`；`currentTotalCapital`/`returnRate`/`maxDrawdown` 为 `public var`（派生只读）
- `TrainingFlowController.shouldSaveRecord() -> Bool`（Normal true / Review false / Replay false）；`var mode`；`TrainingMode` = `.normal`/`.review`/`.replay`
- `TickEngine.globalTickIndex`（`public private(set)`）/ `maxTick`（`public let`）
- `PendingTraining` 12 字段 / `TrainingRecord` 15 字段 / `DrawdownAccumulator { peakCapital, maxDrawdown }` / `TrainingSetMeta { stockCode, stockName, startDatetime, endDatetime }` / `TradeOperation.direction: TradeDirection`（`.buy`/`.sell`）
- `RecordRepository.insertRecord(_:ops:drawings:) -> Int64` / `statistics()` 真实现 = `latest.totalCapital + latest.profit`（确证 D1 起始资金语义）；`PendingTrainingRepository.savePending/loadPending/clearPending`；`TrainingSetReader.loadMeta() -> TrainingSetMeta`
- `PositionManager: Codable`（合成 encode + 自定义 throwing decode）；`AppError.internalError(module:detail:)` / `.persistence(.dbCorrupted)`
- `CrosshairLayout.swift` 用 `TimeZone(secondsFromGMT: 8 * 3600)`（北京时 UTC+8 先例）
- baseline `swift test` = **674 tests / 108 suites 全绿**（新增后 = 674 + 本 PR 新测试数）

若 grep 实测与上不符，**subagent 以 grep 为准**修正，并在 PR body 标 `D-#`。

---

## 关键设计决策（D1–D11）

实现前固化以下决策。偏差/取舍均登记，供 plan-stage 与 branch-diff 对抗性 review 直接审。

| # | 决策 | 依据 |
|---|---|---|
| **D1** | **`finalize` 写 `TrainingRecord.totalCapital = engine.initialCapital`（本局起始资金）**，`profit = engine.currentTotalCapital - engine.initialCapital`，`returnRate = engine.returnRate`。**不**存 `currentTotalCapital`（结束总资金）。 | **user 裁决（2026-06-07）方案 A**。冻结 P4 `statistics()`（`latest.totalCapital + latest.profit` = 下一局起始资金）+ 刚 merge 的 E6a `review()`（`initialCapital=record.totalCapital`、`cashBalance=totalCapital+profit` 才使 `returnRate==record.returnRate` 自洽）都要求 `total_capital=起始`。DB 注释 L416「结束总资金」+ plan v1.5 历史列表示例 + U3「总资金」显示属 stale 侧 → **residual E6b-R1**（U1/U2 接线时 UI 改显 `total_capital+profit`、修 DB 注释/plan 文案；本 PR 不动 UI）。 |
| **D2** | **`finalize` 返回 `nil` 当 `engine.flow.shouldSaveRecord() == false`（Review/Replay）**：早返，**不**插记录、**不**动 pending。`true`（Normal）→ 构造 record + `insertRecord(record, ops:, drawings:)` + `clearPending()` + 返回 `id`。 | modules L1680「若 `flow.shouldSaveRecord() == false` 返回 nil」；ReviewFlow/ReplayFlow `shouldSaveRecord()==false`（E4 capability matrix） |
| **D3** | **`saveProgress` 仅 Normal 模式持久化**（`engine.flow.mode == .normal`）；Review/Replay → **no-op**（直接 return，不写 pending、不抛）。 | `PendingTraining`/`resumePending` 是「中断的 **Normal** 局」恢复机制（review 只读、replay 不入账，均无 pending 语义）；spec 无 review/replay 进度保存语义。登记 **residual E6b-R4** |
| **D4** | **追踪「当前 session 持久化上下文」**：新增 `@ObservationIgnored private var activeFile: TrainingSetFile?` + `@ObservationIgnored private var activeStartedAt: Int64?`，在 E6a 4 open 方法**成功分支**记录（`startNewNormalSession`：`activeFile=file`、`activeStartedAt=now()`；`resumePending`：`activeFile=file`、`activeStartedAt=pending.startedAt` **保留原起始时间**；`review`/`replay`：`activeFile=file`、`activeStartedAt=nil`）。 | `saveProgress`(`trainingSetFilename`) / `finalize`(`trainingSetFilename`+`loadMeta`) 需文件名，`TrainingEngine` 不携带 → 必须由 coordinator 追踪；`PendingTraining.startedAt` = 本局起始（resume 须保留，非每次保存重置）。E6a init 已 Wave 0 冻结，故新存储**不进 init**，默认值就地初始化 |
| **D5** | **可注入时钟**：`@ObservationIgnored var now: () -> Int64 = { Int64(Date().timeIntervalSince1970) }`（internal，默认系统时钟）。`finalize` 的 `createdAt = now()`、`startNewNormalSession` 的 `activeStartedAt = now()` 经此取值。 | public init 冻结不能加 clock 参数；internal `now` 让 `@testable` 测试覆盖以获确定性时间戳，避免对 `Date()` 断言 flaky |
| **D6** | **最大回撤额(元)→记录比率(负值)**：`finalize` 用静态纯函数 `drawdownRatio(absolute: engine.drawdown.maxDrawdown, peak: engine.drawdown.peakCapital)`，`peak<=0 → 0`，否则 `-(absolute / peak)`。 | `DrawdownAccumulator.maxDrawdown` 是**非负绝对额(元)**（modules L510），`TrainingRecord.max_drawdown` 是**负比率**（如 -0.12，plan v1.5 L419）。v1.3 改存绝对额且只留最终 peak，无法精确还原原 plan L744-747 逐时刻比率 → 以**最终 peakCapital** 为基准换算（标准定义 回撤额/峰值）。lossy 性登记 **residual E6b-R2** |
| **D7** | **起始年月 = `meta.startDatetime`(UTC 秒) 按北京时 UTC+8 取 年/月**：静态纯函数 `startYearMonth(from:)` 用 `Calendar(identifier:.gregorian)` + `TimeZone(secondsFromGMT: 8*3600)!`。 | 后端 `import_csv.py` 以 `utc=True` 存 epoch 秒；前端 `CrosshairLayout.swift:69` 显示 K 线时间用 `TimeZone(secondsFromGMT: 8*3600)`（北京时）。年/月须与显示口径一致 |
| **D8** | **`buyCount`/`sellCount` = `engine.tradeOperations` 按 `direction` 计数**（`.buy`/`.sell`）。局终自动强平产生的 `.sell` op（E5b `forceCloseIfEnded`）**计入** sellCount（它是真实成交流水）。`finalTick = engine.tick.globalTickIndex`、`feeSnapshot = engine.fees`。 | plan v1.5 L1000-1001 结算窗显示买/卖次数；强平是真实卖出（记 marker+op），归入卖出次数自然 |
| **D9** | **M0.4 边界**：唯一内部编码点 = `saveProgress` 的 `JSONEncoder().encode(position)` → 私有 helper `encodePosition(_:)` 内 catch 翻译为 `AppError.internalError(module:"E6b", detail:)`（in-memory 不变量保证 finite，encode 失败=内部 bug，非可恢复 .dbCorrupted）；与 E6a `decodePosition`（load 不可信 → .dbCorrupted）非对称是有意。public 方法体内**无** raw `.encode`/`.decode`。`finalize`/`saveProgress` 缺活跃上下文（`activeFile`/`activeReader`/`activeStartedAt` 为 nil）→ `throw AppError.internalError(module:"E6b", ...)`（caller 在无活跃 session 时调收尾 = 编程错误，但 public throwing 故 throw 不 trap）。`loadMeta`/`insertRecord`/`clearPending` 本就抛 `AppError`，直接传播。 | `docs/governance/m04-apperror-translation-gate.md`（Gate 2 raw-try / 显式 throw 用 AppError）；E6a D11 先例 |
| **D10** | **`endSession()` async 非 throws**：`activeReader?.close()` → `activeReader=nil`、`activeEngine=nil`、`activeFile=nil`、`activeStartedAt=nil`。never-started（全 nil）→ 安全 no-op。 | spec L1666/L1684「session 结束清理（关闭 reader）」不 throws；承接 E6a-R2（启动新 session 前既存 reader 清理归 endSession/caller） |
| **D11** | **静态纯 helper（`drawdownRatio`/`startYearMonth`）= `static`（internal，非 private）** 以便 `@testable` 直接单元测试 lossy 换算 + 时区边界；实例 helper（`encodePosition`）保持 `private`。**不**新建 `check_e6b_apperror_gate.sh`（同 E6a D11：E6 模块无专属 gate，以失败注入测试覆盖）。**不** touch cache（承接 E6a-R3，cache LRU touch 仍延后）。 | 纯函数直测比仅经 finalize 间接覆盖更能锁死换算/时区契约；surgical 不扩 gate |

**未决留 review 的点**（plan-stage 对抗性 review 重点审）：
- D3 saveProgress 仅 Normal 持久化：spec 未显式写 review/replay 是否保存进度，本 plan 据 PendingTraining=Normal-resume 语义推定 no-op。若 reviewer 认为应 throw（而非静默 no-op）以暴露误用，需 user 裁决。
- D6 lossy 换算：以最终 peakCapital 为基准，与原 plan 逐时刻比率在「峰值出现在最大绝对回撤之后」时数值不同。本 plan 据现冻结 `DrawdownAccumulator` 数据模型推定为唯一可实现口径。
- D9 缺活跃上下文 throw `.internalError` vs `precondition` trap：本 plan 选 throw（public throwing 方法，trap 体验更差）。

---

## File Structure

| File | 责任 | 改动 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` | E6 协调器：3 收尾方法真实现 + 上下文追踪存储 + 4 open 方法各加 1-2 行记录上下文 + 3 私有/静态 helper | Modify |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift` | E6b 行为 + 失败注入 + 纯函数单元 + save→resume round-trip 测试（新文件，不动 E6a 的 `TrainingSessionCoordinatorConstructionTests.swift` 与 Wave 0 `TrainingSessionCoordinatorTests.swift`） | Create |
| `docs/acceptance/2026-06-07-pr-e6b-session-persistence.md` | 非编码者验收清单（中文）+ M0.4 失败注入证据表 | Create |

**Prod LOC 估算**：3 方法 ~55 + 3 helper ~25 + 上下文存储/4 方法接线 ~14 + 注释 ~35 = **~129 行新增**（≤500 预算内）。
**测试新增**：Task 1-4 共 **19 tests / 1 suite**（Task1 endSession 3 + Task2 saveProgress 5 + Task3 helper 单元 6 + Task4 finalize 5）。

---

## Task 1: 上下文追踪存储 + endSession + 4 open 方法接线

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift`

- [ ] **Step 1.1: 写失败测试（test fixtures + endSession）**

Create `TrainingSessionPersistenceTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingSessionPersistence")
struct TrainingSessionPersistenceTests {

    // MARK: - 合法 candle fixture（连续 .m3 轴 0..n + m60/daily 非空，过 make 全校验）

    static func validCandles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int, close: Double) -> KLineCandle {
            KLineCandle(period: p, datetime: Int64(gi) * 180, open: 10, high: 11, low: 9,
                        close: close, volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: gi, endGlobalIndex: egi)
        }
        let m3 = (0..<m3Count).map { c(.m3, gi: $0, egi: $0, close: 10 + Double($0) * 0.1) }
        let last = m3Count - 1
        let m60 = [c(.m60, gi: 0, egi: last / 2, close: 10.3),
                   c(.m60, gi: last / 2 + 1, egi: last, close: 10.7)]
        let daily = [c(.daily, gi: 0, egi: last, close: 10.7)]
        return [.m3: m3, .m60: m60, .daily: daily]
    }

    struct CapitalDAO: SettingsDAO {
        let capital: Double
        func loadSettings() throws -> AppSettings {
            AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                        totalCapital: capital, displayMode: .system)
        }
        func saveSettings(_: AppSettings) throws {}
        func resetCapital() throws {}
    }

    static func cachedFile(id: Int = 1, filename: String = "set.sqlite") -> TrainingSetFile {
        TrainingSetFile(id: id, filename: filename,
                        localURL: URL(fileURLWithPath: "/tmp/\(filename)"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    /// 可配置 meta + 记录 close() 的 spy reader（finalize 需控制 loadMeta 返回值）。
    final class MetaSpyReader: TrainingSetReader, @unchecked Sendable {
        let candles: [Period: [KLineCandle]]
        let meta: TrainingSetMeta
        private(set) var closed = false
        init(candles: [Period: [KLineCandle]],
             meta: TrainingSetMeta = TrainingSetMeta(stockCode: "X", stockName: "X",
                                                     startDatetime: 1, endDatetime: 1)) {
            self.candles = candles; self.meta = meta
        }
        func loadMeta() throws -> TrainingSetMeta { meta }
        func loadAllCandles() throws -> [Period: [KLineCandle]] { candles }
        func close() { closed = true }
    }

    /// 注入指定 reader 的 factory（绕过 PreviewTrainingSetDBFactory 的 happy-path）。
    struct StubFactory: TrainingSetDBFactory {
        let reader: TrainingSetReader
        func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader { reader }
    }

    /// PreviewTrainingSetDBFactory + seed 缓存文件 + 指定起始本金 的 happy-path coordinator。
    static func makeCoordinator(
        candles: [Period: [KLineCandle]],
        capital: Double = 50_000,
        seedFile: TrainingSetFile? = cachedFile()
    ) -> (TrainingSessionCoordinator, InMemoryRecordRepository, InMemoryPendingTrainingRepository) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let cache = InMemoryCacheManager()
        if let f = seedFile { cache._seedForTesting([f]) }
        let coord = TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: candles),
            recordRepo: records,
            pendingRepo: pending,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: SettingsStore(settingsDAO: CapitalDAO(capital: capital)))
        return (coord, records, pending)
    }

    @Test("endSession: 关闭 reader + 清空 active 状态（D10）")
    func endSession_closesReaderClearsActive() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        _ = try await coord.startNewNormalSession()
        #expect(coord.activeReader != nil)
        #expect(coord.activeEngine != nil)
        await coord.endSession()
        #expect(coord.activeReader == nil)
        #expect(coord.activeEngine == nil)
    }

    @Test("endSession: never-started → 安全 no-op（不崩）")
    func endSession_neverStarted_noop() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        await coord.endSession()     // 全 nil，不崩
        #expect(coord.activeReader == nil)
        #expect(coord.activeEngine == nil)
    }

    @Test("endSession: 真关闭注入 reader（spy.closed == true）")
    func endSession_closesInjectedReader() async throws {
        let spy = Self.MetaSpyReader(candles: Self.validCandles())
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: InMemoryRecordRepository(),
            pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        _ = try await coord.startNewNormalSession()
        await coord.endSession()
        #expect(spy.closed == true)
    }
}
```

- [ ] **Step 1.2: 跑测试验证失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6b-session-persistence/ios/Contracts"
swift test --filter "TrainingSessionPersistence" 2>&1 | tail -15
```
Expected: FAIL —— `endSession` 的 `fatalError("Wave 2 E6 impl")` 触发。

- [ ] **Step 1.3: 加上下文存储 + 实现 endSession + 4 open 方法接线**

在 `TrainingSessionCoordinator.swift` 内 `activeReader` 声明**之后**加 3 个存储（紧接 `public private(set) var activeReader: ...` 行下方）：

```swift
    // MARK: - E6b 会话持久化上下文（saveProgress/finalize 需文件名+起始时间，engine 不携带）

    /// 当前 session 的训练组文件（4 open 方法成功时记录；endSession 清空）。
    @ObservationIgnored private var activeFile: TrainingSetFile?
    /// 当前 session 的起始时间（fresh Normal=now()；resume=保留 pending.startedAt；review/replay=nil）。
    @ObservationIgnored private var activeStartedAt: Int64?
    /// 可注入时钟（public init 已冻结，不能加参数）。默认系统时钟；@testable 测试可覆盖（D5）。
    @ObservationIgnored var now: () -> Int64 = { Int64(Date().timeIntervalSince1970) }
```

把 `endSession` 的 `fatalError` 体替换为：

```swift
    /// session 结束清理（spec L1666/L1684，不 throws）：关闭 reader 并清空全部活跃上下文（D10）。
    public func endSession() async {
        activeReader?.close()
        activeReader = nil
        activeEngine = nil
        activeFile = nil
        activeStartedAt = nil
    }
```

在 E6a 4 open 方法的**成功分支**记录上下文（D4）。各方法 `activeReader = reader` / `activeEngine = engine` 之后**紧接**加：

- `startNewNormalSession` 内 `activeEngine = engine` 之后加：
```swift
            activeFile = file
            activeStartedAt = now()                 // D4：fresh Normal 局起始时间
```
- `resumePending` 内 `activeEngine = engine` 之后加：
```swift
            activeFile = file
            activeStartedAt = pending.startedAt      // D4：resume 保留原局起始时间
```
- `review` 内 `activeEngine = engine` 之后加：
```swift
            activeFile = file
            activeStartedAt = nil                    // D4：review 只读，无进度保存
```
- `replay` 内 `activeEngine = engine` 之后加：
```swift
            activeFile = file
            activeStartedAt = nil                    // D4：replay 不入账，无进度保存
```

- [ ] **Step 1.4: 跑测试验证通过**

```bash
swift test --filter "TrainingSessionPersistence" 2>&1 | tail -8
```
Expected: 3/3 PASS, 0 warnings。

- [ ] **Step 1.5: 回归 E6a 测试（4 方法接线未破坏构造行为）**

```bash
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -5
```
Expected: E6a 17 测试仍全 PASS（新加的 activeFile/activeStartedAt 赋值不影响 E6a 断言）。

- [ ] **Step 1.6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift
git commit -m "feat(E6b): 会话上下文追踪 + endSession 真实现 + 4 open 方法接线（D4/D10）"
```

---

## Task 2: saveProgress 真实现（Normal 进度保存）

**Files:**
- Modify: `TrainingSessionCoordinator.swift`（替换 `saveProgress` 体 + 加 `encodePosition` helper）
- Modify: `TrainingSessionPersistenceTests.swift`

- [ ] **Step 2.1: 写失败测试**

在 suite 内追加：

```swift
    @Test("saveProgress: Normal 局 → 持久化 PendingTraining 全字段（含 startedAt=now()、accumulated=起始资金）")
    func saveProgress_normal_persistsAllFields() async throws {
        let (coord, _, pending) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        coord.now = { 111 }                                  // 控制 startedAt
        let engine = try await coord.startNewNormalSession()  // fresh：tick 0、空仓、cash 50000
        try await coord.saveProgress(engine: engine)
        let p = try #require(try pending.loadPending())
        #expect(p.trainingSetFilename == "set.sqlite")        // D4：activeFile.filename
        #expect(p.globalTickIndex == 0)
        #expect(p.upperPeriod == .m60)
        #expect(p.lowerPeriod == .daily)
        #expect(p.cashBalance == 50_000)
        #expect(p.accumulatedCapital == 50_000)               // D4：engine.initialCapital
        #expect(p.startedAt == 111)                            // D4/D5：fresh=now() at start
        #expect(p.tradeOperations.isEmpty)
        #expect(p.drawings.isEmpty)
        // positionData 可解回空仓（D9 encode 往返）
        let pos = try JSONDecoder().decode(PositionManager.self, from: p.positionData)
        #expect(pos.shares == 0)
    }

    @Test("saveProgress: review 模式 → no-op（不写 pending，D3）")
    func saveProgress_review_noop() async throws {
        let (coord, records, pending) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let engine = try await coord.review(recordId: id)
        try await coord.saveProgress(engine: engine)
        #expect(try pending.loadPending() == nil)             // review 不持久化
    }

    @Test("saveProgress: replay 模式 → no-op（不写 pending，D3）")
    func saveProgress_replay_noop() async throws {
        let (coord, records, pending) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 80_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let engine = try await coord.replay(recordId: id)
        try await coord.saveProgress(engine: engine)
        #expect(try pending.loadPending() == nil)
    }

    @Test("saveProgress: 缺活跃上下文（endSession 后）→ .internalError（D9）")
    func saveProgress_noActiveContext_throws() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.startNewNormalSession()
        await coord.endSession()                               // 清空 activeFile/activeStartedAt
        await #expect(throws: AppError.internalError(module: "E6b",
                      detail: "saveProgress without active session context")) {
            try await coord.saveProgress(engine: engine)
        }
    }

    @Test("saveProgress → resumePending round-trip：状态还原一致（D4 跨方法集成）")
    func saveProgress_thenResume_roundTrips() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        coord.now = { 222 }
        let engine = try await coord.startNewNormalSession()
        try await coord.saveProgress(engine: engine)
        await coord.endSession()
        let resumed = try #require(try await coord.resumePending())
        #expect(resumed.tick.globalTickIndex == 0)
        #expect(resumed.cashBalance == 50_000)
        #expect(resumed.initialCapital == 50_000)
        #expect(resumed.position.shares == 0)
        #expect(resumed.upperPanel.period == .m60)
        #expect(resumed.lowerPanel.period == .daily)
    }
```

- [ ] **Step 2.2: 跑测试验证失败**

```bash
swift test --filter "TrainingSessionPersistence" 2>&1 | tail -15
```
Expected: saveProgress 系列 FAIL（`fatalError("Wave 2 E6 impl")`）。

- [ ] **Step 2.3: 实现 saveProgress + encodePosition helper**

把 `saveProgress` 的 `fatalError` 体替换为：

```swift
    /// 保存进度（spec L1659/L1677：U2 退出 / 每 N tick 自动调用）。仅 Normal 模式持久化
    /// （review 只读、replay 不入账 → 无 pending 语义，D3 no-op）。缺活跃上下文 → .internalError（D9）。
    public func saveProgress(engine: TrainingEngine) async throws {
        guard engine.flow.mode == .normal else { return }     // D3：仅 Normal 持久化
        guard let file = activeFile, let started = activeStartedAt else {
            throw AppError.internalError(module: "E6b", detail: "saveProgress without active session context")
        }
        let pending = PendingTraining(
            trainingSetFilename: file.filename,
            globalTickIndex: engine.tick.globalTickIndex,
            upperPeriod: engine.upperPanel.period,
            lowerPeriod: engine.lowerPanel.period,
            positionData: try encodePosition(engine.position),
            cashBalance: engine.cashBalance,
            feeSnapshot: engine.fees,
            tradeOperations: engine.tradeOperations,
            drawings: engine.drawings,
            startedAt: started,
            accumulatedCapital: engine.initialCapital,         // D4：本局起始资金
            drawdown: engine.drawdown)
        try pendingRepo.savePending(pending)
    }
```

在 E6a `decodePosition` helper **旁边**（私有 helper 段内）加 `encodePosition`：

```swift
    /// D9 M0.4 边界：PositionManager 序列化（saveProgress 唯一编码点）。in-memory 不变量保证 finite，
    /// encode 失败 = 内部 bug（非可恢复存档损坏）→ .internalError（与 decodePosition 的 .dbCorrupted 非对称有意）。
    private func encodePosition(_ position: PositionManager) throws -> Data {
        do {
            return try JSONEncoder().encode(position)
        } catch {
            throw AppError.internalError(module: "E6b", detail: "position encode failed: \(error)")
        }
    }
```

- [ ] **Step 2.4: 跑测试验证通过**

```bash
swift test --filter "TrainingSessionPersistence" 2>&1 | tail -8
```
Expected: saveProgress 5 测试 PASS（累计 8/8），0 warnings。

- [ ] **Step 2.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift
git commit -m "feat(E6b): saveProgress 真实现（Normal 持久化 + encodePosition D3/D9）"
```

---

## Task 3: finalize 静态纯 helper（drawdownRatio + startYearMonth）

**Files:**
- Modify: `TrainingSessionCoordinator.swift`（加 2 个 `static` helper）
- Modify: `TrainingSessionPersistenceTests.swift`

- [ ] **Step 3.1: 写失败测试（纯函数单元，直测 lossy 换算 + 时区边界）**

在 suite 内追加：

```swift
    // MARK: - 纯函数单元（D6/D7/D11）

    @Test("drawdownRatio: peak<=0 → 0（无有效峰值）")
    func drawdownRatio_zeroPeak_returnsZero() {
        #expect(TrainingSessionCoordinator.drawdownRatio(absolute: 0, peak: 0) == 0)
        #expect(TrainingSessionCoordinator.drawdownRatio(absolute: 100, peak: 0) == 0)
        #expect(TrainingSessionCoordinator.drawdownRatio(absolute: 0, peak: -5) == 0)
    }

    @Test("drawdownRatio: 绝对额(元)→负比率 = -(abs/peak)")
    func drawdownRatio_normal_negativeRatio() {
        #expect(abs(TrainingSessionCoordinator.drawdownRatio(absolute: 8930, peak: 100_000) - (-0.0893)) < 1e-12)
        #expect(abs(TrainingSessionCoordinator.drawdownRatio(absolute: 12_000, peak: 100_000) - (-0.12)) < 1e-12)
    }

    @Test("drawdownRatio: 零回撤 → 0（无亏损）")
    func drawdownRatio_zeroDrawdown_returnsZero() {
        #expect(TrainingSessionCoordinator.drawdownRatio(absolute: 0, peak: 100_000) == 0)
    }

    @Test("startYearMonth: 普通时刻按 UTC+8 取年/月")
    func startYearMonth_normal() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let epoch = Int64(cal.date(from: DateComponents(year: 2021, month: 8, day: 15, hour: 12))!
                            .timeIntervalSince1970)
        let (y, m) = TrainingSessionCoordinator.startYearMonth(from: epoch)
        #expect(y == 2021)
        #expect(m == 8)
    }

    @Test("startYearMonth: 用 UTC+8 而非 UTC（跨月边界 killer）")
    func startYearMonth_usesBeijingTZ_notUTC() {
        // 2021-08-01 02:00 北京时 == 2021-07-31 18:00 UTC：UTC+8→8月，误用 UTC→7月。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let epoch = Int64(cal.date(from: DateComponents(year: 2021, month: 8, day: 1, hour: 2))!
                            .timeIntervalSince1970)
        let (y, m) = TrainingSessionCoordinator.startYearMonth(from: epoch)
        #expect(y == 2021)
        #expect(m == 8)               // 误用 UTC 会得 7 → 测试失败
    }

    @Test("startYearMonth: 年初边界（跨年）按 UTC+8")
    func startYearMonth_yearBoundary() {
        // 2022-01-01 01:00 北京时 == 2021-12-31 17:00 UTC：UTC+8→2022/1，误用 UTC→2021/12。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let epoch = Int64(cal.date(from: DateComponents(year: 2022, month: 1, day: 1, hour: 1))!
                            .timeIntervalSince1970)
        let (y, m) = TrainingSessionCoordinator.startYearMonth(from: epoch)
        #expect(y == 2022)
        #expect(m == 1)
    }
```

- [ ] **Step 3.2: 跑测试验证失败**

```bash
swift test --filter "TrainingSessionPersistence" 2>&1 | tail -15
```
Expected: helper 系列 FAIL（编译错误：`drawdownRatio`/`startYearMonth` 未定义）。

- [ ] **Step 3.3: 实现 2 个 static helper**

在 `TrainingSessionCoordinator.swift` 私有 helper 段内加（**`static`（internal）非 private**，D11 便于直测）：

```swift
    /// D6：最大回撤额(元，非负) → 记录用比率(负值，如 -0.12)。peak<=0 → 0。
    /// 注：v1.3 `DrawdownAccumulator` 改存绝对额并只留最终 peak，无法精确还原原 plan v1.5 L744-747
    /// 的逐时刻比率；以**最终 peakCapital** 为基准换算（标准定义 回撤额/峰值）。lossy 性见 residual E6b-R2。
    static func drawdownRatio(absolute: Double, peak: Double) -> Double {
        guard peak > 0 else { return 0 }
        return -(absolute / peak)
    }

    /// D7：训练组起始 Unix 秒(UTC) → 年/月，按北京时 UTC+8（与 CrosshairLayout 显示口径一致；后端 UTC 存储）。
    /// 28800 在 TimeZone 合法范围（±64800）→ 强解包永不 nil。
    static func startYearMonth(from startDatetime: Int64) -> (year: Int, month: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let comps = cal.dateComponents([.year, .month],
                                       from: Date(timeIntervalSince1970: TimeInterval(startDatetime)))
        return (comps.year ?? 0, comps.month ?? 0)
    }
```

- [ ] **Step 3.4: 跑测试验证通过**

```bash
swift test --filter "TrainingSessionPersistence" 2>&1 | tail -8
```
Expected: helper 6 测试 PASS（累计 14/14），0 warnings。

- [ ] **Step 3.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift
git commit -m "feat(E6b): finalize 静态 helper drawdownRatio + startYearMonth（D6/D7/D11）"
```

---

## Task 4: finalize 真实现（正式结束入账）

**Files:**
- Modify: `TrainingSessionCoordinator.swift`（替换 `finalize` 体）
- Modify: `TrainingSessionPersistenceTests.swift`

- [ ] **Step 4.1: 写失败测试**

在 suite 内追加。第一个测试经 `resumePending` 构造**确定性、profit≠0** 的引擎，全面校验 record 映射（含方案 A 的「起始≠结束」killer）：

```swift
    /// 构造一个确定性 pending：resume 后 tick=7、price=10.7、cash=90000、shares=100、accumulated=100000，
    /// → currentTotal=91070、profit=-8930、drawdown abs=8930/peak=100000。
    static func deterministicPending() throws -> PendingTraining {
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        return PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 7,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: true),
            tradeOperations: [
                TradeOperation(globalTick: 2, period: .m3, direction: .buy, price: 10.2, shares: 100,
                               positionTier: .tier1, commission: 1, stampDuty: 0, totalCost: 1020, createdAt: 0),
                TradeOperation(globalTick: 5, period: .m3, direction: .sell, price: 10.5, shares: 100,
                               positionTier: .tier1, commission: 1, stampDuty: 1, totalCost: 1048, createdAt: 0)
            ],
            drawings: [], startedAt: 1,
            accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 5_000))
    }

    /// resume 路径 coordinator（StubFactory + MetaSpyReader 控制 meta；pending 注入）。
    static func resumeCoordinator(
        meta: TrainingSetMeta
    ) throws -> (TrainingSessionCoordinator, InMemoryRecordRepository, InMemoryPendingTrainingRepository, MetaSpyReader) {
        let spy = MetaSpyReader(candles: validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        try pending.savePending(try deterministicPending())
        let coord = TrainingSessionCoordinator(
            dbFactory: StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: CapitalDAO(capital: 10_000)))
        return (coord, records, pending, spy)
    }

    @Test("finalize: Normal 入账 record 全字段（total=起始≠结束 killer / profit / 回撤比率 / 买卖次数 / 年月 / 清 pending）")
    func finalize_normal_insertsRecordCorrectly() async throws {
        // startDatetime = 2021-08-15 12:00 北京时
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let startEpoch = Int64(cal.date(from: DateComponents(year: 2021, month: 8, day: 15, hour: 12))!
                                .timeIntervalSince1970)
        let meta = TrainingSetMeta(stockCode: "600519", stockName: "贵州茅台",
                                   startDatetime: startEpoch, endDatetime: startEpoch + 1)
        let (coord, records, pending, _) = try Self.resumeCoordinator(meta: meta)
        coord.now = { 1_700_000_000 }
        let engine = try #require(try await coord.resumePending())   // tick 7, shares 100
        let id = try #require(try await coord.finalize(engine: engine))

        let (rec, ops, _) = try records.loadRecordBundle(id: id)
        #expect(rec.totalCapital == 100_000)                          // D1 方案 A：起始资金
        #expect(rec.totalCapital != 91_070)                           // killer：非结束总资金
        #expect(abs(rec.profit - (-8_930)) < 1e-6)                    // 91070 - 100000（容差，FP）
        #expect(abs(rec.returnRate - (-0.0893)) < 1e-9)              // profit/起始
        #expect(abs(rec.maxDrawdown - (-0.0893)) < 1e-9)            // -(8930/100000)，D6
        #expect(rec.buyCount == 1)                                    // D8
        #expect(rec.sellCount == 1)
        #expect(rec.stockCode == "600519")
        #expect(rec.stockName == "贵州茅台")
        #expect(rec.startYear == 2021)                                // D7 UTC+8
        #expect(rec.startMonth == 8)
        #expect(rec.createdAt == 1_700_000_000)                       // D5 now()
        #expect(rec.finalTick == 7)
        #expect(rec.trainingSetFilename == "set.sqlite")
        #expect(rec.feeSnapshot.commissionRate == 0.0002)
        #expect(ops.count == 2)                                       // ops 一并入账
        #expect(try pending.loadPending() == nil)                    // D2：清 pending
    }

    @Test("finalize: review 模式 → nil（不插记录、不动 pending，D2）")
    func finalize_review_returnsNil() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let countBefore = try records.listRecords(limit: nil).count
        let engine = try await coord.review(recordId: id)
        let result = try await coord.finalize(engine: engine)
        #expect(result == nil)
        #expect(try records.listRecords(limit: nil).count == countBefore)   // 未新增记录
    }

    @Test("finalize: replay 模式 → nil（不入账，D2）")
    func finalize_replay_returnsNil() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: 80_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let countBefore = try records.listRecords(limit: nil).count
        let engine = try await coord.replay(recordId: id)
        let result = try await coord.finalize(engine: engine)
        #expect(result == nil)
        #expect(try records.listRecords(limit: nil).count == countBefore)
    }

    @Test("finalize: Normal 但缺活跃上下文（endSession 后）→ .internalError（D9）")
    func finalize_noActiveContext_throws() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.startNewNormalSession()
        await coord.endSession()
        await #expect(throws: AppError.internalError(module: "E6b",
                      detail: "finalize without active session context")) {
            _ = try await coord.finalize(engine: engine)
        }
    }

    @Test("finalize: 局终自动强平产生的 sell 计入 sellCount（D8 覆盖）")
    func finalize_forceCloseSell_countedInSellCount() async throws {
        // resume 在 tick 3 持仓 100；holdOrObserve(.upper) 走 m60 步进 3→7（maxTick）→ 触发局终强平卖出。
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        let spy = Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let pos = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000)
        try pending.savePending(PendingTraining(
            trainingSetFilename: "set.sqlite", globalTickIndex: 3,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: try JSONEncoder().encode(pos), cashBalance: 90_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: [], drawings: [], startedAt: 1,
            accumulatedCapital: 100_000, drawdown: .initial))
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: pending,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000)))
        let engine = try #require(try await coord.resumePending())
        #expect(engine.tick.globalTickIndex == 3)
        engine.holdOrObserve(panel: .upper)              // 3 → 7（m60 步进）→ 局终强平 100 股
        #expect(engine.tick.globalTickIndex == 7)
        #expect(engine.position.shares == 0)             // 强平后空仓
        let id = try #require(try await coord.finalize(engine: engine))
        let (rec, _, _) = try records.loadRecordBundle(id: id)
        #expect(rec.sellCount == 1)                       // 仅强平 1 笔 sell（pending ops 为空，D8）
        #expect(rec.buyCount == 0)
        #expect(rec.finalTick == 7)
    }
```

- [ ] **Step 4.2: 跑测试验证失败**

```bash
swift test --filter "TrainingSessionPersistence" 2>&1 | tail -15
```
Expected: finalize 系列 FAIL（`fatalError("Wave 2 E6 impl")`）。

- [ ] **Step 4.3: 实现 finalize**

把 `finalize` 的 `fatalError` 体替换为：

```swift
    /// 正式结束（spec L1663/L1679）：构造 TrainingRecord + ops + drawings 入账，清 pending，返回 recordId。
    /// `flow.shouldSaveRecord()==false`（Review/Replay）→ 早返 nil，不插记录、不动 pending（D2）。
    /// total_capital = 本局**起始**资金（方案 A / D1）；maxDrawdown 元→负比率（D6）；起始年月按 UTC+8（D7）。
    /// 缺活跃上下文 → .internalError（D9）。
    public func finalize(engine: TrainingEngine) async throws -> Int64? {
        guard engine.flow.shouldSaveRecord() else { return nil }   // D2：Review/Replay 不入账
        guard let file = activeFile, let reader = activeReader else {
            throw AppError.internalError(module: "E6b", detail: "finalize without active session context")
        }
        let meta = try reader.loadMeta()
        let starting = engine.initialCapital                       // D1：起始资金
        let profit = engine.currentTotalCapital - starting
        let (year, month) = Self.startYearMonth(from: meta.startDatetime)
        let record = TrainingRecord(
            id: nil,
            trainingSetFilename: file.filename,
            createdAt: now(),                                      // D5
            stockCode: meta.stockCode,
            stockName: meta.stockName,
            startYear: year,
            startMonth: month,
            totalCapital: starting,                               // D1：本局起始资金
            profit: profit,
            returnRate: engine.returnRate,
            maxDrawdown: Self.drawdownRatio(absolute: engine.drawdown.maxDrawdown,
                                            peak: engine.drawdown.peakCapital),   // D6
            buyCount: engine.tradeOperations.filter { $0.direction == .buy }.count,    // D8
            sellCount: engine.tradeOperations.filter { $0.direction == .sell }.count,
            feeSnapshot: engine.fees,
            finalTick: engine.tick.globalTickIndex)
        let id = try recordRepo.insertRecord(record, ops: engine.tradeOperations, drawings: engine.drawings)
        try pendingRepo.clearPending()
        return id
    }
```

- [ ] **Step 4.4: 跑测试验证通过**

```bash
swift test --filter "TrainingSessionPersistence" 2>&1 | tail -8
```
Expected: finalize 5 测试 PASS（累计 19/19），0 warnings。

- [ ] **Step 4.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift
git commit -m "feat(E6b): finalize 真实现（起始资金入账 D1 + 回撤比率 D6 + 清 pending D2）"
```

---

## Task 5: 整体 verification + iOS gate + M0.4 自检 + acceptance doc + PR

- [ ] **Step 5.1: 全量 swift test**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6b-session-persistence/ios/Contracts"
swift test 2>&1 | tail -6
```
Expected: baseline 674 + 19 新测试 = **693 tests** 全 PASS，0 failures。

- [ ] **Step 5.2: 0 warnings 复核（Sendable / unused / strict concurrency / async-no-await）**

```bash
swift build 2>&1 | grep -i "warning" | head -10
swift test 2>&1 | grep -i "warning" | head -10
```
Expected: 空输出。`endSession`/`saveProgress`/`finalize` 为契约冻结的 `async`，即便无 await 也保留（不删 async）。

- [ ] **Step 5.3: iOS Simulator SDK typecheck gate**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6b-session-persistence"
swiftc -typecheck \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios17.0-simulator \
  $(find ios/Contracts/Sources/KlineTrainerContracts -name "*.swift")
```
Expected: exit 0（`@Observable`/`@ObservationIgnored`/`@MainActor`/Sendable 在 iOS 17 SDK 解析全过）。

- [ ] **Step 5.4: M0.4 静态自检（D9，手工 grep——E6 无专属 gate 脚本）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6b-session-persistence/ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine"
# 每条真 throw 必须含 AppError（锚定行首 throw，避免误匹配注释）
grep -nE "^[[:space:]]*throw " TrainingSessionCoordinator.swift | grep -v "AppError" \
  && echo "FAIL: 存在不含 AppError 的 throw" || echo "PASS: 全部 throw 用 AppError"
# public 方法体内不得有 raw .encode/.decode（须在 private helper）
grep -nE "JSONEncoder|JSONDecoder|\.encode\(|\.decode\(" TrainingSessionCoordinator.swift
# 期望：.encode 仅 encodePosition、.decode 仅 decodePosition（均 private helper）
```
Expected: 第一条 `PASS`；第二条仅命中 `encodePosition`（`JSONEncoder().encode`）+ `decodePosition`（`JSONDecoder().decode`）两 private helper。

- [ ] **Step 5.5: 主线 verification-before-completion**

主线（非 subagent）跑 superpowers:verification-before-completion，贴：
- `swift test` 完整尾部（确切计数 693）
- iOS gate exit code
- `git diff main --stat`（文件 + LOC）
- M0.4 自检输出
- 「未交付 / residual」清单：
  - **E6b-R1**（D1 方案 A 后续）：U3 `SettlementContent` + 历史列表（U1）「总资金」当前直显 `total_capital`=起始值，须在 U1/U2 接线（顺位 8/9）改显 `total_capital + profit`（结束值）；并修 stale DB 注释 `plan v1.5 L416` + 历史列表示例 + §6.3 文案
  - **E6b-R2**（D6 lossy）：maxDrawdown 比率以最终 peakCapital 为基准，与原 plan 逐时刻比率在「峰值后置」时有差；如需精确逐时刻比率须扩 `DrawdownAccumulator`（spec 变更）
  - **E6b-R3**（承接 E6a-R3）：cache touch-on-use LRU 仍延后（顺位 11 评估）
  - **E6b-R4**（D3）：saveProgress 对 review/replay 静默 no-op（非 throw）

- [ ] **Step 5.6: 写非编码者验收清单 + M0.4 证据表**

Create `docs/acceptance/2026-06-07-pr-e6b-session-persistence.md`：中文，每条 action / expected / pass-fail（禁忌词见 `.claude/workflow-rules.json`）。至少覆盖：Normal 局保存进度后可继续恢复（save→resume 一致）；Normal 局正式结束生成历史记录（起始资金/盈亏/收益率/回撤/买卖次数/起始年月正确）；复盘/再来一次结束**不**生成记录；session 结束释放训练组文件。附 M0.4 public throwing 方法 → 失败注入测试映射表（saveProgress/finalize × 缺活跃上下文 → 对应 `@Test` 名）。**encode 失败路径**列为「防御性/不可达（PositionManager 不变量保证 finite，无对应 `@Test`）」——不要谎称有测试（plan-review L1）。

- [ ] **Step 5.7: 主线 push + open PR（worktree → user TTY）**

per `feedback_worktree_local_ledger_user_tty_pr`：worktree 开发的分支 attest 写 worktree-local ledger；主仓 `gh pr create`/`merge` 被 guard 拦 → **user 真终端**执行。先 Read 主仓 attest-ledger.json 核对 + 建本地跟踪分支防 "cannot resolve head"。PR body（中文）列：3 方法落地 + D1-D11 决策 + 4 residual + 测试计数（692）+ iOS gate + Catalyst CI 状态 + user 方案 A 裁决引用。

---

## Self-Review

**1. Spec coverage：**
- spec §E6 L1677 `saveProgress`（U2 退出/每 N tick 保存进度）✅ Task 2（D3 仅 Normal + D4 上下文 + D9 encode）
- spec §E6 L1679-1681 `finalize`（构造 TrainingRecord+ops+drawings 插入、清 pending、返 recordId、shouldSaveRecord==false 返 nil）✅ Task 4（D1/D2/D6/D7/D8）
- spec §E6 L1684 `endSession`（关闭 reader，不 throws）✅ Task 1（D10）
- modules §M0.3 `PendingTraining` 12 字段映射 ✅ Task 2（每字段显式赋值 + round-trip 验证）
- modules §M0.3 `TrainingRecord` 15 字段映射 ✅ Task 4（每字段断言）
- plan v1.5 L417-419 records DDL 语义（profit/return_rate/max_drawdown 比率）✅ D1/D6
- plan v1.5 L860 累计资金模型（statistics = total_capital + profit）✅ D1（user 方案 A 与冻结 statistics 一致）
- plan v1.5 L1000-1001 买卖次数 ✅ D8
- M0.4 边界（encode 翻译 + throw 用 AppError + public 体禁 raw encode/decode）✅ D9 + Task 5.4

**2. Placeholder scan：** 无 TBD/TODO。E6b 替换后 `TrainingSessionCoordinator` 内**不再有** `fatalError`（3 个收尾方法全实现）。所有 Task 步骤含完整代码/命令/期望。

**3. Type consistency：**
- `now: () -> Int64`：Task 1 定义，Task 2（startedAt）/ Task 4（createdAt）使用，签名一致 ✅
- `activeFile: TrainingSetFile?` / `activeStartedAt: Int64?`：Task 1 定义，Task 1（4 方法写）/ Task 2（saveProgress 读）/ Task 4（finalize 读）/ endSession（清）一致 ✅
- `drawdownRatio(absolute:peak:)` / `startYearMonth(from:)`：Task 3 定义（static），Task 4 finalize 调用 + Task 3 单元测试，签名一致 ✅
- `encodePosition(_:) throws -> Data`：Task 2 定义（private），仅 saveProgress 调用 ✅
- `PendingTraining`(12) / `TrainingRecord`(15) / `DrawdownAccumulator`(peakCapital/maxDrawdown) / `TrainingSetMeta`(stockCode/stockName/startDatetime/endDatetime) / `TradeOperation.direction` / `FeeSnapshot` 字段名 = AppState.swift/Models.swift 实测（Task 0 pre-flight 校验）✅
- 测试 mock（`MetaSpyReader`/`StubFactory`/`CapitalDAO`）conform 协议方法签名 = dep protocol 实测 ✅
- engine 只读 accessor（`tick.globalTickIndex`/`upperPanel.period`/`cashBalance`/`fees`/`initialCapital`/`currentTotalCapital`/`returnRate`/`drawdown`/`tradeOperations`/`drawings`/`flow.mode`/`flow.shouldSaveRecord()`）= TrainingEngine.swift 实测 ✅

**4. 关键风险复核：**
- 方案 A 起始资金语义：`finalize` total_capital=`initialCapital`、`statistics` 累计 = total_capital+profit = 结束总资金 → 下一局起始正确（Task 4 killer 断言 total != 91070 ending）✅
- D4 上下文 fail-closed：activeFile/activeStartedAt 仅在 4 open 方法**成功分支**写、endSession 清；缺上下文 finalize/saveProgress throw（Task 2/4 endSession 后断言 .internalError）✅
- D3 saveProgress 仅 Normal：review/replay no-op（Task 2 loadPending==nil 断言）✅
- D6 lossy 换算 + D7 时区：纯函数直测（Task 3 含 UTC+8 vs UTC 跨月/跨年 killer）✅
- 浮点断言用容差（profit/returnRate/maxDrawdown），遵 `feedback_swift_local_toolchain_blindspot`（非整除 FP host 测试必须容差）✅
- E6a 回归：4 open 方法仅**追加**上下文赋值，不改原构造逻辑（Task 1.5 跑 E6a 17 测试回归）✅
