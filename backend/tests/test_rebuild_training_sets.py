# backend/tests/test_rebuild_training_sets.py
# 切片一 P4 片 1：重建入口的常驻测试。
# 「假」的只有 asyncpg conn（沿用 _FakeConn）；bundle 是真 build_stock_import 产的，
# 窗口 / 索引 / SQLite / zip / CRC32 全链路是未改动的生产代码。
from __future__ import annotations

import json
import random
import re
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
    # (?!\d)：数字边界——防止子串包含把 "权威值是 1" 误判成命中了 "权威值是 1690819199"
    # （子串是前缀关系，纯 `in` 判断分不清「独立数字 1」与「以 1 开头的别的数字」）。
    assert re.search(rf"算出的 end_datetime = {real_end}(?!\d)", msg), (
        f"消息里没有『算出来的值』（须是独立数字，不能只是某数字的前缀）：{msg}")
    assert re.search(rf"权威值是 {target.expected_end_datetime}(?!\d)", msg), (
        f"消息里没有『权威值』（须是独立数字，不能只是某数字的前缀）：{msg}")
    assert not list(tmp_path.glob("*.zip")), (
        "右端断言失败时不应该已经把 zip 写到盘上 —— 断言必须排在装配之前")


def test_write_detector_reports_nonzero_on_a_planted_write():
    """⭐ 先证明这个检测器**能报出非 0**，再让它去报 0。

    ⭐ 后三条是**按首词判**会漏掉的（codex 评审第 4 轮实测复现）：
    前两条首词分别是 `WITH` / `SELECT`，第三条根本解析不了。
    """
    for bad in ["INSERT INTO training_sets(stock_code, schema_version) VALUES ('X', 1)",
                "UPDATE training_sets SET schema_version = 1",
                "DELETE FROM klines",
                "CREATE TABLE t(x int)",
                "ALTER TABLE klines ADD COLUMN x int",
                "TRUNCATE training_sets",
                "DROP TABLE klines",
                "WITH changed AS (UPDATE training_sets SET schema_version = 1"
                " RETURNING id) SELECT count(*) FROM changed",
                "SELECT 1; UPDATE training_sets SET schema_version = 1",
                "SELECT FROM WHERE ((("]:
        with pytest.raises(r.RebuildMismatch) as ei:
            r.assert_no_write_statements(["SELECT 1", bad])
        assert bad[:40] in str(ei.value), "错误信息里没点名是哪一条"


def test_write_detector_passes_on_reads_only():
    """⭐ 正向对照：本片真正会发出的那几条，一条都不许误报。"""
    r.assert_no_write_statements([
        "SELECT period, datetime FROM klines WHERE stock_code=$1 AND period=$2"
        " ORDER BY datetime",
        "SELECT dense_1m_start_date FROM stock_coverage WHERE stock_code=$1",
        "SELECT count(*) FROM training_sets",
        "SELECT max(id) FROM training_sets",
    ])


def test_connect_read_only_refuses_a_session_that_is_not_read_only(monkeypatch):
    """⛔ 连上了但会话不是只读 ⇒ 拒绝并把连接关掉。

    ⭐ 这条自证**有判别力**，不是恒返回 `on`：一次性 PG 上实测过对照 ——
    只读连接返回 `'on'`、普通连接返回 `'off'`。
    """
    import asyncio
    import types
    closed = {"n": 0}

    class _Conn:
        async def fetchval(self, q):
            return "off"

        async def close(self):
            closed["n"] += 1

    async def _connect(dsn, **kw):
        assert kw.get("server_settings", {}).get(
            "default_transaction_read_only") == "on", "连接时没有要求数据库进入只读"
        return _Conn()

    monkeypatch.setitem(sys.modules, "asyncpg", types.SimpleNamespace(connect=_connect))
    with pytest.raises(r.RebuildMismatch):
        asyncio.run(r.connect_read_only("postgresql://x/y"))
    assert closed["n"] == 1, "拒绝时没有把连接关掉"


def test_connect_read_only_accepts_a_read_only_session(monkeypatch):
    """⭐ 正向对照：⛔ 没有它，一个**恒抛**的 connect_read_only 也能让上一条绿。"""
    import asyncio
    import types

    class _Conn:
        async def fetchval(self, q):
            return "on"

        async def close(self):
            raise AssertionError("不该关掉一个合法的只读连接")

    async def _connect(dsn, **kw):
        return _Conn()

    monkeypatch.setitem(sys.modules, "asyncpg", types.SimpleNamespace(connect=_connect))
    got = asyncio.run(r.connect_read_only("postgresql://x/y"))
    assert isinstance(got, _Conn)


def test_rebuild_one_issues_no_write_statements(bundle, tmp_path):
    """真跑一次重建，断言发出去的每一条 SQL 都是读。"""
    import asyncio
    conn = r.ReadOnlyConn(_conn(bundle))
    target = _target_for(bundle)
    asyncio.run(r.rebuild_one(conn, target, tmp_path))

    assert conn.statements, "一条 SQL 都没记到 ⇒ 这个判据是空转的，⛔ 不算通过"
    r.assert_no_write_statements(conn.statements)
    assert conn.inner.registered == [], (
        "假 training_sets 存储里出现了登记行 —— 重建路径调到了 _register_training_set")


_P11 = "docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql"


def _repo_root():
    import pathlib
    return pathlib.Path(__file__).resolve().parents[2]


def test_two_runs_are_byte_identical(bundle, tmp_path):
    """同一输入连跑两次 ⇒ zip 字节与 CRC32 完全相同。
    这是『随时可以重来』这条恢复前提的唯一依据。"""
    import asyncio
    target = _target_for(bundle)
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(); b.mkdir()
    g1 = asyncio.run(r.rebuild_one(_conn(bundle), target, a))
    g2 = asyncio.run(r.rebuild_one(_conn(bundle), target, b))
    assert g1.content_hash == g2.content_hash
    r.assert_byte_identical(a, b)


def test_manifest_row_is_the_seven_tuple(bundle, tmp_path):
    import asyncio
    target = _target_for(bundle)
    gts = asyncio.run(r.rebuild_one(_conn(bundle), target, tmp_path))
    row = r.manifest_row(gts)
    assert set(row) == {"stock_code", "stock_name", "start_datetime", "end_datetime",
                        "schema_version", "file_path", "content_hash"}
    assert row["schema_version"] == g.SCHEMA_VERSION
    assert row["file_path"] == f"/data/training-sets/{_CODE}_{target.start_datetime}.zip"


def test_legacy_rows_are_parsed_from_the_real_sql_by_a_real_parser():
    """旧七元组由 **pglast**（真 PostgreSQL 解析器）从 p11 SQL 解析出来，
    ⛔ 不是人手抄的字面量 —— 手抄的边界就是抄写者的想象力。"""
    rows = r.read_legacy_rows(_repo_root() / _P11)
    assert len(rows) == 3, f"p11_expected 里应有 3 行，解析出 {len(rows)} 行"
    assert {x["content_hash"] for x in rows} == {"851f9444", "32892a5f", "150d8d6c"}
    assert {x["schema_version"] for x in rows} == {1}, (
        "库存三行仍应是第 1 代 —— 若这里变成 2，说明 P11 已被重新生成过，"
        "⛔ 旧值已经没有落脚点了，停下来查清楚")


def test_read_legacy_rows_refuses_a_regenerated_p11(tmp_path):
    """片 2 把 P11 整份重新生成之后，⛔ 不得再从它取旧身份。

    ⭐ 这条是 codex 评审第 1 轮 finding 2 逼出来的：实测证明，不加这道闸时
    `read_legacy_rows` 会把**新**七元组原样当成「旧值」返回，而调用方看不出任何异常。
    """
    src = (_repo_root() / _P11).read_text(encoding="utf-8")
    fake = (src.replace("851f9444", "aaaa1111")
               .replace("32892a5f", "bbbb2222")
               .replace("150d8d6c", "cccc3333")
               .replace("1756656000, 1777996799, 1,", "1756656000, 1777996799, 2,")
               .replace("1762099200, 1782835199, 1,", "1762099200, 1782835199, 2,"))
    assert fake != src and "aaaa1111" in fake, "变异体没造出来 —— 替换锚点漂了，停下来查"
    q = tmp_path / "p11-regenerated.sql"
    q.write_text(fake, encoding="utf-8")
    with pytest.raises(r.RebuildMismatch) as ei:
        r.read_legacy_rows(q)
    assert "已经被重新生成过" in str(ei.value)


#: 每一项 = (怎么改坏, **期望命中的那条规则的原话片段**)。
#: ⭐ 钉住「红的理由」而不只是「红了」—— 本仓记过：一个被**别的**规则抢先拒掉的用例
#: 看起来是绿的（测试通过），实际上它要验的那条规则**一次都没执行过**。
#: 实测过：早先那版「目标对不上」被 file_path 规则抢先拒、「行数是 4」被指纹重复规则抢先拒。
_HOLES = {
    "缺 content_hash（P11b 身份闸的输入）":
        (lambda rows: [r.pop("content_hash") for r in rows], "字段集合不对"),
    "缺 file_path": (lambda rows: [r.pop("file_path") for r in rows], "字段集合不对"),
    "缺 stock_name": (lambda rows: [r.pop("stock_name") for r in rows], "字段集合不对"),
    "缺 stock_code": (lambda rows: [r.pop("stock_code") for r in rows], "字段集合不对"),
    "多出一个字段": (lambda rows: [r.__setitem__("extra", 1) for r in rows], "字段集合不对"),
    "content_hash 是空串":
        (lambda rows: rows[0].__setitem__("content_hash", ""), "不是非空字符串"),
    "指纹是大写":
        (lambda rows: rows[0].__setitem__("content_hash", "AAAA1111"), "不是 8 位小写十六进制"),
    "三行共用同一个【小写】指纹":
        (lambda rows: [r.__setitem__("content_hash", "deadbeef") for r in rows],
         "个不同的 content_hash"),
    "两行指纹相撞":
        (lambda rows: rows[0].__setitem__("content_hash", rows[1]["content_hash"]),
         "个不同的 content_hash"),
    "file_path 与自己的身份不符":
        (lambda rows: rows[0].__setitem__("file_path", "/data/training-sets/WRONG.zip"),
         "与它自己的身份对不上"),
    "stock_name 与 stock_code 不同":
        (lambda rows: rows[0].__setitem__("stock_name", "平安银行"), "!= stock_code"),
    "start_datetime 是字符串":
        (lambda rows: rows[0].__setitem__("start_datetime", "1756656000"), "不是整数"),
    "schema_version 变成 2":
        (lambda rows: [r.__setitem__("schema_version", 2) for r in rows], "schema_version 是"),
}


def _legacy_shaped_rows() -> list[dict]:
    """一份**完整合法**的旧七元组（三个真指纹，与 p11 SQL 一致）。"""
    return [{"stock_code": t.stock_code, "stock_name": t.stock_code,
             "start_datetime": t.start_datetime,
             "end_datetime": t.expected_end_datetime,
             "schema_version": r.LEGACY_SCHEMA_VERSION,
             "file_path": r.container_file_path(t.stock_code, t.start_datetime),
             "content_hash": h}
            for t, h in zip(r.PINNED_TARGETS,
                            ("851f9444", "32892a5f", "150d8d6c"))]


def test_seven_tuple_shape_accepts_a_complete_legacy_snapshot():
    """⭐ 正向对照，必须排在下面那一堆「拒了」之前看 ——
    ⛔ 一套全是「拒了」的用例掩盖得住一个**恒抛**的校验器。"""
    r.assert_seven_tuple_shape(_legacy_shaped_rows(), where="正向对照",
                               expect_schema_version=r.LEGACY_SCHEMA_VERSION)
    r.assert_matches_pinned_targets(_legacy_shaped_rows(), where="正向对照")


@pytest.mark.parametrize("label", sorted(_HOLES))
def test_seven_tuple_shape_rejects_each_known_hole(label):
    """codex 评审第 5 轮那条线索（它被额度掐断前只说到一半，这些是我逐条实测出来的）。

    ⛔ 上一版只查「行数 / 代数 / (code,start,end) 集合」三样，
    下面这些**当时全部通过**，其中「缺 stock_code」还抛的是 KeyError（命令行接不住）。
    ⭐ 每条都断言**红的理由**，⛔ 不只断言「红了」—— 见 `_HOLES` 的注释。
    """
    mutate, expected_reason = _HOLES[label]
    rows = _legacy_shaped_rows()
    mutate(rows)
    with pytest.raises(r.RebuildMismatch) as ei:
        r.assert_seven_tuple_shape(rows, where="残缺快照",
                                   expect_schema_version=r.LEGACY_SCHEMA_VERSION)
    assert expected_reason in str(ei.value), (
        f"红了，但红的理由不对 —— 期望命中「{expected_reason}」，实际是：{ei.value}")


def test_read_old_snapshot_rejects_an_incomplete_snapshot_file(tmp_path):
    """端到端走一遍文件：残缺快照必须抛 RebuildMismatch，⛔ 不能是 KeyError。"""
    rows = _legacy_shaped_rows()
    for row in rows:
        row.pop("content_hash")
    s = tmp_path / "s.json"
    s.write_text(json.dumps({"old": rows}), encoding="utf-8")
    with pytest.raises(r.RebuildMismatch):
        r.read_old_snapshot(s)


def test_pinned_targets_match_the_authority_row_for_row():
    """spec §7 判据 9③：新一批的 (stock_code, start_datetime) 与旧三个**逐一相同**。

    ⭐ 判据两侧都指向**活数据**：左边是代码里的 PINNED_TARGETS，右边是真解析器从
    p11 SQL 现读出来的。⛔ 不写成「等于某三个字面量」—— 那只是把同一份手抄值抄了第三遍。
    ⭐ 用**集合等式**而不是「这几个各自存在」：后者抓不住「多出来的第四个」。
    """
    rows = r.read_legacy_rows(_repo_root() / _P11)
    authority = {(x["stock_code"], x["start_datetime"], x["end_datetime"]) for x in rows}
    pinned = {(t.stock_code, t.start_datetime, t.expected_end_datetime)
              for t in r.PINNED_TARGETS}
    assert pinned == authority, (
        f"钉死的目标与权威值对不上\n  代码里：{sorted(pinned)}\n  p11 SQL：{sorted(authority)}")
    assert len(r.PINNED_TARGETS) == len(rows) == 3, (
        f"数量对不上：PINNED_TARGETS {len(r.PINNED_TARGETS)} 个、p11 SQL {len(rows)} 行")


class _CountingConn:
    """给 `_FakeConn` 套一层：让它能答上 `snapshot_source_counts` 发的那五条查询
    （四张表各一条 `SELECT count(*)` + `training_sets` 的 `SELECT max(id)`）；
    其余原样转给内层 `_FakeConn`（它对未预期的 SQL 会主动抛 AssertionError，
    见 `_FakeConn` 的 docstring，所以这五条不显式支持就会在 `rebuild_all` 里直接炸）。

    每个 key 第 1 次被问 = 跑前，第 2 次 = 跑后；`mutate_key` 指定的那个 key
    在第 2 次故意返回不同的值，用来证明 `rebuild_all` 真的比较了两次快照
    （Ruling ⑪：只有正向用例的话，一个从不比较的实现照样能绿）。
    """

    _KEYS = {f"SELECT count(*) FROM {t}": f"{t}.count"
             for t in ("klines", "stock_coverage", "stocks", "training_sets")}
    _KEYS["SELECT max(id) FROM training_sets"] = "training_sets.max_id"

    def __init__(self, inner, counts: dict, *, mutate_key: str | None = None):
        self.inner = inner
        self._counts = dict(counts)
        self._mutate_key = mutate_key
        self._seen: dict = {}

    def transaction(self, *, isolation=None, readonly=False):
        return self.inner.transaction(isolation=isolation, readonly=readonly)

    async def fetch(self, query: str, *args):
        return await self.inner.fetch(query, *args)

    async def fetchrow(self, query: str, *args):
        return await self.inner.fetchrow(query, *args)

    async def fetchval(self, query: str, *args):
        key = self._KEYS.get(query)
        if key is None:
            return await self.inner.fetchval(query, *args)
        n = self._seen.get(key, 0) + 1
        self._seen[key] = n
        val = self._counts[key]
        if n == 2 and key == self._mutate_key:
            val = val + 1
        return val


_STUB_SOURCE_COUNTS = {"klines.count": 100, "stock_coverage.count": 1, "stocks.count": 1,
                       "training_sets.count": 0, "training_sets.max_id": None}


def test_rebuild_all_end_to_end_matches_new_shape_and_leaves_source_counts_unchanged(bundle, tmp_path):
    """spec §7 判据 9②：源库四张表行数与 training_sets 的 count/max(id) **跑前跑后一致**。
    这条判据的实现正是 `snapshot_source_counts` + `rebuild_all` 里的比对（Ruling ⑪：
    brief 本身没有任何用例调过 `rebuild_all`，这条是补回来的端到端覆盖）。"""
    import asyncio
    target = _target_for(bundle)
    conn = _CountingConn(_conn(bundle), _STUB_SOURCE_COUNTS)
    result = asyncio.run(
        r.rebuild_all(conn, [target], tmp_path, old_rows=_legacy_shaped_rows()))
    assert set(result) == {"new", "old", "source_counts_before", "source_counts_after"}
    assert result["source_counts_before"] == result["source_counts_after"], (
        "源库只读那条判据：跑前跑后的计数必须完全一致")
    r.assert_seven_tuple_shape(result["new"], where="rebuild_all 的 new",
                               expect_schema_version=g.SCHEMA_VERSION)


def test_rebuild_all_refuses_when_source_counts_change_between_before_and_after(bundle, tmp_path):
    """⭐ 判别力证明：让替身在『跑后』返回**不同**的计数 ⇒ 必须抛 RebuildMismatch。
    只有正向用例的话，一个**从不比较**跑前跑后计数的实现照样能绿（Ruling ⑪）。"""
    import asyncio
    target = _target_for(bundle)
    conn = _CountingConn(_conn(bundle), _STUB_SOURCE_COUNTS, mutate_key="klines.count")
    with pytest.raises(r.RebuildMismatch):
        asyncio.run(r.rebuild_all(conn, [target], tmp_path, old_rows=_legacy_shaped_rows()))
