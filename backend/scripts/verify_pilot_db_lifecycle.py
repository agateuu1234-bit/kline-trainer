#!/usr/bin/env python3
"""验证 4a-2 的**库级闸与破坏性路径**在真 PostgreSQL 上真的成立。

背景：4a-2 的 host 单测用的是假 conn，它**建模不了**这些东西 ——
「库到底有没有被创建/删除」「集群里现在有什么」「同一个 key 能不能插进两行」
「拒绝之后维护库里是不是真的一张表都没多出来」。本轮更有几处判据在 host 层是
**零覆盖**的，只靠 SQL 文本守卫钉着（intent 新鲜度的时钟来源、孤儿删除的锁内原子求值）。

**本脚本存在的唯一理由，就是这些档只有真 PG 能证伪。**

⚠️ 与 `verify_pilot_two_phase_create.py` 的分工（spec §6.2 逐字规定）：
   **两阶段建库的事务边界与崩溃恢复四档归那个脚本，本脚本不得重复实现。**
   本脚本管：集群闸五档 / 闸 0− 三库 + 反向钉 / 归属闸与绑定闸的破坏性分支 /
   `--reset-foreign` 三跑 / `state` 流转两向 / 陈旧库四件套 / 2a-2b 新增面。

用法（需**两个**真 PG；DSN 指向的库里会建/删 `kline_pilot_lifecycle_*`）：

    P1=$(docker inspect qmt-pg-r8  --format '{{range .Config.Env}}{{println .}}{{end}}' \\
         | grep POSTGRES_PASSWORD | cut -d= -f2)
    DSN="postgresql://postgres:${P1}@localhost:55444/postgres" \\
      .venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py; echo "EXIT=$?"

⚠️ **本脚本只要 DSN**：它没有跨集群档，要求 DSN2 会让人以为跨集群被覆盖了。
   跨集群那条（advisory lock 是每集群的）在 `verify_pilot_concurrency.py` 的 Ⓐb。
⚠️ **判绿读输出内容，不要看管道后的 exit code**（`cmd | tail` 之后 `$?` 是 tail 的）。

退出码：0=全绿 / 1=有档没跑或有 FAIL / 2=用法 / 3=DSN 未过破坏性闸 /
4=残留库不在白名单 / 5=库名没登记 / 6=临时对象名没带前缀 / 7=DSN 环境变量没过闸。
"""
from __future__ import annotations

import asyncio
import hashlib
import os
import pathlib
import re
import sys

import asyncpg

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import _pilot_verify_harness as harness  # noqa: E402
from qmt_pilot_db import (MARKER_PURPOSE,  # noqa: E402
                          PILOT_META_KEYS, PilotClusterBoundaryError,
                          PilotDbBoundaryError, assert_cluster_allowed,
                          assert_db_allowed_for_reuse,
                          create_pilot_database, quote_ident, sha256_of_sql)
_SCHEMA_SQL = (pathlib.Path(__file__).resolve().parents[1]
               / "sql/schema.sql").read_text(encoding="utf-8")
_PILOT_SCHEMA_SQL = (pathlib.Path(__file__).resolve().parents[1]
                     / "sql/pilot_schema.sql").read_text(encoding="utf-8")

# 建库参数。⚠️ 指纹**由内容算**（O4-R19-C1）：模块会自校，配死值一律拒。
_EXPORT_LOG_SHA = "a" * 64
_OUTPUT_DIR = "/tmp/verify_pilot_db_lifecycle"
_CREATED_AT = "20260809T101530123456Z"
_BUILD_ARGS = dict(
    schema_sql=_SCHEMA_SQL,
    pilot_schema_sql=_PILOT_SCHEMA_SQL,
    schema_sha256=sha256_of_sql(_SCHEMA_SQL),
    pilot_schema_sha256=sha256_of_sql(_PILOT_SCHEMA_SQL),
    export_log_sha256=_EXPORT_LOG_SHA,
    output_dir=_OUTPUT_DIR,
    created_at=_CREATED_AT,
)
_REUSE_ARGS = dict(
    schema_sha256=sha256_of_sql(_SCHEMA_SQL),
    pilot_schema_sha256=sha256_of_sql(_PILOT_SCHEMA_SQL),
    export_log_sha256=_EXPORT_LOG_SHA,
    output_dir=_OUTPUT_DIR,
)
_RESET_ARGS = dict(export_log_sha256=_EXPORT_LOG_SHA, output_dir=_OUTPUT_DIR,
                   reset_foreign_token=None)

_BACKEND = pathlib.Path(__file__).resolve().parents[1]

# 本脚本的库名前缀。**与 4a-1 那个脚本的 `kline_pilot_selfcheck_` 分开** ——
# 两个脚本的前置清场各扫各的前缀，互不误删。
_PREFIX = "kline_pilot_lifecycle_"
_NAME_RE = re.compile(r"\Akline_pilot_lifecycle[a-z0-9_]*\Z")

# ⚠️ **精确白名单**：清场只删这张表里的名字（harness 会挡住不认识的同前缀库）。
#    新增场景时忘了把库名加进来，`assert_every_selfcheck_db_is_whitelisted` 会在
#    任何连接发生之前 return 5。
_LIFECYCLE_DBS = (
    # ⚠️ `c4` 由 ①②③④ 用 f"{_PREFIX}c4" 拼出，**不是源码里的字面量** ——
    #    扫描器（只认字面量）不会要求它，但清场必须认得它：
    #    否则崩溃留下的 c4 会被当成 stranger，把整个脚本挡住（返回 4）。
    "kline_pilot_lifecycle_c4",
    "kline_pilot_lifecycle_g6",
    "kline_pilot_lifecycle_g7",
    "kline_pilot_lifecycle_g8",
    "kline_pilot_lifecycle_r17b",
    "kline_pilot_lifecycle_r24",
    "kline_pilot_lifecycle_s15",
    "kline_pilot_lifecycle_x18",
    "kline_pilot_lifecycle_x19",
    "kline_pilot_lifecycle_x20",
    "kline_pilot_lifecycle_x20b",
    "kline_pilot_lifecycle_x21",
)

# 本脚本在维护库里造的临时对象。前缀 `zzqmtverify_` 表明归属（harness 自检钉住）。
_SCRATCH_OBJECTS = (
    ("TABLE", "public.zzqmtverify_lifecycle_probe"),
)

# 无关库（不带 pilot 前缀）—— 用于集群闸 ② 那一档。
# ⚠️ 它不匹配 `_PREFIX`，故**不进** `_LIFECYCLE_DBS`（那张表是「同前缀库」的白名单）；
#    它的清理单独做，见 `_sweep_unrelated`。
_UNRELATED_DB = "zzqmtverify_unrelated"

# 验收闸的**完整性清单**：收尾核对每一档都真的跑过。
# ⚠️ 少一档即失败 —— **「静默没跑」与「通过了」在输出上完全一样**，
#    这与本仓反复栽过的「空转的检查比没有检查更糟」是同一族。
# ⚠️ 本片（S1）**只含不依赖破坏性入口的档**；其余随 S2 / S3 补回来 ——
#    见 docs/superpowers/plans/2026-08-10-qmt-plan4a-2b-repackaging.md
_EXPECTED_SCENARIOS = ("①", "②", "③", "④", "⑥", "⑦", "⑧", "⑮", "⑯",
                       "⑰b", "⑱", "⑲", "⑳", "⑳b", "㉑", "㉔")


async def _connect(dsn: str) -> asyncpg.Connection:
    return await asyncpg.connect(dsn)


async def _apply_cluster_schema(conn) -> None:
    """把三张维护表建出来（本脚本自己造前置状态时用，不经 `init_cluster_marker`）。"""
    await conn.execute((_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8"))


async def _write_marker(conn) -> None:
    await conn.execute(
        "INSERT INTO public.pilot_cluster_marker (purpose) VALUES ($1)"
        " ON CONFLICT (purpose) DO NOTHING", MARKER_PURPOSE)


async def _clear_marker(conn) -> None:
    await conn.execute("DELETE FROM public.pilot_cluster_marker")


async def _peer_connect_factory(base_dsn: str):
    """闸 (ii) 会逐个连进同侪库 —— 给它一个按库名建连接的工厂。"""
    async def _connect_peer(name: str):
        return await asyncpg.connect(harness.db_dsn(base_dsn, name))
    return _connect_peer


async def _database_exists(conn, name: str) -> bool:
    return bool(await conn.fetchval(
        "SELECT count(*) FROM pg_database WHERE datname = $1", name))


async def _relation_exists(base_dsn: str, dbname: str, relname: str) -> bool:
    """某个库里有没有这张表。**用于「拒绝之后是不是真的没留下东西」这类断言。**"""
    conn = await asyncpg.connect(harness.db_dsn(base_dsn, dbname))
    try:
        return bool(await conn.fetchval(
            "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
            " WHERE n.nspname = 'public' AND c.relname = $1", relname))
    finally:
        await conn.close()


async def _maintenance(base_dsn: str, *, seed: str | None = None) -> asyncpg.Connection:
    """维护连接。传 `seed` 时**真的取**按 seed 的 advisory lock ——
    模块会在活连接上验它（O4-R5-C2），不信调用方传的布尔值。"""
    conn = await asyncpg.connect(base_dsn)
    await _apply_cluster_schema(conn)
    await _write_marker(conn)
    if seed is not None:
        got = await conn.fetchval(
            "SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))", seed)
        if not got:
            raise RuntimeError(f"取不到 seed={seed!r} 的 advisory lock")
    return conn


async def _build(base_dsn: str, seed: str, connect_peer) -> str:
    """按两阶段建一个真 pilot 库（真 schema 文件），返回库名。"""
    dbname = f"kline_pilot_{seed}"
    await harness.drop_database(base_dsn, dbname)
    maint = await _maintenance(base_dsn, seed=seed)
    try:
        await create_pilot_database(maint, connect=connect_peer, db_name=dbname,
                                    seed=seed, run_id=f"lifecycle-{seed}", **_BUILD_ARGS)
    finally:
        await maint.close()
    return dbname


async def _in_db(base_dsn: str, dbname: str, *statements: str) -> None:
    """在目标库里执行若干语句（用来把一个正常库改坏）。"""
    conn = await asyncpg.connect(harness.db_dsn(base_dsn, dbname))
    try:
        for st in statements:
            await conn.execute(st)
    finally:
        await conn.close()


async def _sweep_unrelated(conn) -> None:
    """清掉本脚本可能留下的无关库与临时对象。

    ⚠️ 只删**本脚本自己造的那个固定名字**，不按前缀盲扫 —— 与 harness 的
       白名单清场同一条纪律：前缀匹配 ≠ 本脚本建的。
    """
    await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(_UNRELATED_DB))
    for kind, obj in _SCRATCH_OBJECTS:
        await conn.execute(f"DROP {kind} IF EXISTS {obj}"
                           + (" CASCADE" if kind == "SCHEMA" else ""))


async def main() -> int:
    base_dsn = os.environ.get("DSN")
    if not base_dsn:
        print("用法：DSN='postgresql://user:pw@host:port/postgres' "
              "python backend/scripts/verify_pilot_db_lifecycle.py",
              file=sys.stderr)
        return 2
    # ⚠️ **本脚本不要 DSN2**（codex 4a-2b/S1 R1-F2）：它此前读了 DSN2、过了破坏性闸、
    #    还因为缺它而硬失败，**却一处都没用过**——「本脚本的跨集群档位」这句话是假的，
    #    这个脚本一个跨集群档都没有。要求一个用不到的环境变量，会让操作者与 CI
    #    以为跨集群被覆盖了，正是本仓反复栽的「宣称的保证 > 实际提供的保证」。
    #    真正用 DSN2 的是 `verify_pilot_concurrency.py` 的 Ⓐb（advisory lock 是每集群的）。
    #    ⚠️ 将来这里真加了跨集群档，**必须同时**把 DSN2 的读取 + 破坏性闸加回来 ——
    #       `harness.assert_every_dsn_env_is_gated` 会在任何连接之前挡住「读了却没加闸」。

    # 破坏性闸**必须先于对该 DSN 的任何 connect/DDL**。
    if harness.assert_destructive_dsn_allowed(base_dsn, "DSN") is None:
        return 3

    # 三条纯源码自检（零副作用），**必须排在破坏性清场之前**：
    # 放在清场之后会被 strangers 闸先触发而永远测不到。
    for rc in (harness.assert_every_dsn_env_is_gated(__file__),
               harness.assert_scratch_objects_are_namespaced(_SCRATCH_OBJECTS),
               harness.assert_every_selfcheck_db_is_whitelisted(
                   __file__, _LIFECYCLE_DBS, _PREFIX)):
        if rc is not None:
            return rc

    # 前置清场：上一次崩溃会留下库、登记行与临时对象；不清的话下一次运行会被
    # 上一次的残留顶红，且红的位置与真因毫无关系。
    pre = await _connect(base_dsn)
    try:
        await _apply_cluster_schema(pre)
        swept = await harness.sweep_leftover_databases(
            pre, prefix=_PREFIX, scenario_dbs=_LIFECYCLE_DBS, name_re=_NAME_RE)
        if isinstance(swept, int):
            return swept
        await _sweep_unrelated(pre)
        await pre.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname LIKE $1", f"{_PREFIX}%")
        await pre.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname LIKE $1", f"{_PREFIX}%")
        if swept:
            print(f"（前置清场：删掉上一次运行残留的 {swept}）")
    finally:
        await pre.close()

    failures: list[str] = []
    ran: set[str] = set()

    def scenario(tag: str) -> None:
        ran.add(tag)

    def check(ok: bool, label: str, detail: str = "") -> None:
        # detail 只在**失败**时打印 —— 它写的是失败时的解释。
        print(f"  {'PASS' if ok else 'FAIL'}  {label}"
              + ("" if ok else f"  —— {detail}" if detail else ""))
        if not ok:
            failures.append(label)

    connect_peer = await _peer_connect_factory(base_dsn)
    target = f"{_PREFIX}c4"

    # ── ① 无标记 → 集群闸拒，且目标库未被创建 ──────────────────────────
    scenario("①")
    print("① 无标记")
    conn = await _connect(base_dsn)
    try:
        await _clear_marker(conn)
        try:
            await assert_cluster_allowed(conn, connect=connect_peer, target_db=target)
            check(False, "① 无标记时集群闸必须拒", "竟然放行了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "no_marker", "① 无标记 → no_marker", f"实得 {exc.code}")
        check(not await _database_exists(conn, target),
              "① 拒绝之后目标库未被创建")
    finally:
        await conn.close()

    # ── ② 有标记但集群含无关库 → 拒 ────────────────────────────────────
    scenario("②")
    print("② 有标记但集群含无关库")
    conn = await _connect(base_dsn)
    try:
        await _write_marker(conn)
        await conn.execute("CREATE DATABASE " + quote_ident(_UNRELATED_DB))
        try:
            await assert_cluster_allowed(conn, connect=connect_peer, target_db=target)
            check(False, "② 有无关库时集群闸必须拒", "竟然放行了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "unrelated_database",
                  "② 无关库 → unrelated_database", f"实得 {exc.code}")
        check(not await _database_exists(conn, target),
              "② 拒绝之后目标库未被创建")
        await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(_UNRELATED_DB))
    finally:
        await conn.close()

    # ── ③ 维护库含用户表 → 拒 ──────────────────────────────────────────
    scenario("③")
    print("③ 维护库含用户表")
    conn = await _connect(base_dsn)
    try:
        await conn.execute("CREATE TABLE public.zzqmtverify_lifecycle_probe (id int)")
        try:
            await assert_cluster_allowed(conn, connect=connect_peer, target_db=target)
            check(False, "③ 维护库非空时集群闸必须拒", "竟然放行了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "maintenance_db_not_empty",
                  "③ 维护库含用户表 → maintenance_db_not_empty", f"实得 {exc.code}")
        await conn.execute("DROP TABLE IF EXISTS public.zzqmtverify_lifecycle_probe")
    finally:
        await conn.close()

    # ── ④ 含无主的同前缀库（非空、无 pilot_meta）→ 拒 ──────────────────
    #    ⚠️ 前缀名**不是**归属证明（spec R22-F1，本 spec 里「形状不是归属」的第五次）。
    scenario("④")
    print("④ 含无主的同前缀库")
    conn = await _connect(base_dsn)
    try:
        await conn.execute("CREATE DATABASE " + quote_ident(target))
        stray = await asyncpg.connect(harness.db_dsn(base_dsn, target))
        try:
            # 造成「非空、且没有合法 pilot_meta」——正是闸 (ii) 要拒的形态。
            await stray.execute("CREATE TABLE public.zzqmtverify_lifecycle_probe (id int)")
        finally:
            await stray.close()
        try:
            # 目标库自己被闸 (ii) 排除，故这里用**另一个**目标名，让它被枚举到。
            await assert_cluster_allowed(conn, connect=connect_peer,
                                         target_db=f"{_PREFIX}other")
            check(False, "④ 无主同前缀库必须拒", "竟然放行了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "unowned_pilot_database",
                  "④ 无主同前缀库 → unowned_pilot_database", f"实得 {exc.code}")
        await harness.drop_database(base_dsn, target)
    finally:
        await conn.close()

    # ── 闸 0− 三库 + 反向钉（spec §6.2 逐字）─────────────────────────────
    #    ⚠️ **变异验证挖出来的判别力事实（如实记，别当成三档各管一条判据）**：
    #       · 中和**结构判据**（`_PILOT_META_SHAPE_SQL`）→ 变红的是 **⑧**，不是 ⑥ ——
    #         ⑥ 的坏表同时被运行时那条抓住，两条判据在 ⑥ 上**互相遮蔽**。
    #       · 中和**运行时重复键判定**（`if key in seen`）→ **一档都不红**。
    #         原因：结构判据要求 `key` 上有**主键**，而有主键就插不进重复行 ——
    #         那条运行时判定在真 PG 上**够不到**，是纯纵深。
    #         这里**不为它编一个够得到的场景**（编出来的只会是假覆盖）；如实登记。
    #    ⚠️ ⑥⑦⑧ 的「带 --reset 也拒」与 ⑨ 的「--reset 必须放行」**方向相反**。
    #       这一对是 spec 明确要求的分寸（O4-F6）：少了 ⑨，实现可以「一律拒」而三档全绿，
    #       那就是把 R55-F1 的锁死钉进 CI。
    for tag, seed, label, damage in (
        ("⑥", "lifecycle_g6", "key 无唯一约束且塞两行 seed", (
            "DROP TABLE public.pilot_meta",
            "CREATE TABLE public.pilot_meta (key TEXT NOT NULL, value TEXT NOT NULL)",
            "INSERT INTO public.pilot_meta (key, value) VALUES "
            "('tool','qmt_pilot'),('seed','lifecycle_g6'),('seed','someone_else'),"
            f"('export_log_sha256','{_EXPORT_LOG_SHA}'),('output_dir','{_OUTPUT_DIR}')",
        )),
        ("⑦", "lifecycle_g7", "缺 output_dir 授权键", (
            "DELETE FROM public.pilot_meta WHERE key = 'output_dir'",
        )),
        ("⑧", "lifecycle_g8", "value 列被改成 varchar(8)", (
            "ALTER TABLE public.pilot_meta ALTER COLUMN value TYPE VARCHAR(8) "
            "USING left(value, 8)",
        )),
    ):
        scenario(tag)
        print(f"{tag} 闸 0−：{label}")
        dbname = await _build(base_dsn, seed, connect_peer)
        await _in_db(base_dsn, dbname, *damage)

        # 复用路径 → 必须拒
        maint = await _maintenance(base_dsn, seed=seed)
        try:
            try:
                await assert_db_allowed_for_reuse(
                    maint, connect=connect_peer, db_name=dbname, seed=seed, **_REUSE_ARGS)
                check(False, f"{tag} 复用必须被闸 0− 拒", "竟然放行了")
            except PilotDbBoundaryError as exc:
                check(exc.code == "pilot_meta_ambiguous",
                      f"{tag} 复用 → pilot_meta_ambiguous", f"实得 {exc.code}")
            # ⚠️ 「带 --reset 也必须拒」那半**在 S2**（它要 `authorize_reset`，
            #    而本片零生产代码改动、main 上还没有那个符号）。
            #    ⚠️ S2 落地时必须补回来 —— spec R80-F1：DROP 路径根本不跑闸 2，
            #    把 pilot_meta 的断言只放进闸 2 会让最危险的那条路径原封不动。
            check(await _database_exists(maint, dbname),
                  f"{tag} 拒绝之后目标库仍然存在")
        finally:
            await maint.close()
        await harness.drop_database(base_dsn, dbname)

    # ── ⑮⑯ state 流转 + initializing 的**复用**方向 ────────────────────
    #    ⚠️ 反向钉 ⑰（同一个 initializing 库走 --reset 必须能 DROP + 重建）**在 S2** ——
    #       它要 `reset_pilot_database`。⚠️ S2 落地时必须补回来：少了它，
    #       实现可以「一律拒」而 ⑯ 照样绿，那就是把 R55-F1 的锁死钉进 CI。
    #    ⚠️ 只验 state 的流转与复用方向 ——
    #       **建库两阶段的崩溃恢复归 `verify_pilot_two_phase_create.py`，本脚本不重复**
    #       （spec §6.2 的分工硬约束）。
    scenario("⑮")
    print("⑮ 正常建库跑完 → state=ready 且九键齐全")
    seed15 = "lifecycle_s15"
    db15 = await _build(base_dsn, seed15, connect_peer)
    peer = await asyncpg.connect(harness.db_dsn(base_dsn, db15))
    try:
        meta15 = {r["key"]: r["value"] for r in
                  await peer.fetch("SELECT key, value FROM public.pilot_meta")}
    finally:
        await peer.close()
    check(meta15.get("state") == "ready", "⑮ 跑完之后 state=ready",
          f"实得 {meta15.get('state')!r}")
    missing15 = [k for k in PILOT_META_KEYS if k not in meta15]
    check(not missing15, "⑮ pilot_meta 九键齐全", f"缺 {missing15}")

    scenario("⑯")
    print("⑯ state=initializing 走复用 → 必须报 db_state_initializing")
    # ⚠️ 判据是**取到哪个码**，不只是「拒了」：state 必须排在闸 1（指纹）**之前**求值，
    #    否则闸 1 会先撞「值不符」并报 schema_fingerprint_mismatch，
    #    于是 db_state_initializing 永远产不出来、恢复指引也从「用 --reset 重建」
    #    错成「schema 漂移」（spec O4-F8）。
    # ⚠️ 必须造成**真正的阶段-1 崩溃形态**，不能只把 `state` 翻回去：
    #    在一个跑完的库上单翻 `state`，`schema_sha256`/`contract_version` 仍然相符，
    #    于是把 state 判定挪到闸 1 之后**这一档照样绿** —— 注释宣称在测次序，
    #    夹具却观测不到次序（实测：该变异一度存活）。
    #    spec O4-F8 的论证前提逐字是「阶段 1 只写 7 个键、schema_sha256/
    #    contract_version 尚未写入」，故把阶段 2 的两个键**删掉**才是这一档的真身。
    await _in_db(base_dsn, db15,
                 "UPDATE public.pilot_meta SET value = 'initializing' WHERE key = 'state'",
                 "DELETE FROM public.pilot_meta"
                 " WHERE key IN ('schema_sha256', 'contract_version')")
    maint = await _maintenance(base_dsn, seed=seed15)
    try:
        try:
            await assert_db_allowed_for_reuse(
                maint, connect=connect_peer, db_name=db15, seed=seed15, **_REUSE_ARGS)
            check(False, "⑯ initializing 必须拒绝复用", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "db_state_initializing",
                  "⑯ initializing → db_state_initializing（**不是**指纹码）",
                  f"实得 {exc.code}")
    finally:
        await maint.close()
    # ⚠️ 原本是 ⑰ 把这个库 DROP 掉再重建的，而 ⑰ 归 S2 ——
    #    本片必须自己收尾，否则每跑一次都留下一个 state=initializing 的库。
    await harness.drop_database(base_dsn, db15)

    # ── ⑰b 健康 ready 库：整条复用闸**零异常全过** ──────────────────────
    #    ⚠️ 这一档是本脚本**唯一**断言「放行」的复用档，而它是刚性必需的：
    #       其余每一档都断言「拒了」，于是一条**恒抛**的闸在每一档看起来都在正常工作。
    #       实测坐实过 —— `_BUSINESS_STRUCTURE_SQL` 里 `array_agg(a.attname)` 出来是
    #       `name[]`、右边字面量是 `text[]`，PostgreSQL 无此操作符，该查询在**任何**库上
    #       都抛，闸 2 的业务表五组判据于是从未成功执行过一次，全兜成
    #       `target_db_unreadable`。host 层测不到（`_FakeConn` 按子串派发预置字典，
    #       SQL 文本一次都没送进 PG），只有真 PG 上一次**成功**的复用能证伪它。
    scenario("⑰b")
    print("⑰b 健康 ready 库 → 整条复用闸零异常全过（闸 2 的每条查询都真跑过）")
    db17b = await _build(base_dsn, "lifecycle_r17b", connect_peer)
    maint = await _maintenance(base_dsn, seed="lifecycle_r17b")
    try:
        try:
            await assert_db_allowed_for_reuse(
                maint, connect=connect_peer, db_name=db17b,
                seed="lifecycle_r17b", **_REUSE_ARGS)
            check(True, "⑰b 健康库复用被放行")
        except PilotDbBoundaryError as exc:
            check(False, "⑰b 健康库复用被放行", f"竟然拒了：{exc.code}：{exc}")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db17b)

    # ── ⑱⑲⑳㉑ 陈旧库四件套 fail-closed（spec §6.2 逐字）────────────────
    #    ⚠️ 四档都断言**取到的是 `structure_mismatch`**，不只是「拒了」——
    #       重叠判据下取到别的码说明闸的次序错了。
    for tag, seed, label, damage in (
        ("⑱", "lifecycle_x18", "OHLC 仍是 DECIMAL", (
            "ALTER TABLE public.klines ALTER COLUMN open  TYPE DECIMAL(10,4)",
            "ALTER TABLE public.klines ALTER COLUMN high  TYPE DECIMAL(10,4)",
            "ALTER TABLE public.klines ALTER COLUMN low   TYPE DECIMAL(10,4)",
            "ALTER TABLE public.klines ALTER COLUMN close TYPE DECIMAL(10,4)",
        )),
        ("⑲", "lifecycle_x19", "file_path 是 VARCHAR", (
            "ALTER TABLE public.training_sets ALTER COLUMN file_path TYPE VARCHAR(255)",
        )),
        ("⑳", "lifecycle_x20", "缺 uq_stock_start", (
            "ALTER TABLE public.training_sets DROP CONSTRAINT uq_stock_start",
        )),
        # ⚠️ ⑳ 单独证伪不了 `uq_stock_start_columns_ok`：约束整个没了时
        #    `uq_stock_start_present` 也为假，两条判据互相遮蔽。而 codex 4a-2a R1 加
        #    `columns_ok` 针对的正是**同名但换了列**——名字在、列错了，`present` 为真。
        #    没有这一档，把 `columns_ok` 删掉整套档位照样全绿。
        ("⑳b", "lifecycle_x20b", "uq_stock_start 同名但换了列", (
            "ALTER TABLE public.training_sets DROP CONSTRAINT uq_stock_start",
            "ALTER TABLE public.training_sets"
            " ADD CONSTRAINT uq_stock_start UNIQUE (stock_code, file_path)",
        )),
        ("㉑", "lifecycle_x21", "缺 content_hash 列", (
            "ALTER TABLE public.training_sets DROP COLUMN content_hash",
        )),
    ):
        scenario(tag)
        print(f"{tag} 陈旧库：{label}")
        dbname = await _build(base_dsn, seed, connect_peer)
        await _in_db(base_dsn, dbname, *damage)
        maint = await _maintenance(base_dsn, seed=seed)
        try:
            try:
                await assert_db_allowed_for_reuse(
                    maint, connect=connect_peer, db_name=dbname, seed=seed, **_REUSE_ARGS)
                check(False, f"{tag} 结构坏掉必须拒绝复用", "竟然放行了")
            except PilotDbBoundaryError as exc:
                check(exc.code == "structure_mismatch",
                      f"{tag} {label} → structure_mismatch",
                      f"实得 {exc.code}：{exc}")
            check(await _database_exists(maint, dbname),
                  f"{tag} 拒绝之后目标库仍然存在（DROP 从未执行）")
        finally:
            await maint.close()
        await harness.drop_database(base_dsn, dbname)

    # ══ Task 5：2a/2b 新增面（spec §6.2 写成之后由 codex 评审逼出来的判据）══
    #    这些判据在 host 假件层**零覆盖或只靠 SQL 文本守卫**，真语义只有这里能坐实。

    # ── ㉔ 活目录指纹：改一个列默认值（2a R1）──────────────────────────
    #    形状判据完全看不见它（列还在、类型没变），只有活目录指纹抓得到。
    scenario("㉔")
    print("㉔ 活目录指纹：training_sets.status 默认值被改 → business_schema_drift")
    seed24 = "lifecycle_r24"
    db24 = await _build(base_dsn, seed24, connect_peer)
    await _in_db(base_dsn, db24,
                 "ALTER TABLE public.training_sets ALTER COLUMN status SET DEFAULT 'sent'")
    maint = await _maintenance(base_dsn, seed=seed24)
    try:
        try:
            await assert_db_allowed_for_reuse(
                maint, connect=connect_peer, db_name=db24, seed=seed24, **_REUSE_ARGS)
            check(False, "㉔ 默认值漂移时复用必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "business_schema_drift",
                  "㉔ 默认值漂移 → business_schema_drift", f"实得 {exc.code}：{exc}")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db24)

    # ── 收尾 ────────────────────────────────────────────────────────────
    conn = await _connect(base_dsn)
    try:
        await _sweep_unrelated(conn)
    finally:
        await conn.close()

    missing = [t for t in _EXPECTED_SCENARIOS if t not in ran]
    if missing:
        print(f"\n❌ 这些档位**没有跑到**：{missing} —— "
              f"「静默没跑」与「通过了」在输出上完全一样，故判失败", file=sys.stderr)
        return 1
    if failures:
        print(f"\n❌ {len(failures)} 条断言不成立：{failures}", file=sys.stderr)
        return 1
    print(f"\n✅ {len(_EXPECTED_SCENARIOS)} 档断言全部成立（真 PostgreSQL）")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
