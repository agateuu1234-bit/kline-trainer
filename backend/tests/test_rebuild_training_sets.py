# backend/tests/test_rebuild_training_sets.py
# 切片一 P4 片 1：重建入口的常驻测试。
# 「假」的只有 asyncpg conn（沿用 _FakeConn）；bundle 是真 build_stock_import 产的，
# 窗口 / 索引 / SQLite / zip / CRC32 全链路是未改动的生产代码。
from __future__ import annotations

import json
import os
import random
import re
import sys
import tempfile
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


def test_rebuild_one_wraps_gating_skip_into_rebuild_mismatch(bundle, tmp_path):
    """A2：`load_gating_inputs` 抛的 `GenerateSkipException`（语义「这个候选不行，换一个」）
    必须被 `rebuild_one` 转成 `RebuildMismatch`（语义「停下来查清楚，不得继续」），
    ⛔ 消息里不能再带字面「跳过」——那会让操作者误以为只是少了一只股，
    而实际是一个包都没产出、清单也没发布。用一个没有 stock_coverage 行的替身连接触发。"""
    import asyncio
    bars = {p: pd.DataFrame(bundle.records[p]).sort_values("datetime").reset_index(drop=True)
            for p in g.PERIODS}
    conn = _FakeConn(_CODE, bars, None)      # 没有 stock_coverage 行
    target = _target_for(bundle)
    with pytest.raises(r.RebuildMismatch) as ei:
        asyncio.run(r.rebuild_one(conn, target, tmp_path))
    assert "跳过" not in str(ei.value), f"消息里还留着「跳过」字样：{ei.value}"


def test_rebuild_one_wraps_assembly_skip_into_rebuild_mismatch(bundle, tmp_path, monkeypatch):
    """A2：`assemble_from_windows` 抛的 `GenerateSkipException`（比如装配路径逃出
    output_dir 的信任边界校验）同样必须被转成 `RebuildMismatch`，⛔ 不带字面「跳过」。
    `build_pinned_windows` 早就做了这个转换，这两处（:105/:119）此前没做。"""
    import asyncio

    def _boom(*a, **kw):
        # ⚠️ 与真实 `assemble_from_windows` 的措辞同形（它本身不含「跳过」二字，
        # 见 generate_training_sets.py:460-461）——伪造成含「跳过」的消息只会测出
        # 「外层没有主动加词」，测不出「外层是否老实转述了内层」这件事。
        raise g.GenerateSkipException("测试用：装配路径逃出 output_dir（拒绝写入，信任边界校验）")

    monkeypatch.setattr(r, "assemble_from_windows", _boom)
    target = _target_for(bundle)
    with pytest.raises(r.RebuildMismatch) as ei:
        asyncio.run(r.rebuild_one(_conn(bundle), target, tmp_path))
    assert "跳过" not in str(ei.value), f"消息里还留着「跳过」字样：{ei.value}"


def test_rebuild_one_gating_skip_keeps_a_mid_sentence_skip_word(bundle, tmp_path, monkeypatch):
    """Ruling ⑮：剥离「跳过」二字只该动【结尾】那一份——句中出现的「跳过」不是本函数
    要清除的误导性措辞，必须原样保留。当年那行 `.replace("，跳过","").replace("跳过","")`
    是**全局文本替换**，会把句中的「跳过」也一起吃掉；用一条「跳过」出现在句中（不在
    结尾）的伪造 `GenerateSkipException` 证明：转换后的消息里这段文字必须完整还在。"""
    import asyncio

    async def _boom(conn, stock_code):
        raise g.GenerateSkipException(
            "测试用：跳过这一支后仍继续处理其余候选，未发现异常")

    monkeypatch.setattr(r, "load_gating_inputs", _boom)
    target = _target_for(bundle)
    with pytest.raises(r.RebuildMismatch) as ei:
        asyncio.run(r.rebuild_one(_conn(bundle), target, tmp_path))
    assert "跳过这一支后仍继续处理其余候选，未发现异常" in str(ei.value), (
        f"句中的「跳过」被静默剥掉了：{ei.value}")


@pytest.mark.parametrize("bad", [
    "INSERT INTO training_sets(stock_code, schema_version) VALUES ('X', 1)",
    "UPDATE training_sets SET schema_version = 1",
    "DELETE FROM klines",
    "CREATE TABLE t(x int)",
    "ALTER TABLE klines ADD COLUMN x int",
    "TRUNCATE training_sets",
    "DROP TABLE klines",
    "WITH changed AS (UPDATE training_sets SET schema_version = 1"
    " RETURNING id) SELECT count(*) FROM changed",
    "SELECT 1; UPDATE training_sets SET schema_version = 1",
    "SELECT FROM WHERE (((",
    "SELECT * INTO newtab FROM klines",
    "SELECT stock_code FROM training_sets FOR UPDATE",
], ids=[
    "insert", "update", "delete", "create_table", "alter_table", "truncate", "drop_table",
    "with_cte_update", "multi_statement_select_then_update", "unparsable",
    "select_into", "select_for_update",
])
def test_write_detector_reports_nonzero_on_a_planted_write(bad):
    """⭐ 先证明这个检测器**能报出非 0**，再让它去报 0。

    ⭐ 中间那几条是**按首词判**会漏掉的（codex 评审第 4 轮实测复现）：
    两条首词分别是 `WITH` / `SELECT`，一条根本解析不了；
    末两条顶层同样是 `SelectStmt`（`SELECT … INTO` 其实是 CREATE TABLE AS，
    `SELECT … FOR UPDATE` 要行锁），白名单本身看不见，需额外显式排除（A3）。

    ⭐ 换成 `parametrize`（关掉延后项 4）：⛔ 原来的 `for` 循环里 `pytest.raises`
    一旦提前失败会当场停下，排在它后面的坏样本永远不会被跑到；`parametrize` 让
    每一条坏样本各自独立跑、独立可见。
    """
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
    """真跑一次重建，断言发出去的每一条 SQL 都是读，且**恰好是**这两类。

    A4：评审实测——存在性检查表达不了穷尽性。往 `rebuild_one` 插一条
    `SELECT pg_try_advisory_lock(...)`（文本上看仍是一条干净的 SELECT，
    `assert_no_write_statements` 看不出它是取锁）后，本文件全套用例照样全绿。
    ⇒ 判据须是**集合等式**：钉住实际发出的那几类语句，而不是「都是读就行」。
    """
    import asyncio
    conn = r.ReadOnlyConn(_conn(bundle))
    target = _target_for(bundle)
    asyncio.run(r.rebuild_one(conn, target, tmp_path))

    assert conn.statements, "一条 SQL 都没记到 ⇒ 这个判据是空转的，⛔ 不算通过"
    r.assert_no_write_statements(conn.statements)
    assert set(conn.statements) == {
        "SELECT dense_1m_start_date, dense_1m_end_date, dropped_1m_dates, dense_day_count "
        "FROM stock_coverage WHERE stock_code=$1",
        f"SELECT {g._KLINE_SELECT_COLS} FROM klines "
        "WHERE stock_code=$1 AND period=$2 ORDER BY datetime",
    }, f"实际发出的语句集合与预期不同（多了/少了什么）：{set(conn.statements)}"
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


def test_read_legacy_rows_refuses_a_missing_file(tmp_path):
    """评审 Important：文件读不出来（`FileNotFoundError` ⊂ `OSError`）⇒ 判不了 ⇒ 拒绝，
    ⛔ 不能让裸 `OSError` 漏出去（命令行接不住）。消息里必须带上那个路径**和理由词**
    （关掉延后项 7：上一版只断言了路径，没断言"错误信息说清楚了失败的理由是什么"）。"""
    missing = tmp_path / "does-not-exist.sql"
    assert not missing.exists()
    with pytest.raises(r.RebuildMismatch) as ei:
        r.read_legacy_rows(missing)
    assert str(missing) in str(ei.value)
    assert "读不出来" in str(ei.value), f"消息里没有理由词「读不出来」：{ei.value}"


def test_read_legacy_rows_refuses_an_undecodable_file(tmp_path):
    """A1：`read_legacy_rows` 漏 `UnicodeDecodeError`（同一形状第三次发作）——姊妹函数
    `read_old_snapshot` 早就接住了 `(OSError, ValueError)`，这里此前只接 `OSError`。
    ⭐ `UnicodeDecodeError` ⊂ `ValueError`：喂一份编码坏掉的 p11 副本（非法 UTF-8 字节），
    必须抛 `RebuildMismatch` 且消息里带理由词，⛔ 不能让裸 `UnicodeDecodeError` 逃出去。"""
    q = tmp_path / "p11-bad-encoding.sql"
    q.write_bytes(b"\xff\xfe\x00INSERT INTO p11_expected VALUES (\xff\xff);")
    with pytest.raises(r.RebuildMismatch) as ei:
        r.read_legacy_rows(q)
    assert "读不出来" in str(ei.value), f"消息里没有理由词「读不出来」：{ei.value}"


def test_read_legacy_rows_refuses_unparsable_sql(tmp_path):
    """评审 Important：SQL 解析不了（pglast 的原始解析异常）⇒ 判不了 ⇒ 拒绝，
    ⛔ 不能让 pglast 的原始异常漏出去。"""
    src = (_repo_root() / _P11).read_text(encoding="utf-8")
    broken = src + "\nTHIS IS NOT VALID SQL ((( ;;;"
    assert broken != src
    q = tmp_path / "p11-broken.sql"
    q.write_text(broken, encoding="utf-8")
    with pytest.raises(r.RebuildMismatch) as ei:
        r.read_legacy_rows(q)
    assert "判不了" in str(ei.value)


def test_read_legacy_rows_refuses_a_non_integer_column(tmp_path):
    """评审 Important：该是整数的列被塞了非数字字面量 ⇒ 拒绝，
    ⛔ 不能让裸 `ValueError` 漏出去；消息必须点名是哪一列、实际值是什么。"""
    src = (_repo_root() / _P11).read_text(encoding="utf-8")
    anchor = "1777996799, 1,"
    assert src.count(anchor) == 1, "替换锚点漂了（不是恰好 1 处），停下来查"
    fake = src.replace(anchor, "1777996799, 'x',")
    assert fake != src
    q = tmp_path / "p11-bad-int.sql"
    q.write_text(fake, encoding="utf-8")
    with pytest.raises(r.RebuildMismatch) as ei:
        r.read_legacy_rows(q)
    assert "schema_version" in str(ei.value)
    assert "不是整数" in str(ei.value), f"消息里没有理由词「不是整数」：{ei.value}"


#: 每一项 = (怎么改坏, **期望命中的那条规则的原话片段**)。
#: ⭐ 钉住「红的理由」而不只是「红了」—— 本仓记过：一个被**别的**规则抢先拒掉的用例
#: 看起来是绿的（测试通过），实际上它要验的那条规则**一次都没执行过**。
#: 实测过：早先那版「目标对不上」被 file_path 规则抢先拒、「行数是 4」被指纹重复规则抢先拒。
_HOLES = {
    "缺 content_hash（P11b 身份闸的输入）":
        (lambda rows: [row.pop("content_hash") for row in rows], "字段集合不对"),
    "缺 file_path": (lambda rows: [row.pop("file_path") for row in rows], "字段集合不对"),
    "缺 stock_name": (lambda rows: [row.pop("stock_name") for row in rows], "字段集合不对"),
    "缺 stock_code": (lambda rows: [row.pop("stock_code") for row in rows], "字段集合不对"),
    "多出一个字段": (lambda rows: [row.__setitem__("extra", 1) for row in rows], "字段集合不对"),
    "content_hash 是空串":
        (lambda rows: rows[0].__setitem__("content_hash", ""), "不是非空字符串"),
    "指纹是大写":
        (lambda rows: rows[0].__setitem__("content_hash", "AAAA1111"), "不是 8 位小写十六进制"),
    "三行共用同一个【小写】指纹":
        (lambda rows: [row.__setitem__("content_hash", "deadbeef") for row in rows],
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
        (lambda rows: [row.__setitem__("schema_version", 2) for row in rows], "schema_version 是"),
}
#: C2：上面的推导式变量此前叫 `r`，与文件顶部 `import rebuild_training_sets as r` 撞名——
#: 目前可用（lambda 体从不引用模块 `r`），但谁往里加一句 `r.LEGACY_SCHEMA_VERSION`
#: 都会拿到 dict、炸一个莫名其妙的 `AttributeError`。已改成 `row`，纯改名不改行为。


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


@pytest.fixture
def scratch(tmp_path):
    """已存在的临时工作根。⛔ 每个用例都要显式给 `--scratch-dir` —— 它没有默认值。"""
    d = tmp_path / "scratch"
    d.mkdir()
    return d


def _cli(tmp_path, scratch, **over) -> list:
    """拼命令行参数。⭐ **只此一份** —— ⛔ 不在每个用例里各抄一遍。

    `over` 里给 `None` 表示**去掉**那个参数（用来造「少给了参数」的用例）。
    """
    args = {
        "--dsn": "postgresql://x/y",
        "--scratch-dir": str(scratch),
        "--out-dir": str(tmp_path / "out"),
        "--manifest": str(tmp_path / "m.json"),
        "--p11-sql": str(_repo_root() / _P11),
    }
    for k, v in over.items():
        key = "--" + k.replace("_", "-")
        if v is None:
            args.pop(key, None)
        else:
            args[key] = str(v)
    flat = []
    for k, v in args.items():
        flat += [k, v]
    return flat


def _fake_rebuild_all_dict(old_rows) -> dict:
    """给『替身 rebuild_all』用的**完整**假返回值（四个键都给全，不只是 `new`/`old`）
    ——好让 B2 新增的『发布出去的清单键集』等式断言，在这类替身场景下验的是
    `rebuild_all` 真实会给的键集合，而不是被替身自己漏掉的两个键（`source_counts_*`）
    误判成生产代码漏了。"""
    return {"new": _fake_pinned_new_rows(), "old": old_rows,
            "source_counts_before": {}, "source_counts_after": {}}


def _fake_pinned_new_rows() -> list[dict]:
    """B1：一份满足 `assert_matches_pinned_targets` 的假『新清单』——只给它检查的那
    三个字段（stock_code/start_datetime/end_datetime），让下面这些用『假 rebuild_all』
    替身走完整个 main() 的 CLI 测试，在 B1 新增的这道闸下继续原样验各自要验的东西，
    而不是被这道新闸提前拦下、悄悄短路掉它们本来要覆盖的代码路径。"""
    return [{"stock_code": t.stock_code, "start_datetime": t.start_datetime,
             "end_datetime": t.expected_end_datetime} for t in r.PINNED_TARGETS]


def _stub_connection(monkeypatch):
    """把「连源库」整个换成替身 —— 本组用例验的是命令行的闸门，不是数据库。

    ⭐ 换的是 `connect_read_only` 本身：如果哪天 `main` 绕过它去裸连数据库，
    这些用例会去真连 `postgresql://x/y` 然后炸掉 —— 等于顺带钉住了「必须走只读连接」。
    """
    class _StubConn:
        async def close(self):
            pass

    async def _connect(dsn):
        return _StubConn()

    monkeypatch.setattr(r, "connect_read_only", _connect)


def _archive(tmp_path, monkeypatch):
    """造一个假的 v1 归档，并把 HOME 指过去。"""
    monkeypatch.setenv("HOME", str(tmp_path))
    a = tmp_path / "qmt_trial_out"
    a.mkdir()
    (a / "000001.SZ_1756656000.zip").write_bytes(b"V1-ORIGINAL-BYTES")
    return a


# ---------- 路径闸本身 ----------

def test_write_gate_rejects_a_symlink_pointing_into_the_archive(tmp_path, monkeypatch):
    """⭐ 一个【指向归档的符号链接】目录（codex 第 1 轮）。

    实测：`assemble_from_windows` **自带**的「没逃出 output_dir」守卫会**放行** ——
    它比的是 `output_dir.resolve()` 与 `zip_path.resolve().parents`，而 `.resolve()`
    会跟着符号链接走，两边都被解析进了归档 ⇒ 判定「没逃出去」为真
    ⇒ 归档里那个同名 zip 被 `ZipFile(..., "w")` 就地截断（实测原始 17 字节被销毁）。
    ⇒ 所以这道闸必须在**我们自己这一侧**拦住，⛔ 不能指望下游守卫。
    """
    archive = _archive(tmp_path, monkeypatch)
    link = tmp_path / "newbatch-verify"
    link.symlink_to(archive, target_is_directory=True)
    with pytest.raises(r.RebuildMismatch) as ei:
        r.assert_write_target_is_safe(link, kind="验证目录")
    assert "归档" in str(ei.value)


def test_write_gate_accepts_a_normal_target(tmp_path, monkeypatch):
    """⭐ 正向对照：⛔ 一套全是「拒了」的用例掩盖得住一个恒抛的守卫 ——
    那是本仓点名的头号假绿形态。"""
    _archive(tmp_path, monkeypatch)
    got = r.assert_write_target_is_safe(tmp_path / "newbatch", kind="产出目录")
    assert got == (tmp_path / "newbatch").resolve()


# ---------- 临时工作根（第 6/7 轮，已塌层） ----------

def test_cli_refuses_a_scratch_dir_inside_the_archive_without_writing_anything(
        tmp_path, monkeypatch):
    """⛔ `--scratch-dir` 指进归档 ⇒ 拒绝，**而且全程一个字节都不许往归档里写**。

    ⭐ 判据用**记录 `os.open` 调用**，⛔ 不是「跑完之后看目录里有没有多东西」：
    上一版就是那么写的，抓不住 —— 实测 `tempfile` 的发现逻辑会
    `open` → `write(b'blat')` → `unlink`，探针文件**建过又删了**，事后看目录什么都没有。
    ⭐ 同时把 `tempfile.tempdir` 清成 `None`（冷缓存），逼出真正的失败路径：
    上一版用例直接给 `tempfile.tempdir` 赋值，**会跳过发现逻辑**，所以它根本没走到那条路。
    """
    archive = _archive(tmp_path, monkeypatch)
    monkeypatch.setattr(tempfile, "tempdir", None)
    monkeypatch.setenv("TMPDIR", str(archive))
    _stub_connection(monkeypatch)

    attempted = []
    real_open = os.open

    def spy_open(path, flags, *a, **kw):
        try:
            if archive.resolve() in Path(path).resolve().parents:
                attempted.append(str(path))
        except Exception:
            pass
        return real_open(path, flags, *a, **kw)

    monkeypatch.setattr(os, "open", spy_open)

    rc = r.main(_cli(tmp_path, archive))     # scratch 就指向归档本身
    assert rc != 0
    assert attempted == [], f"归档里被尝试创建过文件：{attempted}"


def test_cli_pins_tempfile_to_the_validated_scratch_root(tmp_path, scratch, monkeypatch):
    """⭐ 正向对照 + 一条更强的断言：校验通过之后，`tempfile` 必须被**钉**在这个根上。

    ⛔ 不钉住的话，生成器内部那个 `TemporaryDirectory()`
    （`generate_training_sets.py:468`）仍会自己去发现临时目录 —— 而发现本身就会写盘。
    """
    _archive(tmp_path, monkeypatch)
    monkeypatch.setattr(tempfile, "tempdir", None)
    _stub_connection(monkeypatch)
    seen = {}

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        seen["tempdir"] = tempfile.tempdir
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(b"SAME-BYTES")
        return {"new": _fake_pinned_new_rows(), "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)
    assert r.main(_cli(tmp_path, scratch)) == 0
    assert seen["tempdir"] == str(scratch.resolve()), (
        f"tempfile 没被钉在已校验的根上：{seen['tempdir']}")


def test_cli_refuses_a_missing_scratch_dir(tmp_path, monkeypatch):
    """⛔ 临时工作根必须**已经存在** —— 不存在就拒，⛔ 不替操作者悄悄建。"""
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    assert r.main(_cli(tmp_path, tmp_path / "nope")) != 0


# ---------- 产出目录 / 清单 ----------

def test_cli_refuses_out_dir_inside_the_v1_archive(tmp_path, scratch, monkeypatch):
    """⛔ spec §3.4 R2 ⓒ：不得写入 ~/qmt_trial_out/（v1 审计归档，逐字节不得改）。"""
    archive = _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    assert r.main(_cli(tmp_path, scratch, out_dir=archive)) != 0


def _stub_rebuild_all(monkeypatch):
    """把 `rebuild_all` 也换成"总是成功、写出匹配字节"的替身。

    ⭐ **这是任务评审 Important 发现 1 逼出来的**：下面四条用例本来指望路径闸在
    `main()` 走到任何数据库调用**之前**就把命令拦下——但一旦某条闸被**变异**删掉，
    `main()` 会真的往下走到 `snapshot_source_counts(conn)` 去问一个只有 `close()`
    方法的连接替身，`AttributeError: '_StubConn' object has no attribute
    'fetchval'` 会在这里把测试变红。那样"红了"的原因是**替身不完整**、
    而不是**闸没挡住**——两者不是一回事（codex 实测复现过，见变异记录 T6-2/T6-4/T6-6）。
    ⇒ 补上这个替身，变异之后 `main()` 才能干净走完、返回一个真实的退出码，
    让"红的是哪一句、为什么"这件事经得起追问。
    """
    async def _fake(conn, targets, output_dir, *, old_rows):
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(b"SAME-BYTES")
        return {"new": [], "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake)


def test_cli_refuses_manifest_inside_the_v1_archive(tmp_path, scratch, monkeypatch):
    """清单路径也要过同一道闸——判据要能分辨"闸在"与"闸不在"两种情况。

    ⚠️ **任务评审 Important 发现 1 逼出来的改法**：上一版让 `--manifest` 指向归档里
    一个**已经存在**的旧 zip，断言它的字节没被动过。实测证明这样选**分不出**
    "归档闸在"和"归档闸被删掉"——因为 `publish_manifest` 的 `os.link`（目标已存在
    即失败）本来就会独立拒绝覆盖一个已存在的文件，闸删不删这条用例都一样绿。
    ⇒ 改成指向归档里一个**不存在**的路径，断言**归档目录的文件集合完全没变**——
    这与 `--scratch-dir` 那条用例（`test_cli_refuses_a_scratch_dir_inside_the_archive_without_writing_anything`）
    是同一个判据形状：闸在场时，`main()` 应该在任何写入尝试之前就拒绝，
    归档里不会多出任何新条目；闸被删掉时，`publish_manifest` 会真的在归档里
    建出一个新文件并成功返回 0（实测复现过），此时才是真正的、持久的违规。
    """
    archive = _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    _stub_rebuild_all(monkeypatch)
    before = sorted(p.name for p in archive.iterdir())
    victim = archive / "new-manifest-does-not-exist.json"
    assert r.main(_cli(tmp_path, scratch, manifest=victim)) != 0
    assert sorted(p.name for p in archive.iterdir()) == before, "归档目录多出了新文件"


def test_cli_refuses_to_overwrite_an_existing_manifest(tmp_path, scratch, monkeypatch):
    """⛔ 首轮清单里的【旧身份快照】一旦被盖掉就再也取不回来（那时 P11 已是第 2 代）。"""
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    _stub_rebuild_all(monkeypatch)
    man = tmp_path / "m.json"
    man.write_text('{"old": "首轮快照"}', encoding="utf-8")
    assert r.main(_cli(tmp_path, scratch)) != 0
    assert "首轮快照" in man.read_text(encoding="utf-8"), "已有清单被覆盖了"


def test_cli_refuses_an_existing_out_dir(tmp_path, scratch, monkeypatch):
    """产出目录必须【不存在】（spec §3.4 R2 要的就是一个新目录）。

    ⭐ 这比「必须为空」强：`os.mkdir` 是原子的，两个进程同时开工时后来者当场失败；
    而「先看是不是空的、再往里写」拦不住它们（与清单那条是同一个窗口）。
    """
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    _stub_rebuild_all(monkeypatch)
    out = tmp_path / "out"
    out.mkdir()                       # 已经存在，哪怕是空的也要拒
    assert r.main(_cli(tmp_path, scratch)) != 0


def test_cli_refuses_when_neither_old_value_source_is_given(tmp_path, scratch, monkeypatch):
    """⛔ `--p11-sql` 与 `--old-snapshot` 都不给 ⇒ 拒绝。

    ⭐ **拆自原来的单条 `test_cli_requires_exactly_one_old_value_source`**（Ruling ⑬）：
    本仓已经在这个形状上栽过三次（Task 3 两句断言只有第一句有判别力、Task 5 同一条规矩
    两份副本只订正一份、Task 6/T6-2 用例被替身崩溃「红」掉），这是第四次——两个子场景
    挤在一条用例里，"都给"那个子场景的判别力在正常运行中不可见（前一句先抛异常，
    `assert` 语句根本走不到后一句）。⇒ 拆成两条独立用例，让两个子场景各自的判据
    在**每一次**正常运行里都看得见，不必等人手工 deselect 才知道。
    """
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    _stub_rebuild_all(monkeypatch)
    assert r.main(_cli(tmp_path, scratch, p11_sql=None)) != 0


def test_cli_refuses_when_both_old_value_sources_are_given(tmp_path, scratch, monkeypatch):
    """⛔ `--p11-sql` 与 `--old-snapshot` 都给 ⇒ 拒绝（见上一条的拆分说明）。"""
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    _stub_rebuild_all(monkeypatch)
    assert r.main(_cli(tmp_path, scratch,
                       old_snapshot=tmp_path / "s.json")) != 0


def test_publish_manifest_refuses_an_existing_destination(tmp_path):
    """目标已存在 ⇒ 抛错，且**一个字节都不碰**。"""
    dest = tmp_path / "m.json"
    dest.write_bytes(b"FIRST-RUN-SNAPSHOT")
    with pytest.raises(r.RebuildMismatch):
        r.publish_manifest(dest, '{"new": []}\n')
    assert dest.read_bytes() == b"FIRST-RUN-SNAPSHOT", "目标被动过了"
    assert not list(tmp_path.glob(".manifest.*")), "临时文件没清干净"


def test_publish_manifest_writes_when_destination_is_free(tmp_path):
    """⭐ 正向对照：⛔ 没有它，一个**恒抛**的 publish_manifest 也能让上面那条绿。"""
    dest = tmp_path / "m.json"
    r.publish_manifest(dest, '{"ok": 1}\n')
    assert json.loads(dest.read_text(encoding="utf-8")) == {"ok": 1}
    assert not list(tmp_path.glob(".manifest.*")), "临时文件没清干净"


def test_publish_manifest_wraps_a_non_exists_oserror_from_os_link(tmp_path, monkeypatch):
    """B3：`os.link` 在跨设备或不支持硬链接的挂载点（SMB/NFS/exFAT）抛的是
    `EXDEV`/`EPERM`/`ENOTSUP`，不是 `FileExistsError`——`main()` 只捕
    `RebuildMismatch`，这里不转换的话会裸崩，而此时两轮重建已经跑完、清单却丢了。
    ⭐ 用 monkeypatch 让 `os.link` 抛 `OSError(errno.EXDEV, ...)` 来模拟。"""
    import errno

    def _boom_link(src, dst):
        raise OSError(errno.EXDEV, "Invalid cross-device link")

    monkeypatch.setattr(os, "link", _boom_link)
    dest = tmp_path / "m.json"
    with pytest.raises(r.RebuildMismatch) as ei:
        r.publish_manifest(dest, '{"new": []}\n')
    assert "挂不上去" in str(ei.value), f"消息里没有理由词「挂不上去」：{ei.value}"
    assert not dest.exists(), "目标不该被创建出来"


# ---------- 确定性自证 ----------

def test_cli_always_verifies_determinism_even_without_any_flag(
        tmp_path, scratch, monkeypatch):
    """⛔ 确定性自证是**无条件**的（spec §3.4 R2 / §7 判据 9① / 变异 B54）。

    ⭐ 判据是「`rebuild_all` 被调了**两次**、且两次落在**不同目录**」——
    只断言「跑完了」抓不住「只跑了一遍」；两次落同一个目录的话，逐字节比对是**恒真**的。
    """
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    man = tmp_path / "m.json"
    calls = []

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        calls.append(Path(output_dir))
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(b"SAME-BYTES")
        return _fake_rebuild_all_dict(old_rows)

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)

    assert r.main(_cli(tmp_path, scratch)) == 0, "合法输入却失败了"
    assert len(calls) == 2, f"只重建了 {len(calls)} 遍 —— 确定性自证被跳过了"
    assert calls[0] != calls[1], "两遍产出到了同一个目录 ⇒ 逐字节比对恒真，判别力为零"
    published = json.loads(man.read_text(encoding="utf-8"))
    assert published["determinism_verified_against"]
    # B2：**钉住发布物的键集合**（`test_rebuild_all_end_to_end…` 钉的是 `rebuild_all`
    # 的返回值，不是最终发布出去的这份清单）。⚠️ 计划 `:2045` 交给片 2 的「清单 JSON
    # 结构」此前写的是 5 个键，与这里实测的 7 个键不符（第 3 轮加无条件自证、第 7 轮加
    # 显式 `--scratch-dir` 之后过期，两次订正都没回头改交接段那一行）——已在计划里同步
    # 订正（见该文件交接段第 3 条）。片 2 若按旧的 5 键集合等式校验器写，会当场拒掉真清单。
    assert set(published) == {
        "new", "old", "source_counts_before", "source_counts_after",
        "determinism_verified_against", "statements_issued", "scratch_root",
    }, f"发布的清单键集与交接给片 2 的既定事实不符：{sorted(published)}"


def test_cli_refuses_when_new_manifest_does_not_match_pinned_targets(
        tmp_path, scratch, monkeypatch):
    """B1：`main()` 必须真的对本轮产出的【新清单】跑 `assert_matches_pinned_targets`——
    不能只是**构造性成立**（`rebuild_all` 内部用的就是 `PINNED_TARGETS`，天然吻合）。
    用一份『行数不对』的假新清单（0 行，应有 3 行）证明：这道闸真的在执行，不是摆设。"""
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)

    async def _fake_wrong_new(conn, targets, output_dir, *, old_rows):
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(b"SAME-BYTES")
        return {"new": [], "old": old_rows}      # 应有 3 行，这里给 0 行

    monkeypatch.setattr(r, "rebuild_all", _fake_wrong_new)
    assert r.main(_cli(tmp_path, scratch)) != 0


def test_cli_does_not_publish_when_the_two_rounds_differ(tmp_path, scratch, monkeypatch):
    """两轮字节不一致 ⇒ ⛔ 不发布清单、退出码非 0。

    ⭐ 这条是上一条的**反向**：没有它，一个「调了两次但从不比较」的实现照样能让上一条绿。
    """
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    man = tmp_path / "m.json"
    n = {"i": 0}

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        n["i"] += 1
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(
            b"ROUND-1-BYTES" if n["i"] == 1 else b"ROUND-2-DIFFERENT")
        return {"new": _fake_pinned_new_rows(), "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)

    assert r.main(_cli(tmp_path, scratch)) != 0, "两轮不一致却报成功了"
    assert not man.exists(), "两轮不一致却还是把清单发布了"


def test_cli_does_not_clobber_a_manifest_created_after_preflight(
        tmp_path, scratch, monkeypatch):
    """⭐ codex 第 2 轮那条：预检与真正写盘之间隔着**整轮重建**（几分钟）。

    这里让「重建」那一步自己在窗口期内把清单建出来，模拟另一个进程。
    ⛔ 预检必然放行 —— 它早就跑完了。拦住它的只能是 `publish_manifest` 的原子发布。
    """
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    man = tmp_path / "m.json"

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        man.write_bytes(b"FIRST-RUN-SNAPSHOT")      # ← 窗口期内被别的进程建出来
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(b"SAME-BYTES")
        return {"new": _fake_pinned_new_rows(), "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)

    assert r.main(_cli(tmp_path, scratch)) != 0
    assert man.read_bytes() == b"FIRST-RUN-SNAPSHOT", "首轮快照被覆盖了"


def test_cli_prints_a_retry_hint_when_failing_after_out_dir_is_already_built(
        tmp_path, scratch, monkeypatch, capsys):
    """C4：`main()` 失败时 `out` 目录已经被 `os.mkdir` 建出来、且本命令不回滚——
    而它必须【不存在】才能重跑。复用『两轮不一致』这个失败场景，确认 stderr 里
    带着这条提示，不必让操作者自己去猜「为什么原样重跑又立刻被拒」。"""
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    n = {"i": 0}

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        n["i"] += 1
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(
            b"ROUND-1-BYTES" if n["i"] == 1 else b"ROUND-2-DIFFERENT")
        return {"new": _fake_pinned_new_rows(), "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)
    rc = r.main(_cli(tmp_path, scratch))
    assert rc != 0
    err = capsys.readouterr().err
    assert "已经建出" in err and "换一个新路径" in err, f"stderr 里没有产出目录重试提示：{err}"


def test_cli_success_message_mentions_the_leftover_verify_dir(
        tmp_path, scratch, monkeypatch, capsys):
    """C4：成功收尾的 print 里要提一下第二轮验证目录的位置——它带着本轮全部 zip
    永久留在 scratch 里，本命令不清理，操作者应该知道去哪儿删。"""
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(b"SAME-BYTES")
        return {"new": _fake_pinned_new_rows(), "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)
    assert r.main(_cli(tmp_path, scratch)) == 0
    out = capsys.readouterr().out
    assert "验证目录" in out and "zip" in out, f"成功提示里没有提到验证目录：{out}"


def test_cli_success_message_zip_count_follows_pinned_targets(
        tmp_path, scratch, monkeypatch, capsys):
    """Ruling ⑭：成功提示里的 zip 个数必须**跟着 `PINNED_TARGETS` 的实际长度走**，
    ⛔ 不能是写死的字面量——猴补（monkeypatch）把 `PINNED_TARGETS` 缩到只剩 2 个目标
    （连带旧快照也换成只含这 2 个目标的样子，改走 `--old-snapshot`，避免撞上
    「新旧目标集合必须一致」这道跟本条无关的闸），提示里就该说「2 个 zip」；
    如果还说着不存在的「3」，说明数字仍然是写死的。"""
    _archive(tmp_path, monkeypatch)
    _stub_connection(monkeypatch)
    short = r.PINNED_TARGETS[:2]
    monkeypatch.setattr(r, "PINNED_TARGETS", short)
    snapshot = _write_snapshot(tmp_path, _legacy_shaped_rows())

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        (Path(output_dir) / f"{short[0].stock_code}_{short[0].start_datetime}.zip"
         ).write_bytes(b"SAME-BYTES")
        return {"new": _fake_pinned_new_rows(), "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)
    args = _cli(tmp_path, scratch, p11_sql=None, old_snapshot=str(snapshot))
    assert r.main(args) == 0
    out = capsys.readouterr().out
    assert "2 个 zip" in out, f"提示里的 zip 个数没跟着缩到 2：{out}"
    assert "3 个 zip" not in out, f"提示里还留着写死的旧数字「3」：{out}"


# ---------- 旧身份快照 ----------

def _write_snapshot(tmp_path, rows):
    s = tmp_path / "s.json"
    s.write_text(json.dumps({"old": rows}), encoding="utf-8")
    return s


def test_read_old_snapshot_accepts_a_valid_first_round_manifest(tmp_path):
    """⭐ 正向对照（防一套全是「拒了」的用例掩盖一个**恒抛**的校验器）。

    ⛔ 用 `_legacy_shaped_rows()`（三个**真**指纹）——
    上一版这里自己另造了一份「三行都填 deadbeef」的样本，
    在「三个指纹必须互不相同」那条规则落地之后**必然失败**（codex 第 5 轮实测）。
    ⇒ 合法样本只许有**一份**，⛔ 不许各处各造一份。
    """
    assert len(r.read_old_snapshot(_write_snapshot(tmp_path, _legacy_shaped_rows()))) \
        == len(r.PINNED_TARGETS)


def test_read_old_snapshot_refuses_a_second_generation_snapshot(tmp_path):
    rows = _legacy_shaped_rows()
    for row in rows:
        row["schema_version"] = 2
    with pytest.raises(r.RebuildMismatch) as ei:
        r.read_old_snapshot(_write_snapshot(tmp_path, rows))
    assert "schema_version 是" in str(ei.value), f"红的理由不对：{ei.value}"


def test_read_old_snapshot_refuses_when_targets_do_not_match(tmp_path):
    """⚠️ 起点改了，`file_path` **必须跟着改** —— 否则会被「file_path 与身份不符」
    那条**抢先**拒掉，而本用例要验的「目标集合」规则一次都不会执行（实测过）。"""
    rows = _legacy_shaped_rows()
    rows[0]["start_datetime"] += 1
    rows[0]["file_path"] = r.container_file_path(
        rows[0]["stock_code"], rows[0]["start_datetime"])
    with pytest.raises(r.RebuildMismatch) as ei:
        r.read_old_snapshot(_write_snapshot(tmp_path, rows))
    assert "与钉死的目标对不上" in str(ei.value), f"红的理由不对：{ei.value}"


def test_read_old_snapshot_refuses_wrong_row_count(tmp_path):
    """⚠️ 多出来那一行的指纹**必须与前三行都不同** —— 否则会被「指纹重复」
    那条抢先拒掉，而本用例要验的「行数」规则一次都不会执行（实测过）。"""
    rows = _legacy_shaped_rows()
    extra = dict(rows[-1])
    extra["content_hash"] = "aabbccdd"
    rows.append(extra)
    with pytest.raises(r.RebuildMismatch) as ei:
        r.read_old_snapshot(_write_snapshot(tmp_path, rows))
    assert "应有" in str(ei.value) and "行" in str(ei.value), f"红的理由不对：{ei.value}"
