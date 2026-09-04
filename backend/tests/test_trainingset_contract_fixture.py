# backend/tests/test_trainingset_contract_fixture.py
"""跨端接缝的**生产者半边**（spec §4.1）。

三方钉在同一件产物上：
  ① 手写期望值（本文件里的字面量，独立人工推算）
  ② 已提交 fixture（tests/contract-fixtures/training-set/*.zip）
  ③ 现场重建的生成器输出（每次 CI 现产一份）
①↔② 与 ①↔③ 由「生产者半边断言」钉住，②↔③ 由「漂移闸」钉住。
切片二把 App 侧读取链路接到 ② 上，spec §1.4 那道缝才算闭合 —— **本片不做那一半**。
"""
from __future__ import annotations

import datetime as _dt
from zoneinfo import ZoneInfo

import pytest

from generate_training_sets import PERIODS
from tests._trainingset_contract_fixture import (
    END_DATETIME,
    FIXTURE_DB_NAME,
    FIXTURE_ZIP,
    FIXTURE_ZIP_NAME,
    RAW_DATETIMES,
    START_DATETIME,
    build_fixture,
    build_windows,
)

_SH = ZoneInfo("Asia/Shanghai")


def _ep(y, m, d, H=0, M=0, S=0):
    """测试内**独立**实现的 Asia/Shanghai 秒（⛔ 不复用被测模块的辅助函数）。"""
    return int(_dt.datetime(y, m, d, H, M, S, tzinfo=_SH).timestamp())


# ── Task 1：身份常量与三类特征的前提

def test_fixture_identity_constants_are_pinned():
    """文件名进跨端契约（切片二要按这个名字找它）⇒ 常量必须钉住字面量。

    ⚠️ 这里刻意写死数字而不是「再算一遍」：再算一遍等于把两边接到同一个公式上，
    公式错了两边一起错（同 spec 变异 B18 要防的机制）。
    """
    assert START_DATETIME == 1774972800      # 2026-04-01 00:00:00 +08:00
    assert END_DATETIME == 1775059199        # 2026-04-01 23:59:59 +08:00
    assert FIXTURE_ZIP_NAME == "999002.SZ_1774972800.zip"
    assert FIXTURE_DB_NAME == "999002.SZ_1774972800.db"


def test_start_datetime_is_midweek_wednesday():
    """特征③的前提：起点必须落在**周中** —— 落周一就没有跨界周可删了。"""
    got = _dt.datetime.fromtimestamp(START_DATETIME, _SH)
    assert (got.year, got.month, got.day) == (2026, 4, 1)
    assert got.strftime("%a") == "Wed"


def test_windows_carry_the_three_required_features():
    """spec §4.1 note 2 的**特征②③**必须真的在窗口里（而不是只写在注释里）。

    ⚪ 特征①（≥2 根落在 `end_global_index = 0`）在**窗口层面看不出来** —— 它是赋索引之后
       才成立的性质，由 Task 2 的 `monthly` 期望值 `[0, 0, 17, 23]` 断言。
    """
    w = build_windows()

    # 特征③：2026-03-30 那根周线在原始数据里有、在窗口里没有 ⇒ 被生产切窗删掉了
    weekly = [int(x) for x in w["weekly"]["datetime"]]
    assert _ep(2026, 3, 30) in RAW_DATETIMES["weekly"], "原始 weekly 里必须先有那根，否则删无可删"
    assert _ep(2026, 3, 30) not in weekly, "跨界周没被删 ⇒ 特征③是假的"
    assert weekly == [_ep(2026, 3, 16), _ep(2026, 3, 23)]

    # 特征②：3m 轴上必须同时存在跨午休缺口与跨日缺口
    axis = [int(x) for x in w["3m"]["datetime"]]
    assert len(axis) == 24
    assert axis[3] == _ep(2026, 3, 27, 11, 30), "轴上第 4 根应是上午收盘"
    assert axis[4] == _ep(2026, 3, 27, 14, 57), "紧邻的下一根应跨过午休"
    assert axis[5] == _ep(2026, 3, 27, 15, 0), "轴上第 6 根应是当日收盘"
    assert axis[6] == _ep(2026, 3, 30, 9, 33), "紧邻的下一根应跨到下一个交易日"

    # 各周期窗口根数（特征①的具体期望值在下一条用例里断言）
    assert {p: len(w[p]) for p in PERIODS} == {
        "monthly": 4, "weekly": 2, "daily": 5, "60m": 4, "15m": 8, "3m": 24}


def test_build_windows_goes_through_production_select_period_window(monkeypatch):
    """⛔ 窗口必须由**生产**切窗函数切出来，不得手工挑根。

    判据 = monkeypatch 掉 `_trainingset_contract_fixture` 里绑定的那个名字后，
    `build_windows()` 必须对**每个周期各调用一次**。
    若哪天有人把 `build_windows` 改成「自己挑几根塞进去」（**哪怕挑出来的结果与今天逐根相同**），
    spy 不会被调用 ⇒ 本测试红 —— 而上面那条只比较窗口内容的用例**抓不住这种改法**。
    ⭐ 本仓已有同款守卫：`test_generate_training_sets.py::test_week_end_date_is_module_level_and_shared`。
    ⚠️ 必须 patch **本 fixture 模块里绑定的那个名字**（`from ... import select_period_window`
       是模块级绑定）；patch `generate_training_sets` 那边的名字对本调用点无效，会得到一条恒绿的空测试。
    """
    import tests._trainingset_contract_fixture as fx

    calls: list[str] = []
    real = fx.select_period_window

    def spy(bars, start_datetime, before_cap, after_end, period, month_boundaries=None):
        calls.append(period)
        return real(bars, start_datetime, before_cap, after_end, period, month_boundaries)

    monkeypatch.setattr(fx, "select_period_window", spy)
    fx.build_windows()
    assert sorted(calls) == sorted(PERIODS), (
        f"build_windows 没有对每个周期各调一次生产切窗函数（实测 {calls}）"
        f"—— 说明它绕过了 select_period_window，特征③就成了手工摆出来的假象")
