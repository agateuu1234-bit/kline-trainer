# backend/app/lease_repo.py
# Spec: kline_trainer_modules_v1.4.md §四 B3 (L763-803)
#
# Repository 抽象（D1/D8）：
#   - LeaseRepository：路由依赖的异步协议
#   - InMemoryLeaseRepository：一等真实现（路由测试 + B4 调度器测试复用）
#   - AsyncpgLeaseRepository：薄 raw-SQL 壳（CI 不单测，NAS 部署集成；asyncpg 局部 import）
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from typing import Optional
from uuid import UUID

from app.lease_logic import ConfirmOutcome, RowState, decide_confirm, is_meta_selectable
from app.scheduler_logic import is_expired_reserved

# meta 响应需返回的 6 字段（对齐 openapi TrainingSetMetaItem / contract-fixtures）
_META_FIELDS = ("id", "stock_code", "stock_name", "filename", "schema_version", "content_hash")


@dataclass
class MetaRow:
    """training_sets 行的内存表示（InMemory fake 用；含 meta 字段 + lease 状态 + file_path）。"""
    id: int
    stock_code: str
    stock_name: str
    filename: str
    schema_version: int
    content_hash: str
    status: str
    lease_id: Optional[UUID]
    lease_expires_at: Optional[datetime]
    file_path: str
    reserved_at: Optional[datetime] = None   # D9/M1：reserved/sent 行须非空（对齐 ck_lease_state_invariant）


class LeaseRepository(ABC):
    """路由依赖的租约仓储协议。InMemory + Asyncpg 两实现。"""

    @abstractmethod
    async def reserve_meta(self, count: int, lease_id: UUID,
                           expires_at: datetime, now: datetime) -> list[dict]:
        """选 ≤count 个可预占行（D3 谓词），原子置 reserved + lease 三列，返回 meta 字段 dict 列表。"""

    @abstractmethod
    async def confirm(self, id: int, lease_id: UUID, now: datetime) -> ConfirmOutcome:
        """D2/D8：原子 fetch+判定+update，返回 ConfirmOutcome。"""

    @abstractmethod
    async def get_file_path(self, id: int) -> Optional[str]:
        """download 用：返回 zip file_path，行不存在返 None。"""


class InMemoryLeaseRepository(LeaseRepository):
    """一等内存实现（无 PG 也能跑全状态机；路由测试 + B4 测试复用 + 本地 dev）。"""

    def __init__(self, rows: Optional[list[MetaRow]] = None) -> None:
        self._rows: list[MetaRow] = list(rows or [])

    def _by_id(self, id: int) -> Optional[MetaRow]:
        return next((r for r in self._rows if r.id == id), None)

    async def reserve_meta(self, count: int, lease_id: UUID,
                           expires_at: datetime, now: datetime) -> list[dict]:
        picked: list[dict] = []
        for r in self._rows:                       # 按插入序（≈ created_at ORDER BY）
            if len(picked) >= count:
                break
            if is_meta_selectable(r.status, r.lease_expires_at, now):
                r.status = "reserved"              # D9：reserved 必带 lease 三列非空
                r.lease_id = lease_id
                r.lease_expires_at = expires_at
                r.reserved_at = now                # M1：维持 ck_lease_state_invariant 第三列
                picked.append({k: getattr(r, k) for k in _META_FIELDS})
        return picked

    async def confirm(self, id: int, lease_id: UUID, now: datetime) -> ConfirmOutcome:
        r = self._by_id(id)
        row_state = None if r is None else RowState(r.status, r.lease_id, r.lease_expires_at)
        outcome = decide_confirm(row_state, lease_id, now)
        if outcome is ConfirmOutcome.COMMIT_SENT and r is not None:
            r.status = "sent"                      # 保留 lease 三列（CHECK 允许 sent 带 lease）
        return outcome

    async def get_file_path(self, id: int) -> Optional[str]:
        r = self._by_id(id)
        return None if r is None else r.file_path

    async def count_unsent(self) -> int:
        """B4：统计 status=='unsent' 行数。"""
        return sum(1 for r in self._rows if r.status == "unsent")

    async def rollback_expired(self, now: datetime) -> list[int]:
        """B4 职责 1：过期 reserved → unsent，重置 lease 三列 + reserved_at（维持
        ck_lease_state_invariant：unsent 行 lease 字段须为空）。返回回滚 id 列表。"""
        ids: list[int] = []
        for r in self._rows:
            if is_expired_reserved(r.status, r.lease_expires_at, now):
                r.status = "unsent"
                r.lease_id = None
                r.lease_expires_at = None
                r.reserved_at = None
                ids.append(r.id)
        return ids


class AsyncpgLeaseRepository(LeaseRepository):
    """薄 raw-SQL 壳（D1）：CI 不单测，NAS 部署集成。SQL 字面对齐 modules L763-803。"""

    def __init__(self, pool) -> None:              # asyncpg.Pool（局部类型，不顶层 import asyncpg）
        self._pool = pool

    async def reserve_meta(self, count: int, lease_id: UUID,
                           expires_at: datetime, now: datetime) -> list[dict]:
        async with self._pool.acquire() as conn:
            async with conn.transaction():
                rows = await conn.fetch(
                    """
                    SELECT id, stock_code, stock_name, file_path, schema_version, content_hash
                    FROM training_sets
                    WHERE status = 'unsent'
                       OR (status = 'reserved' AND lease_expires_at <= $1)
                    ORDER BY created_at
                    LIMIT $2
                    FOR UPDATE SKIP LOCKED
                    """, now, count)
                ids = [r["id"] for r in rows]
                if ids:
                    await conn.execute(
                        """
                        UPDATE training_sets
                           SET status = 'reserved', lease_id = $1,
                               lease_expires_at = $2, reserved_at = $3
                         WHERE id = ANY($4)
                        """, lease_id, expires_at, now, ids)
                # filename = file_path 的 basename（meta 契约要 filename 字段）
                return [{
                    "id": r["id"], "stock_code": r["stock_code"], "stock_name": r["stock_name"],
                    "filename": r["file_path"].rsplit("/", 1)[-1],
                    "schema_version": r["schema_version"], "content_hash": r["content_hash"],
                } for r in rows]

    async def confirm(self, id: int, lease_id: UUID, now: datetime) -> ConfirmOutcome:
        async with self._pool.acquire() as conn:
            async with conn.transaction():
                row = await conn.fetchrow(
                    "SELECT status, lease_id, lease_expires_at FROM training_sets "
                    "WHERE id = $1 FOR UPDATE", id)
                row_state = None if row is None else RowState(
                    row["status"], row["lease_id"], row["lease_expires_at"])
                outcome = decide_confirm(row_state, lease_id, now)
                if outcome is ConfirmOutcome.COMMIT_SENT:
                    await conn.execute(
                        "UPDATE training_sets SET status = 'sent' WHERE id = $1", id)
                return outcome

    async def get_file_path(self, id: int) -> Optional[str]:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                "SELECT file_path FROM training_sets WHERE id = $1", id)
