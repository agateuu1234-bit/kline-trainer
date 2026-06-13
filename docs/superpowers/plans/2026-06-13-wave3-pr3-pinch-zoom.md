# Wave 3 顺位 3：Pinch 缩放 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付 §4.4d engine-owned pinch 缩放全链路：`PinchZoomModel` 纯数学（clamp + focus 不变量）+ `ChartAction.zoomApplied` reducer case + `engine.applyPinch` 编排 + `makeViewport` 去硬编码 80 + `ChartContainerView` onPinch 接线 + 四 doc amendment（两项 user 裁决落档）。

**Architecture:** 几何在纯函数算好（`PinchZoomModel` + 共享谓词 `currentCandleIndex`），reducer 只收最终值（`zoomApplied`，3 mode 矩阵），engine `applyPinch` 编排（停 animator / pinchBase 捕获 / mode 分派），视图层仅 1 闭包接线。autoTracking = 右锚缩放（user 2026-06-13 裁决 A），freeScrolling = focus 不变量，drawing = reducer 吞没。

**Tech Stack:** Swift 6 / Swift Testing（host macOS 全量单测）/ Mac Catalyst build-for-testing（UIKit 面编译闸）。

**权威输入：** 设计文档 `docs/superpowers/specs/2026-06-13-wave3-pr3-pinch-zoom-design.md`（opus 4.8 xhigh 5 轮收敛 APPROVE，D1-D10 + 两项 user 裁决）。冲突时以设计文档为准。

**Step↔Skill 表（PR #46 教训）：**

| 阶段 | Skill |
|---|---|
| 本 plan 执行 | superpowers:subagent-driven-development（每 Task 双道 review：spec 合规 + code quality） |
| 每 Task 内写码 | superpowers:test-driven-development（红→绿→commit） |
| plan 收敛门 | opus 4.8 xhigh 对抗评审（user session 契约，替代 codex） |
| 完成声明前 | superpowers:verification-before-completion |
| 合并前 | superpowers:requesting-code-review + 整体 branch-diff opus 4.8 xhigh |

**Baseline：** main `ddc96ea`，864 tests / 123 suites 全绿（worktree 实测 2026-06-13）。

**文件总表：**

| 文件 | 动作 |
|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Render/PinchZoomModel.swift` | Create（Task 1） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift` | Modify（Task 1 抽谓词 + Task 2 去硬编码） |
| `ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift` | Modify（Task 3 zoomApplied） |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | Modify（Task 4 applyPinch + pinchBase + seed 80） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift` | Modify（Task 5 接线） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/PinchZoomModelTests.swift` | Create（Task 1） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift` | Modify（Task 2 新增用例） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerZoomTests.swift` | Create（Task 3） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePinchTests.swift` | Create（Task 4） |
| `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` | Modify（Task 6 D9.1 a/b/c） |
| `docs/superpowers/specs/2026-06-09-wave3-outline-design.md` | Modify（Task 6 D9.2 callout） |
| `kline_trainer_modules_v1.4.md` | Modify（Task 6 D9.3/D9.5：1743 focus + 1738 neck） |
| `kline_trainer_plan_v1.5.md` | Modify（Task 6 D9.4：L1037/L1180） |
| `docs/acceptance/2026-06-13-wave3-pr3-pinch-zoom.md` | Create（Task 7） |

---

### Task 1: PinchZoomModel 纯函数 + currentCandleIndex 共享谓词

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/PinchZoomModel.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:71-74`（抽谓词）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/PinchZoomModelTests.swift`

- [ ] **Step 1.1: 写失败测试**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/Render/PinchZoomModelTests.swift`：

```swift
// Wave 3 顺位 3 Pinch 缩放纯数学测试
// Design: docs/superpowers/specs/2026-06-13-wave3-pr3-pinch-zoom-design.md D3/D4
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("PinchZoomModel 纯函数")
struct PinchZoomModelTests {

    // MARK: targetVisibleCount（D4：target = clamp(round(base / effectiveScale), 20, 240)）

    @Test("恒等：effectiveScale=1 → base 不变")
    func identityScale() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 1.0) == 80)
    }

    @Test("放大：scale=2（张开）→ 根数减半")
    func zoomInHalves() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 2.0) == 40)
    }

    @Test("缩小：scale=0.5（捏拢）→ 根数翻倍")
    func zoomOutDoubles() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 0.5) == 160)
    }

    @Test("clamp 上界：240")
    func clampMax() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 0.25) == 240)  // 320 → 240
    }

    @Test("clamp 下界：20")
    func clampMin() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 8.0) == 20)    // 10 → 20
    }

    @Test("round 取整：80/1.05 = 76.19… → 76")
    func roundsToNearest() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 1.05) == 76)
    }

    @Test("单调：scale 升 → target 非严格降")
    func monotoneInScale() {
        let scales: [CGFloat] = [0.2, 0.5, 0.8, 1.0, 1.3, 2.0, 4.0, 10.0]
        let targets = scales.map { PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: $0) }
        for i in 1..<targets.count { #expect(targets[i] <= targets[i - 1]) }
    }

    @Test("极小正 scale：clamp 兜底不溢出（0 附近防御，R3-L1 模型层合法用例）")
    func tinyPositiveScaleClamps() {
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 1e-9) == 240)
        #expect(PinchZoomModel.targetVisibleCount(base: 80, effectiveScale: 1e9) == 20)
    }

    // MARK: rezoomOffset（D3：offset′ = fx − (u_before − cIdx + N′−1)·W/N′）
    // 向量手算依据见设计文档 D3；视口快照直接构造（非饱和值取自 makeViewport 真实输出形态）。

    /// 非饱和 freeScrolling 视口：count=200, N=80, W=800（step=10）, cIdx=150, offset=0
    /// → startIndex=71, pixelShift=0（与 RenderStateBuilderTests 锚定(a) 一致）
    static func viewport(startIndex: Int, pixelShift: CGFloat, step: CGFloat) -> ChartViewport {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 360)
        return ChartViewport(startIndex: startIndex, visibleCount: 80, pixelShift: pixelShift,
                             geometry: ChartGeometry(candleStep: step, candleWidth: step * 0.7,
                                                     gap: step * 0.3),
                             priceRange: PriceRange(min: 9, max: 11),
                             mainChartFrame: frame)
    }

    @Test("右缘焦点（fx=W, offset=0, 非饱和）→ offset′=0（D2 右锚连续性锚点）")
    func rightEdgeFocusYieldsZero() {
        let vp = Self.viewport(startIndex: 71, pixelShift: 0, step: 10)
        let o = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: 150,
                                            focusX: 800, newCount: 40, mainWidth: 800)
        #expect(abs(o) < 1e-9)
    }

    @Test("中点放大（fx=400, 80→40）→ offset′=400（手算向量，设计 D3）")
    func midFocusZoomIn() {
        let vp = Self.viewport(startIndex: 71, pixelShift: 0, step: 10)
        // u_before = 71 + 400/10 = 111；offset′ = 400 − (111−150+39)·20 = 400
        let o = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: 150,
                                            focusX: 400, newCount: 40, mainWidth: 800)
        #expect(abs(o - 400) < 1e-9)
    }

    @Test("offset≠0 起点缩小（pixelShift=5, 80→160）→ offset′=−192.5（手算向量）")
    func nonzeroOffsetZoomOut() {
        // 存量 offset=15 → wholeShift=1, startIndex=70, pixelShift=5
        // u_before = 70 + (400−5)/10 = 109.5；offset′ = 400 − (109.5−150+159)·5 = −192.5
        let vp = Self.viewport(startIndex: 70, pixelShift: 5, step: 10)
        let o = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: 150,
                                            focusX: 400, newCount: 160, mainWidth: 800)
        #expect(abs(o - (-192.5)) < 1e-9)
    }

    @Test("N′=N 恒等（非饱和视口，R2-L3）→ offset′ == 存量 offset")
    func identityCountKeepsOffset() {
        // offset=15 → startIndex=70, pixelShift=5（非饱和：70 ∈ (0, 120)）
        // u_before = 70 + (400−5)/10 = 109.5；offset′ = 400 − (109.5−150+79)·10 = 15
        let vp = Self.viewport(startIndex: 70, pixelShift: 5, step: 10)
        let o = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: 150,
                                            focusX: 400, newCount: 80, mainWidth: 800)
        #expect(abs(o - 15) < 1e-9)
    }

    // 注：端到端 makeViewport focus 不变量测试（endToEndFocusInvariant）放 Task 2（依赖去硬编码后
    // makeViewport honor visibleCount；放此处 Task 1 时 makeViewport 仍恒 80 分母 → 必 FAIL，破 TDD 绿门，Plan-R2 PR2-01）。
}
```

- [ ] **Step 1.2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter PinchZoomModelTests 2>&1 | tail -5`
Expected: 编译失败 `cannot find 'PinchZoomModel' in scope`（含 `currentCandleIndex` 未定义）。

- [ ] **Step 1.3: 实现 PinchZoomModel + 抽共享谓词**

创建 `ios/Contracts/Sources/KlineTrainerContracts/Render/PinchZoomModel.swift`：

```swift
// Kline Trainer Swift Contracts — 顺位 3 Pinch 缩放纯数学（RFC §4.4d）
// Design: docs/superpowers/specs/2026-06-13-wave3-pr3-pinch-zoom-design.md D3/D4
//
// 平台无关：host 全量单测。clamp/灵敏度常量集中此处（runbook 实测不适即一行改，D4）。

import CoreGraphics

public enum PinchZoomModel {
    /// clamp 边界（D4）：默认 80 居中偏左；240 = 3×默认（step≈3pt 密集可辨），20 = 默认÷4（step≈37pt 粗看形态）。
    public static let minVisibleCount = 20
    public static let maxVisibleCount = 240

    /// 目标可见根数：clamp(round(base / effectiveScale), MIN, MAX)。
    /// effectiveScale = scale / scaleAtBegan（锁定点归一，消 ±2% 死区，D4/R1-L1）；>1 张开 → 根数变少 → 放大。
    /// **前置条件**：effectiveScale 有限且 > 0（engine applyPinch 守卫，R2-L1——防御不在本模型）。
    /// clamp 在 CGFloat 域先做再转 Int，防极端 scale 下 Int 转换溢出。
    public static func targetVisibleCount(base: Int, effectiveScale: CGFloat) -> Int {
        let raw = (CGFloat(base) / effectiveScale).rounded(.toNearestOrAwayFromZero)
        let clamped = min(max(raw, CGFloat(minVisibleCount)), CGFloat(maxVisibleCount))
        return Int(clamped)
    }

    /// focus 不变量（D3）：解新 offset 使 pinch 中点 fx 下连续 candle 索引不变。
    /// before 端用**实际渲染视口**（makeViewport 输出，含 clamp/边缘饱和后的值——用户看到什么就锚什么）；
    /// after 端用连续模型：
    ///   u_before = startIndex + (fx − pixelShift) / candleStep
    ///   offset′  = fx − (u_before − currentIdx + N′ − 1) · (W / N′)
    /// 返回值不二次 clamp：渲染端 makeViewport 边界饱和兜底（同 pan 先例；饱和 > focus 优先级）。
    /// **前置条件**：newCount ≥ 1、mainWidth > 0（engine bounds-zero no-op 已挡）。
    public static func rezoomOffset(viewport: ChartViewport, currentIdx: Int,
                                    focusX: CGFloat, newCount: Int,
                                    mainWidth: CGFloat) -> CGFloat {
        let uBefore = CGFloat(viewport.startIndex)
            + (focusX - viewport.pixelShift) / viewport.geometry.candleStep
        let newStep = mainWidth / CGFloat(newCount)
        return focusX - (uBefore - CGFloat(currentIdx) + CGFloat(newCount) - 1) * newStep
    }
}
```

修改 `RenderStateBuilder.swift`：把 makeViewport 内两行（L73-74）

```swift
        let rawIdx = candles.partitioningIndex { $0.endGlobalIndex >= tick }
        let currentIdx = min(rawIdx, count - 1)
```

替换为调用新抽谓词（保留原注释于谓词处）：

```swift
        let currentIdx = currentCandleIndex(candles: candles, tick: tick)
```

并在 makeViewport 函数之后新增（同 enum 内）：

```swift
    /// 当前 candle 索引单一谓词（顺位 3 D3/R1-M1：makeViewport 与 engine.applyPinch 共用，禁双实现）。
    /// 面板自身 period 中首个 endGlobalIndex>=tick（超末根取末根）。
    /// 仅谓词同 E5 currentPrice；序列为面板自身 period（聚合面板必须在自身序列定位，勿改读 .m3）。
    /// **前置**：candles 非空。
    static func currentCandleIndex(candles: [KLineCandle], tick: Int) -> Int {
        let rawIdx = candles.partitioningIndex { $0.endGlobalIndex >= tick }
        return min(rawIdx, candles.count - 1)
    }
```

（makeViewport 原 L71-72 注释「当前 candle 索引…勿改读 .m3」随谓词移动，原位删除。）

- [ ] **Step 1.4: 跑测试确认通过 + 全量回归**

Run: `cd ios/Contracts && swift test --filter PinchZoomModelTests 2>&1 | tail -3`
Expected: PASS（12 tests）。
Run: `cd ios/Contracts && swift test 2>&1 | tail -2`
Expected: `Test run with 876 tests in 124 suites passed`（864 + 12，0 failures；抽谓词零行为变化）。

- [ ] **Step 1.5: mutation-verify（设计 D3 义务，FP demonstrator 教训）**

把 `rezoomOffset` 中 `+ CGFloat(newCount) - 1` 临时改为 `+ CGFloat(newCount)`，跑 `swift test --filter PinchZoomModelTests`，**预期至少 4 个 focus 向量测试 FAIL**（Task 1 内 rightEdge/mid/nonzero/identity 四向量直构视口、不依赖 makeViewport，杀手有效）；恢复原公式，复跑确认 12 tests 全绿。在 commit message 记录「mutation-verified」。

- [ ] **Step 1.6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/PinchZoomModel.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/PinchZoomModelTests.swift
git commit -m "feat(pinch): PinchZoomModel 纯数学（clamp+focus）+ currentCandleIndex 共享谓词（mutation-verified）"
```

---

### Task 2: makeViewport 去硬编码（D5）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:62-66`（geometry 块 L67-69 保留）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（追加用例，含 endToEndFocusInvariant）

- [ ] **Step 2.1: 写失败测试（追加到 RenderStateBuilderTests）**

```swift
    // MARK: 顺位 3 D5：去硬编码 80（target = panelState.visibleCount，≤0 → fallback 80）

    /// 非 0 显式入参 + 80 golden parity（独立金值硬编码，R1-L3 防 tautology）
    @Test("D5 parity：visibleCount=80 显式入参 ≡ 旧 80 行为（金值：step=10/startIndex=71/count=80）")
    func explicitEightyMatchesGolden() {
        let ps = PanelViewState(period: .m3, interactionMode: .autoTracking,
                                visibleCount: 80, offset: 0, revision: 0)
        let vp = RenderStateBuilder.makeViewport(
            panelState: ps, candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 10) < 1e-9)   // 800/80（金值手算，非新公式推导）
        #expect(vp.startIndex == 71)                        // 150−79
        #expect(vp.visibleCount == 80)
        #expect(abs(vp.geometry.candleWidth - 7) < 1e-9)
    }

    @Test("D5 缩放生效：visibleCount=40 → step=20、startIndex=111（右锚 40 根）")
    func fortyVisible() {
        let ps = PanelViewState(period: .m3, interactionMode: .autoTracking,
                                visibleCount: 40, offset: 0, revision: 0)
        let vp = RenderStateBuilder.makeViewport(
            panelState: ps, candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 20) < 1e-9)   // 800/40
        #expect(vp.startIndex == 111)                       // 150−39
        #expect(vp.visibleCount == 40)
    }

    @Test("D5 放宽视野撞老边界：visibleCount=160、currentIdx=150 → startIndex clamp 后边缘饱和")
    func oneSixtyVisibleSaturates() {
        let ps = PanelViewState(period: .m3, interactionMode: .freeScrolling,
                                visibleCount: 160, offset: 15, revision: 0)
        let vp = RenderStateBuilder.makeViewport(
            panelState: ps, candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 5) < 1e-9)    // 800/160
        // baseStart=150−159=−9，wholeShift=floor(15/5)=3 → −12 → clamp 0；startIndex==0 → pixelShift 饱和置 0
        #expect(vp.startIndex == 0)
        #expect(vp.pixelShift == 0)
        #expect(vp.visibleCount == 160)
    }

    @Test("D5 数据不足左对齐：count=100 < target=160 → visibleCount=100、分母仍 target（step=5）")
    func leftFillWhenDataShort() {
        let ps = PanelViewState(period: .m3, interactionMode: .autoTracking,
                                visibleCount: 160, offset: 0, revision: 0)
        let vp = RenderStateBuilder.makeViewport(
            panelState: ps, candles: Self.candles(period: .m3, count: 100),
            tick: 99, bounds: Self.bounds)
        #expect(vp.visibleCount == 100)
        #expect(abs(vp.geometry.candleStep - 5) < 1e-9)    // 800/160：分母 = target 非 count
        #expect(vp.startIndex == 0)
    }

    @Test("D5 fallback：visibleCount=0（旧构造）→ 80（既有 helper 兼容性显式断言）")
    func zeroFallsBackToEighty() {
        let vp = RenderStateBuilder.makeViewport(
            panelState: Self.panel(), candles: Self.candles(period: .m3, count: 200),
            tick: 150, bounds: Self.bounds)
        #expect(abs(vp.geometry.candleStep - 10) < 1e-9)
        #expect(vp.visibleCount == 80)
    }

    // 端到端 focus 不变量（Plan-R2 PR2-01：从 Task 1 移此处——依赖去硬编码后 makeViewport honor visibleCount）。
    @Test("D5 端到端 focus：makeViewport 缩放前后 u(fx) 连续域 <1e-9 + 离散 candle 不变（fx 取 candle 中心）")
    func endToEndFocusInvariant() {
        let candles = Self.candles(period: .m3, count: 200)
        // freeScrolling offset=15：vpBefore startIndex=70/pixelShift=5/step=10（非饱和中段，R1-L4）
        var before = PanelViewState(period: .m3, interactionMode: .freeScrolling,
                                    visibleCount: 80, offset: 15, revision: 0)
        let vpBefore = RenderStateBuilder.makeViewport(panelState: before, candles: candles,
                                                       tick: 150, bounds: Self.bounds)
        let cIdx = RenderStateBuilder.currentCandleIndex(candles: candles, tick: 150)
        // fx = 第 40 个可见 slot 中心 x = 40·10 + 5 + 5 = 410；uBefore = 70 + (410−5)/10 = 110.5
        let fx: CGFloat = 410
        let uBefore = CGFloat(vpBefore.startIndex) + (fx - vpBefore.pixelShift) / vpBefore.geometry.candleStep
        let newCount = 40
        let newOffset = PinchZoomModel.rezoomOffset(viewport: vpBefore, currentIdx: cIdx,
                                                    focusX: fx, newCount: newCount, mainWidth: 800)
        before.visibleCount = newCount
        before.offset = newOffset
        let vpAfter = RenderStateBuilder.makeViewport(panelState: before, candles: candles,
                                                      tick: 150, bounds: Self.bounds)
        let uAfter = CGFloat(vpAfter.startIndex) + (fx - vpAfter.pixelShift) / vpAfter.geometry.candleStep
        #expect(abs(uAfter - uBefore) < 1e-9)          // uAfter = 90 + (410−0)/20 = 110.5
        let mBefore = CoordinateMapper(viewport: vpBefore, displayScale: 1)
        let mAfter = CoordinateMapper(viewport: vpAfter, displayScale: 1)
        #expect(mBefore.xToIndex(fx) == mAfter.xToIndex(fx))
    }
```

- [ ] **Step 2.2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter RenderStateBuilderTests 2>&1 | tail -5`
Expected: `fortyVisible`/`oneSixtyVisibleSaturates`/`leftFillWhenDataShort`/`endToEndFocusInvariant` FAIL（现实现忽略 panelState.visibleCount，恒 80 分母——endToEnd 的 vpAfter 用 step=10 → uAfter=70≠110.5）；parity/fallback 两条 PASS。

- [ ] **Step 2.3: 实现去硬编码**

`RenderStateBuilder.swift` makeViewport 内（替换 L62-66：count/visibleCount/注释/candleStep；**geometry 块 L67-69 保留不动，复用新 candleStep**）：

```swift
        let count = candles.count
        // 顺位 3 D5 去硬编码：target = panelState.visibleCount（≤0 → fallback 80 兼容旧构造；
        // engine init 已 seed 80，新路径不依赖 fallback）。
        let target = panelState.visibleCount > 0 ? panelState.visibleCount : defaultVisibleCount
        let visibleCount = min(target, count)

        // 几何：分母 = target（count<target 时左对齐填充、candle 宽度稳定；target==80 与旧行为逐位一致）。
        let candleStep = mainFrame.width / CGFloat(target)
```

同步更新两处 stale 注释（本 PR 使其失真，surgical 范围内）：
- 文件头 L7-8（旧串逐字：`// 视口几何 spec 无公式 → 本 PR 固定 defaultVisibleCount=80 分母 + 条件锚定 + offset 分解（Wave 2 占位；\n// pinch 缩放改 visibleCount 属 Wave 3）。`，注意「本 PR 」）→ `// 视口几何：分母 = panelState.visibleCount（顺位 3 去硬编码；≤0 fallback 80）+ 条件锚定 + offset 分解。`
- L13：`/// 渲染常量（spec 无公式，本 PR 占位）。pinch 缩放改 visibleCount 属 Wave 3/C8b。` → `/// 渲染常量。defaultVisibleCount = seed/fallback 单一来源（engine init 与 ≤0 兜底共用）；zoom clamp 在 PinchZoomModel。`

- [ ] **Step 2.4: 跑测试确认通过 + 全量回归**

Run: `cd ios/Contracts && swift test 2>&1 | tail -2`
Expected: `882 tests in 124 suites passed`（876 + 6；既有 RenderStateBuilder/C5/C8b 等消费方全绿 = 80-parity 实证）。

- [ ] **Step 2.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
git commit -m "feat(pinch): makeViewport 去硬编码 80（D5：target=panelState.visibleCount，分母=target，0-fallback）"
```

---

### Task 3: Reducer `zoomApplied`（D1 矩阵）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift:101`（ChartAction）+ `:162`（reduce switch）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerZoomTests.swift`

- [ ] **Step 3.1: 写失败测试**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerZoomTests.swift`：

```swift
// 顺位 3 ChartAction.zoomApplied reducer 测试（设计 D1 矩阵）
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("Reducer zoomApplied（D1 三 mode 矩阵）")
struct ReducerZoomTests {

    static func panel(_ mode: ChartInteractionMode, visibleCount: Int = 80,
                      offset: CGFloat = 0, revision: UInt64 = 7) -> PanelViewState {
        PanelViewState(period: .m3, interactionMode: mode,
                       visibleCount: visibleCount, offset: offset, revision: revision)
    }

    @Test("autoTracking：visibleCount 应用 + offset 显式置 0（非 leave-unchanged）+ bump")
    func autoTrackingZeroesOffset() {
        // offset 预置非 0（模拟顺位 4 未来 drawingCommitted 残留，R1-M3 防御可观测）
        var p = Self.panel(.autoTracking, offset: 37)
        let effect = p.reduce(.zoomApplied(visibleCount: 40, offset: 123))
        #expect(p.visibleCount == 40)
        #expect(p.offset == 0)              // 显式置 0：入参 123 不被读取
        #expect(p.revision == 8)
        #expect(effect == .none)
        #expect(p.interactionMode == .autoTracking)   // 不切 mode
    }

    @Test("freeScrolling：visibleCount + offset 双应用 + bump")
    func freeScrollingAppliesBoth() {
        var p = Self.panel(.freeScrolling, offset: 15)
        let effect = p.reduce(.zoomApplied(visibleCount: 160, offset: -192.5))
        #expect(p.visibleCount == 160)
        #expect(abs(p.offset - (-192.5)) < 1e-9)
        #expect(p.revision == 8)
        #expect(effect == .none)
        #expect(p.interactionMode == .freeScrolling)
    }

    @Test("drawing：吞没——状态零改动（含 revision 不 bump），同 offsetApplied 先例")
    func drawingSwallows() {
        let snapshot = DrawingSnapshot(frozen: FrozenPanelState(
            period: .m3, visibleCount: 80, offset: 0, candleRange: 0..<80, baseRevision: 7))
        var p = Self.panel(.drawing(snapshot: snapshot))
        let before = p
        let effect = p.reduce(.zoomApplied(visibleCount: 40, offset: 99))
        #expect(p == before)
        #expect(effect == .none)
    }
}
```

- [ ] **Step 3.2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter ReducerZoomTests 2>&1 | tail -5`
Expected: 编译失败 `type 'ChartAction' has no member 'zoomApplied'`。

- [ ] **Step 3.3: 实现**

`Reducer.swift` ChartAction 末尾（L101 `offsetApplied` 之后）加：

```swift
    /// 顺位 3 §4.4d pinch 缩放：几何在 engine 侧算好（PinchZoomModel），reducer 只收最终值。
    case zoomApplied(visibleCount: Int, offset: CGFloat)
```

reduce switch 的 offsetApplied 块之后（L162 后）加：

```swift
        // —— zoomApplied（顺位 3 §4.4d：drawing 吞；autoTracking 右锚置 0；freeScrolling focus offset）——
        case (.drawing, .zoomApplied):
            return .none
        case (.autoTracking, .zoomApplied(let v, _)):
            visibleCount = v
            offset = 0      // user 2026-06-13 裁决 A 右锚：显式置 0（防未来 drawingCommitted 残留 offset，R1-M3/L5）
            revision &+= 1
            return .none
        case (.freeScrolling, .zoomApplied(let v, let o)):
            visibleCount = v
            offset = o
            revision &+= 1
            return .none
```

（switch 对 (mode, action) 穷尽无 default——漏分支编译即报错，自带完备性守护。）

- [ ] **Step 3.4: 跑测试确认通过 + 全量回归**

Run: `cd ios/Contracts && swift test 2>&1 | tail -2`
Expected: `885 tests in 125 suites passed`（882 + 3）。

- [ ] **Step 3.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ReducerZoomTests.swift
git commit -m "feat(pinch): ChartAction.zoomApplied 三 mode 矩阵（autoTracking 右锚显式置 0 = 裁决 A）"
```

---

### Task 4: Engine `applyPinch` + `pinchBase` + init seed 80（D6）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（主类体 L41 区 + init L123-126 + chart-interaction extension）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePinchTests.swift`

- [ ] **Step 4.1: 写失败测试**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePinchTests.swift`：

```swift
// 顺位 3 engine applyPinch 编排测试（设计 D6）
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite struct TrainingEnginePinchTests {

    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// 复用 InteractionTests 夹具风格：单 .m3 双面板 + fake 减速驱动 + 已记录渲染 bounds。
    static func engine(closes: [Double] = Array(repeating: 10, count: 200))
        -> (TrainingEngine, () -> [FakeFrameDriver]) {
        final class Box { var fakes: [FakeFrameDriver] = [] }
        let box = Box()
        let maxTick = closes.count - 1
        let e = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
                             maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(closes),
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { onTick in
                let f = FakeFrameDriver(onTick: onTick); box.fakes.append(f); return f
            })
        e.recordRenderBounds(Self.bounds, panel: .upper)
        e.recordRenderBounds(Self.bounds, panel: .lower)
        return (e, { box.fakes })
    }

    @Test("init seed：双面板 visibleCount == 80（D5，不再是 0）")
    func initSeedsEighty() {
        let (e, _) = Self.engine()
        #expect(e.upperPanel.visibleCount == 80)
        #expect(e.lowerPanel.visibleCount == 80)
    }

    @Test("began 停本面板减速（同 beginPan 先例）")
    func beganStopsDeceleration() {
        let (e, fakes) = Self.engine()
        e.beginPan(panel: .upper)
        e.endPan(velocity: 1000, panel: .upper)
        #expect(fakes()[0].isInvalidated == false)
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        #expect(fakes()[0].isInvalidated == true)
    }

    @Test("autoTracking 缩放：scale=2 → visibleCount 40，offset 恒 0，mode 不变（裁决 A 右锚）")
    func autoTrackingZoom() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
        #expect(e.upperPanel.offset == 0)
        #expect(e.upperPanel.interactionMode == .autoTracking)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .ended, panel: .upper)
    }

    @Test("scaleAtBegan 归一（R1-L1）：began 于 1.02 → changed 1.02 无变化（effectiveScale=1）")
    func normalizationKillsDeadZone() {
        let (e, _) = Self.engine()
        let r0 = e.upperPanel.revision
        e.applyPinch(scale: 1.02, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 1.02, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 80)
        #expect(e.upperPanel.revision == r0)       // target==current → 跳过派发，不 bump
        // 继续张开到 2.04 → effectiveScale=2 → 40
        e.applyPinch(scale: 2.04, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
    }

    @Test("非有限/非正 scale → guard return 真无操作（R2-L1：不派发、状态零改动）")
    func nonFiniteScaleNoOp() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        let before = e.upperPanel
        e.applyPinch(scale: .nan, focusX: 400, phase: .changed, panel: .upper)
        e.applyPinch(scale: .infinity, focusX: 400, phase: .changed, panel: .upper)
        e.applyPinch(scale: 0, focusX: 400, phase: .changed, panel: .upper)
        e.applyPinch(scale: -1, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel == before)
    }

    @Test("bounds 未记录 → changed no-op（防御）")
    func zeroBoundsNoOp() {
        // fixture 已记录双面板 bounds → 此测试独立构造从未 recordRenderBounds 的 engine
        let maxTick = 199
        let e2 = TrainingEngine(
            flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
                             maxTick: maxTick),
            allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: 200)),
            maxTick: maxTick,
            initialCapital: 100_000, initialCashBalance: 100_000,
            initialUpperPeriod: .m3, initialLowerPeriod: .m3,
            decelerationDriverFactory: { FakeFrameDriver(onTick: $0) })
        e2.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        let before = e2.upperPanel
        e2.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e2.upperPanel == before)
    }

    @Test("self-heal（D6）：changed 先于 began → 以当前值+当前 scale 补 seed，首拍无跳变")
    func selfHealOnMissingBegan() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.7, focusX: 400, phase: .changed, panel: .upper)   // 无 began
        #expect(e.upperPanel.visibleCount == 80)        // effectiveScale=1 → 不变
        e.applyPinch(scale: 3.4, focusX: 400, phase: .changed, panel: .upper)   // 相对 1.7 翻倍
        #expect(e.upperPanel.visibleCount == 40)
        e.applyPinch(scale: 3.4, focusX: 400, phase: .ended, panel: .upper)
    }

    @Test("ended/cancelled 清 base：下一次 changed 重新 self-heal 不串味")
    func endedClearsBase() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)   // → 40
        e.applyPinch(scale: 2.0, focusX: 400, phase: .ended, panel: .upper)
        // 新手势：changed-only，scale=2.0 起步 → self-heal base=(40, 2.0) → effectiveScale=1 → 40 不变
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
    }

    @Test("per-panel 隔离：upper 缩放不影响 lower")
    func perPanelIsolation() {
        let (e, _) = Self.engine()
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
        #expect(e.lowerPanel.visibleCount == 80)
    }

    @Test("freeScrolling focus 端到端：缩放前后 pinch 中点连续索引不变 + 离散 candle 不变")
    func freeScrollingFocusInvariant() {
        let (e, _) = Self.engine()
        e.beginPan(panel: .upper)
        e.applyPanOffset(deltaPixels: 15, panel: .upper)     // freeScrolling offset=15
        let candles = e.allCandles[.m3]!
        let tick = e.tick.globalTickIndex
        let vpBefore = RenderStateBuilder.makeViewport(panelState: e.upperPanel, candles: candles,
                                                       tick: tick, bounds: Self.bounds)
        // NormalFlow.initialTick==0 → currentIdx==0 → before 视口左缘饱和（startIndex=0/pixelShift=0）；
        // fx=405 仍为 candle 40 槽中心（远离 candle 边界，离散锚有判别力），前后离散索引恒 40。
        // 非饱和-中段 focus 路径由 Task 1 endToEndFocusInvariant（tick=150）覆盖。
        let fx: CGFloat = 405
        let uBefore = CGFloat(vpBefore.startIndex) + (fx - vpBefore.pixelShift) / vpBefore.geometry.candleStep
        e.applyPinch(scale: 1.0, focusX: fx, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: fx, phase: .changed, panel: .upper)
        #expect(e.upperPanel.visibleCount == 40)
        let vpAfter = RenderStateBuilder.makeViewport(panelState: e.upperPanel, candles: candles,
                                                      tick: tick, bounds: Self.bounds)
        let uAfter = CGFloat(vpAfter.startIndex) + (fx - vpAfter.pixelShift) / vpAfter.geometry.candleStep
        #expect(abs(uAfter - uBefore) < 1e-9)
        let mB = CoordinateMapper(viewport: vpBefore, displayScale: 1)
        let mA = CoordinateMapper(viewport: vpAfter, displayScale: 1)
        #expect(mB.xToIndex(fx) == mA.xToIndex(fx))
        #expect(e.upperPanel.interactionMode == .freeScrolling)   // 不切 mode
    }

    @Test("revision 单调：每次生效 changed bump 一次；目标不变跳过不 bump")
    func revisionMonotone() {
        let (e, _) = Self.engine()
        let r0 = e.upperPanel.revision
        e.applyPinch(scale: 1.0, focusX: 400, phase: .began, panel: .upper)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)
        #expect(e.upperPanel.revision == r0 + 1)
        e.applyPinch(scale: 2.0, focusX: 400, phase: .changed, panel: .upper)   // target 不变
        #expect(e.upperPanel.revision == r0 + 1)
        e.applyPinch(scale: 2.1, focusX: 400, phase: .changed, panel: .upper)   // 80/2.1→38
        #expect(e.upperPanel.revision == r0 + 2)
    }
}
```

- [ ] **Step 4.2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingEnginePinchTests 2>&1 | tail -5`
Expected: 编译失败 `value of type 'TrainingEngine' has no member 'applyPinch'`（initSeedsEighty 在实现 seed 前也会 FAIL）。

- [ ] **Step 4.3: 实现**

(1) `TrainingEngine.swift` 主类体（`lastRenderedBounds` L41 之后）加存储属性：

```swift
    /// 顺位 3 pinch per-gesture 状态（设计 D6）：`.began` 捕获（base visibleCount, scaleAtBegan）；
    /// `.ended/.cancelled` 清空。scaleAtBegan 用于锁定点归一（D4，消 ±2% 死区）。
    @ObservationIgnored private var pinchBase:
        (upper: (base: Int, scaleAtBegan: CGFloat)?, lower: (base: Int, scaleAtBegan: CGFloat)?) = (nil, nil)
```

(2) init L123-126 seed 80（注释一并更新）：

```swift
        // D7：初始周期组合默认 上区 60m / 下区 日线（plan v1.5 L777）；resume 传入保存的组合（R6）。
        // visibleCount seed 80（顺位 3 D5；zoom ephemeral 不持久，resume 重建恒 80）。
        self.upperPanel = PanelViewState(period: initialUpperPeriod, interactionMode: .autoTracking,
                                         visibleCount: RenderStateBuilder.defaultVisibleCount,
                                         offset: 0, revision: 0)
        self.lowerPanel = PanelViewState(period: initialLowerPeriod, interactionMode: .autoTracking,
                                         visibleCount: RenderStateBuilder.defaultVisibleCount,
                                         offset: 0, revision: 0)
```

(3) chart-interaction extension（`cancelPan` 之后、`recordRenderBounds` 之前）加：

```swift
    // MARK: pinch 缩放手势派发（C7 arbiter onPinch 回调下游；RFC §4.4d + 设计 D6）

    /// onPinch 全相位入口。autoTracking = 右锚缩放（offset 置 0，user 2026-06-13 裁决 A）；
    /// freeScrolling = focus 不变量（pinch 中点 candle x 不动，PinchZoomModel.rezoomOffset）；
    /// drawing 由 reducer 吞没（engine 不预判，统一派发）。
    /// scale 为识别器 per-gesture 累积值，按 `.began` 时刻 scaleAtBegan 归一（D4）。
    public func applyPinch(scale: CGFloat, focusX: CGFloat, phase: GesturePhase, panel: PanelId) {
        switch phase {
        case .began:
            animator(for: panel).stop()        // 同 beginPan 先例：手势起手截住惯性
            setPinchBase(seedPinchBase(scale: scale, panel: panel), panel: panel)
        case .changed:
            // R2-L1：非有限/非正 scale → 真无操作（不派发、状态零改动；防御在 engine 不在模型）
            guard scale.isFinite, scale > 0 else { return }
            let bounds = renderBounds(panel)
            guard bounds.width > 0, bounds.height > 0 else { return }   // 未渲染过 → no-op
            // 自愈（D6）：base 缺失或非法（began 携非法 scale）→ 以当前值+当前 scale 重 seed；
            // 重 seed 后首拍 effectiveScale=1 → target==current → 跳过，无跳变。
            var base = pinchBaseFor(panel) ?? seedPinchBase(scale: scale, panel: panel)
            if !(base.scaleAtBegan.isFinite && base.scaleAtBegan > 0) {
                base = seedPinchBase(scale: scale, panel: panel)
            }
            setPinchBase(base, panel: panel)
            let target = PinchZoomModel.targetVisibleCount(base: base.base,
                                                           effectiveScale: scale / base.scaleAtBegan)
            let ps = panelState(panel)
            guard target != effectiveVisibleCount(ps) else { return }   // N 不变 → 跳过（不 bump）
            switch ps.interactionMode {
            case .freeScrolling:
                assert(bounds.origin == .zero, "focus 数学假设 view-local bounds 原点 .zero（R1-L6）")
                let candles = allCandles[ps.period] ?? []
                guard !candles.isEmpty else { return }
                let vp = RenderStateBuilder.makeViewport(panelState: ps, candles: candles,
                                                         tick: tick.globalTickIndex, bounds: bounds)
                let cIdx = RenderStateBuilder.currentCandleIndex(candles: candles,
                                                                 tick: tick.globalTickIndex)
                let offset = PinchZoomModel.rezoomOffset(viewport: vp, currentIdx: cIdx,
                                                         focusX: focusX, newCount: target,
                                                         mainWidth: vp.mainChartFrame.width)
                _ = reduce(.zoomApplied(visibleCount: target, offset: offset), on: panel)
            case .autoTracking, .drawing:
                // autoTracking：reducer 右锚显式置 0；drawing：reducer 吞没（入参不被读取）
                _ = reduce(.zoomApplied(visibleCount: target, offset: 0), on: panel)
            }
        case .ended, .cancelled:
            setPinchBase(nil, panel: panel)
        }
    }

    /// 有效 visibleCount（≤0 → 80 fallback；engine init 已 seed 80，此处纯防御，D5/R1-L7）。
    private func effectiveVisibleCount(_ ps: PanelViewState) -> Int {
        ps.visibleCount > 0 ? ps.visibleCount : RenderStateBuilder.defaultVisibleCount
    }

    private func seedPinchBase(scale: CGFloat, panel: PanelId) -> (base: Int, scaleAtBegan: CGFloat) {
        (base: effectiveVisibleCount(panelState(panel)), scaleAtBegan: scale)
    }

    private func pinchBaseFor(_ panel: PanelId) -> (base: Int, scaleAtBegan: CGFloat)? {
        panel == .upper ? pinchBase.upper : pinchBase.lower
    }

    private func setPinchBase(_ v: (base: Int, scaleAtBegan: CGFloat)?, panel: PanelId) {
        switch panel {
        case .upper: pinchBase.upper = v
        case .lower: pinchBase.lower = v
        }
    }
```

- [ ] **Step 4.4: 跑测试确认通过 + 全量回归**

Run: `cd ios/Contracts && swift test 2>&1 | tail -2`
Expected: `896 tests in 126 suites passed`（885 + 11）。特别确认既有 E5a/E5b/E6/C8b 套件全绿（init seed 0→80 无既有断言依赖 0，设计 R1/R5 已实证）。

- [ ] **Step 4.5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEnginePinchTests.swift
git commit -m "feat(pinch): engine.applyPinch 编排（pinchBase 归一 + mode 分派 + guard）+ init seed 80"
```

---

### Task 5: ChartContainerView onPinch 接线 + Catalyst 编译闸

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift:90`

- [ ] **Step 5.1: 实现接线**

`ChartContainerView.swift` `attach(to:)` 内，替换 L90 注释行：

```swift
            // onPinch（缩放改 visibleCount）属 Wave 3；onTap（画线锚点）需 DrawingInputController（Wave 3）→ C8b 不接。
```

为：

```swift
            arbiter.onPinch = { [weak self] scale, focus, phase in
                guard let self, let engine = self.engine else { return }
                engine.applyPinch(scale: scale, focusX: focus.x, phase: phase, panel: self.panel)
            }
            // onTap（画线锚点）需 DrawingInputController（顺位 4）→ 本锚不接。
```

- [ ] **Step 5.2: host 编译验证（UIKit 面 macOS 编译为空，仅验证不破坏）**

Run: `cd ios/Contracts && swift build 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 5.3: 本地 Catalyst build-for-testing（UIKit 面真编译，PR #84 de-risk 先例）**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -3`
Expected: `** TEST BUILD SUCCEEDED **`（若本机无 Xcode 16 toolchain 则记录 deferred-to-CI，CI required check 兜底——不得静默跳过，须在 commit message 注明）。

- [ ] **Step 5.4: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift
git commit -m "feat(pinch): ChartContainerView onPinch → engine.applyPinch 接线（C7 仲裁消费闭口）"
```

---

### Task 6: 四 doc amendment（D9，两项 user 裁决落档）+ gate 复跑

**Files:**
- Modify: `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md`
- Modify: `docs/superpowers/specs/2026-06-09-wave3-outline-design.md`
- Modify: `kline_trainer_modules_v1.4.md`
- Modify: `kline_trainer_plan_v1.5.md`

全部 amendment 以**追加注记**落地（不删原文，supersede-marker 治理范式）。逐项 old→new：

- [ ] **Step 6.1: RFC §4.4d 两行注记（D9.1 a/b）**

(a) 在行 `**实施**：顺位 6 加 mutation；顺位 3 消费（去硬编码 80 + pinch 手势接线）。` 之后追加新行：

```markdown
> 【impl-anchor 重指派注记（user 2026-06-12 裁决，PR #97 6b plan §Scope；顺位 3 PR 落档）：§4.4d 整条（mutation + focus + 去硬编码 + pinch 手势）移顺位 3 同 PR 实施，上行「顺位 6 加 mutation / 顺位 3 消费」拆分 superseded。】
```

(b) 在行 `- 语义：改 \`panelState.visibleCount\` 于 clamp \`[MIN_VISIBLE, MAX_VISIBLE]\` 内 + 保持 focus（pinch 中点下的 candle x 不动，重算 offset）。` 之后追加新行：

```markdown
> 【focus 语义裁决注记（user 2026-06-13 裁决，顺位 3 设计 R1-H1 上浮）：focus 不变量限定 freeScrolling；autoTracking = 右锚缩放（offset 恒 0，「锁定最新」优先）。理由与被否选项见 `docs/superpowers/specs/2026-06-13-wave3-pr3-pinch-zoom-design.md` D2。】
```

- [ ] **Step 6.2: RFC §4.4 总纲 canonical neck caveat + 三处短标（D9.1 c）**

在 §4.4 总纲段（`**总纲**：\`TrainingEngine\` 跨「轨 G 图表」…本节钉死该 5 子项 API 面。`）之后追加：

```markdown
> 【neck-doctrine zoom 例外注记（user 2026-06-12 裁决；顺位 3 PR 落档）：§4.4d zoom 经裁决移顺位 3 同 PR 实施（顺位 3 新增 `ChartAction.zoomApplied` + `engine.applyPinch` + pinch 手势态）；本总纲「所有 engine 契约变更集中顺位 6 / 消费锚不改 engine 契约」对 zoom 部分 superseded，对其余 §4.1/§4.4a-c/§4.4e 仍成立。本注记适用 RFC 全文同款表述（§一(D)、§三 概览表「6 实现，3/4/7/8 消费」行、§4.4 标题）。】
```

三处短标（在原句末尾追加，不改原文其余）：
- §一(D) bullet（L18）行末加：`（zoom 除外，见 §4.4 总纲注记）`
- §三 概览表第 4 行（L49）`| 6 实现，3/4/7/8 消费 |` 改为 `| 6 实现，3/4/7/8 消费（zoom 除外，见 §4.4 总纲注记） |`
- §4.4 标题（L111）行末加：`（zoom 除外，见总纲注记）`

- [ ] **Step 6.3: outline document-scoped callout（D9.2）**

在 §二 顺位总览表（顺位 13 行）之后、`**Phase 划分**：` 之前插入：

```markdown
> 【§4.4d zoom 重指派 callout（document-scoped；user 2026-06-12 + 2026-06-13 两裁决；顺位 3 PR 落档）：§4.4d zoom 整条（engine mutation `zoomApplied`/`applyPinch` + focus + 去硬编码 80 + pinch 手势）经 user 2026-06-12 裁决移顺位 3 同 PR 实施。本 callout 适用**全文**所有「engine 契约变更集中顺位 6 / 消费锚（含 3）不改 engine 契约 / serial neck」表述——§二 row 3（L58 prose 与依赖格「2 + 6（若需…归 6；纯 render 则仅 2）」条件分支已由裁决 resolve：zoom 落顺位 3）、row 6（L61）、§三 DAG（L81/L90）、W1 波次（L111）、关键路径（L124）——以上对 zoom 部分 superseded，对其余 §4.1/§4.4a-c/§4.4e 契约仍成立；版本历史 log 行不改（历史保真）。neck 目的不破：仅顺位 3〔轨 G〕改 panelState.visibleCount/zoom 契约，轨 T 不碰，无并发冲突（PR #97 6b plan 已论证）。focus 语义：user 2026-06-13 裁决 A——focus 不变量限 freeScrolling，autoTracking 右锚（顺位 3 设计 D2）。】
```

- [ ] **Step 6.4: modules 两处 amendment（D9.3 + D9.5）**

(1) `:1738` E5 头部，行末（`消费锚 3/4/7/8 不改 engine 契约）` 的右括号之前）插入：`；**§4.4d zoom 除外**：经 user 2026-06-12 裁决移顺位 3 同 PR 实施〔`zoomApplied`+`applyPinch`〕，neck 对其余 §4.1/§4.4a-c/§4.4e 仍成立`

(2) `:1743` bullet，在 `+ 保持 focus（pinch 中点 candle x 不动，重算 offset）` 之后插入：`〔focus 限 freeScrolling：autoTracking = 右锚缩放（offset 恒 0，锁定最新优先），user 2026-06-13 裁决，见顺位 3 设计 D2〕`

**约束**：两处编辑均不得触碰机器锚短语 `pinch/zoom panel-state mutation`（1743 bullet 加粗引导词，gate 谓词 (a) 锁定）。

- [ ] **Step 6.5: plan v1.5 两处 amendment（D9.4）**

(1) L1037 §七 触控交互表行：

```markdown
| 两指捏合/张开 | K 线缩放（freeScrolling 以捏合焦点为中心；autoTracking 右锚锁定最新——user 2026-06-13 裁决，见顺位 3 设计 D2） | UIPinchGestureRecognizer |
```

(2) L1180 §Phase 9 行：

```markdown
   - UIPinchGestureRecognizer → 缩放（freeScrolling 以焦点为中心；autoTracking 右锚——user 2026-06-13 裁决，见顺位 3 设计 D2）
```

- [ ] **Step 6.6: gate 复跑（D9.3 收窄范围，R2-M1/R3-M1）**

Run: `bash scripts/governance/verify-wave3-pr1-rfc.sh; echo "exit=$?"`
Expected 输出逐行核对：
- `(a) PASS`（机器锚 `pinch/zoom panel-state mutation` 仍命中——amendment 未碰引导词）
- `(b) PASS` `(c) PASS` `(d) PASS` `(e) PASS`
- `(f) FAIL: 非白名单改动文件…`（**预期**：本实施分支合法改 .swift；scope 谓词为顺位 1 RFC PR 专属，不作本 PR 门）
- `(g) PASS`（本 PR 不碰 2026-05 冻结 doc；若 FAIL = 误改冻结历史，**必须修**）
- `exit=1`（仅 (f) 所致）

- [ ] **Step 6.7: Commit**

```bash
git add docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md \
        docs/superpowers/specs/2026-06-09-wave3-outline-design.md \
        kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md
git commit -m "docs(pinch): 四 doc amendment——zoom 6→3 重指派 + focus 裁决 A 落档（D9；gate 内容谓词复跑 (a)-(e)+(g) PASS）"
```

---

### Task 7: acceptance checklist + 运行时 runbook 条目 + 终验

**Files:**
- Create: `docs/acceptance/2026-06-13-wave3-pr3-pinch-zoom.md`

- [ ] **Step 7.1: 写 acceptance 文档**

内容骨架（中文；每条 action / expected / pass-fail 三段、判据二元可决；禁用短语：`验证通过即可`/`看起来正常`/`应该没问题`/`should work`/`looks fine`）：

```markdown
# 验收清单 — Wave 3 顺位 3：Pinch 缩放（§4.4d engine-owned zoom）

**交付物：** `PinchZoomModel`（clamp 20/240 + focus 数学）+ `ChartAction.zoomApplied`（3 mode 矩阵，autoTracking 右锚显式置 0 = user 2026-06-13 裁决 A）+ `engine.applyPinch`（pinchBase 归一 + guard）+ `makeViewport` 去硬编码 80 + `ChartContainerView` onPinch 接线 + 四 doc amendment（zoom 6→3 重指派 + focus 裁决落档）。设计经 opus 4.8 xhigh 5 轮对抗评审收敛 APPROVE。

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | `896 tests in 126 suites passed`，`0 failures`（864 baseline + 32 新增） | ☐ |
| 2 | `git diff origin/main...HEAD --stat -- ios/` 逐行核对 | 改动 Swift 文件集 ⊆ {PinchZoomModel.swift(新), RenderStateBuilder.swift, Reducer.swift, TrainingEngine.swift, ChartContainerView.swift} + 4 测试文件；无 .sql/schema/CONTRACT_VERSION/workflow 改动 | ☐ |
| 3 | `git diff origin/main...HEAD -- ios/ \| grep -E "func (saveProgress\|finalize)" ; echo rc=$?` | `rc=1`（零命中 = saveProgress/finalize 方法体零改动，ephemeral 不变量；RFC §4.4d） | ☐ |
| 4 | `bash scripts/governance/verify-wave3-pr1-rfc.sh` | `(a)(b)(c)(d)(e)(g) PASS`；仅 `(f) FAIL`（实施分支改 .swift 属预期，scope 谓词为顺位 1 PR 专属） | ☐ |
| 5 | `grep -c "user 2026-06-13 裁决" kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` | 三文件计数分别 ≥1（focus 裁决 A 落档在位） | ☐ |
| 6 | `grep -cF "pinch/zoom panel-state mutation" kline_trainer_modules_v1.4.md` | ≥1（机器锚未被 amendment 破坏） | ☐ |
| 7 | Mac Catalyst CI：PR checks 页查 `Mac Catalyst build-for-testing on macos-15` | SUCCESS（onPinch 接线 UIKit 面真编译） | ☐ |
| 8 | app-target CI：PR checks 页查顺位 2 设立的 app build required check | SUCCESS | ☐ |

## 运行时 runbook 条目（user device/sim 执行；outline §三.3 顺位 3 义务）

| # | Action（iPad mini 7 或 Catalyst） | Expected | Pass/Fail |
|---|---|---|---|
| R1 | 训练中（autoTracking）两指张开 | K 线变宽（根数变少），最新 K 线始终钉在最右；时间流不中断 | ☐ |
| R2 | 单指左滑进入浏览（freeScrolling）后，把手指中点对准某根特征 K 线两指张开/捏拢 | 该 K 线在屏幕上基本不动（焦点锚定）；无跳变 | ☐ |
| R3 | 连续张开到极限 | 缩到 20 根后不再变宽，无崩溃/抖动 | ☐ |
| R4 | 连续捏拢到极限 | 缩到 240 根后不再变密 | ☐ |
| R5 | 两指竖直滑动（不捏合） | 切换周期组合触发，**不**发生缩放（C7 仲裁不串扰） | ☐ |
| R6 | 上面板缩放后看下面板 | 下面板根数不变（per-panel 隔离） | ☐ |
| R7 | 浏览历史滚到最左边缘后在边缘附近捏合 | 视图贴边不裂口（边缘饱和优先于焦点锚定，预期行为） | ☐ |

## Residuals

- **W3-11-R1**（bounce live 接线）：维持 OPEN，**顺位 3 后 fast-follow 独立 PR**（设计 D8；本 PR 未碰边缘饱和规则）。
- **outline 残差 `:194` partial-closure**：visibleCount=80 硬编码部分**闭合**；candleWidthRatio=0.7 部分以「已是命名常量、无任何 spec/输入驱动其可变」close（设计 R1-M2，非静默收窄）。
- **顺位 4 forward-note**（设计 R1-M3）：接线 `drawingCommitted/drawingCancelled` 时必须同步 `resetOffsetAfterAutoTracking`，否则 autoTracking+offset≠0 破坏右锚前提（reducer zoomApplied 显式置 0 仅第二道防御）。
- **clamp/灵敏度常量**（20/240/恒等映射）：runbook 实测手感不适 → `PinchZoomModel` 一行改（设计 D4）。
```

（acceptance 内测试计数若与实测不符，以实测为准更新文档——禁止反向改测试凑数。）

- [ ] **Step 7.2: 终验（verification-before-completion 输入）**

Run（worktree 根）:
```bash
cd ios/Contracts && swift test 2>&1 | tail -2 && swift build 2>&1 | tail -1
cd .. && bash scripts/governance/verify-wave3-pr1-rfc.sh; echo "exit=$?"
git diff origin/main...HEAD --stat | tail -3
```
Expected: 全量绿 / Build complete / gate 仅 (f) FAIL / diff 范围与 acceptance #2 一致。

- [ ] **Step 7.3: Commit**

```bash
git add docs/acceptance/2026-06-13-wave3-pr3-pinch-zoom.md
git commit -m "docs(pinch): acceptance checklist + 运行时 runbook 条目 + residuals（W3-11-R1 fast-follow / ratio partial-closure / 顺位 4 forward-note）"
```

---

## Self-Review（plan 作者已执行）

**1. Spec coverage（设计 D1-D10 逐项）：** D1 reducer zoomApplied（Task 3）✅；D2 裁决 A 右锚 + forward-note（Task 3 显式置 0 测试 + Task 7 residual）✅；D3 focus 数学 + currentCandleIndex 共享谓词 + mutation-verify（Task 1）✅；D4 clamp/归一常量（Task 1）✅；D5 去硬编码 + parity 金值 + fallback（Task 2）+ engine seed（Task 4）✅；D6 applyPinch 编排全分支（Task 4）+ 接线（Task 5）✅；D7 ephemeral diff-gate（Task 7 acceptance #2/#3）✅；D8 W3-11-R1 fast-follow（Task 7 residual）✅；D9 四 doc amendment 全清单（Task 6：RFC a/b/c + outline callout + modules 1738/1743 + plan L1037/L1180）+ gate 内容谓词复跑（6.6）✅；D10 零回归（各 Task 全量回归步骤）✅。运行时 runbook（outline §三.3）= Task 7 R1-R7 ✅。

**2. Placeholder scan：** 无 TBD/TODO；每个代码步骤含完整代码；每个命令步骤含预期输出。✅

**3. Type consistency：** `PinchZoomModel.targetVisibleCount(base:effectiveScale:)`/`rezoomOffset(viewport:currentIdx:focusX:newCount:mainWidth:)`（Task 1 定义 = Task 4 调用）；`RenderStateBuilder.currentCandleIndex(candles:tick:)`（Task 1 = Task 4）；`ChartAction.zoomApplied(visibleCount:offset:)`（Task 3 = Task 4）；`applyPinch(scale:focusX:phase:panel:)`（Task 4 = Task 5）。✅

**已知偏差声明：** 测试计数（876/882/885/896）按各 Task 新增数推算（Task 1=12 / Task 2=6 / Task 3=3 / Task 4=11，Plan-R1 计数校正 + Plan-R2 PR2-01 endToEnd 移 Task 2），实测若有出入以实测为准（acceptance 同步），不得反向改测试凑数。
