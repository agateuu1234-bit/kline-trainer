# Wave 3 顺位 5：十字光标吸附 + HUD 实施 plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 长按十字光标的竖线吸附到最近蜡烛中心、时间 HUD label 随吸附蜡烛、价格 HUD label 跟随自由 Y，且全部基于 post-pinch 视口几何（消费顺位 3 engine-owned zoom）。

**Architecture:** 纯渲染层改动。在平台无关的 `CrosshairLayout` 引入单一入口 `resolve(...)`（整合原 `lines`/`priceLabel`/`timeLabel`）+ `snappedCandleIndex(...)` 吸附核心（nearest-center round + 两侧校正 + tie 取较小 + clamp 到切片自身界限 + 空切片守卫），UIKit 薄层 `drawCrosshair` 改调一次 `resolve` 后描边。0 engine / 0 Coordinator / 0 arbiter 改动；十字光标仍是视图层瞬态（`renderState.crosshairPoint` 存原始 point，吸附在 draw-time）。

**Tech Stack:** Swift / Swift Testing（`@Test`/`@Suite`/`#expect`）/ CoreGraphics / UIKit（薄层，Catalyst build-for-testing 闸门）。

**Spec:** `docs/superpowers/specs/2026-06-13-wave3-pr5-crosshair-snap-hud-design.md`（opus 4.8 xhigh 对抗 review R1-R4 收敛 APPROVE）。

---

## 文件结构

| 文件 | 责任 | 改动 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift` | 平台无关吸附几何 + label 文本/锚位的**唯一真相** | 加 `snappedCandleIndex` + `CrosshairResolved` + `resolve`；删 `lines`/`priceLabel`/`timeLabel`（被 `resolve` 取代）；更新文件头注（吸附已实现） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift` | UIKit 描边/填充/绘字薄层 | `drawCrosshair` 改调 `resolve` 一次；`drawLabelBox` 不变；更新注释引用 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift` | host 全断言吸附/clamp/守卫/post-pinch | 整体重写为新矩阵（11 行）+ 测试 helper |
| `docs/acceptance/2026-06-13-wave3-pr5-crosshair-snap-hud.md` | 非-coder 验收 + 运行时 runbook（顺位 13 阻塞依赖） | 新建 |

**关键既有事实（已 grep 核实，base = origin/main `b4f0e2a`）**：
- `CoordinateMapper.indexToX(i) = ((i − startIndex)·candleStep + pixelShift)` 后 `(raw·displayScale).rounded()/displayScale`，**`indexToX(i)` 是蜡烛水平中心**（`Geometry.swift:138-141`；`MainChartLayout` D5）。`pixelShift` 符号：>0 = candles 右移（`Geometry.swift:136`）。
- `RenderStateBuilder`：`viewport.visibleCount = slice.count = min(target, count)`（`:65`/`:89`），切片 = `candles[viewport.startIndex ..< …]`（`:26`），`make()` 守 `!candles.isEmpty`（`:23`）。post-pinch `candleStep = mainFrame.width / target`（`:68`）。
- `drawCrosshair` 派发：`KLineView.swift:59` 传 `renderState.crosshairPoint` + `renderState.viewport`；薄层内 `candles = self.renderState.visibleCandles`、`mapper = CoordinateMapper(viewport:, displayScale: traitCollection.displayScale)`。
- `CrosshairLayout.*` 调用方仅 `drawCrosshair` + 本测试文件（grep 证），整合安全。
- `CrosshairLayout` 是 `enum`（internal），全成员 internal；测试 `@testable import KlineTrainerContracts`。

---

## Task 1：吸附核心 `snappedCandleIndex`（纯函数，host 全测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift`

吸附核心 = spec D2 + D3。本任务先把测试 helper 与 5 个吸附/clamp/bounds 测试写好（先红），再实现 `snappedCandleIndex`。

- [ ] **Step 1：重写测试文件头 + helper（替换旧 helper，保留 `mc`）**

把 `CrosshairLayoutTests.swift` 顶部（import + `mc` + 旧 `makeMapper`）替换为以下（旧三函数测试在 Task 1/2 中逐步替换，本步先放新 helper，旧 `@Suite` 暂保留以保编译——下一步起逐个删旧加新）：

```swift
// Kline Trainer Swift Contracts — C5/顺位5 CrosshairLayout host tests
// Spec: docs/superpowers/specs/2026-06-13-wave3-pr5-crosshair-snap-hud-design.md
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

private func mc(_ idx: Int, datetime: Int64, close: Double = 10) -> KLineCandle {
    KLineCandle(period: .m3, datetime: datetime,
                open: close, high: close + 1, low: close - 1, close: close,
                volume: 100, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: idx, endGlobalIndex: idx)
}

/// 连续蜡烛数组（globalIndex = 0..<count）。slice 用 `candles[startIndex..<end]` 取，保 ArraySlice.startIndex == viewport.startIndex。
private func makeCandles(count: Int,
                        startDatetime: Int64 = 1735689600,   // 2025-01-01 00:00 UTC = 08:00 北京
                        stepSeconds: Int64 = 180) -> [KLineCandle] {
    (0..<count).map { i in mc(i, datetime: startDatetime + Int64(i) * stepSeconds) }
}

/// 灵活 mapper 构造（显式 startIndex/visibleCount/candleStep/pixelShift/displayScale）。
/// candleWidth/gap 沿用 0.7/0.3 比例（与 RenderStateBuilder 一致），但吸附只用 candleStep/pixelShift。
private func makeMapper(startIndex: Int = 0, visibleCount: Int = 10,
                       candleStep: CGFloat = 10, pixelShift: CGFloat = 0,
                       displayScale: CGFloat = 2,
                       frameWidth: CGFloat = 1000, frameHeight: CGFloat = 600) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: candleStep,
                             candleWidth: candleStep * 0.7, gap: candleStep * 0.3)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: visibleCount,
                           pixelShift: pixelShift, geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    return CoordinateMapper(viewport: vp, displayScale: displayScale)
}
```

然后**删除**旧的三个 `@Suite`（`CrosshairLinesTests` / `CrosshairLabelTests` / `CrosshairSentinelTests`）整块——它们调用即将移除的 `lines`/`priceLabel`/`timeLabel`，由 Task 1/2 新测试取代。

- [ ] **Step 2：写吸附核心失败测试（矩阵 1 / 1b / 3 / 4 / 11）**

追加到测试文件：

```swift
@Suite("CrosshairLayout.snappedCandleIndex 吸附核心")
struct SnappedIndexTests {

    // 矩阵 1：nearest-center round 跳变（candleStep=10, scale=2 → 中心 = i*10）
    @Test("过中点前吸附较小 candle、过后吸附较大 candle")
    func roundJump() {
        let m = makeMapper(visibleCount: 10)              // 中心 0,10,...,90
        let c = makeCandles(count: 10)[0..<10]
        #expect(CrosshairLayout.snappedCandleIndex(at: 14, mapper: m, candles: c) == 1)  // 14<15 → idx1
        #expect(CrosshairLayout.snappedCandleIndex(at: 16, mapper: m, candles: c) == 2)  // 16>15 → idx2
    }

    // 矩阵 1b：恰中点精确 IEEE tie（logical>0）→ 取较小 index；seed 会取较大（2），tie-break 必须覆盖为 1
    @Test("恰落两中心中点（15.0，|10−15|==|20−15|）→ tie-break 取较小 index（非 seed 的较大）")
    func exactMidpointTieTakesSmaller() {
        let m = makeMapper(visibleCount: 10)              // indexToX(1)=10.0, indexToX(2)=20.0
        let c = makeCandles(count: 10)[0..<10]
        // seed = round((15−0)/10)=round(1.5)= 2（away-from-zero，较大）；两侧 {1,2} 距离均 5.0 → tie 取 1
        #expect(CrosshairLayout.snappedCandleIndex(at: 15.0, mapper: m, candles: c) == 1)
    }

    // 矩阵 3：count < target → clamp 到最末可见（viewport.visibleCount = slice.count = 5）
    @Test("右侧 padding 空白区长按 → 吸附最末可见蜡烛（clamp 右）")
    func clampRight() {
        let m = makeMapper(visibleCount: 5)               // 仅中心 0,10,20,30,40；右侧空白
        let c = makeCandles(count: 5)[0..<5]
        #expect(CrosshairLayout.snappedCandleIndex(at: 500, mapper: m, candles: c) == 4)  // clamp → 末根
    }

    // 矩阵 4：logical<0（point.x 在首中心左侧，pixelShift=30）→ clamp 到 startIndex
    @Test("首蜡烛中心左侧长按 → clamp 到第一可见蜡烛（clamp 左）")
    func clampLeft() {
        let m = makeMapper(visibleCount: 10, pixelShift: 30)  // indexToX(0)=30
        let c = makeCandles(count: 10)[0..<10]
        #expect(CrosshairLayout.snappedCandleIndex(at: 5, mapper: m, candles: c) == 0)
    }

    // 矩阵 11：结构 bounds 不变量（含 startIndex 偏移的绝对索引）
    @Test("任意 in-frame point → candles.startIndex <= snappedIndex < candles.endIndex")
    func boundsInvariant() {
        // 偏移切片：startIndex=5，候选索引 [5,15)
        let m = makeMapper(startIndex: 5, visibleCount: 10)   // indexToX(i)=(i−5)*10
        let c = makeCandles(count: 15)[5..<15]
        for x: CGFloat in [0, 5, 95, 300, 750, 999] {
            let idx = CrosshairLayout.snappedCandleIndex(at: x, mapper: m, candles: c)
            #expect(idx >= c.startIndex && idx < c.endIndex)
        }
    }
}
```

- [ ] **Step 3：运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter "SnappedIndexTests"`
Expected: 编译失败 / FAIL（`snappedCandleIndex` 未定义）。

- [ ] **Step 4：实现 `snappedCandleIndex`（spec D2 + D3）**

在 `CrosshairLayout.swift` 的 `enum CrosshairLayout {` 内（`lines`/`priceLabel`/`timeLabel` 之前；这些将在 Task 2 移除）追加：

```swift
    /// 吸附核心（spec D2/D3）：返回离 `x` 最近蜡烛中心的索引，clamp 到 `candles` 切片自身界限。
    /// 算法：seed = round((x − pixelShift)/candleStep) + startIndex；两侧 {seed−1,seed,seed+1}
    /// 取 |indexToX − x| 最小（严格 <，tie 保留较小 index）；再 clamp [candles.startIndex, candles.endIndex−1]。
    /// 调用方须先保证 !candles.isEmpty（resolve 已守）；indexToX 对任意 Int 线性有定义，越界邻居照常参与比较。
    static func snappedCandleIndex(at x: CGFloat, mapper: CoordinateMapper,
                                   candles: ArraySlice<KLineCandle>) -> Int {
        let vp = mapper.viewport
        let seed = vp.startIndex
            + Int(((x - vp.pixelShift) / vp.geometry.candleStep).rounded(.toNearestOrAwayFromZero))
        // 两侧校正：从较小者起遍历，严格 < ⇒ 距离相等时保留较小 index（确定性 tie-break）。
        var best = seed - 1
        var bestDist = abs(mapper.indexToX(seed - 1) - x)
        for cand in [seed, seed + 1] {
            let d = abs(mapper.indexToX(cand) - x)
            if d < bestDist { best = cand; bestDist = d }
        }
        // clamp 到切片自身有效索引（slice-safe total；生产下 == viewport 窗口）。
        return min(max(best, candles.startIndex), candles.endIndex - 1)
    }
```

- [ ] **Step 5：运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter "SnappedIndexTests"`
Expected: PASS（5 测试全绿）。

- [ ] **Step 6：提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift
git commit -m "顺位5 Task1：CrosshairLayout.snappedCandleIndex 吸附核心（nearest-center round + 两侧校正 + tie 取小 + slice-safe clamp）"
```

---

## Task 2：聚合入口 `resolve` + `CrosshairResolved`（lines/labels/守卫）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift`

聚合 spec D4/D5/D6：竖线吸附 X + 横线自由 Y + 价签自由 Y + 时签吸附 X，单一 `snappedIndex` 真相；`point==nil` / frame 外 / 空切片 → nil。

- [ ] **Step 1：写 `resolve` 失败测试（矩阵 2 / 5 / 6 / 7 / 8 / 9 / 10）**

追加到测试文件：

```swift
@Suite("CrosshairLayout.resolve 聚合 + HUD")
struct ResolveTests {

    // 矩阵 2：snappedX == indexToX(snappedIndex)，竖线两端点同 x（mirror-the-mapper）
    @Test("竖线 x = indexToX(snappedIndex)（两端点一致，经 mapper 推导）")
    func verticalSnapsToCenter() {
        let m = makeMapper(visibleCount: 10)
        let c = makeCandles(count: 10)[0..<10]
        let r = CrosshairLayout.resolve(at: CGPoint(x: 23, y: 300), mapper: m, candles: c)
        #expect(r != nil)
        guard let r else { return }
        let snappedX = m.indexToX(r.snappedIndex)
        #expect(r.lines.vertical.from.x == snappedX)
        #expect(r.lines.vertical.to.x == snappedX)
        #expect(r.snappedIndex == 2)                       // 23 → 中心 20（idx2）
        // 横线自由 Y：跨 frame 全宽、y == point.y
        #expect(r.lines.horizontal.from == CGPoint(x: 0, y: 300))
        #expect(r.lines.horizontal.to == CGPoint(x: 1000, y: 300))
    }

    // 矩阵 5：价格 label 自由 Y（吸附不影响）+ 镜像 yToPrice
    @Test("价格 label 文本恒 = yToPrice(point.y)，与 point.x（吸附）无关 + 镜像 mapper")
    func priceLabelFreeY() {
        let m = makeMapper(visibleCount: 10)
        let c = makeCandles(count: 10)[0..<10]
        for x: CGFloat in [3, 23, 47, 500] {               // 变 x（吸附不同蜡烛）
            let r = CrosshairLayout.resolve(at: CGPoint(x: x, y: 300), mapper: m, candles: c)
            #expect(r?.priceLabel.text == String(format: "%.2f", m.yToPrice(300)))  // y=300 → 50.00
        }
        for y: CGFloat in [50, 150, 450, 550] {            // 镜像 yToPrice
            let r = CrosshairLayout.resolve(at: CGPoint(x: 100, y: y), mapper: m, candles: c)
            #expect(r?.priceLabel.text == String(format: "%.2f", m.yToPrice(y)))
        }
        // 价签右贴 frame.maxX、垂直居中 point.y
        let r = CrosshairLayout.resolve(at: CGPoint(x: 100, y: 300), mapper: m, candles: c)
        #expect(r?.priceLabel.rect.maxX == 1000)
        #expect(r?.priceLabel.rect.midY == 300)
    }

    // 矩阵 6：时间 label 吸附 X + 吸附蜡烛 datetime（mirror-the-mapper）
    @Test("时间 label midX = indexToX(snappedIndex)（非原始 x）+ 文本 = 吸附蜡烛 datetime")
    func timeLabelSnapsX() {
        let m = makeMapper(visibleCount: 3)
        let candles = [mc(0, datetime: 1735781400),        // 2025-01-02 09:30 北京
                       mc(1, datetime: 1735781580),        // 09:33
                       mc(2, datetime: 1735781760)]        // 09:36
        let c = candles[0..<3]
        // point.x=16 → 吸附 idx2（中心 20，16>15）；时签 midX == indexToX(2)=20
        let r = CrosshairLayout.resolve(at: CGPoint(x: 16, y: 300), mapper: m, candles: c)
        #expect(r != nil)
        #expect(r?.snappedIndex == 2)
        #expect(r?.timeLabel.rect.midX == m.indexToX(2))
        #expect(r?.timeLabel.text == "2025-01-02 09:36")
        #expect(r?.timeLabel.rect.maxY == 600)
    }

    // 矩阵 7：frame 外 → nil（4 角半开区间）+ point==nil → nil
    @Test("frame 外 point → nil（半开 [minX,maxX)×[minY,maxY)）；nil point → nil")
    func outsideFrameNil() {
        let m = makeMapper(visibleCount: 10)
        let c = makeCandles(count: 10)[0..<10]
        #expect(CrosshairLayout.resolve(at: nil, mapper: m, candles: c) == nil)
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 0, y: 0), mapper: m, candles: c) != nil)      // 左上 ∈
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 1000, y: 0), mapper: m, candles: c) == nil)   // 右上 ∉
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 0, y: 600), mapper: m, candles: c) == nil)    // 左下 ∉
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 1000, y: 600), mapper: m, candles: c) == nil) // 右下 ∉
    }

    // 矩阵 8：post-pinch demonstrator（同 x，不同 candleStep → 不同蜡烛中心）。displayScale=3 真像素取整。
    @Test("post-pinch：同 point.x 在 zoom 前后吸附到不同蜡烛中心（消费 candleStep 变化）")
    func postPinchSnap() {
        let c = makeCandles(count: 80)
        // 默认 viewport：visibleCount=80, candleStep=1000/80=12.5
        let mDefault = makeMapper(visibleCount: 80, candleStep: 1000.0 / 80.0,
                                  displayScale: 3, frameWidth: 1000)
        // pinch 后 viewport：visibleCount=40, candleStep=1000/40=25
        let mPinch = makeMapper(visibleCount: 40, candleStep: 1000.0 / 40.0,
                                displayScale: 3, frameWidth: 1000)
        let idxDefault = CrosshairLayout.snappedCandleIndex(at: 300, mapper: mDefault, candles: c[0..<80])
        let idxPinch = CrosshairLayout.snappedCandleIndex(at: 300, mapper: mPinch, candles: c[0..<40])
        #expect(idxDefault == 24)                          // round(300/12.5)=24
        #expect(idxPinch == 12)                            // round(300/25)=12
        #expect(idxDefault != idxPinch)                    // mutation：固定 80 分母则二者相等 → 失败
        // resolve 的竖线 x 用各自 mapper 的 indexToX（mirror）
        let r = CrosshairLayout.resolve(at: CGPoint(x: 300, y: 300), mapper: mPinch, candles: c[0..<40])
        #expect(r?.lines.vertical.from.x == mPinch.indexToX(12))
    }

    // 矩阵 9：locale 中性时间格式
    @Test("时间格式跨设备 locale 稳定（en_US_POSIX + UTC+8）")
    func localeNeutral() {
        let m = makeMapper(visibleCount: 1)
        let c = [mc(0, datetime: 1735689600)][0..<1]       // 2025-01-01 00:00 UTC = 08:00 北京
        let r = CrosshairLayout.resolve(at: CGPoint(x: 0, y: 300), mapper: m, candles: c)
        #expect(r?.timeLabel.text == "2025-01-01 08:00")
    }

    // 矩阵 10：空切片守卫（visibleCount==0 + 非 .zero frame + in-frame point）→ nil（不崩）
    @Test("空切片 → resolve nil（先于 clamp，不触发窗口反转崩溃）")
    func emptyCandlesNil() {
        let m = makeMapper(visibleCount: 0)                // 非 .zero frame
        let empty = makeCandles(count: 0)[0..<0]
        #expect(CrosshairLayout.resolve(at: CGPoint(x: 100, y: 300), mapper: m, candles: empty) == nil)
    }
}
```

- [ ] **Step 2：运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter "ResolveTests"`
Expected: 编译失败（`resolve` / `CrosshairResolved` 未定义）。

- [ ] **Step 3：实现 `CrosshairResolved` + `resolve`，移除旧三函数**

在 `CrosshairLayout.swift`：保留 `CrosshairLines` 结构；在其后加 `CrosshairResolved`；在 `enum CrosshairLayout` 内**删除** `lines`/`priceLabel`/`timeLabel` 三函数，加 `resolve`（`snappedCandleIndex` 保留）。最终 `enum` 体为 `snappedCandleIndex` + `resolve`。

加在 `CrosshairLines` 结构之后：

```swift
/// resolve 聚合结果：竖线吸附 + 横线/价签自由 Y + 时签吸附 X，单一 snappedIndex 真相。
struct CrosshairResolved: Equatable, Sendable {
    let lines: CrosshairLines
    let priceLabel: Label
    let timeLabel: Label
    let snappedIndex: Int

    struct Label: Equatable, Sendable {
        let rect: CGRect
        let text: String
    }
}
```

`enum CrosshairLayout` 内（保留 `snappedCandleIndex`，删旧三函数）加：

```swift
    /// 单一入口（spec D6）：long-press 原始 point + 当前 mapper（post-pinch viewport）+ 可见 candles
    /// → 吸附后的十字光标几何 + HUD labels。point==nil / frame 外 / 空切片 → nil（spec D3 守卫）。
    /// 竖线吸附 X（snappedX）、横线自由 Y；价签自由 Y、时签吸附 X；竖线与时签共用同一 snappedIndex。
    static func resolve(at point: CGPoint?, mapper: CoordinateMapper,
                        candles: ArraySlice<KLineCandle>) -> CrosshairResolved? {
        guard let point else { return nil }
        let frame = mapper.viewport.mainChartFrame
        guard frame.contains(point) else { return nil }     // D8 frame 守卫
        guard !candles.isEmpty else { return nil }          // D3 空切片守卫（先于 clamp）

        let snappedIndex = snappedCandleIndex(at: point.x, mapper: mapper, candles: candles)
        let snappedX = mapper.indexToX(snappedIndex)

        // 竖线吸附 snappedX；横线自由 point.y（D1 X-only snap）。
        let lines = CrosshairLines(
            horizontal: .init(from: CGPoint(x: frame.minX, y: point.y),
                              to:   CGPoint(x: frame.maxX, y: point.y)),
            vertical:   .init(from: CGPoint(x: snappedX, y: frame.minY),
                              to:   CGPoint(x: snappedX, y: frame.maxY)))

        // 价签：自由 Y（镜像 yToPrice，D4）；右贴 maxX、垂直居中 point.y。
        let price = mapper.yToPrice(point.y)
        let priceWidth: CGFloat = 60, priceHeight: CGFloat = 18
        let priceRect = CGRect(x: frame.maxX - priceWidth, y: point.y - priceHeight / 2,
                               width: priceWidth, height: priceHeight)
        let priceLabel = CrosshairResolved.Label(rect: priceRect,
                                                 text: String(format: "%.2f", price))

        // 时签：吸附蜡烛 datetime（UTC+8 / en_US_POSIX，D4）；水平居中 snappedX、底贴 maxY。
        let datetime = candles[snappedIndex].datetime
        let date = Date(timeIntervalSince1970: TimeInterval(datetime))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timeWidth: CGFloat = 120, timeHeight: CGFloat = 18
        let timeRect = CGRect(x: snappedX - timeWidth / 2, y: frame.maxY - timeHeight,
                              width: timeWidth, height: timeHeight)
        let timeLabel = CrosshairResolved.Label(rect: timeRect, text: formatter.string(from: date))

        return CrosshairResolved(lines: lines, priceLabel: priceLabel,
                                 timeLabel: timeLabel, snappedIndex: snappedIndex)
    }
```

同时更新文件头注：把 D7「lines 不吸附蜡烛中心……吸附决策在 Wave 2 LongPress 源」「D8 point 落 mainChartFrame 外即返回 nil」两行，改为反映顺位 5 现状：

```swift
// 顺位5：竖线吸附最近蜡烛中心（snappedCandleIndex），横线/价签自由 Y，时签随吸附蜡烛（spec D1/D2/D4）。
// 吸附在本纯层 draw-time，用 resolve 入参的 post-pinch viewport mapper（spec D5）。
// resolve 守卫：point==nil / point 落 mainChartFrame 外（半开区间）/ candles.isEmpty → nil（spec D3）。
```

- [ ] **Step 4：运行测试确认通过（含 Task 1 测试）**

Run: `cd ios/Contracts && swift test --filter "SnappedIndexTests|ResolveTests"`
Expected: PASS（`SnappedIndexTests` 5 + `ResolveTests` 7 全绿）。

⚠️ 若 `postPinchSnap` 因 displayScale=3 像素取整使 `idxDefault`/`idxPinch` 偏离断言值，**不要改容差吞断言**——重核 `snappedCandleIndex` 是否正确读 `vp.geometry.candleStep`（index 是 Int 精确值，scale 不应改 index；只影响 `indexToX` 的 x 像素值）。

- [ ] **Step 5：提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/CrosshairLayout.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/CrosshairLayoutTests.swift
git commit -m "顺位5 Task2：CrosshairLayout.resolve 聚合（竖线吸附+横线/价签自由Y+时签吸附X+空切片守卫）+ 删旧三函数"
```

---

## Task 3：`drawCrosshair` 接 `resolve`（UIKit 薄层）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift`

UIKit 薄层无 host 单测（运行时行为见 runbook）；正确性由编译 + Catalyst build-for-testing 闸门保证。`drawLabelBox` 不变。

- [ ] **Step 1：改写 `drawCrosshair` 调 `resolve`**

把 `drawCrosshair(ctx:at:viewport:)` 函数体替换为：

```swift
    /// 顺位5 十字光标：point != nil 且在 mainChartFrame 内时画横+竖线（竖线吸附最近蜡烛中心）
    /// + 右侧价签（自由 Y）+ 底部时签（吸附蜡烛）。守卫由 CrosshairLayout.resolve 统一处理。
    func drawCrosshair(ctx: CGContext, at point: CGPoint?, viewport: ChartViewport) {
        let mapper = CoordinateMapper(viewport: viewport,
                                      displayScale: self.traitCollection.displayScale)
        let candles = self.renderState.visibleCandles
        guard let resolved = CrosshairLayout.resolve(at: point, mapper: mapper, candles: candles) else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // D3：crosshair 线 = AppColor.text（白 0.92），1 device pixel 宽。
        AppColor.text.setStroke()
        ctx.setLineWidth(1 / mapper.displayScale)
        let lines = resolved.lines
        ctx.move(to: lines.horizontal.from); ctx.addLine(to: lines.horizontal.to); ctx.strokePath()
        ctx.move(to: lines.vertical.from);   ctx.addLine(to: lines.vertical.to);   ctx.strokePath()

        // HUD：价签（自由 Y）+ 时签（吸附 X，resolve 保证 in-frame 恒在）。
        drawLabelBox(ctx: ctx, rect: resolved.priceLabel.rect, text: resolved.priceLabel.text)
        drawLabelBox(ctx: ctx, rect: resolved.timeLabel.rect, text: resolved.timeLabel.text)
    }
```

同时更新文件头第 4 行注释 `// point == nil 直接返回（无光标）。frame 外 point 由 CrosshairLayout.lines 返回 nil 跳过。` 为：
`// 守卫（point==nil / frame 外 / 空切片）统一由 CrosshairLayout.resolve 返回 nil 处理。竖线吸附最近蜡烛中心。`

- [ ] **Step 2：host 编译 + 全量回归（确认无引用残留）**

Run: `cd ios/Contracts && swift build && swift test --filter "SnappedIndexTests|ResolveTests"`
Expected: build 成功（无 `CrosshairLayout.lines/priceLabel/timeLabel` 残引用）；CrosshairLayout 测试全绿。

- [ ] **Step 3：Catalyst build-for-testing（UIKit 薄层闸门，本地 de-risk）**

Run:
```bash
xcodebuild build-for-testing -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **`（若本地无 Catalyst 环境，则依赖 CI required check `Mac Catalyst build-for-testing on macos-15`；不可仅凭 host 绿 claim 通过——见 memory `feedback_swift_local_toolchain_blindspot`）。

- [ ] **Step 4：提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift
git commit -m "顺位5 Task3：drawCrosshair 接 CrosshairLayout.resolve（竖线吸附+HUD 守卫统一）"
```

---

## Task 4：验收文档 + 运行时 runbook

**Files:**
- Create: `docs/acceptance/2026-06-13-wave3-pr5-crosshair-snap-hud.md`

- [ ] **Step 1：写验收 + runbook 文档**

内容（非-coder 可执行；action/expected/pass-fail；runbook 运行时条目为顺位 13 阻塞依赖）：

```markdown
# Wave 3 顺位 5：十字光标吸附 + HUD 验收清单（中文非-coder 可执行）

**PR 范围**：纯渲染层。`CrosshairLayout.swift`（吸附核心 + resolve）+ `KLineView+Crosshair.swift`（薄层接线）+ `CrosshairLayoutTests.swift`（吸附/clamp/守卫/post-pinch 矩阵）+ 本验收文档。**0 engine / 0 Coordinator / 0 arbiter / 0 spec 改动**。

**spec**：`docs/superpowers/specs/2026-06-13-wave3-pr5-crosshair-snap-hud-design.md`（opus 4.8 xhigh 对抗 review R1-R4 收敛 APPROVE）。

## 静态 / host 验收

| Step | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR | 见 4 文件改动，无 engine/Coordinator/arbiter 文件 | □ Pass / □ Fail |
| 2 | `cd ios/Contracts && swift test --filter "SnappedIndexTests\|ResolveTests"` | `SnappedIndexTests`(5) + `ResolveTests`(7) 全 PASS | □ Pass / □ Fail |
| 3 | 查 `CrosshairLayout.swift` | 含 `snappedCandleIndex` + `resolve` + `CrosshairResolved`；**无** `lines`/`priceLabel`/`timeLabel` 旧函数 | □ Pass / □ Fail |
| 4 | `grep -n "CrosshairLayout\.\(lines\|priceLabel\|timeLabel\)" -r ios/Contracts` | 无匹配（旧 API 引用已清） | □ Pass / □ Fail |
| 5 | CI | `Mac Catalyst build-for-testing on macos-15` required check SUCCESS | □ Pass / □ Fail |

## 运行时 runbook（设备/模拟器手测，顺位 13 阻塞依赖，user device 职责）

| Step | Action | Expected | Pass/Fail |
|---|---|---|---|
| R1 | 训练页长按主图任意位置 | 出现十字光标；**竖线落在最近蜡烛中心**（非手指原始 x）；底部时间 label 显示该蜡烛日期时间 | □ Pass / □ Fail |
| R2 | 长按后水平拖动手指 | 竖线在相邻蜡烛间**跳变吸附**（过中点跳邻居）；价格 label 随手指 Y **连续自由移动**（不锁蜡烛价） | □ Pass / □ Fail |
| R3 | 先 pinch 缩放（顺位 3）改变蜡烛密度，再长按 | 吸附仍落正确蜡烛中心（基于 post-pinch 几何，竖线对准缩放后的蜡烛） | □ Pass / □ Fail |
| R4 | 长按拖到主图区外 / 松手 | 区外无光标；松手光标消失 | □ Pass / □ Fail |
```

- [ ] **Step 2：提交**

```bash
git add docs/acceptance/2026-06-13-wave3-pr5-crosshair-snap-hud.md
git commit -m "顺位5 Task4：验收清单 + 运行时 runbook（顺位13 阻塞依赖）"
```

---

## 完成判据（verification before completion 用）

1. `cd ios/Contracts && swift test` 全量绿（908 baseline + 新增吸附/resolve 测试；无回归）。
2. `grep -rn "CrosshairLayout\.\(lines\|priceLabel\|timeLabel\)" ios/Contracts` 无匹配（旧 API 清干净）。
3. `git diff --stat origin/main` 仅含 4 文件（2 prod + 1 test + 1 doc），0 engine/Coordinator/arbiter/spec。
4. Catalyst build-for-testing 成功（本地或 CI required check）。
5. 测试 8（post-pinch）非 vacuous：`idxDefault(24) != idxPinch(12)`，证 candleStep 变化被吸附消费。
```
