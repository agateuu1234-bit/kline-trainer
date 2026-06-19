# 重置资金「真正归零重来」设计文档（W3 运行时 #1 + #6）

> 状态：设计已获用户口头批准（Option A）。用户授权完全按 superpowers 流程自主推进，评审用 **Claude Opus 4.8 xhigh 对抗性 review** 跑到收敛（代 codex，user-explicit）。本文档为后续 writing-plans 的权威输入。
> 关联：运行时验证发现 `project_runtime_verification_findings_2026_06_17`（#1 重置资金、#6 全新安装顶栏 ¥0）。

## 1. 背景与问题

`重置资金` 按钮当前实现与产品意图三处脱节：

1. **重置写 0，不写 10 万（真 bug）**：`SettingsStore.resetCapital()`（`SettingsStore.swift:80`）把内存 `settings.totalCapital = 0`；`SettingsDAOImpl.resetCapital(_:)`（`SettingsDAOImpl.swift:87-91`）持久化 `total_capital = "0.0"`。而 UI 标签与冻结 spec §6.4 都承诺"→ 10 万元"，自相矛盾。
2. **累计模型绕过设置（行为缺口）**：新一局起始资金由 `TrainingSessionCoordinator.startingCapital()`（`TrainingSessionCoordinator.swift:451-455`）决定——**有任意训练记录时取"上一局结束资金"（`stats.currentCapital = 末条 total_capital + profit`），只有零记录时才读 `settings.totalCapital`**。因此即便把 resetCapital 改成写 10 万，只要还有历史记录，下一局照旧从累计值开始，"重置"对有记录的用户等于无效。
3. **#6 全新安装从 ¥0 起（真 bug）**：`SettingsDAOImpl.loadSettings`（`SettingsDAOImpl.swift:27`）对缺失的 `total_capital` 键默认 **0**（非 10 万）。冻结 spec 第 861 行明写"总资金：初始 10 万"。正确的 10 万默认值只存在于 `AppSettings.default`（`AppState.swift:174-180`），而它仅在崩溃恢复 `forceResetAndReload` 路径使用，全新安装从不经过它。零记录 + 零设置 → `startingCapital()` 返 0 → 顶栏 ¥0、开局无法交易。

`#1` 与 `#6` 同根：**10 万这个默认值从未被真正"种"进实时设置**。

## 2. 目标与非目标

**目标**
- G1：「重置资金」实现"真正归零重来"——重置后下一局确实从 ¥100,000 干净起步（含重置累计基线）。
- G2：修 #6——全新安装 / 无资金记录时以 ¥100,000 起步，而非 ¥0。
- G3：重置为破坏性操作，须二次确认且如实披露"将清空训练记录"。

**非目标（本次明确不做）**
- 不清空已下载的行情 / 训练组缓存（`cached_sets` / 文件缓存）——重置后无需重新下载。
- 不改佣金率、夜间模式等其它设置。
- 不改数据库 schema（无 DDL、无新迁移、`user_version` 维持 2、`CONTRACT_VERSION` 维持 "1.6"）。
- 不改累计模型本身（清空记录后 `startingCapital()` 天然走零记录分支读设置，无需动 D4 逻辑）。
- 不引入"保留历史 + 重置基线"的标记式方案（Option B，已被用户否决）。

## 3. 决策：Option A「全部清空，彻底重来」

用户已在 brainstorming 中选定 Option A：重置时**连历史记录一起清空**。理由：资金统计本就从记录推算，清掉记录后系统自然回到 10 万，最简单可靠、无需改 schema、与现有"统计派生自记录"架构自洽；代价是过去训练记录消失（用户已知情接受）。

## 4. 行为规格

按下「重置资金」→ 弹二次确认（文案披露将清空记录）：
- **取消**：不做任何改动（no-op）。
- **确认**：执行一次**原子**操作（全有或全无），内容为：
  1. 删除全部训练记录 `training_records` 及其 FK 子行 `trade_operations`、`drawings`（无 `ON DELETE CASCADE`，须显式先删子行）。
  2. 清空未完成的对局：删除 `pending_training`（`DELETE FROM pending_training WHERE id = 1`，即现有 `clearPending` 语义）。
  3. 将 `settings.total_capital` 写为 **100,000**。
  4. 同步内存 `SettingsStore.settings.totalCapital = 100_000`，使 UI 立即反映。

操作完成后，因记录数归零，`startingCapital()` 走零记录分支读 `settings.totalCapital` = 100,000 → 下一局从 ¥100,000 起。

**#6 修复**：`SettingsDAOImpl.loadSettings` 对缺失 `total_capital` 键的默认值由 0 改为 **100,000**（缺键即"首次启动"信号）。使全新安装的实时设置与 `AppSettings.default`、spec 第 861 行一致。

**幂等性**：无记录 / 无 pending 时确认重置 = 删除 0 行 + 写 capital=100,000，结果一致、可重复执行。

## 5. 架构与组件

### 5.1 新增原子端口（持久化层）
原子性要求"删记录 + 删 pending + 写 capital"在**同一个 `dbQueue.write { db in … }` 事务**内（任一步抛错整体回滚）。先例：`DefaultAppDB.finalizeSession`（`DefaultAppDB.swift:96-107`）已在单事务跨 `training_records` + `pending_training`。

- 新增 `DefaultAppDB.resetAllTrainingProgress(toCapital: Double) throws`：一个 `dbQueue.write` 事务内依次调用
  - 新 `RecordRepositoryImpl.deleteAll(_ db:)`（删 `drawings`、`trade_operations`、`training_records` 全部行，子表先删）；
  - 既有 `PendingTrainingRepositoryImpl.clearPending(_ db:)`；
  - 新 `SettingsDAOImpl.setTotalCapital(_ db:, _ value:)`（参数化写 capital；供本事务与 #6/复用）。
- 经新窄端口协议暴露：`TrainingResetPort { func resetAllTrainingProgress(toCapital: Double) throws }`，`DefaultAppDB` 实现之；错误经 `PersistenceErrorMapping.translate` 归一为 `AppError`（与既有 DAO 一致）。

### 5.2 SettingsStore 编排
将编排放在 `SettingsStore`（而非 live-session 协调器），以**复用其既有 `_loadError` 写阻塞 + `pendingMutations` 串行化机制**，且 SettingsPanel 已持有 SettingsStore（免改 AppRootView 注入链）。

- 注入 `TrainingResetPort`（生产即 `DefaultAppDB`，它已作为 `settingsDAO` 注入 SettingsStore，可同体担当）。
- 新增 `SettingsStore.resetAllProgress() async throws`：沿用 `resetCapital` 的 task-chain 模式（`_loadError` 拦写、串入 `pendingMutations`、`Task.detached` 跑阻塞 DB 调用），调用 `port.resetAllTrainingProgress(toCapital: 100_000)`，成功后置内存 `settings.totalCapital = 100_000`。
- **移除被本次改动孤立的旧 `resetCapital` 生产路径**：`resetCapital` 仅 SettingsPanel 一处生产调用（`SettingsPanel.swift:95`）+ 测试引用。改用 `resetAllProgress` 后旧 `resetCapital`（SettingsStore + SettingsDAO + DefaultAppDB + SettingsDAOImpl 链）成为生产孤儿。按 surgical 原则清除本次改动造成的孤儿（其"写 capital"能力由 `setTotalCapital` 取代）。*（writing-plans 阶段确认无其它引用后删除；若删除面过大有风险，退化为保留 DAO 层 `setTotalCapital` 并删 store 层 `resetCapital`。）*

### 5.3 SettingsPanel（UI）
- 按钮保留（`SettingsPanel.swift:60`）。确认对话框文案（`:92-97`）改为如实披露：标题/正文含"将清空所有训练记录，并将资金恢复为 ¥100,000"。
- 确认动作改调 `settings.resetAllProgress()`。**不再 `try?` 静默吞错**：失败时至少不假装成功（最小化：保留可见错误态 / 或交由 SettingsStore 暴露 `lastError`，与既有 `lastAutosaveError` 风格一致——具体 surfacing 由 plan 定，本设计要求"不静默吞破坏性失败"）。

### 5.4 涉及文件清单（预估，plan 细化）
- 生产：`SettingsDAOImpl.swift`（setTotalCapital + #6 默认 100k）、`RecordRepositoryImpl.swift`（deleteAll）、`RecordRepository.swift`（协议 deleteAll）、`DefaultAppDB.swift`（resetAllTrainingProgress + 端口实现）、新端口协议文件 `TrainingResetPort.swift`、`SettingsStore.swift`（resetAllProgress + 注入端口 + 删孤儿 resetCapital）、`SettingsPanel.swift`（文案 + 调用 + 不吞错）、可能 `AppState.swift`（抽 `defaultTotalCapital` 常量去重）。
- 测试镜像：In-memory fakes（`InMemoryFakes.swift` 的 settings/record/pending + 新端口 fake）。
- spec 修订：`kline_trainer_plan_v1.5.md`（§6.4 第 1025 行）。

### 5.5 去除魔法数
`100_000` 当前散落 `AppSettings.default` / `resetCapital`(应为) / DAO 默认 三处。抽 `AppSettings.defaultTotalCapital: Double = 100_000` 单一来源，三处引用之（本次改动恰好同时碰这三处，DRY 正当）。

## 6. 数据与一致性

- **原子性**：单 `dbQueue.write` 事务，GRDB 在闭包抛错时整体回滚（`DefaultAppDB.swift:94-95` 文档化语义）。不存在"记录删了但 capital 没写"的中间态。
- **外键**：`PRAGMA foreign_keys = ON`（`DefaultAppDB.swift:32-33`）；`trade_operations` / `drawings` 引用 `training_records(id)` 且**无 CASCADE**，故事务内删除顺序必须 子行（drawings、trade_operations）→ 父行（training_records）。
- **无迁移**：纯数据操作，schema 不变；`user_version` 维持 2（`AppDBMigrationsTests.swift:50` 断言不变）；`CONTRACT_VERSION` 维持 "1.6"。

## 7. 错误处理

- 全部经 `AppError`（`SettingsStore.resetAllProgress`、端口、DAO 链一致归一）。
- `_loadError` 存在时拦截重置（沿用 `resetCapital` 的 `if let e = _loadError { throw e }`）。
- 事务失败 → 抛 `AppError`、数据保持原样、UI 呈现失败（不静默吞）。

## 8. 边界情况

- **无记录 / 无 pending**：幂等，仅确保 capital=100k。
- **活动训练会话中触发**：`重置资金` 仅 Settings 面板可达，Settings 经 Home 路由进入——**前置条件：进入 Settings 时无活动训练会话**（无 live engine / 无 in-flight autosave）。因此事务直接清持久化 `pending_training` 行即可，无需 live-session 的 `discardSession` fence/drain。本设计明确不支持"训练进行中从设置重置"（该场景不可达）。
- **重置后再开局**：零记录 → `startingCapital()` 读 settings = 100k。✓
- **全新安装**：缺键默认 100k（#6）→ 顶栏 100k、可交易。✓
- **并发设置写**：串入 `pendingMutations`，与其它设置变更顺序化。

## 9. 冻结 spec 修订（§6.4）

`kline_trainer_plan_v1.5.md` 第 1025 行，现：

```
| **重置资金** 按钮 | 弹出二次确认，确认后将总资金重置为 10 万元（不清空训练记录） |
```

改为：

```
| **重置资金** 按钮 | 弹出二次确认（提示将清空训练记录）；确认后在单一事务内原子性地：清空全部训练记录与未完成的对局，并将总资金重置为 10 万元。取消则不做任何改动。 |
```

载荷编辑 = 反转"（不清空训练记录）"。第 861 行"总资金：初始 10 万，每局正式结束后累加盈亏"保持不变（与 #6 修复后行为一致），如需可加注"（重置资金清空记录并回到初始 10 万）"。

## 10. 测试策略（TDD，先红后绿）

**持久化层（`KlineTrainerPersistenceTests`）**
- `resetAllTrainingProgress`：插入若干记录(含 ops/drawings) + pending 行 + 旧 capital → 重置 → 三表记录归零、capital==100000、`user_version`仍 2。
- 原子回滚：注入一步失败 → 断言数据全保持原样（无部分删除）。
- `deleteAll` 删父删子（无 FK 残留）。
- #6：fresh DB `loadSettings().totalCapital == 100000`（更新 `DefaultSettingsDAOTests.swift:21` 旧断言 0）。
- 更新 `DefaultSettingsDAOTests` case 4/5（原锁定 reset→0 / fresh→0）。

**契约层（`KlineTrainerContractsTests`）**
- `SettingsStore.resetAllProgress`：内存 totalCapital==100000 + 调用端口 + 失败传播 AppError + `_loadError` 拦截（更新 `SettingsStoreProductionTests.swift:101`）。
- `startingCapital` 重置后 == 100000（新增；该私有方法目前零覆盖，经协调器公开路径验证）。
- 端口 in-memory fake 行为镜像真实事务。

**UI**：SettingsPanel 确认文案含"清空训练记录"字样（host / Catalyst 渲染层）。

**回归**：host `swift test` 全绿 + Mac Catalyst `build-for-testing` SUCCEEDED + iOS app build。

## 11. 治理与范围

- **信任边界**：本次不动 `.github/workflows/**`、不动 `codeowners_required_globs`、不动 ruleset → **非信任边界变更**，无需额外 user Approve（除常规评审）。
- **M0.4**：新增 DAO/store 方法经 `PersistenceErrorMapping` 归一 `AppError`，符合 M0.4 精神；现有 P1/P2/P5 gate 脚本不覆盖 DAO 文件（无 CI 接线），本次不新增 gate。
- **评审通道**：用户 explicit 指定 **Opus 4.8 xhigh 对抗性 review**（plan-stage + branch-diff 双闸门，跑到收敛），代 codex（本项目既有 fallback 惯例）。
- **spec 修订**：修改冻结 `kline_trainer_plan_v1.5.md` §6.4 经本 RFC 治理（与 PR #64/#94 等 spec 修订同流程）；不触碰 `wave0-frozen-*` tag 命名空间或 required Catalyst check。

## 12. 验收（非编码者可执行，plan 阶段细化为完整清单）
- 范围 gate（白名单文件）。
- 持久化 + 契约层新测试红→绿（含原子回滚、#6 默认、reset→100k）。
- host 全量 + Catalyst + app build 零回归。
- 模拟器 runbook：① 训练几局产生记录 → 设置点「重置资金」→ 确认 → 首页历史清空、再开局顶栏 ¥100,000；② 全新安装（删 app 重装）→ 直接开局顶栏 ¥100,000（非 ¥0）；③ 点「重置资金」选取消 → 记录与资金不变。
- Opus 4.8 xhigh 对抗性 review APPROVE 落账。
