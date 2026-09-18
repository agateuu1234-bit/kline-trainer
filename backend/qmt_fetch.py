# backend/qmt_fetch.py
"""单股拷贝事务（QMT 4b 切片 S4a）。

Spec（唯一契约）: docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md
Plan: docs/superpowers/plans/2026-09-19-qmt-4b-s4a-impl.md

**本片只是 Task 1**：`--max-bytes` 记账对象 + 单文件流式拷贝。绑定契约 D3（源侧叶子
非普通文件）与 D7（逐块记账、回滚退还）。四象限判据（D2/D4，Task 2）与在途标记 +
单股事务编排（D1/D4-2/D5/D6/D8，Task 3）都不在本片范围内——本模块目前不认识
「manifest」「Slot」「四象限」。

三族互不相交的异常（调用方靠这三族决定「跳过这只股」还是「终止整次运行」）：
  · **候选失败**——`StockCopyFailed`：这一只股这次不行，继续下一只。
  · **终止条件**——`RunTerminated` 及其子类：整次运行必须停（rc≠0）。本片只有
    `MaxBytesExhausted` 一个成员；Task 3 会补第二个成员（D5：源比对不符）。
    调用方要能用一个 `except RunTerminated` 接住全族。
  · **路径逃逸**——`qmt_fsroot.PathEscapeError`：信任边界被破坏，本模块不捕获、
    不包装，原样上抛（它不是 `OSError` 的子类，也不属于前两族）。
"""
from __future__ import annotations

import hashlib
import os
import stat
from typing import NamedTuple

from qmt_fsroot import (
    NotARegularFileError,
    open_regular_probe,
    open_under,
    parent_fd_under,
)

__all__ = [
    "StockCopyFailed",
    "RunTerminated",
    "MaxBytesExhausted",
    "ByteBudget",
    "PART",
    "CopyResult",
    "copy_one",
]


PART = ".part"
_CHUNK = 1 << 20  # 1 MiB


class StockCopyFailed(Exception):
    """候选失败族：这一只股这次不行，调用方跳过它、继续下一只（不终止整次运行）。

    `reason` 是给 4c 报告与账本 `failures` 记录读的字面量。本片只产生两个：
    `fetch_missing_file`（D3：源侧叶子不是普通文件，或干脆不存在）、
    `fetch_copy_hash_mismatch`（落地的 `.part` 重算与源哈希不符）。
    D2/Task 2 会另产 `untracked_target_file`——reason 全集由契约收口，
    本类不做穷尽性校验，只是把调用方传入的字符串原样带上。
    """

    def __init__(self, reason: str, detail: str = ""):
        self.reason = reason
        self.detail = detail
        super().__init__(f"{reason}: {detail}" if detail else reason)


class RunTerminated(Exception):
    """终止条件族的公共基类：整次运行必须停（rc≠0），既不是候选失败也不是路径逃逸。

    调用方用一个 `except RunTerminated` 就能接住全族。本片只有 `MaxBytesExhausted`
    一个成员；Task 3 会补第二个成员（D5：源在本次运行期间换代，比对不符）。
    """


class MaxBytesExhausted(RunTerminated):
    """`--max-bytes` 预算耗尽：`ByteBudget.precheck` / `.charge` 在扣不下去时触发。"""


class ByteBudget:
    """`--max-bytes` 记账（契约 D7）：事前 `stat` 早拒、逐块扣减、回滚退还。

    `limit=None` 表示没传 `--max-bytes`（不设上限，`precheck`/`charge` 永不拒绝）。
    `used` 是**累计写入量**语义，不是「当前占用量」——占用量语义在崩溃恢复第③档
    之后会死锁（契约 D7、证据 E11/E12 已定案）。调用方负责把它初始化成本次运行
    开始时 manifest 里的 `committed_bytes`。
    """

    def __init__(self, *, limit: int | None, used: int = 0):
        self.limit = limit
        self.used = used

    def precheck(self, size: int) -> None:
        """开始流式拷贝前，用 `stat` 得到的文件总大小早拒：这一整个文件铁定装不下，
        就不用打开源文件、不用起 sha256、不用写一个字节。"""
        if self.limit is not None and self.used + size > self.limit:
            raise MaxBytesExhausted(
                f"precheck：剩余 {self.limit - self.used} 字节，此文件 {size} 字节"
            )

    def charge(self, n: int) -> None:
        """逐块扣减：每读到一块就先扣账；扣不下去立即终止（这一块甚至还没写盘）。"""
        if self.limit is not None and self.used + n > self.limit:
            raise MaxBytesExhausted(
                f"charge：剩余 {self.limit - self.used} 字节，本块 {n} 字节"
            )
        self.used += n

    def refund(self, n: int) -> None:
        """回滚退还：把已经扣过账、但这一趟不会被提交的字节还回去。

        触发点是「已经扣过账」，不是「拷贝函数正常返回过」——调用方必须传入
        **逐块累加**得到的「本次已写字节」，不得只在拷贝成功返回后才算出这个数
        （那样会让崩在半路的那一份账白扣，永久占着 `--max-bytes` 的额度）。
        """
        if n > self.used:
            raise ValueError(f"退还 {n} 字节超过已扣的 {self.used} 字节")
        self.used -= n


class CopyResult(NamedTuple):
    """`copy_one` 成功时的返回形状：本次真正写盘的字节数 + 源内容的 sha256。"""
    n_bytes: int
    sha256: str


def _write_all(fd: int, data) -> None:
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        if n <= 0:
            raise OSError(f"os.write 返回 {n}（fd={fd}）")
        view = view[n:]


def _open_source_leaf(src_fd: int, rel: str):
    """打开源侧叶子，交出 `(fd, st)`；D3 的类型判据由调用方对 `st` 自查 `S_ISREG`。

    只把「打不开（不存在）」与「打不开、且 lstat 显示非普通对象（如 socket）」
    这两种**确定**是候选失败的情形折成 `StockCopyFailed("fetch_missing_file")`。
    **不接 `except OSError`**——`PermissionError` 等其它 `OSError` 原样上抛
    （契约 D3：把权限错误也归成 `fetch_missing_file` 是这条判据要防住的坑）。
    符号链接叶子由 `qmt_fsroot` 自己在逐段无跟随时抛 `PathEscapeError`
    （不是 `OSError` 的子类），本函数完全不触碰它，原样上抛。
    """
    try:
        pfd, leaf = parent_fd_under(src_fd, rel)
    except FileNotFoundError as e:
        # 整段目录都不存在（比如这个 period 从没导出过），与「目录在、叶子不在」
        # 是同一件事对调用方而言——都是「这只股这次没有可用源文件」。
        raise StockCopyFailed("fetch_missing_file", f"{rel}: {e}") from e
    try:
        return open_regular_probe(pfd, leaf, flags=os.O_RDONLY)
    except FileNotFoundError as e:
        raise StockCopyFailed("fetch_missing_file", f"{rel}: {e}") from e
    except NotARegularFileError as e:
        raise StockCopyFailed("fetch_missing_file", f"{rel}: {e}") from e
    finally:
        os.close(pfd)


def copy_one(src_fd: int, stg_fd: int, rel: str, budget: ByteBudget) -> CopyResult:
    """单文件流式拷贝：读源 → 流式 sha256 → 逐块扣账 → 写 `.part` → `fsync` →
    对落地的 `.part` 重算并与源哈希比对。

    失败时（含 `--max-bytes` 触顶、源读/目的写中途报错、落地复算不符）退还
    本次已经扣过的账，再原样上抛。本函数**不**删 `.part`、**不**处理「这只股
    另一个文件怎么办」——那些是 Task 3 单股事务编排的范围，本函数只管它自己
    这一个文件的记账闭合。

    返回：成功时 `CopyResult(n_bytes=本次真正写盘的字节数, sha256=源内容哈希)`。
    """
    sfd, st = _open_source_leaf(src_fd, rel)
    try:
        if not stat.S_ISREG(st.st_mode):
            raise StockCopyFailed("fetch_missing_file", f"{rel}: 不是普通文件")
        budget.precheck(st.st_size)

        charged = 0
        try:
            dfd = open_under(
                stg_fd, rel + PART,
                flags=os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                mode=0o600, create_dirs=True,
            )
            try:
                hasher = hashlib.sha256()
                while True:
                    chunk = os.read(sfd, _CHUNK)
                    if not chunk:
                        break
                    budget.charge(len(chunk))
                    charged += len(chunk)
                    _write_all(dfd, chunk)
                    hasher.update(chunk)
                os.fsync(dfd)
            finally:
                os.close(dfd)
            digest = hasher.hexdigest()

            # 对落地的 `.part` 重算并与源哈希比对——不是恒等式：这里重新打开、
            # 重新从磁盘读回，不是复用上面流式算出的那个 hasher。
            rfd = open_under(stg_fd, rel + PART, flags=os.O_RDONLY)
            try:
                verify = hashlib.sha256()
                while True:
                    chunk = os.read(rfd, _CHUNK)
                    if not chunk:
                        break
                    verify.update(chunk)
            finally:
                os.close(rfd)
            if verify.hexdigest() != digest:
                raise StockCopyFailed("fetch_copy_hash_mismatch", rel)
        except BaseException:
            if charged:
                budget.refund(charged)
            raise
    finally:
        os.close(sfd)

    return CopyResult(n_bytes=charged, sha256=digest)
