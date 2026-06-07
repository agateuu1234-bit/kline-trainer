# U2 TrainingView + E6 生命周期接线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付 Wave 2 顺位 9 —— 训练页 `TrainingView`（SwiftUI 薄壳，宿主双 `ChartContainerView` + 交易控件 + scenePhase 中继 + 返回/自动结束接线）与平台无关的 **E6 会话生命周期接线层** `TrainingSessionLifecycle`（host 全测 5 路径），并产出 C2/C7 手势仲裁的运行时验收 runbook。

**Architecture:** 沿用本仓「平台无关纯逻辑层（host swift test 真断言）+ 薄 SwiftUI 壳（Mac Catalyst build-for-testing SUCCEEDED 编译闸门）」双层架构（同 U3/U4/C8）。
- **`TrainingSessionLifecycle`**（host 测）：包裹已构造的 `engine` + `TrainingSessionCoordinator`，把 U2 的 UI 事件**串接**到 E6 的 `saveProgress`/`finalize`/`endSession`。这是 outline §四 L124 钉死的 U2 净 residual。**复用** E6b `TrainingSessionPersistenceTests` 既有的内存全栈 harness（`PreviewTrainingSetDBFactory(candles:)` + seed `InMemoryCacheManager` + InMemory repos）对**真实 coordinator** 验证——无 mock 类（守 modules L2110）。
- **`TrainingTopBarContent`**（host 测）：顶栏数值格式化纯值（总资金 / 持仓成本 / 收益率），同 `SettlementContent` 格式口径（POSIX `¥ ` 千分位 + 带符号百分比 + `-0.0` 归一）。
- **`TrainingView`**（`#if canImport(UIKit)` Catalyst 编译闸门）：组合上述两层 + 既有 `ChartContainerView`（C8）/ `PositionPickerView`（U5）。因嵌 UIKit-only 的 `ChartContainerView`，本壳与 `ChartContainerView` 同门 `#if canImport(UIKit)`（host swift test 不编译，Catalyst 编译）。

**Tech Stack:** Swift 6.3 / SwiftUI / Swift Testing (`@Test`/`#expect`) / SwiftPM `KlineTrainerContracts` target / Mac Catalyst build-for-testing CI 闸门。

---

## Task 0：§15.3 评审策略前置（boilerplate）

**评审通道决议（沿用近邻 PR #84/#86/#87 既定）**：本 PR 走 **opus 4.8 xhigh 双闸门对抗性 review 到收敛**（plan-stage + branch-diff post-impl），非 codex —— 理由：(a) user 本 session 显式指令「另一个 claude opus4.8 xhigh 做对抗性 review 到收敛」；(b) codex 周级配额近邻 PR 已多次耗尽走 opus fallback（per `project_pr86_e6b_merged`）。CLAUDE.md backstop「PR 经 codex:adversarial-review」由 **opus 4.8 xhigh 等价对抗性双闸门 + user TTY attest-override / `--admin`** 满足（per 既往 ledger 先例 PR #62/#65/#84/#86/#87）。

**phase_delivery**：true（1 plan = 1 phase）。acceptance = UI/feature + 生命周期机制验证。

**trust-boundary 触点**：本 PR 新增 `ios/**/*.swift` + `docs/superpowers/plans/**` —— **二者均属 `trust_boundary_globs`**（`.claude/workflow-rules.json`），故**需对抗性 review**（本 PR 由 opus 4.8 xhigh 双闸门满足）。但**不**触 `.github`/`.claude`/schema/`openapi`/CODEOWNERS（`codeowners_required_globs`），亦不改冻结契约文件（modules/plan spec、frozen E5/E6/U3）—— 故无需 user Approve gate，走标准对抗性 review 即可。

---

## 关键决策（D1–D12，opus xhigh 对抗审重点）

| # | 决策 | 理由 / 权威 |
|---|---|---|
| **D1** | **U2 `TrainingView` init 偏离 modules §U2 字面 `(engine:, onExit:)`，扩为 `(lifecycle:, onExit:, onSessionEnded:)`**。`lifecycle` 内含 `engine` + `coordinator`。 | modules §U2 代码块是**示意**（同 E4 教训「spec 示例 illustrative，矩阵权威」per `project_pr63_e4_merged`）；outline §四 L124 **权威**把「U2 接线 E6 saveProgress/finalize/endSession」钉为 U2 净 residual，接线必须持 coordinator。modules §U2 仅画 scenePhase 中继，未画生命周期，故扩签名由 L124 授权。 |
| **D2** | **U2 不呈现 `SettlementView`**；自动结束时 `TrainingView` 调 `lifecycle.finalizeForSettlement()` 得 `recordId?` 后**经注入回调 `onSessionEnded(_:)` 上交**，由顺位 11 组合根加载 record（Normal）/装配 engine 数据（Replay）并呈现结算窗。 | frozen E6（`TrainingSessionCoordinator`，PR #86 已 merged）**无** record-by-id / 活跃 meta 公共访问面；`finalize` 仅返 `Int64?`。结算窗须 stockName/code + 起始年月（plan v1.5 §6.3），来源于 `TrainingSetMeta`（reader 私有），engine 不携带。**在 U2 内呈现结算 = 要么破冻结 E6 加访问面（越界 governance），要么臆造 meta**。顺位 11 是路由+repo owner（outline §四 L122「HomeView 须路由到 TrainingView/SettingsPanel」），结算呈现+record 加载属其职责。U2 仿 U1「导航意图注入，组合根接线」（outline §52 L51）。**U2 仍完整交付 §124：lifecycle 接线全部三 E6 调用 + 5 路径 host 测**。 |
| **D3** | **返回（back）路径 = `saveProgress(engine)` 然后 `endSession()`**，对所有模式统一调用（review/replay 的 `saveProgress` 在 coordinator 内 `guard mode==.normal else return` no-op，**先于**活跃上下文守门，故不抛）。 | plan v1.5 §6.2.1 L920「点击返回：保存进度到 pending_training，返回首页」。coordinator `saveProgress` L176 对非 Normal 早返（PR #86）。统一调用使生命周期对称、review/replay 走「非保存分支」（§124）。 |
| **D4** | **自动结束检测 = `engine.tick.globalTickIndex >= engine.tick.maxTick`**，且仅对**可步进且应结算**模式触发（`mode != .review`）。Review `allowedTickRange = finalTick...finalTick`（固定末态，capability matrix L836「❌ 固定最终态」），`isAtEnd` 构造即真但**不**触发结算（Review 结算弹窗 ❌，L842；Review 只经返回退出，L837）。 | 局终强平由 engine 内部在步进到 maxTick 时完成（E6b 测试 L399 实证 `holdOrObserve` 步到 maxTick → 强平 shares=0）。U2 仅**检测**并调 `finalize`。`engine.tick` 为 `public private(set)`（TrainingEngine L20），`maxTick` public（TickEngine L6）。 |
| **D5** | **自动结算判定逻辑下放到 host-测 lifecycle**：`shouldAutoFinalize(didFinalize:) = isAtEnd && mode != .review && !didFinalize`（**纯函数，Task 1 host 测**）。`TrainingView` 的 `@State didFinalize` + `maybeAutoEnd()` 仅作壳触发器，决策逻辑全在被测纯层（plan-review H1：模式门 + 一次性门不得只活在不可测的 View 壳）。 | `finalize` 第二次调会因 record 已插/pending 已清而重复入账；幂等由一次性闸门保证。Review `allowedTickRange=finalTick...finalTick`（TrainingFlowController L64-65）→ `isAtEnd` 构造即真，**必须**靠 `mode != .review` 抑制误结算 → 该逻辑必须 host 测（killer：review-at-end→false / normal-at-end→true / normal-already-finalized→false / fresh→false）。 |
| **D13** | **结算时序相对 spec §6.2.5「先弹窗→确认后保存」反转为「检测即 finalize（save+clearPending）→ 上交 onSessionEnded → 顺位 11 呈现结算窗」**（plan-review M3）。 | frozen E6 `finalize`（PR #86 L230-231）**原子**插 record + 清 pending，无「先存不清/确认后清」拆分原语；拆分须破冻结 E6（越界）。反转良性：plan v1.5 §6.3 结算窗**仅「确认」无「取消」** → 不存在「取消结算回到进行中局」语义 → 「确认前 pending 已清」无副作用。Normal 经 recordId 让顺位 11 加载已存 record 呈现；Replay finalize 返 nil（无 record），顺位 11 据 engine 末态呈现（residual U2-R4）。 |
| **D6** | **手动「结束本局」按钮（plan v1.5 §6.2.2，含点「是」先强平）延后**，不在 U2 交付。 | §6.2.2 要求「若有持仓，先按最后收盘价**强制平仓**」，但 frozen E5 `TrainingEngine` 公共面**无**手动强平方法（强平仅在步进到 maxTick 时自动发生，TrainingEngine L5-6 注 + E6b 测 L399）。在 U2 实现手动强平须扩 E5（越界本 PR 冻结面）。outline §124 五路径矩阵（back/auto-end/settlement-confirm/review/replay）**不含**手动结束。residual **U2-R1**：手动结束按钮 + E5 `forceCloseAndEnd()` 归后续 PR / Wave 3。自动结束路径（§6.2.5）本 PR 交付。 |
| **D7** | **画线工具面板（plan v1.5 §6.2.6）延后**，不在 U2 交付（顶栏「画线」按钮 + 7 工具开关 + 锚点输入）。 | 画线**输入**（DrawingInputController / onTap 锚点）属 Wave 3（modules L2155 + C8b Coordinator 注 L90「onTap 画线锚点需 DrawingInputController（Wave 3）→ C8b 不接」）。无锚点输入则画线面板无功能。residual **U2-R2**：画线面板 + DrawingInputController 归 Wave 3。 |
| **D8** | **「仓位 X/5」顶栏字段延后**，顶栏交付总资金/持仓成本/收益率三项 + 返回按钮。 | `PositionManager` 公共面仅 `shares`/`holdingCost`（无「当前档位 X/5」存值）；项目**显式拒绝臆造 tier 推导公式**（E5b D1「功能式 ∃tier，无 tier 推导公式」，TrainingEngine L256-257 注）。强算 X/5 = 臆造公式，违既定立场。residual **U2-R3**：仓位档位显示待 tier 反推契约定义。 |
| **D9** | **交易按钮 `PositionPickerView` 全档启用 `Set(PositionTier.allCases)`**，点不可买档由 `engine.buy` 返 `.failure(.insufficientCash)` 兜（本 PR 壳忽略 failure，不 toast——toast UI 非 U2 scope）。买/卖按钮整体启用由 `engine.buyEnabled`/`sellEnabled` 控（`.disabled`）。 | plan v1.5 L735「点不可买的档由 buy 返 .insufficientCash（toast）——单一真值源，无 tier 公式臆造」（TrainingEngine L257-258 注）。避免在壳内重算 per-tier 启用 = 重复 engine ∃tier 逻辑。 |
| **D10** | **交易按钮仅 Normal/Replay 显示**，Review 隐藏（`engine.flow.mode != .review`）。持有/观察按钮文案随 `engine.position.shares > 0` 切「持有」/「观察」。 | capability matrix L833「买入/卖出/持有/观察按钮 Normal ✅ / Review ❌隐藏 / Replay ✅」；L944「有仓位显示『持有』图标，空仓显示『观察』图标」。 |
| **D11** | **`TrainingView` 加 `#if canImport(UIKit)` 平台门**；host swift test 不编译本壳，Catalyst build-for-testing 编译闸门守护。 | 本壳嵌 `ChartContainerView`（UIViewRepresentable，`#if canImport(UIKit)`，ChartContainerView.swift L12）；macOS host 无 UIKit → `ChartContainerView` 不存在 → 不门则 host 编译失败。同 C8 壳门策略。`TrainingSessionLifecycle`/`TrainingTopBarContent` **不**门（无 UIKit 依赖，host 全编译全测）。 |
| **D12** | **`TrainingSessionLifecycle` 为 `@MainActor struct`**（持引用型 `engine`/`coordinator`，无可变存储）；3 async 方法 + 1 计算属性。 | coordinator/engine 皆 `@MainActor`；struct 值语义无保留环。方法 `async`（coordinator 调用 async）。 |

---

## File Structure

| 文件 | 责任 | 平台门 | 测试 |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift` | E6 生命周期接线（back/finalizeForSettlement/endAfterSettlement/isAtEnd） | 无（host 编译） | host swift test |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift` | 顶栏三数值格式化纯值 | 无（host 编译） | host swift test |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | 训练页 SwiftUI 薄壳 | `#if canImport(UIKit)` | Catalyst build-for-testing 编译闸门 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingSessionLifecycleTests.swift` | 5 路径生命周期矩阵 | 无 | — |
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift` | 顶栏格式化 | 无 | — |
| `docs/runbooks/2026-06-07-u2-gesture-runtime-acceptance.md` | C2/C7 手势仲裁运行时验收（单/双指 + 长按） | — | 手动 |
| `docs/acceptance/2026-06-07-pr-u2-training-view.md` | 非编码者可执行验收清单（中文 action/expected/pass-fail） | — | 手动 |

---

## Task 1：`TrainingSessionLifecycle`（E6 生命周期接线，host 全测）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingSessionLifecycleTests.swift`

复用 `TrainingSessionPersistenceTests`（同测试 target，`@testable`）既有 static helper：`validCandles(m3Count:)` / `makeCoordinator(candles:capital:seedFile:)` / `CapitalDAO` / `cachedFile()`。这些是 `static` 方法，跨测试文件可 `TrainingSessionPersistenceTests.makeCoordinator(...)` 调用。

- [ ] **Step 1：写失败测试（5 路径矩阵 + isAtEnd）**

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingSessionLifecycle")
struct TrainingSessionLifecycleTests {

    typealias H = TrainingSessionPersistenceTests   // 复用 E6b 内存全栈 harness

    // 在 records 里插一条 review/replay 用的源记录，返回 id。
    static func seedRecord(_ records: InMemoryRecordRepository, total: Double = 100_000) throws -> Int64 {
        try records.insertRecord(
            TrainingRecord(id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
                           stockCode: "X", stockName: "X", startYear: 2020, startMonth: 1,
                           totalCapital: total, profit: 0, returnRate: 0, maxDrawdown: 0,
                           buyCount: 0, sellCount: 0,
                           feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false),
                           finalTick: 7),
            ops: [], drawings: [])
    }

    // 路径 1：back（Normal）→ 保存进度 + 结束会话
    @Test("back: Normal 局 → saveProgress 写 pending + endSession 清活跃")
    func back_normal_savesAndEnds() async throws {
        let (coord, _, pending) = H.makeCoordinator(candles: H.validCandles(), capital: 50_000)
        coord.now = { 111 }
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        try await life.back()
        #expect(try pending.loadPending() != nil)          // Normal：进度已存
        #expect(coord.activeEngine == nil)                  // 会话已结束
        #expect(coord.activeReader == nil)
    }

    // 路径 4（review back）：back（Review）→ saveProgress no-op + endSession
    @Test("back: Review 局 → 不写 pending（非保存分支）+ endSession")
    func back_review_noSaveButEnds() async throws {
        let (coord, records, pending) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records)
        let engine = try await coord.review(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        try await life.back()
        #expect(try pending.loadPending() == nil)           // 非保存分支
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)                  // L3：review 也开 reader，须断言清理
    }

    // 路径 5（replay back）：back（Replay）→ 不写 pending + endSession
    @Test("back: Replay 局 → 不写 pending（非保存分支）+ endSession")
    func back_replay_noSaveButEnds() async throws {
        let (coord, records, pending) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records, total: 80_000)
        let engine = try await coord.replay(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        try await life.back()
        #expect(try pending.loadPending() == nil)
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)                  // L3
    }

    // isAtEnd：fresh Normal（tick 0，maxTick 7）→ false
    @Test("isAtEnd: fresh Normal tick0 < maxTick → false")
    func isAtEnd_freshNormal_false() async throws {
        let (coord, _, _) = H.makeCoordinator(candles: H.validCandles())   // maxTick = 7
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.isAtEnd == false)
        #expect(engine.tick.maxTick == 7)
    }

    // isAtEnd + 路径 2（auto-end Normal）：resume 在 tick7==maxTick → isAtEnd true；finalize 入账 + 返 recordId + 清 pending
    @Test("auto-end: Normal 在 maxTick → isAtEnd true；finalizeForSettlement 入账返 id + 清 pending")
    func autoEnd_normal_finalizesAndReturnsId() async throws {
        let meta = TrainingSetMeta(stockCode: "600519", stockName: "贵州茅台",
                                   startDatetime: 1, endDatetime: 2)
        let (coord, records, pending, _) = try H.resumeCoordinator(meta: meta)   // 注入 tick7 deterministicPending
        coord.now = { 1_700_000_000 }
        let engine = try #require(try await coord.resumePending())               // tick 7 == maxTick
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.isAtEnd == true)
        let id = try #require(try await life.finalizeForSettlement())
        let (rec, _, _) = try records.loadRecordBundle(id: id)
        #expect(rec.finalTick == 7)
        #expect(try pending.loadPending() == nil)                                // pending 已清
    }

    // 路径 4（review auto）：review finalize → nil（非保存分支，不入账）
    @Test("auto-end: Review → finalizeForSettlement 返 nil，不入账")
    func autoEnd_review_returnsNil() async throws {
        let (coord, records, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records)
        let before = try records.listRecords(limit: nil).count
        let engine = try await coord.review(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(try await life.finalizeForSettlement() == nil)
        #expect(try records.listRecords(limit: nil).count == before)
    }

    // 路径 5（replay auto）：replay finalize → nil（不入账）
    @Test("auto-end: Replay → finalizeForSettlement 返 nil，不入账")
    func autoEnd_replay_returnsNil() async throws {
        let (coord, records, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records, total: 80_000)
        let before = try records.listRecords(limit: nil).count
        let engine = try await coord.replay(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(try await life.finalizeForSettlement() == nil)
        #expect(try records.listRecords(limit: nil).count == before)
    }

    // 路径 3（settlement confirm）：endAfterSettlement → endSession 清活跃（不再保存）
    @Test("settlement-confirm: endAfterSettlement → 仅 endSession 清活跃")
    func endAfterSettlement_endsSession() async throws {
        let (coord, _, _) = H.makeCoordinator(candles: H.validCandles())
        let engine = try await coord.startNewNormalSession()
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        await life.endAfterSettlement()
        #expect(coord.activeEngine == nil)
        #expect(coord.activeReader == nil)
    }

    // MARK: - shouldAutoFinalize 门（H1：自动结算判定逻辑 host 测，三门 + 正例）

    // 正例：Normal 到末态、未结算过 → true
    @Test("shouldAutoFinalize: Normal at-end 未结算 → true")
    func shouldAutoFinalize_normalAtEnd_true() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        let (coord, _, _, _) = try H.resumeCoordinator(meta: meta)      // tick7 == maxTick7
        let engine = try #require(try await coord.resumePending())
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.isAtEnd == true)
        #expect(life.shouldAutoFinalize(didFinalize: false) == true)
    }

    // 一次性门：已结算过 → false（防 onChange 末态多次触发重复 finalize）
    @Test("shouldAutoFinalize: Normal at-end 已结算 → false（once-gate）")
    func shouldAutoFinalize_alreadyFinalized_false() async throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "X", startDatetime: 1, endDatetime: 2)
        let (coord, _, _, _) = try H.resumeCoordinator(meta: meta)
        let engine = try #require(try await coord.resumePending())
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.shouldAutoFinalize(didFinalize: true) == false)
    }

    // 模式门 killer：Review isAtEnd 构造即真，但 mode==.review → false（不得误结算）
    @Test("shouldAutoFinalize: Review at-end → false（mode-gate killer）")
    func shouldAutoFinalize_review_false() async throws {
        let (coord, records, _) = H.makeCoordinator(candles: H.validCandles())
        let id = try Self.seedRecord(records)
        let engine = try await coord.review(recordId: id)
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.isAtEnd == true)                                   // review 固定末态
        #expect(life.shouldAutoFinalize(didFinalize: false) == false)   // 但 mode 门抑制
    }

    // isAtEnd 门：fresh Normal 未到末态 → false（即便未结算）
    @Test("shouldAutoFinalize: fresh Normal not-at-end → false（isAtEnd-gate）")
    func shouldAutoFinalize_freshNormal_false() async throws {
        let (coord, _, _) = H.makeCoordinator(candles: H.validCandles())
        let engine = try await coord.startNewNormalSession()            // tick0 < maxTick7
        let life = TrainingSessionLifecycle(engine: engine, coordinator: coord)
        #expect(life.shouldAutoFinalize(didFinalize: false) == false)
    }
    // 注：Replay-at-end 与 Normal-at-end 同走 `mode != .review` 真分支（仅 Review 被门抑制），
    // 由上「正例」覆盖该路径；不另构造步进至末态的 Replay 引擎（步进粒度依周期，测试脆弱）。
}
```

- [ ] **Step 2：运行测试确认失败**

Run: `swift test --filter TrainingSessionLifecycle`
Expected: FAIL（编译错误：`TrainingSessionLifecycle` 未定义）

- [ ] **Step 3：写最小实现**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift
// Kline Trainer Swift Contracts — U2 会话生命周期接线（Wave 2 顺位 9）
// Spec: docs/superpowers/specs/2026-06-02-wave2-outline-design.md §四 L124（U2 接线 E6
//       saveProgress/finalize/endSession，5 路径矩阵）+ kline_trainer_plan_v1.5.md §6.2.1/§6.2.5。
//
// 平台无关纯接线层（host 全测）：把 U2 的 UI 事件串接到 frozen E6 TrainingSessionCoordinator（PR #86）。
// 决议（D2/D3/D4/D12）：
// - D2 不呈现 SettlementView（顺位 11 路由+repo owner 负责）；finalizeForSettlement 仅返 recordId? 上交。
// - D3 back = saveProgress（非 Normal no-op）+ endSession；统一调用，review/replay 走非保存分支。
// - D4 isAtEnd = tick 到 maxTick；调用方按 mode 决定是否触发结算（Review 不触发）。

import Foundation

@MainActor
public struct TrainingSessionLifecycle {
    public let engine: TrainingEngine
    public let coordinator: TrainingSessionCoordinator

    public init(engine: TrainingEngine, coordinator: TrainingSessionCoordinator) {
        self.engine = engine
        self.coordinator = coordinator
    }

    /// 局是否已到末态（globalTickIndex 抵 maxTick）。调用方据 `engine.flow.mode` 决定是否触发结算（D4）。
    public var isAtEnd: Bool {
        engine.tick.globalTickIndex >= engine.tick.maxTick
    }

    /// 是否应触发自动结算（D5 / plan-review H1）：到末态 + 非 Review（Review 固定末态 isAtEnd 恒真但
    /// 结算弹窗 ❌，capability matrix L842）+ 未结算过（一次性门，防 onChange 末态多次触发）。
    /// 纯函数，host 全测；`TrainingView.maybeAutoEnd` 仅作壳触发器调用本判定。
    public func shouldAutoFinalize(didFinalize: Bool) -> Bool {
        isAtEnd && engine.flow.mode != .review && !didFinalize
    }

    /// 返回按钮（plan v1.5 §6.2.1 L920）：保存进度（Normal 真存；review/replay 在 coordinator 内 no-op）
    /// 然后结束会话。统一调用使非保存分支自然落到 coordinator.saveProgress 的 mode 守门（D3）。
    public func back() async throws {
        try await coordinator.saveProgress(engine: engine)
        await coordinator.endSession()
    }

    /// 自动结束（plan v1.5 §6.2.5）：正式结束入账，返 recordId（Normal）/ nil（review/replay 非保存分支）。
    /// **不** endSession —— 结算确认后才结束会话（D2：呈现由顺位 11，确认走 endAfterSettlement）。
    public func finalizeForSettlement() async throws -> Int64? {
        try await coordinator.finalize(engine: engine)
    }

    /// 结算确认后（plan v1.5 §6.3）：结束会话（reader 关闭 + 清活跃上下文）。
    public func endAfterSettlement() async {
        await coordinator.endSession()
    }
}
```

- [ ] **Step 4：运行测试确认通过**

Run: `swift test --filter TrainingSessionLifecycle`
Expected: PASS（12 测试全过：8 路径 + 4 shouldAutoFinalize 门）

- [ ] **Step 5：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingSessionLifecycleTests.swift
git commit -m "feat(U2): TrainingSessionLifecycle E6 生命周期接线（5 路径矩阵 host 测）"
```

---

## Task 2：`TrainingTopBarContent`（顶栏格式化纯值，host 全测）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift`

格式口径**对齐** `SettlementContent`（POSIX locale `¥ ` + 千分位 + 2 位小数；收益率带符号 2 位百分比 + `-0.0`→`+0.00%` 归一）。`SettlementContent` 的 formatter 为 `private static` 不可复用（U3 冻结，不改），本文件**独立**实现同口径 formatter（D 注：刻意不抽共享避免动冻结 U3）。

- [ ] **Step 1：写失败测试**

```swift
import Testing
@testable import KlineTrainerContracts

@Suite("TrainingTopBarContent")
struct TrainingTopBarContentTests {

    @Test("总资金：¥ + 一空格 + 千分位 + 2 位小数（对齐 SettlementContent 口径）")
    func totalCapital_thousands() {
        let c = TrainingTopBarContent(totalCapital: 102_345.67, holdingCost: 0, returnRate: 0)
        #expect(c.totalCapital == "¥ 102,345.67")
    }

    @Test("持仓成本：空仓 0 → ¥ 0.00")
    func holdingCost_zero() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0)
        #expect(c.holdingCost == "¥ 0.00")
    }

    @Test("持仓成本：含小数千分位")
    func holdingCost_value() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 12_040.5, returnRate: 0)
        #expect(c.holdingCost == "¥ 12,040.50")
    }

    @Test("收益率：正 → +X.XX%")
    func returnRate_positive() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0.0234)
        #expect(c.returnRate == "+2.34%")
    }

    @Test("收益率：负 → -X.XX%")
    func returnRate_negative() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: -0.0832)
        #expect(c.returnRate == "-8.32%")
    }

    @Test("收益率：零 → +0.00%")
    func returnRate_zero() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: 0)
        #expect(c.returnRate == "+0.00%")
    }

    @Test("收益率：负零归一 → +0.00%（killer：-0.0 不得显 -0.00%）")
    func returnRate_negativeZero_normalized() {
        let c = TrainingTopBarContent(totalCapital: 0, holdingCost: 0, returnRate: -0.0)
        #expect(c.returnRate == "+0.00%")
    }

    @Test("Equatable：同输入同值")
    func equatable() {
        let a = TrainingTopBarContent(totalCapital: 100, holdingCost: 50, returnRate: 0.01)
        let b = TrainingTopBarContent(totalCapital: 100, holdingCost: 50, returnRate: 0.01)
        #expect(a == b)
    }
}
```

- [ ] **Step 2：运行测试确认失败**

Run: `swift test --filter TrainingTopBarContent`
Expected: FAIL（`TrainingTopBarContent` 未定义）

- [ ] **Step 3：写最小实现**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift
// Kline Trainer Swift Contracts — U2 顶栏数值格式化纯值（Wave 2 顺位 9）
// Spec: kline_trainer_plan_v1.5.md §6.2.1 L905-918（总资金 / 持仓成本 / 收益率）。
//
// 平台无关纯值（host 全测）：把 engine 实时数值格式化为顶栏显示串。格式口径**对齐** SettlementContent
// （`¥ ` + 一空格 + POSIX 千分位 + 2 位小数；收益率 `%+.2f` + `-0.0` 归一）—— 与 U3 结算窗同 ¥/% 口径，
// 全应用一致。SettlementContent 的 formatter 为 private static（U3 冻结），本文件独立实现**同口径**
// （刻意不抽共享，避免动冻结 U3；以 host 测锁口径一致）。plan-review M1：currency 含空格、percent 用
// `%+.2f` 与 SettlementContent.formatCapital(L48-62)/formatSignedRate(L68-73) 字面一致。
// 决议 D8：本 PR 不含「仓位 X/5」（PositionManager 无档位存值 + 项目拒绝臆造 tier 公式，residual U2-R3）。

import Foundation

public struct TrainingTopBarContent: Equatable {
    public let totalCapital: String   // "¥ 102,345.67"
    public let holdingCost: String    // "¥ 0.00"
    public let returnRate: String     // "+2.34%" / "-8.32%" / "+0.00%"

    public init(totalCapital: Double, holdingCost: Double, returnRate: Double) {
        self.totalCapital = Self.currency(totalCapital)
        self.holdingCost = Self.currency(holdingCost)
        self.returnRate = Self.percent(returnRate)
    }

    /// `¥` + 一空格 + 千分位 + 强制 2 位小数（POSIX，跨 locale 稳定）。同 SettlementContent.formatCapital。
    private static func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let body = f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "¥ \(body)"
    }

    /// 收益率小数 ×100 + `%+.2f` 带符号 + `%`；`-0.0` 归一为 `+0.00%`。同 SettlementContent.formatSignedRate。
    private static func percent(_ rate: Double) -> String {
        let raw = rate * 100
        let pct = (raw == 0) ? 0.0 : raw                  // IEEE-754：±0 均 ==0 → 归一 +0.0
        return "\(String(format: "%+.2f", pct))%"
    }
}
```

- [ ] **Step 4：运行测试确认通过**

Run: `swift test --filter TrainingTopBarContent`
Expected: PASS（8 测试全过）

- [ ] **Step 5：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift
git commit -m "feat(U2): TrainingTopBarContent 顶栏格式化纯值（host 测）"
```

---

## Task 3：`TrainingView`（SwiftUI 薄壳，Catalyst 编译闸门）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`

无 host 单测（壳逻辑，靠 Catalyst build-for-testing SUCCEEDED 编译闸门 + #Preview 装配 + Task 1/2 纯层测试覆盖逻辑）。

- [ ] **Step 1：写壳实现**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
// Kline Trainer Swift Contracts — U2 训练页 SwiftUI 薄壳（Wave 2 顺位 9）
// Spec: kline_trainer_modules_v1.4.md §U2 L2049-2068（scenePhase 中继）
//     + kline_trainer_plan_v1.5.md §6.2（顶栏 / 双 K 线区 / 交易按钮 / 自动结束）。
//
// 决议（D1/D2/D4/D5/D9/D10/D11）：
// - D1 init 扩 (lifecycle:, onExit:, onSessionEnded:)（modules §U2 示意，outline §124 权威接线）。
// - D2 不呈现 SettlementView：自动结束调 finalizeForSettlement → recordId? 经 onSessionEnded 上交顺位 11。
// - D4 自动结束检测 tick>=maxTick 且 mode != .review；D5 didFinalize 一次性闸门。
// - D9 PositionPicker 全档启用，buy 返 failure 兜；D10 交易按钮仅 Normal/Replay，持有/观察随持仓切文案。
// - D11 #if canImport(UIKit)：嵌 ChartContainerView（UIViewRepresentable）故同门；host 不编译，Catalyst 编译闸门。
// - 延后（D6 手动结束按钮 / D7 画线面板 / D8 仓位 X/5）：见 plan residual U2-R1/R2/R3。

#if canImport(UIKit)
import SwiftUI

public struct TrainingView: View {
    private let lifecycle: TrainingSessionLifecycle
    private let onExit: () -> Void
    private let onSessionEnded: (Int64?) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var didFinalize = false
    @State private var pickerRequest: PickerRequest?

    public init(lifecycle: TrainingSessionLifecycle,
                onExit: @escaping () -> Void,
                onSessionEnded: @escaping (Int64?) -> Void) {
        self.lifecycle = lifecycle
        self.onExit = onExit
        self.onSessionEnded = onSessionEnded
    }

    private var engine: TrainingEngine { lifecycle.engine }
    private var showsTradeButtons: Bool { engine.flow.mode != .review }   // D10

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            panel(.upper)
            Divider()
            panel(.lower)
        }
        .onAppear { maybeAutoEnd() }                                            // M2：resume-at-maxTick（onChange 不触发初值）
        .onChange(of: engine.tick.globalTickIndex) { _, _ in maybeAutoEnd() }   // D4/D5
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { engine.onSceneActivated() }                // modules §U2 唯一链路
        }
        .sheet(item: $pickerRequest) { req in
            PositionPickerView(
                enabledTiers: Set(PositionTier.allCases),                       // D9
                onPick: { tier in
                    switch req.action {
                    case .buy:  _ = engine.buy(panel: req.panel, tier: tier)
                    case .sell: _ = engine.sell(panel: req.panel, tier: tier)
                    }
                    pickerRequest = nil
                },
                onCancel: { pickerRequest = nil })
        }
    }

    // 顶栏：返回 + 总资金 / 持仓成本 / 收益率（D8：不含仓位 X/5）。
    private var topBar: some View {
        let bar = TrainingTopBarContent(totalCapital: engine.currentTotalCapital,
                                        holdingCost: engine.holdingCost,
                                        returnRate: engine.returnRate)
        return HStack(spacing: 12) {
            Button("返回") { Task { try? await lifecycle.back(); onExit() } }
            Spacer()
            Text(bar.totalCapital)
            Text("持仓成本\(bar.holdingCost)")
            Text(bar.returnRate)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .font(.callout)
    }

    // 单面板：K 线宿主 + 右侧交易按钮组（Normal/Replay）。
    private func panel(_ id: PanelId) -> some View {
        HStack(spacing: 0) {
            ChartContainerView(panel: id, engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsTradeButtons { tradeButtons(id) }
        }
    }

    private func tradeButtons(_ id: PanelId) -> some View {
        VStack(spacing: 8) {
            Button("买入") { pickerRequest = PickerRequest(panel: id, action: .buy) }
                .disabled(!engine.buyEnabled)
            Button("卖出") { pickerRequest = PickerRequest(panel: id, action: .sell) }
                .disabled(!engine.sellEnabled)
            Button(engine.position.shares > 0 ? "持有" : "观察") {   // D10
                engine.holdOrObserve(panel: id)
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 8)
    }

    // D4/D5：判定下放 host-测 lifecycle.shouldAutoFinalize（H1）；壳仅持一次性 didFinalize + 触发 finalize。
    // 由 .onAppear（resume-at-maxTick，M2）与 .onChange(globalTickIndex)（步进至末态）双触发，shouldAutoFinalize
    // 的 !didFinalize 门保证仅 finalize 一次。
    private func maybeAutoEnd() {
        guard lifecycle.shouldAutoFinalize(didFinalize: didFinalize) else { return }
        didFinalize = true
        Task {
            do {
                let id = try await lifecycle.finalizeForSettlement()
                onSessionEnded(id)
            } catch {
                onSessionEnded(nil)   // finalize 失败：仍上交结束信号（顺位 11 兜错）
            }
        }
    }

    // sheet(item:) 用：交易请求（面板 + 买/卖）。
    private struct PickerRequest: Identifiable {
        enum Action { case buy, sell }
        let panel: PanelId
        let action: Action
        var id: String { "\(panel)-\(action)" }
    }
}

// MARK: - DEBUG-only #Preview

#if DEBUG
#Preview {
    TrainingView(
        lifecycle: TrainingSessionLifecycle(engine: .preview(), coordinator: .preview()),
        onExit: {},
        onSessionEnded: { _ in })
}
#endif
#endif
```

- [ ] **Step 2：host swift test 确认整体编译 + 既有测试全绿（本壳被 `#if canImport(UIKit)` 跳过编译）**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with N tests ... passed`（N = 737 + 本 PR 新增 17；本壳 host 不编译，Task 1/2 测试通过）

- [ ] **Step 3：Mac Catalyst build-for-testing 确认本壳编译通过（本地 de-risk）**

Run（本地有 Xcode 时）:
```bash
xcodebuild build-for-testing \
  -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **`（CI `Mac Catalyst build-for-testing on macos-15` 闸门为权威，本地仅 de-risk）

- [ ] **Step 4：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "feat(U2): TrainingView SwiftUI 薄壳（双 K 线宿主 + 交易 + scenePhase + 自动结束接线）"
```

---

## Task 4：C2/C7 手势仲裁运行时验收 runbook

**Files:**
- Create: `docs/runbooks/2026-06-07-u2-gesture-runtime-acceptance.md`

兑现 outline §四 L121「顺位 9 U2（手势仲裁运行时）须产出具体验收 artifact」+ c8b runbook L7「两指/单指手势仲裁运行时证据归顺位 9 U2」。

- [ ] **Step 1：写 runbook**

```markdown
# U2 手势仲裁运行时验收 runbook（C7 单指 pan / 两指周期切换 / 长按十字光标）

**性质**：device/simulator **手动**验收（CLI/CI 仅编译，不跑 UIKit 运行时；per outline §四 L121）。
执行者：user（按步骤操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：在 iPad / Mac Catalyst 运行含 `TrainingView(lifecycle:onExit:onSessionEnded:)` 的宿主
> （顺位 11 组合根，或最小 SwiftUI 宿主用 `TrainingSessionLifecycle(engine: .preview(mode: .normal), coordinator: .preview())`）。
> 本 runbook 验 C7 手势仲裁运行时；C2 减速 + C8 帧预算见 `2026-06-07-c8b-runtime-acceptance.md`。
>
> **注（独立 preview 宿主，plan-review L2）**：最小 preview 宿主用两个**独立** `.preview()`（engine 非 coordinator 的活跃 engine）→ 抵末态调 `finalize` 会因「无活跃 session 上下文」抛错（coordinator L207），View 的 catch 触发 `onSessionEnded(nil)`。故独立 preview 仅验「触发器/onSessionEnded 上交」路径；真实「finalize 入账」须用顺位 11 接线后的活跃-session 宿主（或步骤 6 在真实组合根验证）。手势仲裁（步骤 1-3）不受影响，preview 宿主可完整验。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | 单指水平拖动上区 K 线 | 图表随手指水平滚动（pan 截获），松手有惯性减速 | pass = 跟手滚动且松手减速 |
| 2 | 两指同向上下滑动 | 周期组合切换（上区/下区 period 同步平移一档，如 60m/日→日/周） | pass = 两指滑触发周期切换、单指不触发 |
| 3 | 长按 K 线并拖动 | 出现十字光标随手指移动；松手消失 | pass = 十字光标显示/跟随/消失 |
| 4 | Normal 模式点「买入」选档 → 确认 | 触发交易，所有周期对应 K 线同步出现红点 B 标记 | pass = 标记同步出现 |
| 5 | Review 模式进入训练页 | 交易按钮组隐藏（capability matrix L833），仅可浏览/十字光标 | pass = 无买卖持有按钮 |
| 6 | 反复步进（持有/观察）至 maxTick | 局自动结束（onSessionEnded 触发，宿主呈现结算/返回） | pass = 抵末态自动结束 |

**回填**：执行后逐行填 pass/fail；本 runbook 链接进 Wave 2 收尾 completion doc 作 C7 手势运行时 artifact。
```

- [ ] **Step 2：Commit**

```bash
git add docs/runbooks/2026-06-07-u2-gesture-runtime-acceptance.md
git commit -m "docs(U2): C7 手势仲裁运行时验收 runbook（单/双指 + 长按）"
```

---

## Task 5：验收清单 doc + 自检

**Files:**
- Create: `docs/acceptance/2026-06-07-pr-u2-training-view.md`

中文 action / expected / pass-fail，二值可判定，避免禁用语（`验证通过即可` / `看起来正常` / `应该没问题` / `should work` / `looks fine`）。

- [ ] **Step 1：写验收 doc**

```markdown
# PR U2 TrainingView + E6 生命周期接线 验收清单

> 非编码者可执行。每项 action / expected / pass-fail，二值判定。机器验收（swift test）+ 手动运行时（见 runbook）。

## 一、host 单元（机器执行）

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift test --filter TrainingSessionLifecycle` | 12 测试全 passed，0 failure | pass = 终端打印 `12 tests ... passed` |
| 2 | `swift test --filter TrainingTopBarContent` | 8 测试全 passed | pass = 终端打印 `8 tests ... passed` |
| 3 | `swift test` 全量 | `757 tests ... passed`（737 基线 + 20 新），0 failure | pass = 全量 0 failure |

## 二、生命周期 5 路径矩阵（host 测断言，逐条对应）

| # | 路径 | expected | pass/fail |
|---|---|---|---|
| 4 | back（Normal） | pending 写入 + activeEngine/activeReader 清空 | pass = `back_normal_savesAndEnds` 过 |
| 5 | back（Review/Replay） | pending **不**写（非保存分支）+ activeEngine/activeReader 清空 | pass = `back_review_noSaveButEnds`/`back_replay_noSaveButEnds` 过 |
| 6 | auto-end（Normal） | isAtEnd true + finalize 返 recordId + record 入账 + pending 清 | pass = `autoEnd_normal_finalizesAndReturnsId` 过 |
| 7 | auto-end（Review/Replay） | finalize 返 nil + 不入账 | pass = `autoEnd_review_returnsNil`/`autoEnd_replay_returnsNil` 过 |
| 8 | settlement confirm | endAfterSettlement → activeEngine 清空 | pass = `endAfterSettlement_endsSession` 过 |
| 8b | 自动结算门（H1） | Review-at-end→false / Normal-at-end→true / 已结算→false / fresh→false | pass = 4 `shouldAutoFinalize_*` 过 |

## 三、Catalyst 编译闸门（CI 权威）

| # | action | expected | pass/fail |
|---|---|---|---|
| 9 | CI `Mac Catalyst build-for-testing on macos-15` | TEST BUILD SUCCEEDED（TrainingView 壳编译过） | pass = CI job 绿 |

## 四、运行时（手动，见 `docs/runbooks/2026-06-07-u2-gesture-runtime-acceptance.md`）

| # | action | expected | pass/fail |
|---|---|---|---|
| 10 | 按 runbook 6 步操作 | 单/双指/长按手势仲裁、交易标记、Review 隐藏交易、自动结束逐项 pass | pass = runbook 6 行全 pass |

## 五、scope 边界（确认延后项不在本 PR）

| # | action | expected | pass/fail |
|---|---|---|---|
| 11 | grep `TrainingView.swift` 无手动结束按钮强平 / 画线面板 / 仓位 X/5 | 仅返回 + 三数值 + 交易 + 自动结束（D6/D7/D8 延后） | pass = 无延后项代码 |
```

- [ ] **Step 2：写 PR 自检（spec coverage 对照）—— 见本 plan 末「Self-Review」节，逐条核对**

- [ ] **Step 3：Commit**

```bash
git add docs/acceptance/2026-06-07-pr-u2-training-view.md
git commit -m "docs(U2): 验收清单（5 路径矩阵 + Catalyst 闸门 + 手势 runbook 引用）"
```

---

## Residuals（本 PR 不交付，文档化上交）

- **U2-R1**：手动「结束本局」按钮（plan v1.5 §6.2.2，含点「是」先按最后收盘价强平）—— 需 frozen E5 无的手动强平方法 `forceCloseAndEnd()`；归后续 PR / Wave 3。自动结束路径（§6.2.5）本 PR 已交付。
- **U2-R2**：画线工具面板（plan v1.5 §6.2.6，顶栏画线按钮 + 7 工具开关 + 锚点输入）—— 画线输入 DrawingInputController 属 Wave 3（modules L2155 + C8b 注 L90）。
- **U2-R3**：顶栏「仓位 X/5」显示 —— PositionManager 无档位存值 + 项目拒绝臆造 tier 公式（E5b D1）；待 tier 反推契约定义。
- **U2-R4（D2 后续）**：`SettlementView` 呈现 + record 加载 —— 归顺位 11 组合根（路由+repo owner）。Normal 经 finalize recordId 加载 record；Replay 无 record 须由 engine 末态 + meta 装配（顺位 11 评估是否需 E6 meta 访问面）。U2 经 `onSessionEnded(recordId:)` 上交。

---

## Self-Review（写完 plan 后冷眼核对 spec）

**1. Spec coverage（逐条 → 任务映射）：**
- outline §四 L124 U2 接线 E6 saveProgress/finalize/endSession + 5 路径矩阵 → **Task 1**（back/finalizeForSettlement/endAfterSettlement + 9 测试覆盖 back-Normal/Review/Replay、auto-end-Normal/Review/Replay、settlement-confirm、isAtEnd）✅
- §124 pending 清理 → Task 1 `autoEnd_normal` 断言 `pending.loadPending() == nil` ✅
- §124 非保存分支（review/replay）→ Task 1 `back_review/replay_noSaveButEnds` + `autoEnd_review/replay_returnsNil` ✅
- modules §U2 scenePhase 中继 `engine.onSceneActivated()` → **Task 3** `.onChange(of: scenePhase)` ✅
- plan v1.5 §6.2.1 返回保存进度 → Task 1 `back()` + Task 3 返回按钮 ✅
- plan v1.5 §6.2.1 顶栏总资金/持仓成本/收益率 → **Task 2** + Task 3 topBar ✅
- plan v1.5 §6.2.3 双 K 线区 → Task 3 `panel(.upper)/.panel(.lower)` 嵌 ChartContainerView ✅
- plan v1.5 §6.2.4 交易按钮 + 仓位 HUD → Task 3 tradeButtons + PositionPickerView ✅
- plan v1.5 §6.2.5 自动结束 → Task 3 `maybeAutoEnd` + Task 1 `finalizeForSettlement` ✅
- capability matrix L833/L837/L842 Review 隐藏交易/无结束按钮 → Task 3 `showsTradeButtons` ✅
- outline §四 L121 C2/C7 运行时 artifact → **Task 4** runbook ✅
- 延后项（手动结束/画线/仓位 X/5/结算呈现）→ Residuals U2-R1/R2/R3/R4 文档化 ✅

**2. Placeholder scan：** 无 TBD/TODO；每步含完整代码 + 精确命令 + 预期输出。✅

**3. Type consistency：**
- `TrainingSessionLifecycle(engine:coordinator:)` 在 Task 1 定义、Task 3 #Preview 一致 ✅
- `finalizeForSettlement() -> Int64?` / `back()` / `endAfterSettlement()` / `isAtEnd` 在 Task 1 与 Task 3 调用一致 ✅
- `TrainingTopBarContent(totalCapital:holdingCost:returnRate:)` Task 2 定义、Task 3 调用一致 ✅
- `ChartContainerView(panel:engine:)`（C8a L21）/ `PositionPickerView(enabledTiers:onPick:onCancel:)`（U5）/ `engine.buy(panel:tier:)`·`sell`·`holdOrObserve(panel:)`·`buyEnabled`·`sellEnabled`·`currentTotalCapital`·`holdingCost`·`returnRate`·`flow.mode`·`tick.globalTickIndex`·`tick.maxTick`·`onSceneActivated()`·`position.shares` —— 全部核对 merged 源码签名一致 ✅
- 测试 harness `TrainingSessionPersistenceTests.{validCandles,makeCoordinator,resumeCoordinator,cachedFile,CapitalDAO}` —— 核对 PR #86 测试文件存在且 static ✅

**4. 测试计数自检：** Task 1 = 12 测试（8 路径 + 4 shouldAutoFinalize 门），Task 2 = 8 测试，合计 20。全量 = 737（基线，本 worktree 实测）+ 20 = **757**。验收 doc #3 / acceptance 数字以此为准（impl 阶段实跑回填，防 stale）。

**5. plan-review（opus xhigh R1）已消解：** H1（自动结算门下放 host 测 + 4 killer）✅ / M1（currency `¥ ` 空格 + `%+.2f` 对齐 SettlementContent）✅ / M2（`.onAppear` resume-at-maxTick 触发）✅ / M3（D13 结算时序反转披露）✅ / L1（Task 0 trust-boundary 措辞）✅ / L2（runbook 独立 preview 注）✅ / L3（review/replay back 加 activeReader 断言）✅。
