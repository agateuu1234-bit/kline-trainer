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


# ── Task 2：生产者半边断言（spec §4.1 note 3）

import contextlib          # noqa: E402
import sqlite3             # noqa: E402
import tempfile            # noqa: E402
import zipfile             # noqa: E402
from pathlib import Path   # noqa: E402

# ⛔ 手写字面量。推导见本片计划 Task 2 的表格。
# ⛔ **绝不**允许写成运行时调 `period_end` / `assign_global_indices` 现算（spec 变异 B18）：
#    那样生产者与校验者接到同一个公式上，公式改错两边**一起绿**，缺陷原样藏住。
EXPECTED_END_GLOBAL_INDEX: dict[str, list[int]] = {
    # 收盘标注：各自指向自己那一刻
    "3m":      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
                12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23],
    "15m":     [3, 5, 9, 11, 15, 17, 21, 23],
    "60m":     [5, 11, 17, 23],
    # 开盘侧标注：指向所属日历周期的最后一刻
    "daily":   [0, 5, 11, 17, 23],
    "weekly":  [0, 5],                 # 03-30 那根被删 ⇒ 03-23 那根按【日历周末】落在 5
    "monthly": [0, 0, 17, 23],         # 前两根月末早于 3m 轴首 ⇒ clamp 0（特征①）
}


@contextlib.contextmanager
def _open_zip_db(zip_path):
    """打开训练组 zip 里那**唯一**一个成员，落临时文件后用 sqlite3 打开。

    顺带兑现 spec §4.1 note 3 的压缩包清单判据：恰好 1 个成员、无 sidecar。
    """
    zip_path = Path(zip_path)
    with zipfile.ZipFile(zip_path) as zf:
        members = zf.namelist()
        assert len(members) == 1, f"训练组 zip 必须恰好 1 个成员（无 sidecar），实测 {members}"
        blob = zf.read(members[0])
    with tempfile.TemporaryDirectory() as td:
        member_path = Path(td) / "member.db"
        member_path.write_bytes(blob)
        conn = sqlite3.connect(str(member_path))
        try:
            yield members, conn
        finally:
            conn.close()


def test_committed_fixture_file_exists():
    """⛔ 缺文件必须**红**，不得 skip —— 后端 CI 零容忍 skip，一条 skip 会被当成覆盖缺口。"""
    assert FIXTURE_ZIP.is_file(), (
        f"跨端契约 fixture 缺失：{FIXTURE_ZIP}\n"
        f"用 `python3 backend/scripts/regen_trainingset_contract_fixture.py` 生成它。")


@pytest.mark.parametrize("source", ["fresh", "committed"])
def test_fixture_matches_hand_written_expectations(source, tmp_path):
    """逐周期索引向量必须等于**独立人工推算**的期望（spec §4.1 note 3）。

    ⭐ **两路都要跑**：`fresh` = 现场重建的生成器输出，`committed` = 仓库里那份已提交 fixture。
    手写期望值同时钉住这两者 ⇒ 三方（手写期望 / 已提交产物 / 当前生成器）中任何一方漂移都会红。
    ⚠️ 若只跑 `fresh`，已提交那份产物就没有任何判据看着它，切片二会对着一份没人验过的产物开发。
    """
    zip_path = build_fixture(tmp_path).path if source == "fresh" else FIXTURE_ZIP

    with _open_zip_db(zip_path) as (members, conn):
        # 压缩包清单
        assert len(members) == 1
        assert Path(members[0]).suffix in (".sqlite", ".db"), (
            f"训练组 zip 成员后缀必须是 .sqlite 或 .db，实测 {members[0]!r}")
        # 产物代际（⛔ 写字面量 2，不 import SCHEMA_VERSION：import 会让断言自我实现）
        assert conn.execute("PRAGMA user_version").fetchone()[0] == 2

        # 逐周期索引向量
        for period, expected in EXPECTED_END_GLOBAL_INDEX.items():
            got = [r[0] for r in conn.execute(
                "SELECT end_global_index FROM klines WHERE period=? ORDER BY id", (period,))]
            assert got == expected, f"{period} 的 end_global_index 与手写期望不符：{got} != {expected}"

        # global_index：仅 3m 赋值、其余全 NULL（D2/D4 契约，本片顺带钉住）
        gi3 = [r[0] for r in conn.execute(
            "SELECT global_index FROM klines WHERE period='3m' ORDER BY id")]
        assert gi3 == EXPECTED_END_GLOBAL_INDEX["3m"]
        non_null = conn.execute(
            "SELECT count(*) FROM klines WHERE period<>'3m' AND global_index IS NOT NULL"
        ).fetchone()[0]
        assert non_null == 0, "非 3m 周期的 global_index 必须全为 NULL"

        # meta 单行（含非 ASCII 股票名的 UTF-8 往返）
        assert conn.execute(
            "SELECT stock_code, stock_name, start_datetime, end_datetime FROM meta").fetchall() == [
            ("999002.SZ", "跨端契约样例", 1774972800, 1775059199)]
        assert conn.execute("SELECT count(*) FROM klines").fetchone()[0] == 47   # 4+2+5+4+8+24


# ── Task 4：漂移闸（spec §4.1 note 4；变异 B53 / B64）

def _logical_content(zip_path) -> dict:
    """训练组 zip 的**逻辑内容**（⛔ 不含任何随机器/时间变化的东西）。"""
    with _open_zip_db(zip_path) as (members, conn):
        return {
            "members": list(members),
            "user_version": conn.execute("PRAGMA user_version").fetchone()[0],
            # DDL 也要比：spec §4.1 note 4 明写「生成器日后改了序列化 / DDL / 版本」都要被抓住
            "schema": conn.execute(
                "SELECT type, name, sql FROM sqlite_master "
                r"WHERE name NOT LIKE 'sqlite\_%' ESCAPE '\' ORDER BY type, name").fetchall(),
            # ⭐ 与 klines 一样用 `SELECT *`：显式列清单会让**日后新增的列**从此永远不进比较面
            # —— 加列那一次由 schema 抓到，之后那一列的取值漂移就再没人看着了（评审 Task4-I1）。
            "meta": conn.execute("SELECT * FROM meta").fetchall(),
            "klines": conn.execute("SELECT * FROM klines ORDER BY id").fetchall(),
        }


def test_committed_fixture_matches_current_generator(tmp_path):
    """每次 CI 都把【当前生成器的输出】与【已提交 fixture】对齐（spec §4.1 note 4）。

    ⛔ 比【逻辑内容】不比 zip 原始字节：SQLite 文件头 offset 96 存的是**写这个库的那个
       sqlite 库的版本号**（本机实测 3053003 = 3.53.3）⇒ 换机器 / 升 sqlite 后字节与 CRC32
       都会变，比字节必然假红。同理 ⛔ 不得断言 content_hash 字面量。
    """
    fresh = build_fixture(tmp_path)
    got = _logical_content(fresh.path)
    committed = _logical_content(FIXTURE_ZIP)
    if got != committed:
        drifted = [k for k in got if got[k] != committed[k]]
        pytest.fail(
            f"当前生成器的输出与已提交 fixture 不一致（差异字段：{drifted}）。\n"
            f"这说明**生成器的行为变了**。\n"
            f"⛔ 别急着跑再生脚本把它压绿 —— 先判断这是不是有意的改动：\n"
            f"  · 有意 ⇒ 跑 `python3 backend/scripts/regen_trainingset_contract_fixture.py` "
            f"重生 fixture，并按 tests/contract-fixtures/training-set/README.md "
            f"把切片二的 App 侧读取链路一并重跑；\n"
            f"  · 无意 ⇒ 这就是回归，该改的是生成器，不是 fixture。")


def test_drift_gate_compares_row_content_not_just_the_member_list():
    """自测：漂移闸的比较面必须**真的逐行逐列**地包含每张表（否则它只是个文件名检查）。

    ⚠️ 这条防的是「闸门写窄了」——只比成员清单的话，改公式（`end_global_index` 全变）
    也不会红，而那正是本切片存在的理由。

    ⛔ **只断言键名在不在是不够的**（评审 Task4-I2 实证）：把
       `"klines": SELECT * … .fetchall()` 换成 `"klines": SELECT count(*) … .fetchone()[0]`，
       **键名一个没少**、闸门却退化成一个行数检查 —— 而逐根改错的 `end_global_index`
       恰恰只有逐行比才抓得住。⇒ 本条必须断言每个键的**取值形状**，不只是它的名字。
    """
    c = _logical_content(FIXTURE_ZIP)
    assert set(c) == {"members", "user_version", "schema", "meta", "klines"}, (
        f"漂移闸的比较面被改窄/改宽了：{sorted(c)}")

    # klines：必须是【逐行 × 逐列】的完整表，⛔ 不得退化成计数或摘要
    assert isinstance(c["klines"], list) and len(c["klines"]) == 47, (
        f"klines 必须逐行比（期望 47 行的 list，实测 {type(c['klines']).__name__}）")
    assert all(isinstance(r, tuple) and len(r) == 18 for r in c["klines"]), (
        "klines 每行必须是完整的 18 列元组 —— 少一列，那一列的漂移就永远抓不到")

    # meta：同样必须是完整行
    assert isinstance(c["meta"], list) and len(c["meta"]) == 1 and len(c["meta"][0]) == 4, (
        f"meta 必须逐行逐列比（期望 1 行 × 4 列，实测 {c['meta']!r}）")

    # schema：必须比 DDL **原文**，否则列的增删改无人看着
    schema_sql = "\n".join(sql for *_, sql in c["schema"] if sql)
    assert "end_global_index" in schema_sql, (
        "schema 必须包含 DDL 原文（`sqlite_master.sql`）——只比表名的话，改列型/加列都不会红")
    assert not any(name.startswith("sqlite_") for _, name, _ in c["schema"]), (
        "sqlite_ 开头的内部表不得进比较面（sqlite_sequence 随 AUTOINCREMENT 变动，会造假红）")
