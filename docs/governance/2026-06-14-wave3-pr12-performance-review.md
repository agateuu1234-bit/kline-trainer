# 静态性能评审 — Wave 3 顺位 12：渲染热路径 + Bitmap Cache 条件引入决议

**日期**：2026-06-14
**Anchor**：Wave 3 顺位 12（D 磨光组）
**类型**：静态评审 artifact（0 生产代码改动）
**依据**：modules v1.4 L2554「Phase 5 磨光前做一次性能评审 … 由 Codex 审视性能热点」

---

## 〇 摘要 + 依赖

**本顺位交付物**：静态渲染热路径评审 + 帧预算判据确认 + Bitmap Cache 条件引入决议 + host CI 回归绊线测试。**0 生产代码改动**。

**帧预算判据（own）**：单帧 `buildRenderState(make) + KLineView.draw(_:)` < 4ms @ 120Hz（modules v1.4 **L1471** / plan v1.5 L1264）。是否真达标 = 顺位 13 device 实测阻塞依赖；本顺位只交付判据与条件门，不交付数值。

**Bitmap Cache 决议**：当前 no-op（outline L173 字面）。条件门 = Instruments 实测峰值单帧 ≥ 4ms 才引入；详见 §四。

**上游依赖（均已 merged）**：
- 顺位 3 Pinch 缩放（PR #98）
- 顺位 4 Drawing 基础设施（PR #103）
- 顺位 5 十字光标 + HUD（PR #101）
- 顺位 11 Bounce（PR #96）

依赖满足（outline §canonical DAG L91 `12 性能 ← 全渲染锚(3,4,5,11)`）。

---

## 一 热路径结构

渲染路径分两个明确边界：

### make() 侧（纯函数，host 全量可测）

`RenderStateBuilder.make(engine:panel:bounds:crosshair:)`
- 位置：`ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:18-43`
- 性质：`@MainActor` 纯函数；切片 candle 数组 + 装配 `KLineRenderState`
- `makeViewport`：同文件 `:58-93`；`partitioningIndex` O(log n) + 切片 O(visibleCount)
- `defaultVisibleCount = 80`（同文件 `:13`）

### draw() 侧（UIKit-only，CI 不运行）

`KLineView.draw(_:)`
- 位置：`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift:33-60`
- 性质：UIKit-only；派发 8 个 `drawXxx` Core Graphics 绘制 pass
- **Equatable 短路**：`renderState.didSet`（`KLineView.swift:18-19`）；`renderState != oldValue` 才 `setNeedsDisplay()`

### 重建触发

`ChartContainerView.updateUIView`（`ios/.../Render/ChartContainerView.swift:34-41`）：每次 SwiftUI `@Bindable engine` 状态变更即重建 renderState。长按十字光标走 `Coordinator.setCrosshair` 视图层旁路重建。

### 帧驱动

`DecelerationAnimator`（`ChartEngine/DecelerationAnimator.swift`）：
- UIKit 平台：`CADisplayLink`，原生 Hz，**未设 `preferredFramesPerSecond`**
- macOS 平台：`Timer(1.0/120.0)`（同文件 `:200`）
- 每帧 1 个 `onUpdate(delta)`；**animator 内不调 `make()`**

**关键不变量**（modules v1.4 L1471 验收）：相同 engine 状态重复 `updateUIView` 经 Equatable 短路不触发 `draw`。此短路是 Phase 1 纯 draw 策略的性能基石。

---

## 二 每帧 CG 调用量级账

对照 plan v1.5 L31：「可见蜡烛约 93 根，总计约 600-700 次 Core Graphics 调用/帧 … 瓶颈线 > 5000 次」。

> **注**：plan 文案「约 93 根」为当时估算；代码权威 `defaultVisibleCount = 80`（`RenderStateBuilder.swift:13`）。以下账目按代码值 80 核算。

| 绘制 pass | 位置（`KLineView+Candles.swift`） | 每帧 CG ops 估算 |
|---|---|---|
| `drawCandles` | `:13-29` | per-candle：1 `strokePath`（影线）+ 1 `fill`（实体）+ `setFill`/`setStroke` 颜色态 × 80 → ~80×(2 path + 2 color) ≈ **320 ops** |
| `drawMA66` | `:30-44` | 1 条折线 stroke（~80 `addLine`）≈ **80 ops** |
| `drawBOLL` | `:47-67` | 3 轨虚线 stroke（~3×80 `addLine`）+ `setLineDash` ≈ **240 ops + 3 state** |
| `drawVolume` | 其他 KLineView+ 文件 | ~80 rect fill ≈ **80 ops** |
| `drawMACD` | 其他 KLineView+ 文件 | diff/dea 折线 + ~80 histogram bar ≈ **160 ops** |
| 其余 3 pass（Crosshair/Markers/Drawings） | 其他文件 | 量级较小；Crosshair 逐帧重绘 |
| **合计** | | ~**600-700+ ops**/帧（与 plan L31 估算同阶） |

**远低于 plan L31 瓶颈线 > 5000 次。**

**重要边界**：精确单帧 ms 归 device runbook（`docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`）；本静态评审不 claim 实测值，**不放行也不否决帧预算**。

---

## 三 热点清单（静态）

### (a) 每帧分配——分两侧记录

**draw() 侧**（`KLineView+Candles.swift` 调用链）：
- `MainChartLayout.candleShapes`：每帧新建 `[(CGRect, CGRect)]` 数组
- `MainChartLayout.ma66Polyline`：每帧新建 `[CGPoint]` 数组
- `MainChartLayout.bollPolylines`：每帧新建 `[[CGPoint]]` 数组

**make() 侧**（`RenderStateBuilder.make` 内部）：
- `slice.map`（volumeRange 装配）：同文件 `:29`，每帧新建数组
- `flatMap`（macdRange 装配）：同文件 `:31`，每帧新建数组

GC/ARC 压力来源候选。**当前规模据 plan L31 无压力**；记录为「device 实测逼近预算时首查点」。

### (b) per-candle 颜色态

`drawCandles`（`:13-29`）循环内：每根蜡烛调用 `color.setFill()` / `color.setStroke()`（涨跌色判断）。涨跌分组批绘是潜在优化——**仅当 Instruments 实测 > 4ms 才值得**，否则属于过早优化。

### (c) Equatable 短路成本

`KLineRenderState` 含 `visibleCandles: ArraySlice` 等大字段，每次 `renderState.didSet` 触发值相等比较。评审确认：
- 短路语义正确（相同 engine 状态不重绘，modules v1.4 L1471 验收）
- 短路本身的比较成本已接受（相对完整重绘是廉价前缀）

---

## 四 Bitmap Cache 条件引入决议 + 设计草图

### 决议门

```
实测峰值单帧 < 4ms
  → Phase 1 纯 draw 充分，Bitmap Cache 不引入
  → 本子项 no-op（outline L173）

实测峰值单帧 ≥ 4ms
  → 按下方设计草图引入 Bitmap Cache
  → 独立后续 anchor（非本锚），引入后须重测回落 < 4ms
```

**当前状态**：实测数值 pending（user device 职责 + 顺位 13 阻塞依赖）→ **当前 no-op**。

### 设计草图（备而不用）

目的：使未来 ≥ 4ms 实测触发时有现成方案，避免届时现编。

**缓存对象**：5 个视口静态层：
- `Candles`、`MA66`、`BOLL`、`Volume`、`MACD`
- 渲染到离屏 `CGLayer` 或 bitmap（数据 immutable，位置 = f(viewport)）

**缓存失效触发**：
1. 可见 candle 切片变化（新 tick / pan 跨 candle 边界）
2. geometry 缩放变化（pinch）
3. drawing 或 marker 增删

**合成策略**：
- 静态层：缓存 blit（5 层合并）
- 动态层（每帧叠加）：`Crosshair`（`renderState.crosshairPoint` 每帧变，必须在缓存之上重绘）
- `Markers`/`Drawings`：viewport-dependent，随缓存失效一并重建

**风险记录**（故 spec 设条件门）：
1. `displayScale` / 亚像素对齐：Retina 下离屏 bitmap 须匹配屏幕 scale，失配产生模糊
2. 失效正确性：缓存失效逻辑若有漏洞，产生陈旧画面（难调试）
3. 内存占用：5 层离屏 bitmap @ Retina 分辨率有额外内存压力

**结论**：不达门（< 4ms）不付此三类风险——spec「非默认/按需」条件门的设计理由。

---

## 五 结论

1. **量级账**：Phase 1 纯 draw 每帧 ~600-700 CG ops，与 plan v1.5 L31 估算同阶，远低于瓶颈线 > 5000。在 spec 规模假设（80 可见蜡烛）下不存在结构性瓶颈。

2. **是否真达标**：裁决权属 device 实测（`docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`），本静态评审不放行也不否决帧预算。

3. **热点清单**：已记录每帧分配（两侧）、per-candle 颜色态、Equatable 短路成本三项；均属「逼近预算时首查」，当前规模据 spec 无压力。

4. **Bitmap Cache**：条件门未触发 → **no-op**；设计草图已写死供 > 4ms 实测时按独立 anchor 引入。

5. **本评审交付**：热点清单 + 量级账 + 条件门决议。数值属顺位 13 阻塞依赖。
