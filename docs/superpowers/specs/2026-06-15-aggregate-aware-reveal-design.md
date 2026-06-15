# 聚合感知 reveal —— 进行中聚合 K 线 partial 合成（设计文档 / RFC）

**日期**：2026-06-15
**性质**：reveal RFC（PR #113 `bb0d597`）的 HIGH residual 后续。reveal RFC 仅消除 **m3 驱动周期**的窗口未来泄漏；codex R4 [HIGH] 揭出**聚合周期（默认上区 m60 / 下区日线）仍泄漏**：渲染的「进行中聚合 K 线」其预存 OHLC/指标含未来 m3 tick。本 RFC 用 **partial 实时合成**根治。改 `RenderStateBuilder` 渲染装配（不动已冻结 `makeViewport` 几何）→ **trust-boundary + 治理 RFC**，经 `codex:adversarial-review`。

**前置**：本 RFC 基于含 reveal 修复的 main（`bb0d597`，`makeViewport.upperBound=max(0,baseStartIndex)` + `sliceEnd=min(…,currentIdx+1)`）。

---

## 一、问题：聚合周期的进行中 K 线泄漏（grep 核实 2026-06-15）

**tick 步进模型（`TrainingEngine.stepsForPeriod` :349-357）**：点击某面板的买/卖/持有/观察 → `tick` 推进到**该面板周期**当前 K 线的 `endGlobalIndex`（"该周期首个 endGlobalIndex>currentTick 的 K 线的 endGlobalIndex − currentTick"），**所有周期 auto-link**（plan v1.5 L575）。故：

- **被点击/推进的面板**：tick 恰落其周期 K 线边界 → 当前 K 线 `endGlobalIndex == tick`（已完整）→ **不泄漏**。
- **另一 auto-link 面板**（不同周期）：当前 K 线 `endGlobalIndex > tick`（尚未走完）→ 其**预存 OHLC/volume/指标是 vendor 按整根算好的、含未来 m3 tick**。reveal 的窗口不变量「slice 末根 ≤ currentIdx」满足，但 **currentIdx 那根 K 线自身越界**（codex R4 实证：sparse 聚合 ends `[3,7,11]` @ m3 tick=1 → currentIdx=0、画出 endGlobalIndex=3 的 K 线，含未来 tick 2/3）。

**默认组合上区 m60 / 下区日线**：用户按哪个面板推进，另一个就显示进行中（泄漏的）聚合 K 线。**该泄漏在主训练视图常态可达。**

### 数据模型事实（backend grep 核实，决定合成方案）
- **各周期独立源**：`import_csv.py` 按 per-period CSV（`_1m/_3m/_15m/_60m/_daily`）导入，各周期 OHLC + 指标（ma66/boll/macd）由各自 pandas rolling 算好存库 —— **聚合不是从 3m 重采样**。
- **`global_index` 只赋 3m**（`generate_training_sets.py` D2「最小周期=3m，global_index 仅赋 3m，其它 NULL」）；所有周期都有 `end_global_index = bisect_right(3m_dts, [open,下一open) 上界) − 1`（= 该 K 线时间窗内最后一根 3m 的 global_index）。
- 故聚合 K 线 `globalIndex == nil`；进行中聚合 K 线的**已揭示成分 = 3m 全局索引区间 `[start … tick]`**，其中 `start` 须**从上一根聚合的 `endGlobalIndex + 1` 推导**（首根 = 0），不能用 NULL 的 globalIndex。

---

## 二、设计：进行中聚合 K 线 partial 实时合成（user 裁决）

**核心不变量**：图表渲染的**每一根可见 K 线**其 OHLC/volume/指标**只含 ≤ tick 的已揭示数据**（`endGlobalIndex ≤ tick`），**且 Y 轴价格区间 `priceRange` 也只由已揭示数据派生**（opus R1-H2：priceRange 折入 high/low + boll/ma66，必须用合成后 slice 重算，否则 Y 轴刻度仍泄漏未来）。reveal 已保证「窗口末根索引 ≤ currentIdx」；本 RFC 进一步保证「currentIdx 那根 K 线的**数据 + 其撑起的 Y 轴刻度**也不含未来」。

**方案（user 2026-06-15 裁决）**：进行中聚合 K 线**不隐藏**、也**不用 vendor 预存整根**，而是**从已揭示 m3 实时合成 partial**（像真实行情"正在长出来"）。

**合成公式**（成分 3m = `engine.allCandles[.m3][start … tick]`，含两端）：
| 字段 | 值 |
|---|---|
| `open` | `m3[start].open` |
| `high` | `max(m3[start … tick].high)` |
| `low` | `min(m3[start … tick].low)` |
| `close` | `m3[tick].close`（== 当前价；E5 `price(atTick:)` 同取 .m3） |
| `volume` | `sum(m3[start … tick].volume)` |
| `amount` | `nil`（成交额非图表渲染字段；不累加避免与 vendor 口径分歧） |
| `ma66 / bollUpper / bollMid / bollLower / macdDiff / macdDea / macdBar` | **`nil`**（D2） |
| `period / datetime` | 保留原聚合 K 线身份（HUD 时间标签用 datetime） |
| `globalIndex` | `nil` |
| `endGlobalIndex` | **`tick`**（D3：使「所有可见根 endGlobalIndex ≤ tick」成为干净可机检的无未来不变量） |

**成分起点 `start`（opus R1-H1 修正）**：用**进行中聚合 K 线自身的 `datetime`** 在 m3 轴定位首根成分：`start = m3.partitioningIndex { $0.datetime >= original.datetime }`（匹配 backend `[open, nextOpen)` 窗口的下界）。**不能**用「上一根聚合 `endGlobalIndex + 1`」：backend 各周期独立 look-back（`generate_training_sets.py` `PERIOD_BEFORE_CAP`），落在 3m 窗口前的聚合根 `end_global_index` 被 clamp 到 0（`max(0, bisect_right(three_dts, …) − 1)`），故首根 in-window 聚合的 predecessor 也是 0 → predecessor+1=1 但真起点是 m3 索引 0（漏 `m3[0]` 的 open/极值）。datetime 定位对 predecessor clamping 免疫（实证：opus R1 模拟 `egi=[0×9,19,39,…]`，tick∈[1,19] 时 predecessor+1=1 ≠ true_start=0）。由合成纯函数**内部**计算（封装 + 单测），不依赖 caller 传 start。`start ∈ [0, tick]`（进行中根含 tick → open ≤ m3[tick].datetime）。

---

## 三、关键设计决策

- **D1 不隐藏（user 裁决，对比 reveal 后续选项 B）**：partial 合成 > 隐藏进行中根。理由：①真实行情语义（K 线正在形成）；②**顺带解决**隐藏方案的「开局聚合面板空白」问题（合成至少有 1 根 m3 即可画）；③**不改 `currentCandleIndex` 语义**（进行中根照常在 currentIdx，仅数据被替换）→ 不波及 pinch/autoTracking 锚（reveal RFC 已冻结的共享谓词）。
- **D2 进行中那根不画指标（user 裁决）**：MA66/BOLL/MACD 是 vendor 按**整根**预算的、partial 无法无歧义重算（尤其 MACD 的 EMA 递归需复制后端逻辑到端上 = 双实现分歧风险）。合成根指标置 `nil`；渲染层**已对 nil 优雅断线**（`MainChartLayout.polylineSegments` `if let`、`SubChartLayout.macdBars` `guard let … else continue`，grep 核实）→ 指标线/柱自然终止在最后一根**已完成** K 线，无需改渲染层。多数真实行情软件指标亦"收盘才更新"。
- **D3 合成根 `endGlobalIndex = tick`**：让无未来不变量统一可机检（`所有可见根 endGlobalIndex ≤ tick`）。安全性：`currentCandleIndex` 在**原** candles 数组上算（合成发生于其后），不回喂；x 位置按 slice 索引；HUD 时间用 datetime；priceRange 用 OHLC —— 均不依赖合成根的 endGlobalIndex。
- **D4 单一真相 / 不动几何（opus R1-H2 精修）**：`makeViewport` 的**几何**（startIndex/pixelShift/sliceEnd/candleStep/visibleCount）、`currentCandleIndex`、`visibleCandleRange`（返索引区间、与 OHLC 无关）**全不改**。合成是 `make()` 装配 slice 后的**纯数据替换** + **priceRange 重算**：`makeViewport` 仍照旧产出 viewport（含基于 pre-synthesis slice 的 priceRange），但 `make()` 在合成后**用合成 slice 重算 `PriceRange.calculate` 并以一份 `priceRange` 被替换的 viewport 副本装入 `KLineRenderState`**（几何字段逐一保留）。`visibleCandleRange`（drawing handler）不读 priceRange → 不受影响。
- **D5 只做渲染合成（user 裁决，scope）**：不碰交易/tick/记账/持久化模型；当前价、tier、结算等仍走既有 .m3 路径（与合成 close 同源，一致）。
- **D6 完成瞬间跳变（已知 cosmetic）**：K 线走完（`endGlobalIndex ≤ tick`）后不再合成、切回 vendor 预存整根（含指标）。vendor 各周期独立源，**若**与 3m 聚合不完全一致 → 完成瞬间一帧轻微 OHLC 跳变。close 维度预期连续（当前价 = m3[tick].close = 该周期收盘的同一标的价）；high/low/open 维度依赖 vendor 数据一致性 → 列 §六验收项（真实数据上肉眼无明显跳变）。**成交量同理（opus R2-L）**：合成 `volume` 是 partial 累加，完成瞬间跳到 vendor 整根量 → volume 柱高 + volumeRange 同帧轻微变化（同根因、同"可接受"处置）。**不**为完全 bit 一致投入（会要求渲染端永远自合成整根、丢弃 vendor 指标，得不偿失）。
- **D7 治理边界**：改 `ios/**/*.swift` 渲染装配 = trust-boundary + RFC + opus 对抗 review 收敛 + codex:adversarial-review。**不** claim 行为中性（明为行为修正：聚合面板进行中根渲染变更）。

---

## 四、架构 / 单一职责

- **新增纯函数**（平台无关，host 全测）：
  `synthesizedInProgressAggregate(original: KLineCandle, m3: [KLineCandle], tick: Int) -> KLineCandle`
  —— **内部**算 `start = m3.partitioningIndex { $0.datetime >= original.datetime }`（R1-H1），读 `m3[start … tick]` 算 partial OHLC/vol，返回保留 `original.period/datetime`、指标 nil、`amount=nil`、`endGlobalIndex=tick`、`globalIndex=nil` 的新 `KLineCandle`。前置：`m3` 非空且 `tick < m3.count`（engine init 保证 .m3 连续 0…≥maxTick、`tick ≤ maxTick`）；**容损 fail-safe（codex R1-H）：`start = min(rawStart, tick)` clamp 到 `[0,tick]`** —— 良性数据 trigger 已保证 rawStart ≤ tick（clamp 无操作），恶意/损坏数据（`.m3` datetime 非单调 / 聚合 datetime 越界 → rawStart > tick）下**不在渲染热路径 trap**，而 fail-closed：`m3[start...tick]` 恒有效（不崩）+ 成分恒 ⊆ 已揭示 m3（不渲染 vendor 整根、不泄漏未来）。temporal 一致性强校验属 reader/persistence trust-boundary（本渲染 RFC 作用域外），clamp 使渲染路径对其失效亦安全。放 `RenderStateBuilder`（render 装配 owner，与 `currentCandleIndex` 同处）或独立小文件 `Render/PartialAggregateCandle.swift`（plan 定）。
- **挂钩 `RenderStateBuilder.make(engine:panel:bounds:)`**（伪码，R1-H2/H3 修正）：
  ```
  let viewport = makeViewport(panelState:candles:tick:bounds:)        // 几何 + pre-synth priceRange
  let currentIdx = currentCandleIndex(candles: candles, tick: tick)
  let lastVisibleIdx = viewport.startIndex + viewport.visibleCount - 1
  var renderViewport = viewport
  var slice = candles[viewport.startIndex ..< viewport.startIndex + viewport.visibleCount]   // ArraySlice，base 索引
  if lastVisibleIdx == currentIdx,
     candles[currentIdx].endGlobalIndex > tick,                       // 进行中且可见
     let m3 = engine.allCandles[.m3], tick < m3.count {              // R1-L1：守 m3 覆盖（precondition 下恒真），缺则跳过不崩
      let synth = synthesizedInProgressAggregate(original: candles[currentIdx], m3: m3, tick: tick)
      var arr = candles                       // R1-H3：改 base 数组副本（COW），保 base 索引
      arr[currentIdx] = synth
      slice = arr[viewport.startIndex ..< viewport.startIndex + viewport.visibleCount]   // slice.startIndex == viewport.startIndex 不变
      // R1-H2：用合成 slice 重算 priceRange，装入 viewport 副本（几何字段逐一保留）
      renderViewport = ChartViewport(startIndex: viewport.startIndex, visibleCount: viewport.visibleCount,
          pixelShift: viewport.pixelShift, geometry: viewport.geometry,
          priceRange: PriceRange.calculate(from: slice), mainChartFrame: viewport.mainChartFrame)
  }
  // 之后用 slice 算 volumeRange/macdRange + visibleCandles=slice，viewport=renderViewport
  ```
- **触发条件精确**：`lastVisibleIdx == currentIdx`（reveal 下 `sliceEnd == currentIdx+1`，窗口确实含 currentIdx；**向后滚动浏览历史**时 `lastVisibleIdx < currentIdx` → 可见全为已完成根 → 不合成）**且** `candles[currentIdx].endGlobalIndex > tick`（进行中）。**m3 驱动面板**：currentIdx 那根 `endGlobalIndex == tick` → 条件 false → 天然 no-op。
- **base 索引契约（opus R1-H3，load-bearing）**：渲染全链按 base 索引定位（`mapper.indexToX(i) = (i − viewport.startIndex)·step`；MainChart/SubChart/Markers/Crosshair layouts 迭代 `slice.indices`）。故合成必须**改 base 数组副本后用原 bounds 重切**（`ArraySlice` 保 base 索引），**不得** `Array(candles[...])`（从 0 重索引 → 全面板渲染错位）。`visibleCandles` 维持 `ArraySlice<KLineCandle>` 类型不变。性能：COW 仅在合成触发（聚合面板，序列短）时拷贝一次/帧，可忽略。
- **排序**：`volumeRange/macdRange` + `priceRange` 必须**用替换后 slice** 计算（合成根 macd/boll/ma66 nil → 不入对应 range；partial volume/high/low 入 range、无未来撑大）。

---

## 五、测试

1. **合成纯函数 host 测**：partial open/high/low/close/volume 正确（多 m3 取极值 + 累加）；指标 + amount 全 nil；`endGlobalIndex==tick`；单 m3（start==tick）；datetime 定位 start（含 **predecessor clamped 到 0 的首根 in-window 聚合**：predecessor endGlobalIndex==0，datetime 定位仍取 m3[0]——R1-H1 killer）；聚合 open datetime 早于 m3[0]（start clamp 到 0）；trigger 下 `start ≤ tick`（assert 不触发，opus R2-L）。
2. **make() 集成测**：
   - 聚合面板进行中根被合成（sparse ends `[3,7,11]` + 对齐 datetime @ m3 tick=1 → currentIdx=0 那根 OHLC=partial、`endGlobalIndex==1`、指标 nil；**之前 reveal 的 aggregate-leak 复现 → 现 PASS**）。
   - **R1-H3 base 索引契约**：合成后 `rs.visibleCandles.startIndex == rs.viewport.startIndex`（防 `Array(...)` 从 0 重索引致全面板错位；现有测试无此断言）。
   - **R1-H2 Y 轴不泄漏**：构造进行中 vendor 聚合根 high 远超已揭示 m3（未来高点）→ 合成后 `rs.viewport.priceRange.max` 只反映已揭示 partial（不含 vendor 未来 high/boll）。
   - m3 驱动面板：currentIdx 那根 `endGlobalIndex==tick` → 不合成（原根原样）。
   - 向后滚动浏览（`lastVisibleIdx < currentIdx`）→ 不合成（可见全已完成）。
   - volumeRange 来自替换后 slice；macdRange 不含合成根（nil）。
3. **无未来不变量扫描**：聚合面板跨 tick → 所有 `visibleCandles` 的 `endGlobalIndex ≤ tick`。
4. **多面板 / 周期组合（R1-M1）**：
   - **双面板皆聚合**（如 daily/weekly 组合，TrainingEngine `periodCombos`）：两面板 `make()` 各自合成、互不串。
   - **switchPeriodCombo 不推进 tick**：切组合后两面板可同时进行中 → 各自合成正确。
   - **极粗聚合**（weekly/monthly，跨数百根 m3）：合成 start/极值/累加在大跨度下正确。
5. **回归**：reveal 既有 + 全量 host 测全绿（合成只改 `make` 的 slice 数据 + priceRange，不动 `makeViewport` 几何 / `currentCandleIndex` / `visibleCandleRange`）。
6. **全量 host + Catalyst**：`swift test` 全绿 + `** TEST BUILD SUCCEEDED **`。

---

## 六、验收 / 治理

- **评审通道**：`codex:adversarial-review`（配额恢复，优先 codex；耗尽 fallback opus 4.8 xhigh）+ Catalyst + app-build。
- **非-coder acceptance checklist**：host 合成 + 不变量测核 + device runbook：
  - R1 训练中观察**非推进面板**（如按下区日线推进时看上区 m60）：最新一根聚合 K 线"正在形成"（随每步长高/变体），**不**提前显示完整未来形态。
  - R2 训练开局聚合面板：进行中根即有 partial 实体（**非空白**）。
  - R3 进行中聚合根上**无** MA66/BOLL/MACD 点（指标线终止在上一根已完成根）。
  - R4（D6 cosmetic）某根聚合 K 线走完瞬间：肉眼无明显 OHLC 跳变（真实数据一致性）。
- **关闭** reveal RFC（PR #113 / acceptance 2026-06-15-chart-reveal-constraint.md）登记的**聚合 HIGH residual**。
- **ledger**：独立 bugfix-RFC，不碰 Wave 3 completion 治理块。

---

## Changelog
| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-06-15 | v1 (draft) | partial 实时合成进行中聚合 K 线（OHLC/vol 从已揭示 m3、指标 nil、endGlobalIndex=tick）；挂钩 RenderStateBuilder.make slice 替换、不动 makeViewport/currentCandleIndex；D1-D7 决策；完成跳变列已知 cosmetic；关闭 reveal 聚合 HIGH residual |
| 2026-06-15 | v1.1 (opus spec-review R1 修) | **3 [H] 修**：**H1** start 改 datetime 定位（`m3.partitioningIndex{datetime>=original.datetime}`）—— backend 各周期独立 look-back 致 pre-window 聚合 endGlobalIndex clamp 到 0，predecessor+1 漏 m3[0]（首根 in-window，开局可达）；**H2** priceRange 必须用合成 slice 重算并装入 viewport 副本（原 priceRange 在 makeViewport 内由 pre-synth slice 算 → Y 轴仍泄漏未来 high/low+bands），核心不变量 + D4 增 Y 轴维度；**H3** 改 base 数组副本后用原 bounds 重切（保 `slice.startIndex==viewport.startIndex` base 索引契约）、严禁 `Array(candles[...])` 从 0 重索引致全面板错位 + 加 startIndex 断言测试。**M1** 补测：双面板皆聚合/switchPeriodCombo 不推进/weekly-monthly 极粗跨度。**L1** 去 `?? []` 死防御改 guard m3 覆盖。survived：close 连续性 / trigger 等价性 / endGlobalIndex=tick 对 MarkersLayout 二分单调性 / nil 指标断线 / reveal 组合（除 priceRange）opus 已核正确。 |
| 2026-06-15 | v1.2 (opus spec-review R2 APPROVE 收敛) | R2 模拟 backend window 规则 + 实核 Geometry/RenderStateBuilder/Markers 契约 → **H1/H2/H3/M1/L1 全 RESOLVED**（datetime-start 跨午休/隔夜 session gap 亦对，因两侧同 bisect datetime；ChartViewport 6 字段 memberwise init 存在；re-slice 保 base 索引）。新 2 [L]（非阻塞，已纳入）：**Edge-E** trigger 下 `start≤tick` 恒真但加 assert + 测试钉死；**volume** 完成瞬间柱高/range 同 OHLC 一并轻变（D6 已注）。设计收敛 APPROVE。 |
| 2026-06-16 | v1.3 (codex branch-diff attest R1 [HIGH] 容损) | 实施后 codex:adversarial-review 揭 [HIGH]：v1.2 的 `assert(start≤tick)` 对**接受但损坏的数据**（`.m3` datetime 非单调 / 聚合 datetime 越界，engine 仅按 endGlobalIndex 校验、不校验 datetime 单调）会在**渲染热路径 trap**（debug assert / release 闭区间越界），把可恢复脏数据变成 use-time crash（比 init fail-fast 差）。裁决：**assert → `start = min(rawStart, tick)` clamp**（fail-safe，不崩 + 成分 ⊆ 已揭示不泄漏）；reader-boundary temporal 强校验属 persistence trust-boundary、本渲染 RFC 作用域外（clamp 已使渲染路径安全）。补 malformed-data 回归测。opus R2-L assert 决策被本条 supersede。 |
