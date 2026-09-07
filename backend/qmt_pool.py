# backend/qmt_pool.py
"""QMT 4b 切片 S3：`export_log` 预筛 + 分层 seeded 储备池（纯函数）。

Spec: `2026-07-27-qmt-plan4b-fetch-design.md` §4.2 / §4.3 / §4.4。

本模块**不碰文件系统、不碰数据库、不做网络 IO**（与 S2a 的读侧校验同规格）：
上接 `qmt_ingest.parse_export_log` 的产物，下出「冻结的分层候选名单」与
「本批要尝试的槽位」，交给 S4 的拷贝引擎去执行。落盘是 S2b `qmt_manifest` 的事。
"""
from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Iterable, Mapping

from qmt_ingest import ExportLogEntry
from qmt_manifest import MARKETS, STOCK_CODE_RE, ManifestInvalidError
from qmt_normalize import QmtSchemaError, trading_date

# §4.3 的两条月数下界。
# 39 = 31 + 8：`generate_training_sets.py:128` 的 `if n < 31 + months`。
# 8：训练窗口需要的完整月数。
MIN_DAILY_MONTHS = 39
MIN_1M_MONTHS = 8


def month_span(first_epoch: int, last_epoch: int) -> int:
    """`[first, last]` 跨越的**不同自然月数**（含两端），按 Asia/Shanghai。

    ⚠️ **必须经 `trading_date()`**：入参是 **Unix 秒**（`qmt_ingest` 已把 QMT 的
    打包整数转过一道，见 `qmt_ingest.py:87`），而日线时间戳恰好落在当地 00:00
    = 前一天 16:00 UTC。按 UTC 算，任何从某月 1 日开始的日线都会被算进上个月，
    跨度凭空多一 —— **不抛异常、只是安静地把边界附近的股多留或多剔**，
    而三条预筛判据全是边界判据。`trading_date` 的 docstring 也写死了
    「所有日期分组/比对的唯一入口，禁 UTC/naive」。
    """
    if first_epoch is None or last_epoch is None:
        # 调用方没按次序调用（status 门必须先跑）—— 这是**代码**的问题，不是数据的问题。
        raise ValueError(
            "month_span 收到空时间戳 —— `status != \"ok\"` 的 export_log 行没有"
            "有效时间戳（qmt_ingest 刻意保留条目并置 None）。调用方必须**先过**"
            "status 门再算月数。"
        )
    if first_epoch > last_epoch:
        # 首尾时间戳被写反了，这是 **export_log 的内容**不合规 —— 与 parse_export_log
        # 对认不出的 period / 重复键的处置同族（spec §5），S5 的 CLI 据此映射 rc=2。
        raise QmtSchemaError(
            f"export_log 的时间戳区间是反的：first={first_epoch} > last={last_epoch}")
    a = trading_date(first_epoch)
    b = trading_date(last_epoch)
    return (b.year - a.year) * 12 + (b.month - a.month) + 1


@dataclass(frozen=True)
class PrefilterStats:
    """§4.3 的预筛统计 ——「关于数据源的第一份真实观测」，随 manifest 落盘。

    四个 `rejected_*` 之间**互斥且穷尽**：每只被剔的股按 `prefilter` 的判定次序
    恰好归因到一条上，`total == passed + 四条之和` 是不变量。
    """
    total: int
    rejected_incomplete: int
    rejected_status: int
    rejected_daily_span: int
    rejected_1m_span: int
    passed: int

    def as_manifest_field(self) -> dict:
        """写进 manifest 的 `prefilter_stats`（**非必需**顶层键，不 bump 版本）。"""
        return {"total": self.total,
                "rejected_incomplete": self.rejected_incomplete,
                "rejected_status": self.rejected_status,
                "rejected_daily_span": self.rejected_daily_span,
                "rejected_1m_span": self.rejected_1m_span,
                "passed": self.passed}


def prefilter(entries: dict[tuple[str, str], ExportLogEntry]
              ) -> tuple[list[str], PrefilterStats]:
    """§4.3 的三条判据（外加一条「两个周期缺一不可」）。

    返回 `(codes, stats)`，`codes` **按字典序升序**。

    ⚠️ **判定次序是判据的一部分**：`status != "ok"` 的行没有有效时间戳
    （真实导出里 `301583.SZ` 的 `first_time`/`last_time` 都是空的，`qmt_ingest`
    保留条目并置 `None`），先算月跨度会当场炸。**先看 status，再碰时间戳** ——
    这正是 `qmt_ingest` 自己在真实数据上栽过的那一跤。

    ⚠️ **升序返回不是可有可无的整洁**：下游 `freeze_universe` 对它做 seeded 打乱，
    而打乱结果依赖入参**顺序**；dict 的迭代顺序就是 `export_log.csv` 的行序。
    不排序的话，「同 seed → 同一个宇宙」会悄悄依赖 QMT 导出时的行序。

    ⚠️ **三条判据都是保守下界，不替代真门**：真门照样在 pilot 里跑。实测在当前
    这份导出上只筛掉 8.4%（S3-F2），实现者不得据此假定宇宙会被大幅缩小。
    """
    by_code: dict[str, dict[str, ExportLogEntry]] = {}
    for (code, period), ent in entries.items():
        by_code.setdefault(code, {})[period] = ent

    passed: list[str] = []
    n_incomplete = n_status = n_daily = n_1m = 0

    for code in sorted(by_code):
        per = by_code[code]
        e_1m, e_daily = per.get("1m"), per.get("daily")
        if e_1m is None or e_daily is None:
            n_incomplete += 1
        elif e_1m.status != "ok" or e_daily.status != "ok":
            n_status += 1
        elif month_span(e_daily.first_time, e_daily.last_time) < MIN_DAILY_MONTHS:
            n_daily += 1
        elif month_span(e_1m.first_time, e_1m.last_time) < MIN_1M_MONTHS:
            n_1m += 1
        else:
            passed.append(code)

    return passed, PrefilterStats(
        total=len(by_code), rejected_incomplete=n_incomplete,
        rejected_status=n_status, rejected_daily_span=n_daily,
        rejected_1m_span=n_1m, passed=len(passed))


def freeze_universe(codes: Iterable[str], *, seed: str) -> dict[str, list[str]]:
    """§4.4：按 code 后缀分三层，各层内**独立** seeded 打乱，产出冻结名单。

    ⚠️ **各层用各自的种子** `f"{seed}:{market}"`：spec 明写「改动某层配额不会扰动
    其他层的顺序」。共用一个 rng 的话，SH 层多一只股就会把 SZ/BJ 的整个顺序推移，
    而逐层增量补拉的正确性完全建立在「其他层顺序不变」上 —— `cursor[SZ]` 还指着
    老位置，指向的却已是另一只股。

    ⚠️ **自己再排一次序**：`random.shuffle` 的输出取决于入参顺序，而入参往往来自
    dict 的迭代顺序（= `export_log.csv` 的行序）。不排序的话，「同 seed → 同一个
    宇宙」会悄悄依赖 QMT 导出时的行序。

    ⚠️ **坏码与重复当场拒**：这份名单是补拉游标的唯一锚点。放过去的话，整棵
    staging 要到读侧校验才被判死，而那时已经离病因十万八千里；重复更狠 ——
    读侧 `_validate_source_snapshot` **不查层内唯一性**，两个下标指向同一只股
    会一路活到 `pool_order` 的锚点校验处才爆。
    """
    layers: dict[str, list[str]] = {mk: [] for mk in MARKETS}
    seen: set[str] = set()
    for code in sorted(codes):
        if not isinstance(code, str) or STOCK_CODE_RE.match(code) is None:
            raise QmtSchemaError(
                f"freeze_universe 收到不合法的股票代码 {code!r}——"
                "`export_log` 的标识列可能被污染（`qmt_ingest._norm_code` 对认不出的"
                "值是原样返回的）。冻结名单是补拉游标的唯一锚点，坏码不许进。")
        if code in seen:
            raise QmtSchemaError(
                f"freeze_universe 收到重复的股票代码 {code!r}——"
                "同一只股占两个 universe_idx 会让锚点语义当场失效。")
        seen.add(code)
        layers[code.rsplit(".", 1)[1]].append(code)

    for mk in MARKETS:
        random.Random(f"{seed}:{mk}").shuffle(layers[mk])
    return layers


# §4.4 的默认配额。约 400 只 ≈ 1.7 GiB（2026-08-23 实测单股两文件均值约 4.6 MB）。
# BJ 给 120 而不按地板（≥8）等比缩到约 32：BJ 的**成功率**才是稀缺资源，
# 详见 spec §4.4 与 S3-F1。
DEFAULT_QUOTA = {"SH": 120, "SZ": 160, "BJ": 120}


@dataclass(frozen=True)
class Slot:
    """一个「要尝试的槽位」= 冻结名单里的一个位置。

    `universe_idx` 随槽位走到底（进 `pool_order` / `failures`），
    因为它才是 pilot 的消费顺序锚点（R12-F1）。
    """
    code: str
    market: str
    universe_idx: int


def fresh_slots(universe: dict, cursor: dict, quota: dict) -> list[Slot]:
    """从各层游标续到该层的**累计目标**（S3-F3）。

    区间 `[cursor[mk], min(quota[mk], len(universe[mk])))`。
    `cursor >= quota` 时该层返回空 —— **用同样的配额重跑不会再拉一批**。

    ⚠️ **必须自己再查一次游标边界**：读侧 `_validate_cursor` 已经查过，但那是
    「从磁盘读回来」这条路；本函数是**纯内存**接口，S4 完全可能在崩溃恢复里
    改完 `cursor` 直接调它。而游标为负时 `range(-2, n)` 会产出 `universe[-2]`
    这样的**尾部**元素 —— 不崩溃、不报错，只是给出一份指错股的工作单。

    （`qmt_manifest._validate_cursor` 对同一字段抛的是 `ManifestInvalidError`，
    因为那是**从磁盘读回来**那条路；到了本函数手上它已经是调用方的内存值，
    坏了就是调用方的 bug。同一字段两个族，是**两条不同的信任边界**，不是不一致。）

    ⚠️ **`quota` 同样要守，但理由不是「账本可能被改」**（最终评审 F2 更正）：
    `quota` 每次都从 `--quota`/默认值经 `resolve_quota` **现算**（spec §4.4），
    写进 manifest 只是留痕、**不读回来做决策** —— 所以它坏掉只可能是**调用方的 bug**，
    故与 `cursor` 同属族②（`ValueError`），不是族③。
    真正要守的原因是：本函数是**纯内存**入口，S4 完全可能**绕过** `resolve_quota`
    直接调它（崩溃恢复路径就没有 CLI 参数可解析）。而负配额会让 `range()` 退化成空批，
    **空批与「这一层池穷尽了」在外部完全不可区分** —— 操作者读到「没候选了」，
    真相是传进来的值坏了。
    给 `cursor` 立守卫的那条理由对 `quota` 一字不差地成立，而我当初只守了一个字段：
    这是「**按字段穷尽、而不是按判据句穷尽**」的复现。
    """
    for name, m in (("cursor", cursor), ("quota", quota)):
        missing = [mk for mk in MARKETS if mk not in m]
        if missing:
            raise ValueError(f"{name} 缺市场 {missing} —— 三层必须齐全，不许缺")

    out: list[Slot] = []
    for mk in MARKETS:
        layer = universe[mk]
        start = cursor[mk]
        if not isinstance(start, int) or isinstance(start, bool) or not 0 <= start <= len(layer):
            raise ValueError(
                f"cursor[{mk}] = {start!r} 越界（本层冻结名单长度 {len(layer)}，"
                f"合法范围 0..{len(layer)}，取到 {len(layer)} 表示该层已取遍）")
        cap = quota[mk]
        if not isinstance(cap, int) or isinstance(cap, bool) or cap < 0:
            raise ValueError(
                f"quota[{mk}] = {cap!r} 必须是非负整数 —— 负值会让本层的区间退化成"
                "空批，而**空批与「池穷尽」在外部完全不可区分**：操作者会读到一份"
                "「这一层没候选了」的结论，真相却是账本被改过。")
        for idx in range(start, min(cap, len(layer))):
            out.append(Slot(code=layer[idx], market=mk, universe_idx=idx))
    return out


def resolve_quota(overrides: "Mapping[str, int] | None" = None) -> dict[str, int]:
    """§4.4 的默认配额 + `--quota SH=..,SZ=..,BJ=..` 覆盖（命令行接线在 S5）。

    ⚠️ **配额是「累计目标」，不是「每批数量」**（S3-F3）：`quota[mk]` 表示这个
    staging 在该层**总共**要尝试到 `universe[mk]` 的第几个。合成方式见 `fresh_slots`。

    ⚠️ 返回**副本**：调用方改它不许污染下一次调用。
    """
    out = dict(DEFAULT_QUOTA)
    for mk, value in dict(overrides or {}).items():
        if mk not in MARKETS:
            raise ValueError(f"--quota 出现未知市场 {mk!r}，只认 {list(MARKETS)}")
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"--quota 的 {mk} 必须是非负整数，读到 {value!r}")
        out[mk] = value
    return out


# §4.4「有界重试」：补拉时只重试 attempts < 2 的条目（一次重试，覆盖瞬时网络故障）。
RETRY_LIMIT = 2


def retry_slots(universe: dict, failures) -> list[Slot]:
    """补拉时要先重试的槽位（§4.4 有界重试）。

    ⚠️ **读侧校验完全不碰 `failures`**（S2-F64 实测坐实：`validate_manifest` 的
    判据里没有它）。于是这份台账**从未被任何人校验过**就交到这里，而它能授权
    「再去拷一次」——一个能授权做事的结构，自己必须先被校验（R21-F3 同族）。

    ⚠️ **每一条都要过校验，包括不会被重试的那些**：把「attempts 到顶所以跳过」
    与「这条记录坏掉所以够不着」混成同一个 `continue`，两者会互相掩盖 ——
    漏站看起来就像一次正常跳过。
    """
    out: list[Slot] = []
    for i, rec in enumerate(failures):
        where = f"failures[{i}]"
        if not isinstance(rec, dict):
            raise ManifestInvalidError(f"{where} 必须是对象，读到 {type(rec).__name__}")
        for key in ("stock_code", "market", "universe_idx", "attempts"):
            if key not in rec:
                raise ManifestInvalidError(f"{where} 缺 {key}")

        code, market = rec["stock_code"], rec["market"]
        if not isinstance(code, str) or STOCK_CODE_RE.match(code) is None:
            raise ManifestInvalidError(f"{where}.stock_code 不是合法股票代码：{code!r}")
        if market not in MARKETS:
            raise ManifestInvalidError(
                f"{where}.market = {market!r} 不在 {list(MARKETS)} 内")
        if not code.endswith("." + market):
            raise ManifestInvalidError(
                f"{where}.stock_code = {code!r} 的后缀与 market {market!r} 不符")

        idx, attempts = rec["universe_idx"], rec["attempts"]
        for key, value in (("universe_idx", idx), ("attempts", attempts)):
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise ManifestInvalidError(
                    f"{where}.{key} 必须是非负整数，读到 {value!r}")

        layer = universe[market]
        if idx >= len(layer):
            raise ManifestInvalidError(
                f"{where}.universe_idx = {idx} 越界（本层冻结名单长度 {len(layer)}）")
        if layer[idx] != code:
            raise ManifestInvalidError(
                f"{where} 的锚点对不上：universe[{market}][{idx}] 是 {layer[idx]!r}，"
                f"而这条记录自称是 {code!r}。这份 manifest 被编辑过或来自另一次 fetch。")

        if attempts < RETRY_LIMIT:
            out.append(Slot(code=code, market=market, universe_idx=idx))
    return out


def plan_batch(universe: dict, cursor: dict, quota: dict, *, failures=()) -> list[Slot]:
    """本批的完整工作单：**先重试、再续新**（§4.4）。

    ⚠️ **重试项不占配额**：它们的槽位早已被 `cursor` 走过，而配额记的是
    「累计尝试到第几个」。若让重试占配额，一层里失败得越多能新拉的股越少，
    池子会**安静地**缩水，最终报出假的 `pool_exhausted`。

    ⚠️ **必须按槽位去重（最终评审 F1）**：`cursor` **不是单调的** ——
    spec §4.4 崩溃恢复**第③档**明令把 `cursor` 回退为 `min(cursor, universe_idx)`，
    而 S2-F8 把「回退后存在 `universe_idx ≥ cursor` 的条目」定性为**合法状态**。
    回退之后，一条 `universe_idx` 落进 `[cursor, quota)` 的失败记录会**同时**出现在
    重试项与续新项里，于是同一只股被要求拷两遍：重复的 SMB 读取与哈希、
    `committed_bytes` 双记（**直接击穿 `--max-bytes` 这条硬上限**）、
    `attempts` 双增（把「一次重试」变成「零次」）。
    **不能留给 S4 兜**：交接单写的是「以 `pool_order` 为准跳过已成功槽位」，
    而重试项按定义**不在** `pool_order` 里（拷贝失败不进池）。
    """
    retries = retry_slots(universe, failures)
    seen = {(s.market, s.universe_idx) for s in retries}
    fresh = [s for s in fresh_slots(universe, cursor, quota)
             if (s.market, s.universe_idx) not in seen]
    return retries + fresh
