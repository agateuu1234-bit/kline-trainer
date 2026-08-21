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


__all__ = [
    # 异常
    "PathDisciplineError", "PathEscapeError", "DirectoryExistsError",
    "LockUnavailableError", "LockDisciplineError", "MarkerInvalidError",
    "BoundaryError",
    # 路径规则
    "normalize_abs_path", "split_components",
    # 逐段无跟随
    "open_root", "open_under", "parent_fd_under",
    # 耐久提交
    "fsync_dir", "full_fsync",
    # 锁
    "acquire_lock", "probe_unclaimed_dir", "assert_lock_still_held",
    # 归属
    "write_owner_marker", "verify_owner_marker", "claim_dir",
    # 边界判据
    "assert_readonly_fd", "assert_no_path_overlap",
    "assert_distinct_inodes", "assert_fd_still_at",
]


# 归属标记的序列化上限。标记只有寥寥几个字段（`tool` + 自指路径 + `seed` +
# 可选的 `export_log_sha256`），64 KiB 是宽松到不可能误伤的量级。
# **它是安全上限，不是性能调优**（R6-codex-high）：标记是**不可信输入**——
# 它决定一个已存在的目录可不可信——读到 EOF 为止意味着一个被植入的几 GB 文件
# 能把进程 OOM 掉，而不是得到一个干净的 `MarkerInvalidError`。
_MARKER_MAX_BYTES = 64 * 1024


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


class BoundaryError(Exception):
    """信任边界判据不过（只读 / 路径重叠 / inode 不符）。"""


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


def _assert_freshly_created(dir_fd: int, abs_path: str) -> None:
    """`mkdir` 与随后的 `open` 是**两次按名字的独立查找**——中间那道缝无法用 POSIX 关掉
    （没有「建目录并直接拿到 fd」的原子原语）。本检查**不关闭竞态，只把伤害限死**：
    调包进来的必须是**空的、0700、属于本用户**的目录，否则拒绝。

    于是 finding 描述的那种伤害（「把文件写进一个不相干的目录」「覆盖别人的产物」）
    在结构上不可能发生——能被静默认领的，只有一个与我们刚造出来的那个**不可区分**的
    空目录，认领它不毁任何数据。

    ⚠️ 这不是归属证明。R66-F2 已经论证过「复查目录为空只证明里面没有文件，
    **不证明这个目录是我造的**」——那条结论在这里仍然成立，本检查的作用是**伤害上界**，
    不是出处证明。真正把「open 之后到发布归属之前」那道缝关掉的是
    `claim_dir` 里取锁后的那次反查。
    """
    st = os.fstat(dir_fd)
    if (st.st_mode & 0o777) != 0o700 or st.st_uid != os.geteuid() or os.listdir(dir_fd):
        raise BoundaryError(
            f"{abs_path} 不是本次刚创建的那个空目录"
            f"（权限 {st.st_mode & 0o777:o}、属主 {st.st_uid}、非空={bool(os.listdir(dir_fd))}）"
            f"——在 `mkdir` 与 `open` 之间它被换掉了。拒绝启动，一个字节都不写。"
        )


def _assert_leaf_still_is(parent_fd: int, leaf: str, dir_fd: int, abs_path: str,
                          *, when: str) -> None:
    """拿**留住的父目录 fd** 反查：`lstat(leaf, dir_fd=父)` 必须仍是我们钉住的 inode。

    ⚠️ **它不「关闭」竞态，`flock` 也关不了**（R2-codex-high 更正了本函数上一版
    「彻底关掉」的说法——那是**声称超出实际保证**）：`flock` 只约束**尊重它的工具**，
    **拦不住任何第三方进程改动父目录的命名空间**。父目录不归本工具所有，
    只要它可被别人写，这个窗口就在。

    它真正提供的是两件可证的事：
      ① **写入永远不会落到别人的目录里** —— 一切写都经 `dir_fd`，走的是我们钉住的
         inode，不是路径；
      ② **发布之后立刻复核**，故「路径已指向别处而我们仍宣称成功」这一档
         **一定会被抓到并 fail-closed**，绝不会以 rc=0 收场。

    调用方在需要「持续可达」的地方仍须周期性用 `assert_fd_still_at` 复核
    （codex R2 的附带建议；S4/S5 的拷贝循环适用）。
    """
    st_name = os.lstat(leaf, dir_fd=parent_fd)
    st_fd = os.fstat(dir_fd)
    if (st_name.st_dev, st_name.st_ino) != (st_fd.st_dev, st_fd.st_ino):
        raise BoundaryError(
            f"{abs_path} 在{when}已不再指向本次创建的那个目录"
            f"——有人把它换掉了。拒绝，且本工具的写入全部经 fd，没有落进别人的目录。"
        )


def _open_root_impl(abs_path: str, *, create_leaf: bool):
    """`open_root` 的实现体。返回 `(fd, parent_fd, leaf)`。

    `create_leaf=True` 时把**父目录 fd 一并交出去**，供 `claim_dir` 在取锁之后反查；
    `create_leaf=False` 时 `parent_fd` / `leaf` 均为 `None`。
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
            try:
                _assert_freshly_created(nxt, abs_path)
            except BaseException:
                os.close(nxt)
                raise
            os.fsync(fd)          # 父目录耐久（R45-F2）
            return nxt, fd, leaf  # fd 作为 parent_fd 交给调用方
        return fd, None, None
    except BaseException:
        os.close(fd)
        raise


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

    ⚠️ **`mkdir` 与随后的 `open` 是两次按名字的独立查找**（R1-codex-high）：
    两者之间目录可被改名调包。POSIX 关不掉这道缝，故用 `_assert_freshly_created`
    把伤害限死为「只可能认领一个与自己刚造的不可区分的空目录」；
    **需要更强保证的调用方请用 `claim_dir`**——它在取锁之后**与发布归属之后**
    各拿父目录 fd 反查一次，使「路径已指向别处而仍宣称成功」不可能发生
    （⚠️ 那仍**不是**关闭竞态：父目录的命名空间不归本工具控制）。

    ⚠️ **绝不用 `os.rename` 做「不覆盖发布」**：POSIX 的 `rename(2)` 在「源是目录、
    目标是**空目录**」时**会把目标替换掉**（macOS 同此），于是一个预先建好的空目录
    会被静默删除并认领（R64-F1）。
    """
    fd, parent_fd, _leaf = _open_root_impl(abs_path, create_leaf=create_leaf)
    if parent_fd is not None:
        os.close(parent_fd)
    return fd


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


def _open_regular_probe(dir_fd: int, name: str, *, flags: int, mode: int = 0o600):
    """以 `O_NONBLOCK` 打开并返回 `(fd, st)`；确认是普通文件后清掉 `O_NONBLOCK`。

    **为什么必须带 `O_NONBLOCK`（R4-codex-high）**：`open(O_RDONLY)` 打开 FIFO 会
    **一直阻塞等写入方** —— 于是「打开在先、查类型在后」的写法，会让一个被篡改的
    目录把启动**永久挂起**，而不是 fail-closed。带上它 `open` 立刻返回，
    随后由调用方按各自的语义 `S_ISREG` 拒掉。

    ⚠️ 也**不要**指望「`O_RDWR` 打开 FIFO 不阻塞」：那个行为 POSIX **未定义**
    （本仓纪律：凡断言某个系统调用有某种性质，都必须对着 man page 逐条核实）。
    三个打开点（取锁、探测、读标记）统一走本函数，避免「同一条纪律只落在其中一处」。
    """
    fd = open_under(dir_fd, name, flags=flags | os.O_NONBLOCK, mode=mode)
    try:
        st = os.fstat(fd)
        if stat.S_ISREG(st.st_mode):
            cur = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, cur & ~os.O_NONBLOCK)
        return fd, st
    except BaseException:
        os.close(fd)
        raise


def _write_all(fd: int, data: bytes) -> None:
    """把 `data` **整量**写完。

    **POSIX 允许部分写入**（R4-codex-medium）：忽略 `os.write` 的返回值，会让一份
    截断的 JSON 被 `fsync` 之后原子发布出去，而调用方照样返回成功 —— 随后的归属
    校验再把它拒掉，目录就此搁浅。（`EINTR` 由 CPython 自动重试，PEP 475，
    故这里只需处理短写。）
    """
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError(f"写入未推进（返回 {written}），拒绝发布可能截断的内容")
        view = view[written:]


def assert_lock_still_held(dir_fd: int, lock_name: str, lock_fd: int) -> None:
    """复核：`lock_name` 这个目录项**仍然**指向我们锁住的那个 inode。

    `flock` 锁的是**打开那一刻**该名字指向的 inode。目录项被 unlink/rename 换掉之后，
    第二个进程打开并锁住**新的 inode** 同样会成功 —— 两个 `qmt_fetch` 各自持有一把
    「独占锁」同时往一棵 staging 里写。**脑裂**，而锁的全部意义就是防这个（R9/R10）。

    ⚠️ **一次检查给不了持久互斥**（codex R10 原话，我同意）。故本函数被做成一个
    **供调用方反复调用**的原语：S4/S5 的拷贝循环应在**每一次状态改变之前**调它，
    而不是只在取锁时调一次。`acquire_lock` 自己在返回前调一次，只保证「取锁那一刻是干净的」。

    ⚠️ **与 `assert_fd_still_at` 是两件事，名字刻意分开**（codex R10 明确点出
    「目录可达性检查不能被误当成锁完整性检查」）：目录可以好端端在原地，
    而锁已经被掉包 —— 只查目录的调用方对此完全失明。

    ⚠️ **能力边界，如实声明**：本函数**挡不住**一个执意替换目录项的同 UID 进程，
    任何「检查 + 使用」的组合都挡不住。spec §4.1 R36-F2 早已把这条边界写死：
    **「`.staging.lock` 只约束尊重它的工具」** —— 一个会去替换锁目录项的进程，
    按定义就不在这个约束之内。本函数提供的是**可检测性**（把静默脑裂变成
    当场 fail-closed），不是对敌互斥。
    """
    st_name = os.lstat(lock_name, dir_fd=dir_fd)
    st_held = os.fstat(lock_fd)
    if (st_name.st_dev, st_name.st_ino) != (st_held.st_dev, st_held.st_ino):
        raise LockDisciplineError(
            f"锁文件 {lock_name!r} 的目录项被换掉了——"
            f"我们锁住的 inode 已不是这个名字指向的那个。"
            f"继续下去会与另一次运行**同时**持有各自的「独占锁」（脑裂）。拒绝。"
        )


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
        lock_fd, lock_st = _open_regular_probe(
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
        if not stat.S_ISREG(lock_st.st_mode):
            raise LockDisciplineError(
                f"锁文件 {lock_name!r} 存在但不是普通文件——拒绝启动。"
            )
        # ⚠️ **本判据原来的理由已经不成立了，如实登记**（R5 → R8）：
        # 它当初（R5-codex-high）是为了保护本函数下面那次 `ftruncate(0)` —— 若
        # `lock_name` 是把外部文件硬链过来的名字，截断就会毁掉边界外的数据。
        # **R8 之后本函数一个字节都不再写锁 inode**，那条伤害路径整个消失了。
        #
        # 保留它的理由变成了另一条、也弱得多：**一个 0700 工作目录里出现多名字的
        # 锁文件本身就是异常现场**，按本仓纪律异常即 fail-closed。
        # 它**不再**声称阻止任何数据破坏。
        # （原先登记的「对手用 rename 而非 link 则测不出」这条残留，
        #   随伤害路径一起失去意义，不再作为残留登记。）
        if lock_st.st_nlink != 1:
            raise LockDisciplineError(
                f"锁文件 {lock_name!r} 有 {lock_st.st_nlink} 个硬链接——"
                f"它同时是别处某个文件的名字，写入会破坏边界之外的数据。"
                f"拒绝启动，一个字节都不写。"
            )
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            raise LockUnavailableError(
                f"{lock_name!r} 正被另一次运行持有，请等待或确认。"
                f"（锁由内核持有、进程死亡即释放，**不需要也不应该手工删锁**）"
            ) from e
        # ⚠️ **取锁之后必须确认目录项仍指向我们锁住的那个 inode**（R9-codex-high）。
        # `flock` 锁的是**打开那一刻 `lock_name` 指向的 inode**，而目录项可以被
        # unlink/rename 换掉：第二个进程打开并锁住**新的 inode** 也会成功，
        # 于是两个 `qmt_fetch` 各自持有一把「独占锁」同时往一棵 staging 里写 ——
        # **脑裂**，而锁的全部意义就是防止这个。
        # 判据与 `assert_fd_still_at` / `_assert_leaf_still_is` 同源：路径 vs inode。
        #
        # ⚠️ 与那两处同样的诚实边界：这**不关闭**竞态（目录项在检查之后仍可被换），
        # 它把「静默脑裂」变成「取锁时就被抓住并 fail-closed」。
        # 需要持续保证的调用方（S4/S5 的拷贝循环）应在每次关键提交前
        # 用 `assert_fd_still_at` 再复核一次。
        assert_lock_still_held(dir_fd, lock_name, lock_fd)

        # ⚠️ **取锁不改动锁 inode 的任何一个字节**（R8-codex-high）。
        # spec R48-F2 明写锁文件内容「仅供人读诊断，不参与任何判定」——
        # 既然如此就没有任何理由去截断它。持有者信息写到**独立文件**，
        # 走 `_atomic_write_json`（唯一名 + `O_EXCL` + `os.replace`）。
        #
        # ⚠️ 对 codex 这一条的**部分不同意**（已在提交信息里登记）：它说
        # 「检查之后被硬链到别处，随后的 ftruncate 会破坏那个外部路径」——
        # 可那个 inode **本来就是我们的**，里面只有我们自己的诊断 JSON，
        # 攻击者链过去的是我们的文件，截断它没有毁掉任何属于别人的数据，
        # harm 被说重了。但它的**另一条建议是对的且更彻底**，故照此重构：
        # 重构之后这个争论本身就不存在了。
        _atomic_write_json(dir_fd, lock_name + ".holder", {
            "tool": tool, "pid": os.getpid(), "hostname": socket.gethostname(),
        })
        return lock_fd
    except BaseException:
        os.close(lock_fd)
        raise


def probe_unclaimed_dir(dir_fd: int, lock_name: str) -> str:
    """一个**没有合法归属标记**的既存目录，该给操作者什么指引——三分支，一个都不能省。

    探测形态由 P2-F1 写死，**绝不带 `O_CREAT`**：带了会在一个已被证明不属于我们的目录里
    造出锁文件，随后建议的 `rmdir` 恰恰因为这个文件而 `ENOTEMPTY`，
    **修复指引自己把自己堵死**；这直接违反「取锁要写文件，打错字的 `--dest`
    会先在未经证明的目录里落下锁文件」（R65-F1）。

    返回值与调用方必须给出的指引：

    - `"vacuum"` —— 锁文件**不存在**。这是崩在 `mkdir` 与建锁文件之间留下的**真空目录**，
      也是**唯一 `rmdir` 能干净成功的一档**（O4-F6）。调用方须**先复查目录确为空**，
      再给 `rmdir <dir>` 指引。
    - `"busy"` —— `flock` 取不到。报「**另一次运行正在认领该目录，请等待或确认**」，
      **绝不建议 `rmdir`**（O2-F9：那个窗口里至少有一次 openat+flock、一次写、三次
      `fsync`，操作者照做后 A 持有的 fd 仍指向已被 unlink 的 inode，
      此后几百个 CSV 全写进一棵**不可达**的树，而 A 以 rc=0 宣称就绪）。
    - `"stale"` —— `flock` 取得了，才**可能**是残骸。⚠️ 此时目录里**必然有**锁文件
      （正是我们刚打开的那个），**裸 `rmdir` 必撞 `ENOTEMPTY`**（已实测）。
      故指引必须是：先列出目录内容供操作者核对，再给
      「若确认除锁文件外为空：`rm -f <dir>/<lock> && rmdir <dir>`」。

    锁文件是符号链接、目录或其它非普通文件 → `LockDisciplineError`（R72-F2）。
    """
    try:
        lock_fd, lock_st = _open_regular_probe(
            dir_fd, lock_name, flags=os.O_RDWR)                    # ⚠️ 绝不带 O_CREAT
    except FileNotFoundError:
        return "vacuum"
    except PathEscapeError as e:
        raise LockDisciplineError(
            f"锁文件 {lock_name!r} 不是普通文件（{e}）——拒绝启动。"
        ) from e
    except IsADirectoryError as e:
        # 与 acquire_lock 同规格：EISDIR 在 fstat 之前就抛出，S_ISREG 够不着
        raise LockDisciplineError(
            f"锁文件 {lock_name!r} 存在但是一个目录——拒绝启动。"
        ) from e
    try:
        if not stat.S_ISREG(lock_st.st_mode):
            raise LockDisciplineError(
                f"锁文件 {lock_name!r} 存在但不是普通文件——拒绝启动。"
            )
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return "busy"
        fcntl.flock(lock_fd, fcntl.LOCK_UN)     # 取得后立即释放，不写任何内容
        return "stale"
    finally:
        os.close(lock_fd)


def _atomic_write_json(dir_fd: int, name: str, payload: dict) -> None:
    """原子写一份 JSON：`lstat` 守卫 → 唯一名 `O_EXCL` 临时文件 → `fsync(文件)`
    → `os.replace` → `fsync(目录)`。**本模块唯一的文件写入路径。**

    ⚠️ **绝不截断既存 inode**（R3 / R5 / R8 同一家族的三次复发：标记临时文件、
    锁硬链接、锁截断竞态）。`O_NOFOLLOW` 挡符号链接、`S_ISREG` 挡 FIFO，
    两者**都挡不住硬链接**；而 `st_nlink == 1` 这类检查与随后的截断之间
    必然存在窗口，**反复加检查关不掉它**。
    真正的解法是：**只写自己用 `O_EXCL` 刚创建出来的 inode**，然后 `os.replace`
    发布 —— `replace` 换的是目录项，不碰目标 inode 的字节，外部硬链接保有自己的数据。

    临时名带 pid 与随机后缀，故崩溃留下的旧临时文件不会被静默复用；
    失败路径把它 unlink 掉。
    """
    try:
        st = os.lstat(name, dir_fd=dir_fd)
    except FileNotFoundError:
        pass
    else:
        if stat.S_ISLNK(st.st_mode):
            raise PathEscapeError(
                relative_path=name, component=name, errno=_errno.ELOOP
            )
        if not stat.S_ISREG(st.st_mode):
            raise MarkerInvalidError(
                f"{name!r} 已存在但不是普通文件——拒绝写入。"
            )
    tmp_name = f"{name}.{os.getpid()}.{os.urandom(6).hex()}.tmp"
    fd = open_under(
        dir_fd, tmp_name,
        flags=os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode=0o600,
    )
    try:
        try:
            _write_all(fd, json.dumps(payload, ensure_ascii=False).encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        # ⚠️ 直接传 dir_fd，不做 os.supports_dir_fd 能力探测（O4-F14）
        os.replace(tmp_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except BaseException:
        try:
            os.unlink(tmp_name, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
        raise
    fsync_dir(dir_fd)


def write_owner_marker(dir_fd: int, marker_name: str, payload: dict) -> None:
    """原子写归属标记：`lstat` 拒符号链接 → tmp → `fsync(文件)` → `os.replace` → `fsync(目录)`。

    标记文件与报告一样走「临时文件 + `os.replace`」原子落地（R13-F2）。

    ⚠️ **`lstat` 那一道不是多余的**：`os.replace` **不跟随**目标符号链接（它替换的是链接
    本身），所以「写不出去」这个后果确实不会发生——但**依赖这个副作用等于把纪律
    建立在一个未经声明的实现细节上**，正是 spec 反复点名的「形容词 + 具体调用不符」。
    且一个我们自以为已归属的目录里凭空出现同名符号链接，本身就是「现场超出理解范围」，
    该 fail-closed 而不是静默把它替换掉。

    ⚠️ **本函数不管顺序**：调用方必须**先取锁再写标记**（R97-F2 取锁早于发布归属）。
    父目录的 `fsync` 由 `open_root(create_leaf=True)` 在 `mkdir` 之后做掉。
    """
    _atomic_write_json(dir_fd, marker_name, payload)


def verify_owner_marker(dir_fd: int, marker_name: str, *, expect_tool: str,
                        self_field: str, self_value: str) -> dict:
    """**第 1 层**归属校验：`tool` 相符 + **自指字段**等于 `self_value`。返回整份标记内容。

    第 1 层**不依赖 manifest，任何时候都能验**。它一旦通过，就确立了
    「**这个目录是本工具的，我有权在里面新增东西**」——但**不足以支撑「作废既有报告」**
    （R31-F1 / R40-F1）。**第 2 层**（`seed` + `export_log_sha256`）**必须等到
    manifest 校验通过之后**才验，**不在本模块**——本函数把整份内容交回给调用方去做。

    自指字段的全部意义是**防标记被整体搬走**：一份从别处拷来的标记，
    `tool` 会对上，只有自指字段对不上。
    """
    try:
        fd, st = _open_regular_probe(dir_fd, marker_name, flags=os.O_RDONLY)
    except FileNotFoundError as e:
        raise MarkerInvalidError(f"归属标记 {marker_name!r} 不存在") from e
    except IsADirectoryError as e:
        raise MarkerInvalidError(f"归属标记 {marker_name!r} 是一个目录") from e
    try:
        if not stat.S_ISREG(st.st_mode):
            # FIFO / 设备 / socket：**先探类型再读**，否则 O_RDONLY 会挂死在 FIFO 上
            raise MarkerInvalidError(
                f"归属标记 {marker_name!r} 存在但不是普通文件——拒绝。"
            )
        # ⚠️ 上限必须卡在**读取过程中**，不能只查 `st_size`（R6-codex-high）：
        # `st_size` 是打开那一刻的快照，文件完全可以**边读边长**，只查它会被绕过。
        #
        # ⚠️ codex 还建议叠一道 `st_size` 早拒，**未采纳**并说明理由：
        # 读取本身每次上限 64 KiB、累计到 64 KiB 即停，两条路的实际读取量同量级，
        # 早拒省不下什么；而它**无法被任何测试单独钉住**（变异 M30 实测仍然全绿，
        # 因为读中计数把同样的场景也接住了）。本仓被「机械检查器悄悄烂掉」坑过，
        # 一道钉不住的守卫是负债不是资产 —— 只留能被钉住的那一道。
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > _MARKER_MAX_BYTES:
                raise MarkerInvalidError(
                    f"归属标记 {marker_name!r} 在读取过程中超过上限 "
                    f"{_MARKER_MAX_BYTES} 字节（文件正在增长）——拒绝，过大。"
                )
            chunks.append(chunk)
        raw = b"".join(chunks)
    finally:
        os.close(fd)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise MarkerInvalidError(f"归属标记 {marker_name!r} 不是合法 JSON: {e}") from e
    if not isinstance(data, dict):
        raise MarkerInvalidError(f"归属标记 {marker_name!r} 顶层不是对象")
    if data.get("tool") != expect_tool:
        raise MarkerInvalidError(
            f"归属标记 {marker_name!r} 的 tool 为 {data.get('tool')!r}，"
            f"不是 {expect_tool!r}——这个目录不属于本工具"
        )
    if data.get(self_field) != self_value:
        raise MarkerInvalidError(
            f"归属标记 {marker_name!r} 的自指字段 {self_field!r} 为 "
            f"{data.get(self_field)!r}，而当前路径是 {self_value!r}"
            f"——标记可能是从别处整体搬来的"
        )
    return data


def claim_dir(abs_path: str, *, lock_name: str, marker_name: str,
              marker_payload: dict, tool: str, self_field: str) -> tuple[int, int]:
    """首次使用 / 认领协议（`--dest` 与 `--output` **创建方式同规格**，R64-F1 + R66-F2）：

      1. `open_root(create_leaf=True)` —— 从 `/` 逐分量 `O_NOFOLLOW` 走到父目录，
         再 `os.mkdir(dir_fd=父fd)`：`mkdir` 是**唯一可移植的目录级独占创建原语**，
         而逐段走保证「独占创建」发生在**验过的那个父 inode** 里（R75-F2）；
      2. 取 `flock` —— **先取锁，再发布归属**（R97-F2）。顺序反了，
         两个进程就能同时往一棵 staging 里写；
      3. 写标记 + `fsync(文件)` + `fsync(该目录)`（父目录的 `fsync` 已在第 1 步做掉）。

    返回 `(dir_fd, lock_fd)`，**两者都归调用方、全程持有、用完必须关**。

    **路径已存在 → `DirectoryExistsError`，一个字节都不写。**
    这一档**只能 fail-closed，不能自动认领**：`mkdir` 之后的目录**不携带任何出处信息**，
    「我崩在半路留下的空目录」与「操作者预先建好的空目录」在磁盘上**完全一样**；
    意图记录只能证明「我打算建」，不能证明「我建成了」；写完标记后的「复查目录为空」
    只证明「里面没有文件」，**不证明「这个目录是我造的」**（R66-F2）。
    **造不出证据时，唯一诚实的做法是拒绝并交给人**——宁可要一次人工介入，
    不要一次静默越界。

    **`--dest` 与 `--output` 在 `EEXIST` 这一档结局不同**（R91-F2），
    由调用方决定，本原语不替它们决定。

    ⚠️ **发布前先自检、发布后再回读**（R7-codex-high）：本仓把「写侧形状与读侧要求
    逐字相同」（R94-F2）与「一个信号只有同时进了写侧规定与读侧校验才真的存在」
    （R93-F1）列为头等纪律，而本函数原先把调用方给的 `marker_payload` **原样发布**，
    从不检查它能否通过自己的 `verify_owner_marker`。后果是：内容超限 / 缺 `tool` /
    自指字段不符时，目录被**认领成功**，而**下一次运行拒绝这份标记** ——
    该目录既不是首次（路径存在）也复用不了（标记非法），**工具自己解不开**。
    且序列化失败原先发生在 `mkdir` 与取锁**之后**，会留下半初始化目录。

    故：**任何副作用之前**先把 `marker_payload` 序列化并逐条自检
    （可 JSON 化 / 不超 `_MARKER_MAX_BYTES` / `tool` 相符 / `self_field` 存在且
    等于规范化后的 `abs_path`）；发布之后再用 `verify_owner_marker` **回读一次**，
    把写侧与读侧真正配上对。

    ⚠️ **本函数不声称序列化父目录的命名空间**（R2-codex-high）：`flock` 只约束
    尊重它的工具。它声称的是——**写入永远经 fd 而非路径**（不会落进别人的目录），
    且**取锁后与发布后各复核一次**，故「路径已指向别处而仍以 rc=0 宣称成功」
    不可能发生。持续可达性由调用方用 `assert_fd_still_at` 周期性复核。
    """
    # ---- 任何副作用之前：把标记内容按读侧的要求逐条自检（R7-codex-high）----
    normalized = normalize_abs_path(abs_path)
    if marker_payload.get("tool") != tool:
        raise MarkerInvalidError(
            f"标记内容的 tool 为 {marker_payload.get('tool')!r}，不是 {tool!r}"
            f"——写侧发布的标记必须能通过读侧自己的校验。一个字节都不写。"
        )
    if marker_payload.get(self_field) != normalized:
        raise MarkerInvalidError(
            f"标记内容的自指字段 {self_field!r} 为 "
            f"{marker_payload.get(self_field)!r}，而目标路径是 {normalized!r}"
            f"——写侧发布的标记必须能通过读侧自己的校验。一个字节都不写。"
        )
    try:
        encoded = json.dumps(marker_payload, ensure_ascii=False).encode("utf-8")
    except (TypeError, ValueError) as e:
        raise MarkerInvalidError(f"标记内容无法序列化成 JSON: {e}。一个字节都不写。") from e
    if len(encoded) > _MARKER_MAX_BYTES:
        raise MarkerInvalidError(
            f"标记内容过大（{len(encoded)} 字节 > {_MARKER_MAX_BYTES}）"
            f"——读侧会拒绝它。一个字节都不写。"
        )

    dir_fd, parent_fd, leaf = _open_root_impl(abs_path, create_leaf=True)
    lock_fd = None
    try:
        lock_fd = acquire_lock(dir_fd, lock_name, tool=tool)
        # 取锁是串行化点：此刻拿**留住的父目录 fd** 反查一次，
        # 把「open 之后、发布归属之前」那道缝彻底关掉（R1-codex-high）
        _assert_leaf_still_is(parent_fd, leaf, dir_fd, abs_path, when="取锁之后")
        write_owner_marker(dir_fd, marker_name, marker_payload)
        # ⚠️ 发布**之后**必须再复核一次（R2-codex-high）：写标记这一串
        # （tmp → fsync → replace → fsync 目录）**不是原子的**，「写之前复核」
        # 挡不住「复核之后、写完之前」被调包 —— 那会让标记落到一个可能已被 unlink
        # 的旧 inode 上，而 abs_path 指向别处，正是 O2-F9 那个最坏结局：
        # **工具以 rc=0 宣称就绪，而操作者按路径去看什么都没有**。
        _assert_leaf_still_is(parent_fd, leaf, dir_fd, abs_path, when="发布归属之后")
        # 写侧读侧配对闭合：刚发布的标记必须当场能被读侧接受。
        # 有了上面的发布前自检，这一步在实践中不该失败；它失败即说明现场
        # **超出本工具的理解范围**，按本仓纪律 fail-closed 并把出路交给人。
        try:
            verify_owner_marker(dir_fd, marker_name, expect_tool=tool,
                                self_field=self_field, self_value=normalized)
        except MarkerInvalidError as e:
            raise MarkerInvalidError(
                f"刚发布的归属标记无法通过读侧校验（{e}）——现场超出本工具的理解范围。"
                f"请先列出 {abs_path} 的内容核对，确认无用后手工清理："
                f"`rm -f {abs_path}/{marker_name} {abs_path}/{lock_name} "
                f"&& rmdir {abs_path}`"
            ) from e
    except BaseException:
        if lock_fd is not None:
            os.close(lock_fd)
        os.close(dir_fd)
        raise
    finally:
        os.close(parent_fd)
    return dir_fd, lock_fd


def assert_readonly_fd(fd: int, *, label: str) -> None:
    """**非写入式**只读判据：`os.fstatvfs(fd).f_flag & ST_RDONLY` 为真才继续（R5-F3）。

    ⚠️ **禁止用「试写一个临时文件」去探测**：那种主动探测在**恰恰是它要防的那个
    危险场景里**（共享真的可写）会**由本工具自己去写权威导出共享**——探测成功即污染。
    再叠加崩溃、删除失败或源本身是审计敏感目录，安全检查反而成了第一个破坏者。
    **为了防止破坏而引入的机制，本身带着破坏性**。

    ⚠️ 本判据**只证明「这是某个只读目录」**：本机根卷 `/` 自己就是
    `apfs … read-only`，**「只读」在 macOS 上根本区分不出「网络共享」与「本地卷」**
    （R19-F2，已实测）。绑住「就是那台机器上的那个共享」要靠**挂载身份**，那是 S5。
    """
    if not (os.fstatvfs(fd).f_flag & os.ST_RDONLY):
        raise BoundaryError(
            f"{label} 不是只读挂载。请以 `-o rdonly` 重新挂载："
            f"`mount_smbfs -o rdonly //<user>@<host>/<share> <挂载点>`。"
            f"（`rdonly` 的效果是连 super-user 也写不了——这是强制要求，不是建议。）"
        )


def assert_no_path_overlap(labeled: dict[str, str]) -> None:
    """任意两个目录**规范化后**不得相等、不得互为子树（R4-F4）。

    否则一旦源挂载是可写的，`qmt_fetch` 会把 `.staging.lock` / `fetch_manifest.json`
    / `.part` / 拷贝出来的 CSV **写进那个权威导出共享里**，污染的正是本次要取证的数据集。

    **按分量比，不按字符串前缀比**：`/a/srcx` 不是 `/a/src` 的子树。
    本判据与 `assert_distinct_inodes` **并用**——路径判据可被换掉，inode 判据不会。
    """
    items = [(lab, split_components(p)) for lab, p in labeled.items()]
    for i, (la, ca) in enumerate(items):
        for lb, cb in items[i + 1:]:
            if ca == cb:
                raise BoundaryError(f"{la} 与 {lb} 是同一个目录")
            shorter, longer, ls, ll = (
                (ca, cb, la, lb) if len(ca) < len(cb) else (cb, ca, lb, la)
            )
            if longer[:len(shorter)] == shorter:
                raise BoundaryError(f"{ll} 落在 {ls} 的目录树之内")


def assert_distinct_inodes(labeled_fds: dict[str, int]) -> None:
    """另比 `(st_dev, st_ino)`——**路径判据可被换掉，inode 判据不会**（R84-F1）。"""
    seen: dict[tuple[int, int], str] = {}
    for label, fd in labeled_fds.items():
        st = os.fstat(fd)
        key = (st.st_dev, st.st_ino)
        if key in seen:
            raise BoundaryError(
                f"{label} 与 {seen[key]} 指向同一个 inode"
                f"（路径不同不代表目录不同——符号链接/硬链接别名会让两条路径落到同一棵树）"
            )
        seen[key] = label


def assert_fd_still_at(abs_path: str, fd: int, *, label: str) -> None:
    """运行中途**分叉检查**：`os.stat(路径)` 的 `(st_dev, st_ino)` 必须等于 `os.fstat(fd)`。

    `--source` **没有归属标记、也没有锁**（它不是我们的目录），
    **没有任何东西阻止它在两条闸之间被换掉**（R84-F1 / R91-F1）。
    """
    st_path = os.stat(abs_path)
    st_fd = os.fstat(fd)
    if (st_path.st_dev, st_path.st_ino) != (st_fd.st_dev, st_fd.st_ino):
        raise BoundaryError(
            f"{label} 在运行中途被改名或改指：钉住的 inode 与当前路径已不是同一个"
        )
