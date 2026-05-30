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
