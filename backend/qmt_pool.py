# backend/qmt_pool.py
"""QMT 4b 切片 S3：`export_log` 预筛 + 分层 seeded 储备池（纯函数）。

Spec: `2026-07-27-qmt-plan4b-fetch-design.md` §4.2 / §4.3 / §4.4。

本模块**不碰文件系统、不碰数据库、不做网络 IO**（与 S2a 的读侧校验同规格）：
上接 `qmt_ingest.parse_export_log` 的产物，下出「冻结的分层候选名单」与
「本批要尝试的槽位」，交给 S4 的拷贝引擎去执行。落盘是 S2b `qmt_manifest` 的事。
"""
from __future__ import annotations

from dataclasses import dataclass

from qmt_ingest import ExportLogEntry
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


@dataclass(frozen=True)
class PrefilterStats:
    """§4.3 的预筛统计 ——「关于数据源的第一份真实观测」，随 manifest 落盘。

    四个 `rejected_*` 之间**互斥且穷尽**：每只被剔的股按 `prefilter` 的判定次序
    恰好归因到一条上，`total == passed + 四条之和` 是不变量。
    """
    total: int
    rejected_incomplete: int
    rejected_status: int
    rejected_daily_span: int
    rejected_1m_span: int
    passed: int

    def as_manifest_field(self) -> dict:
        """写进 manifest 的 `prefilter_stats`（**非必需**顶层键，不 bump 版本）。"""
        return {"total": self.total,
                "rejected_incomplete": self.rejected_incomplete,
                "rejected_status": self.rejected_status,
                "rejected_daily_span": self.rejected_daily_span,
                "rejected_1m_span": self.rejected_1m_span,
                "passed": self.passed}


def prefilter(entries: dict[tuple[str, str], ExportLogEntry]
              ) -> tuple[list[str], PrefilterStats]:
    """§4.3 的三条判据（外加一条「两个周期缺一不可」）。

    返回 `(codes, stats)`，`codes` **按字典序升序**。

    ⚠️ **判定次序是判据的一部分**：`status != "ok"` 的行没有有效时间戳
    （真实导出里 `301583.SZ` 的 `first_time`/`last_time` 都是空的，`qmt_ingest`
    保留条目并置 `None`），先算月跨度会当场炸。**先看 status，再碰时间戳** ——
    这正是 `qmt_ingest` 自己在真实数据上栽过的那一跤。

    ⚠️ **升序返回不是可有可无的整洁**：下游 `freeze_universe` 对它做 seeded 打乱，
    而打乱结果依赖入参**顺序**；dict 的迭代顺序就是 `export_log.csv` 的行序。
    不排序的话，「同 seed → 同一个宇宙」会悄悄依赖 QMT 导出时的行序。

    ⚠️ **三条判据都是保守下界，不替代真门**：真门照样在 pilot 里跑。实测在当前
    这份导出上只筛掉 8.4%（S3-F2），实现者不得据此假定宇宙会被大幅缩小。
    """
    by_code: dict[str, dict[str, ExportLogEntry]] = {}
    for (code, period), ent in entries.items():
        by_code.setdefault(code, {})[period] = ent

    passed: list[str] = []
    n_incomplete = n_status = n_daily = n_1m = 0

    for code in sorted(by_code):
        per = by_code[code]
        e_1m, e_daily = per.get("1m"), per.get("daily")
        if e_1m is None or e_daily is None:
            n_incomplete += 1
        elif e_1m.status != "ok" or e_daily.status != "ok":
            n_status += 1
        elif month_span(e_daily.first_time, e_daily.last_time) < MIN_DAILY_MONTHS:
            n_daily += 1
        elif month_span(e_1m.first_time, e_1m.last_time) < MIN_1M_MONTHS:
            n_1m += 1
        else:
            passed.append(code)

    return passed, PrefilterStats(
        total=len(by_code), rejected_incomplete=n_incomplete,
        rejected_status=n_status, rejected_daily_span=n_daily,
        rejected_1m_span=n_1m, passed=len(passed))
