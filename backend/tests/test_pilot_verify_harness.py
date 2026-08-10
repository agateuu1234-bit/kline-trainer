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
