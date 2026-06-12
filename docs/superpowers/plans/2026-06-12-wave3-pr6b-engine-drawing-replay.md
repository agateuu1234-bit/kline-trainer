# Wave 3 顺位 6b — TrainingEngine 画线投影 + replay 结算 payload engine 契约 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (per-task fresh subagent + two-stage review) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 给 engine/coordinator 加两个 Wave 3 消费锚所需的契约 —— §4.4c `engine.appendDrawing`（画线 commit 投影单一真相，供顺位 4）+ §4.4e `coordinator.replaySettlementPayload`（非持久化 replay 结算 payload，供顺位 8）。

**Architecture:** 纯 additive API。§4.4c = engine 方法 `appendDrawing(_:)`，镜像既有 `deleteDrawing`（`@Observable` 自动重渲染，`engine.drawings` 唯一渲染+持久化真相）。§4.4e = coordinator 方法 `replaySettlementPayload(engine:)`，**不改 `finalize`**、自行装配 in-memory `TrainingRecord`（复用 `TrainingRecord` 类型），不写 DB、不触 pending。零 schema / 零 UI / 零 render 文件改动。

**Tech Stack:** Swift 6, `@MainActor @Observable`, Swift Testing。

**权威输入：** `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` §4.4c + §4.4e + §4.5（anchor #1 RFC，PR #94 merged）。6a（PR #95）已落 `forceCloseManually`/`currentPositionTier`/atomic `performForceClose`。

---

## Scope 决策（关键 —— user 2026-06-12 裁决）

anchor #6 outline 范围估算列原文「plan 须拆：6a trade+tier+手动强平 / **6b 画线+zoom+replay-settlement engine API**」。**§4.4d zoom（visibleCount mutation + focus 不变量 + 去硬编码 80）经 user 2026-06-12 裁决「整条移到顺位 3」**，不在 6b：

> **理由**：§4.4d 的 focus 不变量（pinch 中点 candle x 不动）内在依赖 `RenderStateBuilder.makeViewport` 的像素几何（`candleStep = width/visibleCount` + offset→startIndex/pixelShift，含 floor/clamp/边缘饱和）。而 `makeViewport` 现**硬编码** `defaultVisibleCount=80`、**忽略** `panelState.visibleCount`（`RenderStateBuilder.swift:63/66`），RFC §4.4d 把「去硬编码 80」分给**顺位 3**。⇒ 若 6b 改 `panelState.visibleCount`，在顺位 3 去硬编码前**零渲染效果**，且 focus-offset-recompute **只能孤立公式测、无法端到端验证**（重演 6a 溢出式 codex 下钻风险）。把整条 zoom（mutation+focus+去硬编码+pinch 手势）打包进顺位 3，使 focus 数学与它依赖的 `makeViewport` 几何同 PR、消除脆弱性。

**不破 neck 真实目的**：neck（集中 engine 变更于 6）目的 = 防**轨 G + 轨 T 并发改 engine**。zoom 移顺位 3 后，仅顺位 3（轨 G）改 `panelState.visibleCount`，轨 T 不碰 → 无并发冲突，neck 目的未破。

**文档协调**：本 6b PR **不**编辑 RFC/outline（governance 文档改动不混入 impl PR，per CLAUDE.md backstop）。§4.4d 的 impl-anchor 重指派（6→3）+ RFC/outline 注记**随顺位 3 plan 落地**（§4.4d 在那实现）。本 plan §Scope 决策即权威记录。

**6b 子项 = 2**（§4.4c + §4.4e；≤3，单 PR 不再拆）。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | engine 状态 + 动作 | 修改：加 `appendDrawing(_:)`（Task 1，置于 `deleteDrawing` 旁，:643 区） |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` | 会话编排 | 修改：加 `replaySettlementPayload(engine:)`（Task 2，置于 `finalize` 之后，:233 后；**不改 finalize**） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift` | engine 动作测试 | 修改：加 `// MARK: - Wave 3 顺位 6b：appendDrawing` 段（Task 1） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift` | coordinator 持久化测试（已含 `makeCoordinator`/`MetaSpyReader`/`StubFactory`/`validCandles` fixture） | 修改：加 `// MARK: - Wave 3 顺位 6b：replaySettlementPayload` 段 + appendDrawing 持久化路径测试（Task 1+2，复用现有 fixture） |
| `docs/acceptance/2026-06-12-wave3-pr6b-engine-drawing-replay.md` | 验收清单 | 新建（Task 3） |

---

## 关键事实（grep 核实 2026-06-12，origin/main `33f3903`，含 6a）

- `TrainingEngine` = `@MainActor @Observable public final class`；`drawings` 是 `public private(set) var`（:25）；`deleteDrawing(at:)`（:643）= `precondition(indices.contains) + drawings.remove(at:)`——**无显式 revision bump**（`@Observable` 对 `drawings` 数组突变自动触发重渲染）。`make()/init` 已收 `initialDrawings`（restore/review 还原已支持）。`RenderStateBuilder` 渲染 `engine.drawings`；`coordinator.saveProgress`（:191）/ `finalize`（:230）持久化 `engine.drawings`。
- `DrawingObject(toolType: DrawingToolType, anchors: [DrawingAnchor], isExtended: Bool, panelPosition: Int)`；`DrawingAnchor(period: Period, candleIndex: Int, price: Double)`；`DrawingToolType` = `ray/trend/horizontal/golden/wave/cycle/time`。
- `TrainingSessionCoordinator` = `@MainActor @Observable`；`finalize(engine:) async throws -> Int64?`（:202）对 `shouldSaveRecord()==false`（Review/Replay）早返 `nil`（D2，**保持不变**）。`finalize` 装配 `TrainingRecord`（:213-229）：`totalCapital: starting`（=`engine.initialCapital`，D1 方案 A）、`profit: currentTotalCapital - starting`、`returnRate: engine.returnRate`、`maxDrawdown: Self.drawdownRatio(absolute:peak:)`、`buyCount/sellCount`（filter ops）、`feeSnapshot: engine.fees`、`finalTick: engine.tick.globalTickIndex`、`stockCode/stockName/startYear/startMonth` 来自 `reader.loadMeta()` + `Self.startYearMonth(from:)`。
- `coordinator.replay(recordId:)`（:150）= 载 record → 缓存文件 → 开 reader → `make(.replay(fees: record.feeSnapshot, maxTick:), initialCapital: record.totalCapital)` → 设 `activeReader/activeEngine/activeFile`、`activeStartedAt=nil`。`ReplayFlow.canBuySell()==true`（6a 实测）。
- coordinator 私有上下文：`activeFile: TrainingSetFile?`、`now: () -> Int64`（可测试覆盖）、`activeReader`/`activeEngine`（`public private(set)`）。helper：`Self.startYearMonth(from:)`、`Self.drawdownRatio(absolute:peak:)`。
- 测试 harness（`TrainingSessionPersistenceTests`）：`makeCoordinator(candles:capital:seedFile:)`、`MetaSpyReader(candles:meta:)`、`StubFactory(reader:)`、`validCandles(m3Count:8)`、`CapitalDAO`、`cachedFile(filename:)`；`InMemoryRecordRepository.listRecords(limit:)` / `.insertRecord` / `.loadRecordBundle`；`InMemoryPendingTrainingRepository.loadPending()`。
- 基线：821 tests / 120 suites pass（worktree off origin/main 33f3903）。

---

### Task 1: §4.4c `appendDrawing`（画线 commit 投影单一真相）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（`deleteDrawing` 之后，:646 区）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift`（engine 级）+ `TrainingSessionPersistenceTests.swift`（持久化路径）

**RFC §4.4c 契约：** `engine.appendDrawing(_ drawing: DrawingObject)` 把一条 committed 画线追加进 `engine.drawings`（→ `@Observable` 重渲染 + 进入 finalize/pending 持久化路径）。缺口仅此一个（restore/delete 已在）。不变量：`engine.drawings` 是唯一渲染+持久化真相。

- [ ] **Step 1: 写失败测试**

在 `TrainingEngineActionsTests.swift` 末尾（suite `}` 前）追加：

```swift
    // MARK: - Wave 3 顺位 6b：appendDrawing（RFC §4.4c 画线投影单一真相）

    static func horizontalDrawing(price: Double, candleIndex: Int = 0) -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m3, candleIndex: candleIndex, price: price)],
                      isExtended: false, panelPosition: 0)
    }

    @Test func appendDrawingAddsToDrawings() {
        let e = Self.tradeEngine(closes: [10, 10, 10])
        #expect(e.drawings.isEmpty)
        let d = Self.horizontalDrawing(price: 10.5)
        e.appendDrawing(d)
        #expect(e.drawings.count == 1)
        #expect(e.drawings.last == d)                // 追加进唯一真相
    }

    @Test func appendDrawingAccumulatesInOrder() {
        let e = Self.tradeEngine(closes: [10, 10, 10])
        let d0 = Self.horizontalDrawing(price: 10.1)
        let d1 = Self.horizontalDrawing(price: 10.2)
        e.appendDrawing(d0)
        e.appendDrawing(d1)
        #expect(e.drawings == [d0, d1])              // 顺序保留、累加
    }
```

在 `TrainingSessionPersistenceTests.swift` 末尾（suite `}` 前）追加（证 append → 持久化路径）：

```swift
    // MARK: - Wave 3 顺位 6b：appendDrawing 进入持久化路径

    @Test("appendDrawing: 追加的画线经 saveProgress 落 pending.drawings（§4.4c 单一真相→持久化）")
    func appendDrawing_flowsIntoPendingPersistence() async throws {
        let (coord, _, pending) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        coord.now = { 222 }
        let engine = try await coord.startNewNormalSession()
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.4)],
                              isExtended: false, panelPosition: 0)
        engine.appendDrawing(d)
        try await coord.saveProgress(engine: engine)
        let p = try #require(try pending.loadPending())
        #expect(p.drawings == [d])                   // engine.drawings → pending.drawings 单一真相
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter appendDrawing 2>&1 | tail -20`
Expected: 编译失败 —— `value of type 'TrainingEngine' has no member 'appendDrawing'`。

- [ ] **Step 3: 实现 `appendDrawing`（镜像 deleteDrawing）**

在 `TrainingEngine.swift` `deleteDrawing(at:)`（:643-646）**之后**插入：

```swift
    /// 追加一条 committed 画线进 `engine.drawings`（RFC §4.4c）。`engine.drawings` 是唯一渲染 +
    /// 持久化真相（`@Observable` 数组突变自动触发重渲染，同 `deleteDrawing`；进入 finalize/pending
    /// 持久化路径）。顺位 4 `DrawingInputController` 在 `manager.commit()` 后调本方法，使
    /// `manager.completedDrawings → engine.drawings` 单一真相（manager 仅作输入暂存）。
    public func appendDrawing(_ drawing: DrawingObject) {
        drawings.append(drawing)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter appendDrawing 2>&1 | tail -20`
Expected: PASS（`appendDrawingAddsToDrawings`/`appendDrawingAccumulatesInOrder`/`appendDrawing_flowsIntoPendingPersistence` 全 ✔，0 failures）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineActionsTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift
git commit -m "feat(6b): appendDrawing 画线 commit 投影单一真相（RFC §4.4c）"
```

---

### Task 2: §4.4e `replaySettlementPayload`（非持久化 replay 结算 payload）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（`finalize`:233 之后；**不改 `finalize`**）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift`

**RFC §4.4e 契约：** replay 结束（手动 §4.4a 或 auto maxTick）强平后，由 coordinator 构造 **in-memory `TrainingRecord`**（复用类型）——原局 FeeSnapshot + 强平后终态（total_capital/收益率/回撤/ops）。**不持久化不变量**：不写 `training_records`、不触 `pending_training`、`finalize` 对 replay 仍返 nil（持久化路径不变）。顺位 8 = UI/routing-only 消费。

**设计决策 D1（不改 finalize，避免重开 §4.7 residual）：** 本方法**自行装配** `TrainingRecord`，**不**从 `finalize` 抽共享 helper —— 保 `finalize` 完全不在本 PR diff 内，使 6a 接受的 §4.7 finalize-gating residual（顺位 10）严格不被本 PR 触碰/重开。装配字段语义**刻意镜像** `finalize`（D2/D1 方案 A），由测试 drift-guard。~12 行装配重复是有意取舍。

- [ ] **Step 1: 写失败测试**

在 `TrainingSessionPersistenceTests.swift` 末尾追加（含一个 replay 会话 helper）：

```swift
    // MARK: - Wave 3 顺位 6b：replaySettlementPayload（RFC §4.4e 非持久化 replay 结算 payload）

    /// 建一个活跃 replay 会话（seed 源 record + 注入可控 meta 的 reader），返回 (coord, engine, records, pending)。
    static func makeReplaySession(
        capital: Double = 100_000,
        meta: TrainingSetMeta = TrainingSetMeta(stockCode: "600000", stockName: "测试股",
                                                startDatetime: 1_583_000_000, endDatetime: 1_583_100_000)
    ) async throws -> (TrainingSessionCoordinator, TrainingEngine,
                       InMemoryRecordRepository, InMemoryPendingTrainingRepository) {
        let records = InMemoryRecordRepository()
        let pending = InMemoryPendingTrainingRepository()
        let cache = InMemoryCacheManager(); cache._seedForTesting([Self.cachedFile(filename: "set.sqlite")])
        let src = TrainingRecord(
            id: nil, trainingSetFilename: "set.sqlite", createdAt: 0,
            stockCode: "ignored", stockName: "ignored", startYear: 2000, startMonth: 1,
            totalCapital: capital, profit: 0, returnRate: 0, maxDrawdown: 0,
            buyCount: 0, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), finalTick: 7)
        let srcId = try records.insertRecord(src, ops: [], drawings: [])
        let coord = TrainingSessionCoordinator(
            dbFactory: Self.StubFactory(reader: Self.MetaSpyReader(candles: Self.validCandles(), meta: meta)),
            recordRepo: records, pendingRepo: pending,
            settingsDAO: InMemorySettingsDAO(),
            cache: cache, settings: SettingsStore(settingsDAO: Self.CapitalDAO(capital: capital)))
        let engine = try await coord.replay(recordId: srcId)
        return (coord, engine, records, pending)
    }

    @Test("replaySettlementPayload: 强平后终态 → in-memory TrainingRecord（原局 fees + meta）")
    func replaySettlementPayload_returnsTerminalStateRecord() async throws {
        let (coord, engine, _, _) = try await Self.makeReplaySession(capital: 100_000)
        _ = engine.buy(panel: .upper, tier: .tier1)      // replay 可交易；建非平凡终态
        engine.forceCloseManually()                       // 6a：强平 → 持仓平
        #expect(engine.position.shares == 0)
        let payload = try coord.replaySettlementPayload(engine: engine)
        #expect(payload.id == nil)                                       // 非持久（无 server id）
        #expect(payload.totalCapital == engine.initialCapital)          // D1 方案 A：起始资金
        #expect(payload.profit == engine.currentTotalCapital - engine.initialCapital)
        #expect(payload.returnRate == engine.returnRate)
        #expect(payload.feeSnapshot == engine.fees)                      // 原局 FeeSnapshot
        #expect(payload.stockCode == "600000")                          // 来自 reader.loadMeta()
        #expect(payload.stockName == "测试股")
        #expect(payload.finalTick == engine.tick.globalTickIndex)
        #expect(payload.buyCount == 1)                                  // 1 笔买入
        #expect(payload.sellCount == 1)                                 // forceCloseManually 的 1 笔强平卖出
    }

    @Test("replaySettlementPayload: 非持久化不变量 —— 不写 record、不触 pending，DB 不变")
    func replaySettlementPayload_doesNotPersist() async throws {
        let (coord, engine, records, pending) = try await Self.makeReplaySession()
        let recordsBefore = try records.listRecords(limit: nil).count   // = 1（仅 seed 的源 record）
        _ = engine.buy(panel: .upper, tier: .tier1)
        engine.forceCloseManually()
        _ = try coord.replaySettlementPayload(engine: engine)
        #expect(try records.listRecords(limit: nil).count == recordsBefore)   // 无新 insert
        #expect(try pending.loadPending() == nil)                             // pending 不动
        // finalize 对 replay 仍返 nil（持久化路径不变）
        #expect(try await coord.finalize(engine: engine) == nil)
        #expect(try records.listRecords(limit: nil).count == recordsBefore)   // finalize 也未插
    }

    @Test("replaySettlementPayload: 非 replay 模式 → throws（caller-contract 守卫）")
    func replaySettlementPayload_throwsInNonReplayMode() async throws {
        let (coord, _, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        let engine = try await coord.startNewNormalSession()   // .normal
        #expect(throws: AppError.self) {
            _ = try coord.replaySettlementPayload(engine: engine)
        }
    }

    @Test("replaySettlementPayload: 无活跃会话 / engine 身份不符 → throws")
    func replaySettlementPayload_throwsWithoutActiveSession() async throws {
        let (coord, engine, _, _) = try await Self.makeReplaySession()
        await coord.endSession()                               // 清活跃上下文
        #expect(throws: AppError.self) {
            _ = try coord.replaySettlementPayload(engine: engine)
        }
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter replaySettlementPayload 2>&1 | tail -20`
Expected: 编译失败 —— `value of type 'TrainingSessionCoordinator' has no member 'replaySettlementPayload'`。

- [ ] **Step 3: 实现 `replaySettlementPayload`（不改 finalize）**

在 `TrainingSessionCoordinator.swift` `finalize(...)` 方法（结束于 :233 `}`）**之后**插入：

```swift
    /// 非持久化 replay 结算 payload（RFC §4.4e）：replay 结束强平后，构造 in-memory `TrainingRecord`
    /// （复用类型）供顺位 8 SettlementView 呈现。**不持久化不变量**：不写 `training_records`、不触
    /// `pending_training`、不改 `finalize`（其对 replay 仍返 nil）。用**原局 FeeSnapshot**（replay 构造时
    /// 继承）+ 强平后终态。字段语义刻意镜像 `finalize`（D1 方案 A：totalCapital=起始资金；profit/收益率/
    /// 回撤比率/计数同口径），由 drift-guard 测试守；**有意不抽 finalize 共享 helper**，保 finalize 不在
    /// 本 PR diff 内（§4.7 finalize-gating residual 归顺位 10，不被本 PR 触碰）。
    /// 前置：replay 模式 + 活跃会话（caller=顺位 8 路由）。强平由 caller 先行（本方法只读终态）。
    public func replaySettlementPayload(engine: TrainingEngine) throws -> TrainingRecord {
        guard engine.flow.mode == .replay else {
            throw AppError.internalError(module: "E6b", detail: "replaySettlementPayload requires replay flow")
        }
        guard activeEngine === engine, let reader = activeReader, let file = activeFile else {
            throw AppError.internalError(module: "E6b", detail: "replaySettlementPayload without active session context")
        }
        let meta = try reader.loadMeta()
        let starting = engine.initialCapital
        let profit = engine.currentTotalCapital - starting
        let (year, month) = Self.startYearMonth(from: meta.startDatetime)
        return TrainingRecord(
            id: nil,
            trainingSetFilename: file.filename,
            createdAt: now(),
            stockCode: meta.stockCode,
            stockName: meta.stockName,
            startYear: year,
            startMonth: month,
            totalCapital: starting,
            profit: profit,
            returnRate: engine.returnRate,
            maxDrawdown: Self.drawdownRatio(absolute: engine.drawdown.maxDrawdown,
                                            peak: engine.drawdown.peakCapital),
            buyCount: engine.tradeOperations.filter { $0.direction == .buy }.count,
            sellCount: engine.tradeOperations.filter { $0.direction == .sell }.count,
            feeSnapshot: engine.fees,
            finalTick: engine.tick.globalTickIndex)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter replaySettlementPayload 2>&1 | tail -25`
Expected: PASS（4 个 `replaySettlementPayload*` 全 ✔，含 `_doesNotPersist`（records 计数不变 + pending nil + finalize 仍返 nil）+ 两守卫 throws，0 failures）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift
git commit -m "feat(6b): replaySettlementPayload 非持久化 replay 结算 payload（RFC §4.4e，不改 finalize）"
```

---

### Task 3: 验收清单文档

**Files:**
- Create: `docs/acceptance/2026-06-12-wave3-pr6b-engine-drawing-replay.md`

**约束：** 中文；action/expected/pass-fail 三段二元可决；禁用短语 `验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine`。`--filter` 大小写敏感正则——命中名须精确（per `feedback_acceptance_grep_anchoring`）。

- [ ] **Step 1: 写验收文档**

```markdown
# 验收清单 — Wave 3 顺位 6b：appendDrawing + replaySettlementPayload engine 契约

**交付物：** `engine.appendDrawing(_:)`（RFC §4.4c 画线投影单一真相，供顺位 4）+ `coordinator.replaySettlementPayload(engine:)`（RFC §4.4e 非持久化 replay 结算 payload，供顺位 8）。§4.4d zoom 经 user 2026-06-12 裁决移顺位 3，不在本 PR。纯逻辑层增量，无 UI/schema/render 文件改动；**未改 `finalize`**。

**前置：** 在 `ios/Contracts` 目录执行命令；macOS 装 Swift 6 工具链。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | `swift test --filter appendDrawing` | `Test run with 3 tests ... 0 failures`；`appendDrawingAddsToDrawings`、`appendDrawingAccumulatesInOrder`、`appendDrawing_flowsIntoPendingPersistence` 均 ✔ | `3 tests` 且 `0 failures` 且 3 名 ✔ = 通过；否则不通过 |
| 2 | `swift test --filter replaySettlementPayload` | `Test run with 4 tests ... 0 failures`；含 `_returnsTerminalStateRecord`、`_doesNotPersist`（records 计数不变 + pending nil + finalize 仍返 nil）、`_throwsInNonReplayMode`、`_throwsWithoutActiveSession` | `4 tests` 且 `0 failures` 且 4 名 ✔ = 通过；否则不通过 |
| 3 | `swift test`（全量回归） | `Test run with N tests`，`N ≥ 828`（基线 821 + 新增 7），`0 failures` | `0 failures` = 通过；≥1 failure = 不通过 |
| 4 | 阅读 `git diff origin/main -- ios/Contracts/Sources` | 仅 `TrainingEngine.swift`（+`appendDrawing`）与 `TrainingSessionCoordinator.swift`（+`replaySettlementPayload`）被改；无 `.sql`/schema/`CONTRACT_VERSION` 改动；**`finalize` 方法体零改动**；无 `RenderStateBuilder`/`makeViewport`/`PanelViewState` 改动（zoom 在顺位 3） | 改动文件集 ⊆ {TrainingEngine.swift, TrainingSessionCoordinator.swift} 且 finalize 未改 且无 render/schema 改动 = 通过；否则不通过 |
| 5 | Mac Catalyst CI（PR 上 `Mac Catalyst build-for-testing on macos-15`） | required check 状态 = success | check = success = 通过；failure = 不通过 |
```

- [ ] **Step 2: Commit**

```bash
git add docs/acceptance/2026-06-12-wave3-pr6b-engine-drawing-replay.md
git commit -m "docs(6b): 验收清单（appendDrawing + replaySettlementPayload）"
```

---

## Self-Review

**1. Spec coverage（RFC §4.4c + §4.4e）：**
- §4.4c appendDrawing：追加进 `engine.drawings`（唯一真相）✓；`@Observable` 重渲染（镜像 deleteDrawing 无显式 revision）✓；进入持久化路径 ✓（`appendDrawing_flowsIntoPendingPersistence` 经 saveProgress→pending.drawings）；累加/顺序 ✓。
- §4.4e replaySettlementPayload：原局 FeeSnapshot ✓；强平后终态（buy+forceCloseManually）✓；复用 `TrainingRecord` ✓（shape 决策）；**不持久化不变量**（不写 record + 不触 pending + finalize 仍返 nil）✓（`_doesNotPersist`）；replay-mode + active-session 守卫 ✓。
- §4.4d zoom：**移顺位 3**（user 2026-06-12，§Scope 决策）；本 PR 不实现、不碰 render 文件 ✓（验收 #4 守护）。
- 不改 finalize（§4.7 residual 不重开）✓（D1 + 验收 #4）；无 schema/version bump ✓。

**2. Placeholder scan：** 无 TBD/TODO；每 code step 给完整代码 + 数值。✓

**3. Type consistency：** `appendDrawing(_ drawing: DrawingObject)`（public，无返回）/ `replaySettlementPayload(engine: TrainingEngine) throws -> TrainingRecord`（public，sync throws）—— 全文一致。`DrawingObject`/`DrawingAnchor`/`TrainingRecord`/`FeeSnapshot`/`TrainingSetMeta`/`Self.startYearMonth`/`Self.drawdownRatio`/`MetaSpyReader`/`StubFactory`/`InMemoryRecordRepository.listRecords`/`InMemoryPendingTrainingRepository.loadPending` 签名均取自现有代码。✓

---

## 评审策略（Task 0 / 用户要求）

- 实施前：本 plan 走 **codex `codex:adversarial-review`** 到收敛（plan-stage）。
- 实施后：**严格 per-task** subagent-driven（修 6a 偏差：每 Task 独立 implementer + spec review + quality review）→ verification → requesting-code-review → 整体 codex branch-diff 到收敛。
- codex 周配额耗尽 → opus 4.8 xhigh fallback；token 限额恢复后第一时间续；API/网络问题持续重试至恢复。
- 越界 residual / permanent-bias → escalate user（不臆造越界范围；§Scope 决策已把 §4.4d 移出）。
- 本 PR 触 Catalyst required check（`.swift` 改动），不绕过。
```
