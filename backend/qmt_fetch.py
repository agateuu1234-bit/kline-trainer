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
  · **候选失败**——`StockCopyFailed`：这一只股这次不行，继续下一只。`reason`
    全集**闭合**（大 spec:492 + 契约 D3：不新增值，账本读侧不校验
    `failures[].reason`）共四个，本模块产生其中三个：`fetch_missing_file`
    / `fetch_copy_hash_mismatch`（Task 1）、`untracked_target_file`
    （Task 2/D2，fix round 2 · N1 起也覆盖「账本记录挂着与本次调用不同的
    `relative_path`」这一档，fix round 4 · C1 起还覆盖「`<rel>.part` 那个名字
    底下被植了非普通文件」这一档）——第四个 `fetch_interrupted_rollback` 由
    S4b 的崩溃恢复产生，详见 `StockCopyFailed` 类文档。
  · **终止条件**——`RunTerminated` 及其子类：整次运行必须停（rc≠0）。**三个成员**
    （fix round 7 起是三个）：`MaxBytesExhausted`（`--max-bytes` 预算耗尽）、
    `SourceChangedMidRun`（契约 D5：落地前比对发现源在本次运行期间变了）、
    `RollbackIncomplete`（失败收尾的回滚自己有项目没做完 —— staging 侧
    `EIO`/`EACCES` 是**这棵树**的事实、不是这只股的事实，与 R87-F1 给
    `source_path_escape` 的定性同族）。调用方要能用一个 `except RunTerminated`
    接住全族，且不会被它接住候选失败或路径逃逸。
  · **路径逃逸**——`qmt_fsroot.PathEscapeError`：信任边界被破坏，本模块不捕获、
    不包装，原样上抛（它不是 `OSError` 的子类，也不属于前两族）。

⚠️ **以上三族不是 `copy_stock` 唯一可能逃出的异常类型**——按 `raise` 语句逐条
枚举，另有**三种**（fix round 4 · N3 订正：此前这里写“两种”，漏掉了第三种
裸 `OSError`，而那一种恰恰是 D3 主动要求留下的；fix round 5 · Minor 1 再订正成
“四种”，把 `ByteBudget.refund` 的裸 `ValueError` 补进来；**fix round 7 改回
“三种”**，理由不是“跑不到所以不列”，而是**那条 `raise` 语句现在已经逃不出去了**：
`budget.refund` 在本模块里只剩 `_rollback_all` 这一个调用点，而那里对
`Exception` 逐项兜住，它只会以 `RollbackIncomplete.errors` 的一员、或
`original.__notes__` 的一条出现——本仓的判据是「穷尽性主张必须**按字面量枚举后
逐条定性**」，故此处的依据是逐条重数过 `refund(` 与 `_cleanup_part(` 的调用点各
只剩一个，不是概念推断）。

前两种是**调用方违反了本函数的前置契约**，不是某只股的事实、也不是环境变化
（fix round 2 · N2 定案）：
  · `bare TypeError`（`slot` 不是 `qmt_pool.Slot`），语义上是“函数签名违反”
    （与 Task 2 `_validate_record` 对坏 `record` 类型抛 `TypeError` 同规格）；
  · `qmt_normalize.QmtSchemaError` / `qmt_fsroot.PathDisciplineError`（契约
    D1：两条路径次序互换、或文件名解析出的代码/周期与 `slot`/次序不符）
    ——这两条路径来自调用方（S4b），出错是它没有满足“两条路径要与 `slot`
    对应、次序钉死”这条前提，不许折成 `failures` 的一个 `reason`。

第三种是**环境事实**：**裸 `OSError`**（源文件读不了 → `PermissionError`；
SMB 拷到一半断线 → `OSError(EIO)`；staging 写满 → `ENOSPC`……）。
契约 D3 **明禁**把它折进 `fetch_missing_file`（“打不开”与“不是普通文件”是两件
事，`_open_source_leaf` 与 `_open_part` 的窄 `except` 就是这条判据本身，
各有测试钉着），本模块也**不**把它包装成 `RunTerminated` —— **原样上抛**。
**本模块对它只给一条保证，而那是有前提的位置保证**（fix round 5 · Minor 2
订正：此前这句写成“它**只可能**逃在在途标记写下之前”，**那是假的**——
两次 `os.replace`、`commit_stock`、删标记这三处同样可能逃出裸 `OSError`，
再加上写标记时**发布之后**那次 `fsync(staging)`（fix round 6 · N1 补第四处），
结论靠紧跟其后的括号才救回来，而那句话单独拿出来就是错的）：
**逃在在途标记【发布】之前**的那些裸 `OSError`，逃出来的那一刻盘上什么都没落——
两个 `.part` 已删、本次扣的预算已退还、manifest 一个字段没动。
⚠️ **fix round 7 起这句话是无条件为真的，而在此之前它是假的**：此前回滚顺着写，
删 `.part` 撞 `EIO` 会让「另一个 `.part` 也删掉」「退账」双双落空，而逃出来的
仍然是一个裸 `OSError`（还是清理那个，不是原来那个）。现在回滚逐项独立执行，
**只要有任何一项没做完，逃出来的就不再是裸 `OSError`、而是
`RollbackIncomplete`（终止条件族）** ⇒ 见到裸 `OSError` 就等于回滚做完了。
**这条保证包含写标记这一步自己在发布之前炸掉的那一档**（fix round 6 · N1：
此前它是个例外，而那正是评审 [medium] 的洞——`.part` 与预算双漏）。
⚠️ **fix round 8 起它还包含「关描述符自己失败」那一档**（codex R5 的 [medium]）：
`os.close` **也是收尾动作**，而此前本模块的 12 个关闭点全裸在 `finally:` 里，
两种漏法各自可达 ——
  · `copy_one` 关**源**描述符那一句还在失败收尾的 `except` **外面**：拷贝成功、
    发布之后它抛 `OSError` ⇒ 本函数**永远不返回** ⇒ `copy_stock` 不会把这个文件
    记进 `written` ⇒ 外层回滚删得掉 `.part` 却**退不回这一趟的字节**（评审隔离
    故障注入实测：三个已扣字节留在账上）；
  · 任何一处 `finally` 里的关闭失败都会**顶替掉**正在展开的那个异常 ⇒
    `MaxBytesExhausted` / `PathEscapeError` / `StockCopyFailed` 变成裸 `OSError`，
    而本模块自己的契约又允许调用方把裸 `OSError` 当候选失败处置 ⇒ **必须停机的
    信号被降级成「这一只股不行」**（与 fix round 7 那条判据同一个形态的复发）。
⇒ **本模块此后只有一个关闭判据**：`_close_or_note`（`with _CloseFd(fd):` 是它的
外壳）。有异常在途 ⇒ 只挂 `add_note` 诊断、**在途异常的类型一个字不换**；没有
异常在途 ⇒ 原样上抛，而那时它落在失败收尾里，退账与清理照常执行。
全模块只剩**两处**裸 `os.close`：`_close_or_note` 自己那一句（**它就是判据本身**），
以及 `_probe_part` 探完类型就关那一句（它排在 `try` 之外、`_open_part` 已经返回
⇒ 执行到那里**不可能有异常在途**，顶替不了任何东西）。
⚠️ 代价登记在契约 §3b T5：展开途中的关闭失败被挂成诊断之后，那个描述符可能
没被回收。**S4b 读侧的一条**：这类失败**不进** `RollbackIncomplete.errors`
（它不让盘面/账面对不上），只在 `__notes__` 上——见契约 §4 第 16 条。
**标记发布之后逃出的裸 `OSError` 不在这条保证之内**，按下一段的**位置**判据
处置（调用方在那一段接到任何异常都必须按整次运行终止，不必检查类型）。
⚠️ **“跳过这只股”还是“终止整次运行”由 S4b 定，本片不替它选**（交接）：
无差别 `except OSError` 会把权限错误折成 `fetch_missing_file`（D3 明禁），
一路裸抛则会让一只股的一个读不了的源文件用 traceback 打死约 2 GiB 的整次运行、
而不是留下一条可读的停止记录。两条路都有代价，**而定性需要“这是哪一只股、
已经失败过几次”这类只有续跑循环才有的上下文** ⇒ 必须在 S4b 那一层做，
**不得回头放宽本模块里那两处 `except` 的宽度**（这条纪律两侧**各有一条**
测试钉着：源侧 `test_copy_stock_bare_oserror_from_source_escapes_unclassified`、
staging 侧 `test_open_part_bare_oserror_escapes_and_is_not_called_tampering`）。

（fix round 5 · Minor 1 曾在此列出**第四种**：`ByteBudget.refund` 的裸
`ValueError`“退还超过已扣”。**fix round 7 起它逃不出本模块了**——`refund` 的
调用点在本模块里只剩 `_rollback_all` 一个，那里逐项 `except Exception`，于是它
只会成为 `RollbackIncomplete.errors` 的一员、或挂在原异常 `__notes__` 上的一条
诊断。它原来的定性照旧成立：本模块自己的调用路径上不可达——`copy_one` 只退它
这一趟**逐块累加**出来的 `charged`，`copy_stock` 只退 `written` 里那些已经成功
扣过账、且此前没被退过的字节，两者恒 `<= budget.used`；只有调用方把同一个
`ByteBudget` 跨事务复用、或中途把 `used` 改小才触发得了。）

**标记写下之后** `commit_stock` 可能抛出的 `qmt_manifest.ManifestInvalidError`
（以及任何其它异常）**不要求属于 `RunTerminated`**——契约 D6 的判据是
**位置**（异常发生在标记写下之后），不是**类型**：调用方（S4b）只要处在
“标记还在盘上”这一事实下接到任何异常，就必须按整次运行终止处理，不必也
不应该去检查它的类型。
"""
from __future__ import annotations

import fcntl
import hashlib
import os
import stat
from datetime import datetime, timezone
from typing import NamedTuple

from qmt_fsroot import (
    NotARegularFileError,
    PathEscapeError,
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
    "RollbackIncomplete",
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

    `reason` 是给 4c 报告与账本 `failures` 记录读的字面量。**这个全集是
    闭合的**（大 spec:492 + 契约 D3 的取舍：不新增 `reason`，加值要同步改
    4c 报告 schema，而账本读侧不校验 `failures[].reason`，第五个取值会
    静默流进 manifest、落不进任何一个桶），**共四个**：`fetch_missing_file`
    / `fetch_copy_hash_mismatch` / `untracked_target_file` /
    `fetch_interrupted_rollback`（fix round 3 订正：此前这里漏列了第四个，
    却又说“第五个取值”——`_validate_stock_paths` 与大 spec:492 都是四个）。

    **本模块只产生其中三个**：`fetch_missing_file`（D3：源侧叶子不是普通
    文件，或干脆不存在）、`fetch_copy_hash_mismatch`（落地的 `.part` 重算
    与源哈希不符）、`untracked_target_file`（D2：staging 目标来路不明，
    拒绝覆盖；fix round 2 · N1 起也覆盖“账本记录挂着与本次调用不同的
    `relative_path`”这一档——同属“这只股当前的身份对不上账本”；
    fix round 4 · C1 起还覆盖 `<rel>.part` 那个名字底下被植了非普通文件
    ——`.part` 与 final 同处一棵可被篡改的 staging 树，见 `_open_part`）。
    **第四个 `fetch_interrupted_rollback` 由 S4b 的崩溃恢复产生**（大 spec
    §4.5：同一 `universe_idx` 的在途标记回滚累计到 3 次才记这一条），
    不在本模块的范围内。

    **D1 的两条路径校验不产生 `StockCopyFailed`**（fix round 2 · N2）——那
    是调用方违反前置契约，不是这只股的事实，见 `_validate_stock_paths`。
    本类不做穷尽性校验，只是把调用方传入的字符串原样带上。
    """

    def __init__(self, reason: str, detail: str = ""):
        self.reason = reason
        self.detail = detail
        super().__init__(f"{reason}: {detail}" if detail else reason)


class RunTerminated(Exception):
    """终止条件族的公共基类：整次运行必须停（rc≠0），既不是候选失败也不是路径逃逸。

    调用方用一个 `except RunTerminated` 就能接住全族。**三个成员**：
    `MaxBytesExhausted`（`--max-bytes` 预算耗尽）、`SourceChangedMidRun`
    （D5：源在本次运行期间换代，比对不符）、`RollbackIncomplete`
    （fix round 7：失败收尾的回滚自己有项目没做完 —— 盘面/账面已经对不上，
    且对不上的方式本模块并不知道）。
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


class RollbackIncomplete(RunTerminated):
    """终止条件族第三个成员（fix round 7 · 评审 [medium]）：**回滚自己没做完**。

    触发条件：某条失败收尾路径上，回滚的某一项（删 `.part` / 退还预算）自己抛了
    异常，**且在途的那个原异常本身还不是终止信号**（不是 `RunTerminated`、不是
    `PathEscapeError`、也不是 `KeyboardInterrupt` 那类非 `Exception` 的
    `BaseException`）。

    **为什么定性成终止条件，而不是把原异常原样放出去**：回滚的每一项都动 staging
    树或本次预算，任一项失败都意味着**盘面与账面已经对不上，而对不上的方式本函数
    并不知道**（`.part` 残留、或某一笔已扣的账退不回去）。`_cleanup_part` 抛出的
    `EIO`/`EACCES` 是 **staging 这个文件系统**的事实，不是这只股的事实——同一棵树上
    **后面每一只股都会撞到同一件事**。这与大 spec R87-F1 把 `source_path_escape`
    定性成「终止条件而非候选失败」（理由正是「同一目录下的所有股都受影响」）是
    **同一条判据的第五次应用**，也是契约 D5 复述的那一句：
    **「环境不对」不能记成「这个候选不行」**。
    反过来把原异常原样放出去，调用方（S4b）就会按「跳过这只股」继续跑，
    带着一棵它以为干净、实际并不干净的 staging 树。

    **不新增第五个 `reason`**：本类不是 `StockCopyFailed`，`failures` 里不会出现
    新取值（大 spec:492 + 契约 D3 的那份全集一个字没动）。
    **也不削弱 D6**：本类只可能在**在途标记发布之前**的那些收尾路径上抛出；
    标记一经发布，本模块不再做任何清理，也就没有「回滚」可言。

    携带两样东西，**两样都不顶替原异常**：
      · `original` —— 在途的那个原异常本身，同时经 `raise ... from` 挂在
        `__cause__` 上；
      · `errors` —— 回滚里失败的**全部**项（不是第一项），并逐条以 `add_note`
        挂到 `original` 上，于是无论调用方打印的是哪一个，诊断都在。
    """

    def __init__(self, original: BaseException,
                 errors: tuple[BaseException, ...]):
        self.original = original
        self.errors = errors
        detail = "；".join(f"{type(e).__name__}: {e}" for e in errors)
        super().__init__(
            f"回滚未做完（{len(errors)} 项失败：{detail}）；"
            f"在途的原异常是 {type(original).__name__}: {original}"
        )


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


def _close_or_note(fd: int, pending: BaseException | None) -> None:
    """关一个描述符——**关闭失败绝不顶替在途的那个异常**（fix round 8 · 评审 [medium]）。

    `pending` 是**此刻正在展开的那个异常**，由调用处**显式**交进来
    （`_CloseFd.__exit__` 的第二个形参，或 `except ... as e` 里的那个 `e`）：

      · `pending is None`（没有异常在途）⇒ 关闭失败**原样上抛**。它这时不是收尾
        动作，而是这条路径自己的结果——写侧描述符关不上意味着数据可能根本没落盘，
        咽掉它就是报一次假的成功。
      · `pending is not None` ⇒ 只把失败挂成 `pending` 的一条 `add_note` 诊断，
        `pending` 继续原样展开。**这正是本轮要消灭的那件事**：本模块的三族判据
        （候选失败 / 终止条件 / 路径逃逸）全靠**异常类型**，一次 `os.close` 的
        `EIO` 把 `MaxBytesExhausted` 或 `PathEscapeError` 换成裸 `OSError`，
        就等于把「必须停机」降级成「这一只股不行」（§4 第 10 条允许调用方
        这样处置裸 `OSError`）。

    ⚠️ **为什么不用 `sys.exc_info()` 自动判断「有没有异常在途」**：那拿到的是
    **整条调用栈**上正在被处理的异常，包括调用方（S4b）在自己的 `except` 块里调
    `copy_stock` 这种情形 ⇒ 本模块的关闭行为会取决于「谁在什么上下文里调它」，
    而不是本函数这一帧的事实。`__exit__` 的第二个形参就是这一帧的事实。

    捕获宽度是 `Exception` 而不是 `BaseException`，与 `_rollback_all` 同规格：
    `KeyboardInterrupt` / `SystemExit` 不是「这次关闭失败了」，不许被当成诊断咽掉。

    ⚠️ **已登记的代价**：关闭失败被挂成诊断之后，那个描述符可能没被回收
    （POSIX 对 `close()` 失败后描述符的归属不作保证）。本模块选它，是因为另一侧
    的代价——顶替掉一个终止信号——是**评审实测过的阻断级后果**，而漏一个描述符
    只在同一棵树反复报错时才累积得起来，且那时整次运行本来就该停。
    """
    try:
        os.close(fd)
    except Exception as e:
        if pending is None:
            raise
        pending.add_note(f"关描述符失败（fd={fd}）——{type(e).__name__}: {e}")


class _CloseFd:
    """`with _CloseFd(fd):` —— 离开这段时关掉 `fd`，判据走 `_close_or_note`。

    取代本模块此前那十处 `try: ... finally: os.close(fd)`（fix round 8）：
    `finally` 里的关闭失败会**顶替掉**正在展开的那个异常，而本模块整套调用方契约
    都挂在异常类型上。评审点名的是 `copy_one` 关源描述符那一处，但**按判据穷尽
    本模块**之后同型的 `finally` 共十处 ⇒ 收成**一个**判据、一处实现，不留第二份
    内联副本（「同一条判据只落在其中一处」是本模块自己反复申明的纪律）。

    `fd=None` 表示「这一档没有描述符要关」。它只服务 `classify_target` 里
    `open()` 本身失败（`NotARegularFileError`）那一格：那一格拿不到描述符，却必须
    继续走同一条 `_is_regular(st)` 判据，不许在那里另抄一份「非普通 ⇒ untracked」。
    """

    __slots__ = ("_fd",)

    def __init__(self, fd: int | None) -> None:
        self._fd = fd

    def __enter__(self) -> int | None:
        return self._fd

    def __exit__(self, exc_type, exc, tb) -> bool:
        if self._fd is not None:
            _close_or_note(self._fd, exc)
        return False


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
    with _CloseFd(pfd):
        try:
            return open_regular_probe(pfd, leaf, flags=os.O_RDONLY)
        except FileNotFoundError as e:
            raise StockCopyFailed("fetch_missing_file", f"{rel}: {e}") from e
        except NotARegularFileError as e:
            raise StockCopyFailed("fetch_missing_file", f"{rel}: {e}") from e


def _part_is_non_regular(stg_fd: int, name: str) -> bool:
    """staging 内 `name` 这个名字底下 **存在且不是普通文件** → `True`；其余
    （不存在 / 看不到 / 确实是普通文件）一律 `False` —— **不猜**。

    `name` 是**完整**的 staging 内相对名（`<rel>.part`，或 fix round 6 · C1 起
    写侧那个 `<rel>.part.<pid>.<随机>.tmp` 临时名）——**不是** `rel`：判据要问的
    是「我下一步要动的那个名字底下是什么」，把 `.part` 拼接藏在函数里会让临时名
    那个消费者拿到**另一个名字**的答案。

    逐段无跟随走到父目录再 `lstat` 叶子（不用 `os.stat(多分量路径)`：那会跟随
    中间分量的符号链接，正是 `parent_fd_under` 存在的理由）。
    `_open_part` 与 `_cleanup_part` 共用这一个判据，不各自内联一份。
    """
    try:
        pfd, leaf = parent_fd_under(stg_fd, name)
    except OSError:
        return False
    with _CloseFd(pfd):
        try:
            st = os.stat(leaf, dir_fd=pfd, follow_symlinks=False)
        except OSError:
            return False
    return not _is_regular(st)


def _open_part(stg_fd: int, name: str, *, flags: int, create_dirs: bool = False) -> int:
    """staging 侧 `.part` 一族名字的**唯一**打开点：`O_NONBLOCK` + 普通文件判据
    （fix round 4 · C1）。`name` 是**完整**的 staging 内相对名——`<rel>.part`
    本身，或 fix round 6 · C1 起写侧那个 `<rel>.part.<pid>.<随机>.tmp` 临时名。

    **`.part` 与 final 同处一棵可被篡改的 staging 树**，D2 给 final 立的那条纪律
    必须原样覆盖到它：一个被植进 `<rel>.part` 的 FIFO 会让不带 `O_NONBLOCK` 的
    `os.open()` **永久等对端**（写端等读者、读端等写者，两个方向都一样）——整次
    运行挂死在 `.staging.lock` 里、后续任何一次运行连启动都做不到，比 D2 要防的
    那个结局更糟，而且不是 fail-closed。

    **为什么不直接用 `qmt_fsroot.open_regular_probe`**（这条纪律的登记处，其
    docstring 写着「三个打开点统一走本函数，避免『同一条纪律只落在其中一处』」）：
    写侧这一次必须 `create_dirs=True`——staging 的 `1m/` / `daily/` 子目录正是由
    本模块第一次写临时文件时创建的，而 `open_regular_probe` 不转发这个参数，
    `qmt_fsroot` 在本片是禁改模块。故把同一条纪律在**本模块内收成这一个函数**：
    三个打开点（发布前探一次 `<rel>.part`、造临时文件、复算重读临时文件）
    都只经它。

    **定性 `untracked_target_file`**：D3 的判据是「这只股能不能继续」（不是
    「影响面多大」），而 `.part` 是 **staging 侧**的对象——来路不明就不许覆盖它、
    跳过这只股继续下一只，与 D2 对 final 的处置同一族。**不新增第五个 `reason`**
    （那份全集按大 spec:492 与契约 D3 闭合）。
    符号链接仍由 `open_under` 逐段无跟随抛 `PathEscapeError`（整次致命），不归本族；
    `PermissionError` / `EIO` / `ENOSPC` 等其它 `OSError` **原样上抛**，与
    `_open_source_leaf` 同规格：「打不开」与「不是普通文件」是两件事。

    ⚠️ **没有 `except IsADirectoryError`**（fix round 6 · C1 删掉）：那一条只在
    写侧直接 `O_WRONLY` 打开 `<rel>.part` 时可达，而写侧改成「造临时文件 + 发布」
    之后，目录只会被**只读探测**撞见——`O_RDONLY` 打开一个目录是**成功**的
    （与 `classify_target` 对 final 的那条判据同一套现象），于是它落在下面那句
    `S_ISREG` 上，`reason` 一个字不变。留着一条永不执行的 `except` 等于在代码里
    写一句假话。两条既有测试钉着这个结局（`test_copy_one_directory_at_part_is_
    untracked_target_file` / `test_copy_stock_directory_at_part_fails_closed_
    and_keeps_the_failure_reason`）。
    """
    try:
        fd = open_under(stg_fd, name, flags=flags | os.O_NONBLOCK,
                        mode=0o600, create_dirs=create_dirs)
    except FileNotFoundError:
        raise
    except OSError as e:
        # 打不开 ≠ 打不开的原因猜得到（FIFO 无读者给 `ENXIO`、socket 在 macOS 给
        # `EOPNOTSUPP`，各平台不同、还会变 —— 判据不枚举 errno）：回头 lstat 问
        # 文件系统「那底下到底是个什么东西」，与 `_open_regular_probe` 同一套判据。
        if _part_is_non_regular(stg_fd, name):
            raise StockCopyFailed(
                "untracked_target_file", f"{name}: 存在但不是普通文件（打不开）"
            ) from e
        raise
    try:
        if not _is_regular(os.fstat(fd)):
            # 带 `O_NONBLOCK` 时 FIFO（有读者）与目录（只读打开）都会**打开成功**，
            # 故这条 `S_ISREG` 不是多余的 —— 与 `classify_target` 对 final 的
            # 判据逐字同规格。
            raise StockCopyFailed("untracked_target_file", f"{name}: 不是普通文件")
        cur = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, cur & ~os.O_NONBLOCK)
        return fd
    except BaseException as e:
        # 在途的可能是上面那条 `S_ISREG` 抛出的 `StockCopyFailed
        # ("untracked_target_file")`——一次**有明确定性**的候选失败；关闭失败把它
        # 换成裸 `OSError`，这只股就丢掉了自己的 `reason`（fix round 8）。
        _close_or_note(fd, e)
        raise


def _probe_part(stg_fd: int, rel: str) -> None:
    """写之前问一次「`<rel>.part` 那个名字底下**现在**是什么东西」（fix round 6 · C1）。

    写侧不再直接打开 `<rel>.part`（见 `copy_one`），于是「被植进来的非普通对象
    必须撞 `untracked_target_file`、符号链接必须撞 `PathEscapeError`」这条既有
    纪律没有了**顺带**的落点——本函数就是它现在唯一的落点，判据原样走
    `_open_part`（同一套 `O_NONBLOCK` + `S_ISREG`，不另立一份）：

      · 符号链接 → `open_under` 逐段无跟随撞 `ELOOP` → `PathEscapeError`（整次致命）；
      · FIFO / 目录 / socket → `StockCopyFailed("untracked_target_file")`；
      · **普通文件**（上一次运行崩在半路留下的 `.part`）→ 正路，什么都不做：
        这是本 spec 自己产得出的合法状态，不得把它变成一次失败，随后那次发布
        用 `os.replace` **换目录项**盖掉它（不截断它的 inode）；
      · 那底下什么都没有 → `FileNotFoundError` → 正路。

    ⚠️ 只读打开一下就关掉：本函数只问类型，不持有它。

    ⚠️ **一处明写的行为变化**：那底下若是一个**读不了**的普通文件（比如被植了一个
    `0o200` 的文件），本函数撞 `EACCES` ⇒ 裸 `OSError` 上抛；改动前的 `O_WRONLY`
    打开会成功、然后把它**截断重写**。本工具自己写下的 `.part` 一律 `0o600`，
    故这一档只可能是外来对象——按本模块既有纪律（「打不开」原样上抛、别人植进来的
    对象一律不动手）这是正确的那一侧，不是回归。
    """
    try:
        fd = _open_part(stg_fd, rel + PART, flags=os.O_RDONLY)
    except FileNotFoundError:
        return
    # ⚠️ 这一句**故意**是裸 `os.close`，不走 `_CloseFd`（fix round 8 的穷尽定性）：
    # 它排在 `try` 之外、`_open_part` 已经返回，执行到这里**不可能有异常在途**
    # ⇒ 顶替不了任何东西；它自己失败就是这条路径自己的结果，原样上抛正确，
    # 而那时它落在 `copy_one` 的失败收尾里，退账与清理照常。
    os.close(fd)


def _new_part_suffix() -> str:
    """临时文件名的后缀：`.<pid>.<12 位随机十六进制>.tmp`。

    与 `qmt_fsroot._atomic_write_bytes` 逐条同规格（那里是本仓这条纪律的登记处）：
    **带 pid 与随机后缀**，故崩溃留下的旧临时文件不会被静默复用，也不可能被外人
    预先猜到名字占住。
    """
    return f".{os.getpid()}.{os.urandom(6).hex()}.tmp"


def _publish_part(stg_fd: int, rel: str, suffix: str) -> None:
    """把写好、且已复算过的临时文件发布成 `<rel>.part`：一次 `os.replace`。

    **`replace` 换的是目录项，不碰任何既存 inode 的字节**——这正是 fix round 6 · C1
    的全部要害（见 `copy_one`）。

    **没有随后的 `fsync(目录)`，而这是按大 spec 耐久提交协议闭合清单的入选判据
    算出来的，不是漏了**（该清单在 S4a 范围内继续生效，契约 §5 未覆盖它）：
    判据是「一个命名空间改动进本清单，当且仅当**它的丢失会改变后续运行的判断**」，
    而 `.part` 这个名字的**得失都不改变任何后续判断**——它不匹配导入侧的 glob、
    不进四象限判据（那一条只看 final）、崩溃恢复只按在途标记里明写的路径去
    `unlink` 且容忍不存在。清单里「失败路径上 `.part` 的删除」已经按同一条理由
    **显式豁免**；本次发布是同一个名字的**创建**，与豁免那一条同族。
    ⚠️ 还有一条更硬的理由：改动前的写法（`O_CREAT` 直接造出 `<rel>.part`）本身
    就是一次没有目录 `fsync` 的命名空间改动，本次改动**没有新增**任何一条目录项
    ——盘上的净效果仍然只是「出现一个叫 `<rel>.part` 的目录项」，只是造法换了。

    ⚠️ **已登记的残留窗口**：`_probe_part` 与这一句 `os.replace` 之间，别人仍然
    可以往 `<rel>.part` 上植东西，而 `replace` 会把它连名字一起换掉（POSIX 的
    `rename` 恒覆盖；`RENAME_NOREPLACE` / `RENAME_EXCL` 是平台私有、Python 不暴露，
    而且**合法的残留 `.part` 本来就必须被盖掉**，不覆盖这条路走不通）。
    **这个窗口里丢不了 staging 树外面的数据**——被换掉的只是那个目录项本身：
    FIFO / socket 不存数据，符号链接被 `replace` 换掉时**不跟随**、它指向的对象
    一个字节没动。相比改动前「`O_TRUNC` 直接清空硬链接对面的外部文件」，
    这是同一条时间线上严格更小的后果。
    """
    pfd, leaf = parent_fd_under(stg_fd, rel)
    with _CloseFd(pfd):
        os.replace(leaf + PART + suffix, leaf + PART,
                   src_dir_fd=pfd, dst_dir_fd=pfd)


def copy_one(src_fd: int, stg_fd: int, rel: str, budget: ByteBudget) -> CopyResult:
    """单文件流式拷贝：读源 → 流式 sha256 → 逐块扣账 → 写**一个全新 inode** →
    `fsync` → 对落地的那份重算并与源哈希比对 → `os.replace` 发布成 `<rel>.part`。

    ⚠️⚠️ **为什么不直接 `O_TRUNC` 写 `<rel>.part`**（fix round 6 · C1，评审
    [high]，本机复现）：`O_NOFOLLOW` 挡符号链接、`S_ISREG` 挡 FIFO/目录/socket，
    **两者都挡不住硬链接**——一个被植在 `<rel>.part` 上、指向 staging 树**外面**
    某个可写文件的硬链接，`lstat` 与 `fstat` 都如实回答「这是个普通文件」，
    于是本模块所有既有检查**全部通过**，而 `O_TRUNC` 在任何校验、任何回滚之前
    就已经把那个外部文件清空了（实测：145 字节的外部文件在 `copy_one` **正常
    返回**之后变成本次拷来的内容）。`st_nlink == 1` 这类检查与随后的截断之间
    必然存在窗口，**反复加检查关不掉它**。
    解法与 `qmt_fsroot._atomic_write_bytes`（本仓这条纪律的登记处，它为同一个
    威胁栽过三次：R3 / R5 / R8）**逐条相同**：**只写自己用 `O_CREAT|O_EXCL` 刚
    创建出来的 inode**，再 `os.replace` 发布——`replace` 换的是目录项、不碰目标
    inode 的字节，外部硬链接保有自己的数据。

    **发布之前先 `_probe_part` 探一次** `<rel>.part`：写侧不再打开那个名字，
    既有的「非普通对象一律 `untracked_target_file`、符号链接一律整次致命」纪律
    因此改由它承担（理由见 `_probe_part`）。**上一次运行崩在半路留下的普通
    `.part` 是合法状态，照常被发布盖掉，不是失败。**

    失败时（含 `--max-bytes` 触顶、源读/目的写中途报错、复算不符、`<rel>.part`
    底下被植了非普通文件——见 `_open_part`）**先删掉自己那个临时文件**，再退还
    本次已经扣过的账，然后原样上抛。
    ⚠️ **这两步各自独立执行、互不吃掉**（fix round 7 · 评审 [medium]，走
    `_rollback_all` / `_settle_rollback`）：删临时文件自己撞 `EIO`/`EACCES` 时，
    退账照做，原异常照旧是逃出去的那一个；而回滚只要有一项没做完，逃出去的就是
    `RollbackIncomplete`（终止条件族）而不是那个清理异常——一条清理故障绝不许
    伪装成这只股的候选失败。本函数**不**处理「这只股另一个文件怎么办」
    ——那是 Task 3 单股事务编排的范围，本函数只管它自己这一个文件的记账闭合。
    ⚠️ **fix round 8 起，「本函数不删 `<rel>.part`」这句话收窄了一格**（此前写的
    是无条件不删，理由是「那是别人或上一次运行的残留」）：**从准备发布那一刻起**
    `<rel>.part` 这个名字底下可能已经是本函数自己刚发布的那一份，而本函数分辨
    不了发布到底发生没有（见下面 `parts` 那一段）⇒ 这一档的失败要把它一起清掉，
    否则就是「已发布的落地物漏清 + 这一趟的字节漏退」。删除仍然只经
    `_cleanup_part` 那一个点，非普通对象照旧原样留着不碰。

    ⚠️ **关源描述符也在事务边界之内**（fix round 8 · 评审 [medium]）：它失败时
    若有异常在途，只挂诊断、**绝不换掉在途异常的类型**；若没有异常在途（拷贝
    成功、已发布），它自己那个裸 `OSError` 走的是同一条失败收尾——退账 + 清掉
    刚发布的 `.part`，于是「逃出来的那一刻盘上什么都没落」这条保证继续成立。

    ⚠️ **已登记的代价**：进程被 `SIGKILL` / 断电打断在「临时文件已创建、尚未
    发布」之间时，盘上会留下一个 `<rel>.part.<pid>.<随机>.tmp`，而崩溃恢复
    （S4b）按大 spec §4.5:487「只删标记里明写的那两条 target 与两条 `.part`，
    不做任何模式匹配式清扫」**不会**清理它。这与 `qmt_fsroot` 对自己那些临时
    文件接受的代价逐字相同（「崩溃留下的旧临时文件不会被静默复用」——它换来的
    正是「绝不截断既存 inode」），且改动前同一个窗口留下的是一个半截 `.part`，
    不是零残留。

    返回：成功时 `CopyResult(n_bytes=本次真正写盘的字节数, sha256=源内容哈希)`。
    """
    sfd, st = _open_source_leaf(src_fd, rel)
    charged = 0
    parts: tuple[str, ...] = ()
    try:
        # ⚠️ **关源描述符在事务边界之内**（fix round 8 · 评审 [medium]）。此前
        # 它裸在一个 `finally:` 里、在下面这个 `except` **外面**，于是两档都漏：
        #   (a) 拷贝成功、发布之后它自己抛 `OSError` ⇒ 本函数**永远不返回**
        #       ⇒ `copy_stock` 不会把这个文件记进 `written` ⇒ 外层回滚删得掉
        #       `.part` 却**退不回这一趟的字节**（评审隔离故障注入实测：三个
        #       已扣的字节留在账上）；
        #   (b) `MaxBytesExhausted` 展开途中它抛 `OSError` ⇒ 那个**终止信号被
        #       顶替成裸 `OSError`**，而 §4 第 10 条允许调用方把裸 `OSError` 当
        #       候选失败处置 ⇒ 必须停机的信号被降级成「这一只股不行」。
        # `_CloseFd` 把两档都收口：有异常在途只挂诊断（不换类型），没有异常在途
        # 则原样上抛——而那时它落在下面这个 `except` 里，退账与清理照常执行。
        with _CloseFd(sfd):
            if not _is_regular(st):
                raise StockCopyFailed("fetch_missing_file", f"{rel}: 不是普通文件")
            budget.precheck(st.st_size)

            suffix = _new_part_suffix()
            tmp = rel + PART + suffix
            parts = (tmp,)
            _probe_part(stg_fd, rel)
            dfd = _open_part(
                stg_fd, tmp,
                flags=os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                create_dirs=True,
            )
            with _CloseFd(dfd):
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
            digest = hasher.hexdigest()

            # 对落地的那份重算并与源哈希比对——不是恒等式：这里重新打开、
            # 重新从磁盘读回，不是复用上面流式算出的那个 hasher。
            rfd = _open_part(stg_fd, tmp, flags=os.O_RDONLY)
            with _CloseFd(rfd):
                verify = hashlib.sha256()
                while True:
                    chunk = os.read(rfd, _CHUNK)
                    if not chunk:
                        break
                    verify.update(chunk)
            if verify.hexdigest() != digest:
                raise StockCopyFailed("fetch_copy_hash_mismatch", rel)
            # ⚠️ 从**下一句之前**起，回滚要清的名字多一个 `<rel>.part`：发布一旦
            # 发生，本函数自己造出来的那份东西就叫这个名字，而「发布到底发生了
            # 没有」本函数**分辨不了**——`_publish_part` 在 `os.replace` 成功之后
            # 关目录描述符那一步同样可能失败，抛出来的只是一个裸 `OSError`。
            # `_cleanup_part` 容忍不存在、且不碰非普通对象，故在「发布没发生」
            # 那一档多列这个名字，至多是删掉一份**上一次运行崩在半路留下的陈旧
            # `.part`**——而那正是 `copy_stock` 的主回滚在同一条失败路径上本来
            # 就会做的事（登记在契约 §3b T4）。
            parts = (tmp, rel + PART)
            _publish_part(stg_fd, rel, suffix)
    except BaseException as exc:
        # 只删**自己造出来**的那些名字（`<rel>.part` 仅在「发布可能已经发生」
        # 之后才进这个名单，见上）；共用 Task 3 收尾那一个删除点，不在这里内联
        # 第二份「删之前先问类型」的判据。
        # ⚠️ 删与退**各自独立执行、互不吃掉**（fix round 7 · 评审 [medium]）：
        # 此前这里顺着写，删临时文件撞 `EIO` 会连退账一起跳过，还把原异常顶替掉。
        _settle_rollback(exc, _rollback_all(
            stg_fd, parts, (charged,) if charged else (), budget))
        raise

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
    `files` 里按 `(stock_code, period)` 查出来的那一条记录（形如
    `{"bytes": int, "sha256": str, ...}`），或 `None`（无记录）——**不按
    `relative_path` 查**（fix round 1 · C2 订正：按路径查会在这只股的记录
    换了路径时，把「有记录」误判成「无记录」，见 `copy_stock` 的查找逻辑）。

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
    with _CloseFd(pfd):
        try:
            fd, st = open_regular_probe(pfd, leaf, flags=os.O_RDONLY)
        except FileNotFoundError:
            return TARGET_COPY
        except NotARegularFileError as e:
            fd, st = None, e.st

    with _CloseFd(fd):
        if not _is_regular(st):
            return TARGET_UNTRACKED
        if record is None:
            return TARGET_UNTRACKED
        if st.st_size != record["bytes"]:
            return TARGET_RECOPY
        return TARGET_SKIP if _hash_target(fd) == record["sha256"] else TARGET_RECOPY


# ── Task 3：在途标记 + 单股事务编排（契约 D1、D4 第 2 条、D5、D6、D8）──

INFLIGHT = ".inflight.json"

# ⚠️ 必须与 `qmt_manifest.PERIODS` 逐字相同：本元组决定 `commit_stock` 收到的
# 两条记录的 `period` 取值，一旦分叉，撞的是 `_validate_files`——而那已经在
# **在途标记写下、两个 final 落地之后**，正是 D6 要消灭的状态。
# 由 `test_periods_tuple_agrees_with_qmt_manifest` 钉住（不靠这行注释自称）。
_PERIODS = ("1m", "daily")


def build_inflight_marker(slot: Slot, rel_1m: str, rel_daily: str) -> dict:
    """`.inflight.json` 的形状——**大 spec §4.5:468 钉死**，契约 §5 收尾段声明
    「`.inflight.json` 的字段形状」继续生效（本片未覆盖这一条）：
    `{code, universe_idx, targets: [两条 staging 内相对路径], parts: [两条
    .part 路径], started_at}`。

    **不含 `market`**：大 spec 没有把它列进这份形状。S4b 崩溃恢复要构造
    `qmt_manifest.RecoveryScope` 时，`market` 可以从 `code` 的后缀直接派生
    （`STOCK_CODE_RE` 形如 `^\\d+\\.(SH|SZ|BJ)$` 已经保证了这一点），没有必要
    在标记里再存一份可能与 `code` 语义重复的字段。

    `targets`/`parts` 必须是**这次事务真正会去 `os.replace`/`unlink` 的那两条
    路径本身**，不是调用方之后可以重新推导出来的东西——大 spec §4.5:487
    规定崩溃恢复「只删标记里明写的那两条 target 与两条 `.part`，不做任何
    模式匹配式清扫」，而两条路径怎么从 `Slot` 解析出来这件事本身在契约 D1
    里明写尚未选定路线；标记必须把「这一次实际用的是哪两条」原样钉住，
    不能让 S4b 靠事后重新解析去猜。

    只此一处构造标记内容——`copy_stock` 与 S4b 的崩溃恢复必须读同一份形状
    定义，不得各自内联一份（本仓「写侧形状与读侧要求必须逐字相同」反复栽过
    的那类坑）。
    """
    if not isinstance(slot, Slot):
        raise TypeError(f"slot 必须是 qmt_pool.Slot，收到 {type(slot).__name__}")
    return {
        "code": slot.code,
        "universe_idx": slot.universe_idx,
        "targets": [rel_1m, rel_daily],
        "parts": [rel_1m + PART, rel_daily + PART],
        "started_at": datetime.now(timezone.utc).isoformat(),
    }


def _validate_stock_paths(slot: Slot, rel_1m: str, rel_daily: str) -> None:
    """契约 D1 的前置校验：两条相对路径的次序钉死为 `(1m, daily)`，且各自的
    文件名都必须解析出这只股的代码。

    纯字符串/正则判据（`split_relative_components` + `parse_qmt_filename`），
    **不碰文件系统**——必须排在四象限判据、拷贝、在途标记之前：一个没有前置
    校验的实现会一路跑到 `commit_stock` 才被 `_validate_files` 拒掉，而那时
    两个 final 已落地、标记还在盘上，正是 D6 要消灭的状态（契约 D1 的警告）。

    ⚠️ **坏输入原样上抛 `QmtSchemaError`/`PathDisciplineError`（fix round 2 ·
    N2 订正）——不折进 `StockCopyFailed`，不属于三族任何一个**，与裸
    `TypeError`（`slot` 类型不对）同规格：这两条路径来自调用方（S4b），
    文件名解析出的代码与 `slot` 不符、或次序被互换，是**调用方违反了本函数
    的前置契约**（两条路径要与 `slot` 对应、次序钉死），不是这只股的事实、
    也不是环境变化——不许把它记成 `failures` 的一个 `reason`：大 spec:492
    与契约 D3 都把 failure 的 `reason` 全集声明为**闭合**（`fetch_missing_
    file` / `fetch_copy_hash_mismatch` / `untracked_target_file` /
    `fetch_interrupted_rollback`），账本读侧不校验 `failures[].reason`，
    一个第五个取值会静默流进 manifest、落不进 4c 报告 schema 的任何一个桶。
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


def _cleanup_part(stg_fd: int, name: str) -> None:
    """删 staging 内 `name` 这个名字底下的 `.part` 一族残留，容忍不存在。

    `name` 是**完整**的 staging 内相对名（fix round 6 · C1 起有两类消费者：
    事务收尾传 `<rel>.part`，`copy_one` 的失败路径传它自己那个
    `<rel>.part.<pid>.<随机>.tmp` 临时名）——**不是** `rel`：下面那道类型闸问的
    必须是「我马上要 `unlink` 的**那个**名字」，把 `.part` 拼接藏在函数里会让
    临时名那个消费者拿着**另一个名字**的答案去删自己的文件。

    大 spec 耐久提交协议闭合清单的显式豁免：「失败路径上 `.part` 的删除——
    `.part` 不匹配导入侧的 glob，残留只会在重试时被覆盖或再删一次」——不需要
    随后 `fsync` 其目录（该清单在 S4a 范围内继续生效，契约未覆盖这一条）。

    ⚠️ **删之前先问一次「那名字底下现在是个什么东西」**（fix round 4 · C1）：
    本函数只在失败收尾路径上被调用，而 `os.unlink` 对一个**目录**会抛
    `EPERM`（macOS）/ `EISDIR`（Linux）。
    非普通文件一律**原样留着、不删不碰**，与 D2 对 final 的处置同一条。
    ⚠️ **fix round 7 起这道闸挡的东西变了，但它更要留着**：外层 `_rollback_all`
    现在会兜住本函数抛出的异常，所以它不再会**顶替掉**原异常（那是当初写下这道闸
    的理由）；可一旦被兜住，回滚就算「不完整」，`_settle_rollback` 会把一次本来
    只是 `untracked_target_file` 的**候选失败升级成整次运行终止**。
    也就是说：没有这道闸，「`.part` 底下被植了一个目录」这种完全在预期内、
    D2 明写该按候选失败处置的情形，会被一路升级成停机。

    ⚠️⚠️ **符号链接被这道闸一起挡住是【故意的】，不是照抄判据的副作用**
    （fix round 5 · B）：`_part_is_non_regular` 走的是 `lstat`，所以
    `<rel>.part` 那个名字底下被植的**符号链接**也算「非普通」⇒ 一样留着不删。
    **这不与契约 §2 D2 的「非普通文件不含符号链接」冲突**，因为两者裁的**不是
    同一个决定**：D2 管的是**覆盖裁决**（这个对象能不能被当成一次正常的重拷
    目标覆盖掉），它把符号链接排除在外，是因为符号链接在**打开**那一刻就已经
    由 `open_under` 逐段 `O_NOFOLLOW` 撞 `ELOOP` 变成 `PathEscapeError`
    （整次致命），不许被降级成「这只股的目标来路不明」；本函数管的是**失败
    收尾时删不删**——对象、时机、后果都不同，D2 的排除条款管不到这里。
    **取舍已定案**：别人植进来的对象，本工具一律不动手——不替攻击者把证据
    顺手删掉，也不 `unlink` 一个可能指向 staging 树外的名字（fail-closed）。
    **代价明写**：同一处植入会让**后续每一次运行都死在同一个
    `PathEscapeError` 上，直到有人去看一眼**——一次信任边界破坏就该有人处理，
    不该被下一次运行悄悄抹平。

    ⚠️ **由此，大 spec §4.5 步骤 1「失败即删掉这只股的两个 `.part`」在 S4a
    范围内被收窄，且只收窄「被篡改」那一档**：`.part` 是普通文件（本工具自己
    写下的残留）时照删不误，只有那个名字底下是非普通对象时才留着不碰。
    **两个方向各有一条测试钉着**（`test_cleanup_keeps_a_planted_symlink_at_part`
    / `test_cleanup_still_removes_an_ordinary_part_on_the_failure_path`）——
    此前两个方向都没有测试，正是这条语义能被悄悄改掉的原因。
    """
    if _part_is_non_regular(stg_fd, name):
        return
    try:
        pfd, leaf = parent_fd_under(stg_fd, name)
    except FileNotFoundError:
        return
    with _CloseFd(pfd):
        try:
            os.unlink(leaf, dir_fd=pfd)
        except FileNotFoundError:
            pass


def _rollback_all(stg_fd: int, part_names, refunds, budget: ByteBudget):
    """失败收尾的**唯一**执行点：把回滚拆成互相独立的若干项，**逐项执行、逐项兜住
    异常**，返回失败明细 `[(这一项叫什么, 异常), ...]`（空列表＝回滚完整）。

    ⚠️ **为什么不能顺着写成一串语句**（fix round 7 · 评审 [medium]，三处同型）：
    顺着写时第一项一旦抛异常，后面每一项都**不会执行**——另一个 `.part` 不删、
    本次扣的账不退——而且那个清理异常还会**顶替掉**在途的原异常。实测后果：一个
    意思是「终止整次运行」的 `SourceChangedMidRun` 会变成一个裸 `OSError` 逃出去，
    而本模块自己的调用方契约又允许把裸 `OSError` 当候选失败处置 ⇒ 一条**必须停机**
    的信号被降级成「这一只股失败了」，正是本片从头在防的那次混淆；同时那笔没退的账
    会喂出一次**假的** `--max-bytes` 触顶（已登记残留 R1 那条「一次基础设施故障被
    记成一次正常结束」）。

    **删在前、退在后**（契约 D7：「在回滚删掉 `.part` 之后按实际写出的字节数退还」）
    ——本函数保留这个次序，只是不再让前面一项的失败吃掉后面的项。

    捕获宽度是 `Exception` 而不是 `BaseException`：`KeyboardInterrupt` / `SystemExit`
    不是「这一项回滚失败了」，不许被收进明细当成诊断顺手咽下去。
    """
    errors: list[tuple[str, BaseException]] = []
    for name in part_names:
        try:
            _cleanup_part(stg_fd, name)
        except Exception as e:
            errors.append((f"删 {name}", e))
    for n in refunds:
        try:
            budget.refund(n)
        except Exception as e:
            errors.append((f"退还 {n} 字节", e))
    return errors


def _settle_rollback(original: BaseException, errors) -> None:
    """回滚做完之后的收口：挂诊断，必要时把原异常**升级**成终止信号。三支：

      · **回滚完整**（`errors` 空）⇒ 什么都不做，调用方紧跟的裸 `raise` 把原异常
        原样抛出去——与本次改动之前逐字同结局。
      · **回滚不完整、而原异常本来就已经必须终止整次运行** ⇒ **只挂诊断，绝不换掉
        它的类型**：`RunTerminated` 的族籍、以及 `PathEscapeError` 的「本模块不捕获、
        不包装、原样上抛」都是调用方的判据，换掉就是本次评审要消灭的那种顶替。
        `KeyboardInterrupt` 那类非 `Exception` 的 `BaseException` 同样原样放行
        （把一次中断换成别的类型等于吃掉它）。
      · **回滚不完整、且原异常不是终止信号** ⇒ 抛 `RollbackIncomplete`
        （`raise ... from original`）：盘面/账面已经对不上，不许让调用方按
        「跳过这只股」继续跑。原异常挂在 `.original` 与 `__cause__` 上，一个字没丢。

    ⚠️ **诊断挂在 `original` 上而不是只挂在新异常上**（`add_note`，Python 3.11+）：
    第二支根本不造新异常，若只挂新异常上那一支的诊断就没了；挂在 `original` 上则
    三支通吃，且 `RollbackIncomplete.errors` 仍然结构化地拿得到同一批异常对象。
    """
    if not errors:
        return
    for label, e in errors:
        original.add_note(f"回滚未完成：{label} 失败——{type(e).__name__}: {e}")
    if isinstance(original, (RunTerminated, PathEscapeError)):
        return
    if not isinstance(original, Exception):
        return
    raise RollbackIncomplete(
        original, tuple(e for _label, e in errors)) from original


def _replace_part_to_final(stg_fd: int, rel: str) -> None:
    """`.part` → final 的一次 `os.replace`，之后立即 `fsync` 其所在的 staging
    子目录（大 spec 耐久提交协议闭合清单：命名空间改动之后必须 `fsync` 其目录，
    契约 D 条款未覆盖这一条、继续生效）。`.part` 与 final 同目录，故 `src_dir_fd`
    与 `dst_dir_fd` 是同一个 `pfd`，只需一次 `fsync`。
    """
    pfd, leaf = parent_fd_under(stg_fd, rel)
    with _CloseFd(pfd):
        os.replace(leaf + PART, leaf, src_dir_fd=pfd, dst_dir_fd=pfd)
        fsync_dir(pfd)


def _write_inflight_marker(stg_fd: int, slot: Slot, rel_1m: str, rel_daily: str) -> None:
    """写在途标记：tmp → `fsync`(文件) → `os.replace` → `fsync`(staging 根)，
    经 `qmt_fsroot.atomic_write_json` 的既有原子写路径（`full_sync` 取默认的
    `False`——大 spec 闭合清单只给 `.inflight.json` 的创建/删除记了普通
    `fsync`，`F_FULLFSYNC` 只用在 manifest 提交与 O2-F1 那道顺序屏障，
    两者都不是本函数）。
    """
    atomic_write_json(stg_fd, INFLIGHT, build_inflight_marker(slot, rel_1m, rel_daily))


def _inflight_marker_on_disk(stg_fd: int) -> bool:
    """`.inflight.json` 那个名字底下**现在有没有东西**（fix round 6 · N1）。

    **用途只有一个**：`_write_inflight_marker` 抛异常之后，回答「**发布到底有没有
    发生过**」——契约 D6 的分界不是「写标记这个函数返回了没有」，而是「盘上有没有
    那份标记」。`qmt_fsroot._atomic_write_bytes` 的发布动作是 `os.replace(tmp,
    name)`：
      · 在它**之前**炸（`lstat` 守卫拒绝、临时文件 `open`/`write`/`fsync` 撞
        `ENOSPC`、`os.replace` 本身失败）⇒ 临时文件已被它自己 `unlink` 掉，
        那个名字底下**什么都没有** ⇒ 标记没发布；
      · 在它**之后**炸（紧跟的那次 `fsync(staging)` 撞 `EIO`）⇒ 目录项已经在了
        ⇒ 标记**已发布**，D6 从这一刻起接管。

    ⚠️ **`follow_symlinks=False`，且「看不清就算有」**：这道判据只用来决定「要不要
    动手清理」，而清理是**破坏性**的。两种含糊情形一律答 `True`（保守偏向 D6，
    宁可漏退一次预算，也不删掉一份可能还在授权回滚的凭据）：
      · 那底下是个非普通对象（符号链接/目录/…）——`atomic_write_json` 的 `lstat`
        守卫会因此拒绝写入，标记确实没发布，但这是一次**信任边界被动过**的现场，
        整次运行无论如何都要停，不该由本函数顺手把两个 `.part` 删掉；
      · `os.stat` 自己报了个 `FileNotFoundError` 以外的错（权限/`EIO`）——
        **看不清 ≠ 不存在**。
    """
    try:
        os.stat(INFLIGHT, dir_fd=stg_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return True


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
    到 `max(旧值, universe_idx + 1)`。

    ⚠️ **`max()` 不是防御性写法，是承重构件**（fix round 1 · I3 订正此前的
    误判）：崩溃恢复第③档会把 `cursor` 回退到早于某些已在池的股（契约 D8 末
    段），重拉那些股走的正是这里——`universe_idx` 届时会**小于**当前
    `cursor`，若直接赋值成 `universe_idx + 1` 会让 cursor **倒退**，
    重新打开一批已经在池、且刚被这次重拷证明完好的股，被 `fresh_slots`
    当成尚未处理的新槽位。同理，pool_order 的去重判据不是「防止偶尔重复」，
    是重拷（含崩溃恢复后重跑到已在池的股）**必然**撞见的常态路径。
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

    **前置校验（不消耗预算、不碰文件系统）先抛两类不属于任何族的异常**
    （fix round 2 · N2 定案：这些是调用方违反了本函数的前置契约，不是这只股
    的事实）：`slot` 类型不对 → 裸 `TypeError`；两条路径次序互换、或文件名
    解析出的代码/周期与 `slot`/次序不符 → `qmt_normalize.QmtSchemaError` /
    `qmt_fsroot.PathDisciplineError`。

    **失败/终止路径（标记发布之前）**：删这只股的两个 `.part`、退还本次已扣的
    预算、原样上抛——既接候选失败（`StockCopyFailed`，`reason` 可能是
    `fetch_missing_file` / `fetch_copy_hash_mismatch` / `untracked_target_file`
    ——后者现在也覆盖「账本记录挂着与本次调用不同的 `relative_path`」
    （fix round 2 · N1）与「`<rel>.part` 底下被植了非普通文件」
    （fix round 4 · C1）），也接终止条件（`SourceChangedMidRun` /
    `MaxBytesExhausted`），也接**写标记这一步自己在发布之前炸出来的裸 `OSError`**
    （fix round 6 · N1：`ENOSPC` 之类，此前这一档既漏删 `.part` 又漏退预算），
    三者的清理动作相同，只是调用方（S4b）对它们的后续处置不同（第一种跳过这只股
    继续下一只，后两种终止整次运行）。

    ⚠️ **回滚自己失败那一档**（fix round 7 · 评审 [medium]）：两条 `.part` 的删除
    与两笔退账是**四件互相独立的事**，走 `_rollback_all` 逐项执行、逐项兜住异常，
    再由 `_settle_rollback` 收口——
      · 回滚完整 ⇒ 原异常原样上抛（与改动前逐字同结局）；
      · 回滚不完整、而原异常本来就是终止信号（`RunTerminated` / `PathEscapeError`）
        ⇒ **类型一个字不换**，清理诊断以 `add_note` 挂上去；
      · 回滚不完整、原异常还不是终止信号（`StockCopyFailed` / 裸 `OSError`）
        ⇒ 抛 `RollbackIncomplete`（终止条件族，`.original` + `__cause__` 保留原异常）。
    此前这里顺着写：第一条 `.part` 撞 `EIO` 会让第二条不删、两笔账都不退，而那个
    清理 `OSError` 还会**顶替掉**在途的原异常 —— 于是一个意思是「终止整次运行」的
    `SourceChangedMidRun` 会以裸 `OSError` 的样子到达调用方，而本模块自己的契约
    又允许把裸 `OSError` 当候选失败处置 ⇒ **必须停机的信号被降级成「这一只股失败
    了」**，正是本片从头在防的那次混淆。

    **标记一经发布，本函数不再对任何异常做任何处置**（契约 D6：只有「提交
    成功 + 删标记」与「终止整次运行」两条出路；接住异常继续下一只股这条路
    不存在，S4a 只负责抛，S4b 负责收）。⚠️ **分界是「发布有没有发生」，不是
    「写标记那个函数返回了没有」**（fix round 6 · N1）：`atomic_write_json` 在
    `os.replace` **之后**的那次 `fsync(staging)` 上炸时，标记**已经**在盘上，
    本函数此时一个字节都不清理、一分钱都不退，原样上抛——判据见
    `_inflight_marker_on_disk`。⚠️ 这一段可能逃出的异常**不限于**
    `RunTerminated`——`commit_stock` 可能抛出 `qmt_manifest.ManifestInvalidError`
    等其它类型。契约 D6 的判据是**位置**（标记已经发布），不是**类型**：
    调用方在这一段捕到任何异常都必须按整次运行终止处理，不必检查它的类型。

    返回 `("skipped", manifest)`——两个文件都已在池且完好，契约 D8：跳过由
    四象限判据本身承担，不做任何改动；或 `("committed", 提交后的那份 manifest)`。
    """
    if not isinstance(slot, Slot):
        raise TypeError(f"slot 必须是 qmt_pool.Slot，收到 {type(slot).__name__}")
    # D1：两条路径的前置校验——早于四象限、早于任何拷贝、早于在途标记。
    _validate_stock_paths(slot, rel_1m, rel_daily)

    rels = (rel_1m, rel_daily)
    # D4 第 2 条的触发条件是「账本里有这只股的记录」，不是「账本里有这条
    # relative_path 的记录」——键必须按 (stock_code, period)，不能按
    # (stock_code, relative_path)。理由：两条路径怎么从 Slot 解析出来还没定
    # （契约 D1），若账本里这只股的记录挂在与本次不同的 relative_path 下，
    # 按路径查找会查不到、把它当成「无记录」而跳过比对，两个 final 落地、
    # 标记写下，直到 commit_stock 才被 `_validate_files` 拒掉——那时标记与
    # final 都已经在盘上，正是 D5/D6 要消灭的状态。`_validate_files` 保证
    # 「池内每只股恰两条记录、period 分别为 1m/daily」，故按 period 查找
    # 对一只已在池的股至多命中一条，不会有歧义。
    by_period: dict[str, dict] = {}
    for f in manifest["files"]:
        if f.get("stock_code") == slot.code:
            by_period[f.get("period")] = f
    records_in = [by_period.get(period) for period in _PERIODS]

    # fix round 2 · N1：C2 把查找键改按 period 之后，若账本对某个周期已有
    # 记录、但那条记录的 relative_path 与本次调用给的路径不一致（生产场景：
    # 股票改名/ST 状态变化换了文件名里的 {name} 段，S4b 解析出一条新路径），
    # 必须在四象限判据之前就拒绝——不能让四象限或落地前比对把它悄悄放过去：
    #   · 新路径下文件恰好完好 → 四象限判 SKIP → 旧记录被原样提交，
    #     指向一条盘上并不存在的路径，新路径那份完好的文件反而没有任何记录；
    #   · 新路径下文件不存在、源内容与旧记录一致 → 落地前比对（D5/D4 第 2
    #     条）通过 → 两个 final 落地、标记写下，直到 commit_stock 才因
    #     「会把已提交的 files 记录…回滚掉」拒绝——标记与 final 都已经在盘上，
    #     正是 D6 要消灭的状态。
    # qmt_manifest 的转移守卫（不得修改）没有 RecoveryScope 就不允许「同一
    # (stock_code, period) 换一条 relative_path」这种隐式迁移，而发放
    # RecoveryScope 是 S4b 崩溃恢复的职责，不是单股事务该做的事——一律拒绝，
    # 继续下一只（同一族 `untracked_target_file`：这只股当前的身份对不上
    # 账本，与「目标存在但无记录」是同一件事的另一种成因）。
    for rel, rec in zip(rels, records_in):
        if rec is not None and rec.get("relative_path") != rel:
            raise StockCopyFailed(
                "untracked_target_file",
                f"{slot.code} 在账本里 {rec.get('period')!r} 周期的记录挂在 "
                f"{rec.get('relative_path')!r}，与本次调用给的 {rel!r} 不一致"
                "——多半是股票改名/ST 状态换了文件名段；路径迁移不是单股事务"
                "的职责，这只股这次跳过。",
            )

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
    except BaseException as exc:
        # ⚠️ 两条 `.part` 的删除与两笔退账**互相独立**（fix round 7 · 评审 [medium]）：
        # 任一项失败都不得跳过其余项，也不得顶替掉在途的原异常——此前这里顺着写，
        # 第一条 `.part` 撞 `EIO` 就会让第二条不删、两笔账都不退，而那个 `OSError`
        # 还会把一个 `SourceChangedMidRun`（必须停机）伪装成一次普通的单股失败。
        _settle_rollback(exc, _rollback_all(
            stg_fd, [rel + PART for rel in rels], list(written.values()), budget))
        raise

    # ── 写在途标记：**这一步自己也可能失败，而 D6 的分界是「发布有没有发生」**
    # （fix round 6 · N1，评审 [medium]）。此前这一行裸在回滚处置之外，于是
    # `atomic_write_json` 在**发布之前**失败（创建/写临时文件时撞 `ENOSPC`……）
    # 会同时漏掉两件事：两个已经拷好的 `.part` 留在盘上，本次扣的账也不退
    # ——什么都没提交、也没有任何恢复凭据，而预算被永久占着 ⇒ 调用方接住这个
    # 裸 `OSError` 继续跑下去就可能撞上一次**假的** `--max-bytes` 触顶
    # （正是已登记残留 R1 那条「一次基础设施故障被记成一次正常结束」的喂料口）。
    # 处置按**位置**分两支，与本函数其余部分同一条判据：
    #   · 发布**没**发生 ⇒ 与上面那些标记前失败路径**逐字同规格**：删两个 `.part`、
    #     退还本次已扣的账、原样上抛（盘上什么都没落、manifest 一个字段没动）；
    #   · 发布**已经**发生 ⇒ D6 从那一刻起接管：**一个字节都不清理、一分钱都不退**，
    #     标记原样留在盘上当回滚凭据，原样上抛，由 S4b 终止整次运行。
    try:
        _write_inflight_marker(stg_fd, slot, rel_1m, rel_daily)
    except BaseException as exc:
        if _inflight_marker_on_disk(stg_fd):
            raise
        # 与上面那条标记前失败路径**逐字同规格**，含「回滚自己失败」这一档
        # （fix round 7 · 评审 [medium]）：逐项独立、诊断不顶替原异常、
        # 回滚不完整则升级成终止信号。
        _settle_rollback(exc, _rollback_all(
            stg_fd, [rel + PART for rel in rels], list(written.values()), budget))
        raise

    # ── 标记写下之后，只有两条出路（契约 D6）：本函数往下不再 try/except ──

    for rel, verdict in zip(rels, verdicts):
        if verdict != TARGET_SKIP:
            _replace_part_to_final(stg_fd, rel)

    new_manifest = _apply_stock_records(manifest, slot, new_records, budget.used)
    committed = commit_stock(stg_fd, new_manifest, ledger=ledger)
    _remove_inflight_marker(stg_fd)
    return "committed", committed
