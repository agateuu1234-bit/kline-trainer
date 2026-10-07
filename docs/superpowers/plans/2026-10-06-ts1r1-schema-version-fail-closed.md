# TS1-R1：`schema_version` 去掉 `DEFAULT 1` 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `training_sets.schema_version` 的 `DEFAULT 1` 去掉（保留 `NOT NULL`），使任何漏填该列的写入在 PostgreSQL 层当场失败，而不是被静默标成第 1 代产物。

**Architecture:** 一条 DDL 改动（`schema.sql` 去默认值 + 新增列注释），配一套版本化迁移 `0005_schema_version_fail_closed`（forward / rollback / README / rehearse.sh）。因为 `schema.sql` 的字节与「它建出来的库长什么样」被四处快照钉着（P6b 闸门的 md5 与默认值格、模块常量 `CANONICAL_SCHEMA_SHA256`、活目录指纹固件 + 其 sha256 常量），所以改动面的大头是**同步这些快照**，且**必须在 `schema.sql` 定稿之后**才能算。最后按 m01 治理契约 bump 顶层 `CONTRACT_VERSION` 1.14 → 1.15（11 个同步点，Python 1 + Swift 4 + 文档 5 + 迁移 id cell 1）。

**Tech Stack:** PostgreSQL 15.12（Docker 镜像 `postgres:15.12`，已在本机）· Python 3.11 + pytest + `pglast`（PostgreSQL 官方语法的 Python 绑定，静态解析 SQL，不需要起数据库）· bash（`rehearse.sh` 演练脚本）· Swift + XCTest / swift-testing（`ios/Contracts`）

**Spec:** `docs/superpowers/specs/2026-10-06-ts1r1-schema-version-fail-closed-design.md`（已通过 codex 对抗性评审，第 4 轮 `approve`）

---

## 名词速查（给非技术背景读者）

| 词 | 大白话 |
|---|---|
| `DEFAULT 1` | 「这一格不填就自动填 1」。去掉它，不填就报错 |
| `NOT NULL` | 「这一格不许空着」。本片**保留**它 —— 正因为保留，去掉默认值之后漏填才会报错 |
| 迁移（migration） | 一张**已经存在**的数据库怎么从旧形状改到新形状的脚本。`forward.sql` 往前改，`rollback.sql` 改回去 |
| 哈希 / md5 / sha256 | 给一份文件算出来的「指纹字符串」。文件改一个字节，指纹就全变 |
| 活目录指纹 | 不是对文件算指纹，而是**问数据库自己**「你现在有哪些表、哪些列、哪些默认值」，把答案拼成一长串文本再算指纹 |
| `pglast` | 一个 Python 库，用 PostgreSQL **官方的语法解析器**读 SQL 文件，所以不用真起一个数据库也能判断 SQL 合不合法、写了什么 |
| 变异验证 | 故意把代码改坏一下，看测试是不是真的变红。如果改坏了测试还绿，说明这个测试根本没在测它号称测的东西 |

---

## Global Constraints

逐条抄自 spec，每个 Task 的要求都隐含包含本节。

1. **`DROP DEFAULT` 只改元数据，不碰存量行。** 库存那 3 个第 1 代产物不在本片范围（那是 P4 的事）。
2. **⛔ 不加 CHECK 约束**（spec §6，方案 B 已否决）。本片让**漏填**失败，**不校验值对不对** —— 写 `schema_version = 99` 仍会被接受（spec §7 已知局限）。
3. **⛔ 不动 App 侧** `TrainingSessionCoordinator.swift:1364` 的 `expectedSchemaVersion: 1` 与 `DownloadAcceptanceRunner.swift` 的 `TRAINING_SET_SCHEMA_VERSION = 1` —— 那是设计好的过渡态，属切片二。
4. **⛔ 不给 m01 矩阵加一致性测试。** spec §7 明确判定这属治理/工具变更，要走自己的 `brainstorming → writing-plans → codex 评审`，记为 backlog。本片只保证自己这次 bump 的 11 个点都改对。
5. **⛔ 不动任何一道 `INSERT` 文本守卫** —— 但要分清是哪一道：
   · **已合并**的 `backend/tests/test_insert_schema_version_guard.py`（#194，在 main 里、今天就在跑）
     扫 `backend/` · `docs/runbooks/` · `.github/workflows/` 三个目录下的
     `.py/.sql/.sh/.md/.yml/.yaml`（以及 `Dockerfile*`），**凡 `INSERT INTO training_sets`
     的列清单里没有 `schema_version` 就报红**。它只豁免**自己一个文件**
     （`_iter_files` 第 219 行 `if q.resolve() != _SELF`），**没有**通用豁免机制。
     ⇒ 本片新建的 `0005/rehearse.sh` 落在 `backend/` 下、后缀 `.sh`，**在它视野里**。
   · **未合并**的 PR #201 是给这道守卫加宿主语言解码层的加固片，本片同样不碰。

5b. **⛔⛔ 「漏填」在演练脚本里必须写成「列清单含 `schema_version`、值写 `DEFAULT`」，
    不许写成「把该列从列清单里省掉」。**

    这是 **codex 第 1 轮对 plan 的 [high] finding**，已实测坐实。在真路径
    `backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh` 上做的两个对照：

    | 写法 | 已合并守卫的判定 |
    |---|---|
    | 省略列（本计划初稿的写法）| **红** —— 报 `…/0005_schema_version_fail_closed/rehearse.sh:3  列清单=stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash` |
    | 列清单含 `schema_version`、值写 `DEFAULT` | **绿** —— 解析到 **4 条**语句，`missing=0 / positional=0 / unknown=0` |

    ⇒ 初稿若照原样落盘，`test_every_executable_insert_carries_schema_version`
    **必然失败**，Global Constraint 15 的 1729 全绿**达不到**。

    **为什么 `DEFAULT` 是等价的**（PostgreSQL 15.12 本机实测，不是查文档）：
    `VALUES (…, DEFAULT, …)` 的含义是「用该列的默认值；该列没有默认值时用 NULL」——
    与**把该列从列清单里省掉**完全同义。三个阶段逐一对照过：

    | 阶段 | 省略列 | 值写 `DEFAULT` |
    |---|---|---|
    | 有 `DEFAULT 1` | 写入成功，值 = 1 | 写入成功，值 = 1 |
    | `DROP DEFAULT` 之后 | `ERROR: null value in column "schema_version" … violates not-null constraint` | **同一条报错** |
    | `SET DEFAULT 1` 回滚后 | 写入成功，值 = 1 | 写入成功，值 = 1 |

    ⛔ **不采纳**「把表名放进变量再拼出来」那条路（codex 的建议之一）：
    那正是 PR #201 存在的理由 —— 文本守卫对动态表名只能报「判不了」。
    拿自己标出来的盲点当解法，等于把一个**已知洞**写进仓库当常规做法。
    `DEFAULT` 这条路相反：表名是字面量、列清单是字面量、不拆不拼不动态，
    守卫**看得见全部内容并判它合规**。

    ⚠️ **这条写法顺带暴露了那道守卫的一个真实缺口**，必须说出来而不是藏着：
    守卫**只看列清单、不看值** ⇒ `schema_version` 配 `DEFAULT` 它判合规，
    而语义上那是「让数据库决定」。本片之后该列**没有默认值** ⇒ 这么写会 fail closed，
    所以对 `training_sets` 无害 —— 换句话说**是本片的 DDL 兜住了守卫的这个洞**
    （正是本片的论点：把判据从宿主文本搬到数据库）。
    ⛔ 给守卫补「值不许是 `DEFAULT`」属 guard-hardening 的范围，**记为 backlog，本片不做**。
6. **次序约束（最易出错处）**：`schema.sql` **必须先定稿**，然后才能算这三样 —— P6b 的 md5、`CANONICAL_SCHEMA_SHA256`、活目录指纹。反过来全部拿到旧值。

6b. **⛔ 任何往 `training_sets` 塞样本的地方都要满足 `ck_lease_state_invariant`**：

    | `status` | `lease_id` / `lease_expires_at` / `reserved_at` |
    |---|---|
    | `'unsent'`（列默认值）| **三者全为 NULL** |
    | `'reserved'` / `'sent'` | **三者全非 NULL** |

    ⇒ 不写 `status` 的样本自动合规（取默认 `'unsent'`，三列保持 NULL）；
    **一旦显式写 `'sent'` 或 `'reserved'`，就必须把三列一起给值**。
    实测违反时报 `new row for relation "training_sets" violates check constraint
    "ck_lease_state_invariant"`，psql 退出码 **3** ⇒ `ON_ERROR_STOP=1` + `set -e`
    会让演练脚本当场中止。
    另外 `ck_content_hash_crc32_lowercase` 要求 `content_hash` 匹配 `^[0-9a-f]{8}$`
    （8 位小写十六进制），`ck_status_enum` 限定 `status IN ('unsent','reserved','sent')`。
7. **指纹是三方互钉**：固件（`backend/tests/fixtures/business_catalog_fingerprint.txt`）↔ 常量（`CANONICAL_BUSINESS_CATALOG_SHA256`）↔ 活库。重新生成时**三方必须同时对齐**，只改两方会让「所有正常路径在错的期望上通过」。
8. **顶层 `CONTRACT_VERSION` 1.14 → 1.15**，11 个同步点，一个不漏（Task 5 逐条列出）。
9. **扫描范围**：本片任何「全仓有/没有 X」「共 N 处」类断言，一律按 `git grep … -- backend ios scripts .github docs` 扫。⛔ 只扫 `backend/`（Python）会漏 Swift 侧 —— spec §4⑤ 的第 8–11 项就是这么漏掉再被 codex 挖出来的。
10. **每条新测试走 TDD**：先写、**先看它红**、再实现；完成后做**变异验证**证明它真有判别力。
11. **`docs/governance/m01-*` 属信任边界文件** ⇒ 除 codex 评审外还需 **CODEOWNERS approve**。
12. **⛔ push 与开 PR 由 user 在终端执行**，Claude 不做（仓内守卫会拦）。
13. 全程简体中文；验收清单必须非程序员可执行（动作 / 期望 / 通过与否）。

14. **⛔ Python 解释器必须显式指定 —— 本 worktree 里没有虚拟环境。** 已实测：本 worktree 下
    `python` 这个命令**根本不存在**，`python3` 存在但**没装 `pglast`**（本片全部新测试都要它）。
    `pglast` 与 `pytest` 装在**主检出**的 `.venv` 里。每开一个新终端，**先执行这两行**：

    ```bash
    export PY="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)/.venv/bin/python"
    "$PY" -c "import pglast, pytest; print('解释器 OK: pglast', pglast.__version__, '/ pytest', pytest.__version__)"
    ```

    期望第二行打印 `解释器 OK: pglast v7.13 / pytest 8.4.2`。
    ⚠️ `git rev-parse --git-common-dir` 在 worktree 里返回**主检出**的 `.git` 路径，所以上面这行
    在任何 worktree 里都算得对（已实测）。本计划此后所有 Python 命令一律写 `"$PY"`，
    ⛔ 不许写裸 `python` / `python3`。
    ⚠️ 例外：`rehearse.sh` 的 Part 4 里那两处 `python3` 是**故意**用裸解释器的 ——
    它只 `import qmt_pilot_db`，而那个模块的模块级 import 只有 `hashlib` / `re` / `sys`
    三个标准库（已实测裸 `python3` 能 import 成功）⇒ 让演练脚本不依赖虚拟环境。

15. **实施前基线（已实测，2026-10-06 本 worktree）**：整套后端 **`1720 passed`**，
    0 failed，耗时约 4 分钟。本片新增 **9 条**测试（Task 1 的 3 条 + Task 2 的 6 条；
    Task 3 只改写已有的那条守卫，不增条数）⇒ **完工后应为 `1729 passed`**。
    ⚠️ 若最终数不是 1729，**先搞清差额来自哪里**，⛔ 不许笼统地说「全绿」就过。

---

## File Structure

### 改（后端与快照，7 个文件）

| 文件 | 本片让它负责什么 |
|---|---|
| `backend/sql/schema.sql` | 唯一的 DDL 真源。去 `DEFAULT 1` + 加列注释。**定稿后才能算下面三样哈希** |
| `backend/qmt_pilot_db.py` | 两个常量：`CANONICAL_SCHEMA_SHA256`（:1279）、`CANONICAL_BUSINESS_CATALOG_SHA256`（:1394）；加 `CONTRACT_VERSION`（:827） |
| `backend/tests/fixtures/business_catalog_fingerprint.txt` | 活目录指纹原文快照。删掉 `training_sets.schema_version=1` 那一行（第 65 行） |
| `docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql` | P6b 硬门的期望形状快照。改默认值格（:60）+ 头注释里的 md5（:21） |
| `docs/runbooks/2026-08-24-qmt-nas-deployment.md` | NAS 部署 runbook。在 P6b 之前新增一节「应用迁移」 |
| `docs/governance/m01-schema-versioning-contract.md` | 版本契约矩阵 + bump 记录（信任边界文件） |
| `kline_trainer_modules_v1.4.md` | 模块文档里指向过渡态的那条指针（:2239） |

> 这 7 个里前 4 个是代码与快照，后 3 个是文档（runbook / 治理契约 / 模块文档）。
> 本片的**完整**改动面（含 Swift 4 个、测试 2 个、新建 5 个）的集合等式见 Task 7 Step 4。

### 改（Swift，4 个文件）

| 文件 | 改什么 |
|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | `:7` 的 `CONTRACT_VERSION` |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift` | `:8` 的断言 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift` | `:1260` 断言 + `:1238` **测试名** |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift` | `:52` 断言（⛔ `:61/:74/:79` 是人造反例样本，**不改**） |

### 改（测试，2 个文件）

| 文件 | 加什么 |
|---|---|
| `backend/tests/test_schema.py` | `schema_version` 无默认值 / 仍 `NOT NULL` / P6b 快照 md5 等于实际 md5 |
| `backend/tests/test_migrations.py` | 0005 四件套齐全、合法 PostgreSQL、含 `DROP DEFAULT` / `SET DEFAULT 1`、两份 COMMENT 逐字一致、CJK 大括号守卫扩到 0005 |

### 建（5 个文件）

| 文件 | 责任 |
|---|---|
| `backend/sql/migrations/0005_schema_version_fail_closed/forward.sql` | 往前迁移：`DROP DEFAULT` + 列注释 |
| `backend/sql/migrations/0005_schema_version_fail_closed/rollback.sql` | 迁回去：`SET DEFAULT 1` + 注释置空 |
| `backend/sql/migrations/0005_schema_version_fail_closed/README.md` | 一项变更的说明 + rollback 风险评估（本次无数据风险，由 rehearse.sh Part 3 实地证明） |
| `backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh` | Docker 真库演练，4 个 Part |
| `docs/acceptance/2026-10-06-ts1r1-schema-version-fail-closed.md` | 非程序员可执行的验收清单 |

---

## ⚠️ 对 spec 的声明性偏离（两处，请评审者优先看）

### 偏离一：`rehearse.sh` 做四个 Part + 一段前置探针（spec §4③ 写三个 Part）

spec §4③ 写 `rehearse.sh` **三个 Part**。本计划实现**四个 + 一段前置探针**。两项多出来的都不是新需求：

**Part 4「活目录指纹三方对齐」**是 spec §4④ 那条要求（「本地 docker 起 `postgres:15.12`，用改完的 `schema.sql` 建库，取出活目录指纹」+「三方必须同时对齐」）的**执行机制**。

为什么放进 `rehearse.sh` 而不是另写一个脚本：

1. 这一步需要的东西与 Part 1–3 **完全相同**（docker + `postgres:15.12` + 仓库里的 `schema.sql`），另起一个脚本等于把同一套容器样板抄第二遍 —— 本仓记过「同一事实 N 份副本 ⇒ 每轮修复造下一个回声」。
2. 指纹的第三条腿（**常量 ↔ 活库**）目前只活在 `verify_pilot_two_phase_create.py` 的 ㉕ 档里，而那个脚本需要真 PG 的 DSN + `asyncpg`，**本片不会去跑它**。放进 `rehearse.sh` 意味着这条腿在本片**真的被执行过一次**，而不是写在文档里。
3. ⛔ **不许用「一条命令贴输出」代替脚本** —— 本仓记过「命令超一行必被截断 ⇒ 落脚本」。

⚠️ 它同时是**指纹的生成手段**：Part 4 在固件还是旧值时会**红并打印活库实际值**（与 ㉕ 档同样的设计），Task 4 就是拿这个红色输出里的值去更新固件与常量，再重跑看它变绿。这个红→绿同时**证明了 Part 4 有判别力**（本仓记过「报 0 违反必须先证明它能报非 0」）。

**Part 1 的前置探针**（克隆表上比对「省略该列」与「值写 `DEFAULT`」）是 Global Constraint **5b**
那条设计决定的**自证**：整个 Part 1 的说服力都压在「`DEFAULT` ≡ 漏填」这一个命题上，
而本仓的成文教训是「这类命题必须实测，不能读文档下结论」。探针把它变成每次演练都重新测一遍。

### 偏离二：演练里的「漏填」写成 `DEFAULT`，而不是真的省掉该列

见 Global Constraint **5b** 的完整论证与实测对照表。一句话：spec 没有预见到
**已合并**的文本守卫（#194）会扫到 `backend/` 下新建的 `.sh`，而它要求每条
`INSERT INTO training_sets` 的列清单都含 `schema_version`。
这是 codex 对本计划第 1 轮的 [high] finding，已实测坐实（省略列 → 守卫红并点名该文件）。

⛔ codex 给的建议是「用受控的表名变量构造」，本计划**不采纳** —— 那正是 PR #201
要封的那个盲点（文本守卫对动态表名只能报「判不了」）。把一个**已知洞**写进仓库当常规做法，
代价比收益大。`DEFAULT` 这条路的表名与列清单都是字面量，守卫看得见全部内容并判它合规。

---

## Task 1：`schema.sql` 去默认值 + 三样字节级后果

**为什么这几件事必须在同一个 Task 里：** `schema.sql` 一改，`test_canonical_schema_hashes_match_the_repo_files` 立刻变红（它钉着 `CANONICAL_SCHEMA_SHA256` 与仓库文件一致）。把常量更新拆到后面的 Task，会让中间每一个 Task 都在一棵已知红的树上干活，没人能分辨「这个红是我弄的还是上一个 Task 留的」。P6b 的两处同理：都只依赖 `schema.sql` 的**字节**，不需要 Docker。

**Files:**
- Modify: `backend/sql/schema.sql:75`（加列注释在文件末尾 `COMMENT ON` 段）
- Modify: `backend/qmt_pilot_db.py:1279`（`CANONICAL_SCHEMA_SHA256`）
- Modify: `docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql:21`（md5 注释）、`:60`（默认值格）
- Test: `backend/tests/test_schema.py`（加 3 条）

**Interfaces:**
- Consumes: 无（本片第一个 Task）
- Produces: 定稿的 `backend/sql/schema.sql`。后续 Task 2/3/4 都读它；Task 4 的指纹必须从**这一版**建库才算得对。

- [ ] **Step 1: 写第一条会红的测试 —— `schema_version` 不许有默认值**

加到 `backend/tests/test_schema.py` 末尾。遍历方式照抄同文件 `test_training_sets_content_hash_char8_not_null`（第 45–70 行）的写法。

```python
def test_training_sets_schema_version_has_no_default():
    """TS1-R1 的核心契约：`schema_version` **刻意不设默认值**。

    为什么必须有东西钉死它：有 `DEFAULT 1` 时，漏填该列的 INSERT 会被 PostgreSQL
    静默补成 1 —— 第 2 代产物被标成第 1 代，而写入方毫无察觉。去掉默认值 + 保留
    NOT NULL ⇒ 漏填当场报 `violates not-null constraint`（fail-closed）。
    这条测试防的是「以后有人为了方便又把默认值加回来」。
    """
    stmts = _parse_schema()
    training_sets = next(
        s.stmt
        for s in stmts
        if isinstance(s.stmt, CreateStmt)
        and s.stmt.relation.relname == "training_sets"
    )
    col = next(
        e for e in training_sets.tableElts
        if hasattr(e, "colname") and e.colname == "schema_version"
    )
    defaults = [
        c for c in (col.constraints or ())
        if getattr(c, "contype", None) == pglast.enums.ConstrType.CONSTR_DEFAULT
    ]
    assert not defaults, (
        "training_sets.schema_version 不得有 DEFAULT —— 漏填必须当场失败，"
        f"不能被静默标成第 1 代；实际解析到 {len(defaults)} 个默认值约束")


def test_training_sets_schema_version_is_still_not_null():
    """⚠️ 与上一条是**一对**，缺一不可。

    去掉 DEFAULT 的 fail-closed 效果**完全依赖** NOT NULL 还在：
    只去默认值、同时把 NOT NULL 也去掉，漏填会安静地写成 NULL —— 那比写成 1 更糟
    （下游 reader 拿到 NULL 不是「错的代号」而是「没有代号」）。
    这条测试把「两个条件同时成立」钉住，而不是只钉一半。
    """
    stmts = _parse_schema()
    training_sets = next(
        s.stmt
        for s in stmts
        if isinstance(s.stmt, CreateStmt)
        and s.stmt.relation.relname == "training_sets"
    )
    col = next(
        e for e in training_sets.tableElts
        if hasattr(e, "colname") and e.colname == "schema_version"
    )
    not_null = any(
        getattr(c, "contype", None) == pglast.enums.ConstrType.CONSTR_NOTNULL
        for c in (col.constraints or ())
    )
    assert not_null, "schema_version 必须保留 NOT NULL，否则漏填会写成 NULL"
```

- [ ] **Step 2: 跑这两条，确认第一条红、第二条绿**

```bash
cd backend && "$PY" -m pytest tests/test_schema.py -k schema_version -v
```

期望：
- `test_training_sets_schema_version_has_no_default` **FAIL**，报文含 `实际解析到 1 个默认值约束`
- `test_training_sets_schema_version_is_still_not_null` **PASS**（`NOT NULL` 本来就在）

⚠️ 第二条立刻绿是**预期的**：它钉的是一个当前已经正确、但没人看着的性质。它的红→绿在 Step 7 的变异验证里证明。

- [ ] **Step 3: 写第三条测试 —— P6b 快照里记的 md5 等于 `schema.sql` 的实际 md5**

同样加到 `backend/tests/test_schema.py` 末尾。

```python
def test_p6b_snapshot_records_the_actual_schema_md5():
    """P6b 硬门文件头注释里记着 `schema.sql md5 = …`，本测试钉它与实际 md5 相等。

    ⚠️ 这条漏是 TS1-R1 查出来的：在本片之前，那个 md5 **只活在注释里，没有任何
    测试钉它**（`git grep` 该 md5 只命中注释本身一处）⇒ 谁改了 schema.sql 却忘记
    重新生成 P6b 快照，**不会有任何东西变红**，而症状要等到 NAS 部署跑 P6b
    那一刻才出现（而且长得像「部署坏了」而不是「快照过期」）。
    本片恰好要改 schema.sql，是封这条漏的自然时机。
    """
    import hashlib
    actual = hashlib.md5(SCHEMA_PATH.read_bytes()).hexdigest()
    gate = (Path(__file__).parent.parent.parent / "docs" / "runbooks"
            / "2026-08-24-qmt-nas-p6b-schema-shape-check.sql")
    text = gate.read_text(encoding="utf-8")
    assert f"schema.sql md5 = {actual}" in text, (
        f"P6b 快照文件头注释里记的 md5 与 schema.sql 实际 md5 不符。\n"
        f"  实际 md5：{actual}\n"
        f"  改了 schema.sql 就必须重新生成 {gate.name} 并同步这一行。")
```

- [ ] **Step 4: 跑它，确认现在是绿的**

```bash
cd backend && "$PY" -m pytest tests/test_schema.py::test_p6b_snapshot_records_the_actual_schema_md5 -v
```

期望：**PASS**（当前两边 md5 都是 `2e4b074d5a4607d53a00c849855434d5`，对得上）。

⚠️ 这条的红→绿**就在下一步**：改完 `schema.sql`，它会立刻变红，Step 6 更新注释后再变绿。这不是「测试写完就通过所以没验证」—— 这是一条**防漂移钉**，它的判别力由「schema.sql 一改就红」直接证明。

- [ ] **Step 5: 改 `schema.sql`（本片的核心一行 + 一条列注释）**

把第 75 行：

```sql
    schema_version INTEGER NOT NULL DEFAULT 1,
```

改成：

```sql
    schema_version INTEGER NOT NULL,
```

并在文件末尾 `COMMENT ON COLUMN training_sets.status` 那条**之后**、`COMMIT;` 之前，加一条列注释（照同处两条已有注释的两行式写法）：

```sql
COMMENT ON COLUMN training_sets.schema_version
  IS '产物代号。⛔ 刻意不设默认值：漏填必须当场失败，不能被静默标成第 1 代。';
```

⚠️ **这段注释文字要与 Task 2 的 `forward.sql` 里那条逐字一致** —— 两份副本不一致时，「从 `schema.sql` 新建的库」与「跑过迁移的库」注释会不同，而注释不被任何闸门覆盖 ⇒ 无人发现。Task 2 会加一条测试把「逐字一致」钉住。

- [ ] **Step 6: 跑测试看三条的新状态，再算两个新哈希**

```bash
cd backend && "$PY" -m pytest tests/test_schema.py -v
```

期望：
- `test_training_sets_schema_version_has_no_default` **由红转绿**
- `test_training_sets_schema_version_is_still_not_null` 仍绿
- `test_p6b_snapshot_records_the_actual_schema_md5` **由绿转红**（md5 变了）← 这就是它的红

再跑一次整套后端，确认此刻的红**恰好只有两处**（而不是一片）：

```bash
cd backend && "$PY" -m pytest -q 2>&1 | tail -20
```

期望：`test_p6b_snapshot_records_the_actual_schema_md5` 与 `test_canonical_schema_hashes_match_the_repo_files` 两条 FAIL，其余全 passed。⚠️ 若红的不止这两条，**停下来**先搞清第三条红是什么，再往下。

算新值：

```bash
cd "$(git rev-parse --show-toplevel)" && echo "新 md5    = $(md5 -q backend/sql/schema.sql)" && echo "新 sha256 = $(shasum -a 256 backend/sql/schema.sql | cut -d' ' -f1)"
```

- [ ] **Step 7: 把两个新值与 P6b 的默认值格一起改掉**

三处改动，**都用上一步真正打印出来的值**，⛔ 不许凭记忆或推算填：

1. `docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql:21`：
   `--    schema.sql md5 = 2e4b074d5a4607d53a00c849855434d5` → 换成新 md5
2. 同文件 `:60`：
   `('training_sets', 'schema_version', $p6b$integer$p6b$, $p6b$NOT NULL$p6b$, $p6b$1$p6b$),`
   → `('training_sets', 'schema_version', $p6b$integer$p6b$, $p6b$NOT NULL$p6b$, $p6b$$p6b$),`
   （照同表其它无默认值列的写法，已核对第 56–59 行：无默认值就写成一对空的 `$p6b$$p6b$`）
3. `backend/qmt_pilot_db.py:1279` 的 `CANONICAL_SCHEMA_SHA256` → 换成新 sha256

- [ ] **Step 8: 跑整套后端，确认全绿**

```bash
cd backend && "$PY" -m pytest -q 2>&1 | tail -5
```

期望：`passed`，无 `failed`、无 `error`。

- [ ] **Step 9: 提交**

```bash
cd "$(git rev-parse --show-toplevel)"
git add backend/sql/schema.sql backend/qmt_pilot_db.py \
        docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql \
        backend/tests/test_schema.py
git commit -m "feat(ts1r1): schema_version 去掉 DEFAULT 1 + 同步两处字节级快照

- schema.sql: 去 DEFAULT，保留 NOT NULL，加列注释说明「刻意不设默认值」
- P6b 快照: 默认值格改空 + 头注释 md5 重算
- CANONICAL_SCHEMA_SHA256 重算（否则 create_pilot_database 会抛 schema_not_canonical）
- 新增 3 条测试: 无默认值 / 仍 NOT NULL / P6b 的 md5 锚（这条锚此前无人钉）"
```

⚠️ **提交必须排在变异验证之前**：下一步要用 `git checkout --` 把变异还原，
而 `git checkout --` 只能还原到**最近一次提交**。若先变异后提交，还原会把
Step 5/7 的真实改动一起丢掉（本仓记过「复原别用 `git checkout <file>`」那一类事故）。

- [ ] **Step 10: 变异验证 —— 证明这三条测试真有判别力**

逐条把判据改坏，看它是不是真红。⛔ **每次只改一处，改完立刻还原。**
本步的三个文件**都已提交**（上一步），所以 `git checkout --` 在这里是安全且正确的。

```bash
cd "$(git rev-parse --show-toplevel)"

# 变异 A：把 DEFAULT 1 加回去 → 期望 test_..._has_no_default 变红
sed -i '' 's/    schema_version INTEGER NOT NULL,/    schema_version INTEGER NOT NULL DEFAULT 1,/' backend/sql/schema.sql
(cd backend && "$PY" -m pytest tests/test_schema.py::test_training_sets_schema_version_has_no_default -q 2>&1 | tail -3)
git checkout -- backend/sql/schema.sql

# 变异 B：把 NOT NULL 去掉 → 期望 test_..._is_still_not_null 变红
sed -i '' 's/    schema_version INTEGER NOT NULL,/    schema_version INTEGER,/' backend/sql/schema.sql
(cd backend && "$PY" -m pytest tests/test_schema.py::test_training_sets_schema_version_is_still_not_null -q 2>&1 | tail -3)
git checkout -- backend/sql/schema.sql

# 变异 C：把 P6b 注释里的 md5 改成一个错值 → 期望 md5 那条变红
sed -i '' 's/^--    schema.sql md5 = .*/--    schema.sql md5 = 00000000000000000000000000000000/' docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql
(cd backend && "$PY" -m pytest tests/test_schema.py::test_p6b_snapshot_records_the_actual_schema_md5 -q 2>&1 | tail -3)
git checkout -- docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql
```

期望：A、B、C 三次各打印 `1 failed`。

变异全部确认后，工作区必须回到干净：

```bash
git status --short
```

期望：**无输出**（证明三次 `git checkout --` 都生效了）。

---

## Task 2：迁移 `0005_schema_version_fail_closed` 的 forward / rollback / README

**为什么与 Task 1 分开：** Task 1 管「新建的库长什么样」，本 Task 管「**已经存在**的库怎么改过去」。两者可以各自被独立否决 —— 评审者可能认可 `schema.sql` 的改法却不认可迁移的写法（例如 rollback 要不要加破坏性守卫）。

**Files:**
- Create: `backend/sql/migrations/0005_schema_version_fail_closed/forward.sql`
- Create: `backend/sql/migrations/0005_schema_version_fail_closed/rollback.sql`
- Create: `backend/sql/migrations/0005_schema_version_fail_closed/README.md`
- Test: `backend/tests/test_migrations.py`（加 6 条）

**Interfaces:**
- Consumes: Task 1 定稿的 `backend/sql/schema.sql` —— 特别是那条列注释的**原文**，forward.sql 里必须逐字相同
- Produces: 迁移目录 `0005_schema_version_fail_closed/`。Task 3 的 `rehearse.sh` 放进同一目录并执行这两个 `.sql`；Task 5 把这个目录名写进 m01 矩阵的「PG 迁移 id」cell

- [ ] **Step 1: 先写会红的测试（6 条）**

加到 `backend/tests/test_migrations.py`。先在文件头部常量区（第 14 行 `MIG_0004 = …` 之后）加一行：

```python
MIG_0005 = MIGRATIONS_DIR / "0005_schema_version_fail_closed"
```

再把这 6 条加到文件末尾：

```python
def test_migration_0005_has_forward_and_rollback():
    """m01 §Migration Rollback：每个 migration 必须是 forward+rollback 成对。"""
    assert (MIG_0005 / "forward.sql").is_file(), "缺 forward.sql"
    assert (MIG_0005 / "rollback.sql").is_file(), "缺 rollback.sql"


def test_migration_0005_forward_is_valid_postgres():
    sql = (MIG_0005 / "forward.sql").read_text(encoding="utf-8")
    assert len(pglast.parse_sql(sql)) > 0


def test_migration_0005_rollback_is_valid_postgres():
    sql = (MIG_0005 / "rollback.sql").read_text(encoding="utf-8")
    assert len(pglast.parse_sql(sql)) > 0


def test_migration_0005_forward_drops_the_default():
    """本片的全部目的。判据钉到**具体那一列** —— 只判「含 DROP DEFAULT」
    会被「对别的列 DROP DEFAULT」喂饱。"""
    sql = _sql_normalized(MIG_0005 / "forward.sql")
    assert "alter table training_sets alter column schema_version drop default" in sql, \
        "forward.sql 没有对 training_sets.schema_version 执行 DROP DEFAULT"


def test_migration_0005_rollback_restores_the_default():
    """回滚必须真的把默认值装回去（否则回滚后的库与回滚前不是同一个形状，
    而 P6b 闸门只认一种形状 ⇒ 回滚完闸门照样红）。"""
    sql = _sql_normalized(MIG_0005 / "rollback.sql")
    assert "alter table training_sets alter column schema_version set default 1" in sql, \
        "rollback.sql 没有把 DEFAULT 1 装回去"
    assert "comment on column training_sets.schema_version is null" in sql, \
        "rollback.sql 没有把列注释置空 —— 回滚后库里会留下一条说谎的注释"


def test_migration_0005_comment_text_is_byte_identical_to_schema_sql():
    """⚠️ 同一句注释有**两份副本**：`schema.sql`（新建库走这条）与
    `0005/forward.sql`（既有库走这条）。两份不一致时，两种来源的库注释不同，
    而**注释不被任何闸门覆盖**（P6b 查列/约束/索引，不查 comment）⇒ 无人发现。
    本仓记过「同一事实 N 份副本 ⇒ 每轮修复造下一个回声」，所以这里直接钉逐字相等。

    判据取**注释字符串字面量本身**（单引号之间那段），不比对整条语句 ——
    两份文件的换行与缩进排布可以不同，说谎的是文字内容。
    """
    import re
    pat = re.compile(
        r"COMMENT\s+ON\s+COLUMN\s+training_sets\.schema_version\s+IS\s+'([^']*)'",
        re.IGNORECASE)
    schema_text = (MIGRATIONS_DIR.parent / "schema.sql").read_text(encoding="utf-8")
    fwd_text = (MIG_0005 / "forward.sql").read_text(encoding="utf-8")
    m_schema = pat.search(schema_text)
    m_fwd = pat.search(fwd_text)
    assert m_schema, "schema.sql 里找不到 schema_version 的列注释"
    assert m_fwd, "0005/forward.sql 里找不到 schema_version 的列注释"
    assert m_schema.group(1) == m_fwd.group(1), (
        "两份列注释文字不一致 —— 从 schema.sql 新建的库与跑过迁移的库会带不同注释，"
        "而没有任何闸门查注释。\n"
        f"  schema.sql：{m_schema.group(1)!r}\n"
        f"  forward.sql：{m_fwd.group(1)!r}")
```

- [ ] **Step 2: 跑它们，确认 6 条全红**

```bash
cd backend && "$PY" -m pytest tests/test_migrations.py -k 0005 -v 2>&1 | tail -20
```

期望：6 条全 **FAIL**（目录还不存在，第一条报「缺 forward.sql」，其余报 `FileNotFoundError`）。

- [ ] **Step 3: 建 `forward.sql`**

```bash
mkdir -p "$(git rev-parse --show-toplevel)/backend/sql/migrations/0005_schema_version_fail_closed"
```

内容（头注释格式照 `0004/forward.sql:1-11`）：

```sql
-- Migration 0005: training_sets.schema_version 去掉 DEFAULT 1（fail-closed）
-- 引用治理：docs/governance/m01-schema-versioning-contract.md §Bump 策略 A
-- 触发：A 类 DDL「改既有语义」→ 顶层 CONTRACT_VERSION 1.14 → 1.15
-- Spec: docs/superpowers/specs/2026-10-06-ts1r1-schema-version-fail-closed-design.md §4
--
-- 一项变更（0004 是三项合一，本次只有这一项）：
--   training_sets.schema_version 去掉 DEFAULT 1，保留 NOT NULL
--
-- 为什么：有默认值时，漏填该列的 INSERT 被 PostgreSQL 静默补成 1 ——
-- 第 2 代产物被标成第 1 代，而写入方毫无察觉，错误一路流到 App 读取端。
-- 去掉默认值 + 保留 NOT NULL ⇒ 漏填当场报 `violates not-null constraint`。
--
-- 存量行不受影响：DROP DEFAULT 只改列的元数据，不重写任何已有行（由
-- rehearse.sh Part 2 实地证明，不是推理）。

BEGIN;

ALTER TABLE training_sets ALTER COLUMN schema_version DROP DEFAULT;

COMMENT ON COLUMN training_sets.schema_version
  IS '产物代号。⛔ 刻意不设默认值：漏填必须当场失败，不能被静默标成第 1 代。';
-- ⚠️ 这段文字必须与 schema.sql 里那条**逐字一致** —— 两份副本不一致时，
--    从 schema.sql 新建的库与跑过迁移的库注释会不同，而注释不被任何闸门覆盖
--    （P6b 查列/约束/索引，不查 comment）⇒ 无人发现。
--    由 test_migration_0005_comment_text_is_byte_identical_to_schema_sql 钉住。

COMMIT;
```

- [ ] **Step 4: 建 `rollback.sql`**

```sql
-- Rollback for 0005_schema_version_fail_closed
-- 引用治理：docs/governance/m01-schema-versioning-contract.md §Migration Rollback
--
-- ✅ 无数据风险（与 0004 的 rollback 相反，那一份有两条有损警告）：
--   · DROP DEFAULT / SET DEFAULT 只改列的元数据，不重写任何已有行；
--   · 回滚不删表、不改列类型、不收窄长度 ⇒ 没有任何既有数据会被截断或删除。
-- ⛔ 「声称无风险」比「声称有风险」更需要证明，所以这条断言由
--    rehearse.sh Part 3 实地跑出来，不是写在这里就算。
--
-- 因此本文件**刻意不设**破坏性确认守卫（0004 的 rollback 有
-- `kline.rollback_confirm` 那一道）—— 那道守卫的存在理由是「真有东西会丢」，
-- 本次没有东西会丢。为一个不存在的风险加确认步骤，只会让下一个读者以为这里有风险。
--
-- ⚠️ 回滚**之后**的副作用（不是数据损失，但要知道）：默认值装回去之后，
--    漏填 schema_version 的写入会重新被静默补成 1。回滚只应在「本片引入的
--    fail-closed 行为本身导致停机」时执行。

BEGIN;

ALTER TABLE training_sets ALTER COLUMN schema_version SET DEFAULT 1;

COMMENT ON COLUMN training_sets.schema_version IS NULL;
-- 注释必须一起撤掉：留着「刻意不设默认值」这句话、而库里默认值已经装回去了，
-- 等于在库里留一条说谎的注释，而没有任何闸门会发现它。

COMMIT;
```

- [ ] **Step 5: 建 `README.md`**

````markdown
# Migration 0005 · `training_sets.schema_version` 去掉 `DEFAULT 1`

一项变更，同一次 `CONTRACT_VERSION` bump（1.14 → 1.15）覆盖。
（0004 是三项合一，本次只有这一项。）

## 变更内容

| # | 对象 | 从 | 到 |
|---|---|---|---|
| 1 | `training_sets.schema_version` | `INTEGER NOT NULL DEFAULT 1` | `INTEGER NOT NULL`（无默认值） |

附带：给该列加一条说明注释，写明「刻意不设默认值」。
⚠️ 该注释文字与 `backend/sql/schema.sql` 里那条**逐字一致**，由
`test_migration_0005_comment_text_is_byte_identical_to_schema_sql` 钉住。

## 为什么要改

有 `DEFAULT 1` 时，漏填该列的 `INSERT` 会被 PostgreSQL **静默补成 1** ——
第 2 代产物被标成第 1 代，写入方毫无察觉，错误一路流到 App 读取端才显形
（而那时已经无从分辨「这是真的第 1 代」还是「漏填被补的」）。

去掉默认值、**保留** `NOT NULL` ⇒ 漏填当场报
`null value in column "schema_version" ... violates not-null constraint`。

⚠️ 本次**不校验值对不对**：写 `schema_version = 99` 仍会被接受。钉死取值范围需要
`CHECK` 约束，且要先处理存量 1 / 2 两代共存，属另一条判据（见 spec §7）。

## Rollback 风险评估

**本次 rollback 无数据风险。** 理由：

- `DROP DEFAULT` / `SET DEFAULT` 只改列的**元数据**，PostgreSQL 不重写任何已有行；
- 回滚不删表、不改列类型、不收窄长度 ⇒ 没有既有数据会被截断或删除。

⛔ **「声称无风险」比「声称有风险」更需要证明。** 所以这条断言由同目录
`rehearse.sh` 的 **Part 3** 在真 PostgreSQL 上实地跑出来 —— 不是写在这里就算。

因此 `rollback.sql` **刻意不设**破坏性确认守卫（0004 的那一份有
`kline.rollback_confirm = 'I_HAVE_A_BACKUP'` 一道）。那道守卫的存在理由是
「真有东西会丢」；为一个不存在的风险加确认步骤，只会让下一个读者以为这里有风险。

⚠️ 回滚**之后**的副作用（不是数据损失，但要知道）：默认值装回去之后，漏填
`schema_version` 的写入会重新被静默补成 1。回滚只应在「本片引入的 fail-closed
行为本身导致停机」时执行。

## 怎么跑

```bash
# 演练（需要本机 Docker）
./rehearse.sh

# 应用到真库
psql -d <db> -v ON_ERROR_STOP=1 -f forward.sql

# 回滚
psql -d <db> -v ON_ERROR_STOP=1 -f rollback.sql
```

⚠️ **NAS 上的应用步骤**见 `docs/runbooks/2026-08-24-qmt-nas-deployment.md` 的
「P6a · 应用数据库迁移」一节 —— 跳过那一步，P6b 硬门会报 `FAIL-default-drift`
（那不是部署坏了，是迁移没跑）。
````

- [ ] **Step 6: 跑测试，确认 6 条全绿**

```bash
cd backend && "$PY" -m pytest tests/test_migrations.py -k 0005 -v 2>&1 | tail -20
```

期望：`6 passed`。

- [ ] **Step 7: 提交**

```bash
cd "$(git rev-parse --show-toplevel)"
git add backend/sql/migrations/0005_schema_version_fail_closed backend/tests/test_migrations.py
git commit -m "feat(ts1r1): 新增迁移 0005_schema_version_fail_closed

- forward.sql: DROP DEFAULT + 列注释
- rollback.sql: SET DEFAULT 1 + 注释置空；刻意不设破坏性守卫（本次无数据可丢，理由写在文件里）
- README.md: 一项变更说明 + rollback 风险评估（「无风险」这条由 rehearse.sh Part 3 实证）
- 6 条测试: 四件套成对 / 两份都是合法 PostgreSQL / forward 真的 DROP 到那一列 /
  rollback 真的装回去且撤注释 / 两份 COMMENT 逐字一致"
```

- [ ] **Step 8: 变异验证（提交之后跑，用 `git checkout --` 恢复）**

```bash
cd "$(git rev-parse --show-toplevel)"
F=backend/sql/migrations/0005_schema_version_fail_closed/forward.sql
R=backend/sql/migrations/0005_schema_version_fail_closed/rollback.sql

# 变异 A：把 DROP DEFAULT 的目标列换成别的列 → 期望 drops_the_default 变红
#   （证明判据钉到了具体那一列，而不是「含 DROP DEFAULT 就算」）
sed -i '' 's/ALTER COLUMN schema_version DROP DEFAULT/ALTER COLUMN status DROP DEFAULT/' "$F"
(cd backend && "$PY" -m pytest tests/test_migrations.py::test_migration_0005_forward_drops_the_default -q 2>&1 | tail -3)
git checkout -- "$F"

# 变异 B：rollback 只装回默认值、不撤注释 → 期望 restores_the_default 变红
sed -i '' '/COMMENT ON COLUMN training_sets.schema_version IS NULL;/d' "$R"
(cd backend && "$PY" -m pytest tests/test_migrations.py::test_migration_0005_rollback_restores_the_default -q 2>&1 | tail -3)
git checkout -- "$R"

# 变异 C：把 forward 的注释文字改一个字 → 期望 byte_identical 变红
sed -i '' "s/漏填必须当场失败/漏填必须立刻失败/" "$F"
(cd backend && "$PY" -m pytest tests/test_migrations.py::test_migration_0005_comment_text_is_byte_identical_to_schema_sql -q 2>&1 | tail -3)
git checkout -- "$F"

# 变异 D：把 forward 改成语法不合法 → 期望 forward_is_valid_postgres 变红
#   （证明 pglast 真的在解析，而不是只读了个文件）
printf '\nALTER TABLE ( oops;\n' >> "$F"
(cd backend && "$PY" -m pytest tests/test_migrations.py::test_migration_0005_forward_is_valid_postgres -q 2>&1 | tail -3)
git checkout -- "$F"

git status --short
```

期望：A、B、C、D 四次各打印 `1 failed`；最后 `git status --short` **无输出**。

---

## Task 3：`rehearse.sh` Part 1–3 + 等价性探针（Docker 真库演练升降级回环）

**为什么单独一个 Task：** 它是本片**唯一跑真数据库**的东西，也是 README 里「无数据风险」那句断言的唯一证据来源。评审者完全可能认可迁移 SQL 却不认可演练的覆盖面。

⚠️ **本 Task 必须同时满足两道方向相反的约束**（codex 对 plan 的第 1 轮 [high] finding）：
· 演练要证明「漏填会失败」⇒ 需要一条**真的漏填**的可执行写入；
· 已合并的文本守卫要求 `backend/` 下每条 `INSERT INTO training_sets` 的列清单**都含** `schema_version`。
⇒ 解法是 Global Constraint **5b**：漏填写成「列清单含 `schema_version`、值写 `DEFAULT`」，
   并在 Part 1 开头加一段**克隆表探针**，把「DEFAULT ≡ 省略该列」从断言变成测量。
   ⛔ 不用「表名放进变量」那条路 —— 理由见 5b。

**Files:**
- Create: `backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh`（可执行位）
- Test: `backend/tests/test_migrations.py`（把已有的 CJK 大括号守卫扩到 0005）

**Interfaces:**
- Consumes: Task 2 的 `forward.sql` / `rollback.sql`（脚本按文件名读）；迁移前 schema 快照取自固定提交 `6760955`（= 本分支与 `origin/main` 的 merge-base，已实测该提交的 `schema.sql:75` 是 `schema_version INTEGER NOT NULL DEFAULT 1,`）
- Produces: 同目录下的 `rehearse.sh`，Task 4 往它尾部追加 Part 4

- [ ] **Step 1: 先把已有的 CJK 大括号守卫改成覆盖两个迁移目录（会红）**

`backend/tests/test_migrations.py:131` 那条 `test_rehearse_script_braces_vars_before_cjk` 现在只读 `MIG_0004 / "rehearse.sh"`。改成遍历两个：

```python
def test_rehearse_script_braces_vars_before_cjk():
    """演练脚本里 `$VAR` 紧跟全角字符（中文括号/逗号等）会让 bash 把多字节字符的字节
    吞进变量名 → `set -u` 报「未绑定的变量」。

    这是**真跑才会暴露**的一类 bug：`bash -n` 与 `shellcheck` 都查不出来（语法完全合法）。
    实测中它让脚本在加载迁移前 schema 那一步直接崩掉。修法是一律写成 `${VAR}`。
    本测试把这个运行期陷阱变成静态可检，防止以后写中文提示时复发。

    ⚠️ TS1-R1 起**遍历所有迁移目录**，不再只钉 0004：原来写死一个目录，
    于是新加的 0005/rehearse.sh 犯同样的错不会有任何东西变红 ——
    「守卫只钉它被写出来时存在的那一个对象」是本仓反复踩的一类假绿。
    """
    import re
    scripts = sorted(MIGRATIONS_DIR.glob("*/rehearse.sh"))
    assert len(scripts) >= 2, (
        f"只找到 {len(scripts)} 个 rehearse.sh —— 本仓至少有 0004 与 0005 两个，"
        "glob 坏了（防空转）")
    bad = [
        (path.parent.name, i, line)
        for path in scripts
        for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
        if re.search(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]", line)
    ]
    assert not bad, (
        "以下位置 `$VAR` 紧跟全角字符，bash 会把它当成变量名的一部分，请改用 ${VAR}：\n"
        + "\n".join(f"  {d}/rehearse.sh 第 {i} 行: {line.strip()}" for d, i, line in bad))
```

- [ ] **Step 2: 跑它，确认红**

```bash
cd backend && "$PY" -m pytest tests/test_migrations.py::test_rehearse_script_braces_vars_before_cjk -v 2>&1 | tail -6
```

期望：**FAIL**，报文含 `只找到 1 个 rehearse.sh`（0005 的还不存在）。
⚠️ 这个红**正是防空转断言在起作用** —— 如果没有那条 `>= 2`，glob 找到 1 个也会静默通过。

- [ ] **Step 3: 建 `rehearse.sh`（Part 1 前置探针 + Part 1–3 正戏）**

路径：`backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh`

容器样板、`pass_msg` / `fail_msg` / `assert_eq` / `assert_rejects` / `pg_query` / `pg_exec` / `pg_run_file` 的写法**照抄 0004 的 `rehearse.sh`**（第 18–175 行），只改三处常量：`PRE_MIGRATION_SHA`、`CONTAINER_NAME` 里的编号、顶部说明。完整内容：

```bash
#!/usr/bin/env bash
# rehearse.sh —— migration 0005_schema_version_fail_closed 真库演练脚本
#
# 人工执行，不进 CI（与 0004 同约定：进 CI 会牵动 workflow 变更 + 让日常本地测试必须起 Docker）。
# 上线到任何真实 PostgreSQL 之前，必须先跑本脚本并全绿。见同目录 README.md。
#
# 四个 Part：
#   1. 完整升降级回环：建"迁移前"库（带 DEFAULT 1）→ 漏填插入**成功**且值为 1
#      → forward → 漏填插入**必须失败** → 显式给值**成功** → rollback → 漏填插入**又成功**
#   2. 存量行不受影响：forward + rollback 前后，已有行的 schema_version 逐行不变
#   3. rollback 真的无损：README 声称"本次 rollback 无数据风险"——⛔ 声称无风险
#      比声称有风险更需要证明，这里实地证
#   4. 活目录指纹三方对齐：用**改完的** schema.sql 建一个全新库，取出活目录指纹，
#      与仓库里的固件原文、与 CANONICAL_BUSINESS_CATALOG_SHA256 逐一比对
#
# 用法：./rehearse.sh（在任意目录下均可，脚本自己定位仓库根目录）

set -euo pipefail

# ---------- 环境检查 ----------

if command -v docker >/dev/null 2>&1; then
  HAVE_DOCKER=1
else
  HAVE_DOCKER=0
fi

if [ "$HAVE_DOCKER" -eq 0 ]; then
  echo "[FAIL] 未检测到 docker 命令。"
  echo "本脚本需要 Docker 来起一次性 PostgreSQL 容器演练迁移，请先安装 Docker Desktop（或等效工具）再重跑。"
  exit 1
fi

if docker info >/dev/null 2>&1; then
  :
else
  echo "[FAIL] 检测到 docker 命令，但 Docker daemon 未运行或不可访问。"
  echo "请先启动 Docker Desktop（或对应服务），再重跑本脚本。"
  exit 1
fi

echo "[PASS] Docker 可用"

# ---------- 路径 / 常量 ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

FORWARD_SQL="$SCRIPT_DIR/forward.sql"
ROLLBACK_SQL="$SCRIPT_DIR/rollback.sql"
SCHEMA_SQL="$REPO_ROOT/backend/sql/schema.sql"
CATALOG_FIXTURE="$REPO_ROOT/backend/tests/fixtures/business_catalog_fingerprint.txt"

# 本 migration 的 merge-base（改动前的 main）。固定的历史提交引用，不是
# "当前分支的 merge-base 动态计算" —— 分支合并/删除后动态计算会失效。
# 已实测该提交的 backend/sql/schema.sql 第 75 行为
# `    schema_version INTEGER NOT NULL DEFAULT 1,`，即本 migration 的"迁移前"形状。
PRE_MIGRATION_SHA="6760955"

# 与 backend/docker-compose.yml 的 `image: postgres:15.12` 保持一致（勿凭空猜版本）。
PG_IMAGE="postgres:15.12"

CONTAINER_NAME="kline-rehearse-0005-$$-$(date +%s)"
PG_PASSWORD="rehearse_throwaway_$$"   # 仅容器内部用，不对外暴露端口

for f in "$FORWARD_SQL" "$ROLLBACK_SQL" "$SCHEMA_SQL" "$CATALOG_FIXTURE"; do
  if [ -f "$f" ]; then
    :
  else
    echo "[FAIL] 找不到 $f —— 脚本可能被移动，或该文件被删除"
    exit 1
  fi
done

if git -C "$REPO_ROOT" cat-file -e "${PRE_MIGRATION_SHA}^{commit}" 2>/dev/null; then
  :
else
  echo "[FAIL] 仓库中找不到提交 ${PRE_MIGRATION_SHA}（迁移前 schema 快照的来源）"
  echo "可能是浅克隆缺历史，请先 git fetch --unshallow 再重跑"
  exit 1
fi

# 防呆：迁移前快照必须**真的带** DEFAULT 1，否则 Part 1 的第一步会在一个
# 已经没有默认值的库上"证明漏填会失败"——那是恒真，等于伪证。
if git -C "$REPO_ROOT" show "${PRE_MIGRATION_SHA}:backend/sql/schema.sql" \
     | grep -q "schema_version INTEGER NOT NULL DEFAULT 1"; then
  :
else
  echo "[FAIL] 提交 ${PRE_MIGRATION_SHA} 的 schema.sql 里没有 \`schema_version INTEGER NOT NULL DEFAULT 1\`"
  echo "        ⇒ 迁移前快照不是本 migration 的前置形状，Part 1 会变成恒真的伪证。"
  exit 1
fi

echo "[PASS] forward.sql / rollback.sql / schema.sql / 指纹固件 / 迁移前快照（含 DEFAULT 1）均可用"

TMP_LOG="$(mktemp)"

cleanup() {
  local exit_code=$?
  echo ""
  echo "===== 清理 ====="
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -f "$TMP_LOG" 2>/dev/null || true
  if [ "$exit_code" -eq 0 ]; then
    echo "容器 ${CONTAINER_NAME} 已清理，演练脚本正常结束。"
  else
    echo "容器 ${CONTAINER_NAME} 已清理（脚本以失败退出，exit=${exit_code}）。"
  fi
  exit "$exit_code"
}
trap cleanup EXIT

# ---------- 辅助函数（与 0004 同形） ----------

PASS_COUNT=0

pass_msg() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  [PASS] $1"
}

fail_msg() {
  echo "  [FAIL] $1"
}

assert_rejects() {
  # $1=描述  $2=db  $3=期望出现在错误信息里的约束名或报文片段  $4=应当被拒绝的 SQL
  #
  # ⚠️ 必须校验**被谁拒的**，不能接受任意失败（0004 的 codex R4-F1）。
  # 只判"是否失败"时，一条用了不存在的股票代码的探针会被**外键**拦下、
  # 根本走不到要验的那条判据 —— 即便判据完全不存在，探针照样"通过"。
  local desc="$1" db="$2" expect="$3" sql="$4"
  if [ -z "$expect" ]; then
    fail_msg "$desc —— 脚本 bug：assert_rejects 未收到期望的报文片段（第 3 参数为空）"
    exit 1
  fi
  local out rc
  out=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
          psql -U postgres -h 127.0.0.1 -d "$db" -v ON_ERROR_STOP=1 -tA -c "$sql" 2>&1) && rc=0 || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    fail_msg "$desc —— 该语句本应被数据库拒绝，却执行成功了"
    exit 1
  fi
  if printf '%s' "$out" | grep -q "$expect"; then
    pass_msg "${desc}（确由 [${expect}] 拒绝）"
  else
    fail_msg "$desc —— 被拒了，但不是期望的原因。期望错误信息含 [${expect}]，实际：$out"
    exit 1
  fi
}

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" != "$expected" ]; then
    fail_msg "$desc —— 期望 [${expected}]，实际 [${actual}]"
    exit 1
  fi
  pass_msg "$desc"
}

pg_query() {
  # $1=db  $2=sql（单值查询，返回去除格式的纯文本）
  docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
    psql -U postgres -h 127.0.0.1 -d "$1" -tA -c "$2"
}

pg_exec() {
  # $1=db，SQL 从 stdin 读入（供 heredoc 调用）
  docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
    psql -U postgres -h 127.0.0.1 -d "$1" -v ON_ERROR_STOP=1
}

pg_run_file() {
  # $1=db  $2=sql 文件路径
  docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
    psql -U postgres -h 127.0.0.1 -d "$1" -v ON_ERROR_STOP=1 -f - < "$2"
}

# ---------- 起容器 ----------

echo ""
echo "===== 起一次性 PostgreSQL 容器（${PG_IMAGE}）====="

docker run -d --name "$CONTAINER_NAME" \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  "$PG_IMAGE" >/dev/null

printf "等待数据库就绪"
READY=0
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER_NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
    READY=1
    break
  fi
  printf "."
  sleep 1
done
echo ""

if [ "$READY" -eq 0 ]; then
  echo "[FAIL] 容器起来了但 60 秒内数据库没就绪"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -30
  exit 1
fi

pass_msg "PostgreSQL 容器就绪：$(pg_query postgres 'SHOW server_version;')"

# ---------- Part 1：完整升降级回环 ----------

echo ""
echo "===== Part 1 · 完整升降级回环 ====="

DB1="rehearse_0005_loop"
pg_query postgres "CREATE DATABASE ${DB1};" >/dev/null

# 用迁移前的 schema 快照建库（带 DEFAULT 1）
git -C "$REPO_ROOT" show "${PRE_MIGRATION_SHA}:backend/sql/schema.sql" > "$TMP_LOG"
pg_run_file "$DB1" "$TMP_LOG" >/dev/null
pass_msg "用迁移前快照（${PRE_MIGRATION_SHA}）建库完成"

# 外键要求 stocks 里先有这只股票
pg_exec "$DB1" >/dev/null <<'SQL'
INSERT INTO stocks (code, name) VALUES ('000001', '演练股');
SQL

assert_eq "迁移前：schema_version 的默认值是 1" \
  "$(pg_query "$DB1" "SELECT column_default FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';")" \
  "1"

# ---------- Part 1 前置探针：证明「值写 DEFAULT」≡「省略该列」 ----------
#
# ⚠️ 为什么需要这一段：下面全部"漏填"场景都写成「列清单含 schema_version、值写 DEFAULT」
#    （理由见计划 Global Constraint 5b：已合并的文本守卫会把"省掉该列"的字面量判红）。
#    于是整个 Part 1 的说服力都压在"DEFAULT ≡ 省略"这一个**断言**上 ——
#    ⛔ 断言必须变成**测量**。这段就在真库上把两种写法并排跑一遍。
#
# 用 training_sets 的**克隆表**做，不用玩具表：克隆表与真表列/类型/可空/默认值/CHECK 全同
#   （`LIKE … INCLUDING ALL`），免掉"你是在玩具表上证的"这类质疑。
#   ⚠️ `LIKE … INCLUDING ALL` **不复制外键** ⇒ 探针不需要 stocks 里有对应股票。
#   ⚠️ `INCLUDING ALL` 会把 `id` 的默认值连同 `nextval('training_sets_id_seq')` 一起复制过来
#      ⇒ 探针插入会消耗**真序列**的号。本容器是一次性的、Part 1 之后没有任何断言依赖
#      training_sets.id 的具体取值（Part 3 的整表指纹跑在另一个库上），故无害。
#   克隆表不是 training_sets ⇒ 它上面那条"省略列"的字面量**不在守卫的 needle 里**
#   （守卫只找 `INSERT INTO training_sets`）——  这不是绕法，它确实是另一张表。

echo ""
echo "----- Part 1 前置探针：「值写 DEFAULT」是否真的等于「省略该列」 -----"

pg_exec "$DB1" >/dev/null <<'SQL'
CREATE TABLE ts_default_probe (LIKE training_sets INCLUDING ALL);
SQL

assert_eq "克隆表继承了 schema_version 的默认值 1" \
  "$(pg_query "$DB1" "SELECT coalesce(column_default,'<无>') FROM information_schema.columns WHERE table_name='ts_default_probe' AND column_name='schema_version';")" \
  "1"
assert_eq "克隆表继承了 schema_version 的 NOT NULL" \
  "$(pg_query "$DB1" "SELECT is_nullable FROM information_schema.columns WHERE table_name='ts_default_probe' AND column_name='schema_version';")" \
  "NO"

probe_pair() {
  # $1=阶段描述  $2=本轮用的时间戳前缀（两条探针必须用不同的行，否则撞唯一约束）
  local phase="$1" n="$2" a b ra rb ka kb
  a=$(pg_query "$DB1" "INSERT INTO ts_default_probe (stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash) VALUES ('000001','探针',${n}1,${n}2,'/tmp/a${n}.zip','aaaaaaa1') RETURNING schema_version;" 2>&1) && ra=0 || ra=$?
  b=$(pg_query "$DB1" "INSERT INTO ts_default_probe (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('000001','探针',${n}3,${n}4,DEFAULT,'/tmp/b${n}.zip','bbbbbbb2') RETURNING schema_version;" 2>&1) && rb=0 || rb=$?
  # ⚠️ 判据取**错误身份**（`ERROR:` 那一行），⛔ 不取整段输出：psql 的 `DETAIL:` 行会把
  #    失败那一行的全部字段打出来（含 id / file_path / content_hash / 时间戳），
  #    而两条探针插的本来就是**不同的行** ⇒ 整段比对**必然不等**。
  #    那会得出"两种写法不等价"的**假结论** —— 实测踩过这一步。
  ka=$(printf '%s' "$a" | grep '^ERROR:' || printf '%s' "$a")
  kb=$(printf '%s' "$b" | grep '^ERROR:' || printf '%s' "$b")
  echo "    ${phase}："
  echo "      省略该列      → 退出码 ${ra}；${ka}"
  echo "      值写 DEFAULT  → 退出码 ${rb}；${kb}"
  if [ "$ka" = "$kb" ] && [ "$ra" = "$rb" ]; then
    pass_msg "${phase}：两种写法的退出码与错误身份逐字相同"
  else
    fail_msg "${phase}：两种写法**不等价** —— 那么本脚本此后用 DEFAULT 代替漏填的做法整个失效，必须停下来重新设计"
    exit 1
  fi
}

probe_pair "阶段1 · 有 DEFAULT 1" 10
pg_query "$DB1" "ALTER TABLE ts_default_probe ALTER COLUMN schema_version DROP DEFAULT;" >/dev/null
probe_pair "阶段2 · DROP DEFAULT 之后" 20
pg_query "$DB1" "ALTER TABLE ts_default_probe ALTER COLUMN schema_version SET DEFAULT 1;" >/dev/null
probe_pair "阶段3 · SET DEFAULT 1 回滚之后" 30

# 防空转：阶段 2 必须真的**失败过**，否则三个阶段全是"都成功"，等价性被证得毫无内容
if pg_query "$DB1" "INSERT INTO ts_default_probe (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('000001','探针',901,902,2,'/tmp/c.zip','ccccccc3') RETURNING schema_version;" >/dev/null 2>&1; then
  pass_msg "探针表在显式给值时仍能写入（防空转：证明上面的失败不是因为这张表根本写不进去）"
else
  fail_msg "探针表连显式给值都写不进去 —— 探针自身坏了，上面的等价性结论不可信"
  exit 1
fi

pg_exec "$DB1" >/dev/null <<'SQL'
DROP TABLE ts_default_probe;
SQL
pass_msg "探针表已清理（它只为证明等价性而存在，不参与后面的形状断言）"

echo ""
echo "----- Part 1 正戏 -----"

# ① 迁移前：漏填 schema_version（写成 DEFAULT）的 INSERT 应当成功，且被静默补成 1
#    —— 这就是本片要消灭的行为
pg_exec "$DB1" >/dev/null <<'SQL'
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES ('000001', '演练股', 1000, 2000, DEFAULT, '/tmp/before.zip', 'aabbccdd');
SQL
assert_eq "迁移前：漏填 schema_version 的写入**成功**，且被静默补成 1（= 本片要消灭的行为）" \
  "$(pg_query "$DB1" "SELECT schema_version FROM training_sets WHERE file_path='/tmp/before.zip';")" \
  "1"

# ② 跑 forward
pg_run_file "$DB1" "$FORWARD_SQL" >/dev/null
pass_msg "forward.sql 执行成功"

assert_eq "迁移后：schema_version 已无默认值" \
  "$(pg_query "$DB1" "SELECT coalesce(column_default, '<无默认值>') FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';")" \
  "<无默认值>"

assert_eq "迁移后：schema_version 仍然 NOT NULL（fail-closed 靠它）" \
  "$(pg_query "$DB1" "SELECT is_nullable FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';")" \
  "NO"

assert_eq "迁移后：列注释已写入" \
  "$(pg_query "$DB1" "SELECT col_description('training_sets'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid='training_sets'::regclass AND attname='schema_version'));")" \
  "产物代号。⛔ 刻意不设默认值：漏填必须当场失败，不能被静默标成第 1 代。"

# ③ 迁移后：漏填必须失败，且是**因为 NOT NULL**，不是因为别的
assert_rejects "迁移后：漏填 schema_version 的写入**被拒**" "$DB1" \
  "violates not-null constraint" \
  "INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('000001', '演练股', 3000, 4000, DEFAULT, '/tmp/after_missing.zip', 'bbccddee');"

# ③b 报文必须点名是哪一列 —— 不点名的报文会让运维去猜（验收判据 3 的措辞依据）
#    ⚠️ 这一条刻意用 3100（不是 ③ 的 3000）：`uq_stock_start UNIQUE (stock_code, start_datetime)`
#       在同一个 (股票, start) 上只允许一行。实测两条都失败的 INSERT **零行落地、不占唯一键**
#       （报的都是 `null value … violates not-null constraint`，不是唯一键冲突），
#       所以共用 3000 今天也不会出错 —— 但那依赖「③b 永远注定失败」这个前提。
#       哪天有人把 ③b 改成期望成功，就会撞上一个与本意无关的唯一键错误。错开更省事。
MISSING_OUT=$(docker exec -e PGPASSWORD="$PG_PASSWORD" "$CONTAINER_NAME" \
  psql -U postgres -h 127.0.0.1 -d "$DB1" -v ON_ERROR_STOP=1 -tA \
  -c "INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('000001', '演练股', 3100, 4100, DEFAULT, '/tmp/after_missing2.zip', 'ccddeeff');" 2>&1 || true)
if printf '%s' "$MISSING_OUT" | grep -q 'schema_version'; then
  pass_msg "报错信息点名了 schema_version（运维不用猜是哪一列）"
else
  fail_msg "报错信息没点名 schema_version，实际：$MISSING_OUT"
  exit 1
fi

# ④ 迁移后：显式给值仍能正常写入（正向对照，防止改成恒拒）
pg_exec "$DB1" >/dev/null <<'SQL'
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES ('000001', '演练股', 5000, 6000, 2, '/tmp/after_explicit.zip', 'ddeeff00');
SQL
assert_eq "迁移后：显式写 schema_version=2 仍成功（正向对照，证明不是恒拒）" \
  "$(pg_query "$DB1" "SELECT schema_version FROM training_sets WHERE file_path='/tmp/after_explicit.zip';")" \
  "2"

# ⑤ 跑 rollback，漏填又恢复成"成功且补 1"
pg_run_file "$DB1" "$ROLLBACK_SQL" >/dev/null
pass_msg "rollback.sql 执行成功"

assert_eq "回滚后：默认值 1 已装回" \
  "$(pg_query "$DB1" "SELECT column_default FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';")" \
  "1"

assert_eq "回滚后：列注释已撤掉（不留说谎的注释）" \
  "$(pg_query "$DB1" "SELECT coalesce(col_description('training_sets'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid='training_sets'::regclass AND attname='schema_version')), '<无注释>');")" \
  "<无注释>"

pg_exec "$DB1" >/dev/null <<'SQL'
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES ('000001', '演练股', 7000, 8000, DEFAULT, '/tmp/after_rollback.zip', 'eeff0011');
SQL
assert_eq "回滚后：漏填又恢复为成功且补 1（证明回滚真的回到了迁移前行为）" \
  "$(pg_query "$DB1" "SELECT schema_version FROM training_sets WHERE file_path='/tmp/after_rollback.zip';")" \
  "1"

# ---------- Part 2：存量行不受影响 ----------

echo ""
echo "===== Part 2 · 存量行不受影响 ====="

DB2="rehearse_0005_existing"
pg_query postgres "CREATE DATABASE ${DB2};" >/dev/null
git -C "$REPO_ROOT" show "${PRE_MIGRATION_SHA}:backend/sql/schema.sql" > "$TMP_LOG"
pg_run_file "$DB2" "$TMP_LOG" >/dev/null

pg_exec "$DB2" >/dev/null <<'SQL'
INSERT INTO stocks (code, name) VALUES ('000002', '存量股');
-- 刻意混入两代产物 + 一个非 1/2 的值：若 DROP DEFAULT 真的重写了行，
-- 单一值的样本看不出来（全是 1 的话，被改写成 1 也察觉不到）。
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES ('000002', '存量股', 100, 200, 1, '/tmp/gen1.zip', '11111111'),
       ('000002', '存量股', 300, 400, 2, '/tmp/gen2.zip', '22222222'),
       ('000002', '存量股', 500, 600, 7, '/tmp/gen7.zip', '77777777');
SQL

BEFORE=$(pg_query "$DB2" "SELECT string_agg(file_path || '=' || schema_version, ',' ORDER BY file_path) FROM training_sets;")
assert_eq "样本就位（三行、三个不同代号）" "$BEFORE" \
  "/tmp/gen1.zip=1,/tmp/gen2.zip=2,/tmp/gen7.zip=7"

pg_run_file "$DB2" "$FORWARD_SQL" >/dev/null
AFTER_FWD=$(pg_query "$DB2" "SELECT string_agg(file_path || '=' || schema_version, ',' ORDER BY file_path) FROM training_sets;")
assert_eq "forward 之后存量行逐行不变（DROP DEFAULT 只改元数据）" "$AFTER_FWD" "$BEFORE"

pg_run_file "$DB2" "$ROLLBACK_SQL" >/dev/null
AFTER_RB=$(pg_query "$DB2" "SELECT string_agg(file_path || '=' || schema_version, ',' ORDER BY file_path) FROM training_sets;")
assert_eq "rollback 之后存量行仍逐行不变" "$AFTER_RB" "$BEFORE"

# ---------- Part 3：rollback 真的无损 ----------

echo ""
echo "===== Part 3 · rollback 真的无损（README 声称无风险，这里实证）====="

DB3="rehearse_0005_lossless"
pg_query postgres "CREATE DATABASE ${DB3};" >/dev/null
git -C "$REPO_ROOT" show "${PRE_MIGRATION_SHA}:backend/sql/schema.sql" > "$TMP_LOG"
pg_run_file "$DB3" "$TMP_LOG" >/dev/null

# ⛔ **`sent` 行必须把三个租约列一起填上**（codex 对 plan 第 2 轮的 [high] finding，已实测坐实）。
#    `ck_lease_state_invariant` 的判据是：
#        status='unsent'              ⇒ lease_id / lease_expires_at / reserved_at 三者**全为 NULL**
#        status IN ('reserved','sent') ⇒ 三者**全非 NULL**
#    本计划初稿只给了 status='sent' 而把三列省掉（⇒ 全是 NULL）⇒ 两个分支都不满足。
#    实测报错：`new row for relation "training_sets" violates check constraint
#    "ck_lease_state_invariant"`，psql 退出码 3 ⇒ `ON_ERROR_STOP=1` + `set -e`
#    会让脚本**在 Part 3 的第一条语句就中止** —— 无损验证一条没跑，Part 4 也到不了。
#    写法照 0004 的 `rehearse.sh:213-219`（它给 sent 行填的就是这三个值）。
#    ⚠️ Part 1 / Part 2 的样本**不受影响**：它们不写 status ⇒ 取默认值 'unsent' ⇒
#       三个租约列保持 NULL ⇒ 满足第一个分支（已实测确认三行都是 `unsent/NULL`）。
pg_exec "$DB3" >/dev/null <<'SQL'
INSERT INTO stocks (code, name) VALUES ('000003', '无损股');
INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash,
                           status, lease_id, lease_expires_at, reserved_at)
VALUES ('000003', '无损股', 100, 200, 1, '/tmp/l1.zip', 'aaaa1111',
        'unsent', NULL, NULL, NULL),
       ('000003', '无损股', 300, 400, 2, '/tmp/l2.zip', 'bbbb2222',
        'sent', gen_random_uuid(), NOW() + interval '1 hour', NOW());
SQL

# 防呆：两种 status 都要真的在样本里。若哪天有人把 sent 那行删掉"图省事"，
# 整表指纹判据会退化成"只验了 unsent 行"，而它照样全绿。
assert_eq "无损样本覆盖了两种 status（unsent + sent）" \
  "$(pg_query "$DB3" "SELECT string_agg(DISTINCT status, ',' ORDER BY status) FROM training_sets;")" \
  "sent,unsent"

# 判据不是"schema_version 没变"（Part 2 已经证了），而是**整张表一个字节都没变**：
# 回滚"无损"要防的不只是那一列 —— 任何一列被改写、任何一行消失都算有损。
# 用 md5(整行文本) 的聚合作为"整表指纹"。
SNAP_BEFORE=$(pg_query "$DB3" "SELECT md5(string_agg(t::text, E'\n' ORDER BY t.id)) FROM training_sets t;")
ROWS_BEFORE=$(pg_query "$DB3" "SELECT count(*) FROM training_sets;")
assert_eq "无损样本就位（2 行）" "$ROWS_BEFORE" "2"

pg_run_file "$DB3" "$FORWARD_SQL" >/dev/null
pg_run_file "$DB3" "$ROLLBACK_SQL" >/dev/null

SNAP_AFTER=$(pg_query "$DB3" "SELECT md5(string_agg(t::text, E'\n' ORDER BY t.id)) FROM training_sets t;")
ROWS_AFTER=$(pg_query "$DB3" "SELECT count(*) FROM training_sets;")

assert_eq "升降级一圈之后行数不变" "$ROWS_AFTER" "$ROWS_BEFORE"
assert_eq "升降级一圈之后**整张表的内容指纹**逐字节不变 ⇒ rollback 确实无数据损失" \
  "$SNAP_AFTER" "$SNAP_BEFORE"

# 防空转：指纹不能是空值（表被清空时 string_agg 返回 NULL，md5(NULL) 也是 NULL，
# 两个 NULL 在 psql -tA 下都打印成空串 ⇒ "空 == 空"会让上面那条恒真）。
if [ -n "$SNAP_BEFORE" ]; then
  pass_msg "整表指纹非空（防空转：若表被清空，两边都会是空串而上面那条恒真）"
else
  fail_msg "整表指纹是空串 —— 上面那条相等断言没有判别力，脚本自身有 bug"
  exit 1
fi

# ---------- 收尾 ----------

echo ""
echo "===== 结果 ====="
echo "[PASS] 全部断言通过，共 ${PASS_COUNT} 条。"
```

- [ ] **Step 3b: 先跑已合并的那道 `INSERT` 守卫 —— 并用对照证明它真在看这个文件**

⛔ **这一步必须排在 Step 4（真跑 Docker）之前**：它是静态的、1 秒出结果；
如果守卫会红，先花 3 分钟起容器毫无意义。

```bash
cd "$(git rev-parse --show-toplevel)"
(cd backend && "$PY" -m pytest tests/test_insert_schema_version_guard.py -q 2>&1 | tail -4)
```

期望：**`3 passed`**。

⚠️ **「绿」本身不算证据** —— 守卫也可能根本没看见这个文件（后缀白名单、路径筛选、
`__pycache__` 过滤都可能把它静默移出视野，而守卫会照样报「全都合规」）。
所以必须做**对照 A**：把一条语句临时改成「省略该列」，守卫**必须变红、且报文里出现这个文件的路径**。

⛔ **恢复不能用 `git checkout --`**（codex 对 plan 第 2 轮的 [medium] finding，成立）：
本 Step 排在 Task 3 Step 6 的首次提交**之前**，此时 `rehearse.sh` 还是**未跟踪文件**，
`git checkout -- <未跟踪文件>` 会报 `pathspec … did not match any file(s) known to git`，
于是**变异留在脚本里**，此后整套后端测试会一直红 —— 而变异本身是"故意漏填"，
它留下的红会被误读成"守卫在正常工作"。⇒ 用 `cp` 备份/还原，并**从输出派生结论**。

```bash
cd "$(git rev-parse --show-toplevel)"
F=backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh
BAK="$(mktemp)"
cp "$F" "$BAK"
echo "已备份到 $BAK（$(shasum -a 256 "$BAK" | cut -d' ' -f1 | cut -c1-16)…）"

"$PY" - <<'MUT'
import pathlib
f = pathlib.Path("backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh")
t = f.read_text(encoding="utf-8")
old = ("(stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)\n"
       "VALUES ('000001', '演练股', 1000, 2000, DEFAULT, '/tmp/before.zip', 'aabbccdd');")
new = ("(stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash)\n"
       "VALUES ('000001', '演练股', 1000, 2000, '/tmp/before.zip', 'aabbccdd');")
assert t.count(old) == 1, f"锚点命中 {t.count(old)} 次 —— 变异没改上，⛔ 不要读下面的结果"
f.write_text(t.replace(old, new), encoding="utf-8")
print("变异已施加：第一条 INSERT 的列清单里已无 schema_version")
MUT

# ⛔ 先证明变异真的改上了，再读测试结果
#    （本仓栽过「变异没改上而测试打印通过 ⇒ 结论完全反过来」）
echo "证据 · 不含 schema_version 的 training_sets 列清单条数 = $(grep -c 'end_datetime, file_path' "$F")  （应为 1）"
(cd backend && "$PY" -m pytest tests/test_insert_schema_version_guard.py -q 2>&1 | tail -10)

# 还原，并**证明还原成功**（⛔ 不是"执行了还原命令"就算 —— 本仓记过"还原用相对路径会静默失败"）
cp "$BAK" "$F" && chmod +x "$F" && rm -f "$BAK"
echo "还原后 · 不含 schema_version 的条数 = $(grep -c 'end_datetime, file_path' "$F")  （应为 0）"
(cd backend && "$PY" -m pytest tests/test_insert_schema_version_guard.py -q 2>&1 | tail -4)
```

期望最后那次重跑是 **`3 passed`** —— 这既确认还原生效，也确认绿不是侥幸。

期望（本计划定稿前已在真路径上实测过一次，输出如下）：

```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E         【列清单里没有 `schema_version`】…
E           backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh:3  列清单=stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash
FAILED tests/test_insert_schema_version_guard.py::test_every_executable_insert_carries_schema_version
1 failed, 2 passed
```

⇒ 报文里**出现了这个文件的路径** = 守卫确实在看它；
   恢复之后又 `3 passed` = `DEFAULT` 写法是被它**判为合规**，不是被它**漏掉**。
   （定稿前另有一次直接调 `_scan` 的测量：该文件解析出 **4 条**语句、
   `missing=0 / positional=0 / unknown=0`。）

⚠️ 若对照 A **没有变红**，Step 3b 的「绿」就是假绿 —— **停下来**先搞清它为什么不在视野里，
⛔ 不要往下走。

- [ ] **Step 4: 赋可执行位，语法检查，再真跑**

```bash
cd "$(git rev-parse --show-toplevel)/backend/sql/migrations/0005_schema_version_fail_closed"
chmod +x rehearse.sh
bash -n rehearse.sh && echo "语法 OK"
./rehearse.sh 2>&1 | tee /tmp/ts1r1-rehearse-part123.log
echo "退出码 = $?"
```

期望：所有行都是 `[PASS]`，最后一行 `[PASS] 全部断言通过，共 N 条。`，退出码 **0**。

⚠️ 特别要在输出里找到**前置探针**那三组（它们是整个 Part 1 的地基）：

```
    阶段1 · 有 DEFAULT 1：
      省略该列      → 退出码 0；1
      值写 DEFAULT  → 退出码 0；1
  [PASS] 阶段1 · 有 DEFAULT 1：两种写法的退出码与错误身份逐字相同
    阶段2 · DROP DEFAULT 之后：
      省略该列      → 退出码 1；ERROR:  null value in column "schema_version" of relation "ts_default_probe" violates not-null constraint
      值写 DEFAULT  → 退出码 1；ERROR:  null value in column "schema_version" of relation "ts_default_probe" violates not-null constraint
  [PASS] 阶段2 · DROP DEFAULT 之后：两种写法的退出码与错误身份逐字相同
    阶段3 · SET DEFAULT 1 回滚之后：（同阶段 1，退出码 0、值 1）
  [PASS] 阶段3 · SET DEFAULT 1 回滚之后：两种写法的退出码与错误身份逐字相同
```

⚠️ **阶段 2 必须是退出码 1**。若三个阶段全是退出码 0，说明 `DROP DEFAULT` 没施加到探针表上，
等价性就被「证」得毫无内容。脚本里那条「显式给值仍能写入」的防空转断言挡不住这一种，
所以这里要用眼睛确认一次。

⚠️ 若 Docker 不可用，脚本第一步就会打印 `[FAIL] 未检测到 docker` 并 `exit 1` —— 那时**不要**往下走，先把 Docker 起来。

- [ ] **Step 5: 跑 CJK 守卫，确认由红转绿**

```bash
cd backend && "$PY" -m pytest tests/test_migrations.py::test_rehearse_script_braces_vars_before_cjk -v 2>&1 | tail -5
```

期望：**PASS**（现在 glob 找到 2 个脚本，且两个都没有 `$VAR` 紧跟全角字符）。

- [ ] **Step 6: 跑整套后端确认全绿，然后提交**

```bash
cd backend && "$PY" -m pytest -q 2>&1 | tail -5
cd "$(git rev-parse --show-toplevel)"
git add backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh backend/tests/test_migrations.py
git commit -m "feat(ts1r1): 0005 rehearse.sh 前置探针 + Part 1-3（Docker 真库演练）

- Part 1 前置探针：在 training_sets 的克隆表上证明「值写 DEFAULT」≡「省略该列」
  （三阶段比对退出码 + ERROR 行；⛔ 不比整段输出 —— DETAIL 行含行数据必然不等）
  ⇒ 这是整个 Part 1 的地基：漏填必须写成 DEFAULT 形式才能过已合并的文本守卫（GC 5b）
- Part 1 完整升降级回环：迁移前漏填成功补 1 → forward → 漏填被 NOT NULL 拒且报文点名该列
  → 显式给值仍成功（防恒拒）→ rollback → 漏填又恢复补 1
- Part 2 存量行不变：样本刻意混 1/2/7 三个代号（单一值的样本看不出被改写）
- Part 3 无损实证：判据是**整张表的内容指纹**逐字节不变，不只是那一列；附防空转
- 迁移前快照加防呆：快照里必须真的有 DEFAULT 1，否则 Part 1 变成恒真伪证
- CJK 大括号守卫改为遍历所有迁移目录（原来写死 0004，新脚本犯同样错不会红）"
```

- [ ] **Step 7: 变异验证（提交之后跑）**

```bash
cd "$(git rev-parse --show-toplevel)"
S=backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh

# 变异 A：删掉一个迁移目录的 rehearse.sh → 期望 CJK 守卫的防空转断言变红
mv "$S" /tmp/rehearse-0005.bak
(cd backend && "$PY" -m pytest tests/test_migrations.py::test_rehearse_script_braces_vars_before_cjk -q 2>&1 | tail -3)
mv /tmp/rehearse-0005.bak "$S"

# 变异 B：往脚本里塞一行 `$VAR` 紧跟全角字符 → 期望 CJK 守卫变红
printf 'echo "$CONTAINER_NAME（演练容器）"\n' >> "$S"
(cd backend && "$PY" -m pytest tests/test_migrations.py::test_rehearse_script_braces_vars_before_cjk -q 2>&1 | tail -3)
git checkout -- "$S" && chmod +x "$S"

git status --short
```

期望：A 打印 `1 failed`（报文含 `只找到 1 个 rehearse.sh`）、B 打印 `1 failed`（报文点出那一行）；最后 `git status --short` **无输出**。

⚠️ **还有一类变异必须做 —— 证明 `rehearse.sh` 本身有判别力**，否则它只是一串必然 `[PASS]` 的输出：

```bash
cd "$(git rev-parse --show-toplevel)"
F=backend/sql/migrations/0005_schema_version_fail_closed/forward.sql

# 变异 C：把 forward.sql 的 DROP DEFAULT 删掉 → Part 1 必须在"迁移后漏填被拒"那一条失败
sed -i '' '/ALTER TABLE training_sets ALTER COLUMN schema_version DROP DEFAULT;/d' "$F"
./backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh 2>&1 | tail -8
echo "退出码 = $?"
git checkout -- "$F"

# 变异 D：把 forward.sql 的注释文字改一个字 → Part 1 的"列注释已写入"那条必须失败
sed -i '' "s/漏填必须当场失败/漏填必须立刻失败/" "$F"
./backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh 2>&1 | tail -8
echo "退出码 = $?"
git checkout -- "$F"

git status --short
```

期望：C 打印 `[FAIL] 迁移后：漏填 schema_version 的写入**被拒** —— 该语句本应被数据库拒绝，却执行成功了`，退出码非 0；D 打印 `[FAIL] 迁移后：列注释已写入 —— 期望 […] 实际 […]`，退出码非 0；最后工作区干净。

---

## Task 4：活目录指纹三方对齐（`rehearse.sh` Part 4 + 固件 + 常量）

**为什么单独一个 Task：** 它是本片**唯一需要「先让闸门变红、读它打印的真值、再写回去」**的改动。把它混进 Task 3 会让「Part 1–3 全绿」与「Part 4 故意先红」两种状态挤在一次提交里，没人分得清。

**Files:**
- Modify: `backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh`（尾部追加 Part 4，并把收尾段移到 Part 4 之后）
- Modify: `backend/tests/fixtures/business_catalog_fingerprint.txt`（删第 65 行）
- Modify: `backend/qmt_pilot_db.py:1394`（`CANONICAL_BUSINESS_CATALOG_SHA256`）

**Interfaces:**
- Consumes: Task 1 定稿的 `backend/sql/schema.sql`（Part 4 用**它**建库）；Task 3 的 `rehearse.sh` 容器样板与 `pg_query` / `assert_eq` / `pass_msg`
- Produces: 对齐后的固件 + 常量。`test_business_catalog_fixture_matches_the_constant`（`backend/tests/test_qmt_pilot_db.py:2986`）钉住「固件 ↔ 常量」；Part 4 钉住「固件 ↔ 活库」与「常量 ↔ 活库」

- [ ] **Step 1: 先理清三件事实（动手前读一遍，省掉两次返工）**

1. **指纹的 `--defaults--` 段来自 `pg_attrdef` 的 JOIN**（`backend/qmt_pilot_db.py:1351-1356`）。`DROP DEFAULT` 会把那条记录**整行删掉** ⇒ 固件里 `training_sets.schema_version=1` 那一行应当**消失**，不是改值。
2. **列注释不进指纹**（指纹取 `pg_class` 整行 + `pg_attribute` + `pg_constraint` + `pg_attrdef` + `pg_sequences` + `pg_index`，没有 `pg_description`）⇒ 新增的那条 `COMMENT ON` 预期**不改变指纹**。
3. **固件文件末尾没有换行符**（实测：5041 字节，最后一个字节是 `0x29` 即 `)`），而 `sha256_of_sql` 就是对文件字节直接取 sha256（实测固件 sha256 = 当前常量，对得上）。⇒ 写回固件时必须用 `printf '%s'`（不补换行），⛔ 不能用 `echo`。

⚠️ 第 1、2 条是**预测**。⛔ 不许当成结论直接改固件 —— 本仓反复踩「『它挡得住 X』不实测就写」。Part 4 存在的意义就是让真数据库把答案打出来。

- [ ] **Step 2: 往 `rehearse.sh` 追加 Part 4（放在 Part 3 之后、收尾段之前）**

先把 Task 3 里那段收尾（`===== 结果 =====` 那三行）**删掉**，追加下面这一整段，收尾段放在最后：

```bash
# ---------- Part 4：活目录指纹三方对齐 ----------

echo ""
echo "===== Part 4 · 活目录指纹三方对齐（固件 ↔ 常量 ↔ 活库）====="

# 为什么在这里做：指纹是**三方互钉**（backend/tests/test_qmt_pilot_db.py:85-90 的注释）——
#   · 固件 ↔ 常量：test_business_catalog_fixture_matches_the_constant（纯 Python，CI 里跑）
#   · 常量 ↔ 活库：verify_pilot_two_phase_create.py 的 ㉕ 档（需要真 PG 的 DSN + asyncpg）
# 第三条腿平时**跑不起来**，而改 schema.sql 恰恰改的就是"活库长什么样"。
# 本 Part 用同一个演练容器把那条腿真跑一次，不需要 asyncpg、不需要外部 DSN。
#
# ⚠️ 它同时是**指纹的生成手段**：固件还是旧值时，本 Part 会红并打印活库实际值
#    （与 ㉕ 档同样的设计）。那个红色输出里的值就是要写进固件的新值。

DB4="rehearse_0005_catalog"
pg_query postgres "CREATE DATABASE ${DB4} TEMPLATE template0;" >/dev/null

# ⚠️ 用**仓库当前的** schema.sql 建库（不是迁移前快照）——
#    指纹钉的是"用规范 schema.sql 新建出来的库长什么样"。
pg_run_file "$DB4" "$SCHEMA_SQL" >/dev/null
pass_msg "用当前 backend/sql/schema.sql 建了一个全新库 ${DB4}"

# 指纹 SQL 的**唯一真源**是 backend/qmt_pilot_db.py 里的 _BUSINESS_CATALOG_FINGERPRINT_SQL。
# ⛔ 刻意不在本脚本里抄一份：抄一份就是"同一事实两处副本"，模块那边一改、这里
#    静默沿用旧版 ⇒ 本 Part 会在一个过时的判据上报绿。改为运行时从模块里取出来。
FP_SQL=$(python3 - "$REPO_ROOT" <<'PYEOF'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "backend"))
from qmt_pilot_db import _BUSINESS_CATALOG_FINGERPRINT_SQL
sys.stdout.write(_BUSINESS_CATALOG_FINGERPRINT_SQL)
PYEOF
)

if [ -n "$FP_SQL" ]; then
  pass_msg "已从 qmt_pilot_db 取出指纹 SQL（$(printf '%s' "$FP_SQL" | wc -c | tr -d ' ') 字节），未在本脚本里抄副本"
else
  fail_msg "从 qmt_pilot_db 取指纹 SQL 失败（空串）—— 常量改名或 import 坏了"
  exit 1
fi

# 命令替换会吃掉尾部换行，正好对上固件"文件末尾无换行"的形态（实测固件最后一字节是 ')'）
LIVE_FP=$(pg_query "$DB4" "$FP_SQL")

if [ -n "$LIVE_FP" ]; then
  pass_msg "活库指纹已取出（$(printf '%s' "$LIVE_FP" | wc -c | tr -d ' ') 字节，$(printf '%s' "$LIVE_FP" | wc -l | tr -d ' ') 个换行）"
else
  fail_msg "活库指纹是空串 —— 下面的比对会变成'空 == 空'的恒真，脚本自身有 bug"
  exit 1
fi

LIVE_SHA=$(printf '%s' "$LIVE_FP" | shasum -a 256 | cut -d' ' -f1)
FIXTURE_SHA=$(shasum -a 256 "$CATALOG_FIXTURE" | cut -d' ' -f1)
CONST_SHA=$(python3 - "$REPO_ROOT" <<'PYEOF'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "backend"))
from qmt_pilot_db import CANONICAL_BUSINESS_CATALOG_SHA256
print(CANONICAL_BUSINESS_CATALOG_SHA256)
PYEOF
)

echo ""
echo "  活库指纹 sha256 = ${LIVE_SHA}"
echo "  固件   sha256 = ${FIXTURE_SHA}"
echo "  常量   sha256 = ${CONST_SHA}"
echo ""

# 第一条腿：固件 ↔ 活库。不等时把**完整 diff** 打出来 —— 这就是"重新生成"的输入。
if printf '%s' "$LIVE_FP" | diff -u "$CATALOG_FIXTURE" - > "$TMP_LOG" 2>&1; then
  pass_msg "固件原文 ↔ 活库指纹 逐字节相等"
else
  fail_msg "固件原文与活库指纹不一致。完整 diff（左 = 仓库固件，右 = 活库实际）："
  echo ""
  cat "$TMP_LOG"
  echo ""
  echo "  ⚠️ 若你刚改过 backend/sql/schema.sql，这就是**预期的红**，右侧即新的真值。"
  echo "     重新生成方法（在仓库根目录执行）："
  echo ""
  echo "     本脚本已把活库指纹写到： ${TMP_LOG}.live"
  printf '%s' "$LIVE_FP" > "${TMP_LOG}.live"
  echo "     1) cp ${TMP_LOG}.live backend/tests/fixtures/business_catalog_fingerprint.txt"
  echo "     2) 把 CANONICAL_BUSINESS_CATALOG_SHA256 改成 ${LIVE_SHA}"
  echo "     3) 重跑本脚本，本 Part 应当全 [PASS]"
  echo ""
  echo "     ⛔ 三方必须同时对齐：只改固件不改常量（或反之），会让"
  echo "        所有'正常路径'在**错的期望**上通过 —— 最难发现的一类假绿。"
  exit 1
fi

# 第二条腿：常量 ↔ 活库
assert_eq "CANONICAL_BUSINESS_CATALOG_SHA256 ↔ 活库指纹 sha256 相等" "$CONST_SHA" "$LIVE_SHA"

# 第三条腿：固件 ↔ 常量（纯 Python 侧也有一条测试钉它，这里一并确认，让三方闭环）
assert_eq "固件 sha256 ↔ 常量 相等（与 test_business_catalog_fixture_matches_the_constant 同判据）" \
  "$FIXTURE_SHA" "$CONST_SHA"

# 本片的核心形状断言：指纹里**不得**再出现 schema_version 的默认值
if printf '%s' "$LIVE_FP" | grep -q '^training_sets\.schema_version='; then
  fail_msg "活库指纹的 --defaults-- 段里仍有 training_sets.schema_version —— schema.sql 的 DEFAULT 没真去掉"
  exit 1
else
  pass_msg "活库指纹里已无 training_sets.schema_version 的默认值记录"
fi

# 反向防空转：别的列的默认值必须**还在**（证明上面那条 grep 不是因为整段 --defaults-- 空了而通过）
if printf '%s' "$LIVE_FP" | grep -q "^training_sets\.status='unsent'::character varying$"; then
  pass_msg "同表其它列的默认值仍在（防空转：上一条不是因为 --defaults-- 整段空了才通过）"
else
  fail_msg "指纹里连 training_sets.status 的默认值都没了 —— 上一条 grep 没有判别力"
  exit 1
fi
```

- [ ] **Step 3: 跑它，确认 Part 4 **红**，并读出活库真值**

```bash
cd "$(git rev-parse --show-toplevel)"
./backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh 2>&1 | tee /tmp/ts1r1-part4-red.log
echo "退出码 = ${PIPESTATUS[0]}"
```

期望：Part 1–3 全 `[PASS]`；Part 4 在「固件原文 ↔ 活库指纹」那一条 **`[FAIL]`**，打印完整 diff，退出码非 0。

⚠️ **diff 必须只有一处**：少掉 `training_sets.schema_version=1` 那一行。
- 若 diff 还有别的行 ⇒ Step 1 的第 2 条预测（注释不进指纹）**被推翻**了，**停下来**先搞清多出来的差异是什么，⛔ 不要直接把新值抄进去。
- 若 diff 为空（Part 4 直接绿）⇒ 说明 `schema.sql` 的改动**没生效**，回 Task 1 查。

```bash
grep -c '^[-+]' /tmp/ts1r1-part4-red.log
grep '^[-+]' /tmp/ts1r1-part4-red.log
```

期望：只有 3 行以 `-`/`+` 开头 —— `--- 固件` 头、`+++ -` 头、以及 `-training_sets.schema_version=1`。

- [ ] **Step 4: 把活库真值写回固件 + 常量**

```bash
cd "$(git rev-parse --show-toplevel)"
LIVE=$(ls -t /var/folders/*/T/tmp.*.live /tmp/tmp.*.live 2>/dev/null | head -1)
echo "活库指纹文件 = $LIVE"
cp "$LIVE" backend/tests/fixtures/business_catalog_fingerprint.txt
NEW_SHA=$(shasum -a 256 backend/tests/fixtures/business_catalog_fingerprint.txt | cut -d' ' -f1)
echo "新常量值 = $NEW_SHA"
```

⚠️ 若 `$LIVE` 为空（临时文件已被 `cleanup` 删掉），直接从红色日志里的 diff 自己改固件：**删掉** `training_sets.schema_version=1` 那一行，⛔ 不要改动任何别的字节、⛔ 不要在末尾补换行：

```bash
cd "$(git rev-parse --show-toplevel)"
"$PY" - <<'PYEOF'
import pathlib
p = pathlib.Path("backend/tests/fixtures/business_catalog_fingerprint.txt")
text = p.read_text(encoding="utf-8")
target = "training_sets.schema_version=1\n"
assert text.count(target) == 1, f"预期恰好 1 处，实际 {text.count(target)} 处 —— 停下来核对"
p.write_text(text.replace(target, ""), encoding="utf-8")
print("已删掉那一行；新字节数 =", len(p.read_bytes()))
PYEOF
NEW_SHA=$(shasum -a 256 backend/tests/fixtures/business_catalog_fingerprint.txt | cut -d' ' -f1)
echo "新常量值 = $NEW_SHA"
```

然后把 `backend/qmt_pilot_db.py:1394` 的 `CANONICAL_BUSINESS_CATALOG_SHA256` 改成打印出来的 `$NEW_SHA`。

- [ ] **Step 5: 重跑脚本，确认 Part 4 由红转绿**

```bash
cd "$(git rev-parse --show-toplevel)"
./backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh 2>&1 | tee /tmp/ts1r1-part4-green.log
echo "退出码 = ${PIPESTATUS[0]}"
```

期望：**全部 `[PASS]`**，退出码 **0**。

⚠️ 这个红（Step 3）→绿（本步）就是 Part 4 的判别力证明 —— 它**确实能报非 0**，不是一段恒绿的装饰。

- [ ] **Step 6: 跑整套后端，确认全绿**

```bash
cd backend && "$PY" -m pytest -q 2>&1 | tail -5
```

期望：`passed`，无 `failed`。特别确认 `test_business_catalog_fixture_matches_the_constant` 绿（固件 ↔ 常量 这条腿）。

- [ ] **Step 7: 提交**

```bash
cd "$(git rev-parse --show-toplevel)"
git add backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh \
        backend/tests/fixtures/business_catalog_fingerprint.txt backend/qmt_pilot_db.py
git commit -m "feat(ts1r1): 活目录指纹三方对齐（rehearse.sh Part 4 + 固件 + 常量）

Part 4 把'常量 ↔ 活库'那条腿真跑了一次 —— 它平时只活在 verify_pilot_two_phase_create.py
的 ㉕ 档里（需要真 PG 的 DSN + asyncpg），而改 schema.sql 改的正是'活库长什么样'。

- 指纹 SQL 运行时从 qmt_pilot_db 取，⛔ 不在脚本里抄副本
- 固件：删掉 training_sets.schema_version=1 一行（DROP DEFAULT 让 pg_attrdef 那条记录消失）
  ⇒ 实测 diff 恰好只有这一处，证明'列注释不进指纹'的预测成立
- CANONICAL_BUSINESS_CATALOG_SHA256 重算
- 判别力已证：改固件前 Part 4 红并打印 diff，改完转绿
- 附反向防空转：别的列默认值必须还在，否则'没有 schema_version'可能只是整段空了"
```

---

## Task 5：顶层 `CONTRACT_VERSION` 1.14 → 1.15（11 个同步点）

**为什么单独一个 Task：** 它纯粹是治理契约的联动，与前四个 Task 的技术内容正交；而且它碰 `docs/governance/m01-*`（**信任边界文件**，除 codex 评审外还需 CODEOWNERS approve），独立成一次提交让审批对象清晰。

**Files:**
- Modify: `backend/qmt_pilot_db.py:827`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift:8`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift:1238`（测试名）、`:1260`（断言）
- Modify: `ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift:52`
- Modify: `docs/governance/m01-schema-versioning-contract.md:29`（顶层 cell）、`:30`（PG 迁移 id cell）、`:50`（裸字面量）、新增一条 bump 记录
- Modify: `kline_trainer_modules_v1.4.md:2239`

**Interfaces:**
- Consumes: Task 2 产出的迁移目录名 `0005_schema_version_fail_closed`（写进矩阵的「PG 迁移 id」cell）
- Produces: 全仓一致的 `"1.15"`。`backend/tests/test_qmt_pilot_db.py:830` 的 `test_contract_version_matches_swift_source_of_truth` 钉 Python ↔ Swift 两边相等

- [ ] **Step 1: 动手前先把命中逐条列出来（⛔ 两种语言都扫）**

⚠️ **这条命令的范围是判据的一部分，我第一版写错过**（实测打印 **118 行**而不是 13 行）。
两个错因，都要知道：

1. **扫了整个 `docs/`** ⇒ 把 `docs/superpowers/specs|plans/` 与 `docs/acceptance/` 下
   **十几份历史文档**里的 `1.14` 全扫进来了。那些是**历史记录**（P3c 那一片的 spec、
   plan、验收清单，记的是「当时把 1.13 升到了 1.14」），改它们等于**篡改历史** ——
   与 `m01:48` 那条历史 bump 记录不改是同一个道理。
2. **`grep -v 'modules_v1\.4'` 把 `kline_trainer_modules_v1.4.md` 整个滤掉了** ——
   那个 `-v` 本意是滤掉**内容**里提到「modules v1.4」的行，但**文件名自己**就含
   `modules_v1.4`，于是要改的那一处（`:2239`）被自己的过滤器吃掉了。

⇒ 正确的枚举**分两条跑**，范围限定在「活的代码/断言」与「活的治理文档」：

```bash
cd "$(git rev-parse --show-toplevel)"
echo "=== (a) 活常量与断言 ==="
git grep -n '1\.14' -- backend/qmt_pilot_db.py ios
echo "=== (b) 活治理文档 ==="
git grep -n '1\.14' -- docs/governance kline_trainer_modules_v1.4.md
```

期望：(a) 打印 **9 行**、(b) 打印 **4 行**，合计 **13 行**，逐条定性如下
（⛔ 把实际输出与本表逐行对账，多一行少一行都要搞清为什么）：

| 行 | 改不改 | 为什么 |
|---|---|---|
| `backend/qmt_pilot_db.py:827` | ✅ 改 | Python 侧常量本体 |
| `docs/governance/m01-…:29` | ✅ 改 | 矩阵顶层 cell |
| `docs/governance/m01-…:48` | ❌ 不改 | 这是 **上一次** bump（1.13→1.14）的历史记录，改它等于篡改历史 |
| `docs/governance/m01-…:50` | ✅ 改 | 过渡态那句话里的**裸字面量**，说「切片二若无人动号那就是 1.15」—— 本片正是动它的那个 PR |
| `ios/…/Models.swift:7` | ✅ 改 | Swift 侧常量本体 |
| `ios/…/ModelsTests.swift:8` | ✅ 改 | 断言 |
| `ios/…/RenderStateBuilderTests.swift:1238` | ✅ 改 | ⚠️ **测试名**里写着「契约仍 1.14」—— 只改断言不改名字会留一个说谎的测试名 |
| `ios/…/RenderStateBuilderTests.swift:1260` | ✅ 改 | 断言 |
| `ios/…/M01MatrixSyncGuardTests.swift:52` | ✅ 改 | 守卫断言（钉矩阵顶层 cell） |
| `ios/…/M01MatrixSyncGuardTests.swift:61` | ❌ 不改 | **人造反例样本**的说明注释，写明「用 1.13→1.14 作素材」 |
| `ios/…/M01MatrixSyncGuardTests.swift:74` | ❌ 不改 | 人造样本里的 bump 记录原文 |
| `ios/…/M01MatrixSyncGuardTests.swift:79` | ❌ 不改 | 人造样本的 `XCTAssertNotEqual` 期望值 |
| `kline_trainer_modules_v1.4.md:2239` | ✅ 改 | 指针句里写着「见 `CONTRACT_VERSION 1.14 / 1.15`」 |

⇒ **9 改 + 4 不改 = 13**（集合等式）。加上矩阵的「PG 迁移 id」cell（`:30`，字面量是 `0004_…` 不含 `1.14`）与**新增**的一条 bump 记录 ⇒ 共 **11 个同步点**。

⚠️ `M01MatrixSyncGuardTests.swift:61/74/79` 这三处**改了会把守卫的自检弄坏**：那个人造样本的全部作用是「数据行是旧值、引用块里出现新值」，用来证明解析器不会被 bump 记录喂饱。它不需要对应一次真实发生过的 bump（第 62–63 行的注释写明了这一点）。

- [ ] **Step 2: 改两个常量本体 + 四处 Swift 断言/测试名**

```bash
cd "$(git rev-parse --show-toplevel)"
sed -i '' 's/^CONTRACT_VERSION = "1\.14"$/CONTRACT_VERSION = "1.15"/' backend/qmt_pilot_db.py
sed -i '' 's/^public let CONTRACT_VERSION = "1\.14"$/public let CONTRACT_VERSION = "1.15"/' \
  ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift
sed -i '' 's/#expect(CONTRACT_VERSION == "1\.14")/#expect(CONTRACT_VERSION == "1.15")/' \
  ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift \
  ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
sed -i '' 's/契约仍 1\.14/契约仍 1.15/' \
  ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
sed -i '' 's/"`\\"1\.14\\"`", "m01 顶层版本行未同步"/"`\\"1.15\\"`", "m01 顶层版本行未同步"/' \
  ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift
```

验证这 6 处都改到了、且三处人造样本**没被动**：

```bash
git grep -n '1\.1[45]' -- backend/qmt_pilot_db.py ios | grep -v '3\.11\.14'
```

期望：
- `qmt_pilot_db.py:827`、`Models.swift:7`、`ModelsTests.swift:8`、`RenderStateBuilderTests.swift:1238` 与 `:1260`、`M01MatrixSyncGuardTests.swift:52` → 全是 `1.15`
- `M01MatrixSyncGuardTests.swift:61`、`:74`、`:79` → 仍是 `1.14`

- [ ] **Step 3: 改 m01 矩阵两个 cell**

`docs/governance/m01-schema-versioning-contract.md:29`：

```
| `CONTRACT_VERSION`（顶层标识） | `"1.14"` | 跨系统或破坏性持久化变更 bump 联动；P2 本地 journal state 的**兼容新增**不联动 |
```
→ 把 `` `"1.14"` `` 改成 `` `"1.15"` ``（其余一字不动 —— Swift 守卫按**整格**比对）。

同文件 `:30`：

```
| PostgreSQL schema（`schema.sql` migration id） | `0004_qmt_price_double_and_coverage` | 任何 PostgreSQL DDL 变更（含加列）；联动顶层 |
```
→ 把 `` `0004_qmt_price_double_and_coverage` `` 改成 `` `0005_schema_version_fail_closed` ``。

⚠️ **这一行没有任何测试钉着**（spec §7：五行矩阵里只有它无人钉，而它恰好是本片要改的那一行）⇒ 只能靠人看 diff。改完**立刻**自查：

```bash
cd "$(git rev-parse --show-toplevel)"
sed -n '28,31p' docs/governance/m01-schema-versioning-contract.md
```

期望：顶层行是 `` `"1.15"` ``、PG 行是 `` `0005_schema_version_fail_closed` ``。

- [ ] **Step 4: 改 m01:50 的裸字面量（订正「那就是 1.15」）**

`:50` 现在写着（节选）：

> ⇒ **切片二必须再 bump 一次顶层**（⚠️ **不得与 `1.14` 共号**；**若期间没有别的 PR 动过顶层号，那就是 `"1.15"`** —— ⛔ 这个数**不是**无条件的：当前主线「划线 P1c 七切片」自带 bump 义务，很可能先把号用掉）：`1.14` = 「产物已升第 2 代、App 尚不支持」，`1.15` = 「App 支持第 2 代」。

把括号里那句与句尾的对照改成：

> ⇒ **切片二必须再 bump 一次顶层**（⚠️ **不得与 `1.14` 共号**。⛔ **`1.15` 已被 TS1-R1 用掉**（2026-10-06，`schema_version` 去默认值，见下方 bump 记录）—— 原文这里写的「那就是 `"1.15"`」**已不再成立**，正是它自己警告过的「这个数不是无条件的」那种情形。切片二的号以**它落地时的实际顶层号**为准，⛔ 不要在这里再写一个具体数字）：`1.14` = 「产物已升第 2 代、App 尚不支持」。

⚠️ 这是一次**订正**，而同一事实有**两份副本**（这里与 `kline_trainer_modules_v1.4.md:2239`）。本仓记过「订正只落在两份等价副本中的一份」这个坑 ⇒ 下一步必须把另一份一起改。

- [ ] **Step 5: 改另一份副本 `kline_trainer_modules_v1.4.md:2239`**

现在是：

```
- [ ] `TRAINING_SET_SCHEMA_VERSION = 2` 双方共享常量（⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地；过渡态的权威定义见 `CONTRACT_VERSION 1.14 / 1.15`）
```

改成：

```
- [ ] `TRAINING_SET_SCHEMA_VERSION = 2` 双方共享常量（⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地；过渡态的权威定义见 `docs/governance/m01-schema-versioning-contract.md` 的 bump 记录。⛔ 此处原写「`CONTRACT_VERSION 1.14 / 1.15`」已失效：`1.15` 于 2026-10-06 被 TS1-R1 用掉，切片二的号以它落地时的实际顶层号为准）
```

核对两份副本都改了：

```bash
cd "$(git rev-parse --show-toplevel)"
git grep -n 'TS1-R1 用掉\|已被 TS1-R1' -- docs/governance kline_trainer_modules_v1.4.md
```

期望：**2 行**（m01 一处、modules 一处）。只有 1 行 ⇒ 漏了一份副本。

- [ ] **Step 6: 在 m01 新增一条 bump 记录**

加在 `:50` 那条记录（2026-09-07 的）**之后**、`**存储表位 速查**` 之前。格式照 2026-07-18 那条（`:40`）：触发条件 / 变更内容 / 是否联动 sub-version / iOS 侧有无改动 / 连带后果。

```markdown
> **bump 记录（2026-10-06，TS1-R1 `schema_version` 去默认值）**：顶层 `CONTRACT_VERSION` `"1.14"` → `"1.15"`。触发 = A 类「影响 DDL / 改既有语义」：PostgreSQL migration `0005_schema_version_fail_closed` —— `training_sets.schema_version` 去掉 `DEFAULT 1`、**保留** `NOT NULL`，并加一条列注释说明「刻意不设默认值」。语义变更在**写入端**：此前漏填该列的 `INSERT` 被 PostgreSQL 静默补成 1（第 2 代产物被标成第 1 代，写入方毫无察觉），此后当场报 `violates not-null constraint`（fail-closed）。PG schema sub-version 同步 `0004_qmt_price_double_and_coverage` → `0005_schema_version_fail_closed`。
>
> 三套 sub-version 里**只有 PostgreSQL schema 动**；训练组 SQLite `PRAGMA user_version`、app.sqlite GRDB migration、Swift 模型版本、P2 journal states **均不变**。**iOS reader 逻辑零改动**（本片不动 `TrainingSessionCoordinator.swift` 的 `expectedSchemaVersion: 1` 与 `DownloadAcceptanceRunner.swift` 的 `TRAINING_SET_SCHEMA_VERSION = 1` —— 那是设计好的过渡态，属切片二），仅版本常量 + 其测试随顶层 bump 改（Swift 侧 4 处：`Models.swift:7` 常量、`ModelsTests.swift:8` 与 `RenderStateBuilderTests.swift:1260` 两条断言、同文件 `:1238` 的**测试名**）。
>
> ⚠️ **本次把 `1.15` 用掉了**。上一条记录（2026-09-07）写「切片二若期间没有别的 PR 动过顶层号，那就是 `"1.15"`」—— 本片就是那个「别的 PR」，故该句已订正。切片二的号以它落地时的实际顶层号为准。
>
> ⚠️ **连带后果**：`backend/qmt_pilot_db.py` 的闸 1 逐字比对 `pilot_meta` 里的 `contract_version`，bump 后**任何带 `"1.14"` 的既有 QMT pilot 库都会被拒**（抛 `schema_fingerprint_mismatch`，提示用 `--reset` 重建）。当前 4b 的 `qmt_fetch.py` 仍零实现、pilot 出货链未投产，风险低。
>
> ⚠️ **另两处快照随 `schema.sql` 的字节一起重算**（不是版本号，但同一次改动的连带项）：P6b 硬门文件 `docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql` 的头注释 md5 与 `training_sets.schema_version` 默认值格；模块常量 `CANONICAL_SCHEMA_SHA256`（`schema.sql` 字节 sha256，`create_pilot_database` 在任何副作用之前硬比对它）与 `CANONICAL_BUSINESS_CATALOG_SHA256`（活目录指纹，由 `0005/rehearse.sh` 的 Part 4 在真 PostgreSQL 上重新生成并三方对齐）。
>
> 详见 `docs/superpowers/specs/2026-10-06-ts1r1-schema-version-fail-closed-design.md`。
```

- [ ] **Step 7: 跑两种语言的测试**

```bash
cd "$(git rev-parse --show-toplevel)/backend" && "$PY" -m pytest -q 2>&1 | tail -5
cd "$(git rev-parse --show-toplevel)/ios/Contracts" && swift test 2>&1 | tail -20
```

期望：后端 `passed` 无 `failed`；Swift 全绿（特别是 `M01MatrixSyncGuardTests` 两条 —— 一条钉矩阵、一条是人造反例的自检）。

⚠️ **只跑后端不够**：本片改了 Swift 常量与 3 个 Swift 测试文件，而 `CONTRACT_VERSION` 是跨语言共享常量。

- [ ] **Step 8: 提交**

```bash
cd "$(git rev-parse --show-toplevel)"
git add backend/qmt_pilot_db.py ios/Contracts docs/governance/m01-schema-versioning-contract.md \
        kline_trainer_modules_v1.4.md
git commit -m "chore(ts1r1): 顶层 CONTRACT_VERSION 1.14 -> 1.15（11 个同步点）

A 类 DDL 触发（migration 0005）。逐条：
- Python  1: qmt_pilot_db.py:827
- Swift   4: Models.swift:7 / ModelsTests.swift:8 / RenderStateBuilderTests.swift:1260 +
             :1238 的**测试名**（只改断言不改名字会留一个说谎的测试名）
- m01     4: 顶层 cell / PG 迁移 id cell(0004->0005) / :50 裸字面量订正 / 新增 bump 记录
- modules 1: :2239 的指针

⛔ M01MatrixSyncGuardTests.swift:61/74/79 刻意不改 —— 那是守卫自检用的**人造反例**样本。
⚠️ :50 与 modules:2239 是同一事实的两份副本，两份一起订正（1.15 已被本片用掉，
   切片二的号以它落地时的实际顶层号为准）。"
```

---

## Task 6：NAS runbook 新增「应用数据库迁移」一节

**为什么必须有这一节：** runbook 用 `schema.sql` 建库（`:434`），而 `schema.sql` 全是 `CREATE TABLE IF NOT EXISTS` ⇒ 对**已经存在**的库什么都不做；且 runbook 里**完全没有「应用 migration」这一步**（`grep -E "forward\.sql|migration"` 零命中）。⇒ 本片合并后，NAS 上那个在跑的库**仍带着 `DEFAULT 1`**，下次跑 P6b 硬门会报 `FAIL-default-drift`（库里有默认值、闸门文件说没有），而那个失败**长得像「部署坏了」**。

**Files:**
- Modify: `docs/runbooks/2026-08-24-qmt-nas-deployment.md`（在 `## P6b` 那一节**之前**插入 `## P6a`）

**Interfaces:**
- Consumes: Task 2 的 `backend/sql/migrations/0005_schema_version_fail_closed/forward.sql`；Task 1 改过的 P6b 快照（新一节的失败提示要与 P6b 的失败标签对得上）
- Produces: runbook 的 P6a 一节。Task 2 的 `README.md` 已经指向它（「见 …deployment.md 的『P6a · 应用数据库迁移』一节」）—— 两处标题必须一致

- [ ] **Step 1: 先确认 runbook 现在真的没有迁移步骤**

```bash
cd "$(git rev-parse --show-toplevel)"
grep -n -E 'forward\.sql|migration|迁移' docs/runbooks/2026-08-24-qmt-nas-deployment.md | head
```

期望：**零命中**，或只命中与数据库迁移无关的词。这证明 spec §4⑥ 描述的缺口真实存在。

- [ ] **Step 2: 在 `## P6b` 之前插入新的一节**

找到 `## P6b · 直接查数据库的**实际形状**（硬门）` 那一行（约第 450 行），在它**之前**插入：

````markdown
## P6a · 应用数据库迁移（**旧库必做，全新空卷可跳过**）

**执行者：Claude**

**什么时候需要这一步：** 上一步（P6）用 `backend/sql/schema.sql` 灌建表脚本，而那份脚本里每一条都是 `CREATE TABLE IF NOT EXISTS` —— 意思是「这张表已经有了就什么都不做」。所以对一个**已经存在的旧库**，P6 实际上**一个字都没改**。表结构的改动要靠「迁移脚本」单独应用。

- **全新空卷**（P6 第一步打印 `VOLUME_ABSENT`）：建库时就已经是新形状，**可以跳过本节**，直接进 P6b
- **复用了旧卷**：**必须做本节**，否则下一步 P6b 会红

> ⛔ **跳过这一步会怎样**：P6b 硬门会报 **`FAIL-default-drift`**（库里 `training_sets.schema_version` 还带着默认值 `1`，而闸门文件说这一列没有默认值）。
> **那不是部署坏了，是迁移没跑。** 看到这个标签先回本节，不要去走 P6-RESET 销毁数据卷。

**第一步，把迁移脚本拷到 NAS**：

```
scp "$(git rev-parse --show-toplevel)/backend/sql/migrations/0005_schema_version_fail_closed/forward.sql" \
    "$NAS:$DIR/sql/0005_schema_version_fail_closed_forward.sql"
```

**第二步，在容器里应用它**：

```
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -U kline -d kline_trainer -v ON_ERROR_STOP=1 -f - < sql/0005_schema_version_fail_closed_forward.sql && echo MIGRATION_0005_OK"
```

- ✅ 通过：打印 `BEGIN` / `ALTER TABLE` / `COMMENT` / `COMMIT`，**且**最后一行是 `MIGRATION_0005_OK`
- ❌ 没看到 `MIGRATION_0005_OK`：**停止**。这条命令自己没跑成，⛔ 别当成「迁移已应用」就往下走

> ⚠️ 必须有 `MIGRATION_0005_OK` 这个哨兵。`-v ON_ERROR_STOP=1` 让 psql 一遇错就非零退出，而 `&&` 保证出错时哨兵**不会**被打印 —— 这与 P6 第一步的 `QUERY_OK` 是同一个套路（「没看到预期输出」绝不能被读成「通过」）。

**第三步，当场确认默认值真的没了**：

```
ssh $NAS "docker exec -i kline-trainer-db-1 psql -U kline -d kline_trainer -tA -c \"SELECT coalesce(column_default, 'NO_DEFAULT') FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';\""
```

- ✅ 通过：打印 `NO_DEFAULT`
- ❌ 打印 `1`：迁移没生效，回第二步看报错，⛔ 不要往下走 P6b

**第四步，进 P6b 硬门**，由它逐条核对完整形状。

> ⚠️ **本节是人工步骤，没有自动化编排** —— 本仓目前没有迁移编排器（没有「记录哪些迁移已经跑过」的表），`0004_qmt_price_double_and_coverage` 也是同样形态。所以「这个库跑过哪些迁移」目前只能靠人记 + 靠 P6b 硬门事后发现形状不对。
>
> ⚠️ **重复执行本节是安全的**：`ALTER COLUMN … DROP DEFAULT` 对一个已经没有默认值的列不报错、不改任何东西（PostgreSQL 的 `DROP DEFAULT` 是幂等的）。所以拿不准「跑过没跑过」时，再跑一次比不跑安全。

> **要回滚怎么办**：同目录有 `rollback.sql`，照第一、二步的写法换个文件名执行即可。本次回滚**无数据风险**（只改列的元数据，不重写任何已有行，已由 `rehearse.sh` 的 Part 3 在真数据库上实证）。⚠️ 但回滚之后 P6b 会反过来报 `FAIL-default-drift` —— 因为闸门文件记的是**新形状**。回滚是「本片的 fail-closed 行为本身导致停机」时的应急手段，不是常规操作。
````

- [ ] **Step 3: 核对三处交叉引用对得上**

```bash
cd "$(git rev-parse --show-toplevel)"
echo "--- runbook 的新节标题 ---"
grep -n '^## P6a' docs/runbooks/2026-08-24-qmt-nas-deployment.md
echo "--- README 指向它的那句 ---"
grep -n 'P6a' backend/sql/migrations/0005_schema_version_fail_closed/README.md
echo "--- P6b 的失败标签里有没有 default-drift ---"
grep -n 'default-drift\|default_drift' docs/runbooks/2026-08-24-qmt-nas-deployment.md \
  docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql
```

期望：
- runbook 有 `## P6a · 应用数据库迁移（**旧库必做，全新空卷可跳过**）`
- README 里那句「见 …deployment.md 的『P6a · 应用数据库迁移』一节」与标题文字一致
- `default-drift` 这个标签在 P6b 的闸门文件或 runbook 的失败标签表里**真的存在**

⚠️ 第三条若零命中 ⇒ 我在新节里写的失败标签是**编的**。那就得改成 P6b 真正会打印的标签名 —— ⛔ 不许在 runbook 里写一个运维永远不会在屏幕上看到的字符串。核实办法：

```bash
grep -n "FAIL-" docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql | sort -u
```

把新节里的标签名改成这里真实存在的那一个（若 P6b 只有一个笼统的 `FAIL` 标签，就把新节的措辞改成「P6b 会在 `training_sets.schema_version` 的**默认值**一列报不吻合」，不编标签名）。

- [ ] **Step 4: 提交**

```bash
cd "$(git rev-parse --show-toplevel)"
git add docs/runbooks/2026-08-24-qmt-nas-deployment.md \
        backend/sql/migrations/0005_schema_version_fail_closed/README.md
git commit -m "docs(ts1r1): NAS runbook 新增 P6a「应用数据库迁移」一节

现状缺口：runbook 用 schema.sql 建库，而那份脚本全是 CREATE TABLE IF NOT EXISTS
⇒ 对已存在的旧库一个字都不改；且 runbook 里原本**完全没有**应用 migration 这一步。
⇒ 本片合并后，NAS 上在跑的库仍带 DEFAULT 1，下次 P6b 会红，而那个失败长得像「部署坏了」。

新节放在 P6b 之前，含：拷脚本 / 应用（带 MIGRATION_0005_OK 哨兵，照 P6 的 QUERY_OK 套路）/
当场查默认值真没了 / 失败标签的归因提示（那不是部署坏了，是迁移没跑）/ 幂等性说明 /
回滚路径。标签名已与 P6b 闸门文件实际会打印的字符串核对过。"
```

---

## Task 7：验收清单 + 整体核验

**Files:**
- Create: `docs/acceptance/2026-10-06-ts1r1-schema-version-fail-closed.md`

**Interfaces:**
- Consumes: Task 1–6 的全部交付物
- Produces: 非程序员可执行的验收清单（CLAUDE.md 治理条款 2 要求）

- [ ] **Step 1: 跑完整的两种语言测试 + 演练脚本，把真实输出留下来**

```bash
cd "$(git rev-parse --show-toplevel)"
(cd backend && "$PY" -m pytest -q 2>&1 | tail -5) | tee /tmp/ts1r1-final-backend.log
(cd ios/Contracts && swift test 2>&1 | tail -20) | tee /tmp/ts1r1-final-swift.log
./backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh 2>&1 | tee /tmp/ts1r1-final-rehearse.log
echo "rehearse 退出码 = ${PIPESTATUS[0]}"
```

⛔ 这三份日志里的**真实数字**要写进验收清单与 PR 描述，**不许**凭印象写。

- [ ] **Step 2: 核验 spec §5 判据 5b —— pilot 建库仍能成功（真走一次建库路径）**

判据 5b 的要点是：`CANONICAL_SCHEMA_SHA256` 那道闸在 `create_pilot_database` 的**任何副作用之前**，⛔ 只跑单元测试不够。

```bash
cd "$(git rev-parse --show-toplevel)/backend"
"$PY" -m pytest tests/test_qmt_pilot_db.py -q -k "canonical or catalog or contract_version" 2>&1 | tail -5
grep -rn "create_pilot_database" tests/test_qmt_pilot_db.py | head -5
```

期望：相关测试全绿。再确认建库路径真的被单测覆盖到（上面 `grep` 要有命中）；若本机有真 PG 环境，额外跑一次 `backend/scripts/verify_pilot_two_phase_create.py`；若没有，**在验收清单与 PR 里明说这一条只验到了单测层**，⛔ 不许写成「已真机验证」。

- [ ] **Step 3: 核验 spec §5 判据 5 —— 现有写入仍能正常工作（防恒拒）**

本片的 fail-closed 只能挡**漏填**，不能挡正常写入。`rehearse.sh` 的 Part 1 ④已经证了「显式给值仍成功」。再确认仓内 `INSERT INTO training_sets` 的写入点都显式给了该列：

```bash
cd "$(git rev-parse --show-toplevel)"
git grep -n "INSERT INTO training_sets" -- backend docs scripts | cut -c1-160
```

期望：每一处要么显式列出了 `schema_version`，要么是散文/测试输出/注释（不是真写入）。⛔ 逐条看过再下结论 —— 本仓记过「N 个调用点 ≠ 语义都一样」。

⚠️ **本片新增的 4 处会出现在这个清单里，而且它们的「值」是 `DEFAULT`**
（`0005/rehearse.sh` 的演练语句，理由见 Global Constraint 5b）。
它们**列出了** `schema_version` ⇒ 文本守卫判合规；而**值是 `DEFAULT`** ⇒ 迁移后它们
会 fail closed —— 这正是演练要证明的事。⛔ 别把它们当成「漏填的生产写入」报上来。
真正写生产库的只有 `backend/generate_training_sets.py` 那一条（守卫的格子锚点 `("backend", ".py")`
就是钉它的），它显式给的是真实代号，不是 `DEFAULT`。

另外跑一次「值是不是 DEFAULT」的对账，把两类分开看：

```bash
cd "$(git rev-parse --show-toplevel)"
echo "--- 列清单含 schema_version 且值写 DEFAULT 的（应当只有 0005/rehearse.sh 的 4 条）---"
git grep -n "schema_version, file_path, content_hash)" -- backend | cut -c1-120
```

- [ ] **Step 4: 核验 spec §5 判据 6 —— 改动面集合等式**

```bash
cd "$(git rev-parse --show-toplevel)"
git diff --name-status origin/main...HEAD | sort
```

期望**恰好**下表这 20 个（⛔ 集合等式，多一个少一个都算不通过）。
⚠️ 前两行是 spec 与本计划自身；本分支在实施开始前相对 `origin/main` 只有 **1 个**改动（spec 文档，已实测 `git diff --name-status origin/main...HEAD` 确认），计划文档是实施期间加的第 2 个。

| 状态 | 文件 | 来自 |
|---|---|---|
| A | `docs/superpowers/specs/2026-10-06-ts1r1-schema-version-fail-closed-design.md` | spec 阶段 |
| A | `docs/superpowers/plans/2026-10-06-ts1r1-schema-version-fail-closed.md` | 本计划 |
| M | `backend/sql/schema.sql` | Task 1 |
| M | `backend/qmt_pilot_db.py` | Task 1 + 4 + 5 |
| M | `docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql` | Task 1 |
| M | `backend/tests/test_schema.py` | Task 1 |
| A | `backend/sql/migrations/0005_schema_version_fail_closed/forward.sql` | Task 2 |
| A | `backend/sql/migrations/0005_schema_version_fail_closed/rollback.sql` | Task 2 |
| A | `backend/sql/migrations/0005_schema_version_fail_closed/README.md` | Task 2 |
| A | `backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh` | Task 3 + 4 |
| M | `backend/tests/test_migrations.py` | Task 2 + 3 |
| M | `backend/tests/fixtures/business_catalog_fingerprint.txt` | Task 4 |
| M | `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | Task 5 |
| M | `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift` | Task 5 |
| M | `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift` | Task 5 |
| M | `ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift` | Task 5 |
| M | `docs/governance/m01-schema-versioning-contract.md` | Task 5 |
| M | `kline_trainer_modules_v1.4.md` | Task 5 |
| M | `docs/runbooks/2026-08-24-qmt-nas-deployment.md` | Task 6 |
| A | `docs/acceptance/2026-10-06-ts1r1-schema-version-fail-closed.md` | Task 7 |

Step 4 的期望就是「`git diff --name-status origin/main...HEAD | sort` 的输出与上表**逐行相等**」。

- [ ] **Step 5: 写验收清单**

`docs/acceptance/2026-10-06-ts1r1-schema-version-fail-closed.md`。⛔ 每一条的「动作」必须是**非程序员照着就能做**的，「期望」必须是**屏幕上能看见的具体文字**，⛔ 禁止「正常」「没问题」「符合预期」这类没法判定的措辞。

```markdown
# TS1-R1 验收清单 · `schema_version` 漏填必须当场失败

**这一片做了什么（一句话）**：数据库里存训练组的那张表有一列叫「产物代号」，以前漏填它会被数据库悄悄填成 1（第 1 代），现在漏填会直接报错。

**怎么用这份清单**：从上往下一条条做。每条都写了「你要敲什么」和「屏幕上应该出现什么」。只要有一条对不上，就在「通过与否」里写「否」并把屏幕上的实际输出贴在后面，⛔ 不要自己猜原因、不要跳过往下做。

**需要准备**：一台装了 Docker Desktop 并且**已经启动**的 Mac（第 2–4 条要用）。没有 Docker 的话第 2–4 条做不了，在「通过与否」里写「做不了（无 Docker）」，其余条目照做。

| # | 动作（照着敲） | 期望（屏幕上出现） | 通过与否 |
|---|---|---|---|
| 0 | 先敲这一行（每开一个新终端都要）：`export PY="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)/.venv/bin/python"`，再敲 `"$PY" -c "import pglast, pytest; print('OK')"` | 打印 `OK`。⚠️ 这一步是必须的：这份代码所在的目录里**没有** Python 环境，直接敲 `python` 会说「找不到命令」 | |
| 1 | 敲 `cd backend && "$PY" -m pytest -q`，等约 4 分钟 | 最后一行是 **`1729 passed`**，**没有** `failed`、**没有** `error`。（实施前的基线是 `1720 passed`，这一片新增 9 条测试）。⚠️ 数字不是 1729 时**不要**自己判断「差不多就行」，照实写下实际数字 | |
| 1b | 回到项目根目录，敲 `cd ios/Contracts && swift test`，等它跑完（苹果端的测试不需要上面那个 `$PY`）| 最后出现 `Test run with N tests passed`（或等价的全绿字样），**没有** `failed`。⚠️ **只做第 1 条不够** —— 这一片改了 4 个苹果端（Swift）文件，其中 3 个是测试 | |
| 2 | 在项目根目录敲 `./backend/sql/migrations/0005_schema_version_fail_closed/rehearse.sh` | 每一行都是 `[PASS]`，**没有** `[FAIL]`；最后一行形如 `[PASS] 全部断言通过，共 N 条。`。⚠️ 没装/没启动 Docker 时第一行就是 `[FAIL] 未检测到 docker`，那不是本片的问题，先把 Docker 启动 | |
| 3 | 在第 2 条的输出里找这一行 | `[PASS] 迁移后：漏填 schema_version 的写入**被拒**（确由 [violates not-null constraint] 拒绝）` —— 这就是本片的**核心目的**：漏填当场失败 | |
| 3b | 在第 2 条的输出里找这一行 | `[PASS] 报错信息点名了 schema_version（运维不用猜是哪一列）` —— 报错必须说清是哪一列，否则出事时要靠人猜 | |
| 4 | 在第 2 条的输出里找这一行 | `[PASS] 迁移后：显式写 schema_version=2 仍成功（正向对照，证明不是恒拒）` —— 这证明我们没把写入**全部**挡掉，只挡了漏填 | |
| 4b | 在第 2 条的输出里找这一行 | `[PASS] 升降级一圈之后**整张表的内容指纹**逐字节不变 ⇒ rollback 确实无数据损失` —— 说明「改回去」不会弄丢数据 | |
| 4c | 在第 2 条的输出里找这一行 | `[PASS] 活库指纹里已无 training_sets.schema_version 的默认值记录` —— 说明数据库自己确认了默认值真的没了 | |
| 4d | 在第 2 条的输出里找这三行 | `[PASS] 阶段1 …`、`[PASS] 阶段2 …`、`[PASS] 阶段3 …`（都以「两种写法的退出码与错误身份逐字相同」结尾）。⚠️ 并且**阶段 2 那一组的退出码必须是 1**（两行都是 `退出码 1`）—— 这一组是整个演练的地基：它证明演练里写的 `DEFAULT` 跟「真的漏填」是一回事 | |
| 4e | 敲 `cd backend && "$PY" -m pytest tests/test_insert_schema_version_guard.py -q` | `3 passed`。这是仓库里一道**已有**的检查：它要求所有会被执行的写入语句都必须写明「产物代号」这一列。本片新加的演练脚本必须让它继续是绿的 | |
| 5 | 在项目根目录敲 `git diff --name-status origin/main...HEAD \| sort` | 输出的文件列表与本片实施计划 Task 7 Step 4 那张表**逐行相同**。多一个文件或少一个文件都算不通过 | |
| 6 | 在项目根目录敲 `git grep -n '1\.14' -- backend ios \| grep -v '3\.11\.14'` | **只有 3 行**，都在 `M01MatrixSyncGuardTests.swift`（第 61、74、79 行）。那三行是故意留的「反面例子」，用来证明检查程序不会被骗。⛔ 若 `backend/qmt_pilot_db.py` 或 `Models.swift` 还出现 `1.14`，说明版本号漏改了 | |
| 7 | 在项目根目录敲 `sed -n '28,31p' docs/governance/m01-schema-versioning-contract.md` | 「顶层标识」那一行的版本是 `` `"1.15"` ``；「PostgreSQL schema」那一行是 `` `0005_schema_version_fail_closed` ``。⚠️ **第二行没有任何自动检查盯着它**，只能靠眼睛看，所以这一条要特别仔细 | |
| 8 | 在项目根目录敲 `git grep -n '已被 TS1-R1' -- docs/governance kline_trainer_modules_v1.4.md` | **恰好 2 行**（一行在 m01、一行在 modules 文档）。这是同一句订正的两份副本，只改一份就会留下一份说谎的旧文字 | |

## 本片**明确没做**的事（⛔ 别把这些当成缺陷报）

| 没做什么 | 为什么 |
|---|---|
| 没重建仓库里那 3 个「第 1 代」训练组产物 | 那是另一片（P4）的事。本片的改动只影响**以后**的写入，不动已经存在的数据 |
| 没改手机端那两个写死的「第 1 代」 | 那是**设计好的过渡态**，属切片二。⛔ **合并本片 ≠ 手机能用了** |
| 没检查「产物代号填的值对不对」 | 本片只让**漏填**失败。写 `schema_version = 99` 仍会被接受 —— 要钉死取值范围是另一条判据 |
| 没给版本矩阵加一致性检查 | 那属于「治理/工具变更」，按仓库规则要单独立项走自己的流程。所以第 7 条只能靠眼睛看 |

## 还需要人工做的一步（合并之后）

NAS 上那台在跑的数据库**不会自动改过来**。合并之后要照
`docs/runbooks/2026-08-24-qmt-nas-deployment.md` 的 **P6a** 一节手动应用迁移。
⛔ 跳过那一步，下次跑 P6b 检查会报错，而那个报错**长得像「部署坏了」**，实际是「迁移没跑」。
```

- [ ] **Step 6: 提交**

```bash
cd "$(git rev-parse --show-toplevel)"
git add docs/acceptance/2026-10-06-ts1r1-schema-version-fail-closed.md
git commit -m "docs(ts1r1): 非程序员可执行的验收清单（CLAUDE.md 治理条款 2）

13 条，每条都是「照着敲什么 / 屏幕上出现什么」。
含 4 条「明确没做」（库存产物 / App 侧过渡态 / 不校验取值 / 矩阵一致性检查）——
防止把刻意的范围外当成缺陷报；
含合并后必做的人工步骤（NAS 的 P6a 应用迁移），并写明跳过的症状会被误读成部署坏了。"
```

---

## Self-Review

**1. Spec 覆盖逐节对账**

| spec 节 | 实现在 | 备注 |
|---|---|---|
| §4① `schema.sql` 去默认值 + 列注释 | Task 1 Step 5 | 注释原文逐字抄自 spec |
| §4② 迁移 0005 四件套 | Task 2（forward/rollback/README）+ Task 3（rehearse.sh） | 目录名 `0005_schema_version_fail_closed`；PG 系列此前只有 0004，0005 空号可用 |
| §4③ rehearse.sh 三个 Part | Task 3 Part 1–3 + 前置探针 | ⚠️ 另加 Part 4 与前置探针，两处都在「对 spec 的声明性偏离」一节明写理由 |
| （spec 未覆盖）已合并文本守卫的兼容性 | Global Constraint 5 / 5b + Task 3 Step 3b | ⚠️ **spec 没预见到这一条**；codex 对 plan 第 1 轮的 [high] finding，已实测坐实 |
| §4④ 两道闸门 + 两份哈希 + 一份指纹 | Task 1 Step 7（P6b 两处 + `CANONICAL_SCHEMA_SHA256`）+ Task 4（指纹固件 + `CANONICAL_BUSINESS_CATALOG_SHA256`） | 次序约束兑现：`schema.sql` 在 Task 1 Step 5 定稿，三样哈希全在其后 |
| §4④ 三方互钉 | Task 4 Part 4 的三条腿断言 | 第三条腿（常量↔活库）此前只活在跑不起来的 ㉕ 档里 |
| §4⑤ 11 个 bump 同步点 | Task 5 | Step 1 的 13 行命中表做了「9 改 + 4 不改」的集合等式 |
| §4⑥ NAS runbook 新增一节 | Task 6 | 放在 P6b **之前**；含「那不是部署坏了，是迁移没跑」的归因提示 |
| §4⑦ 三类测试 | Task 1（test_schema.py 3 条）+ Task 2（test_migrations.py 6 条）+ Task 3（CJK 守卫扩到两个目录） | md5 锚那条漏在 Task 1 Step 3 封上 |
| §5 判据 1 / 1b | Task 7 Step 1 + 验收清单 1 / 1b | |
| §5 判据 2 | Task 3 Step 4 + 验收清单 2 | |
| §5 判据 3 | rehearse.sh Part 1 ③ + ③b + 验收清单 3 / 3b | ③b（报文点名该列）是本计划加的 —— 「报错不点名列」在真出事时等于让人猜 |
| §5 判据 4 | ⚠️ **见下方「一处与 spec 的判据差异」** | |
| §5 判据 5 | Task 7 Step 3 + rehearse.sh Part 1 ④ | |
| §5 判据 5b | Task 7 Step 2 | ⚠️ 若本机无真 PG，必须明说只验到单测层 |
| §5 判据 6 | Task 7 Step 4 的 20 行集合等式 + 验收清单 5 | |
| §6 明确不做（4 条） | Global Constraints 2 / 3 / 5 + 验收清单的「明确没做」表 | |
| §7 已知局限（含矩阵 backlog） | Global Constraints 4 + 验收清单「明确没做」表 | ⛔ 不加矩阵一致性测试 |

**2. 一处与 spec 的判据差异（请评审者裁决）**

spec §5 判据 4 是「**造一条表名来自变量的漏填写入** → 同样被 DB 拒」，用来证明本片相对文本守卫的增量价值（守卫对动态表名只能说「判不了」，DB 判对了）。

本计划**没有**把它放进 `rehearse.sh`，理由：从 psql 的角度，`INSERT INTO training_sets …` 和「宿主语言用变量拼出表名再发过来的那条 SQL」**是同一条字节序列** —— 数据库看不到宿主语言。在 bash 里写 `T=training_sets; psql -c "INSERT INTO $T …"` 跑出来与 Part 1 ③**完全一样**的报错，它证明的是 bash 会做变量替换，不是数据库多判对了什么。本仓记过「断言必须落在真正的判据上，不能测标准库」。

⇒ 本计划把这条判据改为**验收清单里的一段说明**（不是一条可执行判据），措辞是：「本片的增量价值在于判据从**宿主语言的文本**搬到了**数据库**：无论写入方用什么语言、表名是写死的还是拼出来的，数据库看到的都是同一条 SQL，所以它一视同仁。文本守卫对拼出来的表名只能报『判不了』」。

⛔ 如果评审认为这条判据必须可执行，我的建议是**不要**在 bash 里造，而是在 `backend/tests/` 里加一条「用 `psycopg`/`asyncpg` 以变量拼表名发一条漏填 INSERT」的测试 —— 但那需要真 PG，本仓的后端测试套件刻意不依赖 Docker（`test_migrations.py` 的文件头注释写明了这一点）⇒ 那条测试在 CI 里会 skip，而本仓**禁止 skip**。这就是我选「改成说明」的原因，请裁决。

**3. 占位符扫描**

已逐 Task 搜过 `TBD` / `TODO` / `implement later` / `类似 Task N` / 「适当的错误处理」/「补充测试」：**零命中**。每个需要代码的 Step 都带完整可运行代码块；每个哈希/指纹的新值都来自 Step 里**实际打印**的命令输出，没有一处写死猜测值。

**4. 类型与命名一致性**

- `MIG_0005` 常量名在 Task 2 Step 1 定义，Task 2/3 的测试一致使用
- 迁移目录名 `0005_schema_version_fail_closed` 在 Task 2（建目录）、Task 3（`PRE_MIGRATION_SHA` 所在脚本路径）、Task 5 Step 3（矩阵 cell）、Task 6 Step 2（runbook 的 scp 路径）四处一致
- `rehearse.sh` 的辅助函数名 `pass_msg` / `fail_msg` / `assert_eq` / `assert_rejects` / `pg_query` / `pg_exec` / `pg_run_file` 在 Task 3 定义、Task 4 的 Part 4 复用，拼写一致
- runbook 新节标题 `P6a · 应用数据库迁移` 与 Task 2 README 里指向它的那句一致（Task 6 Step 3 有专门的核对步骤）
- 列注释原文「产物代号。⛔ 刻意不设默认值：漏填必须当场失败，不能被静默标成第 1 代。」在 Task 1 Step 5（schema.sql）、Task 2 Step 3（forward.sql）、Task 3 的 rehearse.sh Part 1 断言 三处逐字相同

**5. 本计划自己埋的三个「别踩」提示**

1. **Task 1 Step 9 的次序警告**：变异验证要用 `git checkout --` 恢复，所以**必须先提交**再变异。初稿把 Step 9/10 写反了，已在 Step 9 里明写「本步要在 Step 10 之后执行」并要求以 `git status --short` 无输出收尾。（本仓记过「复原别用 `git checkout <file>`」会毁掉未提交的工作。）
2. **Task 4 Step 3 的「diff 必须只有一处」**：若 diff 有别的行，说明「列注释不进指纹」这个预测被推翻 ⇒ **停下来**，⛔ 不许把新值直接抄进去。
3. **Task 6 Step 3 的标签名核实**：runbook 里写的 `FAIL-default-drift` 必须是 P6b **真的会打印**的字符串，否则是在给运维编一个他永远看不到的提示。
