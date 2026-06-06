# E6a TrainingSessionCoordinator 会话构造 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本项目只用 subagent-driven-development（不用 executing-plans）。每个 Task 派一个 fresh sonnet 4.6 high-effort subagent；Task 之间主线两阶段 review。

**Goal:** 把 Wave 0 壳 `TrainingSessionCoordinator` 的 4 个**会话构造**方法（`startNewNormalSession` / `resumePending` / `review` / `replay`）从 `fatalError` 替换为真实现，全部经 E5 `TrainingEngine.make(_:…)` 唯一 public 构造路径装配运行时引擎，并对 Normal 交易流强制 **fail-closed 费用快照**（`settings.snapshotFeesIfReady()`，禁 fail-open）。

**Architecture:** 在现有 `TrainingSessionCoordinator.swift`（`@MainActor @Observable final class`，6 依赖 DI init 已 Wave 0 冻结）内**只替换 4 个方法体 + 新增私有 helper**，不改 init / 存储属性 / 另 3 个生命周期方法（`saveProgress`/`finalize`/`endSession` 留给顺位 5 E6b）。每个方法走统一编排：取数据源（cache.pickRandom / pending / record bundle）→ `dbFactory.openAndVerify` 打开 reader → `reader.loadAllCandles()` → 经 `TrainingEngine.make` 构造引擎 → 成功才写 `activeEngine`/`activeReader`，失败关闭已开 reader 且不留半态。

**Tech Stack:** Swift 6（toolchain，strict concurrency on）+ SwiftPM（`KlineTrainerContracts` package，root `ios/Contracts/`）+ Swift Testing（`@Test`/`@Suite`/`#expect`）+ `@MainActor` + `@Observable`。依赖：E5 `TrainingEngine.make`/`FlowInput`（顺位 2/3）、E4 `NormalFlow`/`ReviewFlow`/`ReplayFlow`（PR #63）、E2 `PositionManager` throwing decoder（PR #65）、6 依赖 protocol（Wave 0）、M0.4 `AppError`。

**Design Doc / 上游契约:**
- `docs/superpowers/specs/2026-06-02-wave2-outline-design.md` 顺位 4（E6a scope + fail-closed 费用快照 residual）
- `docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md` §三#6（fee-callsite fail-closed）
- `kline_trainer_modules_v1.4.md` §E6（L1641-1685 契约）+ L2045（费用打包 fail-closed）
- `kline_trainer_plan_v1.5.md` §5.0 Capability Matrix（Review/Replay 行为）+ L893-894/L1213-1214/L1252-1253（复盘/再来一次语义）

---

## Pre-flight Gate (Step 0 — subagent 必须在 Task 1 前跑)

避免 spec drift：subagent 写代码前 grep baseline 真签名，按实测对齐 plan。**§〇 教训（`feedback_explore_agent_stale_spec_trust`）：以实际代码为准，不信 spec checklist。**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6a-session-coordinator/ios/Contracts"
# (1) make / FlowInput 真签名（构造路径）
grep -n "public static func make\|public enum FlowInput\|case normal\|case review\|case replay" \
  Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift
# (2) 4 方法当前 fatalError 体 + init 6 参数 + active state 字段
grep -n "func startNewNormalSession\|func resumePending\|func review\|func replay\|activeEngine\|activeReader" \
  Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift
# (3) 依赖协议方法签名
grep -n "func " Sources/KlineTrainerContracts/Persistence/TrainingSetReader.swift \
  Sources/KlineTrainerContracts/Persistence/RecordRepository.swift \
  Sources/KlineTrainerContracts/Persistence/PendingTrainingRepository.swift \
  Sources/KlineTrainerContracts/Persistence/CacheManager.swift \
  Sources/KlineTrainerContracts/Persistence/TrainingSetDBFactory.swift
# (4) PositionManager throwing decoder + TradeMarker init + SettingsStore.snapshotFeesIfReady/loadError
grep -n "init(from decoder\|public init" Sources/KlineTrainerContracts/PositionManager.swift
grep -n "struct TradeMarker\|public init" Sources/KlineTrainerContracts/Models/Models.swift
grep -n "snapshotFeesIfReady\|var loadError" Sources/KlineTrainerContracts/Settings/SettingsStore.swift
# (5) 测试 fake 真状态能力（PR #45 升级后）
grep -n "public init\|func loadAllCandles\|func loadMeta" \
  Sources/KlineTrainerContracts/PreviewFakes/PreviewTrainingSetReader.swift
# (6) baseline 测试数（绿基线）
swift test 2>&1 | tail -3
```

期望（已实测 2026-06-07 worktree HEAD `ea23fbd`）：
- `make(_ input: FlowInput, allCandles:, initialTick:, initialCapital:, initialCashBalance:, initialPosition:, initialMarkers:, initialDrawings:, initialTradeOperations:, initialDrawdown:, initialUpperPeriod:, initialLowerPeriod:) throws -> TrainingEngine`
- `FlowInput` = `.normal(fees:maxTick:)` / `.review(record:)` / `.replay(fees:maxTick:)`
- 4 方法体当前 = `fatalError("Wave 2 E6 impl")`；init 6 参数；`activeEngine`/`activeReader` 为 `public private(set)`
- `PositionManager.init(from:) throws`（损坏存档抛 `DecodingError`）；`TradeMarker(globalTick:price:direction:)`
- `SettingsStore.snapshotFeesIfReady() throws -> FeeSnapshot`（loadError 时 throws）；`loadError: AppError?`
- baseline `swift test` 全绿（记录确切数字作 baseline，新增后 = baseline + 本 PR 新测试数）

若 grep 实测与上不符，**subagent 以 grep 为准**修正 stub，并在 PR body 标 `D-#`。

---

## 关键设计决策（D1–D12）

实现前固化以下决策。偏差/取舍均登记，供 plan-stage 与 branch-diff 对抗性 review 直接审。

| # | 决策 | 依据 |
|---|---|---|
| **D1** | 4 方法**全部经 `TrainingEngine.make(_:…)`**（throwing，校验数据派生不变量抛可恢复 `AppError`），**不**直调 internal `init` | E5a `make` 注释 L133-138：`make` 是唯一 public 构造路径；`init` 已退为 internal trust-boundary |
| **D2** | **fail-closed 费用快照仅 Normal 路径**：`startNewNormalSession` 用 `try settings.snapshotFeesIfReady()`（loadError → throw，**早于** pickRandom/openReader，零副作用）。`resumePending` 用 `pending.feeSnapshot`、`review`/`replay` 用 `record.feeSnapshot`（经 ReviewFlow/ReplayFlow）——**均不读当前 settings 费用**，故不调 snapshotFeesIfReady | outline 顺位 4 residual + RFC §三#6；resume/review/replay 继承原局 fees（非新交易流） |
| **D3** | `maxTick` 推导：Normal/resume/replay 用 `allCandles[.m3].last!.endGlobalIndex`（连续轴 = count-1），m3 缺/空 → `throw .trainingSet(.emptyData)`（早于 make，因 `FlowInput.normal/.replay` 需 maxTick）。Review 用 `record.finalTick`（经 `.review(record)`，make 内部派生），仅校验 m3 非空 | E5b plan helper `maxTick = closes.count-1`；make L176-178 二次校验 `m3.last.endGlobalIndex >= maxTick` |
| **D4** | **新局起始资金 = 累计模型**：`let s = try recordRepo.statistics(); start = s.totalCount > 0 ? s.currentCapital : settings.settings.totalCapital`。`initialCapital == initialCashBalance == start`，空仓 | `statistics().currentCapital` = 末条 `total_capital+profit`（无记录返 0）；NormalFlow `shouldAccumulateCapital()==true`；`accumulated_capital` = 本局起始资金（modules L463/L533） |
| **D5** | **Review 重建**（只读，固定末态）：`.review(record)`（initialTick=finalTick）；`initialMarkers = markers(from: ops)`、`initialDrawings = bundle.drawings`、`initialTradeOperations = ops`；空仓；`initialCapital = record.totalCapital`、`initialCashBalance = record.totalCapital + record.profit`（末态全现金 → currentTotalCapital/returnRate 与 record 自洽）；`initialDrawdown = .initial` | plan L893「显示该局结束时完整状态，只读」+ L1213「还原全部标记和绘线」+ L1252「标记/绘线完整还原+不可步进」 |
| **D6** | **Replay 重建**（从头，不入账）：`.replay(fees: record.feeSnapshot, maxTick: m3max)`（initialTick=0）；**无** markers/drawings/ops（fresh）；空仓；`initialCapital = initialCashBalance = record.totalCapital`；`initialDrawdown = .initial` | plan L894「重玩同一训练组…使用原局 FeeSnapshot」+ L365「从头开始(tick=0)」 |
| **D7** | **Resume 重建**：`pendingRepo.loadPending()` → `nil` 才返回 `nil`（**仅**无 pending）；否则 `.normal(fees: pending.feeSnapshot, maxTick: m3max)`、`initialTick = pending.globalTickIndex`、`initialCapital = pending.accumulatedCapital`、`initialCashBalance = pending.cashBalance`、`initialPosition = try decodePosition(pending.positionData)`、`initialMarkers = markers(from: pending.tradeOperations)`、`initialDrawings = pending.drawings`、`initialTradeOperations = pending.tradeOperations`、`initialDrawdown = pending.drawdown`、`initialUpperPeriod/Lower = pending.upper/lowerPeriod` | modules L1667-1668 + L522-538 resume 语义（从 `PendingTraining.drawdown` 直接重建 accumulator）；markers 不持久（TradeMarker 非 Codable）→ 从 ops 重建 |
| **D8** | `expectedSchemaVersion` **硬编码 `1`**（私有 helper 内，注释 `// M0.1 TRAINING_SET_SCHEMA_VERSION = 1`），**不**引入共享常量 | modules L1847/L2202；顺位 6 P2 并行 PR 也消费此值，避免两 PR 重复定义 → 编译冲突；shared-constant 留单一 owner（PR body 标协调说明，作 residual E6a-R1） |
| **D9** | **fail-closed 半态**：成功才写 `activeEngine`/`activeReader`；open reader 后任何步骤 throw → `reader.close()` + 不写 active（do/catch 包 open 之后逻辑）。snapshotFeesIfReady/pickRandom/statistics 在 open **之前**，其 throw 时无 reader 可关 | outline 顺位 4 residual「失败时不造 engine + 不保留 activeReader/session state」 |
| **D10** | **不**关闭既存 `activeReader`（前一 session 清理 = `endSession()`/E6b + caller 契约：U1 先 endSession 再开新局）。E6a 只关本调用开的 reader（失败时） | spec：`activeReader` 生命周期与 session 对齐，`endSession()` 负责 close（E6b scope）。登记 residual E6a-R2 |
| **D11** | **M0.4 边界**：E6 是 public throwing 模块。唯一内部错误源 = `positionData` 的 `JSONDecoder().decode`（DecodingError）→ 私有 `decodePosition` helper 内翻译为 `AppError.persistence(.dbCorrupted)`；所有显式 `throw` 用 `AppError` 字面；public 方法体**无** raw 危险 try（decode 在 private helper）。**不**新建 `check_e6_apperror_gate.sh`（E5a `make` 同抛 AppError 亦无专属 gate；m04 doc 仅显式列 P-模块）；改以**失败注入测试**覆盖每方法每失败模式 | `docs/governance/m04-apperror-translation-gate.md`（原则 + Gate 2 raw-try 规则）；E5a 先例 |
| **D12** | **不** loadMeta（E6a 构造不需 stock/起始年月——那是 E6b finalize 建 record 用）。**不** touch cache（LRU-on-use 非 spec 方法语义，留后续）。登记 residual E6a-R3（touch 留 E6b/顺位 11 评估） | 保持 surgical；method 注释只说「打开 reader → 构造 engine」 |

**未决留 review 的点**（plan-stage 对抗性 review 重点审）：
- D4 累计模型：spec 方法注释只说「构造 engine」未显式写资金来源；本 plan 据数据模型（statistics + accumulated_capital 语义）推定。若 reviewer 认为新局应恒用 `settings.totalCapital`（不累计），需 user 裁决。
- D5 review cashBalance = `totalCapital + profit`：使引擎末态自洽，但若 settlement 直接读 record（不读引擎实时值），此重建仅影响训练页状态栏显示——不改 record 真值，安全。

---

## File Structure

| File | 责任 | 改动 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` | E6 协调器：4 构造方法真实现 + 5 私有 helper | Modify（替换 4 个 `fatalError` 体 + 新增 helper；不动 init/存储/另 3 方法/preview） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorConstructionTests.swift` | E6a 行为 + 失败注入测试（新文件，不动 Wave 0 shape 测试文件） | Create |
| `docs/acceptance/2026-06-07-pr-e6a-session-coordinator-construction.md` | 非编码者验收清单（中文）+ M0.4 失败注入证据表 | Create |

**Prod LOC 估算**：4 方法 ~70 + 5 helper ~45 + 注释 ~40 = **~155 行新增**（≤500 预算内）。

**测试新增**：Task 1-5 共 **17 tests / 1 suite**（Task1 1 + Task2 5 + Task3 5 + Task4 3 + Task5 3；含 M0.4 失败注入：open-throws / loadCandles-fails / corrupt-position / stale-tick + 各方法 post-open reader-close）。

---

## Task 1: 私有 helper + Normal happy-path 骨架（建立编排模式）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorConstructionTests.swift`

- [ ] **Step 1.1: 写失败测试（test fixtures + Normal happy-path）**

Create `TrainingSessionCoordinatorConstructionTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingSessionCoordinatorConstruction")
struct TrainingSessionCoordinatorConstructionTests {

    // MARK: - 合法 candle fixture（连续 .m3 轴 0..n + m60/daily 非空，过 make 全校验）

    /// m3: globalIndex==endGlobalIndex==i, i∈0..<count；m60/daily 覆盖到 maxTick。
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

    /// 设置非零起始本金的 DAO（happy-path：load 成功）。
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

    /// 组装一个 coordinator：注入指定 candle 的 reader（经 PreviewTrainingSetDBFactory）+
    /// 已 seed 一个缓存文件 + 指定起始本金的 SettingsStore。
    static func makeCoordinator(
        candles: [Period: [KLineCandle]],
        capital: Double = 100_000,
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

    @Test("startNewNormalSession: 无记录 → 起始本金取 settings.totalCapital + 引擎可交易 + active 写入")
    func startNew_noRecords_usesSettingsCapital() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        let engine = try await coord.startNewNormalSession()
        #expect(engine.initialCapital == 50_000)
        #expect(engine.cashBalance == 50_000)
        #expect(engine.flow.mode == .normal)
        #expect(engine.tick.globalTickIndex == 0)        // NormalFlow.initialTick == 0
        #expect(coord.activeEngine != nil)
        #expect(coord.activeReader != nil)
    }
}
```

- [ ] **Step 1.2: 跑测试验证失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6a-session-coordinator/ios/Contracts"
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -15
```
Expected: FAIL —— `fatalError("Wave 2 E6 impl")` 触发（或 active 断言失败）。

- [ ] **Step 1.3: 实现 helper + startNewNormalSession**

**先加 import（必须，否则不编译）**：Wave 0 `TrainingSessionCoordinator.swift` 顶部只 `import Observation`，但 `decodePosition`（Task 3）用 `Data`/`JSONDecoder`（Foundation 类型）。在文件顶部 `#if canImport(Observation)` 块**之上**加：

```swift
import Foundation
```

然后在 `TrainingSessionCoordinator.swift` 内，把 `startNewNormalSession` 的 `fatalError` 体替换为下方实现，并在 class 末尾（`endSession()` 之后、`#if DEBUG` preview 之前）加 `// MARK: - 私有构造 helper（E6a）` 段：

```swift
    /// 开始新 Normal 训练（spec L1664）：fail-closed 取费 → 随机选训练组 → 打开 reader →
    /// 累计本金构造 NormalFlow 引擎。loadError 时早抛、零副作用（D2/D9）。
    /// **前置（D10）**：caller 须先 `endSession()` 关闭上一 session 的 reader，否则上一
    /// `activeReader` 被覆盖泄漏（E6a 不替前一 session 收尾——E6b/caller 契约）。
    public func startNewNormalSession() async throws -> TrainingEngine {
        let fees = try settings.snapshotFeesIfReady()        // D2 fail-closed：loadError → throw（reader 未开）
        guard let file = cache.pickRandom() else {
            throw AppError.trainingSet(.fileNotFound)         // 无可用缓存训练组
        }
        let start = try startingCapital()                    // D4 累计模型（reader 未开，throw 无副作用）
        let reader = try openReader(for: file)
        do {
            let allCandles = try reader.loadAllCandles()
            let mt = try maxTick(from: allCandles)            // D3
            let engine = try TrainingEngine.make(
                .normal(fees: fees, maxTick: mt),
                allCandles: allCandles,
                initialCapital: start, initialCashBalance: start)
            activeReader = reader
            activeEngine = engine
            return engine
        } catch {
            reader.close()                                   // D9：失败关闭已开 reader，不留半态
            // D11 M0.4：单表达式可静态证明类型（禁裸变量 `throw error`，m04 gate 规则1）
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
    }
```

helper（加在 `// MARK: - 私有构造 helper（E6a）` 段下）：

```swift
    /// D4：新局起始资金 = 累计模型。有记录 → 末条 total_capital+profit；无记录 → settings 配置本金。
    private func startingCapital() throws -> Double {
        let stats = try recordRepo.statistics()
        return stats.totalCount > 0 ? stats.currentCapital : settings.settings.totalCapital
    }

    /// D8：按 M0.1 schema 版本打开训练组（每次新 reader 实例，spec L1830）。
    private func openReader(for file: TrainingSetFile) throws -> TrainingSetReader {
        // M0.1 TRAINING_SET_SCHEMA_VERSION = 1（modules L1847/L2202）。E6a 硬编码避免与并行
        // 顺位 6 P2 PR 重复定义共享常量致编译冲突；shared-constant 单一 owner 见 PR body（residual E6a-R1）。
        try dbFactory.openAndVerify(file: file.localURL, expectedSchemaVersion: 1)
    }

    /// D3：从已校验 candle 取 maxTick = .m3 末根 endGlobalIndex（连续轴 = count-1）。
    /// .m3 缺/空 → 可恢复 .emptyData（make 也二次校验，但 FlowInput.normal/.replay 需先得 maxTick）。
    private func maxTick(from allCandles: [Period: [KLineCandle]]) throws -> Int {
        guard let m3 = allCandles[.m3], let last = m3.last else {
            throw AppError.trainingSet(.emptyData)
        }
        return last.endGlobalIndex
    }
```

- [ ] **Step 1.4: 跑测试验证通过**

```bash
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -8
```
Expected: 1/1 PASS, 0 warnings。

- [ ] **Step 1.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorConstructionTests.swift
git commit -m "feat(E6a): startNewNormalSession 真实现 + 构造 helper（fail-closed 费用快照 D2）"
```

---

## Task 2: startNewNormalSession 累计本金 + fail-closed/失败注入

**Files:**
- Modify: `TrainingSessionCoordinatorConstructionTests.swift`

- [ ] **Step 2.1: 追加测试（累计本金 + loadError + 无缓存 + reader 失败关闭）**

在 suite 内追加。先加测试用的失败注入 mock（放 suite 内 `static` 嵌套类型）：

```swift
    // MARK: - 失败注入 mock

    /// loadSettings 抛 → SettingsStore.loadError 置位 → snapshotFeesIfReady throws。
    struct ThrowingDAO: SettingsDAO {
        let error: AppError
        func loadSettings() throws -> AppSettings { throw error }
        func saveSettings(_: AppSettings) throws {}
        func resetCapital() throws {}
    }

    /// 记录 close() 调用 + 可配置 loadAllCandles 抛错的 spy reader。
    final class SpyReader: TrainingSetReader, @unchecked Sendable {
        let candles: [Period: [KLineCandle]]
        let loadError: AppError?
        private(set) var closed = false
        init(candles: [Period: [KLineCandle]], loadError: AppError? = nil) {
            self.candles = candles; self.loadError = loadError
        }
        func loadMeta() throws -> TrainingSetMeta {
            TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 1)
        }
        func loadAllCandles() throws -> [Period: [KLineCandle]] {
            if let e = loadError { throw e }
            return candles
        }
        func close() { closed = true }
    }

    /// 注入指定 reader 的 factory（绕过 PreviewTrainingSetDBFactory 的 happy-path）。
    struct StubFactory: TrainingSetDBFactory {
        let reader: TrainingSetReader
        let openError: AppError?
        init(reader: TrainingSetReader, openError: AppError? = nil) {
            self.reader = reader; self.openError = openError
        }
        func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
            if let e = openError { throw e }
            return reader
        }
    }

    /// 用指定 factory + 起始本金 + 缓存文件 组装 coordinator（失败注入专用）。
    static func makeCoordinator(
        factory: TrainingSetDBFactory,
        settings: SettingsStore,
        seedFile: TrainingSetFile? = cachedFile()
    ) -> TrainingSessionCoordinator {
        let cache = InMemoryCacheManager()
        if let f = seedFile { cache._seedForTesting([f]) }
        return TrainingSessionCoordinator(
            dbFactory: factory,
            recordRepo: InMemoryRecordRepository(),
            pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(),
            cache: cache,
            settings: settings)
    }

    @Test("startNewNormalSession: 有记录 → 起始本金取 statistics().currentCapital（末条 total+profit）")
    func startNew_withRecords_usesAccumulatedCapital() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        _ = try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 100,
                           stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                           totalCapital: 50_000, profit: 12_000, returnRate: 0.24, maxDrawdown: 0,
                           buyCount: 1, sellCount: 1,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
        let engine = try await coord.startNewNormalSession()
        #expect(engine.initialCapital == 62_000)         // 50000 + 12000，非 settings 50000
        #expect(engine.cashBalance == 62_000)
    }

    @Test("startNewNormalSession: settings.loadError → throws 且不写 active（fail-closed D2/D9）")
    func startNew_loadError_throwsNoActive() async throws {
        let store = SettingsStore(settingsDAO: ThrowingDAO(error: .persistence(.dbCorrupted)))
        let spy = SpyReader(candles: Self.validCandles())
        let coord = Self.makeCoordinator(factory: StubFactory(reader: spy), settings: store)
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            try await coord.startNewNormalSession()
        }
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
        #expect(spy.closed == false)                     // reader 从未打开（fees 早抛）
    }

    @Test("startNewNormalSession: 无缓存训练组 → .trainingSet(.fileNotFound)")
    func startNew_noCache_throwsFileNotFound() async throws {
        let store = SettingsStore(settingsDAO: CapitalDAO(capital: 10_000))
        let coord = Self.makeCoordinator(
            factory: StubFactory(reader: SpyReader(candles: Self.validCandles())),
            settings: store, seedFile: nil)
        await #expect(throws: AppError.trainingSet(.fileNotFound)) {
            try await coord.startNewNormalSession()
        }
        #expect(coord.activeReader == nil)
    }

    @Test("startNewNormalSession: loadAllCandles 抛 → reader.close() 调用 + 不写 active（D9）")
    func startNew_loadCandlesFails_closesReader() async throws {
        let store = SettingsStore(settingsDAO: CapitalDAO(capital: 10_000))
        let spy = SpyReader(candles: [:], loadError: .persistence(.ioError("disk")))
        let coord = Self.makeCoordinator(factory: StubFactory(reader: spy), settings: store)
        await #expect(throws: AppError.persistence(.ioError("disk"))) {
            try await coord.startNewNormalSession()
        }
        #expect(spy.closed == true)                      // D9：失败关闭已开 reader
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    @Test("startNewNormalSession: openAndVerify 抛 .versionMismatch → 传播 + 不写 active（reader 未建）")
    func startNew_openThrows_propagatesNoActive() async throws {
        let store = SettingsStore(settingsDAO: CapitalDAO(capital: 10_000))
        let spy = SpyReader(candles: Self.validCandles())
        let coord = Self.makeCoordinator(
            factory: StubFactory(reader: spy, openError: .trainingSet(.versionMismatch(expected: 1, got: 2))),
            settings: store)
        await #expect(throws: AppError.trainingSet(.versionMismatch(expected: 1, got: 2))) {
            try await coord.startNewNormalSession()
        }
        #expect(spy.closed == false)                     // openAndVerify 抛 → 无 reader 返回，无可关
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }
```

- [ ] **Step 2.2: 跑测试验证通过（实现已在 Task 1 完成）**

```bash
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -8
```
Expected: 6/6 PASS, 0 warnings。（本 Task 纯加测试覆盖 Task 1 实现的分支；若任一失败 = Task 1 实现缺陷，回 Task 1 修。）

- [ ] **Step 2.3: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorConstructionTests.swift
git commit -m "test(E6a): startNewNormalSession 累计本金 + fail-closed/失败注入覆盖"
```

---

## Task 3: resumePending 真实现

**Files:**
- Modify: `TrainingSessionCoordinator.swift`（替换 `resumePending` 体 + 加 `decodePosition`/`markers` helper）
- Modify: `TrainingSessionCoordinatorConstructionTests.swift`

- [ ] **Step 3.1: 写失败测试**

追加（先加 pending fixture helper + 测试）：

```swift
    static func pending(
        filename: String = "set.sqlite",
        tick: Int = 3,
        position: PositionManager = PositionManager(shares: 100, averageCost: 10, totalInvested: 1000),
        cash: Double = 90_000,
        accumulated: Double = 100_000,
        positionDataOverride: Data? = nil,
        ops: [TradeOperation] = []
    ) throws -> PendingTraining {
        let posData = try positionDataOverride ?? JSONEncoder().encode(position)
        return PendingTraining(
            trainingSetFilename: filename, globalTickIndex: tick,
            upperPeriod: .m60, lowerPeriod: .daily,
            positionData: posData, cashBalance: cash,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
            tradeOperations: ops, drawings: [], startedAt: 1,
            accumulatedCapital: accumulated, drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 5_000))
    }

    @Test("resumePending: 无 pending → 返回 nil（不抛、不写 active）")
    func resume_noPending_returnsNil() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.resumePending()
        #expect(engine == nil)
        #expect(coord.activeEngine == nil)
    }

    @Test("resumePending: 有 pending → 重建 tick/position/cash/drawdown/periods + active 写入")
    func resume_happy_rebuildsState() async throws {
        let (coord, _, pendingRepo) = Self.makeCoordinator(candles: Self.validCandles())
        try pendingRepo.savePending(try Self.pending(tick: 3, cash: 90_000, accumulated: 100_000))
        let engine = try #require(try await coord.resumePending())
        #expect(engine.tick.globalTickIndex == 3)        // D7：initialTick = pending.globalTickIndex
        #expect(engine.position.shares == 100)            // decode 还原
        #expect(engine.cashBalance == 90_000)
        #expect(engine.initialCapital == 100_000)         // accumulatedCapital
        #expect(engine.upperPanel.period == .m60)
        #expect(engine.lowerPanel.period == .daily)
        #expect(coord.activeReader != nil)
    }

    @Test("resumePending: positionData 损坏 → .persistence(.dbCorrupted)（D11）+ reader 关闭")
    func resume_corruptPosition_throwsDbCorrupted() async throws {
        let store = SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000))
        let spy = Self.SpyReader(candles: Self.validCandles())
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let pendingRepo = InMemoryPendingTrainingRepository()
        try pendingRepo.savePending(try Self.pending(positionDataOverride: Data("not json".utf8)))
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: InMemoryRecordRepository(), pendingRepo: pendingRepo,
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: store)
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            try await coord.resumePending()
        }
        #expect(spy.closed == true)
        #expect(coord.activeEngine == nil)
    }

    @Test("resumePending: 训练组文件不在缓存 → .trainingSet(.fileNotFound)")
    func resume_fileMissing_throwsFileNotFound() async throws {
        let (coord, _, pendingRepo) = Self.makeCoordinator(candles: Self.validCandles(), seedFile: nil)
        try pendingRepo.savePending(try Self.pending())
        await #expect(throws: AppError.trainingSet(.fileNotFound)) {
            try await coord.resumePending()
        }
    }

    @Test("resumePending: stale tick 超出 maxTick → make 抛 .emptyData + reader 关闭（D7/D9）")
    func resume_staleTick_throwsEmptyDataClosesReader() async throws {
        let store = SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000))
        let spy = Self.SpyReader(candles: Self.validCandles(m3Count: 8))   // maxTick = 7
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let pendingRepo = InMemoryPendingTrainingRepository()
        try pendingRepo.savePending(try Self.pending(tick: 99))            // 超出 allowedTickRange 0...7（训练组被替换）
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: InMemoryRecordRepository(), pendingRepo: pendingRepo,
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: store)
        await #expect(throws: AppError.trainingSet(.emptyData)) {
            try await coord.resumePending()
        }
        #expect(spy.closed == true)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }
```

- [ ] **Step 3.2: 跑测试验证失败**

```bash
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -15
```
Expected: resume 系列 FAIL（`fatalError("Wave 2 E6 impl")`）。

- [ ] **Step 3.3: 实现 resumePending + decodePosition/markers helper**

替换 `resumePending` 体：

```swift
    /// 继续中断训练（spec L1667）：loadPending → 按 filename 打开 reader → 从 pending 重建引擎（D7）。
    /// 无 pending 返回 nil（**仅**此情形返 nil；其它失败均 throw 可恢复 AppError）。
    public func resumePending() async throws -> TrainingEngine? {
        guard let pending = try pendingRepo.loadPending() else { return nil }
        let file = try cachedFile(filename: pending.trainingSetFilename)
        let reader = try openReader(for: file)
        do {
            let allCandles = try reader.loadAllCandles()
            let mt = try maxTick(from: allCandles)
            let position = try decodePosition(pending.positionData)
            let engine = try TrainingEngine.make(
                .normal(fees: pending.feeSnapshot, maxTick: mt),
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
            return engine
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
    }
```

加 helper（私有构造 helper 段内）：

```swift
    /// 按 filename 在缓存中定位训练组文件；缺失 → 可恢复 .fileNotFound。
    private func cachedFile(filename: String) throws -> TrainingSetFile {
        guard let file = cache.listAvailable().first(where: { $0.filename == filename }) else {
            throw AppError.trainingSet(.fileNotFound)
        }
        return file
    }

    /// D11 M0.4 边界：positionData 反序列化（唯一内部错误源）。损坏/被篡改存档的
    /// PositionManager.init(from:) 抛 DecodingError（§4.2.1 入口 2）→ 翻译为可恢复 .dbCorrupted。
    /// decode 必须在此私有 helper（M0.4 Gate 2：public 方法体禁 raw .decode）。
    private func decodePosition(_ data: Data) throws -> PositionManager {
        do {
            return try JSONDecoder().decode(PositionManager.self, from: data)
        } catch {
            throw AppError.persistence(.dbCorrupted)
        }
    }

    /// 从交易流水重建 UI 标记（TradeMarker 非 Codable，不持久 → resume/review 由 ops 重建）。
    private func markers(from ops: [TradeOperation]) -> [TradeMarker] {
        ops.map { TradeMarker(globalTick: $0.globalTick, price: $0.price, direction: $0.direction) }
    }
```

- [ ] **Step 3.4: 跑测试验证通过**

```bash
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -8
```
Expected: resume 5 测试全 PASS（累计 11/11），0 warnings。

- [ ] **Step 3.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorConstructionTests.swift
git commit -m "feat(E6a): resumePending 真实现（throwing decoder + 状态重建 D7/D11）"
```

---

## Task 4: review 真实现（只读复盘，还原标记/绘线）

**Files:**
- Modify: `TrainingSessionCoordinator.swift`（替换 `review` 体）
- Modify: `TrainingSessionCoordinatorConstructionTests.swift`

- [ ] **Step 4.1: 写失败测试**

追加：

```swift
    /// 插一条带 ops/drawings 的记录，返回 recordId。
    static func seedRecord(
        _ records: InMemoryRecordRepository,
        filename: String = "set.sqlite",
        totalCapital: Double = 100_000, profit: Double = 8_000, finalTick: Int = 7,
        ops: [TradeOperation], drawings: [DrawingObject] = []
    ) throws -> Int64 {
        try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: filename, createdAt: 1,
                           stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
                           totalCapital: totalCapital, profit: profit,
                           returnRate: profit / totalCapital, maxDrawdown: -0.05,
                           buyCount: 1, sellCount: 1,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: true),
                           finalTick: finalTick),
            ops: ops, drawings: drawings)
    }

    static func op(tick: Int, price: Double, dir: TradeDirection) -> TradeOperation {
        TradeOperation(globalTick: tick, period: .m3, direction: dir, price: price, shares: 100,
                       positionTier: .tier1, commission: 1, stampDuty: 0, totalCost: price * 100,
                       createdAt: 0)
    }

    @Test("review: 只读末态 + 还原标记 + tick=finalTick + 收益率与 record 自洽（D5）")
    func review_happy_restoresEndState() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles())
        let id = try Self.seedRecord(records, totalCapital: 100_000, profit: 8_000, finalTick: 7,
                                     ops: [Self.op(tick: 2, price: 10.2, dir: .buy),
                                           Self.op(tick: 5, price: 10.5, dir: .sell)])
        let engine = try await coord.review(recordId: id)
        #expect(engine.flow.mode == .review)
        #expect(engine.flow.canBuySell() == false)        // ReviewFlow 全能力关
        #expect(engine.tick.globalTickIndex == 7)          // initialTick = finalTick
        #expect(engine.markers.count == 2)                 // 还原全部标记
        #expect(engine.tradeOperations.count == 2)
        #expect(engine.initialCapital == 100_000)
        #expect(abs(engine.returnRate - 0.08) < 1e-9)      // (108000-100000)/100000 = record.returnRate
        #expect(coord.activeReader != nil)
    }

    @Test("review: 费率来自 record 非当前 settings（D5）")
    func review_usesRecordFees() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 10_000)
        let id = try Self.seedRecord(records, ops: [])
        let engine = try await coord.review(recordId: id)
        #expect(engine.fees.commissionRate == 0.0002)      // record.feeSnapshot，非 settings 的 0.0001
        #expect(engine.fees.minCommissionEnabled == true)
    }

    @Test("review: loadAllCandles 抛 → reader.close() + 不写 active（D9 post-open）")
    func review_loadCandlesFails_closesReader() async throws {
        let store = SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000))
        let records = InMemoryRecordRepository()
        let id = try Self.seedRecord(records, ops: [])
        let spy = Self.SpyReader(candles: [:], loadError: .persistence(.ioError("x")))
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: store)
        await #expect(throws: AppError.persistence(.ioError("x"))) {
            try await coord.review(recordId: id)
        }
        #expect(spy.closed == true)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }
```

- [ ] **Step 4.2: 跑测试验证失败**

```bash
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -12
```
Expected: review 系列 FAIL（`fatalError`）。

- [ ] **Step 4.3: 实现 review**

替换 `review` 体：

```swift
    /// Review 模式（spec L1670）：record bundle → 打开 reader → 构造只读 ReviewFlow 引擎，
    /// 还原全部标记/绘线、固定末态（D5）。费率/起始年月均来自 record，不读当前 settings。
    /// **D5 不变量**：review 仅供只读展示；`initialCashBalance = totalCapital + profit`（末态全现金，
    /// 强平后）使引擎实时 `returnRate == record.returnRate`（flat-ending-cash 假设下自洽）；**不**改写
    /// record 真值（settlement 若直读 record 则此重建只影响训练页状态栏显示，安全）。
    /// **前置（D10）**：caller 须先 `endSession()`（同 startNewNormalSession）。
    public func review(recordId: Int64) async throws -> TrainingEngine {
        let (record, ops, drawings) = try recordRepo.loadRecordBundle(id: recordId)
        let file = try cachedFile(filename: record.trainingSetFilename)
        let reader = try openReader(for: file)
        do {
            // maxTick 由 .review(record) 内部据 record.finalTick 派生；make 亦校验 .m3 非空 +
            // m3.last.endGlobalIndex >= finalTick，故此处不重复 maxTick(from:)（D3 / LOW#8）。
            let allCandles = try reader.loadAllCandles()
            let engine = try TrainingEngine.make(
                .review(record: record),
                allCandles: allCandles,
                initialCapital: record.totalCapital,
                initialCashBalance: record.totalCapital + record.profit,   // 末态全现金（强平后）
                initialMarkers: markers(from: ops),
                initialDrawings: drawings,
                initialTradeOperations: ops)
            activeReader = reader
            activeEngine = engine
            return engine
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
    }
```

- [ ] **Step 4.4: 跑测试验证通过**

```bash
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -8
```
Expected: review 3 测试 PASS（累计 14/14），0 warnings。

- [ ] **Step 4.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorConstructionTests.swift
git commit -m "feat(E6a): review 真实现（只读复盘，还原标记/绘线 D5）"
```

---

## Task 5: replay 真实现（从头重玩，继承原局费率）

**Files:**
- Modify: `TrainingSessionCoordinator.swift`（替换 `replay` 体）
- Modify: `TrainingSessionCoordinatorConstructionTests.swift`

- [ ] **Step 5.1: 写失败测试**

追加：

```swift
    @Test("replay: 从头 tick=0 + 无标记 + 用原局费率 + 起始本金=record.totalCapital（D6）")
    func replay_happy_freshFromOriginalFees() async throws {
        let (coord, records, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 10_000)
        let id = try Self.seedRecord(records, totalCapital: 80_000, profit: 5_000,
                                     ops: [Self.op(tick: 2, price: 10.2, dir: .buy)])
        let engine = try await coord.replay(recordId: id)
        #expect(engine.flow.mode == .replay)
        #expect(engine.flow.canBuySell() == true)          // Replay 可操作
        #expect(engine.flow.shouldSaveRecord() == false)   // 不入账
        #expect(engine.tick.globalTickIndex == 0)          // 从头
        #expect(engine.markers.isEmpty)                    // fresh，无还原
        #expect(engine.tradeOperations.isEmpty)
        #expect(engine.initialCapital == 80_000)           // record.totalCapital（非累计、非 settings）
        #expect(engine.cashBalance == 80_000)
        #expect(engine.fees.commissionRate == 0.0002)      // 原局 feeSnapshot
        #expect(coord.activeReader != nil)
    }

    @Test("replay: 记录不存在 → 传播 AppError（fake 抛 .dbCorrupted；reader 未开）")
    func replay_unknownRecord_propagates() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles())
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            try await coord.replay(recordId: 999)
        }
        #expect(coord.activeReader == nil)
    }

    @Test("replay: loadAllCandles 抛 → reader.close() + 不写 active（D9 post-open）")
    func replay_loadCandlesFails_closesReader() async throws {
        let store = SettingsStore(settingsDAO: Self.CapitalDAO(capital: 10_000))
        let records = InMemoryRecordRepository()
        let id = try Self.seedRecord(records, ops: [])
        let spy = Self.SpyReader(candles: [:], loadError: .persistence(.diskFull))
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile()])
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: spy),
            recordRepo: records, pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(), cache: cache, settings: store)
        await #expect(throws: AppError.persistence(.diskFull)) {
            try await coord.replay(recordId: id)
        }
        #expect(spy.closed == true)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }
```

- [ ] **Step 5.2: 跑测试验证失败**

```bash
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -12
```
Expected: replay 系列 FAIL（`fatalError`）。

- [ ] **Step 5.3: 实现 replay**

替换 `replay` 体：

```swift
    /// Replay 模式（spec L1673）：record → 打开 reader → 从头构造 ReplayFlow 引擎（只继承原局
    /// feeSnapshot，不还原标记/绘线、不入账，D6）。起始本金 = record 原局起始本金。
    public func replay(recordId: Int64) async throws -> TrainingEngine {
        let (record, _, _) = try recordRepo.loadRecordBundle(id: recordId)
        let file = try cachedFile(filename: record.trainingSetFilename)
        let reader = try openReader(for: file)
        do {
            let allCandles = try reader.loadAllCandles()
            let mt = try maxTick(from: allCandles)
            let engine = try TrainingEngine.make(
                .replay(fees: record.feeSnapshot, maxTick: mt),
                allCandles: allCandles,
                initialCapital: record.totalCapital,
                initialCashBalance: record.totalCapital)
            activeReader = reader
            activeEngine = engine
            return engine
        } catch {
            reader.close()
            throw (error as? AppError) ?? .internalError(module: "E6a", detail: String(describing: error))
        }
    }
```

- [ ] **Step 5.4: 跑测试验证通过**

```bash
swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 | tail -8
```
Expected: replay 3 测试 PASS（累计 17/17），0 warnings。

- [ ] **Step 5.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorConstructionTests.swift
git commit -m "feat(E6a): replay 真实现（从头重玩，继承原局费率 D6）"
```

---

## Task 6: 整体 verification + iOS gate + acceptance doc + PR

- [ ] **Step 6.1: 全量 swift test**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6a-session-coordinator/ios/Contracts"
swift test 2>&1 | tail -6
```
Expected: baseline + 17 新测试全 PASS（确切数 = pre-flight baseline + 17），0 failures。

- [ ] **Step 6.2: 0 warnings 复核（Sendable / unused / strict concurrency / async-no-await）**

```bash
swift build 2>&1 | grep -i "warning" | head -10
swift test 2>&1 | grep -i "warning" | head -10
```
Expected: 空输出。若 `async` 方法报 no-await 警告（不应——Swift 不警告），保留 `async`（契约冻结，不删）。

- [ ] **Step 6.3: iOS Simulator SDK typecheck gate**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6a-session-coordinator"
swiftc -typecheck \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios17.0-simulator \
  $(find ios/Contracts/Sources/KlineTrainerContracts -name "*.swift")
```
Expected: exit 0（`@MainActor`/`@Observable`/Sendable 在 iOS 17 SDK 解析全过）。

- [ ] **Step 6.4: M0.4 静态自检（D11，手工 grep——E6a 无专属 gate 脚本）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave2-e6a-session-coordinator/ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine"
# 每条 throw 行必须含 AppError；public 方法体内不得有 raw .decode（须在 private helper）
grep -nE "throw " TrainingSessionCoordinator.swift | grep -v "AppError" || echo "PASS: 全部 throw 用 AppError"
grep -nE "\.decode\(|JSONDecoder" TrainingSessionCoordinator.swift
# 期望：.decode 仅出现在 decodePosition private helper 内
```
Expected: 第一条 `PASS`；第二条仅命中 `decodePosition` helper 内一处。

- [ ] **Step 6.5: 主线 verification-before-completion**

主线（非 subagent）跑 superpowers:verification-before-completion，贴：
- `swift test` 完整尾部（确切计数）
- iOS gate exit code
- `git diff main --stat`（文件 + LOC）
- M0.4 自检输出
- 「未交付」清单：E6b `saveProgress`/`finalize`/`endSession`（顺位 5）；residuals **E6a-R1**（schema 共享常量 `TRAINING_SET_SCHEMA_VERSION`：单一 owner = 顺位 6 P2 PR；先 merge 方定义、另一方复用，PR body 明示协调）/ **E6a-R2**（启动新 session 前既存 `activeReader` 清理归 `endSession()`/caller，方法 doc 已标前置）/ **E6a-R3**（cache touch-on-use LRU 留 E6b/顺位 11 评估）

- [ ] **Step 6.6: 写非编码者验收清单 + M0.4 证据表**

Create `docs/acceptance/2026-06-07-pr-e6a-session-coordinator-construction.md`：中文，每条 action / expected / pass-fail（禁忌词见 `.claude/workflow-rules.json`）。至少覆盖：startNewNormalSession 新局可达 + 累计本金 + loadError 拒开局；resumePending 恢复中断局 + 损坏存档拒恢复；review 还原标记不可交易；replay 从头用原局费率。附 M0.4 public throwing 方法 → 失败注入测试映射表（startNewNormalSession/resumePending/review/replay × 各失败模式 → 对应 `@Test` 名）。

- [ ] **Step 6.7: 主线 push + open PR（worktree → user TTY）**

per `feedback_worktree_local_ledger_user_tty_pr`：worktree 开发的分支 attest 写 worktree-local ledger；主仓 `gh pr create`/`merge` 被 guard 拦 → **user 真终端**执行。先 Read 主仓 attest-ledger.json 核对 + 建本地跟踪分支防 "cannot resolve head"。PR body（中文）列：4 方法落地 + D1-D12 决策 + 3 residual + 测试计数 + iOS gate + Catalyst CI 状态。

---

## Self-Review

**1. Spec coverage：**
- spec §E6 L1664 `startNewNormalSession`（随机选 → reader → 打包 fees → engine）✅ Task 1（fail-closed fees D2）
- spec §E6 L1667 `resumePending`（loadPending → reader → 恢复，无 pending 返 nil）✅ Task 3（D7）
- spec §E6 L1670 `review`（record → reader → ReviewFlow）✅ Task 4（D5 还原标记/绘线）
- spec §E6 L1673 `replay`（record → reader → ReplayFlow 只继承 fees）✅ Task 5（D6）
- outline 顺位 4 fail-closed 费用快照（snapshotFeesIfReady + loadError 守 + 失败不造 engine/不留 reader）✅ D2/D9 + Task 2 失败注入
- RFC §三#6 交易流禁 fail-open snapshotFees ✅ D2（仅 Normal 调 snapshotFeesIfReady；resume/review/replay 继承原局 fees 不读 settings）
- M0.4 边界（positionData 解码翻译 + throw 用 AppError + public 体禁 raw decode）✅ D11 + Task 6.4
- **未交付（顺位 5 E6b）**：`saveProgress`/`finalize`/`endSession`——保留 `fatalError`，本 PR 不动 ✅（明确 scope）

**2. Placeholder scan：** 无 TBD/TODO。残留 `fatalError` 仅在 E6b 的 3 方法（显式 scope 边界，非 placeholder）。所有 Task 步骤含完整代码/命令/期望。

**3. Type consistency：**
- `TrainingEngine.make(.normal/.review/.replay)` 签名 = E5a 实测（Task 1 pre-flight 校验）✅
- `markers(from:)` Task 3 定义，Task 4 review 复用（同名同签名）✅
- `cachedFile(filename:)` Task 3 定义，Task 4/5 复用 ✅
- `maxTick(from:)` Task 1 定义，Task 3/4/5 复用 ✅
- `openReader(for:)` / `startingCapital()` / `decodePosition(_:)` 定义与调用一致 ✅
- `PendingTraining`/`TrainingRecord`/`TradeOperation`/`TradeMarker`/`FeeSnapshot`/`DrawdownAccumulator` 字段名与 AppState.swift/Models.swift 实测一致（Task 1 pre-flight 校验）✅
- 测试 mock（`SpyReader`/`StubFactory`/`ThrowingDAO`/`CapitalDAO`）conform 的协议方法签名 = 6 dep protocol 实测 ✅

**4. 关键风险复核：**
- fail-closed 顺序：snapshotFeesIfReady → pickRandom → startingCapital **均在 openReader 之前**，throw 时 reader 未开（Task 2 `startNew_loadError` 断言 `spy.closed==false`）✅
- D9 失败半态：open 后逻辑包 do/catch，catch 内 `reader.close()` + 不写 active（Task 2/3 spy.closed==true 断言）✅
- resume 仅无 pending 返 nil，其它失败 throw（D7 + Task 3 覆盖 corrupt/fileMissing throw 分支）✅
- review 收益率自洽：cashBalance = totalCapital+profit、空仓 → returnRate==record.returnRate（Task 4 断言）✅
