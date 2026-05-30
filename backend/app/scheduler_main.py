# backend/app/scheduler_main.py
# B4 独立单例调度器进程入口（python -m app.scheduler_main）。
# 与 web 进程分离（D12/D13）：web (uvicorn app.main) 可多 worker 不起调度器；
# 本进程单独部署，DB 层 advisory lock 强制单例（D14）。薄壳：真 asyncpg pool，CI 不跑。
from __future__ import annotations

import asyncio
import logging
import os
from typing import Awaitable, Callable, Optional

logger = logging.getLogger(__name__)

# 进程级单例 advisory lock key（D14；任意固定 bigint，B4 scheduler 专用）
SCHEDULER_LOCK_KEY = 0x42345CED


async def run_scheduler_process(
    dsn: str,
    output_dir: str,
    *,
    block: Optional[Callable[[], Awaitable[None]]] = None,
) -> None:
    """建 pool → 抢进程级 advisory lock（D14）→ 拿到才建 repo/adapter/start 调度器并常驻；
    退出时 unlock + shutdown + 关 pool。block 可注入（测试传立即返回的协程）。
    拿不到锁（已有 scheduler 进程持锁）→ log error + 直接返回（第二进程退出，不重复 sweep）。"""
    import asyncpg

    from app.lease_repo import AsyncpgLeaseRepository
    from app.scheduler import build_generate_batch, start_b4_scheduler

    pool = await asyncpg.create_pool(dsn)
    lock_conn = None
    scheduler = None
    try:
        lock_conn = await pool.acquire()
        locked = await lock_conn.fetchval("SELECT pg_try_advisory_lock($1)", SCHEDULER_LOCK_KEY)
        if not locked:
            logger.error("another B4 scheduler holds singleton lock %s; exiting", SCHEDULER_LOCK_KEY)
            return
        repo = AsyncpgLeaseRepository(pool)
        gen = build_generate_batch(pool, output_dir)
        scheduler = start_b4_scheduler(repo, gen)
        if block is None:
            await asyncio.Event().wait()        # 常驻（生产）
        else:
            await block()                       # 测试注入
    finally:
        if scheduler is not None:
            scheduler.shutdown(wait=False)
        if lock_conn is not None:
            try:
                await lock_conn.execute("SELECT pg_advisory_unlock($1)", SCHEDULER_LOCK_KEY)
            finally:
                await pool.release(lock_conn)
        await pool.close()


def main() -> None:
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        raise SystemExit("DATABASE_URL required for B4 scheduler process")
    # D15：scheduler 与 web 分进程，file_path 须落在两进程共享的绝对路径
    output_dir = os.environ.get("TRAINING_SETS_DIR")
    if not output_dir or not os.path.isabs(output_dir):
        raise SystemExit("TRAINING_SETS_DIR must be set to an absolute shared path")
    asyncio.run(run_scheduler_process(dsn, output_dir))


if __name__ == "__main__":
    main()
