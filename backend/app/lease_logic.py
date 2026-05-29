# backend/app/lease_logic.py
# Spec: kline_trainer_modules_v1.4.md §四 B3 (L755-808) + M0.2 (L351-393)
#
# 纯决策层（D1）：零 fastapi / asyncpg import；host pytest 全测。
# 租约状态机的判定逻辑抽成纯函数，供 InMemory + Asyncpg 两 repo 复用（D8）。
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from enum import Enum, auto
from typing import Optional
from uuid import UUID

# Lease TTL = 10 分钟（modules L376 / openapi 描述）
LEASE_TTL = timedelta(minutes=10)


class ConfirmOutcome(Enum):
    """POST /confirm 的状态机判定结果（路由层映射成 HTTP）。"""
    NOT_FOUND = auto()      # → 404 {"error": "not_found"}
    IDEMPOTENT_OK = auto()  # → 200 {"ok": true}（已 sent 且 lease 匹配，重复确认）
    LEASE_INVALID = auto()  # → 409 {"error": "lease_expired"}（lease 不匹配或过期）
    COMMIT_SENT = auto()    # → repo 置 sent 后 200 {"ok": true}


@dataclass(frozen=True)
class RowState:
    """confirm 判定需读的 training_sets 行字段子集。"""
    status: str
    lease_id: Optional[UUID]
    lease_expires_at: Optional[datetime]


def decide_confirm(row: Optional[RowState], lease_id: UUID, now: datetime) -> ConfirmOutcome:
    """D2：confirm 状态机（字面 modules L789-803）。
    判定顺序固定：not_found → idempotent(sent+匹配) → invalid(不匹配/过期) → commit。
    幂等检查必须在过期检查之前——已 sent 行保留 lease 供幂等，其 lease_expires_at 可能已过期。"""
    if row is None:
        return ConfirmOutcome.NOT_FOUND
    if row.status == "sent" and row.lease_id == lease_id:
        return ConfirmOutcome.IDEMPOTENT_OK
    if (row.lease_id != lease_id
            or row.lease_expires_at is None
            or row.lease_expires_at < now):       # 严格 `<`（spec L800）
        return ConfirmOutcome.LEASE_INVALID
    return ConfirmOutcome.COMMIT_SENT


def is_meta_selectable(status: str, lease_expires_at: Optional[datetime], now: datetime) -> bool:
    """D3：GET /meta 选择谓词（字面 modules L771-772）。
    status=='unsent' OR (status=='reserved' AND lease_expires_at <= now)。
    用 `<=`（与 confirm 的 `<` 不对称，按 spec 字面保留）。"""
    if status == "unsent":
        return True
    if status == "reserved" and lease_expires_at is not None:
        return lease_expires_at <= now            # 非严格 `<=`（spec L772）
    return False


def format_expires_at(dt: datetime) -> str:
    """D4：RFC3339 UTC，Z 后缀、无小数秒（如 2026-05-22T12:45:00Z），贴合冻结 contract-fixtures。
    防御性（plan-stage review H2）：先无条件转 UTC 再贴 Z——naive 视作 UTC，tz-aware 非 UTC
    先 astimezone(UTC) 换算，避免把本地/北京时区的 wall-clock 误贴 Z（B4 复用时的 footgun）。
    不用 datetime.isoformat()（多产 +00:00，偏离 fixture 字面 Z）。"""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
