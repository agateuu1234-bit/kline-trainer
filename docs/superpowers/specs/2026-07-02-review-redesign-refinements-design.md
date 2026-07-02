# 复盘重设计 · 真机整改增补 设计（Refinements）

> 本文是 `2026-07-02-review-redesign-design.md` 的**增补**，承接同一功能分支/PR（`worktree-review-redesign` / PR #139）。原 spec 的复盘重设计不变；本文只定义真机实测后暴露的 4 处整改。原 spec 与本文冲突时以本文为准（仅限本文覆盖的 4 处）。

## 0. 背景与范围

PR #139 的复盘重设计经模拟器实测，暴露 4 处问题。范围 = 且仅 = 下列 ④③②① 四项；不含 iPad/齿轮/训练设置/划线**删除** UI/文本标注（各自独立 RFC）。

| # | 现象 | 根因 | 类别 |
|---|---|---|---|
| ④ | 已保存复盘再进入时，画线一进复盘就全部显示，不按"画线的时刻"渐显 | 渐显用锚点 `candleIndex`（=手指横向位置），非画线创建时刻 | 行为+契约改动 |
| ③ | 划线只能画在上半面板，下半面板画不了 | 划线钮硬编码 `.upper` | 功能缺陷 |
| ② | 复盘底栏「快进到结尾」按钮两行 + 白底，与「下一根」浅蓝不一致 | ReviewControlBar 样式 | UI |
| ① | 自己训练完点复盘报「训练组数据为空」 | DEBUG 种子 pending 摆在复盘窗口起点之前 | DEBUG 数据 |

## 1. ④ 画线按"创建时刻"渐显（核心）

### 1.1 问题精确定义
当前渐显（`RenderStateBuilder.make`）：一条画线在 `drawing.anchors.allSatisfy { anchor.candleIndex <= currentCandleIndex(period, tick) }` 时显示。锚点 `candleIndex = mapper.xToIndex(point.x)` 记录的是**用户手指点击的横向位置**，与"画这根线时会话所处的时刻"无关。水平线用户常在任意 x 处点，导致：一进复盘（tick=起点）只要某锚点 candleIndex ≤ 起点即立即显示；且"快进到结尾后画的线"会在其锚点位置（可能靠左）提前显示，而非在结尾显示。

### 1.2 目标行为（三情形，训练层与复盘层统一）
- **逐根复盘到第 N tick 时画的线** → 再次复盘步进到 tick N 时才显现。
- **快进到结尾（tick=finalTick）后画的线** → 再次复盘步进到最后一根（finalTick）时才显现。
- **原训练过程中在某 tick 画的线** → 复盘步进到该 tick 时才显现（不是一进复盘就显）。
- 一进复盘（tick=复盘起点 metaStartTick）只显现 `revealTick ≤ metaStartTick` 的线。

### 1.3 模型：`DrawingObject.revealTick`
`DrawingObject` 新增字段 `public let revealTick: Int`：**提交这条画线时会话所处的全局 tick**（`engine.tick.globalTickIndex`）。语义 = "这条线自哪个全局 tick 起开始存在"。锚点 `anchors`（几何位置）保持不变，只是**不再用于渐显时机**，仅用于定位线的画法。

新签名（追加参数，置于末位）：
```swift
public struct DrawingObject: Codable, Equatable, Sendable {
    public let toolType: DrawingToolType
    public let anchors: [DrawingAnchor]
    public let isExtended: Bool
    public let panelPosition: Int
    public let revealTick: Int          // 新增
    public init(toolType: DrawingToolType, anchors: [DrawingAnchor],
                isExtended: Bool, panelPosition: Int, revealTick: Int) { ... }
}
```

### 1.4 盖戳（stamping）位置
`TrainingEngine.routeDrawingCommit(_:)` 是画线提交的单一真相（gesture → 引擎）。在此用引擎当前全局 tick 覆盖 `revealTick` 后再路由，保证任何经手势提交的画线都带正确时刻：
```swift
public func routeDrawingCommit(_ drawing: DrawingObject) {
    let stamped = DrawingObject(toolType: drawing.toolType, anchors: drawing.anchors,
                                isExtended: drawing.isExtended, panelPosition: drawing.panelPosition,
                                revealTick: tick.globalTickIndex)
    if flow.mode == .review { appendReviewDrawing(stamped) } else { appendDrawing(stamped) }
}
```
- 训练模式：`tick.globalTickIndex` = 当前训练位置 → 训练画线的创建时刻。
- 复盘模式：`tick.globalTickIndex` = 当前复盘步进位置 → 复盘画线的创建时刻。
- `appendDrawing` / `appendReviewDrawing` 本身不改（仍是纯 append）；直接调它们的**测试路径**须显式传 `revealTick`。`DrawingToolManager.commit(...)` 构造的 `DrawingObject` 用 `revealTick: 0` 占位（随后被 `routeDrawingCommit` 覆盖）。

### 1.5 渐显逻辑（`RenderStateBuilder.make`）
把锚点渐显判据替换为按创建时刻：
```swift
drawings: (engine.drawings + (engine.flow.mode == .review ? engine.reviewDrawings : [])).filter { drawing in
    drawing.panelPosition == (panel == .upper ? 0 : 1)
        && drawing.revealTick <= tick
}
```
- 面板过滤（`panelPosition`）保持不变。
- `revealTick <= tick`（全局 tick 直接比较，跨周期天然一致，无需 per-anchor per-period 映射）。
- **对 normal/replay 亦成立**：训练/replay 只能在当前 tick 向前画，已画线的 `revealTick ≤ 当前 tick` 恒真 → 全显（与当前效果一致）；复盘步进过去区间时才逐 tick 揭示。行为对三模式统一且正确。

### 1.6 持久化与向后兼容（无新 SQL 迁移）
画线以 JSON blob 存于 `training_records` 画线列 / `review_archive.saved_drawings|working_drawings` / `pending_training.drawings`——**SQL schema 不变**，故**不新增迁移**（`PRAGMA user_version` 保持 5）。
`DrawingObject` 采用自定义 `Codable`，对**缺失 `revealTick` 的旧 blob** 默认 0（向后兼容；本项目尚无生产用户数据，DEBUG 种子画线为空，故默认 0=从起点起可见 是安全且足够的 legacy 语义）：
```swift
// init(from:) 内：
revealTick = try container.decodeIfPresent(Int.self, forKey: .revealTick) ?? 0
// encode(to:)：始终写 revealTick
```
`CONTRACT_VERSION` `"1.9" → "1.10"`（逻辑契约演进标记；该常量仅在 `Models.swift` 定义、**不持久化、不与 DB user_version 门控**，故 bump 为纯标记，无副作用）。`Equatable` 含 `revealTick`。

### 1.7 边界
- 复盘入口终局等式校验 / `ReviewLedger` / 交易账目**完全不受影响**：`revealTick` 只影响画线**显示时机**，不进任何盈亏/持仓/存档净改动判定。`ReviewNetChange.changed` 比较 saved vs working 画线：因 `revealTick` 进入 `Equatable`，同一条线的 `revealTick` 在 saved 与 working 间保持一致（同次提交盖戳后不变），故不误判净改动。
- `revealTick` 可能 > finalTick 吗？不会：提交时 `tick.globalTickIndex ∈ 该模式 allowedTickRange ⊆ [_, finalTick]`。即便越界，`revealTick <= tick` 仍安全（只是永不显示，不崩溃）。

## 2. ③ 划线可画上下两个面板

`TrainingView.swift` 的划线钮当前硬编码 `.upper`（判活跃态、取消、激活工具三处）。改为使用**分段钮选中的 `activePanel`**（`@State activePanel`，默认 `.lower`），使划线作用于用户当前所选面板：
```swift
// 判活跃：if case .drawing = engine.panel(activePanel).interactionMode { return true }
// 取消：  engine.cancelDrawing(panel: activePanel)
// 激活：  engine.activateDrawingTool(.horizontal, panel: activePanel)
```
锚点 `period` 取所选面板 period（`DefaultDrawingInputController.tapToAnchor` 已按传入 panel 派生，无需改）；`panelPosition` 按所选面板（上=0/下=1）写入，渲染过滤据此分面板。`revealTick`（§1）全局，两面板一致。上下面板均可画、均按创建时刻渐显、互不串面板。

## 3. ② 「快进到结尾」按钮样式

`ReviewControlBar` 中「快进到结尾」按钮改为与「下一根」**同款样式**：单行不换行（不因宽度折成两行）、**浅蓝底**（与「下一根」同一背景/前景配色），两按钮视觉统一。仅样式改动，不改动作语义（仍 = 跳到 finalTick）。

## 4. ① DEBUG fixture 一致性（非生产逻辑）

**根因**：`DebugFixtureData.make` 的 `pending.globalTickIndex = m3Count/2 = 9600`，小于复盘窗口起点 `metaStartTick = beforeM3Count = 12000`；record 交易在 tick 1/2（同样在窗口外）。继续训练该 pending 后 finalTick 落在 12000 之前 → 复盘 `make(.review)` 守卫 `record.finalTick >= startTick(=metaStartTick)` 失败 → 抛 `.trainingSet(.emptyData)`「训练组数据为空」。**真实"开始训练"从 metaStartTick 起跑、finalTick 恒 ≥ metaStartTick，复盘正常**——本项仅修 DEBUG 种子数据一致性，不动生产逻辑。

**修正**（`DebugFixtureData.make`，`#if DEBUG`）：
- `pending.globalTickIndex` 从 `m3Count/2` 改为**窗口内**值：`beforeM3Count + (m3Count - beforeM3Count) / 2`（fullLoad 下 = 12000 + 3600 = 15600，∈ (metaStartTick, m3Count)）。
- 两条 record 的交易从 tick 1/2 挪到**窗口内**两个 tick（如 `beforeM3Count + Δ1`、`beforeM3Count + Δ2`，`metaStartTick < t_buy < t_sell < finalTick`）；成交价用**该 tick 的候选收盘价**（读同一确定性蜡烛序列，使买卖标记落在 K 线上、复盘时持仓段账户随真实收盘价逐 tick 滚动）；`record.profit/returnRate` 仍由 ReviewLedger 同款 fold 表达式计算（保证入口终局等式精确成立）。record `finalTick` 保持 `m3Count - 1`（≥ metaStartTick，复盘可开）。

效果：继续训练完可正常复盘（不再报空）；record 1/2 复盘时顶栏逐 tick 盈亏真实滚动（交易在窗口内）。

## 5. 契约/版本
- `DrawingObject` 加 `revealTick: Int` + 自定义 `Codable`（`decodeIfPresent ?? 0`）。
- `CONTRACT_VERSION 1.9 → 1.10`（纯标记，无 DB 门控、无新迁移）。
- `PRAGMA user_version` 保持 5，**不新增迁移**。

## 6. 测试
- **④**：`revealTick` 渐显单测——(a) 逐根 tick N 画线 → `revealTick=N`、tick<N 不显 / tick≥N 显；(b) 结尾画线 `revealTick=finalTick` → 仅最后一根显；(c) 原训练线按训练创建 tick 渐显；(d) 旧 blob（无 revealTick）解码默认 0 且渲染从起点可见；(e) 跨周期（上/下面板不同 period）按全局 tick 渐显；(f) `routeDrawingCommit` 盖戳 = 当前 `tick.globalTickIndex`（review 与 normal 各一）。
- **③**：所选面板划线的锚 period / panelPosition 单测（上、下各一，互不串面板）。
- **①**：`DebugFixtureData` 一致性单测——`pending.globalTickIndex ∈ (metaStartTick, m3Count)`、两 record 交易 tick ∈ (metaStartTick, finalTick)、ReviewLedger fold(ops) == record.profit/returnRate。
- **②**：走人工验收（样式）。
- 全量 `swift test` 绿 + Mac Catalyst `build-for-testing` 绿。

## 7. 验收（人工，action/expected/pass_fail）
1. 划线时机 — 逐根复盘到某根画一条线 → 结束保存 → 再复盘从头步进。 预期：该线在"当初画它的那根 K 线"出现时才显现，之前不显。 pass/fail：出现时机 = 画它的那根 = 通过。
2. 结尾画线时机 — 复盘中先「快进到结尾」再画一条线 → 保存 → 再复盘从头步进。 预期：该线仅在步进到最后一根时才显现。 pass/fail：仅结尾显 = 通过。
3. 训练画线时机 — 训练中在某根画一条线并完成该局 → 复盘从头步进。 预期：该线在训练时画它的那根出现时才显现，非一进复盘就显。 pass/fail：符合 = 通过。
4. 双面板划线 — 分段钮选「下图」→ 点划线钮画横线。 预期：线画在下半面板；选「上图」可画在上半面板；两者互不串。 pass/fail：上下都能画且不串 = 通过。
5. 快进按钮样式 — 进复盘看底栏。 预期：「快进到结尾」单行、浅蓝底，与「下一根」一致。 pass/fail：单行+同色 = 通过。
6. 继续训练可复盘 — 点「继续训练」打完一局 → 对该记录点复盘。 预期：正常进入复盘，不报「训练组数据为空」；顶栏盈亏随步进滚动。 pass/fail：能进且滚动 = 通过。

## 8. 非目标
划线删除 UI、文本标注、iPad/齿轮/训练设置——不在本增补。`removeReviewDrawing` 仍为未接线保留（独立 RFC）。
