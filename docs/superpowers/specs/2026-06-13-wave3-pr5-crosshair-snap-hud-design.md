# Wave 3 顺位 5：十字光标吸附 + HUD 设计

**锚**：Wave 3 outline 顺位 5（`docs/superpowers/specs/2026-06-09-wave3-outline-design.md` §二，轨 G 图表/手势链 `3 Pinch → 5 Crosshair → 4 Drawing`）。
**依赖（均已 merged）**：顺位 2（app-target CI + 锁竖屏，PR #93）+ 顺位 3（Pinch engine-owned zoom，PR #98）。
**范围估算**：~200-300 行（含测试 + runbook）。**纯渲染层**：0 engine 改动、0 Coordinator 改动、0 arbiter 改动。

---

## 一、背景与现状（grep 核实 2026-06-13，base = origin/main b4f0e2a）

**已落基础设施**：

| 件 | 来源 | 现状 |
|---|---|---|
| `CrosshairLayout`（纯函数：`lines`/`priceLabel`/`timeLabel`） | C5 PR #68（Wave 1） | 几何/字符串在 host 可测纯层；**竖/横线用原始 `point.x`/`point.y`，不吸附**（D7 注：「吸附决策在 Wave 2 LongPress 源」）；`timeLabel` 经 `xToIndex` 解析候选 candle，越界返回 `nil` |
| `KLineView+Crosshair.drawCrosshair(ctx:at:viewport:)` | C5 PR #68 | UIKit 薄层；`KLineView.swift:59` 派发，入参 `renderState.crosshairPoint` + `renderState.viewport` |
| 长按 → `setCrosshair(rawLocation)` | C8b PR #87（Wave 2） | `ChartContainerView.Coordinator.onLongPress` 路由长按位置（**原始触点，未吸附**）；十字光标为视图层瞬态（D3，不进 engine），经 `RenderStateBuilder.make(crosshair:)` → `renderState.crosshairPoint` 透传 |
| engine-owned zoom | 顺位 3 PR #98 | `engine.applyPinch(...)` 改 `panelState.visibleCount`；`RenderStateBuilder.makeViewport` 用 `candleStep = mainFrame.width / panelState.visibleCount`，**post-pinch 视口几何经 `renderState.viewport` 流转** |

**baseline gap**：C5 D7 把吸附「defer 到 Wave 2 LongPress 源」，但 Wave 2（C8b）实际只透传原始触点、未实现吸附 → 当前长按竖线落在手指原始 x，不对齐任何蜡烛。**顺位 5 owns 这条吸附。**

**契约归属核实**：
- RFC §4.4d 明定「crosshair 吸附（顺位 5）……消费『post-pinch 视口几何』(index↔x 映射)」，且单一真相要求 zoom 写回 engine `panelState`（顺位 3 已满足）。
- crosshair **本身不是 engine 契约**（view-layer 瞬态 D3，RFC 7 契约不含 crosshair）→ 顺位 5 不改 engine / 不进 RFC 治理面。
- `CrosshairLayout.*` 调用方仅 `drawCrosshair` + 单测（grep 证），可安全整合 API。

---

## 二、目标与非目标

**目标**：
1. 长按十字光标**竖线吸附到最近蜡烛中心**；**时间 label 随吸附后的蜡烛**。
2. **价格 label 自由**（跟随 cursor Y，可读任意价位）。
3. 吸附基于 **post-pinch 视口几何**（缩放后竖线落正确蜡烛中心）。
4. 交付**运行时 runbook 条目**（顺位 13 阻塞依赖，outline §三.3）。

**非目标（YAGNI / 排除）**：
- engine / Coordinator / `ChartGestureArbiter` 改动（长按已接线；吸附在 render 纯层下游）。
- OHLC 信息框 / 成交量读数 / 涨跌幅 HUD（spec/outline 仅要求「价格/时间 label」）。
- 画线锚点（顺位 4）、pinch 手势（顺位 3 已落）、十字光标进入 engine 状态。

---

## 三、核心设计决策

### D1：吸附轴 = 仅 X（竖线 + 时间 label）；Y 自由（横线 + 价格 label）
- **决策**：X-only snap。竖线吸附最近蜡烛中心 + 时间 label 取该蜡烛 datetime；横线与价格 label 跟随 cursor 原始 Y。
- **理由**：金融图表十字光标标准行为（TradingView 同款）——竖线锁定离散蜡烛（定位「哪根 K 线」），价格轴读数随光标自由移动（读任意价位）。本 app 是 K 线训练，长按目的是「检视某根蜡烛 + 读任意价位」，二者兼得。
- **备选 B（全吸附到 close：横线 = `priceToY(close)`、价格 label = close）被否**：锁死 Y 后横线与蜡烛实体冗余、且丧失自由读价能力，对训练检视价值更低。

### D2：「最近蜡烛」= 最近中心（round-to-nearest），非 slot/floor
- 「最近蜡烛」定义为**中心 `indexToX(i)` 离 `point.x` 最近**的索引 `i`（过两中心中点即跳邻居），**非** `xToIndex` 的 slot/floor 语义（slot 在蜡烛边界跳变，非「最近中心」）。
- **`snappedX = indexToX(snappedIndex)`** → 竖线恒落真实渲染中心（与 C3 `MainChartLayout` D5「`indexToX` = 蜡烛水平中心」一致）。
- **鲁棒性契约**（沿用 `xToIndex` verify-and-correct 精神）：候选 = `round((point.x − pixelShift) / candleStep) + startIndex`，再以邻居 `indexToX` 实测距离校正取 min，独立于 fractional `pixelShift`/`candleStep`/`displayScale`。

### D3：吸附 index clamp 到可见蜡烛索引区间
- 吸附 index clamp 到 `[startIndex, startIndex + visibleCount − 1]`（= `renderState.visibleCandles` 的索引区间）→ frame 内点**恒落真实可见蜡烛**：
  - 早期数据（`count < visibleCount`，右侧 padding 空白区）或末根右侧长按 → 吸附**最末可见蜡烛**；左侧越界 → 第一可见蜡烛。
  - 消除 C5 `timeLabel` 的 nil-skip：frame 内长按**始终**有时间 label。
- **frame 守卫（C5 D8）仍在**：`point` 落 `mainChartFrame` 外（半开区间 `[minX,maxX)×[minY,maxY)`）→ 无光标（返回 `nil`，整体跳过绘制）。

### D4：HUD = 价格 label（右缘，自由 Y）+ 时间 label（底缘，吸附 X），无 OHLC 框
- HUD 内容 = 既有两条 axis label，仅位置/取值随吸附调整：
  - **价格 label**：右贴 `mainChartFrame.maxX`、垂直居中 `point.y`、文本 = `yToPrice(point.y)` 两位小数（**不变**，自由 Y）。
  - **时间 label**：水平居中 **`snappedX`**（非原始 `point.x`）、底贴 `maxY`、文本 = 吸附蜡烛 datetime（`yyyy-MM-dd HH:mm` UTC+8 / `en_US_POSIX`，沿用 C5）。
- 不引入 OHLC 信息框（spec/outline 未要求）。

### D5：吸附逻辑落 render 纯层（`CrosshairLayout`）、draw-time、单一吸附真相
- 在 `CrosshairLayout` 纯层 **draw-time** 吸附，输入 = 原始 `point` + 当前 `mapper`（来自 `renderState.viewport`）+ `visibleCandles`。
- **覆写 C5 D7「吸附在 LongPress 源」提示**，理由：
  1. **host 可测**：纯层无 UIKit，吸附/clamp/post-pinch 全在 host swift test 真断言。
  2. **单一视口真相**：用「正在被渲染的同一视口」吸附 → 竖线与所画蜡烛恒一致。
  3. **post-pinch 自动正确**：`mapper` 来自 post-pinch `panelState` 构造的 `viewport`，缩放后 `candleStep` 变化自动反映，无需 Coordinator 重算。
  4. **单一 snappedIndex 真相**：竖线位置与时间 label **共用同一 `snappedIndex`**，结构上杜绝「竖线在 A、时间 label 显示 B」错位。
- **Coordinator 继续存原始 `point`，不改**（吸附是下游 draw-time 投影；长按/松手语义不变）。

### D6：API 整合 —— 单一入口 `resolve(...)`
- `CrosshairLayout` 以单一入口替换三个分离函数（`lines`/`priceLabel`/`timeLabel`），返回一个聚合几何值：
  ```
  struct CrosshairResolved {            // 名暂定，plan 阶段定稿
      let lines: CrosshairLines          // 竖线 x = snappedX；横线 y = point.y
      let priceLabel: (rect: CGRect, text: String)   // 自由 Y
      let timeLabel: (rect: CGRect, text: String)    // 吸附 X（in-frame 恒非 nil）
      let snappedIndex: Int              // 暴露供测试/runbook 断言
  }
  static func resolve(at point: CGPoint?, mapper: CoordinateMapper,
                      candles: ArraySlice<KLineCandle>) -> CrosshairResolved?
  ```
  - `point == nil` 或落 `mainChartFrame` 外 → 返回 `nil`。
  - 单次算 `snappedIndex` → 派生 `lines`/`priceLabel`/`timeLabel`，保证一致。
- 理由：单一 `resolve` 是「单一吸附真相」（D5.4）的结构落地；分离函数会令 `snappedIndex` 算两次、易漂移。仅 `drawCrosshair` + 单测受影响（grep 证无第三方调用）。

---

## 四、组件与数据流

```
长按手势（已接线，C8b 不改）
  → Coordinator.setCrosshair(rawLocation)        [存原始 point，不改]
  → RenderStateBuilder.make(crosshair: rawPoint) [post-pinch viewport 装配，不改]
  → renderState { crosshairPoint=rawPoint, viewport=post-pinch }
  → KLineView.draw → drawCrosshair(at: rawPoint, viewport)   [改：接 resolve]
        └─ CrosshairLayout.resolve(at: rawPoint, mapper(viewport), visibleCandles)  [新：吸附+clamp]
             ├─ 竖线 x = indexToX(snappedIndex)        ← 吸附
             ├─ 横线 y = rawPoint.y                    ← 自由
             ├─ 价格 label = yToPrice(rawPoint.y)       ← 自由
             └─ 时间 label = candles[snappedIndex].datetime @ snappedX  ← 吸附
```

**单元边界**：
- `CrosshairLayout`（纯层，平台无关）：吸附几何 + label 文本/锚位的**唯一真相**；输入值类型、输出值类型，host 全测。
- `KLineView+Crosshair`（UIKit 薄层）：仅描边/填充/绘字，调一次 `resolve`，无几何判断。
- 二者依赖：薄层 → 纯层（单向）；纯层依赖 `CoordinateMapper`/`KLineCandle`（既有值类型）。

---

## 五、测试矩阵（host swift test，纯层全断言）

| # | 断言 | 防回归点 |
|---|---|---|
| 1 | **nearest-center round 跳变**：`point.x` 从中心 A 向 B 移动，过 (A,B) 中点前吸附 A、过后吸附 B | D2 round 非 floor |
| 2 | **`snappedX == indexToX(snappedIndex)`**：竖线恒落真实中心；`lines.vertical.from.x == lines.vertical.to.x == indexToX(snappedIndex)` | D2 |
| 3 | **clamp 右**：`count < visibleCount`，`point.x` 在右侧 padding 空白区 → `snappedIndex == 最末可见` + 时间 label 非 nil | D3 |
| 4 | **clamp 左**：`point.x` < 第一蜡烛中心 → `snappedIndex == startIndex` | D3 |
| 5 | **价格 label 自由 Y**：固定 `point.y`、变 `point.x`，价格 label 文本恒 = `yToPrice(point.y)`（吸附不影响价格读数）+ 镜像 `yToPrice`（禁纯层重算 ratio） | D1/D4 |
| 6 | **时间 label 吸附 X**：`timeLabel.rect.midX == snappedX`（非原始 `point.x`）+ 文本 = `candles[snappedIndex].datetime`（UTC+8） | D2/D4 |
| 7 | **frame 外 → nil**：4 角半开区间（左上 ∈；右上/左下/右下 ∉） | D3 frame 守卫 |
| 8 | **post-pinch demonstrator**：非默认 `visibleCount`（如 40，candleStep 翻倍）+ 非零 `pixelShift` 的 viewport 下吸附正确——同一 `point.x` 在 zoom 前后吸附到**不同**蜡烛中心，证 `candleStep` 变化被吸附消费（mutation-verify：若用固定 80 分母则该向量失败） | post-pinch 集成（5←3 核心验收） |
| 9 | **locale 中性**：时间格式跨设备 locale 稳定（`en_US_POSIX` + UTC+8） | 沿用 C5 |

**Catalyst CI**：`drawCrosshair` UIKit 薄层经 `Mac Catalyst build-for-testing` required check（仅编译/链接，运行时行为见 runbook）。

---

## 六、文件触碰

| 文件 | 改动 |
|---|---|
| `ios/Contracts/Sources/.../Render/CrosshairLayout.swift` | 整合为 `resolve(...)` + 吸附（nearest-center round + clamp）+ `CrosshairResolved` 值类型；保留 `priceLabel` 的 `yToPrice` 镜像不变量 |
| `ios/Contracts/Sources/.../Render/KLineView+Crosshair.swift` | `drawCrosshair` 改调 `resolve`（竖线/横线/价签/时签均从聚合结果绘） |
| `ios/Contracts/Tests/.../Render/CrosshairLayoutTests.swift` | 更新既有断言（吸附后竖线/时签语义）+ 新增矩阵 1-8 |
| `docs/acceptance/2026-06-13-wave3-pr5-crosshair-snap-hud.md` | 非-coder 可执行验收 + **runbook 运行时条目**（长按吸附/松手退出/缩放后吸附/价签自由 Y） |

**不触碰**：`KLineView.swift`（派发点签名不变）、`KLineRenderState`（`crosshairPoint` 仍存原始 point）、`ChartContainerView`/Coordinator、`ChartGestureArbiter`、`TrainingEngine`、RFC/modules/plan spec。

---

## 七、运行时验收（runbook 条目，顺位 13 阻塞依赖）

设备/模拟器手测（user device 职责，记录入 acceptance）：
1. 训练页长按主图 → 出现十字光标，**竖线落在最近蜡烛中心**（非手指原始 x），底部时间 label 对应该蜡烛。
2. 长按拖动 → 竖线在相邻蜡烛间**跳变吸附**（过中点跳），价格 label 随手指 Y **连续自由移动**。
3. 先 pinch 缩放（顺位 3）改变蜡烛密度，再长按 → 吸附仍落正确蜡烛中心（post-pinch 几何）。
4. 长按拖到主图区外 → 无光标；松手 → 光标消失。

---

## 八、风险与对策

| 风险 | 对策 |
|---|---|
| 整合 `resolve` 改 `CrosshairLayout` 公共面 | grep 证仅 `drawCrosshair` + 单测调用；二者均本锚 scope；非跨模块破坏 |
| nearest-center 浮点边界（过中点处 round 抖动） | verify-and-correct 邻居距离校正（D2）+ 测试 1 锁中点两侧；沿用 `xToIndex` 鲁棒先例 |
| post-pinch「双视口真相」 | 吸附用 `renderState.viewport`（post-pinch panelState 单一来源），不在 Coordinator 重算（D5.3）；测试 8 mutation-verify |
| 与顺位 4 画线（同轨 G、后续锚）冲突 | 顺位 5 仅碰 `CrosshairLayout`/`KLineView+Crosshair`；顺位 4 碰 `Drawing*`/reducer/投影，文件不相交；轨内串行 merge（outline §二） |
