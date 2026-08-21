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
