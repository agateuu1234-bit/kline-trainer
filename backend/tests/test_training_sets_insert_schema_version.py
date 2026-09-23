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
  ⇒ 本守卫覆盖的是「**SQL 以字面量写在源码里**」这一类，**不声称覆盖全部写入路径**。
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
_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
_CONCAT_ARTIFACT_RE = re.compile(r"[\"'+\\]")


def _blank_for_discovery(text: str) -> str:
    """位置保持的抹平：干扰物 → 等长空白（换行原样保留）。"""
    def blank(m):
        return "".join("\n" if ch == "\n" else " " for ch in m.group(0))
    return _CONCAT_ARTIFACT_RE.sub(" ", _BLOCK_COMMENT_RE.sub(blank, text))


#: 抹平之后，发现层只剩这一条：关键字之间允许空白或 `--` 行注释；schema 限定符可选；
#: 表名的引号已被抹成空白，所以不必再写引号分支。
_GAP = r"(?:\s|--[^\n]*\n)+"
_INSERT_RE = re.compile(
    rf"insert{_GAP}into{_GAP}(?:public\s*\.\s*)?training_sets",
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


_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
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
    inner = _BLOCK_COMMENT.sub(" ", inner)
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
    i = after
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    if i >= len(text) or text[i] != "(":
        return None
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return None


def test_every_executable_insert_specifies_schema_version():
    missing: list[str] = []
    unknown_shape: list[str] = []
    checked = 0
    whitelisted = 0
    prose = 0

    for path in _scope_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        scan = _blank_for_discovery(text)      # 位置与 text 1:1 对齐
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
            cols = _column_list(text, after)
            if cols is not None:
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
