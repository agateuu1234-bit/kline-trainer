# backend/qmt_pilot_db.py
"""QMT Plan 4a：pilot 数据库护栏（纯 DB，零文件 IO，零网络）。

Spec: docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md

设计约束（逐条来自 spec §4，改动前先读 spec）：
  · 一切守卫用 if/raise，**绝不用 assert**（python -O 会剥掉它）。
  · 一切「证明不了」等价于「拒绝」——绝不 try/except: continue。
  · 本模块不做文件 IO：两份 schema 的 sha256、export_log_sha256、output_dir
    一律由调用方传入**已校验**的标量；取不到 = fail-closed，绝不跳过闸 0b。
"""
from __future__ import annotations

import hashlib
import re
import sys

# CLI 只收 --seed；库名恒为 kline_pilot_{seed}，用户无法传入任意库名。
SEED_RE = re.compile(r"[a-z0-9_]{1,32}")
PILOT_DB_NAME_RE = re.compile(r"kline_pilot_[a-z0-9_]{1,32}")

# 【维护库专用表集合】—— spec §4 的唯一权威定义。
# ⚠️ 凡涉及豁免一律引用本常量，**不得点名单张表**：同一个洞在 spec 里被打开过三次
# （P1-F4 只修索引豁免、P1r3-F1b 只修 SQL 块、O4-F1 才发现散文/§5/§9 三处从未跟上）。
MAINTENANCE_TABLES = ("pilot_cluster_marker", "pilot_create_intent",
                      "pilot_database_registry")


class PilotDbBoundaryError(Exception):
    """库级边界失败。code 进 4c 报告的 db_boundary_error 字段。"""

    def __init__(self, code: str, message: str, *,
                 identity: dict | None = None, confirm_token: str | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.identity = identity
        # ⚠️ confirm_token 只进 stderr，**绝不进报告 JSON**（spec §9-1w：
        # 否则 wrapper 可「读报告取令牌再重跑」，知情同意退化成两步自动化）。
        self.confirm_token = confirm_token


class PilotClusterBoundaryError(Exception):
    """集群级边界失败。code 进 4c 报告的 cluster_boundary_error 字段。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


# ⚠️ **每条守卫连接都必须先把 search_path 钉死**（O4-R17-C1，真 PG 15.12 实测）。
#    PostgreSQL 里 `pg_catalog` 只有在**未被显式列出**时才隐式排在最前；一旦 DSN/角色/库
#    把它显式排在某个可写 schema 之后，裸 `pg_class` 就解析到 `evil.pg_class` ——
#    实测 `SET search_path = evil, pg_catalog, public` 之后 `SELECT count(*) FROM pg_class`
#    从 425 行变成 1 行。整台集群的「除本工具外别无他物」会在**对手控制的数据**上求值。
#    钉桩要做的就是**抹掉这种显式排布**，让隐式规则重新生效。
#    这与 O4-R4-C1（`public.pilot_*` 限定）同类，只是换到了系统目录一侧。
#
#    **为什么不逐个加 `pg_catalog.` 前缀**（codex 的建议）：目录与内建函数的引用有几十处
#    （`to_regclass` / `format_type` / `hashtext` / `pg_get_expr` / 聚合 `count` …），
#    **漏掉一个是静默的**，而且以后每加一条 SQL 都要记得。`SET search_path` 是纯语法、
#    不经过名字解析、**无法被遮蔽**，一句话把后续所有解析（含函数）都钉住。
#    代价：会改动调用方连接的会话状态 —— 对守卫模块而言这正是想要的，且已在此写明。
# ⚠️ 钉成 `public` 而**不是** `pg_catalog, public`（真 PG 15.12 两次实测）：
#    · PostgreSQL 只在 `pg_catalog` **未被显式列出**时才把它隐式排在最前。
#      故 `SET search_path = public` 恰好恢复「系统目录优先」——实测：即使存在
#      `public.pg_class` 影子表，`SELECT count(*) FROM pg_class` 仍是 425 行、
#      `to_regclass('pg_class')` 仍指向真目录。
#    · 反过来把 `pg_catalog` 显式写在最前会**打断业务 DDL**：`schema.sql` 里
#      不限定的 `CREATE TABLE stocks` 会落到 pg_catalog →
#      `InsufficientPrivilegeError: permission denied to create "pg_catalog.stocks"`
#      （我第一版就是这么写的，真 PG 当场炸在场景 ①）。
#      `search_path = public` 下同一句 DDL 落在 public，实测确认。
#    · **必须显式写上 `pg_temp` 且排在末尾**（O4-R18-C1，真 PG 实测）：
#      会话的临时 schema 在**关系名与类型名**的解析上，未被显式列出时隐式排在
#      **`pg_catalog` 之前**。于是 `CREATE TEMP TABLE pg_class (...)` 就能遮蔽真目录 ——
#      实测 `search_path = public` 下 `SELECT count(*) FROM pg_class` 变成 **0 行**，
#      而 `search_path = public, pg_temp` 下恢复 **425 行**，不限定 DDL 仍落在 public。
#      这条路径不需要建 schema、不需要额外权限，任何能连上来的会话都能用。
_PIN_SEARCH_PATH_SQL = "SET search_path = public, pg_temp"


async def pin_search_path(conn) -> None:
    """把连接的 search_path 钉到 `pg_catalog, public`。守卫用到的每条连接都要过一遍。"""
    await conn.execute(_PIN_SEARCH_PATH_SQL)


async def _close_quietly(conn, label: str) -> bool:
    """关掉一条探测连接；`close()` 自身抛出**不得替换掉刚判出来的闸结论**。

    **返回是否真的关掉了** —— 调用方据此决定要不要 fail-closed（codex 4a-2a R2-F1）。

    读一律短连接：DROP 之前本进程对目标库的连接数必须为 0（spec O1-F2 规定 1）。
    ⚠️ `close()` 在 `finally` 里抛出会按 Python 的 finally 语义**顶掉**原异常，
       于是一次成功的守卫变成裸异常 → 4c 记成 `FAIL_INFRASTRUCTURE`（O4-W2r1 M-2）。
       故这里只捕获、不上抛。
    ⚠️ 但抑制**不等于可以忽略**（O4-W3 M-8 + codex R2-F1）：关不掉意味着本进程还占着
       目标库的一条会话。**发放 DROP 授权的路径必须据此 fail-closed**，
       否则随后的 `DROP DATABASE` 会撞 `is being accessed by other users`，
       而操作者拿到的诊断是「有别人连着」——实际上那个「别人」就是我们自己。
    """
    try:
        await conn.close()
    except Exception as close_exc:
        print(f"[qmt_pilot] 警告：关闭 {label!r} 的探测连接失败：{close_exc}",
              file=sys.stderr)
        return False
    return True


def _assert_target_released(closed: bool, db_name: str) -> None:
    """发放 DROP 授权之前，必须证明本模块已经放掉自己对目标库的会话（codex R2-F1）。"""
    if not closed:
        raise PilotDbBoundaryError(
            "target_db_in_use",
            f"本模块没能关掉自己对 {db_name!r} 的探测连接 —— 在这条会话还活着的时候"
            f"发放 DROP 授权，随后的 DROP 必然被它自己顶住，而报出来的会是"
            f"「有别人连着」。拒绝发放授权，请重跑。")


_CURRENT_DATABASE_SQL = "SELECT current_database()"
# 集群身份：来自服务端控制文件，DSN 改写伪造不了（真 PG 实测：两个集群取值不同）。
_CLUSTER_ID_SQL = "SELECT system_identifier::text FROM pg_control_system()"


async def cluster_identity(conn) -> str:
    """这条连接所在**集群**的身份（O4-R29-C1）。

    `pg_control_system().system_identifier` 由 `initdb` 生成、存在服务端控制文件里，
    DSN 改写 / 连接池串号伪造不了它（真 PG 实测：两个集群取值不同）。
    """
    await pin_search_path(conn)
    return await conn.fetchval(_CLUSTER_ID_SQL)


_CURRENT_DB_OID_SQL = ("SELECT d.oid::text FROM pg_database d"
                       " WHERE d.datname = pg_catalog.current_database()")


async def adopt_connection(conn, expected_db: str, *, cluster_id: str | None = None,
                           expected_oid: str | None = None) -> None:
    """接管一条**外部传进来**的连接：钉 `search_path` + 证明它连的就是 `expected_db`。

    ⚠️ **`connect(name)` 返回什么就用什么，是一条没被验过的调用方断言**（O4-R28-C1）——
    与 R5-C2 把 `seed_lock_held` 布尔换成「在活连接上真验锁」是同一条原则。
    DSN 被改写、连接池串了、包装层把名字映射错了，都会让这条连接指向**另一个库**；
    随后 `pilot_schema.sql` 与 `schema.sql` 会落到那个库上做 DDL，
    而刚建好的 pilot 库空着、却已经登记在案 —— 这台守卫存在的全部意义当场归零。

    ⚠️ 两件事**合成一个动作**是有意的（R24 的教训：分成两步写，迟早漏掉其中一处）。
    次序也不能反：先钉 `search_path`，`current_database()` 才不会被解析到别处。
    """
    await pin_search_path(conn)
    actual = await conn.fetchval(_CURRENT_DATABASE_SQL)
    if actual != expected_db:
        raise PilotDbBoundaryError(
            "connection_wrong_database",
            f"connect({expected_db!r}) 返回的连接实际连着 {actual!r} ——"
            f"DSN 改写 / 连接池串号 / 包装层映射错都会落到这里。"
            f"在它上面跑 DDL 会改到**别的库**，故立刻失败并关掉这条连接。")
    # ⚠️ **同名还不够，必须同一台集群**（O4-R29-C1）：被改错的 DSN 完全可能指向
    #    另一台 PostgreSQL 上**同名**的库 —— 名字对上了，而维护库里的 intent/登记
    #    与这条连接分属两台机器，「归属证明」与「被证明的对象」根本不在一个信任边界里。
    #    `system_identifier` 由 initdb 生成、存在服务端控制文件，伪造不了。
    if cluster_id is not None:
        actual_cluster = await conn.fetchval(_CLUSTER_ID_SQL)
        if actual_cluster != cluster_id:
            raise PilotDbBoundaryError(
                "connection_wrong_cluster",
                f"connect({expected_db!r}) 返回的连接在集群 {actual_cluster!r} 上，"
                f"而维护连接在 {cluster_id!r} —— 同名不同机。"
                f"维护库里的 intent/登记与它分属两个信任边界，任何结论都不成立。")
    # ⚠️ **同名同机还不够，必须是刚建出来的那一个实例**（O4-R35-C2）：
    #    `CREATE DATABASE` 与 `connect(db_name)` 之间存在窗口 —— 期间有人把它删掉再用同名重建，
    #    这条连接就指向一个**替身**：schema 与 ready 元数据会写到替身上，
    #    而 intent/登记里记的 `db_oid` 指着那个已经消失的实例。
    #    这与 R16-C2（登记表）/ R21-C1（intent 行）是同一条原则的第三处落点 ——
    #    **凡是「这就是我那个库」的断言，都要绑实例而不是绑名字**。
    if expected_oid is not None:
        actual_oid = await conn.fetchval(_CURRENT_DB_OID_SQL)
        if actual_oid != expected_oid:
            raise PilotDbBoundaryError(
                "connection_wrong_instance",
                f"connect({expected_db!r}) 连到的库 oid 是 {actual_oid!r}，"
                f"而调用方要的是 {expected_oid!r} —— 取得那个 oid 与连上之间，"
                f"这个名字被删掉又重建了。"
                f"名字对得上不代表是同一个实例：在替身上跑 DDL / 判归属，"
                f"结论都与调用方声称的对象无关。")


_HEX64_RE = re.compile(r"\A[0-9a-f]{64}\Z")
# ISO-8601 **basic** UTC 微秒：YYYYMMDDTHHMMSSffffffZ（spec §4 O1-F14 定义的格式）。
_CREATED_AT_RE = re.compile(r"\A\d{8}T\d{12}Z\Z")


def assert_binding_scalars(export_log_sha256, output_dir) -> None:
    """**绑定**标量（闸 0b 的两个）必须在任何副作用之前验掉。

    此前它们一路裸奔到 `values` 才被用上：`output_dir=None` 直到 `CREATE DATABASE` /
    确认 / 登记**都做完之后**才在 `.rstrip('/')` 上崩掉；空串或 `"/"` 则会被安静地
    存成一个空绑定。而这两者正是 `confirm_token` 的原像与 `--reset-foreign` 的绑定依据 ——
    存进去的是垃圾，令牌就派生不出来，库也认不回自己。

    ⚠️ **复用/销毁两条路也必须验**（codex 4a-2 R13-F1，high）：此前整套校验
       **只有建库路径调**，而 reset / 复用把调用方递进来的这两个值**原样**送进
       破坏性闸 ——
         · `output_dir=None` → `_binding_matches` 的 `.rstrip('/')` 抛**裸 AttributeError**，
           且是在集群闸与目标库连接**都做完之后**（spec §9-1w 明令禁止把一次守卫
           记成 FAIL_INFRASTRUCTURE）；
         · `output_dir=''` / `'/'` → 去尾斜杠后是空串，遇到 `output_dir` 为空的
           **畸形 pilot_meta** 就判成「绑定相符」→ 在一个不该匹配的库上放行销毁授权。
       而这条路径的下一步是不可逆的 `DROP DATABASE`。
    ⚠️ 抽成独立函数是因为 reset / 复用**拿不到 `created_at`**（它只在建库时由调用方给）。
       两处各写一份校验必然漂移 —— 本仓记录在案的毛病。
    """
    if not isinstance(export_log_sha256, str) or not _HEX64_RE.match(export_log_sha256):
        raise PilotDbBoundaryError(
            "identity_scalar_invalid",
            f"export_log_sha256 必须是 64 位小写十六进制，实得 {export_log_sha256!r}")
    if not isinstance(output_dir, str):
        raise PilotDbBoundaryError(
            "identity_scalar_invalid", f"output_dir 必须是字符串，实得 {type(output_dir).__name__}")
    if not output_dir.startswith("/") or not output_dir.rstrip("/"):
        raise PilotDbBoundaryError(
            "identity_scalar_invalid",
            f"output_dir 必须是**绝对路径**且去掉尾斜杠后非空，实得 {output_dir!r}——"
            f"空绑定会让 confirm_token 派生不出来、库认不回自己")


def assert_identity_scalars(export_log_sha256, output_dir, created_at) -> None:
    """建库路径的三个**身份/绑定**标量（绑定两个 + `created_at`）。

    绑定那两个复用 `assert_binding_scalars` —— 复用/销毁路径也要验它们，
    而那两条路拿不到 `created_at`。
    """
    assert_binding_scalars(export_log_sha256, output_dir)
    if not isinstance(created_at, str) or not _CREATED_AT_RE.match(created_at):
        raise PilotDbBoundaryError(
            "identity_scalar_invalid",
            f"created_at 必须是 ISO-8601 basic UTC 微秒（YYYYMMDDTHHMMSSffffffZ），"
            f"实得 {created_at!r}")


def sha256_of_sql(sql: str) -> str:
    """一份 .sql 文本的规范指纹。写进 `pilot_meta` 的与这里算出来的必须逐字相等。"""
    return hashlib.sha256(sql.encode("utf-8")).hexdigest()


# ⚠️ **schema 限定必须单独解析**（真 PG 场景 ⑲ 撞出来的）：前一版只剥 `public.`，
#    于是 `CREATE TABLE zz_evil.pg_class (...)` 会把**schema 名** `zz_evil` 当成表名，
#    守卫随后去找一张 `public.zz_evil` → 假的 `schema_tables_missing`，
#    任何在非 public schema 建表的合法 schema.sql 都会被误拒。
_CREATE_TABLE_RE = re.compile(
    r"\ACREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"
    r"(?:\"?([A-Za-z_]\w*)\"?\s*\.\s*)?\"?([A-Za-z_]\w*)\"?",
    re.IGNORECASE)


def declared_tables(sql: str) -> list[str]:
    """这份 .sql **声明要建**的表名（O4-R19-C1）。

    ⚠️ 必须走 `_sql_statements` 再匹配，不能对整份文本裸正则：
    注释掉的 `CREATE TABLE`、字符串/dollar-quoted 块里的同名字都会被算进来，
    于是守卫要求一张**本就不该存在**的表 —— 一个自己造出来的假失败。
    """
    out = []
    for st in _sql_statements(sql):
        m = _CREATE_TABLE_RE.match(st)
        if not m:
            continue
        schema, table = m.group(1), m.group(2)
        # 存在性核实是 `public.` 范围的；建在别的 schema 里的表不归它管，跳过。
        # （不限定 = 落在 public —— 钉桩把 search_path 定成了 `public, pg_temp`。）
        if schema is not None and schema.lower() != "public":
            continue
        out.append(table)
    return out


def _tables_exist_sql(names: list[str]) -> str:
    """逐张表判「存在且是普通表」。名字来自本仓的 .sql 文件，仍走参数化以免拼接。"""
    return ("SELECT count(*) FROM unnest($1::text[]) t(name)"
            " WHERE EXISTS (SELECT 1 FROM pg_class c"
            "                WHERE c.oid = to_regclass('public.' || quote_ident(t.name))"
            "                  AND c.relkind = 'r')")


def quote_ident(name: str) -> str:
    """把标识符包成双引号形式（asyncpg 无 psycopg.sql.Identifier 的等价物）。

    ⚠️ 这**不是**护栏：调用方必须已经让 name 过了 assert_pilot_db_allowed。
    """
    return '"' + name.replace('"', '""') + '"'


def derive_db_name(seed: str) -> str:
    if not isinstance(seed, str) or SEED_RE.fullmatch(seed) is None:
        raise PilotDbBoundaryError(
            "illegal_seed",
            f"--seed 必须匹配 ^[a-z0-9_]{{1,32}}$，实得 {seed!r}",
        )
    return f"kline_pilot_{seed}"


def assert_pilot_db_allowed(db_name: str, *, reset: bool, destructive: bool) -> None:
    """任何 DDL 之前调用。

    db_name 不匹配 ^kline_pilot_[a-z0-9_]{1,32}$ → raise；
    destructive（DROP DATABASE）而 reset 非 True → raise。

    ⚠️ 用 re.fullmatch 而不是 re.match + '$'：后者接受尾随换行，会让
    「闸判定的库」与「DDL 实际作用的库」不是同一个（spec O1-F11）。
    """
    if not isinstance(db_name, str) or PILOT_DB_NAME_RE.fullmatch(db_name) is None:
        raise PilotDbBoundaryError(
            "illegal_db_name",
            f"库名必须匹配 ^kline_pilot_[a-z0-9_]{{1,32}}$，实得 {db_name!r}",
        )
    if destructive and reset is not True:
        raise PilotDbBoundaryError(
            "destructive_without_reset",
            f"对 {db_name} 的破坏性动作需要 --reset；本次未带",
        )


# ── 【绝对空】的唯一判据（O4-R2-C1 重写；本 spec 唯一一条**无归属证明、无令牌**的
#    `DROP DATABASE` 授权就建立在它上面）────────────────────────────────────
#
# ⚠️ 前一版是**六条硬编码目录查询**（pg_class / pg_namespace / pg_proc / pg_type /
#    pg_extension / pg_largeobject_metadata）。codex 指出并经真 PG 复现：
#    **一个只含 `CREATE COLLATION public.mycoll` 的库，六条全返回 0** → 被判「绝对空」
#    → 可被无凭据 DROP。同样逃过的还有 pg_conversion / 文本搜索对象 / publication /
#    operator / opclass / cast / 外部数据包装器…… **枚举式判据每出一种新对象类型就漏一次**，
#    而 spec 自己写着这条判据必须是白名单式。
#
# 现判据是**结构性**的，不再枚举：PostgreSQL 把 initdb 期建的对象分配 oid < 16384，
# **用户后来建的一切都 >= 16384**。故：
#     「本库任一非共享系统目录里存在 oid >= 16384 的行」⟺「有用户对象」
# 目录清单**从 pg_catalog 现查**（不写死），故 PG 加新目录时自动覆盖。
FIRST_NORMAL_OID = 16384

# ⚠️ **oid 阈值对这些目录不成立**（O4-R3-C1，codex 指出并经真 PG 复现）：
#    `lo_create(oid)` / `lo_import(path, oid)` / `lo_from_bytea` 允许**调用方自选 OID**，
#    实测 `SELECT lo_create(100)` 造出 oid=100 的大对象 → 全局阈值看不见它 →
#    一个装着用户数据的库被判「绝对空」→ 可被无归属证明、无令牌地 DROP DATABASE。
#    这类目录里 **initdb 一个对象都不建**，故**任何行都算用户对象**，不设阈值。
#    （判据依据：PG 文档的大对象函数族是唯一允许调用方指定 OID 的公开 API；
#      真 PG 回归钉断言「刚建的库该目录为 0 行」，使「任何行 = 用户对象」成立。）
_CALLER_ASSIGNED_OID_CATALOGS = frozenset({"pg_largeobject_metadata"})

# ⚠️ 会话临时 schema **不算用户对象**（O4-R18 附带，由真 PG 跑出来的）：
#    任何会话在库里建过一次临时表，PostgreSQL 就会留下 `pg_temp_N` /
#    `pg_toast_temp_N` 两条 `pg_namespace` 行 —— 它们的 oid ≥ 16384，
#    **会话结束后仍然留着**。不豁免的话，一个 DBA 用 psql 连进维护库随手
#    `CREATE TEMP TABLE` 就会让闸 (iii) 永久不过，**工具彻底不可用**
#    （本脚本的场景 ⑮ 自己就把维护库弄成了这样，实测）。
#    按名字豁免在这里是安全的：PostgreSQL **保留 `pg_` 前缀**，
#    `CREATE SCHEMA pg_temp_evil` 报 `unacceptable schema name`（实测），
#    故用户造不出能混进来的名字。
#    ⚠️ 只豁免 **namespace 本身**：临时 schema 里**活着的**表仍在 `pg_class` 里
#    被看见并计入 —— 那确实说明有人在用这个库（实测：`live_temp @ pg_temp_3`）。
_TEMP_NAMESPACE_EXCLUSION = {
    "pg_namespace": (" AND x.nspname NOT LIKE 'pg_temp\\_%'"
                     " AND x.nspname NOT LIKE 'pg_toast_temp\\_%'"),
}

# 本库自己的、带 oid 列的系统目录（`relisshared` 排掉 pg_database/pg_authid 这类集群级共享目录）。
_USER_OBJECT_CATALOGS_SQL = """
SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'pg_catalog' AND c.relkind = 'r' AND NOT c.relisshared
   AND EXISTS (SELECT 1 FROM pg_attribute a
                WHERE a.attrelid = c.oid AND a.attname = 'oid' AND NOT a.attisdropped)
 ORDER BY c.relname
"""

# 闸 (iii) 专用：把【维护库专用表集合】及其**全部派生物**（pkey 约束/索引、复合类型、
# 数组类型、TOAST 表及其索引……）从判据里豁免。
# ⚠️ 必须是 `pg_depend` 的**递归闭包**——一层 join 只能豁免直接依赖，实测会漏掉
#    pkey 索引（它依赖的是 pg_constraint，不是表）与 TOAST 表。
_MAINTENANCE_CLOSURE_CTE = """
WITH roots(oid) AS (
  SELECT o::oid FROM unnest(ARRAY[{members}]) o WHERE o IS NOT NULL
), toasts(oid) AS (
  SELECT c.reltoastrelid FROM pg_class c JOIN roots r ON c.oid = r.oid
   WHERE c.reltoastrelid <> 0
), closure(catalog, oid) AS (
  -- ⚠️ **白名单式：只列举这两张表「合法应有」的派生物**（O4-R5-C1）。
  --    前一版用 `pg_depend` 的递归闭包（哪怕限定 deptype ∈ INTERNAL/AUTO）都**过头**：
  --    真 PG 实测，用户自己 `CREATE INDEX` / `CREATE RULE` 出来的东西 PostgreSQL 同样
  --    标成 AUTO（它们随表一起被删），于是被一并豁免 —— 维护库里带着它们也判「干净」。
  --    （我第一次验这条时因为反例对象**累积没清理**，把上一步的继承子表当成了
  --      「索引被抓到」，得出了假阳性结论；每个反例必须单独造、单独清。）
  -- ⚠️ **必须带上目录名配对**（O4-R6-C2，codex 指出、真 PG 复现）：
  --    此前是裸 oid 比较，而**不同目录的 oid 可以相同** —— 加上 `lo_create(oid)`
  --    允许调用方自选 OID，可以蓄意造一个 oid 恰等于被豁免表的大对象，
  --    于是它被跨目录撞号**藏住**，维护库装着用户数据也判「干净」。
  --    配对之后，`pg_largeobject_metadata` 天然永远不在豁免集里。
  SELECT 'pg_class', oid FROM roots                          -- 两张表自身
  UNION SELECT 'pg_class', oid FROM toasts                   -- 它们的 TOAST 表
  UNION SELECT 'pg_type', c.reltype FROM pg_class c         -- 表与 TOAST 的复合类型
                JOIN (SELECT oid FROM roots UNION SELECT oid FROM toasts) a ON c.oid = a.oid
  UNION SELECT 'pg_type', t.typarray FROM pg_type t         -- 复合类型的数组类型
                JOIN pg_class c ON t.oid = c.reltype
                JOIN (SELECT oid FROM roots UNION SELECT oid FROM toasts) a ON c.oid = a.oid
                WHERE t.typarray <> 0
  UNION SELECT 'pg_constraint', k.oid FROM pg_constraint k   -- **仅主键**约束
                JOIN roots r ON k.conrelid = r.oid WHERE k.contype = 'p'
  UNION SELECT 'pg_class', i.indexrelid FROM pg_index i      -- **仅主键背后的**索引
                JOIN roots r ON i.indrelid = r.oid
               WHERE EXISTS (SELECT 1 FROM pg_constraint k
                              WHERE k.conindid = i.indexrelid AND k.contype = 'p')
  UNION SELECT 'pg_class', i.indexrelid FROM pg_index i      -- TOAST 的索引
                JOIN toasts t ON i.indrelid = t.oid
  -- 规范 schema 声明的**那一个** DEFAULT（create_confirmed 的 `false`）。
  -- ⚠️ 只按表豁免是不够的：`ALTER COLUMN create_confirmed SET DEFAULT true`
  --    恰恰是最有价值的敌意改动 —— 它让新 intent 行天生「已确认」，
  --    把 O4-R8-C2 那道持久证明整个掏空。故把**表达式文本**一起钉死
  --    （真 PG 实测 pg_get_expr 对 `DEFAULT false` 返回 'false'、改成 true 后返回 'true'）。
  UNION SELECT 'pg_attrdef', d.oid FROM pg_attrdef d
                JOIN roots r ON d.adrelid = r.oid
                JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
               WHERE (a.attname = 'create_confirmed'
                      AND pg_get_expr(d.adbin, d.adrelid) = 'false')
                  -- ⚠️ `inserted_at` 的默认值同样按文本钉死（O4-R23-C1）：
                  --    把它改成一个很旧的时间，每行新写的 intent 会**立刻过期**、
                  --    随时可被别人接管 —— 而这一行是 DROP 授权。
                  OR (a.attname = 'inserted_at'
                      AND pg_get_expr(d.adbin, d.adrelid) = 'now()')
)
"""


def _maintenance_closure_cte(tables: tuple[str, ...]) -> str:
    """由【维护库专用表集合】派生闸 (iii) 的豁免 CTE（成员从常量来，不手写字面量）。"""
    members = ", ".join(f"to_regclass('public.{t}')" for t in tables)
    return _MAINTENANCE_CLOSURE_CTE.format(members=members)


async def _user_objects(conn, *, exempt_maintenance: bool = False) -> list[tuple[str, int]]:
    """本库里的用户对象，按系统目录分组。**空列表 ⟺ 【绝对空】**。

    `exempt_maintenance=True` 时豁免【维护库专用表集合】及其派生物（闸 (iii) 专用；
    闸 (ii) 的残骸豁免与零对象例外第 3 条用**无豁免**的裸判据）。

    ⚠️ **查不出目录清单 → 抛异常**，绝不返回「空」：证明不了「空」等价于「非空」。
    """
    cats = [r["relname"] for r in await conn.fetch(_USER_OBJECT_CATALOGS_SQL)]
    if not cats:
        raise RuntimeError("查不出 pg_catalog 的目录清单 —— 无法证明该库为空")
    filt_tpl = (" AND NOT EXISTS (SELECT 1 FROM closure cl"
                " WHERE cl.catalog = '{cat}' AND cl.oid = x.oid)") if exempt_maintenance else ""
    parts = []
    for c in cats:
        # 允许调用方自选 OID 的目录不设阈值（见 _CALLER_ASSIGNED_OID_CATALOGS）
        cond = "TRUE" if c in _CALLER_ASSIGNED_OID_CATALOGS else f"x.oid >= {FIRST_NORMAL_OID}"
        parts.append(f"SELECT '{c}' AS cat, count(*) AS n FROM pg_catalog.\"{c}\" x"
                     f" WHERE {cond}{_TEMP_NAMESPACE_EXCLUSION.get(c, '')}"
                     f"{filt_tpl.format(cat=c)}")
    union = " UNION ALL ".join(parts)
    cte = _maintenance_closure_cte(MAINTENANCE_TABLES) if exempt_maintenance else ""
    rows = await conn.fetch(f"{cte}SELECT cat, n FROM ({union}) s WHERE n > 0 ORDER BY cat")
    return [(r["cat"], r["n"]) for r in rows]


# 【维护库专用表集合】两张表的**结构**判据（O4-R8-C1）。
# ⚠️ 此前闸 (i) 的注释写着「先验形状再读值」，而代码**只读了值** —— 又一次
#    「注释声称的保证 > 代码实际提供的保证」。一张伪造的 pilot_cluster_marker
#    （没有主键、或根本不是表）塞进一行 magic string，就能把整台集群授权为「一次性可弃」。
#    而 pilot_create_intent 的结构从来没被验过，它却是 DROP 授权的载体。
# ⚠️ 「唯一」一律要求**主键约束**，不认裸的 unique index（O4-R23-C2，真 PG 实测）：
#    `CREATE UNIQUE INDEX ... WHERE false` 满足 `indisunique` + 单列 `indkey`，
#    却**对任何行都不生效** —— 实测同一个 stock_code 连插两行成功。
#    partial / invalid / not-ready / 表达式索引都能这样骗过 `indisunique`。
#    本仓这五张表的那一列全是 `PRIMARY KEY` 声明的，故直接要求 `pg_constraint.contype='p'`
#    且是单列主键 —— 判据比「挑出所有需要排除的索引形态」更短也更严。
#    （五处一起改：R21 的教训是「同一条修法只落在先被指出的那个对象上」。）
def _durable_tables_sql(qualified: tuple, alias: str) -> str:
    """生成「这几张表是**普通的、持久的、没被改过存储属性**的表」的表级证明（O4-R37-C2）。

    ⚠️ 为什么是**生成**的而不是两处各写一遍：本 PR 里「同一条判据只落在被点名的那一处」
    已经重演到第十一次。上一轮（R35-C1）刚把 `pg_class` 整行纳入**业务表**指纹、
    并写下「按被保护的性质枚举」，却没有回头问一句「**还有哪些表**要同样的保护」——
    于是 `pilot_meta` / `pilot_stock_source` / marker / intent / registry 五张表
    仍可被 `ALTER TABLE … SET UNLOGGED` 掏空：列、主键、依赖物判据**全部照旧为真**，
    库照样被标 `ready`，而 PostgreSQL 崩溃之后 unlogged 表会被 **truncate** ——
    归属元数据、来源代次基线、以及**授权 DROP DATABASE 的 intent 行**一起消失。
    共用一个生成器，是让「两处判据长得不一样」这件事在结构上不可发生。

    覆盖的性质（与 R35 业务表指纹取的是同一族表级属性）：
      · `relkind='r'` 普通表          · `relpersistence='p'` 崩溃后不被 truncate
      · 未启用/未强制 RLS             · 不是分区子表
      · 无 reloptions（fillfactor / autovacuum 覆写等）
      · 默认表空间（换到易失挂载上等于把耐久性交给别人）

    ⚠️ **不含** `read_pilot_meta_rows` 的 `_PILOT_META_SHAPE_SQL`（刻意，不是漏）：
    那条判据读的是**别的库**的归属自证，本次运行并不依赖那个库的耐久性；
    在那里加耐久性要求会让「一台崩溃过的同侪库」把集群闸整个顶死
    （R55-F1 那个锁死的换形态）。此处记下理由，免得下一轮把它当成同族遗漏。
    """
    arr = ",\n                           ".join(
        "to_regclass('%s')" % q for q in qualified)
    return ("  (SELECT count(*) FROM pg_class c\n"
            "    WHERE c.oid = ANY (ARRAY[%s])\n"
            "      AND c.relkind = 'r' AND c.relpersistence = 'p'\n"
            "      AND NOT c.relrowsecurity AND NOT c.relforcerowsecurity\n"
            "      AND NOT c.relispartition\n"
            "      AND c.reloptions IS NULL AND c.reltablespace = 0) = %d\n"
            "                                                     AS %s"
            % (arr, len(qualified), alias))


_MAINTENANCE_SHAPE_SQL = """
SELECT
  EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = to_regclass('public.pilot_cluster_marker')
                                     AND c.relkind = 'r')                       AS marker_is_table,
  EXISTS (SELECT 1 FROM pg_attribute a
           WHERE a.attrelid = to_regclass('public.pilot_cluster_marker')
             AND a.attname = 'purpose' AND NOT a.attisdropped
             AND format_type(a.atttypid, NULL) = 'text')                        AS marker_purpose_text,
  EXISTS (SELECT 1 FROM pg_constraint k
           JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
          WHERE k.conrelid = to_regclass('public.pilot_cluster_marker')
            AND k.contype = 'p' AND array_length(k.conkey, 1) = 1
            AND a.attname = 'purpose')                  AS marker_purpose_unique,
  EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = to_regclass('public.pilot_create_intent')
                                     AND c.relkind = 'r')                       AS intent_is_table,
  (SELECT count(*) FROM pg_attribute a
    WHERE a.attrelid = to_regclass('public.pilot_create_intent') AND NOT a.attisdropped
      AND a.attnum > 0
      AND ((a.attname IN ('dbname','seed','created_at','run_id')
            AND format_type(a.atttypid, NULL) = 'text' )
        OR (a.attname = 'create_confirmed'
            AND format_type(a.atttypid, NULL) = 'boolean')
        OR (a.attname = 'db_oid'
            AND format_type(a.atttypid, NULL) = 'oid')
        OR (a.attname = 'inserted_at'
            AND format_type(a.atttypid, NULL) = 'timestamp with time zone'
            AND a.attnotnull))) = 7                                             AS intent_columns_ok,
  EXISTS (SELECT 1 FROM pg_constraint k
           JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
          WHERE k.conrelid = to_regclass('public.pilot_create_intent')
            AND k.contype = 'p' AND array_length(k.conkey, 1) = 1
            AND a.attname = 'dbname')                   AS intent_dbname_unique,
  EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = to_regclass('public.pilot_database_registry')
                                     AND c.relkind = 'r')                       AS registry_is_table,
  (SELECT count(*) FROM pg_attribute a
    WHERE a.attrelid = to_regclass('public.pilot_database_registry') AND NOT a.attisdropped
      AND a.attnum > 0
      AND ((a.attname IN ('dbname','seed','run_id','claimed_at')
            AND format_type(a.atttypid, NULL) = 'text')
        OR (a.attname = 'db_oid' AND format_type(a.atttypid, NULL) = 'oid'))) = 5
                                                                                AS registry_columns_ok,
  EXISTS (SELECT 1 FROM pg_constraint k
           JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
          WHERE k.conrelid = to_regclass('public.pilot_database_registry')
            AND k.contype = 'p' AND array_length(k.conkey, 1) = 1
            AND a.attname = 'dbname')                   AS registry_dbname_unique,
""" + _durable_tables_sql(("public.pilot_cluster_marker",
                            "public.pilot_create_intent",
                            "public.pilot_database_registry"),
                           "maintenance_tables_durable")

MARKER_PURPOSE = "qmt_pilot_disposable_cluster"

# 系统库判据用 datistemplate，**不用名字 glob**：一个叫 `templates` 的**生产库**
# 会被 `template*` 跳过（spec O1-F3）。顺带解掉「维护 DSN 必须连 postgres」这个隐性约束。
_LIST_DATABASES_SQL = """
SELECT datname, oid::text AS db_oid FROM pg_database
 WHERE datistemplate = false AND datname <> current_database()
"""

# ⚠️ **所有表引用必须 schema 限定**（O4-R4-C1，codex 指出、真 PG 复现）：
#    结构判据用 `to_regclass('public.pilot_meta')` 验的是 public 那张，而不带 schema 的
#    `SELECT … FROM pilot_meta` 由 `search_path` 决定读哪张。实测 `SET search_path = evil, public`
#    时**验的是 public、读的是 evil** —— 一个完全不属于本工具的库，凭 evil schema 里
#    **一行**伪造的 `tool='qmt_pilot'` 就冒充归属成功，集群边界当场失效。
#    限定 schema 比「连接上 SET search_path」更稳：它不依赖调用方的连接怎么建。
_READ_MARKER_SQL = "SELECT purpose FROM public.pilot_cluster_marker ORDER BY purpose"

_READ_META_SQL = "SELECT key, value FROM public.pilot_meta ORDER BY key"


# 闸 0− 的**结构性**形状判据（O4-R2-C2）：`key` 为 text 且有主键或等价唯一约束、
# `value` 为 text。运行时的「重复 key 检测」抓不到这一层——一张**没有唯一约束**、
# 里面只塞了一行 `tool='qmt_pilot'` 的伪造表，读起来毫无异常。
_PILOT_META_SHAPE_SQL = """
SELECT
  EXISTS (SELECT 1 FROM pg_attribute a
           WHERE a.attrelid = to_regclass('public.pilot_meta') AND a.attname = 'key'
             AND NOT a.attisdropped AND format_type(a.atttypid, NULL) = 'text') AS key_is_text,
  EXISTS (SELECT 1 FROM pg_attribute a
           WHERE a.attrelid = to_regclass('public.pilot_meta') AND a.attname = 'value'
             AND NOT a.attisdropped AND format_type(a.atttypid, NULL) = 'text'
             -- ⚠️ NOT NULL 是**结构性纵深**（codex 4a-2a R5-F2）：闸 0− 里那条运行时判据
             --    只看「读出来的值是不是字符串」，这一条从一开始就不让 NULL 存在。
             --    `_PILOT_SCHEMA_SHAPE_SQL` 的 meta_columns_ok 早就这么要求了 ——
             --    同一张表的两份形状证明此前对 NOT NULL 说法不一致。
             AND a.attnotnull)                                                  AS value_is_text,
  EXISTS (SELECT 1 FROM pg_constraint k
           JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
          WHERE k.conrelid = to_regclass('public.pilot_meta')
            AND k.contype = 'p' AND array_length(k.conkey, 1) = 1
            AND a.attname = 'key')                                              AS key_is_unique
"""


async def read_pilot_meta_rows(conn) -> dict[str, str]:
    """读 `pilot_meta` 并**强制形状**：任一 key 出现多行即拒。

    这是「闸 0− 的形状判据」的**唯一实现**，闸 (ii)（验别的 pilot 库）与
    闸 0−（验目标库）**必须共用它**——spec §4 P1-F7 明写：marker 的「不得 LIMIT 1」
    纪律与闸 0− 此前「都只落在了各自发现它的那个对象上」。

    **两层判据缺一不可**：
    ①**结构性**（`_PILOT_META_SHAPE_SQL`）：`key` 为 text 且有主键或等价唯一约束、
      `value` 为 text。**这一层此前缺失**（O4-R2-C2，codex 判 high）——一张**没有唯一约束**、
      里面只塞了一行 `tool='qmt_pilot'` 的伪造表读起来毫无异常，于是一个来路不明的
      `kline_pilot_*` 库能冒充「本工具建的」，在任何 `CREATE`/`DROP`/导入之前就削弱集群边界。
    ②**运行时**：真读到重复 key 就拒（tie-break 不确定 → 同一台集群这次判干净、下次不干净）。

    ⚠️ 这两条都属于**闸 0−，不是闸 2**（spec §9-3c）：**闸 2 在 `--reset` 时不跑**，
    而 `--reset` 的破坏性恰恰建立在这张表上（R80-F1）。推给闸 2 就是把它修掉的洞放回来。

    表不存在等读失败**原样抛出**，由调用方按各自语义处置
    （闸 (ii)：落到「零用户对象即残骸」那档豁免；闸 0−：判 `not_owned`）。
    """
    await pin_search_path(conn)
    shape = await conn.fetchrow(_PILOT_META_SHAPE_SQL)
    if shape is None or not all(shape.values()):
        raise PilotDbBoundaryError(
            "pilot_meta_ambiguous",
            f"pilot_meta 的结构不合规（{dict(shape) if shape else 'None'}）——"
            f"要求 key 为 text 且有主键或等价唯一约束、value 为 text。"
            f"没有唯一约束时，读到哪一行取决于实现，这张表就不能承载归属证明",
        )
    seen: dict[str, str] = {}
    for r in await conn.fetch(_READ_META_SQL):
        key = r["key"]
        if key in seen:
            raise PilotDbBoundaryError(
                "pilot_meta_ambiguous",
                f"pilot_meta 里 {key!r} 出现多行——key 上缺唯一约束，"
                f"读到哪一行取决于实现",
            )
        seen[key] = r["value"]
    return seen


async def _is_absolutely_empty(conn) -> bool:
    """裸【绝对空】：本库不含任何 oid >= 16384 的目录行。**无任何豁免。**"""
    return not await _user_objects(conn)


async def assert_cluster_allowed(maint_conn, *, connect, target_db: str | None) -> None:
    """集群闸 (i)(ii)(iii) —— **每次运行都跑**，在任何 CREATE/DROP DATABASE/导入之前。

    (i)   维护库有合法 pilot_cluster_marker（先验形状再读值）
    (ii)  现查 pg_database 每一个非系统库**且非本次目标库**：名字不匹配 kline_pilot_* 即拒；
          匹配的逐个连进去验归属；零用户对象的同名库是残骸 → 放行
    (iii) 现查维护库自身，除【维护库专用表集合】外绝对空

    ⚠️ (ii) 必须**每次现查**，不能只在初始化时查一次（spec R17-F1，典型 TOCTOU）：
       标记只证明「有人曾声明过」，现查才证明「现在仍然成立」。

    raises:
      · `PilotClusterBoundaryError`（code ∈ no_marker / unrelated_database /
        unowned_pilot_database / maintenance_db_not_empty）
      · **`PilotDbBoundaryError("illegal_db_name")`** —— `target_db` 自身不合法时（O4-W2r1 补）。
        ⚠️ **4c 的接线必须同时捕获这两个异常类**：只 `except PilotClusterBoundaryError`
        会让 `illegal_db_name` 裸逃 → 被兜成 `FAIL_INFRASTRUCTURE`，
        而那是「把一次成功的守卫记成环境故障」（4c §9 明令禁止）。
        `illegal_db_name` 已在 4c 的 `db_boundary_error` 枚举里，能表达。
    """
    await pin_search_path(maint_conn)
    # 维护连接所在集群的身份 —— 闸 (ii) 逐个连进去的同侪库必须与它同机（O4-R29-C1）。
    _gate_cluster_id = await cluster_identity(maint_conn)
    # ⚠️ `target_db` 会让闸 (ii) **整个跳过**那个名字的库，故它自己必须先过名字护栏
    #    （O4-W3）：传进来的若是一个生产库的名字，闸 (ii) 就不会枚举到它 →
    #    三条闸全过 → 工具在生产集群上建库灌数据（spec §1 的风险 ①）。
    #    `--init-cluster-marker` 路径没有目标库，显式传 None。
    if target_db is not None:
        assert_pilot_db_allowed(target_db, reset=False, destructive=False)

    # ── (i) 标记存在且形状合规 ────────────────────────────────────────
    # 先验形状再读值（spec R21-F3：一个能授权删东西的结构，自己必须先被校验）。
    # ⚠️ 不得实现成 SELECT purpose FROM pilot_cluster_marker LIMIT 1（无 ORDER BY，
    #    返回行任意）——两行时它与 EXISTS(… WHERE purpose='…') 给出相反结论。
    # 先验**两张表的结构**，再读值（O4-R8-C1）——它们一起构成「碰这台集群」的凭据。
    try:
        shape = await maint_conn.fetchrow(_MAINTENANCE_SHAPE_SQL)
    except Exception as exc:
        raise PilotClusterBoundaryError(
            "no_marker", f"维护库读不出【维护库专用表集合】的结构：{exc}") from exc
    if shape is None or not all(shape.values()):
        raise PilotClusterBoundaryError(
            "no_marker",
            f"【维护库专用表集合】结构不合规（{dict(shape) if shape else 'None'}）——"
            f"要求 pilot_cluster_marker 是表、purpose 为 text 且唯一；"
            f"pilot_create_intent 是表、七列齐全（含 db_oid / inserted_at）且 dbname 有主键；"
            f"pilot_database_registry 是表、五列齐全（含 db_oid）且 dbname 唯一；"
            f"且三张表都是**持久**普通表（非 UNLOGGED、无 RLS、无 reloptions、默认表空间）"
            f"——UNLOGGED 的 intent 行会在崩溃后被 truncate，"
            f"而它是零对象例外授权 DROP DATABASE 的凭据。"
            f"请跑 qmt_pilot --init-cluster-marker --maintenance-dsn …",
        )
    try:
        rows = await maint_conn.fetch(_READ_MARKER_SQL)
    except Exception as exc:                      # 表不存在 / 无权限 / 连接问题
        raise PilotClusterBoundaryError(
            "no_marker",
            f"维护库读不出 pilot_cluster_marker：{exc}。"
            f"请先跑 qmt_pilot --init-cluster-marker --maintenance-dsn …",
        ) from exc
    if len(rows) != 1 or rows[0]["purpose"] != MARKER_PURPOSE:
        raise PilotClusterBoundaryError(
            "no_marker",
            f"pilot_cluster_marker 必须恰好一行且 purpose = {MARKER_PURPOSE!r}，"
            f"实得 {len(rows)} 行：{[r['purpose'] for r in rows]}",
        )

    # ── (ii) 现查 pg_database ─────────────────────────────────────────
    for row in await maint_conn.fetch(_LIST_DATABASES_SQL):
        name = row["datname"]
        if name == target_db:
            # 目标库由闸 0−/0/0b 全权负责（spec P1r3-F4）。
            continue
        if PILOT_DB_NAME_RE.fullmatch(name) is None:
            raise PilotClusterBoundaryError(
                "unrelated_database",
                f"集群里存在无关数据库 {name!r}——这台集群不是给 pilot 用的一次性环境",
            )
        # 前缀名不是归属证明：逐个连进去问它自己是谁（spec R22-F1）。
        # ⚠️ 连不进去 = 无法证明归属 = 拒绝。绝不 try/except: continue（fail-open）。
        try:
            other = await connect(name)
        except Exception as exc:
            raise PilotClusterBoundaryError(
                "unowned_pilot_database",
                f"连不进 {name!r}（{exc}）→ 无法证明它的归属。"
                f"datallowconn=false / datconnlimit=0 / 无 CONNECT 权限都会落到这里",
            ) from exc
        try:
            # ⚠️ 钉桩挪进了这个带 finally 的块里（O4-R24-C2）：放在外面时它一旦抛异常，
            #    `other` 已经连上却永远关不掉 —— 泄漏的会话会把之后的 DROP 顶住。
            # ⚠️ 同时证明它连的就是 `name` **那个实例**（O4-R28-C1 + 同族第六处落点）：
            #    判到另一个库、或判到同名替身头上，结论都与它声称的对象无关（详见 spec R36）。
            await adopt_connection(other, name, cluster_id=_gate_cluster_id,
                                   expected_oid=row["db_oid"])
            # ⚠️ **必须复用闸 0− 的同一组形状判据**（spec §4 P1-F7）：
            #    裸 `{r["key"]: r["value"] for r in rows}` 在重复 key 时**静默取最后一行**，
            #    于是一个 `key` 上没有唯一约束、塞进两行 `tool` 的库，
            #    哪一行「赢」取决于 PG 对同 ORDER BY 值的 tie-break → **同一台集群这次判干净、
            #    下次判不干净**。spec 明写这条纪律此前「只落在了各自发现它的那个对象上」。
            try:
                meta = await read_pilot_meta_rows(other)
            except Exception:
                # 表不存在 / 形状不合规（重复 key）→ **都不算合法归属证明**。
                # 不在这里拒绝：下面还有「零用户对象即残骸」这一档豁免（spec §4）。
                meta = {}
            # ⚠️ **`tool == 'qmt_pilot'` 一条不构成归属证明**（O4-R13-C1）：
            #    一个形状合规的 pilot_meta 里塞进**单独一行** ('tool','qmt_pilot')
            #    就能让任意一个非空库被当成「本工具建的」而跳过 ——
            #    静态且可猜的标记把整台集群的「除本工具外别无他物」判据掏空。
            #    三条判据一起才算数：
            #      ① 键集合**覆盖阶段 1 的全部 7 键**（崩溃残骸也满足，不会误伤）；
            #      ② `seed` 与库名后缀**逐字相等** —— 从别处抄来的标记过不了这一关；
            #      ③ `state` 是本工具会写出的两个值之一。
            #    ⚠️ 不用「9 键齐全」：那会把 state='initializing' 的合法崩溃残骸判成外来物，
            #      整台集群对所有 seed 被挡住 —— 正是 R55-F1 那个锁死换形态复发。
            #    ⚠️ 但**自证再严也还是自证**（O4-R14-C1）：上面三条判据读的全是
            #    「被判对象自己写的字」，对手把它们照抄一遍即可。故还要求一个
            #    **它改不到**的事实：这个库名在维护库的 pilot_database_registry 里
            #    确实被本工具声明过。两个独立事实同时成立才放行。
            #    （诚实说明：持维护库写权限的对手仍能自己插行 —— 集群本地的凭据都防不住
            #      这一档。它挡的是偶然撞形，以及能建库但写不了维护库的对手。）
            if _looks_like_our_pilot_db(meta, name) and await maint_conn.fetchval(
                    _REGISTRY_HAS_SQL, name, meta.get("seed")):
                continue                          # 是本工具建的另一个 pilot 库，放行
            # 无合法 pilot_meta：零用户对象的是残骸（放行），非空的一律拒。
            if await _is_absolutely_empty(other):
                continue
            raise PilotClusterBoundaryError(
                "unowned_pilot_database",
                f"{name!r} 名字匹配 kline_pilot_* 但没有合法 pilot_meta 且非空"
                f"——前缀名不是归属证明",
            )
        except PilotClusterBoundaryError:
            raise                                   # 本闸自己的判定，原样上抛
        except Exception as exc:
            # ⚠️ spec §4 O1-F10 写的是「**任一**导致『连进去验归属』抛异常时 →
            #    unowned_pilot_database」。此前只包了 connect()，而 _is_absolutely_empty
            #    或 fetchval 抛（该库被并发 DROP、连接 reset）会逃成裸 asyncpg 异常
            #    → 4c 记成 FAIL_INFRASTRUCTURE，而 §9-1w 明令禁止
            #    （把一次成功的守卫记成环境故障）。
            raise PilotClusterBoundaryError(
                "unowned_pilot_database",
                f"验 {name!r} 的归属时失败（{exc}）→ 无法证明它的归属",
            ) from exc
        finally:
            # 读一律短连接 + close 失败不顶掉闸结论（判据与理由见 `_close_quietly`）。
            # ⚠️ 与 4a-2 的库级闸**共用同一份实现**：同一条判据在两处各写一遍，
            #    正是本 PR 记录在案的「只修被点名的那一处」——故此处是调用不是内联。
            await _close_quietly(other, name)

    # ── (iii) 维护库自身也是【绝对空】（除【维护库专用表集合】外）────────
    # spec §4：维护库除【维护库专用表集合】及其派生物外必须【绝对空】。
    leftover = await _user_objects(maint_conn, exempt_maintenance=True)
    if leftover:
        raise PilotClusterBoundaryError(
            "maintenance_db_not_empty",
            f"维护库除 {MAINTENANCE_TABLES} 外还有用户对象 {leftover}"
            f"——「没有别的数据库」不等于「这台集群没在用」",
        )


# 与 ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift 的 CONTRACT_VERSION
# 逐字相等。两边必须同时改（test_contract_version_matches_swift_source_of_truth 是这条的钉）。
CONTRACT_VERSION = "1.13"

# pilot_meta 的九个键，顺序固定。
# created_at **不参与放行判定，但参与令牌派生**（spec O1-F14）。
PILOT_META_KEYS = (
    "tool", "seed", "schema_sha256", "pilot_schema_sha256", "contract_version",
    "export_log_sha256", "output_dir", "created_at", "state",
)

# ⚠️ **两阶段各写哪些键，由 spec §4「建库必须分两阶段」逐字规定，不得合并**（O4-T2-I1）：
#    阶段 1（apply pilot_schema.sql 之后、apply schema.sql 之前）只写这 7 个；
#    `schema_sha256` / `contract_version` **留到阶段 2**、与 `state='ready'` 同一次提交。
#    这不是风格问题：spec §5 的 `db_state_initializing` 那一档（O4-F8）的**论证前提**
#    逐字就是「阶段 1 只写 7 个键、schema_sha256/contract_version 尚未写入」——
#    一次写完九个会让那条修复的前提失真，也让「崩在 schema.sql 之前」的残骸
#    带着一份**完整且相符**的指纹，与「跑完了的库」在指纹维度上不可区分。
PILOT_META_PHASE1_KEYS = (
    "tool", "seed", "export_log_sha256", "output_dir", "created_at",
    "pilot_schema_sha256", "state",
)
PILOT_META_PHASE2_KEYS = ("schema_sha256", "contract_version")

# 本工具会写出的 state 取值（闸 (ii) 的归属判据之一，O4-R13-C1）。
PILOT_STATES = ("initializing", "ready")


def _looks_like_our_pilot_db(meta: dict, db_name: str) -> bool:
    """这个 `kline_pilot_*` 库的 pilot_meta 是否**真的**是本工具写的（O4-R13-C1）。

    判据见闸 (ii) 处的注释。返回 False 不代表「拒绝」——调用方还有
    「零用户对象即残骸」那一档豁免。
    """
    if not set(PILOT_META_PHASE1_KEYS) <= set(meta):
        return False
    if meta.get("tool") != "qmt_pilot":
        return False
    if meta.get("state") not in PILOT_STATES:
        return False
    # 库名恒为 kline_pilot_<seed>（闸 0 保证），故后缀就是 seed。
    prefix = "kline_pilot_"
    return db_name.startswith(prefix) and meta.get("seed") == db_name[len(prefix):]

# 闸 0− 的四个**授权键**：闸 0/0b 读到的值算不算数，由它们决定。
# 不含 created_at —— 故绑定不符而 created_at 缺失时派生不出令牌，须提示人工删库。
PILOT_META_AUTHORIZATION_KEYS = ("tool", "seed", "export_log_sha256", "output_dir")

# 孤儿 intent 行的新鲜度界（spec O4-F2）。
INTENT_TTL_SECONDS = 24 * 3600

# `CREATE DATABASE` 的**确定性**失败：这些 SQLSTATE 意味着**库肯定没被本次建出来**
# （O4-R7-C1）。此时必须删掉本次的 intent 行 —— 否则它会变成一张
# 「这是我的崩溃残骸」的凭据，而本次其实什么都没造：
# 集群闸**跳过目标库**（那是闸 0−/0/0b 的职责），所以「目标库本就存在」这一档能走到这里；
# 于是别人建的一个同名空库，事后会被零对象例外第 6 条当成本次残骸，
# **无 pilot_meta 归属、无 --reset-foreign 令牌**地 DROP 掉。
#
# ⚠️ 反过来，**歧义失败一律保留** intent 行（连接丢失时库可能已经建出来了）——
#    那时它是「清理我自己残骸」的唯一授权。宁可多留（有 TTL 兜底），不可错删。
_CREATE_DEFINITELY_FAILED_SQLSTATES = frozenset({
    "42P04",   # duplicate_database —— 库本来就在，不是本次建的
    "42501",   # insufficient_privilege —— 角色没有 CREATEDB
    "3D000",   # invalid_catalog_name —— 模板库不存在
    "53300",   # too_many_connections
    "22023",   # invalid_parameter_value
})

# 按 seed 的 advisory lock 是否**真的**被本连接持有（O4-R5-C2）。
# 键派生与 spec §4 的 `pg_try_advisory_lock(hashtext('kline_pilot_' || <seed>))` 一致。
# ⚠️ 本模块**不取锁**（spec O1-F4：只接受已持锁的连接），但**验它是否真被持有** ——
#    此前信的是调用方传进来的一个布尔值，那是可伪造的。
_SEED_LOCK_HELD_SQL = """
SELECT EXISTS (
  SELECT 1 FROM pg_locks l
   WHERE l.locktype = 'advisory' AND l.pid = pg_backend_pid() AND l.granted
     -- ⚠️ **必须限定精确形状**（O4-R6-C1，codex 指出、真 PG 复现）：
     --    `objsubid = 1` 是单参数 `pg_advisory_lock(bigint)` 的命名空间；
     --    两参数形式 `pg_advisory_lock(int,int)` 的 objsubid 是 **2**，
     --    实测它能拼出同样的 classid/objid 从而**冒充通过**。
     --    `mode = 'ExclusiveLock'` —— 共享锁（`pg_advisory_lock_shared`）**不提供互斥**，
     --    实测同样能冒充通过；而这把锁的全部意义就是「同 seed 只许一个运行」。
     AND l.objsubid = 1 AND l.mode = 'ExclusiveLock'
     AND ((l.classid::bigint << 32) | l.objid::bigint)
         = (hashtext('kline_pilot_' || $1))::bigint
)
"""


# ── 一份 .sql 的**事务归属**判定（O4-W2r1 重写）──────────────────────
# ⚠️ 前一版用 `^\s*(BEGIN|COMMIT|…)` 判「**含**事务关键字」，两个方向都错（实测 4/7）：
#   · `DO $$ BEGIN … END $$;`、`CREATE FUNCTION … AS $$ BEGIN … END; $$`、
#     `COMMENT ON … IS $doc$ BEGIN; $doc$` → 判 True，而它们是 **PL/pgSQL 块关键字或字符串**，
#     不是事务控制。**这是 fail-open**：`schema.sql` 日后去掉顶层事务但含任一 DO 块，
#     守卫会放行 → 整份文件裸执行，而代码这一侧并没有包裹它 → **配对关系断了**。
#     ⚠️ 注意不是「裸执行就会逐条 autocommit」——那句已被真 PG 证伪（O4-W4）：
#     asyncpg 的 execute(多语句串) 走 simple query 协议，PG 当**一个隐式事务块**。
#     守卫钉的是「代码不包裹」与「文件自带事务」的配对，故相对真实风险偏严（有意）。
#   · `/* apply */ BEGIN;` → 判 False，真有事务却认不出来 → 误砖 + 错误信息误导。
# 现判据是「**整份被一个事务包住**」——那才是代码真正依赖的性质。
_TXN_START_RE = re.compile(r"\A(BEGIN|START\s+TRANSACTION)\b", re.IGNORECASE)
# ⚠️ `ROLLBACK TO SAVEPOINT s1` 是**事务内**动作，不是收尾（O4-W4 M-4）：误判会让一份
#    合法且被包住的 schema 被拒，而错误信息说「必须首条 BEGIN / 末条 COMMIT」而文件恰恰满足。
# ⚠️ `ABORT` 是 PostgreSQL 的 ROLLBACK 别名、`PREPARE TRANSACTION` 会把事务**交出去**，
#    两者都终止当前事务（O4-R10-C2，codex 亲验：
#    `BEGIN; DDL; ABORT; CREATE TABLE naked(); COMMIT;` 此前判 wrapped=True —— 中间那条
#    裸 DDL 在任何事务之外，且前面的 DDL 已被 ABORT 丢掉，整份文件毫无原子性可言）。
#    识别集合漏掉它们时，`_transaction_statements` 只数到一对，「恰好一对」的判据就成了 fail-open。
#    ⚠️ 必须是 `PREPARE TRANSACTION` 而不是裸 `PREPARE` —— 后者是预备语句，与事务无关。
_TXN_END_RE = re.compile(
    r"\A(COMMIT|END|ABORT|PREPARE\s+TRANSACTION|ROLLBACK(?!\s+TO\b))\b", re.IGNORECASE)
# ⚠️ 合法**收尾**只认 COMMIT/END —— `ROLLBACK` 也是事务控制语句（故进 _TXN_END_RE 用于
#    识别），但一份以 ROLLBACK 收尾的 schema 会让整份 DDL 被回滚，而 create_pilot_database
#    随后照常写指纹两键 + state='ready' → 产出一个「ready」却一张业务表都没有的 pilot 库。
# ⚠️ 收尾必须是**精确形式**，`AND CHAIN` / `PREPARED` 一律拒（O4-R4-C2）：
#    `COMMIT AND CHAIN` 提交完会**立刻开一个新事务**，于是 schema DDL 已落地、
#    连接上却留着未闭合的事务 —— 阶段 2 随后失败时，`CREATE DATABASE` 与阶段 1
#    都已产生副作用，留下一个半初始化的 pilot 库，而守卫本该在任何副作用**之前**拦下。
_TXN_COMMIT_RE = re.compile(
    r"\A(COMMIT|END)(\s+(WORK|TRANSACTION))?\Z", re.IGNORECASE)


def _sql_statements(sql: str) -> list[str]:
    """按 `;` 切出顶层语句，**跳过注释 / 字符串 / dollar-quoted 块内部的一切**。

    ⚠️ **必须是单遍词法扫描，不能用「先正则剥这个、再正则剥那个」**（O4-C1，codex 复现）：
    前一版先剥 dollar-quoted 再剥注释，于是**注释里出现两个 `$$`** 就会把它们之间的
    整段真 SQL 一起丢掉。codex 构造出的反例里，守卫判 True 放行，而 PostgreSQL 看到的是
    「一个事务 + 一条裸 DDL + 一个以 ROLLBACK 收尾的事务」——建库流程随后照常写
    `state='ready'`，产出一个**「ready」却缺表**的库。
    而本仓的中文注释里提到「`DO $$ … $$` 块」是很自然的写法（本文件自己就有），
    所以这不是理论风险。

    ⚠️ **覆盖面必须照 PostgreSQL 文档逐条枚举，不能想到一个补一个**（O4-R10-C1 之后第三次）：
    此前 docstring 里列的支持形式**漏掉了双引号标识符**——列表本身就是不全的，
    而没人拿它跟 PG 的词法清单对过。codex 由此构造出

        BEGIN; CREATE TABLE "$x$" (); ROLLBACK; CREATE TABLE naked (); BEGIN; CREATE TABLE "$x$2" (); COMMIT;

    标识符里的 `$x$` 被当成 dollar-quoted 开头，把中间的 ROLLBACK + 裸 DDL + 第二个 BEGIN
    整段吞掉，只剩「BEGIN / 一条 DDL / COMMIT」的完美形状 → 判 True 放行。

    **`;` 能藏身的词法环境（PostgreSQL 手册 §4.1，本函数逐条覆盖）**：
      1. `--` 行注释
      2. `/* … */` 块注释（PG 允许嵌套）
      3. `'…'` 字符串常量（`''` 转义）
      4. `E'…'` 转义字符串常量（反斜杠转义 —— `E'\''` 里那个引号不闭合串）
      5. `U&'…'` Unicode 字符串常量（词法同 3）
      6. `B'…'` / `X'…'` 位串常量（词法同 3）
      7. `$tag$…$tag$` dollar-quoted 块
      8. `"…"` 引号标识符（`""` 转义）
      9. `U&"…"` Unicode 标识符（词法同 8）
    5/6/9 无需单独分支：前缀是普通标识符字符，随后的 `'` 或 `"` 各自落到 3/8 的分支。
    UTF-8 BOM 在入口剥掉。

    **已知近似（fail-closed 方向，如实登记）**：判 dollar-quote 起点用的是「前一个字符不是
    标识符字符」。PostgreSQL 里 `$1` 是**位置参数**，其后的 `$abc$` 对 PG 而言在 token 边界上
    （真 PG 对 `$1$abc$1$` 报 unterminated，正说明它在 `$abc$` 处开了块），而本函数因为前一个
    字符是 `1` 而不开块。差异只发生在含位置参数的 SQL 上 —— 而 `$1` 只在预备语句里合法，
    schema 文件里不会出现；且方向是**多切出语句 → 更容易判「没被包住」**，即 fail-closed。
    """
    src = sql.lstrip("\ufeff")
    out, buf, i, n = [], [], 0, len(src)
    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):                    # 行注释
            j = src.find("\n", i)
            i = n if j < 0 else j + 1
            buf.append(" ")
        elif c == "/" and src.startswith("/*", i):                  # 块注释（可嵌套）
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth += 1; i += 2
                elif src.startswith("*/", i):
                    depth -= 1; i += 2
                else:
                    i += 1
            buf.append(" ")
        elif c == "'":                                              # 单/转义/位串常量
            # `E'…'`（前一个非空白字符是独立的 E/e）里反斜杠会转义引号。
            k = i - 1
            while k >= 0 and src[k].isspace():
                k -= 1
            escaped = (k >= 0 and src[k] in "Ee"
                       and (k == 0 or not (src[k - 1].isalnum() or src[k - 1] == "_")))
            i += 1
            while i < n:
                if escaped and src[i] == "\\":
                    i += 2
                elif src[i] == "'" and src.startswith("''", i):
                    i += 2
                elif src[i] == "'":
                    i += 1; break
                else:
                    i += 1
            buf.append(" ")
        elif c == '"':                                              # 引号标识符（含 U&"…"）
            # ⚠️ 原样保留（含两侧引号）：标识符是语句文本的一部分，
            #    且保留引号能确保它**不会**被 _TXN_START_RE / _TXN_END_RE 从行首匹配上。
            buf.append(c); i += 1
            while i < n:
                if src[i] == '"' and src.startswith('""', i):
                    buf.append('""'); i += 2
                elif src[i] == '"':
                    buf.append('"'); i += 1; break
                else:
                    buf.append(src[i]); i += 1
        elif (c == "$"
              # ⚠️ **必须在 token 边界上**（O4-R12-C1，真 PG 15.12 实测）：PostgreSQL 允许
              #    `$` 出现在无引号标识符里，`CREATE TABLE a$x$ ()` 建出来的表名字面就是 `a$x$`；
              #    反过来 `DO$$ … $$` 在 PG 里是**语法错**（它把 `DO$$` 整个当标识符）。
              #    不看边界时，`BEGIN; CREATE TABLE a$x$ (); ROLLBACK; …; CREATE TABLE b$x$ (); COMMIT;`
              #    会被吞成 `['BEGIN','CREATE TABLE a ()','COMMIT']` → 判「被包住」放行。
              and not (i > 0 and (src[i - 1].isalnum() or src[i - 1] in "_$"))
              # ⚠️ tag 须**符合无引号标识符规则**（首字符是字母或下划线，不能是数字）：
              #    真 PG 对 `$1$abc$1$` 报 unterminated —— `$1` 是位置参数不是 tag；
              #    而 `$标签$abc$标签$` 合法，故用 Unicode 感知的 `[^\W\d]`。
              and (m := re.match(r"\$([^\W\d]\w*)?\$", src[i:]))):   # dollar-quoted
            tag = m.group(0)
            end = src.find(tag, i + len(tag))
            i = n if end < 0 else end + len(tag)
            buf.append(" ")
        elif c == ";":
            out.append(" ".join("".join(buf).split())); buf = []; i += 1
        else:
            buf.append(c); i += 1
    tail = " ".join("".join(buf).split())
    if tail:
        out.append(tail)
    return [x for x in out if x]


def _transaction_statements(sql: str) -> list[str]:
    """这份 .sql 里**顶层的**事务控制语句（不含 PL/pgSQL 块与字符串里的同名字）。"""
    return [st for st in _sql_statements(sql)
            if _TXN_START_RE.match(st) or _TXN_END_RE.match(st)]


def _is_wrapped_in_transaction(sql: str) -> bool:
    """整份 .sql 是否被**一个**事务从头包到尾。

    「含 BEGIN」不等于「被包住」：`CREATE TABLE early (); BEGIN; … COMMIT;` 里
    第一条 DDL 实际在事务外；`BEGIN;` 有而 `COMMIT;` 被删同样不算。

    ⚠️ **判据必须穷尽，不能只看首尾**（O4-W3 实测）：前一版只查 `stmts[0]` 与 `stmts[-1]`，于是

        BEGIN; CREATE TABLE a (); COMMIT;
        CREATE TABLE naked ();          -- ← 在任何事务之外
        BEGIN; CREATE TABLE b (); COMMIT;

    判 True 放行 —— 中间那条裸 DDL 各自 autocommit，整份文件失去原子性而无任何信号
    （**fail-open**，与它本要防的缺陷同类同向）。信息本来就在手里：
    `_transaction_statements()` 对它返回 `['BEGIN','COMMIT','BEGIN','COMMIT']`。
    现判据与 pilot 侧对称：**恰好一对**事务控制语句，且它们就是首尾两条。
    """
    stmts = _sql_statements(sql)
    if len(stmts) < 3:
        return False
    txn = _transaction_statements(sql)
    if len(txn) != 2:                      # 多于一对 → 中间必有裸语句；少于一对 → 没包住
        return False
    return (bool(_TXN_START_RE.match(stmts[0]))
            and bool(_TXN_COMMIT_RE.match(stmts[-1])))   # 收尾只认 COMMIT/END，不认 ROLLBACK


def derive_confirm_token(export_log_sha256: str, output_dir: str, created_at: str) -> str:
    """--reset-foreign 的确认令牌。

    preimage 逐字定义（spec O1-F14）：
      <export_log_sha256 全 64 位>|<output_dir 不带尾斜杠>|<created_at ISO-8601 basic UTC 微秒>

    ⚠️ 令牌**由目标库自身的身份派生**：脚本里写死的令牌对不上另一个库，
       只有真读过本次打印结果的人才可能填对。裸 --reset-foreign 只证明
       「命令行里有这个词」，不证明操作者看过那个即将被销毁的库是哪一个（spec R34-F1）。
    """
    if not export_log_sha256 or not output_dir or not created_at:
        raise PilotDbBoundaryError(
            "confirm_token_underivable",
            "该库的 pilot_meta 缺少派生确认令牌所需的键"
            "（export_log_sha256 / output_dir / created_at）"
            "——请在 pilot 工具之外人工确认并删除该库",
        )
    preimage = f"{export_log_sha256}|{output_dir.rstrip('/')}|{created_at}"
    return hashlib.sha256(preimage.encode()).hexdigest()[:12]


# ⚠️ **只有在「同一 run_id 重入」或「既有行已超 TTL」时才允许接管**（O4-C2）：
#    裸 `DO UPDATE` 会让任何一次运行覆盖掉别人的 intent 行 —— 而那一行是零对象例外
#    第 6 条据以**授权 DROP DATABASE** 的凭据。冲突且对方新鲜 → RETURNING 为空 → fail-closed。
# 闸 (ii) 的外部凭据（O4-R14-C1）：本工具**声明过**这个库名，且 seed 相符。
# 判据是「登记行存在**且它绑的就是现在这个同名库实例**」（O4-R16-C2）：
# JOIN 上 pg_database.oid 之后，「我们建过这个名字、库被删了、别人用同名重建」
# 这一档会因 OID 不同而落空 —— 陈旧的名字凭据不再为新实例背书。
_REGISTRY_HAS_SQL = ("SELECT EXISTS (SELECT 1 FROM public.pilot_database_registry r"
                     " JOIN pg_database d ON d.oid = r.db_oid AND d.datname = r.dbname"
                     " WHERE r.dbname = $1 AND r.seed = $2)")
# ⚠️ **写在 `CREATE DATABASE` 成功之后**（O4-R15-C1 纠正 R14 的写法）。
#    R14 把它写在建库之前，理由是「否则建成了但没登记会锁死」——**那个前提不成立**：
#    唯一的窗口（建库成功 → 登记之间）留下的库必然是**空的**（TEMPLATE template0），
#    而闸 (ii) 早有「零用户对象即残骸」豁免，不会挡住任何东西（已实测）。
#    写在之前的代价却是真的：集群闸**跳过目标库**，所以「目标库是别人的、本就存在」
#    这一档能一路走到 `CREATE DATABASE`；此时登记行已经落库，随后 42P04 失败只撤 intent，
#    **登记行永久留下** —— 一次失败的建库就把一个外来库从「拒」变成了「信」，
#    正是这张表被引入来防的那件事。
#    ⚠️ 这已是同一族错误第三次（R9→R10 的 create_confirmed、R14→R15 的登记行）：
#      **凭据必须在它所证明的事实成立之后才写**。
#    ON CONFLICT DO NOTHING：--reset 重建同名库时首次登记为准（记的是「本工具建过这个库名」）。
# `DO UPDATE` 而不是 `DO NOTHING`（O4-R16-C2）：`--reset` 会把同名库删掉重建，
# 新实例的 OID 与旧行里记的不同。不改写的话，本工具**自己刚建的库**会被自己的
# 闸 (ii) 判成外来物。只在建库确实成功之后才执行，故改写是安全的。
_REGISTER_DB_SQL = ("INSERT INTO public.pilot_database_registry"
                    " (dbname, seed, run_id, claimed_at, db_oid)"
                    # ⚠️ `d.datname` 是 `name` 类型而插入列是 `text`，$1 同时喂给两边会让 PG 推不出
                    #    参数类型（真 PG 报 AmbiguousParameterError；host 假件不执行 SQL，永远看不见）。
                    # ⚠️ **按 $5（本次刚建出来那个实例的 oid）取行，不是按名字**（O4-R36-C1）。
                    #    只按名字取：建库成功之后、登记之前，它被删掉又同名重建，
                    #    这句就把**替身**的 oid 登记成「本工具建过的库」——
                    #    而这张表本工具**从不清**，一个外来库从此永久通过闸 (ii) 的外部凭据。
                    #    取不到行 → 一行都不插 → 下面的读后验落空 → registry_not_written（fail-closed）。
                    " SELECT $1, $2, $3, $4, d.oid FROM pg_database d"
                    "  WHERE d.datname::text = $1 AND d.oid::text = $5"
                    " ON CONFLICT (dbname) DO UPDATE"
                    "    SET seed = EXCLUDED.seed, run_id = EXCLUDED.run_id,"
                    "        claimed_at = EXCLUDED.claimed_at, db_oid = EXCLUDED.db_oid")

_INSERT_INTENT_SQL = """
INSERT INTO public.pilot_create_intent (dbname, seed, created_at, run_id, create_confirmed)
VALUES ($1, $2, $3, $4, false)
ON CONFLICT (dbname) DO UPDATE
   SET seed = EXCLUDED.seed, created_at = EXCLUDED.created_at, run_id = EXCLUDED.run_id,
       -- ⚠️ **确认位的去留只看一件事：它指的那个库现在还在不在**（O4-R18-C3，
       --    取代 R9-C1 的「只有同 run_id 才保住」）。
       --    R9-C1 的规则在**过期抢占**这一档会抹掉恢复凭据：上一次运行建出了库、
       --    确认过、崩在写 pilot_meta 之前；过了 TTL 之后另一次运行（新 run_id）来抢占，
       --    确认位被打回 false → 紧接着的 CREATE 撞 duplicate_database →
       --    确定性失败清理（`AND NOT create_confirmed`）把行删掉 ——
       --    空残骸从此没有任何销毁授权，与 R9-C1 要修的是同一个洞，只是换了触发路径。
       --    改成按「库是否还存在」判：
       --      · **同一个实例**还在（`pg_database.oid` 与当初记下的相等）→ 确认仍然成立
       --        （不论是不是同一次运行建的）→ 保住，残骸清得掉；
       --      · 实例没了、或同名但已是**另一个**实例（被删过又重建）→ 那句确认已无所指
       --        → 归零，不给后来同名的库背书（O4-R21-C1：只按名字判时，
       --        陈旧的确认位会被抢占那一步**刷新**到一个全新的、不是我们建的库上）。
       --    这条比 R9-C1 更贴语义，也顺带收窄了「陈旧确认为别人的同名空库背书」。
       create_confirmed = (public.pilot_create_intent.create_confirmed
                           AND EXISTS (SELECT 1 FROM pg_database d
                                        WHERE d.datname::text = EXCLUDED.dbname
                                          AND d.oid = public.pilot_create_intent.db_oid)),
       -- 确认位被判掉时，绑定也一并清掉，免得留下一个指向已消失实例的 oid
       inserted_at = now(),
       db_oid = (CASE WHEN EXISTS (SELECT 1 FROM pg_database d
                                    WHERE d.datname::text = EXCLUDED.dbname
                                      AND d.oid = public.pilot_create_intent.db_oid)
                      THEN public.pilot_create_intent.db_oid ELSE NULL END)
 WHERE public.pilot_create_intent.run_id = EXCLUDED.run_id
    -- ⚠️ **新鲜度只看 `inserted_at`，不看 `created_at`**（O4-R23-C1）：
    --    `created_at` 是**调用方传进来的**字符串，数据库既不生成也不校验它 ——
    --    很远的未来值让这行永远「新鲜」、永远抢不走；很远的过去值让一行**活着的**
    --    intent 立刻可被别人接管。而这一行是 DROP 授权，有效期不能由调用方说了算。
    --    `inserted_at` 由库自己的 `now()` 写入，抢占时一并刷新。
    -- ⚠️ **比较用 `statement_timestamp()` 而不是 `now()`**（codex S2a-R4-F2，真 PG 15 实测）：
    --    `now()` 是**事务开始时刻**。维护连接处在长事务里时它冻在过去，
    --    一行真实已过期的凭据会被量成「还新鲜」。读侧那条（`_READ_INTENT_SQL`）
    --    的后果是**放行一次本该过期的销毁授权**，这里的后果是**该抢的抢不走**；
    --    两处判的是同一条 TTL 语义，故用**同一个**时钟源，不留漂移。
    -- ⚠️ 写入 `inserted_at` 仍用 `now()`：列的 DEFAULT 就是 `now()`（4a-1 的结构闸钉着），
    --    两边必须一致；而长事务里写 `now()` 只会让行显得更老、更早过期 —— 保守方向。
    --    （这一改顺带干掉了 R18 那段 `to_timestamp(created_at, 'YYYYMMDD"T"HH24MISSUS')`
    --     解析：本工具写的 ISO-8601 basic 格式 PostgreSQL 隐式转换认不了，
    --     曾因 `OR` 短路而**从未被真正求值过**。判据换源之后那条路径不复存在。）
    OR EXTRACT(EPOCH FROM (statement_timestamp() - public.pilot_create_intent.inserted_at)) >= $5
RETURNING run_id
"""

# ⚠️ 必须按 run_id 条件删，否则会删掉**别人**那条（O4-C2）。
# ⚠️ `AND NOT create_confirmed`（O4-R9-C1）：只撤回**本次刚声明、尚未确认**的行。
#    已确认的行意味着库真的被本次建出来过 —— 它是清理残骸的唯一凭据，撤回它等于
#    把自己锁在门外。谓词写在 SQL 里而不是先查后删，避免中间态。
_DELETE_INTENT_SQL = ("DELETE FROM public.pilot_create_intent"
                      " WHERE dbname = $1 AND run_id = $2 AND NOT create_confirmed")
# 干净收尾用的清理：**不带** `NOT create_confirmed`（O4-R10-C1）。
# ⚠️ 两者绝不可复用同一条 SQL：成功建库的行必然已 confirmed，用上面那条删它**永远匹配 0 行** ——
#    每一次正常成功的运行都会留下一行「新鲜且已确认」的 intent，它既会把后来者当外来行挡住，
#    又是一张对同名空库的销毁授权。（这正是 R9 修复引入的回归：我给撤回加谓词时，
#    忘了成功路径复用着同一个常量。修 symptom 会挪动失败面 —— 本仓第 N 次。）
_CLEAR_INTENT_SQL = ("DELETE FROM public.pilot_create_intent"
                     " WHERE dbname = $1 AND run_id = $2")
# 读后验用（O4-R12-C2）：判据是「这一行**真的不在了**」，而不是「DELETE 报了 1 行」。
_INTENT_EXISTS_SQL = ("SELECT EXISTS (SELECT 1 FROM public.pilot_create_intent"
                      " WHERE dbname = $1 AND run_id = $2)")
# 建库确认成功后才置 true —— 零对象例外**只认 create_confirmed = true 的行**（O4-R8-C2）。
# ⚠️ **确认位也必须绑到本次刚建出来的那个实例**（O4-R36-C1）。
#    原来只按名字取 oid：`CREATE DATABASE` 成功 → 读到 oid → **此处**它被删掉又同名重建，
#    这句就给**替身**盖上 `create_confirmed = true` 并把替身的 oid 写进 `db_oid` ——
#    而这一行正是零对象例外第 6 条据以**授权 DROP DATABASE** 的凭据。
#    随后的 `adopt_connection(expected_oid=…)` 确实会拒掉这条运行，但那时
#    维护库里已经留下一张对「本次没有建过的库」的销毁授权 + 归属凭据。
#    ⚠️ 判据必须写在**这一句 SQL 里**，不能「先查 oid 再决定要不要执行」——
#    后者就是本条要修的那个竞态本身（查完到执行之间同样可以被替换）。
#    这是「凡是『这就是我那个库』的断言都要绑实例」在本 PR 的**第四、五处落点**
#    （R16-C2 登记读 → R21-C1 intent 保留位 → R35-C2 目标连接 → 本条 确认位 + 登记写）。
#    第六处（闸 0− 枚举后逐个连进去判归属）在同一轮一并补上；
#    `test_every_pg_database_predicate_binds_to_an_instance` 从此机械挡住第七处。
_CONFIRM_INTENT_SQL = ("UPDATE public.pilot_create_intent SET create_confirmed = true,"
                       "       db_oid = (SELECT d.oid FROM pg_database d"
                       "                  WHERE d.datname::text = $1 AND d.oid::text = $3)"
                       " WHERE dbname = $1 AND run_id = $2"
                       "   AND EXISTS (SELECT 1 FROM pg_database d"
                       "                WHERE d.datname::text = $1 AND d.oid::text = $3)")

# 建库之后立刻读一次：**本次运行所说的「那个库」由这一行定义**。
# 提成常量而不是内联，是为了让 `test_every_pg_database_predicate_binds_to_an_instance`
# 能把它列进「捕获点」白名单——内联的 SQL 那条守卫看不见，等于给自己留了个后门。
_CREATED_DB_OID_SQL = ("SELECT d.oid::text FROM pg_database d"
                       " WHERE d.datname::text = $1")

_INSERT_META_SQL = "INSERT INTO public.pilot_meta (key, value) VALUES ($1, $2)"

# apply 完 pilot_schema_sql 之后、写任何键之前的结构证明（O4-R13-C2）。
# ⚠️ 与闸 (i) 对维护表做的是同一件事：**执行过 DDL ≠ 结构就对**。
#    pilot_schema_sql 由调用方传入（CLI 从仓库文件读），文件漂移/读错都会让这里
#    建出「有 pilot_meta 没有 pilot_stock_source」或「pilot_meta 没有主键」的库，
#    而后续照常写完 9 个键 + state='ready' —— 对外宣称 ready，归属/来源表却是坏的。
# ⚠️ **形状对了不等于行为没被改**（O4-R26-C1）：`schema_sql` 是调用方给的 DDL，它可以在
#    pilot 专用表上装一个**触发器**或**规则** —— 表结构、列、主键、阶段 1 的七行全都原样，
#    而阶段 2 写进去的 `schema_sha256` / `state='ready'` 会被触发器就地改写；
#    装在 `pilot_stock_source` 上的触发器则会污染此后每一次来源代次写入。
#    故 apply 完 `schema_sql` 还要证明这两张表上**没有本工具之外的依赖物**：
#    用户触发器、规则、以及主键之外的索引/约束一律不许有。
#    （`tgisinternal` 为真的是外键/约束自带的内部触发器，不算用户装的。）
# ⚠️ **新建的库，来源代次基线必须是空的**（O4-R27-C1）：`schema_sql` 可以往
#    `public.pilot_stock_source` 里 `INSERT` 几行 —— 形状、主键、依赖物全都干净，
#    库照样被标 ready、intent 行照样被清掉。而这张表是 `already_done` /
#    来源代次判定的**基线**：伪造的行会让此后的重新导入被跳过，
#    或与真实来源冲突，**且那时已经没有任何自动恢复凭据**。
# ⚠️ **验收标准不能从被验对象自己推导**（O4-R29-C2）：此前「schema.sql 声明的表都在吗」
#    这条判据的期望清单来自 `schema_sql` **自己** —— 一份错的但自洽的 SQL
#    （`BEGIN; CREATE TABLE klines(id int); COMMIT;`）过得了事务包裹闸、指纹与它自己一致、
#    声明一张表也确实建出来了 —— 于是被标 ready，把坏 schema 变成「合格的 pilot 库」，
#    失败被推到之后的导入/生成路径上。
#    故另立一条**外部**判据：业务 schema 必须建出这几张表。清单是模块常量，
#    由 `test_required_business_tables_matches_schema_file` 钉死到
#    `backend/sql/schema.sql` —— 模块不读文件（不耦合仓库布局），测试负责防漂移。
REQUIRED_BUSINESS_TABLES = ("stocks", "klines", "stock_coverage", "training_sets")

# ⚠️ **只验表名是不够的**（O4-R30-C1）：四个名字建成空壳、少列、缺约束，一样过得了
#    上面那条判据，随后被标 ready —— 坏 schema 变成「合格的 pilot 库」，
#    失败与损坏被推到之后的导入/生成路径上，而复用时还会信任那个假指纹。
#    修法**不是**把列/类型/约束/索引再枚举一遍（那是把 schema.sql 的契约抄第二遍，
#    必然漂移，且漏一条就是静默放行），而是把两份 .sql **钉死到仓库里的规范文件**：
#    字节相同 → 列、类型、NOT NULL、主键、索引、外键全对，**由构造保证**。
#    模块不读文件（不耦合仓库布局）；防漂移交给
#    `test_canonical_schema_hashes_match_the_repo_files` —— 改了 .sql 而没更新常量，它当场变红。
CANONICAL_SCHEMA_SHA256 = "02c47d43b5bf64c8d61140f1d080c142f63e994679c69eff9142571568dbc28a"
CANONICAL_PILOT_SCHEMA_SHA256 = "8d018f98c5a29583e4eea8204680ea09f570ab9b3acf5479fb01ea0745527d7a"

# ⚠️ **规范指纹证明的是「递进来的字节」，不是「库现在长什么样」**（O4-R32-C2）：
#    apply 之后到写 ready 之间，业务表仍可能被改（并发的手、残留对象、PG 侧异常）——
#    掉一条 CHECK 约束、换一个列类型，四个表名照旧齐全，
#    随后 `schema_sha256` 与 `state='ready'` 被写进去，**元数据声称的 schema 与库里的不是一回事**。
#    故 apply 之后按**活目录**再算一次指纹：列(名/类型/可空) + 约束定义 + 索引定义。
#
#    ⚠️ **这个值对 PostgreSQL 大版本敏感**：`pg_get_constraintdef` / `pg_get_indexdef`
#    的渲染会随版本变。它不是「安全常量」而是「快照」——升级 PG 之后必须重新生成，
#    而**验收脚本会在升级后当场变红并打印实际值**（不会静默漂移到生产）。
#    生成方式：拿一个刚用规范 schema.sql 建好的库，跑 `_BUSINESS_CATALOG_FINGERPRINT_SQL`，
#    对结果做 `sha256_of_sql(...)`。真 PG 验收脚本的 ㉕ 档就是干这件事的。
_BUSINESS_CATALOG_FINGERPRINT_SQL = """
WITH t(oid) AS (
  SELECT o FROM unnest(ARRAY[to_regclass('public.stocks'),
                             to_regclass('public.klines'),
                             to_regclass('public.stock_coverage'),
                             to_regclass('public.training_sets')]) o
   WHERE o IS NOT NULL
)
SELECT
  -- ⚠️ **取整行表级属性，不再逐个字段补**（O4-R35-C1）。
  --    这已经是第三次「指纹漏了一个维度」（R33 默认值 → R34 序列 → 本次 relpersistence）：
  --    `ALTER TABLE … SET UNLOGGED` 改的是 `pg_class.relpersistence`，
  --    列/约束/默认值/序列/索引一个都不动 —— 库不再崩溃安全（PG 崩后会被 truncate），
  --    而守卫毫无察觉地写下 `state='ready'`。
  --    逐个补下去永远比下一个评审慢一步，故这里把**表级那一行**整体纳入：
  --    relkind / relpersistence / 访问方法 / 表空间 / reloptions / 分区归属 /
  --    RLS 两个标志 / 是否有子表·规则·触发器·索引 / check 数 / 列数。
  coalesce((SELECT string_agg(c.relname || '@' ||
                    c.relkind::text || ':' || c.relpersistence::text || ':' ||
                    coalesce(am.amname, '-') || ':' ||
                    coalesce(nullif(c.reltablespace, 0)::text, 'default') || ':' ||
                    coalesce(array_to_string(c.reloptions, ','), '-') || ':' ||
                    c.relispartition::text || ':' ||
                    c.relrowsecurity::text || ':' || c.relforcerowsecurity::text || ':' ||
                    c.relhassubclass::text || ':' || c.relhasrules::text || ':' ||
                    c.relhastriggers::text || ':' || c.relhasindex::text || ':' ||
                    c.relchecks::text || ':' || c.relnatts::text,
                    E'\n' ORDER BY c.relname)
              FROM pg_class c JOIN t ON t.oid = c.oid
              LEFT JOIN pg_am am ON am.oid = c.relam), '')
    || E'\n--columns--\n'
    || coalesce((SELECT string_agg(c.relname || '.' || a.attname || ':' ||
                        format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull::text,
                        E'\n' ORDER BY c.relname, a.attnum)
                   FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                   JOIN t ON t.oid = c.oid
                  WHERE a.attnum > 0 AND NOT a.attisdropped), '')
    || E'\n--constraints--\n'
    || coalesce((SELECT string_agg(c.relname || '|' || k.conname || '|' ||
                        pg_get_constraintdef(k.oid), E'\n' ORDER BY c.relname, k.conname)
                   FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
                   JOIN t ON t.oid = c.oid), '')
    || E'\n--defaults--\n'
    -- ⚠️ **默认值也必须进指纹**（O4-R33-C1）：`ALTER TABLE … ALTER COLUMN status
    --    SET DEFAULT 'sent'` 或 `… DROP DEFAULT` 不动列名/类型/可空/约束/索引，
    --    上一版指纹**完全看不见**它。而运行时的 INSERT 依赖这些默认值
    --    （省略 id / status 的写入会失败，或安静地写成错误的状态）——
    --    库照样被标 ready、intent 行照样被清掉。
    || coalesce((SELECT string_agg(c.relname || '.' || a.attname || '=' ||
                        pg_get_expr(d.adbin, d.adrelid), E'\n' ORDER BY c.relname, a.attname)
                   FROM pg_attrdef d JOIN pg_class c ON c.oid = d.adrelid
                   JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
                   JOIN t ON t.oid = c.oid), '')
    || E'\n--sequences--\n'
    -- ⚠️ 序列参数也进指纹（O4-R34-C1）：`ALTER SEQUENCE training_sets_id_seq
    --    INCREMENT BY -1`（或改 start/cycle）不动列/约束/默认值文本 —— 默认值里写的是
    --    `nextval('…'::regclass)`，序列**本身**变了它一个字都不变。而 id 的生成方式坏掉
    --    会让此后每一次导入拿到错的主键。
    -- ⚠️ **取 pg_sequences 的整行行为属性，不再挑几个字段**（O4-R38-C1）：
    --    R34 加这一段时只取了 start/increment/cycle —— 正是 R35 刚为**表**修掉的那个反模式
    --    （挑字段永远比下一个评审慢一步），而序列这一段当时没跟着改。本机 PG 15.12 实测：
    --    `MAXVALUE 2` / `AS smallint` / `CACHE 1000` 三种改法都让上面那三个字段**一字不变**，
    --    而 `MAXVALUE` 改小之后第三次 INSERT 直接
    --    `nextval: reached maximum value of sequence`（已复现）。
    --    ⚠️ `relpersistence` 也一并取：本机实测 `ALTER SEQUENCE … SET UNLOGGED` **PG 15.12 支持**
    --    （relpersistence 变 'u'）—— R37 给表补的崩溃安全证明，序列这边同样躲得过。
    --    ⚠️ **刻意不取** `last_value`（运行时状态，每插一行就变，取了指纹不再确定）
    --    与 `sequenceowner`（随部署的角色名而变，与 DDL 正确性无关）。
    --    这两条排除由验收脚本的「pg_sequences 列覆盖率」断言钉住：
    --    PG 升级新增一列时它会变红，而不是静默少覆盖一维。
    || coalesce((SELECT string_agg(s.sequencename || ':' || s.data_type || ':' ||
                        s.start_value || ':' || s.min_value || ':' || s.max_value || ':' ||
                        s.increment_by || ':' || s.cycle::text || ':' || s.cache_size || ':' ||
                        sc.relpersistence::text, E'\n' ORDER BY s.sequencename)
                   FROM pg_sequences s
                   JOIN pg_class sc ON sc.relname = s.sequencename AND sc.relkind = 'S'
                   JOIN pg_namespace sn ON sn.oid = sc.relnamespace
                                       AND sn.nspname = s.schemaname
                  WHERE s.schemaname = 'public'
                    AND EXISTS (SELECT 1 FROM pg_depend d
                                 JOIN pg_class sc ON sc.oid = d.objid
                                 JOIN t ON t.oid = d.refobjid
                                WHERE sc.relname = s.sequencename
                                  AND sc.relkind = 'S' AND d.deptype = 'a')), '')
    || E'\n--indexes--\n'
    || coalesce((SELECT string_agg(pg_get_indexdef(i.indexrelid), E'\n'
                        ORDER BY pg_get_indexdef(i.indexrelid))
                   FROM pg_index i JOIN t ON t.oid = i.indrelid), '')
"""

# 由 ㉕ 档在真 PG 上生成/校验；PG 大版本升级后需重新生成（见上）。
CANONICAL_BUSINESS_CATALOG_SHA256 = "e5a87293f44a7f7193b8d2727bb76906a24ad3e94e9e8f67eeaca74cec9e53a8"

# ⚠️ **业务表也要证「没有行为对象」**（O4-R34-C1）：`_PILOT_TABLE_DEPENDENTS_SQL` 只管
#    两张 pilot 表 —— 同一条判据在业务表上**没做**（本 PR 里「只修被点名的那一处」的又一次）。
#    往 `public.klines` 上装一个 INSERT 触发器，列/约束/默认值/索引/序列全都不变，
#    指纹一个字都不动，而此后每一次导入都被它改写。
#    ⚠️ 与 pilot 表那条的**差别**：索引与约束是 `schema.sql` 的合法产物（且已进指纹），
#    故这里只数**行为**类：用户触发器、规则、RLS、继承边。
_BUSINESS_TABLE_BEHAVIOR_SQL = """
WITH t(oid) AS (
  SELECT o FROM unnest(ARRAY[to_regclass('public.stocks'),
                             to_regclass('public.klines'),
                             to_regclass('public.stock_coverage'),
                             to_regclass('public.training_sets')]) o
   WHERE o IS NOT NULL
)
SELECT
  (SELECT count(*) FROM pg_trigger g JOIN t ON g.tgrelid = t.oid
    WHERE NOT g.tgisinternal)                                       AS user_triggers,
  (SELECT count(*) FROM pg_rewrite w JOIN t ON w.ev_class = t.oid
    WHERE w.rulename <> '_RETURN')                                  AS user_rules,
  (SELECT count(*) FROM pg_policy p JOIN t ON p.polrelid = t.oid)    AS rls_policies,
  (SELECT count(*) FROM pg_class c JOIN t ON c.oid = t.oid
    WHERE c.relrowsecurity OR c.relforcerowsecurity)                AS rls_enabled,
  (SELECT count(*) FROM pg_inherits h JOIN t
      ON h.inhparent = t.oid OR h.inhrelid = t.oid)                 AS inherit_edges
"""

_PILOT_SOURCE_EMPTY_SQL = "SELECT count(*) FROM public.pilot_stock_source"

_PILOT_TABLE_DEPENDENTS_SQL = """
WITH roots(oid) AS (
  SELECT o FROM unnest(ARRAY[to_regclass('public.pilot_meta'),
                             to_regclass('public.pilot_stock_source')]) o WHERE o IS NOT NULL
)
SELECT
  (SELECT count(*) FROM pg_trigger g JOIN roots r ON g.tgrelid = r.oid
    WHERE NOT g.tgisinternal)                                       AS user_triggers,
  (SELECT count(*) FROM pg_rewrite w JOIN roots r ON w.ev_class = r.oid
    WHERE w.rulename <> '_RETURN')                                  AS user_rules,
  (SELECT count(*) FROM pg_index i JOIN roots r ON i.indrelid = r.oid
    WHERE NOT EXISTS (SELECT 1 FROM pg_constraint k
                       WHERE k.conindid = i.indexrelid AND k.contype = 'p'))
                                                                    AS extra_indexes,
  (SELECT count(*) FROM pg_constraint k JOIN roots r ON k.conrelid = r.oid
    WHERE k.contype <> 'p')                                         AS extra_constraints,
  -- ⚠️ 行级安全与继承同样**改变读写行为却不碰列/主键形状**（O4-R27-C2，真 PG 实测）：
  --    `ALTER TABLE … ENABLE/FORCE ROW LEVEL SECURITY` 之后 `relrowsecurity`/
  --    `relforcerowsecurity` 变 true 而形状判据照旧通过；本工具**不保证以超级用户运行**
  --    （超级用户会绕过 RLS，普通角色不会）—— 一张「空的但被 RLS 挡住」的来源表
  --    会让此后每次读都看不到该看的行。
  --    继承边则相反：子表的行会**从父表读出来**，来源代次基线凭空多出内容。
  (SELECT count(*) FROM pg_policy p JOIN roots r ON p.polrelid = r.oid)
                                                                    AS rls_policies,
  (SELECT count(*) FROM pg_class c JOIN roots r ON c.oid = r.oid
    WHERE c.relrowsecurity OR c.relforcerowsecurity)                AS rls_enabled,
  (SELECT count(*) FROM pg_inherits h JOIN roots r
      ON h.inhparent = r.oid OR h.inhrelid = r.oid)                 AS inherit_edges
"""

_PILOT_SCHEMA_SHAPE_SQL = """
SELECT
  EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = to_regclass('public.pilot_meta')
                                     AND c.relkind = 'r')                       AS meta_is_table,
  EXISTS (SELECT 1 FROM pg_constraint k
           JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
          WHERE k.conrelid = to_regclass('public.pilot_meta')
            AND k.contype = 'p' AND array_length(k.conkey, 1) = 1
            AND a.attname = 'key')                      AS meta_key_unique,
  (SELECT count(*) FROM pg_attribute a
    WHERE a.attrelid = to_regclass('public.pilot_meta') AND NOT a.attisdropped
      AND a.attnum > 0 AND a.attname IN ('key','value')
      AND format_type(a.atttypid, NULL) = 'text' AND a.attnotnull) = 2          AS meta_columns_ok,
  EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = to_regclass('public.pilot_stock_source')
                                     AND c.relkind = 'r')                       AS source_is_table,
  -- ⚠️ 列名+类型还不够，**必须连 NOT NULL 一起钉**（O4-R20-C2）：
  --    漂移的 pilot_schema.sql 把 sha_1m/sha_daily 的 NOT NULL 去掉、或库里本就存在
  --    一张被 `IF NOT EXISTS` 跳过的旧表，都能满足「列名对、类型对」——
  --    而这张表是**每只股票的来源代次基线**，可空的 hash 等于把正确性从
  --    数据库不变量挪到后续的临时处理上。pilot_meta.value 同理。
  (SELECT count(*) FROM pg_attribute a
    WHERE a.attrelid = to_regclass('public.pilot_stock_source') AND NOT a.attisdropped
      AND a.attnum > 0 AND a.attname IN ('stock_code','sha_1m','sha_daily')
      AND format_type(a.atttypid, NULL) = 'text' AND a.attnotnull) = 3          AS source_columns_ok,
  EXISTS (SELECT 1 FROM pg_constraint k
           JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
          WHERE k.conrelid = to_regclass('public.pilot_stock_source')
            AND k.contype = 'p' AND array_length(k.conkey, 1) = 1
            AND a.attname = 'stock_code')               AS source_key_unique,
""" + _durable_tables_sql(("public.pilot_meta", "public.pilot_stock_source"),
                           "pilot_tables_durable")

_SET_READY_SQL = "UPDATE public.pilot_meta SET value = 'ready' WHERE key = 'state'"


# ── 活体健康检查（**建库后**与**复用前**共用同一份判据，codex 4a-2a R1）──────
# ⚠️ 规范指纹（CANONICAL_*_SHA256）管的是「递进来的 DDL 字节」，
#    这三条管的是「库**现在**长什么样」。建库时跑过一次不等于复用时还成立：
#    apply 之后到下一次复用之间，并发的手 / 残留对象 / 人工 ALTER 都能改它。
#    只在建库路径跑的话，一个被改过的 ready 库照样通过复用闸，
#    随后 B1/B2 在坏 schema 上读写 —— 正是本闸存在的理由。
async def _assert_no_business_behavior_objects(conn, *, phase: str) -> None:
    """业务表上不许有**行为对象**（触发器/规则/RLS/继承边）。

    它们不动列/约束/默认值/索引，**活目录指纹一个字都不动**，
    而此后每一次导入都被它们改写。
    """
    try:
        row = await conn.fetchrow(_BUSINESS_TABLE_BEHAVIOR_SQL)
    except Exception as exc:
        # ⚠️ 读失败不得裸逃（codex R2-F2）：目标库被并发 DROP / 权限变更 / 目录查询失败
        #    都会在这里抛，裸异常会被 4c 兜成 FAIL_INFRASTRUCTURE ——
        #    而 §9-1w 明令禁止把一次成功的 fail-closed 守卫记成环境故障。
        raise PilotDbBoundaryError(
            "target_db_unreadable", f"读业务表行为对象判据失败（{exc}）") from exc
    if row is None or any(v for v in row.values()):
        raise PilotDbBoundaryError(
            "business_tables_have_dependents",
            f"{phase}业务表上出现了行为对象（{dict(row) if row else 'None'}）——"
            f"触发器/规则会改写此后每一次导入，RLS 会让普通角色读不到该读的行，"
            f"继承边会让子表的行从父表冒出来。这些都不动列/约束/默认值/索引，指纹看不见。")


async def _assert_live_catalog_matches_canonical(conn, *, phase: str) -> None:
    """活目录指纹必须等于规范快照。表名齐全不代表列/类型/可空/约束/索引没被改。"""
    try:
        live = await conn.fetchval(_BUSINESS_CATALOG_FINGERPRINT_SQL)
    except Exception as exc:
        raise PilotDbBoundaryError(
            "target_db_unreadable", f"读活目录指纹失败（{exc}）") from exc
    live_sha = sha256_of_sql(live or "")
    if live_sha != CANONICAL_BUSINESS_CATALOG_SHA256:
        raise PilotDbBoundaryError(
            "business_schema_drift",
            f"{phase}活目录指纹是 {live_sha!r}，规范值是 "
            f"{CANONICAL_BUSINESS_CATALOG_SHA256!r} —— "
            f"表名齐全不代表列/类型/可空/约束/索引没被改。"
            f"⚠️ 若刚升级过 PostgreSQL 大版本，这是**渲染差异**而不是漂移："
            f"请用真 PG 验收脚本的 ㉕ 档重新生成 CANONICAL_BUSINESS_CATALOG_SHA256。")


async def _assert_no_pilot_table_dependents(conn, *, phase: str) -> None:
    """pilot 专用表上不许有本工具之外的依赖物（含主键之外的索引/约束）。"""
    try:
        row = await conn.fetchrow(_PILOT_TABLE_DEPENDENTS_SQL)
    except Exception as exc:
        # ⚠️ 读失败不得裸逃（codex R2-F2）：目标库被并发 DROP / 权限变更 / 目录查询失败
        #    都会在这里抛，裸异常会被 4c 兜成 FAIL_INFRASTRUCTURE ——
        #    而 §9-1w 明令禁止把一次成功的 fail-closed 守卫记成环境故障。
        raise PilotDbBoundaryError(
            "target_db_unreadable", f"读pilot 表依赖物判据失败（{exc}）") from exc
    if row is None or any(v for v in row.values()):
        raise PilotDbBoundaryError(
            "pilot_tables_have_dependents",
            f"{phase}pilot 专用表上出现了本工具之外的依赖物"
            f"（{dict(row) if row else 'None'}）——触发器/规则能就地改写指纹与 state；"
            f"额外索引/约束能改变来源代次写入的语义；RLS 能让普通角色读不到该读的行；"
            f"继承边能让子表的行从父表冒出来。")


async def create_pilot_database(
    maint_conn, *, connect, db_name: str, seed: str,
    schema_sql: str, pilot_schema_sql: str,
    schema_sha256: str, pilot_schema_sha256: str,
    export_log_sha256: str, output_dir: str, created_at: str,
    run_id: str,
) -> None:
    """两阶段建库：归属先于 schema（spec R55-F1）。

    0. 维护连接 INSERT pilot_create_intent + COMMIT（在 CREATE DATABASE **之前**，故无窗口）
    1. CREATE DATABASE … TEMPLATE template0
    2. 连进去，**同一个事务**里 apply pilot_schema.sql + 写 7 个键（state='initializing'）
    3. apply schema.sql（**事务外**执行——该文件自带 BEGIN/COMMIT，由它自己的事务保证原子性）
    4. **另一个事务**里补写 2 个键（schema_sha256/contract_version）+ state='ready'
    5. 干净收尾：删掉自己的 intent 行

    ⚠️ 调用方必须已经跑过 assert_cluster_allowed。本函数只再过一次名字护栏。
    """
    await pin_search_path(maint_conn)
    assert_pilot_db_allowed(db_name, reset=False, destructive=False)
    # ⚠️ **指纹必须由内容算出来，不能信调用方传的**（O4-R19-C1）——
    #    与 R5-C2 把 `seed_lock_held` 布尔换成活连接验锁是同一条原则：
    #    调用方的断言不是证据。文件与 hash 配错（读了旧文件、改了文件忘了重算）时，
    #    库会被标成 ready 而 `pilot_meta` 里的指纹**指着另一份 schema**；
    #    之后的复用闸拿这个假指纹去比对，判据整条失效。
    #    放在这里 = 任何副作用之前（连 intent 行都还没写）。
    for _label, _sql, _claimed in (("schema.sql", schema_sql, schema_sha256),
                                   ("pilot_schema.sql", pilot_schema_sql, pilot_schema_sha256)):
        _actual = sha256_of_sql(_sql)
        if _actual != _claimed:
            raise PilotDbBoundaryError(
                "fingerprint_content_mismatch",
                f"{_label} 的指纹与内容对不上：传入 {_claimed!r}，实际 {_actual!r}——"
                f"多半是读了旧文件、或改了文件忘了重算。绝不能把对不上的指纹写进 pilot_meta。")
    # ⚠️ 一份**什么表都不建**的业务 schema 不是合法的 schema.sql（O4-R19-C1）：
    #    `BEGIN; SELECT 1; COMMIT;` 能过事务包裹闸、指纹也能自洽，
    #    却会产出一个「ready 但一张业务表都没有」的库。
    _expected_tables = declared_tables(schema_sql)
    if not _expected_tables:
        raise PilotDbBoundaryError(
            "schema_declares_no_tables",
            "schema.sql 一张表都没声明——它过得了事务包裹闸、指纹也自洽，"
            "却会产出一个『ready 但没有任何业务表』的库。")
    # ⚠️ 两条 fail-closed 守卫：两份 schema 的**事务归属**必须与代码假设一致（O4-W1）。
    #    靠约定不行——违反时是**静默**失去原子性，没有任何信号。
    if _transaction_statements(pilot_schema_sql):
        raise PilotDbBoundaryError(
            "schema_transaction_conflict",
            f"pilot_schema.sql 不得含顶层事务控制语句（实得 "
            f"{_transaction_statements(pilot_schema_sql)}）——阶段 1 由本工具包裹事务；"
            "自带会让本工具的 transaction() 在它的 COMMIT 处被拆开。"
            "（PL/pgSQL 的 DO/函数体里的 BEGIN…END 不算，判据已剥掉 dollar-quoted 块）",
        )
    if not _is_wrapped_in_transaction(schema_sql):
        raise PilotDbBoundaryError(
            "schema_transaction_missing",
            "schema.sql 必须**整份被一个事务包住**（首条 BEGIN / 末条 COMMIT）——"
            "本工具选择了**不包裹**它，而这个选择只有在文件自带事务时才与它配对；"
            "文件形态一变，配对关系就无人看守。注意「含 BEGIN」不等于「被包住」："
            "`CREATE TABLE early (); BEGIN; … COMMIT;` 里第一条 DDL 实际在事务外",
        )
    # ⚠️ 排在事务归属闸之后（那两条讲的是「这份 SQL 的形状」，先报更具体的原因），
    #    但仍在**任何副作用之前** —— 连 intent 行都还没写。
    for _label, _claimed, _canon in (
            ("schema.sql", schema_sha256, CANONICAL_SCHEMA_SHA256),
            ("pilot_schema.sql", pilot_schema_sha256, CANONICAL_PILOT_SCHEMA_SHA256)):
        if _claimed != _canon:
            raise PilotDbBoundaryError(
                "schema_not_canonical",
                f"{_label} 与仓库里的规范文件不是同一份：传入指纹 {_claimed!r}，"
                f"规范指纹 {_canon!r}。**验收标准不能由调用方提供** —— 四个表名建成空壳、"
                f"少列、缺约束都能过「表名齐了吗」那一关，故这里直接钉字节。")

    # 建库与库级闸**共用同一份判据**（4a-2 抽出 `_assert_seed_db_name`）：
    # 两处各写一遍正是本 PR 记录在案的「只修被点名的那一处」。
    _assert_seed_db_name(db_name, seed)

    # ⚠️ **集群闸在这里机器强制，不是注释级前提**（O4-R5-C2）：
    #    此前它只写在 docstring 里，于是任何接线失误都能在**未过集群闸**的情况下
    #    直接在传进来的 DSN 上建库 —— 标记闸、无关库闸、维护库空闸全部被跳过。
    #    重复调用的代价只是几条只读查询，远小于「漏掉一次」的代价。
    await assert_cluster_allowed(maint_conn, connect=connect, target_db=db_name)
    # 维护连接所在集群的身份 —— 之后接管的每条连接都要与它一致（O4-R29-C1）。
    _cluster_id = await cluster_identity(maint_conn)

    # ⚠️ **按 seed 的 advisory lock 在活连接上真验**（O4-R5-C2）：
    #    此前信的是调用方传进来的布尔值 `seed_lock_held`，那是可伪造的 ——
    #    传 True 就能绕过。本模块仍**不取锁**（spec O1-F4），只验它是否真被持有。
    if not await maint_conn.fetchval(_SEED_LOCK_HELD_SQL, seed):
        raise PilotDbBoundaryError(
            "seed_lock_not_held",
            f"维护连接上没有持有 seed={seed!r} 的 advisory lock（①c）——"
            f"并发的同 seed 运行会互相覆盖 pilot_create_intent 行，"
            f"而零对象例外第 6 条据它授权 DROP DATABASE。"
            f"请由调用方先 pg_try_advisory_lock(hashtext('kline_pilot_' || seed))",
        )
    if not run_id:
        raise PilotDbBoundaryError(
            "run_id_missing", "run_id 是 intent 行的归属凭据，不得为空")
    # ⚠️ 在**写 intent 行之前**（也就是任何副作用之前）验身份标量（O4-R32-C1）。
    assert_identity_scalars(export_log_sha256, output_dir, created_at)

    # 0. 声明意图（零对象例外第 6 条的判据）。
    #    冲突且对方新鲜（未超 INTENT_TTL）→ RETURNING 为空 → **拒绝启动**。
    claimed = await maint_conn.fetchval(
        _INSERT_INTENT_SQL, db_name, seed, created_at, run_id, INTENT_TTL_SECONDS)
    if claimed is None:
        raise PilotDbBoundaryError(
            "intent_row_conflict",
            f"{db_name} 已有一条**新鲜的** pilot_create_intent 行且不属于本次运行"
            f"（run_id={run_id!r}）——另一次同名运行可能正在进行；"
            f"绝不覆盖它（那会把 DROP 授权转移到本次运行名下）",
        )

    # 1. 建库。TEMPLATE template0 是硬要求，理由见 test_create_pilot_database_uses_template0。
    #    ⚠️ 库名不能绑参（PG 不允许 DDL 里的标识符绑参），故走 quote_ident；
    #       它之前已经过了 assert_pilot_db_allowed。
    try:
        await maint_conn.execute(
            f"CREATE DATABASE {quote_ident(db_name)} TEMPLATE template0")
    except Exception as exc:
        # 只在**确定没建成**时撤回 intent 行；歧义失败保留它（见常量处的说明）。
        # ⚠️ 撤回本身失败时**绝不能让它的异常盖掉原始建库错误**（O4-R8-C2）——
        #    那会把「库已存在」报成「删行失败」，指引整个走错。
        #    而即便撤回没成功也不致命：该行的 create_confirmed 仍是 false，
        #    **零对象例外只认 true**，故它授权不了任何 DROP；TTL 兜底清理。
        if getattr(exc, "sqlstate", None) in _CREATE_DEFINITELY_FAILED_SQLSTATES:
            try:
                await maint_conn.execute(_DELETE_INTENT_SQL, db_name, run_id)
            except Exception as cleanup_exc:
                print(f"[qmt_pilot] 警告：撤回 {db_name!r} 的 intent 行失败：{cleanup_exc}；"
                      f"该行 create_confirmed=false，授权不了 DROP，将由 INTENT_TTL 清理",
                      file=sys.stderr)
        raise

    # 建库**确认成功** —— 只有到这一步，这一行才可能成为「本次残骸」的凭据。
    # 刚建出来的那个实例的 oid —— 此后每一条凭据都必须绑到它（O4-R35-C2 / R36-C1）。
    _created_oid = await maint_conn.fetchval(_CREATED_DB_OID_SQL, db_name)
    confirm_status = await maint_conn.execute(
        _CONFIRM_INTENT_SQL, db_name, run_id, _created_oid)
    # ⚠️ **必须核行数**（O4-R11-C2，与收尾清理对称）：并发的另一次运行把 intent 行抢走/删掉时
    #    这里是 `UPDATE 0`，函数却照常往下走。此后若崩在写 pilot_meta 之前，就留下一个
    #    **没有恢复凭据的空库** —— 零对象例外认不出它，可自愈的残骸变成人工清理 + 挡住同名重建。
    if str(confirm_status).strip() != "UPDATE 1":
        # ⚠️ 授权与否**已经由上面那句 SQL 原子决定**了（UPDATE 0 = 一个字都没写）。
        #    这里再读一次 oid 只为把错误说清楚，**不据以做任何决定** ——
        #    否则就又是一次「先查后用」的竞态。读失败也不改变结论。
        try:
            _now_oid = await maint_conn.fetchval(_CREATED_DB_OID_SQL, db_name)
        except Exception:                                    # 诊断而已，读不到就算了
            _now_oid = None
        if _now_oid != _created_oid:
            raise PilotClusterBoundaryError(
                "created_database_replaced",
                f"本次建出来的 {db_name!r} 实例 oid 是 {_created_oid!r}，"
                f"写恢复凭据时同名库的 oid 已是 {_now_oid!r} ——"
                f"建库与确认之间它被删掉又重建了。"
                f"绝不给一个本次没有建过的库盖确认位（那是一张 DROP 授权）。"
                f"本次未留下任何凭据；那个同名库不属于本工具，请人工核对 {db_name!r}。")
        raise PilotClusterBoundaryError(
            "intent_not_confirmed",
            f"库 {db_name!r} **已经建出来了**，但写入恢复凭据返回 {confirm_status!r}"
            f"（期望 'UPDATE 1'）—— intent 行可能已被并发运行抢走或删除。"
            f"该空库缺少 create_confirmed 凭据，零对象例外清不掉它，请人工删除 {db_name!r}。")

    # 登记库名（闸 (ii) 的**外部**归属凭据，O4-R14-C1 / R15-C1）——
    # 在**建库确实成功之后**才写；这张表本工具从不清。
    # ⚠️ **必须排在确认 intent 之后**（O4-R16-C1）：夹在「建库成功」与「写恢复凭据」之间的
    #    任何一步失败，都会留下「有库、但 intent 仍是 false」的状态；同 run 重试撞
    #    duplicate_database 后，确定性失败清理会把那行未确认的 intent 删掉 ——
    #    空库从此没有任何销毁授权。凭据要紧贴着它所证明的事实写，中间不夹别的可失败步骤。
    await maint_conn.execute(
        _REGISTER_DB_SQL, db_name, seed, run_id, created_at, _created_oid)
    # 读后验：`DO UPDATE` 的命令状态说明不了「行是否绑到了当前实例」，
    # 而判据本就包含 OID 匹配，故只能读一次。
    if not await maint_conn.fetchval(_REGISTRY_HAS_SQL, db_name, seed):
        raise PilotClusterBoundaryError(
            "registry_not_written",
            f"库 {db_name!r} **已经建出来了**，但没能在 pilot_database_registry 里登记 ——"
            f"它将来会被闸 (ii) 当成外来物。该库此刻是空的，可安全人工删除 {db_name!r}。")

    values = {
        "tool": "qmt_pilot",
        "seed": seed,
        "schema_sha256": schema_sha256,
        "pilot_schema_sha256": pilot_schema_sha256,
        "contract_version": CONTRACT_VERSION,
        "export_log_sha256": export_log_sha256,
        "output_dir": output_dir.rstrip("/"),
        "created_at": created_at,
        "state": "initializing",
    }
    target = await connect(db_name)
    # ⚠️ **连上就立刻进 finally**（O4-R24-C2）：钉桩放在守卫之外时，它一旦抛异常/被取消，
    #    函数带着一条**活着的**会话退出，而目标库此刻刚建好、还没初始化完 ——
    #    之后的 DROP 恢复会撞 `database is being accessed by other users`，
    #    一个本可自愈的残骸变成人工清理。先拿守卫，再做任何事。
    try:
        await adopt_connection(target, db_name, cluster_id=_cluster_id,
                               expected_oid=_created_oid)
        # 2. 阶段 1 —— **必须在同一个事务里**（O4-T2-C1）：
        #    apply pilot_schema.sql（建 pilot_meta + pilot_stock_source）+ 写 7 个键。
        #    ⚠️ 少了这层 `transaction()`，asyncpg 的每次 execute 都是独立自动提交的隐式事务
        #    → 崩在第 5 个键与第 6 个之间会留下「表已建、只有 5 行、`state` 键缺失」的残骸
        #    （`state` 恰是最后一个键）。该残骸**不满足【绝对空】**（两张表 + 各自 pkey 索引
        #    已在 pg_class 里）、又拿不到合法 `tool` → 集群闸 (ii) 判「名字匹配但无合法
        #    pilot_meta 且非空」→ **拒绝，且这一拒会挡住整台集群对所有 seed 的放行**。
        #    这正是两阶段设计与 TEMPLATE template0 专门要防的失效模式（spec R55-F1），
        #    只是从「缺失的事务边界」这个没堵上的窗口重新打开。
        #    PostgreSQL 的 DDL 是事务性的，故「有表但没行」这个中间态**不可能被别人看到**。
        async with target.transaction():
            await target.execute(pilot_schema_sql)
            # ⚠️ **调用方的 SQL 跑完必须重新钉 search_path**（O4-R22-C1，真 PG 实测）：
            #    事务里的普通 `SET search_path` **提交之后仍留在会话上**（只有 `SET LOCAL` 不留）。
            #    一份漂移/敌意的 .sql 只要含一句 `SET search_path = evil, pg_catalog, public`，
            #    其后**所有守卫查询**就都跑在它选定的名字解析下 —— R17/R18 好不容易堵上的
            #    目录遮蔽，从「调用方 SQL 的副作用」这个口子原样回来。
            #    一次性的钉桩管不住后面还会执行的 SQL（与 R21-C2 同一族）。
            await pin_search_path(target)
            # ⚠️ 先证结构再写任何键（O4-R13-C2）：在**同一个事务内**，故不合规时
            #    连 pilot_schema 建的表都一起回滚，不留半成品。
            shape = await target.fetchrow(_PILOT_SCHEMA_SHAPE_SQL)
            if shape is None or not all(shape.values()):
                raise PilotDbBoundaryError(
                    "pilot_schema_malformed",
                    f"apply 完 pilot_schema.sql 后结构不合规（{dict(shape) if shape else 'None'}）——"
                    f"要求 public.pilot_meta(key text 唯一, value text) 与 "
                    f"public.pilot_stock_source(stock_code text 唯一, sha_1m text, sha_daily text) "
                    f"均为普通表。执行过 DDL ≠ 结构就对；这一档不拦住，会产出一个对外宣称 "
                    f"ready、归属/来源表却是坏的库。")
            for key in PILOT_META_PHASE1_KEYS:
                await target.execute(_INSERT_META_SQL, key, values[key])

        # 3. 阶段 2 —— ⚠️ **绝不包裹 schema.sql**（O4-W1，真 postgres:15.12 实测）：
        #    该文件自带 `BEGIN;`(第 6 行)/`COMMIT;`(第 111 行)，套进 transaction() 时
        #    **文件里那句 COMMIT 会提交掉外层事务**，其后语句全部退化成各自 autocommit；
        #    而 asyncpg 的 __aexit__ 在事务已不存在时**静默返回、不抛异常**
        #    （实测：包裹内 raise 之后，schema.sql 之后建的表**仍然存在** = 回滚没发生）。
        #    没有任何测试会红、没有任何运行时错误会提示。故由**它自己的事务**保证原子性。
        await target.execute(schema_sql)
        # 同上（O4-R22-C1）：schema.sql 也是调用方给的，跑完先把解析钉回来，
        # 否则下面这几道守卫查询都可能被它改过的 search_path 牵着走。
        await pin_search_path(target)
        # ⚠️ 「执行过 DDL ≠ 结构就对」（与 O4-R13-C2 对 pilot_schema 做的是同一件事）。
        #    期望清单**从 schema_sql 自身推导**，不硬编码 —— 硬编码的清单会跟着文件漂移。
        _found = await target.fetchval(_tables_exist_sql(_expected_tables), _expected_tables)
        if _found != len(_expected_tables):
            raise PilotDbBoundaryError(
                "schema_tables_missing",
                f"apply 完 schema.sql 后，它声明的 {len(_expected_tables)} 张表里只找到 {_found} 张"
                f"（{_expected_tables}）——不能把这样的库标成 ready。")
        # ⚠️ 上面那条的期望清单来自 `schema_sql` **自己**，是**自证**（O4-R29-C2）。
        #    这条用**外部**清单：不管调用方递进来的是什么 SQL，业务表必须齐。
        # ⚠️ 与复用闸（闸 2）**共用同一份判据** —— 两处各写一遍就是本 PR 记录在案的
        #    「只修被点名的那一处」（codex 4a-2a R1 正是从「复用路径没跑这几条」来的）。
        await _assert_no_business_behavior_objects(target, phase="apply 完 schema.sql 之后")
        # ⚠️ 活目录指纹（O4-R32-C2）：规范指纹管「递进来的字节」，这条管「库现在长什么样」。
        await _assert_live_catalog_matches_canonical(target, phase="apply 完 schema.sql 之后，")
        _required = list(REQUIRED_BUSINESS_TABLES)
        _found_required = await target.fetchval(_tables_exist_sql(_required), _required)
        if _found_required != len(_required):
            raise PilotDbBoundaryError(
                "business_tables_missing",
                f"apply 完 schema.sql 后，业务 schema 要求的 {len(_required)} 张表"
                f"（{_required}）里只找到 {_found_required} 张 —— "
                f"一份错但自洽的 schema_sql 能过得了「它自己声明的表都在吗」那一条，"
                f"故这里另用外部清单。不能把这样的库标成 ready。")
        # ⚠️ **pilot 安全表必须在 schema.sql 之后再验一次**（O4-R21-C2）：
        #    结构证明此前只在 apply schema.sql **之前**跑过。而 schema.sql 是一份
        #    可以干任何事的 DDL —— `BEGIN; CREATE TABLE klines(); DROP TABLE
        #    public.pilot_stock_source; COMMIT;` 过得了事务闸、也过得了上面那道
        #    「业务表都在吗」，随后照常写指纹两键 + state='ready'。产出的库对外宣称
        #    ready、`pilot_schema_sha256` 还记着那份 schema 的指纹，而**来源代次基线表
        #    已经不在了**。一次性的证明管不住后面还会执行的 DDL。
        # ⚠️ **结构没坏不等于内容没被改**（O4-R22-C2）：上面那道只验表的形状。
        #    一句 `UPDATE public.pilot_meta SET value='other' WHERE key='seed'`
        #    或 `DELETE FROM public.pilot_meta WHERE key='export_log_sha256'`
        #    完全保持形状合规，却把**归属与输出绑定**这两组授权键改掉了；
        #    随后照常写指纹两键 + state='ready'、清掉 intent 行，
        #    产出一个「ready」但归属证明已被篡改的库。
        #    故逐键逐值复核阶段 1 写进去的那 7 个键（多一个键、少一个键、值不同，都算篡改）。
        _after = await target.fetchrow(_PILOT_SCHEMA_SHAPE_SQL)
        if _after is None or not all(_after.values()):
            raise PilotDbBoundaryError(
                "pilot_schema_invalidated",
                f"apply 完 schema.sql 之后 pilot 专用表的结构不再合规"
                f"（{dict(_after) if _after else 'None'}）——schema.sql 把它们删了或改坏了。"
                f"不能把这样的库标成 ready。")
        # ⚠️ 这道与下面的依赖物判据**部分重叠**（O4-R37-C2）：耐久性判据含 RLS 两个标志，
        #    而依赖物判据也数 RLS；反过来「部分唯一索引」既让 `*_key_unique` 为假、
        #    也让 `extra_indexes` 非零。**两个方向都重叠**，故没有哪种排序能对所有情形
        #    都给出更精确的那个 code —— 换序只是把遮蔽换到另一边（实测两种排序各红两档）。
        #    两道都保留（都 fail-closed、都可达）；重叠的那几档，验收脚本断言的是
        #    **性质**（拒了、没标 ready），而不是具体 code。
        await _assert_no_pilot_table_dependents(target, phase="apply 完 schema.sql 之后 ")
        _src_rows = await target.fetchval(_PILOT_SOURCE_EMPTY_SQL)
        if _src_rows != 0:
            raise PilotDbBoundaryError(
                "pilot_source_not_empty",
                f"apply 完 schema.sql 之后 public.pilot_stock_source 里已经有 {_src_rows} 行 ——"
                f"新建的库这张表必须是空的。它是 already_done / 来源代次判定的基线，"
                f"伪造的行会让此后的重新导入被跳过，而那时已经没有任何自动恢复凭据。")
        _after_meta = await read_pilot_meta_rows(target)
        _expected_meta = {k: values[k] for k in PILOT_META_PHASE1_KEYS}
        if _after_meta != _expected_meta:
            _diff = {k: (_expected_meta.get(k), _after_meta.get(k))
                     for k in set(_expected_meta) | set(_after_meta)
                     if _expected_meta.get(k) != _after_meta.get(k)}
            raise PilotDbBoundaryError(
                "phase1_meta_tampered",
                f"apply 完 schema.sql 之后阶段 1 的 pilot_meta 不再是写进去的样子："
                f"{_diff}（期望→实得）——schema.sql 改动了归属/绑定键。"
                f"不能把这样的库标成 ready。")

        #    指纹两键 + state='ready' 另起一个事务。
        #    残余窗口（如实登记）：schema.sql 已提交、这三条未提交时崩 →
        #    「schema 齐全、state 仍是 initializing、指纹两键缺失」，由 O4-F8 兜底
        #    （复用被拒 + db_state_initializing，--reset 能清掉重来）。不可消除。
        async with target.transaction():
            for key in PILOT_META_PHASE2_KEYS:
                await target.execute(_INSERT_META_SQL, key, values[key])
            ready_status = await target.execute(_SET_READY_SQL)
            # ⚠️ 核行数（O4-R13-C2）：`state` 行若不在（被并发删掉/阶段 1 的键被动过），
            #    UPDATE 会报 0 行而**不报错** —— 库随后被当成 ready 交付，实际 state 仍是
            #    initializing 或干脆没有。事务未提交，抛出即整体回滚。
            if str(ready_status).strip() != "UPDATE 1":
                raise PilotDbBoundaryError(
                    "ready_not_set",
                    f"置 state='ready' 返回 {ready_status!r}（期望 'UPDATE 1'）——"
                    f"pilot_meta 的 state 行不在或被改过，本次建库整体回滚。")
        # ⚠️ **阶段 2 提交之后必须把九个键读回来逐字比对**（O4-R26-C1）：
        #    上面所有证明都发生在**写入之前**。写入本身仍可能被 `schema_sql` 留下的东西
        #    （触发器/规则）就地改写 —— 依赖物白名单已经把这条路堵上了，但那是**另一条**判据；
        #    「写完再读一遍」是唯一能直接证明「库里现在真的是这九个值」的办法，
        #    也是清掉 intent 行（放弃恢复凭据）之前最后一次能反悔的机会。
        _final_expected = dict(values)
        _final_expected["state"] = "ready"
        _final_meta = await read_pilot_meta_rows(target)
        if _final_meta != _final_expected:
            _fdiff = {k: (_final_expected.get(k), _final_meta.get(k))
                      for k in set(_final_expected) | set(_final_meta)
                      if _final_expected.get(k) != _final_meta.get(k)}
            raise PilotDbBoundaryError(
                "final_meta_mismatch",
                f"阶段 2 提交后读回来的 pilot_meta 与写进去的不一致：{_fdiff}（期望→实得）"
                f"——不能就这样交付，也不能清掉 intent 行（那是唯一的恢复凭据）。")
    finally:
        # ⚠️ 与闸 (ii) 那处同规格（O4-W4 M-1）：close 抛出会顶掉一次**已经成功**的建库
        #    → 裸异常 → 4c 记成 FAIL_INFRASTRUCTURE + 留下孤儿 intent 行，而库其实是 ready 的。
        try:
            await target.close()
        except Exception as close_exc:
            print(f"[qmt_pilot] 警告：关闭 {db_name!r} 的连接失败：{close_exc}", file=sys.stderr)

    # 5. 干净收尾：删掉自己的 intent 行。
    #    崩在这之前会留下孤儿行——它**不是**「无害且自愈」（spec O4-F2）：
    #    孤儿行是一条销毁授权，靠 INTENT_TTL 收窄，靠 --init-cluster-marker 清理。
    # ⚠️ 到这一步库**已经 ready**。清理失败绝不能以裸异常逃出去（O4-R12-C2）：
    #    调用方会把它当成「建库失败」，而实际是一个可用的库 + 一行残留的销毁授权。
    #    判据也不是「DELETE 报了 1 行」而是「这一行**真的不在了**」（O4-R10-C1 起的教训：
    #    R9 那次回归里语句照发不误，只是一行都没匹配上）。
    try:
        status = await maint_conn.execute(_CLEAR_INTENT_SQL, db_name, run_id)
        detail = f"命令状态 {status!r}"
        cleared = str(status).strip() == "DELETE 1"
    except Exception as exc:
        detail, cleared = f"清理语句抛异常：{exc}", False
    if not cleared:
        # 读后验：DELETE 0 也可能只是「上一次已经删掉了」；异常也可能发生在提交之后。
        try:
            still_there = await maint_conn.fetchval(_INTENT_EXISTS_SQL, db_name, run_id)
        except Exception as exc:
            still_there, detail = True, f"{detail}；且复核该行是否存在也失败：{exc}"
        if still_there:
            raise PilotClusterBoundaryError(
                "intent_not_cleared",
                f"库 {db_name!r} **已经建好并 ready、可以正常使用**，但收尾清理它自己的 intent 行"
                f"没能成功（{detail}）——维护库里残留着一行「已确认」的销毁授权，"
                f"它会挡住后续以别的 run_id 重建，也是一张对同名空库的 DROP 授权。"
                f"请人工删除 public.pilot_create_intent 中 dbname={db_name!r} 的行。")


# ===========================================================================
# 4a-2 —— 库级五闸 + 零对象例外 + --reset-foreign 令牌（spec §3 子项③）
# ===========================================================================
# 闸的执行序列（spec §4，照闸表自上而下实现会原样重现 R56-F1 要修的锁死）：
#   集群闸 (i)(ii)(iii)
#     → 【零对象例外】六条 ─ 全成立 → 直接 DROP + 两阶段重建（**不进闸 0−/0/0b**）
#     → 闸 0−（仅对**已存在 pilot_meta 表**的库求值）
#     → 闸 0 → 闸 0b →（复用时另跑 闸 1 → 闸 2）

# ⚠️ **表在不在必须与形状分开求值**（spec O1-F6 收口）：`_PILOT_META_SHAPE_SQL` 的三个
#    EXISTS 全部走 `to_regclass('public.pilot_meta')`，表不存在时它返回 NULL →
#    三个 EXISTS 全 false —— 与「表在但 key 上没有唯一约束」**返回的东西一模一样**，
#    而形状 SQL 本身**不会抛异常**。故靠 `except Exception` 兜「表不存在」的写法在真 PG 上
#    永远走不到 except：一个别人建的、名字恰好撞上的非空库会被报成 `pilot_meta_ambiguous`
#    （「元数据自相矛盾，交给人查」），而正确的诊断是 `not_owned`（「不是本工具建的，请手工删」）。
#    两者给操作者的下一步动作不同，报告消费者也按这个码分诊。
_PILOT_META_PRESENT_SQL = "SELECT to_regclass('public.pilot_meta') IS NOT NULL"


async def read_pilot_meta(conn) -> dict[str, str]:
    """闸 0− —— `pilot_meta` 授权完整性（spec §4「闸 0− 的判据」，R80-F1）。

    它管的是「闸 0/0b **读到的值算不算数**」，故必须排在 0/0b **之前**，
    且 **DROP 与复用两条路径都跑** —— DROP 路径根本不跑闸 2，
    把 `pilot_meta` 的断言只放进闸 2 会让最危险的那条路径原封不动。

    ⚠️ 只对**已存在 `pilot_meta` 表**的库求值。表不存在这一档**不由 0− 处置**
       （否则残骸 + `--reset` 会在 0− 第一条就撞 `pilot_meta_ambiguous`
        「拒绝 DROP、库原样保留」→ **残骸永远清不掉**，spec O1-F5/O1-F6）。

    ⚠️ 形状判据**复用 `read_pilot_meta_rows`**，不得另写一份（spec §4 P1-F7：
       这条纪律此前「只落在了各自发现它的那个对象上」）。

    raises `PilotDbBoundaryError`，code ∈
      · `not_owned` —— 表不存在（这个库不是本工具建的）
      · `pilot_meta_ambiguous` —— 表在但形状不合规 / key 重复 / 授权键缺失
      · `target_db_unreadable` —— 连进去了但读不出来（spec P1r3-F6）
    """
    try:
        await pin_search_path(conn)
        present = await conn.fetchval(_PILOT_META_PRESENT_SQL)
    except Exception as exc:
        # ⚠️ **绝不兜成 not_owned**（spec P1r3-F6）：`ALTER DATABASE … ALLOW_CONNECTIONS false`
        #    做维护的库、权限被收走的库都落在这里，而 `not_owned` 给出的下一步动作是
        #    「不是本工具建的，请手工删」—— 错误且危险。
        raise PilotDbBoundaryError(
            "target_db_unreadable",
            f"连进目标库之后读 pilot_meta 是否存在就失败了（{exc}）——"
            f"无法证明任何事，一律 fail-closed：拒绝 DROP、拒绝复用") from exc
    if not present:
        raise PilotDbBoundaryError(
            "not_owned",
            "目标库没有 public.pilot_meta 表——它不是本次 pilot 建的。"
            "如确需删除请在 pilot 工具之外手工执行")
    try:
        seen = await read_pilot_meta_rows(conn)
    except PilotDbBoundaryError:
        raise                                  # 形状/重复键 → pilot_meta_ambiguous，原样上抛
    except Exception as exc:
        raise PilotDbBoundaryError(
            "target_db_unreadable",
            f"pilot_meta 表存在但读不出来（{exc}）") from exc

    # ⚠️ **NULL 值必须在这里拦下**（codex 4a-2a R5-F2）：形状判据只要求 `value` 是 text，
    #    没要求 NOT NULL。一张 `export_log_sha256 = NULL` 的 pilot_meta 过得了归属闸，
    #    随后 `_bound_identity` 在 `None[:12]` 上抛**裸 TypeError** ——
    #    一次正确的 fail-closed 守卫会被 4c 记成 FAIL_INFRASTRUCTURE（§9-1w 明令禁止），
    #    而 `derive_confirm_token` 也拿不到可用的原像。
    nulls = sorted(k for k, v in seen.items() if not isinstance(v, str))
    if nulls:
        raise PilotDbBoundaryError(
            "pilot_meta_ambiguous",
            f"pilot_meta 的 {nulls} 取到了非字符串值（多半是 NULL）——"
            f"归属/绑定/令牌都要从这些值里读，拒绝 DROP、拒绝复用，库原样保留")
    missing = [k for k in PILOT_META_AUTHORIZATION_KEYS if k not in seen]
    if missing:
        raise PilotDbBoundaryError(
            "pilot_meta_ambiguous",
            f"pilot_meta 缺少授权键 {missing}——闸 0/0b 正是从这些键里读值的，"
            f"缺一个就没有可信的归属/绑定判定。拒绝 DROP、拒绝复用，库原样保留")
    return seen


async def _open_target(maint_conn, connect, db_name: str):
    """打开一条到目标库的**短连接**并 `adopt_connection` 它。

    ⚠️ **连接生命周期由本模块持有，不是调用方的约定**（spec §4 规定 1）：
       集群闸 (ii) 与闸 0−/0/0b 都要连进目标库，而目标库自己就匹配 `kline_pilot_*`。
       只要有一条连接活着，随后的 `DROP DATABASE` 就会撞
       `is being accessed by other users` —— 真 PG 实测坐实，而 reset 是陈旧 schema 库的
       唯一出路。把「读完立即 close」写成调用方纪律等于没写：本模块自己开、自己关。

    ⚠️ 三件事一次做完（与 `create_pilot_database` 的目标连接同一条原则）：
       钉 `search_path` + 证明连的是这个**库名** + 同一台**集群** + 同一个**实例**。
       `expected_oid` 取自维护连接上的 `pg_database` —— 「本次运行说的那个库」由它定义。
    """
    try:
        cluster_id = await cluster_identity(maint_conn)
        # ⚠️ 复用 `_CREATED_DB_OID_SQL` 这个**捕获点**（它的职责就是「此刻这个名字对应
        #    哪个实例」），而不是新写一条按名字查 pg_database 的 SQL ——
        #    `test_every_pg_database_predicate_binds_to_an_instance` 会挡住后者。
        expected_oid = await maint_conn.fetchval(_CREATED_DB_OID_SQL, db_name)
    except Exception as exc:
        raise PilotDbBoundaryError(
            "target_db_unreadable",
            f"在维护连接上取 {db_name!r} 的实例 oid / 集群身份就失败了（{exc}）") from exc
    if expected_oid is None:
        raise PilotDbBoundaryError(
            "target_db_unreadable",
            f"{db_name!r} 不在 pg_database 里 —— 库级闸只对**已存在**的库求值；"
            f"库不存在时该走建库路径，走到这里说明调用方的分支判断与实际状态脱节了")
    try:
        conn = await connect(db_name)
    except Exception as exc:
        # ⚠️ 绝不当成「没查到对象」（spec P1r3-F6）：`datallowconn=false` /
        #    `datconnlimit=0` / 无 CONNECT 权限 / 正被别人删除都落在这里。
        raise PilotDbBoundaryError(
            "target_db_unreadable",
            f"连不进目标库 {db_name!r}（{exc}）—— 无法证明任何事，一律 fail-closed") from exc
    try:
        await adopt_connection(conn, db_name, cluster_id=cluster_id,
                               expected_oid=expected_oid)
    except BaseException:
        # 接管失败也要关掉，否则泄漏的会话会把之后的 DROP 顶住（O4-R24-C2）。
        await _close_quietly(conn, db_name)
        raise
    return conn, expected_oid


def _assert_seed_db_name(db_name: str, seed: str) -> None:
    """`db_name` 必须就是 `derive_db_name(seed)`（与 `create_pilot_database` 同一条判据）。

    两者脱钩时，闸判定的库与 DDL 实际作用的库不是同一个。
    """
    if derive_db_name(seed) != db_name:
        raise PilotDbBoundaryError(
            "seed_db_name_mismatch",
            f"db_name {db_name!r} 不是 seed {seed!r} 派生出来的")


async def _assert_ownership(meta: dict[str, str], *, seed: str) -> None:
    """闸 0 —— 归属（`tool` + `seed`）。这个库**能不能被我碰**。"""
    if meta.get("tool") != "qmt_pilot" or meta.get("seed") != seed:
        raise PilotDbBoundaryError(
            "not_owned",
            f"该库的 pilot_meta 说它属于 tool={meta.get('tool')!r} / seed={meta.get('seed')!r}，"
            f"而本次 seed={seed!r}——该库不是本次 pilot 建的。"
            f"如确需删除请在 pilot 工具之外手工执行")


def _binding_matches(meta: dict[str, str], *, export_log_sha256: str, output_dir: str) -> bool:
    """闸 0b —— 绑定（`export_log_sha256` + `output_dir`）。这个库**是不是我这套设置的**。

    ⚠️ `output_dir` 两边都去尾斜杠：建库时存进去的是 `output_dir.rstrip('/')`
       （见 `create_pilot_database` 的 values），不归一会让**同一套设置**的第二次运行
       被判成「别人的库」。
    """
    return (meta.get("export_log_sha256") == export_log_sha256
            and meta.get("output_dir") == output_dir.rstrip("/"))


def _bound_identity(meta: dict[str, str]) -> dict:
    """拒绝时打印给操作者看的「这个库绑的是谁」（spec §5：哈希前 12 位 / 目录 / 建库时间）。"""
    return {"export_log_sha256": meta.get("export_log_sha256", "")[:12],
            "output_dir": meta.get("output_dir"),
            "created_at": meta.get("created_at")}


# ── 闸 2：结构断言（复用纵深防御副闸，spec §4）───────────────────────────
# 「即便指纹相符，仍对 pilot 真正依赖的结构逐项断言」——防的是**指纹对但库被手工
# ALTER 过**。指纹只证明「建库时递进来的字节是哪一份」，证明不了「现在库里长什么样」。
#
# ⚠️ **业务表这五组必须写成白名单式的布尔，不能靠 information_schema**（O1-F1 同族）：
#    `information_schema.columns` 对物化视图/外部表的可见性各版本不一，
#    而这一闸的意义就是「被换过的东西要被看见」。
# ⚠️ **三张业务表必须先证明它自己是表**（relkind='r'）：一个列名列类型全对的**视图**
#    能过下面每一条列断言，而视图上的写入行为与表完全不同。
# ⚠️ pilot 表那两组**复用 `_PILOT_SCHEMA_SHAPE_SQL`**（建库时证明「apply 完
#    pilot_schema.sql 结构确实对」的同一份），不另写第二份：两份判据必然漂移，
#    而漏一条就是静默放行 —— 这正是本 PR 记录在案的「只修被点名的那一处」。
# ⚠️ 表清单**从 `REQUIRED_BUSINESS_TABLES` 派生**，不再手写三张（codex 4a-2a R1：
#    原来漏了 `stocks` —— 它是 klines 的外键目标，没了它导入必然失败，而闸照样放行）。
#    加第五张表时这里自动跟上，不用等下一个评审提醒。
_BUSINESS_STRUCTURE_SQL = f"""
SELECT
  (SELECT count(*) FROM pg_class c
    WHERE c.oid = ANY (ARRAY[{", ".join(f"to_regclass('public.{t}')" for t in REQUIRED_BUSINESS_TABLES)}])
      AND c.relkind = 'r') = {len(REQUIRED_BUSINESS_TABLES)}     AS business_tables_are_tables,
  (SELECT count(*) FROM pg_attribute a
    WHERE a.attrelid = to_regclass('public.klines') AND NOT a.attisdropped
      AND a.attnum > 0 AND a.attname IN ('open','high','low','close')
      AND format_type(a.atttypid, NULL) = 'double precision') = 4 AS klines_ohlc_double,
  EXISTS (SELECT 1 FROM pg_class c
           WHERE c.oid = to_regclass('public.stock_coverage')
             AND c.relkind = 'r')                                AS stock_coverage_present,
  EXISTS (SELECT 1 FROM pg_attribute a
           WHERE a.attrelid = to_regclass('public.training_sets')
             AND a.attname = 'file_path' AND NOT a.attisdropped
             AND format_type(a.atttypid, NULL) = 'text')         AS file_path_is_text,
  EXISTS (SELECT 1 FROM pg_attribute a
           WHERE a.attrelid = to_regclass('public.training_sets')
             AND a.attname = 'content_hash' AND NOT a.attisdropped
             AND a.attnum > 0)                                   AS content_hash_present,
  EXISTS (SELECT 1 FROM pg_constraint k
           WHERE k.conrelid = to_regclass('public.training_sets')
             AND k.conname = 'uq_stock_start' AND k.contype = 'u')
                                                                 AS uq_stock_start_present,
  -- ⚠️ **名字对不代表列对**（codex 4a-2a R1）：把 uq_stock_start 删掉、用同名但
  --    不同列重建，上一条照样为真 —— 而 already_done 与写入去重整个建立在
  --    (stock_code, start_datetime) 这一对列上。
  -- ⚠️ `attname` 的类型是 `name`，`array_agg` 出来就是 `name[]`；而右边的数组字面量是
  --    `text[]`，**PostgreSQL 没有这两者之间的相等操作符**（标量的 name = text 有，
  --    数组没有）。不转型的话这条不是「判假」而是**整条查询抛异常**，闸 2 于是在任何库上
  --    都兜成 target_db_unreadable，业务表五组判据一次都执行不到。
  --    假件层测不出来（按 SQL 子串派发预置字典，文本不进 PostgreSQL）——
  --    CI 上由 test_no_name_typed_catalog_column_is_aggregated_without_a_text_cast 拦住。
  EXISTS (SELECT 1 FROM pg_constraint k
           WHERE k.conrelid = to_regclass('public.training_sets')
             AND k.conname = 'uq_stock_start' AND k.contype = 'u'
             AND (SELECT array_agg(a.attname::text ORDER BY a.attname::text)
                    FROM pg_attribute a
                   WHERE a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey))
                 = ARRAY['start_datetime', 'stock_code'])        AS uq_stock_start_columns_ok
"""


async def _assert_structure(conn, meta: dict[str, str]) -> None:
    """闸 2 —— 七组结构断言（**只在复用路径跑**；`--reset` 时不跑，spec §4 闸分工表）。

    七组 = 业务表五组（`_BUSINESS_STRUCTURE_SQL`）+ pilot 两张表的形状
    （`_PILOT_SCHEMA_SHAPE_SQL`，与建库时同一份）+ `pilot_meta` 九键齐全。

    ⚠️ **九键齐全这一条只有 `created_at` 走得到**：`tool`/`seed` 归闸 0、两个绑定键归
       闸 0b、`state` 归 state 档、三个指纹键归闸 1。而 `created_at` 正是
       `confirm_token` 的原像 —— 它缺席时没有任何更早的闸会发现，
       直到某天要 `--reset-foreign` 才发现令牌派生不出来、库认不回自己。
    """
    for label, sql in (("业务表", _BUSINESS_STRUCTURE_SQL),
                       ("pilot 表", _PILOT_SCHEMA_SHAPE_SQL)):
        try:
            row = await conn.fetchrow(sql)
        except Exception as exc:
            raise PilotDbBoundaryError(
                "target_db_unreadable", f"闸 2 读{label}结构失败（{exc}）") from exc
        if row is None:
            raise PilotDbBoundaryError(
                "structure_mismatch", f"闸 2 的{label}结构查询没有返回行")
        bad = sorted(k for k, v in dict(row).items() if not v)
        if bad:
            raise PilotDbBoundaryError(
                "structure_mismatch",
                f"该库的{label}结构与 pilot 的依赖不符，不成立的判据：{bad}——"
                f"指纹只证明建库时递进来的字节，证明不了库现在长什么样。请用 --reset 重建")

    missing = [k for k in PILOT_META_KEYS if k not in meta]
    if missing:
        raise PilotDbBoundaryError(
            "structure_mismatch",
            f"pilot_meta 缺键 {missing}——闸 2 要求九个键一个不缺。请用 --reset 重建")

    # ⚠️ **建库时跑过的活体判据，复用前必须原样再跑一遍**（codex 4a-2a R1，high）：
    #    上面那几组只看「列在不在、类型对不对、约束名有没有」，看不见
    #    ①业务表上新装的触发器/规则/RLS/继承边（它们不动任何形状，却改写每一次导入）
    #    ②列/默认值/序列/表级属性的任意改动（活目录指纹才看得见）
    #    ③pilot 表上多出来的索引/约束/触发器
    #    只在建库路径跑的话，一个 ready 之后被改过的库照样通过复用闸，
    #    随后 B1/B2 在坏 schema 上读写 —— 而在 DB 边界拦下正是本闸存在的全部理由。
    await _assert_no_business_behavior_objects(conn, phase="复用前复查：")
    await _assert_no_pilot_table_dependents(conn, phase="复用前复查：")
    await _assert_live_catalog_matches_canonical(conn, phase="复用前复查：")


async def assert_db_allowed_for_reuse(
    maint_conn, *, connect, db_name: str, seed: str,
    schema_sha256: str, pilot_schema_sha256: str,
    export_log_sha256: str, output_dir: str,
) -> None:
    """复用路径：闸 0− → 0 → 0b → **state** → 1 → 2 全过才允许复用。

    ⚠️ `state == 'initializing'` 必须排在**闸 1（指纹）之前**（spec O4-F8）：
       阶段 1 只写 7 个键、`schema_sha256` 尚未写入，闸 1 会先撞「值不符」并报
       `schema_fingerprint_mismatch` → `db_state_initializing` 永远产不出来，
       恢复指引也从「用 --reset 重建」错成「schema 漂移」。
    """
    # ⚠️ 调用方标量先验（codex 4a-2 R13-F1）：它们**在碰目标库之前**就要 fail-closed，
    #    否则先连进去、先跑集群闸、最后才在 `.rstrip('/')` 上抛裸 AttributeError。
    assert_binding_scalars(export_log_sha256, output_dir)
    _assert_seed_db_name(db_name, seed)
    # ⚠️ **集群闸在每个 public 入口各自机器强制**（codex 4a-2a R6-F2）：
    #    它证明的是「这台集群是给 pilot 用的一次性环境」—— 没有它，一次接线失误就能
    #    在**生产集群**上批准复用/销毁，然后往里灌几百只股（spec §1 的风险 ①）。
    #    这几个函数都是 public 的，**不能靠调用方会先跑它**这条纪律。
    #    `create_pilot_database` 早就为同一条理由把它下沉进函数里（O4-R5-C2）；
    #    重复调用的代价只是几条只读查询，远小于「漏掉一次」的代价。
    await assert_cluster_allowed(maint_conn, connect=connect, target_db=db_name)
    conn, _oid = await _open_target(maint_conn, connect, db_name)
    try:
        meta = await read_pilot_meta(conn)                             # 闸 0−
        await _assert_ownership(meta, seed=seed)                       # 闸 0
        # 闸 0r —— **外部**归属凭据（codex 4a-2a R3-F1，user 拍板只加在复用路径）。
        # ⚠️ 闸 0 读的全是「被判对象自己写的字」；同侪库（闸 ii）早就因此要求两个独立
        #    事实（自证 + 维护库登记绑 oid），而目标库这一侧一直只有自证。
        #    这里补上同一条外部凭据：`_REGISTRY_HAS_SQL` JOIN 了 pg_database.oid，
        #    故「我们建过这个名字、库被删了、别人用同名重建」这一档会因 OID 不同而落空。
        # ⚠️ **刻意只加在复用路径，不加在 --reset**（user 拍板）：登记表在维护库里、
        #    本工具从不清它，一旦维护库被重新初始化，非空 pilot 库就再也清不掉了 ——
        #    那正是 spec 花整轮移除的 R55-F1 锁死。复用被拒时逃生口仍在：`--reset` 重建。
        #    这条不对称是**有意的**，test_reset_does_not_require_the_registry_proof 钉住它。
        try:
            registered = await maint_conn.fetchval(_REGISTRY_HAS_SQL, db_name,
                                                   meta.get("seed"))
        except Exception as exc:
            raise PilotDbBoundaryError(
                "registry_proof_missing",
                f"读维护库的归属登记失败（{exc}）——证明不了这个库是本工具建的，"
                f"拒绝复用。用 --reset 重建（reset 不要求这条外部凭据）") from exc
        if not registered:
            raise PilotDbBoundaryError(
                "registry_proof_missing",
                f"维护库的 pilot_database_registry 里没有绑到**这个实例**的 {db_name!r} "
                f"登记行——库里的 pilot_meta 是它自己写的字，单凭它证明不了归属。"
                f"要么这个库不是本工具建的，要么维护库的登记丢了；"
                f"两种情形的出路都是 --reset 重建（reset 不要求这条外部凭据）")
        if not _binding_matches(meta, export_log_sha256=export_log_sha256,
                                output_dir=output_dir):                # 闸 0b
            raise PilotDbBoundaryError(
                "binding_mismatch",
                f"该库绑定的是另一份源快照/输出目录（{_bound_identity(meta)}）——"
                f"请换 seed，或用 --reset 重建",
                identity=_bound_identity(meta))
        if meta.get("state") != "ready":                               # state（先于闸 1）
            raise PilotDbBoundaryError(
                "db_state_initializing",
                f"该库 state={meta.get('state')!r}，上次没跑完 apply schema——"
                f"一律拒绝复用，请用 --reset 重建")
        if (meta.get("schema_sha256") != schema_sha256
                or meta.get("pilot_schema_sha256") != pilot_schema_sha256
                or meta.get("contract_version") != CONTRACT_VERSION):  # 闸 1
            raise PilotDbBoundaryError(
                "schema_fingerprint_mismatch",
                "schema.sql / pilot_schema.sql / contract_version 与建库时不一致——"
                "请用 --reset 重建")
        await _assert_structure(conn, meta)                            # 闸 2
    finally:
        await _close_quietly(conn, db_name)


async def assert_db_allowed_for_reset(
    maint_conn, *, connect, db_name: str, seed: str,
    export_log_sha256: str, output_dir: str, reset_foreign_token: str | None,
) -> str:
    """`--reset` 路径的**判定**：闸 0− → 0 → 0b（不过则要令牌）全过才允许 DROP。

    **返回被判定的那个实例 oid** —— `DROP DATABASE` 带不了谓词，而判定与 DROP 之间
    同名库可以被删掉又重建。判定不绑实例，`--reset` 会去删一个**从未过闸**的替身
    （「凡是『这就是我那个库』的断言都要绑实例」的又一处落点）。

    ⚠️ **返回值同样不是授权、不是能力** —— 与 `try_empty_remnant_exception` 逐字同一条
       （codex S2a-R1-F1）：oid 是公开信息，本模块没有任何东西会因为收到它而去 DROP。
       真正销毁的 `reset_pilot_database`（S2b）自己调用本函数，结果留在函数内的局部变量里。

    ⚠️ **本函数不再交出「授权那一刻该库自称的身份」**（2026-08-12 塌缩，撤销 R3-F1 的
       `ResetGateOutcome`）。R3-F1 那条洞（靠绑定相符过的授权被别的身份的令牌接管）
       在塌缩之后**换了形态**：判定与 DROP 收进同一次调用，复验的判据是
       「拿**本次入参**在封锁下把本函数整个重跑一遍」——
       两种放行理由各自重新成立，取不到并集，也就不需要身份快照。
       而一个没有消费者的授权前提快照正是被删掉的那类负债。

    ⚠️ **这不是 `--reset` 的入口**（codex 4a-2a R6-F1）：它只覆盖「目标库有 `pilot_meta`」
       那一支。崩在 `CREATE DATABASE` 与写 `pilot_meta` 之间的**空残骸**根本没有那张表，
       在这里会撞 `not_owned`。spec §4 把「零对象例外 → 否则闸 0−」画成一条有向序列，
       那条逃生口是 `try_empty_remnant_exception`，**两步的次序焊在 S2b 的
       `reset_pilot_database` 函数体里** —— 调用方一律走那个唯一公开入口，
       不要自己拼这两步。

    ⚠️ **指纹闸与结构闸不参与 DROP 判定**（spec R49-F2）：闸的分工不可倒置——
       归属管「能不能碰」，指纹管「能不能直接用」。把指纹塞进 DROP 路径会让一个
       陈旧 schema 的库连 reset 都做不了，而 reset 是它唯一的出路。
       同理**不查 state、不查九键齐全**：崩在 apply schema 之前的库只有阶段 1 的 7 键。
    """
    # 同上（R13-F1）：破坏性路径上的调用方标量必须先 fail-closed。
    assert_binding_scalars(export_log_sha256, output_dir)
    _assert_seed_db_name(db_name, seed)
    # ⚠️ **先钉 search_path，再验锁**（codex 4a-2a R5-F1 —— R4 加这条检查时我把它放在了
    #    任何钉桩之前）：`_SEED_LOCK_HELD_SQL` 用的是不限定的 `pg_locks` /
    #    `pg_backend_pid()` / `hashtext()`，敌意或残留的 search_path 把一个可写 schema
    #    排在 `pg_catalog` 之前时，这三个名字都能被遮蔽 → **锁的证明返回 true 而锁并不存在**，
    #    R4 刚关上的破坏性窗口原样打开。
    #    本函数是 public 的、可被直接调用，**不能靠「调用方会先跑集群闸」这条
    #    调用方纪律**来保证钉桩 —— 那正是本 PR 反复修的同一个形态。
    await pin_search_path(maint_conn)
    # ⚠️ **集群闸在每个 public 入口各自机器强制**（codex 4a-2a R6-F2）：
    #    它证明的是「这台集群是给 pilot 用的一次性环境」—— 没有它，一次接线失误就能
    #    在**生产集群**上批准复用/销毁，然后往里灌几百只股（spec §1 的风险 ①）。
    #    这几个函数都是 public 的，**不能靠调用方会先跑它**这条纪律。
    #    `create_pilot_database` 早就为同一条理由把它下沉进函数里（O4-R5-C2）；
    #    重复调用的代价只是几条只读查询，远小于「漏掉一次」的代价。
    await assert_cluster_allowed(maint_conn, connect=connect, target_db=db_name)
    # ⚠️ **发放销毁授权之前先证明按 seed 的锁真被持有**（codex 4a-2a R4-F1）。
    #    `create_pilot_database` / `drop_pilot_database` / 零对象例外三处都验了它，
    #    唯独这条发放 DROP 授权的路径没验 —— 接线失误会让一次运行先 DROP 掉既有库、
    #    再在重建时撞 seed_lock_not_held，库没了而重建没做；
    #    同 seed 的两次运行也能一起挤进这段破坏性窗口。
    #    （本模块**不取锁**，只验它是否真被持有 —— spec O1-F4 + O4-R5-C2。）
    if not await maint_conn.fetchval(_SEED_LOCK_HELD_SQL, seed):
        raise PilotDbBoundaryError(
            "seed_lock_not_held",
            f"维护连接上没有持有 seed={seed!r} 的 advisory lock（①c）——"
            f"绝不在没有互斥的情况下发放 DROP 授权")
    conn, oid = await _open_target(maint_conn, connect, db_name)
    # ⚠️ 授权**不在 try 里 return**（codex R2-F1）：`finally` 关连接失败时，
    #    授权已经在路上了。改成「闸过 → 关连接 → 证明真关掉了 → 才交出 oid」。
    try:
        meta = await read_pilot_meta(conn)                             # 闸 0−
        await _assert_ownership(meta, seed=seed)                       # 闸 0
        if not _binding_matches(meta, export_log_sha256=export_log_sha256,
                                output_dir=output_dir):                # 闸 0b 不过
            _assert_reset_foreign_token(meta, reset_foreign_token)
    finally:
        closed = await _close_quietly(conn, db_name)
    _assert_target_released(closed, db_name)
    return oid


def _assert_reset_foreign_token(meta: dict[str, str],
                                reset_foreign_token: str | None) -> None:
    """闸 0b 不过时的令牌校验（spec §5：required / invalid 两个码可区分）。

    ⚠️ 令牌派生排在**分支之前**：`created_at` 不在四个授权键里、可以合法缺席，
       此时唯一诚实的答复是 `confirm_token_underivable`（提示人工删库），
       而不是拿空串硬算一个谁都填不对的令牌。
    """
    identity = _bound_identity(meta)
    token = derive_confirm_token(meta.get("export_log_sha256", ""),
                                 meta.get("output_dir", ""),
                                 meta.get("created_at", ""))
    # ⚠️ **令牌绝不进 message**（codex 4a-2a R3-F2；`PilotDbBoundaryError` 的契约与
    #    spec §9-1w 都写着它只走 `confirm_token` 这条专用通道）。
    #    任何把 `str(exc)` 写进报告/日志的调用方都会把它漏出去，
    #    于是 wrapper 可以「读报告取令牌再重跑」——「知情同意」退化成两步自动化。
    #    由 CLI 显式把 `exc.confirm_token` 打到 stderr 给人看。
    if reset_foreign_token is None:
        raise PilotDbBoundaryError(
            "reset_foreign_token_required",
            f"该库绑定的是另一套设置：{identity}。"
            f"确认要销毁它请重跑并带 --reset-foreign=<本次 stderr 打印的确认令牌>",
            identity=identity, confirm_token=token)
    if reset_foreign_token != token:
        raise PilotDbBoundaryError(
            "reset_foreign_token_invalid",
            "--reset-foreign 令牌与该库的确认令牌不符"
            "（正确的令牌只打印在 stderr，不进任何报告字段）",
            identity=identity, confirm_token=token)


# ── 零对象例外（spec §4「空库残骸的 reset 例外」，R56-F1 + P1r3-F2 + P1-F3 + O4-F2）──
# ⚠️ 两处都是硬要求（O4-R14-C2，计划片段此前**两条都漏**）：
#   · `public.` 限定 —— 不限定时敌意 search_path 能把这条读到另一张伪造表上（O4-R4-C1 同族）；
#   · 必须取 `create_confirmed` 并要求它为 true（O4-R8-C2）——
#     intent 行写在 `CREATE DATABASE` **之前**，未确认的行证明不了「这个库是本次建的」；
#     拿它当授权会去 DROP **别人建的**同名空库，无 pilot_meta 归属、无 --reset-foreign 令牌。
# ⚠️ 新鲜度只认**库自己的时钟**（O4-R23-C1）：年龄由 `statement_timestamp() - inserted_at`
#    在库里算出来，
#    调用方**给不进来**一个 `now`。`created_at` 是调用方传进来的字符串，数据库既不生成也不
#    校验 —— 很远的未来值让这行永远「新鲜」、永远抢不走；很远的过去值让活着的行立刻可被接管。
#    而这一行是 DROP 授权，有效期不能由调用方说了算。
#    （年龄取出来、TTL 的比较放在 Python：判据留在 host 层可测，时钟仍只有一个来源。）
# ⚠️ 凭据必须绑到**本次真的探测过的那个实例**：只按名字取，原库被删、别人用同名重建之后，
#    陈旧的行会为那个全新的、不是我们建的库背书 —— 而它是 DROP 授权（O4-R21-C1 / R25-C1）。
_READ_INTENT_SQL = """
SELECT i.seed, i.create_confirmed, i.db_oid::text AS intent_db_oid,
       EXTRACT(EPOCH FROM (statement_timestamp() - i.inserted_at)) AS age_seconds
  FROM public.pilot_create_intent i WHERE i.dbname = $1
"""


async def _has_qualified_intent_row(maint_conn, db_name: str, *, seed: str, oid: str) -> bool:
    """零对象例外第 6 条：有没有一行「新鲜、已确认、且绑在**这个实例**上」的凭据。

    ⚠️ 抽成一个函数是因为它有**两个**使用点（codex 4a-2/S2 R2-F1）：
       判定时判一次（`try_empty_remnant_exception`），DROP 前在封锁下**再判一次**
       （**S2b 的 `reset_pilot_database`**，本片不含）—— 这一条与【绝对空】一样会过期：
       凭据可以被别的运行清掉、被换成指向另一个实例的行、或者就是过了 TTL。
       两处各写一份判据必然漂移，而漂移的方向恰好会让复验那一处失去判别力
       —— 本仓记录在案的毛病。

    ⚠️ **年龄必须落在 `[0, TTL)`，负数一律判掉**（codex S2a-R2-F2）：
       `inserted_at` 由库自己的 `now()` 写入，正常情况下不可能在未来 —— 但**时钟回拨、
       从备份还原、人工修表**都会造出未来值。那时 `now() - inserted_at` 为负，
       只判上界的写法（`age < TTL`）会把它当成「刚写下的、最新鲜的」凭据，
       于是 TTL 把销毁授权窗口从「永久」收窄到 24h 这条保证（spec O4-F2）**整个失效**：
       一行不可能的时间戳换来一张永不过期的 DROP 授权。
    ⚠️ 判掉之后那个空残骸会**暂时清不掉**（时钟修好或 TTL 追上之前）——
       这是有意的取舍，不是 R55-F1 那种锁死：
       · 它是**自愈**的（时钟一正常就恢复），也不影响有 `pilot_meta` 的库
         （那些走闸 0−/0/0b，根本不看这一行）；
       · 而反方向的代价是**拿一个不可能的时间戳去 DROP 一个库**。
         在一条不可逆的路径上，宁可暂时拒绝。
    ⚠️ 抢占那一侧（`_INSERT_INTENT_SQL` 的 `>= $5`）不用改：负年龄在那里的效果是
       「抢不走这一行」，本来就是 fail-closed 的方向。两侧的不对称是**有意的**。

    ⚠️ **年龄两侧都不许取整**（codex S2a-R3-F1，真 PG 15 实测）：
       上一版在 SQL 里写 `::bigint`、在 Python 里再套一层 `int()` ——
       `::bigint` 是**四舍五入不是截断**（`(-0.1)::bigint = 0`），`int(-0.1)` 也是 0。
       于是一行「比 `now()` 早不到半秒」的**未来** `inserted_at` 会被算成 age 0，
       原样过掉上面那条下界检查 —— 下界这条修复整个被抹掉。
       两层取整都已去掉：SQL 返回原始的分数秒（PG 15 上是 `numeric` → `Decimal`），
       Python 直接比较。
       ⚠️ 安全增量诚实说只有半秒（真正危险的是**很远**的未来值，那一档一直判得掉）；
          修它的理由是**代码要和自己写下的保证一致** —— 本仓反复栽的
          「宣称的保证 > 实际提供的保证」正是这一类。
    """
    rows = await maint_conn.fetch(_READ_INTENT_SQL, db_name)
    return any(r["seed"] == seed
               and r["create_confirmed"]
               and r["intent_db_oid"] == oid
               and 0 <= r["age_seconds"] < INTENT_TTL_SECONDS
               for r in rows)


async def _probe_absolutely_empty(maint_conn, connect, db_name: str):
    """开一条短连接，adopt 它，问这个库是不是【绝对空】。

    返回 `(是否空, 实例 oid, 是否真的把连接关掉了)`。
    ⚠️ 第三项不是多余的（codex 4a-2a R2-F1 同族）：这条探测直接喂给零对象例外的判定，
       关不掉就意味着本进程还占着目标库的会话，随后的 DROP 会被它自己顶住。

    ⚠️ **读失败必须归一成 `target_db_unreadable`，不得裸逃**（codex S2a-R2-F2）：
       目标库被并发 DROP、权限变更、目录查询失败都会在 `_is_absolutely_empty` 里抛。
       这是本模块同一族判据的最后一处漏网 —— `read_pilot_meta`、闸 2 的结构查询、
       复用路径的活体判据（R2-F2）三处早就转了。裸异常会被 4c 兜成
       `FAIL_INFRASTRUCTURE`，而 spec §9-1w 明令禁止把一次成功的 fail-closed 守卫
       记成环境故障：操作者会去查基础设施，而真相是「这个库现在读不出来，拒绝销毁」。
    ⚠️ **读失败的结论不许被 close 失败顶掉**：与 `assert_db_allowed_for_reset` 那条
       「闸的结论不得被 close 失败顶掉」（O4-W2r1 M-2）是同一条规矩。
       两种情形都是拒绝（fail-closed），差别只在给出的下一步动作对不对。
       故本函数在读失败这条路上**不跑** `_assert_target_released`
       —— 调用方那两处照旧只在拿到 `closed` 之后跑，各自的判别力不受影响。
    """
    conn, oid = await _open_target(maint_conn, connect, db_name)
    try:
        empty = await _is_absolutely_empty(conn)
    except Exception as exc:
        raise PilotDbBoundaryError(
            "target_db_unreadable",
            f"连进 {db_name!r} 之后读【绝对空】判据失败（{exc}）——"
            f"证明不了它是不是空的，一律 fail-closed：拒绝销毁") from exc
    finally:
        closed = await _close_quietly(conn, db_name)
    return empty, oid, closed


async def try_empty_remnant_exception(
    maint_conn, *, connect, db_name: str, seed: str,
) -> str | None:
    """零对象例外的**判定** —— 返回**被判定的那个实例 oid**，不适用则返回 None。

    返回非 None = 六条**在判定这一刻**全成立 → 这个库走的是零对象例外那条路，
    **不进闸 0−/0/0b、不需要 `--reset-foreign`**（空库没有身份可确认、也没有数据可丢）。

    ⚠️⚠️ **返回值不是授权，也不是能力**（codex S2a-R1-F1 逼出来的措辞更正；
       上一版把它写成「被**授权销毁**的那个实例 oid」，那个措辞是错的）：
       · 它是一个 oid 字符串，而 oid 是**公开信息** —— 任何人一句
         `SELECT oid FROM pg_database WHERE datname = …` 就能拿到。
         交出它不给任何人任何它本来没有的东西。
       · 本模块里**没有任何东西**会因为收到这个值而去 DROP。
         真正执行销毁的是 `reset_pilot_database`（S2b），而它**不收**这个值 ——
         它自己调用本函数，把结果留在一个**函数内的局部变量**里。
         这正是 2026-08-12 塌缩要买的东西：判定与销毁之间没有可传递的对象。
       · 因此「拿到返回值 → 自己去 DROP」这条路的危险性**不在本函数**：
         那样的调用方要自己写 `DROP DATABASE`，而它绕过的是整个模块，
         不是绕过一道本模块能设的闸。Python 进程内不存在能力边界，
         本模块通篇的立场是「把纪律写成机制」，而不是假装私有名是机制
         —— 那正是这个洞前五轮加固失败的原因。

    ⚠️ **本函数证明的是判定那一刻的事实，而这些事实会过期**（这一点必须说死）：
       【绝对空】与 intent 凭据都可能在返回之后被改掉。把窗口关上的**唯一**地方是
       `reset_pilot_database` 的封锁临界区：它持住一条目标库连接、把库封成
       `CONNECTION LIMIT 0`、在封锁下**重查**【绝对空】+ intent 凭据 + 实例 oid，
       然后在**不放开那条连接**的情况下走到 DROP。
       ⛔ **本片（S2a）里那段临界区不存在** —— 它随 S2b 落地。
       故在本片，本函数的返回值只证明「判定成立过」，不证明任何时刻的可销毁性。

    六条（**当且仅当**全部成立）：
      1. 本次带 `--reset`（由调用方保证：不带 `--reset` 时根本不调用本函数）
      2. 库名**恰等于** `kline_pilot_<seed>`（**全等**不是前缀——把爆炸半径限制在本次 seed）
      3. 该库满足**【绝对空】**（白名单式的 `_user_objects`，物化视图逃不过）
      4. 集群闸 (i)(ii)(iii) 已全过 —— **本函数自己跑，不收调用方的保证**（见下）
      5. ①c 的按 seed advisory lock **在活连接上真被持有**（O4-R5-C2：不收调用方的布尔）
      6. 维护库 `public.pilot_create_intent` 有本次库名的行、`seed` 相符、
         **`create_confirmed = true`**、**`db_oid` 就是本次探测到的那个实例**、
         且按**库时钟**算的年龄未超 `INTENT_TTL_SECONDS`

    **并且**：DROP 之前须**紧贴着**重查一次【绝对空】（第 3 条与 DROP 之间不可原子；
    真 PG 实测 `pg_restore --create` 存在「库已建、表还没建」的空窗）。

    ⚠️ 判定时**不删**超期行 —— 普通运行不该替别的 seed 做决定（spec O4-F2 修正②）。
       清理只在 `--init-cluster-marker` 里做，且须逐行 `pg_try_advisory_lock`。
    """
    # 同上（R5-F1 同族）：本函数也是 public 的，验锁前先把名字解析钉死。
    await pin_search_path(maint_conn)
    # 2. 库名全等（不是前缀）
    if db_name != derive_db_name(seed):
        return None
    # ⚠️ **第 4 条在这里机器强制**（codex 4a-2b R1-F1；2026-08-12 塌缩后落到本函数）：
    #    这一条此前由 `authorize_reset` 代跑，而那个入口连同整套凭据机器已被删除。
    #    不下沉的话，第 4 条就退回成「写在 docstring 里、由调用方保证」——
    #    一次接线失误就能在**未过集群闸**的情况下拿到销毁授权：
    #    标记闸、无关库闸、维护库空闸全部被跳过，而这条路径的下一步是不可逆的
    #    `DROP DATABASE`。`create_pilot_database` 与 `assert_db_allowed_for_reset`
    #    早就为同一条理由把它下沉进各自函数里（O4-R5-C2 / 4a-2a R6-F2），本函数是第三处。
    #    ⚠️ 排在库名全等**之后**：名字不是本次 seed 的库，本函数的答复恒为「例外不适用」，
    #       不授权任何东西，没有理由为它去连一遍同侪库；而名字一旦相符，
    #       后面每一步都可能通向授权，集群闸必须先过。
    await assert_cluster_allowed(maint_conn, connect=connect, target_db=db_name)
    # 5. 按 seed 的锁**真被持有**
    if not await maint_conn.fetchval(_SEED_LOCK_HELD_SQL, seed):
        return None
    # 3. 【绝对空】
    empty, oid, closed = await _probe_absolutely_empty(maint_conn, connect, db_name)
    # ⚠️ **每一次探测之后都要证明会话已释放，不只是「例外成立」那条路**（codex 4a-2b R2-F2）：
    #    判空为「非空」时本函数返回 None，调用方随后落到闸 0−/0/0b ——
    #    而本模块自己那条没关掉的会话仍活着，最后的 DROP 会以
    #    「target_db_in_use，占用者是别人」失败，而那个「别人」就是我们自己。
    _assert_target_released(closed, db_name)
    if not empty:
        return None
    # 6. 新鲜、已确认、且绑在**这个实例**上的 intent 行
    if not await _has_qualified_intent_row(maint_conn, db_name, seed=seed, oid=oid):
        return None
    # DROP 前紧贴着重查一次；同时确认**还是刚才那个实例**（`_open_target` 会绑 oid）。
    empty_now, oid_now, closed_now = await _probe_absolutely_empty(
        maint_conn, connect, db_name)
    # 同上：**无论复查结论如何**都要先证明会话已释放（codex 4a-2b R2-F2）。
    _assert_target_released(closed_now, db_name)
    if not empty_now or oid_now != oid:
        return None
    return oid


# ── ⛔ 这里曾经有一整套「可传递的销毁授权凭据」，2026-08-12 被删除 ────────────
#
# 被删掉的是：能力哨兵、授权登记表、凭据类、铸造函数，以及把它们串起来的那个
# `--reset` 单一入口，外加把「授权那一刻的身份」带出函数的那个具名返回值。
#
# ⚠️ **为什么值得在生产代码里记这一笔**：那套机器不是一次设计失误，是**五轮加固**的
#    产物 —— 同一个洞被 codex 连提六次（4a-2b R4-F2 → R6-F1 → R7-F1 → R14-F2 →
#    S2-R2-F1 → S2a-R1-F1），修法依次是「改私有 → 加构造哨兵 → 使用点查类型 →
#    改查登记表 → 加仓库级 AST 守卫」，**每一次都被下一轮拆穿**。
#
#    根因不在加固不够狠。DROP 前要重验的每一条都能**从目标库的活状态重新推导**：
#    名字、seed 锁、集群闸、占用者、oid、【绝对空】、intent 凭据、`pilot_meta` 归属。
#    唯独「绑定是否与**调用方递进来的**标量相符 / `--reset-foreign` 令牌对不对」
#    推导不出来 —— 它依赖一个库里没有的事实：*这次运行的调用方是谁、他说了什么*。
#    于是那一条只能靠「授权时记下来的东西」，而那个东西正是伪造者控制的入参：
#    **凭据本身就是那条前提的唯一载体，加固凭据永远堵不上它。**
#
#    修法是让缝消失，而不是给缝加锁：判定与 DROP 收进 S2b 的 `reset_pilot_database`
#    **一个函数体**，来路退化成函数内的局部变量，伪造不了；绑定/令牌那一条直接拿
#    **本次调用的入参**在封锁下重验，不再有「记下来的事实」。
#
#    本片（S2a）因此只剩**判定 helper**：`assert_binding_scalars` /
#    `try_empty_remnant_exception` / `_has_qualified_intent_row` /
#    `assert_db_allowed_for_reset`。它们回答「这个库能不能碰」，**不发放任何东西**。
#    「零破坏性能力」于是是**结构上的** —— 不再是「有凭据但暂时没人消费」这种偶然。
#
#    ⚠️ spec §4 那条有向序列（集群闸 → 零对象例外 → 否则闸 0−/0/0b）**本片不再有任何
#       东西机器强制**：它随 `reset_pilot_database` 的函数体在 S2b 落地。
#       本片能证明的只是这两步在同一份 fixture 上给出相反的判定
#       （test_the_empty_remnant_escape_hatch_is_the_only_thing_that_can_clear_a_remnant）。
#       这是本片**明写接受的残留**，不是遗漏。
