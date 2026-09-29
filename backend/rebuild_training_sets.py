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

import argparse
import asyncio
import filecmp
import json
import os
import random
import re
import sys
import tempfile
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
    # ⚠️ A2：`GenerateSkipException` 的语义是「这个候选不行，换一个」，
    #    `RebuildMismatch` 的语义是「停下来查清楚，不得继续」（见本文件顶部
    #    `RebuildMismatch` 的 docstring）。`load_gating_inputs` 与 `assemble_from_windows`
    #    都可能抛前者（门控输入读不出来 / 装配路径信任边界被破）—— 若不转换，
    #    它会带着字面「跳过」逃出 `rebuild_one`，让操作者误以为只是少了一只股，
    #    而实际是一个包都没产出、清单也没发布。`build_pinned_windows` 已经做了
    #    同款转换，这两处照抄同一模式。
    try:
        gi = await load_gating_inputs(conn, target.stock_code)
    except GenerateSkipException as exc:
        # ⚠️ `load_gating_inputs` 有一支原始措辞里带字面「跳过」（stock_coverage
        #    无覆盖 artifact 那一支）——那是它自己「换一个候选」的语义，不是这里
        #    RebuildMismatch「停下来查清楚」的语义，不能把「跳过」这个词也一并
        #    带进最终消息，否则操作者读到的还是「跳过」两个字。
        reason = str(exc).replace("，跳过", "").replace("跳过", "")
        raise RebuildMismatch(
            f"{target.stock_code}: 门控输入读不出来（{reason}）—— 源库与当初不同，"
            f"⛔ 停下来查清楚，不得继续") from exc
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

    try:
        return assemble_from_windows(
            output_dir, stock_code=target.stock_code,
            stock_name=_stock_name_of(target.stock_code),
            start_datetime=int(start), end_datetime=int(after_end), windows=windows)
    except GenerateSkipException as exc:
        raise RebuildMismatch(
            f"{target.stock_code}: 装配失败（{exc}）—— ⛔ 停下来查清楚，不得继续") from exc


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
    ⭐ 判据写成**白名单**（只许 `SelectStmt`），⛔ 不枚举「危险写法」——攻击面枚举永远漏。
    ⚠️ **但白名单本身不等于「纯读」**（评审实测证伪过一次，上一版这里写的是
       「合法面枚举不会漏」，那句话不准确，已订正）：`SELECT * INTO newtab FROM klines`
       其实是 `CREATE TABLE AS`、`SELECT … FOR UPDATE/SHARE` 要行锁，两者顶层同样是
       `SelectStmt`，会被这道白名单放行 —— 所以额外显式排除 `intoClause` 与
       `lockingClause` 这两种白名单看不见的形状。⚠️ 数据安全上没有洞（第一道
       `connect_read_only()` 挡得住这两条），这里补的是**证据可信度**：不让一条
       DDL 在 A4 的证据里被登记成「纯读」。
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
        if parsed[0].stmt.intoClause is not None:
            bad.append((sql, "带 INTO（它是 CREATE TABLE AS，不是纯读）"))
            continue
        if parsed[0].stmt.lockingClause:
            bad.append((sql, "带 FOR UPDATE/SHARE（要行锁，不是纯读）"))
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


def container_file_path(stock_code: str, start_datetime: int) -> str:
    return f"{CONTAINER_TRAINING_SETS_DIR}/{stock_code}_{int(start_datetime)}.zip"


def manifest_row(gts: GeneratedTrainingSet) -> dict:
    """spec §3.4 R2 的【新清单】一行 = 完整七元组。"""
    return {
        "stock_code": gts.stock_code,
        "stock_name": gts.stock_name,
        "start_datetime": int(gts.start_datetime),
        "end_datetime": int(gts.end_datetime),
        "schema_version": int(gts.schema_version),
        "file_path": container_file_path(gts.stock_code, gts.start_datetime),
        "content_hash": gts.content_hash,
    }


def assert_byte_identical(dir_a: Path, dir_b: Path) -> None:
    """两个目录里的 zip 必须逐字节相同（文件名集合也必须相同）。"""
    a = sorted(p.name for p in Path(dir_a).glob("*.zip"))
    b = sorted(p.name for p in Path(dir_b).glob("*.zip"))
    if a != b or not a:
        raise RebuildMismatch(f"两次产出的文件名集合不同或为空：{a} vs {b}")
    for name in a:
        if not filecmp.cmp(Path(dir_a) / name, Path(dir_b) / name, shallow=False):
            raise RebuildMismatch(
                f"{name} 两次产出的字节不同 —— 确定性压缩失效，"
                f"⛔『随时可以重来』这条恢复前提当场不成立")


_P11_EXPECTED_COLUMNS = ("stock_code", "stock_name", "start_datetime", "end_datetime",
                         "schema_version", "file_path", "content_hash")

#: 库存 3 个产物在迁移【之前】的代数。⚠️ 这是一条**历史事实**（实测 p11 SQL 现为 1），
#: 不是可配置常量；它的作用是让「P11 已被重新生成」这件事**当场可判**。
LEGACY_SCHEMA_VERSION = 1

#: `content_hash` 的形状：8 位**小写**十六进制。与 PG 侧约束
#: `ck_content_hash_crc32_lowercase` 同一口径（⛔ 不是随手定的）。
_CONTENT_HASH_RE = re.compile(r"^[0-9a-f]{8}$")


def assert_seven_tuple_shape(rows, *, where: str, expect_schema_version: int,
                             regenerated_hint: bool = False) -> None:
    """校验**完整七元组契约**：字段集合、类型、指纹形状、身份自洽、代数、指纹互不相同。

    ⛔ **这是一份判据，不是几条顺手的检查**（codex 评审第 5 轮的线索，实测复现）：
       上一版只查了「行数 / 代数 / (code,start,end) 集合」三样，于是 —— 逐条实测过 ——
       每行都缺 `content_hash` / 缺 `file_path` / 缺 `stock_name` **全部通过**，
       `content_hash` 是空串**通过**，三行共用同一个大写指纹**通过**，
       缺 `stock_code` 则抛 `KeyError`（命令行接不住，裸崩）。
       而 `content_hash` 正是 **P11b 身份闸的输入** —— 残缺的旧快照会被原样抄进新清单。
    ⭐ 用**集合等式**判字段（`set(row) != set(_P11_EXPECTED_COLUMNS)`），
       ⛔ 不用「这几个键各自在不在」—— 后者抓不住「多出来的第八个」。
    ⭐ `file_path` **由身份现算再比对**，⛔ 不单独相信文件里写的那一串。
    ⭐ 指纹互不相同这条有来历：`…-p15-….sql` 文件头自述，「三行共用同一期望指纹」
       正是它 R2 版被打回的原因（当时闸门还通过了、还打印 PASS）。
    ⚠️ 本函数**不**管行数与目标集合 —— 那是 `assert_matches_pinned_targets` 的事：
       `rebuild_all` 可能只跑一个目标（单测），而「必须是那三个」只对命令行成立。
    """
    if not isinstance(rows, list) or not rows:
        raise RebuildMismatch(f"{where}: 一行都没有")
    for i, row in enumerate(rows, 1):
        if not isinstance(row, dict) or set(row) != set(_P11_EXPECTED_COLUMNS):
            got = sorted(row) if isinstance(row, dict) else type(row).__name__
            raise RebuildMismatch(
                f"{where} 第 {i} 行的字段集合不对\n  实际：{got}\n"
                f"  应为：{sorted(_P11_EXPECTED_COLUMNS)}")
        for k in ("start_datetime", "end_datetime", "schema_version"):
            if not isinstance(row[k], int) or isinstance(row[k], bool):
                raise RebuildMismatch(f"{where} 第 {i} 行的 {k} 不是整数：{row[k]!r}")
        for k in ("stock_code", "stock_name", "file_path", "content_hash"):
            if not isinstance(row[k], str) or not row[k]:
                raise RebuildMismatch(
                    f"{where} 第 {i} 行的 {k} 不是非空字符串：{row[k]!r}")
        if not _CONTENT_HASH_RE.match(row["content_hash"]):
            raise RebuildMismatch(
                f"{where} 第 {i} 行的 content_hash 不是 8 位小写十六进制："
                f"{row['content_hash']!r}")
        if row["stock_name"] != row["stock_code"]:
            raise RebuildMismatch(
                f"{where} 第 {i} 行 stock_name({row['stock_name']!r}) "
                f"!= stock_code({row['stock_code']!r})")
        want_fp = container_file_path(row["stock_code"], row["start_datetime"])
        if row["file_path"] != want_fp:
            raise RebuildMismatch(
                f"{where} 第 {i} 行的 file_path 与它自己的身份对不上\n"
                f"  实际：{row['file_path']}\n  应为：{want_fp}")
    seen = sorted({r["schema_version"] for r in rows})
    if seen != [expect_schema_version]:
        extra = ("—— 说明这份 P11 已经被重新生成过，⛔ 旧身份不能再从它取"
                 "（取到的会是【新】值）。重跑请改用 --old-snapshot 指向【首轮】清单。"
                 if regenerated_hint else "")
        raise RebuildMismatch(
            f"{where}: schema_version 是 {seen}，应为 [{expect_schema_version}] {extra}")
    hashes = {r["content_hash"] for r in rows}
    if len(hashes) != len(rows):
        raise RebuildMismatch(
            f"{where}: {len(rows)} 行却只有 {len(hashes)} 个不同的 content_hash —— "
            f"「三行共用一个指纹」正是 p15 当初被打回的原因，⛔ 拒绝")


def assert_matches_pinned_targets(rows, *, where: str) -> None:
    """行数与 `(stock_code, start_datetime, end_datetime)` 集合必须与 `PINNED_TARGETS` 相同。"""
    if len(rows) != len(PINNED_TARGETS):
        raise RebuildMismatch(
            f"{where}: 应有 {len(PINNED_TARGETS)} 行，实际 {len(rows)} 行")
    got = {(r["stock_code"], r["start_datetime"], r["end_datetime"]) for r in rows}
    want = {(t.stock_code, t.start_datetime, t.expected_end_datetime)
            for t in PINNED_TARGETS}
    if got != want:
        raise RebuildMismatch(
            f"{where}: 与钉死的目标对不上\n  实际：{sorted(got)}\n  应为：{sorted(want)}")


def read_legacy_rows(p11_sql_path) -> list[dict]:
    """用 pglast（真 PostgreSQL 解析器）从 p11 SQL 里取出 `p11_expected` 的三行。

    ⛔ 不用正则、不人手抄：旧值**由机器从那份文件里读出来**，才谈得上可检验。
    ⛔ **只有在 P11 还是第 1 代时才许用它取旧值**：片 2 会把 P11 整份重新生成，
       之后再从它取，取到的是**新**值 —— 实测会被原样当成「旧值」写进清单
       （codex 评审第 1 轮 finding 2）。所以下面那道代数检查是**失败即拒**的，
       ⛔ 不得放宽成警告。重跑请改用 `read_old_snapshot()` 读【首轮】清单。
    """
    from pglast import parse_sql
    from pglast.stream import RawStream

    try:
        text = Path(p11_sql_path).read_text(encoding="utf-8")
    except (OSError, ValueError) as exc:
        # ⚠️ A1：`UnicodeDecodeError` ⊂ `ValueError`（文字编码坏掉时 `read_text` 抛的
        #    正是它）。姊妹函数 `read_old_snapshot` 早就接住了 `(OSError, ValueError)`，
        #    这里只接 `OSError` 是同一形状的第三次漏网（评审实测：喂一份编码坏掉的
        #    p11 副本，这里会让裸 `UnicodeDecodeError` 逃出去）。
        raise RebuildMismatch(f"{p11_sql_path} 读不出来：{exc}") from None
    # `\set` 等 psql 元命令不是 SQL，parse_sql 会拒；逐行剔除后再解析。
    sql = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("\\"))
    try:
        statements = parse_sql(sql)
    except Exception as exc:
        raise RebuildMismatch(
            f"{p11_sql_path} 解析不了（{exc}）⇒ 判不了 ⇒ 拒绝") from None
    rows: list[dict] = []
    for stmt in statements:
        node = stmt.stmt
        if node.__class__.__name__ != "InsertStmt":
            continue
        if node.relation.relname != "p11_expected":
            continue
        for row in node.selectStmt.valuesLists:
            vals = []
            for item in row:
                rendered = RawStream()(item)
                vals.append(rendered.strip().strip("'"))
            if len(vals) != len(_P11_EXPECTED_COLUMNS):
                raise RebuildMismatch(
                    f"p11_expected 的一行有 {len(vals)} 个值，"
                    f"而列清单有 {len(_P11_EXPECTED_COLUMNS)} 个 —— 结构变了，停下来查清楚")
            d = dict(zip(_P11_EXPECTED_COLUMNS, vals))
            for k in ("start_datetime", "end_datetime", "schema_version"):
                try:
                    d[k] = int(d[k])
                except (ValueError, TypeError) as exc:
                    raise RebuildMismatch(
                        f"{p11_sql_path} 的 {k} 列不是整数：{d[k]!r}（{exc}）") from None
            rows.append(d)
    if not rows:
        raise RebuildMismatch(f"{p11_sql_path} 里没找到 p11_expected 的 INSERT")
    assert_seven_tuple_shape(rows, where=str(p11_sql_path),
                             expect_schema_version=LEGACY_SCHEMA_VERSION,
                             regenerated_hint=True)
    assert_matches_pinned_targets(rows, where=str(p11_sql_path))
    return rows


def read_old_snapshot(path) -> list[dict]:
    """重跑时从【首轮清单】取旧身份，并逐项验证它确实是迁移前那一代。

    ⛔ 三条验证缺一不可：代数、目标集合、行数。少一条就可能把一份**新**清单
       当成旧快照接受，而那正是 finding 2 要堵的那个洞。
    """
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RebuildMismatch(f"{path} 读不出来或不是合法 JSON：{exc}") from None
    rows = data.get("old") if isinstance(data, dict) else None
    where = f"{path} 的 old 段"
    assert_seven_tuple_shape(rows, where=where,
                             expect_schema_version=LEGACY_SCHEMA_VERSION)
    assert_matches_pinned_targets(rows, where=where)
    return rows


async def rebuild_all(conn, targets, output_dir: Path, *, old_rows) -> dict:
    """R2 全流程：快照源库计数 → 逐个重建 → 再快照计数并比对。

    ⛔ `old_rows` **由调用方传进来**，本函数不自己去读 P11（codex 评审第 1 轮 finding 2）：
       「旧值必须来自迁移前的来源」这条判据，由 `read_legacy_rows` / `read_old_snapshot`
       各自**失败即拒**地守住；写成「在这里先读一次」只保证了『读在重建之前』，
       **保证不了**『读在 P11 被重新生成之前』。
    """
    before = await snapshot_source_counts(conn)
    new_rows = []
    for t in targets:
        new_rows.append(manifest_row(await rebuild_one(conn, t, output_dir)))
    assert_seven_tuple_shape(new_rows, where="本轮产出的新清单",
                             expect_schema_version=SCHEMA_VERSION)
    after = await snapshot_source_counts(conn)
    if before != after:
        raise RebuildMismatch(
            f"源库在重建前后发生了变化 —— ⛔ 停下来查清楚\n  前：{before}\n  后：{after}")
    return {"new": new_rows, "old": old_rows,
            "source_counts_before": before, "source_counts_after": after}


def _resolve_v1_archive() -> Path:
    """v1 审计归档的真实路径。⚠️ 读 `HOME` —— 测试里可以 monkeypatch 它。"""
    return Path(os.path.expanduser("~/qmt_trial_out")).resolve()


def assert_write_target_is_safe(path, *, kind: str, must_not_exist: bool = False) -> Path:
    """**任何**要写的路径，写之前都必须过这一道。返回解析后的真实路径。

    ⛔ **对每一个写入目标都要跑一遍**（产出目录 / 验证目录 / 清单）——
       只挡其中一个等于没挡（codex 评审第 1 轮 finding 1：原来只挡了产出目录）。
    ⭐ 判据用 `.resolve()` 是**故意的**：它会跟着符号链接走，而这正是需要的 ——
       实测一个指向归档的符号链接能让 `assemble_from_windows` 自带的守卫放行。
    """
    q = Path(path)
    real = q.resolve()
    archive = _resolve_v1_archive()
    if real == archive or archive in real.parents:
        raise RebuildMismatch(
            f"{kind} 的真实路径 {real} 落在 v1 审计归档 {archive} 之内"
            f"（给进来的是 {q}）—— 那里逐字节不得改动，⛔ 拒绝写入")
    if must_not_exist and (q.exists() or q.is_symlink()):
        raise RebuildMismatch(
            f"{kind} {q} 已经存在 —— ⛔ 拒绝覆盖。首轮清单里的【旧身份快照】"
            f"一旦被盖掉就再也取不回来（那时 P11 已经是第 2 代了）")
    # ⚠️ `must_not_exist` 这一支是**早失败**（给操作者一个好看的错误），
    #    **不是**保证 —— 它与真正写盘之间隔着整轮重建。承重的那道在 `publish_manifest`
    #    的 `os.link`（codex 评审第 2 轮）。⛔ 不要因为有了这里就把那里放宽。
    return real


def publish_manifest(manifest_path: Path, payload: str) -> None:
    """**原子发布**清单：先写临时文件并落盘，再用「目标已存在就失败」的方式挂上去。

    ⛔ **不能用 `write_text()`**（codex 评审第 2 轮）：它是 `O_CREAT|O_TRUNC`，
       会**截断**既有文件。而 `main` 里那道「清单不得已存在」的预检与这里之间
       隔着**整轮重建**（几分钟）—— 窗口期内另一个进程（比如操作者以为卡住了、
       在另一个终端重跑了一次）把清单建出来，预检**拦不住**，随后就被截断。
       实测：首轮那份 22 字节的快照被覆盖成新内容，**旧身份从此取不回来**。
    ⭐ `os.link` 在目标已存在时抛 `FileExistsError` 且**一个字节都不碰**（实测坐实），
       这一步本身是原子的 —— 预检只是「早点给出好看的错误信息」，
       **真正的保证在这里**。⛔ 不要因为有了预检就把这里退回 `write_text`。
    ⚠️ 这里用硬链接是**取它「已存在即失败」这一条性质**，与本仓记过的
       「硬链接能穿过守卫写到仓外」是两回事：那里的路径来自外部，这里的目标由我们自己算出、
       且刚刚过完路径闸。
    """
    d = manifest_path.parent
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".manifest.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        try:
            os.link(tmp, manifest_path)
        except FileExistsError:
            raise RebuildMismatch(
                f"清单 {manifest_path} 在本轮重建期间被别的东西创建了 —— "
                f"⛔ 拒绝覆盖，一个字节都没动。"
                f"（首轮清单里的【旧身份快照】一旦被盖掉就再也取不回来）") from None
        except OSError as exc:
            # ⚠️ B3：`os.link` 在跨设备或不支持硬链接的挂载点（SMB/NFS/exFAT）抛的是
            #    `EXDEV`/`EPERM`/`ENOTSUP` 一类 —— **不是** `FileExistsError`。`main()`
            #    只捕 `RebuildMismatch`，不转换的话这里会裸崩，而此时两轮重建已经跑完、
            #    清单却丢了。片 2/3 要在 NAS 语境下跑，这条很可能真踩到。
            raise RebuildMismatch(
                f"清单挂不上去（{exc}）—— 换一个本地文件系统上的 --manifest 路径"
                ) from None
        # 改名/挂链接的原子性 **不等于** 目录项已经落盘（spec §3.4 R4 同一条道理）
        dfd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        os.unlink(tmp)      # 成功时目标已是同一 inode 的另一个名字，删临时名无损


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="切片一 P4 R2：按钉死的起点重建 3 个训练组（只读源库）")
    ap.add_argument("--dsn", required=True, help="源库连接串（⛔ 必须是源库的只读副本）")
    ap.add_argument("--out-dir", required=True, help="产出目录（⛔ 必须【不存在】，由本命令新建）")
    ap.add_argument("--scratch-dir", required=True,
                    help="临时工作根（⛔ 必须【已存在】；⛔ 没有默认值、没有环境变量回退）")
    ap.add_argument("--manifest", required=True, help="清单写到哪里（JSON，⛔ 不得已存在）")
    ap.add_argument("--p11-sql",
                    help="【首轮用】现有 p11 SQL 的路径；⛔ P11 已被片 2 重新生成后不可再用")
    ap.add_argument("--old-snapshot",
                    help="【重跑用】首轮清单 JSON 的路径，旧身份从它取")
    args = ap.parse_args(argv)

    if bool(args.p11_sql) == bool(args.old_snapshot):
        print("拒绝：--p11-sql 与 --old-snapshot 必须【恰好给一个】——"
              " 首轮给 --p11-sql（那时 P11 还是第 1 代），重跑给 --old-snapshot"
              "（P11 已被片 2 改过，再从它取会取到【新】值）", file=sys.stderr)
        return 2

    try:
        # ⭐⭐ **第一件事：把临时工作根钉死。** 这是第 7 轮之后的【塌层】做法。
        #
        # 为什么不能再「校验系统临时目录」了（codex 第 6 → 7 轮，两轮实测）：
        #   ① 写盘的不止我们自己 —— `assemble_from_windows` 里的
        #      `tempfile.TemporaryDirectory()`（`generate_training_sets.py:468`）
        #      用同一个根；`mkdtemp` 还是**先把目录建出来**再返回，闸门只能事后发现。
        #   ② 更要命：**校验动作本身就会写**。冷缓存时 `tempfile.gettempdir()` 走
        #      `_get_default_tempdir()`，它对每个候选目录做
        #      `open` → `write(b'blat')` → `unlink` —— 实测在归档里真的建过又删过一个探针文件，
        #      **事后看目录什么都看不见**。
        #   ⚠️ 说准：那三个 zip 的**字节始终没被动过**；破的是「⛔ 不得写入归档」这条边界，
        #      外加「中途被打断，残渣留在归档里」。
        #
        # ⇒ 同一个根连着三轮冒头（第 1 / 6 / 7 轮），按本仓停止规则：**塌层 + 去开关**，
        #   ⛔ 不再枚举「还有哪条路径会写到归档里」——路径来源是环境决定的，数不完。
        #   塌成一条：**根由命令行显式给定**（必填），⛔ 无默认值、⛔ 无环境变量回退、
        #   ⛔ 全程不调用任何会做「发现」的函数；校验通过后立刻把 `tempfile` **钉**在它上面，
        #   于是下游那个 `TemporaryDirectory()` 也只能落在这里。
        scratch_root = assert_write_target_is_safe(args.scratch_dir, kind="临时工作根")
        if not scratch_root.is_dir():
            raise RebuildMismatch(
                f"临时工作根 {scratch_root} 不存在或不是目录 —— ⛔ 请先建好，"
                f"本命令不替你建（建了就等于又引入一次『先动手、后校验』）")
        tempfile.tempdir = str(scratch_root)    # ⛔ 必须排在任何分配之前

        out = assert_write_target_is_safe(args.out_dir, kind="产出目录")
        manifest_path = Path(args.manifest)
        assert_write_target_is_safe(manifest_path, kind="清单", must_not_exist=True)
        if out in manifest_path.resolve().parents:
            raise RebuildMismatch(
                f"清单 {manifest_path} 落在产出目录 {out} 里 —— ⛔ 输入输出不得混放")
        # `publish_manifest` 的临时文件要建在清单的上级目录里；上级不存在的话
        # `mkstemp` 抛的是 FileNotFoundError，会变成一个没人接的崩溃栈而不是干净的退出码。
        if not manifest_path.parent.is_dir():
            raise RebuildMismatch(
                f"清单 {manifest_path} 的上级目录不存在 —— ⛔ 请先把它建好")
        old_rows = (read_legacy_rows(Path(args.p11_sql)) if args.p11_sql
                    else read_old_snapshot(Path(args.old_snapshot)))
        # ⭐ 用 `os.mkdir`（⛔ **不加** `exist_ok`）把产出目录**原子地占下来**。
        #   spec §3.4 R2 要的本来就是「产出到一个【新目录】」，所以「必须不存在」
        #   比「必须为空」更贴合，而且顺手关掉了与清单同型的那个窗口：
        #   「先检查是不是空的、再往里写」拦不住两个进程同时开工，`mkdir` 拦得住
        #   （实测：第二次 mkdir 抛 FileExistsError）。
        try:
            os.mkdir(out)
        except FileExistsError:
            raise RebuildMismatch(
                f"产出目录 {out} 已经存在 —— spec §3.4 R2 要求产出到一个【新目录】，"
                f"⛔ 请换一个不存在的路径") from None
        except FileNotFoundError:
            raise RebuildMismatch(
                f"产出目录 {out} 的上级目录不存在 —— ⛔ 请先把上级目录建好") from None
    except RebuildMismatch as exc:
        print(f"重建中止：{exc}", file=sys.stderr)
        return 2

    async def _run():
        conn = ReadOnlyConn(await connect_read_only(args.dsn))
        try:
            man = await rebuild_all(conn, PINNED_TARGETS, out, old_rows=old_rows)
            # ⚠️ B1：spec §7 判据 9③「新一批的 (stock_code, start_datetime) 与旧三个
            #    逐一相同」此前只是**构造性成立**（`rebuild_all` 内部用的就是
            #    `PINNED_TARGETS`，天然吻合），从未被真正断言过。补上这一行让它
            #    真的被检验，而不是靠实现细节侥幸一致。
            assert_matches_pinned_targets(man["new"], where="本轮产出的新清单")
            # ⛔ **确定性自证是无条件的，不是开关**（codex 评审第 3 轮）：
            #    spec §3.4 R2 写的是「⭐ 确定性自证：同一输入【连跑两次】」，
            #    §7 判据 9① 写的是「这是『随时可重来』的唯一依据」，变异 B54 专门盯它。
            #    上一版把它做成 `--verify-determinism`（默认关）⇒ 只给必填参数跑一次
            #    就会发布正式清单并返回成功。**而后面 R6 收口闸比的全是「产出 vs 这份清单」**，
            #    两边同源、必然自洽 ⇒ 真有非确定性也照样全绿，直到恢复时重建的包对不上
            #    已发布的指纹才暴露 —— 那时已经没有退路了。
            #    ⛔ 不得加回任何跳过它的开关（本仓教训：同一类缺陷反复上移 ⇒ 塌层 + 去开关）。
            # ⭐ 用**全新的临时目录**，⛔ 不用 `out.parent / (out.name + "-verify")`：
            #    那个名字可能早就被一个【指向归档的符号链接】占着（第 1 轮 finding 1 实测）。
            #    mkdtemp 保证是新建的，根本不存在「被占着」这回事。
            second = Path(tempfile.mkdtemp(prefix="rebuild-verify-", dir=scratch_root))
            # ⚠️ C3：这道闸在**构造上恒通过**——`second` 是已校验过的 `scratch_root`
            #    自己的子目录（`mkdtemp` 建在其内），不可能落进归档。态度是对的（纵深防御），
            #    但它不是一道会拦下什么的**活闸**，只是防将来代码改动（比如改成别的父目录）
            #    时不至于悄悄绕开路径闸，⛔ 不要误以为这里正在验证什么真实风险。
            assert_write_target_is_safe(second, kind="验证目录")   # 纵深防御
            await rebuild_all(conn, PINNED_TARGETS, second, old_rows=old_rows)
            assert_byte_identical(out, second)          # 不一致 → 抛错 → 清单不发布
            man["determinism_verified_against"] = str(second)
            man["statements_issued"] = len(conn.statements)
            man["scratch_root"] = str(scratch_root)
            return man
        finally:
            await conn.inner.close()

    # ⚠️ C4：`out` 这时已经用 `os.mkdir` 建出来了，本命令**不回滚**——而它必须
    #    【不存在】才能重跑。下面两处失败出口都发生在这之后，各自都要提醒一句。
    _out_dir_hint = (f"⚠️ 产出目录 {out} 已经建出、不会自动清理，而它必须【不存在】"
                     f"才能重跑 —— 重试前请换一个新路径，或先手动删掉它。")

    try:
        manifest = asyncio.run(_run())
    except RebuildMismatch as exc:
        print(f"重建中止：{exc}", file=sys.stderr)
        print(_out_dir_hint, file=sys.stderr)
        return 1
    try:
        publish_manifest(
            manifest_path,
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    except RebuildMismatch as exc:
        print(f"清单发布失败：{exc}", file=sys.stderr)
        print(_out_dir_hint, file=sys.stderr)
        return 1
    print(f"清单已写到 {manifest_path}；发出的 SQL 共 {manifest['statements_issued']} 条，"
          f"全部为读。第二轮验证目录 {manifest['determinism_verified_against']} 带着 3 个 zip "
          f"永久留在 scratch 里（本命令不清理，磁盘紧张时请自行删除）。")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
