# QMT 4a-2b 切片 S3：`init_cluster_marker` 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> 每个 Task 内部必须走 superpowers:test-driven-development：**先写测试 → 亲眼看红 → 再实现 → 看绿**。
> 宣称完成前走 superpowers:verification-before-completion。

**Goal:** 把 4a-2b 唯一还欠 main 的生产符号 `init_cluster_marker` 落地 —— `--init-cluster-marker` 的幂等语义（已合法则直接成功／旧版本部分初始化则补建／标记非法则拒）＋ 孤儿 `pilot_create_intent` 行清理（判据「超期 OR 库不存在」在 **advisory lock 内、由同一条 SQL 当下求值**）。做完 4a 全部闭合。

**Architecture:** 纯增量 —— 在 `backend/qmt_pilot_db.py` 末尾新增一个公开 async 函数 `init_cluster_marker` 及其五条私有 SQL 常量与一个规范哈希常量；另把已存在的 `_MAINTENANCE_SHAPE_SQL` 里那条**跨三张表**的耐久性判据拆成**每表一条**（它是新函数「只对在场的表求值」的前缀归属机制的前提）。函数分两段：**① 零副作用预检 → ② 才允许动 DDL**。孤儿清理排在最后，逐行取锁、锁内原子求值、取了就还。

**Tech Stack:** Python 3.11 / asyncpg（生产代码只接受已连好的 conn，模块自身不做文件 IO、不取锁）/ pytest（host 假件层）/ 真 PostgreSQL 验收脚本 `backend/scripts/verify_pilot_db_lifecycle.py`。

---

## Global Constraints

以下逐条来自 spec `docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 与本仓已立的守则，**每个 Task 的要求都隐含包含本节**：

- **一切守卫用 `if/raise`，绝不用 `assert`**（`python -O` 会剥掉它）。
- **一切「证明不了」等价于「拒绝」**，绝不 `try/except: continue`。
- **本模块不做文件 IO**：`cluster_schema_sql` 由调用方传入；模块只钉它的 sha256。
- **所有表引用必须 `public.` schema 限定**（O4-R4-C1）：不限定时由 `search_path` 决定读/写哪张。
- **本模块不自己取 advisory lock**（spec O1-F4：同 session 可重入，模块另开连接会自锁）；锁由调用方回调注入，**但取了就必须还**（R5-F2）。
- **副作用严格排在证明之后**（R5-F1 / R8-F1）：`cluster_schema_sql` 直接在**维护库**上执行，`--maintenance-dsn` 指错到生产库时先建表再拒绝 = 已经在别人库里落下三张表。
- **`--init-cluster-marker` 的「谁写／谁读／谁清」**：它写标记；闸 (i) 每次运行读；**本工具从不清标记**（清除是人工动作）。孤儿 intent 行**只在这里清**。
- **验收断言必须看数据库状态**（成功后表里真的没有该行），**不能只断言「发过一条 DELETE」**（R9 那次回归就是因为没人看 DELETE 匹配了几行）。
- **一族全是「应该被拒」的档，必须配一条「健康输入必须被放行」的正向档**。
- **变异验证由控制者亲跑**：中和某条判据 → 看**具名的那一条**变红 → 用 `cp` 复原（**绝不用 `git checkout`**）。
- 常量 `INTENT_TTL_SECONDS = 24 * 3600`（已在 main），孤儿新鲜度**只认库自己的时钟** `inserted_at`（O4-R23-C1），**不认**调用方传的 `created_at`。

### 工作区与命令（已实测）

```
worktree : /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4a2b-s3
branch   : feat/qmt-4a2b-s3-cluster-marker   （从 origin/main = 8578a59 切出）
venv     : export PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"   ← 在主仓，引用处必须带引号
```

**每条命令都要同时打印 branch 与 HEAD**：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4a2b-s3" && echo "BRANCH=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)"
```

**基线（2026-08-14 在 `8578a59` 上实测）**：

| 闸门 | 基线 |
|---|---|
| `"$PY" -m pytest backend/tests -q` | **770 passed** |
| 真 PG `verify_pilot_db_lifecycle.py` | **41 档** |
| 真 PG `verify_pilot_concurrency.py` | **11 档** |
| 真 PG `verify_pilot_two_phase_create.py` | **28 档** |

**判绿读输出内容，不要用 `tail`**（脚本末尾是免责说明）：

```bash
"$PY" backend/scripts/verify_pilot_db_lifecycle.py 2>&1 | grep -E "档断言全部成立|FAIL|❌"
```

真 PG 三脚本每次都要带 `QMT_VERIFY_ALLOW_DESTRUCTIVE=1`，非本地再加 `QMT_VERIFY_ALLOW_REMOTE=1`；容器 `docker start qmt-pg-r8 qmt-pg-r8b`；退出码 8 = 同集群已有同前缀验收在跑，9 = 固定名角色运行前就存在。

### ⚠️ 参考实现的使用纪律

参考实现在 **`feat/qmt-plan4a-2b-destructive`**（#161 分支，worktree `.dev/worktree/qmt-plan4a-2`），`backend/qmt_pilot_db.py` 的 `init_cluster_marker`（约 L2845 起）。

> **交接单里的一处口径已核实并更正**：`feat/qmt-4a2b-s2-destructive-core` @ `e038bc0` **没有** `init_cluster_marker`（只有一句注释提到它）；真正的参考源是 `feat/qmt-plan4a-2b-destructive`。

**当参考读，不当模板抄**：那条分支上还有 `authorize_reset` / `_mint_authorization` / `_drop_pilot_database` 三个**已被 S2 故意删掉**的符号，而 main 上新增了 `_assert_reset_gates_on` / `_has_qualified_intent_row` / `_restore_seal`。本计划里的代码块已按 main 的当前形状校对过，**以本计划为准**。

### ⚠️ 档号约束

`verify_pilot_db_lifecycle.py` 的 `_EXPECTED_SCENARIOS` 当前 41 档，已占号：

```
①②③④⑥⑦⑧⑨⑨b⑨c⑩⑪⑫⑬⑭⑮⑯⑰⑰b⑱⑲⑳⑳b㉑㉒㉓㉔㉕㉖㉗㉛㉝㉝b㉝c㉘㉜㉜b㉞㉞b㉟㉟b
```

S1 实施时新造三档并占用了 **㉕㉖㉗**。参考分支的「孤儿删除锁内原子求值」用的是**旧 ㉖**，与 main 的 ㉖（凭据表清场只删点名的库名）**直接相撞** → 本计划给它**另编新号 ㊱**。其余四档 **⑤ / ⑤b / ㉙ / ㉚** 在 main 上确认空闲，沿用参考的号。

**S3 完成后 `_EXPECTED_SCENARIOS` = 46 档。**

---

## File Structure

| 文件 | 责任 | 本次改动 |
|---|---|---|
| `backend/qmt_pilot_db.py` | 护栏模块（纯 DB，零文件 IO） | 拆 `_MAINTENANCE_SHAPE_SQL` 的耐久性判据为每表一条；新增 `CANONICAL_CLUSTER_SCHEMA_SHA256`、`_WRITE_MARKER_SQL`、`_MAINTENANCE_PRESENCE_SQL`、`_MAINTENANCE_SHAPE_OWNER`、`_LIST_ALL_INTENT_SQL`、`_DELETE_ORPHAN_INTENT_SQL`、`async def init_cluster_marker` |
| `backend/tests/test_qmt_pilot_db.py` | L1 假件层单测（验控制流与形状，不验语义） | 更新 `_OK_MAINTENANCE_SHAPE` 与闸 (i) 参数化表；`_FakeConn` 新增 `maintenance_presence`；新增 `_InitMaint` / `_orphan` / `_locker` / `_init` / `_marker_writes` / `_deletes` 辅助 + 约 28 条 init 用例 |
| `backend/scripts/verify_pilot_db_lifecycle.py` | 真 PG L2 验收（验假件验不了的语义） | 新增 5 档：⑤ ⑤b ㉙ ㉚ ㊱ |
| `backend/sql/pilot_cluster_schema.sql` | 【维护库专用表集合】DDL | **零改动**（已与参考分支逐字节相同；sha256 = `d9167bcc…3985`，已实算确认） |

---

## Task 1：把 `pilot_cluster_schema.sql` 钉成规范文件

**为什么先做这个**：`init_cluster_marker` 的**第一条**判据（也是唯一一条纯函数、零查询的判据）就是「递进来的 DDL 必须逐字节等于仓库那份」。4a-1 给 `schema.sql` 与 `pilot_schema.sql` 各钉了规范哈希，唯独这份漏了 —— 而它是唯一会直接在**维护库**上执行的 DDL：一份漂移/敌意的文件可以 `DROP`/`TRUNCATE` 掉 marker / intent / registry 三张表，而随后的结构判据**只看形状不看行**，被清空的恢复凭据与归属登记一条都发现不了。

**Files:**
- Modify: `backend/qmt_pilot_db.py`（在 `CANONICAL_PILOT_SCHEMA_SHA256` 之后，约 L1261 附近）
- Test: `backend/tests/test_qmt_pilot_db.py`（追加到文件末尾）

**Interfaces:**
- Produces: `CANONICAL_CLUSTER_SCHEMA_SHA256: str` —— Task 3 的第一条判据要用。

- [ ] **Step 1: 写失败的测试**

追加到 `backend/tests/test_qmt_pilot_db.py` 末尾：

```python
# ---------------------------------------------------------------------------
# init_cluster_marker —— 幂等语义 + 孤儿 intent 行清理（spec §4 + O4-F7 + O4-F2 修正③）
# ---------------------------------------------------------------------------

# ⚠️ **必须是仓库里那份真文件**：init 把 `cluster_schema_sql` 钉到
#    `CANONICAL_CLUSTER_SCHEMA_SHA256`，随手编一段 DDL 过不了那道闸 ——
#    而这正是它的意义：递进来的 DDL 会直接在**维护库**上执行。
_CLUSTER_SQL = (_SQL_DIR / "pilot_cluster_schema.sql").read_text(encoding="utf-8")


def test_canonical_cluster_schema_hash_matches_the_repo_file():
    """防漂移：改了 `pilot_cluster_schema.sql` 而没更新常量，这颗钉子当场变红
    （与 4a-1 给另外两份 schema 立的钉子同族）。"""
    import qmt_pilot_db as m
    actual = m.sha256_of_sql(
        (_SQL_DIR / "pilot_cluster_schema.sql").read_text(encoding="utf-8"))
    assert actual == m.CANONICAL_CLUSTER_SCHEMA_SHA256, (
        f"pilot_cluster_schema.sql 变了：实算 {actual!r}，"
        f"常量 {m.CANONICAL_CLUSTER_SCHEMA_SHA256!r}")


def test_canonical_cluster_schema_file_stays_non_destructive():
    """反向断言：那份文件本身只许有 `CREATE TABLE IF NOT EXISTS`。

    光钉哈希挡不住「有人既改了文件、又顺手更新了常量」——而这份 DDL 跑在维护库上，
    一句 DROP/TRUNCATE 就能把恢复凭据与归属登记清空。
    """
    text = (_SQL_DIR / "pilot_cluster_schema.sql").read_text(encoding="utf-8")
    code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("--"))
    for banned in ("DROP ", "TRUNCATE", "DELETE ", "ALTER "):
        assert banned not in code.upper(), f"规范集群 schema 里出现破坏性语句 {banned!r}"
    assert code.upper().count("CREATE TABLE IF NOT EXISTS") == len(MAINTENANCE_TABLES), \
        "建表条数与【维护库专用表集合】对不上"
```

- [ ] **Step 2: 跑测试确认变红**

```bash
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "canonical_cluster_schema" -q
```

预期：`test_canonical_cluster_schema_hash_matches_the_repo_file` **FAIL**，`AttributeError: module 'qmt_pilot_db' has no attribute 'CANONICAL_CLUSTER_SCHEMA_SHA256'`。
`test_canonical_cluster_schema_file_stays_non_destructive` 这一条**开局就该是绿的**（它只读文件，不依赖新常量）——这符合「守卫必须在当前树上就是绿的」那条守则，它钉的是**未来**别把破坏性语句加进那份 .sql。

- [ ] **Step 3: 写最小实现**

在 `backend/qmt_pilot_db.py` 的 `CANONICAL_PILOT_SCHEMA_SHA256 = "8d018f98…"` 那一行之后插入：

```python
# ⚠️ **`pilot_cluster_schema.sql` 同样必须钉字节**：4a-1 给 schema.sql 与
#    pilot_schema.sql 各钉了规范哈希，唯独这份漏了 —— 而它是 `--init-cluster-marker`
#    直接拿去在**维护库**上执行的 DDL。不钉的话，一份漂移/敌意的文件可以
#    DROP/TRUNCATE 掉 marker / intent / registry 三张表，而随后的结构判据
#    **只看形状不看行**，被删掉的 intent/登记行它一条都发现不了 ——
#    于是恢复凭据与归属登记被静默清空，集群照样被判成「初始化成功」。
#    （spec §4 P1r3-F9 删掉的是**存进集群里**的 `cluster_schema_sha256` —— 那是因为
#      集群里没有地方存、无对照物；**模块常量**是另一回事，与上面两个同族。）
CANONICAL_CLUSTER_SCHEMA_SHA256 = (
    "d9167bcc3c8ebea784fc9ae8968f12e41614919947e5f601b500bbdd76db3985")
```

> 该值已在本 worktree 实算确认：`sha256(backend/sql/pilot_cluster_schema.sql)` = `d9167bcc3c8ebea784fc9ae8968f12e41614919947e5f601b500bbdd76db3985`。若 Step 2 报的实算值与此不符，**以测试打印的实算值为准**并核对 .sql 是否被动过。

- [ ] **Step 4: 跑测试确认变绿**

```bash
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "canonical_cluster_schema" -q
```
预期：**2 passed**。

- [ ] **Step 5: 变异验证（控制者亲跑）**

```bash
cp backend/qmt_pilot_db.py /tmp/s3_t1_backup.py
# 把常量末位改掉一个字符（例：…3985 → …3986）
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "canonical_cluster_schema_hash" -q
# 预期：FAIL，且失败信息里打印出实算值与常量值
cp /tmp/s3_t1_backup.py backend/qmt_pilot_db.py
```
**绝不用 `git checkout` 复原**（会静默抹掉未提交改动）。

- [ ] **Step 6: 全量 host 闸门**

```bash
"$PY" -m pytest backend/tests -q 2>&1 | grep -E "passed|failed|error"
```
预期：**772 passed**（基线 770 + 2）。

- [ ] **Step 7: Commit**

```bash
git add backend/qmt_pilot_db.py backend/tests/test_qmt_pilot_db.py
git commit -m "S3 Task1：把 pilot_cluster_schema.sql 钉成规范文件（哈希常量 + 非破坏性反向断言）"
```

---

## Task 2：耐久性判据拆成**每表一条**

**为什么必须先拆**：`_MAINTENANCE_SHAPE_SQL` 当前那条耐久性判据是一个**跨三张表的 count**，别名 `maintenance_tables_durable`。Task 3 的零副作用预检要「**在场的表必须自己合规（否则零 DDL 拒绝），缺席的才交给 DDL 补建**」，靠的是判据名前缀（`marker_` / `intent_` / `registry_`）归属到具体某张表。一个跨表的 count **归因不到任何一张表**，于是**混合态**（marker 在场但 UNLOGGED + intent/registry 缺席）会漏过预检 → `_needs_repair_ddl` 为真 → **DDL 先落地**建出两张表，之后才由建库**后**的形状检查拒绝 —— 在一个最终被拒的维护库里留下了表，正是「① 零副作用预检 → ② 才允许动 DDL」这条契约要防的那一档（`--maintenance-dsn` 指错到生产库）。

**⚠️ 判别力交代（诚实说明）**：本 Task 的两条 host 断言里，
- `test_shape_fakes_cover_every_predicate`（现有，L3297 附近）**有**判别力：它对**真 SQL 文本**做 `re.findall(r"AS ([a-z_]+)")` 与假件权威副本比对，别名没拆就变红；
- 闸 (i) 的参数化表（现有，L1488 附近）加三条 `*_durable` 档**没有**判别力：`_FakeConn.fetchrow` 把 `self.maintenance_shape` 整个字典交回，`assert_cluster_allowed` 做的是 `all(shape.values())` —— 假件里有什么键就判什么键，与真 SQL 的别名无关。**加它们是为了让假件与 SQL 保持一一对应**（漏建模一条判据，对应用例就在恒真上空转），判别力由上面那条机械守卫和 Task 3 的行为用例提供。

真正证明这条拆分的**行为**用例是 Task 3 的 `test_init_rejects_mixed_state_present_but_non_durable_plus_absent_table`，真 PG 侧由 Task 5 的档 ⑤b 坐实。

**Files:**
- Modify: `backend/qmt_pilot_db.py:558-560`（`_MAINTENANCE_SHAPE_SQL` 尾部的 `_durable_tables_sql(...)` 调用）
- Test: `backend/tests/test_qmt_pilot_db.py:369`（`_OK_MAINTENANCE_SHAPE`）、`:1488`（闸 (i) 参数化表）

**Interfaces:**
- Consumes: `_durable_tables_sql(qualified: tuple, alias: str) -> str`（main 已有，L476）
- Produces: `_MAINTENANCE_SHAPE_SQL` 的判据集合变为 12 条 —— 新增 `marker_durable` / `intent_durable` / `registry_durable`，移除 `maintenance_tables_durable`。Task 3 的 `_MAINTENANCE_SHAPE_OWNER` 依赖这三个名字的前缀。

- [ ] **Step 1: 先改假件的权威副本（这一步就是「写失败的测试」）**

`backend/tests/test_qmt_pilot_db.py` L363-370，把 `_OK_MAINTENANCE_SHAPE` 的最后一个键换掉：

```python
_OK_MAINTENANCE_SHAPE = {
    "marker_is_table": True, "marker_purpose_text": True,
    "marker_purpose_unique": True, "intent_is_table": True,
    "intent_columns_ok": True, "intent_dbname_unique": True,
    "registry_is_table": True, "registry_columns_ok": True,
    "registry_dbname_unique": True,
    # ⚠️ 耐久性判据**每表一条，不能合成一个跨表的 count**：合成一条时它
    #    **归因不到具体哪张表**，于是 `init_cluster_marker` 的预检只能
    #    「三张全在场才要求它」—— 混合态（一张在场但不耐久 + 另一张缺席）就此漏过，
    #    DDL 先落地，之后才拒。拆开之后，判据名前缀自动接进
    #    `_MAINTENANCE_SHAPE_OWNER` 的「只对在场的表求值」机制。
    "marker_durable": True, "intent_durable": True, "registry_durable": True}
```

同时把 L1486-1490 闸 (i) 参数化表里那一条 `("maintenance_tables_durable", "…")` 换成三条：

```python
    ("marker_durable",
     "pilot_cluster_marker 被 SET UNLOGGED / 挂 RLS / 换表空间"),
    ("intent_durable",
     "pilot_create_intent 被 SET UNLOGGED —— 崩溃后 intent 行被 truncate，"
     "而它是零对象例外授权 DROP DATABASE 的凭据（O4-R37-C2）"),
    ("registry_durable",
     "pilot_database_registry 被 SET UNLOGGED —— 崩溃后归属登记消失，"
     "既有 pilot 库在闸 (ii) 里变成外来物"),
])
```

- [ ] **Step 2: 跑测试确认变红**

```bash
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "shape_fakes_cover_every_predicate" -q
```
预期：**FAIL**，信息形如 `_MAINTENANCE_SHAPE_SQL 的判据集合与假件的权威副本不一致：SQL 有 ['maintenance_tables_durable']，假件多出 ['intent_durable', 'marker_durable', 'registry_durable']`。

- [ ] **Step 3: 写最小实现**

`backend/qmt_pilot_db.py` L558-560，把

```python
""" + _durable_tables_sql(("public.pilot_cluster_marker",
                            "public.pilot_create_intent",
                            "public.pilot_database_registry"),
                           "maintenance_tables_durable")
```

替换为

```python
""" + ",\n".join(
    # ⚠️ **每张表各一条，不能合成一个跨表的 count**：合成一条时它**归因不到具体哪张表**，
    #    于是 `init_cluster_marker` 的预检只能「三张全在场才要求它」—— 而混合态
    #    （一张在场但不耐久 + 另一张缺席）就此漏过：`malformed` 为空 →
    #    `_needs_repair_ddl` 为真 → **DDL 先落地**建出缺的表，之后才由建库**后**的
    #    形状检查拒绝，于是在一个最终被拒的维护库里留下了表。
    #    那正是「① 零副作用预检 → ② 才允许动 DDL」这条契约要防的
    #    （`--maintenance-dsn` 指错到生产库）。拆成每表一条之后，判据名的前缀
    #    （marker_/intent_/registry_）自动接进 `_MAINTENANCE_SHAPE_OWNER` 的
    #    「只对在场的表求值」机制，在场却不耐久的表在**预检阶段**就被点名。
    _durable_tables_sql((f"public.{tbl}",), alias)
    for tbl, alias in (("pilot_cluster_marker", "marker_durable"),
                       ("pilot_create_intent", "intent_durable"),
                       ("pilot_database_registry", "registry_durable")))
```

- [ ] **Step 4: 跑测试确认变绿**

```bash
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "shape_fakes_cover_every_predicate or cluster_gate_i_requires_shape" -q
```
预期：全绿（参数化表 12 条 + 机械守卫 1 条）。

- [ ] **Step 5: 变异验证（控制者亲跑）**

```bash
cp backend/qmt_pilot_db.py /tmp/s3_t2_backup.py
# 变异：把三条里的 "intent_durable" 别名改回 "maintenance_tables_durable"
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "shape_fakes_cover_every_predicate" -q
# 预期：FAIL，且信息点名 SQL 有 maintenance_tables_durable / 假件多出 intent_durable
cp /tmp/s3_t2_backup.py backend/qmt_pilot_db.py
```

- [ ] **Step 6: 全量 host 闸门**

```bash
"$PY" -m pytest backend/tests -q 2>&1 | grep -E "passed|failed|error"
```
预期：**774 passed**（Task 1 后 772 + 参数化多出的 2 条）。

- [ ] **Step 7: 真 PG 回归（这条改的是闸 (i) 的 SQL，必须真跑）**

```bash
docker start qmt-pg-r8 qmt-pg-r8b
QMT_VERIFY_ALLOW_DESTRUCTIVE=1 "$PY" backend/scripts/verify_pilot_db_lifecycle.py 2>&1 | grep -E "档断言全部成立|FAIL|❌"
```
预期：**41 档断言全部成立**（本 Task 不加档，只验没打断既有闸 (i)）。

- [ ] **Step 8: Commit**

```bash
git add backend/qmt_pilot_db.py backend/tests/test_qmt_pilot_db.py
git commit -m "S3 Task2：维护表耐久性判据拆成每表一条（为 init 的按表归属预检铺路）"
```

---

## Task 3：`init_cluster_marker` 第一段 —— 零副作用预检 + 幂等 + 补建 + 现查

**范围**：函数从入口到「补建后再验结构 → 写标记 → 完整 `assert_cluster_allowed` 现查」为止。**孤儿清理留给 Task 4**。

**Files:**
- Modify: `backend/qmt_pilot_db.py`（追加到文件末尾，`reset_pilot_database` 之后）
- Test: `backend/tests/test_qmt_pilot_db.py`（追加到 Task 1 那段之后）

**Interfaces:**
- Consumes（main 已有）：`pin_search_path(conn)`、`sha256_of_sql(sql) -> str`、`CANONICAL_CLUSTER_SCHEMA_SHA256`（Task 1）、`_MAINTENANCE_SHAPE_SQL`（Task 2 拆过）、`_READ_MARKER_SQL`、`MARKER_PURPOSE`、`_user_objects(conn, *, exempt_maintenance=False) -> list[tuple[str,int]]`、`MAINTENANCE_TABLES`、`cluster_identity(conn) -> str`、`_LIST_DATABASES_SQL`、`PILOT_DB_NAME_RE`、`adopt_connection(conn, expected_db, *, cluster_id=None, expected_oid=None)`、`_is_absolutely_empty(conn) -> bool`、`_close_quietly(conn, label) -> bool`、`assert_cluster_allowed(maint_conn, *, connect, target_db)`、`PilotClusterBoundaryError(code, msg)`
- Produces：
  - `_WRITE_MARKER_SQL: str`
  - `_MAINTENANCE_PRESENCE_SQL: str`（返回一行三列 `marker_present` / `intent_present` / `registry_present`）
  - `_MAINTENANCE_SHAPE_OWNER: dict[str, str]`（判据名前缀 → 在场列名）
  - `async def init_cluster_marker(maint_conn, *, connect, cluster_schema_sql: str, try_seed_lock, release_seed_lock) -> None`
    - `try_seed_lock`: `async (seed: str) -> bool`；`release_seed_lock`: `async (seed: str) -> None`
    - Task 4 会在函数末尾追加孤儿清理，用到这两个回调；本 Task 里它们**只在签名上出现、不被调用**。

- [ ] **Step 1: 写假件脚手架 + 第一批失败的测试**

追加到 `backend/tests/test_qmt_pilot_db.py`（紧接 Task 1 的 `_CLUSTER_SQL` 定义之后）：

```python
class _InitMaint(_FakeConn):
    """维护连接：三张表的「在场」与「补建后才合规」，以及全表 intent 扫描。"""

    def __init__(self, all_intent_rows=(), intent_table_missing=False, **kw):
        super().__init__(**kw)
        self.all_intent_rows = list(all_intent_rows)
        # 三张维护表**在不在场**（与「在场但结构坏」必须分得开）。
        self.maintenance_presence = {"marker_present": True, "intent_present": True,
                                     "registry_present": True}
        if intent_table_missing:
            # 旧版本初始化的集群：marker 在、intent 不在 → 结构判据先不合规，
            # 跑过建表 SQL 之后才合规。短路成功的实现修不好这种集群（spec O4-F7）。
            self.maintenance_presence["intent_present"] = False
            self.maintenance_shape = {**_OK_MAINTENANCE_SHAPE,
                                      "intent_is_table": False,
                                      "intent_columns_ok": False,
                                      "intent_dbname_unique": False,
                                      "intent_durable": False}

    async def fetch(self, query, *args):
        # ⚠️ 精确到 `FROM public.pilot_create_intent` **后面直接换行**（即无别名无 WHERE
        #    的那条全表扫描），免得劫走闸 (iii) 的豁免 CTE 或按库名读的那条。
        if "FROM public.pilot_create_intent\n" in query:
            self.ops.append(query)
            return list(self.all_intent_rows)
        return await super().fetch(query, *args)

    async def execute(self, query, *args):
        out = await super().execute(query, *args)
        if "CREATE TABLE" in query.upper():
            self.maintenance_shape = dict(_OK_MAINTENANCE_SHAPE)   # 补建之后结构就合规
            self.maintenance_presence = {k: True for k in self.maintenance_presence}
        if "pilot_cluster_marker" in query and "INSERT" in query.upper():
            # 写完标记之后，随后的「每次现查」应当读得到它。
            self.marker_rows = [{"purpose": MARKER_PURPOSE}]
        return out


def _orphan(dbname="kline_pilot_gone", seed="gone", age_seconds=0, db_oid="16400"):
    """⚠️ 字段必须与 `_LIST_ALL_INTENT_SQL` 的输出**逐字一致** —— 少给一个就是
    「测试在测另一个东西」。`db_oid` 是预筛绑实例用的。"""
    return {"dbname": dbname, "seed": seed, "age_seconds": age_seconds,
            "db_oid": db_oid}


def _locker(*, grants=True, record=None, released=None):
    """返回 (try_seed_lock, release_seed_lock) 一对 —— **取了就必须还**。"""
    async def _try(seed):
        if record is not None:
            record.append(seed)
        return grants

    async def _release(seed):
        if released is not None:
            released.append(seed)
    return _try, _release


def _init(maint, *, targets=None, lock_pair=None):
    try_lock, release_lock = lock_pair or _locker()
    return init_cluster_marker(
        maint, connect=_connector(targets or {}), cluster_schema_sql=_CLUSTER_SQL,
        try_seed_lock=try_lock, release_seed_lock=release_lock)


def _marker_writes(conn):
    # ⚠️ 判别式必须锚在**语句开头**：`_CLUSTER_SQL` 是仓库里那份真文件，
    #    它的注释里同时含 `pilot_cluster_marker` 与 `INSERT` 两个词，
    #    松散的子串匹配会把建表 DDL 也算成「写标记」。
    return [q for q in conn.executed
            if q.strip().upper().startswith("INSERT") and "pilot_cluster_marker" in q]


def _deletes(conn):
    # ⚠️ 必须 `.strip()`：孤儿删除 SQL 是三引号常量、以换行开头。不 strip 的话
    #    「不许删」那几条断言会变成恒真。
    return [q for q in conn.executed if q.strip().upper().startswith("DELETE")]
```

`_FakeConn` 需要两处补丁（`backend/tests/test_qmt_pilot_db.py`）：

1. `__init__` 里，在 `self.maintenance_shape = …` 之后加一行默认值（供**不是** `_InitMaint` 的用例也能应答在场查询）：

```python
        # 三张维护表**在不在场**（`_MAINTENANCE_PRESENCE_SQL`）。默认全在场。
        self.maintenance_presence = {"marker_present": True, "intent_present": True,
                                     "registry_present": True}
```

2. `fetchrow` 里，在 `if "marker_is_table" in query:` **之前**加一条分支（两者子串不相交，但显式前置以免日后被子串分发劫走）：

```python
        if "marker_present" in query:
            return (None if self.maintenance_presence is None
                    else dict(self.maintenance_presence))
```

然后追加第一批用例（幂等 / 补建 / 拒非法 / 零 DDL）：

```python
def test_init_is_idempotent_when_everything_is_already_legal():
    """已存在合法单行标记且三张表形状合规 → 直接成功，不重复写标记。"""
    maint = _InitMaint()
    asyncio.run(_init(maint))
    assert _marker_writes(maint) == []


def test_init_executes_no_ddl_at_all_on_a_healthy_cluster():
    """三表齐全时**一条 DDL 都不发**。

    `CREATE TABLE IF NOT EXISTS` 虽是空操作，但「健康集群上零 DDL」是可断言的性质，
    比「发了但没效果」强 —— 也让那些 `executed == []` 的钉子真正咬得住。
    """
    maint = _InitMaint()
    asyncio.run(_init(maint))
    assert not any("CREATE TABLE" in q.upper() for q in maint.executed), \
        f"健康集群上仍然发了 DDL：{maint.executed}"


def test_init_repairs_a_cluster_initialized_by_an_older_build():
    """旧版本没有 `pilot_create_intent` 表 → 零对象例外第 6 条恒不成立 → 残骸永远清不掉。
    **幂等短路成功的实现修不好这种集群**（spec O4-F7）。"""
    maint = _InitMaint(intent_table_missing=True)
    asyncio.run(_init(maint))
    assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
        "结构不合规时必须补建，不得短路成功"


def test_init_verifies_the_shape_after_creating_the_tables():
    """补建之后**还要再验一次结构** —— 「执行过 DDL」不等于「结构就对」。

    建表 SQL 是调用方传进来的；传错一份、或库里本就存在一张被 `IF NOT EXISTS` 跳过的
    旧表，都会让集群带着坏结构被声明为 pilot 专用。
    """
    maint = _InitMaint(intent_table_missing=True)

    async def _still_broken(query, *args):          # 建表也修不好它
        maint.executed.append(query)
        return "CREATE TABLE"
    maint.execute = _still_broken
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker"


@pytest.mark.parametrize("rows,label", [
    ([{"purpose": MARKER_PURPOSE}, {"purpose": "x"}], "多行"),
    ([{"purpose": "something_else"}], "值不对"),
])
def test_init_rejects_an_illegal_marker(rows, label):
    """标记非法/多行 → **拒绝**，要求人工处理（spec §4）。绝不「顺手改成对的」。"""
    maint = _InitMaint(marker_rows=rows)
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker", label
    assert _marker_writes(maint) == []
    assert maint.executed == [], f"{label}：拒绝之前已经执行了 DDL"


def test_init_refuses_a_cluster_schema_that_is_not_the_canonical_file():
    """递进来的 DDL 必须逐字节等于仓库那份。

    漂移的版本可以 DROP/TRUNCATE 掉 marker/intent/registry 三张表，
    随后的结构判据**只看形状不看行**，被删掉的恢复凭据与归属登记一条都发现不了。
    """
    maint = _InitMaint()
    evil = _CLUSTER_SQL + "\nTRUNCATE public.pilot_create_intent;\n"
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(init_cluster_marker(
            maint, connect=_connector({}), cluster_schema_sql=evil,
            try_seed_lock=_locker()[0], release_seed_lock=_locker()[1]))
    assert ei.value.code == "cluster_schema_not_canonical"
    assert maint.ops == [], "连一条查询都不该发 —— 这是纯函数判定"


def test_init_refuses_to_declare_a_cluster_whose_maintenance_db_is_not_empty():
    """首次初始化前必须先证明集群干净（闸 (iii)）—— 生产对象可以就放在默认 postgres 库里。"""
    maint = _InitMaint(marker_rows=[], user_objects=[("pg_class", 7)],
                       exempt_objects=[("pg_class", 7)])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "maintenance_db_not_empty"
    assert _marker_writes(maint) == []


def test_init_executes_no_ddl_before_proving_the_maintenance_db_is_safe():
    """`cluster_schema_sql` 会直接在**维护库**上执行。`--maintenance-dsn` 指错到一个
    生产库时，先建表再拒绝 = 已经在别人库里落下了三张表。

    「副作用排在证明之后」是本 spec 反复立的规矩（intent 行、登记行、确认位都这么排）。
    """
    maint = _InitMaint(user_objects=[("pg_class", 9)], exempt_objects=[("pg_class", 9)])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "maintenance_db_not_empty"
    assert maint.executed == [], f"拒绝之前已经执行了 DDL：{maint.executed}"


@pytest.mark.parametrize("broken,label", [
    ({"marker_purpose_unique": False}, "marker 在场但没唯一约束"),
    ({"intent_dbname_unique": False}, "intent 在场但 dbname 没主键"),
    ({"registry_columns_ok": False}, "registry 在场但列不齐"),
    # ⚠️ 耐久性判据**每表一条**（Task 2）：三张各配一档，
    #    否则某一张被 SET UNLOGGED 时可能只有别的判据在兜。
    ({"marker_durable": False}, "marker 在场但不是持久表（崩溃后会被 truncate）"),
    ({"intent_durable": False}, "intent 在场但不是持久表"),
    ({"registry_durable": False}, "registry 在场但不是持久表"),
])
def test_init_rejects_a_present_but_malformed_maintenance_table_before_any_ddl(broken, label):
    """`CREATE TABLE IF NOT EXISTS` **修不好**已存在的坏表，只会跳过。

    预检若只看「结构合不合规」，一张坏表会让判定落到「补建再验」那条路上：
    DDL 先把**其余缺的表**建出来，然后形状检查才失败 ——
    结果是在一个最终被拒绝的库里留下了表。
    """
    maint = _InitMaint()
    maint.maintenance_shape = {**_OK_MAINTENANCE_SHAPE, **broken}
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker", label
    assert maint.executed == [], f"{label}：拒绝之前已经执行了 DDL"


def test_init_rejects_mixed_state_present_but_non_durable_plus_absent_table():
    """**混合态**：一张在场但不耐久 + 另一张缺席 → 仍须在任何 DDL 之前拒。

    这一档正好落在上面两条钉子的**交叉点**上，两边各自都覆盖不到：
      · `test_init_rejects_a_present_but_malformed…` 造的是「三张全在场」；
      · `test_init_still_repairs_a_genuinely_absent_table` 造的是「缺表但其余合规」。

    耐久性判据若是一个**跨三张表的 count**，归因不到具体哪张表，于是预检只能
    「三张全在场才要求它」—— 混合态下 `malformed` 为空 → `_needs_repair_ddl` 为真
    → **DDL 先落地**建出缺的表，之后才由建库**后**的形状检查拒绝。
    真 PG 侧由 `verify_pilot_db_lifecycle.py` 档 ⑤b 坐实。
    """
    maint = _InitMaint(intent_table_missing=True)
    maint.maintenance_shape = {**maint.maintenance_shape, "marker_durable": False}
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker"
    assert maint.executed == [], "混合态下拒绝之前已经执行了 DDL"


def test_init_still_repairs_a_genuinely_absent_table():
    """反向钉：**缺席**的表照旧补建（别把上面那条做成「一律拒」）。

    旧版本初始化的集群没有 intent 表 —— 那是 O4-F7 明确要求修好的一档。
    """
    maint = _InitMaint(intent_table_missing=True)
    asyncio.run(_init(maint))
    assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
        "缺席的表没有被补建 —— O4-F7 的锁死原样复活"


def test_init_does_not_treat_a_read_failure_as_first_initialization():
    """**绝不把「读失败」一律当成「首次初始化」**：权限问题、坏关系都会落到那条路上，
    然后带着一个没被证明过的前提去动 DDL。"""
    class _PresenceBoom(_InitMaint):
        async def fetchrow(self, query, *args):
            if "marker_present" in query:
                raise RuntimeError("permission denied for schema public")
            return await super().fetchrow(query, *args)

    maint = _PresenceBoom()
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker"
    assert maint.executed == [], "读失败之后仍然动了 DDL"


@pytest.mark.parametrize("dirty,code,why", [
    (lambda m: setattr(m, "databases", ["payments_prod"]),
     "unrelated_database", "集群里有生产库"),
    (lambda m: setattr(m, "databases", ["kline_pilot_stranger"]),
     "unowned_pilot_database", "同前缀但非空、来路不明"),
])
def test_init_proves_peer_databases_are_clean_before_any_ddl(dirty, code, why):
    """首次初始化时，**同侪库也要在动 DDL 之前**证明干净。

    一台含 `payments_prod` 或来路不明 `kline_pilot_*` 的集群根本不该被声明为 pilot 专用；
    在它的维护库里建三张表再拒绝，等于在拒绝的集群上留下了痕迹。
    """
    maint = _InitMaint(marker_rows=[])
    dirty(maint)
    stranger = _FakeConn(user_objects=[("pg_class", 3)])   # 非空
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, targets={"kline_pilot_stranger": stranger}))
    assert ei.value.code == code, why
    assert maint.executed == [], f"{why}：拒绝之前已经执行了 DDL"


def test_init_first_time_still_accepts_an_empty_prefixed_remnant():
    """反向钉：零用户对象的同前缀残骸照旧放行（别把上面那条做成「一律拒」）。

    否则「工具被自己的护栏锁死」那个洞原样复活。
    """
    maint = _InitMaint(marker_rows=[], databases=["kline_pilot_remnant"])
    asyncio.run(_init(maint, targets={"kline_pilot_remnant": _FakeConn()}))
    assert len(_marker_writes(maint)) == 1


@pytest.mark.parametrize("dirty,code,why", [
    (lambda m: setattr(m, "databases", ["payments_prod"]),
     "unrelated_database", "混合态 + 集群里有生产库"),
    (lambda m: setattr(m, "databases", ["kline_pilot_stranger"]),
     "unowned_pilot_database", "混合态 + 同前缀但非空"),
])
def test_init_proves_peers_before_repair_ddl_even_when_the_marker_exists(dirty, code, why):
    """**标记在、但维护表缺席**时也要先证明同侪库。

    `rows` 非空会让上一条那段证明被跳过，而补建 DDL 照跑 —— 又在一个最终被拒绝的
    集群里留下了表。判据必须挂在「**这次会不会真的动 DDL**」上，不是「有没有标记」。
    """
    maint = _InitMaint(intent_table_missing=True)      # 标记在、intent 缺 → 混合态
    dirty(maint)
    stranger = _FakeConn(user_objects=[("pg_class", 3)])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, targets={"kline_pilot_stranger": stranger}))
    assert ei.value.code == code, why
    assert maint.executed == [], f"{why}：补建 DDL 在证明之前就跑了"


def test_init_still_repairs_the_mixed_state_on_a_clean_cluster():
    """反向钉：集群本身干净时，混合态照旧被修好（别把上面那条做成「一律拒」）。"""
    maint = _InitMaint(intent_table_missing=True)      # 集群干净、只是缺表
    asyncio.run(_init(maint))
    assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
        "干净集群上的混合态没有被补建 —— O4-F7 的锁死原样复活"


@pytest.mark.parametrize("dirty,code,why", [
    (lambda m: setattr(m, "databases", ["payments_prod"]),
     "unrelated_database", "集群后来被拿去装了真实数据库"),
    (lambda m: setattr(m, "exempt_objects", [("pg_class", 9)]),
     "maintenance_db_not_empty", "维护库后来多了用户对象"),
])
def test_init_revalidates_the_cluster_even_when_the_marker_already_exists(dirty, code, why):
    """**标记只证明「有人曾声明过」，现查才证明「现在仍然成立」**（spec §4 R17-F1）。

    此前 (ii)(iii) 只写在「首次初始化」那一支里，于是一台**带着合法标记的脏集群**
    会被 init 直接判成功，还接着去动维护库里的 intent 行。
    spec 点名的两条现实路径：①当初为空的 pilot 集群后来装了真实数据库；
    ②标记随 `pg_dump`/卷拷贝被还原或复制到另一个集群。
    """
    maint = _InitMaint()                       # 标记已存在且合法
    dirty(maint)
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == code, why


def test_init_repins_search_path_after_running_caller_supplied_sql():
    """`cluster_schema_sql` 是**调用方递进来的**文件；跑完必须把名字解析钉回来。

    事务里的普通 `SET search_path` 提交之后**仍留在会话上**（只有 `SET LOCAL` 不留）。
    一份漂移/敌意的 .sql 只要含一句 `SET search_path = evil, pg_catalog, public`，
    其后的结构判据 / marker 读取 / pg_database 枚举 / 用户对象扫描 / 孤儿清理
    就全都跑在它选定的解析下 —— 一台脏的维护库会被判成干净并声明为 pilot 专用。
    `create_pilot_database` 对两份 .sql 各钉了一次，本函数此前漏了。
    """
    # ⚠️ 必须用**真会补建**的场景：三表齐全时本函数根本不发 DDL，
    #    拿健康集群来测这条会在 `next(...)` 上撞 StopIteration —— 那不是「守卫失效」。
    maint = _InitMaint(intent_table_missing=True)
    asyncio.run(_init(maint))
    ddl_at = next(i for i, q in enumerate(maint.ops) if "CREATE TABLE" in q.upper())
    pins_after = [i for i, q in enumerate(maint.ops)
                  if q == PIN_SEARCH_PATH_SQL and i > ddl_at]
    assert pins_after, "跑完调用方 SQL 之后没有重新钉 search_path"
    first_guard = next((i for i, q in enumerate(maint.ops)
                        if i > ddl_at and q != PIN_SEARCH_PATH_SQL), None)
    assert first_guard is None or pins_after[0] < first_guard, (
        f"重钉排在了守卫查询之后 —— 中间那条查询仍跑在调用方选定的解析下"
        f"（第一条守卫查询：{maint.ops[first_guard][:60]!r}）")
```

同时把 `init_cluster_marker` 加进测试文件顶部的 import 清单（`from qmt_pilot_db import (...)`）：

```python
                          init_cluster_marker, MARKER_PURPOSE,
```

- [ ] **Step 2: 跑测试确认变红**

```bash
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "init_" -q 2>&1 | tail -20
```
预期：**收集阶段就 ImportError**（`cannot import name 'init_cluster_marker'`）。这是本 Task 的「红」。

- [ ] **Step 3: 写实现**

追加到 `backend/qmt_pilot_db.py` 末尾：

```python
# ── --init-cluster-marker（spec §4「`--init-cluster-marker` 的幂等语义写死」+ O4-F7）──
# ⚠️ `public.` 限定：不限定时由 search_path 决定写进哪个 schema。
_WRITE_MARKER_SQL = ("INSERT INTO public.pilot_cluster_marker (purpose) VALUES ($1)"
                     " ON CONFLICT (purpose) DO NOTHING")

# ⚠️ **「表不存在」与「表在但坏了」必须分得开**：
#    `cluster_schema_sql` 用的是 `CREATE TABLE IF NOT EXISTS` —— 它**修不好**一张已存在
#    但结构损坏的表，只会跳过。而预检若只看「结构合不合规」，一张坏表会让判定落到
#    「补建再验」那条路上：DDL 先把**其余缺的表**建出来，然后形状检查才失败 ——
#    结果是在一个最终被拒绝的库里留下了表。
#    故预检按表分别判：**在场的必须自己合规（否则零 DDL 拒绝），缺席的才交给 DDL 补建。**
_MAINTENANCE_PRESENCE_SQL = """
SELECT to_regclass('public.pilot_cluster_marker')    IS NOT NULL AS marker_present,
       to_regclass('public.pilot_create_intent')     IS NOT NULL AS intent_present,
       to_regclass('public.pilot_database_registry') IS NOT NULL AS registry_present
"""

# `_MAINTENANCE_SHAPE_SQL` 的判据名 → 它属于哪张表。
# ⚠️ 耐久性判据是**每表一条**（`marker_durable` / `intent_durable` / `registry_durable`），
#    故它和形状判据一样按前缀归属，**不需要**「三张全在场才要求」那条例外 ——
#    那条例外正是混合态下「在场却不耐久的表漏过预检、让 DDL 先落地」的洞。
_MAINTENANCE_SHAPE_OWNER = {"marker_": "marker_present",
                            "intent_": "intent_present",
                            "registry_": "registry_present"}


async def init_cluster_marker(maint_conn, *, connect, cluster_schema_sql: str,
                              try_seed_lock, release_seed_lock) -> None:
    """`qmt_pilot --init-cluster-marker`：把一台干净集群声明为 pilot 专用。

    幂等语义（spec §4 + O4-F7）：
      · 已存在合法单行标记 **且**【维护库专用表集合】形状合规 → 直接成功；
      · 标记合法但 intent / registry 表缺失或形状不符 → **补建再成功**
        （短路成功的实现修不好旧版本初始化的集群：旧版没有 intent 表 →
         零对象例外第 6 条恒不成立 → 残骸永远清不掉）；
      · 标记非法 / 多行 → **拒绝**，要求人工处理（绝不「顺手改成对的」）。

    谁写／谁读／谁清（spec §4）：本函数写标记；闸 (i) 每次运行读；
    **本工具从不清标记**（清除是人工动作）。孤儿 intent 行**只在本函数里清**。

    `try_seed_lock` / `release_seed_lock`: `async (seed) -> bool` / `async (seed) -> None`
    —— 由调用方注入（4c 用 `pg_try_advisory_lock` / `pg_advisory_unlock`
    加 `hashtext('kline_pilot_' || seed)`）。本模块**不自己取锁**
    （spec O1-F4：advisory lock 只在同一 session 内可重入，模块另开连接去取会自锁），
    但**取了就必须还**：会话级锁不还会一直挂在维护连接上，挡住后续同 seed 的运行，
    也会让同一条连接上后来的 `_SEED_LOCK_HELD_SQL` 观察到一把**本次操作从未刻意取过**的锁。

    ⚠️ **副作用严格排在证明之后**：`cluster_schema_sql` 是调用方递进来的 DDL，
       且会直接作用在**维护库**上。`--maintenance-dsn` 指错到一个生产库时，
       先建表再拒绝等于已经在别人库里落下了三张表。故本函数分成两段：
       **① 零副作用预检**（规范哈希 / 标记合法性 / 维护库除专用表外绝对空 / 同侪库）
       → **② 才允许动 DDL**。
    """
    # ── ① 零副作用预检：这一段结束之前，本函数不对任何库产生副作用 ──────────
    # 1a. 递进来的 DDL 必须逐字节等于仓库里那份规范文件。
    #     纯函数判定，排在最前 —— 连一次查询都不用发（连 pin 都在它之后）。
    _actual = sha256_of_sql(cluster_schema_sql)
    if _actual != CANONICAL_CLUSTER_SCHEMA_SHA256:
        raise PilotClusterBoundaryError(
            "cluster_schema_not_canonical",
            f"pilot_cluster_schema.sql 与仓库里的规范文件不是同一份："
            f"传入指纹 {_actual!r}，规范指纹 {CANONICAL_CLUSTER_SCHEMA_SHA256!r}。"
            f"这份 DDL 会直接在**维护库**上执行；漂移的版本可以 DROP/TRUNCATE 掉 "
            f"marker / intent / registry 三张表，而结构判据**只看形状不看行**，"
            f"被删掉的恢复凭据与归属登记一条都发现不了。")

    await pin_search_path(maint_conn)

    # 1b. 在场的维护表必须**各自**结构合规。
    #     ⚠️ 绝不把「读失败」一律当成「首次初始化」—— 权限问题、坏关系都会落到那条路上，
    #        然后带着一个没被证明过的前提去动 DDL。是否首次由 **presence** 说了算。
    try:
        presence = await maint_conn.fetchrow(_MAINTENANCE_PRESENCE_SQL)
        shape = await maint_conn.fetchrow(_MAINTENANCE_SHAPE_SQL)
    except Exception as exc:
        raise PilotClusterBoundaryError(
            "no_marker",
            f"读不出【维护库专用表集合】的在场情况/结构（{exc}）——"
            f"在证明之前不会对这个库做任何 DDL") from exc
    if presence is None or shape is None:
        raise PilotClusterBoundaryError(
            "no_marker", "【维护库专用表集合】的在场/结构查询没有返回行")
    malformed = sorted(
        k for k, v in dict(shape).items() if not v
        and any(k.startswith(pre) and presence[owner]
                for pre, owner in _MAINTENANCE_SHAPE_OWNER.items()))
    if malformed:
        raise PilotClusterBoundaryError(
            "no_marker",
            f"维护库里已存在的专用表结构不合规：{malformed}。"
            f"`CREATE TABLE IF NOT EXISTS` **修不好**已存在的坏表，只会跳过 ——"
            f"继续下去只会在一个最终要拒绝的库里留下别的表。请人工处理")

    # 1c. 标记合法性（只读）。marker 表不在场 = 首次初始化，不是错误。
    rows = await maint_conn.fetch(_READ_MARKER_SQL) if presence["marker_present"] else []
    if len(rows) > 1 or (len(rows) == 1 and rows[0]["purpose"] != MARKER_PURPOSE):
        raise PilotClusterBoundaryError(
            "no_marker",
            f"pilot_cluster_marker 形状非法（{len(rows)} 行："
            f"{[r['purpose'] for r in rows]}）——请人工处理")

    # 1d. 维护库除【维护库专用表集合】外必须绝对空（只读）。
    #     **这一条是「能不能在这个库里建 pilot 维护表」的全部依据** ——
    #     它挡的正是「--maintenance-dsn 指到了生产库」。
    leftover = await _user_objects(maint_conn, exempt_maintenance=True)
    if leftover:
        raise PilotClusterBoundaryError(
            "maintenance_db_not_empty",
            f"维护库除 {MAINTENANCE_TABLES} 外还有用户对象 {leftover}"
            f"——「没有别的数据库」不等于「这台集群没在用」。"
            f"在证明它可弃之前，本工具不会在它上面建任何表")

    # 1e. **凡是要动 DDL，同侪库都得先证明干净**。
    #     ⚠️ 判据挂在「**这次会不会真的动 DDL**」上，不是「有没有标记」：
    #        挂在 `if not rows`（首次初始化）会漏掉**混合态** —— 标记在、而
    #        `pilot_create_intent` / `pilot_database_registry` 缺失（旧版本部分初始化，
    #        或标记随 pg_dump/卷拷贝被复制过来）。那时 `rows` 非空 → 证明被跳过 →
    #        补建 DDL 照跑 → 之后才拒，又在一个最终被拒绝的集群里留下了表。
    #     ⚠️ 严判据（同前缀库必须【绝对空】）在这两种情形下都是**唯一诚实的选择**：
    #        登记表要么为空、要么根本不存在，同侪库的外部凭据**无从取得** ——
    #        此时「证明不了」只能等价于「拒绝」，由人工迁移收口。
    #        已建成且三表齐全的集群不会走到这里：它的 DDL 是空操作，
    #        由下面完整的 `assert_cluster_allowed`（认同侪库归属证明）把关。
    _needs_repair_ddl = not all(presence.values())
    if not rows or _needs_repair_ddl:
        _pre_cluster_id = await cluster_identity(maint_conn)
        for row in await maint_conn.fetch(_LIST_DATABASES_SQL):
            name = row["datname"]
            if PILOT_DB_NAME_RE.fullmatch(name) is None:
                raise PilotClusterBoundaryError(
                    "unrelated_database",
                    f"集群里存在无关数据库 {name!r}，拒绝把它声明为 pilot 专用集群"
                    f"——在证明之前不会在它的维护库里建任何表")
            try:
                other = await connect(name)
            except Exception as exc:
                raise PilotClusterBoundaryError(
                    "unowned_pilot_database",
                    f"连不进 {name!r}（{exc}）→ 无法证明它是可弃的残骸") from exc
            try:
                await adopt_connection(other, name, cluster_id=_pre_cluster_id,
                                       expected_oid=row["db_oid"])
                if not await _is_absolutely_empty(other):
                    raise PilotClusterBoundaryError(
                        "unowned_pilot_database",
                        f"{name!r} 名字匹配 kline_pilot_* 但非空，且这台集群还没有任何"
                        f"归属登记——前缀名不是归属证明，拒绝把它声明为 pilot 专用集群")
            except PilotClusterBoundaryError:
                raise
            except Exception as exc:
                raise PilotClusterBoundaryError(
                    "unowned_pilot_database",
                    f"验 {name!r} 是否为空时失败（{exc}）→ 无法证明") from exc
            finally:
                await _close_quietly(other, name)

    # ── ② 到这里才第一次产生副作用 ──────────────────────────────────────
    #     此刻 marker/intent/registry 可能还不存在，闸 (i) 会因此拒绝，
    #     故不能直接调 `assert_cluster_allowed`（那正是本函数存在的原因之一）。
    # ⚠️ **三张表都在场时根本不发这条语句**：`CREATE TABLE IF NOT EXISTS` 虽是空操作，
    #    但「健康集群上一条 DDL 都不执行」是可断言的性质，比「发了但没效果」强 ——
    #    也让上面那些 `executed == []` 的钉子真正咬得住。
    if _needs_repair_ddl:
        await maint_conn.execute(cluster_schema_sql)
        # ⚠️ **调用方的 SQL 跑完必须重新钉 search_path**：事务里的普通 `SET search_path`
        #    **提交之后仍留在会话上**（只有 `SET LOCAL` 不留）。`cluster_schema_sql` 是
        #    调用方递进来的文件，一份漂移/敌意的 .sql 只要含一句
        #    `SET search_path = evil, pg_catalog, public`，其后**所有**守卫查询 ——
        #    结构判据、marker 读取、pg_database 枚举、用户对象扫描、孤儿清理 ——
        #    就都跑在它选定的名字解析下：`pg_class` / `pg_attribute` / `to_regclass` /
        #    `now()` 全都可以被对手控制的 schema 接管，于是一台脏的维护库被判成干净
        #    并声明为 pilot 专用。`create_pilot_database` 对两份 .sql 各钉了一次，
        #    本函数此前漏了。
        await pin_search_path(maint_conn)

    # 2. 建完**再验一次结构**：「执行过 DDL」不等于「结构就对」（与闸 (i) 同一条纪律）。
    #    建表 SQL 由调用方传入；传错一份、或库里本就存在一张被 `IF NOT EXISTS` 跳过的
    #    旧表，都会让集群带着坏结构被声明为 pilot 专用。
    shape = await maint_conn.fetchrow(_MAINTENANCE_SHAPE_SQL)
    if shape is None or not all(shape.values()):
        raise PilotClusterBoundaryError(
            "no_marker",
            f"补建之后【维护库专用表集合】的结构仍不合规"
            f"（{dict(shape) if shape else 'None'}）——请人工处理")

    if not rows:
        # 3. 同侪库已在 1e 证明过（零副作用），这里只剩写标记。
        await maint_conn.execute(_WRITE_MARKER_SQL, MARKER_PURPOSE)

    # 4. ⚠️ **无论标记是不是本次刚写的，都要现查一遍 (i)(ii)(iii)**。
    #    spec §4 R17-F1 逐字写着：「标记证明的是**有人曾声明过**，只有现查才证明
    #    **现在仍然成立**」，并点名两条现实路径 ——
    #    ① 当初为空的 pilot 集群后来被拿去装了真实数据库；
    #    ② 标记随 pg_dump / 卷拷贝被**还原或复制到另一个集群**。
    #    此前这几条检查只写在「首次初始化」那一支里，于是一台带着合法标记的脏集群
    #    会被 init 直接判成功，还接着去动维护库里的 intent 行。
    #    这里用**完整的** `assert_cluster_allowed`（而不是 1e 那组「首次初始化」判据）：
    #    此刻标记与三张表都已就位，(i) 过得了；而 (ii) 的完整版会认同侪 pilot 库的
    #    归属证明 —— 1e 那组要求「同前缀库必须绝对空」只在**登记表必然为空**的
    #    首次初始化那一刻成立，套到已建成的集群上会把正常的 pilot 库判成外来物。
    await assert_cluster_allowed(maint_conn, connect=connect, target_db=None)
```

- [ ] **Step 4: 跑测试确认变绿**

```bash
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "init_" -q 2>&1 | tail -5
```
预期：全绿（约 24 条，含参数化展开）。

- [ ] **Step 5: 变异验证（控制者亲跑，逐条对准具名判据）**

每一条都：`cp backend/qmt_pilot_db.py /tmp/s3_t3_backup.py` → 改 → 跑 → `cp /tmp/s3_t3_backup.py backend/qmt_pilot_db.py` 复原。
**必须核实变红的是具名的那一条**，不是「有测试变红」。

| # | 变异 | 必须变红的具名用例 |
|---|---|---|
| M1 | 删掉 1a 整段（不校验规范哈希） | `test_init_refuses_a_cluster_schema_that_is_not_the_canonical_file` |
| M2 | 把 1a 移到 `pin_search_path` **之后** | 同上（`maint.ops == []` 那条断言） |
| M3 | `malformed` 的推导去掉 `and presence[owner]`（一律要求合规） | `test_init_still_repairs_a_genuinely_absent_table` |
| M4 | `_MAINTENANCE_SHAPE_OWNER` 删掉 `"marker_"` 那一项 | `test_init_rejects_a_present_but_malformed_maintenance_table_before_any_ddl[broken4-…]`（marker_durable 档）与 `…mixed_state…` |
| M5 | `_needs_repair_ddl = not all(presence.values())` 改成 `False`（永不补建） | `test_init_repairs_a_cluster_initialized_by_an_older_build` |
| M6 | 1e 的条件从 `if not rows or _needs_repair_ddl:` 改成 `if not rows:` | `test_init_proves_peers_before_repair_ddl_even_when_the_marker_exists`（两档） |
| M7 | 把 `except Exception` 那段（presence/shape 读失败）改成 `presence = None; shape = None` 后继续 | `test_init_does_not_treat_a_read_failure_as_first_initialization` |
| M8 | 删掉 `if _needs_repair_ddl:` 分支里的 `await pin_search_path(maint_conn)` | `test_init_repins_search_path_after_running_caller_supplied_sql` |
| M9 | 删掉最后那句 `await assert_cluster_allowed(...)` | `test_init_revalidates_the_cluster_even_when_the_marker_already_exists`（两档） |
| M10 | 把「建完再验一次结构」那段删掉 | `test_init_verifies_the_shape_after_creating_the_tables` |
| M11 | `if _needs_repair_ddl:` 改成无条件执行 DDL | `test_init_executes_no_ddl_at_all_on_a_healthy_cluster` |
| M12 | 把 1d（`_user_objects`）移到 `② 副作用` 之后 | `test_init_executes_no_ddl_before_proving_the_maintenance_db_is_safe` |

- [ ] **Step 6: 全量 host 闸门**

```bash
"$PY" -m pytest backend/tests -q 2>&1 | grep -E "passed|failed|error"
```
预期：**798 passed**（Task 2 后 774 + 本 Task 24；实际条数以参数化展开为准，只要**没有 failed/error** 且总数 ≥ 794 即可，把实际数字记进 Task 5 的验收表）。

- [ ] **Step 7: Commit**

```bash
git add backend/qmt_pilot_db.py backend/tests/test_qmt_pilot_db.py
git commit -m "S3 Task3：init_cluster_marker 第一段 —— 零副作用预检 + 幂等 + 补建 + 每次现查"
```

---

## Task 4：`init_cluster_marker` 第二段 —— 孤儿 intent 行清理

**范围**：两条新 SQL 常量 + 函数末尾的清理循环。

**核心不变量（spec O4-F2 修正③，逐条）**：
1. **逐行先 `pg_try_advisory_lock` 取该行 seed 的锁，取不到就跳过** —— 不加这一步会删掉一次**正在进行的运行**的行，那次运行随后判零对象例外第 6 条不成立 → **自己的残骸自己清不掉**；
2. **取到才删、删完立刻释放**；
3. **清理判据 = 超期 OR 库不存在**，且这两条必须**在同一条 DELETE 的 WHERE 里、锁内当下求值** —— 先查后删的话，查完到删之间同 seed 的另一次运行可以启动、刷新自己的 intent 行、崩在写 `pilot_meta` 之前、并随连接断开释放会话锁；此时本循环拿到锁，却按**快照时的陈旧状态**把那条**新鲜的恢复凭据**删掉；
4. **回调返回真不算证明** —— advisory lock 在同一 session 内可重入，且回调完全在调用方那侧；必须在 `maint_conn` 上用 `_SEED_LOCK_HELD_SQL` 复核（它绑 `pg_backend_pid()`，而 DELETE 正是在这条连接上跑的）。调用方若在别的连接上取锁，这里判假、跳过，是**正确**的 fail-closed。

**Files:**
- Modify: `backend/qmt_pilot_db.py`（新增两条常量 + 在 `init_cluster_marker` 末尾追加循环）
- Test: `backend/tests/test_qmt_pilot_db.py`

**Interfaces:**
- Consumes: `INTENT_TTL_SECONDS`（main 已有）、`_SEED_LOCK_HELD_SQL`（main 已有）、`_LIST_DATABASES_SQL`
- Produces: `_LIST_ALL_INTENT_SQL`（输出列 `dbname` / `seed` / `db_oid`(text) / `age_seconds`(bigint)）、`_DELETE_ORPHAN_INTENT_SQL`（参数 `$1=dbname`、`$2=ttl_seconds`）

- [ ] **Step 1: 写失败的测试**

追加到 `backend/tests/test_qmt_pilot_db.py`（Task 3 那批之后）：

```python
def test_init_cleans_orphan_rows_only_under_the_seed_lock():
    """不持 seed 锁就删，会删掉**一次正在进行的运行**的行 → 那次运行随后判零对象例外
    第 6 条不成立 → **自己的残骸自己清不掉**（spec O4-F2 修正③）。"""
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_running",
                                                seed="running")])
    asyncio.run(_init(maint, lock_pair=_locker(grants=False)))
    assert _deletes(maint) == [], "取不到 seed 锁就必须跳过，不得删"


def test_init_takes_the_lock_of_the_row_being_deleted():
    """锁必须**逐行按那一行的 seed** 取，不是随便取一把。"""
    asked = []
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    asyncio.run(_init(maint, lock_pair=_locker(record=asked)))
    assert asked == ["gone"]


@pytest.mark.parametrize("row,label", [
    (_orphan(dbname="kline_pilot_stale", seed="stale",
             age_seconds=INTENT_TTL_SECONDS), "超期"),
    (_orphan(dbname="kline_pilot_gone", seed="gone"), "库已不存在"),
])
def test_init_deletes_stale_or_vanished_rows(row, label):
    """清理判据 = **超期 OR 库不存在**（spec O4-F2 修正③）。"""
    maint = _InitMaint(all_intent_rows=[row], databases=["kline_pilot_stale"])
    asyncio.run(_init(maint, targets={"kline_pilot_stale": _FakeConn()}))
    assert len(_deletes(maint)) == 1, label


def test_init_keeps_a_fresh_row_of_a_live_database():
    """**正向档**：既新鲜、库又真的存在 → 不是孤儿，不许删。

    一族全是「应该被删/被拒」的档会让「恒删」和「恒不删」两种坏实现都活下来；
    这一条是那一族的健康输入。
    """
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_live", seed="live")],
                       databases=["kline_pilot_live"])
    asyncio.run(_init(maint, targets={"kline_pilot_live": _FakeConn()}))
    assert _deletes(maint) == []


def test_orphan_prefilter_treats_a_replaced_same_name_database_as_vanished():
    """预筛必须**绑实例**：只按名字判「库还在不在」时，「原实例被删掉、别人用同名重建」
    这一档会被判成「没消失」→ 直接 continue → 锁内那条 OID-aware 的 DELETE
    **永远跑不到**，陈旧行一直赖着把建库卡到 TTL。
    """
    maint = _InitMaint(
        all_intent_rows=[_orphan(dbname="kline_pilot_reborn", seed="reborn",
                                 db_oid="16400")],           # 凭据记的是**旧**实例
        databases=["kline_pilot_reborn"])
    maint.database_oids = {"kline_pilot_reborn": "99999"}    # 同名，但已是另一个实例
    reborn = _FakeConn()
    reborn.current_db_oid = "99999"                          # 新实例自称就是 99999
    asyncio.run(_init(maint, targets={"kline_pilot_reborn": reborn}))
    assert len(_deletes(maint)) == 1, "同名替身没有被判成 vanished，OID 判据跑不到"


def test_init_does_not_clean_orphans_on_a_cluster_that_is_no_longer_clean():
    """现查不过时，**一行 intent 都不许动** —— 那是别的集群/别人的状态。"""
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")],
                       databases=["payments_prod"])
    with pytest.raises(PilotClusterBoundaryError):
        asyncio.run(_init(maint))
    assert _deletes(maint) == []


def test_orphan_cleanup_refuses_when_the_callback_lies_about_the_lock():
    """孤儿清理不许只信回调的布尔。

    `_SEED_LOCK_HELD_SQL` 在模块里有四个使用点（建库 / reset 授权 / DROP / 零对象例外），
    孤儿清理**做的是 DELETE 恢复凭据**，同样必须复核。
    而 advisory lock 在同一 session 内**可重入**：一个接错线的回调、或同连接上早已
    因别的原因持有的锁，都会返回真而**不提供任何互斥**。
    后果是删掉一次进行中/崩溃中的建库**唯一的恢复凭据** ——
    留下一个零对象例外再也授权不了的空残骸。
    """
    orphan = {"dbname": "kline_pilot_ghost", "seed": "ghost",
              "db_oid": "99999", "age_seconds": 10 ** 9}
    maint = _InitMaint(all_intent_rows=[orphan], seed_lock_held=False)  # 回调撒谎

    async def _lying_try(_seed):
        return True                            # 说取到了，实际 pg_locks 里没有

    async def _noop(_seed):
        return None

    asyncio.run(_init(maint, lock_pair=(_lying_try, _noop)))
    assert _deletes(maint) == [], "回调撒谎说持有锁，孤儿清理就把恢复凭据删了"


def test_orphan_cleanup_releases_every_seed_lock_it_takes():
    """**取了就必须还**：会话级锁不还会一直挂在维护连接上，挡住后续同 seed 的运行；
    同一条连接上后来的 `_SEED_LOCK_HELD_SQL` 也会观察到一把**本次从未刻意取过**的锁。"""
    taken, freed = [], []
    maint = _InitMaint(all_intent_rows=[
        _orphan(dbname="kline_pilot_gone", seed="gone"),
        _orphan(dbname="kline_pilot_stale", seed="stale",
                age_seconds=INTENT_TTL_SECONDS + 1)])
    asyncio.run(_init(maint, lock_pair=_locker(record=taken, released=freed)))
    assert taken == ["gone", "stale"]
    assert freed == taken, f"取了 {taken} 却只还了 {freed}"


def test_orphan_cleanup_releases_the_lock_even_when_the_delete_fails():
    """删除抛异常时锁也必须还 —— 否则一次失败会把那个 seed 永久挡住。"""
    freed = []

    class _DeleteBoom(_InitMaint):
        async def execute(self, query, *args):
            if query.strip().upper().startswith("DELETE"):
                raise RuntimeError("deadlock detected")
            return await super().execute(query, *args)

    maint = _DeleteBoom(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    with pytest.raises(RuntimeError):
        asyncio.run(_init(maint, lock_pair=_locker(released=freed)))
    assert freed == ["gone"], "删除失败时锁没还"


def test_orphan_cleanup_does_not_release_a_lock_it_never_took():
    """取不到锁的那一行**不许调 release** —— 那会把别人正持有的锁还掉。"""
    freed = []
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_running",
                                                seed="running")])
    asyncio.run(_init(maint, lock_pair=_locker(grants=False, released=freed)))
    assert freed == [], "取不到锁却还了锁 —— 会把别的运行持有的锁释放掉"


def test_orphan_cleanup_uses_a_delete_that_can_actually_match_an_orphan():
    """机械守卫：孤儿删除**不能复用** `_DELETE_INTENT_SQL` / `_CLEAR_INTENT_SQL`。

    前者带 `AND NOT create_confirmed`，而孤儿恰恰是**已确认**的行 → 它永远匹配 0 行；
    两者都还带 `run_id = $2`，而清理孤儿的这次运行**不是**写下那一行的那次运行。
    复用任何一条都会是「命令发了、一行没删」的静默失败 ——
    正是 R9 那次回归的形态（没人看 DELETE 匹配了几行）。
    """
    import qmt_pilot_db as m
    sql = m._DELETE_ORPHAN_INTENT_SQL
    assert "run_id" not in sql, "孤儿清理不该按 run_id 过滤"
    assert "create_confirmed" not in sql, "孤儿恰恰是已确认的行"
    assert "public.pilot_create_intent" in sql, "表引用必须 public. 限定"
    # ⚠️ 判据必须**在 SQL 里、在锁内**求值：先查后删的写法会按快照时的陈旧状态，
    #    删掉一条同 seed 运行**刚刷新过的**恢复凭据。
    assert "now() - inserted_at" in sql, "超期判据没有下沉进 DELETE"
    assert "pg_database" in sql and "d.oid" in sql, "「库不存在」判据没有下沉、或没绑实例"
    assert sql.count("$1") == 1 and sql.count("$2") == 1, "参数应为 dbname + TTL 两个"


def test_init_orphan_freshness_uses_the_database_clock():
    """孤儿清理的新鲜度只认库时钟（spec O4-R23-C1），不认调用方传的 created_at。

    `created_at` 是**调用方传进来的**字符串，数据库既不生成也不校验它：
    写一个很远的过去值，一行**活着的** intent 立刻可被别人接管。
    """
    import qmt_pilot_db as m
    sql = m._LIST_ALL_INTENT_SQL
    assert "now() - inserted_at" in sql or "now() - i.inserted_at" in sql
    assert "created_at" not in sql


def test_orphan_delete_predicate_is_evaluated_under_the_lock_not_from_a_snapshot():
    """机械守卫：「超期 OR 库不存在」必须**在 DELETE 的 WHERE 里**，
    且循环体里不许有内联的 DELETE 字面量（那是「按 Python 侧快照决定删不删」的形态）。

    真 PG 侧由 `verify_pilot_db_lifecycle.py` 档 ㊱ 坐实。
    """
    import ast
    import inspect
    import textwrap
    import qmt_pilot_db as m
    sql = m._DELETE_ORPHAN_INTENT_SQL
    assert "now() - inserted_at" in sql and "pg_database" in sql, \
        "两条判据没有下沉进 DELETE"
    src = textwrap.dedent(inspect.getsource(m.init_cluster_marker))
    tree = ast.parse(src)
    consts = [n.value for n in ast.walk(tree)
              if isinstance(n, ast.Constant) and isinstance(n.value, str)
              and "DELETE" in n.value.upper()]
    assert not consts, f"init 里有内联 DELETE 字面量：{consts}"
```

- [ ] **Step 2: 跑测试确认变红**

```bash
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "orphan" -q 2>&1 | tail -20
```
预期：`AttributeError: module 'qmt_pilot_db' has no attribute '_DELETE_ORPHAN_INTENT_SQL'`（机械守卫那几条）＋行为档因「一条 DELETE 都没发」而 FAIL（`test_init_deletes_stale_or_vanished_rows` 两档、`test_orphan_prefilter…`、`test_orphan_cleanup_releases_every_seed_lock_it_takes`、`test_init_takes_the_lock_of_the_row_being_deleted`）。
**注意**：`test_init_cleans_orphan_rows_only_under_the_seed_lock` / `…keeps_a_fresh_row…` / `…does_not_release_a_lock_it_never_took` / `…refuses_when_the_callback_lies…` 这几条**开局就是绿的**（功能没写时它们恒真）——它们是**反向钉**，判别力由 Step 5 的变异表逐条证明，不能拿它们当「红→绿」的证据。

- [ ] **Step 3: 写实现**

在 `_MAINTENANCE_SHAPE_OWNER` 之后、`init_cluster_marker` 之前插入两条常量：

```python
# 孤儿清理要看**全部** intent 行（`_READ_INTENT_SQL` 只看本次库名那一行）。
# 新鲜度同样只认库自己的时钟（O4-R23-C1）。
_LIST_ALL_INTENT_SQL = """
SELECT dbname, seed, db_oid::text AS db_oid,
       EXTRACT(EPOCH FROM (now() - inserted_at))::bigint AS age_seconds
  FROM public.pilot_create_intent
"""

# ⚠️ **绝不能复用 `_DELETE_INTENT_SQL` / `_CLEAR_INTENT_SQL`**：
#    · `_DELETE_INTENT_SQL` 带 `AND NOT create_confirmed`，而孤儿恰恰是**已确认**的行
#      —— 它永远匹配 0 行，清理成了「命令发了、一行没删」的静默失败；
#    · 两者都还带 `run_id = $2`，而清理孤儿的这次运行**不是**写下那一行的那次运行。
#    孤儿的授权来自「取到了那一行 seed 的 advisory lock + 它超期或库已不存在」，
#    不来自 run_id，故判据只按 dbname。
# ⚠️ **判据必须写在这条 SQL 里、在锁内原子求值**：
#    先 `SELECT` 出一批行、再逐行取锁、然后只按 dbname 删，中间的窗口里
#    **同 seed 的另一次运行**可以启动、刷新/确认它自己的 intent 行、崩在写 pilot_meta 之前、
#    并随连接断开释放会话锁 —— 此时本循环拿到锁，却按**快照时看到的陈旧状态**
#    把那条**新鲜的恢复凭据**删掉，留下一个零对象例外再也授权不了的空残骸。
#    故把「超期 OR 库不存在」两条判据下沉进 DELETE 的 WHERE 里。
# ⚠️ 「库不存在」绑实例（`d.oid = db_oid`）而不是只比名字：一条指向已消失实例的行
#    本来就该被清掉，哪怕现在有个同名的新库。
_DELETE_ORPHAN_INTENT_SQL = """
DELETE FROM public.pilot_create_intent
 WHERE dbname = $1
   AND (EXTRACT(EPOCH FROM (now() - inserted_at)) >= $2
        OR NOT EXISTS (SELECT 1 FROM pg_database d
                        WHERE d.datname::text = public.pilot_create_intent.dbname
                          AND d.oid = public.pilot_create_intent.db_oid))
"""
```

在 `init_cluster_marker` 末尾（`await assert_cluster_allowed(...)` 之后）追加：

```python
    # 5. 孤儿 intent 行清理：超期 OR 库不存在，且取得到那一行 seed 的锁。
    # ⚠️ **预筛也必须绑实例**：只按名字判「库还在不在」时，
    #    「原实例被删掉、别人用同名重建」这一档会被判成「没消失」→ 直接 continue →
    #    下面那条 OID-aware 的 DELETE **永远跑不到**，一条指向已消失实例的陈旧行
    #    就一直赖着，把后续的建库/reset 卡到 TTL 为止。
    #    预筛只是省掉不必要的取锁；真正的判据在锁内的 SQL 里，两者的口径必须一致。
    live = {(r["datname"], r["db_oid"]) for r in await maint_conn.fetch(_LIST_DATABASES_SQL)}
    for r in await maint_conn.fetch(_LIST_ALL_INTENT_SQL):
        stale = int(r["age_seconds"]) >= INTENT_TTL_SECONDS
        vanished = (r["dbname"], r["db_oid"]) not in live
        if not (stale or vanished):
            continue
        if not await try_seed_lock(r["seed"]):
            continue                       # 有运行正在用这个 seed —— 跳过，绝不删
        try:
            # ⚠️ **回调返回真不算证明**：`_SEED_LOCK_HELD_SQL` 在本模块有四个使用点
            #    （建库 / reset 授权 / DROP / 零对象例外），而这里做的是
            #    **DELETE 恢复凭据**。两种现实情形会让布尔为真却毫无互斥：
            #      · 调用方回调接错线（本模块**不取锁**，取锁完全在调用方那侧）；
            #      · advisory lock 在同一 session 内**可重入** —— 这条连接若早已因别的
            #        原因持有同一把锁，`pg_try_advisory_lock` 照样返回真。
            #    删错的后果是抹掉一次进行中/崩溃中的建库**唯一的恢复凭据**，
            #    留下一个零对象例外再也授权不了的空残骸。
            # ⚠️ 判据要求锁在 **`maint_conn` 这条连接上**（`_SEED_LOCK_HELD_SQL` 绑
            #    `pg_backend_pid()`）—— DELETE 正是在它上面跑的。调用方若在别的连接上取锁，
            #    这里判假、跳过，是**正确**的 fail-closed。
            if not await maint_conn.fetchval(_SEED_LOCK_HELD_SQL, r["seed"]):
                continue                   # `finally` 仍会把回调取的那把还回去
            # ⚠️ 上面那两条 Python 判据只是**省掉不必要的取锁**；真正的删除判据在 SQL 里，
            #    在锁内按**当下**的 inserted_at 与 pg_database 求值。
            await maint_conn.execute(_DELETE_ORPHAN_INTENT_SQL, r["dbname"],
                                     INTENT_TTL_SECONDS)
        finally:
            # ⚠️ **取了就必须还**：会话级锁不还会一直挂在维护连接上，挡住后续同 seed
            #    的运行；同一条连接上后来的 `_SEED_LOCK_HELD_SQL` 也会观察到一把
            #    **本次操作从未刻意取过**的锁。
            await release_seed_lock(r["seed"])
```

- [ ] **Step 4: 跑测试确认变绿**

```bash
"$PY" -m pytest backend/tests/test_qmt_pilot_db.py -k "orphan or init_" -q 2>&1 | tail -5
```
预期：全绿。

- [ ] **Step 5: 变异验证（控制者亲跑，逐条对准具名判据）**

反向钉（Step 2 里开局就绿的那几条）的判别力**只能**由这一步证明。

| # | 变异 | 必须变红的具名用例 |
|---|---|---|
| M13 | 删掉 `if not await try_seed_lock(...): continue` 那两行（不取锁就删） | `test_init_cleans_orphan_rows_only_under_the_seed_lock` |
| M14 | 把 `try_seed_lock(r["seed"])` 改成 `try_seed_lock("fixed")` | `test_init_takes_the_lock_of_the_row_being_deleted` |
| M15 | 删掉 `if not (stale or vanished): continue`（对每一行都删） | `test_init_keeps_a_fresh_row_of_a_live_database` |
| M16 | `vanished` 改成 `r["dbname"] not in {n for n, _ in live}`（只比名字） | `test_orphan_prefilter_treats_a_replaced_same_name_database_as_vanished` |
| M17 | 删掉 `_SEED_LOCK_HELD_SQL` 复核那两行 | `test_orphan_cleanup_refuses_when_the_callback_lies_about_the_lock` |
| M18 | 把 `finally: await release_seed_lock(...)` 改成普通行（不在 finally 里） | `test_orphan_cleanup_releases_the_lock_even_when_the_delete_fails` |
| M19 | 把 `release_seed_lock` 挪到 `if not await try_seed_lock(...)` 的 `continue` 之前 | `test_orphan_cleanup_does_not_release_a_lock_it_never_took` |
| M20 | `_DELETE_ORPHAN_INTENT_SQL` 去掉 `AND (EXTRACT… OR NOT EXISTS…)` 整段 | `test_orphan_cleanup_uses_a_delete_that_can_actually_match_an_orphan` + `test_orphan_delete_predicate_is_evaluated_under_the_lock_not_from_a_snapshot` |
| M21 | `_LIST_ALL_INTENT_SQL` 把 `now() - inserted_at` 换成 `now() - created_at::timestamptz` | `test_init_orphan_freshness_uses_the_database_clock` |
| M22 | 把清理循环挪到 `await assert_cluster_allowed(...)` **之前** | `test_init_does_not_clean_orphans_on_a_cluster_that_is_no_longer_clean` |
| M23 | 循环只处理 `rows[:1]`（提前 break） | `test_orphan_cleanup_releases_every_seed_lock_it_takes` |

- [ ] **Step 6: 全量 host 闸门**

```bash
"$PY" -m pytest backend/tests -q 2>&1 | grep -E "passed|failed|error"
```
预期：无 failed / error，总数在 Task 3 基础上再 +14 左右。**把实测数字记下来**，Task 5 的验收表要用。

- [ ] **Step 7: Commit**

```bash
git add backend/qmt_pilot_db.py backend/tests/test_qmt_pilot_db.py
git commit -m "S3 Task4：init_cluster_marker 第二段 —— 孤儿 intent 清理（锁内原子求值 + 取了必还）"
```

---

## Task 5：真 PG L2 验收 —— 五档新场景

**为什么必须真跑**：假件只能验**控制流与形状**，验不了语义（`relkind` 覆盖面、advisory lock 可重入、`SET UNLOGGED` 之后 `relpersistence` 真的变了、DELETE 真的匹配到了几行）。spec §6.2 明写假件会静默建模错误语义，本仓已实证吃过亏。

**Files:**
- Modify: `backend/scripts/verify_pilot_db_lifecycle.py`

**档号（已核实空闲，见 Global Constraints）**：

| 新档 | 内容 | 对应 host 用例 |
|---|---|---|
| **⑤** | 脏维护库（有用户表 + 三张维护表全删）上 init 必须拒 **且零 DDL**（事后三张表仍不存在） | `test_init_executes_no_ddl_before_proving_the_maintenance_db_is_safe` |
| **⑤b** | **混合态**：marker 在场但 `UNLOGGED` + 另两张缺席 → 仍须零 DDL 拒 | `test_init_rejects_mixed_state_present_but_non_durable_plus_absent_table` |
| **㉙** | 带合法标记的集群上事后出现无关库 → init 仍须拒（标记不得短路现查） | `test_init_revalidates_the_cluster_even_when_the_marker_already_exists` |
| **㉚** | 孤儿清理取了 seed 锁之后必须还（三条一起：取过锁 + 孤儿真被清掉 + 锁已还） | `test_orphan_cleanup_releases_every_seed_lock_it_takes` |
| **㊱** | **新号**（旧 ㉖ 已被 S1 占用）：预筛之后取锁之前被刷新的凭据**不许被删** —— 判据在锁内当下求值 | `test_orphan_delete_predicate_is_evaluated_under_the_lock_not_from_a_snapshot` |

- [ ] **Step 1: 改 import 与 `_EXPECTED_SCENARIOS`**

`backend/scripts/verify_pilot_db_lifecycle.py` L66-74 的 import 加两个符号：

```python
from qmt_pilot_db import (INTENT_TTL_SECONDS, MARKER_PURPOSE,  # noqa: E402
                          PILOT_META_KEYS, PilotClusterBoundaryError,
                          PilotDbBoundaryError, _READ_INTENT_SQL,
                          _SEED_LOCK_HELD_SQL,
                          _TARGET_CLIENT_SESSIONS_SQL, assert_cluster_allowed,
                          assert_db_allowed_for_reset,
                          assert_db_allowed_for_reuse,
                          create_pilot_database, init_cluster_marker,
                          quote_ident,
                          reset_pilot_database, sha256_of_sql,
                          try_empty_remnant_exception)
```

`_EXPECTED_SCENARIOS` 改成 46 档（新增 ⑤ ⑤b ㉙ ㉚ ㊱，其余顺序不动）：

```python
_EXPECTED_SCENARIOS = ("①", "②", "③", "④", "⑤", "⑤b", "⑥", "⑦", "⑧", "⑨", "⑨b",
                       "⑨c", "⑩", "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑰b", "⑱",
                       "⑲", "⑳", "⑳b", "㉑", "㉒", "㉓", "㉔", "㉕", "㉖", "㉗", "㉙",
                       "㉚", "㊱", "㉛",
                       "㉝", "㉝b", "㉝c", "㉘", "㉜", "㉜b", "㉞", "㉞b", "㉟", "㉟b")
```

- [ ] **Step 2: 跑脚本确认变红**

```bash
docker start qmt-pg-r8 qmt-pg-r8b
QMT_VERIFY_ALLOW_DESTRUCTIVE=1 "$PY" backend/scripts/verify_pilot_db_lifecycle.py 2>&1 | grep -E "档断言全部成立|FAIL|❌|未运行|缺"
```
预期：脚本报**声明了 46 档但只跑了 41 档**（`_EXPECTED_SCENARIOS` 与 `ran` 集合的差集非空）。这是本 Task 的「红」——先让缺档机制自己叫出来，再去补场景。

> 若脚本没有「声明 vs 实跑」的差集检查而是静默通过，**先补这条检查**（它本身就是「机械检查器被它该抓的损坏禁用了自身解析器」那一族的防线），再继续。

- [ ] **Step 3: 写 ⑤ 与 ⑤b（插在 ④ 那段之后，约 L480）**

```python
    # ── ⑤ 脏维护库上的 `--init-cluster-marker` 必须拒，**且零 DDL** ──────────
    #    副作用必须排在证明之后 —— 拒绝的集群里不该多出任何维护表。
    scenario("⑤")
    print("⑤ 脏集群上的 --init-cluster-marker")
    conn = await _connect(base_dsn)
    try:
        # 造脏：维护库里放一张用户表；并把三张维护表**全部删掉**，
        # 使得「补建 DDL 会真的产生副作用」——否则这一档验不到东西。
        await conn.execute("DROP TABLE IF EXISTS public.pilot_create_intent")
        await conn.execute("DROP TABLE IF EXISTS public.pilot_database_registry")
        await conn.execute("DROP TABLE IF EXISTS public.pilot_cluster_marker")
        await conn.execute("CREATE TABLE public.zzqmtverify_lifecycle_probe (id int)")

        async def _never(_seed):
            return False

        async def _noop(_seed):
            return None

        cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8")
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_never, release_seed_lock=_noop)
            check(False, "⑤ 脏维护库上 init 必须拒", "竟然成功了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "maintenance_db_not_empty",
                  "⑤ 脏维护库 → maintenance_db_not_empty", f"实得 {exc.code}")
        # **零 DDL**：三张维护表事后仍然不存在。
        left = [t for t in ("pilot_cluster_marker", "pilot_create_intent",
                            "pilot_database_registry")
                if await conn.fetchval(
                    "SELECT to_regclass($1) IS NOT NULL", f"public.{t}")]
        check(not left, "⑤ 拒绝之前一条 DDL 都没执行（三张维护表仍不存在）",
              f"竟然建出了 {left}")
        # 复原：把维护表建回来，供后续档位与下一次运行使用。
        await conn.execute("DROP TABLE IF EXISTS public.zzqmtverify_lifecycle_probe")
        await _apply_cluster_schema(conn)
        await _write_marker(conn)
    finally:
        await conn.close()

    # ── ⑤b **混合态**：一张维护表在场但不耐久 + 另外两张缺席 → 仍须零 DDL 拒 ──
    #    ⑤ 造的是「三张全缺」，那时 `_needs_repair_ddl` 与「已在场的表合不合规」
    #    不冲突，故证伪不了混合态。
    #    缺陷形态（Task 2 已修）：耐久性判据原本是**横跨三张表的一个 count**，
    #    归因不到具体某张表，于是实现只在「三张全在场」时才要求它 ——
    #    结果：marker 在场但 UNLOGGED、intent/registry 缺席时预检**放行**，
    #    DDL 先落地建出两张表，之后才由建库**后**的形状检查拒绝。
    scenario("⑤b")
    print("⑤b 混合态：marker 在场但 UNLOGGED + 另两张缺席 → 必须零 DDL 拒")
    conn = await _connect(base_dsn)
    try:
        await conn.execute("DROP TABLE IF EXISTS public.pilot_create_intent")
        await conn.execute("DROP TABLE IF EXISTS public.pilot_database_registry")
        # marker 留着、内容合法，只把它变成**不耐久**（崩溃后会被 truncate）。
        await conn.execute("ALTER TABLE public.pilot_cluster_marker SET UNLOGGED")
        # ⚠️ 前置：证明这个混合态真的造出来了 —— 否则下面两条断言是恒真的。
        persist = await conn.fetchval(
            "SELECT c.relpersistence::text FROM pg_class c"
            " WHERE c.oid = to_regclass('public.pilot_cluster_marker')")
        check(persist == "u", "⑤b 前置：marker 确实被改成 UNLOGGED 了",
              f"relpersistence = {persist!r}")
        check(not await conn.fetchval(
            "SELECT to_regclass('public.pilot_create_intent') IS NOT NULL"),
            "⑤b 前置：intent 表确实不在场")

        async def _never2(_seed):
            return False

        async def _noop2(_seed):
            return None

        cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8")
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_never2, release_seed_lock=_noop2)
            check(False, "⑤b 混合态下 init 必须拒", "竟然成功了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "no_marker",
                  "⑤b 在场但不耐久的表 → no_marker", f"实得 {exc.code}：{exc}")
        left = [t for t in ("pilot_create_intent", "pilot_database_registry")
                if await conn.fetchval(
                    "SELECT to_regclass($1) IS NOT NULL", f"public.{t}")]
        check(not left, "⑤b 缺席的表事后仍不存在（补建 DDL 一条都没跑）",
              f"竟然建出了 {left}")
        # 复原
        await conn.execute("ALTER TABLE public.pilot_cluster_marker SET LOGGED")
        await _apply_cluster_schema(conn)
        await _write_marker(conn)
    finally:
        await conn.close()
```

- [ ] **Step 4: 写 ㉙ 与 ㉚（插在 ㉘ 那段之后）**

```python
    # ── ㉙ init 每次都要**现查**，标记不得短路 ──────────────────────────
    #    「标记证明的是**有人曾声明过**，只有现查才证明**现在仍然成立**」——
    #    两条现实路径：当初为空的集群后来被拿去装了真实数据库；
    #    标记随 pg_dump / 卷拷贝被还原到另一个集群。
    scenario("㉙")
    print("㉙ 带合法标记的集群上事后出现无关库 → init 仍须拒")
    conn = await _connect(base_dsn)
    try:
        await conn.execute("CREATE DATABASE " + quote_ident(_UNRELATED_DB))

        async def _never3(_seed):
            return False

        async def _noop3(_seed):
            return None

        cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8")
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_never3, release_seed_lock=_noop3)
            check(False, "㉙ 集群含无关库时 init 必须拒（标记不能短路现查）", "竟然成功了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "unrelated_database",
                  "㉙ 有合法标记但集群变脏 → unrelated_database", f"实得 {exc.code}：{exc}")
        await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(_UNRELATED_DB))
    finally:
        await conn.close()

    # ── ㉚ 孤儿清理**取了锁就必须还** ────────────────────────────────
    #    会话级锁不还会一直挂在维护连接上，挡住后续同 seed 的运行，
    #    也让同一条连接上后来的「锁是否被持有」观察到一把本次从未刻意取过的锁。
    #    ⚠️ 判据**不能**写成「同一条连接还能再取到这把锁」—— advisory lock 在同一
    #       session 内可重入，那样写恒真。这里直接问模块自己的 `_SEED_LOCK_HELD_SQL`。
    scenario("㉚")
    print("㉚ 孤儿清理取了 seed 锁之后必须还回去")
    seed30 = "lifecycle_r30"
    db30 = f"kline_pilot_{seed30}"                       # 这个库**故意不存在**
    conn = await _connect(base_dsn)
    try:
        await harness.drop_database(base_dsn, db30)
        await conn.execute("DELETE FROM public.pilot_create_intent")
        # 指向一个已消失实例的孤儿行（db_oid 借 template1 的，且同名库不存在）
        await conn.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = 'template1'",
            db30, seed30, _CREATED_AT, f"lifecycle-{seed30}")
        check(not await _database_exists(conn, db30),
              "㉚ 前置：那条孤儿行指向的库确实不存在")

        took: list[str] = []

        async def _real_try_lock(seed_of_row):
            took.append(seed_of_row)
            return bool(await conn.fetchval(
                "SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))",
                seed_of_row))

        async def _real_release(seed_of_row):
            await conn.execute(
                "SELECT pg_advisory_unlock(hashtext('kline_pilot_' || $1))", seed_of_row)

        cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8")
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_real_try_lock,
                                      release_seed_lock=_real_release)
        except Exception as exc:
            check(False, "㉚ init 本身必须跑完", f"抛了：{type(exc).__name__}: {exc}")
        # 三条一起才算数：取过锁 + 孤儿真被清掉（证明清理路径真跑了）+ 锁已还。
        check(took == [seed30], "㉚ 前置：清理确实为这条孤儿行取过锁",
              f"try_seed_lock 收到的 seed 列表 = {took}")
        gone = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db30)
        check(gone == 0, "㉚ 孤儿行确实被清掉了（**看数据库状态**，不是看发过 DELETE）",
              f"事后仍有 {gone} 条")
        check(not await conn.fetchval(_SEED_LOCK_HELD_SQL, seed30),
              "㉚ init 返回后维护连接上**不再持有**那把 seed 锁")
        await conn.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db30)
    finally:
        await conn.close()
```

- [ ] **Step 5: 写 ㊱（紧接 ㉚ 之后）**

```python
    # ── ㊱ 孤儿删除判据必须**在锁内当下求值**，不能用预筛时的快照 ────────────
    #    ⚠️ 本档在参考分支上编号为旧 ㉖，而 main 的 ㉖ 已被 S1 的
    #       「凭据表清场只删点名的库名」占用 —— 故另编新号 ㊱，别沿用旧号。
    #    先 `SELECT` 出一批行、再逐行取锁、然后只按 dbname 删，中间的窗口里
    #    **同 seed 的另一次运行**可以启动、刷新它自己的 intent 行、崩在写 pilot_meta
    #    之前、并随连接断开释放会话锁 —— 此时本循环拿到锁，却按**快照时看到的陈旧状态**
    #    把那条**新鲜的恢复凭据**删掉，留下一个零对象例外再也授权不了的空残骸。
    scenario("㊱")
    print("㊱ 预筛之后被刷新的凭据不许被删（判据在锁内当下求值）")
    seed36 = "lifecycle_r36"
    db36 = f"kline_pilot_{seed36}"
    conn = await _connect(base_dsn)
    try:
        await harness.drop_database(base_dsn, db36)
        await conn.execute("CREATE DATABASE " + quote_ident(db36))
        await conn.execute("DELETE FROM public.pilot_create_intent")
        await conn.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db36, seed36, _CREATED_AT, f"lifecycle-{seed36}")
        # 造出「预筛时看起来超期」的状态
        await conn.execute(
            "UPDATE public.pilot_create_intent"
            "   SET inserted_at = now() - make_interval(secs => $2)"
            " WHERE dbname = $1", db36, float(INTENT_TTL_SECONDS + 3600))

        refreshed: list[str] = []

        async def _refresh_then_lock(seed_of_row):
            # 「预筛之后、取锁之前」的那个窗口：另一次运行刷新了自己的凭据。
            side = await asyncpg.connect(base_dsn)
            try:
                await side.execute(
                    "UPDATE public.pilot_create_intent SET inserted_at = now()"
                    " WHERE seed = $1", seed_of_row)
            finally:
                await side.close()
            refreshed.append(seed_of_row)
            return bool(await conn.fetchval(
                "SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))",
                seed_of_row))

        async def _release36(seed_of_row):
            await conn.execute(
                "SELECT pg_advisory_unlock(hashtext('kline_pilot_' || $1))", seed_of_row)

        cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8")
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_refresh_then_lock,
                                      release_seed_lock=_release36)
        except Exception as exc:
            check(False, "㊱ init 本身必须跑完", f"抛了：{type(exc).__name__}: {exc}")
        # ⚠️ **先断言注入真的发生了**：没触发的话下面那条「行还在」是恒真的，
        #    这一档就成了空转。
        check(refreshed == [seed36],
              "㊱ 前置：清理确实走到了取锁那一步（注入点被调用）",
              f"try_seed_lock 收到的 seed 列表 = {refreshed}")
        still = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db36)
        check(still == 1, "㊱ 窗口里被刷新的凭据**没有**被删（判据在锁内当下求值）",
              f"该行事后剩 {still} 条")
        await conn.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db36)
    finally:
        await conn.close()
    await harness.drop_database(base_dsn, db36)
```

- [ ] **Step 5b: 更新脚本尾部的「本脚本证明了什么」免责段**

⚠️ **这一步不是文档美化，是判据的一部分**：脚本尾部（约 L1783-1790）现在**逐字打印**着

```
⚠️ 仍**没有**覆盖的：
     · `--init-cluster-marker` 的幂等语义与孤儿 intent 清理 → 随 **S3** 补回；
```

S3 落地之后这句就成了**假陈述**，而这段话存在的全部理由正是「静默没验」与「验过了」在输出上完全一样。改成：

```python
    print("✅ 本片（S3）在 S2b′ 的基础上补齐 `--init-cluster-marker`：")
    print("   零副作用预检（⑤ ⑤b）、标记不得短路现查（㉙）、")
    print("   孤儿 intent 清理的取锁/还锁（㉚）与锁内当下求值（㊱）。")
    print("⚠️ 仍**没有**覆盖的：")
    print("     · 「不数 autovacuum worker」那一向没有常驻档（要改集群 autovacuum_naptime，")
    print("       对验收脚本太侵入）—— 由一次性真 PG 实验坐实并记进计划，如实登记。")
```

并把上一段 `print("✅ 本片（S2b′）…")` 那三行保留为**历史覆盖面的陈述**（它说的仍然为真），只是不再是「本片」—— 改成 `print("✅ 既有覆盖（S2b′）：…")`。

**⚠️ 「S3 待补」的措辞在这个脚本里有四处，不是一处** —— 按判据本身穷尽全仓，别只改被点名的那一处（`grep -n "S3" backend/scripts/*.py` 已实测，2026-08-14）：

| 行 | 内容 | 改法 |
|---|---|---|
| `verify_pilot_db_lifecycle.py:10` | docstring：「**此刻不跑**（随 S3 补回，见…）」 | 改成「已由 ⑤ ⑤b ㉙ ㉚ ㊱ 覆盖」 |
| `:180` | 「本片（S1）**只含不依赖破坏性入口的档**；其余随 S2 / S3 补回来」 | 改成「S1/S2/S3 已全部补齐」 |
| `:191` | 「⚠️ S3 搬「孤儿删除锁内原子求值」时同样撞号（旧 ㉖）—— 那一档届时另编，别沿用旧号」 | 改成「S3 已另编为 **㊱**」（**保留这条注释**，它是给下一个搬档的人看的档号史） |
| `:1787` | 运行时 print 的免责段（上面那段） | 见上 |

改完再 `grep -n "S3" backend/scripts/*.py` 确认没有残留的「待补」语义。

- [ ] **Step 6: 跑真 PG 确认全绿**

```bash
docker start qmt-pg-r8 qmt-pg-r8b
QMT_VERIFY_ALLOW_DESTRUCTIVE=1 "$PY" backend/scripts/verify_pilot_db_lifecycle.py 2>&1 | grep -E "档断言全部成立|FAIL|❌"
```
预期：**46 档断言全部成立**，无 FAIL。

同时人工核一遍尾部免责段的输出，确认里面**没有**「随 S3 补回」这类已经不成立的陈述：

```bash
QMT_VERIFY_ALLOW_DESTRUCTIVE=1 "$PY" backend/scripts/verify_pilot_db_lifecycle.py 2>&1 | grep -n "S3\|没有**覆盖"
```

- [ ] **Step 7: 另两个真 PG 脚本回归**

```bash
QMT_VERIFY_ALLOW_DESTRUCTIVE=1 "$PY" backend/scripts/verify_pilot_concurrency.py 2>&1 | grep -E "档断言全部成立|FAIL|❌"
QMT_VERIFY_ALLOW_DESTRUCTIVE=1 "$PY" backend/scripts/verify_pilot_two_phase_create.py 2>&1 | grep -E "档断言全部成立|FAIL|❌"
```
预期：**11 档** / **28 档**，与基线一致（S3 不动它们的路径）。

- [ ] **Step 8: 真 PG 变异验证（控制者亲跑，两条最关键的）**

```bash
cp backend/qmt_pilot_db.py /tmp/s3_t5_backup.py
```

| # | 变异 | 必须变红的档 |
|---|---|---|
| M24 | `_DELETE_ORPHAN_INTENT_SQL` 去掉 `EXTRACT(EPOCH FROM (now() - inserted_at)) >= $2 OR` 前半，改成只按 `NOT EXISTS(...)` —— 再把整段 `AND (...)` 删光 | **㊱**（被刷新的凭据被删掉，`still == 0`） |
| M25 | Task 2 的三条 `*_durable` 别名合回一条 `maintenance_tables_durable` | **⑤b**（`left` 非空 —— 补建 DDL 真的落地了） |
| M26 | 删掉清理循环的 `finally: await release_seed_lock(...)` | **㉚**（`_SEED_LOCK_HELD_SQL` 仍为真） |
| M27 | 删掉末尾的 `await assert_cluster_allowed(...)` | **㉙**（init 竟然成功了） |

每次跑完 `cp /tmp/s3_t5_backup.py backend/qmt_pilot_db.py` 复原。**绝不用 `git checkout`**。

- [ ] **Step 9: Commit**

```bash
git add backend/scripts/verify_pilot_db_lifecycle.py
git commit -m "S3 Task5：真 PG 验收补五档（⑤ ⑤b ㉙ ㉚ ㊱），lifecycle 41→46 档"
```

---

## 收口（Task 5 之后，宣称完成之前）

- [ ] **走 superpowers:verification-before-completion**：把下表逐条实测填满，**判绿读输出内容不读结论字样**。

| 闸门 | 基线 | S3 实测 |
|---|---|---|
| `"$PY" -m pytest backend/tests -q` | 770 passed | ___ passed |
| `verify_pilot_db_lifecycle.py` | 41 档 | 46 档 |
| `verify_pilot_concurrency.py` | 11 档 | 11 档 |
| `verify_pilot_two_phase_create.py` | 28 档 | 28 档 |
| 变异表 M1–M27 | — | 逐条「变异 → 具名用例变红 → `cp` 复原」，由控制者亲跑 |

- [ ] **写非 coder 可执行的验收清单**（中文，action / expected / pass-fail 三列；禁用 `.claude/workflow-rules.json` 里列的禁止措辞）—— 这是仓库治理条款 2 的硬要求，每个模块/阶段交付都要有。

- [ ] **codex 对抗评审**（**通过脚本调，不是 Skill**）：

```bash
bash .claude/scripts/codex-attest.sh --scope branch-diff --base 8578a59 --head feat/qmt-4a2b-s3-cluster-marker
```

  - ⛔ 绝不传未知参数（含 `--help` —— 兜底分支会把它当 focus 目标 → 假 approve + 脏账本）；
  - ⛔ 不许窄化 focus；跑的过程中别动那条分支（脚本检测 head 漂移会拒写账本）；
  - 收口后必须 **Read 账本文件**核实 `head_sha` == 当前 HEAD；
  - codex 没**真 approve** 就别写「收敛」—— 如实写 needs-attention / 接受残留 / override，并把边界写清楚；
  - 若 codex 达到 **5 轮仍未 approve**，按 autonomous 授权的 pause 条件停下来问 user。
  - ⚠️ CI 上的 `codex-review-verify` 目前因 **OpenAI 额度用尽** 而红，那不是评审结论，也不在必过门列表。

- [ ] **push / PR 由 user 在真终端跑**（我不跑）。给 user 的命令**一行一条**，不给多行块。

- [ ] PR 合并后才可以关 **#161**（它是 R1–R15 账本的唯一完整记录；S3 一合它就一行有用代码都不剩了）。

---

## Self-Review

**1. spec 覆盖**

| spec 要求（§4 L515-521 / L660-680） | 落在哪 |
|---|---|
| 幂等：已存在合法单行标记 **且** intent 形状合规 → 直接成功 | Task 3 `test_init_is_idempotent_when_everything_is_already_legal` + `…executes_no_ddl_at_all_on_a_healthy_cluster` |
| 标记合法但 intent 表缺失/形状不符 → 补建再成功 | Task 3 `test_init_repairs_a_cluster_initialized_by_an_older_build` + `…still_repairs_a_genuinely_absent_table` |
| 标记非法/多行 → 拒绝，人工处理 | Task 3 `test_init_rejects_an_illegal_marker`（两档） |
| 谁写/谁读/谁清：本工具**从不清标记** | 实现里只有 `_WRITE_MARKER_SQL`（INSERT … ON CONFLICT DO NOTHING），全模块无删 marker 的语句；Task 5 档 ⑤/⑤b 的复原语句是**脚本自己造前置状态**，不经 `init_cluster_marker` |
| 孤儿清理**只在这里做** | 生产代码里 `_DELETE_ORPHAN_INTENT_SQL` 只有一个使用点（`init_cluster_marker`） |
| ① 逐行先取该行 seed 的锁，取不到就跳过 | Task 4 M13 / M14 + `test_init_cleans_orphan_rows_only_under_the_seed_lock` |
| ② 取到才删、删完立刻释放 | Task 4 M18 / M19 + 真 PG ㉚ |
| ③ 判据 = 超期 OR 库不存在，且「库不存在」在**同一条 SQL 里当下求值** | Task 4 M20 / M16 + 真 PG ㊱ |
| 验收断言必须看**数据库状态** | ㉚ 的 `gone == 0`、㊱ 的 `still == 1`、⑤/⑤b 的 `to_regclass(...)` —— 全部查表，无一条只断言「发过 DELETE」 |

**2. 占位符扫描**：无 TBD / TODO / 「similar to Task N」；每个代码步骤都带完整可粘贴的代码块。唯一的「以实测为准」是 Task 3/4 Step 6 的 pytest 总数 —— 那是**故意的**（内嵌「跑某命令应得 N」的自证会自过期，本仓踩过），判绿判据写的是「无 failed/error」而不是硬编码数字。

**3. 类型一致性**：`init_cluster_marker(maint_conn, *, connect, cluster_schema_sql, try_seed_lock, release_seed_lock)` 的签名在 Task 3 定义、Task 4 追加使用、Task 5 三处调用，五处逐字一致。`_LIST_ALL_INTENT_SQL` 的输出列（`dbname` / `seed` / `db_oid` / `age_seconds`）与假件 `_orphan()` 的字典键、与循环体读的键，三处逐字一致。`_DELETE_ORPHAN_INTENT_SQL` 的两个参数（`$1=dbname`、`$2=ttl`）与调用处 `(r["dbname"], INTENT_TTL_SECONDS)` 一致，且被机械守卫 `sql.count("$1") == 1 and sql.count("$2") == 1` 钉住。

**4. 已知的判别力空缺（诚实登记）**：
- Task 2 里闸 (i) 新增的三条 `*_durable` 参数化档**对别名拆分零判别力**（假件整字典回传）——已在 Task 2 正文里写明，判别力由 `test_shape_fakes_cover_every_predicate`（机械）+ Task 3 的混合态用例（行为）+ 真 PG ⑤b（语义）三层提供。
- Task 4 里四条反向钉（`…only_under_the_seed_lock` / `…keeps_a_fresh_row…` / `…does_not_release_a_lock_it_never_took` / `…refuses_when_the_callback_lies…`）在功能未实现时**恒绿**，不能当「红→绿」证据 —— 已在 Step 2 写明，判别力由 M13/M15/M19/M17 逐条证明。
