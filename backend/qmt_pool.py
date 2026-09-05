# backend/qmt_pool.py
"""QMT 4b 切片 S3：`export_log` 预筛 + 分层 seeded 储备池（纯函数）。

Spec: `2026-07-27-qmt-plan4b-fetch-design.md` §4.2 / §4.3 / §4.4。

本模块**不碰文件系统、不碰数据库、不做网络 IO**（与 S2a 的读侧校验同规格）：
上接 `qmt_ingest.parse_export_log` 的产物，下出「冻结的分层候选名单」与
「本批要尝试的槽位」，交给 S4 的拷贝引擎去执行。落盘是 S2b `qmt_manifest` 的事。
"""
from __future__ import annotations

from qmt_normalize import QmtSchemaError, trading_date

# §4.3 的两条月数下界。
# 39 = 31 + 8：`generate_training_sets.py:128` 的 `if n < 31 + months`。
# 8：训练窗口需要的完整月数。
MIN_DAILY_MONTHS = 39
MIN_1M_MONTHS = 8


def month_span(first_epoch: int, last_epoch: int) -> int:
    """`[first, last]` 跨越的**不同自然月数**（含两端），按 Asia/Shanghai。

    ⚠️ **必须经 `trading_date()`**：入参是 **Unix 秒**（`qmt_ingest` 已把 QMT 的
    打包整数转过一道，见 `qmt_ingest.py:87`），而日线时间戳恰好落在当地 00:00
    = 前一天 16:00 UTC。按 UTC 算，任何从某月 1 日开始的日线都会被算进上个月，
    跨度凭空多一 —— **不抛异常、只是安静地把边界附近的股多留或多剔**，
    而三条预筛判据全是边界判据。`trading_date` 的 docstring 也写死了
    「所有日期分组/比对的唯一入口，禁 UTC/naive」。
    """
    if first_epoch is None or last_epoch is None:
        # 调用方没按次序调用（status 门必须先跑）—— 这是**代码**的问题，不是数据的问题。
        raise ValueError(
            "month_span 收到空时间戳 —— `status != \"ok\"` 的 export_log 行没有"
            "有效时间戳（qmt_ingest 刻意保留条目并置 None）。调用方必须**先过**"
            "status 门再算月数。"
        )
    if first_epoch > last_epoch:
        # 首尾时间戳被写反了，这是 **export_log 的内容**不合规 —— 与 parse_export_log
        # 对认不出的 period / 重复键的处置同族（spec §5），S5 的 CLI 据此映射 rc=2。
        raise QmtSchemaError(
            f"export_log 的时间戳区间是反的：first={first_epoch} > last={last_epoch}")
    a = trading_date(first_epoch)
    b = trading_date(last_epoch)
    return (b.year - a.year) * 12 + (b.month - a.month) + 1
