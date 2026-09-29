# backend/rebuild_training_sets.py
"""切片一 P4 的 R2：按【钉死的起点】用【生产口径】重建训练组产物。

⛔ 本模块对源库**只读**：全部是 SELECT，绝不 INSERT / UPDATE / DELETE / DDL，
   也绝不调 `_register_training_set`（它是一条 `INSERT INTO training_sets`）。
   理由见 spec §3.4 R2 ⓐ：源库 `kline_trial` 里那 3 行是权威原始数据。

⭐ 窗口**不自己切**：把候选起点收窄到只剩目标那一个，然后调用与生产完全同一个纯入口
   `build_training_windows` —— 于是 D6（每周期前后根数）与 D9（盘中逐日完整）两道门
   照样跑，窗口口径与生产逐字一致。⛔ 直接调 `select_period_window` 会绕过这两道门。
"""
from __future__ import annotations

import random
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from generate_training_sets import (
    PERIOD_BEFORE_CAP, SCHEMA_VERSION, GeneratedTrainingSet, GenerateSkipException,
    _stock_name_of, assemble_from_windows, build_training_windows, compute_after_end,
    load_gating_inputs,
)

#: 训练组 zip 在 api 容器内的目录（与 p11 SQL 里那三行的 file_path 一致）
CONTAINER_TRAINING_SETS_DIR = "/data/training-sets"


class RebuildMismatch(Exception):
    """重建过程中任一「与权威值对不上」的断言失败。

    ⛔ 它**不是** `GenerateSkipException`：那个的语义是「这个候选不行，换一个」，
    而本异常的语义是「停下来查清楚，不得继续」。两者混用会把停机信号降级成跳过。
    """


@dataclass(frozen=True)
class RebuildTarget:
    stock_code: str
    start_datetime: int
    expected_end_datetime: int


#: spec §3.4 R2 ⓑ/ⓑ2：起点与右端都取自旧三个产物的权威值
#: （见 docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql 的 p11_expected）
PINNED_TARGETS: tuple[RebuildTarget, ...] = (
    RebuildTarget("000001.SZ", 1756656000, 1777996799),
    RebuildTarget("600519.SH", 1762099200, 1782835199),
    RebuildTarget("000001.SZ", 1762099200, 1782835199),
)


def pin_start_excludes(month_boundaries, start_datetime: int) -> frozenset:
    """把 `build_training_windows` 的候选集收成【至多一个】。

    `exclude_starts` 在 `select_valid_window` 里是在切 `[:max_retries]` **之前**过滤的
    （见该函数 docstring），所以把「除目标外的全部月边界」塞进去，剩下的候选最多一个，
    `rng.shuffle` 从此与结果无关。
    """
    targets = {int(b) for b in month_boundaries}
    if int(start_datetime) not in targets:
        raise RebuildMismatch(
            f"起点 {start_datetime} 不是月边界（本股共 {len(targets)} 个月边界）"
            f" —— 源库数据或月边界与当初不同，⛔ 停下来查清楚，不得继续")
    return frozenset(targets - {int(start_datetime)})


def build_pinned_windows(period_bars, month_boundaries, *, start_datetime: int,
                         dense_dates, trading_dates, dropped,
                         rng: Optional[random.Random] = None):
    """起点钉死版的 `build_training_windows`。返回 `(start_datetime, windows)`。"""
    excludes = pin_start_excludes(month_boundaries, start_datetime)
    try:
        start, windows = build_training_windows(
            period_bars, month_boundaries, rng or random.Random(0),
            dense_dates=dense_dates, trading_dates=trading_dates,
            before_caps=PERIOD_BEFORE_CAP, max_retries=1,
            exclude_starts=excludes, dropped=dropped)
    except GenerateSkipException as exc:
        # 钉死之后只剩一个候选：它被门拒 ⇒ 没有「换一个」这回事。
        raise RebuildMismatch(
            f"钉死的起点 {start_datetime} 过不了门控（{exc}）"
            f" —— ⛔ 停下来查清楚，不得退回去选别的起点") from exc
    if int(start) != int(start_datetime):
        raise RebuildMismatch(
            f"钉死的起点失效：要求 {start_datetime}，实际返回 {start}")
    return int(start), windows
