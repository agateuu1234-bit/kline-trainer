"""`fetch_manifest.json` —— `qmt_fetch` 写、`qmt_pilot` 读的唯一真相源。

Spec: `docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md` §4.4 + §4.5
（含文末「S2 实施轮」四条更正）。

本模块只做三件事，**不碰网络、不碰拷贝、不碰数据库**：
1. 定义 manifest 的结构与版本；
2. 读侧**闭合**校验（fail-closed，绝不「尽力而为地解析」）——纯函数，零文件系统；
3. 两个提交入口 + `stopped_reason` / `fetch_fatal_error` 的生命周期决策表。

⚠️ **为什么读侧校验必须闭合**：一个被截断的 manifest 解析出来往往仍是合法 JSON
的**前缀片段**，静默消费它 = 把 manifest 损坏伪装成「候选就这么多」，最终产出一份
**会撒谎的 pilot 报告**（R1-F4）。
"""
from __future__ import annotations

import hashlib
import json
import re
from typing import Iterable

from qmt_fsroot import PathDisciplineError, split_relative_components
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

# 生命周期三字段：**只有收尾提交能动它们**，per-stock 提交在写入路径上够不到
# （R95-F2 + spec §9-3s「使规则可机械检验」）。
LIFECYCLE_KEYS = frozenset({
    "stopped_reason", "stopped_reason_secondary", "fetch_fatal_error",
})

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_STOCK_CODE_RE = re.compile(r"^\d+\.(SH|SZ|BJ)$")

# `fetch_fatal_error.errno` 的闭合枚举：仅两种能触发「留在挂载点内」的逃逸
# 判据的系统调用错误码（R94-F2）。
FATAL_ERRNOS = frozenset({"ELOOP", "ENOTDIR"})

# `fetch_fatal_error` 的必需字段外延——**四字段**，不是三字段（R94-F2）：
# 写侧曾只写三字段、读侧要四字段，会让一个合规的写者产出的 manifest
# 被读者判非法。
FATAL_FIELDS = ("kind", "relative_path", "component", "errno")


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
            "这通常意味着 manifest 被手工编辑过或写坏了——请换新 staging + 新 seed 重拉。"
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
        _require(fatal["kind"] in FATAL_KINDS,
                 f"fetch_fatal_error.kind 必须是 {sorted(FATAL_KINDS)} 之一，"
                 f"读到 {fatal['kind']!r}")
        _require_nonempty_str(fatal["relative_path"], "fetch_fatal_error.relative_path")
        _require_nonempty_str(fatal["component"], "fetch_fatal_error.component")
        _require(fatal["errno"] in FATAL_ERRNOS,
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
    return payload
