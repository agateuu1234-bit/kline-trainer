# RFC-F：开局预放历史 + DEBUG fixture 周期比例修正（设计 spec）

- 日期：2026-06-21
- 分支：`feat/fixture-period-preload`（基线 main `4be9c74` = PR #128）
- 路线图：`docs/superpowers/2026-06-21-trade-ui-overhaul-roadmap.md` 顺位 1（RFC-F）
- 评审通道：Opus 4.8 xhigh 对抗 review（代 codex；codex 周配额耗尽，与 PR #122–128 一致）
- 范围决策（user 已拍）：**合并 F（F1 + F2 一个 RFC），整体按生产 RFC 走完整 review**

---

## 0. 背景与问题（聚焦调查结论）

PR #128 真机/模拟器实测暴露两个 DEBUG fixture 问题：① 周期比例错（各周期根数不合主流比例）；② 开局近空（`tick=0` 只显 1 根）。

路线图原假设 F 是「全 `#if DEBUG`、零生产改动、生产真实数据已对、只需 fixture 复刻」。**三路独立只读调查推翻了这个前提**：

1. **渲染器**（`RenderStateBuilder.swift:78-91,203-220`）：`tick=0` → `currentCandleIndex` = 数组下标 0 → reveal「禁前窥」约束（RFC #113，`docs/superpowers/specs/2026-06-15-chart-reveal-constraint-design.md`）把可见窗口钳到 `sliceEnd = min(startIndex+visibleCount, currentIdx+1) = min(80,1) = 1`。**`tick=0` 永远只渲染 1 根，与 `defaultVisibleCount=80` 无关**。

2. **后端**（`backend/generate_training_sets.py:77-113`，spec §8.3 `kline_trainer_plan_v1.5.md:1125-1132`）：真实训练集**确实**含 before-candle，但 `assign_global_indices` 把 before+after 一起编号 `global_index = 0,1,2,…`，所以**最老的 before-candle 在 `global_index 0`**，真正起始点落在 `global_index ≈ before_count`。

3. **引擎**（`TrainingFlowController.swift:43`；`TrainingSessionCoordinator.swift:148,279`）：`NormalFlow.initialTick=0`、`ReplayFlow.initialTick=0` 写死；`meta.start_datetime` 仅用于记录年/月显示，**从不用来算起始 tick**。

**结论**：`initialTick=0` 下，**真实生产数据开局同样只显 1 根**（会从最老 before-candle 逐根 reveal）。要开局显历史，必须**把起始 tick seed 到起始点**（`= meta.start_datetime 对应的 m3 global_index`）。这是**改生产引擎**、且改变真实数据行为的事——不是纯 fixture DEBUG 修正。spec §8.3 只规定了数据侧（存 before），引擎侧「把播放头放到起始点」**既无 spec、也未实现**——本 RFC 补这半边。

## 1. 目标 / 非目标

**目标**
- G1（引擎）：新开 Normal / Replay 局时，播放头从**起始点**（`meta.start_datetime` 对应的 m3 global_index）开局，使开局即显约一屏历史 before-candle；之后每 tick 右移 +1（reveal 不变）。真实数据与 fixture 一并修对。
- G2（fixture·F2）：DEBUG fixture 在起始点前**预放 before-candle**，`meta.startDatetime` 指向起始点（非 index 0），让模拟器能看到开局历史。
- G3（fixture·F1）：修周期聚合 span 与总根数，使各周期根数合主流比例（60 分/日线 4:1 精确、最大缩小 240 根铺满）。

**非目标 / 显式不做**
- 不改 reveal「禁前窥」约束（RFC #113）本身——本 RFC 与其**不冲突**：before-candle 在播放头**后方**，不是「未来」。
- 不改 `defaultVisibleCount`（保持 80，正常 K 线比例）。user 明确：不缩小，开局正常比例显示一屏（约 80 根），更早历史在屏外左滑可看。
- 不改 `NormalFlow`/`ReplayFlow` 值类型签名、不改 `TrainingEngine.make` 签名（均已支持 `initialTick` 覆盖）。
- 不动 `ReviewFlow`（`initialTick=record.finalTick` 已在末态、历史在后方，开局即显历史）。
- 不动 `resumePending`（用 `pending.globalTickIndex` 续，是用户上次位置）。
- 不改训练组 SQLite schema、不改 `global_index` 0 基连续轴约定、**不 bump `CONTRACT_VERSION`**（见 §6）。

## 2. 确认的开局行为（user 定）

- 进训练界面：当前周期**最新已 reveal 的根 = 起始点**，贴**画面最右边**，正常 K 线比例。
- 屏幕按正常比例放约 80 根；更早的历史（before-candle 里放不下的）在**左边屏外**，左滑 / pan 可看，pan 边界到最老 before-candle（`OffsetBounds` 已支持）。
- 每点一下（买/持/卖）→ 当前周期 +1 根，最右边换成新最新根（现有 reveal 逐根行为，不改）。
- 上下滑切周期不变，切哪个显哪个周期自己的 before 历史。

## 3. 设计

### 3.1 引擎侧（G1）—— 起始点 tick 派生 + 注入

**机制**：`make(_:allCandles:initialTick:…)` 已有可选 `initialTick`（`TrainingEngine.swift:178`），内部 `startTick = initialTick ?? flow.initialTick`（L215）并校验 `flow.allowedTickRange.contains(startTick)`（L216）。当前 `startNewNormalSession` / `replay` **不传** → 落到 `flow.initialTick=0`。修复 = 这两处计算起始点 tick 并传入。

**起始点 tick 定义**（纯函数，新增 `TrainingEngine` 静态 helper）：
```
startTick(forStartDatetime d: Int64, in allCandles) -> Int
  = m3 数组中第一个 datetime >= d 的下标
  （m3 轴连续 globalIndex==endGlobalIndex==index，故下标 == global_index == tick）
  - 找不到（d 超过所有 m3）→ 返回 0（降级；make 的 allowedTickRange 校验兜底，损坏数据走 .emptyData）
```
- 用二分（m3 datetime 严格递增，已由 `isStrictlyIncreasingM3Datetime` 保证；复用 `BinarySearch`）。
- `startTick` ∈ `0...maxTick`：起始点在 after 窗口前缘，`< maxTick`（after 非空，`make` 已校验）。
- **精确退化不变量（R1-C1/H1 修正）**：`startTick == 0` **当且仅当 `meta.startDatetime ≤ m3[0].datetime`**。注意这**不是** `meta.startDatetime == m3[0].datetime`——只要 `meta.startDatetime > m3[0].datetime`（哪怕只大 1），首个 `≥` 落到 index ≥1。真实数据 `meta.start_datetime` 落在数据内部、`m3[0]` 是最老 before、故 `> m3[0]`，得正确的非零 startTick；新 fixture `meta.startDatetime = m3[beforeM3Count].datetime` 精确命中起始点。**但既有测试桩不满足此不变量**（见 §5 C1）。

**改动点（2 处，对称）**（行号已对实际源码核正，R1-M1）：
- `TrainingSessionCoordinator.startNewNormalSession`（`make` 调用在 L171-174，`loadAllCandles` 在 L169）：`loadAllCandles` 后加 `let meta = try reader.loadMeta()`，算 `let startTick = TrainingEngine.startTick(forStartDatetime: meta.startDatetime, in: allCandles)`，`make(.normal(…), allCandles:, initialTick: startTick, …)`。
- `TrainingSessionCoordinator.replay`（`make` 调用在 L293-297；当前**未** `loadMeta`，需新增）：同样 `loadMeta` + 算 `startTick` + `make(.replay(…), initialTick: startTick, …)`（「再来一次」从起始点重开，与 Normal 一致）。

**不改 `allowedTickRange`（保持 `0...maxTick`）**：Normal 只 `canAdvance` 前进、无 rewind 能力（Capability Matrix），tick 从 `startTick` 单调前进到 `maxTick`，永不触及 `< startTick`；保持 `0...maxTick` 既满足 `make` 的 `contains(startTick)` 校验，又避免改冻结值类型。before-candle 经 pan（offset，非 tick）可见，与 tick 下界无关。

**为何不改 `NormalFlow.initialTick`**：那是 `maxTick`-only 的纯值类型，不知起始点；由 caller（持 m3+meta）算 `startTick` 注入是最小且无契约面改动的路径。`flow.initialTick=0` 作为「无 meta 信息时的默认」保留语义正确（无 before ⇒ 起点即 0）。

### 3.2 Fixture 侧（G2 + G3）—— before/after 结构 + 周期比例

**当前**（`DebugFixtureData.swift`）：`make(m3Count:)` 生成 `m3Count` 根 m3（`globalIndex==endGlobalIndex==i`，0 基连续），`meta.startDatetime = m3Rows.first!.datetime`（= index 0，**零 before**），其余 5 周期按 span 聚合（`global_index=nil`、`end=组末 m3 index`）。

**改动**：
1. **F1 周期比例（参数已钉死）**：聚合 span 改为 `m15=5 / m60=20 / daily=80 / weekly=160 / monthly=240`（当前 5/20/40/80/120）；`fullLoadM3Count` 9600→**19,200**。
2. **F2 before/after 结构**：`make` 新增参数 `beforeM3Count: Int = 0`（默认 0 = 向后兼容旧「零 before」行为，现有 `make(m3Count: 240)` 测试不变）；新增常量 `fullLoadBeforeM3Count = 12,000`（after = 19,200−12,000 = 7,200）。`meta.startDatetime = m3Rows[beforeM3Count].datetime`（`beforeM3Count==0` 时退化为 `m3Rows[0]` = 旧行为）。**前置守卫（R1-H2）**：`precondition(beforeM3Count >= 0 && beforeM3Count < m3Count)`——DEBUG fixture trap 调用方 bug（防 `m3Rows[beforeM3Count]` 越界），与本仓既有 fixture「trap-on-caller-bug」约定一致。m3 的 `globalIndex/endGlobalIndex` **仍 0 基连续覆盖整条 before+after 序列**（不变，与真实后端一致），起始点落在 `global_index = beforeM3Count`，故 §3.1 的 `startTick` 派生 → `beforeM3Count`（满载 = 12,000）。
3. **聚合不变**：`aggregate(span:)` 仍从 m3 index 0 按 span 切块；`beforeM3Count` 选为 **lcm(spans)=480 的倍数**（12,000 = 480×25），使每周期 before/after 边界都落在该周期 candle 边界上、各周期 before/after 根数皆整数。
4. **seed 路径接线**：`AppContainer+DebugSeed.swift:33` 由 `make(m3Count: fullLoadM3Count)` 改为 `make(m3Count: fullLoadM3Count, beforeM3Count: fullLoadBeforeM3Count)`——否则 app 实际 seed 仍是零 before（开局 1 根 bug 未消）。grep 证实 `DebugFixtureData.make` 的**唯一生产调用方**即此行（其余皆 `*Tests` 内，R1-L1 已核），故这是唯一让 app 真正吃到 before 的接线点，须随本 RFC 落地并被测试覆盖。

**满载根数表（fullLoadM3Count=19,200，before=12,000 / after=7,200）**：

| 周期 | span | before | after | total |
|---|---|---|---|---|
| m3 | 1 | 12,000 | 7,200 | 19,200 |
| m15 | 5 | 2,400 | 1,440 | 3,840 |
| m60 | 20 | 600 | 360 | 960 |
| daily | 80 | **150** | 90 | 240 |
| weekly | 160 | 75 | 45 | 120 |
| monthly | 240 | 50 | 30 | 80 |

- 满足既有约束：每周期 total ≥ `defaultVisibleCount(80)`；默认面板 `m60`(960)/`daily`(240) ≥ `maxVisibleCount(240)`（pinch 最远档铺满）。
- 满足 F2 新约束：默认面板 before ≥ 80（`daily=150`、`m60=600`），开局填满一屏历史且可左滑回看；`daily before=150` 恰与 spec §8.3（daily=150）对齐。
- 每周期 before ≥ 30（最小 `monthly=50`），不破坏 reader 的 warmup 类约束。

**开局可见性核验（默认面板，`visibleCount=80`，`startTick=12,000`）**：
- `daily`：`currentCandleIndex(12,000)` = `daily[150]`（含起始点的日线，`endGlobalIndex=12,079≥12,000`）；窗口 `daily[71…150]` = 80 根（79 根纯历史 + 起始日线），左滑可至 `daily[0]`（共 150 根历史）。✔
- `m60`：`currentCandleIndex(12,000)` = `m60[600]`；窗口 `m60[521…600]` = 80 根，左滑可至 `m60[0]`（共 600 根历史）。✔

### 3.3 fixture 结构限制（必须写明，呼应 user 共识）

真实后端**每周期独立查真实历史**（daily 真有 150 根独立日线、跨度数月）；DEBUG fixture **从单条 m3 序列聚合**所有周期（为保两图时间对齐 / 全局 tick 轴一致），因此**做不到「每周期各自独立 150」**——同一时间窗聚合下，细周期 before 多（m3=12,000、m15=2,400）、粗周期 before 少（weekly=75、monthly=50）。fixture 只保证**默认面板（m60/daily）开局有一屏历史**；真正的「每周期独立 150」要等真实数据（NAS，W1-R2）落地。此为已知 fixture↔真实差异，非缺陷。

## 4. 受影响 / 不受影响清单

**改动文件**
- `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`：+ 静态 `startTick(forStartDatetime:in:)` helper（纯函数，二分）。
- `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`：`startNewNormalSession`（L168 区段）+ `replay`（L286 区段）各 + `loadMeta` + 算 `startTick` + `make(initialTick:)`。
- `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift`：spans + `fullLoadM3Count` + `+ beforeM3Count 参数` + `fullLoadBeforeM3Count` 常量 + `meta.startDatetime` 指向起始点。
- `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift`：seed make 调用传 `beforeM3Count: fullLoadBeforeM3Count`（§3.2.4）。
- 测试：新增 `startTick` helper 单测（含 before / 无 before / 边界 / 找不到降级）；coordinator 起始 tick 集成测（含 before 的内存 reader）；`DebugFixtureDataTests` 新增 before/after 根数表 + `startDatetime==m3[12000]` 断言 + seed 接线断言；既有满载测试因用 `≥` 比较 + total 与 before 无关而**仍通过**（仅注释里 stale `9600` 文案需更新）。

**不改**
- 训练组 SQLite schema、`DebugTrainingSetWriter`（schema 不变，仅写入的数据值变）。
- `global_index` 0 基连续轴约定、reader 不变量、reveal RFC #113。
- `NormalFlow`/`ReplayFlow`/`ReviewFlow` 值类型、`make` 签名、`TickEngine`。
- `resumePending`（pending.globalTickIndex 续）、`review`（finalTick）。
- 生产 OHLCV/指标生成（`FixturePriceSeries`/`FixtureIndicatorMath` 逻辑不改，仅 count 变大）。

## 5. 行为变更与连带项（blast radius）

- **playable 区间语义**：Normal/Replay 实际游玩从 `startTick` 推进到 `maxTick`（= after 窗口）。before-candle 不被 tick 走过、仅作历史上下文。这**修正了**旧行为下「玩家从最老 before 开始、把历史也走一遍」的潜伏 bug。`allowedTickRange` 仍 `0...maxTick`（不影响单调前进）。
- **结算/强平**：force-close 在 `maxTick`（`forceCloseIfEnded` L458 / `performForceClose` L507），不受 `startTick` 影响。
- **drawdown / 总资金 / 收益率 seeding**：`make` 用 `startTick` 处 m3 收盘价做 `startTotal`（L130-135）——本就读 `startTick`，现 `startTick` 非 0 即正确反映起始点价。无新增数学。
- **既有 pending / record 向后兼容**：pending 存绝对 `globalTickIndex`，resume（`resumePending`）不变；record 存 `finalTick=maxTick`，review 不变。无迁移。
- **⚠️ R1-C1 修正：会破坏的既有测试（这是改 initialTick 语义的必然代价，非可回避）**。
  - blast radius 的**准确**边界 = 「**经 `startNewNormalSession` / `replay` 两路径**、且 reader/factory 的 `meta.startDatetime > m3[0].datetime` 的测试」。**不是**「仅有-before 数据」——既有协程集成测试桩恰好落在这个坑里：
  - 实证：`PreviewTrainingSetDBFactory` 默认 `meta.startDatetime = 1`（`InMemoryFakes.swift:35`，注释「避免 0 边界」），而 `validCandles()` 的 `m3[0].datetime = 0*180 = 0`、`m3[1].datetime = 180`（`TrainingSessionPersistenceTests.swift:13,19`）。新派生 `startTick = 首个 datetime ≥ 1 = index 1`（非 0）。
  - 故这些 fresh-tick 断言**会 FAIL**，须 plan 阶段逐一重基线：`TrainingSessionPersistenceTests.swift:133`（`p.globalTickIndex == 0`）、`:200`（`resumed... == 0`，pending 现存 tick 1 往返）、`TrainingSessionCoordinatorConstructionTests.swift` 的 fresh-Normal/replay `globalTickIndex == 0` 断言、以及任何经默认桩 meta 派生开局价/收益率的断言（`validCandles` close=`10+i*0.1` 会偏一根）。
  - **直接 `make`/`init`（不传 `initialTick`，走 `flow.initialTick=0`）构造引擎的测试不受影响**（如 `TrainingEngineActionsTests` 的 `globalTick==0`）——它们不经 coordinator 的 meta 派生。
  - **两种修法（plan 显式择一/逐测判定，不得回避）**：(a) 把受影响桩 meta 与 `m3[0].datetime` 对齐（注意 `validateMeta` 拒 `startDatetime ≤ 0`，故须令 `m3[0].datetime ≥ 1` 且 `meta == m3[0]`）；(b) 把断言重基线到新派生 tick（语义已变）。
- **§O3 拥有该枚举**：plan 阶段 `grep "globalTickIndex == 0" / "initialTick"` 出全量清单 + 逐测处置。§5 不预判「全绿」。

## 6. CONTRACT_VERSION：不 bump（论证）

- 当前基线 `CONTRACT_VERSION = "1.6"`（`Models.swift:7`；R1-M2 修正旧文档中 stale 的「1.5」）。本 RFC 后**仍 "1.6"**。
- 无 schema/DDL 变更；`klines`/`meta` 表结构不变。
- 无持久化格式变更：`global_index` 仍 0 基连续；`PendingTraining` 字段不变；fixture `meta.startDatetime` 改的是**数据内容**非格式。
- 变的是**运行期行为**（起始 tick），`CONTRACT_VERSION` 跟踪的是持久化兼容性，非运行行为。
- 旧 pending/record 在新代码下语义不变（§5）。
- 全部 fixture 改动在 `#if DEBUG` 内；引擎改动在生产但无格式面。
- ⇒ **不 bump**。spec 阶段已核；plan/review 复核。

## 7. 测试策略

- **纯函数单测**：`startTick(forStartDatetime:in:)` —— ①起始点在序列中部（有 before）返正确 index；②起始点 == m3[0]（无 before）返 0；③`d` 在两 candle datetime 之间（取首个 `>=`）；④`d` 超末根 → 降级 0；⑤单根 m3 边界。
- **引擎/coordinator 集成测**：用「有 before 结构」的内存 reader/fixture → `startNewNormalSession` 得引擎 `tick.globalTickIndex == 预期 startTick`；`replay` 同；`resumePending`/`review` 起始 tick 不变（回归）。
- **fixture 测**（`DebugFixtureDataTests`）：满载下每周期 before/after/total 根数 = §3.2 表；`meta.startDatetime == m3Rows[12000].datetime`；m3 轴仍 0 基连续；指标非空（回归 PR #128）。
- **三绿验收**：host `swift test`（macOS）+ Mac Catalyst build-for-testing + app build；模拟器实测（`simctl uninstall` 再装，过全空 seed 守卫）开局可见约 80 根历史。
- **性能脚注（R1-L3，非正确性）**：`fullLoadM3Count` 9600→19,200 翻倍，`withIndicators`（MA66/BOLL/MACD）在 seed 时对每周期全 close 序列各算一遍（m3=19,200 行）。仅 DEBUG、首装一次性；既有满载测试多次调 `make(fullLoadM3Count)`，plan 须确认 seed/测试仍在 CI 超时内（如超，考虑测试降采样 count）。

## 8. 验收清单（非编码者可执行 · 中文 · action/expected/pass-fail）

> 模拟器 iPhone 17 Pro（udid `DE0BA39D-C749-459D-A407-4418599B61CA`）。**改 fixture 后必须先 `xcrun simctl uninstall <udid> com.agateuu1234.KlineTrainer` 再装**（全空 seed 守卫 `AppContainer+DebugSeed.swift` 否则不重灌）。

| # | 操作 | 预期 | 通过判定 |
|---|---|---|---|
| A1 | 卸载重装 app，开始新训练（Normal） | 进训练界面，**上图(60分)与下图(日线)开局即各显约一屏历史 K 线**（约 80 根），最右边是起始点那根 | 开局**不是只有 1 根**；两图都铺满历史；记为通过 |
| A2 | 在开局画面把图向右拖（看更早） | 能左滑看到更早的历史 K 线（日线可回看到约 150 根、60 分约 600 根） | 能滑出更早历史、到最老一根停住；通过 |
| A3 | 点一次「持有/前进」 | 当前周期最右边新增 1 根，画面右移一根 | 每点一次 +1 根；通过 |
| A4 | 上下滑切到日线/周线/月线/3分/15分 | 每个周期开局也显该周期自己的历史（粗周期根数较少属正常） | 切任一周期都非空、显历史；通过 |
| A5 | 看各周期根数比例 | 60分:日线 ≈ 4:1；最大缩小（pinch out）日线约铺满 240 根 | 比例对、缩放铺满；通过 |

**禁用语**（见 `.claude/workflow-rules.json`）：不得用「应该能/大概/理论上」等模糊词；每条须可现场点出 pass/fail。

## 9. 开放问题（plan 阶段定）

- O1：`startTick` helper 放 `TrainingEngine` 静态 vs 独立纯函数文件 —— 倾向复用 `TrainingEngine` 既有 `BinarySearch`/轴不变量，放静态。
- O2（已收敛方向）：`make(m3Count: Int = 240, beforeM3Count: Int = 0)`，默认 0 保现有小-count 测试不变；满载 seed 与新 before/after 测试显式传 `beforeM3Count: 12000`（480 倍数）。plan 定签名与新测试取值。
- O3：plan 阶段 grep `globalTickIndex == 0` / `initialTick == 0` 全量清单，逐一判定零-before（不变）vs 需补的有-before 断言（§5）。
