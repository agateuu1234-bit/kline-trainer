# TS1-R1 设计：`training_sets.schema_version` 改成 fail-closed

**一句话**：去掉 `DEFAULT 1`，让**漏填该字段的写入直接失败**，而不是静默拿到第 1 代。

**引用治理**：`docs/governance/m01-schema-versioning-contract.md` §Bump 策略 A 类（影响 DDL）
**立项依据**：`docs/superpowers/specs/2026-09-23-ts1r1-schema-version-fail-closed-brief.md`
**前置**：#194（仓内 10 处写入方补齐）—— **已在 main**，见 §2 核实
**基线**：`origin/main` = `6b961db7`

---

## §1 要解决的问题

`training_sets.schema_version` 记的是「这批产物是第几代」。它有 `NOT NULL DEFAULT 1`。
而 `backend/generate_training_sets.py:45` 的 `SCHEMA_VERSION = 2` —— 产物从 #183 起已是**第 2 代**。

⇒ 任何**漏填该字段**的写入都会被默认值**静默**标成第 1 代：不报错、不告警，只是数据错了。

此前两片都在**源码层**堵这件事（#194 的机械守卫、#201 的宿主解码加固）。
那条路线的天花板已经实测过：守卫读的是**源码文本**，而 SQL 是宿主语言**运行时拼出来的**，
拼法是开放的 —— #201 八轮评审九条缺陷全在这一条根上。

**本片把判据下沉到数据库**：不管 SQL 怎么拼出来、注释怎么闭合、表名从哪来，
少填字段 **PostgreSQL 直接报错**。

---

## §2 前置条件（已核实，不是推测）

| 断言 | 怎么核实的 | 结果 |
|---|---|---|
| 仓内所有**可执行**写入方都已显式给值 | main 上 #194 的守卫 `_enforce` 实跑 | `checked=12 / missing=0` |
| 守卫作用域**之外**没有漏填的可执行写入 | 两种方式全仓扫描并对账（`git grep` 与 `find+grep`，各 21 个文件、差集为空），逐个分类 | 作用域外 11 个全是 `docs/` 下的散文提及 / 测试输出记录 / 锚点字符串，**无一条可执行** |
| 真正的生产写入方显式给值 | 读 `backend/generate_training_sets.py:563-567` | 列清单含 `schema_version`，值来自 `SCHEMA_VERSION = 2` |
| `schema_version` 列无 CHECK 约束 | `grep` 全部 `.sql` | 无 ⇒ `DROP DEFAULT` 不与任何约束冲突 |

⇒ **`DROP DEFAULT` 不会打断仓内任何写入方。** 这是本片可以落地的唯一前提。

⚠️ 一条**更正**：立项简报说本片必须等「INSERT 守卫」那一片合并后才能动 —— 不准确。
前置是「写入方补齐」，那是 **#194** 干的、已在 main。
#201 只加固**守卫**、不改任何写入方 ⇒ 本片与 #201 **互不阻塞**。

---

## §3 方案选择

### 方案 A（采用）：`DROP DEFAULT` + 保留 `NOT NULL` + 一条列注释

漏填时 PostgreSQL 报：
`null value in column "schema_version" of relation "training_sets" violates not-null constraint`
—— 点名了表与列。

- 最小：一处 DDL，存量行零影响（`DROP DEFAULT` 只改列元数据）
- 可逆：`rollback.sql` 就是 `SET DEFAULT 1`
- 列注释**零闸门代价**（实测：活目录指纹 0 处、P6b 闸门 0 处覆盖注释），
  而它是唯一能把「为什么刻意没有默认值」留在数据库里的地方；
  `schema.sql` 本来就有 2 处 `COMMENT ON`，是既有惯例

### 方案 B（否决）：`DEFAULT -1` + 具名 CHECK

报错自带约束名、可读性更好。但：

- 约束从 **15 → 16 条** ⇒ 活目录指纹的约束段与 P6b 闸门的约束段**都要改**，比 A 多碰两处闸门
- 留下概念噪音：列里「可以」有 `-1`（靠 CHECK 挡），而本意是「必须有人填」
- 用两个 DDL 对象换一条更漂亮的报错文字 —— 不划算；A 用一条零成本注释补上了这唯一的优势

### 方案 C（否决）：`BEFORE INSERT` 触发器 —— 过度工程。

---

## §4 完整改动面（7 组，逐一带文件:行号）

### ①`backend/sql/schema.sql:75`

```sql
-- 改前
    schema_version INTEGER NOT NULL DEFAULT 1,
-- 改后
    schema_version INTEGER NOT NULL,
```

外加（放在文件既有 `COMMENT ON` 附近）：

```sql
COMMENT ON COLUMN training_sets.schema_version IS
  '产物代号。⛔ 刻意不设默认值：漏填必须当场失败，不能被静默标成第 1 代。';
```

### ②新建 `backend/sql/migrations/0005_schema_version_fail_closed/`

四件套（`forward.sql` / `rollback.sql` / `README.md` / `rehearse.sh`），照
`0004_qmt_price_double_and_coverage/` 的格式（PG 迁移序列现仅有 0004，**0005 空闲**）。
⚠️ `rehearse.sh` 内容较多，单独放在 §4③。

`forward.sql`（含与 0004 同形的头注释：引用治理 / 触发 / Spec / 变更列表，整体 `BEGIN; … COMMIT;`）：

```sql
ALTER TABLE training_sets ALTER COLUMN schema_version DROP DEFAULT;
COMMENT ON COLUMN training_sets.schema_version IS
  '产物代号。⛔ 刻意不设默认值：漏填必须当场失败，不能被静默标成第 1 代。';
-- ⚠️ 这段文字必须与 schema.sql 里那条**逐字一致** —— 两份副本不一致时，
--    从 schema.sql 新建的库与跑过迁移的库注释会不同，而注释不被任何闸门覆盖 ⇒ 无人发现。
```

`rollback.sql`：

```sql
ALTER TABLE training_sets ALTER COLUMN schema_version SET DEFAULT 1;
COMMENT ON COLUMN training_sets.schema_version IS NULL;
```

`README.md`：**一项**变更的说明（0004 是三项合一，0005 只有这一项）+ rollback 风险评估
（本次**无数据风险**，由 `rehearse.sh` Part 3 实地证明 —— 见 §4③）。

### ③`rehearse.sh` —— 按既有约定**实地验证 README 的断言**

0004 的 `rehearse.sh`（484 行）用临时 PG 容器跑三个 Part，**逐条验证它 README 里关于
rollback 的三条警告是否属实**。0005 沿用这个形状，三个 Part：

| Part | 验证什么 | 为什么需要 |
|---|---|---|
| 1 | **完整升降级回环**：建库（带默认值）→ 漏填插入**成功**且值为 1 → forward → 漏填插入**必须失败** → 显式给值**成功** → rollback → 漏填插入**又成功** | 这就是本片的全部目的，必须实地跑过而不是推理 |
| 2 | **存量行不受影响**：forward + rollback 前后，已有行的 `schema_version` 逐行不变 | `DROP DEFAULT` 只改元数据 —— 这是断言，要证明 |
| 3 | **rollback 真的无损**：README 会声称「本次 rollback 无数据风险」（与 0004 那两条**有**风险的警告相反）| ⛔ 声称无风险比声称有风险更需要证明 —— 不许写上去就算 |

### ④两道闸门 + 一份指纹（本片最易出错处）

三样东西都记着「`schema_version` 的默认值是 1」：

| 文件:行 | 改成什么 | 新值怎么得到 |
|---|---|---|
| `docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql:60` | `$p6b$1$p6b$` → `$p6b$$p6b$` | 照同表其它无默认值列的写法（已核对第 56–59 行） |
| 同文件 `:21` 的 `schema.sql md5 = 2e4b074d…` | 新 md5 | 对**改完的** `schema.sql` 重算 |
| `backend/tests/fixtures/business_catalog_fingerprint.txt:65`（`training_sets.schema_version=1`）+ `backend/qmt_pilot_db.py:1394` 的 `CANONICAL_BUSINESS_CATALOG_SHA256` | 新指纹原文 + 新 sha256 | **本地 docker 起 `postgres:15.12`**，用改完的 `schema.sql` 建库，取出活目录指纹 |

⛔ **次序约束**：先改 `schema.sql` → 再重算 md5 与指纹。反过来会得到旧值。

⛔ **指纹是三方互钉**（`test_qmt_pilot_db.py:85-90` 的注释）：固件 ↔ 常量 ↔ 活库。
前两方由 `test_business_catalog_fixture_matches_the_constant` 钉；
第三方由真 PG 验收脚本 `verify_pilot_two_phase_create.py` 的第 ㉕ 档钉。
⇒ 重新生成时**三方必须同时对齐**，只改两方会让「host 层所有正常路径在错的期望上通过」。

⚠️ `postgres:15.12` 镜像**已在本机**（633MB），不需联网拉取。
生成过程的**完整命令与完整输出**都要贴进 PR，⛔ 不只贴结论。

### ⑤版本 bump：顶层 `CONTRACT_VERSION` 1.14 → 1.15

A 类 DDL 触发（依据 `0004/forward.sql:3` 的头注释与 m01 §Bump 策略）。活同步点：

| # | 位置 |
|---|---|
| 1 | `backend/qmt_pilot_db.py:827` —— `CONTRACT_VERSION = "1.14"` |
| 2 | `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7` —— 同值（`test_qmt_pilot_db.py:835` 钉两边相等）|
| 3 | `docs/governance/m01-schema-versioning-contract.md` 矩阵顶层 cell |
| 4 | 同文件矩阵 PG 迁移 id cell：`0004_qmt_price_double_and_coverage` → `0005_schema_version_fail_closed` |
| 5 | 同文件新增一条 **bump 记录**（照 2026-07-18 那条的格式：触发条件、变更内容、是否联动 sub-version、iOS 侧有无改动）|
| 6 | `docs/governance/m01-schema-versioning-contract.md:50` 末句的**裸字面量** |
| 7 | `kline_trainer_modules_v1.4.md:2239` 的**指针** |
| ~~8~~ | ~~`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`~~ —— **已核实：不需要改**。该脚本（124 行）只 `grep` 治理文档里有没有那段政策文字，**不断言矩阵 cell 的值、也不断言迁移 id** |

#### ⛔ 第 6、7 项：`1.15` 这个号在仓内**已被赋予语义**，取它会把两处变成假话

这是「**同一事实 N 份副本 ⇒ 改一处漏其余**」的又一例。全仓 `git grep '1\.15'`
（排除 Python `3.11.15` 与 CSS `line-height`）命中 8 处，逐条定性后分三类：

**(a) 必须改 —— 2 处**

| 文件:行 | 现在写的 | 为什么是假话 |
|---|---|---|
| `docs/governance/m01-schema-versioning-contract.md:50` | 同一行前半句带了免责「⛔ 这个数**不是**无条件的」，**但末句是裸字面量**：「`1.14` = 「产物已升第 2 代、App 尚不支持」，**`1.15` = 「App 支持第 2 代」**」 | 前半句说这个数不保证、后半句又拿它当标识写死 —— **该行自己内部矛盾**。本片取 1.15 后末句直接为假 |
| `kline_trainer_modules_v1.4.md:2239` | 「…；**过渡态的权威定义见 `CONTRACT_VERSION 1.14 / 1.15`**）」 | 这是个**指针**。取 1.15 后它指向错的一对 |

**改法**：都改成**关系式**，照 `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md:188`
已经对了的那版（它是 2026-09 P3c 整支最终评审 I2 **订正过**的写法）：

> `1.14` = 「产物已升第 2 代、App 尚不支持」；**切片二落地后的那个号** = 「App 支持第 2 代」

⚠️ `kline_trainer_modules_v1.4.md` 是**冻结契约**，改它要确认闸门不被打破。
**已核实**：`backend/tests/test_frozen_contract_texts.py:113` 的

```python
_TRANSITION_NOTE = "⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地"
```

**不含 `1.15`** ⇒ 只改后面那个指针、保留这段标注，
`test_frozen_contract_version_refs_are_2_with_transition_note` 不会红。

**(b) 已经对了、不用改 —— 1 处**

`…timestamp-semantics-design.md:188` 本来就是关系式写法（见上）。

**(c) ⛔ 明确不改 —— 其余 5 处**

全在 `docs/acceptance/**` 与 `docs/superpowers/plans/**`：那些是**历史记述**
（P3b / P3c 当时的验收清单与计划），记的是「当时推断多半是 1.15」这个事实本身。
⛔ 改它们等于改写当时的事实，而且它们的措辞**本来就带免责**
（如 `p3c-acceptance.md:288` 标题逐字是「多半是 1.15，**但不保证**」）。

⚠️ 这两处副本是**同事会话（prj-kline-trainer-be）提醒后**我才查到的；
本设计初稿的 §4⑤ 只列了「矩阵两个 cell + 一条 bump 记录」，**漏了这两处散文**。

⛔ `docs/governance/m01-*` 属**信任边界文件** ⇒ 除 codex 评审外还需 **CODEOWNERS approve**。

### ⑥NAS runbook 新增一节「应用迁移」

**现状问题**：runbook 用 `schema.sql` 建库（`:434`），而 `schema.sql` 全是
`CREATE TABLE IF NOT EXISTS` ⇒ 对**已存在**的库什么都不做；且 runbook 里
**完全没有「应用 migration」这一步**（`grep -E "forward\.sql|migration"` 零命中）。

⇒ 本片合并后，NAS 上那个在跑的库**仍带着 `DEFAULT 1`**，下次跑 P6b 闸门会报
`FAIL-default-drift`（库里有默认值、闸门文件说没有）。

**新增一节**，放在 P6b 闸门**之前**：

1. 把 `0005/forward.sql` 拷到 NAS；
2. 在容器里执行（`-v ON_ERROR_STOP=1`）；
3. 跑 P6b 闸门确认形状吻合。

附明确警告：**跳过这一步，P6b 会报 `FAIL-default-drift` —— 那不是部署坏了，是迁移没跑。**

### ⑦测试

| 新增 | 钉什么 |
|---|---|
| `backend/tests/test_migrations.py` 加 0005 若干条 | 四件套齐全 · `forward.sql`/`rollback.sql` 都是合法 PostgreSQL（`pglast`）· forward **确实含 `DROP DEFAULT`** · rollback **确实含 `SET DEFAULT 1`** |
| `backend/tests/test_schema.py` 一条 | `schema.sql` 里 `schema_version` 那一行**不含 `DEFAULT`** —— 本片的核心契约，必须有东西钉死 |
| **md5 锚的测试**（本片顺手封的一条漏） | P6b 闸门文件头记的 md5 **等于** `schema.sql` 的实际 md5 |

⚠️ **md5 锚那条漏是本片查出来的**：那个 md5 现在**只活在注释里，没有任何测试钉它**
（`git grep` 该 md5 只命中注释本身一处）⇒ 谁改了 `schema.sql` 却忘记更新闸门文件，
**不会有任何东西变红**。本片恰好要改 `schema.sql`，是封这条漏的自然时机。
（当前 md5 **对得上**，所以这条漏是潜在的、尚未发生。）

每条新测试走 **TDD**：先写、**先看它红**、再实现；完成后做**变异验证**证明它真有判别力。

---

## §5 验收判据

写进非程序员可执行的验收清单（动作 / 期望 / 通过与否，中文）。核心几条：

| # | 动作 | 期望 |
|---|---|---|
| 1 | 跑整套后端测试 | 只有 `passed`，退出码 0 |
| 2 | 跑 `0005/rehearse.sh` | 三个 Part 全部 `[PASS]`，退出码 0。⚠️ **需要本机 Docker 可用**（脚本第一步就检测，不可用会打印 `[FAIL] 未检测到 docker` 并 `exit 1`）——与 0004 的 `rehearse.sh` 同形 |
| 3 | **造一条漏填的 INSERT**（在 rehearsal 的临时库上）| PostgreSQL **报错**，报文含 `violates not-null constraint` 且点名 `schema_version` |
| 4 | **造一条表名来自变量的漏填写入** | **同样被 DB 拒**。⚠️ 这条是本片相对文本守卫的**增量价值**证明：守卫对这一类只能说「判不了」，而 DB **判对了且不需要人介入** |
| 5 | 现有 12 处 `INSERT` 仍能正常写入 | 正向对照，防止改成恒拒 |
| 6 | 改动面文件集 | 与 §4 列出的**恰好相等**（集合等式，多一个少一个都算不通过）|

⛔ 判据 4 的措辞按实测更新过：文本守卫对动态表名报「**判不了**」（不是「看不见」），
本片的增量是「从**判不了**到**判对了**」。

---

## §6 明确不做

- ⛔ **不碰库存那 3 个第 1 代产物**的重建 —— 那是 P4 的事。`DROP DEFAULT` 不碰存量行。
- ⛔ **不动 App 侧** `TrainingSessionCoordinator.swift:1364` 的 `expectedSchemaVersion: 1`
  与 `TRAINING_SET_SCHEMA_VERSION = 1` —— 那是**设计好的过渡态**，属切片二。
- ⛔ **不加 CHECK 约束**（方案 B 已否决）。
- ⛔ 不动 #201 那道文本守卫（两片互不阻塞）。

---

## §7 已知局限

- 本片让**漏填**失败，但**不校验值对不对**：写 `schema_version = 99` 仍会被接受。
  若要钉死取值范围，那是另一条判据（需要 CHECK，且要先处理存量 1/2 两代共存）。
- NAS 上的迁移是**人工步骤**（runbook 新增那一节），没有自动化编排 ——
  本仓目前没有迁移编排器，`0004` 也是同样形态。
- ⛔ **合并本片 ≠ 手机能用了**：库存产物仍是第 1 代、App 读取端仍钉在第 1 代。

### ⚠️ 本片查出、但**明确不在范围内**的一条漏

**m01 矩阵里，只有【训练组那一行】被钉着；PG 迁移 id 与顶层 CONTRACT_VERSION 两个 cell 无人钉。**

⚠️ **这是对本设计初稿的订正** —— 初稿写的是「矩阵的 cell 值**没有任何**测试钉着」，
那句**过头了**。实际核实：

| cell | 钉它的东西 |
|---|---|
| 训练组 SQLite `PRAGMA user_version` | ✅ `backend/tests/test_frozen_contract_texts.py:173` 的 `test_m01_matrix_training_set_row_matches_backend_ddl` —— 把矩阵那一行钉到 `training_set_schema_v1.sql` 的 `PRAGMA user_version` 上，**两个独立来源互钉，任一边单独动就红** |
| PG 迁移 id | ⛔ 无人钉 |
| 顶层 `CONTRACT_VERSION` | ⛔ 无人钉 |

`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`（124 行）只检查治理文档里
**有没有那段政策文字**，不比对任何 cell 的值。

⭐ 那条已有的守卫**写法值得照抄**：它的 docstring 记着判据的来由 ——
「doc=1 / code=2 的漂移**真的发生过**：#183 把 `training_set_schema_v1.sql` 的
`PRAGMA user_version` 改成 2，而 m01 那行没人动，且当时**没有任何测试在读它**
⇒ 漂移安安静静地存在了两周」；并明写「判据**不是**『等于字面量 2』—— 那样下一次
bump 时会跟 DDL 一起说谎（两边都改错也全绿）」。

⚠️ **TS1-R1 不碰** `training_set_schema_v1.sql`（本片改的是 PostgreSQL 的 `schema.sql`）
⇒ 那条守卫不受本片影响。

后果已经发生过**三次** —— m01 文档自己记着：
2026-06-22 那条写「cell 此前 stale 为 `1.5`」、
2026-07-18 那条写「顶层 cell 此前 stale 为 `1.7`，实际代码已被**三个** PR 连续 bump 至 `1.11` 而未同步本矩阵」。

⛔ **不在本片范围**：给矩阵加「值必须与代码常量一致」的测试属**治理/工具变更**，
按仓库规则要走自己的 `brainstorming → writing-plans → codex 评审`，且 m01 是信任边界文件。
⇒ 记为 backlog，建议单独立项。本片只保证**自己这次 bump 六个点都改对**（§5 判据 6 用集合等式钉住改动面）。
