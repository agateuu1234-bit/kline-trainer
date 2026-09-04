"""`fetch_manifest.json` —— `qmt_fetch` 写、`qmt_pilot` 读的唯一真相源。

Spec: `docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md` §4.4 + §4.5
（含文末「S2 实施轮」五条更正）。

本模块只做两件事，**不碰网络、不碰拷贝、不碰数据库**：
1. 定义 manifest 的结构与版本；
2. 读侧**闭合**校验（fail-closed，绝不「尽力而为地解析」）——纯函数，零文件系统。

（两个提交入口 + `stopped_reason` / `fetch_fatal_error` 的生命周期决策**落盘**逻辑
属于 S2b；本片只定义这些字段的**形状校验**。）

⚠️ **为什么读侧校验必须闭合**：一个被截断的 manifest 解析出来往往仍是合法 JSON
的**前缀片段**，静默消费它 = 把 manifest 损坏伪装成「候选就这么多」，最终产出一份
**会撒谎的 pilot 报告**（R1-F4）。
"""
from __future__ import annotations

import copy
import hashlib
import weakref
import json
import os
import re
import stat
from dataclasses import dataclass
from types import MappingProxyType
from typing import Iterable, Mapping

from qmt_fsroot import (
    PathDisciplineError,
    atomic_write_bytes,
    encode_json,
    open_regular_probe,
    NotARegularFileError,
    split_relative_components,
)
from qmt_normalize import QmtSchemaError, parse_qmt_filename

# ── 版本 ─────────────────────────────────────────────────────
# 新增任何**必需**字段都必须 bump 本值（spec O2-F8）。可选字段经
# 「未知顶层键原样保留」通道流转，不需要 bump。
MANIFEST_VERSION = 1

MANIFEST_NAME = "fetch_manifest.json"

MARKETS = ("SH", "SZ", "BJ")
PERIODS = ("1m", "daily")

# 必需顶层键的**外延**（写死，不做「凡是我认识的都必需」这种开放定义）。
# ⚠️ 顶层**没有** `universe`（S2-F3）：名单的唯一位置是 `source_snapshot.universe`。
# 原 spec 把它列成顶层必需键，而写侧从不产出它 → 本工具诚实产出的每一份 manifest
# 都会被本工具自己的读侧判 FAIL_MANIFEST_INVALID，一次都跑不通。
REQUIRED_KEYS = (
    "manifest_version", "seed", "source_snapshot", "source_mount",
    "pool_order", "cursor", "files", "staged_export_log",
    "source_verification", "source_verification_evidence",
)

# `stopped_reason` 的闭合枚举（R87-F1 + R89 自查补 + O4-F3 补第四值）。
STOPPED_REASONS = frozenset({
    "max_bytes",
    "source_path_escape",
    "staging_path_escape",
    "staging_recheck_failed",
})

# `fetch_fatal_error.kind` 记录的是**首次逃逸的类型**，与 `stopped_reason` **解耦**
# （O4-F3）：复校失败那一档正是「保留 fatal + 换 stopped_reason」，
# 写成「kind 恒等于 stopped_reason」会让它**结构上不可表达**。
FATAL_KINDS = frozenset({"source_path_escape", "staging_path_escape"})

# 这三个 `stopped_reason` 必须同时带形状合规的顶层 `fetch_fatal_error`。
REASONS_REQUIRING_FATAL = frozenset({
    "source_path_escape", "staging_path_escape", "staging_recheck_failed",
})

VERIFICATION_LEVELS = ("snapshot", "full", "partial")

# 生命周期三字段的名字表。「只有收尾提交能动它们，per-stock 提交在写入路径上
# 够不到」是**写入路径**的纪律（R95-F2 + spec §9-3s「使规则可机械检验」），
# 落在 S2b；本片没有写入路径，这里只是形状校验用的一张名字表。
LIFECYCLE_KEYS = frozenset({
    "stopped_reason", "stopped_reason_secondary", "fetch_fatal_error",
})

# `\Z` 不是 `$`：不加 re.MULTILINE 时 `$` 仍会容忍**恰好一个尾随换行**
# （匹配到换行之前的位置，不要求那是字符串真正的末尾），`\Z` 才是绝对末尾。
# 三个都改，按判据本身穷尽（2026-08-26 整支评审实测：`$` 下 gmt_token / sha256
# 带一个尾随 "\n" 都会被放行）。
_SHA256_RE = re.compile(r"^[0-9a-f]{64}\Z")
_STOCK_CODE_RE = re.compile(r"^\d+\.(SH|SZ|BJ)\Z")
_GMT_TOKEN_RE = re.compile(r"^@GMT-\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}\Z")

# `fetch_fatal_error.errno` 的闭合枚举：仅两种能触发「留在挂载点内」的逃逸
# 判据的系统调用错误码（R94-F2）。
FATAL_ERRNOS = frozenset({"ELOOP", "ENOTDIR"})

# `fetch_fatal_error` 的必需字段外延——**四字段**，不是三字段（R94-F2）：
# 写侧曾只写三字段、读侧要四字段，会让一个合规的写者产出的 manifest
# 被读者判非法。
FATAL_FIELDS = ("kind", "relative_path", "component", "errno")

# manifest 是**不可信输入**（它决定整棵 staging 可不可信），故读入有上限。
# **本片新增，非 spec 条款**——与 S1 给归属标记设 `_MARKER_MAX_BYTES` 同一条判据：
# 读到 EOF 为止意味着一个被植入的几 GB 文件能把进程 OOM 掉，而不是得到一个干净的
# `ManifestInvalidError`。64 MiB 宽松到不可能误伤：5608 只股的完整 universe +
# 800 条 files 实测量级约 0.5 MB。
_MANIFEST_MAX_BYTES = 64 * 1024 * 1024


class ManifestInvalidError(Exception):
    """manifest 形状/自洽性不过 → `FAIL_MANIFEST_INVALID`。

    **与 `ManifestVersionError` 是两族**：本族说「这份账本坏了」，那族说
    「这份账本是别的版本写的」。混成一句话会让操作者面对一棵已拉几百只股的
    staging 无路可走（O2-F8）。

    ⚠️ **动作指引由本类统一追加，调用点只说「哪里不对」**：全局约束要求每条拒绝
    都说清「哪里不对」**与**「该怎么办」，而本模块有 90 个拒绝点、其中绝大多数的
    「该怎么办」是**同一个答案**。逐点重复同一句话既冗余、又必然漏（本片已被评审
    提了三次）。把它提到类里，约束就从散文变成**结构上不可违反**的东西。
    """

    #: 所有「账本坏了」类拒绝共用的动作指引。
    GUIDANCE = (
        "该怎么办：这份账本（fetch_manifest.json）已不可信，本工具不会尝试修复它"
        "——半份账本比没有账本更危险。请换一个新的 staging 目录 + 新 seed 重新拉取。"
    )

    def __init__(self, detail: str):
        self.detail = detail
        super().__init__(detail)          # args 保持原文，序列化往返才不会重复追加

    def __str__(self) -> str:
        return f"{self.detail}\n{self.GUIDANCE}"


class ManifestVersionError(Exception):
    """manifest 版本与本工具不等——**不是**形状非法。

    三档（O2-F8 + O4-F10）：低于 / 高于 / 缺失（视为 0，走「低于」）。
    每档给出**不同的、操作者照做得了的**指引。
    """

    def __init__(self, *, kind: str, found: int, expected: int):
        if kind not in ("older", "newer"):
            raise ValueError(f"kind 只能是 older/newer，收到 {kind!r}")
        self.kind = kind
        self.found = found
        self.expected = expected
        self.guidance = (
            f"该 staging 由旧版本（manifest_version={found}）产出，"
            f"本工具是 {expected} 版。请换新 staging + 新 seed 重拉。"
            if kind == "older" else
            f"该 staging 由更新版本（manifest_version={found}）产出，"
            f"本工具只到 {expected} 版。请用对应版本的工具，或换新 staging。"
        )
        super().__init__(self.guidance)


def check_version(payload: object) -> int:
    """**读侧的第一道**：先定版本，再谈形状。

    返回本工具认可的版本号；不认可即抛 `ManifestVersionError`（三档）。
    根本不是对象、或版本号不是整数 → `ManifestInvalidError`。

    ⚠️ **次序是判据的一部分**：一份版本更高的 manifest，其形状按**本版**要求
    去量必然缺东西。先跑形状校验的实现会把「你的工具太旧」报成「账本畸形」，
    **指引整个走错**（O4-F10 栽过的那档）。

    ⚠️ `bool` 是 `int` 的子类：不排除它，`{"manifest_version": True}` 会被
    当成版本 1 放行。
    """
    if not isinstance(payload, dict):
        raise ManifestInvalidError(
            f"manifest 必须是一个 JSON 对象，实际读到 {type(payload).__name__}。"
            "这通常意味着文件被截断或根本不是 manifest。"
        )
    if "manifest_version" not in payload:
        # 缺失视为 0（O4-F10），走「低于」档的指引。
        raise ManifestVersionError(kind="older", found=0, expected=MANIFEST_VERSION)
    raw = payload["manifest_version"]
    if isinstance(raw, bool) or not isinstance(raw, int):
        raise ManifestInvalidError(
            f"manifest_version 必须是整数，读到 {raw!r}（{type(raw).__name__}）。"
            "这通常意味着 manifest 被手工编辑过或写坏了。"
        )
    if raw < MANIFEST_VERSION:
        raise ManifestVersionError(kind="older", found=raw, expected=MANIFEST_VERSION)
    if raw > MANIFEST_VERSION:
        raise ManifestVersionError(kind="newer", found=raw, expected=MANIFEST_VERSION)
    return raw


def manifest_members(manifest: dict) -> list[tuple[str, str]]:
    """聚合指纹的**成员集合**（O2-F12 写死）：`files` 的每一条 + `staged_export_log`
    一条，各取 `(relative_path, sha256)`。

    ⚠️ **`staged_export_log` 那一条不能漏**：它是所有股共用的元数据基准
    （`build_stock_import` 门 2 拿它的 rows 与首尾时间戳卡每只股）。spec 原文
    「写侧含 export_log、读侧要求由 `files` 逐条重算」而 `files` 里没有它——
    **差这一项就让每一份诚实产出的 manifest 都被判 `FAIL_MANIFEST_INVALID`**
    （O4-F13 与 R94-F2 同类）。成员数因此恒为奇数 `2N+1`。
    """
    members = [(f["relative_path"], f["sha256"]) for f in manifest["files"]]
    sel = manifest["staged_export_log"]
    members.append((sel["relative_path"], sel["sha256"]))
    return members


def aggregate_sha256(members: Iterable[tuple[str, str]]) -> str:
    """对「全部已校验文件的 `(相对路径, 文件 sha256)` 排序列表」取 sha256。

    **序列化方式逐字写死（S2-F4）——两个工具必须算出同一个数，故拼法不许各写各的**：
    按相对路径升序 → `json.dumps(..., ensure_ascii=False, separators=(",", ":"))`
    → UTF-8 → sha256。

    ⚠️ `ensure_ascii=False` 与 `separators` **都是判据的一部分**：周期目录名是
    中文，两个取值会产出完全不同的字节。spec 原文只说「排序列表取 sha256」，
    **没定义这个列表怎么拼成字节**——而写这个数的是 `qmt_fetch`（4b）、拿它比对的
    是 `qmt_pilot`（4c），两个切片、两份 plan、不同时间实施。

    **本函数是唯一实现，4c 直接调用，不得各自重写。**
    """
    pairs = sorted(members)
    blob = json.dumps([[r, s] for r, s in pairs],
                      ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def _require(cond: bool, detail: str) -> None:
    """判据不满足即 fail-closed。**绝不「尽力而为地解析」**。"""
    if not cond:
        raise ManifestInvalidError(detail)


def _require_nonempty_str(value: object, where: str) -> None:
    _require(isinstance(value, str) and value != "",
             f"{where} 必须是非空文字，读到 {value!r}")


def _require_sha256(value: object, where: str) -> None:
    """sha256 必须是 **64 位小写十六进制**。大写不放行——同一份字节两种写法
    会让「逐字相符」这条判据静默失效。"""
    _require(isinstance(value, str) and _SHA256_RE.match(value) is not None,
             f"{where} 必须是 64 位小写十六进制的 sha256，读到 {value!r}")


def _require_market_map(value: object, where: str, kind: str) -> dict:
    """三层字典：键恰为 SH/SZ/BJ，不多不少。"""
    _require(isinstance(value, dict), f"{where} 必须是对象，读到 {type(value).__name__}")
    _require(set(value.keys()) == set(MARKETS),
             f"{where} 的键必须恰为 {list(MARKETS)}，读到 {sorted(value.keys())}")
    for mk in MARKETS:
        if kind == "list":
            _require(isinstance(value[mk], list), f"{where}[{mk}] 必须是列表")
        elif kind == "int":
            _require(isinstance(value[mk], int) and not isinstance(value[mk], bool),
                     f"{where}[{mk}] 必须是整数，读到 {value[mk]!r}")
    return value


def _validate_source_snapshot(snap: object) -> None:
    _require(isinstance(snap, dict), "source_snapshot 必须是对象")
    _require("export_log_sha256" in snap, "source_snapshot 缺 export_log_sha256")
    _require_sha256(snap["export_log_sha256"], "source_snapshot.export_log_sha256")
    _require("universe" in snap,
             "source_snapshot 缺 universe —— 冻结的候选名单是补拉游标的唯一锚点，"
             "缺了它整棵 staging 无法续跑")
    uni = _require_market_map(snap["universe"], "source_snapshot.universe", "list")
    for mk in MARKETS:
        for i, code in enumerate(uni[mk]):
            _require(isinstance(code, str) and _STOCK_CODE_RE.match(code) is not None,
                     f"source_snapshot.universe[{mk}][{i}] 不是合法股票代码：{code!r}")
            _require(code.endswith("." + mk),
                     f"source_snapshot.universe[{mk}][{i}] = {code!r} 的后缀与所在层不符")


def _validate_source_mount(mount: object) -> None:
    """`source_mount` 的形状（S2-F2 更正）。

    ⚠️ **`source_root_relative` 允许空串**：§4.6 (ii-a) 用实测论证了
    「共享本身就是导出根」时它就是空串。读侧原文的「三子键均为非空 str」
    会让那种**完全合法的部署**先过 (ii-a) 的拼接、再被读侧判死，
    并把操作者指向一个不存在的问题。

    `mountpoint` / `source_root` 是 fetch 那次的**绝对形态，仅供留痕、
    不参与判定**（R25-F2：把偶然的挂载点形态写进身份判据，会让同一共享重挂到
    `/Volumes/QMT_Export-1` 时否决掉一次完全合法的出货）——故本函数不校验它们，
    但也不拒绝它们的存在。
    """
    _require(isinstance(mount, dict), "source_mount 必须是对象")
    for key in ("fstype", "device", "source_root_relative"):
        _require(key in mount, f"source_mount 缺 {key}")
    _require_nonempty_str(mount["fstype"], "source_mount.fstype")
    _require_nonempty_str(mount["device"], "source_mount.device")
    _require(isinstance(mount["source_root_relative"], str),
             "source_mount.source_root_relative 必须是文字"
             f"（允许空串——共享本身即导出根时就是空的），读到 "
             f"{mount['source_root_relative']!r}")


def _validate_pool_order(pool: object, universe: dict) -> None:
    """`pool_order` 是 **pilot 的唯一消费顺序来源**（P4-D8），故它的每一条都要
    带锚点、锚点要交叉核对、层内两个字段各自唯一。

    ⚠️ **裸字符串元素必须被拒**（R13-F1）：R12-F1 把元素改成 `{code, universe_idx}`
    正是因为拷贝失败是跳过继续、而重试发生在下一批开头——U5 第一批失败、
    U6–U121 成功后顺次追加，第二批重试 U5 成功就被追加到**列表末尾**。
    pilot 按追加顺序消费的话，**最终选中哪 100 只取决于当时 SMB 有没有抖一下**。
    「兼容」裸字符串等于丢掉锚点，把那个口子重开。
    """
    _require_market_map(pool, "pool_order", "list")
    for mk in MARKETS:
        seen_codes: set[str] = set()
        seen_idx: set[int] = set()
        for i, item in enumerate(pool[mk]):
            where = f"pool_order[{mk}][{i}]"
            _require(isinstance(item, dict),
                     f"{where} 必须是对象 {{code, universe_idx}}，读到 "
                     f"{type(item).__name__}——裸字符串是旧版格式，"
                     "缺锚点会让消费顺序取决于网络抖动，一律拒绝")
            _require("code" in item and "universe_idx" in item,
                     f"{where} 必须同时有 code 与 universe_idx，读到 {sorted(item)}")
            code = item["code"]
            _require(isinstance(code, str) and _STOCK_CODE_RE.match(code) is not None,
                     f"{where}.code 不是合法股票代码：{code!r}")
            _require(code.endswith("." + mk),
                     f"{where}.code = {code!r} 的后缀与所在层 {mk} 不符")
            idx = item["universe_idx"]
            _require(isinstance(idx, int) and not isinstance(idx, bool),
                     f"{where}.universe_idx 必须是整数，读到 {idx!r}")
            _require(code not in seen_codes, f"{where}.code = {code!r} 在本层重复出现")
            _require(idx not in seen_idx, f"{where}.universe_idx = {idx} 在本层重复出现")
            layer = universe[mk]
            _require(0 <= idx < len(layer),
                     f"{where}.universe_idx = {idx} 越界"
                     f"（本层冻结名单长度 {len(layer)}）")
            _require(layer[idx] == code,
                     f"{where} 的锚点对不上：universe[{mk}][{idx}] 是 "
                     f"{layer[idx]!r}，而这条记录自称是 {code!r}。"
                     "这份 manifest 被编辑过或来自另一次 fetch。")
            seen_codes.add(code)
            seen_idx.add(idx)


def _validate_cursor(cursor: object, universe: dict) -> None:
    """`cursor[market]` = **已尝试到**冻结名单的下标（R3-F2），与 `pool_order`
    这个**成功列表**语义不同、不可互相替代。

    ⚠️ **上界是闭区间**：取遍全层时 `cursor == len(universe[market])`，
    那是「池穷尽」这个合法终态。写成开区间会让一次正常跑到池尽的 staging
    在下次启动时被判「账本非法」。
    """
    _require_market_map(cursor, "cursor", "int")
    for mk in MARKETS:
        n = len(universe[mk])
        _require(0 <= cursor[mk] <= n,
                 f"cursor[{mk}] = {cursor[mk]} 越界（本层冻结名单长度 {n}，"
                 f"合法范围 0..{n}，取到 {n} 表示该层已取遍）")


def _require_relative_inside(relpath: object, where: str) -> list[str]:
    """路径必须**留在 staging 之内**。

    ⚠️ 用的是 S1 的**分量规则**，不是 spec 字面写的 `resolve()`：`resolve()`
    **会跟随符号链接**（那正是 O2-F4 造 `parent_fd_under` 的全部理由），拿它当
    边界判据等于把判据建在会被绕过的调用上。分量规则更强，且**不碰文件系统**
    ——读侧校验因此得以是纯函数。真正的符号链接防线在打开那一刻由
    `open_under` 逐段 `O_NOFOLLOW` 承担。
    """
    _require(isinstance(relpath, str), f"{where} 必须是文字，读到 {relpath!r}")
    try:
        return split_relative_components(relpath)
    except PathDisciplineError as e:
        raise ManifestInvalidError(f"{where} 不是一条留在 staging 内的相对路径：{e}") from e


def _validate_files(files: object, pool: dict) -> None:
    """实拷清单逐项合规（R21-F3）。

    ⚠️ **这份清单是 `staging_intact` / `pilot_stock_source` / 三方源校验共同的
    真相基准**，而读侧校验此前唯独漏了它。一份被编辑过或半截写入的 manifest
    可以形状全过，却给某只股缺一条、重一条、或**把 1m 的哈希绑到 daily 上**
    ——于是「校验的字节与导入器实际消费的字节根本不是同一批」。
    """
    _require(isinstance(files, list), "files 必须是列表")

    pooled: set[str] = {item["code"] for mk in MARKETS for item in pool[mk]}
    by_stock: dict[str, list[str]] = {}

    for i, rec in enumerate(files):
        where = f"files[{i}]"
        _require(isinstance(rec, dict), f"{where} 必须是对象")
        for key in ("stock_code", "period", "relative_path", "bytes", "sha256"):
            _require(key in rec, f"{where} 缺 {key}")

        code = rec["stock_code"]
        _require(isinstance(code, str) and _STOCK_CODE_RE.match(code) is not None,
                 f"{where}.stock_code 不是合法股票代码：{code!r}")
        _require(rec["period"] in PERIODS,
                 f"{where}.period 必须是 {list(PERIODS)} 之一，读到 {rec['period']!r}")

        parts = _require_relative_inside(rec["relative_path"], f"{where}.relative_path")
        try:
            f_code, _f_name, f_period = parse_qmt_filename(parts[-1])
        except QmtSchemaError as e:
            raise ManifestInvalidError(
                f"{where}.relative_path 的文件名不符合 QMT 导出规则：{e}") from e
        _require(f_code == code,
                 f"{where} 自称是 {code!r}，而文件名解析出的是 {f_code!r}")
        _require(f_period == rec["period"],
                 f"{where} 自称周期是 {rec['period']!r}，而文件名解析出的是 "
                 f"{f_period!r}——把 1m 的哈希绑到 daily 上，校验的字节与导入器"
                 "消费的字节就不是同一批了")

        _require(isinstance(rec["bytes"], int) and not isinstance(rec["bytes"], bool)
                 and rec["bytes"] >= 0,
                 f"{where}.bytes 必须是非负整数，读到 {rec['bytes']!r}")
        _require_sha256(rec["sha256"], f"{where}.sha256")

        _require(code in pooled,
                 f"{where} 记的 {code!r} 不属于 pool_order 里的任何一只股——"
                 "多余的活跃记录会让完整性闸拿着一个没人认领的基准去比对")
        by_stock.setdefault(code, []).append(rec["period"])

    for code in sorted(pooled):
        got = sorted(by_stock.get(code, []))
        _require(got == sorted(PERIODS),
                 f"{code} 在 files 里的记录是 {got}，必须恰好是 "
                 f"{sorted(PERIODS)} 各一条——一只股的两个文件是一次事务，"
                 "缺一条意味着上一次运行崩在两次 os.replace 之间")


def _validate_staged_export_log(sel: object, export_log_sha256: str) -> None:
    """staged `export_log.csv` 与 K 线 CSV 受**同等纪律**（R38-F1）。

    ⚠️ **它是所有股共用的元数据基准**：`build_stock_import` 的门 2 拿它的
    `rows` 与首尾时间戳去卡每一只股。此前全套完整性闸只钉了 K 线 CSV，
    唯独漏了它——**一份手改的 staged log 能让本该被拒的股过门**，而权威源里
    那一份根本不认。

    `sha256` 必须**等于** `source_snapshot.export_log_sha256`：同一份字节在
    manifest 里被记了两次，不等即自相矛盾。
    """
    _require(isinstance(sel, dict), "staged_export_log 必须是对象")
    for key in ("relative_path", "bytes", "sha256"):
        _require(key in sel, f"staged_export_log 缺 {key}")
    _require_relative_inside(sel["relative_path"], "staged_export_log.relative_path")
    _require(isinstance(sel["bytes"], int) and not isinstance(sel["bytes"], bool)
             and sel["bytes"] >= 0,
             f"staged_export_log.bytes 必须是非负整数，读到 {sel['bytes']!r}")
    _require_sha256(sel["sha256"], "staged_export_log.sha256")
    _require(sel["sha256"] == export_log_sha256,
             "staged_export_log.sha256 与 source_snapshot.export_log_sha256 不等"
             "——同一份字节的两处记录对不上，这份 manifest 自相矛盾")


def _require_escape_pairing(reason: object, fatal: object) -> None:
    """`stopped_reason` 与 `fetch_fatal_error` 的**取值级**配对（形状另有判据）。

    ⚠️ **读侧此前只查了单向**（「reason 要求 fatal ⇒ fatal 在」），于是接受了一批
    **写侧根本产不出**的组合（codex R2 [high] + 控制者按判据穷尽挖出的同族两条）。
    最危险的一条：`stopped_reason="staging_path_escape"` 配
    `fetch_fatal_error.kind="source_path_escape"` —— 决策表只看 `kind`，
    于是这份账本绕过 P2-F3 **无条件要求**的 staging 全量复校直接清掉 fatal，
    **一棵被证明动过的树拿到干净标签**。改一个字段的 6 个字符即可，
    而「有人动过 staging」正是本模块的威胁模型。

    **写侧带 fatal 时只可能产出三种 reason**：分支①写 escape 值（此时 reason
    恒等于 kind）、复校失败那支写 `staging_recheck_failed`、其余分支原样保留
    上一次的。故下面两条判据在方向②（合法状态会不会被判死）上不误杀。

    **`staging_recheck_failed` 是 spec 明写的唯一一种解耦状态**（O4-F3）：
    「保留 fatal + 换 stopped_reason」在「kind 恒等于 reason」下结构上不可表达。
    """
    if fatal is None:
        return
    _require(reason in REASONS_REQUIRING_FATAL,
             f"有 fetch_fatal_error 时 stopped_reason 只能是 "
             f"{sorted(REASONS_REQUIRING_FATAL)} 之一，读到 {reason!r}"
             "——写侧任何一支都产不出这种组合")
    if reason in FATAL_KINDS:
        kind = fatal.get("kind") if isinstance(fatal, dict) else None
        _require(kind == reason,
                 f"stopped_reason = {reason!r} 与 fetch_fatal_error.kind = "
                 f"{kind!r} 不一致。escape 类的 stopped_reason 必须与 kind 相等"
                 "（唯一允许解耦的是 staging_recheck_failed，O4-F3）"
                 "——否则一份被改过 kind 的账本能绕过 staging 全量复校清掉 fatal")


def _validate_lifecycle(payload: dict) -> None:
    """`stopped_reason` / `fetch_fatal_error` / `stopped_reason_secondary` 的形状与配对。

    ⚠️ **一个信号只有同时进了「写侧规定」与「读侧校验」，它才真的存在**（R93-F1）：
    一次被源树逃逸终止的 fetch，其 manifest 仍带着此前成功拉到的 `pool_order` 与
    `files`，**形状上完全合法**——读侧不查这两个字段的实现会照常消费那批股，
    把一次信任边界破坏报成「候选不够」甚至走到 `SUCCESS`。

    ⚠️ **`kind` 与 `stopped_reason` 解耦**（O4-F3）：`kind` 记**首次逃逸的类型**，
    `stopped_reason` 记**本次为什么停**。复校失败那一档正是「保留 fatal +
    换 `stopped_reason`」——写成「`kind` 恒等于 `stopped_reason`」会让它
    **结构上不可表达**，实施者无路可走。

    ⚠️ 消费侧的 fail-closed 判据是「`fetch_fatal_error` 存在」，**不是**
    「`stopped_reason` 取值」（O4-F1）：前者是**粘性的信任状态**，后者是
    **易失的本次事件**，拿后者当安全判据必然被后续运行的 `max_bytes` 洗掉。
    本函数只管形状；分支由消费方（4c §4.2 步骤 ②）负责。
    """
    reason = payload.get("stopped_reason")
    fatal = payload.get("fetch_fatal_error")

    # ⚠️ 判「是否要校验枚举」用**键是否存在**，不是「取到的值是否为 None」：
    # 显式写 `"stopped_reason": null` 与**根本没有这个键**是两回事——前者
    # 是「写了却写坏了」，必须拒；`.get() is not None` 会把两者混成一档，
    # 让显式 null 冒充成「可选字段没填」而放行（2026-08-25 TDD 红灯实测抓到）。
    if "stopped_reason" in payload:
        _require(isinstance(reason, str) and reason in STOPPED_REASONS,
                 f"stopped_reason 必须是 {sorted(STOPPED_REASONS)} 之一，"
                 f"读到 {reason!r}")

    # 同理：`fetch_fatal_error: null`（键存在、值为 null）与键根本不存在是两回事，
    # 判据同样用键是否存在，不用 `.get() is not None`（协调者实测抓到：显式
    # null 且没有 stopped_reason 时，`.get() is not None` 会让两条判据都够不着
    # 而放行——「配对判据」与「形状判据」各自都因为看到的是 None 而误判成
    # 「这个字段不存在」）。
    if "fetch_fatal_error" in payload:
        _require(reason is not None,
                 "有 fetch_fatal_error 却没有 stopped_reason——写侧只落了一半")
        _require(isinstance(fatal, dict), "fetch_fatal_error 必须是对象")
        for key in FATAL_FIELDS:
            _require(key in fatal,
                     f"fetch_fatal_error 缺 {key}（必须是 {list(FATAL_FIELDS)} "
                     "四字段——写侧三字段、读侧四字段会让一个合规的写者产出的 "
                     "manifest 被读者判非法，恢复指引整个走错）")
        # ⚠️ 必须**先验类型再比取值**（同第 466 行 stopped_reason 的写法）：
        # `FATAL_KINDS` 是 frozenset，拿一个 list/dict 去做 `in` 会抛
        # `TypeError: unhashable type`——一份被编辑坏的 manifest 于是不是被
        # fail-closed 拒绝，而是让进程带着原始 traceback 崩掉，恢复指引一个字
        # 都印不出来。**守卫自己被它该抓的那种损坏弄坏了。**
        _require(isinstance(fatal["kind"], str) and fatal["kind"] in FATAL_KINDS,
                 f"fetch_fatal_error.kind 必须是 {sorted(FATAL_KINDS)} 之一，"
                 f"读到 {fatal['kind']!r}")
        _require_nonempty_str(fatal["relative_path"], "fetch_fatal_error.relative_path")
        _require_nonempty_str(fatal["component"], "fetch_fatal_error.component")
        _require(isinstance(fatal["errno"], str) and fatal["errno"] in FATAL_ERRNOS,
                 f"fetch_fatal_error.errno 必须是 {sorted(FATAL_ERRNOS)} 之一，"
                 f"读到 {fatal['errno']!r}")

    if reason in REASONS_REQUIRING_FATAL:
        _require(fatal is not None,
                 f"stopped_reason = {reason!r} 必须同时带形状合规的 "
                 "fetch_fatal_error——它才是那个粘性的信任状态，"
                 "stopped_reason 会被后续运行的 max_bytes 洗掉")

    _require_escape_pairing(reason, fatal)

    # 同理：显式 null 与键缺失是两回事，判据用键是否存在。
    secondary = payload.get("stopped_reason_secondary")
    if "stopped_reason_secondary" in payload:
        _require(secondary == "max_bytes",
                 "stopped_reason_secondary 只允许 'max_bytes'（纯人读附注："
                 "Run1 撞 escape、Run2 触顶时，escape 的 stopped_reason "
                 f"不得被覆盖），读到 {secondary!r}")
        # 它只在「上次有 fatal + 本次容量触顶」那一支产生（O4-F1），
        # 没有 fatal 时是无源之水——同样是写侧产不出的组合。
        _require(fatal is not None,
                 "有 stopped_reason_secondary 却没有 fetch_fatal_error："
                 "这个附注只在「上次留着 fatal、本次又撞容量上限」时产生")


def _validate_verification_inputs(payload: dict) -> str:
    """`source_verification` 的级别，以及该级别要求的**前置输入**（R15-F2）。

    ⚠️ **写侧记录与读侧核实是两件事**：R10-F3 加了 `--snapshot-gmt-token` 与
    `--confirm-no-export-window` 让证据有处可记，**却从没要求读侧去核实它们
    真的在**。于是版本错位、半截写入或手工编辑的 manifest 里，一个
    **光秃秃的 `source_verification: "full"` 字符串**就足以让 pilot 判出
    `ship_eligible: true`，而声称属于该级别必要条件的那份证据整个缺席。

    ⚠️ **本校验不授予任何出货资格**（R17-F2 / R18-F2）——它只是一致性检查。
    `ship_eligible ≡ (final_verdict == "SUCCESS")` 是派生量（R26-F1）。
    """
    level = payload["source_verification"]
    _require(isinstance(level, str) and level in VERIFICATION_LEVELS,
             f"source_verification 必须是 {list(VERIFICATION_LEVELS)} 之一，"
             f"读到 {level!r}")

    if level == "snapshot":
        token = payload["source_snapshot"].get("gmt_token")
        _require(isinstance(token, str) and _GMT_TOKEN_RE.match(token) is not None,
                 "source_verification = 'snapshot' 要求 source_snapshot.gmt_token "
                 f"形如 @GMT-YYYY.MM.DD-HH.MM.SS，读到 {token!r}")
    elif level == "full":
        att = payload.get("operator_attestation")
        _require(isinstance(att, dict),
                 "source_verification = 'full' 要求 operator_attestation —— "
                 "缺了它，一个光秃秃的 'full' 字符串就成了出货级标签，"
                 "而那份人工声明从未发生过")
        _require(att.get("no_export_window") is True,
                 "operator_attestation.no_export_window 必须为 true")
        _require_nonempty_str(att.get("recorded_at"),
                              "operator_attestation.recorded_at")
    return level


_PASSES_REQUIRED = {"snapshot": 1, "full": 2}


def _validate_verification_evidence(payload: dict, level: str) -> None:
    """校验过程存根（R16-F1）——证明校验**真的跑过**。

    ⚠️ **存根本身是自指的，不足以支撑出货资格**（R17-F2）：本函数拿
    `aggregate_sha256` 与「manifest **自己记录的**逐文件 sha256」比对，
    因此它证明的只是**这份 manifest 内部自洽**，**不证明校验进程真的读过
    SMB 源**——手工编辑者完全可以自填哈希、自算聚合、自称 `full`。
    故这套校验是**一致性检查**：能挡住截断、版本错位、字段缺失，
    **不再单独授予任何出货资格**。

    ⚠️ **`partial` 级永远可读**（O4-F2）：趟数 / `passes_agree` /
    `aggregate_sha256` / `files_verified` 的一致性校验**只适用于
    `snapshot` / `full` 两级**。首次 fetch 跑到第 200 只股被 SIGKILL 时，
    磁盘上那份 manifest 有几百条 `files`、没有存根（存根只能由**批后**的
    收尾复校产出）；对 `partial` 也强制一致性会让读侧 fail-closed 拒绝，
    而崩溃恢复明写在「读完并校验 manifest **之后**」——于是 `.inflight.json`
    回滚、幂等四象限、按股事务**一条都执行不到**。
    """
    ev = payload["source_verification_evidence"]
    _require(isinstance(ev, dict), "source_verification_evidence 必须是对象")
    _require("level" in ev and "passes" in ev,
             "source_verification_evidence 必须有 level 与 passes")
    _require(ev["level"] == level,
             f"source_verification_evidence.level = {ev['level']!r} 与 "
             f"source_verification = {level!r} 不一致")
    _require(isinstance(ev["passes"], list),
             "source_verification_evidence.passes 必须是列表")

    if level == "partial":
        # 形状仍要，一致性不要（O4-F2）。
        _require(ev["passes"] == [],
                 "partial 级的存根必须是 passes: [] —— per-stock 提交时这两个"
                 "字段的取值是写死的，带着趟数说明写侧没按写死的取值来")
        return

    want = _PASSES_REQUIRED[level]
    _require(len(ev["passes"]) == want,
             f"{level} 级要求恰好 {want} 趟复校，读到 {len(ev['passes'])} 趟")

    expect_n = len(payload["files"]) + 1          # O4-F13：2N+1，含 staged_export_log
    expect_agg = aggregate_sha256(manifest_members(payload))
    aggs: list[str] = []
    for i, p in enumerate(ev["passes"]):
        where = f"source_verification_evidence.passes[{i}]"
        _require(isinstance(p, dict), f"{where} 必须是对象")
        for key in ("pass", "files_verified", "aggregate_sha256", "completed_at"):
            _require(key in p, f"{where} 缺 {key}")
        _require(isinstance(p["pass"], int) and not isinstance(p["pass"], bool)
                 and p["pass"] == i + 1,
                 f"{where}.pass = {p['pass']!r}，必须是整数 {i + 1}"
                 "——这个字段标记的是「这是第几趟」，取值必须与它在 passes 里的"
                 "顺序位置一一对应，否则一份趟号重复/错序/越界的存根就能冒充"
                 "一次真实发生过的连续复校")
        _require(p["files_verified"] == expect_n,
                 f"{where}.files_verified = {p['files_verified']}，"
                 f"必须等于 len(files) + 1 = {expect_n}"
                 "（成员集合含那一份 staged export_log，故恒为奇数 2N+1）")
        _require_sha256(p["aggregate_sha256"], f"{where}.aggregate_sha256")
        _require(p["aggregate_sha256"] == expect_agg,
                 f"{where}.aggregate_sha256 与「拿 manifest 自己记的逐文件 "
                 "sha256 重算出的聚合」不符——这份存根与它所在的 manifest 对不上")
        _require_nonempty_str(p["completed_at"], f"{where}.completed_at")
        aggs.append(p["aggregate_sha256"])

    if level == "snapshot":
        mc = ev.get("mount_check")
        _require(isinstance(mc, dict), "snapshot 级要求 mount_check")
        _require(mc.get("verified_against_mount") is True,
                 "snapshot 级要求 mount_check.verified_against_mount 为 true"
                 "——否则那个 token 只是一个形状对的字符串，没跟真实挂载核过")
    else:                                          # full
        _require(ev.get("passes_agree") is True,
                 "full 级要求 passes_agree 为 true")
        # ⚠️⚠️ **本条在当前实现下是恒真断言**（2026-08-25 控制者变异证实：删掉它全绿）：
        # 循环内已要求**每一趟**都 `== expect_agg`，两趟都过 ⇒ 两趟必然相等。
        # **保留而不删的理由**：①spec 明写 full 级「两趟聚合摘要相等」，删掉是偏离；
        # ②它是**防御性冗余**——若将来有人放宽了循环内那条（例如改成只查格式合法），
        # 这条还在守。**但它此刻挡不住任何循环内那条挡不住的东西，别指望它。**
        _require(aggs[0] == aggs[1],
                 "full 级的两趟聚合摘要不相等，而 passes_agree 写着 true"
                 "——存根自相矛盾")


def validate_manifest(payload: object) -> dict:
    """**读侧闭合校验**：`qmt_fetch` 与 `qmt_pilot` 读 manifest 时都必须过它，
    任一判据不满足即 fail-closed 拒绝整份 manifest。原样返回通过校验的 manifest。

    ⚠️ **必须在任何 DB 写入之前**（R21-F3）。

    ⚠️ **不做「尽力而为地解析」**：一个被截断的 manifest 解析出来往往仍是合法
    JSON 的**前缀片段**，静默消费它 = 把 manifest 损坏伪装成「候选就这么多」，
    最终产出一份**会撒谎的 pilot 报告**（R1-F4）。

    本函数的作用域**仅限于**把畸形/不自洽的 manifest 挡在门外。
    **它不授予、也不参与任何出货资格判定**（R17-F2 / R18-F2）——
    `ship_eligible ≡ (final_verdict == "SUCCESS")` 是派生量，与本函数无关。
    """
    check_version(payload)                 # ← 先版本、后形状（次序是判据的一部分）
    assert isinstance(payload, dict)       # check_version 已保证

    for key in REQUIRED_KEYS:
        _require(key in payload,
                 f"manifest 缺少必需字段 {key!r}。"
                 "这通常意味着文件被截断，或由不兼容的版本写出。")

    _require_nonempty_str(payload["seed"], "seed")
    _validate_source_snapshot(payload["source_snapshot"])
    _validate_source_mount(payload["source_mount"])
    _validate_pool_order(payload["pool_order"], payload["source_snapshot"]["universe"])
    _validate_cursor(payload["cursor"], payload["source_snapshot"]["universe"])
    _validate_files(payload["files"], payload["pool_order"])
    _validate_staged_export_log(payload["staged_export_log"],
                                 payload["source_snapshot"]["export_log_sha256"])
    _validate_lifecycle(payload)
    level = _validate_verification_inputs(payload)
    _validate_verification_evidence(payload, level)

    # ⚠️ **原样返回，绝不做白名单投影**（O4-F10）：读到不认识的顶层键必须原样
    # 保留回写。旧工具消费新版 manifest 后若把不认识的字段丢掉 → 再用新工具
    # 打开时缺必需字段 → **一棵 400 只股的 staging 被一次「用错版本跑补拉」
    # 永久毁掉**。S3/S4 的 failures / batches / inflight_rollbacks / quota
    # 正是靠这条通道流转，因此它们**不需要 bump manifest_version**。
    return payload


# ── 落盘层（S2b）────────────────────────────────────────────
# 以下三个函数是 manifest 与磁盘之间的**唯一**通道。上面的全部校验是纯函数，
# 这里才第一次碰文件系统，且全部走 S1 `qmt_fsroot` 的逐段无跟随原语。


def lifecycle_snapshot(manifest: dict) -> dict:
    """捕获生命周期三字段的当前值，供 per-stock 提交逐字回写。

    **这是 per-stock 提交够不到那三个字段的实现手段**（R95-F2 + spec §9-3s
    「使规则可机械检验」）：`commit_stock` 把 manifest 里的同名键一律剥掉，
    再把本快照塞回去——**调用方即使污染了内存里的 manifest，也写不进磁盘**。

    ⚠️ **必须深拷贝**（codex R1 [high]）：只拷顶层映射时 `fetch_fatal_error`
    仍是**同一个可变 dict**，取完快照再改它一样会被写进磁盘——不变量当场作废。
    本机端到端复现过整条洗白链：把 `kind` 由 `staging_path_escape` 改成
    `source_path_escape` 后仍能过读侧校验，而 source escape 的清除**只要前提①**
    （不需要 staging 全量复校）→ 下一次收尾提交就把它清掉了。
    """
    return {k: copy.deepcopy(manifest[k]) for k in LIFECYCLE_KEYS if k in manifest}


def read_manifest(stg_fd: int) -> dict | None:
    """相对 `stg_fd` **逐段无跟随**读回 manifest 并过全套读侧校验。

    返回校验通过的 manifest；**文件不存在返回 `None`**（引导态——崩在归属标记
    落盘与首份 manifest 之间，spec 明写它允许从头继续初始化，R60-F3）。
    把「不存在」与「坏了」混成一个异常，会让引导态这一档无法与畸形区分。

    抛：

    - `ManifestInvalidError` —— 不是普通文件（FIFO / 目录 / 设备 / socket）/ 空文件 /
      截断 / 不是 JSON 对象 / 超过大小上限 / 任一读侧判据不过；
    - `ManifestVersionError` —— 版本三档（**不在本层抹平成 Invalid**）；
    - `PathEscapeError` —— manifest 这一段被换成符号链接（`open_under` 逐段
      `O_NOFOLLOW` 撞 `ELOOP` / `ENOTDIR`）。**原样上浮，不降级成「manifest 畸形」**：
      那是一次**信任边界破坏**，处置是 `stopped_reason: staging_path_escape` +
      顶层 `fetch_fatal_error` + rc≠0（S4/S5 负责），报成「账本坏了」会让恢复指引
      整个走错。
    - `OSError`（及其子类）—— **环境错误**：账本是一个**普通文件**、却打不开
      （权限 `EACCES`、进程 fd 耗尽 `EMFILE` 等）。**如实上浮，绝不翻译成
      `ManifestInvalidError`**（Opus 第 4 轮 [low]，本机复现 `PermissionError`）：
      那一族的恢复指引是「换新 staging + 新 seed 重拉」，而这里正确的动作是
      `chmod` / 释放 fd —— 把它报成「这棵 staging 已被动过」会让操作者**报废一棵
      几百只股的健康目录**。⚠️ 探测器的兜底因此**必须**先问「它到底是不是普通
      文件」；去掉那一问，一次 `EACCES` 就会被当成「被动过手脚」（已配专属档）。
      **对 S4/S5 的硬性要求**：`except` 清单里要把它与上面三族分开处置。

    ⚠️ **必须经 `open_regular_probe`（带 `O_NONBLOCK`）而不是裸 `open_under`**：
    `open(O_RDONLY)` 打开 FIFO 会**一直阻塞等写入方**，于是一个被篡改的 staging
    让工具**永久挂起**而不是 fail-closed（本机实测：裸 open 时该档 15 秒被闹钟
    杀掉、日志 0 字节）。S1 的 `_open_regular_probe` 已为取锁 / 探测 / 读标记三处
    立了这条纪律，本函数是**第四个**打开点——「同一条纪律只落在其中一处」就是没立。

    ⚠️ **大小上限卡在读取过程中，不是只查 `st_size`**（与 S1 逐字同规格）：
    `st_size` 是打开那一刻的快照，文件完全可以**边读边长**，只查它会被绕过；
    而叠一道 `st_size` 早拒**无法被任何测试单独钉住**（读取本身每次上限 1 MiB、
    累计到上限即停，两条路的实际读取量同量级），一道钉不住的守卫是负债不是资产。
    """
    seen = _read_manifest_with_digest(stg_fd)
    return None if seen is None else seen[0]


# 「不是普通文件」这句结论有**两条路**通向它（`S_ISREG` 判否 / `open` 直接失败），
# 文案写死一处，免得两条路给出不同的指引。
_NOT_REGULAR_DETAIL = (
    f"{MANIFEST_NAME} 存在但不是普通文件——拒绝。"
    "这棵 staging 已被动过，请换新 staging + 新 seed 重拉。"
)


def _read_manifest_with_digest(stg_fd: int) -> tuple[dict, str] | None:
    """`read_manifest` 的实现，另外返回**磁盘上那批原始字节的 sha256**。

    指纹是「这份账本还是不是我上次看见/写下的那一份」的判据 —— 只比生命周期
    字段看不出「被换成另一份同样合法的干净账本」（codex R7 [high]）。
    """
    try:
        fd, st = open_regular_probe(stg_fd, MANIFEST_NAME, flags=os.O_RDONLY)
    except FileNotFoundError:
        return None
    except NotARegularFileError as e:
        # socket 等「存在但打不开成文件」的对象 —— `open` 就失败了，
        # **走不到**下面那句 `S_ISREG`（Opus 评审 [medium]，本机复现：
        # FIFO/目录拿到干净拒绝，socket 抛裸 OSError [Errno 102]）。
        # 两条路必须给**同一句**结论，否则枚举「FIFO/目录/设备/socket」只兑现一半。
        raise ManifestInvalidError(_NOT_REGULAR_DETAIL) from e
    try:
        if not stat.S_ISREG(st.st_mode):
            # FIFO / 目录 / 设备 / socket：**先探类型再读**。目录能被
            # O_RDONLY|O_NOFOLLOW 成功打开，随后 os.read 抛原始 IsADirectoryError；
            # FIFO 则让裸 open 永久阻塞。两者都会让这份自称 fail-closed 的校验
            # 在最该工作的时候印不出一个字的恢复指引。
            raise ManifestInvalidError(_NOT_REGULAR_DETAIL)
        chunks: list[bytes] = []
        total = 0
        while True:
            block = os.read(fd, 1 << 20)
            if not block:
                break
            total += len(block)
            if total > _MANIFEST_MAX_BYTES:
                raise ManifestInvalidError(
                    f"{MANIFEST_NAME} 过大（读取过程中已超过上限 "
                    f"{_MANIFEST_MAX_BYTES} 字节）——它决定整棵 staging 可不可信，"
                    "拒绝把一个来路不明的巨型文件读进内存"
                )
            chunks.append(block)
    finally:
        os.close(fd)

    data = b"".join(chunks)
    if not data:
        raise ManifestInvalidError(f"{MANIFEST_NAME} 是空文件")
    try:
        payload = json.loads(data.decode("utf-8"))
    # ⚠️ **不能只接 `JSONDecodeError`**（codex R9 [medium]）：语法完全合法的 JSON
    # 仍可能在**解析器层**抛别的异常 —— Python 3.11（CI 钉的版本）对超过 4300 位的
    # 整数在 `int()` 转换时抛**裸 `ValueError`**，深嵌套则抛 `RecursionError`。
    # 一份约 5 KB 的 manifest（远低于 64 MiB 上限）就能让读回口带着原始 traceback
    # 崩掉，恢复指引一个字都印不出来 —— 与 S2-F9 / S2-F10 同族：
    # **守卫自己被它该抓的那种损坏弄坏了**。
    # （`JSONDecodeError` 是 `ValueError` 的子类，故写 `ValueError` 即可覆盖两者。）
    except (UnicodeDecodeError, ValueError, RecursionError) as e:
        raise ManifestInvalidError(
            f"{MANIFEST_NAME} 不是合法 JSON：{e}。"
            "这通常意味着上一次写入被打断（文件被截断）。"
        ) from e
    return validate_manifest(payload), hashlib.sha256(data).hexdigest()


def _write_manifest(stg_fd: int, payload: dict) -> str:
    """manifest 的**唯一**落盘路径：tmp → `F_FULLFSYNC(文件)` → `os.replace` →
    `fsync(目录)`。

    文件内容走 **`F_FULLFSYNC`**（O4-F11 定案：断电在威胁模型之内，而本平台的
    `fsync(2)` man page 明写它既不保证断电耐久、也不保证跨设备写序）。

    ⚠️ **绝不就地截断重写**——「原子」（`os.replace` 不会看到半截）与「耐久」
    （崩溃后仍在）是两件事，两者都要（R45-F2）。

    ⚠️⚠️ **落盘前先过一遍读侧校验，且必须排在任何写入之前**（codex R2 [high]）：
    否则一次提交就能写出一份**自己读不回来**的账本——本机复现过
    `commit_stock(..., lifecycle={"stopped_reason": "source_path_escape"})`：
    它过了键白名单、写入**报告成功**，而下一次 `read_manifest` 判它非法
    → **整棵 staging 读不回来**，而干成这件事的那次调用返回的是成功。
    一次 per-stock 提交就能把已经拉了几百只股的 staging 变成砖头。

    这是「写侧形状与读侧要求必须逐字相同」那个家族（R94-F2 / O4-F13 /
    S2-F3 / S2-F4 / S2-F5）的第六次，只是这次跨的是**写入口与读入口**。
    修法不是「调用方小心点」，而是让坏状态**不可表达**：写不出去。
    校验排在 `atomic_write_json` **之前**是判据的一部分——排在之后的话，
    上一份好账本已经被 `os.replace` 换掉了，报不报错都救不回来。
    """
    validate_manifest(payload)          # ← 必须在任何写入之前
    # ⚠️ **大小也要在读侧的接受范围内**（codex R5 [medium]）：读侧有 64 MiB 硬上限，
    # 而未知顶层键按 O4-F10 是「原样保留且无上限」的通道 —— 一份结构完全合法、
    # 序列化后 6700 万字节的账本此前**写入报告成功**，下一次启动却以「过大」
    # 拒绝整棵 staging，已积累的数据全部不可用。这是 S2-F13 的另一半：
    # 我补了「结构合法」，漏了「大小也在读侧接受范围内」。
    #
    # ⚠️ **量的必须就是写的那批字节**：先 `encode_json` 拿到字节、量它、
    # 再把**同一批字节**交给 `atomic_write_bytes`。两处各自 dumps 一次会漂移
    # （`ensure_ascii` 一改，中文周期目录名长度差好几倍）。
    data = encode_json(payload)
    if len(data) > _MANIFEST_MAX_BYTES:
        raise ManifestInvalidError(
            f"{MANIFEST_NAME} 过大（序列化后 {len(data)} 字节，读侧上限 "
            f"{_MANIFEST_MAX_BYTES}）——写出去下一次就读不回来了，拒绝发布"
        )
    atomic_write_bytes(stg_fd, MANIFEST_NAME, data, full_sync=True)
    return hashlib.sha256(data).hexdigest()


# 一经写入就**不许再变**的字段（spec：`seed` 是复用准入条件；`source_snapshot`
# 是「冻结的完整分层 universe + export_log_sha256」；`source_mount` 记的是 fetch
# 那一次的挂载身份；`staged_export_log` 是那一份 export_log 的字节记录）。
# ⚠️ `source_verification` / `source_verification_evidence` **不在**此列 ——
# 它们由收尾复校重算，本来就该变。
_FROZEN_KEYS = ("manifest_version", "seed", "source_snapshot", "source_mount",
                "staged_export_log")


# ── 运行凭据：**不透明句柄 + 模块内注册表** ────────────────
#
# ⚠️ 安全事实（跳没跳过校验 / 见没见过账本 / 账本指纹）**不能存在调用方手里
# 那个对象上**。前两轮的教训：
# · R12：普通可变 dataclass → 一行赋值就改掉；
# · R13：`frozen=True` 挡住「改」，挡不住「**重造**」（构造函数是公开的）；
# · R14：加了构造期令牌，`dataclasses.replace` 仍把令牌**一起复制**过去，
#        `object.__setattr__` 也照样改得动冻结实例。
# ⇒ 终局做法：句柄只是**查表用的钥匙**，事实全部存在模块内部的注册表里。
#   句柄没有任何可写字段（`__slots__` 为空），也没有公开的构造路径。


def _hashable(value: object) -> object:
    """把任意 JSON 值变成**能当字典键 / 集合成员**的东西（总是成功，从不抛）。

    ⚠️⚠️ **为什么需要它**（Kimi 评审 [medium]，本机复现）：几条转移守卫拿
    JSON 里读来的值直接当键 —— `_attempts` 的字典键、`_by_id` 的元组键、
    `_progress_of` 的 frozenset 成员。而 `failures` 是**扩展字段，读侧
    `validate_manifest` 完全不碰它**（实测：`stock_code` 是 list 的账本读侧照样
    放行），且这些守卫都排在 `_write_manifest` 的读侧校验**之前** ——
    于是一份 `stock_code: ["600004.SH"]` 的 payload 让守卫**自己**抛
    `TypeError: unhashable type: 'list'`，调用方拿到的是 traceback 而不是
    `ManifestInvalidError` 的恢复指引。
    **「守卫自己被它该抓的那种损坏弄坏了」在本仓是第四次**（S2-F9 / S2-F27 同族）。

    ⚠️ **不是「跳过坏值」而是「换一个稳定的键」**：两个**相等**的不可哈希值
    仍映到同一个键（dict 按键名排序后归一），于是重名 / 单调那几条判据照常成立
    —— S2-F29 的教训是「对坏输入健壮」不许写成「对坏输入放行」。

    ⚠️ 正常取值**原样返回**（`_hashable("600000.SH") is "600000.SH"`），
    所以 `_proved_success` 那类「拿键回去比对原值」的逻辑一个字都不受影响；
    只有坏值会变成一个永远配不上原值的包装元组 —— 方向是 fail-closed。
    """
    try:
        hash(value)
    except TypeError:
        pass
    else:
        return value
    if isinstance(value, dict):
        # JSON 的键必然是字符串且互不相同 ⇒ 按键名排序后次序唯一，
        # 且 sorted 永远比不到第二个元素（不会拿不可比的值去比大小）。
        return ("<dict>", tuple(sorted(
            (str(k), _hashable(v)) for k, v in value.items())))
    if isinstance(value, (list, tuple)):
        return ("<list>", tuple(_hashable(v) for v in value))
    return ("<other>", repr(value))


def _progress_of(manifest: "dict | None") -> tuple:
    """一份 manifest 的**进度指纹**：实拷清单 / 各层池 / 游标 / 累计字节。

    spec P2-F3 要求「复校失败那一轮**不得推进 cursor、不得新增 files/pool_order**」
    —— 要检验它，就得留住**运行起点**的进度并在收尾时逐项比对。
    """
    m = manifest or {}
    files = frozenset(
        (_hashable(f.get("stock_code")), _hashable(f.get("period")),
         _hashable(f.get("relative_path")))
        for f in (m.get("files") if isinstance(m.get("files"), list) else [])
        if isinstance(f, dict))
    pool = m.get("pool_order") if isinstance(m.get("pool_order"), dict) else {}
    pools = tuple(
        frozenset((_hashable(e.get("code")), _hashable(e.get("universe_idx")))
                  for e in (pool.get(mk) if isinstance(pool.get(mk), list) else [])
                  if isinstance(e, dict))
        for mk in MARKETS)
    cur = m.get("cursor") if isinstance(m.get("cursor"), dict) else {}
    cursor = tuple(cur.get(mk) for mk in MARKETS)
    return (files, pools, cursor, m.get("committed_bytes"))


@dataclass
class _RunState:
    """注册表里那份真正的运行状态（**模块内部可见，调用方够不着**）。"""
    existed: bool
    digest: str | None
    lifecycle: dict
    skip_existing_verify: bool
    # 运行**起点**的进度指纹（不随提交推进），供 P2-F3 的「不得推进」判据比对。
    start_progress: tuple = ()
    # 起跑时账本上那份记录**是否必须先做 staging 全量复校才能解除**。
    # ⚠️ 与 `lifecycle` 分开存：后者每次提交都会被 `_advance` 推进，
    # 而这里要的是**运行起点**的事实。
    start_needs_recheck: bool = False
    # 本次运行登记的复校结论：`None`（还没做）/ `"passed"` / `"failed"`。
    recheck: "str | None" = None
    # 本轮**自己发布过** `fetch_fatal_error` 吗（整次 fetch 致命 ⇒ 之后不许再提交、
    # 也不许在同一轮里把它清掉）。
    fatal_published: bool = False


class RunLedger:
    """`begin_run()` 产出的**不透明凭据句柄**。

    它本身不携带任何可改的安全事实 —— 读取走只读属性，写入只有本模块的
    `_advance()` 做得到。绕过 `begin_run()` 造出来的句柄（哪怕类型完全正确）
    因为不在注册表里，任何一次读取都会当场拒绝。
    """
    __slots__ = ("__weakref__",)

    def __init__(self) -> None:
        raise ValueError(
            "RunLedger 只能由 begin_run() 产出 —— 它记的是安全事实，"
            "自己造一个等于把这些事实伪造掉。")

    def _state(self) -> _RunState:
        st = _LEDGER_STATE.get(self)
        if st is None:
            raise ValueError(
                "这个 RunLedger 不是 begin_run() 产出的（不在运行注册表里）")
        return st

    @property
    def existed(self) -> bool:
        return self._state().existed

    @property
    def digest(self) -> "str | None":
        return self._state().digest

    @property
    def lifecycle(self) -> dict:
        # ⚠️ **交出去的必须是副本**（独立评审 [high(c)]）：原本返回的是内部那个
        # dict **本身**，调用方 `ledger.lifecycle["fetch_fatal_error"] = {...}`
        # 一行就能改掉模块的内部状态、进而解除守卫的武装 —— 而本模块的立身之本
        # 正是「调用方口头上报的东西不能当凭据」。
        # ⚠️ 这与 R1 那条「`lifecycle_snapshot` 只拷了顶层」是**同一个教训的第二处**：
        # 凡是把安全事实交出去的读取口，都要问「交出去的是副本还是本体」。
        return copy.deepcopy(self._state().lifecycle)

    @property
    def skip_existing_verify(self) -> bool:
        return self._state().skip_existing_verify

    @property
    def owes_staging_recheck(self) -> bool:
        """起跑时账本上那份记录，是否**必须**先做一次 staging 全量复校才能解除。

        ⚠️ 不暴露时调用方只能自己重新推导 `_needs_staging_recheck` ——
        正是 `test_only_one_place_decides_whether_a_staging_recheck_is_required`
        立起来要禁止的「同一件事判在两处」（Opus 评审指出）。
        """
        return self._state().start_needs_recheck

    def _advance(self, digest: str, lifecycle: dict, payload: dict,
                 hit_escape: bool = False) -> None:
        """把预期推进到刚写出去的那一份（**只许本模块调用**）。

        ⚠️⚠️ **本轮自己发布的 fatal 必须重新武装复校闸与进度冻结**
        （Opus 第 4 轮 [medium]，本机复现两档）：两者原本只锚定**运行起点**，
        而 `commit_final` **不是每轮只能调一次**。
        · 场景 B：账本带旧逃逸 → 登记复校通过（针对**旧**那条路径）→ 收尾发布
          一条**新路径**的逃逸 → 同一轮再收尾一次，fatal 被清光 ——
          那份凭据**早于**它要清掉的那条逃逸。
        · 场景 C：干净起步 → 收尾发布 escape → `commit_stock` 照样推进
          files 4→6、cursor 1→2，而盘上带着未解除的逃逸（spec:1035 明禁）。

        ⚠️ **判据是「生命周期变了」而不是「现在需要复校」**：per-stock 提交把
        三个字段**原样带过去**，若只看后者，一次登记通过的运行提交第二只股时
        就会把自己的凭据清掉、从此卡死（已配正向档：整轮三次 per-stock 提交）。
        """
        # ⚠️⚠️ **两件事必须拆开**（Opus 第 5 轮两条 high —— **都是上一轮这个
        # 修复自己捅出来的**，判据当时绑在 `_needs_staging_recheck` 上）：
        #   ①「整次 fetch 致命」⇒ 冻结进度 + 本轮不许再清，对**任何** kind 成立
        #     （spec:1025 与 spec:1035 措辞一致）。绑在需不需要复校上时，对
        #     `source_path_escape` 整个不生效：实测发布它之后 `commit_stock` 照样把
        #     files 4→6、cursor SH 1→2、累计字节 733 万→980 万。
        #   ② `_needs_staging_recheck` 只回答「**清除它要哪一道前提**」。
        # ⚠️⚠️ **判据必须是「本轮撞没撞逃逸」，不是「记录变没变」**
        # （独立评审 [high]，控制者本机复现三档）。原来写成
        # `lifecycle != st.lifecycle and 有 fatal`，而决策表有**三种**方式产出
        # 一份与旧记录相等的生命周期，每一种都让武装整个不触发：
        #   (a) 分支①**保住更严的旧 fatal**（拒绝降级）—— 一个**发现源树被换过**
        #       的运行，最后交出一份完全没有 fatal 的账本；
        #   (b) 本轮**再次撞上磁盘上一模一样的那条逃逸**（没修好就重跑）——
        #       现实中最常见的一种；对照实验：换条路径武装就正常触发，
        #       ⇒ 说明判据问错了问题；
        #   (c) `ledger.lifecycle` 曾是活引用，调用方一行赋值即可让 `changed` 为假。
        # ⚠️ 反方向也错：分支③给**别人的** fatal 加一条 `max_bytes` 附注时，
        #   记录变了且带 fatal ⇒ 被误判成「本轮自己发布了 fatal」，把已登记的
        #   `passed` 清掉，还会印出一句假的「本次运行已经自己发布过…」。
        # ⇒ 只有 `commit_final` 拿着一个 `escape` 结局时，这一轮才真的撞了逃逸；
        #   `commit_stock` 永远产不出新 fatal（它把三个字段从磁盘原样带过去），
        #   故它传 `hit_escape=False`。
        st = self._state()
        st.existed = True
        st.digest = digest
        st.lifecycle = lifecycle
        if hit_escape:
            st.fatal_published = True
            st.start_progress = _progress_of(payload)
            if _needs_staging_recheck(lifecycle.get("stopped_reason"),
                                      lifecycle.get("fetch_fatal_error")):
                st.start_needs_recheck = True
            # ⚠️⚠️ **`failed` 是粘性的**：P2-F3 那个**明令要发布**的具名结局
            # （`staging_recheck_failed` + 保留 fatal）本身就满足
            # `_needs_staging_recheck` ⇒ 照旧重置会把本轮自己的「复校失败」凭据
            # 清掉，「结论不许改口」那道闸凭空消失。实测：随后 `attest(True)`
            # 被接受、再收尾一次 fatal 与 stopped_reason **全被删掉** ——
            # 一棵已被证明复校没通过的 staging 带着干净账本出货。
            if st.recheck != "failed":
                st.recheck = None


_LEDGER_STATE: "weakref.WeakKeyDictionary[RunLedger, _RunState]" = \
    weakref.WeakKeyDictionary()



def _expect_from_disk(stg_fd: int, ledger: RunLedger) -> tuple[dict, dict | None]:
    """读回磁盘上的生命周期，并与**启动快照**（预期）对表；不一致一律 fail closed。

    ⚠️ **两个提交入口共用同一份判定**：codex R6 只报了收尾提交那一处，
    而 per-stock 提交同一轮也刚改成「从磁盘取」，同样的洞照样在
    （控制者拿第⑨问自查挖出）——**同一件事绝不判在两处**（S2-F15 的教训）。

    - 磁盘上没有账本、启动快照也是空的 → **真引导态**，返回 `{}`（R60-F3：
      首份 manifest 还没提交时必须能继续初始化）；
    - 磁盘上没有账本、而启动快照非空 → 本次运行期间有人删掉/改名了它 → 拒绝；
    - 磁盘上有账本、但生命周期与启动快照不一致 → 有人动过账本 → 拒绝。

    ⚠️ `startup_lifecycle` 在这里**只当预期用来比对，从不被写进 payload**
    （写的永远是磁盘上那份），所以它不构成走私通道 —— 伪造的对不上磁盘。
    """
    seen = _read_manifest_with_digest(stg_fd)
    if ledger.existed:
        if seen is None:
            raise ManifestInvalidError(
                "本次运行此前看见过这棵 staging 的账本，而现在它**不见了**"
                "——运行期间有人删掉或改名了它。拒绝写入：账本是 files / "
                "pool_order / cursor 的唯一真相，凭内存里那份重建等于把已积累的"
                "进度静默丢弃。请人工核实 staging 现场。"
            )
        if seen[1] != ledger.digest:
            raise ManifestInvalidError(
                "磁盘上的账本与本次运行此前看见的那一份**字节指纹不一致**"
                "——运行期间它被改过或被换成了另一份。拒绝写入。"
            )
        return lifecycle_snapshot(seen[0]), seen[0]
    if seen is not None:
        raise ManifestInvalidError(
            "本次运行开始时这棵 staging 上**没有**账本，而现在**出现了一份**"
            "——很可能有另一个进程正在同一棵 staging 上跑。拒绝写入：覆盖它"
            "等于把对方的进度盖掉。"
        )
    return {}, None


@dataclass(frozen=True)
class RecoveryScope:
    """崩溃恢复允许改动的**确切范围**（spec §4.4 恢复第③档）。

    ⚠️ **取代原先那个布尔旁路**（codex R9 [high]）：`recovering_from_crash=True`
    此前**整条**跳过回滚守卫。本机复现：一次「恢复」把所有市场的所有股票全清了、
    cursor 全归零，而账本结构上还合法 —— 已提交的 CSV 全部变成无主文件。
    spec 只允许**删那一只在途的股**并把**该层** cursor 退到它的 `universe_idx`。

    **一切与该范围无关的不变量照旧强制**。
    """
    stock_code: str
    market: str
    universe_idx: int

    def __post_init__(self) -> None:
        if not isinstance(self.stock_code, str) or \
                _STOCK_CODE_RE.match(self.stock_code) is None:
            raise ValueError(f"stock_code 形如 600000.SH，收到 {self.stock_code!r}")
        if not isinstance(self.market, str) or self.market not in MARKETS:
            raise ValueError(f"market 必须是 {list(MARKETS)} 之一，收到 {self.market!r}")
        if not isinstance(self.universe_idx, int) or \
                isinstance(self.universe_idx, bool) or self.universe_idx < 0:
            raise ValueError(
                f"universe_idx 必须是非负整数，收到 {self.universe_idx!r}")
        if not self.stock_code.endswith("." + self.market):
            raise ValueError(
                f"stock_code {self.stock_code!r} 的后缀与 market {self.market!r} 不一致")



def _carry_forward_persisted_keys(previous: "dict | None", payload: dict) -> None:
    """把**磁盘上有、而这次 payload 没有**的顶层键原样带过来（就地修改 payload）。

    ⚠️ **省略即删除**是错的（codex R15 [high]）：提交此前是「用调用方那份整体
    覆盖」，于是省略任何一个已持久化的顶层键就等于静默删掉它 —— 而 O4-F10 的
    「未知顶层键原样保留」正是 S3/S4 的 `failures` / `batches` /
    `inflight_rollbacks` / `quota` 赖以流转、且**不需要 bump manifest_version**
    的理由。那条通道一旦漏水，「旧工具消费新版 manifest 后把不认识的字段丢掉
    → 再用新工具打开时缺必需字段 → 一棵 400 只股的 staging 被一次『用错版本
    跑补拉』永久毁掉」就重新成立。

    生命周期三键不在此列：它们由两个提交入口各自的规则单独决定。
    """
    if previous is None:
        return
    for k, v in previous.items():
        # ⚠️ 只带**非必需键**：O4-F10 说的是「未知顶层键原样保留」。
        # 必需键由调用方负责给全 —— 缺了就该被读侧校验当场拒掉，
        # 而不是由本函数悄悄补上（那会把调用方的 bug 修得看不见）。
        if k not in payload and k not in LIFECYCLE_KEYS and k not in REQUIRED_KEYS:
            payload[k] = copy.deepcopy(v)


def _require_intrinsic_payload_ok(payload: dict, where: str) -> None:
    """**只看这一份 payload 自身**的检查（与「有没有上一份」无关）。

    ⚠️ 与转移检查分开的理由（codex R14 [high]）：绑在同一个
    `if previous is None: return` 里，**首次提交会整个跳过它们**。

    目前只有一条：`failures` 不得有同名记录。按 `stock_code` 归并时后者覆盖
    前者，而补拉是「先重试 `attempts < 2` 的条目」（§4.4:350）——两条同名记录
    能让一个**已耗尽重试的候选被复活**（codex R12 [high]）。
    """
    # ⚠️ **有 files 就必须带合法的 `committed_bytes`**（codex R15 [high]）。
    # 本机复现：files 从 4 条涨到 6 条而该字段始终缺席 —— 转移守卫里的配额判据
    # 一次都没触发，`--max-bytes` 这条硬上限被**无限期**绕开。
    # ⚠️ 它是**只看这一份 payload** 的性质，所以必须放在这里 ——
    # 放进转移守卫会被引导态的早退跳过，而引导态正是它最该管的那一档。
    # ⚠️ **只在写侧强制**：加进读侧必需键构成「新增必需字段」，按 O2-F8 必须
    # bump `manifest_version` —— 超出本片范围，已在 spec 登记为交给 S4/S5。
    # ⚠️ **staged `export_log.csv` 也计入 `--max-bytes`**（spec:532，O2-F2：
    # 它是**唯一的非股级计账对象**）。此前下限只加 `files`，于是：
    #   ① 引导态账本 `files` 为空 → 整条判据被 `if files:` 跳过，而 export_log
    #      在**第一份 manifest 之前**就已落盘（spec:538）——盘上已占 240 万字节
    #      而账本记 0；
    #   ② 有 files 时把 export_log 那一份漏掉，同样一路放行。
    # 两者都让下一次运行从一个**被低估的总数**起步，`--max-bytes` 这条硬上限
    # 被突破正好一份 export_log 的量（codex R16 [high]，本机复现两档）。
    files = payload.get("files")
    files = files if isinstance(files, list) else []
    sel = payload.get("staged_export_log")

    def _bytes_of(rec):
        b = rec.get("bytes") if isinstance(rec, dict) else None
        return b if isinstance(b, int) and not isinstance(b, bool) and b >= 0 else 0

    if files or sel is not None:
        nb = payload.get("committed_bytes")
        need = sum(_bytes_of(f) for f in files) + _bytes_of(sel)
        if not isinstance(nb, int) or isinstance(nb, bool) or nb < 0 or nb < need:
            raise ManifestInvalidError(
                f"{where} 的账本里有 {len(files)} 条 files 记录 + staged "
                f"export_log {_bytes_of(sel)} 字节，而 committed_bytes 是 "
                f"{nb!r}（须为非负整数且不小于两者之和 {need}）——"
                "缺了它，--max-bytes 这条硬上限就被无限期绕开。"
            )

    # ⚠️⚠️ **写侧必须挡住它自己会造出来的坏容器**（独立评审 [medium]）：
    # 上一轮只给**转移守卫**（看 `previous`）加了容器类型检查，而写侧固有检查没加
    # ⇒ **首次提交**就能把 `batches: {...}` 写上盘，此后每次提交（含崩溃恢复）
    # 都被那条读侧检查拒掉 —— **那棵 staging 永久砖化，只能手改 JSON 救回来**。
    # 这正是本模块自己 docstring 点名的失败形态（「引导态第一次提交就把…写了
    # 进去…这棵 staging 当场卡死」），我加读侧那半时漏了写侧这半。
    # ⚠️ 只在**键存在**时验类型：两者都是扩展字段，缺席合法。
    for _k, _ty, _tn in (("batches", list, "列表"),
                         ("inflight_rollbacks", dict, "对象")):
        if _k in payload and not isinstance(payload[_k], _ty):
            raise ManifestInvalidError(
                f"{where} 的 {_k} 是 {payload[_k]!r}（不是{_tn}）——"
                f"写出去之后每一次提交都会被转移守卫拒掉，这棵 staging 会当场卡死。"
            )

    lst = payload.get("failures")
    seen_codes = set()
    for f in (lst if isinstance(lst, list) else []):
        if not isinstance(f, dict):
            continue
        code = f.get("stock_code")
        # ⚠️ **先验类型再比取值**（本仓既有做法，Kimi 评审 [medium]）：
        # 重名判据只对字符串有意义，而 `failures` 读侧从不校验 ⇒ 这里是它
        # 唯一的把关处。不验类型时 `code in seen_codes` 直接抛裸 TypeError。
        if not isinstance(code, str):
            raise ManifestInvalidError(
                f"{where} 的 failures 里有一条 stock_code 不是字符串"
                f"（读到 {type(code).__name__}：{code!r}）——它是「哪只股失败过、"
                "还剩几次重试」的唯一标识，不是字符串时补拉的归并与有界重试"
                "都无从谈起。"
            )
        # ⚠️ **`attempts` 才是真正携带重试次数的那个字段**（Opus-4 [medium]）。
        # 上一轮给 `stock_code` 加类型校验时，理由写的是「它是『哪只股失败过、
        # 还剩几次重试』的唯一标识」—— 而**记着还剩几次的是这一个**，当时漏了。
        # 「按字段穷尽而不是按判据句穷尽」的又一次。
        # ⚠️ 评审同时推翻了我不做校验的理由：**「键存在时校验它的类型」既不是
        # 新增必需字段、也不需要 bump `manifest_version`**（O2-F8 管的是前者）。
        att = f.get("attempts")
        if not isinstance(att, int) or isinstance(att, bool) or att < 0:
            raise ManifestInvalidError(
                f"{where} 的 failures 里 {code!r} 的 attempts 是 {att!r}"
                "——它必须是**非负整数**（spec §4.4 明写 failures 含 attempts）。"
                "缺席或坏型会让「凭空移出必须自证成功」那条守卫整条失效，"
                "一个已经耗尽重试的候选就能被悄悄复活。"
            )
        if code in seen_codes:
            raise ManifestInvalidError(
                f"{where} 的 failures 里有**重复**的 {code!r} 记录。"
                "按 stock_code 归并时后者会覆盖前者，而补拉是「先重试 attempts<2 的"
                "条目」——两条同名记录能让一个已耗尽重试的候选被复活。"
            )
        seen_codes.add(code)


def _require_no_progress_rollback(previous: dict | None, payload: dict,
                                  where: str,
                                  recovery: "RecoveryScope | None" = None) -> None:
    """磁盘上已提交的进度**不得被一份过期的调用方副本悄悄回滚**。

    ⚠️ 运行凭据管的是「账本有没有被**外人**动过」（消失 / 被替换 / 指纹变了），
    它**管不了**「调用方自己交回来的内容退步了」——两个提交入口的非生命周期内容
    **全部**来自调用方内存。本机复现：调用方拿一份过期副本再提交一次，
    `files` 由 6 条退回 4 条、`cursor` 倒退、`pool_order` 缩水，而凭据检查照过。
    后果：已拷到盘上的股票被从台账里抹掉——它们随后既不在池里，
    又会被 pilot 当成 `untracked_target_file`。

    ⚠️⚠️ **不能写成「条目只增不减」**：spec §4.4:429 明写崩溃恢复发生在
    「读完并校验 manifest **之后**、任何拷贝**之前**」（也就是在 `begin_run`
    之后、运行之内），而恢复第③档要求 `cursor ← min(cursor, universe_idx)`
    且**只删该股的** `files` / `pool_order` 条目 —— 那是**合法**的回退。
    写死单调会打死 spec 自己的恢复路径，让崩过一次的 staging 永远修不好。
    ⇒ 故本守卫只拦**未声明的**回退；唯一正当理由由调用方显式声明
    （`commit_stock(..., recovering_from_crash=True)`）。
    """
    # ⚠️ **只看 payload 的固有检查必须先于早退**（codex R14 [high]）：
    # 它们与「有没有上一份」无关。绑在同一个 `if previous is None: return` 里的
    # 后果是**首次提交整个跳过它们** —— 本机复现：引导态第一次提交就把
    # `[attempts 0, attempts 2]` 两条同名记录写了进去，既复活一个已耗尽重试的
    # 候选，又让**下一次**提交因「重复」被拒，这棵 staging 当场卡死。
    _require_intrinsic_payload_ok(payload, where)

    if previous is None:
        return

    # ⓪ 崩溃恢复是**一次耦合的转移**，不是两个各自独立的许可（codex R11 [high]）。
    #    spec §4.4 恢复第③档：删该股条目 **且** `cursor[market] ← min(cursor, idx)`。
    #    分开判时「删了条目、游标原样停在后面」照样通过 —— 那只股**永远不会被
    #    重新拉取**，池子静默缩水，正是恢复流程本来要消灭的那个状态。
    scoped_removed = False
    if recovery is not None:
        uni = previous.get("source_snapshot", {})
        uni = uni.get("universe", {}) if isinstance(uni, dict) else {}
        lst = uni.get(recovery.market) if isinstance(uni, dict) else None
        anchored = (isinstance(lst, list) and 0 <= recovery.universe_idx < len(lst)
                    and lst[recovery.universe_idx] == recovery.stock_code)
        if not anchored:
            raise ManifestInvalidError(
                f"崩溃恢复声明的范围与**冻结名单**对不上："
                f"universe[{recovery.market!r}][{recovery.universe_idx}] 不是 "
                f"{recovery.stock_code!r}。锚点核对是在途标记形状校验的同一条纪律"
                "——一个错的下标能让 cursor 退到任意位置。"
            )

        def _has(m, code):
            lst_f = m.get("files")
            n = sum(1 for f in (lst_f if isinstance(lst_f, list) else [])
                    if isinstance(f, dict) and f.get("stock_code") == code)
            pool = m.get("pool_order")
            pool = pool.get(recovery.market) if isinstance(pool, dict) else None
            in_pool = any(isinstance(e, dict) and e.get("code") == code
                          for e in (pool if isinstance(pool, list) else []))
            return n, in_pool

        pn, pp = _has(previous, recovery.stock_code)
        nn, np_ = _has(payload, recovery.stock_code)
        if (pn or pp) and not (nn or np_):
            scoped_removed = True
        elif (pn, pp) != (nn, np_):
            # ⚠️ **本条造不出专属档（如实登记，本片第四次撞同一耦合）**：
            # 「部分移除」产出的账本本身就非法（R21-F3：每个池条目恰配两条
            # files 记录），落盘前的读侧校验会先把它拒掉，走不到这里。
            # 保留它是**防御性冗余** —— 万一将来那条一致性规则被放宽。
            raise ManifestInvalidError(
                f"崩溃恢复只**部分**移除了 {recovery.stock_code}"
                f"（files {pn}→{nn} 条、池条目 {pp}→{np_}）——"
                "spec 要求那只股的两条 files 与池条目**一起**消失。"
            )

    # ① 冻结字段：一经写入就不许再变。
    for k in _FROZEN_KEYS:
        if k in previous and previous[k] != payload.get(k):
            raise ManifestInvalidError(
                f"{where} 改动了**冻结字段** {k!r} —— 它一经写入就不该再变"
                "（seed / 冻结的 universe / 挂载身份 / staged export_log）。"
                "调用方交回来的很可能是一份过期或来自另一棵 staging 的副本；"
                "改掉它会让这棵 staging 与自己的归属标记永久对不上。"
            )

    def _by_id(m):
        out = {}
        for f in m.get("files", []) if isinstance(m.get("files"), list) else []:
            if isinstance(f, dict):
                out[(_hashable(f.get("stock_code")), _hashable(f.get("period")),
                     _hashable(f.get("relative_path")))] = f
        return out

    # ② 已提交的 files 记录：不得消失，也不得被改写。
    prev_files, new_files = _by_id(previous), _by_id(payload)
    for key, rec in prev_files.items():
        if key not in new_files:
            # ⚠️ **豁免只在该股被「完全移除」时生效**（codex R13 [high]）：
            # 只看「条数 + 在不在池里」时，把两条记录的 relative_path / bytes /
            # sha256 全换掉仍是 (2, True) —— 既不算完全移除、也不用退游标，
            # 于是一只**已提交**的股票被**重新绑定到不同的文件**，原文件变孤儿，
            # 而 pilot 的 staging_intact 从此校验的是被换过的基线。
            if (recovery is not None and scoped_removed
                    and key[0] == recovery.stock_code):
                continue                      # 恢复范围内：允许删这一只股的记录
            raise ManifestInvalidError(
                f"{where} 会把已提交的 files 记录 {key} **回滚**掉"
                + ("——超出本次崩溃恢复声明的范围（只允许删 "
                   f"{recovery.stock_code}）。" if recovery is not None else
                   "——调用方交回来的很可能是一份过期副本。")
                + "账本是 files / pool_order / cursor 的唯一真相，抹掉它们等于让"
                  "已拷到盘上的股票既不在池里、又被 pilot 当成来路不明的文件。"
            )
        if new_files[key] != rec:
            raise ManifestInvalidError(
                f"{where} **改写**了已提交文件 {key} 的记录（bytes / sha256 等）"
                "——完整性基线一旦被污染，pilot 的 staging_intact 从此校验的是"
                "一条假基线。已提交的文件记录只许新增，不许修改。"
            )

    for mk in MARKETS:
        def _pool_seq(m):
            """取 `pool_order[mk]` 的**列表** —— 全函数唯一一处这么取。

            ⚠️⚠️ **`.get(mk, [])` 在「键存在、值是 null」时交出的是那个 `None`**
            （默认值只在键**缺席**时才生效）。`_pool_ids` 原本正是这么写的，于是
            `pool_order.SH = null` 让守卫抛裸 `TypeError: 'NoneType' object is not
            iterable`；同族还有把它写成 int/str/bool/dict 的五种。
            ⚠️ 这两个 bug 我**已经在旁边那个帮手里修过了**（上一轮加 `_pool_seq`
            时写的是 `isinstance(lst, list)`），只是没回头看隔壁 —— **同一件事
            判在两处、只改对了一处**，本片第三次。⇒ 合并成一个访问器。
            （控制者把「整族坏值扫描」从读侧扩到写侧后挖出，7 类 34 个逃逸全在这里。）
            """
            lst = m.get("pool_order")
            lst = lst.get(mk) if isinstance(lst, dict) else None
            return list(lst) if isinstance(lst, list) else []

        def _pool_ids(m):
            # ⚠️ 成员要进 `set` ⇒ 必须过 `_hashable`，否则 `code` 是 list/dict 时
            # 集合推导自己抛裸 TypeError（与 `_progress_of` 同一条纪律）。
            return {(_hashable(e.get("code")), _hashable(e.get("universe_idx")))
                    for e in _pool_seq(m) if isinstance(e, dict)}
        # ③ 池条目不得消失。
        gone = _pool_ids(previous) - _pool_ids(payload)
        # ⚠️ 本条的 `scoped_removed` 前置**造不出专属档**（如实登记，第五次撞同一耦合）：
        # files 判据排在前面，池条目消失时它的文件记录必然也先消失并触发那一条。
        # 保留是**防御性冗余**，与上面那处同源。
        if recovery is not None and scoped_removed and mk == recovery.market:
            gone -= {(recovery.stock_code, recovery.universe_idx)}
        if gone:
            raise ManifestInvalidError(
                f"{where} 会把 {mk} 层已提交的池条目 {sorted(gone, key=repr)} **回滚**掉"
                + ("——超出本次崩溃恢复声明的范围。" if recovery is not None else
                   "——调用方交回来的很可能是一份过期副本。")
            )
        # ③b **池是有序的**：spec:545「`pool_order[market]` **按序追加**」，
        #    且它是「pilot 的唯一消费顺序来源」（P4-D8）。只比集合时，
        #    **重排已提交条目**、或**把新条目插到已提交条目之前**，成员一个
        #    没少 → 一路放行，而 pilot 消费的次序已经被换掉：断点续跑的
        #    `already_done` 与「池穷尽」判定双双失真，且**不改变任何身份**，
        #    安静地发生（codex R16 [high]，本机复现两档）。
        #    ⇒ 判据 = 上一份必须是新一份的**前缀**（恢复范围内先摘掉那一只）。
        old_seq = _pool_seq(previous)
        if recovery is not None and scoped_removed and mk == recovery.market:
            # 授权删的那一只**摘掉**，其余条目的相对次序照旧必须保住。
            old_seq = [e for e in old_seq
                       if not (isinstance(e, dict)
                               and e.get("code") == recovery.stock_code)]
        new_seq = _pool_seq(payload)
        if new_seq[:len(old_seq)] != old_seq:
            raise ManifestInvalidError(
                f"{where} 改写了 {mk} 层已提交池条目的**顺序**"
                f"（上一份 {[e.get('code') if isinstance(e, dict) else e for e in old_seq]}"
                f" → 本次 {[e.get('code') if isinstance(e, dict) else e for e in new_seq]}）"
                "——spec 规定 pool_order 只许**按序追加**，它是 pilot 的唯一消费"
                "顺序来源；次序被改写等于换掉了「先消费哪几只」，而成员一个没少，"
                "断点续跑与池穷尽判定会双双失真。"
            )
        # ④ cursor 不得倒退（恢复范围内允许退到那一只股的下标）。
        old_c = previous.get("cursor", {}).get(mk) \
            if isinstance(previous.get("cursor"), dict) else None
        new_c = payload.get("cursor", {}).get(mk) \
            if isinstance(payload.get("cursor"), dict) else None
        if isinstance(old_c, int) and isinstance(new_c, int):
            in_scope = recovery is not None and mk == recovery.market
            want = min(old_c, recovery.universe_idx) if in_scope else None
            if in_scope and scoped_removed:
                # 删了那只股 ⇒ 游标**必须**退到确切位置（耦合转移的另一半）。
                if new_c != want:
                    raise ManifestInvalidError(
                        f"崩溃恢复删除了 {recovery.stock_code}，"
                        f"但 {mk} 层的**游标**是 {new_c}、应为 min(cursor, "
                        f"{recovery.universe_idx}) = {want}。"
                        "删条目与退游标是**一次耦合的转移**：只删不退的话，"
                        "那只股永远不会被重新拉取，池子会静默缩水。"
                    )
            elif new_c < old_c:
                raise ManifestInvalidError(
                    f"{where} 会让 {mk} 层的 cursor 从 {old_c} **倒退**到 {new_c}"
                    + ("——本次崩溃恢复并未移除声明的那只股，"
                       "**只退游标**同样超出范围。"
                       if in_scope else
                       "——调用方交回来的很可能是一份过期副本。")
                )

    # ⑤ 单调计数：累计字节 / 历史 / 遥测 / 每股重试次数。
    #
    # ⚠️⚠️ **「上一份里有的，新的必须仍在、类型仍对」**（codex R10 [high]）：
    # 守卫此前写成「两边类型都对才比」，于是**字段缺席或类型不对时守卫被跳过**、
    # 改写照样落盘。而这些都是**扩展字段**，读侧校验根本不要求它们存在、兜不住。
    # 「对坏输入要健壮」（S2-F9）指的是**别崩**，**不是别拦**。
    def _int_or_none(v):
        return v if isinstance(v, int) and not isinstance(v, bool) else None

    # ⚠️ **上一份的值坏型时，此前是「跳过整条」而不是「拒绝」**（Opus-4 [medium]）。
    # R10 那次只把「新值必须良型」补上了，**旧值仍然是整条检查的前置条件** ——
    # 而「对坏输入要健壮」（S2-F9）说的是**别崩**，**不是别拦**，这句话就写在
    # 上面那段注释里。三处同族：committed_bytes / inflight_rollbacks / attempts。
    if "committed_bytes" in previous and _int_or_none(
            previous.get("committed_bytes")) is None:
        raise ManifestInvalidError(
            f"{where} 读到的上一份里 committed_bytes 是 "
            f"{previous.get('committed_bytes')!r}（不是非负整数）——它是 "
            "--max-bytes 的累计基准，坏型时无从比较，拒绝在它之上继续提交。"
        )
    ob = _int_or_none(previous.get("committed_bytes"))
    if ob is not None:
        nb = _int_or_none(payload.get("committed_bytes"))
        if nb is None or nb < ob:
            raise ManifestInvalidError(
                f"{where} 会让 committed_bytes 从 {ob} 变成 "
                f"{payload.get('committed_bytes')!r}——它是累计量，"
                "调小、删掉或换成别的类型都等于绕开 --max-bytes 这条硬上限。"
            )
        # ⚠️ **只拦「减少」不够**（codex R14 [high]）：**加了文件却原地不动**
        # 照样通过 —— 下一次运行从一个被低估的累计值起步，突破 --max-bytes
        # 这条硬上限，最坏把仅约 30 GiB 的可用空间写满（本机复现：新增 246 万
        # 字节而累计值纹丝不动）。
        # ⚠️ 判据取「**至少涨够新增文件的字节数**」而非严格相等：
        # spec 未定 committed_bytes 计不计失败 `.part` 的字节（5o 只说
        # `--max-bytes` 是逐块扣减的流式上限），严格相等会把那种合法记账判死。
        added = 0
        for key, rec in new_files.items():
            if key not in prev_files:
                b = _int_or_none(rec.get("bytes"))
                if b is not None:
                    added += b
        _ = added                    # 下面用
        if added and nb < ob + added:
            raise ManifestInvalidError(
                f"{where} 新增了合计 {added} 字节的 files 记录，而 "
                f"committed_bytes 只从 {ob} 涨到 {nb}——累计量必须至少涨够"
                "新增文件的字节数，否则下一次运行会从一个被低估的总数起步，"
                "突破 --max-bytes 硬上限。"
            )

    # ⚠️ **容器这一层此前漏了**（Opus 第 5 轮 [low]）：同一次提交里刚给
    # `committed_bytes` 与**内层取值**改成「拒绝」（注释自称「三处同族」），
    # 而 `isinstance(容器)` 不成立时整条判据仍然被**跳过**。这两个都是扩展字段、
    # 读侧写侧都不校验 ⇒ 本模块自己就可能把坏容器写上盘，下一次提交把历史抹空。
    obt = previous.get("batches")
    if "batches" in previous and not isinstance(obt, list):
        raise ManifestInvalidError(
            f"{where} 读到的上一份里 batches 是 {obt!r}（不是列表）——"
            "它是只追加的历史，容器坏型时无从比较前缀，拒绝在它之上继续提交。"
        )
    if isinstance(obt, list):
        nbt = payload.get("batches")
        # ⚠️ **只比长度不够**：一次**等长改写**就能把历史悄悄换掉（本机复现过）。
        # 旧列表必须是新列表的**前缀** —— batches 是只追加的历史。
        if not isinstance(nbt, list) or nbt[:len(obt)] != obt:
            raise ManifestInvalidError(
                f"{where} 会**改写或丢弃** batches 历史（旧 {len(obt)} 条必须原样"
                f"作为新列表的前缀保留，读到 {nbt!r}）——它是只追加的历史。"
            )

    orb = previous.get("inflight_rollbacks")
    if "inflight_rollbacks" in previous and not isinstance(orb, dict):
        raise ManifestInvalidError(
            f"{where} 读到的上一份里 inflight_rollbacks 是 {orb!r}（不是对象）——"
            "它是基础设施故障的遥测，容器坏型时无从比较，拒绝在它之上继续提交。"
        )
    if isinstance(orb, dict):
        nrb = payload.get("inflight_rollbacks")
        if not isinstance(nrb, dict):
            raise ManifestInvalidError(
                f"{where} 会**丢弃** inflight_rollbacks 遥测（读到 {nrb!r}）"
                "——丢掉它会把本机故障史抹成「市场就这样」（R66-F3）。"
            )
        for k, v in orb.items():
            ov = _int_or_none(v)
            if ov is None:
                raise ManifestInvalidError(
                    f"{where} 读到的上一份里 inflight_rollbacks[{k!r}] 是 {v!r}"
                    "（不是非负整数）——坏型时无从比较，拒绝在它之上继续提交。"
                )
            nv = _int_or_none(nrb.get(k))
            if nv is None or nv < ov:
                raise ManifestInvalidError(
                    f"{where} 会让 inflight_rollbacks[{k!r}] 从 {ov} 变成 "
                    f"{nrb.get(k)!r}——它是基础设施故障的遥测，只增不减。"
                )

    def _attempts(m):
        out = {}
        lst = m.get("failures")
        for f in lst if isinstance(lst, list) else []:
            if isinstance(f, dict):
                out[_hashable(f.get("stock_code"))] = _int_or_none(f.get("attempts"))
        return out

    def _proved_success(m, code):
        """该股在这份 manifest 里**自证成功**了吗？

        判据 = 它在 `pool_order` 里有锚点条目，且 `files` 里恰好两条记录
        （1m + daily，R21-F3）。
        """
        pool = m.get("pool_order")
        pool = pool if isinstance(pool, dict) else {}
        anchored = any(
            isinstance(e, dict) and e.get("code") == code
            for mk in MARKETS
            for e in (pool.get(mk) if isinstance(pool.get(mk), list) else []))
        lst = m.get("files")
        n = sum(1 for f in (lst if isinstance(lst, list) else [])
                if isinstance(f, dict) and f.get("stock_code") == code)
        return anchored and n == 2

    oa, na = _attempts(previous), _attempts(payload)
    for code, v in oa.items():
        # ⚠️⚠️ **「凭空移出」必须先判，且与旧值是不是良型数字无关**（Opus-4 [medium]）。
        # 此前 `if v is None: continue` 排在最前面，于是一条 `attempts` 缺席/坏型的
        # 记录**连「移出要自证成功」都一起跳过了** —— 而本模块自己就写得出这种
        # 记录（读侧不碰 failures、写侧当时只校验 stock_code）。
        # 端到端复现：第一次写进一条没有 attempts 的记录，第二次整个删掉，
        # 那只股既不在池里也没有 files 记录（毫无成功证据）却被凭空移出。
        if code not in na:
            # ⚠️ **spec §4.4:350 + O2-F14 明写「重试成功即把该条目移出 failures
            # 并计入 batches 历史」** —— 一律拒会把这条路堵死，让一个只是瞬时
            # 失败过的候选**永远回不到池子里**，最终报出假的池穷尽 / 达不到地板
            # （codex R10 [high]）。故：**移出必须自证成功**。
            if _proved_success(payload, code):
                continue
            raise ManifestInvalidError(
                f"{where} 把 {code} 的 failures 条目移出了，却没有它成功的证据"
                "（`pool_order` 里的锚点条目 + `files` 里恰好两条记录）"
                "——凭空移出等于复活一个已经耗尽重试的候选。"
            )
        if v is None:
            continue                    # 旧值不是数字 ⇒ 无从比大小（条目仍在即可）
        nv = na[code]
        if nv is None or nv < v:
            raise ManifestInvalidError(
                f"{where} 会让 {code} 的 failures.attempts 从 {v} 变成 {nv!r}"
                "——重试次数只增不减，调小它等于复活一个已经耗尽重试的候选。"
            )


def begin_run(stg_fd: int, *, skip_existing_verify: bool = False) -> RunLedger:
    """**启动闸**：读回磁盘上的 manifest，执行启动期互斥检查，返回生命周期启动快照。

    返回的快照是收尾提交的**预期**（`commit_final(..., startup_lifecycle=…)`），
    用来识别「本次运行期间账本被人动过」。

    ⚠️ **`--skip-existing-verify` 与「manifest 带着必须做全量复校才能清的证据」
    互斥，且必须在**任何文件系统改动之前**判定**（P2-F3 明写「撞上即**拒绝启动**」）。
    此前这条只在 `resolve_final_lifecycle` 里求值，而那是**收尾提交**才走的路径
    ——一次带 flag 的运行可以先拷完文件、推进游标、写满池子，到最后才被拒，
    **已提交的状态与已消耗的配额都收不回来**（codex R6 [high]）。

    ⚠️ **已接受的残留**：本模块无法强制调用方**先调本函数再动文件系统**
    （它没有运行上下文对象）。**这是对 S4/S5 的硬性要求**：启动序列必须
    第一步就调它，且在任何拷贝/建目录/提交之前。
    """
    # ⚠️ 必须是**真正的 bool**：非空字符串是真值（R1 在 `revisited_fatal_path`
    # 上栽过同一条），而本参数守的是「拒绝启动」这条闸——别猜调用方的意思。
    if not isinstance(skip_existing_verify, bool):
        raise ValueError(
            "skip_existing_verify 必须是 True/False（真正的布尔值），"
            f"收到 {skip_existing_verify!r}"
        )
    seen = _read_manifest_with_digest(stg_fd)
    snapshot = lifecycle_snapshot(seen[0]) if seen is not None else {}
    owes_recheck = _needs_staging_recheck(
        snapshot.get("stopped_reason"), snapshot.get("fetch_fatal_error"))
    # ⚠️ **互斥的对象是「账本带 escape 记录」，spec §4.5:484 原文没有限定 kind**。
    # 此前只挡 `_needs_staging_recheck` 那两种（staging 侧）—— 于是带
    # `source_path_escape` 的账本配上该 flag 能正常起跑，**并在同一轮把 fatal
    # 清掉**（清除 source escape 只要前提①）；而这一轮恰恰跳过了「已 staged 的
    # 文件与源对不对得上」，正是该 flag 跳过的那件事（Opus 评审 [medium]，
    # 本机端到端复现）。判据用 `fetch_fatal_error` 在不在 —— 它才是 O4-F1 定的
    # **粘性信任状态**，`stopped_reason` 只是人读附注。
    if skip_existing_verify and snapshot.get("fetch_fatal_error") is not None:
        raise SkipVerifyWithEscapeError(
            "这棵 staging 的 manifest 里带着必须做全量复校才能解除的记录，"
            "而本次传了 --skip-existing-verify。两者互斥：跳过复校就无法证明"
            "那些已记录的文件还在、还是原来的字节。请去掉该 flag 重跑，"
            "或换新 staging + 新 seed 重拉。"
        )
    handle = object.__new__(RunLedger)          # 绕过公开构造路径，只此一处
    _LEDGER_STATE[handle] = _RunState(
        existed=seen is not None,
        digest=seen[1] if seen is not None else None,
        lifecycle=snapshot,
        skip_existing_verify=skip_existing_verify,
        start_progress=_progress_of(seen[0] if seen is not None else None),
        start_needs_recheck=owes_recheck,
    )
    return handle


def attest_staging_recheck(ledger: RunLedger, *, passed: bool) -> None:
    """登记**本次运行**那一趟 staging 全量存在性 + sha256 复校的结论（P2-F3 前提②）。

    ⚠️ **为什么必须有这个入口**（codex R16 [high]）：P2-F3 要求复校失败的那一轮
    「不得推进 `cursor`、不得新增 `files`/`pool_order`」。此前它只判在**收尾提交**，
    而 per-stock 提交早已**逐只落盘** —— 收尾抛异常**收不回**磁盘上的进度：
    下一次重跑从被推进过的 cursor 起步，继续消耗冻结宇宙与 `--max-bytes` 预算；
    P2-F3 为这一轮指定的 `stopped_reason: "staging_recheck_failed"` 还一次都没记上。
    ⇒ 唯一能兑现那条要求的做法是**把复校挪到任何 per-stock 提交之前**，
    并让模块**自己记住**结论 —— 调用方口头上报的东西不能当凭据。

    ⚠️ **结论不许改口**：复校在一次运行里只做一次。允许 `failed → passed`
    就等于给「洗白一次没通过的复校」开了门（重复登记**同一个**结论是幂等的）。

    ⚠️ **对 S4/S5 的硬性要求**（与 `begin_run` 那条同源、本模块强制不了）：
    账本上带着这类记录时，启动序列必须是 `begin_run` → 做完整棵 staging 的
    全量复校 → 本函数 → 才允许开拷。
    """
    if not isinstance(ledger, RunLedger) or ledger not in _LEDGER_STATE:
        raise ValueError(
            f"ledger 必须是 begin_run() 产出的 RunLedger，收到 {type(ledger).__name__}")
    # 必须是**真正的 bool**：非空字符串是真值，`passed="false"` 会把一次
    # 失败的复校登记成通过（与 `revisited_fatal_path` 栽过的是同一条）。
    if not isinstance(passed, bool):
        raise ValueError(
            "passed 必须是 True/False（真正的布尔值），"
            f"收到 {passed!r}——它是「这棵 staging 已自证完整」的唯一凭据"
        )
    verdict = "passed" if passed else "failed"
    st = ledger._state()
    # ⚠️⚠️ **这一轮不欠复校时一律拒绝登记**（Opus 评审 [medium]，本机复现）。
    # 不拒的后果：干净账本上 `attest(passed=False)` 会被**静默丢弃** ——
    # 闸只看起跑状态所以 per-stock 提交照样放行，收尾走决策表分支②
    # （上次没有 fatal）返回 `{}`，「这棵树复校没过」哪都没写。
    # ⚠️ **为什么修法是「拒绝」而不是「把它记下来」**：pilot 的 fail-closed 判据
    # 是「`fetch_fatal_error` 存在」（O4-F1），`stopped_reason` 只是人读附注 ——
    # 只写 reason 是**假安全**；要真生效就得**凭空造一个 fatal**（四字段一个都
    # 造不出来）。本入口只为 P2-F3 的前提②存在，账本上没有那类记录时它没有
    # 可写入的位置。这一轮的失败由 S4/S5 在**运行级**（rc≠0 + 报告）表达 ——
    # 与 S2-F14 已接受的那条残留同规格，已在 spec 登记。
    # ⚠️⚠️ **该 flag 的定义就是「跳过对既有文件的校验」**，因此这样的一轮
    # **不可能**产出「全量存在性 + sha256 复校通过」这个结论。P2-F3 的互斥此前
    # 只在 `begin_run` 判过一次，而一次**干净起步**的运行自己发布一条逃逸之后，
    # 状态与「启动时就带着 escape 记录」完全等价、模块却什么都没复判
    # （Opus 第 5 轮 [medium]，实测：那之后 attest(True) 被接受、下一次收尾清掉 fatal）。
    # `attest_staging_recheck` 存在的全部理由是「调用方口头上报的不能当凭据」——
    # 这恰恰是它**唯一能交叉核对却没核**的那个调用方声明。
    if st.skip_existing_verify:
        raise SkipVerifyWithEscapeError(
            "本次运行传了 --skip-existing-verify —— 它的定义就是**跳过**对既有"
            "文件的校验，因此这一轮不可能产出「全量复校通过」这个结论，"
            "两者互斥。请去掉该 flag 重跑，或换新 staging + 新 seed 重拉。"
        )
    if not st.start_needs_recheck:
        raise ValueError(
            "这棵 staging 的账本上没有「必须做全量复校才能解除」的记录，"
            f"本次运行不欠一次复校，因而登记 {verdict!r} 没有可写入的位置。"
            "本入口只为 P2-F3 的前提②存在；若你确实跑了复校且没通过，"
            "请在运行级（非零退出码 + 报告）表达，本模块不会凭空造一个 "
            "fetch_fatal_error。"
        )
    if st.recheck is not None and st.recheck != verdict:
        raise ValueError(
            f"本次运行**已登记**的复校结论是 {st.recheck!r}，不许改口成 "
            f"{verdict!r}——复校一次运行只做一次，允许改口等于给"
            "「洗白一次没通过的复校」开门。请换新 staging + 新 seed 重拉。"
        )
    st.recheck = verdict


def commit_stock(stg_fd: int, manifest: dict, *, ledger: RunLedger,
                 recovery: "RecoveryScope | None" = None) -> dict:
    """**per-stock 提交**（每只股一次，R37-F1）。返回真正写出去的那份。

    ⚠️⚠️ **本函数在写入路径上够不到生命周期三字段，且这是无条件的**：
    `stopped_reason` / `stopped_reason_secondary` / `fetch_fatal_error`
    一律从**磁盘上那份 manifest** 读出来、原样写回去；调用方内存里是什么、
    甚至调用方想传什么，都进不来——**这个参数根本不存在**。

    spec §9-3s 要求「per-stock 提交一律不动这两个字段，**使规则可机械检验**」。
    ⚠️ 初版做法是「调用方在启动时取一次快照、每次提交传进来」，本片曾把
    「调用方可能传一份伪造的快照」登记为**已接受的残留** —— codex R6 那轮
    实测证明它是**活的洞**：传一个空快照就能把磁盘上的警报抹掉，
    而 fatal 是 pilot 的 fail-closed 判据。
    **教训：登记为「已接受残留」的东西，下一轮要重新问一次它还能不能被利用。**

    代价是每股多一次 manifest 读回——与同一次提交里的 `F_FULLFSYNC` 相比可以忽略。
    """
    if not isinstance(ledger, RunLedger) or ledger not in _LEDGER_STATE:
        # 类型对不够：还必须在**模块内的运行注册表**里登记过
        # ——否则 `object.__new__(RunLedger)` 造一个就能冒充。
        # ⚠️ 本条**造不出专属档**（如实登记）：真正的防线在句柄的**属性访问**上
        # （每次读取都查注册表，绕不过去），入口这道只是早失败的冗余。
        # 这是本片少数几个「冗余是设计使然、不是遗漏」的地方。
        raise ValueError(
            f"ledger 必须是 begin_run() 产出的 RunLedger，收到 {type(ledger).__name__}")
    if recovery is not None and not isinstance(recovery, RecoveryScope):
        raise ValueError(
            f"recovery 必须是 RecoveryScope 或 None，收到 {recovery!r}"
            "——它是「这次回退是有意的、范围到此为止」的唯一声明")
    # ⚠️⚠️ **复校必须发生在任何 per-stock 提交之前**（spec P2-F3，codex R16 [high]）。
    # 判在收尾是**收口点位置错了**：那时进度早已逐只落盘，抛异常收不回来。
    st = ledger._state()
    if st.fatal_published:
        raise ManifestInvalidError(
            "本次运行已经**自己发布**过 fetch_fatal_error —— spec 把撞逃逸定为"
            "**整次 fetch 致命**（不记 failure、不加 attempts、不推进 cursor、rc≠0），"
            "此后一只股都不许再提交。请修好之后重跑，由新的一轮继续。"
        )
    if st.start_needs_recheck and st.recheck != "passed":
        raise ManifestInvalidError(
            "这棵 staging 的账本带着「必须做 staging 全量复校才能解除」的记录，"
            f"而本次运行的复校结论是 {st.recheck!r} —— 复校通过之前**一只股都不许提交**。"
            "spec P2-F3 要求复校失败的那一轮不得推进 cursor、不得新增 "
            "files/pool_order；只有把复校放在所有提交之前，这条要求才兑现得了"
            "（提交完再拒绝，已经写进磁盘的进度收不回来）。"
        )
    on_disk, previous = _expect_from_disk(stg_fd, ledger)
    payload = {k: v for k, v in manifest.items() if k not in LIFECYCLE_KEYS}
    payload.update(on_disk)
    # ⚠️ **per-stock 提交时这两个字段的取值写死**（spec §4.5:785，O4-F2）。
    # 不写死的后果：一棵干净 staging 用 --skip-existing-verify 起跑，一次
    # 「只失败、没新增文件」的提交会把上一次的 `full` 存根**原样写回**
    # （它结构上仍然合法）；若进程随后崩在收尾之前，磁盘上那份账本就一直
    # **声称自己是 full 级**，而本次运行明确跳过了校验（codex R11 [medium]）。
    # 定级是**收尾提交**的事，且必须在收尾复校跑完之后。
    payload["source_verification"] = "partial"
    payload["source_verification_evidence"] = {"level": "partial", "passes": []}
    _carry_forward_persisted_keys(previous, payload)
    # 唯一正当的回退理由是崩溃恢复（spec §4.4 恢复第③档），且必须**声明范围**；
    # 范围之外的一切不变量照旧强制。
    _require_no_progress_rollback(previous, payload, "per-stock 提交", recovery)
    ledger._advance(_write_manifest(stg_fd, payload), on_disk, payload)
    return payload


# ── 收尾生命周期决策表（S2b Task 17）──────────────────────────

_FINAL_KINDS = frozenset({"clean", "max_bytes", "escape"})
_RECHECK_VERDICTS = (None, "passed", "failed")


class SkipVerifyWithEscapeError(Exception):
    """`--skip-existing-verify` 撞上「manifest 带 escape 记录」——拒绝启动（P2-F3）。

    **不拒的具体后果**：第 1 次带 flag 跑清掉 fatal、标 `partial`（看似安全），
    第 2 次不带 flag 跑时收尾复校**只重算「源」、从不回读 staging** →
    **一棵被证明动过、且从未被复校过的 staging 拿到了出货级 `full` 标签**。
    """


def _validated_escape(escape: object) -> dict:
    """校验 escape 证据的**四字段外延 + 每个字段的类型与取值**，返回一份新 dict。

    ⚠️ **连类型一起校验**：只查「非空」时 `relative_path=123` 会一路通过构造、
    通过决策表，直到被写上磁盘，才在**下一次读**时被判非法——又一次
    「一个合规的写者产出的 manifest 被读者判非法」（R94-F2 家族）。
    """
    if not isinstance(escape, Mapping):
        raise ValueError(f"escape 必须是映射，收到 {type(escape).__name__}")
    ev = dict(escape)
    if set(ev) != set(FATAL_FIELDS):
        raise ValueError(
            f"escape 的键必须恰为 {list(FATAL_FIELDS)}，收到 {sorted(ev)}"
            "——多余的键会被原样写进 manifest 而读侧不认识它"
        )
    if not isinstance(ev["kind"], str) or ev["kind"] not in FATAL_KINDS:
        raise ValueError(
            f"escape.kind 必须是 {sorted(FATAL_KINDS)} 之一，收到 {ev['kind']!r}")
    if not isinstance(ev["errno"], str) or ev["errno"] not in FATAL_ERRNOS:
        raise ValueError(
            f"escape.errno 必须是 {sorted(FATAL_ERRNOS)} 之一，收到 {ev['errno']!r}")
    for name in ("relative_path", "component"):
        if not isinstance(ev[name], str) or not ev[name]:
            raise ValueError(f"escape.{name} 必须是非空字符串，收到 {ev[name]!r}")
    return ev


@dataclass(frozen=True)
class FinalOutcome:
    """本次运行的**收尾事件**。用三个工厂函数构造，非法组合在构造期就被排除。

    - `kind`：`clean`（正常跑完）/ `max_bytes`（干净的配额触顶）/ `escape`（撞了逃逸）
    - `escape`：`kind == "escape"` 时的四字段
    - `revisited_fatal_path`：本次是否**重新遍历过**上次 fatal 所指的那条路径（前提①）
    - `staging_recheck`：`staging_path_escape` 另加的全量复校结果（前提②），
      `"passed"` / `"failed"` / `None`（未做）

    ⚠️ `kind` 在 `__post_init__` 里校验：本类是公开的 dataclass，可以被直接构造，
    不校验的话 `FinalOutcome(kind="whatever")` 会一路落到「上次没 fatal → 返回 {}」
    那一支，被**静默当成干净跑完**。
    """
    kind: str
    escape: dict | None = None
    revisited_fatal_path: bool = False
    staging_recheck: str | None = None

    def __post_init__(self) -> None:
        # ⚠️ **全部不变量都落在这里，不落在三个工厂里**（codex R1 [high]）：
        # 本类是公开的 frozen dataclass，可以被**直接构造**——守卫立在工厂而
        # 对象能绕过工厂构造，等于守卫不存在（本仓已栽过同形态：守卫立在调用方
        # 而 `open()` 发生在被调方）。
        if not isinstance(self.kind, str) or self.kind not in _FINAL_KINDS:
            raise ValueError(
                f"FinalOutcome.kind 必须是 {sorted(_FINAL_KINDS)} 之一，"
                f"收到 {self.kind!r}"
            )
        # ⚠️ 必须是**真正的 bool**：非空字符串是真值，`clean_finish(
        # revisited_fatal_path="false")` 会被当成「重走过那条路径」，
        # **无凭无据就把 fatal 清掉**。命令行/配置传进来的 "false" 正是这个形态。
        if not isinstance(self.revisited_fatal_path, bool):
            raise ValueError(
                "revisited_fatal_path 必须是 True/False（真正的布尔值），"
                f"收到 {self.revisited_fatal_path!r}"
                "——它是「已证明受影响的路径确实干净」的唯一凭据，"
                "非空字符串等真值会让 fatal 被无凭无据地清除"
            )
        if self.staging_recheck not in _RECHECK_VERDICTS:
            raise ValueError(
                "staging_recheck 只能是 None/'passed'/'failed'，"
                f"收到 {self.staging_recheck!r}"
            )
        # ⚠️ **只有 clean 这一支会去清除/保留 fatal，前提②才被消费**：
        # `max_bytes` 一律保留（O4-F1）、`escape` 一律覆盖为本次的，两者都不看它。
        # 两个工厂函数因此不收这个参数（「让它不可表达」），但本类是**公开的**
        # dataclass、可以被直接构造 —— 守卫立在工厂等于守卫不存在（R1 的教训）。
        # 不挡住时能造出一个「决策表永远不看、而 commit_final 会拿去比对」的取值。
        if self.kind != "clean" and self.staging_recheck is not None:
            raise ValueError(
                f"kind={self.kind!r} 的结局不得携带 staging_recheck="
                f"{self.staging_recheck!r} —— 决策表对这一支根本不看它，"
                "可传而被静默忽略是**安静的那种错**"
            )
        # 跨字段配对：kind == "escape" ⟺ 带着证据。
        if (self.kind == "escape") != (self.escape is not None):
            raise ValueError(
                f"kind={self.kind!r} 与 escape={self.escape!r} 不配对："
                "escape 事件必须带四字段证据，非 escape 事件不得携带证据"
                "（否则那份证据被静默忽略）"
            )
        if self.escape is not None:
            ev = _validated_escape(self.escape)
            # 冻结：dict 塞进 frozen dataclass 仍可变，构造期校验会被
            # 「构造完再改一下」绕过（本机复现改成了 bogus）。
            object.__setattr__(self, "escape", MappingProxyType(ev))


def clean_finish(*, revisited_fatal_path: bool = False,
                 staging_recheck: str | None = None) -> FinalOutcome:
    """本次正常跑完整批。"""
    return FinalOutcome(kind="clean", revisited_fatal_path=revisited_fatal_path,
                        staging_recheck=staging_recheck)


def max_bytes_stop() -> FinalOutcome:
    """干净的 `--max-bytes` 触顶（R44-F2：**终止条件，不是这只股的失败**）。

    ⚠️ **本函数不收「清除前提」两个参数**：决策表对 max_bytes 这一支根本不看它们
    （O4-F1：容量停止一律不清除、escape 的 `stopped_reason` 一律不得被覆盖）。
    可传而被静默忽略是**安静的那种错**，故让它**不可表达**。
    """
    return FinalOutcome(kind="max_bytes")


def escape_stop(*, kind: str, relative_path: str, component: str,
                errno: str) -> FinalOutcome:
    """本次撞了逃逸（源树或 staging 树的路径分量被换）。

    ⚠️ 校验本身在 `FinalOutcome.__post_init__` 里，本函数只是个便利入口——
    **直接构造的那条路必须同样安全**。
    """
    return FinalOutcome(kind="escape", escape={
        "kind": kind, "relative_path": relative_path,
        "component": component, "errno": errno,
    })


def _needs_staging_recheck(reason: object, fatal: object) -> bool:
    """这个既有状态要清除，是否**必须**先做一次 staging 全量复校（前提②）？

    两种状态都要：`fetch_fatal_error.kind == "staging_path_escape"`（P2-F3 原文），
    以及 `stopped_reason == "staging_recheck_failed"`（上次复校就没通过）。
    **后者的 `kind` 可以是 `source_path_escape`**（O4-F3 的解耦），
    所以只按 `kind` 判会漏掉它——一次 source 逃逸就能把「上次复校没通过」
    这个结论抹掉。
    """
    if fatal is None:
        return False
    kind = fatal.get("kind") if isinstance(fatal, dict) else None
    return kind == "staging_path_escape" or reason == "staging_recheck_failed"


def resolve_final_lifecycle(manifest: dict, outcome: FinalOutcome) -> dict:
    """**收尾提交**时三个生命周期字段的完整新值（纯函数；缺席的键表示该字段应被删除）。

    ⚠️ **两种朴素做法都错**（R95-F2）：**就地合并式更新**会让操作者修好树、
    重跑成功之后，陈旧 fatal 永远留着、**pilot 永远拒绝启动**；**启动即清除**
    则会在「重试崩在中途」时**抹掉唯一的持久证据**，下一次看到的是一份
    看起来干净、实则来自被污染源树的 staging。把清除与「本次已干净收尾」绑进
    **同一次原子提交**，两种坏结局都不可表达。

    ⚠️ **清除的谓词不是「本次没撞 escape」，而是「已证明受影响的路径确实干净」**
    （O2-F7）：上次 `staging_path_escape` 记了 56 只股，操作者重建目录后重跑，
    新股走**新建目录**全部成功、收尾复校只对**源**重算 sha256（从不回读那 56 只股）
    ——「本次没撞」成立，而什么都没被证明干净。

    ⚠️ **`max_bytes` 绝不许洗白 escape**（O4-F1）：Run2 的累计字节含 Run1，
    触顶几乎必然；把 `stopped_reason` 改写成 `max_bytes` 会让 pilot 放行那批
    从未被复校过的股——**一次被证明破坏的信任边界被一次容量停止洗白成合法凭据**。
    """
    prev_fatal = manifest.get("fetch_fatal_error")
    prev_reason = manifest.get("stopped_reason")

    # 输入自相矛盾就当场拒绝，绝不安静地产出一份读侧判非法的 manifest：
    # 读侧明写「有 fetch_fatal_error 却没有 stopped_reason——写侧只落了一半」。
    # 真实路径上 manifest 来自 read_manifest（配对已被保证），故不会误杀。
    if prev_fatal is not None and prev_reason is None:
        raise ManifestInvalidError(
            "输入 manifest 有 fetch_fatal_error 却没有 stopped_reason——"
            "读侧明令这是非法配对，决策表拒绝在它之上产出新状态"
        )
    # ⚠️ **反方向此前没查**（Opus 第 5 轮 [low]）：`_require_escape_pairing` 在
    # `fatal is None` 时直接返回，于是「reason 属于 REASONS_REQUIRING_FATAL 却
    # 没有 fatal」掉进下面分支②被当成「上次没有 fatal」，返回 `{}` ——
    # **静默丢掉一个「已证明复校没通过」的结论**。走 `commit_final` 到不了这里
    # （磁盘那份先过读侧），所以这纯粹是本 docstring 自称提供的那层纵深防御没做全。
    if prev_fatal is None and prev_reason in REASONS_REQUIRING_FATAL:
        raise ManifestInvalidError(
            f"输入 manifest 的 stopped_reason = {prev_reason!r} 属于 "
            f"{sorted(REASONS_REQUIRING_FATAL)}，却**没有 fetch_fatal_error**——"
            "读侧明令这是非法配对，决策表拒绝在它之上产出新状态"
        )
    # 纵深防御：本函数是**公开的纯函数**，可以不经 read_manifest 直接调用。
    # 读侧堵上之后它仍要自己 fail closed，而不是「把不匹配的当成 source escape
    # 处理」——那正是 codex R2 [high] 被利用的那条路径。
    _require_escape_pairing(prev_reason, prev_fatal)

    # ① 本次撞了 escape → 覆盖为本次的（secondary 清掉）。
    #
    # ⚠️⚠️ **但覆盖只许「同级或升级」，绝不许降级**（codex R3 [high]）：
    # spec 原文写「本次又撞 escape → 覆盖上一次的」，而 O4-F1 同时又说
    # `fetch_fatal_error` 是**粘性的信任状态**。两句话在「staging → source」
    # 这个次序上直接冲突——清除 staging 逃逸要过**两道**前提（另加全量复校，
    # P2-F3），清除 source 逃逸只要一道；用后者覆盖前者等于把那道门取消了。
    #
    # **本机三次运行端到端复现**：Run1 撞 staging → Run2 撞 source（staging
    # 证据没了）→ Run3 干净跑完、重走过源路径、**没做 staging 全量复校**
    # → fatal 被清除。一棵从未证明恢复过的 staging 拿到了干净账本。
    #
    # 严格性的定义 = 「清除它是否需要 staging 全量复校」，故要同时看
    # `kind` 与 `stopped_reason`：`staging_recheck_failed` 的 kind 可以是
    # `source_path_escape`（O4-F3 解耦），只按 kind 判会漏掉它。
    #
    # ⚠️ **已接受的残留**：本次这一起 source 逃逸不会被记进 manifest
    # （schema 里只有一条 `fetch_fatal_error`，不引入新字段）。本次运行的失败
    # 由 S4/S5 在**运行级**输出（rc≠0 + 报告）承担；manifest 保留的是**更难
    # 清除的那个结论**，方向是 fail-closed。
    if outcome.kind == "escape":
        assert outcome.escape is not None
        new_kind = outcome.escape["kind"]
        if new_kind == "source_path_escape" and _needs_staging_recheck(
                prev_reason, prev_fatal):
            return {"stopped_reason": prev_reason,
                    "fetch_fatal_error": copy.deepcopy(prev_fatal)}
        return {"stopped_reason": new_kind,
                "fetch_fatal_error": dict(outcome.escape)}

    # ② 上次没有 fatal → 只写本次的停止原因
    if prev_fatal is None:
        return {"stopped_reason": "max_bytes"} if outcome.kind == "max_bytes" else {}

    # ③ 上次有 fatal，本次是 max_bytes 触顶 → 一律保留，只加诊断附注（O4-F1）。
    if outcome.kind == "max_bytes":
        return {"fetch_fatal_error": copy.deepcopy(prev_fatal),
                "stopped_reason": prev_reason,
                "stopped_reason_secondary": "max_bytes"}

    # ④ 上次有 fatal，本次干净跑完 —— 清除与否取决于「有没有证明干净」
    #
    # ⚠️ **「本次全量复校失败」必须最先判**（codex R5 [high]）：它是**本次运行的
    # 事实**，与「有没有重走过上次出事的那条路」无关。前提①管的是「能不能清除」，
    # 不该挡住「记录一个新的失败」。排在前提①早退之后时：
    # `clean_finish(revisited_fatal_path=False, staging_recheck="failed")` 会原样
    # 保留旧的 source reason、**把「复校失败」这个事实丢掉**，下一次运行重走过
    # 源路径又不做复校，就只看见一个 source 逃逸 → 两个信号全清。
    # ⭐ 这条分支的次序被改过三次（D5 → D16 → 本次），每次都只挪了一格 ——
    #    正是「结构性改动后要重核原来成立的东西」那一类。
    if outcome.staging_recheck == "failed":
        return {"fetch_fatal_error": copy.deepcopy(prev_fatal),
                "stopped_reason": "staging_recheck_failed"}

    if not outcome.revisited_fatal_path:                    # 前提① 不满足
        return {"fetch_fatal_error": copy.deepcopy(prev_fatal),
                "stopped_reason": prev_reason}

    # ⚠️ **必须用 `_needs_staging_recheck`，不能只看 `kind`**（codex R4 [high]）：
    # `staging_recheck_failed` 同样是「必须做过全量复校才能清」的状态，而它的
    # `kind` 可以是 `source_path_escape`（O4-F3 解耦，且本函数上面那一支正是
    # 这么产出的）。只看 kind 的话，「上次复校没通过」这个结论会在下一次
    # 不做任何复校的干净运行里被无条件抹掉。
    #
    # ⚠️ 这是**我自己在 R3 那轮抽出这个 helper 却漏了这个调用点**造成的：
    # 同一件事判在两处、改了一处忘了另一处。已配机械守卫
    # `test_only_one_place_decides_whether_a_staging_recheck_is_required`
    # 钉住「只许在 `_needs_staging_recheck` 里判定」。
    if _needs_staging_recheck(prev_reason, prev_fatal):
        # 前提②（无条件，不受任何 flag 影响，P2-F3）
        if outcome.staging_recheck is None:
            raise SkipVerifyWithEscapeError(
                "这棵 staging 的 manifest 里带着 staging_path_escape 记录，"
                "而本次跳过了既有文件复校。两者互斥：跳过复校就无法证明那些"
                "已记录的文件还在、还是原来的字节。请去掉 --skip-existing-verify "
                "重跑，或换新 staging + 新 seed 重拉。"
            )

    # 已证明干净 → 清除（source_path_escape 只需前提①）
    return {}


def commit_final(stg_fd: int, manifest: dict, *, outcome: FinalOutcome,
                 ledger: RunLedger) -> dict:
    """**收尾提交** —— 全流程中**唯一**能写入或清除生命周期三字段的入口
    （R95-F2）。返回真正写出去的那份。

    与 `commit_stock` 的差别不在「记不记得改」，而在**能不能改**：
    per-stock 提交把那三个键从磁盘读出来原样写回，本函数把它们剥掉再回填
    **决策表的输出**。两者都不从调用方内存里那份 manifest 直接取值。

    `ledger` 是 `begin_run()` 产出的运行凭据（记着「有没有账本」与字节指纹），
    作为「磁盘上应该是什么」的**预期**；与磁盘不匹配（含消失、被替换、
    引导态里凭空出现）一律 fail closed，且每次提交成功后**自动更新**。

    ⚠️ **`resolve_final_lifecycle` 必须在任何写入之前求值**：它可能抛
    `SkipVerifyWithEscapeError`（P2-F3），而那一档的规定是「拒绝启动、
    一个字节都不写」；也可能抛 `ManifestInvalidError`（输入自相矛盾）。
    """
    # ⚠️⚠️ **「上一次的状态」必须来自磁盘，不能来自调用方内存里那份 manifest**
    # （codex R5 [high]）：本函数是**唯一能清除证据的入口**。
    # `commit_stock` 早就用启动快照挡住了同一件事（调用方污染内存），
    # 而当时只修了一半——本机复现：磁盘上有未解除的 staging 警报、内存里那份
    # 「不小心」把三个键弄没了 → 决策表看见「上次没有 fatal」→ 产出空生命周期
    # → **发布了一份干净账本**，而落盘前的读侧校验抓不到（它结构上完全合法）。
    #
    # `read_manifest` 返回 `None` 是**合法**的引导态（首份 manifest 还没提交）；
    # 它抛异常则说明磁盘上那份账本已经坏了/被换了 —— 此时拒绝发布是 fail-closed。
    if not isinstance(ledger, RunLedger) or ledger not in _LEDGER_STATE:
        raise ValueError(
            f"ledger 必须是 begin_run() 产出的 RunLedger，收到 {type(ledger).__name__}")
    # ⚠️⚠️ **收尾上报的复校结论必须等于本次运行登记过的那一个**（codex R16 [high]）。
    # 不查这一条时，`attest_staging_recheck(passed=False)` 把 per-stock 提交挡住，
    # 收尾却上报 `"passed"` —— 一次**没通过**的复校照样把 fatal 清掉，闸白立。
    # 反方向同样拦：从没登记过却上报结论 —— 模块自己那份记录才是唯一真相，
    # 调用方口头说的不算（这与 per-stock 提交「生命周期三字段只从磁盘读」同源）。
    st = ledger._state()
    attested = st.recheck
    if attested == "failed":
        # 复校**已被证明失败**：这一轮只许发布 P2-F3 那个具名结局。
        # 放开非 clean 结局之后若不加这条，`max_bytes_stop()` 会把「复校没过」
        # 整个丢掉——盘上只剩上一轮的 reason 加一条 max_bytes 附注。
        if outcome.kind != "clean" or outcome.staging_recheck != "failed":
            raise ManifestInvalidError(
                "本次运行登记的复校结论是**失败**，那么收尾只能发布 P2-F3 "
                f"规定的具名结局（staging_recheck_failed），而不是 "
                f"kind={outcome.kind!r} / staging_recheck="
                f"{outcome.staging_recheck!r}。"
                "一次被证明没通过的复校必须留下痕迹，不许被别的结局盖过去。"
            )
    elif outcome.kind == "clean" and outcome.staging_recheck != attested:
        # ⚠️ **只在 clean 这一支比对**（Opus 评审 [high]，本机端到端复现）：
        # 只有它会去清除/保留 fatal、真正消费前提②。写成无条件相等时，
        # `max_bytes_stop()` / `escape_stop()` 的 `staging_recheck` 恒为 None
        # （工厂不收这个参数），而一旦这一轮拉过股就必然登记过 `"passed"`
        # （per-stock 提交的复校闸逼着它登记）—— 于是**唯一合法的恢复路径**
        # 被自己堵死：Run2 修好树、复校通过、拉了股、触到 --max-bytes
        # （O4-F1 说这几乎必然），收尾当场被拒，还劝操作者把一棵几百只股的
        # 健康 staging 报废，而 O4-F1 要产出的 secondary 诊断一个字没写。
        # ⚠️ 根因是**版本化不变量漏检**：`max_bytes_stop()` 的理由「决策表这一支
        # 根本不看它们」对 `resolve_final_lifecycle` 成立，而 R16 给
        # `outcome.staging_recheck` **加了第二个消费者**，那句理由没被重核。
        raise ManifestInvalidError(
            f"收尾上报的 staging 复校结论是 {outcome.staging_recheck!r}，"
            f"而本次运行**登记**的是 {attested!r} —— 两者必须一致。"
            "复校结论请在做完复校后用 attest_staging_recheck() 登记；"
            "上报一个没登记过的结论等于让调用方自己给自己发凭据。"
        )
    # ⚠️⚠️ **磁盘是「当前真相」，启动快照是「预期」，两者必须对上**（codex R6 [high]）。
    # 只信磁盘时，「运行中把账本删掉」就成了新的洗白入口。判定与 per-stock 提交
    # **共用** `_expect_from_disk`——同一件事绝不判在两处（S2-F15 的教训）。
    on_disk, previous = _expect_from_disk(stg_fd, ledger)

    basis = {k: v for k, v in manifest.items() if k not in LIFECYCLE_KEYS}
    _carry_forward_persisted_keys(previous, basis)
    basis.update(on_disk)

    new_lifecycle = resolve_final_lifecycle(basis, outcome)   # ← 可能抛，必须在写之前
    # ⚠️⚠️ **本轮自己发布的 fatal 不许在同一轮里清掉**（Opus 第 5 轮 [high]，
    # 本机复现两种 kind）：任何清除前提（重走过那条路径 / 全量复校通过）都与它
    # **同一轮**产生，而 spec 把撞逃逸定为**整次 fetch 致命** —— 那一轮该以
    # rc≠0 结束，本来就不该再走到干净收尾。
    # ⚠️ 判据取「本轮发布过就不许清」而**不是**「凭据要晚于它」：后者要去追先后，
    # 而且会允许一条 spec 说不该存在的流程；让它**不可表达**更省事也更硬。
    # ⚠️ 这条**不看 kind**，所以它同时兜住了「发布 P2-F3 具名结局后又改口」那条路。
    if st.fatal_published and new_lifecycle.get("fetch_fatal_error") is None:
        raise ManifestInvalidError(
            "本次运行**自己发布**的 fetch_fatal_error 不许在同一轮里清掉 ——"
            "清除它的前提与它同一轮产生，证明不了任何东西；而撞逃逸是**整次 "
            "fetch 致命**，这一轮应当以非零码结束。请修好之后**重跑**，"
            "由新的一轮来清除它。"
        )
    payload = {k: v for k, v in basis.items() if k not in LIFECYCLE_KEYS}
    payload.update(new_lifecycle)
    # ⚠️ **复校失败的那一轮，进度必须原地未动**（spec P2-F3，codex R15 [high]）：
    # 「本次不得推进 `cursor`、不得新增 `files`/`pool_order` 条目」——
    # 否则每次重跑都继续消耗冻结宇宙与 `--max-bytes` 预算，却永远清不掉 fatal。
    # 我此前只实现了「保留 fatal + 换 stopped_reason」，漏了这半句。
    # ⚠️ 这里比的是**运行起点**（`begin_run` 时）的进度，不是上一次提交 ——
    # 否则本轮先提交几只股再收尾，比对就恒等成立了。
    # ⚠️⚠️ **闸的对象是「进度」，不是「入口」**（Opus 评审 [medium]，本机端到端复现）。
    # 此前只在「上报 `staging_recheck == "failed"`」时才冻结进度，而
    # **一次运行完全可以从不登记任何结论**：`commit_stock` 的复校闸把它挡住了，
    # `commit_final` 却照收 —— 同一份 payload，per-stock 拒、收尾收，
    # 实测 cursor 1→3、files 4→8、committed_bytes +490 万。于是一棵**已被证明
    # 动过**的 staging，只要把进度全走收尾这个入口，就能一轮一轮地把冻结宇宙与
    # `--max-bytes` 预算烧光 —— 正是 P2-F3 存在的理由。
    # ⭐ 新判据**完全涵盖**旧判据：上报 failed ⇒ 登记 failed（一致性检查）
    #   ⇒ 欠一次复校且未通过（`attest` 不欠时拒绝登记），故合并成一条。
    # ⚠️ 冻结的是**进度**而不是**提交**：这一轮仍要能把「我看见 fatal 了、
    #   我停了」或「我撞了新逃逸」记下去 —— 已配正向档。
    if (st.start_needs_recheck and st.recheck != "passed") or st.fatal_published:
        if _progress_of(payload) != st.start_progress:
            raise ManifestInvalidError(
                "这棵 staging 欠一次全量复校（账本带着必须复校才能解除的记录），"
                f"本次运行的复校结论是 {st.recheck!r}，而这一轮**推进了进度**"
                "（files / pool_order / cursor / committed_bytes 与运行起点不一致）。"
                "spec P2-F3 规定这样的一轮不得推进 cursor、不得新增 "
                "files/pool_order —— 否则每次重跑都继续消耗冻结宇宙与 --max-bytes "
                "预算，却永远清不掉 fatal。请先做完全量复校，或换新 staging + 新 seed 重拉。"
            )

    # ⚠️ **用了 `--skip-existing-verify` 的运行，收尾也不许发布 full/snapshot**
    # （spec §4.5:342：「一旦使用，manifest 与 pilot 报告都打上 partial」）。
    # 这是 R11 那条「per-stock 提交必须写死 partial」的**同族另一处**：
    # 那条管每股提交，本条管收尾 —— 一次明确跳过了校验的运行若产出自称
    # 「完整校验过」的账本，下游会据此判出货资格。
    # 采取**投影**而非拒绝：spec 的措辞是「打上 partial」，且与 per-stock 提交
    # 的处置一致；跑了几小时的一轮不该在最后一步整个失败。
    if ledger.skip_existing_verify:
        payload["source_verification"] = "partial"
        payload["source_verification_evidence"] = {"level": "partial", "passes": []}
    # 收尾提交**永远**没有正当理由回滚进度（崩溃恢复不走这个入口），故无声明可传。
    _require_no_progress_rollback(previous, payload, "收尾提交")
    ledger._advance(_write_manifest(stg_fd, payload), new_lifecycle, payload,
                    hit_escape=(outcome.kind == "escape"))
    return payload
