# 设计文档：两图 pan 时间对齐联动（UI 改版 RFC #4）

> **状态**：设计已与用户确认（联动语义 = 时间对齐跟随 / always-on / 双向 / follower 连惯性减速逐帧跟随）。本文档为冻结 spec 的修订 RFC，需经 Opus 4.8 xhigh 对抗性 review 收敛后转 writing-plans。
> **日期**：2026-06-20
> **前序**：UI 改版 4 子项 —— #3 坐标轴（PR #124）、#1 买卖栏（PR #125）、#2 历史弹窗（PR #126）已落地；本 RFC = **#4，最后一个**。
> **来源**：运行时验证「两图 pan 联动」。见 [[project_runtime_verification_findings_2026_06_17]]。

---

## 1. 目标与范围

### 1.1 一句话目标
拖动上下两个 K 线面板中任一个横向滚动时，另一个**按同一全局 tick 时刻重锚**，两图右缘永远对齐到同一时刻（跨周期时间对齐），包括松手后的惯性减速也逐帧同步。

### 1.2 范围内（in scope）
- 上下两面板（`PanelId.upper/.lower`）pan/scroll 的**时间对齐联动**：leader（被拖面板）驱动 follower（另一面板）右缘对齐到同一 tick。
- 覆盖三条 leader 驱动路径：手指拖动（drag）、松手惯性减速（deceleration）、起手（beginPan，含 follower 模式同步）。
- 新建平台无关纯逻辑层 `PanLinkage`（tick↔offset 跨周期换算），host 全测。
- 相应修订冻结 spec（plan「双面板各自独立 offset」描述增补 pan 时间联动）+ 新验收清单。

### 1.3 范围外（out of scope，明确不碰）
- **Y 轴联动**（plan §811 deferred「Phase 5 锁定 Y 轴」）—— 两面板 Y 轴维持各自独立。
- **缩放（pinch）联动** —— 仅 pan 联动；pinch 维持各自独立。
- **十字光标联动** —— 不做（用户已在 brainstorming 否决 C 选项）。
- **锁定/解耦开关** —— always-on，不加 toggle UI/状态。
- **frozen M0.3 类型**（`Period`/`PanelId`/`KLineCandle`，`Models.swift:11/45/59`）—— 不改。
- **frozen C1b 契约**（`ChartAction`/`PanelViewState`/`ChartReduceEffect`）—— 不加新 action，复用现有 `.offsetApplied`/`.panStarted`。
- **CONTRACT_VERSION** —— 不 bump（无 Codable/DDL/模型/契约触点）。
- 现有 pan 物理（rubber-band overscroll / floor-or-full clamp / reveal 禁前窥）—— leader 行为一字不改。

---

## 2. 现状（待改造的代码事实）

精确锚点（写 spec 时实测；下游 plan 须按当时实际行号复核）：

### 2.1 两面板与周期
- `Models.swift:11-18` `enum Period`（6 态 m3/m15/m60/daily/weekly/monthly，String raw，**无时长映射**——时间由 tick 承载非 datetime）。
- `Models.swift:45-47` `enum PanelId { case upper, lower }`。
- `Models.swift:73` `KLineCandle.endGlobalIndex: Int`（该 K 线收盘对应的全局 tick；`globalIndex: Int?` L72）。
- `TrainingEngine.swift:320` `periodCombos: [(.m3,.m15),(.m15,.m60),(.m60,.daily),(.daily,.weekly),(.weekly,.monthly)]`（upper 细 / lower 粗；默认 upper=.m60, lower=.daily）。
- `TrainingEngine.swift:32` `allCandles: [Period: [KLineCandle]]`（同一源按各周期预聚合；两面板查各自 period 数组）。
- 共享时间轴 = `engine.tick.globalTickIndex`（`TickEngine`，两面板唯一时间状态）。

### 2.2 per-panel offset 与 pan（**当前完全独立**）
- `TrainingEngine.swift:600` `applyOffsetDelta(_ delta:, panel:)` = **唯一** offset 变更入口（→ `reduce(.offsetApplied(deltaPixels:), on: panel)`）。offset 单位 = **像素**，右缘锚定（offset=0=autoTracking rest=最新 tick；增大→朝更旧）。
- `TrainingEngine.swift:663` `beginPan(panel:)`：`interruptDeceleration` + seed dragRaw + `reduce(.panStarted)`（autoTracking→freeScrolling）。
- `TrainingEngine.swift:677` `applyPanOffset(deltaPixels:renderBounds:panel:)`（**public drag 路径**）：算 offsetBounds + drag full-clamp + 最老边 rubber-band，末尾 `applyOffsetDelta(target-cur, panel:)`。
- `TrainingEngine.swift:621` `floorOrFullClampedOffsetDelta(_ delta:, panel:)`：**减速/bounce 每帧（animator onUpdate）**，clamp 后 `applyOffsetDelta`。
- `TrainingEngine.swift:699` `endPan(velocity:..panel:)`：仅 **leader** `animator(for:panel).start()`（per-panel animator tuple）。
- `ChartContainerView.swift:87-95` `arbiter.onPan`：每面板独立 Coordinator，`.began→engine.beginPan(panel:self.panel)` / `.changed→engine.applyPanOffset(...,panel:self.panel)` / `.ended→engine.endPan(...,panel:self.panel)`，**永远只传本面板**。
- `ChartContainerView.swift:131` `engine.recordRenderBounds(bounds, panel:)` → engine 持有**每面板 lastRenderedBounds**（联动算 follower offset 所需）。
- **lockstep reset（既有，两面板一起）**：`TrainingEngine.swift:653` `resetOffsetAfterAutoTracking(panel:)`（offset 归 0），在 trade（`advanceAndAccount` ~L383-384）与 `switchPeriodCombo`（~L344-345）后对 **upper+lower 各调一次**（直接经 `applyOffsetDelta`，**不经 gesture 入口**）。

### 2.3 视口数学（offset ↔ candle index，联动换算的基石）
`Render/RenderStateBuilder.swift`：
- `:78` `geometryCore`：`visibleCount=min(rawVisible,count)`、`candleStep=mainFrameWidth/rawVisible`、`baseStartIndex=currentIdx-(visibleCount-1)`、`upperBound=max(0,baseStartIndex)`（reveal 禁前窥）。
- `:172` `makeViewport`（**forward**：offset→startIndex）：`wholeShift=Int(floor(offset/candleStep))`、`startIndex=clamp(baseStartIndex-wholeShift, 0, upperBound)`。→ 右缘可见候选 ≈ `currentIdx - wholeShift`（reveal 钳 ≤ currentIdx）。
- `:123/:141` `offsetBounds`：`minOffset=0`（最新边**硬钳**，reveal 非弹簧）、`maxOffset=roundTripEdge(baseStartIndex,step)`（最老边）。
- `:217` `currentCandleIndex(candles:tick:)`：`partitioningIndex { endGlobalIndex >= tick }` 钳 count-1（**面板自身 period 定位**；同一 tick 在两面板落不同下标，但同一时刻）。
- `:154` `roundTripEdge(integer:step:)`：FP verify-and-correct（非整除 step 下 `Int·step` floor 偏 1 的钉死，联动逆运算复用）。

### 2.4 既有跨面板对齐先例（联动可行性证明）
markers 只存 `globalTick`，每面板各自 `currentCandleIndex` 重投影到自身 period（`MarkersLayout`）—— **共享 tick 轴已让跨面板时间对齐免费可得**，本 RFC 把同一机制用到 pan。

### 2.5 冻结边界
`TrainingEngine`/`RenderStateBuilder`/`ChartContainerView` 均 Wave 2/3（`wave0-frozen-v1.4` **之后**，可改）。冻结的是 M0.3 类型 + C1b reducer 契约（§1.3 列）。本 RFC **不碰冻结项**（复用 `.offsetApplied`/`.panStarted`）。

---

## 3. 设计决策表

| # | 决策 | 选择 | 理由 |
|---|------|------|------|
| **D1** | 联动语义 | **时间对齐右缘跟随**（两图右缘锁同一 global tick），**不用**比例像素/十字光标 | 跨周期唯一有意义的对齐；复用共享 tick 轴（markers 已证）。用户经 brainstorming 明确选 A。 |
| **D2** | 开关 | **always-on**（无锁定 toggle） | 「联动」即默认；解耦是未来 toggle，本 RFC YAGNI 不做。 |
| **D3** | 方向 | **双向对称**（被拖面板=leader 驱动另一面板=follower） | iPhone 单指一次只一个 pan（two-finger=切周期），leader 无歧义。 |
| **D4** | follower 是否跟惯性减速 | **跟**（leader 减速逐帧驱动 follower）；follower **不跑自己的 pan/减速** | 否则松手后两图脱节再吸附，丑。follower 纯被 leader 驱动。用户确认。 |
| **D5** | 联动挂载点 | **仅 gesture 入口**（`beginPan` / `applyPanOffset(renderBounds:)` drag / `floorOrFullClampedOffsetDelta` decel），**不挂**通用 `applyOffsetDelta` | **根治双驱**：trade/combo 的 `resetOffsetAfterAutoTracking` 直接经 `applyOffsetDelta` 且**已对两面板 lockstep**；若挂通用入口，reset 会再经联动二次驱动 follower。gesture 入口只在被拖面板触发（Coordinator 传 self.panel），故联动只在用户滚动+其惯性时发生。 |
| **D6** | follower 驱动方式 | 复用现有 **`.offsetApplied(deltaPixels:)`**（经 `applyOffsetDelta(target-cur, follower)`）；**不新增 ChartAction** | 不碰冻结 C1b 契约；offset 变更单一真相不变。 |
| **D7** | follower 模式一致性 | leader `beginPan` 时，follower 也转 **freeScrolling**（`reduce(.panStarted, follower)`） | follower 即将被推离 offset=0；autoTracking+offset≠0 语义不一致（makeViewport mode-agnostic 仍渲染但状态脏）。 |
| **D8** | clamp / 无反噬 | follower 用**自身 offsetBounds** clamp 到 `[0, maxOffset]`（reveal minOffset=0 硬钳）；**永不反向驱动 leader** | 单向 leader→follower 根治 feedback loop（R4）。两周期同覆盖 [0,当前tick]，仅最老边因可见根数不同轻微错位，可接受。 |
| **D9** | 纯逻辑下沉 | 新建 `PanLinkage`（平台无关），复用 `RenderStateBuilder.{currentCandleIndex,geometryCore,offsetBounds,roundTripEdge}`，**不重写**几何 | 给跨周期换算（最易错）host 自动化覆盖；单一几何真相不漂移（D4 单一真相原则）。 |
| **D10** | drawing-mode follower | 现有 reducer 在 drawing 态**吞** `.offsetApplied` → follower 不跟（暂 desync），下次 pan/trade/combo 复位 | 画线冻结该面板是既定语义；不为此破例。可接受边界。 |
| **D11** | bounce/overscroll follower | follower **不**独立 bounce；clamp 到自身 [0,maxOffset]（leader 最老边 rubber-band 时 follower 钉边） | follower 是被驱动者，无独立手势物理。视觉错位仅在极老边，R3 可接受。 |
| **D12** | leader 行为 | **一字不改**（drag full-clamp / rubber-band / reveal / 自己的减速全保留） | 外科式；联动是在 leader 各帧之后**追加** follower 驱动，不改 leader。 |

---

## 4. 架构

### 4.1 联动总流（全在 `TrainingEngine`）
新增一个 private 中枢 `propagateLinkage(fromLeader:)`，在三个 gesture 入口的 leader 帧**之后**调用：

```
beginPan(panel: L):                       // L = leader（被拖）
    [现有] interruptDeceleration + seed dragRaw + reduce(.panStarted, L)
    + reduce(.panStarted, follower(L))    // D7：follower 转 freeScrolling
    + propagateLinkage(fromLeader: L)     // 对齐一次（含 re-grab 后 interrupt clamp 的新右缘）

applyPanOffset(deltaPixels:renderBounds:panel: L):   // drag 每帧
    [现有] 算 target + applyOffsetDelta(target-cur, L)
    + propagateLinkage(fromLeader: L)

floorOrFullClampedOffsetDelta(delta:panel: L):       // 减速/bounce 每帧（animator onUpdate）
    [现有] clamp + applyOffsetDelta(...，L)
    + propagateLinkage(fromLeader: L)
```

`propagateLinkage(fromLeader: L)`：
```
F = follower(L)                                   // upper↔lower
guard let lBounds = lastRenderedBounds(L), let fBounds = lastRenderedBounds(F) else return  // 无 bounds 不联动
let leaderTick = PanLinkage.rightEdgeTick(offset: panelState(L).offset,
                    candles: allCandles[period(L)], rawVisible: panelState(L).visibleCount,
                    candleStep: stepOf(L,lBounds), currentIdx: currentIdx(L))
let fTarget = PanLinkage.followerOffset(targetTick: leaderTick,
                    candles: allCandles[period(F)], rawVisible: panelState(F).visibleCount,
                    bounds: fBounds, currentTick: tick.globalTickIndex)   // 内含 clamp [0,maxOffset]
let fCur = panelState(F).offset
if fTarget != fCur { applyOffsetDelta(fTarget - fCur, panel: F) }   // D6：经现有 .offsetApplied
```
> `endPan(velocity:..panel: L)`：**不改**——仅 leader 起 animator；follower 由 leader 减速帧（floorOrFull 路径）持续驱动，leader settle 即 follower settle（follower animator 全程不启）。
> `propagateLinkage` 经 `applyOffsetDelta`→`reduce(.offsetApplied)` 是**直接 reduce**，不重入 gesture 入口 → 单向无环（R4）。follower 在 drawing 态被 reducer 吞（D10）。

### 4.2 `PanLinkage` 纯逻辑（平台无关，host 全测）
```swift
public enum PanLinkage {
    /// forward：leader 当前 offset → 其右缘可见候选的 endGlobalIndex（= 右缘 tick）。
    /// 复用 makeViewport 的 wholeShift/startIndex 数学（不重写）。
    static func rightEdgeTick(offset: CGFloat, candles: [KLineCandle],
                              rawVisible: Int, candleStep: CGFloat, currentIdx: Int) -> Int

    /// inverse：目标 tick → follower offset（其右缘候选 endGlobalIndex 最接近 tick），clamp 到 follower [0,maxOffset]。
    /// targetRightEdgeIdx = currentCandleIndex(candles, tick: targetTick)
    /// wholeShift = currentIdx - targetRightEdgeIdx; offset = wholeShift·candleStep
    /// 再 clamp 到 offsetBounds(follower) 的 [minOffset=0, maxOffset]（reuse roundTripEdge）。
    static func followerOffset(targetTick: Int, candles: [KLineCandle],
                              rawVisible: Int, bounds: CGRect, currentTick: Int) -> CGFloat
}
```
- 两函数都是 `makeViewport` offset↔index 的 forward/inverse，**复用** `currentCandleIndex`/`geometryCore`/`offsetBounds`/`roundTripEdge`。
- 输入纯值（candles + 几何标量）→ 可逐值 host 断言（跨周期换算 / clamp / 同 tick 对齐 killer）。

### 4.3 数据流
拖 upper（leader）→ `applyPanOffset(...,.upper)` 更新 upper offset → `propagateLinkage(.upper)` 算 upper 右缘 tick → 换算 lower 目标 offset（clamp）→ `applyOffsetDelta` 驱动 lower → 两图右缘对齐同一 tick。松手 → upper 起减速 → 每减速帧 `floorOrFull(.upper)` + `propagateLinkage(.upper)` → lower 逐帧跟随至 settle。拖 lower 对称。

### 4.4 错误处理
无新增错误路径。无 bounds（瞬态零尺寸/未首渲）→ `propagateLinkage` guard return（不联动，安全）。空 candle → `offsetBounds`/`currentCandleIndex` 既有退化（[0,0] / 钳 count-1）。

---

## 5. 冻结 spec 修订点

| 文件 | 位置（写 spec 时实测，plan 复核） | 改动 |
|------|------|------|
| `kline_trainer_plan_v1.5.md` | §双面板独立描述（L109「PanelViewState×2 每面板独立 offset」/ L204「交互模式每面板独立」/ L552 / §6.2.3 L941-948） | 增补一句「pan/scroll **时间对齐联动**：拖一面板，另一面板右缘按同一全局 tick 跟随（offset 仍各自独立存储，由引擎跨周期换算驱动）」；**不删**「各自独立」（offset 存储仍独立，仅新增联动驱动）。 |
| `kline_trainer_plan_v1.5.md` | §4.1「多周期联动」附近（L579-601，**该处「联动」指 tick 步进**） | 加注脚区分：「tick 步进联动（既有）≠ pan 时间联动（RFC #4 新增）」防混淆。 |
| `kline_trainer_modules_v1.4.md` | §C 图表交互相关条目（如有「每面板独立 pan」描述） | 同步增补 pan 时间联动语义。 |

> 凡涉及不改类型名/契约：`Period`/`PanelId`/`KLineCandle`/`ChartAction`/`PanelViewState` 字面零改。grep 确认无新增 ChartAction case。

---

## 6. 测试策略（诚实交代）

1. **host 纯逻辑 TDD（核心覆盖，红绿）**：`PanLinkageTests` —— `rightEdgeTick` / `followerOffset` 的跨周期换算正确性（如 upper=.m60 offset=X → 某 tick → lower=.daily offset=Y 实算断言）、clamp（follower 够不到 leader tick 时钳 maxOffset）、同 tick 对齐（offset=0→follower=0）、FP round-trip（非整除 step）、空/退化。killer：删换算/反转 clamp 即红。
2. **host 回归网**：现有 `TrainingEngine`/`RenderStateBuilder` 测试全绿不回归（leader 路径未改，仅追加 follower 驱动；reset/trade/combo lockstep 未动）。
3. **新呈现/集成行为（D5 引擎接线，SwiftUI/engine 壳，不写 host 单测的部分）**：Mac Catalyst `build-for-testing` 编译闸 + iOS app build + **模拟器人工验收**（拖上图下图时间跟随、拖下图上图跟随、松手惯性同步、到最老边 graceful clamp、drawing 态 follower 暂不跟、trade/切周期后两图仍对齐）。

> 跨周期换算（最易错）有 host 自动化覆盖；引擎逐帧接线 + 视觉靠编译闸 + 人工。诚实边界。

---

## 7. 风险

| # | 风险 | 缓解 |
|---|------|------|
| **R1** | 跨不同 `candleStep` 的 tick↔offset 换算 FP 偏移（floor 偏 1） | 复用 `roundTripEdge` verify-and-correct（既有 C1a 机制）；PanLinkage host 测非整除 step 用例。 |
| **R2** | 减速逐帧驱动 follower 的性能/时序（每帧多一次 follower reduce+渲染） | follower 仅 1 次 `applyOffsetDelta`（与 leader 同量级）；`if fTarget != fCur` 省零 delta 空 bump；人工验收测流畅度。 |
| **R3** | follower 最老边 clamp 时与 leader 视觉错位 | 两周期同覆盖 [0,当前tick]，仅极老边 visibleCount 差致轻微错位；D8 接受。人工验收确认无突兀跳变。 |
| **R4** | feedback loop（follower 驱动反噬 leader / 无限重入） | **单向**：联动只在 gesture 入口按 leader 触发；follower 经直接 `applyOffsetDelta`（不重入 gesture 入口）。D5+D8 根治。 |
| **R5** | drawing 态 follower 不跟致 desync | reducer 既有吞 `.offsetApplied`（D10）；下次 pan/trade/combo 复位。人工验收记录为已知边界。 |
| **R6** | follower 模式脏（autoTracking+offset≠0） | leader `beginPan` 时 follower 同步 `.panStarted`→freeScrolling（D7）。 |
| **R7** | 与既有 lockstep reset 双驱 | 联动**不挂**通用 `applyOffsetDelta`，只挂 gesture 入口（D5）；reset 经 applyOffsetDelta 直达，不触联动。 |

---

## 8. 验收清单（草案，正式版随 plan 落地为独立文件）

### 8.1 机器执行
- host：`cd ios/Contracts && swift test` 全量 0 failures；净 = +PanLinkageTests，现有测试零回归。
- Catalyst：`xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'` → `TEST BUILD SUCCEEDED`。
- iOS app：`xcodebuild build … -scheme KlineTrainer …` → `BUILD SUCCEEDED`。

### 8.2 模拟器人工验收（iPhone + seed fixture，默认 upper=60m / lower=日线）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 拖上图（60m）向右回看历史 | 下图（日线）右缘同步滚到**同一时刻**（时间对齐，非同像素） | ☐ |
| 2 | 拖下图（日线）回看 | 上图（60m）同步跟随到同一时刻 | ☐ |
| 3 | 拖任一图后**松手**（带速度） | 两图惯性减速**逐帧同步**滚动至停，全程不脱节 | ☐ |
| 4 | 一直拖到最老边 | follower graceful clamp（到自身最旧），无突兀跳变/越界 | ☐ |
| 5 | 不拖时 | 两图各自 autoTracking（offset=0），右缘都在当前 tick | ☐ |
| 6 | 在一图画线（drawing）后拖另一图 | 画线图暂不跟（冻结），拖动图正常；退出画线/下次操作后复位 | ☐ |
| 7 | 买卖成交 / 两指切周期 | 两图一起 reset 到最新（既有 lockstep），仍右缘对齐 | ☐ |
| 8 | 缩放（pinch）一图 | 仅该图缩放（pinch 不联动，范围外） | ☐ |

### 8.3 回归
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 单图 pan 物理（rubber-band/惯性/reveal 禁前窥） | leader 行为一字未变（D12） | ☐ |
| 2 | 坐标轴/网格/markers/crosshair | RFC #3 轴 + markers 跨周期一切如常 | ☐ |

---

## 9. 流程与治理

- **评审通道**：Opus 4.8 xhigh 对抗性 review 代 codex（与 PR #122–126 一致），把守 spec / plan / 整体 branch-diff 三道闸门到收敛。
- **实现**：superpowers subagent-driven（fresh subagent per task + 两阶段 spec+quality review）。
- **不 bump CONTRACT_VERSION**（§1.3）。无 trust-boundary（`.github/workflows`）改动。
- **merge**：`--admin` 旁路缺失 codex-verify-pass（opus 通道无 codex ledger），真实 CI 三项须绿。
