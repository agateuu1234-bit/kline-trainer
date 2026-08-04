# backend/tests/test_qmt_pilot_db.py
"""Plan 4a 护栏 L1 单测。Spec: docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md"""
from __future__ import annotations

import asyncio
import hashlib
import pathlib
import re

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
                          read_pilot_meta_rows,
                          assert_pilot_db_allowed, create_pilot_database,
                          derive_confirm_token, derive_db_name, quote_ident)

_REPO = pathlib.Path(__file__).resolve().parents[2]


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
                 registered_dbnames=True):
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
        if "meta_is_table" in query:
            return None if self.pilot_schema_shape is None else dict(self.pilot_schema_shape)
        if "marker_is_table" in query:
            return None if self.maintenance_shape is None else dict(self.maintenance_shape)
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
        """同名库**此刻**是哪个实例。未发生替换时就是 `current_db_oid`。"""
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

    async def close(self):
        self.closed = True


# ⚠️ **两份形状字典各自只有一份权威副本**（O4-R37-C2）：此前它们在
#    `_FakeConn.__init__` 与两三个用例里各写一遍，新增判据时只改被点名的那一处 ——
#    正是本 PR 里重演到第十一次的那个形态。任何新键加进这里，
#    所有用例自动跟上；漏加会在 `test_shape_fakes_cover_every_predicate` 变红。
_OK_MAINTENANCE_SHAPE = {
    "marker_is_table": True, "marker_purpose_text": True,
    "marker_purpose_unique": True, "intent_is_table": True,
    "intent_columns_ok": True, "intent_dbname_unique": True,
    "registry_is_table": True, "registry_columns_ok": True,
    "registry_dbname_unique": True, "maintenance_tables_durable": True}

_OK_PILOT_SHAPE = {
    "meta_is_table": True, "meta_key_unique": True, "meta_columns_ok": True,
    "source_is_table": True, "source_columns_ok": True, "source_key_unique": True,
    "pilot_tables_durable": True}


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
    ("maintenance_tables_durable",
     "三张维护表被 SET UNLOGGED / 挂 RLS / 换表空间 —— 崩溃后 intent 行被 truncate，"
     "而它是零对象例外授权 DROP DATABASE 的凭据（O4-R37-C2）"),
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
