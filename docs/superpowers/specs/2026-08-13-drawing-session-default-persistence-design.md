# 划线「本局默认」持久化设计 spec（持久化 PR）

**日期**：2026-08-13

**上游 spec**（继续全部生效，本文件不推翻其中任何一条）：

- 母 spec `docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md`（D1–D22，**§13 = 全局默认，属 P6**）
- 拆分补充 spec `docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md`（D23–D48）
- 1b-i `docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md`（D49–D67）
- 1b-ii `docs/superpowers/specs/2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md`（D68–D80）
- **自动选中 spec** `docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md`（D81–D89，**D87 = 本片的需求来源**）

**基线**：`origin/main` `20f615a`。分支 `feat/drawing-session-default-persistence`，worktree `.dev/worktree/drawing-default-persist`。
基线闸门（同一 commit `20f615a` 上实跑）：host `swift test` = **`Test run with 1831 tests in 215 suites passed`**。

本 spec 新增决策编号从 **D90** 起（D81–D89 属自动选中 spec）。本文件定义 **D90–D100**。

---

## 0. 范围与由来

### 0.1 需求来源：用户 2026-08-13 裁决（逐字）

> 「每一局训练，然后退出了再回来，其实相当于原来的训练**还没有完全结束**嘛，因为用户没有点结束按键，只是相当于返回了再继续进行训练。……相当于是个**断点**，我重新开始，那也要**继承之前我已经做的这些改动**……而不是重置回我们这个 APP 的默认设置。」

**自动选中 spec 的 D87 已据此定死需求**，本 spec 只负责**实现它**，不重新讨论要不要做。

### 0.2 本片在三 PR 链条中的位置（**次序强制，不可颠倒**）

```
本片（持久化 PR） ──强制──▶ 自动选中 PR ──强制──▶ 1b-ii 撤销 PR
```

**为什么本片必须最先**（**自动选中 spec** 的 D89，那份文件的 §6.8，已实测）：自动选中 PR 的 D86 让画线态一次改样式**同时写「线」和「本局默认」**，而「线」经 `drawingsRevision` → autosave **会落盘**。若本局默认此时尚未持久化，续训后就是「**线是新样式、默认回落出厂**」的**半持久化**坏状态 —— 那是 main 上不存在、由自动选中 PR 制造的。本片先落地，该中间态**结构上不会出现**。

**本片单独上线是净收益**：它修的是 main 上**今天就有**的缺口（`defaultStyle` 在 `KlineTrainerPersistence/` 出现 **0 次**），且本片**不引入任何与之耦合的新落盘写入**。

### 0.3 本 spec 不做

- **全局默认**（齿轮「画线设置」界面 + 它的落盘）—— 母 spec §13 = **P6**，一字不动。
  本片持久化的是**本局覆盖量**，不是全局默认。二者别混。
- 自动选中 / 改样式两套语义（自动选中 spec）。
- 复盘存档 `review_archive`（**可证明排除**，见 D90）。
- 节点 / 多锚 / 放大镜（P1c / P4）。

---

## 1. 行为定义

| 事件 | 本局默认 |
|---|---|
| 局内改样式（画线态 / 选择态无选中） | 更新 **并立刻存盘**（D94） |
| 点「返回」回主页 → 「继续训练」续**同一局** | **继承** |
| App 被杀 / 切后台被系统回收 → 续训 | **继承** |
| 本局**结束**（点结束 / 自动结束）后**新开一局** | **回落**到全局默认（今天无齿轮界面 ⇒ 出厂值；P6 之后 = 齿轮里设的那个）。**用户 2026-08-13 确认** |
| 历史记录 →「再次训练（replay）」 | **算新的一局** ⇒ 开始时回落；replay **自己**局内改的，在 replay 的断点续局时继承。**用户 2026-08-13 确认** |
| 复盘 | **不适用**（改不了，见 D90） |
| 升级前建的旧存档 | **能正常打开**，本局默认回落出厂（D92 约束 ④） |

---

## 2. D90　存档面 = `pending_training` + `pending_replay` 两张表；复盘**可证明**排除

### 2.1 复盘排除的依据是一个**谓词**，不是「大概用不上」

常驻样式面板在复盘**根本不渲染**：

```
TrainingView.swift:116  stylePanelWillBeVisible = showsTradeButtons && isDrawingActive && typeRowExpanded
TrainingView.swift:83   showsTradeButtons        = engine.flow.canBuySell()      // 复盘恒 false
```

⇒ 复盘里**改不了**本局默认 ⇒ 没有任何东西需要存 ⇒ `review_archive` 不在本片存档面内。

### 2.2 ⚠️ 这条排除的**失效条件**必须写死

**P5 若让复盘用上新底栏 / 常驻样式面板，本条排除立刻失效**，必须**同期**把 `review_archive` 一并接上，否则复盘会出现与本片修复前一模一样的丢失。
**实施要求**：源码守卫把这个谓词钉住，一旦被改动就报红，逼实施者回来重新判断本条排除是否仍成立。

⚠️ **必须钉住的是整条可达链，不是其中一项**（codex spec-R2 medium，**已核实为真**）：
上一稿的 G4 只断言 `showsTradeButtons` 仍为 `engine.flow.canBuySell()`。可判据是**三项合取**，
改另外两项（`isDrawingActive` / `typeRowExpanded`）、或**另开一条挂载样式面板的路径**，
G4 都照样绿，而复盘就悄悄具备了改本局默认的能力 —— 且它的改动**不会被存**，正是本片要消灭的丢失。

**改为三条守卫合起来钉**（§8 的 G4 / G4b / G4c）：
1. `showsTradeButtons` 的定义式仍为 `engine.flow.canBuySell()`；
2. **`stylePanelWillBeVisible` 的整条定义式**仍为 `showsTradeButtons && isDrawingActive && typeRowExpanded`；
3. **样式面板的挂载点在 `Sources/` 里恰好 1 处**（防「另开一条路径」）。

**并写死一条无条件规则**：**任何让复盘可达「改本局默认」的改动，必须同期把 `review_archive` 接上**——
守卫是提醒，这条规则才是义务。

### 2.3 replay 为什么必须一起做

replay 的底栏与常驻样式面板**与训练完全相同**（`canBuySell()` 在 replay 为 true），用户在 replay 里同样能改本局默认；replay 有自己的断点续局（`pending_replay` 槽 + `resumePendingReplay`）。少做 replay = 同一个缺口换个入口原样存在。

---

## 3. D91　物理形状：**每表一个可空 TEXT 列**存样式 JSON + `0010` 迁移

### 3.1 为什么必须动 SQL 列，而不是「给模型加个 Codable key」

> **来源：自动选中 spec 的 codex R6 critical。我在那份 spec 里写过「给 `PendingTraining` 的 Codable 加可选 key 即可」，那是错的。**

| 实测事实 | 出处 |
|---|---|
| `pending_training` 是**逐列建表** | `AppDBMigrations.swift:57-71`（+ `0004` 追加 `session_key`） |
| `pending_replay` 同构，建于 `0006` | `AppDBMigrations.swift:164-184` |
| repo 写盘是 `INSERT OR REPLACE INTO pending_training (…14 个具名列…) VALUES (…)`，读盘按列名取 | `PendingTrainingRepositoryImpl.swift:18-45` |
| **`PendingTraining` / `PendingReplay` 的 `Codable` 在生产路径上有几个消费者** | **0 个**（全仓 grep 无 `JSONEncoder` 编解码这两个类型的生产调用） |

⇒ **只加 Codable key 会「什么都不做」**：内存 round-trip 测试全绿，而值从来没进过数据库。
这就是本片最需要防的那种假绿（[[feedback_uikit_gated_evidence_traps]] 同族）。

### 3.2 形状

- 两张表各加 **`drawing_default_style TEXT`（可空）**，存一份 JSON：
  `{"lineSubType":…,"lineStyle":…,"thickness":…,"colorToken":…,"labelMode":…}`
- **一个 JSON 列而不是五个标量列**：与 `drawings.style_json TEXT` 的房内惯例逐字同构（`0009`）。
  「某个字段坏了不牵连其余」这条**由解码器保证**（D92 逐字段容错），**不需要**靠拆五列来实现；
  拆五列只会把一次 `ALTER` 变成十次、把一次读列变成十次，收益为零。
- **模型层**：`PendingTraining` / `PendingReplay` 各加 `drawingDefaultStyle: DrawingDefaultStyle?`
  （`nil` = 旧档 / 未写过）。两个 `init` 的新参数**必须带默认值 `= nil`**，否则 `DebugFixtureData.swift:181`
  等既有构造点全部编译失败。
- **模型 Codable 同步更新**（`decodeIfPresent` / `encodeIfPresent`），但见 §7 的判绿纪律：
  **模型 round-trip 绿 ≠ 落盘成功**，必测证据只认 DB 边界测试。

### 3.3 迁移

```
0010_v1.13_drawing_default_style
    ALTER TABLE pending_training ADD COLUMN drawing_default_style TEXT
    ALTER TABLE pending_replay   ADD COLUMN drawing_default_style TEXT
    PRAGMA user_version = 8
```

- 照 **`0008_v1.10_drawing_reveal_tick`** 的先例（`AppDBMigrations.swift:205-208`）：可空列直接 `ALTER ADD`，
  **不需要 `0009` 那种「建新表 + 回填 + 换名」重建**（那是因为要加 `NOT NULL`/`UNIQUE`/`CHECK`，本片不需要）。
- **`user_version` 7 → 8**（现行终态 7 由 `0009` 设置，`AppDBMigrations.swift:244`）。
- **迁移名里的 `v1.13` 必须与本片同 PR 落地的 `CONTRACT_VERSION` 一致**（codex spec-R4 medium）：
  既有命名 `0006_v1.8` / `0007_v1.9` / `0008_v1.10` / `0009_v1.11` 都是「该迁移所属的契约版本」。
  写成 `v1.12`（bump 前的值）会让这次 DDL 看起来属于**上一个**契约版本，与 m01 矩阵记录的 id 自相矛盾。
- **不动 `v1_4_baselineDDL` / `ios/sql/app_schema_v1.sql`**（v1.4 冻结基线）。

**⚠️ schema-drift 闸门无需改动，且这是可证明的**：`scripts/check_app_schema_drift.sh` 只比对
`v1_4_baselineDDL` 与 `app_schema_v1.sql` 两者；新迁移不碰基线 ⇒ 闸门不受影响。
（`0006` / `0009` 的注释里逐字写着同一条纪律：「只走 migration，不动 v1_4_baselineDDL/app_schema_v1.sql」。）
**实施时不得**为了「保持一致」去改基线 DDL —— 那会真的打红 drift 闸门。

### 3.4 D97　契约版本：**必须 bump `CONTRACT_VERSION` 1.12 → 1.13**，并同步 m01 矩阵

> **来源：codex spec-R1 high。我上一稿写「不 bump」，直接违反本仓写死的治理规则。**

**规则是明文的**（`docs/governance/m01-schema-versioning-contract.md` 的 bump 策略，逐字）：

> **必须 bump 顶层 `CONTRACT_VERSION`**（破坏性 / 跨系统变更）：删 state / 改 raw value / 改既有语义 /
> 改恢复扫描集 / **影响 DDL** / 改 OpenAPI / 任何跨系统契约字段调整

本片新增两列 + 新 migration ⇒ **命中「影响 DDL」** ⇒ 必须 bump。

**⚠️ `CONTRACT_VERSION` 在本仓有 _两份_ 源，且它们之间有跨语言一致性测试**（codex spec-R4 high，**已实测**）：

| # | 位置 | 现值 | 本片要做的 |
|---|---|---|---|
| 1 | `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7` | `"1.12"` | → `"1.13"` |
| 2 | **`backend/qmt_pilot_db.py:798`** | `"1.12"`（头注明写「与 Swift 那份保持一致」） | → `"1.13"` |
| 3 | `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift:8` | `#expect(CONTRACT_VERSION == "1.12")` | → `"1.13"` |
| 4 | `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift:1260` | 同上 | → `"1.13"` |
| — | `backend/tests/test_qmt_pilot_db.py:770` | `assert f'CONTRACT_VERSION = "{CONTRACT_VERSION}"' in swift` | **不要改** —— 它**动态读 Swift 文件**比对，两边同步后自动绿；去改它就是把跨语言守卫改瞎 |

⇒ **只改 Swift 那一份，`backend/tests/test_qmt_pilot_db.py:770` 立刻红**（它读 Swift 源文件做断言）。
⇒ **少改任何一处，本片的闸门都过不去**；改错第 5 行则是把守卫本身弄坏。

**⚠️⚠️ 跨项目连带影响：bump 会让在用的 QMT pilot 库需要 `--reset` 重建**（本片必须提前告知，否则会被误判为回归）：

`qmt_pilot_db.py:1694` 把 `contract_version` 写进 pilot DB 元数据，`:2224` 的**闸 1** 校验
`meta.get("contract_version") != CONTRACT_VERSION` → 不符即抛 `schema_fingerprint_mismatch`
（「schema.sql / pilot_schema.sql / contract_version 与建库时不一致——请用 `--reset` 重建」）。

- 这是**闸门按设计工作**，不是缺陷；
- 但**本片合入后第一次跑 QMT 验证的人会撞上它**。**必须写进 PR 描述**：
  「本 PR bump 了 `CONTRACT_VERSION`，已建的 pilot 库须 `--reset` 重建，这是预期行为」。
- ⚠️ 本片**不负责**替 QMT 重建任何库，也**不得**为了避开这条而放弃 bump ——
  bump 是 m01 的硬要求（见上）。

**本片必须做的另两件事**（照最近一次真 bump `09be7cd`「1.11→1.12 + m01 矩阵同步」的先例）：

1. `Models.swift:7` `CONTRACT_VERSION` **`"1.12"` → `"1.13"`**；
2. `docs/governance/m01-schema-versioning-contract.md` 矩阵**三行**同步（codex spec-R2 medium：我上一稿漏了第 3 行）：
   - 顶层行 → `"1.13"`；
   - **app.sqlite GRDB migration 行 → `0010_v1.13_drawing_default_style`**；
   - **Swift 模型版本（`M0.3`）行 → `1.4`** —— 该行的触发条件逐字是「**Codable 字段 / 枚举 case 变更；联动顶层**」，
     而本片给 `PendingTraining` / `PendingReplay` 各加了一个 Codable 字段，**正命中**。

   > **为什么不采纳 codex 给的另一个选项（「把 Codable 改动整个移出本 PR」）**：
   > 那会造出一个**有损的 Codable**——新增的存储属性不进 `encode(to:)` / `init(from:)`，
   > 编码一次就把值丢了。今天它零消费者，可它是 `public` 的，**将来第一个用它的人会踩**。
   > 加一行矩阵的成本，远低于埋一个有损编解码器。

> ⚠️ **必须如实记录的既有漂移（不是本片造成的，也不是本片可援引的先例）**：
> 该矩阵的 app.sqlite 行**当前仍停在 `0003_v1.4_purge_leased`**，而代码已跑到 `0009_v1.11_drawing_style`
> ⇒ **`0004`–`0009` 六个 app.sqlite DDL 迁移都未同步矩阵、也未逐次联动顶层 bump**。
> 本片**不负责回填这六次**（范围外），但**必须把自己这一次做对**，并在 PR 描述里点明这处既有漂移，
> 免得后来者把「矩阵值 ≠ 代码现状」当成本片引入的问题。
> ⚠️ 另注：`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` 断言的仍是 `"1.5"` 且**不在 CI**
> （CI 只跑 `hardening_6_framework.sh`）—— **本片不改它**（改一个不在 CI 的陈旧脚本没有收益，且它断言的是 Wave-0 快照）。

### 3.5 D98　版本错位的**诚实**分析：旧写者会把新列抹成 NULL（已接受残留）

> **来源：codex spec-R1 high 的后半段。我上一稿写「⇒ 双向兼容」，那是错的 —— 我只论证了「读」，没论证「写」。**

| 方向 | 结论 |
|---|---|
| **新二进制读旧库** | ✅ `0010` 把列建出来、值为 NULL → 回落出厂（D92 ④） |
| **旧二进制读新库** | ✅ 它的 `SELECT * ` 拿到多余列不管；按列名取值的字段一个不少 |
| **旧二进制写新库** | ❌ **会把 `drawing_default_style` 抹成 NULL** —— repo 是 `INSERT OR REPLACE INTO pending_training (…具名列…)`，`REPLACE` 整行重建，不在列表里的列取默认值（NULL） |

**这条不可能靠「加个可空列」规避**，因为 app.sqlite **没有任何降级保护**（`user_version` 闸只存在于**训练组**库的 `DefaultTrainingSetDBFactory:25-31`，app.sqlite 侧没有对应物）。

**处置：接受为残留，理由是爆炸半径可精确界定**——

- 被抹掉的**恰好只有本局默认这一个装饰性偏好**：其余 14 列全在旧写者的列清单里，tick / 持仓 / 交易 / 画线**一个都不受影响**；
- **最坏后果 = 回到本片修复之前的行为**（本局默认回落出厂）。**不丢任何训练数据**；
- 这不是本片引入的性质：`INSERT OR REPLACE` + 具名列清单是本仓持久化的**既有形状**，`0004` 的 `session_key` 同样暴露在同一机制下。本片只是**又一个**列。

**⚠️ 明令禁止的两种"改进"**：
- **不得**为此把 repo 改成 `UPDATE`-style 部分写入 —— 那会改动一条 shipped 的写入语义，风险远大于收益，且不属本片范围；
- **不得**在 spec 里继续宣称「双向兼容」。**只能说「读向兼容；写向在降级时丢一个装饰性偏好」**。

---

## 4. D92　容错解码：一个装饰性偏好的坏字节，**绝不允许**让整局训练存档打不开

### 4.1 危险点

`LineSubType` / `LineStyle` / `DrawingColorToken` / `LabelMode` 全是 `String` 原始值枚举（`DrawingEnums.swift:6-20`）。
**合成 `Codable` 解码遇到未知原始值会 `throw`**。而 `loadPending` 的任何 throw 都会沿
`resumePending` 传播 ⇒ **用户手上那一局进行中的训练直接打不开**。

用一个**颜色偏好**的坏字节换掉用户一整局训练 —— 这是本片最严重的失败模式。

### 4.2 四条硬约束

| # | 约束 | 不这么做会怎样 |
|---|---|---|
| **①** | **逐字段独立解码 + 任何失败都只回落该字段，整个解码过程绝不 `throw`**。⚠️ **「失败」包括三类：键缺失 / 值不是合法枚举 / **值的 JSON 类型就不对**（`decodeIfPresent(Int.self)` 遇到 `"fat"` 会抛）。实现上每个字段必须各自 `try?`，**不得**把五个字段包在同一个 `try` 里 | 见 §4.1；漏掉第三类 = 能过 T4/T5 却仍 brick（codex R2-medium） |
| **②** | **列值本身不是合法 JSON / 不是对象 → 整个字段回落出厂，仍不 throw** | 同上；坏字节的形态不止「枚举值不认识」 |
| **③** | **本列的解码失败绝不影响同一行其它列**（tick / 持仓 / 交易 / 画线一律照常读出） | 否则等价于 ① 的后果 |
| **④** | **列为 NULL（旧档）→ `drawingDefaultStyle = nil`，不报错、不写日志噪音** | 用户升级后手上那局打不开 |

**⚠️ 与既有 `settings` 表的策略刻意不同，且这个不对称是有意的**：
`SettingsDAOImpl` 对 `commission_rate` 等**财务**键是「present but malformed → `.dbCorrupted`」（`SettingsDAOImpl.swift:36-44`），
因为静默回退会污染钱的计算。**画线默认是装饰性偏好，反过来**：宁可回落出厂，也绝不让它 brick 一局训练。
实施时**不得**「为了和 settings 一致」把本列改成抛错。

---

## 5. D93　解码后必须 **sanitize**，判据复用既有单一真相

### 5.1 危险点

若磁盘上躺着 `lineSubType = "segment"`：`DrawingSession.commitPending` 里的 `withStyle` 对水平线的 `.segment`
**恒返回 nil**（`HorizontalLineTool.lineXRange` 的 `.segment` 分支恒 nil，1b-i D58/D59 已实测坐实）
⇒ 用户进画线模式后**点多少下都画不出一条线**，屏幕上没有任何提示（母 spec §3：灰只降饱和、绝不写解释文案）。
越域 `thickness`（如 0 或 99）同理会让 `withStyle` 拒绝。

**这是「能打开但用不了」，比打不开更难排查。**

### 5.2 D99　sanitizer 必须落在**平台中立的 Contracts 层**，且值域**只留一份字面量**

> **来源：codex spec-R1 medium。我上一稿写「`thickness` 复用 `DrawingStyleParams` 的 `Array(1...5)`」——**
> **那是不可实施的**：`DrawingStyleParams` 整个文件包在 `#if canImport(UIKit)` 里且是 `internal`
> （`UI/DrawingStyleParams.swift:9,12`），而解码器住在 `KlineTrainerPersistence`。
> 照原文实施只有两条路：**复制一份值域**（那就没有单一真相了）或**把 UI 内部暴露出去**（更糟）。

**形状**：在 **`KlineTrainerContracts`（无 UIKit）** 给 `DrawingDefaultStyle` 加两样东西 ——

```swift
public extension DrawingDefaultStyle {
    /// 粗细值域的**唯一**字面量来源。面板与解码器都必须引用它，禁止任何地方再写 `1...5`。
    static let thicknessRange: ClosedRange<Int> = 1...5

    /// 把一份**可能来自磁盘 / 来自未来版本**的默认样式收敛成本构建一定能用的值。
    /// 三条规则各自复用既有单一真相，本函数**不新写任何判据**。
    func sanitized(for toolType: DrawingToolType) -> DrawingDefaultStyle
}
```

| 字段 | 规则 | 复用谁（**禁止另写一份**） |
|---|---|---|
| `lineSubType` | 必须是该 `toolType` **可渲染**的值（水平线的 `.segment` 拒 → 回落 `.straight`） | `DrawingStyleAvailability.isRenderableSubType` |
| `thickness` | 夹回 `DrawingDefaultStyle.thicknessRange` | 本节新增的那**一个**常量 |
| `labelMode` | 归一化（挡 `(ray, .left)`） | **`DrawingStyleAvailability.normalizedLabelMode(current:lineSubType:toolType:)`** —— **必须用带 `toolType` 的那个重载** |

**连带的必做改动**：`DrawingStyleParams` 里的 `options(Array(1...5), …)` **必须改成引用 `DrawingDefaultStyle.thicknessRange`**。
不改它，「单一真相」就是一句空话 —— 两处字面量迟早漂移，而漂移的后果正是 §5.1 那个「能打开但画不出线」。

### 5.2b D100　容错解码 + sanitize 必须是**两个 repo 共用的一个函数**，且两张表都要有坏值档

> **来源：codex spec-R3 medium。** 上一稿的 T3–T5b 只说「**列**含坏值」，没说是**哪张表**的列。
> 而 `PendingTrainingRepositoryImpl` 与 `PendingReplayRepositoryImpl` 是**两条各自独立的读路径**
> ⇒ 实施者可以只把 `pending_training` 的坏值路径做对，`pending_replay` 照样在坏值上抛 ⇒ **replay 续局被 brick**，
> 正是 D92 要消灭的那个失败模式换了张表。

**形状**：容错解码 + sanitize 收进**一个** internal 函数（住在 `KlineTrainerPersistence`），
两个 repo 的读路径**各调它一次**，除此之外 `Sources/` 里零处自行解码该列。

```swift
// KlineTrainerPersistence internal
/// 从列值（可能为 NULL / 非法 JSON / 类型不匹配 / 未来枚举值）读出一份**一定可用**的默认样式。
/// **绝不 throw**（D92）；返回 nil 仅表示「列为 NULL / 无有效内容」。
func decodeDrawingDefaultStyle(_ raw: String?) -> DrawingDefaultStyle?
```

**测试要求（覆盖矩阵，缺一格即不算过）**：**T3 / T4 / T5 / T5b 的每一条，都必须在 `pending_training`
与 `pending_replay` 上各跑一遍**。允许用参数化测试（同一份用例喂两个 repo），但**不允许只跑一张表**。

**守卫 G7**：`decodeDrawingDefaultStyle` 在 `Sources/` 里**恰好 2 个调用点**，分别在两个 repo impl 文件内。
少于 2 ⇒ 有一条读路径没接上（正是本 finding 的形态）；多于 2 ⇒ 出现了第三条读路径，必须回来重新审。

**变异 M15**：把 `pending_replay` 读路径改回「直接 `JSONDecoder().decode`」（绕过共享函数）
⇒ **只有 replay 侧的 T4/T5/T5b 红**，training 侧全绿 —— 这条专门证明「两张表各跑一遍」不是冗余。

### 5.3 sanitize 的位置

**在解码边界**（repo 读出来那一刻）就调 `sanitized(for:)`，**不是**等到 resume 种子那一步。
理由：种子今天只有一个调用点是**事实**、不是**保证**，而**解码结果是公共值**；把 sanitize 放在边界上，
「一个坏默认能被读进内存」这件事从构造上就不成立。

**⚠️ 两条规则都必须用 tool-aware 重载，不得用水平线专用版**（codex spec-R5 medium，**已核实为真，且源码注释就是为防这个而写的**）：

| 规则 | ✅ 必须用 | ❌ 不得用 | 用错的后果 |
|---|---|---|---|
| `lineSubType` | `isRenderableSubType(_:toolType:)` | `horizontalLineSubTypeEnabled(_:)` | 非水平工具的合法 `.segment` 被静默拒 |
| `labelMode` | `normalizedLabelMode(current:lineSubType:**toolType:**)` | `normalizedLabelMode(current:lineSubType:)` | 一条 `.trend` 线的 `.show` / `.left` 被按**横线**规则静默改写成 `.hidden` |

> 后一格不是推演 —— `DrawingStyleAvailability.swift` 里那个 tool-aware 重载的头注**逐字写着**这个后果，> 并把它归为「与 1b-ii 锁定 PR 那个 `.segment` over-reject **同族**（把只对某类型成立的规则套到所有类型）」。
> ⚠️ **我上一稿在同一个决策里自相矛盾**：既写了「保留 `toolType` 入参，写死 `.horizontal` 会在 P1c 变成静默错误规则」，> 又在规则表里指定了水平线专用的那个重载。**tool-aware 的函数签名挡不住调用方传错重载。**

⚠️ 本片只有水平线一个工具，`sanitized(for:)` 的 `toolType` 入参在调用点恒为 `.horizontal`。
**仍然必须带这个入参**——`isRenderableSubType` 的判据本身就是按 toolType 分的（1b-ii PR-1 曾因为把横规则套到所有工具而出过缺陷），
写死 `.horizontal` 会在 P1c 引入新工具时变成一条静默的错误规则。

---

## 6. D94–D96　写入触发、clean-skip、读回种子

### 6.1 D94　必须**新增** autosave 触发；**不得**复用 `drawingsRevision`

**现状**：唯一的画线相关 autosave 触发是 `TrainingView.swift:368`
`.onChange(of: engine.drawingsRevision) { lifecycle.autosave(immediate: true) }`。
**「只改了默认、没改任何线」不 bump `drawingsRevision`** ⇒ 改完默认立刻杀进程 = 白改。

**做法**：在 `TrainingView` 新增一条 `.onChange(of: engine.drawingSession.defaultStyle)` → `lifecycle.autosave(immediate: true)`
（`DrawingDefaultStyle` 已是 `Equatable`，`DrawingSession` 是 `@Observable` ⇒ 值真变了才触发）。

**⚠️ 这条的证据只能是源码守卫，不能是 host 假件计数**（codex spec-R2 high，**已核实为真**）：

上一稿把 T10（host 假件数 `savePending` 次数）当作 D94 / M7 的唯一证据。**那是零判别力的**——
host 测试够不着 `TrainingView`（`#if canImport(UIKit)`），它只能自己去调 `lifecycle.autosave()`，
那证明的是「autosave 被调用时会存」，**不是**「值变了视图会去调」。
⇒ 实施者**把 `.onChange` 整条删掉，T10 照样绿**，而用户「只改默认就退出」照丢不误。

**改为**：D94 的守门是**守卫 G6**（§8）——断言 `TrainingView` 里存在一条
`.onChange(of: engine.drawingSession.defaultStyle)` 且其闭包体内调用 `lifecycle.autosave(immediate: true)`。
**M7 的判绿对象随之改为 G6，不再是 T10。**
T10 仍然保留，但它的作用**降级为**「`saveProgress` 确实会把默认值写进去」（值传递），
**spec 里不得再把它写成 D94 的证据**。

**⚠️ 明令禁止的两种偷懒**：
- **不得**让 `setDefaultStyle` 去 bump `drawingsRevision`。D56 明写该计数**只覆盖 `drawings`**；
  污染它会让 1b-ii 撤销 PR 的入栈条件（「revision 递增 ⟺ 内容真的变了」）失真。
- **不得**依赖「反正用户改完总会画线，画线时会存」。用户完全可能改完默认就退出。

### 6.2 D95　replay 的 clean-skip **必须**纳入本局默认

**现状**（`TrainingSessionCoordinator.swift:611-621`）：`!replayHasPersisted` 时，若当前态 == `replayBaseline`
则**直接 `return`、不写盘**。基线元组是 `(tick, ops, drawingsSig, upper, lower)`。

⇒ fresh replay 里**只改默认**：五个分量一个没变 → **clean-skip 跳过** → 续局必丢。

**做法**：`replayBaseline` 加第六个分量 `defaultStyle`，并加进 clean-skip 的合取；
三处捕获基线的地方（`:207` 测试入口 / `:588` fresh / `:942` 续局）**必须同步**。

> ⚠️ **同形状的旧 bug 就记在源码注释里**：`TrainingSessionCoordinator.swift:55` 逐字写着
> 「须纳入 clean-skip 比较，否则切周期后 Back/flush 被当 clean 跳过 → 丢 PendingReplay 序列化的 upper/lowerPeriod」。
> 本片是同一个坑的第二次。**凡是新增进 `PendingReplay` 的字段，都必须问一遍「它进 clean-skip 判据了吗」。**

### 6.3 D96　读回种子：两处，且**只在有值时**种

| 位置 | 做法 |
|---|---|
| `TrainingSessionCoordinator.resumePending()` `:294` | 建好 engine 后：`if let s = pending.drawingDefaultStyle { engine.drawingSession.setDefaultStyle(s) }` |
| `TrainingSessionCoordinator.resumePendingReplay()` `:851` | 同上，取 `pending.drawingDefaultStyle` |

- **`nil` 时不动**（保持 `DrawingDefaultStyle()` 出厂值）—— 旧档与「从未改过」走同一条路，无需区分。
- **fresh 会话（`startNewNormalSession` / `replay` 从头 / `review`）一律不种** ⇒ 新局回落，符合 §1 与用户裁决。
- `setDefaultStyle` 是 `DrawingSession` 的 internal mutator，`TrainingSessionCoordinator` 同模块可调，**不得**为此把它改成 `public`（容器 mutator 纪律，`DrawingSession.swift:21-28`）。

### 6.4 写入点：两处，各自读活的 session

`TrainingSessionCoordinator.saveProgress` 内两处构造点：`:623`（replay）与 `:650`（normal），
各自补 `drawingDefaultStyle: engine.drawingSession.defaultStyle`。
**取活值、不取快照**（与该函数内其它字段同一写法）。

---

## 7. 测试与判别力

> ⚠️ **本片最大的假绿陷阱，必须写在最前面**：
> `InMemoryPendingTrainingRepository` / `InMemoryPendingReplayRepository`（`PreviewFakes/InMemoryFakes.swift:132,180`）
> **原样存取整个 `PendingTraining` / `PendingReplay` 值**。⇒ 一旦模型加了字段，**内存假件自动往返成功**，
> 哪怕 SQL 列根本没建、repo 根本没读写。
> **故：`drawingDefaultStyle` 的落盘证据只认 DB 边界测试（真 GRDB），内存假件的往返一律不算数。**
> （这正是自动选中 spec 的 codex R6 critical 所指的形状。）

### 7.1 必测清单（每条注明**在哪一层**）

| # | 用例 | 层 |
|---|---|---|
| **T1** | 存 → 读往返：五个字段**逐字段**相等 | **DB 边界**（真 GRDB，仿 `DefaultPendingTrainingRepositoryTests`） |
| **T2** | replay 槽同样往返 | **DB 边界**（仿 `PendingReplayPersistenceTests`） |
| **T3** | 列为 NULL（旧档）→ `drawingDefaultStyle == nil`，**其余字段照常读出**，不抛 | **DB 边界 ×2 表**（D100） |
| **T4** | **未来枚举值，四个枚举字段各一条**：`{"lineSubType":"arc"}` / `{"lineStyle":"dash5"}` / `{"colorToken":"未来色"}` / `{"labelMode":"center"}` → **整行照常读出**，仅该字段回落出厂、其余三个枚举字段**保留磁盘上的合法值** | **DB 边界 ×2 表**（D92 ① / D100）。⚠️ **四个字段一个都不能少**（codex R6-medium：只测 `colorToken`，实施者可以只给它加 `try?`，`{"lineStyle":"dash5"}` 照样抛） |
| **T5** | 列含**非法 JSON**（如 `"{{{"`）→ 整行照常读出，整个默认回落出厂 | **DB 边界 ×2 表**（D92 ② / D100） |
| **T5b** | 列含**类型不匹配**：`{"thickness":"fat"}` / `{"lineSubType":7}` / `{"colorToken":null}` / `{"lineStyle":[]}` / `{"labelMode":{}}` —— **五个字段各一条** → 整行照常读出，**只有该字段**回落出厂、其余四个字段**保留磁盘上的合法值** | **DB 边界 ×2 表**（codex spec-R2 medium：`decodeIfPresent(Int.self)` 能过 T4/T5 却在这里抛；×2 表见 D100） |
| **T6** | 列含 `{"lineSubType":"segment"}` → 读出后**能正常提交一条线** | **host**（D93；断言 `commitPending` 返回非 nil） |
| **T7** | 列含 `{"thickness":99}` / `{"thickness":0}` → 夹回 `1…5` | **host**（D93） |
| **T8** | 迁移：pre-0010 库跑完 migrator → 两表**都有**该列且 `user_version == 8` | **DB 边界**（仿 `Migration0009Tests` / `AppDB0005MigrationTests` 的裸库套路） |
| **T9** | fresh install 跑完整 migrator → `user_version == 8` | **DB 边界**（`AppDB0005MigrationTests` 里那条现有断言要从 7 改 8） |
| **T10** | 调用 `saveProgress` 时，**默认值确实被带进了写入载荷** | host（假件截获 `PendingTraining`，逐字段断言）。⚠️ **它不是 D94 的证据**（够不着视图），D94 的证据是守卫 **G6** |
| **T11** | **fresh replay 只改默认** → `saveReplay` **确实写了**（clean-skip 未跳过） | host（D95，**这条是 clean-skip 的唯一守门**） |
| **T12** | replay 续局：存 → resume → `session.defaultStyle` 逐字段 == 存进去的 | host + DB 边界 |
| **T13** | normal 续局：同上 | host + DB 边界 |
| **T14** | **fresh 会话不种**：开新局 → `session.defaultStyle` == 出厂值 | host（§1 新局回落） |
| **T15** | **两份**常量都是 `"1.13"`：Swift 侧 `#expect(CONTRACT_VERSION == "1.13")`（**两处测试都要改**）+ backend `qmt_pilot_db.CONTRACT_VERSION == "1.13"` | host（Swift）+ **backend pytest**（D97）。⚠️ `test_qmt_pilot_db.py:770` 的跨语言断言**不改**，它同步后自动绿 |
| **T15b** | `sanitized(for: .trend)`（**非水平工具**）**不改写** `labelMode`：喂 `(lineSubType: .ray, labelMode: .left)` → 原样返回 `.left`（横线规则不得外溢）。同法验 `lineSubType` 不被横规则拒 | host（**不变量锁**：本片调用点恒 `.horizontal`，故只能单元级构造） |
| **T16** | `DrawingDefaultStyle.thicknessRange` 与面板实际渲染的档数**同源**：面板选项数 == `thicknessRange.count` | **Catalyst**（面板是 UIKit-gated；D99 的单一真相守门） |

### 7.2 变异清单（**强制清单 = 本表每一条**，刻意不枚举编号）

| # | 变异 | 必须且只应变红 |
|---|---|---|
| **M2b** | 把 `stylePanelWillBeVisible` 的定义改成 `isDrawingActive && typeRowExpanded`（去掉 `showsTradeButtons`，= 让复盘也能挂面板） | **只有 G4b** 红（G4 仍绿 —— 这条证明单靠 G4 挡不住） |
| M1 | migration 里删掉 `pending_replay` 那一句 `ALTER` | T8 的 replay 分支红；training 分支**不得**红 |
| M2 | repo 的 `INSERT` 语句里去掉该列 | T1/T2 红；T3 **不得**红 |
| M3 | repo 的读取改成恒 `nil` | T1/T2 红 |
| M4 | 把逐字段容错解码换成合成 `Codable`（遇未知即抛） | **只有 T4/T5/T5b** 红 |
| **M4c** | **只给 `colorToken` 留 `try?`**，其余三个枚举字段改回 `try`（模拟「只照着旧 T4 实施」） | **只有 T4 的 `lineSubType`/`lineStyle`/`labelMode` 三条**红，`colorToken` 那条**仍绿** —— 专证「四个字段各一条」不是冗余（codex R6-medium） |
| **M4b** | 保留逐字段解码，但把每个字段的 `try?` 改成 `try`（只挡「枚举值不认识」，不挡类型不匹配） | **只有 T5b** 红 —— 这条专门证明 T4/T5 挡不住类型不匹配 |
| M5 | 删掉 sanitize 的 `lineSubType` 分量 | **只有 T6** 红 |
| M6 | 删掉 sanitize 的 `thickness` 夹取 | **只有 T7** 红 |
| M7 | 删掉 D94 新增的 `onChange` 触发 | **只有守卫 G6** 红（**不是 T10** —— host 够不着视图，T10 对它零判别力，codex R2-high） |
| M8 | `replayBaseline` 去掉 `defaultStyle` 分量（回到五元组） | **只有 T11** 红 |
| M9 | `resumePending` 的种子那一句删掉 | **只有 T13** 红 |
| M10 | `resumePendingReplay` 的种子那一句删掉 | **只有 T12** 红 |
| M11 | 让 fresh 会话也种子（把种子挪到公共构造路径） | **只有 T14** 红 |
| M12 | `user_version` 仍写 7 | T8/T9 红 |
| M13 | **只**改 Swift 那份、backend 那份留在 `"1.12"` | **backend 的 `test_qmt_pilot_db.py:770`** 红（跨语言一致性守卫）—— 这条专证「两份源必须同改」 |
| **M13b** | 两份都留在 `"1.12"` | **只有 T15** 红 |
| M14 | 把 `thicknessRange` 改成 `1...4`（模拟两处字面量漂移） | **只有 T16** 红 —— 证明面板确实是从该常量派生、不是自己写了个 `1...5` |
| **M15b** | 把 `sanitized` 里的 `labelMode` 归一化换成**两参**重载 `normalizedLabelMode(current:lineSubType:)` | **只有 T15b** 红 —— 这条专证「tool-aware 签名挡不住传错重载」（codex R5-medium） |
| **M15** | 把 `pending_replay` 的读路径改回「直接 `JSONDecoder().decode`」（绕过共享函数） | **只有 replay 侧**的 T4/T5/T5b 红，**training 侧全绿** + 守卫 **G7** 红 —— 专证「两张表各跑一遍」不是冗余（codex R3-medium） |

**实施要求**：本表**每一条**逐条关门看红，PR 描述里逐条记录「红的是**哪个测试名**」+ 恢复后重新变绿。
变异复原一律 `cp` 到 /tmp 再 `cp` 回，**禁止 `git checkout <file>`**（[[feedback_git_checkout_destroys_uncommitted_work]]）。

### 7.3 必配的**正向档**

本片判据多为「坏输入被容错」形状。按 [[feedback_all_reject_suite_masks_always_throwing_guard]]，
**必须配「健康输入原样穿过」的正向档并断言取到的是哪个值** —— T1 / T2 / T12 / T13 就是它们，
且**必须逐字段断言**（只断言「非 nil」是零判别力的）。

---

## 8. 源码守卫

| # | 守卫 | 形状 |
|---|---|---|
| **G1** | `setDefaultStyle` 在 `Sources/` 里的调用点**恰好 3 个**：`DrawingEditRouter`（面板写入，既有）+ `resumePending` + `resumePendingReplay` | 结构计数 |
| ~~**G2**~~ | ~~列名 `drawing_default_style` 的出现处计数~~ **已删除** —— 见下方「为什么删掉 G2」 | —— |
| **G3** | `replayBaseline` 的元组构造点**恰好 3 处**且**都包含 `defaultStyle`** | 结构计数 + 内容断言（防「加了字段但某处基线捕获忘了带」） |
| **G4** | `TrainingView.showsTradeButtons` 的定义式仍为 `engine.flow.canBuySell()` | **内容断言** |
| **G4b** | `TrainingView.stylePanelWillBeVisible` 的**整条定义式**仍为 `showsTradeButtons && isDrawingActive && typeRowExpanded` | **内容断言**（codex R2-medium：只钉 G4 会漏掉「改另外两项」这条路） |
| **G4c** | 样式面板（`DrawingStyleParams` / `DrawingStylePanel`）的**挂载点**在 `Sources/` 里**恰好 1 处** | 结构计数（防「另开一条挂载路径」绕过 G4/G4b） |
| **G5** | `1...5` / `1 ... 5` 这类粗细值域字面量在 `Sources/` 里**恰好 1 处**（= `DrawingDefaultStyle.thicknessRange` 的定义），面板与解码器都只引用它 | 结构计数（**剥注释剥字面量后匹配**；D99 的机械守门） |
| **G7** | `decodeDrawingDefaultStyle` 在 `Sources/` 里**恰好 2 个调用点**，分别在两个 repo impl 文件内 | 结构计数（D100：少于 2 = 有一条读路径没接上；多于 2 = 出现第三条读路径，必须回来重审） |
| **G6** | `TrainingView` 里存在一条 `.onChange(of: engine.drawingSession.defaultStyle)`，且其闭包体内调用 `lifecycle.autosave(immediate: true)` | **结构 + 内容断言**。这是 **D94 的唯一守门**（host 够不着视图，见 §6.1）；**M7 判绿看它，不看 T10** |

**为什么删掉 G2**（codex spec-R6 medium，**已核实为真**）：

G2 要数的 `drawing_default_style` 是**写在 Swift 字符串字面量里的 SQL 列名**，
而下面那条纪律要求「结构计数**剥字符串字面量**后再匹配」——**剥完，G2 要找的证据就没了**。
照字面实现 ⇒ 永远红；为它全局放宽剥离规则 ⇒ 所有守卫都变得**可被注释 / 无关字符串伪造**。
**这是一条自我否定的守卫。**

**它同时还是冗余的**：G2 想防的「只给一张表接上了列」，**T1 / T2（两张表各跑一遍的 DB 边界往返）
是直接的行为证据**——列没进 `pending_replay` 的 `INSERT`，T2 当场失败；migration 漏了哪张表，T8 当场失败。
**行为证据严格强于文本计数**，故按 CLAUDE.md §2 删掉 G2，而不是给它打一个 SQL-aware 的补丁
（那要新写一个 Swift 字符串字面量解析器，且它自身又需要一套自测 —— 为一个已被覆盖的风险付双份成本）。

⚠️ **其余守卫不受影响，已逐条核过**：G1 / G3 / G7 数的是 **Swift 标识符**，
G4 / G4b / G6 断言的是 **Swift 表达式**，G5 数的是 **Swift 代码里的 `1...5`** ——
**没有一条依赖字符串字面量里的内容**，剥离纪律对它们全部适用。

**纪律**：结构计数一律**剥注释、剥字符串字面量**后再匹配；每个守卫配**双向自检**（该命中的必须命中、不该命中的必须不命中）；
锚点失效必须**报错**不得静默返回 0（[[feedback_mechanical_checker_parser_disabled]]）。
**G1 / G3 / G4b / G4c / G5 / G6 / G7 在当前树上是红的**（G4b/G4c 依赖的谓词今天就存在，但守卫本身尚未写；G4 今天就是绿的），必须与对应生产改动写在**同一个 task** 里（[[feedback_source_guard_must_be_green_on_current_tree]]）；
**G4 今天就是绿的**，属回归守卫，可先落库。

---

## 9. 验收清单（真机，非 coder 可执行）

前置：Debug 构建 + `KLINE_SEED_FIXTURE=1` 装机（[[project_device_testing_requires_seed_fixture]]；NAS 后端未部署，
不带 seed 必报「训练组文件不存在」，**是环境缺口不是回归**）。

| # | 动作 | 预期 | 通过/失败 |
|---|---|---|---|
| 1 | 开一局新训练 → 进画线模式 → 画一条线 | 线是**出厂橙** | |
| 2 | 在样式面板把颜色改成**紫**、粗细改成 **3** → 再画一条线 | 新线是**紫色、粗细 3** | |
| 3 | 承接 #2，点「返回」回主页 → 点「继续训练」→ 进画线模式 → 画一条线 | 新线**仍是紫色、粗细 3**（继承成功） | |
| 4 | 承接 #3，再把颜色改成**绿** → **直接杀掉 App**（上划关掉，不点返回）→ 重开 → 「继续训练」→ 画一条线 | 新线是**绿色**（只改默认也立刻存了盘） | |
| 5 | 承接 #4，把这一局**打完**（或点「结束本局」）→ 回主页 → **开一局全新训练** → 画一条线 | 新线是**出厂橙**，**不是**绿色（新局回落） | |
| 6 | 从历史记录点某条 →「再次训练」→ 画一条线 | 线是**出厂橙**（replay 算新的一局） | |
| 7 | 承接 #6，在 replay 里把颜色改成**蓝** → 点「返回」→ 再从历史记录点同一条 →「再次训练」（续局） | 画出的线是**蓝色**（replay 的断点续局也继承） | |
| 8 | 从历史记录进**复盘**，用浮动铅笔钮画线 | 能正常画线；**没有样式面板**（复盘本来就改不了默认，符合设计） | |
| 9 | **用升级前建的进行中训练**（若手上有）→ 「继续训练」 | **能正常打开**，画线默认是出厂橙 | |

**#3 / #4 / #5 是三条硬边界**（断点继承 / 只改默认也存盘 / 新局回落），任何一条不过都是阻塞级。

⚠️ **#9 若装不出升级前的存档，必须如实标「无法验证」并在 PR 描述里写明，不得直接打勾**
（[[feedback_uikit_gated_evidence_traps]]：不好测不是打勾的理由）。它的自动化替身是 T3/T8。

---

## 10. 交接与残留

### 10.1 交给自动选中 PR

- 本片合入后，自动选中 spec 的 **D89 前置条件即告满足**，自动选中 PR 方可实施。
- **自动选中 spec** 的 §6.8.3 那条「一致性回归」（画线态改样式 → autosave → 续训 → **线与默认双双恢复且互相一致**）
  在本片之前必然红、本片之后应当能绿 —— 它是次序正确性的机械证据。

### 10.2 交给 P6（母 spec §13）

P6 只需接**一件事**：把「**新开一局时的初始值**」从出厂值改成齿轮里设的全局默认。
「本局覆盖量跨断点续训继承」本片已解决，**P6 不要重做**，也不得把本片的列改成写全局默认。

### 10.3 交给 P5

**D90 §2.2 的失效条件**：P5 若让复盘用上新底栏 / 常驻样式面板，本片对 `review_archive` 的排除立刻失效，
必须同期接上，否则复盘出现与本片修复前一样的丢失。G4 是它的机械提醒。

### 10.4 已接受残留

- **同一台设备上「本局默认」不跨局携带** —— 这是用户 2026-08-13 明确选择的语义（新局回落全局默认），不是缺口。
- **复盘用不到本局默认**（恒出厂值）——复盘没有样式面板，是 main 上的既有事实，本片不改变。

---

## 11. 契约影响

| 项 | 影响 |
|---|---|
| SQLite schema | **有**：两张表各 +1 可空列，新增迁移 `0010`，`user_version` 7 → 8 |
| `v1_4_baselineDDL` / `app_schema_v1.sql` | **零**（冻结基线不动；schema-drift 闸门因此不受影响） |
| `CONTRACT_VERSION` | **必须 bump `1.12` → `1.13`**（命中 m01「影响 DDL」）+ **m01 矩阵三行同步**（D97 §3.4）：① 顶层 → `"1.13"`　② app.sqlite GRDB migration 行 → `0010_v1.13_drawing_default_style`　③ **Swift 模型版本（M0.3）行 → `1.4`**（Codable 字段变更，联动顶层）。⚠️ **常量有两份源**（Swift + `backend/qmt_pilot_db.py`）且有跨语言一致性测试，**必须同改**；连带 QMT pilot 库需 `--reset` 重建 —— **全部细节见 D97 §3.4，本行不复述清单** |
| 版本错位 | **读向兼容；写向在降级时丢一个装饰性偏好**（旧写者的 `INSERT OR REPLACE` 会把新列抹成 NULL）。已接受残留，爆炸半径与理由见 D98 §3.5。**不得再宣称「双向兼容」** |
| 磁盘上的画线数据（`drawings` / `review_archive`） | **零** |
| `DrawingObject` | **零**（本局默认不是画线对象的字段） |


---

## 12. codex 对抗性评审逐轮

| 轮 | 评审对象 | verdict | finding | 处置 |
|---|---|---|---|---|
| **R1** | `feat/drawing-session-default-persistence` @ `daca81b`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：新增 app.sqlite DDL 却写「不 bump `CONTRACT_VERSION`」，违反治理规则；且「双向兼容」只论证了读，**旧写者的 `INSERT OR REPLACE` 会把新列抹成 NULL**<br>**1 medium**：D93 要求解码器复用 `DrawingStyleParams` 的 `Array(1...5)`，但那是 `#if canImport(UIKit)` 里的 internal 视图，**持久化层够不着**，照写只能复制一份值域或暴露 UI 内部 | **两条全采纳，均已实测证实**。high → 新增 **D97**（必须 bump `1.12→1.13` + m01 矩阵同步，照 `09be7cd` 先例；⚠️ **当时写的是两行，R2 已补为三行**，现行以 D97 为准）与 **D98**（版本错位的诚实分析：读向兼容 / 写向降级丢一个装饰性偏好，接受为残留并界定爆炸半径 = 仅该列，其余 14 列全在旧写者清单里，最坏 = 回到本片修复前）。medium → 新增 **D99**（`thicknessRange` + `sanitized(for:)` 落 Contracts 平台中立层，`DrawingStyleParams` 改为引用同一常量），配 T15/T16、M13/M14、守卫 G5 |

**R1 额外自查发现（codex 未提，我核矩阵时撞见）**：`docs/governance/m01-schema-versioning-contract.md`
的 app.sqlite 行**仍停在 `0003_v1.4_purge_leased`**，而代码已到 `0009` ⇒ **`0004`–`0009` 六次 DDL 迁移都未同步矩阵**。
已写进 D97 作为「既有漂移」标注：本片不回填，但必须把自己这次做对，并在 PR 描述里点明，免得被误认为本片引入。

| **R2** | 同分支 @ `a6ed039`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：T10 是 D94/M7 的唯一证据，但它是 host 假件计数，而要证的行为是 UIKit-gated `TrainingView` 里的 `.onChange` —— **删掉 `.onChange`，T10 照样绿**<br>**medium①**：m01 还有一行「Swift 模型版本｜Codable 字段变更→联动顶层」，我只同步了两行<br>**medium②**：G4 只钉 `showsTradeButtons`，可判据是三项合取，改另外两项或另开挂载路径都能绕过<br>**medium③**：T4/T5 只覆盖「枚举值不认识」和「整段非 JSON」，漏了**类型不匹配**（`{"thickness":"fat"}`），`decodeIfPresent(Int.self)` 能过 T4/T5 却在这里抛 | **四条全采纳**。high → D94 的守门改为**守卫 G6**（断言 `.onChange` 存在且调 `autosave`），**M7 判绿看 G6 不看 T10**；T10 降级为「值确实进了写入载荷」。①→ 矩阵改同步**三行**（Swift 模型版本 1.3→1.4）；**不采纳** codex 的另一选项「把 Codable 改动移出 PR」——那会造出有损 Codable，今天零消费者但它是 public，将来第一个用的人会踩。②→ 拆成 G4/G4b/G4c 三条（含整条 `stylePanelWillBeVisible` 定义式 + 挂载点计数），并写死无条件规则「任何让复盘可达改默认的改动必须同期接上 `review_archive`」，加变异 M2b。③→ D92 ① 明写「失败包括三类」+ 每字段各自 `try?`、禁止五字段包一个 `try`；加 T5b（五字段各一条）与 M4b |

| **R3** | 同分支 @ `a850e5e`（整支 branch-diff，零 focus 窄化） | `needs-attention`（**首次无 high**） | **medium①**：T3–T5b 只说「**列**含坏值」，没说哪张表；两个 repo 是**各自独立的读路径** ⇒ 可以只把 `pending_training` 做对，`pending_replay` 照样在坏值上抛 ⇒ replay 续局被 brick<br>**medium②**：§11 契约影响行仍写「m01 矩阵**两行**」，与 D97 已改成的**三行**自相矛盾 | **两条全采纳**。①→ 新增 **D100**：容错解码 + sanitize 收进**一个共享函数** `decodeDrawingDefaultStyle`，两个 repo **各调一次**；**T3/T4/T5/T5b 每条都必须两张表各跑一遍**；配守卫 **G7**（恰好 2 个调用点）与变异 **M15**（把 replay 读路径改回直接 decode → 只有 replay 侧红）。②→ §11 那行改写为三行并逐条列出 |

| **R4** | 同分支 @ `60e8753`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：D97 只让改 `Models.swift` + m01 矩阵，漏了 **`backend/qmt_pilot_db.py` 里的第二份 `CONTRACT_VERSION`**，而 `backend/tests/test_qmt_pilot_db.py:770` **读 Swift 文件**做跨语言一致性断言 ⇒ 只改一边立刻红<br>**1 medium**：迁移名写成 `0010_v1.12_…`，可本片要把契约 bump 到 **1.13**；既有命名（`0008_v1.10` / `0009_v1.11`）都是「该迁移所属的契约版本」⇒ 这次 DDL 会看起来属于上一个契约版本 | **两条全采纳**。high → D97 扩成**四处必改 + 一处必不改**的清单（Swift 常量 / backend 常量 / Swift 两处 `#expect` 断言 / **`test_qmt_pilot_db.py:770` 不得改**——它动态读 Swift 比对，同步后自动绿，改它=把守卫弄瞎）；变异拆成 M13（只改一边 → backend 跨语言守卫红）与 M13b（两边都不改 → T15 红）。medium → 迁移改名 `0010_v1.13_drawing_default_style`（含 m01 记录的 id），并写明命名规则 |

**⚠️ R4 顺藤摸出的第四层（codex 只提到前两层，我拉线才看见）**：`CONTRACT_VERSION` 还是 **QMT pilot 的运行时闸门**——`qmt_pilot_db.py:1694` 把它写进 pilot DB 元数据、`:2224` 的**闸 1** 拿它校验 ⇒ **本片 bump 之后，已建的 pilot 库会报 `schema_fingerprint_mismatch`、必须 `--reset` 重建**。这是闸门按设计工作、不是缺陷，但**必须写进 PR 描述**，否则合入后第一个跑 QMT 验证的人会当成回归去查。已写进 D97。

| **R5** | 同分支 @ `6599805`（整支 branch-diff，零 focus 窄化） | `needs-attention`（**仅 1 medium**） | D99 的规则表让实施者复用 `normalizedLabelMode(current:lineSubType:)` —— 那是**水平线专用**重载；仓里另有 tool-aware 重载正是为防这个而存在。P1c 新工具照此实施，加载持久化默认会把合法的非水平 `labelMode` 静默改写成 `.hidden` | **全采纳，已核实为真**。`DrawingStyleAvailability.swift` 里 tool-aware 重载的头注**逐字**写着这个后果并把它归为「与 1b-ii 锁定 PR 的 `.segment` over-reject 同族」。⚠️ **这是我在同一个决策里自相矛盾**：D99 我亲手写了「保留 `toolType` 入参，写死 `.horizontal` 会在 P1c 变成静默错误规则」，转头在规则表里指定了水平线专用重载。改：规则表加「✅必须用 / ❌不得用 / 用错的后果」三列（两条规则各一行）；新增 **T15b**（`sanitized(for: .trend)` 不改写 labelMode，不变量锁）与 **M15b**（换回两参重载 → 只有 T15b 红）|

| **R6** | 同分支 @ `d04d409`（整支 branch-diff，零 focus 窄化） | `needs-attention`（**0 high**） | **medium①**：T4 只测了 `colorToken` 的未来枚举值；`lineSubType`/`lineStyle`/`labelMode` 只有类型不匹配覆盖 ⇒ 实施者可以只给 `colorToken` 加 `try?`，`{"lineStyle":"dash5"}` 照样抛、照样 brick<br>**medium②**：**G2 与守卫纪律自相矛盾** —— 它要数的是**写在 Swift 字符串字面量里的 SQL 列名**，而同节纪律要求「剥字符串字面量后再匹配」；剥完证据就没了。照字面实现永远红，全局放宽则所有守卫可被伪造 | **两条全采纳**。①→ T4 扩成**四个枚举字段各一条 ×2 表**，加变异 **M4c**（只给 `colorToken` 留 `try?` → 只有另外三条红、`colorToken` 那条仍绿）。②→ **删除 G2**（而非打补丁）：它想防的「只接了一张表」已被 T1/T2/T8 的**行为证据**直接覆盖，**行为证据严格强于文本计数**；给它写 SQL-aware 解析器要付双份成本（解析器自身还需自测）。已逐条核过其余守卫：G1/G3/G7 数 Swift 标识符、G4/G4b/G6 断言 Swift 表达式、G5 数代码里的 `1...5` —— **无一依赖字符串字面量内容**，剥离纪律对它们全部适用 |

**R1 的形状**：我把「可空列 + 附加式」当成了「所以不用 bump」，**跳过了去读治理文档那一步**——
规则明文写着「影响 DDL → 必须 bump」，我一次都没查就下了结论。
而「双向兼容」那句是同一个毛病的另一面：**只推演了对我的结论有利的那个方向（读）**。

**R6 medium② 的形状**：**我写的守卫，被我自己在同一节写的守卫纪律否定了**。两条都对 —— 剥字面量是对的、要防漏接一张表也是对的 —— 但**放在一起就不可实现**。
纪律沉淀：**每加一条守卫，当场用同节的匹配纪律走一遍**：剥完注释与字面量之后，**它要找的证据还在不在**？不在，就说明这条守卫要么换形态、要么本来就该由测试承担。
⚠️ 更一般的：**「文本计数」和「行为测试」能覆盖同一个风险时，优先行为测试** —— 文本计数只在「行为测不到」（如 UIKit-gated 的 `.onChange`，见 G6）时才有不可替代性。

**R5 的形状**：**函数签名 tool-aware，挡不住调用方传错重载**。我把「让 `sanitized` 带 `toolType` 参数」当成了「工具无关性已经解决」，却没检查**表里每一条规则各自调的是哪个重载** —— 参数传下去了，规则本身仍是水平线专用的。
纪律沉淀：**「我加了个参数来表达 X」不等于「X 被遵守了」**；带变体/重载的 API，必须逐条判据写明**用哪一个重载、用错会怎样**，并各配一条只有它够得到的档。

**R4 的形状**：**我把「一个常量」当成了「一处定义」**。它实际有两份源、两处断言、一处跨语言守卫，外加一个把它当运行时闸门用的下游系统 —— 五个地方，我只写了一个。
纪律沉淀：**改任何「版本 / 契约标识」之前，先全仓 grep 它的名字**，把**定义处 / 断言处 / 跨语言校验处 / 把它当运行时判据的下游**四类逐一列出来；
其中**跨语言一致性守卫要单独判断「改它还是不改它」** —— 动态比对型的守卫**改了就是弄瞎**。

**R3 medium① 的形状**：我把两条**独立的读路径**当成了一条来写测试——「列含坏值」这个说法**掩盖了它有两个宿主**。
纪律沉淀：**凡是同一份数据存在 N 个独立读/写路径，测试矩阵必须显式写成 N 份**；用「那个列 / 那个字段」这类**不指明宿主**的措辞，等于默许只做一份。

**R3 medium② 的形状**：又一次「改了 A 忘了同步 B」——D97 从两行改三行，§11 的摘要行没跟着改。
⚠️ 这已是本轮工作里同一形状的第 N 次（自动选中 spec 的 R9/R10/R11 全是它）。**摘要性表格是重灾区**：它复述别处的结论，却没有任何机制保证同步。
纪律沉淀：**摘要表里不复述可变数字，改为指向权威处**（写「见 D97」而不是「两行」）。

**R2 high 的形状 = 「零判别力变异」的第二次**（自动选中 spec R5-medium 是第一次）：我给判据配了变异，却没问「**这条变异真的会让那条测试变红吗**」。T10 在 host、`.onChange` 在 UIKit-gated 视图里，两者**根本不在同一个可执行面上**。
纪律沉淀：**每写一条「M 变异 → T 测试红」的配对，必须先确认这两者在同一个可执行面上**（同一 target、同一平台门）。跨面的配对是空头保证书。

**R2 medium② 的形状**：**守卫只钉了合取式的一项**。判据是 `A && B && C` 时，钉 A 等于没钉。
纪律沉淀：**守卫必须钉住整条可达链**；且守卫是提醒、不是义务本身 —— 义务要单独写成无条件规则。

纪律沉淀：**凡涉及版本 / 契约 / 迁移，先去读治理文档的原文，再下结论**；
**兼容性必须四个方向都写**（新读旧 / 旧读新 / 新写旧 / **旧写新**），少一个方向就是没论证。
