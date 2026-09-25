"""守卫：可执行路径里每一条 `INSERT INTO training_sets` 的【列清单】都必须含 `schema_version`。

⭐ 为什么要紧：PostgreSQL 那一列是 `schema_version INTEGER NOT NULL DEFAULT 1`
   （`backend/sql/schema.sql:75`）—— 漏写**不会报错**，会**静默**把行标成第 1 代。
   作用域里**唯一真正往生产库写行**的是 `_register_training_set`
   （`backend/generate_training_sets.py:554-567`），其余全是彩排 / 烟测 / 提及。

⛔ **判据是「`schema_version` 是不是列清单里的一个【列名】」** —— 既不是「它在某段文本里出现过」，
   **也不是「它是列清单的子串」**（见 `_column_names` 的说明：子串判据会被 `old_schema_version` 假通过）。
   这一版是整支对抗性评审 C1 打回后重写的。上一版「从命中点切到下一个 `;`，找不到就往后
   取 2000 字符，然后在这段文本里搜词」对那条唯一的生产语句**零判别力**：它是 Python
   字符串拼的、**整条 SQL 里没有分号**，窗口于是吞进了下面那行实参 `gts.schema_version`
   —— 把字段从 SQL 列清单里删掉，守卫**照样放行**（spec §3.3 / B23 明令必须变红的那条变异）。
   ⛔ 而且上一版把失效方向**说反了**（写「窗口取长更容易发现缺字段」）：判据是
   `not in`，**窗口越长子串越可能命中，越容易【假通过】**。

⛔ **不写「真 SQL 只有 N 种形状」这类穷尽性断言**（评审 M3）：本文件只**认得**下面几种，
   **认不出的形状默认归宿是「响」**（`unknown` 必报），不是「静默放行」。
   ⚠️ **准确说法**（R2-M1 / R4-M1 两轮打回后订正）：认不出**且列清单解析得出来**的形状归宿是「响」；
   而**解析不出列清单、又恰好被引号包住**的会被当成「提及」**静默跳过** —— 这是本守卫**已知的静默通道**。
   ⛔ 因此**不得**写〔废〕「其余一律必报」这类全称断言。已知的静默通道逐条列在残留 2（**不写总数**）。
   · 带列清单（含 `AS t` / 裸别名 / `public.` 前缀 / 多空白 / 大小写任意）→ 解析列清单；
   · 不带列清单（`VALUES` / `SELECT` / `DEFAULT` / `OVERRIDING` 紧跟）→ **一律必报**
     （按位置插入 ⇒ **本守卫不接受这种写法**）；
   · 整体被同一种引号或反引号包住 → 只是**提及**（Python 字符串谓词、markdown 反引号）；
   · **其余**（例如 `INSERT INTO training_sets WITH …`）→ **必报为「未知形状」**。

⛔ **排除项按结构判、不按数量判**：spec 对「共有几处」这个计数连栽三轮，而上一片（P3c）
   写的一句文档字符串又让命中数 +1。故本文件**不写任何总数**。
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# ⛔ 作用域 = spec §3.3 亲自枚举的三类【可执行】路径。
_SCOPE_DIRS = [REPO_ROOT / "backend",
               REPO_ROOT / "docs" / "runbooks",
               REPO_ROOT / ".github" / "workflows"]
# ⚠️ 后缀白名单是**静默**盲区：日后往作用域里放 `.txt` / `.env` / `.psql` 之类
#    同样会被执行的文件，会被悄悄漏掉、不报错。新增后缀必须回来补。
_SUFFIXES = (".py", ".sql", ".sh", ".md", ".yml", ".yaml")

# ⛔ **今天真正承载 `INSERT INTO training_sets` 的（目录, 后缀）格子** —— 逐个写死。
#    锚点要求**每个格子至少 1 条**；少了任何一个都说明「这类文件静默退出视野了」。
#    ⚠️ 这是**集合式**判据，不是计数判据：本仓成文教训说「某某共 N 处」这种**含自身的
#    总数**会连栽（每写一句关于它的话，数就大一），但这里写死的是**格子的身份**、
#    不是条数，不随论述文本漂移。
_EXPECTED_CELLS = (
    ("backend", ".py"),             # generate_training_sets.py —— 唯一真写生产库那条
    ("backend", ".sh"),             # 0004 迁移彩排 rehearse.sh
    ("docs/runbooks", ".md"),       # NAS 部署手册 P9 两条烟测
    ("docs/runbooks", ".sql"),      # P11 导入脚本
    (".github/workflows", ".yml"),  # schema-smoke 五条约束烟测
)

# ⚠️ 三条正则的大小写策略必须一致 —— 上一版 needle 不带 `re.I` 而形状正则带，
#    导致 `re.I` 在整条链路上是装饰品（小写写法在第一步就丢了）。
# ⚠️ 表头允许标识符带双引号（`INSERT INTO "training_sets"` / `"public"."training_sets"`）——
#    整支评审 R2-M1：上一版对这两种写法**零命中**，整条语句静默漏掉。
# ⛔ **词元之间可以夹注释**（codex attest 对抗性评审实测的【静默放行】，本片唯一一条
#    5 轮 Opus 定向复评 + 整支最终评审 + 控制者全部自查**都没碰到**的洞）：
#    PostgreSQL 允许把注释塞在关键字之间 —— 下面三种都是**合法语句**，pglast 能正常
#    解析出列清单，而上一版 `_HEAD` 用 `\s+` 连接词元 ⇒ **一条都匹配不到**：
#        INSERT /* seed */ INTO training_sets (…)
#        INSERT INTO /* x */ training_sets (…)
#        INSERT -- x⏎INTO training_sets (…)
#    ⛔ **为什么这是静默的**：`findall`（守恒等式的第二来源）与 `finditer`（主循环）
#    用的是**同一个** `_HEAD` ⇒ 两边同时看不见它 ⇒ 命中数 == 四桶之和仍然成立、
#    `lost` 为空 ⇒ 守恒等式**也接不住**。实测：真删掉一处字段 + 在表头夹一句注释
#    ⇒ 三条测试 `3 passed`，而对照组（只删字段）是 `1 failed`。
#    ⭐ 这正是本仓成文教训「**换通道会挖出旧通道十几轮没碰到的 Critical**」的又一例。
# ⚠️ 修法是让**词元间隔**本身认注释，⛔ 不是「先把整份文件的注释屏蔽掉再匹配」——
#    后者会引入一条**新的**静默通道：`.md` 里一个没闭合的 `/*` 会把其后全部内容
#    屏蔽掉，真语句跟着消失。
_HEAD = re.compile(r'INSERT\s+INTO\s+(?:"?[A-Za-z_][\w$]*"?\s*\.\s*)?"?training_sets"?\b', re.I)


class _Span:
    """只暴露 `start()` / `end()`，好让下游代码与 `re.Match` 一样用。"""
    __slots__ = ("_a", "_b")

    def __init__(self, a: int, b: int):
        self._a, self._b = a, b

    def start(self) -> int:
        return self._a

    def end(self) -> int:
        return self._b


_INSERT_KW = re.compile(r"\bINSERT\b", re.I)
_INTO_KW = re.compile(r"\bINTO\b", re.I)
_IDENT_BARE = re.compile(r"([A-Za-z_][\w$]*)")
_IDENT_QUOTED = re.compile(r'"([A-Za-z_][\w$]*)"')


def _ident(text: str, i: int):
    """取一个标识符，返回 `(名字, 结束位置)`；取不到返回 `(None, i)`。

    ⛔ **引号必须成对才吃**（实测打回）：写成 `"?name"?` 的话，
       `if "INSERT INTO training_sets" in query:` 这种**合法提及**里，
       表名后面那个**属于 Python 字符串的**引号会被一起吃掉 ⇒ 结束位置越过了引号 ⇒
       `_classify` 的「两侧都是引号才算提及」判据失效 ⇒ 本该判「提及」的落进
       【认不出的形状】、变成**误报**。
    """
    if i < len(text) and text[i] == '"':
        m = _IDENT_QUOTED.match(text, i)
        return (m.group(1), m.end()) if m else (None, i)
    m = _IDENT_BARE.match(text, i)
    return (m.group(1), m.end()) if m else (None, i)


def _skip_gap(text: str, i: int):
    """从 `i` 起跳过空白与注释（**块注释嵌套感知**）。返回新位置；未闭合则返回 None。"""
    n = len(text)
    while i < n:
        if text[i].isspace():
            i += 1
            continue
        if text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth += 1; i += 2
                elif text.startswith("*/", i):
                    depth -= 1; i += 2
                else:
                    i += 1
            if depth:
                return None          # 未闭合
            continue
        break
    return i


def _heads(text: str):
    r"""找出所有表头。返回 `(_Span 列表, 是否在某个表头里撞到未闭合块注释)`。

    ⛔ **不能用正则「在间隔里允许注释」**（codex attest 第 2 轮实测的静默放行）：
       正则**不认嵌套**。`/\*.*?\*/` 遇到
         `INSERT /* outer /* inner */ INTO training_sets (schema_version) */ INTO training_sets (stock_code, file_path)`
       会在**内层** `*/` 收手，于是把**被注释掉的假列清单** `(schema_version)` 当成真的读；
       而 PostgreSQL 把整段外层注释吃掉、真实列清单是 `['stock_code','file_path']`（**真漏写**）
       ⇒ **静默放行**。⭐ 根因是本仓成文教训「**订正只落在两份等价副本中的一份**」——
       我已经有嵌套感知的 `_mask_sql_comments`，却在表头另写了个不认嵌套的正则。

    ⛔ **也不能「把整份文件按 SQL 注释规则屏蔽掉再匹配」**（实测打回）：
       作用域里的 `.py` / `.yml` / `.md` **根本不是 SQL**，`/*` 在它们里面只是普通字符。
       实测仓内**有 14 个文件**含没有配对 `*/` 的 `/*`（正则字面量、正文叙述等）——
       整份屏蔽会把它们其后的内容整片吞掉，**真语句跟着消失**。
    ⇒ 故这里**只从每个 `INSERT` 关键字往后走一小段**，手写扫描器逐字符消注释，
       其余文本一个字都不碰。
    """
    heads, unterminated = [], False
    for km in _INSERT_KW.finditer(text):
        i = _skip_gap(text, km.end())
        if i is None:
            unterminated = True
            continue
        m_into = _INTO_KW.match(text, i)
        if not m_into:
            continue
        i = _skip_gap(text, m_into.end())
        if i is None:
            unterminated = True
            continue
        name, end = _ident(text, i)
        if name is None:
            continue
        # 可选的 schema 限定前缀：`public.training_sets`
        if name.lower() != "training_sets":
            j = _skip_gap(text, end)
            if j is None:
                unterminated = True
                continue
            if j >= len(text) or text[j] != ".":
                continue
            j = _skip_gap(text, j + 1)
            if j is None:
                unterminated = True
                continue
            name, end = _ident(text, j)
            if name is None or name.lower() != "training_sets":
                continue
        heads.append(_Span(km.start(), end))
    return heads, unterminated
_NO_COLS = re.compile(r"\s*(VALUES|SELECT|DEFAULT|OVERRIDING)\b", re.I)
_ALIAS = re.compile(r"\s*(?:AS\s+)?(?!VALUES\b|SELECT\b|DEFAULT\b|OVERRIDING\b)[A-Za-z_]\w*", re.I)
# ⭐ 允许跨过**引号标识符表名的闭合引号**（`INSERT INTO "training_sets" (…)` —— `_HEAD`
#    的 `\b` 会把匹配尾停在那个 `"` **之前**，不跨过去就找不到左括号），以及 Python
#    相邻字面量拼接留下的缝隙。
# ⚠️ 上一版这里写「生产语句正是这种写法」是**错的**（整支最终评审「次要 2」实测）：
#    生产语句 `"INSERT INTO training_sets (stock_code, …"` 的左括号只是**紧跟一个空格**，
#    拼接缝在列清单**内部**（由 `_column_names` 剥孤引号处理），根本不经过这个字符类。
#    实测把本正则收窄成 `\s*\(` ⇒ 主判据**仍绿**，红的是差分测试里那条引号表名用例。
_OPEN_PAREN = re.compile(r"[\s\"'\\+,)]*\(")
_QUOTES = "\"'`"

_SELF = Path(__file__).resolve()


def _iter_files():
    for d in _SCOPE_DIRS:
        if not d.is_dir():
            raise AssertionError(f"作用域目录不存在：{d} —— 是不是被改名/移走了？")
        for q in sorted(d.rglob("*")):
            # ⚠️ `Dockerfile` 没有后缀，但 PR-2 容器化之后它**是真的可执行路径**
            #    （一句 `RUN psql -c "INSERT INTO training_sets (…)"` 就在视野之外）。
            if q.is_file() and (q.suffix in _SUFFIXES or q.name.startswith("Dockerfile")) \
                    and "__pycache__" not in q.parts:
                if q.resolve() != _SELF:
                    yield q


def _mask_sql_comments(s: str) -> tuple[str, bool]:
    r"""把 SQL 注释替换成**等长空格**（⛔ 不是删除 —— 保长才不会打乱偏移量与行号）。

    ⛔ **块注释在 PostgreSQL 里【可以嵌套】**（Task 3 定向复评用 `pglast`
       ——真·PG 解析器——实测确认；⚠️ 控制者上一轮自查**推错了**，只是碰巧
       挑到了非贪婪正则能处理的那种嵌套排列）。非贪婪的
       `re.sub(r"/\*.*?\*/", ...)` 会在**第一个** `*/` 就收手，把剩下的注释
       尾巴当成真内容。实测**假通过（危险方向）**：
         `INSERT INTO training_sets (/* /* */ schema_version */ stock_code, file_path)`
         pglast 真实列清单 = ['stock_code', 'file_path'] ⇒ **真缺失**，
         旧版守卫却判「含 schema_version」⇒ **放行**。
    ⚠️ 返回 `(屏蔽后的文本, 是否有未闭合的块注释)`。**未闭合必须回传出去**：
       屏蔽是「一路盖到末尾」，若无声吞掉，其后的真语句会跟着消失 ⇒ **静默漏扫**。
       调用方（`_scan`）据此报一条**响亮**的问题。PostgreSQL 自己也会
       `ParseError: unterminated /* comment`，两边都是响亮失败。
    """
    out = list(s)
    i, n, depth = 0, len(s), 0
    while i < n:
        if depth == 0 and s.startswith("--", i):
            j = s.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if s.startswith("/*", i):
            depth += 1
            out[i] = out[i + 1] = " "
            i += 2
            continue
        if depth > 0 and s.startswith("*/", i):
            depth -= 1
            out[i] = out[i + 1] = " "
            i += 2
            continue
        if depth > 0:
            out[i] = " "
        i += 1
    return "".join(out), depth > 0


def _column_list(text: str, pos: int) -> str | None:
    """从 `pos` 起找列清单的左括号，**括号配平**取出里面的文本。取不到返回 None。

    ⛔ **必须在【屏蔽注释之后】的文本上配平**（Task 3 定向复评「重要」）：
       注释里一个裸 `)` 会把列清单**提前截断** ⇒ 合规语句被误报成缺字段。
       实测（pglast 核对）：
         `INSERT INTO training_sets (stock_code, /* oops ) extra */ schema_version, file_path)`
         PG 眼里是三列、**合规**；旧版守卫把 cols 截断成 `stock_code, /* oops ` ⇒ **报缺**。
       ⭐ 顺带闭合了「表名与列清单之间夹注释」那处误报（原先落「认不出的形状」）。
    ⚠️ 返回的是**原文**切片（给报错信息看），判据那边会自己再屏蔽一次。
    """
    masked, _ = _mask_sql_comments(text[pos:])
    m = _OPEN_PAREN.match(masked, 0)
    if not m:
        return None
    depth, i = 0, m.end() - 1
    while i < len(masked):
        if masked[i] == "(":
            depth += 1
        elif masked[i] == ")":
            depth -= 1
            if depth == 0:
                return text[pos + m.end():pos + i]
        i += 1
    return None                      # 括号没配平 ⇒ 交给「未知形状」必报


def _top_split(x: str) -> list[str]:
    """顶层逗号切分：括号内的逗号（函数实参等）不算。"""
    out, d, cur = [], 0, ""
    for ch in x:
        if ch == "(":
            d += 1
        elif ch == ")":
            d -= 1
        if ch == "," and d == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


def _column_names(cols: str) -> set[str]:
    """把列清单切成**列名集合**（小写）。

    ⛔ **判据必须是【列名精确相等】，不能是子串 `"schema_version" in cols`**
       —— 控制者自查发现（R4 轮）：子串判据会被 `old_schema_version`、
       `schema_version_legacy`、甚至「列清单里的注释提到它」**假通过**。
       ⭐ 这正是本仓成文教训「裸子串 `= 1` 会被 `= 12` 满足，必须加词界」的同一个形状
       —— 而那条教训是本片作者在上一片（P3a）亲手写下的。
    ⚠️ 要吃得下生产语句那种 Python 拼接后**残留引号**的列清单
       （`… end_datetime, "\n        "schema_version, …`）。
    """
    # ⛔ **块注释必须先剥**（Task 3 评审阻断项）：只剥 `--` 会让两个方向同时坏掉 ——
    #   · **假通过（危险方向）**：`… content_hash /*, schema_version */` 是**真漏写**，
    #     但块注释里那个逗号会被 `_top_split` 切一刀，切出的 ` schema_version */`
    #     被下面的 `re.match` 从头认成**真列名** ⇒ 守卫**放行**；
    #   · **误报**：`(stock_code, /* 第2代 */ schema_version, …)` 本来合规，但该段以 `/`
    #     开头、`re.match` 不匹配 ⇒ **真列名整个丢失** ⇒ 守卫报缺。误报会把人推向
    #     「干脆把它排除掉」，而那正是把缺口原样留下的路径。
    #   ⭐ 两个方向各由变异 M4i / M4j 钉住。
    #   ⛔ 补充（定向复评阻断项）：**非贪婪正则修不好这件事** —— PG 的块注释可嵌套，
    #     正则会在第一个 `*/` 收手、把注释尾巴当真内容（pglast 实测的假通过）。
    #     ⇒ 必须用 `_mask_sql_comments`（嵌套感知 + 保长）。
    #   ⭐ 四个方向分别由变异 M4i / M4j / M4m / M4n 钉住。
    cols, _ = _mask_sql_comments(cols)
    names = set()
    for part in _top_split(cols):
        part = part.strip()
        # ⛔ **区分两种引号**（第三轮定向复评「重要」—— 控制者上一版写下
        #    「这两件事直接冲突、必须二选一」，复评**实测证明该理由不成立**）：
        #    · **成对包裹整段**的 `"…"` ⇒ 真·SQL **引号标识符**：逐字、大小写敏感、
        #      内部空格有意义。`"schema_version "` / `"Schema_Version"` 在 PG 眼里
        #      都是**另一个列**（pglast 核实），必须判「不含」。
        #    · **孤零零一个**引号 ⇒ 多半是 **Python 相邻字面量拼接**留下的噪声
        #      （生产语句是 `… end_datetime, "\n        "schema_version, …`），
        #      它不是 SQL 语法的一部分，抹掉即可。
        #    ⇒ 两者**形状不同**，可以同时照顾到。实测生产语句解析出的 7 个列名
        #      与改动前**逐字相同** —— 不存在「必须二选一」。
        if len(part) >= 2 and part[0] == '"' and part[-1] == '"':
            names.add(part[1:-1])
            continue
        # ⛔ **必须整段匹配（`fullmatch`），不能只匹配前缀**（第二轮定向复评）：
        #    `re.match` 只要开头像标识符就收下，于是 `schema_version★` 被当成
        #    `schema_version` ⇒ **假通过**（pglast 实测该列真名是 `schema_version★`）。
        bare = part.replace('"', " ").strip()
        m = re.fullmatch(r"([A-Za-z_][\w$]*)\s*", bare)
        if m:
            names.add(m.group(1).lower())      # 裸标识符：PG 会折叠成小写
    return names


def _classify(text: str, a: int, b: int):
    """(a, b) = 表头匹配的起止。返回 ('cols', 列清单) / ('nocols',None) / ('mention',None) / ('unknown',None)

    ⛔ **顺序不能反：先试 SQL，试不成才判「提及」**（整支评审 R2-M1）。
       上一版先按「整体被引号包住」判提及，结果把**最常见的 Python 拼接写法**
       `q = "INSERT INTO training_sets" " (a, b) VALUES ($1,$2)"` 判成提及、**静默漏掉**
       —— 而那恰恰是生产语句最可能被重构成的样子。
       倒过来之后：这种写法的列清单能解析出来 ⇒ 判为真语句；而 `if "…" in query:`
       解析不出列清单 ⇒ 才落到「提及」。三处合法提及实测仍判对。
    """
    if _NO_COLS.match(text, b):
        return ("nocols", None)

    m = _ALIAS.match(text, b)        # 可选别名：INSERT INTO x AS t (...) / INSERT INTO x t (...)
    if m:
        if _NO_COLS.match(text, m.end()):
            return ("nocols", None)
        cols = _column_list(text, m.end())
        if cols is not None:
            return ("cols", cols)

    cols = _column_list(text, b)
    if cols is not None:
        return ("cols", cols)

    # 试不成 SQL，才看是不是被引号/反引号整体包住的**提及**
    before = text[a - 1] if a > 0 else ""
    after = text[b] if b < len(text) else ""
    # ⛔ `before`/`after` 必须先判非空：Python 里 `"" in "\"'`"` 是 **True**
    #    （空串是任意串的子串）⇒ 语句恰好顶在文件首/尾时那一侧恒判「是引号」，
    #    本该报【认不出的形状】的会被**静默跳过**（整支最终评审「次要 3」）。
    if before and after and before in _QUOTES and after in _QUOTES:
        return ("mention", None)
    return ("unknown", None)


def _scan(files, root):
    """扫一批文件，返回 `(missing, positional, unknown, checked, per_cell)`。

    ⛔ **这份代码必须被【真实扫描】与【合成自测】共用** —— 否则
       「**上报动作被整个拔掉**」这一类腐化**无人可挡**：变异 M4f 的发现机制
       自己也要经过这条上报线，会**一起失效**。
       实测（Task 3 第二轮定向复评）：把下面 `missing.append(...)` 整行换成
       `pass`，再注入一条**真漏写**，主测试与差分测试**双双 `2 passed`**。
       ⇒ 那一类腐化在上一版里**没有任何东西钉着**，而文档却声称 M4f 管得了。
       现在由 `test_enforce_actually_raises_on_violations` 单独钉住。
    """
    missing, positional, unknown, checked = [], [], [], 0
    per_cell = {c: 0 for c in _EXPECTED_CELLS}
    lost, bad_comment = [], []

    for q in files:
        try:
            text = q.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError) as e:
            # ⛔ 不把「读不了」混进「不是目标」：读不了必须**响**。
            raise AssertionError(f"作用域内的文件读不了，无法判定：{q} —— {e}") from e

        rel = q.relative_to(root).as_posix()
        # ⛔ **守恒等式，不是存在式**（整支最终评审「重要 1」）：
        #    此前所有防掏空判据都是「**至少一条**」形状（`checked >= 2`、每个格子 >= 1、
        #    `gen_seen >= 1`）—— 它们挡得住「整类文件退出视野」，**挡不住「同一个文件里
        #    少看几条」**。实测：把下面那行循环改成 `for m in list(_HEAD.finditer(text))[:1]:`
        #    （一处单点编辑），再往 `rehearse.sh` 第 2 条语句里真删掉 `schema_version` ⇒
        #    守卫、合成自测、差分测试**三条全绿**（对照组：只注入真漏写 ⇒ 红）。
        #    ⭐ 本仓成文教训：「『这几个各自存在』抓不到『多出来的第五个』⇒ 用集合等式」。
        # ⚠️ `expected_hits` 必须是**独立的第二次扫描**（故意用 `findall`，⛔ 不复用下面的
        #    `finditer` 结果）—— 两个来源互不依赖，一处编辑才改不掉两边。
        _hits, _unterminated = _heads(text)
        if _unterminated:
            # ⛔ 未闭合的块注释会把其后全部内容屏蔽掉 ⇒ 真语句静默消失。必须**响**。
            bad_comment.append(rel)
        expected_hits = len(_hits)
        bucketed = 0

        for m in _heads(text)[0]:
            where = f"{rel}:{text.count(chr(10), 0, m.start()) + 1}"
            kind, cols = _classify(text, m.start(), m.end())
            bucketed += 1          # ⛔ 四类**都要**计数，含「提及」—— 否则等式对不上
            if kind == "mention":
                continue
            if kind == "nocols":
                positional.append(where)
            elif kind == "unknown":
                unknown.append(where)
            else:
                checked += 1
                for _d in _SCOPE_DIRS:
                    if q.is_relative_to(_d):
                        _cell = (_d.relative_to(REPO_ROOT).as_posix(), q.suffix)
                        if _cell in per_cell:
                            per_cell[_cell] += 1
                        break
                if "schema_version" not in _column_names(cols):
                    missing.append(f"{where}  列清单={cols.strip()[:120]}")

        if bucketed != expected_hits:
            lost.append(f"{rel}：表头命中 {expected_hits} 条，却只有 {bucketed} 条被判过")
    return missing, positional, unknown, checked, per_cell, lost, bad_comment


def _enforce(files, root):
    """扫一批文件 → 组装问题清单 → **抛出**。整条链路**只有这一份代码**。

    ⛔ **为什么把组装与最终 `assert` 也收进来**（Task 3 第三轮定向复评「重要」）：
       前两轮各修一次，同一类腐化**每次只是往调用栈上层挪一层**又原样复现 ——
       第 1 轮拔掉 `missing.append`、第 2 轮拔掉 `_scan` 外面的组装。实测三种写法
       （`missing = []` 局部丢弃 / `if missing:` 短路成 `if False:` /
       `assert not problems` 改成 `assert True`）**叠加真缺陷注入后全部 `3 passed`**。
       ⇒ 再补第 4 层测试只会把边界又推高一层。**解法是把层数塌掉**：让
       `test_enforce_actually_raises_on_violations` 走的就是这一个函数，
       于是「组装/抛出被短路」会**同时**让那条合成自测变红。

    ⛔ **一条判据都不许带开关**（第四轮定向复评「重要」）：上一版用
       `real = (root == REPO_ROOT)` 决定要不要跑锚点类判据，结果**改一个实参就能关掉** ——
       实测把调用处的 `REPO_ROOT` 换成 `REPO_ROOT.parent`（祖先路径，不崩、`real` 静默
       变 `False`），再叠加「`_SUFFIXES` 去掉 `.sh` + 真删 `rehearse.sh` 一处字段」⇒ **全绿**。
       而我当时还写下「这种改动远比 `if` 被改成 `if False` 显眼」—— **那句话是错的**，
       它在 diff 里只是换了一个词。
       ⇒ 现在**全部无条件执行**：`root` 只参与**显示文字**（`where` 的路径前缀），
       **不参与任何判决**。于是「改实参」这条路**由构造消失** —— 改了也不影响判定。
       ⚠️ 合成小树跑的时候，格子锚点当然全为 0 ⇒ 会**额外**报一条「有一类文件…」，
       这不碍事：合成自测本来就期待它**抛异常**，且该条对那次运行**确实成立**。
       ⭐ 反过来这还让合成自测**顺带钉住**了 `blind` 与 `checked` 这两条分支。
    """
    missing, positional, unknown, checked, per_cell, lost, bad_comment = _scan(files, root)

    problems = []
    # ⛔ **未闭合的块注释排在最前**：它会让其后的真语句整片消失，
    #    此时别的判据报什么都不作数。
    if bad_comment:
        problems.append(
            "【有未闭合的块注释】`/*` 没有配对的 `*/` ⇒ 其后的内容会被整片当成注释，"
            "真语句会**静默消失**（PostgreSQL 也会报 unterminated comment）：\n  "
            + "\n  ".join(bad_comment))
    # ⛔ **守恒等式排在最前**（整支最终评审「重要 1」）：它报的是「**发现端**被掏空了」——
    #    有命中却没被判过。这种时候后面那些判据的「全都合规」都是**没有意义的**。
    if lost:
        problems.append(
            "【有命中却没被判过】表头匹配到了，却没落进任何一类 —— 说明**发现端**被掏空了"
            "（例如扫描循环被截断）。⛔ 此时「全都合规」这个结论不成立：\n  "
            + "\n  ".join(lost))
    # ⛔ 防空转：一条列清单都没解析到 ⇒ 作用域或解析坏了，而不是「全都合规」。
    if checked < 2:
        problems.append(
            f"【解析不到列清单】只解析到 {checked} 条 —— 作用域或括号配平坏了，"
            "⛔ 这不是「全都合规」。")
    blind = [f"{d}  下的 {sfx} 文件" for (d, sfx), n in per_cell.items() if n == 0]
    if blind:
        problems.append(
            "【有一类文件一条语句都没解析到】它多半被后缀白名单/改名悄悄移出了视野，"
            "而守卫会照样报「全都合规」：\n  " + "\n  ".join(blind))
    # ⚠️ **本片唯一一条【没有常驻测试钉住】的分支**，如实写明，⛔ 不含糊带过：
    #    合成小树造不出「真实生产文件里的语句脱离视野」这个场景（它读的是真文件），
    #    所以只有变异 **M4w**（把生产 SQL 头抽成变量）能证伪它。
    #    ⭐ 但**已实测量过这个残留有多大**：把本分支短路成 `if False:` 再施加 M4w ⇒
    #    守卫**仍然红**，由格子锚点接住（`backend/.py` 那一格掉到 0）。
    #    ⇒ 短路它**不会造成静默放行**，只会丢掉一条**更精确的报错信息**。
    gen_src = (REPO_ROOT / "backend" / "generate_training_sets.py").read_text(encoding="utf-8")
    gen_seen = sum(1 for m in _heads(gen_src)[0]
                   if _classify(gen_src, m.start(), m.end())[0] == "cols")
    if gen_seen < 1:
        problems.append(
            "【生产语句脱离视野】`backend/generate_training_sets.py` 里一条都认不出 "
            "`INSERT INTO training_sets` 的列清单 —— 唯一真正写生产库的那条语句本守卫"
            "已经看不见了（多半是 SQL 被重构成变量拼接 / f-string / 搬去了别处）。"
            "⛔ 这不是「它没问题」，是「守卫看不见它了」。")

    # ⛔ **各类问题必须一次全报，不能用多条 assert 串起来**：只要前一条炸了，
    #    后面的就永远执行不到 —— 而 `missing` 才是本守卫的**招牌判据**。
    #    本仓成文教训：「断言顺序导致招牌判据从未执行」。
    if unknown:
        problems.append(
            "【认不出的形状】必须由人来定性（是真语句就补 `schema_version` 并把该形状加进判据；"
            "是提及就说明理由）：\n  " + "\n  ".join(unknown))
    if positional:
        problems.append(
            "【不写列清单、按位置插入】**本守卫不接受这种写法**，必须改成显式列清单：\n  "
            + "\n  ".join(positional))
    if missing:
        problems.append(
            "【列清单里没有 `schema_version`】PostgreSQL 会用 `DEFAULT 1` **静默**把行标成第 1 代，"
            "而所有闸门照样绿：\n  " + "\n  ".join(missing))

    assert not problems, (
        f"`INSERT INTO training_sets` 守卫发现 {len(problems)} 类问题：\n\n"
        + "\n\n".join(problems))


def test_enforce_actually_raises_on_violations(tmp_path):
    """⭐ 证明**上报这条线**本身没坏 —— 拿一棵**合成的小树**喂给同一份 `_scan`。

    为什么必须单独有这一条（Task 3 第二轮定向复评「重要」）：上一版在文档里写
    「装配线被改坏由变异 M4f 负责」，**这是过度承诺**。M4f 靠的正是这条上报线，
    线断了它自己也不响 —— 实测双双变绿。⇒ 本测试把
    「**判据判出违规 ⇒ 必须被记录并抛出**」这件事**单独**钉住，
    三条上报动作（`missing` / `positional` / `unknown`）**各自**都断不得。
    """
    cases = {
        "bad.sql": "INSERT INTO training_sets (stock_code, file_path) VALUES (1,2);\n",
        "good.sql": "INSERT INTO training_sets (stock_code, schema_version, file_path) VALUES (1,2,3);\n",
        "nocols.sql": "INSERT INTO training_sets VALUES (1,2);\n",
        # ⭐ **同一个文件里放两条**（整支最终评审「重要 1」）：此前所有合成用例都是
        #    「一个文件一条」，于是「每个文件只看第 1 条命中」这种截断**对合成自测完全无感**。
        #    第 1 条合规、第 2 条真漏写 ⇒ 截断一发生，第 2 条就消失，本测试立刻红。
        "two.sql": ("INSERT INTO training_sets (stock_code, schema_version) VALUES (1,2);\n"
                    "INSERT INTO training_sets (stock_code, file_path) VALUES (1,2);\n"),
        "weird.sql": "INSERT INTO training_sets WITH c AS (SELECT 1) SELECT 1;\n",
    }
    files = []
    for name, body in cases.items():
        q = tmp_path / name
        q.write_text(body, encoding="utf-8")
        files.append(q)

    import pytest

    with pytest.raises(AssertionError) as excinfo:
        _enforce(files, tmp_path)
    msg = str(excinfo.value)

    # ⛔ 逐条钉住：三类问题**各自**都必须被组装进报文并抛出来。
    #    少任何一条，说明从「判出违规」到「最终抛出」这条链路上有一段被短路了。
    # ⛔ **必须断言「哪个文件落进哪一类」，不能只断言两者都出现过**
    #    （控制者第五轮自查）：只查「字样在不在」的话，把 `_scan` 的返回值
    #    `missing` 与 `positional` **对调**（一次看起来无害的重构）⇒ 两个字样
    #    都还在、断言照样通过，只是**归错了类别**。实测那样改之后本测试仍绿。
    #    ⇒ 改成按「类别标题之后紧跟的那一段」逐条核对归属。
    def _block(title):
        i = msg.index(title)
        j = min([msg.index(t, i + 1) for t in _TITLES if t in msg[i + 1:]] or [len(msg)])
        return msg[i:j]

    _TITLES = ("【列清单里没有", "【不写列清单、按位置插入", "【认不出的形状",
               "【有一类文件一条语句都没解析到", "【解析不到列清单", "【生产语句脱离视野")
    for title, want in (("【列清单里没有", "bad.sql:1"),
                        ("【列清单里没有", "two.sql:2"),
                        ("【不写列清单、按位置插入", "nocols.sql:1"),
                        ("【认不出的形状", "weird.sql:1")):
        assert title in msg, f"⛔ 报文里缺类别「{title}」—— 上报/组装/抛出这条链路被短路了：\n{msg}"
        assert want in _block(title), \
            f"⛔ 「{want}」没落进「{title}」这一类（多半是 `_scan` 的返回值错位了）：\n{msg}"
    # ⭐ 锚点判据无条件执行之后，合成树（格子全为 0）会**顺带**报这一条 ——
    #    于是这条断言把 `if blind:` 那个分支也一并钉住了。
    assert "有一类文件一条语句都没解析到" in msg, \
        f"⛔ 格子锚点没响 —— `if blind:` 那个分支被短路了：\n{msg}"
    # 合规那条**不得**被报进来（否则是误报方向坏了）
    assert "good.sql" not in msg, f"⛔ 合规语句被误报了：\n{msg}"

    # ⭐ 空输入 ⇒ 必须报【解析不到列清单】，⛔ 不能报成「全都合规」。
    #    这条钉住 `if checked < 2:` 那个分支（本仓成文教训：报 0 违反必须先证明能报非 0）。
    with pytest.raises(AssertionError) as empty_exc:
        _enforce([], tmp_path)
    assert "解析不到列清单" in str(empty_exc.value), \
        f"⛔ 空输入没触发防空转：\n{empty_exc.value}"


def test_every_executable_insert_carries_schema_version():
    """每一条真 `INSERT INTO training_sets` 的列清单里都必须有 `schema_version`。

    ⚠️ **本函数刻意只有一行** —— 判据、组装、抛出全在 `_enforce` 里，与合成自测
       `test_enforce_actually_raises_on_violations` **共用同一份代码**。
       ⛔ 这是三轮定向复评逼出来的形状：此前每修一次，「上报/组装/抛出被短路」
       这一类腐化就往调用栈上层挪一层再出现一次。塌成一条路径之后，那条链路上
       **任何一段**被短路，合成自测都会变红。
    ⛔ **仍然接不住的残留 —— 精确表述**（⚠️ 上一版在这里写的话**被实测证伪过两次**，
       所以这一版只写实测过的）：把下面这一行**整个删掉/换成 `pass`**。
       仓内守卫无法自证（本仓成文教训「仓内守卫可被同一个 PR 改掉、本仓没有信任根」），
       只能靠**人看 diff**。
       ⛔ **不再声称「这比改一个 `if` 显眼」** —— 第四轮定向复评实测打脸：
       把实参 `REPO_ROOT` 换成 `REPO_ROOT.parent` 同样能造成静默失效，而它在 diff 里
       只是换了一个词，一点也不显眼。⇒ 那条路已由「**判据不带任何开关**」在构造上关死
       （`root` 只参与显示文字、不参与判决），不再依赖「显眼不显眼」这种主观判断。
    """

    _enforce(_iter_files(), REPO_ROOT)


# ─────────────────────────────────────────────────────────────────────────────
# ⭐⭐ 差分测试：拿**真 PostgreSQL 解析器**当裁判
#
# 为什么要有这一条（两轮评审各挖出一个阻断项，**根因是同一个**）：
#   第 1 轮阻断 = 块注释没剥；第 2 轮阻断 = 块注释**可嵌套**而非贪婪正则修不好。
#   两次都是**手写变异挡不住**的 —— 手写变异只能覆盖「作者想得到的失效形态」，
#   而这两个洞恰恰都是作者没想到的那一类。控制者自查时甚至**推错过 PG 的语义**，
#   只因碰巧挑到了正则能处理的那种嵌套排列。
#   ⇒ 唯一结构性的解法：**别再由人写期望值**，让 `pglast`（PostgreSQL 官方语法的
#     Python 绑定）说这条语句的列清单到底是什么，守卫必须与它逐条一致。
#
# ⚠️ `pglast` 在本仓**已是被证明可用的 CI 依赖**：`requirements-test.txt:4` 固定
#    `pglast==7.13`，`.github/workflows/backend-tests.yml:37` 装的正是它，且
#    `test_migrations.py` / `test_schema.py` 早已在用 —— ⛔ 不是新引入的可选依赖。
# ─────────────────────────────────────────────────────────────────────────────

_DIFFERENTIAL_CASES = (
    # 块注释家族
    "INSERT INTO training_sets (/* /* */ schema_version */ stock_code, file_path) VALUES (1,2)",
    "INSERT INTO training_sets (stock_code, file_path /* x /*, schema_version */ y */) VALUES (1,2)",
    "INSERT INTO training_sets (stock_code, /* /* /* */ */ */ schema_version, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, file_path /*, schema_version */) VALUES (1,2)",
    "INSERT INTO training_sets (stock_code, /* 第2代 */ schema_version, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, /* oops ) extra */ schema_version, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, /* ( 不配对 */ schema_version, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, /**/ schema_version, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code,/*c*/schema_version,file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, schema_version/*第2代*/, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, file_path /* -- , schema_version */) VALUES (1,2)",
    "INSERT INTO training_sets (stock_code, schema_version, file_path -- /* x\n) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, file_path\n  /*, schema_version\n  暂时去掉 */) VALUES (1,2)",
    "INSERT INTO training_sets (stock_code, file_path /*,*/ , schema_version) VALUES (1,2,3)",
    "INSERT INTO training_sets /* 目标表 */ (stock_code, schema_version, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets -- 注释\n (stock_code, schema_version, file_path) VALUES (1,2,3)",
    # 合规写法 —— 必须放行（误报会把人推向「干脆排除掉它」）
    'INSERT INTO training_sets (stock_code, "schema_version", file_path) VALUES (1,2,3)',
    "INSERT INTO training_sets AS t (stock_code, schema_version, file_path) VALUES (1,2,3)",
    "INSERT INTO public.training_sets (stock_code, schema_version, file_path) VALUES (1,2,3)",
    'INSERT INTO "training_sets" (stock_code, schema_version, file_path) VALUES (1,2,3)',
    "insert into training_sets (stock_code, schema_version, file_path) values (1,2,3)",
    "INSERT\n  INTO\ttraining_sets\n  (stock_code,\n   schema_version,\n   file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, schema_version, file_path) SELECT a,b,c FROM x",
    "INSERT INTO training_sets (stock_code, schema_version, file_path) VALUES (1,2,3) "
    "ON CONFLICT (stock_code) DO UPDATE SET schema_version = 2",
    # ⭐ 表头里夹注释（codex attest 挖出的静默放行）—— 这三条同时钉住 `_HEAD` 的
    #    词元间隔认不认注释：若退回 `\s+`，`_HEAD` 零命中 ⇒ 本测试开头那句
    #    `assert m, "表头正则没命中，这条用例是空转的"` **当场炸**。
    "INSERT /* seed */ INTO training_sets (stock_code, file_path) VALUES (1,2)",
    "INSERT INTO /* x */ training_sets (stock_code, schema_version, file_path) VALUES (1,2,3)",
    "INSERT -- x\nINTO training_sets (stock_code, file_path) VALUES (1,2)",
    # ⭐⭐ codex attest 第 2 轮挖出的那条：**嵌套**表头注释里藏了一个**假列清单**。
    #    PG 把整段外层注释吃掉 ⇒ 真实列清单是 (stock_code, file_path)、**真漏写**；
    #    而不认嵌套的正则会在内层 `*/` 收手，把被注释掉的 `(schema_version)` 当成真的读。
    "INSERT /* outer /* inner */ INTO training_sets (schema_version) */ "
    "INTO training_sets (stock_code, file_path) VALUES (1,2)",
    "INSERT /* a /* b /* c */ */ */ INTO training_sets (stock_code, file_path) VALUES (1,2)",
    "INSERT /* a /* b */ */ INTO training_sets (stock_code, schema_version, file_path) VALUES (1,2,3)",
    "INSERT INTO public /* x */ . /* y */ training_sets (stock_code, file_path) VALUES (1,2)",
    'INSERT /* x */ INTO "training_sets" (stock_code, file_path) VALUES (1,2)',
    # 引号标识符：PG 眼里是**另一个列**（逐字、大小写敏感、内部空格有意义）
    'INSERT INTO training_sets (stock_code, "schema_version ", file_path) VALUES (1,2,3)',
    'INSERT INTO training_sets (stock_code, "Schema_Version", file_path) VALUES (1,2,3)',
    # 标识符边界：`★` 不是 `\w`，前缀匹配会把它当成 `schema_version` ⇒ 假通过
    "INSERT INTO training_sets (stock_code, schema_version★, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, schema_version中文, file_path) VALUES (1,2,3)",
    # 真漏写 —— 必须报（含子串陷阱）
    "INSERT INTO training_sets (stock_code, old_schema_version, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, schema_version_legacy, file_path) VALUES (1,2,3)",
    "INSERT INTO training_sets (stock_code, file_path) SELECT a,b FROM x",
    # PG 自己就解析不了 —— 守卫只需「不放行」
    "INSERT INTO training_sets (stock_code, file_path /*, schema_version) VALUES (1,2)",
)


def test_guard_agrees_with_real_postgres_parser():
    """守卫对每条语句的判定，必须与**真 PostgreSQL 解析器**逐条一致。

    ⛔ **期望值不由人写** —— 由 `pglast` 现场解析得出。这是本测试的全部意义：
       手写期望值会把作者的错误理解一起写进来（控制者就推错过一次 PG 的注释语义）。

    ⚠️ **它接得住什么、接不住什么**（⛔ 实测过，不是推测 —— 本仓成文教训要求把
       「这条判据接不住哪些腐化」写清楚，别让人以为它兜住了全部）：
       · **接得住**：`_HEAD` / `_classify` / `_column_names` 这一层被改坏 ——
         实测把注释处理退回「非贪婪正则」「完全不剥」「配平时不屏蔽」三种旧形态，
         本测试**逐条变红**并直接打印出是【假通过·危险】还是【误报】。
       · ⛔ **接不住**：**`_scan` 那条装配线**被改坏 —— 本测试自己直接调
         `_column_names`，根本不走 `_scan`。分两种，**由不同的东西钉住**：
           ① 判据被换成裸子串（`not in cols`）⇒ 由变异 **M4f**（注入
              `old_schema_version`）证伪；
           ② ⛔ **上报动作被整个拔掉**（`missing.append(...)` → `pass`）⇒ **M4f 也
              一起失效**（它的发现机制走的就是这条线；实测注入真漏写后双双变绿）
              ⇒ 由 `test_enforce_actually_raises_on_violations` 用**合成小树**证伪。
         ⚠️ 上一版把 ② 也算在 M4f 头上，是**过度承诺**（第二轮定向复评实测打回）。
    """
    import pglast

    def pg_columns(sql):
        """PG 眼里这条 INSERT 的列清单；PG 自己解析不了则返回 None。"""
        try:
            stmt = pglast.parse_sql(sql)[0].stmt
        except Exception:
            return None
        return [c.name for c in (stmt.cols or [])]

    mismatches, guard_said = [], set()
    truths = set()
    for sql in _DIFFERENTIAL_CASES:
        _hs, _ = _heads(sql)
        m = _hs[0] if _hs else None
        # ⛔ 防空转：表头没命中 ⇒ 这条用例**从未被判过**，等于白写。
        assert m, f"表头正则没命中，这条用例是空转的：{sql!r}"
        kind, cols = _classify(sql, m.start(), m.end())
        verdict = ("schema_version" in _column_names(cols)) if kind == "cols" else None
        guard_said.add(verdict)

        pg_cols = pg_columns(sql)
        if pg_cols is None:
            # PG 解析不了 ⇒ 两边都该是响亮失败；只要求守卫**不放行**。
            if verdict is True:
                mismatches.append(f"[PG 解析不了却被放行] {sql!r}")
            continue
        truth = "schema_version" in pg_cols
        truths.add(truth)
        if truth and verdict is not True:
            mismatches.append(
                f"[误报] PG 说合规（列清单={pg_cols}），守卫却判 {verdict!r}：{sql!r}")
        if not truth and verdict is True:
            mismatches.append(
                f"[假通过·危险] PG 说缺字段（列清单={pg_cols}），守卫却放行：{sql!r}")

    # ⛔ 防恒真（本仓成文教训「报 0 违反必须先证明它能报非 0」）：
    #    用例表里必须**两种真相都有**，守卫也必须**两种判定都给过** ——
    #    否则这条差分测试可能只是在比对两个恒定值。
    assert truths == {True, False}, f"用例表退化了：PG 真相只出现了 {truths}"
    assert {True, False} <= guard_said, f"用例表退化了：守卫只给出过 {guard_said}"

    assert not mismatches, (
        f"守卫与真 PostgreSQL 解析器不一致，共 {len(mismatches)} 条：\n  "
        + "\n  ".join(mismatches))
