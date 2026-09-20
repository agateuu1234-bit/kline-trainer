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

# ⚠️ 三条正则的大小写策略必须一致 —— 上一版 needle 不带 `re.I` 而形状正则带，
#    导致 `re.I` 在整条链路上是装饰品（小写写法在第一步就丢了）。
# ⚠️ 表头允许标识符带双引号（`INSERT INTO "training_sets"` / `"public"."training_sets"`）——
#    整支评审 R2-M1：上一版对这两种写法**零命中**，整条语句静默漏掉。
_HEAD = re.compile(r'INSERT\s+INTO\s+(?:"?[A-Za-z_][\w$]*"?\s*\.\s*)?"?training_sets"?\b', re.I)
_NO_COLS = re.compile(r"\s*(VALUES|SELECT|DEFAULT|OVERRIDING)\b", re.I)
_ALIAS = re.compile(r"\s*(?:AS\s+)?(?!VALUES\b|SELECT\b|DEFAULT\b|OVERRIDING\b)[A-Za-z_]\w*", re.I)
# ⭐ 允许跨过 Python 相邻字符串字面量拼接的引号 / 反斜杠 / 加号 —— 生产语句正是这种写法
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


def _column_list(text: str, pos: int) -> str | None:
    """从 `pos` 起找列清单的左括号，**括号配平**取出里面的文本。取不到返回 None。"""
    m = _OPEN_PAREN.match(text, pos)
    if not m:
        return None
    depth, i = 0, m.end() - 1
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[m.end():i]
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
    cols = re.sub(r"/\*.*?\*/", "", cols, flags=re.S)   # 先剥 SQL 块注释
    cols = re.sub(r"--[^\n]*", "", cols)          # 再剥 SQL 行注释
    names = set()
    for part in _top_split(cols):
        part = part.strip().strip('"').strip()
        m = re.match(r'"?([A-Za-z_][\w$]*)"?', part)
        if m:
            names.add(m.group(1).lower())
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
    if before in _QUOTES and after in _QUOTES:
        return ("mention", None)
    return ("unknown", None)


def test_every_executable_insert_carries_schema_version():
    """每一条真 `INSERT INTO training_sets` 的列清单里都必须有 `schema_version`。"""
    missing, positional, unknown, checked = [], [], [], 0
    per_dir = {d: 0 for d in _SCOPE_DIRS}

    for q in _iter_files():
        try:
            text = q.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError) as e:
            # ⛔ 不把「读不了」混进「不是目标」：读不了必须**响**。
            raise AssertionError(f"作用域内的文件读不了，无法判定：{q} —— {e}") from e

        for m in _HEAD.finditer(text):
            rel = q.relative_to(REPO_ROOT).as_posix()
            where = f"{rel}:{text.count(chr(10), 0, m.start()) + 1}"
            kind, cols = _classify(text, m.start(), m.end())
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
                        per_dir[_d] += 1
                        break
                if "schema_version" not in _column_names(cols):
                    missing.append(f"{where}  列清单={cols.strip()[:120]}")

    # ⛔ 防空转：一条列清单都没解析到 ⇒ 作用域或解析坏了，而不是「全都合规」。
    assert checked >= 2, f"只解析到 {checked} 条列清单 —— 作用域或括号配平坏了"

    # ⭐ **锚点加固**（整支评审 R4-M1）：宽守卫有一条**结构性**静默通道 ——
    #    把 SQL 头抽成模块常量（`_INSERT_HEAD = "INSERT INTO training_sets"` 这种**寻常重构**）
    #    之后，列清单解析不出来、而表名两侧恰好是引号 ⇒ 落进「提及」**被静默跳过**；
    #    此时再把 `schema_version` 删掉，守卫**仍然绿**，连 M0 那组变异也一并变成恒真。
    # ⇒ 本断言要求：**生产文件里必须至少有 1 条被认出来的 `INSERT`**，认不出就响。
    # ⚠️ **它接得住什么、接不住什么**（R5-M3 实测后订正 —— ⛔ 上一版写〔废〕「不依赖形状判据」是**假的**）：
    #    · 接得住：SQL 被重构成变量拼接 / f-string / 搬去别的文件 ⇒ `gen_seen` 掉到 0 ⇒ 响；
    #    · ⛔ 接不住：**判据本身被改坏**（退回子串 / 退回旧判定顺序 / 去掉双引号支持）——
    #      实测这三种下 `gen_seen` 仍为 1、一声不吭。它用的就是 `_HEAD`/`_classify`，
    #      是同一判据的**回声**，不是独立第二来源。判据被改坏由变异 M0/M4c–M4f 负责发现。
    gen_src = (REPO_ROOT / "backend" / "generate_training_sets.py").read_text(encoding="utf-8")
    gen_seen = sum(1 for m in _HEAD.finditer(gen_src)
                   if _classify(gen_src, m.start(), m.end())[0] == "cols")

    # ⛔ **三类问题必须一次全报，不能用三条 assert 串起来**：只要前一条炸了，
    #    后面的就永远执行不到 —— 而 `missing` 才是本守卫的**招牌判据**。
    #    本仓成文教训：「断言顺序导致招牌判据从未执行」。
    # ⛔ **逐目录锚点**（Task 3 评审「重要 2」）：`checked >= 2` 是**存在性**判据，
    #    表达不了穷尽性 —— 真实树是 12 条，掉到 2 条它才响。实测**单 token 编辑**即可绕过：
    #    从 `_SUFFIXES` 里只拿掉 `".yml"`，`.github/workflows` 整个目录**静默退出视野**，
    #    `checked` 仍 >= 2 ⇒ 守卫绿；此时再真删掉一个列名，它**照样绿**。
    #    ⇒ 改成**每个作用域目录各自至少要有 1 条**，让「整个子树消失」这件事必须响。
    #    ⭐ 由变异 M4k 钉住。
    blind = [d.relative_to(REPO_ROOT).as_posix() for d, n in per_dir.items() if n == 0]

    problems = []
    if blind:
        problems.append(
            "【某个作用域目录一条语句都没解析到】它多半被后缀白名单/改名悄悄移出了视野，"
            "而守卫会照样报「全都合规」：\n  " + "\n  ".join(blind))
    if gen_seen < 1:
        problems.append(
            "【生产语句脱离视野】`backend/generate_training_sets.py` 里一条都认不出 "
            "`INSERT INTO training_sets` 的列清单 —— 唯一真正写生产库的那条语句本守卫已经看不见了"
            "（多半是 SQL 被重构成变量拼接 / f-string / 搬去了别处）。"
            "⛔ 这不是「它没问题」，是「守卫看不见它了」。")
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
