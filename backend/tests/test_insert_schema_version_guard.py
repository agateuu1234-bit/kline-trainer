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


def _mask_sql_comments(s: str) -> str:
    r"""把 SQL 注释替换成**等长空格**（⛔ 不是删除 —— 保长才不会打乱偏移量与行号）。

    ⛔ **块注释在 PostgreSQL 里【可以嵌套】**（Task 3 定向复评用 `pglast`
       ——真·PG 解析器——实测确认；⚠️ 控制者上一轮自查**推错了**，只是碰巧
       挑到了非贪婪正则能处理的那种嵌套排列）。非贪婪的
       `re.sub(r"/\*.*?\*/", ...)` 会在**第一个** `*/` 就收手，把剩下的注释
       尾巴当成真内容。实测**假通过（危险方向）**：
         `INSERT INTO training_sets (/* /* */ schema_version */ stock_code, file_path)`
         pglast 真实列清单 = ['stock_code', 'file_path'] ⇒ **真缺失**，
         旧版守卫却判「含 schema_version」⇒ **放行**。
    ⚠️ 未闭合的 `/*` ⇒ 一路屏蔽到末尾 ⇒ 列清单取不到 ⇒ 落「认不出的形状」**必报**。
       （PostgreSQL 自己也会 `ParseError: unterminated /* comment`，两边都是响亮失败。）
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
    return "".join(out)


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
    masked = _mask_sql_comments(text[pos:])
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
    cols = _mask_sql_comments(cols)
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
    per_cell = {c: 0 for c in _EXPECTED_CELLS}

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
                        _cell = (_d.relative_to(REPO_ROOT).as_posix(), q.suffix)
                        if _cell in per_cell:
                            per_cell[_cell] += 1
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
    # ⛔ **逐（目录, 后缀）格子锚点**（Task 3 评审「重要 2」+ 定向复评「重要」）：
    #    `checked >= 2` 是**存在性**判据，表达不了穷尽性 —— 真实树 12 条，掉到 2 条才响。
    #    实测**单 token 编辑**即可绕过：从 `_SUFFIXES` 拿掉 `".yml"`，`.github/workflows`
    #    整个目录**静默退出视野**，`checked` 仍 >= 2 ⇒ 绿；再真删一个列名**照样绿**。
    #    ⛔ 而**逐【目录】锚点还不够**（定向复评实测）：`backend/` 由 `.py` + `.sh` 两种
    #    后缀共同撑着，单独拿掉 `".sh"` ⇒ `rehearse.sh` 那 3 条静默消失，而 `backend/`
    #    靠 `.py` 那条仍 > 0 ⇒ 锚点**不响**。`.github/workflows` 当初被抓到，只因它
    #    **恰好是单后缀目录** —— 判别力是撞来的，不是设计出来的。
    #    ⇒ 锚点必须钉到**（目录, 后缀）格子**这一层，见 `_EXPECTED_CELLS`。
    #    ⚠️ 代价：日后某格子合理归零（例如 rehearse.sh 退役）会让守卫**响亮报错**，
    #    需要人把该格子从清单里删掉 —— 这是有意选的**吵闹方向**，好过静默漏扫。
    #    ⭐ 由变异 M4k（去 `.yml`）与 M4o（去 `.sh`）各自钉住。
    blind = [f"{d}  下的 {sfx} 文件" for (d, sfx), n in per_cell.items() if n == 0]

    problems = []
    if blind:
        problems.append(
            "【有一类文件一条语句都没解析到】它多半被后缀白名单/改名悄悄移出了视野，"
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
       · ⛔ **接不住**：**上面那条主测试自己的装配线**被改坏。例如把主测试里的
         `"schema_version" not in _column_names(cols)` 退回裸子串 `not in cols`，
         本测试**照样绿** —— 因为它自己直接调 `_column_names`，根本不走那一行。
         ⇒ 那一层由变异 **M4f**（注入 `old_schema_version`）负责证伪，两者**不可互相替代**。
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
        m = _HEAD.search(sql)
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
