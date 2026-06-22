# RFC-B 训练界面布局总重构 — 设计文档（spec）

> 路线图：`docs/superpowers/2026-06-21-trade-ui-overhaul-roadmap.md` 顺位 2。
> 视觉基准（实现必须与之基本一致，user 强制要求）：`docs/superpowers/mockups/rfc-b/training-layout-FINAL.html`。
> 决策来源（D1–D13 全 LOCKED）：`docs/superpowers/mockups/rfc-b/DECISIONS.md`。
> 分支：`feat/training-layout-overhaul`。
> 性质：**纯 UI / 布局重构**；不改引擎行为；预计**不 bump `CONTRACT_VERSION`**（§11 论证）。
> 评审通道：Opus 4.8 xhigh 对抗 review（代 codex）。

---

## 1. 背景与目标

PR #128 后 user 真机/模拟器实测，训练界面布局与主流股票软件（同花顺/东方财富）有差距。**总目标：把训练界面布局对齐主流，最大化 K 线显示区，且不改任何交易/引擎行为。** 交易玩法重做、长按十字光标、设置 popover 分别由后续 RFC-A/C/E 负责。

成功判据（高层）：训练界面渲染结果与 `training-layout-FINAL.html` 基本一致；host swift test + Mac Catalyst build + app build 三绿；模拟器人工验收按 §10 清单逐条通过；引擎行为字节级不变（§3 不变量）。

---

## 2. 范围（Scope）

### 2.1 IN — RFC-B 负责
- **D8/D11/D12 整屏框架**：两图严格等高最大化 + 顶栏固定 + 底部 T2 薄交易条 + 画线浮动按钮；mock 用带灵动岛 iPhone 框、内容落安全区下。
- **D4 顶栏重构**：固定高度；返回(左)/标的名(中)/结束(右) 顶行；5 指标格（总资金/持仓成本/股/持仓股数/仓位/浮动盈亏）标签上数值下、**每格居中对称**、宽度按最坏值预留（总资金 8 位、持仓股数 7 位）。
- **D4 持仓成本语义修正**：显示从总额（`engine.holdingCost`）改为**每股**（`position.averageCost`，引擎已有）。
- **D5 标的名隐显**：训练隐藏（占位文案）/ 复盘·再训练显示真实 `stockName(stockCode)`。
- **D1 坐标轴**：价/时间/周期标签去不透明底框改透明文字（加描边防糊）；**价轴(纵)从右移到左**（不挡最右最新 K 线）；周期标移右上；时间轴仍在底部。
- **D7 指标曲线加深加粗**：MA66 / BOLL 三轨 / MACD DIF·DEA 线宽加粗 + 颜色加深（具体值见 §4.4）。
- **D2 画线浮动控件**：顶栏「水平线」开关钮 → 浮动可拖动圆按钮，点开展开工具条、可拖动、手动点才收回。
- **D10/D3(布局部分) 交易控件回收**：去掉两 panel 内的两侧 `tradeButtons` 列；独立底部「结束本局」条移除（结束上移顶栏）→ 新增**统一底部 T2 薄条**（显示 active 周期+下单价 + 买入/卖出/持有），绑定 active panel；保留 tier 档位条机制与引擎调用。
- **D6 结束按钮**：右上角红描边药丸（候选 C）。

### 2.2 OUT — 明确不在 RFC-B（归 A/C/E）
- **每周期独立取价 / 数量框 +/- / 1/5..5/5→股数 / 复利接续 / 重置资金 → RFC-A**。B **不改定价模型**（见 §5）。
- **长按十字光标 overlay 侧栏（OHLCV/换手率/自适应左右）→ RFC-C**。
- **主页设置 popover → RFC-E**。
- **新画线工具（趋势线/黄金分割/波浪…）/ 画线支持 per-panel → 不做**（B 保留 `.horizontal` on `.upper` 现状；工具条布局上可扩展但 B 只挂现有水平线工具，不上线非功能按钮）。
- **持仓成本「含税费」口径正确性 → RFC-A**（B 仅改显示口径为每股；`averageCost` 是否已含免5/规费由 A 保证）。

### 2.3 性质与契约
- 0 后端 / 0 DDL / 0 持久化结构改动；纯 iOS 表现层 + 只读取值。
- 不 bump `CONTRACT_VERSION`（§11）。

---

## 3. 引擎不变量（behavior-preserving，必须字节级保留）

B 是布局重构。以下引擎/lifecycle 表面**调用点不得改语义**（来自接线调查）：

| 调用 | 签名 / 位置 | B 如何保留 |
|---|---|---|
| 买入 | `engine.buy(panel: PanelId, tier: PositionTier) -> Result<TradeOperation, AppError>` | T2 薄条「买入」→ 弹现有 tier 条 → 选档 → 原样调用，`panel` 取自新 `activePanel` |
| 卖出 | `engine.sell(panel:tier:)` 同上 | 同上 |
| 持有/观察 | `engine.holdOrObserve(panel: PanelId)` | T2 薄条「持有」直接调用，`panel` 取 `activePanel` |
| 买卖使能 | `engine.buyEnabled` / `engine.sellEnabled` | 控件 `.disabled` 沿用 |
| 持仓 | `engine.position.shares` / `engine.position.averageCost` | 读取显示；股数=label 与 sell 守卫；averageCost=每股成本显示 |
| 结束本局 | `engine.forceCloseManually() -> Bool` + `routeEndOfSession()` | 结束药丸 → `confirmingEnd` → `endManually()` 原链路 |
| 画线 | `engine.activateDrawingTool(.horizontal, panel: .upper)` / `engine.cancelDrawing(panel: .upper)` | 浮动按钮调用同签名、同 `.upper` |
| flow 门 | `engine.flow.canBuySell()` / `.canAdvance()` / `.mode` | `showsTradeButtons` 等 gating 沿用 |

**关键不变量**：
- 交易价仍为**全局** `currentPrice`（`.m3` 驱动序列在 `tick.globalTickIndex` 的收盘，TrainingEngine:256-258/552-557）。B 不引入 per-panel 价。
- `panel` 参数语义不变：只影响①记录 period ②推进步数（`stepsForPeriod`）。
- tier 仍为 `PositionTier` 枚举（5 档，tier5=全仓/清仓），非裸 index。

### 3.1 新增「只读表面」（additive accessor，零行为、零新 I/O、不 bump；R1-H1/H2 + R2-H2 修正）
1. **价**：`public var currentPrice: Double { ... }`——`TrainingEngine.currentPrice` 现为 `private`（TrainingEngine:256），加只读 public 镜像供 T2 显示。已核：:256 是纯 computed 读、无副作用 → 加 public 镜像**零行为**。**不改取值逻辑**（仍 `.m3` 全局价）。
2. **标的名（R2-H2 + R3-H 修正：retain 已加载 record，零新 I/O）**：名字**只在 review/replay 显示**。已核真实加载路径：
   - `review(recordId:)`（coordinator:244）：`loadRecordBundle(id:)`（:245）已加载完整 `(record,ops,drawings)`，装进 `.review(record:)`（`ReviewFlow.record` 为 `public let`，TrainingFlowController:56）。
   - `replay(recordId:)`（coordinator:283）：**同样 `loadRecordBundle` 加载了完整 record**，但只取 `record.feeSnapshot` 装进 `ReplayFlow`（无 record 字段），**record 被丢弃**。⚠️ **不可**用 `replaySettlementPayload`（:405-410，含 `loadMeta()` 磁盘读）当名字源——那是新 I/O 反模式。
   - **统一 grounded 出口**：coordinator 加 `public private(set) var activeRecord: TrainingRecord?`（与现有 `activeEngine`/`activeReader` 同款，coordinator:30-31），在 review()/replay() 用**那个本就加载好的 `record`** 存一份（**零新 I/O**，record 两路都已在内存）；`TrainingSessionLifecycle` 透出 → 顶栏读 `activeRecord?.stockName/stockCode`。`TrainingRecord.stockName/stockCode` 为**非可选 `String`**（`TrainingRecord` 定义见 `AppState.swift`）。
   - normal（盲测）：`activeRecord==nil` → 名字隐藏=占位，**不需要任何名字源**。
   - 复用既有 `formatStock(name:code:)`（`HistoryActionContent`/`HomeContent`/`SettlementContent` 已用）做全角括号格式化。
- 二者均属 §11「additive read-only，无外部契约面、无新 I/O」，不 bump `CONTRACT_VERSION`。

---

## 4. 详细设计（按 zone）

### 4.0 受影响文件总览
- `UI/TrainingView.swift`（root VStack、topBar、panel、tradeButtons、tradeStrip overlay、bottomBar、toggleDrawing、新增 `activePanel` 状态）。
- `UI/TrainingTopBarContent.swift`（顶栏值类型：新增字段/格式化，每股成本、股数、名称、宽度策略）。
- `UI/TradeBarView.swift`（tier 条 —— 触发点改由 T2 薄条；视图本身基本不变）。
- 新增：`UI/TradeActionBar*.swift`（T2 底部薄条视图 + 纯值类型，含周期分段钮）、`UI/DrawingToolFloatingView*.swift`（画线浮动控件 + 拖动/折叠 clamp 纯逻辑）。
- 只读访问器（§3.1，零行为、零新 I/O）：`TrainingEngine.swift`（加 `public var currentPrice` 只读镜像）；`TrainingSessionCoordinator.swift`（加 `public private(set) var activeRecord: TrainingRecord?`，review()/replay() 用已加载 record 存一份）；`TrainingSessionLifecycle.swift`（透出 activeRecord）。**不**新增 meta/磁盘加载。
- `Render/AxisGridLayout.swift`（价标 x 坐标改左缘；周期标移右上；去底框）。
- `Render/KLineView+AxisGrid.swift` / `Render/KLineView+Crosshair.swift`（`drawLabelBox` 去背景填充，仅留文字+描边）。
- `Render/KLineView+Candles.swift`（MA66/BOLL 线宽）、`Render/KLineView+MACD.swift`（DIF/DEA 线宽）、`Theme/Theme.swift`（指标色加深）。

> 每个文件的纯逻辑（值类型/几何/格式化）抽出做 host 可测；UIKit 绘制薄层 + SwiftUI 组合靠 Catalyst build + 模拟器人工验收。

### 4.1 整屏框架（D8/D11/D12）
root `VStack(spacing:0)`：`header` → `panel(.upper)` → `panelDivider(1px)` → `panel(.lower)` → `tradeActionBar`（T2，仅 `showsTradeButtons` 时）。
- **两图严格等高**：两 `panel` 各 `frame(maxHeight:.infinity)` 平分；T2 薄条与 header 在两图之外（不偏吃下图）。**校验**：上下 panel 高度差 = 0（§10 验收逐像素/快照）。
- 图内 60/15/25（主图/量/MACD）= `ChartPanelFrames.split`，**保持不变**（D13）。
- 安全区：内容在 `header` 之上由 SwiftUI safe area 处理；mock 框示意灵动岛/状态栏/home indicator，仅为可视化基准，不需 app 改 safe-area 逻辑（SwiftUI 默认已避让）。

### 4.2 顶栏（D4/D5/D6）
固定高度 header，两段：
1. **顶行**：`返回`(左, `lifecycle.back()`) / `标的名`(中) / `结束`(右, 红描边药丸 → `confirmingEnd=true`)。去掉之前的设置齿轮与误加方块。
2. **指标行**：`HStack` 5 格，每格 `VStack(居中)`：标签(上, ~8.5pt) / 数值(下, ~12pt 居中)。
   - 宽度策略（防最坏值重叠）：总资金格预留 8 位 `¥99,999,999`；持仓股数格预留 7 位 `9,999,999 股`；持仓成本/股、仓位、浮动盈亏量级有限。**每格内容居中对称**，数字多少位都对称、不撑邻格。
   - 字段与取值：
     - 总资金 = `engine.currentTotalCapital`（格式化 `¥` + 千分位，8 位不撑宽）。
     - **持仓成本/股 = `engine.position.averageCost`**（每股；替换原 `engine.holdingCost` 总额）。`shares==0` 时 `averageCost==0` → 显示 `¥ 0.00`（与现 formatter 一致）。
     - 持仓股数 = `engine.position.shares`（千分位 + " 股"）。
     - 仓位 = `仓位 X/5`（沿用现 `positionTier`）。
     - 浮动盈亏 = `returnRate`（沿用现，含 ±0 归一 `+0.00%`）。
- **D5 标的名隐显**（R2-H2 修正：名字源自已加载 record，非新增 meta 注入）：
  - 规则：正常训练（盲测，`activeRecord==nil`）→ 显示占位「训练标的 · 盲测」（不泄露真名，**无需任何名字源**）；**review / replay**（`activeRecord!=nil`）→ 显示 `formatStock(activeRecord.stockName, activeRecord.stockCode)`（复用既有 helper，全角括号）。
  - 名字源 = coordinator `activeRecord`（§3.1.2）= review/replay **已在内存、零新 I/O retain** 的 `TrainingRecord`；`stockName/stockCode` 非可选 `String`，review/replay 下**恒有值**。
  - 注：因非可选，review/replay 名字恒在 → 不设「nil fail-closed」分支（那将是不可达死代码，R2-M）；§10#10 只验真名显示。判隐显用 `activeRecord==nil`（=正常训练）vs `!=nil`（=review/replay）。

### 4.3 坐标轴透明无框 + 价轴移左（D1）
- `drawLabelBox`（`KLineView+Crosshair.swift`）：**去掉背景填充矩形**，只留文字 + 细描边/阴影（`shadow`/双描边，防糊在 K 线上不可读）。crosshair 的 label 同样去底框（保持与轴一致；crosshair 交互本体属 RFC-C，此处仅去底框不改交互）。
- `AxisGridLayout`：
  - 价标 x：从右缘 → **左缘**（`frames.mainChart.minX + pad`，右对齐改左对齐）。candle 绘制区左内边距相应让出价标宽度，确保不压最左 K 线（或价标浮于左侧透明、K 线占满——二选一在 plan 定，优先「浮于上层透明、K 线占满」以最大化面积，与 mock 一致）。
  - 周期标（`periodLabel`）：从左上 → **右上**（避让左侧价标）。
  - 时间标：仍在 MACD 底部，去底框透明。
- **可读性硬约束**：透明文字必须在深/浅主题与红绿 K 线背景上都可读（描边/阴影），§10 验收人工确认。

### 4.4 指标曲线加深加粗（D7）
现状全部 `1/displayScale`（≈1px）、无区分。目标加粗加深（**以下为锁定目标值，§10#5 据此二值判定；plan 若调任一值须同步改 §10#5**）：
- MA66：线宽 `2/displayScale`，颜色加深（`Theme.ma66` 提饱和，紫）。
- BOLL 上/中/下：线宽 `1.6/displayScale`，中轨实线、上下轨虚线保留；颜色加深（琥珀）。
- MACD DIF/DEA：线宽 `1.8/displayScale`；DIF 白、DEA 黄加深。
- 成交量柱、MACD 柱：维持（红绿）。
- **非整除浮点等比 host 测试必须用容差**（历史教训 [[feedback_swift_local_toolchain_blindspot]]）。线宽若以 `CGFloat` 字面比值出现，host 断言用容差。

### 4.5 画线浮动控件（D2）
- 移除 topBar 的「水平线/结束画线」开关钮。
- 新增浮动控件（overlay 于图层之上）：
  - 折叠态 = 圆按钮（✎），可**拖动**到屏内任意位置（位置 clamp 在安全可视区内 = 纯逻辑，host 可测）。
  - 点 ✎ **展开**为工具条（含现有水平线工具入口 + 折叠图标）；展开保持，**仅手动点折叠图标才收回**（不自动收）。
  - 工具条**布局上为未来工具预留**，但 B 只挂 `.horizontal`，不放非功能按钮。
- 行为保留：工具激活/取消仍调 `engine.activateDrawingTool(.horizontal, panel: .upper)` / `cancelDrawing(panel: .upper)`；anchor 仍靠点击图表（`ChartContainerView` 现有 `handleDrawingTap`，不改）。
- **review 模式 gating（R1-M2）**：浮动 ✎ 控件**仅 `showsTradeButtons==true` 时渲染**（= 现 topBar 开关钮同一门 `engine.flow.canBuySell()`，TrainingView:165-168）；review 模式不出现。
- **无障碍（R1-M2）**：✎ 折叠按钮 `accessibilityLabel("画线工具")`；展开后水平线工具 `accessibilityLabel("水平线")`、折叠图标 `accessibilityLabel("收起画线工具")`。
- ⚠️ 画线仍 **upper-only**（保留现状）；per-panel 画线不在 B。

### 4.6 交易控件 T2 + active-panel 绑定（D10 / D3 布局部分）
- **删除**：两 `panel` 内右侧 `tradeButtons` VStack 列；独立 `bottomBar`（仅含结束本局）整体移除，结束按钮上移顶栏（见 4.2）。
- **新增 T2 底部薄条**（`tradeActionBar`，~38pt，仅 `showsTradeButtons`）：
  - 左：**周期分段钮 `[上图周期 | 下图周期]`**（如 `60分 | 日线`）= **active-panel 切换器**（见下）+ 中性价标 **`下单价 ¥<currentPrice>`**。
  - 右：买入 / 卖出 / 持有 三钮。买入/卖出 `.disabled(!buyEnabled/!sellEnabled)`；持有 label = `shares>0 ? 持有 : 观察`。
  - **无障碍**：三钮 `accessibilityLabel` = 「买入」「卖出」「持有/观察」；分段钮 = 「下单周期：<周期>」。
- **价标措辞（R1-M1）**：B 用**中性**「下单价 ¥…」，**不**用 FINAL mock 里的「日线下单价」字样——因 B 阶段价为全局价、与周期无关，写「日线下单价」=对用户撒谎。mock 的「日线下单价」是 **A 时代措辞**（A 落地 per-period 价后才成立）。此为 §1「与 mock 基本一致」的**显式例外**（措辞层，非布局层）。
- **active-panel 切换 = T2 条分段钮（R1-H3 改方案，避开手势雷区）**：
  - 现状单击事件被 `ChartGestureArbiter.handleTap` 独占且仅 `drawingMode` 时触发（:185-188），非画线态无单击路径。**「点图切 active」需新加手势识别器/SwiftUI tap，会与已稳定的 UIKit 仲裁冲突（C7 历经 16 轮）→ B 不做。**
  - 改用 **T2 条上的周期分段钮**切换 `@State activePanel: PanelId`（默认 `.lower`）；选中端高亮对应 panel（红描边 inset）。**零手势改动**。D3 本就允许「控件上 60分|日线 切换钮」。
  - 买入/卖出 → 弹**现有 tier 条**：`tradeStrip = TradeStripRequest(panel: activePanel, action:)`，overlay 仍按 `strip.panel==id` 落 active panel 底部；选档 → `performTrade(action, panel: activePanel, tier:)` → `engine.buy/sell(panel:tier:)`（原样）。
  - 持有 → `engine.holdOrObserve(panel: activePanel)`。
- **保留**：`tradeStrip` 状态、`performTrade`、haptic/toast、autosave、`ChartGestureArbiter` 全不动（画线点击 anchor 路径不变）。
- ⚠️ 与现状的唯一交互差异：买卖入口从「两侧各 panel 的按钮」→「统一薄条 + 分段钮选 active」。语义等价（`panel` 仍传引擎）。§10 验收：upper/lower 分别 active 时买卖，记录 period 与推进步数与旧版一致；且**画线模式下点图仍是落 anchor、不切 active**。

### 4.7 结束 / 返回（D6）
- 返回：顶栏左，`lifecycle.back()`（不变）。
- 结束：顶栏右红描边药丸 → `confirmingEnd` → `confirmationDialog` → `endManually()`（链路不变）。

---

## 5. B/A 边界澄清（关键、对抗 review 必查点）

**B 不改定价模型。** 现状买卖价 = 全局 `.m3` 当前 tick 收盘（与点哪个 panel 无关）。D3「每周期取各自最后一根 K 线收盘」是**引擎行为改动**，归 **RFC-A**。

B 在此只做两件**布局/显示**事：
1. 控件统一到 T2 薄条 + `activePanel`（分段钮选）绑定（`panel` 参数本就由引擎接收，B 只换 `panel` 的来源 = activePanel，不新增定价语义）。
2. 薄条用**中性**「下单价 ¥…」显示当前**全局**价 + 周期分段钮标出 active 周期。**不写「<周期>下单价」**（避免对用户声称一个尚不存在的 per-period 价）。A 落地 per-period 价后，措辞可升级为「该周期价」。

→ spec 不承诺 B 阶段「不同周期不同价」。该承诺由 RFC-A 兑现。user 已在 D3 同意取价规则归 A。
→ **与 mock 的差异（显式记录）**：FINAL mock 印「日线下单价 ¥1,680」属 A 时代措辞；B 实现取**中性措辞**，是 §1「与 mock 基本一致」在措辞层的有意例外（布局/位置仍照 mock）。

---

## 6. 数据流 / 新增状态

- `@State activePanel: PanelId`（TrainingView，默认 `.lower`）——交易目标 panel；**由 T2 条周期分段钮更新**（不靠点图，R1-H3）；驱动高亮 + 传给 buy/sell/holdOrObserve/tradeStrip。
- 新增只读访问器（§3.1）：`TrainingEngine.currentPrice`（public 只读镜像，供 T2 显示）；`TrainingSessionCoordinator.activeRecord`（review/replay retain 已加载 record，lifecycle 透出供顶栏标的名）。均零行为、零新 I/O。
- 画线浮动控件位置 `@State drawToolOffset: CGPoint` + 展开态 `@State drawToolExpanded: Bool`——纯 UI 状态；位置 clamp 逻辑抽纯函数 host 测。
- 顶栏值类型 `TrainingTopBarContent` 扩展：加 `stockNameDisplay: String?`（隐显规则结果）、`holdingCostPerShare`（每股）、`shares`（格式化）字段；格式化函数 host 测（千分位 / 8 位 / 7 位 / 占位）。
- 无新增引擎状态；无新增持久化。

---

## 7. 错误处理 / 边界

- 顶栏最坏值（总资金 `¥99,999,999`、持仓股数 `9,999,999 股`、仓位 `5/5`、盈亏 `+24.68%`/极端负）→ 不重叠、不换行、居中对称（§10 验收用最坏值）。
- `shares==0`：持仓成本/股显示 `0.00` 或 `—`（plan 定，与现状 `¥0.00` 一致优先）；卖出禁用；持有 label=「观察」。
- 透明轴文字在浅色主题 + 红绿满屏 K 线下的可读性（描边/阴影必到位）。
- review 模式 `showsTradeButtons=false`：无 T2 薄条、无画线浮动钮、无结束（沿用现 gating）；顶栏显示真实标的名。
- 画线浮动控件拖动 clamp：不可拖出可视区、不可遮死顶栏/T2 条核心按钮（位置 clamp 纯函数测）。

---

## 8. 测试策略

- **Host 可测纯逻辑**（Swift Testing）：
  - `TrainingTopBarContent` 格式化（8 位总资金千分位、每股成本、`shares==0`→`¥ 0.00`、7 位股数、±0 归一、`activeRecord==nil`→占位名 / `!=nil`→真实名 的隐显选择）。**确有纯逻辑可测**。
  - 画线浮动控件位置 clamp 纯函数（拖出边界回弹）。**确有纯逻辑可测**。
  - 轴几何：`AxisGridLayout` 价标 x 落在左缘、周期标在右上（断言坐标，容差）。**`AxisGridLayout` 是纯值类型，确可测**。
  - **active-panel：诚实声明无可抽纯单元**——它是 `@State` + 直传引擎的普通 SwiftUI 状态（R1-M3），不臆造 host 测试；由 §10#7 模拟器验收覆盖。
- **构建验证**：`swift test` host 全绿；Mac Catalyst `build-for-testing` SUCCEEDED；iOS app build 成功。
- **模拟器人工验收**：§10 清单逐条（iPhone 17 Pro，DEBUG fixture）。
- 历史教训：等比浮点 host 断言用容差；负向 grep 断言用 `if/exit 1` 非 `! grep`（[[feedback_acceptance_grep_anchoring]]）。

---

## 9. 不在范围的已知问题（不在 B 修，记录）
- 交易仍全局价（A 修）。
- `averageCost` 是否含税费（A 保证）。
- 画线 upper-only（未来增强）。
- DrawingToolType 有 7 枚举但仅 horizontal 接线（A/后续）。

---

## 10. 验收清单（非程序员可执行；action / expected / pass-fail；二值可判）

> 设备：模拟器 iPhone 17 Pro（udid `DE0BA39D-C749-459D-A407-4418599B61CA`），DEBUG fixture（`SIMCTL_CHILD_KLINE_SEED_FIXTURE=1`）。改 fixture 后须 `simctl uninstall` 再装。证据：每条附截图。

| # | 操作（action） | 预期（expected） | 通过判定（pass/fail） |
|---|---|---|---|
| 1 | 进入训练界面 | 顶栏固定一行返回(左)/标的名(中)/结束红药丸(右)；下方 5 指标格标签上数值下、居中 | 三件套位置正确且 5 格不重叠 = pass；任一重叠/缺失 = fail |
| 2 | 观察上下两个 K 线图 | 上下两图高度肉眼相等 | 截图量两图像素高度差 ≤ 2px = pass；否则 fail |
| 3 | 观察价轴数字 | 价格数字在图**左侧**、透明无底框、不遮挡最右最新 K 线 | 最右 K 线完整可见且价标无实心底框 = pass；底框遮挡 = fail |
| 4 | 观察周期标 / 时间轴 | 周期标在主图右上；时间标在 MACD 底部、透明 | 位置与透明均符 = pass；否则 fail |
| 5 | 查源码/截图量 MA66/BOLL/MACD 线宽（对照 §4.4 目标值） | MA66=`2/displayScale`、BOLL 三轨=`1.6/displayScale`、MACD DIF/DEA=`1.8/displayScale`；色为紫/琥珀/白黄 | 三类线宽各等于目标值（任一仍为 `1/displayScale` 即 fail）且配色符 = pass；否则 fail |
| 6 | 点屏幕左上「✎」并拖动 | 出现可拖动圆按钮；拖到别处停住；点开展开工具条；再点折叠图标收回 | 拖动+展开+手动收回三动作均生效 = pass；任一失效 = fail |
| 7 | T2 条分段钮切到「上图(60分)」点「买入」选 2/5；再切「下图(日线)」同样买入 | 分段钮选中端对应图高亮；买入弹 1/5..5/5 档条；选档成交；60分记 60 分、日线记日线（推进步数随之） | 两周期各自成交且记录 period/步数与旧版一致 = pass；行为变化 = fail |
| 8 | 顶栏「持仓成本/股」（持仓 >0 与 =0 两种） | 持仓>0 显示**每股**成本（价位级，如 1,683.50）；持仓=0 显示 `¥ 0.00` | 两种取值均符 = pass；显示为总额(万级)或 0 时异常 = fail |
| 9 | 顶格压测：构造大额（资金千万级 / 股数百万级） | 总资金 8 位、持仓股数 7 位均不撑宽、不换行、不与邻格重叠 | 无重叠/换行 = pass；否则 fail |
| 10 | 复盘(review)与 replay 各进入 | 顶栏显真实 `标的名（代码）`（取自已加载 record）；无 T2 薄条/画线钮/结束 | review 与 replay 均显真实名且交易控件按 review 隐藏 = pass；任一不符 = fail |
| 11 | 正常训练（盲测）进入 | 顶栏标的名为占位「训练标的 · 盲测」（不泄露真名） | 占位显示 = pass；泄露真名 = fail |
| 12 | 进入画线模式后点图表 | 落下水平线 anchor（**不**切换 active panel） | 点击落 anchor 且 active 不变 = pass；点击改 active 或不落 anchor = fail |
| 13 | 浅色与深色外观各进训练页 | 两种外观下左侧价标/时间标透明文字在红绿 K 线上均清晰可读（描边/阴影生效） | 两外观均可读 = pass；任一外观糊住读不清 = fail |

---

## 11. 不 bump `CONTRACT_VERSION` 论证

`CONTRACT_VERSION` 钉持久化/跨端契约。B：0 DDL、0 持久化结构、0 序列化字段、0 后端、0 引擎**行为**、**0 新 I/O**；仅 iOS 表现层重排 + 只读取值。新增表面**仅 additive 只读**（§3.1）：`currentPrice` public 镜像（值逻辑不变）；`activeRecord` 留存 review/replay **本就已 `loadRecordBundle` 到内存**的 record（retain 已加载对象，**零新 I/O**；R3-H 已核 review:283/replay:283 两路都已加载）。`stockName`/`averageCost` 数值本就存在，只是之前未透出到训练 UI——均不进入任何持久化/序列化/跨端契约面。无任何外部可观测契约变化 → **不 bump**（与 PR #122–128 UI 改版一致）。plan/impl 阶段若发现需触持久化结构（不预期），回到本节修订并 bump。

---

## 12. 风险 / 未决（plan 阶段消解）
- ~~R1 标的名 meta→UI 可达性~~ → **已消解**（R2 再修正）：名字源自 review/replay 已加载 `record.stockName/code`，零新 I/O、零 nil 分支（§3.1.2/§4.2）。
- R2 价轴移左与 K 线占满区的内边距取舍（浮于上层 vs 让出 gutter）——优先浮于上层占满，plan 定细节，§10#3 验收兜底。
- R3 透明轴文字浅色主题可读性（描边方案 plan 定，§10#3/#4/#13 双外观人工验收）。
- ~~R4 「点 panel 即改 active」手势冲突~~ → **已消解**：改用 T2 条周期分段钮切 active，零手势改动（R1-H3 修正）；画线点击 anchor 路径不变（§10#12 兜底）。

## 13. R1 对抗 review 修正记录（spec 自身可追溯）
R1（Opus 4.8 xhigh，target blob `ac6efc8a`）判 NEEDS-ATTENTION，3H/4M/3L 全部成立、已修：
- H1 `currentPrice` 私有 → §3.1.1 加 public 只读镜像。
- H2 标的名路径缺失 → §3.1.2/§4.2 落实 `activeMeta` 注入 + §10#10 fail-closed。
- H3 点图切 active 撞手势仲裁 → §4.6 改 T2 条分段钮，零手势改动。
- M1 mock「日线下单价」误导 → §4.6/§5 改中性「下单价」措辞 + 记差异。
- M2 a11y/review-gating → §4.5/§4.6 补 accessibilityLabel + 浮动钮 `showsTradeButtons` 门。
- M3 测试性夸大 → §8 诚实声明 active-panel 无纯单元。
- M4 §10#5「明显更粗」不可二值 → 改对照 §4.4 数值线宽。
- L1 shares==0 取值 → §4.2 钉 `¥ 0.00` + §10#8 覆盖。
- L2 双主题验收缺 → §10#13 新增。
- L3 两图等高 1px divider 取整 → §10#2 容差 ≤2px 已吸收（无需改）。

### R2 对抗 review 修正记录（target blob `0f0e73e1`）
R2 判 NEEDS-ATTENTION，1H/1M（其余 R1 修正全 verified sound），已修：
- **H2** `activeMeta` 统一注入与真实加载路径不符（review/resume 加载时不调 `loadMeta()`），强行统一会给 review 加新 I/O = 真行为改动 → **改**：名字只在 review/replay 显示，直接复用**已加载 record** 的非可选 `stockName/stockCode`（§3.1.2/§4.2/§6/§11）；normal 占位不需名字源。**零新 I/O**。
- **M** §10#10「构造 activeMeta==nil」不可执行（record.stockName 非可选恒有值）→ 删 nil fail-closed 死分支，§10#10 改为「review 与 replay 均显真实名」。
- R2 verified sound（无需改）：H1 currentPrice 纯读、H3 分段钮真避手势仲裁、M1 中性措辞无矛盾、M2/M3/M4/L1/L2 均到位、coordinator `@MainActor @Observable` 无并发竞态、`averageCost` 每股语义正确。

### R3 对抗 review 修正记录（target blob `b3a042c5`）
R3 判 NEEDS-ATTENTION，1H/1M/1L（其余全 verified sound），已修：
- **H** R2 修对了 review（`ReviewFlow.record` public let 零 I/O 可达），但 **replay 破**：`ReplayFlow` 无 record、:283 加载的 record 被丢，错引 `replaySettlementPayload`(含 `loadMeta()` 新 I/O)。→ **改**：coordinator 加 `activeRecord` 留存 review/replay **本就已加载**的 record（零新 I/O），统一两路（§3.1.2/§4.2/§6/§4.0/§11）。已核 review:283/replay:283 两路均 `loadRecordBundle` 加载完整 record。
- **M** §8 漏删的 `activeMeta==nil` fail-closed host 测残留 → 改为 `activeRecord==nil`→占位 / `!=nil`→真名 的隐显选择（§8）。
- **L** TrainingRecord 行号引用错（在 `AppState.swift` 非 `Models.swift`）→ §3.1.2 改为「`TrainingRecord` 定义见 `AppState.swift`」。
- R3 verified sound：currentPrice 纯读、formatStock 复用、T2 分段钮避手势、§10 其余行二值可判、B/A 边界一致。
