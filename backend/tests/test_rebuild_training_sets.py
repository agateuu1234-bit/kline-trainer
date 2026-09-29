# backend/tests/test_rebuild_training_sets.py
# 切片一 P4 片 1：重建入口的常驻测试。
# 「假」的只有 asyncpg conn（沿用 _FakeConn）；bundle 是真 build_stock_import 产的，
# 窗口 / 索引 / SQLite / zip / CRC32 全链路是未改动的生产代码。
from __future__ import annotations

import json
import random
import sys
from pathlib import Path

import pandas as pd
import pytest

import generate_training_sets as g
import rebuild_training_sets as r
from qmt_ingest import build_stock_import
from tests._qmt_fixtures import gen_valid_sources
from tests.test_b2_reconnect_integration import _FakeConn

_CODE = "000001.SZ"


@pytest.fixture(scope="module")
def bundle():
    s1, sd, e1, ed = gen_valid_sources(_CODE)
    return build_stock_import(s1, sd, stock_code=_CODE, stock_name="平安",
                              entry_1m=e1, entry_daily=ed)


def _conn(bundle) -> _FakeConn:
    bars = {p: pd.DataFrame(bundle.records[p]).sort_values("datetime").reset_index(drop=True)
            for p in g.PERIODS}
    cov = bundle.coverage
    return _FakeConn(_CODE, bars, {
        "dense_1m_start_date": cov.start_date,
        "dense_1m_end_date": cov.end_date,
        "dropped_1m_dates": json.dumps([d.isoformat() for d in cov.dropped_dates]),
        "dense_day_count": cov.dense_day_count,
    })


def _gating(bundle):
    import asyncio
    return asyncio.run(g.load_gating_inputs(_conn(bundle), _CODE))


def _eligible_starts(gi) -> list[int]:
    """当前 bundle 下【所有】合格候选起点（不钉死时 build_training_windows 会从中选）。"""
    idxs = g.eligible_start_indices(gi.month_boundaries, random.Random(0),
                                    dense_dates=gi.dense_dates,
                                    trading_dates=gi.trading_dates,
                                    dropped=gi.dropped)
    return sorted(int(gi.month_boundaries[i]) for i in idxs)


def test_unpinned_start_is_not_stable_across_seeds(bundle):
    """**先证明这件事真的会发生**：不钉死时，不同种子选到的起点不一样。

    ⭐ 没有这条对照，下一条「钉死后恒定」可能只是因为本 fixture 恰好只有一个候选
    —— 那样它判别力为零、却一直是绿的。
    """
    gi = _gating(bundle)
    assert len(_eligible_starts(gi)) >= 2, (
        "本 fixture 只有不到 2 个合格候选起点 ⇒ 『钉死起点』这条判据无从验证。"
        " ⛔ 不要放宽本断言，请改用能产出多候选的 fixture。")

    picked = set()
    for seed in range(8):
        start, _ = g.build_training_windows(
            gi.period_bars, gi.month_boundaries, random.Random(seed),
            dense_dates=gi.dense_dates, trading_dates=gi.trading_dates,
            before_caps=g.PERIOD_BEFORE_CAP, dropped=gi.dropped)
        picked.add(int(start))
    assert len(picked) >= 2, (
        f"8 个不同种子只选出了 {picked} 一个起点 —— 与 rng.shuffle 的存在矛盾，"
        " 请查清楚再继续")


def test_pinned_start_is_identical_across_seeds(bundle):
    """钉死之后：无论什么种子，返回的起点恒等于目标。"""
    gi = _gating(bundle)
    target = _eligible_starts(gi)[0]
    for seed in range(8):
        start, windows = r.build_pinned_windows(
            gi.period_bars, gi.month_boundaries, start_datetime=target,
            dense_dates=gi.dense_dates, trading_dates=gi.trading_dates,
            dropped=gi.dropped, rng=random.Random(seed))
        assert int(start) == target
        assert set(windows) == set(g.PERIODS)


def test_pinned_start_not_a_month_boundary_is_refused(bundle):
    """起点不是月边界 ⇒ 当场拒绝，⛔ 不得悄悄退回随机选。"""
    gi = _gating(bundle)
    with pytest.raises(r.RebuildMismatch) as ei:
        r.pin_start_excludes(gi.month_boundaries, 12345)
    assert "12345" in str(ei.value)


def test_pinned_start_that_fails_gates_is_refused(bundle):
    """起点是月边界、但过不了 D6 / D9 两道门 ⇒ 抛 RebuildMismatch，
    ⛔ 不得退回去选别的起点（那会静默产出一个不同的训练组）。"""
    gi = _gating(bundle)
    eligible = set(_eligible_starts(gi))
    bad = next((int(b) for b in gi.month_boundaries if int(b) not in eligible), None)
    assert bad is not None, "本 fixture 里每个月边界都是合格候选 ⇒ 本用例无从验证"
    with pytest.raises(r.RebuildMismatch):
        r.build_pinned_windows(
            gi.period_bars, gi.month_boundaries, start_datetime=bad,
            dense_dates=gi.dense_dates, trading_dates=gi.trading_dates,
            dropped=gi.dropped, rng=random.Random(0))


def _target_for(bundle, *, expected_end: int | None = None) -> r.RebuildTarget:
    """拿本 fixture 的第一个合格起点造一个 RebuildTarget（右端由真实现现算）。"""
    import asyncio
    gi = _gating(bundle)
    start = _eligible_starts(gi)[0]
    idx = [int(b) for b in gi.month_boundaries].index(start)
    real_end = g.compute_after_end(gi.month_boundaries, idx)
    return r.RebuildTarget(_CODE, start, real_end if expected_end is None else expected_end)


def test_rebuild_one_produces_a_real_zip_with_schema_version_2(bundle, tmp_path):
    import asyncio
    target = _target_for(bundle)
    gts = asyncio.run(r.rebuild_one(_conn(bundle), target, tmp_path))

    assert gts.start_datetime == target.start_datetime
    assert gts.end_datetime == target.expected_end_datetime
    assert gts.schema_version == g.SCHEMA_VERSION
    assert gts.stock_name == g._stock_name_of(_CODE)

    zip_path = tmp_path / f"{_CODE}_{target.start_datetime}.zip"
    assert zip_path.exists(), f"没产出 {zip_path.name}"
    assert gts.content_hash == g.crc32_hex(zip_path.read_bytes()), (
        "登记的 content_hash 与磁盘上 zip 字节的真实 CRC32 不一致")


def test_rebuild_one_refuses_when_end_datetime_differs_from_authority(bundle, tmp_path):
    """右端与权威值不符 ⇒ 抛 RebuildMismatch，且错误信息里**两个值都要有**
    （只说『对不上』的话，操作者不知道该去查哪一边）。"""
    import asyncio
    target = _target_for(bundle, expected_end=1)
    with pytest.raises(r.RebuildMismatch) as ei:
        asyncio.run(r.rebuild_one(_conn(bundle), target, tmp_path))
    msg = str(ei.value)
    real_end = _target_for(bundle).expected_end_datetime
    assert f"算出的 end_datetime = {real_end}" in msg, f"消息里没有『算出来的值』：{msg}"
    assert f"权威值是 {target.expected_end_datetime}" in msg, f"消息里没有『权威值』：{msg}"
    assert not list(tmp_path.glob("*.zip")), (
        "右端断言失败时不应该已经把 zip 写到盘上 —— 断言必须排在装配之前")
