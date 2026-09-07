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
    entries.update(_stock("600006.SH", daily_months=10))    # 判据 (b)，第二只——见下方注释
    entries.update(_stock("000001.SZ", m1_months=3))        # 判据 (c)
    entries.update(_stock("301583.SZ", status="empty"))     # 判据 (a)
    entries[("430047.BJ", "1m")] = _entry("430047.BJ", "1m",
                                          first=_start_of_span(13), last=_END)  # 缺 daily
    codes, s = prefilter(entries)
    assert s.total == 6
    assert codes == ["600000.SH"]
    assert (s.passed + s.rejected_incomplete + s.rejected_status
            + s.rejected_daily_span + s.rejected_1m_span) == s.total

    # ⚠️ 四个计数器必须**逐键**断言 —— 全零载荷下把两个键对调也不会红（最终评审
    # F3）：那样这份「关于数据源的第一份真实观测」可以把 468 只报成 1m 判据剔的、
    # 0 只报成日线判据剔的，无人察觉。原样本四个 rejected_* 恰好都是 1（区分不开
    # `rejected_daily_span` 与 `rejected_1m_span`），故上面多加了一只 daily_months=10
    # 的股把 `rejected_daily_span` 顶到 2 —— 把这两个键对调，下面这条断言必须红
    # （已用变异验证，见 final-fix-report.md）。
    assert s.as_manifest_field() == {
        "total": 6, "rejected_incomplete": 1, "rejected_status": 1,
        "rejected_daily_span": 2, "rejected_1m_span": 1, "passed": 1}


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


from qmt_manifest import MARKETS, validate_manifest
from qmt_pool import freeze_universe


def _bootstrap_manifest(universe: dict) -> dict:
    """「刚冻结完宇宙、一只股都还没拷」—— S4 会写出的第一份 manifest。

    形状逐字对着 `qmt_manifest` 的读侧枚举造：`partial` 级的存根必须是
    `passes: []`（O4-F2：首次 fetch 崩在半路时磁盘上就是这个样子）。
    """
    elog = "e" * 64
    return {
        "manifest_version": 1,
        "seed": "s-2026-09-05",
        "source_snapshot": {"export_log_sha256": elog, "universe": universe},
        "source_mount": {"fstype": "smbfs",
                         "device": "//agate@192.168.5.151/QMT_Export",
                         "source_root_relative": "front_ratio_cn_stocks_ab_bj"},
        "pool_order": {mk: [] for mk in MARKETS},
        "cursor": {mk: 0 for mk in MARKETS},
        "files": [],
        "staged_export_log": {"relative_path": "export_log.csv",
                              "bytes": 2399554, "sha256": elog},
        "source_verification": "partial",
        "source_verification_evidence": {"level": "partial", "passes": []},
    }


_SAMPLE = ["600000.SH", "600004.SH", "600006.SH", "600008.SH",
           "000001.SZ", "000002.SZ", "000004.SZ",
           "430047.BJ", "430090.BJ"]


def test_codes_are_split_into_three_layers_by_suffix():
    uni = freeze_universe(_SAMPLE, seed="s1")
    assert set(uni) == set(MARKETS)
    assert sorted(uni["SH"]) == ["600000.SH", "600004.SH", "600006.SH", "600008.SH"]
    assert sorted(uni["SZ"]) == ["000001.SZ", "000002.SZ", "000004.SZ"]
    assert sorted(uni["BJ"]) == ["430047.BJ", "430090.BJ"]


def test_the_same_seed_and_the_same_stocks_give_a_byte_identical_universe():
    assert freeze_universe(_SAMPLE, seed="s1") == freeze_universe(_SAMPLE, seed="s1")


def test_a_different_seed_gives_a_different_order():
    a, b = freeze_universe(_SAMPLE, seed="s1"), freeze_universe(_SAMPLE, seed="s2")
    assert a != b
    assert {mk: sorted(a[mk]) for mk in MARKETS} == {mk: sorted(b[mk]) for mk in MARKETS}


def test_the_universe_does_not_depend_on_the_input_order():
    """`random.shuffle` 的输出取决于入参顺序，而入参来自 dict 的迭代顺序。"""
    assert (freeze_universe(_SAMPLE, seed="s1")
            == freeze_universe(list(reversed(_SAMPLE)), seed="s1")
            == freeze_universe(set(_SAMPLE), seed="s1"))


def test_each_layer_is_shuffled_with_its_own_seed():
    """每层顺序 == `shuffle(该层排序后的成员, Random(f"{seed}:{market}"))` —— 逐字钉死。

    ⚠️ **不要用「改一层、看另一层动没动」去间接推断**：那条判据不可靠（2026-09-06
    修复轮 1 订正，原判据是 `test_changing_one_layer_does_not_disturb_the_others`）。
    实测 `shuffle` 洗 6 个和洗 7 个元素**消耗的随机数次数相同**（都是 7 次
    `getrandbits`），于是共用 rng 时洗完第一层状态没变、后面的层纹丝不动；
    再加上 `MARKETS` 里排第一的那层结构上必然不受影响 —— 两个独立的失效来源。

    本条改为直接断言契约公式。S4 的逐层增量补拉完全建立在
    「同 seed 同成员 → 同顺序，且与其他层无关」之上，这就是那条契约。
    """
    import random as _r

    uni = freeze_universe(_SAMPLE, seed="s1")
    for mk in MARKETS:
        expected = sorted(c for c in _SAMPLE if c.endswith("." + mk))
        _r.Random(f"s1:{mk}").shuffle(expected)
        assert uni[mk] == expected, f"{mk} 层的顺序与 f'seed:市场' 的契约不符"


def test_an_empty_layer_is_legal():
    uni = freeze_universe(["600000.SH"], seed="s1")
    assert uni["SZ"] == [] and uni["BJ"] == []


def test_a_malformed_code_is_refused():
    """冻结名单是补拉游标的**唯一锚点**，坏码必须当场拒。

    `qmt_ingest._norm_code` 对认不出的标识值是原样 `strip()` 返回的，
    一份被污染的 export_log 能把 `"foo"` 送到这里。放过去的话，
    整棵 staging 要到读侧校验才被判死 —— 离病因十万八千里。
    """
    for bad in ("foo", "600000.XX", "600000.SH\n", "", "../etc/passwd"):
        with pytest.raises(QmtSchemaError, match="不合法的股票代码"):
            freeze_universe(["600000.SH", bad], seed="s1")


def test_a_duplicated_code_is_refused():
    """名单里重复 ⇒ 两个 `universe_idx` 指向同一只股，锚点语义当场崩。

    ⚠️ 读侧 `_validate_source_snapshot` **不查层内唯一性**（只查每个元素
    是合法代码且后缀相符）。故这道门只能立在写侧。
    """
    with pytest.raises(QmtSchemaError, match="重复"):
        freeze_universe(["600000.SH", "600000.SH"], seed="s1")


def test_the_frozen_universe_passes_the_read_side_validator():
    """跨模块契约钉：S3 产出的宇宙必须被 S2a 的读侧校验接受。

    「写侧形状与读侧要求不配对」在本仓已经栽过三次（S2-F3 / R94-F2 / O4-F13），
    每次都是「本工具诚实产出的 manifest 被本工具自己判非法」。
    """
    m = _bootstrap_manifest(freeze_universe(_SAMPLE, seed="s1"))
    assert validate_manifest(m) is m          # 原样返回即通过


from qmt_pool import DEFAULT_QUOTA, resolve_quota


def test_the_default_quota_matches_the_spec():
    assert resolve_quota() == {"SH": 120, "SZ": 160, "BJ": 120}


def test_overriding_one_layer_leaves_the_others_at_the_default():
    assert resolve_quota({"BJ": 40}) == {"SH": 120, "SZ": 160, "BJ": 40}


def test_zero_is_a_legal_quota():
    """把某层配额设为 0 = 「这一层一只都不拉」，是合法意图，不是错误。"""
    assert resolve_quota({"BJ": 0})["BJ"] == 0


def test_an_unknown_market_is_refused():
    with pytest.raises(ValueError, match="未知市场"):
        resolve_quota({"HK": 10})


def test_a_non_integer_or_negative_quota_is_refused():
    for bad in (-1, 1.5, "120", True, None):
        with pytest.raises(ValueError, match="非负整数"):
            resolve_quota({"SH": bad})


def test_the_returned_mapping_is_a_copy_of_the_default():
    """调用方改返回值不许污染下一次调用的默认值。"""
    q = resolve_quota()
    q["SH"] = 1
    assert resolve_quota()["SH"] == 120
    assert DEFAULT_QUOTA["SH"] == 120


from qmt_pool import Slot, fresh_slots


def _uni(n_sh: int = 5, n_sz: int = 4, n_bj: int = 3) -> dict:
    """直接造宇宙，绕开 shuffle —— 本 task 测的是区间算术，不是打乱。"""
    return {"SH": [f"60{i:04d}.SH" for i in range(n_sh)],
            "SZ": [f"00{i:04d}.SZ" for i in range(n_sz)],
            "BJ": [f"43{i:04d}.BJ" for i in range(n_bj)]}


def test_a_first_run_takes_the_quota_from_the_head_of_each_layer():
    uni = _uni()
    slots = fresh_slots(uni, {"SH": 0, "SZ": 0, "BJ": 0}, {"SH": 2, "SZ": 1, "BJ": 0})
    assert [(s.market, s.universe_idx) for s in slots] == [
        ("SH", 0), ("SH", 1), ("SZ", 0)]
    assert slots[0] == Slot(code=uni["SH"][0], market="SH", universe_idx=0)


def test_every_slot_anchors_to_the_frozen_universe():
    uni = _uni()
    for s in fresh_slots(uni, {"SH": 0, "SZ": 0, "BJ": 0}, {"SH": 5, "SZ": 4, "BJ": 3}):
        assert uni[s.market][s.universe_idx] == s.code


def test_rerunning_with_the_same_quota_takes_nothing_new():
    """**S3-F3 的正向档**：配额是累计目标，重跑不会再拉一批。

    按「每批数量」实现的话，这里会再拿到 2 个 SH 槽位 ——
    而操作者以为自己只是重跑了一次。
    """
    assert fresh_slots(_uni(), {"SH": 2, "SZ": 1, "BJ": 0},
                       {"SH": 2, "SZ": 1, "BJ": 0}) == []


def test_raising_the_quota_continues_from_the_cursor():
    """**S3-F3 的反向档**：提高配额才拉下一批，且从游标处续、零重复零遗漏。"""
    uni = _uni()
    slots = fresh_slots(uni, {"SH": 2, "SZ": 0, "BJ": 0}, {"SH": 4, "SZ": 0, "BJ": 0})
    assert [s.universe_idx for s in slots] == [2, 3]
    assert all(s.market == "SH" for s in slots)


def test_a_quota_larger_than_the_layer_takes_the_whole_layer():
    """spec §4.4：「配额大于可用数不是错误，取全部即可」。"""
    slots = fresh_slots(_uni(n_sh=3), {"SH": 0, "SZ": 0, "BJ": 0},
                        {"SH": 999, "SZ": 0, "BJ": 0})
    assert [s.universe_idx for s in slots] == [0, 1, 2]


def test_a_quota_lowered_below_the_cursor_takes_nothing_rather_than_going_backwards():
    assert fresh_slots(_uni(), {"SH": 4, "SZ": 0, "BJ": 0},
                       {"SH": 1, "SZ": 0, "BJ": 0}) == []


def test_an_exhausted_layer_is_a_legal_terminal_state():
    """`cursor == len(universe[mk])` 是「池穷尽」这个合法终态，不是错误。"""
    assert fresh_slots(_uni(n_sh=3), {"SH": 3, "SZ": 0, "BJ": 0},
                       {"SH": 120, "SZ": 0, "BJ": 0}) == []


def test_a_negative_cursor_is_refused_rather_than_silently_wrapping():
    """⚠️ Python 的负下标会**静默**取到另一只股。

    `range(-2, 120)` 会产出 `universe[-2]`、`universe[-1]` —— 两个来自层**尾部**
    的股，而 `Slot.universe_idx` 记的是 -2/-1。这不是崩溃，是一份看起来完全
    正常、却指错了股的工作单。
    """
    with pytest.raises(ValueError, match="越界"):
        fresh_slots(_uni(), {"SH": -2, "SZ": 0, "BJ": 0}, {"SH": 3, "SZ": 0, "BJ": 0})


def test_a_cursor_past_the_end_of_the_layer_is_refused():
    with pytest.raises(ValueError, match="越界"):
        fresh_slots(_uni(n_sh=3), {"SH": 4, "SZ": 0, "BJ": 0},
                    {"SH": 3, "SZ": 0, "BJ": 0})


def test_a_negative_quota_is_refused_rather_than_silently_emptying_the_batch():
    """⚠️ 负配额不会崩，只会让 `range(start, 负数)` 变成空批。

    而**空批与「这一层池穷尽了」在外部完全不可区分** —— 操作者读到的是
    「没候选了」，真相是传进来的值坏了。

    ⚠️ 它坏掉只可能是**调用方的 bug**（`quota` 每次现算、不从账本读回），
    故属族②`ValueError`。守它的理由是：本函数是纯内存入口，S4 可能绕过
    `resolve_quota` 直接调 —— 而负配额会让本层静默空跑，
    **空批与「池穷尽」在外部完全不可区分**。
    """
    with pytest.raises(ValueError, match="必须是非负整数"):
        fresh_slots(_uni(), {"SH": 0, "SZ": 0, "BJ": 0},
                    {"SH": -1, "SZ": 0, "BJ": 0})


def test_a_map_missing_a_market_is_refused_rather_than_raising_a_bare_keyerror():
    """缺一层要给出说得清的错，而不是一个来路不明的 KeyError。"""
    with pytest.raises(ValueError, match="缺市场"):
        fresh_slots(_uni(), {"SH": 0, "SZ": 0}, {"SH": 1, "SZ": 0, "BJ": 0})
    with pytest.raises(ValueError, match="缺市场"):
        fresh_slots(_uni(), {"SH": 0, "SZ": 0, "BJ": 0}, {"SH": 1, "BJ": 0})


from qmt_manifest import ManifestInvalidError
from qmt_pool import RETRY_LIMIT, plan_batch, retry_slots


def _fail(uni: dict, mk: str, idx: int, attempts: int) -> dict:
    return {"stock_code": uni[mk][idx], "market": mk,
            "universe_idx": idx, "attempts": attempts,
            "reason": "fetch_missing_file"}


def test_entries_below_the_retry_limit_are_retried():
    uni = _uni()
    got = retry_slots(uni, [_fail(uni, "SH", 1, 0), _fail(uni, "SZ", 0, 1)])
    assert [(s.market, s.universe_idx) for s in got] == [("SH", 1), ("SZ", 0)]


def test_an_entry_at_the_retry_limit_is_not_retried():
    """spec §4.4：`attempts < 2` 才自动重试；仍失败则加一后不再自动重试。"""
    uni = _uni()
    assert RETRY_LIMIT == 2
    assert retry_slots(uni, [_fail(uni, "SH", 1, RETRY_LIMIT)]) == []


def test_a_corrupt_entry_is_refused_even_when_it_would_not_be_retried():
    """⚠️ 校验必须跑遍**每一条**，不能因为「反正不重试」就跳过。

    「断定不是目标」与「判据够不着」混成同一个 `continue`，两者会**互相掩盖**：
    漏站看起来像正常跳过。这条台账读侧从不校验（S2-F64 实测坐实
    `validate_manifest` 的判据里没有 `failures`），本函数是它唯一的门。
    """
    uni = _uni()
    bad = _fail(uni, "SH", 1, RETRY_LIMIT)
    bad["stock_code"] = "not-a-code"
    with pytest.raises(ManifestInvalidError, match="不是合法股票代码"):
        retry_slots(uni, [bad])


def test_a_negative_universe_idx_is_refused_rather_than_wrapping():
    uni = _uni()
    bad = _fail(uni, "SH", 1, 0)
    bad["universe_idx"] = -1
    with pytest.raises(ManifestInvalidError, match="非负整数"):
        retry_slots(uni, [bad])


def test_an_anchor_that_does_not_match_the_frozen_universe_is_refused():
    """锚点对不上 = 这份 manifest 被编辑过，或来自另一次 fetch。"""
    uni = _uni()
    bad = _fail(uni, "SH", 1, 0)
    bad["universe_idx"] = 2               # 指向另一只股
    with pytest.raises(ManifestInvalidError, match="锚点对不上"):
        retry_slots(uni, [bad])


def test_a_market_that_disagrees_with_the_code_suffix_is_refused():
    uni = _uni()
    bad = _fail(uni, "SH", 1, 0)
    bad["market"] = "SZ"
    with pytest.raises(ManifestInvalidError, match="后缀与"):
        retry_slots(uni, [bad])


def test_a_missing_key_is_refused():
    uni = _uni()
    for key in ("stock_code", "market", "universe_idx", "attempts"):
        bad = _fail(uni, "SH", 1, 0)
        del bad[key]
        with pytest.raises(ManifestInvalidError, match=f"缺 {key}"):
            retry_slots(uni, [bad])


def test_plan_batch_puts_retries_before_fresh_slots():
    """spec §4.4：「**先重试** `attempts < 2` 的条目，**再从 `cursor` 继续**」。"""
    uni = _uni()
    got = plan_batch(uni, {"SH": 2, "SZ": 0, "BJ": 0}, {"SH": 4, "SZ": 0, "BJ": 0},
                     failures=[_fail(uni, "SH", 0, 1)])
    assert [s.universe_idx for s in got] == [0, 2, 3]


def test_a_cursor_rolled_back_by_crash_recovery_does_not_duplicate_a_slot():
    """崩溃恢复第③档会把 `cursor` **回退**（spec §4.4，`min(cursor, universe_idx)`）。

    回退之后，一条 `universe_idx` 落进 `[cursor, quota)` 的失败记录会**同时**
    出现在重试项与续新项里。同一只股拷两遍 ⇒ `committed_bytes` 双记击穿
    `--max-bytes`、`attempts` 双增把「一次重试」变成「零次」。

    ⚠️ 这一档**不能靠 S4 的「跳过已成功槽位」兜住** —— 重试项按定义不在
    `pool_order` 里（拷贝失败不进池）。
    """
    uni = _uni(n_sh=6)
    fail = [_fail(uni, "SH", 3, 1)]
    quota = {"SH": 6, "SZ": 0, "BJ": 0}

    before = plan_batch(uni, {"SH": 5, "SZ": 0, "BJ": 0}, quota, failures=fail)
    assert [(s.market, s.universe_idx) for s in before] == [("SH", 3), ("SH", 5)]

    after = plan_batch(uni, {"SH": 2, "SZ": 0, "BJ": 0}, quota, failures=fail)
    shape = [(s.market, s.universe_idx) for s in after]
    assert shape == [("SH", 3), ("SH", 2), ("SH", 4), ("SH", 5)]
    assert len(shape) == len(set(shape)), f"同一槽位被排了两次：{shape}"


def test_a_retry_does_not_consume_quota():
    """重试的槽位早已被 `cursor` 走过；配额记的是「累计尝试到第几个」。

    若重试占配额，一层里失败得越多、能新拉的股越少 —— 而 `cursor` 照样在推进，
    池子会**安静地**缩水，最终报出假的 `pool_exhausted`。

    ⚠️ **入参必须让「被挤掉的那一只」可观测**：`cursor == quota` 时本层
    本来就一只新股都不拉，于是配额有没有被扣**在输出上完全看不出来** ——
    那样这条测试对它自己点名要防的 bug 判别力为零（本条最初就是那样写的）。
    故取 `cursor=2 / quota=4`：正确实现给 3 个槽位（重试 1 + 新 2），
    扣配额的实现只给 2 个，**少掉的那一只正是被重试挤掉的**。

    判据：**配额有没有被扣，必须在输出上看得出来 —— 否则这条档判别力为零。**
    """
    uni = _uni()
    got = plan_batch(uni, {"SH": 2, "SZ": 0, "BJ": 0}, {"SH": 4, "SZ": 0, "BJ": 0},
                     failures=[_fail(uni, "SH", 0, 0)])
    assert [(s.market, s.universe_idx) for s in got] == [("SH", 0), ("SH", 2), ("SH", 3)]


def test_plan_batch_without_failures_equals_fresh_slots():
    uni = _uni()
    cur, quo = {"SH": 0, "SZ": 0, "BJ": 0}, {"SH": 2, "SZ": 1, "BJ": 0}
    assert plan_batch(uni, cur, quo) == fresh_slots(uni, cur, quo)


def test_an_exhausted_candidate_is_not_revived_by_a_cursor_rollback():
    """⚠️⚠️ **复审 N1：第一版去重只堵了一半的洞**（控制者自己写出来的）。

    第一版的 `seen` 是从 `retry_slots()` 的返回值建的，而那个返回值**已经被
    `attempts < RETRY_LIMIT` 过滤过**。于是一条**已耗尽重试**（`attempts == 2`）
    的失败记录不会进 `seen` —— 游标一旦被崩溃恢复第③档回退到它前面，
    它就原样出现在**续新段**里，等于**复活了一次本不该再有的尝试**。
    spec 把「复活一个已耗尽重试的候选」判为 **high**（S2-F25 / S2-F34）。

    判据：**一条失败记录所在的槽位，按定义就不是「新槽位」** —— 无论它还能不能重试。
    """
    uni = _uni(n_sh=6)
    quota = {"SH": 6, "SZ": 0, "BJ": 0}
    exhausted = [_fail(uni, "SH", 3, RETRY_LIMIT)]      # 已耗尽，不该再被尝试

    # 游标在它后面：本来就取不到它
    assert [(s.market, s.universe_idx) for s in
            plan_batch(uni, {"SH": 5, "SZ": 0, "BJ": 0}, quota, failures=exhausted)] \
        == [("SH", 5)]

    # 游标回退到它**前面**：它必须仍然不出现（第一版这里会冒出 ('SH', 3)）
    for rolled_back in (3, 2, 0):
        shape = [(s.market, s.universe_idx) for s in
                 plan_batch(uni, {"SH": rolled_back, "SZ": 0, "BJ": 0},
                            quota, failures=exhausted)]
        assert ("SH", 3) not in shape, f"cursor={rolled_back} 时已耗尽的候选被复活：{shape}"

    # 对照：还能重试的（attempts=1）**必须**出现，且排在最前 —— 别把门修过头
    retryable = [_fail(uni, "SH", 3, RETRY_LIMIT - 1)]
    shape = [(s.market, s.universe_idx) for s in
             plan_batch(uni, {"SH": 2, "SZ": 0, "BJ": 0}, quota, failures=retryable)]
    assert shape[0] == ("SH", 3) and shape.count(("SH", 3)) == 1, shape


# ── 最终评审 F5/F6/F7/F8：补上零覆盖的守卫 ───────────────────────
# 最终评审逐条变异实测，发现下面这些守卫**删掉之后 51 条测试全绿** ——
# 行为今天是对的，明天没人守。三点要害：
#   ① `resolve_quota` 有完整坏值表，而 `fresh_slots` 里**一模一样**的判据
#      一个坏值都没测 —— 判据复制过来了，测试表没复制；
#   ② `attempts` 那条正是 S2-F64 整条在讲的洞（缺席/坏型能复活一个已耗尽重试的
#      候选），守卫写对了却没有任何测试钉住它，而隔壁 `universe_idx` 有专属档；
#   ③ `retry_slots` 换用 `qmt_normalize` 那份宽松正则（`$`，容忍尾随换行）**不红**
#      —— 直接架空 Task 4「写侧读侧用同一个正则对象」的全部意义。


@pytest.mark.parametrize("bad", [-1, 1.5, "2", True, None])
def test_fresh_slots_refuses_a_malformed_cursor(bad):
    """与 `resolve_quota` 那张坏值表**同规格**：判据复制过来了，测试表也必须复制。"""
    with pytest.raises(ValueError):
        fresh_slots(_uni(), {"SH": bad, "SZ": 0, "BJ": 0}, {"SH": 1, "SZ": 0, "BJ": 0})


@pytest.mark.parametrize("bad", [-1, 1.5, "2", True, None])
def test_fresh_slots_refuses_a_malformed_quota(bad):
    """⚠️ `True` 那一档：`isinstance(True, int)` 是 True，不显式排除 bool 会被当成 1。"""
    with pytest.raises(ValueError):
        fresh_slots(_uni(), {"SH": 0, "SZ": 0, "BJ": 0}, {"SH": bad, "SZ": 0, "BJ": 0})


@pytest.mark.parametrize("field,bad", [
    ("stock_code", None), ("stock_code", 600000), ("stock_code", "600000.SH\n"),
    ("market", "HK"), ("market", 1), ("market", None),
    ("universe_idx", "1"), ("universe_idx", 1.0), ("universe_idx", True),
    ("universe_idx", 99), ("universe_idx", -1),
    ("attempts", "1"), ("attempts", 1.5), ("attempts", True), ("attempts", -1),
])
def test_retry_slots_refuses_a_malformed_failure_entry(field, bad):
    """`failures` 是账本的**非必需字段**，读侧一个字都不校验 —— 本函数是它唯一的门。

    ⚠️⚠️ **`("stock_code", "600000.SH\\n")` 这一档钉不住正则的宽严 —— 如实登记，
    不要误以为它钉住了**（最终评审 F5 第 10 组，控制者变异实测）：
    严格版（`\\Z`）与宽松版（`$`）**唯一**不同的输入类是 `<合法码>\\n`，
    而本函数在正则之后还有一道 `code.endswith("." + market)` ——
    `"600000.SH\\n".endswith(".SH")` 是 `False`，**后缀检查结构上抢先拦住了它**。
    所以在 `retry_slots` 里换用宽松正则是一个**等价变异**（换了不红，不是覆盖缺口）。
    正则的宽严在 `freeze_universe` 里**才**可观测（那里正则之后直接按后缀分层，
    `"SH\\n"` 会 KeyError），已由 `test_a_malformed_code_is_refused` 钉住。
    这一档保留的价值是「这个输入必须被拒」这件事本身，**不是**"它证明了用哪个正则"。

    ⚠️ `attempts` 的四档专钉 S2-F64：一条 `attempts` 缺席/坏型的记录，
    能让一个**已耗尽重试**的候选被复活。
    """
    uni = _uni()
    rec = _fail(uni, "SH", 1, 0)
    rec[field] = bad
    with pytest.raises(ManifestInvalidError):
        retry_slots(uni, [rec])


def test_retry_slots_refuses_a_non_object_entry():
    """一条不是对象的记录要给出说得清的错，而不是在取键时炸出 TypeError。"""
    with pytest.raises(ManifestInvalidError, match="必须是对象"):
        retry_slots(_uni(), ["not-a-dict"])


@pytest.mark.parametrize("bad", [None, 5, "failures", {"SH": []}])
def test_retry_slots_refuses_a_non_list_ledger(bad):
    """容器本身的门（F6）：S4 读账本必然写 `manifest.get("failures", [])`，
    账本里一个 `"failures": null` 就走到这里 —— 必须是 `ManifestInvalidError`，
    不是裸 `TypeError`（后者一句恢复指引都印不出来）。"""
    with pytest.raises(ManifestInvalidError, match="必须是列表"):
        retry_slots(_uni(), bad)


@pytest.mark.parametrize("consumer", ["fresh_slots", "retry_slots"])
@pytest.mark.parametrize("bad_universe", [
    {"SH": [], "SZ": []},                      # 缺一层
    {"SH": [], "SZ": [], "BJ": [], "HK": []},  # 多一层
    {"SH": None, "SZ": [], "BJ": []},          # 某层不是列表
    "not-a-dict",
])
def test_both_consumers_refuse_a_malformed_universe(consumer, bad_universe):
    """冻结名单是**全部**锚点的来源（F7）。

    给 `cursor` 立守卫的理由（「本函数是纯内存入口，S4 可能绕过直接调」）
    对 `universe` **一字不差地成立**，而它此前一道门都没有：
    缺一层 → 裸 `KeyError`；某层是 None → `TypeError: ... has no len()`。
    """
    zero = {"SH": 0, "SZ": 0, "BJ": 0}
    with pytest.raises(ValueError):
        if consumer == "fresh_slots":
            fresh_slots(bad_universe, zero, {"SH": 1, "SZ": 0, "BJ": 0})
        else:
            retry_slots(bad_universe, [])


@pytest.mark.parametrize("bad", [None, "", 123, b"s1"])
def test_freeze_universe_refuses_a_malformed_seed(bad):
    """`seed` 是全部可复现性的锚点，却曾是唯一没被校验的入参（F8）。

    `f"{seed}:{market}"` 会把**任何东西**字符串化 —— 加门之前 `seed=None`
    与 `seed="None"` 冻出的名单**逐字相同**，`seed=""` 也照收。
    而读侧 `qmt_manifest` 要求 `seed` 是非空字符串：**写侧不能比读侧松**。
    """
    with pytest.raises(ValueError, match="非空文字"):
        freeze_universe(["600000.SH"], seed=bad)


def test_prefilter_checks_both_periods_status_not_just_one():
    """status 门必须**两个周期都看** —— 只看一个的话，另一个周期坏掉的股会溜过去，
    而它的时间戳是 `None`，下游算月数时才炸（且炸在离病因很远的地方）。"""
    for bad_period in ("1m", "daily"):
        entries = _stock("600000.SH")
        entries[("600000.SH", bad_period)] = _entry(
            "600000.SH", bad_period, status="empty", rows=0)
        codes, stats = prefilter(entries)
        assert codes == [] and stats.rejected_status == 1, f"{bad_period} 坏掉时没被拦住"


def test_prefilter_checks_both_periods_present_not_just_one():
    """「两个周期缺一不可」也必须**两边都查** —— 只查 daily 的话，缺 1m 的股会溜到
    status 门，而 `per.get("1m")` 是 None，取 `.status` 当场炸。"""
    for present in ("1m", "daily"):
        code = "600000.SH"
        full = _stock(code)
        entries = {(code, present): full[(code, present)]}
        codes, stats = prefilter(entries)
        assert codes == [] and stats.rejected_incomplete == 1, f"只有 {present} 时没被拦住"
