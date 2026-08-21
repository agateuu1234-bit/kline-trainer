# backend/tests/test_qmt_fsroot.py
from __future__ import annotations
import pytest
from qmt_fsroot import (
    PathDisciplineError, normalize_abs_path, split_components, _split_rel,
)


def test_normalize_strips_trailing_slash_from_shell_completion():
    # shell 目录补全默认补出尾斜杠，而本项目的操作者不是程序员——
    # 尾斜杠必须在检查空分量**之前**被折叠掉（spec §4.1 O4-F17）
    assert normalize_abs_path("/Volumes/staging/") == "/Volumes/staging"
    assert normalize_abs_path("/Volumes/staging///") == "/Volumes/staging"


def test_normalize_collapses_duplicate_slashes():
    assert normalize_abs_path("//Volumes///QMT_Export//x") == "/Volumes/QMT_Export/x"


def test_normalize_rejects_relative_path():
    with pytest.raises(PathDisciplineError, match="绝对路径"):
        normalize_abs_path("Volumes/staging")


def test_normalize_rejects_dot_and_dotdot_with_distinct_message():
    # 「含 . / ..」与「含符号链接分量」两条提示必须分开（spec §4.1 O4-F17）
    with pytest.raises(PathDisciplineError, match=r"`\.` 或 `\.\.`"):
        normalize_abs_path("/Volumes/../etc")
    with pytest.raises(PathDisciplineError, match=r"`\.` 或 `\.\.`"):
        normalize_abs_path("/Volumes/./staging")


def test_normalize_root_stays_root():
    assert normalize_abs_path("/") == "/"


def test_split_components_root_is_empty_list():
    assert split_components("/") == []
    assert split_components("/a/b/c") == ["a", "b", "c"]


def test_split_rel_rejects_absolute_empty_dot_dotdot():
    assert _split_rel("a/b.csv") == ["a", "b.csv"]
    with pytest.raises(PathDisciplineError, match="相对路径"):
        _split_rel("/a/b.csv")
    for bad in ("a//b", "a/./b", "a/../b", ""):
        with pytest.raises(PathDisciplineError):
            _split_rel(bad)
