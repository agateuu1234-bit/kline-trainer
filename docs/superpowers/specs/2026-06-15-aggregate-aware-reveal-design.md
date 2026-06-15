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

**核心不变量**：图表渲染的**每一根可见 K 线**其 OHLC/volume/指标**只含 ≤ tick 的已揭示数据**（`endGlobalIndex ≤ tick`）。reveal 已保证「窗口末根索引 ≤ currentIdx」；本 RFC 进一步保证「currentIdx 那根 K 线的**数据**也不含未来」。

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

`start = (currentIdx == 0) ? 0 : aggCandles[currentIdx − 1].endGlobalIndex + 1`。

---

## 三、关键设计决策

- **D1 不隐藏（user 裁决，对比 reveal 后续选项 B）**：partial 合成 > 隐藏进行中根。理由：①真实行情语义（K 线正在形成）；②**顺带解决**隐藏方案的「开局聚合面板空白」问题（合成至少有 1 根 m3 即可画）；③**不改 `currentCandleIndex` 语义**（进行中根照常在 currentIdx，仅数据被替换）→ 不波及 pinch/autoTracking 锚（reveal RFC 已冻结的共享谓词）。
- **D2 进行中那根不画指标（user 裁决）**：MA66/BOLL/MACD 是 vendor 按**整根**预算的、partial 无法无歧义重算（尤其 MACD 的 EMA 递归需复制后端逻辑到端上 = 双实现分歧风险）。合成根指标置 `nil`；渲染层**已对 nil 优雅断线**（`MainChartLayout.polylineSegments` `if let`、`SubChartLayout.macdBars` `guard let … else continue`，grep 核实）→ 指标线/柱自然终止在最后一根**已完成** K 线，无需改渲染层。多数真实行情软件指标亦"收盘才更新"。
- **D3 合成根 `endGlobalIndex = tick`**：让无未来不变量统一可机检（`所有可见根 endGlobalIndex ≤ tick`）。安全性：`currentCandleIndex` 在**原** candles 数组上算（合成发生于其后），不回喂；x 位置按 slice 索引；HUD 时间用 datetime；priceRange 用 OHLC —— 均不依赖合成根的 endGlobalIndex。
- **D4 单一真相 / 不动几何**：`makeViewport`（含 reveal 的 upperBound/sliceEnd）、`currentCandleIndex`、`visibleCandleRange`（返索引区间、与 OHLC 无关）**全不改**。合成是 `make()` 装配 slice 后的**纯数据替换**。
- **D5 只做渲染合成（user 裁决，scope）**：不碰交易/tick/记账/持久化模型；当前价、tier、结算等仍走既有 .m3 路径（与合成 close 同源，一致）。
- **D6 完成瞬间跳变（已知 cosmetic）**：K 线走完（`endGlobalIndex ≤ tick`）后不再合成、切回 vendor 预存整根（含指标）。vendor 各周期独立源，**若**与 3m 聚合不完全一致 → 完成瞬间一帧轻微 OHLC 跳变。close 维度预期连续（当前价 = m3[tick].close = 该周期收盘的同一标的价）；high/low/open 维度依赖 vendor 数据一致性 → 列 §六验收项（真实数据上肉眼无明显跳变）。**不**为完全 bit 一致投入（会要求渲染端永远自合成整根、丢弃 vendor 指标，得不偿失）。
- **D7 治理边界**：改 `ios/**/*.swift` 渲染装配 = trust-boundary + RFC + opus 对抗 review 收敛 + codex:adversarial-review。**不** claim 行为中性（明为行为修正：聚合面板进行中根渲染变更）。

---

## 四、架构 / 单一职责

- **新增纯函数**（平台无关，host 全测）：
  `RenderStateBuilder.synthesizedInProgressAggregate(original: KLineCandle, m3: [KLineCandle], startGlobalIndex: Int, tick: Int) -> KLineCandle`
  —— 读 `m3[startGlobalIndex … tick]` 算 partial OHLC/vol，返回保留 `original.period/datetime`、指标 nil、`endGlobalIndex=tick`、`globalIndex=nil` 的新 `KLineCandle`。前置：`m3` 非空且覆盖 `[startGlobalIndex, tick]`（engine init 已保证 .m3 连续 0…≥maxTick、`tick ≤ maxTick`）。放 `RenderStateBuilder`（render 装配 owner，与 `currentCandleIndex` 同处）或独立小文件 `Render/PartialAggregateCandle.swift`（plan 定，避免 RenderStateBuilder 膨胀）。
- **挂钩 `RenderStateBuilder.make(engine:panel:bounds:)`**（伪码）：
  ```
  let viewport = makeViewport(panelState:candles:tick:bounds:)
  var slice = Array(candles[viewport.startIndex ..< viewport.startIndex + viewport.visibleCount])
  let currentIdx = currentCandleIndex(candles: candles, tick: tick)
  let lastVisibleIdx = viewport.startIndex + viewport.visibleCount - 1
  if lastVisibleIdx == currentIdx, candles[currentIdx].endGlobalIndex > tick {        // 进行中且可见
      let start = currentIdx == 0 ? 0 : candles[currentIdx - 1].endGlobalIndex + 1
      slice[slice.count - 1] = synthesizedInProgressAggregate(
          original: candles[currentIdx], m3: engine.allCandles[.m3] ?? [], startGlobalIndex: start, tick: tick)
  }
  // 之后用替换后的 slice 算 volumeRange/macdRange/priceRange + visibleCandles
  ```
- **触发条件精确**：`lastVisibleIdx == currentIdx`（即 reveal 下 `sliceEnd == currentIdx+1`，窗口确实含 currentIdx；用户**向后滚动浏览历史**时 `lastVisibleIdx < currentIdx` → 可见全为已完成根 → 不合成）**且** `candles[currentIdx].endGlobalIndex > tick`（进行中）。**m3 驱动面板**：currentIdx 那根 `endGlobalIndex == tick` → 条件 false → 天然 no-op。
- **类型注记（plan 落实）**：`KLineRenderState.visibleCandles` 现为 `ArraySlice<KLineCandle>`；替换单根需改走 `Array` 或重建 slice。下游 layout 函数取 `ArraySlice` → 传 `array[...]`。属机械 impl 细节，plan 决定最小波及实现（如 visibleCandles 改 Array 或合成后重切）。
- **排序**：`volumeRange/macdRange/priceRange` 必须**用替换后 slice** 计算（合成根 macd nil → 不入 macdRange compactMap；partial volume/high/low 入 range，无未来撑大）。

---

## 五、测试

1. **合成纯函数 host 测**：partial open/high/low/close/volume 正确（多 m3 取极值 + 累加）；指标全 nil；`endGlobalIndex==tick`；单 m3（start==tick）；首根（start=0）。
2. **make() 集成测**：
   - 聚合面板进行中根被合成（sparse ends `[3,7,11]` @ m3 tick=1 → currentIdx=0 那根 OHLC=partial、`endGlobalIndex==1`、指标 nil；**之前 reveal 的 aggregate-leak 复现 → 现 PASS**）。
   - m3 驱动面板：currentIdx 那根 `endGlobalIndex==tick` → 不合成（原根原样）。
   - 向后滚动浏览（`lastVisibleIdx < currentIdx`）→ 不合成（可见全已完成）。
   - priceRange/volumeRange 来自替换后 slice（不含未来 high/low）；macdRange 不含合成根（nil）。
3. **无未来不变量扫描**：聚合面板跨 tick → 所有 `visibleCandles` 的 `endGlobalIndex ≤ tick`。
4. **回归**：reveal 既有 + 全量 host 测全绿（合成只改 `make` 的 slice 数据，不动 `makeViewport`/`currentCandleIndex`/`visibleCandleRange`）。
5. **全量 host + Catalyst**：`swift test` 全绿 + `** TEST BUILD SUCCEEDED **`。

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
