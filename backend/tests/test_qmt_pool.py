# backend/tests/test_qmt_pool.py
"""QMT 4b 切片 S3：预筛 + 分层储备池（纯函数）的测试。"""
from __future__ import annotations

import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from qmt_normalize import QmtSchemaError
from qmt_pool import month_span

_SH = ZoneInfo("Asia/Shanghai")


def _sh(y: int, m: int, d: int, hh: int = 0, mi: int = 0) -> int:
    """造「上海时间的这一刻」的 Unix 秒——与 qmt_normalize.parse_qmt_datetime 同口径。"""
    return int(dt.datetime(y, m, d, hh, mi, tzinfo=_SH).timestamp())


def test_a_range_inside_one_calendar_month_spans_one():
    assert month_span(_sh(2025, 7, 4), _sh(2025, 7, 31)) == 1


def test_two_adjacent_days_across_a_month_boundary_span_two():
    assert month_span(_sh(2025, 7, 31), _sh(2025, 8, 1)) == 2


def test_span_crosses_a_year_boundary():
    assert month_span(_sh(2024, 12, 31), _sh(2025, 1, 1)) == 2


def test_span_counts_calendar_months_not_elapsed_time():
    # 2023-01 .. 2025-03 = 2023 全年 12 + 2024 全年 12 + 2025 的 1~3 月 3 = 27
    assert month_span(_sh(2023, 1, 31), _sh(2025, 3, 1)) == 27


def test_month_span_is_measured_in_shanghai_not_utc():
    """日线时间戳正好落在**当地 00:00**，按 UTC 算会退回上一个月。

    QMT 日线是 8 位打包整数（如 20250801），`parse_qmt_datetime` 用 `%Y%m%d`
    解析后按 Asia/Shanghai 本地化 —— 于是**每一个**日线 first_time 都恰好是
    当地 00:00 = 前一天 16:00 UTC。某只股的日线若从某月 1 日开始，
    UTC 实现会把它算进上个月、跨度凭空多一，**而且不抛任何异常**。
    """
    assert month_span(_sh(2025, 8, 1), _sh(2025, 8, 20)) == 1


def test_month_span_refuses_an_empty_timestamp():
    """`status != "ok"` 的行时间戳是 None（qmt_ingest 刻意保留条目）。

    调用方必须先过 status 门再算月数；够不到这条纪律时要**响亮地**失败，
    而不是抛一个来路不明的 TypeError。

    ⚠️ 它必须**不是** `QmtSchemaError`：这是**代码**的次序问题，不是数据不合规。
    两族混同的话，S5 的命令行会把一个内部 bug 报成「你的 export_log 有问题」，
    把操作者指向一个根本不存在的问题。
    """
    with pytest.raises(ValueError, match="空时间戳") as exc:
        month_span(None, _sh(2025, 1, 1))
    assert not isinstance(exc.value, QmtSchemaError)


def test_month_span_refuses_a_reversed_interval():
    """首尾写反是 **export_log 的内容**坏了，不是调用方的错 —— 故属 QmtSchemaError。

    ⚠️ 断言必须钉**精确的族**：`QmtSchemaError` 是 `ValueError` 的子类，
    写成 `pytest.raises(ValueError)` 的话，两种实现都绿，判别力为零。
    """
    with pytest.raises(QmtSchemaError, match="区间是反的"):
        month_span(_sh(2025, 8, 1), _sh(2025, 7, 1))
