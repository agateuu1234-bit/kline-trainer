# backend/qmt_fsroot.py
"""文件系统信任边界地基（`--source` / `--dest` / `--output` 三个目录共用）。

Spec: docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md §4.1
      + §4.5 的「锁」与「耐久提交协议」两小节。
切片: docs/superpowers/specs/2026-08-21-qmt-plan4b-slice-map.md S1。

本模块**不认识**「staging」「output」「source」——它只提供受纪律约束的原语，
标记文件名、自指字段名、锁文件名全部由调用方参数化。
`--dest` 与 `--output` 的创建方式**同规格**，差异只有 `EEXIST` 那一档（R91-F2），
而那一档由调用方决定，本模块不替它们决定。
"""
from __future__ import annotations
import errno as _errno
import fcntl
import json
import os
import socket
import stat


class PathDisciplineError(ValueError):
    """路径字符串本身不合规：相对/绝对方向不对、或含 `.` / `..` / 空分量。"""


class PathEscapeError(Exception):
    """逐段无跟随时撞到**非目录分量**（符号链接或普通文件，本平台不可区分）。

    携带 manifest `fetch_fatal_error` 需要的三个字段（spec §4.5 要求四字段
    `{kind, relative_path, component, errno}`）；`kind` 由调用方按源侧/staging 侧补上。
    """

    def __init__(self, *, relative_path: str, component: str, errno: int):
        self.relative_path = relative_path
        self.component = component
        self.errno = errno
        code = _errno.errorcode.get(errno, str(errno))
        # ⚠️ 不得声称「这是符号链接」：ENOTDIR 与「这里放了个普通文件」不可区分（O4-F12）
        super().__init__(
            f"路径 {relative_path!r} 的分量 {component!r} 不是一个普通目录（{code}）："
            f"它可能是符号链接，也可能是个文件——两者在本平台给出同一个错误码。"
            f"本工具不替你解析符号链接，请改传完全解析后的绝对路径。"
        )


class DirectoryExistsError(Exception):
    """首次使用时目标路径已存在（`mkdirat` 撞 `EEXIST`）。

    **只证明目录存在，不证明里面有什么**——调用方须按各自规格处置（R91-F2）。
    """


class LockUnavailableError(Exception):
    """锁被另一个**活着的**进程持有（`flock` 取不到）。锁文件残留不算被持有（R48-F2）。"""


class LockDisciplineError(Exception):
    """锁文件不是普通文件（符号链接或其它类型）——拒绝启动，一个字节都不写（R72-F2）。"""


class MarkerInvalidError(Exception):
    """归属标记不存在 / 非法 JSON / 字段不符。"""


def normalize_abs_path(raw: str) -> str:
    """入口处的**纯字符串**规范化：去尾斜杠、折叠重复 `/`。**绝不 `realpath()`**（O4-F17）。

    尾斜杠必须在检查空分量**之前**折叠掉：shell 目录补全默认补出尾斜杠，
    `--dest /Volumes/staging/` 是操作者最常见的输入，而本项目的操作者不是程序员。
    「含 `.` / `..`」与「含符号链接分量」两条提示必须分开——后者由逐段 open 时抛
    `PathEscapeError` 给出。
    """
    if not raw.startswith("/"):
        raise PathDisciplineError(f"必须是绝对路径（以 / 开头），收到 {raw!r}")
    parts = [p for p in raw.split("/") if p != ""]
    if any(p in (".", "..") for p in parts):
        raise PathDisciplineError(
            f"路径不得含 `.` 或 `..` 分量，收到 {raw!r}"
            f"（本工具不做路径解析——请传一条已经展开好的绝对路径）"
        )
    return "/" + "/".join(parts)


def split_components(path: str) -> list[str]:
    """规范化后的绝对路径 → 分量列表。`/` 得 `[]`。"""
    return [p for p in normalize_abs_path(path).split("/") if p != ""]


def _split_rel(relpath: str) -> list[str]:
    """相对路径 → 分量。与 `open_root` **同一套分量规则**（O4-F14 ①）：
    拒绝绝对路径 / 空分量 / `.` / `..`。

    相对路径是本工具内部构造的（不是操作者敲的），故这里**不**做尾斜杠宽容——
    出现空分量就是构造方的 bug，应当立刻炸出来。
    """
    if relpath.startswith("/"):
        raise PathDisciplineError(f"必须是相对路径，收到 {relpath!r}")
    parts = relpath.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise PathDisciplineError(
            f"相对路径不得含空分量 / `.` / `..`，收到 {relpath!r}"
        )
    return parts


def _raise_walk_error(relative_path: str, component: str, exc: OSError):
    """逐段走时的错误分流：只有 `ELOOP` / `ENOTDIR` 算**逃逸**，其余原样上抛。

    `ENOENT` 尤其不能算逃逸——「路径不存在」与「路径被换成了符号链接」是两件事，
    前者是操作者忘了挂载（spec §5 要求提示 `mount_smbfs`），后者是信任边界被绕过。
    """
    if exc.errno in (_errno.ELOOP, _errno.ENOTDIR):
        raise PathEscapeError(
            relative_path=relative_path, component=component, errno=exc.errno
        ) from exc
    raise exc


def open_root(abs_path: str, *, create_leaf: bool = False) -> int:
    """从 `/` 起**逐分量** `O_DIRECTORY|O_NOFOLLOW` 打开，返回叶子目录的 fd（调用方全程持有）。

    `O_NOFOLLOW` **只保护最后一段**——`/a/b/out` 里 `a`、`b` 若是符号链接（或在 pin 之前
    被换成符号链接），内核照样跟随，于是被钉住的是**另一棵树**的 inode，此后所有 `*at`
    纪律都忠实地作用在**错的目录**上。**pin 本身是这套边界的起点，起点被绕过则
    其后一切纪律归零**（R75-F2）。**不做 `realpath()`**——那正是「跟随」。

    `create_leaf=True`（首次使用/认领）：逐段走到**父目录**后用 `os.mkdir(dir_fd=父fd)`
    **独占创建**叶子——`mkdir` 是**唯一可移植的目录级排他原语**，已存在即 `EEXIST`；
    而逐段走保证「独占创建」发生在**验过的那个父 inode** 里（R75-F2）。
    创建成功后 `fsync` 父目录（耐久提交协议：`mkdir` 改的是目录项，
    而目录项的持久化不由文件的 `fsync` 保证，R45-F2）。

    ⚠️ **绝不用 `os.rename` 做「不覆盖发布」**：POSIX 的 `rename(2)` 在「源是目录、
    目标是**空目录**」时**会把目标替换掉**（macOS 同此），于是一个预先建好的空目录
    会被静默删除并认领（R64-F1）。
    """
    comps = split_components(abs_path)
    if create_leaf and not comps:
        raise PathDisciplineError("create_leaf 需要至少一个分量，不能对 `/` 用")
    dirs = comps[:-1] if create_leaf else comps
    leaf = comps[-1] if create_leaf else None
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for d in dirs:
            try:
                nxt = os.open(
                    d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
                )
            except OSError as e:
                _raise_walk_error(abs_path, d, e)
            os.close(fd)
            fd = nxt
        if create_leaf:
            try:
                os.mkdir(leaf, 0o700, dir_fd=fd)
            except FileExistsError as e:
                raise DirectoryExistsError(
                    f"路径已存在：{abs_path}。"
                    f"`EEXIST` 只证明**目录**存在，不证明它属于本工具——"
                    f"处置由调用方按各自规格决定（R91-F2）。"
                ) from e
            try:
                nxt = os.open(
                    leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
                )
            except OSError as e:
                _raise_walk_error(abs_path, leaf, e)
            os.fsync(fd)          # 父目录耐久（R45-F2）
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


def open_under(root_fd: int, relpath: str, *, flags: int, mode: int = 0o600,
               create_dirs: bool = False) -> int:
    """相对 `root_fd` **逐分量**无跟随打开，返回叶子的 fd（调用方负责关）。

    **`dir_fd=` 只保证起点、`O_NOFOLLOW` 只作用于最后一段**——中间的 `a` 或 `b`
    是符号链接时，内核照样跟随。于是一棵被复用的 staging 里，只要
    `1分钟K线_前复权` 被换成指向 staging 之外的链接，`qmt_fetch` 就会把 `.part`/CSV
    **写到 staging 树外面**，随后 pilot 又会**从树外面读**，而全套 `staging_intact`
    哈希校验查的是「同一条路径读回来的字节」——**换过的分量对它完全透明**（R74-F2）。

    `create_dirs=True` 只创建本工具自己的目录（`0o700`），**且只在 `mkdir` 真的成功时**
    才 `fsync` 其父目录（O2-F3）——子目录创建也是一次命名空间改动，漏掉会让
    manifest 已提交「文件在该目录下」而**目录项没落地**：重启后记录在、文件与目录都不在，
    既不是 `untracked_target_file`（那要求文件存在）也回收不了（R84-F2）。

    只有 `ELOOP` / `ENOTDIR` 算逃逸；`ENOENT` 原样上抛为 `FileNotFoundError`
    （「不存在」与「被换掉」是两件事）。
    """
    *dirs, leaf = _split_rel(relpath)
    cur = root_fd
    opened: list[int] = []
    try:
        for d in dirs:
            if create_dirs:
                try:
                    os.mkdir(d, 0o700, dir_fd=cur)
                except FileExistsError:
                    pass
                else:
                    os.fsync(cur)      # 新建成功才 fsync 父目录（O2-F3 / R84-F2）
            try:
                nxt = os.open(
                    d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur
                )
            except OSError as e:
                _raise_walk_error(relpath, d, e)
            opened.append(nxt)
            cur = nxt
        try:
            return os.open(leaf, flags | os.O_NOFOLLOW, mode, dir_fd=cur)
        except OSError as e:
            _raise_walk_error(relpath, leaf, e)
    finally:
        for fd in opened:
            os.close(fd)


def parent_fd_under(root_fd: int, relpath: str) -> tuple[int, str]:
    """逐分量无跟随走到 `relpath` 的**父目录**，返回 `(parent_fd, leaf)`。

    **为什么需要它**：`open_under` 只能 `open()`，而按股事务里最关键的三个动作——
    `os.replace(.part → final)`、回滚 `unlink`、对子目录 `fsync`——都要
    **父目录 fd + basename**（O2-F4）。实施者最自然的写法 `os.unlink(str(staging / rel))`
    会让 `.inflight.json` 的形状校验（只要求 `resolve()` 后落在 staging 之内，
    而 **`resolve()` 会跟随符号链接**）放行一条**破坏性恢复路径**删到边界之外。

    与 `open_under` 同规格三条（O4-F14）：
      ① 分量规则相同（拒空分量 / `.` / `..`，逐段 `O_DIRECTORY|O_NOFOLLOW`）；
      ② 中间 fd 在 `finally` 里关掉，**返回的 `parent_fd` 归调用方、用完必须关**
         ——每股泄漏 3~4 个 fd 会让「staging 已被 rename 掉」这类分叉检查
         拿着陈旧 fd 继续成立；
      ③ 恢复路径上撞逃逸的处置由调用方决定（S4：不删任何文件、保留 `.inflight.json`、
         记 `stopped_reason: staging_path_escape` 后 rc≠0）。

    ⚠️ 单分量时父目录**就是** `root_fd`，故一律返回 `os.dup(root_fd)`——
    否则调用方一关就把根 fd 连带关掉了。
    """
    *dirs, leaf = _split_rel(relpath)
    cur = root_fd
    opened: list[int] = []
    try:
        for d in dirs:
            try:
                nxt = os.open(
                    d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur
                )
            except OSError as e:
                _raise_walk_error(relpath, d, e)
            opened.append(nxt)
            cur = nxt
        return os.dup(cur), leaf
    finally:
        for fd in opened:
            os.close(fd)


def fsync_dir(dir_fd: int) -> None:
    """命名空间改动（`os.replace` / `os.mkdir` / `unlink`）之后 `fsync` 其所在目录。

    **目录项的持久化不由文件的 `fsync` 保证**：断电后文件系统完全可能只持久化了
    rename、没持久化 manifest 的 replace（或反过来）——于是重启后 staging 里躺着两个
    final 文件而 manifest 无记录，正是按股事务要消灭的那个状态（R45-F2）。
    「原子」（`os.replace` 不会看到半截）与「耐久」（崩溃后仍在）是两件事。
    """
    os.fsync(dir_fd)


def full_fsync(fd: int) -> None:
    """`fcntl(fd, F_FULLFSYNC)` —— 本平台唯一把字节真正推到盘上的调用。

    macOS `man 2 fsync` 原文：「if the drive loses power or the OS crashes, the
    application may find that only some or none of their data was written.
    The disk drive may also **re-order** the data … **This is not a theoretical
    edge case.**」——即 `fsync` 在本平台上**既不保证断电耐久、也不保证跨设备写序**。

    **定案：断电在威胁模型之内**（O4-F11）。故 **manifest 提交**与
    **回滚时那道顺序屏障**两处用本函数（每股 1~2 次，400 股量级完全可接受），
    其余落地点保留 `fsync_dir` / `os.fsync`。
    （实测：`fsync(dirfd)` 在本机 APFS 上返回 0，**不会有任何报错提示这层保证并不存在**。）
    """
    fcntl.fcntl(fd, fcntl.F_FULLFSYNC)


def acquire_lock(dir_fd: int, lock_name: str, *, tool: str) -> int:
    """取得目录生命周期锁，返回锁 fd（调用方全程持有到最后一次提交之后）。

    **锁由内核持有，进程无论正常退出还是被杀都自动释放**（R48-F2）。
    **锁文件残留不构成拒绝**——唯一判据是 `flock` 能否取得，也**不得提示人工删锁**：
    存在性锁（`O_CREAT|O_EXCL`）的释放靠「进程记得删文件」，而 `kill -9` / 断电时
    它删不掉，会与「执行阶段中途崩溃」叠成**死锁**。

    序列：`openat(O_CREAT|O_RDWR|O_NOFOLLOW, 0o600)` → `fstat` 确认**普通文件**
    → `flock(LOCK_EX|LOCK_NB)` → 写持有者信息。
    `ELOOP` 或类型不符 → `LockDisciplineError`（拒绝启动，**一个字节都不写**，R72-F2）。

    持有者信息（pid / 主机名 / 工具名）**仅供人读诊断，不参与任何判定**。
    锁文件本身**不进耐久提交协议的闭合清单**（显式豁免：它存在与否不参与判定，
    丢了下次重建即可）。
    """
    try:
        lock_fd = open_under(
            dir_fd, lock_name, flags=os.O_CREAT | os.O_RDWR, mode=0o600
        )
    except PathEscapeError as e:
        raise LockDisciplineError(
            f"锁文件 {lock_name!r} 不是普通文件（{e}）——拒绝启动，一个字节都不写。"
        ) from e
    except IsADirectoryError as e:
        # ⚠️ 锁名被一个**目录**占住时，`open(O_CREAT|O_RDWR)` 在 `fstat` 之前就抛
        # `EISDIR` —— 下面那道 `S_ISREG` 检查**根本够不着**。spec R72-F2 只写了
        # 「ELOOP 或 fstat 类型不符」，照字面实现会在这一档漏出裸 traceback。
        # （`S_ISREG` 仍然是活的：FIFO 能被 `O_RDWR` 打开成功，由它拦下。）
        raise LockDisciplineError(
            f"锁文件 {lock_name!r} 存在但是一个目录——拒绝启动，一个字节都不写。"
        ) from e
    try:
        if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
            raise LockDisciplineError(
                f"锁文件 {lock_name!r} 存在但不是普通文件——拒绝启动。"
            )
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            raise LockUnavailableError(
                f"{lock_name!r} 正被另一次运行持有，请等待或确认。"
                f"（锁由内核持有、进程死亡即释放，**不需要也不应该手工删锁**）"
            ) from e
        os.ftruncate(lock_fd, 0)
        os.lseek(lock_fd, 0, os.SEEK_SET)
        os.write(lock_fd, json.dumps(
            {"tool": tool, "pid": os.getpid(), "hostname": socket.gethostname()},
            ensure_ascii=False,
        ).encode("utf-8"))
        return lock_fd
    except BaseException:
        os.close(lock_fd)
        raise
