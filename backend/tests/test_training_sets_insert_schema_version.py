# backend/tests/test_training_sets_insert_schema_version.py
"""切片一 P3：可执行路径里的每一条 `INSERT INTO training_sets` 都必须显式给
`schema_version`。

为什么（spec §3.3）：PostgreSQL 的 `training_sets.schema_version` 带
`DEFAULT 1`。#183 起产物已是第 2 代，任何**省略该字段**的 INSERT 都会**静默**
把行标成第 1 代 —— 没有报错、没有告警，只是数据错了。

本片刻意不去掉那个 `DEFAULT 1`（改它属 DDL 变更 ⇒ 需受治理 migration，且会让
P6b 形状闸门的 `schema.sql` md5 锚失配、必须重新生成整份闸门文件，代价与收益
不成比例；已登记为残留 TS1-R1）。⇒ 只能靠本守卫在写侧堵。

⚠️ 匹配窗口是**列清单**，不是「到分号为止」，更不是按行：
   · 按行会把在场 5 条跨行语句**误报为缺字段**；
   · 「到分号为止」在 `generate_training_sets.py` 那条上会跑飞 —— 它是 asyncpg
     参数化查询，整条 SQL 里**根本没有分号**。
   取「紧随表名之后的那一对配平圆括号」对在场三种写法全都成立。

⛔⛔ **本守卫的【已知边界】—— 表名不在文本里时，任何文本扫描都看不见**

实测漏掉、且**本层无法修复**的三种（表名来自变量，源码文本里根本没有
`training_sets` 这个词）：

    f"INSERT INTO {TBL} (...)"              # f-string
    "INSERT INTO {} (...)".format(TBL)      # .format()
    "INSERT INTO " + TBL + " (...)"         # 常量相加

⚠️ ⛔ **不要为此把判据放宽成「`insert into` 后面跟任何东西」** —— 那会在每一条
   插入**别的表**的语句上误报，守卫当场失去可用性（本仓教训：守卫必须在当前树上
   为绿，否则就是一张放行许可证）。

⇒ 这条边界的**真正补偿措施在数据库层**：去掉 PostgreSQL 的
  `training_sets.schema_version DEFAULT 1`，让漏给字段的写入**直接失败**（fail-closed）——
  那样无论 SQL 是怎么拼出来的都挡得住。该项已登记为**残留 TS1-R1**（属 DDL 变更，
  需受治理 migration，且会让 P6b 形状闸门的 `schema.sql` md5 锚失配）。

⛔⛔ **本守卫的【定位】—— 请先读这一段再改它**

本守卫经历了 **10 轮对抗性评审、10 次被攻破**，其中 **3 次是真假绿**（守卫报绿而语句
确实缺字段）。每一次修完，下一轮又从**新的角度**打进来：注释冒充列名 → 大小写/换行/限定名
→ 关键字间夹注释 → `+` 拼接 → 转义序列 → 限定符点号周围 → 注释里的右括号 → 嵌套注释
→ 行注释里的 `/*`。

**这不是判据写得不够细，是路线本身的天花板**：本守卫在用**文本扫描**去模拟一个
**SQL 词法分析器**，而宿主语言（Python / shell / YAML / Markdown）的引号、注释、拼接
与 SQL 自己的引号、注释互相嵌套 —— 组合是**开放**的，补丁永远慢一步。

⇒ **定位**：本守卫是**辅助防线**，覆盖「**SQL 以字面量写在源码里**」这一类，
   ⛔ **不声称覆盖全部写入路径**。已知它挡不住的：表名来自变量、被 `/* */` 注掉的语句。
⇒ **唯一的完备防线是 TS1-R1**（数据库层 fail-closed）。**在 TS1-R1 落地之前，
   ⛔ 不要把本守卫当成「这件事已经有人管了」的依据。**
⇒ 若日后又发现新的绕过：先问**值不值得再补一层**，而不是条件反射地补。
   判据是「TS1-R1 落地了没有」—— 落地之后，本守卫的边际价值会大幅下降。
"""
from __future__ import annotations

import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SELF = Path(__file__).resolve()

#: ⛔ **发现步骤不能用固定字面量 `text.find("INSERT INTO training_sets")`**：它区分大小写、
#:    且只认「INTO 与表名之间恰好一个空格、无 schema 限定」这一种拼法。codex 复审实测：
#:    往作用域里追加三条**合法且缺字段**的 SQL —— 小写 `insert into`、`INSERT` 与 `INTO`
#:    之间换行、`public.training_sets` —— 守卫**照样 `1 passed`**（PostgreSQL 侧确认三条
#:    都是合法语句）。而既有 12 处仍满足计数断言，于是**新写入方可以静默绕过**、拿到
#:    `DEFAULT 1`，把第 2 代产物错标成第 1 代。
#: ⚠️ **表示空白的转义序列**也要当成间隔跳掉：Python 字面量里
#:    `"INSERT INTO\\ntraining_sets (…)"` 执行时是合法 SQL（`\n` 就是换行），
#:    但**源码文本**里是「反斜杠 + 字母 n」两个字符 —— 只跳反斜杠会留下一个 `n`，
#:    发现层当场瞎掉（codex 第六轮实测：那样写守卫仍报 `1 passed`）。
#: ⛔ 这一类是**可穷举**的：SQL 里的空白只有 空格/制表/换行/回车，写法就这几种。
#: ⛔ PostgreSQL 词法里的空白是 `space [ \t\n\r\f\v]`（见 `src/backend/parser/scan.l`）——
#:    **这是个封闭集合**，照抄全集即可，不必再打地鼠。
#:    实测：漏掉 `\f` / `\v` 时 `INSERT\fINTO training_sets (…)` 是合法 SQL，
#:    而精确网与粗网**同时落空** ⇒ 假绿。
_PG_SPACE = " \t\n\r\f\v"
_WS_ESCAPE_RE = re.compile(
    r"\\(?:u000[bBcC]|x0[bBcC]|u0020|x20|0(?:13|14|40)|[ntrfv])"
)


#: ⛔⛔ **发现层是一个【非破坏性的游标扫描器】，既不抹除、也不用正则。**
#:
#: 两条约束是十五轮打出来的，缺一不可：
#:
#: ① **不抹除** —— 抹除是**破坏性**的，破坏的代价是**漏报（瞎）**。
#:    第 9 / 10 / 12 / 13 轮四次都是「抹掉了不该抹的 ⇒ 真语句从发现层消失 ⇒ 假绿」：
#:    未闭合 `/*` 抹到文末、**行注释**里的 `/*`、**SQL 字符串**里的 `/*`、heredoc 与**美元引号**。
#:    每次我的修法都是「再教它认一种上下文」，而上下文是**开放**的（`E'…'`、`U&'…'`、
#:    各种宿主字符串……）—— **数不完**。
#:
#: ② **不用正则** —— 正则**做不了嵌套**。第 15 轮：
#:    `INSERT /* outer /* inner */ outer */ INTO training_sets (…)` 是合法 PostgreSQL，
#:    而非嵌套的注释模式在**第一个** `*/` 就停 ⇒ 两条正则都匹配不上 ⇒ **假绿**。
#:    ⚠️ 第 13 轮我把注释处理从（嵌套感知的）抹除搬进（非嵌套的）正则间隔时，
#:       判断过「关键字之间放嵌套注释很荒谬」—— **那个判断是错的**，它在声明的覆盖范围内。
#:
#: ⇒ 游标扫描器同时满足两条：**只前进、不改写原文**（非破坏性），且**手写的跳过逻辑
#:    可以嵌套感知**。认不全某种语法时最坏是**推进失败 ⇒ 落进粗网报「判不了」（吵）**，
#:    ⛔ 而不是把真语句变没（瞎）。

#: `--` 行注释的终止符。⛔ **不能只找物理换行** —— Python 字面量
#:    `"INSERT -- seed row\\nINTO training_sets (…)"` 运行时是合法 SQL（`\\n` 就是换行），
#:    但**源码里没有物理换行** ⇒ 行注释「永不结束」⇒ 推进失败 ⇒ 语句从两张网里同时消失
#:    ⇒ **假绿**（codex 第十六轮实测）。
#: ⛔ 换行的转义写法同样是**封闭集合**，照抄即可。
_NEWLINE_ESCAPE_RE = re.compile(r"\\(?:u000[aAdD]|x0[aAdD]|0(?:12|15)|[nr])")


def _line_comment_end(text: str, i: int) -> int | None:
    """返回 `--` 行注释结束后的下标；找不到终止符返回 None。"""
    phys = text.find("\n", i)
    esc = _NEWLINE_ESCAPE_RE.search(text, i)
    cands = []
    if phys != -1:
        cands.append(phys + 1)
    if esc is not None:
        cands.append(esc.end())
    return min(cands) if cands else None


def _skip_gap(text: str, i: int, *, required: bool, extra: str = "") -> int | None:
    """跳过关键字之间允许出现的东西，返回新下标；`required` 时至少要跳掉一个字符。

    允许：空白 / `--` 行注释 / `/* */` 块注释（**嵌套感知**）/ 宿主引号 / `+` / 续行反斜杠 /
          表示空白的转义（`\n` `\t` `\r` `\x20` `\u0020` `\040`）。
    `extra` 是额外容忍的字符，只给**粗网**用（见 `_find_inserts` 里劈开表名那一处）。
    """
    n, start = len(text), i
    while i < n:
        ch = text[i]
        if ch in _PG_SPACE:
            i += 1
        elif ch in "\"'+" or (extra and ch in extra):
            i += 1
        elif text.startswith("--", i):
            k = _line_comment_end(text, i)
            if k is None:
                return None
            i = k
        elif text.startswith("/*", i):
            depth, k = 1, i + 2          # ⭐ 嵌套感知 —— 正则做不到的就在这里
            while k < n and depth:
                if text.startswith("/*", k):
                    depth += 1; k += 2
                elif text.startswith("*/", k):
                    depth -= 1; k += 2
                else:
                    k += 1
            if depth:
                return None              # 注释没闭合 ⇒ 推进不了
            i = k
        elif ch == "\\":
            m = _WS_ESCAPE_RE.match(text, i)
            i = m.end() if m else i + 1
        else:
            break
    if required and i == start:
        return None
    return i


def _match_word(text: str, i: int, word: str) -> int | None:
    """大小写不敏感地匹配一个关键字/标识符，返回其后的下标。"""
    seg = text[i: i + len(word)]
    return i + len(word) if seg.lower() == word else None


#: ⛔⛔ **最后一张网：完全不解析间隔。**
#:
#: 上面两张网（精确 / 粗）共用 `_skip_gap`。这意味着我注释里写的那条不变量 ——
#: 「认不全某种语法时，最坏是**推进失败 ⇒ 落进粗网报『判不了』（吵）**」——
#: **其实没有兑现**：`_skip_gap` 一旦返回 None，两张网会**同时**落空，语句静默消失。
#: codex 第十六轮就是从这个缝里进来的（`--` 遇上转义换行）。
#:
#: ⇒ 这张网只认三个**词**，中间允许任何字符，⛔ 但**不许跨** `(` `)` `;`。
#:    不许跨括号是被干净树上的误报逼出来的：
#:        `INSERT INTO p15_targets (id) SELECT id FROM training_sets`
#:    这是往**另一张表**写的合法语句，中间的 `(id)` 把它排除掉。
#: ⚠️ 它只用来报「判据够不着」**让测试红**，不参与「通过」的判定 ——
#:    所以它宁可宽一点：多红一条有人看，少红一条没人知道。
_SPAN = r"(?:(?![(;)])[\s\S])"
#: 表名被劈开时中间只可能是「下划线 / 空白 / 宿主引号 / `+` / 续行反斜杠」。
#: ⛔ 这里**不能**用 `_SPAN`（任意字符）—— 实测它会把 runbook 里的**文件路径**
#:    `/data/training-sets/000001.SZ_….zip` 当成表名（中间是连字符），
#:    连带把同一段里 `INSERT INTO p11_expected VALUES …`（往**另一张表**写）拖成误报。
_NAME_SPLIT = r"[\s_\"'+\\]"
_LAST_RESORT_RE = re.compile(
    # ⚠️ 窗口 400/200 是**实测**定出来的：200/80 兜不住「长注释夹在关键字之间」，
    #    而放宽到 400/200 在干净树上**多报 0 条**（800/400 也是 0，但没有额外收益）。
    rf"insert{_SPAN}{{1,400}}?into{_SPAN}{{0,200}}?training{_NAME_SPLIT}{{0,12}}?sets"
    r"(?![A-Za-z0-9_$])",          # ⛔ 词边界：否则 `training_sets_audit` 也被拖下水
    re.I,
)

#: 标识符：普通形式 `[A-Za-z_][A-Za-z0-9_$]*`（引号形式的引号已被 `_skip_gap` 当作宿主
#: 定界符吃掉，所以这里不必再写引号分支）。
_IDENT_RE = re.compile(r"[A-Za-z_\u0080-\uffff][A-Za-z0-9_$\u0080-\uffff]*")


def _match_ident(text: str, i: int) -> int | None:
    m = _IDENT_RE.match(text, i)
    return m.end() if m else None


#: ⛔⛔ **表名不是字面量的 INSERT，也要报出来。**
#:
#: 这是本守卫**最后一个静默盲区**，而我此前在三份文档里都写着它「会落进
#: 判据够不着、让测试红（吵）」—— **那是不实陈述**。实测四种写法
#: （f-string 变量 / `.format()` / 常量相加 / `%` 格式化）**全部静默不可见**：
#: 三张网都要求表名里有字面量的 `training` 与 `sets`，而它们一个字都没有。
#:
#: ⇒ 改成：凡 `INSERT INTO` 后面**不是字面量表名**的，一律报「判据够不着」。
#: ⚠️ 这等于把**所有**动态表名的写入都报出来，不只是 `training_sets` 的 ——
#:    所以先量了再做：**干净树上 0 条**，零代价。
#:    将来真要往别的表做动态写入，必须显式在这里认领并说明理由。
def _find_dynamic_targets(text: str) -> list[int]:
    """扫出「`INSERT INTO` 之后不是字面量表名」的位置。"""
    out, n, i = [], len(text), 0
    while i < n:
        if text[i] not in "iI":
            i += 1
            continue
        start = i
        j = _match_word(text, i, "insert")
        if j is None:
            i += 1
            continue
        j = _skip_gap(text, j, required=True)
        j = j if j is None else _match_word(text, j, "into")
        if j is None:
            i = start + 1
            continue
        k = _skip_gap(text, j, required=False)
        if k is None or k >= n or not _IDENT_RE.match(text, k):
            out.append(start)      # 后面是 `{` / `%` / 哨兵 / 字面量到此为止
        i = start + 1
    return out


def _find_inserts(text: str, *, loose: bool):
    """扫出 `INSERT … INTO … [public.] training_sets`，产出 (起点, 表名之后的下标)。

    `loose=True` 是**粗网**：只要求走到「像表名的东西」，用来兜住精确推进走不通的写法。
    """
    out, n, i = [], len(text), 0
    while i < n:
        if text[i] not in "iI":
            i += 1
            continue
        start = i
        j = _match_word(text, i, "insert")
        if j is None:
            i += 1
            continue
        j = _skip_gap(text, j, required=True)
        j = j if j is None else _match_word(text, j, "into")
        j = j if j is None else _skip_gap(text, j, required=True)
        if j is None:
            i = start + 1
            continue
        # 可选的 schema 限定符。⛔ **不写死 `public`** —— 写死一个标识符和写死一个字符类
        #    是同一个毛病：数不完。实测 `INSERT INTO qmt.training_sets (…)` 两网皆空 ⇒ 假绿。
        #    ⇒ 改成「任意标识符 + 点」，最多两级（PostgreSQL 不支持跨库引用）。
        for _ in range(2):
            k = _match_ident(text, j)
            if k is None:
                break
            k2 = _skip_gap(text, k, required=False)
            if k2 is None or k2 >= n or text[k2] != ".":
                break                                   # 后面不是点 ⇒ 这不是限定符，回退
            k3 = _skip_gap(text, k2 + 1, required=False)
            if k3 is None:
                break
            j = k3
        end = _match_word(text, j, "training_sets")
        if end is None and loose:
            # 粗网：容忍表名被引号/拼接劈开（`"INSERT INTO training_" "sets (…)"`）。
            # ⛔ 这里必须**额外容忍 `_`** —— 劈开点常常就落在下划线两侧，
            #    漏掉它就等于把这种写法静默放行（实测：G3「表名劈开」由抓到退回假绿）。
            end = _match_word(text, j, "training")
            if end is not None:
                e2 = _skip_gap(text, end, required=False, extra="_")
                end = _match_word(text, e2, "sets") if e2 is not None else None
        # ⛔ **词边界**：不加的话 `INSERT INTO training_sets_audit (…)` 会被当成本表 ⇒ **误报**
        #    （旧的正则版同样如此）。表名后面不许紧跟标识符字符。
        if end is not None and (end >= n or not (text[end].isalnum() or text[end] in "_$")):
            out.append((start, end))
            i = end
        else:
            i = start + 1
    return out


#: 只扫**可执行**路径。#: 只扫**可执行**路径。`docs/superpowers/**` 是历史记述（plan / spec 里引用这条
#: SQL 的地方不是要跑的东西），显式不在作用域内。
_SCOPE_GLOBS = (
    "backend/**/*.py",
    "backend/**/*.sql",
    "backend/**/*.sh",
    "docs/runbooks/**/*.md",
    "docs/runbooks/**/*.sql",
    ".github/workflows/*.yml",
)

#: 已知的**非 SQL** 命中：test double 的分派谓词
#: （`if "INSERT INTO training_sets" in query:`）。它是字符串比较、不是要执行的
#: SQL，结构上永远不可能「出现 schema_version」，不排除则守卫恒红。
#: ⚠️ 按**形状**白名单，不按行号 —— 行号会随无关改动漂移。
_NON_SQL_SHAPE = '" in query'

#: 另一类**非 SQL** 命中：被反引号整个包起来的**散文提及**，形如
#: 「（spec §3.3 对 `INSERT INTO training_sets` 的计数连栽三轮）」。
#: ⚠️ 这是**结构性**判据、不是猜测：反引号跨度在 markdown / docstring 里是**代码跨度**，
#:    在 `.sh` 里是命令替换（真跑会把 `INSERT` 当命令、直接失败）—— 三种宿主里
#:    **都不是可执行的 SQL 写入路径**。
#: ⛔ 不设硬性条数：散文提及会随文档自然增减（本仓「别写含自身的总数」那条教训）；
#:    但它**单独计数并在防空转断言里露出来**，不会被悄悄吃掉。
def _is_prose_mention(text: str, start: int, end: int) -> bool:
    return start > 0 and text[start - 1] == "`" and end < len(text) and text[end] == "`"


def _scope_files() -> list[Path]:
    out: list[Path] = []
    for pattern in _SCOPE_GLOBS:
        for path in sorted(ROOT.glob(pattern)):
            if path.is_file() and path.resolve() != SELF:
                out.append(path)
    assert len(out) >= 20, f"作用域只解析出 {len(out)} 个文件 —— glob 坏了（防空转）"
    return out


#: 块注释在下面**就地**嵌套感知地剥（见 `_column_names` 与 `_column_list`），这里只管行注释。
_LINE_COMMENT = re.compile(r"--[^\n]*")


#: ⛔⛔ **单遍词法**。剥注释必须一遍走完，不能「先剥块注释、再剥行注释」——
#: 两遍会互相污染，实测造出三条**误报**（守卫在合法代码上变红，而且报文是错的）：
#:
#:   ```sql
#:   (stock_code, -- 注意 /* 这里
#:    schema_version)
#:   ```
#:   `/*` 只是**行注释里的文字**，`schema_version` 是真列。而先剥块注释那一遍
#:   会把它当成未闭合注释、一路吃到末尾 ⇒ 守卫报「**缺 schema_version**」——
#:   字段明明在场，⛔ **报文本身是错的**，比单纯报错更误导人。
#:   （同族：`'a--b'` / `'a/*b'` 这种引号内的定界符。）
#:
#: ⚠️ 顺带去掉重复实现：`_column_list` 的配平扫描此前另有一份同样的嵌套注释逻辑。
#:    本仓老教训「同一条判据存在于多处实现，改完必须两处都验」—— 这里直接去掉重复。
#: ⚠️ 引号内的内容**原样保留**（不是抹掉）：`"schema_version"` 是**带引号的标识符**，
#:    是真列名，抹掉它会造出新的漏报。
def _strip_comments(s: str) -> str:
    """一遍扫完：`/* */`（嵌套感知）与 `--` 换成空格；引号内原样保留。"""
    out, i, n = [], 0, len(s)
    while i < n:
        ch = s[i]
        if s.startswith("/*", i):
            depth, k = 1, i + 2
            while k < n and depth:
                if s.startswith("/*", k):
                    depth += 1; k += 2
                elif s.startswith("*/", k):
                    depth -= 1; k += 2
                else:
                    k += 1
            out.append(" ")
            i = k
        elif s.startswith("--", i):
            k = s.find("\n", i)
            if k == -1:
                out.append(" ")
                break
            out.append(" ")
            i = k                      # 换行本身留着，token 切分要靠它
        elif ch in "'\"":
            k = i + 1
            while k < n and s[k] != ch:
                k += 1
            out.append(s[i: k + 1])    # 引号内原样保留
            i = k + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def _column_names(cols: str) -> set[str]:
    """把列清单原文切成**真正的列名集合**。

    ⛔ 不能直接对原文做 `"schema_version" in cols` 子串判断 —— 一句
       `/* schema_version uses the default */` 注释就能把它喂饱，而真列名并不在场
       （codex 对抗性评审实测复现：那样改完守卫仍报 `1 passed`，PostgreSQL 侧
       确认该列缺席 ⇒ 那一行会被 DEFAULT 1 静默标成第 1 代）。

    ⇒ 先剥 SQL 注释（`/* */` 与 `--`），再按逗号切分，逐个 token 剥掉空白、
      引号与 Python 字符串拼接残留，最后按**整个标识符**比对。
    """
    inner = cols.strip()
    assert inner.startswith("(") and inner.endswith(")"), inner[:60]
    inner = inner[1:-1]
    inner = _strip_comments(inner)
    names = set()
    for tok in inner.split(","):
        # 跨行的 asyncpg 查询会把引号与换行夹进 token（实测形如 '"\n        "schema_version'）
        tok = tok.strip().strip('"').strip("'").strip()
        tok = tok.split()[-1] if tok.split() else ""
        tok = tok.strip('"').strip("'")
        if tok:
            names.add(tok)
    return names


#: ⛔⛔ **无法逐字还原运行时字符串的宿主，遇到歧义就说「判不了」。**
#:
#: 「源码文本 ≠ 运行时字符串」这条根打穿了**四轮**（11 / 16 / 17 / 18）。
#: `.py` 有精确解（语法树，见 `_scan_units`）；`.sh` / `.yml` / `.md` **没有**，
#: 而它们同样会拼接：
#:   · 第 11 轮：相邻 Python 字面量拼接，`--` 注掉了下一段里的 `schema_version`；
#:   · 第 18 轮：**shell 的引号拼接** —— `/""*` 运行时就是 `/*`，
#:     `(stock_code, /""* schema_version, *""/ stock_name, …)` 里字段**被注掉**，
#:     源码里却看不出任何注释 ⇒ 守卫把它当成在场的列 ⇒ **假绿**。
#:
#: ⇒ 不再逐种写法去猜。这些宿主的列清单里只要出现**宿主引号**或 `--`，
#:   就断言「**判据够不着**」让测试红 —— ⛔ 宁可吵，不可瞎。
#: ⚠️ 实测：干净树上 11 条非 `.py` 列清单**一个引号都没有**，这条规则零代价。
#: ⚠️ 要真正判准这一类得给每种宿主写词法器；在 TS1-R1（数据库层 fail-closed）
#:    落地之前，不值得。
#: ⛔⛔ **正字符集** —— 合法列清单里只可能有：标识符字符、`$`、逗号、括号、空白。
#: ⚠️ 这是**反过来写**的，而且是被逼的：我前后**五次**往「歧义字符集」里补字符
#:    （宿主引号 → `--` → …… → 第 19 轮的**反斜杠续行**，shell 会把
#:    `/` + 反斜杠换行 + `*` 拼成 `/*`）。而「**数不完**」这四个字就写在本文件
#:    自己的注释里 —— 枚举攻击面永远漏，枚举**合法面**才是封闭的。
#: ⚠️ 实测：干净树上非 `.py`/`.sql` 宿主的 11 条列清单，**没有一条**含集合外字符。
_COLS_ALLOWED = re.compile(r"[A-Za-z0-9_$,() \t\r\n]")


def _ambiguous(cols: str, *, exact_host: bool) -> str | None:
    """列清单里有没有「源码与运行时可能不一致」的东西；有就返回它的名字。

    `exact_host` 指 `.sql`（源码就是运行时文本）与 `.py`（已由语法树还原）。
    ⛔ 但「精确宿主」不等于「这一条一定精确」—— f-string 的插值**求不出来**，
       哨兵在场时同样判不了（codex 第 21 轮）。
    """
    if _UNRESOLVED in cols:
        return "未解析的 f-string 插值（它可以求值成 `/*` 把字段注掉）"
    if exact_host:
        return None
    odd = sorted({c for c in cols if not _COLS_ALLOWED.match(c)})
    if odd:
        return f"合法列清单不该有的字符 {odd}（宿主拼接后可能变出/变没注释）"
    return None


def _column_list(text: str, after: int) -> str | None:
    """取 `INSERT INTO training_sets` 之后紧随的配平圆括号内容。

    返回 None 表示**这里没有列清单**（不是「检查通过」）—— 调用方必须把它
    与「检查通过」区分开来处理，否则一个 `continue` 就同时制造漏报与假阳性
    （本仓「守卫里一个 continue 混了两件事」的老教训）。
    """
    # ⚠️ 找左括号时要**同时跳过空白与 SQL 注释**：`training_sets /* c */ (cols)` 与
    #    `training_sets -- c\n  (cols)` 都是合法 SQL。只跳空白的话，这两种会掉进
    #    「判据够不着」兜底分支 —— **红是红了，但报文说「判不了」，而其实完全判得了**
    #    （实测确认过走的是兜底分支）。兜底分支应该留给真正够不着的形态。
    i = after
    while i < len(text):
        if text[i] in " \t\r\n":
            i += 1
        elif text.startswith("/*", i):
            depth, k = 1, i + 2
            while k < len(text) and depth:
                if text.startswith("/*", k):
                    depth += 1; k += 2
                elif text.startswith("*/", k):
                    depth -= 1; k += 2
                else:
                    k += 1
            if depth:
                return None
            i = k
        elif text.startswith("--", i):
            j = text.find("\n", i)
            if j == -1:
                return None
            i = j + 1
        else:
            break
    if i >= len(text) or text[i] != "(":
        return None
    # ⛔ 配平扫描必须**跳过注释与引号内的内容**，不能只数括号（codex 第八轮实测）：
    #    `(stock_code /* , schema_version) */, stock_name, …)`
    #    注释**里面**那个 `)` 会提前终止扫描 ⇒ 截出 `(stock_code /* , schema_version)`，
    #    其中的注释**未闭合**、剥注释的正则匹配不到 ⇒ `schema_version` 字样作为「列名」
    #    幸存 ⇒ 守卫**判为通过**，而 PostgreSQL 会忽略该注释、用 DEFAULT 1。
    #    ⇒ 这是一次**真假绿**，不是误报。引号同理（`'x)y'` 里的 `)` 也不该算）。
    depth = 0
    j = i
    n = len(text)
    while j < n:
        ch = text[j]
        if text.startswith("/*", j):                       # 块注释（**嵌套感知**）：整段跳过
            # ⛔ **必须用【另一个】计数器** —— 这里原本复用了外层的 `depth`（它数的是**括号**），
            #    进注释就把括号深度覆盖掉了：注释闭合后 `depth == 0`，列清单自己的右括号
            #    再减一变成 -1，**永远返回不了** ⇒ 合法的
            #    `(stock_code /* ticker */, schema_version)` 被判成「判据够不着」⇒ **CI 在正确代码上变红**。
            # ⚠️ 这是**假阳性**（前面十三轮全是假绿），而且是我上一轮自己写的 bug。
            #    ⭐ 我的回归套件当时**没抓到它** —— 因为所有带注释的用例都是「字段**缺失**」，
            #      红得「看起来对」，其实红的理由是错的。⇒ **正向对照必须覆盖每一种语法形态**，
            #      不能只对「裸的正常语句」做对照。
            comment_depth, k = 1, j + 2
            while k < n and comment_depth:
                if text.startswith("/*", k):
                    comment_depth += 1; k += 2
                elif text.startswith("*/", k):
                    comment_depth -= 1; k += 2
                else:
                    k += 1
            if comment_depth:
                return None                                # 注释没闭合 ⇒ 判不了
            j = k
            continue
        if text.startswith("--", j):                       # 行注释：跳到行尾
            k = text.find("\n", j)
            if k == -1:
                return None
            j = k + 1
            continue
        if ch in "'\"":                                    # 引号：整段跳过
            k = text.find(ch, j + 1)
            if k == -1:
                return None
            j = k + 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
        j += 1
    return None


#: ⛔⛔ **`.py` 宿主：扫描【ast 还原后的运行时字符串】，不扫源码文本。**
#:
#: 「源码文本 ≠ 运行时字符串」这条根，连着打穿了三轮：
#:   · 第 11 轮：相邻字面量拼接，`--` 注掉了下一段里的 `schema_version`；
#:   · 第 16 轮：`--` 后面是**转义**换行 `\n`，源码里没有物理换行 ⇒ 行注释永不结束；
#:   · 第 17 轮：**注释定界符自己被劈开** —— `… /" "* … schema_version, *" "/ …`
#:     运行时是 `/* … */`（字段被注掉），源码里却根本不存在 `/*`。
#:
#: 我前两轮的修法都是「再教扫描器认一种写法」，而这正是代码里自己写着的那条
#: 「**数不完**」。⇒ 对 `.py` 有**精确解**：用 Python 自己的语法树把字面量解出来。
#: `ast` 会把**相邻字面量折叠成一个常量**，并把所有转义序列还原 ——
#: 得到的就是运行时真正交给 PostgreSQL 的那串字符。
#:
#: ⚠️ 解不动的写法（`+` 拼接、`.format()`、f-string 的变量部分）不会凭空消失：
#:    **兜底网始终扫原文**，它们会落进「判据够不着」（吵），不是「瞎」。
#: ⚠️ 但**表名本身**是拼出来的（`{tbl}` / `%s` / 常量相加）时，兜底网也够不着 ——
#:    那一类由 `_find_dynamic_targets` 单独接住（见下）。此处曾写「都会变红」，
#:    **是不实陈述**，已订正。
#: 未解析的 f-string 插值的哨兵。⛔ 取一个**绝不会出现在合法列清单里**的字符，
#: 这样它自动落进 `_ambiguous` 的正字符集之外 —— 不必再为它单写一条判据。
_UNRESOLVED = "\x00"


def _line_starts(text: str) -> list[int]:
    out, pos = [0], text.find("\n")
    while pos != -1:
        out.append(pos + 1)
        pos = text.find("\n", pos + 1)
    return out


def _py_literals(text: str):
    """产出 `.py` 里每个字符串字面量的 (运行时值, 行号, 原文起点, 原文终点)。

    返回 None 表示**这个文件解析不了**（语法错误）—— 调用方要退回扫原文，
    ⛔ 不能当成「没有字面量」（那是把解析失败伪装成检查通过）。
    """
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None
    starts = _line_starts(text)

    def abs_pos(lineno, col):
        # ast 的 col_offset 按 **UTF-8 字节**计，这里换算回字符下标
        line_start = starts[lineno - 1]
        line = text[line_start: starts[lineno] if lineno < len(starts) else len(text)]
        return line_start + len(line.encode("utf-8")[:col].decode("utf-8", "ignore"))

    out, inner = [], set()
    for node in ast.walk(tree):
        if isinstance(node, ast.JoinedStr):
                    # f-string：变量部分**求不出来** ⇒ 放哨兵。
            # ⛔ 哨兵**必须落在列清单正字符集之外** —— 我原先放的是 `{}`，
            #    而 codex 第 21 轮实测：插值可以求值成 `/*` 与 `*/`，
            #        f"INSERT INTO training_sets (stock_code, {a} schema_version, {b} …)"
            #    运行时 `schema_version` **在注释里**，而扫描层看到的是
            #    `{} schema_version` —— 被当成真列名 ⇒ **假绿**。
            #    ⚠️ 表名是字面量，所以这和「动态表名」那条已知局限**不是同一件事**。
            for part in ast.walk(node):
                if part is not node:
                    inner.add(id(part))
            val = "".join(
                p.value if isinstance(p, ast.Constant) and isinstance(p.value, str)
                else _UNRESOLVED
                for p in node.values
            )
            out.append((val, node.lineno, abs_pos(node.lineno, node.col_offset),
                        abs_pos(node.end_lineno, node.end_col_offset)))
    for node in ast.walk(tree):
        if (isinstance(node, ast.Constant) and isinstance(node.value, str)
                and id(node) not in inner):
            out.append((node.value, node.lineno, abs_pos(node.lineno, node.col_offset),
                        abs_pos(node.end_lineno, node.end_col_offset)))
    return out


def _scan_units(path: Path, text: str):
    """产出 (待扫文本, 行号, 原文起点, 原文终点)。

    `.py` ⇒ 每个还原后的字面量各算一块；其它宿主 ⇒ 整篇原文一块。
    """
    if path.suffix == ".py":
        lits = _py_literals(text)
        if lits is not None:
            return lits
    return [(text, 1, 0, len(text))]


#: ⛔⛔ **逐文件扫描抽成函数，是为了让整套攻击语料能变成【常驻测试】。**
#:
#: 之前这些判据只能靠临时脚本往真文件里注样本来验 —— 临时脚本不进仓库，
#: 于是「谁把某张网从主循环里摘掉」**没有任何常驻测试会红**（干净树上没有那种样本）。
#: 实测：把兜底网从主循环摘掉，四条常驻测试**全绿**。
#: 这正是本仓老教训「**守卫只钉『名字在不在』挡不住行为被改掉**」。
#: ⇒ 抽成 `_scan_source(path, text)` 之后，攻击语料直接喂文本即可。
def _scan_source(path: Path, text: str):
    """扫一份源码，返回 (missing, unknown_shape, checked, whitelisted, prose)。

    `path` 只用来取后缀（决定宿主语言）与拼报文里的相对路径，**不读盘**。
    """
    missing: list[str] = []
    unknown_shape: list[str] = []
    checked = whitelisted = prose = 0
    rel = path
    text = text
    # ⛔ 扫的是**还原后的运行时字符串**（`.py`）或原文（其它宿主），见 `_scan_units`。
    units = _scan_units(path, text)
    hits: list[tuple[str, int, int, int, int]] = []  # (单元文本, 起点, 表名后下标, 行号, 单元原文终点)
    seen_per_unit: list[tuple[int, int, int]] = []   # (原文起点, 原文终点, 该单元内已认领的条数)

    for utext, uline, ustart, uend in units:
        precise = _find_inserts(utext, loose=False)
        precise_starts = {s for s, _ in precise}
        coarse_starts = {cs for cs, _ in _find_inserts(utext, loose=True)}
        # ⛔⛔ **三张网都在【同一份文本】上跑，按【出现位置】去重。**
        #    第 20 轮的缺陷就出在这里：我曾按「扫描单元」去重 —— 而非 `.py` 宿主的
        #    扫描单元**就是整个文件**，于是**一条被认出来的 INSERT 会把整份文件的
        #    兜底网关掉**。同一文件里再加一条 `INSERT INTO U&"training_sets" (…)`
        #    （合法的 PostgreSQL 标识符写法、且缺字段）就**静默通过**了。
        #    ⇒ 去重的粒度必须是「**这一条出现**」，不是「这一片文本」。
        last_resort_starts = {mm.start() for mm in _LAST_RESORT_RE.finditer(utext)}
        dynamic_starts = set(_find_dynamic_targets(utext))
        for cs in sorted(
            (coarse_starts | last_resort_starts | dynamic_starts) - precise_starts
        ):
            ln = uline if path.suffix == ".py" else utext.count("\n", 0, cs) + 1
            unknown_shape.append(
                f"{rel}:{ln}: 判据够不着 -> {utext[cs: cs + 60]!r}"
            )
        for pos, after in precise:
            ln = uline if path.suffix == ".py" else utext.count("\n", 0, pos) + 1
            hits.append((utext, pos, after, ln, uend))
        seen_per_unit.append(
            (ustart, uend,
             len(precise_starts | coarse_starts | last_resort_starts | dynamic_starts))
        )

    if path.suffix == ".py":
        # ⛔ `.py` 还要**额外扫一遍原文** —— `ast` 解不动的拼法（`+` 相加、`.format()`、
        #    f-string 的变量部分）会把一条语句劈到**两个字面量**里，任何单个字面量
        #    的还原文本里都看不见它。
        # ⚠️ 去重按**条数**对账，不按跨度：一个字面量里可能同时有「已认领的一条」和
        #    「跨到下一个字面量、因而没被认领的另一条」——按跨度去重会把后者一起吞掉
        #    （这正是第 20 轮那个缺陷的 `.py` 版本）。
        raw_per_unit: dict[int, int] = {}
        outside = []
        for mm in _LAST_RESORT_RE.finditer(text):
            for idx, (ustart, uend, _) in enumerate(seen_per_unit):
                if ustart <= mm.start() < uend:
                    raw_per_unit[idx] = raw_per_unit.get(idx, 0) + 1
                    break
            else:
                outside.append(mm.start())
        for idx, raw_n in raw_per_unit.items():
            ustart, _, claimed_n = seen_per_unit[idx]
            for _ in range(max(0, raw_n - claimed_n)):
                lineno = text.count("\n", 0, ustart) + 1
                unknown_shape.append(
                    f"{rel}:{lineno}: 判据够不着（跨字面量拼接，还原不出运行时文本）"
                    f" -> {text[ustart: ustart + 60]!r}"
                )
        for start in outside:
            lineno = text.count("\n", 0, start) + 1
            unknown_shape.append(
                f"{rel}:{lineno}: 判据够不着 -> {text[start: start + 60]!r}"
            )

    for utext, pos, after, lineno, uend in hits:
        # 非 SQL 白名单要看**原文**里字面量后面那一小段（`… " in query:`）
        tail = (text[uend - 1: uend + 20] if path.suffix == ".py"
                else utext[after: after + 20])
        cols = _column_list(utext, after)
        if cols is not None and _ambiguous(cols, exact_host=path.suffix in (".sql", ".py")):
            # ⛔ **源码换行 ≠ 运行时换行** —— 这是本守卫的根本局限，这里把它从
            #    「悄悄猜错」变成「明说判不了」。
            #    codex 第十一轮实测：两个**相邻的 Python 字面量**
            #        "-- optional metadata: "
            #        "schema_version,\n"
            #    在**源码里分两行**（`--` 被当成只注掉第一行），但**运行时拼成一行**
            #    ⇒ `schema_version` 落在 `--` 之后、**被 SQL 注释掉** ⇒ PostgreSQL 用
            #    `DEFAULT 1`。而守卫按源码换行判定，把它当成在场的列 ⇒ **假绿**。
            # ⇒ 只有 `.sql` 文件能保证「源码换行就是 SQL 换行」；其它宿主（.py / .sh /
            #    .yml / .md）里 SQL 是字符串，换行可能来自 `\n` 转义或相邻字面量拼接。
            #    ⇒ 非 `.sql` 文件的列清单里只要出现 `--`，一律报「判据够不着」**让测试红**。
            # ⚠️ 要真正判准这一类得上 AST 解析（把相邻字面量先拼出来）—— 那是 TS1-R1
            #    之外的另一条路；在 TS1-R1 落地前，**吵**比**瞎**重要。
            unknown_shape.append(
                f"{rel}:{lineno}: 判据够不着（列清单含 "
                f"{_ambiguous(cols, exact_host=path.suffix in ('.sql', '.py'))}）"
                f"-> {cols[:80]}"
            )
        elif cols is not None:
            checked += 1
            if "schema_version" not in _column_names(cols):
                missing.append(f"{rel}:{lineno}: 列清单缺 schema_version -> {cols[:100]}")
        elif _NON_SQL_SHAPE in tail:
            whitelisted += 1          # test double 的分派谓词，不是 SQL
        elif _is_prose_mention(utext, pos, after):
            prose += 1                # 反引号包住的散文提及，不是可执行 SQL
        else:
            # ⛔ 既不是列清单、又不是已知的非 SQL 形状 —— **报错**，不静默跳过。
            unknown_shape.append(
                f"{rel}:{lineno}: 未知写法 -> {utext[pos:after]!r}{tail!r}"
            )
    return missing, unknown_shape, checked, whitelisted, prose


def test_every_executable_insert_specifies_schema_version():
    missing: list[str] = []
    unknown_shape: list[str] = []
    checked = 0
    whitelisted = 0
    prose = 0

    for path in _scope_files():
        m_, u_, c_, w_, p_ = _scan_source(
            path.relative_to(ROOT), path.read_text(encoding="utf-8", errors="replace")
        )
        missing += m_
        unknown_shape += u_
        checked += c_
        whitelisted += w_
        prose += p_

    assert not unknown_shape, (
        "出现了本守卫判据够不着的 INSERT 写法 —— 不是「通过」，是**判不了**。\n"
        "请把它改成带列清单的写法，或在 _NON_SQL_SHAPE 旁边补一条有理由的白名单：\n"
        + "\n".join(unknown_shape)
    )
    assert checked >= 12, (
        f"只检查到 {checked} 条带列清单的 INSERT —— 少于已知的 12 条（防空转）。"
        f"要么作用域坏了，要么有语句被改成了判据够不着的写法"
        f"（同批：白名单 {whitelisted} 条、散文提及 {prose} 条）"
    )
    # ⛔ **散文提及也是一条「悄悄判通过」的出口，必须和白名单一样钉死数量。**
    #    第十八轮的教训是「改动只落在报告的那一处，没落在整条判据家族上」——
    #    `whitelisted` 当时钉了 `== 2`，而同一类出口的 `prose` 只计数、没断言。
    #    ⇒ 多出来的每一条都必须由人确认「它确实只是文字，不是要跑的 SQL」。
    assert prose == 1, (
        f"反引号包住的散文提及命中 {prose} 条，已知应为 1 条"
        f"（spec 计数那句的引用）。多出来的必须逐条确认不是真 SQL"
    )
    assert whitelisted == 2, (
        f"非 SQL 白名单命中 {whitelisted} 条，已知应为 2 条"
        f"（test_b2_reconnect_integration.py 的两处 test double 分派谓词）。"
        f"多出来的必须逐条确认不是真 SQL"
    )
    assert not missing, (
        "以下 INSERT 省略了 schema_version —— PostgreSQL 会用 DEFAULT 1 "
        "**静默**把行标成第 1 代：\n" + "\n".join(missing)
    )


# ---------------------------------------------------------------------------
# ⭐ **正向对照，常驻**（codex 第十四轮打回后新增）
#
# 前十三轮挖到的全是**假绿**（该红的没红），于是我的回归套件几乎全是「坏样本应变红」。
# 第十四轮挖到的是**假阳性**：合法的 `(stock_code /* ticker */, schema_version)`
# 被判成「判据够不着」⇒ **CI 在正确代码上变红**。根因是我上一轮在配平扫描里
# 复用了 `depth`（它数的是括号），进注释就把括号深度覆盖了。
#
# ⭐ **我的套件当时没抓到它** —— 因为所有带注释的用例都是「字段**缺失**」的，
#    红得「看起来对」，其实**红的理由是错的**。
# ⇒ 教训：**正向对照必须覆盖每一种语法形态**，不能只对「裸的正常语句」做对照。
#    否则解析器坏掉时，坏样本照样红，你看不出区别。
# ---------------------------------------------------------------------------

_VALID_FORMS = {
    "裸的": "INSERT INTO training_sets (stock_code, schema_version) VALUES (1,2);",
    "单层块注释": "INSERT INTO training_sets (stock_code /* ticker */, schema_version) VALUES (1,2);",
    "嵌套块注释": "INSERT INTO training_sets (stock_code /* a /* b */ c */, schema_version) VALUES (1,2);",
    "注释里含括号": "INSERT INTO training_sets (stock_code /* (x) */, schema_version) VALUES (1,2);",
    "注释在列清单末尾": "INSERT INTO training_sets (stock_code, schema_version /* z */) VALUES (1,2);",
    "行注释在列清单里": "INSERT INTO training_sets (stock_code, -- t\n schema_version) VALUES (1,2);",
    "限定表名": "INSERT INTO public.training_sets (stock_code, schema_version) VALUES (1,2);",
    "大小写混写": "insert Into training_sets (stock_code, schema_version) VALUES (1,2);",
    "关键字间嵌套注释": "INSERT /* a /* b */ c */ INTO training_sets (stock_code, schema_version) VALUES (1,2);",
    "限定符周围嵌套注释": "INSERT INTO public /* a /* b */ c */ . training_sets (stock_code, schema_version) VALUES (1,2);",
}


def test_valid_column_lists_with_comments_are_parsed_not_rejected():
    """⛔ 合法且**字段在场**的写法必须被**正常解析出字段**，不许掉进「判据够不着」。

    这条挡的是**假阳性** —— 守卫在正确代码上变红，比漏报更容易让人直接把它关掉。
    """
    broken = []
    for label, sql in _VALID_FORMS.items():
        hits = _find_inserts(sql, loose=False)
        if not hits:
            broken.append(f"{label}: 发现层就没扫到")
            continue
        cols = _column_list(sql, hits[0][1])
        if cols is None:
            broken.append(f"{label}: 列清单解析返回 None（会被判『判据够不着』）")
        elif "schema_version" not in _column_names(cols):
            broken.append(f"{label}: 解析出的列名里没有 schema_version -> {sorted(_column_names(cols))}")
    assert not broken, (
        "以下**合法且字段在场**的写法被守卫误判 —— 这是**假阳性**，"
        "会让 CI 在正确代码上变红：\n" + "\n".join(broken)
    )


# ---------------------------------------------------------------------------
# ⭐ **兜底网的独立判别力，常驻**（codex 第十六轮打回后新增）
#
# 精确网与粗网共用 `_skip_gap`。间隔一旦解析不动，两张网会**同时**落空 ——
# 而我在注释里写的不变量是「最坏落进粗网报『判不了』（吵）」。**那句话当时是假的。**
# 第十六轮就是从这个缝里进来的：Python 字面量里 `--` 后跟的是**转义**换行 `\n`
# （源码中没有物理换行）⇒ 行注释「永不结束」⇒ 推进失败 ⇒ 语句静默消失 ⇒ 假绿。
#
# ⇒ 本测试钉的是**这张网自己**的判别力：它必须在「间隔根本解析不动」时仍然报得出来，
#   同时不许把「往另一张表写」的合法语句拖下水（否则守卫在干净树上就是红的 ⇒
#   那等于一张放行许可证）。
# ---------------------------------------------------------------------------

_COLS6 = "(stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash)"

#: 这些形态里，间隔**故意**解析不动（注释没有终止符）。兜底网必须仍然报得出来。
_LAST_RESORT_MUST_CATCH = {
    "行注释完全无终止": f'"INSERT -- c INTO training_sets {_COLS6} VALUES (1);"',
    "块注释不闭合": f'"INSERT /* c INTO training_sets {_COLS6} VALUES (1);"',
}
#: ⚠️ 下面这两种曾经也够不着，**现已被精确网正面覆盖**，所以**不能**放进上面那个字典 ——
#:    放进去会让「防空转」那条断言失效（它要求样本确实够不着）：
#:      · `"INSERT -- seed\\nINTO …"`（行注释配**转义**换行，第十六轮）
#:      · `INSERT\fINTO …`（`\f` 也是 PostgreSQL 的空白）
#:    它们的覆盖由 `_skip_gap` 负责，回归脚本里另有用例。

#: ⛔ 反向：往**另一张表**写、只是碰巧 `SELECT … FROM training_sets` 的合法语句。
#:    兜底网若把它算进来，守卫在干净树上就是红的 —— 那不是严格，是**放行许可证**
#:    （本仓老教训：「守卫必须在功能还没写的当前树上就是绿的」）。
_LAST_RESORT_MUST_NOT_CATCH = {
    "插另一张表": "INSERT INTO p15_targets (id) SELECT id FROM training_sets;",
    "插前缀相同的表": f"INSERT INTO training_sets_audit {_COLS6} VALUES (1);",
}


def test_last_resort_net_has_independent_discriminating_power():
    missed = [k for k, s in _LAST_RESORT_MUST_CATCH.items() if not _LAST_RESORT_RE.search(s)]
    assert not missed, (
        "以下形态的**间隔解析不动**，而兜底网也没接住 —— 语句会从三张网里同时消失、"
        "守卫静默报绿：\n  " + "\n  ".join(missed)
    )
    # ⭐ 防空转：上面那条断言必须真的经过了「精确网够不着」的路径，否则它只是在
    #    重复验证精确网。这里逐条确认精确网**确实**认不出它们。
    not_actually_unreachable = [
        k for k, s in _LAST_RESORT_MUST_CATCH.items() if _find_inserts(s, loose=True)
    ]
    assert not not_actually_unreachable, (
        "以下样本本意是「间隔解析不动」，但粗网已经认出来了 —— 这条测试对兜底网的"
        "判别力就**归零**了，请换成真正够不着的样本：\n  "
        + "\n  ".join(not_actually_unreachable)
    )
    false_alarms = [k for k, s in _LAST_RESORT_MUST_NOT_CATCH.items() if _LAST_RESORT_RE.search(s)]
    assert not false_alarms, (
        "兜底网把**往别的表写**的合法语句也算进来了 —— 守卫会在干净树上变红，"
        "那等于给实施者发放宽许可证：\n  " + "\n  ".join(false_alarms)
    )


# ---------------------------------------------------------------------------
# ⭐ **`.py` 字面量必须先还原成运行时字符串，常驻**（codex 第十七轮打回后新增）
#
# 「源码文本 ≠ 运行时字符串」这条根连着打穿了三轮（11 / 16 / 17）。前两轮我的修法
# 都是「再教扫描器认一种写法」—— 而「数不完」这四个字就写在本文件自己的注释里。
# 第十七轮把**注释定界符本身**劈开（`… /" "* …`），彻底说明这条路走不通。
#
# ⇒ 对 `.py` 宿主改用 Python 自己的语法树：`ast` 会把相邻字面量折叠成一个常量、
#   把转义序列还原，得到的就是运行时真正交给 PostgreSQL 的那串字符。
# ---------------------------------------------------------------------------

#: 每条都是「**源码里看不出、运行时才成立**」的形态。
#: 左边是 `.py` 源码，右边是它运行时真正的字符串。
_PY_DECODE_CASES = {
    "块注释定界符被劈开": (
        'q = ("INSERT INTO t (a, /"\n     "* c, schema_version, *"\n     "/ b)")\n',
        "INSERT INTO t (a, /* c, schema_version, */ b)",
    ),
    "行注释定界符被劈开": (
        'q = ("INSERT INTO t (a, -"\n     "- schema_version)")\n',
        "INSERT INTO t (a, -- schema_version)",
    ),
    "转义换行": (
        'q = "INSERT -- c\\nINTO t (a)"\n',
        "INSERT -- c\nINTO t (a)",
    ),
    "表名被劈开": (
        'q = ("INSERT INTO training_"\n     "sets (a)")\n',
        "INSERT INTO training_sets (a)",
    ),
    "字段名被劈开（合法且在场）": (
        'q = ("INSERT INTO t (a, sch"\n     "ema_version)")\n',
        "INSERT INTO t (a, schema_version)",
    ),
}


def test_python_literals_are_decoded_before_scanning():
    wrong = []
    for label, (src, runtime) in _PY_DECODE_CASES.items():
        values = [v for v, _, _, _ in _scan_units(Path("x.py"), src)]
        if runtime not in values:
            wrong.append(f"{label}: 还原出的是 {values!r}，期望含 {runtime!r}")
    assert not wrong, (
        "`.py` 字面量没有被还原成运行时字符串 —— 扫描层看到的将是**源码文本**，"
        "而注释定界符、换行、字段名都可能在源码里被劈开 ⇒ 判定层必然判错：\n  "
        + "\n  ".join(wrong)
    )
    # ⭐ 防空转：上面那条断言必须真的经过了「源码 ≠ 运行时」的路径。
    #    若某条用例的源码文本里**本来就含有**目标字符串，它就证明不了还原这件事。
    vacuous = [
        label for label, (src, runtime) in _PY_DECODE_CASES.items() if runtime in src
    ]
    assert not vacuous, (
        "以下用例的**源码文本里本来就含有**期望的运行时字符串 —— 不还原也能通过，"
        "这条测试对它们的判别力是零：\n  " + "\n  ".join(vacuous)
    )
    # ⛔ 解析不了的 `.py` 必须**退回扫原文**，不能当成「没有字面量」
    #    （那是把解析失败伪装成检查通过 —— 本仓「报 0 违反的扫描必须先证明它能报非 0」）。
    broken = "def f(:\n"
    assert _py_literals(broken) is None, "语法错误的文件应当返回 None"
    units = _scan_units(Path("x.py"), broken)
    assert units == [(broken, 1, 0, len(broken))], "解析失败时必须退回扫原文"


# ---------------------------------------------------------------------------
# ⭐⭐ **十七轮攻击语料，常驻**
#
# 这些形态此前只能靠临时脚本往真文件里注样本来验证 —— 临时脚本不进仓库，
# 于是它们对**将来的改动**没有任何约束力。实测：把兜底网从主循环里摘掉，
# 当时四条常驻测试**全绿**。⇒ 全部搬进来。
#
# 判据分三档（对同一条**缺字段**的语句）：
#   `缺字段` = 精确网认领了它，判得最准；
#   `判不了` = 精确网够不着，靠兜底网接住 —— **仍然吵，没瞎**；
#   `绿`     = 三张网全落空 ⇒ **假绿**，这是唯一不可接受的结果。
# ⛔ 所以断言写成「**不许是绿**」，而不是「必须报缺字段」——
#    后者会把「判得更糙但仍然红」误判成回归，逼出无意义的修改。
# ---------------------------------------------------------------------------

_C6 = "(stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash)"
_C7 = ("(stock_code, stock_name, start_datetime, end_datetime, file_path, "
       "content_hash, schema_version)")
_V = "VALUES ('X','Y',9,9,'/x.zip','deadbeef');"


def _sql_file(sql: str) -> str:
    """把一段 SQL 包成 `.sql` 文件内容。"""
    return sql + "\n"


#: 每条都是**合法 PostgreSQL 且缺 `schema_version`** —— 守卫不许报绿。
_EVASIONS = {
    # 发现层：大小写 / 空白 / 限定符
    "全大写": f"INSERT INTO PUBLIC.TRAINING_SETS {_C6} {_V}",
    "小写换行": f"insert\ninto training_sets {_C6} {_V}",
    "点号带空格": f"INSERT INTO public . training_sets {_C6} {_V}",
    "双引号全限定": f'INSERT INTO "public"."training_sets" {_C6} {_V}',
    "非 public 限定": f"INSERT INTO qmt.training_sets {_C6} {_V}",
    "两级限定": f"INSERT INTO db.qmt.training_sets {_C6} {_V}",
    "制表符": f"INSERT\tINTO\ttraining_sets {_C6} {_V}",
    "换页 \\f 当空白": f"INSERT\x0cINTO training_sets {_C6} {_V}",
    "垂直制表 \\v 当空白": f"INSERT\x0bINTO training_sets {_C6} {_V}",
    # 发现层：注释夹在关键字之间
    "行注释夹关键字": f"INSERT -- c\nINTO training_sets {_C6} {_V}",
    "表名前块注释": f"INSERT INTO /* c */ training_sets {_C6} {_V}",
    "多块注释": f"INSERT /*a*//*b*/ INTO training_sets {_C6} {_V}",
    "限定符后块注释": f"INSERT INTO public./* c */training_sets {_C6} {_V}",
    "关键字间嵌套注释": f"INSERT /* o /* i */ o */ INTO training_sets {_C6} {_V}",
    "限定符间嵌套注释": f"INSERT INTO public /* o /* i */ o */ . training_sets {_C6} {_V}",
    "表名前嵌套注释": f"INSERT INTO /* o /* i */ o */ training_sets {_C6} {_V}",
    # 判定层：用注释伪造列名
    "注释里喂字样": (
        "INSERT INTO training_sets (stock_code, stock_name, start_datetime, "
        f"end_datetime, file_path, content_hash /* schema_version uses default */) {_V}"
    ),
    "嵌套注释注掉字段": (
        "INSERT INTO training_sets (stock_code, stock_name, start_datetime, "
        f"end_datetime, file_path, content_hash /* a /* b */ , schema_version, */ ) {_V}"
    ),
    "注释里含右括号": (
        "INSERT INTO training_sets (stock_code /* , schema_version) */, stock_name, "
        f"start_datetime, end_datetime, file_path, content_hash) {_V}"
    ),
    "行注释注掉字段": (
        "INSERT INTO training_sets (stock_code, stock_name, start_datetime, "
        f"end_datetime, file_path, content_hash -- , schema_version\n  ) {_V}"
    ),
    "列名含子串": (
        "INSERT INTO training_sets (stock_code, stock_name, start_datetime, "
        f"end_datetime, file_path, content_hash, my_schema_version) {_V}"
    ),
    # 没有列清单的写法（应落进「判不了」）
    "无列清单": "INSERT INTO training_sets VALUES ('X','Y',9,9);",
    "INSERT…SELECT": "INSERT INTO training_sets SELECT a,b,c,d,e,f FROM other;",
    "VALUES 里含字样": "INSERT INTO training_sets VALUES ('schema_version','Y',9,9);",
    "AS 别名": f"INSERT INTO training_sets AS t {_C6} {_V}",
    "ON CONFLICT": f"INSERT INTO training_sets {_C6} {_V[:-1]} ON CONFLICT DO NOTHING;",
    # 曾因「全局抹除」把真语句抹没的四种上下文
    "引号里的 /*": f"SELECT '/*';\nINSERT INTO training_sets {_C6} {_V}\nSELECT '*/';",
    "行注释里的 /*": f"-- /* 注意\nINSERT INTO training_sets {_C6} {_V}",
    "未闭合的 /*": f"INSERT INTO training_sets {_C6} {_V}\n-- 结尾有个 /* 不闭合",
}

#: `.py` 宿主：源码文本与运行时字符串**不一致**的那一家子。
_PY_EVASIONS = {
    "INTO 后断行": 'q = ("INSERT INTO "\n     "training_sets (a, b, c) VALUES ($1)")\n',
    "INSERT 后断行": 'q = ("INSERT "\n     "INTO training_sets (a, b, c) VALUES ($1)")\n',
    "表名被劈开": 'q = ("INSERT INTO training_"\n     "sets (a, b, c) VALUES ($1)")\n',
    "转义换行 \\n": 'q = "INSERT INTO\\ntraining_sets (a, b, c) VALUES ($1)"\n',
    "`--` 配转义换行": 'q = "INSERT -- seed\\nINTO training_sets (a, b, c) VALUES ($1)"\n',
    "`--` 拼接陷阱": (
        'q = ("INSERT INTO training_sets (a, b, "\n     "-- optional: "\n'
        '     "schema_version) VALUES ($1)")\n'
    ),
    "块注释定界符被劈开": (
        'q = ("INSERT INTO training_sets (stock_code, /"\n     "* x, schema_version, *"\n'
        '     "/ stock_name, file_path, content_hash) VALUES ($1)")\n'
    ),
    "行注释定界符被劈开": (
        'q = ("INSERT INTO training_sets (stock_code, file_path, -"\n'
        '     "- schema_version) VALUES ($1)")\n'
    ),
    "`+` 拼接劈开表名": 'q = "INSERT INTO training_" + "sets (a, b, c) VALUES ($1)"\n',
    "行注释无终止": 'q = "INSERT -- c INTO training_sets (a, b, c) VALUES ($1)"\n',
    "块注释不闭合": 'q = "INSERT /* c INTO training_sets (a, b, c) VALUES ($1)"\n',
}

#: 反向：**合法且字段真在场**，守卫必须保持绿。
#: ⛔ 这一组是第十四轮逼出来的 —— 当时所有带注释的用例都是「字段缺失」的坏样本，
#:    解析器坏掉后它们照样红，**只是红的理由变了**，套件看不出区别。
_VALID = {
    "裸的": f"INSERT INTO training_sets {_C7} {_V[:-1]} ;",
    "列清单带注释": (
        "INSERT INTO training_sets (stock_code /* ticker */, stock_name, start_datetime, "
        "end_datetime, file_path, content_hash, schema_version) VALUES (1);"
    ),
    "列清单嵌套注释": (
        "INSERT INTO training_sets (stock_code /* a /* b */ c */, stock_name, "
        "start_datetime, end_datetime, file_path, content_hash, schema_version) VALUES (1);"
    ),
    "注释里含括号": (
        "INSERT INTO training_sets (stock_code /* (x) */, stock_name, start_datetime, "
        "end_datetime, file_path, content_hash, schema_version) VALUES (1);"
    ),
    "关键字间嵌套注释": f"INSERT /* o /* i */ o */ INTO training_sets {_C7} VALUES (1);",
    "限定 + 大小写混写": f"insert Into public.training_sets {_C7} VALUES (1);",
    "行注释在列清单里": (
        "INSERT INTO training_sets (stock_code, -- t\n stock_name, start_datetime, "
        "end_datetime, file_path, content_hash, schema_version) VALUES (1);"
    ),
}

_VALID_PY = {
    "字段名被劈开但在场": (
        'q = ("INSERT INTO training_sets (stock_code, sch"\n     "ema_version, stock_name, '
        'file_path, content_hash) VALUES ($1)")\n'
    ),
    "整条在一个字面量里": (
        'q = "INSERT INTO training_sets (stock_code, schema_version) VALUES ($1,$2)"\n'
    ),
}

#: 反向：往**别的表**写的合法语句，守卫不许把它们拖下水
#: （守卫必须在干净树上是绿的，否则等于给实施者发放宽许可证）。
_OTHER_TABLE = {
    "插别表 + SELECT FROM 本表":
        "INSERT INTO p15_targets (id) SELECT id FROM training_sets;",
    "插前缀相同的表": f"INSERT INTO training_sets_audit {_C6} {_V}",
    "路径里出现 training-sets":
        "INSERT INTO p11_expected VALUES ('000001.SZ', '/data/training-sets/a.zip');",
    "UPDATE 不是 INSERT": "UPDATE training_sets SET schema_version = 2;",
}


def _verdict(suffix: str, src: str) -> str:
    missing, unknown, checked, _, _ = _scan_source(Path(f"probe{suffix}"), src)
    if missing:
        return "缺字段"
    if unknown:
        return "判不了"
    return "绿"


#: ⛔ **只有粗网接得住**的形态：表名被宿主引号劈开（精确网够不着），
#:    而间隔里的注释含 `(` 或 `;`（兜底网**按设计**不许跨这几个字符）。
#: ⚠️ 没有这一组的话，「把粗网从主循环里摘掉」**一条常驻测试都不会红** ——
#:    实测过，所以补在这里。
_SH_EVASIONS = {
    # ⭐ 第十八轮（codex）：**shell 的引号拼接** —— `/""*` 运行时就是 `/*`，
    #    于是 `schema_version` 落在注释里、被 PostgreSQL 忽略，而源码里看不出任何注释。
    "shell 引号拼出块注释":
        'psql -c "INSERT INTO training_sets (stock_code, /""* schema_version, *""/ '
        "stock_name, start_datetime, end_datetime, file_path, content_hash) "
        "VALUES ('X','Y',0,0,'f','abcdef12');\"\n",
    "shell 单引号拼出块注释":
        "psql -c 'INSERT INTO training_sets (stock_code, /''* schema_version, *''/ "
        "stock_name, file_path, content_hash) VALUES (1);'\n",
    "shell 引号拼出行注释":
        'psql -c "INSERT INTO training_sets (stock_code, file_path, content_hash -""- '
        ', schema_version) VALUES (1);"\n',
    # ⭐ 第十九轮（codex）：**反斜杠续行**。bash 会删掉「反斜杠+换行」，
    #    于是 `/` 与 `*` 在运行时拼成 `/*` —— 源码里同样看不出注释。
    "shell 续行拼出块注释":
        'psql -c "INSERT INTO training_sets (stock_code, /\\\n* schema_version, *\\\n'
        '/ stock_name, file_path, content_hash) VALUES (1);"\n',
    "注释含左括号 + 表名劈开":
        'psql -c "INSERT /* (x) */ INTO training_""sets (a, b, c) VALUES (1);"\n',
    "行注释含分号 + 表名劈开":
        'psql -c "INSERT -- x;\nINTO training_""sets (a, b, c) VALUES (1);"\n',
}


def test_known_evasions_never_produce_a_false_green():
    green = [k for k, s in _EVASIONS.items() if _verdict(".sql", _sql_file(s)) == "绿"]
    green += [f"[sh] {k}" for k, s in _EVASIONS.items()
              if _verdict(".sh", f"psql <<SQL\n{s}\nSQL\n") == "绿"]
    green += [f"[py] {k}" for k, s in _PY_EVASIONS.items() if _verdict(".py", s) == "绿"]
    green += [f"[sh] {k}" for k, s in _SH_EVASIONS.items() if _verdict(".sh", s) == "绿"]
    assert not green, (
        "以下写法**合法、可执行、且缺 schema_version**，而守卫报绿 —— "
        "PostgreSQL 会用 DEFAULT 1 把第 2 代产物静默标成第 1 代：\n  "
        + "\n  ".join(green)
    )


def test_valid_statements_stay_green():
    """⛔ 反向对照：守卫在**正确代码**上必须是绿的。

    红得「看起来对」是最难发现的坏味道 —— 解析器坏掉时，缺字段的坏样本照样红，
    只是**红的理由变了**（第十四轮实测：合法的 `(stock_code /* ticker */, schema_version)`
    被判成「判据够不着」⇒ CI 在正确代码上变红）。
    """
    bad = [f"{k}: {_verdict('.sql', _sql_file(s))}" for k, s in _VALID.items()
           if _verdict(".sql", _sql_file(s)) != "绿"]
    bad += [f"[py] {k}: {_verdict('.py', s)}" for k, s in _VALID_PY.items()
            if _verdict(".py", s) != "绿"]
    bad += [f"[别的表] {k}: {_verdict('.sql', _sql_file(s))}"
            for k, s in _OTHER_TABLE.items() if _verdict(".sql", _sql_file(s)) != "绿"]
    assert not bad, (
        "守卫在**合法代码**上变红了 —— 这是假阳性。一道在干净树上就红的守卫"
        "等于给实施者发放宽许可证：\n  " + "\n  ".join(bad)
    )


def test_evasion_corpus_actually_exercises_every_net():
    """⛔ 防空转：语料必须真的走过三张网，否则上面那条断言可能只是在验一张网。"""
    kinds = {_verdict(".sql", _sql_file(s)) for s in _EVASIONS.values()}
    kinds |= {_verdict(".py", s) for s in _PY_EVASIONS.values()}
    assert "缺字段" in kinds and "判不了" in kinds, (
        f"语料只触发了 {kinds} —— 说明它没覆盖到「精确网够不着、靠兜底网接住」"
        f"这条路径，兜底网被摘掉时这套语料不会变红"
    )
    # 兜底网是「间隔根本解析不动」时的唯一防线，必须有语料专门走它
    only_last_resort = [
        k for k, s in _PY_EVASIONS.items()
        if not _find_inserts(s, loose=True) and _LAST_RESORT_RE.search(s)
    ]
    assert only_last_resort, (
        "没有任何一条语料是「粗网够不着、只有兜底网接得住」的 —— "
        "那么把兜底网从主循环里摘掉，这套语料**一条都不会红**"
    )


# ---------------------------------------------------------------------------
# ⭐ **精度不许退化，常驻**
#
# 上面那条断言写的是「**不许是绿**」—— 故意的：判得糙一点但仍然红（「判不了」）
# 不是安全事故，把它当回归会逼出无意义的修改。
#
# 但这留下一个缺口：**纯精度**的修复没有任何测试守着。实测把下面三处改回去，
# 七条常驻测试**全绿**（那三条语料只是从「缺字段」降级成「判不了」）：
#   · `--` 行注释的终止符退回只认物理换行；
#   · `\f` `\v` 退出空白集；
#   · schema 限定符退回写死 `public`。
#
# ⇒ 这一条专门钉「**必须报得出真正的问题**」：守卫说「判不了」时，人得停下来
#   手工看一眼；说「缺 schema_version」才是直接可行动的。差别是真实的成本。
# ---------------------------------------------------------------------------

#: 每条都必须被判成 **缺字段**（而不是「判不了」）。
_PRECISION_FORMS = {
    # `--` 的终止符：宿主是 YAML/shell 时，`\n` 是**转义**，源码里没有物理换行
    "行注释配转义换行（.yml）": (
        ".yml",
        'run: psql -c "INSERT -- seed\\nINTO training_sets (a, b, c) VALUES (1);"\n',
    ),
    # PostgreSQL 的空白全集 `space [ \t\n\r\f\v]`
    "换页 \\f 当空白": (".sql", "INSERT\x0cINTO training_sets (a, b, c) VALUES (1);\n"),
    "垂直制表 \\v 当空白": (".sql", "INSERT\x0bINTO training_sets (a, b, c) VALUES (1);\n"),
    # schema 限定符不写死 `public`
    "非 public 限定": (".sql", "INSERT INTO qmt.training_sets (a, b, c) VALUES (1);\n"),
    "两级限定": (".sql", "INSERT INTO db.qmt.training_sets (a, b, c) VALUES (1);\n"),
}


def test_precision_does_not_regress_to_cannot_tell():
    punted = {
        k: _verdict(suffix, src)
        for k, (suffix, src) in _PRECISION_FORMS.items()
        if _verdict(suffix, src) != "缺字段"
    }
    assert not punted, (
        "以下写法**判得出**缺 schema_version，守卫却报成「判据够不着」—— "
        "红是红了，但报文说「判不了」，人还得手工再看一遍：\n  "
        + "\n  ".join(f"{k}: {v}" for k, v in punted.items())
    )


# ---------------------------------------------------------------------------
# ⭐ **剥注释必须一遍扫完，常驻**
#
# 原先是「先剥块注释、再剥行注释」两遍走，两遍会互相污染 —— 造出三条**误报**：
# 守卫在**合法代码**上报「缺 schema_version」，而字段明明在场。
# ⛔ 报文本身是错的，比单纯报错更误导人（人会照着报文去「补」一个已经存在的列）。
#
# ⚠️ 这一组既要钉「注释里的字样不算数」（防假绿），也要钉「注释外的真列要认得」
#    （防误报）。只钉一半就是第十四轮那个坑：坏样本照样红，只是红的理由变了。
# ---------------------------------------------------------------------------

_COLUMN_NAME_CASES = {
    # (列清单, schema_version 是否真的在场)
    "干净": ("(stock_code, schema_version)", True),
    "带引号的标识符": ('(stock_code, "schema_version")', True),
    "行注释里出现 /*，字段在下一行": ("(stock_code, -- 注意 /* 这里\n schema_version)", True),
    "引号里出现 --": ("(stock_code, 'a--b', schema_version)", True),
    "引号里出现 /*": ("(stock_code, 'a/*b', schema_version)", True),
    "块注释注掉": ("(stock_code, /* , schema_version */ file_path)", False),
    "嵌套块注释注掉": ("(stock_code, /* a /* b */ , schema_version, */ file_path)", False),
    "行注释注掉到行尾": ("(stock_code, file_path -- , schema_version\n)", False),
    "只是子串": ("(stock_code, my_schema_version)", False),
    "注释里喂字样": ("(stock_code /* schema_version uses default */, file_path)", False),
}


def test_column_name_extraction_is_lexically_correct():
    wrong = []
    for label, (cols, expected) in _COLUMN_NAME_CASES.items():
        got = "schema_version" in _column_names(cols)
        if got != expected:
            kind = "误报（字段在场却说不在）" if expected else "假绿（字段不在场却说在）"
            wrong.append(f"{label}: {kind} -> {cols!r}")
    assert not wrong, (
        "列名提取的词法判断错了 —— 说「在场」会放过缺字段的写入（假绿），"
        "说「不在场」会让守卫在合法代码上变红且**报文是错的**：\n  "
        + "\n  ".join(wrong)
    )
    # ⭐ 防空转：两个方向都必须有用例，否则这条测试只挡得住一半。
    assert any(v for _, v in _COLUMN_NAME_CASES.values()), "缺「字段真在场」的用例"
    assert any(not v for _, v in _COLUMN_NAME_CASES.values()), "缺「字段被注掉」的用例"


# ---------------------------------------------------------------------------
# ⭐⭐ **一条被认出来的语句不许掩护同一文件里的其它语句，常驻**（codex 第二十轮）
#
# 第 17 轮我为了给 `.py` 做去重，引入了「**扫描单元**已被认领就跳过兜底网」。
# 而非 `.py` 宿主的扫描单元**就是整个文件** —— 于是：
#
#   > 一条被认出来的 INSERT，会把**整份文件**的兜底网关掉。
#
# 往一个已覆盖的文件里再加一条 `INSERT INTO U&"training_sets" (…)`
# （`U&"…"` 是合法的 PostgreSQL 标识符写法，且缺字段）就**静默通过**。
#
# ⛔ 这是「改动只落在一处、没落在整条判据家族上」的又一次 —— 同一套去重逻辑
#    套在两种粒度完全不同的单元上，`.py` 那边对、这边错。
# ⇒ 去重粒度收窄到「**这一条出现**」。
# ---------------------------------------------------------------------------

_MIXED_OK = "INSERT INTO training_sets (stock_code, schema_version) VALUES (1,2);"
#: `U&"…"` 是 PostgreSQL 的 Unicode 转义标识符，合法；精确网够不着它，只有兜底网接得住。
_MIXED_BAD = 'INSERT INTO U&"training_sets" (stock_code, file_path) VALUES (1,2);'

_MIXED_CASES = {
    "只有未认领的": _MIXED_BAD,
    "已认领的在前": f"{_MIXED_OK}\n{_MIXED_BAD}",
    "已认领的在后": f"{_MIXED_BAD}\n{_MIXED_OK}",
    "夹在两条已认领的中间": f"{_MIXED_OK}\n{_MIXED_BAD}\n{_MIXED_OK}",
}


def test_a_recognized_insert_does_not_shield_its_neighbours():
    shielded = []
    for label, src in _MIXED_CASES.items():
        missing, unknown, _, _, _ = _scan_source(Path("mixed.sql"), src + "\n")
        if not missing and not unknown:
            shielded.append(label)
    assert not shielded, (
        "同一文件里已经有一条被认出来的 INSERT，就把另一条**缺字段且判据够不着**的"
        "语句掩护过去了 —— 往已覆盖的文件里追加写入即可静默绕过：\n  "
        + "\n  ".join(shielded)
    )
    # ⭐ 防空转：这条测试只有在 `_MIXED_BAD` 确实**够不着精确网**时才有意义。
    #    若哪天精确网认得它了，用例就退化成在验精确网，掩护问题不会再被发现。
    assert not _find_inserts(_MIXED_BAD, loose=True), (
        "`_MIXED_BAD` 已经能被精确/粗网认出来了 —— 这条测试对「掩护」问题的"
        "判别力归零，请换一条真正够不着的样本"
    )
    assert _LAST_RESORT_RE.search(_MIXED_BAD), "`_MIXED_BAD` 连兜底网都够不着，用例无效"
    # ⛔ `.py` 宿主的同一问题：一个字面量里同时有「已认领的一条」和「跨字面量、
    #    因而认不出的另一条」。按跨度去重会把后者一起吞掉。
    py_src = (
        'q = "' + _MIXED_OK + ' INSERT INTO training_" + "sets (a) VALUES (1)"\n'
    )
    missing, unknown, checked, _, _ = _scan_source(Path("mixed.py"), py_src)
    assert checked == 1 and unknown, (
        f"`.py` 同一字面量里「已认领 + 跨字面量未认领」没有各自报出来："
        f"checked={checked} unknown={unknown}"
    )


# ---------------------------------------------------------------------------
# ⭐⭐⭐ **表名不是字面量 / 插值落在列清单里，都不许静默通过**（codex 第二十一轮 + 自查）
#
# 第 21 轮 codex 报的是**列清单里的 f-string 插值**：插值可以求值成 `/*` `*/`，
# 把 `schema_version` 注掉，而我原先把插值换成 `{}` —— 扫描层看到
# `{} schema_version`，当成真列名 ⇒ **假绿**。（表名是字面量，所以这和
# 「动态表名」那条已知局限不是同一件事。）
# ⇒ 插值改用**列清单正字符集之外**的哨兵，自动落进「判不了」。
#
# ⚠️⚠️ 修这条时顺手核实「动态表名」那条已知局限，发现**我的文档在撒谎**：
#   三份文档都写着它「会落进判据够不着、让测试红（吵）」，而实测**四种写法
#   （f-string 变量 / `.format()` / 常量相加 / `%` 格式化）全部【静默不可见】** ——
#   三张网都要求表名里有字面量的 `training` 与 `sets`，它们一个字都没有。
#   ⛔ 不实陈述比缺陷更坏：它让人以为这件事已经有人管了。
# ⇒ 先量后做（干净树上「表名不是字面量」的 INSERT = **0 条**，零代价），
#   补第四个检测器把它们一律报成「判不了」。
#
# ⇒ 至此守卫的主张可以是：**作用域内每条路径要么判对、要么明说判不了，
#   没有静默不可见的。** 这条主张由下面这个测试守着。
# ---------------------------------------------------------------------------

_MUST_NOT_BE_SILENT = {
    "f-string 变量表名":
        'q = f"INSERT INTO {tbl} (stock_code, file_path) VALUES (1)"\n',
    ".format() 表名":
        'q = "INSERT INTO {t} (stock_code) VALUES (1)".format(t="training_sets")\n',
    "常量相加拼表名":
        'TBL = "training_sets"\nq = "INSERT INTO " + TBL + " (stock_code) VALUES (1)"\n',
    "% 格式化表名":
        'q = "INSERT INTO %s (stock_code) VALUES (1)" % "training_sets"\n',
    "插值落在列清单里（可求值成注释定界符）":
        'q = f"INSERT INTO training_sets (stock_code, {a} schema_version, {b} file_path)'
        ' VALUES (1)"\n',
}

#: ⛔ 反向：插值**只落在 `VALUES` 里**是完全正常的写法（参数化查询），必须保持绿。
#:    不钉这一头的话，「把所有 f-string 都报出来」也能让上面那条断言通过 ——
#:    那是把守卫变成噪音源。
_INTERPOLATION_OK = {
    "插值只在 VALUES 里":
        'q = f"INSERT INTO training_sets (stock_code, schema_version) VALUES ({a}, {b})"\n',
    "插值只在结尾的注释里":
        'q = f"INSERT INTO training_sets (stock_code, schema_version) VALUES (1,2)'
        ' ON CONFLICT DO NOTHING -- {tag}"\n',
    "纯字面量": 'q = "INSERT INTO training_sets (stock_code, schema_version) VALUES (1,2)"\n',
}


def test_nothing_in_scope_is_silently_invisible():
    silent = []
    for label, src in _MUST_NOT_BE_SILENT.items():
        missing, unknown, _, _, _ = _scan_source(Path("dyn.py"), src)
        if not missing and not unknown:
            silent.append(label)
    # shell 变量同理
    missing, unknown, _, _, _ = _scan_source(
        Path("dyn.sh"), 'psql -c "INSERT INTO $TABLE (a) VALUES (1);"\n'
    )
    if not missing and not unknown:
        silent.append("shell 变量表名")
    assert not silent, (
        "以下写法**静默通过**了 —— 守卫既没判对也没说判不了。"
        "⛔ 静默是最坏的结果：没人知道该去看一眼：\n  " + "\n  ".join(silent)
    )


def test_interpolation_outside_the_column_list_stays_green():
    noisy = []
    for label, src in _INTERPOLATION_OK.items():
        missing, unknown, checked, _, _ = _scan_source(Path("ok.py"), src)
        if missing or unknown or checked != 1:
            noisy.append(f"{label}: 缺={missing} 判不了={unknown} checked={checked}")
    assert not noisy, (
        "参数化查询（插值只在 VALUES 里）是**完全正常**的写法，守卫把它报红了 —— "
        "那是把守卫变成噪音源，人很快就会开始无视它：\n  " + "\n  ".join(noisy)
    )
