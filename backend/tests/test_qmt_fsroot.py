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


# ------------------------------------------------------------- Task 7: acquire_lock
import json
import subprocess
import sys
from qmt_fsroot import LockDisciplineError, LockUnavailableError, acquire_lock


def test_acquire_lock_succeeds_and_writes_human_readable_holder(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        lk = acquire_lock(root, ".staging.lock", tool="qmt_fetch")
        try:
            info = json.loads((tmp_path / ".staging.lock").read_text())
            # 持有者信息**仅供人读诊断，不参与判定**（R48-F2）
            assert info["tool"] == "qmt_fetch"
            assert info["pid"] == os.getpid()
            assert "hostname" in info
        finally:
            os.close(lk)
    finally:
        os.close(root)


def test_acquire_lock_is_exclusive_across_processes(tmp_path: Path):
    root = open_root(str(tmp_path))
    lk = acquire_lock(root, ".staging.lock", tool="qmt_fetch")
    try:
        script = (
            "import fcntl, os, sys\n"
            f"fd = os.open({str(tmp_path / '.staging.lock')!r}, os.O_RDWR)\n"
            "try:\n"
            "    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
            "    sys.exit(0)\n"
            "except OSError:\n"
            "    sys.exit(3)\n"
        )
        r = subprocess.run([sys.executable, "-c", script])
        assert r.returncode == 3          # 另一个**进程**确实拿不到
    finally:
        os.close(lk)
        os.close(root)


def test_lock_released_when_holder_process_dies(tmp_path: Path):
    # 锁由**内核**持有，进程无论正常退出还是被杀都自动释放；
    # 存在性锁（O_CREAT|O_EXCL）会与「执行阶段中途崩溃」叠成**死锁**：
    # 每次重跑都卡在取锁那一步，只能人工删锁（R48-F2 / §9-5n）
    script = (
        "import fcntl, os\n"
        f"fd = os.open({str(tmp_path / '.staging.lock')!r}, os.O_CREAT | os.O_RDWR, 0o600)\n"
        "fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
        "os.kill(os.getpid(), 9)\n"
    )
    subprocess.run([sys.executable, "-c", script])
    assert (tmp_path / ".staging.lock").exists()     # 锁文件**残留**了
    root = open_root(str(tmp_path))
    try:
        lk = acquire_lock(root, ".staging.lock", tool="qmt_fetch")   # 照样取得
        os.close(lk)
    finally:
        os.close(root)


def test_acquire_lock_refuses_symlinked_lock_file(tmp_path: Path):
    # 锁文件在直觉里像「临时协调物」，恰恰因此被漏掉；
    # 凡本工具会写入的路径，无论承载数据还是协调状态，都过同一套符号链接纪律（R72-F2）
    outside = tmp_path / "outside.lock"
    outside.write_text("")
    inside = tmp_path / "root"
    inside.mkdir()
    (inside / ".staging.lock").symlink_to(outside)
    root = open_root(str(inside))
    try:
        with pytest.raises(LockDisciplineError):
            acquire_lock(root, ".staging.lock", tool="qmt_fetch")
    finally:
        os.close(root)
    assert outside.read_text() == ""       # 一个字节都没写进去


def test_acquire_lock_refuses_non_regular_lock_file(tmp_path: Path):
    (tmp_path / ".staging.lock").mkdir()
    root = open_root(str(tmp_path))
    try:
        with pytest.raises(LockDisciplineError):
            acquire_lock(root, ".staging.lock", tool="qmt_fetch")
    finally:
        os.close(root)


def test_acquire_lock_raises_when_held(tmp_path: Path):
    root = open_root(str(tmp_path))
    lk = acquire_lock(root, ".staging.lock", tool="qmt_fetch")
    root2 = open_root(str(tmp_path))
    try:
        with pytest.raises(LockUnavailableError):
            acquire_lock(root2, ".staging.lock", tool="qmt_fetch")
    finally:
        os.close(lk)
        os.close(root)
        os.close(root2)


# ------------------------------------------------------- Task 8: probe_unclaimed_dir
from qmt_fsroot import probe_unclaimed_dir


def test_probe_vacuum_when_lock_file_absent(tmp_path: Path):
    # 崩在 mkdir 与建锁文件之间留下的**真空目录**，
    # 也是**唯一 rmdir 能干净成功的一档**（O4-F6）
    root = open_root(str(tmp_path))
    try:
        assert probe_unclaimed_dir(root, ".staging.lock") == "vacuum"
    finally:
        os.close(root)


def test_probe_busy_when_lock_held_by_another_process(tmp_path: Path):
    lockpath = tmp_path / ".staging.lock"
    proc = subprocess.Popen(
        [sys.executable, "-c",
         "import fcntl, os, sys, time\n"
         f"fd = os.open({str(lockpath)!r}, os.O_CREAT | os.O_RDWR, 0o600)\n"
         "fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
         "sys.stdout.write('held'); sys.stdout.flush()\n"
         "time.sleep(30)\n"],
        stdout=subprocess.PIPE)
    try:
        assert proc.stdout.read(4) == b"held"
        root = open_root(str(tmp_path))
        try:
            # 取不到锁 → 「另一次运行正在认领该目录」，**绝不建议 rmdir**（O2-F9）
            assert probe_unclaimed_dir(root, ".staging.lock") == "busy"
        finally:
            os.close(root)
    finally:
        proc.kill()
        proc.wait()


def test_probe_stale_when_lock_file_present_but_free(tmp_path: Path):
    (tmp_path / ".staging.lock").write_text("{}")
    root = open_root(str(tmp_path))
    try:
        assert probe_unclaimed_dir(root, ".staging.lock") == "stale"
    finally:
        os.close(root)


def test_probe_never_creates_the_lock_file(tmp_path: Path):
    # ⚠️ 带 O_CREAT 会在一个**已被证明不属于我们的目录**里造文件——
    # `--dest` 打错成 /Users/me/Documents 时，工具先落下 .staging.lock，
    # 然后建议 rmdir，而 rmdir 恰恰因为我们刚造的这个文件而 ENOTEMPTY，
    # **修复指引自己把自己堵死**；真正的残骸空目录也再 rmdir 不掉（P2-F1）
    root = open_root(str(tmp_path))
    try:
        assert probe_unclaimed_dir(root, ".staging.lock") == "vacuum"
    finally:
        os.close(root)
    assert list(tmp_path.iterdir()) == []          # 目录仍然是空的


def test_probe_rejects_symlinked_lock_file(tmp_path: Path):
    outside = tmp_path / "outside.lock"
    outside.write_text("")
    inside = tmp_path / "root"
    inside.mkdir()
    (inside / ".staging.lock").symlink_to(outside)
    root = open_root(str(inside))
    try:
        with pytest.raises(LockDisciplineError):
            probe_unclaimed_dir(root, ".staging.lock")
    finally:
        os.close(root)


def test_probe_rejects_directory_lock_name(tmp_path: Path):
    (tmp_path / ".staging.lock").mkdir()
    root = open_root(str(tmp_path))
    try:
        with pytest.raises(LockDisciplineError):
            probe_unclaimed_dir(root, ".staging.lock")
    finally:
        os.close(root)


# ------------------------------------------------------------------ Task 9: 归属标记
import shutil
from qmt_fsroot import MarkerInvalidError, verify_owner_marker, write_owner_marker


def test_write_and_verify_dest_marker(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        write_owner_marker(root, ".staging_owner.json",
                           {"tool": "qmt_fetch", "seed": "s1", "dest": str(tmp_path)})
        got = verify_owner_marker(root, ".staging_owner.json",
                                  expect_tool="qmt_fetch",
                                  self_field="dest", self_value=str(tmp_path))
        assert got["seed"] == "s1"
    finally:
        os.close(root)


def test_same_primitive_expresses_output_marker(tmp_path: Path):
    # 同一套原语必须能表达 --output 的第 1 层（tool + output_dir 自指），
    # 差异只有 EEXIST 那一档（由调用方决定，不在本模块）
    root = open_root(str(tmp_path))
    try:
        write_owner_marker(root, ".pilot_output.json",
                           {"tool": "qmt_pilot", "output_dir": str(tmp_path),
                            "seed": "s1", "export_log_sha256": "a" * 64})
        got = verify_owner_marker(root, ".pilot_output.json",
                                  expect_tool="qmt_pilot",
                                  self_field="output_dir", self_value=str(tmp_path))
        # 第 2 层（seed + export_log_sha256）**必须等到 manifest 校验通过之后**才验，
        # 不在本模块（R31-F1）——这里只把整份内容交回去
        assert got["export_log_sha256"] == "a" * 64
    finally:
        os.close(root)


def test_verify_rejects_wrong_tool(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        write_owner_marker(root, ".staging_owner.json",
                           {"tool": "qmt_pilot", "dest": str(tmp_path)})
        with pytest.raises(MarkerInvalidError, match="tool"):
            verify_owner_marker(root, ".staging_owner.json", expect_tool="qmt_fetch",
                                self_field="dest", self_value=str(tmp_path))
    finally:
        os.close(root)


def test_verify_rejects_marker_moved_wholesale(tmp_path: Path):
    # 自指字段的全部意义：防标记被**整体搬走**到另一个目录还继续生效
    a = tmp_path / "a"
    a.mkdir()
    b = tmp_path / "b"
    b.mkdir()
    root_a = open_root(str(a))
    try:
        write_owner_marker(root_a, ".staging_owner.json",
                           {"tool": "qmt_fetch", "dest": str(a)})
    finally:
        os.close(root_a)
    shutil.copy(a / ".staging_owner.json", b / ".staging_owner.json")
    root_b = open_root(str(b))
    try:
        with pytest.raises(MarkerInvalidError, match="dest"):
            verify_owner_marker(root_b, ".staging_owner.json", expect_tool="qmt_fetch",
                                self_field="dest", self_value=str(b))
    finally:
        os.close(root_b)


def test_verify_rejects_missing_and_malformed(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        with pytest.raises(MarkerInvalidError):
            verify_owner_marker(root, ".staging_owner.json", expect_tool="qmt_fetch",
                                self_field="dest", self_value=str(tmp_path))
        (tmp_path / ".staging_owner.json").write_text("{not json")
        with pytest.raises(MarkerInvalidError):
            verify_owner_marker(root, ".staging_owner.json", expect_tool="qmt_fetch",
                                self_field="dest", self_value=str(tmp_path))
    finally:
        os.close(root)


def test_write_owner_marker_leaves_no_tmp_behind(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        write_owner_marker(root, ".staging_owner.json",
                           {"tool": "qmt_fetch", "dest": str(tmp_path)})
    finally:
        os.close(root)
    assert sorted(p.name for p in tmp_path.iterdir()) == [".staging_owner.json"]


def test_write_owner_marker_refuses_symlink_target(tmp_path: Path):
    outside = tmp_path / "outside.json"
    outside.write_text("{}")
    inside = tmp_path / "root"
    inside.mkdir()
    (inside / ".staging_owner.json").symlink_to(outside)
    root = open_root(str(inside))
    try:
        # 一个名字对得上的符号链接会让写入**跟出目录**，把归属判定整个绕过去（R13-F2）
        with pytest.raises(PathEscapeError):
            write_owner_marker(root, ".staging_owner.json",
                               {"tool": "qmt_fetch", "dest": str(inside)})
    finally:
        os.close(root)
    assert outside.read_text() == "{}"


# ---------------------------------------------------------------- Task 10: claim_dir
from qmt_fsroot import claim_dir


def test_claim_dir_creates_locks_and_marks(tmp_path: Path):
    target = tmp_path / "dest"
    dir_fd, lock_fd = claim_dir(
        str(target), lock_name=".staging.lock", marker_name=".staging_owner.json",
        marker_payload={"tool": "qmt_fetch", "seed": "s1", "dest": str(target)},
        tool="qmt_fetch",
    )
    try:
        assert target.is_dir()
        assert (target / ".staging_owner.json").exists()
        assert (target / ".staging.lock").exists()
        got = verify_owner_marker(dir_fd, ".staging_owner.json", expect_tool="qmt_fetch",
                                  self_field="dest", self_value=str(target))
        assert got["seed"] == "s1"
    finally:
        os.close(lock_fd)
        os.close(dir_fd)


def test_claim_dir_takes_lock_before_publishing_ownership(tmp_path: Path, monkeypatch):
    # R97-F2：取锁必须早于发布归属。若顺序反了，两个 qmt_fetch 能同时
    # 往一棵 staging 里写（其中一个刚写完标记还没取到锁）
    order = []
    import qmt_fsroot as M
    real_lock, real_mark = M.acquire_lock, M.write_owner_marker
    monkeypatch.setattr(
        M, "acquire_lock",
        lambda *a, **k: (order.append("lock"), real_lock(*a, **k))[1])
    monkeypatch.setattr(
        M, "write_owner_marker",
        lambda *a, **k: (order.append("marker"), real_mark(*a, **k))[1])
    target = tmp_path / "dest"
    dir_fd, lock_fd = claim_dir(
        str(target), lock_name=".staging.lock", marker_name=".staging_owner.json",
        marker_payload={"tool": "qmt_fetch", "dest": str(target)}, tool="qmt_fetch")
    try:
        assert order == ["lock", "marker"]
    finally:
        os.close(lock_fd)
        os.close(dir_fd)


def test_claim_dir_raises_directory_exists_and_writes_nothing(tmp_path: Path):
    # 撞 EEXIST 时**一个字节都不写**——处置由调用方按各自规格决定（R91-F2）：
    # --dest 有合法标记 → 退回复用路径的完整准入序列；--output → 一律拒绝
    target = tmp_path / "dest"
    target.mkdir()
    with pytest.raises(DirectoryExistsError):
        claim_dir(str(target), lock_name=".staging.lock",
                  marker_name=".staging_owner.json",
                  marker_payload={"tool": "qmt_fetch", "dest": str(target)},
                  tool="qmt_fetch")
    assert list(target.iterdir()) == []


def test_claim_dir_leaves_nothing_when_lock_unavailable(tmp_path: Path, monkeypatch):
    import qmt_fsroot as M

    def boom(*a, **k):
        raise LockUnavailableError("held")

    monkeypatch.setattr(M, "acquire_lock", boom)
    target = tmp_path / "dest"
    with pytest.raises(LockUnavailableError):
        claim_dir(str(target), lock_name=".staging.lock",
                  marker_name=".staging_owner.json",
                  marker_payload={"tool": "qmt_fetch", "dest": str(target)},
                  tool="qmt_fetch")
    # 目录已被 mkdir 出来（不可避免），但**没有标记** → 下次启动会走 probe 的
    # "vacuum" 分支，拿到唯一能干净 rmdir 的那一档指引
    assert target.is_dir() and list(target.iterdir()) == []


# ------------------------------------------------------------- Task 11: 三条边界判据
from qmt_fsroot import (
    BoundaryError, assert_distinct_inodes, assert_fd_still_at,
    assert_no_path_overlap, assert_readonly_fd,
)


def test_assert_readonly_fd_rejects_writable_dir(tmp_path: Path):
    # 非写入式判据：statvfs 问内核要挂载标志。
    # ⚠️ 禁止用「试写一个临时文件」探测——那种主动探测在**恰恰是它要防的
    # 那个危险场景里**（共享真的可写）会由本工具**亲手去写权威导出共享**，
    # 探测成功即污染（R5-F3）
    rw = open_root(str(tmp_path))
    try:
        with pytest.raises(BoundaryError, match="只读"):
            assert_readonly_fd(rw, label="--source")
    finally:
        os.close(rw)


@pytest.mark.skipif(not (os.statvfs("/").f_flag & os.ST_RDONLY),
                    reason="本机根卷不是只读挂载（macOS SSV 之外的平台）")
def test_assert_readonly_fd_accepts_readonly_volume():
    # ⚠️ 本判据只证明「这是某个只读目录」：本机根卷 / 自己就是 apfs … read-only，
    # 「只读」在 macOS 上**区分不出网络共享与本地卷**（R19-F2，已实测）
    ro = open_root("/")
    try:
        assert_readonly_fd(ro, label="--source")
    finally:
        os.close(ro)


def test_assert_no_path_overlap_rejects_equal_and_subtree(tmp_path: Path):
    src = tmp_path / "src"
    src.mkdir()
    (src / "inner").mkdir()
    dest = tmp_path / "dest"
    dest.mkdir()
    assert_no_path_overlap({"--source": str(src), "--dest": str(dest)})
    with pytest.raises(BoundaryError):
        assert_no_path_overlap({"--source": str(src), "--dest": str(src)})
    with pytest.raises(BoundaryError):
        # 否则一旦源挂载是可写的，qmt_fetch 会把锁/manifest/.part/CSV
        # **写进那个权威导出共享里**，污染的正是本次要取证的数据集（R4-F4）
        assert_no_path_overlap({"--source": str(src), "--dest": str(src / "inner")})
    with pytest.raises(BoundaryError):
        assert_no_path_overlap({"--source": str(src / "inner"), "--dest": str(src)})


def test_assert_no_path_overlap_is_not_fooled_by_sibling_prefix(tmp_path: Path):
    # /a/srcx 不是 /a/src 的子树——字符串前缀比较会误判
    (tmp_path / "src").mkdir()
    (tmp_path / "srcx").mkdir()
    assert_no_path_overlap({"--source": str(tmp_path / "src"),
                            "--dest": str(tmp_path / "srcx")})


def test_assert_distinct_inodes_catches_symlink_aliased_dirs(tmp_path: Path):
    # 路径判据可被换掉，inode 判据不会（R84-F1）
    real = tmp_path / "real"
    real.mkdir()
    (tmp_path / "alias").symlink_to(real)
    a = open_root(str(real))
    b = os.open(str(tmp_path / "alias"), os.O_RDONLY | os.O_DIRECTORY)
    try:
        with pytest.raises(BoundaryError):
            assert_distinct_inodes({"--source": a, "--dest": b})
    finally:
        os.close(a)
        os.close(b)


def test_assert_fd_still_at_detects_swapped_directory(tmp_path: Path):
    d = tmp_path / "staging"
    d.mkdir()
    fd = open_root(str(d))
    try:
        assert_fd_still_at(str(d), fd, label="--dest")
        d.rename(tmp_path / "moved")
        (tmp_path / "staging").mkdir()       # 有人在原路径上放了另一棵树
        with pytest.raises(BoundaryError, match="--dest"):
            assert_fd_still_at(str(d), fd, label="--dest")
    finally:
        os.close(fd)
