# backend/tests/test_lease_logic.py
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from uuid import UUID

from app.lease_logic import (
    ConfirmOutcome,
    RowState,
    LEASE_TTL,
    decide_confirm,
    is_meta_selectable,
    format_expires_at,
)

NOW = datetime(2026, 5, 22, 12, 30, 0, tzinfo=timezone.utc)
LID = UUID("6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d")
OTHER = UUID("11111111-2222-4333-8444-555566667777")
FUTURE = NOW + timedelta(minutes=5)
PAST = NOW - timedelta(minutes=5)


# ---- decide_confirm（D2 状态机；判定顺序：not_found → idempotent → invalid → commit）----
def test_confirm_row_missing_returns_not_found():
    assert decide_confirm(None, LID, NOW) is ConfirmOutcome.NOT_FOUND


def test_confirm_already_sent_same_lease_is_idempotent():
    row = RowState(status="sent", lease_id=LID, lease_expires_at=FUTURE)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.IDEMPOTENT_OK


def test_confirm_sent_idempotent_even_if_lease_expired():
    # 关键：已 sent 行即使 lease_expires_at 已过期，幂等检查仍先命中（不返 409）
    row = RowState(status="sent", lease_id=LID, lease_expires_at=PAST)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.IDEMPOTENT_OK


def test_confirm_lease_id_mismatch_is_invalid():
    row = RowState(status="reserved", lease_id=OTHER, lease_expires_at=FUTURE)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.LEASE_INVALID


def test_confirm_expired_lease_is_invalid():
    row = RowState(status="reserved", lease_id=LID, lease_expires_at=PAST)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.LEASE_INVALID


def test_confirm_valid_reserved_commits_sent():
    row = RowState(status="reserved", lease_id=LID, lease_expires_at=FUTURE)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.COMMIT_SENT


def test_confirm_boundary_expires_equal_now_commits_sent():
    # confirm 用严格 `<`：lease_expires_at == now → NOT < now → 不因过期判 invalid；
    # 但 reserved 且 lease 匹配且未过期 → COMMIT_SENT（边界 == now 视为未过期）
    row = RowState(status="reserved", lease_id=LID, lease_expires_at=NOW)
    assert decide_confirm(row, LID, NOW) is ConfirmOutcome.COMMIT_SENT


# ---- is_meta_selectable（D3 选择谓词；用 `<=`）----
def test_meta_unsent_selectable():
    assert is_meta_selectable("unsent", None, NOW) is True


def test_meta_reserved_expired_selectable():
    assert is_meta_selectable("reserved", PAST, NOW) is True


def test_meta_reserved_not_expired_not_selectable():
    assert is_meta_selectable("reserved", FUTURE, NOW) is False


def test_meta_reserved_expires_equal_now_selectable():
    # meta 用 `<=`：lease_expires_at == now → 视为已过期可重选（与 confirm 的 `<` 不对称）
    assert is_meta_selectable("reserved", NOW, NOW) is True


def test_meta_sent_never_selectable():
    assert is_meta_selectable("sent", PAST, NOW) is False


# ---- format_expires_at（D4 契约修正：必须 Z 后缀、无小数秒）----
def test_format_expires_at_uses_z_suffix_no_fraction():
    s = format_expires_at(datetime(2026, 5, 22, 12, 45, 0, tzinfo=timezone.utc))
    assert s == "2026-05-22T12:45:00Z"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", s)
    assert "+00:00" not in s


def test_format_expires_at_truncates_microseconds():
    s = format_expires_at(datetime(2026, 5, 22, 12, 45, 0, 123456, tzinfo=timezone.utc))
    assert s == "2026-05-22T12:45:00Z"


def test_format_expires_at_converts_non_utc_offset():
    # H2 防御：+08:00 的 20:45 = UTC 12:45（不能把 +08:00 wall-clock 直接贴 Z）
    from datetime import timezone as _tz
    beijing = _tz(timedelta(hours=8))
    s = format_expires_at(datetime(2026, 5, 22, 20, 45, 0, tzinfo=beijing))
    assert s == "2026-05-22T12:45:00Z"


def test_format_expires_at_naive_treated_as_utc():
    s = format_expires_at(datetime(2026, 5, 22, 12, 45, 0))   # naive → 视作 UTC
    assert s == "2026-05-22T12:45:00Z"


def test_lease_ttl_is_ten_minutes():
    assert LEASE_TTL == timedelta(minutes=10)


# ---- InMemoryLeaseRepository 直测（不经 HTTP）----
import asyncio
from app.lease_repo import InMemoryLeaseRepository, MetaRow


def _repo_with_rows():
    return InMemoryLeaseRepository(rows=[
        MetaRow(id=1, stock_code="600519", stock_name="贵州茅台",
                filename="600519_202001.zip", schema_version=1, content_hash="deadbeef",
                status="unsent", lease_id=None, lease_expires_at=None, file_path="/tmp/a.zip"),
        MetaRow(id=2, stock_code="000001", stock_name="平安银行",
                filename="000001_202103.zip", schema_version=1, content_hash="a0b1c2d3",
                status="sent", lease_id=LID, lease_expires_at=FUTURE, file_path="/tmp/b.zip"),
    ])


def test_inmemory_reserve_meta_marks_reserved_and_returns_meta():
    repo = _repo_with_rows()
    reserved = asyncio.run(repo.reserve_meta(count=5, lease_id=LID, expires_at=FUTURE, now=NOW))
    # 只有 id=1（unsent）可选；id=2 是 sent 不可选
    assert [r["id"] for r in reserved] == [1]
    assert reserved[0]["content_hash"] == "deadbeef"
    # 选后行被置 reserved + lease 三列非空（D9/M1 不变量：含 reserved_at）
    row1 = repo._by_id(1)
    assert (row1.status == "reserved" and row1.lease_id == LID
            and row1.lease_expires_at == FUTURE and row1.reserved_at == NOW)


def test_inmemory_reserve_meta_respects_count_upper_bound():
    repo = _repo_with_rows()
    reserved = asyncio.run(repo.reserve_meta(count=0, lease_id=LID, expires_at=FUTURE, now=NOW))
    assert reserved == []   # count=0 → 空（partial/empty 合法）


def test_inmemory_confirm_commit_then_idempotent():
    repo = _repo_with_rows()
    asyncio.run(repo.reserve_meta(count=1, lease_id=LID, expires_at=FUTURE, now=NOW))
    o1 = asyncio.run(repo.confirm(1, LID, NOW))
    assert o1 is ConfirmOutcome.COMMIT_SENT and repo._by_id(1).status == "sent"
    o2 = asyncio.run(repo.confirm(1, LID, NOW))     # 重复
    assert o2 is ConfirmOutcome.IDEMPOTENT_OK and repo._by_id(1).status == "sent"


def test_inmemory_confirm_unknown_id_not_found():
    repo = _repo_with_rows()
    assert asyncio.run(repo.confirm(999, LID, NOW)) is ConfirmOutcome.NOT_FOUND


def test_inmemory_file_path_lookup():
    repo = _repo_with_rows()
    assert asyncio.run(repo.get_file_path(1)) == "/tmp/a.zip"
    assert asyncio.run(repo.get_file_path(999)) is None
