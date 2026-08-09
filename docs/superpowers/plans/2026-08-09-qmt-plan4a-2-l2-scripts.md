# QMT Plan 4a-2 —— 两个 L2 真 PG 验收脚本 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 4a-2 的复用/破坏路径补上「只有真 PostgreSQL 能证伪」的那一层 —— host 假件对
「库到底有没有被删掉」「同一个 key 能不能插进两行」「advisory lock 的持有与释放语义」
一律建模不了，本轮已有**四处判据在 host 层零覆盖、只靠 SQL 文本守卫钉住**。

**Architecture:** 两个独立可执行脚本，共用 `backend/scripts/_pilot_verify_harness.py`
（破坏性 DSN 闸 / 只对过闸 DSN 动手的 `drop_database` / 三条纯源码自检 / 精确白名单清场）。
形态照抄 `verify_pilot_two_phase_create.py`：模块 docstring 写清背景/用法/退出码，
`async def main() -> int`，`asyncio.run` 收口，**退出码 0 = 全部断言成立**，
每档一行 `PASS`/`FAIL`，收尾核对**场景完整性清单**一个不缺。

**Tech Stack:** Python 3.11 / asyncpg 0.31.0 / PostgreSQL 15.12（Docker ×2）

**Spec:** `docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md` §6.2 与 §9
**权威性**：spec §4 是唯一权威；§6.2 是它的导出视图。本计划与 spec 冲突时以 §4 为准。

---

## Global Constraints

- **两个容器都要给**：`DSN`（qmt-pg-r8，55444）与 `DSN2`（qmt-pg-r8b，55445）。
  **缺 DSN2 直接判失败，绝不「跳过」** —— spec §9 明写「跳过被当成通过」是本仓栽过的坑。
  密码用 `docker inspect <名字> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep POSTGRES_PASSWORD`。
- **判绿读输出内容，不看管道后的 exit code**（`cmd | tail` 之后 `$?` 是 tail 的，本仓已踩两次）。
  运行命令一律写成 `…; echo "EXIT=$?"`，不用管道。
- **每个新库名必须进白名单常量**，否则 `_pilot_verify_harness.assert_every_selfcheck_db_is_whitelisted`
  会在任何连接发生之前 `return 5`。本脚本前缀 **`kline_pilot_lifecycle_`**（与 4a-1 的
  `kline_pilot_selfcheck_` 分开，两个脚本的清场互不干扰）。
- **临时对象一律 `zzqmtverify_` 前缀**，否则前缀自检 `return 6`。
- **每读一个 `DSN*` 环境变量就必须有一个 `assert_destructive_dsn_allowed(x, "DSN*")`**，
  否则反向断言 `return 7`。
- **⛔ spec §6.2 的分工硬约束**：**两阶段建库的事务边界与崩溃恢复四档归
  `verify_pilot_two_phase_create.py`（已存在），本计划的脚本不得重复实现。**
- **交付表述**：禁述「pilot 已完成」「100 股已出货」「真实数据接入完成」。

---

## ⚠️ 本计划最重要的一条纪律：每一档都要变异验证

4a-1 的 L2 脚本用血写下的教训（spec §6.2 逐字）：

> **④ 是唯一能判别「C1 是否真修好」的一档**：①②③ 在中和掉修复之后**照样全 PASS**（实测），
> 故 ④ 的注入点必须从 `PILOT_META_PHASE2_KEYS` **派生**、不得写死。

所以本计划里**每个 Task 的最后一步都是「中和被验的那道生产守卫 → 该档必须变红 → 复原」**，
不是可选的收尾。写完一档就验一档，不许攒到最后。
**由控制者亲验，不接受实施者自报。**

---

## File Structure

| 文件 | 责任 | 谁碰 |
|---|---|---|
| `backend/scripts/_pilot_verify_harness.py` | **已存在**（本分支已交付）。共用安全护栏。 | 只在需要新护栏时改 |
| `backend/scripts/verify_pilot_db_lifecycle.py` | **新增**。集群闸 / 库级闸 / 令牌 / 零对象例外 / init。 | Task 1–5 |
| `backend/scripts/verify_pilot_concurrency.py` | **新增**。advisory lock 的持有与释放语义。 | Task 6 |

**不修改任何生产代码。** 本计划是纯验收层；若某档跑红且证实是生产缺陷，
**停下来向控制者报告**，不要在本计划里顺手改 `qmt_pilot_db.py`。

---

### Task 1: 脚本骨架 + 集群闸五档

**Files:**
- Create: `backend/scripts/verify_pilot_db_lifecycle.py`

**Interfaces:**
- Consumes: `_pilot_verify_harness`（`assert_destructive_dsn_allowed` / `db_dsn` /
  `drop_database` / `assert_every_dsn_env_is_gated` / `assert_scratch_objects_are_namespaced` /
  `assert_every_selfcheck_db_is_whitelisted` / `sweep_leftover_databases`）；
  `qmt_pilot_db` 的 `assert_cluster_allowed` / `init_cluster_marker` / `PilotClusterBoundaryError`
- Produces: `scenario(tag)` / `check(ok, label, detail)` / `_LIFECYCLE_DBS` / `_EXPECTED_SCENARIOS`
  —— 后续 Task 往同一个 `main()` 里追加档位

- [ ] **Step 1: 写骨架（常量 + 自检 + 清场 + scenario/check + 完整性闸）**

照 `verify_pilot_two_phase_create.py:395-514` 的形态。要点：
- `_LIFECYCLE_DBS` 列出本脚本用到的**每一个**库名（前缀 `kline_pilot_lifecycle_`）
- `_SCRATCH_OBJECTS` 列出临时对象（`zzqmtverify_` 前缀）
- 三条纯源码自检**排在破坏性清场之前**（零副作用，放后面会被 strangers 闸先触发）
- `_EXPECTED_SCENARIOS` 收尾核对，少一档即 `return 1` 并点名

- [ ] **Step 2: 跑空骨架，确认护栏都活着**

Run:
```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4a-2"
P1=$(docker inspect qmt-pg-r8 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep POSTGRES_PASSWORD | cut -d= -f2)
P2=$(docker inspect qmt-pg-r8b --format '{{range .Config.Env}}{{println .}}{{end}}' | grep POSTGRES_PASSWORD | cut -d= -f2)
DSN="postgresql://postgres:${P1}@localhost:55444/postgres" DSN2="postgresql://postgres:${P2}@localhost:55445/postgres" ./.venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py; echo "EXIT=$?"
```
Expected: `EXIT=1` + 完整性闸点名「这些档没跑：…」（此时一档都没实现，**空骨架必须红**）

- [ ] **Step 3: 集群闸五档**（spec §6.2 逐字）

| 档 | 造什么 | 断言 |
|---|---|---|
| ① 无标记 | 维护库清掉 `pilot_cluster_marker` 行 | `assert_cluster_allowed` 抛 `no_marker`；**目标库事后未被创建** |
| ② 有标记但有无关库 | 建一个 `zzqmtverify_unrelated` 库 | 抛 `unrelated_database`；目标库未创建 |
| ③ 维护库含用户表 | 维护库建 `public.zzqmtverify_probe_a` | 抛 `maintenance_db_not_empty` |
| ④ 含无主 `kline_pilot_*` | 建 `kline_pilot_lifecycle_orphan` 并在里面建一张表（非空、无 `pilot_meta`）| 抛 `unowned_pilot_database` |
| ⑤ 同场景下 `--init-cluster-marker` 也须拒绝 | 同 ③ 的脏维护库 | `init_cluster_marker` 抛 `maintenance_db_not_empty`，**且 `pilot_create_intent` 表事后不存在**（证明零 DDL） |

⚠️ ⑤ 的第二条断言是 codex 4a-2b R5-F1 的钉子：**副作用必须排在证明之后**。

- [ ] **Step 4: 跑，确认五档全 PASS**

Run: 同 Step 2。Expected: 五档 `PASS`，其余档仍在完整性闸里点名（`EXIT=1`）

- [ ] **Step 5: 变异验证（控制者亲验）**

| 中和方式（改 `backend/qmt_pilot_db.py`） | 必须变红的档 |
|---|---|
| `assert_cluster_allowed` 的 `(i)` 标记判定改成恒真 | ① |
| `(ii)` 的 `PILOT_DB_NAME_RE.fullmatch` 判定改成恒真 | ② |
| `(iii)` 的 `leftover` 判定改成恒假 | ③ |
| `(ii)` 里 `_is_absolutely_empty` 那条豁免改成恒真 | ④ |
| `init_cluster_marker` 的 1d 维护库空判定改成恒假 | ⑤ |

复原后重跑，五档回绿。**五次红色输出贴给控制者。**

- [ ] **Step 6: 提交**

```
git add backend/scripts/verify_pilot_db_lifecycle.py
git commit -F - <<'MSG'
test(4a-2b L2): lifecycle 脚本骨架 + 集群闸五档（真 PG）

每档都经变异验证：中和对应的生产守卫 → 该档变红 → 复原回绿。
MSG
```

---

### Task 2: 闸 0− 三库 + 反向钉

**Files:**
- Modify: `backend/scripts/verify_pilot_db_lifecycle.py`

**Interfaces:**
- Consumes: Task 1 的 `scenario` / `check` / 清场
- Produces: 档 ⑥⑦⑧⑨

- [ ] **Step 1: 三库 + 一条反向钉**

spec §6.2 逐字：「**闸 0− 三库**（`key` 无唯一约束且两行 `seed` / 缺 `output_dir` 键 /
`value` 为 `varchar(8)`）+ 反向钉」。

| 档 | 造什么 | 断言 |
|---|---|---|
| ⑥ | 库里手工建 `pilot_meta(key text, value text)`（**无主键**）并插两行 `seed` | 复用 → `pilot_meta_ambiguous`；**带 `--reset` 也拒**；**库事后仍在** |
| ⑦ | 正常建库后 `DELETE FROM pilot_meta WHERE key='output_dir'` | 同上三条 |
| ⑧ | `pilot_meta.value` 改成 `varchar(8)` | 同上三条 |
| ⑨ **反向钉** | 零用户对象、库名全等 `kline_pilot_lifecycle_<seed>` 的**空残骸** + `--reset` | **必须正常 DROP + 重建**（spec O4-F6：写成「闸 0− 四库、`--reset` 也拒」就是把 R55-F1 的锁死钉进 L2 门）|

⚠️ ⑥⑦⑧ 的「带 `--reset` 也拒」与 ⑨ 的「`--reset` 必须放行」**方向相反**，
这一对是 spec 明确要求的分寸。少了 ⑨，实现可以「一律拒」而三档全绿。

- [ ] **Step 2: 跑，确认四档全 PASS** —— 同 Task 1 Step 2 的命令

- [ ] **Step 3: 变异验证**

| 中和方式 | 必须变红的档 |
|---|---|
| `read_pilot_meta_rows` 的 `key_is_unique` 判定改成恒真 | ⑥ |
| `read_pilot_meta` 的 `missing` 授权键判定改成空列表 | ⑦ |
| `_PILOT_META_SHAPE_SQL` 的 `value_is_text` 改成恒真 | ⑧ |
| `authorize_reset` 跳过 `try_empty_remnant_exception`（直接落闸序）| ⑨ |

- [ ] **Step 4: 提交**（message 同 Task 1 形态，写明档号）

---

### Task 3: 归属/绑定的破坏性分支 + `--reset-foreign` 三跑

**Files:**
- Modify: `backend/scripts/verify_pilot_db_lifecycle.py`

- [ ] **Step 1: 破坏性分支两档 + 令牌三跑三档**

spec §6.2：「归属闸与绑定闸的**破坏性分支**（真验「目标库事后仍然存在」）；
`--reset-foreign` 三跑（裸 flag / 错令牌 / 正确令牌）」。

| 档 | 造什么 | 断言 |
|---|---|---|
| ⑩ | 正常建库后把 `pilot_meta.seed` 改成别的值，带 `--reset` | `not_owned`；**`SELECT 1 FROM pg_database` 证明库事后仍在**；`confirm_token is None` |
| ⑪ | 把 `output_dir` 改成 `/someone_else`，带 `--reset` **不带令牌** | `reset_foreign_token_required`；库仍在；`exc.confirm_token` 非空 |
| ⑫ | 同 ⑪，带**错**令牌 `deadbeefcafe` | `reset_foreign_token_invalid`；库仍在 |
| ⑬ | 同 ⑪，带**正确**令牌（由 `derive_confirm_token` 从库里读到的三元组算出）| **DROP 成功**：`pg_database` 里查不到该库 |
| ⑭ | ⑪⑫ 两档的异常 message | **不含令牌**（spec §9-1w：令牌只走 `confirm_token`，进了 message 会被写进报告）|

⚠️ ⑬ 是**唯一能证明令牌真的解锁了 DROP** 的一档。少了它，实现可以「一律拒」而 ⑩⑪⑫ 全绿。

- [ ] **Step 2: 跑，确认五档全 PASS**

- [ ] **Step 3: 变异验证**

| 中和方式 | 必须变红的档 |
|---|---|
| `_assert_ownership` 改成恒过 | ⑩ |
| `_assert_reset_foreign_token` 的 `is None` 分支删掉 | ⑪ |
| 令牌比较 `!=` 改成 `is None` | ⑫ |
| `derive_confirm_token` 的 preimage 顺序调换 | ⑬ |
| 把 `token` 拼回 message | ⑭ |

- [ ] **Step 4: 提交**

---

### Task 4: `state` 流转 + `initializing` 两向 + 陈旧库四件套

**Files:**
- Modify: `backend/scripts/verify_pilot_db_lifecycle.py`

- [ ] **Step 1: 两阶段 state 流转 + initializing 两向**

⚠️ **只验 `state` 的流转与复用/reset 两个方向；崩溃恢复三档归
`verify_pilot_two_phase_create.py`，本脚本不重复**（spec §6.2 分工硬约束）。

| 档 | 造什么 | 断言 |
|---|---|---|
| ⑮ | 正常建库跑完 | `pilot_meta.state == 'ready'` 且九键齐全 |
| ⑯ | 造**真正的阶段-1 崩溃形态**：`state='initializing'` **且删掉阶段 2 的两个键**（`schema_sha256`/`contract_version`），走**复用** | `db_state_initializing`（**不是** `schema_fingerprint_mismatch`）|

> ⚠️ **⑯ 的夹具最初写错了**（实施时实测发现）：在一个跑完的库上只翻 `state`，指纹仍然相符，
> 于是「把 state 判定挪到闸 1 之后」这条变异**存活** —— 注释宣称在测次序，夹具却观测不到次序。
> spec O4-F8 的论证前提逐字是「阶段 1 只写 7 个键」，删掉阶段 2 那两个键才是这一档的真身。
| ⑰ **反向钉** | 同 ⑯ 的库，走 **`--reset`** | **必须 DROP + 重建成功**（R55-F1）|

- [x] **Step 1b（实施时追加）：⑰b 健康库复用**必须被放行****

本脚本其余每一档都断言「拒了」，于是一条**恒抛**的闸在每一档看起来都在正常工作。
⑰b 是唯一断言「放行」的复用档，它是刚性必需的 —— 见下面 Step 3 记录的生产缺陷。

| 档 | 造什么 | 断言 |
|---|---|---|
| ⑰b | 正常建库跑完（零损坏）走**复用** | **零异常放行**（闸 2 的每条查询都真的在真 PG 上成功跑过）|

- [x] **Step 2: 陈旧库四件套 fail-closed**

spec §6.2 逐字：「OHLC 仍 `DECIMAL` / `file_path` 为 `VARCHAR` / 缺 `uq_stock_start` / 缺 `content_hash`」。
四档各造一个**结构被改坏**的 ready 库，走复用：

| 档 | 造什么 | 断言 |
|---|---|---|
| ⑱ | `ALTER TABLE klines ALTER COLUMN open TYPE DECIMAL(10,4)` 等四列 | `structure_mismatch`；DROP 从未执行 |
| ⑲ | `ALTER TABLE training_sets ALTER COLUMN file_path TYPE VARCHAR(255)` | 同上 |
| ⑳ | `ALTER TABLE training_sets DROP CONSTRAINT uq_stock_start` | 同上 |
| ⑳b **（实施时追加）** | 删掉 `uq_stock_start` 后**用同名但不同列重建**（`(stock_code, file_path)`）| 同上 |
| ㉑ | `ALTER TABLE training_sets DROP COLUMN content_hash` | 同上 |

⚠️ 每档都要断言 **`db_boundary_error` 取到的是 `structure_mismatch`**，
而不只是「拒了」—— 重叠判据下取到别的码说明闸的次序错了。

⚠️ **⑳b 为什么必须有**：⑳ 把约束整个删掉时 `uq_stock_start_present` 与
`uq_stock_start_columns_ok` **同时**为假、互相遮蔽，⑳ 单独证伪不了后者。而
`columns_ok` 正是 codex 4a-2a R1 为「同名换列」加的 —— 没有 ⑳b，把它整条删掉全套档位照样全绿。

- [x] **Step 3: 跑，确认全 PASS**

> ### ⚠️ 本步挖出一个生产缺陷（已修，见 Step 4 最后一行）
>
> `_BUSINESS_STRUCTURE_SQL` 里 `array_agg(a.attname ORDER BY a.attname)` 出来是 `name[]`，
> 右边字面量是 `text[]`，**PostgreSQL 没有 `name[] = text[]` 操作符**（标量 `name = text` 有）。
> 该查询在**任何**库上都抛，闸 2 的业务表五组判据于是**从未成功执行过一次**，
> 全部兜成 `target_db_unreadable`。
>
> - **影响**：fail-closed，不放行任何危险东西；但整条复用路径 100% 不可用，
>   且错误码把运维指向权限/连通性，而不是「schema 漂移 → 用 --reset 重建」。
> - **为什么 429 条 host 测试 + codex 十四轮全没抓到**：host 层 `_FakeConn` 按子串派发
>   预置字典，**SQL 文本一次都没送进 PG**。这是 L2 脚本存在的全部理由。
> - **为什么本脚本原有档位也没抓到**：它们**全部**断言「拒了」，
>   一条恒抛的闸在每一档看起来都在正常工作 → 追加 ⑰b。
> - **修法**：`array_agg(a.attname::text ORDER BY a.attname::text)`（`backend/qmt_pilot_db.py`）。

- [x] **Step 4: 变异验证**（8 条，全部由控制者亲跑亲验变红）

| 中和方式 | 必须变红的档 | 结果 |
|---|---|---|
| `assert_db_allowed_for_reuse` 的 `state` 判定挪到闸 1 之后 | ⑯ | RED（取到 `schema_fingerprint_mismatch`）|
| `assert_db_allowed_for_reset` 加上 `state` 判定 | ⑰ | RED |
| `_BUSINESS_STRUCTURE_SQL` 的 `klines_ohlc_double` 改成恒真 | ⑱ | RED |
| 同上 `file_path_is_text` | ⑲ | RED |
| 同上 `uq_stock_start_present` **与** `uq_stock_start_columns_ok` **两条一起** | ⑳ | RED |
| 同上 `uq_stock_start_columns_ok` **单独** | ⑳b | RED |
| 同上 `content_hash_present` | ㉑ | RED |
| 撤掉 `::text`（把 `name[] = text[]` 复原）| ⑰b | RED |

> ⚠️ 计划原写「中和 `uq_stock_start_present` → ⑳ 变红」，**实测该变异存活**：
> 约束整个没了时 `columns_ok` 也为假、替它兜住。两条判据必须**一起**关，
> 而 `columns_ok` 的单独判别力由新增的 ⑳b 提供。
>
> ⚠️ 变异跑器的档位匹配从 `tag in line` 收紧成**整 token 相等**：
> ⑨/⑨b/⑨c、⑰/⑰b、⑳/⑳b 互为子串，用 `in` 会让 ⑳b 的 FAIL 行把 ⑳ 的变异算成「抓到了」——
> **跑器自己会变成假绿的来源**（这一轮实测撞到）。

- [ ] **Step 5: 提交**

---

### Task 5: 2a/2b 新增面（spec 写成之后才有的东西）

**Files:**
- Modify: `backend/scripts/verify_pilot_db_lifecycle.py`

> 本 Task 覆盖的是 **spec §6.2 写成之后**由 codex 十二轮评审逼出来的判据。
> 它们**在 host 假件层零覆盖或只靠 SQL 文本守卫**，真语义只有这里能坐实。

- [ ] **Step 1: 逐档**

| 档 | 判据（哪一轮来的） | 造什么 | 断言 |
|---|---|---|---|
| ㉒ | 闸 0r 登记凭据（2a R3-F1）| 正常建库后 `DELETE FROM pilot_database_registry` | **复用**被拒 `registry_proof_missing`；**`--reset` 仍放行**（不对称是有意的）|
| ㉓ | 闸 2 活体判据（2a R1）| ready 库上 `CREATE TRIGGER` 到 `public.klines` | 复用拒 `business_tables_have_dependents`；**`--reset` 放行** |
| ㉔ | 活目录指纹（2a R1）| `ALTER TABLE training_sets ALTER COLUMN status SET DEFAULT 'sent'` | 复用拒 `business_schema_drift` |
| ㉕ | intent 新鲜度**只认库时钟**（2b R3-F2；**host 层零覆盖**）| 把 intent 行的 `created_at` 改成很远的未来、`inserted_at` 保持超期 | 零对象例外**不适用**（证明看的是 `inserted_at` 不是 `created_at`）|
| ㉖ | 孤儿删除**锁内原子求值**（2b R3-F2）| 列出行之后、取锁之前把该行 `inserted_at` 刷新成新鲜 | 该行**事后仍在**（证明判据在 SQL 里当下求值，不是按快照）|
| ㉗ | DROP 后清凭据（2b R4-F1）| 走完一次 `reset_pilot_database` | intent 行事后**不存在**；**紧接着用新 `run_id` 重建能成功**（不清的话会撞 `intent_row_conflict`）|
| ㉘ | 零对象例外的紧贴复查（2b R2-F1）| 授权后、DROP 前往空库里建一张表 | **拒绝 DROP**、库事后仍在 |
| ㉙ | init 每次现查（2b R3-F1）| 已有合法标记的集群上事后建一个无关库 | `init_cluster_marker` 抛 `unrelated_database`（标记不能短路现查）|
| ㉚ | 孤儿清理**取了锁必须还**（2b R5-F2）| 跑一次带孤儿行的 init | 事后在**同一条连接**上 `pg_try_advisory_lock` 同一个 seed **仍能取到**（证明还掉了）|
| ㉛ | 【绝对空】对物化视图（spec §9-1a2）| 建一个只含物化视图（1000 行真数据）的同名库 + `--reset` | **必须拒绝且库事后仍在** |
| ㉜ | 集群闸遍历过目标库之后立刻 `--reset`（spec §4 规定 4）| 正常路径 | **必须成功 DROP + 重建**（证明「读一律短连接」真做到了）|

- [x] **Step 2: 跑，确认十一档全 PASS**（脚本总计 36 档全绿）

- [x] **Step 3: 变异验证**（逐档，中和对应生产守卫；㉕㉖ 两档尤其重要 ——
  它们是 host 层**零覆盖**的那两条，若中和后仍绿说明这一档也是空的）

11 条变异，全部由控制者亲跑亲验。**10 条 RED、1 条如实登记为「被前面的档位遮蔽」**。

| 中和的生产守卫 | 档 | 结果 |
|---|---|---|
| 闸 0r 的登记凭据恒为真 | ㉒ | RED |
| 不查业务表上的触发器/规则/RLS | ㉓ | RED |
| 不比活目录指纹 | ㉔ | RED |
| 零对象例外不看 intent 新鲜度 | ㉕ | RED |
| 孤儿删除的判据不在锁内求值 | ㉖ | RED |
| DROP 成功之后不清那条 intent 凭据 | ㉗ | RED |
| DROP 前不做【绝对空】紧贴复查 | ㉘ | RED |
| init 靠标记短路现查 | ㉙ | RED |
| 孤儿清理取了 seed 锁不还 | ㉚ | RED |
| 【绝对空】改用 information_schema | ㉛ | RED |
| 集群闸 (ii) 读完不关连接**且持住引用** | ㉜ | **遮蔽**（见下） |

> ### 三条实施时挖出的判别力缺陷（都是我自己写的档/变异的问题）
>
> **① ㉗ 原来是恒真的。** 夹具用 `_build` 造，而 `create_pilot_database` **跑成功时
> 自己就把 intent 行清掉了**（`_CLEAR_INTENT_SQL`）—— 于是「事后 0 条」不管 DROP
> 后的清理在不在都成立。把 DROP 后的清理整条删掉，㉗ 照样绿。
> 改法：夹具改成 R4-F1 真正针对的形态 —— **零对象例外那条路**的残骸（手工插一行
> 已确认的凭据），并断言前置「凭据已就位」。
>
> **② ㉖ 的第一版变异是假红。** `WHERE dbname = $1 AND $2 IS NOT NULL` 让 PG 推断不出
> `$2` 的类型 → 整条 init 抛 `IndeterminateDatatypeError`。㉖ 是**因为脚本崩了**才红的，
> 不是因为它抓到了判据被中和。加 `$2::bigint` 之后才是真红。
>
> **③ ㉜ 的判别力被前面的档位遮蔽（如实登记，不编场景）。**
> · 把闸 (ii) 的 `await _close_quietly(other, name)` 换成 `pass` → **变异存活**：
>   CPython 的引用计数会在 `other` 出作用域时立刻回收并断开，
>   「忘了关」在这个解释器上根本产生不出滞留会话。
> · 换成「不关且**持住引用**」→ 滞留会话真的出现了，但它在 **④ 的清场**
>   （本脚本第一次 DROP）就抛 `ObjectInUseError` 把脚本打死。
>   凡是走 reset 的档（⑨⑬⑰㉗㉘…）都排在 ㉜ 之前，**按构造它不可能是第一个观测点**。
> 结论：该性质确实被套件捕获，只是首个观测点不是 ㉜。㉜ 的独立价值是**正向钉** ——
> 防「实现为了省事把 reset 一律拒掉」那一类回归。

> ### ⚠️ 本 Task 挖出**第二个生产缺陷**：DROP 预检把 autovacuum worker 当成占用者
>
> ㉜ 在**干净代码**上间歇性变红，占用者是
> `{'pid': …, 'usename': None, 'application_name': ''}`。
>
> **取证（真 PG 实验，`autovacuum_naptime=1s`）**：
>
> | 观测 | 结果 |
> |---|---|
> | pilot 库上出现的非客户端后端 | `{'backend_type': 'autovacuum worker', 'usename': None, 'application_name': ''}` —— 与 ㉜ 失败时记录的占用者逐字吻合 |
> | 它在场时 PostgreSQL 自己 `DROP DATABASE` | **成功**（PG 会先终止目标库上的 autovacuum worker 再删）|
>
> **缺陷**：`_TARGET_SESSIONS_SQL` 数了 `pg_stat_activity` 的**全部**行。于是
> `--reset`（陈旧 schema 库的**唯一**出路）会**间歇性**假拒，还给出一条运维根本
> 执行不了的动作（「请让它们自行退出后重试」，而占用者是后台进程）。
> 在 CI 里表现为 flake，在现场表现为「重试几次又好了」的玄学。
>
> **修法（root cause，两处使用点语义本就不同，故拆成两条常量）**：
> · 预检改用新的 `_TARGET_CLIENT_SESSIONS_SQL`（`AND a.backend_type = 'client backend'`）；
> · DROP 被顶住之后的**诊断**仍用 `_TARGET_SESSIONS_SQL` 看全部后端 —— 操作者需要知道是谁。
> · 收窄不削弱护栏：真正会顶住 DROP 的后端仍由 DROP 自己的 55006 兜住，映射成同一个码。
>
> **新增 ㉜b（反向断言，防收窄过头）**：目标库上开一条真客户端连接 →
> 断言**模块自己的预检谓词**看得见它、且 reset 报 `target_db_in_use`、库事后仍在。
>
> **变异（两条，均由控制者亲跑）**：
>
> | 中和方式 | 档 | 结果 |
> |---|---|---|
> | 预检谓词收窄过头（过滤成 `'autovacuum worker'`）| ㉜b | RED（模块谓词返回 `[]`）|
> | 预检**整个跳过**（`if False and occupants:`）| ㉜b | **存活，exit=0** —— 如实登记 |
>
> 后一条的诚实含义：这条预检是**纯纵深**，真正的裁决权在 `DROP DATABASE` 自己的
> 55006，且它被映射成同一个 `target_db_in_use`。不为它编一个够得到的场景。
>
> **「不数 autovacuum worker」那一向没有常驻档**：逼出一个 autovacuum worker 要
> `ALTER SYSTEM SET autovacuum_naptime`（持久且全局），对验收脚本太侵入。
> 该向由上面那次一次性真 PG 实验坐实，如实登记。

> ### 另一个实施时挖出的脚本缺陷（非判别力，但会假绿）
>
> 我把 `reset_pilot_database` 提到顶层 import 时，只删掉了**三处局部 import 里的一处**。
> 剩下两处让 `reset_pilot_database` 在整个 `main()` 里成为**局部名**，
> 于是排在它们之前的 ⑨ 直接 `UnboundLocalError`。
> 更该记的是：我当时**只看了 ㉒ 之后的输出**就判绿，没看总判据行 ——
> 判绿必须读**结论行**（「✅ N 档全部成立」/「❌ …」），不能读过滤后的片段。

- [ ] **Step 4: 提交**

---

### Task 6: `verify_pilot_concurrency.py`

**Files:**
- Create: `backend/scripts/verify_pilot_concurrency.py`

**Interfaces:**
- Consumes: `_pilot_verify_harness`
- Produces: 独立可执行脚本

- [x] **Step 1: 三档 → 实交七档**（Ⓐ Ⓐb Ⓑ Ⓑb Ⓑd Ⓑc Ⓒ）

spec §6.2 逐字：「同 `--seed`、不同 `--maintenance-dsn` 的两个进程 —— 断言第二个在
`pg_try_advisory_lock` 处**立刻**失败返回（**须设短超时并断言它没有在等**），
且未执行任何 `DROP`/`CREATE`；杀掉第一个后第二个能立即取得锁」。

| 档 | 造什么 | 断言 |
|---|---|---|
| Ⓐ | 连接 A 取住 `seed=conc` 的锁；连接 B 试取 | B **立刻**返回 false；`time.monotonic()` 差 **< 1 秒**（证明没在等）|
| Ⓑ | 同上，B 随后调 `create_pilot_database` | 抛 `seed_lock_not_held`；**`pg_database` 里没有新库**、维护库里没有新 intent 行 |
| Ⓒ | 关掉 A 的连接 | B **立刻**取得锁（会话级锁随连接断开自动释放）|

⚠️ Ⓐ 的「没在等」必须用**时间**断言，不能只断言返回 false —— 阻塞版
`pg_advisory_lock` 最终也会返回 false 之外的东西，而「等了 30 秒才失败」
在一次并发运行里等于把另一次运行挂住。

**实施时补的四档（理由都是「原三档证伪不了它」）**：

| 档 | 造什么 | 断言 |
|---|---|---|
| Ⓐb | 在**第二台集群**（DSN2）上取同一个 seed 的锁 | **取得到** —— advisory lock 是**每集群**的，`--maintenance-dsn` 指到另一台集群时按 seed 的互斥**完全不存在**。这条限制必须是被验证过的事实，不是想当然。（也顺带证明 DSN2 与 DSN 真是两台集群）|
| Ⓑb | 用**两参数** `pg_try_advisory_lock(int,int)` 拼出**同样的 classid/objid** | 前置断言它真撞上了同一个键（objsubid=2），然后 `_SEED_LOCK_HELD_SQL` 必须**不认** |
| Ⓑd | 用 `pg_try_advisory_lock_shared`（classid/objid/**objsubid 全一样**，只差 mode）| 前置断言撞上同键同 objsubid + **反向**证明另一条连接能同时拿到它（共享锁根本不互斥），然后谓词必须**不认** |
| Ⓑc | 找一个 `hashtext` 为**负**的 seed，取锁 | 谓词必须判「持有」—— 键派生里有 `(classid::bigint << 32) \| objid::bigint`，而 `hashtext` 返回有符号 int4，**约一半的 seed 是负数**。现有档位用的 seed 恰好都是正数是碰运气，不是被验证过的性质。（实测：PG 的 `<<` 回绕，负值算得对，无缺陷）|

- [x] **Step 2: 跑** —— 七档全 PASS，`EXIT=0`

- [x] **Step 3: 变异验证**（4 条，全部由控制者亲跑亲验）

| 中和方式 | 档 | 结果 |
|---|---|---|
| `_SEED_LOCK_HELD_SQL` 去掉 `objsubid = 1` | Ⓑb | RED |
| `_SEED_LOCK_HELD_SQL` 去掉 `mode = 'ExclusiveLock'` | Ⓑd | RED |
| 键派生改成 `abs(hashtext(...))` | Ⓑc | RED |
| `create_pilot_database` 的 seed 锁判定恒真 | Ⓑ | RED |

> ⚠️ **计划原写的「去掉 `objsubid = 1` → Ⓐ 变红」是错的**：Ⓐ 验的是
> `pg_try_advisory_lock` 的**平台行为**，`_SEED_LOCK_HELD_SQL` 根本没参与，
> 那条变异打不红 Ⓐ。真正被它证伪的是新加的 Ⓑb。
>
> ⚠️ **Ⓐ / Ⓐb / Ⓒ 没有对应的生产守卫可中和**（如实登记）：本模块**从不取锁**
> （spec O1-F4），它只验锁是否被持有。这三档验的是 PostgreSQL 的平台行为
> ——「try 版立刻返回」「锁是每集群的」「会话级锁随连接断开释放」——
> 而这三条正是 spec §4 整套互斥设计的**地基假设**，属于
> 「设计地基靠基础设施行为 → 必须在真环境验，不能用假件」那一族。
> **不为它们编一个够得到的变异**：编出来的只会是假覆盖。

- [ ] **Step 4: 提交**

---

## 收尾：两个脚本一起跑 + 交接单更新

- [ ] **1. 两个脚本各跑一遍，末行都是 `EXIT=0`**
- [ ] **2. 4a-1 那个脚本复跑，仍是 28 档 / 178 条断言 / `EXIT=0`**（证明 harness 没被改坏）
- [ ] **3. host 全量仍绿**（`pytest tests/ -q`）
- [ ] **4. 把两个脚本的档数与断言数写进交接单第三节**
- [ ] **5. 非 coder 验收清单补两项**：起容器 → 跑脚本 → 期望末行 `EXIT=0`

---

## Self-Review 结果

**1. Spec 覆盖**（逐条对照 §6.2 对 `verify_pilot_db_lifecycle.py` 的要求）：

| spec 要求 | 落在哪 | |
|---|---|---|
| 集群闸五档 | Task 1 ①–⑤ | ✅ |
| 两阶段建库 + `state` 流转 | Task 4 ⑮ | ✅ |
| 陈旧库四件套 fail-closed | Task 4 ⑱–㉑ | ✅ |
| 归属闸与绑定闸的破坏性分支 | Task 3 ⑩⑪ | ✅ |
| `--reset-foreign` 三跑 | Task 3 ⑪⑫⑬ | ✅ |
| 闸 0− 三库 + 反向钉 | Task 2 ⑥–⑨ | ✅ |
| `state=='initializing'` 两向 | Task 4 ⑯⑰ | ✅ |
| 崩溃恢复三档 | **刻意不做** —— spec §6.2 明写归 `verify_pilot_two_phase_create.py` | ⛔ 有意 |
| `verify_pilot_concurrency.py` 三条 | Task 6 Ⓐ–Ⓒ | ✅ |
| 【绝对空】物化视图档（§9-1a2）| Task 5 ㉛ | ✅ |
| 集群闸遍历后立刻 reset（§4 规定 4）| Task 5 ㉜ | ✅ |

**2. Placeholder 扫描**：无 TBD/TODO。每档都写明了「造什么 / 断言什么 / 用哪条变异验证」。
⚠️ 本计划**刻意不内联完整脚本源码** —— 本仓已实证「计划的代码块本身是恒真测试的根因」
（`feedback_plan_code_blocks_cause_vacuous_tests`）：4a-1 的计划片段写于模块 405 行时期，
到 1815 行后整体过期。故本计划给的是**判据与变异对照表**，源码由实施者按当时的真实 API 写。

**3. 类型一致性**：`scenario` / `check` 的签名在 Task 1 定义，Task 2–5 沿用；
两个脚本的退出码语义一致（0=全绿 / 1=有档没跑或有 FAIL / 2=用法 / 3=DSN 未过闸 /
4=strangers / 5=白名单 / 6=前缀 / 7=DSN 反向断言），与 4a-1 那个脚本对齐。

**4. 发现一处缺口，已补**：spec §6.2 只说「闸 0− 三库 + 反向钉」，没说反向钉造什么。
按 O4-F6 的原文（「零对象残骸不走闸 0−」）定为「零用户对象的同名空库 + `--reset` → 正常 DROP 重建」，
已写进 Task 2 档 ⑨。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-09-qmt-plan4a-2-l2-scripts.md`.
