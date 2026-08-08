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
    P2=$(docker inspect qmt-pg-r8b --format '{{range .Config.Env}}{{println .}}{{end}}' \\
         | grep POSTGRES_PASSWORD | cut -d= -f2)
    DSN="postgresql://postgres:${P1}@localhost:55444/postgres" \\
    DSN2="postgresql://postgres:${P2}@localhost:55445/postgres" \\
      .venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py; echo "EXIT=$?"

⚠️ **DSN2 必填，缺了直接判失败** —— spec §9 明写「跳过被当成通过」是本仓栽过的坑。
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
from qmt_pilot_db import (MARKER_PURPOSE, PilotClusterBoundaryError,  # noqa: E402
                          PilotDbBoundaryError, assert_cluster_allowed,
                          assert_db_allowed_for_reuse, authorize_reset,
                          create_pilot_database, init_cluster_marker,
                          quote_ident, sha256_of_sql)

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
    "kline_pilot_lifecycle_c4",
    "kline_pilot_lifecycle_g6",
    "kline_pilot_lifecycle_g7",
    "kline_pilot_lifecycle_g8",
    "kline_pilot_lifecycle_g9",
    "kline_pilot_lifecycle_g9b",
    "kline_pilot_lifecycle_g9c",
    "kline_pilot_lifecycle_t10",
    "kline_pilot_lifecycle_t11",
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
_EXPECTED_SCENARIOS = ("①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑨b", "⑨c", "⑩", "⑪", "⑫", "⑬", "⑭")


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
    dsn2 = os.environ.get("DSN2")
    if not base_dsn:
        print("用法：DSN='postgresql://user:pw@host:port/postgres' "
              "DSN2='…' python backend/scripts/verify_pilot_db_lifecycle.py",
              file=sys.stderr)
        return 2
    if not dsn2:
        # ⚠️ **绝不「跳过」**（spec §9）：一档静默没跑，与它通过了，在输出上完全一样。
        print("拒绝运行：DSN2 未设置。本脚本的跨集群档位需要第二个 PostgreSQL；"
              "缺它一律判失败，不接受跳过。", file=sys.stderr)
        return 2

    # 破坏性闸**必须先于对该 DSN 的任何 connect/DDL**。
    if harness.assert_destructive_dsn_allowed(base_dsn, "DSN") is None:
        return 3
    if harness.assert_destructive_dsn_allowed(dsn2, "DSN2") is None:
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

    # ── ⑤ 同场景下 `--init-cluster-marker` 也须拒，**且零 DDL** ──────────
    #    ⚠️ 第二条断言是 codex 4a-2b R5-F1/R8-F1 那一族的钉子：
    #       副作用必须排在证明之后 —— 拒绝的集群里不该多出任何维护表。
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
            # ⚠️ **带 --reset 也必须拒**（spec R80-F1）：DROP 路径根本不跑闸 2，
            #    把 pilot_meta 的断言只放进闸 2 会让最危险的那条路径原封不动。
            try:
                await authorize_reset(maint, connect=connect_peer, db_name=dbname,
                                      seed=seed, **_RESET_ARGS)
                check(False, f"{tag} --reset 也必须被闸 0− 拒", "竟然放行了")
            except PilotDbBoundaryError as exc:
                check(exc.code == "pilot_meta_ambiguous",
                      f"{tag} --reset → pilot_meta_ambiguous", f"实得 {exc.code}")
            check(await _database_exists(maint, dbname),
                  f"{tag} 拒绝之后目标库仍然存在")
        finally:
            await maint.close()
        await harness.drop_database(base_dsn, dbname)

    # ── ⑨ 反向钉：零对象空残骸 + --reset → **必须正常 DROP 重建** ─────────
    #    spec O4-F6 明写：写成「闸 0− 四库、--reset 也拒」就是把 R55-F1 的锁死钉进 L2 门。
    #    残骸的形态 = 崩在 `CREATE DATABASE` 与写 `pilot_meta` 之间：
    #    库是空的、没有 pilot_meta，但维护库里留着一行**已确认且绑到该实例**的 intent。
    scenario("⑨")
    print("⑨ 反向钉：零对象空残骸必须能被 --reset 清掉重建")
    seed9 = "lifecycle_g9"
    db9 = f"kline_pilot_{seed9}"
    maint = await _maintenance(base_dsn, seed=seed9)
    try:
        await harness.drop_database(base_dsn, db9)
        await maint.execute("CREATE DATABASE " + quote_ident(db9))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db9)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db9, seed9, _CREATED_AT, f"lifecycle-{seed9}")
        check(await _database_exists(maint, db9), "⑨ 前置：空残骸已就位")

        # ⚠️ **必须包 try**：裸调时授权一旦抛异常会直接把脚本打死 ——
        #    那样这一档**产不出 FAIL 行**，变异跑器只看到「脚本挂了」而不是「⑨ 红了」，
        #    等于这一档零判别力（本轮变异当场抓到）。
        try:
            auth = await authorize_reset(maint, connect=connect_peer, db_name=db9,
                                         seed=seed9, **_RESET_ARGS)
            check(auth.via_empty_remnant is True,
                  "⑨ 授权来自**零对象例外**（不是闸 0−/0/0b）",
                  f"via_empty_remnant={auth.via_empty_remnant}")
        except Exception as exc:
            check(False, "⑨ 授权来自**零对象例外**（不是闸 0−/0/0b）",
                  f"空残骸的 --reset 被拒了：{type(exc).__name__}: {exc}")
    finally:
        await maint.close()

    # 真的把它 DROP 掉并重建 —— 「声称的恢复能力必须逐条验到 DROP 真的能执行为止」
    maint = await _maintenance(base_dsn, seed=seed9)
    try:
        from qmt_pilot_db import reset_pilot_database
        try:
            await reset_pilot_database(maint, connect=connect_peer, db_name=db9,
                                       seed=seed9, **_RESET_ARGS)
        except Exception as exc:
            check(False, "⑨ 空残骸真的被 DROP 掉了",
                  f"reset 抛了：{type(exc).__name__}: {exc}")
        else:
            check(not await _database_exists(maint, db9), "⑨ 空残骸真的被 DROP 掉了")
    finally:
        await maint.close()
    try:
        rebuilt = await _build(base_dsn, seed9, connect_peer)
    except Exception as exc:
        check(False, "⑨ DROP 之后能正常重建", f"重建抛了：{type(exc).__name__}: {exc}")
    else:
        conn = await _connect(base_dsn)
        try:
            check(await _database_exists(conn, rebuilt), "⑨ DROP 之后能正常重建")
        finally:
            await conn.close()
    await harness.drop_database(base_dsn, db9)


    # ── ⑨b **未确认**的 intent 行不许授权销毁（spec O4-R8-C2）───────────────
    #    intent 行写在 `CREATE DATABASE` **之前**，未确认的行证明不了「这个库是本次建的」。
    #    拿它当授权，会去 DROP **别人建的**同名空库 —— 无 pilot_meta 归属、无令牌。
    #    ⚠️ 这一档是 ⑨ 的**判别力补丁**：⑨ 的 fixture 把 create_confirmed 设成 true，
    #       所以中和那条判据时 ⑨ 照样绿（本轮变异当场抓到）。
    scenario("⑨b")
    print("⑨b 未确认的 intent 行不得授权销毁")
    seed9b = "lifecycle_g9b"
    db9b = f"kline_pilot_{seed9b}"
    maint = await _maintenance(base_dsn, seed=seed9b)
    try:
        await harness.drop_database(base_dsn, db9b)
        await maint.execute("CREATE DATABASE " + quote_ident(db9b))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db9b)
        # 与 ⑨ 唯一的差别：create_confirmed = **false**
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, false, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db9b, seed9b, _CREATED_AT, f"lifecycle-{seed9b}")
        try:
            auth = await authorize_reset(maint, connect=connect_peer, db_name=db9b,
                                         seed=seed9b, **_RESET_ARGS)
            check(False, "⑨b 未确认的 intent 行不得授权销毁",
                  f"竟然放行了：via_empty_remnant={auth.via_empty_remnant}")
        except PilotDbBoundaryError as exc:
            # 落到闸 0−：那个库没有 pilot_meta → not_owned（「不是本工具建的，请人工删」）
            check(exc.code == "not_owned",
                  "⑨b 未确认的 intent 行 → 例外不适用，落到闸 0− 判 not_owned",
                  f"实得 {exc.code}")
        check(await _database_exists(maint, db9b), "⑨b 拒绝之后那个空库仍然存在")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db9b)


    # ── ⑨c 凭据**绑到另一个实例**时例外不适用（spec O4-R21-C1 / R25-C1）──────
    #    「原库被删掉、别人用同名重建」这一档：陈旧的 create_confirmed=true 会为那个
    #    **全新的、不是我们建的**库背书 —— 而这一行是 DROP 授权。
    #    ⚠️ 这一档是 ⑨/⑨b 的**判别力补丁**：它们的 fixture 总把 db_oid 设对，
    #       所以中和绑定判据时两档照样绿（本轮变异当场抓到）。
    scenario("⑨c")
    print("⑨c 凭据绑到另一个实例时例外不适用")
    seed9c = "lifecycle_g9c"
    db9c = f"kline_pilot_{seed9c}"
    maint = await _maintenance(base_dsn, seed=seed9c)
    try:
        await harness.drop_database(base_dsn, db9c)
        await maint.execute("CREATE DATABASE " + quote_ident(db9c))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db9c)
        # 已确认、但 db_oid 指向**另一个**实例（拿 template1 的 oid 当陈旧绑定）
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = 'template1'",
            db9c, seed9c, _CREATED_AT, f"lifecycle-{seed9c}")
        try:
            auth = await authorize_reset(maint, connect=connect_peer, db_name=db9c,
                                         seed=seed9c, **_RESET_ARGS)
            check(False, "⑨c 绑到别的实例的凭据不得授权销毁",
                  f"竟然放行了：via_empty_remnant={auth.via_empty_remnant}")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned",
                  "⑨c 陈旧实例绑定 → 例外不适用，落到闸 0− 判 not_owned",
                  f"实得 {exc.code}")
        check(await _database_exists(maint, db9c), "⑨c 拒绝之后那个空库仍然存在")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db9c)


    # ── ⑩ 归属闸的破坏性分支：真验「目标库事后仍然存在」──────────────────
    #    归属不过时**不给令牌**（spec R3-F1）：令牌只解「同 seed 但绑定不同」那一档。
    #    归属不符意味着这个库根本不是本工具建的，唯一出路是人工删 ——
    #    在错误提示里给出令牌，等于把「换个参数就能删掉别人的库」写进指引。
    scenario("⑩")
    print("⑩ 归属闸的破坏性分支")
    seed10 = "lifecycle_t10"
    db10 = await _build(base_dsn, seed10, connect_peer)
    await _in_db(base_dsn, db10,
                 "UPDATE public.pilot_meta SET value = 'someone_else' WHERE key = 'seed'")
    maint = await _maintenance(base_dsn, seed=seed10)
    try:
        try:
            await authorize_reset(maint, connect=connect_peer, db_name=db10,
                                  seed=seed10, **_RESET_ARGS)
            check(False, "⑩ 归属不符时 --reset 必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned", "⑩ 归属不符 → not_owned", f"实得 {exc.code}")
            check(exc.confirm_token is None,
                  "⑩ 归属不过时**不给令牌**（令牌只解「同 seed 但绑定不同」）",
                  f"竟然给了 {exc.confirm_token!r}")
        check(await _database_exists(maint, db10), "⑩ 拒绝之后目标库仍然存在")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db10)

    # ── ⑪⑫⑬⑭ --reset-foreign 三跑 + 令牌不得进 message ────────────────
    #    ⚠️ ⑬ 是**唯一能证明令牌真的解锁了 DROP** 的一档：
    #       少了它，实现可以「一律拒」而 ⑪⑫ 全绿。
    seed11 = "lifecycle_t11"
    db11 = await _build(base_dsn, seed11, connect_peer)
    # ⚠️ 故意带**尾斜杠**：`derive_confirm_token` 的 preimage 规定用「不带尾斜杠的
    #    output_dir」，而建库时存进去的本来就已经 rstrip 过 —— 不造一个带斜杠的值，
    #    那条 `.rstrip('/')` 判据就**观察不到**（本轮变异当场抓到：去掉它一档都不红）。
    await _in_db(base_dsn, db11,
                 "UPDATE public.pilot_meta SET value = '/someone_else/' "
                 "WHERE key = 'output_dir'")
    # 令牌由**库自身的身份**派生（spec R34-F1）——从库里读回三元组自己算一遍。
    # ⚠️ **必须用 spec 的字面公式独立算，绝不能调 `derive_confirm_token`**：
    #    拿被测函数自己算期望值，改它的时候脚本与模块**一起改**、两边永远相等 ——
    #    这一档就退化成「模块和脚本一致」，而不是「令牌符合 spec」。
    #    （本轮变异当场抓到：把 preimage 顺序调换之后**一档都不红**。）
    #    spec §4 逐字：confirm_token = sha256(export_log_sha256|output_dir|created_at)[:12]
    peer = await asyncpg.connect(harness.db_dsn(base_dsn, db11))
    try:
        meta11 = {r["key"]: r["value"] for r in
                  await peer.fetch("SELECT key, value FROM public.pilot_meta")}
    finally:
        await peer.close()
    right_token = hashlib.sha256(
        f"{meta11['export_log_sha256']}|{meta11['output_dir'].rstrip('/')}"
        f"|{meta11['created_at']}".encode("utf-8")).hexdigest()[:12]
    leaked: list[str] = []

    scenario("⑪")
    print("⑪ 绑定不符、不带令牌")
    maint = await _maintenance(base_dsn, seed=seed11)
    try:
        try:
            await authorize_reset(maint, connect=connect_peer, db_name=db11,
                                  seed=seed11, **_RESET_ARGS)
            check(False, "⑪ 绑定不符且无令牌 → 必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "reset_foreign_token_required",
                  "⑪ 绑定不符 → reset_foreign_token_required", f"实得 {exc.code}")
            check(exc.confirm_token == right_token,
                  "⑪ 令牌经**专用通道**给出且与库身份派生的一致",
                  f"实得 {exc.confirm_token!r}")
            leaked.append(str(exc))
        check(await _database_exists(maint, db11), "⑪ 拒绝之后目标库仍然存在")
    finally:
        await maint.close()

    scenario("⑫")
    print("⑫ 绑定不符、带错令牌")
    maint = await _maintenance(base_dsn, seed=seed11)
    try:
        try:
            await authorize_reset(maint, connect=connect_peer, db_name=db11,
                                  seed=seed11, **{**_RESET_ARGS,
                                                  "reset_foreign_token": "deadbeefcafe"})
            check(False, "⑫ 错令牌 → 必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "reset_foreign_token_invalid",
                  "⑫ 错令牌 → reset_foreign_token_invalid", f"实得 {exc.code}")
            leaked.append(str(exc))
        check(await _database_exists(maint, db11), "⑫ 拒绝之后目标库仍然存在")
    finally:
        await maint.close()

    scenario("⑭")
    print("⑭ 令牌不得出现在异常 message 里")
    # spec §9-1w：令牌只走 `confirm_token`。写进 message 之后，任何把 `str(exc)`
    # 序列化进报告的调用方都会漏 —— wrapper 就能「读报告取令牌再重跑」，
    # 「知情同意」退化成两步自动化。
    check(bool(leaked) and all(right_token not in m for m in leaked),
          "⑭ ⑪⑫ 两档的 message 都不含令牌",
          f"令牌 {right_token!r} 漏进了：{[m for m in leaked if right_token in m]}")

    scenario("⑬")
    print("⑬ 带**正确**令牌 → 必须真的 DROP 掉")
    from qmt_pilot_db import reset_pilot_database
    maint = await _maintenance(base_dsn, seed=seed11)
    try:
        try:
            await reset_pilot_database(maint, connect=connect_peer, db_name=db11,
                                       seed=seed11,
                                       **{**_RESET_ARGS,
                                          "reset_foreign_token": right_token})
        except Exception as exc:
            check(False, "⑬ 正确令牌必须解锁 DROP",
                  f"竟然被拒：{type(exc).__name__}: {exc}")
        else:
            check(not await _database_exists(maint, db11),
                  "⑬ 正确令牌 → 目标库真的被 DROP 掉了")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db11)

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
