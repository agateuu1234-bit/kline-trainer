# QMT 4a-2b 切片 S3：`init_cluster_marker` 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> 每个 Task 内部必须走 superpowers:test-driven-development：**先写测试 → 亲眼看红 → 再实现 → 看绿**。
> 宣称完成前走 superpowers:verification-before-completion。

**Goal:** 把 4a-2b 唯一还欠 main 的生产符号 `init_cluster_marker` 落地 —— `--init-cluster-marker` 的幂等语义（已合法则直接成功／旧版本部分初始化则补建／标记非法则拒）＋ 孤儿 `pilot_create_intent` 行清理（判据「超期 OR 库不存在」在 **advisory lock 内、由同一条 SQL 当下求值**）。做完 4a 全部闭合。

**Architecture:** 纯增量 —— 在 `backend/qmt_pilot_db.py` 末尾新增一个公开 async 函数 `init_cluster_marker` 及其五条私有 SQL 常量与一个规范哈希常量；另把已存在的 `_MAINTENANCE_SHAPE_SQL` 里那条**跨三张表**的耐久性判据拆成**每表一条**（它是新函数「只对在场的表求值」的前缀归属机制的前提）。函数分两段：**① 零副作用预检 → ② 才允许动 DDL**。孤儿清理排在最后，逐行取锁、锁内原子求值、取了就还。

**Tech Stack:** Python 3.11 / asyncpg（生产代码只接受已连好的 conn，模块自身不做文件 IO、不取锁）/ pytest（host 假件层）/ 真 PostgreSQL 验收脚本 `backend/scripts/verify_pilot_db_lifecycle.py`。

---

## 评审收口状态（2026-08-14，**必须先读**）

**codex 对抗评审跑了 7 轮，`verdict` 全部是 `needs-attention`，⛔ 从未 approve。**
由 **user 在 R7 后显式拍板终止评审、转入实施**（第 7 轮结论：1 high，已修）。

- **账本未写**（脚本对非 approve 一律不写账本），这份计划**没有** codex 背书。
- 七轮共 **13 条 finding，零重复、零边角料**，全部已修；逐轮记录见文末 Self-Review 第 4 节。
- ⚠️ **终止的理由不是「挖干净了」**：R3 / R5 / R7 三轮抓到的都是**我上一轮修复引入的新洞**，
  近四轮稳定在 1 high，不收敛也不发散。终止的判断是
  **「继续在文档层推演的边际收益已低于引入新洞的风险」** ——
  剩余风险的正确兜底是实施阶段的 pytest / 真 PG 48 档 / 43 条变异，
  那些 codex 读不到也跑不了。
- ⛔ **本次 override 的边界**：它只覆盖「**停止继续评审这份计划文档**」。
  **不覆盖**实施质量 —— 下面每一条前置约束、每一条变异验证、每一档真 PG 断言
  仍然必须逐条兑现；实施完成后的**整支分支**仍要再走一次 `codex:adversarial-review`。

### 实施前置约束（七轮评审确认的三条原则，写代码时逐条自查）

这三条不是风格建议，是 7 轮里**反复被证伪**的地方。每写完一个函数，对着它们自查一遍。

1. **副作用严格排在证明之后；不可回滚的信任写入必须是最后一句。**
   - R4：标记写在最终现查之前 → 失败的 init 留下合法标记。
   - R5：R4 修完之后，Task 4 又在函数末尾追加了会抛的清理 → 同一个洞复活。
   - **自查法**：对每个产生副作用的语句问「它之后还有没有会抛的代码？」
     对不可回滚的那个（`_WRITE_MARKER_SQL`）问「它是不是函数的字面最后一句？」

2. **调用方递进来的回调/参数，返回什么都不算证明；必须在活连接上复核。**
   - R2：`try_seed_lock` 返回真 ≠ 真持有锁（advisory lock 同 session 可重入，真 PG 15.12 实测坐实）。
   - R4：`release_seed_lock` 返回 ≠ 真释放了。
   - **自查法**：每个回调的返回值旁边，问「有没有一条查活连接的 SQL 在验它？」

3. **凭据必须挂在它的信任根上；别把它从根上摘下来单独用。**
   - R7：登记表在闸 (ii) 里可信，是因为闸 (i) **先**验过标记。
     我只看「登记表在不在场」就拿来用 → 标记缺失时凭据无根 → 可被伪造。
   - **自查法**：用任何凭据之前，问「**凭什么信它**？那个理由这一刻成立吗？」

**外加两条实施纪律（本轮踩过）：**

4. **反向钉必须造得出「出问题的那个组合」。**
   R7 的洞之所以躲过我自己的测试，是因为那条反向钉把 `presence` 三个全设 False，
   恰好绕开了「标记缺失但登记表在场」。**写完每条反向钉，问它对哪条判据真有判别力。**

5. **假件先自证，再拿去证明生产代码。**
   R3：`_InitMaint` 的初始化被误放到 `return` 之后成死代码，`intent_table_missing=True`
   整个失效，补建路径几条用例改测了健康集群。故有
   `test_init_maint_fake_actually_models_the_states_it_claims`。

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

  ⚠️⚠️ **每一次变异与每一次复原之后都必须清 `__pycache__`，否则整套变异验证是假的**
  （2026-08-14 实测踩到，Task 1 M1 当场复现）：
  CPython 的 `.pyc` 失效判据是 **`(源文件 mtime 的秒, 源文件 size)` 二元组**。
  本计划的变异**绝大多数是等长替换**（`3985`→`3986`、`now()`→`now()`、
  `$2`→`$3`、删一个 `and` 再补空格……），而 `cp` 复原又常常发生在**同一秒**内 ——
  于是 size 与 mtime-秒**双双不变**，Python 直接用**上一次编译的字节码**。
  实测现场：源文件里明明是 `…3985`，`import` 到的却是 `…3986`。
  **危险方向是反的**：变异后若命中旧缓存会显示**绿**，
  你会据此断定「这条测试对该判据没有判别力」，然后去改一条**本来是对的**测试，
  或把一个**真实存在**的缺口当成已覆盖放过去 —— 正是本仓「假绿家族」的新成员。

  ```bash
  # 每条变异都套这个壳，别省
  nuke(){ find backend -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null; true; }
  cp backend/qmt_pilot_db.py /tmp/s3_backup.py
  <改判据>            ; nuke; "$PY" -m pytest <具名用例> -q   # 必须红，且红的是具名那条
  cp /tmp/s3_backup.py backend/qmt_pilot_db.py ; nuke
  "$PY" -m pytest <具名用例> -q                              # 必须回绿，否则复原没生效
  ```
  **复原之后必须再跑一次确认回绿** —— 那是「复原真的生效了」的唯一证据。
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

**S3 完成后 `_EXPECTED_SCENARIOS` = 48 档。**

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
    """维护连接：三张表的「在场」与「补建后才合规」、全表 intent 扫描、**锁状态的迁移**。"""

    def __init__(self, all_intent_rows=(), intent_table_missing=False,
                 pre_held_seeds=(), **kw):
        super().__init__(**kw)
        self.all_intent_rows = list(all_intent_rows)
        # ⚠️ **锁状态必须建模成会变的集合，不能是一个静态布尔**（codex S3-R2 之后）：
        #    孤儿清理现在在**取锁前后各查一次** `_SEED_LOCK_HELD_SQL` ——
        #    前一次必须为假（证明这把锁不是本连接早就持有的），后一次必须为真
        #    （证明回调真的把它取到了）。父类的 `seed_lock_held` 是**一个布尔**，
        #    两次查询会得到同一个答案，于是**两条判据里必然有一条恒真、测不出东西**。
        #    改成集合之后，`_locker` 在授予时写入、释放时移出，两次查询自然不同。
        #    `pre_held_seeds` = 进入 init **之前**就已挂在这条连接上的锁（可重入那一档）。
        self.held_seeds = set(pre_held_seeds)
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

    async def fetchval(self, query, *args):
        # 父类按 `"pg_locks" in query` 返回静态布尔；这里改成按集合作答。
        # ⚠️ 本方法**只建模锁状态**，别往里塞构造期的初始化 —— 那样会落在
        #    `return` 之后成为死代码，而假件「看起来配好了」（S3-R3 实测踩过：
        #    `intent_table_missing=True` 整个失效，补建路径那几条用例改测了健康集群）。
        if "pg_locks" in query:
            self.ops.append(query)
            return args[0] in self.held_seeds
        return await super().fetchval(query, *args)

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


def _locker(maint=None, *, grants=True, record=None, released=None):
    """返回 (try_seed_lock, release_seed_lock) 一对 —— **取了就必须还**。

    ⚠️ 真授予时**同步更新假件的 `held_seeds`**：模块随后要在 `maint_conn` 上用
       `_SEED_LOCK_HELD_SQL` 复核，「回调说取到了」与「连接上真挂着」必须一致。
       两者**故意可以做成不一致** —— 那正是「回调撒谎」那一档（传一对不更新
       `held_seeds` 的自制回调即可，见
       `test_orphan_cleanup_refuses_when_the_callback_lies_about_the_lock`）。
    """
    async def _try(seed):
        if record is not None:
            record.append(seed)
        if grants and maint is not None:
            maint.held_seeds.add(seed)
        return grants

    async def _release(seed):
        if released is not None:
            released.append(seed)
        if maint is not None:
            maint.held_seeds.discard(seed)
    return _try, _release


def _init(maint, *, targets=None, lock_pair=None):
    try_lock, release_lock = lock_pair or _locker(maint)
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
def test_init_maint_fake_actually_models_the_states_it_claims():
    """**假件自检**：`_InitMaint` 的两个开关必须真的改变它的作答（codex S3-R3）。

    ⚠️ 这不是形式主义。实测踩过：`maintenance_presence` / `intent_table_missing`
       的初始化被误放到 `fetchval` 的 `return` **之后**成了死代码 ——
       假件「看起来配好了」，而 `intent_table_missing=True` 整个失效，
       补建路径那几条用例**改测了健康集群**（`_needs_repair_ddl` 恒假），
       于是「旧版本集群修不修得好」「混合态零 DDL」两条判据一次都没被求值。
       与 `test_shape_fakes_cover_every_predicate` 同族：**先证明假件建模对了，
       再拿它去证明生产代码**。
    """
    healthy = _InitMaint()
    assert healthy.maintenance_presence == {
        "marker_present": True, "intent_present": True, "registry_present": True}
    assert healthy.maintenance_shape == _OK_MAINTENANCE_SHAPE

    missing = _InitMaint(intent_table_missing=True)
    assert missing.maintenance_presence["intent_present"] is False, \
        "intent_table_missing 没有把 intent 置为缺席 —— 补建路径的用例会改测健康集群"
    for key in ("intent_is_table", "intent_columns_ok", "intent_dbname_unique",
                "intent_durable"):
        assert missing.maintenance_shape[key] is False, f"{key} 没有跟着置假"
    # marker / registry 不受影响 —— 否则造出来的是「三张全缺」而不是**混合态**
    assert missing.maintenance_presence["marker_present"] is True
    assert missing.maintenance_shape["marker_durable"] is True

    # 锁状态：默认空；`pre_held_seeds` 真的会被 `_SEED_LOCK_HELD_SQL` 看见
    assert _InitMaint().held_seeds == set()
    assert _InitMaint(pre_held_seeds=("x",)).held_seeds == {"x"}


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
    # ⚠️ **一对回调必须来自同一次 `_locker(...)` 调用**：写成
    #    `try_seed_lock=_locker(maint)[0], release_seed_lock=_locker(maint)[1]`
    #    会造出**两对互不相干**的闭包，`record` / `released` 各记各的 —— 一族
    #    「取了没还」的断言会因此恒真。
    _lp = _locker(maint)
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(init_cluster_marker(
            maint, connect=_connector({}), cluster_schema_sql=evil,
            try_seed_lock=_lp[0], release_seed_lock=_lp[1]))
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


def test_init_does_not_leave_a_marker_when_the_final_gate_rejects():
    """**标记必须是最后一个不可回滚的信任写入**（codex S3-R4）。

    上一版是「先写标记、再跑现查」，而现查**仍然可能拒绝** —— 预检通过之后、
    写标记之前的窗口里冒出一个同侪库、连不进某个库、维护库多了用户对象，
    都会让它抛。于是一次**报告失败**的 `--init-cluster-marker` 却在集群里留下了
    一个**合法标记**；而本工具的契约是**从不清标记**，这份残留只能人工收拾。

    ⚠️ 造法：让「预检那一刻干净、最终现查那一刻变脏」—— 第二次枚举 pg_database
       时才冒出无关库。只在构造函数里设 `databases` 是造不出这个窗口的
       （那样预检就先拒了，测不到本条判据）。
    """
    class _DirtyOnSecondScan(_InitMaint):
        def __init__(self, **kw):
            super().__init__(**kw)
            self.db_scans = 0

        async def fetch(self, query, *args):
            if "datistemplate" in query:
                self.db_scans += 1
                if self.db_scans >= 2:          # 第二次现查时集群已经变脏
                    self.databases = ["payments_prod"]
            return await super().fetch(query, *args)

    maint = _DirtyOnSecondScan(marker_rows=[])   # 首次初始化
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "unrelated_database"
    assert maint.db_scans >= 2, \
        "只枚举了一次 pg_database —— 写标记之前那道现查根本没跑，这条用例在空转"
    assert _marker_writes(maint) == [], \
        "最终现查拒绝了，却已经把标记写进去了 —— 一次失败的 init 留下了合法标记"


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


def test_repair_accepts_a_registered_nonempty_pilot_peer(): 
    """**混合态修复必须认同侪库的归属登记**（codex S3-R6）。

    形态：marker + `pilot_database_registry` 在场且合规，只有 `pilot_create_intent` 缺失，
    而集群里有一个**已登记的、装着真数据的**合法 pilot 库。

    此前所有「要动 DDL」的路径都走【绝对空】严判据 —— 于是这个完全正常的库被判成
    外来物，整台集群被锁在修复路径之外。而 O4-F7 引入修复路径的**全部理由**就是
    「短路成功的实现修不好旧版本初始化的集群」；对一台真有 pilot 库的集群修不了，
    等于这条路径没兑现它的承诺。这是 spec 反复打的**锁死**洞（R55-F1 一族）换形态。

    ⚠️ 严判据在**首次初始化**那一刻仍是对的（登记表根本不存在，凭据无从取得）——
       由 `test_init_proves_peer_databases_are_clean_before_any_ddl` 守着，别一起放宽。
    """
    peer = _FakeConn(user_objects=[("pg_class", 42)],          # 非空：装着真数据
                     meta_rows=[{"key": k, "value": v} for k, v in {
                         "tool": "qmt_pilot", "seed": "live", "state": "ready",
                         "contract_version": CONTRACT_VERSION,
                         "export_log_sha256": "a" * 64, "output_dir": "/x/y",
                         "created_at": "20260809T101530123456Z"}.items()])
    maint = _InitMaint(intent_table_missing=True,              # 混合态：只缺 intent
                       databases=["kline_pilot_live"],
                       registered_dbnames={"kline_pilot_live"})
    asyncio.run(_init(maint, targets={"kline_pilot_live": peer}))
    assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
        "已登记的非空 pilot 库把修复路径挡住了 —— 锁死洞原样复活"


def test_repair_still_rejects_an_unregistered_nonempty_peer():
    """**反向钉**：登记表可用**不等于**放行一切非空同前缀库。

    两个独立事实缺一不可 —— 库自己的 `pilot_meta` 合规（自证）**且**这个库名
    确实在维护库的登记表里（被判对象改不到）。这里造「meta 像样但没登记」，
    必须仍然拒。否则上面那条放宽就把闸 (ii) 的外部凭据整个掏空了。
    """
    peer = _FakeConn(user_objects=[("pg_class", 42)],
                     meta_rows=[{"key": k, "value": v} for k, v in {
                         "tool": "qmt_pilot", "seed": "faker", "state": "ready",
                         "contract_version": CONTRACT_VERSION,
                         "export_log_sha256": "a" * 64, "output_dir": "/x/y",
                         "created_at": "20260809T101530123456Z"}.items()])
    maint = _InitMaint(intent_table_missing=True,
                       databases=["kline_pilot_faker"],
                       registered_dbnames=set())               # **没**登记
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, targets={"kline_pilot_faker": peer}))
    assert ei.value.code == "unowned_pilot_database"
    assert maint.executed == [], "拒绝之前已经执行了 DDL"


def _registered_looking_peer(seed="live"):
    """一个**非空**、且自己写了一份合规 pilot_meta 的同前缀库。"""
    return _FakeConn(user_objects=[("pg_class", 42)],
                     meta_rows=[{"key": k, "value": v} for k, v in {
                         "tool": "qmt_pilot", "seed": seed, "state": "ready",
                         "contract_version": CONTRACT_VERSION,
                         "export_log_sha256": "a" * 64, "output_dir": "/x/y",
                         "created_at": "20260809T101530123456Z"}.items()])


@pytest.mark.parametrize("presence_over,label", [
    ({"marker_present": False, "intent_present": False, "registry_present": False},
     "三张表都不在场（真·首次初始化）"),
    # ⚠️ **这一档是 codex S3-R7 抓到的洞**：上一版只造了「三张全不在场」，
    #    于是「标记缺失、登记表在场」这个组合**一次都没被测过**，
    #    而放宽判据当时只看 `registry_present` —— 它正好在这一档为真。
    ({"marker_present": False, "intent_present": False, "registry_present": True},
     "标记缺失但登记表在场（人工清过标记 / 部分还原 / 对手写入）"),
    ({"marker_present": False, "intent_present": True, "registry_present": True},
     "标记缺失、另两张都在场"),
])
def test_no_legal_marker_never_gets_the_registry_relaxation(presence_over, label):
    """**没有合法标记时，登记表不构成可信凭据**（codex S3-R7）。

    标记才是「这个维护库是我们的」那句话的**信任根** —— 闸 (ii) 之所以敢信登记表，
    正因为闸 (i) **先**验过标记。放宽若只看 `registry_present`，则：
    人工清过标记（契约明写这是**人工动作**）、维护库被部分还原、或对手能写维护库时，
    登记表里的行会被当成归属证明 → 一个**非空的、装成 pilot 样子的**同前缀库过关
    → 然后**写下一个合法标记**。等于绕过首次初始化的【绝对空】证明，
    还把「人工清标记」这个逃生阀一并废掉。

    ⚠️ 反向的一半由 `test_repair_accepts_a_registered_nonempty_pilot_peer` 守着
       （标记在场的混合态**必须**认登记凭据），别把这条修成「一律严判据」。
    """
    peer = _registered_looking_peer()
    maint = _InitMaint(marker_rows=[], databases=["kline_pilot_live"],
                       registered_dbnames={"kline_pilot_live"})
    maint.maintenance_presence = {**maint.maintenance_presence, **presence_over}
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, targets={"kline_pilot_live": peer}))
    assert ei.value.code == "unowned_pilot_database", label
    assert _marker_writes(maint) == [], \
        f"{label}：拒绝了，却已经把标记写进去了"
    assert maint.executed == [], f"{label}：拒绝之前已经执行了 DDL"


def test_both_peer_proofs_use_the_same_two_facts():
    """机械守卫：闸 (ii) 与修复路径的归属判据**必须是同一组两个事实**。

    同一条判据在两处各写一遍是本仓反复栽的形态。这里不要求两处代码相同（它们的
    上下文不同），但要求**都**引用 `_looks_like_our_pilot_db` 与 `_REGISTRY_HAS_SQL`
    —— 任一处日后被改成「只看 pilot_meta」就当场变红。
    """
    import inspect
    import qmt_pilot_db as m
    for fn in (m.assert_cluster_allowed, m._assert_disposable_cluster):
        src = inspect.getsource(fn)
        assert "_looks_like_our_pilot_db(" in src, f"{fn.__name__} 缺自证那一半"
        assert "_REGISTRY_HAS_SQL" in src, f"{fn.__name__} 缺外部登记凭据那一半"
        assert "_is_absolutely_empty(" in src, f"{fn.__name__} 缺【绝对空】那一档豁免"


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


async def _assert_disposable_cluster(maint_conn, *, connect,
                                     registry_usable: bool = False) -> None:
    """「这台集群整个可弃」的**免标记**证明 —— 首次初始化用的那一组闸 (ii)(iii)。

    `registry_usable`：`pilot_database_registry` **在场且形状合规**时传 True
    —— 那时同侪库的**外部归属凭据取得到**，就不该再要求它们【绝对空】。
    详见下面「两种同侪库判据」那一段（codex S3-R6）。

    ⚠️ **调用方一律传 `presence["registry_present"]`，即「动 DDL 之前」的在场情况**，
       不要在 DDL 之后重新查一次：补建刚造出来的登记表**必然是空的**，
       拿它去「证明」同侪库归属等于零证据。用 DDL 前的快照既正确又保守 ——
       首次初始化那一刻登记表不存在 → 严判据；混合态修复时它带着真实内容 → 认凭据。
    ⚠️ 形状不合规的登记表走不到这里：`init_cluster_marker` 的 1b 那一步
       （在场的表必须各自合规）会**零 DDL** 先拒掉，故「在场」即「可用」。

    ⚠️ **和 `assert_cluster_allowed` 的区别，以及为什么两个都要有**：
      · `assert_cluster_allowed` 的闸 (i) 要求**已经有合法标记** —— 首次初始化时
        标记还没写，它必然拒绝。而闸 (ii) 的完整版会认同侪 pilot 库的**归属登记**，
        那在首次初始化时必然为空。
    **两种同侪库判据，由 `registry_usable` 选（codex S3-R6）**：
      · `registry_usable=False`（**首次初始化，或标记缺失**）：没有合法标记时，
        登记表**不构成可信凭据** —— 标记才是「这个维护库是我们的」那句话的信任根，
        闸 (ii) 之所以敢信登记表，正因为闸 (i) **先**验过标记（codex S3-R7）。
        故此时同侪库的外部凭据**取不到**，「证明不了」只能等价于「拒绝」，
        要求同前缀库【绝对空】。
      · `registry_usable=True`（**混合态修复**：marker + registry 在场、intent 缺失）：
        登记表在场且合规（形状不合规的话 1b 那一步早就零 DDL 拒了），
        于是**外部归属凭据取得到** —— 此时仍要求【绝对空】会把一个
        **已登记的、装着真数据的合法 pilot 库**判成外来物，
        把整台集群锁在修复路径之外。而 O4-F7 引入修复路径的全部理由，
        就是「短路成功的实现修不好旧版本初始化的集群」。
        ⚠️ 这正是 spec 反复打的那类**锁死**洞（R55-F1 一族）换了个形态。
      · 归属证明与闸 (ii) 用**同一组两个独立事实**：库自己的 `pilot_meta` 合规
        （`_looks_like_our_pilot_db`）**且**这个库名在维护库的登记表里确实被声明过
        （`_REGISTRY_HAS_SQL`，它 JOIN `pg_database` 绑实例）。
        两条都不成立时才落到【绝对空】那一档。
      · 反过来，把严判据套到**已建成**的集群上同样会把正常的 pilot 库判成外来物，
        所以已有标记且三表齐全的那条路仍然走 `assert_cluster_allowed`（完整闸 (i)(ii)(iii)）。

    ⚠️ **零副作用**（只读），故可以在同一次运行里调用两次：
      一次在动 DDL **之前**（不在别人的库里留下表），
      一次在写标记**之前**（标记是不可回滚的信任写入，见调用点）。
    """
    leftover = await _user_objects(maint_conn, exempt_maintenance=True)
    if leftover:
        raise PilotClusterBoundaryError(
            "maintenance_db_not_empty",
            f"维护库除 {MAINTENANCE_TABLES} 外还有用户对象 {leftover}"
            f"——「没有别的数据库」不等于「这台集群没在用」。"
            f"在证明它可弃之前，本工具不会在它上面建任何表")
    _cluster_id = await cluster_identity(maint_conn)
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
            await adopt_connection(other, name, cluster_id=_cluster_id,
                                   expected_oid=row["db_oid"])
            if registry_usable:
                # ⚠️ 与闸 (ii) **同一组两个独立事实**：库自己的 pilot_meta 合规
                #    （自证）**且**这个库名在维护库的登记表里被声明过（被判对象改不到，
                #    且 `_REGISTRY_HAS_SQL` JOIN `pg_database` 绑实例）。
                # ⚠️ 读 meta 失败/形状不合规**不在这里拒**：下面还有【绝对空】那一档豁免
                #    （与闸 (ii) 的处理逐字一致 —— 否则一个合法的崩溃残骸会被判成外来物）。
                try:
                    meta = await read_pilot_meta_rows(other)
                except Exception:
                    meta = {}
                if _looks_like_our_pilot_db(meta, name) and await maint_conn.fetchval(
                        _REGISTRY_HAS_SQL, name, meta.get("seed")):
                    continue              # 已登记的合法 pilot 库 → 放行
            if not await _is_absolutely_empty(other):
                raise PilotClusterBoundaryError(
                    "unowned_pilot_database",
                    f"{name!r} 名字匹配 kline_pilot_* 但非空"
                    + ("，且它没有合法 pilot_meta / 没在维护库的登记表里登记过"
                       if registry_usable else
                       "，且这台集群还没有任何归属登记")
                    + "——前缀名不是归属证明，拒绝把它声明为 pilot 专用集群")
        except PilotClusterBoundaryError:
            raise
        except Exception as exc:
            raise PilotClusterBoundaryError(
                "unowned_pilot_database",
                f"验 {name!r} 是否为空时失败（{exc}）→ 无法证明") from exc
        finally:
            await _close_quietly(other, name)


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

    # 1c-2. **登记表能不能当归属凭据用**（codex S3-R7）。
    #    ⚠️ **必须同时要求「已有合法标记」**，不能只看登记表在不在场：
    #       登记表在 gate (ii) 里之所以可信，是因为闸 (i) **先**验过标记 ——
    #       标记才是「这个维护库是我们的」那句话的**信任根**。
    #       marker 缺失 / registry 在场且有行 这个组合是**真实可达**的：
    #         · 契约明写「清除标记是**人工动作**」，人真的清过；
    #         · 维护库被部分 pg_dump/还原；
    #         · 对手能写维护库。
    #       只看 `registry_present` 的话，这三种情形下 registry 的行会被当成归属证明，
    #       让一个**非空的、装成 pilot 样子的**同前缀库过关，然后**写下一个合法标记** ——
    #       等于绕过首次初始化的【绝对空】证明，把人工清标记这个逃生阀也一并废掉。
    #    ⚠️ 形状不合规的登记表走不到这里（1b 已零 DDL 拒），故「在场」即「形状可用」；
    #       但**可用 ≠ 可信**，可信要由标记来背书。
    _registry_usable = bool(rows) and presence["registry_present"]

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
        await _assert_disposable_cluster(maint_conn, connect=connect,
                                         registry_usable=_registry_usable)

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

    # 3+4. **现查一遍集群仍然可弃，然后（首次初始化时）才写标记**。
    #    spec §4 R17-F1 逐字写着：「标记证明的是**有人曾声明过**，只有现查才证明
    #    **现在仍然成立**」，并点名两条现实路径 ——
    #    ① 当初为空的 pilot 集群后来被拿去装了真实数据库；
    #    ② 标记随 pg_dump / 卷拷贝被**还原或复制到另一个集群**。
    #
    # ⚠️ **次序：现查在前、写标记在后**（codex S3-R4）。上一版是「先写标记、
    #    再跑 `assert_cluster_allowed`」，而那一步**仍然可能拒绝** —— 窗口里冒出一个
    #    同侪库、连不进某个库、维护库多了用户对象，都会让它抛。于是一次**报告失败**的
    #    `--init-cluster-marker` 却在集群里留下了一个**合法标记**；而本工具的契约是
    #    **从不清标记**（清除是人工动作），这份残留只能人工收拾，
    #    并且让后来的人看到一个「从未由成功的 init 产生过」的标记。
    #    改法：把标记写入变成**最后一个、不可回滚的信任写入**。
    #    （⛔ 另一条路「失败时把本次写的标记删掉」被否：那要给本模块新增
    #      「删标记」这一能力，与「本工具从不清标记」的契约直接冲突。）
    if rows:
        # 已有合法标记 → 用**完整的** `assert_cluster_allowed`：此刻标记与三张表
        # 都已就位，(i) 过得了；而 (ii) 的完整版会认同侪 pilot 库的**归属登记** ——
        # `_assert_disposable_cluster` 那组严判据（同前缀库必须绝对空）只在
        # 登记表必然为空的首次初始化那一刻成立，套到已建成的集群上会把正常的
        # pilot 库判成外来物。本条路**不写标记**，故没有次序问题。
        await assert_cluster_allowed(maint_conn, connect=connect, target_db=None)
    else:
        # 首次初始化：标记还没写，闸 (i) 必然拒绝，故用**免标记**的等价现查。
        # ⚠️ 这一次是在 DDL **之后**跑的，与 1d/1e 那次不是同一个时刻 ——
        #    正是它把「预检通过之后、写标记之前」那个窗口关上。
        await _assert_disposable_cluster(maint_conn, connect=connect,
                                         registry_usable=_registry_usable)
        # ⚠️ **本函数唯一不可回滚的信任写入，必须排在所有会拒绝的检查之后。**
        await maint_conn.execute(_WRITE_MARKER_SQL, MARKER_PURPOSE)
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
- Produces:
  - `_LIST_ALL_INTENT_SQL` —— 输出列 `dbname` / `seed` / `db_oid`(text) / `age_seconds`(**double precision，不取整**)
  - `_DELETE_ORPHAN_INTENT_SQL` —— 参数 **`$1=dbname`、`$2=seed`、`$3=ttl_seconds`（三个）**
    ⚠️ **`$2=seed` 不是记账细节，是信任边界**：这条 DELETE 的授权来自「本次持有的是
    **这一行 seed** 的 advisory lock」。写成两参数（只按 dbname 删）就等于让实现/评审
    清单里出现一条「不绑所锁那一行也算对」的契约，而 dbname↔seed 的对应**没有任何
    数据库约束在兜**（无 CHECK、`dbname` 非生成列）。调用处必须是
    `(r["dbname"], r["seed"], INTENT_TTL_SECONDS)`。

- [ ] **Step 1: 写失败的测试**

追加到 `backend/tests/test_qmt_pilot_db.py`（Task 3 那批之后）：

```python
def test_init_cleans_orphan_rows_only_under_the_seed_lock():
    """不持 seed 锁就删，会删掉**一次正在进行的运行**的行 → 那次运行随后判零对象例外
    第 6 条不成立 → **自己的残骸自己清不掉**（spec O4-F2 修正③）。"""
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_running",
                                                seed="running")])
    asyncio.run(_init(maint, lock_pair=_locker(maint, grants=False)))
    assert _deletes(maint) == [], "取不到 seed 锁就必须跳过，不得删"


def test_init_takes_the_lock_of_the_row_being_deleted():
    """锁必须**逐行按那一行的 seed** 取，不是随便取一把。"""
    asked = []
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    asyncio.run(_init(maint, lock_pair=_locker(maint, record=asked)))
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
    # 回调撒谎：`held_seeds` 始终为空（连接上并没有那把锁），而回调返回 True。
    maint = _InitMaint(all_intent_rows=[orphan])

    async def _lying_try(_seed):
        return True                            # 说取到了，实际 pg_locks 里没有

    async def _noop(_seed):
        return None

    asyncio.run(_init(maint, lock_pair=(_lying_try, _noop)))
    assert _deletes(maint) == [], "回调撒谎说持有锁，孤儿清理就把恢复凭据删了"


def test_orphan_cleanup_binds_the_delete_to_the_row_it_locked():
    """DELETE 必须按**取锁的那一行**删（codex S3-R2）。

    授权来自「本次持有的是这一行 seed 的 advisory lock」。只按 dbname 删的话，
    语句靠的是「dbname 恒为 `kline_pilot_<seed>`」这条**跨列不变量**，
    而它**没有任何数据库约束在兜** —— 孤儿清理处理的恰恰是来路不明的行
    （旧版本写的 / `pg_restore` 还原的 / 人工插的），对它们那条不变量不成立。
    """
    seen = []

    class _RecordArgs(_InitMaint):
        async def execute(self, query, *args):
            if query.strip().upper().startswith("DELETE"):
                seen.append(args)
            return await super().execute(query, *args)

    maint = _RecordArgs(all_intent_rows=[_orphan(dbname="kline_pilot_gone",
                                                 seed="gone")])
    asyncio.run(_init(maint))
    assert seen == [("kline_pilot_gone", "gone", INTENT_TTL_SECONDS)], \
        f"DELETE 的参数不是 (dbname, seed, ttl)：{seen}"


def test_orphan_cleanup_skips_a_seed_whose_lock_this_connection_already_holds():
    """**取锁之前先证明本连接还没持有它**（codex S3-R2，真 PG 15.12 实测坐实）。

    advisory lock 在同一 session 内**可重入**：实测 `pg_try_advisory_lock` 对一把
    本连接已持有的锁**照样返回 true**（计数器 1→2），而 `_SEED_LOCK_HELD_SQL`
    在调用之前**就已经是 true`** —— 于是「取到了 + 复核为真」这套证明
    对这一行**没有提供任何新的互斥**。

    危险的是**自己**这一档：本连接正在为该 seed 干别的事（4c 的 wrapper 把 init
    套进一次 create/reset、或连接池里漏回来一把锁），而这里把它**进行中的**
    恢复凭据删掉 —— 就是「不加锁会删掉一次正在进行的运行的行」换了个形态。

    ⚠️ 反向的一半由 `test_init_deletes_stale_or_vanished_rows` 兜着：
       事前**没**持有时照常清理，别把这条修成「一律跳过」。
    """
    took, freed = [], []
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")],
                       pre_held_seeds=("gone",))     # 事前就持有 → 必须 fail-closed
    asyncio.run(_init(maint, lock_pair=_locker(maint, record=took, released=freed)))
    assert _deletes(maint) == [], "本连接事前已持有该 seed 的锁，仍然删了凭据"
    assert took == [], "事前已持有就不该再去取锁（可重入只会让计数器涨上去）"
    assert freed == [], "没取过就不许还 —— 那会把别处正持有的锁释放掉"


def test_first_init_writes_no_marker_when_orphan_cleanup_fails():
    """**清理会抛，故必须排在写标记之前**（codex S3-R5）。

    这是 R4 那条修复的**续集**：R4 只把标记挪到了「首次初始化那一支的最后」，
    而 Task 4 随后在**整个函数的最后**又接了一段会抛的清理循环 ——
    首次初始化于是又能「报告失败、却留下一个合法标记」，
    而契约是「本工具从不清标记」。典型的「修 symptom 会挪动失败面」。
    """
    class _DeleteBoom(_InitMaint):
        async def execute(self, query, *args):
            if query.strip().upper().startswith("DELETE"):
                raise RuntimeError("deadlock detected")
            return await super().execute(query, *args)

    maint = _DeleteBoom(
        marker_rows=[],                                   # 首次初始化
        all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    with pytest.raises(RuntimeError):
        asyncio.run(_init(maint))
    assert _marker_writes(maint) == [], \
        "孤儿清理失败了，却已经把标记写进去了 —— 一次失败的 init 留下了合法标记"


def test_first_init_proves_the_cluster_again_immediately_before_the_marker():
    """信任写入必须由**紧挨着它**的证明背书（spec §4「DROP 前须紧贴着重查」同族）。

    授权清理的那次证明与写标记之间隔着整个清理循环 —— 取锁、DELETE、释放，
    每一步都要时间，窗口里集群可以变脏。
    """
    maint = _InitMaint(marker_rows=[],
                       all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    asyncio.run(_init(maint))
    assert len(_marker_writes(maint)) == 1

    # ⚠️ **判据是次序，不是计数**（`_FakeConn.ops` 的注释：「计数是脆弱断言 ——
    #    中间多一处合法调用就会假红；次序才是判据」）。这里要证的性质就一条：
    #    **写标记之前、清理之后，还有一次 pg_database 现查。**
    marker_at = next(i for i, q in enumerate(maint.ops)
                     if q.strip().upper().startswith("INSERT")
                     and "pilot_cluster_marker" in q)
    delete_at = max(i for i, q in enumerate(maint.ops)
                    if q.strip().upper().startswith("DELETE"))
    assert delete_at < marker_at, "清理排在了写标记之后 —— 会抛的活不许排在信任写入之后"
    assert any("datistemplate" in q for q in maint.ops[delete_at + 1:marker_at]), (
        "清理之后、写标记之前没有再现查一次 pg_database —— "
        "标记会由一次隔着整个清理循环的**陈旧**证明背书")
    # 标记必须是**最后一条**真正执行的语句：它之后不许再有任何会抛的活
    assert maint.executed[-1] == _marker_writes(maint)[0], \
        f"写标记之后还执行了别的语句：{maint.executed[maint.executed.index(_marker_writes(maint)[0]) + 1:]}"


def test_orphan_cleanup_verifies_the_release_actually_took_effect():
    """**还了也要验**（codex S3-R4）—— 与「取到了也要验」是同一条纪律。

    `release_seed_lock` 和 `try_seed_lock` 一样是**调用方递进来的回调**：空实现、
    连错连接、只释放一层可重入计数，都会「成功返回」而锁**仍挂在 `maint_conn` 上**。
    会话级锁泄漏会挡住后续同 seed 的建库/reset；更毒的是它会被
    `test_orphan_cleanup_skips_a_seed_whose_lock_this_connection_already_holds`
    那条 fail-closed 判据放大成「这条连接从此再也清不掉该 seed 的孤儿」——
    静默跳过，理由看起来还完全合理。
    """
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])

    async def _grant(seed):
        maint.held_seeds.add(seed)
        return True

    async def _noop_release(_seed):
        return None                    # 空实现：锁没还，`held_seeds` 里还留着

    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, lock_pair=(_grant, _noop_release)))
    assert ei.value.code == "seed_lock_not_released"


def test_orphan_cleanup_release_check_does_not_mask_the_original_failure():
    """`finally` 里 raise 会接替正在传播的异常，但原异常必须留在 `__context__` 里。

    否则「DELETE 失败」会被「锁没还」盖掉，排查时看到的是**第二个**症状。
    """
    maint_holder = {}

    class _DeleteBoom(_InitMaint):
        async def execute(self, query, *args):
            if query.strip().upper().startswith("DELETE"):
                raise RuntimeError("deadlock detected")
            return await super().execute(query, *args)

    maint = _DeleteBoom(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    maint_holder["m"] = maint

    async def _grant(seed):
        maint.held_seeds.add(seed)
        return True

    async def _noop_release(_seed):
        return None                    # 既没还锁，DELETE 又炸了

    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, lock_pair=(_grant, _noop_release)))
    assert ei.value.code == "seed_lock_not_released"
    assert isinstance(ei.value.__context__, RuntimeError), \
        f"原始的 DELETE 异常没留在 __context__ 里：{ei.value.__context__!r}"


def test_orphan_cleanup_releases_every_seed_lock_it_takes():
    """**取了就必须还**：会话级锁不还会一直挂在维护连接上，挡住后续同 seed 的运行；
    同一条连接上后来的 `_SEED_LOCK_HELD_SQL` 也会观察到一把**本次从未刻意取过**的锁。"""
    taken, freed = [], []
    maint = _InitMaint(all_intent_rows=[
        _orphan(dbname="kline_pilot_gone", seed="gone"),
        _orphan(dbname="kline_pilot_stale", seed="stale",
                age_seconds=INTENT_TTL_SECONDS + 1)])
    asyncio.run(_init(maint, lock_pair=_locker(maint, record=taken, released=freed)))
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
        asyncio.run(_init(maint, lock_pair=_locker(maint, released=freed)))
    assert freed == ["gone"], "删除失败时锁没还"


def test_orphan_cleanup_does_not_release_a_lock_it_never_took():
    """取不到锁的那一行**不许调 release** —— 那会把别人正持有的锁还掉。"""
    freed = []
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_running",
                                                seed="running")])
    asyncio.run(_init(maint, lock_pair=_locker(maint, grants=False, released=freed)))
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
    assert "statement_timestamp() - inserted_at" in sql, "超期判据没有下沉进 DELETE"
    assert "pg_database" in sql and "d.oid" in sql, "「库不存在」判据没有下沉、或没绑实例"
    # ⚠️ **必须绑 seed**（codex S3-R2）：授权来自「持有这一行 seed 的锁」，
    #    语句就得按那一行删。dbname↔seed 的对应只有代码在维持，没有 DB 约束在兜。
    assert "seed = $2" in sql, "DELETE 没绑 seed —— 拿着 A 的锁能删掉 B 的凭据"
    assert (sql.count("$1") == 1 and sql.count("$2") == 1
            and sql.count("$3") == 1), "参数应为 dbname + seed + TTL 三个"


def test_init_orphan_freshness_uses_the_database_clock():
    """孤儿清理的新鲜度只认库时钟（spec O4-R23-C1），不认调用方传的 created_at。

    `created_at` 是**调用方传进来的**字符串，数据库既不生成也不校验它：
    写一个很远的过去值，一行**活着的** intent 立刻可被别人接管。
    """
    import qmt_pilot_db as m
    sql = m._LIST_ALL_INTENT_SQL
    assert "statement_timestamp() - inserted_at" in sql, "新鲜度没有用库时钟算"
    assert "created_at" not in sql
    # ⚠️ 年龄不许在 SQL 里取整：`::bigint` 是四舍五入不是截断
    #    （真 PG 15 实测 `(-0.1)::bigint = 0`），`_READ_INTENT_SQL` 已经去掉了它。
    assert "::bigint" not in sql, "年龄被取整了 —— 与 _READ_INTENT_SQL 的口径漂移"


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
    assert "statement_timestamp() - inserted_at" in sql and "pg_database" in sql, \
        "两条判据没有下沉进 DELETE"
    src = textwrap.dedent(inspect.getsource(m.init_cluster_marker))
    tree = ast.parse(src)
    consts = [n.value for n in ast.walk(tree)
              if isinstance(n, ast.Constant) and isinstance(n.value, str)
              and "DELETE" in n.value.upper()]
    assert not consts, f"init 里有内联 DELETE 字面量：{consts}"
```

- [ ] **Step 1b: 把新 SQL 接进既有的**族级**时钟守卫，并让族成员**不再靠手写名单**

⚠️ **这一步是 codex S3-R1 那条 high 的根因层修复，不是附带清理。**

仓里已经有一条族级守卫 `test_intent_ttl_is_never_measured_against_the_transaction_clock`（`backend/tests/test_qmt_pilot_db.py:4570` 附近），它遍历的是一份**手写名单**：

```python
    for name in ("_READ_INTENT_SQL", "_INSERT_INTENT_SQL"):
```

S3 新增的 `_LIST_ALL_INTENT_SQL` / `_DELETE_ORPHAN_INTENT_SQL` 是**同一族的第三、第四个成员**，而手写名单**不会自动收录它们** —— 守卫看起来在工作、对新成员却零覆盖。这正是 `feedback_fix_the_whole_predicate_family_not_the_reported_site` 记的那个形态（同一 PR 重演过 7 次），也正是「机械检查器被它该抓的损坏禁用了自身解析器 → 静默全绿」的近亲。

改成**从模块推导**族成员，并保留手写名单做**双向**核对：

```python
def test_intent_ttl_is_never_measured_against_the_transaction_clock():
    """**族级**：凡是拿时钟减 `inserted_at` 判 TTL 的地方，都不许用 `now()`
    （codex S2a-R4-F2，真 PG 15 实测；S3-R1 把族扩到四个成员）。

    ...（既有 docstring 保留，补一句）...

    ⚠️ **族成员由模块推导，不靠手写名单**（S3-R1 的根因层修复）：手写名单在新增
       第三、第四条 SQL 时不会自动收录它们 —— 守卫看起来在工作、对新成员却零覆盖。
       `_EXPECTED` 只作**双向**核对：模块里冒出新成员而名单没跟上 → 红；
       名单写了模块里没有的名字（改名/删除）→ 也红。
    """
    import re
    import qmt_pilot_db as m
    pat = re.compile(r"EXTRACT\(EPOCH FROM \(\s*([A-Za-z_]+\(\))\s*-")
    # 「量 inserted_at 年龄」的族 = 模块级 *_SQL 常量里，既提到 inserted_at
    #   又含一处「时钟() −」的那些。`_MAINTENANCE_SHAPE_SQL` 只提列名、不量年龄，
    #   故不在族里（已实测确认它被正确排除）。
    derived = {n for n in dir(m)
               if n.endswith("_SQL") and isinstance(getattr(m, n), str)
               and "inserted_at" in getattr(m, n) and pat.search(getattr(m, n))}
    _EXPECTED = {"_READ_INTENT_SQL", "_INSERT_INTENT_SQL",
                 "_LIST_ALL_INTENT_SQL", "_DELETE_ORPHAN_INTENT_SQL"}
    assert derived == _EXPECTED, (
        f"「量 inserted_at 年龄」的 SQL 族变了：模块里多出 {sorted(derived - _EXPECTED)}，"
        f"名单里多出 {sorted(_EXPECTED - derived)} —— 新成员必须显式进这份名单，"
        f"否则它的时钟源无人把关")
    for name in sorted(derived):
        sql = getattr(m, name)
        clocks = pat.findall(sql)
        # 反向自检：扫不到任何时钟表达式 = 匹配式过时了，下面那条会恒真
        assert clocks, f"{name} 里一处「时钟 − inserted_at」都没扫到 —— 这颗钉子是空的"
        for clock in clocks:
            assert clock == "statement_timestamp()", (
                f"{name} 用 {clock} 判 TTL —— `now()` 是**事务开始时刻**，"
                f"长事务里一行已过期的销毁凭据会被判成新鲜")
```

**推导式已在 `8578a59` 上实跑验证**（2026-08-14）：当前只捞到 `_INSERT_INTENT_SQL` / `_READ_INTENT_SQL` 两个，`_MAINTENANCE_SHAPE_SQL`（提到 `inserted_at` 但不量年龄）被正确排除。故这份守卫在**改名单之前**是绿的、在**加上两个新名字之后**立刻变红（模块里还没有它们）—— 符合「守卫必须在功能还没写的当前树上就是绿的」那条守则的次序要求：**先实现 SQL，再改名单**，或两者同一步提交。

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
# ⚠️ **时钟源必须是 `statement_timestamp()`，不是 `now()`**（codex S2a-R4-F2 立的族规，
#    真 PG 15 实测；S3-R1 指出本函数漏了它）：`now()` 是**事务开始时刻**。
#    `init_cluster_marker` 收的是一条**已经连好的**连接、不控制事务生命周期，
#    4c 的 wrapper 很可能把整段维护操作包进事务 —— 那时 `now()` 冻在过去，
#    一行**真实已过期**的孤儿会被量成「还新鲜」→ 预筛跳过 → 残骸永远清不掉。
#    与 `_READ_INTENT_SQL` / `_INSERT_INTENT_SQL` 用**同一个**时钟源，不留漂移。
# ⚠️ **不加 `::bigint`**：`::bigint` 是四舍五入不是截断（真 PG 15 实测
#    `(-0.1)::bigint = 0`）。`_READ_INTENT_SQL` 已经把这个转换去掉了，这里跟同一口径。
_LIST_ALL_INTENT_SQL = """
SELECT dbname, seed, db_oid::text AS db_oid,
       EXTRACT(EPOCH FROM (statement_timestamp() - inserted_at)) AS age_seconds
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
# ⚠️ 时钟源同上：`statement_timestamp()`。这条尤其要紧 —— 它是**权威判据**
#    （预筛只是省取锁）。长事务里用 `now()` 的话，取到锁之后这条 DELETE 会匹配 0 行，
#    于是「命令发了、一行没删」的静默失败，正是 R9 那次回归的形态。
# ⚠️ **必须同时绑 `seed`（codex S3-R2）**：这条 DELETE 的授权来自「本次持有的是
#    **这一行 seed** 的 advisory lock」。只按 dbname 删的话，语句本身与它的授权
#    对不上号 —— 它靠的是「dbname 恒为 `kline_pilot_<seed>`、seed 是它的函数」
#    这条**跨列不变量**，而那条不变量**没有任何数据库约束在兜**
#    （`pilot_create_intent` 既无 `CHECK (dbname = 'kline_pilot_' || seed)`、
#     `dbname` 也不是生成列）。孤儿清理处理的恰恰是**来路不明的行**：旧版本写的、
#    `pg_restore` 还原的、人工插的 —— 对它们那条不变量不成立。
#    绑上 seed 之后，失配时**删 0 行**（fail-closed），而不是拿着 A 的锁删 B 的凭据。
#    ⛔ **不在本片给 .sql 加 CHECK 约束**：那会改动被钉死的
#       `CANONICAL_CLUSTER_SCHEMA_SHA256` 与闸 (i) 的形状判据，远超 S3 范围。
_DELETE_ORPHAN_INTENT_SQL = """
DELETE FROM public.pilot_create_intent
 WHERE dbname = $1
   AND seed = $2
   AND (EXTRACT(EPOCH FROM (statement_timestamp() - inserted_at)) >= $3
        OR NOT EXISTS (SELECT 1 FROM pg_database d
                        WHERE d.datname::text = public.pilot_create_intent.dbname
                          AND d.oid = public.pilot_create_intent.db_oid))
"""
```

⚠️ **插入位置是本 Task 最容易做错的一步，先读完这一段再动手（codex S3-R5）。**

Task 3 结束时函数末尾长这样：

```python
    if rows:
        await assert_cluster_allowed(maint_conn, connect=connect, target_db=None)
    else:
        await _assert_disposable_cluster(maint_conn, connect=connect,
                                         registry_usable=_registry_usable)
        await maint_conn.execute(_WRITE_MARKER_SQL, MARKER_PURPOSE)   # ← 当时是最后一句
```

**清理循环不能追加在这之后。** 清理循环**会抛**（DELETE 失败、`seed_lock_not_released`），
一旦排在写标记之后，首次初始化就又回到 R4 那个洞：**报告失败、却留下一个合法标记**，
而契约是「本工具从不清标记」。R4 我只把标记挪到了「那一支的最后」，没考虑到 Task 4 随后
会在**整个函数的最后**再接一段会抛的代码 —— 典型的「修 symptom 会挪动失败面」。

**正确形态**（改完之后函数的结尾）：

```python
    if rows:
        await assert_cluster_allowed(maint_conn, connect=connect, target_db=None)
    else:
        # 这一次证明的是「可以动这台集群的 intent 行」——授权下面的清理。
        await _assert_disposable_cluster(maint_conn, connect=connect,
                                         registry_usable=_registry_usable)

    # 5. 孤儿 intent 行清理（下面那一大段）。**它会抛**，故必须排在写标记之前。
    ...清理循环...

    # 6. 首次初始化：**紧贴着**再证一次，然后写标记。
    if not rows:
        # ⚠️ **「紧贴」是 spec 立过的纪律**（§4：「DROP 前须**紧贴着**重查一次【绝对空】」）：
        #    上面那次证明与这里之间隔着整个清理循环 —— 取锁、DELETE、释放，
        #    每一步都要时间，窗口里集群可以变脏。信任写入必须由**紧挨着它**的证明背书。
        await _assert_disposable_cluster(maint_conn, connect=connect,
                                         registry_usable=_registry_usable)
        # ⚠️ **本函数的最后一句，之后不许再有任何会抛的语句。**
        #    它是唯一不可回滚的信任写入（契约：本工具从不清标记）。
        await maint_conn.execute(_WRITE_MARKER_SQL, MARKER_PURPOSE)
```

**为什么这样就到头了**：写标记成了函数的**字面最后一句**，它之后不存在任何代码，
「副作用次序」这条原则在本函数内**再没有新的落点**可以移动。

具体做法：把 Task 3 末尾 `else:` 分支里的 `_WRITE_MARKER_SQL` 那一句**剪切**出来，
按上面的形态重新组织；然后在两者之间插入下面的清理循环。

```python
    # 5. 孤儿 intent 行清理：超期 OR 库不存在，且取得到那一行 seed 的锁。
    # ⚠️ **预筛也必须绑实例**：只按名字判「库还在不在」时，
    #    「原实例被删掉、别人用同名重建」这一档会被判成「没消失」→ 直接 continue →
    #    下面那条 OID-aware 的 DELETE **永远跑不到**，一条指向已消失实例的陈旧行
    #    就一直赖着，把后续的建库/reset 卡到 TTL 为止。
    #    预筛只是省掉不必要的取锁；真正的判据在锁内的 SQL 里，两者的口径必须一致。
    live = {(r["datname"], r["db_oid"]) for r in await maint_conn.fetch(_LIST_DATABASES_SQL)}
    for r in await maint_conn.fetch(_LIST_ALL_INTENT_SQL):
        # ⚠️ **不取整**（codex S2a-R3-F1 立的族规）：`int()` 与 `::bigint` 都会把
        #    符号抹掉（`int(-0.1) == 0`），而 `_READ_INTENT_SQL` 那侧已经两层都去掉了。
        #    这里是预筛，取整不致命，但口径必须与锁内那条 DELETE 一致。
        stale = float(r["age_seconds"]) >= INTENT_TTL_SECONDS
        vanished = (r["dbname"], r["db_oid"]) not in live
        if not (stale or vanished):
            continue
        # ⚠️ **取锁之前先证明本连接还没持有它**（codex S3-R2，真 PG 15.12 实测坐实）：
        #    advisory lock 在同一 session 内**可重入** —— 实测 `pg_try_advisory_lock`
        #    对一把本连接已持有的锁**照样返回 true**（计数器 1→2），而
        #    `_SEED_LOCK_HELD_SQL` 在调用之前**就已经是 true**。于是下面那道复核
        #    证明不了任何**新**的互斥，等于对这一行没有锁。
        #    危险的是**自己**这一档：本连接正在为该 seed 干别的事（4c 的 wrapper 把
        #    init 套进一次 create/reset、或连接池里漏回来一把锁），而这里把它
        #    **进行中的**恢复凭据删掉 —— 正是「不加锁会删掉一次正在进行的运行的行」
        #    那条要防的后果，只是换成了同连接的形态。
        #    （对**别的 session** 的互斥仍然成立：我们持有时别人取不到。）
        #    判据 fail-closed：已持有 → 跳过，不删、也不 release（那是别处的锁）。
        if await maint_conn.fetchval(_SEED_LOCK_HELD_SQL, r["seed"]):
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
                                     r["seed"], INTENT_TTL_SECONDS)
        finally:
            # ⚠️ **取了就必须还**：会话级锁不还会一直挂在维护连接上，挡住后续同 seed
            #    的运行；同一条连接上后来的 `_SEED_LOCK_HELD_SQL` 也会观察到一把
            #    **本次操作从未刻意取过**的锁。
            await release_seed_lock(r["seed"])
            # ⚠️ **还了也要验**（codex S3-R4）—— 与「取到了也要验」是同一条纪律，
            #    上一版只验了取、没验还。`release_seed_lock` 和 `try_seed_lock` 一样是
            #    **调用方递进来的回调**：空实现、连错连接、只释放一层可重入计数，
            #    都会「成功返回」而锁**仍挂在 `maint_conn` 上**。
            #    这条泄漏尤其毒，因为上面那条「事前已持有就跳过」的 fail-closed 判据
            #    会把它放大成**这条连接从此再也清不掉该 seed 的孤儿**（静默跳过，
            #    而且理由看起来完全合理）。
            # ⚠️ 只对**本次确实取到**的那把锁作此要求：走到这里就说明
            #    「事前未持有 + 回调授予 + 活连接复核为真」三条都成立过。
            if await maint_conn.fetchval(_SEED_LOCK_HELD_SQL, r["seed"]):
                raise PilotClusterBoundaryError(
                    "seed_lock_not_released",
                    f"孤儿清理为 seed={r['seed']!r} 取了 advisory lock，"
                    f"调用方的 release 回调返回了，但这把锁**仍挂在维护连接上**。"
                    f"它是会话级的：不还会挡住后续同 seed 的建库/reset，"
                    f"也会让本函数以后把该 seed 的孤儿静默跳过。"
                    f"请检查 release_seed_lock 的接线（是否空实现／是否作用在另一条连接／"
                    f"是否只释放了一层可重入计数），或重开维护连接。")
            # ⚠️ 在 `finally` 里 raise 会**接替**正在传播的异常，但原异常仍保留在
            #    `__context__` 里（Python 语义），信息不丢。
            # ⛔ **不在这里关闭/毒化 `maint_conn`**（codex 建议过）：连接是调用方的，
            #    本模块通篇不拥有它、也从不关它；关掉会让调用方拿到一个它没预料到的
            #    死连接，且掩盖真正的接线错误。抛一个点名的 code 更诚实。
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
| M21 | `_LIST_ALL_INTENT_SQL` 把 `statement_timestamp() - inserted_at` 换成 `statement_timestamp() - created_at::timestamptz` | `test_init_orphan_freshness_uses_the_database_clock` |
| **M21b** | `_LIST_ALL_INTENT_SQL` 的 `statement_timestamp()` 换回 `now()` | `test_intent_ttl_is_never_measured_against_the_transaction_clock`（**具名到 `_LIST_ALL_INTENT_SQL`**）+ `test_init_orphan_freshness_uses_the_database_clock` |
| **M21c** | `_DELETE_ORPHAN_INTENT_SQL` 的 `statement_timestamp()` 换回 `now()` | 同上，具名到 `_DELETE_ORPHAN_INTENT_SQL`；另 `test_orphan_cleanup_uses_a_delete_that_can_actually_match_an_orphan` |
| **M21d** | 把族守卫的 `derived` 换回手写 `("_READ_INTENT_SQL", "_INSERT_INTENT_SQL")`，同时把 `_LIST_ALL_INTENT_SQL` 改成 `now()` | **必须仍有测试变红**。若全绿 = 推导式失效，守卫回到「新成员零覆盖」状态 —— 这一条验的是守卫**自己**的判别力 |
| **M21e** | `_LIST_ALL_INTENT_SQL` 的 age 加回 `::bigint` | `test_init_orphan_freshness_uses_the_database_clock`（`::bigint` 那条断言） |
| **M29** | `_DELETE_ORPHAN_INTENT_SQL` 去掉 `AND seed = $2`（参数退回两个，调用处同步改） | `test_orphan_cleanup_binds_the_delete_to_the_row_it_locked` + `test_orphan_cleanup_uses_a_delete_that_can_actually_match_an_orphan` |
| **M30** | 删掉取锁前那条 `if await maint_conn.fetchval(_SEED_LOCK_HELD_SQL, ...): continue` | `test_orphan_cleanup_skips_a_seed_whose_lock_this_connection_already_holds` |
| **M31** | 把 `_InitMaint.fetchval` 的 `"pg_locks"` 分支改回返回**静态** `self.seed_lock_held` | **必须仍有测试变红**。若全绿 = 锁状态没建模成迁移，取锁前/后两条判据里有一条恒真——这一条验的是**假件自己**的判别力 |
| **M32** | `_LIFECYCLE_DBS` 去掉 `kline_pilot_lifecycle_r37` 一行，然后**在 ㊲ 建库之后 kill 脚本**，再跑一次 | 第二次运行必须 `return 4` 并点名 `kline_pilot_lifecycle_r37`。这条验的是「漏登记会锁死后续运行」这一后果真的存在（跑完用 `QMT_VERIFY_FORCE_CLEANUP=1` 收拾） |
| **M33** | 把首次初始化那支改回「先 `_WRITE_MARKER_SQL` 再 `_assert_disposable_cluster`」 | `test_init_does_not_leave_a_marker_when_the_final_gate_rejects` |
| **M34** | 删掉写标记前那次 `await _assert_disposable_cluster(...)`（只留预检那次） | 同上（`db_scans >= 2` 那条前置断言先红 —— 它专防这条用例空转） |
| **M35** | 删掉 `finally` 里 release 之后那条 `_SEED_LOCK_HELD_SQL` 复核 | `test_orphan_cleanup_verifies_the_release_actually_took_effect` + `..._does_not_mask_the_original_failure` |
| **M36** | 把 `_assert_disposable_cluster` 里的 `_user_objects` 检查删掉（只留同侪库那半） | `test_init_refuses_to_declare_a_cluster_whose_maintenance_db_is_not_empty` |
| **M37** | 把 `_WRITE_MARKER_SQL` 那句挪回清理循环**之前**（即 Task 3 的原位置） | `test_first_init_writes_no_marker_when_orphan_cleanup_fails` + `test_first_init_proves_the_cluster_again_immediately_before_the_marker`（`delete_at < marker_at` 那条） |
| **M38** | 删掉写标记前那次「紧贴」`_assert_disposable_cluster` | `test_first_init_proves_the_cluster_again_immediately_before_the_marker`（`datistemplate in ops[delete_at+1:marker_at]` 那条） |
| **M39** | `_assert_disposable_cluster` 的 `if registry_usable:` 整段删掉（退回一律严判据） | `test_repair_accepts_a_registered_nonempty_pilot_peer` |
| **M40** | 把 `registry_usable` 的两个事实改成只判 `_looks_like_our_pilot_db`（去掉 `_REGISTRY_HAS_SQL`） | `test_repair_still_rejects_an_unregistered_nonempty_peer` + `test_both_peer_proofs_use_the_same_two_facts` |
| **M41** | 调用处把 `registry_usable=_registry_usable` 改成恒 `True` | `test_no_legal_marker_never_gets_the_registry_relaxation`（三档全红） |
| **M43** | `_registry_usable` 去掉 `bool(rows) and`（退回只看 `registry_present`） | `test_no_legal_marker_never_gets_the_registry_relaxation[presence_over1-…]` 与 `[presence_over2-…]`（**具名到「标记缺失但登记表在场」那两档**；第一档 presence 全假，对这条判据零判别力，别拿它当证据） |
| **M42** | 调用处改成在 DDL **之后**重查在场情况再传（而不是用 DDL 前的 `presence`） | `test_no_legal_marker_never_gets_the_registry_relaxation`（补建出的空登记表会让首次初始化误走宽判据） |
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
| **㊲** | **新增（codex S3-R1）**：**长事务**里孤儿清理仍按语句时刻量 —— 一行真实已过期的孤儿仍被删掉 | `test_intent_ttl_is_never_measured_against_the_transaction_clock` |
| **㊳** | **新增（codex S3-R6/R7）**，**三向**：①混合态 + **已登记的非空** pilot 库 → 修复成功；②同场景 + **未登记**的非空同前缀库 → 拒；③**标记被清掉**但登记表仍在 + 非空同前缀库 → 拒**且不写标记** | `test_repair_accepts_a_registered_nonempty_pilot_peer` / `..._still_rejects_an_unregistered_nonempty_peer` / `test_no_legal_marker_never_gets_the_registry_relaxation` |

> **㊳ 为什么要上真 PG**：这是本片唯一一处**放宽**判据的改动（原本一律要求同前缀库【绝对空】）。放宽必须由真库证明它没有**过度**放宽 —— host 假件的 `registered_dbnames` 是一个布尔/集合，`_REGISTRY_HAS_SQL` 那句 `JOIN pg_database d ON d.oid = r.db_oid` 的**绑实例**语义在假件上完全不求值。同一档里必须同时跑「已登记 → 放行」与「未登记 → 拒」两向。

> **㊲ 为什么非有不可**：既有的 ㉝c 有一句自己写下的警告 ——「㉝ / ㉝b 都在**自动提交**下跑，`now()` 与 `statement_timestamp()` 几乎相等，**时钟源这一条在它们身上一次都没求值**」。⑤ ⑤b ㉙ ㉚ ㊱ 全是自动提交，同样对时钟源零判别力。不补 ㊲ 的话，S3 关于时钟源的证据就只剩 host 层的文本断言（那只证明「SQL 里写着这几个字」，不证明「长事务里真的量对了」）。

- [ ] **Step 0: 把三个新库名加进 `_LIFECYCLE_DBS`（codex S3-R2，漏了会锁死后续每一次运行）**

⚠️ **这一步排在最前，漏掉的后果是「下一次运行整个起不来」，不是「少测一档」。**

`backend/scripts/verify_pilot_db_lifecycle.py:119` 的 `_LIFECYCLE_DBS` 是**精确白名单**。按字母序插入三行：

```python
    "kline_pilot_lifecycle_r28",
    "kline_pilot_lifecycle_r30",          # ㉚（只写 intent 行，不建库）
    "kline_pilot_lifecycle_r31",
    ...
    "kline_pilot_lifecycle_r35b",
    "kline_pilot_lifecycle_r36",          # ㊱
    "kline_pilot_lifecycle_r37",          # ㊲
    "kline_pilot_lifecycle_r38",          # ㊳（已登记的非空 pilot 库）
    "kline_pilot_lifecycle_r38stranger",  # ㊳（未登记的非空同前缀库）
    "kline_pilot_lifecycle_s15",
```

**为什么这三个都要加**（两条后果，第二条 codex 没说到，是我核出来的）：

1. **同前缀 stranger 闸会顶死整个脚本**：`sweep_leftover_databases`（`_pilot_verify_harness.py:252`）把「匹配前缀但不在白名单」的库判成 `strangers` → **`return 4`，拒绝运行**。㊱/㊲ 都真的 `CREATE DATABASE`，崩在 CREATE 与 DROP 之间就会留下这样一个库。
2. **凭据行清不掉**：`purge_metadata_for(conn, _LIFECYCLE_DBS)`（同文件 `:301`）**只删点名库名**的 intent/registry 行。㉚ ㊱ ㊲ **三档都 INSERT 了 intent 行** —— 不在白名单里的话，崩溃残留的凭据行连前置清场都清不掉，会去污染后续档位。㉚ 虽然从不建库，但它写 intent 行，**同样必须登记**。

⚠️ **源码扫描器拦不住这个漏**（已实测）：`assert_every_selfcheck_db_is_whitelisted`（`:160`）走 **AST 字符串字面量** + `startswith("kline_pilot_lifecycle_")`。而本脚本一贯的写法是 `seed37 = "lifecycle_r37"` + `f"kline_pilot_{seed37}"` —— 那个字面量**不以前缀开头**，扫描器看不见它。既有的 30 个场景全是这个形状，全靠**人工登记**。

⛔ **不在 S3 修这个扫描器盲区**（codex 建议过「扩展 harness 让 f-string 名字无法绕过」）：那要改 harness 的公共扫描逻辑并回头核对既有 30 个场景，是独立的一片工作。**如实登记为已知残留**，写进本片的验收清单。

- [ ] **Step 1: 改 import 与 `_EXPECTED_SCENARIOS`**

`backend/scripts/verify_pilot_db_lifecycle.py` L66-74 的 import 加两个符号：

```python
from qmt_pilot_db import (INTENT_TTL_SECONDS, MARKER_PURPOSE,  # noqa: E402
                          PILOT_META_KEYS, PilotClusterBoundaryError,
                          PilotDbBoundaryError, _LIST_ALL_INTENT_SQL,
                          _READ_INTENT_SQL, _SEED_LOCK_HELD_SQL,
                          _TARGET_CLIENT_SESSIONS_SQL, assert_cluster_allowed,
                          assert_db_allowed_for_reset,
                          assert_db_allowed_for_reuse,
                          create_pilot_database, init_cluster_marker,
                          quote_ident,
                          reset_pilot_database, sha256_of_sql,
                          try_empty_remnant_exception)
```

`_EXPECTED_SCENARIOS` 改成 48 档（新增 ⑤ ⑤b ㉙ ㉚ ㊱ ㊲ ㊳，其余顺序不动）：

```python
_EXPECTED_SCENARIOS = ("①", "②", "③", "④", "⑤", "⑤b", "⑥", "⑦", "⑧", "⑨", "⑨b",
                       "⑨c", "⑩", "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑰b", "⑱",
                       "⑲", "⑳", "⑳b", "㉑", "㉒", "㉓", "㉔", "㉕", "㉖", "㉗", "㉙",
                       "㉚", "㊱", "㊲", "㊳", "㉛",
                       "㉝", "㉝b", "㉝c", "㉘", "㉜", "㉜b", "㉞", "㉞b", "㉟", "㉟b")
```

**S3 完成后 = 48 档**（基线 41 + ⑤ ⑤b ㉙ ㉚ ㊱ ㊲ ㊳）。

- [ ] **Step 2: 跑脚本确认变红**

```bash
docker start qmt-pg-r8 qmt-pg-r8b
QMT_VERIFY_ALLOW_DESTRUCTIVE=1 "$PY" backend/scripts/verify_pilot_db_lifecycle.py 2>&1 | grep -E "档断言全部成立|FAIL|❌|未运行|缺"
```
预期：脚本报**声明了 48 档但只跑了 41 档**（`_EXPECTED_SCENARIOS` 与 `ran` 集合的差集非空）。这是本 Task 的「红」——先让缺档机制自己叫出来，再去补场景。

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

- [ ] **Step 5a: 写 ㊲ —— 长事务里的时钟源（codex S3-R1）**

⚠️ 本档的形态直接照 ㉝c 那一档（它已在 main 上跑绿），只是把被测对象从 `try_empty_remnant_exception` 换成 `init_cluster_marker` 的孤儿清理路径。

⚠️ **必须把「超期」这一半单独隔离出来**：孤儿判据是「超期 **OR** 库不存在」。若这一档里的库不存在，`vanished` 会独自把行删掉，**时钟源那一条一次都不会求值** —— 这一档就成了空转。故本档**必须建出那个库并把 `db_oid` 绑上去**，让 `vanished` 为假、只剩 `stale` 说话。

```python
    # ── ㊲ 长事务里 TTL 仍按语句时刻量（codex S3-R1；与 ㉝c 同族）──────────
    #    `now()` 是**事务开始时刻**。`init_cluster_marker` 收的是一条**已经连好的**
    #    连接、不控制事务生命周期，4c 的 wrapper 很可能把整段维护操作包进事务 ——
    #    那时 `now()` 冻在过去，一行**真实已过期**的孤儿被量成「还新鲜」→
    #    预筛跳过 → 残骸永远清不掉。
    #    ⚠️ ⑤ ⑤b ㉙ ㉚ ㊱ 全在**自动提交**下跑，`now()` 与 `statement_timestamp()`
    #       几乎相等 —— 时钟源这一条在它们身上**一次都没求值**（㉝c 那一档写下的教训）。
    #    ⚠️ 本档刻意把库**建出来并绑 oid**：孤儿判据是「超期 OR 库不存在」，
    #       库若不存在，`vanished` 会独自把行删掉，时钟源根本不被求值 → 空转。
    scenario("㊲")
    print("㊲ 长事务里孤儿清理仍按语句时刻量（`now()` 会冻在事务开始那一刻）")
    seed37 = "lifecycle_r37"
    db37 = f"kline_pilot_{seed37}"
    conn = await _connect(base_dsn)
    try:
        # `CREATE DATABASE` 不能在事务块里 —— 必须排在 BEGIN 之前。
        await harness.drop_database(base_dsn, db37)
        await conn.execute("CREATE DATABASE " + quote_ident(db37))
        await conn.execute("DELETE FROM public.pilot_create_intent")
        await conn.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db37, seed37, _CREATED_AT, f"lifecycle-{seed37}")
        # 前置①：那个库**确实存在且 oid 对得上** → `vanished` 为假，只剩 `stale` 说话。
        bound = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent i"
            " JOIN pg_database d ON d.datname::text = i.dbname AND d.oid = i.db_oid"
            " WHERE i.dbname = $1", db37)
        check(bound == 1,
              "㊲ 前置：孤儿行绑在一个**存在的**实例上（隔离掉「库不存在」那一半）",
              f"JOIN 命中 {bound} 行 —— 没隔离住，这一档会被 vanished 带过去")

        await conn.execute("BEGIN")
        try:
            await conn.fetchval("SELECT pg_sleep(1.2)")
            # 前置②：事务里的 `now()` 确实落后语句时刻 —— 否则这一档测不到时钟源。
            drift = float(await conn.fetchval(
                "SELECT EXTRACT(EPOCH FROM (statement_timestamp() - now()))"))
            check(drift >= 1.0,
                  "㊲ 前置：事务里的 `now()` 确实落后语句时刻 ≥1s",
                  f"实得 drift={drift:.3f}s —— 事务没变老，这一档测不到时钟源")
            # 造一行**真实已过期 0.1 秒**的孤儿：按真实时钟（clock_timestamp）回推。
            # 用 `now()` 量的话它是 TTL−1.1s → 判成新鲜 → 不删。
            await conn.execute(
                "UPDATE public.pilot_create_intent"
                "   SET inserted_at = clock_timestamp() - make_interval(secs => $2)"
                " WHERE dbname = $1", db37, float(INTENT_TTL_SECONDS) + 0.1)
            # 前置③：**模块自己那条 SQL** 在长事务里把它量成已过期。
            rows37 = await conn.fetch(_LIST_ALL_INTENT_SQL)
            age37 = next((float(r["age_seconds"]) for r in rows37
                          if r["dbname"] == db37), None)
            check(age37 is not None and age37 >= INTENT_TTL_SECONDS,
                  "㊲ **模块的 `_LIST_ALL_INTENT_SQL`** 在长事务里仍把它量成已过期",
                  f"实得 age_seconds={age37!r}，TTL={INTENT_TTL_SECONDS}"
                  f"（小于 TTL = 用了 `now()`，预筛会直接跳过这一行）")

            took37: list[str] = []

            async def _try37(seed_of_row):
                took37.append(seed_of_row)
                return bool(await conn.fetchval(
                    "SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))",
                    seed_of_row))

            async def _rel37(seed_of_row):
                await conn.execute(
                    "SELECT pg_advisory_unlock(hashtext('kline_pilot_' || $1))",
                    seed_of_row)

            cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(
                encoding="utf-8")
            try:
                await init_cluster_marker(conn, connect=connect_peer,
                                          cluster_schema_sql=cluster_sql,
                                          try_seed_lock=_try37,
                                          release_seed_lock=_rel37)
            except Exception as exc:
                check(False, "㊲ init 本身必须跑完", f"抛了：{type(exc).__name__}: {exc}")
            check(took37 == [seed37],
                  "㊲ 前置：预筛把这一行判成了孤儿并去取锁（用 `now()` 时这里是空的）",
                  f"try_seed_lock 收到的 seed 列表 = {took37}")
            # 判据看**数据库状态**：真实已过期的孤儿必须真的不在了。
            left37 = await conn.fetchval(
                "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db37)
            check(left37 == 0,
                  "㊲ 长事务里那行真实已过期的孤儿**确实被删掉了**",
                  f"事后仍有 {left37} 条 —— 锁内那条 DELETE 用了 `now()`，匹配 0 行")
        finally:
            await conn.execute("ROLLBACK")
        await conn.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db37)
    finally:
        await conn.close()
    await harness.drop_database(base_dsn, db37)
```

> ⚠️ **实施时必须现场确认的一点**：`ROLLBACK` 会把事务里那次 DELETE 一起回滚，故 `left37 == 0` 的断言**必须在 ROLLBACK 之前**求值（上面的写法已经是这样）。若实施时发现 `init_cluster_marker` 在显式事务里因别的原因跑不完（例如某条守卫查询要求自动提交），**不要**把这一档改成自动提交来「修绿」—— 那会让它退化成又一个对时钟源零判别力的档；正确做法是停下来报告，由控制者判断。

- [ ] **Step 5c: 写 ㊳ —— 混合态修复认同侪库的归属登记（codex S3-R6）**

⚠️ 本档必须**双向**：同一个混合态下，「已登记的非空库 → 放行修复」与「未登记的非空库 → 拒」都要跑到。只测放行那一半，等于证明了「放宽生效」却没证明「没有过度放宽」。

```python
    # ── ㊳ 混合态修复必须认同侪库的**外部归属登记**（codex S3-R6）────────────
    #    形态：marker + pilot_database_registry 在场且合规，只有 pilot_create_intent 缺失。
    #    此前所有「要动 DDL」的路径都走【绝对空】严判据 → 一个**已登记的、装着真数据的**
    #    合法 pilot 库被判成外来物 → 整台集群锁在修复路径之外，
    #    而 O4-F7 引入修复路径的全部理由就是「修好旧版本初始化的集群」。
    #    ⚠️ 这是本片唯一一处**放宽**判据的改动，故必须由真库同时证明两向。
    scenario("㊳")
    print("㊳ 混合态修复：已登记的非空 pilot 库放行、未登记的非空同前缀库仍拒")
    seed38 = "lifecycle_r38"
    db38 = f"kline_pilot_{seed38}"
    conn = await _connect(base_dsn)
    try:
        # 1) 造一个**真正由本工具建出来**的 pilot 库（带合法 pilot_meta + 登记行）
        await harness.drop_database(base_dsn, db38)
        await _apply_cluster_schema(conn)
        await _write_marker(conn)
        got38 = await conn.fetchval(
            "SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))", seed38)
        check(bool(got38), "㊳ 前置：取到 seed 锁")
        try:
            await create_pilot_database(conn, connect=connect_peer, seed=seed38,
                                        run_id=f"lifecycle-{seed38}", **_BUILD_ARGS)
        finally:
            await conn.execute(
                "SELECT pg_advisory_unlock(hashtext('kline_pilot_' || $1))", seed38)
        # 往里塞真数据 —— 它必须是**非空**的，否则会被【绝对空】那一档豁免带过去，
        # 归属登记这条判据一次都不会被求值（本仓栽过多次的空转形态）。
        await _in_db(base_dsn, db38,
                     "CREATE TABLE public.zzqmtverify_payload (id int)",
                     "INSERT INTO public.zzqmtverify_payload"
                     " SELECT generate_series(1, 500)")
        check(not await _is_db_absolutely_empty(base_dsn, db38),
              "㊳ 前置：那个已登记的 pilot 库确实**非空**（否则本档空转）")
        registered = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_database_registry WHERE dbname = $1", db38)
        check(registered == 1, "㊳ 前置：它确实在登记表里", f"登记了 {registered} 行")

        # 2) 造混合态：只把 pilot_create_intent 删掉（marker / registry 留着）
        await conn.execute("DROP TABLE IF EXISTS public.pilot_create_intent")
        check(not await conn.fetchval(
            "SELECT to_regclass('public.pilot_create_intent') IS NOT NULL"),
            "㊳ 前置：intent 表确实不在场（混合态成立）")

        async def _never38(_seed):
            return False

        async def _noop38(_seed):
            return None

        cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8")
        # 3) **放行那一向**：修复必须成功，且 intent 表被补建出来
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_never38, release_seed_lock=_noop38)
        except Exception as exc:
            check(False, "㊳ 已登记的非空 pilot 库不得挡住修复",
                  f"抛了：{type(exc).__name__}: {exc}")
        check(bool(await conn.fetchval(
            "SELECT to_regclass('public.pilot_create_intent') IS NOT NULL")),
            "㊳ 修复真的把 pilot_create_intent 补建出来了")

        # 4) **拒绝那一向**：同一个混合态下，**未登记**的非空同前缀库必须仍被拒
        stranger38 = f"{_PREFIX}r38stranger"
        await harness.drop_database(base_dsn, stranger38)
        await conn.execute("CREATE DATABASE " + quote_ident(stranger38))
        await _in_db(base_dsn, stranger38,
                     "CREATE TABLE public.zzqmtverify_payload (id int)",
                     "INSERT INTO public.zzqmtverify_payload SELECT generate_series(1, 10)")
        await conn.execute("DROP TABLE IF EXISTS public.pilot_create_intent")   # 再造混合态
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_never38, release_seed_lock=_noop38)
            check(False, "㊳ 未登记的非空同前缀库必须拒", "竟然成功了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "unowned_pilot_database",
                  "㊳ 未登记的非空同前缀库 → unowned_pilot_database", f"实得 {exc.code}")
        check(not await conn.fetchval(
            "SELECT to_regclass('public.pilot_create_intent') IS NOT NULL"),
            "㊳ 拒绝那一向是**零 DDL** 的（intent 表事后仍不存在）")
        await harness.drop_database(base_dsn, stranger38)

        # 5) **第三向（codex S3-R7）**：标记缺失、登记表在场 → 登记凭据**不可信**，
        #    非空同前缀库必须仍被拒，且**不得写下标记**。
        #    标记才是「这个维护库是我们的」的信任根；契约明写清除标记是**人工动作**，
        #    所以「人清过标记」是真实可达的状态。
        await _apply_cluster_schema(conn)
        await _clear_marker(conn)                              # 人工清标记
        check(not await conn.fetchval(
            "SELECT count(*) FROM public.pilot_cluster_marker"),
            "㊳ 前置：标记确实被清掉了")
        still_registered = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_database_registry WHERE dbname = $1", db38)
        check(still_registered == 1,
              "㊳ 前置：登记行仍在（这一档要测的就是「有登记、无标记」）",
              f"登记了 {still_registered} 行")
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_never38, release_seed_lock=_noop38)
            check(False, "㊳ 无标记时登记表不得当归属凭据用", "竟然成功了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "unowned_pilot_database",
                  "㊳ 标记缺失 + 登记在场 + 非空同前缀库 → unowned_pilot_database",
                  f"实得 {exc.code}：{exc}")
        check(not await conn.fetchval(
            "SELECT count(*) FROM public.pilot_cluster_marker"),
            "㊳ 拒绝之后**没有**写下标记（否则绕过了【绝对空】证明，"
            "还把人工清标记这个逃生阀废掉了）")
        await _write_marker(conn)                  # 复原供后续档位使用
    finally:
        await conn.close()
    await harness.drop_database(base_dsn, db38)
```

⚠️ **实施前置**：本档用到 `create_pilot_database` / `_BUILD_ARGS` / `_in_db`，脚本里都已存在；另需一个「某个库是不是【绝对空】」的小助手 `_is_db_absolutely_empty(base_dsn, dbname)` —— 若脚本里还没有，照 `_relation_exists` 的形状加一个（连进去调 `_is_absolutely_empty`）。`kline_pilot_lifecycle_r38` 与 `kline_pilot_lifecycle_r38stranger` **两个名字都要进 Step 0 的 `_LIFECYCLE_DBS`**。

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
    print("   孤儿 intent 清理的取锁/还锁（㉚）、锁内当下求值（㊱）、")
    print("   以及长事务下的 TTL 时钟源（㊲，与 ㉝c 同族）。")
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
预期：**48 档断言全部成立**，无 FAIL。

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
| M24 | `_DELETE_ORPHAN_INTENT_SQL` 把整段 `AND (EXTRACT(...) >= $2 OR NOT EXISTS(...))` 删光（只按 dbname 删） | **㊱**（被刷新的凭据被删掉，`still == 0`） |
| **M28** | `_DELETE_ORPHAN_INTENT_SQL` + `_LIST_ALL_INTENT_SQL` 的 `statement_timestamp()` 双双换回 `now()` | **㊲**（`took37 == []` 或 `left37 == 1`）—— 且 ⑤ ⑤b ㉙ ㉚ ㊱ **必须仍然全绿**，那正是「自动提交档对时钟源零判别力」的证据 |
| M25 | Task 2 的三条 `*_durable` 别名合回一条 `maintenance_tables_durable` | **⑤b**（`left` 非空 —— 补建 DDL 真的落地了） |
| M26 | 删掉清理循环的 `finally: await release_seed_lock(...)` | **㉚**（`_SEED_LOCK_HELD_SQL` 仍为真） |
| M27 | 删掉末尾的 `await assert_cluster_allowed(...)` | **㉙**（init 竟然成功了） |

每次跑完 `cp /tmp/s3_t5_backup.py backend/qmt_pilot_db.py` 复原。**绝不用 `git checkout`**。

- [ ] **Step 9: Commit**

```bash
git add backend/scripts/verify_pilot_db_lifecycle.py
git commit -m "S3 Task5：真 PG 验收补七档（⑤ ⑤b ㉙ ㉚ ㊱ ㊲ ㊳），lifecycle 41→48 档"
```

---

## 收口（Task 5 之后，宣称完成之前）

- [ ] **走 superpowers:verification-before-completion**：把下表逐条实测填满，**判绿读输出内容不读结论字样**。

| 闸门 | 基线 | S3 实测 |
|---|---|---|
| `"$PY" -m pytest backend/tests -q` | 770 passed | ___ passed |
| `verify_pilot_db_lifecycle.py` | 41 档 | 48 档 |
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
| 验收断言必须看**数据库状态** | ㉚ 的 `gone == 0`、㊱ 的 `still == 1`、㊲ 的 `left37 == 0`、⑤/⑤b 的 `to_regclass(...)` —— 全部查表，无一条只断言「发过 DELETE」 |
| TTL 时钟源必须是 `statement_timestamp()`（族规，codex S2a-R4-F2） | Task 4 的两条新 SQL + **Step 1b 把族守卫改成从模块推导**（不再手写名单）+ 真 PG ㊲ + 变异 M21b/M21c/M21d |

**2. 占位符扫描**：无 TBD / TODO / 「similar to Task N」；每个代码步骤都带完整可粘贴的代码块。唯一的「以实测为准」是 Task 3/4 Step 6 的 pytest 总数 —— 那是**故意的**（内嵌「跑某命令应得 N」的自证会自过期，本仓踩过），判绿判据写的是「无 failed/error」而不是硬编码数字。

**3. 类型一致性**：`init_cluster_marker(maint_conn, *, connect, cluster_schema_sql, try_seed_lock, release_seed_lock)` 的签名在 Task 3 定义、Task 4 追加使用、Task 5 三处调用，五处逐字一致。`_LIST_ALL_INTENT_SQL` 的输出列（`dbname` / `seed` / `db_oid` / `age_seconds`）与假件 `_orphan()` 的字典键、与循环体读的键，三处逐字一致。`_DELETE_ORPHAN_INTENT_SQL` 的**三个**参数（`$1=dbname`、`$2=seed`、`$3=ttl`）与调用处 `(r["dbname"], r["seed"], INTENT_TTL_SECONDS)` 一致，且被两条机械守卫钉住：`"seed = $2" in sql` 与 `sql.count("$1") == sql.count("$2") == sql.count("$3") == 1`；行为层再由 `test_orphan_cleanup_binds_the_delete_to_the_row_it_locked` 断言实参元组恰为 `(dbname, seed, ttl)`。

⚠️ **本节这次是逐个 `grep` 核过的，不是凭印象写的**（S3-R3 抓到过一次：SQL 与测试都改成了三参数，而本节和 Task 4 的 Interfaces 块还留着两参数的旧契约 —— 一份自相矛盾的计划会让实施者按其中错的那半去写）。核法：`grep -n 'ttl_seconds\|\$2=ttl\|(dbname, seed, ttl)\|\$1=dbname' <plan>`，逐条打开看。

**4. codex 对抗评审轮次记录**

| 轮 | verdict | finding | 处置 |
|---|---|---|---|
| **R1** | `needs-attention`（**未 approve**） | **[high]** 孤儿清理用 `now()` 量 TTL，而仓里既有的两条 intent TTL 判据早已因同一原因（codex S2a-R4-F2，真 PG 15 实测）换成 `statement_timestamp()`；`init_cluster_marker` 收的是已连好的连接、不控制事务生命周期，长事务里 `now()` 冻在过去 → 真实已过期的孤儿被量成新鲜 → 残骸永远清不掉。**且计划里的机械测试写死要求 `now()`，会把正确的修法判红。** | **全部接受并已改**（见下） |
| **R2** | `needs-attention`（**未 approve**） | **[high]** DELETE 只绑 dbname 不绑 seed；**[medium]** advisory lock 可重入让「取到了」的证明失效；**[medium]** 新场景库名没进 `_LIFECYCLE_DBS` | **三条结论全接受，两条的理由我按实测改写**（见下） |
| **R3** | `needs-attention`（**未 approve**） | **[high]** `_InitMaint` 的 `maintenance_presence` / `intent_table_missing` 初始化被误放到 `fetchval` 的 `return` 之后 → 死代码 → `intent_table_missing=True` 整个失效，补建路径那几条用例**改测健康集群**；**[medium]** Task 4 的 Interfaces 块与 Self-Review 仍写着两参数 DELETE 契约，与同一份计划里的 SQL/测试自相矛盾 | **两条全接受，全是 R2 编辑引入的自伤**；已修，并加了两道机械自检 |

| **R4** | `needs-attention`（**未 approve**） | **[high]** 首次初始化「先写标记、再跑现查」—— 现查仍可能拒绝，于是一次**报告失败**的 init 在集群里留下**合法标记**，而契约是「本工具从不清标记」；**[high]** `release_seed_lock` 只调用、**从不验证**锁真的还回去了 —— 空实现/连错连接/只释放一层可重入计数都会「成功返回」而锁仍挂着 | **两条全接受**；标记写入改成最后一个不可回滚写入（抽出 `_assert_disposable_cluster` 复用），release 后加活连接复核 |

| **R5** | `needs-attention`（**未 approve**） | **[high]** R4 只把标记挪到「首次初始化那一支的最后」，而 Task 4 随后在**整个函数的最后**又接了会抛的清理循环（DELETE 失败 / `seed_lock_not_released`，后者正是 R4 我自己加的）→ 首次初始化又能「报告失败、却留下合法标记」 | **接受**；标记改成**函数字面最后一句**，清理排在它之前，并在它之前补一次「紧贴」复查 |

| **R6** | `needs-attention`（**未 approve**） | **[high]** 混合态（marker+registry 在场、intent 缺失）走【绝对空】严判据 → 一个**已登记的、装着真数据的**合法 pilot 库被判成外来物 → 整台集群锁在修复路径之外，而 O4-F7 引入修复路径的全部理由就是修好这种集群 | **接受**，按 **user 拍板的方案 B**：只在新函数上加 `registry_usable` 开关，**零改动已合并的 `assert_cluster_allowed`** |

| **R7** | `needs-attention`（**未 approve**） | **[high]** R6 的放宽只看 `registry_present`，于是**标记缺失但登记表在场**（人工清过标记／部分还原／对手写维护库）时，登记行会被当成归属证明放行一个非空的伪 pilot 库，**并写下合法标记** —— 绕过首次初始化的【绝对空】证明，还废掉「人工清标记」这个逃生阀。我那条反向钉只造了「三张表全不在场」，恰好没覆盖这个组合 | **接受**；`_registry_usable = bool(rows) and presence["registry_present"]`，反向钉改成三档参数化 + ㊳ 加第三向 |

⚠️ **R7 又是我上一轮修复的洞** —— 而且是**同一族**：R6 我论证「登记表在场 ⇒ 凭据取得到」时，只看了「表在不在」，没问「**凭什么信它**」。根因一句话：**标记才是「这个维护库是我们的」的信任根**；闸 (ii) 敢信登记表，正因为闸 (i) **先**验过标记。我把凭据从它的信任根上摘下来单独用了。
⚠️ 我那条反向钉 `presence` 三个全设 False，**对这条判据零判别力** —— 变异 M43 特意点名只有后两档能证伪它，别拿第一档当证据。

R6 的核实与处置：

- ✅ **属实**。我写在 `_assert_disposable_cluster` docstring 里的理由「登记表要么为空、要么根本不存在」在混合态下**前提不成立** —— registry 可以在场且带着真实内容。而闸 (ii) 的同侪归属证明**根本不碰 `pilot_create_intent`**（实测：它只用 `read_pilot_meta_rows` + `_REGISTRY_HAS_SQL` + `_is_absolutely_empty`），所以那份凭据在混合态下是**取得到**的，我却把它扔了。
- 📉 **严重度有界，已实测**：`pilot_cluster_schema.sql` 由**单个提交**（#157）一次性引入三张表 —— **没有任何已发布版本会产生部分表集**；且至今不存在真实 pilot 集群。故这是**恢复路径的可用性**问题（可由人工损坏／部分还原到达），不是版本错位或数据安全问题。
- 🧭 **方案由 user 拍板（B）**：只改新函数，不动已合并的 `assert_cluster_allowed`（该函数是本模块最安全攸关的一处，4a-1 曾被评审 32 轮）。代价=归属判断在两处各有一份，已用机械守卫 `test_both_peer_proofs_use_the_same_two_facts` 钉住两处必须引用**同一组**符号。
- ⚠️ **放宽必须双向验证**：这是本片唯一一处**放宽**判据的改动。配了三条 host 反向钉（未登记的非空库仍拒 / 首次初始化不享受放宽 / 两处判据同源）+ 真 PG 档 **㊳**（同一混合态下「已登记 → 放行」与「未登记 → 拒」两向都跑）。假件的 `registered_dbnames` 是个集合，`_REGISTRY_HAS_SQL` 里 `JOIN pg_database ON d.oid = r.db_oid` 的**绑实例**语义在 host 上完全不求值 —— 故 ㊳ 不可省。

⚠️ **R5 这一条是我 R4 修复的直接回归** —— 教科书式的「修 symptom 会挪动失败面」：我把标记挪到了分支末尾，却没考虑到下一个 Task 会在函数末尾追加会抛的代码，而那段代码里**新加的 raise 正是 R4 修复的产物**。
**为什么这次是终点**：写标记现在是函数的**字面最后一句**，它之后不存在任何代码 —— 「副作用次序」这条原则在本函数内**再没有新的落点**。用例 `test_first_init_proves_the_cluster_again_immediately_before_the_marker` 用 `maint.executed[-1]` 把这条性质钉死。

R4 两条的核实与处置：

- ✅ **[high] 标记次序** —— 属实且可达：`assert_cluster_allowed` 会**重新枚举** `pg_database` 并逐个连进同侪库，预检到它之间的窗口里冒出同侪库、连接抖动、维护库多个用户对象，任一都会让它抛，而标记已经落地。修法取**重排**而非「失败时删标记」：后者要给本模块新增「删标记」能力，与契约直接冲突。抽出 `_assert_disposable_cluster`（免标记、零副作用）在写标记**之前**再跑一次，标记成为最后一个副作用。
  ⚠️ 诚实说明**残留**：DDL（三张表）仍然可能在一次最终失败的 init 里留下 —— 那是**无法消除**的，`CREATE TABLE` 与后续检查不可能原子，且闸 (i) 本来就要求这三张表存在才能评估。已把「标记」与「表」的风险等级分开：标记是**信任声明**，表是**结构**且不授权任何东西。
- ✅ **[high] release 未验证** —— 属实，且与我已经接受的「回调返回真不算证明」是**同一条纪律的另一半**（上一版只验了取、没验还）。这条泄漏尤其毒：R2 加的「事前已持有就跳过」会把它放大成**该连接从此静默跳过该 seed 的孤儿清理**，而跳过的理由看起来完全合理。已加 release 后的活连接复核 + 具名 code `seed_lock_not_released`。
  ⚠️ **反驳一半**：codex 建议「fail loudly **and close/poison the connection**」。**不关连接** —— 它是调用方的，本模块通篇不拥有也从不关它；关掉会让调用方拿到一个没预料到的死连接，还掩盖真正的接线错误。抛一个点名的 code 更诚实。

⚠️ **R3 的两条都不是设计问题，是我在 R2 编辑时弄坏的** —— 一条把初始化splice进了别的方法体，一条改了 SQL 与测试却漏改契约声明。故加了两道**对计划本身**的机械检查（见 Self-Review 第 6 条），并把「假件自检」升格成一条正式用例 `test_init_maint_fake_actually_models_the_states_it_claims`。

R2 的逐条核实（**两条的机制我不同意，结论仍改**）：

- ⚠️ **[high] 绑 seed —— 评审说的竞态被命名不变量挡住，但结论仍成立**。实测：`derive_db_name(seed) = f"kline_pilot_{seed}"`（`qmt_pilot_db.py:295`），spec 逐字写着「两个不同 seed 撞同一个 dbname 不可能」，`_INSERT_INTENT_SQL` 的 `EXCLUDED.dbname` 与 `EXCLUDED.seed` 由同一调用方按同一 seed 派生 —— 「同名行换了 seed」在生产路径上**造不出来**。**真正的理由是另一条**：那条不变量**没有任何数据库约束在兜**（无 CHECK、`dbname` 非生成列），而孤儿清理处理的恰恰是来路不明的行（旧版本写的 / `pg_restore` 还原的 / 人工插的）。DELETE 的授权来自「持有这一行 seed 的锁」，语句就该按那一行删。**已加 `AND seed = $2`**，失配时删 0 行（fail-closed）。
- ✅ **[medium] 可重入 —— 真 PG 15.12 实测坐实**：`pg_try_advisory_lock` 对一把本连接已持有的锁**照样返回 true**（计数器 1→2），`_SEED_LOCK_HELD_SQL` 在调用前**就已经是 true**，那道复核证明不了任何**新**互斥。已加「取锁前先证明本连接还没持有」的 fail-closed 前置检查。
  ⚠️ **但评审的后半句我反驳**：它把「release 只减一次、既有的锁留在 session 上」当缺陷 —— 那恰恰是**正确**行为（不能释放不是自己取的锁），`test_orphan_cleanup_does_not_release_a_lock_it_never_took` 钉的就是这条。**不改**。
  ⚠️ 也要说准：对**别的 session** 的互斥仍然成立（我们持有时别人取不到）。真正的危险是**自己**这一档 —— 本连接正在为该 seed 干别的事，而 init 删掉它进行中的凭据。
- ✅ **[medium] 白名单 —— 完全成立，是我漏的**，已加 Step 0。**评审只说到一条后果，我核出第二条**：除了 stranger 闸顶死运行，`purge_metadata_for` 只清点名库名的 intent/registry 行，故 ㉚（从不建库、但写 intent 行）**同样必须登记**。
  ⛔ 评审建议「扩展 harness 让 f-string 名字不能绕过扫描器」**不在 S3 做**：那要改公共扫描逻辑并回头核对既有 30 个场景，如实登记为残留。

**R2 修复顺带暴露的两个自引入缺陷**（不是评审提的，是改的过程中撞出来的）：

- 🐞 `_FakeConn.seed_lock_held` 是**一个静态布尔**，而孤儿清理现在**取锁前后各查一次**同一条 SQL —— 用静态布尔建模的话，两条判据里**必然有一条恒真**（且默认 `True` 会让所有既有孤儿用例直接跳过清理）。已把 `_InitMaint` 的锁状态改成**会迁移的集合** `held_seeds`，并配变异 **M31** 验假件自己的判别力。
- 🐞 计划里 `try_seed_lock=_locker()[0], release_seed_lock=_locker()[1]` 造的是**两对互不相干**的闭包，`record`/`released` 各记各的 —— 一族「取了没还」的断言会因此恒真。已改成同一次调用取一对。

R1 的三条已实测复核，**不是**照单全收：

- ✅ `statement_timestamp()` 确在 main 的两条 SQL 上（`qmt_pilot_db.py:1186` / `:2413`），且带 `codex S2a-R4-F2，真 PG 15 实测` 的出处注释 —— 评审关于「仓里已经换过」的陈述**属实**。
- ✅ 「计划的测试会把正确修法判红」**属实**，而且这正是 `feedback_plan_code_blocks_cause_vacuous_tests` 记的形态。
- ⚠️ **评审没说到、但更要命的一条（我自己补的）**：族级守卫 `test_intent_ttl_is_never_measured_against_the_transaction_clock` 遍历的是**手写名单** `("_READ_INTENT_SQL", "_INSERT_INTENT_SQL")`。S3 的两条新 SQL 是同族第三、四个成员，手写名单**不会收录它们** —— 就算把 SQL 改对了，守卫对新成员仍是**零覆盖**，下一次改错没人拦。故 Step 1b 把族成员改成**从模块推导** + 双向核对，并配变异 M21d 验守卫**自己**的判别力。
- ⚠️ 评审建议的「加一条真 PG 或单测模拟长事务」已落为**档 ㊲**；顺带发现 ⑤ ⑤b ㉙ ㉚ ㊱ 全在自动提交下跑，对时钟源**零判别力**（㉝c 那一档早就写下过同样的教训）。

**5. 对计划本身的机械自检（S3-R3 之后加，每次改完计划都要重跑）**

计划里的代码块会被**逐字粘贴**进测试文件，故它自己就得过语法与死代码检查。两条都已在当前版本上跑过：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4a2b-s3"
export PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
"$PY" - <<'EOF'
import ast, re, pathlib, textwrap
p = pathlib.Path("docs/superpowers/plans/2026-08-14-qmt-4a2b-s3-init-cluster-marker.md")
blocks = re.findall(r"```python\n(.*?)```", p.read_text(encoding="utf-8"), re.S)
bad = 0
for i, b in enumerate(blocks, 1):
    src = textwrap.dedent(b)
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        if src.lstrip().startswith(("def ", "class ", "@pytest")):
            print(f"❌ 块#{i} 语法错误 line~{e.lineno}: {e.msg}"); bad += 1
        continue
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for j, st in enumerate(node.body[:-1]):
                if isinstance(st, (ast.Return, ast.Raise)):
                    print(f"❌ 块#{i} {node.name}(): 第 {st.lineno} 行之后是死代码"); bad += 1
print("✅ 通过" if not bad else f"❌ {bad} 处")
EOF
```

- **①语法**：25 个块里 4 个是有意的片段（参数化表尾、三引号续接、`for` 头），其余全部 `ast.parse` 通过。
- **②死代码**：无「`return`/`raise` 之后仍有语句」。**这一条正是 R3 那个 high 的形态** —— `fetchval` 里 `return` 之后跟着 11 行构造期初始化，肉眼扫过去像是 `__init__` 的一部分。
- **③契约一致性**：`grep -n 'ttl_seconds\|\$2=ttl\|\$1=dbname\|(dbname, seed, ttl)'` 逐条打开核 —— R3 的 medium 就是这里漏的。

**6. 已知的判别力空缺（诚实登记）**：
- Task 2 里闸 (i) 新增的三条 `*_durable` 参数化档**对别名拆分零判别力**（假件整字典回传）——已在 Task 2 正文里写明，判别力由 `test_shape_fakes_cover_every_predicate`（机械）+ Task 3 的混合态用例（行为）+ 真 PG ⑤b（语义）三层提供。
- Task 4 里四条反向钉（`…only_under_the_seed_lock` / `…keeps_a_fresh_row…` / `…does_not_release_a_lock_it_never_took` / `…refuses_when_the_callback_lies…`）在功能未实现时**恒绿**，不能当「红→绿」证据 —— 已在 Step 2 写明，判别力由 M13/M15/M19/M17 逐条证明。
