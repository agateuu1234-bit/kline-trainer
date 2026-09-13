# 切片一 P3c：顶层契约版本 bump + 治理矩阵订正 + Mac v1 副本作废　实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把顶层 `CONTRACT_VERSION` 从 `"1.13"` 升到 `"1.14"`（实测 **10 处** 字面量、跨 6 个文件），把 m01 治理矩阵的训练组行由 `1` 订正为 `2` 并扩写其触发条件，把 Mac 本地三个 v1 压缩包明确作废为审计归档 —— 并为后两件各配机械守卫（实测落地 **4 条**：Task 2 的 1 条 + Task 3 的 3 条）。

**Architecture:** 三个任务各自独立、按文件分组；两条新守卫都写成 Python 测试放进 `backend/tests/`（本仓既有做法，P3a 的 `test_frozen_contract_texts.py` 是先例）。守卫**在文本改完之后**加，且每条都必须用「故意改坏一处→看它红不红」的变异实测证明有判别力。

**Tech Stack:** Python 3（pytest）· Swift 6（`swift test`，XCTest + swift-testing 双框架）· markdown 治理文档

**Spec:** `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §3.3（第 4 项、顶层 bump 表 5–9 项）+ §3.4「Mac 本地 `~/qmt_trial_out/` 三个 v1 包 —— 明确作废为归档」

**上游母 spec：** `docs/superpowers/specs/2026-08-30-trainingset-app-contract-design.md` §5.7（同一次 bump 的另一份清单，**列的是 6 个同步点**，与本片 spec 的 5 项有出入；本计划按**实测字面量**取并集，见 Task 1 表）

---

## Global Constraints

以下每一条都是**硬约束**，每个任务的要求都隐含包含本节。

1. ⛔ **不碰任何 App 运行逻辑**。本片对 `ios/` 的改动**只有常量与测试断言/显示名**。`DownloadAcceptanceRunner.swift`、`TrainingSessionCoordinator.swift`、`DefaultTrainingSetReader.swift` **一行都不改** —— 它们是切片二的范围，且 P3a 的守卫正在断言「App 读取端仍钉在第 1 代」。
2. ⛔ **不碰 `.github/workflows/**`**。那是 **P3b** 的范围（本仓对 workflows 有单独的 push 仪式）。
3. ⛔ **不碰 `backend/generate_training_sets.py` / `backend/sql/**`** —— P1 已定版为第 2 代，本片只**读**它。
4. ⛔ **不改 `kline_trainer_modules_v1.4.md:144`** 那个 stale 的 `CONTRACT_VERSION | "1.5"`。**实测理由**：`scripts/acceptance/plan_e2_position_manager.sh:37` 正断言它等于 `1.5` 并**当前通过**；改了它会让 `plan_e2` 从 2 FAIL 变 3 FAIL。它自 v1.4 起就 stale、不由本片引入，归 `docs/superpowers/specs/2026-08-31-acceptance-stale-literals-design.md` F21。
5. ⛔ **不改 `backend/tests/test_qmt_pilot_db.py`**。它的 `assert f'CONTRACT_VERSION = "{CONTRACT_VERSION}"' in swift`（`:835`）是**动态**读 Swift 源文件做跨语言比对 —— 两边同改后自动变绿；改它 = 把守卫弄瞎。
6. ⛔ **迁移 id `0010_v1.13_drawing_default_style` 是历史标识、不是版本值**，四处出现（`AppDBMigrations.swift:250`、`M01MatrixSyncGuardTests.swift:53/:71/:76`、m01 矩阵 app.sqlite 行）**全部保留原样**。本次 bump **不涉及任何 app.sqlite migration**。
7. 变异验证纪律：一次只改一处；用 `cp` 备份/还原，⛔ **不得用 `git checkout <文件>`**（会静默抹掉未提交改动）；Python 变异前后各清一次 `__pycache__`；每次还原后跑 `git status --short` 确认树干净。
8. 交付必须含一份**非程序员可执行**的中文验收清单（动作 / 期望 / 通过判定），以及一份逐条的变异记录。
9. ⛔ **不得说**「手机能用了」「跨端契约已闭合」「版本已对齐」。✅ 可以说「顶层契约版本已升到 1.14，治理矩阵与后端 DDL 已对齐」。

### 起点基线（**已在 `origin/main` = `f54d9ff` 上实测**，2026-09-07）

| 项 | 命令 | 实测 |
|---|---|---|
| 后端全套 | `cd backend && $PY -m pytest tests/ -q` | **1399 passed**，0 failed / 0 skipped |
| Swift 全套 | `cd ios/Contracts && swift test` | XCTest **302 tests, 0 failures**；swift-testing **1993 tests in 232 suites passed**；exit 0 |
| `plan_1f` 验收脚本 | `bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | **22 passed / 3 failed**（3 条 failed 是**既有**的嵌套回归项，与本片无关） |
| `plan_e2` 验收脚本 | `bash scripts/acceptance/plan_e2_position_manager.sh` | **9 OK / 2 FAIL**（两条 FAIL 都要求 `1.5`，**既有**） |
| Catalyst 总数基线 | `cat .github/scripts/catalyst-total-baseline.txt` | `1897` |

⭐ **本片新增测试数 = 4**（都是 Python；⚠️ 原估 3 条，Task 3 的最终评审要求把正向对照拆成两个测试函数以免「两条判据互相掩盖」，遂成 4 条），**新增 Swift 测试数 = 0** ⇒ Catalyst 的四处基线**一处都不用动**（已实测：`catalyst-uikit-baseline.txt` 里 `contractVersionIs` 命中数 **0**、`N7` 命中数 **0**，本片改名的两个测试都不是 UIKit-gated）。

`$PY` = `"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3"`（⚠️ 本 worktree 里**没有** `.venv`，必须用主目录那份的绝对路径）。

---

## File Structure

| 文件 | 动作 | 责任 |
|---|---|---|
| `docs/governance/m01-schema-versioning-contract.md` | 修改 | 治理矩阵：顶层 cell `1.13`→`1.14`（Task 1）、训练组行 `1`→`2` + 触发条件扩写（Task 2）；追加一条 bump 记录（Task 1） |
| `backend/qmt_pilot_db.py` | 修改 1 行 | 后端侧 `CONTRACT_VERSION` 常量 |
| `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | 修改 1 行 | Swift 侧 `CONTRACT_VERSION` 常量（**唯一真相**，backend 那份与它逐字相等） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift` | 修改 2 行 | 测试**函数名** + `#expect` |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift` | 修改 2 行 | `@Test` **显示名** + `#expect` |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift` | 修改 4 行 | 矩阵断言字面量 + 解析器自检样本 |
| `docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md` | 修改 2 行 | Mac 三个 v1 包作废为归档 |
| `backend/tests/test_frozen_contract_texts.py` | 追加 1 个测试 | m01 训练组行 ↔ 后端 DDL 的**双向**一致性守卫 |
| `backend/tests/test_deployment_source_texts.py` | **新建** | P7 压缩包来源的禁令守卫 + **四条**正向对照（Mac 副本 / NAS handoff 副本 / 改写后的规则 / P4 前置条件） |
| `docs/acceptance/2026-09-07-trainingset-p3c-acceptance.md` | **新建** | 非程序员验收清单 |
| `docs/acceptance/2026-09-07-trainingset-p3c-mutation-log.md` | **新建** | 变异逐条记录 |

---

## Task 1: 顶层 `CONTRACT_VERSION` `"1.13"` → `"1.14"`（10 处字面量 / 6 个文件）

**Files:**
- Modify: `docs/governance/m01-schema-versioning-contract.md:29` + 在 `:46` 之后追加 bump 记录
- Modify: `backend/qmt_pilot_db.py:827`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift:7-8`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift:1238,1260`
- Modify: `ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift:52,64,70,75`

**Interfaces:**
- Consumes: 无（本任务是本片的第一步）
- Produces: `CONTRACT_VERSION == "1.14"`（Swift 与 Python 两份源逐字相等）；m01 矩阵顶层 cell = `` `"1.14"` ``；m01 末尾多一条 2026-09-07 的 bump 记录

### ⚠️ 先读：spec 说「5 个同步点」，实测展开是 **10 处 edit**

spec §3.3 的表把它们归成 5 个「点」，母 spec §5.7 归成 6 个。**按字面量逐处枚举**后是下面这 10 处 —— 其中**第 5、7 两处（函数名与 `@Test` 显示名）两份 spec 都没列**，是本计划实测补上的（本仓成文教训：「订正一个结论，它的回声散在八处，④`@Test` 显示名最常漏」）。

| # | 位置 | 现文 | 改为 |
|---|---|---|---|
| 1 | `m01:29` 矩阵顶层 cell | `` `"1.13"` `` | `` `"1.14"` `` |
| 2 | `m01` 末尾（`:46` 那条记录之后、`**存储表位 速查**` 之前） | — | **追加**一条 bump 记录（正文见下） |
| 3 | `backend/qmt_pilot_db.py:827` | `CONTRACT_VERSION = "1.13"` | `CONTRACT_VERSION = "1.14"` |
| 4 | `Models.swift:7` | `public let CONTRACT_VERSION = "1.13"` | `… = "1.14"` |
| 5 | `ModelsTests.swift:7` | `@Test func contractVersionIs1_13() {` | `@Test func contractVersionIs1_14() {` |
| 6 | `ModelsTests.swift:8` | `#expect(CONTRACT_VERSION == "1.13")` | `… == "1.14")` |
| 7 | `RenderStateBuilderTests.swift:1238` | `@Test("N7：选中态绝不落盘 —— 选中前后 DrawingObject 逐字段一致、契约仍 1.13")` | `… 契约仍 1.14")` |
| 8 | `RenderStateBuilderTests.swift:1260` | `#expect(CONTRACT_VERSION == "1.13")` | `… == "1.14")` |
| 9 | `M01MatrixSyncGuardTests.swift:52` | `XCTAssertEqual(r["`CONTRACT_VERSION`（顶层标识）"], "`\"1.13\"`", …)` | 字面量改 `"1.14"` |
| 10 | `M01MatrixSyncGuardTests.swift:64,70,75` | 解析器自检样本以 **上一次** bump（`1.12`→`1.13`）为素材 | 刷新为**本次**（`1.13`→`1.14`） |

### ⭐ 计划阶段已做的一次预演（证据，不是推演）

写计划时把 m01 的**三处改动**（顶层 cell、训练组行、追加 bump 记录）真的落到工作树上跑了一次
`swift test --filter M01MatrixSyncGuardTests`，然后 `cp` 还原、`git status --short` 确认树干净。实测：

```
Test Case '…test_m01_matrix_three_rows_are_in_sync' started.
M01MatrixSyncGuardTests.swift:52: error: … XCTAssertEqual failed:
  ("Optional("`\"1.14\"`")") is not equal to ("Optional("`\"1.13\"`")") - m01 顶层版本行未同步
Test Case '…test_m01_matrix_three_rows_are_in_sync' failed (0.291 seconds).
Test Case '…test_parser_is_immune_to_values_that_only_appear_in_bump_notes' passed (0.000 seconds).
	 Executed 2 tests, with 1 failure (0 unexpected)
```

三条结论：

1. **Step 7 不是可选的** —— 只改 m01 不改 `:52` 的写死字面量，这条守卫**当场红**（母 spec R4-F2 说的就是这件事，实测复现）。
2. **追加的 bump 记录没有把解析器喂饱** —— `test_parser_is_immune_to_values_that_only_appear_in_bump_notes` 仍绿，且失败停在 `:52` 说明 `:51` 的防空转 `r.count >= 5` **通过**了 ⇒ 新增的 `>` 引用块与改动过的两行都没破坏表解析。
3. 失败信息里出现的是 `1.14` vs `1.13`，证明**矩阵那一格确实被改到了**（而不是改到了别处某个长得像的地方）。

- [ ] **Step 1: 改 `Models.swift:7`（Swift 侧唯一真相）**

```swift
public let CONTRACT_VERSION = "1.14"
```

- [ ] **Step 2: 改 `backend/qmt_pilot_db.py:827`**

```python
CONTRACT_VERSION = "1.14"
```

⚠️ **不要动它上面 `:825-826` 那两行注释**（「与 …Models.swift 的 CONTRACT_VERSION 逐字相等。两边必须同时改」）—— 那是这条纪律的说明。

- [ ] **Step 3: 跑跨语言守卫，确认两边同步**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_qmt_pilot_db.py -q
```

期望：全部通过。⚠️ 若这里红了并点名 `contract_version_matches_swift`，说明 Step 1 / Step 2 只做了一半。

- [ ] **Step 4: 改两个 Swift 测试里的四处（函数名 / 显示名 / 两处 `#expect`）**

`ModelsTests.swift`：

```swift
    @Test func contractVersionIs1_14() {
        #expect(CONTRACT_VERSION == "1.14")
    }
```

`RenderStateBuilderTests.swift`：

```swift
    @Test("N7：选中态绝不落盘 —— 选中前后 DrawingObject 逐字段一致、契约仍 1.14")
```

```swift
        #expect(CONTRACT_VERSION == "1.14")
```

- [ ] **Step 5: 改 m01 矩阵顶层 cell（`:29`）**

```markdown
| `CONTRACT_VERSION`（顶层标识） | `"1.14"` | 跨系统或破坏性持久化变更 bump 联动；P2 本地 journal state 的**兼容新增**不联动 |
```

⛔ 同一张表里的其它 5 行**一行不改**（PostgreSQL schema / app.sqlite GRDB migration / Swift 模型版本 / P2 journal states 本次都不变；训练组 SQLite 那行归 **Task 2**）。

- [ ] **Step 6: 在 m01 追加 bump 记录**

插到 `:46`（2026-08-13 那条记录）之后、`**存储表位 速查**` 之前，**空一行**再写：

```markdown
> **bump 记录（2026-09-07，训练组时间戳语义订正 · 切片一 P3c）**：顶层 `CONTRACT_VERSION` `"1.13"` → `"1.14"`。触发 = A 类**两条同时命中**：「改既有语义」（`end_global_index` 由「一律按下一根开盘反算」改为「按每周期 `datetime` 标注语义分流后反算」，非 `3m` 周期**允许重复**）+「跨系统契约字段调整」（该列是后端产物与 App 读取端共享的字段）。**无结构性 DDL 变更**（表 / 列 / 类型 / 约束逐列相同；`training_set_schema_v1.sql` 仅 `PRAGMA user_version` 一行由 `1` 改 `2`），先例 = 2026-05-25 E2「无 DDL 的读取端语义收紧照样 bump 顶层」（`"1.4"` → `"1.5"`）。⚠️ **与 E2 的不同**：E2 是「无 DDL ⇒ 三套 sub-version 全不动」，本次是「无结构性 DDL，**但**训练组 sub-version 必须动」—— 因为本次的判据是**新旧产物能否互读**，不是**列有没有变**。三套 sub-version 里**只有训练组 SQLite 同步 `1` → `2`**（判据是「新旧产物能否互读」，不是「列有没有变」）；PostgreSQL schema、app.sqlite GRDB migration、Swift 模型版本、P2 journal states **均不变**。
>
> ⚠️ **`1.14` 是一个有意的过渡态**：产物已是第 2 代，而 **App 读取端仍钉在第 1 代**（`DownloadAcceptanceRunner.swift` 的 `TRAINING_SET_SCHEMA_VERSION = 1`、`TrainingSessionCoordinator.swift` 写死的 `expectedSchemaVersion: 1` —— 本片一行未改）。⇒ **切片二必须再 bump 一次顶层**（⚠️ **不得与 `1.14` 共号**；**若期间没有别的 PR 动过顶层号，那就是 `"1.15"`** —— ⛔ 这个数**不是**无条件的：当前主线「划线 P1c 七切片」自带 bump 义务，很可能先把号用掉）：`1.14` = 「产物已升第 2 代、App 尚不支持」，`1.15` = 「App 支持第 2 代」。若切片二不再 bump，「读不了库存的中间态 App」与「能读的完成态 App」会共用 `1.14`，跨语言一致性守卫在两种状态下都绿，这个标识就失去兼容性与回滚审计的意义。
>
> ⚠️ **连带后果**：`backend/qmt_pilot_db.py` 的闸 1 逐字比对 `pilot_meta` 里的 `contract_version`，bump 后**任何带 `"1.13"` 的既有 QMT pilot 库都会被拒**（抛 `schema_fingerprint_mismatch`，提示用 `--reset` 重建）。当前 4b 的 `qmt_fetch.py` 仍零实现、pilot 出货链未投产，风险低。详见 `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §3.3。
```

⚠️ **这条记录里的每一行都必须以 `>` 开头，且不得出现 `|` 字符** —— `M01MatrixSyncGuardTests.rows()` 只收「以 `|` 开头且以 `|` 结尾」的行；出现一行像表格的文本会被当成矩阵数据行，把守卫喂饱。

- [ ] **Step 7: 改 `M01MatrixSyncGuardTests.swift:52` 的断言字面量**

```swift
        XCTAssertEqual(r["`CONTRACT_VERSION`（顶层标识）"], "`\"1.14\"`", "m01 顶层版本行未同步")
```

⛔ `:53`（app.sqlite migration id）与 `:55`（Swift 模型版本 `1.4`）**不改** —— 本次 bump 不涉及这两项。

- [ ] **Step 8: 刷新 `M01MatrixSyncGuardTests.swift` 的解析器自检样本**

只改三处（`:64` 样本行、`:70` 样本 bump 记录、`:75` 断言），使自检以**本次** bump 为素材：

```swift
        | `CONTRACT_VERSION`（顶层标识） | `"1.13"` | … |
```

```swift
        > **bump 记录**：顶层 `CONTRACT_VERSION` `"1.13"` → `"1.14"`；app.sqlite 同步至
```

```swift
        XCTAssertNotEqual(r["`CONTRACT_VERSION`（顶层标识）"], "`\"1.14\"`")
```

⛔ **`:71` / `:76` / `:77` 三行不改**（app.sqlite migration id 与 Swift 模型版本 —— 本次 bump 没动它们，样本里保留旧素材是合理的：这是一份**人造样本**，它唯一的职责是「行里是旧值、引用块里是新值」，不需要对应一次真实存在的 bump）。在 `:58` 那段注释末尾补一句说明这一点：

```swift
    /// ⚠️ 本样本是**人造**的：顶层那行用本次 bump（`1.13` → `1.14`）作素材，
    ///    而 app.sqlite / Swift 模型版本两行仍沿用上一次 bump 的素材 —— 本次 bump 并未改动它们。
    ///    样本只需满足「数据行是旧值、引用块里出现新值」，不必对应一次真实发生过的 bump。
```

- [ ] **Step 9: 跑 Swift 全套**

```bash
cd ios/Contracts && swift test
```

期望：XCTest **302 tests, 0 failures**；swift-testing **1993 tests in 232 suites passed**；exit 0。
⚠️ 数字对不上先查是不是别的 PR 动了基线，⛔ 不要直接改本计划里的数字。

- [ ] **Step 10: 跑后端全套 + 两个既有验收脚本，确认「零 delta」**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```

期望：`1399 passed`（本任务不新增测试）。

```bash
bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh 2>&1 | grep -E "passed, .* failed"
```

期望：`22 passed, 3 failed` —— **与基线逐字相同**。

```bash
bash scripts/acceptance/plan_e2_position_manager.sh 2>&1 | grep -c "^FAIL:"
```

期望：`2` —— 与基线相同（那两条 FAIL 都要求 `1.5`，既有）。
⚠️ 这条命令**单独跑**，别接在 `&&` 后面：`grep -c` 数到 0 时退出码是 1，会把整条链弄断，看起来像失败其实是通过。

- [ ] **Step 11: 逐条定性剩余的 `"1.13"` 命中（穷尽性证据）**

```bash
grep -rn '1\.13' --include='*.py' --include='*.swift' --include='*.md' --include='*.sh' --include='*.yml' --include='*.sql' . | grep -v '^\./\.git/'
```

⛔ **不许加 `| head`**（本仓栽过：`head` 截断让我把 App 侧一条生产代码判成「不相干」）。把完整输出逐条归入以下三类之一；**出现第四类就是漏改**：

- ① **历史记述**：m01 的历史 bump 记录、以及 `docs/superpowers/{specs,plans}/**` 与 `docs/acceptance/**` 里的记述。⚠️ **这一类必须逐条看、不能按目录整片归并**（本仓「穷尽性主张必须按字面量枚举后逐条定性」）—— 实测其中 `2026-08-25-drawing-tools-P1c-split-addendum.md` 是**当前主线 P1c 的活 spec**、不是完结记述，它写着「当前值 `"1.13"`」；该句是 D104 论证的辅助证据、结论与具体数值无关，故**不改**，但必须**点名**而不是混在目录里带过；
- ② **人造样本**：`M01MatrixSyncGuardTests.swift:7-8` 的 docstring（讲的是 2026-08-13 那次 PR 的历史缘由）与 `:64/:70/:71/:76` 的解析器自检样本；
- ③ **迁移 id**：`0010_v1.13_drawing_default_style`（`AppDBMigrations.swift:247,250`、`M01MatrixSyncGuardTests.swift:53,71,76`、m01 矩阵 app.sqlite 行）—— 这是历史标识、不是版本值。

**再跑一条更锐利的**（应为 **0 行**）：

```bash
grep -rn 'CONTRACT_VERSION = "1\.13"\|CONTRACT_VERSION == "1\.13"' --include='*.py' --include='*.swift' . | grep -v '^\./\.git/'
```

- [ ] **Step 12: 提交**

```bash
git add docs/governance/m01-schema-versioning-contract.md backend/qmt_pilot_db.py ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift
git commit -F <(printf '%s\n' 'chore(contract): 顶层 CONTRACT_VERSION 1.13 → 1.14（10 处字面量 / 6 个文件）+ m01 bump 记录' '' 'spec §3.3 的顶层 bump 表列 5 个同步点、母 spec §5.7 列 6 个；按字面量逐处枚举后实测 10 处。' '两份 spec 都没列的两处 = ModelsTests 的函数名 contractVersionIs1_13 与 RenderStateBuilderTests' '的 @Test 显示名「契约仍 1.13」——本仓成文教训里「回声散在八处」的第 4 类。' '' 'm01 追加的 bump 记录写明：A 类两条同时命中、无 DDL、先例 2026-05-25 E2；三套 sub-version 里' '只有训练组 SQLite 同步 1→2；1.14 是有意的过渡态，切片二须再 bump 到 1.15；连带后果是' '带 1.13 的既有 QMT pilot 库会被闸 1 拒、需 --reset。')
```

---

## Task 2: m01 治理矩阵训练组行 `1` → `2` + 触发条件扩写 + doc↔code 守卫

**Files:**
- Modify: `docs/governance/m01-schema-versioning-contract.md:31`
- Modify: `backend/tests/test_frozen_contract_texts.py`（追加 1 个测试 + 追加 1 个常量）
- Test: 同上（守卫自己就是测试）

**Interfaces:**
- Consumes: Task 1 已把顶层 cell 改为 `"1.14"`（本任务与它同文件、不同行）
- Produces: m01 训练组行值 = `2` 且带 P3a 已定义的过渡态标注整句

### ⚠️ 先读：这一行为什么现在是错的

`backend/sql/training_set_schema_v1.sql` 的 `PRAGMA user_version` **早在 #183（P1）就已经是 `2`**，而 m01 矩阵那行仍写 `1` —— 也就是**治理文档与代码已经漂移了两周**。当时之所以没人发现，是因为**没有任何守卫在读这一行**（本仓 backlog 条目 R-E2 记过这件事）。本任务不只订正数值，还要把这个「没人看」的缺口堵上。

- [ ] **Step 1: 改 `m01:31`**

现文：

```markdown
| 训练组 SQLite `PRAGMA user_version` | `1` | 训练组 schema 结构变更；联动顶层 |
```

改为：

```markdown
| 训练组 SQLite `PRAGMA user_version` | `2` | 训练组 schema **结构变更，或字段语义变更导致新旧产物互不可读**；联动顶层（⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地） |
```

⚠️ **括注里那句话必须与 P3a 已定义的 `_TRANSITION_NOTE` 逐字相同**（`backend/tests/test_frozen_contract_texts.py:111`）。逐字相同才有意义：切片二收敛时要一次性把四处标注一起撤掉，字不一样就会漏。

⚠️ **触发条件为什么必须扩写**：原文只写「**结构**变更」。而本次两代产物的**表结构逐列相同**，变的是 `end_global_index` 的**取值语义** —— 照原文字面读，本次根本不该 bump 这一行。留着原文 = 留下一条会把下次同类变更放过去的成文判据。

- [ ] **Step 2: 先跑守卫，确认它现在还不存在（防止误以为已有覆盖）**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py -q
```

期望：`5 passed`（P3a 的五条，**还没有**本任务这条）。

- [ ] **Step 3: 往 `backend/tests/test_frozen_contract_texts.py` 追加常量与守卫**

在文件顶部常量区（`PLAN15 = …` 那行之后）加：

```python
M01 = REPO_ROOT / "docs" / "governance" / "m01-schema-versioning-contract.md"
TRAINING_SET_DDL = REPO_ROOT / "backend" / "sql" / "training_set_schema_v1.sql"
```

在文件末尾追加：

```python
def test_m01_matrix_training_set_row_matches_backend_ddl():
    """m01 治理矩阵的训练组行 == 后端 DDL 里**真正写着**的那个值，且带过渡态标注。

    ⚠️ 这条不是「让文档好看」：doc=1 / code=2 的漂移**真的发生过** —— #183（P1）把
       `training_set_schema_v1.sql` 的 `PRAGMA user_version` 改成 2，而 m01 那行没人动，
       且当时**没有任何测试在读它** ⇒ 漂移安安静静地存在了两周。
    ⛔ **判据不是「等于字面量 2」**：那样在下一次 bump 时会跟 DDL 一起说谎（两边都改错也全绿）。
       判据是「等于**从 DDL 解析出来的值**」——它把两个独立来源钉在一起，任一边单独动都会红。
    ⛔ 也不能只比值：只断言值 = 2 会让 m01 声称「训练组第 2 代」，而 P3a 的守卫**同时**认证
       「App 读取端 = 1」；谁拿 m01 去写读取端就会直接写 2、越过切片次序（与 spec 3b2 同一形状）。
    """
    ddl = TRAINING_SET_DDL.read_text(encoding="utf-8")
    m = re.search(r"^PRAGMA user_version = (\d+);", ddl, re.M)
    assert m, "training_set_schema_v1.sql 里找不到 `PRAGMA user_version = N;` 语句"
    ddl_version = m.group(1)

    rows = [l for l in M01.read_text(encoding="utf-8").splitlines()
            if l.startswith("|") and "训练组 SQLite `PRAGMA user_version`" in l]
    assert len(rows) == 1, (
        f"m01 矩阵里训练组行应恰好 1 行，实测 {len(rows)} 行 —— "
        f"0 行 = 被整行删掉（删证据不是订正）；>1 行 = 又抄了一份")

    cells = [c.strip() for c in rows[0].strip("|").split("|")]
    assert cells[1] == f"`{ddl_version}`", (
        f"m01 矩阵训练组行写 {cells[1]}，而后端 DDL 实际是 `{ddl_version}` —— 文档与代码漂移")

    assert _TRANSITION_NOTE in rows[0], (
        "m01 训练组行改了值但**没带过渡态标注** —— 治理矩阵会声称「训练组已第 2 代」而不说"
        "App 读取端仍是 1，谁照它去写读取端就会越过切片次序")
```

- [ ] **Step 4: 跑，确认变成 6 条全绿**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py -v
```

期望：**6 passed**，且新那条名字是 `test_m01_matrix_training_set_row_matches_backend_ddl`。

- [ ] **Step 5: 变异 M1 —— 把矩阵值改回 `1`，守卫必须红**

```bash
cp docs/governance/m01-schema-versioning-contract.md /tmp/m01.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path("docs/governance/m01-schema-versioning-contract.md")
s = p.read_text(encoding="utf-8")
old = "| 训练组 SQLite `PRAGMA user_version` | `2` |"
assert s.count(old) == 1, f"锚点命中 {s.count(old)} 次，应为 1 —— 中止，不写文件"
p.write_text(s.replace(old, "| 训练组 SQLite `PRAGMA user_version` | `1` |"), encoding="utf-8")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py -q; cd ..
cp /tmp/m01.bak docs/governance/m01-schema-versioning-contract.md
git status --short
```

期望：变异时 **1 failed**，失败信息里同时出现 `` `1` `` 与 `` `2` ``；还原后 `git status --short` **无输出**。

- [ ] **Step 6: ⭐ 变异 M2 —— 把 **DDL** 改成 `3`，守卫必须红（证明它真的在读 DDL）**

这是本条守卫**最关键**的一次变异：它证伪「判据其实是写死的 `2`」。

```bash
cp backend/sql/training_set_schema_v1.sql /tmp/ddl.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path("backend/sql/training_set_schema_v1.sql")
s = p.read_text(encoding="utf-8")
assert s.count("PRAGMA user_version = 2;") == 1, "锚点不唯一 —— 中止"
p.write_text(s.replace("PRAGMA user_version = 2;", "PRAGMA user_version = 3;"), encoding="utf-8")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py -q; cd ..
cp /tmp/ddl.bak backend/sql/training_set_schema_v1.sql
git status --short
```

期望：变异时**至少 2 failed**（本条 + P3a 的 `test_backend_production_side_is_already_generation_two`），且本条的失败信息里出现 `` 而后端 DDL 实际是 `3` ``。
⛔ 若本条**没红**，说明判据退化成了字面量比较 —— 必须改判据，不许改期望。

- [ ] **Step 7: 变异 M3 —— 只删过渡态标注，守卫必须红**

```bash
cp docs/governance/m01-schema-versioning-contract.md /tmp/m01.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path("docs/governance/m01-schema-versioning-contract.md")
s = p.read_text(encoding="utf-8")
note = "（⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地）"
assert s.count(note) == 1, f"锚点命中 {s.count(note)} 次，应为 1 —— 中止"
p.write_text(s.replace(note, ""), encoding="utf-8")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py -q; cd ..
cp /tmp/m01.bak docs/governance/m01-schema-versioning-contract.md
git status --short
```

期望：**1 failed**，失败信息含「没带过渡态标注」。

- [ ] **Step 8: 变异 M4 —— 把训练组行整行删掉，守卫必须红**

```bash
cp docs/governance/m01-schema-versioning-contract.md /tmp/m01.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path("docs/governance/m01-schema-versioning-contract.md")
lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
hit = [i for i, l in enumerate(lines) if l.startswith("| 训练组 SQLite `PRAGMA user_version`")]
assert len(hit) == 1, f"锚点命中 {len(hit)} 次，应为 1 —— 中止"
del lines[hit[0]]
p.write_text("".join(lines), encoding="utf-8")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py -q; cd ..
cp /tmp/m01.bak docs/governance/m01-schema-versioning-contract.md
git status --short
```

期望：**1 failed**，失败信息含「应恰好 1 行，实测 0 行」。
⭐ 这一条复刻 P3a 的 M2 观测量：**光有「值必须对」挡不住「把证据删掉」**。

- [ ] **Step 9: 跑后端全套 + 既有 Swift 守卫，确认零 delta**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```

期望：`1400 passed`（基线 1399 + 本任务 1 条）。

```bash
cd ios/Contracts && swift test 2>&1 | grep -E "Executed [0-9]+ tests, with|Test run with"
```

期望：`Executed 302 tests, with 0 failures` + `Test run with 1993 tests in 232 suites passed`。
⚠️ 关注点：改了 m01 之后 `M01MatrixSyncGuardTests` 仍须**全绿** —— 它解析同一张表，新增的 bump 记录（Task 1）与本行改动都不该让它的行数掉出 `>= 5`。

- [ ] **Step 10: 提交**

```bash
git add docs/governance/m01-schema-versioning-contract.md backend/tests/test_frozen_contract_texts.py
git commit -F <(printf '%s\n' 'fix(governance): m01 矩阵训练组行 1 → 2 + 触发条件扩写 + doc↔code 守卫' '' '这一行自 #183（P1）把 DDL 改成 2 之后就与代码漂移了，而当时没有任何测试读它。' '触发条件由「结构变更」扩写为「结构变更，或字段语义变更导致新旧产物互不可读」——' '本次两代产物表结构逐列相同、变的是取值语义，照原文字面读根本不该 bump 这一行。' '' '新守卫判据 = 矩阵值等于【从 DDL 解析出的值】，不是等于字面量 2（变异 M2 实证：' '把 DDL 改成 3 它照样红）；另要求该行带 P3a 已定义的过渡态标注整句。')
```

---

## Task 3: Mac 本地三个 v1 包作废为审计归档 + 五条文案守卫

**Files:**
- Modify: `docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md:135,138`
- Create: `backend/tests/test_deployment_source_texts.py`

**Interfaces:**
- Consumes: 无（与 Task 1/2 不共文件）
- Produces: 一条可机械检查的「P7 只能从 NAS handoff 目录取」结论

### ⚠️ 先读：这为什么是**数据安全**问题而不是文档洁癖

`2026-08-14-qmt-nas-deployment-design.md:138` 现在写着「P7 的 zip **既可从 Mac scp，也可直接用 NAS 上那份**」。等 P4 把三个产物重建成第 2 代之后，**任何人照这句从 Mac 拷一次，就会把 v1 包盖回部署目录** —— 而数据库里已是新指纹。症状是完整性校验失败或 404，**且收口闸会全绿**，看不出问题出在哪。

- [ ] **Step 1: 改 `:138`**

现文（**逐字**）：

```markdown
→ 「不可再生」的两样东西现在是**本机 + NAS 双份**。P7 的 zip 既可从 Mac scp，也可直接用 NAS 上那份（**判据不变：落到目标目录后必须重算 CRC32 比对**）。
```

改为：

```markdown
→ 「不可再生」的两样东西现在是**本机 + NAS 双份**。⚠️ **2026-09 订正（切片一 P3c）**：P7 的 zip **只能**从 NAS 的 handoff 目录取；Mac 本地 `~/qmt_trial_out/` 那三份自此仅作 **v1 审计归档**，⛔ **不得再 scp 到部署目录** —— 切片一把产物升到第 2 代后，v1 包与库里的新指纹对不上，症状是完整性校验失败或 404，而收口闸会全绿、看不出问题。（**判据不变：落到目标目录后必须重算 CRC32 比对**）
```

- [ ] **Step 2: 给 `:135` 加「历史记述，非判据」标注**

现文：

```markdown
| Mac 本地 `~/qmt_trial_out/` 三个 zip 仍在，重算 CRC32 = `851f9444` / `150d8d6c` / `32892a5f` | `zlib.crc32` 逐个算 |
```

改为：

```markdown
| Mac 本地 `~/qmt_trial_out/` 三个 zip 仍在，重算 CRC32 = `851f9444` / `150d8d6c` / `32892a5f`（⚠️ **历史记述，非判据** —— 2026-09 切片一起这三个包已作废为 v1 审计归档，见本表下方那行订正） | `zlib.crc32` 逐个算 |
```

⚠️ 这一格里的三个 CRC32 是 **v1 的**指纹。不加标注的话，P4 重建之后有人会拿它们当「应该是多少」的判据。

- [ ] **Step 3: 新建 `backend/tests/test_deployment_source_texts.py`**

```python
# backend/tests/test_deployment_source_texts.py
"""P7 压缩包来源的五条文案守卫（spec §3.4「Mac 本地三个 v1 包 —— 明确作废为归档」）。

⭐ 这不是文档洁癖：P4 把产物重建成第 2 代之后，任何人照旧文案从 Mac 拷一次，
   就会把 v1 包盖回部署目录，而库里已是新指纹 ⇒ 完整性校验失败或 404，**收口闸却全绿**。

⚠️ **这条守卫挡得住什么、挡不住什么**（最终评审 Important 1；⛔ 别把它当成「回归防护」的全部）：
   · 挡得住：**原句照抄式回退** —— 把被禁的那句话原样写回作用域内任何一处。
   · ⛔ 挡不住：**任何改写式回退** —— 同义改写（「也可以从 Mac 拷一份」）、英文表述、
     把一句话拆成两行（判据逐行比对，跨行即失效）、全角/半角空格或不可见字符差异。
   这是**有意的取舍**（按段落匹配 markdown 的复杂度远高于收益，与 P3a 的 R10 同一形状），
   不是疏漏；但**任何人拿这条守卫下「已防住回退」的结论之前，必须知道它的边界只到这里**。

⛔ 作用域**不得写成全仓**：被禁的那句话在作用域之外仍必须逐字保留 —— 本片 spec 的论证段
   与变异条目、本片的计划文档、以及本文件自己的注释，都必须引用原句才说得清在禁什么。
   ⛔ **刻意不写「仓内共 N 处」这种含自身的总数**：每多写一句关于这句话的话，这个数就大一
   （spec §3.3 对 `INSERT INTO training_sets` 的计数连栽三轮，此处照办）。
"""
from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

RUNBOOKS = REPO_ROOT / "docs" / "runbooks"
NAS_DESIGN = (REPO_ROOT / "docs" / "superpowers" / "specs"
              / "2026-08-14-qmt-nas-deployment-design.md")

# ⛔ 作用域 = 【会被人当操作依据的两类文本】：runbook（照着敲的）+ 那份部署设计（P7 的出处）。
#    ⛔ 不含 `docs/superpowers/specs/2026-09-01-*`（本片 spec）与 `docs/superpowers/plans/**`
#      ——它们是**论证与记述**，必须逐字引用被禁的原句才说得清在禁什么。
#    ⭐ 因为作用域已经把它们排除在外，**不需要**再写一份白名单（spec 里提到的白名单在这个
#      作用域下是空转的；本仓不写永远走不到的分支）。
_FORBIDDEN = "既可从 Mac scp"

# 改写后那句话的三个特征词，必须**同时**出现在同一行。
# ⛔ 不用单个词做判据：「只能」两个字在部署文档里到处都是。
_REWRITTEN_MARKERS = ("只能", "v1 审计归档", "不得再 scp 到部署目录")

_ARCHIVE_NOTE_MARKERS = ("~/qmt_trial_out/", "历史记述，非判据")

# ⛔ NAS handoff 目录那份**也是 v1**（与 Mac 那份 CRC32 逐字相同，是同一批包的两份副本）。
#    最终评审 I1：本片原先的订正只落在两行中的一行，而新规则偏偏把操作者指向了**未订正的那一行**。
_NAS_ARCHIVE_NOTE_MARKERS = ("kline-trainer-handoff-20260814", "历史记述，非判据")

# ⛔ 新规则必须带**前置条件**，不能无条件地把 handoff 目录指定为来源。
_P4_PRECONDITION_MARKERS = ("同样是 v1 包", "P4 重建完成", "不得作为第 2 代产物的来源")


def _scope_files():
    # ⚠️ spec §3.4 写的作用域是 glob `docs/superpowers/specs/2026-08-14-*`，这里**硬编码成单个文件路径**。
    #    实测今天该 glob 只命中这 1 个文件 ⇒ 当前等价；⛔ 日后若多一份 `2026-08-14-*` 的 spec，
    #    会被**静默**漏掉。
    files = [NAS_DESIGN]
    # ⚠️ 后缀白名单是**静默**的盲区：实测今天 `docs/runbooks/` 下 14 个文件全在这三种之内
    #    （8 个 .md / 2 个 .sh / 4 个 .sql）。⛔ 日后若往这里放 `.yml` / `.txt` / `.env` 之类
    #    **同样会被人照着敲**的文件，必须回来把后缀补进去 —— 漏掉不会报错，守卫照样全绿。
    files += [p for p in RUNBOOKS.rglob("*")
              if p.is_file() and p.suffix in (".md", ".sql", ".sh")]
    # ⛔ 防空转：目录被改名/移走时 `rglob` **静默返回空**（不报错），整条禁令守卫会从
    #    「扫十几个文件」退化成「扫 1 个」且照样全绿 —— 本仓「报 0 违反的扫描必须先证明
    #    它能报非 0」那一类。
    assert len(files) >= 2, f"作用域只收集到 {len(files)} 个文件 —— runbooks 目录是不是被改名/移走了？"
    return files


def test_p7_source_wording_no_longer_offers_the_mac_copy():
    """守卫①：作用域内不得再出现「既可从 Mac scp」这句旧文案。"""
    offenders = []
    for p in _scope_files():
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError) as e:
            # ⛔ 不把「读不了」混进「不是目标」（本仓「守卫里一个 continue 混了两种含义」教训）：
            #    读不了必须**响**，否则一个权限错误会让整份文件静默退出作用域。
            raise AssertionError(f"作用域内的文件读不了，无法判定：{p} —— {e}") from e
        for i, line in enumerate(text.splitlines(), start=1):
            if _FORBIDDEN in line:
                offenders.append(f"{p.relative_to(REPO_ROOT).as_posix()}:{i}: {line.strip()[:120]}")
    assert not offenders, (
        "作用域内仍有「P7 既可从 Mac scp」这类文案 —— P4 重建后照它拷一次就会把 v1 包"
        "盖回部署目录，而收口闸全绿：\n" + "\n".join(offenders))


def test_rewritten_p7_source_rule_is_present():
    """守卫①的**正向对照（其一）**：改写后那句「只能从 NAS handoff 取」必须真的在，且恰好 1 行。

    ⚠️ 只有上面那条禁令的话，把 `:138` **整行删掉**同样能让它变绿 —— 那不是订正，是删证据。
    ⛔ 与下面那条**必须分成两个测试函数**：写在同一个函数里时，前一条 `assert` 先失败即中止，
       后一条根本不会执行 —— 两处被同一次编辑一起删掉时，失败信息只提得到前一处
       （本仓「两条判据互相掩盖」的成文教训）。
    """
    lines = NAS_DESIGN.read_text(encoding="utf-8").splitlines()
    rule = [l for l in lines if all(m in l for m in _REWRITTEN_MARKERS)]
    assert len(rule) == 1, (
        f"部署设计里「P7 只能从 NAS handoff 取 / Mac 副本仅作 v1 审计归档 / 不得再 scp 到部署目录」"
        f"应恰好 1 行，实测 {len(rule)} 行 —— 0 行 = 被整行删掉；>1 行 = 抄了两份（会各自漂移）")


def test_mac_copy_archive_note_is_present():
    """守卫①的**正向对照（其二）**：Mac 三个 zip 那行必须带「历史记述，非判据」标注，且恰好 1 行。

    ⚠️ 它独立成一个测试的理由见上一条的 docstring。
    """
    lines = NAS_DESIGN.read_text(encoding="utf-8").splitlines()
    note = [l for l in lines if all(m in l for m in _ARCHIVE_NOTE_MARKERS)]
    assert len(note) == 1, (
        f"Mac 三个 zip 那行应带「历史记述，非判据」标注且恰好 1 行，实测 {len(note)} 行 —— "
        f"少了它，P4 重建之后有人会拿那三个 v1 指纹当「应该是多少」的判据")


def test_nas_handoff_copy_archive_note_is_present():
    """守卫①的**正向对照（其三）**：NAS handoff 那行也必须带「历史记述，非判据」标注，且恰好 1 行。

    ⚠️ **最终评审 I1**：`:135`（Mac 副本）与 `:136`（NAS handoff 副本）的三个 CRC32 **逐字相同**
       —— 本就是同一批 v1 包的两份副本。原先只给前者加了标注，后者原样留着 ⇒
       「拿 v1 指纹当『应该是多少』」这个被消灭的风险，在下一行完好无损。
    """
    lines = NAS_DESIGN.read_text(encoding="utf-8").splitlines()
    note = [l for l in lines if all(m in l for m in _NAS_ARCHIVE_NOTE_MARKERS)]
    assert len(note) == 1, (
        f"NAS handoff 那行应带「历史记述，非判据」标注且恰好 1 行，实测 {len(note)} 行 —— "
        f"它与 Mac 那份是同一批 v1 包，少了标注就会有人拿那三个 v1 指纹当判据")


def test_p7_source_rule_carries_the_p4_precondition():
    """守卫①的**正向对照（其四）**：那条「只能从 handoff 取」的规则必须带 **P4 前置条件**。

    ⚠️ **最终评审 I1 的核心**：规则给出的理由（v1 包与新指纹对不上）**逐字适用于它自己指定的
       那个替代来源**。不带前置条件的话，P4 之后照新规则做会产生**同一个**故障，而且这次
       带着权威背书 —— 比订正之前更糟（操作者会以为自己拿到了背书）。
    ⛔ 本条**必须独立成测试**：与上面几条合并会互相掩盖（本仓成文教训）。
    """
    lines = NAS_DESIGN.read_text(encoding="utf-8").splitlines()
    hit = [l for l in lines if all(m in l for m in _P4_PRECONDITION_MARKERS)]
    assert len(hit) == 1, (
        f"「P7 只能从 handoff 取」这条规则应带 P4 前置条件且恰好 1 行，实测 {len(hit)} 行 —— "
        f"0 行 = 规则又变回无条件，会把操作者指向同样是 v1 的那份副本")
```

- [ ] **Step 4: 跑，确认 2 条全绿**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_deployment_source_texts.py -v
```

期望：**2 passed**。

- [ ] **Step 5: 变异 M5 —— 把 `:138` 改回原句，两条都必须红**

```bash
cp docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md /tmp/nas.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path("docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md")
s = p.read_text(encoding="utf-8")
new = "⚠️ **2026-09 订正（切片一 P3c）**：P7 的 zip **只能**从 NAS 的 handoff 目录取"
assert s.count(new) == 1, f"锚点命中 {s.count(new)} 次，应为 1 —— 中止"
lines = s.splitlines(keepends=True)
hit = [i for i, l in enumerate(lines) if new in l]
lines[hit[0]] = "→ 「不可再生」的两样东西现在是**本机 + NAS 双份**。P7 的 zip 既可从 Mac scp，也可直接用 NAS 上那份（**判据不变：落到目标目录后必须重算 CRC32 比对**）。\n"
p.write_text("".join(lines), encoding="utf-8")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_deployment_source_texts.py -q; cd ..
cp /tmp/nas.bak docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md
git status --short
```

期望：**2 failed**（禁令红 + 正向对照红）。

- [ ] **Step 6: ⭐ 变异 M6 —— 把 `:138` **整行删掉**，禁令必须变绿、只有正向对照红**

```bash
cp docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md /tmp/nas.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path("docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md")
lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
hit = [i for i, l in enumerate(lines) if "不得再 scp 到部署目录" in l]
assert len(hit) == 1, f"锚点命中 {len(hit)} 次，应为 1 —— 中止"
del lines[hit[0]]
p.write_text("".join(lines), encoding="utf-8")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_deployment_source_texts.py -q; cd ..
cp /tmp/nas.bak docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md
git status --short
```

期望：**1 failed / 1 passed** —— 红的是正向对照那条，禁令那条**绿**。
⭐ 这就是「正向对照不可省」的观测量：**光有禁令，删证据也能蒙混过关**。

- [ ] **Step 7: 变异 M7 —— 删掉 `:135` 的「历史记述，非判据」，正向对照必须红**

```bash
cp docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md /tmp/nas.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path("docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md")
s = p.read_text(encoding="utf-8")
frag = "（⚠️ **历史记述，非判据** —— 2026-09 切片一起这三个包已作废为 v1 审计归档，见本表下方那行订正）"
assert s.count(frag) == 1, f"锚点命中 {s.count(frag)} 次，应为 1 —— 中止"
p.write_text(s.replace(frag, ""), encoding="utf-8")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_deployment_source_texts.py -q; cd ..
cp /tmp/nas.bak docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md
git status --short
```

期望：**1 failed**，失败信息含「历史记述，非判据」。

- [ ] **Step 8: ⭐ 变异 M8 —— 往 runbook 里塞一行假违例，禁令必须红并点名 runbook**

证明作用域不只覆盖那一份 spec（复刻 P3a 的 M10：自排除/窄作用域有没有把守卫弄瞎，必须单独证伪）。

```bash
cp docs/runbooks/2026-08-24-qmt-nas-deployment.md /tmp/rb.bak
printf '\n<!-- 变异 M8 临时行：P7 的 zip 既可从 Mac scp -->\n' >> docs/runbooks/2026-08-24-qmt-nas-deployment.md
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_deployment_source_texts.py -q; cd ..
cp /tmp/rb.bak docs/runbooks/2026-08-24-qmt-nas-deployment.md
git status --short
```

期望：**1 failed**，且失败信息里**点名** `docs/runbooks/2026-08-24-qmt-nas-deployment.md` 与行号。

- [ ] **Step 9: 跑后端全套**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```

期望：`1403 passed`（基线 1399 + Task 2 的 1 条 + 本任务 3 条）。
⚠️ **原写 1402 / 2 条**：Task 3 的最终评审要求把正向对照拆成两个测试函数（见本片最终评审的修复波），故为 3 条。

- [ ] **Step 10: 提交**

```bash
git add docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md backend/tests/test_deployment_source_texts.py
git commit -F <(printf '%s\n' 'fix(deploy-doc): Mac 三个 v1 包作废为审计归档 + P7 来源文案守卫' '' 'P4 重建成第 2 代之后，照旧文案「P7 的 zip 既可从 Mac scp」拷一次，就会把 v1 包' '盖回部署目录，而库里已是新指纹 ⇒ 完整性校验失败或 404，且收口闸全绿、看不出问题。' '' '作用域 = docs/runbooks/** + 那份 2026-08-14 部署设计（会被当操作依据的两类文本），' '⛔ 不写成全仓：该句全仓 4 处命中里 3 处在本片自己的 spec 里、删不得。' '因为作用域已排除它们，spec 提的白名单在此是空转的，故不写。' '' '变异 M6 实测：把那行整行删掉 ⇒ 禁令守卫变绿、只有正向对照红 —— 正向对照不可省。')
```

---

## Task 4: 验收清单 + 变异记录 + 计划本身入库

**Files:**
- Create: `docs/acceptance/2026-09-07-trainingset-p3c-acceptance.md`
- Create: `docs/acceptance/2026-09-07-trainingset-p3c-mutation-log.md`
- Add: `docs/superpowers/plans/2026-09-07-trainingset-p3c-version-bump.md`（本文件）

- [ ] **Step 1: 写验收清单**（中文、非程序员可执行、动作/期望/通过判定三段式）

必须含的动作，**每条的期望数字都要先用真实输出对过**（⛔ 不许照抄本计划里的数字就交）：

| 序 | 动作 | 期望 |
|---|---|---|
| A1 | 跑后端全套 | `1403 passed`，无 `failed`/`skipped`/`error` |
| A2 | 跑本片新加的 4 条守卫 | 4 行 `PASSED` |
| A3 | 跑 Swift 全套 | `Executed 302 tests, with 0 failures` + `Test run with 1993 tests in 232 suites passed` |
| A4 | 列出全仓 `CONTRACT_VERSION` 的两处源 | 两行，都是 `1.14` |
| A5 | 看 m01 矩阵那两行 | 顶层 = `` `"1.14"` ``、训练组 = `` `2` `` 且带过渡态标注 |
| A6 | 确认三个禁区一行未动 | `.github/` = 0；`generate_training_sets.py` + `backend/sql/` = 0；App **运行逻辑**文件 = 0（⚠️ 本片 `ios/` 改动文件数**不是** 0，是 4 —— 全是常量与测试断言，见清单说明） |
| A7 | 两个既有验收脚本零 delta | `plan_1f` = `22 passed, 3 failed`；`plan_e2` 的 `FAIL:` 行数 = `2` |
| A8 | 本片一共动了哪些文件 | 逐个列出并说明用途 |

⚠️ **A6 必须特别写清楚**：P3a 那片的判据是「`ios/` 改动文件数 = 0」，**本片不是** —— 本片按 spec 授权改了 4 个 `ios/` 文件，但**全部是常量与测试断言/显示名**，App 的运行逻辑一行未动。清单里要给出**可机械核对**的表达：

```bash
git diff --name-only origin/main...HEAD -- ios/ | sort
```

期望恰好这 4 个（且**一个不多**）：

```
ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift
ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift
```

并附一条更锐的：

```bash
git diff --name-only origin/main...HEAD -- ios/Contracts/Sources/ | wc -l
```

期望 `1`（只有 `Models.swift` 那一个源文件，且它只改了一个字符串字面量）。

- [ ] **Step 2: 写变异记录**（**10 组：M1 / M2 / M3 / M4 / M4b / M5 / M6 / M7 / M8 / M9**），⚠️ **编号为什么有个 `M4b`**：控制者在 Task 2 的评审之后补跑了一组「把训练组行再抄一份」（评审指出 `>1 行` 那个分支没人测过），当时记作 M5；但 Task 3 的计划已把 M5–M8 分配给 Mac 副本那一批，**且 M6/M8 已写进 commit `e402ed1` 的提交信息、改不了** ⇒ 遂把 Task 2 那组改名为 **M4b**。M9 则是 Task 3 修复轮新增的「两行一起删」，用来证明拆成两个测试函数确实让两条各自点名自己那一处。**这段由来必须写进记录文件**，否则读者会以为漏了一组。逐条含：改了什么、跑了什么、**原样贴出的观测输出**、结论。

- [ ] **Step 3: 把残留写进验收清单末尾**（见下节「已知残留」，逐条照抄）

- [ ] **Step 4: 提交**

```bash
git add docs/acceptance/2026-09-07-trainingset-p3c-acceptance.md docs/acceptance/2026-09-07-trainingset-p3c-mutation-log.md docs/superpowers/plans/2026-09-07-trainingset-p3c-version-bump.md
git commit -m "docs(p3c): 验收清单（8 条）+ 变异记录（10 组）+ 实施计划"
```

---

## 已知残留（本片**不**解决，必须逐条写进验收清单）

1. ⛔ **`INSERT INTO training_sets` 有 10 处缺 `schema_version`**（5 处在 `.github/workflows/schema-smoke.yml`）⇒ 归 **P3b**，它是唯一碰 workflows 的一片。
2. ⛔ **生成器 DDL 字面量 ↔ 冻结 DDL 文件之间无任何守卫**（自 Plan B2 起就在，非本片引入）⇒ 建议并入 **P3b**。
3. ⛔ **库存 3 个产物仍是第 1 代**；`api` / `scheduler` / 生成器 CLI **必须保持停止**；重建归 **P4**。
4. ⛔ **App 侧一行运行逻辑未改** ⇒ 归**切片二**，且有**两道**拦路石：只认 `.sqlite` 成员、以及 `DefaultTrainingSetReader.swift:90-92` 的严格递增运行时校验。
5. ⛔ **切片二必须再 bump 一次顶层，且不得与 `1.14` 共号**（若期间无其它 bump 则是 `"1.15"`，⛔ 但这不是无条件的 —— 主线 P1c 自带 bump 义务）。`1.14` 是「产物已第 2 代、App 尚不支持」的**过渡态**；不再 bump 则两种状态共用同一标识，跨语言守卫两边都绿。
6. ⚠️ **带 `"1.13"` 的既有 QMT pilot 库会被闸 1 拒**，需 `--reset` 重建。当前 4b 未投产、风险低。
7. ⚠️ **`kline_trainer_modules_v1.4.md:144` 的 `CONTRACT_VERSION | "1.5"` 仍 stale**，刻意不改 —— **实测**：`plan_e2:37` 正断言它 = `1.5` 并当前通过，改了会让该脚本从 2 FAIL 变 3 FAIL。归 `2026-08-31-acceptance-stale-literals-design.md` F21。
8. ⚠️ **`plan_e2` 另两条断言仍要求 `1.5`**（`§4.2.7 门` 与 `m01 矩阵`），本片 bump 后仍是 FAIL —— **既有失败，非本片引入**，delta 为 0。
9. ⚠️ **`catalyst-gate.sh:161` 的注释举例仍写 `contractVersionIs1_11()`**（两次 bump 之前的名字）。它是长注释里的**举例**、不是判据（实测：`catalyst-uikit-baseline.txt` 里 `contractVersionIs` 命中 0），改它属范围蔓延 ⇒ 不改。
10. ⚠️ **文案守卫①只钉「既可从 Mac scp」这 8 个字**：同义改写（「也可以从 Mac 拷一份」）、英文、拆成两行都绕得过。这是**有意的取舍**（按段落匹配 markdown 的复杂度远高于收益），与 P3a 的 R10 同一形状。
11. ⚠️ **runbook `P7` 现在是从 NAS 的 `kline-trainer-handoff-20260814/` 拷的**，而那个目录里躺的仍是 v1 包。本片的守卫**抓不到它**（那里没有任何「Mac」字样）⇒ **P4 必须把这个来源目录一并处理**，否则一次干净重部署会用陈旧包覆盖修好的包。母 spec §5.6 把它列为「最危险的一处」。
12. ⚠️ **本片的守卫今天全红也不阻止合并** —— 后端测试不在 `main` 的 ruleset 必需检查里。修法属独立 PR，且需 user 本人在网页上改配置。
13. ⚠️ **m01 顶层行的守卫是「文档 ↔ 写死字面量」**（`M01MatrixSyncGuardTests:52`），不是「文档 ↔ 代码常量」。它能挡住「改了代码忘了改矩阵」，但下一次 bump 仍要手工同步那个字面量。本片**不扩**（Task 2 的新守卫已把训练组那行做成 doc↔code，顶层这条属既有设计）。

---

## Self-Review（写完后自查，已执行）

**1. spec 覆盖**：§3.3 第 4 项（m01 矩阵）→ Task 2 ✅；§3.3 顶层 bump 表 5–9 项 → Task 1 ✅；§3.4「Mac 三个 v1 包」1–4 → Task 3 ✅。§3.3 的 1/2/3/3b/3b-2nd/3b2/3c/3d/3e/4b/4c/4d 已由 P1 与 P3a 落地；`INSERT` 补字段与 PG `DEFAULT 1` 归 P3b（残留 1/2）。

**2. 占位扫描**：无 TBD / TODO / 「类似 Task N」/ 「补充适当的错误处理」。每个代码步骤都给了可直接落地的完整代码块。

**3. 类型/命名一致性**：`_TRANSITION_NOTE`（复用 P3a 已有常量，⛔ 不新定义第二份）· `M01` / `TRAINING_SET_DDL`（Task 2 新增，仅本文件内用）· `_FORBIDDEN` / `_REWRITTEN_MARKERS` / `_ARCHIVE_NOTE_MARKERS`（Task 3 新文件内用）· 测试函数名三条互不重名。

**4. 计数自查**：后端测试数 1399 → 1400（Task 2）→ 1402（Task 3）→ **1403**（Task 3 修复轮把正向对照拆成两个测试函数）；Swift 测试数**不变**（只改名与字面量）⇒ Catalyst 四处基线不动。
