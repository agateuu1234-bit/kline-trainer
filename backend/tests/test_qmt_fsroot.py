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


# ---------------------------------------------------------------- Task 2: open_root
import errno
import os
from pathlib import Path
from qmt_fsroot import PathEscapeError, open_root


def test_open_root_pins_existing_dir(tmp_path: Path):
    d = tmp_path / "a" / "b"
    d.mkdir(parents=True)
    fd = open_root(str(d))
    try:
        assert os.fstat(fd).st_ino == d.stat().st_ino
    finally:
        os.close(fd)


def test_open_root_rejects_symlinked_intermediate_component(tmp_path: Path):
    # `O_NOFOLLOW` 只保护最后一段——中间分量被换成符号链接时，
    # 裸 os.open 会把 pin 钉在**另一棵树**上（spec §4.1 R75-F2）
    real = tmp_path / "real"
    (real / "leaf").mkdir(parents=True)
    (tmp_path / "link").symlink_to(real)
    with pytest.raises(PathEscapeError) as ei:
        open_root(str(tmp_path / "link" / "leaf"))
    assert ei.value.component == "link"
    # 本机实测：目录分量是符号链接得 ENOTDIR，**不是** ELOOP（O4-F12）
    assert ei.value.errno == errno.ENOTDIR


def test_open_root_escape_message_does_not_claim_symlink(tmp_path: Path):
    # ENOTDIR 与「这里放了个普通文件」不可区分，消息不得声称是符号链接（O4-F12）
    (tmp_path / "notadir").write_text("x")
    with pytest.raises(PathEscapeError) as ei:
        open_root(str(tmp_path / "notadir" / "leaf"))
    assert "可能是符号链接，也可能是个文件" in str(ei.value)
    assert ei.value.component == "notadir"


def test_open_root_missing_component_is_plain_filenotfound(tmp_path: Path):
    # 「不存在」不是「逃逸」——S5 的 CLI 要能把它翻译成「请先 mount_smbfs」
    with pytest.raises(FileNotFoundError):
        open_root(str(tmp_path / "nope"))


def test_open_root_tolerates_trailing_slash(tmp_path: Path):
    d = tmp_path / "a"
    d.mkdir()
    fd = open_root(str(d) + "/")
    try:
        assert os.fstat(fd).st_ino == d.stat().st_ino
    finally:
        os.close(fd)


# ------------------------------------------------- Task 3: open_root(create_leaf)
from qmt_fsroot import DirectoryExistsError


def test_open_root_create_leaf_creates_with_0700(tmp_path: Path):
    target = tmp_path / "dest"
    fd = open_root(str(target), create_leaf=True)
    try:
        assert target.is_dir()
        assert (target.stat().st_mode & 0o777) == 0o700
        assert os.fstat(fd).st_ino == target.stat().st_ino
    finally:
        os.close(fd)


def test_open_root_create_leaf_is_exclusive(tmp_path: Path):
    # mkdir 是**唯一可移植的目录级独占创建原语**；已存在即 EEXIST。
    # 绝不能用 os.rename 做「不覆盖发布」——POSIX 的 rename 在目标是**空目录**时
    # 会把目标**替换**掉，预建或并发抢建的空目录会被静默删除并认领（R64-F1）
    target = tmp_path / "dest"
    target.mkdir()
    with pytest.raises(DirectoryExistsError):
        open_root(str(target), create_leaf=True)


def test_open_root_create_leaf_exclusive_even_when_target_nonempty(tmp_path: Path):
    target = tmp_path / "dest"
    target.mkdir()
    (target / "x").write_text("y")
    with pytest.raises(DirectoryExistsError):
        open_root(str(target), create_leaf=True)
    assert (target / "x").read_text() == "y"   # 一个字节都没动


def test_open_root_create_leaf_rejects_symlinked_parent(tmp_path: Path):
    real = tmp_path / "real"
    real.mkdir()
    (tmp_path / "link").symlink_to(real)
    with pytest.raises(PathEscapeError):
        open_root(str(tmp_path / "link" / "dest"), create_leaf=True)
    assert not (real / "dest").exists()        # 没在别人的树里造目录


def test_open_root_create_leaf_rejects_root(tmp_path: Path):
    with pytest.raises(PathDisciplineError, match="至少一个分量"):
        open_root("/", create_leaf=True)


# ---------------------------------------------------------------- Task 4: open_under
from qmt_fsroot import open_under


def _read_fd(fd: int) -> bytes:
    with os.fdopen(os.dup(fd), "rb") as f:
        return f.read()


def test_open_under_reads_through_nested_dirs(tmp_path: Path):
    (tmp_path / "a" / "b").mkdir(parents=True)
    (tmp_path / "a" / "b" / "c.csv").write_bytes(b"hello")
    root = open_root(str(tmp_path))
    try:
        fd = open_under(root, "a/b/c.csv", flags=os.O_RDONLY)
        try:
            assert _read_fd(fd) == b"hello"
        finally:
            os.close(fd)
    finally:
        os.close(root)


def test_open_under_rejects_symlinked_intermediate_component(tmp_path: Path):
    # `dir_fd=` 只钉住**起点**、`O_NOFOLLOW` 只管**最后一段**：中间分量被换成外指
    # 链接时，fetch 会把 CSV 写到 staging 树**外面**，pilot 又会从树外读，
    # 而 staging_intact 的哈希对此**完全透明**（它读的是同一条被换过的路径，R74-F2）
    outside = tmp_path / "outside"
    outside.mkdir()
    inside = tmp_path / "root"
    inside.mkdir()
    (inside / "sub").symlink_to(outside)
    root = open_root(str(inside))
    try:
        with pytest.raises(PathEscapeError) as ei:
            open_under(root, "sub/x.csv", flags=os.O_RDONLY)
        assert ei.value.component == "sub"
        assert ei.value.errno == errno.ENOTDIR
    finally:
        os.close(root)


def test_open_under_leaf_symlink_gets_eloop(tmp_path: Path):
    # 叶子是**文件**符号链接、且不带 O_DIRECTORY → ELOOP（本机实测，O4-F12）
    (tmp_path / "real.csv").write_text("x")
    (tmp_path / "link.csv").symlink_to(tmp_path / "real.csv")
    root = open_root(str(tmp_path))
    try:
        with pytest.raises(PathEscapeError) as ei:
            open_under(root, "link.csv", flags=os.O_RDONLY)
        assert ei.value.errno == errno.ELOOP
    finally:
        os.close(root)


def test_open_under_create_dirs_makes_0700_and_is_idempotent(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        fd = open_under(root, "x/y/z.csv",
                        flags=os.O_CREAT | os.O_WRONLY, create_dirs=True)
        os.close(fd)
        assert (tmp_path / "x" / "y").is_dir()
        assert ((tmp_path / "x").stat().st_mode & 0o777) == 0o700
        # 第二次不得因目录已存在而失败
        fd = open_under(root, "x/y/z2.csv",
                        flags=os.O_CREAT | os.O_WRONLY, create_dirs=True)
        os.close(fd)
    finally:
        os.close(root)


def test_open_under_missing_leaf_is_plain_filenotfound(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        with pytest.raises(FileNotFoundError):
            open_under(root, "nope.json", flags=os.O_RDONLY)
    finally:
        os.close(root)


def test_open_under_rejects_bad_components(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        for bad in ("/abs/x", "a/../b", "a/./b", "a//b"):
            with pytest.raises(PathDisciplineError):
                open_under(root, bad, flags=os.O_RDONLY)
    finally:
        os.close(root)


def test_open_under_does_not_leak_intermediate_fds(tmp_path: Path):
    # 中间 fd 必须在 finally 里关掉（O4-F14 ②）：每次泄漏几个 fd 会让
    # 「staging 已被 rename 掉」这类分叉检查拿着陈旧 fd 继续成立
    (tmp_path / "a" / "b").mkdir(parents=True)
    (tmp_path / "a" / "b" / "c.csv").write_text("x")
    root = open_root(str(tmp_path))
    try:
        before = len(os.listdir("/dev/fd"))
        for _ in range(50):
            os.close(open_under(root, "a/b/c.csv", flags=os.O_RDONLY))
        after = len(os.listdir("/dev/fd"))
        assert after - before <= 2      # 允许 listdir 自身的抖动
    finally:
        os.close(root)


# ----------------------------------------------------------- Task 5: parent_fd_under
from qmt_fsroot import parent_fd_under


def test_parent_fd_under_returns_parent_and_leaf(tmp_path: Path):
    (tmp_path / "a" / "b").mkdir(parents=True)
    root = open_root(str(tmp_path))
    try:
        pfd, leaf = parent_fd_under(root, "a/b/c.csv")
        try:
            assert leaf == "c.csv"
            assert os.fstat(pfd).st_ino == (tmp_path / "a" / "b").stat().st_ino
        finally:
            os.close(pfd)
    finally:
        os.close(root)


def test_parent_fd_under_single_component_dups_root(tmp_path: Path):
    # 单分量时父目录**就是** root——必须返回 dup，否则调用方一关就把 root_fd 关掉了
    root = open_root(str(tmp_path))
    try:
        pfd, leaf = parent_fd_under(root, "manifest.json")
        assert leaf == "manifest.json"
        assert pfd != root
        os.close(pfd)
        os.fstat(root)                  # root 仍可用，没被连带关掉
    finally:
        os.close(root)


def test_parent_fd_under_supports_replace_and_unlink_and_fsync(tmp_path: Path):
    # 按股事务最关键的三个动作都要「父目录 fd + basename」（O2-F4）
    (tmp_path / "d").mkdir()
    (tmp_path / "d" / "x.csv.part").write_text("data")
    root = open_root(str(tmp_path))
    try:
        pfd, leaf = parent_fd_under(root, "d/x.csv")
        try:
            # ⚠️ 直接传 src_dir_fd/dst_dir_fd，不做 os.supports_dir_fd 能力探测：
            # 本机 `os.replace in os.supports_dir_fd` 为 False 而实际能跑通，
            # 写探测的实现会恰好退回被明令禁止的按路径改名（O4-F14）
            os.replace("x.csv.part", leaf, src_dir_fd=pfd, dst_dir_fd=pfd)
            assert (tmp_path / "d" / "x.csv").read_text() == "data"
            os.fsync(pfd)
            os.unlink(leaf, dir_fd=pfd)
            assert not (tmp_path / "d" / "x.csv").exists()
        finally:
            os.close(pfd)
    finally:
        os.close(root)


def test_parent_fd_under_rejects_symlinked_component(tmp_path: Path):
    # `.inflight.json` 的形状校验用 resolve()，而 **resolve() 会跟随符号链接**——
    # 逐段无跟随是最后一道防线，否则一条**破坏性恢复路径**会删到边界之外（O4-F14 ①）
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "victim.csv").write_text("someone elses data")
    inside = tmp_path / "root"
    inside.mkdir()
    (inside / "sub").symlink_to(outside)
    root = open_root(str(inside))
    try:
        with pytest.raises(PathEscapeError) as ei:
            parent_fd_under(root, "sub/victim.csv")
        assert ei.value.component == "sub"
    finally:
        os.close(root)
    assert (outside / "victim.csv").read_text() == "someone elses data"


def test_parent_fd_under_rejects_bad_components(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        for bad in ("/abs/x", "a/../b", "a/./b", "a//b", ""):
            with pytest.raises(PathDisciplineError):
                parent_fd_under(root, bad)
    finally:
        os.close(root)


def test_parent_fd_under_does_not_leak_intermediate_fds(tmp_path: Path):
    (tmp_path / "a" / "b").mkdir(parents=True)
    root = open_root(str(tmp_path))
    try:
        before = len(os.listdir("/dev/fd"))
        for _ in range(50):
            pfd, _leaf = parent_fd_under(root, "a/b/c.csv")
            os.close(pfd)
        after = len(os.listdir("/dev/fd"))
        assert after - before <= 2
    finally:
        os.close(root)


# --------------------------------------------------------------- Task 6: 耐久提交原语
import fcntl
from qmt_fsroot import fsync_dir, full_fsync


def test_fsync_dir_accepts_directory_fd(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        fsync_dir(root)          # 不抛即可（APFS 上 fsync(dirfd) 返回 0）
    finally:
        os.close(root)


def test_full_fsync_uses_F_FULLFSYNC_not_plain_fsync(tmp_path: Path, monkeypatch):
    # macOS `man 2 fsync` 明写 fsync **既不保证断电耐久、也不保证跨设备写序**
    # （"This is not a theoretical edge case."）。断电在威胁模型之内（O4-F11），
    # 故 manifest 提交与顺序屏障两处必须真的走 F_FULLFSYNC——
    # 用 fsync 写出来的「目录项丢失注入测试」绿灯**证明不了任何东西**。
    calls = []
    real_fcntl = fcntl.fcntl
    monkeypatch.setattr(
        fcntl, "fcntl",
        lambda fd, cmd, *a: (calls.append(cmd), real_fcntl(fd, cmd, *a))[1],
    )
    p = tmp_path / "f"
    p.write_text("x")
    fd = os.open(str(p), os.O_RDONLY)
    try:
        full_fsync(fd)
    finally:
        os.close(fd)
    assert calls == [fcntl.F_FULLFSYNC]


def test_full_fsync_command_constant_exists():
    assert hasattr(fcntl, "F_FULLFSYNC")     # 本机实测值 51
