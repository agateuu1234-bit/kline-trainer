#!/usr/bin/env python3
"""验证 4a-2 的库级闸与破坏性路径在真 PostgreSQL 上真的成立（**S2 切片**）。

⛔ **本脚本仍不是 spec §6.2 生命周期那一组的 ship gate**
   （codex 4a-2b/S1 R5-F2）：下面「本脚本管」那张分工表写的是**这个文件最终**要
   覆盖的范围，而 S2 这一片仍缺**集群标记初始化与孤儿清理**那一组。
   ⚠️ 这与 R1/R3 在并发脚本上栽过的是同一条：全绿摘要照样打印，读的人会把它
      当成整组生命周期验收已过 —— 而 `--init-cluster-marker` 此刻一档都没跑。

   **此刻不跑**（随 S3 补回，见
   `docs/superpowers/plans/2026-08-10-qmt-plan4a-2b-repackaging.md` Task 3）：
     · `init_cluster_marker` 的幂等语义与「副作用排在证明之后」
     · 孤儿 intent 行的清理（含取锁必须还、判据必须在锁内当下求值）
   **此刻跑**：集群闸 / 复用闸 / 绑定闸 / 陈旧库 / 业务表结构漂移 /
   零对象例外与 `--reset-foreign` 的**授权判定**（只到「授权发得出来」为止）/
   清场护栏自身的三档回归（㉕㉖㉗）。
   ⛔ **此刻不跑**：DROP 的执行本身、DROP 前的封锁与紧贴复查、占用者检查、
   DROP 后的凭据清理 —— 本片模块里根本没有 `_drop_pilot_database`。随 S2b 补回。

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
    QMT_VERIFY_ALLOW_DESTRUCTIVE=1 \\
    DSN="postgresql://postgres:${P1}@localhost:55444/postgres" \\
      .venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py; echo "EXIT=$?"

⚠️ **每一次运行都要 `QMT_VERIFY_ALLOW_DESTRUCTIVE=1`**（codex R7-F1）——「本地」不是
   「可弃」：这个变量是操作者对「这个集群整个可以被毁掉」的明示。指向非本地集群
   还要**另外**设 `QMT_VERIFY_ALLOW_REMOTE=1`。

⚠️ **本脚本只要 DSN**：它没有跨集群档，要求 DSN2 会让人以为跨集群被覆盖了。
   跨集群那条（advisory lock 是每集群的）在 `verify_pilot_concurrency.py` 的 Ⓐb。
⚠️ **判绿读输出内容，不要看管道后的 exit code**（`cmd | tail` 之后 `$?` 是 tail 的）。

退出码：0=全绿 / 1=有档没跑或有 FAIL / 2=用法 / 3=DSN 未过破坏性闸 /
4=残留库不在白名单 / 5=库名没登记 / 6=临时对象名没带前缀 / 7=DSN 环境变量没过闸 /
8=同集群上已有另一个同前缀的验收在跑。
"""
from __future__ import annotations

import asyncio
import hashlib
import os
import pathlib
import re
import sys
import uuid

import asyncpg

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import _pilot_verify_harness as harness  # noqa: E402
from qmt_pilot_db import (INTENT_TTL_SECONDS, MARKER_PURPOSE,  # noqa: E402
                          PILOT_META_KEYS, PilotClusterBoundaryError,
                          PilotDbBoundaryError, assert_cluster_allowed,
                          assert_db_allowed_for_reuse, authorize_reset,
                          create_pilot_database, quote_ident, sha256_of_sql)
# ⚠️ 本片（S2a）**零破坏性能力**：`reset_pilot_database` / `_TARGET_CLIENT_SESSIONS_SQL`
#    连同整个 `_drop_pilot_database` 都在 S2b，模块里根本没有这些符号。
#    引用它们会让本脚本在任何档位跑起来之前就 ImportError（codex S2a-plan-R1 实测）。
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
    "kline_pilot_lifecycle_r17b",
    "kline_pilot_lifecycle_r22",
    "kline_pilot_lifecycle_r23",
    "kline_pilot_lifecycle_r24",
    "kline_pilot_lifecycle_r28",
    "kline_pilot_lifecycle_r31",
    "kline_pilot_lifecycle_r32",
    "kline_pilot_lifecycle_r32b",
    "kline_pilot_lifecycle_r33",
    "kline_pilot_lifecycle_r34",
    "kline_pilot_lifecycle_r34b",
    "kline_pilot_lifecycle_r35",
    "kline_pilot_lifecycle_s15",
    "kline_pilot_lifecycle_t10",
    "kline_pilot_lifecycle_t11",
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
# ⚠️ 它不匹配 `_PREFIX`，故**不进** `_LIFECYCLE_DBS`（那张表是「同前缀库」的白名单）。
_UNRELATED_DB = "zzqmtverify_unrelated"

# ㉕ 的诱饵库：**匹配 `LIKE 'kline_pilot_lifecycle_%'`，却不以该前缀开头**
# （`_` 是 LIKE 的单字符通配符，这里每个 `_` 位置都换成了 `0`）。
# ⚠️ 它的归属标记 `zzqmtverify` 只能长在**中间** —— 放开头就不再匹配那条通配符模式，
#    这一档也就测不到 R4-F1 了。
_LIKE_DECOY_DB = "kline0pilot0lifecycle0zzqmtverify0decoy"

# 本脚本可能 DROP 的**不带 pilot 前缀**的库。它们在 `sweep_leftover_databases` 的
# 白名单机制之外，故单独登记 + 单独 fail-closed。
# ⚠️ **这是一条真栽过的**（codex 4a-2b/S1 R2-F1，high，实测复现）：
#    前置清场原本无条件 `DROP DATABASE IF EXISTS zzqmtverify_unrelated` ——
#    在共享 PG 上手工建一个同名库、灌 500 行数据，**光是启动本脚本就把它删光了**，
#    而那时任何档位都还没跑、任何归属都还没证明。
#    这与 harness 那条「精确白名单，绝不按前缀盲删」是同一条纪律，
#    只是数据库这一侧此前漏了 —— 前缀名不是归属证明，固定名同样不是。
_OWNED_EXTRA_DBS = (_UNRELATED_DB, _LIKE_DECOY_DB)

# 验收闸的**完整性清单**：收尾核对每一档都真的跑过。
# ⚠️ 少一档即失败 —— **「静默没跑」与「通过了」在输出上完全一样**，
#    这与本仓反复栽过的「空转的检查比没有检查更糟」是同一族。
# ⚠️ 本片（S1）**只含不依赖破坏性入口的档**；其余随 S2 / S3 补回来 ——
#    见 docs/superpowers/plans/2026-08-10-qmt-plan4a-2b-repackaging.md
#
# ⚠️⚠️ **㉕㉖㉗ 与 4a-2 那条 `feat/qmt-plan4a-2b-destructive` 分支上的同号档不是一回事。**
#    S1（PR #162）在实施中新造了三档并占用了这三个号（前缀扫描不吃 `_` 通配符 /
#    凭据表清场只删点名库名 / 同集群第二个验收取不到运行锁）。本片（S2）搬进来的
#    那三档因此改号，映射如下 —— 读旧计划或旧分支时按这张表对：
#      · 旧 ㉕（intent 新鲜度只认 inserted_at）  → 本脚本 **㉝**
#      · 旧 ㉗（DROP 之后清凭据）                → 本脚本 **㉞**
#      · 旧 ㉗b（连 db_oid=NULL 的陈旧凭据也清） → 本脚本 **㉞b**
#    ㉟ 是本片新增的（R15-F1 的语义证明），旧分支上没有。
#    ⚠️ S3 搬「孤儿删除锁内原子求值」时同样撞号（旧 ㉖）—— 那一档届时另编，别沿用旧号。
_EXPECTED_SCENARIOS = ("①", "②", "③", "④", "⑥", "⑦", "⑧", "⑨", "⑨b",
                       "⑨c", "⑩", "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑰b", "⑱",
                       "⑲", "⑳", "⑳b", "㉑", "㉒", "㉓", "㉔", "㉕", "㉖", "㉗", "㉛", "㉝")


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


def assert_extra_dbs_are_namespaced() -> int | None:
    """`_OWNED_EXTRA_DBS` 里每个名字都必须带 `zzqmtverify` 归属标记。

    ⚠️ 与 `assert_scratch_objects_are_namespaced` 同一条纪律，只是作用在**库**上：
       清理是 `DROP DATABASE`，通名（`scratch` / `tmpdb`）会在开发机或 CI 上
       把别人同名的库**不可逆地**删掉。
    ⚠️ 判的是**标记在不在**，不是它在不在开头：`_LIKE_DECOY_DB` 必须匹配
       `LIKE 'kline_pilot_lifecycle_%'` 才测得到 R4-F1，因此它开头只能是 `kline`。
       让名字不可能与别人重名的是 `zzqmtverify` 这个串本身，不是它的位置。
    """
    bad = [d for d in _OWNED_EXTRA_DBS if "zzqmtverify" not in d]
    if bad:
        print(f"拒绝运行：这些非 pilot 前缀的库名没带 `zzqmtverify` 归属标记：{bad}"
              f" —— 清理它们是 DROP DATABASE，通名会删掉别人的库", file=sys.stderr)
        return 6
    return None


async def assert_extra_dbs_are_not_preexisting(conn) -> int | None:
    """前置清场：`_OWNED_EXTRA_DBS` 里的库**若已经存在就拒绝运行**（R2-F1）。

    ⚠️ 判据是「本次运行之前它就在」——那说明它**不是本脚本这次造的**，
       归属证明不成立，绝不删。这与 harness 的 strangers 分支同一语义与同一逃生口。
    """
    present = [d for d in _OWNED_EXTRA_DBS if await conn.fetchval(
        "SELECT count(*) FROM pg_database WHERE datname = $1", d)]
    if not present:
        return None
    if os.environ.get("QMT_VERIFY_FORCE_CLEANUP") == "1":
        print(f"（QMT_VERIFY_FORCE_CLEANUP=1：删掉已存在的 {present}）")
        for d in present:
            await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(d))
        return None
    print(f"拒绝运行：这些库在本次运行**之前**就存在：{present}。"
          f"本脚本会不可逆地删掉它们，而它们不是本次造的、归属无从证明。"
          f"确认可弃后设 QMT_VERIFY_FORCE_CLEANUP=1 重跑，或先自行删除。",
          file=sys.stderr)
    return 4


async def _sweep_unrelated(conn) -> None:
    """收尾：清掉**本次运行造出来的**无关库与临时对象。

    ⚠️ 只在成功路径上跑，此时这些东西确实是本次造的 ——
       「本次之前就存在」那一档由 `assert_extra_dbs_are_not_preexisting` 在
       任何 DDL 之前挡掉。
    """
    for d in _OWNED_EXTRA_DBS:
        await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(d))
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
               assert_extra_dbs_are_namespaced(),
               harness.assert_every_selfcheck_db_is_whitelisted(
                   __file__, _LIFECYCLE_DBS, _PREFIX)):
        if rc is not None:
            return rc

    if (rc := await _acquire_run_lock(base_dsn)) is not None:
        return rc

    # 前置清场：上一次崩溃会留下库、登记行与临时对象；不清的话下一次运行会被
    # 上一次的残留顶红，且红的位置与真因毫无关系。
    pre = await _connect(base_dsn)
    try:
        await _apply_cluster_schema(pre)
        rc = await assert_extra_dbs_are_not_preexisting(pre)
        if rc is not None:
            return rc
        swept = await harness.sweep_leftover_databases(
            pre, prefix=_PREFIX, scenario_dbs=_LIFECYCLE_DBS, name_re=_NAME_RE)
        if isinstance(swept, int):
            return swept
        await _sweep_unrelated(pre)
        await harness.purge_metadata_for(pre, _LIFECYCLE_DBS)
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
    # ⚠️ 「真的 DROP 掉 + 重建」那半**在 S2b**（它要 `reset_pilot_database`，
    #    而本片零破坏性能力、模块里根本没有那个符号）。
    #    ⚠️ S2b 落地时必须补回来：本片只证明到「授权发得出来」为止，
    #    证明不了「DROP 真的执行得下去」——那正是 R55-F1 要钉的东西。
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
    print("⑬ 带**正确**令牌 → 授权必须放行（**唯一**证明令牌真的解锁了的一档）")
    # ⚠️ 少了这一档，实现可以「一律拒」而 ⑩⑪⑫ 全绿 —— 那是把 R55-F1 的锁死钉进 CI。
    # ⚠️ 「真的 DROP 掉」那半**在 S2b**：本片零破坏性能力，只证明到「授权发得出来」。
    maint = await _maintenance(base_dsn, seed=seed11)
    try:
        try:
            auth13 = await authorize_reset(
                maint, connect=connect_peer, db_name=db11, seed=seed11,
                **{**_RESET_ARGS, "reset_foreign_token": right_token})
            check(auth13.via_empty_remnant is False,
                  "⑬ 正确令牌 → 授权来自闸 0−/0/0b（不是零对象例外）",
                  f"via_empty_remnant={auth13.via_empty_remnant}")
        except Exception as exc:
            check(False, "⑬ 正确令牌必须解锁授权",
                  f"竟然被拒：{type(exc).__name__}: {exc}")
        check(await _database_exists(maint, db11),
              "⑬ 本片不销毁：授权发出后目标库仍然存在（DROP 归 S2b）")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db11)


    # ── ⑮⑯⑰ state 流转 + initializing **两向** ──────────────────────────
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

    scenario("⑰")
    print("⑰ 反向钉：同一个 initializing 库走 --reset → 授权必须放行")
    # spec R55-F1：--reset 时归属闸与绑定闸所需的键在阶段 1 就已写入，
    # 故它**能被正常清掉重来**。把 state 判定塞进 DROP 路径就是那个锁死。
    # ⚠️ 少了这一档，实现可以「一律拒」而 ⑯ 照样绿。
    # ⚠️ 「真的 DROP + 重建」那半**在 S2b**：本片零破坏性能力。
    maint = await _maintenance(base_dsn, seed=seed15)
    try:
        try:
            auth17 = await authorize_reset(maint, connect=connect_peer, db_name=db15,
                                           seed=seed15, **_RESET_ARGS)
            check(auth17.via_empty_remnant is False,
                  "⑰ initializing 的库必须能拿到 --reset 授权",
                  f"via_empty_remnant={auth17.via_empty_remnant}")
        except Exception as exc:
            check(False, "⑰ initializing 的库必须能拿到 --reset 授权",
                  f"竟然被拒：{type(exc).__name__}: {exc}")
    finally:
        await maint.close()
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

    # ── ㉕ 前缀扫描按**字面**比，不吃 `_` 通配符（R4-F1 回归）──────────────
    #    诱饵库匹配 `LIKE 'kline_pilot_lifecycle_%'` 但不以该前缀开头。
    #    旧判据下：不带 force 它被当成 stranger → 清场返回 4（㉕a 红）；
    #             带 force 则被 DROP（㉕b 红）。
    scenario("㉕")
    print("㉕ 前缀扫描不吃 `_` 通配符")
    conn = await _connect(base_dsn)
    try:
        await conn.execute("CREATE DATABASE " + quote_ident(_LIKE_DECOY_DB))
        leftover = f"{_PREFIX}g6"          # 真前缀下、且在白名单里 → 应当被删
        await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(leftover))
        await conn.execute("CREATE DATABASE " + quote_ident(leftover))
        swept = await harness.sweep_leftover_databases(
            conn, prefix=_PREFIX, scenario_dbs=_LIFECYCLE_DBS, name_re=_NAME_RE)
        decoy_alive = await conn.fetchval(
            "SELECT count(*) FROM pg_database WHERE datname = $1", _LIKE_DECOY_DB)
        check(swept == [leftover], "㉕a 清场删掉真前缀下的残留、且只删它",
              f"实得 {swept!r}（`4` = 判据把诱饵库当成了同前缀的 stranger）")
        check(decoy_alive == 1, "㉕b 只是 LIKE 命中的无关库不被删",
              f"{_LIKE_DECOY_DB!r} 没了 —— 判据把 `_` 当通配符了")
        await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(_LIKE_DECOY_DB))
    finally:
        await conn.close()

    # ── ㉖ 凭据表清场只删点名的库名（R4-F2 回归）──────────────────────────
    #    intent 行在 CREATE DATABASE **之前**写下，是崩溃后判归属的唯一依据；
    #    按前缀删会把**别的运行**的凭据一并抹掉。
    scenario("㉖")
    print("㉖ 凭据表清场只删点名的库名")
    # ⚠️ 旁观者的名字与 run_id 必须**本次运行唯一**（codex 4a-2b/S1 R6-F1，high）：
    #    上一版用固定名 `…otherrun_7788`，插入前不查、`finally` 里只按 dbname 无条件删。
    #    `dbname` 是这两张表的**主键** —— 该名字若已有真行（真运行留下的，或上一次被
    #    打断的验收留下的），INSERT 直接抛，而 `finally` 照样把那些**真凭据**删掉。
    #    也就是说：这一档本身犯了它要防的那个错。
    #    现在：唯一名 + 插入前 fail-closed 断言不存在 + 清理按 `dbname` **且** `run_id`，
    #    绝不碰不是本次写下的行。
    token = uuid.uuid4().hex[:12]
    bystander = f"{_PREFIX}bystander_{token}"   # 同前缀、但**不在** `_LIFECYCLE_DBS` 里
    bystander_run = f"zzqmtverify-bystander-{token}"
    mine = _LIFECYCLE_DBS[0]
    conn = await _connect(base_dsn)
    try:
        pre_i = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", bystander)
        pre_r = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_database_registry WHERE dbname = $1", bystander)
        if pre_i or pre_r:
            # 唯一名撞上 = 归属无从证明 → 不写、不删、直接判失败。
            check(False, "㉖ 前置：旁观者库名在本次运行之前必须没有任何登记行",
                  f"{bystander!r} 已有 intent={pre_i} registry={pre_r} —— 拒绝碰它")
            raise RuntimeError(f"㉖ 旁观者名字 {bystander!r} 已被占用，拒绝改动它的凭据")
        # `mine` 在本脚本自己的白名单里 —— 先清掉它自己的行再插，免得将来新增某个
        # 会给 c4 写 intent 的档位时，这里因主键冲突而崩（那是脆弱，不是判据）。
        await harness.purge_metadata_for(conn, (mine,))
        for name in (bystander, mine):
            await conn.execute(
                "INSERT INTO public.pilot_create_intent"
                " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
                " VALUES ($1, 'x', now(), $2, true, NULL)", name, bystander_run)
            await conn.execute(
                "INSERT INTO public.pilot_database_registry"
                " (dbname, seed, run_id, claimed_at, db_oid)"
                " VALUES ($1, 'x', $2, now(), 1)", name, bystander_run)
        await harness.purge_metadata_for(conn, _LIFECYCLE_DBS)
        kept_i = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", bystander)
        kept_r = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_database_registry WHERE dbname = $1", bystander)
        gone_i = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", mine)
        gone_r = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_database_registry WHERE dbname = $1", mine)
        check(kept_i == 1 and kept_r == 1, "㉖a 别的运行的凭据不被清场删掉",
              f"{bystander!r} 的 intent={kept_i} registry={kept_r}，期望各 1")
        check(gone_i == 0 and gone_r == 0, "㉖b 点名库名的登记行确实被清掉",
              f"{mine!r} 的 intent={gone_i} registry={gone_r}，期望各 0")
    finally:
        # ⚠️ `run_id` 必须一起进 WHERE：只按 dbname 删就是「删掉不是本次写的行」——
        #    正是本档要证伪的那件事。
        await conn.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1 AND run_id = $2",
            bystander, bystander_run)
        await conn.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname = $1 AND run_id = $2",
            bystander, bystander_run)
        await conn.close()

    # ── ㉗ 同集群上第二个同前缀的验收必须取不到运行锁（R7-F2 回归）───────────
    #    本进程已经握着这把锁（`_acquire_run_lock`）。第二个运行必须取不到 ——
    #    否则并发的两个运行会互删对方正在用的库与凭据。
    #    ⚠️ 判据必须用**同集群、不同库**的 DSN（codex R8-F1）：advisory lock 是每库的，
    #       上一版在「调用方 DSN 所指的库」上取锁，这一档拿同一个 DSN 去试，
    #       测不到「换个库名就绕过去了」这条真缺陷。
    scenario("㉗")
    print("㉗ 同集群的第二个验收取不到运行锁（哪怕它的 DSN 指向别的库）")
    rival_dsn = harness.db_dsn(base_dsn, "template1")   # 同集群、不同库
    denied = await harness.acquire_run_lock(rival_dsn, _PREFIX)
    if denied is not None:
        await denied.close()
    check(denied is None, "㉗a 同集群、DSN 指向别的库的第二个运行同样取不到锁",
          "竟然取到了 —— 换个库名就绕过运行锁，两个运行会互删对方正在用的库和凭据")
    other = await harness.acquire_run_lock(base_dsn, "kline_pilot_someotherprefix")
    check(other is not None, "㉗b 别的前缀不受影响（证明 ㉗a 不是「这把锁谁都取不到」）",
          "连不相干的前缀都取不到 —— 那 ㉗a 就是恒真的")
    if other is not None:
        await other.close()

    # ── ㉝ intent 新鲜度只认 `inserted_at`（2b R3-F2；**host 层零覆盖**）───
    #    造一行「`created_at` 在很远的未来、`inserted_at` 已超期」的凭据：
    #    看 `created_at` 会判成新鲜（→ 授权销毁），看 `inserted_at` 才判得出超期。
    scenario("㉝")
    print("㉝ intent 新鲜度只认 inserted_at（created_at 在未来也不算数）")
    seed33 = "lifecycle_r33"
    db33 = f"kline_pilot_{seed33}"
    maint = await _maintenance(base_dsn, seed=seed33)
    try:
        await harness.drop_database(base_dsn, db33)
        await maint.execute("CREATE DATABASE " + quote_ident(db33))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db33)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db33, seed33, "29990101T000000000000Z", f"lifecycle-{seed33}")
        # `inserted_at` 推到 TTL 之外（`created_at` 已是很远的未来）。
        await maint.execute(
            "UPDATE public.pilot_create_intent"
            "   SET inserted_at = now() - make_interval(secs => $2)"
            " WHERE dbname = $1", db33, float(INTENT_TTL_SECONDS + 3600))
        try:
            auth = await authorize_reset(maint, connect=connect_peer, db_name=db33,
                                         seed=seed33, **_RESET_ARGS)
            check(False, "㉝ 超期凭据不得授权销毁",
                  f"竟然放行了：via_empty_remnant={auth.via_empty_remnant}")
        except PilotDbBoundaryError as exc:
            # 例外不适用 → 落到闸 0−，那个空库没有 pilot_meta → not_owned
            check(exc.code == "not_owned",
                  "㉝ inserted_at 超期 → 例外不适用，落到闸 0− 判 not_owned",
                  f"实得 {exc.code}：{exc}")
        check(await _database_exists(maint, db33), "㉝ 拒绝之后那个空库仍然存在")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db33)

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
    # ⚠️ 全绿**不等于** spec §6.2 生命周期那一组被满足 —— S1 只跑了非破坏性档。
    #    只写在 docstring 里跑的人看不见，故打到输出上（与并发脚本同一处理）。
    # ⚠️ **这段话必须说清楚本片到底证明了什么**（codex S2a-R1-F2）：
    #    上一版只说「不覆盖 --init-cluster-marker」，**暗示其余都覆盖了** ——
    #    而本片所有 reset 档只调到 `authorize_reset` 为止。
    #    DROP 执行 / 紧贴复查 / 会话封锁 / 凭据清理**全部坏掉，本脚本照样全绿**。
    #    在最高风险的那条路径上给出假信心，正是本仓反复栽的
    #    「宣称的保证 > 实际提供的保证」。
    print("⚠️⚠️ 本片（S2a）只验到**授权发得出来**为止，**不验 DROP 真的执行得下去**：")
    print("     · `reset_pilot_database` / `_drop_pilot_database` 不在本片，模块里没有这两个符号；")
    print("     · 故 DROP 执行、DROP 前的【绝对空】/归属/身份紧贴复查、连接封锁与占用者检查、")
    print("       DROP 后的凭据清理 —— 这些**一档都没跑**，坏掉也不会让本脚本变红。")
    print("     · 它们随 **S2b** 补回（⑨⑬⑰ 的 DROP 半 + ㉘ ㉜ ㉜b ㉞ ㉞b ㉟）。")
    print("⚠️ 另：`--init-cluster-marker` 的幂等语义与孤儿 intent 清理随 **S3** 补回。")
    print("⛔ 因此本脚本**此刻不是** spec §6.2 生命周期那一组的 ship gate。")
    return 0


# ── 每前缀的运行锁（codex 4a-2b/S1 R7-F2）────────────────────────────────
# ⚠️ 本脚本的场景库名是**固定**的。同一集群上并发跑两个同前缀的验收，后者的前置
#    清场会把前者**正在用**的库 DROP 掉、把它的 intent/registry 行删掉。
#    锁握在一条活到进程结束的连接上 —— advisory lock 是会话级的，连接一关（含崩溃、
#    被杀）就自动释放，不会留下死锁。
# ⚠️ 是**列表**不是单个：㉔ 那类档会在第二台集群上删/建固定名的库，
#    那台集群的锁也要一起握到进程结束（codex R9-F1）。
_LOCK_CONNS = []


async def _acquire_run_lock(base_dsn: str) -> int | None:
    lock = await harness.acquire_run_lock(base_dsn, _PREFIX)
    if lock is None:
        print(f"拒绝运行：同一集群上已有另一个 {_PREFIX!r} 前缀的验收在跑。"
              f"两个运行的场景库名完全相同，继续下去会把对方正在用的库和凭据删掉。"
              f"等它跑完再来（它一结束锁就自动放）。", file=sys.stderr)
        return 8
    _LOCK_CONNS.append(lock)
    return None


async def _entry() -> int:
    try:
        return await main()
    finally:
        for _lock in _LOCK_CONNS:
            await _lock.close()


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_entry()))
