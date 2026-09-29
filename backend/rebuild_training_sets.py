# backend/rebuild_training_sets.py
"""切片一 P4 的 R2：按【钉死的起点】用【生产口径】重建训练组产物。

⛔ 本模块对源库**只读**：全部是 SELECT，绝不 INSERT / UPDATE / DELETE / DDL，
   也绝不调 `_register_training_set`（它是一条 `INSERT INTO training_sets`）。
   理由见 spec §3.4 R2 ⓐ：源库 `kline_trial` 里那 3 行是权威原始数据。

⭐ 窗口**不自己切**：把候选起点收窄到只剩目标那一个，然后调用与生产完全同一个纯入口
   `build_training_windows` —— 于是 D6（每周期前后根数）与 D9（盘中逐日完整）两道门
   照样跑，窗口口径与生产逐字一致。⛔ 直接调 `select_period_window` 会绕过这两道门。
"""
from __future__ import annotations

import random
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from generate_training_sets import (
    PERIOD_BEFORE_CAP, SCHEMA_VERSION, GeneratedTrainingSet, GenerateSkipException,
    _stock_name_of, assemble_from_windows, build_training_windows, compute_after_end,
    load_gating_inputs,
)

#: 训练组 zip 在 api 容器内的目录（与 p11 SQL 里那三行的 file_path 一致）
CONTAINER_TRAINING_SETS_DIR = "/data/training-sets"


class RebuildMismatch(Exception):
    """重建过程中任一「与权威值对不上」的断言失败。

    ⛔ 它**不是** `GenerateSkipException`：那个的语义是「这个候选不行，换一个」，
    而本异常的语义是「停下来查清楚，不得继续」。两者混用会把停机信号降级成跳过。
    """


@dataclass(frozen=True)
class RebuildTarget:
    stock_code: str
    start_datetime: int
    expected_end_datetime: int


#: spec §3.4 R2 ⓑ/ⓑ2：起点与右端都取自旧三个产物的权威值
#: （见 docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql 的 p11_expected）
PINNED_TARGETS: tuple[RebuildTarget, ...] = (
    RebuildTarget("000001.SZ", 1756656000, 1777996799),
    RebuildTarget("600519.SH", 1762099200, 1782835199),
    RebuildTarget("000001.SZ", 1762099200, 1782835199),
)


def pin_start_excludes(month_boundaries, start_datetime: int) -> frozenset:
    """把 `build_training_windows` 的候选集收成【至多一个】。

    `exclude_starts` 在 `select_valid_window` 里是在切 `[:max_retries]` **之前**过滤的
    （见该函数 docstring），所以把「除目标外的全部月边界」塞进去，剩下的候选最多一个，
    `rng.shuffle` 从此与结果无关。
    """
    targets = {int(b) for b in month_boundaries}
    if int(start_datetime) not in targets:
        raise RebuildMismatch(
            f"起点 {start_datetime} 不是月边界（本股共 {len(targets)} 个月边界）"
            f" —— 源库数据或月边界与当初不同，⛔ 停下来查清楚，不得继续")
    return frozenset(targets - {int(start_datetime)})


def build_pinned_windows(period_bars, month_boundaries, *, start_datetime: int,
                         dense_dates, trading_dates, dropped,
                         rng: Optional[random.Random] = None):
    """起点钉死版的 `build_training_windows`。返回 `(start_datetime, windows)`。"""
    excludes = pin_start_excludes(month_boundaries, start_datetime)
    try:
        start, windows = build_training_windows(
            period_bars, month_boundaries, rng or random.Random(0),
            dense_dates=dense_dates, trading_dates=trading_dates,
            before_caps=PERIOD_BEFORE_CAP, max_retries=1,
            exclude_starts=excludes, dropped=dropped)
    except GenerateSkipException as exc:
        # 钉死之后只剩一个候选：它被门拒 ⇒ 没有「换一个」这回事。
        raise RebuildMismatch(
            f"钉死的起点 {start_datetime} 过不了门控（{exc}）"
            f" —— ⛔ 停下来查清楚，不得退回去选别的起点") from exc
    if int(start) != int(start_datetime):
        raise RebuildMismatch(
            f"钉死的起点失效：要求 {start_datetime}，实际返回 {start}")
    return int(start), windows


async def rebuild_one(conn, target: RebuildTarget, output_dir: Path,
                      *, rng: Optional[random.Random] = None) -> GeneratedTrainingSet:
    """重建一个训练组。⛔ 只读源库；⛔ 不登记；⛔ 不取 B2 生成锁。

    次序是硬的：**先断言右端等于权威值，再装配**。反过来会在断言失败时已经把
    zip 写到盘上，留下一个「看起来产出成功了」的残渣。
    """
    gi = await load_gating_inputs(conn, target.stock_code)
    start, windows = build_pinned_windows(
        gi.period_bars, gi.month_boundaries, start_datetime=target.start_datetime,
        dense_dates=gi.dense_dates, trading_dates=gi.trading_dates,
        dropped=gi.dropped, rng=rng)

    idx = [int(b) for b in gi.month_boundaries].index(int(start))
    after_end = compute_after_end(gi.month_boundaries, idx)
    if int(after_end) != int(target.expected_end_datetime):
        raise RebuildMismatch(
            f"{target.stock_code}@{target.start_datetime}: 算出的 end_datetime ="
            f" {after_end}，而旧产物的权威值是 {target.expected_end_datetime}"
            f" —— 源库数据或月边界与当初不同，⛔ 停下来查清楚，不得继续")

    return assemble_from_windows(
        output_dir, stock_code=target.stock_code,
        stock_name=_stock_name_of(target.stock_code),
        start_datetime=int(start), end_datetime=int(after_end), windows=windows)


async def connect_read_only(dsn: str):
    """【第一道】连源库，让**数据库自己**进只读，并当场自证它真的只读了。

    ⭐ 这是唯一挡得住**函数副作用**的一道 —— 一次性 PG 实测：只读会话下
       `SELECT sneaky_write()`（函数体里有 `UPDATE`）被 PG 拒为
       `cannot execute UPDATE in a read-only transaction`，而**任何纯文本解析
       都看不见它**（语法上它就是个普通 SELECT）。
    ⭐ 自证不是走过场：实测对照过 —— 只读连接这句返回 `'on'`、普通连接返回 `'off'`
       ⇒ 这条判据**有判别力**，不是恒返回 `on`。
    ⚠️ 用 `SELECT current_setting(...)` 而**不是** `SHOW ...`：后者的语法树顶层不是
       `SelectStmt`，会被第二道自己拦下来。
    """
    import asyncpg
    conn = await asyncpg.connect(
        dsn, server_settings={"default_transaction_read_only": "on"})
    mode = await conn.fetchval("SELECT current_setting('transaction_read_only')")
    if mode != "on":
        await conn.close()
        raise RebuildMismatch(
            f"连上了，但这个会话不是只读的（transaction_read_only = {mode!r}）"
            f" —— ⛔ 拒绝在这种连接上跑重建")
    return conn


def assert_no_write_statements(statements) -> None:
    """【第二道】每条 SQL 都必须是**单条纯 SELECT**：解析得动、只有一条、顶层是
    `SelectStmt`、且语法树里不出现别的语句节点。不合格就逐条点名并抛错。

    ⛔ **不许按首个关键字判**（codex 评审第 4 轮，两个洞都实测复现过）：
       `WITH changed AS (UPDATE … RETURNING id) SELECT …` 首词是 `WITH` ⇒ 放行；
       `SELECT 1; UPDATE …` 首词是 `SELECT` ⇒ 放行。而它们改的是 `schema_version`，
       **不动行数也不动 `max(id)`** ⇒ 「跑前跑后计数一致」那条同样发现不了。
    ⭐ 判据写成**白名单**（只许 `SelectStmt`），⛔ 不枚举「危险写法」——
       攻击面枚举永远漏，合法面枚举不会。
    ⚠️ **解析不了 ⇒ 判不了 ⇒ 拒绝**，⛔ 不得当成「看起来没问题」。
    ⚠️ 它**看不见**函数副作用 —— 那一类由 `connect_read_only()` 兜住。
    """
    from pglast import parse_sql
    from pglast.visitors import Visitor

    class _Collect(Visitor):
        def __init__(self):
            self.tags = []

        def visit(self, ancestors, node):
            self.tags.append(node.__class__.__name__)

    bad = []
    for sql in statements:
        try:
            parsed = parse_sql(sql)
        except Exception as exc:
            bad.append((sql, f"解析不了（{exc}）⇒ 判不了 ⇒ 拒绝"))
            continue
        if len(parsed) != 1:
            bad.append((sql, f"一次发了 {len(parsed)} 条语句"))
            continue
        top = parsed[0].stmt.__class__.__name__
        if top != "SelectStmt":
            bad.append((sql, f"顶层是 {top}，不是 SelectStmt"))
            continue
        v = _Collect()
        v(parsed[0])
        others = sorted({x for x in v.tags
                         if x.endswith("Stmt") and x not in ("SelectStmt", "RawStmt")})
        if others:
            bad.append((sql, f"语法树里有非 SELECT 的语句节点：{others}"))
    if bad:
        listed = "\n".join(f"  · {s.strip()[:160]}\n      ↳ {why}" for s, why in bad)
        raise RebuildMismatch(
            f"源库只读被破坏：{len(bad)} 条语句不是纯读 —— ⛔ 停下来查清楚\n{listed}")


class ReadOnlyConn:
    """包住一个 asyncpg 风格连接：记录每条 SQL，非纯读**当场拒绝**。

    ⚠️ 它是**第二道 + 证据**，不是保险 —— 真正兜底的是 `connect_read_only()` 让
    数据库自己拒绝。本片重建路径只用 fetch / fetchrow / fetchval / transaction 四样，
    由 `test_rebuild_one_issues_no_write_statements` 钉住实际发出的语句集合。
    """

    def __init__(self, inner):
        self.inner = inner
        self.statements: list[str] = []

    def _record(self, sql: str):
        self.statements.append(sql)
        assert_no_write_statements([sql])

    def transaction(self, *, isolation=None, readonly=False):
        return self.inner.transaction(isolation=isolation, readonly=readonly)

    async def fetch(self, query: str, *args):
        self._record(query)
        return await self.inner.fetch(query, *args)

    async def fetchrow(self, query: str, *args):
        self._record(query)
        return await self.inner.fetchrow(query, *args)

    async def fetchval(self, query: str, *args):
        self._record(query)
        return await self.inner.fetchval(query, *args)

    async def execute(self, query: str, *args):
        self._record(query)
        return await self.inner.execute(query, *args)


#: spec §7 判据 9②：跑前跑后必须完全一致的那几个数
_COUNT_TABLES = ("klines", "stock_coverage", "stocks", "training_sets")


async def snapshot_source_counts(conn) -> dict:
    """四张表行数 + training_sets 的 max(id)。⛔ 全是 SELECT。"""
    out = {}
    for t in _COUNT_TABLES:
        out[f"{t}.count"] = int(await conn.fetchval(f"SELECT count(*) FROM {t}"))
    out["training_sets.max_id"] = await conn.fetchval("SELECT max(id) FROM training_sets")
    return out
