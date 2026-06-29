# 训练界面验收回归微调（顶栏空间 + 指标加粗）设计

## 0. 文档状态 / 范围（codex spec-R3）

**本文件 = 设计文档（brainstorming 产物），非实现。** 当前分支 `feat/training-ui-polish` 在 spec 阶段**只含本 spec + canonical mockup**，**刻意不含**任何生产代码/测试改动。实现按既定 superpowers 流程在**同一分支后续提交**：本 spec 收敛 → `writing-plans` 出实现计划 → `subagent-driven-development` 逐任务实现 + host 测 → 三绿（host/Catalyst/iOS build）→ **whole-branch Codex review 审实现**（那一关才校验 §6 命名文件 + 测试齐全）→ PR。本 spec-阶段 review 仅审**设计质量**；分支**实现完成前不 merge**。§2「做」列的是本批待实现项，非「本分支已交付」。

> RFC-A（已 merge PR #132）真机验收时 user 提的一批界面微调。基准 = **现网代码**（main `8b7a6c2` 之后），非任何 mockup（mockup 仅设计预览，已知与代码有漂移）。
> 关联 [[project_trade_ui_backlog_2026_06_21]]。设计 mockup：`docs/superpowers/mockups/2026-06-29-rfc-a-topbar-on-rfcb.html`（基于 RFC-B 定稿改顶栏 + 真实底栏 + 加粗指标）。

## 1. 目标

两组互相独立的微调，打包为一个验收回归 PR：
- **顶栏空间优化**：顶栏一行挤不下大数字（尤其浮动盈亏常被截），改数字格式 + 布局，让最坏值也放得下。
- **技术指标线再加粗**：MA66/BOLL/MACD 线 RFC-B 已加粗一轮，仍偏细，再加粗。

> **DEBUG fixture 周期比例（#5）+ m60 周期对：本批移除**（codex spec-R4 揭示真实代价超预期——见 §9）。

## 2. 范围

**做（本 spec）**：① 顶栏（`TrainingTopBarContent` + `TrainingView.topBar`）；② 指标线宽（`KLineView+Candles` MA66/BOLL + `KLineView+MACD`）。

**不做（明确排除）**：**DEBUG fixture 周期比例 + m60 周期对（#5，移到单独排期，见 §9）**；复盘从初始位置进入 + 往后浏览（单独排期，与 replay 续局一起设计）；交易框/交易条逻辑；引擎/资金/持久层；坐标轴/蜡烛/十字线样式。

## 3. Part 1 — 顶栏空间优化（生产 UI，host 可测纯值 + UIKit 薄层）

### 3.1 数字格式（`TrainingTopBarContent`）

现状（`TrainingTopBarContent.swift`）：`currency(_)` = `¥ ` + POSIX 千分位 + **强制 2 位小数**；`totalCapital`/`holdingCostPerShare` 都用它；`holdingPnL` = `signedCurrency(金额) (percent(%))` 单串。

改为：

| 字段 | 现状 | 新 |
|---|---|---|
| `totalCapital` 总资金 | `¥ 99,999,999.00`（2 位） | **无小数** `¥99,999,999`（整数千分位） |
| `holdingCostPerShare` 成本/股 | `¥ 1,683.50`（2 位） | **保留 2 位、去掉 `¥`** → `1,683.50`（对齐 canonical mockup + 省宽防 56pt 格截断；「成本/股」标签已表明是价。codex plan-R1） |
| `sharesText` 股数 | `9,999,999 股` | **无小数 + 去「股」后缀** `9,999,999`（标签已写「股数」） |
| `positionShort` 仓位 | `5/5` | 不变 |
| 浮动盈亏 金额 | （见下） | **无小数** `+¥12,345,678`（带正负号） |
| 浮动盈亏 百分比 | （见下） | **保留 2 位** `+4,900.00%`（signed-zero `-0.0→+0.00%` 归一，沿用现 `percent`） |

- 新增整数货币 helper（如 `currencyInt(_)` / `signedCurrencyInt(_)`）= `¥`/带符号 + 千分位 + **0 位小数**；`holdingCostPerShare` 仍用现有 2 位 `currency`。
- ¥ 与数字之间空格：新整数版 `totalCapital`/`holdingPnLAmount` = `¥` 紧贴数字无空格（`¥99,999,999`）。`holdingCostPerShare` **完全去 ¥**（见上表）。
- **防截断（codex plan-R1 / r4）**：顶栏所有数值 `Text` 加 `minimumScaleFactor` + `lineLimit(1)`——固定宽格遇超长值**缩放而非省略号**；§8#1 最坏值人工验收**附截图**证明不截断。
  - 固定格用 `0.8`（其宽固定、内容必合）；**浮动盈亏弹性格用 `0.5`** 作窄屏安全网。
  - **设备底线 = 375pt**（部署目标 iOS 17.6 → 最小设备 iPhone SE2/3，无 320pt 设备）：内容宽 375−24=351，固定格 84+56+62+30=232 → PnL 弹性余量≈**119pt**，worst-case `+¥12,345,678` 满刻度(~85pt)即放得下、**受支持设备永不触发缩放**；`0.5` 仅保任意更窄屏（codex r4 假设的 320pt）也不截断。

### 3.2 浮动盈亏拆字段 + 两行渲染（#3 + 方案 C）

- `TrainingTopBarContent` 把 `holdingPnL` 单串**拆成两个字段**：`holdingPnLAmount`（如 `+¥12,345,678`，无小数带符号）+ `holdingPnLPercent`（如 `+4,900.00%`，2 位 signed-zero 归一）。0 持仓 → `+¥0` / `+0.00%`（沿用现 `shares>0 && averageCost>0` 守卫）。
- 公式不变：金额 = `(currentPrice − averageCost) × shares`；百分比 = `(currentPrice − averageCost) / averageCost`。
- 顶栏视图把这两个字段**叠两行**显示（金额上 / 百分比下），**去括号、去斜杠**。
- **颜色**：盈=**红**（`up`）、亏=**绿**（`down`），沿用红涨绿跌（与蜡烛/现 `.mv.up` 同源 palette，**不是**西式绿盈）。

### 3.3 布局 + 对齐（`TrainingView.topBar` / `metricCell`）

- **标签简化**：「持仓成本/股」→「成本/股」、「持仓股数」→「股数」。
- **横向均匀分布（方案 A，真机验收修正 / user 选 A）**：浮动盈亏改两行后**纵向**已腾空间，**不再横向收窄**其余格给它让位。旧做法（前 4 格固定窄 84/56/62/30 + 浮动盈亏 `flex/maxWidth:.infinity` **吃光剩余**）→ PnL 格偏宽显空、左侧偏挤、不均匀。
  - 改为：**每格按各自 worst-case 内容定宽**（留够极限值）+ **格间等距 `Spacer`** 把剩余横向空间**均匀摊到各间隙**（PnL 不再独吞）；自适应屏宽（宽屏间隙等比增大）。**浮动盈亏格也定宽**（非 `maxWidth:.infinity`）。
  - worst-case 参考定宽（实现按真机微调）：总资金 ~80（`¥10,000,000`）/ 成本/股 ~56（`8,888.88`）/ 股数 ~64（`9,999,999`）/ 仓位 ~28（`5/5`）/ 浮动盈亏 ~92（`+¥12,345,678` 两行较宽行）。Σ定宽≈320 + 4×min间隙 ≤ 最小受支持设备 375pt 内容宽 351，可容。
  - `metricRowH=44` 固定有界高、各格等高、对齐口径不变（见下）。`minimumScaleFactor` 防截断不变（固定格 0.8 / PnL 0.5）。
- **对齐（user 明确）**：
  - 所有格**标签顶部齐头**（同一 Y，像表头行）。
  - 标签下方数值区：**单行数字**（总资金/成本/股数/仓位）在数值区里**上下居中**；浮动盈亏**两行**（金额/百分比）也在数值区居中。
  - **所有格等高**（由浮动盈亏两行撑高）。
  - 即：现 `metricCell` 的「整块居中」改为「标签固定顶部 + 数值区填满剩余且内容垂直居中」；行内各格等高、标签齐平。

### 3.4 顶栏高度 + 图表（如实记录）

- 浮动盈亏两行使顶栏第二行比现状**高约一行文字（~12–14pt）**；这是方案 C「永不截断」的代价（user 已知并接受）。
- **指标行用固定有界高度**（`metricRowH≈44pt`），**绝不用 `maxHeight: .infinity`**（codex plan-R2：顶栏与两个贪婪 `maxHeight:.infinity` 图表 panel 同级，若指标格无界会跟图表抢竖向空间致大幅塌缩）。固定高 = 顶栏只确定性增高这一点点。
- 两图 panel 均 `maxHeight: .infinity` → SwiftUI **自动均分剩余竖向空间** → 顶栏增高后两图各缩约一半、**仍等高**（框架处理奇数零头，无需手工 +1pt）。T2 交易条高度不变。

### 3.5 「本局盈亏」语义重定义（真机验收新增 / user 确认）

- **问题**：原「浮动盈亏」= **持仓级**未实现盈亏（`(现价−持仓均价)×股数`），只反映当前未平仓那一笔。user 要的是**整局级**总盈亏：开局本金（如 10 万）起，不管中间买卖/平仓多少次，实时显示「现在一共比开局赚/亏了多少」（**含已实现 + 未实现**）。
- **改动（零引擎改动，引擎已具备）**：
  - **标签** 「浮动盈亏」→ **「本局盈亏」**。
  - **金额** = `engine.currentTotalCapital − engine.initialCapital`（`currentTotalCapital = 现金 + 持仓股数×现价`，实时盯市；`initialCapital` = 本局开局本金/`accumulatedCapital`）。
  - **百分比** = `engine.returnRate`（= `(currentTotalCapital − initialCapital)/initialCapital`，引擎已算好；**不再**用持仓收益率 `(现价−均价)/均价`）。
  - **字段重命名**：`holdingPnLAmount/Percent/Sign` → `sessionPnLAmount/Percent/Sign`（语义已变，名须准；in-module 重构）。
  - `TrainingTopBarContent` 新增入参 `initialCapital: Double`；**移除** `currentPrice` 入参（改后仅 session 公式不再用它，删死参）。`totalCapital`（已是 `currentTotalCapital`）、`returnRate`（已传入）复用。
- **沿用不变**：盈=红 亏=绿（红涨绿跌、scheme-aware palette）；两行（金额/百分比）；舍入到 ¥0 → 整格持平 `+¥0`/`+0.00%`/中性；非有限 → 退化 `—`/`—`/sign 0；`minimumScaleFactor`、固定有界高、均匀分布（方案A）全不变。
- **不 bump** CONTRACT_VERSION（纯展示值、in-module、零持久化）。

## 4. Part 2 — 技术指标线再加粗（#6，生产渲染）

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
- `KLineView+Candles.swift` / `KLineView+MACD.swift` — 线宽常量。
- `TrainingTopBarContentTests.swift`（host）、相关测试更新。

**CONTRACT_VERSION：不 bump（codex plan-R5 复核，有据）**。
- m01 的 `CONTRACT_VERSION` 文义 = 只 gate **跨系统 / 破坏性持久化 / schema** 变更（两次先例 1.4→1.5 E2 `position_data` reader 收紧、1.6→1.7 RFC-A `settings.total_capital` 语义 + migration 0005，**均为持久/reader 语义**）。它**不是** gate 每个 public Swift 符号。
- `TrainingTopBarContent` 是 **UI 纯展示值类型**，`public` 仅为 host 可测；**grep 证实唯一消费者 = `TrainingView`（同 `KlineTrainerContracts` 模块）+ 其测试**，app target（`ios/KlineTrainer`）与 `KlineTrainerPersistence` **均无引用**（无 persistence / DTO / 跨 target / 外部消费者）。
- 拆 `holdingPnL` 为三字段 = **in-module 源级重构**，零持久化 / schema / 跨系统影响 → **不在 CONTRACT_VERSION gate 范围**。单 SwiftPM target 整体编译，无部分编译 version-skew。指标线宽同理。

## 7. 测试策略

- **顶栏纯值**（host）：`TrainingTopBarContent` 各字段格式逐字断言——总资金/股数/浮动盈亏金额无小数；成本/股、浮动盈亏% 2 位；浮动盈亏拆两字段值正确；盈/亏/平/0 持仓四态；signed-zero 归一；最坏值（千万级 + 几十倍）不崩。FP 断言用容差或字符串等值（选值为精确二进制浮点）。
- **顶栏布局/对齐 + 浮动盈亏两行 + 颜色**：SwiftUI 视图行为，host 不可测 → iOS Simulator/Catalyst build 闸门 + §8 人工验收（沿用 RFC-A UI 壳惯例）。
- **指标线宽**：常量改动，渲染行为 host 不可测 → build 闸门 + 人工验收（曲线明显更粗）。

## 8. 验收清单（模拟器/真机，非程序员可执行）

| # | 操作 | 预期 | pass/fail |
|---|---|---|---|
| 1 | 顶栏满仓大数字（总资金千万、股数千万、浮动盈亏千万+几十倍） | 总资金/股数/浮动盈亏金额**无小数**；成本/股、浮动盈亏%**两位小数** | 符合=pass |
| 2 | 看浮动盈亏格 | **金额一行、百分比一行**两行；**盈红亏绿**；不截断/不省略 | 两行+颜色对=pass |
| 3 | 看顶栏标签行 | 总资金/成本/股/股数/仓位/浮动盈亏 标签**齐头同高**；单行数字在格内**上下居中** | 齐头+居中=pass |
| 4 | 看上下两图 | 高度仍**相等**；顶栏略增高但图未明显变形 | 两图等高=pass |
| 5 | 看 MA66/BOLL/MACD 线 | 比改前**明显更粗**、醒目 | 更粗=pass |

## 9. 非目标 + 移出本批（单独排期）

- **DEBUG fixture 周期比例（#5）+ m60 周期对**：移出本批。codex spec-R4 揭示真实代价超预期——fixture 不变量要求**每周期 ≥ defaultVisibleCount(80) 根 + 每周期 MA66 warmup（`rows[65].ma66 != nil`，需 ≥66 根）**；旧 span（monthly=240）正是反推自「19,200/240=80」。日历精确的 monthly=1600 要满足「≥80 月线根」需 m3Count ≥ 80×1600 = **128,000**（现 19,200 的 6.7×）→ DEBUG seed 显著变大、开局变慢。**紧凑 fixture（≥80根/周期）与日历精确比例根本矛盾**。**生产数据（真实 NAS 经 `import_csv` 按 datetime 聚合）比例本就正确**，仅 DEBUG 假数据有此妥协。→ user 拍板**本批去掉 #5**；将来若要修需专门设计放大 fixture（或放宽 ≥80/周期约束），单独走流程。m60 周期对（trivial，但属 fixture 范畴）一并随该任务做。
- 其它非目标：复盘初始位置/浏览、交易逻辑、坐标轴样式、生产周期聚合（已正确）、CONTRACT_VERSION bump。
