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
#: ⇒ 改用正则，覆盖：关键字大小写、任意空白/换行、可选 `public.` 限定、可选双引号。
#: 关键字之间允许出现的东西：空白 / SQL 注释 / **Python 字符串拼接留下的引号**。
#: ⚠️ 引号那一项是必须的：`"INSERT INTO "` 换行 `"training_sets (…)"` 是**最自然的
#:    换行点**，真实开发者会这么写（实测不加这一项时 G1/G2/G4 三种拼法全部漏掉）。
_KW_GAP = r"(?:\s|[\"']|/\*.*?\*/|--[^\n]*\n)+"

_INSERT_RE = re.compile(
    # ⚠️ 引号必须**成对**匹配，不能写 `"?training_sets"?`：那样在
    #    `if "INSERT INTO training_sets" in query:` 上会把 Python 字符串的**收尾引号**
    #    一起吃掉，`m.end()` 越过它 ⇒ 下面按 tail 认 test double 的白名单当场失配。
    # ⚠️ 关键字之间允许夹 **SQL 注释**：`INSERT /* c */ INTO training_sets` 是合法语句，
    #    只写 `\s+` 会漏掉它（codex 复审第 3 轮实测：那样写守卫仍绿）。
    #    ⛔ 只在「INSERT…INTO…表名」这个构造**内部**容忍注释，不做全文剥注释 ——
    #       `--` 在 shell / YAML 里有别的含义，全文剥会误伤同行后面的真 SQL。
    rf'insert{_KW_GAP}into{_KW_GAP}(?:"?public"?\s*\.\s*)?(?:"training_sets"|training_sets)',
    re.I | re.S,
)

#: ⛔⛔ **粗网**：精确正则再宽也总有够不着的拼法（实测：把表名劈成
#:    `"INSERT INTO training_"` + `"sets …"` 两段拼接就能溜过去）。
#:    本仓的铁律是「**不许把『断定不是目标』和『判据够不着』混进同一个分支**」——
#:    两者会互相伪装成对方。⇒ 这里用一张**故意放宽**的网把「`insert` 附近出现类似
#:    表名的东西」全兜住，凡是**精确正则没认领**的，一律报「判据够不着」**让测试红**，
#:    ⛔ 绝不静默放行。宁可偶尔误报（红了有人看），也不要漏报（绿了没人知道）。
#: ⚠️ 粗网的两条收紧，都是干净树上的误报逼出来的（守卫**必须在当前树上是绿的**，
#:    否则它就成了一张放行许可证）：
#:    ① 只认 `insert` 会在**中文散文**上误报 —— 实测 7 处，例如注释里
#:       「并发 sweep 在预检与 INSERT 之间插入同一起点时」；⇒ 要求后面不远处跟 `into`。
#:    ② `into` 与表名之间不能放任意内容 —— 否则
#:       `INSERT INTO p15_targets (id) SELECT … FROM training_sets` 这条**插另一张表**的
#:       合法语句会被误判；⇒ 两者之间只容忍空白/引号/下划线（正好够兜住被劈开的表名）。
_COARSE_RE = re.compile(
    r"""insert[\s"'/*-]{0,40}?into[\s"'_]{0,40}?training[\s"'_]*sets""",
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
        precise_starts = {m.start() for m in _INSERT_RE.finditer(text)}

        # 粗网先跑：凡「像是往 training_sets 写」却没被精确正则认领的，一律报出来
        for cm in _COARSE_RE.finditer(text):
            if cm.start() in precise_starts:
                continue
            lineno = text.count("\n", 0, cm.start()) + 1
            unknown_shape.append(
                f"{path.relative_to(ROOT)}:{lineno}: 判据够不着 -> "
                f"{text[cm.start(): cm.start() + 60]!r}"
            )

        for m in _INSERT_RE.finditer(text):
            pos, after = m.start(), m.end()
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
