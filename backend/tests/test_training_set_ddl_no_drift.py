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
    """归一化成语句列表：剥行注释 → 按 `;` 切 → 把连续空白压成单个空格 → 丢掉空段。"""
    sql = re.sub(r"--[^\n]*", "", sql)
    parts = [re.sub(r"\s+", " ", p).strip() for p in sql.split(";")]
    return [p for p in parts if p]


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
