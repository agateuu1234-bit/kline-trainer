#!/usr/bin/env python3
"""验证 B2 快照读依赖的两件 PostgreSQL 地基语义：**REPEATABLE READ 只读事务快照**
与**按股 advisory lock 隔离**（spec `2026-07-23-qmt-plan3-b1-ingest-coverage-design.md`
§5.3，Plan 3 Task5）。

背景：`generate_one_training_set` 把 coverage + 六周期读包进
`conn.transaction(isolation="repeatable_read", readonly=True)`，并在其外层用
`pg_try_advisory_lock(IMPORT_GEN_LOCK_KEY, stock_lock_key(code))` 与 B1 导入互斥
（见 `backend/generate_training_sets.py`）。本仓的假 conn 单测**证明不了**这两件事——
假件建模的是「我们确实按预期参数/顺序调用了这些」，不是 PostgreSQL 真的按 RR 快照
隔离并发写、advisory lock 真的跨连接互斥（`feedback_verify_foundational_infra_assumption_
real_not_fake` 的坑）。故用真 PostgreSQL 手写 SQL 扮演「B1 写、B2 读」跑一遍。

本脚本验 6 条断言（spec §5.3 原文编号）：
  1. RR 只读事务内第一次读之后，另一连接 INSERT klines + UPDATE stock_coverage 并
     COMMIT；同事务内第二次读仍看到旧值（klines 与 stock_coverage 都验）。
  2. 同一时刻，事务外的第三个连接看得见新值——证明写方真的提交了（防「写方其实
     没写成，快照测试空转全绿」）。
  3. `SHOW transaction_isolation` 在该事务内 == repeatable read；事务内尝试写被
     PostgreSQL 拒绝（证明 readonly=True 真生效）。
  4. 导入事务未提交时，外部连接既看不到 coverage 行也看不到 klines 行；提交后
     同时看到两者（P3-D4 原子性）。
  5. 按股锁隔离：连接 A 持 `pg_advisory_lock(K, s1)` → 连接 B 对同一 s1 的
     `pg_try_advisory_lock` 返回 False、对不同股 s2 返回 True；A 释放后 B 能拿到 s1。
  6. B1 事务级锁足够 + 非阻塞不挂起：A 持 session 锁期间，B 的
     `pg_try_advisory_xact_lock` 立即返回 False（不阻塞）；A 释放后 B 的 try 成功，
     且随 B 自己的事务提交自动释放（不多占）；反向对照——B 若改用阻塞式
     `pg_advisory_xact_lock`，A 持锁期间该调用会真的挂起（脚本用短超时探测）。

不进 pytest：CI 禁 skip、且需要真 Docker PostgreSQL，pytest 套件里放不了会挂起/
不可用的依赖。一次性脚本，用法同 `verify_advisory_lock_reentrancy.py`：

  docker run --rm -d -p 5433:5432 -e POSTGRES_PASSWORD=postgres postgres:15.12
  DSN='postgresql://postgres:postgres@localhost:5433/postgres' \
    .venv/bin/python backend/scripts/verify_repeatable_read_snapshot.py

退出码 0 = 六条断言全部成立。非 0 = 有断言不成立，B2 快照读/按股锁的地基假设有
问题，必须停下重新评估——不要因为假 conn 单测绿就当它成立。
"""
import asyncio
import os
import sys
from datetime import date

# 与 generate_training_sets.IMPORT_GEN_LOCK_KEY（0x42345CF0）刻意不同的临时 key，
# 避免与任何真在跑的 B1/B2 抢锁；语义验证与 key 值本身无关。两个子 key 模拟两只
# 不同股票（stock_lock_key 的产物是 int4 范围内的 crc32，这里用普通整数即可）。
TEST_KEY = 0x42345CF1
S1 = 101
S2 = 202

# 测试用 stock_code，独立前缀，方便识别/清理，不与任何真实数据碰撞。
TEST_STOCK_RR = "VRFYRR01"       # 断言 1/2/3 用
TEST_STOCK_ATOMIC = "VRFYATOM"   # 断言 4 用


async def _setup_schema_and_baseline(conn) -> None:
    """建表（若不存在，取 backend/sql/schema.sql 的最小切片）+ 清理残留 + 灌基线数据。
    与真实 schema.sql 兼容：若目标库已有完整 schema，这里的 INSERT 只用到其中的
    非空必填列，CHECK 约束（价格有限为正/high>=low 等）也满足，故两种情况都能跑。
    """
    await conn.execute("""
        CREATE TABLE IF NOT EXISTS stocks (
            code VARCHAR(10) PRIMARY KEY,
            name VARCHAR(50) NOT NULL
        )
    """)
    await conn.execute("""
        CREATE TABLE IF NOT EXISTS klines (
            id BIGSERIAL PRIMARY KEY,
            stock_code VARCHAR(10) NOT NULL REFERENCES stocks(code),
            period VARCHAR(10) NOT NULL,
            datetime BIGINT NOT NULL,
            open DOUBLE PRECISION NOT NULL,
            high DOUBLE PRECISION NOT NULL,
            low DOUBLE PRECISION NOT NULL,
            close DOUBLE PRECISION NOT NULL,
            volume BIGINT NOT NULL,
            UNIQUE(stock_code, period, datetime)
        )
    """)
    await conn.execute("""
        CREATE TABLE IF NOT EXISTS stock_coverage (
            stock_code          TEXT PRIMARY KEY,
            dense_1m_start_date DATE NOT NULL,
            dense_1m_end_date   DATE NOT NULL,
            dropped_1m_dates    JSONB NOT NULL DEFAULT '[]'::jsonb,
            dense_day_count     INTEGER NOT NULL
        )
    """)

    # 清理上一次可能失败退出留下的残留行（幂等重跑）。
    await conn.execute(
        "DELETE FROM klines WHERE stock_code = ANY($1)",
        [TEST_STOCK_RR, TEST_STOCK_ATOMIC])
    await conn.execute(
        "DELETE FROM stock_coverage WHERE stock_code = ANY($1)",
        [TEST_STOCK_RR, TEST_STOCK_ATOMIC])
    await conn.execute(
        "DELETE FROM stocks WHERE code = ANY($1)",
        [TEST_STOCK_RR, TEST_STOCK_ATOMIC])

    await conn.execute(
        "INSERT INTO stocks (code, name) VALUES ($1, 'RR快照验证'), ($2, '原子性验证')",
        TEST_STOCK_RR, TEST_STOCK_ATOMIC)

    # RR 基线：coverage 一行（dense_day_count=100）+ klines 恰好一行。
    await conn.execute(
        "INSERT INTO stock_coverage "
        "(stock_code, dense_1m_start_date, dense_1m_end_date, dense_day_count) "
        "VALUES ($1, $2, $3, 100)",
        TEST_STOCK_RR, date(2024, 1, 1), date(2024, 6, 1))
    await conn.execute(
        "INSERT INTO klines (stock_code, period, datetime, open, high, low, close, volume) "
        "VALUES ($1, '1m', 1000, 10, 10, 10, 10, 100)",
        TEST_STOCK_RR)
    # TEST_STOCK_ATOMIC 刻意不预插 coverage/klines——断言 4 验的正是「从无到有」
    # 这一整个导入事务的可见性。


async def _cleanup(conn) -> None:
    await conn.execute(
        "DELETE FROM klines WHERE stock_code = ANY($1)",
        [TEST_STOCK_RR, TEST_STOCK_ATOMIC])
    await conn.execute(
        "DELETE FROM stock_coverage WHERE stock_code = ANY($1)",
        [TEST_STOCK_RR, TEST_STOCK_ATOMIC])
    await conn.execute(
        "DELETE FROM stocks WHERE code = ANY($1)",
        [TEST_STOCK_RR, TEST_STOCK_ATOMIC])


async def main() -> int:
    dsn = os.environ.get("DSN")
    if not dsn:
        print("ERROR: 需要环境变量 DSN，例如 "
              "DSN='postgresql://postgres:postgres@localhost:5432/postgres'",
              file=sys.stderr)
        return 2

    try:
        import asyncpg
    except ImportError:
        print("ERROR: .venv 未装 asyncpg。先跑："
              "  .venv/bin/python -m pip install asyncpg", file=sys.stderr)
        return 3

    failures: list[str] = []

    setup_conn = await asyncpg.connect(dsn)
    try:
        await _setup_schema_and_baseline(setup_conn)
    finally:
        await setup_conn.close()

    # conn_a: RR 只读事务连接（断言1-3），随后复用为按股锁的「连接 A」（断言5/6）。
    # conn_b: 外部写方（断言1/2 的写者，断言4 的「导入事务」连接）。
    # conn_c: 事务外的第三方读者（断言2/4），随后复用为按股锁的「连接 B」（断言5/6）。
    conn_a = await asyncpg.connect(dsn)
    conn_b = await asyncpg.connect(dsn)
    conn_c = await asyncpg.connect(dsn)

    try:
        # ==================================================================
        # 断言 1+2+3：RR 只读事务快照 + 事务外可见 + readonly 真生效
        # ==================================================================
        tr_rr = conn_a.transaction(isolation="repeatable_read", readonly=True)
        await tr_rr.start()

        cov_read1 = await conn_a.fetchval(
            "SELECT dense_day_count FROM stock_coverage WHERE stock_code = $1",
            TEST_STOCK_RR)
        kl_count_read1 = await conn_a.fetchval(
            "SELECT COUNT(*) FROM klines WHERE stock_code = $1", TEST_STOCK_RR)

        # 外部连接（conn_b）INSERT klines + UPDATE stock_coverage，并 COMMIT。
        async with conn_b.transaction():
            await conn_b.execute(
                "UPDATE stock_coverage SET dense_day_count = 999 WHERE stock_code = $1",
                TEST_STOCK_RR)
            await conn_b.execute(
                "INSERT INTO klines "
                "(stock_code, period, datetime, open, high, low, close, volume) "
                "VALUES ($1, '1m', 2000, 20, 20, 20, 20, 200)",
                TEST_STOCK_RR)

        # RR 事务内第二次读——应仍看到旧值（快照语义）。
        cov_read2 = await conn_a.fetchval(
            "SELECT dense_day_count FROM stock_coverage WHERE stock_code = $1",
            TEST_STOCK_RR)
        kl_count_read2 = await conn_a.fetchval(
            "SELECT COUNT(*) FROM klines WHERE stock_code = $1", TEST_STOCK_RR)

        if cov_read1 == 100 and cov_read2 == 100:
            print(f"OK  [1] RR 事务内 stock_coverage 二读仍见旧值（{cov_read1} == {cov_read2} == 100）")
        else:
            failures.append(
                f"[1-coverage] RR 快照被打破：read1={cov_read1!r} read2={cov_read2!r}，期望均为 100")
        if kl_count_read1 == 1 and kl_count_read2 == 1:
            print(f"OK  [1] RR 事务内 klines 二读仍见旧值（行数 {kl_count_read1} == {kl_count_read2} == 1）")
        else:
            failures.append(
                f"[1-klines] RR 快照被打破：count1={kl_count_read1!r} count2={kl_count_read2!r}，期望均为 1")

        # 断言 2：事务外的第三方连接（conn_c，无事务）应看到新值——证明写方真的提交了。
        cov_outside = await conn_c.fetchval(
            "SELECT dense_day_count FROM stock_coverage WHERE stock_code = $1",
            TEST_STOCK_RR)
        kl_count_outside = await conn_c.fetchval(
            "SELECT COUNT(*) FROM klines WHERE stock_code = $1", TEST_STOCK_RR)
        if cov_outside == 999 and kl_count_outside == 2:
            print(f"OK  [2] 事务外第三方连接看见新值（coverage=999, klines行数=2）——写方确已提交")
        else:
            failures.append(
                f"[2] 事务外连接应看见新值 (999, 2)，实得 (coverage={cov_outside!r}, "
                f"klines行数={kl_count_outside!r}) → 疑似写方根本没写成，断言 1 空转全绿")

        # 断言 3a：SHOW transaction_isolation == repeatable read
        iso = await conn_a.fetchval("SHOW transaction_isolation")
        if iso == "repeatable read":
            print(f"OK  [3a] SHOW transaction_isolation == 'repeatable read'")
        else:
            failures.append(f"[3a] transaction_isolation 应为 'repeatable read'，实得 {iso!r}")

        # 断言 3b：事务内尝试写 → 应被 PostgreSQL 拒绝（readonly=True 真生效）。
        # 放在最后一步做——PG 事务内任何错误都会把事务标记为 aborted，此后不能再读。
        write_rejected = False
        try:
            await conn_a.execute(
                "UPDATE stock_coverage SET dense_day_count = dense_day_count "
                "WHERE stock_code = $1",
                TEST_STOCK_RR)
        except asyncpg.PostgresError as e:
            write_rejected = True
            sqlstate = getattr(e, "sqlstate", None)
            if sqlstate == "25006":
                print(f"OK  [3b] RR 只读事务内写被 PG 拒绝（sqlstate=25006 read_only_sql_transaction）")
            else:
                failures.append(
                    f"[3b] 写被拒绝但 sqlstate 非预期：{sqlstate!r}（{e}）——仍算「被拒绝」但值得核实")
        if not write_rejected:
            failures.append("[3b] RR 只读事务内的写居然成功了——readonly=True 没有真生效")

        # 事务已因上面的失败写入被标记为 aborted，唯一安全收尾是 rollback
        # （反正整个事务本来就是只读的，没有任何数据需要提交）。
        await tr_rr.rollback()

        # ==================================================================
        # 断言 4：B1 导入事务原子性——未提交外部两者都看不到，提交后两者都看到
        # ==================================================================
        conn_import = await asyncpg.connect(dsn)
        try:
            tr_import = conn_import.transaction()
            await tr_import.start()
            await conn_import.execute(
                "INSERT INTO stock_coverage "
                "(stock_code, dense_1m_start_date, dense_1m_end_date, dense_day_count) "
                "VALUES ($1, $2, $3, 2)",
                TEST_STOCK_ATOMIC, date(2024, 1, 1), date(2024, 1, 2))
            await conn_import.execute(
                "INSERT INTO klines "
                "(stock_code, period, datetime, open, high, low, close, volume) "
                "VALUES ($1, '1m', 3000, 1, 1, 1, 1, 10)",
                TEST_STOCK_ATOMIC)

            cov_uncommitted = await conn_c.fetchval(
                "SELECT COUNT(*) FROM stock_coverage WHERE stock_code = $1",
                TEST_STOCK_ATOMIC)
            kl_uncommitted = await conn_c.fetchval(
                "SELECT COUNT(*) FROM klines WHERE stock_code = $1", TEST_STOCK_ATOMIC)
            if cov_uncommitted == 0 and kl_uncommitted == 0:
                print("OK  [4a] 导入事务未提交时，外部连接既看不到 coverage 行也看不到 klines 行")
            else:
                failures.append(
                    f"[4a] 导入事务未提交，外部却看到了 (coverage行数={cov_uncommitted!r}, "
                    f"klines行数={kl_uncommitted!r})，期望均为 0")

            await tr_import.commit()

            cov_committed = await conn_c.fetchval(
                "SELECT COUNT(*) FROM stock_coverage WHERE stock_code = $1",
                TEST_STOCK_ATOMIC)
            kl_committed = await conn_c.fetchval(
                "SELECT COUNT(*) FROM klines WHERE stock_code = $1", TEST_STOCK_ATOMIC)
            if cov_committed == 1 and kl_committed == 1:
                print("OK  [4b] 提交后，外部连接同时看到 coverage 行与 klines 行（原子性成立）")
            else:
                failures.append(
                    f"[4b] 提交后外部应同时看到两者，实得 (coverage行数={cov_committed!r}, "
                    f"klines行数={kl_committed!r})，期望均为 1")
        finally:
            await conn_import.close()

        # ==================================================================
        # 断言 5：按股锁隔离——同股互斥、异股不互斥
        # ==================================================================
        await conn_a.execute("SELECT pg_advisory_lock($1, $2)", TEST_KEY, S1)

        b_same_stock = await conn_b.fetchval(
            "SELECT pg_try_advisory_lock($1, $2)", TEST_KEY, S1)
        if b_same_stock is False:
            print(f"OK  [5a] A 持 s1 锁时，B 对同一 s1 的 pg_try_advisory_lock 返回 False（同股互斥）")
        else:
            failures.append(f"[5a] A 持 s1 锁时，B 对同一 s1 应拿不到，实得 {b_same_stock!r}")

        b_diff_stock = await conn_b.fetchval(
            "SELECT pg_try_advisory_lock($1, $2)", TEST_KEY, S2)
        if b_diff_stock is True:
            print(f"OK  [5b] A 持 s1 锁时，B 对不同股 s2 的 pg_try_advisory_lock 返回 True（异股不互斥）")
            await conn_b.execute("SELECT pg_advisory_unlock($1, $2)", TEST_KEY, S2)
        else:
            failures.append(
                f"[5b] A 持 s1 锁不应挡住 B 对 s2 的锁，实得 {b_diff_stock!r} "
                "→ 按股隔离退化成了全局互斥")

        await conn_a.execute("SELECT pg_advisory_unlock($1, $2)", TEST_KEY, S1)
        b_after_release = await conn_b.fetchval(
            "SELECT pg_try_advisory_lock($1, $2)", TEST_KEY, S1)
        if b_after_release is True:
            print("OK  [5c] A 释放 s1 后，B 成功获取 s1")
            await conn_b.execute("SELECT pg_advisory_unlock($1, $2)", TEST_KEY, S1)
        else:
            failures.append(f"[5c] A 释放 s1 后，B 应能获取，实得 {b_after_release!r}")

        # ==================================================================
        # 断言 6：B1 事务级锁——非阻塞不挂起 + 提交自动释放（不多占）+ 反向对照
        # ==================================================================
        await conn_a.execute("SELECT pg_advisory_lock($1, $2)", TEST_KEY, S1)

        # 6a：A 持 session 锁期间，B 用非阻塞 xact 锁 → 立即返回 False（不挂起）。
        tr_b1 = conn_b.transaction()
        await tr_b1.start()
        b_try_xact = await conn_b.fetchval(
            "SELECT pg_try_advisory_xact_lock($1, $2)", TEST_KEY, S1)
        await tr_b1.rollback()  # 没拿到锁，无需 unlock；事务本身也无别的改动
        if b_try_xact is False:
            print("OK  [6a] A 持 session 锁期间，B 的 pg_try_advisory_xact_lock 立即返回 False（不阻塞）")
        else:
            failures.append(f"[6a] A 持锁期间 B 的非阻塞 xact 锁应返回 False，实得 {b_try_xact!r}")

        # 6b（反向对照）：B 若改用阻塞式 pg_advisory_xact_lock，A 持锁期间该调用应真的
        # 挂起——用短超时探测，证明 try 与阻塞语义确有差别，B1 选 try 确实避免了挂起。
        conn_block = await asyncpg.connect(dsn)
        blocked = False
        try:
            tr_block = conn_block.transaction()
            await tr_block.start()
            try:
                await asyncio.wait_for(
                    conn_block.execute(
                        "SELECT pg_advisory_xact_lock($1, $2)", TEST_KEY, S1),
                    timeout=1.5,
                )
            except asyncio.TimeoutError:
                blocked = True
        finally:
            conn_block.terminate()  # 强制断开，不等挂起的查询返回；顺带回滚未提交事务
        if blocked:
            print("OK  [6b] 反向对照：A 持锁期间，阻塞式 pg_advisory_xact_lock 确实挂起（1.5s 超时探测到）")
        else:
            failures.append(
                "[6b] A 持锁期间，阻塞式 pg_advisory_xact_lock 应挂起，实际在超时内返回——"
                "try 与阻塞语义的差别未证实")

        # 6c：A 释放后，B 的非阻塞 xact 锁应成功，并随 B 自己的事务提交自动释放。
        await conn_a.execute("SELECT pg_advisory_unlock($1, $2)", TEST_KEY, S1)

        tr_b2 = conn_b.transaction()
        await tr_b2.start()
        b_try_xact2 = await conn_b.fetchval(
            "SELECT pg_try_advisory_xact_lock($1, $2)", TEST_KEY, S1)
        if b_try_xact2 is True:
            print("OK  [6c] A 释放 session 锁后，B 的 pg_try_advisory_xact_lock 成功获取 s1")
        else:
            failures.append(f"[6c] A 释放后，B 的非阻塞 xact 锁应成功，实得 {b_try_xact2!r}")
        await tr_b2.commit()  # 不显式 unlock——xact 锁应随提交自动释放

        # 提交后用另一连接（A）验证锁确已自动释放、B 没有多占。
        a_after_b_commit = await conn_a.fetchval(
            "SELECT pg_try_advisory_lock($1, $2)", TEST_KEY, S1)
        if a_after_b_commit is True:
            print("OK  [6d] B 的事务提交后，A 立即能拿到 s1（xact 锁随提交自动释放，未多占）")
            await conn_a.execute("SELECT pg_advisory_unlock($1, $2)", TEST_KEY, S1)
        else:
            failures.append(
                f"[6d] B 提交后 s1 应已自动释放，A 应能立即拿到，实得 {a_after_b_commit!r} "
                "→ xact 锁被多占了")

    finally:
        # 安全网：无论上面走到哪一步失败，都释放本会话可能仍持有的 session 级
        # advisory lock（xact 级锁随事务结束/连接关闭自动释放，无需处理）。
        for c in (conn_a, conn_b):
            try:
                await c.execute("SELECT pg_advisory_unlock_all()")
            except Exception:
                pass
        cleanup_conn = await asyncpg.connect(dsn)
        try:
            await _cleanup(cleanup_conn)
        finally:
            await cleanup_conn.close()
        await conn_a.close()
        await conn_b.close()
        await conn_c.close()

    print("-" * 60)
    if failures:
        print(f"FAIL: {len(failures)} 条断言不成立——B2 快照读/按股锁的地基假设有问题：")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("PASS: RR 快照隔离 + 事务外可见 + readonly 生效 + 导入原子性 + "
          "按股锁隔离 + 事务级锁非阻塞/自动释放，六条断言全部成立。")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
