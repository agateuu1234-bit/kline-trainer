#!/usr/bin/env python3
"""验证 B2 生成锁下沉的地基假设：PostgreSQL session 级 advisory lock 的
**可重入计数**语义 + **跨连接互斥**语义。

背景：`generate_one_training_set` 内层新加的 `pg_try_advisory_lock` 依赖两件事——
  (1) 同一连接已持锁时再取同一把锁**必然成功**（否则 CLI/调度器会自锁死）；
  (2) 需要**配对次数**的 unlock 才真正释放（计数语义，否则一次 unlock 就放了、
      外层锁提前失效）；
  (3) 不同连接对同一 key 互斥（否则整把锁没意义）。

本仓单测用假 conn，验不了这些——假件对"同一 session 第二次取锁"和"第一次取锁"
反应完全一样（review 已指出：假件建模的是"锁永远能拿到"，不是可重入计数）。
故用真 PostgreSQL 跑一遍。

用法（user 真终端，需真 PG）：
  cd "/Users/maziming/Coding/Prj_Kline trainer"
  # 若用 PR 2a 那套 Docker PG：先起容器，DSN 形如
  #   postgresql://postgres:postgres@localhost:5432/postgres
  DSN='postgresql://postgres:postgres@localhost:5432/postgres' \
    .venv/bin/python backend/scripts/verify_advisory_lock_reentrancy.py

  # 若 .venv 没装 asyncpg（whole-branch review 指出本仓未装）：先装
  #   .venv/bin/python -m pip install asyncpg
  # 它只装进 .venv，不影响生产/测试依赖。

退出码 0 = 三条断言全部成立（可重入假设坐实）。非 0 = 有断言不成立，
锁下沉设计的地基有问题，必须停下重新评估——**不要**因为单测绿就当它成立。
"""
import asyncio
import os
import sys

# 与 generate_training_sets.B2_GENERATION_LOCK_KEY 保持一致（那里是 0x42345CEE）。
# 这里用一个**不同**的临时 key，避免与任何真在跑的 B2/B4 抢锁；语义验证与 key 值无关。
TEST_KEY = 0x42345CEF


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

    conn_a = await asyncpg.connect(dsn)
    conn_b = await asyncpg.connect(dsn)
    failures = []
    try:
        # ---- 断言 1：同一连接可重入（第二次取锁必须也成功）----
        r1 = await conn_a.fetchval("SELECT pg_try_advisory_lock($1)", TEST_KEY)
        r2 = await conn_a.fetchval("SELECT pg_try_advisory_lock($1)", TEST_KEY)
        if not (r1 is True and r2 is True):
            failures.append(
                f"[可重入] 同一连接连取两次应都返回 True，实得 r1={r1!r} r2={r2!r} "
                "→ 内层锁会把已持锁的 CLI/调度器自己锁死")
        else:
            print(f"OK  可重入：同一连接连取两次均返回 True（r1={r1}, r2={r2}）")

        # ---- 断言 2：计数语义（取了 2 次，需要 2 次 unlock 才真正释放）----
        u1 = await conn_a.fetchval("SELECT pg_advisory_unlock($1)", TEST_KEY)
        # 此刻仍持有一层：另一连接不该拿得到
        b_after_one_unlock = await conn_b.fetchval(
            "SELECT pg_try_advisory_lock($1)", TEST_KEY)
        if b_after_one_unlock is not False:
            failures.append(
                f"[计数] 取锁 2 次、仅 unlock 1 次后，另一连接却拿到了锁 "
                f"(得 {b_after_one_unlock!r}) → 说明不是计数语义、一次 unlock 就全放了 "
                "→ 外层锁的独占会被内层的第一次 unlock 提前打破")
        else:
            print("OK  计数：取 2 次仅放 1 次后，另一连接仍拿不到锁（配对计数成立）")

        u2 = await conn_a.fetchval("SELECT pg_advisory_unlock($1)", TEST_KEY)
        if not (u1 is True and u2 is True):
            failures.append(
                f"[计数] 两次 unlock 应都返回 True，实得 u1={u1!r} u2={u2!r}")

        # ---- 断言 3：完全释放后，另一连接可获取（跨连接互斥确实解除）----
        b_after_full = await conn_b.fetchval(
            "SELECT pg_try_advisory_lock($1)", TEST_KEY)
        if b_after_full is not True:
            failures.append(
                f"[互斥解除] A 完全释放后 B 应能取到锁，实得 {b_after_full!r}")
        else:
            print("OK  互斥：A 配对释放完毕后，B 成功获取（锁确实回到可用）")
            await conn_b.fetchval("SELECT pg_advisory_unlock($1)", TEST_KEY)

        # ---- 断言 4（补充）：A 持锁时 B 直接拿不到（基本互斥，防"根本没锁上"）----
        await conn_a.fetchval("SELECT pg_try_advisory_lock($1)", TEST_KEY)
        b_blocked = await conn_b.fetchval(
            "SELECT pg_try_advisory_lock($1)", TEST_KEY)
        if b_blocked is not False:
            failures.append(
                f"[互斥] A 持锁时 B 不应拿到，实得 {b_blocked!r} → 锁根本没生效")
        else:
            print("OK  互斥：A 持锁时 B 直接拿不到（跨连接互斥生效）")
        await conn_a.fetchval("SELECT pg_advisory_unlock($1)", TEST_KEY)
    finally:
        await conn_a.close()
        await conn_b.close()

    print("-" * 60)
    if failures:
        print(f"FAIL: {len(failures)} 条断言不成立——锁下沉地基有问题：")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("PASS: 可重入 + 计数 + 跨连接互斥 三项全部成立。锁下沉假设坐实。")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
