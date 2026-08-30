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
     因为扫描器本身是递归的。

⚠️ 已知盲区（明写，不假装闭合）：一个测试模块如果读了 `backend/` 之外的东西却**没
声明** `EXTERNAL_INPUTS`，本守卫看不见。无启发式的静态识别做不到 —— 同一个字符串
字面量在本套件里既被拼到仓库根、也被拼到 `backend/tests/`（实测 5 个候选里 3 个是
这种假阳性），而锚点表达式有四种写法。穷尽的做法是**运行期追踪整套 IO**，配方与
2026-08-30 的实测结果见
`docs/superpowers/plans/2026-08-30-ci-paths-suite-external-inputs.md` §D。
"""
from __future__ import annotations

import ast
import re
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
# GitHub 的 paths 过滤器语法：`*` 匹配零或多个字符但**不跨 `/`**；`**` 跨 `/`。
# 其余元字符（`?` 除外）本匹配器建模不了 —— 遇到就抛，不猜。
_UNSUPPORTED_GLOB_CHARS = set("[]{}()|+")


def _entry_regex(entry: str) -> re.Pattern[str]:
    if entry.startswith("!"):
        raise AssertionError(f"否定式 paths 条目 {entry!r}：本匹配器建模不了，请改本守卫")
    bad = sorted(set(entry) & _UNSUPPORTED_GLOB_CHARS)
    if bad:
        raise AssertionError(
            f"paths 条目 {entry!r} 含本匹配器建模不了的元字符 {bad}，请改本守卫"
        )
    out: list[str] = []
    i = 0
    while i < len(entry):
        if entry.startswith("**", i):
            out.append(".*")
            i += 2
        elif entry[i] == "*":
            out.append("[^/]*")
            i += 1
        elif entry[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(entry[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def _probes(rel: str) -> list[str]:
    """要证明「改这个输入会触发 CI」，得拿哪些具体路径去问 paths 过滤器。

    目录：递归扫描面 ⇒ 一层和多层各探一次（`scripts/*` 能过第一探、过不了第二探，
    而扫描器真的会读 `scripts/governance/*.sh` —— 这个区分必须留住）。
    """
    if (REPO_ROOT / rel).is_dir():
        return [f"{rel}/__probe__", f"{rel}/__probe_dir__/__probe__"]
    return [rel]


def _uncovered(rel: str, entries: list[str]) -> list[str]:
    regexes = [_entry_regex(e) for e in entries]
    return [p for p in _probes(rel) if not any(r.match(p) for r in regexes)]


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


# ── 匹配器自检（反向判别力）──────────────────────────────────────────────
@pytest.mark.parametrize(
    "entry,candidate,expected",
    [
        ("scripts/**", "scripts/a.sh", True),
        ("scripts/**", "scripts/governance/a.sh", True),
        # 关键判别：单星不跨 `/`。扫描器递归读 scripts/governance/*.sh，
        # 所以 `scripts/*` **不算**覆盖 —— 这一条区分不出来，整条守卫就废了。
        ("scripts/*", "scripts/a.sh", True),
        ("scripts/*", "scripts/governance/a.sh", False),
        ("backend/**", "scripts/a.sh", False),
        ("scripts/**", "backend/a.sh", False),
        # 前缀不能当命中：`scripts/**` 不该覆盖 `scripts-extra/a.sh`
        ("scripts/**", "scripts-extra/a.sh", False),
        # 精确文件条目
        ("ios/x/M.swift", "ios/x/M.swift", True),
        ("ios/x/M.swift", "ios/x/N.swift", False),
        ("ios/x/M.swift", "ios/x/M.swiftx", False),
    ],
)
def test_glob_matcher_discriminates(entry, candidate, expected):
    assert bool(_entry_regex(entry).match(candidate)) is expected


@pytest.mark.parametrize("entry", ["!scripts/**", "scripts/[ab]*", "s/+(a|b)", "a/{x,y}"])
def test_matcher_refuses_patterns_it_cannot_model(entry):
    """建模不了就抛，不静默当成「不匹配」（那会造成假红）或「匹配」（假绿）。"""
    with pytest.raises(AssertionError):
        _entry_regex(entry)


# ── 主判据 ──────────────────────────────────────────────────────────────
def test_ci_paths_cover_every_declared_external_input():
    """判据③ —— 每条声明的外部输入，改动它都必须能触发本套件。"""
    entries = _workflow_pull_request_paths()
    misses: list[str] = []
    for rel, modules in sorted(_declared_external_inputs().items()):
        gaps = _uncovered(rel, entries)
        if gaps:
            misses.append(f"  {rel}  （声明于 {', '.join(modules)}）未覆盖: {gaps}")
    assert not misses, (
        "以下外部输入没被 CI 的 pull_request.paths 覆盖 —— 只改这些文件的 PR "
        "不会触发后端测试套件，守卫存在但有静默旁路：\n"
        + "\n".join(misses)
        + f"\n当前 paths: {entries}\n"
        "修法：往 .github/workflows/backend-tests.yml 的 paths 里补条目"
        "（目录用 `<dir>/**`，单文件写全路径）。"
        "注意该文件对 Claude 是硬 deny，须走 ceremony 由 user 落地。"
    )
