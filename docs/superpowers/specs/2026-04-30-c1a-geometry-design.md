# C1a Geometry — Implementation Design

> **Status**：approved 2026-04-30，两轮 Opus 4.7 xhigh adversarial review 收敛（R1→R2 ACCEPT；R3→R4→R5 ACCEPT，confidence 95% high）。
>
> **起因**：Wave 0 业务模块第二锚（E1 TickEngine merged 2026-04-30 后续）。C1a 解锁 C1b Reducer + C1c RenderState 整条图表 pipeline，零 upstream dep，纯值类型 + 几何数学，codex 风险面比 P1 APIClient 小一个数量级。

## Goal

落地 modules §C1a + plan §3 的 7 个值类型——图表渲染的几何 / 视口 / 坐标映射底盘，UIKit-free 纯值类型。

## Architecture

C1a 是 SwiftPM `KlineTrainerContracts` package 内的 standalone 值类型 bundle，无外部依赖（除 Foundation + CoreGraphics + 同 package 的 `KLineCandle`），无 trust-boundary，无 mutation invariant，仅由 C1b/C1c/C8 等下游持有。

**关键结构决策（α）**：C1a + C1b + C1c-values 共住 `ios/Contracts/Sources/KlineTrainerContracts/` 同一 SwiftPM package。详见 §"Package 结构 pre-commit clause"。

## Tech Stack

- Swift 6（toolchain 6.3.1）
- Swift Testing macros（`@Test` / `@Suite` / `#expect`）
- SwiftPM intra-package value type
- `import Foundation` + `import CoreGraphics`（Contracts 当前 0 CG 引用，C1a 引入新精度面，显式声明）
- iOS 17+ / macOS 14+（Package.swift 既有 platform 范围）
- CGFloat / CGRect Sendable via Swift 6 retroactive conformance（compile 验证通过）

## Spec snapshot（grep-verified）

**modules §C1a**（kline_trainer_modules_v1.4.md L854-955）—— **frozen baseline，权威**：见 §"Implementation"。
**plan §3**（kline_trainer_plan_v1.5.md L100-200）—— body implementation guide。

### Spec discrepancies（5 项，modules 优先）

| # | Aspect | modules §C1a | plan §3 | Resolution |
|---|---|---|---|---|
| D-1 | `PriceRange.calculate` body | 仅声明 L890-893 | 完整 body L142-161（`lo *= 0.95; hi *= 1.05` + BOLL/MA66 inclusion） | 照抄 plan body 字面（modules 仅声明，plan 提供 impl guide） |
| D-2 | `ChartViewport` 描述漂移 | 无叙述 | plan L111 narrative 写"（计算属性）"，但 plan struct L127-134 实际 6 字段 stored，与 modules struct L895-902 完全一致 | 非阻塞；仅 plan inline 注释 bug，struct 本身一致 |
| D-3 | `CoordinateMapper.displayScale` 字段 | 显式 `let displayScale: CGFloat` L910 | struct L168-196 漏字段，但 L174/L183 引用（不可编译） | 用 modules：显式字段 |
| D-4 | Equatable / Sendable conformance | 全 7 类显式 `: Equatable, Sendable`（L879/L883/L890/L895/L908/L919/L945） | 仅 PriceRange `: Equatable` L142；其它 bare struct；Sendable 全无 | 全 7 类 `: Equatable, Sendable` |
| D-5 | 覆盖 gap | 全 7 类型 | 仅 4/7（缺 ChartPanelFrames / NonDegenerateRange / IndicatorMapper） | 这 3 类 modules 是唯一权威 — ~43% surface modules-only |

**冲突解决原则**：以 **modules §C1a 为准**（per memory `project_modules_v1.4_frozen`，35 模块 4 轮 codex review 冻结 baseline）。impl 一字不差对应 modules declaration + plan body（仅 D-1 取 plan body 因 modules 不提供）。

### Package 结构 pre-commit clause

C1a 在 `ios/Contracts/Sources/KlineTrainerContracts/Geometry/` 同时 pre-commit Contracts 同 package 容纳：
- **C1b** 全 bundle（modules §C1b L957-1135 全值类型，UIKit-free，已独立 grep 验证）
- **C1c-values 子集** —— `KLineRenderState` 值类型（modules §C1c）

UIKit-bearing siblings 落 **iOS Xcode app target**：
- `KLineView` —— `final class KLineView: UIView`（modules L1179），与 `KLineView+Candles / +MACD / +Volume / +Crosshair / +Markers` extensions 同住
- C2 `DecelerationAnimator`（modules L1245 起）
- C7 `ChartGestureArbiter`（modules L1389 `attach(to view: UIView)`）
- C8 `ChartContainerView: UIViewRepresentable`（modules L1404）

**C1c 跨 2 package 拆分**是结构事实，不是 drift —— 把值类型推 Contracts，UIView 推 app target，符合 Contracts package 不依赖 UIKit 的硬约束。

**已知 spec drift**：modules L848 + L854 写 C1a 路径为 `ChartEngine/Core/Geometry/`（暗示 iOS app 内）。本设计 deviate 至 Contracts package，理由：
- E1 precedent（PR #37 merged）：TickEngine 同样不在 spec literal `ViewModels/` path，而在 Contracts
- iOS Xcode app 当前 0 test target（`xcodebuild -list` 验证：仅 `KlineTrainer` app target），新建 test target 是 heavy infra scope creep
- Contracts 已 host KLineCandle，PriceRange.calculate 直接消费同 package 类型最干净

设为 **deferred reconciliation**：iOS app 增 test target 时再评估 migrate。

## Scope

**Sub-task 1（单 PR / 单 sub-item）**：C1a 7 类型 + tests
- 文件 1：`ios/Contracts/Sources/KlineTrainerContracts/Geometry/Geometry.swift`（或拆 7 个文件视实现时清晰度，prod ≤200 LOC 含 public boilerplate）
- 文件 2：`ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift`（~30 tests，~230 LOC 含 blank separator）

**子项总数 1**（≤3 硬上限）；**prod 估 ~187 LOC**（≤500 硬上限留余裕）。

**测试数 30 > memory `feedback_big_pr_codex_noncovergence` ≤10 警戒**：7 类型 bundle 故意超；用 6 residuals 抢答 + spec citation 表 + 每个数字边缘的 characterization test 兜底。目标 ≤3 codex 轮（vs E1 2 轮）。

## 不在范围

- ❌ C1b reducer / PanelViewState / FrozenPanelState / ChartAction / DrawingSnapshot（独立 anchor）
- ❌ C1c KLineRenderState / KLineView / 任何 UIKit 类（独立 anchor，C1c 跨 package 拆分）
- ❌ C2 DecelerationAnimator / C7 ChartGestureArbiter / C8 ChartContainerView
- ❌ M0.3 矩阵 bump（C1a 在 §六业务模块，不在 §M0.3 契约值类型 scope）
- ❌ spec / m01 / §M0.x 任何修订（D-2 narrative 漂移留 plan v1.6 单独修，不在 C1a scope）
- ❌ Codable conformance（spec 不要求；C1a 类型不持久化）
- ❌ 性能 benchmark / Equatable hot-path 测量（modules L1451 在 C8 验收，不在 C1a v1）
- ❌ 12 项 residuals 的 caller-side 防御（spec gap，归 caller / E5 / 训练数据源责任，详见 §"Residuals"）

## Implementation

```swift
// Kline Trainer Swift Contracts — C1a Geometry
// Spec: kline_trainer_modules_v1.4.md §C1a + kline_trainer_plan_v1.5.md §3

import Foundation
import CoreGraphics

// MARK: - 几何 + 视口

public struct ChartGeometry: Equatable, Sendable {
    public let candleStep: CGFloat
    public let candleWidth: CGFloat
    public let gap: CGFloat

    public init(candleStep: CGFloat, candleWidth: CGFloat, gap: CGFloat) {
        self.candleStep = candleStep
        self.candleWidth = candleWidth
        self.gap = gap
    }
}

public struct ChartPanelFrames: Equatable, Sendable {
    public let mainChart: CGRect       // 60%
    public let volumeChart: CGRect     // 15%
    public let macdChart: CGRect       // 25%

    public init(mainChart: CGRect, volumeChart: CGRect, macdChart: CGRect) {
        self.mainChart = mainChart
        self.volumeChart = volumeChart
        self.macdChart = macdChart
    }

    /// 60/15/25 纵向堆叠（modules L884-886）
    public static func split(in rect: CGRect) -> ChartPanelFrames {
        let mainH = rect.height * 0.60
        let volH = rect.height * 0.15
        let macdH = rect.height * 0.25
        let main = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: mainH)
        let vol = CGRect(x: rect.minX, y: rect.minY + mainH, width: rect.width, height: volH)
        let macd = CGRect(x: rect.minX, y: rect.minY + mainH + volH, width: rect.width, height: macdH)
        return ChartPanelFrames(mainChart: main, volumeChart: vol, macdChart: macd)
    }
}

public struct PriceRange: Equatable, Sendable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    /// plan §3 L142-161 字面：含 BOLL / MA66 + 5% 上下扩展
    public static func calculate(from candles: ArraySlice<KLineCandle>) -> PriceRange {
        guard !candles.isEmpty else { return PriceRange(min: 0, max: 1) }
        var lo = candles.map(\.low).min()!
        var hi = candles.map(\.high).max()!
        for c in candles {
            if let bu = c.bollUpper { hi = Swift.max(hi, bu) }
            if let bl = c.bollLower { lo = Swift.min(lo, bl) }
            if let ma = c.ma66 { hi = Swift.max(hi, ma); lo = Swift.min(lo, ma) }
        }
        lo *= 0.95
        hi *= 1.05
        return PriceRange(min: lo, max: hi)
    }
}

public struct ChartViewport: Equatable, Sendable {
    public let startIndex: Int
    public let visibleCount: Int
    public let pixelShift: CGFloat
    public let geometry: ChartGeometry
    public let priceRange: PriceRange
    public let mainChartFrame: CGRect

    public init(startIndex: Int, visibleCount: Int, pixelShift: CGFloat,
                geometry: ChartGeometry, priceRange: PriceRange, mainChartFrame: CGRect) {
        self.startIndex = startIndex
        self.visibleCount = visibleCount
        self.pixelShift = pixelShift
        self.geometry = geometry
        self.priceRange = priceRange
        self.mainChartFrame = mainChartFrame
    }
}

// MARK: - 坐标映射

public struct CoordinateMapper: Equatable, Sendable {
    public let viewport: ChartViewport
    public let displayScale: CGFloat

    public init(viewport: ChartViewport, displayScale: CGFloat) {
        self.viewport = viewport
        self.displayScale = displayScale
    }

    public func indexToX(_ index: Int) -> CGFloat {
        let raw = CGFloat(index - viewport.startIndex) * viewport.geometry.candleStep
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }

    public func priceToY(_ price: Double) -> CGFloat {
        let frame = viewport.mainChartFrame
        let span = viewport.priceRange.max - viewport.priceRange.min
        let ratio = (price - viewport.priceRange.min) / span
        let raw = frame.maxY - CGFloat(ratio) * frame.height
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }

    public func xToIndex(_ x: CGFloat) -> Int {
        viewport.startIndex + Int((x / viewport.geometry.candleStep).rounded(.down))
    }

    public func yToPrice(_ y: CGFloat) -> Double {
        let frame = viewport.mainChartFrame
        let ratio = Double((frame.maxY - y) / frame.height)
        return viewport.priceRange.min + ratio * (viewport.priceRange.max - viewport.priceRange.min)
    }
}

public struct NonDegenerateRange: Equatable, Sendable {
    public let lower: Double
    public let upper: Double                   // 强制 upper > lower（无 public init，外部只能走 .make）

    // memberwise init 不显式声明 → Swift 合成 internal init；外部只能 .make
    // 同 package test 可直接 internal init 验证 Equatable / span / 边界

    /// modules L924-925 字面：empty / 全等值都返回可用 range
    public static func make(values: [Double],
                            fallback: ClosedRange<Double> = 0.0...1.0,
                            paddingRatio: Double = 0.02) -> NonDegenerateRange {
        guard let minV = values.min(), let maxV = values.max() else {
            return NonDegenerateRange(lower: fallback.lowerBound, upper: fallback.upperBound)
        }
        if minV == maxV {
            let pad = Swift.max(abs(minV) * paddingRatio, 1e-6)
            return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
        }
        let span = maxV - minV
        let pad = span * paddingRatio
        return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
    }

    public var span: Double { upper - lower }
}

public struct IndicatorMapper: Equatable, Sendable {
    public let frame: CGRect
    public let valueRange: NonDegenerateRange
    public let geometry: ChartGeometry
    public let viewport: ChartViewport
    public let displayScale: CGFloat

    public init(frame: CGRect, valueRange: NonDegenerateRange,
                geometry: ChartGeometry, viewport: ChartViewport, displayScale: CGFloat) {
        self.frame = frame
        self.valueRange = valueRange
        self.geometry = geometry
        self.viewport = viewport
        self.displayScale = displayScale
    }

    public func indexToX(_ index: Int) -> CGFloat {
        let raw = CGFloat(index - viewport.startIndex) * geometry.candleStep
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }

    public func valueToY(_ value: Double) -> CGFloat {
        let ratio = (value - valueRange.lower) / valueRange.span    // span > 0 by .make 构造保证
        let raw = frame.maxY - CGFloat(ratio) * frame.height
        return (raw * displayScale).rounded(.toNearestOrAwayFromZero) / displayScale
    }
}
```

**Notes**：
- 全 `public` 暴露符合 SwiftPM package 跨模块使用约定（与 E1 / Models.swift 一致）
- **NonDegenerateRange 例外**：无 public init，外部只能走 `.make`（modules L921 注释"强制 upper > lower"的最 minimal 实现 = init 不公开；不加 `precondition` 避免触发 governance budget cap 防御 bias）
- `import Foundation` 提供 `abs` / `Swift.min/max`；`import CoreGraphics` 显式声明 CGFloat / CGRect 来源
- sub-pixel 对齐：`(raw * scale).rounded(.toNearestOrAwayFromZero) / scale` —— 显式选 `.toNearestOrAwayFromZero` 与 plan §3 L172-184 `Foundation.round()` C99 语义严格对齐（注意：`.rounded()` 默认 `.toNearestOrEven` banker's rounding 在 .5 边界与 spec 不一致，故必须显式 rounding rule）
- `xToIndex` 用 `(x / step).rounded(.down)` 等价于 `floor`，避免显式 `Foundation.floor` 依赖

## 测试矩阵（35 tests，1+3+7+3+6+10+5）

| 类型 | tests | 关键验证 |
|---|---|---|
| ChartGeometry | 1 | 自动合成 init + Equatable |
| ChartPanelFrames | 3 | split 60/15/25 比例 / 0-rect edge / 非零 origin |
| PriceRange | 7 | empty → (0,1) ; 普通 candles ; 含 BOLL ; 含 MA66 ; **三指标全有 + 同时扩 lo/hi**（reviewer test-1）; 5% pad 精确值 ; 单根 candle |
| ChartViewport | 3 | init / Equatable / 跨 frame Equatable 区分 |
| NonDegenerateRange | 6 | empty → fallback ; 全等值 → 对称 pad ; 普通 → span pad ; non-default paddingRatio ; non-default fallback ; **每分支 span > 0 显式断言**（reviewer test-4） |
| CoordinateMapper | 10 | indexToX 起点 / indexToX 偏移 ; priceToY 上下边界 ; xToIndex floor 行为 ; yToPrice 反向 ; sub-pixel scale=1/2/3 ; **.5-边界 .toNearestOrAwayFromZero 抢答 banker's-rounding drift**（reviewer test-3 / drift-1）; **退化 PriceRange(min==max) → NaN**（residual #10 R1 抢答）|
| IndicatorMapper | 5 | **indexToX(i) === CoordinateMapper.indexToX(i) 显式相等**（reviewer test-2）; valueToY 上下边界 ; sub-pixel ; valueRange.span > 0 不除零 |

## Open Questions / Residuals（不在 C1a v1 scope，6 项 + char tests 抢答 codex）

1. **PriceRange 5% padding magic number 不参数化**：plan §3 L157-158 字面 `lo *= 0.95; hi *= 1.05` 写死。**归 plan 字面 fidelity**；改成可配置 = spec drift。char test：padded range 与 `lo*0.95` / `hi*1.05` 精确匹配。

2. **NonDegenerateRange 默认 paddingRatio=0.02 / fallback=0.0...1.0**：modules L924-925 字面默认值。char tests：empty values → fallback ；non-default paddingRatio honored。

3. **CoordinateMapper sub-pixel `displayScale` 由 caller 注入**：C1a 不 import UIKit，无法读 `UIView.traitCollection.displayScale`。caller（iOS app 内 KLineView）负责取 + 传入。char test：相同 raw 在 scale=2 / scale=3 产生不同 rounded 值。

4. **`xToIndex` Int 转换不防 overflow**：spec L188 字面 `Int(floor(x / candleStep))`。极端 x 可能溢出 Int.max trap。**归 caller side**：UI 层 x 坐标自然有屏宽 bound，业务上不可能 > Int.max。char test：典型 bounded x → expected index。

5. **PriceRange.calculate 假定正价**：`lo *= 0.95` 在 `lo ≤ 0` 时反向收缩而非扩展。**归训练数据源 / E5 caller**：A 股股价天然 > 0。char test：正价输入 → expected pad ; design doc note 显式声明 caller 保正。

6. **空 candles → `PriceRange(min: 0, max: 1)`**：plan §3 L148 字面 fallback。char test：empty ArraySlice → exact (0, 1)。

7. **`displayScale > 0` 由 caller 保证**（final-reviewer predicted-4 抢答）：所有 sub-pixel 算式 `... / displayScale` 用 displayScale 作除数。`scale = 0` → inf / NaN 传播；`scale < 0` → mirror coords。`UIView.traitCollection.displayScale` 在 iOS / macOS 真机上恒 ≥ 1（UIKit 平台保证），simulator 偶尔 1/2/3。caller（KLineView）传入 `traitCollection.displayScale` 即可，不需 C1a 自校。**归 caller side**；不加 `precondition` 避免触发 governance budget cap 防御 bias。

8. **`IndicatorMapper` 同时持 `viewport: ChartViewport` + `geometry: ChartGeometry` 是 spec-mandated 重复**（final-reviewer predicted-5 抢答）：modules L945-955 字面声明两字段并存。impl 取 `geometry.candleStep` 而非 `viewport.geometry.candleStep`，所以 caller 传不一致 geometry 时 indexToX 用 IndicatorMapper.geometry。**归 caller convention**：caller 应保 `indMap.geometry === viewport.geometry`（C8 ChartContainerView 构造时同源）；C1a 不强制一致性。spec L945-955 是硬证据，不重构 impl。

9. **`NonDegenerateRange.span > 0` 仅 `.make` 路径保证**（final-reviewer predicted-6 抢答）：`NonDegenerateRange` 无 public init，外部消费者只能 `.make`，所有 3 分支 post-condition `lower < upper`。但同 package 内（含 tests + 未来 Contracts 内部代码）可走 internal memberwise init 直接传 `lower==upper`。`IndicatorMapper.valueToY` 注释"span > 0 by .make 构造保证"是对**外部 caller path** 的契约声明，不是同包内强制不变量。同包内若构造退化值，行为为 NaN/inf 传播 — 归同包 dev 责任，不加 `assert`。

10. **`PriceRange(min:max:)` public init 不强制 `min < max`**（R1 adversarial-reviewer I-1 抢答）：`PriceRange.calculate` 路径在 `lo *= 0.95; hi *= 1.05` 后天然 `max > min`（正价输入下），不退化。但 caller 直接走 public init 传 `min == max` 或 `min > max` 时，`priceToY` 算 `(price - min) / (max - min)` → 0/0 = NaN 或负 ratio，最终输出 NaN/inf。**归 caller side**；A 股股价场景下 caller 只走 `.calculate` 不直接 init。char test：`PriceRange(min: 100, max: 100)` 的 `priceToY` 显式断言 NaN（document behavior，不是 invariant 强制）。

11. **`ChartGeometry.candleStep == 0` 传 `xToIndex` 触发 runtime trap**（R1 adversarial-reviewer I-2 抢答）：`(x / 0).rounded(.down) = +inf`，`Int(+inf)` 在 Swift trap (EXC_BAD_INSTRUCTION)。Residual #4 仅覆盖 Int.max overflow，不覆盖 division-by-zero。**归 caller side**：`ChartGeometry.candleStep` 必须 > 0 by C8 caller convention；UI 层不会传 0（K 线 candle 间距至少 1px）。不加 `precondition` 避免 governance budget cap 防御 bias。

12. **`frame.height == 0` 产生 NaN 传播**（R1 adversarial-reviewer I-3 抢答）：`priceToY` / `yToPrice` / `valueToY` 算 `... / frame.height` 用 frame.height 作除数。`ChartPanelFrames.split(in: 0-高 rect)` 已 char-test 产生 `mainChart.height == 0`，但 mapper 输出未 char-test。caller 责任：`ChartContainerView` `bounds` 在 attach 后非零；UI 层 layout 阶段才构造 mapper。归 caller convention，不防御。

13. **~~`ChartViewport.pixelShift` 不进 mapper~~ → R2 实施进 mapper**（codex R2 finding #1 收敛）：codex R1+R2 两轮强 push pixelShift 应在 mapper 内应用以保证 X mapping 与 hit-testing 对称（layer-transform-only 模式要求 caller 在 xToIndex 前减去 pixelShift = 认知负担 + 易错）。R2 接受：`indexToX = (i-startIndex)*step + pixelShift`；`xToIndex = startIndex + floor((x - pixelShift)/step)`。pixelShift 符号契约：> 0 = candles 右移。spec 字面（modules L908-916 仅签名；plan §3 L172-189 base case mapper body）没禁止 pixelShift 进 mapper，只是没显式写。pixelShift 作为 ChartViewport 字段存在 = 设计意图明确指向"被 mapper 消费"。+3 char tests（pixelShiftAppliedToIndexToX / pixelShiftRoundTrip / pixelShiftNegative）。

十二项 + 1 项 R2 实施 = **十三项处理记录**（原 12 项 residuals + 1 项 R2 实施收敛）。

**codex R1 finding #2 fix（NonDegenerateRange.make 退化 fallback）**：modules L924 字面"返回可用的 range" = 非退化合约。原 impl `fallback: 0...0` → `lower=0, upper=0` span=0 违约。R2 修复：empty values 路径检查 fallback 是否退化（`lo == hi`），退化则走 single-value padding 路径（与 `values=[0.0]` 走的同一支），保 span > 0 不变量。新 char tests `emptyValuesDegenerateFallback`（fallback 0...0）+ `emptyValuesDegenerateNonZeroFallback`（fallback 5...5）。

**codex R2 finding #2 (PriceRange public init NaN) push back**：codex R2 重述 residual #10。spec 字面 modules L890-893：`struct PriceRange { let min, max: Double; static func calculate(...) -> PriceRange }` — public memberwise init by Swift auto-synth；spec 不要求 init 验证。`.calculate` 路径正价输入下天然 max > min 不退化。caller 直接 init 是 caller-side path（residual #10 char-tested）。memory `feedback_governance_budget_cap` 不主动加 precondition；E5/E1 caller 注入路径只走 `.calculate`。**保留 residual #10 不改**。

**codex R2 finding #3 (ChartGeometry.candleStep zero) push back**：codex R2 重述 residual #11。spec 字面 modules L879-881：`struct ChartGeometry { let candleStep, candleWidth, gap: CGFloat }` — public memberwise init；spec 不要求验证。UI 层 candle 间距业务上 ≥ 1px。memory `feedback_governance_budget_cap` 不主动加 precondition；C8 caller 通过 ChartContainerView geometry 计算路径保正。**保留 residual #11 不改**。

**codex R3 finding #1 fix（fractional pixelShift round-trip）**：R2 实施 `xToIndex = startIndex + floor((x - pixelShift)/step)` 在 fractional pixelShift 下破对称。codex R3 case：pixelShift=0.4 step=8 displayScale=1：indexToX(5)=round(40.4)=40；xToIndex(40)=floor(39.6/8)=4 ❌ 应 5。**根因**：indexToX 把 (i*step+pixelShift) round 到 display grid 但 xToIndex 减的是未 round 的 pixelShift，sub-pixel 漂移堆叠破 floor 边界。**R3 修复**：`alignedShift = round(pixelShift * displayScale) / displayScale`，再 `xToIndex = startIndex + floor((x - alignedShift)/step)`。pixelShift=0 时 alignedShift=0 与 spec 字面 `floor(x/step)` 完全等价（保 7.9→0 / 8→1 spec 行为）；fractional pixelShift 下保 round-trip。+3 char tests（fractionalPixelShiftRoundTripScale1 / fractionalPixelShiftRoundTripScale2 / nearHalfPixelShiftRoundTrip）。

## Codex review 策略

- **预期 round 数**：≤3 轮（34 tests > E1 的 15，超 memory ≤10 警戒，故 +1 round contingency）
- **关键预防**：
  - 12 residuals codify + 关键项 char test → 抢先回答 codex 可能的 push（"为啥不防 overflow / div-by-zero / NaN 传播" / "为啥不参数化 0.95" / "displayScale 为啥不验证" / "geometry 为啥重复" / "span > 0 同包能破" / "PriceRange.init 为啥不验证 min<max" / "candleStep=0 触发 trap" 等）
  - spec citation 表 5 项 discrepancy + line 编号 → 抢先回答 "spec 不一致" 类 push
  - impl 一字不差对应 spec body → 不给 codex "spec drift" attack surface
  - C1c 跨 package 拆分 + α placement deferred reconciliation 显式声明 → 抢先回答 "modules 路径漂移" 类 push
- **超 3 轮立即 abort**（per memory `feedback_big_pr_codex_noncovergence` 硬规则）
- **若 codex push throws / overflow guard / `precondition`**：spec 字面是硬证据 + memory `feedback_governance_budget_cap` 不主动加防御，1 轮 inline 反驳 + accept residual

## Rollout

```
T0  worktree 设置：git worktree add .worktrees/c1a-geometry -b c1a-geometry main
T1  impl + tests（subagent-driven-development，1 task）
T2  verification-before-completion（swift test all pass / 0 warnings）
T3  requesting-code-review（superpowers code-reviewer subagent，sonnet 4.6 high）
T4  user explicit confirm → push branch + open PR
T5  codex adversarial review（≤3 轮 / 超 3 abort）
T6  CODEOWNERS approve（单人项目 = user self-approve）
T7  merge
```

## 8 行非 coder 验收清单（CLAUDE.md backstop §2）

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | `cd .worktrees/c1a-geometry && swift test 2>&1 \| tail -5` | 退出码 0；末行 `Test Suite 'All tests' passed`；新增 43 C1a tests（含 codex R1 修复 +3 + R2 +3 -1 flip + R3 fractional pixelShift +3 = 净 +8），全部 baseline tests 仍通过；0 warnings | ☐ |
| 2 | `wc -l ios/Contracts/Sources/KlineTrainerContracts/Geometry/*.swift` | ≤210 行 prod 总和 | ☐ |
| 3 | `wc -l ios/Contracts/Tests/KlineTrainerContractsTests/GeometryTests.swift` | ≤520 行（43 tests / 5 Suites + 2 helpers / 实测对齐 E1 precedent commit 8b91e38 的 budget bump 模式） | ☐ |
| 4 | `git diff main --stat` | 仅 Geometry impl + tests + design doc + plan doc，无副改 | ☐ |
| 5 | `grep -rnE "import UIKit\|import SwiftUI" ios/Contracts/Sources/KlineTrainerContracts/Geometry/` | 0 命中（Contracts package 不依赖 UIKit / SwiftUI） | ☐ |
| 6 | `grep -rnE "precondition\|fatalError\|throws\|assertionFailure" ios/Contracts/Sources/KlineTrainerContracts/Geometry/` | 0 命中（spec 字面 fidelity，无新增防御） | ☐ |
| 7 | PR description 中文 + 含本 design doc cross-ref + 5 项 discrepancy 解决记录 + 12 项 residuals 显式 list | 显式 list | ☐ |
| 8 | PR `codex-verify-pass` GitHub status check | **绿灯** | ☐ |

第 8 行红/黄灯 → 不得 merge（CLAUDE.md backstop §1）。**超 3 轮 codex needs-attn → abort PR + close + 重新评估**（per memory hard rule）。

## Memory compliance check

- ✅ `feedback_big_pr_codex_noncovergence`：~187 行 prod / ~30 tests / 预计 ≤3 codex 轮（30 tests 超 ≤10 警戒由 6 residuals + char test 抢答兜底，+1 round contingency 显式承认）
- ✅ `feedback_planner_packaging_bias`：1 sub-task / 1 PR / ≤500 行 prod
- ✅ `feedback_brainstorming_grep_first`：spec 章节归属 grep-verified（modules L854-955 + plan L100-200 + L848 路径 + L1179 KLineView 跨 package）
- ✅ `feedback_module_level_abort_signal`：C1a 首次 brainstorm，无前史 abort
- ✅ `feedback_governance_budget_cap`：不主动加 precondition / throws / overflow guard；6 spec gap 全归 caller-side
- ✅ `project_modules_v1.4_frozen`：modules §C1a declaration 优先，不修 spec
- ✅ `feedback_pr_language_chinese`：本 design doc + 后续 PR description 全中文
- ✅ `feedback_reviewer_verdict_not_authorization`：T4 push / merge 前 user explicit confirm
- ✅ `feedback_infra_readiness_unaudited`：核 toolchain（Swift 6.3.1）/ SwiftPM target（Contracts）/ test scheme（既有 KlineTrainerContractsTests）/ spec 完整性（5 discrepancy 全暴露）
- ✅ `feedback_dep_graph_m05_overstated`：dep 仅 KLineCandle（同 package）+ Foundation/CoreGraphics（platform-given），无虚高声明

## Brainstorming convergence trail

- **R 周期 1**（Opus xhigh，原始 reviewer）：R1 NEEDS-CHANGES（3 Critical + 4 Important）→ R2 ACCEPT
- **R 周期 2**（Opus xhigh，fresh reviewer）：R3 NEEDS-CHANGES（2 Important + 4 Minor）→ R4 NEEDS-CHANGES（2 Blocker：C1c UIKit 误判 + D-2/D-4 ghost discrepancy）→ R5 ACCEPT（confidence 95% high）
- **关键修正轨迹**：
  - C-1：spec discrepancy 4→5（修正 D-2/D-4 ghost；保留 D-3/D-4/D-5 真分歧；删 D-7 折入 D-3）
  - C-2：`import CoreGraphics` 显式声明（Contracts 首次 CG 引用）
  - C-3：LOC 估 150→187（含 public boilerplate + 公开 init）
  - I-1：scope split 选项 A 给真实 air time（vs 第 1 轮 strawman）
  - I-3：α placement + C1b/C1c-values 同 package pre-commit + C1c 跨 2 package 拆分（KLineView 落 app target）
  - residuals 3→6（+ xToIndex overflow / 正价假设 / 空 candles fallback）
  - ChartPanelFrames.split 60/15/25 纵向堆叠算术显式

## Reviewer 留下的 2 个 minor caveat（non-blocking，已纳入本 doc）

- C2 cite 改为 modules L1245（不是 L1389，L1389 是 C7 ChartGestureArbiter.attach）—— 本 doc 已采用 L1245
- plan L111 narrative drift（"（计算属性）"）留 plan v1.6 单独修，不在 C1a brainstorm scope

## Cross-references

- **本 design doc**：`docs/superpowers/specs/2026-04-30-c1a-geometry-design.md`
- **spec 源**：`kline_trainer_modules_v1.4.md` §C1a L854-955（+ L848 path / L884-886 split 比例 / L1179 KLineView 跨 package 证据）+ `kline_trainer_plan_v1.5.md` §3 L100-200
- **C1a 下游消费点**：modules §C1b（L957-1135）+ §C1c KLineRenderState + §C8 ChartContainerView
- **E1 precedent design doc**（同 anchor 节奏 + Contracts placement 先例）：`docs/superpowers/specs/2026-04-29-e1-tickengine-design.md`
- **E2 deferred archive**（不复用，仅论证 anchor 选择素材）：memory `project_pr36_aborted.md`
- **CLAUDE.md backstop**：§1 codex-verify-pass / §2 非 coder 验收清单 / §4 skill gate
- **Memory references**：`feedback_big_pr_codex_noncovergence` / `feedback_planner_packaging_bias` / `feedback_governance_budget_cap` / `feedback_brainstorming_grep_first` / `feedback_module_level_abort_signal` / `project_modules_v1.4_frozen` / `feedback_infra_readiness_unaudited` / `project_pr37_e1_merged`
