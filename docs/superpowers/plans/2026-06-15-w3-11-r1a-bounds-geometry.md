# W3-11-R1a：bounds 几何 helper + makeViewport 重构（行为中性）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 抽出 `geometryCore` 共享几何内核 + `offsetBounds` 纯函数（bounce 接线所需的 offset 边界），并把 `makeViewport` 重构为消费同一内核——**零运行时行为改动**（既有 makeViewport 输出逐位不变），为 R1b-wire 的 bounce 接线提供单一真相的边界来源。

**Architecture:** 纯 Render 层（`RenderStateBuilder`，平台无关，host 全测）。`geometryCore(mainFrameWidth, rawVisible, candleCount, currentIdx) → (baseStartIndex, upperBound, candleStep, visibleCount)` 是 makeViewport 现有几何派生的等价抽取；`offsetBounds` 在其上派生 `(minOffset, maxOffset, candleStep)`。makeViewport 改调 geometryCore 但 startIndex/pixelShift/slice 输出不变。**不含 overscroll 渲染（B4）+ 不碰 engine/gesture**（均 R1b-wire）。

**Tech Stack:** Swift（`KlineTrainerContracts` 包，`Render/RenderStateBuilder.swift`）；Swift Testing（`@Test`/`#expect`）；host `swift test` + Catalyst build。

**Source-of-truth:** spec `docs/superpowers/specs/2026-06-15-w3-11-r1-bounce-wiring-design.md` §二.B1 + §五.D4/D5 + §八（R1a 行为中性）。

**关键不变量（行为中性证明）**：既有 `RenderStateBuilderTests` 全部 case 重构后**逐一仍绿** = makeViewport 输出等价。R1a **不**改任何 startIndex/pixelShift/slice 输出。

**坐标模型（spec §二.B1 核实，`RenderStateBuilder.swift:58-93`）**：`target = rawVisible>0 ? rawVisible : 80`；`visibleCount = min(target, count)`；`candleStep = mainFrameWidth/target`；`baseStartIndex = currentIdx − (visibleCount−1)`；`upperBound = max(0, count − visibleCount)`；`maxOffset = baseStartIndex·candleStep`（最老边，startIndex==0 临界）；`minOffset = (baseStartIndex − upperBound)·candleStep`（最新边，startIndex==upperBound 临界，通常 <0）。

**ledger**：本 PR 业务轨**不碰** `wave3-completion.md`/`verify-wave3-completion.sh`/runtime-matrix（per 并行编排 ledger-B）。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift` | 加 `GeometryCore` 值 + `geometryCore(...)` + `offsetBounds(...)`；`makeViewport` 改调 `geometryCore` | Modify |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift` | 加 geometryCore + offsetBounds + 行为对拍 测试 | Modify |

---

## Task 1: geometryCore 内核抽取 + makeViewport 重构（行为中性）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`（`makeViewport` :58-93 + 新增 `GeometryCore`/`geometryCore`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`

- [ ] **Step 1: 跑既有 makeViewport 测试，确认 baseline 全绿（重构等价基准）**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests`
Expected: 全绿（含 `geometry`/`anchorPhysicalRightEdge`(startIndex==71)/`anchorEarlyTick`(==0)/`offsetMidScroll`(==69) 等）。记下通过数作等价基准。

- [ ] **Step 2: 写 geometryCore 直接单测（先失败）**

在 `RenderStateBuilderTests.swift` 加（用既有 `Self.candles`/`Self.bounds`；count=200,tick=150 → currentIdx=150 已由既有 `offsetMidScroll` 实证 baseStartIndex==71）：
```swift
@Test("geometryCore：count=200/currentIdx=150/width=800/rawVisible=0→80 → base=71,upper=120,step=10,vc=80")
func geometryCore_known() {
    let core = RenderStateBuilder.geometryCore(
        mainFrameWidth: ChartPanelFrames.split(in: Self.bounds).mainChart.width,
        rawVisible: 0, candleCount: 200, currentIdx: 150)
    #expect(core.visibleCount == 80)
    #expect(core.candleStep == 10)          // 800/80
    #expect(core.baseStartIndex == 71)      // 150 − 79
    #expect(core.upperBound == 120)         // 200 − 80
}
```

- [ ] **Step 3: 跑 → 失败（geometryCore 未定义）**

Run: `cd ios/Contracts && swift test --filter geometryCore_known`
Expected: 编译失败 `geometryCore` / `GeometryCore` not found（或 `.mainChart` 若需 import——`ChartPanelFrames` 同模块可达）。

- [ ] **Step 4: 实现 geometryCore + makeViewport 重构调它（行为等价）**

在 `RenderStateBuilder` enum 内加：
```swift
/// 共享几何内核（spec §二.B1 / D4 单一真相）：makeViewport 的 startIndex 派生与 offsetBounds 的边界派生
/// 都消费它，杜绝两套几何公式漂移。纯值、平台无关。
struct GeometryCore: Equatable, Sendable {
    let baseStartIndex: Int
    let upperBound: Int
    let candleStep: CGFloat
    let visibleCount: Int
}

static func geometryCore(mainFrameWidth: CGFloat, rawVisible: Int,
                         candleCount: Int, currentIdx: Int) -> GeometryCore {
    let target = rawVisible > 0 ? rawVisible : defaultVisibleCount
    let visibleCount = min(target, candleCount)
    let candleStep = mainFrameWidth / CGFloat(target)
    let baseStartIndex = currentIdx - (visibleCount - 1)
    let upperBound = max(0, candleCount - visibleCount)
    return GeometryCore(baseStartIndex: baseStartIndex, upperBound: upperBound,
                        candleStep: candleStep, visibleCount: visibleCount)
}
```
把 `makeViewport`（:60-85）的 target/visibleCount/candleStep/baseStartIndex/upperBound 五行**替换为调 geometryCore**，其余（geometry 构造、wholeShift、startIndex clamp、pixelShift、边缘 pin、slice）**逐字不变**：
```swift
static func makeViewport(panelState: PanelViewState, candles: [KLineCandle],
                         tick: Int, bounds: CGRect) -> ChartViewport {
    let mainFrame = ChartPanelFrames.split(in: bounds).mainChart
    let count = candles.count
    let currentIdx = currentCandleIndex(candles: candles, tick: tick)
    let core = geometryCore(mainFrameWidth: mainFrame.width, rawVisible: panelState.visibleCount,
                            candleCount: count, currentIdx: currentIdx)
    let candleStep = core.candleStep
    let geometry = ChartGeometry(candleStep: candleStep,
                                 candleWidth: candleStep * candleWidthRatio,
                                 gap: candleStep - candleStep * candleWidthRatio)
    let baseStartIndex = core.baseStartIndex
    let upperBound = core.upperBound
    let visibleCount = core.visibleCount
    let wholeShift = Int((panelState.offset / candleStep).rounded(.down))
    let startIndex = min(max(baseStartIndex - wholeShift, 0), upperBound)
    var pixelShift = panelState.offset - CGFloat(wholeShift) * candleStep
    if startIndex == 0 || startIndex == upperBound { pixelShift = 0 }
    let sliceEnd = min(startIndex + visibleCount, count)
    let slice = candles[startIndex ..< sliceEnd]
    return ChartViewport(startIndex: startIndex, visibleCount: slice.count,
                         pixelShift: pixelShift, geometry: geometry,
                         priceRange: PriceRange.calculate(from: slice),
                         mainChartFrame: mainFrame)
}
```

- [ ] **Step 5: 跑 geometryCore 测 + 全 makeViewport 既有测（等价证明）**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests`
Expected: `geometryCore_known` 绿 + **既有全部 case 仍绿，通过数 = Step 1 基准 + 1**（行为等价、零回归）。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "refactor(w3-11-r1a): 抽 geometryCore 共享几何内核 + makeViewport 重构调它（行为中性，既有测全绿）"
```

---

## Task 2: offsetBounds 纯函数 + 行为对拍测试

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`（加 `offsetBounds`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`

- [ ] **Step 1: 写 offsetBounds 数值 + 行为对拍测试（先失败）**

```swift
@Test("offsetBounds：count=200/currentIdx=150/width=800 → max=710,min=-490,step=10")
func offsetBounds_known() {
    let b = RenderStateBuilder.offsetBounds(
        mainFrameWidth: ChartPanelFrames.split(in: Self.bounds).mainChart.width,
        rawVisible: 0, candleCount: 200, currentIdx: 150)
    #expect(b.maxOffset == 710)     // baseStartIndex 71 · step 10
    #expect(b.minOffset == -490)    // (71 − 120) · 10
    #expect(b.candleStep == 10)
}

// D4 行为对拍（opus M4）：把 offsetBounds 算出的 edge-offset 喂回 makeViewport，
// 须落到 render 边缘（startIndex∈{0,upperBound}）且 pixelShift==0（边缘 pin），证 bounds 与 render clamp 同源。
@Test("offsetBounds 行为对拍：maxOffset→startIndex==0 pin / minOffset→startIndex==upperBound pin")
func offsetBounds_matchesRenderClamp() {
    let cs = Self.candles(period: .m3, count: 200)
    let b = RenderStateBuilder.offsetBounds(
        mainFrameWidth: ChartPanelFrames.split(in: Self.bounds).mainChart.width,
        rawVisible: 0, candleCount: 200, currentIdx: 150)
    let atMax = RenderStateBuilder.makeViewport(
        panelState: Self.panel(offset: b.maxOffset), candles: cs, tick: 150, bounds: Self.bounds)
    #expect(atMax.startIndex == 0)          // 最老边
    #expect(atMax.pixelShift == 0)          // 边缘 pin
    let atMin = RenderStateBuilder.makeViewport(
        panelState: Self.panel(offset: b.minOffset), candles: cs, tick: 150, bounds: Self.bounds)
    #expect(atMin.startIndex == 120)        // upperBound, 最新边
    #expect(atMin.pixelShift == 0)
}
```

- [ ] **Step 2: 跑 → 失败（offsetBounds 未定义）**

Run: `cd ios/Contracts && swift test --filter offsetBounds`
Expected: 编译失败 `offsetBounds` not found。

- [ ] **Step 3: 实现 offsetBounds（在 geometryCore 上派生）**

在 `RenderStateBuilder` 内加：
```swift
/// bounce 接线所需的 offset 边界（spec §二.B1 / D5）：带符号——maxOffset≥0（最老边）、minOffset 通常 <0（最新边）。
/// 与 makeViewport 的 startIndex clamp **共用 geometryCore**（D4 单一真相）。供 R1b-wire 的 Coordinator 喂 engine。
static func offsetBounds(mainFrameWidth: CGFloat, rawVisible: Int,
                         candleCount: Int, currentIdx: Int)
    -> (minOffset: CGFloat, maxOffset: CGFloat, candleStep: CGFloat) {
    let core = geometryCore(mainFrameWidth: mainFrameWidth, rawVisible: rawVisible,
                            candleCount: candleCount, currentIdx: currentIdx)
    let maxOffset = CGFloat(core.baseStartIndex) * core.candleStep
    let minOffset = CGFloat(core.baseStartIndex - core.upperBound) * core.candleStep
    return (minOffset: minOffset, maxOffset: maxOffset, candleStep: core.candleStep)
}
```

- [ ] **Step 4: 跑 → 通过**

Run: `cd ios/Contracts && swift test --filter offsetBounds`
Expected: `offsetBounds_known` + `offsetBounds_matchesRenderClamp` 均绿。

- [ ] **Step 5: 退化边界测试（count ≤ visibleCount）**

```swift
@Test("offsetBounds 退化：count<=visibleCount(无滚动空间) → upperBound==0, min/max 同号无区间")
func offsetBounds_degenerate() {
    // count=30 < 80 → visibleCount=min(80,30)=30, target=80, step=10, upperBound=max(0,30-30)=0
    // currentIdx=29(最新根) → baseStartIndex=29-29=0 → max=0, min=(0-0)*10=0（单点，无 overscroll 空间）
    let b = RenderStateBuilder.offsetBounds(
        mainFrameWidth: ChartPanelFrames.split(in: Self.bounds).mainChart.width,
        rawVisible: 0, candleCount: 30, currentIdx: 29)
    #expect(b.maxOffset == 0)
    #expect(b.minOffset == 0)
    #expect(b.candleStep == 10)
}
```
Run: `cd ios/Contracts && swift test --filter offsetBounds_degenerate`
Expected: 绿（min==max==0，交 R1b-wire 的 `EdgeBounceModel` 端点校验处理单点）。

- [ ] **Step 6: 全量 host 测 + Catalyst build**

Run: `cd ios/Contracts && swift test`
Expected: 全绿（既有 + 新 4 测）。
Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -3`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 7: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "feat(w3-11-r1a): offsetBounds 纯函数（锚相对带符号 bounce 边界）+ 行为对拍 + 退化测"
```

---

## Self-Review

**1. Spec 覆盖**（spec §二.B1 + §八 R1a）：
- geometryCore 共享内核（spec R2-M1 坐实 D4）→ Task 1 ✓
- offsetBounds 锚相对带符号（spec C1/D5）→ Task 2 ✓
- makeViewport 重构调 core 行为等价（D4）→ Task 1 Step 5 既有测全绿证明 ✓
- 行为对拍（opus M4）→ Task 2 Step 1 ✓
- 退化 count≤visibleCount → Task 2 Step 5 ✓
- **不含 B4 overscroll / engine / gesture**（spec §八 planning 修正：B4 入 R1b-wire）✓
- ledger 不碰治理 doc（ledger-B）✓

**2. Placeholder 扫描**：无 TBD/TODO；每 step 含完整 Swift 代码 + 确切命令 + 期望。

**3. 类型/标识一致性**：`GeometryCore`(baseStartIndex/upperBound/candleStep/visibleCount) / `geometryCore(mainFrameWidth:rawVisible:candleCount:currentIdx:)` / `offsetBounds(...)→(minOffset,maxOffset,candleStep)` 在 Task 1/2 一致；数值 base=71/upper=120/step=10/max=710/min=-490 与 spec §二.B1 + 既有 `offsetMidScroll` 测（baseStartIndex==71）一致。

**风险**：①`currentIdx=150 for tick=150`——由既有 `offsetMidScroll`（startIndex 69 = 71−2）实证 baseStartIndex==71，故 currentIdx==150 成立（fixture 的 endGlobalIndex 线性）；实施时 Step 1 先验证既有测绿即锁定此前提。②`ChartPanelFrames.split(in:).mainChart.width` 在 800 宽 bounds 下是否 ==800（split 切高度不切宽度？）——既有 `geometry` 测 candleStep==10=800/80 已实证 mainChart.width==800，故对拍用同式安全。
