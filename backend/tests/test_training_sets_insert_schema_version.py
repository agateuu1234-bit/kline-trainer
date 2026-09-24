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
#: ⛔⛔ **发现层用「先抹平、再简单正则」，不再一个个往字符类里补字符。**
#:
#: 为什么是这个做法：发现层被连续攻破**五次** —— 大小写/换行/`public.` 限定 →
#: 关键字之间夹注释 → `+` 拼接 → **schema 限定符与表名之间夹注释**
#: （`INSERT INTO public./* c */training_sets`）。每次我都往间隔字符类里补一个字符，
#: 这是打地鼠：**字符类永远数不全**。
#:
#: 结构性做法：先把**干扰物**换成**等长空白**（位置 1:1 保持、换行保留 ⇒ 行号不会错），
#: 再用一条**简单**正则扫抹平后的文本。干扰物只有两类：
#:   ① SQL 块注释 `/* … */` —— 可以出现在语句的任何缝隙里；
#:   ② Python 字符串拼接的痕迹 `"` `'` `+` `\` —— 它们永远不属于标识符。
#: ⚠️ **等长**是硬要求：抹平后的下标要能直接映射回原文，否则报出来的行号是错的。
#: ⚠️ `--` 行注释**不做全局抹平**（它在 shell / YAML 里另有含义，全局抹会吃掉同一行
#:    后面的真 SQL ⇒ 制造**漏报**）；只在关键字之间的间隔里局部容忍。
#: ⛔⛔ **全片只有这一个块注释扫描器** —— 发现层、配平扫描、列名提取**三处共用**。
#: 之前是**四份各自为政**的非贪婪正则/内联跳过，codex 第九轮用**嵌套注释**一次打穿：
#:     (stock_code /* outer /* inner */ , schema_version, */ , stock_name, …)
#: PostgreSQL 的块注释**可嵌套** ⇒ 整段都是注释、`schema_version` 被注掉；
#: 而非贪婪正则在**第一个** `*/` 就停 ⇒ 残留的 `schema_version` 字样被当成列名 ⇒ **假绿**。
#: ⚠️ 本仓教训「同一条判据存在于多处实现，改完必须两处都验」—— 这次直接**去掉重复**。
def _blank_block_comments(text: str) -> str:
    """把 `/* … */` 换成**等长**空白（换行保留，位置 1:1）。**支持嵌套**。

    ⛔ **找不到配对的 `*/` 就【不抹】**（当它不是注释）。
       起初我写成「未闭合就一路抹到文末」（想对齐 PostgreSQL 的行为），**当场闯祸**：
       `.github/workflows/schema-smoke.yml` 的 `paths:` 里有 `'backend/sql/**'` ——
       `/` 加 `*` 正好构成 `/*`，而全文没有 `*/` ⇒ **从第 6 行一路抹到文末**，
       该文件里 5 条 INSERT 全部消失、守卫只剩 5/12（防空转断言当场报红才没放过去）。
       ⇒ 失败必须往**吵**的方向倒（不抹 ⇒ 可能误报 ⇒ 有人看），
         ⛔ 不能往**瞎**的方向倒（乱抹 ⇒ 漏报 ⇒ 没人知道）。
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        # ⛔ **先认行注释，再认块注释**：`--` 之后的内容里如果出现 `/*`，那**不是**块注释
        #    起点（PostgreSQL 把整行当注释）。反过来先认 `/*` 会闯祸 —— codex 第十轮实测：
        #        -- /*
        #        INSERT INTO training_sets(…) VALUES (…);   ← 这条是**要执行**的
        #        -- */
        #    扫描器把第 1 行的 `/*` 当起点、第 3 行的 `*/` 当终点 ⇒ **把中间那条真 INSERT
        #    整段抹掉** ⇒ 发现层看不见它 ⇒ **假绿**，而 PostgreSQL 会照常执行它、用 DEFAULT 1。
        # ⚠️ 行注释这里**只跳过、不抹**：是否抹由调用方决定（发现层不抹 —— `--` 在
        #    shell / YAML 里另有含义；解析层才抹）。
        #
        # ⚠️ **由此带来一个【有意保留】的不对称，实测确认过**：
        #    · 被 `/* */` 注掉的 INSERT —— 发现层**看不见**（块注释被抹成空白）⇒ 绿；
        #    · 被 `--` 注掉的 INSERT —— 发现层**仍看得见** ⇒ 若缺字段则**红**。
        #    看起来不一致，但**不改成一致**，理由有二：
        #    ① 要改成一致就得在发现层也抹掉行注释，而那会让
        #       `psql --dbname=x -c "INSERT INTO training_sets(…)"` 这种写法**整条被抹掉**
        #       ⇒ **静默漏报**。实测当前作用域内「同一行 `--` 出现在 INSERT 之前」的行数为 **0**，
        #       但这是**今天**的事实，不是结构保证。⛔ 失败要往**吵**的方向倒，不往**瞎**的方向倒。
        #    ② 「注掉的、缺字段的 INSERT」本身就是**埋着的雷** —— 取消注释只要删两个字符。
        #       红在这里是合理的：要么补上字段，要么把那行删掉。
        if text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j == -1 else j + 1
            continue
        if text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            if depth:                 # 没配对上 ⇒ 当它不是注释，原样留着
                i += 2
                continue
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            i += 1
    return "".join(out)
#: ⚠️ 还要抹掉**表示空白的转义序列**：Python 字面量里 `"INSERT INTO\\ntraining_sets (…)"`
#:    执行时是合法 SQL（`\\n` 就是换行），但源码文本里是**反斜杠 + 字母 n** 两个字符 ——
#:    只抹反斜杠会留下一个 `n`，发现层当场瞎掉（codex 实测这样写守卫仍 `1 passed`）。
#: ⛔ 这一类是**可穷举**的：SQL 里的空白只有 空格/制表/换行/回车，对应的转义写法就这几种
#:    （`\\n` `\\t` `\\r` `\\x20` `\\u0020` `\\040`）。⇒ 按**整个转义序列**抹成等长空白。
_WS_ESCAPE_RE = re.compile(r"\\(?:u0020|x20|040|[ntr])")
_CONCAT_ARTIFACT_RE = re.compile(r"[\"'+\\]")


def _blank_for_discovery(text: str) -> str:
    """位置保持的抹平：干扰物 → 等长空白（换行原样保留）。"""
    def blank(m):
        return "".join("\n" if ch == "\n" else " " for ch in m.group(0))
    # 次序：块注释 → 空白转义（整段等长抹）→ 单字符拼接痕迹。
    # ⚠️ 空白转义必须在单字符那步**之前**：否则反斜杠先被抹成空格，留下的 `n` 就再也认不出来了。
    t = _blank_block_comments(text)
    t = _WS_ESCAPE_RE.sub(blank, t)
    return _CONCAT_ARTIFACT_RE.sub(" ", t)


#: 抹平之后，发现层只剩这一条：关键字之间允许空白或 `--` 行注释；schema 限定符可选；
#: 表名的引号已被抹成空白，所以不必再写引号分支。
_GAP = r"(?:\s|--[^\n]*\n)+"
#: ⚠️ schema 限定符的点号**两侧也要用同一种间隔**，不能只写 `\s*`：
#:    `INSERT INTO public. -- target table\n training_sets (…)` 是合法 SQL，
#:    而 `--` 行注释**故意不做全局抹平**（见上），所以必须在这里局部容忍
#:    （codex 第七轮实测：只写 `\s*` 时守卫仍 `1 passed`）。
#:    用 `*` 而非 `+`：没有间隔（`public.training_sets`）才是最常见的写法。
_DOT_GAP = r"(?:\s|--[^\n]*\n)*"
_INSERT_RE = re.compile(
    rf"insert{_GAP}into{_GAP}(?:public{_DOT_GAP}\.{_DOT_GAP})?training_sets",
    re.I,
)

#: ⛔⛔ **粗网**：精确正则再宽也总有够不着的拼法（如表名被劈成 `training_` + `sets`）。
#:    铁律是「**不许把『断定不是目标』和『判据够不着』混进同一个分支**」—— 两者会
#:    互相伪装成对方。⇒ 凡「像是往 training_sets 写」却**没被上面那条认领**的，
#:    一律报「判据够不着」**让测试红**，⛔ 绝不静默放行。
#:    宁可偶尔误报（红了有人看），也不要漏报（绿了没人知道）。
#: ⚠️ `into` 与表名之间**仍然收得很紧**，是被干净树上的误报逼出来的：放宽到任意字符会让
#:    `INSERT INTO p15_targets (id) SELECT … FROM training_sets` 这条**插另一张表**的
#:    合法语句误报（守卫必须在当前树上为绿，否则就是一张放行许可证）。
_COARSE_RE = re.compile(
    rf"insert{_GAP}into[\s_]{{0,40}}?training[\s_]*sets",
    re.I,
)

#: 只扫**可执行**路径。`docs/superpowers/**` 是历史记述（plan / spec 里引用这条
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


#: 块注释已由 `_blank_block_comments` 统一抹掉（见上），这里只需处理行注释。
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
    inner = _LINE_COMMENT.sub(" ", inner)
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
        parse_text = _blank_block_comments(text)   # 解析层用：块注释已抹、位置 1:1
        scan = _blank_for_discovery(text)          # 发现层用：再抹拼接痕迹与空白转义
        precise_starts = {m.start() for m in _INSERT_RE.finditer(scan)}

        # 粗网先跑：凡「像是往 training_sets 写」却没被精确正则认领的，一律报出来
        for cm in _COARSE_RE.finditer(scan):
            if cm.start() in precise_starts:
                continue
            lineno = text.count("\n", 0, cm.start()) + 1
            unknown_shape.append(
                f"{path.relative_to(ROOT)}:{lineno}: 判据够不着 -> "
                f"{text[cm.start(): cm.start() + 60]!r}"
            )

        for m in _INSERT_RE.finditer(scan):
            pos, after = m.start(), m.end()      # 下标对 text 同样有效（抹平等长）
            rel = path.relative_to(ROOT)
            lineno = text.count("\n", 0, pos) + 1
            tail = text[after: after + 20]
            cols = _column_list(parse_text, after)
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
                unknown_shape.append(f"{rel}:{lineno}: 未知写法 -> {m.group(0)}{tail!r}")

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
