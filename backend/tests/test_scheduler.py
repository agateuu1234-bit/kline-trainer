# backend/tests/test_scheduler.py
"""B4 repo 扩展 + run_sweep + build_scheduler + adapter host 测试（本地跑）。"""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from uuid import UUID

import pytest

from app.lease_repo import InMemoryLeaseRepository, MetaRow

NOW = datetime(2026, 5, 30, 12, 0, 0, tzinfo=timezone.utc)
PAST = NOW - timedelta(minutes=5)
FUTURE = NOW + timedelta(minutes=5)
LID = UUID("6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d")


def _meta(id, status, lease_id=None, exp=None, reserved_at=None):
    return MetaRow(id=id, stock_code="600519", stock_name="贵州茅台",
                   filename=f"{id}.zip", schema_version=1, content_hash="deadbeef",
                   status=status, lease_id=lease_id, lease_expires_at=exp,
                   file_path=f"/tmp/{id}.zip", reserved_at=reserved_at)


def test_inmemory_count_unsent():
    repo = InMemoryLeaseRepository(rows=[
        _meta(1, "unsent"), _meta(2, "unsent"),
        _meta(3, "reserved", LID, FUTURE, NOW),
    ])
    assert asyncio.run(repo.count_unsent()) == 2


def test_inmemory_rollback_expired_resets_four_columns():
    repo = InMemoryLeaseRepository(rows=[
        _meta(1, "reserved", LID, PAST, NOW),
        _meta(2, "reserved", LID, FUTURE, NOW),
    ])
    rolled = asyncio.run(repo.rollback_expired(NOW))
    assert rolled == [1]
    r1 = repo._by_id(1)
    assert (r1.status == "unsent" and r1.lease_id is None
            and r1.lease_expires_at is None and r1.reserved_at is None)
    r2 = repo._by_id(2)
    assert r2.status == "reserved" and r2.lease_id == LID


def test_inmemory_rollback_five_expired():
    # 验收场景 A：5 条过期 reserved → 全回滚
    repo = InMemoryLeaseRepository(rows=[
        _meta(i, "reserved", LID, PAST, NOW) for i in range(1, 6)])
    assert asyncio.run(repo.rollback_expired(NOW)) == [1, 2, 3, 4, 5]
    assert asyncio.run(repo.count_unsent()) == 5


def _spy_generate_batch():
    calls = []

    async def gen(n):
        calls.append(n)
        return n

    return gen, calls


def test_run_sweep_replenish_30_to_70():
    # 验收场景 B：unsent=30 (<=40) → 请求生成 70 → generated 70
    from app.scheduler import run_sweep
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])
    gen, calls = _spy_generate_batch()
    result = asyncio.run(run_sweep(repo, NOW, gen))
    assert result.rolled_back == []
    assert result.deficit == 70
    assert result.generated == 70
    assert calls == [70]


def test_run_sweep_rollback_then_deficit_combined():
    # D4：30 unsent + 5 过期 reserved → 回滚后 35 (<=40) → deficit 65
    from app.scheduler import run_sweep
    rows = [_meta(i, "unsent") for i in range(1, 31)]
    rows += [_meta(i, "reserved", LID, PAST, NOW) for i in range(31, 36)]
    repo = InMemoryLeaseRepository(rows=rows)
    gen, calls = _spy_generate_batch()
    result = asyncio.run(run_sweep(repo, NOW, gen))
    assert result.rolled_back == [31, 32, 33, 34, 35]
    assert result.deficit == 65
    assert result.generated == 65
    assert calls == [65]


def test_run_sweep_rollback_pushes_over_threshold_skips_generate():
    # D4 后果：38 unsent + 5 过期 → 回滚后 43 (>40) → 不补
    from app.scheduler import run_sweep
    rows = [_meta(i, "unsent") for i in range(1, 39)]
    rows += [_meta(i, "reserved", LID, PAST, NOW) for i in range(39, 44)]
    repo = InMemoryLeaseRepository(rows=rows)
    gen, calls = _spy_generate_batch()
    result = asyncio.run(run_sweep(repo, NOW, gen))
    assert len(result.rolled_back) == 5
    assert result.deficit == 0
    assert result.generated == 0
    assert calls == []


def test_run_sweep_generated_can_be_less_than_deficit():
    from app.scheduler import run_sweep
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])

    async def short_gen(n):
        return n - 10

    result = asyncio.run(run_sweep(repo, NOW, short_gen))
    assert result.deficit == 70
    assert result.generated == 60


def test_run_sweep_until_target_retries_partial():
    # D16：首轮只补一半 → 仍 degraded → 同进程重试补剩余 → 达标
    from app.scheduler import run_sweep_until_target
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])  # 30 unsent
    calls = []

    async def gen(n):
        calls.append(n)
        added = n // 2 if len(calls) == 1 else n     # 首轮只补一半（模拟 skip）
        base = max((r.id for r in repo._rows), default=0)
        for k in range(added):
            repo._rows.append(_meta(base + 1 + k, "unsent"))
        return added

    result = asyncio.run(run_sweep_until_target(repo, NOW, gen))
    assert calls[0] == 70                       # 首轮请求 100-30
    assert len(calls) >= 2                       # 触发重试
    assert asyncio.run(repo.count_unsent()) == 100
    assert result.generated == result.deficit    # 末轮已达标


def test_run_sweep_until_target_exhausts_attempts():
    # D16：B2 始终生成不出（skip 耗尽）→ 重试耗尽仍 degraded
    from app.scheduler import run_sweep_until_target, sweep_is_degraded
    repo = InMemoryLeaseRepository(rows=[_meta(i, "unsent") for i in range(1, 31)])

    async def gen(n):
        return 0

    result = asyncio.run(run_sweep_until_target(repo, NOW, gen, max_attempts=3))
    assert sweep_is_degraded(result) is True
    assert result.generated == 0
