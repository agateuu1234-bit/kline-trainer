# 图表 reveal 约束（已揭示前缀窗口）—— 设计文档（RFC：改顺位 3 冻结视口几何）

**日期**：2026-06-15
**性质**：修复 `RenderStateBuilder.makeViewport` 的 **latent 未来泄漏 bug**——当前几何允许图表显示「当前 tick (`currentIdx`) 之后的未揭示未来 candle」，违反 K 线 trainer「预测未来 ⇒ 看不到未来」的核心前提。改顺位 3（PR #98 `3187072`）落定的视口几何 → **trust-boundary + 治理 RFC**（动冻结几何，经 `codex:adversarial-review`）。

**触发**：W3-11-R1 bounce 接线的 codex R3 揭出——`offsetBounds`（镜像 makeViewport `upperBound=count−visibleCount`）允许 bounce/scroll 进未来；进一步核实发现 makeViewport **autoTracking 本身**在早 tick 也泄漏未来。user 裁决（2026-06-15）：独立 RFC 先治 reveal，**禁前窥（最新可见=当前 tick）**。修好后 W3-11-R1（parked 于 `wave3-w3-11-r1-bounce-wiring`）rebase 重做 offsetBounds。

---

## 一、问题：未来泄漏的两个来源（grep 核实 2026-06-15）

`makeViewport`（`RenderStateBuilder.swift:58-93`）：`slice = candles[startIndex ..< min(startIndex+visibleCount, count)]`，`startIndex = clamp(baseStartIndex − wholeShift, 0, upperBound)`，`upperBound = max(0, count − visibleCount)`，`baseStartIndex = currentIdx − (visibleCount−1)`。`make()`（`:22`）传**全集** `engine.allCandles[period]`（`let`，构造时全量，非渐进揭示）；`KLineView.draw`（`:72`）直接绘 `renderState.visibleCandles`，**无 currentIdx 约束**。故：

1. **前向滚动泄漏（mid/late tick）**：负 offset → `wholeShift<0` → `startIndex` 增向 `upperBound=count−visibleCount` → slice 含 `currentIdx` 之后的未来根。既有测 `saturateRightClamped`（offset=−600 → startIndex==120）即把窗口推到 candles[120..<200]，currentIdx=150 → 未来根 151-199 被绘。
2. **早 tick autoTracking 泄漏（currentIdx < visibleCount−1）**：`baseStartIndex < 0` → `startIndex=0`，`sliceEnd=min(0+visibleCount, count)`=visibleCount → slice=`candles[0..<80]`，但 revealed 仅 `candles[0..currentIdx]`。既有测 `anchorEarlyTick`（count=200/tick=10）slice=candles[0..<80]、currentIdx=10 → **未来根 11-79 被绘**。

> **可达性（opus R1-M1 收紧）**：源 #1 **前向滚动泄漏始终可达**——任意 mid/late tick 用户向新方向拖拽即触发，与训练集无关，故本 RFC 无条件必要。源 #2（早 tick autoTracking）**条件可达**：当训练集 startTick 使开局 `currentIdx < visibleCount−1`（download verifier 仅要求 startDatetime 前 ≥30 根历史，30<79，**允许**此情形；具体频率取决于 B2 `generate_training_sets` 的窗口/起始选取，未逐一核）→ 开局即泄漏；即便 #2 在某些训练集不触发，#1 已使修复必要，#2 作防御性同修。
> **为何未被发现**：Wave 3 device 运行时矩阵尚未实测（completion doc `runtime-matrix: PARTIAL`）。泄漏存在但未肉眼观察。本 RFC 在 device 测前堵上。

---

## 二、不变量与设计（revealed-prefix window）

**核心不变量**：图表可见窗口 ⊆ **已揭示前缀** `candles[0 ... currentIdx]`——**任何 offset/缩放/tick 下，slice 末根索引恒 ≤ currentIdx**（看不到未来）。

**最新可见 = autoTracking（禁前窥，user 裁决）**：前向滚动（朝新）最多到 autoTracking（currentIdx 落最右被绘 slot）；不可再向新。向后滚动（朝旧/历史，offset>0）仍可，至 candles[0] 为止。

**makeViewport 两处改（其余逐字不变）**：
- **(A) `upperBound`（startIndex 上限）：`max(0, count − visibleCount)` → `max(0, baseStartIndex)`**。autoTracking 锚 `baseStartIndex` 即最新 startIndex；前向滚动（startIndex 试图 > baseStartIndex）被 clamp 回 baseStartIndex。
- **(B) `sliceEnd`：`min(startIndex + visibleCount, count)` → `min(startIndex + visibleCount, currentIdx + 1)`**。slice 末根恒 ≤ currentIdx（早 tick autoTracking 左填充时，slice=`candles[0..<currentIdx+1]` 而非 `[0..<visibleCount]`）。`viewport.visibleCount = sliceEnd − startIndex`（实际可见根数，早 tick < target）。
- **边缘 pin 不变**：`if startIndex==0 || startIndex==upperBound { pixelShift=0 }`——upperBound 现 = `max(0,baseStartIndex)`，autoTracking（startIndex==baseStartIndex==upperBound）→ pixelShift=0（最新边 pin）✓。
  - **交互变更注（opus R1-M2，非缺陷）**：upperBound 从 `count−visibleCount` 收到 `baseStartIndex` 后，mid-history autoTracking（如 tick=150，si=71）由「内部非 pin」变为「==upperBound pin」→ **autoTracking 处向后（朝历史）拖拽不足一根（offset∈[0,candleStep)）由「跟手微移」变为「pin 吸附」**（offset≥candleStep 即正常移）。这是「autoTracking=最新边」的一致后果（标准边缘 pin），非泄漏、非缺陷；device 上首根 sub-candle 向后拖有轻微吸附感 → 列入 §五.7 device runbook 验收项确认非缺陷。（旧行为下该 si 非边缘故跟手，因旧 upperBound 允许前向滚动到未来——正是本 RFC 要消的泄漏。）
- **candleStep 分母仍 = target**（不变，candle 宽度稳定；早 tick 左填充：少于 target 根靠左、右侧空槽，沿用既有 `anchorShortHistory` 左填充语义）。

**几何不变量副产**（消 W3-11-R1 的 R2/R3）：bounce 的 offset 边界变极简——
- `minOffset = 0`（autoTracking 即最新边，前向不可越）；
- `maxOffset = max(0, baseStartIndex) · candleStep`（最老边，向后滚至 candles[0]）。
- 早 tick base<0 → maxOffset=0 → [0,0]（无滚动空间，已显最旧+无未来）。
- **无未来泄漏（不变量保证）+ 无死区（startIndex 上限=baseStartIndex，区间内每 step 都移）+ 无负 minOffset 早 tick 歧义**。

> **作用域限制（codex R4 [HIGH]，2026-06-15 实施后补）：** 本不变量「slice 末根 ≤ currentIdx」对 **m3 驱动周期** 完全消除未来泄漏（m3 candle 的 endGlobalIndex==tick，currentIdx 的 candle 恰落当前 tick）。但对**聚合周期（m60/日线）**，`currentCandleIndex`（首个 `endGlobalIndex≥tick`）指向尚未走完的聚合 candle，其 finalized OHLC/volume/指标含未来 m3 tick → slice 末根虽 ≤ currentIdx，currentIdx 自身的聚合 candle 仍越界。本 RFC 设计 D-currentCandleIndex「不改」，故聚合泄漏**超出本 RFC 作用域**，登记为 HIGH residual + 独立「聚合感知 reveal」后续 RFC（决策 hide vs 已揭示 m3 实时合成 partial；改 currentCandleIndex 语义须走完整设计评审）。本 RFC 是 m3 轴的严格改进，未使聚合泄漏变差（既有问题）。

---

## 三、既有测试的预期行为变更（修 latent bug，非回归）

`RenderStateBuilderTests` 数个 case 编码了旧的「泄漏」行为，须更新为新不变量（逐条列，实施时改期望值）：
- **`anchorEarlyTick`**（count=200/tick=10）：`visibleCount` 期望 `80 → 11`（slice=candles[0..<11]，无未来）；`startIndex==0` 不变。
- **`offsetNegative`**（offset=−25）：`startIndex` 期望 `74 → 71`（前向滚动 clamp 回 autoTracking）；`pixelShift` `5 → 0`（落 upperBound 边 pin）。
- **`saturateRightClamped`**（offset=−600）：`startIndex` 期望 `120 → 71`（不可前向越 autoTracking）。
- **`saturateRightExactBoundary`**（offset=−485）：`startIndex` 期望 `120 → 71`；pixelShift 仍 0。
- **`oneSixtyVisibleSaturates`**（target=160/currentIdx=150/offset=15/step=5，顺位 3 D5 缩放组，opus R1-C1 补）：`baseStartIndex=150−159=−9 → upperBound=max(0,−9)=0 → startIndex=0`；`sliceEnd=min(0+160, 151)=151` → **`visibleCount` 期望 `160 → 151`**（slice=candles[0..<151]，末根==150==currentIdx，无未来）。
- **不变（已逐一实算核，含顺位 3 D5 缩放组全部，opus R1-C1/H1）**：`geometry` / `anchorPhysicalRightEdge`（startIndex 71 / vc 80）/ `anchorShortHistory`（count=30 全揭示，vc 30）/ `offsetMidScroll`（backward，startIndex 69）/ `saturateLeftClamped`（750→0）/ `saturateLeftExactBoundary`（715→0 pin）/ priceRange / aggregatePanelAnchorsOwnPeriod / make 装配 / **D5 缩放组其余三个**：`fortyVisible`（si=111/vc=40 不变）、`leftFillWhenDataShort`（count=100/tick=99 全揭示，si=0/vc=100 不变）、**`endToEndFocusInvariant`**（pinch rezoom 端到端：vpBefore si=70/ps=5/step=10 中段内部不触新 pin、vpAfter si=90/ps=0/step=20、uBefore==uAfter==110.5、xToIndex(410)==110 缩放前后相等 → **不变**，已实算）。
- **新增不变量测**：①slice 末根 ≤ currentIdx（全 offset 扫描：正/负/大/小 offset 下 `startIndex + viewport.visibleCount − 1 ≤ currentIdx`）；②前向滚动禁（任意负 offset → startIndex ≤ baseStartIndex_clamped）；③早 tick autoTracking 显已揭示（count=200/tick=10 → slice=candles[0..<11]，末根==10==currentIdx）；④backward 滚动至 candles[0]（大正 offset → startIndex 0）。

### §三.B 跨 suite 影响审计（opus R2-C1'：reveal × pinch-focus 冲突，必做）
makeViewport/visibleCandleRange 的消费面**不止 RenderStateBuilderTests**（grep 核 2026-06-15，opus R3 精校）：**代码**（3）`Render/RenderStateBuilder.swift`（几何唯一拥有者）+ `Render/PinchZoomModel.swift`（pinch focus 几何）+ `TrainingEngine.swift`（`applyPinch`/`rezoomOffset`）+ `Render/ChartContainerView.swift`（SwiftUI 壳，`.make()`/`applyPinch` **经 makeViewport 透传、无独立几何、无 host 测**——D4 单一真相下新行为自动流过，不构成隐藏路径）；**实际几何消费测试 suite**（6）：`RenderStateBuilderTests` / `TrainingEnginePinchTests` / `PinchZoomModelTests` / `GeometryTests` / `TrainingEngineInteractionTests` / `TrainingEngineDrawingHandlerH1Tests`（`Drawing/DefaultDrawingInputControllerTests` **不消费**——直接构造 `ChartViewport` 测 CoordinateMapper 逆映射、与几何公式无关，opus R3 移出 scope）。

**核心冲突（opus R2-C1'，已实算）**：**pinch-zoom focus 不变量**（缩放时手指下 candle 保持不动：`uBefore==uAfter`）在 **focus 落未来/未揭示 slot** 时与禁前窥**根本冲突**——`TrainingEnginePinchTests.freeScrollingFocusInvariant`（`:134-159`，NormalFlow initialTick==0 → currentIdx==0、focus slot 40 = 未来）：新公式 upperBound=max(0,−79)=0 → 两端 pin → **uBefore=40.5 ≠ uAfter=20.25 → 硬失败**（旧公式 upperBound=120 两端非 pin、uBefore==uAfter==40.5 通过）。**根因合理**：currentIdx==0 时 slot 40 无 candle（未揭示），「手指下 candle 不动」对不存在的 candle 无意义 → 退化为 reveal-pin。
- **语义裁决**：focus 不变量**仅在 focus 落已揭示 candle（focal slot ≤ currentIdx 的可见映射）时成立**；focus 落未来 slot → 退化为「pin 在已揭示最新边」（禁前窥的必然结果，非缺陷）。
- **测试更新**：`freeScrollingFocusInvariant` 改为「focus 落已揭示 candle」的 tick（如 currentIdx≥focal，invariant 仍成立）**或**重设计为「currentIdx==0/早 tick focus-on-future → pin 后 startIndex/pixelShift 一致」断言。
- **审计义务（plan/impl 必做）**：上述 **6 suite 逐一**核新公式下的期望——凡断言「前向滚动后 startIndex > baseStartIndex」「focus-on-future 不变量」「slice 含 currentIdx 之后根」者更新为新语义；不依赖这些的保持绿（回归基准）。**已知变更**：RenderStateBuilderTests §三 5 case + `TrainingEnginePinchTests.freeScrollingFocusInvariant`。其余 suite 的逐测结论由 plan 阶段审计补全（本 RFC 设语义 + 标 scope，plan 穷举）。

---

## 四、关键设计决策

- **D1 禁前窥（user 裁决）**：最新可见=当前 tick；不允许「允许前窥但灰显未来」（仍泄漏未来走势信息，违 trainer 前提）。
- **D2 早 tick 左填充（沿用既有语义）**：revealed < target 时，已揭示根靠左、currentIdx 落 slot=currentIdx、右侧空槽（同既有 `anchorShortHistory`），**不**右对齐（右对齐会改 candle 屏幕位置语义、扩散到坐标映射/十字光标/画线，超本 RFC）。
- **D3 candleStep 分母仍 target**（不变，宽度稳定 + 与顺位 3 一致）；仅改 startIndex 上限 + sliceEnd 上限。
- **D4 单一真相不破**：仍仅 makeViewport 拥有 startIndex/slice 装配；visibleCandleRange/make 经它自动获新行为。
- **D5 下游 W3-11-R1 rebase**：reveal 修好后，offsetBounds 重做为 `minOffset=0` / `maxOffset=max(0,baseStartIndex)·candleStep`（消 R2 死区 + R3 未来，bounds 测随之简化）；R1a 的 geometryCore 抽取仍复用（geometryCore 改返新 upperBound 语义）。**provenance（opus R1-H2）**：W3-11-R1 的设计/实现（含 `2026-06-15-w3-11-r1-bounce-wiring-design.md` + R1a 代码）**parked 在分支 `wave3-w3-11-r1-bounce-wiring`，不在本 RFC 分支/main**；本 RFC merge 后，该分支 rebase onto 含本 reveal 修复的 main、按 D5 重做 offsetBounds。本节对该下游的引用为**前瞻**（其文档在 parked 分支可 `git show wave3-w3-11-r1-bounce-wiring:…` 查），非本仓现有文件。
- **D6 治理边界**：改顺位 3 冻结视口几何 = RFC（本文档）+ opus 对抗 review 到收敛 + writing-plans + codex:adversarial-review。**不** claim 行为中性（明为行为修正）。

---

## 五、测试

1. **不变量（核心）**：跨 tick（早/中/晚 currentIdx）× 跨 offset（autoTracking/backward/forward-fling/large-both）扫描，断言 **`startIndex + viewport.visibleCount − 1 ≤ currentIdx`**（slice 末根永不越 currentIdx）**且 `viewport.visibleCount ≥ 1`**（opus R1-L2：防空切片 regression 崩 `make()` 的强切 slice）。
2. **前向滚动禁**：任意负 offset → `startIndex ≤ max(0, baseStartIndex)`（不越 autoTracking）。
3. **早 tick 修复**：count=200/tick=10 → `viewport.visibleCount==11`、slice 末根==currentIdx==10（无未来）。
4. **backward 历史**：大正 offset → startIndex==0（至最旧）+ pixelShift==0。
5. **既有测更新**：§三列的 4 个变更 case 改期望 + 不变 case 保持绿（回归基准）。
6. **全量 host + Catalyst**：`swift test` 全绿 + `** TEST BUILD SUCCEEDED **`。
7. **device runbook 注**：reveal 修复后，Wave 3 运行时矩阵的「前向滚动不显未来 / 开局不显未来」作新增 device 验收项（归 Wave 3 矩阵或本 RFC acceptance）。

---

## 六、file refs（grep 核实 2026-06-15）

- `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:58-93`（makeViewport：改 upperBound :77 + sliceEnd :87）+ `:95-102`（currentCandleIndex，不改）+ `:22/:26`（make 传全集 + slice）
- `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift:72`（draw visibleCandles，无 currentIdx 约束——本 RFC 经 makeViewport slice 收口，KLineView 不改）
- `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（§三列的变更/不变 case + 新不变量测）
- 下游 parked：`docs/superpowers/specs/2026-06-15-w3-11-r1-bounce-wiring-design.md`（R1a rebase per D5）；顺位 3：`docs/superpowers/specs/2026-06-13-wave3-pr3-pinch-zoom-design.md`（冻结几何来源）

---

## 七、验收 / 治理

- **评审通道**：改 `ios/**/*.swift`（顺位 3 冻结视口几何）→ `codex:adversarial-review`（配额耗尽 fallback opus 4.8 xhigh）+ Catalyst + app-build。
- **非-coder acceptance checklist**：host 不变量测核 + §五.7 device runbook（前向/开局不显未来）。
- **ledger**：本 PR 属独立 bugfix RFC，**不**碰 Wave 3 completion doc 治理块（per 并行编排 ledger-B；Wave 3 矩阵新增 device 项归收尾 reconciliation 或本 RFC acceptance 自记）。

---

## Changelog

| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-06-15 | v1 (draft) | revealed-prefix window：makeViewport 两处改（upperBound→max(0,baseStartIndex) 禁前窥 + sliceEnd→min(…,currentIdx+1) 修早 tick）；不变量=slice 末根≤currentIdx；既有测 4 变更 case 列；下游 W3-11-R1 rebase（minOffset=0/maxOffset=baseStartIndex·step）；治理=改顺位 3 冻结几何 RFC |
| 2026-06-15 | v1.1 (opus spec-review R1 修) | R1 独立实算确认核心不变量数学严密（200+ tick×offset×target 零泄漏零空切片 + 4 变更值 + D5 bounce 边界全核对正确）。**C1**：§三补漏 `oneSixtyVisibleSaturates`（vc 160→151）；**H1**：`endToEndFocusInvariant` 列「不变」；**H2**：澄清 bounce 文档 parked 分支；**M1**：收紧可达性；**M2**：注最新边 micro-drag pin；**L2**：visibleCount≥1。 |
| 2026-06-15 | v1.2 (opus spec-review R2 修) | R2 确认 R1 全 RESOLVED + 核心不变量再核严密。新 **C1'**：跨 suite 测试 `TrainingEnginePinchTests.freeScrollingFocusInvariant`（非 RenderStateBuilderTests）新公式硬失败（currentIdx==0 focus-on-future → reveal-pin → uBefore40.5≠uAfter20.25）→ 揭 **reveal × pinch-zoom focus 不变量根本冲突**。新增 **§三.B 跨 suite 影响审计**：枚举 2 代码（PinchZoomModel/TrainingEngine pinch）+ 7 测试 suite；裁决 focus 不变量仅 focus-落已揭示-candle 时成立、focus-on-future 退化 pin（禁前窥必然，非缺陷）；plan 阶段穷举 6 suite 逐测更新。L3' D5 计数四→六（补 explicitEightyMatchesGolden/zeroFallsBackToEighty 实算不变）。待 opus R3 复核 |
| 2026-06-15 | v1.3 (opus spec-review R3 APPROVE 收敛) | R3 §三.B 消费面精校：实际几何消费测试 suite **6**（v1.2 笔误「7」更正——`DefaultDrawingInputControllerTests` 直接构造 `ChartViewport` 测 CoordinateMapper 逆映射、不消费几何公式，移出 scope）；代码消费面 = `RenderStateBuilder`（owner）+ `PinchZoomModel`（pinch focus）+ `TrainingEngine`（applyPinch/rezoomOffset + activateDrawingTool→visibleCandleRange）+ `ChartContainerView`（经 makeViewport 透传、无独立几何、无 host 测）。R1/R2 全 RESOLVED。设计收敛 APPROVE。 |
| 2026-06-15 | v1.4 (codex branch-diff attest R4 [HIGH] · 作用域诚实化) | 实施后 codex:adversarial-review（治理闸门）发现 [HIGH]：本不变量对**聚合周期**未消除泄漏——`currentCandleIndex`（首个 endGlobalIndex≥tick）指向进行中聚合 candle，其 finalized OHLC 含未来 m3 tick（实证 sparse ends `[3,7,11]` @ tick=1 → 末根 endGlobalIndex=3>1）。三道 opus review 均漏（测试工厂 endGlobalIndex==index 1:1 盲区）。裁决：本 RFC 作用域 = **m3 轴窗口泄漏**（严格改进，未使聚合变差）；聚合泄漏超 D-currentCandleIndex「不改」范围 → §二「作用域限制」+ HIGH residual + 独立「聚合感知 reveal」后续 RFC。codex 正确维持 needs-attention；本 PR 经 user attest-override 接受 documented residual 合入。 |
