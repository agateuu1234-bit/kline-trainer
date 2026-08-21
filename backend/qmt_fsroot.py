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
        lock_fd = open_under(dir_fd, lock_name, flags=os.O_RDWR)   # ⚠️ 绝不带 O_CREAT
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
        if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
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
    try:
        st = os.lstat(marker_name, dir_fd=dir_fd)
    except FileNotFoundError:
        pass
    else:
        if stat.S_ISLNK(st.st_mode):
            raise PathEscapeError(
                relative_path=marker_name, component=marker_name, errno=_errno.ELOOP
            )
        if not stat.S_ISREG(st.st_mode):
            raise MarkerInvalidError(
                f"归属标记 {marker_name!r} 已存在但不是普通文件——拒绝写入。"
            )
    tmp_name = marker_name + ".tmp"
    fd = open_under(
        dir_fd, tmp_name, flags=os.O_CREAT | os.O_WRONLY | os.O_TRUNC, mode=0o600
    )
    try:
        os.write(fd, json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    # ⚠️ 直接传 dir_fd，不做 os.supports_dir_fd 能力探测（O4-F14）
    os.replace(tmp_name, marker_name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    fsync_dir(dir_fd)


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
        fd = open_under(dir_fd, marker_name, flags=os.O_RDONLY)
    except FileNotFoundError as e:
        raise MarkerInvalidError(f"归属标记 {marker_name!r} 不存在") from e
    try:
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
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
              marker_payload: dict, tool: str) -> tuple[int, int]:
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
    """
    dir_fd = open_root(abs_path, create_leaf=True)
    try:
        lock_fd = acquire_lock(dir_fd, lock_name, tool=tool)
    except BaseException:
        os.close(dir_fd)
        raise
    try:
        write_owner_marker(dir_fd, marker_name, marker_payload)
    except BaseException:
        os.close(lock_fd)
        os.close(dir_fd)
        raise
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
