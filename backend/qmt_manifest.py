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

import hashlib
import json
import os
import re
import stat
from typing import Iterable

from qmt_fsroot import (
    PathDisciplineError,
    open_regular_probe,
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

    # 同理：显式 null 与键缺失是两回事，判据用键是否存在。
    secondary = payload.get("stopped_reason_secondary")
    if "stopped_reason_secondary" in payload:
        _require(secondary == "max_bytes",
                 "stopped_reason_secondary 只允许 'max_bytes'（纯人读附注："
                 "Run1 撞 escape、Run2 触顶时，escape 的 stopped_reason "
                 f"不得被覆盖），读到 {secondary!r}")


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
    """
    return {k: manifest[k] for k in LIFECYCLE_KEYS if k in manifest}


def read_manifest(stg_fd: int) -> dict | None:
    """相对 `stg_fd` **逐段无跟随**读回 manifest 并过全套读侧校验。

    返回校验通过的 manifest；**文件不存在返回 `None`**（引导态——崩在归属标记
    落盘与首份 manifest 之间，spec 明写它允许从头继续初始化，R60-F3）。
    把「不存在」与「坏了」混成一个异常，会让引导态这一档无法与畸形区分。

    抛：

    - `ManifestInvalidError` —— 不是普通文件（FIFO / 目录 / 设备）/ 空文件 /
      截断 / 不是 JSON 对象 / 超过大小上限 / 任一读侧判据不过；
    - `ManifestVersionError` —— 版本三档（**不在本层抹平成 Invalid**）；
    - `PathEscapeError` —— manifest 这一段被换成符号链接（`open_under` 逐段
      `O_NOFOLLOW` 撞 `ELOOP` / `ENOTDIR`）。**原样上浮，不降级成「manifest 畸形」**：
      那是一次**信任边界破坏**，处置是 `stopped_reason: staging_path_escape` +
      顶层 `fetch_fatal_error` + rc≠0（S4/S5 负责），报成「账本坏了」会让恢复指引
      整个走错。

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
    try:
        fd, st = open_regular_probe(stg_fd, MANIFEST_NAME, flags=os.O_RDONLY)
    except FileNotFoundError:
        return None
    try:
        if not stat.S_ISREG(st.st_mode):
            # FIFO / 目录 / 设备 / socket：**先探类型再读**。目录能被
            # O_RDONLY|O_NOFOLLOW 成功打开，随后 os.read 抛原始 IsADirectoryError；
            # FIFO 则让裸 open 永久阻塞。两者都会让这份自称 fail-closed 的校验
            # 在最该工作的时候印不出一个字的恢复指引。
            raise ManifestInvalidError(
                f"{MANIFEST_NAME} 存在但不是普通文件——拒绝。"
                "这棵 staging 已被动过，请换新 staging + 新 seed 重拉。"
            )
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
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise ManifestInvalidError(
            f"{MANIFEST_NAME} 不是合法 JSON：{e}。"
            "这通常意味着上一次写入被打断（文件被截断）。"
        ) from e
    return validate_manifest(payload)
