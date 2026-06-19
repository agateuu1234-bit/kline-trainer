# 设计文档：图表坐标轴 / 网格 / 周期标注（RFC #3）

- 日期：2026-06-20
- 类型：渲染增量功能（改已冻结 spec，走完整 RFC）
- 来源：2026-06-17 模拟器运行时验证 #3a/#7（图表无坐标轴/网格/周期标注）。见 `project_runtime_verification_findings_2026_06_17`。
- 评审通道：**Opus 4.8 xhigh 对抗性 review 到收敛**（代 codex，user explicit；codex 周配额耗尽，与本项目所有 opus-fallback PR 一致）。
- 范围说明：这是「UI 改版 4 子项」拆分后的第 1 个独立 RFC（user 选定先做 #3）。其余 3 项（#1 买卖操作栏 / #2 历史中间弹窗 / #4 两图 pan 联动）各自独立 RFC，后续单独排。

---

## 1. 背景与问题

当前 K 线图表**完全没有持久的坐标轴、网格线、周期标注**。`KLineView.draw(_:)` 只派发 8 个绘制调用（candles / MA66 / BOLL / volume / MACD / drawings / markers / crosshair）。唯一「轴样」渲染是十字光标的**临时** HUD（长按时出现，松手即清），不是持久坐标系。`AppColorTokens.gridLine` 调色 token 早已存在（`Theme/Theme.swift:62`）但**从未接线**（grep 确认 draw 层零消费）。

spec（`kline_trainer_modules_v1.4.md` / `kline_trainer_plan_v1.5.md`）对「渲染可见坐标轴/网格/周期标注」**从未规定**——只描述了坐标系数学（`CoordinateMapper`/`PriceRange`/`ChartViewport`）与一个未接线的 `gridLine` token。因此本 RFC 是**新增 spec 段落**，不是反转任何冻结决策。

## 2. 目标与范围

### 目标
给上下两个 K 线面板（各自周期、各自价格刻度）的**主图 + 量图 + MACD** 三个区都加上：价格轴、时间轴、网格线、周期角标。

### In scope
- 主图右缘价格刻度（整齐数字）+ 对齐的水平网格线。
- 底部共享时间轴（周期自适应日期格式）+ 对齐的垂直网格线（贯穿三区）。
- 量图最大量标签（万/亿）+ 顶部一条水平网格线。
- MACD 0 轴水平网格线 + 标签。
- 左上角周期角标（`3分 / 15分 / 60分 / 日 / 周 / 月`）。
- 上下两面板都生效。

### Out of scope（非目标，明确排除）
- ❌ 最新价横线 + 高亮标签（user 明确不要）。
- ❌ 改动冻结的 60/15/25 三区几何与视口宽度（采用**悬浮**标签，不留白槽）。
- ❌ 引擎 / 交易 / 手势 / pan / pinch 逻辑（零改动）。
- ❌ 百分比涨跌轴、成交额轴、副图多线数值游标（YAGNI）。
- ❌ #1/#2/#4 三个子项（各自独立 RFC）。

## 3. 已锁定决策（brainstorming Q&A 结果）

| # | 决策 | 取值 |
|---|---|---|
| D1 | 覆盖范围 | **完整版**：主图 + 量图 + MACD 三区都有轴/网格 |
| D2 | 价格轴位置 | 右缘，4–5 档「整齐数字」刻度 |
| D3 | 水平网格 | 主图对齐价格刻度；量图最大值一条；MACD 0 轴一条 |
| D4 | 垂直网格 | 对齐时间刻度（淡线），贯穿三区 |
| D5 | 时间轴 | 底部一条共享；周期自适应格式 |
| D6 | 周期角标 | 左上角，半透明盒，`3分/15分/60分/日/周/月` |
| D7 | 量图/MACD 标签 | 量：`万/亿` 单位最大量；MACD：0 轴标签 |
| D8 | 两面板 | 都生效（各自周期、各自价格刻度） |
| D9 | 最新价横线 | ❌ 不做 |
| D10 | 标签占位 | **悬浮**（叠在 K 线上，不动 60/15/25 几何） |

> **实现说明（impl 落地后回填）**：标签盒复用 `KLineView.drawLabelBox`，其 `currentPalette.background` 在两套调色板下 alpha=1.0（**实心**，非真半透明）。本文 D6/D10/§4.3/§5 中「半透明」是观感目标；实现以实心盒为准（与十字光标 HUD 一致），spec amendment §C5b 与 plan 残留如实记录。真半透明属 cosmetic follow-up，不在本 RFC 范围。

## 4. 架构

### 4.1 核心：draw-time 解析（沿用十字光标先例）

`RenderStateBuilder.make` **不持有 `displayScale`**（源码注释 `RenderStateBuilder.swift:19-20`：「renderState 无该字段；亚像素对齐在 `KLineView.draw` 用 `traitCollection.displayScale`」）。十字光标据此把布局解析放在**绘制时**：`KLineRenderState` 只存原始输入 `crosshairPoint: CGPoint?`，几何由 `CrosshairLayout.resolve(...)` 在 `KLineView+Crosshair.swift`（`#if canImport(UIKit)`）用 displayScale 感知的 `CoordinateMapper` 现算（`CrosshairLayout.swift:63`）。

坐标轴/网格的全部输入——`viewport`（价格区间 + 几何）、`frames`（三区 rect）、`visibleCandles`（datetime）、`volumeRange`/`macdRange`、`panel.period`——**已经全部在 `KLineRenderState` 里**（`KLineRenderState.swift:14-23`；`KLineView` 现已用 `renderState.panel.period` 派发 drawDrawings，`KLineView.swift:101`）。因此本功能**无需给 `KLineRenderState` 加任何字段、无需改 `RenderStateBuilder`、无需 bump `CONTRACT_VERSION`**——这比「预计算进 renderState」严格更外科手术、风险更低，且与既有先例同构。

> 设计演进说明：brainstorming 阶段我向 user 描述「新增 `KLineRenderState` 字段 + `RenderStateBuilder` 计算」。读源码后发现十字光标的 **draw-time 解析**先例使本功能零 renderState 改动即可达成同一可见效果，故采用更外科的版本。所有 D1–D10 可见决策不变。

### 4.2 新增纯函数布局类型 `AxisGridLayout`

新文件 `ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift`（**不 import UIKit**，host 全测；与 `CrosshairLayout`/`MarkersLayout` 同构，类型 `internal`——十字光标类型即 internal，测试走 `@testable import`，故**无公有 API 变更**）。

```
enum AxisGridLayout {
    static func resolve(
        mapper: CoordinateMapper,          // 主图价格映射（含 displayScale）
        volumeMapper: IndicatorMapper,     // 量图值映射
        macdMapper: IndicatorMapper,       // MACD 值映射
        candles: ArraySlice<KLineCandle>,
        period: Period,
        frames: ChartPanelFrames
    ) -> AxisGridResolved?                 // candles.isEmpty / 退化几何 → nil（守卫）
}

struct AxisGridResolved: Equatable, Sendable {
    let gridLines: [LineSegment]           // 水平(价格档/量max/macd0) + 垂直(时间档) —— 画在 K 线背后
    let priceLabels: [Label]               // 右缘价格刻度（悬浮盒）
    let timeLabels: [Label]                // 底部时间刻度（悬浮盒）
    let volumeLabel: Label?                // 量图最大量（万/亿）
    let macdZeroLabel: Label?              // MACD 0 轴
    let periodLabel: Label                 // 左上角周期角标
    // `Label`/`LineSegment` 是 AxisGridResolved 自有的**新嵌套类型**（{ rect, text } / { from, to }），
    // 形状镜像 CrosshairLayout 的 `CrosshairResolved.Label` / `CrosshairLines.LineSegment`
    // （CrosshairLayout.swift:19/32 是 *nested*，无顶层 `Label`/`LineSegment`）。在本新文件内定义，
    // 故「其余既有文件零改动」仍成立（修 review-R2 N3）。
}
```

入参 `mapper`/`volumeMapper`/`macdMapper` 由绘制层用 `traitCollection.displayScale` 构造（`KLineView.draw` 现已构造这三个 mapper，`KLineView.swift:80-93`，直接复用）。`resolve` 全为平台无关纯数学 + 字符串格式化 → host `swift test` 真断言。

### 4.3 新增 UIKit 薄绘制层 `KLineView+AxisGrid.swift`

两个绘制方法（`#if canImport(UIKit)`）。**两者都必须遵循既有 GState 自平衡惯例** `ctx.saveGState(); defer { ctx.restoreGState() }`（同 `KLineView+Crosshair.swift:22-23`、`KLineView+Candles.swift:15/56-57` 的 H1-honesty「state 不得泄漏到后续 pass」），否则 `drawGridLines` 设的 strokeColor/lineWidth 会泄漏进随后的 `drawCandles`：
- `drawGridLines(ctx:, resolved:)`：用 `currentPalette.gridLine` 描所有网格线（接线既有 token），1 device pixel 宽。
- `drawAxisLabels(ctx:, resolved:)`：描价格/时间/量/MACD/周期标签盒（半透明 bg + text）。
- **标签盒复用 = 显式可见性改动（修 review High）**：现有 `drawLabelBox` 是 `KLineView+Crosshair.swift:38` 的 **`private func`**，跨 extension 文件不可调用。决议：把它从 `private` 改为 `internal`（`func drawLabelBox(...)`，去掉 `private`），两个新方法共用同一实现（DRY，单 token 拓宽可见性）。这使**改动的既有文件 = 2 个**（见 §4.4），非 1 个。

### 4.4 `KLineView.draw(_:)` 集成 + `KLineView+Crosshair.swift` 一处可见性拓宽

在 `draw` 内构造 `AxisGridLayout.resolve(...)` 一次，按层序插入两段：
```
... 构造 mapper / volMapper / macdMapper（既有）...
let axis = AxisGridLayout.resolve(mapper:, volumeMapper:, macdMapper:, candles:, period: renderState.panel.period, frames: renderState.frames)
drawGridLines(ctx:, resolved: axis)      // ★新增① 最前：网格画在 K 线背后
drawCandles / drawMA66 / drawBOLL / drawVolume / drawMACD / drawDrawings / drawMarkers   // 既有 7 个，顺序不变
drawAxisLabels(ctx:, resolved: axis)     // ★新增② 标签画在 K 线之上、crosshair 之下
drawCrosshair(...)                        // 既有第 8 个，仍最后（长按 HUD 盖在最上）
```
既有 8 个绘制调用的相对顺序与签名**全部不变**；只**插入** 2 个新调用（网格在最前、轴标在 `drawMarkers` 与 `drawCrosshair` 之间）。`axis == nil`（空 candle）时两个新调用都跳过。

**改动的既有文件（共 2 个，对齐修 review High）**：① `KLineView.swift` 的 `draw(_:)` —— 插入 1 行 `resolve` + 2 个绘制调用；② `KLineView+Crosshair.swift` —— `drawLabelBox` `private`→`internal`（单 token）。其余既有文件零改动。

### 4.5 排除的备选
- 在 draw 方法里直接算刻度几何（不可 host 测、layout 耦合 UIKit）——否。
- 独立 SwiftUI overlay view 叠加（多一套组件、破坏单一 `KLineView` draw 管线、与 UIKit 图层错位）——否。
- 预计算进 `KLineRenderState` 新字段（builder 无 displayScale，须存 value-domain 再于 draw 映射，多一层且扩公有契约）——否（见 §4.1）。

## 5. 元素规格（精确规则）

### 5.1 价格刻度（D2/D3）
- 输入区间 = `viewport.priceRange.[min,max]`（含 BOLL/MA66 + ±5% padding，`Geometry.swift:88-101`）。
- **退化守卫（修 review High）**：`let range = max - min`；`guard range.isFinite, range > 0 else { 不产出价格刻度 }`。注意 `*0.95/*1.05` 只对**严格正**价格撑开——零价或全零 OHLC 时 `min==max==0` → `range==0`（不能假定「恒撑开」），故此 guard 是必需而非冗余（当前仅 `DebugFixtureData` 正弦数据掩盖了它）。
- **整齐步长**算法（`maxTicks = 6`，取「能放下 ≤6 档的最细 nice step」，下界不硬保证）：
  - nice step 候选 = `{1,2,5} × 10^k`（k∈ℤ），由细到粗：`…0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10…`。
  - 定义 `count(S) = floor(max/S) − ceil(min/S) + 1`（在选取所用的**细端区间**内随 S 增大而减；粗端可能出现 count==0 的非单调点，不影响选取——选取永远落在 count 较大的细端）。取**满足 `count(S) ≤ maxTicks` 的最小 S**（= 不超 6 档的最细网格）。
  - **空档兜底（修 review-R2 N1）**：候选 step 阶梯须向细端延伸到 `count ≥ 1`（实现勿把最细 step 截断在比区间宽的粒度）。极窄正区间（如 `10.001..10.002`，窄于阶梯最细 step）若选中 step 给 `count==0` → 回退产出**单档**（`round(midpoint/S)×S` 落在区间内则取之，否则取 midpoint 原值）。真实数据有 ±5% padding（≥10% 宽）不会触发，但 host 测须覆盖此窄区间断言「价格刻度非空」。
  - `first = ceil(min/S) × S`；自 `first` 起以 `S` 递增取所有 ≤ `max` 的档位。
  - 工作示例（与 §6.1 一致）：`11.23..12.87` → S=0.1 给 16 档(>6)、0.2 给 8 档(>6)、**0.5 给 3 档(≤6)** → `{11.5, 12.0, 12.5}`。
- 每档 `value`：`y = mapper.priceToY(value)`；label = `String(format:"%.2f", value)`；rect 右贴 `mainChart.maxX`、垂直居中该 y。
- 每档同时产出一条水平网格线（`from(mainChart.minX,y) → to(mainChart.maxX,y)`）。

### 5.2 时间刻度（D4/D5）
- **必须用绝对索引（修 review High）**：`visibleCandles` 是 `ArraySlice`，其 `startIndex == viewport.startIndex`（`RenderStateBuilder.swift:30`），而 `mapper.indexToX` 内部按 `(index − viewport.startIndex)` 计算（`Geometry.swift:139`）。沿切片**绝对索引**均匀取 ~4 个位：`idx_k = candles.startIndex + ⌊k·(n−1)/3⌋`，`k∈{0,1,2,3}`，去重，`n = candles.count`。**严禁**传 slice-relative `0/n/3/...`（会错位一个 `startIndex`，正是既有 `CrosshairLayout`/`MainChartLayout` 用 `candles.indices` 规避的陷阱）。
- 每位取 `candles[idx_k].datetime`（`Int64` 秒）格式化（用与 `CrosshairLayout.swift:91-94` **相同的 formatter 配置**：UTC+8 / `en_US_POSIX`；该处 formatter 为内联构造、非共享符号，故是「镜像配置」而非代码复用——修 review-R2 N2）：
  - `.m3/.m15/.m60` → `"MM-dd HH:mm"`
  - `.daily/.weekly` → `"yyyy-MM-dd"`
  - `.monthly` → `"yyyy-MM"`
- 每位 `x = mapper.indexToX(idx_k)`；time label rect 水平居中该 x、底贴 `macdChart.maxY`（悬浮）。
- 每位同时产出一条垂直网格线（`from(x, mainChart.minY) → to(x, macdChart.maxY)`，贯穿三区）。

### 5.3 量图 / MACD（D3/D7）
- 量图：取可见 `volume` 实际最大值 `maxVolume`；水平网格线与 label 都定位在 `y = volumeMapper.valueToY(maxVolume)`（**注意**：`volumeRange` 经 `NonDegenerateRange.make` 加了 2% 上 padding，`RenderStateBuilder.swift:42`，故该 y 略**低于** `volumeChart` 顶边，与最高量柱顶对齐——不与 frame 顶边重合，rect 锚在这条线的右端，不写「顶贴 frame 顶部」）。label：`亿`（≥1e8 → `x/1e8` 一位小数 + "亿"）、`万`（≥1e4 → `x/1e4` 一位小数 + "万"）、否则原值。
- MACD：若 `0` 落在 `macdRange.[lower,upper]` 内，`y = macdMapper.valueToY(0)`；一条水平网格线 + label `"0"`，rect 右贴该 y 处 `macdChart.maxX`。0 不在区间则跳过（label/line 皆不产出）。

### 5.4 周期角标（D6）
- `period → 文字`：`.m3→"3分" / .m15→"15分" / .m60→"60分" / .daily→"日" / .weekly→"周" / .monthly→"月"`。
- rect 左上角（`mainChart.minX + 内边距`，`mainChart.minY + 内边距`），半透明盒。

### 5.5 守卫
- `candles.isEmpty` → `resolve` 返 nil（两段绘制跳过）。
- **价格区间退化**（`max − min ≤ 0` 或非有限——零价/全零 OHLC 时确会发生，§5.1 已说明「恒撑开」不成立）→ 价格刻度元素跳过（不产出，不进 `log10`/除法，不 trap）。
- 非有限 mapper 输出 / `macdRange` 不含 0 / 单根 candle 等 → 对应元素各自跳过，不 trap。

## 6. 测试策略（TDD）

### 6.1 host 单测（`AxisGridLayoutTests`，平台无关真断言）
- 整齐步长：非整除区间 `11.23..12.87` → 期望 `{11.5, 12.0, 12.5}`（step 0.5，与 §5.1 算法一致）；档数 `≤ 6` 硬断言（取满足 count≤6 的最细 step）；下界不硬断言（极端区间可能 2 档）。再加一例 `10.05..10.95` → `{10.2,10.4,10.6,10.8}`（step 0.2，4 档）佐证常态。
- **退化区间产出空价格刻度**：全零 OHLC（`min==max==0`）/ 非有限 → 价格刻度数组为空、不 trap（直接验 §5.5 守卫，防 `log10(0)`/除零回归）。
- **极窄正区间非空（防 review-R2 N1 回归）**：`range>0` 但极窄（如 `10.001..10.002`）→ 价格刻度**非空**（验 §5.1 空档兜底单档回退）。
- 价格档 `y` 与 `CoordinateMapper.priceToY` 一致（同一映射，无第二套公式）。
- **绝对索引断言（防 §5.2 陷阱回归）**：首条垂直时间线的 `x == mapper.indexToX(candles.startIndex)`，**不等于** `indexToX(0)`（构造 `startIndex > 0` 的 viewport 使两者可区分）。
- 时间标签：六个 `Period` 各自分支格式正确；UTC+8 边界（跨日 23:30 / 月初）。
- 时间档 `x` 与 `indexToX` 一致；垂直线贯穿 `mainChart.minY..macdChart.maxY`。
- 量图 `万/亿` 格式分支（9999 / 1e4 / 1.5e8）；MACD 0 轴在/不在区间两分支。
- 边界：单根 candle（`n==1`，索引集去重为 `{startIndex}`）、空切片返 nil。
- 浮点：整齐步长与 `%.2f` 用容差/字面对齐（吸取 `feedback_swift_local_toolchain_blindspot`：非整除浮点 host 测试必须容差）。

### 6.2 UIKit 绘制层
- Catalyst `build-for-testing` 编译闸（`KLineView+AxisGrid.swift` 进 `#if canImport(UIKit)`）。
- 模拟器人工验收（acceptance §6 runbook）：上下两面板各周期下轴/网格/角标正确、不遮挡核心、暗/亮主题 `gridLine` 对比可见。

## 7. 治理 / 冻结 spec 影响

- **新增**（非反转冻结）：
  - `kline_trainer_modules_v1.4.md`：新增一节（建议 §C5b「坐标轴/网格/周期标注布局 `AxisGridLayout`」），登记新纯类型 + 两个 UIKit 绘制方法 + `KLineView.draw` 层序（网格最前、轴标 crosshair 之前）。**显式声明 `KLineRenderState` 契约不变**（无新字段）。
  - `kline_trainer_plan_v1.5.md`：新增一节描述轴/网格/周期标注渲染规则（§5 元素规格摘要），**显式声明 60/15/25 几何与视口宽度不变**（悬浮，非留白槽）。
- **`CONTRACT_VERSION`**：当前 `1.6`（`Models.swift:7`）。权威 bump 策略在 `docs/governance/m01-schema-versioning-contract.md`（§Bump 策略 A 类 = 跨系统/破坏性持久化/改既有语义）。本 RFC = `AxisGridLayout` internal 类型（同 `CrosshairLayout`）+ 增量 draw pass，**无公有 API 变更、无 DDL/持久格式/Codable 变更** → 不命中任何 bump 触发 → **不 bump**。
  - ⚠️ 该治理文档顶层标 `"1.5"` 而代码已 `"1.6"`（后续 PR 升过但文档未回填，**pre-existing drift，非本 RFC 职责**）；plan 阶段仅引用其 bump 策略章节，不依赖其陈旧版本号。
- **非信任边界变更**：不动 `.github/workflows`、codeowners、ruleset。
- 评审通道 = Opus 4.8 xhigh 对抗性 review（spec / plan / branch-diff 三道，各到收敛）。

## 8. 风险与残留

- **R1**：整齐步长在极端区间（价格 < 0.1 或 > 1e4）的档位密度。缓解：nice-step magnitude 自适应 + **上界 `≤6` 硬保证**（取满足 count≤6 的最细 step；下界不硬保证，极端区间可能 2 档——已在 §5.1/§6.1 如实声明，不再宣称「clamp [3,6]」）+ host 边界测试。
- **R2**：悬浮标签遮挡最右/最底边缘 K 线（user 已知并接受，D10）。半透明盒最小化影响。
- **R3**：`KLineView.draw` 改动层序——风险在编译与层叠次序，无引擎/数据风险；Catalyst 编译闸 + 模拟器验收兜底。
- **R4**：周期角标文字与未来 #1/#4 RFC 的潜在 UI 元素位置冲突——本 RFC 角标固定左上，后续 RFC 各自避让。

## 9. 成功标准

1. 上下两面板、六个周期下，主图价格轴（整齐数字）+ 水平网格、底部时间轴（周期自适应）+ 垂直网格、量图最大量、MACD 0 轴、左上周期角标全部正确渲染。
2. `AxisGridLayout` host 单测全绿（含非整除/边界/六周期格式）。
3. host 全量 `swift test` 不回归 + Catalyst `build-for-testing` SUCCEEDED + iOS app build SUCCEEDED。
4. `KLineRenderState` 契约零字段变更；引擎/交易/手势零改动。
5. 三道 Opus 4.8 xhigh 对抗性 review 各收敛 APPROVE。
