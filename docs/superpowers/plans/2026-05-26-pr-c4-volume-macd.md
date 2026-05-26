# C4 副图渲染（Volume + MACD）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PR #51 留下的 C4 两个空 stub（`drawVolume` / `drawMACD`）替换为真实现：成交量柱（红涨绿跌，与主图同步）+ MACD 子图（DIF 白线 / DEA 黄线 + 柱状，正红负绿）。

**Architecture:** 几何/布局逻辑（成交量柱矩形、MACD 折线分段、MACD 柱基线钳制）抽到**平台无关**纯函数文件 `SubChartLayout.swift`（只依赖 CoreGraphics + 已冻结的 `IndicatorMapper`/`KLineCandle`），由 macOS host `swift test` 真断言。`KLineView+Volume.swift` 与 `KLineView+MACD.swift` 两个方法降为**薄 UIKit 层**——调用布局函数拿到几何原语，再用 `AppColor` token + CGContext 描边/填充，由 Mac Catalyst `build-for-testing` 编译闸门守护（UIKit 在 host 不可编译，仅编译验证，无运行期测试）。这与 C3 已落地的 `MainChartLayout`（平台无关、host 全测）+ §15.1 #3 Catalyst 编译闸门完全同款两闸门架构。**DRY 决议**：C3 `MainChartLayout.polylineSegments` 形参用 `CoordinateMapper`，C4 用 `IndicatorMapper`，两个版本各 7 行字面同款仅 mapper 类型不同；引入 protocol/泛型抽象不划算（CLAUDE.md "No abstractions for single-use code"）。本 PR 不改 `MainChartLayout`，SubChartLayout 内私有重新实现 `IndicatorMapper` 版本。

**Tech Stack:** Swift 6.0 / Swift Testing（`import Testing` + `@Test` + `#expect`）/ CoreGraphics（host 可用）/ UIKit（仅 Catalyst）/ 已冻结模块：`IndicatorMapper`（C1a Geometry.swift）、`NonDegenerateRange`（C1a）、`KLineCandle`（F1/Models，含 `volume: Int64` + `macdDiff/macdDea/macdBar: Double?`）、`AppColor.candleUp/candleDown/macdDIF/macdDEA/macdBarPositive/macdBarNegative`（F2 Theme.swift）。

---

## 背景与既有接缝（实施者必读）

- 派发点已存在且不改动：`Render/KLineView.swift` 的 `draw(_:)` 已调用 `drawVolume(ctx:mapper:candles:)` 与 `drawMACD(ctx:mapper:candles:)`（modules L1222-1223 + 既有 KLineView.swift L51-52）。本 PR 只填两个方法体 + 新增布局文件 + 测试。
- 当前 stub：`Render/KLineView+Volume.swift` 与 `Render/KLineView+MACD.swift`（各 1 个空方法，`#if canImport(UIKit)` 守卫）。
- `IndicatorMapper`（`Geometry/Geometry.swift` L172-199，平台无关）API：
  - `let frame: CGRect`（子图区，由 caller 注入 `renderState.frames.volumeChart` / `.macdChart`）
  - `let valueRange: NonDegenerateRange`（外部注入 `renderState.volumeRange` / `.macdRange`，由 C8 Wave 2 构造）
  - `let viewport: ChartViewport`（含 `startIndex: Int`、`geometry.candleWidth: CGFloat`、`pixelShift: CGFloat`）
  - `let displayScale: CGFloat`
  - `func indexToX(_ index: Int) -> CGFloat`（已 round-to-device-pixel，与 `CoordinateMapper.indexToX` 同算法 + 同 pixelShift 符号契约）
  - `func valueToY(_ value: Double) -> CGFloat`（已 round-to-device-pixel；`ratio = (value - valueRange.lower) / valueRange.span`，`raw = frame.maxY - ratio * frame.height`，`span > 0` 由 `NonDegenerateRange.make` caller 契约保证）
- `KLineCandle`（`Models/Models.swift`，平台无关）：
  - `volume: Int64`（**非可选**，永不为 nil）
  - `macdDiff/macdDea/macdBar: Double?`（**后端 B1 在全序列上预计算**；warmup 段为 nil；C4 不重算）
- `KLineRenderState.empty`（已落地）的 `volumeRange = NonDegenerateRange.make(values: [])`、`macdRange = NonDegenerateRange.make(values: [])` 落入 fallback `0.0...1.0`（合法非退化值，不是 sentinel）。**C4 必须用 `visibleCandles.isEmpty` 判 "no-data" 短路，不用 range 值判 emptiness**（与 KLineRenderState.swift L67-70 已写注释口径完全一致）。
- `AppColor` F2 token（`Theme/Theme.swift`，`#if canImport(UIKit)`）：
  - `.candleUp` / `.candleDown`：成交量柱涨跌色（与主图蜡烛同步，D7）
  - `.macdDIF`：DIF 折线白色（Theme L107 `AppColorTokens.macdDIF = white 1.0`）
  - `.macdDEA`：DEA 折线黄色（Theme L108 `AppColorTokens.macdDEA = (1.00,0.84,0.20)`，对应 spec v1.5 §2 变更）
  - `.macdBarPositive` / `.macdBarNegative`：MACD 柱正/负色（Theme L109-110，派生自 `candleUp/candleDown`）
- C3 既有助手：`MainChartLayout.polylineSegments(for:mapper:value:)` 当前是 `private static`，签名 `(ArraySlice<KLineCandle>, CoordinateMapper, (KLineCandle) -> Double?) -> [[CGPoint]]`。**本 PR 不修改 `MainChartLayout`**；SubChartLayout 内独立私有实现 `IndicatorMapper` 版本（与 C3 字面同款仅 mapper 类型差），不引入泛型/协议（CLAUDE.md "Simplicity First / 不为 2 caller 抽象"）。
- 测试基线：当前 451 tests / 81 suites（PR #66 merge 后）。本 PR 目标 **+15 host 测试**（volume 5 + macdLines 4 + macdBars 6 → 实际 **466 total**）。

---

## Task 0 — §15.3 评审策略前置 + spec 偏差裁决

> 完成 Task 0 才进 Task 1。本节是**决策记录**，无代码；实施者据此实现，评审据此核对。

- [ ] **局部对抗性评审（必）**：本 plan C4 scope 内对抗性 review = 用户本次显式指定 **Claude Opus 4.7 xhigh effort 双闸门**：plan-stage 收敛 + impl-stage 收敛；codex 周配额若耗尽走 opus fallback（按 memory `feedback_openai_quota_ci_pattern`）。4-5 轮收敛或 escalate（`feedback_codex_plan_budget_overshoot`）。
- [ ] **集成层评审（N/A）**：C8 `ChartContainerView` 桥接 + `buildRenderState`（含 volumeRange/macdRange 计算）在 **Wave 2**；本 PR 不含集成层，不触发集成评审。
- [ ] **性能评审（N/A）**：plan v1.5 §一 "单帧 <4ms / Instruments" 属 **Phase 5 磨光 PR**；C4 是 Phase 1 纯 `draw(_:)` 渲染，本 PR 不做 Instruments 评审（同 C3 决议）。

### Spec 偏差裁决（D1-D11，全部写进代码注释 + 验收）

| # | 偏差/歧义 | 裁决 | 权威依据 |
|---|---|---|---|
| **D1** | MACD 是否在 C4 内重算 DIF/DEA/MACD bar | **错，不采纳**。C4 **读** `candle.macdDiff/macdDea/macdBar` 预计算值，**不重算**。理由：MACD 由后端 B1 在**全序列**算（plan v1.5 L720）；可见 slice 缺历史无法重算；与 C3 D1 同口径。 | `Models.swift` L69-71 macdDiff/Dea/Bar 字段 + plan v1.5 L720 后端 pandas-ta 计算 + 与 C3 D1 同口径 |
| **D2** | 是否画 MACD 零线 / 网格线 | **不画**。零线 / 网格线属 C5 辅助层（modules §C5 L1298-1313）或独立美化 PR；C4 仅 DIF/DEA/bar 三类原始几何。 | modules §C4 L1289-1294 仅 `drawVolume` + `drawMACD` 两签名；§C5 才是 crosshair/markers/grid 层；Simplicity First |
| **D3** | DIF/DEA 线型 | **实线**（与 BOLL 虚线相反）。modules + plan 文案均未提虚线；标准 MACD 视觉是实线。 | plan v1.5 L799/L936 "DIF白线 + DEA黄线"（无虚线字样）+ modules L799 同款 + 反例 BOLL 才有显式 "灰色虚线"字样 |
| **D4** | 颜色来源 | C4 **引用 F2 token**：`AppColor.candleUp/candleDown`（volume 柱）/ `.macdDIF`/`.macdDEA`（折线）/ `.macdBarPositive/.macdBarNegative`（MACD 柱）。**不硬编码 RGB**。F2 token 取值与 spec 描述（白/黄/红/绿）已经 PR #39 冻结。 | DRY 单一色源 + F2 `project_pr39_f2_merged` 已冻结 + memory `feedback_outline_no_inline_implementation` |
| **D5** | `mapper.indexToX(index)` 语义 = bar 中心还是左缘 | C4 视其为**柱水平中心**：volume/MACD 柱矩形以 cx 居中（`minX = cx - candleWidth/2`，与 C3 D5 完全同款）。 | 与 C3 D5 同口径；标准 K 线柱状惯例；body+wick 共用 cx 内部自洽 |
| **D6** | 可见 slice 的 index 与 chart index 对齐 | C4 用 `candles.indices`（`ArraySlice` 保留母数组下标）作 chart index 传给 `mapper.indexToX`；调用方（C8，Wave 2）保证 `slice.startIndex == viewport.startIndex`。 | 与 C3 D6 同口径 + `ArraySlice` 语义 + C8 `buildRenderState` 用 `fullArray[range]` 构造 |
| **D7** | volume 柱涨跌判定（含平盘 doji） | `isUp = close >= open`（平盘归"涨"色，与 C3 D7 字面同款 + AppColor 仅 candleUp/candleDown 两色）。**volume 柱色 = 当根蜡烛涨跌色**，不依赖 volume 本身大小。 | 与 C3 D7 同口径；plan v1.5 L797 "交易量柱状图" 紧贴 K 线视觉 |
| **D8** | volume==0（停牌罕见）柱高 | 柱高最小 = `1 / displayScale`（1 个设备像素）。 | 与 C3 D8 doji 同口径 + 渲染常识；valueToY 已 round-to-device-pixel |
| **D9** | MACD warmup 段 nil + 防御性内部 gap | DIF/DEA 折线遇 nil **断线分段**：leading nil 跳过；内部 nil（B1 契约下不应出现，防御）切多段；<2 点段不描边（与 C3 D9 同口径）。MACD **bar**：遇 nil 跳过该根（不画柱）。 | B1 warmup 契约 + 与 C3 D9 同口径 |
| **D10**（C4 新增）| volume 柱基线 | **基线 = `frame.maxY`**（=子图区底边 = `valueToY(volumeRange.lower)`）。柱顶 = `valueToY(volume)`；高度 = `frame.maxY - valueToY(volume)`。语义：柱高反映**可见区相对幅度**（valueRange.lower=最小成交量，lower 不一定 0）；这与"标准成交量柱锚定到 0"在 NonDegenerateRange.make 给出正 lower 的情况下视觉等价、计算更省（不需 valueToY(0) 钳制）。 | NonDegenerateRange.make 上下加 padding（modules L941-948）；valueToY(lower)==frame.maxY 是 valueToY 直接结论；caller 已注入 valueRange |
| **D11**（C4 新增）| MACD 柱基线（含 0 不在 macdRange 内的退化）| **基线 = `clampedValueToY0 = clamp(valueToY(0), frame.minY, frame.maxY)`**。正常情形下 macdRange 跨 0 → `valueToY(0)` 在 frame 内；退化情形（C8 给出的 macdRange 不含 0，例如全正/全负 + 不够 padding）→ 钳制到上/下边。对正/负柱分别从基线向 `valueToY(macdBar)` 描绘；高度最小 = `1 / displayScale`（macdBar==0 时）。 | NonDegenerateRange.make 不强制包含 0；防御性钳制不掩盖 C8 责任（C8 Wave 2 落地时可再加 contract 测试） |
| **D12**（R1-H1 修订）| 测试如何构造任意 `NonDegenerateRange` 用于精确像素算术 | **测试用 implicit-internal memberwise init 走 `@testable import` 通道**：`NonDegenerateRange(lower: 0, upper: 1000)` 等。理由：`NonDegenerateRange.make(values:)` 上下加 paddingRatio=0.02 padding → 数值不整除，破坏精确像素期望值（demonstrator-grade 测试要求）。这与现有 GeometryTests.swift（L476/506/514 大量 `.make` + L506-518 直接验 padding 的 round-trip）协调：现有 tests 走 `.make`，我们走 implicit init，两者通过 `@testable` 同等合法。**契约脆弱性**：若 Geometry.swift 未来收紧为 explicit `private init`，本 PR 测试需迁移到 `.make + 容差`；本 PR 不预先处理（YAGNI；现实是 implicit internal 已稳定数月）。 | `@testable` 是 Swift 官方测试惯例；现有 GeometryTests 走同款 import；CLAUDE.md "不为假设抽象" |
| **D9a/D9b**（M3 修订）| D9 拆细 | **D9a 折线（DIF/DEA/BOLL/MA66）**：遇 nil **断线分段**，segment.count < 2 不描边；leading nil 跳过；内部 nil 切多段（B1 契约下不应出现，防御）。**D9b 柱（Volume/MACD bar）**：Volume 柱 `volume: Int64` 非可选不会 nil；MACD `macdBar: Double?` 遇 nil **直接跳过该根**（不画柱）。两个口径在 plan 内须明确区分以免实施者混用。 | spec 字段类型 + 渲染惯例 |

---

## File Structure

| 文件 | 动作 | 职责 | 平台 |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Render/SubChartLayout.swift` | **新建** | 纯布局函数：`volumeBars` / `macdLines`（DIF+DEA）/ `macdBars` / `macdBarBaseline` + 私有 `polylineSegments`（`IndicatorMapper` 重载）；返回 `CGRect`/`CGPoint` 几何原语 | 平台无关（host 可测） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift` | **改**（填 stub） | `drawVolume` 调用布局函数 + `AppColor` token + CGContext fill | `#if canImport(UIKit)`（仅 Catalyst） |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | **改**（填 stub） | `drawMACD` 调用布局函数 + `AppColor` token + CGContext stroke（DIF/DEA）+ fill（柱）| `#if canImport(UIKit)`（仅 Catalyst） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/SubChartLayoutTests.swift` | **新建** | 布局函数 host 测试（volume 柱 / MACD 折线 / MACD 柱 / 索引契约杀手） | 平台无关（host 跑） |
| `scripts/acceptance/plan_c4_volume_macd.sh` | **新建** | 机检验收脚本 | bash |
| `docs/acceptance/2026-05-26-pr-c4-volume-macd.md` | **新建** | 非程序员逐条验收清单 | md |

---

## Task 1: `SubChartLayout.volumeBars` —— 成交量柱几何

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/SubChartLayout.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/SubChartLayoutTests.swift`

- [ ] **Step 1: 写失败测试**

新建 `SubChartLayoutTests.swift`：

```swift
// Kline Trainer Swift Contracts — C4 SubChartLayout host tests
// Spec: kline_trainer_modules_v1.4.md §C4 + plan 2026-05-26-pr-c4-volume-macd.md
// 平台无关：只 import CoreGraphics（host swift test 直跑，不需 Catalyst）。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

// MARK: - 测试构造器
private func mc(_ index: Int,
               open: Double = 10, close: Double = 10,
               volume: Int64 = 100,
               macdDiff: Double? = nil, macdDea: Double? = nil, macdBar: Double? = nil) -> KLineCandle {
    KLineCandle(period: .m3, datetime: Int64(index),
                open: open, high: max(open, close), low: min(open, close), close: close,
                volume: volume, amount: nil, ma66: nil,
                bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: macdDiff, macdDea: macdDea, macdBar: macdBar,
                globalIndex: index, endGlobalIndex: index)
}

/// 干净取整的 IndicatorMapper for volume：step=10, width=6, scale=2, valueRange 0...1000, frame y∈[0,200]。
/// indexToX(startIndex + k) == k*10；valueToY(v) == 200 - v*0.2（v∈[0,1000]）。
private func makeVolumeMapper(startIndex: Int = 0, count: Int,
                              lower: Double = 0, upper: Double = 1000) -> IndicatorMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return IndicatorMapper(frame: CGRect(x: 0, y: 0, width: 1000, height: 200),
                           valueRange: NonDegenerateRange(lower: lower, upper: upper),
                           geometry: geom, viewport: vp, displayScale: 2)
}

/// 干净取整的 MACD mapper：valueRange -50...50（跨 0），frame y∈[0,200]。
/// valueToY(0) == 100；valueToY(50)==0；valueToY(-50)==200。
private func makeMacdMapper(startIndex: Int = 0, count: Int,
                            lower: Double = -50, upper: Double = 50) -> IndicatorMapper {
    let geom = ChartGeometry(candleStep: 10, candleWidth: 6, gap: 4)
    let vp = ChartViewport(startIndex: startIndex, visibleCount: count, pixelShift: 0,
                           geometry: geom,
                           priceRange: PriceRange(min: 0, max: 100),
                           mainChartFrame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    return IndicatorMapper(frame: CGRect(x: 0, y: 0, width: 1000, height: 200),
                           valueRange: NonDegenerateRange(lower: lower, upper: upper),
                           geometry: geom, viewport: vp, displayScale: 2)
}

@Suite("SubChartLayout.volumeBars")
struct SubChartLayoutVolumeTests {

    @Test("涨蜡烛对应红柱：isUp=true，基线=frame.maxY，柱顶=valueToY(volume)")
    func upBar() {
        let candles = [mc(0, open: 10, close: 20, volume: 500)]
        let m = makeVolumeMapper(count: 1)
        let bars = SubChartLayout.volumeBars(for: candles[0..<1], mapper: m)
        #expect(bars.count == 1)
        let b = bars[0]
        #expect(b.isUp == true)
        // cx = indexToX(0) = 0；width = 6 → minX = -3
        #expect(b.rect.minX == -3)
        #expect(b.rect.width == 6)
        // volume=500 → y=200 - 500*0.2 = 100；基线=frame.maxY=200 → 高度 100
        #expect(b.rect.minY == 100)
        #expect(b.rect.height == 100)
    }

    @Test("跌蜡烛对应绿柱：isUp=false")
    func downBar() {
        let candles = [mc(0, open: 20, close: 10, volume: 250)]
        let b = SubChartLayout.volumeBars(for: candles[0..<1], mapper: makeVolumeMapper(count: 1))[0]
        #expect(b.isUp == false)
        // volume=250 → y=200 - 50 = 150；高度 50
        #expect(b.rect.minY == 150)
        #expect(b.rect.height == 50)
    }

    @Test("volume==0（停牌）柱高=1/displayScale 最小（D8）+ 中心契约 D5（M1）")
    func zeroVolumeMinHeight() {
        let candles = [mc(0, open: 10, close: 10, volume: 0)]
        // valueRange.lower 0：valueToY(0) == frame.maxY == 200；高度本身 0
        let b = SubChartLayout.volumeBars(for: candles[0..<1], mapper: makeVolumeMapper(count: 1))[0]
        #expect(b.rect.minX == -3 && b.rect.width == 6)    // M1：D5 中心契约
        #expect(b.rect.height == 0.5)                       // 1 / scale(2)
    }

    @Test("lower>0：基线仍取 frame.maxY（=valueToY(lower)），不取 valueToY(0)（D10）+ M1 中心契约")
    func baselineFromLowerNotZero() {
        // valueRange 100...1000：valueToY(100)==200 (frame.maxY)；valueToY(0)==222.222... off-frame
        let candles = [mc(0, volume: 100)]
        let m = makeVolumeMapper(count: 1, lower: 100, upper: 1000)
        let b = SubChartLayout.volumeBars(for: candles[0..<1], mapper: m)[0]
        // volume=100 == lower → valueToY=200 → 高度本应 0，被 D8 撑到 0.5
        #expect(b.rect.minX == -3 && b.rect.width == 6)    // M1
        #expect(b.rect.height == 0.5)
        // 高 volume=1000 → valueToY=0 → 高度 200
        let b2 = SubChartLayout.volumeBars(for: [mc(1, volume: 1000)][0..<1], mapper: m)[0]
        #expect(b2.rect.minX == -3 && b2.rect.width == 6)  // M1
        #expect(b2.rect.height == 200)
        #expect(b2.rect.minY == 0)
    }

    @Test("D6 杀手：slice arr[2..<5] + startIndex=2 → 首根 midX==0（防 enumerated-offset bug）")
    func indexAlignment() {
        let arr = (0..<5).map { mc($0, volume: 100) }
        let m = makeVolumeMapper(startIndex: 2, count: 3)
        let bars = SubChartLayout.volumeBars(for: arr[2..<5], mapper: m)
        #expect(bars.count == 3)
        #expect(bars[0].rect.midX == 0)    // indexToX(2)=0
        #expect(bars[1].rect.midX == 10)
        #expect(bars[2].rect.midX == 20)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter SubChartLayoutVolumeTests`
Expected: 编译失败 —— `cannot find 'SubChartLayout' in scope`。

- [ ] **Step 3: 写最小实现**

新建 `Render/SubChartLayout.swift`（仅 `volumeBars` + 类型定义；`macdLines`/`macdBars`/`polylineSegments` 在 Task 2-3 增量追加）：

```swift
// Kline Trainer Swift Contracts — C4 副图布局纯函数（平台无关）
// Spec: kline_trainer_modules_v1.4.md §C4 + plan 2026-05-26-pr-c4-volume-macd.md
//
// 本文件不 import UIKit：所有几何在 host swift test 真断言。
// drawXxx 的 UIKit 描边/填充薄层在 KLineView+Volume.swift / KLineView+MACD.swift（#if canImport(UIKit)）。
//
// 索引契约（D6）：用 candles.indices 作 chart index；调用方保证 slice.startIndex == viewport.startIndex（与 C3 同口径）。
// 中心契约（D5）：indexToX(index) 视为柱水平中心，矩形居中（与 C3 同口径）。

import Foundation
import CoreGraphics

/// 单根成交量柱的可描边几何原语。
struct VolumeBar: Equatable, Sendable {
    let rect: CGRect     // 柱矩形（基线=frame.maxY；柱顶=valueToY(volume)；含 D8 最小高度）
    let isUp: Bool       // 当根蜡烛 close >= open（D7：柱色 = 蜡烛色）
}

/// 单根 MACD 柱的可描边几何原语。
struct MacdBar: Equatable, Sendable {
    let rect: CGRect     // 柱矩形（D11 基线钳制 + D8 最小高度）
    let isPositive: Bool // macdBar >= 0
}

/// MACD 两轨折线分段（D9：按 nil 断线分段）。
struct MacdLines: Equatable, Sendable {
    let dif: [[CGPoint]]
    let dea: [[CGPoint]]
}

enum SubChartLayout {

    /// 成交量柱几何（D7 涨跌色 / D8 最小高度 / D10 基线=frame.maxY）。
    static func volumeBars(for candles: ArraySlice<KLineCandle>,
                           mapper: IndicatorMapper) -> [VolumeBar] {
        let width = mapper.viewport.geometry.candleWidth
        let baseline = mapper.frame.maxY    // D10：=valueToY(valueRange.lower)，柱锚定子图底边
        let minBar = 1 / mapper.displayScale
        var bars: [VolumeBar] = []
        bars.reserveCapacity(candles.count)
        for index in candles.indices {
            let c = candles[index]
            let cx = mapper.indexToX(index)
            let top = mapper.valueToY(Double(c.volume))
            // baseline >= top 通常成立（volume >= lower）；防御性 max 保证非负高度
            let height = max(baseline - top, minBar)
            let rect = CGRect(x: cx - width / 2, y: baseline - height, width: width, height: height)
            bars.append(VolumeBar(rect: rect, isUp: c.close >= c.open))
        }
        return bars
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter SubChartLayoutVolumeTests`
Expected: PASS（5 tests）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/SubChartLayout.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/SubChartLayoutTests.swift
git commit -m "C4 Task 1: SubChartLayout.volumeBars 成交量柱几何 + host 测试"
```

---

## Task 2: `SubChartLayout.macdLines` —— MACD DIF/DEA 折线（含 IndicatorMapper polylineSegments 重载）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/SubChartLayout.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/SubChartLayoutTests.swift`

- [ ] **Step 1: 写失败测试**

追加到 `SubChartLayoutTests.swift`：

```swift
@Suite("SubChartLayout.macdLines")
struct SubChartLayoutMacdLinesTests {

    @Test("DIF 与 DEA 各自独立折线，warmup nil 跳过")
    func difDeaDistinctAndWarmup() {
        let arr = [mc(0),                                     // 全 nil
                   mc(1, macdDiff: 20, macdDea: 10),         // 都有
                   mc(2, macdDiff: -10, macdDea: 5),         // 都有
                   mc(3, macdDiff: 30, macdDea: nil)]        // 只 dif
        let m = makeMacdMapper(count: 4)
        let lines = SubChartLayout.macdLines(for: arr[0..<4], mapper: m)
        // DIF：index 1,2,3 三点连成 1 段（中间不断）
        #expect(lines.dif.count == 1)
        // index1 x=10, dif=20 → y = 200 - (20-(-50))/100*200 = 60
        // index2 x=20, dif=-10 → y = 200 - 40/100*200 = 120
        // index3 x=30, dif=30 → y = 200 - 80/100*200 = 40
        #expect(lines.dif[0] == [CGPoint(x: 10, y: 60), CGPoint(x: 20, y: 120), CGPoint(x: 30, y: 40)])
        // DEA：index 1,2 两点连成 1 段（index 3 nil 断段，末尾无新段所以只 1 段）
        #expect(lines.dea.count == 1)
        // dea=10 → y = 200 - 60/100*200 = 80；dea=5 → y = 200 - 55/100*200 = 90
        #expect(lines.dea[0] == [CGPoint(x: 10, y: 80), CGPoint(x: 20, y: 90)])
    }

    @Test("内部 nil 断段（D9 防御）")
    func internalGapSplits() {
        let arr = [mc(0, macdDiff: 10, macdDea: 5),
                   mc(1, macdDiff: 20, macdDea: 10),
                   mc(2),                                     // gap
                   mc(3, macdDiff: 30, macdDea: nil)]
        let lines = SubChartLayout.macdLines(for: arr[0..<4], mapper: makeMacdMapper(count: 4))
        #expect(lines.dif.count == 2)
        #expect(lines.dif[0].count == 2)
        #expect(lines.dif[1].count == 1)   // 单点段（draw 层跳过 <2）
    }

    @Test("全 nil → 两轨皆空")
    func allNil() {
        let arr = [mc(0), mc(1)]
        let lines = SubChartLayout.macdLines(for: arr[0..<2], mapper: makeMacdMapper(count: 2))
        #expect(lines.dif.isEmpty && lines.dea.isEmpty)
    }

    @Test("D6 杀手：slice arr[2..<5] + startIndex=2 → 首点 x==0")
    func indexAlignment() {
        let arr = (0..<5).map { mc($0, macdDiff: 0, macdDea: 0) }
        let m = makeMacdMapper(startIndex: 2, count: 3)
        let lines = SubChartLayout.macdLines(for: arr[2..<5], mapper: m)
        #expect(lines.dif.count == 1)
        // dif=0 → valueToY(0) = 200 - 50/100*200 = 100
        #expect(lines.dif[0].map(\.x) == [0, 10, 20])
        #expect(lines.dif[0].allSatisfy { $0.y == 100 })
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter SubChartLayoutMacdLinesTests`
Expected: 编译失败 —— `SubChartLayout` 无 `macdLines`。

- [ ] **Step 3: 写最小实现**

在 `SubChartLayout` enum 内追加：

```swift
    /// 按 value 提取折线点，遇 nil 断线分段（D9，IndicatorMapper 重载）。
    /// 与 MainChartLayout.polylineSegments 算法字面同款，仅 mapper 类型不同；不抽协议保持简单（5 行不值得引入泛型）。
    private static func polylineSegments(for candles: ArraySlice<KLineCandle>,
                                         mapper: IndicatorMapper,
                                         value: (KLineCandle) -> Double?) -> [[CGPoint]] {
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for index in candles.indices {
            if let v = value(candles[index]) {
                current.append(CGPoint(x: mapper.indexToX(index), y: mapper.valueToY(v)))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// MACD DIF + DEA 折线（D1：读预计算 candle.macdDiff/macdDea，不重算；D9：各轨独立 nil 断线）。
    static func macdLines(for candles: ArraySlice<KLineCandle>,
                          mapper: IndicatorMapper) -> MacdLines {
        MacdLines(
            dif: polylineSegments(for: candles, mapper: mapper, value: { $0.macdDiff }),
            dea: polylineSegments(for: candles, mapper: mapper, value: { $0.macdDea }))
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ios/Contracts && swift test --filter SubChartLayoutMacdLinesTests`
Expected: PASS（4 tests）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/SubChartLayout.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/SubChartLayoutTests.swift
git commit -m "C4 Task 2: SubChartLayout.macdLines（DIF/DEA 折线，IndicatorMapper polylineSegments 重载）"
```

---

## Task 3: `SubChartLayout.macdBars` —— MACD 柱（基线钳制 + 正负柱）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/SubChartLayout.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/SubChartLayoutTests.swift`

- [ ] **Step 1: 写失败测试**

追加：

```swift
@Suite("SubChartLayout.macdBars")
struct SubChartLayoutMacdBarsTests {

    @Test("正柱：isPositive=true，柱顶在基线上方")
    func positiveBar() {
        let candles = [mc(0, macdBar: 20)]
        let m = makeMacdMapper(count: 1)
        // valueToY(0)=100, valueToY(20)= 200 - (20-(-50))/100*200 = 200 - 140 = 60
        let bars = SubChartLayout.macdBars(for: candles[0..<1], mapper: m)
        #expect(bars.count == 1)
        let b = bars[0]
        #expect(b.isPositive == true)
        #expect(b.rect.minX == -3 && b.rect.width == 6)
        #expect(b.rect.minY == 60)
        #expect(b.rect.height == 40)    // 100 - 60
    }

    @Test("负柱：isPositive=false，柱顶=基线，柱底=valueToY(macdBar) 下方")
    func negativeBar() {
        let candles = [mc(0, macdBar: -20)]
        let m = makeMacdMapper(count: 1)
        // valueToY(-20)= 200 - (-20-(-50))/100*200 = 200 - 60 = 140
        let b = SubChartLayout.macdBars(for: candles[0..<1], mapper: m)[0]
        #expect(b.isPositive == false)
        #expect(b.rect.minY == 100)    // 基线 valueToY(0)
        #expect(b.rect.height == 40)   // 140 - 100
    }

    @Test("零柱：macdBar==0，高度=1/displayScale（D8）+ 中心契约 D5（M1）")
    func zeroBar() {
        let b = SubChartLayout.macdBars(for: [mc(0, macdBar: 0)][0..<1], mapper: makeMacdMapper(count: 1))[0]
        #expect(b.isPositive == true)                      // >= 0 归正
        #expect(b.rect.minX == -3 && b.rect.width == 6)    // M1：D5 中心契约
        #expect(b.rect.height == 0.5)                       // 1 / scale(2)
    }

    @Test("nil 柱跳过（D9b）+ 留存柱 D5 中心契约（M1）")
    func nilBarSkipped() {
        let arr = [mc(0, macdBar: 10), mc(1), mc(2, macdBar: -5)]
        let bars = SubChartLayout.macdBars(for: arr[0..<3], mapper: makeMacdMapper(count: 3))
        #expect(bars.count == 2)                            // index 1 nil 被跳过（D9b）
        #expect(bars[0].rect.midX == 0 && bars[0].rect.width == 6)   // index 0 → cx=0
        #expect(bars[1].rect.midX == 20 && bars[1].rect.width == 6)  // index 2 → cx=20，跳过的是 input nil 不是输出对齐
    }

    @Test("D11 退化：valueRange 全正（不含 0）→ 基线钳到 frame.maxY；柱顶精确像素 = 111.0")
    func degenerateRangeAllPositive() {
        // valueRange 10...100：valueToY(0) raw = 200 - (0-10)/90*200 = 222.222.. (off-frame) → 钳到 frame.maxY=200。
        // macdBar=50：raw = 200 - (50-10)/90*200 = 200 - 88.888.. = 111.111..
        // round-to-device-pixel scale=2：(111.111 × 2).rounded() / 2 = 222 / 2 = 111.0（精确，非容差）
        let m = makeMacdMapper(count: 1, lower: 10, upper: 100)
        let b = SubChartLayout.macdBars(for: [mc(0, macdBar: 50)][0..<1], mapper: m)[0]
        #expect(b.rect.minX == -3 && b.rect.width == 6)    // D5 中心契约（M1 补）
        #expect(b.rect.minY == 111.0)                       // 精确像素（H2 收紧，错误实现给 baseline=100 会 fail）
        #expect(b.rect.maxY == 200)                         // 钳后基线在底
        #expect(b.rect.height == 89.0)                      // 200 - 111.0
        #expect(b.isPositive == true)
    }

    @Test("D6 杀手：slice arr[2..<5] + startIndex=2 → 首根 midX==0")
    func indexAlignment() {
        let arr = (0..<5).map { mc($0, macdBar: 10) }
        let m = makeMacdMapper(startIndex: 2, count: 3)
        let bars = SubChartLayout.macdBars(for: arr[2..<5], mapper: m)
        #expect(bars.count == 3)
        #expect(bars.map { $0.rect.midX } == [0, 10, 20])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter SubChartLayoutMacdBarsTests`
Expected: 编译失败 —— `SubChartLayout` 无 `macdBars`。

- [ ] **Step 3: 写最小实现**

在 `SubChartLayout` enum 内追加：

```swift
    /// MACD 柱基线（D11）：valueToY(0) 钳到 [frame.minY, frame.maxY]，
    /// 防御 macdRange 不含 0 的退化（C8 Wave 2 应避免，此处兜底不掩盖责任）。
    static func macdBarBaseline(mapper: IndicatorMapper) -> CGFloat {
        let raw = mapper.valueToY(0)
        return min(max(raw, mapper.frame.minY), mapper.frame.maxY)
    }

    /// MACD 柱（D1 读 candle.macdBar 不重算 / D9 nil 跳过 / D11 基线钳制 / D8 零柱最小高度）。
    static func macdBars(for candles: ArraySlice<KLineCandle>,
                         mapper: IndicatorMapper) -> [MacdBar] {
        let width = mapper.viewport.geometry.candleWidth
        let baseline = macdBarBaseline(mapper: mapper)
        let minBar = 1 / mapper.displayScale
        var bars: [MacdBar] = []
        bars.reserveCapacity(candles.count)
        for index in candles.indices {
            guard let value = candles[index].macdBar else { continue }   // D9
            let cx = mapper.indexToX(index)
            let top = mapper.valueToY(value)
            // 正柱：top < baseline；负柱：top > baseline；零柱：top == baseline
            let minY = min(baseline, top)
            let maxY = max(baseline, top)
            let height = max(maxY - minY, minBar)
            let rect = CGRect(x: cx - width / 2, y: minY, width: width, height: height)
            bars.append(MacdBar(rect: rect, isPositive: value >= 0))
        }
        return bars
    }
```

- [ ] **Step 4: 跑测试确认通过 + 全 host 套件回归**

Run: `cd ios/Contracts && swift test --filter SubChartLayoutMacdBarsTests`
Expected: PASS（6 tests：正/负/零/nil/退化/索引契约）。

Run: `cd ios/Contracts && swift test`
Expected: 全 package PASS，0 失败（451 基线 + 15 新 = **466**；含 volumeBars 5 + macdLines 4 + macdBars 6）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/SubChartLayout.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/SubChartLayoutTests.swift
git commit -m "C4 Task 3: SubChartLayout.macdBars（正负柱 + 基线钳制 + 零柱最小高度）"
```

---

## Task 4: `drawVolume` UIKit 薄层

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift`

> 说明：UIKit 代码在 host `swift build` 被 `#if canImport(UIKit)` 排除，无法 host 编译验证；本任务的编译验证统一在 **Task 6 Catalyst build**。本任务只写正确实现。

- [ ] **Step 1: 实现 `drawVolume`**

替换 `KLineView+Volume.swift` 的方法体（保留文件头注释 + `#if canImport(UIKit)` 守卫）：

```swift
// Kline Trainer Swift Contracts — C4 成交量副图渲染 extension（Wave 1 真实现）
// Spec: kline_trainer_modules_v1.4.md §C4（Volume + MACD，使用 IndicatorMapper）
// 几何来自 SubChartLayout（平台无关，host 已测）；本文件仅 UIKit 描边/填充薄层。
// §15.1 #3 编译验证：本文件方法签名与 KLineView.draw(_:) 派发点逐字匹配。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C4 成交量柱：柱矩形（涨/跌色填充，与主图蜡烛同步 D7）。
    /// 几何来自 SubChartLayout.volumeBars（host 已测）；本方法仅 UIKit 填充。
    func drawVolume(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>) {
        guard !candles.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        for bar in SubChartLayout.volumeBars(for: candles, mapper: mapper) {
            let color = bar.isUp ? AppColor.candleUp : AppColor.candleDown
            color.setFill()
            ctx.fill(bar.rect)
        }
    }
}

#endif
```

- [ ] **Step 2: host build 仍绿（确认平台无关部分未破）**

Run: `cd ios/Contracts && swift build`
Expected: build 成功（此步**不**验证 UIKit 体，仅确认 host 编译面未破）。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift
git commit -m "C4 Task 4: drawVolume UIKit 薄层（volumeBars + AppColor 涨跌色）"
```

---

## Task 5: `drawMACD` UIKit 薄层（DIF/DEA 折线 + 柱）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift`

- [ ] **Step 1: 实现 `drawMACD`**

替换 `KLineView+MACD.swift` 的方法体：

```swift
// Kline Trainer Swift Contracts — C4 MACD 副图渲染 extension（Wave 1 真实现）
// Spec: kline_trainer_modules_v1.4.md §C4（DIF + DEA + MACD bar；spec v1.5 §2: DIF 白 / DEA 黄）
// 几何来自 SubChartLayout（平台无关，host 已测）；本文件仅 UIKit 描边/填充薄层。
// §15.1 #3 编译验证：本文件方法签名与 KLineView.draw(_:) 派发点逐字匹配。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C4 MACD：DIF（白）+ DEA（黄）折线（实线，D3）+ 柱（正红负绿，D11 基线钳制）。
    /// 颜色 token: AppColor.macdDIF / .macdDEA / .macdBarPositive / .macdBarNegative（D4，F2 已冻结）。
    func drawMACD(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>) {
        guard !candles.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 柱先画（在折线下方视觉层次）
        for bar in SubChartLayout.macdBars(for: candles, mapper: mapper) {
            let color = bar.isPositive ? AppColor.macdBarPositive : AppColor.macdBarNegative
            color.setFill()
            ctx.fill(bar.rect)
        }

        // DIF / DEA 折线（D3 实线 / D9 单点段跳过）
        let lines = SubChartLayout.macdLines(for: candles, mapper: mapper)
        ctx.setLineWidth(1 / mapper.displayScale)
        ctx.setLineJoin(.round)

        AppColor.macdDIF.setStroke()
        for segment in lines.dif where segment.count >= 2 {
            ctx.move(to: segment[0])
            for point in segment.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }

        AppColor.macdDEA.setStroke()
        for segment in lines.dea where segment.count >= 2 {
            ctx.move(to: segment[0])
            for point in segment.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }
    }
}

#endif
```

- [ ] **Step 2: host build 仍绿**

Run: `cd ios/Contracts && swift build`
Expected: build 成功。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift
git commit -m "C4 Task 5: drawMACD UIKit 薄层（DIF白+DEA黄+柱正红负绿）"
```

---

## Task 6: Catalyst 编译闸门 + 验收脚本 + 非程序员验收清单

**Files:**
- Create: `scripts/acceptance/plan_c4_volume_macd.sh`
- Create: `docs/acceptance/2026-05-26-pr-c4-volume-macd.md`

- [ ] **Step 1: Mac Catalyst build-for-testing（验证两个 UIKit draw 方法编译 + 无 warning）**

Run:
```bash
cd ios/Contracts && set -o pipefail && xcodebuild build-for-testing \
  -scheme KlineTrainerContracts \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/derived-c4 2>&1 | tee /tmp/c4-catalyst.log
```
Expected: 末尾 `** TEST BUILD SUCCEEDED **`，且 `grep -E "(^|[[:space:]])(error|warning):" /tmp/c4-catalyst.log` **无输出**（CI catalyst-build job 同款闸门）。

- [ ] **Step 2: 写验收脚本**

新建 `scripts/acceptance/plan_c4_volume_macd.sh`：

```bash
#!/usr/bin/env bash
# C4 Volume + MACD 机检验收。仓库根目录运行。
set -uo pipefail
FAIL=0
run() { echo "--- $1"; shift; if "$@"; then echo "OK"; else echo "FAIL"; FAIL=1; fi; }

SRC="ios/Contracts/Sources/KlineTrainerContracts/Render"
LAYOUT="$SRC/SubChartLayout.swift"
DRAW_VOL="$SRC/KLineView+Volume.swift"
DRAW_MACD="$SRC/KLineView+MACD.swift"

run "SubChartLayout.swift 存在" test -f "$LAYOUT"
run "SubChartLayoutTests.swift 存在" test -f "ios/Contracts/Tests/KlineTrainerContractsTests/Render/SubChartLayoutTests.swift"
# 匹配行首真实 import 语句，避免误伤注释 "本文件不 import UIKit"
run "布局文件平台无关（无真实 import UIKit 语句）" bash -c "! grep -qE '^import UIKit' '$LAYOUT'"
run "三布局函数存在" bash -c "grep -q 'func volumeBars' '$LAYOUT' && grep -q 'func macdLines' '$LAYOUT' && grep -q 'func macdBars' '$LAYOUT'"
run "D11：MACD 基线钳制函数存在" bash -c "grep -q 'func macdBarBaseline' '$LAYOUT'"
# D1 主门 = 正向断言 MACD 读预计算字段；负向 grep 仅 best-effort（同 C3 L3 教训）
run "D1（主门）：MACD 读预计算 macdDiff/macdDea/macdBar 字段（强 \$0. 引用 + 单词边界，M4 真收紧）" bash -c "grep -qE '\\\$0\\.macdDiff\\b' '$LAYOUT' && grep -qE '\\\$0\\.macdDea\\b' '$LAYOUT' && grep -qE '\\.macdBar\\b' '$LAYOUT'"
run "D1（best-effort）：无 'EMA/ema/window/滑窗' 重算关键词" bash -c "! grep -qiE 'EMA|ema|window|滑窗' '$LAYOUT'"
# M2 注：awk '^}' 命中位置 = swift extension 体的闭合 `}`（顶层无缩进；方法 `    }` 缩进 4 空格不命中）。
# 本断言依赖"该文件 extension 内只有 drawMACD 一个方法"——若未来追加同 extension 第二方法 awk 范围会扩大引入误检；本 PR 单方法 OK。
run "D3：DIF/DEA 实线（drawMACD 内无 setLineDash）" bash -c "! awk '/func drawMACD/,/^}/' '$DRAW_MACD' | grep -q 'setLineDash'"
run "D4 Volume：引用 F2 涨跌色 token，不硬编码 RGB" bash -c "grep -q 'AppColor.candleUp' '$DRAW_VOL' && grep -q 'AppColor.candleDown' '$DRAW_VOL'"
run "D4 MACD：引用 F2 macd token，不硬编码 RGB" bash -c "grep -q 'AppColor.macdDIF' '$DRAW_MACD' && grep -q 'AppColor.macdDEA' '$DRAW_MACD' && grep -q 'AppColor.macdBarPositive' '$DRAW_MACD' && grep -q 'AppColor.macdBarNegative' '$DRAW_MACD'"
run "saveGState/restoreGState 配对（结构存在性，非配对证明）：drawVolume" bash -c "awk '/func drawVolume/,/^}/' '$DRAW_VOL' | grep -q 'saveGState' && awk '/func drawVolume/,/^}/' '$DRAW_VOL' | grep -q 'restoreGState'"
run "saveGState/restoreGState 配对（结构存在性，非配对证明）：drawMACD" bash -c "awk '/func drawMACD/,/^}/' '$DRAW_MACD' | grep -q 'saveGState' && awk '/func drawMACD/,/^}/' '$DRAW_MACD' | grep -q 'restoreGState'"
run "M0.4 豁免：C4 不碰 AppError" bash -c "! grep -q 'AppError' '$LAYOUT' '$DRAW_VOL' '$DRAW_MACD'"
run "stub 字样清除：Volume" bash -c "! grep -qiE 'Wave 1 \\(C4\\): implement' '$DRAW_VOL'"
run "stub 字样清除：MACD" bash -c "! grep -qiE 'Wave 1 \\(C4\\): implement' '$DRAW_MACD'"
run "host swift test exit 0" bash -c "cd ios/Contracts && swift test"

if [ "$FAIL" -eq 0 ]; then echo "=== ALL C4 ACCEPTANCE CHECKS PASSED ==="; else echo "=== C4 ACCEPTANCE FAILED ==="; exit 1; fi
```

- [ ] **Step 2b: 跑验收脚本**

Run: `bash scripts/acceptance/plan_c4_volume_macd.sh`
Expected: 每行 `OK`，末行 `=== ALL C4 ACCEPTANCE CHECKS PASSED ===`。

- [ ] **Step 3: 写非程序员验收清单**

新建 `docs/acceptance/2026-05-26-pr-c4-volume-macd.md`：

```markdown
# 验收清单 — C4 副图渲染 Volume + MACD（Wave 1 顺位 10 / 第 12 个 PR）

> 给非程序员逐条核对。每条：照"动作"敲命令 → 比对"期望" → 在"通过"打 ✓/✗。命令在仓库根目录运行。
> 模块 C4 = 把 K 线副图的"成交量柱 + MACD（DIF/DEA 线 + 柱）"从空占位补成真画图代码。画图本身（描边/填充）由苹果编译器在 CI 验证；所有计算（柱矩形、折线坐标、基线钳制）在电脑上跑真测试。

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | 运行：`cd ios/Contracts && swift test --filter SubChartLayout` | 全部通过，0 失败（15 项：volume 5 + MACD 折线 4 + MACD 柱 6） | ☐ |
| 2 | 运行：`cd ios/Contracts && swift test` | 全 package 通过，0 失败（在既有 451 基础上增加 15 项 → 466） | ☐ |
| 3 | 运行：`bash scripts/acceptance/plan_c4_volume_macd.sh` | 每行 `OK`，末行 `=== ALL C4 ACCEPTANCE CHECKS PASSED ===` | ☐ |
| 4 | 在浏览器打开本 PR → 看底部 CI 检查 | `swift test on macos-15` 与 `Mac Catalyst build-for-testing on macos-15` 两项均 ✓ 绿 | ☐ |
| 5 | 运行：`grep -c 'Wave 1 (C4): implement' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | 两文件各输出 `0`（两个方法已从空占位 stub 变成真实现，"implement" 提示字样清除） | ☐ |
| 6 | 运行：`grep -n 'setLineDash' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | **无任何输出**（DIF/DEA 是实线，与 C3 BOLL 虚线不同） | ☐ |
| 7 | 运行：`grep -n 'AppColor.macdDIF\|AppColor.macdDEA\|AppColor.macdBarPositive\|AppColor.macdBarNegative' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | 4 项均命中（颜色取自 F2 token，未硬编码 RGB） | ☐ |
| 8 | 运行：`grep -n 'AppError' ios/Contracts/Sources/KlineTrainerContracts/Render/SubChartLayout.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | **无任何输出**（纯画图，不碰错误类型，M0.4 豁免） | ☐ |
| 9 | 运行：`git diff --name-only main...HEAD` | 改动 = SubChartLayout.swift（新）/ KLineView+Volume.swift（改）/ KLineView+MACD.swift（改）/ SubChartLayoutTests.swift（新）/ 验收脚本 / 本清单 / plan 文档（**无 migration / 无 .sql / 无 backend / 不改 MainChartLayout**） | ☐ |

**任一条 ✗ → 不得 merge。** 第 1/2/3/4 条是硬门（计算真测 + 画图真编译 + CI 双绿）。
```

- [ ] **Step 4: Commit**

```bash
git add scripts/acceptance/plan_c4_volume_macd.sh docs/acceptance/2026-05-26-pr-c4-volume-macd.md
git commit -m "C4 Task 6: Catalyst 闸门 + 验收脚本 + 非程序员验收清单"
```

---

## Self-Review（写完即查，发现即改）

**1. Spec coverage**
- §C4 `drawVolume(ctx:mapper:candles:)` → Task 1（volumeBars 几何）+ Task 4（UIKit 填充）✓
- §C4 `drawMACD(ctx:mapper:candles:)` → Task 2（macdLines 折线）+ Task 3（macdBars 柱）+ Task 5（UIKit 描边+填充）✓
- §C4 v1.2 注 "valueRange 来自 KLineRenderState.volumeRange/macdRange，C4 内部不再计算值域" → SubChartLayout 全部函数读 `mapper.valueRange`/`mapper.frame`，不重算 ✓
- plan v1.5 §一 v1.4 变更 #1 "DIF 白 + DEA 黄" → AppColor.macdDIF/macdDEA + D4 ✓
- §15.1 #3 Catalyst 编译闸门 → Task 6 Step 1 ✓
- D1 MACD 读预计算字段（与 C3 D1 镜像）→ 验收脚本主门 ✓
- M0.4：C4 不消费 AppError → 豁免，验收脚本 grep 断言 ✓

**2. Placeholder scan**：各 step 均含完整代码/命令/期望；无 TBD/TODO/"类似 Task N"。✓

**3. Type consistency**
- `volumeBars`/`macdLines`/`macdBars`/`macdBarBaseline` 命名在 Task 1-5 与测试/验收脚本一致；
- `VolumeBar`{rect, isUp}、`MacdBar`{rect, isPositive}、`MacdLines`{dif, dea} 字段在测试与实现一致；
- `AppColor.candleUp/candleDown/macdDIF/macdDEA/macdBarPositive/macdBarNegative` 与 Theme.swift L103-110 字面一致；
- `mapper.viewport.geometry.candleWidth` / `mapper.displayScale` / `mapper.frame` / `indexToX` / `valueToY` 与 Geometry.swift IndicatorMapper L172-199 一致；
- `candle.volume: Int64` / `candle.macdDiff/macdDea/macdBar: Double?` 与 Models.swift L63/L69-71 一致；测试中 `Double(c.volume)` 显式转。✓

**4. 已知 residual（交评审/用户）**
- **R1**：D11 退化兜底（macdRange 不含 0 时基线钳制）属防御性；C8 Wave 2 落地时应加 contract 测试保证 `macdRange.lower ≤ 0 ≤ macdRange.upper`，C4 本 PR 不强制此契约（钳制不掩盖 C8 责任，仅做兜底）。
- **R2**（L3 修订）：D10 volume 基线选 frame.maxY 而非 valueToY(0)：等价于"标准成交量锚定到 valueRange.lower 而非绝对 0"。理论 edge case：`NonDegenerateRange.make(values: [0])` 走 single-value padding 路径 → `lower = -1e-6`（paddingRatio 微小负偏移）；此时 baseline=frame.maxY 而非 valueToY(-1e-6)，差约 0.0002 像素，被 round-to-device-pixel 完全吸收，**实际无害**。volume 不可能负，C8 不会构造 lower 远小于 0 的 range；本 PR 不强制此契约（C8 Wave 2 可加 contract 测试）。
- **R3**：单点折线段（内部 gap 防御产物）draw 层跳过 <2 点段——B1 契约下不应出现内部 gap，属防御冗余（与 C3 同款）。

---

## Plan-stage 对抗性评审收敛记录（Opus 4.7 xhigh，待跑）

> Round 1 待跑。预期模式（参考 C3 PR #66 经验）：
> - Round 1 给 0-2 Critical / 1-3 High / 若干 Low+观察
> - 修订后 Round 2 收敛 APPROVE 或追加一轮
> - 若 4-5 轮不收敛 → escalate user（memory `feedback_codex_plan_budget_overshoot`）

### Round 1（已跑）verdict = **NEEDS-ATTENTION**（0 Critical / 2 High / 3 Medium / 3 Low；数学复核全对）

| Finding | 处理 |
|---|---|
| **H1** 测试用 `NonDegenerateRange.init(lower:upper:)` 走 `@testable` 提权访问 implicit-internal init（脆弱依赖）| 新增 **D12 裁决**：本 PR 显式记录此依赖 + 现有 GeometryTests 走同款 `@testable` 通道；若未来 Geometry 收紧为 explicit `private init` 则测试需迁移到 `.make + 容差`。implicit internal 已稳定数月，YAGNI 不预修。|
| **H2** `degenerateRangeAllPositive` 容差 `> 100 && < 120` 过宽 | 收紧到精确 `b.rect.minY == 111.0`（手算 valueToY(50) round-to-device-pixel = 111.0）+ 加 minX/width 断言 + 加 height==89.0 断言 |
| **M1** 三 bar 测试 zeroBar/zeroVolumeMinHeight/baselineFromLowerNotZero/nilBarSkipped 漏断 minX/width | 每个补 `b.rect.minX == -3 && b.rect.width == 6` 或 midX==X 断言（D5 中心契约杀手覆盖） |
| **M2** `awk '^}'` 验收脚本依赖"文件单方法"假设 | 加注释明确该假设；本 PR 单方法 OK |
| **M3** D9 折线 vs 柱 nil 口径混在一条 | 拆 D9a（折线 segment+断段+<2 skip）/ D9b（柱 nil 跳过该根） |
| **L3** R2 "lower < 0 不可能发生" 措辞略夸 | 改 "实际无害（padding 微小 + round 吸收）"；保留 C8 责任口径 |
| **M2/D1 grep 收紧** | 验收脚本 `grep -q 'macdBar'` 收紧为 `'.macdBar'` 减少误命中函数名 `macdBars()` |
| L1/L2（观察项）| L1 C3 行号锚 OK 接受；L2 Task 4 commit 中间 stub 状态符合 TDD 增量，OK 接受 |

Round 2 目标：复核 H1/H2/M1/M2/M3/L3 修订落地 + 无新 finding → APPROVE。

### Round 2（已跑）verdict = **NEEDS-ATTENTION**（仅 1 个 M4-new）→ **修后 APPROVE**

| Finding | 处理 |
|---|---|
| R1 H1/H2/M1/M2/M3/L3 七项修订核对 | 全部字面落地 + 数学复核精确（valueToY(50)=111.0、height=89.0 二进制可表示无 FP 漂移）+ M1 杀手有效（`cx - width/2` → `cx` 误改 minX=0 必 fail） |
| **M4-new** `.macdBar` grep 中 `.` 是 regex 任意字符仍误命中 `macdBars()/macdBarPositive/macdBarBaseline` | 改 `grep -qE '\.macdBar\b'`（转义 `.` + 单词边界 `\b`，BSD grep ERE 支持）；同步 macdDiff/macdDea 收紧成 `\$0\.macdDiff\b` / `\$0\.macdDea\b` 模式 |

### Round 3 verdict = **APPROVE**（M4-new 修订落地 → 进 Task 1 实施）

---

## Execution Handoff

本 plan 用户已显式指定执行路径：**Subagent-Driven（superpowers:subagent-driven-development）**——每 Task 派新 subagent（Sonnet 4.6 high effort，per `feedback_subagent_model_selection`）+ 两阶段 review；plan-stage 先过 **Claude Opus 4.7 xhigh 对抗性评审收敛**，impl 完后过 **verification-before-completion** + **requesting-code-review** + 再过一轮整体 **Opus 4.7 xhigh 对抗性评审收敛**，最后 push + admin merge ceremony。
