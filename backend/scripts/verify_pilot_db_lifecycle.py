#!/usr/bin/env python3
"""验证 4a-2 的库级闸与破坏性路径在真 PostgreSQL 上真的成立（**S2 切片**）。

⛔ **本脚本仍不是 spec §6.2 生命周期那一组的 ship gate**
   （codex 4a-2b/S1 R5-F2）：下面「本脚本管」那张分工表写的是**这个文件最终**要
   覆盖的范围；**集群标记初始化与孤儿清理那一组已由 S3 补齐**（见下）。
   ⚠️ 这与 R1/R3 在并发脚本上栽过的是同一条：全绿摘要照样打印，读的人会把它
      当成整组生命周期验收已过。`--init-cluster-marker` 在 S3 之前一档都没跑，
      现在有七档；这段话保留，是因为「静默没验」与「验过了」在输出上完全一样。

   **已由 S3 补齐**（⑤ ⑤b ㉙ ㉚ ㊱ ㊲ ㊳）：
     · `init_cluster_marker` 的幂等语义与「副作用排在证明之后」（⑤ ⑤b ㉙ ㊳）
     · 孤儿 intent 行的清理（含取锁必须还、判据必须在锁内当下求值）（㉚ ㊱ ㊲）
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
                          PilotDbBoundaryError, _LIST_ALL_INTENT_SQL,
                          _is_absolutely_empty,
                          _READ_INTENT_SQL, _SEED_LOCK_HELD_SQL,
                          _TARGET_CLIENT_SESSIONS_SQL, assert_cluster_allowed,
                          assert_db_allowed_for_reset,
                          assert_db_allowed_for_reuse,
                          create_pilot_database, init_cluster_marker,
                          quote_ident,
                          reset_pilot_database, sha256_of_sql,
                          try_empty_remnant_exception)
# ⚠️ **`authorize_reset` 已经没有了**（2026-08-12 塌缩）：整套「可传递的授权凭据」连同
#    那个单一入口一起删掉了。`--reset` 这条路现在是：
#      · 两个**判定** helper —— `try_empty_remnant_exception` / `assert_db_allowed_for_reset`；
#      · 一个**唯一公开破坏性入口** `reset_pilot_database`（判定与销毁一体，S2b′ 落地）。
#    故「只判不删」的档点名调判定 helper，「真的动手」的档走 `reset_pilot_database`。
#    ⚠️ S2a 明写接受的那条残留（spec §4 的有向序列没有东西机器强制）**本片还回来了**：
#       次序焊在 `reset_pilot_database` 的函数体里，由 host 层的 AST 钉子守着。
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
    "kline_pilot_lifecycle_r30",          # ㉚（只写 intent 行，不建库）
    "kline_pilot_lifecycle_r31",
    "kline_pilot_lifecycle_r32",
    "kline_pilot_lifecycle_r32b",
    "kline_pilot_lifecycle_r33",
    "kline_pilot_lifecycle_r33b",
    "kline_pilot_lifecycle_r33c",
    "kline_pilot_lifecycle_r34",
    "kline_pilot_lifecycle_r34b",
    "kline_pilot_lifecycle_r35",
    "kline_pilot_lifecycle_r35b",
    "kline_pilot_lifecycle_r36",          # ㊱
    "kline_pilot_lifecycle_r37",          # ㊲
    "kline_pilot_lifecycle_r38",          # ㊳（已登记的非空 pilot 库）
    "kline_pilot_lifecycle_r38stranger",  # ㊳（未登记的非空同前缀库）
    "kline_pilot_lifecycle_r39",          # ㊴（db_oid 为空的凭据）
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
# ⚠️ S1 那一片**只含不依赖破坏性入口的档**；S2 / S3 已把其余的全部补齐 ——
#    见 docs/superpowers/plans/2026-08-10-qmt-plan4a-2b-repackaging.md
#    与 docs/superpowers/plans/2026-08-14-qmt-4a2b-s3-init-cluster-marker.md
#
# ⚠️⚠️ **㉕㉖㉗ 与 4a-2 那条 `feat/qmt-plan4a-2b-destructive` 分支上的同号档不是一回事。**
#    S1（PR #162）在实施中新造了三档并占用了这三个号（前缀扫描不吃 `_` 通配符 /
#    凭据表清场只删点名库名 / 同集群第二个验收取不到运行锁）。本片（S2）搬进来的
#    那三档因此改号，映射如下 —— 读旧计划或旧分支时按这张表对：
#      · 旧 ㉕（intent 新鲜度只认 inserted_at）  → 本脚本 **㉝**
#      · 旧 ㉗（DROP 之后清凭据）                → 本脚本 **㉞**
#      · 旧 ㉗b（连 db_oid=NULL 的陈旧凭据也清） → 本脚本 **㉞b**
#    ㉟ 是本片新增的（R15-F1 的语义证明），旧分支上没有。
#    ⚠️ S3 搬「孤儿删除锁内原子求值」时同样撞号（旧 ㉖）—— **已另编为 ㊱**，别沿用旧号。
_EXPECTED_SCENARIOS = ("①", "②", "③", "④", "⑤", "⑤b", "⑥", "⑦", "⑧", "⑨", "⑨b",
                       "⑨c", "⑩", "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑰b", "⑱",
                       "⑲", "⑳", "⑳b", "㉑", "㉒", "㉓", "㉔", "㉕", "㉖", "㉗", "㉙",
                       "㉚", "㊱", "㊲", "㊳", "㊴", "㉛",
                       "㉝", "㉝b", "㉝c", "㉘", "㉜", "㉜b", "㉞", "㉞b", "㉟", "㉟b")


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


async def _database_oid(conn, name: str) -> str | None:
    """目标库**当前实例**的 oid。

    ⚠️ 放行档用它做判据：`assert_db_allowed_for_reset` 交回的必须是**这个库这一刻**的
       oid，不是随便一个真值。只断言「没抛异常」的话，实现把 `return oid` 改成
       `return "0"`（或返回上一次探到的那个）也照样绿 —— 而 DROP 就是靠这个 oid
       认定「要删的是不是当初被授权的那个实例」。
    """
    return await conn.fetchval(
        "SELECT d.oid::text FROM pg_database d WHERE d.datname::text = $1", name)


async def _relation_exists(base_dsn: str, dbname: str, relname: str) -> bool:
    """某个库里有没有这张表。**用于「拒绝之后是不是真的没留下东西」这类断言。**"""
    conn = await asyncpg.connect(harness.db_dsn(base_dsn, dbname))
    try:
        return bool(await conn.fetchval(
            "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
            " WHERE n.nspname = 'public' AND c.relname = $1", relname))
    finally:
        await conn.close()


async def _is_db_absolutely_empty(base_dsn: str, dbname: str) -> bool:
    """某个库是不是【绝对空】。**连进去问模块自己那条判据**，不另写一份 ——
    另写一份的话，这一档验的就成了「我抄的那份判据怎么想」，而不是生产判据。"""
    conn = await asyncpg.connect(harness.db_dsn(base_dsn, dbname))
    try:
        return bool(await _is_absolutely_empty(conn))
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
                await assert_db_allowed_for_reset(
                    maint, connect=connect_peer, db_name=dbname, seed=seed,
                    **_RESET_ARGS)
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

        # ⚠️ **必须包 try**：裸调时判定一旦抛异常会直接把脚本打死 ——
        #    那样这一档**产不出 FAIL 行**，变异跑器只看到「脚本挂了」而不是「⑨ 红了」，
        #    等于这一档零判别力（本轮变异当场抓到）。
        want9 = await _database_oid(maint, db9)
        try:
            remnant_oid = await try_empty_remnant_exception(
                maint, connect=connect_peer, db_name=db9, seed=seed9)
            check(remnant_oid == want9,
                  "⑨ 零对象例外对空残骸成立，且交回**这个实例**的 oid",
                  f"实得 {remnant_oid!r}，该库当前 oid={want9!r}")
        except Exception as exc:
            check(False, "⑨ 零对象例外对空残骸成立，且交回**这个实例**的 oid",
                  f"空残骸的例外判定抛了：{type(exc).__name__}: {exc}")
        # ⚠️ **对照的另一半**（塌缩后新增）：同一个残骸走闸 0−/0/0b **必须被拒**。
        #    没有这一半，「例外返回了 oid」证明不了例外有存在的必要 ——
        #    而它存在的全部理由就是「闸 0− 对残骸只会判 not_owned，残骸于是永远清不掉」
        #    （R56-F1 花一整轮修的洞 / R55-F1 那句「能被自己 --reset 清掉重来」）。
        try:
            await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db9, seed=seed9, **_RESET_ARGS)
            check(False, "⑨-对照 同一个残骸走闸 0−/0/0b 必须被拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned",
                  "⑨-对照 同一个残骸走闸 0−/0/0b → not_owned（故例外是它唯一的出路）",
                  f"实得 {exc.code}：{exc}")
    finally:
        await maint.close()
    # 真的把它 DROP 掉并重建 —— 「声称的恢复能力必须逐条验到 DROP 真的能执行为止」。
    # ⚠️ 只验到「例外判定成立」是不够的（S2a 就停在那里）：R55-F1 要钉的是
    #    「残骸能被自己 --reset 清掉重来」，而那句话里的动词是 DROP 与重建。
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
        got9b = await try_empty_remnant_exception(
            maint, connect=connect_peer, db_name=db9b, seed=seed9b)
        check(got9b is None, "⑨b 未确认的 intent 行 → 零对象例外不适用",
              f"竟然交出了授权 oid={got9b!r}")
        # 例外不适用之后唯一的去处是闸 0−：那个库没有 pilot_meta → not_owned
        # （「不是本工具建的，请人工删」）。两半都断言，免得「例外返 None」被实现成
        # 「例外恒返 None」而无人察觉 —— 那会让 ⑨ 变红，但 ⑨ 与本档的判据必须各自可分辨。
        try:
            await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db9b, seed=seed9b, **_RESET_ARGS)
            check(False, "⑨b 例外不适用后走闸 0− 必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned",
                  "⑨b 例外不适用 → 落到闸 0− 判 not_owned", f"实得 {exc.code}")
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
        got9c = await try_empty_remnant_exception(
            maint, connect=connect_peer, db_name=db9c, seed=seed9c)
        check(got9c is None, "⑨c 陈旧实例绑定 → 零对象例外不适用",
              f"竟然交出了授权 oid={got9c!r}")
        try:
            await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db9c, seed=seed9c, **_RESET_ARGS)
            check(False, "⑨c 例外不适用后走闸 0− 必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned",
                  "⑨c 例外不适用 → 落到闸 0− 判 not_owned", f"实得 {exc.code}")
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
            await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db10, seed=seed10, **_RESET_ARGS)
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
            await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db11, seed=seed11, **_RESET_ARGS)
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
            await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db11, seed=seed11,
                **{**_RESET_ARGS, "reset_foreign_token": "deadbeefcafe"})
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
    # ⚠️ 「真的 DROP 掉」那半**在 S2b**：本片零破坏性能力，只证明到「闸放行」。
    maint = await _maintenance(base_dsn, seed=seed11)
    try:
        want13 = await _database_oid(maint, db11)
        try:
            got13 = await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db11, seed=seed11,
                **{**_RESET_ARGS, "reset_foreign_token": right_token})
            check(got13 == want13,
                  "⑬ 正确令牌 → 闸 0−/0/0b 放行，并交回**这个实例**的 oid",
                  f"实得 {got13!r}，该库当前 oid={want13!r}")
        except Exception as exc:
            check(False, "⑬ 正确令牌必须让闸 0−/0/0b 放行",
                  f"竟然被拒：{type(exc).__name__}: {exc}")
        check(await _database_exists(maint, db11),
              "⑬ 闸只判不删：放行之后目标库仍然存在")
    finally:
        await maint.close()
    # …并且带同一个令牌走唯一入口时，它**真的被删掉**。
    maint = await _maintenance(base_dsn, seed=seed11)
    try:
        try:
            await reset_pilot_database(
                maint, connect=connect_peer, db_name=db11, seed=seed11,
                **{**_RESET_ARGS, "reset_foreign_token": right_token})
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
    print("⑰ 反向钉：同一个 initializing 库走 --reset → 闸必须放行")
    # spec R55-F1：--reset 时归属闸与绑定闸所需的键在阶段 1 就已写入，
    # 故它**能被正常清掉重来**。把 state 判定塞进 DROP 路径就是那个锁死。
    # ⚠️ 少了这一档，实现可以「一律拒」而 ⑯ 照样绿。
    # ⚠️ 「真的 DROP + 重建」那半**在 S2b**：本片零破坏性能力。
    maint = await _maintenance(base_dsn, seed=seed15)
    try:
        want17 = await _database_oid(maint, db15)
        try:
            got17 = await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db15, seed=seed15, **_RESET_ARGS)
            check(got17 == want17,
                  "⑰ initializing 的库必须过得了 --reset 的闸，并交回**这个实例**的 oid",
                  f"实得 {got17!r}，该库当前 oid={want17!r}")
        except Exception as exc:
            check(False, "⑰ initializing 的库必须过得了 --reset 的闸",
                  f"竟然被拒：{type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    # …并且真的删得掉、删完还能重建（把 state 判定塞进 DROP 路径就是 R55-F1 的锁死）。
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
        want22 = await _database_oid(maint, db22)
        try:
            got22 = await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db22, seed=seed22, **_RESET_ARGS)
            check(got22 == want22,
                  "㉒ **反向**：--reset 不要求登记凭据，闸照样放行并交回本实例 oid",
                  f"实得 {got22!r}，该库当前 oid={want22!r}")
        except Exception as exc:
            check(False, "㉒ **反向**：--reset 不要求登记凭据，闸照样放行",
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
        want23 = await _database_oid(maint, db23)
        try:
            got23 = await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db23, seed=seed23, **_RESET_ARGS)
            check(got23 == want23,
                  "㉓ **反向**：带触发器的库 --reset 仍放行（闸 2 不进 DROP 路径）",
                  f"实得 {got23!r}，该库当前 oid={want23!r}")
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
        got33 = await try_empty_remnant_exception(
            maint, connect=connect_peer, db_name=db33, seed=seed33)
        check(got33 is None, "㉝ inserted_at 超期 → 零对象例外不适用",
              f"竟然交出了授权 oid={got33!r}")
        try:
            await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db33, seed=seed33, **_RESET_ARGS)
            check(False, "㉝ 例外不适用后走闸 0− 必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            # 例外不适用 → 落到闸 0−，那个空库没有 pilot_meta → not_owned
            check(exc.code == "not_owned",
                  "㉝ 例外不适用 → 落到闸 0− 判 not_owned", f"实得 {exc.code}：{exc}")
        check(await _database_exists(maint, db33), "㉝ 拒绝之后那个空库仍然存在")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db33)

    # ── ㉝b intent 的年龄必须落在 `[0, TTL)` —— **未来**的 inserted_at 一律判掉 ──
    #    （codex S2a-R2-F2）时钟回拨 / 从备份还原 / 人工修表都会造出未来值。
    #    只判上界（`age < TTL`）的写法会把它当成「刚写下的、最新鲜的」凭据，
    #    于是「TTL 把销毁授权窗口从永久收窄到 24h」（spec O4-F2）整条保证失效。
    #    ⚠️ 这一档是 ㉝ 的**判别力补丁**，不是重复：㉝ 把 `inserted_at` 推到**过去**、
    #       靠上界判掉；下界（`0 <=`）在 ㉝ 上**一次都没求值**。
    scenario("㉝b")
    print("㉝b inserted_at 在未来 → 例外不适用（年龄必须非负）")
    seed33b = "lifecycle_r33b"
    db33b = f"kline_pilot_{seed33b}"
    maint = await _maintenance(base_dsn, seed=seed33b)
    try:
        await harness.drop_database(base_dsn, db33b)
        await maint.execute("CREATE DATABASE " + quote_ident(db33b))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db33b)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db33b, seed33b, _CREATED_AT, f"lifecycle-{seed33b}")
        # `inserted_at` 推到**未来**（其余五条全部成立 —— 只剩年龄这一条不合格）。
        await maint.execute(
            "UPDATE public.pilot_create_intent"
            "   SET inserted_at = now() + make_interval(secs => $2)"
            " WHERE dbname = $1", db33b, float(INTENT_TTL_SECONDS + 3600))
        # 先证明夹具真的造出了负年龄，否则下面那条可能是因为别的原因绿的。
        age33b = await maint.fetchval(
            "SELECT EXTRACT(EPOCH FROM (now() - inserted_at))::bigint"
            "  FROM public.pilot_create_intent WHERE dbname = $1", db33b)
        check(age33b is not None and age33b < 0,
              "㉝b 前置：库时钟算出来的年龄确实是**负数**",
              f"实得 age_seconds={age33b!r} —— 夹具没造出未来值，这一档测不到下界")
        got33b = await try_empty_remnant_exception(
            maint, connect=connect_peer, db_name=db33b, seed=seed33b)
        check(got33b is None, "㉝b 未来的 inserted_at → 零对象例外不适用",
              f"竟然交出了 oid={got33b!r} —— 一行不可能的时间戳换来一张永不过期的 DROP 授权")
        try:
            await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db33b, seed=seed33b, **_RESET_ARGS)
            check(False, "㉝b 例外不适用后走闸 0− 必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned",
                  "㉝b 例外不适用 → 落到闸 0− 判 not_owned", f"实得 {exc.code}：{exc}")
        check(await _database_exists(maint, db33b), "㉝b 拒绝之后那个空库仍然存在")

        # ── ㉝b 第二段：**亚秒级**的未来时间戳，符号不许被取整抹掉（codex S2a-R3-F1）──
        # ⚠️ 上面那半用的是「TTL + 1 小时」的未来值 —— 它大到**整数判据也拦得住**，
        #    故对「SQL 里 `::bigint` 四舍五入把 −0.1 抹成 0」这条**零判别力**。
        #    真 PG 15 实测：`(-0.1)::bigint = 0`、`(-0.4)::bigint = 0`。
        # ⚠️ 判据钉的是**模块自己那条 SQL 返回了什么**，不是脚本另写一条等价查询 ——
        #    取整被加回去时只有前者会变（与 ㉜b 断言模块预检谓词同一条纪律）。
        # ⚠️ 端到端那一半在这里**故意不做**：整条闸序要跑好几百毫秒，
        #    一个 400ms 的未来值到那时早就变成过去了 —— 那样的档是 flake，不是覆盖。
        #    端到端方向由上面那半（TTL+1h）承担，本段只钉「符号活着走出 SQL」。
        await maint.execute(
            "UPDATE public.pilot_create_intent"
            "   SET inserted_at = now() + interval '400 milliseconds'"
            " WHERE dbname = $1", db33b)
        sub = await maint.fetch(_READ_INTENT_SQL, db33b)
        sub_age = sub[0]["age_seconds"] if sub else None
        check(sub_age is not None and sub_age < 0,
              "㉝b2 400ms 的未来 inserted_at → **模块的 SQL** 返回的年龄仍是负数",
              f"实得 age_seconds={sub_age!r}（0 = 被 ::bigint 四舍五入抹掉了符号，"
              f"下界那条修复就此失效）")
        check(sub_age is not None and -1 < sub_age < 0,
              "㉝b2 而且它是**分数秒**（证明确实取到了亚秒精度，不是整秒 −1）",
              f"实得 age_seconds={sub_age!r}")
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db33b)
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db33b)

    # ── ㉝c TTL 不许拿**事务开始时刻**去量（codex S2a-R4-F2）─────────────
    #    PostgreSQL 的 `now()` 是**事务开始时刻**，不是当前时刻。维护连接处在长事务里
    #    （4c 的 wrapper 很可能把整段 reset 包进事务）时它冻在过去，
    #    一行**真实已过期**的销毁凭据会被量成「还新鲜」→ 零对象例外照样放行。
    #    ⚠️ 这一档是 ㉝ / ㉝b 的**判别力补丁**：那两档都在**自动提交**下跑，
    #       `now()` 与 `statement_timestamp()` 几乎相等 —— 时钟源这一条在它们身上
    #       **一次都没求值**。把时钟源换回 `now()`，㉝ 与 ㉝b 照样全绿。
    #    ⚠️ 判据是**模块自己那条 SQL 返回了什么**，不是脚本另写一条等价查询。
    scenario("㉝c")
    print("㉝c 长事务里 TTL 仍按语句时刻量（`now()` 会冻在事务开始那一刻）")
    seed33c = "lifecycle_r33c"
    db33c = f"kline_pilot_{seed33c}"
    maint = await _maintenance(base_dsn, seed=seed33c)
    try:
        await harness.drop_database(base_dsn, db33c)
        await maint.execute("CREATE DATABASE " + quote_ident(db33c))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db33c)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db33c, seed33c, _CREATED_AT, f"lifecycle-{seed33c}")
        # 开一个事务并让它「变老」——之后这条连接上的 `now()` 就冻在 1.2s 前。
        await maint.execute("BEGIN")
        try:
            await maint.fetchval("SELECT pg_sleep(1.2)")
            drift = float(await maint.fetchval(
                "SELECT EXTRACT(EPOCH FROM (statement_timestamp() - now()))"))
            check(drift >= 1.0,
                  "㉝c 前置：事务里的 `now()` 确实落后语句时刻 ≥1s",
                  f"实得 drift={drift:.3f}s —— 事务没变老，这一档测不到时钟源")
            # 造一行**真实已过期 0.1 秒**的凭据：按真实时钟（clock_timestamp）回推。
            await maint.execute(
                "UPDATE public.pilot_create_intent"
                "   SET inserted_at = clock_timestamp() - make_interval(secs => $2)"
                " WHERE dbname = $1", db33c, float(INTENT_TTL_SECONDS) + 0.1)
            rows = await maint.fetch(_READ_INTENT_SQL, db33c)
            age = float(rows[0]["age_seconds"]) if rows else None
            check(age is not None and age >= INTENT_TTL_SECONDS,
                  "㉝c **模块的 SQL** 在长事务里仍把它量成已过期",
                  f"实得 age_seconds={age!r}，TTL={INTENT_TTL_SECONDS}"
                  f"（小于 TTL = 用了 `now()`，一行真实已过期的销毁凭据被判成新鲜）")
            got33c = await try_empty_remnant_exception(
                maint, connect=connect_peer, db_name=db33c, seed=seed33c)
            check(got33c is None,
                  "㉝c 长事务里那行过期凭据仍然不得让零对象例外成立",
                  f"竟然交出了 oid={got33c!r}")
        finally:
            await maint.execute("ROLLBACK")
        check(await _database_exists(maint, db33c), "㉝c 拒绝之后那个空库仍然存在")
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db33c)
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db33c)

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
        got31 = await try_empty_remnant_exception(
            maint, connect=connect_peer, db_name=db31, seed=seed31)
        check(got31 is None, "㉛ 物化视图算「非空」→ 零对象例外不适用",
              f"竟然交出了授权 oid={got31!r}")
        try:
            await assert_db_allowed_for_reset(
                maint, connect=connect_peer, db_name=db31, seed=seed31, **_RESET_ARGS)
            check(False, "㉛ 例外不适用后走闸 0− 必须拒", "竟然放行了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned",
                  "㉛ 例外不适用 → 落到闸 0− 判 not_owned", f"实得 {exc.code}：{exc}")
        check(await _database_exists(maint, db31), "㉛ 拒绝之后目标库仍然存在")
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db31)
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db31)

    # ── ㉞ reset 之后凭据被清掉，且能用**新 run_id** 立刻重建（2b R4-F1）──────
    scenario("㉞")
    print("㉞ reset 之后凭据被清掉，且能用**新 run_id** 立刻重建")
    seed34 = "lifecycle_r34"
    db34 = f"kline_pilot_{seed34}"
    maint = await _maintenance(base_dsn, seed=seed34)
    try:
        # ⚠️ **夹具不能用 `_build`**：`create_pilot_database` 跑成功时自己就把 intent 行
        #    清掉了（`_CLEAR_INTENT_SQL`），于是「事后 0 条」恒真、这一档整个是空的
        #    （变异当场抓到：把 DROP 后的清理整条删掉，㉞ 照样绿）。
        #    R4-F1 要防的是**零对象例外那条路**：崩在写 pilot_meta 之前的残骸，
        #    它那行凭据仍然新鲜且已确认，只有 DROP 之后的清理能收掉。
        await harness.drop_database(base_dsn, db34)
        await maint.execute("CREATE DATABASE " + quote_ident(db34))
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db34)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db34, seed34, _CREATED_AT, f"lifecycle-{seed34}")
        check(1 == await maint.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db34),
            "㉞ 前置：残骸的 intent 凭据已就位")
        try:
            await reset_pilot_database(maint, connect=connect_peer, db_name=db34,
                                       seed=seed34, **_RESET_ARGS)
        except Exception as exc:
            check(False, "㉞ 前置：reset 必须成功", f"抛了：{type(exc).__name__}: {exc}")
        left = await maint.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db34)
        check(left == 0, "㉞ DROP 之后那条 intent 凭据被清掉了", f"事后仍有 {left} 条")
        # ⚠️ **必须换 run_id**：沿用同一个 run_id 时接管条件本来就成立，
        #    这一档会变成恒真。
        try:
            await create_pilot_database(maint, connect=connect_peer, db_name=db34,
                                        seed=seed34, run_id=f"lifecycle-{seed34}-again",
                                        **_BUILD_ARGS)
            check(True, "㉞ 紧接着用**新 run_id** 重建成功（没被陈旧凭据卡住）")
        except Exception as exc:
            check(False, "㉞ 紧接着用**新 run_id** 重建成功（没被陈旧凭据卡住）",
                  f"重建抛了：{type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db34)

    # ── ㉞b DROP 之后必须连**指不到活实例**的凭据一起清（codex 4a-2 R11-F1）──
    #    `pilot_create_intent.db_oid` 可空，而 intent 行写在 `CREATE DATABASE` **之前**
    #    —— 那一刻它就是 NULL。一次失败的建库若连自己的撤回也失败（连接断/进程被杀），
    #    就留下一行**新鲜、未确认、db_oid = NULL** 的行。
    #    只按「被销毁的那个 oid」清理时 NULL 匹配不上 → 该行留存 →
    #    用**新 run_id** 重建时接管条件（同 run_id 或超 TTL）都不成立 →
    #    `intent_row_conflict`：**破坏性 reset 之后重建不了**，要等 TTL 或人工。
    #    ⚠️ ㉞ 造的是零对象例外那条路的残骸凭据（db_oid 绑对），证伪不了这一档。
    scenario("㉞b")
    print("㉞b reset 之后连 db_oid=NULL 的陈旧凭据也要清掉，否则重建被卡死")
    seed34b = "lifecycle_r34b"
    db34b = await _build(base_dsn, seed34b, connect_peer)
    maint = await _maintenance(base_dsn, seed=seed34b)
    try:
        # 建库成功时自己的凭据已被清掉；这里注入「上一次失败的建库留下的」那种行：
        # 新鲜、未确认、db_oid = NULL、**且 run_id 与后面的重建不同**。
        await maint.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db34b)
        await maint.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " VALUES ($1, $2, $3, $4, false, NULL)",
            db34b, seed34b, _CREATED_AT, f"lifecycle-{seed34b}-crashed")
        stale = await maint.fetchrow(
            "SELECT create_confirmed, db_oid IS NULL AS oid_is_null"
            "  FROM public.pilot_create_intent WHERE dbname = $1", db34b)
        check(stale is not None and not stale["create_confirmed"] and stale["oid_is_null"],
              "㉞b 前置：陈旧的「未确认 + db_oid 为 NULL」凭据已就位",
              f"实得 {dict(stale) if stale else None}")
        try:
            await reset_pilot_database(maint, connect=connect_peer, db_name=db34b,
                                       seed=seed34b, **_RESET_ARGS)
        except Exception as exc:
            check(False, "㉞b 前置：reset 必须成功", f"抛了：{type(exc).__name__}: {exc}")
        left = await maint.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db34b)
        check(left == 0,
              "㉞b DROP 之后那条 db_oid=NULL 的陈旧凭据也被清掉了",
              f"事后仍有 {left} 条 —— 它会把重建卡成 intent_row_conflict")
        try:
            await create_pilot_database(maint, connect=connect_peer, db_name=db34b,
                                        seed=seed34b,
                                        run_id=f"lifecycle-{seed34b}-rebuild",
                                        **_BUILD_ARGS)
            check(True, "㉞b 紧接着用**新 run_id** 重建成功（没被陈旧凭据卡死）")
        except Exception as exc:
            check(False, "㉞b 紧接着用**新 run_id** 重建成功（没被陈旧凭据卡死）",
                  f"重建抛了：{type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db34b)

    # ── ㉘ 零对象例外的【绝对空】复查必须**紧贴 DROP**（2b R2-F1）────────
    #    授权理由就是「这个库当时是空的」，而那是一个**会过期的事实**。
    #    这里在 DROP 前的那次复查连进目标库**之前**往库里建一张表，
    #    模拟 `pg_restore --create` 或人工建表挤进那个窗口。
    scenario("㉘")
    print("㉘ 判定之后、DROP 之前库变得不空 → 必须拒绝 DROP")
    seed28 = "lifecycle_r28"
    db28 = f"kline_pilot_{seed28}"
    # ⚠️ 只数**连向目标库**的连接：集群闸 (ii) 会跳过目标库，故连它的只有
    #    `_probe_absolutely_empty`（例外判定里两次：初判 + 紧贴复查）与封锁临界区
    #    持住的那一条。**第 3 次就是封锁下的那一次**。
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
        # 先证明注入真的插进了那个窗口，否则上面那条是恒真的。
        check(injected == [3],
              "㉘ 前置：建表确实插在封锁下那次复查之前",
              f"连向目标库的次数 = {probe_calls['n']}，注入点 = {injected}")
        check(await _database_exists(maint, db28), "㉘ 拒绝之后目标库仍然存在")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db28)

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
            await create_pilot_database(conn, connect=connect_peer, db_name=db38,
                                        seed=seed38,
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

    # ── ㊴ `db_oid` 为空的凭据不许被当成「库已不存在」（Kimi S3-WB-R3）──────────
    #    `_INSERT_INTENT_SQL` **不写 db_oid** —— 确认那一步才写。故「INSERT intent →
    #    CREATE DATABASE 成功 → 崩在确认之前」这个窗口（两阶段建库存在的全部理由）
    #    留下的正是一行**新鲜的、db_oid 为空**的行，而那个库**真的存在**。
    #    SQL 里 `d.oid = NULL` 求值为 NULL → `NOT EXISTS` **恒真** ——
    #    这条三值逻辑**假件根本不求值**（它的 DELETE 不是真的在跑 SQL），只有真库能证。
    #    ⚠️ **双向**：新鲜的不许删（否则删掉一次进行中/崩溃中建库的凭据），
    #       超期的照样要删（否则「db_oid 为空」就等于**永不过期**，永久占住库名）。
    scenario("㊴")
    print("㊴ db_oid 为空的凭据：新鲜的不许删、超期的照样删")
    seed39 = "lifecycle_r39"
    db39 = f"kline_pilot_{seed39}"
    conn = await _connect(base_dsn)
    try:
        await harness.drop_database(base_dsn, db39)
        await conn.execute("CREATE DATABASE " + quote_ident(db39))   # 建**成功了**
        await conn.execute("DELETE FROM public.pilot_create_intent")
        # 崩在确认之前：create_confirmed=false，且 **db_oid 为空**（列默认就是 NULL）
        await conn.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed)"
            " VALUES ($1, $2, $3, $4, false)",
            db39, seed39, _CREATED_AT, f"lifecycle-{seed39}")
        # ⚠️ 前置：这一行的 db_oid 真的是 NULL，且库真的在 —— 否则本档测的是别的东西。
        check(bool(await conn.fetchval(
            "SELECT db_oid IS NULL FROM public.pilot_create_intent WHERE dbname = $1", db39)),
            "㊴ 前置：那一行的 db_oid 确实为空")
        check(await _database_exists(conn, db39), "㊴ 前置：那个库确实存在")

        took39: list[str] = []

        async def _try39(seed_of_row):
            took39.append(seed_of_row)
            return bool(await conn.fetchval(
                "SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))", seed_of_row))

        async def _rel39(seed_of_row):
            await conn.execute(
                "SELECT pg_advisory_unlock(hashtext('kline_pilot_' || $1))", seed_of_row)

        cluster_sql = (_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8")

        # ── 第一向：新鲜 → 必须留下 ──────────────────────────────────
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_try39, release_seed_lock=_rel39)
        except Exception as exc:
            check(False, "㊴ init 本身必须跑完（第一向）",
                  f"抛了：{type(exc).__name__}: {exc}")
        fresh_left = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db39)
        check(fresh_left == 1,
              "㊴ 新鲜的、db_oid 为空的凭据**没有**被当成「库已不存在」删掉",
              f"事后剩 {fresh_left} 条 —— `d.oid = NULL` 让 NOT EXISTS 恒真了")

        # ── 第二向：改成超期 → 必须删掉（证明第一向不是「永不过期」）──────
        await conn.execute(
            "UPDATE public.pilot_create_intent"
            "   SET inserted_at = statement_timestamp() - make_interval(secs => $2)"
            " WHERE dbname = $1", db39, float(INTENT_TTL_SECONDS + 60))
        try:
            await init_cluster_marker(conn, connect=connect_peer,
                                      cluster_schema_sql=cluster_sql,
                                      try_seed_lock=_try39, release_seed_lock=_rel39)
        except Exception as exc:
            check(False, "㊴ init 本身必须跑完（第二向）",
                  f"抛了：{type(exc).__name__}: {exc}")
        # 前置：第二向确实走到了取锁那一步（第一向不该走到）
        check(took39 == [seed39],
              "㊴ 前置：只有超期那一向去取了锁（新鲜那一向应当在预筛就跳过）",
              f"try_seed_lock 收到的 seed 列表 = {took39}")
        stale_left = await conn.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db39)
        check(stale_left == 0,
              "㊴ 超期之后照样被清掉（db_oid 为空**不等于**永不过期）",
              f"事后仍有 {stale_left} 条")
        check(not await conn.fetchval(_SEED_LOCK_HELD_SQL, seed39),
              "㊴ init 返回后维护连接上不再持有那把 seed 锁")
        await conn.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db39)
    finally:
        await conn.close()
    await harness.drop_database(base_dsn, db39)

    # ── ㉜ 集群闸读过目标库之后立刻 --reset → 必须成功（R12-F1 的正向钉）────────
    #    ⚠️ 本档的独立价值是**正向钉** —— 防「实现为了省事把 reset 一律拒掉」
    #       那一类回归（与 ⑨/⑰ 同族）。
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

    # ── ㉟ **正常路**的前提也会在窗口里失效（codex 4a-2 R15-F1，high）────────
    #    零对象例外那条路的「紧贴复查」由 ㉘ 钉着；本档钉的是**另一条路** ——
    #    走闸 0−/0/0b 过闸之后、DROP 之前，把 `pilot_meta.seed` 改掉。
    #
    #    注入点的算法（不是猜的，按代码路径数出来的）：走 `reset_pilot_database`
    #    的正常路一共连**三次**目标库 ——
    #      1 `try_empty_remnant_exception` 的【绝对空】初判（库非空 → 例外不适用）
    #      2 `assert_db_allowed_for_reset` 的 `_open_target`（读 pilot_meta 过闸）
    #      3 封锁临界区持住的那条（**本档要打的就是这次之前**）
    #    集群闸 (ii) 会跳过目标库自己，故不计数。
    scenario("㉟")
    print("㉟ 正常 reset 过闸之后、DROP 之前**归属**被改掉 → 必须拒绝且库仍在")
    seed35 = "lifecycle_r35"
    db35 = await _build(base_dsn, seed35, connect_peer)
    conn = await _connect(base_dsn)
    try:
        limit_before = await conn.fetchval(
            "SELECT datconnlimit FROM pg_database WHERE datname = $1", db35)
    finally:
        await conn.close()
    calls35 = {"n": 0}
    injected35: list[int] = []

    async def _connect_tampering(name: str):
        if name == db35:
            calls35["n"] += 1
            if calls35["n"] == 3:
                await _in_db(base_dsn, db35,
                             "UPDATE public.pilot_meta SET value = 'someone_else'"
                             " WHERE key = 'seed'")
                injected35.append(calls35["n"])
        return await connect_peer(name)

    maint = await _maintenance(base_dsn, seed=seed35)
    try:
        try:
            await reset_pilot_database(maint, connect=_connect_tampering,
                                       db_name=db35, seed=seed35, **_RESET_ARGS)
            check(False, "㉟ 归属在窗口里被改掉的库必须拒绝 DROP", "竟然删掉了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "not_owned",
                  "㉟ 窗口里归属被改 → 拒绝 DROP（not_owned）", f"实得 {exc.code}：{exc}")
        # ⚠️ 先证明注入**真的**插进了那个窗口，否则上面那条是恒真的
        #    （与 ㉘ 同一条纪律：夹具没生效时「拒了」也可能是别的原因）。
        check(injected35 == [3],
              "㉟ 前置：改归属确实插在封锁下那次连接之前",
              f"连向目标库的次数 = {calls35['n']}，注入点 = {injected35}")
        check(await _database_exists(maint, db35), "㉟ 拒绝之后目标库仍然存在")
        limit_after = await maint.fetchval(
            "SELECT datconnlimit FROM pg_database WHERE datname = $1", db35)
        check(limit_after == limit_before,
              "㉟ 拒绝之后连接数上限被还回原值（没把库留在半封锁状态）",
              f"封锁前 {limit_before!r}，事后 {limit_after!r}")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db35)

    # ── ㉟b **绑定**被改掉那一向（塌缩设计 §六：㉟ 必须改判据，别照搬）────────
    #    ⚠️ 这一档是 ㉟ 的**判别力补丁，不是重复**：㉟ 改的是 `seed`，
    #       它在封锁下的复验里被**闸 0（归属）**拦住 —— 而闸 0b（绑定）与令牌那一段
    #       **一次都没求值**。只有 ㉟ 的话，把复验里绑定/令牌那半整个删掉，㉟ 照样绿。
    #    ⚠️ 判据是 `reset_foreign_token_required`（不是旧实现的 `binding_mismatch`）：
    #       塌缩之后复验就是拿**本次入参**重跑闸 0b —— 绑定不符时它要的是令牌，
    #       而本次调用没带。
    scenario("㉟b")
    print("㉟b 正常 reset 过闸之后、DROP 之前**绑定**被改掉 → 必须要令牌，且库仍在")
    seed35b = "lifecycle_r35b"
    db35b = await _build(base_dsn, seed35b, connect_peer)
    calls35b = {"n": 0}
    injected35b: list[int] = []

    async def _connect_tampering_binding(name: str):
        if name == db35b:
            calls35b["n"] += 1
            if calls35b["n"] == 3:
                await _in_db(base_dsn, db35b,
                             "UPDATE public.pilot_meta SET value = '/someone_else'"
                             " WHERE key = 'output_dir'")
                injected35b.append(calls35b["n"])
        return await connect_peer(name)

    maint = await _maintenance(base_dsn, seed=seed35b)
    try:
        try:
            await reset_pilot_database(maint, connect=_connect_tampering_binding,
                                       db_name=db35b, seed=seed35b, **_RESET_ARGS)
            check(False, "㉟b 绑定在窗口里被改掉的库必须拒绝 DROP", "竟然删掉了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "reset_foreign_token_required",
                  "㉟b 窗口里绑定被改 → 复验重跑闸 0b，要令牌（reset_foreign_token_required）",
                  f"实得 {exc.code}：{exc}")
            check(exc.confirm_token is not None,
                  "㉟b 拒绝时经**专用通道**给出该库此刻的确认令牌（操作者的下一步）",
                  f"confirm_token={exc.confirm_token!r}")
        check(injected35b == [3],
              "㉟b 前置：改绑定确实插在封锁下那次连接之前",
              f"连向目标库的次数 = {calls35b['n']}，注入点 = {injected35b}")
        check(await _database_exists(maint, db35b), "㉟b 拒绝之后目标库仍然存在")
    finally:
        await maint.close()
    await harness.drop_database(base_dsn, db35b)

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
    # ⚠️ **这段话必须说清楚本脚本到底证明了什么**（codex S2a-R1-F2）：
    #    「静默没验」与「验过了」在输出上完全一样。少写一句，读的人就会
    #    把一份局部保证当成整组的 ship gate —— 本仓反复栽的
    #    「宣称的保证 > 实际提供的保证」。
    print("✅ 既有覆盖（S2b′）—— `--reset` 的**执行面**：DROP 真的执行得下去（⑨⑬⑰㉜）、")
    print("   封锁下的【绝对空】/ 归属 / 绑定紧贴复验（㉘ ㉟ ㉟b）、占用者预检（㉜b）、")
    print("   DROP 后的凭据清理与重建（㉞ ㉞b）。")
    print("✅ 本片（S3）在此基础上补齐 `--init-cluster-marker`：零副作用预检（⑤ ⑤b）、")
    print("   标记不得短路现查（㉙）、孤儿 intent 清理的取锁/还锁（㉚）、")
    print("   锁内当下求值（㊱）、长事务下的 TTL 时钟源（㊲，与 ㉝c 同族）、")
    print("   混合态修复认同侪库归属登记的**双向**证明（㊳），")
    print("   以及 db_oid 为空的凭据不被当成「库已不存在」（㊴，双向）。")
    print("⚠️ 仍**没有**覆盖的：")
    print("     · 「不数 autovacuum worker」那一向没有常驻档（要改集群 autovacuum_naptime，")
    print("       对验收脚本太侵入）—— 由一次性真 PG 实验坐实并记进计划，如实登记。")
    print("⛔ 因此本脚本**此刻仍不是** spec §6.2 生命周期那一组的完整 ship gate。")
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
