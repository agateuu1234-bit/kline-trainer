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
    """收集 os.environ.get("X") / os.environ["X"] / os.getenv("X") 的**字面量**键名。

    刻意只认字面量：`os.environ.get(name)` 这种动态键本来就无法静态归类，
    漏掉它不会造成假绿——它读的名字连人也看不出来，要靠代码评审拦。
    刻意用 AST 而不是正则：`backend/scripts/_pilot_verify_harness.py` 里有一段
    **字符串字面量**形式的 `os\\.environ\\.get\\("(DSN\\d*)"\\)` 正则源码，
    正则扫描会把它当成真消费者，AST 不会。
    """

    def __init__(self) -> None:
        self.keys: set[str] = set()

    @staticmethod
    def _literal(node: ast.expr) -> str | None:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        return None

    def visit_Call(self, node: ast.Call) -> None:
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr in ("get", "getenv"):
            base = func.value
            is_environ_get = isinstance(base, ast.Attribute) and base.attr == "environ"
            is_os_getenv = (
                isinstance(base, ast.Name) and base.id == "os" and func.attr == "getenv"
            )
            if (is_environ_get or is_os_getenv) and node.args:
                key = self._literal(node.args[0])
                if key is not None:
                    self.keys.add(key)
        self.generic_visit(node)

    def visit_Subscript(self, node: ast.Subscript) -> None:
        value = node.value
        if isinstance(value, ast.Attribute) and value.attr == "environ":
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


# 「这个脚本真的 source 了一个 .env」：`source x/.env` 或 `. x/.env`
_SOURCES_DOTENV_RE = re.compile(r"^\s*(?:source|\.)\s+\S*\.env\b", re.MULTILINE)
# 该脚本自己声明的必需变量列表：`for var in A B C D; do`
_REQUIRED_LOOP_RE = re.compile(r"for\s+var\s+in\s+([A-Za-z0-9_\s]+?);\s*do")


def _shell_consumer_files() -> list[Path]:
    return sorted(
        list(BACKEND_DIR.rglob("*.sh")) + list((REPO_ROOT / "scripts").glob("*.sh"))
    )


def _scan_shell_keys() -> set[str]:
    """真的 source 了 .env 的 shell 脚本，取它自己声明的必需变量列表。

    fail-closed（对齐 feedback_guard_skip_conflates_not_a_site_with_unknown）：
    如果一个脚本 source 了 .env 却找不到必需变量循环，**抛异常**而不是当成
    「零消费者」静默跳过——那会把「判据够不着」伪装成「断定不是目标」。
    """
    keys: set[str] = set()
    for path in _shell_consumer_files():
        text = path.read_text(encoding="utf-8")
        if not _SOURCES_DOTENV_RE.search(text):
            continue
        match = _REQUIRED_LOOP_RE.search(text)
        if match is None:
            raise AssertionError(
                f"{path.relative_to(REPO_ROOT)} source 了 .env 却没有 "
                "`for var in ...; do` 必需变量声明 —— 本扫描器够不到它读了哪些名字。"
                "请在该脚本里补上必需变量循环，或改本扫描器（不要让它静默漏扫）。"
            )
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
