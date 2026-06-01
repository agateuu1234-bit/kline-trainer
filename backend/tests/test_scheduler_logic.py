# backend/tests/test_scheduler_logic.py
"""B4 scheduler_logic 纯决策测试（host 本地跑，不碰 PG / APScheduler）。"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.scheduler_logic import compute_replenish_deficit, is_expired_reserved

NOW = datetime(2026, 5, 30, 12, 0, 0, tzinfo=timezone.utc)
PAST = NOW - timedelta(minutes=5)
FUTURE = NOW + timedelta(minutes=5)


def test_expired_reserved_true_when_reserved_and_past():
    assert is_expired_reserved("reserved", PAST, NOW) is True


def test_expired_reserved_false_when_not_expired():
    assert is_expired_reserved("reserved", FUTURE, NOW) is False


def test_expired_reserved_strict_less_than_boundary():
    # 严格 `<`：lease_expires_at == now → 未过期
    assert is_expired_reserved("reserved", NOW, NOW) is False


def test_expired_reserved_false_when_not_reserved():
    assert is_expired_reserved("unsent", PAST, NOW) is False
    assert is_expired_reserved("sent", PAST, NOW) is False


def test_expired_reserved_false_when_expiry_none():
    assert is_expired_reserved("reserved", None, NOW) is False


def test_deficit_replenish_30_to_70():
    # 验收场景 B：unsent=30 (<=40) → 补 70
    assert compute_replenish_deficit(30) == 70


def test_deficit_at_threshold_40_replenishes():
    assert compute_replenish_deficit(40) == 60


def test_deficit_above_threshold_returns_zero():
    assert compute_replenish_deficit(41) == 0


def test_deficit_zero_when_empty_fills_to_target():
    assert compute_replenish_deficit(0) == 100


def test_deficit_clamped_when_over_target():
    assert compute_replenish_deficit(120) == 0
