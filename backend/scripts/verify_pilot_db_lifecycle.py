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
from qmt_pilot_db import (INTENT_TTL_SECONDS, MARKER_PURPOSE,  # noqa: E402
                          PILOT_META_KEYS, PilotClusterBoundaryError,
                          PilotDbBoundaryError, assert_cluster_allowed,
                          assert_db_allowed_for_reuse, authorize_reset,
                          create_pilot_database, init_cluster_marker,
                          quote_ident, reset_pilot_database, sha256_of_sql)
# ⚠️ 私有名，**刻意**直接引用：㉚ 要断言的是「模块取了锁之后还回去了」，
#    判据必须与模块自己用来判「锁是否被持有」的那一条**逐字同源** ——
#    在脚本里另写一份等价 SQL，两份必然漂移，而漂移的方向恰好会让这一档失去判别力。
from qmt_pilot_db import (_SEED_LOCK_HELD_SQL,  # noqa: E402
                          _TARGET_CLIENT_SESSIONS_SQL)

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
    "kline_pilot_lifecycle_s15",
    "kline_pilot_lifecycle_r17b",
    "kline_pilot_lifecycle_x18",
    "kline_pilot_lifecycle_x19",
    "kline_pilot_lifecycle_x20",
    "kline_pilot_lifecycle_x20b",
    "kline_pilot_lifecycle_x21",
    # Task 5：2a/2b 新增面。⚠️ `r30` 那个库**故意从不存在**（它只作为一条指向已消失
    #    实例的孤儿 intent 行的库名），但库名字面量出现在源码里，
    #    `assert_every_selfcheck_db_is_whitelisted` 要求它照样登记。
    "kline_pilot_lifecycle_r22",
    "kline_pilot_lifecycle_r23",
    "kline_pilot_lifecycle_r24",
    "kline_pilot_lifecycle_r25",
    "kline_pilot_lifecycle_r26",
    "kline_pilot_lifecycle_r27",
    "kline_pilot_lifecycle_r28",
    "kline_pilot_lifecycle_r29",
    "kline_pilot_lifecycle_r30",
    "kline_pilot_lifecycle_r31",
    "kline_pilot_lifecycle_r32",
    "kline_pilot_lifecycle_r32b",
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
_EXPECTED_SCENARIOS = ("①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑨b", "⑨c", "⑩", "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑰b", "⑱", "⑲", "⑳", "⑳b", "㉑",
                       "㉒", "㉓", "㉔", "㉕", "㉖", "㉗", "㉘", "㉙", "㉚", "㉛", "㉜", "㉜b")


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


    # ── ⑮⑯⑰ state 流转 + initializing **两向** ──────────────────────────
    #    ⚠️ 只验 state 的流转与复用/reset 两个方向 ——
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

    scenario("⑰")
    print("⑰ 反向钉：同一个 initializing 库走 --reset → 必须 DROP + 重建")
    # spec R55-F1：--reset 时归属闸与绑定闸所需的键在阶段 1 就已写入，
    # 故它**能被正常清掉重来**。把 state 判定塞进 DROP 路径就是那个锁死。
    maint = await _maintenance(base_dsn, seed=seed15)
    try:
        try:
            await reset_pilot_database(maint, connect=connect_peer, db_name=db15,
                                       seed=seed15, **_RESET_ARGS)
        except Exception as exc:
            check(False, "⑰ initializing 的库必须能被 --reset 清掉",
                  f"竟然被拒：{type(exc).__name__}: {exc}")
        else:
            check(not await _database_exists(maint, db15),
                  "⑰ initializing 的库真的被 DROP 掉了")
    finally:
        await maint.close()
    try:
        await _build(base_dsn, seed15, connect_peer)
    except Exception as exc:
        check(False, "⑰ DROP 之后能正常重建", f"重建抛了：{type(exc).__name__}: {exc}")
    else:
        conn = await _connect(base_dsn)
        try:
            check(await _database_exists(conn, db15), "⑰ DROP 之后能正常重建")
        finally:
            await conn.close()
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

    # ── ㉒ 闸 0r 外部登记凭据：复用要，`--reset` **刻意不要**（2a R3-F1）────
    #    ⚠️ 这条不对称是 user 拍板的**有意设计**：登记表在维护库里、本工具从不清它，
    #       一旦维护库被重新初始化，非空 pilot 库就再也清不掉了（R55-F1 锁死复发）。
    #       故两个方向都要断言，只钉「复用被拒」会让实现顺手把 reset 也锁死而全绿。
    scenario("㉒")
    print("㉒ 闸 0r：删掉登记行 → 复用拒、--reset 仍放行")
    seed22 = "lifecycle_r22"
    db22 = await _build(base_dsn, seed22, connect_peer)
    maint = await _maintenance(base_dsn, seed=seed22)
    try:
        await maint.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname = $1", db22)
        try:
            await assert_db_allowed_for_reuse(
                maint, connect=connect_peer, db_name=db22, seed=seed22, **_REUSE_ARGS)
            check(False, "㉒ 无登记行时复用必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "registry_proof_missing",
                  "㉒ 无登记行 → registry_proof_missing", f"实得 {exc.code}：{exc}")
        try:
            auth = await authorize_reset(maint, connect=connect_peer, db_name=db22,
                                         seed=seed22, **_RESET_ARGS)
            check(auth.via_empty_remnant is False,
                  "㉒ **反向**：--reset 不要求登记凭据，照样放行",
                  f"via_empty_remnant={auth.via_empty_remnant}")
        except Exception as exc:
            check(False, "㉒ **反向**：--reset 不要求登记凭据，照样放行",
                  f"竟然被拒：{type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db22)

    # ── ㉓ 闸 2 活体判据：业务表上挂了触发器（2a R1）────────────────────
    #    结构判据只看「列在不在、类型对不对」，看不见一个不动任何形状、
    #    却改写每一次导入的触发器。
    scenario("㉓")
    print("㉓ 闸 2 活体：public.klines 上挂触发器 → 复用拒、--reset 放行")
    seed23 = "lifecycle_r23"
    db23 = await _build(base_dsn, seed23, connect_peer)
    await _in_db(
        base_dsn, db23,
        "CREATE FUNCTION public.zzqmtverify_tg() RETURNS trigger LANGUAGE plpgsql"
        " AS $$ BEGIN RETURN NEW; END $$",
        "CREATE TRIGGER zzqmtverify_klines_tg BEFORE INSERT ON public.klines"
        " FOR EACH ROW EXECUTE FUNCTION public.zzqmtverify_tg()")
    maint = await _maintenance(base_dsn, seed=seed23)
    try:
        try:
            await assert_db_allowed_for_reuse(
                maint, connect=connect_peer, db_name=db23, seed=seed23, **_REUSE_ARGS)
            check(False, "㉓ 业务表带触发器时复用必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "business_tables_have_dependents",
                  "㉓ 触发器 → business_tables_have_dependents", f"实得 {exc.code}：{exc}")
        try:
            await authorize_reset(maint, connect=connect_peer, db_name=db23,
                                  seed=seed23, **_RESET_ARGS)
            check(True, "㉓ **反向**：带触发器的库 --reset 仍放行（闸 2 不进 DROP 路径）")
        except Exception as exc:
            check(False, "㉓ **反向**：带触发器的库 --reset 仍放行（闸 2 不进 DROP 路径）",
                  f"竟然被拒：{type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db23)

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

    # ── ㉕ intent 新鲜度只认 `inserted_at`（2b R3-F2；**host 层零覆盖**）───
    #    造一行「`created_at` 在很远的未来、`inserted_at` 已超期」的凭据：
    #    看 `created_at` 会判成新鲜（→ 授权销毁），看 `inserted_at` 才判得出超期。
    scenario("㉕")
    print("㉕ intent 新鲜度只认 inserted_at（created_at 在未来也不算数）")
    seed25 = "lifecycle_r25"
    db25 = f"kline_pilot_{seed25}"
    maint = await _maintenance(base_dsn, seed=seed25)
    try:
        await harness.drop_database(base_dsn, db25)
        await maint.execute("CREATE DATABASE " + quote_ident(db25))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db25)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db25, seed25, "29990101T000000000000Z", f"lifecycle-{seed25}")
        # `inserted_at` 推到 TTL 之外（`created_at` 已是很远的未来）。
        await maint.execute(
            "UPDATE public.pilot_create_intent"
            "   SET inserted_at = now() - make_interval(secs => $2)"
            " WHERE dbname = $1", db25, float(INTENT_TTL_SECONDS + 3600))
        try:
            auth = await authorize_reset(maint, connect=connect_peer, db_name=db25,
                                         seed=seed25, **_RESET_ARGS)
            check(False, "㉕ 超期凭据不得授权销毁",
                  f"竟然放行了：via_empty_remnant={auth.via_empty_remnant}")
        except PilotDbBoundaryError as exc:
            # 例外不适用 → 落到闸 0−，那个空库没有 pilot_meta → not_owned
            check(exc.code == "not_owned",
                  "㉕ inserted_at 超期 → 例外不适用，落到闸 0− 判 not_owned",
                  f"实得 {exc.code}：{exc}")
        check(await _database_exists(maint, db25), "㉕ 拒绝之后那个空库仍然存在")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db25)

    # ── ㉖ 孤儿删除在**锁内当下求值**，不按快照（2b R3-F2）──────────────
    #    造一行超期孤儿，然后在**取锁的那一刻**把它刷新成新鲜 ——
    #    判据若在 SQL 里当下求值，这一行就不该被删。
    #    ⚠️ 这一档模拟的是真实竞态：同 seed 的另一次运行在预筛与取锁之间启动、
    #       刷新了自己的凭据。按快照删会把一条**新鲜的恢复凭据**删掉，
    #       留下一个零对象例外再也授权不了的空残骸。
    scenario("㉖")
    print("㉖ 孤儿删除在锁内当下求值（窗口里被刷新的行不许删）")
    seed26 = "lifecycle_r26"
    db26 = f"kline_pilot_{seed26}"
    conn = await _connect(base_dsn)
    try:
        await harness.drop_database(base_dsn, db26)
        await conn.execute("CREATE DATABASE " + quote_ident(db26))
        await conn.execute("DELETE FROM public.pilot_create_intent")
        await conn.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db26, seed26, _CREATED_AT, f"lifecycle-{seed26}")
        await conn.execute(
            "UPDATE public.pilot_create_intent"
            "   SET inserted_at = now() - make_interval(secs => $2)"
            " WHERE dbname = $1", db26, float(INTENT_TTL_SECONDS + 3600))

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
            return True

        async def _noop_release(_seed):
            return None

        cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8")
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_refresh_then_lock,
                                      release_seed_lock=_noop_release)
        except Exception as exc:
            check(False, "㉖ init 本身必须跑完", f"抛了：{type(exc).__name__}: {exc}")
        # ⚠️ **先断言注入真的发生了**：没触发的话下面那条「行还在」是恒真的，
        #    这一档就成了空转（本仓栽过十二次的形态）。
        check(refreshed == [seed26],
              "㉖ 前置：清理确实走到了取锁那一步（注入点被调用）",
              f"try_seed_lock 收到的 seed 列表 = {refreshed}")
        still = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db26)
        check(still == 1, "㉖ 窗口里被刷新的凭据**没有**被删（判据在锁内当下求值）",
              f"该行事后剩 {still} 条")
        await conn.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db26)
    finally:
        await conn.close()
    await harness.drop_database(base_dsn, db26)

    # ── ㉗ DROP 成功之后必须清掉那条凭据（2b R4-F1）────────────────────
    #    不清的话：那一行仍新鲜且已确认、只是指向一个已消失的实例，
    #    而重建用的是**新的 run_id** → 接管条件不成立 → `intent_row_conflict`，
    #    于是 `--reset` 把库删掉了却重建不了。
    scenario("㉗")
    print("㉗ reset 之后凭据被清掉，且能用**新 run_id** 立刻重建")
    seed27 = "lifecycle_r27"
    db27 = f"kline_pilot_{seed27}"
    maint = await _maintenance(base_dsn, seed=seed27)
    try:
        # ⚠️ **夹具不能用 `_build`**：`create_pilot_database` 跑成功时自己就把 intent 行
        #    清掉了（`_CLEAR_INTENT_SQL`），于是「事后 0 条」恒真、这一档整个是空的
        #    （本轮变异当场抓到：把 DROP 后的清理整条删掉，㉗ 照样绿）。
        #    R4-F1 要防的是**零对象例外那条路**：崩在写 pilot_meta 之前的残骸，
        #    它那行凭据仍然新鲜且已确认，只有 DROP 之后的清理能收掉。
        await harness.drop_database(base_dsn, db27)
        await maint.execute("CREATE DATABASE " + quote_ident(db27))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db27)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db27, seed27, _CREATED_AT, f"lifecycle-{seed27}")
        check(1 == await maint.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db27),
            "㉗ 前置：残骸的 intent 凭据已就位")
        try:
            await reset_pilot_database(maint, connect=connect_peer, db_name=db27,
                                       seed=seed27, **_RESET_ARGS)
        except Exception as exc:
            check(False, "㉗ 前置：reset 必须成功", f"抛了：{type(exc).__name__}: {exc}")
        left = await maint.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db27)
        check(left == 0, "㉗ DROP 之后那条 intent 凭据被清掉了", f"事后仍有 {left} 条")
        # ⚠️ **必须换 run_id**：沿用同一个 run_id 时接管条件本来就成立，
        #    这一档会变成恒真。
        try:
            await create_pilot_database(maint, connect=connect_peer, db_name=db27,
                                        seed=seed27, run_id=f"lifecycle-{seed27}-again",
                                        **_BUILD_ARGS)
            check(True, "㉗ 紧接着用**新 run_id** 重建成功（没被陈旧凭据卡住）")
        except Exception as exc:
            check(False, "㉗ 紧接着用**新 run_id** 重建成功（没被陈旧凭据卡住）",
                  f"重建抛了：{type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db27)

    # ── ㉘ 零对象例外的【绝对空】复查必须**紧贴 DROP**（2b R2-F1）────────
    #    授权理由就是「这个库当时是空的」，而那是一个**会过期的事实**。
    #    这里在 DROP 前的那次复查连进目标库**之前**往库里建一张表，
    #    模拟 `pg_restore --create` 或人工建表挤进那个窗口。
    scenario("㉘")
    print("㉘ 授权之后、DROP 之前库变得不空 → 必须拒绝 DROP")
    seed28 = "lifecycle_r28"
    db28 = f"kline_pilot_{seed28}"
    # ⚠️ 只数**连向目标库**的连接：集群闸 (ii) 会跳过目标库，故连它的只有
    #    `_probe_absolutely_empty` —— 授权里两次（初判 + 紧贴复查），
    #    `_drop_pilot_database` 里第三次。第 3 次就是 DROP 前的那一次。
    probe_calls = {"n": 0}
    injected: list[int] = []

    async def _connect_with_injection(name: str):
        if name == db28:
            probe_calls["n"] += 1
            if probe_calls["n"] == 3:
                await _in_db(base_dsn, db28,
                             "CREATE TABLE public.zzqmtverify_squatter (id int)")
                injected.append(probe_calls["n"])
        return await connect_peer(name)

    maint = await _maintenance(base_dsn, seed=seed28)
    try:
        await harness.drop_database(base_dsn, db28)
        await maint.execute("CREATE DATABASE " + quote_ident(db28))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db28)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db28, seed28, _CREATED_AT, f"lifecycle-{seed28}")
        try:
            await reset_pilot_database(maint, connect=_connect_with_injection,
                                       db_name=db28, seed=seed28, **_RESET_ARGS)
            check(False, "㉘ 窗口里变得不空的库必须拒绝 DROP", "竟然删掉了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned",
                  "㉘ 窗口里变得不空 → 拒绝 DROP（not_owned）", f"实得 {exc.code}：{exc}")
        # 同 ㉖：先证明注入真的插进了那个窗口，否则下面两条是恒真的。
        check(injected == [3],
              "㉘ 前置：建表确实插在 DROP 前那次复查之前",
              f"连向目标库的次数 = {probe_calls['n']}，注入点 = {injected}")
        check(await _database_exists(maint, db28), "㉘ 拒绝之后目标库仍然存在")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db28)

    # ── ㉙ init 每次都要**现查**，标记不得短路（2b R3-F1）────────────────
    #    「标记证明的是**有人曾声明过**，只有现查才证明**现在仍然成立**」——
    #    两条现实路径：当初为空的集群后来被拿去装了真实数据库；
    #    标记随 pg_dump / 卷拷贝被还原到另一个集群。
    scenario("㉙")
    print("㉙ 带合法标记的集群上事后出现无关库 → init 仍须拒")
    conn = await _connect(base_dsn)
    try:
        await conn.execute("CREATE DATABASE " + quote_ident(_UNRELATED_DB))

        async def _never2(_seed):
            return False

        async def _noop2(_seed):
            return None

        cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8")
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_never2, release_seed_lock=_noop2)
            check(False, "㉙ 集群含无关库时 init 必须拒（标记不能短路现查）", "竟然成功了")
        except PilotClusterBoundaryError as exc:
            check(exc.code == "unrelated_database",
                  "㉙ 有合法标记但集群变脏 → unrelated_database", f"实得 {exc.code}：{exc}")
        await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(_UNRELATED_DB))
    finally:
        await conn.close()

    # ── ㉚ 孤儿清理**取了锁就必须还**（2b R5-F2）────────────────────────
    #    会话级锁不还会一直挂在维护连接上，挡住后续同 seed 的运行，
    #    也让同一条连接上后来的「锁是否被持有」观察到一把本次从未刻意取过的锁。
    #    ⚠️ 判据**不能**写成「同一条连接还能再取到这把锁」—— advisory lock 在同一
    #       session 内可重入，那样写恒真。这里直接问模块自己的「锁是否被持有」。
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
        check(gone == 0, "㉚ 前置：孤儿行确实被清掉了（清理路径真的跑到了 DELETE）",
              f"事后仍有 {gone} 条")
        check(not await conn.fetchval(_SEED_LOCK_HELD_SQL, seed30),
              "㉚ init 返回后维护连接上**不再持有**那把 seed 锁")
        await conn.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db30)
    finally:
        await conn.close()

    # ── ㉛ 【绝对空】必须看见物化视图（spec §9-1a2）────────────────────
    #    物化视图**存着真数据**，而按 information_schema 或只数普通表的实现看不见它。
    scenario("㉛")
    print("㉛ 只含物化视图（1000 行真数据）的同名库 → --reset 必须拒")
    seed31 = "lifecycle_r31"
    db31 = f"kline_pilot_{seed31}"
    maint = await _maintenance(base_dsn, seed=seed31)
    try:
        await harness.drop_database(base_dsn, db31)
        await maint.execute("CREATE DATABASE " + quote_ident(db31))
        await _in_db(base_dsn, db31,
                     "CREATE MATERIALIZED VIEW public.zzqmtverify_mv AS"
                     " SELECT g AS n FROM generate_series(1, 1000) g")
        # ⚠️ 连接必须关掉：目标库上留一条会话，随后的 DROP 会撞
        #    `is being accessed by other users`，而顶住它的正是本脚本自己。
        probe31 = await asyncpg.connect(harness.db_dsn(base_dsn, db31))
        try:
            rows31 = await probe31.fetchval("SELECT count(*) FROM public.zzqmtverify_mv")
        finally:
            await probe31.close()
        check(rows31 == 1000, "㉛ 前置：物化视图里确实有 1000 行真数据",
              f"实得 {rows31} 行")
        # 已确认、绑对实例、新鲜的凭据 —— 六条里只剩【绝对空】那一条不成立。
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db31)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db31, seed31, _CREATED_AT, f"lifecycle-{seed31}")
        try:
            auth = await authorize_reset(maint, connect=connect_peer, db_name=db31,
                                         seed=seed31, **_RESET_ARGS)
            check(False, "㉛ 含物化视图的库不得走零对象例外",
                  f"竟然放行了：via_empty_remnant={auth.via_empty_remnant}")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned",
                  "㉛ 物化视图算「非空」→ 例外不适用，落到闸 0− 判 not_owned",
                  f"实得 {exc.code}：{exc}")
        check(await _database_exists(maint, db31), "㉛ 拒绝之后目标库仍然存在")
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db31)
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db31)

    # ── ㉜ 集群闸遍历过目标库之后**立刻** DROP 必须成功（spec §4 规定 4）──
    #    集群闸 (ii) 与闸 0−/0/0b 都会连进目标库（它自己就匹配 kline_pilot_*）。
    #    只要有一条连接活着，随后的 DROP 就会撞 `is being accessed by other users`——
    #    而 reset 是陈旧 schema 库的唯一出路。这一档钉的是「读一律短连接」真做到了。
    #
    #    ⚠️ **变异验证的如实结论（别当成「这一档管着 _close_quietly」）**：
    #       · 把闸 (ii) 的 `await _close_quietly(other, name)` 换成 `pass` —— **变异存活**。
    #         CPython 的引用计数会在 `other` 出作用域时立刻回收并断开，
    #         「忘了关」在这个解释器上根本产生不出滞留会话。
    #       · 换成「不关且**持住引用**」—— 滞留会话真的出现了，但它在 **④ 的清场**
    #         （本脚本第一次 DROP）就抛 ObjectInUseError 把脚本打死，远早于本档。
    #         凡是走 reset 的档（⑨⑬⑰㉗㉘…）都排在本档之前，
    #         故**按构造本档不可能是第一个观测点**。
    #       结论：该性质确实被套件捕获，只是首个观测点不是这里。本档的独立价值是
    #       **正向钉**——防「实现为了省事把 reset 一律拒掉」那一类回归（与 ⑨/⑰ 同族）。
    #       **不为它编一个够得到的变异**：编出来的只会是假覆盖。
    scenario("㉜")
    print("㉜ 集群闸读过目标库之后立刻 --reset → 必须成功 DROP + 重建")
    seed32 = "lifecycle_r32"
    db32 = await _build(base_dsn, seed32, connect_peer)
    maint = await _maintenance(base_dsn, seed=seed32)
    try:
        # 先让集群闸真的连进目标库读一遍（target_db 传 None，目标库不被跳过）。
        try:
            await assert_cluster_allowed(maint, connect=connect_peer, target_db=None)
            check(True, "㉜ 前置：集群闸把目标库当同侪库读过一遍")
        except Exception as exc:
            check(False, "㉜ 前置：集群闸把目标库当同侪库读过一遍",
                  f"集群闸抛了：{type(exc).__name__}: {exc}")
        try:
            await reset_pilot_database(maint, connect=connect_peer, db_name=db32,
                                       seed=seed32, **_RESET_ARGS)
        except Exception as exc:
            # ⚠️ 占用者只报 pid/usename 时没法判断该拿它怎么办。把 `backend_type` 一起打出来：
            #    `client backend` = 真有人连着（本脚本或别人）；
            #    `autovacuum worker` 之类 = 非客户端后端，操作者根本「让它自行退出」不了。
            who = [dict(r) for r in await maint.fetch(
                "SELECT pid, usename, application_name, backend_type, state"
                "  FROM pg_stat_activity WHERE datname = $1", db32)]
            check(False, "㉜ 紧接着的 DROP 必须成功（没有被自己的连接顶住）",
                  f"reset 抛了：{type(exc).__name__}: {exc}；此刻占用者={who}")
        else:
            check(not await _database_exists(maint, db32),
                  "㉜ 紧接着的 DROP 必须成功（没有被自己的连接顶住）")
    finally:
        await maint.close()
    try:
        await _build(base_dsn, seed32, connect_peer)
    except Exception as exc:
        check(False, "㉜ DROP 之后能正常重建", f"重建抛了：{type(exc).__name__}: {exc}")
    else:
        conn = await _connect(base_dsn)
        try:
            check(await _database_exists(conn, db32), "㉜ DROP 之后能正常重建")
        finally:
            await conn.close()
    await harness.drop_database(base_dsn, db32)

    # ── ㉜b **反向**：目标库上有真客户端连接时，DROP 预检必须触发 ──────────
    #    ⚠️ 这一档存在的唯一理由是「防止 ㉜ 那条修复收窄过头」：
    #       预检从「数 pg_stat_activity 全部行」收窄成「只数 backend_type =
    #       'client backend'」之后，一个写错的过滤条件会让它**永不触发** ——
    #       而它是 DROP 之前唯一一道「别人还连着」的早失败闸。
    #    ⚠️ 「不数 autovacuum worker」那一向**没有常驻档**：逼出一个 autovacuum worker
    #       要改集群的 autovacuum_naptime（ALTER SYSTEM，持久且全局），
    #       对一个验收脚本太侵入。该向由一次性真 PG 实验坐实并记进计划，如实登记。
    scenario("㉜b")
    print("㉜b 目标库上有真客户端连接 → reset 预检必须报 target_db_in_use")
    seed32b = "lifecycle_r32b"
    db32b = await _build(base_dsn, seed32b, connect_peer)
    squatter = await asyncpg.connect(harness.db_dsn(base_dsn, db32b))
    maint = await _maintenance(base_dsn, seed=seed32b)
    try:
        # ⚠️ 断言的是**模块自己那条预检谓词**，不是脚本另写的等价查询 ——
        #    过滤条件写错（收窄过头）时只有前者会变。
        seen = await maint.fetch(_TARGET_CLIENT_SESSIONS_SQL, db32b)
        check(len(seen) == 1,
              "㉜b 前置：**模块的预检谓词**确实看得见那条客户端会话（没收窄过头）",
              f"实得 {[dict(r) for r in seen]}")
        try:
            await reset_pilot_database(maint, connect=connect_peer, db_name=db32b,
                                       seed=seed32b, **_RESET_ARGS)
            check(False, "㉜b 有客户端连接时必须拒绝 DROP", "竟然删掉了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "target_db_in_use",
                  "㉜b 有客户端连接 → target_db_in_use", f"实得 {exc.code}：{exc}")
        check(await _database_exists(maint, db32b), "㉜b 拒绝之后目标库仍然存在")
    finally:
        await squatter.close()
        await maint.close()
    await harness.drop_database(base_dsn, db32b)

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
