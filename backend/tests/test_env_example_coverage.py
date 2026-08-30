# backend/tests/test_env_example_coverage.py
"""C1-6 / T2：`.env.example` 必须覆盖「消费 backend/.env 的那一族」环境变量。

背景（spec §2.5-a，2026-08-24 实测）：`app/main.py` / `app/scheduler_main.py` /
`import_csv.py` / `generate_training_sets.py` 四处读 `DATABASE_URL`，而
`.env.example` 当时只定义 `DB_URL` —— 名字对不上，是个真 bug。而且
`app/main.py:16-22` 在 DSN 缺失时会**静默**回落 InMemoryLeaseRepository，
所以这个名字对不上不报错，只会让手机拉到一个空库（假绿）。

判据形状（spec T2-1 的 2026-08-24 订正版）：
  ① discovered == ENV_FILE_KEYS | OUT_OF_SCOPE_KEYS  （精确相等，两个方向同时成立）
  ② ENV_FILE_KEYS <= `.env.example` 里解析出的 KEY 集合

判据①是**反向断言**，同时兜住两种失效：
  - 扫描器坏掉 / 扫不到文件 → discovered 为空 → 不相等 → 红（防空转）；
  - 有人新增、改名、删除一个消费者而没更新分类表 → 不相等 → 红（枚举性）。
所以「变量名写在本文件里」在这里**不构成恒真**：被比较的另一侧是扫出来的，
不是写死的。
"""
from __future__ import annotations

import ast
import re
from pathlib import Path

# backend/tests/<本文件> → parents[0]=tests, [1]=backend, [2]=仓库根
REPO_ROOT = Path(__file__).resolve().parents[2]
BACKEND_DIR = REPO_ROOT / "backend"
ENV_EXAMPLE = BACKEND_DIR / ".env.example"

# 本模块读到 `backend/` **之外**的东西：shell 扫描面包含仓库根的 `scripts/`。
# 这条声明由 `test_ci_paths_cover_external_inputs.py` 静态收集，用来保证
# `.github/workflows/backend-tests.yml` 的 `pull_request.paths` 覆盖它 ——
# 否则「只改 scripts/ 的 PR」压根不触发本套件，本守卫就有了一条静默旁路。
# 下面 `_shell_consumer_files` **必须用这个常量本身**去拼扫描根：声明与实际扫描面
# 共用一份来源，才不会一边改了另一边还停在旧值上。
EXTERNAL_INPUTS = ("scripts",)

# ── 分类表 ──────────────────────────────────────────────────────────────
# 该进 `.env.example` 的：部署时由 backend/.env 提供。
ENV_FILE_KEYS = {
    "DATABASE_URL",       # 后端代码读；容器内走 compose 内网 db:5432
    "DB_URL",             # 宿主侧管理用 DSN；scripts/nas-preflight.sh 的必需变量循环读
    "NAS_HOST",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_DB",
}

# ⚠️ 已知盲区（本 PR 不修，记录在案）：本扫描器**不覆盖** `backend/docker-compose.yml`，
# 而它其实是 `backend/.env` 的真消费者，走两条通道：
#   - `env_file: - .env`（compose 文件 6-7 行）把整份 .env 注入容器；
#   - `${...}` 插值（9-16 行），其中 16 行 `- "${DB_BIND_HOST:-127.0.0.1}:5433:5432"`。
# 于是 `DB_BIND_HOST` 既不在 `.env.example` 里，也不在下面两张分类表里。
# 为什么不能顺手把它填进 OUT_OF_SCOPE_KEYS：判据①是**精确集合相等**，
# 而扫描器扫不到 compose 文件，discovered 里不会有 `DB_BIND_HOST`；
# 单方面往分类表加一条会让等式左右不等 —— 判据①立刻变红。
# 正解是**先让扫描器认得 compose**（再补分类），那是下一个 PR 的范围。
# 明确**不**进 `.env.example` 的，每条都要有理由（spec §2.5-a 实测全表）。
OUT_OF_SCOPE_KEYS = {
    # 人工验证脚本的 DSN：每次在命令行显式传，从不读 .env。
    "DSN",
    "DSN2",
    # 破坏性/清理开关：故意要求每次手打，写进配置样例等于给它发通行证。
    "QMT_VERIFY_ALLOW_DESTRUCTIVE",
    "QMT_VERIFY_ALLOW_REMOTE",
    "QMT_VERIFY_FORCE_CLEANUP",
    # B4 调度器本次不部署（spec §5.3）。将来部署调度器时必须重新归类到 ENV_FILE_KEYS。
    "TRAINING_SETS_DIR",
}


class _EnvKeyVisitor(ast.NodeVisitor):
    """收集环境变量读取点的**字面量**键名。

    认得的书写形态（I1：以前只认前三种，后面几种被**静默漏扫**）：
      - `os.environ.get("X")` / `os.environ["X"]` / `os.getenv("X")`；
      - `os.environ.setdefault("X", ...)` / `os.environ.pop("X")`；
      - `from os import environ, getenv` 之后的裸名形态：
        `environ.get("X")` / `environ["X"]` / `environ.setdefault("X", ...)` /
        `environ.pop("X")` / `getenv("X")`。
    漏掉其中任何一种都不会让判据①变红：消费者没被扫到 → discovered 少一个名字，
    而人也不会去改分类表 → 两边一起缩水、等式照样成立。这正是本 guard 要防的 bug
    本身能从 guard 面前走过去的原因，所以「认得的形态」必须穷尽常见写法。

    刻意只认字面量：`os.environ.get(name)` 这种动态键本来就无法静态归类，
    漏掉它不会造成假绿——它读的名字连人也看不出来，要靠代码评审拦。
    刻意用 AST 而不是正则：`backend/scripts/_pilot_verify_harness.py` 里有一段
    **字符串字面量**形式的 `os\\.environ\\.get\\("(DSN\\d*)"\\)` 正则源码，
    正则扫描会把它当成真消费者，AST 不会。
    """

    # environ 这个映射上「取一个键」的方法名（都是第一个位置参数即键名）。
    _ENVIRON_METHODS = ("get", "setdefault", "pop")

    def __init__(self) -> None:
        self.keys: set[str] = set()

    @staticmethod
    def _literal(node: ast.expr) -> str | None:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        return None

    @staticmethod
    def _is_environ(node: ast.expr) -> bool:
        """`os.environ`（属性形态）或 `from os import environ` 之后的裸 `environ`。"""
        if isinstance(node, ast.Attribute):
            return node.attr == "environ"
        return isinstance(node, ast.Name) and node.id == "environ"

    def visit_Call(self, node: ast.Call) -> None:
        func = node.func
        if isinstance(func, ast.Attribute):
            hit = (
                func.attr in self._ENVIRON_METHODS and self._is_environ(func.value)
            ) or (
                func.attr == "getenv"
                and isinstance(func.value, ast.Name)
                and func.value.id == "os"
            )
        else:
            # `from os import getenv` 之后的裸调用
            hit = isinstance(func, ast.Name) and func.id == "getenv"
        if hit and node.args:
            key = self._literal(node.args[0])
            if key is not None:
                self.keys.add(key)
        self.generic_visit(node)

    def visit_Subscript(self, node: ast.Subscript) -> None:
        if self._is_environ(node.value):
            key = self._literal(node.slice)
            if key is not None:
                self.keys.add(key)
        self.generic_visit(node)


def _python_consumer_files() -> list[Path]:
    """backend/ 下的全部 .py，排除测试与字节码缓存。

    扫描根刻意限定在 backend/：仓库根的 tests/hooks/*.py 是治理工具链，
    读的是 PATH / CLAUDE_SESSION_ID 之类，与部署配置无关。
    """
    out: list[Path] = []
    for path in sorted(BACKEND_DIR.rglob("*.py")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        if rel.startswith("backend/tests/") or "__pycache__" in rel:
            continue
        out.append(path)
    return out


def _scan_python_keys() -> set[str]:
    keys: set[str] = set()
    for path in _python_consumer_files():
        visitor = _EnvKeyVisitor()
        visitor.visit(ast.parse(path.read_text(encoding="utf-8"), filename=str(path)))
        keys |= visitor.keys
    return keys


# 严格式：「这个脚本**确定**是消费者，去读它的必需变量循环」——`source x/.env` / `. x/.env`。
_SOURCES_DOTENV_RE = re.compile(r"^\s*(?:source|\.)\s+\S*\.env\b", re.MULTILINE)
# 宽探针（I1 fail-closed）：命令位上的 `source` / `.`，目标是一个 `.env`，
# 或是一个**变量**路径（`source "$ENV_FILE"` —— 静态扫描根本够不到它指向哪个文件）。
# 严格式匹配不到、宽探针匹配得到 ⇒ 本扫描器「够不着」，必须抛异常而不是 continue，
# 否则以下写法会被静默漏扫、而 guard 依旧绿：
#   `set -a && source backend/.env` / `[ -f .env ] && source .env` / `source "$ENV_FILE"`
# 「命令位」= 行首 / 命令分隔符（; & | ( ) { }）之后 / then|else|do 之后。
# 这一条不能省：`scripts/governance/verify-wave{2,3}-pr1-rfc.sh` 里真有一行
# `echo "GATE FAIL: unreadable source $f"`，不要求命令位就会把它误判成 source 调用。
_LOOSE_DOTENV_RE = re.compile(
    r"(?:^|[;&|(){}]|\b(?:then|else|do)\b)[ \t]*"
    r"(?:source|\.)[ \t]+[\"']?\S*?(?:\.env\b|\$\w)",
    re.MULTILINE,
)
# 该脚本自己声明的必需变量列表：`for var in A B C D; do`
_REQUIRED_LOOP_RE = re.compile(r"for\s+var\s+in\s+([A-Za-z0-9_\s]+?);\s*do")


def _strip_comment_lines(text: str) -> str:
    """把整行注释置空（保留行号，便于报错时指行）。

    `# source backend/.env` 是注释不是消费者；两个探针都读剥注释后的文本，
    宽探针才不会被注释里的示例命令打红。
    """
    return "\n".join(
        "" if line.lstrip().startswith("#") else line for line in text.splitlines()
    )


def _shell_consumer_files() -> list[Path]:
    """backend/ 与 scripts/ 下的全部 .sh，**两边都递归**（M10）。

    以前 scripts/ 用非递归 glob，只看到 5 个文件、漏掉 scripts/*/ 下的 25 个；
    覆盖面不一致本身就是漏扫来源，所以统一 rglob。仓库里只有这两处放 shell 脚本。
    """
    roots = [BACKEND_DIR] + [REPO_ROOT / rel for rel in EXTERNAL_INPUTS]
    return sorted(path for root in roots for path in root.rglob("*.sh"))


def _scan_shell_keys() -> set[str]:
    """真的 source 了 .env 的 shell 脚本，取它自己声明的必需变量列表。

    fail-closed（对齐 feedback_guard_skip_conflates_not_a_site_with_unknown）两道：
      1. 宽探针命中而严格式没命中 → **抛异常**：识别这一步够不着这种写法；
      2. 严格式命中却找不到必需变量循环 → **抛异常**而不是当成「零消费者」静默跳过。
    两道都不能写成 continue——那会把「判据够不着」伪装成「断定不是目标」。
    """
    keys: set[str] = set()
    for path in _shell_consumer_files():
        scannable = _strip_comment_lines(path.read_text(encoding="utf-8"))
        if not _SOURCES_DOTENV_RE.search(scannable):
            loose = _LOOSE_DOTENV_RE.search(scannable)
            if loose is None:
                continue
            line_no = scannable[: loose.start()].count("\n") + 1
            line_text = scannable.splitlines()[line_no - 1].strip()
            raise AssertionError(
                f"{path.relative_to(REPO_ROOT)}:{line_no} 看起来在 source 一个 .env / "
                f"一个变量路径，但本扫描器的严格式认不出来：\n    {line_text}\n"
                "请把该脚本改成 `source <路径>/.env` 的行首写法，或者把本扫描器改宽"
                "（不要让它静默漏扫——漏扫时 discovered 和分类表会一起缩水、判据①照样绿）。"
            )
        matches = list(_REQUIRED_LOOP_RE.finditer(scannable))
        if not matches:
            raise AssertionError(
                f"{path.relative_to(REPO_ROOT)} source 了 .env 却没有 "
                "`for var in ...; do` 必需变量声明 —— 本扫描器够不到它读了哪些名字。"
                "请在该脚本里补上必需变量循环，或改本扫描器（不要让它静默漏扫）。"
            )
        # M9：并所有循环，而不是只取第一个——以后加第二个循环不会被静默忽略。
        for match in matches:
            keys |= set(match.group(1).split())
    return keys


def _env_example_keys() -> set[str]:
    keys: set[str] = set()
    for line in ENV_EXAMPLE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", stripped)
        if match:
            keys.add(match.group(1))
    return keys


def test_classification_table_is_disjoint():
    """两张分类表不得重叠——重叠会让判据①的语义变得含混。"""
    overlap = ENV_FILE_KEYS & OUT_OF_SCOPE_KEYS
    assert overlap == set(), f"同一个名字同时出现在两张分类表里: {sorted(overlap)}"


def test_discovered_keys_match_classification():
    """判据① —— 扫描全集与分类表精确相等（两个方向）。

    红了怎么办：
      - 多出来的名字 = 你新增/改名了一个消费者。把它归到 ENV_FILE_KEYS
        （部署时要配）或 OUT_OF_SCOPE_KEYS（附理由）。
      - 少了的名字 = 分类表有陈旧条目，或扫描器坏了。先确认扫描器还能扫到东西。
    """
    discovered = _scan_python_keys() | _scan_shell_keys()
    expected = ENV_FILE_KEYS | OUT_OF_SCOPE_KEYS
    assert discovered == expected, (
        f"扫描全集与分类表不符\n"
        f"  扫到但没归类: {sorted(discovered - expected)}\n"
        f"  归类了但没扫到: {sorted(expected - discovered)}"
    )


def test_env_file_keys_are_all_defined_in_env_example():
    """判据② —— 该进配置样例的名字，每一个都要有同名 `KEY=` 行。"""
    defined = _env_example_keys()
    missing = ENV_FILE_KEYS - defined
    assert missing == set(), (
        f".env.example 缺少这些消费者读取的名字: {sorted(missing)}"
        f"（已定义: {sorted(defined)}）"
    )
