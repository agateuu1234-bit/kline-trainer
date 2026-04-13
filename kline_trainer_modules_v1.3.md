# Kline Trainer 模块拆分方案

**版本：v1.3**
**基于实施方案：v1.5**
**更新日期：2026-04-13**

**演进路径**：v1.0 → v1.1（第 1 轮 Codex 评审 + Cloud 反评审，21 项修订）→ v1.2（第 2 轮评审 + 反评审，新增 16 项）→ **v1.3（第 3 轮 codex 对抗性评审 + Claude 反挑战，3 轮辩论收敛 17 项修订）**。累计 **54 项**修订，详见 §十四 评审痕迹。

**v1.2 → v1.3 核心增量**：
1. **（P0×5）**：C1 reducer 加 `revision: UInt64` 单调版本检测（解面板跨 tick 快照漂移）；E5 拆 L2（新增 E6 `TrainingSessionCoordinator`）；`content_hash` PostgreSQL 列改 `CHAR(8) NOT NULL` CRC32 + 迁移；新增 `download_acceptance_journal` 表（P4 提供 DAO）；P3 拆 `TrainingSetDBFactory` + `TrainingSetReader`
2. **（P1×6）**：`commissionRate` 小数率单位闭合（P6 边界乘除 10000）；新增 `DrawdownAccumulator` + `PendingTraining` 增 `cashBalance/drawdown`；U1 接口改依赖 `TrainingSessionCoordinator`；`TrainingEnginePreviewFactory` 前移 Wave 0；副图值域改 `NonDegenerateRange`；`TradeOperation.positionTier: String` → `PositionTier`
3. **（细拆）**：P4 对外 3 public protocol（`RecordRepository` / `PendingTrainingRepository` / `SettingsDAO`）+ `typealias AppDB`；P2 顶层 runner + 4 内部端口（`ZipIntegrityVerifying` / `ZipExtracting` / `TrainingSetDataVerifying` / `DownloadAcceptanceCleaning`）；C1 拆 3 件（`ChartGeometryState` / `ChartReducer` / `KLineRenderState`）
4. **（契约补齐）**：M0.1 新增 `CONTRACT_VERSION` 矩阵；DB migration rollback owner（M0.1 定策略，B3 PostgreSQL，P4 app.sqlite，训练组 SQLite 不 rollback）；Sendable 清单（M0.3 DTO / AppError Reason / 跨 actor 协议返回值）；Fixture / Mock ports 清单（Coordinator / Verifier / Repository fake）
5. **（总览）**：顶层模块 31 → 35（E 组 +1：E6；P 组 +2：P3 拆 2；C 组 +2：C1 拆 3）

**v1.1 → v1.2 核心增量**（保留）：
1. **（P0×4）**：M0.1 扩 `training_sets` 3 列 + `training_records` 1 列；C1 拆非递归 `FrozenPanelState` + 全家补 `Equatable`；所有 Reason 枚举 `: Error`；修 `Result` 类型约束
2. **（P1×5）**：M0.4 翻译表职责重写（本模块边界内转 AppError）；reducer 补全 3×7 完整矩阵；Wave 0 交付 C1 完整实现而非切片；P4 统一 `DatabaseQueue`；MockTrainingEngine 改 Preview Fixture 模式
3. **（P2×7）**：IndicatorMapper 值域外置至 KLineRenderState；主方向补单指判定；`AppError.unknown` → `internalError(module, detail)`；`content_hash` 改用 zip CRC32；NormalFlow.fees 打包时机明确；scenePhase 责任链统一；§十四 重做为 37 行可核对表
4. **工程实操补遗**：新增 §十五 Wave 0 执行前的准备（编译验证 / 依赖锁定 / 评审策略 / 签字流程）

---

## 零、拆分原则

1. **契约先行**：模块之间用"数据结构 + 接口"连接，不共享内部状态。
2. **纯函数优先**：能做成纯函数/值类型的，不做 class；能不依赖 UIKit 的，不拉 UIKit。
3. **可并行开发**：任意两个模块若不在同一条依赖链上，就应该能由两个人同时开发。
4. **可独立验收**：每个模块都能用 Mock/Fixture 依赖单元测试，不依赖上游真实实现。
5. **单一职责**：拆分最小单位是"一个能被单独替换的技术决策"。
6. **不过拆**：仅 5~50 行的胶水代码、无独立复用场景的，不单独成模块。
7. **契约冻结后不得静默变更**：任何契约字段改动必须 bump 契约版本号并走 RFC。
8. **类型可编译**（v1.2 新增）：所有契约层代码片段必须在脑内/Playground 里过一遍编译（递归值类型、`Result<_, Error>` 约束、`Equatable` 合成等），禁止只做语义审查。

---

## 一、模块总览（35 个顶层模块 + 8 个内部可替换端口，6 大类；v1.3 拆分）

| 组 | 代号 | 顶层模块数 | 语言 | 说明 |
|---|---|---|---|---|
| 契约层 | **M0** | 5 | 多语言 | DB/REST/Swift 模型/错误处理/并发约定（+ CONTRACT_VERSION 矩阵 + migration rollback 规则 + Sendable 清单） |
| 后端 | **B** | 4 | Python | 导入、生成、服务、调度（B3 owner PostgreSQL migration rollback）|
| iOS 基础 | **F** | 2 | Swift | 数据模型、主题 |
| iOS 图表引擎 | **C** | **10**（v1.3：C1 拆 3）| Swift/UIKit | C1a `ChartGeometryState` / C1b `ChartReducer` / C1c `KLineRenderState`；C2-C8 不变 |
| iOS 业务逻辑 | **E** | **6**（v1.3：E5 拆 2）| Swift | 时间、持仓、费用、流控、引擎运行时、**会话编排 E6**（新增）|
| iOS 持久化 | **P** | **8**（v1.3：P3 拆 2；P4 对外 3 接口）| Swift | P1 APIClient；**P2 Runner + 4 内部端口**；**P3a Factory + P3b Reader**；**P4 RecordRepo + PendingRepo + SettingsDAO + typealias AppDB**；P5 Cache；P6 SettingsStore |
| iOS UI | **U** | 6 | SwiftUI | 首页（依赖 E6 Coordinator）、训练页、弹窗、HUD |

**v1.3 说明**：
- 原 31 顶层 → 现 35 顶层（+4：E6 + P3a/P3b + C1 拆 3 - 原 C1 原 E5 原 P3）
- P4 对外 3 public protocol 但共享单 `DatabaseQueue`；composition root 用 `typealias AppDB = RecordRepository & PendingTrainingRepository & SettingsDAO`
- P2 顶层仍单一 `DownloadAcceptanceRunner`，内部 4 个 public protocol 用于 Mock / 替换
- 可替换端口总计：~36（v1.2）→ ~44（v1.3）

---

## 二、依赖关系图

```
                          ┌──────────────────────┐
                          │   M0 共享契约层       │
                          │ DB/REST/Swift/Err/   │
                          │ Concurrency/         │
                          │ CONTRACT_VERSION/    │
                          │ Rollback/Sendable    │
                          └──────────┬───────────┘
                                     │
           ┌─────────────────────────┼─────────────────────────┐
           ▼                         ▼                         ▼
   ┌──────────────┐          ┌──────────────┐          ┌──────────────┐
   │  后端 B1-B4   │          │ F1 数据模型   │          │ F2 主题      │
   │  (B4→B2 函数 │          └──────┬───────┘          └──────┬───────┘
   │   式调用)     │                 │                         │
   └──────────────┘                  │                         │
              ┌─────────────────────┼──────────────┐          │
              ▼                     ▼              ▼          │
       ┌─────────────┐      ┌──────────────┐ ┌─────────────────────┐  │
       │ C1a Geometry │      │ E1 Tick      │ │ P1 APIClient         │  │
       │ C1b Reducer  │      │ E2 Position  │ │ P3a DBFactory        │  │
       │ C1c RenderS  │      │ E3 TradeCalc │ │ P3b Reader           │  │
       │ C2 Animator  │      │ E4 FlowCtrl  │ │ P4: RecordRepo /     │  │
       │ C7 Gesture   │      └──────┬───────┘ │     PendingRepo /    │  │
       └──────┬──────┘             │         │     SettingsDAO      │  │
              │                    │         │     (typealias AppDB) │  │
              ▼                    │         │ P5 Cache / P6 Setting │  │
       ┌──────────────┐            │         └──────────┬───────────┘  │
       │ C3/C4/C5/C6  │            │                    │              │
       │  渲染层       │            │ P2 Runner + 4 内部端口            │
       └──────┬───────┘            │ (ZipIntegrity / ZipExtract /      │
              ▼                    │  DataVerify / Cleaning)           │
       ┌──────────────┐            ▼                                   │
       │ C8 Container │    ┌───────────────────────┐                   │
       │ (纯桥接)     │    │ E5 TrainingEngine     │                   │
       └──────┬───────┘    │ E6 SessionCoordinator │                   │
              │            └──────────┬────────────┘                   │
              └────────┬──────────────┘                                │
                       ▼                                               │
              ┌───────────────────────────────────────────┐             │
              │ U1 Home (依赖 E6) / U2 Training           │◀────────────┘
              │ U3 Settle / U4 Settings                   │
              │ U5 Picker / U6 History                    │
              └───────────────────────────────────────────┘
```

> **v1.3 说明**：
> - C1 拆为 `ChartGeometryState` (C1a) / `ChartReducer` (C1b) / `KLineRenderState` (C1c) 三顶层；
> - E5 拆为 `TrainingEngine` (运行时) + `TrainingSessionCoordinator` (E6，session 生命周期编排 P3/P4/P5)；
> - P3 拆 `TrainingSetDBFactory` (P3a) + `TrainingSetReader` (P3b)，每训练组文件独立 `DatabaseQueue`；
> - P4 对外 3 个 public protocol + `typealias AppDB` 作 composition root；
> - P2 顶层仍为 `DownloadAcceptanceRunner`，内部暴露 4 个 public protocol 供测试/替换；
> - **依赖方向新增**：U1 → E6 → (P3a 创建 P3b reader / P4 三 Repo / P5) → reader/Repo 下游；P2 runner 编排 P1 / P3a / P5 / 4 内部端口。
> - scenePhase 责任链不变（`U2 监听 → E5.onSceneActivated() → C2.resetOnSceneActive()`，C8 不兼任 scene 生命周期）。

---

## 三、契约层（Wave 0，所有模块开工前必须冻结）

### M0.1 数据库 Schema 契约

| 存储 | 位置 | Schema 文件 | 变更策略 |
|---|---|---|---|
| PostgreSQL | NAS | `backend/sql/schema.sql` | 加列只追加，改字段需 migration；migration/rollback 文件由 B3 owner |
| 训练组 SQLite | 各 `.zip` 内部 | `backend/sql/training_set_schema_v1.sql` | `PRAGMA user_version` 作版本号；**不支持 rollback**，用 `schema_version` 直接拒收旧文件 |
| app.sqlite | iOS 沙盒 | `ios/sql/app_schema_v1.sql` | GRDB migration 管理；migration/rollback 由 P4 owner |

#### CONTRACT_VERSION 矩阵（v1.3 新增）

任何契约字段 / API schema / 存储 schema / journal state 变更必须 bump 对应版本号并走 RFC（§零原则 7）。v1.3 矩阵如下：

| 维度 | 当前版本 | 变更触发 bump 的条件 |
|---|---|---|
| `CONTRACT_VERSION`（顶层标识） | `"1.3"` | 任一维度 bump 即同步 |
| PostgreSQL schema（`schema.sql` migration id） | `0003_v1.3` | 任何 PostgreSQL DDL 变更（含加列） |
| 训练组 SQLite `PRAGMA user_version` | `1` | 训练组 schema 结构变更 |
| app.sqlite GRDB migration | `0002_v1.3_journal` | app.sqlite DDL / 新表 |
| Swift 模型版本（`M0.3`） | `1.3` | Codable 字段 / 枚举 case 变更 |
| `P2 journal states` enum | `v1` | journal state 枚举增删（即便 raw value 兼容也要 bump 以便 reader 显式校验）|

#### Migration Rollback 规则（v1.3 新增）

| 范围 | 规则 | Owner |
|---|---|---|
| PostgreSQL `schema.sql` | 每个 migration 提供 `forward.sql` + `rollback.sql` 或显式标注"不可逆（列/表删除）"——不可逆项不允许放进 Wave 1+ 的 migration | B3 |
| app.sqlite GRDB migration | 每个 migration 写在 `DatabaseMigrator` 中；rollback 通过新增反向 migration 实现（GRDB 不原生支持 down）；删列 / 删表需新 migration id | P4 |
| 训练组 SQLite | **不 rollback**；增字段就 bump `PRAGMA user_version`，旧 version reader 直接拒收（抛 `AppError.trainingSet(.versionMismatch)`） | M0.1 策略 / P3a Factory 执行 |

**v1.5 契约继承 + v1.2 扩充 + v1.3 新增**：

#### PostgreSQL `content_hash` 列类型迁移（v1.3 新增）

v1.2 已把算法从 `sha256(sqlite_bytes)` 改为 `zlib.crc32(zip_bytes)`，但 `training_sets.content_hash` 列仍是 `VARCHAR(64)`，长度不再匹配。v1.3 迁移：

**两阶段 migration**（v1.3 修订：闸门 #1 F1 修复——避免 `SET NOT NULL` 校验阶段撞到被置 NULL 的遗留行）：

```sql
-- v1.3 migration 0003_v1.3_part1/forward.sql
-- 第 1 阶段：收紧列类型但保持可空；保留 8 字符 CRC32（小写十六进制）有效行，其它置 NULL 等 B2 backfill
-- 先 DROP NOT NULL（若存在），避免 TYPE 改写时校验
ALTER TABLE training_sets ALTER COLUMN content_hash DROP NOT NULL;

-- 用 CASE 表达式只替换非合法行，保留已合法的 8 字符小写十六进制 CRC32
ALTER TABLE training_sets
  ALTER COLUMN content_hash TYPE CHAR(8)
  USING CASE
          WHEN content_hash ~ '^[0-9a-f]{8}$'
            THEN content_hash::char(8)
          WHEN content_hash ~ '^[0-9A-Fa-f]{8}$'
            THEN lower(content_hash)::char(8)
          ELSE NULL
        END;

-- 只对被置 NULL 的遗留行（原 sha256 或其它非 CRC32 形态）重置 status / lease
UPDATE training_sets
   SET status = 'unsent',
       lease_id = NULL,
       lease_expires_at = NULL,
       reserved_at = NULL
 WHERE content_hash IS NULL;

COMMENT ON COLUMN training_sets.content_hash
  IS 'zip 文件 CRC32 十六进制（8 字符，小写），由 B2 生成、P2 校验；v1.3 两阶段 migration 第 1 阶段后可空，B2 backfill 完成后第 2 阶段加 NOT NULL';
```

```sql
-- v1.3 migration 0003_v1.3_part1/rollback.sql
ALTER TABLE training_sets ALTER COLUMN content_hash TYPE VARCHAR(64);
-- 不恢复旧 sha256 数据（已作废行由 B4 重新生成）
```

```sql
-- v1.3 migration 0003_v1.3_part2/forward.sql
-- 第 2 阶段：B2 backfill 完成后再加 NOT NULL；B3 在部署脚本中校验没有 content_hash IS NULL 行后才执行本阶段
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM training_sets WHERE content_hash IS NULL) THEN
    RAISE EXCEPTION 'content_hash backfill incomplete; run B2 generate_batch first';
  END IF;
END$$;
ALTER TABLE training_sets ALTER COLUMN content_hash SET NOT NULL;
```

```sql
-- v1.3 migration 0003_v1.3_part2/rollback.sql
ALTER TABLE training_sets ALTER COLUMN content_hash DROP NOT NULL;
```

**B2 回迁策略**：B2 `generate_one_training_set` 在 part1 部署完成后首次运行时，识别 `status='unsent' AND content_hash IS NULL` 行（即 migration 作废的遗留 sha256 行），按新 CRC32 格式重新计算并回写；全部补齐后 B3 部署 part2 加 NOT NULL。

**验收步骤**（含 codex 建议的 migration 测试，v1.3 闸门 #2 修订）：
1. 准备混合数据：1 条 `content_hash = 'deadbeef'`（合法 8 字符 CRC32）+ 1 条 `content_hash = LPAD('a', 64, 'a')`（遗留 sha256）+ 1 条 `content_hash = 'BADC0DE1'`（大写 8 字符，应被 lower 保留）
2. 部署 part1 → 验证：
   - 合法 `'deadbeef'` 行：`content_hash = 'deadbeef'`（保留）、`status` 不变
   - 大写 `'BADC0DE1'` 行：`content_hash = 'badc0de1'`（转小写保留）、`status` 不变
   - 遗留 64 字符行：`content_hash IS NULL AND status = 'unsent'`
3. 运行 B4 调度器 → 验证 B2 重新生成遗留行的 content_hash（8 字符 CRC32 小写）
4. 部署 part2 → 断言成功；若仍有 NULL 行，part2 RAISE EXCEPTION 阻塞

#### app.sqlite `download_acceptance_journal` 表（v1.3 新增）

解决 P0-4：confirm 网络不确定错误导致本地文件被误清。journal 属 P2 业务语义，落 app.sqlite 由 P4 提供 DAO（而非独立文件——避免 cache 文件与 app 状态双写一致性问题）。

```sql
-- v1.3 migration 0002_v1.3_journal/forward.sql
CREATE TABLE download_acceptance_journal (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    training_set_id INTEGER NOT NULL,
    lease_id TEXT NOT NULL,
    state TEXT NOT NULL,                  -- 见下方 JournalState enum
    state_entered_at INTEGER NOT NULL,    -- Unix 秒 UTC
    last_error TEXT,                      -- AppError.userMessage
    sqlite_local_path TEXT,               -- 已 stored 时填充
    content_hash CHAR(8),                 -- 已校验时填充（供 confirm 重试核对）
    UNIQUE (training_set_id, lease_id)
);
CREATE INDEX idx_journal_state ON download_acceptance_journal(state);
```

**JournalState enum**（由 P2 定义、P4 DAO 反序列化）：

```
leased          -- lease 已从 GET /meta 取得；尚未开始下载
downloaded      -- zip 下载完成；尚未 CRC
crcOK           -- CRC32 校验通过
unzipped        -- 解压完成
dbVerified      -- P3a factory openAndVerify 通过（schema + meta 非空）
stored          -- P5 CacheManager.store 完成；sqlite_local_path 已落盘
confirmPending  -- confirm API 已调用但网络不确定（超时 / 连接错误）；可重试
confirmed       -- confirm 成功；本地 TrainingSetFile 可见
rejected        -- 显式失败（409/404/CRC 失败/schema mismatch 等）；sqlite_local_path 可清理
```

**幂等与崩溃恢复规则**（v1.3 闸门 #1 F3 修订）：
- App 启动时的 journal 扫描必须**同时覆盖两类 state**：`stored`（已落盘未发起 confirm）+ `confirmPending`（confirm 已发起但网络不确定）。两类都走同一 `retryPendingConfirmations` 流程：以原 `lease_id` 调用 `api.confirm`。
- `stored` → 调用 `confirm`：成功则 → `confirmed`；网络不确定 → `confirmPending`；409/404 → `rejected` 清理本地文件
- `confirmPending` → 重试 `confirm`：成功 → `confirmed`；仍网络不确定 → 停留 `confirmPending`；409/404 → `rejected` 清理本地文件
- **场景覆盖**：cache.store 完成、confirm 尚未调用时崩溃 → 启动时从 `stored` 恢复，本地 sqlite 不孤立；confirm 请求发出但响应未到达时崩溃 → 启动时从 `confirmPending` 恢复
- 只有 **409/404** 明确失败才转 `rejected` 并允许清理本地文件；其他错误停留原态

#### PostgreSQL `training_sets` 扩充（v1.2 新增）

v1.5 §3.1 的 DDL 只含 `status` 字段，无法实现 lease 机制。v1.2 扩充 3 列：

```sql
-- v1.2 新增
ALTER TABLE training_sets ADD COLUMN lease_id UUID NULL;
ALTER TABLE training_sets ADD COLUMN lease_expires_at TIMESTAMPTZ NULL;
ALTER TABLE training_sets ADD COLUMN reserved_at TIMESTAMPTZ NULL;

-- v1.2 新增索引
CREATE INDEX idx_training_sets_lease
  ON training_sets(lease_id) WHERE lease_id IS NOT NULL;
CREATE INDEX idx_training_sets_lease_expire
  ON training_sets(lease_expires_at) WHERE status = 'reserved';

-- v1.2 新增唯一约束（见 §四 B2）
ALTER TABLE training_sets
  ADD CONSTRAINT uq_stock_start UNIQUE (stock_code, start_datetime);
```

**状态机不变量**：

| 操作 | `status` | `lease_id` | `lease_expires_at` | `reserved_at` |
|---|---|---|---|---|
| 初始入库 | `unsent` | NULL | NULL | NULL |
| `GET meta` 批量预占 | `reserved` | 新 UUID | now + 10min | now |
| `POST confirm`（lease_id 匹配且未过期） | `sent` | （保留，供幂等） | （保留） | （保留） |
| `confirm`（lease 不匹配或过期） | 不变 | 不变 | 不变 | 不变（后端返 409） |
| 调度器回滚 | `unsent` | NULL | NULL | NULL |

#### app.sqlite `training_records` 扩充（v1.2 新增）

v1.5 §3.3 的 DDL 无法存储 Review 模式所需的 finalTick。v1.2 扩充：

```sql
-- v1.2 新增
ALTER TABLE training_records ADD COLUMN final_tick INTEGER NOT NULL DEFAULT 0;
```

`final_tick` 语义：训练局结束时的 `globalTickIndex`。自动结束 = maxTick；手动结束 = 用户点击结束时的值。**Review 模式启动以此作为 `initialTick`**。

#### 其他（保持 v1.5）

训练组 SQLite schema（见 v1.5 §3.2）、app.sqlite 其他表（`trade_operations / drawings / pending_training / settings`，见 v1.5 §3.3）保持。

**v1.5 内部矛盾修正**（继承自 v1.1）：
- `settings` 表 key 清单**删除** `stamp_duty_enabled`（v1.5 §4.2"印花税始终生效"）

### M0.2 REST API 契约

**冻结产物**：`backend/openapi.yaml` 完整 OpenAPI 3.0 文档。

```
GET  /training-sets/meta?count=N                     → 200 LeaseResponse
GET  /training-set/{id}/download                     → 200 application/zip
                                                        （Content-MD5 头携带 zip MD5，供客户端二次校验）
POST /training-set/{id}/confirm?lease_id={lease_id}  → 200 { ok: true }
                                                     → 409 { error: "lease_expired" }
                                                     → 404 { error: "not_found" }
```

**v1.2 修正：`content_hash` 改为 zip CRC32**

v1.1 的 `content_hash = sha256(unzipped_sqlite_bytes)` 依赖 SQLite 字节确定性（页分配、临时元数据），跨平台/跨版本不保证。v1.2 改为：

- **`content_hash` 字段 = zip 文件的 CRC32 十六进制**（每个 zip 文件格式本身携带）
- 客户端下载后直接对 zip 字节流算 CRC32，与 `content_hash` 比对
- 解压后不再依赖 sqlite 字节 hash
- 跨平台健壮，无需后端特殊处理

**关键契约约束**：
1. `confirm` 必带 `lease_id`，错误返回 409
2. `confirm` 幂等：同一 `(id, lease_id)` 重复调用返回 200
3. Lease TTL = 10 分钟
4. 时间戳：所有 `datetime` 字段 = **Unix 秒 UTC**

```typescript
// LeaseResponse
{
  "lease_id": string,                  // UUID v4
  "expires_at": string,                // ISO8601 UTC
  "sets": [{
    "id": number,
    "stock_code": string,
    "stock_name": string,
    "filename": string,
    "schema_version": number,
    "content_hash": string             // v1.3：CRC32 hex，精确 8 字符小写（对应 training_sets.content_hash CHAR(8) NOT NULL）
  }]
}
```

### M0.3 Swift 数据模型契约

**Sendable 约定**（v1.3 新增）：以下所有值类型（struct / enum）默认 `Sendable`；跨 actor 协议返回值（P1/P3b/P4 三 Repo 等）必须是 `Sendable` 类型；`AppError` 及全部 `Reason` 枚举 `Sendable`；闭包跨 actor 捕获引用类型需显式 `@MainActor` 或 actor-isolated，禁止跨 actor 捕获非 Sendable 引用（见 §三 M0.5）。

```swift
// —— 枚举（v1.3 全部 Sendable）——
enum Period: String, Codable, Equatable, Sendable { case m3 = "3m", m15 = "15m", m60 = "60m", daily, weekly, monthly }
enum TradeDirection: String, Codable, Equatable, Sendable { case buy, sell }
enum PositionTier: String, Codable, Equatable, Sendable { case tier1 = "1/5", tier2 = "2/5", tier3 = "3/5", tier4 = "4/5", tier5 = "5/5" }
enum TrainingMode: Equatable, Sendable { case normal, review, replay }
enum DrawingToolType: String, Codable, Equatable, Sendable { case ray, trend, horizontal, golden, wave, cycle, time }
enum DisplayMode: String, Codable, Equatable, Sendable { case light, dark, system }
enum PanelId: Equatable, Sendable { case upper, lower }
enum SwipeDirection: Equatable, Sendable { case up, down }
enum PeriodDirection: Equatable, Sendable { case toLarger, toSmaller }

// —— K 线（完整 CodingKeys；v1.3 Sendable）——
struct KLineCandle: Codable, Equatable, Sendable {
    let period: Period
    let datetime: Int64
    let open, high, low, close: Double
    let volume: Int64
    let amount: Double?
    let ma66: Double?
    let bollUpper: Double?
    let bollMid: Double?
    let bollLower: Double?
    let macdDiff: Double?
    let macdDea: Double?
    let macdBar: Double?
    let globalIndex: Int?
    let endGlobalIndex: Int

    enum CodingKeys: String, CodingKey {
        case period, datetime, open, high, low, close, volume, amount, ma66
        case bollUpper = "boll_upper"
        case bollMid = "boll_mid"
        case bollLower = "boll_lower"
        case macdDiff = "macd_diff"
        case macdDea = "macd_dea"
        case macdBar = "macd_bar"
        case globalIndex = "global_index"
        case endGlobalIndex = "end_global_index"
    }
}

struct TrainingSetMeta: Codable, Equatable, Sendable {
    let stockCode: String
    let stockName: String
    let startDatetime: Int64
    let endDatetime: Int64
}

struct FeeSnapshot: Codable, Equatable, Sendable {
    let commissionRate: Double               // v1.3：佣金小数率（0.0001 = 万一）。UI 层边界在 P6 SettingsStore 统一乘除 10000
    let minCommissionEnabled: Bool
    // stampDutyEnabled 已删除（印花税永久启用）
}

struct TradeOperation: Codable, Equatable, Sendable {
    let globalTick: Int
    let period: Period
    let direction: TradeDirection
    let price: Double
    let shares: Int
    let positionTier: PositionTier           // v1.3：从 String 改为 enum 防止非法值
    let commission: Double
    let stampDuty: Double
    let totalCost: Double
    let createdAt: Int64

    // Codable 保持 rawValue "1/5" ... "5/5"，无需自定义 CodingKeys
}

struct DrawingAnchor: Codable, Equatable, Sendable {
    let period: Period
    let candleIndex: Int
    let price: Double
}

struct DrawingObject: Codable, Equatable, Sendable {
    let toolType: DrawingToolType
    let anchors: [DrawingAnchor]
    let isExtended: Bool
    let panelPosition: Int
}

struct TradeMarker: Equatable, Sendable {
    let globalTick: Int
    let price: Double
    let direction: TradeDirection
}

// —— 训练记录（v1.2 含 finalTick，对应 DDL；v1.3 Sendable）——
struct TrainingRecord: Codable, Equatable, Sendable {
    let id: Int64?
    let trainingSetFilename: String
    let createdAt: Int64
    let stockCode: String
    let stockName: String
    let startYear: Int
    let startMonth: Int
    let totalCapital: Double
    let profit: Double
    let returnRate: Double
    let maxDrawdown: Double
    let buyCount: Int
    let sellCount: Int
    let feeSnapshot: FeeSnapshot
    let finalTick: Int                 // v1.2：Review 模式初始化依据
}

// v1.3 新增：最大回撤累加器（解 Round 3 P1-2 resume 一致性问题）
struct DrawdownAccumulator: Codable, Equatable, Sendable {
    var peakCapital: Double              // 当前 resume 已见过的最高总资金（cash + holding * price）
    var maxDrawdown: Double              // 到目前为止的最大回撤（非负值，单位元）

    /// 每 tick 或每次交易后调用
    mutating func update(currentCapital: Double) {
        if currentCapital > peakCapital { peakCapital = currentCapital }
        let dd = peakCapital - currentCapital
        if dd > maxDrawdown { maxDrawdown = dd }
    }

    static let initial = DrawdownAccumulator(peakCapital: 0, maxDrawdown: 0)
}

struct PendingTraining: Codable, Equatable, Sendable {
    let trainingSetFilename: String
    let globalTickIndex: Int
    let upperPeriod: Period
    let lowerPeriod: Period
    let positionData: Data                  // PositionManager 的 Codable 序列化（由 E2 Codable 实现保证）
    let cashBalance: Double                 // v1.3 新增：恢复时直接使用，避免重放历史
    let feeSnapshot: FeeSnapshot
    let tradeOperations: [TradeOperation]
    let drawings: [DrawingObject]
    let startedAt: Int64
    let accumulatedCapital: Double
    let drawdown: DrawdownAccumulator       // v1.3 新增：denormalize，resume 时直接恢复 peak/maxDD
}

// v1.3 说明：TrainingRecord 仍只存最终 maxDrawdown（见上），不保存 peakCapital；
// resume 语义：E6 TrainingSessionCoordinator 从 PendingTraining.drawdown 直接重建 accumulator；
// DEBUG 模式可用 tradeOperations + cashBalance 序列重放校验一致性。

// —— REST DTO ——
struct LeaseResponse: Codable, Sendable {
    let leaseId: String
    let expiresAt: String
    let sets: [TrainingSetMetaItem]
    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case expiresAt = "expires_at"
        case sets
    }
}

struct TrainingSetMetaItem: Codable, Sendable {
    let id: Int
    let stockCode: String
    let stockName: String
    let filename: String
    let schemaVersion: Int
    let contentHash: String             // v1.3：CRC32 hex，精确 8 字符小写
    enum CodingKeys: String, CodingKey {
        case id
        case stockCode = "stock_code"
        case stockName = "stock_name"
        case filename
        case schemaVersion = "schema_version"
        case contentHash = "content_hash"
    }
}

struct TrainingSetFile: Equatable, Sendable {
    let id: Int
    let filename: String
    let localURL: URL
    let schemaVersion: Int
    let lastAccessedAt: Int64
    let downloadedAt: Int64
}

struct AppSettings: Equatable, Sendable {
    var commissionRate: Double           // v1.3：永远是小数率（0.0001 = 万一）
    var minCommissionEnabled: Bool
    var totalCapital: Double
    var displayMode: DisplayMode
    // stampDutyEnabled 已删除
}
```

### M0.4 错误处理策略（v1.2 重写翻译规则）

**核心原则**（v1.2 重写）：**私有错误在本模块边界内转 AppError，调用方只消费 AppError**。v1.1 的"P2 转换 P1 的私有错误"属职责错配。

```swift
// 顶层错误类型（v1.2 以 case internalError 取代 .unknown；v1.3 全部 Sendable）
enum AppError: Error, Equatable, Sendable {
    case network(NetworkReason)
    case persistence(PersistenceReason)
    case trade(TradeReason)
    case trainingSet(TrainingSetReason)
    case internalError(module: String, detail: String)   // 强制标识来源模块
}

// v1.2：所有 Reason 枚举标 Error；v1.3：+ Sendable
enum NetworkReason: Error, Equatable, Sendable {
    case timeout
    case offline
    case serverError(code: Int)
    case leaseExpired
    case leaseNotFound
}

enum PersistenceReason: Error, Equatable, Sendable {
    case diskFull
    case dbCorrupted
    case schemaMismatch(expected: Int, got: Int)
    case ioError(String)
}

enum TradeReason: Error, Equatable, Sendable {
    case insufficientCash
    case insufficientHolding
    case disabled
    case invalidShareCount
}

enum TrainingSetReason: Error, Equatable, Sendable {
    case crcFailed
    case unzipFailed
    case emptyData
    case versionMismatch(expected: Int, got: Int)
    case fileNotFound
}

extension AppError {
    var userMessage: String { ... }
    var isRecoverable: Bool { ... }
    var shouldShowToast: Bool { ... }
}
```

**v1.2 翻译规则**（替代 v1.1 表）：

| 模块 | 在本模块边界内转 AppError 的责任 |
|---|---|
| **P1 APIClient** | 所有方法 `throws AppError`。内部把 `URLError / APIError.httpStatus(N)` 映射为 `.network(.offline/.timeout/.serverError/.leaseExpired)` |
| **P3 TrainingSetDB** | 所有方法 `throws AppError`。内部 GRDB `DatabaseError` 映射为 `.persistence(.dbCorrupted)` 或 `.trainingSet(.versionMismatch/.crcFailed)` |
| **P4 AppDB** | 同上，映射为 `.persistence(...)` |
| **E3 TradeCalculator** | 纯函数返回 `Result<Quote, TradeReason>`，**E5 调用方**用 `.mapError { AppError.trade($0) }` 提升 |
| **P2 DownloadAcceptance** | 不接触任何私有错误；只捕获下游 `AppError`，包装为 `AcceptanceResult.rejected(AppError)` |
| **UI 层（U1-U6）** | 只消费 `AppError`，通过 `userMessage` 展示 |

**禁止**：
- ❌ P2 捕获 P1/P3 的 `APIError / DatabaseError`（私有错误不跨模块）
- ❌ 随意使用 `.internalError` —— CI lint 规则限制：仅当错误无法归入前 4 类时才允许，且必须填 `module: String`

### M0.5 线程与并发约定（v1.2 修正 GRDB 表述）

```swift
// —— MainActor 必须 ——
@MainActor
final class TrainingEngine { ... }        // E5
@MainActor
final class SettingsStore { ... }          // P6
@MainActor
final class ThemeController { ... }        // F2
@MainActor
final class DrawingToolManager { ... }     // C6

// 所有 SwiftUI View / UIViewRepresentable / UIGestureRecognizerDelegate 默认 @MainActor

// —— 后台可执行 ——
actor NetworkExecutor { ... }              // P1 内部
// P3/P4 不使用 actor；GRDB 内置 DatabaseQueue 串行化

// —— 回主线程 ——
let result = try await backgroundTask()
await MainActor.run {
    engine.update(result)                  // 唯一合法的写 @Observable 方式
}
```

**GRDB 约定**（v1.2 修正）：**v1 全部使用 `DatabaseQueue`**。v1.1 在 P4 描述中"读操作可并发（GRDB pool）"的表述与 M0.5 矛盾；v1.2 统一删除 pool 表述：

- P3 TrainingSetDB：每个训练组文件对应一个独立 `DatabaseQueue`（只读，进程内串行，不同训练组并行）
- P4 AppDB：单一 `DatabaseQueue` for app.sqlite（读写均串行化，GRDB 内置）
- 追求读并发是过早优化，v1 场景（单用户 + 本地小库）`DatabaseQueue` 足够

**文件系统**：P5 `store()` 采用临时文件 + rename 原子化。

**禁止清单**：
- ❌ 后台线程直接修改 @Observable 字段
- ❌ 多个 Task 并发写同一 SQLite 文件
- ❌ 并发多次 `CacheManager.store()` 写同一目标路径
- ❌ CADisplayLink 回调中执行重量级计算
- ❌ **跨模块传递私有错误类型**（v1.2 新增）
- ❌ **跨 actor 捕获非 Sendable 引用类型**（v1.3 新增）——闭包中若需捕获 `@MainActor` 引用，闭包本身必须标 `@MainActor` 或通过 `MainActor.assumeIsolated` 安全进入

**Sendable 清单**（v1.3 新增）：
- M0.3 全部值类型（struct / enum）`Sendable`
- `AppError` 及 `NetworkReason / PersistenceReason / TradeReason / TrainingSetReason`（Reason 清单见 M0.4）
- 跨 actor 协议返回值必须 `Sendable`：`P1 APIClient`、`P3b TrainingSetReader`、`P4` 三 Repo、`P2` 4 个内部端口返回类型
- `@Observable final class` 默认非 Sendable；必须在 `@MainActor` 上下文内使用（E5 / P6 / F2 / C6 DrawingToolManager 均已标 `@MainActor`）

---

## 四、后端模块（4 个）

### B1 数据导入模块 `import_csv.py`

- **职责**：CSV → 清洗 → 计算 MA66/BOLL/MACD → 建立 1m 基准 ticket_index → 写 PostgreSQL
- **依赖**：M0.1
- **CLI**：`python import_csv.py --input <csv_dir> --stock <code> [--period 1m|3m|...]`
- **验收**：row count、时间连续性、ticket_index 严格递增

### B2 训练组生成模块 `generate_training_sets.py`（v1.2 增强 hash 计算）

- **职责**：月线选起始点 → 每周期独立查询 → 算 `global_index / end_global_index` → 写 SQLite + `PRAGMA user_version` → 压缩 zip → 计算 zip CRC32 → 登记 `training_sets`

**函数式 API**：

```python
def generate_one_training_set(conn, stock_code: str) -> GeneratedTrainingSet:
    """
    生成一个训练组。
    幂等：若 (stock_code, start_datetime) 已存在则重选起始点。
    失败（月线不足 / "之后"窗口为空）→ 抛 GenerateSkipException
    """

@dataclass
class GeneratedTrainingSet:
    path: Path                   # zip 文件路径
    content_hash: str            # v1.2：zip CRC32 十六进制（无需 sqlite 字节 hash）
    ...

def generate_batch(conn, target_count: int) -> List[GeneratedTrainingSet]:
    """B4 调度器直接调用，同进程共享连接池。"""
```

- **v1.2 修正**：`content_hash` 计算从"解压后 sqlite 字节的 sha256"改为"zip 字节的 CRC32"。CRC32 由 zip 格式天然携带，客户端无需重新解压即可验。Python 使用 `zlib.crc32`
- **v1.3 hash 格式收紧**：`content_hash` 返回值 = `format(zlib.crc32(zip_bytes) & 0xFFFFFFFF, '08x')`（8 字符小写十六进制），对应 PostgreSQL `CHAR(8)` 列。B2 拒绝长度 ≠ 8 的旧值写入
- **v1.3 回迁**：上线 v1.3 migration 后首次批次运行时，B4 调度器调用 B2 `generate_batch`，B2 识别所有 `status='unsent' AND content_hash IS NULL` 行（含 migration 作废的遗留 sha256 行），按新 CRC32 格式重新计算并回写
- **不变量**：月线前 ≥30 / "之后"= 8 根月 K 时间窗口 / end_global_index 二分匹配 / UNIQUE(stock_code, start_datetime) 冲突重选
- **验收**：生成 10 个样本，每个 zip 用 `unzip -v` 查看 CRC 与库里 content_hash 一致（长度 8，小写）

### B3 FastAPI 服务模块 `app/routes.py`（v1.3：+ migration/rollback owner）

- **职责**：实现 M0.2 + 租约状态机 + **PostgreSQL migration / rollback 执行**（v1.3 新增）
- **v1.3 新增 owner 责任**：B3 负责执行 `backend/sql/migrations/` 下每个 migration 的 `forward.sql` / `rollback.sql`，按 M0.1 规则不允许不可逆 migration（除非列/表删除且显式标注）
- **v1.2 变更**：`GET /meta` 不再仅改 `status`，需原子更新 `status='reserved' / lease_id / lease_expires_at / reserved_at` 4 列；`POST /confirm` 校验 `lease_id` 与 `lease_expires_at > now()`
- **实现参考**：

```python
@app.post("/training-set/{id}/confirm")
async def confirm(id: int, lease_id: UUID):
    async with db.transaction():
        row = await db.fetch_one("""
            SELECT status, lease_id, lease_expires_at
            FROM training_sets WHERE id = $1 FOR UPDATE
        """, id)
        if not row:
            raise HTTPException(404, "not_found")
        if row["status"] == "sent" and row["lease_id"] == lease_id:
            return {"ok": True}  # 幂等
        if row["lease_id"] != lease_id or row["lease_expires_at"] < now():
            raise HTTPException(409, "lease_expired")
        await db.execute("UPDATE training_sets SET status = 'sent' WHERE id = $1", id)
        return {"ok": True}
```

### B4 调度器模块 `app/scheduler.py`

- **职责**：APScheduler 每天北京时间 5:00：
  1. 回滚：`status='reserved' AND lease_expires_at < now()` → 重置 status/lease_id/lease_expires_at/reserved_at
  2. 补齐：`unsent` ≤ 40 → 同进程调用 `B2.generate_batch(conn, target=100-current_unsent)`
- **依赖**：B2（函数调用）、M0.1
- **验收**：人为 5 条过期 reserved → 全部回滚；unsent=30 → 补 70 个

---

## 五、iOS 基础模块（2 个）

### F1 数据模型模块 `Models/`

- **职责**：承载 M0.3 所有类型（含 `Equatable / Codable / CodingKeys`）
- **依赖**：M0.3、M0.4（AppError）
- **验收**：Codable round-trip 测试（snake_case JSON ↔ camelCase struct）；所有类型 `Equatable`；Reason 枚举 `Error` conformance 编译通过

### F2 主题模块 `Theme/`

```swift
@MainActor
@Observable
final class ThemeController {
    var displayMode: DisplayMode = .system
    func resolve(trait: UITraitCollection) -> ColorScheme
}

enum AppColor {
    static var candleUp: UIColor { get }
    static var candleDown: UIColor { get }
    static var ma66: UIColor { get }
    static var bollLine: UIColor { get }
    static var macdDIF: UIColor { get }
    static var macdDEA: UIColor { get }          // 黄色（v1.5 §2）
    static var profitRed: UIColor { get }
    static var lossGreen: UIColor { get }
    // ... 背景/网格/文字
}
```

---

## 六、iOS 图表引擎模块（10 个，v1.3 C1 拆 3）

### C1 图表核心模块拆分说明（v1.3）

v1.3 把 v1.2 的单一 C1 模块拆为 3 个顶层模块，分别承担几何 / 状态机 / 渲染状态三个独立职责。三者共同构成 "C1 族"：

- **C1a `ChartEngine/Core/Geometry/`** — 纯几何与坐标映射（下方 §六 C1a）
- **C1b `ChartEngine/Core/Reducer/`** — 交互状态机 + revision 漂移防护（下方 §六 C1b）
- **C1c `ChartEngine/Core/Render/`** — `KLineRenderState` + `KLineView` 本体（下方 §六 C1c）

三个拆分都在 Wave 0 整体交付（不分 wave 切分）；`ChartAction`/`ChartReduceEffect`/`PanelViewState`/`FrozenPanelState` 等值类型跨 C1a/C1b 共享。

### C1a 几何与坐标模块 `ChartEngine/Core/Geometry/`（v1.3 从 C1 拆出）

**职责**：纯几何 / 视口 / 坐标映射；不依赖 UIKit、不依赖 candles 数据、不依赖手势。

**v1.3 额外修订**：新增 `NonDegenerateRange` 替换副图 `ClosedRange<Double>`（解 P1-5 副图值域退化除零）。

### C1 原始小节（v1.2 锚点保留）

**v1.2 关键修订**：
1. 拆非递归 `FrozenPanelState`（解 P0-3 递归值类型）
2. 所有值类型补 `Equatable`
3. 三态 reducer 补全 3×7 完整矩阵
4. `IndicatorMapperBundle.make(for:)` 删除；值域外置到 `KLineRenderState`，由 C8 构造
5. Wave 0 交付 C1 完整实现（不再切片）

**v1.3 关键修订**（基于 Round 3 adversarial review 收敛）：
1. `PanelViewState` 加 `revision: UInt64` 单调版本；`FrozenPanelState` 加 `baseRevision: UInt64`（解 P0-1 跨 tick 快照漂移）
2. `ChartAction.drawingCommitted/drawingCancelled` 加参数 `baseRevision: UInt64`
3. `ChartReduceEffect` 新增 `.stalePanelRevision(expected:actual:)`
4. `NonDegenerateRange` 替换 `ClosedRange<Double>` 用于副图值域（解 P1-5）
5. C1 拆 3 顶层模块（C1a / C1b / C1c，见上）

#### 几何 + 视口

```swift
struct ChartGeometry: Equatable, Sendable {
    let candleStep, candleWidth, gap: CGFloat
}

struct ChartPanelFrames: Equatable, Sendable {
    let mainChart: CGRect      // 60%
    let volumeChart: CGRect    // 15%
    let macdChart: CGRect      // 25%
    static func split(in rect: CGRect) -> ChartPanelFrames
}

struct PriceRange: Equatable, Sendable {
    let min, max: Double
    static func calculate(from candles: ArraySlice<KLineCandle>) -> PriceRange
}

struct ChartViewport: Equatable, Sendable {
    let startIndex: Int
    let visibleCount: Int
    let pixelShift: CGFloat
    let geometry: ChartGeometry
    let priceRange: PriceRange
    let mainChartFrame: CGRect
}
```

#### 坐标映射

```swift
struct CoordinateMapper: Equatable, Sendable {
    let viewport: ChartViewport
    let displayScale: CGFloat

    func indexToX(_: Int) -> CGFloat
    func priceToY(_: Double) -> CGFloat
    func xToIndex(_: CGFloat) -> Int
    func yToPrice(_: CGFloat) -> Double
}

// v1.3：非退化值域（替换 ClosedRange<Double>，避免 upper == lower 导致除零）
struct NonDegenerateRange: Equatable, Sendable {
    let lower: Double
    let upper: Double                                   // 强制 upper > lower

    /// 从候选值构造非退化范围。values 可为空或全零或单值，均返回可用的 range。
    static func make(values: [Double],
                     fallback: ClosedRange<Double> = 0.0...1.0,
                     paddingRatio: Double = 0.02) -> NonDegenerateRange {
        guard let minV = values.min(), let maxV = values.max() else {
            return NonDegenerateRange(lower: fallback.lowerBound, upper: fallback.upperBound)
        }
        if minV == maxV {
            // 单值：对称加 padding
            let pad = max(abs(minV) * paddingRatio, 1e-6)
            return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
        }
        let span = maxV - minV
        let pad = span * paddingRatio
        return NonDegenerateRange(lower: minV - pad, upper: maxV + pad)
    }

    var span: Double { upper - lower }
}

// v1.2：独立副图 mapper（不再有 make(for:)，valueRange 外部注入）
// v1.3：valueRange 类型从 ClosedRange<Double> 改为 NonDegenerateRange，valueToY 保证无除零；+ Sendable
struct IndicatorMapper: Equatable, Sendable {
    let frame: CGRect
    let valueRange: NonDegenerateRange
    let geometry: ChartGeometry
    let viewport: ChartViewport
    let displayScale: CGFloat

    func indexToX(_: Int) -> CGFloat
    func valueToY(_: Double) -> CGFloat
}
```

#### C1b 状态类型（v1.2 拆非递归；v1.3 加 revision 防漂移）

```swift
struct PanelViewState: Equatable, Sendable {
    var period: Period
    var interactionMode: ChartInteractionMode
    var visibleCount: Int
    var offset: CGFloat                            // 唯一真值
    var revision: UInt64                           // v1.3：每次面板状态变动单调递增；revision 只由 reducer/effect 递增，外部只读
}

enum ChartInteractionMode: Equatable, Sendable {
    case autoTracking
    case freeScrolling
    case drawing(snapshot: DrawingSnapshot)
}

// v1.2：非递归冻结快照；v1.3：增 baseRevision 供提交时核对
struct FrozenPanelState: Equatable, Sendable {
    let period: Period
    let visibleCount: Int
    let offset: CGFloat
    let candleRange: Range<Int>
    let baseRevision: UInt64                       // v1.3：冻结时的面板 revision
}

struct DrawingSnapshot: Equatable, Sendable {
    let frozen: FrozenPanelState                  // 非递归，编译通过
}

extension PanelViewState {
    func freeze(candleRange: Range<Int>) -> FrozenPanelState {
        FrozenPanelState(period: period, visibleCount: visibleCount,
                        offset: offset, candleRange: candleRange,
                        baseRevision: revision)    // v1.3：冻结当前 revision
    }
}
```

**revision 防漂移语义**（v1.3 解 P0-1）：
- `periodComboSwitched` / `tradeTriggered` / `panStarted` / `panEnded` 等任何改变面板可见范围的 action 处理时，reducer 递增 `revision`
- `activateDrawing` 冻结 snapshot 时记录当时的 `revision` 作为 `baseRevision`
- `drawingCommitted(baseRevision:)` / `drawingCancelled(baseRevision:)` 提交时携带冻结时的 `baseRevision`；reducer 比对当前 `revision`，**不匹配则返回 `.stalePanelRevision(expected:actual:)` 并保持 drawing 模式**（让 UI 层决定重新冻结还是放弃）
- 业务含义：交易后硬切 autoTracking 或跨 tick 面板状态漂移时，旧 snapshot 的 commit/cancel 不再能覆盖当前面板
- 推断：在 `@MainActor` + sync reducer 前提下已大部分消除重入，但 async effect 跨 tick 返回时仍可能拿到旧 revision（例如长按绘线期间交易触发），revision 检测是最轻量的防御

#### C1b 三态 Reducer（v1.3：activateDrawing 改 effect-driven + drawingCommitted/Cancelled 比对当前 revision）

```swift
// ChartAction 定义见本节后方（含 v1.3 新增 setDrawingSnapshot）；reducer 先定义 effect 与 reduce 实现

// v1.3：effect 扩充。闸门 #4 修订：
// - 拆分 stale 场景只保留 setDrawingSnapshot 漂移（drawing 内不可能 bump revision，commit/cancel 不 check）
// - activateDrawing effect 显式要求 handler 先 stop animator
enum ChartReduceEffect: Equatable, Sendable {
    case none
    case startDeceleration(velocity: CGFloat)
    case clearPendingDrawing
    /// activateDrawing 返回此 effect。Handler 合约（必须按序）：
    ///   1. 立即调用 DecelerationAnimator.stop()（防止 stale 漂移，闸门 #2 F2）
    ///   2. 基于当前 viewport 计算 candleRange
    ///   3. 派发 ChartAction.setDrawingSnapshot(tool, baseRevision, candleRange)
    /// 若 handler 不 stop animator，reducer 已通过 drawing 模式下吞 offsetApplied 兜底
    /// 但任何残留 animator 回调在 drawing 退出后仍会应用 → 必须 stop
    case requestDrawingSnapshotAfterStoppingAnimator(tool: DrawingToolType, baseRevision: UInt64)
    /// setDrawingSnapshot 回推时发现 revision 已漂移（handler 计算期间被 tradeTriggered/period 切换抢占）
    /// 语义：snapshot 无效 → mode 保持 autoTracking，不进 drawing；UI 可按需重新发 activateDrawing
    case staleDrawingSnapshot(expected: UInt64, actual: UInt64)
}

/// v1.3 说明：reducer 在修改面板可见范围的 action 处理时 `revision += 1`：
/// - panStarted / panEnded：修改 interactionMode 和 offset → bump
/// - activateDrawing：返回 requestDrawingSnapshot effect；不进 drawing 模式；不 bump revision
/// - setDrawingSnapshot（新 action，见下）：外部带真实 candleRange 回来，才进 drawing 模式；不 bump revision（但核对 baseRevision 必须等于当前 revision）
/// - tradeTriggered / periodComboSwitched：硬切 autoTracking → bump
/// drawingCommitted/drawingCancelled：比较 action.baseRevision 与当前 panel.revision；不匹配返回 stalePanelRevision 保留 mode；匹配则切 autoTracking
extension PanelViewState {
    /// v1.3 更新：ChartAction 新增 setDrawingSnapshot；drawing 模式不再使用 placeholder
    mutating func reduce(_ action: ChartAction) -> ChartReduceEffect {
        switch (interactionMode, action) {
        // —— panStarted ——
        case (.autoTracking, .panStarted):
            interactionMode = .freeScrolling
            revision &+= 1
            return .none
        case (.freeScrolling, .panStarted), (.drawing, .panStarted):
            return .none

        // —— panEnded ——
        case (.autoTracking, .panEnded), (.drawing, .panEnded):
            return .none
        case (.freeScrolling, .panEnded(let v)):
            revision &+= 1
            return .startDeceleration(velocity: v)

        // —— activateDrawing（v1.3：不直接进 drawing 模式，只发 effect 请求快照）——
        case (.autoTracking, .activateDrawing(let tool)), (.freeScrolling, .activateDrawing(let tool)):
            return .requestDrawingSnapshotAfterStoppingAnimator(tool: tool, baseRevision: revision)
        case (.drawing, .activateDrawing):
            return .none  // 切换工具由 DrawingToolManager 处理

        // —— setDrawingSnapshot（v1.3 新 action：外部带真实 candleRange 回来；stale 仅此处可达）——
        case (.autoTracking, .setDrawingSnapshot(let tool, let baseRev, let range)),
             (.freeScrolling, .setDrawingSnapshot(let tool, let baseRev, let range)):
            // handler 计算 candleRange 期间若被 tradeTriggered / periodComboSwitched 抢占，revision 已漂移
            guard baseRev == revision else {
                return .staleDrawingSnapshot(expected: baseRev, actual: revision)
            }
            _ = tool  // 由 DrawingToolManager 处理 tool 切换；reducer 只管面板 mode
            let frozen = FrozenPanelState(period: period, visibleCount: visibleCount,
                                          offset: offset, candleRange: range,
                                          baseRevision: revision)
            interactionMode = .drawing(snapshot: DrawingSnapshot(frozen: frozen))
            return .none
        case (.drawing, .setDrawingSnapshot):
            return .none  // drawing 模式下切工具由 DrawingToolManager 处理，不重复进 drawing

        // —— drawingCommitted / drawingCancelled（v1.3 闸门 #4 简化）——
        // 洞察：drawing 模式下没有任何 action 可以 bump revision（offsetApplied 被吞；
        // tradeTriggered/periodComboSwitched 会切出 drawing；其余都是 no-op）；
        // 所以 drawing 模式内 action.baseRevision 必然 == 当前 revision，stale 不可达。
        // baseRevision 参数保留作为 UI → reducer 的调试 trace，reducer 本身不做 stale 检查。
        case (.drawing, .drawingCommitted), (.drawing, .drawingCancelled):
            interactionMode = .autoTracking
            return .none
        case (.autoTracking, .drawingCommitted), (.freeScrolling, .drawingCommitted),
             (.autoTracking, .drawingCancelled), (.freeScrolling, .drawingCancelled):
            assertionFailure("非法转换：\(interactionMode) → \(action)")
            return .none

        // —— tradeTriggered：任意状态硬切 autoTracking ——
        case (_, .tradeTriggered):
            interactionMode = .autoTracking
            revision &+= 1
            return .none

        // —— periodComboSwitched：同 trade，并清空 drawing 快照 ——
        case (_, .periodComboSwitched):
            interactionMode = .autoTracking
            revision &+= 1
            return .clearPendingDrawing

        // —— offsetApplied（v1.3 新；闸门 #3 修订：drawing 模式下忽略，防止 deceleration/Pan 漂移导致 drawing 卡死）——
        // 业务约束：进入 drawing 模式前，E5/C8 应 stop 减速动画；若仍有残余回调到达 drawing 模式，reducer 直接忽略
        case (.drawing, .offsetApplied):
            return .none
        case (.autoTracking, .offsetApplied(let deltaPixels)),
             (.freeScrolling, .offsetApplied(let deltaPixels)):
            offset += deltaPixels
            revision &+= 1
            return .none
        }
    }
}
```

**ChartAction 更新**（v1.3 加 `setDrawingSnapshot` + `offsetApplied`；activateDrawing 不再直接切 mode）：

```swift
enum ChartAction: Equatable, Sendable {
    case panStarted
    case panEnded(velocity: CGFloat)
    case activateDrawing(DrawingToolType)                                  // v1.3：只触发 effect，不 bump revision
    case setDrawingSnapshot(tool: DrawingToolType, baseRevision: UInt64,
                            candleRange: Range<Int>)                       // v1.3 新：外部带真实 range 回推
    case drawingCommitted(baseRevision: UInt64)
    case drawingCancelled(baseRevision: UInt64)
    case tradeTriggered
    case periodComboSwitched
    case offsetApplied(deltaPixels: CGFloat)                               // v1.3 新（闸门 #2 F2 修复）：手势/减速动画/程序驱动的 offset 变化必须走此 action；reducer 更新 offset + bump revision
}
```

**关键约束**（闸门 #2 F2 修复）：
- `DecelerationAnimator.onUpdate` **禁止**直接写 `PanelViewState.offset`；必须派发 `.offsetApplied(deltaPixels:)` 到 reducer
- 所有改变 `offset` 的路径（手势 Pan / DecelerationAnimator / 程序 setOffset）**必须**通过 `offsetApplied` action；reducer 在此 action 下 bump `revision`
- 由此 `requestDrawingSnapshot` 返回后若发生任何 offset 漂移，`revision` 已变，`setDrawingSnapshot` 会因 revision 不匹配返回 `.stalePanelRevision`

**staleDrawingSnapshot 可达路径**（v1.3 闸门 #4 简化：仅 setDrawingSnapshot 阶段可能 stale）：

- **trade 漂移**：activateDrawing（r=0）→ effect `.requestDrawingSnapshotAfterStoppingAnimator(tool, baseRev:0)` → handler 计算期间发生 `tradeTriggered` 使 revision=1 → handler 回推 setDrawingSnapshot(baseRev:0, range) → reducer 返回 `.staleDrawingSnapshot(expected:0, actual:1)` 且 mode 保持 autoTracking（未进 drawing）
- **periodCombo 漂移**：同 trade，但触发 `periodComboSwitched`（也 bump + 切 autoTracking）

**drawing 模式不可能 stale**：进入 drawing 后无任何 action 能 bump revision（offsetApplied 被吞；tradeTriggered/periodComboSwitched 会直接切出 drawing + 丢弃 snapshot）；因此 commit/cancel 不需 check baseRevision。

**Wave 0 额外验收**（v1.3 闸门 #4 修订）：
- `revision` 单调性测试：`panStarted` / `panEnded` / `tradeTriggered` / `periodComboSwitched` / **`offsetApplied`**（仅 autoTracking + freeScrolling 模式）均 bump；其它 action 均不 bump；drawing 模式下 `offsetApplied` 吞掉、revision 不变
- `requestDrawingSnapshotAfterStoppingAnimator` effect 覆盖测试：autoTracking / freeScrolling 上派发 activateDrawing → 返回对应 effect + mode 未变 + revision 未变
- **`staleDrawingSnapshot` 可达测试**：
  1. activateDrawing（r=0）→ tradeTriggered（r=1）→ setDrawingSnapshot(baseRev:0) → 断言 `.staleDrawingSnapshot(expected:0, actual:1)` + mode=autoTracking
  2. activateDrawing（r=0）→ periodComboSwitched（r=1, clearPendingDrawing）→ setDrawingSnapshot(baseRev:0) → 同上
- **Deceleration stop 契约测试**（闸门 #4 F3 新增）：`panEnded(velocity:) → .startDeceleration(v)` effect handler 启动 animator；后续 activateDrawing → `.requestDrawingSnapshotAfterStoppingAnimator` effect；验证 handler 必须**先**调用 `animator.stop()` 再计算 range（集成测试：模拟延迟 animator 回调，验证 drawing 退出后无 `offsetApplied` 到达 reducer）
- `drawingCommitted/drawingCancelled` 非法转换 assertion 测试：autoTracking / freeScrolling 上派发 → assertionFailure
- `drawingCommitted/drawingCancelled` 正常退出测试：drawing 模式内派发 → mode=autoTracking + .none；无论 action 携带的 baseRevision 值为何（baseRevision 仅作调试 trace，reducer 不 check）
- `offsetApplied` 单独测试：
  - autoTracking / freeScrolling：offset 累加 + revision+1；mode 不变
  - drawing：忽略（.none），offset 与 revision 均不变

#### KLineView 本体

```swift
final class KLineView: UIView {
    var renderState: KLineRenderState = .empty {
        didSet {
            guard renderState != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = traitCollection.displayScale
        let mapper = CoordinateMapper(viewport: renderState.viewport, displayScale: scale)
        let volMapper = IndicatorMapper(
            frame: renderState.frames.volumeChart,
            valueRange: renderState.volumeRange,              // v1.2：外部注入
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)
        let macdMapper = IndicatorMapper(
            frame: renderState.frames.macdChart,
            valueRange: renderState.macdRange,
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)

        drawCandles(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawMA66(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawBOLL(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawVolume(ctx: ctx, mapper: volMapper, candles: renderState.visibleCandles)
        drawMACD(ctx: ctx, mapper: macdMapper, candles: renderState.visibleCandles)
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                    period: renderState.panel.period)
        drawMarkers(ctx: ctx, viewport: renderState.viewport, mapper: mapper,
                   markers: renderState.markers, candles: renderState.visibleCandles)
        drawCrosshair(ctx: ctx, at: renderState.crosshairPoint, viewport: renderState.viewport)
    }
}

// v1.2：renderState 扩充 volumeRange / macdRange（由 C8 构造时计算）
// v1.3：volumeRange / macdRange 改为 NonDegenerateRange（解 P1-5）
struct KLineRenderState: Equatable, Sendable {
    let panel: PanelViewState
    let frames: ChartPanelFrames
    let viewport: ChartViewport
    let visibleCandles: ArraySlice<KLineCandle>
    let volumeRange: NonDegenerateRange          // v1.3：类型升级
    let macdRange: NonDegenerateRange            // v1.3：类型升级
    let markers: [TradeMarker]
    let drawings: [DrawingObject]
    let crosshairPoint: CGPoint?

    static let empty = KLineRenderState(...)
}
```

- **依赖**：F1、M0.3
- **可并行性**：Wave 0 完整交付（含 KLineView 本体、renderState、reducer、全部 mapper 类型）
- **验收**：
  - 坐标映射往返单元测试
  - PriceRange 边界测试
  - reducer 全 21 格矩阵测试（含 assertionFailure 触发）
  - `KLineRenderState` Equatable 短路测试（相同输入两次 render 只画一次）

### C2 减速动画模块 `DecelerationAnimator.swift`（v1.3：offset 更新必须派发 action）

```swift
final class DecelerationAnimator {
    /// v1.3（闸门 #2 F2 修复）：onUpdate 的消费者**必须**把 deltaOffset 封装为
    /// `ChartAction.offsetApplied(deltaPixels:)` 派发给 reducer；禁止直接写 `PanelViewState.offset`
    var onUpdate: ((CGFloat) -> Void)?
    var onFinish: (() -> Void)?
    init(friction: CGFloat = 0.94, stopThreshold: CGFloat = 0.5)
    func start(initialVelocity: CGFloat)
    func stop()
    func resetOnSceneActive()     // 由 E5.onSceneActivated() 调用
}

// v1.3 用法示例（C8 或 E5 中）：
// animator.onUpdate = { [weak dispatcher] delta in
//     dispatcher?.dispatch(.offsetApplied(deltaPixels: delta))
// }
```

### C3 主图渲染模块 `KLineView+Candles.swift`

```swift
extension KLineView {
    func drawCandles(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>)
    func drawMA66(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>)
    func drawBOLL(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>)
}
```

### C4 副图渲染模块 `KLineView+Volume.swift` + `KLineView+MACD.swift`

```swift
extension KLineView {
    func drawVolume(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>)
    func drawMACD(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>)
}
```

**v1.2 注**：`mapper.valueRange` 来自 `KLineRenderState.volumeRange/macdRange`，C4 内部不再计算值域。

### C5 辅助层渲染模块

```swift
extension KLineView {
    func drawCrosshair(ctx: CGContext, at point: CGPoint?, viewport: ChartViewport)
    func drawMarkers(ctx: CGContext, viewport: ChartViewport, mapper: CoordinateMapper,
                    markers: [TradeMarker], candles: ArraySlice<KLineCandle>)
}

// 精确二分谓词
func findCandleIndex(for marker: TradeMarker,
                    in candles: ArraySlice<KLineCandle>) -> Int? {
    // 在 candles 上二分：找第一根满足 candle.endGlobalIndex >= marker.globalTick 的 K 线
    return candles.binarySearchFirst { $0.endGlobalIndex >= marker.globalTick }
}
```

### C6 绘线工具模块

```swift
protocol DrawingTool {
    static var type: DrawingToolType { get }
    var requiredAnchors: ClosedRange<Int> { get }
    func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor])
    func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool
}

protocol DrawingInputController {
    func tapToAnchor(at point: CGPoint, panel: PanelViewState, mapper: CoordinateMapper) -> DrawingAnchor
    func shouldCommit(current: [DrawingAnchor], tool: DrawingToolType) -> Bool
}

@MainActor
@Observable
final class DrawingToolManager {
    var activeTool: DrawingToolType?
    var enabledTools: Set<DrawingToolType>
    var pendingAnchors: [DrawingAnchor]
    var completedDrawings: [DrawingObject]

    func toggle(_: DrawingToolType)
    func addAnchor(_: DrawingAnchor)
    func commit()
    func cancel()                               // v1.2：显式取消，供 reducer.periodComboSwitched 调用
    func deleteDrawing(at: Int)
}

extension KLineView {
    func drawDrawings(ctx: CGContext, mapper: CoordinateMapper,
                     drawings: [DrawingObject], period: Period)
}
```

### C7 手势系统模块（v1.2 补单指主方向）

```swift
enum GesturePhase { case began, changed, ended, cancelled }

// 两指意图（v1.1）
enum TwoFingerIntent: Equatable {
    case switchPeriod(SwipeDirection)
    case pinch
    case ignore
}

func classifyTwoFingerGesture(translation: CGPoint, scale: CGFloat) -> TwoFingerIntent {
    if abs(scale - 1.0) > 0.02 { return .pinch }
    let dx = abs(translation.x); let dy = abs(translation.y)
    if dy > dx * 1.2 { return .switchPeriod(translation.y < 0 ? .up : .down) }
    return .ignore
}

// v1.2 新增：单指意图
enum SingleFingerPanIntent: Equatable {
    case horizontal(delta: CGFloat)             // 触发平移
    case vertical                                // 忽略
    case ambiguous                               // 等待更多数据
}

func classifySingleFingerPan(translation: CGPoint,
                            minThreshold: CGFloat = 8) -> SingleFingerPanIntent {
    let dx = abs(translation.x)
    let dy = abs(translation.y)
    if dx < minThreshold && dy < minThreshold { return .ambiguous }
    if dx > dy * 1.5 { return .horizontal(delta: translation.x) }
    if dy > dx * 1.5 { return .vertical }
    return .ambiguous
}

// v1.2 新增：Drawing 模式截获规则
enum DrawingModePanPolicy {
    case drawingTakesOver    // Pan 被绘线工具吃掉
    case normalPass          // 普通透传
}

func panPolicyInDrawingMode(drawingMode: Bool) -> DrawingModePanPolicy {
    drawingMode ? .drawingTakesOver : .normalPass
}

final class ChartGestureArbiter: NSObject, UIGestureRecognizerDelegate {
    var onPan: ((CGFloat, CGFloat, GesturePhase) -> Void)?
    var onPinch: ((CGFloat, CGPoint, GesturePhase) -> Void)?
    var onLongPress: ((CGPoint, GesturePhase) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var onTwoFingerSwipe: ((SwipeDirection) -> Void)?
    var drawingMode: Bool = false
    func attach(to view: UIView)
}
```

### C8 图表容器模块（v1.2 去除 scene 职责）

**v1.2 变更**：C8 只做 @Observable → UIKit 桥接，**不再负责 scenePhase 监听**。scene 责任链统一为：

```
U2 TrainingView .onChange(of: scenePhase)
    → engine.onSceneActivated()  (E5)
        → animator.resetOnSceneActive()  (C2)
```

```swift
struct ChartContainerView: UIViewRepresentable {
    let panel: PanelId
    @Bindable var engine: TrainingEngine

    func makeUIView(context: Context) -> KLineView
    func updateUIView(_ view: KLineView, context: Context) {
        view.renderState = buildRenderState(from: engine, panel: panel, bounds: view.bounds)
    }
}

// 实现约束：
// 1. updateUIView 中禁止直接订阅 ObservationRegistrar
// 2. 依赖 @Bindable 触发 SwiftUI 重建，进而触发 updateUIView
// 3. KLineView 不持有 @Observable 引用，只接受 KLineRenderState 值类型
// 4. buildRenderState 负责计算 volumeRange / macdRange（v1.2 新增职责）
// 5. 不监听 scenePhase（v1.2）

// C8 内部：KLineRenderState 构造（v1.3：使用 NonDegenerateRange.make 保证非退化）
private func buildRenderState(from engine: TrainingEngine,
                             panel: PanelId, bounds: CGRect) -> KLineRenderState {
    let panelState = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
    let candles = engine.allCandles[panelState.period]!
    let visibleSlice = /* 基于 tick + offset 计算 */
    let volumeValues = visibleSlice.map { Double($0.volume) }
    let volumeRange = NonDegenerateRange.make(
        values: [0.0] + volumeValues,                   // 保证下界 0
        fallback: 0.0...1.0
    )
    let macdValues = visibleSlice.flatMap { [$0.macdDiff, $0.macdDea, $0.macdBar].compactMap { $0 } }
    let macdRange = NonDegenerateRange.make(
        values: macdValues,
        fallback: -0.001...0.001                        // nil/全零 fallback
    )
    return KLineRenderState(
        panel: panelState,
        frames: ChartPanelFrames.split(in: bounds),
        viewport: /* ... */,
        visibleCandles: visibleSlice,
        volumeRange: volumeRange,
        macdRange: macdRange,
        markers: engine.markers,
        drawings: engine.drawings,
        crosshairPoint: /* ... */
    )
}
```

- **验收**：Instruments 120Hz 单帧 <4ms；Equatable 短路生效（相同 engine 状态重复 updateUIView 不触发 draw）

---

## 七、iOS 业务逻辑模块（6 个，v1.3 E5 拆 L2）

### E1 时间引擎模块 `TickEngine.swift`

```swift
struct TickEngine: Equatable {
    private(set) var globalTickIndex: Int
    let maxTick: Int

    init(maxTick: Int, initialTick: Int = 0) {
        self.maxTick = maxTick
        self.globalTickIndex = max(0, min(initialTick, maxTick))
    }

    mutating func advance(steps: Int = 1) -> Bool
    mutating func reset(to tick: Int)
}
```

### E2 持仓管理模块 `PositionManager.swift`

（见 v1.5 §4.2；类型加 `Equatable`）

### E3 交易计算模块 `TradeCalculator.swift`（v1.2 错误类型闭环）

```swift
enum TradeCalculator {
    struct BuyQuote: Equatable { let shares: Int; let notional, commission, totalCost: Double }
    struct SellQuote: Equatable { let shares: Int; let notional, commission, stampDuty, proceeds: Double }

    // v1.2：TradeReason 已标 Error，Result 类型合法
    static func quoteBuy(totalCapital: Double, cash: Double,
                        tier: PositionTier, price: Double,
                        fees: FeeSnapshot) -> Result<BuyQuote, TradeReason>

    static func quoteSell(holding: Int, averageCost: Double,
                         tier: PositionTier, price: Double,
                         fees: FeeSnapshot) -> Result<SellQuote, TradeReason>

    static func forceCloseOnEnd(holding: Int, averageCost: Double,
                               price: Double, fees: FeeSnapshot) -> SellQuote

    static let stampDutyRate: Double = 0.0005   // 始终生效
    static let minCommissionAmount: Double = 5
    static let shareLotSize: Int = 100
}
```

**调用方转换示例**（E5 TrainingEngine）：

```swift
func buy(panel: PanelId, tier: PositionTier) -> Result<TradeOperation, AppError> {
    TradeCalculator
        .quoteBuy(...)
        .mapError { AppError.trade($0) }         // TradeReason → AppError
        .map { quote in /* 构造 TradeOperation */ }
}
```

### E4 训练模式控制模块 `TrainingFlowController.swift`（v1.2 验收文字修正）

```swift
protocol TrainingFlowController {
    var mode: TrainingMode { get }
    var feeSnapshot: FeeSnapshot { get }
    var initialTick: Int { get }                   // TrainingEngine 启动时设置
    var allowedTickRange: ClosedRange<Int> { get }

    func canBuySell() -> Bool
    func canAdvance() -> Bool
    func shouldSaveRecord() -> Bool
    func shouldAccumulateCapital() -> Bool
    func shouldShowSettlement() -> Bool
    func shouldGiveHapticFeedback() -> Bool
}

struct NormalFlow: TrainingFlowController {
    let fees: FeeSnapshot                           // v1.2 注：由 U1 启动时从 SettingsStore 打包注入
    let maxTick: Int
    var feeSnapshot: FeeSnapshot { fees }
    var initialTick: Int { 0 }
    var allowedTickRange: ClosedRange<Int> { 0...maxTick }
}

struct ReviewFlow: TrainingFlowController {
    let record: TrainingRecord                      // 原局 snapshot
    var feeSnapshot: FeeSnapshot { record.feeSnapshot }
    var initialTick: Int { record.finalTick }
    var allowedTickRange: ClosedRange<Int> { record.finalTick...record.finalTick }
    func canAdvance() -> Bool { false }
    func canBuySell() -> Bool { false }
}

struct ReplayFlow: TrainingFlowController {
    let feeSnapshotFromOriginal: FeeSnapshot        // v1.2：只持有 feeSnapshot，不持有整个 record
    let maxTick: Int
    var feeSnapshot: FeeSnapshot { feeSnapshotFromOriginal }
    var initialTick: Int { 0 }
    var allowedTickRange: ClosedRange<Int> { 0...maxTick }
    func shouldSaveRecord() -> Bool { false }
}
```

**验收**（v1.2 修正）：
- Normal：启动后 `tick == 0`，canAdvance=true
- Review：启动后 `tick == record.finalTick`，canAdvance=false（**不是 `maxTick`**，v1.1 验收文字已修正）
- Replay：启动后 `tick == 0`，使用原局 feeSnapshot，结束不保存

### E5 训练引擎模块（v1.3 L2 拆分：E5 只保留运行时，持久化移至 E6）

**v1.3 关键修订**（解 P0-2 + P1-3）：
- E5 `TrainingEngine` 不再承担持久化与 session 生命周期（不再有 `saveProgress` / `finalize`）；这些职责迁移至新增的 **E6 `TrainingSessionCoordinator`**
- E5 只负责运行时状态：tick / position / markers / drawings / panels / 交易动作 / 减速动画 / scenePhase 中继
- U1 / U2 不再直接构造 `TrainingEngine`，改为通过 E6 Coordinator 获得运行时

```swift
@MainActor
@Observable
final class TrainingEngine {
    private(set) var tick: TickEngine
    private(set) var position: PositionManager
    private(set) var cashBalance: Double                  // v1.3 新增：运行时现金余额
    private(set) var drawdown: DrawdownAccumulator        // v1.3 新增：peak/maxDD 实时累计
    private(set) var markers: [TradeMarker]
    private(set) var drawings: [DrawingObject]
    private(set) var upperPanel: PanelViewState
    private(set) var lowerPanel: PanelViewState
    private(set) var tradeOperations: [TradeOperation]    // v1.3：暴露给 E6 finalize 打包
    let flow: TrainingFlowController
    let allCandles: [Period: [KLineCandle]]
    let fees: FeeSnapshot
    let initialCapital: Double                            // v1.3 新增：启动时资金（用于 drawdown 初始化）
    private let animators: (upper: DecelerationAnimator, lower: DecelerationAnimator)

    init(flow: TrainingFlowController,
         allCandles: [Period: [KLineCandle]],
         maxTick: Int,
         initialCapital: Double,                          // v1.3 新增参数
         initialCashBalance: Double,                      // v1.3 新增参数
         initialPosition: PositionManager = .init(),
         initialMarkers: [TradeMarker] = [],
         initialDrawings: [DrawingObject] = [],
         initialTradeOperations: [TradeOperation] = [],   // v1.3 新增参数
         initialDrawdown: DrawdownAccumulator = .initial) { /* ... */ }

    func buy(panel: PanelId, tier: PositionTier) -> Result<TradeOperation, AppError>
    func sell(panel: PanelId, tier: PositionTier) -> Result<TradeOperation, AppError>
    func holdOrObserve(panel: PanelId)
    func switchPeriodCombo(direction: PeriodDirection)
    func activateDrawingTool(_: DrawingToolType)
    func deleteDrawing(at: Int)

    /// 场景生命周期入口（由 U2 TrainingView 顶层 .onChange(of: scenePhase) 触发）
    func onSceneActivated() {
        animators.upper.resetOnSceneActive()
        animators.lower.resetOnSceneActive()
    }

    // v1.3 删除：saveProgress / finalize 迁移到 E6 Coordinator

    var currentTotalCapital: Double { get }
    var holdingCost: Double { get }
    var returnRate: Double { get }
    var maxDrawdown: Double { drawdown.maxDrawdown }      // v1.3：直接读 accumulator
    var buyEnabled: Bool { get }
    var sellEnabled: Bool { get }
}

// v1.3：E6 TrainingSessionCoordinator —— 会话生命周期编排
// 依赖 P3a / P4 三 Repo / P5 CacheManager / P6 SettingsStore
@MainActor
@Observable
final class TrainingSessionCoordinator {
    private let dbFactory: TrainingSetDBFactory         // P3a
    private let recordRepo: RecordRepository            // P4
    private let pendingRepo: PendingTrainingRepository  // P4
    private let settingsDAO: SettingsDAO                // P4
    private let cache: CacheManager                     // P5
    private let settings: SettingsStore                 // P6

    // 当前活跃 session 的运行时引用（U2 通过 @Environment 或 init 注入到 TrainingView）
    private(set) var activeEngine: TrainingEngine?
    private(set) var activeReader: TrainingSetReader?   // 保证 reader 生命周期与 session 对齐

    init(dbFactory: TrainingSetDBFactory,
         recordRepo: RecordRepository,
         pendingRepo: PendingTrainingRepository,
         settingsDAO: SettingsDAO,
         cache: CacheManager,
         settings: SettingsStore)

    /// 开始新 Normal 训练：随机选训练组 → 打开 reader → 打包 fees → 构造 engine
    func startNewNormalSession() async throws -> TrainingEngine

    /// 继续中断训练：loadPending → 按 filename 打开 reader → 从 pending 恢复 engine
    func resumePending() async throws -> TrainingEngine?  // 无 pending 返回 nil

    /// Review 模式：record → 打开 reader → 构造 ReviewFlow engine
    func review(recordId: Int64) async throws -> TrainingEngine

    /// Replay 模式：record → 打开 reader → 构造 ReplayFlow engine（只继承 fees）
    func replay(recordId: Int64) async throws -> TrainingEngine

    /// 保存进度（U2 退出时 / 每 N tick 自动调用）
    func saveProgress(engine: TrainingEngine) async throws

    /// 正式结束：构造 TrainingRecord + TradeOperations + Drawings，插入 record，清 pending
    /// 返回插入的 recordId（用于跳 Settlement）；若 flow.shouldSaveRecord() == false 返回 nil
    func finalize(engine: TrainingEngine) async throws -> Int64?

    /// session 结束清理（关闭 reader）
    func endSession() async
}

// v1.2：Preview Fixture（取代 MockTrainingEngine 概念）
// v1.3：TrainingEnginePreviewFactory 前移 Wave 0；init 增参数；Coordinator 也有对应 preview
#if DEBUG
extension TrainingEngine {
    static func preview(mode: TrainingMode = .normal) -> TrainingEngine {
        let flow: TrainingFlowController = switch mode {
            case .normal: NormalFlow(fees: .preview, maxTick: 1000)
            case .review: ReviewFlow(record: .previewRecord)
            case .replay: ReplayFlow(feeSnapshotFromOriginal: .preview, maxTick: 1000)
        }
        return TrainingEngine(
            flow: flow,
            allCandles: KLineCandle.previewFixture,
            maxTick: 1000,
            initialCapital: 100_000,
            initialCashBalance: 100_000
        )
    }
}

extension TrainingSessionCoordinator {
    static func preview() -> TrainingSessionCoordinator {
        TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(),          // 见 §十一 Fixture 清单
            recordRepo: InMemoryRecordRepository(),
            pendingRepo: InMemoryPendingTrainingRepository(),
            settingsDAO: InMemorySettingsDAO(),
            cache: InMemoryCacheManager(),
            settings: SettingsStore.preview()
        )
    }
}

extension KLineCandle {
    static let previewFixture: [Period: [KLineCandle]] = { ... }()
}

extension FeeSnapshot {
    static let preview = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false)
}

extension TrainingRecord {
    static let previewRecord: TrainingRecord = ...
}
#endif
```

---

## 八、iOS 持久化模块（8 个顶层 + 4 个 P2 内部端口；v1.3 重构）

**v1.3 总览变化**：
- P2 顶层仍为 `DownloadAcceptanceRunner`；新增 4 个内部 public protocol 作为可替换端口（Mock/测试/替换用）
- P3 拆为 P3a `TrainingSetDBFactory` + P3b `TrainingSetReader`（解 P0-5）
- P4 对外暴露 3 个 public protocol：`RecordRepository` + `PendingTrainingRepository` + `SettingsDAO`，composition root 用 `typealias AppDB`；共享单一 `DatabaseQueue`
- P4 新增 `AcceptanceJournalDAO`（对应 §三 M0.1 `download_acceptance_journal` 表）



### P1 APIClient `Services/APIClient.swift`

```swift
protocol APIClient {
    func fetchMeta(count: Int) async throws -> LeaseResponse      // throws AppError
    func downloadTrainingSet(id: Int) async throws -> URL
    func confirm(id: Int, leaseId: String) async throws
}

final class DefaultAPIClient: APIClient {
    // 内部：URLSession 后台线程
    // 私有 URLError/HTTPStatus 转 AppError.network
}
```

### P2 下载验收状态机 `Services/DownloadAcceptance/`（v1.3 runner + 4 内部端口）

```swift
enum AcceptanceResult: Sendable {
    case confirmed(TrainingSetFile)
    case rejected(AppError)
}

// v1.3 新增：4 个可替换内部端口（public protocol）供测试 / Mock / 替换实现

protocol ZipIntegrityVerifying {
    /// 校验 zipURL 的 CRC32 是否等于 expectedCRC32Hex（8 字符小写）
    /// 不匹配 → throw AppError.trainingSet(.crcFailed)
    func verify(zipURL: URL, expectedCRC32Hex: String) throws
}

protocol ZipExtracting {
    /// 解压到临时目录并返回 sqlite 文件 URL
    /// 失败 → throw AppError.trainingSet(.unzipFailed)
    func extract(zipURL: URL) throws -> URL
}

protocol TrainingSetDataVerifying {
    /// 通过 P3b reader 校验训练组非空、各周期 candle 数量合理
    /// 失败 → throw AppError.trainingSet(.emptyData)
    func verifyNonEmpty(reader: TrainingSetReader) throws
}

protocol DownloadAcceptanceCleaning {
    /// 清理一组临时 URL（解压目录、下载 zip 等）
    /// 非致命：失败只打日志，不抛
    func cleanup(tempURLs: [URL])
}

// v1.3 顶层编排：runner 注入全部端口，按 journal 状态驱动
final class DownloadAcceptanceRunner {
    init(api: APIClient,                                   // P1
         cache: CacheManager,                              // P5
         dbFactory: TrainingSetDBFactory,                  // P3a（不是 v1.2 的整个 P3）
         journal: AcceptanceJournalDAO,                    // v1.3 新增（P4 提供）
         integrity: ZipIntegrityVerifying,                 // v1.3 内部端口 1
         extractor: ZipExtracting,                         // v1.3 内部端口 2
         dataVerifier: TrainingSetDataVerifying,           // v1.3 内部端口 3
         cleaner: DownloadAcceptanceCleaning)              // v1.3 内部端口 4

    func run(meta: TrainingSetMetaItem, leaseId: String) async -> AcceptanceResult
    func runBatch(lease: LeaseResponse, concurrency: Int = 1) async -> [AcceptanceResult]

    /// App 启动时扫描 stored + confirmPending 记录，重试 confirm（v1.3 修订）
    /// - 覆盖两类 state：stored（已落盘未 confirm）+ confirmPending（confirm 已发起但不确定）
    /// - 成功 → confirmed；409/404 → rejected + 清理；网络不确定 → 停留/转 confirmPending
    func retryPendingConfirmations() async
}
```

**v1.3 内部流程**（按 journal 状态推进，确保崩溃恢复）：

| 步骤 | journal state 推进 | 失败分支 |
|---|---|---|
| 0. `api.fetchMeta` 后记录 lease | `leased` | 直接返回 rejected |
| 1. `api.downloadTrainingSet` | → `downloaded` | rejected（网络）|
| 2. `integrity.verify(zipURL:)` | → `crcOK` | rejected(.crcFailed) + cleanup |
| 3. `extractor.extract(zipURL:)` | → `unzipped` | rejected(.unzipFailed) + cleanup |
| 4. `dbFactory.openAndVerify(...)` | → `dbVerified` | rejected(.versionMismatch) + cleanup |
| 5. `dataVerifier.verifyNonEmpty(reader:)` | 保持 `dbVerified` | rejected(.emptyData) + cleanup |
| 6. `cache.store(...)` | → `stored`，写 sqlite_local_path | rejected(persistence) |
| 7. `api.confirm(id:leaseId:)` | 成功 → `confirmed`；409/404 → `rejected`；网络不确定 → `confirmPending` | 见下 |

**崩溃恢复与 confirmPending 重试**（v1.3 闸门 #1 F3 修订，解 P0-4 + stored 崩溃孤立）：
- 停留 `stored` / `confirmPending` 的记录均不清理本地 sqlite 文件
- App 启动扫 `stored ∪ confirmPending` → 用原 `lease_id` 调/重试 confirm
- 成功 → `confirmed`；收到 409/404 → `rejected` 才清理本地文件
- 网络仍不确定 → `stored` 行转 `confirmPending`；已在 `confirmPending` 行保持
- 验收用例：
  1. `stored` 后进程 kill → 启动 → journal = confirmed + 本地 sqlite 保留
  2. `confirmPending` 状态下进程 kill → 启动 → 若网络恢复则 confirmed，否则仍 confirmPending

### P3 训练组数据库（v1.3 拆 P3a Factory / P3b Reader）

**v1.3 关键修订**（解 P0-5）：原 `protocol TrainingSetDB` 把"打开文件"和"读取数据"混在一个状态化协议里；v1.3 拆为无状态工厂 + 有状态 reader。

#### P3a `Services/TrainingSetDBFactory.swift`

```swift
protocol TrainingSetDBFactory {
    /// 打开训练组 sqlite 文件并校验 schema_version / 基本元数据
    /// - expectedSchemaVersion: 预期 schema 版本（M0.1 TRAINING_SET_SCHEMA_VERSION = 1）
    /// - throws AppError.trainingSet(.versionMismatch) / .fileNotFound / .emptyData
    /// - 返回绑定到独立 DatabaseQueue 的 reader（每次调用产生新 reader 实例）
    func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader
}

final class DefaultTrainingSetDBFactory: TrainingSetDBFactory {
    // 无状态：每次调用 openAndVerify → 创建新 DatabaseQueue → 返回 Reader
}
```

#### P3b `Services/TrainingSetReader.swift`

```swift
protocol TrainingSetReader: AnyObject, Sendable {
    /// 从已 openAndVerify 的 sqlite 加载元数据
    func loadMeta() throws -> TrainingSetMeta
    /// 加载全部周期 candles
    func loadAllCandles() throws -> [Period: [KLineCandle]]
    /// 关闭 reader（释放 DatabaseQueue）；调用方应在 session 结束时调用
    func close()
}

final class DefaultTrainingSetReader: TrainingSetReader {
    // 实现约束：每个 reader 实例持有独立 DatabaseQueue（对应一个训练组文件）
    // 生命周期与 TrainingSessionCoordinator 的 activeReader 对齐
}
```

**Reader 生命周期规则**（解 P0-5 DB handle 共享）：
- 每个训练组文件对应独立 reader 实例（与 M0.5 `DatabaseQueue` 约定一致）
- reader 不跨 session 复用；并发验收 A/B 文件 → 两个独立 reader，不会相互覆盖
- session 结束 → coordinator 调用 `reader.close()` 释放

### P4 应用数据库 `Services/AppDB/`（v1.3 对外 3 public protocol + typealias；+ AcceptanceJournalDAO）

**v1.3 关键修订**：原单一 `protocol AppDB` 把 record / pending / settings 全塞在一个端口，违反 §零原则 4（独立验收 Mock 粒度过大）。v1.3 拆成 3 个 public protocol，共享单一 `DatabaseQueue`；composition root 用 `typealias` 合成。

```swift
// —— 3 个独立职责 protocol（v1.3 拆分）——

protocol RecordRepository: Sendable {
    func insertRecord(_: TrainingRecord,
                     ops: [TradeOperation],
                     drawings: [DrawingObject]) throws -> Int64
    func listRecords(limit: Int?) throws -> [TrainingRecord]
    func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject])
    func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double)
}

protocol PendingTrainingRepository: Sendable {
    func savePending(_: PendingTraining) throws
    func loadPending() throws -> PendingTraining?
    func clearPending() throws
}

protocol SettingsDAO: Sendable {
    func loadSettings() throws -> AppSettings
    func saveSettings(_: AppSettings) throws
    func resetCapital() throws
}

// —— v1.3 新增：下载验收 journal DAO（对应 M0.1 download_acceptance_journal 表）——

protocol AcceptanceJournalDAO: Sendable {
    /// 按 (training_set_id, lease_id) upsert 状态
    func upsert(trainingSetId: Int, leaseId: String,
                state: P2JournalState,
                sqliteLocalPath: String?,
                contentHash: String?,
                lastError: String?) throws
    /// 列出指定 state 的全部行（App 启动扫 confirmPending）
    func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow]
    /// 清理 rejected 行（可选）
    func deleteByIdLease(trainingSetId: Int, leaseId: String) throws
}

enum P2JournalState: String, Codable, Sendable {
    case leased
    case downloaded
    case crcOK
    case unzipped
    case dbVerified
    case stored
    case confirmPending
    case confirmed
    case rejected
}

struct AcceptanceJournalRow: Sendable {
    let id: Int64
    let trainingSetId: Int
    let leaseId: String
    let state: P2JournalState
    let stateEnteredAt: Int64
    let lastError: String?
    let sqliteLocalPath: String?
    let contentHash: String?
}

// —— composition root：单实现组合全部 protocol ——
typealias AppDB = RecordRepository & PendingTrainingRepository & SettingsDAO & AcceptanceJournalDAO

final class DefaultAppDB: AppDB {
    // 唯一 GRDB DatabaseQueue for app.sqlite
    // 单实现同时满足 4 个 protocol；所有读写串行化（§三 M0.5）
    init(dbPath: URL)
}
```

**v1.3 并发约束**（延续 v1.2）：
- 单一 GRDB `DatabaseQueue` for app.sqlite（共享给全部 4 个 protocol 的实现方法）
- 读写均通过 queue 串行化；调用方可跨线程；结果回 MainActor 更新 @Observable
- 不使用 `DatabasePool`

**Mock 粒度**（v1.3 收益）：
- `SettingsStore` 只依赖 `SettingsDAO`，Mock 三个方法即可
- `TrainingSessionCoordinator` 依赖 `RecordRepository + PendingTrainingRepository`，不需要 Mock settings 路径
- P2 `DownloadAcceptanceRunner` 只依赖 `AcceptanceJournalDAO`

### P5 缓存管理 `Services/CacheManager.swift`

```swift
protocol CacheManager {
    func listAvailable() -> [TrainingSetFile]
    func pickRandom() -> TrainingSetFile?
    func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile
    func touch(_: TrainingSetFile)
    func delete(_: TrainingSetFile) throws
}

final class FileSystemCacheManager: CacheManager {
    static let maxCachedSets = 20

    // 内部：
    // - store() = 临时文件 → rename 原子 → 更新 lastAccessedAt → 自动 evict 到 ≤ 20
    // - 串行队列处理，防止并发写同一路径
}
```

### P6 设置存储 `Services/SettingsStore.swift`（v1.3 commissionRate 小数率边界）

```swift
@MainActor
@Observable
final class SettingsStore {
    private(set) var settings: AppSettings                // settings.commissionRate 永远是小数率（0.0001 = 万一）

    // v1.3：依赖收窄到 SettingsDAO 而不是整个 AppDB
    init(settingsDAO: SettingsDAO)
    func update(_ mutate: (inout AppSettings) -> Void) async throws
    func resetCapital() async throws
    func snapshotFees() -> FeeSnapshot                   // v1.2：Coordinator.startNewNormalSession 内部调用
}

// v1.3：UI 层边界转换（U4 SettingsPanel 内实现，非 SettingsStore 职责）
/// UI 输入"万分之一"整数 → 存储小数率
/// 例：UI 输入 "1" → commissionRate = 0.0001
func commissionRate(fromUIInputTenThousandth x: Double) -> Double { x * 0.0001 }

/// 存储小数率 → UI 显示"万分之一"整数
/// 例：commissionRate = 0.0001 → UI 显示 "1"
func uiDisplayTenThousandth(fromCommissionRate r: Double) -> Double { r * 10000 }

// 强约束：SettingsStore.settings.commissionRate 读取或写入均为小数率；
// UI 层只在显示 / input 绑定处做一次乘除 10000 的转换。
// E3 TradeCalculator / E5 TrainingEngine / P4 SettingsDAO 一律使用小数率。
```

---

## 九、iOS UI 模块（6 个）

### U1 首页 `HomeView.swift`（v1.3 改依赖 TrainingSessionCoordinator）

```swift
struct HomeView: View {
    // v1.3：不再直接注入 db / cache / api，统一通过 coordinator + acceptance
    init(coordinator: TrainingSessionCoordinator,       // E6：新训练 / 继续 / review / replay 入口
         settings: SettingsStore,                       // P6：设置读取、fees 打包保留在 coordinator.startNewNormalSession 内部
         acceptance: DownloadAcceptanceRunner)          // P2：手动触发下载、App 启动 retry pending
}

// 启动 Normal 训练（v1.3）：
// let engine = try await coordinator.startNewNormalSession()
// pushToTrainingView(engine: engine)
//
// 继续中断训练（v1.3）：
// if let engine = try await coordinator.resumePending() {
//     pushToTrainingView(engine: engine)
// }
//
// fees 打包现在由 coordinator.startNewNormalSession 内部调用 settings.snapshotFees()，
// U1 不再直接拼装 flow / engine。
```

### U2 训练页 `TrainingView.swift`（v1.2 scenePhase 监听确认）

```swift
struct TrainingView: View {
    let engine: TrainingEngine
    let onExit: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        mainContent
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    engine.onSceneActivated()     // v1.2：scene → engine → animator 唯一链路
                }
            }
    }
}
```

**v1.2 关键**：scene 监听**只在 U2 顶层**；C8 不再监听；E5 仅做中继；C2 仅执行 reset。

### U3 结算弹窗 `SettlementView.swift`

```swift
struct SettlementView: View {
    init(record: TrainingRecord, onConfirm: () -> Void)
}
```

### U4 设置面板 `SettingsPanel.swift`

```swift
struct SettingsPanel: View {
    init(settings: SettingsStore, api: APIClient,
         cache: CacheManager, acceptance: DownloadAcceptanceRunner)
}

// 无印花税开关（v1.1 起保持）
```

### U5 仓位选择 HUD `PositionPickerView.swift`

```swift
struct PositionPickerView: View {
    init(enabledTiers: Set<PositionTier>,
         onPick: (PositionTier) -> Void,
         onCancel: () -> Void)
}
```

### U6 历史动作表 `HistoryActionSheet.swift`

```swift
struct HistoryActionSheet: View {
    init(record: TrainingRecord,
         onReview: () -> Void,
         onReplay: () -> Void,
         onCancel: () -> Void)
}
```

**UI 层 Mock 策略**（v1.2 修订）：**不使用 Mock 类**。所有 UI Preview 通过 `TrainingEngine.preview()` / `SettingsStore.preview()` 等便利构造器 + Fixture 数据，保持与 Swift 6 `@Observable` 的 ObservationRegistrar 追踪兼容。

---

## 十、并行开发波次（v1.2 调整）

### Wave 0：契约冻结（串行，1 人 ~2 周，v1.3 从 1.5 周再调整）

**v1.3 Wave 0 新增交付项**（对应 Round 3 Part B）：C1 三件拆分、E6 Coordinator 契约、TrainingEnginePreviewFactory 前移、P2 4 内部端口、P3a Factory + P3b Reader、P4 3 Repo + AcceptanceJournalDAO、CONTRACT_VERSION 矩阵、migration rollback 策略、Sendable 清单、fixture / Mock ports 清单。

- [ ] **M0.1** 三套 DB schema（含 v1.2 lease 三列、final_tick 列、UNIQUE 约束；**v1.3**：`content_hash CHAR(8)` + `download_acceptance_journal` 表 + migration/rollback 文件 + `CONTRACT_VERSION` 矩阵）
- [ ] **M0.2** OpenAPI 文档（lease_id query、409/404、CRC32 hash 长度精确 8）
- [ ] **M0.3** Swift 模型完整实现（Codable/Equatable round-trip + **Sendable** + fixture；v1.3：`DrawdownAccumulator` + `PendingTraining.cashBalance/drawdown` + `TradeOperation.positionTier: PositionTier`）
- [ ] **M0.4** AppError + 所有 Reason 标 `Error, Sendable` + 边界翻译表
- [ ] **M0.5** @MainActor 清单 + GRDB DatabaseQueue 约定 + **Sendable 清单**（v1.3）
- [ ] **F1** Swift 模型实现 + 测试
- [ ] **F2** Theme 框架 + 默认颜色常量
- [ ] **C1 三件拆分完整交付**（v1.3 拆 C1a/C1b/C1c 全部在 Wave 0）：
  - **C1a Geometry**：`ChartGeometry / ChartPanelFrames / PriceRange / ChartViewport / CoordinateMapper / IndicatorMapper / NonDegenerateRange`（v1.3 新）
  - **C1b Reducer**：`PanelViewState(含 revision) / FrozenPanelState(含 baseRevision) / DrawingSnapshot / ChartInteractionMode / ChartAction(drawingCommitted/Cancelled 带 baseRevision) / ChartReduceEffect(含 stalePanelRevision) / 完整 3×7 reduce 实现`
  - **C1c Render**：`KLineView / KLineRenderState(volumeRange/macdRange 为 NonDegenerateRange)`
  - C3-C6 的 drawXxx extension 方法签名 + **空 stub 实现**（真正实现放 Wave 1）
  - 单元测试：坐标映射 / PriceRange / reducer 21 格矩阵 / NonDegenerateRange.make 退化值覆盖 / revision 单调性 / stalePanelRevision 场景 / renderState Equatable 短路
- [ ] **E6 TrainingSessionCoordinator 契约** + init 签名 + preview() Fixture（v1.3）
- [ ] **TrainingEnginePreviewFactory** 前移 Wave 0（v1.3；原 Wave 1）
- [ ] **P2 4 内部端口**（`ZipIntegrityVerifying` / `ZipExtracting` / `TrainingSetDataVerifying` / `DownloadAcceptanceCleaning`）协议定义 + 空 stub（v1.3）
- [ ] **P3a TrainingSetDBFactory** + **P3b TrainingSetReader** 协议（v1.3）
- [ ] **P4 三 Repo**（`RecordRepository` / `PendingTrainingRepository` / `SettingsDAO`）+ `AcceptanceJournalDAO` + `typealias AppDB` 组合（v1.3）

### Wave 1：并行开发（最多 10 人/组）

**后端（2 人）**
- [ ] B1 import_csv
- [ ] B2 generate_training_sets（含函数式 API + CRC32）
- [ ] B3 FastAPI（含 lease 状态机）
- [ ] B4 APScheduler

**图表核心（2 人）**
- [ ] C2 DecelerationAnimator
- [ ] C7 Gesture Arbiter（含 classifyTwoFingerGesture + classifySingleFingerPan + panPolicyInDrawingMode）

**图表渲染（2-3 人，可切片）**
- [ ] C3 Candles + MA66 + BOLL（实现）
- [ ] C4 Volume + MACD（实现，用 IndicatorMapper）
- [ ] C5 Crosshair + Markers（二分谓词精确）
- [ ] C6 DrawingTools + DrawingInputController（Phase 2.5 水平线先行）

**业务逻辑（1-2 人）**
- [ ] E1 TickEngine
- [ ] E2 PositionManager
- [ ] E3 TradeCalculator（Result with Error）
- [ ] E4 TrainingFlowController

**持久化（1-2 人）**
- [ ] P1 APIClient（lease_id / AppError）
- [ ] P3 TrainingSetDB（DatabaseQueue）
- [ ] P4 AppDB（DatabaseQueue）
- [ ] P5 CacheManager（CRC32 / 自动 evict）
- [ ] P6 SettingsStore（snapshotFees）

**UI 壳（1 人，Preview Fixture）**
- [ ] U3 SettlementView
- [ ] U5 PositionPickerView
- [ ] U6 HistoryActionSheet
- [ ] ~~`TrainingEngine.preview()` + `SettingsStore.preview()` Fixture 数据~~（v1.3：前移至 Wave 0；此处不再占位）

### Wave 2：集成

- [ ] C8 ChartContainerView（纯桥接；computes volumeRange/macdRange 用 `NonDegenerateRange.make` 注入 renderState）
- [ ] E5 TrainingEngine（含 onSceneActivated；v1.3 init 增 `initialCapital/initialCashBalance/initialTradeOperations/initialDrawdown` 参数）
- [ ] **E6 TrainingSessionCoordinator** 实现（v1.3 新）
- [ ] P2 DownloadAcceptanceRunner 及 4 内部端口默认实现 + `retryPendingConfirmations`（v1.3）
- [ ] P4 `DefaultAppDB` 实现（组合 4 个 protocol + `AcceptanceJournalDAO`）
- [ ] U1 HomeView（依赖 `TrainingSessionCoordinator` + `DownloadAcceptanceRunner`）
- [ ] U2 TrainingView（顶层 scenePhase 监听；drawingCommitted/Cancelled 派发 baseRevision）
- [ ] U4 SettingsPanel（v1.3：commissionRate UI 边界乘除 10000）

### Wave 3：端到端

- [ ] Phase 2.5 水平线 MVP
- [ ] Phase 3 完整流程（normal/review/replay）
- [ ] Phase 5 性能 + 夜间模式 + 边界

---

## 十一、契约冻结 Checklist（v1.2 交付清单）

### 后端↔前端
- [ ] `backend/openapi.yaml` 三接口完整 schema（lease_id query 参数、幂等、409/404、**CRC32 hash**）
- [ ] `backend/sql/schema.sql` 含 v1.2 `training_sets` 3 列 + `UNIQUE(stock_code, start_datetime)`
- [ ] `backend/sql/training_set_schema_v1.sql` + 示例 zip（附 CRC32 验证脚本）
- [ ] `ios/sql/app_schema_v1.sql` 含 `final_tick` 列
- [ ] `TRAINING_SET_SCHEMA_VERSION = 1` 双方共享常量
- [ ] 时区约定（Unix 秒 UTC，UI 转北京时间）
- [ ] `settings` 表 key 列表**不含** `stamp_duty_enabled`

### iOS 内部
- [ ] `Models/` 所有类型 + **完整 CodingKeys** + Codable round-trip 测试 + **Sendable**（v1.3）
- [ ] `AppError` + 所有 `Reason` 枚举 `: Error, Equatable, Sendable`（v1.3）（含 `case internalError(module, detail)`）
- [ ] M0.4 翻译表（本模块边界内转 AppError）
- [ ] `@MainActor` 清单：E5/E6/P6/F2/C6 DrawingToolManager（v1.3 增 E6）
- [ ] Preview Fixture 清单（取代 Mock 清单）：
  - [ ] `TrainingEngine.preview(mode:)`
  - [ ] `TrainingSessionCoordinator.preview()`（v1.3）
  - [ ] `SettingsStore.preview()`
  - [ ] `KLineCandle.previewFixture`
  - [ ] `FeeSnapshot.preview`
  - [ ] `TrainingRecord.previewRecord`
- [ ] **Test Fixture Ports 清单**（v1.3 新增，对应各 protocol 的 in-memory fake）：
  - [ ] `InMemoryRecordRepository`
  - [ ] `InMemoryPendingTrainingRepository`
  - [ ] `InMemorySettingsDAO`
  - [ ] `InMemoryAcceptanceJournalDAO`
  - [ ] `PreviewTrainingSetDBFactory` + `PreviewTrainingSetReader`
  - [ ] `InMemoryCacheManager`
  - [ ] `FakeZipIntegrityVerifier`（固定返回 OK / 失败）
  - [ ] `FakeZipExtractor`
  - [ ] `FakeTrainingSetDataVerifier`
  - [ ] `FakeDownloadAcceptanceCleaner`
  - [ ] `FakeAPIClient`（驱动 lease/download/confirm 各分支的 stub）
- [ ] 颜色常量清单（含夜间模式）

### 引擎契约
- [ ] **KLineView 本体**（C1c）+ `KLineRenderState`（v1.3：volumeRange/macdRange 为 `NonDegenerateRange`）+ `ChartPanelFrames`
- [ ] **非递归 `FrozenPanelState`**（v1.3：含 `baseRevision`）+ `DrawingSnapshot`
- [ ] 所有 C1a/C1b/C1c 值类型 **`Equatable, Sendable`**（v1.3）
- [ ] **reducer 完整 3×7 矩阵** + 非法 assertionFailure 测试 + **revision 单调性测试** + **stalePanelRevision 测试**（v1.3）
- [ ] **`IndicatorMapper`**（C1a）独立类型 + `NonDegenerateRange` 外部注入
- [ ] **`NonDegenerateRange.make`** 覆盖空 / 全零 / 单值 fallback 测试（v1.3）
- [ ] **`classifyTwoFingerGesture`** + **`classifySingleFingerPan`** + **`panPolicyInDrawingMode`** 纯函数
- [ ] **`DrawingInputController`** 接口
- [ ] **marker 二分谓词** 精确函数
- [ ] **`onSceneActivated()`** 在 E5 + `resetOnSceneActive()` 在 C2
- [ ] **E6 Coordinator 契约**：`startNewNormalSession / resumePending / review / replay / saveProgress / finalize / endSession`（v1.3）
- [ ] **P3a `TrainingSetDBFactory.openAndVerify(file:expectedSchemaVersion:)`** 签名（v1.3）
- [ ] **P3b `TrainingSetReader` protocol**（loadMeta / loadAllCandles / close）（v1.3）
- [ ] **P4 三 Repo + AcceptanceJournalDAO + typealias AppDB**（v1.3）
- [ ] **P2 4 内部端口** + `runner.run` 对应 journal state 推进（v1.3）
- [ ] **P2 `retryPendingConfirmations`** App 启动扫 confirmPending（v1.3）

### 工程化
- [ ] SPM/CocoaPods + GRDB 版本锁定
- [ ] Xcode Target/Group 按 35 顶层模块划分（v1.3：原 31 → 35）
- [ ] CI：单元测试 + pytest + OpenAPI 校验 + `@MainActor` Threading Checker + **Swift strict concurrency（complete）**（v1.3）
- [ ] CI lint：禁止直接使用 `AppError.internalError` 之外的捕获所有错误
- [ ] CI assert：`CONTRACT_VERSION` 常量与 M0.1 矩阵同步（v1.3）

---

## 十二、风险点（v1.2 扩充至 37 项）

| # | 风险 | 级别 | 缓解 | Owner |
|---|---|---|---|---|
| R01 | DecelerationAnimator 后台恢复 | P2 | resetOnSceneActive + dt>1s 直接停；U2→E5→C2 责任链 | U2/E5/C2 |
| R02 | PriceRange 与 BOLL/MA66 协调 | P2 | calculate 含指标极值 + 5% padding | C1 |
| R03 | 后端 Index 预计算一致性 | P1 | global_index/end_global_index 严格递增 + 前后端 assert | B2/P3 |
| R04 | A 股异常数据 | P2 | 后端 pandas 清洗 | B1 |
| R05 | CSV 数据量 | P2 | import_csv 异步批处理 | B1 |
| R06 | 训练组 SQLite 完整性 | P1 | 完整验收状态机 | P2 |
| R07 | 训练组版本兼容 | P2 | schema_version 不匹配拒收删除 | P3 |
| R08 | NAS 不可达 | P2 | 纯离线模式 + AppError 统一 Toast | P1/U4 |
| R09 | 1 分钟 index 基准 | P2 | 数据源必须含 1m CSV | B1 |
| R10 | lease_id 前后端分叉 | P0→修复 | M0.1 DDL 3 列 + OpenAPI 强制 query | B3/P1 |
| R11 | KLineCandle CodingKeys 不一致 | P0→修复 | F1 完整 CodingKeys + CI round-trip | F1 |
| R12 | KLineView 本体归属 | P1→修复 | C1 Wave 0 完整交付 | C1 |
| R13 | 三态转换不一致 | P1→修复 | reducer 3×7 矩阵 + assertionFailure | C1 |
| R14 | Volume/MACD 误用主图 mapper | P1→修复 | IndicatorMapper 独立 | C4 |
| R15 | marker 二分谓词错位 | P1→修复 | findCandleIndex 精确函数 + 测试 | C5 |
| R16 | Review 模式初始化歧义 | P1→修复 | initialTick/allowedTickRange + final_tick 列 | E4/M0.1 |
| R17 | B4→B2 进程一致性 | P1→修复 | 同进程函数式 API | B4 |
| R18 | 并发下载 GRDB/FS 竞态 | P1→修复 | DatabaseQueue + rename 原子 | P4/P5 |
| R19 | C8 @Observable→UIKit 刷新丢失 | P2 | KLineRenderState 值类型下发 + Equatable 短路 | C8 |
| R20 | scenePhase 责任空缺 | P2→修复 | U2 顶层监听 → E5 → C2 单一链路 | U2/E5/C2 |
| R21 | @MainActor 漏标致线程撕裂 | P2 | M0.5 清单 + CI Threading Checker | M0.5 |
| R22 | 错误语义混用 | P1→修复 | M0.4 翻译规则 + lint | M0.4 |
| R23 | stampDutyEnabled 多处矛盾 | P1→修复 | 三处同步删除 | M0.1/M0.3 |
| R24 | B2 随机选点重复 | P2→修复 | UNIQUE(stock_code, start_datetime) | B2 |
| R25 | LRU 阈值归属不清 | P2→修复 | P5 内部常量 + 自动 evict | P5 |
| **R26** | **training_sets 表缺 lease 列**（v1.2） | **P0** | M0.1 扩 3 列 + 索引 + 状态机 | M0.1/B3 |
| **R27** | **training_records 表缺 final_tick**（v1.2） | **P0** | M0.1 扩 1 列 + E4 initialTick 对齐 | M0.1/E4 |
| **R28** | **C1 递归值类型编译失败**（v1.2） | **P0** | 拆 FrozenPanelState 非递归 + 全补 Equatable | C1 |
| **R29** | **Result Failure 不符合 Error**（v1.2） | **P0** | 所有 Reason 枚举 `: Error` | M0.4/E3 |
| **R30** | **M0.4 翻译表责任矛盾**（v1.2） | **P1** | 重写为"本模块边界内转" | M0.4 |
| **R31** | **reducer 转换表不完整**（v1.2） | **P1** | 3×7 完整矩阵 + 测试全覆盖 | C1 |
| **R32** | **Wave 0 C1 切片不可编译**（v1.2） | **P1** | C1 完整交付；C3-C6 仅空 stub | 十 |
| **R33** | **GRDB Queue/Pool 并存矛盾**（v1.2） | **P1** | 统一 DatabaseQueue，删 pool 表述 | M0.5/P4 |
| **R34** | **MockTrainingEngine 不可执行**（v1.2） | **P1** | 改 Preview Fixture 模式（非 protocol） | E5/U2 |
| **R35** | **IndicatorMapperBundle.make 值域藏在 draw**（v1.2） | **P2** | 值域外置到 KLineRenderState，C8 构造 | C1/C8 |
| **R36** | **NormalFlow.fees 打包时机不明**（v1.2） | **P2** | U1 启动时 SettingsStore.snapshotFees | U1/E4 |
| **R37** | **content_hash 跨平台字节不确定**（v1.2） | **P2** | 改用 zip CRC32 | M0.2/B2 |

---

## 十三、不单独成模块的决策

| 内容 | 理由 |
|---|---|
| 震动反馈 `UIImpactFeedbackGenerator` | 1 行调用，归 E5 或 U2 内部 |
| 颜色单个常量 | 归 F2 Theme 内 |
| BinarySearch 扩展 | 归 F1 通用工具区 |
| `KlineTrainerApp.swift` | App 入口 ~10 行，归 U1 组 |

---

## 十四、评审痕迹（v1.3 延续 v1.2 的一对一可核对表）

### 14.1 评审流程

```
v1.0（Claude 首次拆分）
   │
   │ 第 1 轮
   ▼
┌─────────────────────────────────────────────┐
│ Codex 对抗性评审：P0×3 / P1×10 / P2×3 = 16  │
│ Cloud 反评审：降级 5 / 归因 1 / 新增 5 = 11 │
└────────────┬────────────────────────────────┘
             ▼
v1.1（整合 21 项修订）
   │
   │ 第 2 轮
   ▼
┌─────────────────────────────────────────────┐
│ Codex 二次评审：P0×4 / P1×6 / P2×3 = 13     │
│ Cloud 反评审：接受 7 / 修正解法 1 / 驳降级 3 / 新增 4 = 15 │
│ 有效修订：16                                │
└────────────┬────────────────────────────────┘
             ▼
v1.2（整合共 37 项修订）
   │
   │ 第 3 轮（v1.3：codex adversarial + Claude 反挑战 3 轮辩论）
   ▼
┌─────────────────────────────────────────────┐
│ Round 1 codex：NO-SHIP；5 P0 + 6 P1 + 4 细拆│
│ Round 1 Claude 反挑战：根因收敛 + 4 未覆盖面│
│ Round 2 codex：A/B/C/D 4 条终判              │
│ Round 2 Claude：对 4 终判增量挑战            │
│ Round 3 codex：17 条 Part B 修订清单        │
│ Round 3 Claude：收敛，无阻塞性异议           │
│ 有效修订：17（落 v1.3）                     │
└────────────┬────────────────────────────────┘
             ▼
v1.3（累计 54 项修订）
```

### 14.2 修订逐项表

| # | 来源 | 原级别 | 最终级别 | 落位 | 摘要 |
|---|---|---|---|---|---|
| **— 第 1 轮 —** | | | | | |
| 01 | R1-Codex P0-1 | P0 | P0 | M0.2 | OpenAPI `confirm?lease_id=X` + 409/404 |
| 02 | R1-Codex P0-2 | P0 | P0 | M0.3 | KLineCandle 完整 CodingKeys |
| 03 | R1-Codex P0-3 | P0 | **P1** | C1 | KLineView 本体归入 C1（Cloud 降级） |
| 04 | R1-Codex P1-1 | P1 | P1 | C1 | 三态转换以 reducer 冻结 |
| 05 | R1-Codex P1-2 | P1 | **P2** | C7 | classifyTwoFingerGesture 纯函数（Cloud 降级） |
| 06 | R1-Codex P1-3 | P1 | P1 | C5 | endGlobalIndex >= globalTick 二分谓词 |
| 07 | R1-Codex P1-4 | P1 | P1 | C1/C4 | 副图独立 IndicatorMapper |
| 08 | R1-Codex P1-5 | P1 | **P2** | U2/E5 | sceneDidBecomeActive 责任链（Cloud 降级） |
| 09 | R1-Codex P1-6 | P1 | **P2** | C8 | KLineRenderState 值类型下发（Cloud 降级） |
| 10 | R1-Codex P1-7 | P1 | **P2** | M0.5 | @MainActor 标注（Cloud 降级） |
| 11 | R1-Codex P1-8 | P1 | P1 | M0.4 | AppError 统一错误处理 |
| 12 | R1-Codex P1-9 | P1 | P1 | M0.1/M0.3 | 删除 stampDutyEnabled（归因调整：锅在 v1.5） |
| 13 | R1-Codex P1-10 | P1 | **P2** | C6 | DrawingInputController（Cloud 降级） |
| 14 | R1-Codex P2-1 | P2 | P2 | Wave 0 | Mock 清单补全 |
| 15 | R1-Codex P2-2 | P2 | P2 | C1 | PanelViewState offset 唯一真值 |
| 16 | R1-Codex P2-3 | P2 | P2 | §十二 | 风险表扩充 |
| 17 | R1-Cloud-新增 | — | P1 | E4/E5 | TrainingFlowController.initialTick/allowedTickRange |
| 18 | R1-Cloud-新增 | — | P1 | B2/B4 | B2 函数式 API + B4 同进程调用 |
| 19 | R1-Cloud-新增 | — | P1 | P4/P5 | 并发下载 GRDB/FS 安全 |
| 20 | R1-Cloud-新增 | — | P2 | B2 | UNIQUE(stock_code, start_datetime) |
| 21 | R1-Cloud-新增 | — | P2 | P5 | maxCachedSets=20 + 自动 evict |
| **— 第 2 轮 —** | | | | | |
| 22 | R2-Codex P0-1 | P0 | P0 | M0.1 | training_sets 补 lease_id/lease_expires_at/reserved_at 三列 |
| 23 | R2-Codex P0-2 | P0 | P0 | M0.1/E4 | training_records 补 final_tick 列；E4 验收改 record.finalTick |
| 24 | R2-Codex P0-3 | P0 | P0 | C1 | DrawingSnapshot 拆非递归 FrozenPanelState + 全补 Equatable |
| 25 | R2-Codex P0-4 | P0 | P0 | M0.4/E3 | TradeReason 等 Reason 枚举标 Error |
| 26 | R2-Codex P1-1 | P1 | P1 | M0.4 | 翻译表责任重写（本模块边界内转） |
| 27 | R2-Codex P1-2 | P1 | P1 | C1 | reducer 补全 3×7 转换矩阵 |
| 28 | R2-Codex P1-3 | P1 | P1 | §十 | Wave 0 C1 完整交付 |
| 29 | R2-Codex P1-4 | P1 | **P2** | C8/U2 | scenePhase 责任链统一（Cloud 降级：文字一致性问题） |
| 30 | R2-Codex P1-5 | P1 | P1 | E5/U2 | Mock 改 Preview Fixture（Cloud 修正解法方向） |
| 31 | R2-Codex P1-6 | P1 | P1 | M0.5/P4 | 统一 DatabaseQueue 删 pool 表述 |
| 32 | R2-Codex P2-1 | P2 | P2 | C1/C8 | IndicatorMapper 值域外置到 renderState |
| 33 | R2-Codex P2-2 | P2 | P2 | C7 | 补 classifySingleFingerPan + drawingMode 规则 |
| 34 | R2-Codex P2-3 | P2 | P2 | §十四 | 评审痕迹重做为 37 行 |
| 35 | R2-Cloud-新增 | — | P2 | C1 | IndicatorMapperBundle.make 签名重构 |
| 36 | R2-Cloud-新增 | — | P2 | U1/P6 | NormalFlow.fees 打包时机明确（U1 + SettingsStore.snapshotFees） |
| 37 | R2-Cloud-新增 | — | P2 | M0.2/B2 | content_hash 改 zip CRC32 |
| (38) | R2-Cloud-新增 | — | P2 | M0.4 | AppError.unknown → internalError(module, detail) |
| **— 第 3 轮（v1.3）—** | | | | | |
| 38 | R3-P0-1 | P0 | P0 | C1b | reducer `PanelViewState.revision` + `FrozenPanelState.baseRevision` + action 携 baseRevision + `.stalePanelRevision` effect |
| 39 | R3-P0-2 | P0 | P0 | E5/E6 | E5 L2 拆分：TrainingEngine 运行时 + 新 E6 `TrainingSessionCoordinator`（start/resume/save/finalize/review/replay）|
| 40 | R3-P0-3 | P0 | P0 | M0.1/B2 | `training_sets.content_hash` 改 `CHAR(8) NOT NULL` CRC32 + migration 作废遗留 sha256 + B2 回迁策略 |
| 41 | R3-P0-4 | P0 | P0 | M0.1/P4/P2 | `download_acceptance_journal` 表 + `P2JournalState` 9 态 + `AcceptanceJournalDAO` + confirmPending 重试 |
| 42 | R3-P0-5 | P0 | P0 | P3 | 拆 P3a `TrainingSetDBFactory` + P3b `TrainingSetReader`（每文件独立 DatabaseQueue） |
| 43 | R3-P1-1 | P1 | P1 | M0.3/P6 | `commissionRate` 小数率注释闭合 + UI 边界乘除 10000 |
| 44 | R3-P1-2 | P1 | P1 | M0.3/E5 | 新增 `DrawdownAccumulator`；`PendingTraining` 增 `cashBalance` + `drawdown`；E5 暴露 tradeOperations |
| 45 | R3-P1-3 | P1 | P1 | U1 | HomeView 改依赖 `TrainingSessionCoordinator` + `DownloadAcceptanceRunner` |
| 46 | R3-P1-4 | P1 | P1 | §十 | `TrainingEnginePreviewFactory` + 相关 Fixture 前移至 Wave 0 |
| 47 | R3-P1-5 | P1 | P1 | C1a/C1c | `NonDegenerateRange` 替换 `ClosedRange<Double>` 副图值域 + `.make` 工厂保证非退化 |
| 48 | R3-P1-6 | P1 | P1 | M0.3 | `TradeOperation.positionTier: String` → `PositionTier` |
| 49 | R3-细拆-P4 | — | P1 | P4 | 对外 3 public protocol（`RecordRepository` / `PendingTrainingRepository` / `SettingsDAO`）+ `typealias AppDB`（争议 B Claude 赢）|
| 50 | R3-细拆-P2 | — | P1 | P2 | 顶层 runner + 4 内部 public protocol（争议 C Claude 赢）|
| 51 | R3-细拆-C1 | — | P1 | C1a/C1b/C1c | C1 拆 3 顶层模块 |
| 52 | R3-补齐-Version | — | P1 | M0.1 | 新增 `CONTRACT_VERSION` 矩阵（PostgreSQL/training_set/app.sqlite/Swift/P2 journal states）|
| 53 | R3-补齐-Rollback | — | P1 | M0.1/B3/P4 | migration rollback 规则 + owner 分配（B3 PostgreSQL / P4 app.sqlite / 训练组 SQLite 不 rollback）|
| 54 | R3-补齐-Sendable | — | P2 | M0.3/M0.4/M0.5 | 全部值类型 / AppError / 跨 actor 协议返回值 `Sendable` |
| 55 | R3-补齐-Fixture | — | P2 | §十一 | Test Fixture Ports 清单（in-memory fake） |

> **注**：v1.3 共 17 项 Part B 修订（R3-P0-1～P0-5 + P1-1～P1-6 + 5 条补齐 + 细拆归并记为 3 条），实际展开后表格行数为 18 行（38-55）。

### 14.3 Cloud 对 Codex 二次判决的反驳（v1.2 保留记录）

Codex 第 2 轮在"降级 5 条的二次判决"中：

| Codex 二次判决 | Cloud 裁决 | v1.2 处理 |
|---|---|---|
| P1-2 手势主方向：同意降级 | ✅ 同意 Codex 同意 | 保持 P2 + 新增 P2-2 补单指 |
| P1-5 IndicatorMapper：同意降级 | ✅ 同意 Codex 同意 | 保持 P2 + 新增 P2-1 外置值域 |
| **P1-6 应恢复 P1** | ❌ 驳回：Codex 混淆 P1-6 原始问题（API 洁癖）与 v1.1 修法引入的 P0-3（递归值类型） | P1-6 保持 P2；P0-3 另外作为 R2-P0-3 处理 |
| **P1-7 应恢复 P1**（Codex 笔误写成 Mock 内容） | ❌ 编号错位；实际 P1-7 @MainActor 保持 P2 | 无处理 |
| **P1-10 应恢复 P1** | ❌ 驳回：Codex 滑坡谬误（因 P0-3 未修→P1-10 也做不了），修好 P0-3 后 P1-10 难度回到 P2 | 保持 P2 |

### 14.4 v1.5 实施方案反馈（供 v1.6 参考）

1. §3.1 `training_sets` 表应补 `lease_id / lease_expires_at / reserved_at` 三列及对应索引
2. §3.3 `training_records` 表应补 `final_tick` 列
3. §3.3 settings 表 key 列表删除 `stamp_duty_enabled`
4. §3.4 `FeeSnapshot` 删除 `stampDutyEnabled` 字段
5. 追加"错误处理策略"小节，对齐 v1.2 M0.4
6. 追加"线程并发约定"小节，对齐 v1.2 M0.5
7. §8.1 `content_hash` 算法改用 zip CRC32（或明确 sqlite 字节确定性生成方式）
8. §4.2 印花税不可配置的声明与 §3.3/§3.4 保持一致
9. **v1.3 新增**：§3.1 `training_sets.content_hash` 列类型改 `CHAR(8)`（由 PR-B 修正至 plan）；§8.1 REST 示例 `"sha256hex..."` 改 CRC32 示例（PR-B 修正）
10. **v1.3 新增**：追加"下载验收 journal 表"小节描述 P0-4 解决方案（可在 v1.6 plan 中新增 §8.3）

---

## 十五、Wave 0 执行前的准备（v1.2 补充）

### 15.1 示例代码编译验证

v1.2 契约层含大量代码片段，尤其 §六 C1 的类型设计在 v1.1→v1.2 经两轮反复修正（P0-3 递归值类型、P0-4 Error 约束）。**Wave 0 交付物签字前必须**把以下代码块放进 Xcode Playground 或独立 Swift Package 过一遍编译器，确认无错：

**必验代码清单**：

| # | 位置 | 验证重点 |
|---|---|---|
| 1 | §六 C1 所有值类型 | `ChartGeometry / ChartPanelFrames / PriceRange / ChartViewport / CoordinateMapper / IndicatorMapper / PanelViewState / FrozenPanelState / DrawingSnapshot / ChartInteractionMode` 全部 `Equatable` 自动合成通过 |
| 2 | §六 C1 reducer | `ChartAction` 7 个 case × `ChartInteractionMode` 3 个状态的完整 switch，含 assertionFailure 分支 |
| 3 | §六 C1 KLineView | `draw(_:)` 调用 C3-C6 extension 方法，编译期检查方法签名匹配 |
| 4 | §六 C1 KLineRenderState | 含 `volumeRange / macdRange`，`Equatable` 短路 didSet 生效 |
| 5 | §三 M0.4 所有 Reason 枚举 | `: Error, Equatable` 均满足；`AppError.internalError(module:detail:)` 可构造 |
| 6 | §三 M0.3 KLineCandle | `Codable` round-trip：`snake_case` JSON ↔ `camelCase` struct |
| 7 | §七 E3 TradeCalculator | `Result<BuyQuote, TradeReason>` 编译通过（Failure 符合 Error） |
| 8 | §七 E5 TrainingEngine | `@MainActor` + `@Observable` + `onSceneActivated()` 不产生 strict concurrency 警告 |
| 9 | §七 E5 Preview Fixture | `TrainingEngine.preview(mode:)` 可在 `#Preview` 中调用 |

**重点关注编译器报错类型**：
- `Value type 'X' cannot have a stored property that recursively contains it` → 递归值类型未清除
- `Type 'TradeReason' does not conform to protocol 'Error'` → Reason 枚举漏标
- `Type 'X' does not conform to 'Equatable'` → `Equatable` 自动合成失败（某子字段未满足）
- `Sending '...' risks causing data races` → `@MainActor` / async 边界不清
- `@Observable 'X' cannot be used...` → `@Observable` 与 `struct` 错配

**任何一条编译不过 → 阻塞签字，回契约层修订 → 重新编译验证**。

### 15.2 三方依赖版本锁定

Wave 0 签字同步锁定以下版本，**Wave 1 起不得修改**（除非安全补丁 + 三方同意）：

| 依赖 | 用途 | 建议版本 | 锁定位置 |
|---|---|---|---|
| GRDB.swift | iOS SQLite ORM | 6.x 最新稳定（≥ 6.29） | `Package.resolved` / `Podfile.lock` |
| SQLite | iOS 内嵌 + 后端 | ≥ 3.45（iOS 17 自带满足） | iOS 最低部署版本 17.0 |
| FastAPI | 后端 API 框架 | 0.110+ | `requirements.txt` |
| Uvicorn | FastAPI ASGI server | 0.27+ | `requirements.txt` |
| APScheduler | 后端定时任务 | 3.10+ | `requirements.txt` |
| pandas | 后端数据处理 | 2.x | `requirements.txt` |
| pandas-ta | 技术指标计算 | 0.3.14b0+ | `requirements.txt` |
| asyncpg | 后端 PostgreSQL 驱动 | 0.29+ | `requirements.txt` |
| PostgreSQL | 数据仓库 | 15+ | `docker-compose.yml` 镜像 tag |

**不引入的依赖**（v1.5 §一 已明确，v1.2 再次锁定）：

- 网络层：**不用** Alamofire / Moya，仅 URLSession + async/await
- K 线图表：**不用** KSChart / Lightweight Charts / Swift Charts，仅 Core Graphics 自绘
- 数据库：**不用** Realm / CoreData，仅 GRDB

**版本锁定产物交付**：

- iOS：`Package.resolved` 提交到仓库
- 后端：`requirements.txt` 使用 `==` 精确版本；`docker-compose.yml` 镜像指定 tag（**禁止 `:latest`**）
- 文档：在项目 README 登记版本表，Wave 1 开工前群发确认

### 15.3 后续评审策略

v1.0 → v1.1 → v1.2 已经过**两轮 Codex 对抗性评审 + Cloud 反评审**，累计 37 项修订。边际收益判断：

| 评审选项 | 建议 | 理由 |
|---|---|---|
| 立即做第 3 轮 Codex 全量评审 | **不建议** | v1.2 大量修订来自编译级错误（递归值类型、Error 约束），这些硬问题是前两轮主要收益；第 3 轮预计产出多为风格建议，投入 ~1 人天 vs 收益低 |
| Wave 0 编码中**局部**对抗性评审 | **建议** | 若某个子模块契约落地时发现硬伤，针对该子模块做一次定向评审；快、准、省 |
| Wave 2 集成完成后做一次**集成层**评审 | **建议** | C8 桥接 + E5 编排是跨模块协议最密集处；完成后让 Codex 对比"契约声明 vs 实际实现"审视是否一致 |
| Phase 5 磨光前做一次**性能评审** | **建议** | 用 Instruments 数据对照 v1.5 §一"单帧 <4ms" 目标，由 Codex 审视性能热点 |

### 15.4 契约冻结签字流程

Wave 0 全部交付物收齐后（见 §十一 Checklist），由以下 3 方签字：

| 签字方 | 审查范围 |
|---|---|
| **后端代表** | M0.1 DDL（PostgreSQL + 训练组 sqlite） + M0.2 OpenAPI 与 B1-B4 实现一致；lease 状态机 + CRC32 生成流程可落地 |
| **iOS 代表** | M0.3/M0.4/M0.5 + F1/F2/C1 **完成 §15.1 编译验证**；与 C2-U6 模块接口兼容；Preview Fixture 可在 Xcode Canvas 中渲染 |
| **数据代表** | B1 CSV 导入覆盖所有需要的字段；B2 训练组生成策略（月线前 30 / 后 8 根月窗口）满足训练语义；3-5 个样本训练组数据正确 |

任何一方拒签 → **回契约层修订 → 重新编译验证 → 重新签字**。签字完成后：

1. 项目 README 登记 v1.2 版本号 + 签字时间 + 依赖版本表
2. Git 打 tag `wave0-frozen-v1.2`
3. 三方邮件/群组留存确认记录
4. Wave 1 开工

---

**签字冻结后进入 Wave 1。契约变更需走 RFC + 三方确认（后端/iOS/数据）。下一轮对抗性评审（如需）可对比 v1.5 → v1.2 的全量差异。**
