# backend/qmt_fetch.py
"""单股拷贝事务（QMT 4b 切片 S4a）。

Spec（唯一契约）: docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md
Plan: docs/superpowers/plans/2026-09-19-qmt-4b-s4a-impl.md

**本片含 Task 1 + Task 2 + Task 3**：`--max-bytes` 记账对象 + 单文件流式拷贝
（D3、D7），幂等四象限判据 `classify_target`（D2、D4 第 1 条），以及把它们
串成一次「要么两个文件都提交、要么一个都不留」的单股事务 `copy_stock`
（D1、D4 第 2 条、D5、D6、D8）+ 在途标记 `.inflight.json` 的形状定义。
**S4b 范围**（续跑循环、崩溃恢复、两条相对路径的解析方式、`begin_run` 的调用
时机）不在本模块内——见契约 §4「交接」。

三族互不相交的异常（调用方靠这三族决定「跳过这只股」还是「终止整次运行」）：
  · **候选失败**——`StockCopyFailed`：这一只股这次不行，继续下一只。
  · **终止条件**——`RunTerminated` 及其子类：整次运行必须停（rc≠0）。两个成员：
    `MaxBytesExhausted`（`--max-bytes` 预算耗尽）、`SourceChangedMidRun`
    （契约 D5：落地前比对发现源在本次运行期间变了）。调用方要能用一个
    `except RunTerminated` 接住全族，且不会被它接住候选失败或路径逃逸。
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
    atomic_write_json,
    fsync_dir,
    open_regular_probe,
    open_under,
    parent_fd_under,
    split_relative_components,
)
from qmt_manifest import RunLedger, commit_stock
from qmt_normalize import QmtSchemaError, parse_qmt_filename
from qmt_pool import Slot

__all__ = [
    "StockCopyFailed",
    "RunTerminated",
    "MaxBytesExhausted",
    "SourceChangedMidRun",
    "ByteBudget",
    "PART",
    "CopyResult",
    "copy_one",
    "TARGET_COPY",
    "TARGET_SKIP",
    "TARGET_RECOPY",
    "TARGET_UNTRACKED",
    "classify_target",
    "INFLIGHT",
    "build_inflight_marker",
    "copy_stock",
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


class SourceChangedMidRun(RunTerminated):
    """终止条件族第二个成员（契约 D5）：落地前的比对发现新拷出的字节/哈希与账本
    已有记录不符。唯一成因是源在本次运行期间变了（本判据只查本地文件与
    manifest，不回读源文件——见不到「为什么」，只见得到「不一致」）。

    **定性是终止条件，不是这只股的候选失败**：删这只股的两个 `.part`、
    不记 failure、不加 attempts、不推进 cursor，manifest 一个字段都不写
    （交接 S4b：接住它、终止整次运行、rc≠0）。

    **必须早于在途标记与两次 `os.replace`**（E5 与反事实对照，契约 D5）：
    排在提交时的话，两个 final 已落地、标记已写，盘上已是新代次而账本仍记
    旧 sha —— 一次静默的代次混合，正是 D6 要消灭的状态。`copy_stock` 在
    落地任何东西之前就做这个比对。
    """


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


def _is_regular(st: os.stat_result) -> bool:
    """D2/D3 共用的「是不是普通文件」判据：拿 `open_regular_probe` 交出的 `st`
    自查 `stat.S_ISREG`——源侧（`copy_one`）与 staging 侧（`classify_target`）
    两处消费者都必须经它，不得各自内联一份（两份内联副本正是本仓反复栽过的缺陷）。

    **不含符号链接**：符号链接叶子在 `qmt_fsroot` 逐段无跟随时已经变成
    `PathEscapeError`（不是 `OSError` 子类），根本传不到这里来判——`st` 只可能
    来自「`open()` 成功打开的对象」或「`open()` 失败、`lstat` 证明存在的非普通对象
    （如 socket）」这两种情形，两者均已排除符号链接。
    """
    return stat.S_ISREG(st.st_mode)


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
        if not _is_regular(st):
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


# ── Task 2：幂等四象限判据（契约 D2、D4 第 1 条）──────────────────

TARGET_COPY = "copy"
TARGET_SKIP = "skip"
TARGET_RECOPY = "recopy"
TARGET_UNTRACKED = "untracked_target_file"


def _validate_record(record) -> None:
    """校验调用方传入的 manifest 记录形状：`None`（无记录）之外，必须是含
    `bytes`（`int`，排除 `bool`）与 `sha256`（`str`）两个字段的 `dict`。

    **一律拒绝，不是跳过**：字段缺失、类型不对（含不可哈希类型，如把 `sha256`
    传成一个 `list`）都在这里被截住并抛出清楚的 `TypeError`——`classify_target`
    的下游只用 `!=` / `==` 比较这两个字段，那两个运算符对几乎任何类型组合都
    「悄悄」给得出一个结果（要么恒不等、要么巧合相等），不会自己报错，
    坏记录会被静默当成「不符」或更糟「碰巧符合」，而不是被看见。
    """
    if record is None:
        return
    if not isinstance(record, dict):
        raise TypeError(
            f"manifest 记录必须是 dict 或 None，收到 {type(record).__name__}：{record!r}"
        )
    _MISSING = object()
    n_bytes = record.get("bytes", _MISSING)
    sha256_hex = record.get("sha256", _MISSING)
    if not isinstance(n_bytes, int) or isinstance(n_bytes, bool):
        raise TypeError(
            f"manifest 记录的 'bytes' 字段必须是 int，收到 {n_bytes!r}"
        )
    if not isinstance(sha256_hex, str):
        raise TypeError(
            f"manifest 记录的 'sha256' 字段必须是 str，收到 {sha256_hex!r}"
        )


def _hash_target(fd: int) -> str:
    hasher = hashlib.sha256()
    while True:
        chunk = os.read(fd, _CHUNK)
        if not chunk:
            break
        hasher.update(chunk)
    return hasher.hexdigest()


def classify_target(stg_fd: int, rel: str, record) -> str:
    """幂等四象限判据：manifest 有无这只股这个文件的记录 × staging 目标在不在，
    返回 `TARGET_COPY` / `TARGET_SKIP` / `TARGET_RECOPY` / `TARGET_UNTRACKED`
    四个字面量之一（契约 D2、D4 第 1 条）。`record` 是调用方已经从 manifest
    `files` 里按 `(stock_code, period, relative_path)` 查出来的那一条记录
    （形如 `{"bytes": int, "sha256": str, ...}`），或 `None`（无记录）。

    | | 有记录 | 无记录 |
    |---|---|---|
    | 目标存在 | 相符→`TARGET_SKIP`；不符→`TARGET_RECOPY` | `TARGET_UNTRACKED` |
    | 目标不存在 | `TARGET_COPY` | `TARGET_COPY` |

    **D2（非普通文件不按有无记录分叉）**：staging 目标存在但不是普通文件
    （目录 / FIFO / socket）——**不管有没有记录**——一律 `TARGET_UNTRACKED`，
    不落进「重拷」那一格。判据是**调用方自己查 `stat.S_ISREG`**（`_is_regular`，
    与 `copy_one` 共用同一个模块级判据），不是 `except NotARegularFileError`：
    目录与 FIFO 打开都会**成功**（`open_regular_probe` 内部带 `O_NONBLOCK`），
    只有 socket 那种「`open()` 本身就失败」的情形才会撞见
    `NotARegularFileError`——那时把它携带的 `st` 原样接过来，
    走的仍是同一条 `_is_regular(st)` 判据，**不是**拿异常类型本身当分支依据。

    **符号链接不在本判据管辖范围**：`rel` 的叶子若是符号链接，`open_regular_probe`
    背后的 `open_under` 会在逐段无跟随时先一步撞 `ELOOP` 抛出 `PathEscapeError`
    （不是 `OSError` 子类）——本函数完全不捕获它，原样向上传播，**绝不会**被
    归进 `TARGET_UNTRACKED`。一次符号链接就是一次信任边界破坏，必须整次运行
    终止，而不是被这条判据降级成「这只股的目标来路不明」。

    **R2-F3 回归钉**：目标是普通文件且字节数与记录相符，仍须比对 `sha256`——
    同尺寸不同内容必须判 `TARGET_RECOPY`，不得因为字节数先对上就跳过哈希比对
    而误判 `TARGET_SKIP`。

    **不做**：源侧比对（那是 D3/`copy_one` 的范围）、落地前把新拷出的字节与
    记录比对（D4 第 2 条，含「有记录 × 目标不存在」那一格，交 Task 3）、
    任何标记/提交动作。本函数只读，不写。
    """
    _validate_record(record)
    try:
        pfd, leaf = parent_fd_under(stg_fd, rel)
    except FileNotFoundError:
        return TARGET_COPY
    try:
        try:
            fd, st = open_regular_probe(pfd, leaf, flags=os.O_RDONLY)
        except FileNotFoundError:
            return TARGET_COPY
        except NotARegularFileError as e:
            fd, st = None, e.st
    finally:
        os.close(pfd)

    try:
        if not _is_regular(st):
            return TARGET_UNTRACKED
        if record is None:
            return TARGET_UNTRACKED
        if st.st_size != record["bytes"]:
            return TARGET_RECOPY
        return TARGET_SKIP if _hash_target(fd) == record["sha256"] else TARGET_RECOPY
    finally:
        if fd is not None:
            os.close(fd)


# ── Task 3：在途标记 + 单股事务编排（契约 D1、D4 第 2 条、D5、D6、D8）──

INFLIGHT = ".inflight.json"

_PERIODS = ("1m", "daily")


def build_inflight_marker(slot: Slot) -> dict:
    """`.inflight.json` 的形状（契约 D1、D6）：写下之后，S4b 的崩溃恢复据它构造
    `qmt_manifest.RecoveryScope`（`stock_code` / `market` / `universe_idx`）——
    三个字段与 `RecoveryScope` 的必需字段一一对应，形状校验要求
    `source_snapshot.universe[market][universe_idx] == code`（S4b 范围）。

    只此一处构造标记内容——`copy_stock` 与 S4b 的崩溃恢复必须读同一份形状定义，
    不得各自内联一份（本仓「写侧形状与读侧要求必须逐字相同」反复栽过的那类坑）。
    """
    if not isinstance(slot, Slot):
        raise TypeError(f"slot 必须是 qmt_pool.Slot，收到 {type(slot).__name__}")
    return {"code": slot.code, "market": slot.market, "universe_idx": slot.universe_idx}


def _validate_stock_paths(slot: Slot, rel_1m: str, rel_daily: str) -> None:
    """契约 D1 的前置校验：两条相对路径的次序钉死为 `(1m, daily)`，且各自的
    文件名都必须解析出这只股的代码。

    纯字符串/正则判据（`split_relative_components` + `parse_qmt_filename`），
    **不碰文件系统**——必须排在四象限判据、拷贝、在途标记之前：一个没有前置
    校验的实现会一路跑到 `commit_stock` 才被 `_validate_files` 拒掉，而那时
    两个 final 已落地、标记还在盘上，正是 D6 要消灭的状态（契约 D1 的警告）。
    """
    for rel, expected_period in ((rel_1m, "1m"), (rel_daily, "daily")):
        parts = split_relative_components(rel)
        code, _name, period = parse_qmt_filename(parts[-1])
        if code != slot.code:
            raise QmtSchemaError(
                f"{rel!r} 解析出的股票代码是 {code!r}，与 slot.code {slot.code!r} 不符"
            )
        if period != expected_period:
            raise QmtSchemaError(
                f"{rel!r} 解析出的周期是 {period!r}，此处期望 {expected_period!r}"
                "——两条路径的次序钉死为 (1m, daily)"
            )


def _cleanup_part(stg_fd: int, rel: str) -> None:
    """删这只股这一个文件的 `.part` 残留，容忍不存在。

    大 spec 耐久提交协议闭合清单的显式豁免：「失败路径上 `.part` 的删除——
    `.part` 不匹配导入侧的 glob，残留只会在重试时被覆盖或再删一次」——不需要
    随后 `fsync` 其目录（该清单在 S4a 范围内继续生效，契约未覆盖这一条）。
    """
    try:
        pfd, leaf = parent_fd_under(stg_fd, rel)
    except FileNotFoundError:
        return
    try:
        try:
            os.unlink(leaf + PART, dir_fd=pfd)
        except FileNotFoundError:
            pass
    finally:
        os.close(pfd)


def _replace_part_to_final(stg_fd: int, rel: str) -> None:
    """`.part` → final 的一次 `os.replace`，之后立即 `fsync` 其所在的 staging
    子目录（大 spec 耐久提交协议闭合清单：命名空间改动之后必须 `fsync` 其目录，
    契约 D 条款未覆盖这一条、继续生效）。`.part` 与 final 同目录，故 `src_dir_fd`
    与 `dst_dir_fd` 是同一个 `pfd`，只需一次 `fsync`。
    """
    pfd, leaf = parent_fd_under(stg_fd, rel)
    try:
        os.replace(leaf + PART, leaf, src_dir_fd=pfd, dst_dir_fd=pfd)
        fsync_dir(pfd)
    finally:
        os.close(pfd)


def _write_inflight_marker(stg_fd: int, slot: Slot) -> None:
    """写在途标记：tmp → `fsync`(文件) → `os.replace` → `fsync`(staging 根)，
    经 `qmt_fsroot.atomic_write_json` 的既有原子写路径（`full_sync` 取默认的
    `False`——大 spec 闭合清单只给 `.inflight.json` 的创建/删除记了普通
    `fsync`，`F_FULLFSYNC` 只用在 manifest 提交与 O2-F1 那道顺序屏障，
    两者都不是本函数）。
    """
    atomic_write_json(stg_fd, INFLIGHT, build_inflight_marker(slot))


def _remove_inflight_marker(stg_fd: int) -> None:
    """删在途标记，之后 `fsync` staging 根目录（大 spec 闭合清单：标记的创建与
    删除各自之后都要 `fsync(staging)`）。只在 `commit_stock` 成功之后调用——
    契约 D6：标记是「提交成功」与「终止整次运行」这两条出路的分界，提交没成功
    之前不许消失。
    """
    try:
        os.unlink(INFLIGHT, dir_fd=stg_fd)
    except FileNotFoundError:
        return
    fsync_dir(stg_fd)


def _apply_stock_records(manifest: dict, slot: Slot, records: list[dict],
                          committed_bytes: int) -> dict:
    """把这只股的两条新记录并入 manifest 的内存副本（不改动传入的 `manifest`）：
    `files` 里原有这只股的记录先摘掉、换成这两条；`pool_order` 若还没有这只股
    的锚点条目则按序追加一条（已在池则不重复追加，契约 D8/E3）；`cursor` 推进
    到 `universe_idx + 1`（`max` 是防御性写法，不假定调用方严格按序调用）；
    `committed_bytes` 由调用方传入——契约 D7 的累计写入量语义（`旧值 + 本次
    真正写盘字节`），不是 `sum(files[].bytes) + staged_export_log.bytes` 那种
    「当前占用量」语义（证据 E11：那种语义在崩溃恢复之后会死锁）。
    """
    out = dict(manifest)
    out["files"] = [f for f in manifest["files"] if f.get("stock_code") != slot.code] + records
    pool = {mk: list(v) for mk, v in manifest["pool_order"].items()}
    if not any(isinstance(e, dict) and e.get("code") == slot.code for e in pool[slot.market]):
        pool[slot.market] = pool[slot.market] + [
            {"code": slot.code, "universe_idx": slot.universe_idx}
        ]
    out["pool_order"] = pool
    cursor = dict(manifest["cursor"])
    cursor[slot.market] = max(cursor[slot.market], slot.universe_idx + 1)
    out["cursor"] = cursor
    out["committed_bytes"] = committed_bytes
    return out


def copy_stock(src_fd: int, stg_fd: int, slot: Slot, rel_1m: str, rel_daily: str,
               manifest: dict, *, ledger: RunLedger, budget: ByteBudget) -> tuple[str, dict]:
    """单股拷贝事务（契约 D1、D4 第 2 条、D5、D6、D8）：四象限 → 拷 `.part` →
    落地前比对 → 写在途标记 → 两次 `os.replace`（各自耐久 `fsync`）→ 按股提交
    （`qmt_manifest.commit_stock`）→ 删标记。

    `slot` 必须是 `qmt_pool.Slot`；`rel_1m` / `rel_daily` 是两条相对路径，
    次序钉死（契约 D1——路径怎么从 `Slot` 解析出来是 S4b 的范围，本函数只管
    收到之后怎么校验/怎么用）。

    **失败/终止路径（标记写下之前）**：删这只股的两个 `.part`、退还本次已扣的
    预算、原样上抛——既接候选失败（`StockCopyFailed`、`MaxBytesExhausted` 等
    源侧异常），也接终止条件（`SourceChangedMidRun`），两者的清理动作相同，
    只是调用方（S4b）对它们的后续处置不同。

    **标记写下之后，本函数不再捕获任何异常**（契约 D6：一经写下，只有「提交
    成功 + 删标记」与「终止整次运行」两条出路；接住异常继续下一只股这条路
    不存在，S4a 只负责抛，S4b 负责收）。

    返回 `("skipped", manifest)`——两个文件都已在池且完好，契约 D8：跳过由
    四象限判据本身承担，不做任何改动；或 `("committed", 提交后的那份 manifest)`。
    """
    if not isinstance(slot, Slot):
        raise TypeError(f"slot 必须是 qmt_pool.Slot，收到 {type(slot).__name__}")
    # D1：两条路径的前置校验——早于四象限、早于任何拷贝、早于在途标记。
    _validate_stock_paths(slot, rel_1m, rel_daily)

    rels = (rel_1m, rel_daily)
    by_key = {(f.get("stock_code"), f.get("relative_path")): f for f in manifest["files"]}
    records_in = [by_key.get((slot.code, rel)) for rel in rels]

    verdicts = [classify_target(stg_fd, rel, rec) for rel, rec in zip(rels, records_in)]
    if TARGET_UNTRACKED in verdicts:
        # D2 staging 半边：那个对象原样留着，不删不碰——候选失败，继续下一只。
        raise StockCopyFailed("untracked_target_file", slot.code)
    if all(v == TARGET_SKIP for v in verdicts):
        return "skipped", manifest          # D8：跳过由四象限判据本身承担

    written: dict[str, int] = {}
    new_records: list[dict] = []
    try:
        for rel, period, rec, verdict in zip(rels, _PERIODS, records_in, verdicts):
            if verdict == TARGET_SKIP:
                new_records.append(dict(rec))
                continue
            result = copy_one(src_fd, stg_fd, rel, budget)
            written[rel] = result.n_bytes
            # D4 第 2 条 + D5：任何有记录的格都要在落地前比对（含「有记录 ×
            # 目标不存在」那一格，不只是「重拷」那一格）；不符即终止整次运行，
            # 且必须早于在途标记与两次 os.replace（E5 与反事实对照）。
            if rec is not None and (result.n_bytes != rec["bytes"]
                                     or result.sha256 != rec["sha256"]):
                raise SourceChangedMidRun(
                    f"{rel}: 账本记录 {rec['sha256'][:8]}/{rec['bytes']} 字节，"
                    f"本次拷出 {result.sha256[:8]}/{result.n_bytes} 字节——"
                    "源在本次运行期间变了"
                )
            new_records.append({"stock_code": slot.code, "period": period,
                                 "relative_path": rel, "bytes": result.n_bytes,
                                 "sha256": result.sha256})
    except BaseException:
        for rel in rels:
            _cleanup_part(stg_fd, rel)
        for n in written.values():
            budget.refund(n)
        raise

    # ── 标记写下之后，只有两条出路（契约 D6）：本函数往下不再 try/except ──
    _write_inflight_marker(stg_fd, slot)

    for rel, verdict in zip(rels, verdicts):
        if verdict != TARGET_SKIP:
            _replace_part_to_final(stg_fd, rel)

    new_manifest = _apply_stock_records(manifest, slot, new_records, budget.used)
    committed = commit_stock(stg_fd, new_manifest, ledger=ledger)
    _remove_inflight_marker(stg_fd)
    return "committed", committed
