# backend/tests/test_ci_paths_cover_external_inputs.py
"""守卫：CI 的 paths 过滤器必须覆盖本套件读到的每一处 `backend/` 之外的文件。

背景：`.github/workflows/backend-tests.yml` 只在 `pull_request.paths` 命中的改动上
跑。而本套件里有测试**读 `backend/` 之外的东西** —— `test_env_example_coverage.py`
递归扫 `scripts/**` 下的 shell，`test_qmt_pilot_db.py` 读 iOS 那份 Swift 契约常量。
paths 一旦漏掉它们，「只改那些文件的 PR」根本不触发本套件：守卫还在，但多了一条
**静默旁路** —— 红要等合进 main 之后由 push 触发才暴露，那时已经晚了。本仓在
Catalyst 闸门上踩过同型的坑（后合 PR 引红 main）。

判据形状：
  ① 每个测试模块把自己读到的外部输入声明成模块级 `EXTERNAL_INPUTS`，并且**用这个
     常量本身**去做那次读取 —— 声明因此不可能与该模块的实际行为脱节；
  ② 本模块用 AST 静态扫描全部测试模块，收集所有 `EXTERNAL_INPUTS`（不是手抄一张
     清单：有人给守卫加第三个扫描根时，常量一改，这里的覆盖要求自动跟着变）；
  ③ 每一条声明都必须被 workflow 的 paths 列表覆盖 —— 目录要覆盖到**任意深度**，
     因为扫描器本身是递归的。判定方式是**结构比对**而非模拟 GitHub 的通配符匹配，
     理由见下方 §③ 的注释（上一版模拟法有两个已复现的假绿）。

⚠️ 已知盲区（明写，不假装闭合）：一个测试模块如果读了 `backend/` 之外的东西却**没
声明** `EXTERNAL_INPUTS`，本守卫看不见。无启发式的静态识别做不到 —— 同一个字符串
字面量在本套件里既被拼到仓库根、也被拼到 `backend/tests/`（实测 5 个候选里 3 个是
这种假阳性），而锚点表达式有四种写法。穷尽的做法是**运行期追踪整套 IO**，配方与
2026-08-30 的实测结果见
`docs/superpowers/plans/2026-08-30-ci-paths-suite-external-inputs.md` §D。
"""
from __future__ import annotations

import ast
from pathlib import Path

import pytest
import yaml

# backend/tests/<本文件> → parents[0]=tests, [1]=backend, [2]=仓库根
REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS_DIR = Path(__file__).resolve().parents[0]

# 本模块自己也读一处 `backend/` 之外的文件（就是被它校验的那份 workflow）。
# 同一条约定对自己也生效：声明它，并且用这个常量去做读取。
EXTERNAL_INPUTS = (".github/workflows/backend-tests.yml",)
WORKFLOW = REPO_ROOT / EXTERNAL_INPUTS[0]

_DECL_NAME = "EXTERNAL_INPUTS"


# ── ① 收集声明 ──────────────────────────────────────────────────────────
def _declaring_modules() -> list[Path]:
    return [
        p
        for p in sorted(TESTS_DIR.rglob("*.py"))
        if "__pycache__" not in p.as_posix()
    ]


def _declared_external_inputs() -> dict[str, list[str]]:
    """{外部输入相对路径: [声明它的模块名, ...]}。

    fail-closed：`EXTERNAL_INPUTS` 存在但不是「非空的字符串字面量序列」→ **抛异常**，
    不静默跳过。写成 continue 会把「判据够不着」伪装成「这里没有声明」。
    """
    found: dict[str, list[str]] = {}
    for path in _declaring_modules():
        module = path.relative_to(REPO_ROOT).as_posix()
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in tree.body:  # 只认模块级赋值
            if isinstance(node, ast.Assign):
                targets: list[ast.expr] = list(node.targets)
                value = node.value
            elif isinstance(node, ast.AnnAssign):
                targets = [node.target]
                value = node.value
            else:
                continue
            if not any(
                isinstance(t, ast.Name) and t.id == _DECL_NAME for t in targets
            ):
                continue
            if value is None:
                raise AssertionError(f"{module}: {_DECL_NAME} 只有类型标注、没有值")
            try:
                literal = ast.literal_eval(value)
            except (ValueError, SyntaxError) as exc:
                raise AssertionError(
                    f"{module}:{node.lineno} 的 {_DECL_NAME} 不是字面量，本扫描器"
                    f"静态求不出它的值（{exc}）。请写成字符串元组字面量。"
                ) from exc
            if not isinstance(literal, (tuple, list)) or not literal:
                raise AssertionError(
                    f"{module}:{node.lineno} 的 {_DECL_NAME} 必须是**非空**的序列，"
                    f"实得 {literal!r}"
                )
            for item in literal:
                if not isinstance(item, str) or not item:
                    raise AssertionError(
                        f"{module}:{node.lineno} 的 {_DECL_NAME} 含非字符串/空条目: "
                        f"{item!r}"
                    )
                found.setdefault(item, []).append(module)
    return found


# ── ② 读 workflow 的 paths 过滤器 ───────────────────────────────────────
def _workflow_pull_request_paths() -> list[str]:
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    # ⚠️ YAML 1.1 坑（PyYAML 6.0.3 实测）：裸键 `on:` 被解析成**布尔 True**，
    # 不是字符串 "on"。`doc["on"]` 会 KeyError。两种键都试，都取不到就报错，
    # 不返回空列表 —— 返回空会让下面的覆盖判据恒真。
    on = doc.get("on", doc.get(True))
    assert isinstance(on, dict), (
        f"{EXTERNAL_INPUTS[0]} 里取不到 on: 段（PyYAML 把裸 on 解析成 True）—— "
        f"本守卫的解析口径已失效，实得 {type(on).__name__}"
    )
    pull_request = on.get("pull_request")
    assert isinstance(pull_request, dict), (
        "on.pull_request 不是映射 —— 解析口径已失效，"
        f"实得 {type(pull_request).__name__}"
    )
    paths = pull_request.get("paths")
    assert isinstance(paths, list) and paths, (
        "on.pull_request.paths 缺失或为空。注意：**删掉整个 paths 过滤器**"
        "（= 每个 PR 都跑）也会让本守卫红 —— 那是刻意的，请改本守卫并说明理由。"
    )
    return [str(p) for p in paths]


# ── ③ 覆盖判据 ──────────────────────────────────────────────────────────
# GitHub 的 paths 过滤器语法**不是**普通 glob（官方 filter pattern cheat sheet）：
#   *   零或多个字符，不跨 `/`
#   **  零或多个任意字符（跨 `/`）
#   ?   **前一个字符**出现 0 或 1 次   ← 数量词，不是「任意一个字符」
#   +   **前一个字符**出现 1 或多次    ← 同上
#   []  方括号里的一个字符
#   !   置于开头时取反，从前面已匹配的结果里**减掉**
#
# 上一版守卫自己实现了一套 glob→正则、再拿两个固定探针去试，两处都翻车（codex R1，
# 两条本地都复现过）：
#   ① 有限个探针证明不了「任意深度」——`scripts/*` + `scripts/*/*` 同时满足
#      一层探针和两层探针，却盖不住 `scripts/a/b/c.sh`，而扫描器用 rglob 读任意深度；
#   ② `?` 被按「任意一个字符」翻译，与 GitHub 的数量词语义相反，于是
#      `Model?.swift` 被判成盖得住 `Models.swift`，GitHub 实际不匹配。
#
# 结论：**别再模拟 GitHub 的匹配**。只认两种结构上无歧义的条目：
#   - 字面路径（不含任何元字符）；
#   - 规范递归前缀 `<字面前缀>/**`，以及全仓通配 `**`。
# 认不出的条目一律**不授予覆盖**，而不是报错：paths 是并集，多一条只会让触发面更大，
# 所以「不据它授予覆盖」的方向是**更严**，不可能造成假绿；真红时会把这些条目列出来
# 解释为什么没算数，作者要么改成规范写法、要么按 GitHub 的确切语义扩本守卫。
# ⚠️ 唯一的例外是 `!`：它从并集里**减掉**东西，忽略它就不再保守 → 直接抛。
_GLOB_META = set("*?+[]{}()|!")


def _has_meta(text: str) -> bool:
    return any(ch in _GLOB_META for ch in text)


def _recursive_prefix(entry: str) -> str | None:
    """`<字面前缀>/**` → 该前缀；`**` → `""`（全仓）；不是规范递归写法 → None。"""
    if entry == "**":
        return ""
    if entry.endswith("/**"):
        prefix = entry[: -len("/**")]
        if prefix and not _has_meta(prefix):
            return prefix
    return None


def _uncovered(rel: str, entries: list[str]) -> list[str]:
    """rel 未被覆盖时返回「为什么」的说明行；已覆盖则返回空列表。"""
    for entry in entries:
        if entry.startswith("!"):
            raise AssertionError(
                f"paths 里有否定式条目 {entry!r}：它会从触发面里**减掉**内容，"
                "本守卫的保守近似（忽略认不出的条目）对它不成立。"
                "请改本守卫按 GitHub 的确切语义处理否定式，再判覆盖。"
            )
    is_dir = (REPO_ROOT / rel).is_dir()
    unusable: list[str] = []
    for entry in entries:
        prefix = _recursive_prefix(entry)
        if prefix is not None and (
            prefix == "" or rel == prefix or rel.startswith(prefix + "/")
        ):
            return []
        # 目录声明**不能**由字面条目满足：paths 里一个字面 `scripts` 匹配的是
        # 「一个叫 scripts 的文件」，不是该目录下的内容。
        if not is_dir and prefix is None and not _has_meta(entry) and entry == rel:
            return []
        if prefix is None and _has_meta(entry):
            unusable.append(entry)
    want = (
        f"`{rel}/**`（或一条包住它的上级 `<目录>/**`）"
        if is_dir
        else f"`{rel}` 本身（或一条包住它的 `<目录>/**`）"
    )
    reason = [f"{rel}：paths 里没有 {want}"]
    if unusable:
        reason.append(
            f"    这些条目含元字符、本守卫不据以授予覆盖（改成规范写法或扩本守卫）：{unusable}"
        )
    return reason


# ── 防空转 ──────────────────────────────────────────────────────────────
def test_scan_finds_external_input_declarations():
    """扫不到任何声明 = 扫描器坏了，下面那条覆盖判据会恒真通过。"""
    declared = _declared_external_inputs()
    assert declared, (
        f"一条 {_DECL_NAME} 声明都没扫到 —— 至少本模块自己就有一条，"
        "说明 AST 扫描器已经失去判别力"
    )


def test_workflow_pull_request_paths_is_non_empty():
    """paths 解析不出东西 = 覆盖判据的另一侧为空，同样会恒真。"""
    assert _workflow_pull_request_paths()


def test_declared_external_inputs_are_well_formed():
    """声明必须是**仓库相对**、真实存在、且确实在 `backend/` 之外。

    - 不存在 ⇒ 陈旧声明：它会安静地满足任何 paths 列表（探针路径随便怎么拼都行），
      于是这条声明变成一句空话；
    - 落在 `backend/` 里 ⇒ 不是"外部输入"，`backend/**` 早就覆盖了，
      放进来只会稀释这张表的含义。
    """
    for rel, modules in sorted(_declared_external_inputs().items()):
        where = ", ".join(modules)
        assert not rel.startswith(("/", "./")) and not rel.endswith("/"), (
            f"{where} 声明的 {rel!r} 不是干净的仓库相对路径"
        )
        assert (REPO_ROOT / rel).exists(), (
            f"{where} 声明的外部输入 {rel!r} 在仓库里不存在 —— 陈旧声明会静默空转"
        )
        assert not rel.startswith("backend/") and rel != "backend", (
            f"{where} 声明的 {rel!r} 在 backend/ 里，不是外部输入"
        )


# ── 覆盖判据自检（反向判别力）────────────────────────────────────────────
_SWIFT = "ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift"
_FIXTURES = "tests/contract-fixtures"


@pytest.mark.parametrize(
    "rel,entries,covered",
    [
        # —— 目录声明：只有规范递归前缀算数 ——
        ("scripts", ["scripts/**"], True),
        ("scripts", ["**"], True),
        # 单星不跨 `/`，而扫描器递归读 scripts/governance/*.sh
        ("scripts", ["scripts/*"], False),
        # 只盖住某个子目录 ≠ 盖住整个目录
        ("scripts", ["scripts/governance/**"], False),
        # 字面条目匹配的是「一个叫 scripts 的文件」，不是目录内容
        ("scripts", ["scripts"], False),
        # 前缀不是边界：scripts-extra 跟 scripts 无关
        ("scripts", ["scripts-extra/**"], False),
        ("scripts", ["backend/**"], False),
        (_FIXTURES, ["tests/contract-fixtures/**"], True),
        (_FIXTURES, ["tests/**"], True),
        (_FIXTURES, ["tests/contract-fixtures"], False),
        # —— 文件声明：字面相等，或被某条递归前缀包住 ——
        (_SWIFT, [_SWIFT], True),
        (_SWIFT, ["ios/**"], True),
        (_SWIFT, ["ios/Contracts/Sources/KlineTrainerContracts/Models/**"], True),
        (_SWIFT, ["ios/Contracts/Sources/KlineTrainerContracts/Models/*"], False),
        (_SWIFT, ["ios/Contracts/Sources/KlineTrainerContracts/Models/Other.swift"], False),
        (_SWIFT, ["ios/Contracts/Sources/KlineTrainerContracts/Models"], False),
        # —— 认不出的条目不授予覆盖，但也不该把本来成立的覆盖弄没 ——
        ("scripts", ["scripts/[ab]*", "scripts/**"], True),
        ("scripts", ["scripts/[ab]*"], False),
    ],
)
def test_coverage_is_structural(rel, entries, covered):
    assert (_uncovered(rel, entries) == []) is covered


def test_negation_entry_is_refused():
    """`!` 从触发面里**减掉**内容，「忽略认不出的条目」这个保守近似对它不成立。

    别的元字符条目被忽略只会让判据更严（顶多误红），`!` 却能让判据更松（假绿），
    所以它必须走抛异常这条路，不能跟其它元字符一样被忽略。
    """
    with pytest.raises(AssertionError):
        _uncovered("scripts", ["scripts/**", "!scripts/governance/**"])


# ── 反例（codex R1 提出，已本地复现）────────────────────────────────────
def test_split_star_entries_do_not_cover_a_recursive_directory():
    """`scripts/*` + `scripts/*/*` 不算覆盖一个**递归**扫描的目录。

    两条加起来能满足「一层」和「两层」，但扫描器用 rglob 读任意深度，
    `scripts/a/b/c.sh` 就漏在外面。有限个探针证明不了无限深度 —— 这正是
    R1 指出的假绿：workflow 写成这样能过守卫，而只改深层脚本的 PR 静默跳过全套。
    """
    assert _uncovered("scripts", ["scripts/*", "scripts/*/*"]) != []


def test_question_mark_entry_does_not_cover_the_swift_file():
    """GitHub 的 `?` 是「前一个字符出现 0 或 1 次」的**数量词**，不是任意字符。

    故 `Model?.swift` 实际匹配 `Mode.swift` / `Model.swift`，**不匹配**
    `Models.swift`。守卫若按「任意字符」理解就会发出一张 GitHub 不认的通行证。
    """
    swift = "ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift"
    near_miss = "ios/Contracts/Sources/KlineTrainerContracts/Models/Model?.swift"
    assert _uncovered(swift, [near_miss]) != []


# ── 主判据 ──────────────────────────────────────────────────────────────
def test_ci_paths_cover_every_declared_external_input():
    """判据③ —— 每条声明的外部输入，改动它都必须能触发本套件。"""
    entries = _workflow_pull_request_paths()
    misses: list[str] = []
    for rel, modules in sorted(_declared_external_inputs().items()):
        gaps = _uncovered(rel, entries)
        if gaps:
            detail = "\n".join(gaps)
            misses.append(f"  （声明于 {', '.join(modules)}）{detail}")
    assert not misses, (
        "以下外部输入没被 CI 的 pull_request.paths 覆盖 —— 只改这些文件的 PR "
        "不会触发后端测试套件，守卫存在但有静默旁路：\n"
        + "\n".join(misses)
        + f"\n当前 paths: {entries}\n"
        "修法：往 .github/workflows/backend-tests.yml 的 paths 里补条目 —— "
        "目录写 `<目录>/**`，单文件写全路径。本守卫只认这两种无歧义写法，"
        "别的元字符写法即使在 GitHub 上成立，这里也不会算作覆盖（保守方向，见上方注释）。"
        "注意该文件对 Claude 是硬 deny，须走 ceremony 由 user 落地。"
    )
