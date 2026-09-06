# backend/tests/test_frozen_contract_texts.py
"""冻结契约文本的两条机械守卫（spec §3.3 3c）。

⭐ 本片处理的是一个**有意的过渡态**：生产者（后端）已升到第 2 代，而 App 读取端**仍钉在 1**
   —— 这不是没同步，是切片次序决定的。守卫②把它写成**可断言的事实**，而不是留成矛盾。
⛔ 本文件只**读** `ios/` 下两处常量，不改 App 一行。
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

MODULES = REPO_ROOT / "kline_trainer_modules_v1.4.md"
PLAN15 = REPO_ROOT / "kline_trainer_plan_v1.5.md"

# ── 守卫①作用域：**后端与治理文档**
# ⛔ 不得扩成全仓：
#   · `docs/superpowers/**` 下实测 **20 个文件**逐字引用旧表述（历史记述；含本片的 spec、P1 计划，
#     以及本片自己的计划文档 —— 所以这个数只会随记述增加而变大，⛔ 不是判据）
#   · `ios/**` 下的命中**分两类**（⚠️ 早先写「主题全不相干」是错的 —— 那次 grep 加了 `head` 被截断）：
#     ⛔ **同一条规则、且是生产代码**：`DefaultTrainingSetReader.swift:80` 注释「校验 per-period
#        endGlobalIndex 严格递增」、`:90-92` **就是执行它的那段代码**
#        （`if let prev = lastEnd[period], r.endGlobalIndex <= prev { throw .dbCorrupted }`）
#        —— 它会**拒掉每一个第 2 代产物**（`monthly [0,0,17,23]` 的 `0 <= 0` 当场抛错）；
#        `:146` 还逐字引用了 R03 原句作为依据。⇒ **切片二要改的正是这里**。
#     ⚪ 其余（画线图标线宽、datetime 次序等）与本片不相干。
#   扩成全仓 ⇒ 守卫恒红，要它变绿只能删历史记述或改 App 源文件。
# 切片二把作用域扩到 `ios/`（spec §8）。
_SCOPE_FILES = [MODULES, PLAN15]
# ⭐ 作用域必须覆盖**所有会照这条规则写检查的地方**（最终评审 Important 2）：本片的立论就是
#    「日后任何照旧规则写的检查，会把每个第 2 代产物判死」，而检查恰恰住在 `scripts/acceptance/`、
#    `docs/runbooks/`（可执行 SQL 烟测）与 `.github/workflows/` 里 —— spec §3.3 也正是把这三类
#    称作「可执行路径」。实测把它们纳入后**今天零违例**，所以这是纯粹的加固。
_SCOPE_DIRS = [REPO_ROOT / "docs" / "governance", REPO_ROOT / "backend",
               REPO_ROOT / "docs" / "runbooks", REPO_ROOT / "scripts",
               REPO_ROOT / "tests", REPO_ROOT / ".github"]

_OLD_WORDING = "严格递增"

# ⛔ 守卫**不扫自己**：本文件的 docstring 必须能**逐字引用**它所禁止的那句旧表述
# （不然它就没法说明自己在禁什么），于是天然满足「同行既有『严格递增』又有 global_index」。
# 用**解析后的自身路径**排除，⛔ 不按文件名字符串（改名后会静默重新自指、红得莫名其妙），
# ⛔ 也不整目录排除 `backend/tests/`（那等于把一整个目录永久移出作用域）。
_SELF = Path(__file__).resolve()


def _scope_lines():
    """作用域内所有 (相对路径, 行号, 行文本)。"""
    files = list(_SCOPE_FILES)
    for d in _SCOPE_DIRS:
        files += [p for p in d.rglob("*")
                  if p.is_file() and p.suffix in (".md", ".py", ".sql", ".sh", ".yml", ".yaml")
                  and "__pycache__" not in p.parts]
    for p in files:
        if p.resolve() == _SELF:
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in enumerate(text.splitlines(), start=1):
            yield p.relative_to(REPO_ROOT).as_posix(), i, line


def test_old_all_periods_strictly_increasing_wording_is_gone():
    """守卫①：作用域内不得再出现「全周期严格递增」这条旧表述（spec §3.3 3c①）。

    ⛔ **判据不是裸的「严格递增」**：作用域内有一条**合法且无关**的命中
       —— `kline_trainer_modules_v1.4.md:723` 讲的是 `ticket_index`，与本片无关。
       裸词判据会把它误报成违例，而最省事的「修法」是去改那条无关的行。
    ⇒ 判据 = 同一行里**既有**「严格递增」**又有** `global_index`，**且不是**改写后的新表述
      （新表述保留了「`3m` … 严格递增」这半句，属预期命中）。
    """
    offenders = []
    for rel, lineno, line in _scope_lines():
        if _OLD_WORDING not in line or "global_index" not in line:
            continue
        # 改写后的新表述必然同时点名「其它周期」与「允许重复」；旧表述两者皆无。
        if "其它周期" in line and "允许重复" in line:
            continue
        offenders.append(f"{rel}:{lineno}: {line.strip()[:120]}")
    assert not offenders, (
        "作用域内仍有「全周期严格递增」旧表述（与 spec §2.2 直接矛盾，"
        "照它写的守卫会把每个第 2 代产物判死）：\n" + "\n".join(offenders))


def test_rewritten_clauses_are_present_in_both_root_authorities():
    """守卫①的**正向对照**：两份根级权威都必须**真的**有改写后的表述。

    ⚠️ 只有上面那条否定式守卫的话，把两行**整行删掉**同样能让它变绿 —— 那不是订正，是删证据。
    """
    for path in (MODULES, PLAN15):
        text = path.read_text(encoding="utf-8")
        hits = [l for l in text.splitlines()
                if "global_index" in l and "其它周期" in l and "允许重复" in l]
        assert len(hits) == 1, (
            f"{path.name} 应恰好有 1 行改写后的 Index 预计算表述，实测 {len(hits)} 行 —— "
            f"0 行 = 被整行删掉（删证据不是订正）；>1 行 = 又抄了一份（两份实现漂移的老毛病）")


# ── 守卫②：分阶段版本守卫（spec §3.3 3c②，切片一断言）

# ⛔ 按**整句**判，不按「App 侧仍为 1」这 6 个字的子串（最终评审 Important 5 实证：
#    「旧说法『App 侧仍为 1』已作废，App 侧现已为 2」这种**反义句**同样含该子串、会被放行）。
#    实测三处标注**逐字同一句**，所以整句匹配可行。
_TRANSITION_NOTE = "⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地"


def test_frozen_contract_version_refs_are_2_with_transition_note():
    """守卫②前半：冻结契约三处版本引用为 `2`，且**各自带过渡态标注**。

    ⚠️ 它变红有两种含义（同下面那条 App 钉桩守卫）：要么有人把值或标注改回去了，
       要么**切片二已落地**而本守卫没跟着收敛 —— 那时 spec §8 要求改成「三方同时为 2」、
       并把过渡态标注一并撤掉。
    ⛔ **只断言值 = 2 是不够的**（spec 3b2 / 变异 B16）：那样冻结契约会声称「前后端共享 = 2」，
       而本守卫后半同时把「App 侧 = 1」认证为正确 —— 两条权威互相打脸，正是本片要消灭的形状。
    """
    lines = MODULES.read_text(encoding="utf-8").splitlines()
    # ⛔ 必须**按形状锚定**：原式 `[=|]\s*`?2`?` 会被 `| 2026-10 起…` 这类**日期单元格**满足
    # （最终评审 Minor 实证：把值改成 `3`、同行带个 2026 开头的日期，整条守卫照样绿）。
    _VALUE_SHAPES = (r"\|\s*`2`\s*\|",                      # 矩阵值单元格
                     r"TRAINING_SET_SCHEMA_VERSION\s*=\s*2\b")  # 常量写法
    targets = [l for l in lines
               if ("PRAGMA user_version" in l or "TRAINING_SET_SCHEMA_VERSION" in l)
               and any(re.search(s, l) for s in _VALUE_SHAPES)]
    assert len(targets) == 3, (
        f"冻结契约里带版本数值的引用应恰好 3 处且都为 2，实测 {len(targets)} 处：\n"
        + "\n".join(t.strip()[:110] for t in targets))
    missing = [t.strip()[:110] for t in targets if _TRANSITION_NOTE not in t]
    assert not missing, (
        "这几处改了值但**没带过渡态标注** —— 冻结契约会声称『前后端共享 = 2』，"
        "而 App 侧实际仍是 1：\n" + "\n".join(missing))


def test_app_reader_is_still_pinned_to_generation_one():
    """守卫②后半：App 读取端**仍显式钉在 1**（切片一的过渡态，切片二才改）。

    ⚠️ 两处**形状不同**，必须分别断言（spec 给的行号 `:1307` 已过期，实测在 `:1360`）：
      · `DownloadAcceptanceRunner.swift` —— 常量定义 `public let TRAINING_SET_SCHEMA_VERSION = 1`
      · `TrainingSessionCoordinator.swift` —— **写死的字面量** `expectedSchemaVersion: 1`
    ⛔ 本条**只读不改** `ios/`。它变红有两种含义：要么有人越界提前改了 App（违反切片次序），
       要么切片二已落地而这条守卫没跟着收敛（spec §8 要求那时改成「三方同时为 2」）。
    """
    runner = (REPO_ROOT / "ios/Contracts/Sources/KlineTrainerContracts"
              / "DownloadAcceptance/DownloadAcceptanceRunner.swift").read_text(encoding="utf-8")
    # ⛔ 用 `\b` 收尾：裸子串 `= 1` 会被 `= 12` 满足（最终评审 Minor）
    assert re.search(r"public let TRAINING_SET_SCHEMA_VERSION = 1\b", runner), (
        "DownloadAcceptanceRunner 的 TRAINING_SET_SCHEMA_VERSION 不再是 1 —— "
        "切片一期间 App 读取端必须仍钉在第 1 代")

    coordinator = (REPO_ROOT / "ios/Contracts/Sources/KlineTrainerContracts"
                   / "TrainingEngine/TrainingSessionCoordinator.swift").read_text(encoding="utf-8")
    assert "expectedSchemaVersion: 1)" in coordinator, (
        "TrainingSessionCoordinator 里写死的 expectedSchemaVersion 不再是 1 —— 同上")


def test_backend_production_side_is_already_generation_two():
    """守卫②中段：后端生产侧两处均为 `2`（P1 已落地，本条防退化）。"""
    ddl = (REPO_ROOT / "backend/sql/training_set_schema_v1.sql").read_text(encoding="utf-8")
    assert "PRAGMA user_version = 2;" in ddl
    gen = (REPO_ROOT / "backend/generate_training_sets.py").read_text(encoding="utf-8")
    assert re.search(r"^SCHEMA_VERSION = 2\b", gen, re.M)
    assert "PRAGMA user_version = 2;" in gen
