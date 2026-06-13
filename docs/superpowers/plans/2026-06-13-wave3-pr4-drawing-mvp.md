# Wave 3 顺位 4 — 水平线绘线 MVP 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 接通水平线绘线全链路——用户点"水平线"按钮进入绘线模式、点图表落一条横价线、横线投影进 `engine.drawings`（单一真相）并渲染、跨缩放/平移/save-resume 还原。

**Architecture:** 大部分链路已 ship（reducer FSM / `activateDrawingTool` / `appendDrawing` / 持久化 / 恢复 / 手势 `drawingMode`+`onTap`）。本 plan 补 5 个缺口：①`HorizontalLineTool`（渲染）②`DefaultDrawingInputController`（point→anchor 逆映射）③`engine.commitDrawing/cancelDrawing`（reducer `.drawing` 退出，user 2026-06-13 裁决 supersede neck-doctrine）④`KLineView` tool 注册 + `RenderStateBuilder` panelPosition 过滤 ⑤`ChartContainerView.Coordinator` onTap 接线 + `TrainingView` toggle 按钮。纯逻辑（①②③④ + E2E）host 全测；UIKit 壳（KLineView/Coordinator/TrainingView）Catalyst build-for-testing 闸门 + 运行时 runbook。

**Tech Stack:** Swift 6 / SwiftPM (`ios/Contracts`) / Swift Testing (`import Testing`, `@Test`, `#expect`) / CoreGraphics / UIKit（`#if canImport(UIKit)` 平台门）/ Mac Catalyst CI。

**Spec:** `docs/superpowers/specs/2026-06-13-wave3-pr4-drawing-mvp-design.md`（已经 opus 4.8 xhigh 对抗性 review R2 APPROVE）。

---

## File Structure

**新增 prod（2）**
- `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift` — 横线 `DrawingTool`（render + hitTest + 纯几何 helper）
- `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DefaultDrawingInputController.swift` — `DrawingInputController`（tapToAnchor 逆映射 + shouldCommit）

**修改 prod（5）**
- `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` — 加 `commitDrawing(panel:)`/`cancelDrawing(panel:)`（appendDrawing 旁）
- `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:41` — `drawings:` 按 panelPosition 过滤
- `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift:55-56` — 注册 `[.horizontal: HorizontalLineTool()]`
- `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift` — Coordinator 持 manager+inputController、sync 对齐、onTap 接线
- `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` — "水平线" toggle 按钮（gated by canBuySell）

**新增/扩展 test（4）**
- `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift`（新）
- `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DefaultDrawingInputControllerTests.swift`（新）
- `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift`（新）
- 扩 `Render/RenderStateBuilderTests.swift`（panelPosition 过滤）+ 扩 `TrainingSessionPersistenceTests.swift`（drawing E2E resume）

**新增 doc（2，Task 9）**
- `docs/acceptance/2026-06-13-wave3-pr4-drawing-mvp.md`（非-coder 验收 + 运行时 runbook 条目）

**约定**：所有 `swift test` 在 `ios/Contracts/` 目录跑。Catalyst：`xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`。基线：908 tests / 127 suites 全绿。

---

## Task 1: HorizontalLineTool（横线渲染 + hitTest，host 可测）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift`

- [ ] **Step 1: 写失败测试**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("HorizontalLineTool")
struct HorizontalLineToolTests {

    // 已知视口：mainChartFrame x∈[0,800] y∈[0,360]（split 60% of 600），price∈[10,20]。
    static func mapper() -> CoordinateMapper {
        let main = CGRect(x: 0, y: 0, width: 800, height: 360)
        let vp = ChartViewport(
            startIndex: 0, visibleCount: 80, pixelShift: 0,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 10, max: 20), mainChartFrame: main)
        return CoordinateMapper(viewport: vp, displayScale: 2.0)
    }

    @Test("type == .horizontal / requiredAnchors == 1...1")
    func metadata() {
        #expect(HorizontalLineTool.type == .horizontal)
        #expect(HorizontalLineTool().requiredAnchors == 1...1)
    }

    @Test("lineY: 横线 y == mapper.priceToY(anchor.price)")
    func lineYMatchesPriceToY() {
        let m = Self.mapper()
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)]
        let y = HorizontalLineTool().lineY(anchors: anchors, mapper: m)
        #expect(y == m.priceToY(15))
    }

    @Test("lineY: 空 anchors → nil（无可画）")
    func lineYEmptyNil() {
        #expect(HorizontalLineTool().lineY(anchors: [], mapper: Self.mapper()) == nil)
    }

    @Test("hitTest: 命中（point.y 接近横线 y，容差内）")
    func hitTestHit() {
        let m = Self.mapper()
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)]
        let y = m.priceToY(15)
        #expect(HorizontalLineTool().hitTest(point: CGPoint(x: 400, y: y + 2),
                                             mapper: m, anchors: anchors) == true)
    }

    @Test("hitTest: 未命中（远离横线 y，超容差）")
    func hitTestMiss() {
        let m = Self.mapper()
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)]
        let y = m.priceToY(15)
        #expect(HorizontalLineTool().hitTest(point: CGPoint(x: 400, y: y + 50),
                                             mapper: m, anchors: anchors) == false)
    }

    @Test("hitTest: 空 anchors → false")
    func hitTestEmptyFalse() {
        #expect(HorizontalLineTool().hitTest(point: .zero, mapper: Self.mapper(), anchors: []) == false)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter HorizontalLineTool`
Expected: 编译失败（`HorizontalLineTool` 未定义）。

- [ ] **Step 3: 写最小实现**

Create `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift`:

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift
// Spec: docs/superpowers/specs/2026-06-13-wave3-pr4-drawing-mvp-design.md §一.1 + D-CROSSPERIOD
// Wave 3 顺位 4：唯一具体 DrawingTool（水平线 MVP）。横线仅 price 承重（周期无关），
// candleIndex 不参与 render。几何抽纯 helper `lineY` host 可测；render 仅 stroke。
//
// 跨平台：仅 CoreGraphics（CGContext/CGColor/CGPoint），与 DrawingTool protocol 一致无 UIKit。

import CoreGraphics

@MainActor
public struct HorizontalLineTool: DrawingTool {
    public static var type: DrawingToolType { .horizontal }
    public var requiredAnchors: ClosedRange<Int> { 1...1 }

    public init() {}

    /// 纯几何 helper（host 可测）：横线 y = 第一锚价位映射；空 anchors → nil。
    public func lineY(anchors: [DrawingAnchor], mapper: CoordinateMapper) -> CGFloat? {
        guard let first = anchors.first else { return nil }
        return mapper.priceToY(first.price)
    }

    /// 命中容差（点）：point.y 距横线 y 在此内即命中。MVP 不接删除 UI（Phase 4）。
    private static let hitTolerance: CGFloat = 8

    public func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor]) {
        guard let y = lineY(anchors: anchors, mapper: mapper) else { return }
        let frame = mapper.viewport.mainChartFrame
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 0.95, green: 0.6, blue: 0.1, alpha: 1))  // MVP 固定橙；token 化属后续
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: frame.minX, y: y))
        ctx.addLine(to: CGPoint(x: frame.maxX, y: y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    public func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool {
        guard let y = lineY(anchors: anchors, mapper: mapper) else { return false }
        return abs(point.y - y) <= Self.hitTolerance
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter HorizontalLineTool`
Expected: PASS（6 tests）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/HorizontalLineToolTests.swift
git commit -m "Task 1: HorizontalLineTool（横线 DrawingTool + 纯几何 helper + 6 host 测）"
```

---

## Task 2: DefaultDrawingInputController（point→anchor 逆映射，host 可测）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DefaultDrawingInputController.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DefaultDrawingInputControllerTests.swift`

- [ ] **Step 1: 写失败测试**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DefaultDrawingInputControllerTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DefaultDrawingInputController")
struct DefaultDrawingInputControllerTests {

    // mutation-sanity：用**非零** pixelShift + 非默认 startIndex 的视口，证逆映射在真实平移下成立（非空洞恒等）。
    static func mapper(pixelShift: CGFloat = 3, startIndex: Int = 12) -> CoordinateMapper {
        let main = CGRect(x: 0, y: 0, width: 800, height: 360)
        let vp = ChartViewport(
            startIndex: startIndex, visibleCount: 80, pixelShift: pixelShift,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 10, max: 20), mainChartFrame: main)
        return CoordinateMapper(viewport: vp, displayScale: 2.0)
    }

    static func panel(period: Period = .m60) -> PanelViewState {
        PanelViewState(period: period, interactionMode: .autoTracking,
                       visibleCount: 80, offset: 0, revision: 0)
    }

    @Test("tapToAnchor: period 取自 panel，candleIndex/price 取自 mapper 逆映射")
    func tapToAnchorMapsCorrectly() {
        let m = Self.mapper()
        let p = Self.panel(period: .m60)
        let point = CGPoint(x: 235, y: 144)
        let anchor = DefaultDrawingInputController().tapToAnchor(at: point, panel: p, mapper: m)
        #expect(anchor.period == .m60)
        #expect(anchor.candleIndex == m.xToIndex(235))
        #expect(anchor.price == m.yToPrice(144))
    }

    @Test("tapToAnchor: round-trip —— 由 anchor 映回的 x/y 落回同一 candle/价位（非零 pixelShift 下）")
    func tapToAnchorRoundTrips() {
        let m = Self.mapper(pixelShift: 3, startIndex: 12)
        let p = Self.panel()
        // 取一个落在某 candle 中心的 x：indexToX(15)；以及一个已知价位 y：priceToY(15.5)
        let x = m.indexToX(15)
        let y = m.priceToY(15.5)
        let anchor = DefaultDrawingInputController().tapToAnchor(at: CGPoint(x: x, y: y), panel: p, mapper: m)
        #expect(anchor.candleIndex == 15)                       // xToIndex∘indexToX 恒等（含非零 pixelShift）
        #expect(abs(anchor.price - 15.5) < 1e-9)                // yToPrice∘priceToY 恒等
    }

    @Test("shouldCommit: horizontal 1 锚 → true")
    func shouldCommitHorizontalOneAnchor() {
        let anchors = [DrawingAnchor(period: .m3, candleIndex: 0, price: 10)]
        #expect(DefaultDrawingInputController().shouldCommit(current: anchors, tool: .horizontal) == true)
    }

    @Test("shouldCommit: horizontal 0 锚 → false")
    func shouldCommitHorizontalZeroAnchor() {
        #expect(DefaultDrawingInputController().shouldCommit(current: [], tool: .horizontal) == false)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DefaultDrawingInputController`
Expected: 编译失败（`DefaultDrawingInputController` 未定义）。

- [ ] **Step 3: 写最小实现**

Create `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DefaultDrawingInputController.swift`:

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DefaultDrawingInputController.swift
// Spec: docs/superpowers/specs/2026-06-13-wave3-pr4-drawing-mvp-design.md §一.2 + §四
// Wave 3 顺位 4：具体 DrawingInputController。tapToAnchor 经 CoordinateMapper 逆映射；
// shouldCommit 经显式 enum→最小锚数映射（requiredAnchors 在 DrawingTool 实例非 enum，评审 R2-L）。
//
// 跨平台：CoreGraphics + 跨平台值类型；无 UIKit。protocol 是 @MainActor → 本类 @MainActor final class。

import CoreGraphics

@MainActor
public final class DefaultDrawingInputController: DrawingInputController {
    public init() {}

    public func tapToAnchor(at point: CGPoint, panel: PanelViewState, mapper: CoordinateMapper) -> DrawingAnchor {
        DrawingAnchor(period: panel.period,
                      candleIndex: mapper.xToIndex(point.x),
                      price: mapper.yToPrice(point.y))
    }

    /// MVP 显式映射 enum→最小锚数（requiredAnchors 是 tool 实例属性、非 enum 可达）。
    private func minAnchors(for tool: DrawingToolType) -> Int {
        switch tool {
        case .horizontal: return 1
        // 其余 6 工具属 Phase 4（enabledTools 仅 .horizontal，不会到达）。
        case .ray, .trend, .golden, .wave, .cycle, .time: return Int.max
        }
    }

    public func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool {
        current.count >= minAnchors(for: tool)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter DefaultDrawingInputController`
Expected: PASS（4 tests）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DefaultDrawingInputController.swift ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DefaultDrawingInputControllerTests.swift
git commit -m "Task 2: DefaultDrawingInputController（tapToAnchor 逆映射 + shouldCommit + 4 host 测含非零 pixelShift round-trip）"
```

---

## Task 3: engine commitDrawing/cancelDrawing（reducer .drawing 退出，host 可测）

> user 2026-06-13 裁decision supersede neck-doctrine（spec §D-ENGINE + RFC §4.4 总纲注记）：这两方法是 `activateDrawingTool`（C8b）激活-FSM handler 家族的兄弟，正交顺位-6 业务面。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（drawing extension，`appendDrawing` 旁，约 :729 后）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift`

- [ ] **Step 1: 写失败测试**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift`:

```swift
// Wave 3 顺位 4：engine 画线 FSM 退出（commitDrawing/cancelDrawing）。
// 复用 TrainingEngineInteractionTests.engine()（单 .m3 双面板 + fake 驱动）。
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("TrainingEngine drawing commit/cancel（FSM 退出，Wave 3 顺位 4）")
struct TrainingEngineDrawingCommitTests {

    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// 进入 .drawing 的 engine（activateDrawingTool 已验证进 drawing）。
    static func drawingEngine() -> TrainingEngine {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.activateDrawingTool(.horizontal, panel: .upper)
        return e
    }

    @Test("commitDrawing: .drawing → .autoTracking + revision 不变（核 Reducer:203-208 不 bump）")
    func commitExitsToAutoTrackingNoRevisionBump() {
        let e = Self.drawingEngine()
        guard case .drawing = e.upperPanel.interactionMode else { Issue.record("应在 drawing"); return }
        let revBefore = e.upperPanel.revision
        e.commitDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision == revBefore)             // commit 不 bump revision
    }

    @Test("cancelDrawing: .drawing → .autoTracking + revision 不变")
    func cancelExitsToAutoTrackingNoRevisionBump() {
        let e = Self.drawingEngine()
        let revBefore = e.upperPanel.revision
        e.cancelDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision == revBefore)
    }

    @Test("commitDrawing: 非 drawing 态 → no-op（autoTracking 不变）")
    func commitNonDrawingNoOp() {
        let (e, _) = TrainingEngineInteractionTests.engine()        // autoTracking
        let revBefore = e.upperPanel.revision
        e.commitDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.upperPanel.revision == revBefore)
    }

    @Test("cancelDrawing: 非 drawing 态 → no-op")
    func cancelNonDrawingNoOp() {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.cancelDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
    }

    @Test("append 与 commit 独立：appendDrawing 不改 mode；commitDrawing 不改 drawings")
    func appendAndCommitAreIndependent() {
        let e = Self.drawingEngine()
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.4)],
                              isExtended: true, panelPosition: 0)
        e.appendDrawing(d)
        #expect({ if case .drawing = e.upperPanel.interactionMode { return true }; return false }())  // append 不改 mode
        #expect(e.drawings == [d])
        e.commitDrawing(panel: .upper)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        #expect(e.drawings == [d])                                 // commit 不改 drawings
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter "drawing commit/cancel"`
Expected: 编译失败（`commitDrawing`/`cancelDrawing` 未定义）。

- [ ] **Step 3: 写最小实现**

In `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`, locate `appendDrawing` (约 :729). Insert AFTER it (still inside the same extension, before the closing `}`):

```swift
    /// 提交当前 drawing：dispatch reducer `.drawingCommitted` 退出 `.drawing` → `.autoTracking`
    /// （RFC §4.4 总纲注记：画线激活-FSM handler 家族，user 2026-06-13 裁决 supersede neck）。
    /// 封装 snapshot.frozen.baseRevision 细节（caller 不碰 revision）。非 drawing 态 no-op（幂等）。
    /// 不改 `drawings`（数据投影是 `appendDrawing` 的职责）；不 bump revision（reducer 契约）。
    public func commitDrawing(panel: PanelId) {
        guard case .drawing(let snap) = panelState(panel).interactionMode else { return }
        _ = reduce(.drawingCommitted(baseRevision: snap.frozen.baseRevision), on: panel)
    }

    /// 取消当前 drawing：dispatch reducer `.drawingCancelled` 退出 `.drawing` → `.autoTracking`。
    /// 非 drawing 态 no-op。无数据投影。
    public func cancelDrawing(panel: PanelId) {
        guard case .drawing(let snap) = panelState(panel).interactionMode else { return }
        _ = reduce(.drawingCancelled(baseRevision: snap.frozen.baseRevision), on: panel)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter "drawing commit/cancel"`
Expected: PASS（5 tests）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift
git commit -m "Task 3: engine commitDrawing/cancelDrawing（reducer .drawing FSM 退出 + 5 host 测；user 裁决 supersede neck）"
```

---

## Task 4: RenderStateBuilder panelPosition 过滤（横线只渲本面板，host 可测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:41`
- Test: extend `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`

- [ ] **Step 1: 写失败测试**

Append to `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（在 struct 内末尾加方法）。先确认文件顶部 `import` + suite 结构（应已有 `@testable import KlineTrainerContracts`）。加：

```swift
    // MARK: - Wave 3 顺位 4：panelPosition 过滤（横线只渲本面板）

    @Test("make: drawings 按 panelPosition 过滤 —— 上栏(0)在 .upper，下栏(1)被排除")
    func drawingsFilteredByPanelPositionUpper() {
        let (e, _) = TrainingEngineInteractionTests.engine()
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: 10)],
                                      isExtended: true, panelPosition: 0))    // 上栏
        e.appendDrawing(DrawingObject(toolType: .horizontal,
                                      anchors: [DrawingAnchor(period: .m3, candleIndex: 0, price: 11)],
                                      isExtended: true, panelPosition: 1))    // 下栏
        let rs = RenderStateBuilder.make(engine: e, panel: .upper,
                                         bounds: TrainingEngineInteractionTests.bounds)
        #expect(rs.drawings.count == 1)
        #expect(rs.drawings.allSatisfy { $0.panelPosition == 0 })            // 仅上栏；下栏被排除
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter drawingsFilteredByPanelPositionUpper`
Expected: FAIL（当前未过滤 → `rs.drawings.count == 2`）。

- [ ] **Step 3: 写最小实现**

In `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`, change line 41 inside `make`:

```swift
            drawings: engine.drawings,
```
to:
```swift
            drawings: engine.drawings.filter { $0.panelPosition == (panel == .upper ? 0 : 1) },
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter drawingsFilteredByPanelPositionUpper`
Expected: PASS。

确认既有 makeAssembles 断言（`rs.drawings == engine.drawings`，preview 无 drawings）未破：
Run: `swift test --filter RenderStateBuilder`
Expected: 全 PASS（既有 + 新增）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "Task 4: RenderStateBuilder 按 panelPosition 过滤 drawings（横线只渲本面板 + 正/负向测）"
```

---

## Task 5: drawing E2E save/resume（持久化已 ship，本测验证 resume 还原；host 可测）

> 注：持久化全链路已 ship（appendDrawing→saveProgress→pending 由既有 `appendDrawing_flowsIntoPendingPersistence` 测覆盖 save 半段；resume→initialDrawings 已实现但 drawings 字段未显式断言）。本 Task 补 **resume 还原 drawings** 的 E2E 断言。**预期首跑即 PASS**（验证既有行为的回归守卫，非 red-green）。

**Files:**
- Test: extend `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift`（复用本文件 static helper `makeCoordinator`/`validCandles`，故就地扩展而非新文件，DRY）

- [ ] **Step 1: 写测试**

Append a new `@Test` inside `TrainingSessionPersistenceTests`（在 "Wave 3 顺位 6b：appendDrawing" MARK 段附近）:

```swift
    @Test("E2E（顺位 4）: 画线 → saveProgress → endSession → resume：engine.drawings 逐字段还原")
    func drawing_saveProgress_thenResume_restoresDrawings() async throws {
        let (coord, _, _, _) = Self.makeCoordinator(candles: Self.validCandles(), capital: 50_000)
        coord.now = { 222 }
        let engine = try await coord.startNewNormalSession()
        let d = DrawingObject(toolType: .horizontal,
                              anchors: [DrawingAnchor(period: .m60, candleIndex: 3, price: 10.55)],
                              isExtended: true, panelPosition: 0)
        engine.appendDrawing(d)
        try await coord.saveProgress(engine: engine)
        await coord.endSession()
        let resumed = try #require(try await coord.resumePending())
        #expect(resumed.drawings == [d])              // resume 经 initialDrawings 逐字段还原画线
    }
```

- [ ] **Step 2: 跑测试**

Run: `swift test --filter drawing_saveProgress_thenResume_restoresDrawings`
Expected: PASS（既有持久化/恢复链路真往返 drawings；本测把 resume-还原-drawings 钉成回归守卫）。

> 若意外 FAIL：说明 resume 未还原 drawings = 既有持久化 bug，进 systematic-debugging（不在本 plan 预期内）。

- [ ] **Step 3: 提交**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift
git commit -m "Task 5: drawing E2E save/resume 回归守卫（resume 还原 engine.drawings 逐字段）"
```

---

## Task 6: KLineView 注册 HorizontalLineTool（UIKit；Catalyst 验证）

> UIKit-gated（`#if canImport(UIKit)`）→ host `swift test` 不编译此文件。本 Task 不加 host 测；编译由 Task 9 Catalyst build 验证。host 测套件须保持全绿（不受影响）。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift:55-56`

- [ ] **Step 1: 加静态 tool 注册表 + 用它**

In `KLineView.swift`, 在 `public final class KLineView: UIView {` 内（属性区，`renderState` 之后）加：

```swift
    /// Wave 3 顺位 4：注册具体 DrawingTool。MVP 单工具内联（6 种工具 + 注册表机制属 Phase 4）。
    private static let drawingTools: [DrawingToolType: any DrawingTool] = [.horizontal: HorizontalLineTool()]
```

然后把 `draw(_:)` 内（约 :55-56）：

```swift
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                     period: renderState.panel.period, tools: [:])
```
改为：
```swift
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                     period: renderState.panel.period, tools: Self.drawingTools)
```

- [ ] **Step 2: host 测仍全绿（UIKit 文件不编译，确认无回归）**

Run: `swift test 2>&1 | tail -3`
Expected: 全 PASS（KLineView 在 host 不编译，套件数不变 + 新 Task 1-5 测）。

- [ ] **Step 3: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift
git commit -m "Task 6: KLineView 注册 HorizontalLineTool（drawDrawings tools 字典；Catalyst 验证）"
```

---

## Task 7: ChartContainerView.Coordinator onTap 接线（UIKit；Catalyst 验证）

> UIKit-gated → 无 host 测；Catalyst 编译 + 运行时 runbook 验证。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`

- [ ] **Step 1: Coordinator 持 manager + inputController**

In `ChartContainerView.Coordinator`, 加属性（`arbiter` 之后）：

```swift
        /// Wave 3 顺位 4：画线输入暂存（仅 .horizontal）+ 逆映射 controller。manager 是输入暂存，
        /// engine.drawings 才是单一真相（spec §D-MANAGER）。
        private let manager = DrawingToolManager(enabledTools: [.horizontal])
        private let inputController: DrawingInputController = DefaultDrawingInputController()
```

- [ ] **Step 2: sync 对齐 manager 与 engine drawing 模式**

把现有 `sync` 末尾的 `arbiter.drawingMode = isDrawing(engine: engine, panel: panel)` 替换为：

```swift
            // drawing 模式下 arbiter 截获单指 pan（spec §C7）+ 对齐 manager.activeTool（顺位 4）。
            let drawing = isDrawing(engine: engine, panel: panel)
            arbiter.drawingMode = drawing
            if drawing {
                if manager.activeTool == nil { manager.toggle(.horizontal) }     // 进入：对齐（条件 toggle，非每帧盲翻）
            } else if manager.activeTool != nil {
                manager.cancel()                                                  // 退出：复位暂存
            }
```

- [ ] **Step 3: 接 arbiter.onTap**

把 `attach` 内的注释行：
```swift
            // onTap（画线锚点）需 DrawingInputController（顺位 4）→ 本锚不接。
```
替换为：
```swift
            arbiter.onTap = { [weak self] point in
                self?.handleDrawingTap(at: point)
            }
```

并在 Coordinator 内（`setCrosshair` 之后）加 handler：

```swift
        /// 顺位 4：drawing 模式单指点击落锚 → 投影 engine.drawings → 退出 .drawing。
        /// 全链路：tapToAnchor（逆映射）→ manager.addAnchor/commit → engine.appendDrawing → engine.commitDrawing。
        private func handleDrawingTap(at point: CGPoint) {
            guard let engine, let view else { return }
            guard isDrawing(engine: engine, panel: panel), manager.activeTool != nil else { return }
            // 空图表（candleStep==0）→ xToIndex 会 Int(NaN) 崩溃 → 守卫（spec §四 load-bearing）。
            let viewport = view.renderState.viewport
            guard viewport.geometry.candleStep > 0 else { return }
            let mapper = CoordinateMapper(viewport: viewport, displayScale: view.traitCollection.displayScale)
            let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
            let anchor = inputController.tapToAnchor(at: point, panel: ps, mapper: mapper)
            manager.addAnchor(anchor)
            guard inputController.shouldCommit(current: manager.pendingAnchors, tool: .horizontal) else { return }
            manager.commit(isExtended: true, panelPosition: panel == .upper ? 0 : 1)
            if let committed = manager.completedDrawings.last {
                engine.appendDrawing(committed)              // 投影：单一真相 engine.drawings
            }
            engine.commitDrawing(panel: panel)               // 退出 reducer .drawing
        }
```

- [ ] **Step 4: host 测仍全绿（UIKit 文件不编译）**

Run: `swift test 2>&1 | tail -3`
Expected: 全 PASS（无回归）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift
git commit -m "Task 7: ChartContainerView.Coordinator onTap 接线（manager+inputController+sync 对齐+落锚投影；Catalyst 验证）"
```

---

## Task 8: TrainingView 水平线 toggle 按钮（UIKit/SwiftUI；Catalyst 验证）

> UIKit-gated → 无 host 测；Catalyst 编译 + 运行时 runbook 验证。按钮门 = `showsTradeButtons`（canBuySell，Normal/Replay 可见、Review 隐藏，D-REVIEWMODE）。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`

- [ ] **Step 1: 加 drawing 状态/动作 + topBar 按钮**

In `TrainingView`, 加 computed + 方法（`showsTradeButtons` 之后）：

```swift
    // 顺位 4：上栏是否在画线模式（按钮选中态 + toggle 语义）。
    private var isDrawingActive: Bool {
        if case .drawing = engine.upperPanel.interactionMode { return true }
        return false
    }
    private func toggleDrawing() {
        if isDrawingActive {
            engine.cancelDrawing(panel: .upper)
        } else {
            engine.activateDrawingTool(.horizontal, panel: .upper)
        }
    }
```

在 `topBar` 的 `Button("返回") { ... }` 之后、`Spacer()` 之前插入（gated by showsTradeButtons）：

```swift
            if showsTradeButtons {
                Button(isDrawingActive ? "结束画线" : "水平线") { toggleDrawing() }
                    .tint(isDrawingActive ? .orange : nil)
            }
```

- [ ] **Step 2: host 测仍全绿（UIKit 文件不编译）**

Run: `swift test 2>&1 | tail -3`
Expected: 全 PASS。

- [ ] **Step 3: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "Task 8: TrainingView 水平线 toggle 按钮（canBuySell 门 + activate/cancelDrawing；Catalyst 验证）"
```

---

## Task 9: 全量 host 测 + Catalyst build + 验收 doc + runbook

**Files:**
- Create: `docs/acceptance/2026-06-13-wave3-pr4-drawing-mvp.md`

- [ ] **Step 1: 全量 host 测**

Run: `swift test 2>&1 | tail -5`
Expected: 全 PASS；count = 908 + 本 plan 新增（Task1 6 + Task2 4 + Task3 5 + Task4 1 + Task5 1 = 17）→ ~925 tests。0 failures。

- [ ] **Step 2: Catalyst build-for-testing（验证全部 UIKit 改动编译 + 链接）**

Run:
```bash
xcodebuild build-for-testing \
  -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -15
```
Expected: `** TEST BUILD SUCCEEDED **`。
> 若失败（如 @MainActor 隔离 / Sendable / 闭包 capture）：按报错修对应 UIKit 文件，re-run，直至 SUCCEEDED（per `feedback_swift_local_toolchain_blindspot`：本地 swift test 绿 ≠ Catalyst 绿）。

- [ ] **Step 3: 写非-coder 验收 + 运行时 runbook**

Create `docs/acceptance/2026-06-13-wave3-pr4-drawing-mvp.md`（中文，action/expected/pass-fail；禁用语见 `.claude/workflow-rules.json`；负向 grep 断言用 `grep -F` + `if ...; then exit 1` 防 set -e 死闸门，per `feedback_acceptance_grep_anchoring`）。须含：
- **静态验收**：2 新文件在 PR；`KLineView.swift` 不再含字面 `tools: [:]`（`grep -Fn 'tools: [:]'` 命中即 fail）；`engine.commitDrawing`/`cancelDrawing` 存在；RFC §4.4 含画线-FSM 例外注记。
- **测试验收**：`swift test` 全绿 + 新增 ~17；Catalyst `TEST BUILD SUCCEEDED`。
- **运行时 runbook 条目（outline §三.3「水平线绘制+跨缩放还原」）**：device/sim 手动步骤 ——
  1. 进 Normal 训练局 → 顶栏见"水平线"按钮（Review 局应无此按钮）。
  2. 点"水平线" → 按钮变"结束画线"；单指拖动图表**不**再平移（被绘线截获）。
  3. 点图表某价位 → 出现一条横线钉在该价位；按钮自动复位"水平线"（提交后退出绘线模式）。
  4. 两指 pinch 缩放 / 单指平移 → 横线**维持在原价位**（price 周期无关）。
  5. 两指上下切周期 → 横线仍在原价位（跨周期还原）。
  6. 点"返回"存档 → 重进该局（继续训练）→ 横线还原。
  7. （断言）横线只在主图（上栏），不出现在量/MACD 副图。
- 运行时实测是 user device 职责；其**完成**是顺位 13 阻塞依赖。本 PR 交付 runbook **条目**（步骤定义）。

- [ ] **Step 4: 提交**

```bash
git add docs/acceptance/2026-06-13-wave3-pr4-drawing-mvp.md
git commit -m "Task 9: 全量 host 测 + Catalyst build 验证 + 非-coder 验收 + 运行时 runbook 条目"
```

---

## 收尾（plan 外，交 superpowers:requesting-code-review + 整体 opus 4.8 xhigh 对抗性 review → 收敛 → PR）

- verification-before-completion：`swift test` 全绿 + Catalyst SUCCEEDED 的真实输出。
- requesting-code-review + 整体 opus 4.8 xhigh 对抗性 review 到收敛。
- 开 PR（标题：`Wave 3 顺位 4：水平线绘线 MVP + 画线 source-of-truth 全链路`）；codex:adversarial-review 闸门（配额耗尽走 opus xhigh fallback）；attest + admin merge ceremony。

## Spec 覆盖自检（writing-plans self-review）
- spec §一.1 HorizontalLineTool → Task 1 ✓ ｜ §一.2 DefaultDrawingInputController → Task 2 ✓
- §一.3 commit/cancelDrawing（D-ENGINE）→ Task 3 ✓ ｜ §一.4 tool 注册 + panelPosition 过滤 → Task 6 + Task 4 ✓
- §一.5 onTap 接线（manager）→ Task 7 ✓ ｜ §一.6 toggle 按钮（D-REVIEWMODE）→ Task 8 ✓
- §一.7 E2E 持久化 → Task 5 ✓ ｜ §一.8 运行时 runbook → Task 9 ✓
- §三 全 D-items（ENGINE/PANELFILTER/TOOLREG/MANAGER/BUTTON/REVIEWMODE/CROSSPERIOD/NOSPLIT）→ 各 Task 落实 ✓
- 类型一致性：`commitDrawing(panel:)`/`cancelDrawing(panel:)`/`appendDrawing(_:)`/`tapToAnchor(at:panel:mapper:)`/`shouldCommit(current:tool:)`/`lineY(anchors:mapper:)` 跨 Task 命名一致 ✓
