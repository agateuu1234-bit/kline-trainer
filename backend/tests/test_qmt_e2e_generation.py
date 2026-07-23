# backend/tests/test_qmt_e2e_generation.py
# QMT Plan 3 Task 9：L1 端到端集成测（CI 内，假件存储，无真 PG）。
#
# 证明的是**跨模块拼接**：B1 新导入路径 `build_stock_import` 产出的 bundle，
# 真能喂给 B2 真实 `generate_batch` 产出一个真实训练组 zip——「假」的只有
# asyncpg conn（复用 test_b2_reconnect_integration.py 的 `_FakeConn`，把它当
# klines/stock_coverage/training_sets 存储用），generate_batch →
# generate_one_training_set → build_training_windows → assemble_from_windows →
# 真 SQLite → 真 zip → 真 CRC32 全链路是未改动的生产代码。
from __future__ import annotations

import asyncio
import json
import random

import pandas as pd
import pytest

from generate_training_sets import PERIODS, crc32_hex, generate_batch
from qmt_ingest import build_stock_import

from tests._qmt_fixtures import gen_valid_sources
from tests.test_b2_reconnect_integration import _FakeConn

_CODE = "000001.SZ"


@pytest.fixture(scope="module")
def bundle():
    """真 B1 装配（含门5 出货可行性预检，耗时几秒）——整模块只建一次。"""
    s1, sd, e1, ed = gen_valid_sources(_CODE)
    return build_stock_import(s1, sd, stock_code=_CODE, stock_name="平安",
                              entry_1m=e1, entry_daily=ed)


def _bundle_conn(bundle) -> _FakeConn:
    """把真 bundle 灌进沿用的 `_FakeConn`：klines 存储 = bundle.records（按周期转
    DataFrame、按 datetime 排序，对齐 `_fetch_period_bars` 的 `ORDER BY datetime`）；
    stock_coverage 存储 = bundle.coverage 转成 `_fetch_dense_coverage` 期望的行形状
    （dropped_1m_dates 是 JSONB → 存 ISO 日期字符串数组的 json.dumps，与
    write_qmt_stock 写入的格式一致）。"""
    bars = {p: pd.DataFrame(bundle.records[p]).sort_values("datetime").reset_index(drop=True)
            for p in PERIODS}
    cov = bundle.coverage
    coverage_row = {
        "dense_1m_start_date": cov.start_date,
        "dense_1m_end_date": cov.end_date,
        "dropped_1m_dates": json.dumps([d.isoformat() for d in cov.dropped_dates]),
        "dense_day_count": cov.dense_day_count,
    }
    return _FakeConn(_CODE, bars, coverage_row)


def test_real_bundle_drives_real_generate_batch_to_zip(bundle, tmp_path):
    """核心断言：真 bundle → 真 generate_batch → 磁盘上确有 ≥1 个真 zip，
    且假 training_sets 登记行的 content_hash 与该 zip 字节的 CRC32 完全一致。"""
    conn = _bundle_conn(bundle)

    out = asyncio.run(generate_batch(conn, 1, tmp_path, random.Random(0)))

    assert len(out) >= 1, "generate_batch 未从真 bundle 产出任何训练组"

    zips = sorted(tmp_path.glob("*.zip"))
    assert len(zips) >= 1, "输出目录里没有任何 .zip 文件"

    assert len(conn.registered) >= 1, "假 training_sets 存储里没有任何登记行"
    row = conn.registered[0]

    zip_bytes = zips[0].read_bytes()
    assert row["content_hash"] == crc32_hex(zip_bytes), (
        "登记的 content_hash 与磁盘上 zip 字节的真实 CRC32 不一致")
