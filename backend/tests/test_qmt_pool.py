# backend/tests/test_qmt_pool.py
"""QMT 4b 切片 S3：预筛 + 分层储备池（纯函数）的测试。"""
from __future__ import annotations

import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from qmt_normalize import QmtSchemaError
from qmt_pool import PrefilterStats, month_span, prefilter

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


from qmt_ingest import ExportLogEntry


def _entry(code: str, period: str, *, status: str = "ok",
           first: int | None = None, last: int | None = None, rows: int = 100):
    return ExportLogEntry(code=code, period=period, status=status, rows=rows,
                          first_time=first, last_time=last, source=code)


def _start_of_span(months: int) -> int:
    """造一个起点，使 [起点, 2025-12-31] 恰好跨 `months` 个自然月。"""
    total = 2025 * 12 + 12 - (months - 1)
    y, m = divmod(total - 1, 12)
    return _sh(y, m + 1, 1)


_END = _sh(2025, 12, 31)


def _stock(code: str, *, daily_months: int = 40, m1_months: int = 13,
           status: str = "ok") -> dict:
    """一只股的两条 export_log 记录。

    ⚠️ 照**真实导出**的形态造：`status != "ok"` 的行 rows=0、时间戳为 None
    （真实导出里 301583.SZ 正是这样，qmt_ingest 刻意保留条目）。
    照想象造样本让两个生产缺陷藏了三年且测试全绿。
    """
    if status != "ok":
        return {(code, "1m"): _entry(code, "1m", status=status, rows=0),
                (code, "daily"): _entry(code, "daily", status=status, rows=0)}
    return {
        (code, "1m"): _entry(code, "1m", first=_start_of_span(m1_months), last=_END),
        (code, "daily"): _entry(code, "daily", first=_start_of_span(daily_months), last=_END),
    }


def test_a_stock_passing_all_three_predicates_is_kept():
    codes, stats = prefilter(_stock("600000.SH"))
    assert codes == ["600000.SH"]
    assert stats.total == 1 and stats.passed == 1


def test_daily_span_boundary_39_passes_and_38_is_rejected():
    """spec §9 验收 3：`k_daily == 39` 放行 / `== 38` 剔。"""
    kept, _ = prefilter(_stock("600000.SH", daily_months=39))
    assert kept == ["600000.SH"]
    dropped, stats = prefilter(_stock("600000.SH", daily_months=38))
    assert dropped == [] and stats.rejected_daily_span == 1


def test_1m_span_boundary_8_passes_and_7_is_rejected():
    """spec §9 验收 3：`k_1m == 8` 放行 / `== 7` 剔。"""
    kept, _ = prefilter(_stock("600000.SH", m1_months=8))
    assert kept == ["600000.SH"]
    dropped, stats = prefilter(_stock("600000.SH", m1_months=7))
    assert dropped == [] and stats.rejected_1m_span == 1


def test_a_non_ok_status_is_rejected_without_touching_its_empty_timestamps():
    """真实导出里 301583.SZ 两个周期都是 `empty`、时间戳为空。

    先算月跨度、再看 status 的实现会在这里炸 —— 那正是 `qmt_ingest`
    在真实数据上栽过的顺序错误（整份 log 崩掉，5607 只好股一只都导不进来）。
    """
    entries = _stock("301583.SZ", status="empty")
    assert entries[("301583.SZ", "1m")].first_time is None      # 前提成立才算数
    codes, stats = prefilter(entries)
    assert codes == [] and stats.rejected_status == 1


def test_a_stock_missing_one_period_is_rejected():
    """两个周期缺一不可 —— 缺 daily 就没有 k_daily 可算。"""
    entries = {("430047.BJ", "1m"): _entry("430047.BJ", "1m",
                                           first=_start_of_span(13), last=_END)}
    codes, stats = prefilter(entries)
    assert codes == [] and stats.rejected_incomplete == 1


def test_the_four_rejection_counters_partition_the_universe():
    """`total == passed + 四条之和` —— 每只被剔的股**恰好**归因一次。

    这条挡的是「同一只股被记进两个计数器」与「某条剔除路径忘了计数」：
    两者都会让写进 manifest 的那份「关于数据源的第一份真实观测」自相矛盾。
    """
    entries: dict = {}
    entries.update(_stock("600000.SH"))                     # 通过
    entries.update(_stock("600004.SH", daily_months=10))    # 判据 (b)
    entries.update(_stock("000001.SZ", m1_months=3))        # 判据 (c)
    entries.update(_stock("301583.SZ", status="empty"))     # 判据 (a)
    entries[("430047.BJ", "1m")] = _entry("430047.BJ", "1m",
                                          first=_start_of_span(13), last=_END)  # 缺 daily
    codes, s = prefilter(entries)
    assert s.total == 5
    assert codes == ["600000.SH"]
    assert (s.passed + s.rejected_incomplete + s.rejected_status
            + s.rejected_daily_span + s.rejected_1m_span) == s.total


def test_output_order_does_not_depend_on_export_log_row_order():
    """dict 的迭代顺序 = `export_log.csv` 的**行序**。

    下游 `freeze_universe` 要对这个列表做 seeded 打乱，而打乱结果依赖入参顺序。
    若此处不排序，「同 seed 同一批股 → 同一个宇宙」这条本 spec 全部可复现性设计
    赖以成立的性质，就会**悄悄地**取决于 QMT 导出时的行序。
    """
    a: dict = {}
    for c in ("600000.SH", "000001.SZ", "430047.BJ"):
        a.update(_stock(c))
    b: dict = {}
    for c in ("430047.BJ", "600000.SH", "000001.SZ"):
        b.update(_stock(c))
    assert list(a) != list(b)                    # 两份输入的行序确实不同
    assert prefilter(a)[0] == prefilter(b)[0]
    assert prefilter(a)[0] == sorted(prefilter(a)[0])


def test_stats_travel_as_a_non_required_manifest_key():
    """预筛统计走「非必需顶层键」通道 —— **不 bump `manifest_version`**。

    靠的是 `validate_manifest` 的「原样返回、绝不做白名单投影」（O4-F10）
    与两个提交入口的 `_carry_forward_persisted_keys`（S2-F40）。
    """
    import qmt_manifest

    _, stats = prefilter(_stock("600000.SH"))
    field = stats.as_manifest_field()
    assert field == {"total": 1, "rejected_incomplete": 0, "rejected_status": 0,
                     "rejected_daily_span": 0, "rejected_1m_span": 0, "passed": 1}
    assert "prefilter_stats" not in qmt_manifest.REQUIRED_KEYS
    assert qmt_manifest.MANIFEST_VERSION == 1
