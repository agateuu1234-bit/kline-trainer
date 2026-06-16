# Persistence-Scope 校验 RFC — 设计文档

> Wave 3 后续 RFC。R4 残留真修：在数据信任边界补齐「`.m3` datetime 严格递增 + 聚合 open 落 `endGlobalIndex` 窗口」校验，使损坏训练集在 load 期被拒，而非靠渲染层 fail-safe 兜底（GIGO）。

- **状态：** 已实施（plan 全任务完成，待 codex:adversarial-review）
- **作用域：** trust-boundary（持久化 ingest 校验）→ 须走 `codex:adversarial-review`
- **前置：** 聚合感知 reveal RFC（PR #115，`7b1849a`）的 codex R4 HIGH residual
- **版本：** v1.3

---

## 一、背景与问题

### 1.1 R4 残留的由来

聚合感知 reveal RFC（`docs/superpowers/specs/2026-06-15-aggregate-aware-reveal-design.md`）引入 `PartialAggregateCandle.synthesize`，从已揭示的 `.m3` 合成「进行中聚合 K 线」。其定位逻辑：

```swift
let rawStart = m3.partitioningIndex { $0.datetime >= original.datetime }
let start = min(rawStart, tick)   // codex R1-H fail-safe clamp
```

`partitioningIndex` 的契约（`BinarySearch.swift`）要求谓词在序列上**单调**，否则「result is undefined」。这里谓词是 `$0.datetime >= original.datetime`，因此正确性依赖 **`.m3` 的 `datetime` 单调递增**，以及**聚合 K 线的 `datetime` 能在其 `endGlobalIndex` 窗口内被定位到**。

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

**第二个 reader（`#if DEBUG` 镜像）：** `PreviewTrainingSetReader`（`PreviewFakes/PreviewTrainingSetReader.swift`，SwiftUI preview / debug seed 用）通过 `validateCandles` **逐项镜像** `DefaultTrainingSetReader.loadAllCandles` 的全套校验，并带 in-code 维护契约（line 8「production validateCandles 改了 → 这里同步改」），目的是让「reader 返回 = 已校验」不变量「在测试和生产都成立」。因此本 RFC 的两项 reader 校验**必须同步镜像进 `PreviewTrainingSetReader.validateCandles`**（否则 preview 路径静默漏校验、违反该契约）。

**m3 datetime 的消费者（依赖排序但无任何保证）：** `synthesize`（`PartialAggregateCandle.swift:20`）、`candleDatetime`（交易记录时间戳，`TrainingEngine.swift:404`）直接读 **m3** `datetime` 排序；`CrosshairLayout.swift:89`（`candles[snappedIndex].datetime`）读**显示周期**（含聚合）datetime 作时间轴标签（仅显示，见 §8 R-B）。

**未守的（本 RFC 补齐）：**

1. **`.m3` `datetime` 单调性** —— reader / make / init **均未校验**。reader 校验的是 `endGlobalIndex`，不是 `datetime`。
2. **聚合 open 落窗口** —— 聚合（非 m3）K 线的 `datetime` 是否能在其 `endGlobalIndex` 窗口内的 m3 轴上被定位到，无校验。`datetime` 越界（指向未来 m3 / 空 bucket）会让 `partitioningIndex` 返回越界 start。

### 1.3 影响（为何值得修）

- 渲染层因 R1-H clamp 不会崩 / 不泄漏未来，但**合成出有界错误的 OHLC**（错根），属静默错渲染。
- 交易记录时间戳（`candleDatetime`）若 m3 datetime 乱序，可能取到错误时间。
- 这是 codex 治理闸门维持 needs-attention 的根因：PR #115 是靠 `attest-override` 接受 residual 合入，`codex-verify-pass` 被 bypass。补齐本校验后，该类损坏在 load 期即被 reject，R4 真正关闭。

---

## 二、目标与非目标

### 2.1 目标（in scope）

在数据信任边界补两项校验，损坏即拒（reject-load）：

1. **`.m3` `datetime` 严格递增。**
2. **每根聚合（非 m3）K 线的 `datetime` 落在其 `endGlobalIndex` 窗口内**（open time 在 m3 轴上解析到的首个索引 `s ≤ endGlobalIndex`）。

闸门位置（用户拍板 = Reader + make 纵深）：

- **Reader（生产信任边界，主校验）：** 两项全做，抛 `.persistence(.dbCorrupted)`，作为可恢复错误上抛 UI（与 reader 既有内容校验同行为；**不**自动删文件——详见 §五）。**两项均同步镜像进 `PreviewTrainingSetReader.validateCandles`**（#if DEBUG 第二 reader，维护契约要求；§1.2）。
- **`make`（普适末线，纵深防御）：** 镜像**校验 1（m3 datetime 单调）**，抛 `.trainingSet(.emptyData)`（与既有 `isContiguousM3Axis` 同族）。作用是**消除未定义行为**：使 `synthesize` 的 `partitioningIndex` 谓词在任何构造路径（fake / in-memory / 未来非 GRDB 源）上单调、结果良定义。**不**保证窗口正确性——非 GRDB 源喂入窗口越界聚合时，由 `synthesize` 的 `min(rawStart, tick)` clamp 兜底为**有界 fail-safe**（不崩 / 不泄未来 / Y 轴不越界），即 bounded-GIGO，不在 make 关闭（生产路径由 reader 校验 2 全覆盖）。

### 2.2 非目标（out of scope，文档登记）

- **不**把 `DefaultTrainingSetDataVerifier`（warmup ≥30 根 / monthly ≥8 根等内容计数规则）接进 load 路径。该 verifier 当前仅在**下载验收**路径（`DownloadAcceptanceRunner.swift:85`）跑，从不在 load-to-engine 跑——这是一个**内容策略**缺口，与本 RFC 的**单调性/窗口**关注点正交，登记为相邻 residual（§8 R-A），另案处理。
- **不**改 `currentCandleIndex` / `makeViewport` / 任何渲染语义（前序 RFC 已冻结）。
- **不**在 `make` 镜像校验 2（聚合窗口）。理由见 §2.1 make 条目（render clamp 已对非 GRDB 源 fail-safe 兜底）。
- **不**在 `init`（末线 `precondition`）加 datetime 校验。`init` 仅经 `make` 可达（已校验）；现有 `isContiguousM3Axis` 在 init 复检属既有模式，本 RFC 不扩张该 trap 面（YAGNI）。
- **不**改 `loadAllCandles` 失败的恢复语义（不把它移进 `cache.delete`+重试区）；见 §8 R-C。

---

## 三、数据模型事实（grounding）

- `KLineCandle.datetime: Int64`（Unix epoch 秒，UTC）。`globalIndex: Int?`（仅 m3 非 nil，且 `== endGlobalIndex == 数组下标`）。`endGlobalIndex: Int`（非可选）。
- 各周期独立源（per-period CSV + 各自 pandas 指标），聚合**非从 3m 重采样**；`global_index` 仅赋 3m，聚合 `globalIndex=nil`、有 `endGlobalIndex`（datetime 二分到 3m 轴）。
- **聚合 bucket 构造（`generate_training_sets.py:101-110`，本 RFC 校验 2 的依据）：** 第 k 根聚合的 `datetime` = vendor 周期 open 原始时间戳（`opens = d["datetime"]`，**不**吸附到 3m）。它覆盖半开区间 `[open_k, open_{k+1})`：`end_global_index = bisect_right(3m_dts, open_{k+1}-1) - 1`，clamp `[0, N3-1]`（= 区间内**最后一根** 3m）。**首根**成分 = 首个 `datetime >= open_k` 的 3m = `partitioningIndex{ datetime >= open_k } = s`。故 bucket 在 m3 轴上 = `[s, endGlobalIndex]`，结构不变量 `s <= endGlobalIndex`。
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

**严格** `>`（非 `>=`）：重复时间戳会使 `partitioningIndex` 对「首个 `datetime >= X`」的定位歧义，视为损坏。后端 `import_csv.py:64-65`（`drop_duplicates(subset=["datetime"])` + 升序排序）保证真实数据严格递增，故 `>` 不误杀（§6）。

- **Reader：** 在主循环对 `period == .m3` 的行追踪上一根 datetime；违反 → `throw AppError.persistence(.dbCorrupted)`。
- **make：** 新增私有静态 helper `isStrictlyIncreasingM3Datetime(_ m3:) -> Bool`，在现有 `isContiguousM3Axis` guard 之后调用；违反 → `throw AppError.trainingSet(.emptyData)`。

### 4.2 校验 2：聚合 open 落 `endGlobalIndex` 窗口（仅 Reader）

前置（**硬性顺序要求**）：校验 2 的任何 `partitioningIndex` 调用之前，**校验 1（m3 datetime 严格递增）必须已执行并通过**。原因：reader 取行是 `ORDER BY period, end_global_index`，m3 数组按 `endGlobalIndex` 存储顺序排列（既有 m3-axis 校验保证 `endGlobalIndex == 数组下标`），但**这只证明按下标有序、未证明按 datetime 有序**——「m3 数组的存储顺序恰为 datetime 升序」正是校验 1 才证明的事实。若实现把校验 2 排到校验 1 之前/之外，损坏文件的非单调 m3 datetime 会让 `partitioningIndex` 谓词非单调 → result undefined（`BinarySearch` 契约）→ 校验 2 可能伪通过或误拒。m3 非空（reader 既有逻辑保证「有聚合则必有 m3」；m3 缺失则 result 为空、无聚合可遍历、校验 2 vacuous）。

**为何是窗口下界 `s <= endGlobalIndex` 而非精确匹配 `m3[s].datetime == C.datetime`：** 见 §3「聚合 bucket 构造」。聚合 `datetime` 是 vendor 周期 open 原始时间戳，不吸附到 3m；bucket = `[s, endGlobalIndex]`，`s = partitioningIndex{ datetime >= C.datetime }` 恰是真实首根成分索引。**精确匹配会误杀合法数据**——任何 vendor open 不恰好等于某 3m 时间戳的聚合（如 60m open=09:30 vs 首根 3m=09:33）都会被错拒。`m3[s]` 按区间定义**就是** bucket 真实首根成分，故 `m3[s].open` 正确；`synthesize` 取 `constituents.first!.datetime`（= `m3[s].datetime`，真实成分）而非 `original.datetime` 正是为兼容此偏移。结构不变量 `s <= endGlobalIndex` 才是正确的边界校验。

对每个 `period != .m3` 的每根 candle `C`：

```
let s = m3.partitioningIndex { $0.datetime >= C.datetime }
require s <= C.endGlobalIndex
```

捕获：① **空 bucket**（窗口内无 3m 成分，data gap → `s > endGlobalIndex`）② **future-overflow**（`C.datetime` 大于所有 m3 → `s = m3.count > endGlobalIndex`，因 `endGlobalIndex ≤ m3Max = m3.count-1`）③ open 被推到窗口末之后。违反 → `throw AppError.persistence(.dbCorrupted)`。落点：reader `loadAllCandles` 内、m3 块（`m3Candles` 已可得）之后，遍历非 m3 candle。

**边界正确性（loose bound 下，已验证，写进设计以防回归）：**

- **pre-window / straddling 聚合（R1-H1）：** `C.datetime ≤ m3[0].datetime` → 全部 m3 满足谓词 → `s = 0`；pre-window 时 `endGlobalIndex=0`（后端 clamp）→ `0 ≤ 0` 通过；straddling 时 `endGlobalIndex>0` → 通过。**不破坏 R1-H1 对 clamped predecessor 的免疫**，亦与 synthesize 的 `min(rawStart=0, tick)` 行为一致。
- **future-overflow：** `s = m3.count > endGlobalIndex` → 拒绝。
- **loose bound 的残留容忍（已知、有界、可接受）：** 若 agg.datetime 被损坏到仍 `s ≤ endGlobalIndex` 但偏离真起点，synthesize 多/少含同窗内成分 → **有界错根**（⊆ 已揭示 m3、不泄未来），与 render clamp 同 GIGO 类。检测真起点需独立真值（无），故容忍。

---

## 五、失败模式与恢复

- **reject-load（抛错）**，不 sanitize / 不 best-effort——与 reader 既有全部内容校验、E2 PositionManager throwing decoder 一致。

- **Reader 抛 `.persistence(.dbCorrupted)` 的实际去向（修正 v1.0 的错误声明）：** 两项新校验落在 `loadAllCandles()` 内。在 coordinator 四个 load 方法中，`loadAllCandles()` 处于**内层 `do` 块**（`TrainingSessionCoordinator.swift:168-187` 及对应处），其 catch 仅 `reader.close()` + 重抛为 `AppError`（L183-187），**不**做 `cache.delete` + 换文件重试。`cache.delete`+重试的 `isCorruptTrainingSet` 闸门**只**包裹 `openReader`（= `dbFactory.openAndVerify`，M0.1 schema 版本检查，L159-164），而 `openAndVerify` **不**调 `loadAllCandles`。因此新校验的 `.dbCorrupted` 会作为**可恢复错误上抛给 UI**，**与 reader 所有既有内容校验（endGlobalIndex / OHLC / m3-axis）行为完全一致**。`isCorruptTrainingSet`（L537）虽匹配 `.persistence(.dbCorrupted)`，但其注释明示「仅在 openReader 调用栈内用」，本路径不经过它。

- **本 RFC 不改这一既有行为**（把 `loadAllCandles` 移进 delete+重试区是非平凡 coordinator 改动，且会改动既有内容校验的恢复语义，超本 RFC 作用域，见 §8 R-C）。新校验与既有内容校验同档：可恢复、UI 呈现、不自动删文件。

- **make 抛 `.trainingSet(.emptyData)`（`isRecoverable == true`）：** 由 UI 呈现。此路径主要服务 fake / 非生产构造；生产路径已被 reader 在更早处以 `.dbCorrupted` 拦下。

---

## 六、信任边界、治理与 CONTRACT_VERSION

- **trust-boundary 变更：** 持久化 ingest 校验收紧 → 须 `codex:adversarial-review`（`codex-verify-pass` required check）。codex 配额耗尽时按既有惯例走 opus 4.8 xhigh fallback + `attest-override`（user TTY）。

- **CONTRACT_VERSION：不 bump（已核 backend-safe）。** 本 RFC 不改 schema / DDL / 字段 / 序列化格式；frozen `schema.sql` 不变。它只收紧对本就非法数据的拒绝（非单调 datetime / 越界聚合在消费端本就是 undefined behavior）。后端 `import_csv.py:64-65`（`drop_duplicates(subset=["datetime"], keep="last")` + `sort_values("datetime")`）与 `generate_training_sets.py:94/102`（按 datetime 升序）保证 m3 datetime **严格递增**（重复已丢），故校验 1 不拒任何真实有效数据；校验 2 的 `s ≤ endGlobalIndex` 是后端 bucket 构造的结构不变量（§3/§4.2），合法聚合恒满足。

- **观察（非本 RFC 引入、不修）：** 后端 `end_global_index` 对稀疏/尾部聚合理论上可能产生相邻相等值——若发生，**既有** reader L90（endGlobalIndex 严格递增）已先拒；与本 RFC 校验 2 无关，属既有正交关注，列此以免后续 reviewer 误判归因。

- **codeowners / workflow 文件：** 不改。

---

## 七、测试策略

全部 host `swift test`（reader 测试在 `KlineTrainerPersistenceTests`，make 测试在 `KlineTrainerContractsTests`）+ Mac Catalyst `build-for-testing`。

**Reader（`KlineTrainerPersistenceTests`，需建带 `klines` 表的临时 GRDB 库 fixture）：**

1. happy-path 回归：m3 datetime 严格递增 + 聚合 open 落窗口 → `loadAllCandles()` 成功、字典完整。
2. m3 datetime 非严格递增（含①下降 ②重复）→ 抛 `.persistence(.dbCorrupted)`。
3. 聚合 datetime 越界（指向未来 m3，`s > endGlobalIndex`）→ 抛 `.persistence(.dbCorrupted)`。
4. pre-window 聚合（`datetime` 早于首根 m3、`endGlobalIndex=0`）→ **通过**（R1-H1 不回归 killer）。

**make（`KlineTrainerContractsTests`，纯内存 dict）：**

5. m3 datetime 非严格递增的内存 dict 喂 `make` → 抛 `.trainingSet(.emptyData)`（纵深防御）。
6. happy-path 内存 dict → `make` 成功（回归，确认未误伤）。

**Mutation-verify（每个新 guard）：** 临时 revert 该 guard → 对应测试必须 FAIL（红）→ 恢复 → 绿。证明测试真锚定 guard，非 vacuous。

**强 fixture 要求（吸取前序 vacuous-fixture 教训）：**
- 校验 2 的越界测试 fixture 必须让 `s` 真正 `> endGlobalIndex`（聚合数足够、m3 轴足够长），不能用「m3 只有 1-2 根」使任何分支都过。
- 校验 1 的「重复 datetime」fixture 必须保持 `endGlobalIndex` **严格递增**（datetime 是独立列），使失败可归因于校验 1 而非既有 L90 endGlobalIndex 闸门——否则 mutation-verify（revert 校验 1）会因 L90 仍红而误判通过。

---

## 八、相邻 residual（登记，不在本 RFC 修）

- **R-A：** `DefaultTrainingSetDataVerifier`（warmup/content 计数）从不在 load 路径跑（仅下载验收）→ 缓存后内容漂移 / 未经下载验收的文件会带「内容不足」绕过到引擎。内容策略缺口，另案。
- **R-B：** 聚合（非 m3）周期的 `datetime` **单调性**本身未单独校验（本 RFC 只校验聚合 open 的**窗口落点** `s ≤ endGlobalIndex`，不要求聚合 datetime 序列整体单调）。唯一依赖聚合 datetime 的消费者是 `CrosshairLayout.swift:89` 的**十字光标时间轴标签**（显示用）——聚合 datetime 乱序 → 标签显示错误时间，**非泄漏 / 非定位错误 / 非崩溃**，接受为 residual。若未来有消费者按聚合 datetime 二分定位，需补。
- **R-C：** reader 内容校验（含本 RFC 两项 + 既有 endGlobalIndex/OHLC/m3-axis）失败经内层 catch 上抛，**不自动 `cache.delete`+重试**（该恢复仅包裹 `openReader`/schema 检查）。把 `loadAllCandles` 纳入 delete+重试区可改善损坏文件的自动剔除，但属既有行为改动 + 非平凡 coordinator 重构，另案。

---

## 九、验收标准（高层；非编码者可执行清单见 `docs/acceptance/2026-06-16-persistence-scope-validation.md`）

- 损坏训练集（m3 datetime 非单调 / 聚合 open 越界）在 `loadAllCandles()` 即被拒为 `.dbCorrupted`，作为可恢复错误上抛 UI（不自动删文件，与既有内容校验同档），不再静默到达渲染层。
- 良性训练集（含 pre-window clamped 聚合）照常 load 成功，无回归。
- fake / 内存 dict 路径：m3 datetime 非单调时 `make` 拒为 `.emptyData`。
- 全部既有测试 + 新增测试绿；Catalyst build-for-testing 成功。
- codex:adversarial-review 收敛（或 quota fallback 至 opus 4.8 xhigh APPROVE + 文档化 residual）。

---

## 十、变更记录

- **v1.0**（2026-06-16）：初稿。brainstorming 收敛后写入。闸门位置 = Reader + make 纵深（user 拍板）。
- **v1.1**（2026-06-16）：opus 4.8 xhigh 对抗 review 第 1 轮（2H/3M/2L）后修订。
  - **#1 [HIGH] 修正恢复声明（v1.0 误判）：** 删去「复用 cache.delete+换文件重试」错误声明。核实 `loadAllCandles` 在内层 catch 上抛、不经 `isCorruptTrainingSet`（仅包裹 `openReader`/schema 检查）；新校验作可恢复错误上抛 UI，与既有内容校验同档（§2.1 / §五 / §九 改写，§8 新增 R-C）。
  - **#2 [HIGH] 驳回精确匹配建议、保留 loose bound（附 backend 证据）：** review 建议改 `m3[s].datetime == C.datetime`；经核 `generate_training_sets.py:101-110`，聚合 datetime 是 vendor 原始 open（不吸附 3m），bucket = `[s, endGlobalIndex]`，精确匹配会误杀合法数据。保留 `s ≤ endGlobalIndex`，并在 §3/§4.2 补 backend bucket 构造依据。
  - **#3 [MEDIUM] 消解：** 因不采精确匹配，R1-H1 与精确匹配的冲突不存在；§4.2 显式列 loose bound 下 R1-H1 通过的数值推演。
  - **#4 [MEDIUM] make 措辞修正：** make 校验 1 是「消除未定义行为」（谓词单调）非「关闭窗口正确性」；窗口正确性对非 GRDB 源由 render clamp 兜底（bounded-GIGO）。§2.1/§2.2 改写。
  - **#5 [MEDIUM] 补漏消费者：** §1.2 加 `CrosshairLayout.swift:89`；§8 R-B 改为「唯一聚合 datetime 消费者是十字光标显示标签，乱序仅错标签非泄漏，接受」。
  - **#6 [LOW] 测试 fixture 约束：** §7 加「重复-datetime fixture 须保 endGlobalIndex 严格递增以归因校验 1」。
  - **#7 [LOW] CONTRACT_VERSION 确认 backend-safe：** §6 补 import_csv/generate 的 datetime 去重+排序证据 + 稀疏聚合 endGlobalIndex 既有 L90 拒的观察。
- **v1.2**（2026-06-16）：opus 4.8 xhigh 对抗 review **R2 = APPROVE（0 Critical/0 High）**，所有 R1 项 confirmed-resolved，#2 精确匹配争议 R2 独立核 backend 后判作者方对。应用 R2 唯一 LOW（**N2**）：§4.2 前置改为**硬性顺序要求**——校验 2 的 `partitioningIndex` 之前校验 1 必须已过（m3 数组按 endGlobalIndex 存储、仅校验 1 证明其 datetime 升序，防实现重排引入 undefined）。设计收敛，进 writing-plans。
- **v1.3**（2026-06-16）：writing-plans + opus 4.8 xhigh **plan-review R1 HIGH** 反哺——发现第二个 reader `PreviewTrainingSetReader`（#if DEBUG 镜像，带 in-code 维护契约）未被覆盖。§1.2/§2.1 补：两项校验须同步镜像进 `PreviewTrainingSetReader.validateCandles`（否则 preview 路径静默漏校验、违反契约）。plan 已把镜像折入 Task 1/2。
