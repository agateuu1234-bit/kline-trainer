# Wave 3 residual-D 闭合设计：生产路径 E2E smoke 接真 verifier

**日期**：2026-06-16
**性质**：Wave 3 residual 闭合（feature + governance 混合）。把 `residual-D-e2e-smoke` 从 **PARTIAL → CLOSED**：让真实 `DownloadAcceptanceRunner` 的生产路径 E2E smoke **接真 `DefaultTrainingSetDataVerifier`**（而非 13b 的 `FakeTrainingSetDataVerifier`），从而覆盖「runner ↔ 真 verifier」此前唯一未被 smoke 覆盖的接线。
**source-of-truth**：`docs/governance/2026-06-14-wave3-completion.md` §三 行 D + `docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md`「Residual」表 13b-R2 + spec `docs/superpowers/specs/2026-06-14-wave3-pr13-completion-design.md` §D。
**评审通道**：trust-boundary（改 `ios/**/*.swift` 测试 + `docs/governance/**` + `scripts/**`，均在 `trust_boundary_globs` 且后三类在 `codeowners_required_globs`）→ PR 阶段须 codex:adversarial-review + CODEOWNERS approve；本 spec / plan / 整体三闸门按用户指令走 opus 4.8 xhigh 对抗性 review 到收敛。

---

## 一、问题陈述（residual-D 当前 PARTIAL 的确切边界）

13b PR #109（`fc46fef`）交付了 §D「生产路径 E2E smoke」：测试 `DownloadAcceptanceRunnerIntegrationTests.run_realPipeline_storedSetIsDownstreamConsumable` 用**全真组件**跑 download→CRC→unzip→openAndVerify→verifyNonEmpty→store→confirm→下游 reopen 消费，**唯独 `dataVerifier` 注入 `FakeTrainingSetDataVerifier()`（放行）**。

governance 完成 doc §三 行 D 据 codex 13b review R4-Med 判为 **PARTIAL**，理由原文：

> 真 `DefaultTrainingSetDataVerifier` 要求**每周期 startDatetime 前 ≥30 warm-up（含 monthly ≥30 = 数千根 m3 + 多年数据）**，对测试 fixture 不现实 → runner ↔ 真 verifier 接线**未被 smoke 覆盖** → 整条生产验收组合未一次性端到端 → PARTIAL。

13b acceptance「Residual」表 13b-R2 同样以「满足真 verifier 的 ≥30-全周期-含-monthly fixture 不现实」accept residual。

**残留实质**：生产路径上 `DownloadAcceptanceRunner` 调 `dataVerifier.verifyNonEmpty(reader:)`（`DownloadAcceptanceRunner.swift:85`）这一步，在 E2E smoke 中走的是 fake，真 verifier 的判定从未在「真 runner 管线内」端到端流过。真 verifier 的**规则**有 `DefaultTrainingSetDataVerifierTests` 专测，但「runner 把真 verifier 接进 Step 4+5 并正确传播其放行/拒绝」无 E2E 覆盖。

---

## 二、核心论证：13b-R2「不现实」前提是错的（residual-D 可闭合）

13b-R2 的「数千根 m3 + 多年数据」推断，把**两件不同的事**混为一谈：

1. **真 verifier 实际检查的规则**（`DefaultTrainingSetDataVerifier.swift:27-42`）：对 `Period.allCases` **逐周期独立**，仅要求
   - `candles[period]` 非空；
   - `before = count(datetime < startDatetime) >= 30`；
   - `after = count(datetime >= startDatetime) >= (period == .monthly ? 8 : 1)`。

   它**只对该周期自身的数组计数**——**不**要求 monthly 的根是从 m3 物理聚合而来，**不**校验跨周期时间对齐，**不**要求覆盖「多年」真实日历跨度。

2. **13b-R2 误以为的隐含前提**：要让 monthly 有 ≥30 根 startDatetime 之前的 K 线，就得有真实「30 个月」历史，聚合到 m3 = 数千根。**但 verifier 根本不检查物理聚合**，所以这个前提不成立。

**verifier 阈值层的反证（仅证「阈值可达」，不证「真管线可行」）**：真 verifier 的专测 `DefaultTrainingSetDataVerifierTests.makeValidCandles()`（该文件 L52-67）构造出**通过真 verifier 逻辑**的最小数据——每周期 `30 个 before（startDT−i）+ N 个 after（monthly N=8，其余 N=1）`，6 周期合计约 **228 根**，毫无「多年」跨度，已让 `verifyNonEmpty_validShape_passes` 绿。**但必须澄清其证明边界**：该测试经 `FakeReader`（同文件 L12-22，直接返回字典、**绕过真 `DefaultTrainingSetReader` 的全部不变量**），且每根 candle `endGlobalIndex = 0`（L48，全 0）——这份数据**只证明「verifier 的 before/after 阈值用 ~228 根即可满足」，绝不证明「同样数据经真 sqlite + 真 reader 也能流过」**（若原样写库，m3 轴 `g==endgidx==i` 连续性 + endgidx 严格递增会立刻 reject）。

**真管线可行性是独立命题，由本 spec §四 承担**：闭合 residual-D 需要的是「一份**经真 sqlite + 真 reader + 真 verifier** 全流过的 fixture」。这要求 fixture **同时**满足 §三 列出的 reader 全部不变量（含校验 1/校验 2，见下）**与** verifier 阈值。§四 据此**另起炉灶**设计（endgidx 0…37 连续 + 非 m3 datetime 与 m3 网格逐一对齐），并在 §四逐条证明其过 reader——这才是 residual-D 可闭合的真正依据。

> 结论：满足**真 verifier 阈值**的数据量完全现实（~228 行，13b-R2「数千根 + 多年」前提事实有误）；而满足**真 reader + 真 verifier 全管线**的 fixture 也可行——但其可行性来自 §四 对 reader 不变量（尤其校验 1/2）的精确满足，**不是**「verifier 规则简单」的推论。residual-D 之所以停在 PARTIAL，是 13b 选 fake 走捷径 + 一条事实有误的「不现实」论断 accept residual，而非真有技术障碍。本 PR 据此推翻前提、闭合 residual-D。

**与既有「accept residual」决策的关系**：本 PR **不**回改 13b acceptance doc（它是 13b 当时快照，13b-R2 是当时 PR 内的诚实记录）。本 PR 在 governance 完成 doc 的**权威 residual ledger**（§三 行 D + WAVE3-STATUS 块）把跨 PR 的 residual-D 标 CLOSED，并以「verifier-valid fixture + 真 verifier E2E」作证据指针，**显式注明** 13b-R2「不现实」评估已被本 PR 解决。ledger 完整性优先（同 13a-R2 在 2026-06-14 doc 内就地标 RESOLVED 2026-06-15 的先例）。

**机器块/gate 值的命名（避免 PR-号占位符 + 强化 provenance）**：WAVE3-STATUS 块值 + grep gate 谓词用 **work-id + 日期戳** `CLOSED residual-D 2026-06-16`（authoring 时已知、稳定、无 `<PR#>` 占位符；镜像 13a-R2 的 `CLOSED 13a-R2 2026-06-15` work-id+date 风格，机器块自身即绑定具体残留交付）。PR 号 + 测试名等完整 provenance 落在 §三 行 D 的**散文**里（散文不受 gate 字面精确匹配约束，可 merge 后回填 PR 号）。

---

## 三、约束地图（fixture 必须同时过的每一关）

E2E smoke 让 fixture sqlite 字节流过真管线，每一关都有不变量；fixture 必须**同时**满足全部：

| 关卡 | 代码 | 约束 |
|---|---|---|
| ZipIntegrity (CRC32) | `DefaultZipIntegrityVerifier` | `meta.contentHash` == 真实 sqlite 字节的 CRC32（由 `ZipFixture.makeMinimalSqliteZip` 实算，自动满足） |
| Extract | `DefaultZipExtractor` | 标准 zip（fixture helper 已保证） |
| openAndVerify | `DefaultTrainingSetDBFactory.swift:19-79` | `PRAGMA user_version == 1`；meta 单行 + 列类型正确 + `stockCode/stockName` 非空 + `startDatetime > 0` + `endDatetime >= startDatetime` |
| loadAllCandles（被 verifyNonEmpty 调用） | `DefaultTrainingSetReader.swift:28-174` | 见下「reader 不变量」 |
| **verifyNonEmpty（真 verifier）** | `DefaultTrainingSetDataVerifier.swift:27-42` | 每周期 `before>=30` + `after>=(monthly?8:1)` |
| store | `DefaultFileSystemCacheManager` | 内部开 DatabaseQueue 读 `PRAGMA user_version`（==1 满足） |
| confirm | `FakeAPIClient`（测试替身，放行） | 无约束（返回成功） |
| 下游消费 | reopen + `loadAllCandles` | 同 reader 不变量 |

**reader 不变量（`loadAllCandles`，最严格的一关；以 worktree base c7feea8 的真实代码为准——注意 base 比早期 8cdf06f 多了校验 1/2，persistence-scope RFC 新增）**：
- SQL `ORDER BY period, end_global_index`；每周期 `end_global_index` **严格递增**（`DefaultTrainingSetReader.swift:90-92`，`r.endGlobalIndex <= prev` → `.dbCorrupted`）。
- 每行 OHLC（L97-105）：`open/high/low/close` 有限且 `> 0`；`high >= max(open,close,low)`；`low <= min(open,close,high)`；`volume >= 0`。
- 可选指标（amount/ma66/boll*/macd*）若非 nil 须有限；amount 若非 nil 须 `>= 0`（L107-115）。
- **m3 轴不变量**（L153-160）：`result[.m3]` 按 end_global_index 排序后枚举位置 `i`，每根须 `globalIndex == endGlobalIndex == i`（即 m3 的 `global_index = end_global_index = 0,1,2,…,N−1` 连续从 0）。
- 非 m3 周期：`end_global_index >= 0` 且 `<= m3Max`（= m3 最大 end_global_index，L170-175）。`global_index` 可 NULL。
- **校验 1**（L161-168，**易漏**）：`.m3` 的 `datetime` **严格递增**（`m3Candles[i].datetime > m3Candles[i−1].datetime`，否则 `.dbCorrupted`）。校验 2 依赖它。
- **校验 2**（L177-187，**最易漏、与 fixture 数字强耦合**）：对**每个非 m3 candle** `c`，`s = m3Candles.partitioningIndex { $0.datetime >= c.datetime }`（= 首个 datetime ≥ `c.datetime` 的 m3 下标）须满足 `s <= c.endGlobalIndex`，否则 `.dbCorrupted`（空 bucket / 聚合 open 越窗 / future-overflow）。**这条要求非 m3 candle 的 `datetime` 与其 `endGlobalIndex` 必须和 m3 的 datetime 网格自洽**——§四 fixture 正是靠「非 m3 datetime = m3 同网格」让 `s == endGlobalIndex` 临界满足。
- m3 缺失但存在高周期数据 = corrupt（L188-190）；全空字典 = 允许（本 PR 不触发）。

---

## 四、Fixture 设计（满足全部约束的最小一致数据）

**统一形状**：6 个周期（`.m3 / .m15 / .m60 / .daily / .weekly / .monthly`）各 **38 根** K 线 = `30 根 before + 8 根 after`，合计 **228 根**。

设 `startDT = meta.startDatetime`（沿用现有 fixture 默认 `1_700_000_000`）。每周期：
- before 段：`datetime = startDT − 30 … startDT − 1`（30 根，全 `< startDT`），`end_global_index = 0 … 29`。
- after 段：`datetime = startDT + 0 … startDT + 7`（8 根，全 `>= startDT`），`end_global_index = 30 … 37`。
- 故每周期 `end_global_index = 0…37` 严格递增、`datetime` 单调递增、跨 startDT 在 index 29→30 之间切换。

**m3**：`global_index = end_global_index = 0…37`（满足 `g == endgidx == i` 连续从 0），`m3Max = 37`。
**非 m3（m15/m60/daily/weekly/monthly）**：`global_index = NULL`，`end_global_index = 0…37`（全 `<= m3Max = 37`）。

**OHLC**：沿用现有 fixture 的安全常量 `open=1.0, high=2.0, low=0.5, close=1.5, volume=100`，指标列全 NULL（已知过 reader 语义校验：`high=2 >= max(1,1.5,0.5)=1.5`，`low=0.5 <= min(1,1.5,2)=1`，全正，volume≥0）。

**关键对齐**：**所有周期（含非 m3）的第 `e` 根 datetime 一律 = `startDT − 30 + e`**（`e` = 该根 end_global_index）。即 6 个周期共享同一条 datetime 网格。这不是巧合而是过 reader 校验 2 的硬约束（见下证明）。

**reader 核验（逐条，独立推演，过最严格的一关）**：
- 每周期 end_global_index `0…37` 严格递增 ✓。
- OHLC 语义 ✓（上段）。
- m3 轴：`global_index = end_global_index = i = 0…37` 连续从 0 ✓；`m3Max = 37`。
- 非 m3 `end_global_index = 0…37` 全 `<= m3Max = 37` ✓；`global_index = NULL`（reader 不校验非 m3 的 global_index）✓。
- **校验 1**（m3 datetime 严格递增）：m3 datetime = `startDT−30, startDT−29, …, startDT+7` 单调递增 ✓。
- **校验 2**（每非 m3 candle `s <= endGlobalIndex`）：非 m3 candle `c` 在 `endGlobalIndex = e`、`datetime = startDT−30+e`。`s = partitioningIndex{ m3.datetime >= startDT−30+e }`；m3 第 `i` 根 datetime = `startDT−30+i`，故首个 `i` 使 `startDT−30+i >= startDT−30+e` 即 `i = e` → `s = e`。`s = e <= e = c.endGlobalIndex` ✓（**临界等号成立、合法**）。**全 6 周期所有非 m3 行均满足校验 2，当且仅当 datetime 与 m3 网格对齐。**

**verifier 核验**：每周期 `before = count{datetime < startDT} = 30 >= 30` ✓（`e = 0…29` → datetime `startDT−30…startDT−1`）；`after = count{datetime >= startDT} = 8`（`e = 30…37` → datetime `startDT…startDT+7`），monthly `>= 8` ✓、其余 `>= 1` ✓。**全 6 周期通过真 verifier**。

> 为何统一 38 而非按周期最小化：monthly 驱动上界（30+8=38 → end_global_index 至 37 → m3Max≥37 → m3≥38 根）。其余周期 30+1 即可，但统一 38 使 helper 退化为「对每个 period 跑同一生成函数」，最简、最易读、无特例分支（YAGNI 反向：不引入按周期的 after 数差异）。228 行无性能/可读性负担。

---

## 五、测试设计（正反双测，证明接线真实承载 verifier 判定）

新增于 `DownloadAcceptanceRunnerIntegrationTests.swift`（Persistence 测试目标）：

1. **正向（闭合 residual-D 的主测）** `run_realPipeline_withRealVerifier_confirmsAndDownstreamConsumable`：
   - 用 **verifier-valid fixture**（§四）+ **真 `DefaultTrainingSetDataVerifier()`** 跑全真管线。
   - 断言 `.confirmed`；`file.schemaVersion == TRAINING_SET_SCHEMA_VERSION`；journal `.confirmed` 计数 1；下游 reopen `loadAllCandles` 每周期非空、`candles[.m3].first.globalIndex == 0`、每周期 before≥30/after 满足（直接复述 verifier 通过的条件，钉死「真 verifier 真跑过」）。

2. **反向（防 vacuous：证明真 verifier 被接进管线且其拒绝沿 runner 错误路径传播）** `run_realPipeline_withRealVerifier_rejectsWhenPeriodUnderThirtyBefore`：
   - 取 verifier-valid fixture，但 **daily 周期重新生成为 29 根 before**——**不是「删一根、其余不变」**（那会破坏 datetime↔endgidx↔m3 网格对齐、被 reader 校验 2 先拒成假阴）。**正确做法 = 丢弃 daily 的 `e = 0` 那根，保留 `e = 1…37`**：
     - daily before：`e = 1…29`，datetime `startDT−29…startDT−1`（29 根，全 `< startDT`）。
     - daily after：`e = 30…37`，datetime `startDT…startDT+7`（8 根，不变）。
     - 即 daily 共 37 根、end_global_index `{1…29, 30…37}` 仍严格递增、datetime 仍 = `startDT−30+e`（网格对齐保持）。**其余 5 周期不变（各 38 根）。m3 仍 0…37（m3Max=37 不变）。**
   - reader 核验：daily 各行 `s = partitioningIndex{m3.datetime >= startDT−30+e} = e <= e` ✓（对齐保持，**过 reader、非 `.dbCorrupted`**）。
   - 真 verifier 对 daily `before = 29 < 30` 抛 `AppError.trainingSet(.emptyData)`；runner 在 Step 4+5（`DownloadAcceptanceRunner.swift:85`）抛出 → catch（L109-115）→ 返回 `.rejected(.trainingSet(.emptyData))`、写 `.rejected` journal、cleaner 清 temp。
   - 断言 `.rejected` 且错误 **精确等于** `.trainingSet(.emptyData)`（区分于 reader 的 `.persistence(.dbCorrupted)` / confirm 的 `.network*`）；cache 无该组（`cache.store` 在 verifier 之后、`DownloadAcceptanceRunner.swift:91`，verifier 抛错时从未执行 → 必空）。

> 反向测试的必要性（mutation-kill 思路）：仅正向测试，即便 `verifyNonEmpty` 被旁路/空实现也可能绿。反向测试令「真 verifier 的拒绝必须穿过 runner 到达调用者」——这是 residual-D 的真正语义（接线承载判定），不是「能造一份过 verifier 的数据」。两测合取 = runner↔真 verifier 接线**双向**端到端覆盖。

**既有测试保留**：`run_realPipeline_happyPath_storesAndConfirms` 与 `run_realPipeline_storedSetIsDownstreamConsumable`（用 fake + 极小 fixture）**不动**——它们覆盖其它管线面（CRC/store/cleaner/下游字段），与本 PR 正交；删除属无关改动（违 surgical）。

---

## 六、实现方式（2 个候选 + 推荐）

**候选 A（推荐）— 测试内生成 verifier-valid candles，复用既有 `TrainingSetSQLiteFixture.make(options:)`。**
新增一个**测试目标内**的纯生成 helper（如 `TrainingSetSQLiteFixture` 上的 `static func verifierValidConfig(droppingBeforeForDailyTo:)` 或测试文件内 `private` 工厂），按 §四 产出 `ConfigOptions.candles`，喂给现有 `make`。**零生产代码改动**；复用既有 schema 写入路径（与下载验收同口径）。
- 优点：最 surgical；不碰生产；fixture 写入逻辑已被 `TrainingSetSQLiteFixtureTests` 覆盖。
- 缺点：helper 需手工拼 228 元组 → 用循环生成（非字面量），保持可读。

**候选 B — 复用 `DebugTrainingSetWriter`（生产 `#if DEBUG` 写入器）。**
它已能写全 6 周期 schema-aligned sqlite。
- 缺点：`DebugTrainingSetWriter` 的根数/datetime 形状由其自身契约定（13c-R2 用 `fullLoadM3Count=9600` 等），与 verifier 的 before/after 语义未必对齐；为本测试改它 = 动生产代码 + 牵连 13c-R2 既定形状，违 surgical。**否决**。

**采用 A**。helper 形如 `verifierValidCandles(dailyBeforeStart: Int = 0)`：对 `period in Period.allCases`，按 end_global_index `e` 生成 `(datetime: startDT − 30 + e, gIdx: period == .m3 ? e : nil, endGIdx: e)`；
- 正向：所有周期 `e ∈ 0…37`（30 before + 8 after）。
- 反向：仅 daily `e ∈ 1…37`（丢 e=0 → 29 before + 8 after，**保持 datetime = startDT−30+e 网格对齐**，过 reader 校验 2），其余周期仍 `e ∈ 0…37`。
通过 `dailyBeforeStart`（0=正向 / 1=反向）参数化 daily 起始 e。**关键不变量：datetime 永远 = startDT−30+e，使非 m3 的 `s == e <= e`（校验 2）恒成立——不可改成「按 datetime 重排 endgidx」或「删行不重排」。** startDT 取 fixture 默认 meta.startDatetime（`1_700_000_000`）。OHLC 由 `TrainingSetSQLiteFixture` 写死安全常量，helper 只产 `(datetime, gIdx, endGIdx)` 元组。

---

## 七、Scope（surgical 边界）

**改**：
1. `ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift`：+2 测试（正/反），新增 verifier-valid candles 生成 helper **作该测试文件内 `private` static func**（单一使用点 → 不扩 `TrainingSetSQLiteFixture` 表面；用循环生成 `ConfigOptions.candles`，daily before 根数参数化 30/29）。
2. `docs/governance/2026-06-14-wave3-completion.md`：
   - WAVE3-STATUS 块 `residual-D-e2e-smoke: PARTIAL 13b #109` → **`CLOSED residual-D 2026-06-16`**。
   - §三 行 D（L85）：终态 PARTIAL → **CLOSED**；**必须删除/改写该行末「满足真 verifier 的 ≥30-全周期-含-monthly fixture **不现实**（13b accept residual）」这半句**（否则同一行既 CLOSED 又称「不现实」= 自相矛盾），改为「13b-R2『不现实』评估已被本 PR 用 verifier-valid 228 根 fixture（非 m3 datetime 与 m3 网格对齐过 reader 校验 1/2 + 真 verifier）证伪并解决；证据 = `DownloadAcceptanceRunnerIntegrationTests` 正/反向真 verifier E2E（PR# merge 后回填）」。
   - §六 评审通道说明（L124）「A/B/C CLOSED + **D PARTIAL**」→ CLOSED 同步。
3. `scripts/governance/verify-wave3-completion.sh`——**全部** residual-D/PARTIAL/fake-verifier 措辞逐处同步（漏改任一注释 = gate 自文档撒谎）：
   - L47 谓词：`require_kv "residual-D-e2e-smoke" "PARTIAL 13b #109"` → **`"CLOSED residual-D 2026-06-16"`**（功能行）。
   - L5 头注释「residual A/B/C 标 CLOSED + **D 标 PARTIAL**（块内全行；**D=PARTIAL per R4-Med fake verifier**）」→ CLOSED 措辞（该行含两处 PARTIAL）。
   - L43 谓词 1 inline 注释「residual A/B/C = CLOSED；**D = PARTIAL（codex R4-Med：§D smoke 用 fake verifier，runner↔真 verifier 接线未 smoke 覆盖）**」→ CLOSED + 「本 PR 接真 verifier，runner↔真 verifier 已 E2E 覆盖」。
   - L73 末行 echo「…A/B/C CLOSED + **D PARTIAL** + …」→ `D CLOSED`。
   实施后本地跑该脚本须 PASS（residual-D 谓词改 CLOSED 且与 doc 块逐字一致）。
4. `docs/acceptance/2026-06-16-wave3-residual-d-e2e.md`：本 PR 中文非-coder acceptance checklist（CLAUDE.md backstop #2）。

**不改（明确非目标）**：
- 生产代码（runner / verifier / reader / fixture writer）——0 行。
- `docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md`（13b 历史快照，13b-R2 是当时诚实记录，不回写历史）。
- `runtime-matrix: PARTIAL` / `formal-closure: PENDING` / `feature-completeness` / `freeze-tag` / W3-11-R1 / ship 门——residual-D（E2E smoke）与 device 运行时矩阵正交，**一律不动**。
- 既有 fake-verifier 测试。

---

## 八、风险与缓解

| 风险 | 缓解 |
|---|---|
| 误判 reader 不变量导致 fixture 被 `.dbCorrupted` 拒（而非走到 verifier） | §三 已逐条映射；正向测试若得到 `.rejected(.persistence(.dbCorrupted))` 即说明 fixture 违反 reader 约束（非 verifier）——TDD 红→绿过程会立刻暴露，且断言精确到 `.confirmed` |
| 反向测试「假阴」：daily 减到 29 也可能因别的原因 reject | 断言错误**精确等于** `.trainingSet(.emptyData)`（verifier 的拒绝码），区分于 `.persistence(.dbCorrupted)`（reader）/`.network`（confirm）；并断言其余周期仍合法（隔离变量） |
| 并行 PR 也在改 completion doc / grep gate（W3-11-R1 ledger 仍 OPEN，疑有在途 PR） | 本 worktree 从最新 `origin/main`(c7feea8) 分支；只改 residual-D 相关**行**，最小化 diff 冲突面；合并前 rebase 校验 |
| 改 grep gate 后与 doc 不一致 → CI fail-closed | 谓词与 WAVE3-STATUS 块**逐字**对齐（gate 设计即「同一份字面契约」）；本地跑 `verify-wave3-completion.sh` 验证 PASS 作 verification 证据 |
| Swift 本地工具链 blindspot（历史教训） | 依赖 Catalyst CI + swift-test CI 作第二层；本地 `swift test --filter` 先跑 Persistence 套件 |

---

## 九、验收标准（预览，详见 plan 的 acceptance checklist）

- 新增正向 E2E 测试用**真** `DefaultTrainingSetDataVerifier` 跑通真 runner 管线得 `.confirmed` + 下游可消费 → 绿。
- 新增反向 E2E 测试证明真 verifier 拒绝（29-before）经 runner 传播为 `.rejected(.trainingSet(.emptyData))` → 绿。
- 既有全量测试不回归。
- `scripts/governance/verify-wave3-completion.sh` 本地跑 **PASS**（residual-D 谓词已改 `CLOSED residual-D 2026-06-16` 且与 doc 块逐字一致）。
- governance 完成 doc §三 行 D + WAVE3-STATUS 块 + §六 一致标 CLOSED，并记证据指针 + 注明 13b-R2 前提已解决；**行 D 末「不现实」半句已删/改**。
- **gate 脚本内无残留 `PARTIAL` / `不现实` / `fake verifier` 指向 residual-D 的措辞**（L5/L43/L47/L73 全同步；可 `grep -n "PARTIAL" scripts/governance/verify-wave3-completion.sh` 自查仅余与 residual-D 无关的项如 runtime-matrix=PARTIAL）。
- Catalyst + swift-test + app-build CI 绿。
- 本 PR 中文非-coder acceptance checklist 就位。

---

## 十、评审与流程

- 本 spec → opus 4.8 xhigh 对抗性 review 到收敛（用户指定）。
- 收敛后 → writing-plans → opus 4.8 xhigh 对抗性 review plan 到收敛 → subagent-driven TDD → verification-before-completion → requesting-code-review → 整体 opus 4.8 xhigh 对抗性 review 到收敛。
- PR 阶段：codex:adversarial-review（CLAUDE.md backstop #1 非-overridable；配额耗尽按 memory 既有先例 documented opus 4.8 xhigh fallback）+ CODEOWNERS approve（`docs/governance/**`、`scripts/**`、`docs/superpowers/specs|plans/**` 均在 `codeowners_required_globs`，合并门）。
