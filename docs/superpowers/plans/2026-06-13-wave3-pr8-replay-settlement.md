# Wave 3 顺位 8：Replay 结算窗（UI/routing-only）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 replay 局结束（手动「结束本局」或 auto 抵 maxTick）触发**忠实的非持久化结算窗**——消费顺位 6b 已冻结的 `coordinator.replaySettlementPayload(engine:)` payload，经 AppRouter 呈现既有 `SettlementView`，确认后路由回首页；全程**不写 `training_records`、不触 `pending_training`、不改 `finalize`**。

**Architecture:** 纯接线/路由锚（RFC §4.5「顺位 8 UI/routing-only，不自改 E5/E6 契约」）。三层既有抽象全部已就绪：(1) engine/coordinator payload 由顺位 6b（PR #97）`replaySettlementPayload(engine:) throws -> TrainingRecord` 提供（in-memory、非持久、原局 FeeSnapshot）；(2) `SettlementView(record:onConfirm:)` 自 Wave 1 U3 起即为泛型；(3) `AppRouter.Modal.settlement(TrainingRecord)` + `confirmSettlement()` 自 Wave 2 顺位 11 起即存。本锚只补「replay 结束 → 取 payload → 设 `.settlement` modal」这条投影路径，并把它接进 `TrainingView` 薄壳（新增 `onReplaySettlement` 回调，按 `flow.mode == .replay` 在结束路由处分流）。Normal/Review 路径**字节不变**（surgical）。

**Tech Stack:** Swift 6 / Swift Testing（`@Test`/`#expect`/`#require`）/ SwiftUI（`AppRootView`/`TrainingView` 薄壳，`#if canImport(UIKit)`，Catalyst build-for-testing 闸门）/ `ios/Contracts` SwiftPM 包。

---

## 背景与冻结上游（实施者须先读）

- **冻结契约**：RFC `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md`
  - §4.4e（L157-166）：`replaySettlementPayload` 来源 + **非持久化不变量**（不写 record / 不触 pending / `finalize` 对 replay 仍返 nil）+ 原局 FeeSnapshot。
  - §4.5（L168-173）：顺位 8 消费契约——`replay 结束 → 强平 → in-memory payload → SettlementView 呈现（total_capital/收益率/回撤，§4.2 结算口径）→ 确认路由回首页`；FeeSnapshot=原局；**不保存 record、不计入统计、pending 不动**；**顺位 8 不自改 E5/E6 契约**。
- **已交付 engine 支持（PR #97 6b，已冻结）**：`TrainingSessionCoordinator.replaySettlementPayload(engine:) throws -> TrainingRecord`（`ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift:262-290`）。注释明确「**强平由 caller 先行（本方法只读终态）**」，前置 = replay 模式 + 活跃会话（否则抛 `.internalError`）。`TrainingSessionCoordinator` 是 `@MainActor public final class`，本方法 `throws`（**非 async**）。
- **强平机制（已就绪，本锚不改）**：
  - **manual**：`engine.forceCloseManually()`（`TrainingEngine.swift:453`，replay 因 `canBuySell()==true` 可达）。`TrainingView.endManually()` 已在 routeFinalize 前调用它。
  - **auto maxTick**：步进经 `advanceAndAccount → forceCloseIfEnded()`（`TrainingEngine.swift:369/440`）已自动强平。
- **当前 replay 结束行为（待改）**：`TrainingView.runFinalize()` 对 replay 调 `finalizeForSettlement()` 返 `nil` → `onSessionEnded(nil)` → `AppRouter.sessionEnded(recordId: nil)` 的 replay 分支 = **retreat 回家，无结算窗**（`AppRouter.swift` `sessionEnded` else 分支；pr7 runbook step 9 实证）。
- **既有可复用件**：
  - `SettlementView(record: TrainingRecord, onConfirm: @escaping () -> Void)`（`UI/SettlementView.swift`）。
  - `AppRouter.Modal.settlement(TrainingRecord)` + `confirmSettlement()`（`App/AppRouter.swift`）：`confirmSettlement` = `endAfterSettlement()`（仅 `endSession` 关 reader+清活跃，**无持久化**）+ `activeModal=nil` + `activeTraining=nil` + `loadHome()`。对 replay 语义正确（replay 从未写 pending，endSession 不触 pending）。
  - `AppRootView` 的 `.sheet(item: $router.activeModal)` 已含 `.settlement` case 渲染 `SettlementView`。

## 设计决策（实施者不得偏离；偏离须经 plan-review）

- **D1 — 投影路径走 AppRouter（非 TrainingView 自呈现）**：replay 结算窗经 `AppRouter` 的新方法 `presentReplaySettlement(record:)` 设 `.settlement` modal，与 Normal 走 `sessionEnded(id) → .settlement` 同一 modal 基础设施 + 同一 `confirmSettlement()` 收口。**理由**：RFC §4.5「SettlementView 呈现 + 路由」——路由归 AppRouter（Wave 2 顺位 11 owns 全部 modal）；不在薄壳重复一套 sheet。
- **D2 — in-memory record 经新回调上交（不复用 `onSessionEnded: (Int64?)`）**：replay payload 是 `id == nil` 的非持久 `TrainingRecord`，无法走 `Int64?` 通道。新增 `TrainingView.onReplaySettlement: (TrainingRecord) -> Void`（additive，Normal 的 `onSessionEnded` 通道字节不变）。
- **D3 — 结束路由分流在薄壳，meaty 逻辑在 host-tested 层**：`TrainingView`（`#if canImport(UIKit)` 薄壳，不 host 测，Catalyst 编译闸门）只做一处 `engine.flow.mode == .replay` 分流（与既有 `showsTradeButtons = engine.flow.canBuySell()` 同范式，读 flow capability）。payload 取得（`lifecycle.replaySettlementRecord()`）+ modal 设置（`AppRouter.presentReplaySettlement`）+ 非持久化不变量均落 host-tested 层（lifecycle/AppRouter）。
- **D4 — `replaySettlementRecord()` 纯转发，不在内部强平**：与 Normal 对称（Normal 的 `endManually` 在壳层强平、`finalize` 只读终态）。强平由 caller（壳层 manual `forceCloseManually()` / auto 步进）先行，契合 6b 注释「强平由 caller 先行」。
- **D5 — Review 不可达本路径**：`shouldAutoFinalize` 对 Review 为 false（`shouldShowSettlement()==false`）；`forceCloseManually()` 对 Review 返 false（`canBuySell()==false`）→ `endManually` guard 拦截。故 `routeEndOfSession` 仅见 Normal/Replay，`else` 分支恒为 Normal，无需显式处理 Review。
- **D6 — 防御性 catch → retreat**：`replaySettlementRecord()` 在「replay + 活跃会话」下不抛（caller 已保证）；壳层 catch 仅作不可达兜底，走 `onSessionEnded(nil)`（既有 AppRouter replay-nil retreat 分支，不入账）。
- **D7 — 既有 `AppRouter.sessionEnded` replay-nil 分支语义降级为「防御性」**：顺位 8 后生产 replay 结束不再经 `onSessionEnded(nil)`（改经 `onReplaySettlement`）。该分支 + 其两个测试（`sessionEnded_replayRetreat`/`sessionEnded_replayTearsDownReader`）保留作 D6 防御路径覆盖；**仅刷新 stale 注释**，不删测试、不改 AppRouter `sessionEnded` 行为（surgical）。
- **D8 — swipe-dismiss 边界 = 既有、不在 scope**：`.sheet(item:)` 被下滑关闭会留 `activeTraining`+reader（未 confirm）。此为 Normal 结算窗**既有**行为（顺位 8 未引入），对 replay 等价；不在本锚 scope（属顺位 10/独立治理）。runbook 仅验 confirm 正常路径。

## File Structure

| 文件 | 责任 | 改动类型 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift` | 平台无关接线层（host 全测）。新增 `replaySettlementRecord() throws -> TrainingRecord` 转发 coordinator。 | Modify（+1 方法 ~6 行） |
| `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift` | 路由状态机（host 全测）。新增 `presentReplaySettlement(record:)` 设 `.settlement` modal；刷新 `sessionEnded` replay-nil 注释（D7）。 | Modify（+1 方法 ~4 行 + 注释） |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | U2 SwiftUI 薄壳（Catalyst 闸门，不 host 测）。新增 `onReplaySettlement` 回调 + `routeEndOfSession()` 分流，改 `endManually`/`maybeAutoEnd` 调用点。 | Modify（+回调 + 1 方法 ~10 行 + 2 改行 + #Preview） |
| `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift` | 生产根视图薄壳。接线 `onReplaySettlement → router.presentReplaySettlement`。 | Modify（+1 行） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingSessionLifecycleTests.swift` | lifecycle host 测。+2 测试（replay 返 payload / normal 抛）。 | Modify（+2 @Test） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift` | AppRouter host 测。+2 测试（present 设 modal+不持久 / confirm teardown+不持久）；刷新 2 既有 replay 测试注释（D7）。 | Modify（+2 @Test + 注释） |
| `docs/acceptance/2026-06-13-wave3-pr8-replay-settlement.md` | 非-coder 可执行验收清单（中文）。 | Create |
| `docs/runbooks/2026-06-13-wave3-pr8-replay-settlement-runtime-acceptance.md` | replay 结算窗运行时验收 runbook（顺位 13 阻塞依赖）。 | Create |

**预估 prod 改动**：4 文件、净增 ~25 行（远 < 500 行门）。无新文件 prod 代码、无 schema/CONTRACT_VERSION/render/engine 契约改动。

---

## Task 1：Lifecycle `replaySettlementRecord()`（host-tested）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingSessionLifecycleTests.swift`

- [ ] **Step 1：写失败测试**

在 `TrainingSessionLifecycleTests.swift` 末尾（最后一个 `}` 之前，即 struct 内）追加：

```swift
    // MARK: - Wave 3 顺位 8：replaySettlementRecord（RFC §4.4e/§4.5 非持久 replay 结算 payload 转发）

    @Test("replaySettlementRecord: Replay 交易+强平后 → 非持久 payload（id nil + totalCapital=起始资金 + profit 直通 + 原局 fees）")
    func replaySettlementRecord_replay_returnsPayload() async throws {
        let (coord, records, _, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records, total: 80_000)
        let engine = try await coord.replay(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        _ = engine.buy(panel: .upper, tier: .tier1)       // 建非平凡终态（replay 可交易）
        engine.forceCloseManually()                       // 强平须 caller 先行（D4）→ 持仓平
        #expect(engine.position.shares == 0)
        let payload = try life.replaySettlementRecord()
        #expect(payload.id == nil)                        // 非持久（无 server id）
        #expect(payload.totalCapital == engine.initialCapital)   // D1 方案 A：起始资金
        #expect(payload.profit == engine.currentTotalCapital - engine.initialCapital)   // 终态收益直通
        #expect(payload.feeSnapshot == engine.fees)       // 原局 FeeSnapshot
    }

    @Test("replaySettlementRecord: Normal → throws（非 replay 守卫，转发 coordinator caller-contract）")
    func replaySettlementRecord_normal_throws() async throws {
        let (coord, _, _, _) = H.makeCoordinator(candles: H.validCandles())
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(throws: AppError.self) { _ = try life.replaySettlementRecord() }
    }
```

- [ ] **Step 2：运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter replaySettlementRecord`
Expected: 编译失败 `value of type 'TrainingSessionLifecycle' has no member 'replaySettlementRecord'`。

- [ ] **Step 3：实现 lifecycle 方法**

在 `TrainingSessionLifecycle.swift` 的 `endAfterSettlement()` 方法之后（struct 闭合 `}` 之前）插入：

```swift
    /// 顺位 8（RFC §4.4e/§4.5）：replay 结束的**非持久化**结算 payload。转发 frozen
    /// `coordinator.replaySettlementPayload`（只读终态 in-memory `TrainingRecord`；不写 `training_records`、
    /// 不触 `pending_training`、`finalize` 对 replay 仍返 nil）。**强平须 caller 先行**（壳层 manual
    /// `forceCloseManually` / auto maxTick 步进已强平，同 `finalizeForSettlement` 的终态前提）。
    /// 仅 replay + 活跃会话合法；否则 coordinator 抛 `.internalError`（caller 守卫）。
    public func replaySettlementRecord() throws -> TrainingRecord {
        try coordinator.replaySettlementPayload(engine: engine)
    }
```

- [ ] **Step 4：运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter replaySettlementRecord`
Expected: `Test run with 2 tests ... 0 failures`；`replaySettlementRecord_replay_returnsPayload`、`replaySettlementRecord_normal_throws` 均 ✔。

- [ ] **Step 5：提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingSessionLifecycleTests.swift
git commit -m "feat(pr8): lifecycle.replaySettlementRecord 转发 6b replay-settlement payload（RFC §4.4e/§4.5）"
```

---

## Task 2：AppRouter `presentReplaySettlement(record:)`（host-tested）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift`

- [ ] **Step 1：写失败测试**

在 `AppRouterTests.swift` 的 `confirmSettlement_clears` 测试之后（struct 闭合 `}` 之前）追加：

```swift
    // MARK: - Wave 3 顺位 8：replay 结算窗（present 设 .settlement modal + 非持久化不变量）

    @Test("presentReplaySettlement: 设 .settlement(in-memory record) modal 且不持久化（records/pending 不变）")
    func presentReplaySettlement_showsModalNoPersist() async throws {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])   // [C2] insert-order id=1
        await f.router.replay(id: 1)                                  // activeTraining = replay，reader 开
        #expect(f.router.activeTraining?.lifecycle.engine.flow.mode == .replay)
        let recordsBefore = try f.records.listRecords(limit: nil).count   // = 1（仅 seed 源 record）
        let life = try #require(f.router.activeTraining?.lifecycle)
        let payload = try life.replaySettlementRecord()               // id==nil 非持久 payload
        f.router.presentReplaySettlement(record: payload)
        if case .settlement(let r)? = f.router.activeModal { #expect(r.id == nil) }
        else { Issue.record("expected .settlement") }
        #expect(try f.records.listRecords(limit: nil).count == recordsBefore)   // 不写 record
        #expect(try f.pending.loadPending() == nil)                            // 不触 pending
    }

    @Test("replay 结算 confirm → teardown reader + activeTraining/modal nil + 仍不持久化")
    func presentReplaySettlement_confirmTearsDown() async throws {
        let f = Self.makeRouter(seedRecords: [Self.record(id: 1)])
        await f.router.replay(id: 1)
        #expect(f.coordinator.activeReader != nil)
        let life = try #require(f.router.activeTraining?.lifecycle)
        f.router.presentReplaySettlement(record: try life.replaySettlementRecord())
        let before = try f.records.listRecords(limit: nil).count
        await f.router.confirmSettlement()
        #expect(f.router.activeTraining == nil)
        #expect(f.router.activeModal == nil)
        #expect(f.coordinator.activeReader == nil)                    // endAfterSettlement→endSession 关 reader
        #expect(try f.records.listRecords(limit: nil).count == before)   // confirm 不持久化
        #expect(try f.pending.loadPending() == nil)
    }
```

- [ ] **Step 2：运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter presentReplaySettlement`
Expected: 编译失败 `value of type 'AppRouter' has no member 'presentReplaySettlement'`。

- [ ] **Step 3：实现 AppRouter 方法**

在 `AppRouter.swift` 的 `confirmSettlement()` 方法之后插入：

```swift
    /// 顺位 8（RFC §4.5）：replay 结束的**非持久化**结算窗。caller（TrainingView）已强平 + 经
    /// `lifecycle.replaySettlementRecord()` 取 in-memory payload（`coordinator.replaySettlementPayload`，
    /// 不写 record / 不触 pending）→ 此处仅设 `.settlement` modal。确认复用 `confirmSettlement()`
    /// （`endAfterSettlement`→`endSession` 关 reader，无持久化）。replay 不计入统计、pending 不动。
    public func presentReplaySettlement(record: TrainingRecord) {
        activeModal = .settlement(record)
    }
```

- [ ] **Step 4：运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter presentReplaySettlement`
Expected: `Test run with 2 tests ... 0 failures`；两测试均 ✔。

- [ ] **Step 5：刷新 stale 注释（D7）**

在 `AppRouter.swift` 的 `sessionEnded(recordId:)` 的 `else`（`recordId==nil`）分支，把原注释行：

```swift
            // recordId==nil：replay 结束（retreat）正常路径。normal finalize 失败自 Wave 3 10a 起
            // 不再走此路径（TrainingView 失败保留 + 重试/放弃，§4.7a）；normal-nil 分支保留作防御性守卫，
```

替换为：

```swift
            // recordId==nil：防御性兜底分支。自 Wave 3 顺位 8 起，**replay 结束改经 onReplaySettlement →
            // presentReplaySettlement 走结算窗**（RFC §4.5），不再经此 nil 路径；replay-nil 仅在
            // TrainingView.routeEndOfSession 的不可达 catch 兜底时到达。normal finalize 失败自 Wave 3 10a 起
            // 亦不再走此路径（TrainingView 失败保留 + 重试/放弃，§4.7a）；两者均保留作防御性守卫，
```

在 `AppRouterTests.swift` 把 `sessionEnded_replayRetreat` 与 `sessionEnded_replayTearsDownReader` 两测试的 `@Test("...")` 描述各加前缀 `[D7 防御路径] `（覆盖顺位 8 后的不可达 catch 兜底，非生产正常路径），仅改描述串，不改断言。例如：

```swift
    @Test("[D7 防御路径] sessionEnded replay nil → retreat：activeTraining nil 且无 settlement")
```
```swift
    @Test("[D7 防御路径] teardown：replay nil 兜底后 coordinator.activeReader == nil（endAfterSettlement→endSession）")
```

- [ ] **Step 6：运行回归确认两既有测试仍绿**

Run: `cd ios/Contracts && swift test --filter AppRouter`
Expected: 全部 AppRouter 测试 `0 failures`（含刷新描述的 2 既有 + 新增 2）。

- [ ] **Step 7：提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/AppRouterTests.swift
git commit -m "feat(pr8): AppRouter.presentReplaySettlement 设 .settlement modal + 非持久不变量测试（RFC §4.5）"
```

---

## Task 3：TrainingView 薄壳分流 + AppRootView 接线（Catalyst 闸门）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift`

> **本 Task 为 `#if canImport(UIKit)` 薄壳，不 host 测**（与既有 `TrainingView`/`AppRootView` 一致，D10 决议）。验证 = 本地 Mac Catalyst build-for-testing 成功 + CI Catalyst required check + 运行时 runbook（Task 4）。

- [ ] **Step 1：TrainingView 加 `onReplaySettlement` 回调**

在 `TrainingView` 的属性区，`private let onSessionEnded: (Int64?) -> Void` 之后加：

```swift
    private let onReplaySettlement: (TrainingRecord) -> Void
```

把 `init` 改为（加第 4 参 + 赋值）：

```swift
    public init(lifecycle: TrainingSessionLifecycle,
                onExit: @escaping () -> Void,
                onSessionEnded: @escaping (Int64?) -> Void,
                onReplaySettlement: @escaping (TrainingRecord) -> Void) {
        self.lifecycle = lifecycle
        self.onExit = onExit
        self.onSessionEnded = onSessionEnded
        self.onReplaySettlement = onReplaySettlement
    }
```

- [ ] **Step 2：加 `routeEndOfSession()` 分流并改两调用点**

把 `endManually()` 末行 `runFinalize()` 改为 `routeEndOfSession()`：

```swift
    private func endManually() {
        guard !didFinalize else { return }
        guard engine.forceCloseManually() else { return }
        didFinalize = true
        routeEndOfSession()
    }
```

把 `maybeAutoEnd()` 末行 `runFinalize()` 改为 `routeEndOfSession()`：

```swift
    private func maybeAutoEnd() {
        guard lifecycle.shouldAutoFinalize(didFinalize: didFinalize) else { return }
        didFinalize = true
        routeEndOfSession()
    }
```

在 `runFinalize()` 之后插入分流方法：

```swift
    // 顺位 8（RFC §4.5）：结束路由分流。Replay → 非持久结算窗（取 in-memory payload 经 onReplaySettlement
    // 上交 AppRouter）；Normal → 入账（runFinalize，字节不变）。Review 不可达此方法
    // （shouldAutoFinalize 抑制 + forceCloseManually 对 Review 返 false），故 else 恒为 Normal。
    // 读 engine.flow.mode 与既有 showsTradeButtons=canBuySell() 同范式（壳层 flow-capability 分流）。
    private func routeEndOfSession() {
        guard engine.flow.mode == .replay else { runFinalize(); return }
        do {
            let record = try lifecycle.replaySettlementRecord()   // 强平已由上面 caller 先行（D4）
            onReplaySettlement(record)
        } catch {
            // 不可达（replay + 活跃会话已保证）；防御性 retreat（不入账，走 AppRouter replay-nil 兜底）
            onSessionEnded(nil)
        }
    }
```

- [ ] **Step 3：更新 #Preview**

把文件底部 `#if DEBUG` 区的 `#Preview` 调用补第 4 参：

```swift
#Preview {
    TrainingView(
        lifecycle: TrainingSessionLifecycle(engine: .preview(), coordinator: .preview()),
        onExit: {},
        onSessionEnded: { _ in },
        onReplaySettlement: { _ in })
}
```

- [ ] **Step 4：AppRootView 接线新回调**

在 `AppRootView.swift` 的 `TrainingView(...)` 构造处，把：

```swift
                        TrainingView(lifecycle: t.lifecycle,
                                     onExit: { Task { await router.exitTraining() } },
                                     onSessionEnded: { id in Task { await router.sessionEnded(recordId: id) } })
```

改为：

```swift
                        TrainingView(lifecycle: t.lifecycle,
                                     onExit: { Task { await router.exitTraining() } },
                                     onSessionEnded: { id in Task { await router.sessionEnded(recordId: id) } },
                                     onReplaySettlement: { record in router.presentReplaySettlement(record: record) })
```

- [ ] **Step 5：本地 Mac Catalyst build-for-testing 验证**（per `feedback_swift_local_toolchain_blindspot`：本地编译验薄壳，CI macos-15 终审）

Run:
```bash
xcodebuild build-for-testing \
  -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/pr8-catalyst 2>&1 | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **`（薄壳新回调 + 分流编译链接通过）。

> 若本机无 xcodebuild Catalyst 目标，至少 `swift build` 验 Sources 编译；薄壳 `#if canImport(UIKit)` 在纯 host swift build 下被跳过，故 Catalyst 编译为权威闸门——CI required check 终审。

- [ ] **Step 6：全量 host 回归（确认薄壳改动未破坏 host 编译/测试）**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `Test run with N tests ... 0 failures`，`N == 917 + 4 == 921`（baseline 917 + Task1/2 共 4 新测试）。

- [ ] **Step 7：提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift \
        ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift
git commit -m "feat(pr8): TrainingView replay 结束分流 onReplaySettlement + AppRootView 接线（RFC §4.5）"
```

---

## Task 4：验收清单 + 运行时 runbook

**Files:**
- Create: `docs/acceptance/2026-06-13-wave3-pr8-replay-settlement.md`
- Create: `docs/runbooks/2026-06-13-wave3-pr8-replay-settlement-runtime-acceptance.md`

- [ ] **Step 1：写非-coder 验收清单**

创建 `docs/acceptance/2026-06-13-wave3-pr8-replay-settlement.md`：

```markdown
# 验收清单 — Wave 3 顺位 8：Replay 结算窗（UI/routing-only）

**交付物：** replay 局结束（手动「结束本局」或 auto 抵 maxTick）触发**非持久化**结算窗：消费顺位 6b 冻结的 `coordinator.replaySettlementPayload`，经 `AppRouter.presentReplaySettlement` 设 `.settlement` modal → `SettlementView` 呈现 → 确认路由回首页。**不写 `training_records`、不触 `pending_training`、不改 `finalize`、不自改 E5/E6 契约**（RFC §4.4e/§4.5）。

**前置：** 在 `ios/Contracts` 目录执行命令；macOS 装 Swift 6 工具链。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | `swift test --filter replaySettlementRecord` | `Test run with 2 tests ... 0 failures`；`replaySettlementRecord_replay_returnsPayload`、`replaySettlementRecord_normal_throws` 均 ✔ | 2 tests 且 0 failures 且 2 名 ✔ = 通过 |
| 2 | `swift test --filter presentReplaySettlement` | `Test run with 2 tests ... 0 failures`；`presentReplaySettlement_showsModalNoPersist`（modal=.settlement + records/pending 不变）、`presentReplaySettlement_confirmTearsDown`（confirm 后 reader 关 + nil + 不持久）均 ✔ | 2 tests 且 0 failures 且 2 名 ✔ = 通过 |
| 3 | `swift test`（全量回归） | `Test run with N tests`，`N == 921`（baseline 917 + 新增 4），`0 failures` | N==921 且 0 failures = 通过 |
| 4 | 阅读 `git diff origin/main -- ios/Contracts/Sources` | 仅改 `TrainingSessionLifecycle.swift`（+`replaySettlementRecord`）、`AppRouter.swift`（+`presentReplaySettlement`+注释）、`TrainingView.swift`（+`onReplaySettlement`+`routeEndOfSession`）、`AppRootView.swift`（+接线 1 行）；**无 `.sql`/schema/`CONTRACT_VERSION` 改动**；**`finalize`/`replaySettlementPayload` 方法体零改动**；无 `TrainingEngine`/render 改动 | 改动文件集 ⊆ {上述 4} 且 finalize/payload 未改 且无 schema/engine 改动 = 通过 |
| 5 | 阅读 `AppRouter.presentReplaySettlement` 方法体 | 仅 `activeModal = .settlement(record)` 一行（不调 insertRecord/savePending/finalize） | 方法体仅设 modal = 通过 |
| 6 | Mac Catalyst CI（PR 上 `Mac Catalyst build-for-testing on macos-15`） | required check 状态 = success | check = success = 通过 |
| 7 | 运行时验收 runbook `docs/runbooks/2026-06-13-wave3-pr8-replay-settlement-runtime-acceptance.md` 存在且含 replay 结算窗 + 不入账断言 | 文件在 PR 文件列表，含「不入账/统计不变」断言项 | 存在且含该断言 = 通过 |

**说明（非破坏性核实）：** 本锚为 UI/routing-only，engine/coordinator payload 逻辑由顺位 6b（PR #97）交付并冻结，本锚不复制不修改其逻辑；非持久化不变量在 6b 已有 `replaySettlementPayload_doesNotPersist` 覆盖，本锚补 router 层 present→confirm 全路径不持久断言（step 2）。
```

- [ ] **Step 2：写运行时 runbook**

创建 `docs/runbooks/2026-06-13-wave3-pr8-replay-settlement-runtime-acceptance.md`：

```markdown
# Wave 3 顺位 8 — Replay 结算窗运行时验收 runbook

**性质**：device/simulator **手动**验收（CI 仅 Catalyst 编译守护，不验运行时路由/呈现/持久化副作用）。
执行者：user（操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：经顺位 10 全 app fixture provisioning（若未落地则用已有缓存训练组 + 已有一条历史记录），
> 在 iPhone/iPad 启动 `KlineTrainer` app target；从首页对一条历史记录选「再来一次」进入一局 **Replay** 训练。
> 记录验收前先看首页：记录条数 + 胜率/总资金统计，作为「不入账」基线。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | Replay 局中点底部左侧「结束本局」→ 弹确认「结束本局训练」→ 点「否」 | 对话框消失；**仍在本局**（无强平、无结算、状态不变） | pass = 取消不路由 |
| 2 | 再点「结束本局」→「是」（有持仓） | 有持仓按当前收盘价强制平仓 → **弹结算窗**（显示 total_capital 冻结值 / 总收益率 / 最大回撤 / 买卖次数，§4.2 口径） | pass = 强平 + 结算窗弹出 |
| 3 | 结算窗点「确认」 | 结算窗关闭 → 回首页 | pass = 回首页 |
| 4 | 回首页后对比基线统计 | **记录条数不变 + 胜率/总资金统计不变**（replay 不入账、不计入统计，RFC §4.5） | pass = 统计完全不变 |
| 5 | 再进同一记录的 Replay，步进/持有直到 **auto 抵 maxTick**（不手动结束） | 抵末态自动强平 → **自动弹结算窗**（同 step 2 内容）→ 确认回首页 | pass = auto 末态也弹结算窗 |
| 6 | step 5 确认回首页后看统计 | 记录条数 + 统计仍**不变**（auto replay 同样不入账） | pass = 统计不变 |
| 7 | （对照）Normal 局结束 → 结算窗 → 确认 | 结算窗显示 + 确认后**记录条数 +1**（Normal 入账，与 replay 区分） | pass = Normal 入账（证 replay 非误抑制持久化） |

**回填**：执行后逐行填 pass/fail。本 runbook 作 Wave 3 新交互运行时矩阵一项，是顺位 13 收尾阻塞依赖之一（spec §三.3）。
核心运行时断言 = replay 结算窗呈现（step 2/5）+ **不入账/统计不变**（step 4/6，区别于 Normal step 7）。
```

- [ ] **Step 3：提交**

```bash
git add docs/acceptance/2026-06-13-wave3-pr8-replay-settlement.md \
        docs/runbooks/2026-06-13-wave3-pr8-replay-settlement-runtime-acceptance.md
git commit -m "docs(pr8): replay 结算窗验收清单 + 运行时 runbook"
```

---

## Self-Review（写完后核对）

**1. Spec 覆盖（RFC §4.4e/§4.5）：**
- `replay 结束 → 强平 → in-memory payload`：强平由 caller 先行（Task 3 endManually/maybeAutoEnd 既有强平），payload 经 `lifecycle.replaySettlementRecord()`（Task 1）。✓
- `SettlementView 呈现 + 路由`：`AppRouter.presentReplaySettlement` 设 `.settlement` modal（Task 2）→ `AppRootView` 既有 sheet 渲染 `SettlementView`（无需改）→ 接线 onReplaySettlement（Task 3）。✓
- `确认后路由回首页`：复用 `confirmSettlement()`（既有，Task 2 测试覆盖）。✓
- `不保存 record / 不计入统计 / pending 不动 / 不自改 E5/E6`：Task 2 测试断言 records/pending 不变 + `finalize`/`replaySettlementPayload`/engine 零改动（acceptance step 4/5）。✓
- `FeeSnapshot=原局`：由 6b payload 保证；Task 1 测试 `payload.feeSnapshot == engine.fees`。✓

**2. Placeholder 扫描：** 无 TBD/TODO；每 step 含完整代码或精确命令 + 预期输出。✓

**3. 类型一致性：**
- `replaySettlementRecord() throws -> TrainingRecord`（sync throws，因 coordinator `@MainActor` 类的 `replaySettlementPayload` 为 sync throws）——Task 1 定义、Task 2/3 调用、Task 1/2 测试均无 `await`。✓
- `presentReplaySettlement(record: TrainingRecord)`——Task 2 定义、Task 3 接线、Task 2 测试一致。✓
- `onReplaySettlement: (TrainingRecord) -> Void`——Task 3 init/属性/#Preview/AppRootView 一致。✓
- `engine.flow.mode == .replay`：`TrainingMode` 含 `.replay`（已核实 Models.swift:34）。✓
- `AppRouter.Modal.settlement(TrainingRecord)`：既有，`.id` 对 `record.id==nil` 产 `"settlement--1"`（单 modal 无碰撞）。✓

**4. 既有行为保护：** Normal 路径 `runFinalize()`/`onSessionEnded(id)` 字节不变（routeEndOfSession 的 else 分支调原 runFinalize）；Review 不可达；D7 仅刷新注释不改 `sessionEnded` 行为，既有 2 测试仍绿（Task 2 step 6 验证）。✓
