# 新需求 10 · Replay 续局 + 复盘可步进重演 — 设计 spec

> 日期：2026-06-30　分支：`worktree-feat+replay-resume-review-playback`（基线 origin/main `16d57d8`）
> 主题：**从历史记录重新体验** —— 两个相关改动合一个 PR。
> 关联：[[project_trade_ui_backlog_2026_06_21]] §新需求10、RFC-A（PR #132 资金/仓位）、Wave 3（ReplayFlow/ReviewFlow 冻结语义）。

---

## 0. 目标 / 非目标

### 目标
1. **Replay 续局**：replay（历史记录→"再次训练"）从"设计上非持久"改为"中途状态可保存、可续局"。中途返回不再丢进度，再次进入可**回到原 tick/状态接着练**。
2. **历史弹窗按钮文案切换**：replay 那颗按钮在 **「再次训练」**（无暂存档=从头开始）↔ **「返回训练」**（有暂存档=回原 tick 续练）之间按记录切换。
3. **复盘可步进重演**：复盘（"复盘"按钮）从"冻结在最后一根 K 线"改为"进入即停在训练起点、可逐根向前步进重演（只看不交易）"，K 线 + 当时买卖标记随步进渐显；并提供 **「快进到结尾」** 一键展开整局（＝原冻结全貌画面）。
4. **历史弹窗精简**：去掉「取消」按钮（点弹窗外遮罩即取消），弹窗更小。

### 非目标（明确不做，YAGNI）
- 不改 replay 的资金语义：replay 仍 **不累积资金**（`shouldAccumulateCapital=false`）、完成时 **不写 `training_records`**、结算仍是临时（`shouldShowSettlement=true` 但 ephemeral）。续局只让**中途状态**可保存/恢复。
- 不支持"每条记录各自独立暂存"。**单个 replay 暂存槽**（user 决策：同时只 1 局暂停的 replay；对另一记录开新 replay 覆盖旧档）。replay 暂存与 normal 暂存（`pending_training`）相互独立（可各 1 局暂停）。
- 复盘**不持久化进度**：复盘只读重演，离开即丢、下次重新从起点进入（续局需求只针对 replay 交易练习，不针对复盘观看）。
- 复盘**不重演盈亏过程**：复盘步进只控制"图表/标记的揭示进度"，顶栏盈亏始终显示该记录的**最终成绩**（详见 §B.4 D-B3）。不在复盘中按 tick 逐步重算 cash/position（避免极高复杂度）。
- 不支持"已有暂存档时从头重练"的独立入口（user 决策：单按钮切换文案；要重练把当前这局练到末尾即自动清档）。

---

## 1. 现状（事实，来自源码勘探）

### 1.1 Flow 能力矩阵（`TrainingFlowController.swift`）
协议方法：`mode / feeSnapshot / initialTick / allowedTickRange / canBuySell() / canAdvance() / shouldSaveRecord() / shouldAccumulateCapital() / shouldShowSettlement() / shouldGiveHapticFeedback()`。

| 能力 | NormalFlow | ReviewFlow | ReplayFlow |
|---|---|---|---|
| `initialTick` | `0`（coordinator 实际传入 metadata 派生 startTick，RFC-F） | `record.finalTick` | `0`（coordinator 传 metadata 派生 startTick） |
| `allowedTickRange` | `0...maxTick` | `finalTick...finalTick`（单点冻结） | `0...maxTick` |
| `canBuySell` | ✓ | ✗ | ✓ |
| `canAdvance` | ✓ | **✗** | ✓ |
| `shouldSaveRecord` | ✓ | ✗ | ✗ |
| `shouldAccumulateCapital` | ✓ | ✗ | ✗ |
| `shouldShowSettlement` | ✓ | ✗ | ✓ |
| `shouldGiveHapticFeedback` | ✓ | ✗ | ✓ |

### 1.2 Normal 暂存/恢复（已有，可镜像）
- 表 `pending_training`（单行 `CHECK(id=1)`，`app_schema_v1.sql`）：`training_set_filename / global_tick_index / upper_period / lower_period / position_data(base64 JSON) / fee_snapshot(JSON) / trade_operations(JSON) / drawings(JSON) / started_at / accumulated_capital / cash_balance / drawdown(JSON) / session_key`。
- 模型 `PendingTraining`（`AppState.swift`）。
- 仓储 `PendingTrainingRepository`（`savePending/loadPending/clearPending`）+ `PendingTrainingRepositoryImpl`（`INSERT OR REPLACE` id=1）。
- `TrainingSessionCoordinator.saveProgress()`：**前置=必须 Normal 模式**（review/replay no-op）；构造 `PendingTraining` 写库。
- `resumePending()`：载入 → 定位文件 → 重建引擎（`initialTick=pending.globalTickIndex` + 全部状态）。
- `AppRouter.continueTraining()` → `resumePending()`。
- 自动保存：lifecycle `autosave(immediate:)` / `flushForBackground()` → coalesced → `saveProgress()`；`back()` = `saveProgress()` + `endSession()`；`discardSession()` 清 pending + endSession；fencing/`terminating` 防竞态。

### 1.3 Replay / Review 装配（`TrainingSessionCoordinator`）
- `replay(recordId:)`：load 记录 bundle → open reader → load candles+metadata → `.replay(fees: record.feeSnapshot, maxTick:)` → `initialTick=startTick`（metadata 派生）`initialCapital=record.totalCapital` `initialCashBalance=record.totalCapital`（无持仓、不恢复 markers/drawings）→ `activeRecord=record` / `activeStartedAt=nil` / `activeSessionKey=nil`。
- `review(recordId:)`：load bundle → open reader → load candles → `.review(record:)` → `initialCashBalance=record.totalCapital + record.profit`（末态全现金）+ `initialMarkers=markers(from: ops)` + `initialDrawings` → `activeRecord=record` / `activeStartedAt=nil` / `activeSessionKey=nil`。
- startTick 派生：`TrainingEngine.startTick(forStartDatetime:in:)`（normal/replay 共用；review 当前未用）。

### 1.4 引擎步进与 reveal（`TrainingEngine` / `TickEngine` / `RenderStateBuilder`）
- 步进唯一入口 `advanceAndAccount(panel:)`：`tick.advance(steps: stepsForPeriod(...))` + 面板 `.tradeTriggered` reduce + `resetOffsetAfterAutoTracking` + `drawdown.update` + `forceCloseIfEnded`。被 `buy/sell` 调用；`holdOrObserve(panel:)` 也调它但 `guard flow.canAdvance() else { return }`。
- `TickEngine.advance(steps:)`（钳 maxTick）；`TickEngine.reset(to:)` **存在但从未被调用**（可用于 jump-to-end）。
- 引擎构造前置：`flow.allowedTickRange.contains(resolvedInitialTick)`、`flow.allowedTickRange.upperBound == maxTick`。
- **K 线渐显自动**：`RenderStateBuilder` `currentIdx = currentCandleIndex(candles, tick)`；`sliceEnd = min(startIndex+visibleCount, currentIdx+1)`；可见切片 `candles[startIndex..<sliceEnd]` 恒 ≤ currentIdx（看不到未来）。
- **标记渐显自动**：`drawMarkers` 收到的 `candles` = 可见切片；`MarkersLayout.markerPlacements` 用 `findCandleIndex(for: marker, in: 切片)`，超出切片（即超出 currentIdx）的标记 `continue` 跳过 → **不绘制**。故标记随 currentIdx 自动渐显，无需新增 tick 过滤。
- 初始视口自动：面板初始 `offset=0`（autoTracking）→ 显示"已揭示前缀的最右 `defaultVisibleCount=80` 根"；tick=startTick 时即显示起点附近（含 RFC-F 的 before-candles），无需改视口逻辑。

### 1.5 历史弹窗 / 路由
- `HistoryActionSheet`（`UI/HistoryActionSheet.swift`）：ZStack（遮罩 `.onTapGesture { onCancel() }` + 居中卡片）；卡片内 标题 + 「复盘」(onReview) + 「再来一次」(onReplay) + 「取消」(onCancel)；`.frame(maxWidth: 280)`。
- `AppRouter`：`selectRecord(id:)` → `activeModal=.history(record)`；`review(id:)`→`coordinator.review`；`replay(id:)`→`coordinator.replay`；`resetAllProgressAndReload()`→`settings.resetAllProgress()`(清 pending+资金回 10万) + `loadHome()`。

### 1.6 契约
- `CONTRACT_VERSION = "1.7"`（`Models.swift`）。最新 migration 0005（`user_version=3`）。迁移在 `AppDBMigrations.makeMigrator()`，`DefaultAppDB.init()` 注册。

---

## A. Replay 续局

### A.1 数据模型（新增持久格式）
新表 **`pending_replay`**（单行 `CHECK(id=1)`），列＝`pending_training` 全套 **＋ `record_id INTEGER NOT NULL`**（来源历史记录 id）：

```sql
CREATE TABLE IF NOT EXISTS pending_replay (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    record_id INTEGER NOT NULL,
    training_set_filename TEXT NOT NULL,
    global_tick_index INTEGER NOT NULL,
    upper_period TEXT NOT NULL,
    lower_period TEXT NOT NULL,
    position_data TEXT NOT NULL,
    fee_snapshot TEXT NOT NULL,
    trade_operations TEXT NOT NULL,
    drawings TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    accumulated_capital REAL NOT NULL,
    cash_balance REAL NOT NULL,
    drawdown TEXT NOT NULL
);
```
- 无 `session_key`（replay 不写 `training_records`、无 finalize 幂等需求）。
- 无外键：历史记录无"单条删除"路径；唯一清理来源＝重置（§A.7）＋恢复时校验记录仍存在（§A.6）。`accumulated_capital` 对 replay = 该局起始资金（`engine.initialCapital = record.totalCapital`），与 normal 字段含义对齐（不参与跨局复利）。

### A.2 模型 + 仓储
- `PendingReplay`（`AppState.swift`）：镜像 `PendingTraining` 全字段 **＋ `recordId: Int64`**。`Codable/Equatable/Sendable`。
- `PendingReplayRepository`（协议）：`saveReplay(_:) / loadReplay() -> PendingReplay? / clearReplay()`。
- `PendingReplayRepositoryImpl`：镜像 `PendingTrainingRepositoryImpl`（`INSERT OR REPLACE` id=1；base64 position；JSON 复杂字段；解码遗留 fee 容错沿用 WB-1 sanitize 模式）。
- 测试替身 `InMemoryPendingReplayRepository`（镜像现有 `InMemoryPendingTrainingRepository`）。

### A.3 Flow 能力新增
`TrainingFlowController` 新增 **`shouldPersistProgress() -> Bool`**：
- Normal = **true**、Replay = **true**、Review = **false**。
- 取代 `saveProgress()` 里"仅 Normal"的硬判断。各 flow 显式实现（不用协议默认，沿用 [[project_pr63_e4_merged]] D2"矩阵权威、每 struct 显式"教训）。

### A.4 Coordinator 改动
1. **autosave 入口 + `saveProgress()` 双双改门控**（codex spec-R1-F1：**仅改 saveProgress 不够**——autosave 入口本身硬门控 Normal，replay 会只在显式 Back 才存、crash/后台丢档）：
   - **`requestAutosave(engine:immediate:)`**（L78-79，**autosave 真入口**）：`guard !terminating, engine.flow.mode == .normal` → 改 `guard !terminating, engine.flow.shouldPersistProgress()`。这样 replay 的 tick 节流 / 交易·画线 immediate / 后台 flush 全部启用；**review 仍 `shouldPersistProgress()==false` → no-op**。`flushAutosave`/`flushForBackground` 只 await 已排程 task、无模式门，自动适配。
   - **`saveProgress()`**（L326-327）：`guard mode == .normal` → `guard shouldPersistProgress()`；体内按 mode 分流：
     - `mode == .normal` → 构造 `PendingTraining` 写 `pending_training`（**原逻辑一字不改**）。
     - `mode == .replay` → **fail-closed 守卫（codex plan-R3-F2，镜像 normal 活跃上下文守卫）**：`guard activeEngine === engine, let file = activeFile, let recordId = activeRecord?.id, let started = activeStartedAt else { throw .internalError(...) }`——缺上下文 **throw**（autosave/back 显错）而非静默 `return`（静默=用户无感进度丢失）。
       - **clean-skip 守卫（codex plan-R4-F1/R6-F1，关键）**：守卫后、写槽前 —— 若 **`!replayHasPersisted`（本会话尚未写过槽）且** 当前态 `(tick, ops.count, drawings.count)` == 会话**基线** `replayBaseline` → **`return`（跳过写）**。因 `back()` **无条件**调 saveProgress、`flushForBackground` 强制 flush——无此守卫则开 fresh replay B 零操作 Back/切后台会用 B 初始态**覆盖另一记录 A 的槽**。**首写后 `replayHasPersisted=true` → 永不跳过**（否则"加画线→写→删画线(count 回基线)→跳过"会残留已删画线；仅计数不足判脏，用"是否已拥有槽"门控，codex plan-R6-F1）。`replayHasPersisted`：fresh=false / **resumed=true（续局本就拥有槽）** / 任一次成功 saveReplay 后=true；`endSession` 重置。此 `return` 是"无进度可存"正常跳过（≠ F2 缺上下文 throw）；写槽成功后置 `replayHasPersisted=true`。
       - 否则构造 `PendingReplay`（`trainingSetFilename=file.filename`、`cash_balance = max(0, engine.cashBalance)`、`accumulated_capital = engine.initialCapital`、`global_tick_index = engine.tick.globalTickIndex`、`startedAt=started`、`recordId` 等）写 `pending_replay`。replay 不依赖 `activeSessionKey`（无 sessionKey）。
2. **`replay(recordId:)`（从头）补充**（codex spec-R1-F3：**不前置 clear**——易错装配失败会丢旧档）：
   - **不**在装配前 `clearReplay()`。**单槽覆盖靠首次保存的 `INSERT OR REPLACE`（id=1）自然覆盖**：新 replay 一旦 autosave/back 即写 `pending_replay(recordId=新)` 覆盖旧档。故"开新 replay 即覆盖"语义保留，且**装配（开 reader/load candles/构造引擎）任一步失败 → 旧暂停档原封不动**（无数据丢失）。
   - 设 `activeStartedAt = now()`（replay 会话起始，供 `PendingReplay.started_at`）；`activeRecord = record`（已设）；**捕获 `replayBaseline = (tick, ops.count, drawings.count)`**（fresh = startTick/0/0，供 clean-skip）。`activeSessionKey` 保持 nil。
   - 其余装配不变（fresh：无 initialMarkers/position）。
   - 边界：开新 replay B 后**零操作**即退出 → **clean-skip 守卫**（§A.4.1）使 `back()`/后台 flush 不写槽 + **条件清**（§A.4.4）使 B 终局不动 A 的槽 → **旧档 A 完整保留**，A 仍显"返回训练"、B 显"再次训练"。B 一旦有进度（步进/交易/画线）再存 → 覆盖单槽为 B（last-active wins，符合 D-A1/D-A4）。注：slot==A 时记录 A 的按钮本就显"返回训练"，不可达"对 A 开从头 replay"。
3. **新增 `resumePendingReplay(recordId:) async throws -> TrainingEngine?`**（**精确镜像 `resumePending` 的错误纪律**，codex plan-R1-F1）：
   - **错误纪律（关键）**：`loadReplay()` / `loadRecordBundle` / `loadAllCandles` / `make` / decode 的错误**一律传播**（throw，**不清档、不覆盖槽**；含 `.dbCorrupted`——fail-closed，同 resumePending 的 loadPending 传播）。瞬态错误经路由 setError、**不回退从头**（防丢有效暂停档）。**唯一清档点 = openReader「已验证损坏」(`isCorruptTrainingSet`)** → `cache.delete + clearReplay + 返回 nil`。
   - `loadReplay()` 无槽 或 `pending.recordId != recordId` → 返回 nil（**不清档**；调用方回退从头）。
   - `recordRepo.loadRecordBundle(id: pending.recordId)`：错误传播（记录不被单独删除——reset 连带清槽无孤儿——故必为瞬态）。设 `activeRecord = bundle.record`。
   - open reader：corrupt(`isCorruptTrainingSet`)→ `cache.delete` + `clearReplay()` + 返回 nil（镜像 normal resume）；其他错误传播。
   - load candles → `.replay(fees: pending.feeSnapshot, maxTick:)` 重建，注入 saved 状态：`initialTick=pending.globalTickIndex` / `initialCapital=pending.accumulatedCapital` / `initialCashBalance=pending.cashBalance` / `initialPosition=decode(pending.positionData)` / `initialMarkers=markers(from: pending.tradeOperations)` / `initialDrawings=pending.drawings` / `initialTradeOperations=pending.tradeOperations` / `initialDrawdown=pending.drawdown` / `initialUpper/LowerPeriod`。
   - 成功后会话上下文：`activeReader/activeEngine/activeFile`、`cache.touch(file)`、`activeStartedAt = pending.startedAt`、`activeRecord = bundle.record`、`activeSessionKey = nil`、`replayBaseline=(resumed 态)`、**`replayHasPersisted = true`（续局本就拥有该记录槽 → 永不 clean-skip）**、`resetAutosaveState()`。
4. **清档时机（关键——区分"续局保留" vs "终局清除"，且终局须 fence）**：
   - **`endSession()` 对 replay 不清 `pending_replay`**。理由：`back()` = `saveProgress`(写 pending_replay) + `endSession()`；若 endSession 清档则续局立即失效。endSession 仅关 reader/清活跃上下文（原语义，含 `terminating=true` fence）。
   - **终局清档须 fence+drain（codex spec-R1-F2）**：replay 走到结算（到 maxTick 自动结算 **或** 手动「结束本局」）→ 终局清档前**必须 `await fenceAndDrainAutosaves()` 再 `clearReplay()`**，否则末根 tick 的 `onChange` 已排队的 autosave 会在 clear 后跑、把 maxTick 终态写回 `pending_replay` → 按钮错显"返回训练"、再进=终态陈旧局。镜像 Normal `finalize`（L362 先 fence 再单事务）。
     - 实现：`replaySettlementPayload` 现为 **sync `throws` 且无 fence**（注释明示原"不触 pending"不变量——本 PR 刻意打破）→ 改为 **async**，**顺序（codex plan-R1-F2）**：①两 guard → ②`await fenceAndDrainAutosaves()`（此后无并发写）→ ③`loadMeta` + 构造 `record`（**全部 throwing payload 工作，槽仍在**）→ ④**成功后才** **条件清** `if let id = activeRecord?.id { try clearReplay(ifRecordId: id) }` → ⑤return record。**清档绝不早于 payload 全部成功**。clearReplay 抛 → 方法抛、record 不返回 → **caller 保留 session+槽、可重试**（不 `onSessionEnded(nil)` 拆毁）。连带 `lifecycle.replaySettlementRecord()` 改 async；`TrainingView` 新增 `runReplaySettlement()`（镜像 `runFinalize` 重入门）+ `replaySettlementFailed` alert（重试/退出本局）；`routeEndOfSession` replay 分支调它。
   - **条件清（codex plan-R3-F1，关键）**：终局/discard 用 **`clearReplay(ifRecordId: activeRecord.id)`**（原子 `DELETE WHERE id=1 AND record_id=?`），**仅清属于当前 replay 记录的槽**。因"不前置 clear"——开新 replay B 在任何成功保存前就到终局（如开 B 立即「结束本局」）时槽仍 = 旧记录 A；无条件清会误删 A。条件清则 B 终局 no-op、A 保留。reset（§A.7）用无条件 `clearReplay()` 清全部。
   - **丢弃清档**：`discardSession()` 当 `mode==.replay` 用 `clearReplay(ifRecordId: activeRecord.id)`（已先 `fenceAndDrainAutosaves`，L460；normal 时清 `pending_training`）。
   - 故 pending_replay 生命周期：`replay()`(从头, **不清旧档**) → 玩(autosave 写档) → `back()`(saveProgress 写档, endSession **不清**) → 续局 `resumePendingReplay` → … → 终局结算/discard(**fence→条件清 ifRecordId**) **或** 被新 replay 首存 `INSERT OR REPLACE` 覆盖 **或** reset 无条件清。
5. **新增查询 `hasResumableReplay(recordId:) -> Bool`**：`(try? loadReplay())?.recordId == recordId`。**display-only / advisory**（仅历史弹窗按钮文案）；**不当路由门**。读失败保守返 false 安全，因路由是 resume-first 权威（见 §A.5）：一次瞬态 false 至多让按钮短暂误显"再次训练"，点击仍走 resume-first、不会丢槽。

### A.5 路由 + UI（**resume-first 权威**，codex plan-R1-F1）
- **`AppRouter.replay(id:)` 分流**：**总先试** `resumePendingReplay(id)`——返非 nil→续局；返 nil（无槽/不匹配/已验证损坏已清）→从头 `replay(id)`；**throw（瞬态）→ setError，不 fresh、不覆盖槽**。**不**用 `hasResumableReplay` 当路由门（防其瞬态 false 触发 fresh 覆盖有效槽）。
- **历史弹窗呈现**：`AppRootView` 呈现 `HistoryActionSheet` 时把 `coordinator.hasResumableReplay(record.id)`（display-only）传入 sheet 决定钮文案。文案与路由可在罕见瞬态错误下短暂不一致，但方向安全（点击 resume-first 不丢槽）。
- **`HistoryActionSheet` 改动**：
  - 去掉「取消」按钮（遮罩 `.onTapGesture { onCancel() }` 仍在，`onCancel` 回调保留）。
  - replay 钮文案：新增参数 `hasResumableReplay: Bool` → 文案 `hasResumableReplay ? "返回训练" : "再次训练"`（替换原 "再来一次"）。「复盘」不变。
  - 卡片更小（去掉一颗按钮 + 末尾 `Spacer`，`maxWidth` 视觉收紧；具体值 plan 定）。

### A.6 错误处理（精确镜像 normal resume；**区分瞬态 vs 已验证损坏**，codex plan-R1-F1）
- **唯一清档 = 训练集 open「已验证损坏」(`isCorruptTrainingSet`)** → `cache.delete + clearReplay + 返回 nil`（孤儿槽不可恢复）。
- **瞬态/未分类错误一律传播（不清档、不覆盖槽）**：`loadReplay`（含 decode `.dbCorrupted`，fail-closed）、`loadRecordBundle`、`loadAllCandles`、`make`/decode position 失败 → throw → 路由 setError、不回退从头。
- `pending.recordId` 不匹配 / 无槽 → 返回 nil（**不清档**）。
- 自动保存 fencing / `terminating` 机制对 replay 复用（同一 coordinator 状态机）。

### A.7 重置
`settings.resetAllProgress()` / `DefaultAppDB.resetAllTrainingProgress`（RFC-A 后保留记录）连带 **清 `pending_replay`**（与清 `pending_training` 并列）。重置后所有记录按钮恢复"再次训练"。

### A.8 契约 / 迁移
- 新 migration **0006**（`AppDBMigrations.makeMigrator()` 末尾，命名 `0006_v1.8_pending_replay`）：`CREATE TABLE IF NOT EXISTS pending_replay (...)` + `PRAGMA user_version = 4`（镜像 0004/0005 风格）。
- **⚠️ 只加 migration，绝不动 `ios/sql/app_schema_v1.sql` 与 `AppDBMigrations.v1_4_baselineDDL`**：二者＝**v1.4 冻结基线**（`pending_training` 都无 session_key——那是 0004 加的），由 CI `scripts/check_app_schema_drift.sh` 校验**严格相等**。`pending_replay` 是 v1.8 新表，与 session_key 同样只走 migration（fresh install 经 0001→…→0006 链建全表），改基线会 drift 红。
- **`CONTRACT_VERSION` 1.7→1.8**（沿用"每 migration 必 bump"先例 0004→1.6 / 0005→1.7）。additive（新表，旧读者忽略）；连带 CODEOWNERS approve 门（trust-boundary：`*.swift`/migrations）。

---

## B. 复盘可步进重演（含快进到结尾）

### B.1 ReviewFlow 改动
- 新增构造参数 `startTick: Int`（coordinator 从 metadata 派生传入）。
- `initialTick = startTick`（原 `finalTick`）。
- `allowedTickRange = startTick...record.finalTick`（原单点 `finalTick...finalTick`）。
- `canAdvance() = true`（原 false）—— 解锁 `holdOrObserve` 步进。
- `canBuySell() = false`（不变，只看不交易）。
- 新增能力 **`canJumpToEnd() -> Bool`**：Review=true、Normal=false、Replay=false。
- `shouldShowSettlement=false` / `shouldAccumulateCapital=false` / `shouldSaveRecord=false` / `shouldPersistProgress=false` 均不变。
- `shouldGiveHapticFeedback`：保持 false（复盘步进不震动；如需可后续微调，本次不做）。

### B.2 startTick 派生（无 schema 改动）+ FlowInput 触点
`coordinator.review(recordId:)` 增：load metadata（reader 已开），`startTick = TrainingEngine.startTick(forStartDatetime: meta.startDatetime, in: ...)`（与 replay 同一调用）；经 FlowInput 传入。**`TrainingRecord` 不加字段**（startTick 从训练集 metadata 确定性派生，记录引用同一 `trainingSetFilename` → 同 metadata → 同 startTick）。
- **FlowInput 触点**（已勘实）：`TrainingEngine.FlowInput.review(record:)` → **`.review(record:, startTick:)`**；`make` 内 `case .review:` **先校验** `guard startTick >= 0, record.finalTick >= startTick else { throw .trainingSet(.emptyData) }`（**codex plan-R3-F3**：损坏 record 的 `finalTick < startTick` 会让 `startTick...finalTick` ClosedRange 构造 **trap 崩溃**；须在构造 flow 前抛可恢复错误）→ `maxTick = record.finalTick` + `flow = ReviewFlow(record: record, startTick: startTick)`。同步：preview fixture（`make` DEBUG 分支 `case .review`）补 startTick（preview 取 0 或派生值）。
- 引擎前置仍满足（已勘实 L96/L106）：`allowedTickRange.contains(startTick)`（startTick∈start...final）；`upperBound==maxTick`（`.review` maxTick=record.finalTick 不变 = range 上界 finalTick）；`m3.last.endGlobalIndex >= maxTick` 用 `>=`（review m3 为训练组全集，末根可 > finalTick，安全）。

### B.3 引擎步进 / jump-to-end
- **步进**：复用现成 `holdOrObserve(panel:)`（`canAdvance()=true` 即生效）；review 无持仓 → `forceCloseIfEnded` no-op；`advanceAndAccount` 的面板 `.tradeTriggered` reduce 把镜头吸附到揭示前缘（与训练一致）。**不新增 advance API**。
- **jump-to-end**：新增 `TrainingEngine.jumpToEnd()`：`guard flow.canJumpToEnd() else { return }`；`tick.reset(to: tick.maxTick)`；两面板吸附 autoTracking（镜像 `advanceAndAccount` 的 `resetOffsetAfterAutoTracking`/`.tradeTriggered`）；`drawdown.update`。无 `forceClose`（无持仓）。到末尾后 K 线+标记全揭示＝原冻结全貌。

### B.4 顶栏盈亏显示决策（D-B3）
保持 `review()` 现有资金装配不变：`initialCapital=record.totalCapital`、`initialCashBalance=record.totalCapital+record.profit`、无持仓。则步进/快进全程 `currentTotalCapital=cashBalance`（持仓 0、currentPrice 变化不影响）＝该记录**最终成绩**恒定；`returnRate=(末-起)/起=record 的 return`。即复盘顶栏始终显示该局**最终盈亏**，步进只控制图表/标记揭示。
- 理由：复盘=回看一局**已完成**记录的成绩与走势；不在复盘中按 tick 重算 cash/position（需逐根重放已记录交易，复杂度极高、易错），是明确取舍（非目标）。

### B.5 UI（训练界面控件门控）— 已勘实
**事实**：`TrainingView.showsTradeButtons = engine.flow.canBuySell()` 门控**整条 `TradeActionBar`**（买/卖/观察捆在一起）。复盘 `canBuySell=false` → 整条不显示 → **当前复盘无任何步进控件**。故复盘步进**不能靠"翻 canAdvance 复用现条"**，须**新增 review 专用控件条**。
- 新增谓词 `showsReviewControls = engine.flow.canAdvance() && !engine.flow.canBuySell()`（＝复盘可步进态），渲染一个**精简控件条**（不含买/卖）：
  - 「下一根」→ `engine.holdOrObserve(panel: activePanel)`（复用现成步进；`canAdvance=true` 生效；activePanel 沿用现有选择，步长 = `stepsForPeriod(活动周期)`，与训练一致）。
  - 「快进到结尾」→ `engine.jumpToEnd()`；**仅 `engine.flow.canJumpToEnd()` 为真时显示**。
  - 位置/样式 plan 定（建议占 TradeActionBar 同一槽位，复盘时以该条替之）。
- 买/卖控件：复盘恒隐藏（`canBuySell=false` 不变）。
- K 线 + 标记渐显：自动（§1.4），无改动。
- 既有 `onChange(of: tick) { tradeStrip=nil; lifecycle.autosave(immediate:false); maybeAutoEnd() }` 对复盘步进的影响：`autosave` → `saveProgress` 因 `shouldPersistProgress()==false` 早返 no-op（无害）；`maybeAutoEnd` 见 §B.6 安全。

### B.6 边界（含 maxTick 自动结算安全性）— 已勘实
- **复盘步进/快进到 maxTick 不会误触自动结算/退出**：`lifecycle.shouldAutoFinalize = isAtEnd && flow.shouldShowSettlement() && !didFinalize`，按 **`shouldShowSettlement()`（Review=false）** 抑制（**非** `canAdvance()`）。故把 `canAdvance` 翻 true 后，复盘到末尾仍 `shouldShowSettlement=false → shouldAutoFinalize=false`，只显整局全貌、不退出。**前置约束：本 spec 保持 ReviewFlow `shouldShowSettlement=false` 不变**（若改动则破坏此抑制）。
- `back()` 复盘 = `saveProgress`(no-op, shouldPersistProgress=false) + `endSession` → 复盘不持久（D-B4）。
- 周期组合：记录无周期字段，复盘沿用现 review 的引擎默认周期组合（不改）。
- `startTick == finalTick`（极短局）：range 退化单点，「下一根」无可推进、`jumpToEnd` no-op，等价旧冻结行为，安全。
- 步进到 maxTick 后再「下一根」：`tick.advance` 返 false（已钳 maxTick），无副作用。

---

## 2. 决策汇总

| # | 决策 | 选择 | 理由 |
|---|---|---|---|
| D-A1 | replay 暂存范围 | **单个暂存档**（单行 `pending_replay`） | user 拍板；与 normal 单行模型一致、最简、风险最低；按钮文案仍按记录正确显示 |
| D-A2 | 按钮文案 vs 路由 | **路由 = resume-first 权威**（总先试 `resumePendingReplay`）；`hasResumableReplay` 仅 display-only 决定钮文案（codex plan-R1-F1） | 旧"同源"方案下 `hasResumableReplay` 瞬态 false 会让路由走 fresh→首存覆盖有效槽=数据丢失；resume-first 把路由与脆弱 Bool 解耦，瞬态 throw→setError 不覆盖槽 |
| D-A3 | replay 与 normal 暂存关系 | **独立两槽**（`pending_training` + `pending_replay` 各单行） | 可同时各暂停 1 局；开 replay 不动 normal 复利进度（RFC-A） |
| D-A4 | 单槽覆盖机制 | **不前置 clear**；靠新 replay 首次保存 `INSERT OR REPLACE`(id=1) 覆盖旧档（codex spec-R1-F3） | 开新 replay 即覆盖语义保留，但**失败装配不丢旧档**；不在 UI 做确认弹窗（练习数据、低风险，YAGNI） |
| D-A7 | replay autosave 启用点 | 改 **`requestAutosave` 入口门** `mode==.normal`→`shouldPersistProgress()`（非仅改 saveProgress）（codex spec-R1-F1） | autosave 真入口在 requestAutosave；不改它则 replay 仅 Back 存、crash/后台丢档 |
| D-A8 | replay 终局清档 | 先 `await fenceAndDrainAutosaves()` 再 **条件清** `clearReplay(ifRecordId:)`（payload 成功后）；`replaySettlementPayload` 改 async（codex spec-R1-F2 / plan-R3-F1） | 防末根排队 autosave 复活 slot；防误删别记录槽；镜像 Normal finalize §4.7d |
| D-A9 | clean replay 不写槽 | replay save 设会话基线 + `replayHasPersisted` 标志；**仅 `!replayHasPersisted && 当前态==baseline`** 才跳过写（codex plan-R4-F1/R6-F1） | `back()`/后台 flush 无条件保存→无守卫则 clean fresh B 覆盖别记录 A 槽；**仅计数判脏会让"加画线→删画线"残留**，故首写后(拥有槽)永不跳过；resumed 本就拥有槽=true |
| D-A5 | CONTRACT_VERSION | 1.7→1.8 + migration 0006 | 沿用每 migration 必 bump 先例；additive 新表 |
| D-A6 | 去「取消」按钮 | 去掉，遮罩点击取消，保留 `onCancel` | user 拍板；弹窗更小 |
| D-B1 | 复盘起点 | metadata 派生 startTick，**不加 record 字段** | 确定性派生、零 schema 改动；与 normal/replay 同源 |
| D-B2 | 复盘是否双模式 | **单一可步进模式 + 快进到结尾** | user 拍板（统一方案）；一个模式覆盖"重走过程"+"看整体"，diff 更小、利于 codex 收敛 |
| D-B3 | 复盘盈亏显示 | 全程显示记录**最终成绩**，步进只控揭示 | 避免逐 tick 重放交易的高复杂度；复盘=回看已完成成绩 |
| D-B4 | 复盘是否持久化进度 | **否** | 续局需求只针对 replay；复盘每次从起点重进，简单 |
| D-B5 | jump-to-end 实现 | 复用现成未调用的 `TickEngine.reset(to:)` + 新 `canJumpToEnd()` 门控 | 最小新增；语义清晰可测 |

---

## 3. 受影响文件（预估，plan 阶段精化）

**新增**
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingReplayRepositoryImpl.swift`（enum 静态方法，镜像 `PendingTrainingRepositoryImpl`）
- migration **0006**（`AppDBMigrations.swift` 内 `CREATE TABLE pending_replay`，**不动** `app_schema_v1.sql`/baseline DDL）
- `PendingReplayRepository` 协议（`Persistence/PendingReplayRepository.swift`，sync throws 镜像 `PendingTrainingRepository`）+ `InMemoryPendingReplayRepository`（`PreviewFakes/InMemoryFakes.swift`，`#if DEBUG`，镜像 normal 替身含 fail-injection/saveCount）
- 测试：flow 矩阵、coordinator replay save/resume/clear、review playback、jumpToEnd、按钮文案、reset 清档、sheet 去取消、迁移。

**修改**
- `TrainingEngine/TrainingFlowController.swift`（+`shouldPersistProgress` +`canJumpToEnd`；ReviewFlow `init(record:, startTick:)`/范围 `start...final`/`canAdvance=true`；Normal/Replay 显式实现新方法）
- `TrainingEngine/TrainingSessionCoordinator.swift`（**`requestAutosave` 门 `mode==.normal`→`shouldPersistProgress()`**、saveProgress 分流、replay 会话 startedAt（不前置 clear）、resumePendingReplay、review 派生 startTick、**`replaySettlementPayload` 改 async + fence+clearReplay**、discard 清 replay、hasResumableReplay）
- `UI/TrainingSessionLifecycle.swift`（`replaySettlementRecord()` 改 async 以承接 async `replaySettlementPayload`）
- `TrainingEngine/TrainingEngine.swift`（+`jumpToEnd()`；`FlowInput.review(record:, startTick:)` + `make` 的 `.review` 分支 + preview fixture 分支）
- `AppState.swift`（+`PendingReplay` 结构，镜像 `PendingTraining` 去 sessionKey + 加 `recordId: Int64`）
- `Models/Models.swift`（CONTRACT_VERSION 1.7→1.8）
- `KlineTrainerPersistence/DefaultAppDB.swift`（conform `PendingReplayRepository`：saveReplay/loadReplay/clearReplay/**clearReplay(ifRecordId:)** 委托 Impl + 错误映射；`resetAllTrainingProgress` 加无条件 `clearReplay`）
- `KlineTrainerPersistence/AppContainer.swift`（coordinator 注入 `pendingReplayRepo: db`）
- `App/AppRouter.swift`（`replay(id:)` resume-first 分流：先 `resumePendingReplay`，nil→fresh，throw→setError）
- `App/AppRootView.swift`（历史弹窗传 display-only `hasResumableReplay` bool）
- `UI/HistoryActionSheet.swift`（去「取消」按钮、`hasResumableReplay` 文案切换参数、缩小）
- `UI/TrainingView.swift`（+`showsReviewControls = canAdvance && !canBuySell`；复盘控件条「下一根」+「快进到结尾」；**replay 终局 `runReplaySettlement()`（async）+ `replaySettlementFailed` 可重试 alert，不 `onSessionEnded(nil)` 拆毁**；review autosave/maybeAutoEnd 已证安全）+ 可能新增 `UI/ReviewControlBar.swift`（精简控件条，平台无关纯内容 + 薄壳，plan 定是否拆文件）
- composition root（注入 `PendingReplayRepository`：`DefaultAppDB`/`AppContainer` 装配）+ `settings.resetAllProgress`/`DefaultAppDB.resetAllTrainingProgress`（清 pending_replay）+ AppRootView 历史弹窗呈现处（传 `hasResumableReplay`、去 `onCancel` 按钮无关——遮罩仍用）

---

## 4. 测试计划

**host `swift test`（两框架 0 失败）**
- Flow 矩阵：`shouldPersistProgress`（N=✓/R=✓/Rev=✗）、`canJumpToEnd`（Rev=✓/N=✗/R=✗）、ReviewFlow `initialTick==startTick` / `allowedTickRange==start...final` / `canAdvance==true`。
- Coordinator（in-memory fakes）：
  - replay 从头 → `saveProgress` 写 `pending_replay`（recordId 正确）；`hasResumableReplay` 真。
  - **autosave 入口（spec-R1-F1）**：replay 的 `requestAutosave(immediate:false)`（tick 节流）、`requestAutosave(immediate:true)`（交易/画线）、`flushAutosave`（后台）均**写 `pending_replay`**；**review 的 requestAutosave 仍 no-op**（不写任何 pending）。
  - `resumePendingReplay` 还原 tick/cash/position/markers/drawings/drawdown；recordId 不匹配 → nil（**不清档**）；**瞬态 loadReplay/loadRecordBundle 失败 → 传播 throw + 槽保留**（不清、不 fresh，codex plan-R1-F1）；仅 openReader 已验证损坏 → 清档 nil。
  - **单槽覆盖（spec-R1-F3）**：已有 `pending_replay`(A)，开新 replay(B) 并保存 → slot 变 B（`INSERT OR REPLACE` 覆盖）；**failed fresh replay 回归**：已有 A、开 B 但装配抛错 → A 仍在（未被清）。
  - **条件清不删别记录槽（plan-R3-F1）**：A 有槽、开 B 未保存即终局/discard → 条件清 `ifRecordId=B` no-op → A 的槽保留。**fail-closed save（plan-R3-F2）**：缺活跃上下文（如 startedAt/recordId 缺、stale engine）→ saveProgress 对 replay **throw**（非静默 no-op）。
  - **clean-skip 不覆盖别记录槽（plan-R4-F1）**：A 有槽、开 fresh B 零操作 → `back()`(saveProgress) **与** 后台 `flushAutosave` 均跳过写 → A 仍在；B 有进度后存 → 覆盖为 B。
  - **首写后不残留（plan-R6-F1）**：replay 加画线→存→删画线（count 回基线）→存 → 槽更新为无画线（`replayHasPersisted` 后不跳过），续局无陈旧画线。
  - **复盘 tick 范围守卫（plan-R3-F3）**：`make(.review(record:finalTick=5, startTick=10))` → 抛 `AppError.trainingSet(.emptyData)`（不 trap）。
  - **终局清档 fence + payload-before-clear 回归（spec-R1-F2 / plan-R1-F2）**：replay 步进到 maxTick 且有一个排队的 autosave → 终局 fence→构建 payload→clear 后 `pending_replay` 仍为空（排队 autosave 不复活）；**clearReplay 抛 → 方法抛 + 槽保留（可重试）**；`discardSession`(replay) → 清档。
  - `saveProgress` 在 review 模式 = no-op；normal 路径回归不变（写 `pending_training`，字节级）。
  - reset → `pending_replay` 同 `pending_training` 一起清空。
- 引擎：`jumpToEnd` 设 tick=maxTick + 镜头吸附 + 非 review/canJumpToEnd=false 时 no-op；review 步进经 `holdOrObserve` 推进且不交易；review 顶栏 `currentTotalCapital==record.totalCapital+profit` 恒定。
- 渲染（host 纯函数）：currentIdx=startTick 时切片末根≤currentIdx；超 currentIdx 的 marker 不入 placement（回归确认自动渐显）。
- UI 纯内容：`HistoryActionSheet` 文案随 `hasResumableReplay` 切换；无「取消」按钮但遮罩 `onCancel` 仍触发。
- 迁移：0006 后 `user_version==4`；`pending_replay` 表存在；旧库升级幂等。

**Catalyst**：`KlineTrainerContracts` 包 scheme `build-for-testing` SUCCEEDED（UIKit-gated 代码编译闸门，含训练界面 UI 改动）。CI-gate `grep -E "(error|warning):"` count 0。

**iOS Simulator**：app `BUILD SUCCEEDED`。

**模拟器/真机人工验收**（acceptance 清单，Chinese，action/expected/pass-fail）：见 `docs/superpowers/acceptance/2026-06-30-replay-resume-review-playback.md`（plan/实现阶段产出）。

---

## 5. 治理 / 风险

- **触碰 Wave-1 冻结契约 `TrainingFlowController`**（加方法 + 改 ReviewFlow）→ codex 重点审；各 flow 显式实现新方法、不破坏既有调用点。
- **CONTRACT_VERSION bump + 新 migration** → CODEOWNERS approve 门；migration 幂等 + 旧库升级路径测。
- **`saveProgress` 分流**：normal 分支字节级不变（回归测护住）；replay 分支不依赖 sessionKey。
- **单槽并发**：`hasResumableReplay`/路由同源 + resume 兜底回退（D-A2）。
- **复盘语义变更**（冻结→可步进）：顶栏成绩恒定的取舍写死在 spec（D-B3），codex 易质疑"为何盈亏不随步进变"——已在非目标/决策中明确理由。
- 评审通道＝真 Codex `codex-attest.sh --scope branch-diff --head worktree-feat+replay-resume-review-playback --base main`。
