# Wave 3 fast-follow 并行编排方案（待 opus 4.8 xhigh 对抗 review 到收敛）

**目的**：把 Wave 3 收尾后剩余的可编码 fast-follow 项排出**并行/串行编排**，使可并行者（文件 disjoint）同时跑、有冲突/依赖者正确串行，并处理跨切治理冲突。本文件是**编排决策工件**，供对抗 review；不是某一项的实现 plan。

**触点已 grep 核实 2026-06-15**（见各项「触点」）。

---

## 一、待实施项清单（可编码；device 实测/NAS 不在内）

| 项 | 触点（已核实文件域） | 性质 | 状态 |
|---|---|---|---|
| **W3-11-R1** bounce 接线 | `Render/RenderStateBuilder.swift` + `Render/ChartContainerView.swift` + `Render/KLineView.swift` + `TrainingEngine/TrainingEngine.swift` + `Reducer/Reducer.swift` + 新 bounds 纯函数 | 渲染/手势/engine | spec 已写，**opus review NEEDS-ATTENTION 3 Critical 待返工** |
| **R1b** 拖拽期橡皮筋阻尼 | 同 W3-11-R1（render + gesture，叠加 drag-time） | 渲染/手势 | 未开始；**依赖 W3-11-R1** |
| **13a-R2** cache 跨 lease data-loss | **根因 = cache 物理身份只有 id（`DefaultFileSystemCacheManager.swift:169` 文件名 `<id>__<filename>`、delete 按 id；`InMemoryCacheManager` 按 `meta.id`），journal 却按 `(id,leaseId)`**。lease/version-aware 修复扩散：`Persistence/CacheManager.swift` 协议（**Contracts 包**）+ `DefaultFileSystemCacheManager.swift`（文件名 scheme+delete+listAvailable 解析）+ `InMemoryCacheManager`（PreviewFakes）+ 可能 `TrainingSetFile`/`TrainingSetMetaItem` 值类型加 lease/version 字段 + `DownloadAcceptanceRunner.retryPendingConfirmations` + `TrainingSessionCoordinator`(cache cleanup) + **可能 journal DDL 迁移**（`AppDBMigrations`+`ios/sql/app_schema_v1.sql` mirror，触 schema-smoke CI） | 下载/缓存/持久化/**可能 schema** | 未开始（P2-confirm RFC 域；**cache 身份方案须先 brainstorm 冻结**——见 §三） |
| **13c-R1** os_signpost 帧相关 instrumentation | `Render/KLineView.swift` + `Render/ChartContainerView.swift` + `Render/RenderStateBuilder.swift` | 渲染 | 未开始 |
| **13c-R2** ≥80 蜡烛 perf fixture | `KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift` + `DebugTrainingSetWriter.swift` | 测试 fixture | 未开始 |

排除（非本编排）：device/sim 运行时矩阵实测（user device 职责）；PR11-R1 生产 backendBaseURL / W1-R2 真实样本数据（NAS scope）。

---

## 二、冲突 / 依赖矩阵（核实后）

**生产文件交集**（行×列是否共享 ≥1 生产文件）：

| | W3-11-R1 | R1b | 13a-R2 | 13c-R1 | 13c-R2 |
|---|---|---|---|---|---|
| **W3-11-R1** | — | 同源 | ∅ | **RenderStateBuilder+ChartContainerView+KLineView** | ∅ |
| **R1b** | 依赖 | — | ∅ | 同 render | ∅ |
| **13a-R2** | ∅ | ∅ | — | ∅ | **条件冲突** |
| **13c-R1** | 冲突 | 冲突 | ∅ | — | ∅ |
| **13c-R2** | ∅ | ∅ | **条件冲突** | ∅ | — |

**判定（opus review C1/H1 修正）**：
- **13a-R2 与图表项（W3-11-R1/R1b/13c-R1）disjoint**（下载/缓存 vs 渲染，零共享生产文件）✓。
- **13a-R2 × 13c-R2 = 条件冲突，非 ∅**：二者同在 `KlineTrainerPersistence` 包、同经 `cache.store`——13c-R2 的 perf fixture 经 `AppContainer+DebugSeed.swift:54 cache.store(downloadedZip:meta:)` + 构造 `TrainingSetMetaItem`。**若 13a-R2 改 `CacheManager.store` 签名 / `TrainingSetMetaItem` 加 lease/version 必填字段 → 13c-R2 该调用编译即破**。故 C 轨并行性**取决于 13a-R2 cache 身份方案**（见 §三）。
- **13c-R1 与 W3-11-R1/R1b 共享 3 个 `Render/` 文件 → 真冲突**，渲染轨内串行。
- **R1b 依赖 W3-11-R1**（改同一 `applyPanOffset`/`makeViewport`——R1b 正是 W3-11-R1 §B3/D2 deferred 的拖拽期跟手，字面同函数）。

**跨切治理冲突（关键，所有项共享）**：每项 merge 时都要改同一批 Wave 3 治理工件——
`docs/governance/2026-06-14-wave3-completion.md`（WAVE3-STATUS 机器块 + residual 表）、`scripts/governance/verify-wave3-completion.sh`（gate 谓词）、`docs/acceptance/2026-06-14-wave3-runtime-matrix.md`。
例：W3-11-R1 merge 翻 `feature-completeness: PENDING-W3-11-R1`→resolved + `residual-W3-11-R1: OPEN→CLOSED` + 矩阵 bounce 行；13a-R2 翻 `known-defect-13a-R2: OPEN→CLOSED`；13c-R1/R2 解帧预算 caveat + 残留 13c-R1/R2。**并行下这批治理 doc 必冲突**。

---

## 三、编排（2 轨并行启动 + 1 轨条件并行，错峰，opus review C1/M3 修正）

```
Track A（渲染/手势链，严格串行）: W3-11-R1 ⇄ 13c-R1(signpost)  →  R1b
       〔W3-11-R1 与 13c-R1 共享 Render 文件，二者顺序可换但须串行；R1b 必在 W3-11-R1 后〕
Track B（下载/缓存，独立）      : 13a-R2  〔须先 brainstorm 冻结 cache 身份方案〕
Track C（fixture）             : 13c-R2  〔条件：见下〕
治理收尾（串行末，doc-only）    : ledger-B reconciliation PR（§四）
```

- **A 与 B 真并行**（render/gesture vs 下载/缓存，零共享生产文件 + 测试文件 disjoint，见 §五.2）→ 立即可双轨。
- **A 轨内严格串行**：W3-11-R1 与 13c-R1 共享 3 个 `Render/` 文件，**不可同时**。顺序可换（opus M1：signpost 是纯观测插桩、锚 `make`/`draw` 函数边界、不随 bounce 几何返工 → 可前置给 W3-11-R1 返工提供帧预算工具，也可后置）；R1b（拖拽跟手）**必在 W3-11-R1 之后**（改其刚加的 `applyPanOffset` clamp + `makeViewport` overscroll）。**推荐顺序**：W3-11-R1 →（R1b 与 13c-R1 二选一先做，均串行）。
- **C 轨条件并行（opus C1/H1）**：13c-R2 与 13a-R2 同经 `cache.store`。**B 轨 brainstorming 须先定 cache 身份方案**：
  - 若 13a-R2 选 **additive**（不改 `CacheManager.store`/`TrainingSetMetaItem` 签名，lease 维度走运行时按 journal 行匹配/旁路）→ **C 与 A/B 三轨真并行**。
  - 若 13a-R2 选 **改 store 协议/值类型签名** → 13c-R2 的 `AppContainer+DebugSeed` 调用编译破 → **C 串在 B 之后**（B merged 后 off 更新 main 再做 C）。
  - **决策点 = B 轨 spec 收敛时**；在此之前 C 不进实现（可先各自 brainstorming）。
- **轨 A 前置 = W3-11-R1 spec 返工到收敛**（opus spec-review 3 Critical：bounds 锚相对/符号 + candleStep 几何 + drag-clamp↔runbook 矛盾）。返工收敛前 A 不进实现；B 可即刻 brainstorming/spec。
- **并发强度（opus M3）**：默认 **A + B 双轨先发**；C 待 B 的 cache 方案决定后启（并行或串行）；ledger 收尾最后。不 3 轨齐发，控运维 + merge ceremony 强度。

**隔离**：每轨独立 worktree（off 最新 origin/main），分支 `wave3-w3-11-r1-*` / `wave3-13a-r2-*` / `wave3-13c-r2-*`。轨内下一项在上一项 merged 后 off 更新 main 切新分支 + rebase。

---

## 四、跨切治理 ledger 冲突的处置（opus review C2 修正 → 强制 ledger-B）

每项完成都要翻同一批治理工件：`docs/governance/2026-06-14-wave3-completion.md`（WAVE3-STATUS 机器块 + residual 表）、`scripts/governance/verify-wave3-completion.sh`（gate `require_kv` 谓词）、`docs/acceptance/2026-06-14-wave3-runtime-matrix.md`。

**关键（opus C2）**：gate 的 `require_kv "...-13a-R2..." "OPEN"` / `"...-W3-11-R1..." "OPEN"` / `feature-completeness "PENDING-W3-11-R1"` 是 **codex R3/R8 钉死的强制断言**。翻 `OPEN→CLOSED` / `PENDING→resolved` = **改强制校验逻辑**（非「调 PASS echo 文案」，前版误判），且多轨各改同一 gate 脚本不同 `require_kv` 行 → 真冲突 + 校验语义变更须连同高层 `feature-completeness` 行一致翻、否则留「gate 与现实矛盾」中间态（如 W3-11-R1 merged 但 gate 仍 require `PENDING-W3-11-R1`）。

**决策：强制 ledger-B（业务轨不碰治理 gate/机器块）**：
- 3 业务轨 PR（A/B/C 各项）**不改** `wave3-completion.md` 机器块 / `verify-wave3-completion.sh` / runtime-matrix——各自完成仅记自身 `docs/acceptance/2026-06-15-<item>.md`（含「本项 merged，Wave 3 ledger 待 reconciliation」注）。
- 全部业务轨 merged 后，**单独一个 doc-only「Wave 3 收尾-2 reconciliation」PR** 一次性：翻 `residual-W3-11-R1: OPEN→CLOSED` + `feature-completeness: PENDING-W3-11-R1 → <已解>` + `known-defect-13a-R2: OPEN→CLOSED` + 帧预算 caveat/残留 13c-R1/R2 解 + 矩阵 bounce 行转 device 行 + gate `require_kv` 同步翻 + 红验证。一致、无中间矛盾、单点 review。
- 缓解事实：gate **未接入 CI**（grep 确认 not wired，仅本地/手动）→ 不阻塞业务轨 merge；但仍是共享文件 + 校验逻辑，集中改最稳。
- 备选 ledger-A（逐行 + rebase）**仅**适用机器块纯数据行的低冲突场景，**不适用 gate 谓词逻辑翻转** → 本方案弃 A 取 B。

---

## 五、风险 / 开放问题（opus review R1 后更新）

1. **〔已消解，C1/H1〕13a-R2×13c-R2 disjoint**：经核 13a-R2 触 cache 身份模型（协议 + DefaultFileSystemCacheManager + InMemoryCacheManager + 值类型），与 13c-R2 经同一 `cache.store` → **条件冲突**。§二/§三已改：C 轨并行性 gated on B 的 cache 身份方案（additive→并行 / 改签名→串 B 后）。
2. **〔已核实清单，H2〕测试文件 disjoint**：
   - **A 轨独占**：`Render/RenderStateBuilderTests.swift`、`*PinchTests`、`DecelerationAnimator*Tests`、`*InteractionTests`、`KLineView*Tests`（W3-11-R1 + 13c-R1 共扩 → 已在 A 轨内串行规避；R1b 同）。
   - **B 轨独占**：`DownloadAcceptanceRunnerTests`、`*CacheManagerTests`、`AcceptanceJournalDAO*Tests`、`CacheTouchOnUse*Tests`。
   - **C 轨独占**：`DebugFixtureDataTests`、`DebugTrainingSetWriterTests`、`AppContainerDebugSeedTests`。
   - 轨间（A∥B、A∥C）测试文件 disjoint ✓；A∩C 经 `AppContainerDebugSeedTests`？——A 不碰 Persistence 测试，故 disjoint。**唯一交叉风险 = 13a-R2 改 cache 协议会动 `AppContainerDebugSeedTests`（13c-R2/C 轨域）**，归并入 C1 条件冲突。
3. **〔已纳入，H3〕13a-R2 可能含 journal DDL 迁移**：若选给 journal 加 cache-path 唯一约束等 → 新 `00NN` ALTER 迁移（`AppDBMigrations`，不改 `0001` baseline）。**触 schema-smoke CI 仅当同步更新 `ios/sql/app_schema_v1.sql` mirror 文件**（schema-smoke 仅监听 `ios/sql/**`；纯 `AppDBMigrations.swift` ALTER 增量迁移不触发，`check_app_schema_drift.sh` 比对 v1.4 baseline 仍过）——故 13a-R2 的 DDL 高度隔离于 `AppDBMigrations.swift`。与 13c-R2 的 training-set schema（`DebugTrainingSetWriter`，非 app.sqlite）disjoint ✓。B 轨 spec 须明确是否动 DDL + 是否更新 mirror。
4. **〔已决断，M3〕并发强度**：降为 **A + B 双轨先发**，C 待 B cache 方案定后启，ledger-B 收尾末。非 3 轨齐发。
5. **CI 隔离**：catalyst-build / app-build 各 PR 独立触发互不阻塞；schema-smoke 仅 B（若动 DDL）；main 推进 → 各轨 rebase（错峰覆盖）。**SwiftPM 跨包**：Persistence 依赖 Contracts，故改 Contracts（图表轨 A）会触发 Persistence 重编译——但这是增量编译/CI 重跑，非**文件冲突**，不破坏「独立 PR」（各 PR 自带完整 diff，CI 各自全跑）。
6. **〔scope 归属，开放〕13a-R2 是 pre-existing 基线 bug**（非 Wave 3 引入），P2-confirm RFC 域。并入 Wave 3 fast-follow 批 vs 归 P2 独立治理批——属 scope 归属选择（非并行性）；若归 P2 独立批，则本编排只剩 A 轨（W3-11-R1→13c-R1→R1b）+ C 轨（13c-R2，此时与谁都 disjoint，真并行）。**留待用户裁决 13a-R2 批次归属。**

---

## 六、本方案请 review 的判据

- 冲突/依赖矩阵是否准确（有无漏掉的共享文件/隐藏依赖）？
- 3 轨划分是否真 disjoint（生产 + 测试 + 构建 target 层）？
- 轨 A 内 W3-11-R1→R1b→13c-R1 串行顺序是否最优？
- 跨切治理 ledger 冲突处置（ledger-A/B）是否健全，有无第三种更优？
- W3-11-R1 spec-返工作为轨 A 前置是否正确，会否反过来推翻并行划分？
- 并发强度（3 轨）是否现实，还是应降为 2 轨？
