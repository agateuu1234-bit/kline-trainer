# C3 主图渲染（Candles + MA66 + BOLL）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PR #51 留下的 C3 三个空 stub（`drawCandles` / `drawMA66` / `drawBOLL`）替换为真实现：主图蜡烛实体+影线、MA66 折线、BOLL 上中下三轨虚线。

**Architecture:** 几何/布局逻辑（蜡烛实体矩形、影线端点、指标折线分段）抽到**平台无关**纯函数文件 `MainChartLayout.swift`（只依赖 CoreGraphics + 已冻结的 `CoordinateMapper`/`KLineCandle`），由 macOS host `swift test` 真断言；`KLineView+Candles.swift` 三个方法降为**薄 UIKit 层**——调用布局函数拿到几何原语，再用 `AppColor` token + CGContext 描边/填充，由 Mac Catalyst `build-for-testing` 编译闸门守护（UIKit 在 host 不可编译，故无运行期测试，仅编译验证）。这与 C1a `Geometry.swift`（平台无关、host 全测）+ §15.1 #3 Catalyst 编译闸门的既有两闸门架构一致。

**Tech Stack:** Swift 6.0 / Swift Testing（`import Testing` + `@Test` + `#expect`）/ CoreGraphics（host 可用）/ UIKit（仅 Catalyst）/ 已冻结模块：`CoordinateMapper`（C1a）、`KLineCandle`（F1/Models）、`AppColor`+`AppColorTokens`（F2 Theme）。

---

## 背景与既有接缝（实施者必读）

- 派发点已存在且不改动：`Render/KLineView.swift` 的 `draw(_:)` 已调用 `drawCandles/drawMA66/drawBOLL(ctx:mapper:candles:)`（L50-52）。本 PR 只填三个方法体 + 新增布局文件 + 测试。
- 当前 stub：`Render/KLineView+Candles.swift`（3 个空方法，`#if canImport(UIKit)` 守卫）。
- `CoordinateMapper`（`Geometry/Geometry.swift`，平台无关）API：
  - `func indexToX(_ index: Int) -> CGFloat`（已做亚像素 round-to-device-pixel；`(index - viewport.startIndex)*candleStep + pixelShift` 再 round）
  - `func priceToY(_ price: Double) -> CGFloat`（已 round-to-device-pixel）
  - `let displayScale: CGFloat`
  - `let viewport: ChartViewport`（含 `startIndex: Int`、`geometry.candleWidth: CGFloat`）
- `KLineCandle`（`Models/Models.swift`，平台无关）：`open/high/low/close: Double`，`ma66/bollUpper/bollMid/bollLower: Double?`（**后端 B1 在全序列上预计算**，warmup 段为 nil）。
- `AppColor`（`Theme/Theme.swift`，`#if canImport(UIKit)`）：`.candleUp`、`.candleDown`、`.ma66`、`.bollLine`（均为 `UIColor`）。
- 测试基线：当前 435 tests / 80 suites（PR #65）。本 PR +16 host 测试（蜡烛 5 + MA66 5 + BOLL 4 + 索引契约 2 → 实际 451 total）。

---

## Task 0 — §15.3 评审策略前置 + spec 偏差裁决

> 完成 Task 0 才进 Task 1。本节是**决策记录**，无代码；实施者据此实现，评审据此核对。

- [ ] **局部对抗性评审（必）**：本 plan C3 scope 内对抗性 review（用户本次指定 = Claude Opus 4.7 xhigh effort 双闸门：plan-stage 收敛 + impl-stage 收敛；codex 周配额若耗尽走 opus fallback，按 memory `feedback_openai_quota_ci_pattern`）。4-5 轮收敛或 escalate（`feedback_codex_plan_budget_overshoot`）。
- [ ] **集成层评审（N/A）**：C8 `ChartContainerView` 桥接 + `buildRenderState` 在 **Wave 2**，本 PR 不含集成层；不触发集成评审。
- [ ] **性能评审（N/A）**：plan v1.5 §一 "单帧 <4ms / Instruments" 属 **Phase 5 磨光 PR**；C3 是 Phase 1 纯 `draw(_:)` 渲染，本 PR 不做 Instruments 评审（per plan 模板 "Phase 5 磨光 PR 必"）。

### Spec 偏差裁决（D1-D9，全部写进代码注释 + 验收）

| # | 偏差/歧义 | 裁决 | 权威依据 |
|---|---|---|---|
| **D1** | stub 注释写 "drawMA66 滑窗 66 根计算均价" | **错，不采纳**。C3 **读** `candle.ma66` 预计算值，**不重算**。理由：MA66 由后端 B1 在**全序列**算（plan v1.5 L24）；可见 slice 前 65 根缺历史，重算会出错；且 `PriceRange.calculate` 已直接读 `c.ma66`。 | Models `KLineCandle.ma66` 字段 + `Geometry.swift` `PriceRange.calculate` L96 + plan v1.5 L24 |
| **D2** | stub 注释提 BOLL "上下轨填充" | **不实现填充**。BOLL = 上/中/下三条线，无填充。 | 权威 spec §C3（modules L1280-1284 仅三方法）+ plan v1.5 L794/L934 "上/中/下轨"（无填充字样）；Simplicity First |
| **D3** | BOLL 线型 | **虚线（dashed）**。dash 段长抽为 host 可测纯函数 `MainChartLayout.dashPattern(displayScale:)`；`drawBOLL` 用 `ctx.setLineDash` 喂入，并以 `saveGState`+`defer restoreGState` 隔离。MA66 + 蜡烛 = 实线。**验证边界（H1 如实）**：虚线段长正确性 = host 测；save/restore 配对正确性无运行期自动验证（UIKit 在 host 不可测、Catalyst 仅 build 不 run），靠 defer 惯用法 + 人工 review；验收脚本的 saveGState/restoreGState grep 仅为**结构存在性**检查，**不证明**配对正确。 | plan v1.5 **L6 v1.4 变更#2**："BOLL 曲线样式从灰色细线改为灰色虚线" + L794/L934 "灰色虚线"；H1 修订 |
| **D4** | 颜色：plan v1.5 说 "MA66 亮橙 / BOLL 灰" 但已冻结 F2 token 是 `ma66`=紫(0.55,0.40,0.85)、`bollLine`=橙(0.95,0.70,0.20) | C3 **引用 F2 token**（`AppColor.ma66`/`.bollLine`/`.candleUp`/`.candleDown`），不硬编码 RGB。颜色取值是 F2（Wave 0 已冻结）的职责；token 命名/取值与 plan v1.5 §一 文案的差异**记为 residual**（若用户要灰色 BOLL 须走独立 F2-revision RFC，不在 C3 scope）。 | DRY 单一色源 + F2 `project_pr39_f2_merged` 已冻结 + memory `feedback_outline_no_inline_implementation`（约束=契约不内联实现） |
| **D5** | `indexToX(index)` 语义 = 蜡烛中心还是左缘 | C3 视其为**蜡烛水平中心**：实体矩形以 cx 居中（`minX = cx - candleWidth/2`），影线在 cx。绝对位置（中心/左缘）由 mapper 决定，C3 不控制；只保证"影线居于实体中心"。 | 标准 K 线惯例；body+wick 共用 cx 内部自洽 |
| **D6** | 可见 slice 的 index 与 chart index 对齐 | C3 用 `candles.indices`（`ArraySlice` 保留母数组下标）作 chart index 传给 `mapper.indexToX`；调用方（C8，Wave 2）保证 `slice.startIndex == viewport.startIndex`。 | `ArraySlice` 语义 + C8 `buildRenderState` 用 `fullArray[range]` 构造 |
| **D7** | 涨跌判定（含平盘 doji） | `isUp = close >= open`（平盘归"涨"色）。中国红涨绿跌。 | plan v1.5 L934 "红涨绿跌"；F2 仅 candleUp/candleDown 两色 |
| **D8** | doji（open==close）实体高度为 0 不可见 | 实体最小高度 = `1 / displayScale`（1 个设备像素）。 | 渲染常识；priceToY 已 round-to-device-pixel |
| **D9** | MA66/BOLL warmup 段 nil + 防御性内部 gap | `polylineSegments` 遇 nil **断线分段**：leading nil 跳过；内部 nil（B1 契约下不应出现，防御）切成多段；<2 点的段不描边。 | B1 warmup 契约 + 防"跨 gap 直连"误导渲染 |

---

## File Structure

| 文件 | 动作 | 职责 | 平台 |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Render/MainChartLayout.swift` | **新建** | 纯布局函数：`candleShapes` / `ma66Polyline` / `bollPolylines` / 私有 `polylineSegments`；返回 `CGRect`/`CGPoint` 几何原语 | 平台无关（host 可测） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift` | **改**（填 stub） | 三个 `drawXxx` 调用布局函数 + `AppColor` token + CGContext 描边/填充 | `#if canImport(UIKit)`（仅 Catalyst） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/MainChartLayoutTests.swift` | **新建** | 布局函数 host 测试（蜡烛几何 / MA66 分段 / BOLL 三轨 / 边界） | 平台无关（host 跑） |
| `scripts/acceptance/plan_c3_candles_ma66_boll.sh` | **新建** | 机检验收脚本 | bash |
| `docs/acceptance/2026-05-25-pr-c3-candles-ma66-boll.md` | **新建** | 非程序员逐条验收清单 | md |

---

## Task 1: `MainChartLayout.candleShapes` —— 蜡烛实体+影线几何

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/MainChartLayout.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/MainChartLayoutTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `MainChartLayoutTests.swift`：

```swift
// Kline Trainer Swift Contracts — C3 MainChartLayout host tests
// Spec: kline_trainer_modules_v1.4.md §C3 + plan 2026-05-25-pr-c3-candles-ma66-boll.md
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

// MARK: - 测试构造器
private func mc(_ index: Int,
               open: Double = 10, high: Double = 11, low: Double = 9, close: Double = 10,
               ma66: Double? = nil,
               bollUpper: Double? = nil, bollMid: Double? = nil, bollLower: Double? = nil) -> KLineCandle {
    KLineCandle(period: .m3, datetime: Int64(index),
                open: open, high: high, low: low, close: close,
                volume: 0, amount: nil, ma66: ma66,
                bollUpper: bollUpper, bollMid: bollMid, bollLower: bollLower,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: index, endGlobalIndex: index)
}

/// 干净取整的 mapper：step=10, width=6, scale=2, price 0...100, frame 0,0,1000,600。
/// indexToX(startIndex + k) == k*10；priceToY(p) == 600 - p*6（p∈[0,100]）。
private func makeMapper(startIndex: Int = 0, count: Int) -> CoordinateMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return CoordinateMapper(viewport: vp, displayScale: 2)
}

@Suite("MainChartLayout.candleShapes")
struct MainChartLayoutCandleTests {

    @Test("涨蜡烛：isUp=true，实体顶=priceToY(close)，影线 cx 居中")
    func upCandle() {
        let candles = [mc(0, open: 10, high: 25, low: 5, close: 20)]
        let m = makeMapper(count: 1)
        let shapes = MainChartLayout.candleShapes(for: candles[0..<1], mapper: m)
        #expect(shapes.count == 1)
        let s = shapes[0]
        #expect(s.isUp == true)
        // cx = indexToX(0) = 0；width 6 → minX = -3
        #expect(s.bodyRect.minX == -3)
        #expect(s.bodyRect.width == 6)
        // close=20 → y=480（高价小 y）；open=10 → y=540
        #expect(s.bodyRect.minY == 480)
        #expect(s.bodyRect.height == 60)
        // 影线 high=25 → y=450；low=5 → y=570；x=cx=0
        #expect(s.wickTop == CGPoint(x: 0, y: 450))
        #expect(s.wickBottom == CGPoint(x: 0, y: 570))
    }

    @Test("跌蜡烛：isUp=false")
    func downCandle() {
        let candles = [mc(0, open: 20, high: 25, low: 5, close: 10)]
        let s = MainChartLayout.candleShapes(for: candles[0..<1], mapper: makeMapper(count: 1))[0]
        #expect(s.isUp == false)
        #expect(s.bodyRect.minY == 480)   // top = min(y_open=480, y_close=540)
        #expect(s.bodyRect.height == 60)
    }

    @Test("平盘 doji：实体高度=1/displayScale（最小 1 设备像素）")
    func dojiMinBody() {
        let candles = [mc(0, open: 10, high: 12, low: 8, close: 10)]
        let s = MainChartLayout.candleShapes(for: candles[0..<1], mapper: makeMapper(count: 1))[0]
        #expect(s.isUp == true)            // close==open 归涨色
        #expect(s.bodyRect.height == 0.5)  // 1 / scale(2)
    }

    @Test("slice 起始下标对齐 viewport.startIndex（第二根 x=10）")
    func indexAlignment() {
        let arr = [mc(0), mc(1, open: 10, close: 20)]
        let m = makeMapper(startIndex: 0, count: 2)
        let shapes = MainChartLayout.candleShapes(for: arr[0..<2], mapper: m)
        #expect(shapes[1].bodyRect.midX == 10)  // indexToX(1)=10
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter MainChartLayoutCandleTests`
Expected: 编译失败 —— `cannot find 'MainChartLayout' in scope`。

- [ ] **Step 3: 写最小实现**

新建 `Render/MainChartLayout.swift`：

```swift
// Kline Trainer Swift Contracts — C3 主图布局纯函数（平台无关）
// Spec: kline_trainer_modules_v1.4.md §C3 + plan 2026-05-25-pr-c3-candles-ma66-boll.md
//
// 本文件不 import UIKit：所有几何在 host swift test 真断言。
// drawXxx 的 UIKit 描边/填充薄层在 KLineView+Candles.swift（#if canImport(UIKit)）。
//
// 索引契约（D6）：用 candles.indices 作 chart index；调用方保证 slice.startIndex == viewport.startIndex。
// 中心契约（D5）：indexToX(index) 视为蜡烛水平中心，实体居中、影线在中心。

import Foundation
import CoreGraphics

/// 单根蜡烛的可描边几何原语。
struct CandleShape: Equatable, Sendable {
    let bodyRect: CGRect      // 实体矩形（已含 doji 最小高度）
    let wickTop: CGPoint      // 影线上端（高价，小 y）
    let wickBottom: CGPoint   // 影线下端（低价，大 y）
    let isUp: Bool            // close >= open（D7）
}

/// BOLL 三轨折线分段（D9：各轨按 nil 断线分段）。
struct BollPolylines: Equatable, Sendable {
    let upper: [[CGPoint]]
    let mid: [[CGPoint]]
    let lower: [[CGPoint]]
}

enum MainChartLayout {

    /// 蜡烛实体+影线几何。D5 中心 / D7 涨跌 / D8 doji 最小高度。
    /// L5 注：body 左右边缘 (cx ± width/2) 不单独 round-to-pixel——沿用 indexToX 已对齐的 cx；
    ///        candleWidth 的偶数像素由 C1a/C8 geometry 构造保证（非 C3 职责）。
    /// L6 注：minBody = 1/displayScale 不除零——displayScale 来自 traitCollection.displayScale 恒 ≥1；
    ///        下方 caller(drawCandles) 的 `guard !candles.isEmpty` 只为空 slice 短路，与除零无关。
    static func candleShapes(for candles: ArraySlice<KLineCandle>,
                             mapper: CoordinateMapper) -> [CandleShape] {
        let width = mapper.viewport.geometry.candleWidth
        let minBody = 1 / mapper.displayScale
        var shapes: [CandleShape] = []
        shapes.reserveCapacity(candles.count)
        for index in candles.indices {
            let c = candles[index]
            let cx = mapper.indexToX(index)
            let yOpen = mapper.priceToY(c.open)
            let yClose = mapper.priceToY(c.close)
            let top = min(yOpen, yClose)
            let bottom = max(yOpen, yClose)
            let height = max(bottom - top, minBody)
            let bodyRect = CGRect(x: cx - width / 2, y: top, width: width, height: height)
            shapes.append(CandleShape(
                bodyRect: bodyRect,
                wickTop: CGPoint(x: cx, y: mapper.priceToY(c.high)),
                wickBottom: CGPoint(x: cx, y: mapper.priceToY(c.low)),
                isUp: c.close >= c.open))
        }
        return shapes
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter MainChartLayoutCandleTests`
Expected: PASS（4 tests）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/MainChartLayout.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/MainChartLayoutTests.swift
git commit -m "C3 Task 1: MainChartLayout.candleShapes 蜡烛几何 + host 测试"
```

---

## Task 2: `polylineSegments` + `ma66Polyline` —— MA66 折线分段

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/MainChartLayout.swift`（加 `polylineSegments` + `ma66Polyline`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/MainChartLayoutTests.swift`（加 suite）

- [ ] **Step 1: 写失败测试**

追加到 `MainChartLayoutTests.swift`：

```swift
@Suite("MainChartLayout.ma66Polyline")
struct MainChartLayoutMA66Tests {

    @Test("leading nil 跳过：前两根 nil，后三根连成一段")
    func leadingNilSkipped() {
        let arr = [mc(0), mc(1), mc(2, ma66: 50), mc(3, ma66: 60), mc(4, ma66: 40)]
        let segs = MainChartLayout.ma66Polyline(for: arr[0..<5], mapper: makeMapper(count: 5))
        #expect(segs.count == 1)
        // index 2 → x=20, ma66=50 → y=300; index 3 → x=30, y=240; index 4 → x=40, y=360
        #expect(segs[0] == [CGPoint(x: 20, y: 300), CGPoint(x: 30, y: 240), CGPoint(x: 40, y: 360)])
    }

    @Test("内部 nil 断线分两段（D9 防御）")
    func internalGapSplits() {
        let arr = [mc(0, ma66: 50), mc(1, ma66: 60), mc(2), mc(3, ma66: 40)]
        let segs = MainChartLayout.ma66Polyline(for: arr[0..<4], mapper: makeMapper(count: 4))
        #expect(segs.count == 2)
        #expect(segs[0].count == 2)
        #expect(segs[1].count == 1)   // 单点段（draw 层会跳过 <2 点）
    }

    @Test("全 nil → 空")
    func allNil() {
        let arr = [mc(0), mc(1)]
        #expect(MainChartLayout.ma66Polyline(for: arr[0..<2], mapper: makeMapper(count: 2)).isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter MainChartLayoutMA66Tests`
Expected: 编译失败 —— `MainChartLayout` 无 `ma66Polyline`。

- [ ] **Step 3: 写最小实现**

在 `MainChartLayout` enum 内追加：

```swift
    /// 按 value 提取折线点，遇 nil 断线分段（D9）。各段内点连续。
    private static func polylineSegments(for candles: ArraySlice<KLineCandle>,
                                         mapper: CoordinateMapper,
                                         value: (KLineCandle) -> Double?) -> [[CGPoint]] {
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for index in candles.indices {
            if let v = value(candles[index]) {
                current.append(CGPoint(x: mapper.indexToX(index), y: mapper.priceToY(v)))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// MA66 折线（D1：读预计算 candle.ma66，不重算）。
    static func ma66Polyline(for candles: ArraySlice<KLineCandle>,
                             mapper: CoordinateMapper) -> [[CGPoint]] {
        polylineSegments(for: candles, mapper: mapper, value: { $0.ma66 })
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter MainChartLayoutMA66Tests`
Expected: PASS（3 tests）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/MainChartLayout.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/MainChartLayoutTests.swift
git commit -m "C3 Task 2: polylineSegments + ma66Polyline（读预计算 ma66，nil 断线）"
```

---

## Task 3: `bollPolylines` —— BOLL 上/中/下三轨

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/MainChartLayout.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/MainChartLayoutTests.swift`

- [ ] **Step 1: 写失败测试**

追加：

```swift
@Suite("MainChartLayout.bollPolylines")
struct MainChartLayoutBollTests {

    @Test("三轨各取对应 keypath（用不同值区分上中下）")
    func threeBandsDistinct() {
        let arr = [mc(0, bollUpper: 80, bollMid: 50, bollLower: 20),
                   mc(1, bollUpper: 90, bollMid: 60, bollLower: 30)]
        let b = MainChartLayout.bollPolylines(for: arr[0..<2], mapper: makeMapper(count: 2))
        #expect(b.upper.count == 1 && b.mid.count == 1 && b.lower.count == 1)
        // index0 x=0：upper 80→y=120, mid 50→y=300, lower 20→y=480
        #expect(b.upper[0][0] == CGPoint(x: 0, y: 120))
        #expect(b.mid[0][0]   == CGPoint(x: 0, y: 300))
        #expect(b.lower[0][0] == CGPoint(x: 0, y: 480))
    }

    @Test("warmup：某轨 nil 段被跳过，不连跨 gap")
    func warmupNilPerBand() {
        let arr = [mc(0), mc(1, bollUpper: 90, bollMid: 60, bollLower: 30)]
        let b = MainChartLayout.bollPolylines(for: arr[0..<2], mapper: makeMapper(count: 2))
        #expect(b.upper == [[CGPoint(x: 10, y: 60)]])  // 仅 index1：x=10, 90→y=60
        #expect(b.mid.count == 1 && b.lower.count == 1)
    }

    @Test("全 nil → 三轨皆空")
    func allNil() {
        let arr = [mc(0), mc(1)]
        let b = MainChartLayout.bollPolylines(for: arr[0..<2], mapper: makeMapper(count: 2))
        #expect(b.upper.isEmpty && b.mid.isEmpty && b.lower.isEmpty)
    }

    @Test("D3：dashPattern 段长 = 4/displayScale（虚线参数 host 可测，H1 修订）")
    func dashPatternValue() {
        #expect(MainChartLayout.dashPattern(displayScale: 2) == [2, 2])
        #expect(MainChartLayout.dashPattern(displayScale: 1) == [4, 4])
    }
}

@Suite("MainChartLayout 索引契约（D6 杀手测试：startIndex≠0）")
struct MainChartLayoutIndexTests {

    // D6 关键：用 candles.indices（母数组下标）而非 0-based enumerated offset。
    // 若实现误用 enumerated().indexToX(offset)，下列断言会 fail（offset 实现算出负 x）。

    @Test("candleShapes：slice arr[2..<5] + startIndex=2 → 首根 midX==0")
    func candleStartIndexOffset() {
        let arr = (0..<5).map { mc($0, open: 10, close: 20) }
        let m = makeMapper(startIndex: 2, count: 3)   // 可见 index 2,3,4
        let shapes = MainChartLayout.candleShapes(for: arr[2..<5], mapper: m)
        #expect(shapes.count == 3)
        #expect(shapes[0].bodyRect.midX == 0)    // indexToX(2)=0；enumerated 错误实现会得 indexToX(0)=-20
        #expect(shapes[1].bodyRect.midX == 10)   // indexToX(3)=10
        #expect(shapes[2].bodyRect.midX == 20)   // indexToX(4)=20
    }

    @Test("ma66Polyline：slice arr[2..<5] + startIndex=2 → 首点 x==0")
    func ma66StartIndexOffset() {
        let arr = (0..<5).map { mc($0, ma66: 50) }
        let m = makeMapper(startIndex: 2, count: 3)
        let segs = MainChartLayout.ma66Polyline(for: arr[2..<5], mapper: m)
        #expect(segs.count == 1)
        #expect(segs[0].map(\.x) == [0, 10, 20])  // enumerated 错误实现会得 [-20,-10,0]
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter MainChartLayoutBollTests`
Expected: 编译失败 —— 无 `bollPolylines`/`dashPattern`。

- [ ] **Step 3: 写最小实现**

在 `MainChartLayout` enum 内追加：

```swift
    /// BOLL 上/中/下三轨折线（D2：仅三线无填充；D9：各轨独立按 nil 断线）。
    static func bollPolylines(for candles: ArraySlice<KLineCandle>,
                              mapper: CoordinateMapper) -> BollPolylines {
        BollPolylines(
            upper: polylineSegments(for: candles, mapper: mapper, value: { $0.bollUpper }),
            mid:   polylineSegments(for: candles, mapper: mapper, value: { $0.bollMid }),
            lower: polylineSegments(for: candles, mapper: mapper, value: { $0.bollLower }))
    }

    /// BOLL 虚线 dash 参数（D3）。抽为纯值 → host 可测虚线"段长正确"（缩小 UIKit 不可测面，
    /// per H1 修订）；drawBOLL 仅把它喂给 ctx.setLineDash。每段 4 设备像素 on / 4 off。
    static func dashPattern(displayScale: CGFloat) -> [CGFloat] {
        let unit = 4 / displayScale
        return [unit, unit]
    }
```

- [ ] **Step 4: 跑测试确认通过 + 全 host 套件回归**

Run: `cd ios/Contracts && swift test --filter MainChartLayoutBollTests`
Expected: PASS（4 tests：三轨 distinct + warmup + allNil + dashPatternValue）。

Run: `cd ios/Contracts && swift test`
Expected: 全 package PASS，0 失败（435 基线 + 16 新 = 451；含 MainChartLayoutIndexTests 2 个 startIndex≠0 杀手测试 + 空 slice / trailing nil / @3x dash 边界）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/MainChartLayout.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/MainChartLayoutTests.swift
git commit -m "C3 Task 3: bollPolylines 三轨（无填充，各轨 nil 断线）"
```

---

## Task 4: `drawCandles` UIKit 薄层

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift`

> 说明：UIKit 代码在 host `swift build` 被 `#if canImport(UIKit)` 排除，无法 host 编译验证；本任务的编译验证统一在 **Task 7 Catalyst build**。本任务只写正确实现。

- [ ] **Step 1: 实现 `drawCandles`**

替换 `KLineView+Candles.swift` 中 `drawCandles` 方法体（保留文件头与 `#if canImport(UIKit)` 结构）：

```swift
    /// C3 主图蜡烛：实体矩形（涨/跌色填充）+ 影线（1 设备像素描边）。
    /// 几何来自 MainChartLayout.candleShapes（host 已测）；本方法仅 UIKit 描边/填充。
    func drawCandles(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        guard !candles.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(1 / mapper.displayScale)
        for shape in MainChartLayout.candleShapes(for: candles, mapper: mapper) {
            let color = shape.isUp ? AppColor.candleUp : AppColor.candleDown
            color.setFill()
            color.setStroke()
            ctx.move(to: shape.wickTop)
            ctx.addLine(to: shape.wickBottom)
            ctx.strokePath()
            ctx.fill(shape.bodyRect)
        }
    }
```

- [ ] **Step 2: host build 仍绿（确认平台无关部分未破）**

Run: `cd ios/Contracts && swift build`
Expected: build 成功（注意：此步**不**验证 UIKit 体，仅确认 host 编译面未破）。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift
git commit -m "C3 Task 4: drawCandles UIKit 薄层（candleShapes + AppColor）"
```

---

## Task 5: `drawMA66` UIKit 薄层

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift`

- [ ] **Step 1: 实现 `drawMA66`**

替换 `drawMA66` 方法体：

```swift
    /// C3 MA66：读预计算 candle.ma66 折线（实线），AppColor.ma66 着色（D1/D4）。
    func drawMA66(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        let segments = MainChartLayout.ma66Polyline(for: candles, mapper: mapper)
        guard !segments.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        AppColor.ma66.setStroke()
        ctx.setLineWidth(1 / mapper.displayScale)
        ctx.setLineJoin(.round)
        for segment in segments where segment.count >= 2 {
            ctx.move(to: segment[0])
            for point in segment.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }
    }
```

- [ ] **Step 2: host build 仍绿**

Run: `cd ios/Contracts && swift build`
Expected: build 成功。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift
git commit -m "C3 Task 5: drawMA66 UIKit 薄层（实线折线）"
```

---

## Task 6: `drawBOLL` UIKit 薄层（虚线）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift`

- [ ] **Step 1: 实现 `drawBOLL`**

替换 `drawBOLL` 方法体（**虚线**是 D3 硬要求；`saveGState/restoreGState` 隔离 dash 不泄漏给后续 drawVolume 等）：

```swift
    /// C3 BOLL：上/中/下三轨虚线（D3 plan v1.5 L6），无填充（D2），AppColor.bollLine 着色（D4）。
    func drawBOLL(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        let boll = MainChartLayout.bollPolylines(for: candles, mapper: mapper)
        let lines = [boll.upper, boll.mid, boll.lower]
        guard lines.contains(where: { !$0.isEmpty }) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        AppColor.bollLine.setStroke()
        ctx.setLineWidth(1 / mapper.displayScale)
        // D3：BOLL 虚线。dash 段长由 host 已测的 MainChartLayout.dashPattern 提供（H1 修订）。
        // saveGState/restoreGState（上方 defer）配对保证 dash 不泄漏给后续 drawVolume/drawMACD——
        // 此配对正确性靠 defer 紧跟 saveGState 的惯用法 + code review，无运行期自动验证（H1 如实记录）。
        ctx.setLineDash(phase: 0, lengths: MainChartLayout.dashPattern(displayScale: mapper.displayScale))
        for line in lines {
            for segment in line where segment.count >= 2 {
                ctx.move(to: segment[0])
                for point in segment.dropFirst() { ctx.addLine(to: point) }
                ctx.strokePath()
            }
        }
    }
```

- [ ] **Step 2: host build 仍绿**

Run: `cd ios/Contracts && swift build`
Expected: build 成功。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift
git commit -m "C3 Task 6: drawBOLL UIKit 薄层（三轨虚线，setLineDash + saveGState 隔离）"
```

---

## Task 7: Catalyst 编译闸门 + 验收脚本 + 非程序员验收清单

**Files:**
- Create: `scripts/acceptance/plan_c3_candles_ma66_boll.sh`
- Create: `docs/acceptance/2026-05-25-pr-c3-candles-ma66-boll.md`

- [ ] **Step 1: Mac Catalyst build-for-testing（验证三个 UIKit draw 方法编译 + 无 warning）**

Run:
```bash
cd ios/Contracts && set -o pipefail && xcodebuild build-for-testing \
  -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/derived-c3 2>&1 | tee /tmp/c3-catalyst.log
```
Expected: 末尾 `** TEST BUILD SUCCEEDED **`，且 `grep -E "(^|[[:space:]])(error|warning):" /tmp/c3-catalyst.log` **无输出**（CI catalyst-build job 同款闸门）。

- [ ] **Step 2: 写验收脚本**

新建 `scripts/acceptance/plan_c3_candles_ma66_boll.sh`：

```bash
#!/usr/bin/env bash
# C3 Candles + MA66 + BOLL 机检验收。仓库根目录运行。
set -uo pipefail
FAIL=0
run() { echo "--- $1"; shift; if "$@"; then echo "OK"; else echo "FAIL"; FAIL=1; fi; }

SRC="ios/Contracts/Sources/KlineTrainerContracts/Render"
LAYOUT="$SRC/MainChartLayout.swift"
DRAW="$SRC/KLineView+Candles.swift"

run "MainChartLayout.swift 存在" test -f "$LAYOUT"
run "MainChartLayoutTests.swift 存在" test -f "ios/Contracts/Tests/KlineTrainerContractsTests/Render/MainChartLayoutTests.swift"
# 匹配行首真实 import 语句，避免误伤注释 "本文件不 import UIKit"
run "布局文件平台无关（无真实 import UIKit 语句）" bash -c "! grep -qE '^import UIKit' '$LAYOUT'"
run "三布局函数存在" bash -c "grep -q 'func candleShapes' '$LAYOUT' && grep -q 'func ma66Polyline' '$LAYOUT' && grep -q 'func bollPolylines' '$LAYOUT'"
# D1 主门 = 正向断言 MA66 读预计算 $0.ma66；负向 grep 仅 best-effort（L3：易绕过，不作硬证据）
run "D1（主门）：MA66 读预计算字段 \$0.ma66" bash -c "grep -q '\\\$0.ma66' '$LAYOUT'"
run "D1（best-effort）：无 'window/滑窗' 重算关键词" bash -c "! grep -qiE 'window|滑窗' '$LAYOUT'"
run "D3：BOLL 虚线 setLineDash" bash -c "grep -q 'setLineDash' '$DRAW'"
run "D3：dash 段长抽为 host 可测 dashPattern" bash -c "grep -q 'func dashPattern' '$LAYOUT' && grep -q 'dashPattern' '$DRAW'"
run "D2：无 BOLL 填充（drawBOLL 内不出现 fill 调用）" bash -c "! awk '/func drawBOLL/,/^    }/' '$DRAW' | grep -qE 'ctx.fill|\\.fill\\('"
run "D4：引用 F2 token 不硬编码 RGB" bash -c "grep -q 'AppColor.candleUp' '$DRAW' && grep -q 'AppColor.candleDown' '$DRAW' && grep -q 'AppColor.ma66' '$DRAW' && grep -q 'AppColor.bollLine' '$DRAW'"
# H1 如实：以下仅"结构存在性"检查，不证明 save/restore 配对正确（运行期无自动验证，靠 review）
run "dash 隔离结构存在（非配对证明，H1）：drawBOLL 含 saveGState+restoreGState" bash -c "awk '/func drawBOLL/,/^    }/' '$DRAW' | grep -q 'saveGState' && awk '/func drawBOLL/,/^    }/' '$DRAW' | grep -q 'restoreGState'"
run "M0.4 豁免：C3 不碰 AppError" bash -c "! grep -q 'AppError' '$LAYOUT' '$DRAW'"
run "host swift test exit 0" bash -c "cd ios/Contracts && swift test"

if [ "$FAIL" -eq 0 ]; then echo "=== ALL C3 ACCEPTANCE CHECKS PASSED ==="; else echo "=== C3 ACCEPTANCE FAILED ==="; exit 1; fi
```

- [ ] **Step 2b: 跑验收脚本**

Run: `bash scripts/acceptance/plan_c3_candles_ma66_boll.sh`
Expected: 每行 `OK`，末行 `=== ALL C3 ACCEPTANCE CHECKS PASSED ===`。

- [ ] **Step 3: 写非程序员验收清单**

新建 `docs/acceptance/2026-05-25-pr-c3-candles-ma66-boll.md`：

```markdown
# 验收清单 — C3 主图渲染 Candles + MA66 + BOLL（Wave 1 顺位 9 / 第 11 个 PR）

> 给非程序员逐条核对。每条：照"动作"敲命令 → 比对"期望" → 在"通过"打 ✓/✗。命令在仓库根目录运行。
> 模块 C3 = 把 K 线主图的"蜡烛 + 66 均线 + 布林带"从空占位补成真画图代码。画图本身（描边/填充）由苹果编译器在 CI 验证；所有计算（蜡烛矩形/影线/折线坐标）在电脑上跑真测试。

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | 运行：`cd ios/Contracts && swift test --filter MainChartLayout` | 全部通过，0 失败（16 项：蜡烛 5 + MA66 5 + BOLL 4 + 索引契约 2） | ☐ |
| 2 | 运行：`cd ios/Contracts && swift test` | 全 package 通过，0 失败（在既有 435 基础上增加 16 项 → 451） | ☐ |
| 3 | 运行：`bash scripts/acceptance/plan_c3_candles_ma66_boll.sh` | 每行 `OK`，末行 `=== ALL C3 ACCEPTANCE CHECKS PASSED ===` | ☐ |
| 4 | 在浏览器打开本 PR → 看底部 CI 检查 | `swift test on macos-15` 与 `Mac Catalyst build-for-testing on macos-15` 两项均 ✓ 绿 | ☐ |
| 5 | 运行：`grep -ci '占位\|stub' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift` | 输出 `0`（三个方法已从空占位 stub 变成真实现，"占位/stub" 字样清除） | ☐ |
| 6 | 运行：`grep -n 'setLineDash' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift` | 命中（布林带按需求画成虚线） | ☐ |
| 7 | 运行：`grep -n 'AppError' ios/Contracts/Sources/KlineTrainerContracts/Render/MainChartLayout.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift` | **无任何输出**（纯画图，不碰错误类型，M0.4 豁免） | ☐ |
| 8 | 运行：`git diff --name-only main...HEAD` | 改动 = MainChartLayout.swift（新）/ KLineView+Candles.swift（改）/ MainChartLayoutTests.swift（新）/ 验收脚本 / 本清单 / plan 文档（**无 migration / 无 .sql / 无 backend**） | ☐ |

**任一条 ✗ → 不得 merge。** 第 1/2/3/4 条是硬门（计算真测 + 画图真编译 + CI 双绿）。
```

- [ ] **Step 4: Commit**

```bash
git add scripts/acceptance/plan_c3_candles_ma66_boll.sh docs/acceptance/2026-05-25-pr-c3-candles-ma66-boll.md
git commit -m "C3 Task 7: Catalyst 闸门 + 验收脚本 + 非程序员验收清单"
```

---

## Self-Review（写完即查，发现即改）

**1. Spec coverage**
- §C3 `drawCandles` → Task 1（几何）+ Task 4（描边）✓
- §C3 `drawMA66` → Task 2（折线）+ Task 5（描边）✓；D1 读预计算 ma66 ✓
- §C3 `drawBOLL` → Task 3（三轨）+ Task 6（虚线描边）✓；D2 无填充 ✓ / D3 虚线 ✓
- plan v1.5 L6 BOLL 虚线 → D3 + Task 6 `setLineDash` ✓
- plan v1.5 L934 红涨绿跌 → D7 `isUp = close>=open` + `AppColor.candleUp/Down` ✓
- §15.1 #3 Catalyst 编译闸门 → Task 7 Step 1 ✓
- M0.4：C3 不消费 AppError → 豁免，验收脚本 grep 断言 ✓

**2. Placeholder scan**：各 step 均含完整代码/命令/期望；无 TBD/TODO/"类似 Task N"。✓

**3. Type consistency**：`candleShapes`/`ma66Polyline`/`bollPolylines`/`polylineSegments` 命名在 Task 1-6 与测试/验收脚本一致；`CandleShape`{bodyRect,wickTop,wickBottom,isUp}、`BollPolylines`{upper,mid,lower} 字段在测试与实现一致；`AppColor.candleUp/candleDown/ma66/bollLine` 与 Theme.swift L103-106 一致；`mapper.viewport.geometry.candleWidth` / `mapper.displayScale` / `indexToX` / `priceToY` 与 Geometry.swift 一致。✓

**4. 已知 residual（交评审/用户）**
- D4 颜色命名/取值：F2 `ma66`=紫、`bollLine`=橙，与 plan v1.5 §一 "MA66 亮橙 / BOLL 灰" 文案不符。C3 引用 token 保持 DRY 正确；若要改色须独立 F2-revision RFC（不在 C3 scope）。
- 单点折线段（内部 gap 防御产物）draw 层跳过 <2 点段——B1 契约下不应出现内部 gap，属防御冗余。

---

## Plan-stage 对抗性评审收敛记录（Opus 4.7 xhigh，Round 1）

Round 1 裁决 **NEEDS-ATTENTION**（0 Critical / 1 High / 余 Low+观察）；手算复核 19 个写死期望值**全部一致**（测试数学正确）。已修：

| Finding | 处理 |
|---|---|
| **H1** dash 不泄漏契约零实质验证（grep 仅字符串存在） | 抽 `dashPattern(displayScale:)` 纯函数 → host 测段长；D3 + 验收脚本如实标注 save/restore 配对**无运行期自动验证**（靠 defer 惯用法 + review），grep 仅"结构存在性"非"配对证明" |
| **L1/L2** D6 索引契约无杀手测试（所有 slice 起点 0，enumerated-offset bug 会漏过） | 新增 `MainChartLayoutIndexTests`：`startIndex=2 + arr[2..<5]`，断言首根 midX==0 / 首点 x==0（错误实现会得 -20，必 fail） |
| **L3** D1 反向 grep `reduce.*close` 过窄易绕过 | 拆为"主门=正向 `$0.ma66` 断言" + "best-effort=仅 `window/滑窗`"，不再伪装成硬证据 |
| **L5** D5 body 边缘像素对齐未说明 | candleShapes 注释点明 body 边缘不单独 round，偶数 candleWidth 由 C1a/C8 保证 |
| **L6** displayScale==0 除零结论略草 | candleShapes 注释澄清 displayScale≥1 由 traitCollection 不变量保证；guard 仅为空 slice 短路 |
| M1/L4（观察项） | M1 dash 隔离"必要性"措辞已随 H1 改为面向未来 C4-C6 的防御；L4 lineJoin 不一致不改（spec 无要求） |

新增测试后总计 +16（蜡烛 5 + MA66 5 + BOLL 4 + 索引契约 2；含 impl-stage code-review 补的空 slice / trailing nil / @3x dash / down-candle wick 边界）。Round 2 复审目标：确认 H1/L1-L6 修订落地 + 无新 finding → APPROVE。

---

## Execution Handoff

本 plan 用户已指定执行路径：**Subagent-Driven（superpowers:subagent-driven-development）**——每 Task 派新 subagent（Sonnet 4.6 high effort，per `feedback_subagent_model_selection`）+ 两阶段 review；plan-stage 先过一轮 Claude Opus 4.7 xhigh 对抗性评审收敛，impl 完再过一轮整体 Opus 4.7 xhigh 对抗性评审收敛。
