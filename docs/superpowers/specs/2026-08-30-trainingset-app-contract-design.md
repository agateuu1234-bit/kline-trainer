# 训练组 ↔ App 契约对齐设计（`.db` 扩展名 + 跨周期全局索引）

> 日期：2026-08-30 · 分支 `feat/trainingset-app-contract-fix` · base `main@1437529`
> 触发：2026-08-30 NAS 真机验收（runbook P13/P14）—— 手机下载 3 个训练组全部失败。
> 结论：失败与 NAS 部署无关，是**后端产物与 App 读取器之间两条一直存在、从未被端到端测过的契约不符**。

---

## 1. 问题（全部经实测，非推演）

真机症状两次，逐次定位到两条独立缺陷。

### 1.1 缺陷 A —— zip 内文件扩展名

| 侧 | 事实 | 出处 |
|---|---|---|
| 后端 | zip 内恰好一个文件，名为 `{stock_code}_{start_datetime}.db` | `backend/generate_training_sets.py:403` + `:371`（`arcname=db_path.name`）；旁注原文「文件名仍用 `{code}_{start}.db` 以保持 zip 内 arcname 契约不变」 |
| App | 要求「exactly 1 个 regular file 且 path 后缀 `.sqlite`（lowercased）」，否则 `AppError.trainingSet(.unzipFailed)` | `DefaultZipExtractor.swift:26`；契约文字 `ZipExtracting.swift:10-11` |
| 部署 spec | 自己写着「zip 内是单个 `.db`」 | `docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md:56` |

矛盾一直摆在纸面上。用户可见症状：「训练组解压失败」。形态检查发生在解压之前，故表现为「下载成功、解压失败」。

### 1.2 缺陷 B —— 早于 3m 轴的历史 K 线，`end_global_index` 全被压成 0

后端 `assign_global_indices()`（`backend/generate_training_sets.py:273-296`）对每个周期的每根 K 线求
`j = bisect_right(three_dts, upper) - 1`，再 `egi.append(max(0, min(j, n3 - 1)))`（`:292`）。

**整根早于 3m 轴起点**的 K 线，`bisect_right` 返回 0 → `j = -1` → 被 `max(0, …)` 压成 **0**。

这不是偶发：`PERIOD_BEFORE_CAP`（`:45-46`）里 **`monthly` 的 before cap 是 `None`（有多少历史取多少）**，而 1 分钟源数据只有约一年 —— 故**每一个训练组**都必然携带大量早于 3m 轴的高周期历史。

实测（三个真实训练组，逐个查库）：

| 周期 | 行数 | 不同 `end_global_index` | 压成 0 的行数 | 早于 3m 轴起点的行数 |
|---|---|---|---|---|
| 3m | 12870 | 12870 | 1（首根，正当） | 0 |
| 15m | 2694 | 2576 | 119 | 120 |
| 60m | 786 | 646 | 141 | 142 |
| daily | 309 | 162 | 148 | 149 |
| weekly | 154 | 36 | 119 | 120 |
| monthly | 422 | 10 | **413** | 414 |

（3m 轴最早 2025-08-28；monthly 最早 1991-01-04。「压成 0 的行数」比「早于轴起点的行数」少 1，差的那根是**跨在轴起点上**的那一根 —— 它的覆盖窗口延伸进了轴内，拿到正当的非零编号。）

App 侧 `DefaultTrainingSetReader.loadAllCandles()` 第 90 行要求**每个周期内 `end_global_index` 严格递增**，任何重复 → `AppError.persistence(.dbCorrupted)`。用户可见症状：「本地数据损坏」，界面汇总为「3 个未完成」。

### 1.3 冻结契约自身的冲突

`kline_trainer_modules_v1.4.md`：

- `:752` —— 训练组不变量含「**月线前 ≥30**」；
- `:2302` R03 —— 「`global_index/end_global_index` **严格递增** + 前后端 assert」。

30 根月线 = 2.5 年历史，而 1 分钟源数据只有约一年 ⇒ **这两条要求在真实数据上不可能同时成立**。冲突写在契约里，不是某一侧写错了一行。

### 1.4 为什么藏到今天

仓库里**没有任何一条测试把「生成器真实产物」喂给「App 读取器」**。两侧各自的测试都绿：后端测自己的纯函数，App 测自己手写的 fixture。缝在中间，无人负责。

**推论（须在措辞上守住）**：App 至今**从未成功消费过一个真实生成的训练组**；此前跑通的全是 debug fixture。

---

## 2. 决策

### 2.1 采纳：路线 A —— 收紧地放宽 App 侧读取规则

**「后端不动」的准确表述**：数据格式、既有产物、`content_hash` 全部不动；后端**唯一**的改动是装配期新增一条 assert（§5.5），其作用是让不满足契约的候选起点在生成时就被跳过（走既有 bounded retry），而不是产出后到用户设备上才爆。它不改变任何已生成产物。

**用户已拍板（2026-08-30）**：
1. 早于 3m 轴的老历史 **要当普通历史显示出来**（契约「月线前 ≥30」本来的意图 —— 看月线就是为了判大局）；
2. 扩展名一条 **改 App，让它接受 `.db`**；
3. **要补**「后端真实产物 → App 读取器」的常驻测试。

### 2.2 否决：路线 B —— 给早于轴的 K 线一个专用标记（新列或哨兵值）

语义更干净（不给 `0` 赋双重含义），但属**数据格式变更** ⇒ `TRAINING_SET_SCHEMA_VERSION` bump ⇒ **全部已生成训练组作废并重算指纹**；且本 App 可能公开上架，格式升级还要连带处理「用户手机上已下载的旧训练组」的迁移。当前真实数据链路刚打通第一次，不值得动格式。**记为后续可选演进**：若 `0` 的双重含义日后确实碍事，届时再评估。

### 2.3 否决：把 3m 轴向前延长以覆盖全部历史

券商源数据不存在那么久远的分钟级数据。物理上不可行。

### 2.4 否决：砍掉早于轴的历史（只留轴内那段）

轴内月线仅约 9 根（实测），既违反契约 `:752`「月线前 ≥30」，也让「切到月线判大局」这个训练目的落空。

---

## 3. 契约变更（精确表述）

### 3.1 跨周期全局索引

**原（`kline_trainer_modules_v1.4.md:2302` R03）**：
> `global_index/end_global_index` 严格递增 + 前后端 assert

**新**：

> **`.m3`（全局 tick 轴）**：`global_index == end_global_index == 数组下标`，从 0 起**严格递增**、无缺口、不得为 NULL。**一条不放宽。**
>
> **其它周期**：`end_global_index` 按 `datetime` 升序**非递减**；**重复值只允许出现在 `0` 上**。`0` 的含义是「该 K 线整根早于（或恰起于）`.m3` 轴的第一根」，即纯历史上下文，不参与全局 tick 推进。
>
> **全部周期（含 `.m3`）**：周期内 `datetime` **严格递增**。此前该条只对 `.m3` 显式成立，其它周期靠「`end_global_index` 唯一且与 `datetime` 同序」隐式成立；放宽后隐式保证消失，必须显式化（§4.4）。
>
> **读取次序**：读取端取数必须以 `(period, end_global_index, datetime)` 排序 —— 并列时若无次序键，数组次序在 SQL 语义上无定义（§4.4）。
>
> 前后端各自 assert：后端在装配时拒绝不满足者（`GenerateSkipException` → 换起点重试），App 在读取边界拒绝不满足者（`.dbCorrupted`）。

### 3.2 zip 形态

**原（`ZipExtracting.swift:10-11`）**：「exactly 1 个 regular file 且 path 后缀 `.sqlite`」

**新**：「exactly 1 个 regular file 且 path 后缀为 `.sqlite` 或 `.db`（均 lowercased 比较）；其它扩展名、0 个、≥2 个、或含任何其它 regular file → `.unzipFailed`」。

`.sqlite` 保留是为了**向后兼容**既有 fixture 与测试资产；生产产物用 `.db`。

---

## 4. 为什么这样是安全的（四条论证，均有实测支撑；4.4 是自审新增的必修项）

### 4.1 「非递减」足以让二分查找正确

App 里所有依赖 `end_global_index` 的查询都是 `partitioningIndex`（Swift 的分区二分），使用点：
`TrainingEngine.swift:541 / :563 / :727`、`MarkersLayout.swift:25`、`PanLinkage.swift:27,31`。

`partitioningIndex` 的前置条件是「数组按谓词**已分区**」（前段全 false、后段全 true），而不是「严格递增」。谓词形如 `$0.endGlobalIndex > current` / `>= target`，在**非递减**序列上分区性成立。故放宽不破坏任何一处二分。

`.m3` 的严格递增与连续性另有独立校验（`DefaultTrainingSetReader.swift:153-160`、`TrainingEngine.swift:159-163, :736`），本次**一律不动**。

### 4.2 `0` 这个桶是**自限**的 —— 现存校验已经挡住了滥用

`DefaultTrainingSetReader.swift:182-183` 已有一条校验：

```
let s = m3Candles.partitioningIndex { $0.datetime >= c.datetime }
guard s <= c.endGlobalIndex else { throw .dbCorrupted }
```

对 `end_global_index == 0` 的 K 线，该式要求 `s == 0`，即**它的开盘时刻必须 ≤ `.m3` 首根的开盘时刻**。换言之：**只有真正早于（或恰起于）轴起点的 K 线才可能携带 0**；任何轴内 K 线试图带 0 会被这条既有校验直接拒绝。

⇒ 放宽后，`0` 桶里只可能是纯历史，**不会**成为「任意数据混进来」的通道。

**实测**（三个训练组逐个查）：`end_global_index = 0 且 datetime > min(3m datetime)` 的行数 = **0 / 0 / 0**。

### 4.3 放宽不引入未来数据泄露

用 App 自己的「已揭示」算法（`endGlobalIndex <= 当前 tick`）在真实数据上算，训练起点 tick=150 时各周期可见：

| 周期 | 可见根数 | 覆盖时间 | 末根是否 ≤ 训练起点 2025-09-01 |
|---|---|---|---|
| monthly | 414 / 422 | 1991-01-05 → 2025-08-01 | 是 |
| weekly | 120 / 154 | 2023-05-04 → 2025-08-25 | 是 |
| daily | 150 / 309 | 2025-01-17 → 2025-08-29 | 是 |
| 60m | 149 / 786 | 2025-07-09 → 2025-08-29 | 是 |
| 15m | 149 / 2694 | 2025-08-18 → 2025-08-29 | 是 |
| 3m | 151 / 12870 | 2025-08-28 → 2025-09-01 | 是 |

无一根越过训练起点。且这正是 §2.1 用户要的「老历史当普通历史显示」。

### 4.4 ⚠️ 放宽会**连带**掀出一个隐藏假设：并列时数组次序无定义

这是本设计自审时抓到的、**不修就会引入新缺陷**的一条。

`DefaultTrainingSetReader.swift:67` 取数的 SQL 是：

```
ORDER BY period, end_global_index
```

**没有并列时的次序键**。在「严格递增」前提下 `end_global_index` 在周期内唯一，次序被唯一确定；一旦允许在 `0` 上并列，那 413 根月线彼此的先后**在 SQL 语义上就没有定义了**。当前它们恰好按插入顺序（= datetime 升序）返回，是因为存在 `idx_period_endidx ON klines(period, end_global_index)` 且并列时走 rowid 次序 —— **这是实现细节，不是保证**。

后果不在二分（§4.1 只要求分区性，与并列内部次序无关），而在**渲染**：`result[period]` 数组按原次序被切片绘制，次序错乱 = 月线图上 K 线前后颠倒。

同时暴露另一件事：现有代码**只对 `.m3` 校验了 datetime 严格递增**（`:161-166`），其它周期从未校验 —— 以前靠「egi 唯一 + egi 与 datetime 同序」隐式成立，放宽后这条隐式保证消失。

**实测**（三个真实训练组逐个查）：每周期 `datetime` 重复数 = **0 / 0 / 0**；「按 `(end_global_index, datetime)` 排」与「按 `datetime` 排」的结果**逐行一致**（差异行数 0 / 0 / 0）。故下面的修正对真实数据是可满足的，且不改变现有次序。

---

## 5. 改动清单

### 5.1 App —— `DefaultTrainingSetReader.swift`：次序键 + 分周期判据 + datetime 单调

三处，缺一不可（§4.4）：

**(a) SQL 补并列次序键**（`:67`）：

```
ORDER BY period, end_global_index, datetime
```

**(b) 每周期 datetime 严格递增** —— 把现有那条只作用于 `.m3` 的校验（`:161-166`）推广到**全部周期**。这是 §4.4 里失去的隐式保证的显式替代，也是本次唯一**收紧**的判据。

**(c) `end_global_index` 判据按周期拆分**（`:90`）：

- `.m3`：`endGlobalIndex <= prev` → `.dbCorrupted`（**与现状逐字相同**）；
- 其它周期：`endGlobalIndex == prev && prev != 0` → `.dbCorrupted`（非零重复）。

⚠️ **关于「倒退」（`endGlobalIndex < prev`）**：在 (a) 的 `ORDER BY` 下，周期内 `end_global_index` **由查询本身保证非递减**，该分支**结构上不可达**。本仓明令禁止把不可达条件写成「看起来在把关」的判据（会产出零判别力的测试）。故：**保留一条防御性 `< prev` 抛错**，但在实现与注释中写明它不可达，并**以「不变量锁测试」的形式**固定 —— 锁测试断言的是「SQL 含 `end_global_index` 作为排序键」这一结构事实，而非试图构造一个走到该分支的用例。

⚠️ 实现约束：该循环遍历的是排序后的结果集，`lastEnd` 按周期分别记。**不得**改成「先分组再逐组校验」之类的重构 —— 保持 surgical。

### 5.2 App —— `DefaultZipExtractor.swift:26`

后缀判据由 `.sqlite` 扩为 `.sqlite` 或 `.db`；其余形态规则（恰好 1 个、不允许任何其它 regular file、dir/symlink 不计、解压前先查形态）**逐条不变**。

### 5.3 App —— 契约文字

- `ZipExtracting.swift:10-14` 按 §3.2 改写；
- `DefaultTrainingSetReader.swift` 相关注释按 §3.1 改写，并写明 `0` 的语义与 §4.2 的自限论证（这是后人最容易误删的一条，注释必须承重）。

### 5.4 契约文件 —— `kline_trainer_modules_v1.4.md:2302`

R03 行按 §3.1 改写。⚠️ 该文件是**冻结契约**，本次是**修订而非放宽**：一侧收紧（后端新增 assert），一侧按真实数据可满足化。改动须在文件的修订记录里留一行。

### 5.5 后端 —— `assign_global_indices()` 新增装配期 assert

**为什么必须加**（否则 §3.1 的「重复只允许在 0 上」是一句兑现不了的承诺）：

`j = bisect_right(three_dts, upper) - 1` 随 `datetime` 升序**非递减**；两根相邻高周期 K 线拿到**同一个非零** `j`，当且仅当它们的覆盖窗口之间**没有任何新的 3m bar** —— 即 3m 轴内部存在缺口（停牌、数据缺失）。生成器现有的 D9 per-day 硬门只覆盖 `[start, after_end]`（`build_training_windows._try`），**不覆盖 before-context 那 150 根**。故「非零重复」在现有门禁下**不是不可能**，只是三个实测样本里没出现。

若不加 assert，这种切片会被生成、登记、发到手机，然后在用户设备上报「本地数据损坏」—— 失败点离根因最远。

**做法**：在 `assign_global_indices` 返回前（或紧随其后的装配步骤里）断言：对每个非 `.m3` 周期，`end_global_index` 非递减且重复只出现在 0 上；不满足 → `raise GenerateSkipException(...)`。

这正好接进既有的 **bounded retry**（`select_valid_window`，最多 8 个候选起点）：坏起点被跳过、换下一个，不影响产量语义，也不需要新机制。

⚠️ 断言必须**在 zip 与 content_hash 生成之前**，避免产出已落盘再回滚。

### 5.6 常驻测试 —— 补上「后端真实产物 → App 读取器」这道缝

**目标**：让 §1.4 那类缺陷**下一次在 CI 就红**，而不是等真机。

两条测试夹住这道缝：

**(a) 后端侧（Python，host pytest）**：用**生产函数本身**（`assign_global_indices` → `build_training_set_sqlite` → `zip_and_hash`）从一组合成 bar 数据造出一个**小训练组**，其形态必须包含本缺陷的特征 —— 至少一个非 m3 周期有 **≥2 根** K 线落在 `end_global_index = 0`（即合成数据里高周期历史要早于 3m 轴起点）。断言：
1. 产物与仓库里那份 fixture 的**数据库内容**逐表一致（**不比 zip 字节** —— `zipfile.write` 会嵌入文件 mtime，跨机跨时不可复现；比字节必然假红）；
2. 产物满足 §3.1 的全部不变量（这条同时是 §5.5 assert 的正向对照）。

⇒ 生成器日后若改动索引方案，这条会红，fixture 不会悄悄过期。

**(b) App 侧（Swift）**：把 (a) 产出并提交进仓库的 fixture 喂给**真实生产实现**跑完整链路：
`DefaultZipIntegrityVerifier` → `DefaultZipExtractor` → `DefaultTrainingSetDBFactory.openAndVerify` → `DefaultTrainingSetDataVerifier.verifyNonEmpty` → `DefaultFileSystemCacheManager.store`，断言全过。

⚠️ **防空转下限**（本仓反复踩过「测试写了却测不到」）：该测试**必须**先断言 fixture 本身具备特征 —— 「存在一个非 m3 周期，其 `end_global_index = 0` 的行数 ≥2」。若哪天有人用一份没有老历史的 fixture 替换它，这条断言先红，而不是让整条测试静默退化成空转。

⚠️ 该 fixture 同时是 §5.1(a)/(b) 的**正向档**：它必须含「同一周期内多根并列于 0 且 datetime 各不相同」这一形态，否则次序键与 datetime 单调两条判据在这条链路上取不到值。

**为什么合成 bar 数据不违反「fixture 必须照生产真实格式造」**：被测的是**产物的生成路径**，而该路径用的是**生产函数本人**；禁忌是「照想象手写产物格式」，不是「喂合成输入」。fixture 文件本身由生产代码写出，不是手搓的。

---

## 6. 判别力要求（实施阶段硬约束）

本仓的假绿家族反复踩过，故每条新判据都必须配**变异验证**，且逐条记录「红的是哪一条」：

| # | 变异 | 期望 |
|---|---|---|
| M1 | 把 §5.1(c) 的 `.m3` 分支放宽成「只禁非零重复」 | 现有 m3 轴测试变红（证明 m3 那条没被顺手放宽） |
| M2 | 把 §5.1(c) 非 m3 分支的「非零重复」判据删掉 | 需有一条「非零重复」用例变红 |
| M3 | 把 §5.1(b) 的 datetime 严格递增校验删掉 | 需有一条「某非 m3 周期 datetime 乱序」用例变红 |
| M3b | 把 §5.1(b) 的校验**只对 `.m3` 生效**（即退回现状） | 同上那条用例仍须红（防「推广」只写了没接上） |
| M4 | 把 §5.1(a) 的 `, datetime` 次序键删掉 | §5.1(c) 那条「不变量锁测试」变红 |
| M5 | 把 §5.2 的 `.db` 分支删掉 | §5.6(b) 变红 |
| M6 | 把 §5.2 改成「任何扩展名都接受」 | 需有一条「zip 内是 `x.txt`」用例变红 |
| M7 | 把 §5.5 的后端 assert 删掉 | 需有一条「非零重复的合成输入」用例变红 |
| M8 | 把 §5.6(b) 的 fixture 换成没有老历史的 | 该测试的防空转断言变红 |

⚠️ **M2 与 M3 必须互不掩盖**：本仓踩过「两条判据互相掩盖、单独变异都不红」。故除逐条单变异外，**必须补一次 M2+M3 组合变异**，确认组合下仍有测试红，且**记录红的是哪一条**。

**正向对照（必配，防「全是拒了」的套件掩盖恒抛守卫）**：三个**真实**训练组（`851f9444` / `32892a5f` / `150d8d6c`）与 §5.6 的 fixture 必须**被放行**；任一条判据若恒抛，这些正向档会红。

⚠️ `KlineTrainerPersistence` 相关测试注意本仓既有陷阱：Catalyst scheme 必须是 `KlineTrainerContracts-Package`，`set -o pipefail`，新增 UIKit-gated 测试要同步四处基线。本设计的改动均**不在** UIKit-gated 文件内，但闸门仍按既有流程跑。

---

## 7. 兼容性与迁移

| 维度 | 结论 | 理由 |
|---|---|---|
| 训练组 SQLite schema | **不变** | 无新列、无类型变化；`training_set_schema_v1.sql` 一字不动 |
| `TRAINING_SET_SCHEMA_VERSION` | **不 bump（保持 1）** | 数据格式未变；变的是**读取端的接受集合**，且是**放宽** |
| 已生成的训练组（含 NAS 上这 3 个） | **全部继续可用** | 产物零改动；`content_hash` 不变 |
| 用户手机上已缓存的训练组 | **不受影响** | 缓存里存的是解压后的 sqlite，文件名由 `meta.filename`（`.zip`）规范化而来，与 zip 内条目名无关（`DefaultFileSystemCacheManager.swift:145-159`） |
| 旧版本 App 读新训练组 | **与今日相同（仍失败）** | 本次不改产物，故不产生「新数据老 App 读不了」的新错位 |
| 新版本 App 读旧训练组 | **可用** | 见下一行的限定 |
| §5.1(b) 新增「全周期 datetime 严格递增」 | **这是本次唯一的收紧** | 理论上可拒掉一份此前能读的训练组（周期内 datetime 重复或乱序者）。**实测三个真实训练组：每周期 datetime 重复数 0/0/0、次序一致 0/0/0** ⇒ 现有产物不受影响。被拒者本就是坏数据（渲染次序无定义），拒掉是想要的行为 |

⇒ 本次**不需要**任何迁移脚本。

⚠️ 「接受集合是超集」这句只对 `end_global_index` 与扩展名两条成立；datetime 那条是收紧，故上表**不写**「纯放宽」。

---

## 8. 明确不做（YAGNI / 范围外）

1. **路线 B**（专用标记列或哨兵值）—— §2.2 已否决，记为后续可选演进；
2. **后端改产出 `.sqlite`** —— 用户已选「改 App」；
3. **`expose.sh` 看门狗继承 flock 导致窗口期内 `close`/`renew` 恒 `LOCK_TIMEOUT`** —— 2026-08-30 实测三次稳定复现（`/proc` 三重证据），**真缺陷但与本设计无关**，独立小 PR；
4. **App 后端地址不可配（PR-3 从未实施）** —— `KlineTrainerApp.swift:18` 仍硬编码 `http://kline-trainer.local`；本次真机验收靠临时改一行绕过，**PR-3 仍 OPEN**；
5. **每只股票可切片段数受限** —— 往前需 8 个完整月且逐日 1 分钟数据完整，而 1 分钟源数据只有约一年 ⇒ 每股约 3–4 个可用月起点（实测 `000001.SZ` 落在 2025-09-01 与 2025-11-03）。**要量靠多铺股票，不是同股反复切**。属出货量规划，非本次范围；
6. **`verifyNonEmpty` 把「起点前 ≥30」施加到全部周期**（契约 `:752` 只说月线）—— 当前真实数据全部满足（各周期 before cap 为 120/150），**不改**，仅记录该处比契约更严。

---

## 9. 验收判据

1. 三个真实训练组（NAS 上 id=3/4/5）经**真实生产实现**跑完 §5.6(b) 那条链路，六关全过；
2. §6 的 M1–M7 变异逐条跑过，且**报告里写明红的是哪一条测试**（不接受「有测试红了」）；
3. 正向对照全部放行；
4. 后端与 App 两侧闸门按既有流程全绿（后端 Linux CI 零 skip；Catalyst 按既有配方）；
5. **真机**：runbook P14 的 G2（状态行 3 个成功）+ G3（库里 3 行变 `sent`）+ G4（图表画出蜡烛图）全部成立。

⚠️ 判据 5 需重跑 runbook P12–P14；判据 1–4 在 CI 内即可闭合。

---

## 10. 残留与后续

| 编号 | 内容 | 状态 |
|---|---|---|
| TS-R1 | 路线 B（早于轴的 K 线专用标记）作为后续可选演进 | OPEN，无时限 |
| TS-R2 | `expose.sh` 看门狗锁缺陷 | OPEN，独立小 PR |
| TS-R3 | PR-3：App 后端地址可配（`KLINE_BACKEND_BASE_URL`） | OPEN，独立 PR |
| TS-R4 | `verifyNonEmpty` 的「全周期 ≥30」比契约 `:752` 更严 | 已记录，不改 |
| TS-R5 | 出货量规划：每股可用起点约 3–4 个 | 已记录，非本次范围 |

## 附：措辞纪律

本次**不得**声称「真实数据链路已打通」「pilot 已完成」——本设计只解除两条阻断；**真机 G2/G4 通过之前**，「App 能消费真实训练组」这句话没有证据。
