# backend/tests/test_training_set_ddl_no_drift.py
"""守卫：生成器内嵌的训练组建表语句，必须与冻结的建表文件**逐语句相同**。

⭐ 为什么要紧：`generate_training_sets.py` 的注释自称「逐字 training_set_schema_v1.sql」，
   但从 Plan B2 起**没有任何东西在核这句话**。两份一旦漂移，生成出来的 `.db` 结构
   就与冻结契约不一致，而两边各自的测试都照样绿。

⛔ **必须按【语句】比，不能按行比**：实测两份**语义完全相同、排版不同**
   —— 冻结文件一列一行，生成器里几列挤一行。按行比这条守卫**开局就是红的**，
   而本仓成文教训是「一条开局就红的守卫 = 给实施者发放宽许可证」。
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
GENERATOR = REPO_ROOT / "backend" / "generate_training_sets.py"
FROZEN_DDL = REPO_ROOT / "backend" / "sql" / "training_set_schema_v1.sql"


def _statements(sql: str) -> list[str]:
    r"""归一化成语句列表：剥行注释 → 按 `;` 切 → **把排版差异彻底抹平** → 丢掉空段。

    ⛔ **紧贴标点的空白也必须抹掉**（控制者复核 Task 4 时实测发现）：
       只做 `re.sub(r"\s+", " ", …)` 的话，一次**纯排版**改动就会被报成「漂移」——
       实测把 `CREATE TABLE meta ( … )` 的多列挤成一行：
         原文  `CREATE TABLE meta ( stock_code TEXT NOT NULL, … NOT NULL )`
         压行后 `CREATE TABLE meta (stock_code TEXT NOT NULL, … NOT NULL)`
       连续空白被压成一个空格，但 `( ` 与 ` )` 这两处**空格还在**，于是两串不相等 ⇒ **误报**。
       ⭐ 误报正是这条守卫最怕的东西：本文件开头就写着「开局就红的守卫＝发放宽许可证」，
       而一条**会因为别人重排版就变红**的守卫，迟早被人放宽或删掉。
    ⚠️ 只在**这两份 DDL 里没有任何字符串字面量**（实测：冻结文件零引号、生成器内嵌段
       零引号）的前提下才可以这么抹 —— 有字面量时去空格会改变语义。
       日后若 DDL 里出现 `DEFAULT 'x y'` 这类写法，**必须回来改这里**。
    """
    sql = re.sub(r"--[^\n]*", "", sql)
    parts = []
    for p in sql.split(";"):
        p = re.sub(r"\s+", " ", p).strip()
        p = re.sub(r"\s*([(),])\s*", r"\1", p)     # 抹掉紧贴 ( ) , 的空白
        parts.append(p)
    return [p for p in parts if p]


def test_normalisation_premise_no_string_literals():
    """⭐ 把归一化赖以成立的**前提**从「文档承诺」变成「机械可查」。

    ⛔ **为什么必须有这一条**（Task 4 评审「重要」，控制者已复现）：
       `_statements` 会无条件抹掉紧贴 `(` `)` `,` 的空白，**不区分该空白是否在
       字符串字面量内部**。于是两个**不同**的默认值会被判成相同：
         `DEFAULT 'x( y'` vs `DEFAULT 'x(y'`   → 归一化后**相等** ❌
         `DEFAULT 'a, b'` vs `DEFAULT 'a,b'`   → 归一化后**相等** ❌
       这是**假通过**方向（真的不同却判相同），⛔ 比误报危险得多。
    ⭐ 今天挡住它的**只有一个前提**：两份 DDL 里**零个字符串字面量**（实测各 0 个单引号）。
       而上一版把这个前提**只写在注释里** —— 本仓成文教训：**写「必须 X」之前，
       先核实机制兑现得了吗**。⇒ 本测试就是那个机制：前提一旦破，**立刻响**，
       而不是等到某天真漂移了却静默放行。
    """
    frozen = FROZEN_DDL.read_text(encoding="utf-8")
    embedded = _embedded_ddl()
    offenders = [(name, text.count("'")) for name, text in
                 (("冻结文件 training_set_schema_v1.sql", frozen),
                  ("生成器内嵌 _TRAINING_SET_DDL", embedded))
                 if "'" in text]
    assert not offenders, (
        "DDL 里出现了**字符串字面量**（单引号），而本守卫的归一化会抹掉紧贴 `( ) ,` 的空白、"
        "**不区分是否在字面量内部** ⇒ 两个不同的默认值可能被判成相同（**假通过**）。\n"
        f"  出现处：{offenders}\n"
        "⛔ 修法：把 `_statements` 改成**先切出字符串字面量、比较时不动它们内部**，"
        "改完再把这条前提检查一并更新。⛔ 不要简单地删掉本测试。")


def test_statements_ignores_pure_formatting():
    """⭐ 证明归一化**真的**把排版差异抹平了 —— ⛔ 不靠「我记得跑过一次变异」。

    这条自测是控制者复核时补的：原版归一化对「括号旁边的空格」敏感，一次纯排版
    改动就会误报。本测试用**手写的等价对**把这件事钉死，日后谁把归一化改回去都会红。
    """
    a = """
    CREATE TABLE meta (
        stock_code TEXT NOT NULL,
        stock_name TEXT NOT NULL
    );
    CREATE INDEX idx_x ON meta(stock_code);
    """
    b = "CREATE TABLE meta (stock_code TEXT NOT NULL, stock_name TEXT NOT NULL);\n" \
        "CREATE INDEX idx_x ON meta( stock_code );"
    assert _statements(a) == _statements(b), (
        "纯排版差异被当成了漂移：\n"
        f"  a = {_statements(a)}\n  b = {_statements(b)}")

    # ⛔ 防恒真：真改一个列名必须**不**相等（否则上面那条等式毫无判别力）
    c = b.replace("stock_name", "stock_name_x")
    assert _statements(b) != _statements(c), "改了列名却仍判相等 —— 归一化抹过头了"


def _embedded_ddl() -> str:
    text = GENERATOR.read_text(encoding="utf-8")
    m = re.search(r'_TRAINING_SET_DDL = """(.*?)"""', text, re.S)
    assert m, ("在 generate_training_sets.py 里找不到 `_TRAINING_SET_DDL = \"\"\"…\"\"\"` —— "
               "是不是被改名或改成了别的写法？⛔ 抓不到就必须响，不能静默当作『没有漂移』")
    return m.group(1)


def test_generator_ddl_matches_frozen_schema_file_statement_by_statement():
    """两份建表语句逐条相同（语句级，排版差异不算漂移）。"""
    frozen = _statements(FROZEN_DDL.read_text(encoding="utf-8"))
    embedded = _statements(_embedded_ddl())

    # ⛔ 防空转：切不出语句就说明归一化坏了，而不是「两边都空所以相等」
    assert len(frozen) >= 3, f"冻结文件只切出 {len(frozen)} 条语句 —— 归一化坏了"

    assert frozen == embedded, (
        "生成器内嵌的建表语句与冻结的建表文件**已漂移**。\n"
        f"冻结文件 {len(frozen)} 条 / 生成器 {len(embedded)} 条。\n"
        "只在冻结文件里：\n  " + "\n  ".join(s[:120] for s in frozen if s not in embedded) +
        "\n只在生成器里：\n  " + "\n  ".join(s[:120] for s in embedded if s not in frozen))
