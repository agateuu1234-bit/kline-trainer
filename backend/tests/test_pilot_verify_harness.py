# backend/tests/test_pilot_verify_harness.py
"""真-PG 验收护栏里**纯函数**那部分的 L1 回归。

只放不需要数据库的判据 —— 需要真 PG 的那些在 `backend/scripts/verify_pilot_*.py`。
存在的理由：`db_dsn` 是 6 个调用点共用的「把探针指向哪个库」的唯一判据，
它算错的后果是**在维护库上跑 DDL 却以为在临时库上**（codex 4a-2b/S1 R6-F2）。
"""
from __future__ import annotations

import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))

import _pilot_verify_harness as harness  # noqa: E402


def test_db_dsn_replaces_database_name():
    assert (harness.db_dsn("postgresql://u:p@127.0.0.1:5432/postgres", "scratch")
            == "postgresql://u:p@127.0.0.1:5432/scratch")


def test_db_dsn_does_not_touch_a_username_that_is_also_the_db_name():
    # 用户名也可能叫 `postgres` —— 按字符串替换会把它一起改掉。
    assert (harness.db_dsn("postgresql://postgres:p@h:5432/postgres", "scratch")
            == "postgresql://postgres:p@h:5432/scratch")


def test_db_dsn_keeps_query_parameters_that_contain_a_slash():
    """R6-F2 的回归：查询参数里带斜杠时，按最后一个 `/` 切会**不换库名**。

    旧实现返回 `postgresql://u:p@h:5432/postgres?sslrootcert=/scratch`——
    库名还是 postgres，调用方却以为自己连的是 scratch。
    """
    got = harness.db_dsn(
        "postgresql://u:p@h:5432/postgres?sslrootcert=/tmp/ca.crt", "scratch")
    assert got == "postgresql://u:p@h:5432/scratch?sslrootcert=/tmp/ca.crt"


def test_db_dsn_rejects_keyword_value_dsn_instead_of_guessing():
    # keyword/value 形态没有 path 分量 —— 猜错的代价是把探针指向别的库，故抛。
    with pytest.raises(AssertionError, match="URL 形态"):
        harness.db_dsn("host=127.0.0.1 port=5432 dbname=postgres", "scratch")


# ── 库名白名单扫描器（R9-F3）──────────────────────────────────────────────

def _scan(tmp_path, source: str, whitelist):
    f = tmp_path / "fake_verifier.py"
    f.write_text(source, encoding="utf-8")
    return harness.assert_every_selfcheck_db_is_whitelisted(
        f, whitelist, "kline_pilot_selfcheck")


def test_single_quoted_database_literal_cannot_bypass_the_whitelist(tmp_path):
    """R9-F3 的回归：旧扫描器是正则、只认**双引号**、只认 `[a-z0-9_]*` 的名字。

    `evil_db = 'kline_pilot_selfcheck_ev"il'` 单引号、名字里还带引号，
    整条从判据底下溜过去了 —— 而它是真的会被 `CREATE DATABASE` 建出来的。
    """
    src = "evil_db = 'kline_pilot_selfcheck_ev\"il'\n"
    assert _scan(tmp_path, src, ("kline_pilot_selfcheck_ok",)) == 5


def test_whitelisted_database_literal_is_allowed(tmp_path):
    # 正向对照：登记了就该放行，否则上一条在「扫描器恒拒」时也是绿的。
    src = "evil_db = 'kline_pilot_selfcheck_ev\"il'\n"
    assert _scan(tmp_path, src, ('kline_pilot_selfcheck_ev"il',)) is None


def test_prose_mentioning_the_prefix_is_not_mistaken_for_a_database_name(tmp_path):
    # 文档字符串里提到前缀不算库名 —— 判据是「这个字面量**就是**前缀底下的名字」。
    src = '"""本脚本会建/删 kline_pilot_selfcheck_* 库。"""\n'
    assert _scan(tmp_path, src, ()) is None


# ── 破坏性 DSN 闸（R7-F1）────────────────────────────────────────────────
# ⚠️ 每条用不同的 DSN 串：放行会把它记进模块级的 `_GUARDED_DSNS`，共用串会串味。

def test_local_dsn_is_refused_without_the_disposable_cluster_optin(monkeypatch):
    """R7-F1 的回归：**「本地」不是「可弃」**。

    旧实现把 localhost/127.0.0.1/::1 直接放行 —— DSN 打错一位端口指到本机真开发库，
    脚本会在「证明目标可弃」之前就建表、写标记、扫库删库、清凭据。
    """
    monkeypatch.delenv("QMT_VERIFY_ALLOW_DESTRUCTIVE", raising=False)
    monkeypatch.delenv("QMT_VERIFY_ALLOW_REMOTE", raising=False)
    assert harness.assert_destructive_dsn_allowed(
        "postgresql://u:p@127.0.0.1:5432/r7local", "DSN") is None


def test_local_dsn_passes_with_the_disposable_cluster_optin(monkeypatch):
    # 正向对照：健康输入必须被放行，否则上一条在「闸恒拒」时也是绿的。
    monkeypatch.setenv("QMT_VERIFY_ALLOW_DESTRUCTIVE", "1")
    monkeypatch.delenv("QMT_VERIFY_ALLOW_REMOTE", raising=False)
    dsn = "postgresql://u:p@127.0.0.1:5432/r7localok"
    assert harness.assert_destructive_dsn_allowed(dsn, "DSN") == dsn


def test_remote_dsn_needs_its_own_optin_on_top(monkeypatch):
    """两个变量各表达一件事：可弃 ≠ 允许打远端。

    共用一个变量的话，「本地也要设」一落地，人人常设它，远端那道闸就自动失效了。
    """
    monkeypatch.setenv("QMT_VERIFY_ALLOW_DESTRUCTIVE", "1")
    monkeypatch.delenv("QMT_VERIFY_ALLOW_REMOTE", raising=False)
    assert harness.assert_destructive_dsn_allowed(
        "postgresql://u:p@db.example.com:5432/r7remote", "DSN") is None

    monkeypatch.setenv("QMT_VERIFY_ALLOW_REMOTE", "1")
    dsn = "postgresql://u:p@db.example.com:5432/r7remoteok"
    assert harness.assert_destructive_dsn_allowed(dsn, "DSN") == dsn
