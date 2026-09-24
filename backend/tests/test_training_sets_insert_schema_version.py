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
_LAST_RESORT_RE = re.compile(
    rf"insert{_SPAN}{{1,200}}?into{_SPAN}{{0,80}}?training{_SPAN}{{0,12}}?sets"
    r"(?![A-Za-z0-9_$])",          # ⛔ 词边界：否则 `training_sets_audit` 也被拖下水
    re.I,
)

#: 标识符：普通形式 `[A-Za-z_][A-Za-z0-9_$]*`（引号形式的引号已被 `_skip_gap` 当作宿主
#: 定界符吃掉，所以这里不必再写引号分支）。
_IDENT_RE = re.compile(r"[A-Za-z_\u0080-\uffff][A-Za-z0-9_$\u0080-\uffff]*")


def _match_ident(text: str, i: int) -> int | None:
    m = _IDENT_RE.match(text, i)
    return m.end() if m else None


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
    # ⛔ 块注释必须**嵌套感知**地剥：非贪婪正则在第一个 `*/` 就停，
    #    `/* a /* b */ , schema_version, */` 会让被注掉的字段字样幸存 ⇒ 假绿（codex 第九轮）。
    out_chars, k, m = [], 0, len(inner)
    while k < m:
        if inner.startswith("/*", k):
            depth, q = 1, k + 2
            while q < m and depth:
                if inner.startswith("/*", q):
                    depth += 1; q += 2
                elif inner.startswith("*/", q):
                    depth -= 1; q += 2
                else:
                    q += 1
            out_chars.append(" ")
            k = q
            continue
        out_chars.append(inner[k])
        k += 1
    inner = _LINE_COMMENT.sub(" ", "".join(out_chars))
    names = set()
    for tok in inner.split(","):
        # 跨行的 asyncpg 查询会把引号与换行夹进 token（实测形如 '"\n        "schema_version'）
        tok = tok.strip().strip('"').strip("'").strip()
        tok = tok.split()[-1] if tok.split() else ""
        tok = tok.strip('"').strip("'")
        if tok:
            names.add(tok)
    return names


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


def test_every_executable_insert_specifies_schema_version():
    missing: list[str] = []
    unknown_shape: list[str] = []
    checked = 0
    whitelisted = 0
    prose = 0

    for path in _scope_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        # ⛔ 直接在**原文**上扫 —— 非破坏性游标扫描器（理由见上方长注释）。
        precise = _find_inserts(text, loose=False)
        precise_starts = {s for s, _ in precise}

        # 粗网 + 最后一张网：凡「像是往 training_sets 写」却没被精确扫描认领的，一律报出来。
        # ⛔ 两张网都要跑 —— 粗网仍走 `_skip_gap`，间隔认不全时它会和精确网**一起**落空；
        #    最后一张网不解析间隔，正是为此存在。
        reported = set(precise_starts)
        coarse = [cs for cs, _ in _find_inserts(text, loose=True)]
        for cs in coarse + [m.start() for m in _LAST_RESORT_RE.finditer(text)]:
            if cs in reported:
                continue
            reported.add(cs)
            lineno = text.count("\n", 0, cs) + 1
            unknown_shape.append(
                f"{path.relative_to(ROOT)}:{lineno}: 判据够不着 -> "
                f"{text[cs: cs + 60]!r}"
            )

        for pos, after in precise:
            rel = path.relative_to(ROOT)
            lineno = text.count("\n", 0, pos) + 1
            tail = text[after: after + 20]
            cols = _column_list(text, after)
            if cols is not None and "--" in cols and path.suffix != ".sql":
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
                    f"{rel}:{lineno}: 判据够不着（列清单含 `--`，而本文件非 .sql ⇒ "
                    f"源码换行未必是运行时换行）-> {cols[:80]}"
                )
            elif cols is not None:
                checked += 1
                if "schema_version" not in _column_names(cols):
                    missing.append(f"{rel}:{lineno}: 列清单缺 schema_version -> {cols[:100]}")
            elif _NON_SQL_SHAPE in tail:
                whitelisted += 1          # test double 的分派谓词，不是 SQL
            elif _is_prose_mention(text, pos, after):
                prose += 1                # 反引号包住的散文提及，不是可执行 SQL
            else:
                # ⛔ 既不是列清单、又不是已知的非 SQL 形状 —— **报错**，不静默跳过。
                unknown_shape.append(
                    f"{rel}:{lineno}: 未知写法 -> {text[pos:after]!r}{tail!r}"
                )

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
