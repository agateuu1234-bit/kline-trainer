#!/usr/bin/env python3
"""pilot seed 锁的**平台行为 + 模块验锁谓词**真-PostgreSQL 验收。

⛔ **本脚本不是 spec §6.2 第三组的 ship gate —— 那一条尚未被满足**
   （codex 4a-2b/S1 R1-F1 / R3-F1，两轮提出；R1 我只改了档位注释、
   顶部仍在逐字引用那条要求，等于还在宣称自己满足它 —— 那是**不完整的修复**）。

   spec §6.2 第三组要的是：「同 `--seed`、不同 `--maintenance-dsn` 的**两个进程** ——
   断言第二个在 `pg_try_advisory_lock` 处立刻失败返回，且未执行任何 `DROP`/`CREATE`；
   杀掉第一个后第二个能立即取得锁」。

   它要求驱动**真正取锁并做破坏性操作的那个入口**。而本模块**从不取锁**
   （spec O1-F4），取锁是调用方的事，会取 pilot seed 锁的 wrapper 属于 **4c、
   此刻还不存在**（实测：全仓 advisory lock 的取锁点在 import_csv /
   generate_training_sets / scheduler，pilot 的 seed 锁**零处**）。
   → **那一档必须加进 4c 的验收**，判据：两个真进程并发、短超时、
     并在事前事后断言败者**没建库、没删库、没写 intent/registry 行**。

   本脚本提供的是**两类证据**，都不足以替代上面那一条：
     · Ⓐ/Ⓐb/Ⓒ —— **PostgreSQL 的平台行为**（spec §4 整套互斥设计的地基假设：
       try 版立刻返回 / 锁是每集群的 / 会话级锁随连接断开释放）。
       属于「设计地基靠基础设施行为 → 必须真环境验，不能用假件」那一族；
       **没有对应的生产守卫可中和，如实登记，不为它编一个够得到的变异**。
     · Ⓑ/Ⓑb/Ⓑc/Ⓑd —— **本模块的生产判据**：`create_pilot_database` 无锁必拒
       且零副作用、`_SEED_LOCK_HELD_SQL` 不认两参数形式与共享锁的冒充。
       可中和可证伪。

⚠️ **「立刻」必须用时间断言，不能只断言返回 false**：阻塞版 `pg_advisory_lock`
   也会「最终返回」，而在一次并发运行里「等了 30 秒才失败」等于把另一次运行挂住。

⚠️ **本模块从不取锁**（spec O1-F4：advisory lock 只在同一 session 内可重入，
   模块另开连接去取会自锁）。取锁是**调用方**的事，而会取 pilot seed 锁的那个
   wrapper 属于 4c、此刻**还不存在** —— 所以本脚本无法「驱动生产取锁路径」，
   那一档要等 4c 落地后加在它的验收里。本脚本分两类档：
     · Ⓐ/Ⓐb/Ⓒ 验 **PostgreSQL 的平台行为**（spec §4 互斥设计的地基假设；
       没有对应的生产守卫可中和，如实登记，**不为它编一个够得到的变异**）；
     · Ⓑ/Ⓑb/Ⓑc/Ⓑd 验**本模块的生产判据** —— `create_pilot_database` 无锁必拒
       且零副作用、`_SEED_LOCK_HELD_SQL` 不认两参数/共享锁冒充。可中和可证伪。

用法：
    QMT_VERIFY_ALLOW_DESTRUCTIVE=1 \
    DSN="postgresql://…:55444/postgres" DSN2="postgresql://…:55445/postgres" \
        ./.venv/bin/python backend/scripts/verify_pilot_concurrency.py

⚠️ **每一次运行都要 `QMT_VERIFY_ALLOW_DESTRUCTIVE=1`**（codex R7-F1）——「本地」不是
   「可弃」。指向非本地集群还要**另外**设 `QMT_VERIFY_ALLOW_REMOTE=1`。
   退出码 8 = 同集群上已有另一个同前缀的验收在跑。
   退出码 9 = 本脚本要用的固定名角色在运行之前就已存在（不是本次造的，绝不删）。
"""
from __future__ import annotations

import asyncio
import os
import pathlib
import re
import sys
import time

import asyncpg

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import _pilot_verify_harness as harness  # noqa: E402
from qmt_pilot_db import (MARKER_PURPOSE, PilotDbBoundaryError,  # noqa: E402
                          create_pilot_database, quote_ident,
                          reset_pilot_database, sha256_of_sql)
# ⚠️ 私有名，**刻意**直接引用：Ⓑb/Ⓑc 要证伪的就是这条谓词本身，
#    在脚本里另写一份等价 SQL，两份必然漂移，而漂移会让这两档失去判别力。
from qmt_pilot_db import _SEED_LOCK_HELD_SQL  # noqa: E402

_BACKEND = pathlib.Path(__file__).resolve().parents[1]
_SCHEMA_SQL = (_BACKEND / "sql/schema.sql").read_text(encoding="utf-8")
_PILOT_SCHEMA_SQL = (_BACKEND / "sql/pilot_schema.sql").read_text(encoding="utf-8")

_BUILD_ARGS = dict(
    schema_sql=_SCHEMA_SQL,
    pilot_schema_sql=_PILOT_SCHEMA_SQL,
    schema_sha256=sha256_of_sql(_SCHEMA_SQL),
    pilot_schema_sha256=sha256_of_sql(_PILOT_SCHEMA_SQL),
    export_log_sha256="c" * 64,
    output_dir="/tmp/verify_pilot_concurrency",
    created_at="20260809T101530123456Z",
)

# 本脚本的库名前缀。与另外两个脚本分开 —— 各扫各的前缀，互不误删。
_PREFIX = "kline_pilot_conc_"
_NAME_RE = re.compile(r"\Akline_pilot_conc[a-z0-9_]*\Z")

# ⚠️ 精确白名单：清场只删这张表里的名字。
#    `b1` 这个库**本该从不存在**（Ⓑ 断言它没被建出来），但库名字面量在源码里，
#    `assert_every_selfcheck_db_is_whitelisted` 要求它照样登记；
#    而万一某次运行因缺陷真把它建出来了，清场也才收得掉。
_CONC_DBS = ("kline_pilot_conc_b1", "kline_pilot_conc_d1", "kline_pilot_conc_d2",
             "kline_pilot_conc_d3", "kline_pilot_conc_e1")

# 本脚本不在维护库里造任何临时对象。
_SCRATCH_OBJECTS: tuple = ()

# 「立刻」的判据。真机上 `pg_try_advisory_lock` 是纯内存操作，量级是微秒；
# 1 秒的阈值足够宽到不会被负载抖动打红，又足够窄到能把「换成了阻塞版」抓出来。
_IMMEDIATE_SECONDS = 1.0

# 验收闸的**完整性清单**：收尾核对每一档都真的跑过。
# ⚠️ 少一档即失败 —— 「静默没跑」与「通过了」在输出上完全一样。
_EXPECTED_SCENARIOS = ("Ⓐ", "Ⓐb", "Ⓑ", "Ⓑb", "Ⓑd", "Ⓑc", "Ⓒ", "Ⓓ", "Ⓓb", "Ⓓc", "Ⓔ")

# Ⓓ 用的普通（非超级用户）角色。`datconnlimit = 0` 对超级用户不生效，
# 所以这一档必须用一个真的普通角色，否则测的是「超级用户能不能连」——恒真。
_PLAIN_ROLE = "zzqmtverify_plain"
_PLAIN_PASSWORD = "zzqmtverify"
# Ⓔ 用的属主角色（非超级用户、有 CREATEDB）。
_OWNER_ROLE = "zzqmtverify_owner"

# 本脚本会 `CREATE ROLE` / `DROP ROLE` 的**固定名**角色。
# ⚠️ **这是与 harness 那条「精确白名单、绝不按前缀盲删」完全同源的一条纪律，
#    只是作用在角色上**（codex 合并评审 R3-F2）。此前这里是无条件
#    `DROP ROLE IF EXISTS zzqmtverify_plain` —— 与 4a-2b/S1 R2-F1 那条**真栽过**的
#    「无条件 DROP DATABASE IF EXISTS zzqmtverify_unrelated」是同一个形态：
#    在共享集群上，光是启动本脚本就会把一个**不是本次造的**同名角色连同它的
#    登录/权限状态一起抹掉，而那时任何档位都还没跑、任何归属都还没证明。
#    **固定名不是归属证明。**
_OWNED_ROLES = (_PLAIN_ROLE, _OWNER_ROLE)


async def _apply_cluster_schema(conn) -> None:
    await conn.execute((_BACKEND / "sql/pilot_cluster_schema.sql").read_text(encoding="utf-8"))


async def _write_marker(conn) -> None:
    await conn.execute(
        "INSERT INTO public.pilot_cluster_marker (purpose) VALUES ($1)"
        " ON CONFLICT (purpose) DO NOTHING", MARKER_PURPOSE)


async def _peer_connect_factory(base_dsn: str):
    async def _connect_peer(name: str):
        return await asyncpg.connect(harness.db_dsn(base_dsn, name))
    return _connect_peer


async def _try_seed_lock(conn, seed: str) -> bool:
    """单参数形式的按 seed advisory lock —— 与 spec §4 的键派生逐字一致。"""
    return bool(await conn.fetchval(
        "SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || $1))", seed))


async def _timed_try_seed_lock(conn, seed: str) -> tuple[bool, float]:
    """取锁 + **耗时**。`time.monotonic` 不受系统时钟调整影响。"""
    t0 = time.monotonic()
    got = await _try_seed_lock(conn, seed)
    return got, time.monotonic() - t0


async def assert_roles_are_not_preexisting(conn) -> int | None:
    """前置清场：`_OWNED_ROLES` 里的角色**若已经存在就拒绝运行**（R3-F2）。

    ⚠️ 判据是「本次运行之前它就在」——那说明它**不是本脚本这次造的**，
       归属证明不成立，绝不删。与 `assert_extra_dbs_are_not_preexisting`
       （库那一侧）同语义、同逃生口：明确告诉操作者手工删哪一个再重跑。
    """
    rows = await conn.fetch(
        "SELECT rolname FROM pg_roles WHERE rolname = ANY($1::text[])",
        list(_OWNED_ROLES))
    if rows:
        names = sorted(r["rolname"] for r in rows)
        print(f"拒绝运行：这些角色在本次运行之前就已经存在：{names}——"
              f"本脚本会 CREATE/DROP 它们，而它们不是本次造的，归属证明不成立，绝不删。"
              f"确认无用后请手工执行 "
              f"{'; '.join(f'DROP ROLE {n}' for n in names)} 再重跑。", file=sys.stderr)
        return 9
    return None


async def main() -> int:
    base_dsn = os.environ.get("DSN")
    dsn2 = os.environ.get("DSN2")
    if not base_dsn:
        print("用法：DSN='postgresql://user:pw@host:port/postgres' "
              "DSN2='…' python backend/scripts/verify_pilot_concurrency.py",
              file=sys.stderr)
        return 2
    if not dsn2:
        # ⚠️ **绝不「跳过」**：一档静默没跑，与它通过了，在输出上完全一样。
        #    Ⓐb 需要第二台集群来钉「advisory lock 是**每集群**的」。
        print("拒绝运行：DSN2 未设置。Ⓐb 需要第二个 PostgreSQL 集群；"
              "缺它一律判失败，不接受跳过。", file=sys.stderr)
        return 2

    # 破坏性闸**必须先于对该 DSN 的任何 connect/DDL**。
    if harness.assert_destructive_dsn_allowed(base_dsn, "DSN") is None:
        return 3
    if harness.assert_destructive_dsn_allowed(dsn2, "DSN2") is None:
        return 3

    # 纯源码自检（零副作用），**必须排在破坏性清场之前**。
    for rc in (harness.assert_every_dsn_env_is_gated(__file__),
               harness.assert_scratch_objects_are_namespaced(_SCRATCH_OBJECTS),
               harness.assert_every_selfcheck_db_is_whitelisted(
                   __file__, _CONC_DBS, _PREFIX)):
        if rc is not None:
            return rc

    if (rc := await _acquire_run_lock(base_dsn)) is not None:
        return rc

    pre = await asyncpg.connect(base_dsn)
    try:
        await _apply_cluster_schema(pre)
        await _write_marker(pre)
        swept = await harness.sweep_leftover_databases(
            pre, prefix=_PREFIX, scenario_dbs=_CONC_DBS, name_re=_NAME_RE)
        if isinstance(swept, int):
            return swept
        await harness.purge_metadata_for(pre, _CONC_DBS)
        if swept:
            print(f"（前置清场：删掉上一次运行残留的 {swept}）")
        # ⚠️ 角色这一侧的同源守卫（R3-F2）：固定名不是归属证明。
        if (rc := await assert_roles_are_not_preexisting(pre)) is not None:
            return rc
    finally:
        await pre.close()

    failures: list[str] = []
    ran: set[str] = set()

    def scenario(tag: str) -> None:
        ran.add(tag)

    def check(ok: bool, label: str, detail: str = "") -> None:
        print(f"  {'PASS' if ok else 'FAIL'}  {label}"
              + ("" if ok else f"  —— {detail}" if detail else ""))
        if not ok:
            failures.append(label)

    connect_peer = await _peer_connect_factory(base_dsn)
    seed = "conc_a"

    # 两条**独立**连接 —— 模拟两个进程。advisory lock 是会话级的，
    # 同一条连接上重复取会成功（可重入），那样写整套档都是恒真的。
    conn_a = await asyncpg.connect(base_dsn)
    conn_b = await asyncpg.connect(base_dsn)
    try:
        # ── Ⓐ 第二把同 seed 的锁必须**立刻**失败返回，而不是在等 ──────────
        # ⚠️ **这一档验的是 PostgreSQL 的平台行为，不是本工具的行为**
        #    （codex 4a-2b/S1 R1-F1 说它「没驱动生产取锁路径」——**本模块根本没有
        #    取锁路径**：spec O1-F4 把取锁放在调用方，`qmt_pilot_db.py` 全文只
        #    「验锁是否被持有」、一次都不取；会取 pilot seed 锁的那个 wrapper 属于 4c，
        #    此刻还不存在。等它存在时，「两个真进程并发跑」那一档应当加在**它**的验收里。）
        #    本档的价值：spec §4 整套互斥设计的**地基假设**（try 版立刻返回、
        #    锁是每集群的、会话级锁随连接断开释放）必须在真 PG 上被验过，
        #    而不是想当然 —— 属于「设计地基靠基础设施行为 → 必须真环境验」那一族。
        #    **驱动生产判据的是 Ⓑ 系列**（`create_pilot_database` 无锁必拒 + 零副作用、
        #    `_SEED_LOCK_HELD_SQL` 不认两参数/共享锁冒充）。
        scenario("Ⓐ")
        print("Ⓐ A 持锁时 B 取同一把锁 → 立刻返回 false（PostgreSQL 平台行为）")
        check(await _try_seed_lock(conn_a, seed), "Ⓐ 前置：A 取到了 seed 锁")
        got_b, elapsed = await _timed_try_seed_lock(conn_b, seed)
        check(got_b is False, "Ⓐ B 取不到锁", "B 竟然也取到了（互斥失效）")
        check(elapsed < _IMMEDIATE_SECONDS,
              f"Ⓐ B **没有在等**（耗时 {elapsed*1000:.1f} ms < {_IMMEDIATE_SECONDS}s）",
              f"耗时 {elapsed:.3f}s —— 多半被换成了阻塞版 pg_advisory_lock")

        # ── Ⓐb advisory lock 是**每集群**的（用第二台集群钉死）──────────
        #    ⚠️ 这一条不是「顺手多测一点」：它说明 `--maintenance-dsn` 指到另一台集群时
        #       按 seed 的互斥**完全不存在**。spec 的模型是「一台 pilot 专用集群」，
        #       而这条限制必须是被验证过的已知事实，不是想当然。
        scenario("Ⓐb")
        print("Ⓐb 同一个 seed 在**另一台集群**上不构成互斥（锁是每集群的）")
        conn_other = await asyncpg.connect(dsn2)
        try:
            # ⚠️ **先证明 DSN2 真的是另一台集群**（codex 4a-2b/S1 R8-F2）：
            #    「取锁互不影响」根本不能当跨集群的证据 —— advisory lock 本来就是
            #    **每库**的（本机真 PG 实测：同集群连 /postgres 与 /template1，
            #    同一个 key 两边都取得到，`pg_locks` 两行 objid 相同 database 不同）。
            #    把 DSN2 指到同集群的另一个库，下面那条断言照样通过，
            #    于是本档对「锁不跨集群」这条**地基假设**给出假绿。
            #    `system_identifier` 是集群初始化时生成的身份，才是真判据。
            distinct = await harness.assert_distinct_clusters(conn_a, conn_other)
            check(distinct, "Ⓐb 前置：DSN2 必须是**另一台集群**（比 system_identifier）",
                  "DSN2 与 DSN 的 system_identifier 相同 —— 它只是同一集群上的另一个库，"
                  "这一档证明不了任何跨集群的事")
            # 负面对照：同集群、不同库的连接，同一把锁**照样取得到** ——
            # 这正是「取锁成功 ≠ 另一台集群」的现场证据，也让上面那条前置不是装饰。
            same_cluster_other_db = await asyncpg.connect(
                harness.db_dsn(base_dsn, "template1"))
            try:
                same_sysid = not await harness.assert_distinct_clusters(
                    conn_a, same_cluster_other_db)
                got_same, _ = await _timed_try_seed_lock(same_cluster_other_db, seed)
                check(same_sysid and got_same is True,
                      "Ⓐb− 负面对照：同集群的另一个库上同 seed 的锁也取得到"
                      "（故「取到了」不构成跨集群的证据）",
                      f"same_sysid={same_sysid} got={got_same}")
            finally:
                await same_cluster_other_db.close()

            got_other, elapsed_other = await _timed_try_seed_lock(conn_other, seed)
            check(got_other is True,
                  "Ⓐb 另一台集群上同 seed 的锁**照样取得到**（互斥不跨集群）",
                  "竟然取不到 —— 锁语义与假设不符")
            check(elapsed_other < _IMMEDIATE_SECONDS,
                  f"Ⓐb 且是立刻取到的（耗时 {elapsed_other*1000:.1f} ms）",
                  f"耗时 {elapsed_other:.3f}s")
        finally:
            await conn_other.close()

        # ── Ⓑ 没持锁的连接不许建库，且**一个副作用都不许留下** ───────────
        scenario("Ⓑ")
        print("Ⓑ B 没持锁就调 create_pilot_database → seed_lock_not_held 且零副作用")
        db_b = f"{_PREFIX}b1"
        seed_b = "conc_b1"
        # ⚠️ 库名必须是 seed 派生的，否则会先撞 `_assert_seed_db_name` 而不是锁闸 ——
        #    那样这一档验的就不是它宣称的东西了。
        check(db_b == f"kline_pilot_{seed_b}", "Ⓑ 前置：库名确实是该 seed 派生的",
              f"{db_b!r} vs kline_pilot_{seed_b}")
        await conn_b.execute("SELECT pg_advisory_unlock_all()")
        check(not await conn_b.fetchval(_SEED_LOCK_HELD_SQL, seed_b),
              "Ⓑ 前置：B 确实**没有**持有该 seed 的锁")
        try:
            await create_pilot_database(conn_b, connect=connect_peer, db_name=db_b,
                                        seed=seed_b, run_id="conc-b1", **_BUILD_ARGS)
            check(False, "Ⓑ 没持锁时建库必须拒", "竟然建出来了")
        except PilotDbBoundaryError as exc:
            check(exc.code == "seed_lock_not_held",
                  "Ⓑ 没持锁 → seed_lock_not_held", f"实得 {exc.code}：{exc}")
        except Exception as exc:
            check(False, "Ⓑ 没持锁 → seed_lock_not_held",
                  f"抛的不是 PilotDbBoundaryError：{type(exc).__name__}: {exc}")
        # 零副作用：新库、新 intent 行、新 registry 行，**三样都不许有**。
        # ⚠️ registry 这一条是 codex 4a-2b/S1 R5-F1（high）补的：原来只查了前两样，
        #    而 `pilot_database_registry` 是**归属凭据** —— 一个绕过锁闸、抢先写下
        #    registry 行的回归，会被这一档判成「零副作用」放行，接着被收尾清场抹掉痕迹，
        #    然后毒化此后所有的归属判定。断言必须在**清场之前**，否则查的是清场的效果。
        made = await conn_b.fetchval(
            "SELECT count(*) FROM pg_database WHERE datname = $1", db_b)
        check(made == 0, "Ⓑ 拒绝之后 pg_database 里没有那个库", f"竟然存在（count={made}）")
        rows = await conn_b.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db_b)
        check(rows == 0, "Ⓑ 拒绝之后维护库里没有新的 intent 行", f"竟然留下了 {rows} 行")
        regs = await conn_b.fetchval(
            "SELECT count(*) FROM public.pilot_database_registry WHERE dbname = $1", db_b)
        check(regs == 0, "Ⓑ 拒绝之后维护库里没有新的 registry 行（归属凭据）",
              f"竟然留下了 {regs} 行 —— 绕过锁闸写下的归属凭据会毒化此后所有归属判定")

        # ── Ⓑb 两参数形式的 advisory lock **不得冒充**按 seed 的锁 ─────────
        #    O4-R6-C1：`pg_advisory_lock(int,int)` 能拼出**同样的 classid/objid**，
        #    只有 `objsubid`（1 vs 2）区分得开。冒充成功 = 互斥形同虚设。
        scenario("Ⓑb")
        print("Ⓑb 两参数 advisory lock 拼出同样的 classid/objid → 验锁谓词必须不认")
        seed_bb = "conc_b2"
        await conn_b.execute("SELECT pg_advisory_unlock_all()")
        await conn_b.fetchval(
            "SELECT pg_try_advisory_lock("
            "  ((hashtext('kline_pilot_' || $1))::bigint >> 32)::int,"
            "  hashtext('kline_pilot_' || $1))", seed_bb)
        # ⚠️ **前置必须证明冒充真的撞上了同一个键**：撞不上的话下面那条
        #    「谓词说没持有」是恒真的，这一档整个是空的。
        collided = await conn_b.fetchval(
            "SELECT EXISTS (SELECT 1 FROM pg_locks l"
            "  WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid() AND l.granted"
            "    AND l.objsubid = 2"
            "    AND ((l.classid::bigint << 32) | l.objid::bigint)"
            "        = (hashtext('kline_pilot_' || $1))::bigint)", seed_bb)
        check(collided is True,
              "Ⓑb 前置：两参数锁确实拼出了**同一个 classid/objid**（objsubid=2）",
              "没撞上同一个键 —— 这一档就验不到冒充了")
        check(not await conn_b.fetchval(_SEED_LOCK_HELD_SQL, seed_bb),
              "Ⓑb 验锁谓词**不认**两参数形式的冒充锁")
        await conn_b.execute("SELECT pg_advisory_unlock_all()")

        # ── Ⓑd **共享**锁不得冒充按 seed 的排他锁 ─────────────────────────
        #    与 Ⓑb 是同一条生产注释点名的两种形态：`pg_advisory_lock_shared` 拼出的
        #    classid/objid/objsubid **全都一样**，只有 `mode` 区分得开。
        #    而共享锁**不提供互斥** —— 两个运行能同时持有它，这把锁的全部意义就没了。
        scenario("Ⓑd")
        print("Ⓑd 共享 advisory lock（objsubid 也是 1）→ 验锁谓词必须不认")
        seed_bd = "conc_b3"
        await conn_b.execute("SELECT pg_advisory_unlock_all()")
        await conn_b.fetchval(
            "SELECT pg_try_advisory_lock_shared(hashtext('kline_pilot_' || $1))", seed_bd)
        # 前置：证明它确实撞上了**同一个键、同一个 objsubid**，只差 mode。
        collided_shared = await conn_b.fetchval(
            "SELECT EXISTS (SELECT 1 FROM pg_locks l"
            "  WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid() AND l.granted"
            "    AND l.objsubid = 1 AND l.mode <> 'ExclusiveLock'"
            "    AND ((l.classid::bigint << 32) | l.objid::bigint)"
            "        = (hashtext('kline_pilot_' || $1))::bigint)", seed_bd)
        check(collided_shared is True,
              "Ⓑd 前置：共享锁撞上了**同一个键与 objsubid**，只有 mode 不同",
              "没撞上 —— 这一档就验不到冒充了")
        # 反向：证明共享锁**真的不互斥**（两条连接能同时持有）——
        # 这才是「不认它」的理由，不然只是个形状洁癖。
        conn_c = await asyncpg.connect(base_dsn)
        try:
            check(bool(await conn_c.fetchval(
                "SELECT pg_try_advisory_lock_shared(hashtext('kline_pilot_' || $1))",
                seed_bd)),
                "Ⓑd 反向：另一条连接**同时**也能拿到共享锁（它根本不互斥）")
        finally:
            await conn_c.close()
        check(not await conn_b.fetchval(_SEED_LOCK_HELD_SQL, seed_bd),
              "Ⓑd 验锁谓词**不认**共享锁")
        await conn_b.execute("SELECT pg_advisory_unlock_all()")

        # ── Ⓑc `hashtext` 为**负**的 seed 也必须验得对 ────────────────────
        #    键派生里有 `(classid::bigint << 32) | objid::bigint` 这样的位运算，
        #    而 `hashtext` 返回的是有符号 int4 —— 约一半的 seed 是负数。
        #    现有档位用的 seed 是否恰好都是正数，是**碰运气**，不是被验证过的性质。
        scenario("Ⓑc")
        print("Ⓑc hashtext 为负的 seed：取了锁之后验锁谓词必须判「持有」")
        seed_neg = None
        for i in range(200):
            cand = f"conc_neg_{i}"
            if await conn_b.fetchval(
                    "SELECT (hashtext('kline_pilot_' || $1))::bigint < 0", cand):
                seed_neg = cand
                break
        check(seed_neg is not None, "Ⓑc 前置：找到了一个 hashtext 为负的 seed",
              "200 个候选里一个负的都没有 —— 该假设本身要重查")
        if seed_neg is not None:
            h = await conn_b.fetchval(
                "SELECT (hashtext('kline_pilot_' || $1))::bigint", seed_neg)
            check(await _try_seed_lock(conn_b, seed_neg),
                  f"Ⓑc 前置：取到了 seed={seed_neg!r}（hashtext={h}）的锁")
            check(await conn_b.fetchval(_SEED_LOCK_HELD_SQL, seed_neg),
                  "Ⓑc 负 hashtext 下验锁谓词判「持有」（位运算没把负值算错）")
            await conn_b.execute("SELECT pg_advisory_unlock_all()")

        # ── Ⓒ 第一个进程退出后，第二个必须**立刻**取得锁 ──────────────────
        #    会话级 advisory lock 随连接断开自动释放 —— 这是「杀掉第一个」之后
        #    第二个能继续的全部依据。
        scenario("Ⓒ")
        print("Ⓒ 关掉 A 的连接之后，B 立刻取得同一把锁")
        check(await conn_b.fetchval(_SEED_LOCK_HELD_SQL, seed) is False,
              "Ⓒ 前置：此刻 B 并没有持有那把锁")
        await conn_a.close()
        # ⚠️ 服务端清理 A 的 PGPROC 是异步的：轮询到取得为止，
        #    但**总耗时**仍按「立刻」的阈值判。绝不 sleep 一个固定值当通过。
        t0 = time.monotonic()
        got_after = False
        while time.monotonic() - t0 < _IMMEDIATE_SECONDS:
            if await _try_seed_lock(conn_b, seed):
                got_after = True
                break
            await asyncio.sleep(0.01)
        waited = time.monotonic() - t0
        check(got_after,
              f"Ⓒ A 断开后 B 在 {_IMMEDIATE_SECONDS}s 内取得了锁（实耗 {waited*1000:.1f} ms）",
              f"等满 {waited:.3f}s 仍取不到 —— 会话级锁没有随连接释放")
    finally:
        for c in (conn_a, conn_b):
            try:
                await c.close()
            except Exception:
                pass

    # ── Ⓓ 零对象例外的 DROP 窗口：验空之后、DROP 之前不许有人连进来 ─────────
    #    （codex 4a-2 R10-F1，critical）这条来路**绕过** pilot_meta 归属与
    #    `--reset-foreign` 令牌，它的全部授权理由就是「这个库当时是空的」。
    #    验空是一次读，读完到 `DROP DATABASE` 之间实测有 0.7–2.2 ms：
    #    一个普通角色在这段里连进来建表再断开，PostgreSQL 就没有活会话可挡，
    #    于是本工具会删掉一个**已经不空**的库。
    #    收口手段（真 PG 实测选定）：`ALTER DATABASE … CONNECTION LIMIT 0`。
    #      · `ALLOW_CONNECTIONS false` 连**超级用户**也挡 → 验空根本做不了，不可用；
    #      · `CONNECTION LIMIT 0` 只挡非超级用户 → 本工具仍连得进去验空。
    scenario("Ⓓ")
    print("Ⓓ 验空之后、DROP 之前，普通角色必须连不进目标库")
    seed_d = "conc_d1"
    db_d = f"kline_pilot_{seed_d}"
    conn_m = await asyncpg.connect(base_dsn)
    try:
        await conn_m.execute(
            f"CREATE ROLE {quote_ident(_PLAIN_ROLE)} LOGIN PASSWORD '{_PLAIN_PASSWORD}'")
        await conn_m.execute("DROP DATABASE IF EXISTS " + quote_ident(db_d))
        await conn_m.execute("CREATE DATABASE " + quote_ident(db_d))
        # PG 15 起 PUBLIC 不再自带 schema public 的 CREATE 权限 ——
        # 不给这个授权的话，「窗口里建了表」这件事会因为权限而不发生，
        # 于是修复前后都「没建成」，这一档就恒绿了。
        seedconn = await asyncpg.connect(harness.db_dsn(base_dsn, db_d))
        try:
            await seedconn.execute(
                f"GRANT CREATE ON SCHEMA public TO {quote_ident(_PLAIN_ROLE)}")
        finally:
            await seedconn.close()
        await conn_m.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db_d)
        await conn_m.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db_d, seed_d, _BUILD_ARGS["created_at"], "conc-d1")
        if not await _try_seed_lock(conn_m, seed_d):
            check(False, "Ⓓ 前置：取到 seed 锁")

        # 把 DSN 的用户名/口令换成普通角色，再把库名换成目标库。
        plain_dsn = harness.db_dsn(
            re.sub(r"//[^:/@]+:[^@]*@", f"//{_PLAIN_ROLE}:{_PLAIN_PASSWORD}@", base_dsn),
            db_d)

        target_connects = {"n": 0}
        window = {"fired": False, "connected": None, "error": ""}

        class _CloseHooked:
            """代理目标库连接：在**它被关闭的那一刻**执行注入 ——
            那正是「验空已经读完、DROP 还没发出」的窗口。"""

            def __init__(self, inner):
                self._inner = inner

            def __getattr__(self, name):
                return getattr(self._inner, name)

            async def close(self, *a, **k):
                window["fired"] = True
                try:
                    intruder = await asyncpg.connect(plain_dsn)
                except Exception as exc:
                    window["connected"] = False
                    window["error"] = f"{type(exc).__name__}: {str(exc).splitlines()[0]}"
                else:
                    window["connected"] = True
                    try:
                        await intruder.execute(
                            "CREATE TABLE public.zzqmtverify_squatted (id int)")
                    finally:
                        await intruder.close()
                return await self._inner.close(*a, **k)

        async def _connect_with_window(name: str):
            inner = await connect_peer(name)
            if name == db_d:
                target_connects["n"] += 1
                # 第 3 次连目标库 = `reset_pilot_database` 封锁临界区持住的那条
                #（前两次在 try_empty_remnant_exception 的两次探测里）。
                if target_connects["n"] == 3:
                    return _CloseHooked(inner)
            return inner

        try:
            await reset_pilot_database(conn_m, connect=_connect_with_window,
                                       db_name=db_d, seed=seed_d,
                                       export_log_sha256=_BUILD_ARGS["export_log_sha256"],
                                       output_dir=_BUILD_ARGS["output_dir"],
                                       reset_foreign_token=None)
            dropped = True
        except Exception as exc:
            dropped = False
            window["error"] = window["error"] or f"{type(exc).__name__}: {exc}"
        # ⚠️ 先证明注入真的落在那个窗口里，否则下面那条是恒真的。
        check(window["fired"] and target_connects["n"] == 3,
              "Ⓓ 前置：注入确实落在「验空读完、DROP 之前」那一刻",
              f"连目标库 {target_connects['n']} 次，注入触发={window['fired']}")
        check(window["connected"] is False,
              "Ⓓ 窗口里普通角色**连不进**目标库（DROP 前已封住新连接）",
              f"竟然连进去并建了表 —— 于是一个已经不空的库会被 DROP 掉；"
              f"connected={window['connected']}")
        still_there = await conn_m.fetchval(
            "SELECT count(*) FROM pg_database WHERE datname = $1", db_d)
        check(dropped and not still_there,
              "Ⓓ 反向：封连接不影响本工具自己 —— 空残骸仍被正常 DROP 掉",
              f"dropped={dropped}；{window['error']}")
    finally:
        try:
            await conn_m.execute("SELECT pg_advisory_unlock_all()")
            await conn_m.execute("DROP DATABASE IF EXISTS " + quote_ident(db_d))
            await conn_m.execute(f"DROP ROLE IF EXISTS {quote_ident(_PLAIN_ROLE)}")
        finally:
            await conn_m.close()

    # ── Ⓓb **反向**：被拒之后连接限制必须还回去 ──────────────────────────
    #    Ⓓ 的修复在 DROP 前把库封成 `CONNECTION LIMIT 0`。若拒绝路径上忘了恢复，
    #    一个本工具**没有**销毁、也不归它管的库会对所有非超级用户**永久不可连** ——
    #    那比原来的窗口更糟。这一档专门钉恢复。
    #    ⚠️ 这里的入侵者用**超级用户**（超级用户不受 connlimit 限制），
    #       且注入在 probe **读之前** —— 于是复查判「不空」→ 拒绝 → 走恢复路径。
    scenario("Ⓓb")
    print("Ⓓb 封连接之后被拒 → 连接限制必须恢复（库不能被留成不可连）")
    seed_db = "conc_d2"
    db_db = f"kline_pilot_{seed_db}"
    conn_m2 = await asyncpg.connect(base_dsn)
    try:
        await conn_m2.execute(
            f"CREATE ROLE {quote_ident(_PLAIN_ROLE)} LOGIN PASSWORD '{_PLAIN_PASSWORD}'")
        await conn_m2.execute("DROP DATABASE IF EXISTS " + quote_ident(db_db))
        await conn_m2.execute("CREATE DATABASE " + quote_ident(db_db))
        # ⚠️ 给它一个**非默认**的连接上限（codex 4a-2 R11-F2）：
        #    此前这一档只断言「恢复成 −1」，于是「一律写死 −1」照样绿 ——
        #    而那会把一个本工具**明确选择不销毁**的库的连接策略永久改成「无限制」。
        #    判据必须是「还原成**原来那个值**」。
        await conn_m2.execute(
            f"ALTER DATABASE {quote_ident(db_db)} WITH CONNECTION LIMIT 7")
        await conn_m2.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db_db)
        await conn_m2.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db_db, seed_db, _BUILD_ARGS["created_at"], "conc-d2")
        if not await _try_seed_lock(conn_m2, seed_db):
            check(False, "Ⓓb 前置：取到 seed 锁")

        squat = {"n": 0, "did": False}

        async def _connect_squatting(name: str):
            if name == db_db:
                squat["n"] += 1
                if squat["n"] == 3:      # DROP 前那次复查，**读之前**把库弄脏
                    sup = await asyncpg.connect(harness.db_dsn(base_dsn, db_db))
                    try:
                        await sup.execute("CREATE TABLE public.zzqmtverify_late (id int)")
                        squat["did"] = True
                    finally:
                        await sup.close()
            return await connect_peer(name)

        refused = ""
        try:
            await reset_pilot_database(conn_m2, connect=_connect_squatting,
                                       db_name=db_db, seed=seed_db,
                                       export_log_sha256=_BUILD_ARGS["export_log_sha256"],
                                       output_dir=_BUILD_ARGS["output_dir"],
                                       reset_foreign_token=None)
            check(False, "Ⓓb 复查发现不空时必须拒绝 DROP", "竟然删掉了")
        except PilotDbBoundaryError as exc:
            refused = exc.code
            check(exc.code == "not_owned",
                  "Ⓓb 复查发现不空 → 拒绝 DROP（not_owned）", f"实得 {exc.code}：{exc}")
        check(squat["did"] and squat["n"] == 3,
              "Ⓓb 前置：注入确实落在 DROP 前那次复查之前",
              f"连目标库 {squat['n']} 次，注入={squat['did']}")
        limit = await conn_m2.fetchval(
            "SELECT datconnlimit FROM pg_database WHERE datname = $1", db_db)
        check(limit == 7,
              "Ⓓb 拒绝之后连接限制恢复成了**原来那个值 7**（不是写死的 −1）",
              f"实得 datconnlimit={limit}"
              f"（0 = 库被留成非超级用户不可连；−1 = 原有的连接策略被这次操作抹掉了）")
        # 端到端再证一次：普通角色现在真的连得进去。
        plain2 = harness.db_dsn(
            re.sub(r"//[^:/@]+:[^@]*@", f"//{_PLAIN_ROLE}:{_PLAIN_PASSWORD}@", base_dsn),
            db_db)
        try:
            back = await asyncpg.connect(plain2)
            await back.close()
            check(True, "Ⓓb 普通角色**又连得进**目标库了（端到端确认恢复生效）")
        except Exception as exc:
            check(False, "Ⓓb 普通角色**又连得进**目标库了（端到端确认恢复生效）",
                  f"仍连不进：{type(exc).__name__}: {str(exc).splitlines()[0]}"
                  f"；拒绝码={refused}")
    finally:
        try:
            await conn_m2.execute("SELECT pg_advisory_unlock_all()")
            await conn_m2.execute("DROP DATABASE IF EXISTS " + quote_ident(db_db))
            await conn_m2.execute(f"DROP ROLE IF EXISTS {quote_ident(_PLAIN_ROLE)}")
        finally:
            await conn_m2.close()

    # ── Ⓓc 封锁必须连**超级用户**的新连接一起挡住（codex 合并评审 F1）──────────
    #    Ⓓ 用的是普通角色，而 `CONNECTION LIMIT 0` **本来就只挡非超级用户** ——
    #    也就是说 Ⓓ 对「超级用户能不能挤进窗口」这一条**零判别力**。
    #    而本工具在 pilot 部署里**就是**超级用户跑的（Ⓔ 证明非超级用户连集群闸都过不去），
    #    所以「另一个用同一套凭据的并发任务」才是最现实的威胁面：
    #    它能在最后一次复验之后、DROP 之前连进来建表再断开，
    #    于是一个**已经不空**的库照样被删掉 —— 正是 R10-F1 那条 critical 的形态。
    #    收口手段：封锁语句同时设 `ALLOW_CONNECTIONS false`（真 PG 15 实测：
    #    已建立的会话不受影响、新的超级用户连接被挡、DROP 仍然成功）。
    scenario("Ⓓc")
    print("Ⓓc 验空之后、DROP 之前，**超级用户**同样必须连不进目标库")
    seed_dc = "conc_d3"
    db_dc = f"kline_pilot_{seed_dc}"
    conn_m3 = await asyncpg.connect(base_dsn)
    try:
        await conn_m3.execute("DROP DATABASE IF EXISTS " + quote_ident(db_dc))
        await conn_m3.execute("CREATE DATABASE " + quote_ident(db_dc))
        await conn_m3.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db_dc)
        await conn_m3.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db_dc, seed_dc, _BUILD_ARGS["created_at"], "conc-d3")
        if not await _try_seed_lock(conn_m3, seed_dc):
            check(False, "Ⓓc 前置：取到 seed 锁")

        # ⚠️ 入侵者用的是**超级用户**的 DSN（与本工具同一套凭据）——
        #    这正是 Ⓓ 用普通角色测不到的那一向。
        super_dsn = harness.db_dsn(base_dsn, db_dc)
        sup_connects = {"n": 0}
        win = {"fired": False, "connected": None, "error": ""}

        class _CloseHookedSuper:
            """在**持住的那条目标库连接被关闭的那一刻**注入 ——
            即「最后一次复验已经做完、DROP 还没发出」的窗口。"""

            def __init__(self, inner):
                self._inner = inner

            def __getattr__(self, name):
                return getattr(self._inner, name)

            async def close(self, *a, **k):
                win["fired"] = True
                try:
                    intruder = await asyncpg.connect(super_dsn)
                except Exception as exc:
                    win["connected"] = False
                    win["error"] = f"{type(exc).__name__}: {str(exc).splitlines()[0]}"
                else:
                    win["connected"] = True
                    try:
                        await intruder.execute(
                            "CREATE TABLE public.zzqmtverify_super_squatted (id int)")
                    finally:
                        await intruder.close()
                return await self._inner.close(*a, **k)

        async def _connect_with_super_window(name: str):
            inner = await connect_peer(name)
            if name == db_dc:
                sup_connects["n"] += 1
                # 第 3 次连目标库 = `reset_pilot_database` 封锁临界区持住的那条
                #（前两次在 try_empty_remnant_exception 的两次探测里）。
                if sup_connects["n"] == 3:
                    return _CloseHookedSuper(inner)
            return inner

        try:
            await reset_pilot_database(conn_m3, connect=_connect_with_super_window,
                                       db_name=db_dc, seed=seed_dc,
                                       export_log_sha256=_BUILD_ARGS["export_log_sha256"],
                                       output_dir=_BUILD_ARGS["output_dir"],
                                       reset_foreign_token=None)
            dropped_dc = True
        except Exception as exc:
            dropped_dc = False
            win["error"] = win["error"] or f"{type(exc).__name__}: {exc}"
        # 先证明注入真的落在那个窗口里，否则下面那条是恒真的。
        check(win["fired"] and sup_connects["n"] == 3,
              "Ⓓc 前置：注入确实落在「最后一次复验做完、DROP 之前」那一刻",
              f"连目标库 {sup_connects['n']} 次，注入触发={win['fired']}")
        check(win["connected"] is False,
              "Ⓓc 窗口里**超级用户**也连不进目标库（封锁带 ALLOW_CONNECTIONS false）",
              f"竟然连进去并建了表 —— 于是一个已经不空的库会被 DROP 掉；"
              f"connected={win['connected']}（CONNECTION LIMIT 0 挡不住超级用户）")
        still_dc = await conn_m3.fetchval(
            "SELECT count(*) FROM pg_database WHERE datname = $1", db_dc)
        check(dropped_dc and not still_dc,
              "Ⓓc 反向：封超级用户不影响本工具自己 —— 空残骸仍被正常 DROP 掉",
              f"dropped={dropped_dc}；{win['error']}")
    finally:
        try:
            await conn_m3.execute("SELECT pg_advisory_unlock_all()")
            await conn_m3.execute("DROP DATABASE IF EXISTS " + quote_ident(db_dc))
        finally:
            await conn_m3.close()

    # ── Ⓔ **非超级用户**维护角色：在任何破坏性动作之前就被挡住 ────────────
    #    起因是 codex 4a-2 R12-F1 担心「非超级用户部署下窗口仍在」。
    #    本档实测出一个**比那个担心更根本**的事实：
    #    【绝对空】判据 `_user_objects` 要遍历**所有**带 oid 列的 pg_catalog 表，
    #    其中 `pg_user_mapping` 非超级用户读不了 → `InsufficientPrivilegeError`。
    #    也就是说**整个模块早就隐含要求超级用户维护角色**（不只是 DROP 前的封锁），
    #    非超级用户连集群闸都过不去，根本走不到 DROP ——
    #    R12-F1 设想的「仍然删得掉库的非超级用户部署」在现实里到不了那一步。
    #    ⚠️ 这条前提此前是**偶然**成立的（没人写下来、也没人验过）。这一档把它钉成
    #       可验证的事实，并证明它是 **fail-closed** 的：库没被动、配置也没被改一半。
    #    ⚠️ 不要「顺手让 `_user_objects` 跳过读不了的目录」—— 那是 fail-open：
    #       模块明写「查不出目录清单 → 抛异常，绝不返回『空』」。
    scenario("Ⓔ")
    print("Ⓔ 非超级用户维护角色：破坏性动作之前就被挡住，且什么都没留下")
    seed_e = "conc_e1"
    db_e = f"kline_pilot_{seed_e}"
    owner = _OWNER_ROLE
    sup = await asyncpg.connect(base_dsn)
    try:
        await sup.execute("DROP DATABASE IF EXISTS " + quote_ident(db_e))
        await sup.execute(
            f"CREATE ROLE {quote_ident(owner)} LOGIN CREATEDB PASSWORD '{_PLAIN_PASSWORD}'")
        await sup.execute("CREATE DATABASE " + quote_ident(db_e)
                          + " OWNER " + quote_ident(owner))
        # 维护库里的三张表要让这个角色读写（真实部署里也要这么授）
        for tbl in ("pilot_cluster_marker", "pilot_create_intent",
                    "pilot_database_registry"):
            await sup.execute(
                f"GRANT SELECT, INSERT, UPDATE, DELETE ON public.{tbl} "
                f"TO {quote_ident(owner)}")
        await sup.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db_e)
        await sup.execute(
            "INSERT INTO public.pilot_create_intent"
            " (dbname, seed, created_at, run_id, create_confirmed, db_oid)"
            " SELECT $1, $2, $3, $4, true, d.oid FROM pg_database d"
            "  WHERE d.datname::text = $1",
            db_e, seed_e, _BUILD_ARGS["created_at"], "conc-e1")

        owner_dsn = re.sub(r"//[^:/@]+:[^@]*@",
                           f"//{owner}:{_PLAIN_PASSWORD}@", base_dsn)
        owner_conn = await asyncpg.connect(owner_dsn)
        try:
            check(not await owner_conn.fetchval(
                "SELECT current_setting('is_superuser') = 'on'"),
                "Ⓔ 前置：这个维护角色**不是**超级用户")
            if not await _try_seed_lock(owner_conn, seed_e):
                check(False, "Ⓔ 前置：取到 seed 锁")

            async def _owner_connect(name: str):
                return await asyncpg.connect(harness.db_dsn(owner_dsn, name))

            try:
                await reset_pilot_database(
                    owner_conn, connect=_owner_connect, db_name=db_e, seed=seed_e,
                    export_log_sha256=_BUILD_ARGS["export_log_sha256"],
                    output_dir=_BUILD_ARGS["output_dir"], reset_foreign_token=None)
                refused_e, err_e = False, ""
            except Exception as exc:
                refused_e, err_e = True, f"{type(exc).__name__}: {exc}"
            check(refused_e,
                  "Ⓔ 非超级用户维护角色被挡住（不是悄悄降级继续跑）",
                  "竟然跑完了 —— 那说明【绝对空】的目录遍历没有真的遍历全")
            check("permission denied" in err_e,
                  "Ⓔ 挡住它的是**读不了系统目录**（模块隐含要求超级用户维护角色）",
                  f"实得 {err_e}")
            still = await sup.fetchval(
                "SELECT count(*) FROM pg_database WHERE datname = $1", db_e)
            check(still == 1, "Ⓔ fail-closed：目标库**没有**被删",
                  f"库不见了（count={still}）—— 权限不足却还是执行了破坏性动作")
            limit_e = await sup.fetchval(
                "SELECT datconnlimit FROM pg_database WHERE datname = $1", db_e)
            check(limit_e == -1,
                  "Ⓔ 也没有把目标库留在半封锁状态（datconnlimit 仍是 −1）",
                  f"实得 datconnlimit={limit_e} —— 配置被改了一半就抛了")
        finally:
            await owner_conn.close()
    finally:
        try:
            await sup.execute("DROP DATABASE IF EXISTS " + quote_ident(db_e))
            await sup.execute(
                "DELETE FROM public.pilot_create_intent WHERE dbname = $1", db_e)
            for tbl in ("pilot_cluster_marker", "pilot_create_intent",
                        "pilot_database_registry"):
                await sup.execute(f"REVOKE ALL ON public.{tbl} FROM {quote_ident(owner)}")
            await sup.execute(f"DROP ROLE IF EXISTS {quote_ident(owner)}")
        finally:
            await sup.close()


    # ── 收尾 ────────────────────────────────────────────────────────────
    post = await asyncpg.connect(base_dsn)
    try:
        for name in _CONC_DBS:
            await post.execute("DROP DATABASE IF EXISTS " + quote_ident(name))
        await harness.purge_metadata_for(post, _CONC_DBS)
    finally:
        await post.close()

    missing = [t for t in _EXPECTED_SCENARIOS if t not in ran]
    if missing:
        print(f"\n❌ 这些档位**没有跑到**：{missing} —— "
              f"「静默没跑」与「通过了」在输出上完全一样，故判失败", file=sys.stderr)
        return 1
    if failures:
        print(f"\n❌ {len(failures)} 条断言不成立：{failures}", file=sys.stderr)
        return 1
    print(f"\n✅ {len(_EXPECTED_SCENARIOS)} 档断言全部成立（真 PostgreSQL）")
    # ⚠️ 全绿**不等于** spec §6.2 第三组被满足 —— 那一条要驱动真正取锁的入口
    #    （4c 的 wrapper，尚不存在）。只写在 docstring 里跑的人看不见，故打到输出上。
    print("⚠️ 注意：本脚本不覆盖 spec §6.2 第三组的「两个真进程并发」——"
          "取锁方是 4c 的 wrapper（尚不存在），那一档须加进 4c 的验收。")
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
    sys.exit(asyncio.run(_entry()))
