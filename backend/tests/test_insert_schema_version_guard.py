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

import ast
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

# ─────────────────────────────────────────────────────────────────────────────
# ⭐⭐⭐ 宿主解码层：`_scan` 喂给 `_heads` 的必须是**运行时字符串**，不是源码原文
#
# `.py` / `.sh` / `.yml` / `.md` 里的 SQL 是**字符串**，而源码原文与运行时真正
# 交给 PostgreSQL 的字符串不是一回事。实测（三个预言机逐条核实，见
# `test_guard_sees_the_runtime_sql_not_the_source_text`）**10 条缺陷**：
#   · 8 条【整条消失】—— `_heads` 连表头都没找到（相邻字面量在 INSERT/INTO 后断开、
#     劈开表名、`\n` 转义、`--` 配转义换行、常量相加劈开表名、shell 引号拼接劈开表名）；
#   · 1 条【假通过】—— 块注释定界符被劈成 `/"` + `"*`，假注释里含 `schema_version`
#     字样，源码上按逗号切 token 会把它当成真列名；
#   · 1 条【误报】—— 合法的 `(stock_code, sch" "ema_version, file_path)` 被报缺字段。
#
# ⛔ **`.py` 不猜、直接解**：用 Python 自己的语法树把字面量解出来 —— `ast` 会把
#    相邻字面量**折叠成一个常量**、把转义序列还原，得到的就是运行时那串字符。
#    这不是「多认一种写法」，是把问题从**猜**变成**解**。
# ⚠️ `ast` 解不动的（f-string 的变量部分、`.format()`、`%`、与变量相加）**不会静默
#    消失**：由 `_nonliteral_targets` 报「判不了」（吵），不是「瞎」。
# ⛔ **`.sh` / `.yml` / `.md` 不做解码** —— 那些宿主没有便宜的精确解，而「跑一遍
#    shell 让它自己拼」在守卫里是**绝对不可以**的（有副作用）。那一侧只补
#    `_split_name_heads`：把「表名被宿主引号/拼接劈开」认出来并报「判不了」。
# ─────────────────────────────────────────────────────────────────────────────

#: f-string 等**求不出来**的插值的占位。取一个绝不会出现在 SQL 标识符里的字符，
#: 于是它自然落进「`INSERT INTO` 后面不是字面量表名」那条判据。
_UNRESOLVED = "\x00"

#: 「这里有东西求不出来」的**可枚举**标记：f-string 插值的哨兵 · `.format()` 的 `{}` ·
#: 百分号格式化的 `%` · shell 变量的 `$`。出现在**表名区段**或**列清单**里都意味着
#: 「判不了」—— ⛔ 不是「缺字段」。
_COLS_MARKERS = (_UNRESOLVED, "{", "%", "$")


#: ⛔⛔ **最后一张网：完全不解析间隔。**
#:
#: `_heads` / `_split_name_heads` / `_nonliteral_targets` **三者共用同一个 `_skip_gap`**
#: —— 它只跳空白与 SQL 注释。间隔里一出现**宿主拼接痕迹**（引号 / 续行反斜杠），
#: 三张网就**一起落空** ⇒ 语句静默消失。实测两条（bash 现场吐出参数 + pglast 核实，
#: 都是合法 SQL 且列清单确实缺 `schema_version`）：
#:     psql -c "INSERT "" INTO training_sets (…) VALUES (…);"
#:     psql -c "INSERT \<换行> INTO training_sets (…) VALUES (…);"
#:
#: ⭐ 这与「粗网和精确网共用间隔解析器 ⇒ 所谓兜底根本不存在」是**同一条根**：
#:   只要所有网都靠同一个间隔解析器，它坏掉时就没有地板。
#: ⇒ 这张网**只认三个词**，中间允许任何字符，⛔ 但不许跨 `(` `)` `;`。
#:   不许跨括号是被干净树上的误报逼出来的：
#:       INSERT INTO p15_targets (id) SELECT id FROM training_sets
#:   这是往**另一张表**写的合法语句，中间的 `(id)` 正好把它排除掉。
#: ⚠️ 它只用来报「判不了」，不参与「通过」的判定 ⇒ 宁可宽一点。
#: ⚠️ 只用于**没解码**的宿主（`.py` 已由 `ast` 正面解开，再补一遍会重复报）。
#: ⚠️ 先量后做：实测在非 `.py` 宿主的干净树上**多报 0 条**。
_LR_SPAN = r"(?:(?![(;)])[\s\S])"
#: 表名被劈开时中间只可能是「下划线 / 空白 / 宿主引号 / `+` / 续行反斜杠」。
#: ⛔ 这里**不能**用 `_LR_SPAN`（任意字符）—— 实测它会把 runbook 里的**文件路径**
#:    `/data/training-sets/000001.SZ_….zip` 当成表名（中间是连字符）。
_LR_NAME = r"[\s_\"'+\\]"
_LAST_RESORT_RE = re.compile(
    # ⛔ **间隔不设字符上限。** 原先是 400/200 —— 间隔一长就够不着 ⇒ 静默放行。
    #    ⚠️ 「420 个字符的间隔很荒谬」**不是判据**：我上一片第 15 轮就是判断
    #      「关键字之间放嵌套注释很荒谬」而漏掉了真缺陷。窗口大小本身就是个
    #      「数不完」的参数 —— 去掉它才是结构性的。
    #    ⚠️ 实测：去掉上限后干净树**多报 0 条**，全量扫描（16145 个单元）耗时
    #      与有上限时**相同**（28ms）—— 真正约束跨度的是「禁跨 `(` `)` `;`」那一条。
    rf"insert{_LR_SPAN}+?into{_LR_SPAN}*?training{_LR_NAME}{{0,12}}?sets"
    r"(?![A-Za-z0-9_$])",          # ⛔ 词边界：否则 `training_sets_audit` 也被拖下水
    re.I,
)


def _py_units(text: str):
    """`.py` 源码 → `[(运行时字符串, 起始行号)]`；⛔ 解析不了返回 None。

    调用方**必须**把 None 当成「退回扫原文」，⛔ 不能当成「没有字符串」——
    那是把解析失败伪装成检查通过（本仓成文教训：报 0 违反要先证明能报非 0）。
    """
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None

    consumed = set()

    def fold(node):
        """能算出运行时值就返回它，算不出返回 None。

        ⛔⛔ **只把【真正被折进结果】的节点记进 `consumed`。**
           上一版对整棵子树无差别标记 —— 于是 `"…SQL…".format() + ";"` 折成
           `<哨兵>;` 之后，`.format()` 里那条**真 SQL 字面量再也不会被单独扫到**
           ⇒ 整条消失（codex 第三轮实测的静默绕过，评级 high）。
           ⭐ 这是本仓成文教训「**抹除是破坏性的，破坏的代价是漏报（瞎）**」的又一副
             面孔：我以为自己只是在「折叠」，实际上把**没被代表**的子树抹掉了。
           ⇒ 求不出来的操作数**不消费**，它的子树留给外层循环继续单独扫。
        """
        if isinstance(node, ast.Constant) and isinstance(node.value, (str, bytes)):
            consumed.add(id(node))
            # ⛔ **bytes 字面量也要收**：`b"INSERT INTO …".decode()` 运行时就是 SQL。
            #    只收 `str` 的话它整条消失 —— 而**旧守卫（扫原文）本来报得出它**，
            #    等于我的改动造成了退化（codex 第四轮）。
            return (node.value.decode("utf-8", "replace")
                    if isinstance(node.value, bytes) else node.value)
        if isinstance(node, ast.JoinedStr):          # f-string
            out = []
            for part in node.values:
                if isinstance(part, ast.Constant) and isinstance(part.value, str):
                    consumed.add(id(part))
                    out.append(part.value)
                else:
                    out.append(_UNRESOLVED)          # ⛔ 插值的子树不消费
            consumed.add(id(node))
            return "".join(out)
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "join" and len(node.args) == 1
                and isinstance(node.args[0], (ast.Tuple, ast.List))):
            # `sep.join((a, b, …))`：分隔符与各段都算得出来就折起来（精度）；
            # 算不出来的段放哨兵 —— 与 `+` 的处理一致。
            sep = fold(node.func.value)
            if sep is not None:
                parts = [fold(e) for e in node.args[0].elts]
                consumed.add(id(node))
                return sep.join(_UNRESOLVED if x is None else x for x in parts)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            # ⛔ 求不出来的操作数**放哨兵**而不是返回 None（codex 第二轮）：
            #    返回 None 的话，`"INSERT INTO training_" + suffix + " (…)"` 整体折不起来，
            #    碎片 `INSERT INTO training_` 里没有任何标记 ⇒ 一言不发。
            lhs, rhs = fold(node.left), fold(node.right)
            consumed.add(id(node))
            return ((_UNRESOLVED if lhs is None else lhs)
                    + (_UNRESOLVED if rhs is None else rhs))
        return None                                  # ⛔ 不消费 ⇒ 子树继续单独扫

    # ⛔⛔ **「提及」豁免必须看 AST 上下文，不能只看「字面量恰好到表名为止」。**
    #    豁免是**消音**规则 —— 放宽一点就是一个洞。实测（codex 第五轮，评级 high）：
    #        Q = "".join(("INSERT INTO training_sets", " (stock_code, …) VALUES (…)"))
    #    第一段碎片恰好到表名为止 ⇒ 被当成「提及」消音 ⇒ **静默放行**
    #    （守恒判据也发现不了：原文与解码各有 1 条表头，数目相等）。
    # ⇒ 只有**真正的成员测试**（`if "INSERT INTO training_sets" in query:`）才豁免 ——
    #   那是作用域里三处合法提及的真实形状。
    mention_ok = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Compare) and any(
                isinstance(op, (ast.In, ast.NotIn)) for op in node.ops):
            mention_ok.add(id(node.left))

    units = []
    for node in ast.walk(tree):
        if id(node) in consumed:
            continue
        # ⛔ `ast.Call` 也要进来 —— 否则 `fold` 的 `join` 分支**根本不会被调用到**，
        #    折出来的整串从没变成单元，两段碎片反而各自成了单元（实测：join 那条
        #    只报「判不了」而不是「缺字段」，就是这个原因）。
        if isinstance(node, (ast.JoinedStr, ast.BinOp, ast.Call)) or (
                isinstance(node, ast.Constant) and isinstance(node.value, (str, bytes))):
            value = fold(node)
            if value is not None:
                units.append((value, node.lineno, id(node) in mention_ok))
    return units


#: 宿主拼接留下的痕迹：引号 / `+` / 续行反斜杠 —— 它们永远不属于 SQL 标识符。
_HOST_ARTIFACT = set("\"'+\\ \t\r\n")


def _split_name_heads(text: str) -> list[int]:
    r"""找出「表名被**宿主引号/拼接**劈开」的表头起点。

    ⛔ 只用来报「判不了」，不参与「通过」的判定 —— 所以它宁可宽一点。
    实测这两种 shell 写法此前**整条消失**（`_ident` 读到 `training_` 就放弃）：
        psql -c "INSERT /* (x) */ INTO training_""sets (…) VALUES (…);"
        psql -c "INSERT -- x;\nINTO training_""sets (…) VALUES (…);"
    ⚠️ 读取到 `(` / `;` 即止、且最多 80 个字符，免得把「插另一张表、只是碰巧
       `SELECT … FROM training_sets`」那种合法语句拖下水（那一条实测仍不匹配：
       `INSERT INTO p15_targets (id) SELECT id FROM training_sets` 剥完是
       `p15_targets`，不等于 `training_sets`）。
    """
    out = []
    for km in _INSERT_KW.finditer(text):
        i = _skip_gap(text, km.end())
        if i is None:
            continue
        m_into = _INTO_KW.match(text, i)
        if not m_into:
            continue
        i = _skip_gap(text, m_into.end())
        if i is None:
            continue
        buf, j, n = [], i, len(text)
        while j < n and j - i < 80:
            ch = text[j]
            if ch in "(;":
                break
            if ch.isalnum() or ch in "_$":
                buf.append(ch)
            elif ch in _HOST_ARTIFACT:
                pass                      # 拼接痕迹，跳过但继续读
            else:
                break
            j += 1
        if "".join(buf).lower() == "training_sets":
            out.append(km.start())
    return out


def _unresolved_insert_spans(text: str) -> list[int]:
    r"""`INSERT` 到第一个 `(` / `;` 之间**既含 `INTO`、又含「求不出来」的标记** ⇒ 判不了。

    ⛔⛔ **这条判据【不要求表名】** —— 这是它存在的全部理由。
       codex 第七轮实测的静默绕过（high）：**间隔和表名同时**是插值 ——
           gap = " "; table = "training_sets"
           Q = f"INSERT{gap}INTO {table} (…)"
       解码成 `INSERT<哨兵>INTO <哨兵> (…)`：
         · 兜底网要求字面量 `training…sets` ⇒ 够不着；
         · `_nonliteral_targets` 要靠 `_skip_gap` 走到表名 ⇒ 被间隔里的哨兵挡住；
         · 守恒判据也过（原文与解码**各 0 条**表头）。
       ⇒ 三道都建立在「能认出表名」或「能走过间隔」之上。**必须有一条两者都不依赖的。**
    ⚠️ 这等于把**所有**「表名或间隔求不出来」的 INSERT 都报出来，不只是本表的。
       ⛔ 所以先量后做：干净树上这条判据**多报 0 条**。
    """
    out, n = [], len(text)
    for km in _INSERT_KW.finditer(text):
        k = km.end()
        while k < n and text[k] not in "(;":     # 到列清单/语句末为止
            k += 1
        span = text[km.end():k]
        if _INTO_KW.search(span) and any(mk in span for mk in _COLS_MARKERS):
            out.append(km.start())
    return out


def _nonliteral_targets(text: str) -> list[int]:
    r"""找出「`INSERT INTO` 之后**不是字面量表名**」的表头起点。

    ⛔ 这是本守卫此前**最后一个静默盲区**：表名来自 f-string 变量 / `.format()` /
       `%` 格式化 / 与变量相加时，源码里根本没有 `training_sets` 这几个字，
       三张网**一个都够不着**，而守卫**一言不发** —— 往作用域里加这样一条写入
       即可静默拿到 `DEFAULT 1`。
    ⚠️ 这等于把**所有**动态表名的写入都报出来，不只是 `training_sets` 的。
       ⛔ 所以是**先量后做**：实测干净树上这类 INSERT = **0 条**，零代价。
       将来真要做动态写入，必须显式在这里认领并说明理由。
    """
    out = []
    for km in _INSERT_KW.finditer(text):
        i = _skip_gap(text, km.end())
        if i is None:
            continue
        m_into = _INTO_KW.match(text, i)
        if not m_into:
            continue
        i = _skip_gap(text, m_into.end())
        if i is None:
            continue
        # ⛔ **必须看整个「表名区段」，不能只看第一个字符**（codex 第一轮实测的
        #    **静默绕过**，评级 high）：`f"INSERT INTO training_{suffix} (…)"` 解码后是
        #    `training_<哨兵>` —— `_heads` 认不出这个表名，而只看第一个字符的话，
        #    `training_` **是**个合法标识符 ⇒ 直接放过 ⇒ 既判不了又一言不发。
        # ⇒ 区段 = 从 `INTO` 之后一直读到空白 / `(` / `;` / `,` / 末尾；
        #    区段里出现任何**模板或变量标记**就报。这样部分动态、限定符动态、
        #    shell 的 `training_${SUF}` 都能接住。
        j, n, region = i, len(text), []
        while j < n and j - i <= 128:
            ch = text[j]
            if ch.isspace() or ch in "(;,":
                break
            region.append(ch)
            j += 1
        blob = "".join(region)
        # ⛔ **不是「取不到标识符就报」** —— 那样 `.md` 散文里「INSERT INTO 表」
        #    这种中文字样也会响（`_IDENT_BARE` 要求首字符是 ASCII 字母/下划线）。
        #    ⇒ 只认**可枚举的模板/变量标记**，外加「区段是空的」（= 字面量到此为止，
        #      `"INSERT INTO " + TBL` 就是这样）。
        #      `{` = `.format()` · `%` = 百分号格式化 · `$` = shell 变量 ·
        #      哨兵 = f-string 的插值。
        if not blob or any(mk in blob for mk in _COLS_MARKERS):
            out.append(km.start())
    return out


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
        # ⛔ **扫的是运行时字符串，不是源码原文**（见上方 `_py_units` 的长注释）。
        #    `.py` 用 `ast` 逐个字面量解出来；其它宿主没有便宜的精确解 ⇒ 原文一整块。
        #    ⚠️ `_py_units` 返回 None（语法错）必须**退回扫原文**，
        #       ⛔ 不能当成「这个文件没有字符串」—— 那是把解析失败伪装成检查通过。
        decoded_units = _py_units(text) if q.suffix == ".py" else None
        if decoded_units is None:
            units = [(text, None, False)]   # None = 行号现场数；原文扫描不走 AST 豁免
        else:
            units = decoded_units

        # ⛔⛔ **地板：解码不许让可见的语句【变少】。**
        #    把 `.py` 从「扫原文」改成「扫解码单元」，等于把扫描面**收窄**了 ——
        #    凡是解码器没建模的东西（bytes 字面量、将来某种新写法……）在解码单元里
        #    **根本不存在** ⇒ 整条消失 ⇒ 一言不发。codex 第四轮就是从这里进来的，
        #    而那一条**旧守卫本来报得出** —— 我的改动造成了**退化**。
        # ⇒ 逐个补类型是打地鼠。这里用**守恒判据**：原文里看得见几条表头，
        #    解码后就不许少于几条。它对**所有**将来的解码器缺口都成立。
        # ⚠️ 先量后做：干净树上「解码后表头变少」的 `.py` 文件 = 0 个。
        if decoded_units is not None:
            _raw_n = len(_heads(text)[0])
            _dec_n = sum(len(_heads(u)[0]) for u, _l, _m in units)
            if _dec_n < _raw_n:
                unknown.append(
                    f"{rel}（解码后可见的表头从 {_raw_n} 条减到 {_dec_n} 条 —— "
                    f"解码器漏掉了某种写法，判不了）")

        expected_hits = 0
        bucketed = 0

        for utext, uline, mention_ok in units:
            _hits, _unterminated = _heads(utext)
            if _unterminated:
                # ⛔ 未闭合的块注释会把其后全部内容屏蔽掉 ⇒ 真语句静默消失。必须**响**。
                bad_comment.append(rel)
            expected_hits += len(_hits)

            for m in _heads(utext)[0]:
                lineno = (uline if uline is not None
                          else utext.count(chr(10), 0, m.start()) + 1)
                where = f"{rel}:{lineno}"
                kind, cols = _classify(utext, m.start(), m.end())
                bucketed += 1      # ⛔ 四类**都要**计数，含「提及」—— 否则等式对不上
                if kind == "unknown" and mention_ok \
                        and not utext[m.end():].strip():
                    # ⛔ 解码后的字面量**恰好到表名为止** ⇒ 这是**提及**，不是语句。
                    #    `if "INSERT INTO training_sets" in query:` 这种分派谓词就是
                    #    它。`_classify` 的「两侧都是引号」判据只在**原文**上成立 ——
                    #    解码之后引号已经不在了，必须在这里补回等价判断，否则三处
                    #    合法提及会变成【认不出的形状】⇒ 误报。
                    #    ⚠️ 单独一条 `INSERT INTO training_sets` **不是合法 SQL**
                    #       （没有 VALUES/SELECT），所以这样收不会放过真语句。
                    kind = "mention"
                if kind == "mention":
                    continue
                if kind == "nocols":
                    positional.append(where)
                elif kind == "unknown":
                    unknown.append(where)
                elif any(mk in cols for mk in _COLS_MARKERS):
                    # ⛔ 列清单里有**未解析的插值/占位** ⇒ 判不了，
                    #    ⛔ 不许报「缺 schema_version」：`{a}` 求值成 `/*` 时字段真被注掉，
                    #    求值成空字符串时字段真在场 —— 两种都可能，说「缺」有一半概率
                    #    是在撒谎。而人是照着报文去改代码的（会去补一个已经存在的列）。
                    #    本仓成文教训：报文本身错了，比单纯报错更误导人。
                    # ⚠️ 先量后做：干净树上这条判据命中 0 条。
                    unknown.append(f"{where}（列清单里有未解析的插值/占位，判不了）")
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

            # ⛔⛔ **最后一张网按【单元】跑，解码单元与原文一视同仁。**
            #    `_heads` / `_split_name_heads` / `_nonliteral_targets` 三者**共用
            #    `_skip_gap`**，间隔里一出现它不认的东西（宿主引号、续行反斜杠、
            #    或解码后的哨兵）三张网就**一起落空** —— 那时只有这张不解析间隔的网
            #    还在。⛔ 此前我把它**只开给非 `.py` 宿主**，于是 `.py` 这边没有地板：
            #        gap = " "; Q = f"INSERT{gap}INTO training_sets (…)"
            #    解码成 `INSERT<哨兵>INTO …` ⇒ 三网全空、守恒判据也过（两边都是 0 条）
            #    ⇒ 静默放行（codex 第六轮，评级 high）。
            #    ⭐ 教训：**地板只铺一半等于没铺**。
            #    ⚠️ 先量后做：解码单元上跑这张网，干净树**多报 0 条**。
            _unit_claimed = ({h.start() for h in _heads(utext)[0]}
                             | set(_split_name_heads(utext)))
            for mm in _LAST_RESORT_RE.finditer(utext):
                if mm.start() in _unit_claimed:
                    continue
                lineno = (uline if uline is not None
                          else utext.count(chr(10), 0, mm.start()) + 1)
                unknown.append(f"{rel}:{lineno}（间隔里有拼接痕迹或未解析插值，判不了）")

            # ⛔ 「`INSERT INTO` 后面不是字面量表名」按**单元**判：`.py` 要看解码后的
            #    哨兵/`{}`，其它宿主看原文里的 `$VAR`。这一类**判不了**，但绝不许沉默。
            for st in _nonliteral_targets(utext):
                lineno = (uline if uline is not None
                          else utext.count(chr(10), 0, st) + 1)
                unknown.append(f"{rel}:{lineno}（表名不是字面量，判不了）")

            # ⛔ 「间隔或表名求不出来」——**这一条不要求表名**（见 `_unresolved_insert_spans`
            #    的长注释）。它是「间隔和表名同时是插值」时唯一还站着的判据。
            # ⛔⛔ **去重只按「已报过的不确定性」，绝不按「已认出的表头」**（codex 第八轮）：
            #    认出表头**不等于**这条语句的结构是确定的。实测的静默放行 ——
            #        comment = "*/ (stock_code, file_path) VALUES (1,2); --"
            #        Q = f"INSERT INTO training_sets /* {comment} */ (stock_code, schema_version) …"
            #    运行时那段插值里的 `*/` **提前闭合注释**，真实列清单变成不带字段的那一份
            #    （pglast 核实：`['stock_code', 'file_path']`）；而源码上注释规规矩矩、
            #    `schema_version` 在场 ⇒ 守卫判「通过」。上一版按表头去重，正好把它跳过了。
            _already = set(_nonliteral_targets(utext))
            for st in _unresolved_insert_spans(utext):
                if st in _already:
                    continue
                lineno = (uline if uline is not None
                          else utext.count(chr(10), 0, st) + 1)
                unknown.append(f"{rel}:{lineno}（间隔或表名求不出来，判不了）")

        # ⛔ 「表名被宿主引号/拼接劈开」只对**没解码**的宿主补 —— `.py` 已经由 `ast`
        #    正面解开了，再补一遍会把同一条语句重复报成「判不了」⇒ 合法写法被误报。
        if decoded_units is None:
            _raw_starts = {m.start() for m in _heads(text)[0]}
            for st in _split_name_heads(text):
                if st in _raw_starts:
                    continue
                lineno = text.count(chr(10), 0, st) + 1
                unknown.append(f"{rel}:{lineno}（表名被宿主引号/拼接劈开，判不了）")

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


# ─────────────────────────────────────────────────────────────────────────────
# ⭐⭐⭐ 差分测试之二：**宿主语言这一层**也要拿真东西当裁判
#
# 为什么要再加一条（上面那条差分测试**接不住**这一层）：
#   `test_guard_agrees_with_real_postgres_parser` 直接把**SQL 字符串**喂给
#   `_heads` / `_classify`，它从不走「**文件原文 → 宿主解码 → 扫描**」这条路。
#   而 `_scan` 喂给 `_heads` 的是**文件原文**——`.py` / `.sh` 里的 SQL 是**字符串**，
#   源码原文与运行时真正交给 PostgreSQL 的字符串**不是一回事**：
#
#     · 相邻字面量拼接   `"INSERT INTO " "training_sets (…)"`      → 运行时是一整条
#     · 转义换行         `"INSERT INTO\ntraining_sets (…)"`        → 运行时是真换行
#     · `--` 配转义换行  `"INSERT -- c\nINTO training_sets (…)"`   → 运行时行注释真的结束
#     · 注释定界符被劈开 `… /" "* schema_version, *" "/ …`         → 运行时才形成 `/* */`
#     · 常量相加劈开表名 `"INSERT INTO training_" + "sets (…)"`    → 运行时才拼出表名
#     · shell 引号拼接   `INTO training_""sets (…)`                → 运行时才拼出表名
#
#   实测（三个预言机逐条核实）：上面这一家子里有 **9 条**是
#   「**合法 SQL + 写 training_sets + 列清单确实没有 schema_version**」，
#   而守卫**一言不发** —— `_heads` 连表头都没找到，语句整条从视野里消失。
#
# ⛔ **期望值一个字都不由人写**，三个预言机各管一段：
#     ① `.py` 的运行时字符串 → 交给 **Python 自己的 `ast`**（相邻字面量折叠、转义还原）
#     ② `.sh` 的运行时字符串 → **让 bash 自己把那个参数吐出来**（绝不执行 psql）
#     ③ 「是合法 SQL 吗 / 列清单里到底有没有 schema_version」→ 交给 **`pglast`**
#
# ⚠️ 表名来自**变量**（f-string / `.format()` / `%` / 与变量相加）时，
#    运行时字符串**从源码取不出来** —— 这一类的正确行为是**明说「判不了」让测试红**，
#    ⛔ 不是静默放行。本测试把这一类单独钉住。
# ─────────────────────────────────────────────────────────────────────────────

#: `(标签, 后缀, 源码)` —— 每条都是**宿主层**的写法，不是裸 SQL。
_HOST_CASES = (
    # ── `.py`：相邻字面量 / 转义 / 定界符被劈开 / 常量相加 ──────────────────
    ("py 相邻字面量在 INTO 后断开", ".py",
     'Q = ("INSERT INTO "\n     "training_sets (stock_code, file_path) VALUES ($1,$2)")\n'),
    ("py 相邻字面量在 INSERT 后断开", ".py",
     'Q = ("INSERT "\n     "INTO training_sets (stock_code, file_path) VALUES ($1,$2)")\n'),
    ("py 相邻字面量劈开表名", ".py",
     'Q = ("INSERT INTO training_"\n     "sets (stock_code, file_path) VALUES ($1,$2)")\n'),
    ("py 转义换行当空白", ".py",
     'Q = "INSERT INTO\\ntraining_sets (stock_code, file_path) VALUES ($1,$2)"\n'),
    ("py 行注释配转义换行", ".py",
     'Q = "INSERT -- 种子\\nINTO training_sets (stock_code, file_path) VALUES ($1,$2)"\n'),
    # ⚠️ 这个排列是**刻意挑的**：被劈开的假注释里**含 `schema_version` 字样**，
    #    于是源码原文上按逗号切出来的 token 会把它当成真列名 ⇒ 守卫判「合规」（**假通过**）。
    #    ⛔ 换成 `/" "* 先不要 schema_version, *" "/` 那种排列就**复现不出**这个洞
    #    （守卫会报缺字段，方向恰好对）—— RED 阶段实测到的，所以这里写死这个排列。
    ("py 块注释定界符被劈开（假注释里含字段字样）", ".py",
     'Q = ("INSERT INTO training_sets (stock_code, /"\n'
     '     "* x, schema_version, *"\n'
     '     "/ stock_name, file_path, content_hash) VALUES ($1)")\n'),
    ("py 常量相加劈开表名", ".py",
     'Q = "INSERT INTO training_" + "sets (stock_code, file_path) VALUES ($1,$2)"\n'),
    # ── `.sh`：引号拼接劈开表名 ────────────────────────────────────────────
    # ⛔⛔ **间隔里塞宿主拼接痕迹** —— 自查挖出的三条静默绕过，根因是
    #    `_heads` / `_split_name_heads` / `_nonliteral_targets` **三者共用同一个
    #    `_skip_gap`**：它只跳空白与 SQL 注释，间隔里一出现宿主引号 / 续行反斜杠，
    #    三张网**一起落空** ⇒ 一言不发。
    #    ⭐ 这与「粗网和精确网共用间隔解析器 ⇒ 所谓兜底根本不存在」是同一条根 ——
    #      解法只能是一张**完全不解析间隔**的网。
    #    （运行时用 bash 实测过：三条都是合法 SQL 且列清单确实缺 schema_version。）
    ("sh 间隔塞引号（INSERT 与 INTO 之间）", ".sh",
     'psql -c "INSERT "" INTO training_sets (stock_code, file_path) VALUES (1,2);"\n'),
    ("sh 间隔用反斜杠续行", ".sh",
     'psql -c "INSERT \\\n INTO training_sets (stock_code, file_path) VALUES (1,2);"\n'),
    # ⚠️ `.yml` 的等价写法**没放进来**：本测试的预言机②只让 bash 吐出 `psql` 的参数，
    #    对 `.yml` 无能为力 ⇒ 那条用例会**空转**（防空转断言当场抓到了，已撤）。
    #    同一条代码路径由上面两条 `.sh` 用例覆盖。
    ("sh 引号拼接劈开表名（间隔注释含左括号）", ".sh",
     'psql -c "INSERT /* (x) */ INTO training_""sets '
     '(stock_code, file_path) VALUES (1,2);"\n'),
    ("sh 引号拼接劈开表名（间隔行注释含分号）", ".sh",
     'psql -c "INSERT -- x;\nINTO training_""sets '
     '(stock_code, file_path) VALUES (1,2);"\n'),
    # ── 正向对照：合法且字段在场，⛔ 守卫必须放行 ─────────────────────────
    ("py 正向·整条在一个字面量里", ".py",
     'Q = "INSERT INTO training_sets (stock_code, schema_version, file_path) '
     'VALUES ($1,$2,$3)"\n'),
    ("py 正向·相邻字面量拼接且字段在场", ".py",
     'Q = ("INSERT INTO training_sets (stock_code, sch"\n'
     '     "ema_version, file_path) VALUES ($1,$2,$3)")\n'),
    # ⛔ **表名被劈开、但字段在场**的合法写法 —— 这一条是变异逼出来的：
    #    把 `_split_name_heads` 的「只对没解码的宿主补」那道 gate 去掉，
    #    `.py` 里同一条语句会被**重复报成「判不了」** ⇒ 合法代码变红。
    #    实测：没有这条对照时，那个变异**零红**（正向对照里缺了这一种形态）。
    ("py 正向·相邻字面量劈开表名且字段在场", ".py",
     'Q = ("INSERT INTO training_"\n'
     '     "sets (stock_code, schema_version, file_path) VALUES ($1,$2,$3)")\n'),
    # ⛔ **三段以上**常量相加。codex 第一轮实测的误报 —— `_py_units` 第一遍没查
    #    `consumed`，`Add(Add(a,b), c)` 里**内层那个 Add 也被当成一个单元发出**，
    #    而内层是「半条语句」（括号没配平）⇒ 被报「判不了」⇒ 合法代码变红。
    ("py 正向·三段常量相加且字段在场", ".py",
     'Q = "INSERT INTO training_sets (" + "stock_code, " '
     '+ "schema_version) VALUES ($1,$2)"\n'),
    ("py 正向·四段常量相加且字段在场", ".py",
     'Q = ("INSERT INTO " + "training_sets " + "(stock_code, schema_version) " '
     '+ "VALUES ($1,$2)")\n'),
    ("sh 正向·heredoc 里字段在场", ".sh",
     'psql <<SQL\nINSERT INTO training_sets (stock_code, schema_version, file_path)\n'
     '  VALUES (1,2,3);\nSQL\n'),
)

#: 表名来自**变量** ⇒ 运行时字符串从源码取不出来 ⇒ 守卫必须报「判不了」，不得沉默。
_HOST_UNDECIDABLE = (
    ("py f-string 变量表名", ".py",
     'Q = f"INSERT INTO {tbl} (stock_code, file_path) VALUES ($1,$2)"\n'),
    ("py .format() 变量表名", ".py",
     'Q = "INSERT INTO {t} (stock_code, file_path) VALUES ($1,$2)".format(t=TBL)\n'),
    ("py 与变量相加拼表名", ".py",
     'Q = "INSERT INTO " + TBL + " (stock_code, file_path) VALUES ($1,$2)"\n'),
    # ⛔ 碎片**恰好到表名为止**、且**不是**成员测试（在列表里等着被 join）。
    #    「提及」豁免若退回「只看位置」，这一条会被消音 ⇒ 静默放行。
    #    ⚠️ 没有这一条，那个变异**零红**（实测）。
    ("py 碎片到表名为止、在列表里（不是成员测试）", ".py",
     'QS = ["INSERT INTO training_sets", cols]\n'),
    ("py % 格式化变量表名", ".py",
     'Q = "INSERT INTO %s (stock_code, file_path) VALUES ($1,$2)" % TBL\n'),
    # ⛔ **部分动态**：表名有字面量前缀、后半截是插值。codex 第一轮实测的静默绕过 ——
    #    解码后是 `training_<哨兵>`，`_heads` 认不出它，而「表名不是字面量」那条判据
    #    看到 `training_` **是**个合法标识符就放过了 ⇒ 既判不了又一言不发。
    ("py 部分动态表名（字面量前缀 + 插值）", ".py",
     'suffix = "sets"\n'
     'Q = f"INSERT INTO training_{suffix} (stock_code, file_path) VALUES ($1,$2)"\n'),
    ("py 部分动态表名（限定符也是插值）", ".py",
     'Q = f"INSERT INTO {sch}.training_sets (stock_code, file_path) VALUES ($1,$2)"\n'),
    ("sh 部分动态表名（shell 变量拼后半截）", ".sh",
     'psql -c "INSERT INTO training_${SUF} (stock_code, file_path) VALUES (1,2);"\n'),
    # ⛔⛔ codex 第六轮实测的静默绕过（high）：插值落在**关键字之间的间隔**里。
    #    解码后是 `INSERT<哨兵>INTO training_sets (…)` —— `_heads` 与
    #    `_nonliteral_targets` **都靠 `_skip_gap`**，而它不认哨兵 ⇒ 两者一起落空；
    #    守恒判据也过（原文与解码各 0 条表头）；而兜底网当时**只开给非 `.py` 宿主**
    #    ⇒ `.py` 这边根本没有地板。
    #    ⭐ 这就是我自己在非 `.py` 侧已经认过的那条根 —— 我把网只开了一半。
    ("py 插值落在关键字之间的间隔里", ".py",
     'gap = " "\n'
     'Q = f"INSERT{gap}INTO training_sets (stock_code, file_path) VALUES (1,2)"\n'),
    ("py 变量落在关键字之间的间隔里（`+` 拼接）", ".py",
     'Q = "INSERT" + gap + "INTO training_sets (stock_code, file_path) VALUES (1,2)"\n'),
    # ⛔⛔ codex 第八轮：插值藏在**列清单之前的注释里**。
    #    运行时那段插值里的 `*/` 会**提前闭合注释**，把真实列清单换成不带字段的那一份
    #    （pglast 核实：运行时列清单 = ['stock_code', 'file_path']，**真缺字段**），
    #    而源码上看起来注释规规矩矩、列清单里 `schema_version` 在场 ⇒ 守卫判「通过」。
    #    ⭐ 根因是我那条去重写错了：**「`_heads` 认出来了就跳过不确定性检查」** ——
    #      认出表头**不等于**这条语句的结构是确定的。去重该按「已报过的不确定性」，
    #      ⛔ 不是按「已认出的表头」。
    ("py 插值藏在列清单之前的注释里", ".py",
     'comment = "*/ (stock_code, file_path) VALUES (1,2); --"\n'
     'Q = f"INSERT INTO training_sets /* {comment} */'
     ' (stock_code, schema_version) VALUES (1,2)"\n'),
    # ⛔⛔ codex 第七轮（high）：**间隔和表名同时**是插值。
    #    解码成 `INSERT<哨兵>INTO <哨兵> (…)` —— 兜底网要求字面量 `training…sets`（够不着），
    #    `_nonliteral_targets` 又被间隔里的哨兵挡住（`_skip_gap` 走不过去）⇒ 两者皆空；
    #    守恒判据也过（原文与解码各 0 条表头）⇒ 静默。
    #    ⇒ 需要一条**根本不要求表名**的判据：`INSERT` 到第一个 `(` / `;` 之间
    #      既含 `INTO`、又含「求不出来」的标记 ⇒ 判不了（不管写的是哪张表）。
    ("py 间隔与表名同时是插值", ".py",
     'gap = " "\n'
     'table = "training_sets"\n'
     'Q = f"INSERT{gap}INTO {table} (stock_code, file_path) VALUES (1,2)"\n'),
    # ⛔ **间隔很长**：兜底网原先有 400 字符的窗口，间隔一长就够不着 ⇒ 静默。
    #    ⚠️ 「420 个字符的间隔很荒谬」**不是判据** —— 本仓成文教训：
    #      我上一片第 15 轮就是判断「关键字之间放嵌套注释很荒谬」而漏掉了真缺陷。
    #    ⇒ 窗口大小本身就是个「数不完」的参数，已去掉上限（实测零误报、耗时不变）。
    ("py 关键字之间的间隔超长", ".py",
     'Q = f"INSERT {g}' + "x" * 420 + ' INTO training_sets'
     ' (stock_code, file_path) VALUES (1,2)"\n'),
    # ⛔ codex 第二轮实测的静默绕过：`fold` 对**含变量的 `Add`** 返回 None，
    #    于是碎片被各自当成单元 —— 而碎片 `INSERT INTO training_` 里**没有任何标记**，
    #    「表名不是字面量」那条判据也就认不出它。
    ("py 变量补全表名后半截（常量 + 变量 + 常量）", ".py",
     'suffix = "sets"\n'
     'Q = "INSERT INTO training_" + suffix + " (stock_code, file_path) VALUES ($1,$2)"\n'),
    ("py 变量接在完整表名之后", ".py",
     'Q = "INSERT INTO training_sets" + tail + " (stock_code, file_path) VALUES ($1,$2)"\n'),
)


def _oracle_runtime_sql(suffix: str, src: str) -> list[str]:
    """预言机 ①②：把宿主源码**还原成运行时真正交给 PostgreSQL 的字符串**。

    ⛔ 一个字都不由人写：
      · `.py` → **Python 自己的 `ast`**（相邻字面量已折叠、转义已还原）；
        常量 `+` 常量再手动折一层；变量部分折不出来 ⇒ 该条返回空表。
      · `.sh` → **让 bash 自己吐出 `psql -c` 的那个参数**（⛔ 绝不执行 psql）。
    """
    if suffix == ".py":
        import ast as _ast

        def _fold(node):
            if isinstance(node, _ast.Constant) and isinstance(node.value, str):
                return node.value
            if isinstance(node, _ast.Constant) and isinstance(node.value, bytes):
                return node.value.decode("utf-8", "replace")
            if isinstance(node, _ast.BinOp) and isinstance(node.op, _ast.Add):
                a, b = _fold(node.left), _fold(node.right)
                return None if a is None or b is None else a + b
            # ⛔ `sep.join((a, b, …))` —— 这里模拟的是 **Python 的语义**，
            #    ⛔ 不是照抄守卫的实现（否则预言机与被测对象循环依赖、判别力归零）。
            if (isinstance(node, _ast.Call) and isinstance(node.func, _ast.Attribute)
                    and node.func.attr == "join" and len(node.args) == 1
                    and isinstance(node.args[0], (_ast.Tuple, _ast.List))):
                sep = _fold(node.func.value)
                parts = [_fold(e) for e in node.args[0].elts]
                if sep is not None and all(x is not None for x in parts):
                    return sep.join(parts)
            return None

        out = []
        for node in _ast.walk(_ast.parse(src)):
            if isinstance(node, (_ast.Assign, _ast.Expr)):
                v = _fold(node.value)
                if v:
                    out.append(v)
        return out

    import shutil as _shutil
    import subprocess as _subprocess
    # ⛔ 不许 skip（本仓规则：后端 CI 是 Linux 且零容忍 skip）—— bash 必须在。
    assert _shutil.which("bash"), "预言机②需要 bash，环境里没有 —— 这是硬失败，不是 skip"
    # ⛔ stub 必须**同时**接住两种喂法：`psql -c "<SQL>"` 与 heredoc / 管道（读 stdin）。
    #    只接 `-c` 的话，heredoc 那条用例会还原不出 SQL ⇒ 防空转断言当场炸
    #    （RED 阶段实测到的，正是这条断言该有的作用）。
    stub = (
        "psql() { got=0; while [ $# -gt 0 ]; do "
        "if [ \"$1\" = -c ]; then shift; printf '\\1%s\\2' \"$1\"; got=1; fi; "
        "shift; done; "
        "if [ \"$got\" = 0 ]; then printf '\\1'; cat; printf '\\2'; fi; }\n"
    )
    r = _subprocess.run(["bash", "-c", stub + src], capture_output=True, text=True)
    blob, out = r.stdout, []
    while "\1" in blob:
        _, _, rest = blob.partition("\1")
        arg, _, blob = rest.partition("\2")
        out.append(arg)
    # ⛔ 取不出来就**明说取不出来**，绝不退回「把整篇当 SQL」——
    #    那会让 `psql <<SQL …` 这种壳子进到 pglast 里，制造「预言机也解析不了」的假象。
    return out


def _oracle_truth(sqls: list[str]):
    """预言机 ③：`pglast` 说这批语句里有没有「写 training_sets 且缺 schema_version」。

    返回 `True`（有合规写入）/ `False`（有真漏）/ `None`（PG 眼里没有这样的 INSERT）。
    """
    import pglast

    verdict = None
    for sql in sqls:
        try:
            tree = pglast.parse_sql(sql)
        except Exception:
            continue
        for raw in tree:
            stmt = raw.stmt
            if type(stmt).__name__ != "InsertStmt":
                continue
            rel = stmt.relation
            if rel is None or rel.relname != "training_sets":
                continue
            if rel.schemaname not in (None, "public"):
                continue
            cols = [c.name for c in (stmt.cols or []) if getattr(c, "name", None)]
            if not cols:
                continue
            if "schema_version" not in cols:
                return False         # 真漏最要紧，直接定案
            verdict = True
    return verdict


def _guard_on_source(tmp_root, suffix: str, src: str):
    """把源码写成一个真文件，走**守卫真正的那条装配线**（`_scan`）。

    ⛔ 必须走 `_scan` 而不是直接调 `_heads` —— 本文件上面那条差分测试正是因为
       绕过了装配线，才让「宿主原文 ≠ 运行时字符串」这一层**整层没人钉**。
    """
    f = tmp_root / f"probe{suffix}"
    f.write_text(src, encoding="utf-8")
    missing, positional, unknown, checked, _cells, lost, bad_comment = _scan([f], tmp_root)
    return {
        "missing": missing, "positional": positional, "unknown": unknown,
        "checked": checked, "lost": lost, "bad_comment": bad_comment,
        "silent": not (missing or positional or unknown or lost or bad_comment),
    }


def test_guard_sees_the_runtime_sql_not_the_source_text(tmp_path):
    """守卫对宿主源码的判定，必须与「**还原成运行时字符串再问 PostgreSQL**」一致。

    ⛔ 这一条钉的是 `_scan` 喂给 `_heads` 的**文本来源**。
       上面那条差分测试直接喂 SQL 字符串，**绕过了**这一层。
    """
    wrong = []
    truths, guard_verdicts = set(), set()

    for label, suffix, src in _HOST_CASES:
        runtime = _oracle_runtime_sql(suffix, src)
        truth = _oracle_truth(runtime)
        # ⛔ 防空转：预言机必须真的从这条源码里还原出一条「写 training_sets」的 INSERT，
        #    否则这条用例什么都没验（本仓成文教训：报 0 违反要先证明能报非 0）。
        assert truth is not None, (
            f"预言机没能从这条源码里还原出写 training_sets 的 INSERT，用例是空转的："
            f"{label} -> 还原结果={runtime!r}"
        )
        truths.add(truth)

        got = _guard_on_source(tmp_path, suffix, src)
        # 「守卫判它合规」= 真的判过（checked ≥ 1）且没报任何问题
        said_ok = (got["checked"] >= 1 and not got["missing"]
                   and not got["unknown"] and not got["positional"])
        guard_verdicts.add(said_ok)

        if truth is False:
            # PG 说真漏 ⇒ 守卫**不许判为合规**，也不许连表头都没找到。
            # ⚠️ 两者要分开报：「判过了但说合规」与「整条从视野里消失」根因不同，
            #    混成一句话会让人修错地方（报文本身错了比单纯报错更误导人）。
            if said_ok:
                wrong.append(
                    f"[假通过] {label}：PG 说缺 schema_version，守卫判过它却说合规"
                    f"（checked={got['checked']}）")
            elif got["silent"]:
                wrong.append(
                    f"[整条消失] {label}：PG 说缺 schema_version，守卫连表头都没找到"
                    f"（checked={got['checked']}）")
        else:
            # PG 说合规 ⇒ 守卫必须真的**判过**它，且判为合规
            if not said_ok:
                wrong.append(
                    f"[误报] {label}：PG 说合规，守卫却 missing={got['missing']} "
                    f"unknown={got['unknown']} positional={got['positional']} "
                    f"checked={got['checked']}"
                )

    # ⛔ 防恒真：两种真相都要出现过，守卫也要两种判定都给过 ——
    #    否则本测试可能只是在比对两个恒定值。
    assert truths == {True, False}, f"用例表退化了：PG 真相只出现了 {truths}"
    assert guard_verdicts == {True, False}, f"用例表退化了：守卫只给出过 {guard_verdicts}"

    assert not wrong, (
        f"守卫看的是**源码原文**、而 PostgreSQL 看的是**运行时字符串**，共 "
        f"{len(wrong)} 条不一致：\n  " + "\n  ".join(wrong)
    )


#: ⛔ 反向：**不该响**的内容。「表名不是字面量」那条判据只认**可枚举的模板/变量标记**
#:    （`{` `%` `$` / f-string 哨兵 / 字面量到此为止）—— 若退化成「取不到标识符就报」，
#:    `.md` 散文里的中文表名字样也会响（`_IDENT_BARE` 要求首字符是 ASCII 字母/下划线）。
#: ⚠️ 这一条也是变异逼出来的：把那个判据放宽成「取不到就报」时，实测**零红** ——
#:    干净树上恰好没有会误触的内容，于是那个收紧**没有任何东西钉着**。
_MUST_STAY_QUIET = (
    ("md 中文散文提到往哪张表写", ".md",
     "P9 烟测：往 INSERT INTO 训练组表 里写一行，然后核对返回的 id。\n"),
    ("md 散文里 INTO 后面是标点", ".md",
     "本节讲的是 `INSERT INTO`：它后面跟表名。\n"),
    ("py 注释里提到 INSERT INTO 而已", ".py",
     "# 这里原本要 INSERT INTO 另一张表，后来改了\nX = 1\n"),
    # ⛔ 这两条钉住**兜底网不许过宽**，都是变异逼出来的（没有它们，两个变异零红）：
    ("sh 插的是前缀相同的另一张表", ".sh",
     'psql -c "INSERT INTO training_sets_audit (stock_code, file_path) VALUES (1,2);"\n'),
    # ⚠️ 这一条**不能**在 `INTO` 与路径之间放括号 —— 兜底网本来就不许跨 `(`，
    #    放了括号它根本走不到表名跨度那一步，于是「表名跨度用任意字符」那个变异会零红。
    #    （实测踩过：第一版写成 `VALUES ('000001.SZ', '/data/training-sets/…')` ⇒ 零红。）
    ("md 插别的表、同一段里出现 training-sets 路径且不隔括号", ".md",
     "```sh\npsql -c \"INSERT INTO p11_expected SELECT "
     "'/data/training-sets/a.zip';\"\n```\n"),
)


def test_guard_stays_quiet_on_prose_that_merely_mentions_insert_into(tmp_path):
    """⛔ 守卫不许变成噪音源：只是**提到** `INSERT INTO` 的散文不得被报出来。

    一道会在合法内容上变红的守卫等于给实施者发放宽许可证（人很快就开始无视它）。
    本仓成文教训：守卫必须在当前树上就是绿的。
    """
    noisy = []
    for label, suffix, src in _MUST_STAY_QUIET:
        got = _guard_on_source(tmp_path, suffix, src)
        if not got["silent"]:
            noisy.append(
                f"{label}：unknown={got['unknown']} missing={got['missing']} "
                f"positional={got['positional']}")
    assert not noisy, (
        "只是提到 `INSERT INTO` 的散文被守卫报出来了 —— 这是噪音，不是严格：\n  "
        + "\n  ".join(noisy))


#: ⛔ 列清单里含**未解析的插值/占位**时，守卫**判不了** —— 它不许说「缺 schema_version」。
#:    `{a}` 求值成 `/*` 时字段真的被注掉；求值成空字符串时字段真的在场。
#:    两种都可能，所以「缺字段」这个报文**有一半概率是在撒谎**。
#: ⚠️ 两者都会让测试变红，差别只在**报文说的对不对** —— 而人是照着报文去改代码的：
#:    看到「缺 schema_version」他会去补一个**可能已经存在**的列。
#:    本仓成文教训：报文本身错了，比单纯报错更误导人。
_COLS_UNDECIDABLE = (
    ("整个列清单是插值", ".py",
     'Q = f"INSERT INTO training_sets ({cols}) VALUES ($1,$2)"\n'),
    ("插值夹在列清单里（可求值成注释定界符）", ".py",
     'Q = f"INSERT INTO training_sets (stock_code, {a} schema_version, {b} file_path)'
     ' VALUES ($1)"\n'),
    (".format() 占位在列清单里", ".py",
     'Q = "INSERT INTO training_sets (stock_code, {a} schema_version, {b} file_path)'
     ' VALUES ($1)".format(a="/*", b="*/")\n'),
    ("% 占位在列清单里", ".py",
     'Q = "INSERT INTO training_sets (stock_code, %s schema_version, %s file_path)'
     ' VALUES ($1)" % ("/*", "*/")\n'),
    ("shell 变量在列清单里", ".sh",
     'psql -c "INSERT INTO training_sets (stock_code, $EXTRA) VALUES (1);"\n'),
)


def test_guard_says_cannot_tell_when_the_column_list_has_unresolved_interpolation(tmp_path):
    """列清单里有未解析插值 ⇒ 报「判不了」，⛔ 不许报「缺 schema_version」。"""
    mislabelled = []
    for label, suffix, src in _COLS_UNDECIDABLE:
        got = _guard_on_source(tmp_path, suffix, src)
        if got["silent"]:
            mislabelled.append(f"{label}：一言不发（最坏的结果）")
        elif got["missing"]:
            mislabelled.append(
                f"{label}：报了「缺 schema_version」，可这里**判不了** -> {got['missing']}")
        elif not got["unknown"]:
            mislabelled.append(f"{label}：红了但不是「判不了」-> {got}")
    assert not mislabelled, (
        "列清单里有未解析的插值，守卫却给出了**确定性的结论** —— 人会照着这个"
        "报文去补一个可能已经存在的列：\n  " + "\n  ".join(mislabelled))
    # ⛔ 防空转：反向必须仍然绿 —— 插值只落在 VALUES 里是**完全正常**的参数化查询。
    ok = _guard_on_source(
        tmp_path, ".py",
        'Q = f"INSERT INTO training_sets (stock_code, schema_version) VALUES ({a},{b})"\n')
    assert ok["checked"] == 1 and not ok["missing"] and not ok["unknown"], (
        f"插值只在 VALUES 里是正常写法，守卫却报了问题：{ok}")


#: ⛔⛔ **求不出来的表达式里的 SQL 字面量，不许消失。**
#:
#: codex 第三轮实测的**静默绕过（high）**，而且是我第二轮修法的**直接后果**：
#: 第二轮我让 `fold` 对求不出来的操作数放哨兵 —— 但同时把**整棵子树**都标成
#: 「已消费」。于是 `"…SQL…".format() + "\n"` 折成 `<哨兵>\n`，
#: 而 `.format()` 里那条**真 SQL 字面量再也不会被单独扫到** ⇒ 整条消失。
#:
#: ⭐ 这是本仓成文教训「**抹除是破坏性的，破坏的代价是漏报（瞎）**」的又一副面孔 ——
#:    我以为自己只是「折叠」，实际上把没被代表的子树**抹掉**了。
#: ⇒ 只消费**真正被折进结果**的节点；求不出来的操作数，其子树要继续单独扫。
_MUST_NOT_VANISH = (
    ("调用结果再接一段（.format() + 后缀）", ".py",
     'Q = "INSERT INTO training_sets (stock_code, file_path) VALUES ($1,$2)"'
     '.format() + ";"\n'),
    ("列表里的 SQL 与另一个列表相加", ".py",
     'QS = ["INSERT INTO training_sets (stock_code, file_path) VALUES ($1,$2)"] + EXTRA\n'),
    ("三元表达式里的 SQL", ".py",
     'Q = ("INSERT INTO training_sets (stock_code, file_path) VALUES ($1,$2)"\n'
     '     if flag else OTHER)\n'),
    # ⛔ SQL 字面量嵌在 **f-string 的插值表达式**里。若插值的子树也被无差别消费，
    #    这条同样会整条消失 —— 与 `.format()` 那条是同一个根，只是换了个容器。
    ("f-string 插值表达式里的 SQL", ".py",
     "Q = f\"{'INSERT INTO training_sets (stock_code, file_path) VALUES (1,2)'"
     " if flag else ''}\"\n"),
    # ⛔ `"".join(...)`：碎片 `INSERT INTO training_sets` 恰好到表名为止，
    #    被「提及」豁免当成非语句 ⇒ 静默放行（codex 第五轮，评级 high）。
    #    ⭐ 豁免是**消音**规则 —— 消音规则放宽一点就是一个洞。
    ("join 拼接（碎片恰好到表名为止）", ".py",
     'Q = "".join(("INSERT INTO training_sets",'
     ' " (stock_code, file_path) VALUES (1,2)"))\n'),
    # ⛔ **bytes 字面量**：旧守卫（扫原文）本来报得出它，而我改成扫解码单元之后
    #    它整条消失 —— 这是**我引入的退化**（codex 第四轮）。
    ("bytes 字面量 .decode()", ".py",
     'Q = b"INSERT INTO training_sets (stock_code, file_path) VALUES (1,2)"'
     '.decode("ascii")\n'),
    ("SQL 字面量作为函数实参", ".py",
     'run("INSERT INTO training_sets (stock_code, file_path) VALUES ($1,$2)" + tail)\n'),
)


def test_sql_literals_inside_unresolvable_expressions_do_not_vanish(tmp_path):
    """求不出来的表达式**里面**的 SQL 字面量，守卫必须仍然看得见。

    ⛔ 最低要求是**不许一言不发** —— 判得出就报缺字段，判不出就报判不了，
       但绝不能整条从视野里消失。
    """
    vanished = []
    for label, suffix, src in _MUST_NOT_VANISH:
        got = _guard_on_source(tmp_path, suffix, src)
        if got["silent"]:
            vanished.append(f"{label}（checked={got['checked']}）")
    assert not vanished, (
        "求不出来的表达式里的 SQL 字面量**整条消失**了 —— 这是最坏的结果："
        "既没判对也没说判不了，没人知道该去看一眼：\n  " + "\n  ".join(vanished))
    # ⛔ 防空转：这些样本里**确实**各有一条写 training_sets 且缺字段的 SQL。
    #    ⚠️ 候选串既要含**单个字面量**（`.format()` / 列表 / 三元 那几条的 SQL 就在
    #       某一个字面量里），也要含**折叠后的整体**（`join` 那条的两段单独都不是
    #       合法 SQL，只有拼起来才是）。少一半这条防空转就会误判成「用例空转」。
    import ast as _ast
    for label, suffix, src in _MUST_NOT_VANISH:
        cands = list(_oracle_runtime_sql(suffix, src))
        for node in _ast.walk(_ast.parse(src)):
            if not isinstance(node, _ast.Constant):
                continue
            raw = node.value
            if isinstance(raw, bytes):
                raw = raw.decode("utf-8", "replace")
            if isinstance(raw, str):
                cands.append(raw)
        assert _oracle_truth(cands) is False, (
            f"这条样本里并没有「写 training_sets 且缺 schema_version」的合法 SQL，"
            f"用例是空转的：{label}")


#: ⛔ 这些写法**旧守卫（扫原文）本来就能给出确定结论**（「缺 schema_version」）。
#:    换成扫解码单元之后，不许降级成「判不了」—— 那对使用者是**退化**：
#:    「判不了」要人手工再看一遍，「缺字段」是直接可行动的。
#: ⚠️ 这一条是变异逼出来的：守恒判据（地板）会把 bytes 那条接成「判不了」，
#:    于是「收不收 bytes」**没有任何东西钉着** —— 实测把它改回只收 `str`，零红。
_MUST_NAME_THE_MISSING_FIELD = (
    ("bytes 字面量 .decode()", ".py",
     'Q = b"INSERT INTO training_sets (stock_code, file_path) VALUES (1,2)"'
     '.decode("ascii")\n'),
    ("普通字面量", ".py",
     'Q = "INSERT INTO training_sets (stock_code, file_path) VALUES (1,2)"\n'),
    # ⛔ `join` 折叠是**精度**改进：不折叠时兜底/豁免收窄会把它兜成「判不了」——
    #    仍然红，但报文从「缺 schema_version」降级成「要人再看一遍」。
    #    ⚠️ 没有这一条，「不折叠 join」那个变异**零红**（实测）。
    ("join 拼接", ".py",
     'Q = "".join(("INSERT INTO training_sets",'
     ' " (stock_code, file_path) VALUES (1,2)"))\n'),
    # ⛔ 下面三条钉住「**只消费真正被折进结果的节点**」是**精度**改进：
    #    守恒判据（地板）已经能把它们兜成「判不了」，于是那处修复本身**没人钉**
    #    —— 实测两个变异（Add 分支整棵子树消费 / f-string 插值子树也消费）零红。
    #    有了这三条，它们才会红。
    (".format() 结果再接一段", ".py",
     'Q = "INSERT INTO training_sets (stock_code, file_path) VALUES (1,2)"'
     '.format() + ";"\n'),
    ("f-string 插值表达式里的 SQL", ".py",
     "Q = f\"{'INSERT INTO training_sets (stock_code, file_path) VALUES (1,2)'"
     " if flag else ''}\"\n"),
    ("列表里的 SQL 与另一个列表相加", ".py",
     'QS = ["INSERT INTO training_sets (stock_code, file_path) VALUES (1,2)"] + EXTRA\n'),
)


def test_precision_does_not_regress_to_cannot_tell(tmp_path):
    """判得出的写法必须报「缺 schema_version」，⛔ 不许降级成「判不了」。"""
    punted = []
    for label, suffix, src in _MUST_NAME_THE_MISSING_FIELD:
        got = _guard_on_source(tmp_path, suffix, src)
        if not got["missing"]:
            punted.append(
                f"{label}：missing={got['missing']} unknown={got['unknown']} "
                f"checked={got['checked']}")
    assert not punted, (
        "这些写法**判得出**缺 schema_version，守卫却没给出确定结论 —— "
        "对使用者是退化（「判不了」要人再看一遍）：\n  " + "\n  ".join(punted))


def test_decoding_must_not_reduce_what_the_raw_scan_can_see(tmp_path):
    """⛔⛔ **解码不许让可见的语句【变少】** —— 这是整条解码路线的**地板**。

    把 `.py` 从「扫原文」改成「扫解码单元」，等于把扫描面**收窄**了：
    凡是我的解码器没建模的东西（bytes 字面量、将来某种新写法……），
    在解码单元里**根本不存在** ⇒ 整条消失 ⇒ 一言不发。
    codex 第四轮就是从这里进来的（bytes 字面量），而那一条**旧守卫本来报得出**
    —— 也就是说我的改动造成了**退化**。

    ⇒ 逐个补类型是打地鼠。这里改成一条**守恒判据**：
      **原文里看得见几条表头，解码后就不许少于几条。** 少了就报「判不了」。
      它对**所有**将来的解码器缺口都成立，不必预见具体写法。
    ⚠️ 先量后做：干净树上「解码后表头变少」的 `.py` 文件 = **0 个**，零代价。
    """
    # SQL 藏在**注释**里：原文扫得到，解码单元里根本没有注释 ⇒ 守恒判据必须响。
    src = ("# INSERT INTO training_sets (stock_code, file_path) VALUES (1,2)\n"
           "X = 1\n")
    got = _guard_on_source(tmp_path, ".py", src)
    assert not got["silent"], (
        "原文里看得见一条表头、解码后一条都不剩，守卫却一言不发 —— "
        f"解码器的任何缺口都会变成静默漏扫：{got}")
    # ⛔ 防空转：这条用例的前提是「原文看得见、解码看不见」。
    raw_heads = len(_heads(src)[0])
    dec_heads = sum(len(_heads(u)[0]) for u, _ in (_py_units(src) or []))
    assert raw_heads > dec_heads, (
        f"这条用例的前提不成立（原文 {raw_heads} 条 / 解码 {dec_heads} 条），"
        f"它没在验守恒判据")


def test_guard_never_stays_silent_when_something_is_unresolved(tmp_path):
    """源码里有**求不出来**的东西时，必须**明说判不了**，⛔ 不许沉默。

    ⚠️ 本测试原名 `…_on_a_non_literal_table_name`，已改名 —— 它管的不只是表名：
       间隔里的插值、列清单之前注释里的插值，同样属于「求不出来」。
       名字不准会让人以为别的形态没人管（本仓成文教训：不实陈述比缺陷更坏）。

    ⚠️ 这一类**无法**判对（表名到底是不是 `training_sets`，源码里没写）。
       但「判不了」与「沉默」是两件完全不同的事：前者让测试红、有人来看，
       后者是**放行许可证**。本仓成文教训：失败要往「吵」的方向倒，不往「瞎」的方向倒。
    """
    silent = []
    for label, suffix, src in _HOST_UNDECIDABLE:
        # ⛔ 防空转：这些用例的前提是「预言机也还原不出来」。若哪天能还原了，
        #    它们就该搬去上面那条测试，而不是留在这里继续验「沉默」。
        runtime = _oracle_runtime_sql(suffix, src)
        assert _oracle_truth(runtime) is None, (
            f"预言机居然还原出了运行时 SQL：{label} —— 这条用例该搬去 "
            f"test_guard_sees_the_runtime_sql_not_the_source_text"
        )
        got = _guard_on_source(tmp_path, suffix, src)
        if got["silent"]:
            silent.append(f"{label}")
    assert not silent, (
        "表名是拼出来的，守卫既判不了、又一言不发 —— 往作用域里加这样一条写入即可"
        "静默绕过，拿到 DEFAULT 1：\n  " + "\n  ".join(silent)
    )
