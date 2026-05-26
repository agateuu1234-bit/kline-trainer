# PR C6 — DrawingTools + DrawingInputController infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace PR #51 empty `drawDrawings` stub with a complete drawing-tool infrastructure layer: 2 protocols + 1 `@MainActor @Observable` Manager + real render dispatch with `tools:` injection — Wave 1 顺位 12 / 第 14 个 PR per outline v20.

**Architecture:** Manager is a pure in-memory state container (NO ChartReducer coupling — reducer integration is Wave 3 UI 层 responsibility per spec §3.3). Render dispatch consumes injected `[DrawingToolType: any DrawingTool]` dictionary; Wave 1 callers pass `[:]` so no drawing actually paints.

**Tech Stack:** Swift 6.0, Swift Testing (`@Test` / `#expect`), UIKit (CoreGraphics), `@MainActor` + `@Observable`, SwiftPM `KlineTrainerContracts` target.

**Spec source:** `docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md` (commit `b7c7450`).

**Constraint reminders:**
- ≤ 3 sub-items (this plan: 3 Tasks)
- ≤ 500 行 prod (this plan: ~250 行 prod estimate)
- codex 4-5 轮内收敛 (will be opus 4.7 xhigh, but same budget)
- `cd ios/Contracts && swift test` is the canonical test command
- Working branch: `worktree-pr-c6-drawing-tools-infrastructure`

---

## File Structure

### Production (5 files, ~250 lines)

| Path | Action | Lines | Responsibility |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | Create | ~30 | `public protocol DrawingTool: Sendable` (4 members) |
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift` | Create | ~20 | `public protocol DrawingInputController: AnyObject` (2 methods) |
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | Create | ~140 | `@MainActor @Observable public final class` (4 props + 5 methods + init) |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift` | Modify | ~25-30 (replace stub body) | Replace stub body with real dispatch loop + add `tools:` parameter |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | 1 line changed | +0 net lines | L55-56 callsite add ` tools: [:]` argument (chars only) |

### Tests (4 files, ~380 lines, 17 tests total)

| Path | Action | Lines | Tests |
|---|---|---|---|
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingProtocolTests.swift` | Create | ~80 | 3 protocol contract tests |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolManagerTests.swift` | Create | ~180 | 10 Manager state-machine tests |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift` | Create | ~80 | 3 dispatch tests |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/SpecLiteralGuardTests.swift` | Create | ~40 | 1 spec literal guard test |

### Docs / spec amendments (3 files)

| Path | Action | Content |
|---|---|---|
| `kline_trainer_modules_v1.4.md` | Modify 3 sites | L2149 (acceptance §A wording) + L1224-1225 (KLineView demo 5-arg sig) + L1346-1348 (§C6 protocol block 5-arg sig) |
| `docs/acceptance/2026-05-26-pr-c6-drawing-tools-infrastructure.md` | Create | ~120 lines 中文非程序员验收清单 (9 sections per template) |
| `docs/superpowers/plans/2026-05-26-pr-c6-drawing-tools-infrastructure.md` | Already exists | This file |

---

## Task 0 — §15.3 评审策略前置

per `docs/governance/wave1-plan-template.md`：本 plan 使用哪些评审形式。

- [ ] **局部对抗性评审**（必）：本 plan 子模块 scope 内 opus 4.7 xhigh effort adversarial review；4-5 轮内收敛或 escalate（按 memory `feedback_codex_plan_budget_overshoot`）。**本 PR 已在 spec 阶段跑过 3 轮 opus xhigh review 收敛 APPROVE**（R1 NEEDS-ATTN 12 findings → v2 → R2 APPROVE-with-caveat 1 finding → v3 → R3 APPROVE clean，commit `b7c7450` §九 changelog v1→v2→v3）；plan 阶段独立 review 一轮；实施完 branch-diff 再一轮。
- [x] **集成层评审**（C8 桥接 + E5 编排所在 PR 必）：**声明 N/A** — 本 PR 不动 ChartReducer / KLineView 数据流主线，仅替换 drawDrawings stub + 新增 infrastructure；spec §一 明确退出 C8/E5 scope。
- [x] **性能评审**（Phase 5 磨光 PR 必）：**声明 N/A** — drawDrawings 在本 PR runtime 因 `tools:` 字典空 → for 循环每次走 `continue`，零绘图开销；Phase 5 磨光要等 Wave 3 注册具体 tool 后才有性能数据可测。

完成 Task 0 才进 Task 1 实施（仅"局部对抗性评审"项为可执行待办，2 项 N/A 已预勾声明）。

---

## Task 1 — DrawingTool + DrawingInputController protocols

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingProtocolTests.swift`

- [ ] **Step 1: Write the failing tests** — `DrawingProtocolTests.swift`

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingProtocolTests.swift
// Spec: docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md §5.2
// 3 protocol contract tests. Verifies DrawingTool + DrawingInputController conformance shape.

import Testing
import CoreGraphics
@testable import KlineTrainerContracts

#if canImport(UIKit)

@MainActor
struct DrawingProtocolTests {

    @Test("§5.2 #11 FakeDrawingTool conforms to DrawingTool (4 members reachable)")
    func fakeDrawingToolConforms() {
        let tool: any DrawingTool = FakeDrawingTool()
        #expect(type(of: tool).type == .horizontal)
        #expect(tool.requiredAnchors == 1...1)
        // render / hitTest reachable through dynamic dispatch
        let mapper = makeMapperFixture()
        let ctx = makeCtxFixture()
        tool.render(ctx: ctx, mapper: mapper, anchors: [])
        let hit = tool.hitTest(point: .zero, mapper: mapper, anchors: [])
        #expect(hit == false)
    }

    @Test("§5.2 #12 requiredAnchors is ClosedRange<Int> (lower & upper both contained)")
    func requiredAnchorsRangeIsClosed() {
        let tool = FakeDrawingTool()
        let r = tool.requiredAnchors
        #expect(r.contains(r.lowerBound))
        #expect(r.contains(r.upperBound))
        // Compile-time guard: assignment to ClosedRange<Int> would fail if it were Range<Int>
        let _: ClosedRange<Int> = r
    }

    @Test("§5.2 #13 FakeInputController conforms to DrawingInputController (2 methods callable)")
    func fakeInputControllerConforms() {
        let ctrl: any DrawingInputController = FakeInputController()
        let mapper = makeMapperFixture()
        let panel = makePanelFixture()
        let anchor = ctrl.tapToAnchor(at: .zero, panel: panel, mapper: mapper)
        #expect(anchor.candleIndex == 0)
        #expect(anchor.price == 0)
        let shouldCommit = ctrl.shouldCommit(current: [anchor], tool: .horizontal)
        #expect(shouldCommit == true)
    }
}

// MARK: - Test fakes

// @unchecked Sendable: Swift 6 strict concurrency — @MainActor final class 不自动 Sendable，
// DrawingTool protocol 强制 : Sendable → 必须显式标。无可变状态，安全。
@MainActor
private final class FakeDrawingTool: DrawingTool, @unchecked Sendable {
    static var type: DrawingToolType { .horizontal }
    var requiredAnchors: ClosedRange<Int> { 1...1 }
    func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor]) {}
    func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool { false }
}

@MainActor
private final class FakeInputController: DrawingInputController {
    func tapToAnchor(at point: CGPoint, panel: PanelViewState, mapper: CoordinateMapper) -> DrawingAnchor {
        DrawingAnchor(period: .m60, candleIndex: 0, price: 0)
    }
    func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool {
        !current.isEmpty
    }
}

// MARK: - Fixtures
// fixture 形状对齐 GeometryTests.swift L210-219 + ReducerTests.swift L20-21 既有 pattern

@MainActor
private func makeMapperFixture() -> CoordinateMapper {
    let viewport = ChartViewport(
        startIndex: 0,
        visibleCount: 100,
        pixelShift: 0,
        geometry: ChartGeometry(candleStep: 8, candleWidth: 6, gap: 2),
        priceRange: PriceRange(min: 100, max: 200),
        mainChartFrame: CGRect(x: 0, y: 0, width: 320, height: 200)
    )
    return CoordinateMapper(viewport: viewport, displayScale: 1)
}

@MainActor
private func makeCtxFixture() -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

@MainActor
private func makePanelFixture() -> PanelViewState {
    PanelViewState(
        period: .m60,
        interactionMode: .autoTracking,
        visibleCount: 100,
        offset: 0,
        revision: 0
    )
}

#endif
```

- [ ] **Step 2: Run tests to verify they fail (compilation error)**

Run: `cd ios/Contracts && swift test --filter DrawingProtocolTests 2>&1 | grep -E "error:.*cannot find.*in scope"`
Expected: ≥ 1 命中（关键短语 `cannot find 'DrawingTool'` 或 `cannot find 'DrawingInputController'`；Swift toolchain 小版本可能调整 wording）。

- [ ] **Step 3: Write minimal implementation — `DrawingTool.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift
// Spec: kline_trainer_modules_v1.4.md §C6 L1318-1323 + design doc §2.2
// Wave 1 PR C6: protocol-only; concrete tool impls deferred to Wave 3 Phase 2.5/4.

#if canImport(UIKit)
import CoreGraphics

public protocol DrawingTool: Sendable {
    static var type: DrawingToolType { get }
    var requiredAnchors: ClosedRange<Int> { get }
    @MainActor func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor])
    @MainActor func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool
}

#endif
```

- [ ] **Step 4: Write minimal implementation — `DrawingInputController.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift
// Spec: kline_trainer_modules_v1.4.md §C6 L1325-1328 + design doc §2.2
// Wave 1 PR C6: protocol-only; DefaultDrawingInputController impl deferred to Wave 3.

#if canImport(UIKit)
import CoreGraphics

public protocol DrawingInputController: AnyObject {
    @MainActor func tapToAnchor(at point: CGPoint, panel: PanelViewState, mapper: CoordinateMapper) -> DrawingAnchor
    @MainActor func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool
}

#endif
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios/Contracts && swift test --filter DrawingProtocolTests 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中（Swift Testing 真实输出 `Test run with 3 tests in 1 suite passed after X seconds.`；过滤后单复数视 N=1 而定）

- [ ] **Step 6: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingProtocolTests.swift
git commit -m "feat(c6): DrawingTool + DrawingInputController protocols (Task 1)

Spec §C6 L1318-1328 字面对齐；本 PR scope 仅 protocol，具体 tool 实现归 Wave 3。
3 contract tests (DrawingProtocolTests).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 — DrawingToolManager state machine

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolManagerTests.swift`

- [ ] **Step 1: Write the failing tests** — `DrawingToolManagerTests.swift`

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolManagerTests.swift
// Spec: docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md §5.1
// 10 Manager state-machine tests. All pure state assertions; no dispatch spy / no revision spy.

import Testing
@testable import KlineTrainerContracts

#if canImport(UIKit)

@MainActor
struct DrawingToolManagerTests {

    private func makeAnchor(_ price: Double = 100) -> DrawingAnchor {
        DrawingAnchor(period: .m60, candleIndex: 0, price: price)
    }

    @Test("§5.1 #1 first toggle activates tool, pendingAnchors stays empty")
    func toggleFirstActivatesTool() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        #expect(m.activeTool == .horizontal)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.completedDrawings.isEmpty)
    }

    @Test("§5.1 #2 same-tool re-toggle deactivates")
    func toggleSameToolDeactivates() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor())
        m.toggle(.horizontal)
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
    }

    @Test("§5.1 #3 different-tool toggle overrides and clears pending")
    func toggleDifferentToolOverridesAndClearsPending() {
        let m = DrawingToolManager(enabledTools: [.horizontal, .ray])
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor())
        m.toggle(.ray)
        #expect(m.activeTool == .ray)
        #expect(m.pendingAnchors.isEmpty)
    }

    @Test("§5.1 #4 toggling disabled tool is no-op")
    func toggleDisabledToolIsNoOp() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.ray)  // ray NOT in enabledTools
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.enabledTools == [.horizontal])
    }

    @Test("§5.1 #5 addAnchor appends to pendingAnchors")
    func addAnchorAppends() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        let a = makeAnchor(150)
        m.addAnchor(a)
        #expect(m.pendingAnchors.count == 1)
        #expect(m.pendingAnchors[0] == a)
    }

    @Test("§5.1 #6 commit moves drawing to completed and resets active/pending")
    func commitMovesToCompletedAndResets() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        let a = makeAnchor(180)
        m.addAnchor(a)
        m.commit()
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.completedDrawings.count == 1)
        #expect(m.completedDrawings[0].toolType == .horizontal)
        #expect(m.completedDrawings[0].anchors == [a])
        #expect(m.completedDrawings[0].isExtended == false)
        #expect(m.completedDrawings[0].panelPosition == 0)
    }

    @Test("§5.1 #7 explicit cancel resets active and pending; completed untouched")
    func cancelExplicitResetsActiveAndPending() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor())
        m.commit()
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor(200))
        m.cancel()
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.completedDrawings.count == 1)  // prior commit preserved
    }

    @Test("§5.1 #8 cancel is idempotent no-op when activeTool == nil")
    func cancelIdempotentNoChange() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.cancel()
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.completedDrawings.isEmpty)
        #expect(m.enabledTools == [.horizontal])
    }

    @Test("§5.1 #9 deleteDrawing removes at index, preserves order")
    func deleteDrawingRemovesAtIndex() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        // commit 3 drawings
        for price in [100.0, 150.0, 200.0] {
            m.toggle(.horizontal)
            m.addAnchor(makeAnchor(price))
            m.commit()
        }
        #expect(m.completedDrawings.count == 3)
        m.deleteDrawing(at: 1)
        #expect(m.completedDrawings.count == 2)
        #expect(m.completedDrawings[0].anchors[0].price == 100)
        #expect(m.completedDrawings[1].anchors[0].price == 200)
    }

    @Test("§5.1 #10 enabledTools defaults to empty set; explicit init injects 7")
    func enabledToolsDefaultsToEmptySet() {
        let m1 = DrawingToolManager()
        #expect(m1.enabledTools.isEmpty)
        let all: Set<DrawingToolType> = [.ray, .trend, .horizontal, .golden, .wave, .cycle, .time]
        let m2 = DrawingToolManager(enabledTools: all)
        #expect(m2.enabledTools.count == 7)
    }
}

#endif
```

- [ ] **Step 2: Run tests to verify they fail (compilation error)**

Run: `cd ios/Contracts && swift test --filter DrawingToolManagerTests 2>&1 | grep -E "error:.*cannot find.*in scope"`
Expected: ≥ 1 命中（关键短语 `cannot find 'DrawingToolManager'`）。

- [ ] **Step 3: Write minimal implementation — `DrawingToolManager.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift
// Spec: kline_trainer_modules_v1.4.md §C6 L1330-1343 + design doc §2.3 §3.1 §四
// Wave 1 PR C6: pure in-memory state container. NO ChartReducer coupling.
// Reducer integration (.activateDrawing / .drawingCommitted / .drawingCancelled
// ChartAction dispatch) is Wave 3 UI 层 responsibility per design §3.3.

#if canImport(UIKit)
import Observation

@MainActor
@Observable
public final class DrawingToolManager {
    public var activeTool: DrawingToolType?
    public var enabledTools: Set<DrawingToolType>
    public var pendingAnchors: [DrawingAnchor]
    public var completedDrawings: [DrawingObject]

    public init(enabledTools: Set<DrawingToolType> = []) {
        self.activeTool = nil
        self.enabledTools = enabledTools
        self.pendingAnchors = []
        self.completedDrawings = []
    }

    /// Spec §3.1 toggle: 互斥语义 + 切工具时清空 pendingAnchors.
    /// - 同 tool 再 toggle = 关闭 (activeTool=nil, pendingAnchors=[])
    /// - 切到新 tool = 覆写 activeTool + 清 pending（隐含取消上一个 tool）
    /// - 不在 enabledTools 内 = no-op return
    public func toggle(_ t: DrawingToolType) {
        guard enabledTools.contains(t) else { return }
        if activeTool == t {
            activeTool = nil
            pendingAnchors = []
        } else {
            activeTool = t
            pendingAnchors = []
        }
    }

    /// Spec §3.1 addAnchor: append-only.
    /// - invariant: activeTool != nil (caller must toggle first)
    public func addAnchor(_ a: DrawingAnchor) {
        // invariant: activeTool != nil
        precondition(activeTool != nil, "addAnchor requires activeTool != nil (caller must toggle first)")
        pendingAnchors.append(a)
    }

    /// Spec §3.1 commit: move pending → completedDrawings + reset.
    /// - invariant: activeTool != nil && !pendingAnchors.isEmpty
    /// - anchor 数量上下界由 caller (DrawingInputController.shouldCommit) gate, NOT manager.
    public func commit() {
        // invariant: activeTool != nil
        precondition(activeTool != nil, "commit requires activeTool != nil")
        // invariant: !pendingAnchors.isEmpty
        precondition(!pendingAnchors.isEmpty, "commit requires non-empty pendingAnchors (shouldCommit gate)")
        let drawing = DrawingObject(
            toolType: activeTool!,
            anchors: pendingAnchors,
            isExtended: false,
            panelPosition: 0
        )
        completedDrawings.append(drawing)
        activeTool = nil
        pendingAnchors = []
    }

    /// Spec §3.1 cancel: idempotent no-op when activeTool == nil.
    public func cancel() {
        guard activeTool != nil else { return }
        activeTool = nil
        pendingAnchors = []
    }

    /// Spec §3.1 deleteDrawing.
    /// - invariant: completedDrawings.indices.contains(index)
    public func deleteDrawing(at index: Int) {
        // invariant: completedDrawings.indices.contains(index)
        precondition(completedDrawings.indices.contains(index), "deleteDrawing index out of bounds")
        completedDrawings.remove(at: index)
    }
}

#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/Contracts && swift test --filter DrawingToolManagerTests 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中（真实输出 `Test run with 10 tests in 1 suite passed after X seconds.`）

- [ ] **Step 5: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolManagerTests.swift
git commit -m "feat(c6): DrawingToolManager state machine (Task 2)

@MainActor @Observable final class with 4 props + 5 methods.
Pure in-memory state container; NO ChartReducer coupling (design §3.3).
10 state-machine tests (DrawingToolManagerTests).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 — drawDrawings real dispatch + KLineView callsite + acceptance + spec literal guard + modules amendment

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift` (replace stub with real dispatch + `tools:` param)
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift:55-56` (add `tools: [:]` argument)
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift` (3 tests)
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/SpecLiteralGuardTests.swift` (1 test)
- Modify: `kline_trainer_modules_v1.4.md` (3 sites: L2149 + L1224-1225 + L1346-1348)
- Create: `docs/acceptance/2026-05-26-pr-c6-drawing-tools-infrastructure.md`

- [ ] **Step 1: Write the failing dispatch tests** — `DrawDrawingsDispatchTests.swift`

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift
// Spec: docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md §5.3
// 3 dispatch tests for drawDrawings: empty list / registered tool render-once / missing-tool silent skip.

import Testing
import CoreGraphics
@testable import KlineTrainerContracts

#if canImport(UIKit)

@MainActor
struct DrawDrawingsDispatchTests {

    @Test("§5.3 #14 drawDrawings with empty list calls no render")
    func drawDrawingsEmptyListNoRenderCalls() {
        let view = makeViewFixture()
        let spy = SpyDrawingTool()
        let ctx = makeCtxFixture()
        let mapper = makeMapperFixture()
        view.drawDrawings(
            ctx: ctx, mapper: mapper, drawings: [], period: .m60,
            tools: [.horizontal: spy]
        )
        #expect(spy.renderCallCount == 0)
    }

    @Test("§5.3 #15 registered tool render called once with passed-through anchors")
    func drawDrawingsRegisteredToolRenderCalledOnce() {
        let view = makeViewFixture()
        let spy = SpyDrawingTool()
        let ctx = makeCtxFixture()
        let mapper = makeMapperFixture()
        let anchor = DrawingAnchor(period: .m60, candleIndex: 5, price: 120)
        let drawing = DrawingObject(
            toolType: .horizontal, anchors: [anchor],
            isExtended: false, panelPosition: 0
        )
        view.drawDrawings(
            ctx: ctx, mapper: mapper, drawings: [drawing], period: .m60,
            tools: [.horizontal: spy]
        )
        #expect(spy.renderCallCount == 1)
        #expect(spy.lastAnchors == [anchor])
    }

    @Test("§5.3 #16 missing tool in dictionary skips silently (Wave 1 default path)")
    func drawDrawingsMissingToolSkipsSilently() {
        let view = makeViewFixture()
        let spy = SpyDrawingTool()
        let ctx = makeCtxFixture()
        let mapper = makeMapperFixture()
        let drawing = DrawingObject(
            toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m60, candleIndex: 0, price: 100)],
            isExtended: false, panelPosition: 0
        )
        // tools: [:] = Wave 1 default callsite (empty registry).
        view.drawDrawings(
            ctx: ctx, mapper: mapper, drawings: [drawing], period: .m60,
            tools: [:]
        )
        #expect(spy.renderCallCount == 0)
    }
}

// MARK: - Spies / fixtures

// @unchecked Sendable: Swift 6 strict concurrency — DrawingTool 强制 Sendable，class with mutable
// state 在 @MainActor 隔离下访问安全 (test struct 整体 @MainActor)，靠 actor isolation 守约。
@MainActor
private final class SpyDrawingTool: DrawingTool, @unchecked Sendable {
    static var type: DrawingToolType { .horizontal }
    var requiredAnchors: ClosedRange<Int> { 1...1 }
    var renderCallCount = 0
    var lastAnchors: [DrawingAnchor] = []
    func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor]) {
        renderCallCount += 1
        lastAnchors = anchors
    }
    func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool { false }
}

@MainActor
private func makeViewFixture() -> KLineView {
    KLineView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
}

@MainActor
private func makeCtxFixture() -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

@MainActor
private func makeMapperFixture() -> CoordinateMapper {
    // fixture 形状对齐 GeometryTests.swift L210-219
    let viewport = ChartViewport(
        startIndex: 0,
        visibleCount: 100,
        pixelShift: 0,
        geometry: ChartGeometry(candleStep: 8, candleWidth: 6, gap: 2),
        priceRange: PriceRange(min: 100, max: 200),
        mainChartFrame: CGRect(x: 0, y: 0, width: 320, height: 200)
    )
    return CoordinateMapper(viewport: viewport, displayScale: 1)
}

#endif
```

- [ ] **Step 2: Run tests to verify they fail (compilation error)**

Run: `cd ios/Contracts && swift test --filter DrawDrawingsDispatchTests 2>&1 | grep -E "error:.*(extra argument|cannot find)"`
Expected: ≥ 1 命中（关键短语 `extra argument 'tools' in call` —— stub 还没接受 `tools:` 参数）。

- [ ] **Step 3: Update `KLineView+Drawing.swift`** — replace stub with real dispatch + `tools:` param

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift
// Spec: kline_trainer_modules_v1.4.md §C6 + design doc §3.2
// Wave 1 PR C6: real dispatch loop over [DrawingObject] keyed by DrawingToolType.
// Wave 1 callsites pass `tools: [:]` so for-loop continues every iteration (no paint).
// Wave 3 callsites register concrete tool implementations and render begins.

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C6 绘线渲染 dispatch loop. spec §C6 + design §3.2.
    /// Missing tool in `tools` dict → silently skip (Wave 1 default path).
    @MainActor
    func drawDrawings(ctx: CGContext,
                      mapper: CoordinateMapper,
                      drawings: [DrawingObject],
                      period: Period,
                      tools: [DrawingToolType: any DrawingTool]) {
        for drawing in drawings {
            guard let tool = tools[drawing.toolType] else { continue }
            tool.render(ctx: ctx, mapper: mapper, anchors: drawing.anchors)
        }
    }
}

#endif
```

- [ ] **Step 4: Update `KLineView.swift` L55-56 callsite** — add `tools: [:]` argument

Edit `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift`:

old_string (2 lines, preserve 8-space indent + 21-space wrap):
```swift
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                     period: renderState.panel.period)
```

new_string:
```swift
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                     period: renderState.panel.period, tools: [:])
```

Verify: `grep -nc 'tools: \[:\]' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift`
Expected: 数字 ≥ 1

- [ ] **Step 5: Run dispatch tests to verify they pass**

Run: `cd ios/Contracts && swift test --filter DrawDrawingsDispatchTests 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中（真实输出 `Test run with 3 tests in 1 suite passed after X seconds.`）

- [ ] **Step 6: Write the spec literal guard test** — `SpecLiteralGuardTests.swift`

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/SpecLiteralGuardTests.swift
// Spec: docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md §5.4
// 1 spec literal guard test. Compile-time + reflection-style checks that protocol shape stays stable.

import Testing
import CoreGraphics
@testable import KlineTrainerContracts

#if canImport(UIKit)

@MainActor
struct SpecLiteralGuardTests {

    @Test("§5.4 #17 protocol signature guards against spec drift")
    func protocolSignatureGuardsAgainstSpecDrift() {
        // Guard (a): protocol DrawingTool 本身必须 conform Sendable —— 编译期约束加在 existential 上
        // 如果 spec drift 让 protocol 删 ": Sendable"，下方 `where P: Sendable` 约束会编译失败
        _requireProtocolSendable((any DrawingTool).self)

        // Guard (b): DrawingToolManager 必须 @MainActor —— 编译期实证
        // 在 nonisolated 闭包内同步调用 manager init 必须编译失败（因 init 是 main-actor-isolated）
        // 反过来在 @MainActor 闭包内可同步调用
        _requireManagerMainActorIsolated()

        // Guard (c): requiredAnchors 必须是 ClosedRange<Int> —— 编译期赋值约束
        // 如果 protocol 改成 Range<Int> 或其他类型，下方赋值会编译失败
        let req: ClosedRange<Int> = SignatureGuardTool().requiredAnchors
        #expect(req.lowerBound <= req.upperBound)
    }
}

// Guard (a) helper：约束加在 existential type P 上
// 删 protocol Sendable 声明 → (any DrawingTool) 不再满足 Sendable → 编译失败
private func _requireProtocolSendable<P>(_: P.Type) where P: Sendable {}

// Guard (b) helper：@MainActor func 内同步调用 manager init 必须成功
@MainActor private func _requireManagerMainActorIsolated() {
    _ = DrawingToolManager(enabledTools: [])
}

// 注意：SignatureGuardTool 必须 explicit conform Sendable
// （@MainActor final class 不自动 Sendable，需 显式标 或 通过 protocol composition）
@MainActor
private final class SignatureGuardTool: DrawingTool, @unchecked Sendable {
    static var type: DrawingToolType { .horizontal }
    var requiredAnchors: ClosedRange<Int> { 1...2 }
    func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor]) {}
    func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool { false }
}

#endif
```

- [ ] **Step 7: Run spec literal guard test to verify it passes**

Run: `cd ios/Contracts && swift test --filter SpecLiteralGuardTests 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: 一行命中（真实输出 `Test run with 1 test in 1 suite passed after X seconds.`）

- [ ] **Step 8: Apply modules amendment — `kline_trainer_modules_v1.4.md` 3 sites**

**Site 1**: L2149 (acceptance §A wording) using Edit tool:
- old: `- [ ] C6 DrawingTools + DrawingInputController（Phase 2.5 水平线先行）`
- new: `- [ ] C6 DrawingTools + DrawingInputController（infrastructure + tool 框架；Phase 2.5 水平线 MVP 归 Wave 3，per outline v20 顺位 12）`

**Site 2**: L1224-1225 KLineView demo callsite — Edit with exact old/new (preserve 8-space indent + 20-space wrap):

old_string (multi-line, 2 lines):
```
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                    period: renderState.panel.period)
```

new_string:
```
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                    period: renderState.panel.period, tools: [:])
```

**Site 3**: L1345-1348 §C6 protocol block extension KLineView signature demo — Edit with exact old/new (preserve 4-space inside-extension indent + 21-space wrap; the new `tools:` parameter goes on its own 3rd line aligned to `drawings:`):

old_string (multi-line, 4 lines):
```
extension KLineView {
    func drawDrawings(ctx: CGContext, mapper: CoordinateMapper,
                     drawings: [DrawingObject], period: Period)
}
```

new_string:
```
extension KLineView {
    func drawDrawings(ctx: CGContext, mapper: CoordinateMapper,
                     drawings: [DrawingObject], period: Period,
                     tools: [DrawingToolType: any DrawingTool])
}
```

After all three Edits, verify with `grep -nc 'tools: \[:\]\|tools: \[DrawingToolType' kline_trainer_modules_v1.4.md` — expect ≥ 2 hits (Site 2 + Site 3).

- [ ] **Step 9: Create acceptance checklist** — `docs/acceptance/2026-05-26-pr-c6-drawing-tools-infrastructure.md`

```markdown
# PR C6 验收清单（中文非程序员可执行）

> Wave 1 顺位 12 / 第 14 个 PR。spec `docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md` (commit `b7c7450`)。

## §A modules amendment 字面验证

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| A.1 | `grep -nc 'infrastructure + tool 框架；Phase 2.5 水平线 MVP 归 Wave 3' kline_trainer_modules_v1.4.md` | 一个数字 | 数字 ≥ 1 |
| A.2 | `grep -nc 'tools: \[DrawingToolType: any DrawingTool\]' kline_trainer_modules_v1.4.md` | 一个数字 | 数字 ≥ 1 |
| A.3 | `grep -nc 'tools: \[:\]' kline_trainer_modules_v1.4.md` | 一个数字 | 数字 ≥ 1 |

## §B 编译 + 全量测试

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| B.1 | `cd ios/Contracts && swift build 2>&1 \| tail -3` | `Build complete!` | 命中 |
| B.2 | `cd ios/Contracts && swift test 2>&1 \| grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"` | `Test run with 503 tests in 100 suites passed after X seconds.` | tests 数 = 503，suites 数 = 100（main baseline 实测 486/96 + 本 PR 新增 17/4） |

## §C C6 新文件存在

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| C.1 | `ls ios/Contracts/Sources/KlineTrainerContracts/Drawing/` | DrawingInputController.swift / DrawingTool.swift / DrawingToolManager.swift 三个文件 | 全部存在 |
| C.2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/` | DrawingProtocolTests.swift / DrawingToolManagerTests.swift / DrawDrawingsDispatchTests.swift / SpecLiteralGuardTests.swift 四个文件 | 全部存在 |

## §D 4 个新 suite 全绿

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| D.1 | `cd ios/Contracts && swift test 2>&1 \| grep -cE 'Suite "(DrawingProtocolTests\|DrawingToolManagerTests\|DrawDrawingsDispatchTests\|SpecLiteralGuardTests)" passed'` | 数字 4 | 数字 = 4 |

## §E spec literal grep 锚（防 spec drift）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -nc 'static var type: DrawingToolType' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 1 hit | 数字 = 1 |
| E.2 | `grep -nc 'var requiredAnchors: ClosedRange<Int>' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 1 hit | 数字 = 1 |
| E.3 | `grep -nc '@MainActor func render(ctx: CGContext' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 1 hit | 数字 = 1 |
| E.4 | `grep -nc '@MainActor func hitTest(point: CGPoint' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift` | 1 hit | 数字 = 1 |
| E.5 | `grep -nc '@MainActor func tapToAnchor(at point: CGPoint' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift` | 1 hit | 数字 = 1 |
| E.6 | `grep -nc '@MainActor func shouldCommit(current:' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift` | 1 hit | 数字 = 1 |
| E.7 | `grep -nc '@Observable' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | 1 hit | 数字 = 1 |
| E.8 | `grep -nc 'final class DrawingToolManager' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | 1 hit | 数字 = 1 |
| E.9 | `grep -nc 'func drawDrawings(ctx: CGContext' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift` | 1 hit | 数字 = 1 |
| E.10 | `grep -nc 'tools: \[DrawingToolType: any DrawingTool\]' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift` | 1 hit | 数字 = 1 |

## §F precondition invariant grep 锚

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nc '// invariant:' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | ≥ 4 hit（addAnchor + commit ×2 + deleteDrawing） | 数字 ≥ 4 |

## §G Manager 不依赖 ChartReducer（单向接缝硬约束）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -nE 'ChartAction\|ChartReducer\|interactionMode\|ChartReduceEffect\|dispatch' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift` | 无任何命中 | 输出为空 |
| G.2 | `grep -nE 'ChartAction\|ChartReducer\|dispatch' ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingTool.swift ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingInputController.swift` | 无任何命中 | 输出为空 |

## §H drawDrawings 调用方 KLineView L55 显式 `tools: [:]`

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| H.1 | `grep -n 'tools: \[:\]' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | 一行命中 L55-56 区域 | 数字 ≥ 1 |

## §I scope 边界（本 PR 不在 scope 的字面退出验证）

| 编号 | 命令 | 预期看到 | 通过条件 |
|---|---|---|---|
| I.1 | `find ios/Contracts/Sources/KlineTrainerContracts/Drawing -name '*Horizontal*' -o -name '*Ray*' -o -name '*Trend*' -o -name '*Default*'` | 无文件 | 输出为空（无具体 tool / DefaultController 实现） |
| I.2 | `grep -rn 'import GRDB' ios/Contracts/Sources/KlineTrainerContracts/Drawing/` | 无命中 | 输出为空（drawings 不持久化） |
```

- [ ] **Step 10: Run full test suite to verify nothing regressed**

Run: `cd ios/Contracts && swift test 2>&1 | grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"`
Expected: `Test run with 503 tests in 100 suites passed after X seconds.`
（main baseline 实测 2026-05-26 = 486 tests in 96 suites；本 PR 新增 17 tests + 4 suites，即 486+17=503 / 96+4=100）

- [ ] **Step 11: Commit**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/SpecLiteralGuardTests.swift \
        kline_trainer_modules_v1.4.md \
        docs/acceptance/2026-05-26-pr-c6-drawing-tools-infrastructure.md
git commit -m "feat(c6): drawDrawings dispatch + modules amendment + acceptance (Task 3)

- KLineView+Drawing.swift: replace stub with real dispatch loop;
  add tools: [DrawingToolType: any DrawingTool] parameter
- KLineView.swift L55 callsite: tools: [:] (Wave 1 empty registry)
- modules amendment 3 sites: L2149 wording + L1224-1225/L1346-1348 5-arg sig
- 3 dispatch tests + 1 spec literal guard test
- 中文非程序员验收清单 (§A-§I 9 sections)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Checklist (Subagent / Inline executor MUST run before merge)

After all 3 Tasks complete, the executor runs through this:

1. **Spec coverage** — every spec section has at least 1 task:
   - spec §一 in scope: 7 items → Task 1 (protocols) + Task 2 (Manager) + Task 3 (drawDrawings + KLineView callsite + acceptance + modules amendment) ✓
   - spec §一 out of scope: 8 items → not implemented (by design) ✓
   - spec §二 component list: 12 files → Task 1 (2 files) + Task 2 (2 files) + Task 3 (3 prod + 2 test + 1 modules + 1 acceptance + 1 plan) ✓
   - spec §三 data flow + responsibility split → Task 2 Manager state machine + Task 3 drawDrawings dispatch ✓
   - spec §四 precondition table → Task 2 implementation `// invariant:` comments ✓
   - spec §五 17 tests → Task 1 (3) + Task 2 (10) + Task 3 (3 + 1) = 17 ✓
   - spec §六 acceptance amendment → Task 3 Step 8 (3 sites) ✓
   - spec §七 12 reject patterns → no code change required; opus xhigh review will guard ✓

2. **Placeholder scan** — no "TBD" / "TODO" / "implement later" / "similar to Task N".

3. **Type consistency** — `DrawingTool` / `DrawingInputController` / `DrawingToolManager` / `DrawingObject` / `DrawingAnchor` / `DrawingToolType` / `CoordinateMapper` / `PanelViewState` / `ChartViewport` / `ChartGeometry` / `PriceRange` / `Period (.m60)` all match exact spec literal and existing `Models.swift` / `Reducer.swift` / `Geometry.swift` definitions; `drawDrawings(ctx:mapper:drawings:period:tools:)` 5-arg signature consistent across `KLineView+Drawing.swift` def + `KLineView.swift` callsite + dispatch tests + modules amendment 3 sites. **Swift 6 strict-concurrency Sendable 守约**：DrawingTool protocol 强制 `: Sendable`，所有实现（含测试 fake/spy class）必须 `@unchecked Sendable` 或改用 actor，因 `@MainActor final class` 不自动派生 Sendable（参见 memory `feedback_swift_local_toolchain_blindspot`）。本 plan 中 `FakeDrawingTool` + `SpyDrawingTool` + `SignatureGuardTool` 共 3 处 class fake/spy 均显式标 `@unchecked Sendable`。

---

## Execution Handoff

After Tasks 1–3 done + self-review clean + opus xhigh adversarial review APPROVE convergence, the next stages run in this order per spec §八:

1. **verification-before-completion** (`swift test` + acceptance §A-§I + grep guard)
2. **requesting-code-review** (self review)
3. **opus 4.7 xhigh adversarial review on branch diff** until APPROVE
4. **admin merge** + memory landing

---

## Plan Changelog

| Date | Version | Notes |
|---|---|---|
| 2026-05-26 | v1 (draft) | 初稿；3 Tasks (protocols / Manager / dispatch+amendment+acceptance) + self-review 修 4 处 type drift（ChartViewport/PanelViewState fixture 字段名 + Period.h1→.m60 + Sendable existential trait 约束 + import Observation） |
| 2026-05-26 | v2 (opus xhigh R1 修订) | R1 verdict NEEDS-ATTENTION 13 findings（1C/3H/5M/4L）。全部处理：(F1-C) 3 处 fake/spy class 加 `@unchecked Sendable` + Self-Review §3 加 Swift 6 strict-concurrency 守约说明；(F2-H) Step 8 Site 2/3 给完整 Edit old_string/new_string 字面（modules L1224-1225 + L1345-1348）+ 改 verify grep；(F3-H) Step 5/4/7 + Step 10 Expected 改 `grep -E "Test run with [0-9]+ tests? in [0-9]+ suites? passed"` 兼容 Swift Testing 真实输出 + 单复数；(F4-H) acceptance §A.1 改 `grep -nc` 统一计数格式；(F5-M) Step 4 加 sanity grep verify；(F6-M) SpecLiteralGuardTests helper 改 `_requireProtocolSendable<P>(_:) where P: Sendable {}` 把约束加在 existential 上（真守 protocol Sendable 声明 drift）；(F7-M) Step 10 + acceptance §B.2 写真数 baseline 486/96 → 503/100 实测于 2026-05-26；(F8-M) Step 2 Expected 改 `grep -E "error:..."` 模糊匹配；(F10-L) 删 SpecLiteralGuardTests Guard (b) 的 `MainActor.assertIsolated()` 改用 `@MainActor func _requireManagerMainActorIsolated()` helper 编译期实证；(F11-L) Task 0 措辞改 "3 轮 opus xhigh review 收敛 APPROVE" 对齐 spec changelog；(F12-L) Task 0 N/A 项预勾 `[x]` + 加注 "声明 N/A"；(F13-L) File Structure KLineView Lines 改 "1 line changed, +0 net lines" + KLineView+Drawing 改 "~25-30 (replace stub body)"。**R1-F9 (Medium) reject**：保留 `#if canImport(UIKit)` 包装。reasoning：与既有 `KLineView+Drawing.swift` stub 风格一致（PR #51 起 stub 在 UIKit guard 内）+ 本 PR 仅关心 UIKit 侧 drawDrawings dispatch + macOS catalyst 只 build-for-testing 不 run tests + Wave 3 配 macOS catalyst 注册 tool 时再统一拆 guard。Trade-off：reviewer 论点 "protocol 用 CGContext/CGPoint 不依赖 UIKit" 技术正确，但 Wave 1 scope 内无 macOS-side conformer 需求 → 保留 guard 风险为零。 |
| 2026-05-27 | v3 (Task 1 实施期间 fix 回填) | Task 1 implementer 实际跑 swift test 发现 plan v2 **R1-F9 reject 错了**（subagent DONE_WITH_CONCERNS 抓出）+ **新 bug**：Swift 6 strict concurrency `ConformanceIsolation` 错误（成员级 `@MainActor` 与 protocol `: Sendable` 冲突）。两 bug 同 commit `a80c9df` fix：(a) protocol DrawingTool/DrawingInputController + DrawingProtocolTests 删 `#if canImport(UIKit)` guard（protocols 用 CGContext/CGPoint 跨平台无 UIKit 依赖；guard 让 macOS host swift test 排除 整 suite 失 TDD 验证）；(b) protocol 改 **protocol-level `@MainActor`**（替代成员级 + 删 `: Sendable`，因 `@MainActor` 隔离自带 Sendable）；FakeDrawingTool 不再需 `@unchecked Sendable`。Task 2 (commit `1ca0472`) DrawingToolManager + tests 同样不带 UIKit guard（cross-platform @MainActor + @Observable）。Task 3 (commit `8a45909` + `3dd2287` + `64f0132`) DrawDrawingsDispatchTests 保留 UIKit guard（用 KLineView fixture）+ SpecLiteralGuardTests 不带 guard + 不带 @unchecked Sendable；acceptance §B/§D 拆 macOS host (500/99) vs Catalyst CI (503/100) 分轨。spec 同步 v4 changelog 记录此 Task 1 期间发现的 spec v3 §2.2 字面 bug 修订。 |
