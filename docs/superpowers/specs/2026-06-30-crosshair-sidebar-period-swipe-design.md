# RFC-C 长按十字光标 overlay + 单指竖滑切周期 — 设计文档（spec）

> 路线图：`docs/superpowers/2026-06-21-trade-ui-overhaul-roadmap.md` 顺位 4（C）。顺序 F✅→B✅→A✅→**C**→E。
> 视觉基准（实现须与之基本一致）：`docs/superpowers/mockups/rfc-c/crosshair-sidebar.html`（user 浏览器逐轮定稿）。
> 分支：`feat/crosshair-sidebar-period`（从 main `35a97ab` 切）。
> 性质：**纯视图 / 手势层**；十字光标是 view-layer 瞬态（不进引擎），周期切换复用既有 `switchPeriodCombo`。**零引擎行为、零契约改动**，不 bump `CONTRACT_VERSION`（保持 1.7，§9 论证）。
> 评审通道：Opus 4.8 xhigh 对抗 review（代 codex）。

---

## 1. 背景与目标

PR #128 后 user 真机/模拟器实测，提出训练界面十字光标与周期切换要对齐主流股票软件（同花顺/东方财富/文华财经）。RFC-B（已 merged）已做布局（坐标轴左移、顶栏、T2 交易条、画线浮动钮）；RFC-C 负责**长按十字光标交互**与**周期切换手势**两块——二者都改动同一个精细的 `ChartGestureArbiter`（C7，历经 15 轮评审），**一次性统一消歧**，避免两次碰仲裁面。

**总目标**：
1. 长按出十字光标后，**整图冻结**（不平移/缩放），只光标动；**黏滞**（松手保留，点击退出）。
2. 十字光标侧出**悬浮信息栏**（OHLC + 成交量/额 + 均价 + 涨跌 + 栏顶光标价），**自适应左右**躲手指。
3. 周期切换手势从「两指上下滑」改为「**单指竖滑**」（一甩切一档），两指捏合缩放保留。

成功判据（高层）：训练界面十字光标交互与 mockup 基本一致；host swift test（纯函数全断言）+ Mac Catalyst build + iOS app build 三绿；模拟器/真机人工验收按 §8 清单逐条通过；引擎行为字节级不变（§3 不变量）。

---

## 2. 范围（Scope）

### 2.1 IN — RFC-C 负责
- **C1 十字光标黏滞状态机**：长按进入 → 冻结该 panel → 拖动只移光标 → 松手黏滞保留 → 点击退出（§4.2）。
- **C2 光标视觉**：细**实线**十字；竖线**逐根吸附** K 线中心、横线跟手指 Y 自由；**光标中心 = 手指触摸点（无偏移）**；竖线贯穿整 panel、横线只在所触子图；左缘价标 + 底部时间标随光标（§4.2 / §4.4）。
- **C3 吸附震动**：拖动竖线**每吸附到新一根 K 线触发一次短 haptic**（§4.4）。
- **C4 单指竖滑切周期**：单指竖滑（一甩切一档，松手离散触发一次 + 最小阈值防误触）替换两指切周期；**两指捏合缩放保留**；复用 `switchPeriodCombo`（§4.3）。
- **C5 悬浮信息栏**：栏顶「光标价」+ 日期/时间/开高低收/涨跌/涨跌幅/均价/成交量/成交额；颜色规则（涨红/跌绿/平白 + 其余黄）；自适应左右停靠；双面板各显各（§4.5）。

### 2.2 OUT — 明确不做
- **运行时可调字号**：不做（现在/以后均不做；user 明确撤回）。字号固定可读。
- **换手率**：缺流通股本数据（`KLineCandle` 无字段、后端 CSV 无）→ 不做。
- **MA66 值进信息栏**：不做（user 选不放；MA66 是图上趋势线，≠均价）。
- **per-panel 画线 / 新画线工具**：不在 C。
- **引擎 / Coordinator 持久化 / 契约改动 / per-period 取价**：RFC-A 已定不做 per-period 价；C 不碰引擎行为。
- **设置 popover**：归 RFC-E。

### 2.3 性质与契约
- 0 后端 / 0 DDL / 0 持久化结构 / 0 引擎行为改动；纯 iOS 表现层 + 手势层 + 只读取值。
- 不 bump `CONTRACT_VERSION`（§9）。

---

## 3. 引擎 / 契约不变量（behavior-preserving，必须字节级保留）

C 是视图/手势重构。以下表面**调用点不得改语义**（接线调查 + 代码 map 核实）：

| 调用 / 状态 | 位置 | C 如何保留 |
|---|---|---|
| 周期切换 | `engine.switchPeriodCombo(direction:)`（TrainingEngine:321-339） | **原样调用**，只是触发源从「`onTwoFingerSwipe`」改为「单指竖滑」；方向语义 `PeriodDirection.toLarger/toSmaller` 不变 |
| 十字光标 | view-layer 瞬态：`Coordinator.crosshairPoint` → `RenderStateBuilder.make(crosshair:)` → `renderState.crosshairPoint`（不进 engine，D3 既定） | 仍 view-layer；新增「黏滞 + 冻结」也全在 view 层（Coordinator 状态 + arbiter 标志），**不进 engine** |
| 平移 / 缩放 | `engine.applyPan/applyPinch`（既有） | 冻结 = arbiter 在 crosshairMode 下**不发** `onPan/onPinch`；引擎调用签名不变，仅「不调用」 |
| 候选取值 | `candles[snappedIndex]`（`KLineCandle` 所有字段：OHLC/volume/amount）+ `mapper.yToPrice/indexToX`（既有几何） | 信息栏只**读取**渲染层已有切片与几何，零新 I/O、零引擎读 |
| 手势仲裁纯函数 | `GestureClassifiers.singlePanStep / twoFingerStep`（host 全测） | 单指竖滑路径在纯函数内消歧（host 可测）；两指机**最小改动**（§4.3 R 决策） |

**关键不变量**：
- 十字光标**不是 engine 契约**（RFC §7 契约不含 crosshair，view-layer D3）→ C 的黏滞/冻结/信息栏全不进 RFC 治理面。
- `switchPeriodCombo` 行为不变：仍只在阶梯 5 组合内移动、仍 `resetOffsetAfterAutoTracking`、仍 guard 两 panel 有数据。
- 冻结 = arbiter **抑制发射**，非引擎新增「锁」状态；引擎无感知。

---

## 4. 详细设计

### 4.0 受影响文件总览
- `ChartEngine/ChartGestureArbiter.swift`（UIKit 薄层）：加 `crosshairMode` 标志；新增 `onCrosshairMove`/`onCrosshairExit` 回调（或复用 `onTap`，plan 定）；crosshairMode 下抑制 `onPan/onPinch/onTwoFingerSwipe`；单指竖滑 → `onVerticalSwipe`；tap 在 crosshairMode 下触发退出。
- `ChartEngine/GestureClassifiers.swift`（纯函数，平台无关，host 全测）：`singlePanStep` 把「竖直」从 `verticalRejected`（现 no-op）改为**累积 → 松手按阈值发一次切周期**；新增/调整返回类型表达「竖滑切周期」emission。两指机 `twoFingerStep` **最小改动**（§4.3）。
- `ChartEngine/GestureRouting.swift`：竖滑方向 → `PeriodDirection` 映射（复用既有 up=toLarger/down=toSmaller 语义）。
- `Render/ChartContainerView.swift`（`Coordinator`）：十字光标**黏滞状态机**（enter/move/park/exit + 冻结标志）；接 `onCrosshairMove/onCrosshairExit`；接 `onVerticalSwipe → engine.switchPeriodCombo`；吸附 index 变化触发 haptic。
- `Render/CrosshairLayout.swift`（纯函数）：`resolve` **扩参收 `frames: ChartPanelFrames`**；**竖线改为贯穿整 panel**（`mainChart.minY` → `macdChart.maxY`，**改现状** 仅到 `mainChartFrame.maxY`）；**时间标移到 panel 最底部 `macdChart.maxY`**（**改现状** 现在主图区底/成交量上方）；沿用吸附；**价标全局移左缘**（与 `frames` 无关，§4.2，codex R4/R6）；视觉钉死细实线、无偏移。grep 证 `resolve` 仅 `drawCrosshair`+单测调用，扩参安全。
- 新增 `Render/CrosshairSidebarContent.swift`（纯值类型，平台无关，host 全测）：信息栏字段装配 + 格式化 + 均价单位自检 + 涨跌派生 + 颜色归类 + 左右停靠判定。
- `Render/KLineView+Crosshair.swift`（UIKit 薄层）：画细实线十字 + 渲染悬浮信息卡（调一次纯层结果）。
- 新增 haptic 封装（UIKit 薄层，`#if canImport(UIKit)`）：`UIImpactFeedbackGenerator(.light)` prepare/impact。
- 各对应 host 测试文件（§7）。

> 纯逻辑（值类型/几何/格式化/手势分类）抽 host 可测；UIKit 绘制/识别器/haptic 薄层靠 Catalyst build + 模拟器/真机人工验收。

### 4.1 手势消歧总表（核心 · 对抗 review 必查）

每个 `ChartContainerView`(.upper/.lower) 独立一套 arbiter + Coordinator。两个模式标志：`drawingMode`（既有，画线浮动钮切换）、`crosshairMode`（**新增**，长按进入/点击退出）。**二者互斥（双向，codex R5-M2）**：`drawingMode==true` 时长按不进十字光标（drawing 优先）；**进入画线模式时若 crosshair 黏滞则先 `exitCrosshair`**（`Coordinator.sync` 内）。**进入 crosshairMode 时立即 supersede 进行中的单指 pan**（发残量 + `.cancelled` 给 engine，关闭因长按前已激活 pan 而悬空的 pan/deceleration 状态，codex R5-M1）。

| 手势 | drawingMode | crosshairMode | 普通态（都 false） |
|---|---|---|---|
| **单指横滑** | 被绘线截获，不平移（既有） | **抑制**（图冻结，不平移） | 平移 `onPan`（既有） |
| **单指竖滑** | 被绘线截获 | **移动光标**（驱动 crosshairPoint；不切周期） | **切周期**（一甩一档，松手发一次，§4.3，**新**） |
| **单指长按** | 不进光标（drawing 优先） | 移动光标（`.changed`）/ 黏滞（`.ended` 不清） | **进入光标模式** + 冻结（`.began`，**新**） |
| **单指点击** | 落锚点 `onTap`（既有） | **退出光标** + 解冻（**新**） | no-op（既有） |
| **两指捏合** | —（少见） | **抑制**（不缩放） | 缩放 `onPinch`（既有，保留） |
| **两指竖滑** | — | **抑制** | **不再切周期**（移除；§4.3 R 决策，**改**） |

**判读优先级**：crosshairMode 为最高（一旦进入，单指全部喂光标、两指全抑制，仅 tap 退出）；其次 drawingMode；再普通态。横/竖单指消歧沿用既有阈值（`dx>dy*1.5`=横、`dy>dx*1.5`=竖、`<8pt`=ambiguous 待定）。

**长按 vs 竖滑时序消歧**：长按由 `UILongPressGestureRecognizer` 的**最小按压时长**触发（站定不动达时长 → 进光标）；快速竖滑在达时长前已移出长按移动容差 → 不触发长按、走竖滑切周期。二者由识别器的时长/移动容差自然分离（既有机制），plan 核实容差值。

### 4.2 十字光标黏滞状态机（C1/C2）

**状态**（view-layer，`Coordinator`）：`crosshairActive: Bool`、`crosshairPoint: CGPoint?`、`lastSnappedIndex: Int?`（haptic 去重用）。

| 事件 | 动作 |
|---|---|
| 长按 `.began`（且 `!drawingMode`） | `crosshairActive=true`；`arbiter.crosshairMode=true`；`crosshairPoint=location`；冻结（arbiter 抑制 pan/pinch/竖滑切周期）；起 haptic generator `prepare()`；设 `lastSnappedIndex` |
| 长按 `.changed` / crosshairMode 下单指拖动 | `crosshairPoint=location`；重算吸附 index，若 `≠lastSnappedIndex` → haptic + 更新 |
| 长按 `.ended/.cancelled` | **黏滞**：保留 `crosshairPoint` 与 `crosshairActive=true`（**不清**）；图仍冻结 |
| crosshairMode 下单指点击（tap） | **退出**：`crosshairActive=false`；`arbiter.crosshairMode=false`；`crosshairPoint=nil`；解冻；清 `lastSnappedIndex` |

**冻结语义**：crosshairMode 下 arbiter **不发** `onPan/onPinch/onTwoFingerSwipe/onVerticalSwipe` → 引擎 pan/zoom/切周期均不被调用 → 整图不动。另一 panel 不受影响（各自 arbiter）；pan-linkage（PR #127）因本 panel 不 pan 故不触发。

**光标几何**（沿用 C5/PR5 `CrosshairLayout.resolve`，仅改视觉）：
- 竖线 x = `indexToX(snappedIndex)`（最近中心 round + 两侧校正 + tie 取小 + clamp，既有）；横线 y = 手指原始 Y（自由）。
- **细实线**（去 PR5 之外可能的虚线呈现；本 RFC 钉死实线，线宽 `1/displayScale`）。
- **无偏移**：光标中心对齐手指触点（**撤销路线图旧决策 #4c「右偏保持」**——user 对照主流后改为无偏移）。
- **竖线贯穿整 panel**：从 `frames.mainChart.minY` 到 **`frames.macdChart.maxY`（整周期图最底部，穿过主图+成交量+MACD）**——⚠️ **改现状**（现 `resolve` 竖线只到 `mainChartFrame.maxY` = 主图区底/成交量上方）。**横线只在所触子图**（主图，跟手指 Y）。
- **时间标移到 panel 最底部 `frames.macdChart.maxY`（MACD 底部）**——⚠️ **改现状**（现时间标在 `mainChartFrame.maxY` = 成交量上方；user 真机确认）。时间标为高亮填充 tag，覆盖该 x 处底部时间轴标签（主流同款，不另避让）。
- **左缘价标** = `yToPrice(point.y)`（随横线 Y）——⚠️ **改现状**（原 C5 `resolve` 价标在右缘 `mainChartFrame.maxX`；RFC-B 已把价轴移左、本 RFC 把 crosshair 价标一并移左对齐价轴/mock，codex R4）；时间标文本 = `candles[snappedIndex].datetime`（随竖线吸附）。
- **frame 守卫不变**：长按仍仅在 `mainChart` 区生效（手指落主图蜡烛区才出光标）；竖线向下延伸只为参考，不改触发区。

**双面板**：长按 `.upper` → 上图 crosshairMode + 上图候选；`.lower` 同理。各 Coordinator 独立，结构上「点哪图显哪图」（代码 map 已证每 panel 独立 arbiter/crosshairPoint）。
- **跨面板互斥（2026-06-30 真机验收后加）**：**同时只一个图有十字光标**——进一个 panel 的光标 → 另一个 panel 自动退出（含其侧栏）。机制 = 共享 view-state `crosshairOwner: PanelId?`（`TrainingView` `@State` → 两 panel `@Binding`，**不进 engine**，守本 §「view-layer 瞬态」原则）：`enterCrosshair` 经 setter 宣示持有 → 另一 panel `sync` 见 `owner ≠ 自己` 即 `exitCrosshair(releaseOwnership:false)`；user 点击退出 / 进画线 → `releaseOwnership:true` 释放 owner（进画线的 owner 释放延后到 view-update 后，避免 update 期改 @State）。「点哪图显哪图」语义不变。

### 4.3 单指竖滑切周期（C4）

**触发**：普通态（`!crosshairMode && !drawingMode`）单指**竖滑**。沿用 `singlePanStep` 的「竖直」判定（`dy>dx*1.5`），但把现「`verticalRejected`（no-op）」改为：**累积竖直位移，松手 `.ended` 时若净竖移 ≥ 阈值 `T_swipe` → 发一次切周期** emission（方向：上滑=`toLarger`、下滑=`toSmaller`，复用 `GestureRouting`），`< T_swipe` → 不切（防误触）。**一甩切一档**（单次手势最多切一档，与现两指版离散语义一致）。

**替换两指（R 决策 · 最小化高风险仲裁改动）**：
- **选 R-A（推荐，最小 churn）**：**不改** `twoFingerStep` 分类器；仅在 `Coordinator` **取消** `onTwoFingerSwipe → switchPeriodCombo` 的接线（两指竖滑变 inert no-op）。新增单指竖滑 → 切周期。理由：`twoFingerStep` 是 15 轮评审的高危状态机，移除分支风险高于收益；「替换」的用户可见效果（两指不再切周期）由不接线达成。
- 备选 R-B（全移除两指 swipe 分支）：plan/对抗 review 若坚持「死能力须删」再评估；spec 默认 R-A。
- **两指捏合缩放保留**：`onPinch` 接线不动。

**阈值 `T_swipe`**：plan 阶段敲定具体点数（防误触 vs 灵敏）；host 测覆盖「净竖移 < T_swipe 不切 / ≥ T_swipe 切一档 / 方向正确 / 单次最多一档」。

### 4.4 吸附震动反馈（C3）

- 进入 crosshairMode 时 `UIImpactFeedbackGenerator(style: .light)` `prepare()`。
- 拖动重算吸附 `snappedIndex`，**仅当 `snappedIndex ≠ lastSnappedIndex`** 时 `impactOccurred()` + 更新 `lastSnappedIndex`（**每根一次，去重**；double-driving 同帧第二次见相同 index 不重发）。
- 平台门 `#if canImport(UIKit)`；macOS host 编译为空；haptic 行为靠真机人工验收（模拟器无触觉硬件）。
- haptic 去重逻辑（`snappedIndex` 变化判定）抽 host 可测纯谓词。

### 4.5 悬浮信息栏（C5）

新增纯值类型 `CrosshairSidebarContent`（平台无关，host 全测）：输入 = 吸附蜡烛 `KLineCandle` + 前一根（派生涨跌）+ 横线价 `yToPrice(point.y)` + period + 几何（停靠判定）；输出 = 有序字段行（标签/值串/颜色类）+ 停靠侧。

**字段（自上而下）**：
1. **栏顶实时价**（**无标签、居中大字**）= `yToPrice(横线 Y)`，纯纵轴读数，**与具体哪根 K 线无关**。
2. 日期 · 时间（**合并一行**：日期靠左、时间靠右）：`datetime`（UTC+8 / `en_US_POSIX`）；**日内周期（m3/m15/m60）显日期 + 「时:分」；daily/weekly/monthly 只显日期**（按 `period` 分支）。
3. 开 / 高 / 低 / 收：`open/high/low/close`。
4. 涨跌 / 涨跌幅：`close − prevClose` / `(close−prevClose)/prevClose`（基准 = **前一根收盘**）。**前收来源**：切片内取 `candles[idx-1]`；**最左可见根**（`idx==slice.startIndex` 但滚动后该根前面仍有历史）取切片外真实前收 `renderState.previousCloseBeforeVisible`（`RenderStateBuilder.make` 从 `engine.allCandles[period]` 完整数组算，codex R2-M）。仅**全序列第一根**（无更早数据）prevClose=nil → 显「—」+ 中性白。
5. 均价：`amount / volume`，**单位自检**：仅当 `amount != nil && volume > 0 && low ≤ 均价 ≤ high` 才显示，否则该行隐藏（fail-safe，防 A 股「手 vs 元」差 100 倍显假值）。
6. 成交量：`volume`（千分位 + **「股」**——importer 约定 `amount = close × volume` ⇒ volume 为 share-count、非「手」，codex R3）；成交额：`amount`（`nil` → 隐藏该行）。

**颜色规则**（user 定，**已网查证主流同基准**；**2026-06-30 真机验收后修订：所有价格字段方向上色**）：
- **方向色（涨=红 / 跌=绿 / 平=白）**：**栏顶实时价 + 开 / 高 / 低 / 收 + 涨跌 / 涨跌幅 + 均价**（**所有价格字段**）。基准 = **前一根收盘（prevClose）**——主流（同花顺/东财/通达信/文华财经）OHLC 各值与涨跌额/幅均 vs 前收上色（红涨判定 `CLOSE>REF(CLOSE,1)`；[东财帮助](https://qhweb.eastmoney.com/help/1217204.html) / [涨跌幅百科](https://baike.baidu.com/item/%E6%B6%A8%E8%B7%8C%E5%B9%85/8646206)）。slice 首根无 prevClose → 中性白 + 涨跌显「—」。
- **其余 = 黄色**：日期·时间、成交量、成交额（**非价格字段**）。
- 注：原 spec「开/高/低/均价=黄」是 brainstorming 初版决定；真机后 user 改为「所有价格按前收上色」对齐主流，本节为修订后权威。

**自适应左右停靠**：**吸附竖线 x（snappedX，非手指原始 x）**相对**主图水平中点**——`> 中点` → 栏靠左（`dockLeft`）；`≤ 中点` → 栏靠右（`dockRight`）。用竖线 x 保证与可见光标一致、确定性。**左右位置固定不跟手指 Y**（钉在顶角，防滑动抖动）。停靠判定（中点比较）为纯函数，host 可测。

**悬浮性**：overlay 浮于图层上、半透明、**不占固定面积**（不挤压 K 线区）；字号固定可读（标签 ~10pt / 光标价 ~13pt，具体 plan 定）；仅 crosshairMode 时渲染。

### 4.6 数据流

```
长按 .began（!drawingMode）
  → Coordinator: crosshairActive=true, crosshairMode=true（arbiter 冻结）, crosshairPoint=loc
  → RenderStateBuilder.make(crosshair: loc)（既有，post-pinch viewport 装配）
  → KLineView.draw → drawCrosshair(at: loc, viewport)
       ├─ CrosshairLayout.resolve(...) → snappedIndex / 竖线 x / 横线 y / 价标 / 时标（既有 + 细实线）
       │     └─ snappedIndex 变 → Coordinator haptic（每根一次）
       └─ CrosshairSidebarContent.make(candle, prev, yPrice, period, geometry)（新）
             → 字段行 + 颜色类 + 停靠侧 → KLineView+Crosshair 画悬浮卡
拖动（长按 .changed / crosshairMode 单指）→ 更新 loc → 重绘（图冻结）
松手 .ended → 黏滞保留
点击（crosshairMode）→ Coordinator: crosshairActive=false, crosshairMode=false, crosshairPoint=nil（解冻）

普通态单指竖滑 .ended（净竖移≥T_swipe）
  → onVerticalSwipe(dir) → Coordinator → engine.switchPeriodCombo(direction:)（既有，原样）
```

---

## 5. 组件边界与单一职责

- `CrosshairLayout`（纯层）：吸附几何 + 价/时标的唯一真相（既有，仅加细实线视觉契约）。
- `CrosshairSidebarContent`（纯层，**新**）：信息栏字段/格式化/派生/颜色/停靠的唯一真相；输入值类型、输出值类型，host 全测。
- `GestureClassifiers`（纯层）：单指竖滑→切周期 emission 的唯一真相（host 全测）。
- `ChartGestureArbiter`（UIKit 薄层）：读识别器 + crosshairMode 抑制/路由 + 触发回调，无业务几何判断。
- `Coordinator`（UIKit 薄层）：黏滞状态机 + haptic 去重 + 接线；状态转移的可抽纯谓词 host 测，识别器交互靠人工验收。
- `KLineView+Crosshair`（UIKit 薄层）：描边/绘字/画卡，调纯层结果，无几何判断。
- 依赖方向：薄层 → 纯层（单向）；纯层依赖既有值类型（`KLineCandle`/`CoordinateMapper`/`Period`）。

---

## 6. 错误处理 / 边界

- **slice 首根无 prevClose**：涨跌/涨跌幅显「—」、方向色退中性白（不崩、不显假涨跌）。
- **均价单位异常**（`amount==nil` 或 均价 ∉[low,high]）：隐藏均价行（fail-safe）。
- **amount==nil**：隐藏成交额行（不显 0 误导）。
- **crosshairMode 中切到另一 panel**：另一 panel 独立，不受影响；本 panel 仍冻结直到 tap 退出。
- **crosshairMode 中收到两指**：抑制（不缩放/不切周期），须先 tap 退出。
- **长按结于非主图区（成交量/MACD/坐标轴）**：**no-op**——不进光标、不冻结（守卫 `mainChartFrame.contains` 前置于状态置位，codex R1-M1）；拖动中出主图区则忽略本次移动、保留上次有效位置（不消失）。
- **长按未拖即松手**：光标黏滞在按点（snappedIndex 既定），信息栏显该根；tap 退出。
- **竖滑误触**：净竖移 < `T_swipe` 不切周期；横/竖 ambiguous（<8pt）不动作（既有）。
- **停靠临界**：竖线恰在主图水平中点 → 归 `dockRight`（`≤` 含等号，确定性，host 测）。
- **haptic 去重**：同根多事件只震一次（`snappedIndex` 变化守门）。
- **review 模式**：crosshair 长按仍可用（纯检视，无交易门）；竖滑切周期在 review 是否可用沿用现状（plan 核实 review 下 `switchPeriodCombo` 既有可达性，不新增门）。

---

## 7. 测试策略

- **Host 可测纯逻辑**（Swift Testing，全断言）：
  - `GestureClassifiers`：单指竖滑→切周期（净竖移 ≥/< `T_swipe`、方向 up/down、单次最多一档、横滑仍平移不切、ambiguous 不动作）；两指机回归（R-A 下 `twoFingerStep` 未改 → 既有断言全绿）。
  - `CrosshairSidebarContent`：字段顺序/格式化；日内显时分 vs 日/周/月只日期（按 period）；均价单位自检（落区间显 / 越界隐 / amount nil 隐）；涨跌派生（含首根无 prevClose → 「—」）；颜色归类（方向色 4 字段 + 其余黄 + 平=白 + 首根中性）；左右停靠（中点两侧 + 恰中点=右）。
  - `CrosshairLayout`：既有吸附断言回归（细实线不改几何）；haptic 去重谓词（snappedIndex 变化判定）。
  - **均价/价格等比浮点 host 断言用容差 / mirror mapper**（历史教训 [[feedback_swift_local_toolchain_blindspot]]）。
- **诚实声明无纯单元处**：黏滞状态机的识别器交互、冻结抑制、haptic 真触觉、震动手感 → 无可抽纯单元的部分由 §8 模拟器/真机人工验收覆盖（不臆造 host 测）。
- **构建验证**：`swift test` host 全绿（两框架：Swift Testing「末行」+ XCTest「All tests passed」都看，教训 per RFC-A）；Mac Catalyst `build-for-testing` SUCCEEDED；iOS app build 成功。
- **负向 grep 断言用 `if/exit 1` 非 `! grep`**（[[feedback_acceptance_grep_anchoring]]）。

---

## 8. 验收清单（非程序员可执行；action / expected / pass-fail；二值可判）

> 设备：模拟器 iPhone 17 Pro（udid `DE0BA39D-C749-459D-A407-4418599B61CA`）+ 真机（haptic）；DEBUG fixture（`SIMCTL_CHILD_KLINE_SEED_FIXTURE=1`）。改 fixture 后须 `simctl uninstall` 再装。证据：每条附截图，haptic 条附真机说明。

| # | 操作（action） | 预期（expected） | 通过判定（pass/fail） |
|---|---|---|---|
| 1 | 训练页长按上图主图 | 出现细实线十字光标，竖线落最近 K 线中心、**竖线贯穿整个周期图（主图+成交量+MACD）**、横线在手指 Y（仅主图）；**时间标在整图最底部（MACD 下方，非成交量上方）**；**整图冻结**（背景不平移/缩放） | 竖线贯穿三子图 + 时间标在最底 + 图不动 = pass；竖线只到主图/时间标在成交量上方/图动 = fail |
| 2 | 长按后保持按住、左右拖动 | 竖线逐根**跳变吸附**相邻 K 线；横线随手指上下；图始终不动 | 逐根吸附且图不动 = pass；连续不吸附或图动 = fail |
| 3 | 同上拖动（真机） | 每跨到下一根 K 线**有一次短震动**；停在同一根不重复震 | 每根一次震动 = pass；不震或乱震 = fail |
| 4 | 长按出光标后**松手抬指** | 光标**保留**在原位、信息栏仍显示（不消失） | 松手后光标/栏保留 = pass；松手即消失 = fail |
| 5 | 光标显示时**点一下屏幕** | 光标消失 + 信息栏收起 + 图恢复可平移/缩放 | 点击退出且恢复交互 = pass；点击无效 = fail |
| 6 | 长按使光标在主图**中心偏右** | 悬浮信息栏停靠**左侧** | 偏右→栏左 = pass；否则 fail |
| 7 | 长按使光标在主图**中心或偏左** | 悬浮信息栏停靠**右侧** | 偏左→栏右 = pass；否则 fail |
| 8 | 看信息栏字段 | 栏顶「光标价」+ 日期/时间/开/高/低/收/涨跌/涨跌幅/均价/成交量/成交额；日内显时分、日线只显日期 | 字段齐全且周期对应 = pass；缺失/错周期 = fail |
| 9 | 看信息栏颜色（涨 K 线 vs 跌 K 线各一次） | 光标价/收/涨跌/涨跌幅：涨红/跌绿/平白；日期/时间/开/高/低/均价/量/额：黄色 | 两类颜色规则都符 = pass；任一错 = fail |
| 10 | 上下滑动横线（竖线停同一根不动） | 栏顶「光标价」随横线纵轴读数变化；其值是纵轴价位（不等于该根收盘也正常） | 光标价随横线变 = pass；不变或乱跳 = fail |
| 11 | 长按**下图**（日线）主图 | 信息栏显**日线**那根明细（非上图 60 分） | 显下图周期数据 = pass；显上图 = fail |
| 12 | 普通态（无光标）**单指竖直一甩** | 周期切换一档（上滑变大/下滑变小）；横滑仍平移 | 竖滑切一档且横滑平移 = pass；不切或乱切 = fail |
| 13 | 普通态**两指竖滑** | **不再切周期**（两指捏合仍能缩放） | 两指竖滑无切周期 + 捏合能缩放 = pass；两指仍切周期 = fail |
| 14 | 均价单位异常构造（如 fixture amount 量级使均价越界）或正常 | 正常：显均价且落 [低,高]；异常：均价行隐藏（不显假值） | 落区间显/越界隐 = pass；显越界假值 = fail |
| 15 | 长按成交量/MACD/坐标轴区（非主图蜡烛区） | 不进入十字光标、图不冻结（仍可平移/缩放） | 子图区长按无反应 = pass；冻结或出隐形光标 = fail |
| 16 | 先右滚（更早历史移屏外）再长按**最左可见**那根 K 线 | 涨跌/涨跌幅显真实值（非「—」）、收/光标按真实前收上色 | 最左根显真实涨跌 = pass；显「—」/白 = fail |
| 17 | 十字光标**黏滞显示时**点画线浮动钮（✎）进入画线模式 | 光标消失、图恢复、之后点图落水平线锚点（非退光标） | 进画线退光标且点图落锚 = pass；点图退光标/落锚失败 = fail |
| 18 | 小幅横拖一点再按住进光标 → 松手 → 再正常拖图 | 后续平移正常（无残留 pan 状态卡死） | 平移正常 = pass；卡死/offset 异常 = fail |

---

## 9. 不 bump `CONTRACT_VERSION` 论证

`CONTRACT_VERSION` 钉持久化/跨端契约。C：0 DDL、0 持久化结构、0 序列化字段、0 后端、0 引擎**行为**、0 新 I/O；仅 iOS 表现层（十字光标视觉/信息栏）+ 手势层（消歧/路由）+ 只读取值（`candles[i]` 既有切片、`yToPrice` 既有几何）。`KLineRenderState` 加 additive 字段 `previousCloseBeforeVisible`——**纯视图渲染态、非持久化/跨端契约**，从既有 `engine.allCandles` 只读派生，零引擎改动。周期切换复用既有 `switchPeriodCombo`（行为不变）。十字光标本就 view-layer 瞬态（不进 engine、不进 RFC 7 契约）。无任何外部可观测契约变化 → **不 bump**（与 RFC-B / PR #122–128 UI 改版一致）。plan/impl 若发现需触持久化（不预期），回本节修订并 bump。

---

## 10. 风险 / 未决（plan 阶段消解）

- **R1 手势仲裁是高危面（C7 15 轮）**：crosshairMode 抑制 + 单指竖滑消歧改 `singlePanStep`/arbiter → 纯函数 host 测全覆盖（§7）；两指机走 R-A 最小 churn（§4.3）。plan 阶段逐状态列消歧表 + 杀手测试。
- **R2 双驱动光标**（长按 .changed 与 crosshairMode 单指 .changed 同帧都设 crosshairPoint）：同一手指位置幂等；haptic 由 `snappedIndex` 变化去重，双事件第二次见同 index 不重发。plan 钉死「单一 crosshairPoint 写入 + 去重谓词」。
- **R3 颜色基准 = 前一根收盘**：spec 定 prevClose 为方向色基准（光标价、收、涨跌同基准）；plan 核实与主流一致 + 首根 fail 安全（中性白 + 「—」）。若 user/review 要求改基准（如 vs open），plan 修订。
- **R4 均价单位**：A 股 volume「手」vs amount「元」差 100 倍 → 「均价∈[低,高]」自检兜底（§4.5）；plan 核实 fixture/真实数据的 volume 单位，决定是否需 ×100 归一（自检失败即隐，不会显假值）。
- **R5 `T_swipe` 阈值**：竖滑切周期的最小位移（防误触 vs 灵敏）plan 调值 + host 测边界。
- **R6 drawingMode × crosshairMode 互斥**：spec 定 drawing 优先（长按不进光标）；plan 核实切换时机无残留态。
- **R7 review 模式竖滑切周期可达性**：plan 核实 review 下 `switchPeriodCombo` 既有行为（不新增门、不改语义）。

---

## 11. 决策摘要（user 已拍，brainstorming 逐轮定稿）
1. 单指竖滑**替换**两指切周期；两指捏合缩放保留；**一甩切一档**（翻页式，松手离散一次 + 阈值防误触）。
2. 十字光标**黏滞模式**：长按进入 + 整图冻结 → 松手保留 → **点击退出**。
3. 光标**细实线**、**中心对齐手指触点（撤销旧 #4c 右偏）**；竖线逐根吸附、横线自由 Y。
4. 吸附**每根一次短 haptic**。
5. 信息栏字段：**栏顶实时价（无标签居中）** + 日期·时间（合并一行）+ 开高低收/涨跌/涨跌幅/均价/成交量/成交额；**换手率/MA66/可调字号不做**。
6. 颜色：**涨红/跌绿/平白**（栏顶实时价/收/涨跌/涨跌幅，基准=**前一根收盘**，已网查证主流同基准）；**其余黄**。
7. **自适应左右**：过主图水平中点 → 栏靠左，否则靠右；左右位置固定不跟手。
8. **均价** = 成交额÷成交量，[低,高] 单位自检过才显。
9. **零引擎/契约改动**，不 bump `CONTRACT_VERSION`（1.7）。

## 12. 真机验收修正记录（2026-06-30，user 真机发现 4 问题，3 修复 + 1 已设计内）
- **A 颜色**（§4.5 已改）：信息栏 开/高/低/均价 从黄改为按前收方向上色——所有价格字段统一方向色，对齐主流。
- **B 周期组合根因**：DEBUG fixture seed 的 `PendingTraining` 误设 `(m3, daily)`（**非 periodCombos 阶梯相邻档**）→ `switchPeriodCombo` 在 `firstIndex` 找不到当前组合直接 return → **单指竖滑永久 no-op**（user 报「切不动」）+ 默认显示非相邻档。修：`DebugFixtureData` seed pending 改 `(m60, daily)`（路线图 P1 默认）+ `DebugFixtureDataTests` 加「pending 组合须阶梯合法档」回归断言。⚠️ 纯 DEBUG fixture 改动；改 fixture 后真机/模拟器必须 uninstall 再装（空状态守卫）。手势链（singlePanStep→onVerticalSwipe→switchPeriodCombo）经核**接线全对**，无第二处 bug；唯一根因是非法默认组合。
- **C 双面板光标互斥**（§4.2 已加）：跨面板光标互斥（同时只一个图有光标），共享 view-state 不进 engine。
- **次要风险（记录，暂不改）**：慢速单指竖滑会先触发 0.5s 长按 → 进十字光标而非切周期（`UILongPressGestureRecognizer` 默认时长/容差）。组合修复后正常「一甩」可切；若慢滑仍困扰，再调长按阈值。
