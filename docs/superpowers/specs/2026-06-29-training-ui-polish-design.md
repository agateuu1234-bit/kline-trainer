# 训练界面验收回归微调（顶栏空间 + 指标加粗 + fixture 周期比例）设计

> RFC-A（已 merge PR #132）真机验收时 user 提的一批界面微调。基准 = **现网代码**（main `8b7a6c2` 之后），非任何 mockup（mockup 仅设计预览，已知与代码有漂移）。
> 关联 [[project_trade_ui_backlog_2026_06_21]]。设计 mockup：`docs/superpowers/mockups/2026-06-29-rfc-a-topbar-on-rfcb.html`（基于 RFC-B 定稿改顶栏 + 真实底栏 + 加粗指标）。

## 1. 目标

三组互相独立的微调，打包为一个验收回归 PR：
- **顶栏空间优化**：顶栏一行挤不下大数字（尤其浮动盈亏常被截），改数字格式 + 布局，让最坏值也放得下。
- **DEBUG fixture 周期比例修正**：周/月线聚合 span 与真实日历比例不符（周线1根≈日线2根，应≈5根）。
- **技术指标线再加粗**：MA66/BOLL/MACD 线 RFC-B 已加粗一轮，仍偏细，再加粗。

## 2. 范围

**做（本 spec）**：① 顶栏（`TrainingTopBarContent` + `TrainingView.topBar`）；② fixture 周期 span（`DebugFixtureData`，DEBUG only）；③ 指标线宽（`KLineView+Candles` MA66/BOLL + `KLineView+MACD`）。

**不做（明确排除）**：复盘从初始位置进入 + 往后浏览（单独排期，与 replay 续局一起设计）；交易框/交易条逻辑；引擎/资金/持久层；坐标轴/蜡烛/十字线样式。

## 3. Part 1 — 顶栏空间优化（生产 UI，host 可测纯值 + UIKit 薄层）

### 3.1 数字格式（`TrainingTopBarContent`）

现状（`TrainingTopBarContent.swift`）：`currency(_)` = `¥ ` + POSIX 千分位 + **强制 2 位小数**；`totalCapital`/`holdingCostPerShare` 都用它；`holdingPnL` = `signedCurrency(金额) (percent(%))` 单串。

改为：

| 字段 | 现状 | 新 |
|---|---|---|
| `totalCapital` 总资金 | `¥ 99,999,999.00`（2 位） | **无小数** `¥99,999,999`（整数千分位） |
| `holdingCostPerShare` 成本/股 | `¥ 1,683.50`（2 位） | **保留 2 位**（要跟实时价比，不变） |
| `sharesText` 股数 | `9,999,999 股` | **无小数 + 去「股」后缀** `9,999,999`（标签已写「股数」） |
| `positionShort` 仓位 | `5/5` | 不变 |
| 浮动盈亏 金额 | （见下） | **无小数** `+¥12,345,678`（带正负号） |
| 浮动盈亏 百分比 | （见下） | **保留 2 位** `+4,900.00%`（signed-zero `-0.0→+0.00%` 归一，沿用现 `percent`） |

- 新增整数货币 helper（如 `currencyInt(_)` / `signedCurrencyInt(_)`）= `¥`/带符号 + 千分位 + **0 位小数**；`holdingCostPerShare` 仍用现有 2 位 `currency`。
- ¥ 与数字之间空格：现状 `¥ `（一空格）。新整数版**去掉空格** `¥99,999,999`（更紧凑，mockup 即此）。`holdingCostPerShare` 的 `¥ ` 是否同步去空格 = 实现细节（建议一并去，口径统一），spec 不强制。

### 3.2 浮动盈亏拆字段 + 两行渲染（#3 + 方案 C）

- `TrainingTopBarContent` 把 `holdingPnL` 单串**拆成两个字段**：`holdingPnLAmount`（如 `+¥12,345,678`，无小数带符号）+ `holdingPnLPercent`（如 `+4,900.00%`，2 位 signed-zero 归一）。0 持仓 → `+¥0` / `+0.00%`（沿用现 `shares>0 && averageCost>0` 守卫）。
- 公式不变：金额 = `(currentPrice − averageCost) × shares`；百分比 = `(currentPrice − averageCost) / averageCost`。
- 顶栏视图把这两个字段**叠两行**显示（金额上 / 百分比下），**去括号、去斜杠**。
- **颜色**：盈=**红**（`up`）、亏=**绿**（`down`），沿用红涨绿跌（与蜡烛/现 `.mv.up` 同源 palette，**不是**西式绿盈）。

### 3.3 布局 + 对齐（`TrainingView.topBar` / `metricCell`）

- **标签简化**：「持仓成本/股」→「成本/股」、「持仓股数」→「股数」。
- **格宽收窄**（现 `metricCell` 固定宽 96/72/86/40 + 浮动盈亏弹性）→ 收窄前 4 格、把富余让给浮动盈亏弹性末格。参考值（实现按真机微调）：总资金 ~84 / 成本 ~56 / 股数 ~62 / 仓位 ~30 / 浮动盈亏 = 弹性。
- **对齐（user 明确）**：
  - 所有格**标签顶部齐头**（同一 Y，像表头行）。
  - 标签下方数值区：**单行数字**（总资金/成本/股数/仓位）在数值区里**上下居中**；浮动盈亏**两行**（金额/百分比）也在数值区居中。
  - **所有格等高**（由浮动盈亏两行撑高）。
  - 即：现 `metricCell` 的「整块居中」改为「标签固定顶部 + 数值区填满剩余且内容垂直居中」；行内各格等高、标签齐平。

### 3.4 顶栏高度 + 图表（如实记录）

- 浮动盈亏两行使顶栏第二行比现状**高约一行文字（~12–14pt）**；这是方案 C「永不截断」的代价（user 已知并接受）。
- 两图 panel 均 `maxHeight: .infinity` → SwiftUI **自动均分剩余竖向空间** → 顶栏增高后两图各缩约一半、**仍等高**（框架处理奇数零头，无需手工 +1pt）。T2 交易条高度不变。

## 4. Part 2 — DEBUG fixture 周期比例修正（#5，`#if DEBUG` only，零生产影响）

`DebugFixtureData.make` 用固定 span 聚合 m3：现 `weekly=160`、`monthly=240`，与真实日历比例不符（A 股 240 分/日 → 日线=80 m3；周=5 交易日=400；月≈20 交易日≈1600）。现状 daily 240/weekly 120/monthly 80 根 = 各周期跨度不一（日 1 年、周 2.3 年、月 6.7 年），故「周线1根≈日线2根」。

**改聚合 span 为真实日历比例**：
- **weekly span 160 → 400**（= 5×日线）、**monthly span 240 → 1600**（= 20×日线）。m15=5/m60=20/daily=80 不变。

**连锁约束（必须一并处理，否则破坏 fixture 不变量）**：
1. **新 `lcm(spans)` = lcm(5,20,80,400,1600) = 1600**（旧为 480）。`fullLoadM3Count` 与 `fullLoadBeforeM3Count` **都须为 1600 的倍数**（保证「各周期 before/after 边界落在该周期 candle 边界」不变量，line 47-48）。
   - `fullLoadM3Count = 19,200` = 1600×12 ✓（**不变**）。
   - `fullLoadBeforeM3Count = 12,000` = 1600×7.5 ✗ → 改 **12,800**（=1600×8；daily-before 160≈旧 150，仍 < 19,200）。原「daily before=150 对齐 spec §8.3」放宽为「对齐新 lcm」（fixture 内部参数，无外部契约）。
2. **新根数（fullLoad 19,200）**：日线 **240** / 周线 **48** / 月线 **12**——**各周期均≈1 年、比例正确**（240 交易日≈1 年、48 周≈1 年、12 月=1 年）。月线 12 根**是真实的**（真实月线图本就只十几根），非「太少」；推翻旧注释「monthly≥80」的人为约束（那是旧小 span 的产物）。
3. **更新代码注释**（line 44-49 的 fullLoad 推导说明：lcm 480→1600、根数、约束）+ **fixture 测试**（凡断言旧 weekly=120/monthly=80 的，改 48/12；before-对齐测试若有，改 12,800/新 lcm）。
- 生产 `import_csv`（按真实 datetime 聚合）**本就正确、不动**。仅改 DEBUG fixture。
- **m60 周期对**（实现阶段一并做，不在 spec 分支预改）：fixture 开局 pending 的 `upperPeriod: .m3 → .m60`（与 `lowerPeriod: .daily` 相邻、对齐生产默认 m60/daily + periodCombos 阶梯；原 m3/daily 不相邻）。真机验收时临时改过验证可行，正式实现纳入本批 Part 2。

## 5. Part 3 — 技术指标线再加粗（#6，生产渲染）

`setLineWidth(x / displayScale)`：

| 指标 | 文件:行 | 现 | 新 |
|---|---|---|---|
| MA66（紫实线） | `KLineView+Candles.swift:36`（`drawMA66`） | 2 | **3** |
| BOLL 上/中/下（琥珀虚线） | `KLineView+Candles.swift:54`（`drawBOLL`） | 1.6 | **2.2** |
| MACD DIF·DEA（白/黄线） | `KLineView+MACD.swift:27` | 1.8 | **2.4** |

- 蜡烛实体/影线（`:17` 的 1）、坐标轴/网格（`+AxisGrid`）、十字线（`+Crosshair`）**不动**。
- BOLL 虚线 dash 不变（只改线宽）。

## 6. 影响文件 + CONTRACT_VERSION

- `TrainingTopBarContent.swift` — 格式 helper + 拆 holdingPnL 两字段 + 各字段口径（host 全测）。
- `TrainingView.swift` — `topBar` 标签/宽度 + 浮动盈亏两行渲染 + 对齐（UIKit 守卫，Catalyst/iOS build 闸门）。
- `DebugFixtureData.swift` — weekly/monthly span。
- `KLineView+Candles.swift` / `KLineView+MACD.swift` — 线宽常量。
- `TrainingTopBarContentTests.swift`（host）、相关测试更新。

**CONTRACT_VERSION：不 bump**。`TrainingTopBarContent` 是 UI 纯展示值、仅 `TrainingView` 同模块消费；拆字段/改格式无持久化 / schema / 跨模块契约语义变更。指标线宽、fixture span 同理。（spec 阶段 codex 复核此判断。）

## 7. 测试策略

- **顶栏纯值**（host）：`TrainingTopBarContent` 各字段格式逐字断言——总资金/股数/浮动盈亏金额无小数；成本/股、浮动盈亏% 2 位；浮动盈亏拆两字段值正确；盈/亏/平/0 持仓四态；signed-zero 归一；最坏值（千万级 + 几十倍）不崩。FP 断言用容差或字符串等值（选值为精确二进制浮点）。
- **顶栏布局/对齐 + 浮动盈亏两行 + 颜色**：SwiftUI 视图行为，host 不可测 → iOS Simulator/Catalyst build 闸门 + §8 人工验收（沿用 RFC-A UI 壳惯例）。
- **fixture span**（host，Persistence）：断言 weekly 根数 ≈ m3Count/400、monthly ≈ m3Count/1600，且 weekly/daily 根数比 ≈ 1:5、monthly/daily ≈ 1:20（或直接断言聚合 span 常量）。
- **指标线宽**：常量改动，渲染行为 host 不可测 → build 闸门 + 人工验收（曲线明显更粗）。

## 8. 验收清单（模拟器/真机，非程序员可执行）

| # | 操作 | 预期 | pass/fail |
|---|---|---|---|
| 1 | 顶栏满仓大数字（总资金千万、股数千万、浮动盈亏千万+几十倍） | 总资金/股数/浮动盈亏金额**无小数**；成本/股、浮动盈亏%**两位小数** | 符合=pass |
| 2 | 看浮动盈亏格 | **金额一行、百分比一行**两行；**盈红亏绿**；不截断/不省略 | 两行+颜色对=pass |
| 3 | 看顶栏标签行 | 总资金/成本/股/股数/仓位/浮动盈亏 标签**齐头同高**；单行数字在格内**上下居中** | 齐头+居中=pass |
| 4 | 看上下两图 | 高度仍**相等**；顶栏略增高但图未明显变形 | 两图等高=pass |
| 5 | 切到周线/日线对比 | 1 根周线 ≈ **5 根**日线（非 2 根）；月线≈20 日线 | 比例对=pass |
| 6 | 看 MA66/BOLL/MACD 线 | 比改前**明显更粗**、醒目 | 更粗=pass |

## 9. 非目标

复盘初始位置/浏览、交易逻辑、坐标轴样式、生产周期聚合（已正确）、CONTRACT_VERSION bump。
