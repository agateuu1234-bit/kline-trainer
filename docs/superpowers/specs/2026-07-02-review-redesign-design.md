# 复盘(Review) 完整重设计 + replay 主界面标记 — 设计规格

- **日期**：2026-07-02
- **状态**：Draft（待 codex 对抗评审 + 用户确认）
- **交付形态**：**一个 PR / 一个 RFC**（复盘重设计 + replay 主界面标记合并交付）
- **基线**：main `d96b1f4`（#136 replay 续局 + 复盘可步进重演 / #137 / #138 已落地）
- **关联**：memory `project_review_redesign_rfc_2026_07_01`（需求源）、`project_trade_ui_backlog_2026_06_21`、`project_post_overhaul_backlog_2026_06_30`
- **UI mockup（已浏览器确认）**：`docs/superpowers/mockups/2026-07-02-review-redesign.html`

---

## 0. 范围界定

### 本 RFC 做（合并一个 PR）
1. **复盘(Review) 完整重设计**：训练一致的 UI（逐 tick 重算运行盈亏顶栏 / 双 K 线 / 红框 / 划线钮）、底栏由 3 键买卖改为 2 键（下一根 + 快进到结尾，保留分段器 + 下单价）、复盘中可画线、复盘可持久可续（返回复盘）、结束弹保存提示、每记录单槽复盘存档、再复盘到结尾揭示存档画线。
2. **主界面标记**：`再次训练中`（replay 全局单槽）/ `复盘中` / `已复盘` 三态行标记 + action sheet 文案切换（复盘↔返回复盘）。

### 本 RFC 不做（各自独立 RFC，见 backlog）
- iPad/iPhone 适配、主页齿轮 UI 调整、训练界面设置按钮（周期/指标可配）。
- **划线工具扩充**（射线/趋势/黄金分割/波浪等多种几何工具）。
- **文本标注工具**（属划线工具扩充的一部分）——本 RFC 复盘存档**只存画线，不含文本标注**。故「已复盘」标记只反映新画线。

---

## 1. 背景与现状锚点（本设计的改造起点）

以下为 #136 后的现状触点（文件:行），本设计在其上改造：

| 关注点 | 位置 | 现状 |
|---|---|---|
| `ReviewFlow` | `TrainingFlowController.swift:62-86` | `init(record:,startTick:)`；`canBuySell=false / canAdvance=true / canJumpToEnd=true / shouldSaveRecord=false / shouldPersistProgress=false / shouldShowSettlement=false` |
| 复盘步进/快进 | `TrainingEngine.swift:359-368 (jumpToEnd)`, `375-389 (stepReviewForward)` | `stepReviewForward` 自动取两面板较细周期步进；`jumpToEnd` 置 `tick=maxTick` |
| 复盘底栏 | `ReviewControlBar.swift:19-54` | 现为 `[下一根]`（+`[快进到结尾]`）两 `.bordered` 按钮 |
| 训练底栏 | `TradeActionBar.swift:50-94` | `[上图\|下图]分段器(width104) + 下单价(size10.5) + 买入(red)/卖出(green)/持有` |
| 顶栏盈亏 R4 门控 | `TrainingTopBarContent.swift:107-119` | `reviewAwareCapital/reviewAwareReturnRate`：review 且未到结尾 → 显起始本金/0%（隐藏最终成绩） |
| 画线按 tick 渐显 | `RenderStateBuilder.swift:61-69` | 按 `anchor.candleIndex ≤ currentCandleIndex(tick)` 过滤（review/normal/replay 共用） |
| 划线钮 / 红框门控 | `TrainingView.swift:56,211-215,332-336` | `showsTradeButtons = canBuySell()`；划线 FAB + active-panel 红框仅在此为真时显示（复盘=false→现复盘无划线钮/无红框） |
| 复盘入口路由 | `AppRouter.swift:95-101` → `TrainingSessionCoordinator.swift:264-293` | `review(recordId:)` 载 bundle（ops+drawings）+ 全 candles，`TrainingEngine.make(.review(record:,startTick:))` |
| replay 单槽仓 | `PendingReplayRepository.swift:5-23` + `PendingReplayRepositoryImpl.swift` | 协议 save/load/`loadReplaySlotInfo`(轻量)/clear/`clearReplay(ifRecordId:)` |
| replay 单槽表 | `AppDBMigrations.swift:164-184` | migration `0006` 建 `pending_replay`（`CHECK(id=1)` 单行 + `INSERT OR REPLACE`） |
| replay resume-first 路由 | `AppRouter.swift:103-116` | `resumePendingReplay` 命中→续，nil→从头 |
| replay 文案切换 | `HistoryActionSheet.swift:44-46` | `replayButtonTitle(hasResumableReplay:) → 返回训练/再次训练` |
| 首页统计栏 | `HomeView.swift:74-95` | 三行 `.subheadline`：总局次/胜率/总资金 + 齿轮 `.title2` |
| 首页历史行 | `HomeView.swift:137-154` + `HomeContent.swift:18-26,136-145` | r1 `日期(caption)\|股票(subheadline.bold)`；r2 `起始月(caption)\|总资金(caption)`；r3 `本局盈亏(subheadline，红涨绿跌)` |
| 组合根 | `AppContainer.swift` | `DefaultAppDB` 多角色（含 `PendingReplayRepository`）注入 `TrainingSessionCoordinator` |
| `TradeOperation` | `Models.swift:166-195` | 带 `globalTick / direction / price / shares / positionTier / commission / stampDuty / totalCost / createdAt`（**逐 tick 重算的确定性来源**） |
| `DrawingObject` | `Models.swift:209-221` | `toolType / anchors[DrawingAnchor(period,candleIndex,price)] / isExtended / panelPosition` |
| 契约版本 | `Models.swift` | `CONTRACT_VERSION = "1.8"` |

---

## 2. 术语与状态

**两个正交维度**，一条历史记录可同时具备（首页可并列两标记）：

- **replay 维度**（#136 既定，全局单槽）：`无` / `再次训练中`（该记录占 `pending_replay` 单槽）。
- **review 维度**（本 RFC 新增，per-record）：`无` / `复盘中`（in_progress，未保存可续）/ `已复盘`（saved，有存档）。
  - **已提交基线（committed baseline，codex R5-high）**：`复盘中` 的净改动判定**永远相对"已提交基线"** = 该记录的 `saved_drawings`（`已复盘`）或空集 ∅（无 saved / 原始记录）——**不是** resume 时载入的 working 副本。resume 只是把上次 working 载入供继续编辑，基线仍是 committed。
  - **`复盘中` 的严格定义（codex R3-medium / R5-high）**：当且仅当**当前工作画线集 ≠ 已提交基线**（有净改动）且未保存。**纯浏览（进入→步进/看→返回，无净画线改动）不产生 `复盘中`**。**resume 后把编辑删回到与 committed 相等再返回，也回退**（因为对比的是 committed 而非 resumed working）。任何终态动作（返回/结束）都拿"当前工作集 vs committed 基线"比对：相等 → 清 working → `已复盘`(有 saved)/`无`；不等 → `复盘中`。步进位置仅作为已存在 working 行的续接位置，本身不单独产生 `复盘中`。
  - **`复盘中` 与 `已复盘` 互斥**：一条记录任一时刻只处于其一。已复盘记录被重新进入**并使工作集 ≠ saved**后返回 → 变回 `复盘中`；工作集回到 = saved 后返回则仍 `已复盘`。

**文案定稿**（mockup 确认）：`再次训练中`（非"正在再次训练中"）/ `复盘中` / `已复盘`。

---

## 3. 数据模型与 schema

### 3.1 新表 `review_archive`（每记录一行）

migration `0007_v1.9_review_archive`（§10 钉死版本契约；`AppDBMigrations.makeMigrator()` 尾部注册；**非** baseline DDL）：

```sql
CREATE TABLE IF NOT EXISTS review_archive (
    record_id          INTEGER PRIMARY KEY REFERENCES training_records(id) ON DELETE CASCADE,
    saved_drawings     TEXT,               -- 已提交存档画线 JSON [DrawingObject]；NULL=从未保存
    working_step_tick  INTEGER,            -- 复盘中续接位置(global tick)；NULL=当前不在复盘中
    working_drawings   TEXT,               -- 复盘中工作副本 JSON [DrawingObject]；NULL=当前不在复盘中
    updated_at         INTEGER NOT NULL,
    -- 不变量硬约束（codex R1-high）：working 两列同生同灭，DB 层拒绝半 working 行。
    CHECK ((working_step_tick IS NULL) = (working_drawings IS NULL))
);
```

- `working_step_tick` 与 `working_drawings` **同生同灭**（要么都 NULL=非进行中，要么都非 NULL=进行中）——由上述 `CHECK` 在 DB 层强制，任何只写其一的写入将被拒绝（防半 working 损坏行）。
- `ON DELETE CASCADE`：训练记录删除时复盘存档随删（复用现有记录删除路径，避免孤儿）。

### 3.2 状态派生（互斥，供首页 + action sheet）

```
row 不存在                                  → review 维度 = 无
working_step_tick != NULL                  → 复盘中   (优先)
working_step_tick == NULL && saved != NULL → 已复盘
其它(全 NULL)                               → 无（异常行，按无处理并清理）
```

### 3.3 CONTRACT_VERSION

`Models.swift`：`1.8 → 1.9`（新增持久化表，遵循 #136 单槽 bump 先例）。同步 `ModelsTests` 断言。

---

## 4. 复盘生命周期状态机

`ReviewFlow` 能力扩展：`shouldPersistProgress` 对 review 改为 `true`（复盘进度落 `review_archive`，而非 `pending`/`pending_replay`）；`canBuySell` 仍 `false`。

**已提交基线**（§2）：`committed = saved_drawings`（`已复盘`）或 ∅（无 saved）。**所有净改动判定一律"当前工作集 vs committed"**，与是否从 resume 载入无关（codex R5-high）。

**进入复盘**（`无`/`已复盘`/`复盘中`续）：mint 新 `sessionToken`（§6.3）；committed 基线取自 `saved_drawings`/∅；resume 时把上次 `working_drawings` 载入供编辑（**基线仍是 committed，不是载入的 working**）；**不立即落 working**（避免纯浏览产生假 `复盘中`，codex R3-medium）。

**会话中 autosave**（§6.2/§6.3，单写者串行 + revision 守卫）：一旦工作画线集**≠ committed**（有净改动），落 working（原子 `tick+drawings`）；此后步进只更新已存在 working 行的 `tick`（节流）。工作集回到 = committed 时视为无净改动。

**终态动作**（先 drain/取消所有待写节流，再执行终态写，保证 last-wins，codex R3-high）——判定一律"当前工作集 vs committed"：

| 动作 | 工作集 vs committed | 持久化结果（原子 `saveWorkingReview`/清空） | 首页标记 |
|---|---|---|---|
| 点**返回** | ≠（有净改动） | final 写 working（`tick+drawings`；saved 不动） | 复盘中 |
| 点**返回** | =（无净改动，含 resume 后删回 saved） | 清 working（两列同置 NULL）；`saved` 保留（无 saved 则 DELETE 行） | 已复盘 / 无 |
| 点**结束** → `保存` | ≠（才弹此选项） | `saved_drawings=working_drawings`；清 `working_*` | 已复盘 |
| 点**结束** → `不保存` | ≠（才弹此选项） | 清 `working_*`；`saved` 保留（无 saved 则 DELETE 行） | 已复盘 / 无 |
| 点**结束** → `取消` | — | 无操作（继续复盘） | （会话内，不变） |
| 点**结束**（工作集 = committed） | = | 不弹窗，直接清 working（有 saved 留、无 saved 删行）并退出 | 已复盘 / 无 |

**保存提示触发条件**：点「结束」且**工作集 ≠ committed**（有净改动）时弹 `保存/不保存/取消`；工作集 = committed 直接结束并清理（不弹）。

**关键不变量**：复盘**从不修改原训练记录的 `drawings`**（`training_records`/`drawings` 表只读）；复盘新画线只进 `review_archive.working_drawings`。

---

## 5. 引擎：逐 tick 重算运行盈亏（ReviewLedger）

### 5.1 目标
复盘逐根步进时，顶栏账户/盈亏显示**截至当前步进 tick 的运行值**（非最终成绩，无剧透；到结尾自然等于最终成绩）。取代 #136 R4 的「隐藏到结尾」门控。

### 5.2 纯组件 `ReviewLedger`（平台无关，host 全测）
```
struct ReviewLedgerState { cash; shares; averageCost; totalCapital; returnRate; positionTier; drawdown? }
func state(atTick t, ops:[TradeOperation], initialCapital, markPriceAtTick:(Int)->Double) -> ReviewLedgerState
```
- 折叠 `ops.filter { $0.globalTick <= t }`（按 `globalTick` 升序，`createdAt` 兜底稳定序）逐笔应用 **E2 `PositionManager` + E3 `TradeCalculator` 同款语义**（现金流用 op 自带的 `totalCost/commission/stampDuty`，持仓/成本用 direction+shares）。
- `totalCapital = cash + shares × markPriceAtTick(t)`；`returnRate = (totalCapital − initialCapital)/initialCapital`；`positionTier` = 现派生公式（`round(持仓市值/总资金×5) clamp 0...5`）。

### 5.2.1 规范 mark price 来源（codex R5-medium）
`markPriceAtTick` **非可选、对每个 global tick 都有定义**：
- **来源 = 规范全局序列在 global tick t 的收盘价**（`engine.allCandles` 中以 global tick 1:1 索引的基准周期序列，即引擎 `currentPrice` 在当前 tick 取的同一价基——finalize 计算终局总资金用的正是此价基）。**与跨周期步进/所选面板无关**（步进只改 global tick，mark price 恒按 global tick 取基准序列收盘价）。
- **越界兜底**：`t` 落在 `[0, maxTick]` 内恒有值；仅作守卫的越界（`t<0` 或 `>maxTick`）clamp 到最近端收盘价（不返回 nil、不崩）。
- **精度/round**：ReviewLedger 全程用与 finalize 相同的 `Double` 算术（`PositionManager`/`TradeCalculator`），**不额外 round**；显示层格式化独立（§5.3 顶栏用 `TrainingTopBarContent` 同款 formatter）。故 `state(atTick maxTick)` 的 `totalCapital` 与 finalize 存值**逐位一致**。

- **一致性保证**：`state(atTick maxTick)` 逐值等于该记录 finalize 存的 `totalCapital/profit/returnRate`（因为这些 ops 正是产生它的输入 + 同价基同算术）——host 测断言 + mutation。
- **测试**：缺价/越界 tick 的 clamp 行为；`maxTick` 精确等于持久化终局总额（多条 fixture）；中间 tick 运行值合理性；mutation（改 op 应用顺序/价基 → 断言失败）。

### 5.3 顶栏接线
- 复盘顶栏 5 格（总资金/成本/股/股数/仓位/本局盈亏）读 `ReviewLedger.state(atTick: 当前tick)`。
- **移除 review 分支的 `reviewAwareCapital/reviewAwareReturnRate` 隐藏门控**（`TrainingTopBarContent.swift:107-119`）：改为始终显示 ReviewLedger 运行值（运行值本身即非剧透）。normal/replay 路径不变。

### 5.4 步进语义变更（配合 UI）
`stepReviewForward()` → `stepReviewForward(panel: PanelId)`：步进**指定（红框所选）面板**的周期一根（现"自动取较细"改为"按 activePanel"）。`jumpToEnd()` 不变（置 `maxTick`）。ReviewLedger 随新 tick 重算。
- **边界**：所选面板已到末尾（该周期无更多 candle）时，「下一根」回退为步进另一面板一根（避免死键）；两面板都到末尾 → no-op（到结尾，`快进到结尾`/自动结束逻辑接管）。此边界沿用现 `stepReviewForward` 的"一方耗尽用另一方 / 都耗尽 no-op"语义，仅把默认起点从"较细"改为"activePanel"。

---

## 6. 复盘中画线（解耦 + 归属 + 揭示）

### 6.1 解耦门控
新增谓词 `showsDrawingTools`（Normal/Replay/**Review** 均真）与 `showsActivePanelFrame`（同）；把划线 FAB（`TrainingView.swift:211-215`）与红框（`:332-336`）从 `showsTradeButtons` 改挂到新谓词。买卖条仍仅 `showsTradeButtons`。

### 6.2 画线归属 + 原子 autosave（codex R1-high）
- 复盘模式下新画线**不进** `engine.drawings`（原训练记录集，只读），改进 review 工作副本（`review_archive.working_drawings`）。
- **唯一持久化入口 = 原子 `saveWorkingReview(recordId:, tick:, drawings:, sessionToken:, revision:)`**：单次 UPSERT **同时**写 `working_step_tick=当前tick` + `working_drawings=当前工作集`（+ `updated_at`），**从不只写其一**（配合 §3.1 `CHECK`）。
- **触发点**（全部走上述原子入口，写入即带当前 tick，杜绝"有画线无 tick"）：
  1. **工作画线集 ≠ committed 基线**（§2/§4，增/删/改后与 committed 不等）——触发用工作集**内容变化**（值相等比较，**非** `count`；同数量的编辑也须落盘，codex R1-high）。**工作集 = committed 时不触发/清 working**（纯浏览 + resume 后删回 saved 均不产生 working，codex R3-medium/R5-high）。
  2. **步进 tick 变化**（仅当已存在 working 行时）——按节流更新续接 tick。
  3. **点返回/结束**——终态写（§6.3 drain 后执行）。
- 目标仓 = `review_archive`（**不写** record/pending/pending_replay）。失败 → §9 fail-closed（返回/结束路径弹重试/放弃 alert，不丢新画线）。

### 6.3 持久化顺序 / 单写者（codex R3-high / R4-high）
防"陈旧节流写乱序覆盖终态写"（延迟步进 autosave 落在返回终态写之后，把 `working_*` 退回旧值）。**顺序守卫在进程内单写者，不在 DB 列**——对齐 #136 replay autosave 已 codex 批准的 `terminating` fence + `autosaveTask` 取消范式；跨重启无在途陈旧写者，故 `review_archive` **不需**加 token/revision 列：
- **单写者串行**：复盘 working 持久化全部经 coordinator actor 隔离的**单一串行写路径**（@MainActor/actor 串行语义），无并发 UPSERT 交错。
- **会话 fence + 内存 revision（均进程内，不落库）**：进入复盘 mint 内存 `sessionToken` + 单调 `revision`。节流 autosave 携带发起时的 (token, revision)；单写者写前比对**当前内存**值，`token 失配（会话已终结/换新）或 revision 陈旧` → **丢弃**（挡上一会话/乱序陈旧写）。
- **终态 drain + fence**：`返回`/`结束(保存/不保存)` 先**取消待写节流 Task + 置 fence（invalidate 当前 token）**，再执行终态写（final working / saved / 清空），保证终态**最后落盘、last-wins**；此后迟到的旧 token 写被 fence 丢弃。
- **DB 侧只保证单写原子**：`saveWorkingReview` 单次 UPSERT 仍同时写两 working 列（§3.1 CHECK）；顺序/陈旧判定由上述内存单写者负责。
- **测试**：注入"延迟 autosave"测试替身 → 断言终态（返回/结束）胜过迟到节流写；旧 token/陈旧 revision 写被内存守卫丢弃。

### 6.3 揭示语义（统一）
复盘渲染叠加两层画线，均按 `anchor.candleIndex ≤ currentCandleIndex(tick)` 渐显（沿用 `RenderStateBuilder:61-69`）：
- **原训练画线**（记录自带，只读）；
- **复盘画线**（working 或 saved）。
到最后一根 / 一键到底时，所有 anchor≤maxTick → **自然全显**（满足"到结尾把保存的复盘内容全部显示"）。进行中新画线因 anchor 在当前 tick，画即可见。

---

## 7. UI 改动清单

### 7.1 复盘底栏（训练底栏原样，仅 3 键→2 键）
新增 `ReviewControlBar` 重设计（或复用 TradeActionBar 结构）：`[上图\|下图]分段器(选 activePanel) + 下单价(保留原文案) + 下一根 + 快进到结尾`。
- `下一根` → `engine.stepReviewForward(panel: activePanel)`（步进红框所选面板周期）。
- `快进到结尾` → `engine.jumpToEnd()`（`canJumpToEnd` 为真时显示第二键，沿用现内容模型语义）。
- 配色：下一根淡蓝强调、快进到结尾白描边次要（`.bordered`）。

### 7.2 复盘顶栏
- 显示 `返回`（左）/ 股票名（中）/ **`结束`（右，红色）**——复盘也显示结束键（触发保存弹窗；现状 review 为 `Color.clear` 占位，改为显示结束）。
- 5 格指标读 ReviewLedger 运行值（§5.3）。

### 7.3 红框 + 划线钮
复盘显示 active-panel 红框（所选面板=下一根步进目标）+ 划线 FAB（§6.1 解耦）。

### 7.4 结束保存弹窗
`confirmationDialog`/`alert`：标题「结束复盘」+「是否保存本次复盘记录？」+ `保存` / `不保存` / `取消`。仅本次有改动时弹（§4）。

### 7.5 首页行标记
`HomeContent` / `HomeHistoryRow` 扩展每行两个正交标记语义（Content 不含颜色，view 映射）：
- `replayMarker: Bool`（该行 id == replay 单槽 recordId）。
- `reviewMarker: enum { none, inProgress, saved }`。
渲染：chip 右对齐贴总资金正下方（r3 右侧，与本局盈亏同行/必要时换行）；单标记一行、两标记（replay+review）并排/换行，行高自然撑开不固定。配色：再次训练中(蓝)/复盘中(橙·脉动)/已复盘(青)。
**数据获取（避免 N 查）**：`loadHome()` 额外取 (a) replay 单槽 recordId（`loadReplaySlotInfo` 一次）、(b) review 标记字典 `[Int64: ReviewMarker]`（`review_archive` 一次批量），注入 `HomeContent`。

### 7.6 action sheet
- 复盘按钮：新 `reviewButtonTitle(inProgress: Bool) -> "返回复盘" : "复盘"`（镜像 `replayButtonTitle`）。已复盘（非进行中）仍显示纯「复盘」，**无任何备注标签**。
- 训练按钮：`replayButtonTitle` 不变。
- `AppRootView` 传入 `hasReviewInProgress(id:)`。顶部无小字说明。

---

## 8. 路由 / coordinator

新增/改动方法（`TrainingSessionCoordinator` + `AppRouter`，镜像 replay 模式）：

- `saveWorkingReview(recordId:, tick:, drawings:) async throws`：**原子 UPSERT**（§6.2），同时写 `working_step_tick + working_drawings`（saved 不动）；只保证单写原子。**顺序/陈旧守卫由 §6.3 进程内单写者负责**（token/revision 为 coordinator actor 内部态，不落库、不入本方法签名）。画线净改动/步进/终态的唯一持久化入口。
- `resumePendingReview(recordId:) async throws -> TrainingEngine?`：resume-first。命中 in_progress → 从 `working_step_tick` 起，加载 `working_drawings` 作复盘工作副本；**committed 基线仍取 `saved_drawings`/∅，不是载入的 working**（codex R5-high）；未命中 → nil。
- `review(recordId:) async throws -> TrainingEngine`（改造现 `:264-293`）：从头（startTick）；若该记录**已复盘**（有 `saved_drawings`），加载 saved 作工作副本供逐 tick 揭示 + 可继续修改（committed 基线=saved）；**进入不立即落 working**（§4/§6.2）；mint 新 sessionToken。
- `AppRouter.review(id:)`：resume-first（先 `resumePendingReview` 命中续，否则 `review` 从头），镜像 `replay(id:)`。
- 返回（`lifecycle.back()` 复盘分支）：drain 待写 → 有净改动则 final `saveWorkingReview`；无净改动则 `discardReviewWorking`。
- 结束保存/不保存：drain 待写 → `saveReview`（`saved=working`，清 working）/ `discardReviewWorking`（清 working，留 saved；无 saved 删行）——均原子清空两 working 列。
- `hasReviewInProgress(recordId:) -> Bool` + `loadReviewMarkers() -> [Int64: ReviewMarker]`（轻量，供首页/action sheet；不解码大 payload，镜像 `loadReplaySlotInfo`）。

---

## 9. 错误处理 / fail-closed 纪律（镜像 replay）

- `review_archive` 读写异常映射：JSON 解码失败 / 非法 period → `.dbCorrupted`。
- resume 复盘（working 损坏）：`.dbCorrupted` → durable clear 该行 **working**（回到"无进行中"）+ 返回 nil（从头）；非 `.dbCorrupted` 瞬时错误 → 上抛可重试（不静默丢）。清理失败上抛（保留行可重试）。
- **saved 存档损坏恢复（codex R4-medium）**：首页/action sheet 的「已复盘」判定用轻量查询（不解码 payload）→ 若 `saved_drawings` 实际损坏，进入复盘解码 saved 时 `.dbCorrupted`。处理：durable clear **仅** `saved_drawings`（置 NULL、移除「已复盘」标记；working 列不受影响）→ 以原训练记录为基线**从头进入复盘**（空 review 基线，可重新画线保存）→ toast 告知「复盘存档损坏已清除，可重新复盘保存」。杜绝"打开即崩且无法清坏档"死循环。清理失败上抛可重试。
- 复盘**返回/结束保存**失败 → 弹「保存进度失败」重试/放弃 alert（镜像 `TrainingView` 现 `backFailed`/`finalizeFailed`），**不丢用户新画线**。
- 首页标记查询失败 → 保守降级（不显示该标记，不阻塞列表；镜像 `hasResumableReplay` 的 try? 兜底）。

---

## 10. 迁移 / 契约（版本契约钉死，codex R2-high）

**现状机制（核实自 `AppDBMigrations.swift:93-187`）**：GRDB `DatabaseMigrator` 命名迁移，按注册序执行、由 GRDB `grdb_migrations` 表按 identifier 去重追踪；部分迁移**额外**手动 `PRAGMA user_version`。已注册链：`0001_v1.4_baseline` → `0003_v1.4_purge_leased` → `0004_v1.6_session_key`(user_version=2) → `0005_v1.7_capital_authoritative`(=3) → `0006_v1.8_pending_replay`(=4)。**基线 `d96b1f4` 的 DB 状态 = 已过 0006、`PRAGMA user_version = 4`、有 `pending_replay`**。

**本 RFC 新增（尾部追加，单调递增，不改既有迁移/不动冻结基线 `v1_4_baselineDDL`/`app_schema_v1.sql`）**：
- 注册 `0007_v1.9_review_archive`：建 `review_archive`（§3.1，含 `CHECK`），尾 `PRAGMA user_version = 5`（沿 0006→4 的 +1 递增）。
- 幂等：`CREATE TABLE IF NOT EXISTS`；GRDB 按 identifier 只跑一次。
- **升级路径**：既有 DB（已 0006、user_version=4）只跑 0007 → 建表、user_version=5；fresh install 跑 `0001→…→0007` 全链建全表。
- **迁移链测试（新增，codex R2-high）**：(a) 从"基线形态 DB（有 pending_replay、user_version=4、无 review_archive）"跑 migrator → 断言 `review_archive` 存在 + `user_version==5` + CHECK 生效（插半 working 行被拒）；(b) fresh install 跑全链 → 断言 `review_archive` 存在；(c) 重复跑 migrator 幂等（不报错、不重建）。

**其它契约**：
- `CONTRACT_VERSION 1.8 → 1.9` + `ModelsTests` 同步断言。
- `DefaultAppDB` 增 `ReviewArchiveRepository` 角色；`AppContainer` 注入 `TrainingSessionCoordinator`。

---

## 11. 组件边界（可独立理解/测试的单元）

| 单元 | 职责 | 依赖 | 测试面 |
|---|---|---|---|
| migration `0007_v1.9_review_archive` | 建 review_archive + user_version 4→5 | GRDB DatabaseMigrator | **迁移链升级测试**（§10）：基线形态 DB→建表+v5+CHECK生效 / fresh 全链 / 幂等重跑 |
| `ReviewArchiveRepository`(协议+impl) | review_archive CRUD + 原子 saveWorkingReview + 状态派生 + fail-closed | AppDB | 内存 fake + 状态机转换（含回滚/re-edit）+ **原子写恒双列非空/双列同置NULL** + **CHECK 拒半 working 行** + **内容变化触发（同 count 编辑也落盘）** + **corrupt saved_drawings 仅清 saved + 移除标记 + 可重进（§9）** |
| 复盘持久化顺序（单写者 + fence，§6.3） | 内存 token/revision 串行守卫 + 终态 last-wins | coordinator actor | **延迟 autosave 测试替身**：终态（返回/结束）胜过迟到节流写；旧 token/陈旧 revision 内存写被丢弃 |
| 净改动判定 + 返回回退（§2/§4，committed 基线） | vs committed 比较 + 无改动清 working | ReviewArchiveRepository | **已复盘→复盘→返回(无改动)=仍已复盘**；**无存档→复盘→返回(无改动)=仍无标记**；**resume 编辑后删回=saved 再返回=仍已复盘**（codex R5-high）；工作集≠committed→复盘中 |
| `ReviewLedger`(纯值) | 逐 tick 折叠运行盈亏 + 规范 mark price | PositionManager/TradeCalculator | host 折叠：**maxTick 逐位匹配持久化终局** + 中间值 + **越界 clamp 非 nil** + mutation |
| `ReviewControlBarContent`(纯值) | 复盘底栏按钮/文案模型 | — | host 内容断言 |
| `HomeContent` 标记派生(纯值) | 行 replay/review 标记 | — | 各态 + 正交 + 互斥 |
| `reviewButtonTitle`(纯函数) | 复盘/返回复盘 文案 | — | host |
| 保存弹窗呈现谓词(纯值) | 有改动才弹 + 三选项路由 | — | host |
| SwiftUI 薄壳（顶栏/底栏/FAB/首页/弹窗接线） | 呈现 + 意图闭包 | 上述纯值 | Catalyst 编译闸门 |

---

## 12. 验收清单（草案；非编码者可自测；action/expected/pass_fail；中文）

> 最终验收清单在 plan 阶段定稿并随 PR body 交付。以下为草案。

1. **复盘逐根运行盈亏**
   - action：任选一条有买卖的历史记录 → 点「复盘」→ 连点「下一根」若干次，越过一次买入所在的 K 线。
   - expected：越过买入那根后，顶栏「股数/仓位」由 0 变为实际持仓，「总资金/本局盈亏」随后续每根 K 线变化而变化。
   - pass_fail：买入根之前顶栏为 0 仓、买入根之后顶栏显示非零持仓且盈亏随价格逐根变动 = 通过；否则失败。

2. **复盘到结尾等于最终成绩**
   - action：同一记录点「快进到结尾」。
   - expected：顶栏「本局盈亏」与首页该记录行显示的盈亏金额/百分比一致。
   - pass_fail：两处数值完全一致 = 通过；不一致 = 失败。

3. **复盘中画线 + 返回续接**
   - action：复盘中用划线钮画一条水平线 → 点「返回」回首页 → 再点该记录。
   - expected：该记录行显示「复盘中」；action sheet 复盘按钮显示「返回复盘」；点入回到上次步进位置且刚画的线在。
   - pass_fail：三者都满足 = 通过；任一不满足 = 失败。

4. **结束保存 → 已复盘**
   - action：复盘中点「结束」→ 选「保存」。
   - expected：回首页该记录行由「复盘中」变「已复盘」。
   - pass_fail：标记变为「已复盘」= 通过；仍是「复盘中」或无标记 = 失败。

5. **再复盘揭示存档画线**
   - action：对「已复盘」记录点「复盘」→ 点「快进到结尾」。
   - expected：之前保存的画线全部显示在图上。
   - pass_fail：保存过的线全部出现 = 通过；缺失 = 失败。

6. **结束不保存保留旧存档**
   - action：对「已复盘」记录点「复盘」→ 画一条新线 → 点「结束」→ 选「不保存」。
   - expected：回首页仍是「已复盘」；再进入到结尾只显示旧存档的线，不含刚画的新线。
   - pass_fail：旧存档完整保留且新线未被保存 = 通过；否则失败。

7. **再次训练中 + 复盘中 双标记正交**
   - action：对记录 A 点「再次训练」→ 返回；再对 A 点「复盘」→ 画线 → 返回。
   - expected：A 行同时显示「再次训练中」和「复盘中」两个标记。
   - pass_fail：两标记并存 = 通过；只显示其一 = 失败。

8. **replay 全局单槽不被复盘影响**
   - action：A「再次训练」返回（A 显示再次训练中）→ 对 B「再次训练」返回。
   - expected：A 的「再次训练中」消失、B 显示「再次训练中」（单槽）；A/B 的复盘标记（若有）各自独立不受影响。
   - pass_fail：replay 标记单槽转移且复盘标记不受牵连 = 通过；否则失败。

9. **纯浏览不误标复盘中**（codex R3-medium）
   - action：对「已复盘」记录点「复盘」→ 只连点「下一根」看几根、不画任何线 → 点「返回」；另对一条「无标记」记录同样只看不画后返回。
   - expected：已复盘记录返回后仍是「已复盘」（action sheet 仍为「复盘」非「返回复盘」）；无标记记录返回后仍无标记。
   - pass_fail：两条都不出现「复盘中」= 通过；任一误标「复盘中」= 失败。

10. **迟到自动保存不覆盖返回**（codex R3-high，需构造弱网/慢盘或工程自测）
   - action：复盘中画线并快速连续步进后立即点「返回」。
   - expected：再次「返回复盘」进入时，续接位置与画线为返回前的最新状态，不回退到中途某旧状态。
   - pass_fail：恢复到最新状态 = 通过；回退到旧状态 = 失败。

11. **复盘存档损坏可恢复**（codex R4-medium，工程注入损坏 saved 自测）
   - action：把某「已复盘」记录的存档人为置损坏 → 对该记录点「复盘」。
   - expected：不反复崩溃；提示「复盘存档损坏已清除」；该记录标记「已复盘」消失；进入的是从头的空白复盘（可重新画线保存）。
   - pass_fail：坏档被清除且可正常重新复盘 = 通过；反复失败/无法进入 = 失败。

12. **续复盘删回原样不误标复盘中**（codex R5-high）
   - action：对「已复盘」记录点「复盘」→ 画一条新线 → 点返回（此时应为「复盘中」）→「返回复盘」→ 把刚画的那条线删掉（回到与已保存存档相同）→ 点返回。
   - expected：最后返回后该记录回到「已复盘」（action sheet 为「复盘」非「返回复盘」）。
   - pass_fail：回到「已复盘」= 通过；仍卡「复盘中」= 失败。

---

## 13. 风险 / 边界

- **步进面板选择 vs 跨周期 tick**：`下一根` 步进所选面板一根，另一面板按同一 global tick 重锚（跨周期时间对齐，复用现几何）。粗周期一根=大步长为预期行为。
- **ReviewLedger 与 finalize 一致性**：必须逐值等于记录终局，否则"快进到结尾"与首页盈亏不符——用 host 断言 + mutation 守门。
- **画线归属混淆**：严禁复盘新画线写回原训练记录 `drawings`；autosave 目标必须是 `review_archive`。以测试锁定"原记录 drawings 复盘后不变"。
- **re-edit 回滚**：已复盘记录重编辑后"不保存"须回滚到旧 saved（schema 用 saved/working 分列支持）。
- **持久化乱序（codex R3-high/R4-high）**：延迟节流写可能落在返回终态写之后→退回旧状态。以单写者串行 + **进程内**（不落库）token/revision 守卫 + 终态 drain+fence（§6.3，对齐 replay 范式）根治，测试用延迟替身守门。
- **假"复盘中"（codex R3-medium）**：纯浏览不得留下 working 行。以"净改动才落 working + 返回无改动清 working"（§2/§4）根治，验收 case 9 守门。
- **saved 存档损坏（codex R4-medium）**：轻量标记查询不解码，坏 saved 会致"打开即崩"死循环。以"仅清 saved + 移除标记 + 从原记录空基线重进 + toast"（§9）根治，验收 case 11 守门。
- **续复盘删回原样卡复盘中（codex R5-high）**：净改动判定必须对 committed 基线（saved/∅）而非 resumed working，否则删回=saved 仍误判有改动。以 §2/§4 committed 基线根治，验收 case 12 守门。
- **ReviewLedger 价基（codex R5-medium）**：mark price 须为 global tick 的规范基准序列收盘价（同 finalize 价基）、越界 clamp 非 nil、不额外 round，才能 maxTick 逐位等于终局。§5.2.1 定义，host 测守门。
- **删除记录级联**：`ON DELETE CASCADE` 保证复盘存档随记录删除，避免孤儿标记。
- **本地工具链宽松**：SwiftUI 隔离/Sendable 错误本地可能漏报，合并后须确认 CI macos-15 真绿（参 memory `feedback_swift_local_ci_toolchain_strictness`）。

---

## 14. 未决问题

无（所有 UI + 行为决策已在 brainstorming 敲定，见 §2–§7 与 mockup）。
```

<!-- 决策留痕（brainstorming 2026-07-02）：
盈亏=逐tick重算；复盘中持久化=per-record；本RFC不做文本标注；行标记文案=再次训练中/复盘中/已复盘且放总资金正下方；action sheet 无小字；复盘底栏保留下单价文案+分段器，下一根步进所选红框面板周期；复盘中与已复盘互斥。 -->
