#!/usr/bin/env python3
"""验证 4a-1 两阶段建库在**真 PostgreSQL** 上的事务边界与崩溃安全。

背景：whole-branch 终审（O4-W1）指出，`create_pilot_database` 曾把
`backend/sql/schema.sql` 放进 `async with conn.transaction():`，而那个文件
**自带 `BEGIN;`（第 6 行）/ `COMMIT;`（第 111 行）**。真 PG 上的后果是：

  · 文件里那句 `COMMIT` **提交掉外层事务**，其后语句全部退化成各自 autocommit；
  · asyncpg 的 `Transaction.__aexit__` 在事务已不存在时**静默返回、不抛异常**。

于是「注释与测试都声称有原子性、真库上没有」——**没有任何测试会红、
没有任何运行时错误会提示**。它之所以逃过 host 单测的 6 个建库用例，
直接原因是那 6 个传的都是 `schema_sql="CREATE TABLE IF NOT EXISTS klines ();"`
这种玩具串，**没有一条走真文件**；`_FakeConn.transaction()` 是纯 Python 计数器，
在结构上不可能建模「SQL 文本自己含 COMMIT」。

**本脚本存在的唯一理由，就是这一档只有真 PG 能证伪。**

用法（需真 PG；DSN 指向的库里会建/删 `kline_pilot_selfcheck_*`）：

    docker run --rm -d --name pg4a -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:15.12
    DSN='postgresql://postgres:postgres@localhost:55432/postgres' \
      .venv/bin/python backend/scripts/verify_pilot_two_phase_create.py
    docker rm -f pg4a

退出码 0 = 全部档位的断言都成立。非 0 = 事务边界或崩溃安全不符设计，**必须停下**，
不要因为 host 单测绿就当它成立。
"""
from __future__ import annotations

import asyncio
import os
import pathlib
import re
import sys
from urllib.parse import urlparse

import asyncpg

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import _pilot_verify_harness as harness  # noqa: E402
from qmt_pilot_db import (PILOT_META_KEYS, PILOT_META_PHASE1_KEYS,  # noqa: E402
                          PILOT_META_PHASE2_KEYS, _is_absolutely_empty,
                          _SEED_LOCK_HELD_SQL, _user_objects, create_pilot_database,
                          PilotClusterBoundaryError, assert_cluster_allowed,
                          pin_search_path, quote_ident, sha256_of_sql,
                          CANONICAL_BUSINESS_CATALOG_SHA256,
                          _BUSINESS_CATALOG_FINGERPRINT_SQL,
                          read_pilot_meta_rows)

_BACKEND = pathlib.Path(__file__).resolve().parents[1]
# 本脚本只会造/删这个形状的库；前置清场只敢删符合它的（O4-R20-C1）。
_SELFCHECK_NAME_RE = re.compile(r"\Akline_pilot_selfcheck[a-z0-9_]*\Z")
# ⚠️ 验收闸的**完整性清单**（O4-R31-C1）：收尾核对每一档都真的跑过。
#    少一档即失败 —— **「静默没跑」与「通过了」在输出上完全一样**，
#    这与本仓反复栽过的「空转的检查比没有检查更糟」是同一族。
#    新增场景时把标记加进来；忘了加，那一档就永远不会被要求执行。
# ⚠️ **前置清场只删这张精确清单里的库**（O4-R33-C2）：上一版按
#    `LIKE 'kline_pilot_selfcheck%'` 枚举后**先删再说** —— 本地/共享的 PostgreSQL 上
#    真有人用这个前缀建了库的话，会在任何标记、登记行、白名单校验之前就被**不可逆地删掉**。
#    localhost 闸挡不住这一档（它挡的是「别指向远端」，不是「别删本地别人的库」）。
#    匹配前缀但不在清单里的，**打印出来并中止**，除非显式设 QMT_VERIFY_FORCE_CLEANUP=1。
#    清单由 `test`-style 自检钉住：脚本源码里出现的每个 selfcheck 库名都必须在这里。
# 本脚本在目标/维护库里造的**临时对象**（O4-R34-C2）。前缀 `zzqmtverify_` 表明归属；
# 清场只删这张清单里的名字，且名字必须带该前缀（由下方自检钉住）。
_SCRATCH_OBJECTS = (
    ("TABLE", "public.zzqmtverify_probe_a"),
    ("TABLE", "public.zzqmtverify_probe_b"),
    ("SCHEMA", "zzqmtverify_shadow_ns"),
    ("SCHEMA", "zzqmtverify_poison_ns"),
)

_SCENARIO_DBS = (
    "kline_pilot_selfcheck_ok",
    "kline_pilot_selfcheck_p1",
    "kline_pilot_selfcheck_p10",
    "kline_pilot_selfcheck_p11",
    "kline_pilot_selfcheck_p12",
    "kline_pilot_selfcheck_p13",
    "kline_pilot_selfcheck_p13x",
    "kline_pilot_selfcheck_p16",
    "kline_pilot_selfcheck_p17",
    "kline_pilot_selfcheck_p18",
    "kline_pilot_selfcheck_p19a",
    "kline_pilot_selfcheck_p19b",
    "kline_pilot_selfcheck_p2",
    "kline_pilot_selfcheck_p20",
    "kline_pilot_selfcheck_p20b",
    "kline_pilot_selfcheck_p21",
    "kline_pilot_selfcheck_p22",
    "kline_pilot_selfcheck_p23",
    "kline_pilot_selfcheck_p23v",
    "kline_pilot_selfcheck_p24",
    "kline_pilot_selfcheck_p25",
    "kline_pilot_selfcheck_p26",
    "kline_pilot_selfcheck_p27",
    "kline_pilot_selfcheck_p27x",
    "kline_pilot_selfcheck_p3",
    "kline_pilot_selfcheck_p4",
    "kline_pilot_selfcheck_p5",
    "kline_pilot_selfcheck_p6",
    "kline_pilot_selfcheck_p7",
    "kline_pilot_selfcheck_p8",
)

_EXPECTED_SCENARIOS = ("①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑧b", "⑨", "⑩",
                       "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳",
                       "㉑", "㉒", "㉓", "㉔", "㉕", "㉖", "㉗")

_SCHEMA_SQL = (_BACKEND / "sql/schema.sql").read_text(encoding="utf-8")
_PILOT_SCHEMA_SQL = (_BACKEND / "sql/pilot_schema.sql").read_text(encoding="utf-8")
class _PostSchemaSaboteur:
    """代理目标库连接：**规范 `schema.sql` 跑完之后**立刻执行一段敌意 DDL。

    ⚠️ 为什么不再把敌意语句拼进 `schema_sql`（O4-R30-C1 之后）：两份 .sql 已被钉死到
    仓库里的规范指纹，**「敌意 schema.sql」这条路径不再可达** —— 拼出来的 SQL 会在
    进场那一关就被拒，场景根本走不到它要测的 post-apply 判据。
    现在这些判据要防的真实威胁是「apply 之后、判据之前库被弄坏」（并发的手、
    残留的对象、PG 侧异常），注入点改到连接上正是这个模型。
    """

    def __init__(self, conn, sabotage: str) -> None:
        self._conn = conn
        self._sabotage = sabotage
        self._fired = False

    def transaction(self):
        return self._conn.transaction()

    async def execute(self, query: str, *args, **kwargs):
        out = await self._conn.execute(query, *args, **kwargs)
        if not self._fired and query == _SCHEMA_SQL:
            self._fired = True
            await self._conn.execute(self._sabotage)
        return out

    async def fetch(self, query: str, *args):
        return await self._conn.fetch(query, *args)

    async def fetchval(self, query: str, *args):
        return await self._conn.fetchval(query, *args)

    async def fetchrow(self, query: str, *args):
        return await self._conn.fetchrow(query, *args)

    async def close(self) -> None:
        await self._conn.close()

    @property
    def fired(self) -> bool:
        return self._fired


class _ReplaceTargetMaint:
    """代理**维护**连接：在 `trigger` 命中的那一刻，把目标库删掉再用同名重建。

    模型是「`CREATE DATABASE` 成功之后、凭据落库之前，另一只手把它换掉了」——
    正是 oid 绑定要防的那个窗口。注入点必须在**连接层**：写成「测试里先建再删」
    的话，被测代码走的是另一条时间线，那个窗口一次都没被打开过。

    ⚠️ DROP/CREATE 走**另开的一条连接**：借用被测连接会把它自己的语句序列搅乱，
    而序列正是这一档要观察的东西。
    """

    def __init__(self, conn, base_dsn: str, db: str, trigger) -> None:
        self._conn, self._dsn, self._db, self._trigger = conn, base_dsn, db, trigger
        self.replacement_oid = None

    def transaction(self):
        return self._conn.transaction()

    async def _maybe(self, kind: str, query: str) -> None:
        if self.replacement_oid is not None or not self._trigger(kind, query):
            return
        side = await asyncpg.connect(self._dsn)
        try:
            await side.execute("DROP DATABASE " + quote_ident(self._db))
            await side.execute(
                "CREATE DATABASE " + quote_ident(self._db) + " TEMPLATE template0")
            self.replacement_oid = await side.fetchval(
                "SELECT oid FROM pg_database WHERE datname::text = $1", self._db)
        finally:
            await side.close()

    async def execute(self, query: str, *args, **kwargs):
        out = await self._conn.execute(query, *args, **kwargs)
        await self._maybe("execute", query)
        return out

    async def fetch(self, query: str, *args):
        out = await self._conn.fetch(query, *args)
        await self._maybe("fetch", query)
        return out

    async def fetchval(self, query: str, *args):
        out = await self._conn.fetchval(query, *args)
        await self._maybe("fetchval", query)
        return out

    async def fetchrow(self, query: str, *args):
        out = await self._conn.fetchrow(query, *args)
        await self._maybe("fetchrow", query)
        return out

    async def close(self) -> None:
        await self._conn.close()


def _saboteur(base_dsn: str, sabotage: str):
    """返回一个 connect 工厂：连上目标库，并在规范 schema 跑完后注入 `sabotage`。"""
    holder = {}

    async def _connect(name: str):
        proxy = _PostSchemaSaboteur(await asyncpg.connect(_db_dsn(base_dsn, name)), sabotage)
        holder["proxy"] = proxy
        return proxy

    return _connect, holder


def _schema_plus(*extra: str) -> str:
    """真 `schema.sql` + 若干条敌意语句（插在收尾 `COMMIT;` 之前）。

    ⚠️ 场景**必须用真业务 schema**（O4-R29-C2 之后）：守卫另立了一条**外部**判据 ——
    不管调用方递进来的是什么 SQL，`REQUIRED_BUSINESS_TABLES` 那几张表必须齐。
    玩具 schema（只建一张 klines）会在那条判据上先失败，于是场景根本走不到它要测的地方
    （实测：一次改动同时把六档顶红，红的原因与被测行为无关）。
    """
    body = _SCHEMA_SQL.rstrip()
    assert body.endswith("COMMIT;"), "schema.sql 不是以 COMMIT; 收尾 —— 拼接前提不成立"
    return body[: -len("COMMIT;")] + "\n".join(extra) + "\nCOMMIT;"


_ARGS = dict(
    schema_sql=_SCHEMA_SQL,
    pilot_schema_sql=_PILOT_SCHEMA_SQL,
    # 指纹**由内容算**（O4-R19-C1）：模块会自校，配死值一律拒。
    schema_sha256=sha256_of_sql(_SCHEMA_SQL),
    pilot_schema_sha256=sha256_of_sql(_PILOT_SCHEMA_SQL),
    export_log_sha256="a" * 64,
    output_dir="/tmp/verify_pilot_two_phase",
    created_at="20260729T101530123456Z",
)


class _Boom(RuntimeError):
    """注入的崩溃。"""


class _BoomProxy:
    """代理真 asyncpg 连接，在写指定的 `pilot_meta` 键时抛异常。

    ⚠️ 必须用代理而不是猴补丁：asyncpg 的 `Connection.execute` 是只读属性。
    """

    def __init__(self, conn: asyncpg.Connection, trip_key: str | None) -> None:
        self._conn = conn
        self._trip_key = trip_key

    def transaction(self):
        return self._conn.transaction()

    async def execute(self, query: str, *args, **kwargs):
        # ⚠️ 匹配**不得依赖 schema 前缀**：SQL 从 `pilot_meta` 改成 `public.pilot_meta` 时，
        #    按旧文本匹配的注入器会**静默不触发** —— 崩溃从未发生，而「崩溃后应该怎样」
        #    的断言全部落空（实测：②③④ 三档同时假红）。这已是本轮第三次被脆弱子串咬到。
        if (self._trip_key and "pilot_meta" in query and "INSERT" in query.upper()
                and args and args[0] == self._trip_key):
            raise _Boom(f"注入：写 {self._trip_key!r} 时断连")
        return await self._conn.execute(query, *args, **kwargs)

    async def fetch(self, query: str, *args):
        return await self._conn.fetch(query, *args)

    async def fetchval(self, query: str, *args):
        return await self._conn.fetchval(query, *args)

    async def fetchrow(self, query: str, *args):
        return await self._conn.fetchrow(query, *args)

    async def close(self) -> None:
        await self._conn.close()


# ⚠️ 破坏性 DSN 闸 / 换库名 / 只对过闸 DSN 动手的 DROP，**三个验收脚本共用一份**
#    （见 `_pilot_verify_harness.py` 的头注）：各抄一份就是把「同一条判据只落在
#    被点名的那一处」这个本仓重演十二次的毛病，搬到**防止误删数据库**的代码上。
_assert_destructive_dsn_allowed = harness.assert_destructive_dsn_allowed
_db_dsn = harness.db_dsn


async def _maintenance(base_dsn: str, *, seed: str | None = None) -> asyncpg.Connection:
    """维护连接。传 `seed` 时**真的取**按 seed 的 advisory lock —— `create_pilot_database`
    现在会在活连接上验它（O4-R5-C2），不再信调用方传的布尔值。"""
    conn = await asyncpg.connect(base_dsn)
    # 维护库必须先被声明为 pilot 专用集群 —— `create_pilot_database` 现在会在内部
    # 机器强制地跑集群闸（O4-R5-C2），没有标记就建不了库。
    await conn.execute((_BACKEND / "sql/pilot_cluster_schema.sql").read_text())
    await conn.execute("INSERT INTO public.pilot_cluster_marker (purpose) VALUES ($1)"
                       " ON CONFLICT (purpose) DO NOTHING",
                       "qmt_pilot_disposable_cluster")
    if seed is not None:
        got = await conn.fetchval(
            "SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))", seed)
        if not got:
            raise RuntimeError(f"取不到 seed={seed!r} 的 advisory lock")
    # intent 表由 pilot_cluster_schema.sql **独家**定义（上面已 apply）——
    #    此处曾有第二份 CREATE TABLE，它少了 create_confirmed 列却因 IF NOT EXISTS 静默生效，
    #    正是「第二份定义悄悄漂移」的陷阱。
    return conn


async def _plain_connect_p27(name: str):
    """㉗b 的对端连接工厂（闸 (ii) 会逐个连进同侪库）。"""
    return await asyncpg.connect(_db_dsn(_P27_DSN["dsn"], name))


_P27_DSN = {"dsn": ""}


_drop = harness.drop_database


async def _read_meta(base_dsn: str, dbname: str) -> dict[str, str] | None:
    """读 `pilot_meta`；表不存在返回 None。"""
    conn = await asyncpg.connect(_db_dsn(base_dsn, dbname))
    try:
        try:
            rows = await conn.fetch("SELECT key, value FROM public.pilot_meta")
        except asyncpg.exceptions.UndefinedTableError:
            return None
        return {r["key"]: r["value"] for r in rows}
    finally:
        await conn.close()


async def _relation_exists(base_dsn: str, dbname: str, relname: str) -> bool:
    conn = await asyncpg.connect(_db_dsn(base_dsn, dbname))
    try:
        return bool(await conn.fetchval(
            "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
            "WHERE n.nspname = 'public' AND c.relname = $1", relname))
    finally:
        await conn.close()


async def _build(base_dsn: str, dbname: str, seed: str, trip_key: str | None) -> None:
    await _drop(base_dsn, dbname)
    maint = await _maintenance(base_dsn, seed=seed)

    async def connect(name: str):
        return _BoomProxy(await asyncpg.connect(_db_dsn(base_dsn, name)), trip_key)

    try:
        await create_pilot_database(maint, connect=connect, db_name=dbname,
                                    seed=seed, run_id=f"verify-{seed}", **_ARGS)
    finally:
        await maint.close()


async def main() -> int:
    base_dsn = os.environ.get("DSN")
    if not base_dsn:
        print("用法：DSN='postgresql://user:pw@host:port/postgres' "
              "python backend/scripts/verify_pilot_two_phase_create.py", file=sys.stderr)
        return 2

    # 隔离护栏（O4-R9-C2）：本脚本会 apply DDL 到 DSN 指向的库、并 DROP 一串
    # kline_pilot_selfcheck_* 库，还会临时把维护表改成畸形形态。指错 DSN 就是
    # 对共享库做这些事。同仓 verify_qmt_pg_chain.py / verify_repeatable_read_snapshot.py
    # 早就有这道闸 —— 是本脚本没跟上惯例。必须**先于任何 connect/DDL**。
    if _assert_destructive_dsn_allowed(base_dsn, "DSN") is None:
        return 3
    _P27_DSN["dsn"] = base_dsn

    # ⚠️ 白名单自检（O4-R33-C2）：新增场景时忘了把库名加进 `_SCENARIO_DBS`，
    #    那个库就会在收尾时留下来、并在下一次运行时把整个脚本挡住（strangers 分支）。
    #    ⚠️ 必须排在**破坏性清场之前** —— 它是纯源码检查、零副作用，
    #    放在清场之后的话，会被 strangers 闸先触发而永远测不到（实测踩过）。
    # ⚠️ 三条纯源码自检（零副作用），**必须排在破坏性清场之前**：放在清场之后会被
    #    strangers 闸先触发而永远测不到（实测踩过）。判据挂在**本脚本**的源码上，
    #    故把 `__file__` 传进 harness —— 用 harness 自己的 `__file__` 就成了恒真断言。
    for _rc in (harness.assert_every_dsn_env_is_gated(__file__),
                harness.assert_scratch_objects_are_namespaced(_SCRATCH_OBJECTS),
                harness.assert_every_selfcheck_db_is_whitelisted(
                    __file__, _SCENARIO_DBS, "kline_pilot_selfcheck")):
        if _rc is not None:
            return _rc

    # 前置清场：本脚本会在中途崩溃时留下 kline_pilot_selfcheck_* 库与登记行，
    # 而登记表按设计**永不清理**。不清场的话，下一次运行会被上一次的残留顶红，
    # 且红的位置（场景 ①）与真正的原因毫无关系 —— 实测踩过。
    _pre = await asyncpg.connect(base_dsn)
    try:
        await _pre.execute((_BACKEND / "sql/pilot_cluster_schema.sql").read_text())
        matched = [r["datname"] for r in await _pre.fetch(
            "SELECT datname FROM pg_database WHERE datname LIKE 'kline_pilot_selfcheck%'")]
        # ⚠️ 精确白名单（O4-R33-C2）：前缀匹配 ≠ 本脚本建的。
        leftovers = [x for x in matched if x in _SCENARIO_DBS]
        strangers = [x for x in matched if x not in _SCENARIO_DBS]
        if strangers and os.environ.get("QMT_VERIFY_FORCE_CLEANUP") != "1":
            print(f"拒绝运行：这些库名匹配 selfcheck 前缀但**不是本脚本建的**：{strangers}。"
                  f"本脚本会不可逆地删库，故不碰不认识的名字。"
                  f"确认它们可弃后设 QMT_VERIFY_FORCE_CLEANUP=1 重跑，或先自行删除。",
                  file=sys.stderr)
            return 4
        leftovers += strangers if os.environ.get("QMT_VERIFY_FORCE_CLEANUP") == "1" else []
        for name in leftovers:
            # ⚠️ 名字是从 pg_database 按 LIKE 读回来的，**不是常量**（O4-R20-C1）：
            #    PostgreSQL 的库名可以含引号/分号，而 asyncpg.execute 支持多语句 ——
            #    裸 f-string 拼接能让本脚本以 DSN（通常是超级用户）多跑一条 DROP，
            #    localhost 闸挡不住这一档（共享的本地开发集群同样中招）。
            #    **挡住注入的是 `quote_ident`**：它把名字变成字面标识符，内容再怪也无法逃逸。
            #    ⚠️ 曾经在这里加过一层「名字不合 `_SELFCHECK_NAME_RE` 就跳过」——**已撤掉**：
            #    它挡不住任何东西（转义已经挡住了），却制造了一个**不可恢复**的陷阱 ——
            #    上一次运行崩溃留下的怪名字库会被永远跳过，而它又会让集群闸判「存在无关数据库」，
            #    脚本从此再也跑不起来（实测踩到）。
            if not _SELFCHECK_NAME_RE.fullmatch(name):
                print(f"（清掉命名异常的残留库 {name!r} —— 它只可能是本脚本崩溃时留下的）")
            await _pre.execute("DROP DATABASE IF EXISTS " + quote_ident(name))
        await _pre.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname LIKE 'kline_pilot_selfcheck%'")
        await _pre.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname LIKE 'kline_pilot_selfcheck%'")
        # ⑭ 中途崩溃会留下影子目录 schema 与探针表 —— 它们是维护库里的**用户对象**，
        # 下一次运行会在场景 ① 就被闸 (iii) 顶红（与真因毫无关系）。
        # ⚠️ 这些临时对象**必须用明确属于本脚本的前缀**（O4-R34-C2）：
        #    上一版叫 `evil_catalog` / `tmp_probe_data` / `zz_evil` / `evil_user_data` ——
        #    全是会撞的通名，而清场是**无条件 DROP**。开发机或 CI 上任何人用了同名对象，
        #    就会在没有任何归属校验的情况下被删掉。
        #    （上一轮 O4-R33-C2 只把**库名**的盲删改成了白名单，**这一段漏了** ——
        #     同一族「只修被点名的那一处」在本 PR 里的又一次。）
        #    改名之后残余风险是「有人恰好也用 zzqmtverify_ 前缀」，可忽略；
        #    这些名字同时进 _SCRATCH_OBJECTS，由源码自检钉住不许再出现通名。
        for _obj_kind, _obj in _SCRATCH_OBJECTS:
            await _pre.execute(f"DROP {_obj_kind} IF EXISTS {_obj} CASCADE"
                               if _obj_kind == "SCHEMA" else
                               f"DROP {_obj_kind} IF EXISTS {_obj}")
        if leftovers:
            print(f"（前置清场：删掉上一次运行残留的 {leftovers}）")
    finally:
        await _pre.close()

    failures: list[str] = []
    ran: set[str] = set()

    def scenario(tag: str) -> None:
        """登记「这一档真的跑到了」。收尾会核对 `_EXPECTED_SCENARIOS` 一个不缺。

        ⚠️ 存在的理由（O4-R31-C1）：上一版 ㉔ 缺 DSN2 时只打印一行「跳过」，
        退出码与结尾摘要照样全绿 —— **一档静默没跑，与它通过了，在输出上完全一样**。
        这与本仓反复栽过的「空转的检查比没有检查更糟」是同一族。
        """
        ran.add(tag)


    def check(ok: bool, label: str, detail: str = "") -> None:
        # ⚠️ detail 只在**失败**时打印 —— 它写的是失败时的解释，
        #    在 PASS 行上打出来会让读者误判成失败。
        print(f"  {'PASS' if ok else 'FAIL'}  {label}"
              + ("" if ok else f"  —— {detail}" if detail else ""))
        if not ok:
            failures.append(label)

    # ── ① 正常建库：真 asyncpg + 真 schema 文件走完全程 ────────────────
    scenario("①")
    print("① 正常建库（真 schema 文件，无注入）")
    db = "kline_pilot_selfcheck_ok"
    await _build(base_dsn, db, "selfcheck_ok", trip_key=None)
    meta = await _read_meta(base_dsn, db)
    check(meta is not None and set(meta) == set(PILOT_META_KEYS),
          "九键齐全", f"实得 {len(meta or {})} 键")
    check(bool(meta) and meta.get("state") == "ready", "state == 'ready'")
    check(await _relation_exists(base_dsn, db, "klines"), "schema.sql 的 klines 已建")
    check(await _relation_exists(base_dsn, db, "pilot_stock_source"),
          "pilot_schema.sql 的 pilot_stock_source 已建")
    # ⚠️ 断言**数据库状态**，不是「发过一条 DELETE」（O4-R10-C1）：R9 那次回归里
    #    语句照发不误，只是带着 `NOT create_confirmed` 一行都没匹配上 ——
    #    每次正常成功都留下一行「新鲜且已确认」的 intent（既挡住后来者，又是销毁授权）。
    maint = await _maintenance(base_dsn)
    try:
        left = await maint.fetch(
            "SELECT run_id, create_confirmed FROM public.pilot_create_intent WHERE dbname = $1", db)
    finally:
        await maint.close()
    check(not left, "成功建库后 intent 行必须**真的不在了**",
          f"残留 {[dict(r) for r in left]} —— 这是一张持久的销毁授权")
    await _drop(base_dsn, db)

    # ── ② 阶段 1 中途崩 → 整体回滚（这一档证明阶段 1 的事务是真的）──────
    scenario("②")
    print("\n② 阶段 1 写第 4 个键时崩 → pilot_meta 必须**整体回滚**")
    db = "kline_pilot_selfcheck_p1"
    try:
        await _build(base_dsn, db, "selfcheck_p1", trip_key="output_dir")
    except _Boom:
        pass
    meta = await _read_meta(base_dsn, db)
    check(not meta, "pilot_meta 表不存在或为空（阶段 1 事务真有效）",
          f"残留 {sorted(meta)}" if meta else "")
    await _drop(base_dsn, db)

    # ── ③ schema.sql 已提交、补写指纹键时崩 → 文档化的残余窗口 ─────────
    #    这一档**不是缺陷**：schema.sql 自带事务，它与后续两键不可能原子。
    #    spec §4 已如实登记，且由 O4-F8 兜底（复用被拒 + db_state_initializing）。
    scenario("③")
    print("\n③ schema.sql 已提交、补写指纹键时崩 → 残余窗口须落在 O4-F8 的兜底里")
    db = "kline_pilot_selfcheck_p2"
    try:
        await _build(base_dsn, db, "selfcheck_p2", trip_key="schema_sha256")
    except _Boom:
        pass
    meta = await _read_meta(base_dsn, db) or {}
    check(set(meta) == set(PILOT_META_PHASE1_KEYS),
          "键集合恰为阶段 1 的 7 个", f"实得 {sorted(meta)}")
    check(meta.get("state") == "initializing",
          "state == 'initializing'（复用会被 db_state_initializing 拒、--reset 可清）")
    check(await _relation_exists(base_dsn, db, "klines"),
          "klines 已建（schema.sql 自己的事务已提交）")
    maint = await _maintenance(base_dsn)
    try:
        rows = await maint.fetch(
            "SELECT dbname, run_id FROM public.pilot_create_intent WHERE dbname = $1", db)
    finally:
        await maint.close()
    check(len(rows) == 1 and rows[0]["run_id"] == "verify-selfcheck_p2",
          "异常路径上 intent 行**保留**且带本次 run_id（它是下次的销毁授权）",
          f"实得 {[dict(r) for r in rows]}")
    await _drop(base_dsn, db)

    # ── ④ **唯一能区分「修好」与「没修好」的一档**（自查补）────────────
    #    ①②③ 三档在**中和掉 C1 修复之后照样全 PASS** —— 实测过，脚本一度是 vacuous 的：
    #      · ① 正常路径两种设计都通；
    #      · ② 阶段 1 本来就一直是对的（pilot_schema.sql 不自带事务）；
    #      · ③ 在**第一个**阶段-2 键上注入 → 两种设计都是「什么都没写」，结果相同。
    #    判别点必须放在**第二个**阶段-2 键上：
    #      · 修好的版本：阶段 2 是一个独立事务 → 整体回滚 → `schema_sha256` **不在**；
    #      · 坏的版本：外层事务已被 schema.sql 的 COMMIT 提交掉 → 前一条 INSERT
    #        **已 autocommit 落库** → `schema_sha256` **仍在**。
    scenario("④")
    print("\n④ 在**第二个**阶段-2 键上崩 → 阶段 2 必须整体回滚（判别 C1 是否真的修好）")
    # ⚠️ 注入点与断言**必须从常量派生**（O4-W2r1 I-2）：写死 "contract_version" 时，
    #    任何人把 PILOT_META_PHASE2_KEYS 重排（语义无差别、host 全绿，因为钉它的测试用的是
    #    `set(...)` 比较、**顺序没被钉住**），④ 就退化成「在第一个键上注入」= 与 ③ 等价，
    #    脚本**静默变回 vacuous 且 EXIT=0** —— 正是刚修掉的失效形态从没人看守的入口重新可达。
    if len(PILOT_META_PHASE2_KEYS) < 2:
        print("  FAIL  PILOT_META_PHASE2_KEYS 少于 2 个键 —— ④ 无判别力，脚本失去意义")
        return 1
    first_key, second_key = PILOT_META_PHASE2_KEYS[0], PILOT_META_PHASE2_KEYS[1]
    db = "kline_pilot_selfcheck_p3"
    try:
        await _build(base_dsn, db, "selfcheck_p3", trip_key=second_key)
    except _Boom:
        pass
    meta = await _read_meta(base_dsn, db) or {}
    check(first_key not in meta,
          f"{first_key} 已随阶段 2 事务回滚",
          f"仍在库里 → schema.sql 的 COMMIT 拆掉了外层事务（C1 未修好）：{sorted(meta)}")
    check(set(meta) == set(PILOT_META_PHASE1_KEYS),
          "键集合仍恰为阶段 1 的 7 个", f"实得 {sorted(meta)}")
    await _drop(base_dsn, db)

    # ── ⑤ 【绝对空】的结构性判据 —— **只有真 PG 能验**（O4-R2-C1）────────
    #    host 层的假件不执行 SQL，改判据的 SQL 文本它看不见（实测：中和后零测试变红）。
    #    这一档造的正是 codex 点名、旧六条枚举判据全返回 0 的那个对象。
    scenario("⑤")
    print("\n⑤ 【绝对空】必须抓到旧枚举判据漏掉的对象（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p4"
    await _drop(base_dsn, db)
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("CREATE DATABASE " + quote_ident(db) + " TEMPLATE template0")
    finally:
        await maint.close()
    probe = await asyncpg.connect(_db_dsn(base_dsn, db))
    try:
        check(await _is_absolutely_empty(probe), "刚建的库判为【绝对空】")
        # ⚠️ **低 OID 大对象**（O4-R3-C1）：`lo_create(oid)` 允许调用方自选 OID，
        #    实测 `lo_create(100)` 造出 oid=100 → 全局 oid 阈值看不见它。
        #    先断言「刚建的库该目录为 0 行」，「任何行 = 用户对象」这条才成立。
        check(await probe.fetchval("SELECT count(*) FROM pg_largeobject_metadata") == 0,
              "刚建的库里 pg_largeobject_metadata 为 0 行（「任何行=用户对象」的前提）")
        await probe.execute("SELECT lo_create(100)")
        check(not await _is_absolutely_empty(probe),
              "低 OID 大对象（lo_create(100)）必须让【绝对空】失效",
              "判据没看见它 → 装着用户数据的库可被无凭据 DROP")
        await probe.execute("SELECT lo_unlink(100)")
        check(await _is_absolutely_empty(probe), "删掉大对象后恢复判空")

        for ddl, label in (("CREATE COLLATION public.c1 (locale = 'C')", "自定义 collation"),
                           ("CREATE MATERIALIZED VIEW public.mv AS SELECT 1 AS x", "物化视图"),
                           ("CREATE TEXT SEARCH CONFIGURATION public.ts (parser = default)",
                            "文本搜索配置")):
            await probe.execute(ddl)
            objs = await _user_objects(probe)
            check(bool(objs), f"{label} 必须让【绝对空】失效", "判据没看见它 → 可被无凭据 DROP")
            await probe.execute(ddl.replace("CREATE ", "DROP ", 1).split(" (")[0]
                                .replace("AS SELECT 1 AS x", ""))
    finally:
        await probe.close()
    await _drop(base_dsn, db)

    # ── ⑥ 敌意 search_path 下归属证明不得被冒充（O4-R4-C1，只有真 PG 能验）──────
    scenario("⑥")
    print("\n⑥ 敌意 search_path：结构验一张表、值读另一张表（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p5"
    await _drop(base_dsn, db)
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("CREATE DATABASE " + quote_ident(db) + " TEMPLATE template0")
    finally:
        await maint.close()
    probe = await asyncpg.connect(_db_dsn(base_dsn, db))
    try:
        await probe.execute("CREATE TABLE public.pilot_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        await probe.execute("CREATE SCHEMA evil")
        await probe.execute("CREATE TABLE evil.pilot_meta (key TEXT, value TEXT)")
        await probe.execute("INSERT INTO evil.pilot_meta VALUES ('tool','qmt_pilot')")
        await probe.execute("SET search_path = evil, public")
        meta = await read_pilot_meta_rows(probe)
        check(meta.get("tool") is None,
              "敌意 search_path 下不得读到 evil.pilot_meta 的伪造行",
              f"读到了 {meta} —— 一个不属于本工具的库凭一行伪造记录冒充归属成功")
    finally:
        await probe.close()
    await _drop(base_dsn, db)

    # ── ⑦ 闸 (iii) 的豁免不得盖住**用户造的**依赖物（O4-R5-C1，只有真 PG 能验）──
    scenario("⑦")
    print("\n⑦ 用户造的依赖物不得被闸 (iii) 的豁免盖住（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p6"
    await _drop(base_dsn, db)
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("CREATE DATABASE " + quote_ident(db) + " TEMPLATE template0")
    finally:
        await maint.close()
    probe = await asyncpg.connect(_db_dsn(base_dsn, db))
    try:
        await probe.execute((_BACKEND / "sql/pilot_cluster_schema.sql").read_text())
        check(not await _user_objects(probe, exempt_maintenance=True),
              "apply 完【维护库专用表集合】后闸 (iii) 判空（合法派生物仍被豁免）")
        # ⚠️ **每个反例单独造、单独清** —— 累积会让上一步的对象冒充本步的检出
        #    （我第一次验这条时就是这么得出假阳性的）。
        for ddl, undo, label in (
            ("CREATE TABLE public.child () INHERITS (public.pilot_create_intent)",
             "DROP TABLE public.child", "继承子表"),
            ("CREATE INDEX extra_idx ON public.pilot_create_intent (seed)",
             "DROP INDEX public.extra_idx", "额外索引"),
            ("ALTER TABLE public.pilot_create_intent ADD CONSTRAINT ck_x CHECK (length(seed) > 0)",
             "ALTER TABLE public.pilot_create_intent DROP CONSTRAINT ck_x", "额外约束"),
            ("CREATE RULE r_x AS ON DELETE TO public.pilot_cluster_marker DO INSTEAD NOTHING",
             "DROP RULE r_x ON public.pilot_cluster_marker", "规则"),
            ("CREATE TRIGGER trg_x BEFORE INSERT ON public.pilot_create_intent"
             " FOR EACH ROW EXECUTE FUNCTION suppress_redundant_updates_trigger()",
             "DROP TRIGGER trg_x ON public.pilot_create_intent", "触发器"),
        ):
            await probe.execute(ddl)
            check(bool(await _user_objects(probe, exempt_maintenance=True)),
                  f"{label}必须被闸 (iii) 看见",
                  "被豁免盖住了 → 维护库带着它也判「干净」")
            await probe.execute(undo)
            check(not await _user_objects(probe, exempt_maintenance=True),
                  f"{label}清理后恢复判空")
    finally:
        await probe.close()
    await _drop(base_dsn, db)

    # ── ⑧ 锁形态混淆 + 跨目录 OID 撞号（O4-R6，只有真 PG 能验）──────────
    scenario("⑧")
    print("\n⑧ 锁形态混淆 / 跨目录 OID 撞号（只有真 PG 能验）")
    lk = await asyncpg.connect(base_dsn)
    try:
        seed = "selfcheck_lock"
        h = await lk.fetchval("SELECT hashtext('kline_pilot_' || $1)", seed)
        await lk.fetchval("SELECT pg_advisory_lock_shared(hashtext('kline_pilot_' || $1))", seed)
        check(not await lk.fetchval(_SEED_LOCK_HELD_SQL, seed),
              "只持**共享**锁不得满足 seed 锁证明", "共享锁不提供互斥，两次同 seed 会并跑")
        await lk.fetchval("SELECT pg_advisory_unlock_shared(hashtext('kline_pilot_' || $1))", seed)
        hi, lo = (h >> 32) & 0xFFFFFFFF, h & 0xFFFFFFFF
        hi = hi - (1 << 32) if hi >= (1 << 31) else hi
        lo = lo - (1 << 32) if lo >= (1 << 31) else lo
        await lk.fetchval("SELECT pg_advisory_lock($1::int, $2::int)", hi, lo)
        check(not await lk.fetchval(_SEED_LOCK_HELD_SQL, seed),
              "只持**两参数**锁不得满足 seed 锁证明", "那是另一个命名空间（objsubid=2）")
        await lk.fetchval("SELECT pg_advisory_unlock($1::int, $2::int)", hi, lo)
        await lk.fetchval("SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))", seed)
        check(await lk.fetchval(_SEED_LOCK_HELD_SQL, seed),
              "持正确的单参数独占锁时必须通过（不能误拒）")
    finally:
        await lk.close()

    db = "kline_pilot_selfcheck_p7"
    await _drop(base_dsn, db)
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("CREATE DATABASE " + quote_ident(db) + " TEMPLATE template0")
    finally:
        await maint.close()
    probe = await asyncpg.connect(_db_dsn(base_dsn, db))
    try:
        await probe.execute((_BACKEND / "sql/pilot_cluster_schema.sql").read_text())
        oid = await probe.fetchval("SELECT to_regclass('public.pilot_cluster_marker')::oid::bigint")
        await probe.execute("SELECT lo_create($1)", oid)
        check(bool(await _user_objects(probe, exempt_maintenance=True)),
              "oid 与被豁免表撞号的大对象必须被闸 (iii) 看见",
              "裸 oid 比较会跨目录撞号把它藏住")
    finally:
        await probe.close()
    await _drop(base_dsn, db)

    # ── ⑧b hashtext 为负的 seed 同样要判得出锁（O4-R17-C2 的结论，钉住它）──
    #    codex 判定「hashtext 返回有符号 int32，负值时 classid::bigint<<32 会溢出或
    #    得到无符号值，约一半 seed 会误判 seed_lock_not_held」。**实测不成立**：
    #    PostgreSQL 的 int8 `<<` 是按位移位、会绕回，重建结果与原值逐位相等。
    #    结论既然是「现状正确」，就必须有钉子守着它，否则下一轮又要重新论证一遍。
    scenario("⑧b")
    print("\n⑧b 负 hashtext 的 seed 也必须判得出锁（只有真 PG 能验）")
    maint = await _maintenance(base_dsn)
    try:
        rows = await maint.fetch(
            "SELECT s, hashtext('kline_pilot_' || s) AS h FROM"
            " (VALUES ('a'),('b'),('d'),('e'),('probe'),('c')) t(s)")
        negs = [r["s"] for r in rows if r["h"] < 0]
        poss = [r["s"] for r in rows if r["h"] >= 0]
        check(bool(negs) and bool(poss),
              "样本里正负 hashtext 都有（本档的前提）",
              f"负={negs} 正={poss}")
        for seed_i in negs[:2] + poss[:2]:
            got = await maint.fetchval(
                "SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))", seed_i)
            held = await maint.fetchval(_SEED_LOCK_HELD_SQL, seed_i)
            h = await maint.fetchval("SELECT hashtext('kline_pilot_' || $1)", seed_i)
            check(bool(got) and bool(held),
                  f"seed={seed_i!r}（hashtext={h}）持锁后判据成立",
                  f"取锁={got} 判据={held}")
            await maint.fetchval(
                "SELECT pg_advisory_unlock(hashtext('kline_pilot_' || $1))", seed_i)
    finally:
        await maint.close()

    # ── ⑨ 建库确定性失败必须撤回 intent 行（O4-R7-C1，只有真 PG 能验）────
    scenario("⑨")
    print("\n⑨ 目标库本就存在 → 建库失败 → intent 行必须撤回（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p8"
    await _drop(base_dsn, db)
    maint = await _maintenance(base_dsn, seed="selfcheck_p8")
    try:
        # 模拟「别人先建了一个同名空库」
        await maint.execute("CREATE DATABASE " + quote_ident(db) + " TEMPLATE template0")
        await maint.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
        # ⚠️ 登记表按设计**永不清理**，所以它会跨脚本运行累积 —— 上一轮跑剩的行会让
        #    本档「不得留下登记行」的断言假红（实测踩到）。前置里显式清掉本档的那一行。
        await maint.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", db)

        async def connect(name: str):
            return _BoomProxy(await asyncpg.connect(_db_dsn(base_dsn, name)), None)

        try:
            await create_pilot_database(maint, connect=connect, db_name=db,
                                        seed="selfcheck_p8", run_id="verify-p8", **_ARGS)
            check(False, "目标库已存在时建库必须失败")
        except Exception as exc:
            check(getattr(exc, "sqlstate", None) == "42P04",
                  "失败原因是 duplicate_database", f"实得 {type(exc).__name__}")
        rows = await maint.fetch(
            "SELECT dbname FROM public.pilot_create_intent WHERE dbname = $1", db)
        check(not rows,
              "确定性失败后 intent 行必须撤回",
              "留着它 → 之后 --reset 会把**别人的**空库当成本次残骸无凭据 DROP")
        # O4-R15-C1：登记行是闸 (ii) 的**外部**归属凭据。一次失败的建库若把它铸出来，
        # 就把一个**外来**的同名库从「拒」变成了「信」—— 正是这张表被引入来防的事。
        reg = await maint.fetch(
            "SELECT dbname FROM public.pilot_database_registry WHERE dbname = $1", db)
        check(not reg,
              "确定性失败后**不得**留下登记行",
              f"残留 {[dict(r) for r in reg]} —— 一次失败尝试就为外来库铸出了归属凭据")
    finally:
        await maint.close()
    await _drop(base_dsn, db)

    # ── ⑩ 【维护库专用表集合】的结构证明 + 建库确认（O4-R8，只有真 PG 能验）────
    #    host 测试只能验「代码问没问结构」；**这条 SQL 到底能不能认出畸形表**
    #    是语义问题，假件（回一个现成 dict）对它零覆盖。
    scenario("⑩")
    print("\n⑩ 维护表结构证明 / create_confirmed 时序（只有真 PG 能验）")
    maint = await _maintenance(base_dsn)

    async def _connect_unused(name: str):
        raise AssertionError("闸 (i) 就该拦下，不该走到连别的库")

    async def _gate_rejects(label: str, detail: str) -> None:
        try:
            await assert_cluster_allowed(maint, connect=_connect_unused, target_db=None)
            check(False, label, detail)
        except PilotClusterBoundaryError as exc:
            check(exc.code == "no_marker", label, f"code={exc.code}: {exc}")

    try:
        # (a) marker 换成没有唯一约束的表 —— 仍能返回一行 magic string
        await maint.execute("DROP TABLE IF EXISTS public.pilot_cluster_marker CASCADE")
        await maint.execute("CREATE TABLE public.pilot_cluster_marker (purpose TEXT)")
        await maint.execute("INSERT INTO public.pilot_cluster_marker (purpose) VALUES ($1)",
                            "qmt_pilot_disposable_cluster")
        await _gate_rejects("marker 无唯一约束 → 闸 (i) 必须拒",
                            "一行 magic string 就骗过了整台集群的授权")

        # (b) marker 换成**视图** —— relkind='v'，同样能返回那一行
        await maint.execute("DROP TABLE IF EXISTS public.pilot_cluster_marker CASCADE")
        await maint.execute("CREATE VIEW public.pilot_cluster_marker AS "
                            "SELECT 'qmt_pilot_disposable_cluster'::text AS purpose")
        await _gate_rejects("marker 是视图 → 闸 (i) 必须拒", "视图冒充了标记表")
        await maint.execute("DROP VIEW public.pilot_cluster_marker")

        # (c) marker 恢复正常，改坏 intent 表：少 create_confirmed 列
        await maint.execute((_BACKEND / "sql/pilot_cluster_schema.sql").read_text())
        await maint.execute("INSERT INTO public.pilot_cluster_marker (purpose) VALUES ($1)"
                            " ON CONFLICT (purpose) DO NOTHING",
                            "qmt_pilot_disposable_cluster")
        await maint.execute("ALTER TABLE public.pilot_create_intent DROP COLUMN create_confirmed")
        await _gate_rejects("intent 少 create_confirmed 列 → 闸 (i) 必须拒",
                            "少了这列，「建库已确认」这个凭据根本无处可存")

        # (d) intent.dbname 丢掉唯一约束 —— ON CONFLICT 的抢占语义整个塌掉
        await maint.execute("DROP TABLE public.pilot_create_intent")
        await maint.execute(
            "CREATE TABLE public.pilot_create_intent (dbname TEXT, seed TEXT NOT NULL,"
            " created_at TEXT NOT NULL, run_id TEXT NOT NULL,"
            " create_confirmed BOOLEAN NOT NULL DEFAULT false)")
        await _gate_rejects("intent.dbname 无唯一约束 → 闸 (i) 必须拒",
                            "没有唯一约束，ON CONFLICT 抢占判据不成立")

        # (e) 结构复原后闸 (i) 必须**放行** —— 否则上面四条全是「恒拒」的假红
        await maint.execute("DROP TABLE public.pilot_create_intent")
        await maint.execute((_BACKEND / "sql/pilot_cluster_schema.sql").read_text())
        ok = True
        try:
            await assert_cluster_allowed(maint, connect=_connect_unused, target_db=None)
        except PilotClusterBoundaryError as exc:
            ok, why = False, str(exc)
        check(ok, "结构复原后闸 (i) 放行（证明上面四条不是恒拒）",
              why if not ok else "")
    finally:
        await maint.close()

    # (f) 建库已成功、后续阶段崩 → 保留的 intent 行必须**已确认**
    #     ⚠️ 不能在「全程成功」那一档验：成功收尾会把 intent 行删掉，读到的永远是 None
    #        （我第一版就是这么写的，FAIL 的原因与被测行为无关）。
    #        这一档才同时满足两个前提：CREATE DATABASE 已成功 + 行还在。
    db = "kline_pilot_selfcheck_p10"
    try:
        await _build(base_dsn, db, "selfcheck_p10", trip_key="output_dir")
    except _Boom:
        pass
    maint = await _maintenance(base_dsn)
    try:
        row = await maint.fetchrow(
            "SELECT create_confirmed FROM public.pilot_create_intent WHERE dbname = $1", db)
        check(row is not None and row["create_confirmed"] is True,
              "建库已成功时保留的 intent 行 create_confirmed = true",
              f"实得 {dict(row) if row else None}"
              + "（false 意味着确认那一步没跑 → 零对象例外将永远认不出自己的残骸）")
    finally:
        await maint.close()
    await _drop(base_dsn, db)

    # ── ⑪ 同 run_id 重试不得毁掉自己的恢复凭据（O4-R9-C1，只有真 PG 能验）────
    #    起点：CREATE DATABASE 已成功、确认已写，但**还没连上目标库**就崩了
    #    → 留下一个【绝对空】的库 + 一行 create_confirmed=true 的 intent 行（凭据完好）。
    #    重试（同 run_id）时若把 create_confirmed 打回 false，随后 CREATE 撞
    #    duplicate_database，确定性失败清理又把行删了 → 空残骸失去唯一的销毁授权，
    #    工具再也清不掉自己建的库。
    scenario("⑪")
    print("\n⑪ 同 run_id 重试必须保住 create_confirmed（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p11"
    await _drop(base_dsn, db)

    async def _connect_boom(name: str):
        raise _Boom("注入：确认之后、连目标库之前断连")

    async def _attempt() -> Exception | None:
        maint = await _maintenance(base_dsn, seed="selfcheck_p11")
        try:
            await create_pilot_database(maint, connect=_connect_boom, db_name=db,
                                        seed="selfcheck_p11", run_id="verify-p11", **_ARGS)
        except Exception as exc:
            return exc
        finally:
            await maint.close()
        return None

    async def _intent_state():
        maint = await _maintenance(base_dsn)
        try:
            return await maint.fetchrow(
                "SELECT run_id, create_confirmed FROM public.pilot_create_intent"
                " WHERE dbname = $1", db)
        finally:
            await maint.close()

    exc1 = await _attempt()
    check(isinstance(exc1, _Boom), "第一次：崩在确认之后、连库之前",
          f"实得 {type(exc1).__name__ if exc1 else None}")
    maint = await _maintenance(base_dsn)
    try:
        exists = await maint.fetchval("SELECT 1 FROM pg_database WHERE datname = $1", db)
    finally:
        await maint.close()
    check(exists == 1, "空残骸库确实留下了")
    row = await _intent_state()
    check(row is not None and row["create_confirmed"] is True,
          "崩溃后 intent 行在、且 create_confirmed=true（凭据完好）",
          f"实得 {dict(row) if row else None}")

    exc2 = await _attempt()
    check(getattr(exc2, "sqlstate", None) == "42P04",
          "第二次（同 run_id）：CREATE 撞 duplicate_database",
          f"实得 {type(exc2).__name__ if exc2 else None}")
    row = await _intent_state()
    check(row is not None and row["create_confirmed"] is True,
          "重试之后凭据必须**仍在且仍为 true**（否则空残骸永远清不掉）",
          f"实得 {dict(row) if row else None} —— 同 run 重入把确认打回 false、"
          "再被确定性失败清理删掉 = 自毁恢复能力")
    await _drop(base_dsn, db)
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
    finally:
        await maint.close()

    # ── ⑫ 畸形 pilot_schema 必须在 ready 之前失败（O4-R13-C2，只有真 PG 能验）────
    #    host 假件只能验「代码问没问结构」；**这条 SQL 能不能在真 PG 上认出缺表**
    #    是语义问题，假件（回一个现成 dict）对它零覆盖。
    scenario("⑫")
    print("\n⑫ 畸形 pilot_schema 必须在 ready 之前整体回滚（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p12"
    await _drop(base_dsn, db)

    async def _plain_connect(name: str):
        return await asyncpg.connect(_db_dsn(base_dsn, name))

    bad_args = dict(_ARGS)
    # ⚠️ O4-R30-C1 之后，「畸形 pilot_schema 被 apply 出去」这条路径**不再可达** ——
    #    两份 .sql 已钉死到仓库规范指纹，非规范的根本进不了场。
    #    故本档改测：畸形输入在**任何副作用之前**被拒（连 intent 行都不写）。
    bad_args["pilot_schema_sql"] = (
        "CREATE TABLE IF NOT EXISTS public.pilot_meta "
        "(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
    bad_args["pilot_schema_sha256"] = sha256_of_sql(bad_args["pilot_schema_sql"])
    maint = await _maintenance(base_dsn, seed="selfcheck_p12")
    try:
        try:
            await create_pilot_database(maint, connect=_plain_connect, db_name=db,
                                        seed="selfcheck_p12", run_id="verify-p12", **bad_args)
            check(False, "非规范 pilot_schema 必须被拒")
        except Exception as exc:
            check(getattr(exc, "code", None) == "schema_not_canonical",
                  "非规范 pilot_schema → schema_not_canonical（进场即拒）",
                  f"实得 {type(exc).__name__}: {exc}")
        rows = await maint.fetch(
            "SELECT dbname FROM public.pilot_create_intent WHERE dbname = $1", db)
        check(not rows, "进场被拒时连 intent 行都不许写")
    finally:
        await maint.close()
    _m12 = await asyncpg.connect(base_dsn)
    try:
        check(await _m12.fetchval(
            "SELECT 1 FROM pg_database WHERE datname = $1", db) is None,
            "库也不许被建出来")
    finally:
        await _m12.close()

    # ⑫b 对称地检查 schema.sql 那一份（同样进场即拒）
    bad2 = dict(_ARGS)
    bad2["schema_sql"] = "BEGIN;\nCREATE TABLE klines (id int);\nCOMMIT;"
    bad2["schema_sha256"] = sha256_of_sql(bad2["schema_sql"])
    maint = await _maintenance(base_dsn, seed="selfcheck_p12")
    try:
        try:
            await create_pilot_database(maint, connect=_plain_connect, db_name=db,
                                        seed="selfcheck_p12", run_id="verify-p12b", **bad2)
            check(False, "非规范 schema.sql 必须被拒")
        except Exception as exc:
            check(getattr(exc, "code", None) == "schema_not_canonical",
                  "非规范 schema.sql → schema_not_canonical（进场即拒）",
                  f"实得 {type(exc).__name__}: {exc}")
    finally:
        await maint.close()

    # ⑫c 库名含引号时，建/删必须走 quote_ident（O4-R20-C1）
    #     库名可以含引号/分号，而 asyncpg.execute 支持多语句 —— 裸 f-string 拼接
    #     能让本脚本以 DSN（通常是超级用户）多跑一条 DROP。
    evil_db = 'kline_pilot_selfcheck_ev"il'
    m = await _maintenance(base_dsn)
    try:
        await m.execute("DROP DATABASE IF EXISTS " + quote_ident(evil_db))
        await m.execute("CREATE DATABASE " + quote_ident(evil_db) + " TEMPLATE template0")
        exists = await m.fetchval("SELECT 1 FROM pg_database WHERE datname = $1", evil_db)
        check(exists == 1, "含引号的库名建得出来（本档的前提）")
        check(_SELFCHECK_NAME_RE.fullmatch(evil_db) is None,
              "这种名字不符合本脚本自己的命名规则（清场会额外打印一行提示）")
    finally:
        await m.close()
    await _drop(base_dsn, evil_db)
    m = await _maintenance(base_dsn)
    try:
        gone = await m.fetchval("SELECT 1 FROM pg_database WHERE datname = $1", evil_db)
        check(gone is None, "转义后能正常删掉，且没有波及别的库")
        others = await m.fetchval(
            "SELECT count(*) FROM pg_database WHERE datname LIKE 'kline_pilot_%'")
        check(others == 0, "没有别的 kline_pilot_* 库被误删", f"实得 {others} 个")
    finally:
        await m.close()

    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
    finally:
        await maint.close()

    # ── ⑰ apply 之后业务表被弄丢 → 不许标 ready（O4-R19/R29，只有真 PG 能验）──
    #    ⚠️ O4-R30-C1 之后注入点从 SQL 文本改到**连接代理**：两份 .sql 已钉死到仓库
    #    规范指纹，「敌意 schema.sql」不再可达；这些判据要防的真实威胁是
    #    「apply 之后、判据之前库被弄坏」，故在规范 schema 跑完的那一刻注入。
    scenario("⑰")
    print("\n⑰ apply 之后业务表被弄丢 → 不许标 ready（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p17"
    await _drop(base_dsn, db)
    connect17, holder17 = _saboteur(base_dsn, "DROP TABLE public.stocks CASCADE;")   # 有外键依赖，须 CASCADE
    maint = await _maintenance(base_dsn, seed="selfcheck_p17")
    try:
        try:
            await create_pilot_database(maint, connect=connect17, db_name=db,
                                        seed="selfcheck_p17", run_id="verify-p17", **_ARGS)
            check(False, "业务表被弄丢时必须失败")
        except Exception as exc:
            check(getattr(exc, "code", None) in ("schema_tables_missing",
                                                 "business_tables_missing"),
                  "失败原因是表不齐（schema_tables_missing / business_tables_missing）",
                  f"实得 {type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    check(holder17["proxy"].fired, "前提：注入确实触发了（规范 schema 跑过）")
    meta = await _read_meta(base_dsn, db) or {}
    check(set(meta) == set(PILOT_META_PHASE1_KEYS) and meta.get("state") == "initializing",
          "库停在阶段 1（没被标 ready）",
          f"实得键 {sorted(meta)} state={meta.get('state')}")
    await _drop(base_dsn, db)
    m = await _maintenance(base_dsn)
    try:
        await m.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname LIKE 'kline_pilot_selfcheck_p17%'")
        await m.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname LIKE 'kline_pilot_selfcheck_p17%'")
    finally:
        await m.close()

    # ── ⑱ apply 之后 pilot 安全表被弄没 → 不许标 ready（O4-R21-C2，只有真 PG 能验）──
    #    ⚠️ O4-R30-C1 之后注入点从 SQL 文本改到**连接代理**：两份 .sql 已钉死到仓库
    #    规范指纹，「敌意 schema.sql」不再可达；这些判据要防的真实威胁是
    #    「apply 之后、判据之前库被弄坏」，故在规范 schema 跑完的那一刻注入。
    scenario("⑱")
    print("\n⑱ apply 之后 pilot 安全表被弄没 → 不许标 ready（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p18"
    await _drop(base_dsn, db)
    connect18, holder18 = _saboteur(base_dsn, "DROP TABLE public.pilot_stock_source;")
    maint = await _maintenance(base_dsn, seed="selfcheck_p18")
    try:
        try:
            await create_pilot_database(maint, connect=connect18, db_name=db,
                                        seed="selfcheck_p18", run_id="verify-p18", **_ARGS)
            check(False, "pilot 安全表被弄没时必须失败")
        except Exception as exc:
            check(getattr(exc, "code", None) == "pilot_schema_invalidated",
                  "失败原因是 pilot_schema_invalidated",
                  f"实得 {type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    check(holder18["proxy"].fired, "前提：注入确实触发了")
    check(await _relation_exists(base_dsn, db, "klines"),
          "前提：规范 schema 确实执行了（klines 建出来了）")
    meta = await _read_meta(base_dsn, db) or {}
    check(meta.get("state") == "initializing" and "schema_sha256" not in meta,
          "库停在阶段 1，没被标 ready",
          f"实得 state={meta.get('state')} 键={sorted(meta)}")
    await _drop(base_dsn, db)
    m = await _maintenance(base_dsn)
    try:
        await m.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
        await m.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", db)
    finally:
        await m.close()

    # ── ⑲ apply 之后的副作用不得掀翻后续守卫（O4-R22，只有真 PG 能验）──────────
    #    ⚠️ O4-R30-C1 之后注入点从 SQL 文本改到**连接代理**：两份 .sql 已钉死到仓库
    #    规范指纹，「敌意 schema.sql」不再可达；这些判据要防的真实威胁是
    #    「apply 之后、判据之前库被弄坏」，故在规范 schema 跑完的那一刻注入。
    scenario("⑲")
    print("\n⑲ apply 之后的副作用不得掀翻后续守卫（只有真 PG 能验）")

    # (a) 前提：普通 SET 提交后确实留在会话上
    probe = await asyncpg.connect(base_dsn)
    try:
        await probe.execute("SET search_path = public, pg_temp")
        await probe.execute("BEGIN; SET search_path = zzqmtverify_poison_ns, pg_catalog, public; COMMIT;")
        left = await probe.fetchval("SELECT current_setting('search_path')")
        check("zzqmtverify_poison_ns" in left, "前提：事务里的 SET 提交后仍留在会话上",
              f"实得 {left!r} —— 本档证明不了任何事")
    finally:
        await probe.close()

    # (b) 毒化 search_path + 真影子目录表 → 后续守卫必须仍在真目录上求值
    db = "kline_pilot_selfcheck_p19a"
    await _drop(base_dsn, db)
    poison = ("CREATE SCHEMA IF NOT EXISTS zzqmtverify_poison_ns;"
              "CREATE TABLE zzqmtverify_poison_ns.pg_class (oid oid, relname text, relkind \"char\","
              " relnamespace oid, reltoastrelid oid, reltype oid, relisshared boolean);"
              "CREATE TABLE zzqmtverify_poison_ns.pg_attribute (attrelid oid, attname text, attnum int,"
              " atttypid oid, attisdropped boolean, attnotnull boolean);"
              "SET search_path = zzqmtverify_poison_ns, pg_catalog, public;")
    connect19a, holder19a = _saboteur(base_dsn, poison)
    maint = await _maintenance(base_dsn, seed="selfcheck_p19a")
    try:
        try:
            await create_pilot_database(maint, connect=connect19a, db_name=db,
                                        seed="selfcheck_p19a", run_id="verify-p19a", **_ARGS)
            ok19a, why = True, ""
        except Exception as exc:
            ok19a, why = False, f"{type(exc).__name__}: {exc}"
    finally:
        await maint.close()
    check(holder19a["proxy"].fired, "前提：毒化确实注入了")
    check(ok19a, "search_path 被毒化之后，后续守卫仍能正常求值并放行", why)
    meta = await _read_meta(base_dsn, db) or {}
    check(meta.get("state") == "ready" and len(meta) == len(PILOT_META_KEYS),
          "库正常建成（本档要的是「不被牵着走」，不是「必须失败」）",
          f"实得 state={meta.get('state')} 键数={len(meta)}")
    await _drop(base_dsn, db)

    # (c) 篡改阶段 1 的授权键 → 必须在标 ready 之前拦下
    db = "kline_pilot_selfcheck_p19b"
    await _drop(base_dsn, db)
    connect19b, holder19b = _saboteur(
        base_dsn, "UPDATE public.pilot_meta SET value = 'someone_else' WHERE key = 'seed';")
    maint = await _maintenance(base_dsn, seed="selfcheck_p19b")
    try:
        try:
            await create_pilot_database(maint, connect=connect19b, db_name=db,
                                        seed="selfcheck_p19b", run_id="verify-p19b", **_ARGS)
            check(False, "阶段 1 授权键被改时必须失败")
        except Exception as exc:
            check(getattr(exc, "code", None) == "phase1_meta_tampered",
                  "失败原因是 phase1_meta_tampered",
                  f"实得 {type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    check(holder19b["proxy"].fired, "前提：篡改确实注入了")
    meta = await _read_meta(base_dsn, db) or {}
    check(meta.get("state") == "initializing" and "schema_sha256" not in meta,
          "库停在阶段 1，没被标 ready",
          f"实得 state={meta.get('state')} 键={sorted(meta)}")
    await _drop(base_dsn, db)

    m = await _maintenance(base_dsn)
    try:
        await m.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname LIKE 'kline_pilot_selfcheck_p19%'")
        await m.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname LIKE 'kline_pilot_selfcheck_p19%'")
        await m.execute("DROP SCHEMA IF EXISTS zzqmtverify_poison_ns CASCADE")
    finally:
        await m.close()

    # ── ⑳ 部分/无效唯一索引不得冒充主键；TTL 只认库时钟（O4-R23，只有真 PG 能验）──
    scenario("⑳")
    print("\n⑳ 唯一性判据要求主键 + TTL 只认库时钟（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p20"
    await _drop(base_dsn, db)

    async def _plain20(name: str):
        return await asyncpg.connect(_db_dsn(base_dsn, name))

    async def _boom20(name: str):
        raise _Boom("注入：确认之后、连目标库之前断连")

    # (a) apply 之后把主键换成**部分**唯一索引：满足 indisunique 却对任何行都不生效
    #     ⚠️ 注入点在连接代理上（O4-R30-C1 之后 pilot_schema.sql 已被钉死）。
    for _tbl, _col, _tag in (("pilot_stock_source", "stock_code", "pilot_stock_source"),
                             ("pilot_meta", "key", "pilot_meta.key")):
        await _drop(base_dsn, db)
        _m20 = await _maintenance(base_dsn)
        try:
            await _m20.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
        finally:
            await _m20.close()
        sab = (f"ALTER TABLE public.{_tbl} DROP CONSTRAINT {_tbl}_pkey;"
               f"CREATE UNIQUE INDEX ON public.{_tbl} ({_col}) WHERE false;")
        conn20, holder20 = _saboteur(base_dsn, sab)
        maint = await _maintenance(base_dsn, seed="selfcheck_p20")
        try:
            try:
                await create_pilot_database(maint, connect=conn20, db_name=db,
                                            seed="selfcheck_p20", run_id="verify-p20a", **_ARGS)
                check(False, f"{_tag} 的部分唯一索引必须被拒")
            except Exception as exc:
                check(getattr(exc, "code", None) == "pilot_schema_invalidated",
                      f"{_tag} 的部分唯一索引 → pilot_schema_invalidated",
                      f"实得 {type(exc).__name__}: {exc}")
        finally:
            await maint.close()
        check(holder20["proxy"].fired, f"{_tag}：注入确实触发了")
    await _drop(base_dsn, db)
    _m20 = await _maintenance(base_dsn)
    try:
        await _m20.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
    finally:
        await _m20.close()

    # (b) 调用方传一个**很远的未来** created_at，不得让 intent 行永不过期
    db = "kline_pilot_selfcheck_p20b"
    await _drop(base_dsn, db)
    future_args = dict(_ARGS)
    future_args["created_at"] = "29991231T235959999999Z"
    maint = await _maintenance(base_dsn, seed="selfcheck_p20b")
    try:
        try:
            await create_pilot_database(maint, connect=_boom20, db_name=db,
                                        seed="selfcheck_p20b", run_id="verify-p20b", **future_args)
        except _Boom:
            pass
    finally:
        await maint.close()
    m = await _maintenance(base_dsn)
    try:
        row = await m.fetchrow(
            "SELECT created_at, inserted_at,"
            " EXTRACT(EPOCH FROM (now() - inserted_at))::bigint AS age_s"
            " FROM public.pilot_create_intent WHERE dbname = $1", db)
        check(row is not None and row["created_at"] == "29991231T235959999999Z",
              "前提：调用方传的未来 created_at 确实原样存下来了（它仍是展示/绑定值）",
              f"实得 {dict(row) if row else None}")
        check(row is not None and -5 <= row["age_s"] <= 5,
              "新鲜度按**库时钟**算，与调用方传的 created_at 无关",
              f"实得 age={row['age_s'] if row else None}s —— 若跟着 created_at 走会是个负的巨值")
        # 把库时钟老化到 TTL 之外 → 应当可被别的 run 接管
        await m.execute("UPDATE public.pilot_create_intent"
                        " SET inserted_at = now() - interval '999 days' WHERE dbname = $1", db)
    finally:
        await m.close()
    await _drop(base_dsn, db)
    maint = await _maintenance(base_dsn, seed="selfcheck_p20b")
    try:
        try:
            await create_pilot_database(maint, connect=_boom20, db_name=db,
                                        seed="selfcheck_p20b", run_id="verify-p20b-2", **_ARGS)
            took_over = True
        except _Boom:
            took_over = True
        except Exception as exc:
            took_over, why = False, f"{type(exc).__name__}: {exc}"
    finally:
        await maint.close()
    check(took_over,
          "库时钟老化之后可被别的 run 接管（未来 created_at 挡不住 TTL）",
          why if not took_over else "")
    await _drop(base_dsn, db)
    m = await _maintenance(base_dsn)
    try:
        await m.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname LIKE 'kline_pilot_selfcheck_p20%'")
        await m.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname LIKE 'kline_pilot_selfcheck_p20%'")
    finally:
        await m.close()

    # ── ㉑ apply 之后 pilot 表上被装了触发器 → 不许标 ready（O4-R26-C1，只有真 PG 能验）
    #    形状、列、主键、阶段 1 的七行全都原样 —— 只有触发器会把阶段 2 写进去的值改掉。
    #    ⚠️ 注入点在连接代理上（O4-R30-C1 之后 schema.sql 已被钉死，敌意文本不再可达）。
    scenario("㉑")
    print("\n㉑ apply 之后 pilot 表上被装了触发器 → 不许标 ready（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p21"
    await _drop(base_dsn, db)
    trig = ("CREATE FUNCTION public.zzqmtverify_rewrite_fn() RETURNS trigger AS $fn$ "
            "BEGIN IF NEW.key = 'schema_sha256' THEN NEW.value := repeat('0', 64); END IF; "
            "RETURN NEW; END; $fn$ LANGUAGE plpgsql;"
            "CREATE TRIGGER zzqmtverify_meta_trg BEFORE INSERT ON public.pilot_meta "
            "  FOR EACH ROW EXECUTE FUNCTION public.zzqmtverify_rewrite_fn();")
    connect21, holder21 = _saboteur(base_dsn, trig)
    maint = await _maintenance(base_dsn, seed="selfcheck_p21")
    try:
        try:
            await create_pilot_database(maint, connect=connect21, db_name=db,
                                        seed="selfcheck_p21", run_id="verify-p21", **_ARGS)
            check(False, "pilot_meta 上被装触发器时必须失败")
        except Exception as exc:
            check(getattr(exc, "code", None) == "pilot_tables_have_dependents",
                  "失败原因是 pilot_tables_have_dependents",
                  f"实得 {type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    check(holder21["proxy"].fired, "前提：触发器确实装上了")
    meta = await _read_meta(base_dsn, db) or {}
    check(meta.get("state") == "initializing" and "schema_sha256" not in meta,
          "库停在阶段 1，没被标 ready",
          f"实得 state={meta.get('state')} 键={sorted(meta)}")
    await _drop(base_dsn, db)
    m = await _maintenance(base_dsn)
    try:
        await m.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
        await m.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", db)
    finally:
        await m.close()

    # ── ㉒ 来源基线的**内容**与**行为**同样要证（O4-R27，只有真 PG 能验）────────
    #    ⚠️ 注入点在连接代理上（O4-R30-C1 之后 schema.sql 已被钉死）。
    scenario("㉒")
    print("\n㉒ apply 之后被预置基线 / 留下 RLS 或继承 → 不许标 ready（只有真 PG 能验）")

    async def _try22(tag: str, sabotage: str, want_code, why: str) -> None:
        # ⚠️ `want_code` 可以是**一组** code（O4-R37-C2）：形状/耐久性判据与依赖物判据
        #    在两个方向上重叠（RLS 两边都数；部分唯一索引既让 key_unique 为假、
        #    也让 extra_indexes 非零），没有哪种排序能对所有情形都给出更精确的那个 ——
        #    换序只是把遮蔽换到另一边（实测两种排序各红两档）。
        #    重叠的那几档断言的是**性质**（拒了、停在阶段 1），不是具体 code；
        #    不重叠的档位仍然逐个 code 钉死。
        want = want_code if isinstance(want_code, tuple) else (want_code,)
        db22 = "kline_pilot_selfcheck_p22"
        await _drop(base_dsn, db22)
        m0 = await _maintenance(base_dsn)
        try:
            await m0.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db22)
        finally:
            await m0.close()
        conn22, holder22 = _saboteur(base_dsn, sabotage)
        mm = await _maintenance(base_dsn, seed="selfcheck_p22")
        try:
            try:
                await create_pilot_database(mm, connect=conn22, db_name=db22,
                                            seed="selfcheck_p22", run_id="verify-p22", **_ARGS)
                check(False, tag, "建库居然成功了 —— " + why)
                return
            except Exception as exc:
                check(getattr(exc, "code", None) in want, tag,
                      f"实得 {type(exc).__name__}: {exc}")
        finally:
            await mm.close()
        check(holder22["proxy"].fired, tag + "：注入确实触发了")
        meta22 = await _read_meta(base_dsn, db22) or {}
        check(meta22.get("state") == "initializing",
              tag + "：库停在阶段 1", f"实得 state={meta22.get('state')}")
        await _drop(base_dsn, db22)

    await _try22("预置来源基线 → pilot_source_not_empty",
                 "INSERT INTO public.pilot_stock_source VALUES ('000001', 'a', 'b');",
                 "pilot_source_not_empty", "伪造的基线行会让此后的重新导入被跳过")
    await _try22("留下 FORCE RLS → 拒（依赖物或耐久性判据，两者重叠）",
                 "ALTER TABLE public.pilot_stock_source ENABLE ROW LEVEL SECURITY;"
                 "ALTER TABLE public.pilot_stock_source FORCE ROW LEVEL SECURITY;",
                 ("pilot_tables_have_dependents", "pilot_schema_invalidated"),
                 "本工具不保证以超级用户运行；普通角色会被 RLS 挡住")
    await _try22("apply 之后把业务表改成 UNLOGGED → business_schema_drift",
                 "ALTER TABLE public.training_sets SET UNLOGGED;",
                 "business_schema_drift",
                 "改的是 pg_class.relpersistence —— 列/约束/默认值/序列/索引一个不动，"
                 "而库不再崩溃安全（PG 崩后会被 truncate）")
    await _try22("apply 之后在业务表上装触发器 → business_tables_have_dependents",
                 "CREATE FUNCTION public.zzqmtverify_biz_fn() RETURNS trigger AS $fn$ "
                 "BEGIN RETURN NEW; END; $fn$ LANGUAGE plpgsql;"
                 "CREATE TRIGGER zzqmtverify_biz_trg BEFORE INSERT ON public.klines "
                 "  FOR EACH ROW EXECUTE FUNCTION public.zzqmtverify_biz_fn();",
                 "business_tables_have_dependents",
                 "列/约束/默认值/索引/序列全不变，活目录指纹一个字都不动")
    await _try22("apply 之后改掉序列参数 → business_schema_drift",
                 "ALTER SEQUENCE public.training_sets_id_seq INCREMENT BY 7;",
                 "business_schema_drift",
                 "默认值文本写的是 nextval(...)，序列本身变了它一个字不变")
    # ⚠️ 序列漂移不止 INCREMENT BY（O4-R38-C1）：本机 PG 15.12 实测，下面三种改法
    #    都让 R34 版指纹（只取 start/increment/cycle）**一字不变**，
    #    而 MAXVALUE 改小之后第三次 INSERT 会 `nextval: reached maximum value of sequence`。
    await _try22("apply 之后改小序列 MAXVALUE → business_schema_drift",
                 "ALTER SEQUENCE public.training_sets_id_seq MAXVALUE 2;",
                 "business_schema_drift",
                 "序列耗尽后此后每一次 INSERT 都会失败，而库已被标 ready")
    await _try22("apply 之后改窄序列类型 → business_schema_drift",
                 "ALTER SEQUENCE public.training_sets_id_seq AS smallint MAXVALUE 32767;",
                 "business_schema_drift",
                 "取值范围被砍到 32767，主键空间悄悄缩小")
    await _try22("apply 之后把序列改成 UNLOGGED → business_schema_drift",
                 "ALTER SEQUENCE public.training_sets_id_seq SET UNLOGGED;",
                 "business_schema_drift",
                 "PG 15.12 支持给序列 SET UNLOGGED —— R37 给表补的崩溃安全证明，序列这边躲得过")
    await _try22("apply 之后改掉一个默认值 → business_schema_drift",
                 "ALTER TABLE public.training_sets ALTER COLUMN schema_version SET DEFAULT 99;",
                 "business_schema_drift",
                 "默认值不动列名/类型/可空/约束/索引 —— 上一版指纹**完全看不见**它，"
                 "而运行时的 INSERT 依赖它")
    await _try22("apply 之后掉一条 CHECK 约束 → business_schema_drift",
                 "ALTER TABLE public.klines DROP CONSTRAINT ck_klines_price_finite_positive;",
                 "business_schema_drift",
                 "四个表名照旧齐全，而列/约束已经不是规范 schema 那一套 —— "
                 "规范指纹证明的是**递进来的字节**，不是**库现在长什么样**")
    await _try22("留下继承子表 → pilot_tables_have_dependents",
                 "CREATE TABLE public.zzqmtverify_child () INHERITS (public.pilot_stock_source);",
                 "pilot_tables_have_dependents", "子表的行会从父表读出来，基线凭空多出内容")

    m = await _maintenance(base_dsn)
    try:
        await m.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname LIKE 'kline_pilot_selfcheck_p22%'")
        await m.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname LIKE 'kline_pilot_selfcheck_p22%'")
    finally:
        await m.close()

    # ── ㉓ 注入的连接必须**证明自己连对了库**（O4-R28-C1，只有真 PG 能验）────────
    #    `connect(name)` 返回什么就用什么，是一条没被验过的调用方断言 ——
    #    DSN 改写 / 连接池串号 / 包装层映射错，都会让 DDL 落到**另一个库**上。
    scenario("㉓")
    print("\n㉓ 注入的连接必须证明自己连对了库（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p23"
    await _drop(base_dsn, db)
    victim = "kline_pilot_selfcheck_p23v"
    await _drop(base_dsn, victim)
    m = await _maintenance(base_dsn)
    try:
        await m.execute("CREATE DATABASE " + quote_ident(victim) + " TEMPLATE template0")
    finally:
        await m.close()

    async def _misrouted(name: str):
        # 无论要哪个库，都把连接送到 victim —— 模拟 DSN 改写 / 连接池串号
        return await asyncpg.connect(_db_dsn(base_dsn, victim))

    maint = await _maintenance(base_dsn, seed="selfcheck_p23")
    try:
        try:
            await create_pilot_database(maint, connect=_misrouted, db_name=db,
                                        seed="selfcheck_p23", run_id="verify-p23", **_ARGS)
            check(False, "连接被送到别的库时必须失败")
        except Exception as exc:
            check(getattr(exc, "code", None) == "connection_wrong_database",
                  "失败原因是 connection_wrong_database",
                  f"实得 {type(exc).__name__}: {exc}")
    finally:
        await maint.close()
    check(await _relation_exists(base_dsn, victim, "pilot_meta") is False,
          "**一张表都没建到那个无辜的库上**",
          "DDL 落到了别的库 —— 这台守卫存在的全部意义当场归零")
    check(await _relation_exists(base_dsn, victim, "klines") is False,
          "业务 schema 也没落到那个库上")
    await _drop(base_dsn, victim)
    await _drop(base_dsn, db)
    m = await _maintenance(base_dsn)
    try:
        await m.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname LIKE 'kline_pilot_selfcheck_p23%'")
        await m.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname LIKE 'kline_pilot_selfcheck_p23%'")
    finally:
        await m.close()

    # ── ㉔ 同名但**在另一台集群**上（O4-R29-C1，只有真 PG 能验）──────────────
    #    被改错的 DSN 完全可能指向另一台 PostgreSQL 上同名的库 —— 名字对上了，
    #    而维护库里的 intent/登记与它分属两台机器。
    #    本档需要第二个集群：环境变量 DSN2 没给就**明确跳过并打印**（不当成通过）。
    # ⚠️ **DSN2 是必填的**（O4-R31-C1）：上一版缺它时只打印一行「跳过」，
    #    而退出码与结尾摘要照样是绿的 —— **「跳过」与「通过」在最终信号上没有区别**，
    #    于是「跨集群误路由」这条高代价的信任边界回归可以毫无验收信号地溜过去。
    #    本脚本是验收闸，不是可选自测：缺 DSN2 直接判失败。
    dsn2 = os.environ.get("DSN2")
    if not dsn2:
        check(False, "㉔ 跨集群同名库",
              "未提供 DSN2 —— 这一档**没有跑**。验收闸不接受「跳过」："
              "请把 DSN2 指向第二个 PostgreSQL 集群后重跑。")
    elif _assert_destructive_dsn_allowed(dsn2, "DSN2") is None:
        # ⚠️ 闸必须在**第一次 connect/DDL 之前**（O4-R37-C1）：本档接下来就
        #    `_drop(dsn2, …)` + `CREATE DATABASE`。闸没过就判失败，不是「跳过」——
        #    验收闸里「跳过」与「通过」在最终信号上没有区别。
        check(False, "㉔ 跨集群同名库",
              "DSN2 没过破坏性 DSN 闸 —— 这一档**没有跑**。")
    else:
        scenario("㉔")
        print("\n㉔ 同名但在另一台集群上（只有真 PG 能验）")
        db = "kline_pilot_selfcheck_p24"
        await _drop(base_dsn, db)
        await _drop(dsn2, db)
        far = await asyncpg.connect(dsn2)
        try:
            await far.execute("CREATE DATABASE " + quote_ident(db) + " TEMPLATE template0")
            id1 = await (await asyncpg.connect(base_dsn)).fetchval(
                "SELECT system_identifier::text FROM pg_control_system()")
            id2 = await far.fetchval("SELECT system_identifier::text FROM pg_control_system()")
            check(id1 != id2, "前提：两个 DSN 确实是不同集群", f"两边都是 {id1}")
        finally:
            await far.close()

        async def _far_connect(name: str):
            return await asyncpg.connect(_db_dsn(dsn2, name))

        maint = await _maintenance(base_dsn, seed="selfcheck_p24")
        try:
            try:
                await create_pilot_database(maint, connect=_far_connect, db_name=db,
                                            seed="selfcheck_p24", run_id="verify-p24", **_ARGS)
                check(False, "连接落在另一台集群时必须失败")
            except Exception as exc:
                check(getattr(exc, "code", None) == "connection_wrong_cluster",
                      "失败原因是 connection_wrong_cluster",
                      f"实得 {type(exc).__name__}: {exc}")
        finally:
            await maint.close()
        check(await _relation_exists(dsn2, db, "pilot_meta") is False,
              "另一台集群上那个同名库里一张表都没建",
              "DDL 落到了另一台机器上 —— 信任边界整个错位")
        await _drop(dsn2, db)
        await _drop(base_dsn, db)
        m = await _maintenance(base_dsn)
        try:
            await m.execute(
                "DELETE FROM public.pilot_create_intent WHERE dbname LIKE 'kline_pilot_selfcheck_p24%'")
            await m.execute(
                "DELETE FROM public.pilot_database_registry WHERE dbname LIKE 'kline_pilot_selfcheck_p24%'")
        finally:
            await m.close()

    # ── ㉕ 业务 schema 的**活目录**指纹（O4-R32-C2，只有真 PG 能验）─────────────
    #    钉住「规范常量 ↔ 活库」这一半（另一半「固件 ↔ 常量」由 host 测试钉）。
    #    ⚠️ 这个值对 PostgreSQL **大版本敏感**（pg_get_constraintdef / pg_get_indexdef
    #    的渲染会变）。升级 PG 之后这一档会**当场变红并打印实际值** ——
    #    那是「请重新生成常量」，不是「schema 漂移了」。这条提示写在断言的 detail 里。
    scenario("㉕")
    print("\n㉕ 业务 schema 的活目录指纹 = 规范常量（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p25"
    await _drop(base_dsn, db)
    m = await asyncpg.connect(base_dsn)
    try:
        await m.execute("CREATE DATABASE " + quote_ident(db) + " TEMPLATE template0")
    finally:
        await m.close()
    fresh = await asyncpg.connect(_db_dsn(base_dsn, db))
    try:
        await pin_search_path(fresh)
        await fresh.execute(_SCHEMA_SQL)
        live = await fresh.fetchval(_BUSINESS_CATALOG_FINGERPRINT_SQL)
    finally:
        await fresh.close()
    live_sha = sha256_of_sql(live or "")
    check(live_sha == CANONICAL_BUSINESS_CATALOG_SHA256,
          "刚用规范 schema.sql 建好的库，其活目录指纹等于 CANONICAL_BUSINESS_CATALOG_SHA256",
          f"实得 {live_sha!r}，常量是 {CANONICAL_BUSINESS_CATALOG_SHA256!r}。"
          f"⚠️ 若刚升级过 PostgreSQL 大版本，这是**渲染差异**：把实得值填进常量与固件"
          f"（backend/tests/fixtures/business_catalog_fingerprint.txt）即可。")
    # ⚠️ **按 PostgreSQL 自己的列清单核覆盖率**（O4-R38-C1）：指纹取哪些字段，
    #    不该由我记得住多少决定。凡是 `pg_sequences` 里的列，要么在指纹 SQL 里，
    #    要么在**写明理由的排除清单**里；PG 升级新增一列 → 这条变红，
    #    而不是静默地少覆盖一维（R34 挑三个字段就是这么漏的）。
    seq_cols = {r["column_name"] for r in await (
        await asyncpg.connect(_db_dsn(base_dsn, db))).fetch(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_name = 'pg_sequences'")}
    excluded = {"schemaname",      # 指纹本就只取 public
                "sequencename",    # 已作为行首键
                "last_value",      # 运行时状态：每插一行就变，取了指纹不再确定
                "sequenceowner"}   # 随部署角色名而变，与 DDL 正确性无关
    uncovered = {c for c in seq_cols - excluded
                 if f"s.{c}" not in _BUSINESS_CATALOG_FINGERPRINT_SQL}
    check(not uncovered, "pg_sequences 的每一列要么进指纹、要么在写明理由的排除清单里",
          f"未覆盖也未登记排除：{sorted(uncovered)}")
    check(bool(seq_cols) and excluded <= seq_cols,
          "反向断言：列清单真的读出来了、排除项确实是现存的列",
          f"实得 {sorted(seq_cols)}")
    check((live or "").count("--constraints--") == 1 and (live or "").count("--indexes--") == 1,
          "指纹确实覆盖了约束段与索引段（不是只有列）",
          f"实得段落标记缺失 —— 覆盖面已不是原来那个")
    await _drop(base_dsn, db)

    # ── ⑬ 闸 (ii) 的外部归属凭据（O4-R14-C1，只有真 PG 能验）──────────────
    #    造一个**真的** kline_pilot_* 同侪库，里面塞一份 7 键齐全、seed 与库名相符、
    #    state 合法的 pilot_meta —— 自证判据全部满足。它是否被放行，只取决于
    #    维护库的 pilot_database_registry 里有没有这个库名。
    scenario("⑬")
    print("\n⑬ 闸 (ii)：自证再严也要有外部凭据（只有真 PG 能验）")
    peer, peer_seed = "kline_pilot_selfcheck_p13", "selfcheck_p13"
    await _drop(base_dsn, peer)
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", peer)
        await maint.execute("CREATE DATABASE " + quote_ident(peer) + " TEMPLATE template0")
    finally:
        await maint.close()
    peer_conn = await asyncpg.connect(_db_dsn(base_dsn, peer))
    try:
        await peer_conn.execute(
            "CREATE TABLE public.pilot_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
            "CREATE TABLE public.unrelated_user_data (id int);")     # 非空 → 不走残骸豁免
        for k, v in (("tool", "qmt_pilot"), ("seed", peer_seed), ("export_log_sha256", "a" * 64),
                     ("output_dir", "/x/y"), ("created_at", "20260729T101530123456Z"),
                     ("pilot_schema_sha256", "c" * 64), ("state", "ready")):
            await peer_conn.execute(
                "INSERT INTO public.pilot_meta (key, value) VALUES ($1, $2)", k, v)
    finally:
        await peer_conn.close()

    async def _peer_connect(name: str):
        return await asyncpg.connect(_db_dsn(base_dsn, name))

    async def _gate_verdict():
        m = await _maintenance(base_dsn)
        try:
            await assert_cluster_allowed(m, connect=_peer_connect,
                                         target_db="kline_pilot_selfcheck_p13x")
            return None
        except PilotClusterBoundaryError as exc:
            return exc
        finally:
            await m.close()

    exc = await _gate_verdict()
    check(exc is not None and exc.code == "unowned_pilot_database",
          "自证齐全但**未登记** → 闸 (ii) 必须拒",
          f"实得 {exc.code if exc else '放行了'} —— 往任意非空库塞一份 pilot_meta 就骗过了集群边界")

    maint = await _maintenance(base_dsn)
    try:
        await maint.execute(
            "INSERT INTO public.pilot_database_registry"
            " (dbname, seed, run_id, claimed_at, db_oid)"
            " SELECT $1, $2, 'verify-p13', '20260729T101530123456Z', d.oid"
            "   FROM pg_database d WHERE d.datname::text = $1", peer, peer_seed)
    finally:
        await maint.close()
    exc = await _gate_verdict()
    check(exc is None, "登记之后放行（证明上一条不是恒拒）", f"实得 {exc}")

    peer_conn = await asyncpg.connect(_db_dsn(base_dsn, peer))
    try:
        await peer_conn.execute(
            "UPDATE public.pilot_meta SET value = 'not_our_seed' WHERE key = 'seed'")
    finally:
        await peer_conn.close()
    exc = await _gate_verdict()
    check(exc is not None and exc.code == "unowned_pilot_database",
          "登记过但自证坏掉 → 仍须拒（两个事实都要）", f"实得 {exc.code if exc else '放行了'}")

    # (d) **陈旧的名字凭据不得为新实例背书**（O4-R16-C2）：
    #     把库删掉、用同名重建（这就是「别人用同名建了个库」），登记行原样留着。
    #     只绑名字时这一档会被放行 —— 对手不需要维护库写权限就能过闸 (ii)。
    peer_conn = await asyncpg.connect(_db_dsn(base_dsn, peer))
    try:
        await peer_conn.execute(
            "UPDATE public.pilot_meta SET value = $1 WHERE key = 'seed'", peer_seed)
    finally:
        await peer_conn.close()
    exc = await _gate_verdict()
    check(exc is None, "自证修回来之后先放行（下一步才有对照）", f"实得 {exc}")

    m = await _maintenance(base_dsn)
    try:
        old_oid = await m.fetchval("SELECT oid FROM pg_database WHERE datname = $1", peer)
        registered_oid = await m.fetchval(
            "SELECT db_oid FROM public.pilot_database_registry WHERE dbname = $1", peer)
        check(old_oid == registered_oid, "登记行记的就是当前实例的 OID",
              f"登记={registered_oid} 实际={old_oid}")
    finally:
        await m.close()

    await _drop(base_dsn, peer)                      # 我们的库没了，登记行**故意**留着
    m = await _maintenance(base_dsn)
    try:
        await m.execute("CREATE DATABASE " + quote_ident(peer)          # 别人用同名重建
                        + " TEMPLATE template0")
        new_oid = await m.fetchval("SELECT oid FROM pg_database WHERE datname = $1", peer)
        check(new_oid != old_oid, "重建后 OID 确实变了（本档的前提）",
              f"新={new_oid} 旧={old_oid}")
    finally:
        await m.close()
    peer_conn = await asyncpg.connect(_db_dsn(base_dsn, peer))
    try:
        await peer_conn.execute(
            "CREATE TABLE public.pilot_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
            "CREATE TABLE public.unrelated_user_data (id int);")
        for k, v in (("tool", "qmt_pilot"), ("seed", peer_seed), ("export_log_sha256", "a" * 64),
                     ("output_dir", "/x/y"), ("created_at", "20260729T101530123456Z"),
                     ("pilot_schema_sha256", "c" * 64), ("state", "ready")):
            await peer_conn.execute(
                "INSERT INTO public.pilot_meta (key, value) VALUES ($1, $2)", k, v)
    finally:
        await peer_conn.close()
    exc = await _gate_verdict()
    check(exc is not None and exc.code == "unowned_pilot_database",
          "同名重建的**新实例**不得被陈旧登记行背书 → 必须拒",
          f"实得 {exc.code if exc else '放行了'} —— 只绑名字的凭据会为它背书")

    await _drop(base_dsn, peer)
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", peer)
    finally:
        await maint.close()

    # ── ⑭ 敌意 search_path 遮蔽**系统目录**（O4-R17-C1，只有真 PG 能验）─────
    #    实测：`SET search_path = evil, pg_catalog, public` 之后
    #    `SELECT count(*) FROM pg_class` 从 425 行变成 1 行 —— 裸目录名解析到了
    #    对手建的影子表，整台集群的「除本工具外别无他物」在假数据上求值。
    scenario("⑭")
    print("\n⑭ 敌意 search_path 遮蔽系统目录（只有真 PG 能验）")
    setup = await asyncpg.connect(base_dsn)
    try:
        await setup.execute("CREATE SCHEMA IF NOT EXISTS zzqmtverify_shadow_ns")
        await setup.execute(
            "DROP TABLE IF EXISTS zzqmtverify_shadow_ns.pg_class;"
            " CREATE TABLE zzqmtverify_shadow_ns.pg_class"
            " (oid oid, relname text, relkind \"char\", relnamespace oid,"
            "  reltoastrelid oid, reltype oid, relisshared boolean)")
        # 维护库里放一个**真的**用户对象：没被遮蔽时闸 (iii) 必须看见它
        await setup.execute("DROP TABLE IF EXISTS public.zzqmtverify_probe_a;"
                            " CREATE TABLE public.zzqmtverify_probe_a (id int)")
    finally:
        await setup.close()

    hostile = await asyncpg.connect(base_dsn)
    try:
        await hostile.execute("SET search_path = zzqmtverify_shadow_ns, pg_catalog, public")
        shadowed = await hostile.fetchval("SELECT count(*) FROM pg_class")
        check(shadowed == 0, "前提：裸 pg_class 确实被影子表遮蔽了",
              f"影子表里 {shadowed} 行 —— 遮蔽没生效，本档证明不了任何事")

        # 遮蔽状态下判据是坏的：要么读到假数据、要么直接查不动（都不可接受）
        broken = None
        try:
            broken = await _user_objects(hostile, exempt_maintenance=True)
        except Exception as exc:
            broken = f"抛异常：{type(exc).__name__}"
        check(broken != [("pg_class", 0)] and broken is not None,
              "前提：没钉 search_path 时判据确实是坏的", f"实得 {broken}")

        # 钉桩之后必须恢复：看见维护库里那个**真的**用户对象
        await pin_search_path(hostile)
        after = await hostile.fetchval("SELECT count(*) FROM pg_class")
        check(after > 400, "钉桩后裸 pg_class 重新解析到真目录",
              f"实得 {after} 行")
        objs = await _user_objects(hostile, exempt_maintenance=True)
        check(bool(objs), "钉桩后闸 (iii) 看得见真实的用户对象",
              f"实得 {objs} —— 判据仍跑在对手控制的影子目录上")
    finally:
        await hostile.close()

    cleanup = await asyncpg.connect(base_dsn)
    try:
        await cleanup.execute("DROP TABLE IF EXISTS public.zzqmtverify_probe_a")
        await cleanup.execute("DROP SCHEMA IF EXISTS zzqmtverify_shadow_ns CASCADE")
    finally:
        await cleanup.close()

    # ── ⑮ 会话临时 schema 遮蔽系统目录（O4-R18-C1，只有真 PG 能验）─────────
    #    比 ⑭ 更难堵：`pg_temp` 在**关系名与类型名**解析上，未被显式列出时隐式排在
    #    **`pg_catalog` 之前**。不需要建 schema、不需要额外权限 ——
    #    任何能连上来的会话 `CREATE TEMP TABLE pg_class (...)` 即可。
    scenario("⑮")
    print("\n⑮ 会话临时 schema 遮蔽系统目录（只有真 PG 能验）")
    tmp_hostile = await asyncpg.connect(base_dsn)
    try:
        await tmp_hostile.execute("CREATE TABLE public.zzqmtverify_probe_b (id int)")
        await tmp_hostile.execute(
            "CREATE TEMP TABLE pg_class (oid oid, relname text, relkind \"char\","
            " relnamespace oid, reltoastrelid oid, reltype oid, relisshared boolean)")
        await tmp_hostile.execute("SET search_path = public")     # R17 的钉法
        shadowed = await tmp_hostile.fetchval("SELECT count(*) FROM pg_class")
        check(shadowed == 0,
              "前提：只钉 `public` 时临时表确实遮蔽了 pg_class",
              f"实得 {shadowed} 行 —— 遮蔽没生效，本档证明不了任何事")

        await pin_search_path(tmp_hostile)                        # R18 的钉法
        after = await tmp_hostile.fetchval("SELECT count(*) FROM pg_class")
        check(after > 400, "显式把 pg_temp 排到末尾后恢复真目录", f"实得 {after} 行")
        objs = await _user_objects(tmp_hostile, exempt_maintenance=True)
        check(bool(objs), "钉桩后闸 (iii) 看得见真实的用户对象",
              f"实得 {objs} —— 判据仍跑在临时影子表上")
        await tmp_hostile.execute("DROP TABLE IF EXISTS public.zzqmtverify_probe_b")
    finally:
        await tmp_hostile.close()

    # ── ⑯ 过期的**已确认** intent 被新 run 抢占后，恢复凭据不得被抹掉（O4-R18-C3）──
    #    上一次建出了库、确认过、崩在写 pilot_meta 之前；过 TTL 后另一次运行来抢占。
    #    按 run_id 判确认位时，这一档会把 true 打回 false → 紧接着 CREATE 撞
    #    duplicate_database → 确定性失败清理把行删掉 → 空残骸再也清不掉。
    scenario("⑯")
    print("\n⑯ 过期抢占不得抹掉恢复凭据（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p16"
    await _drop(base_dsn, db)

    async def _connect_boom16(name: str):
        raise _Boom("注入：确认之后、连目标库之前断连")

    maint = await _maintenance(base_dsn, seed="selfcheck_p16")
    try:
        try:
            await create_pilot_database(maint, connect=_connect_boom16, db_name=db,
                                        seed="selfcheck_p16", run_id="verify-p16-A", **_ARGS)
        except _Boom:
            pass
    finally:
        await maint.close()

    maint = await _maintenance(base_dsn)
    try:
        row = await maint.fetchrow(
            "SELECT run_id, create_confirmed FROM public.pilot_create_intent"
            " WHERE dbname = $1", db)
        check(row is not None and row["create_confirmed"] is True,
              "第一次：留下空残骸 + 已确认的 intent 行",
              f"实得 {dict(row) if row else None}")
        # 把它挪到 TTL 之外。
        # ⚠️ 老化必须动 `inserted_at`（O4-R23-C1）：新鲜度不再看调用方传的 created_at ——
        #    那正是这次要修掉的东西（调用方能让一行 DROP 授权永不过期、或立刻可被抢走）。
        await maint.execute(
            "UPDATE public.pilot_create_intent"
            " SET inserted_at = now() - interval '999 days' WHERE dbname = $1", db)
    finally:
        await maint.close()

    maint = await _maintenance(base_dsn, seed="selfcheck_p16")
    try:
        try:
            await create_pilot_database(maint, connect=_connect_boom16, db_name=db,
                                        seed="selfcheck_p16", run_id="verify-p16-B", **_ARGS)
            check(False, "第二次（新 run_id）应撞 duplicate_database")
        except Exception as exc:
            check(getattr(exc, "sqlstate", None) == "42P04",
                  "第二次（新 run_id）撞 duplicate_database",
                  f"实得 {type(exc).__name__}: {exc}")
    finally:
        await maint.close()

    maint = await _maintenance(base_dsn)
    try:
        row = await maint.fetchrow(
            "SELECT run_id, create_confirmed FROM public.pilot_create_intent"
            " WHERE dbname = $1", db)
        check(row is not None and row["create_confirmed"] is True,
              "过期抢占之后凭据必须**仍在且仍为 true**（库还在，那句确认仍然成立）",
              f"实得 {dict(row) if row else None} —— 空残骸从此没有任何销毁授权")
    finally:
        await maint.close()

    # ⑯b **同名重建**之后，陈旧确认位不得被刷新到新实例上（O4-R21-C1）
    #     只按「当前是否存在同名库」判时，这一档会保住 true —— 而这一行正是零对象例外的
    #     DROP 授权，于是一个无关的空库（或 `pg_restore --create` 的中途窗口）会被当成
    #     「本次的崩溃残骸」删掉。
    maint = await _maintenance(base_dsn)
    try:
        old_oid = await maint.fetchval(
            "SELECT db_oid FROM public.pilot_create_intent WHERE dbname = $1", db)
        check(old_oid is not None, "确认那一步记下了实例 oid（本档的前提）")
    finally:
        await maint.close()
    await _drop(base_dsn, db)                       # 我们的库没了
    maint = await _maintenance(base_dsn)
    try:
        # 别人用同名建了一个全新的空库
        await maint.execute("CREATE DATABASE " + quote_ident(db) + " TEMPLATE template0")
        new_oid = await maint.fetchval(
            "SELECT oid FROM pg_database WHERE datname::text = $1", db)
        check(new_oid != old_oid, "重建后 OID 确实变了（本档的前提）",
              f"新={new_oid} 旧={old_oid}")
        await maint.execute(
            "UPDATE public.pilot_create_intent"
            " SET inserted_at = now() - interval '999 days' WHERE dbname = $1", db)
    finally:
        await maint.close()
    maint = await _maintenance(base_dsn, seed="selfcheck_p16")
    try:
        try:
            await create_pilot_database(maint, connect=_connect_boom16, db_name=db,
                                        seed="selfcheck_p16", run_id="verify-p16-D", **_ARGS)
        except Exception:
            pass
    finally:
        await maint.close()
    maint = await _maintenance(base_dsn)
    try:
        row = await maint.fetchrow(
            "SELECT create_confirmed, db_oid FROM public.pilot_create_intent"
            " WHERE dbname = $1", db)
        # 判据是「**不存在**为这个新实例背书的已确认凭据」——行被整条删掉同样成立
        # （抢占时确认位因 oid 不符归零 → 紧接着 42P04 → 「只删未确认行」的清理把它删了，
        #  比留一行未确认的更干净）。只按名字判时这里会留成 create_confirmed=true。
        check(row is None or row["create_confirmed"] is False,
              "同名**重建**后不得留下已确认的凭据（陈旧凭据不为新实例背书）",
              f"实得 {dict(row) if row else None} —— 只按名字判时这里会留成 true")
    finally:
        await maint.close()

    # 库被删掉之后，同一条抢占必须把确认位归零（那句确认已无所指）
    await _drop(base_dsn, db)
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute(
            "UPDATE public.pilot_create_intent"
            " SET inserted_at = now() - interval '999 days' WHERE dbname = $1", db)
    finally:
        await maint.close()
    maint = await _maintenance(base_dsn, seed="selfcheck_p16")
    try:
        try:
            await create_pilot_database(maint, connect=_connect_boom16, db_name=db,
                                        seed="selfcheck_p16", run_id="verify-p16-C", **_ARGS)
        except _Boom:
            pass
    finally:
        await maint.close()
    await _drop(base_dsn, db)
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
        await maint.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", db)
    finally:
        await maint.close()

    # (g) 把 create_confirmed 的 DEFAULT 改成 true → 闸 (iii) 必须看见
    #     白名单按**表达式文本**钉死就是为了这一刀：新 intent 行天生「已确认」，
    #     O4-R8-C2 那道持久证明会被整个掏空。只按表名豁免的话这里是静默放行。
    maint = await _maintenance(base_dsn)
    try:
        await maint.execute("ALTER TABLE public.pilot_create_intent "
                            "ALTER COLUMN create_confirmed SET DEFAULT true")
        objs = await _user_objects(maint, exempt_maintenance=True)
        check(bool(objs), "篡改 create_confirmed 的 DEFAULT 必须让闸 (iii) 判非空",
              "只按表名豁免会静默放行 —— 新 intent 行天生「已确认」")
        await maint.execute("ALTER TABLE public.pilot_create_intent "
                            "ALTER COLUMN create_confirmed SET DEFAULT false")
        objs = await _user_objects(maint, exempt_maintenance=True)
        check(not objs, "改回规范 DEFAULT 后恢复判空（证明上一条不是恒真）",
              f"残留 {objs}")
        await maint.execute("DELETE FROM public.pilot_create_intent WHERE dbname LIKE 'kline_pilot_selfcheck_%'")
        # 同上：登记表永不清理 → 本脚本必须自己收尾，否则下一次运行带着上一次的凭据跑。
        await maint.execute("DELETE FROM public.pilot_database_registry WHERE dbname LIKE 'kline_pilot_selfcheck_%'")
    finally:
        await maint.close()

    # ── ㉖ 建库之后、凭据落库之前被同名替换（O4-R36-C1，只有真 PG 能验）────────
    #    host 假件只能证明「模块对 UPDATE 0 / 空登记的反应正确」；
    #    「PG 真的按 SQL 里那个 oid 谓词拒绝」只有真库能证。
    scenario("㉖")
    print("\n㉖ 建库与写凭据之间被同名替换 → 绝不给替身发凭据（只有真 PG 能验）")
    db, seed26 = "kline_pilot_selfcheck_p26", "selfcheck_p26"

    async def _plain_connect(name: str):
        return await asyncpg.connect(_db_dsn(base_dsn, name))

    async def _run26(trigger):
        """跑一次建库；返回 (异常, 代理)。前置把两张表上这个库名的行清干净。"""
        await _drop(base_dsn, db)
        m = await _maintenance(base_dsn)
        try:
            await m.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
            await m.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", db)
        finally:
            await m.close()
        raw = await _maintenance(base_dsn, seed=seed26)
        proxy = _ReplaceTargetMaint(raw, base_dsn, db, trigger)
        try:
            await create_pilot_database(proxy, connect=_plain_connect, db_name=db,
                                        seed=seed26, run_id="verify-p26", **_ARGS)
            return None, proxy
        except Exception as exc:                       # 本档要的就是它拒
            return exc, proxy
        finally:
            await raw.close()

    async def _creds():
        m = await _maintenance(base_dsn)
        try:
            row = await m.fetchrow(
                "SELECT create_confirmed, db_oid FROM public.pilot_create_intent"
                " WHERE dbname = $1", db)
            reg = await m.fetchval(
                "SELECT count(*) FROM public.pilot_database_registry WHERE dbname = $1", db)
            reg_oid = await m.fetchval(
                "SELECT db_oid FROM public.pilot_database_registry WHERE dbname = $1", db)
            return row, reg, reg_oid
        finally:
            await m.close()

    # (a) 替换发生在**读到 oid 之后、写确认位之前**
    exc, proxy = await _run26(lambda kind, q: kind == "fetchval"
                              and "d.oid::text FROM pg_database d" in q)
    check(proxy.replacement_oid is not None, "㉖a 前提：替身确实被建出来了")
    check(isinstance(exc, PilotClusterBoundaryError)
          and exc.code == "created_database_replaced",
          "㉖a 建库→确认之间被同名替换 → created_database_replaced",
          f"实得 {getattr(exc, 'code', exc)!r} —— 只按名字取 oid 时，"
          f"替身会被盖上 create_confirmed=true（那是一张 DROP 授权）")
    row, reg, _ = await _creds()
    check(row is None or row["create_confirmed"] is False,
          "㉖a 替身身上不得留下已确认的 intent 行", f"实得 {dict(row) if row else None}")
    check(row is None or row["db_oid"] != proxy.replacement_oid,
          "㉖a intent 行绝不能绑到替身的 oid 上",
          f"实得 db_oid={row['db_oid'] if row else None} 替身={proxy.replacement_oid}")
    check(reg == 0, "㉖a 确认没成立 → 登记表一行都不许写（这张表本工具从不清）",
          f"实得 {reg} 行")

    # (b) 替换发生在**确认之后、登记之前** —— 登记那句 SELECT 必须按 oid 取行
    exc, proxy = await _run26(lambda kind, q: kind == "execute"
                              and "SET create_confirmed = true" in q)
    check(proxy.replacement_oid is not None, "㉖b 前提：替身确实被建出来了")
    check(isinstance(exc, PilotClusterBoundaryError) and exc.code == "registry_not_written",
          "㉖b 确认→登记之间被同名替换 → registry_not_written",
          f"实得 {getattr(exc, 'code', exc)!r} —— 只按名字取行时，"
          f"替身会拿到一张**永不清理**的归属凭据")
    row, reg, _ = await _creds()
    check(reg == 0, "㉖b 登记表一行都不许写", f"实得 {reg} 行")
    check(row is not None and row["db_oid"] != proxy.replacement_oid,
          "㉖b 确认位记的是本次建的那个实例，不是替身",
          f"实得 db_oid={row['db_oid'] if row else None} 替身={proxy.replacement_oid}")

    # (c) 对照组：不做替换，同一段代码必须**走通** —— 否则上面两条可能只是恒拒
    exc, proxy = await _run26(lambda kind, q: False)
    check(exc is None, "㉖c 不替换时同一路径必须成功（证明 a/b 不是恒拒）", f"实得 {exc!r}")
    row, reg, reg_oid = await _creds()
    m = await _maintenance(base_dsn)
    try:
        live_oid = await m.fetchval(
            "SELECT oid FROM pg_database WHERE datname::text = $1", db)
    finally:
        await m.close()
    # ⚠️ 成功收尾会把 intent 行**删掉**（`_CLEAR_INTENT_SQL`）—— 这是对的，
    #    所以正常路径要核的是「登记行绑到了当前实例」+「intent 行已清干净」。
    #    （第一版把 intent 行的 db_oid 当判据，被这一组对照当场判红：
    #     对照组的作用正是在这里 —— 它证伪的是**我对正常路径的预期**。）
    check(reg == 1 and reg_oid == live_oid,
          "㉖c 正常路径下登记行绑到了当前实例", f"reg={reg} reg_oid={reg_oid} live={live_oid}")
    check(row is None, "㉖c 正常收尾把 intent 行清干净了", f"实得 {dict(row) if row else None}")

    await _drop(base_dsn, db)
    m = await _maintenance(base_dsn)
    try:
        await m.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
        await m.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", db)
    finally:
        await m.close()

    # ── ㉗ 守卫表被 SET UNLOGGED / 挂 RLS（O4-R37-C2，只有真 PG 能验）──────────
    #    host 层只能证明「SQL 文本里写着这些判据」+「库报 false 时模块会拒」；
    #    「PostgreSQL 真的因为 UNLOGGED 而让判据为假」只有真库能证。
    scenario("㉗")
    print("\n㉗ 守卫表被 SET UNLOGGED / 挂 RLS → 不许标 ready、不许放行集群（只有真 PG 能验）")
    db = "kline_pilot_selfcheck_p27"

    # (a) 目标库的 pilot 专用表：apply schema.sql 之后被改成 UNLOGGED
    for tbl in ("pilot_meta", "pilot_stock_source"):
        await _drop(base_dsn, db)
        m = await _maintenance(base_dsn)
        try:
            await m.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
            await m.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", db)
        finally:
            await m.close()
        connect, _holder = _saboteur(base_dsn, f"ALTER TABLE public.{tbl} SET UNLOGGED")
        maint = await _maintenance(base_dsn, seed="selfcheck_p27")
        try:
            exc = None
            try:
                await create_pilot_database(maint, connect=connect, db_name=db,
                                            seed="selfcheck_p27", run_id="verify-p27",
                                            **_ARGS)
            except Exception as e:
                exc = e
        finally:
            await maint.close()
        check(getattr(exc, "code", None) == "pilot_schema_invalidated",
              f"㉗a {tbl} 被 SET UNLOGGED → pilot_schema_invalidated",
              f"实得 {getattr(exc, 'code', exc)!r} —— 列/主键判据全都照旧为真，"
              f"只有表级 relpersistence 看得见它；崩溃后这张表会被 truncate")
        ready = await _relation_exists(base_dsn, db, "pilot_meta")
        if ready:
            probe = await asyncpg.connect(_db_dsn(base_dsn, db))
            try:
                state = await probe.fetchval(
                    "SELECT value FROM public.pilot_meta WHERE key = 'state'")
            finally:
                await probe.close()
            check(state != "ready", f"㉗a {tbl} 被掏空的库绝不能是 ready", f"实得 state={state!r}")

    # (b) 维护库的三张表：SET UNLOGGED / FORCE RLS 都必须让闸 (i) 拒
    async def _gate():
        m = await _maintenance(base_dsn)
        try:
            await assert_cluster_allowed(m, connect=_plain_connect_p27,
                                         target_db="kline_pilot_selfcheck_p27x")
            return None
        except PilotClusterBoundaryError as e:
            return e
        finally:
            await m.close()

    check(await _gate() is None, "㉗b 前提：未被动手时闸 (i) 放行（证明下面不是恒拒）")
    for tbl, hostile, undo in (
            ("pilot_cluster_marker", "SET UNLOGGED", "SET LOGGED"),
            ("pilot_create_intent", "SET UNLOGGED", "SET LOGGED"),
            ("pilot_database_registry", "SET UNLOGGED", "SET LOGGED"),
            ("pilot_create_intent", "ENABLE ROW LEVEL SECURITY",
             "DISABLE ROW LEVEL SECURITY"),
            ("pilot_database_registry", "FORCE ROW LEVEL SECURITY",
             "NO FORCE ROW LEVEL SECURITY"),
    ):
        m = await _maintenance(base_dsn)
        try:
            await m.execute(f"ALTER TABLE public.{tbl} {hostile}")
        finally:
            await m.close()
        exc = await _gate()
        m = await _maintenance(base_dsn)
        try:
            await m.execute(f"ALTER TABLE public.{tbl} {undo}")
        finally:
            await m.close()
        check(exc is not None and exc.code == "no_marker",
              f"㉗b {tbl} {hostile} → 闸 (i) 必须拒",
              f"实得 {getattr(exc, 'code', '放行了')!r} —— UNLOGGED 的 intent 行崩溃后被 "
              f"truncate，而它是零对象例外授权 DROP DATABASE 的凭据；"
              f"RLS 则让普通角色读不到本该看见的凭据")
        check(await _gate() is None, f"㉗b 撤销 {hostile} 后恢复放行（证明上一条不是恒拒）")

    await _drop(base_dsn, db)
    m = await _maintenance(base_dsn)
    try:
        await m.execute("DELETE FROM public.pilot_create_intent WHERE dbname = $1", db)
        await m.execute("DELETE FROM public.pilot_database_registry WHERE dbname = $1", db)
    finally:
        await m.close()

    missing = [t for t in _EXPECTED_SCENARIOS if t not in ran]
    if missing:
        failures.append(f"这些档**没有跑**：{missing}")
        print(f"  FAIL  场景完整性  —— 这些档没有跑：{missing}"
              f"（exit 0 必须意味着每一档都真的执行过）")

    print()
    if failures:
        print(f"❌ {len(failures)} 条断言不成立：{failures}")
        return 1
    # ⚠️ 档数**现算**，不写死：散文里的手写计数在本仓已漂过多次（O4-R36 收尾时
    #    发现这行还停在「二十六档」、模块头还停在「九档」）。
    print(f"✅ {len(_EXPECTED_SCENARIOS)} 档断言全部成立（真 PostgreSQL）")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
