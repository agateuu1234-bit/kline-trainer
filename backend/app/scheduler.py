# backend/app/scheduler.py
# Spec: kline_trainer_modules_v1.4.md §四 B4 (L810-816)
#       + kline_trainer_plan_v1.5.md §8.1 (L1076-1078, L1156)
#
# 职责：1 回滚过期 reserved；2 unsent<=40 调 B2 generate_batch 补到 100；
#       3 清理 30 天前 sent（可选）—— 本 PR 省略，见 plan residual B4-R1
#
# 层次：run_sweep 纯编排（host 测）；build_scheduler/build_generate_batch/
#       start_b4_scheduler 接线（lazy import apscheduler / fake-pool 可测）。
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime
from typing import Awaitable, Callable, Protocol

from app.scheduler_logic import (
    REPLENISH_TARGET,
    REPLENISH_THRESHOLD,
    compute_replenish_deficit,
)

BEIJING_TZ = "Asia/Shanghai"
logger = logging.getLogger(__name__)


class _SweepRepo(Protocol):
    async def rollback_expired(self, now: datetime) -> list[int]: ...
    async def count_unsent(self) -> int: ...


@dataclass(frozen=True)
class SweepResult:
    """一次调度扫描结果。deficit=请求生成数；generated=实际生成数（B2 可能因 skip 少于 deficit）。"""
    rolled_back: list[int]
    deficit: int
    generated: int


async def run_sweep(
    repo: _SweepRepo,
    now: datetime,
    generate_batch: Callable[[int], Awaitable[int]],
    *,
    threshold: int = REPLENISH_THRESHOLD,
    target: int = REPLENISH_TARGET,
) -> SweepResult:
    """先回滚过期 lease，再按缺口委托 B2 补足（D4 顺序）。deficit<=0 不调 generate_batch。"""
    rolled_back = await repo.rollback_expired(now)
    unsent = await repo.count_unsent()
    deficit = compute_replenish_deficit(unsent, threshold=threshold, target=target)
    generated = await generate_batch(deficit) if deficit > 0 else 0
    return SweepResult(rolled_back=rolled_back, deficit=deficit, generated=generated)


def sweep_is_degraded(result: SweepResult) -> bool:
    """该 sweep 结果仍有未满足的剩余缺口（deficit>0）→ degraded，需告警。
    用于 run_sweep_until_target 的结果——其 deficit = 重试后基于实际 count_unsent 的最终剩余缺口。"""
    return result.deficit > 0


DEFAULT_MAX_SWEEP_ATTEMPTS = 3


async def run_sweep_until_target(
    repo: _SweepRepo,
    now: datetime,
    generate_batch: Callable[[int], Awaitable[int]],
    *,
    threshold: int = REPLENISH_THRESHOLD,
    target: int = REPLENISH_TARGET,
    max_attempts: int = DEFAULT_MAX_SWEEP_ATTEMPTS,
) -> SweepResult:
    """首轮完整 sweep（回滚 + 阈值门触发补足）；触发补足后基于**实际 count_unsent** 重试补到 target
    （codex branch-diff R2-F1：并发 /meta reserve 会把生成的 unsent 移走，不能只看 B2 生成数；
    以最终库存是否达 target 为准）。重试补 max(0, target-当前unsent)，不再过 unsent<=40 阈值门（D16）。
    返回 SweepResult：rolled_back=首轮回滚；deficit=重试后基于实际 count 的最终剩余缺口（0=已达 target）；
    generated=累计实际 B2 生成数。"""
    first = await run_sweep(repo, now, generate_batch, threshold=threshold, target=target)
    rolled = first.rolled_back
    initial_deficit = first.deficit
    total_generated = first.generated
    attempts = 1
    while initial_deficit > 0 and attempts < max_attempts:
        unsent = await repo.count_unsent()
        remaining = max(0, target - unsent)     # 重试按实际库存，不过阈值门
        if remaining <= 0:
            break
        total_generated += await generate_batch(remaining)
        attempts += 1
    final_deficit = 0
    if initial_deficit > 0:                     # 仅触发过补足才按最终实际库存判剩余缺口
        final_unsent = await repo.count_unsent()
        final_deficit = max(0, target - final_unsent)
    return SweepResult(rolled_back=rolled, deficit=final_deficit, generated=total_generated)


def build_scheduler(
    repo: _SweepRepo,
    generate_batch: Callable[[int], Awaitable[int]],
    *,
    threshold: int = REPLENISH_THRESHOLD,
    target: int = REPLENISH_TARGET,
):
    """构造每天北京时间 05:00 跑 run_sweep 的 AsyncIOScheduler（薄壳；CI 不跑）。
    lazy import apscheduler；max_instances=1+coalesce=True 防同进程重入（D11）。
    返回未 start 的调度器；调用方负责 .start()。"""
    from datetime import timezone

    from apscheduler.schedulers.asyncio import AsyncIOScheduler
    from apscheduler.triggers.cron import CronTrigger

    scheduler = AsyncIOScheduler(timezone=BEIJING_TZ)

    async def _job() -> None:
        try:
            result = await run_sweep_until_target(repo, datetime.now(timezone.utc), generate_batch,
                                                  threshold=threshold, target=target)
            logger.info("B4 sweep rolled_back=%d deficit=%d generated=%d",
                        len(result.rolled_back), result.deficit, result.generated)
            if sweep_is_degraded(result):   # codex R4-F2/R5-F3：最终库存仍未达 target 才告警，不静默
                logger.warning("B4 replenish degraded: final unsent still short by %d (generated %d)",
                               result.deficit, result.generated)
        except Exception:   # codex branch-diff F2：瞬时故障不得逃逸崩调度器；记录后等次日 cron(B4-R6)
            logger.exception("B4 sweep failed with exception; will retry at next daily fire")

    scheduler.add_job(
        _job,
        CronTrigger(hour=5, minute=0, timezone=BEIJING_TZ),
        id="b4_daily_sweep",
        replace_existing=True,
        max_instances=1,
        coalesce=True,
        misfire_grace_time=3600,   # codex R7-F3：daily 维护任务给 1h 宽限，05:00 短暂 stall 不跳过当天
        next_run_time=datetime.now(timezone.utc),  # codex branch-diff R2-F2：启动即首跑一次（防 05:00 后启动当天不补），之后按 cron
    )
    return scheduler


def build_generate_batch(
    pool,
    output_dir: str,
    rng=None,
) -> Callable[[int], Awaitable[int]]:
    """生产适配（D5/F2）：把 B2 generate_batch(conn,target_count,output_dir,rng)->list
    适配成 run_sweep 要的 (n)->实际生成数。pool=asyncpg.Pool（薄壳，fake-pool 可测）。
    局部 import generate_batch，避免 app.scheduler 顶层拉 pandas（保 run_sweep 测试轻量）。"""
    from pathlib import Path

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)   # F1：确保输出目录存在；不可写则抛 → lifespan startup 失败

    async def _gen(n: int) -> int:
        from generate_training_sets import B2_GENERATION_LOCK_KEY, generate_batch
        async with pool.acquire() as conn:
            # codex PF2-R5-F2：与 B2 CLI 互斥。拿不到锁 = 有人手工在跑 B2 →
            # 本次 sweep 生成 0 并告警，等下次 cron，不与之竞争同一产物路径。
            if not await conn.fetchval("SELECT pg_try_advisory_lock($1)",
                                       B2_GENERATION_LOCK_KEY):
                logger.warning("B2 生成锁被占（有人手工在跑 B2 CLI？）；本次 sweep 生成 0，"
                               "等下次 cron 重试")
                return 0
            try:
                produced = await generate_batch(conn, n, out, rng)
            finally:
                await conn.execute("SELECT pg_advisory_unlock($1)", B2_GENERATION_LOCK_KEY)
            return len(produced)

    return _gen


def start_b4_scheduler(
    repo: _SweepRepo,
    generate_batch: Callable[[int], Awaitable[int]],
    *,
    threshold: int = REPLENISH_THRESHOLD,
    target: int = REPLENISH_TARGET,
):
    """build + start B4 调度器，返回已 start 的 handle（供 lifespan 持有 + shutdown）。"""
    scheduler = build_scheduler(repo, generate_batch, threshold=threshold, target=target)
    scheduler.start()
    return scheduler
