# RFC-A 交易/仓位/资金对齐主流 — 设计文档（spec）

> 路线图：`docs/superpowers/2026-06-21-trade-ui-overhaul-roadmap.md` 顺位 3（RFC-A）。
> 前置：RFC-F（`fd7ab64`）、RFC-B 训练界面布局总重构（`e8e9d60` PR #131）已 merge。本 RFC 在 RFC-B 布局基础上做**交易玩法**改造，不改 RFC-B 的任何布局。
> 分支：`feat/trade-position-capital`。
> 评审通道：Opus 4.8 xhigh 对抗 review（代 codex；周配额耗尽，与 PR #122–131 一致）。
> 性质：触碰 Wave-1 冻结契约 **E3 TradeCalculator**（RFC 授权演进）+ 持久化资金语义；**预计不 bump `CONTRACT_VERSION`**（§11 论证，plan/impl 阶段复核）。

---

## 1. 背景与目标

PR #128 后 user 真机/模拟器实测，提出交易玩法要对齐主流股票软件（同花顺/东方财富）。RFC-B 已重构了训练**界面布局**（顶栏/坐标轴/曲线/画线浮动/T2 交易条），但**交易玩法本身仍是「按仓位档 1/5..5/5 一拍即下」**，与主流「按股数、两步确认」有差距。

**总目标（本 RFC）**：把交易/仓位/资金做成主流风格——
1. **股数化交易**：买卖以股数为基准（A 股一手 = 100 股），可用现金/持仓为约束。
2. **买卖框（两步式）**：点买入/卖出后弹出数量框（数量框 + ±100 + 比例快捷填入 + 可买/可卖 + 预估金额 + 确认），取代「一拍即下的 5 档条」。
3. **持仓信息**：顶栏「浮动盈亏」改为**当前持仓**未实现盈亏（元 + %），而非账户总收益率。
4. **资金跨局复利 + 重置保留历史**：当前总资金成为权威存储字段，跨局复利接续；重置 = 强制回 10 万但**保留**历史记录（推翻 #123 清记录）。

成功判据（高层）：host swift test + Mac Catalyst build + iOS app build 三绿；§10 模拟器人工验收逐条通过；股数/资金算术由新增 host 测试逐值钉死；E3 契约演进有等价或更强的测试覆盖；无任何持久化序列化结构改动（§11）。

---

## 2. 范围（Scope）

### 2.1 IN — RFC-A 负责
- **A1 股数化交易引擎/契约**：`TradeCalculator` 演进为**按股数**报价；比例 1/5..5/5 降级为「计算快捷填入股数」的辅助；引擎交易入口改为按股数。
- **A2 买卖框 UI（方案 D）**：点 T2 买入/卖出 → 从 active 图底部弹出数量框（**沿用 RFC-B 现有 overlay 机制**：红框/anchor/active 绑定全不动），内容 = 数量框 + ±100 步进 + 1/5..4/5 + 全仓/清仓快捷填入 + 可买/可卖 X 股 + 预估金额 + 右上 ✕（点框外亦可）取消 + 全宽确认。取代现有 `TradeBarView` 5 档条的**内容**。
- **A3 顶栏「浮动盈亏」语义**：从「账户总收益率 %」改为「**当前持仓浮动盈亏（元 + %）**」=（现价 − 每股成本）× 持仓股数。RFC-B 顶栏其余 4 格（总资金/持仓成本-每股/持仓股数/仓位 X/5）保留不动；**仓位% 保留**（user 明确）。
- **A4 资金跨局复利 + 重置保留历史**：`settings.total_capital` 成为**权威当前资金**（每局结束写入、开局读取）；`resetAllTrainingProgress` 去掉 `deleteAll`（保留记录）、保留清 pending、置 10 万；一次性数据迁移回填已有进度。

### 2.2 OUT — 明确不在 RFC-A
- **#10 replay 续局** → **推迟到独立 RFC**（user 拍）。本 RFC 不动 replay 的临时性（不存档/不累计/不可续）。
- **per-period 独立取价** → **不做**（§5 论证：任一时刻全周期现价相同；选周期决定步进颗粒度而非价格）。保持全局现价 + T2 中性「下单价」。
- **长按十字光标 / 单指竖滑切周期 → RFC-C；设置 popover → RFC-E。**
- **T2 薄条布局/顺序、顶栏框架、坐标轴、指标曲线、画线浮动控件** = RFC-B 已定，**全不动**（仅 T2 的买/卖按钮改为弹「新数量框」而非「旧 5 档条」；持有/观察不变）。
- **新画线工具、per-panel 画线** = 不做。

### 2.3 性质与契约
- **0 后端 / 0 DDL 结构改动**（A4 仅一次性**数据**迁移 UPDATE `settings`，不加列）；纯 iOS 表现层 + 引擎/计算器逻辑演进 + 资金读写口径变更。
- 不 bump `CONTRACT_VERSION`（§11）。

---

## 3. 引擎 / 契约改动

### 3.1 E3 `TradeCalculator` 演进（按股数；冻结契约 RFC 授权演进）
**现状**（Wave-1 冻结）：`quoteBuy(totalCapital:cash:tier:price:fees:)`（买入额 = **总资金** × ratio）/ `quoteSell(holding:averageCost:tier:price:fees:)`（卖出 = 持仓 × ratio，tier5 = 全部）/ `forceCloseOnEnd(...)`。常量 `stampDutyRate=0.0005`、`minCommissionAmount=5`、`shareLotSize=100`；`robustFloor` 抗 FP；ratio tier1..5 = 0.2..1.0。

**演进（新增按股数 API + 比例改基准）：**

1. **新增按股数报价（主路径）：**
   ```
   quoteBuy(cash: Double, shares: Int, price: Double, fees: FeeSnapshot) -> Result<BuyQuote, TradeReason>
   quoteSell(holding: Int, averageCost: Double, shares: Int, price: Double, fees: FeeSnapshot) -> Result<SellQuote, TradeReason>
   ```
   - 校验：`shares > 0 && shares % shareLotSize == 0`，否则 `.invalidShareCount`；买入 `totalCost <= cash` 否则 `.insufficientCash`；卖出 `shares <= holding` 否则 `.insufficientHolding`。
   - `BuyQuote`/`SellQuote` 结构与字段**不变**（shares/notional/commission/totalCost；shares/notional/commission/stampDuty/proceeds）。佣金/印花税/proceeds 算法**不变**（commission = notional×rate，启用免5则下限 5；卖印花税 always；proceeds = notional − commission − stampDuty）。
2. **新增「可买上限」（fee-aware，防确认时 `insufficientCash`）：**
   ```
   maxBuyableShares(cash: Double, price: Double, fees: FeeSnapshot) -> Int
   ```
   返回**满足 `quoteBuy(cash, N).totalCost <= cash` 的最大 100 股整数倍 N**。必须 fee-aware：朴素 `floor(cash/price/100)×100` 不含佣金，可能 totalCost > cash → 确认失败。实现可用闭式估算后向下校正（plan 定；用 `robustFloor` 抗 FP），并由 host 测试钉死边界（恰好够 / 差 1 手 / 佣金免5 下限触发）。
3. **比例 → 股数 快捷填入 helper（A1 语义核心，buy 改 cash 基准）：**
   ```
   sharesForBuyTier(cash: Double, price: Double, tier: PositionTier) -> Int   // 1/5..4/5
   sharesForSellTier(holding: Int, tier: PositionTier) -> Int                 // 1/5..5/5
   ```
   - **买 k/5（k=1..4）= `floor(cash × k/5 / price / shareLotSize) × shareLotSize`**（**可用现金**基准，非总资金——路线图 A1 明确；与现状 totalCapital 基准不同，见 D1）。**全仓（5/5）= `maxBuyableShares`**（fee-aware 上限，而非朴素 `floor(cash/price/100)×100`，避免确认 `insufficientCash`，见 D2）。
   - **卖 k/5（k=1..4）= `floor(holding × k/5 / shareLotSize) × shareLotSize`；清仓（5/5）= `holding`**（精确全部持仓，含零股）。
4. **旧 tier 报价方法（`quoteBuy(totalCapital:cash:tier:)`/`quoteSell(holding:averageCost:tier:)`）去留 = D3**：plan 阶段做**调用方接线调查**；若仅 UI（经 `engine.buy(panel:tier:)`）调用 → **移除**旧 tier 报价 + 对应 `engine.buy/sell(panel:tier:)` + 其测试，用按股数路径与新 host 测试替代（避免 totalCapital 基准的**死/误导**代码）；若发现非 UI 调用方 → 适配。tier 概念仅作为 UI 快捷填入存活。

### 3.2 E2 `PositionManager`：**不改**
`buy(shares:totalCost:)` / `sell(shares:)` 本就按股数 + precondition trap + throwing decoder + invariantsHold。新按股数路径直接复用，**零改动**。

### 3.3 `TrainingEngine` 交易入口（按股数）
- 新增 `buy(panel: PanelId, shares: Int) -> Result<TradeOperation, AppError>` / `sell(panel: PanelId, shares: Int) -> Result<TradeOperation, AppError>`：调 `TradeCalculator.quoteBuy(cash: cashBalance, shares:, price: currentPrice, fees:)` / `quoteSell(holding: position.shares, averageCost: position.averageCost, shares:, ...)`，成功则 `position.buy/sell` + `cashBalance ±= ...` + 记 `TradeMarker`/`TradeOperation`（沿用现有 `.buy/.sell` 记账 + D6 字段口径：buy `stampDuty:0`，sell `totalCost:proceeds`）+ `advanceAndAccount`。**价仍为全局 `currentPrice`**（§5），`panel` 仍只影响①记录 period ②`stepsForPeriod` 推进步数。
- `forceCloseOnEnd` / `forceCloseManually` / `holdOrObserve` **不改**。
- `buyEnabled`/`sellEnabled` 不改（卖使能仍 `position.shares > 0`）。
- `TradeOperation` 的 `positionTier: PositionTier`（**非可选**，`Codable` 且持久化进 `trade_operations` 表，`Models.swift:159`）——按股数下单仍**必须**填一个值（字段不可丢/不可空，否则改序列化结构=bump）。**D4**：由该笔成交占比反推最近档 `round(占比×5)` clamp 1..5 映射为 `PositionTier`（买占比 = totalCost/下单前现金 或 成交市值/总资金，sell 占比 = soldShares/下单前持仓；具体口径 plan 定），**仅作记录展示用、不参与任何算术**。不增删字段、不改 `TradeOperation` 序列化结构（§11）。

### 3.4 资金持久化（A4）
- **`startingCapital()`（`TrainingSessionCoordinator`）**：从「派生（末条记录 `total_capital+profit`，无则 settings）」改为「**直接读 `settings.total_capital`**」（权威字段）。
- **`finalize(engine:)` / `DefaultAppDB.finalizeSession(...)`**：Normal 收尾的**同一事务**内新增 `SettingsDAOImpl.setTotalCapital(db, engine.currentTotalCapital)`（写权威当前资金）。Review/Replay 不写（`shouldSaveRecord()==false`，沿用）。
- **`resetAllTrainingProgress(toCapital:)`**：**去掉 `RecordRepositoryImpl.deleteAll`**（保留 records/trade_operations/drawings），**保留** `clearPending`（重置即清当前未完成局），保留 `setTotalCapital(toCapital)`（= `defaultTotalCapital` 10 万）。
- **一次性数据迁移 `0005`（user_version 2→3）**：`UPDATE settings SET value = (末条 training_records.total_capital + profit)` 当存在记录时（无记录则不动，保持默认 10 万）。**纯数据 UPDATE，不加列、不改结构**。保证老用户跨局累计资金不丢（D5）。
- **「当前总资金」单一真相源**：plan 阶段查所有「跨局当前资金」消费点（如主页/历史统计用 `RecordRepositoryImpl.statistics().currentCapital` 派生显示者），统一改读 `settings.total_capital`，否则重置后显示会与权威值背离（D6）。引擎内 `currentTotalCapital`（= cash + 持仓市值，**单局内**实时）不变。

---

## 4. 详细设计（按子项）

### 4.1 A1 股数化交易语义
- **下单价 = 全局 `currentPrice`**（§5）。买卖一手 = 100 股。
- **买**：可用现金约束；`可买 = maxBuyableShares(cash, price, fees)`；k/5 快捷 = `sharesForBuyTier`（cash 基准）；全仓 = 可买上限。
- **卖**：持仓约束；`可卖 = position.shares`；k/5 快捷 = `sharesForSellTier`；清仓 = 全部持仓；`shares==0` 时卖入口禁用（`sellEnabled` 沿用）。
- **持仓成本含费**：`averageCost` 由 `position.buy(totalCost:)` 累计，`totalCost` 含买入佣金 → `averageCost` 已含买入费（RFC-B §2.2 要求 A 保证）。卖出印花税/佣金在 proceeds 扣减、不回灌成本。**确认现状正确**，A1 不额外改。

### 4.2 A2 买卖框 UI（方案 D）
- **触发与位置**：T2 薄条「买入/卖出」→ 设 `tradeStrip = TradeStripRequest(panel: activePanel, action:)`（**不变**）→ overlay 仍按 `strip.panel == id` 落 **active panel 底部**（**RFC-B 现有机制，零改动**：红框跟随 `activePanel`、上图 active 则上图底弹、下图 active 则下图底弹）。**取代的只是 overlay 的内容**：从 `TradeBarView`（5 档条）换成新 `TradeBoxView`（数量框）。
- **框内容（买入；卖出镜像）**：
  - 顶行：标题「买入」(红) / 「卖出」(绿) · 现价 ¥X · 「可买 N 股」/「可卖 N 股」· 右上 ✕。
  - 数量行：`−` `[数量]` `＋`（每点 ±100 股）。
  - 预估行：「每点 ±100 股 · 预估 ¥Y」——买 Y = `quoteBuy(...).totalCost`，卖 Y = `quoteSell(...).proceeds`（当前数量的实时报价；非法数量显占位）。
  - 快捷行：`1/5 2/5 3/5 4/5 [全仓/清仓]`——点击**填入数量框**（不直接下单）：买 = `sharesForBuyTier`(1/5..4/5) / `maxBuyableShares`(全仓)；卖 = `sharesForSellTier`(1/5..4/5) / `holding`(清仓)。
  - 确认行：**全宽**「买入 N 股」/「卖出 N 股」。`N==0` 或非法时禁用。
- **数量校验**：手动输入向下取整到 100；clamp 到 `[0, 可买]`（买）/`[0, 可卖]`（卖）。`−` 不低于 0，`＋` 不超上限。
- **取消**：右上 ✕ 或点框外空白 → 清 `tradeStrip`（关闭框；不下单）。
- **下单（确认）= 复用 + 强化防漂移守卫（关键安全，吸取 RFC-B 教训 [[project_trade_ui_backlog_2026_06_21]]）**：
  - `performTrade` 改为按股数：`engine.buy(panel: activePanel, shares:)` / `engine.sell(panel: activePanel, shares:)`。
  - **确认前必须重新校验引擎状态未漂移**：沿用 `tradeStripStillValid(capturedPeriod, currentPeriod, capturedTick, currentTick)`；**任一不符 → 框作废、不下单**（防对过期 period/tick/价成交 + 不可逆 autosave）。框打开期间若 tick 推进（持有/观察/买卖触发）或周期被切 → `可买/可卖/现价/预估` 均失真 → 失效。plan 钉死「框打开→状态变→确认」必红的 host/接线测试。
  - 成功后 haptic/toast/autosave（沿用 `TradeFeedback`/`lifecycle.autosave(immediate:true)`）。
- **平台无关纯值** `TradeBoxContent`（host 测）：给定 (action, price, cash/holding, averageCost, fees, 当前数量) → 输出 可买/可卖串、预估串、各快捷档股数、确认按钮文案/使能。`TradeBoxView` 为 SwiftUI 薄壳。
- **无障碍**：数量框/±/快捷/确认/✕ 各 `accessibilityLabel`。

### 4.3 A3 顶栏「浮动盈亏」→ 持仓浮动盈亏
- `TrainingTopBarContent`：第 5 格由 `returnRate`（账户总收益率 %）改为**持仓浮动盈亏**：
  - 金额 = `(currentPrice − averageCost) × shares`；百分比 = `(currentPrice − averageCost) / averageCost`（`shares>0`）。
  - `shares==0` → `+¥0.00 (+0.00%)`（沿用 `±0` 归一为 `+`）。
  - 显示串：`+¥480.00 (+1.98%)`（红涨绿跌随符号；¥/% 口径对齐现有 formatter）。
  - 实现：`TrainingTopBarContent.init` 增 `currentPrice` 入参，计算 `holdingPnL` 串；标签文案保持「浮动盈亏」。host 全测（正/负/零持仓/大额）。
- 其余 4 格（总资金/持仓成本-每股/持仓股数/仓位 X/5）**不动**。

### 4.4 A4 资金（见 §3.4）
- 模型：`settings.total_capital` = 权威当前资金；finalize 写、startNew 读、reset 置 10 万保留记录、迁移 0005 回填。
- 复利接续：新局起始资金 = 上一局结束写入的 `settings.total_capital`（含上局盈亏）。
- 重置：强制 10 万 + 保留全部历史记录（推翻 #123）。

---

## 5. per-period 取价 = 不做（关键、对抗 review 必查点）

**任一时刻，全周期现价相同。** 每个周期**最右一根「正在形成」的 K 线**收盘价 = 最新 `.m3` 收盘 = 全局现价；3分/15分/60分/日线/周线这根未完成 candle 的 close 全相等。所谓「日线 11 块」是日线**收盘后**（未来）的价，非「此刻」可成交价；走到日终时各周期最新 close 同为 11。若硬做 per-period 取价，只能取**已完成**那根的 close（如日线取昨收）→ 大周期上按**过时价**成交，反而错误。

**选周期真正的意义 = 时间颗粒度（步进粒度），非价格。** active panel（T2 分段钮选）决定 `stepsForPeriod` 推进步数（60分一次跳 60 分钟 / 3分一次跳 3 分钟）+ 弹框位置 + 红框——**这些 RFC-B 已实现，A 不改**。下单价恒为全局现价。

→ RFC-A 保持全局现价 + T2 中性「下单价 ¥…」（RFC-B 现状）。**不**承诺「不同周期不同下单价」。

---

## 6. 关键决策（D1–D6，LOCKED 除注明）

- **D1（买基准 = 可用现金，非总资金）**：买 k/5 用 `cash × k/5`（路线图 A1 明确），不同于现状 `totalCapital × ratio`。理由：主流快捷买按钮基于「可用资金」；已持仓时 totalCapital 基准会算出超过现金的股数 → `insufficientCash`。属 E3 行为演进（§3.1），旧 totalCapital 基准被有意取代。
- **D2（全仓 = fee-aware 可买上限）**：全仓填入 `maxBuyableShares`（含佣金校正），非朴素 `floor(cash/price/100)×100`，否则确认 `insufficientCash`。host 测钉死边界。
- **D3（旧 tier 报价方法去留）**：plan 阶段接线调查后定（仅 UI 调 → 移除 + 替换测试；否则适配）。倾向移除以免 totalCapital 基准的死/误导代码。
- **D4（`TradeOperation.positionTier` 取值）**：该字段非可选、Codable、持久化，按股数下单必须填值；由成交占比反推最近档 `round(占比×5)` clamp 1..5（口径 plan 定），**仅记录展示、不参与算术、不改序列化结构**。
- **D5（迁移回填，user 锁）**：升级（app 版本覆盖安装、旧 DB 在）后，一次性迁移 `settings.total_capital = 末条记录 total+profit`（无记录则 10 万），不丢累计进度。
- **D6（当前资金单一真相源）**：所有「跨局当前资金」显示/使用点统一读 `settings.total_capital`；plan 阶段查全 `statistics().currentCapital` 派生消费者并改读权威字段（否则重置后背离）。

---

## 7. 数据流 / 新增状态
- `TradeBoxView` 数量 `@State qtyShares: Int`（初始 0 或上次档位填入值）——纯 UI 状态；校验/clamp/快捷股数/预估均经 `TradeBoxContent` 纯值 + `TradeCalculator` helper（host 测）。
- 复用 RFC-B 既有：`@State activePanel`、`tradeStrip: TradeStripRequest?`、overlay-on-active-panel、`tradeStripStillValid`、`performTrade`、haptic/toast、autosave。
- 引擎新增 `buy/sell(panel:shares:)`（§3.3）；TradeCalculator 新增按股数报价 + helper（§3.1）。
- 资金：`settings.total_capital` 读写口径变更（§3.4）；migration 0005。
- **无新增持久化序列化结构**（§11）。

---

## 8. 测试策略
- **Host 可测纯逻辑**（Swift Testing）：
  - `TradeCalculator` 按股数报价：lot 校验（`invalidShareCount`）、买 `insufficientCash`、卖 `insufficientHolding`、佣金/印花税/proceeds 逐值（沿用现有口径）、`robustFloor` FP 边界（沿用 demonstrator 思路，须 mutation-verify 非空洞）。
  - `maxBuyableShares`：恰好够 / 差 1 手 / 佣金免5 下限触发 / 现金为 0 → 逐值。
  - `sharesForBuyTier`（cash 基准 1/5..4/5）/ `sharesForSellTier`（holding 1/5..4/5 + 清仓=全部含零股）逐值 + lot 取整。
  - `TradeBoxContent`：可买/可卖串、预估串（买 totalCost / 卖 proceeds）、各档填入股数、`N==0`/非法→确认禁用、买红卖绿文案。
  - `TrainingTopBarContent` 持仓浮动盈亏：正/负/零持仓（`+¥0.00 (+0.00%)`）/大额、¥/% 口径、`±0` 归一 `+`。
  - 防漂移：`tradeStripStillValid` 已有；新增「框打开→tick 推进/周期切→确认必拒」的纯逻辑/接线断言。
  - A4 资金口径：`startingCapital` 读 settings、finalize 写 settings、reset 保留记录+置 10 万、migration 0005 回填（有/无记录两路）——用 in-memory fake DB（沿用 Wave-1 fixture 范式）逐值。
- **构建验证**：`swift test` host 全绿；Mac Catalyst `build-for-testing` SUCCEEDED；iOS app build 成功。
- **模拟器人工验收**：§10 清单逐条（iPhone 17 Pro，DEBUG fixture；改 fixture 须 `simctl uninstall` 再装）。
- 历史教训：等比/FP host 断言用容差且 demonstrator 须 mutation-verify [[feedback_swift_local_toolchain_blindspot]]；负向 grep 断言用 `if/exit 1` 非 `! grep` [[feedback_acceptance_grep_anchoring]]。

---

## 9. 不在范围的已知问题（记录）
- replay 续局（#10）→ 独立 RFC。
- per-period 取价 → 论证不做（§5）。
- 长按十字光标（RFC-C）/ 单指竖滑切周期（RFC-C）/ 设置 popover（RFC-E）。
- 账户总收益率不再进顶栏（移到/保留于结算窗，沿用）。

---

## 10. 验收清单（非程序员可执行；action / expected / pass-fail；二值可判）

> 设备：模拟器 iPhone 17 Pro（udid `DE0BA39D-C749-459D-A407-4418599B61CA`），DEBUG fixture（`SIMCTL_CHILD_KLINE_SEED_FIXTURE=1`）。改 fixture 须 `simctl uninstall` 再装。证据：每条附截图。

| # | 操作（action） | 预期（expected） | 通过判定（pass/fail） |
|---|---|---|---|
| 1 | 进入训练，点底部「买入」 | 从 active 图底部弹出**数量框**（非旧 5 档条）：含数量框 + −/＋ + 1/5..4/5 + 全仓 + 可买 N 股 + 预估金额 + 右上 ✕ + 全宽「买入」键 | 框内 7 类元素齐全且从 active 图底弹 = pass；仍是旧 5 档条或缺元素 = fail |
| 2 | 框内点「＋」一次、再点「−」一次 | 数量各 ±100 股 | 步进恰为 ±100 = pass；否则 fail |
| 3 | 手动输入一个非 100 倍数（如 250） | 确认时取整到手（250→200），或输入即向下取整到 100 | 最终下单股数为 100 倍数 = pass；成交奇数股 = fail |
| 4 | 点「全仓」再「买入」 | 用尽可用现金买入最大手数且**不报现金不足**；持仓股数增加、现金≥0 | 成交且现金不为负、无「现金不足」报错 = pass；报错或现金为负 = fail |
| 5 | 持仓>0 时点「卖出」→「清仓」→「卖出」 | 持仓清零（精确全部，含零股）、现金增加 | 持仓变 0 = pass；残留股数 = fail |
| 6 | 0 持仓时看「卖出」入口 | 卖出禁用（或卖框「可卖 0 股」且确认禁用） | 不能卖空 = pass；能卖出 = fail |
| 7 | 切 T2「60分」点买入 / 切「日线」点买入 | 框分别从**上图(60分)底部** / **下图(日线)底部**弹出，红框随之在上/下图 | 两次弹出位置 + 红框各自正确 = pass；位置/红框错 = fail |
| 8 | 顶栏第 5 格（持仓>0 与 =0） | 持仓>0 显**当前持仓浮动盈亏**「±¥金额 (±%)」=（现价−成本）×股数；持仓=0 显 `+¥0.00 (+0.00%)` | 两态取值符合 = pass；显示账户总收益率或错值 = fail |
| 9 | 完成一局（结算）后开新局 | 新局起始总资金 = 上局结束总资金（含上局盈亏，跨局复利接续） | 新局起始资金接续上局 = pass；回到 10 万 = fail |
| 10 | 设置里「重置资金」 | 总资金回 10 万，但**历史记录仍在**（历史列表条目数不变） | 资金=10 万 且 历史条目保留 = pass；记录被清空 = fail |
| 11 | 打开买框后，先做一次「持有」（推进 tick），再回到框点「买入」 | 框因状态漂移作废/刷新，不会按过期价/tick 成交 | 不发生过期成交（框失效或数值已刷新）= pass；按旧价/旧 tick 成交 = fail |
| 12 | 全程不动 RFC-B 布局 | 顶栏框架 / 上下两图 / 坐标轴 / MA66·BOLL·MACD / 画线浮动 ✎ / T2 条顺序(周期左·价中·买卖持有右) 与 RFC-B 一致 | 布局零变化 = pass；任一被改 = fail |

---

## 11. 不 bump `CONTRACT_VERSION` 论证
`CONTRACT_VERSION` 钉**持久化/跨端序列化**契约。RFC-A：
- **E3 `TradeCalculator`** 是**纯计算函数**，行为不进入任何序列化；新增按股数 API、比例改 cash 基准、移除/替换旧 tier 方法——均不改 `BuyQuote/SellQuote/PositionTier/FeeSnapshot` 的**结构**（仅算术/入参），无跨端契约面变化。
- **E2 `PositionManager`** 零改动。
- **`TradeOperation`** 序列化结构不变（D4 仅定 tier 字段取值，不增删字段）。
- **A4 资金**：`settings` 是 KV 表，`total_capital` **键已存在**；改的是**写入时机/读取来源**（口径），migration 0005 是**纯数据 UPDATE**（不加列、不改表结构）。无序列化结构变化。
- A3 顶栏纯展示层（读 engine 现有值算 PnL），不持久化。

→ 无任何外部可观测的持久化/跨端契约结构变化 → **不 bump**（与 PR #122–131 UI/玩法改版一致）。plan/impl 若发现需触序列化结构（不预期），回本节修订并 bump。

---

## 12. 风险 / 未决（plan 阶段消解）
- **R1（D3 旧 tier 方法去留）**：依赖 plan 接线调查；移除冻结契约方法须对抗 review 确认无非 UI 调用方 + 等价测试覆盖。
- **R2（D6 当前资金消费者全集）**：plan 须穷举所有「跨局当前资金」显示/使用点改读 `settings.total_capital`，漏一处则重置后背离。
- **R3（maxBuyableShares FP 边界）**：fee-aware 上限的闭式+校正实现须 host 测钉死（恰好够/差1手/免5），避免 off-by-one-lot 或确认 `insufficientCash`。
- **R4（顶栏第 5 格大额宽度）**：持仓浮动盈亏「±¥… (±%)」最坏值不撑宽/不重叠（沿用 RFC-B 顶栏宽度策略，§10 兜底人工核）。
- **R5（迁移幂等/无记录）**：migration 0005 在无记录、已 reset、多次运行下行为正确（user_version 守护一次性）。
