# backend/app/scheduler_logic.py
# Spec: kline_trainer_modules_v1.4.md §四 B4 (L810-816)
#       + kline_trainer_plan_v1.5.md §8.1 (L1076-1078)
#
# 纯决策层（D8）：只吃原语（status / datetime / int），零 fastapi/asyncpg/app import。
# 不 import MetaRow（避免与 lease_repo 形成循环）；host pytest 全测。
from __future__ import annotations

from datetime import datetime
from typing import Optional

# 补足触发阈值与上限（spec L1078 / modules L814）
REPLENISH_THRESHOLD = 40
REPLENISH_TARGET = 100


def is_expired_reserved(status: str, lease_expires_at: Optional[datetime],
                        now: datetime) -> bool:
    """B4 职责 1 回滚判定：status=='reserved' 且 lease_expires_at 严格 < now（spec L813）。
    lease_expires_at 为 None → 无到期信息 → 保守不回滚。
    与 B3 is_meta_selectable 的 `<=` 不对称，按各自 spec 字面保留。"""
    return (status == "reserved"
            and lease_expires_at is not None
            and lease_expires_at < now)


def compute_replenish_deficit(unsent_count: int, *,
                              threshold: int = REPLENISH_THRESHOLD,
                              target: int = REPLENISH_TARGET) -> int:
    """B4 职责 2：unsent_count <= threshold 才补，补到 target；否则 0（spec L1078）。
    返回值 = 要新生成的个数，由 run_sweep 作为 generate_batch 的 target_count 传入。"""
    if unsent_count > threshold:
        return 0
    return max(0, target - unsent_count)
