# backend/scripts/_pilot_verify_harness.py
"""pilot 真-PG 验收脚本的**共用安全护栏**。

本模块只放**三个脚本逐字相同、且漂移会造成不可逆损失**的那几段：
破坏性 DSN 闸、只肯对过闸 DSN 动手的 `drop_database`、换库名的 `db_dsn`，
以及「新增了 DSN 却忘了给它加闸」的源码反向自检。

**刻意不放进来的**：`scenario()` / `check()` / 前置清场那套。它们每个脚本各不相同
（档位标记、库名白名单、临时对象都不一样），且用闭包捕获 `main()` 的局部状态；
它们漂移最多是某个脚本自己的账本不准，各自的完整性闸会抓到 —— 与「误删别人的数据库」
不是一个量级。**按被保护的性质抽，不按「看起来像重复」抽。**

⚠️ 存在的理由：`verify_pilot_two_phase_create.py` 里这套护栏是 codex 花了
O4-R9-C2 / O4-R33-C2 / O4-R34-C2 / O4-R37-C1 四轮才收口的。新脚本各抄一份
＝把「同一条判据只落在被点名的那一处」这个本仓重演十二次的毛病，
原样搬到**防止误删数据库**的代码上。
"""
from __future__ import annotations

import os
import pathlib
import re
import sys
from urllib.parse import urlparse

import asyncpg

_BACKEND = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND))

from qmt_pilot_db import quote_ident  # noqa: E402

# 过了破坏性闸的 DSN。`drop_database` 只肯对这里面的动手。
_GUARDED_DSNS: set[str] = set()


def assert_destructive_dsn_allowed(dsn: str, label: str) -> str | None:
    """破坏性 DSN 闸。**必须先于对该 DSN 的任何 connect/DDL**。

    ⚠️ 每一个会被建库/删库的 DSN 都要过（O4-R37-C1）：上一版只闸了 `DSN`，
    而 `DSN2` 从环境变量读出来就直接 `_drop(dsn2, …)` —— 脚本对外宣称
    「破坏性操作有护栏」，却对第二个集群**一次都没检查**。

    返回 None = 不放行（调用方负责判失败并给出退出码）。
    """
    host = urlparse(dsn).hostname
    if host not in ("localhost", "127.0.0.1", "::1") and os.environ.get(
            "QMT_VERIFY_ALLOW_DESTRUCTIVE") != "1":
        print(f"拒绝运行：{label} 指向非本地库 {host}，本脚本会在它上面建/删库。"
              "仅对隔离测试库运行；确需对非本地库运行请设 QMT_VERIFY_ALLOW_DESTRUCTIVE=1",
              file=sys.stderr)
        return None
    _GUARDED_DSNS.add(dsn)
    return dsn


def db_dsn(base_dsn: str, dbname: str) -> str:
    """把 DSN 的**库名**换掉。

    ⚠️ 绝不能用 `str.replace` —— 用户名也可能叫 `postgres`。
    """
    head, _, _ = base_dsn.rpartition("/")
    return f"{head}/{dbname}"


async def drop_database(base_dsn: str, dbname: str) -> None:
    """DROP 一个库。**只对过了破坏性闸的 DSN 执行**（O4-R37-C1）。

    ⚠️ 「记得给新 DSN 加闸」是纪律，而纪律在这套代码里已经失效十二次；
       这一句让漏加闸的新 DSN 在**第一次删库之前**就炸掉，而不是删完才发现。
    ⚠️ 库名一律走 `quote_ident`：清场时名字是从 `pg_database` 按 LIKE 读回来的、
       **不是常量**，而 PostgreSQL 的库名可以含引号/分号，asyncpg 又支持多语句。
    """
    if base_dsn not in _GUARDED_DSNS:
        raise AssertionError(
            f"DROP DATABASE 的目标 DSN 没有过破坏性闸：{urlparse(base_dsn).hostname!r}。"
            f"先调用 assert_destructive_dsn_allowed(dsn, '<名字>')")
    conn = await asyncpg.connect(base_dsn)
    try:
        await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(dbname))
    finally:
        await conn.close()


def assert_every_dsn_env_is_gated(script_path: str | pathlib.Path) -> int | None:
    """**反向断言**：脚本读了几个 `DSN*` 环境变量，就必须有几个走过破坏性闸。

    ⚠️ 只在新增 DSN 处补一句「记得加闸」是纪律；这一句让「新增 DSN3 却忘了加闸」
       在**任何连接发生之前**就把脚本挡住。返回退出码或 None（放行）。

    判据挂在**调用方的源码**上，故必须由调用方把自己的 `__file__` 传进来 ——
    用本模块的 `__file__` 就成了永远自查本文件的恒真断言。
    """
    src = pathlib.Path(script_path).read_text(encoding="utf-8")
    envs = set(re.findall(r'os\.environ\.get\("(DSN\d*)"\)', src))
    gated = set(re.findall(
        r'assert_destructive_dsn_allowed\([A-Za-z_0-9]+, "(DSN\d*)"\)', src))
    missing = envs - gated
    if missing:
        print(f"拒绝运行：这些 DSN 环境变量没有过破坏性闸：{sorted(missing)}"
              f" —— 本脚本会在它们上面建/删库", file=sys.stderr)
        return 7
    if envs and not gated:
        # 正则与代码脱钩时，上面那条会恒假 —— 这一句让脱钩本身变红。
        print("拒绝运行：反向断言自身失效 —— 读到了 DSN 环境变量却一个过闸调用都没匹配到",
              file=sys.stderr)
        return 7
    return None


def assert_scratch_objects_are_namespaced(scratch_objects) -> int | None:
    """临时对象名必须带 `zzqmtverify_` 归属前缀（O4-R34-C2）。

    ⚠️ 清场是**无条件 DROP**：`evil_catalog` / `tmp_probe_data` 这类通名，
       会在开发机或 CI 上把别人同名的东西不加校验地删掉。
    """
    bad = [obj for _kind, obj in scratch_objects if "zzqmtverify_" not in obj]
    if bad:
        print(f"拒绝运行：临时对象名没带 `zzqmtverify_` 前缀：{bad} —— "
              f"清场是无条件 DROP，通名会删掉别人的东西", file=sys.stderr)
        return 6
    return None


def assert_every_selfcheck_db_is_whitelisted(
        script_path: str | pathlib.Path, scenario_dbs, prefix: str) -> int | None:
    """脚本源码里出现的每个 selfcheck 库名都必须在白名单里（O4-R33-C2）。

    ⚠️ 新增场景时忘了把库名加进白名单，那个库会在收尾时留下来，
       并在下一次运行时把整个脚本挡住（strangers 分支）。
    ⚠️ **必须排在破坏性清场之前** —— 它是纯源码检查、零副作用；
       放在清场之后会被 strangers 闸先触发而永远测不到（实测踩过）。
    """
    # ⚠️ **前缀本身要排除**：调用方是把前缀当参数传进来的，那个字面量就写在被扫描的
    #    源码里（`assert_every_selfcheck_db_is_whitelisted(__file__, DBS, "前缀")`），
    #    不排除的话扫描器会把**自己的参数**报成一个未登记的库名 —— 实测当场踩到。
    #    为免这条豁免被拿去藏东西：前缀本身**不许**出现在白名单里（真库名一律带后缀）。
    if prefix in set(scenario_dbs):
        print(f"拒绝运行：白名单里出现了裸前缀 {prefix!r} —— 真库名一律带后缀；"
              f"裸前缀是扫描器的参数，把它登记成库名会让这条自检失去判别力",
              file=sys.stderr)
        return 5
    src = pathlib.Path(script_path).read_text(encoding="utf-8")
    literals = {x for x in re.findall(rf'"({re.escape(prefix)}[a-z0-9_]*)"', src)
                if x != prefix}
    unlisted = sorted(literals - set(scenario_dbs))
    if unlisted:
        print(f"拒绝运行：脚本里用到的这些库名不在白名单里：{unlisted}", file=sys.stderr)
        return 5
    return None


async def sweep_leftover_databases(conn, *, prefix: str, scenario_dbs,
                                   name_re: re.Pattern) -> list[str] | int:
    """前置清场：删掉**白名单之内**的残留库。返回删掉的名字，或退出码。

    ⚠️ **精确白名单，绝不按前缀盲删**（O4-R33-C2）：本地/共享的 PostgreSQL 上
       真有人用这个前缀建了库的话，会在任何校验之前就被**不可逆地删掉**；
       localhost 闸挡不住这一档（它挡的是「别指向远端」，不是「别删本地别人的库」）。
    """
    # ⚠️ **绝不能写 `datname LIKE prefix || '%'`**（codex 4a-2b/S1 R4-F1，high，实测复现）：
    #    `_` 在 LIKE 里是**单字符通配符**，而本仓两个前缀（`kline_pilot_lifecycle_` /
    #    `kline_pilot_conc_`）全是下划线 —— `kline0pilot0lifecycle0prod` 这种**完全
    #    不在本前缀下**的库名会被判成「本前缀下的 strangers」，于是：
    #      · 不带 force：整个脚本被它挡死（返回 4），且拒绝理由是假的；
    #      · 带 force：**直接 DROP 掉它**。
    #    实测：造 `kline0pilot0lifecycle0prod` 灌 1000 行数据，`QMT_VERIFY_FORCE_CLEANUP=1`
    #    跑一次生命周期脚本 —— 库没了，而脚本照常打印「✅ 16 档断言全部成立」。
    #    `left(datname, length($1)) = $1` 是**字面**前缀比较，不解释任何元字符。
    matched = [r["datname"] for r in await conn.fetch(
        "SELECT datname FROM pg_database WHERE left(datname, length($1)) = $1", prefix)]
    leftovers = [x for x in matched if x in scenario_dbs]
    strangers = [x for x in matched if x not in scenario_dbs]
    forced = os.environ.get("QMT_VERIFY_FORCE_CLEANUP") == "1"
    if strangers and not forced:
        print(f"拒绝运行：这些库名匹配 {prefix} 前缀但**不是本脚本建的**：{strangers}。"
              f"本脚本会不可逆地删库，故不碰不认识的名字。"
              f"确认它们可弃后设 QMT_VERIFY_FORCE_CLEANUP=1 重跑，或先自行删除。",
              file=sys.stderr)
        return 4
    if forced:
        leftovers += strangers
    # ⚠️ 二道闸，**在任何一次 DROP 之前**整体校验（不是边删边查 —— 否则第 3 个名字
    #    不合格时，前 2 个已经被删掉了）。上面那条判据将来若被改回通配符匹配，
    #    这里**抛**而不是删库：把 R4-F1 那种**静默不可逆的数据丢失**降级成一次响亮的崩溃。
    outside = [x for x in leftovers if not x.startswith(prefix)]
    if outside:
        raise AssertionError(
            f"内部错误：清场选中了不在前缀 {prefix!r} 之下的库 {outside!r} —— "
            f"已中止，本次未删任何库")
    for name in leftovers:
        # ⚠️ 名字是读回来的、不是常量 → 必须 quote_ident（O4-R20-C1）。
        #    ⚠️ 曾经在这里加过「名字不合正则就跳过」——**已撤掉**：它挡不住任何东西
        #    （转义已经挡住了），却制造了一个**不可恢复**的陷阱：崩溃留下的怪名字库
        #    会被永远跳过，而它又让集群闸判「存在无关数据库」，脚本从此再也跑不起来。
        if not name_re.fullmatch(name):
            print(f"（清掉命名异常的残留库 {name!r} —— 它只可能是本脚本崩溃时留下的）")
        await conn.execute("DROP DATABASE IF EXISTS " + quote_ident(name))
    return leftovers


async def purge_metadata_for(conn, dbnames) -> None:
    """清场：只删**点名的这些库名**在两张维护表里的登记行。

    ⚠️ **绝不能按前缀 DELETE**（codex 4a-2b/S1 R4-F2，high，实测复现）：
       `pilot_create_intent` / `pilot_database_registry` 是**恢复与归属凭据** ——
       intent 行在 `CREATE DATABASE` **之前**就写下，正是崩溃之后判「这个库是谁的、
       能不能回收」的唯一依据。按前缀删会把**别的运行**的凭据一起抹掉；再叠加
       LIKE 的 `_` 通配符（R4-F1），连不在本前缀下的名字也一起抹。
       实测：预先写入 `kline0pilot0lifecycle0prod`（不在本前缀下）与
       `kline_pilot_lifecycle_otherrun_7788`（同前缀、别的运行）两组 intent+registry，
       跑一次生命周期脚本 —— 四行全没了，而脚本照常打印「✅ 16 档断言全部成立」。
    """
    names = list(dbnames)
    await conn.execute(
        "DELETE FROM public.pilot_create_intent WHERE dbname = ANY($1::text[])", names)
    await conn.execute(
        "DELETE FROM public.pilot_database_registry WHERE dbname = ANY($1::text[])", names)
