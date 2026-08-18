# backend/tests/test_qmt_pilot_db.py
"""Plan 4a 护栏 L1 单测。Spec: docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md"""
from __future__ import annotations

import ast
import asyncio
import hashlib
import pathlib
import re
import types

import pytest

from qmt_pilot_db import (CONTRACT_VERSION, FIRST_NORMAL_OID, INTENT_TTL_SECONDS,
                          MAINTENANCE_TABLES, PILOT_META_KEYS, PILOT_META_PHASE1_KEYS,
                          PILOT_META_PHASE2_KEYS, PilotClusterBoundaryError,
                          PilotDbBoundaryError, REQUIRED_BUSINESS_TABLES,
                          CANONICAL_SCHEMA_SHA256, CANONICAL_PILOT_SCHEMA_SHA256,
                          CANONICAL_BUSINESS_CATALOG_SHA256, sha256_of_sql,
                          adopt_connection, assert_identity_scalars,
                          declared_tables,
                          _is_wrapped_in_transaction,
                          _PIN_SEARCH_PATH_SQL as PIN_SEARCH_PATH_SQL,
                          _maintenance_closure_cte, _transaction_statements,
                          _user_objects, assert_cluster_allowed,
                          read_pilot_meta_rows, read_pilot_meta,
                          assert_db_allowed_for_reuse, assert_db_allowed_for_reset,
                          try_empty_remnant_exception, reset_pilot_database,
                          assert_pilot_db_allowed, create_pilot_database,
                          init_cluster_marker, MARKER_PURPOSE,
                          derive_confirm_token, derive_db_name, quote_ident)

_REPO = pathlib.Path(__file__).resolve().parents[2]

# 假件自检要「真的发一次写标记语句」，故直接引生产常量，不另抄一份文本
from qmt_pilot_db import _WRITE_MARKER_SQL as _WRITE_MARKER_SQL_FOR_FAKE  # noqa: E402


@pytest.mark.parametrize("bad_name", [
    "",                                   # 空串
    "klinedb",                            # 非前缀
    "postgres",                           # 非前缀（系统库）
    "kline_pilot_",                       # 前缀但 seed 为空
    "kline_pilot_A",                      # 大写非法
    "kline_pilot_x-y",                    # 连字符非法
    "kline_pilot_x; DROP DATABASE y",     # 注入形
    "kline_pilot_x\n",                    # ⚠️ 尾随换行：re.match+$ 会放行（O1-F11）
    "kline_pilot_" + "a" * 33,            # 超长（seed 上限 32）
])
def test_assert_pilot_db_allowed_rejects_bad_names(bad_name):
    with pytest.raises(PilotDbBoundaryError) as ei:
        assert_pilot_db_allowed(bad_name, reset=True, destructive=False)
    assert ei.value.code == "illegal_db_name"


def test_assert_pilot_db_allowed_accepts_legal_name():
    assert_pilot_db_allowed("kline_pilot_probe", reset=True, destructive=False) is None


def test_destructive_action_requires_reset():
    """DROP DATABASE 而 reset 非 True → 拒绝。"""
    with pytest.raises(PilotDbBoundaryError) as ei:
        assert_pilot_db_allowed("kline_pilot_probe", reset=False, destructive=True)
    assert ei.value.code == "destructive_without_reset"


def test_destructive_action_with_reset_passes():
    assert_pilot_db_allowed("kline_pilot_probe", reset=True, destructive=True) is None


def test_derive_db_name_rejects_bad_seed():
    for bad in ["", "A", "x-y", "a" * 33, "x\n"]:
        with pytest.raises(PilotDbBoundaryError) as ei:
            derive_db_name(bad)
        assert ei.value.code == "illegal_seed"


# 建库测试统一用这两份玩具 SQL，指纹**由内容算出来**（O4-R19-C1 起，模块会自校）。
# ⚠️ 建库测试一律用**仓库里的真 .sql**（O4-R30-C1 起）：模块把两份 schema 钉死到规范指纹，
#    玩具 SQL 会在那一关先失败，测试就走不到它要测的地方。
#    假件不执行 SQL，所以用真文件对它们没有额外成本。
_SQL_DIR = pathlib.Path(__file__).resolve().parents[1] / "sql"
TOY_SCHEMA_SQL = (_SQL_DIR / "schema.sql").read_text(encoding="utf-8")
TOY_PILOT_SCHEMA_SQL = (_SQL_DIR / "pilot_schema.sql").read_text(encoding="utf-8")
# 活目录指纹的**真原文**（真 PG 15.12 上从规范 schema.sql 建库后取出）。
# 三方互钉：固件 ↔ CANONICAL_BUSINESS_CATALOG_SHA256 ↔ 活库
#   · `test_business_catalog_fixture_matches_the_constant` 钉「固件 ↔ 常量」；
#   · 真 PG 验收脚本的 ㉕ 档钉「常量 ↔ 活库」（PG 大版本升级会在那里当场变红）。
_CANON_CATALOG_TEXT = (pathlib.Path(__file__).resolve().parent
                       / "fixtures/business_catalog_fingerprint.txt").read_text()

TOY_SCHEMA_SHA = hashlib.sha256(TOY_SCHEMA_SQL.encode("utf-8")).hexdigest()
TOY_PILOT_SCHEMA_SHA = hashlib.sha256(TOY_PILOT_SCHEMA_SQL.encode("utf-8")).hexdigest()


def test_derive_db_name_happy():
    assert derive_db_name("probe_01") == "kline_pilot_probe_01"


def test_quote_ident_doubles_embedded_quotes():
    assert quote_ident('kline_pilot_x') == '"kline_pilot_x"'
    assert quote_ident('a"b') == '"a""b"'


def test_maintenance_tables_matches_the_schema_file():
    """【维护库专用表集合】必须与 pilot_cluster_schema.sql **实际建的表**逐一相符。

    spec O4-F1：同一个洞开过三次 —— 集合的成员散落在常量 / 闸 (iii) 豁免 /
    闸 (i) 形状断言 / spec 多处，漏改一处即闸恒假。
    ⚠️ 此前这颗钉子把元组**硬编码**在测试里，于是「加一张表要同步六处」全靠记性，
    而它自己就是那六处之一。现在改为**从 schema 文件推导** —— 加表时它自动变红，
    而不是等人想起来改它。
    """
    sql = (pathlib.Path(__file__).resolve().parents[1] / "sql/pilot_cluster_schema.sql").read_text()
    in_file = tuple(re.findall(r"CREATE TABLE IF NOT EXISTS public\.(\w+)", sql))
    assert set(MAINTENANCE_TABLES) == set(in_file), (
        f"常量 {MAINTENANCE_TABLES} 与 schema 文件 {in_file} 不一致 —— "
        f"加表时还须同步：闸 (i) 形状断言、spec §4 集合定义、spec §5、spec §9-1a")
    assert len(MAINTENANCE_TABLES) == len(set(MAINTENANCE_TABLES)), "常量里有重复项"


class _FakeConn:
    """按查询关键词返回预设值的假 conn。

    ⚠️ 它只能验**控制流与形状**，验不了语义（relkind 覆盖面、锁可重入、DROP 是否被顶住）。
    那些一律交给 backend/scripts/verify_pilot_db_lifecycle.py 的真 PG 断言
    （spec §6.2：假件会静默建模错误语义，本仓已实证吃过亏）。
    """

    def __init__(self, *, marker_rows=None, user_objects=None, exempt_objects=None,
                 databases=(), meta_rows=None, fail_connect=False, meta_shape=None,
                 seed_lock_held=True, maintenance_shape=None,
                 registered_dbnames=True, meta_table_present=True):
        self.marker_rows = marker_rows if marker_rows is not None else [
            {"purpose": "qmt_pilot_disposable_cluster"}]
        # 【绝对空】现在是**结构性**判据（任何 oid >= 16384 的目录行 = 用户对象），
        # 不再是六条硬编码查询。假件据此建模：user_objects 是裸判据的命中，
        # exempt_objects 是闸 (iii) 豁免版的命中。
        self.user_objects = list(user_objects or [])
        self.exempt_objects = list(exempt_objects if exempt_objects is not None else [])
        self.databases = list(databases)
        self.meta_rows = meta_rows or []
        # pilot_meta 的**结构**（闸 0− 的第一层判据）。默认合规；
        # 传 dict 可造出「没有唯一约束的伪造表」等形态。
        # `public.pilot_meta` 这个**关系名**在不在（4a-2 闸 0− 的第 0 层）。
        # ⚠️ 与 `meta_shape` 分开建模是有意的：spec O1-F6 要求「表不存在 → not_owned」
        #    与「表在但形状不合规 → pilot_meta_ambiguous」**可区分**，
        #    而形状 SQL 对这两种情形返回的东西一模一样（EXISTS 全 false）。
        self.meta_table_present = meta_table_present
        # 按 seed 的 advisory lock 是否被本连接持有（现在是**在活连接上真验**，
        # 不再是调用方传进来的布尔参数——那个可伪造）。
        self.seed_lock_held = seed_lock_held
        # 收尾清理的**读后验**判据（O4-R12-C2）：判「这一行真的不在了」，
        # 而不是「DELETE 报了 1 行」。默认干净收尾后它已不在。
        self.intent_row_still_there = False
        # 闸 (ii) 的**外部**凭据（O4-R14-C1）：本工具声明过哪些库名。
        # True = 全部都登记过（多数用例的默认）；集合 = 只有其中的登记过。
        self.registered_dbnames = registered_dbnames
        self.declared_tables_all_present = True
        # apply 完 pilot_schema_sql 之后的结构证明（O4-R13-C2）。默认合规。
        # pilot 表上「本工具之外的依赖物」计数（O4-R26-C1）。默认干净。
        self.pilot_table_dependents = {
            "user_triggers": 0, "user_rules": 0,
            "extra_indexes": 0, "extra_constraints": 0,
            "rls_policies": 0, "rls_enabled": 0, "inherit_edges": 0}
        # 闸 2 的**业务表**那五组结构断言（4a-2）。默认合规。
        self.business_structure = dict(_OK_BUSINESS_STRUCTURE)
        # 业务表上的**行为对象**计数（O4-R34-C1）。默认干净。
        self.business_table_behavior = {
            "user_triggers": 0, "user_rules": 0,
            "rls_policies": 0, "rls_enabled": 0, "inherit_edges": 0}
        # 新建的库，来源代次基线必须是空的（O4-R27-C1）。
        self.pilot_source_rows = 0
        # 活目录指纹的**原文**（O4-R32-C2）。默认给一段哈希后恰等于规范常量的文本。
        self.business_catalog_text = _CANON_CATALOG_TEXT
        # 这条连接自称连着哪个库（O4-R28-C1）。默认 None = 由 _connector 按映射填。
        self.current_database = None
        # 这条连接所连库的 oid（O4-R35-C2）。默认与 create 路径记下的一致。
        self.current_db_oid = "16400"
        # 枚举 pg_database 时每个库名对应的 oid（O4-R36 自捉）。默认与对端假连接一致。
        self.database_oids: dict[str, str] = {}
        # 「同名库现在是哪个实例」——建库之后被删掉又重建时，测试把它改成替身的 oid。
        # None = 没发生替换。由 _ReplaceAfter* 这类子类在恰当时刻翻转（O4-R36-C1）。
        self.live_db_oid: str | None = None
        # 登记写入是否真的绑上了当前实例；None = 未涉及（保持既有行为）。
        self.registry_write_bound: bool | None = None
        # 这条连接所在集群的身份（O4-R29-C1）。默认所有假连接同机。
        self.cluster_id = "cluster-A"
        self.pilot_schema_shape = dict(_OK_PILOT_SHAPE)
        self.meta_shape = meta_shape if meta_shape is not None else {
            "key_is_text": True, "value_is_text": True, "key_is_unique": True}
        # 【维护库专用表集合】两张表的**结构**（闸 (i) 的第一层判据）。默认合规。
        self.maintenance_shape = (maintenance_shape if maintenance_shape is not None
                                  else dict(_OK_MAINTENANCE_SHAPE))
        # 三张维护表**在不在场**（`_MAINTENANCE_PRESENCE_SQL`）。默认全在场。
        # ⚠️ 与 `maintenance_shape` **分开建模是有意的**：`init_cluster_marker` 必须能
        #    区分「表不存在」（交给 DDL 补建）与「表在但结构坏」（零 DDL 拒绝）——
        #    `CREATE TABLE IF NOT EXISTS` 修不好后者，只会跳过。
        self.maintenance_presence = {"marker_present": True, "intent_present": True,
                                     "registry_present": True}
        # 维护角色是不是超级用户，以及生产代码**问过几次**。
        # ⚠️ R12-F1 之后封锁**不许**依赖它：先连上再封，已建立的会话不受
        #    `CONNECTION LIMIT 0` 影响，所以普通角色也能验空。
        #    这个计数器就是用来钉「不许依赖」的 —— 问一次就说明分支又回来了。
        self.is_superuser = True
        self.is_superuser_queries = 0
        # 目标库**当前**的连接数上限。封锁之后必须恢复成**这个值**，不是写死的 -1。
        self.datconnlimit = -1
        # 目标库**当前**是否接受连接。同上：恢复的是这个值，不是写死的 true ——
        # 一个被 DBA 明确设成不可连的库，本工具拒绝销毁之后不该把它「顺手打开」。
        self.datallowconn = True
        self.fail_connect = fail_connect
        self.closed = False
        self.executed: list[str] = []
        self.session_setup: list[str] = []
        # 统一的**有序**轨迹（含钉桩）。计数是脆弱断言 —— 中间多一处合法调用就会假红；
        # 次序才是判据：每段调用方 SQL 与其后第一次守卫查询之间必须夹着钉桩（O4-R22-C1）。
        self.ops: list[str] = []

    async def fetch(self, query, *args):
        self.ops.append(query)
        if "FROM pg_class c JOIN pg_namespace n" in query and "relisshared" in query:
            return [{"relname": c} for c in ("pg_class", "pg_collation", "pg_proc", "pg_type")]
        if "SELECT cat, n FROM (" in query:
            src = self.exempt_objects if "closure" in query else self.user_objects
            return [{"cat": c, "n": n} for c, n in src]
        if "pilot_cluster_marker" in query and "to_regclass" not in query:
            return list(self.marker_rows)
        if "pg_database" in query:
            return [{"datname": d, "db_oid": self.database_oids.get(d, "16400")}
                    for d in self.databases]
        if "pilot_meta" in query:
            return list(self.meta_rows)
        raise AssertionError(f"_FakeConn 收到未预期的 fetch: {query[:80]}")

    async def fetchrow(self, query, *args):
        self.ops.append(query)
        if "user_triggers" in query:
            # 两条判据的 SQL 都含 user_triggers —— 按 roots 里的表名区分（评审多次警告
            # 子串分发很脆弱，此处显式说明判别依据）。
            if "public.stocks" in query:
                return (None if self.business_table_behavior is None
                        else dict(self.business_table_behavior))
            return (None if self.pilot_table_dependents is None
                    else dict(self.pilot_table_dependents))
        if "klines_ohlc_double" in query:
            return (None if self.business_structure is None
                    else dict(self.business_structure))
        if "meta_is_table" in query:
            return None if self.pilot_schema_shape is None else dict(self.pilot_schema_shape)
        # ⚠️ 显式排在形状查询**之前**：两条 SQL 的判据名不相交（present / is_table），
        #    但本仓已被子串分发劫走过多次，故写死次序并说明判别依据。
        if "marker_present" in query:
            return (None if self.maintenance_presence is None
                    else dict(self.maintenance_presence))
        if "marker_is_table" in query:
            return None if self.maintenance_shape is None else dict(self.maintenance_shape)
        if "d.datallowconn, d.datconnlimit" in query:
            # 封锁前读回的**原值**（两列一行）。取不到 = 已经不是那个实例。
            if self.datconnlimit is None:
                return None
            return {"datallowconn": self.datallowconn,
                    "datconnlimit": self.datconnlimit}
        if "key_is_unique" in query:
            return dict(self.meta_shape)
        raise AssertionError(f"_FakeConn 收到未预期的 fetchrow: {query[:80]}")

    async def fetchval(self, query, *args):
        self.ops.append(query)
        # ⚠️ 这条必须**排在最前**：INSERT … RETURNING 的文本里含 pilot_create_intent，
        #    而下面几条是按子串分发的（评审警告过这套很脆弱，此处显式前置）。
        if "unnest($1::text[])" in query:
            # 「schema.sql 声明的表都建出来了吗」（O4-R19-C1）。默认全在。
            return len(args[0]) if self.declared_tables_all_present else 0
        # ⚠️ **精确匹配整条语句，不能用子串**：`_SEED_LOCK_HELD_SQL` 的文本里也含
        #    `pg_backend_pid()`，按子串分发会把锁判定的返回值一起劫走 ——
        #    实测当场打红九条用例（本仓「假件子串分发被自己的判据劫走」第 N 次）。
        if query.strip() == "SELECT pg_backend_pid()":
            return _HELD_PID
        if "is_superuser" in query:
            self.is_superuser_queries += 1
            return self.is_superuser
        if "datconnlimit" in query:
            return self.datconnlimit
        if "to_regclass('public.pilot_meta') IS NOT NULL" in query:
            return self.meta_table_present
        if "EXISTS (SELECT 1 FROM public.pilot_database_registry" in query:
            if self.registry_write_bound is False:
                # 登记那句 SELECT 一行都没取到 → 没插行 → 读后验落空（O4-R36-C1）。
                return False
            return self.registered_dbnames is True or (
                bool(self.registered_dbnames) and args[0] in self.registered_dbnames)
        if "EXISTS (SELECT 1 FROM public.pilot_create_intent" in query:
            return self.intent_row_still_there
        if "d.oid::text FROM pg_database d WHERE d.datname::text = $1" in query:
            return self._oid_now()
        if "pg_control_system()" in query:
            return self.cluster_id
        if "current_database()" in query and "pg_database" in query:
            return self.current_db_oid
        if query == "SELECT current_database()":
            # 假件默认「连对了库」；`_connector` 会把它设成映射里的那个名字（O4-R28-C1）。
            return self.current_database
        if "--constraints--" in query:
            return self.business_catalog_text
        if "count(*) FROM public.pilot_stock_source" in query:
            return self.pilot_source_rows
        if "pg_locks" in query:
            return self.seed_lock_held
        if "pilot_create_intent" in query and "INSERT" in query.upper():
            return args[3]                     # 默认「接管成功」，返回本次 run_id
        raise AssertionError(f"_FakeConn 收到未预期的 fetchval: {query[:80]}")

    def _oid_now(self):
        """同名库**此刻**是哪个实例。未发生替换时就是 `current_db_oid`。

        ⚠️ `db_is_gone` 建模「这个名字在 `pg_database` 里已经查不到了」——
           与 `live_db_oid`（被换成了另一个实例）是两回事，别合并：
           前者是 DROP 真的生效了，后者是同名替身。
        """
        if getattr(self, "db_is_gone", False):
            return None
        return self.current_db_oid if self.live_db_oid is None else self.live_db_oid

    def _sql_oid_predicate_rejects(self, query, args):
        """建模「PostgreSQL 会执行**写在这句 SQL 里**的 oid 谓词」（O4-R36-C1）。

        ⚠️ 判据故意挂在 **query 文本**上而不是调用参数上：挂参数的话，
        把谓词从 SQL 里删掉、参数照传，假件仍会拦 —— 钉子对「谓词被删」
        毫无反应，覆盖等于零（本仓多次踩过的假覆盖形态）。
        ⚠️ 边界：假件只能证明「模块对 UPDATE 0 / 空登记的反应正确」。
        「PG 真的按这个谓词拒绝」由真 PG 档㉗证明，host 层证明不了。
        """
        if "AND d.oid::text = $3" in query and len(args) > 2:
            return args[2] != self._oid_now()
        if "AND d.oid::text = $5" in query and len(args) > 4:
            return args[4] != self._oid_now()
        return False

    async def execute(self, query, *args):
        self.ops.append(query)
        if query == PIN_SEARCH_PATH_SQL:
            # ⚠️ 单独记账，**不进 `executed`**（O4-R17-C1）：它是会话钉桩、无数据副作用，
            #    而 `executed` 承载的断言是「闸未过就不许执行任何 DDL」。
            #    但**不能就这么放行** —— 见 test_search_path_is_pinned_first_on_every_guard_conn：
            #    那颗钉子要求它必须是每条守卫连接上的**第一条**语句。
            self.session_setup.append(query)
            return "SET"
        self.executed.append(query)
        if self._sql_oid_predicate_rejects(query, args):
            if "pilot_database_registry" in query:
                self.registry_write_bound = False
                return "INSERT 0 0"
            return "UPDATE 0"
        # asyncpg 的 execute 返回命令状态串（'DELETE 1' / 'UPDATE 1' …）。
        # 假件必须照样返回，否则「核行数」那类守卫在 host 层是**零覆盖**
        # ——它会在 None 上比较、恒不相等或恒相等，而不是真的在验行为。
        return self.command_status(query)

    def command_status(self, query):
        verb = query.strip().split()[0].upper() if query.strip() else ""
        return f"{verb} 1" if verb in ("DELETE", "UPDATE", "INSERT") else verb

    closed_after_ops = None

    async def close(self):
        self.closed = True
        # 次序判据用：close 这一刻，**维护连接**已经发出了多少条语句。
        # 由 `_seq_connector` 在交出连接时注入 `_maint_executed`（同一个 list 对象）。
        maint_log = getattr(self, "_maint_executed", None)
        if maint_log is not None:
            self.closed_after_ops = len(maint_log)


# ⚠️ **两份形状字典各自只有一份权威副本**（O4-R37-C2）：此前它们在
#    `_FakeConn.__init__` 与两三个用例里各写一遍，新增判据时只改被点名的那一处 ——
#    正是本 PR 里重演到第十一次的那个形态。任何新键加进这里，
#    所有用例自动跟上；漏加会在 `test_every_guard_table_shape_proof_covers_table_level_durability` 变红。
_OK_MAINTENANCE_SHAPE = {
    "marker_is_table": True, "marker_purpose_text": True,
    "marker_purpose_unique": True, "intent_is_table": True,
    "intent_columns_ok": True, "intent_dbname_unique": True,
    "registry_is_table": True, "registry_columns_ok": True,
    "registry_dbname_unique": True,
    # ⚠️ 耐久性判据**每表一条，不能合成一个跨表的 count**：合成一条时它
    #    **归因不到具体哪张表**，于是 `init_cluster_marker` 的预检只能
    #    「三张全在场才要求它」—— 混合态（一张在场但不耐久 + 另一张缺席）就此漏过，
    #    DDL 先落地，之后才拒。拆开之后，判据名前缀自动接进
    #    `_MAINTENANCE_SHAPE_OWNER` 的「只对在场的表求值」机制。
    "marker_durable": True, "intent_durable": True, "registry_durable": True}

_OK_PILOT_SHAPE = {
    "meta_is_table": True, "meta_key_unique": True, "meta_columns_ok": True,
    "source_is_table": True, "source_columns_ok": True, "source_key_unique": True,
    "pilot_tables_durable": True}

# 闸 2 的业务表五组（4a-2）。同上：唯一权威副本，新增判据时用例自动跟上。
_OK_BUSINESS_STRUCTURE = {
    "business_tables_are_tables": True, "klines_ohlc_double": True,
    "stock_coverage_present": True, "file_path_is_text": True,
    "content_hash_present": True, "uq_stock_start_present": True,
    "uq_stock_start_columns_ok": True}


def _connector(mapping):
    """返回一个 connect(dbname) -> conn 的可调用对象；dbname 不在 mapping 里即模拟连不上。

    ⚠️ 默认把返回连接的 `current_database` 设成**请求的那个名字**（O4-R28-C1）——
    即「连对了库」的正常情形。要模拟 DSN 改写 / 连接池串号，测试里显式改这个字段。
    """
    async def _connect(dbname):
        if dbname not in mapping:
            raise ConnectionError(f"cannot connect to {dbname}")
        conn = mapping[dbname]
        if getattr(conn, "current_database", None) is None:
            conn.current_database = dbname
        return conn
    return _connect


def test_absolutely_empty_is_structural_not_an_enumeration():
    """【绝对空】必须是**结构性**判据，不是「列举几个系统目录」（O4-R2-C1）。

    旧版硬编码六条查询。codex 指出并经真 PG 复现：**一个只含
    `CREATE COLLATION public.mycoll` 的库六条全返回 0** → 被判「绝对空」→
    可被无归属证明、无令牌地 `DROP DATABASE`。同样逃过的还有 pg_conversion /
    文本搜索对象 / publication / operator / opclass / cast / FDW……
    **枚举式判据每出一种新对象类型就漏一次。**

    现判据：PG 给 initdb 期对象分配 oid < 16384，**用户建的一切 >= 16384**；
    目录清单从 `pg_catalog` **现查**（`relisshared` 排掉集群级共享目录），
    故 PG 加新目录时自动覆盖，不需要改代码。
    """
    import qmt_pilot_db as m
    assert FIRST_NORMAL_OID == 16384
    src = pathlib.Path(m.__file__).read_text()
    assert "relisshared" in src, "必须用 relisshared 排掉 pg_database 这类集群级共享目录"
    assert "nspname = 'pg_catalog'" in src, "目录清单必须从 pg_catalog 现查"
    for banned in ("information_schema.tables", "relkind IN"):
        assert banned not in src, f"禁用枚举式写法：{banned}"


def test_all_table_references_are_schema_qualified():
    """所有表引用必须 `public.*` 限定（O4-R4-C1，codex 指出、真 PG 复现）。

    结构判据用 `to_regclass('public.pilot_meta')` 验的是 public 那张，而不带 schema 的
    `SELECT … FROM pilot_meta` 由 `search_path` 决定读哪张。实测
    `SET search_path = evil, public` 时**验的是 public、读的是 evil** ——
    一个完全不属于本工具的库，凭 evil schema 里**一行**伪造的 `tool='qmt_pilot'`
    就冒充归属成功。

    ⚠️ 本条只钉 SQL 文本；**敌意 search_path 下的实际行为只有真 PG 能验**，
    见 verify_pilot_two_phase_create.py 第 ⑥ 档。
    """
    import re as _re

    import qmt_pilot_db as m
    # ⚠️ 只扫**真正会被执行的 SQL 常量**，不扫注释与 docstring
    #    （注释里为了讲清反例，本来就会出现未限定的写法）。
    sql_consts = {k: v for k, v in vars(m).items()
                  if k.startswith("_") and isinstance(v, str) and _re.search(
                      r"\b(SELECT|INSERT|UPDATE|DELETE)\b", v, _re.I)}
    assert sql_consts, "没扫到任何 SQL 常量 —— 断言会空转"
    for name, sql in sql_consts.items():
        bad = _re.findall(r"(?:FROM|INTO|UPDATE)\s+(pilot_\w+)", sql)
        assert not bad, f"{name} 里的表引用未 schema 限定：{bad}"
    # 两份 SQL 文件同样要限定（否则建在 search_path 的第一个 schema 里）
    repo = pathlib.Path(__file__).resolve().parents[2]
    for f in ("backend/sql/pilot_schema.sql", "backend/sql/pilot_cluster_schema.sql"):
        text = (repo / f).read_text()
        assert "CREATE TABLE IF NOT EXISTS public." in text, f"{f} 的建表未 schema 限定"
        assert _re.search(r"CREATE TABLE IF NOT EXISTS (?!public\.)", text) is None, \
            f"{f} 里仍有未限定的 CREATE TABLE"


@pytest.mark.parametrize("sql,wrapped,label", [
    ("BEGIN;\nCREATE TABLE t ();\nCOMMIT AND CHAIN;", False, "COMMIT AND CHAIN"),
    ("BEGIN;\nCREATE TABLE t ();\nEND AND CHAIN;", False, "END AND CHAIN"),
    ("BEGIN;\nCREATE TABLE t ();\nCOMMIT PREPARED 'x';", False, "COMMIT PREPARED"),
    ("BEGIN;\nCREATE TABLE t ();\nCOMMIT WORK;", True, "COMMIT WORK"),
    ("BEGIN;\nCREATE TABLE t ();\nEND TRANSACTION;", True, "END TRANSACTION"),
])
def test_transaction_terminator_must_be_an_exact_form(sql, wrapped, label):
    """收尾必须是精确形式，`AND CHAIN` / `PREPARED` 一律拒（O4-R4-C2）。

    `COMMIT AND CHAIN` 提交完会**立刻开一个新事务** —— schema DDL 已落地、连接上却留着
    未闭合的事务；阶段 2 随后失败时 `CREATE DATABASE` 与阶段 1 都已产生副作用，
    留下一个半初始化的 pilot 库，而守卫本该在任何副作用**之前**拦下。
    """
    assert _is_wrapped_in_transaction(sql) is wrapped, label


def test_caller_assigned_oid_catalogs_bypass_the_threshold():
    """`oid >= 16384` 这条规律**对大对象不成立**（O4-R3-C1，codex 指出、真 PG 复现）。

    `lo_create(oid)` / `lo_import(path, oid)` / `lo_from_bytea` 允许**调用方自选 OID**——
    实测 `SELECT lo_create(100)` 造出 oid=100 的大对象，全局阈值看不见它，
    于是一个**装着用户数据**的库被判「绝对空」→ 可被无归属证明、无令牌地 DROP DATABASE。
    这类目录里 initdb 一个对象都不建，故任何行都算用户对象、不设阈值。

    ⚠️ 这条只钉常量与 SQL 形状；**判据在真库上是否真的抓到低 OID 大对象，
    只有真 PG 能验**（假件不执行 SQL）——见 verify_pilot_two_phase_create.py 第 ⑤ 档。
    """
    import qmt_pilot_db as m
    assert "pg_largeobject_metadata" in m._CALLER_ASSIGNED_OID_CATALOGS
    src = pathlib.Path(m.__file__).read_text()
    assert "_CALLER_ASSIGNED_OID_CATALOGS" in src
    assert '"TRUE" if c in _CALLER_ASSIGNED_OID_CATALOGS' in src, \
        "特化目录必须不设 oid 阈值"


def test_seed_lock_proof_pins_the_exact_lock_shape():
    """seed 锁证明必须限定**精确形状**（O4-R6-C1，codex 指出、真 PG 复现）。

    只查 classid/objid 时，两种别的锁形态都能冒充通过：
      · `pg_advisory_lock_shared(key)` —— **共享**锁，`mode='ShareLock'`，**不提供互斥**；
      · `pg_advisory_lock(int, int)` —— 两参数形式，`objsubid=2`（另一个命名空间），
        能拼出同样的 classid/objid。
    两者都会让**两次同 seed 的运行**同时通过守卫，去抢 intent 行与 CREATE/DROP。

    ⚠️ 本条只钉 SQL 形状；**别的锁形态是否真能冒充只有真 PG 能验**，见第 ⑧ 档。
    """
    import qmt_pilot_db as m
    assert "l.objsubid = 1" in m._SEED_LOCK_HELD_SQL, "必须限定单参数命名空间"
    assert "l.mode = 'ExclusiveLock'" in m._SEED_LOCK_HELD_SQL, "必须限定独占模式"


def test_maintenance_exemption_is_catalog_scoped():
    """豁免必须按 `(目录, oid)` 配对，不能裸比 oid（O4-R6-C2，真 PG 复现）。

    不同目录的 oid 可以相同，而 `lo_create(oid)` 允许调用方自选 OID ——
    可以蓄意造一个 oid 恰等于被豁免表的大对象，把它**藏在**闸 (iii) 之外。
    配对之后，`pg_largeobject_metadata` 天然永远不在豁免集里。
    """
    cte = _maintenance_closure_cte(MAINTENANCE_TABLES)
    assert "closure(catalog, oid)" in cte, "闭包必须带目录名"
    for cat in ("'pg_class'", "'pg_type'", "'pg_constraint'"):
        assert cat in cte, f"闭包缺少目录标注 {cat}"
    import qmt_pilot_db as m
    src = pathlib.Path(m.__file__).read_text()
    assert "cl.catalog = " in src, "过滤必须按目录配对"
    assert "x.oid NOT IN (SELECT oid FROM closure)" not in src, "不得再裸比 oid"


def test_maintenance_exemption_is_a_structural_whitelist():
    """闸 (iii) 的豁免必须是**结构性白名单**，不是 `pg_depend` 闭包（O4-R5-C1）。

    真 PG 实测：用户自己 `CREATE INDEX` / `CREATE RULE` 出来的东西，PostgreSQL 同样标成
    **AUTO 依赖**（它们随表一起被删）—— 于是「跟着 pg_depend 闭包豁免」会把它们一并盖住，
    维护库里带着继承子表 / 额外索引 / 额外约束 / 规则 / 触发器也被判「干净」。
    现改为只列举这两张表**合法应有**的派生物：TOAST 表及其索引、复合/数组类型、
    **仅主键**约束、**仅主键背后**的索引。

    ⚠️ 本条只钉 SQL 形状；**五种反例是否真被抓到只有真 PG 能验**（假件不执行 SQL），
    见 verify_pilot_two_phase_create.py 第 ⑦ 档（每个反例单独造、单独清）。
    """
    import re as _re
    cte = _maintenance_closure_cte(MAINTENANCE_TABLES)
    # ⚠️ 只看**真正的 SQL**，不看注释 —— CTE 的注释里会提到 pg_depend 讲清为什么不用它
    #    （先前有一条断言就是因为扫到注释而误报的）。
    sql_only = _re.sub(r"--[^\n]*", "", cte)
    assert "RECURSIVE" not in sql_only, "不得再用递归依赖闭包 —— 它会盖住用户造的依赖物"
    assert not _re.search(r"\b(FROM|JOIN)\s+pg_depend\b", sql_only), \
        "不得靠 pg_depend 判「合法派生物」"
    assert "contype = 'p'" in cte, "约束只豁免主键"
    assert "reltoastrelid" in cte and "typarray" in cte, "TOAST 与数组类型必须在白名单里"
    for tbl in MAINTENANCE_TABLES:
        assert f"to_regclass('public.{tbl}')" in cte, f"白名单的根漏了 {tbl}"
    fake = _maintenance_closure_cte(("alpha_tbl", "beta_tbl"))
    assert "alpha_tbl" in fake and MAINTENANCE_TABLES[0] not in fake


def test_cluster_gate_iii_catches_objects_the_old_enumeration_missed():
    """闸 (iii) 必须抓到旧枚举判据漏掉的对象类型（O4-R2-C1）。

    `pg_collation` 是 codex 点名、真 PG 复现过的那一个。
    """
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            _FakeConn(exempt_objects=[("pg_collation", 1)]),
            connect=_connector({}), target_db="kline_pilot_probe"))
    assert ei.value.code == "maintenance_db_not_empty"


def test_absolutely_empty_fails_closed_when_catalog_list_unavailable():
    """查不出目录清单时**绝不能返回「空」** —— 证明不了「空」等价于「非空」。"""
    class _NoCatalogs(_FakeConn):
        async def fetch(self, query, *args):
            if "relisshared" in query:
                return []
            return await super().fetch(query, *args)

    with pytest.raises(Exception):
        asyncio.run(_user_objects(_NoCatalogs()))


def test_cluster_gate_i_rejects_missing_marker():
    conn = _FakeConn(marker_rows=[])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "no_marker"
    assert conn.executed == [], "闸未过就不许执行任何 DDL"
    # 会出现不止一次：闸自己钉一次，`cluster_identity` 内部再钉一次
    #（`pg_control_system()` 是**函数**，同样走 search_path 解析，该钉）。
    # 断言的本意是「先跑的只能是钉桩」，故按集合比。
    assert conn.session_setup and set(conn.session_setup) == {PIN_SEARCH_PATH_SQL}, \
        f"闸未过之前跑了别的会话级语句：{conn.session_setup}"


def test_cluster_gate_i_rejects_two_marker_rows():
    """两行时 SELECT ... LIMIT 1（无 ORDER BY）与 EXISTS(...) 给出相反结论
    → 同一台集群能不能被建库/DROP 取决于实现细节（spec O1-F8）。"""
    conn = _FakeConn(marker_rows=[{"purpose": "qmt_pilot_disposable_cluster"},
                                  {"purpose": "something_else"}])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "no_marker"


def test_cluster_gate_ii_rejects_unrelated_database():
    conn = _FakeConn(databases=["production_db"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "unrelated_database"


def test_cluster_gate_ii_rejects_prefix_named_db_without_pilot_meta():
    """前缀名不是归属证明：共享集群上一个恰好叫 kline_pilot_xxx 的**非空**无关库，
    会让整台集群被误判为「干净」（spec R22-F1，「形状不是归属」的第五次）。"""
    other = _FakeConn(meta_rows=[], user_objects=[("pg_class", 3)])  # 非空
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": other}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_cluster_gate_ii_exempts_absolutely_empty_remnant():
    """零用户对象的同名库是「崩在 CREATE 与写 pilot_meta 之间的残骸」→ **放行集群闸**。
    不豁免的话，一个残骸会把整台集群对所有 seed 锁死（spec R55-F1）。"""
    remnant = _FakeConn(meta_rows=[], user_objects=[])
    conn = _FakeConn(databases=["kline_pilot_other"])
    asyncio.run(assert_cluster_allowed(
        conn, connect=_connector({"kline_pilot_other": remnant}),
        target_db="kline_pilot_probe"))  # 不抛 = 放行


def test_cluster_gate_ii_skips_target_db_itself():
    """目标库由闸 0−/0/0b 全权负责。不排除它的话，「目标库已存在、非空、无 pilot_meta」
    这一档会先被集群闸拒掉，报「这台集群不干净」，而真相是「你的目标库不是本工具建的」
    ——下一步动作「人工删这个库」与报告完全对不上（spec P1r3-F4）。"""
    conn = _FakeConn(databases=["kline_pilot_probe"])
    # connect 映射为空：若实现去连了目标库，会抛 ConnectionError 而非干净返回
    asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                       target_db="kline_pilot_probe"))


def test_cluster_gate_ii_connect_failure_is_fail_closed():
    """datallowconn=false / datconnlimit=0 / 无 CONNECT 权限 / 正被别的会话删除 ——
    任一导致「连进去验归属」抛异常时，判定为「无法证明归属」→ 拒绝。
    **绝不 try/except: continue**（那是 fail-open，spec O1-F10）。"""
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_cluster_gate_iii_rejects_dirty_maintenance_db():
    """「没有别的数据库」≠「这台集群没在用」——生产对象完全可以就放在默认 postgres 库里
    （spec R20-F2）。豁免后仍有 1 个对象即拒。"""
    conn = _FakeConn(exempt_objects=[("pg_collation", 1)])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="kline_pilot_probe"))
    assert ei.value.code == "maintenance_db_not_empty"


def test_cluster_gate_ii_rejects_structurally_invalid_pilot_meta():
    """一张**没有唯一约束**、只塞了一行 `tool='qmt_pilot'` 的伪造 `pilot_meta`
    不得被当成归属证明（O4-R2-C2，codex 判 high）。

    运行时的「重复 key 检测」抓不到它 —— 表里就一行，读起来毫无异常。
    于是一个来路不明的 `kline_pilot_*` 库能冒充「本工具建的」，
    在任何 `CREATE`/`DROP`/导入之前就削弱了一次性集群边界。
    """
    forged = _FakeConn(
        meta_rows=[{"key": "tool", "value": "qmt_pilot"}],
        meta_shape={"key_is_text": True, "value_is_text": True, "key_is_unique": False},
        user_objects=[("pg_class", 3)])          # 非空 → 不走残骸豁免
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": forged}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_read_pilot_meta_rows_rejects_bad_shape():
    """闸 0− 的结构判据（4a-2 的闸 0− 复用同一实现）。"""
    for bad in ({"key_is_text": False, "value_is_text": True, "key_is_unique": True},
                {"key_is_text": True, "value_is_text": False, "key_is_unique": True},
                {"key_is_text": True, "value_is_text": True, "key_is_unique": False}):
        with pytest.raises(PilotDbBoundaryError) as ei:
            asyncio.run(read_pilot_meta_rows(_FakeConn(
                meta_shape=bad,
                meta_rows=[{"key": "tool", "value": "qmt_pilot"}])))
        assert ei.value.code == "pilot_meta_ambiguous", bad


def test_cluster_gate_ii_rejects_ambiguous_pilot_meta_in_other_db():
    """别的 pilot 库若 `key` 上没唯一约束、塞进两行 `tool`，裸 dict 推导式会**静默取最后一行**
    → 哪一行「赢」取决于 PG 的 tie-break → **同一台集群这次判干净、下次判不干净**
    （spec §4 P1-F7：这条纪律此前只落在 marker 上）。"""
    ambiguous = _FakeConn(
        meta_rows=[{"key": "tool", "value": "something_else"},
                   {"key": "tool", "value": "qmt_pilot"}],
        user_objects=[("pg_class", 3)])          # 非空 → 不走残骸豁免
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": ambiguous}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_cluster_gate_rejects_illegal_target_db_name():
    """`target_db` 会让闸 (ii) **整个跳过**那个名字的库，故它自己必须先过名字护栏（O4-W3）。

    传一个生产库的名字进来 → 闸 (ii) 不会枚举到它 → 三条闸全过 →
    工具在生产集群上建库灌数据（spec §1 的风险 ①）。
    """
    conn = _FakeConn(databases=["production_db"])
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                           target_db="production_db"))
    assert ei.value.code == "illegal_db_name"


def test_cluster_gate_allows_none_target_for_init_path():
    """`--init-cluster-marker` 路径没有目标库，显式传 None 必须放行。"""
    asyncio.run(assert_cluster_allowed(_FakeConn(), connect=_connector({}), target_db=None))


def test_cluster_gate_none_target_still_runs_all_three_gates():
    """`target_db=None` **不是**「整套闸全跳过」（O4-W2r1 M-3）。

    上一条用的 `_FakeConn()` 其 `databases=()`，闸 (ii) 的循环体一次都不进 ——
    把实现写成 `if target_db is None: return` 那条测试**照样绿**，
    于是 None 分支的闸 (ii)/(iii) 覆盖为 0。本条补上真正的行为断言。
    """
    conn = _FakeConn(databases=["production_db"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}), target_db=None))
    assert ei.value.code == "unrelated_database"
    # 闸 (iii) 同样不得被跳过
    with pytest.raises(PilotClusterBoundaryError) as ei2:
        asyncio.run(assert_cluster_allowed(_FakeConn(exempt_objects=[("pg_collation", 1)]),
                                           connect=_connector({}), target_db=None))
    assert ei2.value.code == "maintenance_db_not_empty"
    # 闸 (i) 同样不得在 None 路径上被跳过（O4-W3 M-9：前一版只钉了 (ii)(iii)，
    # 把实现写成「None 时跳过闸 (i)」这条测试照样绿）
    with pytest.raises(PilotClusterBoundaryError) as ei3:
        asyncio.run(assert_cluster_allowed(_FakeConn(marker_rows=[]),
                                           connect=_connector({}), target_db=None))
    assert ei3.value.code == "no_marker"


def test_cluster_gate_ii_ownership_probe_failure_is_fail_closed():
    """spec O1-F10：**任一**导致「连进去验归属」抛异常时都判 `unowned_pilot_database`（O4-W4）。

    此前只包了 `connect()`；`_is_absolutely_empty` 或 `fetchval` 抛（该库被并发 DROP、
    连接 reset）会逃成裸 asyncpg 异常 → 4c 记成 `FAIL_INFRASTRUCTURE`，
    而 §9-1w 明令禁止「把一次成功的守卫记成环境故障」。
    """
    class _BoomOnEmptyCheck(_FakeConn):
        async def fetch(self, query, *args):
            # 【绝对空】现在走 fetch（现查目录清单 + 扫 oid），注入点随之改到这里
            if "relisshared" in query or "SELECT cat, n FROM (" in query:
                raise RuntimeError("模拟：探测【绝对空】时该库被并发 DROP")
            return await super().fetch(query, *args)

    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": _BoomOnEmptyCheck(meta_rows=[])}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_close_failure_does_not_override_the_gate_verdict():
    """`finally` 里的 `close()` 抛出会**替换掉**刚判出来的闸结论（Python finally 语义）——
    于是一次成功的守卫变成裸异常 → 4c 记成 `FAIL_INFRASTRUCTURE`，
    而那是「把一次成功的守卫记成环境故障」（O4-W4 M-2：此前这条修复零覆盖，
    把整段 try/except 删掉 74 条测试全绿）。
    """
    class _BoomOnClose(_FakeConn):
        async def close(self):
            raise RuntimeError("模拟：连接已 abort，close 抛出")

    other = _BoomOnClose(meta_rows=[], user_objects=[("pg_class", 3)])   # 非空 → 应判 unowned
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": other}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database", \
        "close() 的异常不得顶掉闸结论"


def test_cluster_gate_all_pass_executes_no_ddl():
    conn = _FakeConn()
    asyncio.run(assert_cluster_allowed(conn, connect=_connector({}),
                                       target_db="kline_pilot_probe"))
    assert conn.executed == []


def test_pilot_meta_has_exactly_nine_keys():
    assert PILOT_META_KEYS == (
        "tool", "seed", "schema_sha256", "pilot_schema_sha256", "contract_version",
        "export_log_sha256", "output_dir", "created_at", "state",
    )
    assert len(PILOT_META_KEYS) == 9


def test_contract_version_matches_swift_source_of_truth():
    """跨语言契约漂移钉：Python 侧的常量必须与 Swift 那份逐字相等。
    一次与 pilot 无关的 iOS 迁移 bump 会让复用闸对既有库全判失配——那是预期行为，
    但两边必须**同时**改，不能一边悄悄漂。"""
    swift = (_REPO / "ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift").read_text()
    assert f'CONTRACT_VERSION = "{CONTRACT_VERSION}"' in swift


def test_confirm_token_preimage_is_byte_exact():
    """preimage 逐字定义（spec O1-F14）：
    <export_log_sha256 全 64 位>|<output_dir 不带尾斜杠>|<created_at ISO-8601 basic UTC 微秒>
    取 sha256 的前 12 位十六进制。"""
    import hashlib
    sha = "a" * 64
    out = "/Users/me/pilot_out"
    at = "20260729T101530123456Z"
    expected = hashlib.sha256(f"{sha}|{out}|{at}".encode()).hexdigest()[:12]
    assert derive_confirm_token(sha, out, at) == expected


def test_confirm_token_strips_trailing_slash_from_output_dir():
    """尾斜杠必须被剥掉，否则同一个目录会派生出两个不同的令牌
    → 操作者照打印填了却对不上，reset 的唯一出路被自己焊死。"""
    assert derive_confirm_token("a" * 64, "/x/y/", "20260729T101530123456Z") == \
           derive_confirm_token("a" * 64, "/x/y", "20260729T101530123456Z")


def test_confirm_token_rejects_missing_created_at():
    """闸 0− 的四个授权键**不含** created_at，故绑定不符而该键缺失时派生不出令牌
    → 必须明确提示人工删库，而不是派生一个假令牌（spec O1-F14）。"""
    with pytest.raises(PilotDbBoundaryError) as ei:
        derive_confirm_token("a" * 64, "/x/y", "")
    assert ei.value.code == "confirm_token_underivable"


def test_intent_ttl_is_24h():
    """孤儿 intent 行是一条**永久有效的销毁授权**（spec O4-F2 撤回了上一轮
    「无害且自愈」的假断言）。TTL 把授权窗口从「永久」收窄到 24h。"""
    assert INTENT_TTL_SECONDS == 24 * 3600


class _RecordingConn(_FakeConn):
    """记录 execute 的完整序列与事务边界，用于断言两阶段建库的次序与原子性。"""

    def __init__(self, **kw):
        super().__init__(**kw)
        self.log: list[tuple[str, tuple]] = []
        self.transactions = 0            # 进入过几次事务
        self.rolled_back = 0             # 回滚过几次
        self._depth = 0
        self.executes_outside_transaction: list[str] = []
        # 每条 execute 落在第几个事务里（1-based；0 = 事务外），
        # 用来断言「哪些键写在阶段 1、哪些写在阶段 2」——只看常量的测试抓不到这一层。
        self.meta_keys_by_phase: dict[int, list[str]] = {}

    def transaction(self):
        conn = self

        class _Tx:
            async def __aenter__(self):
                conn.transactions += 1
                conn._depth += 1
                return conn

            async def __aexit__(self, exc_type, exc, tb):
                conn._depth -= 1
                if exc_type is not None:
                    conn.rolled_back += 1
                return False          # 不吞异常

        return _Tx()

    async def fetchval(self, query, *args):
        # intent 的 INSERT 走 fetchval（要读 RETURNING），也必须进 log —— 否则
        # 「冲突时绝不建库」「DELETE 带 run_id」这类断言看不到它。
        if "pilot_create_intent" in query:
            self.log.append((query, args))
            self.executed.append(query)
        return await super().fetchval(query, *args)

    async def execute(self, query, *args):
        if query == PIN_SEARCH_PATH_SQL:
            # 与 _FakeConn 同规格：会话钉桩不进 log / executes_outside_transaction，
            # 由 test_search_path_is_pinned_first_on_every_guard_conn 单独钉住。
            return await super().execute(query, *args)
        # ⚠️ 本方法不走 super().execute（它有自己的记账与返回值），
        #    所以有序轨迹要在这里补 —— 否则 ops 里只有钉桩，次序断言无从谈起。
        self.ops.append(query)
        if self._depth == 0:
            self.executes_outside_transaction.append(query)
        elif "pilot_meta" in query and "INSERT" in query.upper():
            self.meta_keys_by_phase.setdefault(self.transactions, []).append(args[0])
            # ⚠️ 真的把值记下来（O4-R22-C2）：新判据要在 apply schema.sql **之后**
            #    把 pilot_meta 读回来逐键比对。假件不建模写→读闭环的话，
            #    读回来永远是空表，判据在所有用例上恒真地失败 —— 覆盖等于零。
            self.meta_rows.append({"key": args[0], "value": args[1]})
        elif "SET value = 'ready'" in query:
            for row in self.meta_rows:
                if row["key"] == "state":
                    row["value"] = "ready" 
        self.log.append((query, args))
        self.executed.append(query)
        if self._sql_oid_predicate_rejects(query, args):
            if "pilot_database_registry" in query:
                self.registry_write_bound = False
                return "INSERT 0 0"
            return "UPDATE 0"
        return self.command_status(query)

    async def fetch(self, query, *args):
        if "pilot_meta" in query:
            # ⚠️ 这条捷径**必须自己记 ops**：它不走 super().fetch，而有序轨迹是在那里记的。
            #    漏记的后果不是「少一行日志」——「置 ready 之后有没有再读一次」这类
            #    **次序断言**会看不见它而恒假（实测：钉子第一版就这么假红了）。
            self.ops.append(query)
            return list(self.meta_rows)
        return await super().fetch(query, *args)


def _stage_sequence(conn):
    """把 execute 日志压成可断言的阶段序列。"""
    out = []
    for q, _ in conn.log:
        low = q.lower()
        if "pilot_create_intent" in low and "insert" in low:
            out.append("intent")
        elif "create database" in low:
            out.append("create_db")
        elif "pilot_meta" in low and "insert" in low:
            out.append("meta")
        elif "create table" in low and "pilot_meta" in low:
            out.append("apply_pilot_schema")
        elif "create table" in low:
            out.append("apply_schema")
        elif "pilot_meta" in low and "update" in low and "ready" in low:
            out.append("ready")
    return out


def test_create_pilot_database_writes_intent_before_create():
    """intent 行写在 CREATE DATABASE **之前**，故没有窗口（spec P1r3-F2）。"""
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z",
        run_id="run-001"))
    seq = _stage_sequence(maint) + _stage_sequence(target)
    assert seq.index("intent") < seq.index("create_db"), "intent 必须先于 CREATE DATABASE"


def test_create_pilot_database_writes_meta_before_schema():
    """归属先于 schema（spec R55-F1）：CREATE DATABASE 之后**第一件事**就是写 pilot_meta。

    原序列 CREATE → apply schema → 写 pilot_meta 会在崩溃时留下一个**没有 pilot_meta 的
    kline_pilot_* 库**：集群闸 (ii) 判它「名字匹配但无合法 pilot_meta」→ 拒绝；归属闸也
    因缺 pilot_meta 而拒绝 DROP → **工具被自己的护栏锁死**。"""
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z",
        run_id="run-001"))
    seq = _stage_sequence(target)
    assert seq.index("meta") < seq.index("apply_schema"), "pilot_meta 必须先于 schema.sql"
    assert seq[-1] == "ready", "state='ready' 必须是最后一步"


def test_create_pilot_database_uses_template0():
    """一律 CREATE DATABASE … TEMPLATE template0（spec O1-F8，实测）：
    template1 里有一张表时，默认模板建出的库【绝对空】返回 1
    → **本工具自己的残骸不满足【绝对空】** → 集群闸豁免不成立
    → 整台集群对所有 seed 锁死，且 --reset 也清不掉。"""
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z",
        run_id="run-001"))
    create = [q for q, _ in maint.log if "CREATE DATABASE" in q][0]
    assert "TEMPLATE template0" in create


def test_phase_key_sets_partition_the_nine_keys():
    """7/2 两阶段键集合必须**恰好划分**九键——不重不漏（O4-T2-I1）。"""
    assert set(PILOT_META_PHASE1_KEYS) | set(PILOT_META_PHASE2_KEYS) == set(PILOT_META_KEYS)
    assert set(PILOT_META_PHASE1_KEYS) & set(PILOT_META_PHASE2_KEYS) == set()
    assert len(PILOT_META_PHASE1_KEYS) == 7 and len(PILOT_META_PHASE2_KEYS) == 2
    # spec §4 逐字规定：指纹两键必须留到阶段 2
    assert set(PILOT_META_PHASE2_KEYS) == {"schema_sha256", "contract_version"}


def test_both_phases_are_wrapped_in_transactions():
    """两阶段各自**必须**在一个事务里（O4-T2-C1）。

    少了 `transaction()`，asyncpg 每次 execute 都独立自动提交 → 崩在写键中途会留下
    「表已建、只有几行、`state` 缺失」的残骸；它不满足【绝对空】又无合法 `tool`，
    集群闸 (ii) 会拒绝，**整台集群对所有 seed 锁死**。

    ⚠️ `schema_sql` 是**唯一**允许在事务外执行的语句（它自带 BEGIN/COMMIT，见
    `test_schema_sql_is_executed_outside_any_transaction`）——本测试断言除它之外
    没有任何语句逃出事务。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    schema_sql = TOY_SCHEMA_SQL       # 必须是规范文件（O4-R30-C1）
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=schema_sql,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z",
        run_id="run-001"))
    assert target.transactions == 2, f"两阶段各一个事务，实得 {target.transactions}"
    # 除 schema_sql 自身（它自带事务）外，每一条 execute 都必须落在某个事务内
    assert target.executes_outside_transaction == [schema_sql], \
        f"这些语句在事务外执行了: {target.executes_outside_transaction}"


def test_phase1_writes_exactly_seven_keys_phase2_the_other_two():
    """**行为钉**：阶段 1 必须只写 7 个键，指纹两键留到阶段 2（O4-T2-I1）。

    ⚠️ `test_phase_key_sets_partition_the_nine_keys` 只检查**常量**的划分，
    抓不到「常量分好了、写入循环却一次写完九个」——控制者亲验：把写入循环从
    `PILOT_META_PHASE1_KEYS` 改成 `PILOT_META_KEYS` 时，**没有任何测试变红**。
    故本条单独钉住**写入行为**。

    为什么这条重要：spec §5 的 `db_state_initializing` 那一档（O4-F8）的论证前提
    逐字就是「阶段 1 只写 7 个键、schema_sha256/contract_version 尚未写入」。
    一次写完九个，会让「崩在 schema.sql 之前」的残骸带着一份**完整且相符**的指纹，
    与「跑完了的库」在指纹维度上不可区分。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z",
        run_id="run-001"))
    assert set(target.meta_keys_by_phase[1]) == set(PILOT_META_PHASE1_KEYS), \
        f"阶段 1 应恰好写这 7 个键，实得 {sorted(target.meta_keys_by_phase[1])}"
    assert set(target.meta_keys_by_phase[2]) == set(PILOT_META_PHASE2_KEYS), \
        f"阶段 2 应恰好写这 2 个键，实得 {sorted(target.meta_keys_by_phase.get(2, []))}"
    # 指纹两键**绝不能**在阶段 1 出现
    assert "schema_sha256" not in target.meta_keys_by_phase[1]
    assert "contract_version" not in target.meta_keys_by_phase[1]


def test_meta_values_are_correct_not_just_key_names():
    """只断言键名集合的测试抓不到「值写反了」（O4-T2-I2）。

    把 `schema_sha256` 与 `pilot_schema_sha256` 的值写反、或把 `output_dir` 误写成
    `seed` 的值，只验键名的实现全绿。故逐键断言值。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y/",
        created_at="20260729T101530123456Z",
        run_id="run-001"))
    written = {args[0]: args[1] for q, args in target.log if "pilot_meta" in q and "INSERT" in q.upper()}
    assert written == {
        "tool": "qmt_pilot", "seed": "probe",
        "schema_sha256": TOY_SCHEMA_SHA, "pilot_schema_sha256": TOY_PILOT_SCHEMA_SHA,
        "contract_version": CONTRACT_VERSION, "export_log_sha256": "a" * 64,
        "output_dir": "/x/y",                      # ← 尾斜杠必须已剥离
        "created_at": "20260729T101530123456Z", "state": "initializing",
    }


def test_failure_midway_keeps_intent_row_and_closes_connection():
    """崩在建库中途：intent 行**必须保留**（它是下次的销毁授权），连接必须关掉（O4-T2-I3）。

    spec 的设计是「崩了就留孤儿行、由 INTENT_TTL 与 --init-cluster-marker 收口」。
    若异常路径上也把 intent 行删了，下一次同名重跑走零对象例外时第 6 条不成立
    → 自己的残骸自己清不掉。
    """
    class _BoomConn(_RecordingConn):
        async def execute(self, query, *args):
            await super().execute(query, *args)
            if "pilot_meta" in query and "INSERT" in query.upper() and args[0] == "output_dir":
                raise RuntimeError("模拟：写第 4 个键时断连")

    maint, target = _RecordingConn(), _BoomConn()
    with pytest.raises(RuntimeError):
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z",
        run_id="run-001"))
    assert target.closed is True, "finally 必须关掉目标连接"
    assert not any("pilot_create_intent" in q and "DELETE" in q.upper() for q, _ in maint.log), \
        "异常路径上绝不能删 intent 行"
    assert target.rolled_back == 1, "阶段 1 的事务必须回滚"


def _effective_lines(path: pathlib.Path) -> list[str]:
    """**不经过被测分类器**的独立判据：去掉空行与 `--` 行注释后的有效行。"""
    return [ln.strip() for ln in path.read_text().lstrip("\ufeff").splitlines()
            if ln.strip() and not ln.strip().startswith("--")]


def _txn_control_lines(lines: list[str]) -> list[str]:
    """有效行里以事务控制语句开头的那些（独立于被测分类器的朴素判据）。"""
    return [ln for ln in lines
            if ln.upper().startswith(("BEGIN", "COMMIT", "END;", "START TRANSACTION", "ROLLBACK"))]


def test_real_schema_files_have_the_transaction_ownership_the_code_assumes():
    """**用真文件 + 不经过分类器的独立判据**（O4-W2r1）。

    ⚠️ 前一版写的是 `assert _has_own_transaction(真文件)` —— **期望值就是被测分类器本身**，
    分类器判错它也绿。实测那版分类器 7 条探针错 4 条，而这条测试全程是绿的。
    现改为直接看文件的**字面首尾行**，与分类器实现无关。
    """
    repo = pathlib.Path(__file__).resolve().parents[2]
    biz = _effective_lines(repo / "backend/sql/schema.sql")
    assert biz[0].upper().startswith("BEGIN"), f"schema.sql 首条有效语句应为 BEGIN，实得 {biz[0]!r}"
    assert biz[-1].upper().startswith("COMMIT"), f"schema.sql 末条应为 COMMIT，实得 {biz[-1]!r}"
    # ⚠️ 首尾对**不等于**整份被一个事务包住（O4-W3）：`BEGIN;A;COMMIT; NAKED; BEGIN;B;COMMIT;`
    #    首尾同样是 BEGIN/COMMIT。前一版这条「独立判据」与被测分类器**共享同一个盲区**，
    #    三层（守卫 / 本钉 / 探针表）对同一个反例同时失明。故本判据也必须穷尽。
    txn = _txn_control_lines(biz)
    assert len(txn) == 2, f"schema.sql 必须**恰好一对**事务控制语句，实得 {txn}"
    pilot = _effective_lines(repo / "backend/sql/pilot_schema.sql")
    assert _txn_control_lines(pilot) == [], \
        f"pilot_schema.sql 不得含顶层事务控制语句，实得 {_txn_control_lines(pilot)}"


def test_schema_sql_is_executed_outside_any_transaction():
    """**行为钉**：`schema.sql` 必须在事务外执行（O4-W1，真 postgres:15.12 实测）。

    套进 `transaction()` 时，文件里那句 `COMMIT` 会提交掉外层事务，其后语句退化成
    autocommit；而 asyncpg 的 `__aexit__` 在事务已不存在时**静默返回**——
    没有任何测试会红、没有任何运行时错误会提示。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    biz_sql = TOY_SCHEMA_SQL          # = 仓库里的真 schema.sql（规范指纹）
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=biz_sql,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        # ⚠️ 两份都必须是**仓库里的规范文件**（O4-R30-C1）：模块把它们钉到了规范指纹，
        #    自定义 SQL 会在那一关先失败，这颗钉子就测不到「schema.sql 在事务外执行」。
        schema_sha256=TOY_SCHEMA_SHA,
        pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z",
        run_id="run-001"))
    assert biz_sql in target.executes_outside_transaction, \
        "schema.sql 必须在事务外执行，绝不能被 transaction() 包裹"
    assert target.transactions == 2, "阶段 1 与「两键 + ready」仍各自在一个事务里"


@pytest.mark.parametrize("pilot_sql,biz_sql,code", [
    ("BEGIN;\nCREATE TABLE t ();\nCOMMIT;", "BEGIN;\nCREATE TABLE u ();\nCOMMIT;",
     "schema_transaction_conflict"),
    ("CREATE TABLE t ();", "CREATE TABLE u ();", "schema_transaction_missing"),
])
def test_schema_transaction_ownership_is_fail_closed(pilot_sql, biz_sql, code):
    """两条守卫必须 fail-closed：靠约定不行——违反时是**静默**失去原子性，没有任何信号。"""
    maint, target = _RecordingConn(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=biz_sql, pilot_schema_sql=pilot_sql,
            # ⚠️ 指纹要按**这两份 SQL 自己**算：指纹自校（O4-R19-C1）排在事务归属闸之前，
            #    配玩具指纹会先撞 fingerprint_content_mismatch，这颗钉子就测不到它要测的东西。
            schema_sha256=hashlib.sha256(biz_sql.encode("utf-8")).hexdigest(),
            pilot_schema_sha256=hashlib.sha256(pilot_sql.encode("utf-8")).hexdigest(),
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z",
        run_id="run-001"))
    assert ei.value.code == code
    assert maint.log == [], "守卫未过就不许执行任何 DDL（连 intent 行都不写）"


@pytest.mark.parametrize("sql,wrapped,label", [
    ("DO $$\nBEGIN\n  RAISE NOTICE 'x';\nEND $$;\nCREATE TABLE t ();", False, "PL/pgSQL DO 块"),
    ("CREATE FUNCTION g() RETURNS void AS $$\nBEGIN\n  RETURN;\nEND;\n$$ LANGUAGE plpgsql;",
     False, "函数体里的 BEGIN"),
    ("COMMENT ON TABLE t IS $doc$\nBEGIN;\n$doc$;", False, "dollar-quoted 字符串里的字"),
    ("/* apply */ BEGIN;\nCREATE TABLE t ();\n/* done */ COMMIT;", True, "注释前缀的真事务"),
    ("CREATE TABLE early ();\nBEGIN;\nCREATE TABLE u ();\nCOMMIT;", False, "首条 DDL 在事务外"),
    ("BEGIN;\nCREATE TABLE t ();", False, "有 BEGIN 无 COMMIT"),
    ("BEGIN;\nCREATE TABLE t ();\nCOMMIT;", True, "标准形"),
    ("CREATE TABLE t (begin_at TIMESTAMPTZ);", False, "列名含 begin"),
    # ↓ O4-W3：只看首尾的判据对这三条全部判错
    ("BEGIN;\nCREATE TABLE a ();\nCOMMIT;\n"
     "CREATE TABLE naked ();\n"
     "BEGIN;\nCREATE TABLE b ();\nCOMMIT;", False, "多事务块 + 中间裸 DDL"),
    ("BEGIN;\nCREATE TABLE a ();\nROLLBACK;", False, "ROLLBACK 收尾"),
    ("\ufeffBEGIN;\nCREATE TABLE t ();\nCOMMIT;", True, "UTF-8 BOM"),
    ("BEGIN ISOLATION LEVEL SERIALIZABLE;\nCREATE TABLE t ();\nCOMMIT;", True, "BEGIN ISOLATION LEVEL"),
    # ROLLBACK TO SAVEPOINT 是**事务内**动作，不是收尾 —— 误判会拒掉一份合法且被包住的 schema
    ("BEGIN;\nSAVEPOINT s1;\nCREATE TABLE t ();\nROLLBACK TO SAVEPOINT s1;\n"
     "CREATE TABLE u ();\nCOMMIT;", True, "ROLLBACK TO SAVEPOINT（事务内）"),
])
def test_is_wrapped_in_transaction_probe_table(sql, wrapped, label):
    """判据必须是「**整份被一个事务包住**」，不是「含事务关键字」（O4-W2r1）。

    前一版 `^\\s*(BEGIN|COMMIT|…)` 在**原来那 8 条**里错 4 条，两个方向都坏：
      · 前三条判 True（PL/pgSQL 块关键字 / 字符串内容被当成事务）→ **fail-open**：
        `schema.sql` 日后去掉顶层事务但含任一 DO 块，守卫会放行 → DDL 逐条 autocommit；
      · 第四条判 False（真事务认不出）→ 误砖 + 错误信息误导。
    「首条 DDL 在事务外」与「有 BEGIN 无 COMMIT」两条是新判据独有的——
    旧判据对它们都返回 True，而它们**都不满足**代码依赖的那个性质。

    **「多事务块 + 中间裸 DDL」是第二轮修复留下的洞**（O4-W3）：那一版只查首尾两条，
    于是 `BEGIN;A;COMMIT; NAKED; BEGIN;B;COMMIT;` 判 True 放行 —— 中间那条裸 DDL
    各自 autocommit、整份文件失去原子性而无任何信号，**与它本要防的缺陷同类同向**。
    **`ROLLBACK` 收尾**同样曾被放行 → 整份 DDL 被回滚，而建库流程照常写指纹两键 +
    `state='ready'` → 产出一个「ready」却一张业务表都没有的 pilot 库。
    """
    assert _is_wrapped_in_transaction(sql) is wrapped, label


def test_sql_statements_strips_dollar_quoted_before_comments():
    """dollar-quoted 必须**先于**注释剥：`$$ … -- 横杠 … $$` 里的横杠是字符串内容。"""
    assert _transaction_statements("DO $$\nBEGIN -- 这不是注释，是块内容\nEND $$;") == []
    assert _transaction_statements("BEGIN;\nCREATE TABLE t ();\nCOMMIT;") == ["BEGIN", "COMMIT"]


def test_create_requires_proof_of_seed_lock():
    """按 seed 的 advisory lock **在活连接上真验**，不再信调用方传的布尔值（O4-R5-C2）。

    此前签名里有个 `seed_lock_held: bool` —— 传 True 就能绕过。现在改成查 `pg_locks`：
    键派生与 spec §4 的 `pg_try_advisory_lock(hashtext('kline_pilot_' || seed))` 一致。
    没有它时，两次同 seed 的运行会互相覆盖 `pilot_create_intent` 行，
    而零对象例外第 6 条**据那一行授权 DROP DATABASE**。
    """
    maint, target = _RecordingConn(seed_lock_held=False), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z",
            run_id="run-001"))
    assert ei.value.code == "seed_lock_not_held"
    assert not any("CREATE DATABASE" in q for q, _ in maint.log), "锁未持有时绝不建库"


def test_create_runs_the_cluster_gate_itself():
    """集群闸必须**在 create_pilot_database 内部**机器强制（O4-R5-C2）。

    此前它只是 docstring 里的「调用方须先跑」—— 任何接线失误都能在**未过集群闸**
    的情况下直接在传进来的 DSN 上建库，标记闸 / 无关库闸 / 维护库空闸全被跳过。
    """
    # 维护库自身脏（闸 (iii) 应拒）
    maint = _RecordingConn(exempt_objects=[("pg_class", 1)])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": _RecordingConn()}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-001"))
    assert ei.value.code == "maintenance_db_not_empty"
    assert maint.log == [], "集群闸未过就不许写 intent 行、不许建库"

    # 集群里有无关库（闸 (ii) 应拒）
    maint2 = _RecordingConn(databases=["production_db"])
    with pytest.raises(PilotClusterBoundaryError) as ei2:
        asyncio.run(create_pilot_database(
            maint2, connect=_connector({"kline_pilot_probe": _RecordingConn()}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-001"))
    assert ei2.value.code == "unrelated_database"
    assert maint2.log == []


def test_create_rejects_empty_run_id():
    """`run_id` 是 intent 行的归属凭据，空值等于没有归属。"""
    maint, target = _RecordingConn(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z",
            run_id=""))
    assert ei.value.code == "run_id_missing"
    assert maint.log == []


@pytest.mark.parametrize("sqlstate,should_delete,label", [
    ("42P04", True, "duplicate_database —— 库本来就在，不是本次建的"),
    ("42501", True, "insufficient_privilege —— 角色没有 CREATEDB"),
    ("3D000", True, "invalid_catalog_name —— 模板库不存在"),
    (None, False, "无 sqlstate（连接丢失）—— 库**可能**已建出来，必须保留"),
    ("08006", False, "connection_failure —— 同上，歧义失败"),
])
def test_intent_row_rollback_only_on_definite_create_failure(sqlstate, should_delete, label):
    """`CREATE DATABASE` 失败时，intent 行的去留必须按「是否确定没建成」分档（O4-R7-C1）。

    **为什么这条重要**：集群闸**跳过目标库**（那是闸 0−/0/0b 的职责），所以
    「目标库本就存在」这一档能一路走到 `CREATE DATABASE`。此时若把 intent 行留下，
    它就变成一张「这是我的崩溃残骸」的凭据 —— 而本次**什么都没造**。
    之后 `--reset` 会凭它把**别人建的**同名空库当成本次残骸，
    **无 pilot_meta 归属、无 --reset-foreign 令牌**地 DROP 掉。

    反过来，歧义失败（连接丢失）必须**保留** —— 那时库可能真的建出来了，
    而 intent 行是「清理我自己残骸」的唯一授权。宁可多留（有 TTL 兜底），不可错删。
    """
    class _CreateFails(_RecordingConn):
        async def execute(self, query, *args):
            if "CREATE DATABASE" in query:
                exc = RuntimeError("模拟建库失败")
                if sqlstate is not None:
                    exc.sqlstate = sqlstate
                raise exc
            return await super().execute(query, *args)

    maint, target = _CreateFails(), _RecordingConn()
    with pytest.raises(RuntimeError):
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    deleted = [a_ for q, a_ in maint.log
               if "pilot_create_intent" in q and "DELETE" in q.upper()]
    if should_delete:
        assert deleted == [("kline_pilot_probe", "run-007")], f"{label} → 应撤回 intent 行"
    else:
        assert deleted == [], f"{label} → 必须保留 intent 行"


def test_create_refuses_to_steal_a_fresh_foreign_intent_row():
    """既有 intent 行**新鲜且不属于本次运行** → RETURNING 为空 → 拒绝启动（O4-C2）。

    裸 `ON CONFLICT DO UPDATE` 会把别人的 DROP 授权转到本次运行名下。
    """
    class _ForeignIntent(_RecordingConn):
        async def fetchval(self, query, *args):
            if "pilot_create_intent" in query and "INSERT" in query.upper():
                return None          # 冲突且对方新鲜 → 未接管
            return await super().fetchval(query, *args)

    maint, target = _ForeignIntent(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z",
            run_id="run-002"))
    assert ei.value.code == "intent_row_conflict"
    assert not any("CREATE DATABASE" in q for q, _ in maint.log), "冲突时绝不建库"


def test_intent_delete_is_keyed_by_run_id():
    """收尾删 intent 行必须**带 run_id 条件**，否则会删掉别人那条（O4-C2）。"""
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z",
        run_id="run-003"))
    dels = [(q, a) for q, a in maint.log if "pilot_create_intent" in q and "DELETE" in q.upper()]
    assert len(dels) == 1
    assert "run_id" in dels[0][0], "DELETE 必须带 run_id 条件"
    assert dels[0][1] == ("kline_pilot_probe", "run-003")


def test_lexer_ignores_dollar_markers_inside_comments():
    """**codex 复现的那条**（O4-C1）：注释里两个 `$$` 曾把它们之间的整段真 SQL 吞掉。

    前一版先正则剥 dollar-quoted、再剥注释，于是守卫对下面这份判 True 放行，
    而 PostgreSQL 看到的是「一个事务 + 一条裸 DDL + 一个以 ROLLBACK 收尾的事务」——
    建库流程随后照常写 `state='ready'`，产出一个**「ready」却缺表**的库。
    本仓的中文注释里提到「`DO $$ … $$` 块」是很自然的写法（本模块自己就有）。
    """
    evil = ("BEGIN;\nCREATE TABLE a ();\n-- 说明里提到 $$ 块\nCOMMIT;\n"
            "CREATE TABLE naked ();\n"
            "BEGIN;\nCREATE TABLE b ();\nROLLBACK;\n-- 又提了一次 $$\nCOMMIT;")
    assert _is_wrapped_in_transaction(evil) is False
    # 字符串字面量里的分号与关键字同样不得干扰（这两条此前只被登记为「已知盲区」）
    assert _is_wrapped_in_transaction(
        "BEGIN;\nCOMMENT ON TABLE t IS 'a; BEGIN 散文';\nCREATE TABLE t ();\nCOMMIT;") is True
    assert _transaction_statements("COMMENT ON TABLE t IS 'a; BEGIN 散文';") == []
    # 嵌套块注释
    assert _is_wrapped_in_transaction(
        "/* 外 /* 嵌套 */ 仍在注释 */ BEGIN;\nCREATE TABLE t ();\nCOMMIT;") is True


def test_create_pilot_database_rejects_illegal_name_before_any_ddl():
    maint, target = _RecordingConn(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({}),
            db_name="production_db", seed="probe",
            schema_sql="", pilot_schema_sql="",
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z",
        run_id="run-001"))
    assert ei.value.code == "illegal_db_name"
    assert maint.log == [], "护栏未过就不许执行任何 DDL"


def test_create_pilot_database_writes_all_nine_meta_keys():
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z",
        run_id="run-001"))
    written = {args[0] for q, args in target.log if "pilot_meta" in q and "INSERT" in q.upper()}
    assert written == set(PILOT_META_KEYS), f"九键缺 {set(PILOT_META_KEYS) - written}"


# ---------------------------------------------------------------------------
# O4-R8：【维护库专用表集合】的结构证明 + 建库确认（create_confirmed）
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("broken_key,label", [
    ("marker_is_table", "marker 不是普通表（视图/外表也能返回一行 magic string）"),
    ("marker_purpose_text", "marker.purpose 不是 text"),
    ("marker_purpose_unique", "marker.purpose 没有主键/唯一约束 —— 可塞任意多行"),
    ("intent_is_table", "intent 表缺失"),
    ("intent_columns_ok", "intent 列不全或类型不对（少了 create_confirmed / db_oid 等）"),
    ("intent_dbname_unique", "intent.dbname 无唯一约束 —— ON CONFLICT 的抢占语义整个塌掉"),
    ("registry_is_table", "registry 表缺失 —— 闸 (ii) 的外部凭据无处可查"),
    ("registry_columns_ok", "registry 列不全或类型不对"),
    ("registry_dbname_unique", "registry.dbname 无唯一约束 —— 同名可塞多行"),
    # ⚠️ 耐久性判据**每表一条**：三张各配一档。这三档对「别名拆没拆」本身
    #    **零判别力**（假件把整个字典交回，闸 (i) 做的是 `all(shape.values())`，
    #    与真 SQL 的别名无关）—— 加它们是为了让假件与 SQL 一一对应。
    #    拆分本身的判别力由 `test_every_guard_table_shape_proof_covers_table_level_durability`（机械，读真 SQL 文本）
    #    与 Task 3 的混合态用例（行为）提供。
    ("marker_durable",
     "pilot_cluster_marker 被 SET UNLOGGED / 挂 RLS / 换表空间"),
    ("intent_durable",
     "pilot_create_intent 被 SET UNLOGGED —— 崩溃后 intent 行被 truncate，"
     "而它是零对象例外授权 DROP DATABASE 的凭据（O4-R37-C2）"),
    ("registry_durable",
     "pilot_database_registry 被 SET UNLOGGED —— 崩溃后归属登记消失，"
     "既有 pilot 库在闸 (ii) 里变成外来物"),
])
def test_cluster_gate_i_requires_shape_proof_of_both_maintenance_tables(broken_key, label):
    """闸 (i) 必须先证**结构**再读值（O4-R8-C1）。

    此前这里的注释写着「先验形状再读值」，而代码**只读了值** ——
    一行 magic string 塞进任意关系（视图、无主键的表、别人留下的同名旧表）
    就能把整台集群授权成「一次性可弃」。而 pilot_create_intent 的结构
    从来没被验过，它却是 DROP 授权的载体：dbname 没有唯一约束时，
    「抢占别人的 intent 行」那套 ON CONFLICT 判据根本不成立。
    """
    shape = dict(_OK_MAINTENANCE_SHAPE)
    shape[broken_key] = False
    conn = _FakeConn(maintenance_shape=shape)
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}), target_db=None))
    assert ei.value.code == "no_marker", label
    assert broken_key in str(ei.value), "报错必须点名是哪一项结构不合规"


def test_cluster_gate_i_shape_proof_runs_before_reading_the_marker_value():
    """结构不合规时**不许**去读 marker 的值 —— 否则「先证后读」只是文字（O4-R8-C1）。"""
    class _CountingConn(_FakeConn):
        marker_reads = 0

        async def fetch(self, query, *args):
            if "pilot_cluster_marker" in query and "to_regclass" not in query:
                type(self).marker_reads += 1
            return await super().fetch(query, *args)

    _CountingConn.marker_reads = 0
    conn = _CountingConn(maintenance_shape=dict(_OK_MAINTENANCE_SHAPE,
                                               marker_purpose_unique=False))
    with pytest.raises(PilotClusterBoundaryError):
        asyncio.run(assert_cluster_allowed(conn, connect=_connector({}), target_db=None))
    assert _CountingConn.marker_reads == 0, "结构没过就读了 marker 值 = 判据顺序反了"


def test_create_marks_intent_confirmed_only_after_create_database_succeeds():
    """create_confirmed 必须在 `CREATE DATABASE` **之后**置 true（O4-R8-C2）。

    intent 行写在建库**之前**，所以它单独存在证明不了「这库是本次建的」。
    只有确认建成之后置的 true 才是可信凭据；4a-2 的零对象例外只认 true。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-007"))
    order = [q for q, _ in maint.log
             if "CREATE DATABASE" in q or "create_confirmed = true" in q]
    assert len(order) == 2, f"建库与确认各应恰好一次，实得 {order}"
    assert "CREATE DATABASE" in order[0] and "create_confirmed = true" in order[1], \
        "确认必须排在建库之后"


def test_intent_cleanup_failure_does_not_replace_the_original_create_error():
    """撤回 intent 行失败时，**原始建库错误必须原样抛出**（O4-R8-C2）。

    否则「库已存在」会被报成「删行失败」，整个排障方向被带偏；
    而这一行即便留下也授权不了 DROP —— 它的 create_confirmed 仍是 false。
    """
    class _BothFail(_RecordingConn):
        async def execute(self, query, *args):
            if "CREATE DATABASE" in query:
                exc = RuntimeError("原始错误：库已存在")
                exc.sqlstate = "42P04"
                raise exc
            if "pilot_create_intent" in query and "DELETE" in query.upper():
                raise RuntimeError("清理时连接抖了")
            return await super().execute(query, *args)

    maint, target = _BothFail(), _RecordingConn()
    with pytest.raises(RuntimeError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert "原始错误：库已存在" in str(ei.value), \
        f"清理异常盖掉了原始错误：{ei.value}"


def test_intent_insert_writes_create_confirmed_false():
    """intent 行**首次**落库时 create_confirmed 必须显式为 false（O4-R8-C2 / R9-C1）。

    默认值靠得住与否取决于表定义，而表定义是可以被换掉的 ——
    闸 (i) 的结构证明管住了「列在不在」，写入侧再把值钉死。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-007"))
    inserts = [q for q, _ in maint.log
               if "INSERT INTO public.pilot_create_intent" in q]
    assert len(inserts) == 1, f"intent 插入应恰好一次，实得 {inserts}"
    # ⚠️ 必须**按子句切分**再断言：整条语句里 ON CONFLICT 分支也含 create_confirmed=false，
    #    「'false' in 整条语句」会被那一半满足，把 VALUES 子句的钉子变成空的（本条已被
    #    mutation 抓过一次：去掉 VALUES 的列仍全绿）。
    head, _, tail = inserts[0].partition("ON CONFLICT")
    assert tail, "语句里没有 ON CONFLICT 分支，切分前提不成立"
    assert "create_confirmed" in head and "false" in head, \
        f"VALUES 子句未显式写 create_confirmed=false：{head}"
    # ⚠️ ON CONFLICT 分支**不是**无条件打回 false（O4-R9-C1 推翻了上一版这条要求）：
    #    同 run_id 重入必须保住已有的确认，否则紧接着的 duplicate_database 会走进
    #    确定性失败清理把行删掉，空残骸从此没有任何销毁授权。
    assert "pg_database" in tail and "create_confirmed" in tail, \
        f"ON CONFLICT 分支必须按「库是否还存在」决定确认位的去留：{tail}"
    assert "create_confirmed = false" not in tail, \
        "无条件打回 false = 同 run 重试自毁恢复凭据"


def test_source_guard_intent_predicates_survive_future_edits():
    """源码守卫（O4-R9-C1）：两条谓词一旦被改回去，整条恢复链就断。

    ⚠️ **这是文本钉子，不是行为钉子** —— 它证明不了 SQL 语义正确。
    行为由 verify_pilot_two_phase_create.py 的场景 ⑪ 在真 PG 上钉住
    （同 run 重试后凭据仍在且仍为 true）。但那个脚本是**手工跑**的、CI 看不见，
    所以这里留一颗 CI 可见的守卫：把「无条件 create_confirmed = false」
    或「不带 NOT create_confirmed 的 DELETE」改回来会当场变红。
    """
    import qmt_pilot_db as m
    ins = " ".join(m._INSERT_INTENT_SQL.split())
    # ⚠️ R18-C3 取代了 R9-C1 的规则：确认位的去留只看「它指的那个库现在还在不在」，
    #    不再看 run_id。按 run_id 判会在**过期抢占**这一档抹掉恢复凭据。
    assert "create_confirmed = (public.pilot_create_intent.create_confirmed" in ins, \
        "ON CONFLICT 分支必须以**已有的确认位**为起点，不能无条件写 false"
    assert "EXISTS (SELECT 1 FROM pg_database" in ins, \
        "确认位必须按「库是否还存在」判 —— 按 run_id 判会在过期抢占时抹掉恢复凭据"
    assert "create_confirmed = false" not in ins.split("VALUES")[-1], \
        "ON CONFLICT 分支不得把 create_confirmed 无条件打回 false"
    dele = " ".join(m._DELETE_INTENT_SQL.split())
    assert "AND NOT create_confirmed" in dele, \
        "确定性失败的撤回必须只删**未确认**的行 —— 删掉已确认的行 = 自锁在门外"


# ---------------------------------------------------------------------------
# O4-R10：成功收尾必须真的删掉 intent 行 + ABORT/PREPARE TRANSACTION
# ---------------------------------------------------------------------------

def test_clean_success_uses_unguarded_delete_and_verifies_rowcount():
    """干净收尾用的是**不带 NOT create_confirmed** 的清理（O4-R10-C1）。

    成功建库的行必然已 confirmed，用撤回那条 SQL 删它**永远匹配 0 行** ——
    每一次正常成功的运行都会留下一行「新鲜且已确认」的 intent：
    它既把后来者当外来行挡住，又是一张对同名空库的销毁授权。
    这是 R9 修复引入的回归（给撤回加谓词时忘了成功路径复用同一常量）。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-007"))
    deletes = [q for q, _ in maint.log
               if "pilot_create_intent" in q and q.strip().upper().startswith("DELETE")]
    assert len(deletes) == 1, f"成功路径应恰好发一条清理，实得 {deletes}"
    assert "NOT create_confirmed" not in deletes[0], \
        "成功收尾用了撤回专用的 SQL —— 它永远匹配 0 行，留下一张持久的销毁授权"


def test_clean_success_raises_when_intent_row_survives_cleanup():
    """清理没能真正删掉那一行时必须报错（O4-R10-C1 → R12-C2 升级为读后验）。

    R9 那次回归之所以能溜过去，正是因为没人看 DELETE 报了几行 ——
    语句照发不误，只是一行都没匹配上。而判据现在不是「报了几行」而是
    「**这一行真的不在了吗**」，故假件在这里如实建模「行还在」。
    """
    class _DeleteMatchesNothing(_RecordingConn):
        def __init__(self, **kw):
            super().__init__(**kw)
            self.intent_row_still_there = True

        def command_status(self, query):
            if "pilot_create_intent" in query and query.strip().upper().startswith("DELETE"):
                return "DELETE 0"
            return super().command_status(query)

    maint, target = _DeleteMatchesNothing(), _RecordingConn()
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "intent_not_cleared"
    assert "已经建好并 ready、可以正常使用" in str(ei.value), \
        "报错必须说清库是好的，否则操作者会以为建库失败而重来一遍"
    assert "DELETE 0" in str(ei.value), "必须带上命令状态，否则排障没有线索"


@pytest.mark.parametrize("sql,label", [
    ("BEGIN;\nCREATE TABLE a ();\nABORT;\nCREATE TABLE naked ();\nCOMMIT;",
     "ABORT 是 ROLLBACK 的别名 —— 它之后的 DDL 在任何事务之外，之前的 DDL 已被丢弃"),
    ("BEGIN;\nCREATE TABLE a ();\nPREPARE TRANSACTION 'gid1';\nCREATE TABLE naked ();\nCOMMIT;",
     "PREPARE TRANSACTION 把事务交出去 —— 之后的 DDL 不在它里面"),
])
def test_transaction_guard_sees_abort_and_prepare_transaction(sql, label):
    """事务分类器必须认出所有顶层终止语句（O4-R10-C2）。

    识别集合漏掉它们时，`_transaction_statements` 只数到一对，
    「恰好一对」的判据就成了 **fail-open** —— 与它本要防的缺陷同类同向。
    """
    assert not _is_wrapped_in_transaction(sql), label


@pytest.mark.parametrize("stmt", ["ABORT;", "PREPARE TRANSACTION 'gid1';"])
def test_pilot_schema_side_also_sees_them(stmt):
    """pilot_schema_sql 侧同样必须看见（O4-R10-C2）—— 它是**禁止自带事务**那一侧。"""
    assert _transaction_statements(stmt), \
        f"{stmt!r} 没被认成事务控制 → pilot_schema 可以偷偷自带事务控制而不触发拒绝"


def test_transaction_guard_still_accepts_legitimate_savepoints():
    """SAVEPOINT / ROLLBACK TO 是**事务内**动作，不得被新识别集合误判（防过度收紧）。"""
    assert _is_wrapped_in_transaction(
        "BEGIN;\nSAVEPOINT s1;\nCREATE TABLE a ();\nROLLBACK TO s1;\nCOMMIT;")


def test_bare_prepare_is_not_transaction_control():
    """裸 `PREPARE p AS …` 是预备语句，与事务无关 —— 不得被 `PREPARE TRANSACTION` 的规则误收。"""
    assert _transaction_statements("PREPARE p AS SELECT 1;") == []


# ---------------------------------------------------------------------------
# O4-R11：词法器覆盖引号标识符 + 确认写入核行数
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("sql,wrapped,label", [
    ('BEGIN; CREATE TABLE "$x$" (); ROLLBACK; CREATE TABLE naked (); '
     'BEGIN; CREATE TABLE "$x$2" (); COMMIT;', False,
     "引号标识符里的 $x$ 被当成 dollar-quoted 开头 → 中间 ROLLBACK+裸 DDL+第二个 BEGIN 被整段吞掉"),
    ('BEGIN; CREATE TABLE U&"$x$" (); ROLLBACK; CREATE TABLE naked (); '
     'BEGIN; CREATE TABLE U&"$x$2" (); COMMIT;', False,
     "U&\"…\" 是同一个洞"),
    ('BEGIN; CREATE TABLE "a;b" (); CREATE TABLE c (); COMMIT;', True,
     "标识符里的分号不得被当成语句分隔（防过度收紧）"),
    ('BEGIN; CREATE TABLE "a""b" (); CREATE TABLE c (); COMMIT;', True,
     '标识符里的 "" 转义（防过度收紧）'),
])
def test_lexer_handles_quoted_identifiers(sql, wrapped, label):
    """`;` 能藏身的词法环境必须照 PG 手册枚举齐（O4-R11-C1）。

    此前 docstring 列的支持形式**本身就漏了双引号标识符**，而没人拿它跟 PG 的
    词法清单对过 —— 这是同一族失败的第三次（注释里的 $$ → 只看首尾 → 引号标识符）。
    """
    assert _is_wrapped_in_transaction(sql) is wrapped, label


def test_create_raises_when_confirmation_write_matched_no_row():
    """确认凭据写入报「0 行」时必须报错（O4-R11-C2，与收尾清理对称）。

    并发的另一次运行把 intent 行抢走/删掉时这里是 `UPDATE 0`。若照常往下走、
    随后崩在写 pilot_meta 之前，就留下一个**没有恢复凭据的空库**：
    零对象例外认不出它，可自愈的残骸变成人工清理 + 挡住同名重建。
    """
    class _ConfirmMatchesNothing(_RecordingConn):
        def command_status(self, query):
            if "create_confirmed = true" in query:
                return "UPDATE 0"
            return super().command_status(query)

    maint, target = _ConfirmMatchesNothing(), _RecordingConn()
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "intent_not_confirmed"
    assert "已经建出来了" in str(ei.value), "报错必须说清库已建出，否则操作者不会去删它"
    # 失败必须**先于**任何目标库副作用 —— 否则报错说「请人工删」而库里已有半套表
    assert not target.log, f"确认失败后不该再碰目标库，实得 {[q for q, _ in target.log][:3]}"


def test_clean_success_tolerates_delete_zero_when_row_is_already_gone():
    """`DELETE 0` 但那一行**本来就不在**时不得报错（O4-R12-C2 的对偶）。

    判据是「行不在了」，不是「DELETE 报 1」。上一次尝试已经删掉、或异常发生在
    提交之后，都会走到这一档。把它判成失败会让一次完全成功的建库报错。
    """
    class _DeleteZeroButGone(_RecordingConn):
        def command_status(self, query):
            if "pilot_create_intent" in query and query.strip().upper().startswith("DELETE"):
                return "DELETE 0"
            return super().command_status(query)

    maint, target = _DeleteZeroButGone(), _RecordingConn()   # intent_row_still_there=False
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-007"))


def test_clean_success_cleanup_exception_becomes_boundary_error_not_raw():
    """ready 之后清理抛异常时，不得让裸异常逃出去（O4-R12-C2）。

    此刻库**已经可用**。裸异常会让调用方当成「建库失败」而重来一遍，
    而真实情况是一个好库 + 一行残留的销毁授权。
    """
    class _CleanupExplodes(_RecordingConn):
        def __init__(self, **kw):
            super().__init__(**kw)
            self.intent_row_still_there = True

        async def execute(self, query, *args):
            if "pilot_create_intent" in query and query.strip().upper().startswith("DELETE"):
                raise RuntimeError("维护连接在收尾时断了")
            return await super().execute(query, *args)

    maint, target = _CleanupExplodes(), _RecordingConn()
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "intent_not_cleared"
    assert "已经建好并 ready、可以正常使用" in str(ei.value), \
        "报错必须说清库是好的，否则操作者会重来一遍"
    assert "维护连接在收尾时断了" in str(ei.value), "原始异常必须带上，否则排障没有线索"


@pytest.mark.parametrize("sql,wrapped,label", [
    ("BEGIN; CREATE TABLE a$x$ (); ROLLBACK; CREATE TABLE naked (); "
     "BEGIN; CREATE TABLE b$x$ (); COMMIT;", False,
     "PG 允许 $ 出现在无引号标识符里：`CREATE TABLE a$x$ ()` 的表名字面就是 a$x$（真 PG 实测）"),
    ("BEGIN; DO $$ BEGIN NULL; END $$; CREATE TABLE a (); COMMIT;", True,
     "真 DO 块不得被误拒"),
    ("BEGIN; SELECT $_a$x;y$_a$; CREATE TABLE a (); COMMIT;", True,
     "$_a$ 是合法 tag（下划线起头）"),
    ("BEGIN; SELECT $标签$x;y$标签$; CREATE TABLE a (); COMMIT;", True,
     "非 ASCII 字母也是合法 tag（真 PG 实测通过）"),
    ("BEGIN; SELECT $1$; ROLLBACK; CREATE TABLE naked (); "
     "BEGIN; SELECT $1$; CREATE TABLE a (); COMMIT;", False,
     "数字起头的 $1$ 不是 tag（真 PG 对 $1$abc$1$ 报 unterminated）——"
     "放宽成 \\w* 时这里会被吞成 BEGIN/CREATE TABLE a/COMMIT 而判「被包住」"),
])
def test_dollar_quote_requires_token_boundary_and_valid_tag(sql, wrapped, label):
    """dollar-quote 只在 token 边界上、且 tag 合法时才成立（O4-R12-C1）。

    三条判据都在真 PostgreSQL 15.12 上量过，不是照文档推的：
    `CREATE TABLE a$x$ (id int)` 建出的表名是 `a$x$`；`DO$$ … $$` 报语法错；
    `$1$abc$1$` 报 unterminated（`$1` 是位置参数不是 tag）。
    """
    assert _is_wrapped_in_transaction(sql) is wrapped, label


# ---------------------------------------------------------------------------
# O4-R13：同侪 pilot 库的归属证明 + pilot_schema 结构证明
# ---------------------------------------------------------------------------

def _meta_rows(**over):
    """形状合规、键齐全的 pilot_meta 行（阶段 1 的 7 键）。"""
    base = {"tool": "qmt_pilot", "seed": "other", "export_log_sha256": "a" * 64,
            "output_dir": "/x/y", "created_at": "20260729T101530123456Z",
            "pilot_schema_sha256": "c" * 64, "state": "ready"}
    base.update(over)
    return [{"key": k, "value": v} for k, v in base.items() if v is not None]


def test_cluster_gate_ii_rejects_forged_single_key_pilot_meta():
    """**形状合规**但只有一行 ('tool','qmt_pilot') 的库不得被当成本工具建的（O4-R13-C1）。

    此前判据只是 `meta.get("tool") == "qmt_pilot"` —— 一个静态且可猜的标记，
    塞进任意非空库的合规 pilot_meta 里就能让它跳过闸 (ii)，
    「这台集群除本工具外别无他物」的判据被整个掏空。
    （既有那颗钉子靠的是 key 无唯一约束，走的是**形状**分支；本档形状完全合规。）
    """
    forged = _FakeConn(meta_rows=[{"key": "tool", "value": "qmt_pilot"}],
                       user_objects=[("pg_class", 3)])      # 非空 → 不走残骸豁免
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": forged}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_cluster_gate_ii_rejects_pilot_meta_whose_seed_does_not_match_db_name():
    """`seed` 与库名后缀不符 → 不是这个库的标记（O4-R13-C1）。

    从别处（另一个真 pilot 库）整份抄来的 pilot_meta 正是靠这一条被挡住。
    """
    stolen = _FakeConn(meta_rows=_meta_rows(seed="someone_else"),
                       user_objects=[("pg_class", 3)])
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": stolen}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


@pytest.mark.parametrize("state", ["ready", "initializing"])
def test_cluster_gate_ii_accepts_genuine_pilot_db_in_both_states(state):
    """**防过度收紧**：键齐、seed 相符、state 合法的真 pilot 库必须放行（O4-R13-C1）。

    `initializing` 那一档尤其重要：那是崩溃残骸的合法形态（只有阶段 1 的 7 键）。
    若要求「9 键齐全」，残骸会被判成外来物 → 整台集群对**所有** seed 被挡住 ——
    正是 R55-F1 那个锁死换形态复发。
    """
    genuine = _FakeConn(meta_rows=_meta_rows(state=state), user_objects=[("pg_class", 3)])
    conn = _FakeConn(databases=["kline_pilot_other"])
    asyncio.run(assert_cluster_allowed(
        conn, connect=_connector({"kline_pilot_other": genuine}),
        target_db="kline_pilot_probe"))


@pytest.mark.parametrize("missing", list(PILOT_META_PHASE1_KEYS))
def test_cluster_gate_ii_requires_every_phase1_key(missing):
    """阶段 1 的 7 键**逐个**都是归属判据的一部分（O4-R13-C1）。"""
    partial = _FakeConn(meta_rows=[r for r in _meta_rows() if r["key"] != missing],
                        user_objects=[("pg_class", 3)])
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": partial}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database", f"缺 {missing} 时应判非归属"


def test_cluster_gate_ii_rejects_unknown_state_value():
    """`state` 只能是本工具会写出的两个值（O4-R13-C1）。"""
    weird = _FakeConn(meta_rows=_meta_rows(state="whatever"), user_objects=[("pg_class", 3)])
    conn = _FakeConn(databases=["kline_pilot_other"])
    with pytest.raises(PilotClusterBoundaryError):
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": weird}),
            target_db="kline_pilot_probe"))


@pytest.mark.parametrize("broken", ["meta_is_table", "meta_key_unique", "meta_columns_ok",
                                    "source_is_table", "source_columns_ok", "source_key_unique",
                                    "pilot_tables_durable"])
def test_create_rejects_malformed_pilot_schema_before_writing_anything(broken):
    """apply 完 pilot_schema_sql 必须先证结构再写键（O4-R13-C2）。

    **执行过 DDL ≠ 结构就对**：文件漂移/读错会建出「有 pilot_meta 没有
    pilot_stock_source」或「pilot_meta 没有主键」的库，而后续照常写完 9 键 +
    state='ready' —— 对外宣称 ready，归属/来源表却是坏的。
    """
    shape = dict(_OK_PILOT_SHAPE)
    shape[broken] = False

    class _BadSchema(_RecordingConn):
        def __init__(self, **kw):
            super().__init__(**kw)
            self.pilot_schema_shape = shape

    maint, target = _RecordingConn(), _BadSchema()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "pilot_schema_malformed"
    assert broken in str(ei.value), "报错必须点名是哪一项结构不合规"
    assert not target.meta_keys_by_phase, \
        f"结构没过就写了键：{target.meta_keys_by_phase} —— 判据顺序反了"


def test_create_rejects_when_ready_update_matched_no_row():
    """置 `state='ready'` 报 0 行时必须整体回滚（O4-R13-C2）。

    `state` 行若不在（被并发删掉/阶段 1 的键被动过），UPDATE 报 0 行而**不报错** ——
    库随后被当成 ready 交付，实际 state 仍是 initializing 或干脆没有。
    """
    class _ReadyMatchesNothing(_RecordingConn):
        def command_status(self, query):
            if "SET value = 'ready'" in query:
                return "UPDATE 0"
            return super().command_status(query)

    maint, target = _RecordingConn(), _ReadyMatchesNothing()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "ready_not_set"


# ---------------------------------------------------------------------------
# O4-R14：闸 (ii) 的外部归属凭据（维护库侧登记）
# ---------------------------------------------------------------------------

def test_cluster_gate_ii_rejects_fully_forged_seven_key_meta_when_not_registered():
    """**7 键齐全、seed 相符、state 合法**的伪造 pilot_meta，若库名没被登记过 → 拒（O4-R14-C1）。

    R13 把自证判据收紧了，但读的仍全是「被判对象自己写的字」—— 对手照抄一遍即可。
    故还要求一个**它改不到**的事实：这个库名在维护库的 pilot_database_registry 里
    确实被本工具声明过。两个独立事实同时成立才放行。
    """
    forged = _FakeConn(meta_rows=_meta_rows(), user_objects=[("pg_class", 3)])   # 非空
    conn = _FakeConn(databases=["kline_pilot_other"], registered_dbnames=set())  # 一个都没登记
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": forged}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_cluster_gate_ii_accepts_registered_and_self_consistent_peer():
    """**防过度收紧**：登记过 + 自证合规的真 pilot 库必须放行（O4-R14-C1）。"""
    genuine = _FakeConn(meta_rows=_meta_rows(), user_objects=[("pg_class", 3)])
    conn = _FakeConn(databases=["kline_pilot_other"],
                     registered_dbnames={"kline_pilot_other"})
    asyncio.run(assert_cluster_allowed(
        conn, connect=_connector({"kline_pilot_other": genuine}),
        target_db="kline_pilot_probe"))


def test_cluster_gate_ii_still_requires_self_attestation_even_when_registered():
    """登记过**不能单独**放行 —— 两个事实都要（O4-R14-C1）。

    登记表只记「本工具声明过这个库名」；那次建库可能失败了，之后别人用同名建了库。
    """
    impostor = _FakeConn(meta_rows=_meta_rows(seed="someone_else"),
                         user_objects=[("pg_class", 3)])
    conn = _FakeConn(databases=["kline_pilot_other"],
                     registered_dbnames={"kline_pilot_other"})
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": impostor}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"


def test_create_registers_the_db_name_only_after_create_succeeded():
    """登记必须写在 `CREATE DATABASE` **成功之后**（O4-R15-C1，纠正 R14 的写法）。

    集群闸**跳过目标库**，所以「目标库是别人的、本就存在」这一档能一路走到
    `CREATE DATABASE`。若登记写在之前，随后的 42P04 只撤 intent，**登记行永久留下** ——
    一次失败的建库就把一个外来库从「拒」变成了「信」。
    R14 写在之前的理由（「否则建成了但没登记会锁死」）**前提不成立**：
    那个窗口留下的库必然是空的，闸 (ii) 的「零用户对象即残骸」豁免会放行它。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-007"))
    order = [q for q, _ in maint.log
             if "pilot_database_registry" in q or "CREATE DATABASE" in q]
    assert len(order) == 2, f"登记与建库各应恰好一次，实得 {order}"
    assert "CREATE DATABASE" in order[0] and "pilot_database_registry" in order[1], \
        "登记必须排在建库成功之后"
    # ⚠️ 从 DO NOTHING 改成 DO UPDATE（O4-R16-C2）：--reset 重建同名库时 OID 变了，
    #    不改写的话本工具**自己刚建的库**会被自己的闸 (ii) 判成外来物。
    assert "ON CONFLICT (dbname) DO UPDATE" in order[1], "登记必须可重入且改写到新实例"
    assert "db_oid = EXCLUDED.db_oid" in order[1], "重建同名库时必须把 OID 改写成新实例的"


def test_registry_is_never_deleted_anywhere_in_the_module():
    """源码守卫：本工具**从不清**登记表（O4-R14-C1）。

    ⚠️ 文本钉子。清掉它等于把既有 pilot 库判成外来物 → 整台集群被挡住，
    而这种锁死在测试里不会自己冒出来（要有一个「上一次运行留下的库」才能观察到）。
    """
    import qmt_pilot_db as m
    src = pathlib.Path(m.__file__).read_text()
    for stmt in re.findall(r"(?i)\b(DELETE\s+FROM|TRUNCATE|DROP\s+TABLE)\s+[\w.]*pilot_database_registry", src):
        raise AssertionError(f"模块里出现了清理登记表的语句：{stmt}")


def test_failed_create_leaves_no_registry_proof():
    """建库失败**不得**留下登记行（O4-R15-C1）。

    集群闸跳过目标库 → 「目标库是别人的、本就存在」这一档能走到 `CREATE DATABASE`。
    若那时登记行已落库，42P04 之后它永久留下，把一个外来库从「拒」变成「信」——
    正是这张表被引入来防的那件事。
    """
    class _CreateFails(_RecordingConn):
        async def execute(self, query, *args):
            if "CREATE DATABASE" in query:
                exc = RuntimeError("库本来就在（别人的）")
                exc.sqlstate = "42P04"
                raise exc
            return await super().execute(query, *args)

    maint, target = _CreateFails(), _RecordingConn()
    with pytest.raises(RuntimeError):
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    registered = [q for q, _ in maint.log if "pilot_database_registry" in q
                  and q.strip().upper().startswith("INSERT")]
    assert registered == [], \
        f"建库失败却写了登记行：{registered} —— 一次失败尝试就为外来库铸出了归属凭据"


def test_create_raises_when_registry_row_cannot_be_confirmed_present():
    """登记之后读不到那一行时必须报错（O4-R15-C1）。

    `ON CONFLICT DO NOTHING` 的命令状态本就可能是 'INSERT 0 0'（--reset 重建同名库），
    所以判据只能是**读后验**。读不到 → 本次建出的库将来会被闸 (ii) 当外来物。
    """
    class _RegistryVanishes(_RecordingConn):
        def __init__(self, **kw):
            super().__init__(**kw)
            self.registered_dbnames = set()      # 登记完仍查不到

    maint, target = _RegistryVanishes(), _RecordingConn()
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL,
            pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "registry_not_written"
    assert "该库此刻是空的" in str(ei.value), "必须告诉操作者这个库可以安全删掉"
    assert not target.log, "登记没落实就不该再碰目标库"


def test_unregistered_empty_remnant_does_not_block_gate_ii():
    """「建库成功、登记之前崩」留下的**空**残骸不得挡住闸 (ii)（O4-R15-C1 的前提）。

    R14 之所以把登记写在建库之前，正是担心这一档会锁死。**那个担心不成立** ——
    这颗钉子就是那个前提本身；它一旦变红，把登记挪到建库之后的理由就没了。
    """
    remnant = _FakeConn(meta_rows=[], user_objects=[])          # 绝对空
    conn = _FakeConn(databases=["kline_pilot_orphan"], registered_dbnames=set())
    asyncio.run(assert_cluster_allowed(
        conn, connect=_connector({"kline_pilot_orphan": remnant}),
        target_db="kline_pilot_other"))


def test_intent_confirmation_happens_immediately_after_create_before_registry():
    """确认凭据必须**紧贴**建库，中间不夹别的可失败步骤（O4-R16-C1）。

    夹在「建库成功」与「写恢复凭据」之间的任何一步失败，都会留下
    「有库、但 intent 仍是 false」的状态；同 run 重试撞 duplicate_database 后，
    确定性失败清理会把那行未确认的 intent 删掉 —— 空库从此没有任何销毁授权。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-007"))
    seq = [q for q, _ in maint.log
           if "CREATE DATABASE" in q or "create_confirmed = true" in q
           or "pilot_database_registry" in q]
    assert len(seq) == 3, f"应恰好三步，实得 {seq}"
    assert "CREATE DATABASE" in seq[0], "第一步必须是建库"
    assert "create_confirmed = true" in seq[1], \
        "确认恢复凭据必须**紧接**建库 —— 中间夹任何可失败步骤都会造出无凭据的空库"
    assert "pilot_database_registry" in seq[2], "登记排在确认之后"


def test_registry_proof_is_bound_to_the_database_instance_not_just_the_name():
    """源码守卫：登记凭据必须绑到实例（O4-R16-C2）。

    ⚠️ 文本钉子。行为由真 PG 场景 ⑬ 钉住（删掉同名库、别人用同名重建、
    陈旧登记行仍在 → 必须拒）—— 假件模拟不了 pg_database.oid 的分配。
    """
    import qmt_pilot_db as m
    has = " ".join(m._REGISTRY_HAS_SQL.split())
    assert "pg_database" in has and "d.oid = r.db_oid" in has, \
        f"登记判据没绑实例，只认名字：{has}"
    reg = " ".join(m._REGISTER_DB_SQL.split())
    assert "d.oid" in reg and "db_oid = EXCLUDED.db_oid" in reg, \
        f"登记写入没记录/改写实例 OID：{reg}"


def test_search_path_is_pinned_first_on_every_guard_conn():
    """守卫用到的**每条**连接，第一条语句必须是 search_path 钉桩（O4-R17-C1）。

    真 PG 实测：`SET search_path = evil, pg_catalog, public` 之后
    `SELECT count(*) FROM pg_class` 从 425 行变成 1 行 —— 整台集群的
    「除本工具外别无他物」会在**对手控制的数据**上求值。
    钉桩必须排在**任何读判据之前**，否则它保护不了先跑的那几条。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL,
        pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-007"))
    for label, conn in (("维护连接", maint), ("目标库连接", target)):
        assert conn.session_setup and conn.session_setup[0] == PIN_SEARCH_PATH_SQL, \
            f"{label}没钉 search_path：{conn.session_setup}"
        assert conn.executed, f"{label}什么都没执行，这颗钉子会变成空的"


def test_peer_connections_in_gate_ii_are_pinned_too():
    """闸 (ii) 逐个连进去的**同侪库**同样要钉（O4-R17-C1）。

    归属判据全在那条连接上求值 —— 它才是最需要钉的一条。
    """
    peer = _FakeConn(meta_rows=_meta_rows(), user_objects=[("pg_class", 3)])
    conn = _FakeConn(databases=["kline_pilot_other"],
                     registered_dbnames={"kline_pilot_other"})
    asyncio.run(assert_cluster_allowed(
        conn, connect=_connector({"kline_pilot_other": peer}),
        target_db="kline_pilot_probe"))
    # 会钉两次，且是**有意的**：闸 (ii) 自己钉一次（`_is_absolutely_empty` 也在这条连接上跑，
    # 而 `read_pilot_meta_rows` 可能先抛异常），`read_pilot_meta_rows` 作为 4a-2 会独立调用的
    # 入口再钉一次。重复无害，缺任何一处都会留下没钉的路径。
    assert peer.session_setup and peer.session_setup[0] == PIN_SEARCH_PATH_SQL, \
        f"同侪库连接没钉 search_path：{peer.session_setup}"
    assert set(peer.session_setup) == {PIN_SEARCH_PATH_SQL}, \
        f"同侪库连接上跑了别的会话级语句：{peer.session_setup}"


def test_every_connection_the_module_opens_is_pinned_immediately():
    """结构守卫：模块里每个 `await connect(...)` 之后必须紧跟 `pin_search_path`（O4-R17-C1）。

    ⚠️ **这是结构钉子，不是行为钉子** —— 但它是这里唯一有效的形式：
    钉桩在多处冗余（`read_pilot_meta_rows` / `assert_cluster_allowed` 内部也各钉一次），
    黑盒断言「这条连接钉了吗」**分辨不出是哪一处钉的**，删掉任意单点都不会变红
    （实测：V2/V3 两条 mutation 都没红）。与其假装覆盖了，不如按结构检查：
    以后新增任何一处 `connect(...)` 而忘了钉，这颗钉子当场变红。
    """
    import qmt_pilot_db as m
    lines = pathlib.Path(m.__file__).read_text().splitlines()
    opened = [(i, l) for i, l in enumerate(lines)
              if re.search(r"=\s*await\s+connect\(", l)]
    assert opened, "一处 connect( 都没找到 —— 匹配式过时了，这颗钉子会变成空的"
    for i, line in opened:
        # ⚠️ 不变量有**两条**（O4-R24-C2 之后）：
        #   ① 连上之后先进 `try:`（close 守卫必须比任何可能失败的动作更早就位 ——
        #      钉桩放在守卫外时，它一抛异常就带着一条活会话退出，之后的 DROP 会被顶住）；
        #   ② 随后要有 `pin_search_path`（否则这条连接上的目录查询可被 search_path 遮蔽）。
        #   窗口放宽到 12 行，但**两条都必须命中**，且 `try:` 要排在 pin 之前。
        window = lines[i + 1:i + 13]
        joined = " ".join(window)
        assert "adopt_connection(" in window[0] or any(
            l.strip() == "try:" for l in window), (
            f"第 {i + 1} 行 `{line.strip()}` 之后没有立刻进 try —— "
            f"连接在拿到 close 守卫之前就可能因异常泄漏")
        assert "adopt_connection(" in joined, (
            f"第 {i + 1} 行 `{line.strip()}` 之后 12 行内没有 adopt_connection —— "
            f"外部连接必须被**接管**：钉 search_path + 证明它连的就是那个库（O4-R28-C1）")
        try_at = next((k for k, l in enumerate(window) if l.strip() == "try:"), None)
        pin_at = next((k for k, l in enumerate(window) if "adopt_connection(" in l), None)
        assert try_at is not None and pin_at is not None and try_at < pin_at, (
            f"第 {i + 1} 行 `{line.strip()}`：try 在第 {try_at}、接管在第 {pin_at} —— "
            f"接管必须在 close 守卫**之内**")


def test_guard_entrypoints_pin_before_touching_the_connection():
    """结构守卫：三个信任边界入口的**函数体第一条 await** 必须是钉桩（O4-R17-C1）。"""
    import qmt_pilot_db as m
    src = pathlib.Path(m.__file__).read_text()
    for fname in ("read_pilot_meta_rows", "assert_cluster_allowed", "create_pilot_database"):
        i = src.index(f"async def {fname}(")
        # ⚠️ 窗口**必须切到函数边界**：用固定字节数会溢出到下一个函数，
        #    于是删掉本函数的钉桩后，匹配到的是**下一个函数**的钉桩 → 钉子静默失效
        #    （实测：V4 mutation 因此没红）。这是「检验器窗口不设边界」那一族。
        nxt = re.search(r"^(?:async def|def|class) ", src[i + 1:], re.MULTILINE)
        body = src[i:i + 1 + nxt.start()] if nxt else src[i:]
        assert f"async def {fname}(" in body and body.count("\nasync def ") == 0, \
            f"{fname} 的函数体切分不对，窗口跨到别的函数了"
        first_await = re.search(r"^\s+(await .+)$", body, re.MULTILINE)
        assert first_await, f"{fname} 里没找到 await —— 匹配式过时了"
        assert "pin_search_path" in first_await.group(1), (
            f"{fname} 的第一条 await 是 `{first_await.group(1).strip()}`，"
            f"不是 search_path 钉桩 —— 它之前的任何目录查询都可被遮蔽")


# ---------------------------------------------------------------------------
# O4-R19：指纹自校 + schema.sql 声明的表必须真的建出来
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("which", ["schema", "pilot_schema"])
def test_create_rejects_fingerprint_that_does_not_match_content(which):
    """指纹必须由内容算出来，不能信调用方传的（O4-R19-C1）。

    与 R5-C2 把 `seed_lock_held` 布尔换成活连接验锁是同一条原则：
    **调用方的断言不是证据**。文件与 hash 配错（读了旧文件、改了文件忘了重算）时，
    库会被标成 ready 而 pilot_meta 里的指纹**指着另一份 schema** ——
    之后的复用闸拿这个假指纹去比对，判据整条失效。
    """
    kw = dict(schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA)
    kw[f"{which}_sha256"] = "f" * 64
    maint, target = _RecordingConn(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007", **kw))
    assert ei.value.code == "fingerprint_content_mismatch"
    assert maint.log == [], "指纹对不上就不许有任何副作用（连 intent 行都不写）"


def test_create_rejects_schema_that_declares_no_tables():
    """一份什么表都不建的业务 schema 不是合法的 schema.sql（O4-R19-C1）。

    `BEGIN; SELECT 1; COMMIT;` 过得了事务包裹闸、指纹也能自洽，
    却会产出一个「ready 但一张业务表都没有」的库。
    """
    empty = "BEGIN;\nSELECT 1;\nCOMMIT;"
    maint, target = _RecordingConn(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=empty, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=hashlib.sha256(empty.encode("utf-8")).hexdigest(),
            pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "schema_declares_no_tables"
    assert maint.log == [], "守卫未过就不许有任何副作用"


def test_create_rejects_when_declared_tables_are_missing_after_apply():
    """apply 完 schema.sql 后，它声明的表必须真的在（O4-R19-C1）。

    「执行过 DDL ≠ 结构就对」——与 R13-C2 对 pilot_schema 做的是同一件事。
    期望清单**从 schema_sql 自身推导**，不硬编码（硬编码会跟着文件漂移）。
    """
    class _TablesVanish(_RecordingConn):
        def __init__(self, **kw):
            super().__init__(**kw)
            self.declared_tables_all_present = False

    maint, target = _RecordingConn(), _TablesVanish()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "schema_tables_missing"
    assert "klines" in str(ei.value), "报错要点名缺的是哪几张表"
    # 必须在写阶段 2 的键之前失败 —— 否则库已被标 ready
    assert 2 not in target.meta_keys_by_phase, \
        f"表没建齐却写了阶段 2 的键：{target.meta_keys_by_phase}"


@pytest.mark.parametrize("sql,expected,label", [
    ("-- CREATE TABLE ghost ();\nCREATE TABLE real_one ();", ["real_one"], "注释里的不算"),
    ("SELECT 'CREATE TABLE ghost ()';\nCREATE TABLE real_two ();", ["real_two"], "字符串里的不算"),
    ("CREATE TABLE IF NOT EXISTS public.\"quoted\" ();", ["quoted"], "限定名与引号标识符"),
    ("BEGIN;\nSELECT 1;\nCOMMIT;", [], "什么都不建"),
    # ⚠️ schema 限定必须**单独解析**（真 PG 场景 ⑲ 撞出来的）：前一版只剥 `public.`，
    #    于是 `CREATE TABLE zz_evil.pg_class (...)` 把 schema 名当成表名，
    #    守卫随后去找一张 `public.zz_evil` → 假的 schema_tables_missing，
    #    任何在非 public schema 建表的合法 schema.sql 都会被误拒。
    ("CREATE TABLE zz_evil.pg_class (id int);", [], "建在别的 schema → 不归 public 范围的核实管"),
    ('CREATE TABLE IF NOT EXISTS "public"."t" ();', ["t"], "显式 public 限定 + 引号"),
    ("CREATE TABLE public.a ();\nCREATE TABLE b ();\nCREATE TABLE other.c ();",
     ["a", "b"], "混合：显式 public / 不限定 / 别的 schema"),
])
def test_declared_tables_ignores_comments_and_strings(sql, expected, label):
    """期望清单必须走 `_sql_statements` 再匹配，不能对整份文本裸正则（O4-R19-C1）。

    否则注释掉的 `CREATE TABLE`、字符串里的同名字都会被算进来 ——
    守卫于是要求一张**本就不该存在**的表，造出一个自己发明的假失败。
    """
    assert declared_tables(sql) == expected, label


# ---------------------------------------------------------------------------
# O4-R21：确认位绑实例 + schema.sql 之后复验 pilot 安全表
# ---------------------------------------------------------------------------

def test_pilot_schema_is_reverified_after_business_schema_runs():
    """apply 完 schema.sql 之后必须**再验一次** pilot 安全表（O4-R21-C2）。

    结构证明此前只在 apply schema.sql **之前**跑过。而 schema.sql 是一份可以干任何事的
    DDL —— `BEGIN; CREATE TABLE klines(); DROP TABLE public.pilot_stock_source; COMMIT;`
    过得了事务闸、也过得了「业务表都在吗」，随后照常写指纹两键 + state='ready'。
    产出的库对外宣称 ready、`pilot_schema_sha256` 还记着那份 schema 的指纹，
    而**来源代次基线表已经不在了**。一次性的证明管不住后面还会执行的 DDL。
    """
    class _SchemaEatsPilotTable(_RecordingConn):
        """第一次结构证明合规；跑完 schema.sql 之后变成不合规。"""

        def __init__(self, **kw):
            super().__init__(**kw)
            self._business_schema_ran = False

        async def execute(self, query, *args):
            if "klines" in query:
                self._business_schema_ran = True
                self.pilot_schema_shape = dict(self.pilot_schema_shape,
                                               source_is_table=False)
            return await super().execute(query, *args)

    maint, target = _RecordingConn(), _SchemaEatsPilotTable()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "pilot_schema_invalidated"
    assert target._business_schema_ran, "这颗钉子的前提是 schema.sql 真的跑过了"
    assert 2 not in target.meta_keys_by_phase, \
        f"安全表已被破坏却写了阶段 2 的键：{target.meta_keys_by_phase}"


def test_intent_confirmation_is_bound_to_the_database_instance():
    """源码守卫：确认位必须绑 `db_oid`，不能只按名字判（O4-R21-C1）。

    ⚠️ 文本钉子。行为由真 PG 场景钉住（假件模拟不了 pg_database.oid 的分配）。
    只按名字判时，原库被删、别人用同名重建之后，陈旧的 create_confirmed=true 会被
    抢占那一步**刷新**到那个全新的库上 —— 而这一行正是零对象例外的 DROP 授权。
    与 pilot_database_registry.db_oid 是同一条修法（R16-C2），当时只改了登记表。
    """
    import qmt_pilot_db as m
    ins = " ".join(m._INSERT_INTENT_SQL.split())
    # ⚠️ 必须**按子句切分**再断言：语句里有两处 `d.oid = …db_oid`（确认位表达式一处、
    #    随后清理 db_oid 的 CASE 一处）。整句 `in` 会被后者满足，把这颗钉子变成空的
    #    ——本 PR 第二次栽在同一形态（前一次是 create_confirmed 的 VALUES vs ON CONFLICT）。
    clause = ins.split("create_confirmed = (")[1].split("db_oid = (CASE")[0]
    assert "d.oid = public.pilot_create_intent.db_oid" in clause, \
        f"抢占时确认位只按名字判，没绑实例：{clause}"
    assert ins.count("d.oid = public.pilot_create_intent.db_oid") == 2, \
        "确认位与 db_oid 清理两处都必须按实例比对"
    conf = " ".join(m._CONFIRM_INTENT_SQL.split())
    assert "db_oid = (SELECT d.oid FROM pg_database d" in conf, \
        f"确认那一步没记下实例 oid：{conf}"


# ---------------------------------------------------------------------------
# O4-R22：调用方 SQL 跑完要重新钉 search_path + 复核阶段 1 元数据
# ---------------------------------------------------------------------------

def test_search_path_is_repinned_after_every_caller_supplied_sql():
    """每一段调用方 SQL 跑完都要重新钉 search_path（O4-R22-C1）。

    真 PG 实测：事务里的普通 `SET search_path` **提交之后仍留在会话上**
    （只有 `SET LOCAL` 不留）。一份漂移/敌意的 .sql 只要含一句
    `SET search_path = evil, pg_catalog, public`，其后**所有守卫查询**就都跑在
    它选定的名字解析下 —— R17/R18 堵上的目录遮蔽从「调用方 SQL 的副作用」原样回来。
    一次性的钉桩管不住后面还会执行的 SQL（与 R21-C2 同一族）。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-007"))
    # 目标库连接上：连库时钉一次，两段调用方 SQL 各自跑完再钉一次 = 3 次
    # 判据是**次序**不是次数：每段调用方 SQL 之后、下一次守卫查询之前必须夹着钉桩。
    # （次数会随内部合法调用变化 —— read_pilot_meta_rows 自己也钉，写死 3 会假红。）
    for blob, tag in ((TOY_PILOT_SCHEMA_SQL, "pilot_schema.sql"), (TOY_SCHEMA_SQL, "schema.sql")):
        i = target.ops.index(blob)
        rest = target.ops[i + 1:]
        assert rest, f"{tag} 之后什么都没做，这颗钉子会变成空的"
        assert rest[0] == PIN_SEARCH_PATH_SQL, \
            f"{tag} 跑完的下一步是 {rest[0][:60]!r}，不是重新钉 search_path"
    assert set(target.session_setup) == {PIN_SEARCH_PATH_SQL}


@pytest.mark.parametrize("tamper,label", [
    ({"seed": "someone_else"}, "改掉 seed（归属键）"),
    ({"export_log_sha256": "f" * 64}, "改掉 export_log_sha256（输出绑定键）"),
    ({"output_dir": "/somewhere/else"}, "改掉 output_dir（输出绑定键）"),
    ({"state": "ready"}, "把 state 提前改成 ready"),
    ({"tool": None}, "删掉 tool 键"),
    ({"zz_extra": "x"}, "塞进一个多余的键"),
])
def test_schema_sql_must_not_tamper_with_phase1_metadata(tamper, label):
    """`schema_sql` 跑完必须复核阶段 1 的 7 个键逐键逐值没变（O4-R22-C2）。

    **结构没坏不等于内容没被改**：`UPDATE public.pilot_meta SET value='other'
    WHERE key='seed'` 完全保持表的形状合规，却把归属/输出绑定键改掉了；
    随后照常写指纹两键 + state='ready'、清掉 intent 行，
    产出一个「ready」但归属证明已被篡改的库。
    """
    class _SchemaTampersMeta(_RecordingConn):
        async def execute(self, query, *args):
            out = await super().execute(query, *args)
            if "klines" in query:                       # 业务 schema 跑完时动手脚
                for k, v in tamper.items():
                    self.meta_rows = [r for r in self.meta_rows if r["key"] != k]
                    if v is not None:
                        self.meta_rows.append({"key": k, "value": v})
            return out

    maint, target = _RecordingConn(), _SchemaTampersMeta()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "phase1_meta_tampered", label
    assert 2 not in target.meta_keys_by_phase, \
        f"元数据被篡改却写了阶段 2 的键：{target.meta_keys_by_phase}"
    # intent 行不能被当成「干净收尾」清掉
    cleared = [q for q, _ in maint.log
               if "pilot_create_intent" in q and q.strip().upper().startswith("DELETE")]
    assert cleared == [], f"失败路径不该清 intent 行：{cleared}"



def test_no_sql_constant_proves_uniqueness_with_indisunique():
    """机械守卫：模块里**任何** SQL 都不许拿 `indisunique` 当唯一性证明（O4-R24-C1）。

    ⚠️ 这颗钉子存在的直接原因：R23 修这条时我在提交信息里明写「五处一起改」，
    实际有**六处** —— 漏掉的正是运行时归属读取器 `_PILOT_META_SHAPE_SQL`。
    错在枚举方式：我按「我正在编辑的那两个 SHAPE_SQL 常量」数，而不是按
    「模块里所有唯一性判据」数。改判据时**必须按判据本身穷尽，不是按手头的文件块**。
    检查读的是模块的**字符串属性**（不是源文件文本），故 .py 注释里提到它不会误报。
    """
    import qmt_pilot_db as m
    offenders = sorted(k for k, v in vars(m).items()
                       if isinstance(v, str) and "indisunique" in v)
    assert not offenders, (
        f"这些 SQL 常量仍用 indisunique 当唯一性证明：{offenders} —— "
        f"`CREATE UNIQUE INDEX ... WHERE false` 能满足它却对任何行都不生效"
        f"（真 PG 实测：同一个键连插两行成功）。改用 pg_constraint 单列主键。")
    # 反向：确实有若干处在用主键判据，免得上面那条在「一条 SQL 都没有」时空转
    pk_sites = sum(v.count("contype = 'p'") for v in vars(m).values() if isinstance(v, str))
    assert pk_sites >= 6, f"主键判据只有 {pk_sites} 处 —— 少于已知的六处唯一性判据"


# ---------------------------------------------------------------------------
# O4-R26：pilot 表的依赖物白名单 + 阶段 2 提交后复读九键
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("counter,label", [
    ("user_triggers", "触发器能就地改写阶段 2 写进去的指纹与 state"),
    ("user_rules", "规则同理（`DO INSTEAD` 能把写入整个改向）"),
    ("extra_indexes", "主键之外的索引改变写入语义"),
    ("extra_constraints", "主键之外的约束同理"),
    # ⚠️ 这三条**改变读写行为却不碰列/主键形状**（O4-R27-C2，真 PG 实测）
    ("rls_policies", "RLS 策略能过滤掉普通角色读到的行"),
    ("rls_enabled", "relrowsecurity/relforcerowsecurity 置位（本工具不保证以超级用户运行）"),
    ("inherit_edges", "继承边让子表的行从父表读出来 —— 基线凭空多出内容"),
])
def test_schema_sql_must_not_leave_dependents_on_pilot_tables(counter, label):
    """**形状对了不等于行为没被改**（O4-R26-C1）。

    `schema_sql` 是调用方给的 DDL，它可以在 pilot 专用表上装触发器/规则 ——
    表结构、列、主键、阶段 1 的七行全都原样，而阶段 2 写进去的
    `schema_sha256` / `state='ready'` 会被就地改写；装在 `pilot_stock_source`
    上的则污染此后每一次来源代次写入。
    """
    class _SchemaLeavesDependent(_RecordingConn):
        async def execute(self, query, *args):
            out = await super().execute(query, *args)
            if "klines" in query:                       # 业务 schema 跑完时装上
                self.pilot_table_dependents = dict(self.pilot_table_dependents,
                                                   **{counter: 1})
            return out

    maint, target = _RecordingConn(), _SchemaLeavesDependent()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "pilot_tables_have_dependents", label
    assert counter in str(ei.value), "报错要点名是哪一类依赖物"
    assert 2 not in target.meta_keys_by_phase, \
        f"依赖物没清就写了阶段 2 的键：{target.meta_keys_by_phase}"


def test_final_meta_is_reread_after_phase2_and_before_clearing_intent():
    """阶段 2 提交后必须把九键读回来逐字比对（O4-R26-C1）。

    上面所有证明都发生在**写入之前**。「写完再读一遍」是唯一能直接证明
    「库里现在真的是这九个值」的办法，也是清掉 intent 行（放弃恢复凭据）
    之前最后一次能反悔的机会。
    """
    class _TampersAfterPhase2(_RecordingConn):
        async def execute(self, query, *args):
            out = await super().execute(query, *args)
            if "SET value = 'ready'" in query:          # 阶段 2 落地之后动手脚
                for row in self.meta_rows:
                    if row["key"] == "schema_sha256":
                        row["value"] = "0" * 64
            return out

    maint, target = _RecordingConn(), _TampersAfterPhase2()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "final_meta_mismatch"
    assert "schema_sha256" in str(ei.value), "报错要点名是哪个键对不上"
    # **恢复凭据不能在复读之前就被清掉**
    cleared = [q for q, _ in maint.log
               if "pilot_create_intent" in q and q.strip().upper().startswith("DELETE")]
    assert cleared == [], f"复读没过却清了 intent 行：{cleared}"


def test_happy_path_rereads_all_nine_keys_before_clearing_intent():
    """**防空转**：正常路径上复读确实发生了，且排在清 intent 之前（O4-R26-C1）。"""
    maint, target = _RecordingConn(), _RecordingConn()
    asyncio.run(create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-007"))
    ready_at = next(i for i, q in enumerate(target.ops) if "SET value = 'ready'" in q)
    reread_at = [i for i, q in enumerate(target.ops)
                 if i > ready_at and "SELECT key, value" in q]
    assert reread_at, f"置 ready 之后没有再读一次 pilot_meta：{target.ops[ready_at:]}"
    assert len(target.meta_rows) == 9, f"最终应有九个键，实得 {len(target.meta_rows)}"


def test_schema_sql_must_not_preseed_the_source_baseline():
    """新建的库，来源代次基线必须是空的（O4-R27-C1）。

    `schema_sql` 可以往 `public.pilot_stock_source` 里 INSERT 几行 ——
    形状、主键、依赖物全都干净，库照样被标 ready、intent 行照样被清掉。
    而这张表是 `already_done` / 来源代次判定的**基线**：伪造的行会让此后的
    重新导入被跳过，或与真实来源冲突，**且那时已经没有任何自动恢复凭据**。
    """
    class _SchemaSeedsSource(_RecordingConn):
        async def execute(self, query, *args):
            out = await super().execute(query, *args)
            if "klines" in query:
                self.pilot_source_rows = 3
            return out

    maint, target = _RecordingConn(), _SchemaSeedsSource()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "pilot_source_not_empty"
    assert "3 行" in str(ei.value), "报错要说清有几行"
    assert 2 not in target.meta_keys_by_phase, \
        f"基线被污染却写了阶段 2 的键：{target.meta_keys_by_phase}"
    cleared = [q for q, _ in maint.log
               if "pilot_create_intent" in q and q.strip().upper().startswith("DELETE")]
    assert cleared == [], f"失败路径不该清 intent 行：{cleared}"


@pytest.mark.parametrize("wrong", ["postgres", "kline_pilot_other", "template1"])
def test_create_rejects_a_target_connection_pointing_elsewhere(wrong):
    """`connect(db_name)` 返回的连接必须**真的**连着 db_name（O4-R28-C1）。

    与 R5-C2 把 `seed_lock_held` 布尔换成「在活连接上真验锁」是同一条原则：
    **调用方注入的东西不是证据**。DSN 被改写、连接池串了、包装层把名字映射错了，
    都会让这条连接指向另一个库；随后 pilot_schema.sql 与 schema.sql 会落到**那个库**上做 DDL，
    而刚建好的 pilot 库空着、却已经登记在案。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    target.current_database = wrong
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "connection_wrong_database"
    assert wrong in str(ei.value), "报错要点名它实际连到了哪个库"
    # 一条 DDL 都不许落到那个库上
    assert target.executed == [], f"在错的库上执行了：{target.executed}"
    assert target.closed, "识别出连错库之后必须把这条连接关掉"


def test_gate_ii_rejects_a_peer_probe_pointing_elsewhere():
    """闸 (ii) 逐个连同侪库时同样要证身份（O4-R28-C1）。

    判归属却判到**另一个库**头上，这道闸的结论就与它声称的对象无关了。
    """
    peer = _FakeConn(meta_rows=_meta_rows(), user_objects=[("pg_class", 3)])
    peer.current_database = "postgres"          # connect 把我们送去了别处
    conn = _FakeConn(databases=["kline_pilot_other"],
                     registered_dbnames={"kline_pilot_other"})
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": peer}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"
    assert "postgres" in str(ei.value), "底层原因要透出来，否则排障看不到真因"


def test_adopt_connection_pins_before_asking_which_database():
    """接管的**次序**：先钉 search_path，再问 current_database（O4-R28-C1）。

    反过来的话，`current_database()` 这个函数名本身就可能被敌意 search_path 解析到别处。
    """
    conn = _RecordingConn()
    conn.current_database = "kline_pilot_probe"
    asyncio.run(adopt_connection(conn, "kline_pilot_probe"))
    assert conn.ops[0] == PIN_SEARCH_PATH_SQL, \
        f"第一步不是钉 search_path：{conn.ops[:2]}"
    assert conn.ops[1] == "SELECT current_database()", \
        f"第二步不是问身份：{conn.ops[:3]}"


def test_create_rejects_a_target_connection_on_another_cluster():
    """同名还不够，必须**同一台集群**（O4-R29-C1）。

    被改错的 DSN 完全可能指向另一台 PostgreSQL 上**同名**的库 —— 名字对上了，
    而维护库里的 intent/登记与这条连接分属两台机器：
    「归属证明」与「被证明的对象」根本不在一个信任边界里。
    `system_identifier` 由 initdb 生成、存在服务端控制文件，DSN 改写伪造不了
    （真 PG 实测：两个集群取值不同）。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    target.cluster_id = "cluster-B"                 # 同名，但在另一台机器上
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "connection_wrong_cluster"
    assert "cluster-B" in str(ei.value) and "cluster-A" in str(ei.value), \
        "报错要把两边的集群身份都点出来"
    assert target.executed == [], f"在别的集群上执行了：{target.executed}"


def test_gate_ii_rejects_a_peer_probe_on_another_cluster():
    """闸 (ii) 逐个连同侪库时同样要绑集群（O4-R29-C1）。"""
    peer = _FakeConn(meta_rows=_meta_rows(), user_objects=[("pg_class", 3)])
    peer.cluster_id = "cluster-B"
    conn = _FakeConn(databases=["kline_pilot_other"],
                     registered_dbnames={"kline_pilot_other"})
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": peer}),
            target_db="kline_pilot_probe"))
    assert ei.value.code == "unowned_pilot_database"
    assert "cluster-B" in str(ei.value), "底层原因要透出来"


def test_required_business_tables_matches_schema_file():
    """`REQUIRED_BUSINESS_TABLES` 必须与 `backend/sql/schema.sql` **实际建的表**一致（O4-R29-C2）。

    模块本身**不读文件**（不把库耦合到仓库布局），防漂移的责任落在这颗钉子上：
    业务 schema 增删一张表而常量没跟着改，它当场变红。
    ⚠️ 这也是「验收标准不能从被验对象自己推导」的落地方式 —— 期望清单来自**仓库文件**，
    不是来自调用方递进来的那份 SQL。
    """
    sql = (pathlib.Path(__file__).resolve().parents[1] / "sql/schema.sql").read_text()
    in_file = declared_tables(sql)
    assert set(REQUIRED_BUSINESS_TABLES) == set(in_file), (
        f"常量 {REQUIRED_BUSINESS_TABLES} 与 schema.sql 实际建的 {in_file} 不一致")
    assert len(REQUIRED_BUSINESS_TABLES) == len(set(REQUIRED_BUSINESS_TABLES)), "常量里有重复"


def test_self_consistent_but_wrong_schema_is_rejected():
    """一份**错但自洽**的 schema_sql 不得自证为 ready（O4-R29-C2）。

    `BEGIN; CREATE TABLE klines(id int); COMMIT;` 过得了事务包裹闸、
    指纹与它自己一致、声明的一张表也确实建出来了 —— 旧判据全部满足。
    只有外部清单能拦住它。
    """
    class _OnlyKlines(_RecordingConn):
        async def fetchval(self, query, *args):
            if "unnest($1::text[])" in query:
                # 只有 klines 真的存在
                return sum(1 for name in args[0] if name == "klines")
            return await super().fetchval(query, *args)

    wrong = "BEGIN;\nCREATE TABLE klines (id int);\nCOMMIT;"
    maint, target = _RecordingConn(), _OnlyKlines()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=wrong, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=hashlib.sha256(wrong.encode("utf-8")).hexdigest(),
            pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    # ⚠️ O4-R30-C1 之后，这一档被**更早也更强**的闸接住：schema_sql 与仓库里的规范文件
    #    字节不同 → 根本不允许进场。原来的 business_tables_missing 由下面那颗钉子守着
    #    （规范输入 + apply 之后表却不齐，即「库不是这份 DDL 该产出的样子」）。
    assert ei.value.code == "schema_not_canonical"
    assert "schema.sql" in str(ei.value), "报错要点名是哪一份对不上"
    assert 2 not in target.meta_keys_by_phase, \
        f"业务表不齐却写了阶段 2 的键：{target.meta_keys_by_phase}"


def test_canonical_schema_hashes_match_the_repo_files():
    """`CANONICAL_*_SHA256` 必须等于仓库里那两份 .sql 的指纹（O4-R30-C1）。

    模块**不读文件**（不把库耦合到仓库布局），防漂移的责任落在这颗钉子上：
    改了 `backend/sql/schema.sql` 或 `pilot_schema.sql` 而没更新常量，它当场变红。
    ⚠️ 这是「验收标准不能由调用方提供」的落地方式 —— 判据锚在**仓库文件**上，
    而不是锚在调用方递进来的那份 SQL 上（后者是自证）。
    """
    sql_dir = pathlib.Path(__file__).resolve().parents[1] / "sql"
    for name, const in (("schema.sql", CANONICAL_SCHEMA_SHA256),
                        ("pilot_schema.sql", CANONICAL_PILOT_SCHEMA_SHA256)):
        actual = hashlib.sha256(
            (sql_dir / name).read_text(encoding="utf-8").encode("utf-8")).hexdigest()
        assert const == actual, (
            f"{name} 的规范指纹常量是 {const!r}，文件实际是 {actual!r} —— "
            f"改了 .sql 就要同步常量，否则守卫会把**当前**的规范文件判成非规范")


def test_business_tables_missing_still_fires_with_canonical_input():
    """规范输入 + apply 之后表却不齐 → `business_tables_missing`（O4-R30-C1 之后的分工）。

    规范指纹管「进场的是不是那份 SQL」；这条管「跑完之后库是不是那份 SQL 该产出的样子」。
    两者都不可少：前者挡坏输入，后者挡「输入对但结果不对」（DDL 被别的东西干扰、
    库本就不干净、PG 侧异常）。
    """
    class _TablesMissingAfterApply(_RecordingConn):
        async def fetchval(self, query, *args):
            if "unnest($1::text[])" in query:
                return 0                      # 一张都找不到
            return await super().fetchval(query, *args)

    maint, target = _RecordingConn(), _TablesMissingAfterApply()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code in ("schema_tables_missing", "business_tables_missing")
    assert 2 not in target.meta_keys_by_phase, \
        f"表不齐却写了阶段 2 的键：{target.meta_keys_by_phase}"


@pytest.mark.parametrize("which", ["schema", "pilot_schema"])
def test_non_canonical_schema_is_rejected_before_any_side_effect(which):
    """非规范的 .sql 一律不许进场，且在**任何副作用之前**（O4-R30-C1）。"""
    kw = dict(schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
              schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA)
    # ⚠️ 两份的形状要求不同：schema.sql **必须**自带事务，pilot_schema.sql **不许**自带。
    #    给错形状会撞更早的那两条闸，这颗钉子就测不到规范指纹了。
    drifted = ("BEGIN;\nCREATE TABLE stocks (); CREATE TABLE klines ();\n"
               "CREATE TABLE stock_coverage (); CREATE TABLE training_sets ();\nCOMMIT;"
               if which == "schema" else
               "CREATE TABLE pilot_meta (); CREATE TABLE pilot_stock_source ();")
    kw[f"{which}_sql"] = drifted
    kw[f"{which}_sha256"] = hashlib.sha256(drifted.encode("utf-8")).hexdigest()
    maint, target = _RecordingConn(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007", **kw))
    assert ei.value.code == "schema_not_canonical"
    assert maint.log == [], "非规范 schema 不许有任何副作用（连 intent 行都不写）"


@pytest.mark.parametrize("field,value,why", [
    ("export_log_sha256", None, "None"),
    ("export_log_sha256", "", "空串"),
    ("export_log_sha256", "Z" * 64, "非十六进制"),
    ("export_log_sha256", "a" * 63, "长度不足"),
    ("export_log_sha256", "A" * 64, "大写十六进制（规范是小写）"),
    ("output_dir", None, "None —— 旧代码在 CREATE/确认/登记之后才崩"),
    ("output_dir", "", "空串"),
    ("output_dir", "/", "只有根 —— 去掉尾斜杠后是空绑定"),
    ("output_dir", "relative/path", "相对路径"),
    ("created_at", None, "None"),
    ("created_at", "2026-07-29T10:15:30Z", "扩展格式（规范是 basic）"),
    ("created_at", "20260729T1015Z", "位数不足"),
])
def test_identity_scalars_are_validated_before_any_side_effect(field, value, why):
    """三个身份/绑定标量必须在**任何副作用之前**验掉（O4-R32-C1）。

    它们此前一路裸奔到 `values` 才被用上：`output_dir=None` 直到
    `CREATE DATABASE` / 确认 / 登记**都做完之后**才在 `.rstrip('/')` 上崩掉；
    空串或 `"/"` 则被安静地存成一个空绑定。而这三者正是 `confirm_token` 的原像
    与 `--reset-foreign` 的绑定依据 —— 存进去的是垃圾，令牌就派生不出来。
    """
    kw = dict(export_log_sha256="a" * 64, output_dir="/x/y",
              created_at="20260729T101530123456Z")
    kw[field] = value
    maint, target = _RecordingConn(), _RecordingConn()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            run_id="run-007", **kw))
    assert ei.value.code == "identity_scalar_invalid", why
    assert field in str(ei.value), "报错要点名是哪个字段"
    assert maint.log == [], f"{why}：不该有任何副作用，实得 {[q for q, _ in maint.log][:2]}"
    assert target.executed == [], f"{why}：目标库上不该执行任何东西"


def test_identity_scalars_accept_the_normal_shape():
    """**防过度收紧**：正常取值必须放行（O4-R32-C1）。"""
    assert_identity_scalars("0" * 64, "/data/qmt", "20260729T101530123456Z")
    assert_identity_scalars("f" * 64, "/data/qmt/", "19700101T000000000000Z")


def test_business_catalog_fixture_matches_the_constant():
    """固件 ↔ 规范常量必须一致（O4-R32-C2）。

    假件靠这段原文喂给守卫；它一旦与常量脱钩，host 层所有「正常路径」都会变成
    在**错的期望**上通过 —— 那是最难发现的一类假绿。
    另一半（常量 ↔ 活库）由真 PG 验收脚本的 ㉕ 档钉住。
    """
    assert sha256_of_sql(_CANON_CATALOG_TEXT) == CANONICAL_BUSINESS_CATALOG_SHA256, (
        "固件与 CANONICAL_BUSINESS_CATALOG_SHA256 对不上 —— "
        "改了 schema.sql 或升级了 PostgreSQL 之后，两边都要重新生成")
    assert "--constraints--" in _CANON_CATALOG_TEXT and "--indexes--" in _CANON_CATALOG_TEXT, \
        "固件缺少约束/索引段 —— 生成方式变了，指纹覆盖面已经不是原来那个"


def test_business_schema_drift_after_apply_is_rejected():
    """apply 之后活目录被改（掉约束/换类型）→ 不许标 ready（O4-R32-C2）。

    规范指纹证明的是「递进来的字节」，**不是「库现在长什么样」**。
    """
    class _CatalogDrifts(_RecordingConn):
        async def execute(self, query, *args):
            out = await super().execute(query, *args)
            if "klines" in query:
                self.business_catalog_text = _CANON_CATALOG_TEXT.replace(
                    "--constraints--", "--constraints--\n(少了一条 CHECK)")
            return out

    maint, target = _RecordingConn(), _CatalogDrifts()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "business_schema_drift"
    assert "升级过 PostgreSQL" in str(ei.value), \
        "报错必须提示「也可能是 PG 版本渲染差异」，否则升级后无从下手"
    assert 2 not in target.meta_keys_by_phase, \
        f"目录已漂移却写了阶段 2 的键：{target.meta_keys_by_phase}"


@pytest.mark.parametrize("counter,label", [
    ("user_triggers", "业务表上的触发器会改写此后每一次导入"),
    ("user_rules", "规则同理（DO INSTEAD 能把写入整个改向）"),
    ("rls_policies", "RLS 策略过滤掉普通角色读到的行"),
    ("rls_enabled", "relrowsecurity/relforcerowsecurity 置位"),
    ("inherit_edges", "继承边让子表的行从父表冒出来"),
])
def test_business_tables_must_not_have_behavior_objects(counter, label):
    """业务表也要证「没有行为对象」（O4-R34-C1）。

    `_PILOT_TABLE_DEPENDENTS_SQL` 只管两张 pilot 表 —— 同一条判据在业务表上**没做**，
    是本 PR 里「只修被点名的那一处」的又一次。往 `public.klines` 上装一个 INSERT 触发器，
    列/约束/默认值/索引/序列全都不变，**活目录指纹一个字都不动**。
    """
    class _BizBehavior(_RecordingConn):
        async def execute(self, query, *args):
            out = await super().execute(query, *args)
            if "klines" in query:
                self.business_table_behavior = dict(self.business_table_behavior,
                                                    **{counter: 1})
            return out

    maint, target = _RecordingConn(), _BizBehavior()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "business_tables_have_dependents", label
    assert counter in str(ei.value), "报错要点名是哪一类"
    assert 2 not in target.meta_keys_by_phase, \
        f"业务表有行为对象却写了阶段 2 的键：{target.meta_keys_by_phase}"


def test_fingerprint_covers_sequences():
    """序列参数必须在指纹里（O4-R34-C1）。

    默认值文本写的是 `nextval('…'::regclass)` —— 序列**本身**被
    `ALTER SEQUENCE … INCREMENT BY -1` 改掉时，它一个字都不变。
    """
    import qmt_pilot_db as m
    assert "--sequences--" in m._BUSINESS_CATALOG_FINGERPRINT_SQL, "指纹缺 sequences 段"
    assert "pg_sequences" in m._BUSINESS_CATALOG_FINGERPRINT_SQL
    assert "--sequences--" in _CANON_CATALOG_TEXT, "固件缺 sequences 段 —— 与查询脱钩了"
    seg = _CANON_CATALOG_TEXT.split("--sequences--")[1].split("--indexes--")[0]
    seq_lines = [l for l in seg.splitlines() if l.strip()]
    assert len(seq_lines) == 2, f"应有两条序列（klines/training_sets），实得 {seq_lines}"

    # ⚠️ **按字段数与字段值判，不再按 `:1:false` 这种魔法后缀**（O4-R38-C1）：
    #    后缀判据把「取了哪些字段」这件事藏了起来 —— R34 只取三个字段时它照样通过。
    for line in seq_lines:
        name, *fields = line.split(":")
        assert len(fields) == 8, (
            f"{name} 的序列指纹应有 8 个字段"
            f"（data_type/start/min/max/increment/cycle/cache/relpersistence），"
            f"实得 {len(fields)}：{fields}")
        assert fields[-1] == "p", f"{name} 不是 LOGGED 序列：relpersistence={fields[-1]!r}"
    # 两条序列的**取值范围必须不同**（bigint vs integer）——若指纹漏了 max_value/data_type，
    # 这两行会长得一模一样，这条断言就变红。
    assert seq_lines[0].split(":")[1:6] != seq_lines[1].split(":")[1:6], \
        "两条序列的类型/范围字段完全相同 —— 指纹很可能没取 data_type/min/max"


def test_fingerprint_covers_every_behavioral_sequence_attribute():
    """序列指纹取的是 pg_sequences 的**整行行为属性**，不是挑几个字段（O4-R38-C1）。

    R34 加这一段时只取了 start/increment/cycle —— 正是 R35 刚为**表**修掉的反模式。
    本机 PG 15.12 实测：`MAXVALUE 2` / `AS smallint` / `CACHE 1000` 三种改法
    都让那三个字段**一字不变**，而 MAXVALUE 改小之后第三次 INSERT 直接
    `nextval: reached maximum value of sequence`。
    另：`ALTER SEQUENCE … SET UNLOGGED` 在 15.12 **是支持的**（relpersistence→'u'），
    故 R37 给表补的崩溃安全证明，序列这边同样躲得过 —— 一并纳入。
    """
    import qmt_pilot_db as m
    sql = m._BUSINESS_CATALOG_FINGERPRINT_SQL
    for col in ("s.data_type", "s.start_value", "s.min_value", "s.max_value",
                "s.increment_by", "s.cycle", "s.cache_size", "sc.relpersistence"):
        assert col in sql, f"序列指纹缺 {col} —— 改它不会让指纹变化"
    # ⚠️ 两条**刻意排除**，钉住理由，免得下一轮「顺手补上」把指纹变成不确定的：
    assert "s.last_value" not in sql, \
        "last_value 是运行时状态（每插一行就变）——取了指纹对同一份 DDL 不再稳定"
    assert "s.sequenceowner" not in sql, \
        "sequenceowner 随部署的角色名而变，与 DDL 正确性无关"


def test_target_connection_must_be_the_instance_just_created():
    """目标连接必须绑到**刚建出来的那个实例**（O4-R35-C2）。

    `CREATE DATABASE` 与 `connect(db_name)` 之间存在窗口 —— 期间有人把它删掉再用同名重建，
    这条连接就指向一个**替身**：schema 与 ready 元数据会写到替身上，
    而 intent/登记里记的 `db_oid` 指着那个已经消失的实例。
    这是「凡是『这就是我那个库』的断言都要绑实例」的**第三处落点**
    （R16-C2 登记表 / R21-C1 intent 行 / 本条 活连接）。
    """
    maint, target = _RecordingConn(), _RecordingConn()
    target.current_db_oid = "99999"          # 替身：同名同机，但不是刚建的那个
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(create_pilot_database(
            maint, connect=_connector({"kline_pilot_probe": target}),
            db_name="kline_pilot_probe", seed="probe",
            schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
            schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
            export_log_sha256="a" * 64, output_dir="/x/y",
            created_at="20260729T101530123456Z", run_id="run-007"))
    assert ei.value.code == "connection_wrong_instance"
    assert "99999" in str(ei.value) and "16400" in str(ei.value), \
        "报错要把两个 oid 都点出来"
    assert target.executed == [], f"在替身上执行了：{target.executed}"


def test_fingerprint_takes_the_whole_table_level_row():
    """指纹必须整体纳入表级属性，而不是逐个字段补（O4-R35-C1）。

    这已经是第三次「指纹漏了一个维度」（R33 默认值 → R34 序列 → R35 relpersistence）。
    `ALTER TABLE … SET UNLOGGED` 改的是 `pg_class.relpersistence`，
    列/约束/默认值/序列/索引一个都不动 —— 库不再崩溃安全，而守卫毫无察觉。
    逐个补下去永远比下一个评审慢一步，故取**表级那一行**。
    """
    import qmt_pilot_db as m
    q = m._BUSINESS_CATALOG_FINGERPRINT_SQL
    for col in ("relkind", "relpersistence", "reltablespace", "reloptions",
                "relispartition", "relrowsecurity", "relforcerowsecurity",
                "relhassubclass", "relhasrules", "relhastriggers", "relhasindex",
                "relchecks", "relnatts", "amname"):
        assert col in q, f"指纹漏了表级属性 {col}"
    tbl_lines = [l for l in _CANON_CATALOG_TEXT.splitlines() if "@" in l and ":" in l]
    assert len(tbl_lines) == 4, f"应有四张业务表的表级行，实得 {tbl_lines}"
    assert all(":p:" in l for l in tbl_lines), \
        f"规范库里四张表都应是 permanent（relpersistence='p'）：{tbl_lines}"


def _replace_after(trigger_check):
    """造一条维护连接：在 `trigger_check` 命中的那一刻，同名库被删掉又重建。

    ⚠️ 只翻转一次（`live_db_oid is None` 时才动手）——否则「替换」会在每次
    命中时重演，测试想验的那个**单一时间窗**就被抹平了。
    """
    class _Replacer(_RecordingConn):
        async def fetchval(self, query, *args):
            out = await super().fetchval(query, *args)
            if trigger_check("fetchval", query) and self.live_db_oid is None:
                self.live_db_oid = "77777"
            return out

        async def execute(self, query, *args):
            out = await super().execute(query, *args)
            if trigger_check("execute", query) and self.live_db_oid is None:
                self.live_db_oid = "77777"
            return out
    return _Replacer()


def _create_probe(maint, target):
    return create_pilot_database(
        maint, connect=_connector({"kline_pilot_probe": target}),
        db_name="kline_pilot_probe", seed="probe",
        schema_sql=TOY_SCHEMA_SQL, pilot_schema_sql=TOY_PILOT_SCHEMA_SQL,
        schema_sha256=TOY_SCHEMA_SHA, pilot_schema_sha256=TOY_PILOT_SCHEMA_SHA,
        export_log_sha256="a" * 64, output_dir="/x/y",
        created_at="20260729T101530123456Z", run_id="run-036")


def test_confirm_intent_binds_to_the_instance_just_created():
    """确认位（= DROP 授权）绝不能盖到一个本次没建过的同名库上（O4-R36-C1）。

    `CREATE DATABASE` 成功 → 读到 oid → **此处**它被删掉又同名重建 →
    只按名字取 oid 的旧写法会给**替身**盖 `create_confirmed = true`、
    并把替身的 oid 写进 `db_oid`。随后的 `adopt_connection(expected_oid=…)`
    确实会拒掉这条运行，但那时维护库里已经留下一张对「本次没有建过的库」的
    销毁授权。**凭据必须在授权成立的那一句 SQL 里就绑死实例**。
    """
    maint = _replace_after(lambda kind, q: kind == "fetchval"
                           and "d.oid::text FROM pg_database d" in q)
    target = _RecordingConn()
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_create_probe(maint, target))
    assert ei.value.code == "created_database_replaced", ei.value.code
    assert "16400" in str(ei.value) and "77777" in str(ei.value), \
        "报错要同时点出「本次建的那个」与「现在这个」，否则人工核对无从下手"
    confirms = [q for q, _ in maint.log if "SET create_confirmed = true" in q]
    assert len(confirms) == 1, "确认应当被尝试过一次（是 SQL 谓词把它拦下的，不是先查后用）"
    assert not [q for q, _ in maint.log if "pilot_database_registry" in q.upper()
                or "pilot_database_registry" in q], \
        "确认没成立就绝不能往登记表写 —— 那张表本工具从不清"
    assert 1 not in target.meta_keys_by_phase, "被替换后不得往任何库写 pilot_meta"


def test_registry_write_binds_to_the_instance_just_created():
    """登记行同理：确认之后、登记之前被替换，也绝不给替身发归属凭据（O4-R36-C1）。

    这张表本工具**从不清**——一次写错就是永久的：那个外来库从此永远通过
    闸 (ii) 的外部凭据。故登记那句 `SELECT` 必须按 oid 取行，取不到就一行都不插。
    """
    maint = _replace_after(lambda kind, q: kind == "execute"
                           and "SET create_confirmed = true" in q)
    target = _RecordingConn()
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_create_probe(maint, target))
    assert ei.value.code == "registry_not_written", ei.value.code
    assert maint.registry_write_bound is False, \
        "登记那句 SELECT 应当一行都没取到（假件据 SQL 文本里的 $5 谓词建模）"
    assert 1 not in target.meta_keys_by_phase, "登记没成立就不得继续初始化"


def test_cluster_gate_judges_the_instance_it_enumerated():
    """闸 0− 判的必须是它**枚举到的那个实例**（自捉，同族第六处落点）。

    `pg_database` 读出 `kline_pilot_other` 之后、`connect(name)` 之前它被删掉
    又同名重建：这道闸就是在**替身**上得出「集群干净」，而它声称检查的是
    刚才枚举到的那一个。名字不是实例 —— 与 R16-C2 / R21-C1 / R35-C2 / R36-C1 同一条原则。
    """
    peer = _FakeConn(user_objects=[])
    peer.current_db_oid = "88888"                     # 替身：同名同机，另一个实例
    conn = _FakeConn(databases=["kline_pilot_other"],
                     registered_dbnames={"kline_pilot_other"})
    conn.database_oids = {"kline_pilot_other": "16400"}   # 枚举时看到的那一个
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(assert_cluster_allowed(
            conn, connect=_connector({"kline_pilot_other": peer}),
            target_db="kline_pilot_probe"))
    # 闸 0− 按 spec §4 O1-F10 把「验归属时的任何失败」统一收成 unowned_pilot_database
    # （4c 才不会把一次成功的守卫记成 FAIL_INFRASTRUCTURE）——判据要落在**原因**上。
    assert ei.value.code == "unowned_pilot_database", ei.value.code
    assert "88888" in str(ei.value) and "16400" in str(ei.value), \
        f"报错没点出 oid 不符，等于没说清它拒的是什么：{ei.value}"


def test_every_pg_database_predicate_binds_to_an_instance():
    """机械守卫：模块里每一条碰 `pg_database` 的 SQL 都必须**比较 oid**（O4-R36-C1）。

    「凡是『这就是我那个库』的断言，都要绑实例而不是绑名字」在本 PR 里被逐个点出了
    **六处**（R16-C2 登记读 → R21-C1 intent 保留位 → R35-C2 目标连接 →
    R36-C1 确认位 + 登记写 → 自捉 闸 0− 枚举）。逐处修永远比下一个评审慢一步，
    故这里按**判据本身**把全模块扫一遍，让第七处一出现就变红。

    ⚠️ 判据是「出现 oid **比较**」，不是「出现 oid 三个字母」：旧的 `_REGISTER_DB_SQL`
    在 SELECT 列表里就有 `d.oid`（它是被**写入**的值），拿「含 oid」当判据的话
    这条守卫对本轮的真 bug 毫无反应 —— 又一个恒真断言。
    ⚠️ 白名单是**捕获点**：这几条 SQL 的职责就是「回答此刻那个名字对应哪个实例」，
    本次运行所说的「那个库」由它们定义，故它们无从比较。往白名单里加名字是
    刻意且可评审的动作；下面的反向断言保证不能靠「全都加进白名单」把守卫掏空。
    """
    import re
    import qmt_pilot_db as m
    capture_points = {"_CURRENT_DB_OID_SQL", "_CREATED_DB_OID_SQL", "_LIST_DATABASES_SQL"}
    compares_oid = re.compile(r"\.oid(::text)?\s*=")
    scanned, checked = set(), set()
    for attr in dir(m):
        val = getattr(m, attr)
        if not isinstance(val, str) or "pg_database" not in val:
            continue
        scanned.add(attr)
        if attr in capture_points:
            continue
        checked.add(attr)
        assert compares_oid.search(val), (
            f"{attr} 碰了 pg_database 却没有**比较** oid —— 它按名字断言「这就是我那个库」。"
            f"同名库可以被删掉又重建；名字不是实例。")
    assert scanned >= capture_points | {
        "_REGISTRY_HAS_SQL", "_INSERT_INTENT_SQL", "_CONFIRM_INTENT_SQL", "_REGISTER_DB_SQL"}, \
        f"扫描漏了已知的同族 SQL —— 守卫的枚举方式坏了：实得 {sorted(scanned)}"
    assert len(checked) >= 4, \
        f"只有 {len(checked)} 条 SQL 被真正检查（其余都在白名单里）—— 守卫已被掏空"
    assert not any(re.search(r"pg_database", s) for s in _module_inline_sql_without_oid(m)), \
        "模块里还有**内联**的 pg_database 查询：内联 SQL 这条守卫看不见，请提成常量"


def _module_inline_sql_without_oid(m):
    """源码里内联（非模块常量）的 SQL 字面量 —— 守卫的盲区，必须为空。"""
    import ast
    import inspect
    tree = ast.parse(inspect.getsource(m))
    module_consts = {t.id for node in tree.body if isinstance(node, ast.Assign)
                     for t in node.targets if isinstance(t, ast.Name)}
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                and node.func.attr in ("execute", "fetch", "fetchval", "fetchrow"):
            for a in node.args[:1]:
                if isinstance(a, ast.Constant) and isinstance(a.value, str):
                    out.append(a.value)
    assert module_consts, "解析器没取到任何模块常量 —— AST 走空了"
    return out


def test_every_guard_table_shape_proof_covers_table_level_durability():
    """**每一张守卫表**都要有表级耐久性证明（O4-R37-C2）——按性质枚举，不按点名枚举。

    R35-C1 把 `pg_class` 整行纳入了**业务表**指纹，还写下了「按被保护的性质枚举」，
    却没回头问「**还有哪些表**要同样的保护」——于是 pilot/维护共五张表仍可被
    `ALTER TABLE … SET UNLOGGED` 掏空：列、主键、依赖物判据全部照旧为真，
    库照样被标 ready，而崩溃后 unlogged 表会被 truncate。
    这条守卫按「本工具的安全性依赖哪些表」来枚举，让第六张表一出现就变红。
    """
    import re
    import qmt_pilot_db as m
    specs = {"_MAINTENANCE_SHAPE_SQL": _OK_MAINTENANCE_SHAPE,
             "_PILOT_SCHEMA_SHAPE_SQL": _OK_PILOT_SHAPE}
    for name, canon in specs.items():
        sql = getattr(m, name)
        for token in ("relpersistence = 'p'", "relrowsecurity", "relforcerowsecurity",
                      "relispartition", "reloptions IS NULL", "reltablespace = 0"):
            assert token in sql, f"{name} 缺表级判据 {token!r}"
        fields = set(re.findall(r"AS ([a-z_]+)", sql))
        assert fields == set(canon), (
            f"{name} 的判据集合与假件的权威副本不一致：SQL 有 {sorted(fields - set(canon))}，"
            f"假件多出 {sorted(set(canon) - fields)} —— 假件漏建模一条判据，"
            f"对应的用例就在一个 KeyError/恒真上空转")

    # 「本工具的安全性依赖哪些表」——一张都不许漏
    for table in ("public.pilot_meta", "public.pilot_stock_source",
                  "public.pilot_cluster_marker", "public.pilot_create_intent",
                  "public.pilot_database_registry"):
        assert any(table in getattr(m, n) for n in specs), \
            f"{table} 没有任何表级耐久性证明 —— 它可被 SET UNLOGGED 而所有判据照旧为真"

    # ⚠️ **刻意排除**：`_PILOT_META_SHAPE_SQL` 读的是**别的库**的归属自证，
    #    本次运行不依赖那个库的耐久性；在那里要求持久会让一台崩溃过的同侪库
    #    把集群闸整个顶死（R55-F1 锁死的换形态）。钉住这条排除，
    #    免得下一轮把它当成同族遗漏「顺手补上」而引入锁死。
    assert "relpersistence" not in m._PILOT_META_SHAPE_SQL, \
        "同侪库的归属自证不该要求持久性 —— 那会让崩溃过的同侪库顶死整台集群"


# `name` 型的系统目录列。聚合成数组之后与 `text[]` 字面量比较时**没有相等操作符**。
_NAME_TYPED_CATALOG_COLUMNS = ("attname", "relname", "conname", "nspname",
                               "typname", "proname", "rolname", "spcname")

# 「聚合了 name 型目录列却没转成 text」的出现处。
# ⚠️ 是**结构计数**，不是禁词黑名单：数的是「这个形状出现了几次」，要求为 0。
_UNCAST_NAME_AGG_RE = re.compile(
    r"array_agg\(\s*(?:DISTINCT\s+)?[A-Za-z_][A-Za-z_0-9]*\.(?:%s)\b(?!\s*::)"
    % "|".join(_NAME_TYPED_CATALOG_COLUMNS))


def _strip_sql_line_comments(sql: str) -> str:
    """剥掉 SQL 的 `--` 行注释。

    ⚠️ 「守卫读哪份文本」本身就是判据的一部分：这是一条**否定**断言，
       而承重注释里往往正好要写出被禁的那个形状来解释它为什么被禁 ——
       不剥注释的话，写清楚理由反而会把自己打红。
    """
    return "\n".join(line.split("--", 1)[0] for line in sql.splitlines())


def _uncast_name_aggregations(sql: str):
    return _UNCAST_NAME_AGG_RE.findall(_strip_sql_line_comments(sql))


def test_scanner_for_uncast_name_aggregation_actually_discriminates():
    """**双向自检**：上面那条扫描必须对坏形状变红、对好形状放行。

    否定断言最常见的失效方式是「正则与代码脱钩之后恒为空」——
    那时它永远为真，而被它保护的判据早已坏掉。
    """
    bad = "SELECT (SELECT array_agg(a.attname ORDER BY a.attname) FROM pg_attribute a) = ARRAY['x']"
    good = "SELECT (SELECT array_agg(a.attname::text ORDER BY a.attname::text) FROM pg_attribute a) = ARRAY['x']"
    assert _uncast_name_aggregations(bad), "扫描器对坏形状不报 —— 它已经失去判别力"
    assert not _uncast_name_aggregations(good), "扫描器对已转型的写法误报"
    # 剥注释这一步本身也要能被证伪：注释里写出坏形状不该把守卫打红。
    commented = "-- 反例：array_agg(a.attname ORDER BY a.attname)\n" + good
    assert not _uncast_name_aggregations(commented), \
        "注释里出现的坏形状被当成了真代码 —— 承重注释会把守卫自己打红"


def test_no_name_typed_catalog_column_is_aggregated_without_a_text_cast():
    """`name[]` 与 `text[]` 之间**没有**相等操作符（真 PostgreSQL 15 实测）：

        SELECT array_agg(a.attname ORDER BY a.attname) … = ARRAY['start_datetime','stock_code']
        → ERROR: operator does not exist: name[] = text[]

    后果不是「这条判据判假」，而是**整条结构查询抛异常**：闸 2 于是在任何库上都
    兜成 `target_db_unreadable`，业务表五组判据**一次都执行不到**。
    它是 fail-closed 的（不放行危险东西），但整条复用路径不可用，
    且错误码把运维指向权限/连通性，而不是「schema 漂移 → 用 --reset 重建」。

    ⚠️ 这条判据在**假件层结构性测不到**：`_FakeConn` 按 SQL 子串派发预置字典，
       SQL 文本一次都不进 PostgreSQL。真语义由 L2 真-PG 脚本坐实
       （`verify_pilot_db_lifecycle.py` 档 ⑰b「健康库复用**必须被放行**」）；
       在没有 PostgreSQL 的 CI 上，这条源码结构守卫是唯一拦得住它的东西。
    ⚠️ 标量 `name = text` 是**合法**的，只有数组没有 —— 故判据只针对
       `array_agg(<别名>.<name 型列>)`，不去禁标量比较。
    """
    import qmt_pilot_db as m
    offenders = {}
    for name, value in vars(m).items():
        if isinstance(value, str) and "array_agg" in value:
            hits = _uncast_name_aggregations(value)
            if hits:
                offenders[name] = hits
    assert not offenders, (
        f"这些模块 SQL 把 name 型目录列聚合成数组却没有 ::text：{offenders}。"
        f"与 text[] 字面量比较时 PostgreSQL 会抛 "
        f"`operator does not exist: name[] = text[]`，"
        f"于是**整条**查询失败、判据一次都执行不到")


# ===========================================================================
# 4a-2 —— 库级五闸（spec §3 子项③）
# ===========================================================================
# 本段以下全部是 4a-2 新增。分节标题对应 spec §4 的闸序列：
#   零对象例外 → 闸 0− → 闸 0 → 闸 0b →（复用时另跑 闸 1 → 闸 2）
# ---------------------------------------------------------------------------
# 闸 0− —— pilot_meta 授权完整性（spec R80-F1，DROP 与复用两条路径都跑）
# ---------------------------------------------------------------------------

def _full_meta_rows(**over):
    """**目标库**的 pilot_meta：九键齐全、seed='probe'、state='ready'。

    ⚠️ 与上面那个 `_meta_rows` 是两回事，别合并：那个建模的是**同侪库**在闸 (ii)
    里的自证（只有阶段 1 的 7 键，因为崩溃残骸也必须放行），本函数建模的是
    **本次目标库**在闸 0−/0/0b/1/2 里的完整元数据。
    """
    base = {"tool": "qmt_pilot", "seed": "probe",
            "schema_sha256": "b" * 64, "pilot_schema_sha256": "c" * 64,
            "contract_version": CONTRACT_VERSION, "export_log_sha256": "a" * 64,
            "output_dir": "/x/y", "created_at": "20260729T101530123456Z",
            "state": "ready"}
    base.update(over)
    return [{"key": k, "value": v} for k, v in base.items() if v is not None]


def test_gate_0minus_missing_pilot_meta_table_is_not_owned():
    """**表不存在 → `not_owned`**，不是 `pilot_meta_ambiguous`（spec O1-F6 收口）。

    ⚠️ 这一条**必须在形状判据之前单独求值**：`_PILOT_META_SHAPE_SQL` 全部走
    `to_regclass('public.pilot_meta')`，表不存在时它返回 NULL → 三个 EXISTS 全 false
    → 与「表在但没有唯一约束」**返回完全一样的东西**。照计划片段那样只靠
    `except Exception` 兜底的实现，在真 PG 上根本走不到 except（形状 SQL 不会抛），
    于是「别人建的、名字恰好撞上的非空库」会被报成「元数据自相矛盾」。
    两者给操作者的下一步动作不同（手工删 vs 交给人查），而报告消费者按这个码分诊。
    """
    conn = _FakeConn(meta_table_present=False, meta_shape={
        "key_is_text": False, "value_is_text": False, "key_is_unique": False})
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(read_pilot_meta(conn))
    assert ei.value.code == "not_owned"


def test_gate_0minus_present_but_bad_shape_is_ambiguous_not_not_owned():
    """反向钉：表**在**但形状不合规 → `pilot_meta_ambiguous`（不能一律报 not_owned）。"""
    conn = _FakeConn(meta_shape={"key_is_text": True, "value_is_text": True,
                                 "key_is_unique": False})
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(read_pilot_meta(conn))
    assert ei.value.code == "pilot_meta_ambiguous"


def test_gate_0minus_rejects_duplicate_key_rows():
    """`key` 上没有唯一约束、塞进**两行 seed** 的库：闸 0/0b 随后读到哪一行
    取决于实现，而 `--reset` 的破坏性正建立在这张表上（spec R79-F2 + R80-F1）。

    形状判据必须**复用 `read_pilot_meta_rows`**，不得另写一份。
    """
    rows = _full_meta_rows() + [{"key": "seed", "value": "other"}]
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(read_pilot_meta(_FakeConn(meta_rows=rows)))
    assert ei.value.code == "pilot_meta_ambiguous"


@pytest.mark.parametrize("missing_key", ["tool", "seed", "export_log_sha256", "output_dir"])
def test_gate_0minus_rejects_missing_authorization_key(missing_key):
    """四个**授权键**任一缺失即拒 —— 闸 0/0b 就是从它们里读值的（spec §4 闸 0− 判据）。

    ⚠️ 逐个参数化而不是只测 `output_dir` 一个：本仓「只修被点名的那一处」已重演十一次，
    单点测试挡不住「判据里只列了三个键」这种写法。
    """
    rows = [r for r in _full_meta_rows() if r["key"] != missing_key]
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(read_pilot_meta(_FakeConn(meta_rows=rows)))
    assert ei.value.code == "pilot_meta_ambiguous"
    assert missing_key in str(ei.value)


def test_gate_0minus_read_failure_is_unreadable_not_not_owned():
    """连进去了但**读失败** → `target_db_unreadable`，**不是** `not_owned`（spec P1r3-F6）。

    `ALTER DATABASE … ALLOW_CONNECTIONS false` 做维护的库、权限被收走的库都落在这里。
    报成 `not_owned` 会给出「这不是本工具建的，请手工删」这个**错误且危险**的下一步动作。
    """
    class _ReadBoom(_FakeConn):
        async def fetchval(self, query, *args):
            if "to_regclass('public.pilot_meta') IS NOT NULL" in query:
                raise RuntimeError("permission denied for database")
            return await super().fetchval(query, *args)

    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(read_pilot_meta(_ReadBoom()))
    assert ei.value.code == "target_db_unreadable"


def test_gate_0minus_pins_search_path_before_reading():
    """闸 0− 的第一条语句必须是 search_path 钉桩（O4-R17-C1 同族）。

    不钉的话，`to_regclass('public.pilot_meta')` 之外的解析都由调用方的 search_path 说了算。
    """
    conn = _FakeConn(meta_rows=_full_meta_rows())
    asyncio.run(read_pilot_meta(conn))
    assert conn.ops[0] == PIN_SEARCH_PATH_SQL, \
        f"闸 0− 的第一条语句是 {conn.ops[0][:60]!r}，不是 search_path 钉桩"


def test_gate_0minus_happy_returns_all_nine_keys():
    got = asyncio.run(read_pilot_meta(_FakeConn(meta_rows=_full_meta_rows())))
    assert got["tool"] == "qmt_pilot" and got["seed"] == "probe"
    assert set(got) == set(PILOT_META_KEYS)


# ---------------------------------------------------------------------------
# 闸 0（归属）/ 0b（绑定）/ state / 闸 1（指纹） + --reset-foreign 令牌
# ---------------------------------------------------------------------------

_REUSE_KW = dict(db_name="kline_pilot_probe", seed="probe",
                 schema_sha256="b" * 64, pilot_schema_sha256="c" * 64,
                 export_log_sha256="a" * 64, output_dir="/x/y")
_RESET_KW = dict(db_name="kline_pilot_probe", seed="probe",
                 export_log_sha256="a" * 64, output_dir="/x/y",
                 reset_foreign_token=None)


def _target_pair(**over):
    """(maint_conn, target_conn)：目标库存在、同机、oid 一致、九键齐全。"""
    target = _FakeConn(meta_rows=_full_meta_rows(**over))
    maint = _FakeConn(databases=["kline_pilot_probe"])
    return maint, target


def _reuse(maint, target, **over):
    kw = {**_REUSE_KW, **over}
    return assert_db_allowed_for_reuse(
        maint, connect=_connector({"kline_pilot_probe": target}), **kw)


def _reset(maint, target, **over):
    kw = {**_RESET_KW, **over}
    return assert_db_allowed_for_reset(
        maint, connect=_connector({"kline_pilot_probe": target}), **kw)


@pytest.mark.parametrize("bad,label", [
    ({"output_dir": None}, "output_dir 缺失 —— 会在 _binding_matches 的 .rstrip 上抛裸 AttributeError"),
    ({"output_dir": ""}, "output_dir 空串 —— rstrip 之后仍是空，会与畸形 pilot_meta 的空绑定判成相符"),
    ({"output_dir": "/"}, "output_dir 只有斜杠 —— 同上，去尾斜杠之后是空绑定"),
    ({"output_dir": "relative/path"}, "output_dir 不是绝对路径"),
    ({"export_log_sha256": None}, "export_log_sha256 缺失"),
    ({"export_log_sha256": "nothex"}, "export_log_sha256 不是 64 位小写十六进制"),
])
@pytest.mark.parametrize("entry", ["reuse", "reset"])
def test_every_public_reset_or_reuse_entry_validates_the_binding_scalars(entry, bad, label):
    """**复用/销毁两条路都要先验调用方标量**（codex 4a-2 R13-F1，high）。

    建库路径早就有 `assert_identity_scalars`，而它**全模块只有那一个调用点** ——
    reset / 复用把调用方递进来的 `export_log_sha256` / `output_dir` **原样**
    送进破坏性闸：
      · `output_dir=None` → `_binding_matches` 的 `.rstrip('/')` 抛**裸 AttributeError**，
        而且是在集群闸与目标库连接**都做完之后**（spec §9-1w 明令禁止把一次守卫
        记成 FAIL_INFRASTRUCTURE）；
      · `output_dir=''` / `'/'` → 去尾斜杠后是空串，遇到 `output_dir` 为空的**畸形
        pilot_meta** 就判成「绑定相符」→ 在一个不该匹配的库上放行销毁授权。
    这与「缺失/畸形的调用方标量一律 fail-closed」的契约不符，而这条路径的下一步
    是不可逆的 `DROP DATABASE`。

    ⚠️ **塌缩之后这一族只剩两个入口**（`authorize_reset` 已删）：`try_empty_remnant_exception`
       的签名里根本没有这两个标量（空残骸那条路不用它们），故它不属于本族。
       「收了这两个标量的 public 入口都要验」这条**性质**由下面那颗机械钉子按签名扫，
       不靠这里的点名清单。
    """
    maint = _FakeConn(databases=["kline_pilot_probe"])
    target = _FakeConn(meta_rows=_full_meta_rows())
    run = {"reuse": _reuse, "reset": _reset}[entry]
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(run(maint, target, **bad))
    assert ei.value.code == "identity_scalar_invalid", f"{entry} / {label}"


@pytest.mark.parametrize("entry", ["reuse", "reset"])
def test_binding_scalar_guard_runs_before_touching_the_target_database(entry):
    """**在碰目标库之前**就拦下（codex R13-F1 的要害之一）。

    验在后面等于「先连进去、先跑集群闸、再发现调用方给的是垃圾」——
    副作用与诊断都错位。判据：拒绝时**一次都没连过目标库**。
    """
    connects = []

    async def _counting(dbname):
        connects.append(dbname)
        raise AssertionError("不该连目标库 —— 标量应该在这之前就被拦下")

    maint = _FakeConn(databases=["kline_pilot_probe"])
    kw = {"db_name": "kline_pilot_probe", "seed": "probe",
          "export_log_sha256": "a" * 64, "output_dir": None}
    if entry == "reuse":
        kw.update(schema_sha256="s", pilot_schema_sha256="p")
        call = assert_db_allowed_for_reuse(maint, connect=_counting, **kw)
    else:
        call = assert_db_allowed_for_reset(maint, connect=_counting,
                                           reset_foreign_token=None, **kw)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(call)
    assert ei.value.code == "identity_scalar_invalid"
    assert connects == [], f"标量还没验就连了目标库：{connects}"


def test_binding_scalar_guard_is_reachable_from_every_entry_that_takes_them():
    """**机械守卫**：凡是签名里带这两个标量的 public 入口，都必须验它们。

    「记得在新入口也验一遍」是纪律，而纪律在这套代码里已经失效过十几次。
    这一条让「新加一个收这两个标量的 public 入口却忘了验」当场变红。
    """
    import ast
    import inspect
    import qmt_pilot_db as m
    tree = ast.parse(inspect.getsource(m))

    def _entries_taking_binding_scalars():
        # ⚠️ 只扫**会碰数据库的**（async）public 入口。判据是「性质」不是「点名」：
        #    `assert_binding_scalars` 自己是那条守卫；`derive_confirm_token` 是**纯派生**，
        #    它的输入来自库里的 pilot_meta（已过闸 0− 的非空/形状判据），
        #    不是调用方递进来的，也不授权任何东西 —— 两者都不属于本判据要覆盖的族。
        found = []
        for node in ast.walk(tree):
            if not isinstance(node, ast.AsyncFunctionDef):
                continue
            if node.name.startswith("_"):
                continue                  # 私有的由 public 入口负责
            names = ({a.arg for a in node.args.args}
                     | {a.arg for a in node.args.kwonlyargs})
            if {"export_log_sha256", "output_dir"} <= names:
                found.append(node)
        return found

    entries = _entries_taking_binding_scalars()
    # ⚠️ **反向自检必须走同一个扫描器**：上一版把扫描逻辑又抄了一遍去自检，
    #    于是破坏主循环的判据时自检照样绿 —— 自检守的是副本不是本体（变异当场抓到）。
    assert entries, "扫描器一个入口都没找到 —— 它已经失去判别力，下面那条会恒真"
    guards = {"assert_binding_scalars", "assert_identity_scalars"}
    missing = [n.name for n in entries
               if not ({c.func.id for c in ast.walk(n)
                        if isinstance(c, ast.Call) and isinstance(c.func, ast.Name)}
                       & guards)]
    assert not missing, (
        f"这些 public 入口收了 export_log_sha256/output_dir 却没验它们：{missing}"
        f" —— 破坏性路径上的调用方标量必须 fail-closed")


# ── 闸 0 归属 ──────────────────────────────────────────────────────────

@pytest.mark.parametrize("over,label", [
    ({"seed": "someone_else"}, "seed 不符"),
    ({"tool": "something_else"}, "tool 不符"),
])
def test_reuse_rejects_ownership_mismatch(over, label):
    maint, target = _target_pair(**over)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "not_owned", label


def test_reset_ownership_mismatch_never_offers_a_token():
    """归属不过时**不给令牌**——令牌只解「同 seed 但绑定不同」这一档（spec R3-F1）。

    归属不符意味着这个库根本不是本工具建的，唯一出路是人工删；
    给出令牌等于把「换个参数就能删掉别人的库」写进错误提示里。
    """
    maint, target = _target_pair(tool="something_else")
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset(maint, target))
    assert ei.value.code == "not_owned"
    assert ei.value.confirm_token is None


# ── 闸 0b 绑定 ─────────────────────────────────────────────────────────

@pytest.mark.parametrize("over,label", [
    ({"export_log_sha256": "d" * 64}, "源快照不同"),
    ({"output_dir": "/other"}, "输出目录不同"),
])
def test_reuse_rejects_binding_mismatch(over, label):
    """两个绑定字段**各自**都要比 —— 只比其中一个的实现在另一档上放行（spec R7-F1）。"""
    maint, target = _target_pair(**over)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "binding_mismatch", label


def test_reuse_binding_compares_output_dir_without_trailing_slash():
    """建库时存的是 `output_dir.rstrip('/')`，复用时传的可能带尾斜杠 —— 必须归一后比。

    不归一的实现会让**同一套设置**的第二次运行被判成「别人的库」。
    """
    maint, target = _target_pair()
    asyncio.run(_reuse(maint, target, output_dir="/x/y/"))     # 不抛 = 放行


def test_reset_binding_mismatch_requires_token_and_prints_identity():
    """`--reset` 绑定不符 → **`reset_foreign_token_required`**（spec §5，不是 binding_mismatch）
    并打印所绑身份 + 派生令牌（R34-F1）。

    ⚠️ 计划片段这里写的是 `binding_mismatch`，与 spec §5 的错误码表冲突；
       4c 报告消费者按这个码分诊「换个 seed」与「要令牌才能删」两种完全不同的处置。
    """
    maint, target = _target_pair(output_dir="/someone_else")
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset(maint, target))
    assert ei.value.code == "reset_foreign_token_required"
    assert ei.value.confirm_token == derive_confirm_token(
        "a" * 64, "/someone_else", "20260729T101530123456Z")
    assert ei.value.identity["output_dir"] == "/someone_else"
    assert ei.value.identity["created_at"] == "20260729T101530123456Z"
    # 身份里只放哈希前 12 位（spec §5：打印给操作者看的是身份不是原文）
    assert ei.value.identity["export_log_sha256"] == "a" * 12


def test_reset_wrong_token_refused():
    maint, target = _target_pair(output_dir="/someone_else")
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset(maint, target, reset_foreign_token="deadbeefcafe"))
    assert ei.value.code == "reset_foreign_token_invalid"


def test_reset_correct_token_allowed_and_returns_authorized_oid():
    """令牌逐字相符 → 放行，并**返回被授权的那个实例 oid（裸 str）**。

    返回 oid 不是锦上添花：`DROP DATABASE` 无法带谓词，授权与 DROP 之间同名库可以被
    删掉又重建。不把授权绑到实例上，`--reset` 会去删一个**从未被授权**的替身。

    ⚠️ **不再带出「授权那一刻该库自称的身份」**（撤销 R3-F1 的 `ResetGateOutcome`）：
       塌缩之后判定与 DROP 在**同一次调用**里，复验的判据是「拿**本次入参**在封锁下
       重跑一遍闸 0/0b/令牌」，不是「和记下来的身份比对」。带出去的身份快照没有消费者，
       而一个没人消费的授权前提快照正是本 PR 删掉的那类负债。
    """
    maint, target = _target_pair(output_dir="/someone_else")
    token = derive_confirm_token("a" * 64, "/someone_else", "20260729T101530123456Z")
    assert asyncio.run(_reset(maint, target, reset_foreign_token=token)) == "16400"


def test_reset_binding_match_returns_authorized_oid_without_token():
    maint, target = _target_pair()
    assert asyncio.run(_reset(maint, target)) == "16400"


def test_reset_missing_created_at_cannot_derive_token():
    """绑定不符而 `created_at` 缺失 → 派生不出令牌 → 提示人工删库（spec §4 闸 0− 注）。

    `created_at` **刻意不在**四个授权键里，所以它可以合法缺席；此时唯一诚实的
    答复是「本工具给不出令牌」，而不是拿空串硬算一个谁都填不对的令牌。
    """
    maint, target = _target_pair(output_dir="/someone_else", created_at=None)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset(maint, target))
    assert ei.value.code == "confirm_token_underivable"


# ── state / 闸 1 指纹 ──────────────────────────────────────────────────

def test_reuse_rejects_initializing_before_fingerprint_gate():
    """`state='initializing'` 必须在**闸 1（指纹）之前**求值（spec O4-F8）。

    阶段 1 只写 7 个键、`schema_sha256` 尚未定稿，闸 1 会先撞「值不符」并报
    `schema_fingerprint_mismatch` → **`db_state_initializing` 永远产不出来**，
    恢复指引也从「用 --reset 重建」错成「schema 漂移」。
    本用例故意让指纹**也**不符：次序写反时拿到的会是指纹码。
    """
    maint, target = _target_pair(state="initializing", schema_sha256="zzz")
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "db_state_initializing", \
        "initializing 必须先于指纹闸命中，否则报的是 schema_fingerprint_mismatch"


@pytest.mark.parametrize("over,label", [
    ({"schema_sha256": "d" * 64}, "schema.sql 漂移"),
    ({"pilot_schema_sha256": "d" * 64}, "pilot_schema.sql 漂移（R63-F1）"),
    ({"contract_version": "9.99"}, "contract_version 漂移"),
])
def test_reuse_rejects_fingerprint_drift(over, label):
    """指纹闸必须**三项都比** —— 只比 schema_sha256 的实现会让另外两项完全失明。"""
    maint, target = _target_pair(**over)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "schema_fingerprint_mismatch", label


def test_reset_allows_fingerprint_drift():
    """**反向钉（分寸不能过头，spec R49-F2）**：归属与绑定都相符、但 schema_sha256
    已漂移的库带 `--reset` → **必须放行到 DROP**。

    把指纹/结构闸也塞进 `--reset` 分支的实现会让陈旧 schema 的库连 reset 都做不了，
    而 reset 是它唯一的出路。
    """
    maint, target = _target_pair(schema_sha256="d" * 64)
    asyncio.run(_reset(maint, target))                          # 不抛 = 放行


def test_reset_allows_initializing():
    """`--reset` 时 initializing 照常走归属闸 + 绑定闸（两者所需的键阶段 1 就已写入），
    故**能被正常清掉重来**（spec R55-F1）。"""
    maint, target = _target_pair(state="initializing")
    asyncio.run(_reset(maint, target))


def test_reset_allows_库_with_only_phase1_keys():
    """崩在 apply schema 之前的库只有阶段 1 的 7 键 —— `--reset` 必须清得掉。

    把「九键齐全」塞进 DROP 路径的实现会在此变红，那正是 R55-F1 的锁死。
    """
    maint, target = _target_pair(schema_sha256=None, contract_version=None,
                                 state="initializing")
    asyncio.run(_reset(maint, target))


# ── 连接的接管与短连接纪律 ──────────────────────────────────────────────

@pytest.mark.parametrize("mutate,code", [
    (lambda t: setattr(t, "current_database", "kline_pilot_other"), "connection_wrong_database"),
    (lambda t: setattr(t, "cluster_id", "cluster-B"), "connection_wrong_cluster"),
    (lambda t: setattr(t, "current_db_oid", "99999"), "connection_wrong_instance"),
])
def test_reuse_adopts_target_connection_before_reading(mutate, code):
    """每条守卫连接先 `adopt_connection`：钉 search_path + 证明**库/集群/实例**（spec O4-R28/29/35）。

    `connect(name)` 返回什么就用什么是一条没被验过的调用方断言 —— DSN 被改写、
    连接池串了、同名不同机、名字对但已是替身，读到的 pilot_meta 都与本次要判的对象无关。
    """
    maint, target = _target_pair()
    mutate(target)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == code


@pytest.mark.parametrize("run,label", [
    (lambda m, t: _reuse(m, t), "复用"),
    (lambda m, t: _reset(m, t), "reset"),
])
def test_gates_close_the_target_connection_on_success(run, label):
    """读一律短连接：闸跑完必须把目标库连接关掉（spec O1-F2 规定 1）。

    留着不关，随后的 `DROP DATABASE` 会撞 `is being accessed by other users`——
    而那正是 reset 这条「唯一出路」最常见的失败方式。
    """
    maint, target = _target_pair()
    asyncio.run(run(maint, target))
    assert target.closed is True, label


@pytest.mark.parametrize("run,label", [
    (lambda m, t: _reuse(m, t), "复用"),
    (lambda m, t: _reset(m, t), "reset"),
])
def test_gates_close_the_target_connection_on_failure(run, label):
    """闸**拒绝**时同样要关连接 —— 泄漏的会话会把之后的 DROP 顶住（O4-R24-C2 同族）。"""
    maint, target = _target_pair(tool="something_else")
    with pytest.raises(PilotDbBoundaryError):
        asyncio.run(run(maint, target))
    assert target.closed is True, label


@pytest.mark.parametrize("gate,kw,label", [
    (assert_db_allowed_for_reuse, _REUSE_KW, "复用"),
    (assert_db_allowed_for_reset, _RESET_KW, "reset"),
])
def test_gates_map_connect_failure_to_target_db_unreadable(gate, kw, label):
    """连不进目标库 → `target_db_unreadable`（spec P1r3-F6）。

    ⚠️ 绝不能 `try/except` 当成「没查到对象」：那会让一个被 DBA
    `ALTER DATABASE … ALLOW_CONNECTIONS false` 冻结的库被判【绝对空】而直接 DROP。
    """
    maint = _FakeConn(databases=["kline_pilot_probe"])
    with pytest.raises(PilotDbBoundaryError) as ei:
        # `_connector({})` = 任何库都连不上
        asyncio.run(gate(maint, connect=_connector({}), **kw))
    assert ei.value.code == "target_db_unreadable", label


@pytest.mark.parametrize("run,label", [
    (lambda m, t: _reuse(m, t, db_name="kline_pilot_other"), "复用"),
    (lambda m, t: _reset(m, t, db_name="kline_pilot_other"), "reset"),
])
def test_gates_reject_seed_db_name_mismatch(run, label):
    """`db_name` 必须就是 `derive_db_name(seed)` —— 两者脱钩时闸判的库与 DDL 作用的库不是同一个。"""
    maint, target = _target_pair()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(run(maint, target))
    assert ei.value.code == "seed_db_name_mismatch", label


def test_reuse_happy_path_returns_none():
    maint, target = _target_pair()
    assert asyncio.run(_reuse(maint, target)) is None


# ---------------------------------------------------------------------------
# 闸 2 —— 结构断言七组（spec §4「结构断言（复用纵深防御副闸）」）
# ---------------------------------------------------------------------------
# ⚠️ **这一闸在计划里被整条推给了 L2 脚本**（"由调用方在真库上跑"），而 spec §4 的
#    闸分工表明写「闸 2 复用时 ✅ 必过」。只放在验收脚本里的话，4c 调
#    assert_db_allowed_for_reuse 时闸 2 在**生产路径上根本不存在**，
#    `structure_mismatch` 永远产不出来，而它防的是「指纹对但库被手工 ALTER 过」。

@pytest.mark.parametrize("field", sorted(_OK_BUSINESS_STRUCTURE))
def test_reuse_rejects_business_structure_drift(field):
    """业务表五组断言**逐条**都要有判别力（spec §4：OHLC 类型 / stock_coverage /
    file_path 类型 / content_hash 列 / uq_stock_start 约束 / 三张表真的是表）。

    ⚠️ 逐字段参数化而不是只造一种坏库：只测一条的写法挡不住「判据里只 and 了三项」。
    """
    maint, target = _target_pair()
    target.business_structure = {**_OK_BUSINESS_STRUCTURE, field: False}
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "structure_mismatch"
    assert field in str(ei.value), "错误信息必须点名是哪一条判据不成立"


@pytest.mark.parametrize("field", sorted(_OK_PILOT_SHAPE))
def test_reuse_rejects_pilot_table_structure_drift(field):
    """`pilot_stock_source` 与 `pilot_meta` 自身也在闸 2 里（spec R12-F2 + R79-F2）。

    判据**复用 `_PILOT_SCHEMA_SHAPE_SQL`** —— 与建库时证明「apply 完 pilot_schema.sql
    结构确实对」的是同一份 SQL，不另写第二份（漂移必然发生，漏一条就是静默放行）。
    """
    maint, target = _target_pair()
    target.pilot_schema_shape = {**_OK_PILOT_SHAPE, field: False}
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "structure_mismatch"


def test_reuse_rejects_pilot_meta_missing_created_at():
    """闸 2 要求 `pilot_meta` **九个键一个不缺**（spec §4）。

    ⚠️ 九个键里只有 `created_at` 走得到这一闸：`tool`/`seed` 归闸 0，
    两个绑定键归闸 0b，`state` 归 state 档，三个指纹键归闸 1。
    而 `created_at` 正是 `confirm_token` 的原像 —— 它缺席时**没有任何更早的闸**会发现，
    直到某天要 `--reset-foreign` 才发现令牌派生不出来、库认不回自己。
    """
    maint, target = _target_pair(created_at=None)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "structure_mismatch"
    assert "created_at" in str(ei.value)


@pytest.mark.parametrize("break_it,label", [
    (lambda t: setattr(t, "business_structure",
                       {**_OK_BUSINESS_STRUCTURE, "uq_stock_start_present": False}), "业务表结构"),
    (lambda t: setattr(t, "pilot_schema_shape",
                       {**_OK_PILOT_SHAPE, "source_is_table": False}), "pilot 表结构"),
])
def test_reset_does_not_run_the_structure_gate(break_it, label):
    """**反向钉（分寸不能过头，spec R49-F2 + 闸分工表）**：闸 2 在 `--reset` 时**不跑**。

    结构坏掉的库恰恰最需要 reset；把闸 2 塞进 DROP 路径会让它连 reset 都做不了。
    """
    maint, target = _target_pair()
    break_it(target)
    asyncio.run(_reset(maint, target))                          # 不抛 = 放行


def test_business_structure_fake_covers_every_predicate():
    """机械守卫：`_BUSINESS_STRUCTURE_SQL` 的判据集合必须与假件的权威副本逐一对应。

    假件漏建模一条判据，对应的用例就在一个 KeyError / 恒真上空转
    （与既有的 `test_every_guard_table_shape_proof_covers_table_level_durability` 同族）。
    """
    import re
    import qmt_pilot_db as m
    fields = set(re.findall(r"AS ([a-z_]+)", m._BUSINESS_STRUCTURE_SQL))
    assert fields == set(_OK_BUSINESS_STRUCTURE), (
        f"SQL 有 {sorted(fields - set(_OK_BUSINESS_STRUCTURE))}，"
        f"假件多出 {sorted(set(_OK_BUSINESS_STRUCTURE) - fields)}")
    # spec §4 逐条点名的五组，一条都不许漏（判据挂在 SQL 文本上，改名即变红）
    for token in ("public.klines", "public.stock_coverage", "public.training_sets",
                  "'double precision'", "uq_stock_start", "content_hash", "file_path"):
        assert token in m._BUSINESS_STRUCTURE_SQL, f"闸 2 缺 spec 点名的判据 {token!r}"


def test_structure_gate_reuses_the_module_sql_constants():
    """闸 2 **必须引用模块常量**，不得内联第二份 SQL。

    另写一份必然漂移（本仓已重演十一次），而漏一条就是静默放行。

    ⚠️ 判据走 **AST 的 Name 节点**，不是 `"_PILOT_SCHEMA_SHAPE_SQL" in 源码文本`：
       后者被**本函数自己的 docstring** 满足 —— 我第一版就是那么写的，
       变异（把常量换成内联字面量）跑出来**仍然是绿的**。恒真断言的又一种形态。
    """
    import ast
    import inspect
    import textwrap
    import qmt_pilot_db as m
    tree = ast.parse(textwrap.dedent(inspect.getsource(m._assert_structure)))
    names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
    for const in ("_BUSINESS_STRUCTURE_SQL", "_PILOT_SCHEMA_SHAPE_SQL"):
        assert const in names, f"闸 2 没有引用 {const} —— 第二份判据一定会漂移"
    inlined = [n.value for n in ast.walk(tree)
               if isinstance(n, ast.Constant) and isinstance(n.value, str)
               and "SELECT" in n.value.upper()]
    assert not inlined, f"闸 2 里有内联 SQL 字面量：{inlined}"


# ── codex 4a-2a R5：验锁前必须先钉 search_path / 闸 0− 拒绝 NULL 值 ──────────
# ⚠️ 这两条都是**我在 R4 修复时自己引入的**：R4 把验锁加在了任何钉桩之前；
#    而 R4 之后 reset 才会走到 _bound_identity，NULL 值的裸 TypeError 由此暴露。

_SEED_LOCK_PIN_WHY = """`_SEED_LOCK_HELD_SQL` 用的是不限定的 `pg_locks` / `pg_backend_pid()` /
`hashtext()`。敌意或残留的 search_path 把一个可写 schema 排在 `pg_catalog` 之前时，
这三个名字都能被遮蔽 → **锁的证明返回 true 而锁并不存在**，破坏性窗口原样打开。
凡是自己发起这条证明的函数都是 public 的，**不能靠调用方会先跑别的闸**这条纪律来保证钉桩。"""


def _assert_pinned_before_lock_proof(maint):
    lock_at = next(i for i, q in enumerate(maint.ops) if "pg_locks" in q)
    pins_before = [i for i, q in enumerate(maint.ops)
                   if q == PIN_SEARCH_PATH_SQL and i < lock_at]
    assert pins_before, "验锁之前没有钉 search_path"


def test_reset_pins_search_path_before_proving_the_seed_lock():
    """见 `_SEED_LOCK_PIN_WHY`（codex 4a-2a R5-F1 —— 这是我在 R4 加验锁时自己引入的）。"""
    maint = _FakeConn(databases=["kline_pilot_probe"])
    target = _FakeConn(meta_rows=_full_meta_rows())
    asyncio.run(assert_db_allowed_for_reset(
        maint, connect=_connector({"kline_pilot_probe": target}), **_RESET_KW))
    _assert_pinned_before_lock_proof(maint)


@pytest.mark.parametrize("null_key", ["export_log_sha256", "output_dir", "created_at"])
def test_gate_0minus_rejects_null_pilot_meta_values(null_key):
    """`value` 为 NULL 的 pilot_meta 必须在闸 0− 就被拒（codex R5-F2）。

    形状判据只要求 `value` 是 text，没要求 NOT NULL。一张
    `export_log_sha256 = NULL` 的表过得了归属闸，随后 `_bound_identity` 在
    `None[:12]` 上抛**裸 TypeError** —— 一次正确的 fail-closed 守卫会被 4c 记成
    `FAIL_INFRASTRUCTURE`（§9-1w 明令禁止），而 `derive_confirm_token` 也拿不到原像。
    """
    rows = [r if r["key"] != null_key else {"key": null_key, "value": None}
            for r in _full_meta_rows()]
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(read_pilot_meta(_FakeConn(meta_rows=rows)))
    assert ei.value.code == "pilot_meta_ambiguous"
    assert null_key in str(ei.value)


def test_reset_with_null_binding_value_is_a_boundary_error_not_a_typeerror():
    """端到端：NULL 绑定值走 `--reset` 时拿到的是 `PilotDbBoundaryError` 而非 TypeError。"""
    maint = _FakeConn(databases=["kline_pilot_probe"])
    rows = [r if r["key"] != "export_log_sha256"
            else {"key": "export_log_sha256", "value": None}
            for r in _full_meta_rows()]
    target = _FakeConn(meta_rows=rows)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reset(
            maint, connect=_connector({"kline_pilot_probe": target}), **_RESET_KW))
    assert ei.value.code == "pilot_meta_ambiguous"


def test_pilot_meta_shape_proof_requires_not_null():
    """结构性纵深：同一张表的**两份**形状证明必须对 NOT NULL 说法一致。

    `_PILOT_SCHEMA_SHAPE_SQL` 的 meta_columns_ok 早就要求 `attnotnull`，
    而闸 0− 的 `_PILOT_META_SHAPE_SQL` 此前没有 —— 同族判据分叉正是本仓反复踩的形态。
    """
    import qmt_pilot_db as m
    assert "a.attnotnull" in m._PILOT_META_SHAPE_SQL, \
        "闸 0− 的形状证明没要求 value NOT NULL"
    assert "a.attnotnull" in m._PILOT_SCHEMA_SHAPE_SQL


# ---------------------------------------------------------------------------


# ── codex 4a-2a R1（high）：复用前必须重跑建库时那组**活体**判据 ──────────
# 原实现的闸 2 只看「列在不在、类型对不对、约束名有没有」。一个 ready 之后被改过的库
# ——加个触发器、改个默认值、把 uq_stock_start 换成别的列——照样通过复用闸，
# 随后 B1/B2 在坏 schema 上读写。而在 DB 边界拦下正是这道闸存在的全部理由。

def test_reuse_rejects_business_behavior_objects_added_after_ready():
    """往 public.klines 上装一个 INSERT 触发器：列/约束/默认值/索引/序列全不变，
    **活目录指纹一个字都不动**，而此后每一次导入都被它改写。"""
    maint, target = _target_pair()
    target.business_table_behavior = {**_FakeConn().business_table_behavior,
                                      "user_triggers": 1}
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "business_tables_have_dependents"


def test_reuse_rejects_pilot_table_dependents_added_after_ready():
    """pilot 表上多出来的触发器能就地改写 state 与指纹，额外索引/约束能改变
    来源代次写入的语义。"""
    maint, target = _target_pair()
    target.pilot_table_dependents = {**_FakeConn().pilot_table_dependents,
                                     "extra_indexes": 1}
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "pilot_tables_have_dependents"


def test_reuse_rejects_live_catalog_drift():
    """`ALTER TABLE … ALTER COLUMN status SET DEFAULT 'sent'` 之类不动表名/列名/类型，
    只有活目录指纹看得见（O4-R33-C1 建库侧已有此钉，复用侧此前是空的）。"""
    maint, target = _target_pair()
    target.business_catalog_text = _CANON_CATALOG_TEXT + "\n-- 被人手工改过一笔"
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "business_schema_drift"


@pytest.mark.parametrize("break_it,label", [
    (lambda t: setattr(t, "business_table_behavior",
                       {**_FakeConn().business_table_behavior, "user_triggers": 1}), "业务表行为对象"),
    (lambda t: setattr(t, "pilot_table_dependents",
                       {**_FakeConn().pilot_table_dependents, "extra_indexes": 1}), "pilot 表依赖物"),
    (lambda t: setattr(t, "business_catalog_text", "drifted"), "活目录指纹漂移"),
])
def test_reset_does_not_run_the_live_health_checks(break_it, label):
    """**反向钉**：这三条同样只属于复用路径。被改坏的库最需要 reset，
    把它们塞进 DROP 路径会让它连 reset 都做不了（R49-F2）。"""
    maint, target = _target_pair()
    break_it(target)
    asyncio.run(_reset(maint, target))                          # 不抛 = 放行


def test_reuse_and_create_share_the_same_live_health_predicates():
    """机械守卫：建库路径与复用路径必须调**同一组** helper，不得各写一份。

    codex 4a-2a R1 正是从「复用路径根本没跑这几条」来的；
    两处各写一遍则必然漂移（本仓已重演十一次）。
    """
    import ast
    import inspect
    import textwrap
    import qmt_pilot_db as m
    shared = {"_assert_no_business_behavior_objects",
              "_assert_no_pilot_table_dependents",
              "_assert_live_catalog_matches_canonical"}
    for fn in (m._assert_structure, m.create_pilot_database):
        tree = ast.parse(textwrap.dedent(inspect.getsource(fn)))
        names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
        assert shared <= names, f"{fn.__name__} 少调了 {sorted(shared - names)}"
    # 反向断言：三个 helper 里的判据 SQL 必须来自模块常量，不得内联第二份
    for name in shared:
        tree = ast.parse(textwrap.dedent(inspect.getsource(getattr(m, name))))
        inlined = [n.value for n in ast.walk(tree)
                   if isinstance(n, ast.Constant) and isinstance(n.value, str)
                   and "SELECT" in n.value.upper()]
        assert not inlined, f"{name} 里有内联 SQL：{inlined}"


def test_business_structure_covers_every_required_business_table():
    """业务表清单必须**从 `REQUIRED_BUSINESS_TABLES` 派生**（codex 4a-2a R1：原来漏了
    `stocks` —— 它是 klines 的外键目标，没了它导入必然失败，而闸照样放行）。"""
    import qmt_pilot_db as m
    for t in REQUIRED_BUSINESS_TABLES:
        assert f"to_regclass('public.{t}')" in m._BUSINESS_STRUCTURE_SQL, \
            f"闸 2 的业务表清单漏了 {t}"
    assert f"= {len(REQUIRED_BUSINESS_TABLES)}" in m._BUSINESS_STRUCTURE_SQL, \
        "计数阈值没跟着 REQUIRED_BUSINESS_TABLES 走"


def test_uq_stock_start_predicate_really_compares_the_columns():
    """机械守卫：`uq_stock_start` 的**列**必须真的被比对。

    ⚠️ host 假件直接喂 `uq_stock_start_columns_ok` 的布尔，SQL 文本在 L1 是**零覆盖**的
       —— 把列比对换成 `IS NOT NULL`，上面那组参数化用例**全都照样是绿的**（实测）。
       所以这里改钉 SQL 文本：删掉 uq_stock_start、用同名但不同列重建时，
       只看名字的判据照样为真，而 already_done 与写入去重整个建立在
       (stock_code, start_datetime) 这一对列上。
    """
    import qmt_pilot_db as m
    sql = m._BUSINESS_STRUCTURE_SQL
    assert "k.conkey" in sql, "没有取出约束的列集合"
    assert "ARRAY['start_datetime', 'stock_code']" in sql, \
        "没有把约束的列集合与 (stock_code, start_datetime) 逐一比对"


# ── codex 4a-2a R2：关不掉自己的探测连接就不许发 DROP 授权 / 活体判据读失败要归一 ──

class _UncloseableConn(_FakeConn):
    async def close(self):
        raise RuntimeError("connection reset by peer")


def test_reset_refuses_authorization_when_it_cannot_release_its_own_session():
    """关不掉自己那条探测会话 → **不发 DROP 授权**（codex R2-F1，high）。

    否则随后的 `DROP DATABASE` 必然被它自己顶住，而操作者拿到的诊断是
    「有别人连着这个库」—— 那个「别人」就是我们自己。
    """
    maint = _FakeConn(databases=["kline_pilot_probe"])
    target = _UncloseableConn(meta_rows=_full_meta_rows())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reset(
            maint, connect=_connector({"kline_pilot_probe": target}), **_RESET_KW))
    assert ei.value.code == "target_db_in_use"


def test_close_failure_never_masks_the_gate_verdict():
    """闸**本身**拒绝时，关不掉连接不得顶掉那个结论（Python finally 语义，O4-W2r1 M-2）。

    拿到 target_db_in_use 而不是 not_owned 的话，操作者会去查「谁连着」，
    而真相是「这个库根本不是本工具建的」。
    """
    maint = _FakeConn(databases=["kline_pilot_probe"])
    target = _UncloseableConn(meta_rows=_full_meta_rows(tool="something_else"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reset(
            maint, connect=_connector({"kline_pilot_probe": target}), **_RESET_KW))
    assert ei.value.code == "not_owned", "闸的结论被 close 失败顶掉了"


def test_reuse_does_not_fail_closed_on_close_failure():
    """**刻意的不对称**（钉住，免得下一轮当成同族遗漏「顺手补上」）：

    复用路径不 DROP，一条没关掉的会话不构成 DROP 危险；在这里也 fail-closed
    会让一次本可以正常复用的运行因为一个 close 抖动而失败。
    「DROP 之前连接数为 0」这条规定管的是**发放销毁授权**的路径。
    """
    maint = _FakeConn(databases=["kline_pilot_probe"])
    target = _UncloseableConn(meta_rows=_full_meta_rows())
    assert asyncio.run(assert_db_allowed_for_reuse(
        maint, connect=_connector({"kline_pilot_probe": target}), **_REUSE_KW)) is None


@pytest.mark.parametrize("attr,label", [
    ("business_table_behavior", "业务表行为对象"),
    ("pilot_table_dependents", "pilot 表依赖物"),
    ("business_catalog_text", "活目录指纹"),
])
def test_live_health_read_failure_is_a_boundary_error_not_a_raw_exception(attr, label):
    """活体判据读失败 → `target_db_unreadable`，不得裸逃（codex R2-F2）。

    目标库被并发 DROP / 权限变更 / 目录查询失败都会在这里抛。裸异常会被 4c 兜成
    `FAIL_INFRASTRUCTURE`，而 §9-1w 明令禁止把一次成功的 fail-closed 守卫记成环境故障。
    """
    maint, target = _target_pair()
    boom = RuntimeError("terminating connection due to administrator command")

    if attr == "business_catalog_text":
        class _Boom(_FakeConn):
            async def fetchval(self, query, *args):
                if "--constraints--" in query:
                    raise boom
                return await super().fetchval(query, *args)
    else:
        want = "public.stocks" if attr == "business_table_behavior" else "pilot_meta"

        class _Boom(_FakeConn):
            async def fetchrow(self, query, *args):
                if "user_triggers" in query and want in query:
                    raise boom
                return await super().fetchrow(query, *args)

    target = _Boom(meta_rows=_full_meta_rows())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reuse(maint, target))
    assert ei.value.code == "target_db_unreadable", label


# ── codex 4a-2a R3-F2：确认令牌只走 confirm_token，绝不进 message / identity ──

@pytest.mark.parametrize("token_arg,code", [
    (None, "reset_foreign_token_required"),
    ("deadbeefcafe", "reset_foreign_token_invalid"),
])
def test_confirm_token_never_leaks_into_report_facing_strings(token_arg, code):
    """令牌只走 `confirm_token` 这条专用通道（spec §9-1w + PilotDbBoundaryError 契约）。

    把它写进 message 的话，任何把 `str(exc)` 或 `identity` 序列化进报告/日志的调用方
    都会漏出去 —— 于是 wrapper 可以「读报告取令牌再重跑」，
    **「知情同意」退化成两步自动化**，而那正是这个令牌被引入来防的事。
    """
    import json
    maint, target = _target_pair(output_dir="/someone_else")
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset(maint, target, reset_foreign_token=token_arg))
    exc = ei.value
    assert exc.code == code
    token = derive_confirm_token("a" * 64, "/someone_else", "20260729T101530123456Z")
    assert exc.confirm_token == token, "专用通道里必须有令牌，否则操作者拿不到它"
    assert token not in str(exc), "令牌漏进了 message"
    assert token not in json.dumps(exc.identity, ensure_ascii=False), "令牌漏进了 identity"


# ── codex 4a-2a R3-F1（user 拍板）：闸 0r —— 复用路径要外部归属凭据 ────────

def test_reuse_requires_an_external_registry_proof():
    """闸 0 读的全是「被判对象自己写的字」。同侪库（闸 ii）早就因此要求两个独立事实，
    而目标库这一侧一直只有自证 —— 一个抄来 pilot_meta、绑定又恰好相符的同名外来库
    会被当成本工具建的库拿去装真数据。"""
    maint = _FakeConn(databases=["kline_pilot_probe"], registered_dbnames=set())
    target = _FakeConn(meta_rows=_full_meta_rows())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reuse(
            maint, connect=_connector({"kline_pilot_probe": target}), **_REUSE_KW))
    assert ei.value.code == "registry_proof_missing"


def test_reuse_registry_proof_read_failure_is_fail_closed():
    """读不到登记 = 证明不了归属 = 拒绝复用（绝不 try/except 当成「没查到」）。"""
    class _RegistryBoom(_FakeConn):
        async def fetchval(self, query, *args):
            if "pilot_database_registry" in query:
                raise RuntimeError("maintenance db unreachable")
            return await super().fetchval(query, *args)

    maint = _RegistryBoom(databases=["kline_pilot_probe"])
    target = _FakeConn(meta_rows=_full_meta_rows())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reuse(
            maint, connect=_connector({"kline_pilot_probe": target}), **_REUSE_KW))
    assert ei.value.code == "registry_proof_missing"


def test_reset_does_not_require_the_registry_proof():
    """**刻意的不对称，钉住它**（user 2026-08-05 拍板）：

    登记表在维护库里、本工具从不清它。一旦维护库被重新初始化，若 `--reset` 也要这条
    凭据，非空 pilot 库就**再也清不掉**了 —— 那正是 spec 花整轮移除的 R55-F1 锁死。
    复用被拒时逃生口仍在：`--reset` 重建。
    下一轮若有人「顺手把 registry 闸也补到 reset 上」，这颗钉子当场变红。
    """
    maint = _FakeConn(databases=["kline_pilot_probe"], registered_dbnames=set())
    target = _FakeConn(meta_rows=_full_meta_rows())
    assert asyncio.run(assert_db_allowed_for_reset(
        maint, connect=_connector({"kline_pilot_probe": target}),
        **_RESET_KW)) == "16400"


def test_registry_proof_is_instance_bound_not_name_bound():
    """机械守卫：这条外部凭据必须走 `_REGISTRY_HAS_SQL`（它 JOIN 了 pg_database.oid）。

    只按名字查的话，「我们建过这个名字、库被删了、别人用同名重建」这一档
    仍然过得了 —— 陈旧的名字凭据会为一个全新的、不是我们建的库背书。
    ⚠️ 判据走 AST 的 Name 节点，不看源码文本：注释里提到常量名会让它恒真。
    """
    import ast
    import inspect
    import textwrap
    import qmt_pilot_db as m
    tree = ast.parse(textwrap.dedent(inspect.getsource(m.assert_db_allowed_for_reuse)))
    names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
    assert "_REGISTRY_HAS_SQL" in names, "复用路径没有走绑实例的那条登记查询"
    assert "d.oid = r.db_oid" in m._REGISTRY_HAS_SQL, "登记查询没有绑实例"
    # reset 路径**不许**引用它（不对称是有意的）
    rtree = ast.parse(textwrap.dedent(inspect.getsource(m.assert_db_allowed_for_reset)))
    rnames = {n.id for n in ast.walk(rtree) if isinstance(n, ast.Name)}
    assert "_REGISTRY_HAS_SQL" not in rnames, \
        "reset 路径引用了登记凭据 —— 维护库一丢，非空库就再也清不掉（R55-F1 锁死）"


# ── codex 4a-2a R4-F1：发放 DROP 授权之前必须证明按 seed 的锁真被持有 ──────

def test_reset_refuses_authorization_without_the_seed_lock():
    """建库 / DROP / 零对象例外三处都验了这把锁，唯独发放 DROP 授权这条路径没验。

    接线失误会让一次运行先 DROP 掉既有库、再在重建时撞 seed_lock_not_held ——
    库没了而重建没做；同 seed 的两次运行也能一起挤进这段破坏性窗口。
    """
    maint = _FakeConn(databases=["kline_pilot_probe"], seed_lock_held=False)
    target = _FakeConn(meta_rows=_full_meta_rows())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(assert_db_allowed_for_reset(
            maint, connect=_connector({"kline_pilot_probe": target}), **_RESET_KW))
    assert ei.value.code == "seed_lock_not_held"


def test_reset_checks_the_seed_lock_before_opening_the_target():
    """锁没拿到就**一条连接都别开** —— 探测连接本身就会把随后的 DROP 顶住。"""
    maint = _FakeConn(databases=["kline_pilot_probe"], seed_lock_held=False)
    target = _FakeConn(meta_rows=_full_meta_rows())
    with pytest.raises(PilotDbBoundaryError):
        asyncio.run(assert_db_allowed_for_reset(
            maint, connect=_connector({"kline_pilot_probe": target}), **_RESET_KW))
    assert target.ops == [], "锁未持有时不该对目标库发出任何查询"


def test_reuse_does_not_require_the_seed_lock():
    """**刻意的不对称**：复用不做任何破坏性动作，要求互斥锁只会让并发的只读复用互相挡。

    这条锁的规定管的是**破坏性窗口**（建库 / DROP / 零对象例外），不是读。
    """
    maint = _FakeConn(databases=["kline_pilot_probe"], seed_lock_held=False)
    target = _FakeConn(meta_rows=_full_meta_rows())
    assert asyncio.run(assert_db_allowed_for_reuse(
        maint, connect=_connector({"kline_pilot_probe": target}), **_REUSE_KW)) is None


# ── codex 4a-2a R6-F2：每个 public 入口都要自己强制集群闸 ────────────────
# 它证明的是「这台集群是给 pilot 用的一次性环境」。没有它，一次接线失误就能在
# **生产集群**上批准复用/销毁，然后往里灌几百只股 —— spec §1 列的风险 ①。

@pytest.mark.parametrize("gate,kw,label", [
    (assert_db_allowed_for_reuse, _REUSE_KW, "复用"),
    (assert_db_allowed_for_reset, _RESET_KW, "reset"),
])
@pytest.mark.parametrize("break_cluster,code,why", [
    (lambda m: setattr(m, "marker_rows", []), "no_marker", "集群没有 pilot 标记"),
    (lambda m: setattr(m, "databases", ["payments_prod", "kline_pilot_probe"]),
     "unrelated_database", "集群里有无关库"),
    (lambda m: setattr(m, "exempt_objects", [("pg_class", 9)]),
     "maintenance_db_not_empty", "维护库除专用表外非空"),
])
def test_public_gates_enforce_the_cluster_boundary_themselves(
        gate, kw, label, break_cluster, code, why):
    """三种集群闸失败都必须挡住这两个 public 入口（codex R6-F2）。

    `create_pilot_database` 早就为同一条理由把集群闸下沉进函数里（O4-R5-C2）——
    这两个新入口此前只有 seed/名字检查加目标库读取。
    """
    maint = _FakeConn(databases=["kline_pilot_probe"])
    target = _FakeConn(meta_rows=_full_meta_rows())
    break_cluster(maint)
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(gate(maint, connect=_connector({"kline_pilot_probe": target}), **kw))
    assert ei.value.code == code, f"{label} / {why}"


@pytest.mark.parametrize("gate,kw,label", [
    (assert_db_allowed_for_reuse, _REUSE_KW, "复用"),
    (assert_db_allowed_for_reset, _RESET_KW, "reset"),
])
def test_public_gates_run_the_cluster_boundary_before_touching_the_target(gate, kw, label):
    """集群闸没过 → 目标库上一条查询都不许发（探测连接本身就会顶住随后的 DROP）。"""
    maint = _FakeConn(databases=["kline_pilot_probe"], marker_rows=[])
    target = _FakeConn(meta_rows=_full_meta_rows())
    with pytest.raises(PilotClusterBoundaryError):
        asyncio.run(gate(maint, connect=_connector({"kline_pilot_probe": target}), **kw))
    assert target.ops == [], f"{label}：集群闸未过时不该对目标库发出任何查询"




# 零对象例外六条 + DROP 前紧贴复查（spec §4「空库残骸的 reset 例外」）
# ---------------------------------------------------------------------------

class _RemnantMaint(_FakeConn):
    """维护连接：额外答 `pilot_create_intent` 的读。"""

    def __init__(self, intent_rows=(), **kw):
        kw.setdefault("databases", ["kline_pilot_probe"])
        super().__init__(**kw)
        self.intent_rows = list(intent_rows)

    async def fetch(self, query, *args):
        # ⚠️ 判别式必须精确到 `FROM public.pilot_create_intent i`：
        #    闸 (iii) 的豁免 CTE 里也含 `pilot_create_intent` 这个**表名字符串**
        #    （它是【维护库专用表集合】的成员），裸 `in query` 会把那条查询也劫走，
        #    于是集群闸拿到 intent 行、在 `r["cat"]` 上炸 KeyError。
        #    4a-1 的假件已经为「子串分发很脆弱」写过警告 —— 这是它的又一次实证。
        if "FROM public.pilot_create_intent i " in query:
            self.ops.append(query)
            return list(self.intent_rows)
        return await super().fetch(query, *args)



def _intent(seed="probe", age_seconds=0, create_confirmed=True, intent_db_oid="16400"):
    """⚠️ 字段必须与 `_READ_INTENT_SQL` 的输出**逐字一致**：判据读
    seed / create_confirmed / intent_db_oid / age_seconds，fixture 少给一个
    就是「测试在测另一个东西」。"""
    return [{"seed": seed, "create_confirmed": create_confirmed,
             "intent_db_oid": intent_db_oid, "age_seconds": age_seconds}]



class _EmptyOnProbe(_FakeConn):
    """第 n 次【绝对空】探测的结果可以不同 —— 用来造「判定与 DROP 之间的空窗」。"""

    def __init__(self, non_empty_probes=(), **kw):
        super().__init__(**kw)
        self.probes = 0
        self.non_empty_probes = set(non_empty_probes)

    async def fetch(self, query, *args):
        if "SELECT cat, n FROM (" in query and "closure" not in query:
            self.ops.append(query)
            self.probes += 1
            return ([{"cat": "pg_class", "n": 3}]
                    if self.probes in self.non_empty_probes else [])
        return await super().fetch(query, *args)



def _remnant(maint, target, **over):
    kw = {"db_name": "kline_pilot_probe", "seed": "probe", **over}
    return try_empty_remnant_exception(
        maint, connect=_connector({"kline_pilot_probe": target}), **kw)



def test_remnant_exception_all_six_conditions_pass():
    """六条全成立 + 紧贴复查通过 → 返回**被授权的那个实例 oid**（不是裸 True）。

    返回 oid 而不是布尔：`DROP DATABASE` 带不了谓词，授权与 DROP 之间同名库可以被
    删掉又重建。授权不绑实例，本工具会去删一个从未被授权的替身。
    """
    maint = _RemnantMaint(intent_rows=_intent())
    assert asyncio.run(_remnant(maint, _EmptyOnProbe())) == "16400"



def test_remnant_exception_requires_exact_db_name():
    """第 2 条是**全等**而非前缀——它把爆炸半径限制在本次 seed（spec R56-F1）。"""
    maint = _RemnantMaint(intent_rows=_intent())
    assert asyncio.run(_remnant(maint, _EmptyOnProbe(),
                                db_name="kline_pilot_other")) is None



def test_remnant_exception_requires_seed_lock_really_held():
    """第 5 条：按 seed 的 advisory lock 必须**在活连接上真验**（spec O4-R5-C2）。

    ⚠️ 计划片段这里收的是一个 `holds_seed_lock: bool` 参数 —— 那正是 4a-1 已经
    删掉的可伪造断言（传 True 就能绕过）。判据必须查 `pg_locks`。
    """
    maint = _RemnantMaint(intent_rows=_intent(), seed_lock_held=False)
    assert asyncio.run(_remnant(maint, _EmptyOnProbe())) is None



def test_remnant_exception_requires_absolutely_empty():
    """第 3 条：一个装着物化视图的库不是残骸。判据用【绝对空】那组白名单式判据，
    绝不用 information_schema.tables（物化视图会逃过它，spec O1-F1）。"""
    maint = _RemnantMaint(intent_rows=_intent())
    assert asyncio.run(_remnant(maint, _EmptyOnProbe(non_empty_probes=[1]))) is None



def test_remnant_exception_requires_intent_row():
    """第 6 条：同事裸 `CREATE DATABASE` 与 `pg_restore --create` 都**没有** intent 行
    → 拒（spec P1r3-F2：这是第 6 条存在的全部理由）。"""
    maint = _RemnantMaint(intent_rows=[])
    assert asyncio.run(_remnant(maint, _EmptyOnProbe())) is None



@pytest.mark.parametrize("over,label", [
    ({"seed": "other"}, "seed 不符"),
    ({"create_confirmed": False}, "未确认的行不是授权（O4-R8-C2）"),
    ({"intent_db_oid": "99999"}, "凭据绑的是另一个实例（O4-R21-C1/R25-C1）"),
    ({"intent_db_oid": None}, "凭据的实例绑定已被判掉"),
    ({"age_seconds": INTENT_TTL_SECONDS}, "超过 INTENT_TTL（O4-F2）"),
    ({"age_seconds": INTENT_TTL_SECONDS + 1}, "远超 INTENT_TTL"),
    ({"age_seconds": -1}, "inserted_at 在**未来**（codex S2a-R2-F2）"),
    ({"age_seconds": -INTENT_TTL_SECONDS * 365}, "inserted_at 在很远的未来"),
    ({"age_seconds": -0.1}, "inserted_at 在**亚秒级**未来（codex S2a-R3-F1）"),
    ({"age_seconds": -0.4999}, "亚秒级未来的上沿（四舍五入会把它抹成 0）"),
])
def test_remnant_exception_rejects_unqualified_intent_row(over, label):
    """第 6 条的四个子判据**逐条**都要有判别力。

    · `create_confirmed=false` 的行写在 `CREATE DATABASE` **之前**，证明不了库是本次建的
      —— 拿它当授权会去 DROP **别人建的**同名空库，无 pilot_meta 归属、无令牌。
    · 绑到另一个实例的行是**陈旧凭据**：原库被删、别人用同名重建之后，它会为那个
      全新的、不是我们建的库背书。
    · 孤儿 intent 行是一条**永久有效的销毁授权**；TTL 把窗口从「永久」收窄到 24h。
    """
    maint = _RemnantMaint(intent_rows=_intent(**over))
    assert asyncio.run(_remnant(maint, _EmptyOnProbe())) is None, label



def test_remnant_exception_ttl_boundary_is_strictly_less_than():
    """恰好差 1 秒仍算新鲜 —— 边界方向钉住，免得 `<` 与 `<=` 互换而无人察觉。"""
    maint = _RemnantMaint(intent_rows=_intent(age_seconds=INTENT_TTL_SECONDS - 1))
    assert asyncio.run(_remnant(maint, _EmptyOnProbe())) == "16400"


def test_intent_ttl_is_never_measured_against_the_transaction_clock():
    """**族级**：凡是拿时钟减 `inserted_at` 判 TTL 的地方，都不许用 `now()`
    （codex S2a-R4-F2，真 PG 15 实测）。

    PostgreSQL 的 `now()` 是**事务开始时刻**，不是当前时刻。维护连接若处在一个
    长事务里（4c 的 wrapper 很可能把整段 reset 包进事务），`now()` 就冻在过去：
    实测 —— 事务开始 1.2s 后，一行**真实年龄 = TTL + 0.1s（已过期）**的凭据
    被 `now()` 量成 `TTL − 1.1s` → **判为新鲜** → 零对象例外照样放行，
    「TTL 把销毁授权窗口收窄到 24h」（spec O4-F2）再一次失效。
    `statement_timestamp()` 是**本条语句**开始的时刻，不受事务年龄影响。

    ⚠️ 判据覆盖**全族** SQL（读侧判新鲜、写侧判能不能抢占、孤儿扫描、孤儿删除），
       不是只修被点名的那一处。
    ⚠️ **写侧的 `inserted_at = now()` 刻意不改**：列的 DEFAULT 就是 `now()`（4a-1 的
       结构闸钉着它），两边必须一致；而长事务里写 `now()` 只会让行显得**更老**、
       更早过期 —— 那是保守方向。这条不对称是有意的。

    ⚠️ **族成员由模块推导，不靠手写名单**（S3-R1 的根因层修复）：手写名单在新增
       第三、第四条 SQL 时不会自动收录它们 —— 守卫看起来在工作、对新成员却零覆盖。
       `_EXPECTED` 只作**双向**核对：模块里冒出新成员而名单没跟上 → 红；
       名单写了模块里没有的名字（改名/删除）→ 也红。
    """
    import re
    import qmt_pilot_db as m
    pat = re.compile(r"EXTRACT\(EPOCH FROM \(\s*([A-Za-z_]+\(\))\s*-")
    # 「量 inserted_at 年龄」的族 = 模块级 *_SQL 常量里，既提到 inserted_at
    #   又含一处「时钟() −」的那些。`_MAINTENANCE_SHAPE_SQL` 只提列名、不量年龄，
    #   故不在族里（已实测确认它被正确排除）。
    derived = {n for n in dir(m)
               if n.endswith("_SQL") and isinstance(getattr(m, n), str)
               and "inserted_at" in getattr(m, n) and pat.search(getattr(m, n))}
    _EXPECTED = {"_READ_INTENT_SQL", "_INSERT_INTENT_SQL",
                 "_LIST_ALL_INTENT_SQL", "_DELETE_ORPHAN_INTENT_SQL"}
    assert derived == _EXPECTED, (
        f"「量 inserted_at 年龄」的 SQL 族变了：模块里多出 {sorted(derived - _EXPECTED)}，"
        f"名单里多出 {sorted(_EXPECTED - derived)} —— 新成员必须显式进这份名单，"
        f"否则它的时钟源无人把关")
    for name in sorted(derived):
        sql = getattr(m, name)
        clocks = pat.findall(sql)
        # 反向自检：扫不到任何时钟表达式 = 匹配式过时了，下面那条会恒真
        assert clocks, f"{name} 里一处「时钟 − inserted_at」都没扫到 —— 这颗钉子是空的"
        for clock in clocks:
            assert clock == "statement_timestamp()", (
                f"{name} 用 {clock} 判 TTL —— `now()` 是**事务开始时刻**，"
                f"长事务里一行已过期的销毁凭据会被判成新鲜")


def test_remnant_exception_age_predicate_never_rounds_away_the_sign():
    """机械守卫：判据两侧都不许取整（codex S2a-R3-F1）。

    ⚠️ 这条洞**同时**藏在两层，只堵一层没用：
      · SQL 的 `::bigint` 是四舍五入（真 PG 15 实测 `(-0.1)::bigint = 0`）；
      · Python 的 `int(-0.1)` 也是 0。
    ⚠️ 判据走 AST 的调用节点，不看源码文本：注释里提到 `int(` 会让文本判据恒真。
    """
    import inspect
    import textwrap
    import qmt_pilot_db as m
    tree = ast.parse(textwrap.dedent(inspect.getsource(m._has_qualified_intent_row)))
    calls = [n.func.id for n in ast.walk(tree)
             if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)]
    assert calls, "扫描器一个调用都没解析到 —— 下面那条会恒真"
    for rounding in ("int", "round"):
        assert rounding not in calls, \
            f"年龄在 Python 里被 {rounding}() 取整了 —— 亚秒级未来时间戳的符号会被抹掉"


def test_remnant_exception_accepts_a_row_inserted_this_instant():
    """**正向钉**：`age_seconds == 0`（刚写下的那一行）必须仍然合格。

    ⚠️ 这一条守的是 codex S2a-R2-F2 那条修复的**下界方向**：判据从
       `age < TTL` 收紧成 `0 <= age < TTL` 之后，写成 `0 < age` 会把
       **同一次运行刚写下的凭据**判掉 —— 空残骸从此清不掉（R55-F1 锁死换个来路）。
       上界由 `…ttl_boundary_is_strictly_less_than` 守，两端各一颗钉子。
    """
    maint = _RemnantMaint(intent_rows=_intent(age_seconds=0))
    assert asyncio.run(_remnant(maint, _EmptyOnProbe())) == "16400"



def test_remnant_exception_does_not_delete_stale_row():
    """判定时**不删**超期行——普通运行不替别的 seed 做决定（spec O4-F2 修正②）。
    清理只在 --init-cluster-marker 里做，且要逐行取 seed 锁。"""
    maint = _RemnantMaint(intent_rows=_intent(age_seconds=INTENT_TTL_SECONDS + 1))
    asyncio.run(_remnant(maint, _EmptyOnProbe()))
    assert not any("DELETE" in q.upper() for q in maint.executed)



def test_remnant_exception_empty_probe_bottoms_out_at_the_whitelist_predicate():
    """第 3 条与紧贴复查都必须落到**裸【绝对空】**（`_is_absolutely_empty`）上。

    ⚠️ 判据要**跟着调用链走**，不能只看 `try_empty_remnant_exception` 一层：
       探测被提成 `_probe_absolutely_empty` 之后，只看外层的写法会在一个空集合上
       恒真（我第一版就是那样，当场变红）。
    ⚠️ 反向断言：零对象例外这条链上不许出现 `information_schema` 或 relkind 枚举 ——
       真 PG 实测，一个只含物化视图（relkind='m'）的库会从这两种写法下逃掉，
       于是**不过闸 0−/0/0b、不要令牌、无提示，直接 DROP**（spec O1-F1）。
    """
    import ast
    import inspect
    import textwrap
    import qmt_pilot_db as m
    chain = [m.try_empty_remnant_exception, m._probe_absolutely_empty]
    names, srcs = set(), []
    for fn in chain:
        src = textwrap.dedent(inspect.getsource(fn))
        srcs.append(src)
        names |= {n.id for n in ast.walk(ast.parse(src)) if isinstance(n, ast.Name)}
    assert "_probe_absolutely_empty" in names, "零对象例外没有走探测函数"
    assert "_is_absolutely_empty" in names, "探测链没有落到【绝对空】的唯一实现上"
    for bad in ("information_schema", "relkind IN", "relkind in"):
        assert not any(bad in s for s in srcs), f"零对象例外链上出现 {bad!r}"



class _EmptyProbeReadFails(_EmptyOnProbe):
    """连得进去，但【绝对空】那条目录读**抛异常**（并发 DROP / 权限变更 / 目录查询失败）。"""

    def __init__(self, boom=None, **kw):
        super().__init__(**kw)
        self.boom = boom or RuntimeError(
            "terminating connection due to administrator command")

    async def fetch(self, query, *args):
        if "SELECT cat, n FROM (" in query and "closure" not in query:
            raise self.boom
        return await super().fetch(query, *args)


class _EmptyProbeReadAndCloseFail(_EmptyProbeReadFails):
    async def close(self):
        raise RuntimeError("connection reset by peer")


def test_remnant_probe_read_failure_is_a_boundary_error_not_a_raw_exception():
    """【绝对空】读失败 → `target_db_unreadable`，不得裸逃（codex S2a-R2-F2）。

    ⚠️ 这是本模块**同一族判据的最后一处漏网**：复用路径的活体判据（R2-F2）、
       闸 2 的结构查询、`read_pilot_meta` 三处早就把读失败转成
       `target_db_unreadable` 了，唯独零对象例外的探测没转。
       裸异常会被 4c 兜成 `FAIL_INFRASTRUCTURE`，而 spec §9-1w 明令禁止
       把一次成功的 fail-closed 守卫记成环境故障 —— 恢复动作整个走错
       （去查基础设施，而真相是「这个库现在读不出来，拒绝销毁」）。
    """
    maint = _RemnantMaint(intent_rows=_intent())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_remnant(maint, _EmptyProbeReadFails()))
    assert ei.value.code == "target_db_unreadable"


def test_remnant_probe_read_failure_is_not_masked_by_a_close_failure():
    """**刻意的不对称，钉住它**：读失败的结论不得被「关不掉连接」顶掉。

    与 `test_close_failure_never_masks_the_gate_verdict`（O4-W2r1 M-2）同一条规矩 ——
    拿到 `target_db_in_use` 的话，操作者会去查「谁连着这个库」，
    而真相是「这条探测根本读不出来」。两种情形都是拒绝（fail-closed），
    差别只在**给出的下一步动作对不对**。
    ⚠️ codex S2a-R2-F2 的第二半建议「读失败时也要跑 `_assert_target_released`」——
       那会让 close 失败顶掉读失败的结论，正是上面那条既有钉子禁止的形态，故不采纳。
    """
    maint = _RemnantMaint(intent_rows=_intent())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_remnant(maint, _EmptyProbeReadAndCloseFail()))
    assert ei.value.code == "target_db_unreadable", "读失败的结论被 close 失败顶掉了"


def test_every_target_side_read_failure_maps_to_target_db_unreadable():
    """**族级**：三条会连进目标库的路径，读失败一律归一到 `target_db_unreadable`。

    ⚠️ 本仓记录在案的形态是「只修被点名的那一处」—— 这一条按**判据本身**覆盖全族，
       新增一条会连目标库的路径而忘了归一时当场变红。
    """
    boom = RuntimeError("terminating connection due to administrator command")

    class _MetaReadBoom(_FakeConn):
        async def fetchval(self, query, *args):
            if "to_regclass('public.pilot_meta') IS NOT NULL" in query:
                raise boom
            return await super().fetchval(query, *args)

    cases = [
        ("复用（闸 0− 读 pilot_meta）",
         lambda: _reuse(_FakeConn(databases=["kline_pilot_probe"]), _MetaReadBoom())),
        ("--reset 闸 0−（读 pilot_meta）",
         lambda: _reset(_FakeConn(databases=["kline_pilot_probe"]), _MetaReadBoom())),
        ("零对象例外的【绝对空】探测",
         lambda: _remnant(_RemnantMaint(intent_rows=_intent()), _EmptyProbeReadFails())),
    ]
    for label, run in cases:
        with pytest.raises(PilotDbBoundaryError) as ei:
            asyncio.run(run())
        assert ei.value.code == "target_db_unreadable", label


def test_remnant_exception_closes_every_probe_connection():
    """两次探测都是短连接：留一条活着就会把紧接着的 DROP 顶住（spec O1-F2 规定 1）。"""
    maint = _RemnantMaint(intent_rows=_intent())
    target = _EmptyOnProbe()
    asyncio.run(_remnant(maint, target))
    assert target.closed is True



def test_remnant_exception_rejects_when_replacement_also_claims_the_new_oid():
    """两次探测之间同名库被删掉又重建，**且替身自称就是新实例** → 仍须 fail-closed。

    ⚠️ 这一档与下面那条不是重复：下面那条被 `adopt_connection` 挡下（替身还自称旧 oid），
       走的是**连接接管**那条路径。真实的「删掉又重建」里，`connect()` 拿到的是新实例、
       维护库读到的也是新 oid —— **adopt 会通过**，此时唯一挡得住的是
       「复查拿到的 oid 必须还是判定时那一个」。
       去掉那半个判据时，上一条测试**照样是绿的**（实测），本条才会变红。
    """
    target = _EmptyOnProbe()

    class _RebuiltAfterFirstProbe(_RemnantMaint):
        def __init__(self, **kw):
            super().__init__(**kw)
            self.oid_reads = 0

        async def fetchval(self, query, *args):
            if "d.oid::text FROM pg_database d WHERE d.datname::text = $1" in query:
                self.oid_reads += 1
                self.ops.append(query)
                if self.oid_reads > 1:
                    target.current_db_oid = "99999"     # 替身自称新实例 → adopt 过得了
                    return "99999"
                return "16400"
            return await super().fetchval(query, *args)

    maint = _RebuiltAfterFirstProbe(intent_rows=_intent())
    assert asyncio.run(_remnant(maint, target)) is None
    assert maint.oid_reads == 2, "必须真的探测了两次"



def test_remnant_exception_read_intent_freshness_uses_the_database_clock():
    """机械守卫：intent 行的**年龄只能由库自己的时钟算**（spec O4-R23-C1）。

    ⚠️ host 假件直接喂 `age_seconds`，故 SQL 文本本身在 L1 是**零覆盖**的
       —— 把 `EXTRACT(EPOCH FROM (now() - i.inserted_at))` 换成常量，
       上面那一组 TTL 用例**全都照样是绿的**（实测）。所以这里改钉 SQL 文本：
       `created_at` 是调用方传进来的字符串，数据库既不生成也不校验它，
       很远的未来值让这行永远「新鲜」、永远抢不走 —— 而它是一张 DROP 授权。
    """
    import qmt_pilot_db as m
    sql = m._READ_INTENT_SQL
    assert "statement_timestamp() - i.inserted_at" in sql, "新鲜度没有用库时钟算"
    # ⚠️ 时钟源必须是 `statement_timestamp()` 而不是 `now()`（事务开始时刻）——
    #    由 `test_intent_ttl_is_never_measured_against_the_transaction_clock` 按族覆盖。
    assert "created_at" not in sql, "新鲜度不得取调用方传进来的 created_at"
    assert "public.pilot_create_intent" in sql, "表引用必须 public. 限定（O4-R4-C1）"
    assert "i.create_confirmed" in sql and "i.db_oid" in sql, \
        "第 6 条的确认位与实例绑定必须由这条 SQL 取出来"
    # ⚠️ **年龄不许在 SQL 里取整**（codex S2a-R3-F1，真 PG 15 实测）：
    #    `::bigint` 是**四舍五入**不是截断 —— `(-0.1)::bigint = 0`。
    #    于是一行「比 now() 早不到半秒」的**未来** inserted_at 会被算成 age 0，
    #    过得了下界检查，而下界正是 R2-F2 那条修复的全部内容。
    #    Python 那侧的 `int()` 是第二层同样的抹除（`int(-0.1) == 0`），两层都要去掉。
    assert "::bigint" not in sql, \
        "年龄在 SQL 里被取整了 —— 亚秒级的未来时间戳会被抹成 age 0（符号丢失）"



def test_remnant_exception_rejects_when_adopt_catches_a_stale_instance():
    """两次探测之间实例被换、而替身仍自称旧 oid → 由 `adopt_connection` 挡下。"""
    class _SwapAfterFirst(_RemnantMaint):
        def __init__(self, **kw):
            super().__init__(**kw)
            self.oid_reads = 0

        async def fetchval(self, query, *args):
            if "d.oid::text FROM pg_database d WHERE d.datname::text = $1" in query:
                self.oid_reads += 1
                self.ops.append(query)
                return "16400" if self.oid_reads == 1 else "99999"
            return await super().fetchval(query, *args)

    maint = _SwapAfterFirst(intent_rows=_intent())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_remnant(maint, _EmptyOnProbe()))
    assert ei.value.code == "connection_wrong_instance"



def test_module_never_uses_force_or_terminate_backend():
    """spec §4 规定 2 明令禁止 —— 机械守卫，不靠人工 grep 清单。

    `DROP DATABASE … WITH (FORCE)` 与 `pg_terminate_backend` 会**无差别 terminate
    别人的会话**，正是本文件全套护栏要避免的行为。

    ⚠️ 判据必须**剥掉注释与 docstring** 再看：本模块的 docstring 里就写着
       「明令禁止 pg_terminate_backend」—— 只按行首 `#` 过滤的写法会被自己的说明文字
       触发（我第一版就是那样，当场变红）。`ast.unparse` 顺带把注释也去掉了。
    """
    import ast
    import pathlib
    src = (pathlib.Path(__file__).resolve().parents[1] / "qmt_pilot_db.py").read_text()
    tree = ast.parse(src)
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if not isinstance(body, list) or not body:
            continue
        head = body[0]
        if (isinstance(head, ast.Expr) and isinstance(head.value, ast.Constant)
                and isinstance(head.value.value, str)):
            node.body = body[1:] or [ast.Pass()]
    code = ast.unparse(tree)
    assert "pg_terminate_backend" not in code, "模块里出现被明令禁止的 pg_terminate_backend"
    # ⚠️ **不能裸查 `FORCE`**：`_PILOT_TABLE_DEPENDENTS_SQL` 的 SQL 注释里正当地写着
    #    `ENABLE/FORCE ROW LEVEL SECURITY`（RLS 判据的说明）。判据收窄到「DROP DATABASE
    #    这条语句里出现 FORCE」—— 那才是被禁的东西。
    import re
    hit = re.search(r"DROP\s+DATABASE[^;\n]*FORCE", code, re.IGNORECASE)
    assert hit is None, f"DROP DATABASE 带上了强制模式：{hit.group(0) if hit else ''!r}"
    # 反向断言：剥完之后模块正文还在（剥过头会让上面两条恒真）
    assert "DROP DATABASE" in code and len(code) > 20_000, \
        "剥离 docstring 把正文也剥掉了 —— 上面的禁用判据会恒真"



# ── 零对象例外与闸 0−/0/0b 的分工（R56-F1 / R55-F1）────────────────────────
#
# ⚠️ **这里曾经有一个 `authorize_reset` 单一入口，它连同整套「可传递的授权凭据」
#    在 2026-08-12 被删掉了。**为什么值得在测试文件里记一笔：那套机器是被 codex
#    连提**六次**（R4-F2 → R6-F1 → R7-F1 → R14-F2 → S2-R2-F1 → S2a-R1-F1）
#    的同一个洞逼出来的五轮加固 —— 改私有 → 加构造哨兵 → 使用点查类型 → 改查登记表
#    → 加仓库级 AST 守卫，**每一轮都被下一轮拆穿**。
#    根因不是加固不够狠，而是「授权」与「销毁」之间那道**缝**本身：
#    绑定/令牌那一条判据推导不出来，只能靠「授权时记下来的东西」，
#    而那个东西正是伪造者控制的入参。**加固凭据永远堵不上它。**
#    修法是让缝消失 —— 判定与 DROP 收进 S2b 的 `reset_pilot_database` 一个函数体，
#    没有可传递的对象、没有登记表、没有铸造函数。
#    本片（S2a）因此只剩**判定 helper**，连一张可用的凭据都不存在。

def test_the_empty_remnant_escape_hatch_is_the_only_thing_that_can_clear_a_remnant():
    """同一个空残骸：闸 0−/0/0b **拒**，零对象例外**放行** —— 两半各自可分辨。

    崩在 `CREATE DATABASE` 与写 `pilot_meta` 之间的残骸根本没有 pilot_meta，
    直接走闸 0− 会撞 `not_owned`「拒绝 DROP、库原样保留」→ 残骸永远清不掉
    （R56-F1 花一整轮修的洞，也正是 R55-F1 那句「能被自己 --reset 清掉重来」
    会变成空话的地方）。

    ⚠️ 这一档取代了原来那条「`authorize_reset` 能清掉空残骸」——
       塌缩之后没有单一入口了，**两步的次序**由 S2b 的 `reset_pilot_database` 焊死；
       本片能证明也只能证明的是：**这两步在同一份 fixture 上给出相反的判定**。
       少了这条对照，「例外返回 oid」看起来仍像在工作，却证明不了它有存在的必要。
    """
    remnant_kw = dict(meta_table_present=False)      # 空库：连 pilot_meta 都没有
    # 例外这一半：放行，并交回被授权的那个实例 oid
    maint = _RemnantMaint(intent_rows=_intent())
    assert asyncio.run(_remnant(maint, _EmptyOnProbe(**remnant_kw))) == "16400"
    # 闸这一半：同一份残骸 —— 必须拒，且拒的理由是「不是本工具建的」
    maint2 = _FakeConn(databases=["kline_pilot_probe"])
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset(maint2, _FakeConn(**remnant_kw)))
    assert ei.value.code == "not_owned"



class _CloseFailsOnNth(_EmptyOnProbe):
    """只在**第 n 次** close 时失败 —— 让两处释放校验各自可分辨。"""

    def __init__(self, fail_on=1, **kw):
        super().__init__(**kw)
        self.closes = 0
        self.fail_on = fail_on

    async def close(self):
        self.closes += 1
        if self.closes == self.fail_on:
            raise RuntimeError("connection reset by peer")
        await super().close()



@pytest.mark.parametrize("fail_on,label", [
    (1, "判定那次探测关不掉"),
    (2, "DROP 前紧贴复查那次关不掉"),
])
def test_remnant_exception_refuses_authorization_when_it_cannot_release_a_probe(
        fail_on, label):
    """零对象例外在交出销毁授权前，**两次探测各自**都要证明会话已放掉（codex R2-F1 同族）。

    ⚠️ 必须按「第几次 close 失败」参数化：让**两次都失败**的写法里，
       删掉其中任意一处校验另一处仍会拦住 —— 两条变异都跑出绿色（实测），
       即这两处校验各自的覆盖是零。这与 4a-1 为 `pin_search_path` 记下的
       「钉桩在多处冗余 → 黑盒断言分辨不出是哪一处」是同一个坑。
    """
    maint = _RemnantMaint(intent_rows=_intent())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_remnant(maint, _CloseFailsOnNth(fail_on=fail_on)))
    assert ei.value.code == "target_db_in_use", label



# ── codex 4a-2b R1：集群闸机器强制 + 调用方 SQL 跑完必须重钉 search_path ──────

def test_remnant_exception_enforces_the_cluster_gate_itself():
    """零对象例外的第 4 条（集群闸已全过）**必须机器强制，不能只写在 docstring 里**。

    这条路径的下一步就是不可逆的 `DROP DATABASE`；接线失误会让标记闸、无关库闸、
    维护库空闸全部被跳过。`create_pilot_database` 与 `assert_db_allowed_for_reset`
    早就为同一条理由把它下沉进函数里（O4-R5-C2 / 4a-2a R6-F2）。

    ⚠️ **这一条原本挂在 `authorize_reset` 上**（4a-2b R1-F1）。塌缩把那个入口删了，
       若不把集群闸一并下沉进本函数，一条 public 判定入口就会退回到
       「第 4 条只写在 docstring 里、由调用方保证」—— 那正是 R1-F1 修掉的形态。
       重复调用的代价只是几条只读查询。
    """
    maint = _RemnantMaint(intent_rows=_intent(), marker_rows=[])   # 集群没有合法标记
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_remnant(maint, _EmptyOnProbe(meta_table_present=False)))
    assert ei.value.code == "no_marker"



def test_remnant_exception_runs_the_cluster_gate_before_anything_touches_the_target():
    """集群闸没过 → 目标库上一条查询都不许发（探测连接本身就会顶住随后的 DROP）。"""
    maint = _RemnantMaint(intent_rows=_intent(), marker_rows=[])
    target = _EmptyOnProbe(meta_table_present=False)
    with pytest.raises(PilotClusterBoundaryError):
        asyncio.run(_remnant(maint, target))
    assert target.ops == [], "集群闸未过时不该对目标库发出任何查询"



@pytest.mark.parametrize("probes,fail_on,label", [
    ([1], 1, "第一次探测判非空、且关不掉"),
    ([2], 2, "复查判非空、且关不掉"),
])
def test_remnant_exception_checks_release_even_when_it_falls_through(
        probes, fail_on, label):
    """**落空路径也要证明会话已释放**（codex 4a-2b R2-F2）。

    判空为「非空」时本函数返回 None，调用方随后落到闸 0−/0/0b ——
    而本模块自己那条没关掉的会话仍活着，最后的 DROP 会以
    「target_db_in_use，占用者是别人」失败，而那个「别人」就是我们自己。
    """
    maint = _RemnantMaint(intent_rows=_intent())
    target = _CloseFailsOnNth(fail_on=fail_on, non_empty_probes=probes)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_remnant(maint, target))
    assert ei.value.code == "target_db_in_use", label



def test_remnant_exception_pins_search_path_before_proving_the_seed_lock():
    """见 `_SEED_LOCK_PIN_WHY`（codex 4a-2a R5-F1 同族）。"""
    maint = _RemnantMaint(intent_rows=_intent())
    asyncio.run(_remnant(maint, _EmptyOnProbe()))
    _assert_pinned_before_lock_proof(maint)



# ── 塌缩守卫：**可传递的授权凭据**不许再出现（2026-08-12）─────────────────
#
# 被删掉的七个名字。⚠️ 这不是一张「私有名单」——**它们一个都不该存在**：
#   · `ResetAuthorization` / `_RESET_CAPABILITY` / `_MINTED_AUTHORIZATIONS` /
#     `_MintedFacts` / `_mint_authorization`：整套凭据机器（铸造 + 登记 + 哨兵）；
#   · `authorize_reset`：「集群闸 + 走哪条路的决策 + 铸造」的封装 —— 留着它等于
#     把缝留下一半（调用方仍可「先问一次走哪条路，再自己去 DROP」）；
#   · `ResetGateOutcome`：把「授权那一刻的身份」带出函数的载体。数据虽不是能力，
#     但只要 DROP 那边**信**它，缝就还在；而只要 DROP 那边不信（自己重新推导），
#     它就没有存在意义。
_COLLAPSED_AUTHORIZATION_SYMBOLS = frozenset({
    "ResetAuthorization", "_RESET_CAPABILITY", "_MINTED_AUTHORIZATIONS",
    "_MintedFacts", "_mint_authorization", "ResetGateOutcome", "authorize_reset",
})


def _collapsed_symbol_hits(source: str, label: str) -> list[str]:
    """在一份源码里找**代码层面**引用了被塌缩符号的地方。

    ⚠️ 走 AST 不走文本：本文件与模块里都有大段解释「为什么删掉 `ResetAuthorization`」
       的注释与 docstring，文本判据会被这些**承重的历史叙述**打红，
       而绕开它的办法是删注释 —— 那正是本仓明令禁止的判据形态。
       `ast` 天然看不见注释；docstring 是 `Constant` 不是 `Name`，也不会被算进来。
    """
    tree = ast.parse(source)
    hits = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            hits += [f"{label}: from {node.module} import {a.name}"
                     for a in node.names if a.name in _COLLAPSED_AUTHORIZATION_SYMBOLS]
        elif isinstance(node, ast.Attribute):
            if node.attr in _COLLAPSED_AUTHORIZATION_SYMBOLS:
                hits.append(f"{label}: …{node.attr}")
        elif isinstance(node, ast.Name):
            if node.id in _COLLAPSED_AUTHORIZATION_SYMBOLS:
                hits.append(f"{label}: {node.id}")
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.name in _COLLAPSED_AUTHORIZATION_SYMBOLS:
                hits.append(f"{label}: def/class {node.name}")
    return sorted(hits)


def test_collapsed_symbol_scanner_actually_discriminates():
    """扫描器的**正向**自检：七个名字 × 四种写法，一种都不许漏。

    ⚠️ 没有这一条，下面那两颗钉子就是「对一个恒空集合断言为空」——
       本仓记录在案的「机械检查器被它该抓的损坏禁用了自身解析器 → 静默全绿」。
    """
    for name in sorted(_COLLAPSED_AUTHORIZATION_SYMBOLS):
        for form, src in (
            ("import", f"from qmt_pilot_db import {name}\n"),
            ("name", f"x = {name}\n"),
            ("attribute", f"import qmt_pilot_db as m\ny = m.{name}\n"),
            ("definition", f"def {name}():\n    pass\n"),
        ):
            assert _collapsed_symbol_hits(src, "probe"), \
                f"扫描器漏掉了 {name} 的 {form} 形态"
    # 反向：正常代码不许被误报（否则这颗钉子只会逼人删注释）
    assert _collapsed_symbol_hits(
        "# ResetAuthorization 是被删掉的\n"
        "def f():\n"
        "    '''authorize_reset 曾经在这里铸造 _MINTED_AUTHORIZATIONS'''\n"
        "    return try_empty_remnant_exception\n", "probe") == [], \
        "扫描器把注释/docstring 里的历史叙述当成了引用"


def test_the_transferable_reset_authorization_machinery_is_gone_from_the_module():
    """核心不变量：`qmt_pilot_db` 里**不存在**可传递的销毁授权。

    同一个洞被 codex 提了**六次**，五次加固全被下一轮拆穿 ——
    因为「绑定/令牌那一条」推导不出来，只能靠「授权时记下来的东西」，
    而那个东西正是伪造者控制的入参。**加固凭据永远堵不上它。**
    这颗钉子守的不是某一次加固，而是「缝不许再被造出来」本身。
    """
    import qmt_pilot_db as m
    src = pathlib.Path(m.__file__).read_text(encoding="utf-8")
    hits = _collapsed_symbol_hits(src, "qmt_pilot_db.py")
    assert not hits, f"可传递的授权凭据又被造回来了：{hits}"
    # ⚠️ **自检**：同一个扫描器必须在同一份源码上**看得见还活着的判定函数** ——
    #    否则「一个都没扫到」与「解析器坏了」在输出上完全一样。
    alive = frozenset({"try_empty_remnant_exception", "assert_db_allowed_for_reset"})
    defined = {n.name for n in ast.walk(ast.parse(src))
               if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))}
    assert alive <= defined, \
        f"扫描器在这份源码上连判定函数都找不到，上面那条是恒真的：{sorted(defined)[:5]}"


def test_no_production_file_reintroduces_a_transferable_reset_authorization():
    """仓库级：`backend/` 下**任何**生产文件都不许把那套机器造回来。

    ⚠️ **先把这颗钉子能做到什么说清楚**：**Python 进程内不存在能力边界**，
       所以它防不住蓄意绕过，也不该被写成防得住。它防的是 spec §1 风险① 那一类
       **接线失误**，以及「下一轮有人觉得『再加一道锁就行了』又把缝造回来」——
       两者都一定表现为**仓库里多出一个符号**，那是机械抓得住的。
    """
    import qmt_pilot_db as m
    backend = pathlib.Path(m.__file__).resolve().parent
    scanned, offenders = [], []
    for path in sorted(backend.rglob("*.py")):
        rel = path.relative_to(backend)
        if rel.parts[0] == "tests":
            continue                       # 测试当然要提这些名字（本文件就在提）
        scanned.append(str(rel))
        offenders += _collapsed_symbol_hits(
            path.read_text(encoding="utf-8"), str(rel))
    # ⚠️ **自检 A**：扫描器必须真的扫到文件，否则下面那条是恒真的。
    assert scanned, "扫描器一个生产文件都没找到 —— 它已经失去判别力"
    # ⚠️ **自检 B**：`scripts/` 是最可能图省事直接引内部符号的地方，必须在扫描面内。
    assert any("scripts/" in s for s in scanned), \
        f"没扫到 scripts/ —— 验收脚本正是最可能图省事的地方：{scanned}"
    assert any(s == "qmt_pilot_db.py" for s in scanned), \
        "没扫到 qmt_pilot_db.py 本体 —— 定义处才是最要紧的那一个"
    assert not offenders, f"这些生产文件把可传递的授权凭据造回来了：{offenders}"


# ═══ S2b′：`reset_pilot_database` —— 授权与销毁**一体**的唯一破坏性入口 ═══════
#
# ⚠️ **本片与 S2a 的关系，先说清楚**：S2a 明写接受了一条残留 ——
#    spec §4 那条有向序列（集群闸 → 零对象例外 → 否则闸 0−/0/0b）在那一片
#    **没有任何东西机器强制**，因为焊住它的那个函数体就是本片要落的这一个。
#    本片把它还回来（`test_reset_welds_the_spec_order_into_one_function_body`）。
#
# ⚠️ **塌缩之后判定与 DROP 之间没有可传递的东西**：来路是函数内的**局部变量**，
#    伪造不了；绑定/令牌那一条在封锁下拿**本次调用的入参**重跑，不再有「记下来的事实」。
#    因此 S2 那一整族「伪造 / 鸭子类型 / 篡改属性 / 子类 / 一次性凭据」的用例
#    在本片**不存在对应的失败模式**，整族删除 —— 这正是塌缩买到的东西。

# 假连接持有的那条目标库会话的 pid（`pg_backend_pid()`）。
_HELD_PID = 90001


class _ResetMaint(_RemnantMaint):
    """维护连接：在 `_RemnantMaint`（答 intent 行）之上再答 `pg_stat_activity`。"""

    def __init__(self, target_sessions=(), late_sessions=(), drop_error=None,
                 vanish_on_drop=False, seal_error=None, restore_error=None,
                 replace_on_drop=None, **kw):
        kw.setdefault("intent_rows", _intent())
        super().__init__(**kw)
        # 「服务端执行了、客户端没收到回包」这一族（codex 4a-2/S2 R1-F1 / R1-F2）。
        self.vanish_on_drop = vanish_on_drop
        self.seal_error = seal_error
        # 拒绝路径上「把封锁还回去」那条 ALTER 失败（codex 合并评审 R2-F1）。
        self.restore_error = restore_error
        # 「DROP 生效了，但这个**名字**随即被另一个实例占住」（codex 4a-2/S2 R6-F1）。
        # 与 vanish_on_drop 是两回事：那个是名字整个没了。
        self.replace_on_drop = replace_on_drop
        self.target_sessions = list(target_sessions)
        # 「在最前面那次占用者检查之后、封锁之前才连进来」的会话 ——
        # 只有**封锁之后**那次复查看得见它。没有这个区分的话，
        # 「封锁后复查」这条闸的用例会被最前面那条闸先接走，永远测不到自己。
        self.late_sessions = list(late_sessions)
        self.session_queries: list[tuple] = []
        self.drop_error = drop_error

    async def fetch(self, query, *args):
        if "pg_stat_activity" in query:
            self.ops.append(query)
            self.session_queries.append((query, args))
            rows = list(self.target_sessions)
            # ⚠️ 建模真实时序：**我们自己持住的那条会话只在连上之后才存在**。
            #    带排除子句的那条查询是在「已经连上目标库」之后才发的，
            #    所以只有它看得见 `_HELD_PID`；最前面那次占用者检查发生在连上之前。
            if "a.pid <> $2" in query and len(args) > 1:
                rows = rows + self.late_sessions + [
                    _session(pid=_HELD_PID, usename="qmt_pilot",
                             application_name="qmt_pilot_probe")]
                # ⚠️ 排除要**真的按 pid 过滤**（codex 4a-2 R12-F1）：假件若不建模它，
                #    「排除自己」与「没排除」在测试里完全一样，两条用例都在恒真上空转。
                rows = [r for r in rows if r["pid"] != args[1]]
            return rows
        return await super().fetch(query, *args)

    async def execute(self, query, *args):
        if query.upper().startswith("DROP DATABASE") and self.drop_error is not None:
            self.executed.append(query)
            # 建模「服务端做了、客户端不知道」：`vanish_on_drop` 为真时同名库真的没了，
            # 但 execute 仍然抛（回包丢 / 连接断）。
            if self.vanish_on_drop:
                self.db_is_gone = True
                self.databases = [d for d in self.databases if d != "kline_pilot_probe"]
            if self.replace_on_drop is not None:
                self.live_db_oid = self.replace_on_drop
            raise self.drop_error
        if ("ALTER DATABASE" in query.upper() and "LIMIT 0" not in query.upper()
                and self.restore_error is not None):
            self.executed.append(query)
            raise self.restore_error
        if "CONNECTION LIMIT 0" in query.upper() and self.seal_error is not None:
            # 同族：ALTER 已经生效，只是 execute 抛了（codex 4a-2/S2 R1-F1）。
            self.executed.append(query)
            raise self.seal_error
        return await super().execute(query, *args)


def _session(pid=4242, usename="someone", application_name="psql"):
    return {"pid": pid, "usename": usename, "application_name": application_name}


class _PgError(Exception):
    def __init__(self, sqlstate, msg="boom"):
        super().__init__(msg)
        self.sqlstate = sqlstate


def _connlimit_ops(maint):
    """维护连接上发出的 `ALTER DATABASE … CONNECTION LIMIT` 语句，按顺序。"""
    return [q for q in maint.executed
            if "CONNECTION LIMIT" in q.upper() and "ALTER DATABASE" in q.upper()]


def _drops(conn):
    return [q for q in conn.executed if q.upper().startswith("DROP DATABASE")]


def _seq_connector(name, conns):
    """把**第 n 次**连向同一个库的请求接到第 n 条假连接上。

    ⚠️ 塌缩之后「授权」与「封锁下复验」在同一次调用里，两次都真的连目标库 ——
       想造出「窗口里 pilot_meta 被改掉」这种状态，唯一诚实的办法就是让
       **不同次的连接读到不同的库**（真 PG 档 ㉟ 用的是同一招）。
       用一个可变的 `_FakeConn` 在读之间改 `meta_rows` 也能造，但那会把
       「第几次读」这件事藏进夹具的隐式状态里，出错时看不出注入点在哪。
    """
    handed: list = []

    async def _connect(dbname):
        if dbname != name:
            raise ConnectionError(f"cannot connect to {dbname}")
        conn = conns[min(len(handed), len(conns) - 1)]
        handed.append(conn)
        if getattr(conn, "current_database", None) is None:
            conn.current_database = dbname
        return conn

    _connect.handed = handed
    return _connect


_RESET_DB_KW = dict(db_name="kline_pilot_probe", seed="probe",
                    export_log_sha256="a" * 64, output_dir="/x/y",
                    reset_foreign_token=None)


def _reset_db(maint, *, target=None, targets=None, via_remnant=False, **over):
    """跑一次完整的 `reset_pilot_database`。

    ⚠️ 默认目标库随**来路**变：零对象例外那条要【绝对空】（`_EmptyOnProbe`），
       正常路要一份九键齐全、seed/绑定都相符的 `pilot_meta`。
    ⚠️ `targets`（列表）用于「窗口里目标库被改掉」那一族 —— 见 `_seq_connector`。
    """
    kw = {**_RESET_DB_KW, **over}
    if targets is None:
        if target is None:
            target = (_EmptyOnProbe() if via_remnant
                      else _EmptyOnProbe(non_empty_probes=[1],
                                         meta_rows=_full_meta_rows()))
        targets = [target]
    for t in targets:
        t._maint_executed = maint.executed          # 次序判据用（见 _FakeConn.close）
    return reset_pilot_database(
        maint, connect=_seq_connector(kw["db_name"], targets), **kw)


# ── 基本形状：一条朴素的 DROP，且它是**被授权的那个实例** ─────────────────

def test_reset_executes_a_plain_quoted_drop_and_returns_the_destroyed_oid():
    """正常路径：恰好一条 `DROP DATABASE "<名字>"`，标识符走 quote_ident，返回被销毁的 oid。"""
    maint = _ResetMaint()
    assert asyncio.run(_reset_db(maint)) == "16400"
    assert _drops(maint) == ['DROP DATABASE "kline_pilot_probe"']


def test_reset_clears_an_empty_remnant_end_to_end():
    """**正向钉**：崩在写 `pilot_meta` 之前的空残骸必须真的被清掉（R56-F1 / R55-F1）。

    ⚠️ 少了它，实现可以「零对象例外一律不放行」而所有「拒了」的档全绿 ——
       而那条逃生口正是残骸唯一的出路。
    """
    maint = _ResetMaint()
    assert asyncio.run(_reset_db(maint, via_remnant=True)) == "16400"
    assert _drops(maint) == ['DROP DATABASE "kline_pilot_probe"']


def test_reset_refuses_when_any_session_is_on_the_target():
    """规定 1：DROP 之前断言目标库上**零会话**，并把占用者打印出来（规定 3）。"""
    maint = _ResetMaint(target_sessions=[_session(pid=777, usename="dba",
                                                  application_name="pgAdmin")])
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint))
    assert ei.value.code == "target_db_in_use"
    for token in ("777", "dba", "pgAdmin"):
        assert token in str(ei.value), f"占用者信息缺 {token}"
    assert _drops(maint) == [], "闸未过时一句 DDL 都不许执行"


def test_reset_refuses_when_the_instance_is_no_longer_the_authorized_one():
    """闸过了、DROP 之前同名库被删掉又重建 → 绝不删那个从未过闸的替身。"""
    target = _EmptyOnProbe(non_empty_probes=[1], meta_rows=_full_meta_rows())

    class _SwapBeforeDrop(_ResetMaint):
        """占用者检查跑完之后，同名库变成另一个实例。"""

        async def fetch(self, query, *args):
            rows = await super().fetch(query, *args)
            if "pg_stat_activity" in query:
                self.live_db_oid = "99999"
            return rows

    maint = _SwapBeforeDrop()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, target=target))
    assert ei.value.code == "target_db_replaced"
    assert _drops(maint) == []


def test_reset_requires_the_seed_lock_to_be_really_held():
    """破坏性动作同样要求按 seed 的锁**在活连接上真被持有**（O4-R5-C2）。"""
    maint = _ResetMaint(seed_lock_held=False)
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint))
    assert ei.value.code == "seed_lock_not_held"
    assert _drops(maint) == []


@pytest.mark.parametrize("over,code,label", [
    ({"db_name": "postgres", "seed": "probe"}, "illegal_db_name", "系统库"),
    ({"db_name": "kline_pilot_other", "seed": "probe"}, "seed_db_name_mismatch",
     "名字合法但不是本次 seed 派生的"),
])
def test_reset_refuses_a_name_it_must_not_touch(over, code, label):
    """名字护栏排在**最前**：它是最根本、最便宜的一条。

    ⚠️ 次序不能反：先跑 `_assert_seed_db_name` 的话，`db_name='postgres'` 会被报成
       「不是这个 seed 派生的」，而操作者真正需要看到的是「这个名字根本不允许被 DROP」。
    """
    maint = _ResetMaint()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, **over))
    assert ei.value.code == code, label
    assert _drops(maint) == []


def test_reset_maps_object_in_use_to_target_db_in_use_and_never_retries_with_force():
    """DROP 被别人顶住（55006）→ `target_db_in_use`，**一次都不重试、绝不用 FORCE**。"""
    maint = _ResetMaint(drop_error=_PgError("55006", "is being accessed by other users"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint))
    assert ei.value.code == "target_db_in_use"
    assert len(_drops(maint)) == 1, "重试了"
    assert all("FORCE" not in q.upper() for q in _drops(maint))


def test_reset_does_not_swallow_unrelated_failures():
    """权限不足（42501）之类**不许**兜成 `target_db_in_use` —— 恢复动作整个走错。"""
    maint = _ResetMaint(drop_error=_PgError("42501", "permission denied"))
    with pytest.raises(_PgError):
        asyncio.run(_reset_db(maint))


# ── 封锁临界区（codex 4a-2 R10-F1 critical / R11 / R12 / R15-F1）──────────────

def test_remnant_reset_seals_new_connections_before_the_final_proof():
    """零对象例外的授权理由是「它当时是空的」，而验空到 DROP 之间是一个真实窗口。
    封锁必须在**最后那次验空之前**发出。"""
    maint = _ResetMaint()
    asyncio.run(_reset_db(maint, via_remnant=True))
    assert _connlimit_ops(maint)[:1] == [
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS false CONNECTION LIMIT 0']


def test_normal_reset_is_also_sealed_before_its_recheck():
    """R15-F1：**两条来路**都进封锁临界区，不是只有零对象例外那条。"""
    maint = _ResetMaint()
    asyncio.run(_reset_db(maint))
    assert _connlimit_ops(maint)[:1] == [
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS false CONNECTION LIMIT 0']


def test_the_seal_blocks_new_connections_from_superusers_too():
    """封锁必须挡住**超级用户**的新连接（codex 合并评审 F1，真 PG 15 实测）。

    `CONNECTION LIMIT 0` **只挡非超级用户** —— 模块自己一直如实登记着这条边界。
    问题是本工具在 pilot 部署里**就是**超级用户跑的（并发档 Ⓔ 已证明非超级用户
    连集群闸都过不去），所以「另一个用同一套凭据的并发任务」正是最现实的威胁面：
    它能在最后一次复验之后、DROP 之前连进来建表再断开，
    于是一个**已经不空**的库被删掉 —— 正是封锁要堵的那个数据丢失形态。

    ⚠️ 真 PG 15 实测（本轮亲跑）确认 `ALLOW_CONNECTIONS false` 可用，且推翻了
       模块此前那条「用不了」的注释 —— 那条注释假设的是**先封再连**的次序：
       · 已建立的会话**不受** `datallowconn=false` 影响 → 持住的那条仍能验空；
       · **新的超级用户**连接被挡（`is not currently accepting connections`）；
       · `datallowconn=false` 时 `DROP DATABASE` 照样成功。
       R12-F1 早就把次序定成「先连上再封」，那条注释是那次改动之后没跟着更新的。
    """
    maint = _ResetMaint()
    asyncio.run(_reset_db(maint, via_remnant=True))
    seal = [q for q in maint.executed if "ALLOW_CONNECTIONS" in q.upper()]
    assert seal, "封锁没有动 ALLOW_CONNECTIONS —— 超级用户仍能在窗口里连进来"
    assert seal[0] == ('ALTER DATABASE "kline_pilot_probe" '
                       'WITH ALLOW_CONNECTIONS false CONNECTION LIMIT 0'), \
        f"封锁语句形状不对：{seal[0]!r}"


def test_reset_restores_both_seal_flags_to_their_prior_values():
    """拒绝之后**两个**标志都要还成原值（R11-F2 的判据扩到 `datallowconn`）。

    ⚠️ 一律恢复成 `true` 会把一个被 DBA **明确设成不可连**的库顺手打开 ——
       与「一律恢复 −1 会抹掉原有连接策略」是同一条毛病。
    """
    maint = _ResetMaint(late_sessions=[_session(pid=555)])
    maint.datconnlimit = 7
    maint.datallowconn = False
    with pytest.raises(PilotDbBoundaryError):
        asyncio.run(_reset_db(maint))
    assert _connlimit_ops(maint) == [
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS false CONNECTION LIMIT 0',
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS false CONNECTION LIMIT 7'], \
        f"两个标志没有各自还成原值：{_connlimit_ops(maint)}"


def test_the_seal_is_restored_while_the_target_session_is_still_held():
    """复验拒绝时，恢复必须发生在**还持着目标库会话**的时候（codex 合并评审 F2）。

    放掉会话之后再按名字发 `ALTER DATABASE`，名字↔实例就不再稳定：
    并发的特权进程可以在「按 oid 核对」与「发 ALTER」之间把同名库删掉重建，
    于是这段代码去改一个**从未过闸**的替身的配置。
    持着会话期间别人删不掉这个库（DROP 会撞 55006），名字↔实例因此是钉死的。

    ⚠️ 判据是**发出的次序**：恢复的 ALTER 必须排在目标库连接 close 之前。
    """
    maint = _ResetMaint()
    ok = _EmptyOnProbe(non_empty_probes=[1], meta_rows=_full_meta_rows())
    tampered = _FakeConn(meta_rows=_full_meta_rows(seed="someone_else"))
    with pytest.raises(PilotDbBoundaryError):
        asyncio.run(_reset_db(maint, targets=[ok, ok, tampered]))
    assert tampered.closed is True, "持住的那条会话最后没关"
    assert tampered.closed_after_ops is not None, "夹具没记下 close 时刻"
    restores = [i for i, q in enumerate(maint.executed)
                if "ALLOW_CONNECTIONS" in q.upper() and "LIMIT 0" not in q.upper()]
    assert restores, "拒绝之后压根没恢复封锁"
    assert restores[-1] < tampered.closed_after_ops, (
        f"恢复的 ALTER 发在 close 之后（restore@{restores[-1]}，"
        f"close@{tampered.closed_after_ops}）—— 那时名字可能已经指向替身")


def test_the_held_session_is_closed_even_when_restoring_the_seal_fails():
    """恢复封锁失败时，**自己那条目标库会话照样要关**（codex 合并评审 R2-F1）。

    ⚠️ **这是我上一轮修 F2 时自己引入的回归，如实登记**：把恢复挪到 close 之前之后，
       `_restore_seal()` 一抛，`_close_quietly(target_conn)` 就再也到不了 ——
       一次 fail-closed 的拒绝会把库**既留在封锁态、又被本进程占着**，
       随后的重试连 DROP 都发不出去（会被我们自己顶住）。
       「修 symptom 会挪动失败面」在本仓记录在案，这是又一次。
    ⚠️ 抛出去的仍然是 `connection_limit_not_restored`：
       「库被留在不可连状态」比「这次 reset 为什么被拒」更需要人立刻知道。
    """
    maint = _ResetMaint(late_sessions=[_session(pid=555)],
                        restore_error=_PgError("08006", "connection reset"))
    # ⚠️ **持住的那条必须是独立对象**：三次连接共用一个假件时，探测那次的 close
    #    会把 `closed` 先置成 True，这条断言就恒真了（写第一版时当场踩到）。
    probe = _EmptyOnProbe(non_empty_probes=[1], meta_rows=_full_meta_rows())
    held = _FakeConn(meta_rows=_full_meta_rows())
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, targets=[probe, probe, held]))
    assert ei.value.code == "connection_limit_not_restored"
    assert held.closed is True, \
        "恢复失败之后没关掉自己那条目标库会话 —— 库既被封着又被我们自己占着"
    assert _drops(maint) == []


def test_a_close_failure_does_not_mask_the_revalidation_verdict():
    """**刻意的不对称，钉住它**：复验拒绝时，关不掉会话不得顶掉那个结论。

    与 `test_close_failure_never_masks_the_gate_verdict`（O4-W2r1 M-2）同一条规矩。
    ⚠️ codex 合并评审 R2-F1 的第二半建议「close 失败也要显式上报」——
       那会让 `target_db_in_use` 顶掉 `not_owned`，操作者于是去查「谁连着这个库」，
       而真相是「这个库在窗口里被改成别人的了」。故不采纳。
       关不掉这件事仍由 `_close_quietly` 打警告，且此时会话还活着反而**护住**了这个库。
    """
    maint = _ResetMaint()
    ok = _EmptyOnProbe(non_empty_probes=[1], meta_rows=_full_meta_rows())
    tampered = _UncloseableConn(meta_rows=_full_meta_rows(seed="someone_else"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, targets=[ok, ok, tampered]))
    assert ei.value.code == "not_owned", "复验的结论被 close 失败顶掉了"
    assert _drops(maint) == []


def test_reset_restores_the_databases_prior_connection_limit_when_refused():
    """拒绝之后必须把连接上限还成**原值**，不是写死的 −1（codex 4a-2 R11-F2）。

    一律恢复 −1 会把一个本工具**明确选择不销毁**的库的连接策略永久改成「无限制」。
    """
    maint = _ResetMaint(late_sessions=[_session(pid=555)])
    maint.datconnlimit = 7
    with pytest.raises(PilotDbBoundaryError):
        asyncio.run(_reset_db(maint))
    assert _connlimit_ops(maint) == [
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS false CONNECTION LIMIT 0',
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS true CONNECTION LIMIT 7']


def test_reset_seals_even_for_a_non_superuser_maintenance_role():
    """封锁**不许**依赖「维护角色是超级用户」（codex 4a-2 R12-F1）。

    R11 那版是「不是超级用户就跳过封锁」—— 等于在一个仍然删得掉库的部署上
    把数据丢失窗口原样留着，拿数据安全换可用性。
    正确形状是「先连上再封」：已建立的会话不受 `CONNECTION LIMIT 0` 影响。
    ⚠️ 判据是**问都没问过** —— 问一次就说明那条分支又回来了。
    """
    maint = _ResetMaint()
    maint.is_superuser = False
    asyncio.run(_reset_db(maint, via_remnant=True))
    assert maint.is_superuser_queries == 0, "封锁又去问「是不是超级用户」了"
    assert _drops(maint) == ['DROP DATABASE "kline_pilot_probe"']


def test_reset_excludes_its_own_held_session_from_the_occupant_check():
    """封锁之后那次占用者复查必须按 pid 把**我们自己持住的那条**排除掉。

    不排除的话这条闸一上来就把自己判成占用者，逃生口永远走不通（R12-F1 真 PG 实测）。
    """
    maint = _ResetMaint()
    asyncio.run(_reset_db(maint, via_remnant=True))
    excluding = [(q, a) for q, a in maint.session_queries if "a.pid <> $2" in q]
    assert excluding, "封锁之后没有发出「排除自己」的那条占用者查询"
    assert excluding[-1][1][1] == _HELD_PID, \
        f"排除的不是持住那条会话的 pid：{excluding[-1][1]}"


def test_reset_still_refuses_when_another_client_session_exists_after_sealing():
    """**反向**：封的是新连接，封之前就连着的还在 → 封住之后必须再数一遍。"""
    maint = _ResetMaint(late_sessions=[_session(pid=6001, usename="app")])
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint))
    assert ei.value.code == "target_db_in_use"
    assert "6001" in str(ei.value)
    assert _drops(maint) == []


def test_seal_is_recorded_before_the_alter_is_awaited():
    """`execute()` 抛异常**不等于**服务端没执行（codex 4a-2/S2 R1-F1，high）。

    回包丢、连接断、进程被信号打断都会抛，而 `ALTER DATABASE` 已经生效。
    标记记在 await 之后的话，`finally` 整段被跳过 →
    目标库被永久留在 `CONNECTION LIMIT 0`，对所有非超级用户不可连。
    """
    maint = _ResetMaint(seal_error=_PgError("08006", "connection reset"))
    maint.datconnlimit = 5
    with pytest.raises(Exception):
        asyncio.run(_reset_db(maint))
    assert _connlimit_ops(maint) == [
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS false CONNECTION LIMIT 0',
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS true CONNECTION LIMIT 5'], \
        "封锁的 ALTER 抛了就当没执行 —— 库会被永久留在不可连状态"


# ── 封锁下的紧贴复验：零对象例外那条来路 ─────────────────────────────────

def test_remnant_reset_rechecks_emptiness_under_the_seal():
    """授权理由是「它是空的」，而那是**会过期的事实**（R10-F1，真 PG 已复现数据丢失）。

    第 3 次验空 = 封锁下那次（前两次在 `try_empty_remnant_exception` 里）。
    """
    maint = _ResetMaint()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, via_remnant=True,
                              target=_EmptyOnProbe(non_empty_probes=[3])))
    assert ei.value.code == "not_owned"
    assert _drops(maint) == [], "窗口里变得不空了，却还是 DROP 了"


@pytest.mark.parametrize("bad,label", [
    ({"create_confirmed": False}, "凭据在窗口里被换成未确认的行"),
    ({"intent_db_oid": "99999"}, "凭据在窗口里被换成指向另一个实例的行"),
    ({"age_seconds": INTENT_TTL_SECONDS}, "凭据在窗口里过期了"),
])
def test_remnant_reset_rejects_a_stale_intent_row_under_the_seal(bad, label):
    """只重查【绝对空】是不够的（codex 4a-2/S2 R2-F1）。

    零对象例外**绕过** pilot_meta 归属与 `--reset-foreign` 令牌，
    那行 intent 凭据是它仅有的归属依据 —— 而它同样会过期：
    被别的运行清掉、被换成指向另一个实例的行、或者就是过了 TTL。
    """

    class _IntentRotsUnderSeal(_ResetMaint):
        """封锁之后（= 已经发过 `CONNECTION LIMIT 0`）再读 intent 时给坏行。"""

        async def fetch(self, query, *args):
            if ("FROM public.pilot_create_intent i " in query
                    and any("CONNECTION LIMIT 0" in q.upper() for q in self.executed)):
                self.intent_rows = list(_intent(**bad))
            return await super().fetch(query, *args)

    maint = _IntentRotsUnderSeal()
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, via_remnant=True))
    assert ei.value.code == "not_owned", label
    assert _drops(maint) == [], label


def test_remnant_reset_still_succeeds_with_a_valid_intent_row():
    """**正向钉**：凭据一直有效时，封锁下的复查必须放行（别把闸修成谁都过不了）。"""
    maint = _ResetMaint()
    assert asyncio.run(_reset_db(maint, via_remnant=True)) == "16400"
    assert _drops(maint) == ['DROP DATABASE "kline_pilot_probe"']


# ── 封锁下的紧贴复验：闸 0−/0/0b 那条来路（塌缩之后判据变了，见设计 §六）───────
#
# ⚠️ **判据从「和记下来的身份比对」改成「拿本次调用的入参重跑一遍闸」**。
#    R3-F1 当初要求记身份，是因为授权与 DROP 拆成了两个函数：使用点若重新判，
#    只能写成「绑定相符 **or** 令牌对得上」，即两种理由取并集 ——
#    于是靠绑定相符过的授权能被一份**别的身份的**令牌接管。
#    塌缩之后**入参在一次调用里不会变**：并集的两侧都只对「这次调用者的权限」成立，
#    接管不了。故不再需要身份快照，也就不再有可被伪造的「记下来的事实」。

def test_normal_reset_revalidates_ownership_under_the_seal():
    """正常 reset 路径也必须在封锁下复验归属（codex 4a-2 R15-F1，high）。"""
    maint = _ResetMaint()
    ok = _EmptyOnProbe(non_empty_probes=[1], meta_rows=_full_meta_rows())
    tampered = _FakeConn(meta_rows=_full_meta_rows(seed="someone_else"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, targets=[ok, ok, tampered]))
    assert ei.value.code == "not_owned"
    assert _drops(maint) == [], "归属在窗口里被改掉了，却还是 DROP 了"


def test_normal_reset_revalidates_the_binding_under_the_seal():
    """R15-F1 的另一半：`seed` 没动、绑定被改成另一套设置。

    ⚠️ **判据是 `reset_foreign_token_required`，不是 `binding_mismatch`**（设计 §六）：
       复验就是拿本次入参重跑闸 0b —— 绑定不符时它要的是令牌，而本次调用没带。
       这条错误还会带上该库**此刻**的确认令牌，正是操作者需要的下一步。
    """
    maint = _ResetMaint()
    ok = _EmptyOnProbe(non_empty_probes=[1], meta_rows=_full_meta_rows())
    tampered = _FakeConn(meta_rows=_full_meta_rows(output_dir="/someone_else"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, targets=[ok, ok, tampered]))
    assert ei.value.code == "reset_foreign_token_required"
    assert _drops(maint) == [], "绑定在窗口里被改掉了，却还是 DROP 了"


def test_foreign_reset_survives_the_revalidation_when_the_identity_is_unchanged():
    """**正向钉**：`--reset-foreign` 那条路的绑定是**故意不符**的，必须照常放行。

    ⚠️ 刚性必需（本仓「全是『拒了』的套件 → 恒抛的守卫处处像在工作」）：
       上面两条都断言「拒了」，而复验若写成「绑定不符一律拒」，两条照样全绿，
       却把一次合法的 foreign reset 判死 —— R55-F1 锁死换个形态回来。
    """
    maint = _ResetMaint()
    foreign = _full_meta_rows(export_log_sha256="b" * 64, output_dir="/other")
    token = derive_confirm_token("b" * 64, "/other", "20260729T101530123456Z")
    got = asyncio.run(_reset_db(
        maint, target=_EmptyOnProbe(non_empty_probes=[1], meta_rows=foreign),
        reset_foreign_token=token))
    assert got == "16400"
    assert _drops(maint) == ['DROP DATABASE "kline_pilot_probe"']


def test_foreign_reset_is_refused_when_the_identity_changes_under_the_seal():
    """令牌由 `(export_log_sha256, output_dir, created_at)` 派生 ——
    窗口里 meta 被改过，当初那份「令牌对得上」的理由就不再成立。

    ⚠️ **判据是 `reset_foreign_token_invalid`**（设计 §六）：复验拿的是本次入参里
       那个令牌，而它对**改之后**这份身份派生不出来。
    """
    maint = _ResetMaint()
    foreign = _full_meta_rows(export_log_sha256="b" * 64, output_dir="/other")
    token = derive_confirm_token("b" * 64, "/other", "20260729T101530123456Z")
    ok = _EmptyOnProbe(non_empty_probes=[1], meta_rows=foreign)
    changed = _FakeConn(meta_rows=_full_meta_rows(export_log_sha256="b" * 64,
                                                  output_dir="/moved_again"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, targets=[ok, ok, changed],
                              reset_foreign_token=token))
    assert ei.value.code == "reset_foreign_token_invalid"
    assert _drops(maint) == []


def test_normal_reset_still_proceeds_when_only_created_at_changes_under_the_seal():
    """⭐ **塌缩带来的一处有意的语义变化，明写钉住它**。

    旧实现把「授权那一刻该库自称的身份」记成三元组
    `(export_log_sha256, output_dir, created_at)`，故窗口里只改 `created_at`
    也会被拒（`binding_mismatch`）。塌缩之后复验的判据是「拿本次入参重跑闸」：
    · 本次的放行理由是「绑定与调用方的两个标量相符」；
    · `created_at` **不参与**这个理由（它只是令牌的原像之一，而本次不需要令牌）；
    · 目标实例 oid 没变、归属没变、绑定没变 —— **当初批准销毁它的理由原样成立**。
    因此这里放行是正确的，不是漏判。

    ⚠️ 记下来是因为它**改变了对外可观察的行为**：不写这一条，
       下一轮有人看到旧实现的 `binding_mismatch` 用例被删掉，会以为是漏删。
    ⚠️ foreign 那条路不受影响：改 `created_at` 会让令牌派生结果变化，
       由上一条 `…identity_changes_under_the_seal` 拦住。
    """
    maint = _ResetMaint()
    ok = _EmptyOnProbe(non_empty_probes=[1], meta_rows=_full_meta_rows())
    moved = _FakeConn(meta_rows=_full_meta_rows(created_at="20991231T235959999999Z"))
    assert asyncio.run(_reset_db(maint, targets=[ok, ok, moved])) == "16400"
    assert _drops(maint) == ['DROP DATABASE "kline_pilot_probe"']


def test_normal_reset_restores_the_connection_limit_when_the_revalidation_refuses():
    """正常路被复验拒掉时，封锁**必须**还回去（R10-F1 那条修复的同族失败模式）。"""
    maint = _ResetMaint()
    maint.datconnlimit = 7
    ok = _EmptyOnProbe(non_empty_probes=[1], meta_rows=_full_meta_rows())
    tampered = _FakeConn(meta_rows=_full_meta_rows(seed="someone_else"))
    with pytest.raises(PilotDbBoundaryError):
        asyncio.run(_reset_db(maint, targets=[ok, ok, tampered]))
    assert _connlimit_ops(maint) == [
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS false CONNECTION LIMIT 0',
        'ALTER DATABASE "kline_pilot_probe" WITH ALLOW_CONNECTIONS true CONNECTION LIMIT 7']


def test_the_sealed_recheck_and_the_authorizing_gate_share_one_implementation():
    """机械守卫：闸 0−/0/0b 只许有**一份**实现，两个使用点都调它。

    ⚠️ 两处各写一遍判据必然漂移，而漂移的方向恰好会让复验那一处失去判别力
       —— `_has_qualified_intent_row` 当初被抽出来就是这条理由（R2-F1）。
    ⚠️ 判据走 AST 的 Name 节点，不看源码文本：注释里提到函数名会让它恒真。
    """
    import inspect
    import textwrap
    import qmt_pilot_db as m
    callers = {}
    for fn in (m.assert_db_allowed_for_reset, m.reset_pilot_database):
        src = textwrap.dedent(inspect.getsource(fn))
        callers[fn.__name__] = {n.id for n in ast.walk(ast.parse(src))
                                if isinstance(n, ast.Name)}
    for name, names in callers.items():
        assert "_assert_reset_gates_on" in names, \
            f"{name} 没有走那份唯一的闸 0−/0/0b 实现"
    # 反向自检：扫描器确实解析出了东西（否则上面两条恒真）
    assert all(len(n) > 3 for n in callers.values()), \
        f"扫描器几乎什么都没解析到，上面的断言是恒真的：{callers}"


# ── DROP 的**部分失败**：`execute()` 抛 ≠ 服务端没执行（R1-F2 / R6-F1）─────────

def test_ambiguous_drop_is_reconciled_against_pg_database():
    """回包丢但库真的没了 → 与 `pg_database` 对账后按**成功**收尾。

    只按「execute 抛没抛」判的话，`_CLEAR_DROPPED_INTENT_SQL` 一次都不跑 →
    那行凭据仍然新鲜且已确认、却指向消失了的实例 →
    紧接着用**新 run_id** 重建撞 `intent_row_conflict`：库删掉了却重建不了。
    """
    maint = _ResetMaint(drop_error=_PgError("08006", "connection reset"),
                        vanish_on_drop=True)
    assert asyncio.run(_reset_db(maint)) == "16400"
    assert any("pilot_create_intent" in q and q.strip().upper().startswith("DELETE")
               for q in maint.executed), "对账判成功了，却没清那条凭据"


def test_a_genuine_drop_failure_is_still_reported():
    """名字还在、还是那个实例 → 真失败，原异常照样上抛。"""
    maint = _ResetMaint(drop_error=_PgError("08006", "connection reset"))
    with pytest.raises(_PgError):
        asyncio.run(_reset_db(maint))


def test_ambiguous_drop_refuses_when_the_name_is_taken_by_a_replacement():
    """被授权的实例没了、但这个**名字**此刻指向另一个实例（codex 4a-2/S2 R6-F1，high）。

    判据写成 `oid_after != authorized_oid` 会把这一档当成成功 ——
    而那一刻这个名字被一个**没过任何闸**的库占着，调用方接着重建会撞
    duplicate_database，且它拿到的是一个**破坏性操作的假成功信号**。
    """
    maint = _ResetMaint(drop_error=_PgError("08006", "connection reset"),
                        replace_on_drop="99999")
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint))
    assert ei.value.code == "target_db_replaced"


# ── DROP 之后清凭据（codex 4a-2b R4-F1 / R11-F1）──────────────────────────

def test_reset_clears_the_intent_row_of_the_instance_it_destroyed():
    """不清的话那一行仍然新鲜且已确认、只是指向一个消失了的 oid ——
    用**新 run_id** 重建会撞 `intent_row_conflict`：删掉了却重建不了，自锁。"""
    maint = _ResetMaint()
    asyncio.run(_reset_db(maint, via_remnant=True))
    deletes = [q for q in maint.executed
               if q.strip().upper().startswith("DELETE")
               and "pilot_create_intent" in q]
    assert len(deletes) == 1, f"DROP 之后没有恰好一条清理语句：{deletes}"


def test_dropped_intent_cleanup_is_not_bound_to_the_destroyed_oid_alone():
    """机械守卫：清理谓词必须**同时**覆盖「指不到任何活实例」的行（R11-F1，high）。

    `db_oid` 可空，而 intent 行写在 `CREATE DATABASE` **之前** —— 那一刻它就是 NULL。
    只按被销毁的 oid 清，NULL 与陈旧 oid 的行都会留下并把重建卡死。
    ⚠️ 语义证明在真 PG 档 ㉞b（那里紧接着用新 run_id 重建**必须成功**）。
    """
    import qmt_pilot_db as m
    sql = m._CLEAR_DROPPED_INTENT_SQL
    assert "pg_database" in sql and "NOT EXISTS" in sql.upper(), (
        f"清理谓词只按 db_oid 匹配，NULL / 陈旧 oid 的行会留下来并把重建卡死：{sql!r}")


# ── 次序与唯一入口（S2a 明写接受的那条残留，本片还回来）────────────────────

def test_reset_welds_the_spec_order_into_one_function_body():
    """⭐ spec §4 的有向序列（零对象例外 → 否则闸 0−/0/0b）必须焊在**一个函数体**里。

    ⚠️ S2a 把这条性质明写成「本片没有任何东西机器强制」的残留 ——
       因为焊住它的函数体就是本片这一个。这颗钉子是那笔账的偿还。
    ⚠️ 判据走 AST 而非源码文本：docstring 里提到函数名会让文本判据恒真
       （同一形态在本 PR 已被变异抓到过一次）。
    """
    import inspect
    import textwrap
    import qmt_pilot_db as m
    tree = ast.parse(textwrap.dedent(inspect.getsource(m.reset_pilot_database)))
    calls = [n.func.id for n in ast.walk(tree)
             if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)]
    assert "try_empty_remnant_exception" in calls, "唯一入口没有走零对象例外"
    assert "assert_db_allowed_for_reset" in calls, "唯一入口没有走闸 0−/0/0b"
    assert calls.index("try_empty_remnant_exception") < calls.index(
        "assert_db_allowed_for_reset"), "次序反了：例外必须排在闸 0− 之前"


def test_reset_runs_the_cluster_gate_before_sealing():
    """集群闸没过 → 一句 `ALTER DATABASE` 都不许发（codex 4a-2/S2 R4-F1）。

    「这台集群是给 pilot 用的一次性环境」是整套破坏性护栏的地基假设。
    """
    maint = _ResetMaint(marker_rows=[])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_reset_db(maint))
    assert ei.value.code == "no_marker"
    assert _connlimit_ops(maint) == [], "集群闸未过就动了目标库的连接策略"
    assert _drops(maint) == []


def test_reset_refuses_a_foreign_database_end_to_end():
    """端到端：归属不符时唯一入口照样拒，且**不给令牌**（令牌只解「同 seed 但绑定不同」）。"""
    maint = _ResetMaint()
    target = _EmptyOnProbe(non_empty_probes=[1],
                           meta_rows=_full_meta_rows(tool="something_else"))
    with pytest.raises(PilotDbBoundaryError) as ei:
        asyncio.run(_reset_db(maint, target=target))
    assert ei.value.code == "not_owned"
    assert ei.value.confirm_token is None
    assert _drops(maint) == []


def test_reset_pilot_database_is_the_only_public_destructive_entry():
    """机械守卫：模块里执行 `DROP DATABASE` 的地方**只有一处**，且在唯一公开入口里。

    ⚠️ 判据剥掉注释与 docstring 再看（本模块通篇在讨论 `DROP DATABASE`）。
    """
    import qmt_pilot_db as m
    src = pathlib.Path(m.__file__).read_text(encoding="utf-8")
    tree = ast.parse(src)
    holders = set()
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for sub in ast.walk(node):
            if isinstance(sub, ast.JoinedStr):
                literal = "".join(v.value for v in sub.values
                                  if isinstance(v, ast.Constant)
                                  and isinstance(v.value, str))
                if literal.strip().upper().startswith("DROP DATABASE"):
                    holders.add(node.name)
    assert holders == {"reset_pilot_database"}, \
        f"执行 DROP DATABASE 的函数不只唯一入口一个：{sorted(holders)}"
    # 反向自检：扫描器真的在这份源码上找到了那条语句（否则上面那条是恒真的）
    assert holders, "一处 DROP DATABASE 都没扫到 —— 匹配式过时了，这颗钉子是空的"


def test_no_production_module_reaches_past_the_public_reset_entry():
    """机械守卫：生产代码不许绕过 `reset_pilot_database` 直接碰破坏性内部件。

    ⚠️ **Python 进程内不存在能力边界**，它防不住蓄意绕过，也不该被写成防得住。
       它防的是 spec §1 风险① 那一类**接线失误**（4c 接线时错调了内部函数），
       而接线失误一定表现为**仓库里多出一个调用点** —— 那是机械抓得住的。
    """
    import qmt_pilot_db as m
    private = {"_SEAL_CONNECTIONS_SQL", "_RESTORE_CONNLIMIT_SQL",
               "_CLEAR_DROPPED_INTENT_SQL", "_OTHER_CLIENT_SESSIONS_SQL",
               "_assert_reset_gates_on"}
    # ⚠️ **自检 A**：名单里的符号必须在模块里**真实存在**。
    #    不存在的名字扫不到任何引用 → 那一项恒真。
    absent = sorted(n for n in private if not hasattr(m, n))
    assert not absent, f"守卫名单里这些符号在模块里不存在，对应的检查是**恒真**的：{absent}"

    backend = pathlib.Path(m.__file__).resolve().parent
    scanned, offenders = [], []
    for path in sorted(backend.rglob("*.py")):
        rel = path.relative_to(backend)
        if rel.parts[0] == "tests" or path.samefile(m.__file__):
            continue                       # 测试当然要碰；模块自己就是定义处
        scanned.append(str(rel))
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module == "qmt_pilot_db":
                offenders += [f"{rel}: from qmt_pilot_db import {a.name}"
                              for a in node.names if a.name in private]
            elif isinstance(node, ast.Attribute) and node.attr in private:
                offenders.append(f"{rel}: …{node.attr}")
    # ⚠️ **自检 B**：扫描器必须真的扫到文件，否则下面那条是恒真的。
    assert scanned, "扫描器一个生产文件都没找到 —— 它已经失去判别力"
    assert any("scripts/" in s for s in scanned), \
        f"没扫到 scripts/ —— 验收脚本正是最可能图省事的地方：{scanned}"
    assert not offenders, (
        f"这些生产文件绕过了 reset_pilot_database 直接碰破坏性内部件：{offenders}")


# ---------------------------------------------------------------------------
# init_cluster_marker —— 幂等语义 + 孤儿 intent 行清理（spec §4 + O4-F7 + O4-F2 修正③）
# ---------------------------------------------------------------------------

# ⚠️ **必须是仓库里那份真文件**：init 把 `cluster_schema_sql` 钉到
#    `CANONICAL_CLUSTER_SCHEMA_SHA256`，随手编一段 DDL 过不了那道闸 ——
#    而这正是它的意义：递进来的 DDL 会直接在**维护库**上执行。
_CLUSTER_SQL = (_SQL_DIR / "pilot_cluster_schema.sql").read_text(encoding="utf-8")


def test_canonical_cluster_schema_hash_matches_the_repo_file():
    """防漂移：改了 `pilot_cluster_schema.sql` 而没更新常量，这颗钉子当场变红
    （与 4a-1 给另外两份 schema 立的钉子同族）。"""
    import qmt_pilot_db as m
    actual = m.sha256_of_sql(
        (_SQL_DIR / "pilot_cluster_schema.sql").read_text(encoding="utf-8"))
    assert actual == m.CANONICAL_CLUSTER_SCHEMA_SHA256, (
        f"pilot_cluster_schema.sql 变了：实算 {actual!r}，"
        f"常量 {m.CANONICAL_CLUSTER_SCHEMA_SHA256!r}")


def test_canonical_cluster_schema_file_stays_non_destructive():
    """反向断言：那份文件本身只许有 `CREATE TABLE IF NOT EXISTS`。

    光钉哈希挡不住「有人既改了文件、又顺手更新了常量」——而这份 DDL 跑在维护库上，
    一句 DROP/TRUNCATE 就能把恢复凭据与归属登记清空。
    """
    text = (_SQL_DIR / "pilot_cluster_schema.sql").read_text(encoding="utf-8")
    code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("--"))
    for banned in ("DROP ", "TRUNCATE", "DELETE ", "ALTER "):
        assert banned not in code.upper(), f"规范集群 schema 里出现破坏性语句 {banned!r}"
    assert code.upper().count("CREATE TABLE IF NOT EXISTS") == len(MAINTENANCE_TABLES), \
        "建表条数与【维护库专用表集合】对不上"


class _InitMaint(_FakeConn):
    """维护连接：三张表的「在场」与「补建后才合规」、全表 intent 扫描、**锁状态的迁移**。"""

    def __init__(self, all_intent_rows=(), intent_table_missing=False,
                 pre_held_seeds=(), **kw):
        super().__init__(**kw)
        self.all_intent_rows = list(all_intent_rows)
        # ⚠️ **锁状态必须建模成会变的集合，不能是一个静态布尔**：孤儿清理在
        #    **取锁前后各查一次** `_SEED_LOCK_HELD_SQL` —— 前一次必须为假（证明这把锁
        #    不是本连接早就持有的），后一次必须为真（证明回调真的把它取到了）。
        #    父类的 `seed_lock_held` 是**一个布尔**，两次查询会得到同一个答案，
        #    于是**两条判据里必然有一条恒真、测不出东西**。
        #    `pre_held_seeds` = 进入 init **之前**就已挂在这条连接上的锁（可重入那一档）。
        self.held_seeds = set(pre_held_seeds)
        if intent_table_missing:
            # 旧版本初始化的集群：marker 在、intent 不在 → 结构判据先不合规，
            # 跑过建表 SQL 之后才合规。短路成功的实现修不好这种集群（spec O4-F7）。
            self.maintenance_presence["intent_present"] = False
            self.maintenance_shape = {**_OK_MAINTENANCE_SHAPE,
                                      "intent_is_table": False,
                                      "intent_columns_ok": False,
                                      "intent_dbname_unique": False,
                                      "intent_durable": False}

    async def fetchval(self, query, *args):
        # 父类按 `"pg_locks" in query` 返回静态布尔；这里改成按集合作答。
        # ⚠️ 本方法**只建模锁状态**，别往里塞构造期的初始化 —— 那样会落在 `return`
        #    之后成为死代码，而假件「看起来配好了」。
        if "pg_locks" in query:
            self.ops.append(query)
            return args[0] in self.held_seeds
        return await super().fetchval(query, *args)

    async def fetch(self, query, *args):
        # ⚠️ 精确到 `FROM public.pilot_create_intent` **后面直接换行**（即无别名无 WHERE
        #    的那条全表扫描），免得劫走闸 (iii) 的豁免 CTE 或按库名读的那条。
        if "FROM public.pilot_create_intent\n" in query:
            self.ops.append(query)
            return list(self.all_intent_rows)
        return await super().fetch(query, *args)

    async def execute(self, query, *args):
        out = await super().execute(query, *args)
        if "CREATE TABLE" in query.upper():
            self.maintenance_shape = dict(_OK_MAINTENANCE_SHAPE)   # 补建之后结构就合规
            self.maintenance_presence = {k: True for k in self.maintenance_presence}
        if (query.strip().upper().startswith("INSERT")
                and "pilot_cluster_marker" in query):
            # 写完标记之后，随后的「每次现查」应当读得到它。
            # ⚠️ **判别式必须锚在语句开头**（Kimi S3-WB-R1 抓到，与 `_marker_writes`
            #    那条注释同规格）：`_CLUSTER_SQL` 是仓库里那份真文件，它的注释里
            #    同时含 `pilot_cluster_marker` 与 `INSERT`（"INSERT 时为 NULL"），
            #    松散子串匹配会让**补建 DDL** 也把假件的标记置成合法 ——
            #    一个幻影标记，与这一行自己写的「写完标记之后」直接矛盾。
            self.marker_rows = [{"purpose": MARKER_PURPOSE}]
        return out


def _orphan(dbname="kline_pilot_gone", seed="gone", age_seconds=0, db_oid="16400"):
    """⚠️ 字段必须与 `_LIST_ALL_INTENT_SQL` 的输出**逐字一致** —— 少给一个就是
    「测试在测另一个东西」。`db_oid` 是预筛绑实例用的。"""
    return {"dbname": dbname, "seed": seed, "age_seconds": age_seconds,
            "db_oid": db_oid}


def _locker(maint=None, *, grants=True, record=None, released=None):
    """返回 (try_seed_lock, release_seed_lock) 一对 —— **取了就必须还**。

    ⚠️ 真授予时**同步更新假件的 `held_seeds`**：模块随后要在 `maint_conn` 上用
       `_SEED_LOCK_HELD_SQL` 复核，「回调说取到了」与「连接上真挂着」必须一致。
       两者**故意可以做成不一致** —— 那正是「回调撒谎」那一档。
    """
    async def _try(seed):
        if record is not None:
            record.append(seed)
        if grants and maint is not None:
            maint.held_seeds.add(seed)
        return grants

    async def _release(seed):
        if released is not None:
            released.append(seed)
        if maint is not None:
            maint.held_seeds.discard(seed)
    return _try, _release


def _init(maint, *, targets=None, lock_pair=None):
    try_lock, release_lock = lock_pair or _locker(maint)
    return init_cluster_marker(
        maint, connect=_connector(targets or {}), cluster_schema_sql=_CLUSTER_SQL,
        try_seed_lock=try_lock, release_seed_lock=release_lock)


def _marker_writes(conn):
    # ⚠️ 判别式必须锚在**语句开头**：`_CLUSTER_SQL` 是仓库里那份真文件，
    #    它的注释里同时含 `pilot_cluster_marker` 与 `INSERT` 两个词，
    #    松散的子串匹配会把建表 DDL 也算成「写标记」。
    return [q for q in conn.executed
            if q.strip().upper().startswith("INSERT") and "pilot_cluster_marker" in q]


def _deletes(conn):
    # ⚠️ 必须 `.strip()`：孤儿删除 SQL 是三引号常量、以换行开头。不 strip 的话
    #    「不许删」那几条断言会变成恒真。
    return [q for q in conn.executed if q.strip().upper().startswith("DELETE")]


def _registered_looking_peer(seed="live"):
    """一个**非空**、且自己写了一份合规 pilot_meta 的同前缀库。

    ⚠️ 键必须**覆盖 `PILOT_META_PHASE1_KEYS` 全部 7 个**（`_looks_like_our_pilot_db`
       的第一条判据就是这个）。漏一个（实测漏过 `pilot_schema_sha256`）会让
       自证那一半直接为假 —— 于是「必须拒」那几条用例**因为错误的原因通过**，
       对「登记表判据」零判别力，而「必须放行」那条会假红。
       故这里从常量派生，而不是手写一份清单。
    """
    values = {"tool": "qmt_pilot", "seed": seed, "state": "ready",
              "export_log_sha256": "a" * 64, "output_dir": "/x/y",
              "created_at": "20260809T101530123456Z",
              "pilot_schema_sha256": "b" * 64}
    missing = set(PILOT_META_PHASE1_KEYS) - set(values)
    assert not missing, f"假件的 pilot_meta 漏了阶段 1 的键：{sorted(missing)}"
    return _FakeConn(user_objects=[("pg_class", 42)],
                     meta_rows=[{"key": k, "value": v} for k, v in values.items()])


def test_init_maint_fake_actually_models_the_states_it_claims():
    """**假件自检**：`_InitMaint` 的两个开关必须真的改变它的作答。

    ⚠️ 这不是形式主义。实测踩过：`maintenance_presence` / `intent_table_missing`
       的初始化被误放到 `fetchval` 的 `return` **之后**成了死代码 ——
       假件「看起来配好了」，而 `intent_table_missing=True` 整个失效，
       补建路径那几条用例**改测了健康集群**（`_needs_repair_ddl` 恒假）。
       与 `test_every_guard_table_shape_proof_covers_table_level_durability` 同族：
       **先证明假件建模对了，再拿它去证明生产代码**。
    """
    healthy = _InitMaint()
    assert healthy.maintenance_presence == {
        "marker_present": True, "intent_present": True, "registry_present": True}
    assert healthy.maintenance_shape == _OK_MAINTENANCE_SHAPE

    missing = _InitMaint(intent_table_missing=True)
    assert missing.maintenance_presence["intent_present"] is False, \
        "intent_table_missing 没有把 intent 置为缺席 —— 补建路径的用例会改测健康集群"
    for key in ("intent_is_table", "intent_columns_ok", "intent_dbname_unique",
                "intent_durable"):
        assert missing.maintenance_shape[key] is False, f"{key} 没有跟着置假"
    # marker / registry 不受影响 —— 否则造出来的是「三张全缺」而不是**混合态**
    assert missing.maintenance_presence["marker_present"] is True
    assert missing.maintenance_shape["marker_durable"] is True

    # 锁状态：默认空；`pre_held_seeds` 真的会被 `_SEED_LOCK_HELD_SQL` 看见
    assert _InitMaint().held_seeds == set()
    assert _InitMaint(pre_held_seeds=("x",)).held_seeds == {"x"}

    # 标记只由**真的写标记**那条语句产生，补建 DDL 不许造出幻影标记
    # （Kimi S3-WB-R1：`_CLUSTER_SQL` 的注释里同时含 `pilot_cluster_marker` 与
    #  `INSERT`——"INSERT 时为 NULL"——松散子串匹配会让补建把假件的标记置成合法，
    #  与 `_InitMaint.execute` 那一行自己写的「写完标记之后」直接矛盾）。
    ddl_only = _InitMaint(marker_rows=[])
    asyncio.run(ddl_only.execute(_CLUSTER_SQL))
    assert ddl_only.marker_rows == [], \
        "补建 DDL 把假件的标记置成了合法 —— 幻影标记会让「首次初始化」那族用例失去判别力"
    wrote = _InitMaint(marker_rows=[])
    asyncio.run(wrote.execute(_WRITE_MARKER_SQL_FOR_FAKE, MARKER_PURPOSE))
    assert wrote.marker_rows == [{"purpose": MARKER_PURPOSE}], \
        "真的写了标记之后，随后的现查却读不到它 —— 假件把幂等那一支建模错了"


def test_init_is_idempotent_when_everything_is_already_legal():
    """已存在合法单行标记且三张表形状合规 → 直接成功，不重复写标记。"""
    maint = _InitMaint()
    asyncio.run(_init(maint))
    assert _marker_writes(maint) == []


def test_init_executes_no_ddl_at_all_on_a_healthy_cluster():
    """三表齐全时**一条 DDL 都不发**。

    `CREATE TABLE IF NOT EXISTS` 虽是空操作，但「健康集群上零 DDL」是可断言的性质，
    比「发了但没效果」强 —— 也让那些 `executed == []` 的钉子真正咬得住。
    """
    maint = _InitMaint()
    asyncio.run(_init(maint))
    assert not any("CREATE TABLE" in q.upper() for q in maint.executed), \
        f"健康集群上仍然发了 DDL：{maint.executed}"


def test_init_repairs_a_cluster_initialized_by_an_older_build():
    """旧版本没有 `pilot_create_intent` 表 → 零对象例外第 6 条恒不成立 → 残骸永远清不掉。
    **幂等短路成功的实现修不好这种集群**（spec O4-F7）。"""
    maint = _InitMaint(intent_table_missing=True)
    asyncio.run(_init(maint))
    assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
        "结构不合规时必须补建，不得短路成功"


def test_init_verifies_the_shape_after_creating_the_tables():
    """补建之后**还要再验一次结构** —— 「执行过 DDL」不等于「结构就对」。

    建表 SQL 由调用方传入；传错一份、或库里本就存在一张被 `IF NOT EXISTS` 跳过的
    旧表，都会让集群带着坏结构被声明为 pilot 专用。

    ⚠️ **必须走「首次初始化」那条路**（变异 M10 实测坐实）：标记已在的那条路末尾是
       `assert_cluster_allowed`，它**也**复验维护表形状、**也**抛 `no_marker` ——
       拿它来测的话，把「建后复验」整段删掉测试照样绿，这条用例对它零判别力。
       首次初始化那条路末尾是 `_assert_disposable_cluster`，它**不看**维护表形状，
       于是「建后复验」是唯一拦得住坏结构的地方。
    """
    maint = _InitMaint(marker_rows=[])
    maint.maintenance_presence = {k: False for k in maint.maintenance_presence}
    maint.maintenance_shape = {**_OK_MAINTENANCE_SHAPE, "intent_dbname_unique": False}

    async def _still_broken(query, *args):          # 建表也修不好它
        maint.executed.append(query)
        maint.ops.append(query)
        return "CREATE TABLE"
    maint.execute = _still_broken
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker"
    assert _marker_writes(maint) == [], "结构还不合规就把标记写进去了"


@pytest.mark.parametrize("rows,label", [
    ([{"purpose": MARKER_PURPOSE}, {"purpose": "x"}], "多行"),
    ([{"purpose": "something_else"}], "值不对"),
])
def test_init_rejects_an_illegal_marker(rows, label):
    """标记非法/多行 → **拒绝**，要求人工处理（spec §4）。绝不「顺手改成对的」。"""
    maint = _InitMaint(marker_rows=rows)
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker", label
    assert _marker_writes(maint) == []
    assert maint.executed == [], f"{label}：拒绝之前已经执行了 DDL"


def test_init_refuses_a_cluster_schema_that_is_not_the_canonical_file():
    """递进来的 DDL 必须逐字节等于仓库那份。"""
    maint = _InitMaint()
    evil = _CLUSTER_SQL + "\nTRUNCATE public.pilot_create_intent;\n"
    # ⚠️ **一对回调必须来自同一次 `_locker(...)` 调用**：写成 `_locker(m)[0], _locker(m)[1]`
    #    会造出两对互不相干的闭包，`record`/`released` 各记各的 → 一族断言恒真。
    _lp = _locker(maint)
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(init_cluster_marker(
            maint, connect=_connector({}), cluster_schema_sql=evil,
            try_seed_lock=_lp[0], release_seed_lock=_lp[1]))
    assert ei.value.code == "cluster_schema_not_canonical"
    assert maint.ops == [], "连一条查询都不该发 —— 这是纯函数判定"


def test_init_refuses_to_declare_a_cluster_whose_maintenance_db_is_not_empty():
    """首次初始化前必须先证明集群干净（闸 (iii)）—— 生产对象可以就放在默认 postgres 库里。"""
    maint = _InitMaint(marker_rows=[], user_objects=[("pg_class", 7)],
                       exempt_objects=[("pg_class", 7)])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "maintenance_db_not_empty"
    assert _marker_writes(maint) == []


def test_init_executes_no_ddl_before_proving_the_maintenance_db_is_safe():
    """`cluster_schema_sql` 会直接在**维护库**上执行。`--maintenance-dsn` 指错到一个
    生产库时，先建表再拒绝 = 已经在别人库里落下了三张表。

    ⚠️ **必须造一个 DDL 真会跑的场景**（变异 M12 实测）：三张表齐全时
       `_needs_repair_ddl` 为假、本来就一条 DDL 都不发，`executed == []` 是恒真的，
       这条用例对「证明排在副作用之前」零判别力。故用**混合态**（缺 intent →
       补建 DDL 会跑）+ 脏维护库，让「先证明还是先建表」真正分得出来。
    """
    maint = _InitMaint(intent_table_missing=True,
                       user_objects=[("pg_class", 9)], exempt_objects=[("pg_class", 9)])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "maintenance_db_not_empty"
    assert maint.executed == [], f"拒绝之前已经执行了 DDL：{maint.executed}"


@pytest.mark.parametrize("broken,label", [
    ({"marker_purpose_unique": False}, "marker 在场但没唯一约束"),
    ({"intent_dbname_unique": False}, "intent 在场但 dbname 没主键"),
    ({"registry_columns_ok": False}, "registry 在场但列不齐"),
    ({"marker_durable": False}, "marker 在场但不是持久表（崩溃后会被 truncate）"),
    ({"intent_durable": False}, "intent 在场但不是持久表"),
    ({"registry_durable": False}, "registry 在场但不是持久表"),
])
def test_init_rejects_a_present_but_malformed_maintenance_table_before_any_ddl(broken, label):
    """`CREATE TABLE IF NOT EXISTS` **修不好**已存在的坏表，只会跳过。

    ⚠️ **判别力的诚实交代**（变异 M4 实测）：本组用例造的是「三张全在场」，此时
       `_needs_repair_ddl` 为假、DDL 本就不跑，于是「建后复验」那一步会兜住同样的
       坏结构并抛同一个 `no_marker` —— 把 `_MAINTENANCE_SHAPE_OWNER` 的前缀映射
       删掉，本组**仍然全绿**。
       真正证明「按表归属」的是下面那条 `..._mixed_state_present_but_non_durable`
       （一张在场但不耐久 + 另一张缺席 → DDL 会跑 → 只有预检阶段的按表归属拦得住）。
       本组钉的是「在场的坏表要被点名拒绝」这条性质本身，别把它当成归属机制的证据。
    """
    maint = _InitMaint()
    maint.maintenance_shape = {**_OK_MAINTENANCE_SHAPE, **broken}
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker", label
    assert maint.executed == [], f"{label}：拒绝之前已经执行了 DDL"


def test_init_rejects_mixed_state_present_but_non_durable_plus_absent_table():
    """**混合态**：一张在场但不耐久 + 另一张缺席 → 仍须在任何 DDL 之前拒。

    这一档正好落在两条钉子的**交叉点**上，两边各自都覆盖不到。
    耐久性判据若是一个**跨三张表的 count**，归因不到具体哪张表，于是预检只能
    「三张全在场才要求它」—— 混合态下 `malformed` 为空 → DDL 先落地。
    真 PG 侧由档 ⑤b 坐实。
    """
    maint = _InitMaint(intent_table_missing=True)
    maint.maintenance_shape = {**maint.maintenance_shape, "marker_durable": False}
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker"
    assert maint.executed == [], "混合态下拒绝之前已经执行了 DDL"


def test_init_still_repairs_a_genuinely_absent_table():
    """反向钉：**缺席**的表照旧补建（别把上面那条做成「一律拒」）。"""
    maint = _InitMaint(intent_table_missing=True)
    asyncio.run(_init(maint))
    assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
        "缺席的表没有被补建 —— O4-F7 的锁死原样复活"


def test_init_does_not_treat_a_read_failure_as_first_initialization():
    """**绝不把「读失败」一律当成「首次初始化」**：权限问题、坏关系都会落到那条路上，
    然后带着一个没被证明过的前提去动 DDL。"""
    class _PresenceBoom(_InitMaint):
        async def fetchrow(self, query, *args):
            if "marker_present" in query:
                raise RuntimeError("permission denied for schema public")
            return await super().fetchrow(query, *args)

    maint = _PresenceBoom()
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker"
    assert maint.executed == [], "读失败之后仍然动了 DDL"


@pytest.mark.parametrize("dirty,code,why", [
    (lambda m: setattr(m, "databases", ["payments_prod"]),
     "unrelated_database", "集群里有生产库"),
    (lambda m: setattr(m, "databases", ["kline_pilot_stranger"]),
     "unowned_pilot_database", "同前缀但非空、来路不明"),
])
def test_init_proves_peer_databases_are_clean_before_any_ddl(dirty, code, why):
    """首次初始化时，**同侪库也要在动 DDL 之前**证明干净。"""
    maint = _InitMaint(marker_rows=[])
    maint.maintenance_presence = {k: False for k in maint.maintenance_presence}
    dirty(maint)
    stranger = _FakeConn(user_objects=[("pg_class", 3)])   # 非空
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, targets={"kline_pilot_stranger": stranger}))
    assert ei.value.code == code, why
    assert maint.executed == [], f"{why}：拒绝之前已经执行了 DDL"


def test_init_first_time_still_accepts_an_empty_prefixed_remnant():
    """反向钉：零用户对象的同前缀残骸照旧放行（别把上面那条做成「一律拒」）。"""
    maint = _InitMaint(marker_rows=[], databases=["kline_pilot_remnant"])
    maint.maintenance_presence = {k: False for k in maint.maintenance_presence}
    asyncio.run(_init(maint, targets={"kline_pilot_remnant": _FakeConn()}))
    assert len(_marker_writes(maint)) == 1


@pytest.mark.parametrize("dirty,code,why", [
    (lambda m: setattr(m, "databases", ["payments_prod"]),
     "unrelated_database", "混合态 + 集群里有生产库"),
    (lambda m: setattr(m, "databases", ["kline_pilot_stranger"]),
     "unowned_pilot_database", "混合态 + 同前缀但非空"),
])
def test_init_proves_peers_before_repair_ddl_even_when_the_marker_exists(dirty, code, why):
    """**标记在、但维护表缺席**时也要先证明同侪库。

    判据必须挂在「**这次会不会真的动 DDL**」上，不是「有没有标记」。
    """
    maint = _InitMaint(intent_table_missing=True)      # 标记在、intent 缺 → 混合态
    dirty(maint)
    stranger = _FakeConn(user_objects=[("pg_class", 3)])
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, targets={"kline_pilot_stranger": stranger}))
    assert ei.value.code == code, why
    assert maint.executed == [], f"{why}：补建 DDL 在证明之前就跑了"


def test_init_still_repairs_the_mixed_state_on_a_clean_cluster():
    """反向钉：集群本身干净时，混合态照旧被修好（别把上面那条做成「一律拒」）。"""
    maint = _InitMaint(intent_table_missing=True)      # 集群干净、只是缺表
    asyncio.run(_init(maint))
    assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
        "干净集群上的混合态没有被补建 —— O4-F7 的锁死原样复活"


@pytest.mark.parametrize("dirty,code,why", [
    (lambda m: setattr(m, "databases", ["payments_prod"]),
     "unrelated_database", "集群后来被拿去装了真实数据库"),
    (lambda m: setattr(m, "exempt_objects", [("pg_class", 9)]),
     "maintenance_db_not_empty", "维护库后来多了用户对象"),
])
def test_init_revalidates_the_cluster_even_when_the_marker_already_exists(dirty, code, why):
    """**标记只证明「有人曾声明过」，现查才证明「现在仍然成立」**（spec §4 R17-F1）。"""
    maint = _InitMaint()                       # 标记已存在且合法
    dirty(maint)
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == code, why


def test_init_repins_search_path_after_running_caller_supplied_sql():
    """`cluster_schema_sql` 是**调用方递进来的**文件；跑完必须把名字解析钉回来。"""
    # ⚠️ 必须用**真会补建**的场景：三表齐全时本函数根本不发 DDL。
    maint = _InitMaint(intent_table_missing=True)
    asyncio.run(_init(maint))
    ddl_at = next(i for i, q in enumerate(maint.ops) if "CREATE TABLE" in q.upper())
    pins_after = [i for i, q in enumerate(maint.ops)
                  if q == PIN_SEARCH_PATH_SQL and i > ddl_at]
    assert pins_after, "跑完调用方 SQL 之后没有重新钉 search_path"
    first_guard = next((i for i, q in enumerate(maint.ops)
                        if i > ddl_at and q != PIN_SEARCH_PATH_SQL), None)
    assert first_guard is None or pins_after[0] < first_guard, (
        f"重钉排在了守卫查询之后 —— 中间那条查询仍跑在调用方选定的解析下"
        f"（第一条守卫查询：{maint.ops[first_guard][:60]!r}）")


def test_repair_accepts_a_registered_nonempty_pilot_peer():
    """**混合态修复必须认同侪库的归属登记**（codex S3-R6）。

    形态：marker + registry 在场且合规，只有 intent 缺失，而集群里有一个
    **已登记的、装着真数据的**合法 pilot 库。此前一律走【绝对空】严判据 →
    这个完全正常的库被判成外来物，整台集群被锁在修复路径之外。
    """
    maint = _InitMaint(intent_table_missing=True,              # 混合态：只缺 intent
                       databases=["kline_pilot_live"],
                       registered_dbnames={"kline_pilot_live"})
    asyncio.run(_init(maint, targets={"kline_pilot_live": _registered_looking_peer()}))
    assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
        "已登记的非空 pilot 库把修复路径挡住了 —— 锁死洞原样复活"


def test_repair_still_rejects_an_unregistered_nonempty_peer():
    """**反向钉**：登记表可用**不等于**放行一切非空同前缀库。

    两个独立事实缺一不可 —— 库自己的 pilot_meta 合规（自证）**且**这个库名
    确实在维护库的登记表里（被判对象改不到）。
    """
    maint = _InitMaint(intent_table_missing=True,
                       databases=["kline_pilot_faker"],
                       registered_dbnames=set())               # **没**登记
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint,
                          targets={"kline_pilot_faker": _registered_looking_peer("faker")}))
    assert ei.value.code == "unowned_pilot_database"
    assert maint.executed == [], "拒绝之前已经执行了 DDL"


@pytest.mark.parametrize("presence_over,label", [
    ({"marker_present": False, "intent_present": False, "registry_present": False},
     "三张表都不在场（真·首次初始化）"),
    # ⚠️ **这一档是 codex S3-R7 抓到的洞**：上一版只造了「三张全不在场」，
    #    于是「标记缺失、登记表在场」这个组合**一次都没被测过**，
    #    而放宽判据当时只看 `registry_present` —— 它正好在这一档为真。
    ({"marker_present": False, "intent_present": False, "registry_present": True},
     "标记缺失但登记表在场（人工清过标记 / 部分还原 / 对手写入）"),
    ({"marker_present": False, "intent_present": True, "registry_present": True},
     "标记缺失、另两张都在场"),
])
def test_no_legal_marker_never_gets_the_registry_relaxation(presence_over, label):
    """**没有合法标记时，登记表不构成可信凭据**（codex S3-R7）。

    标记才是「这个维护库是我们的」那句话的**信任根** —— 闸 (ii) 之所以敢信登记表，
    正因为闸 (i) **先**验过标记。放宽若只看 `registry_present`，则人工清过标记、
    维护库被部分还原、或对手能写维护库时，登记行会被当成归属证明 →
    一个非空的伪 pilot 库过关 → 然后**写下一个合法标记**。
    """
    maint = _InitMaint(marker_rows=[], databases=["kline_pilot_live"],
                       registered_dbnames={"kline_pilot_live"})
    maint.maintenance_presence = {**maint.maintenance_presence, **presence_over}
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, targets={"kline_pilot_live": _registered_looking_peer()}))
    assert ei.value.code == "unowned_pilot_database", label
    assert _marker_writes(maint) == [], f"{label}：拒绝了，却已经把标记写进去了"
    assert maint.executed == [], f"{label}：拒绝之前已经执行了 DDL"


def test_both_peer_proofs_use_the_same_two_facts():
    """机械守卫：闸 (ii) 与修复路径的归属判据**必须是同一组两个事实**。"""
    import inspect
    import textwrap
    import qmt_pilot_db as m
    for fn in (m.assert_cluster_allowed, m._assert_disposable_cluster):
        # ⚠️ **判据必须剥掉注释与 docstring**（变异 M40 实测抓到，2026-08-18）：
        #    原先拿 `inspect.getsource` 的**原始文本**做子串匹配，而
        #    `_assert_disposable_cluster` 的 docstring 里正好逐字写着
        #    `_REGISTRY_HAS_SQL` —— 于是把那半个判据从**代码**里删掉（归属证明退化成
        #    「只要自称是 pilot 库就放行」），这颗钉子照样全绿。
        #    改成走 AST 的**标识符**：prose 里提到多少次都不算数。
        tree = ast.parse(textwrap.dedent(inspect.getsource(fn)))
        names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
        called = {n.func.id for n in ast.walk(tree)
                  if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        # 反向自检：一个标识符都扫不到 = 解析失效，下面三条会恒真
        assert names and called, f"{fn.__name__} 一个标识符都没扫到 —— 这颗钉子是空的"
        assert "_looks_like_our_pilot_db" in called, f"{fn.__name__} 缺自证那一半"
        assert "_REGISTRY_HAS_SQL" in names, f"{fn.__name__} 缺外部登记凭据那一半"
        assert "_is_absolutely_empty" in called, f"{fn.__name__} 缺【绝对空】那一档豁免"


@pytest.mark.parametrize("dirty,code,why", [
    (lambda m: setattr(m, "databases", ["payments_prod"]),
     "unrelated_database", "窗口里冒出一个无关库"),
    (lambda m: setattr(m, "exempt_objects", [("pg_class", 9)]),
     "maintenance_db_not_empty", "窗口里维护库多了用户对象"),
])
def test_init_does_not_leave_a_marker_when_the_final_gate_rejects(dirty, code, why):
    """**标记必须是最后一个不可回滚的信任写入**（codex S3-R4）。

    写标记之前那次现查**仍然可能拒绝** —— 预检通过之后、写标记之前的窗口里
    冒出一个同侪库、或维护库多了用户对象，都会让它抛。若标记先写，
    一次**报告失败**的 `--init-cluster-marker` 就在集群里留下了一个**合法标记**，
    而契约是**从不清标记** —— 只能人工收拾。

    ⚠️ 造法：让「预检那一刻干净、最终现查那一刻变脏」。只在构造函数里设脏是造不出
       这个窗口的（那样预检就先拒了，测不到本条判据）。
    ⚠️ 触发点用**语义**的「DDL 跑完之后」，不用调用计数：助手是先查 `_user_objects`
       再枚举 `pg_database`，两档走到的查询次序不同，按次数翻脏会让其中一档空转
       （实测踩过）。「DDL 之后」恰好就是这条判据要保护的那个窗口。
    """
    class _DirtyAfterDdl(_InitMaint):
        async def execute(self, query, *args):
            out = await super().execute(query, *args)
            if "CREATE TABLE" in query.upper():
                dirty(self)                     # 窗口打开：预检已过，标记还没写
            return out

    maint = _DirtyAfterDdl(marker_rows=[])      # 首次初始化
    maint.maintenance_presence = {k: False for k in maint.maintenance_presence}
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == code, why
    # 前置：DDL 真的跑了 → 翻脏真的发生了。否则下面那条「没写标记」是恒真的。
    assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
        "补建 DDL 没跑 → 翻脏没触发 → 这条用例在空转"
    assert _marker_writes(maint) == [], \
        f"{why}：最终现查拒绝了，却已经把标记写进去了"


def test_init_cleans_orphan_rows_only_under_the_seed_lock():
    """不持 seed 锁就删，会删掉**一次正在进行的运行**的行 → 那次运行随后判零对象例外
    第 6 条不成立 → **自己的残骸自己清不掉**（spec O4-F2 修正③）。"""
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_running",
                                                seed="running")])
    asyncio.run(_init(maint, lock_pair=_locker(maint, grants=False)))
    assert _deletes(maint) == [], "取不到 seed 锁就必须跳过，不得删"


def test_init_takes_the_lock_of_the_row_being_deleted():
    """锁必须**逐行按那一行的 seed** 取，不是随便取一把。"""
    asked = []
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    asyncio.run(_init(maint, lock_pair=_locker(maint, record=asked)))
    assert asked == ["gone"]


@pytest.mark.parametrize("row,label", [
    (_orphan(dbname="kline_pilot_stale", seed="stale",
             age_seconds=INTENT_TTL_SECONDS), "超期"),
    (_orphan(dbname="kline_pilot_gone", seed="gone"), "库已不存在"),
])
def test_init_deletes_stale_or_vanished_rows(row, label):
    """清理判据 = **超期 OR 库不存在**（spec O4-F2 修正③）。"""
    maint = _InitMaint(all_intent_rows=[row], databases=["kline_pilot_stale"])
    asyncio.run(_init(maint, targets={"kline_pilot_stale": _FakeConn()}))
    assert len(_deletes(maint)) == 1, label


def test_init_keeps_a_fresh_row_of_a_live_database():
    """**正向档**：既新鲜、库又真的存在 → 不是孤儿，不许删。

    一族全是「应该被删/被拒」的档会让「恒删」和「恒不删」两种坏实现都活下来；
    这一条是那一族的健康输入。
    """
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_live", seed="live")],
                       databases=["kline_pilot_live"])
    asyncio.run(_init(maint, targets={"kline_pilot_live": _FakeConn()}))
    assert _deletes(maint) == []


def test_orphan_prefilter_treats_a_replaced_same_name_database_as_vanished():
    """预筛必须**绑实例**：只按名字判「库还在不在」时，「原实例被删掉、别人用同名重建」
    这一档会被判成「没消失」→ 直接 continue → 锁内那条 OID-aware 的 DELETE
    **永远跑不到**，陈旧行一直赖着把建库卡到 TTL。
    """
    maint = _InitMaint(
        all_intent_rows=[_orphan(dbname="kline_pilot_reborn", seed="reborn",
                                 db_oid="16400")],           # 凭据记的是**旧**实例
        databases=["kline_pilot_reborn"])
    maint.database_oids = {"kline_pilot_reborn": "99999"}    # 同名，但已是另一个实例
    reborn = _FakeConn()
    reborn.current_db_oid = "99999"                          # 新实例自称就是 99999
    asyncio.run(_init(maint, targets={"kline_pilot_reborn": reborn}))
    assert len(_deletes(maint)) == 1, "同名替身没有被判成 vanished，OID 判据跑不到"


def test_init_does_not_clean_orphans_on_a_cluster_that_is_no_longer_clean():
    """现查不过时，**一行 intent 都不许动** —— 那是别的集群/别人的状态。"""
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")],
                       databases=["payments_prod"])
    with pytest.raises(PilotClusterBoundaryError):
        asyncio.run(_init(maint))
    assert _deletes(maint) == []


def test_orphan_cleanup_refuses_when_the_callback_lies_about_the_lock():
    """孤儿清理不许只信回调的布尔。

    `_SEED_LOCK_HELD_SQL` 在模块里有四个使用点（建库 / reset 授权 / DROP / 零对象例外），
    孤儿清理**做的是 DELETE 恢复凭据**，同样必须复核。
    而 advisory lock 在同一 session 内**可重入**：一个接错线的回调、或同连接上早已
    因别的原因持有的锁，都会返回真而**不提供任何互斥**。
    后果是删掉一次进行中/崩溃中的建库**唯一的恢复凭据** ——
    留下一个零对象例外再也授权不了的空残骸。
    """
    orphan = {"dbname": "kline_pilot_ghost", "seed": "ghost",
              "db_oid": "99999", "age_seconds": 10 ** 9}
    # 回调撒谎：`held_seeds` 始终为空（连接上并没有那把锁），而回调返回 True。
    maint = _InitMaint(all_intent_rows=[orphan])

    async def _lying_try(_seed):
        return True                            # 说取到了，实际 pg_locks 里没有

    async def _noop(_seed):
        return None

    asyncio.run(_init(maint, lock_pair=(_lying_try, _noop)))
    assert _deletes(maint) == [], "回调撒谎说持有锁，孤儿清理就把恢复凭据删了"


def test_orphan_cleanup_binds_the_delete_to_the_row_it_locked():
    """DELETE 必须按**取锁的那一行**删（codex S3-R2）。

    授权来自「本次持有的是这一行 seed 的 advisory lock」。只按 dbname 删的话，
    语句靠的是「dbname 恒为 `kline_pilot_<seed>`」这条**跨列不变量**，
    而它**没有任何数据库约束在兜** —— 孤儿清理处理的恰恰是来路不明的行
    （旧版本写的 / `pg_restore` 还原的 / 人工插的），对它们那条不变量不成立。
    """
    seen = []

    class _RecordArgs(_InitMaint):
        async def execute(self, query, *args):
            if query.strip().upper().startswith("DELETE"):
                seen.append(args)
            return await super().execute(query, *args)

    maint = _RecordArgs(all_intent_rows=[_orphan(dbname="kline_pilot_gone",
                                                 seed="gone")])
    asyncio.run(_init(maint))
    assert seen == [("kline_pilot_gone", "gone", INTENT_TTL_SECONDS)], \
        f"DELETE 的参数不是 (dbname, seed, ttl)：{seen}"


def test_orphan_cleanup_skips_a_seed_whose_lock_this_connection_already_holds():
    """**取锁之前先证明本连接还没持有它**（codex S3-R2，真 PG 15.12 实测坐实）。

    advisory lock 在同一 session 内**可重入**：实测 `pg_try_advisory_lock` 对一把
    本连接已持有的锁**照样返回 true**（计数器 1→2），而 `_SEED_LOCK_HELD_SQL`
    在调用之前**就已经是 true`** —— 于是「取到了 + 复核为真」这套证明
    对这一行**没有提供任何新的互斥**。

    危险的是**自己**这一档：本连接正在为该 seed 干别的事（4c 的 wrapper 把 init
    套进一次 create/reset、或连接池里漏回来一把锁），而这里把它**进行中的**
    恢复凭据删掉 —— 就是「不加锁会删掉一次正在进行的运行的行」换了个形态。

    ⚠️ 反向的一半由 `test_init_deletes_stale_or_vanished_rows` 兜着：
       事前**没**持有时照常清理，别把这条修成「一律跳过」。
    """
    took, freed = [], []
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")],
                       pre_held_seeds=("gone",))     # 事前就持有 → 必须 fail-closed
    asyncio.run(_init(maint, lock_pair=_locker(maint, record=took, released=freed)))
    assert _deletes(maint) == [], "本连接事前已持有该 seed 的锁，仍然删了凭据"
    assert took == [], "事前已持有就不该再去取锁（可重入只会让计数器涨上去）"
    assert freed == [], "没取过就不许还 —— 那会把别处正持有的锁释放掉"


def test_first_init_writes_no_marker_when_orphan_cleanup_fails():
    """**清理会抛，故必须排在写标记之前**（codex S3-R5）。

    这是 R4 那条修复的**续集**：R4 只把标记挪到了「首次初始化那一支的最后」，
    而 Task 4 随后在**整个函数的最后**又接了一段会抛的清理循环 ——
    首次初始化于是又能「报告失败、却留下一个合法标记」，
    而契约是「本工具从不清标记」。典型的「修 symptom 会挪动失败面」。
    """
    class _DeleteBoom(_InitMaint):
        async def execute(self, query, *args):
            if query.strip().upper().startswith("DELETE"):
                raise RuntimeError("deadlock detected")
            return await super().execute(query, *args)

    maint = _DeleteBoom(
        marker_rows=[],                                   # 首次初始化
        all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    with pytest.raises(RuntimeError):
        asyncio.run(_init(maint))
    assert _marker_writes(maint) == [], \
        "孤儿清理失败了，却已经把标记写进去了 —— 一次失败的 init 留下了合法标记"


def test_first_init_proves_the_cluster_again_immediately_before_the_marker():
    """信任写入必须由**紧挨着它**的证明背书（spec §4「DROP 前须紧贴着重查」同族）。

    授权清理的那次证明与写标记之间隔着整个清理循环 —— 取锁、DELETE、释放，
    每一步都要时间，窗口里集群可以变脏。
    """
    maint = _InitMaint(marker_rows=[],
                       all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    asyncio.run(_init(maint))
    assert len(_marker_writes(maint)) == 1

    # ⚠️ **判据是次序，不是计数**（`_FakeConn.ops` 的注释：「计数是脆弱断言 ——
    #    中间多一处合法调用就会假红；次序才是判据」）。这里要证的性质就一条：
    #    **写标记之前、清理之后，还有一次 pg_database 现查。**
    marker_at = next(i for i, q in enumerate(maint.ops)
                     if q.strip().upper().startswith("INSERT")
                     and "pilot_cluster_marker" in q)
    delete_at = max(i for i, q in enumerate(maint.ops)
                    if q.strip().upper().startswith("DELETE"))
    assert delete_at < marker_at, "清理排在了写标记之后 —— 会抛的活不许排在信任写入之后"
    assert any("datistemplate" in q for q in maint.ops[delete_at + 1:marker_at]), (
        "清理之后、写标记之前没有再现查一次 pg_database —— "
        "标记会由一次隔着整个清理循环的**陈旧**证明背书")
    # 标记必须是**最后一条**真正执行的语句：它之后不许再有任何会抛的活
    assert maint.executed[-1] == _marker_writes(maint)[0], \
        f"写标记之后还执行了别的语句：{maint.executed[maint.executed.index(_marker_writes(maint)[0]) + 1:]}"


def test_orphan_cleanup_verifies_the_release_actually_took_effect():
    """**还了也要验**（codex S3-R4）—— 与「取到了也要验」是同一条纪律。

    `release_seed_lock` 和 `try_seed_lock` 一样是**调用方递进来的回调**：空实现、
    连错连接、只释放一层可重入计数，都会「成功返回」而锁**仍挂在 `maint_conn` 上**。
    会话级锁泄漏会挡住后续同 seed 的建库/reset；更毒的是它会被
    `test_orphan_cleanup_skips_a_seed_whose_lock_this_connection_already_holds`
    那条 fail-closed 判据放大成「这条连接从此再也清不掉该 seed 的孤儿」——
    静默跳过，理由看起来还完全合理。
    """
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])

    async def _grant(seed):
        maint.held_seeds.add(seed)
        return True

    async def _noop_release(_seed):
        return None                    # 空实现：锁没还，`held_seeds` 里还留着

    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, lock_pair=(_grant, _noop_release)))
    assert ei.value.code == "seed_lock_not_released"


def test_orphan_cleanup_release_check_does_not_mask_the_original_failure():
    """`finally` 里 raise 会接替正在传播的异常，但原异常必须留在 `__context__` 里。

    否则「DELETE 失败」会被「锁没还」盖掉，排查时看到的是**第二个**症状。
    """
    maint_holder = {}

    class _DeleteBoom(_InitMaint):
        async def execute(self, query, *args):
            if query.strip().upper().startswith("DELETE"):
                raise RuntimeError("deadlock detected")
            return await super().execute(query, *args)

    maint = _DeleteBoom(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    maint_holder["m"] = maint

    async def _grant(seed):
        maint.held_seeds.add(seed)
        return True

    async def _noop_release(_seed):
        return None                    # 既没还锁，DELETE 又炸了

    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint, lock_pair=(_grant, _noop_release)))
    assert ei.value.code == "seed_lock_not_released"
    assert isinstance(ei.value.__context__, RuntimeError), \
        f"原始的 DELETE 异常没留在 __context__ 里：{ei.value.__context__!r}"


def test_orphan_cleanup_releases_every_seed_lock_it_takes():
    """**取了就必须还**：会话级锁不还会一直挂在维护连接上，挡住后续同 seed 的运行；
    同一条连接上后来的 `_SEED_LOCK_HELD_SQL` 也会观察到一把**本次从未刻意取过**的锁。"""
    taken, freed = [], []
    maint = _InitMaint(all_intent_rows=[
        _orphan(dbname="kline_pilot_gone", seed="gone"),
        _orphan(dbname="kline_pilot_stale", seed="stale",
                age_seconds=INTENT_TTL_SECONDS + 1)])
    asyncio.run(_init(maint, lock_pair=_locker(maint, record=taken, released=freed)))
    assert taken == ["gone", "stale"]
    assert freed == taken, f"取了 {taken} 却只还了 {freed}"


def test_orphan_cleanup_releases_the_lock_even_when_the_delete_fails():
    """删除抛异常时锁也必须还 —— 否则一次失败会把那个 seed 永久挡住。"""
    freed = []

    class _DeleteBoom(_InitMaint):
        async def execute(self, query, *args):
            if query.strip().upper().startswith("DELETE"):
                raise RuntimeError("deadlock detected")
            return await super().execute(query, *args)

    maint = _DeleteBoom(all_intent_rows=[_orphan(dbname="kline_pilot_gone", seed="gone")])
    with pytest.raises(RuntimeError):
        asyncio.run(_init(maint, lock_pair=_locker(maint, released=freed)))
    assert freed == ["gone"], "删除失败时锁没还"


def test_orphan_cleanup_does_not_release_a_lock_it_never_took():
    """取不到锁的那一行**不许调 release** —— 那会把别人正持有的锁还掉。"""
    freed = []
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_running",
                                                seed="running")])
    asyncio.run(_init(maint, lock_pair=_locker(maint, grants=False, released=freed)))
    assert freed == [], "取不到锁却还了锁 —— 会把别的运行持有的锁释放掉"


def test_orphan_cleanup_uses_a_delete_that_can_actually_match_an_orphan():
    """机械守卫：孤儿删除**不能复用** `_DELETE_INTENT_SQL` / `_CLEAR_INTENT_SQL`。

    前者带 `AND NOT create_confirmed`，而孤儿恰恰是**已确认**的行 → 它永远匹配 0 行；
    两者都还带 `run_id = $2`，而清理孤儿的这次运行**不是**写下那一行的那次运行。
    复用任何一条都会是「命令发了、一行没删」的静默失败 ——
    正是 R9 那次回归的形态（没人看 DELETE 匹配了几行）。
    """
    import qmt_pilot_db as m
    sql = m._DELETE_ORPHAN_INTENT_SQL
    assert "run_id" not in sql, "孤儿清理不该按 run_id 过滤"
    assert "create_confirmed" not in sql, "孤儿恰恰是已确认的行"
    assert "public.pilot_create_intent" in sql, "表引用必须 public. 限定"
    # ⚠️ 判据必须**在 SQL 里、在锁内**求值：先查后删的写法会按快照时的陈旧状态，
    #    删掉一条同 seed 运行**刚刷新过的**恢复凭据。
    assert "statement_timestamp() - inserted_at" in sql, "超期判据没有下沉进 DELETE"
    assert "pg_database" in sql and "d.oid" in sql, "「库不存在」判据没有下沉、或没绑实例"
    # ⚠️ **必须绑 seed**（codex S3-R2）：授权来自「持有这一行 seed 的锁」，
    #    语句就得按那一行删。dbname↔seed 的对应只有代码在维持，没有 DB 约束在兜。
    assert "seed = $2" in sql, "DELETE 没绑 seed —— 拿着 A 的锁能删掉 B 的凭据"
    assert (sql.count("$1") == 1 and sql.count("$2") == 1
            and sql.count("$3") == 1), "参数应为 dbname + seed + TTL 三个"


def test_init_orphan_freshness_uses_the_database_clock():
    """孤儿清理的新鲜度只认库时钟（spec O4-R23-C1），不认调用方传的 created_at。

    `created_at` 是**调用方传进来的**字符串，数据库既不生成也不校验它：
    写一个很远的过去值，一行**活着的** intent 立刻可被别人接管。
    """
    import qmt_pilot_db as m
    sql = m._LIST_ALL_INTENT_SQL
    assert "statement_timestamp() - inserted_at" in sql, "新鲜度没有用库时钟算"
    assert "created_at" not in sql
    # ⚠️ 年龄不许在 SQL 里取整：`::bigint` 是四舍五入不是截断
    #    （真 PG 15 实测 `(-0.1)::bigint = 0`），`_READ_INTENT_SQL` 已经去掉了它。
    assert "::bigint" not in sql, "年龄被取整了 —— 与 _READ_INTENT_SQL 的口径漂移"


def test_orphan_delete_predicate_is_evaluated_under_the_lock_not_from_a_snapshot():
    """机械守卫：「超期 OR 库不存在」必须**在 DELETE 的 WHERE 里**，
    且循环体里不许有内联的 DELETE 字面量（那是「按 Python 侧快照决定删不删」的形态）。

    真 PG 侧由 `verify_pilot_db_lifecycle.py` 档 ㊱ 坐实。
    """
    import ast
    import inspect
    import textwrap
    import qmt_pilot_db as m
    sql = m._DELETE_ORPHAN_INTENT_SQL
    assert "statement_timestamp() - inserted_at" in sql and "pg_database" in sql, \
        "两条判据没有下沉进 DELETE"
    src = textwrap.dedent(inspect.getsource(m.init_cluster_marker))
    tree = ast.parse(src)
    consts = [n.value for n in ast.walk(tree)
              if isinstance(n, ast.Constant) and isinstance(n.value, str)
              and "DELETE" in n.value.upper()]
    assert not consts, f"init 里有内联 DELETE 字面量：{consts}"


def test_every_test_name_cited_in_a_comment_actually_exists():
    """机械守卫：注释/docstring 里用反引号点名的测试，必须真的存在于本文件。

    抓到的形态（Kimi S3-WB-R1）：三处注释把「别名拆分的机械判别力」归给
    test_shape_fakes_cover_every_predicate —— 一个**全仓都不存在**的名字。
    判据本身在（真名是 `test_every_guard_table_shape_proof_covers_table_level_durability`），
    ⚠️ 上面那个错名**刻意不加反引号**：加了的话，这颗钉子会被自己举的例子打红 ——
       一条开局就红的守卫等于给实施者发放宽许可证。举例与判据必须分得开。
    坏的是**归属**：按图索骥的人找不到那颗钉子，而它将来被改名/删除时，
    这几处注释也没有任何东西会提醒需要同步 —— 正是本仓
    「机械检查器被它该抓的损坏禁用了自身解析器」那一族的近亲。

    ⚠️ 只管本文件内的引用：跨文件的符号（真 PG 脚本的档位、生产函数名）不在此列，
       它们各有各的守卫。
    ⚠️ 反向自检：一个引用都扫不到 = 匹配式过时了，下面那条断言会恒真。
    """
    src = pathlib.Path(__file__).read_text(encoding="utf-8")
    defined = set(re.findall(r"^def (test_\w+)", src, re.M))
    cited = set(re.findall(r"`(test_\w+)`", src))
    assert cited, "一个被反引号点名的测试都没扫到 —— 这颗钉子是空的"
    missing = sorted(cited - defined)
    assert not missing, (
        f"注释点名了本文件里并不存在的测试：{missing}。"
        f"判据可能还在、只是名字指错 —— 按图索骥的读者找不到它，"
        f"而那颗钉子被改名/删除时也没有东西会变红")


def test_orphan_cleanup_keeps_a_fresh_row_that_has_no_recorded_instance():
    """`db_oid` 为空 = **证明不了**那个库消失了，不等于「它消失了」（Kimi S3-WB-R3）。

    `_INSERT_INTENT_SQL` **不写 `db_oid`** —— 它在建库确认那一步才写。于是
    「INSERT 了 intent、`CREATE DATABASE` 成功、崩在确认之前」这个窗口
    （两阶段建库存在的全部理由）会留下一行**新鲜的、`db_oid` 为空的**行，
    而那个库**真的存在**。
    SQL 里 `d.oid = NULL` 求值为 NULL → `NOT EXISTS` **恒真** → 这类行被判成
    「库已不存在」→ 不论多新鲜都立刻删掉，与模块自己写下的
    「该行 create_confirmed=false，授权不了 DROP，**将由 INTENT_TTL 清理**」直接矛盾。
    本仓的铁律是「一切**证明不了**等价于**拒绝**」，这里的拒绝就是**不删**。
    """
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_half", seed="half",
                                                db_oid=None)],
                       databases=["kline_pilot_half"])
    asyncio.run(_init(maint, targets={"kline_pilot_half": _FakeConn()}))
    assert _deletes(maint) == [], \
        "一行新鲜的、尚未确认实例的凭据被当成「库已不存在」删掉了"


def test_orphan_cleanup_still_deletes_a_stale_row_that_has_no_recorded_instance():
    """**正向档**：上一条不许把「`db_oid` 为空」变成**永不过期**。

    超期这条判据与实例无关，`db_oid` 为空的行照样归它管 ——
    否则一条崩在确认之前的行会永久占住那个库名。
    """
    maint = _InitMaint(all_intent_rows=[_orphan(dbname="kline_pilot_old", seed="old",
                                                db_oid=None,
                                                age_seconds=INTENT_TTL_SECONDS)],
                       databases=["kline_pilot_old"])
    asyncio.run(_init(maint, targets={"kline_pilot_old": _FakeConn()}))
    assert len(_deletes(maint)) == 1, "超期的行因为 db_oid 为空而清不掉了"


def test_orphan_delete_never_treats_an_unrecorded_instance_as_vanished():
    """机械守卫：锁内那条 DELETE 必须显式排掉 `db_oid IS NULL`。

    ⚠️ 这一条**只有真库能证**（`= NULL` 的三值逻辑假件不求值），
       语义那一半由 `verify_pilot_db_lifecycle.py` 档 ㊴ 坐实；
       这里钉的是「判据写进 SQL 里了」。
    """
    import qmt_pilot_db as m
    sql = m._DELETE_ORPHAN_INTENT_SQL
    assert "db_oid IS NOT NULL" in sql, \
        "「库不存在」那一支没有排掉 db_oid 为空的行 —— NOT EXISTS 对它恒真"
    # 反向自检：排除条件必须落在**库不存在**那一支里，不是随手加在别处
    assert sql.index("db_oid IS NOT NULL") < sql.index("NOT EXISTS"), \
        "db_oid IS NOT NULL 没有排在 NOT EXISTS 之前 —— 它守不住那一支"


@pytest.mark.parametrize("guard,why", [
    ("_READ_MARKER_SQL", "1c 读标记"),
    ("_MAINTENANCE_SHAPE_SQL", "第 2 步补建之后复验结构"),
])
def test_init_turns_a_failed_guard_query_into_a_named_boundary_error(guard, why):
    """守卫查询失败必须是**具名的** boundary error（spec O1-F10；Kimi S3-WB-R3）。

    闸 (i) 对**同样这两条查询**都包了 try/except 转成 `no_marker`
    （`qmt_pilot_db.py` 闸 (i) 内逐字如此），而 `init_cluster_marker` 里
    1b 包了、1c 与建后复验没包 —— 同一个函数内部的不一致，显然是漏的不是有意的。
    裸 asyncpg 异常逃出去，4c 会把它记成 FAIL_INFRASTRUCTURE 而不是「集群不合规」。

    可达路径：marker 表在目录里看得见（1b 过得了）但维护角色缺 SELECT 权限，
    或 1b 与 1c 之间那张表被并发 DROP。方向本来就是 fail-closed（发生在任何 DDL 之前），
    坏的是**分类**。
    """
    import qmt_pilot_db as m
    marker_sql, shape_sql = m._READ_MARKER_SQL, m._MAINTENANCE_SHAPE_SQL
    target = marker_sql if guard == "_READ_MARKER_SQL" else shape_sql

    # ⚠️ **建后复验那一档必须只在 DDL 之后才抛**：`_MAINTENANCE_SHAPE_SQL` 在 1b
    #    就被读过一次，而 1b **已经**包了 try/except —— 无差别地抛会让这一档在 1b
    #    就拿到 `no_marker`，于是它**根本走不到**第 2 步，成了一条恒真的空档
    #    （实测踩到：第一版就是这样，开局即绿）。
    class _Boom(_InitMaint):
        armed = (guard == "_READ_MARKER_SQL")      # 读标记那档一开始就武装

        async def execute(self, query, *args):
            out = await super().execute(query, *args)
            if "CREATE TABLE" in query.upper():
                self.armed = True                  # 补建跑完 → 只炸建后复验那一次
            return out

        async def fetch(self, query, *args):
            if self.armed and query == target:
                raise RuntimeError("permission denied for table")
            return await super().fetch(query, *args)

        async def fetchrow(self, query, *args):
            if self.armed and query == target:
                raise RuntimeError("permission denied for table")
            return await super().fetchrow(query, *args)

    # 建后复验那一条要先走到 DDL，故用「缺 intent 表」的混合态把补建路径打开
    maint = (_Boom() if guard == "_READ_MARKER_SQL"
             else _Boom(intent_table_missing=True))
    with pytest.raises(PilotClusterBoundaryError) as ei:
        asyncio.run(_init(maint))
    assert ei.value.code == "no_marker", f"{why}：失败没有转成具名 boundary error"
    if guard == "_MAINTENANCE_SHAPE_SQL":
        # 前置：补建 DDL 真的跑了 → 抛的是**第 2 步**那一次，不是 1b 那一次
        assert any("CREATE TABLE" in q.upper() for q in maint.executed), \
            "补建 DDL 没跑 → 这一档抛在 1b（那里本来就包了），对第 2 步零判别力"
