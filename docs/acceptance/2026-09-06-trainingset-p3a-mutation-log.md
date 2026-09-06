# 切片一 P3a（冻结契约文本一致性）· 变异验证逐条记录

**分支** `feat/trainingset-p3a-contract-texts`
**跑的人** 控制者本人（⛔ 不是子代理转述）
**日期** 2026-09-07
**基线** 全套 `1399 passed / 0 failed / 0 skipped`；聚焦 `tests/test_frozen_contract_texts.py` **5 passed**

## 纪律（每条本仓都栽过）

一组一条命令；`backup`/`restore` 包在 `try/finally` 里、复原是每组最后一步；复原用 `cp` 副本，⛔ 不用 `git checkout <file>`；每组跑前清 `backend/**/__pycache__`；**锚点命中数 ≠ 1 当场中止且不写盘**；每组跑完**单独打印 `git status --short`**（下表末列即当次实测，**10 组全部为空**）。

---

## 逐组结果

| # | 变异 | 期望 | 实测红的**具体用例** | 复原后 `git status` |
|---|---|---|---|---|
| **M1** | `modules:2302` R03 改回旧表述（「全周期严格递增」） | 禁令 + 正向对照双红 | 🔴 `test_old_all_periods_strictly_increasing_wording_is_gone`（点名 `:2302`）<br>🔴 `test_rewritten_clauses_are_present_in_both_root_authorities`（modules 变 0 行）<br>合计 **2 failed, 3 passed** | 空 |
| **M2** | ⭐⭐ `plan_v1.5:1285` **整行删掉**（不是改回去） | 只有正向对照红 | 🟢 **禁令守卫不红**（旧表述确实没了）<br>🔴 **只有** `test_rewritten_clauses_are_present_in_both_root_authorities`<br>合计 **1 failed, 4 passed** | 空 |
| **M3** | `modules:723` 那条**合法无关**的行改成含 `global_index` 的措辞 | 禁令红 | 🔴 `test_old_all_periods_strictly_increasing_wording_is_gone`（点名 `:723`） | 空 |
| **M4** | ⭐⭐ 把守卫①判据里 `and "global_index" not in line` 那半个条件**删掉**（退化成裸词） | **在干净树上当场红** | 🔴 `test_old_all_periods_strictly_increasing_wording_is_gone`，点名的正是那条**合法无关**的 `:723`（`ticket_index 严格递增`） | 空 |
| **M5** | `modules:2239` 值改回 `1`（标注留着） | 版本守卫红 | 🔴 `test_frozen_contract_version_refs_are_2_with_transition_note`（「应恰好 3 处…实测 2 处」） | 空 |
| **M6** | ⭐⭐ `modules:2239` 值**保持 `2`**、**只删过渡态标注** | 版本守卫红 | 🔴 同上，报「改了值但**没带过渡态标注**」 | 空 |
| **M7** | `DownloadAcceptanceRunner.swift:14` 的常量 `1` → `2` | App 钉桩守卫红 | 🔴 `test_app_reader_is_still_pinned_to_generation_one`（前半） | 空 |
| **M8** | `TrainingSessionCoordinator.swift:1360` 的**写死字面量** `1` → `2` | 同上 | 🔴 同一条用例（后半） | 空 |
| **M9** | 冻结 DDL 的 `PRAGMA user_version` `2` → `1` | 后端生产侧守卫红 | 🔴 `test_backend_production_side_is_already_generation_two` | 空 |
| **M10** | ⭐⭐ **自排除是否把守卫弄瞎**：往 `backend/generate_training_sets.py` 末尾塞一行含「严格递增」+ `global_index` 且无放行词的注释 | 禁令守卫仍应红 | 🔴 `test_old_all_periods_strictly_increasing_wording_is_gone`，点名 `backend/generate_training_sets.py:845` ⇒ **自排除只排除了守卫自己，没有把作用域弄瞎** | 空 |

---

## 四条从实测里读出来的结论（不是推演）

### 1. M2 证明「正向对照」那条守卫**不可省**

把与新公式矛盾的那条规则**整行删掉** ⇒ 禁令守卫**变绿**（旧表述确实没了），只有正向对照红。

⇒ 若只有禁令守卫，「**删证据**」这条路会畅通无阻，而它既不是订正、还让根级权威少了一条本该在的规则。

### 2. M4 证明「判据不得写成裸词」不是空话

把 `global_index` 那半个条件删掉，守卫**在当前这棵干净的树上当场红**，点名的正是 `modules:723` 那条**讲 `ticket_index`、与本片毫无关系**的合法行。

⇒ 若当初图省事写成裸词，实施者遇到这个红，最省事的「修法」就是**去改那条无关的行** —— 把好东西改坏。

### 3. M6 证明「只断言值」会漏掉整个洞（spec 变异 B16 的观测量）

值保持 `2`、**只删掉过渡态标注** ⇒ 守卫仍红。

⇒ 若守卫只查值，冻结契约就会声称「前后端共享 = 2」，而同一份守卫**同时**把「App 侧 = 1」认证为正确 —— 两条权威互相打脸。这正是本片要消灭的形状，不能在消灭它的同时又造一个。

### 4. M7 / M8 证明 App 侧那两处**必须分别断言**

两处形状不同：一处是**常量定义**（`public let TRAINING_SET_SCHEMA_VERSION = 1`），另一处是**写死的字面量**（`expectedSchemaVersion: 1`，源码注释解释了为什么硬编码）。两组变异各自都能让同一条用例红 ⇒ 两处都真的被覆盖了。

⚠️ 若当初照 spec 那样套同一个正则，会漏掉其中一处 —— 而 spec 给的行号本身也已过期（`:1307` 实测在 `:1360`）。

---

## 一处计划缺陷，由实施者在执行中挡下

守卫①的作用域含 `backend/**/*.py`，而**守卫自己就住在那里**；它的 docstring 必须**逐字引用**所禁止的那句话（不然没法说明自己在禁什么）⇒ **它把自己判成了违例**（实测 `:52` 那行，全套 1398 过 1 失败）。

⭐ 实施者确认了转录逐字无误、判定这是**计划的结构性缺陷**、**没有擅自改设计**，报 BLOCKED 并说明需要一个设计决策。

**裁定**：按 `Path(__file__).resolve()` 排除**自身**。
⛔ 否决「改写 docstring 绕开自己的判据」—— 一条说不出自己在禁什么的守卫是更糟的守卫，且下一个想加同类注释的人还会再踩。
⛔ 不整目录排除 `backend/tests/`（等于把一整个目录永久移出作用域）。
⛔ 不按文件名字符串排除（**改名后会静默重新自指**、红得莫名其妙）。

**而自排除有没有把守卫弄瞎，由 M10 单独证伪** —— 见上表。
