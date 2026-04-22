# M0.1 Schema Versioning Contract（contract，frozen by Plan 1f）

> **Status**：frozen 2026-04-22（Plan 1f PR）。
>
> **权威来源**（spec `kline_trainer_modules_v1.4.md`）：
> - 主体条款：L133-157（v1.3 新增 / v1.4 拆分 bump 策略）
> - Bump 策略二分：L137-138 + L287-293（DAO reader 未知 state 处理）
> - 历史决议：L2407（R4-codex modify，缩小"journal state 增删均 bump 顶层"的适用范围）
> - Wave 0 交付验收项：L2097
> - CI assert 要求（未实施 / 登记未来强制点）：L2232
>
> 任何修改本文档需走 spec 更新 → 本文档同步 → codex:adversarial-review → CODEOWNERS approve（`.claude/workflow-rules.json` `trust_boundary_globs` + `codeowners_required_globs`）。

## 用途

本文件是 M0.1 schema 版本管理规则在 repo 内的**权威落地锚点**。

- spec `kline_trainer_modules_v1.4.md` §M0.1 是规范文本来源
- 本文件是 **Plan 2 B3**（PostgreSQL migration 实施者）/ **Plan 3 P4**（app.sqlite GRDB migration 实施者）/ **Plan 3 P3a**（训练组 SQLite reader 工厂）的强制引用对象
- 任何涉及 DDL 变更 / migration 文件新增 / CONTRACT_VERSION bump 的 PR 必须在描述里点名引用本文件相应章节
- 与 `docs/governance/m04-apperror-translation-gate.md`（M0.4 错误翻译 stub）形成 governance doc 体系：m04 管错误传播边界，m01 管 schema 版本边界

## CONTRACT_VERSION 矩阵

三套存储 + Swift 模型 + P2 journal states 共 5 个子版本维度，顶层 `CONTRACT_VERSION` 作总标识：

| 维度 | 当前版本 | 变更触发 bump 的条件 |
|---|---|---|
| `CONTRACT_VERSION`（顶层标识） | `"1.4"` | 跨系统或破坏性持久化变更 bump 联动；P2 本地 journal state 的**兼容新增**不联动 |
| PostgreSQL schema（`schema.sql` migration id） | `0003_v1.3` | 任何 PostgreSQL DDL 变更（含加列）；联动顶层 |
| 训练组 SQLite `PRAGMA user_version` | `1` | 训练组 schema 结构变更；联动顶层 |
| app.sqlite GRDB migration | `0003_v1.4_purge_leased` | app.sqlite DDL / 新表 / **DML 数据清理 migration**（v1.4 新增：删除 v1.3 残留 `state='leased'` journal 行）；联动顶层 |
| Swift 模型版本（`M0.3`） | `1.3` | Codable 字段 / 枚举 case 变更；联动顶层 |
| `P2 journal states` enum | `v2` | 删除 / 改 raw value / 改既有语义 / 改恢复扫描集 → bump 顶层；仅追加本地中间态 → 只 bump 本子版本，reader 须显式处理未知 state |

**存储表位 速查**（spec L129-131）：

| 存储 | 位置 | Schema 文件 |
|---|---|---|
| PostgreSQL | NAS（`backend/sql/schema.sql`） | `backend/sql/schema.sql` |
| 训练组 SQLite | 各 `.zip` 内部 | `backend/sql/training_set_schema_v1.sql` |
| app.sqlite | iOS 沙盒（GRDB 管理） | `ios/sql/app_schema_v1.sql` |

## Bump 策略（破坏性 vs 本地兼容）

Bump 策略**分两类**（spec v1.4 修订，L137-138）：

### A. 必须 bump 顶层 `CONTRACT_VERSION`（破坏性 / 跨系统变更）

触发条件（满足任一即必须联动 bump）：
- 删 state / 改 raw value / 改既有语义
- 改恢复扫描集（`retryPendingConfirmations` 扫的 state 集合变更）
- 影响 DDL（新增 / 删除列、改类型、改约束等任何 PostgreSQL / app.sqlite / 训练组 SQLite schema 变更）
- 改 OpenAPI（REST API 契约变更）
- 任何跨系统契约字段调整

### B. 只 bump 子版本，不联动顶层（本地兼容新增）

触发条件（**全部**满足才适用）：
- 仅追加本地中间态（P2 journal 等）
- raw value 追加
- 既有 state 语义不变
- DDL 不变
- 不改恢复扫描集
- 不跨 REST 传输

**前提条件**（否则不适用本条例外）：
- DAO / reader 对未知 state 显式处理（fail-closed 或忽略策略文档化）

### DAO reader 对未知 state 的处理（与 B 类 bump 策略配套，spec L287-293）

- `AcceptanceJournalDAO.listByState(_:)` / `listScanTargets()` 读取时若遇到**当前 enum 未定义**的 raw value（跨版本向前读 / 回滚后读新版本写入的行等），采用"**fail-safe 忽略**"策略：
  - 记 warning 日志（状态名、training_set_id、lease_id）
  - 该行**不进入任何恢复扫描集**（不重试 confirm、不清理本地文件）
  - 留待用户手动运维或下次版本 migration 处理
- Swift 实现提示：`P2JournalState.init(rawValue:)` 返回 `nil` 时 DAO 将该行映射为内部 `UnknownJournalRow` 类型（不对外暴露到 `AcceptanceJournalRow.state`），`listBy*` API 过滤掉该类行

## Migration Rollback 规则

三套存储的 rollback owner + 规则（spec L151-157）：

| 范围 | 规则 | Owner |
|---|---|---|
| PostgreSQL `schema.sql` | 每个 migration 提供 `forward.sql` + `rollback.sql` 或显式标注"不可逆（列/表删除）"——不可逆项不允许放进 Wave 1+ 的 migration | **B3** |
| app.sqlite GRDB migration | 每个 migration 写在 `DatabaseMigrator` 中；rollback 通过新增反向 migration 实现（GRDB 不原生支持 down）；删列 / 删表需新 migration id | **P4** |
| 训练组 SQLite | **不 rollback**；增字段就 bump `PRAGMA user_version`，旧 version reader 直接拒收（抛 `AppError.trainingSet(.versionMismatch)`） | **M0.1 策略 / P3a Factory 执行**（runtime 拒收） |

## 应用范围（哪个模块 PR 必须引用本文件）

| Plan | 模块 | 引用本文件 | 备注 |
|---|---|---|---|
| Plan 2 | B1 import_csv | 否 | 不新增 DDL / 不改 schema |
| Plan 2 | B2 generate_training_sets | 否 | 只读 schema；但若需改 `training_sets` 写入字段语义，触发 A 类 bump 必须引用 |
| Plan 2 | **B3 FastAPI 服务 + migration owner** | ✅ **强制** | 所有 `backend/sql/migrations/` 下 migration 文件对（forward/rollback）必须符合本契约 A/B 类 bump 规则 |
| Plan 2 | B4 调度器 | 否 | 不改 schema |
| Plan 3 | F1 Models | 否 | Swift 模型 Codable 字段由 M0.3 契约管（见 `ios/Contracts/`），但若改模型字段触发 A 类 bump 必须引用本文件 |
| Plan 3 | P2 DownloadAcceptanceRunner | ✅（间接） | P2 journal states enum 的 bump 策略由本文件规定；journal DAO 未知 state 处理规则由本文件规定 |
| Plan 3 | **P3a TrainingSetDBFactory** | ✅ **强制** | 训练组 SQLite reader 工厂：打开 `.zip` 后 `PRAGMA user_version` 校验 + 版本不匹配抛 `AppError.trainingSet(.versionMismatch)` |
| Plan 3 | P3b TrainingSetReader | 否 | 只读，版本检查由 P3a Factory 在打开时完成 |
| Plan 3 | **P4 AppDB** | ✅ **强制** | GRDB `DatabaseMigrator` 注册所有 migration；`0003_v1.4_purge_leased` 按本文件要求在启动时强制执行；含 `AcceptanceJournalDAO`（见 m04 gate stub + 未来 Plan 1g M0.5 Sendable 要求） |
| Plan 3 | P5 CacheManager | 否 | 无 schema |
| Plan 3 | P6 SettingsStore | 否 | 无 schema |

## 未来强制点（Plan 1f 不实施，登记 backlog）

以下增量在 Plan 1f scope **之外**，但作为 spec 长期 governance 目标登记：

- [ ] **CI assert：`CONTRACT_VERSION` 常量与本文件矩阵同步**（spec L2232，v1.3 要求）：需先等 Plan 2 B3 在 Python 侧定义 `CONTRACT_VERSION = "1.4"` 常量（或 `kline_trainer/version.py`）且 Plan 3 F1 / P4 在 Swift 侧定义对应常量，随后开一个轻量 CI workflow grep 本文件当前 `"1.4"` 字串 vs 两侧常量。**落地形态待 Plan 2 B3 + Plan 3 F1 完成后另议**。
- [ ] **具体 migration SQL 文件落地**：spec L161-231 描述的 `content_hash` 两阶段 migration（`0003_v1.3_part1/forward.sql` + `.../rollback.sql` + `part2/forward.sql` + `.../rollback.sql`）由 Plan 2 B3 首次 migration PR 落地；本文件作为 migration 文件命名规范 / rollback 格式的**引用对象**。
- [ ] **`download_acceptance_journal` 表 migration**：spec L233-263 描述的 `0002_v1.3_journal/forward.sql` + `.../rollback.sql` 同上，由 Plan 2 B3 落地。
- [ ] **`0003_v1.4_purge_leased` app.sqlite GRDB migration 注册**（spec L268-281）由 Plan 3 P4 落地。
- [ ] **跨语言 `CONTRACT_VERSION` 常量同步 lint**：当 Plan 2 Python 常量 + Plan 3 Swift 常量都存在时，可在 PR CI 中加 string-equality lint；本 backlog 项延后到两侧都落地。

## 交叉引用

- **spec 源**：`kline_trainer_modules_v1.4.md` §M0.1 数据库 Schema 契约（L125-293，其中 L133-157 / L287-293 / L2097 / L2232 为本文件冻结主体）
- **姊妹 governance doc**：`docs/governance/m04-apperror-translation-gate.md`（M0.4 错误翻译 stub，由 Plan 3 P1 闭合）
- **Plan 1e aborted 教训**：`kline_trainer_modules_v1.4.md` §M0.5 相关 concurrency 合并冻结归独立 Plan 1g
- **治理 PR 工作流**：`.claude/workflow-rules.json`（`trust_boundary_globs` + `codeowners_required_globs`）
