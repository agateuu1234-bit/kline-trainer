# QMT 4a-2b 重新打包（拆成三个可评审片）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 PR #161（+5956 / −87，14 个提交，codex **15 轮从未 approve**）按「破坏性核心 / 集群初始化 / 纯验收证据」拆成三个各自可评审的片，让每片的评审面小到能真正收敛。

**Architecture:** 不做 rebase / cherry-pick —— 提交拓扑不支持（见「为什么不能按提交切」）。改为**按最终状态重新分片**：从 `origin/main` 切三条新分支，把 `feat/qmt-plan4a-2b-destructive` 的最终产物按**生产特性**分配，每片带上**恰好验证它自己**的 L2 真-PG 档位。

**Tech Stack:** Python 3.11 · asyncpg 0.31 · PostgreSQL 15.12（两个本地容器 `qmt-pg-r8` / `qmt-pg-r8b`，端口 55444 / 55445）· pytest 8.4.2

---

## Global Constraints

- **每片 ≤3 子项**。行数硬指标做不到（S3 的脚本本身就大），但**评审面**必须单一：一片只讲一件事。
- **禁述**「pilot 已完成」「100 股已出货」「真实数据接入完成」——真 QMT 数据一个字节都没流过。
- 所有 pilot 表一律 `public.` 限定；每条守卫连接先 `adopt_connection`（钉 search_path + 证明库/集群/实例）。
- 新测试必须做**变异验证**（中和判据 → 看**具名测试 / 该档**变红 → 用 `cp` 复原，**绝不用 `git checkout`**）。由控制者亲验，不接受实施者自证。
- 判绿**读输出内容**（结论行），不看管道后的 exit code；每条 git/闸门命令同时打印 branch/HEAD。
- `push` / `gh pr create` / `gh pr merge` 由 user 在真终端执行。
- codex 没真 approve 就别写「收敛」，如实写 needs-attention / 接受残留 / override。

---

## 为什么不能按提交切（实测，不是判断）

第一个提交 `6817c47` 就把生产代码（+625）、`_pilot_verify_harness.py`、
`verify_pilot_db_lifecycle.py`（+726）、`verify_pilot_two_phase_create.py` 改造、
测试（+1380）**全混在一起**；后续每个 fix 提交（R9–R14）也同时动生产 + 脚本 + 测试。

→ `cherry-pick` / `rebase -i` 都切不出干净的片。**只能按最终状态重新分配文件与档位。**

## 依赖方向（实测，推翻了「先合脚本」的直觉）

L2 脚本 import 的这些符号 **`origin/main` 上不存在**：
`authorize_reset` · `reset_pilot_database` · `init_cluster_marker` ·
`try_empty_remnant_exception` · `_mint_authorization` · `assert_binding_scalars` ·
`_TARGET_CLIENT_SESSIONS_SQL`

→ **纯脚本片不能先合**。切面必须按「生产特性 + 验证它的档位」成组。

### 39 档 lifecycle 的精确依赖（逐档实测）

| 依赖 | 档 |
|---|---|
| **只用 main 已有符号**（14 档）| ① ② ③ ④ ⑭ ⑮ ⑯ ⑰b ⑱ ⑲ ⑳ ⑳b ㉑ ㉔ |
| `init_cluster_marker`（5 档）| ⑤ ⑤b ㉖ ㉙ ㉚ |
| `authorize_reset` / `reset_pilot_database`（20 档）| ⑥ ⑦ ⑧ ⑨ ⑨b ⑨c ⑩ ⑪ ⑫ ⑬ ⑰ ㉒ ㉓ ㉕ ㉗ ㉗b ㉘ ㉛ ㉜ ㉜b |

concurrency 10 档：**Ⓐ Ⓐb Ⓑ Ⓑb Ⓑd Ⓑc Ⓒ 只用 main 已有符号**；Ⓓ Ⓓb Ⓔ 需要 reset。

⚠️ **⑥⑦⑧ 要拆半**：它们同时断言「复用被拒」（main 已有）与「带 `--reset` 也被拒」
（需要 `authorize_reset`）。复用那半进 S1，`--reset` 那半随 S2 补上。

---

## 三片的划分与次序

| 片 | 分支名 | 内容 | 生产代码 | 档位 |
|---|---|---|---|---|
| **S1** | `feat/qmt-4a2b-s1-verify-harness` | `_pilot_verify_harness.py` + `verify_pilot_two_phase_create.py` 改造 + concurrency 7 档 + lifecycle 14 档（+ ⑥⑦⑧ 的复用半）| **零** | 28 + 7 + 17 |
| **S2** | `feat/qmt-4a2b-s2-destructive-core` | 零对象例外 + `authorize_reset` + `reset_pilot_database` + 授权登记表 + **封锁统一（含 R15-F1）** | ~+1000 | lifecycle **新增 17 档 + 给 ⑥⑦⑧ 补 reset 半**、concurrency +3 档 |
| **S3** | `feat/qmt-4a2b-s3-cluster-init` | `--init-cluster-marker` + 孤儿清理（含 R14-F1 验锁）| ~+400 | +5 lifecycle |

**次序：S1 → S2 → S3。** S1 零生产改动，应当快速 approve；S2 是十五轮 finding 的**集中地**，
单独评审是这次重打包的全部价值所在；S3 与 S2 基本独立，可并行准备但在 S2 之后开 PR。

> ⚠️ **PR #161 在 S1/S2/S3 全部合并之前不要关闭** —— 它是唯一完整记录了 R1–R15
> 账本与三个生产缺陷的地方。三片合完之后再关，并在关闭评论里指向本计划。

---

## File Structure

| 文件 | 归属 | 责任 |
|---|---|---|
| `backend/scripts/_pilot_verify_harness.py` | S1 新建 | 三个脚本共用的**安全护栏**（破坏性 DSN 闸 / 只对过闸 DSN 动手的 `drop_database` / 白名单清场 / 反向自检）|
| `backend/scripts/verify_pilot_two_phase_create.py` | S1 改造 | 4a-1 的 28 档；本片只把护栏换成引用 harness，**档数与断言数不得变** |
| `backend/scripts/verify_pilot_concurrency.py` | S1 建（7 档）→ S2 补（3 档）| seed 锁互斥语义 |
| `backend/scripts/verify_pilot_db_lifecycle.py` | S1 建（17 档）→ S2 补（20 档）→ S3 补（5 档）| 库级闸的真 PG 验收 |
| `backend/qmt_pilot_db.py` | S2 / S3 各改自己那段 | 生产模块 |
| `backend/tests/test_qmt_pilot_db.py` | S2 / S3 各加自己那批 | host 假件层测试 |

---

## Task 1: S1 —— 共用护栏 + 只读档位（零生产代码改动）

**Files:**
- Create: `backend/scripts/_pilot_verify_harness.py`
- Create: `backend/scripts/verify_pilot_db_lifecycle.py`（只含 17 档）
- Create: `backend/scripts/verify_pilot_concurrency.py`（只含 7 档）
- Modify: `backend/scripts/verify_pilot_two_phase_create.py`（改为引用 harness）

**Interfaces:**
- Consumes: `origin/main` 上已有的 `assert_cluster_allowed` / `assert_db_allowed_for_reuse` /
  `create_pilot_database` / `quote_ident` / `sha256_of_sql` / `_SEED_LOCK_HELD_SQL` /
  `MARKER_PURPOSE` / `PILOT_META_KEYS` / `PilotDbBoundaryError` / `PilotClusterBoundaryError`
- Produces: `harness.assert_destructive_dsn_allowed(dsn, label) -> str | None` ·
  `harness.db_dsn(base_dsn, dbname) -> str` · `harness.drop_database(base_dsn, dbname)` ·
  `harness.assert_every_dsn_env_is_gated(script_path) -> int | None` ·
  `harness.assert_scratch_objects_are_namespaced(objs) -> int | None` ·
  `harness.assert_every_selfcheck_db_is_whitelisted(script_path, dbs, prefix) -> int | None` ·
  `harness.sweep_leftover_databases(conn, *, prefix, scenario_dbs, name_re) -> list[str] | int`

- [ ] **Step 1: 从 origin/main 切分支**

```
git worktree add ".dev/worktree/qmt-4a2b-s1" -b feat/qmt-4a2b-s1-verify-harness origin/main
```

- [ ] **Step 2: 基线必须先绿**

Run: `cd backend && ../.venv/bin/python -m pytest tests/ -q -p no:randomly`
Expected: 末行 `passed`，无 `failed` / `error`。**基线不绿就停下**——之后的红分不清是谁的。

- [ ] **Step 3: 原样搬入 harness**

从 `feat/qmt-plan4a-2b-destructive` 取 `backend/scripts/_pilot_verify_harness.py`：

```
git checkout feat/qmt-plan4a-2b-destructive -- backend/scripts/_pilot_verify_harness.py
```

⚠️ **一个字都不要改**。它是 codex 花 O4-R9-C2 / R33-C2 / R34-C2 / R37-C1 四轮收口的护栏。

- [ ] **Step 4: 改造 4a-1 那个脚本，并证明它没被改坏**

```
git checkout feat/qmt-plan4a-2b-destructive -- backend/scripts/verify_pilot_two_phase_create.py
```

Run（两个容器起着）：

```
export DSN="postgresql://postgres:$(docker inspect qmt-pg-r8 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | cut -d= -f2)@localhost:55444/postgres"
export DSN2="postgresql://postgres:$(docker inspect qmt-pg-r8b --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | cut -d= -f2)@localhost:55445/postgres"
.venv/bin/python backend/scripts/verify_pilot_two_phase_create.py
```

Expected: 末行 `✅ 28 档断言全部成立（真 PostgreSQL）`。**28 这个数字不许变** ——
它是「护栏抽取没有改变行为」的唯一判据。

- [ ] **Step 5: 搬 concurrency 的 7 档**

```
git checkout feat/qmt-plan4a-2b-destructive -- backend/scripts/verify_pilot_concurrency.py
```

然后**删掉** Ⓓ / Ⓓb / Ⓔ 三档及其专用常量（`_PLAIN_ROLE` / `_PLAIN_PASSWORD` 只被这三档用），
并把 `_EXPECTED_SCENARIOS` 改成：

```python
_EXPECTED_SCENARIOS = ("Ⓐ", "Ⓐb", "Ⓑ", "Ⓑb", "Ⓑd", "Ⓑc", "Ⓒ")
```

同时把 `_CONC_DBS` 收成只剩 `("kline_pilot_conc_b1",)`，并从顶层 import 里去掉
`reset_pilot_database`（main 上没有这个符号，留着会 ImportError）。

Run: `.venv/bin/python backend/scripts/verify_pilot_concurrency.py`
Expected: 末行 `✅ 7 档断言全部成立（真 PostgreSQL）`

- [ ] **Step 6: 搬 lifecycle 的 17 档**

```
git checkout feat/qmt-plan4a-2b-destructive -- backend/scripts/verify_pilot_db_lifecycle.py
```

**保留**：① ② ③ ④ ⑭ ⑮ ⑯ ⑰b ⑱ ⑲ ⑳ ⑳b ㉑ ㉔ ＋ ⑥ ⑦ ⑧ 的**复用半**
**删除**：⑤ ⑤b ⑨ ⑨b ⑨c ⑩ ⑪ ⑫ ⑬ ⑰ ㉒ ㉓ ㉕ ㉖ ㉗ ㉗b ㉘ ㉙ ㉚ ㉛ ㉜ ㉜b，
以及 ⑥⑦⑧ 里那段 `authorize_reset` 断言。

⑥⑦⑧ 循环体改成只留复用那半：

```python
        maint = await _maintenance(base_dsn, seed=seed)
        try:
            try:
                await assert_db_allowed_for_reuse(
                    maint, connect=connect_peer, db_name=dbname, seed=seed, **_REUSE_ARGS)
                check(False, f"{tag} 复用必须被闸 0− 拒", "竟然放行了")
            except PilotDbBoundaryError as exc:
                check(exc.code == "pilot_meta_ambiguous",
                      f"{tag} 复用 → pilot_meta_ambiguous", f"实得 {exc.code}")
            check(await _database_exists(maint, dbname),
                  f"{tag} 拒绝之后目标库仍然存在")
        finally:
            await maint.close()
```

⚠️ 三件事必须同步改，漏一件脚本会自己把自己挡住：
`_EXPECTED_SCENARIOS`（完整性闸）· `_LIFECYCLE_DBS`（白名单，harness 会在任何连接之前
拿源码里的库名字面量比对它）· 顶层 import（去掉 main 上不存在的符号）。

Run: `.venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py`
Expected: 末行 `✅ 17 档断言全部成立（真 PostgreSQL）`

- [ ] **Step 7: 三个脚本连跑，且 lifecycle 连跑三遍**

Expected: `✅ 28 档` / `✅ 17 档` / `✅ 7 档`；lifecycle 三遍末行**完全一样**
（专查间歇性 flake —— 本轮真踩到过一次 autovacuum 假拒）。

- [ ] **Step 8: 变异验证（3 条，控制者亲跑）**

| 中和方式 | 必须变红 |
|---|---|
| `harness.drop_database` 去掉「DSN 没过破坏性闸就抛」那条 | 任一脚本的 `assert_every_dsn_env_is_gated` 自检 |
| `_BUSINESS_STRUCTURE_SQL` 的 `klines_ohlc_double` 改成恒真 | lifecycle ⑱ |
| `_SEED_LOCK_HELD_SQL` 去掉 `objsubid = 1` | concurrency Ⓑb |

- [ ] **Step 9: 提交并开 PR**

PR 标题：`QMT 4a-2b/S1：真 PG 验收护栏 + 只读档位（零生产代码改动）`
PR 正文必须写明：**本片零生产代码改动**，`git diff --stat origin/main..HEAD -- backend/qmt_pilot_db.py`
的输出为空 —— 这是本片最重要的一条评审线索。

- [ ] **Step 10: codex 对抗性评审**

```
.claude/scripts/codex-attest.sh --scope branch-diff --base <origin/main sha> --head feat/qmt-4a2b-s1-verify-harness
```

⚠️ 不加 `--focus`（窄化会跑出假 approve）。收口只认 `branch-diff`。
拿到 approve 之后**不要 rebase**（账本绑死 head_sha）。

---

## Task 2: S2 —— 破坏性核心（含 R15-F1 的封锁统一）

**Files:**
- Modify: `backend/qmt_pilot_db.py`（零对象例外 / `authorize_reset` / `reset_pilot_database` /
  `_drop_pilot_database` / 授权登记表 / `assert_binding_scalars` / `_TARGET_CLIENT_SESSIONS_SQL`）
- Modify: `backend/scripts/verify_pilot_db_lifecycle.py`（补 20 档）
- Modify: `backend/scripts/verify_pilot_concurrency.py`（补 Ⓓ Ⓓb Ⓔ）
- Modify: `backend/tests/test_qmt_pilot_db.py`
- Modify: `docs/superpowers/specs/2026-07-27-qmt-plan4c-pilot-shipment-design.md`（错误码枚举）

**Interfaces:**
- Consumes: S1 的 harness（`import _pilot_verify_harness as harness`）
- Produces: `try_empty_remnant_exception(maint_conn, *, connect, db_name, seed) -> str | None` ·
  `authorize_reset(maint_conn, *, connect, db_name, seed, export_log_sha256, output_dir, reset_foreign_token) -> ResetAuthorization` ·
  `reset_pilot_database(...同上...) -> str` ·
  `assert_binding_scalars(export_log_sha256, output_dir) -> None`

- [ ] **Step 1: 从 S1 合并后的 main 切分支**（S1 必须先落地）

- [ ] **Step 2: 搬入生产代码，但 `_drop_pilot_database` 按新设计写**

⚠️ **不要照搬 `feat/qmt-plan4a-2b-destructive` 的 `_drop_pilot_database`** ——
它的封锁块只包了零对象例外那条路（R15-F1）。本片要写成**两条路统一**：

```python
    # 授权登记表里存四元组 + 绑定标量（R15-F1 需要在使用点复验绑定）
    # _MINTED_AUTHORIZATIONS[auth] = (db_name, seed, db_oid, via_empty_remnant,
    #                                 export_log_sha256, output_dir, foreign_token_ok)
    _record = _MINTED_AUTHORIZATIONS.get(authorization) \
        if type(authorization) is ResetAuthorization else None
    if _record is None:
        raise PilotDbBoundaryError("forged_reset_authorization", ...)
    (_auth_db, _auth_seed, _auth_oid, _auth_via_remnant,
     _auth_export_sha, _auth_output_dir, _auth_token_ok) = _record
    if _auth_db != db_name or _auth_seed != seed:
        raise PilotDbBoundaryError("forged_reset_authorization", ...)

    # ── 两条路**都**进这个临界区（R15-F1）──────────────────────────
    target_conn, oid_held = await _open_target(maint_conn, connect, db_name)
    try:
        if oid_held != _auth_oid:
            raise PilotDbBoundaryError("target_db_replaced", ...)
        _prior_limit = await maint_conn.fetchval(_READ_CONNLIMIT_SQL, db_name, _auth_oid)
        if _prior_limit is None:
            raise PilotDbBoundaryError("target_db_replaced", ...)
        await maint_conn.execute(_SEAL_CONNECTIONS_SQL(db_name))
        _sealed = True
        held_pid = await target_conn.fetchval(_BACKEND_PID_SQL)
        others = await maint_conn.fetch(_OTHER_CLIENT_SESSIONS_SQL, db_name, held_pid)
        if others:
            raise PilotDbBoundaryError("target_db_in_use", ...)
        if _auth_via_remnant:
            # 零对象例外：授权前提是「库是空的」→ 复验空
            if not await _is_absolutely_empty(target_conn):
                raise PilotDbBoundaryError("not_owned", ...)
        else:
            # 正常路：授权前提是「库是我们的 + 绑定相符（或过了令牌）」→ 复验它
            meta_now = await read_pilot_meta(target_conn)
            await _assert_ownership(meta_now, seed=seed)
            if not _binding_matches(meta_now, export_log_sha256=_auth_export_sha,
                                    output_dir=_auth_output_dir) and not _auth_token_ok:
                raise PilotDbBoundaryError(
                    "binding_mismatch",
                    f"{db_name!r} 的绑定在授权之后被改过 —— 授权它的前提已经不成立，拒绝 DROP")
    finally:
        _held_closed = await _close_quietly(target_conn, db_name)
    _assert_target_released(_held_closed, db_name)
```

- [ ] **Step 3: 写 R15-F1 的失败测试（TDD，先看它红）**

```python
def test_normal_reset_revalidates_ownership_under_the_seal():
    """正常 reset 路径也必须在封锁下复验归属（codex 4a-2 R15-F1，high）。

    授权读的是**当时**的 pilot_meta；授权到 DROP 之间它可以被改掉，
    而 oid 没变、会话数为 0，后面的检查全过 —— 于是 DROP 掉一个
    已经不满足授权前提的库。
    """
    maint = _DropMaint()
    tampered = _FakeConn(meta_rows=_meta_rows(seed="someone_else"))
    auth = _mint_authorization("kline_pilot_probe", "probe", "16400",
                               via_empty_remnant=False,
                               export_log_sha256="a" * 64, output_dir="/x/y",
                               foreign_token_ok=False)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_drop_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": tampered}),
            db_name="kline_pilot_probe", seed="probe", authorization=auth))
    assert ei.value.code == "not_owned"
    assert _drops(maint) == [], "归属在窗口里被改掉了，却还是 DROP 了"
```

Run: `pytest backend/tests/test_qmt_pilot_db.py -k normal_reset_revalidates -v`
Expected: FAIL（封锁块只包 remnant 时，正常路根本不复验）

- [ ] **Step 4: 实现 Step 2 的统一临界区，跑到绿**

- [ ] **Step 5: 补 17 档 lifecycle（+ ⑥⑦⑧ 的 reset 半）+ 3 档 concurrency**

从 `feat/qmt-plan4a-2b-destructive` 取这些档：
⑥⑦⑧ 的 `--reset` 半 · ⑨ ⑨b ⑨c ⑩ ⑪ ⑫ ⑬ ⑰ ㉒ ㉓ ㉕ ㉗ ㉗b ㉘ ㉛ ㉜ ㉜b · Ⓓ Ⓓb Ⓔ
（⑤ ⑤b ㉖ ㉙ ㉚ 属于 S3，**不要**搬进来）

- [ ] **Step 6: 新增真 PG 档 ㉝（R15-F1 的语义证明）**

在 lifecycle 里加：正常 reset 授权之后、DROP 之前，用注入的 `connect` 在
**第 N 次连目标库时**把 `pilot_meta` 的 `seed` 改掉 → 断言 reset 被拒且**库仍然存在**。

- [ ] **Step 7: 变异验证（控制者亲跑）**

| 中和方式 | 必须变红 |
|---|---|
| 封锁块改回只包 `if _auth_via_remnant:` | host `..._normal_reset_revalidates...` + 真 PG ㉝ |
| 正常路只复验归属、不复验绑定 | 新增的绑定档 |
| 使用点改回读对象属性（不查登记表） | `..._lookalike...` |
| 授权不绑 `(db_name, seed)` | `..._minted_for_another_database...` |

- [ ] **Step 8: 全套闸门 + 提交 + PR + codex**

Expected: host 全量 passed；lifecycle `✅ 35 档`（17 + 17 + 新增 ㉝）；concurrency `✅ 10 档`；two-phase `✅ 28 档`

---

## Task 3: S3 —— 集群初始化 + 孤儿清理

**Files:**
- Modify: `backend/qmt_pilot_db.py`（`init_cluster_marker` / `_DELETE_ORPHAN_INTENT_SQL` /
  `_MAINTENANCE_SHAPE_SQL` 的每表耐久性判据）
- Modify: `backend/scripts/verify_pilot_db_lifecycle.py`（补 ⑤ ⑤b ㉖ ㉙ ㉚）
- Modify: `backend/tests/test_qmt_pilot_db.py`

**Interfaces:**
- Consumes: S2 的 `authorize_reset`（⑤b 用它）
- Produces: `init_cluster_marker(maint_conn, *, connect, cluster_schema_sql, try_seed_lock, release_seed_lock) -> None`

- [ ] **Step 1: 从 S2 合并后的 main 切分支**

- [ ] **Step 2: 搬入 `init_cluster_marker`，含 R9-F1 与 R14-F1 两处修复**

⚠️ 两处**必须**带上，它们是这块代码上已确认的缺陷修复：
- **R9-F1**：耐久性判据拆成 `marker_durable` / `intent_durable` / `registry_durable`
  每表一条（合成一个跨表 count 时归因不到具体表，混合态下会先落 DDL 再拒）
- **R14-F1**：孤儿清理取锁之后、DELETE 之前补验 `_SEED_LOCK_HELD_SQL`
  （回调返回真不算证明；advisory lock 同 session 可重入）

- [ ] **Step 3: 补 5 档（⑤ ⑤b ㉖ ㉙ ㉚）+ 对应 host 测试**

- [ ] **Step 4: 变异验证（控制者亲跑）**

| 中和方式 | 必须变红 |
|---|---|
| 孤儿清理不验 `_SEED_LOCK_HELD_SQL` | host `..._callback_lies_about_the_lock` |
| 耐久性判据改回跨表 count | 真 PG ⑤b |
| init 靠标记短路现查 | 真 PG ㉙ |
| 取了 seed 锁不还 | 真 PG ㉚ |

- [ ] **Step 5: 全套闸门 + 提交 + PR + codex**

Expected: lifecycle `✅ 40 档`（35 + 5）

---

## Task 4: 收口

- [ ] **Step 1: 三片全部合并之后，关闭 PR #161**

关闭评论里写明：内容已按本计划拆成 S1/S2/S3 合入，并列出三个 PR 号。
⚠️ **在此之前不要关** —— #161 是唯一完整记录 R1–R15 账本与三个生产缺陷的地方。

- [ ] **Step 2: 更新交接单**

`docs/superpowers/plans/2026-08-05-qmt-plan4a-2-handoff.md`：把「两条待推」改成三片的落地状态，
并把 R15-F1 从「已知残留」移到「已在 S2 修复」。

- [ ] **Step 3: 清理 worktree**

`.dev/worktree/qmt-plan4a-2` 在 #161 关闭之前**别清**。

---

## Self-Review 结果

**1. 覆盖检查**：`feat/qmt-plan4a-2b-destructive` 的最终产物逐项对照 ——

| 产物 | 落在 |
|---|---|
| `_pilot_verify_harness.py` | S1 |
| `verify_pilot_two_phase_create.py` 改造 | S1 |
| lifecycle 39 档 | S1（17）+ S2（17，另给 ⑥⑦⑧ 补 reset 半）+ S3（5）＝ 39；S2 另新增 ㉝ → 最终 **40 档** |
| concurrency 10 档 | S1（7）+ S2（3）|
| 零对象例外 / reset 单一入口 / 授权登记表 | S2 |
| `assert_binding_scalars`（R13-F1）| S2 |
| `_TARGET_CLIENT_SESSIONS_SQL`（autovacuum 缺陷）| S2 |
| `init_cluster_marker` + 孤儿清理 | S3 |
| R9-F1 耐久性拆表 | S3 |
| R14-F1 孤儿清理验锁 | S3 |
| R15-F1 封锁统一 | **S2（新写，不照搬）** |
| 4c 错误码枚举（`connection_limit_not_restored` 等）| S2 |

**2. Placeholder 扫描**：无 TBD / TODO。每个 Step 都给了实际命令或代码。

**3. 类型一致性**：`_mint_authorization` 在 S2 的签名从四元组扩成七元组
（加 `export_log_sha256` / `output_dir` / `foreign_token_ok`）—— Task 2 Step 2 与 Step 3
的调用形态一致；S3 不碰它。

**4. 发现一处缺口，已补**：`--reset-foreign` 那条路的绑定**故意不匹配**，
若正常路复验只看 `_binding_matches` 会把合法的 foreign reset 判死。
故登记表里必须带 `foreign_token_ok`，复验条件写成
`_binding_matches(...) or _auth_token_ok`（已写进 Task 2 Step 2 的代码块）。

---

## 诚实的成本与风险

- **这是多个工作段的量**，不是一次能做完。S1 最轻（零生产改动），S2 最重。
- **每片仍要各自跑 codex**，没有「拆了就自动 approve」这回事。拆分买到的是
  **评审面单一** —— 十五轮的 finding 几乎全在破坏性核心，把它隔离成 ~1000 行是全部价值。
- **中途状态是可用的**：S1 合了就有真 PG 护栏与只读档位；S2 合了破坏性核心就完整。
  任何一片停下都不会让仓库处于半成品状态。
- **风险**：从 39 档里摘出 17 档时，`_EXPECTED_SCENARIOS` / `_LIFECYCLE_DBS` /
  顶层 import 三处必须同步；漏一处脚本会自己把自己挡住（harness 的白名单自检会
  在任何连接之前 return 5）。Task 1 Step 6 已写明这一点。
