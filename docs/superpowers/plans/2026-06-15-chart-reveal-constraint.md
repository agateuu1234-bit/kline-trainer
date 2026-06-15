# 图表 reveal 约束（已揭示前缀窗口）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `RenderStateBuilder.makeViewport` 的未来泄漏 latent bug —— 把图表可见窗口约束为「已揭示前缀」`candles[0...currentIdx]`，任何 offset/缩放/tick 下 slice 末根索引恒 ≤ currentIdx（禁前窥）。

**Architecture:** 仅改 `makeViewport` 两行（`upperBound` 收紧 + `sliceEnd` 上限），单一真相不破（`make`/`visibleCandleRange`/engine pinch 经它自动获新行为）；既有测试中编码旧「泄漏」期望的 5 个 case 改期望 + 跨 suite 冲突测 `freeScrollingFocusInvariant` 重设计 + 补 4 个不变量测 + 1 个 mid-tick 正向 focus 测。

**Tech Stack:** Swift / Swift Testing（`@testable import KlineTrainerContracts`）；host `swift test`（macOS）+ Mac Catalyst build-for-testing。

**收敛设计文档（spec）：** `docs/superpowers/specs/2026-06-15-chart-reveal-constraint-design.md`（opus 4.8 xhigh spec-review R1→R2→R3 APPROVE 收敛）。

**基线：** `1016 tests in 144 suites passed`（worktree off main `8cdf06f`，实跑确认）。本计划净增 5 测 → 目标 `1021 tests in 144 suites`。

---

## 不变量（核心，来自 spec §二）

图表可见窗口 ⊆ **已揭示前缀** `candles[0 ... currentIdx]`：**任何 offset/缩放/tick 下，`startIndex + viewport.visibleCount − 1 ≤ currentIdx`（看不到未来）且 `viewport.visibleCount ≥ 1`（不空切片）。**

生产改动（`makeViewport`，其余逐字不变）：
- **(A)** `upperBound`：`max(0, count − visibleCount)` → `max(0, baseStartIndex)`（autoTracking=最新可见边，前向滚动 clamp 回当前 tick，禁前窥）。
- **(B)** `sliceEnd`：`min(startIndex + visibleCount, count)` → `min(startIndex + visibleCount, currentIdx + 1)`（slice 末根恒 ≤ currentIdx；早 tick 左填充时实际可见根数 < target）。

数学闭合（实施时无需重推，已核）：`currentIdx = min(rawIdx, count−1)` ⇒ `currentIdx+1 ≤ count`（sliceEnd 仍在界内，不再需要旧 `count` 上限）；`startIndex ≤ max(0, baseStartIndex) ≤ currentIdx`（baseStartIndex = currentIdx−(visibleCount−1) ≤ currentIdx）⇒ `sliceEnd ≥ startIndex+1`（slice 永非空，`make()` 强切 slice 不崩）。

---

## §三.B 跨 suite 影响审计结果（已逐测核实 2026-06-15，spec 要求 plan 阶段穷举）

消费 `makeViewport`/`visibleCandleRange` 的 **6 个测试 suite** 逐测结论：

| Suite | 结论 | 依据 |
|---|---|---|
| **RenderStateBuilderTests** | **5 case 改期望 + 注释**（见 Task 1） | 直接断言 `startIndex`/`visibleCount` 硬值；其余 case 已实算不变（回归基准） |
| **TrainingEnginePinchTests** | **`freeScrollingFocusInvariant` 重设计 + 补 1 正向 mid-tick 测**（见 Task 1） | currentIdx==0（NormalFlow.initialTick==0）+ focus 落未来 slot 40 → 新公式 reveal-pin → uBefore=40.5≠uAfter=20.25 硬失败（spec C1'） |
| **PinchZoomModelTests** | **INVARIANT（零改）** | 全部直接构造 `ChartViewport`（局部 `viewport()` helper）+ 调纯函数 `rezoomOffset`/`targetVisibleCount`；本 RFC 不碰这两个公式 |
| **GeometryTests** | **INVARIANT（零改）** | 局部 `makeViewport` helper 直接构造 `ChartViewport`（非 `RenderStateBuilder.makeViewport`）；测 CoordinateMapper/几何原语 |
| **TrainingEngineInteractionTests** | **INVARIANT（零改）** | `expected = visibleCandleRange(...)` 与 `snap.frozen.candleRange` **同函数自洽比较**（两侧都经新公式，恒相等）；其余断言为 offset 累加 / 减速 FSM / mode |
| **TrainingEngineDrawingHandlerH1Tests** | **INVARIANT（零改）** | 同上自洽比较（`expected` 经 `visibleCandleRange`，handler 内部同 `visibleCandleRange`）；无硬编码几何期望 |

生产消费面（3 处，新行为经单一真相自动流过，无独立几何）：`make()`（slice 装配）、`TrainingEngine.applyPinch` freeScrolling 分支（`makeViewport` + `rezoomOffset`，:652）、`TrainingEngine.activateDrawingTool`（`visibleCandleRange`，:713）。后二者由 TrainingEnginePinchTests / TrainingEngineInteractionTests / DrawingHandlerH1Tests 覆盖（前者改、后二自洽比较恒绿）。

非消费面（spec §三.B 已排除，无需改）：`Drawing/DefaultDrawingInputControllerTests`（直接构造 `ChartViewport` 测 CoordinateMapper 逆映射）。`ChartContainerView`（SwiftUI 壳，`.make()`/`applyPinch` 经 makeViewport 透传、无独立几何、无 host 测）。

---

## File Structure

- **Modify** `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`（`makeViewport` :77 + :87 两行 + 注释；Task 2）
- **Modify** `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（5 case 改期望 + 注释 + 4 新不变量测；Task 1）
- **Modify** `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePinchTests.swift`（重设计 `freeScrollingFocusInvariant` + 补 1 mid-tick 正向测；Task 1）
- **Create** `docs/acceptance/2026-06-15-chart-reveal-constraint.md`（非 coder 可执行验收清单 + device runbook；Task 3）

---

## Task 1: 把 reveal 不变量编码进测试（RED）

把「已揭示前缀」期望写进测试。RED 闸门：bug-demonstrator 测试对当前生产代码 FAIL；regression-guard 测试两态都绿。

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePinchTests.swift`

- [ ] **Step 1：更新 RenderStateBuilderTests 5 个变更 case 的期望值 + 注释**

`anchorEarlyTick`（line 57-64）—— `visibleCount` 期望 `80 → 11`（slice=candles[0..<11]，末根==currentIdx==10，无未来）：

```swift
    @Test("锚定(b)：count>=80 但 currentIdx<79（早期 tick）→ startIndex==0，只显已揭示前缀（reveal）")
    func anchorEarlyTick() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 10, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.visibleCount == 11)        // reveal：slice=candles[0..<11]（currentIdx+1），非旧 80
        #expect(10 - vp.startIndex == 10)
    }
```

`offsetNegative`（line 108-117）—— 前向滚动 clamp 回 autoTracking（startIndex `74 → 71`）+ 落 upperBound 边 pin（pixelShift `5 → 0`）：

```swift
    @Test("offset：负 offset（前向/朝新）→ clamp 回 autoTracking（reveal 禁前窥）")
    func offsetNegative() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -25), candles: cs, tick: 150, bounds: Self.bounds)
        // reveal：upperBound=max(0,baseStartIndex)=71；wholeShift=floor(-2.5)=-3 → unclamped=74 → clamp 71
        //（前向滚动不可越当前 tick）；startIndex==71==upperBound → pixelShift 边 pin=0
        #expect(vp.startIndex == 71)
        #expect(vp.pixelShift == 0)
    }
```

`saturateRightClamped`（line 129-137）—— 不可前向越 autoTracking（startIndex `120 → 71`）：

```swift
    @Test("饱和(前向/朝新越界)：负大 offset → clamp 到 autoTracking（reveal），pixelShift=0")
    func saturateRightClamped() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -600), candles: cs, tick: 150, bounds: Self.bounds)
        // reveal：upperBound=max(0,71)=71；wholeShift=floor(-60)=-60 → unclamped=131 → clamp 71（不越当前 tick）
        #expect(vp.startIndex == 71)
        #expect(vp.pixelShift == 0)
    }
```

`saturateRightExactBoundary`（line 149-157）—— startIndex `120 → 71`：

```swift
    @Test("饱和(前向恰落旧右界 + 非零余量)：reveal 下仍 clamp 到 autoTracking，pixelShift=0")
    func saturateRightExactBoundary() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: -485), candles: cs, tick: 150, bounds: Self.bounds)
        // reveal：upperBound=71；wholeShift=floor(-48.5)=-49 → unclamped=120 → clamp 71；余量按落位归 0
        #expect(vp.startIndex == 71)
        #expect(vp.pixelShift == 0)
    }
```

`oneSixtyVisibleSaturates`（line 315-327）—— `visibleCount` 期望 `160 → 151`（slice=candles[0..<151]，末根==currentIdx==150）：

```swift
    @Test("D5 放宽视野 + reveal：visibleCount=160、currentIdx=150 → 早 tick 左填充至 currentIdx+1")
    func oneSixtyVisibleSaturates() {
        let ps = PanelViewState(period: .m3, interactionMode: .freeScrolling,
                                visibleCount: 160, offset: 15, revision: 0)
        let vp = RenderStateBuilder.makeViewport(
            panelState: ps, candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 5) < 1e-9)    // 800/160
        // baseStart=150−159=−9 → upperBound=max(0,−9)=0；wholeShift=floor(15/5)=3 → −12 → clamp 0 → pixelShift=0
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
        #expect(vp.visibleCount == 151)    // reveal：sliceEnd=min(0+160, 150+1)=151，末根==currentIdx==150
    }
```

同步把 line 97 段注释 `upperBound=120` 改为 `upperBound=max(0,baseStartIndex)=71（reveal）`（仅注释，紧邻 `offsetMidScroll` 上方）。

- [ ] **Step 2：在 RenderStateBuilderTests 末尾（line 409 `}` 之前）新增 4 个 reveal 不变量测**

```swift
    // MARK: - reveal 约束（已揭示前缀窗口；spec §五）

    @Test("reveal 不变量扫描：跨 tick × offset，slice 末根 ≤ currentIdx 且 visibleCount ≥ 1（禁前窥）")
    func revealedPrefixInvariantScan() {
        let cs = Self.candles(period: .m3, count: 200)
        let ticks = [0, 5, 10, 40, 79, 80, 150, 199]
        let offsets: [CGFloat] = [0, 25, -25, 600, -600, 5000, -5000]
        for t in ticks {
            let currentIdx = RenderStateBuilder.currentCandleIndex(candles: cs, tick: t)
            for off in offsets {
                let vp = RenderStateBuilder.makeViewport(
                    panelState: Self.panel(offset: off), candles: cs, tick: t, bounds: Self.bounds)
                #expect(vp.visibleCount >= 1, "空切片 tick=\(t) offset=\(off)")
                #expect(vp.startIndex + vp.visibleCount - 1 <= currentIdx,
                        "前窥 tick=\(t) offset=\(off)：末根=\(vp.startIndex + vp.visibleCount - 1) > cIdx=\(currentIdx)")
            }
        }
    }

    @Test("reveal 前向滚动禁：任意负 offset → startIndex ≤ max(0, baseStartIndex)（不越 autoTracking）")
    func forwardScrollClampedToAutoTracking() {
        let cs = Self.candles(period: .m3, count: 200)
        let ticks = [10, 79, 150, 199]
        let negOffsets: [CGFloat] = [-5, -25, -200, -600, -5000]
        for t in ticks {
            let currentIdx = RenderStateBuilder.currentCandleIndex(candles: cs, tick: t)
            let cap = max(0, currentIdx - (min(80, cs.count) - 1))   // vc=80（panel visibleCount=0→fallback）
            for off in negOffsets {
                let vp = RenderStateBuilder.makeViewport(
                    panelState: Self.panel(offset: off), candles: cs, tick: t, bounds: Self.bounds)
                #expect(vp.startIndex <= cap, "前向越界 tick=\(t) offset=\(off)：si=\(vp.startIndex) > cap=\(cap)")
            }
        }
    }

    @Test("reveal 早 tick 修复：count=200/tick=10 → visibleCount==11、slice 末根==currentIdx==10（无未来）")
    func earlyTickRevealsOnlyRevealedPrefix() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: cs, tick: 10, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.visibleCount == 11)
        #expect(vp.startIndex + vp.visibleCount - 1 == 10)   // 末根==currentIdx，无未来
    }

    @Test("reveal backward 历史：大正 offset → startIndex==0 + pixelShift==0（至最旧；regression 基准）")
    func backwardScrollReachesOldest() {
        let cs = Self.candles(period: .m3, count: 200)
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(offset: 5000), candles: cs, tick: 150, bounds: Self.bounds)
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
    }
```

- [ ] **Step 3：重设计 TrainingEnginePinchTests.freeScrollingFocusInvariant（line 134-159）→ reveal-pin 退化断言**

`currentIdx==0`（NormalFlow.initialTick==0）时 focus 落未来 slot → 退化为「pin 在已揭示最新边」（禁前窥的必然结果，spec C1' 裁决）。整段替换：

```swift
    @Test("freeScrolling focus 落未来 slot（currentIdx==0）→ 退化为 reveal-pin（禁前窥必然，spec C1'）")
    func freeScrollingFocusOnFuturePinsToRevealedEdge() {
        let (e, _) = Self.engine()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 15, panel: .upper)     // freeScrolling offset=15
        let candles = e.allCandles[.m3]!
        let tick = e.tick.globalTickIndex                    // ==0 → currentIdx==0
        let fx: CGFloat = 405                                // slot 40 = 未来（> currentIdx 0）
        let vpBefore = RenderStateBuilder.makeViewport(panelState: e.upperPanel, candles: candles,
                                                       tick: tick, bounds: Self.bounds)
        #expect(vpBefore.startIndex == 0)                    // reveal：upperBound=max(0,−79)=0 → 左缘 pin
        #expect(vpBefore.pixelShift == 0)
        e.applyPinch(scale: 1.0, focusX: fx, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: fx, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
        let vpAfter = RenderStateBuilder.makeViewport(panelState: e.upperPanel, candles: candles,
                                                      tick: tick, bounds: Self.bounds)
        #expect(vpAfter.startIndex == 0)                     // reveal：缩放后仍 pin 在已揭示最新边（无前窥）
        #expect(vpAfter.pixelShift == 0)
        #expect(e.upperPanel.interactionMode == .freeScrolling)   // 不切 mode
    }
```

- [ ] **Step 4：在 TrainingEnginePinchTests 末尾（line 172 `}` 之前）新增 mid-tick 正向 focus 不变量测**

补回「engine 编排路径 focus 不变量在 focus 落已揭示 candle 时仍成立」的覆盖（原 `freeScrollingFocusInvariant` 因 currentIdx==0 已无法承担）：

```swift
    @Test("freeScrolling focus 端到端（mid-tick，focus 落已揭示 candle）→ 缩放前后连续索引不变 + 离散不变")
    func freeScrollingFocusInvariantMidTickRevealedCandle() {
        // mid-tick engine（initialTick=150 ∈ 0...199，currentIdx=150，非饱和 startIndex=70）：
        // focus 落已揭示 candle（uBefore=110.5 ≤ 150）→ reveal 下 focus 不变量仍成立（经 engine 编排路径）。
        let maxTick = 199
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
                             maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: 200)),
            maxTick: maxTick,
            initialTick: 150,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 15, panel: .upper)     // freeScrolling offset=15 → startIndex=70/pixelShift=5
        let candles = e.allCandles[.m3]!
        let tick = e.tick.globalTickIndex
        let vpBefore = RenderStateBuilder.makeViewport(panelState: e.upperPanel, candles: candles,
                                                       tick: tick, bounds: Self.bounds)
        let fx: CGFloat = 410                                // uBefore = 70 + (410−5)/10 = 110.5 ≤ currentIdx 150
        let uBefore = CGFloat(vpBefore.startIndex) + (fx - vpBefore.pixelShift) / vpBefore.geometry.candleStep
        e.applyPinch(scale: 1.0, focusX: fx, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: fx, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
        let vpAfter = RenderStateBuilder.makeViewport(panelState: e.upperPanel, candles: candles,
                                                      tick: tick, bounds: Self.bounds)
        let uAfter = CGFloat(vpAfter.startIndex) + (fx - vpAfter.pixelShift) / vpAfter.geometry.candleStep
        #expect(abs(uAfter - uBefore) < 1e-9)                // 110.5 == 110.5（focus 落已揭示 candle，invariant 成立）
        let mB = CoordinateMapper(viewport: vpBefore, displayScale: 1)
        let mA = CoordinateMapper(viewport: vpAfter, displayScale: 1)
        #expect(mB.xToIndex(fx) == mA.xToIndex(fx))
        #expect(e.upperPanel.interactionMode == .freeScrolling)
    }
```

- [ ] **Step 5：运行变更/新增 suite，确认 RED（bug-demonstrator FAIL）**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilder 2>&1 | tail -30 && swift test --filter TrainingEnginePinch 2>&1 | tail -30`

Expected（对当前未改生产代码）：
- **FAIL（bug-demonstrator，预期红）：** `anchorEarlyTick`、`offsetNegative`、`saturateRightClamped`、`saturateRightExactBoundary`、`oneSixtyVisibleSaturates`、`revealedPrefixInvariantScan`、`forwardScrollClampedToAutoTracking`、`earlyTickRevealsOnlyRevealedPrefix`、`freeScrollingFocusOnFuturePinsToRevealedEdge`。
- **PASS（regression-guard，两态绿）：** `backwardScrollReachesOldest`、`freeScrollingFocusInvariantMidTickRevealedCandle`（focus 落已揭示 candle，旧公式下也成立）。

若任一 bug-demonstrator 意外 PASS → 该测试未真正锚定 reveal 行为，回查期望值。

- [ ] **Step 6：Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePinchTests.swift
git commit -m "test(reveal): 编码已揭示前缀不变量（5 case 改期望 + 4 不变量测 + pinch focus 重设计，RED）"
```

---

## Task 2: makeViewport 生产改动（GREEN）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:77,87`

- [ ] **Step 1：改 upperBound（:77）—— 禁前窥**

旧：
```swift
        let upperBound = max(0, count - visibleCount)
```
新：
```swift
        // reveal RFC（2026-06-15）：upperBound 从 max(0,count−visibleCount) 收紧为 max(0,baseStartIndex)
        // = autoTracking 即最新可见边，前向滚动（朝新）不可越当前 tick（禁前窥）。
        let upperBound = max(0, baseStartIndex)
```

- [ ] **Step 2：改 sliceEnd（:87）—— slice 末根 ≤ currentIdx**

旧：
```swift
        let sliceEnd = min(startIndex + visibleCount, count)
```
新：
```swift
        // reveal RFC：可见窗口 ⊆ 已揭示前缀 candles[0...currentIdx]；slice 末根恒 ≤ currentIdx（看不到未来）。
        // 早 tick 左填充时 visibleCount(返回) = sliceEnd−startIndex < target。currentIdx+1 ≤ count（界内）。
        let sliceEnd = min(startIndex + visibleCount, currentIdx + 1)
```

- [ ] **Step 3：运行全量 host 测试 → 全绿**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `Test run with 1021 tests in 144 suites passed`，`0 failures`（1016 baseline + 5 新增；Task 1 的 9 个 bug-demonstrator 现转绿，2 个 regression-guard 维持绿）。

若有非预期 FAIL（§三.B 判 INVARIANT 的 suite 出现失败）→ 审计遗漏，停下逐测复核该 suite，**勿**为凑绿改无关测试。

- [ ] **Step 4：Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift
git commit -m "fix(reveal): makeViewport 已揭示前缀窗口（upperBound→baseStartIndex 禁前窥 + sliceEnd→currentIdx+1）"
```

---

## Task 3: 验收清单 + 最终验证

**Files:**
- Create: `docs/acceptance/2026-06-15-chart-reveal-constraint.md`

- [ ] **Step 1：写非 coder 可执行验收清单（中文 action/expected/pass-fail + device runbook）**

```markdown
# 验收清单 — 图表 reveal 约束（已揭示前缀窗口，改顺位 3 冻结视口几何 RFC）

**交付物：** `RenderStateBuilder.makeViewport` 两行改（`upperBound→max(0,baseStartIndex)` 禁前窥 + `sliceEnd→min(…,currentIdx+1)` slice 末根≤currentIdx）= 修未来泄漏 latent bug。设计经 opus 4.8 xhigh spec-review R1→R3 APPROVE 收敛；实施计划经 opus 4.8 xhigh 对抗评审收敛。

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | `1021 tests in 144 suites passed`，`0 failures`（1016 baseline + 5 新增） | ☐ |
| 2 | `git diff origin/main...HEAD --stat -- ios/` 逐行核对 | 改动 Swift 文件集 ⊆ {RenderStateBuilder.swift, RenderStateBuilderTests.swift, TrainingEnginePinchTests.swift}；无 .sql/schema/CONTRACT_VERSION/workflow 改动 | ☐ |
| 3 | `git diff origin/main...HEAD -- ios/Contracts/Sources \| grep -cE "^\+" ` | 生产侧新增行数极小（两行逻辑改 + 注释）；无 KLineView/PinchZoomModel/TrainingEngine 生产逻辑改动 | ☐ |
| 4 | `grep -n "max(0, baseStartIndex)" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift; echo rc=$?` | 命中（upperBound 收紧已落地）`rc=0` | ☐ |
| 5 | `grep -n "currentIdx + 1" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift; echo rc=$?` | 命中（sliceEnd 上限已落地）`rc=0` | ☐ |
| 6 | `swift test --filter revealedPrefixInvariantScan 2>&1 \| tail -2` | 该不变量扫描测试 PASS（跨 tick×offset 零前窥零空切片） | ☐ |
| 7 | Mac Catalyst CI：PR checks 页查 `Mac Catalyst build-for-testing on macos-15` | SUCCESS（平台无关几何，UIKit 面真编译） | ☐ |
| 8 | app-target CI：PR checks 页查顺位 2 设立的 app build required check | SUCCESS | ☐ |

## 运行时 runbook 条目（user device/sim 执行；spec §五.7 device 验收义务 + Wave 3 矩阵新增项）

| # | Action（iPad mini 7 或 Catalyst） | Expected | Pass/Fail |
|---|---|---|---|
| R1 | 训练中（autoTracking）单指向左快滑（朝新方向 fling） | 最新一根 K 线钉在最右后**不再露出更新的（未来）K 线**；无空白未来区 | ☐ |
| R2 | 训练刚开局（前几根 tick）观察图表 | 只显示已走出的 K 线（左填充），右侧为空槽，**无未来 K 线**被画出 | ☐ |
| R3 | 向后（朝历史）拖拽到最左 | 可滚到第一根 K 线为止，贴左边缘不裂口 | ☐ |
| R4 | mid-history 处（已滚动浏览）两指对准某根特征 K 线捏合缩放 | 该 K 线基本不动（focus 锚定）；缩放后仍不露未来 | ☐ |
| R5 | autoTracking 处向后拖不足一根（sub-candle） | 首根有轻微吸附感（最新边 pin，spec §M2 注明的预期一致行为，非缺陷） | ☐ |

## Residuals

- **W3-11-R1**（bounce live 接线，parked 于分支 `wave3-w3-11-r1-bounce-wiring`）：本 RFC merge 后 rebase onto 含 reveal 修复的 main，按 spec D5 重做 `offsetBounds`（`minOffset=0` / `maxOffset=max(0,baseStartIndex)·candleStep`）。
- **device 运行时矩阵**：本 RFC 新增 R1-R5 device 验收项归 Wave 3 矩阵收尾 reconciliation 或本验收清单自记（spec §七 ledger-B：不碰 Wave 3 completion 治理块）。
```

- [ ] **Step 2：最终全量验证（host + Catalyst build）**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `1021 tests in 144 suites passed`，`0 failures`。

Run（Catalyst build-for-testing，平台面真编译）:
```bash
cd ios/Contracts && xcodebuild build-for-testing \
  -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **`（若本地无 Catalyst 工具链则依赖 CI required check，记录于验收 #7）。

- [ ] **Step 3：Commit**

```bash
git add docs/acceptance/2026-06-15-chart-reveal-constraint.md
git commit -m "docs(reveal): 验收清单 + device runbook（已揭示前缀窗口）"
```

---

## Self-Review（writing-plans 自查）

1. **Spec coverage：** spec §二 (A)(B) → Task 2；spec §三 5 变更 case → Task 1 Step 1；spec §三.B 6-suite 审计 → 本计划「审计结果」表（4 INVARIANT + 2 改）+ Task 1 Step 3-4；spec §五 4 不变量测 → Task 1 Step 2；spec §五.7 device runbook → Task 3；spec D5 下游 → Residuals。覆盖完整，无 gap。
2. **Placeholder scan：** 无 TBD/TODO；每步含完整 Swift 代码 + 精确命令 + 期望输出。
3. **Type consistency：** `currentCandleIndex`/`makeViewport`/`rezoomOffset` 签名与现源一致（已 `@testable` 暴露，endToEndFocusInvariant 已先例调用 `currentCandleIndex`）；`TrainingEngine.init(initialTick:)` 参数序与源 :64-78 一致；`baseStartIndex` 在 `makeViewport` 内已定义（:76），(A) 改动复用之，无前置依赖问题。

## 治理

- **评审通道：** 改 `ios/**/*.swift` + `docs/superpowers/plans/**` + `docs/superpowers/specs/**`（均 trust_boundary_globs）→ `codex:adversarial-review`（codex 配额耗尽 → opus 4.8 xhigh fallback，established pattern）；Catalyst + app-build required check。
- **phase_delivery：** true；acceptance = 上述 host 测 + device runbook（业务行为修正，非 mechanism）。
- **不 claim 行为中性：** 明为行为修正（spec D6）。
