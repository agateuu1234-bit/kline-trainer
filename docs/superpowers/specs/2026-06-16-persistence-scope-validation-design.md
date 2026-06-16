# Persistence-Scope 校验 RFC — 设计文档

> Wave 3 后续 RFC。R4 残留真修：在数据信任边界补齐「`.m3` datetime 严格递增 + 聚合 open 落 `endGlobalIndex` 窗口」校验，使损坏训练集在 load 期被拒，而非靠渲染层 fail-safe 兜底（GIGO）。

- **状态：** 设计中（待 opus 4.8 xhigh 对抗 review 收敛）
- **作用域：** trust-boundary（持久化 ingest 校验）→ 须走 `codex:adversarial-review`
- **前置：** 聚合感知 reveal RFC（PR #115，`7b1849a`）的 codex R4 HIGH residual
- **版本：** v1.0

---

## 一、背景与问题

### 1.1 R4 残留的由来

聚合感知 reveal RFC（`docs/superpowers/specs/2026-06-15-aggregate-aware-reveal-design.md`）引入 `PartialAggregateCandle.synthesize`，从已揭示的 `.m3` 合成「进行中聚合 K 线」。其定位逻辑：

```swift
let rawStart = m3.partitioningIndex { $0.datetime >= original.datetime }
let start = min(rawStart, tick)   // codex R1-H fail-safe clamp
```

`partitioningIndex` 的契约（`BinarySearch.swift:8`）要求谓词在序列上**单调**，否则「result is undefined」。这里谓词是 `$0.datetime >= original.datetime`，因此正确性依赖 **`.m3` 的 `datetime` 单调递增**，以及**聚合 K 线的 `datetime` 能在其 `endGlobalIndex` 窗口内被定位到**。

codex 在该 RFC 的第 4 轮（R4 HIGH）指出：这两个前提**在运行时 load 路径上没有任何闸门强制**。`synthesize` 自身加了 `min(rawStart, tick)` 容损 clamp（不崩、不泄漏未来、Y 轴不越界），并在注释里明确写下「temporal 一致性的强校验属 reader/persistence trust-boundary（本渲染 RFC 作用域外）」。即：渲染层是 fail-safe 的 GIGO，**真修是在信任边界拒绝损坏数据**。本 RFC 即该真修。

### 1.2 现状：已守的 vs 未守的

生产数据路径 **永远** 经过 `DefaultTrainingSetReader.loadAllCandles()`（in-memory cache 缓存的是文件，不是已解码 candle；每次 load 都重新经 reader 解码）。reader 已强校验（全部抛 `AppError.persistence(.dbCorrupted)`）：

- SQL `typeof()` 存储类匹配（绕过 GRDB silent coerce）
- throwing GRDB decode（列类型 / NOT NULL 违反）
- **per-period `endGlobalIndex` 严格递增**（`DefaultTrainingSetReader.swift:90`）
- OHLC finite / 正价 / 序关系 + volume 非负 + 指标 finite + amount 非负
- **`.m3` 轴**：每根 `globalIndex == endGlobalIndex == i`，从 0 连续
- 非 m3 `endGlobalIndex ≥ 0` 且 `≤ m3Max`
- m3 缺失但有高周期数据 → corrupt

`TrainingEngine.make`（`TrainingEngine.swift:160`）是所有 candle 字典进入引擎的**唯一公共构造闸门**（四个 coordinator 方法均经此），它额外复校验 `isContiguousM3Axis`（m3 索引轴），失败抛 `AppError.trainingSet(.emptyData)`。

**未守的（本 RFC 补齐）：**

1. **`.m3` `datetime` 单调性** —— reader / make / init **均未校验**。reader 校验的是 `endGlobalIndex`，不是 `datetime`。`synthesize`、`candleDatetime`（交易记录时间戳，`TrainingEngine.swift:404`）直接读 m3 `datetime` 排序而无任何保证。
2. **聚合 open 落窗口** —— 聚合（非 m3）K 线的 `datetime` 是否能在其 `endGlobalIndex` 窗口内的 m3 轴上被定位到，无校验。`datetime` 越界（指向未来 m3）会让 `partitioningIndex` 返回错误 start。

### 1.3 影响（为何值得修）

- 渲染层因 R1-H clamp 不会崩 / 不泄漏未来，但**合成出有界错误的 OHLC**（错根），属静默错渲染。
- 交易记录时间戳（`candleDatetime`）若 m3 datetime 乱序，可能取到错误时间。
- 这是 codex 治理闸门维持 needs-attention 的根因：PR #115 是靠 `attest-override` 接受 residual 合入，`codex-verify-pass` 被 bypass。补齐本校验后，该类损坏在 load 期即被 reject，R4 真正关闭。

---

## 二、目标与非目标

### 2.1 目标（in scope）

在数据信任边界补两项校验，损坏即拒（reject-load）：

1. **`.m3` `datetime` 严格递增。**
2. **每根聚合（非 m3）K 线的 `datetime` 落在其 `endGlobalIndex` 窗口内**（open time 能在 m3 轴上定位到一个 `≤ endGlobalIndex` 的索引）。

闸门位置（用户拍板 = Reader + make 纵深）：

- **Reader（生产信任边界，主校验）：** 两项全做，抛 `.persistence(.dbCorrupted)`，复用 coordinator 既有损坏文件恢复（`cache.delete` + 换文件重试）。
- **`make`（普适末线，纵深防御）：** 镜像**校验 1（m3 datetime 单调）**，抛 `.trainingSet(.emptyData)`（与既有 `isContiguousM3Axis` 同族），保护 fake / in-memory / 未来非 GRDB 源喂入引擎的路径——使 `synthesize` 的 `partitioningIndex` 谓词在任何构造路径上都良定义。

### 2.2 非目标（out of scope，文档登记）

- **不**把 `DefaultTrainingSetDataVerifier`（warmup ≥30 根 / monthly ≥8 根等内容计数规则）接进 load 路径。该 verifier 当前仅在**下载验收**路径（`DownloadAcceptanceRunner.swift:85`）跑，从不在 load-to-engine 跑——这是一个**内容策略**缺口，与本 RFC 的**单调性/窗口**关注点正交，登记为相邻 residual，另案处理。
- **不**改 `currentCandleIndex` / `makeViewport` / 任何渲染语义（前序 RFC 已冻结）。
- **不**在 `make` 镜像校验 2（聚合窗口）。校验 2 是跨周期较重的检查；fake reader 喂入窗口越界的聚合时，`synthesize` 的 `min(rawStart, tick)` clamp 已是渲染期 fail-safe，无需在末线闸门重复。生产路径由 reader 全覆盖。
- **不**在 `init`（末线 `precondition`）加 datetime 校验。`init` 仅经 `make` 可达（已校验）；现有 `isContiguousM3Axis` 在 init 复检属既有模式，本 RFC 不扩张该 trap 面（YAGNI）。

---

## 三、数据模型事实（grounding）

- `KLineCandle.datetime: Int64`（Unix epoch 秒，UTC）。`globalIndex: Int?`（仅 m3 非 nil，且 `== endGlobalIndex == 数组下标`）。`endGlobalIndex: Int`（非可选）。
- 各周期独立源（per-period CSV + 各自 pandas 指标），聚合非从 3m 重采样；`global_index` 仅赋 3m，聚合 `globalIndex=nil`、有 `endGlobalIndex`（bisect 到 3m 轴）。
- 聚合 K 线的 `datetime` = 其 open time = 其首根成分 m3 bar 的 `datetime`；`endGlobalIndex` = 其末根成分 m3 bar 的全局索引。良性数据下，首根成分的 m3 索引 `f ≤ endGlobalIndex`，且 `m3[f].datetime == 聚合.datetime`。
- 后端对 pre-window 聚合的 `end_global_index` clamp 到 `max(0, …)`（R1-H1 场景：pre-window 聚合 `endGlobalIndex=0`、`datetime` 早于窗口首根 m3）。
- `.m3` 是最小周期 = 全局 tick 轴（无 `Period.min`，按约定硬编码）。
- `CONTRACT_VERSION = "1.6"`；`TRAINING_SET_SCHEMA_VERSION = 1`；frozen `schema.sql` 无 UNIQUE/datetime 约束。

---

## 四、校验规格（精确谓词）

### 4.1 校验 1：`.m3` `datetime` 严格递增

设 `m3 = allCandles[.m3]`。对所有相邻 `i`：

```
m3[i+1].datetime > m3[i].datetime
```

**严格** `>`（非 `>=`）：重复时间戳会使 `partitioningIndex` 对「首个 `datetime >= X`」的定位歧义，视为损坏。

- **Reader：** 在主循环对 `period == .m3` 的行追踪上一根 datetime；违反 → `throw AppError.persistence(.dbCorrupted)`。（rows 按 `ORDER BY period, end_global_index` 取，m3 的 endGlobalIndex 已严格递增，datetime 应随之严格递增。）
- **make：** 新增私有静态 helper `isStrictlyIncreasingM3Datetime(_ m3:) -> Bool`，在现有 `isContiguousM3Axis` guard 之后调用；违反 → `throw AppError.trainingSet(.emptyData)`。

### 4.2 校验 2：聚合 open 落 `endGlobalIndex` 窗口（仅 Reader）

前置：校验 1 已通过（m3 datetime 单调，`partitioningIndex` 良定义）；m3 非空（reader 既有逻辑保证「有聚合则必有 m3」）。

对每个 `period != .m3` 的每根 candle `C`：

```
let s = m3.partitioningIndex { $0.datetime >= C.datetime }
require s <= C.endGlobalIndex
```

含义：聚合 `C` 的 open time 在 m3 轴上解析到的首个索引 `s`，必须落在 `C` 的窗口末 `endGlobalIndex` 或之前——正是 `synthesize` 对 open 那根（`tick ≤ C.endGlobalIndex`）依赖的前提 `rawStart ≤ tick`。

边界正确性（已验证，写进设计以防回归）：

- **pre-window 聚合（R1-H1）：** `C.datetime < m3[0].datetime` → 全部 m3 满足谓词 → `s = 0 ≤ endGlobalIndex`（clamp 后为 0）→ **通过**。本校验不破坏 R1-H1 对 clamped predecessor 的免疫。
- **未来越界聚合：** `C.datetime > 所有 m3 datetime` → `s = m3.count`；因 `endGlobalIndex ≤ m3Max < m3.count` → `s > endGlobalIndex` → **拒绝**。

违反 → `throw AppError.persistence(.dbCorrupted)`。落点：reader `loadAllCandles` 内、m3 块（`m3Candles` 已可得）之后，遍历非 m3 candle。

---

## 五、失败模式与恢复

- **reject-load（抛错）**，不 sanitize / 不 best-effort——与 reader 既有全部校验、E2 PositionManager throwing decoder 一致。
- **Reader 抛 `.persistence(.dbCorrupted)`：** 经 coordinator `isCorruptTrainingSet` 闸门 → `cache.delete(file)` + 换另一文件重试（既有恢复路径，四个 load 方法均有）。这是 P6 `dbCorrupted` 错误类共享的恢复语义（但本路径是训练集 candle 路径，非 SettingsStore 的两层 retryReload/forceReset；训练集损坏的恢复是删文件换源）。
- **make 抛 `.trainingSet(.emptyData)`（`isRecoverable == true`）：** 由 UI 呈现。此路径主要服务 fake / 非生产构造；生产路径已被 reader 在更早处以 `.dbCorrupted` 拦下。

---

## 六、信任边界、治理与 CONTRACT_VERSION

- **trust-boundary 变更：** 持久化 ingest 校验收紧 → 须 `codex:adversarial-review`（`codex-verify-pass` required check）。codex 配额耗尽时按既有惯例走 opus 4.8 xhigh fallback + `attest-override`（user TTY）。
- **CONTRACT_VERSION：不 bump。** 本 RFC 不改 schema / DDL / 字段 / 序列化格式；frozen `schema.sql` 不变。它只是**收紧对本就非法数据的拒绝**（非单调 datetime / 越界聚合在消费端本就是 undefined behavior）。后端生成的数据按构造即满足两项不变量（3m bar 顺序生成、聚合 open 对齐其首根 m3），不会拒绝任何真实有效数据。（此判断在 spec self-review / opus review 复核。）
- **codeowners / workflow 文件：** 不改。

---

## 七、测试策略

全部 host `swift test`（reader 测试在 `KlineTrainerPersistenceTests`，make 测试在 `KlineTrainerContractsTests`）+ Mac Catalyst `build-for-testing`。

**Reader（`KlineTrainerPersistenceTests`，需建带 `klines` 表的临时 GRDB 库 fixture）：**

1. happy-path 回归：m3 datetime 严格递增 + 聚合 open 对齐 → `loadAllCandles()` 成功、字典完整。
2. m3 datetime 非严格递增（含①下降 ②重复）→ 抛 `.persistence(.dbCorrupted)`。
3. 聚合 datetime 越界（指向未来 m3，`s > endGlobalIndex`）→ 抛 `.persistence(.dbCorrupted)`。
4. pre-window 聚合（`datetime` 早于首根 m3、`endGlobalIndex=0`）→ **通过**（R1-H1 不回归 killer）。

**make（`KlineTrainerContractsTests`，纯内存 dict）：**

5. m3 datetime 非严格递增的内存 dict 喂 `make` → 抛 `.trainingSet(.emptyData)`（纵深防御）。
6. happy-path 内存 dict → `make` 成功（回归，确认未误伤）。

**Mutation-verify（每个新 guard）：** 临时 revert 该 guard → 对应测试必须 FAIL（红）→ 恢复 → 绿。证明测试真锚定 guard，非 vacuous。

**强 fixture 要求（吸取前序 vacuous-fixture 教训）：** 校验 2 的越界测试 fixture 必须让 `s` 真正 `> endGlobalIndex`（聚合数足够、m3 轴足够长），不能用「m3 只有 1-2 根」使任何分支都过。

---

## 八、相邻 residual（登记，不在本 RFC 修）

- **R-A：** `DefaultTrainingSetDataVerifier`（warmup/content 计数）从不在 load 路径跑（仅下载验收）→ 缓存后内容漂移 / 未经下载验收的文件会带「内容不足」绕过到引擎。内容策略缺口，另案。
- **R-B：** 聚合（非 m3）周期的 `datetime` 单调性本身未单独校验（本 RFC 只校验聚合 open 的**窗口落点**，未要求聚合 datetime 序列整体单调）；当前无消费者依赖聚合 datetime 单调（render 用 endGlobalIndex），故不修。若未来有消费者按聚合 datetime 二分，需补。

---

## 九、验收标准（高层；非编码者可执行清单见 `docs/acceptance/2026-06-16-persistence-scope-validation.md`）

- 损坏训练集（m3 datetime 非单调 / 聚合 open 越界）在 `loadAllCandles()` 即被拒为 `.dbCorrupted`，不再静默到达渲染层。
- 良性训练集（含 pre-window clamped 聚合）照常 load 成功，无回归。
- fake / 内存 dict 路径：m3 datetime 非单调时 `make` 拒为 `.emptyData`。
- 全部既有测试 + 新增测试绿；Catalyst build-for-testing 成功。
- codex:adversarial-review 收敛（或 quota fallback 至 opus 4.8 xhigh APPROVE + 文档化 residual）。

---

## 十、变更记录

- **v1.0**（2026-06-16）：初稿。brainstorming 收敛后写入。闸门位置 = Reader + make 纵深（user 拍板）。待 opus 4.8 xhigh 对抗 review。
