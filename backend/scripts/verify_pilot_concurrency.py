#!/usr/bin/env python3
"""pilot 建库/销毁的**并发互斥**真-PostgreSQL 验收（spec §6.2 第三组）。

spec §6.2 逐字：「同 `--seed`、不同 `--maintenance-dsn` 的两个进程 —— 断言第二个在
`pg_try_advisory_lock` 处**立刻**失败返回（**须设短超时并断言它没有在等**），
且未执行任何 `DROP`/`CREATE`；杀掉第一个后第二个能立即取得锁」。

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
    DSN="postgresql://…:55444/postgres" DSN2="postgresql://…:55445/postgres" \
        ./.venv/bin/python backend/scripts/verify_pilot_concurrency.py
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
                          create_pilot_database, quote_ident, sha256_of_sql)
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
_CONC_DBS = ("kline_pilot_conc_b1",)

# 本脚本不在维护库里造任何临时对象。
_SCRATCH_OBJECTS: tuple = ()

# 「立刻」的判据。真机上 `pg_try_advisory_lock` 是纯内存操作，量级是微秒；
# 1 秒的阈值足够宽到不会被负载抖动打红，又足够窄到能把「换成了阻塞版」抓出来。
_IMMEDIATE_SECONDS = 1.0

# 验收闸的**完整性清单**：收尾核对每一档都真的跑过。
# ⚠️ 少一档即失败 —— 「静默没跑」与「通过了」在输出上完全一样。
_EXPECTED_SCENARIOS = ("Ⓐ", "Ⓐb", "Ⓑ", "Ⓑb", "Ⓑd", "Ⓑc", "Ⓒ")


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

    pre = await asyncpg.connect(base_dsn)
    try:
        await _apply_cluster_schema(pre)
        await _write_marker(pre)
        swept = await harness.sweep_leftover_databases(
            pre, prefix=_PREFIX, scenario_dbs=_CONC_DBS, name_re=_NAME_RE)
        if isinstance(swept, int):
            return swept
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
            got_other, elapsed_other = await _timed_try_seed_lock(conn_other, seed)
            check(got_other is True,
                  "Ⓐb 另一台集群上同 seed 的锁**照样取得到**（互斥不跨集群）",
                  "竟然取不到 —— 要么 DSN2 与 DSN 是同一台集群，要么锁语义与假设不符")
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
        # 零副作用：既没有新库，也没有新 intent 行。
        made = await conn_b.fetchval(
            "SELECT count(*) FROM pg_database WHERE datname = $1", db_b)
        check(made == 0, "Ⓑ 拒绝之后 pg_database 里没有那个库", f"竟然存在（count={made}）")
        rows = await conn_b.fetchval(
            "SELECT count(*) FROM public.pilot_create_intent WHERE dbname = $1", db_b)
        check(rows == 0, "Ⓑ 拒绝之后维护库里没有新的 intent 行", f"竟然留下了 {rows} 行")

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

    # ── 收尾 ────────────────────────────────────────────────────────────
    post = await asyncpg.connect(base_dsn)
    try:
        for name in _CONC_DBS:
            await post.execute("DROP DATABASE IF EXISTS " + quote_ident(name))
        await post.execute(
            "DELETE FROM public.pilot_create_intent WHERE dbname LIKE $1", f"{_PREFIX}%")
        await post.execute(
            "DELETE FROM public.pilot_database_registry WHERE dbname LIKE $1", f"{_PREFIX}%")
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
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
