# QMT 4b 切片 S1：共享地基（文件系统信任边界原语）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付 `backend/qmt_fsroot.py` —— 三个目录（`--source` / `--dest` / `--output`）共用的文件系统信任边界原语：逐段无跟随打开、耐久提交、锁纪律、归属标记与认领协议。

**Architecture:** 一个纯文件系统模块，**不认识**「staging」「output」「source」这些业务概念——标记文件名、自指字段名、锁文件名全部作为参数传入，由调用方（S4/S5 与 4c）参数化出各自规格。全部逻辑可用 `tmp_path` 测全，零网络、零数据库、零源机依赖。

**Tech Stack:** Python 3（`os` 的 `*at` 系列 + `dir_fd=`、`fcntl.flock` / `F_FULLFSYNC`、`pytest` + `tmp_path`）。无新增第三方依赖。

**Spec:** `docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md` §4.1 + §4.5 的「锁」与「耐久提交协议」两小节
**切片依据:** `docs/superpowers/specs/2026-08-21-qmt-plan4b-slice-map.md` S1

## Global Constraints

以下为 spec 的全局硬约束，**每个 Task 的要求都隐含包含本节**：

1. **绝不 `realpath()` / `Path.resolve()` 去解析用户传入的目录路径** —— 那正是「跟随」，用它等于自愿放弃这道闸。唯一例外是 Task 11 的路径重叠判据（spec §4.1 闸 1 明写用 `resolve()`，且它与 inode 判据**并用**）。
2. **逐段无跟随必须覆盖从 `/` 到叶子的每一个分量，包括建立信任边界的那一次 open 本身**（spec §4.1 R75-F2 / 对象×维度矩阵维度③）。
3. **`os.replace` 一律直接传 `src_dir_fd`/`dst_dir_fd`，不得用 `os.supports_dir_fd` 做能力探测**（O4-F14）。本机实测：`os.replace in os.supports_dir_fd` 为 **False**、`os.rename` 才是 True，而 `os.replace(..., src_dir_fd=, dst_dir_fd=)` **实际能跑通**。写能力探测的实现会在 macOS 上恰好退回被明令禁止的按路径改名。
4. **目录分量是符号链接时得 `ENOTDIR`，不是 `ELOOP`**（本机实测，O4-F12）；只有不带 `O_DIRECTORY` 的叶子文件 `O_NOFOLLOW` 才得 `ELOOP`。**且 `ENOTDIR` 与「这里放了个普通文件」不可区分**——错误消息**不得声称「这是符号链接」**。
5. **耐久提交协议**：凡改动命名空间（`os.replace` / `os.mkdir` / `unlink`）之处，动作之后必须 `fsync` 其所在目录；写文件内容则先 `fsync` 文件本身。**豁免两项**（写出来是为了让「闭合」可被检验）：锁文件本身的创建（存在与否不参与任何判定）、失败路径上 `.part` 的删除。
6. **威胁模型含断电**（O4-F11）：macOS `man 2 fsync` 明写 `fsync` 既不保证断电耐久、也不保证跨设备写序。故 **manifest 提交**与**顺序屏障**两处用 `fcntl(fd, F_FULLFSYNC)`，其余落地点用 `os.fsync`。本模块只提供两个原语，由调用方按此规则选用。
7. **本模块不实现 `--output` 的业务规格**（`.superseded/`、报告落盘、zip）——那是 4c。S1 只保证同一套原语**能表达**两种规格，差异只有 `EEXIST` 那一档。
8. **中文注释，引用 spec 的 finding 编号**（本仓既有风格，见 `backend/qmt_normalize.py`）。文件头两行为 `# backend/<name>.py` 与模块 docstring 注明 Spec 出处。
9. **测试位置** `backend/tests/test_qmt_fsroot.py`；运行方式 `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest`。基线为 **838 passed**。

---

## File Structure

| 文件 | 职责 |
|---|---|
| `backend/qmt_fsroot.py`（新建） | 全部 S1 原语与异常族。单一职责：**受纪律约束的文件系统访问**，不含任何业务判断 |
| `backend/tests/test_qmt_fsroot.py`（新建） | S1 的全部单测，纯 `tmp_path` |

**为什么单独成模块而不是塞进 `qmt_fetch.py`**：这套原语的第二个使用者是 4c 的 `qmt_pilot`（spec 切分图明写「4c 引用 4b 的共享地基」）。放进 `qmt_fetch.py` 会让 4c 反向依赖一个 CLI 脚本。

---

### Task 1: 异常族 + 路径分量规则

**Files:**
- Create: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: 无
- Produces:
  - `PathDisciplineError(ValueError)`
  - `PathEscapeError(Exception)` 带属性 `relative_path: str` / `component: str` / `errno: int`
  - `DirectoryExistsError(Exception)`
  - `LockUnavailableError(Exception)` / `LockDisciplineError(Exception)` / `MarkerInvalidError(Exception)`
  - `normalize_abs_path(raw: str) -> str`
  - `split_components(path: str) -> list[str]`
  - `_split_rel(relpath: str) -> list[str]`

- [ ] **Step 1: 写失败的测试**

写入 `backend/tests/test_qmt_fsroot.py`：

```python
# backend/tests/test_qmt_fsroot.py
from __future__ import annotations
import pytest
from qmt_fsroot import (
    PathDisciplineError, normalize_abs_path, split_components, _split_rel,
)


def test_normalize_strips_trailing_slash_from_shell_completion():
    # shell 目录补全默认补出尾斜杠，而本项目的操作者不是程序员——
    # 尾斜杠必须在检查空分量**之前**被折叠掉（spec §4.1 O4-F17）
    assert normalize_abs_path("/Volumes/staging/") == "/Volumes/staging"
    assert normalize_abs_path("/Volumes/staging///") == "/Volumes/staging"


def test_normalize_collapses_duplicate_slashes():
    assert normalize_abs_path("//Volumes///QMT_Export//x") == "/Volumes/QMT_Export/x"


def test_normalize_rejects_relative_path():
    with pytest.raises(PathDisciplineError, match="绝对路径"):
        normalize_abs_path("Volumes/staging")


def test_normalize_rejects_dot_and_dotdot_with_distinct_message():
    # 「含 . / ..」与「含符号链接分量」两条提示必须分开（spec §4.1 O4-F17）
    with pytest.raises(PathDisciplineError, match=r"`\.` 或 `\.\.`"):
        normalize_abs_path("/Volumes/../etc")
    with pytest.raises(PathDisciplineError, match=r"`\.` 或 `\.\.`"):
        normalize_abs_path("/Volumes/./staging")


def test_normalize_root_stays_root():
    assert normalize_abs_path("/") == "/"


def test_split_components_root_is_empty_list():
    assert split_components("/") == []
    assert split_components("/a/b/c") == ["a", "b", "c"]


def test_split_rel_rejects_absolute_empty_dot_dotdot():
    assert _split_rel("a/b.csv") == ["a", "b.csv"]
    with pytest.raises(PathDisciplineError, match="相对路径"):
        _split_rel("/a/b.csv")
    for bad in ("a//b", "a/./b", "a/../b", ""):
        with pytest.raises(PathDisciplineError):
            _split_rel(bad)
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: FAIL —— `ModuleNotFoundError: No module named 'qmt_fsroot'`

- [ ] **Step 3: 写最小实现**

创建 `backend/qmt_fsroot.py`：

```python
# backend/qmt_fsroot.py
"""文件系统信任边界地基（`--source` / `--dest` / `--output` 三个目录共用）。

Spec: docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md §4.1
      + §4.5 的「锁」与「耐久提交协议」两小节。
切片: docs/superpowers/specs/2026-08-21-qmt-plan4b-slice-map.md S1。

本模块**不认识**「staging」「output」「source」——它只提供受纪律约束的原语，
标记文件名、自指字段名、锁文件名全部由调用方参数化。
`--dest` 与 `--output` 的创建方式**同规格**，差异只有 `EEXIST` 那一档（R91-F2），
而那一档由调用方决定，本模块不替它们决定。
"""
from __future__ import annotations
import errno as _errno


class PathDisciplineError(ValueError):
    """路径字符串本身不合规：相对/绝对方向不对、或含 `.` / `..` / 空分量。"""


class PathEscapeError(Exception):
    """逐段无跟随时撞到**非目录分量**（符号链接或普通文件，本平台不可区分）。

    携带 manifest `fetch_fatal_error` 需要的三个字段（spec §4.5 要求四字段
    `{kind, relative_path, component, errno}`）；`kind` 由调用方按源侧/staging 侧补上。
    """

    def __init__(self, *, relative_path: str, component: str, errno: int):
        self.relative_path = relative_path
        self.component = component
        self.errno = errno
        code = _errno.errorcode.get(errno, str(errno))
        # ⚠️ 不得声称「这是符号链接」：ENOTDIR 与「这里放了个普通文件」不可区分（O4-F12）
        super().__init__(
            f"路径 {relative_path!r} 的分量 {component!r} 不是一个普通目录（{code}）："
            f"它可能是符号链接，也可能是个文件——两者在本平台给出同一个错误码。"
            f"本工具不替你解析符号链接，请改传完全解析后的绝对路径。"
        )


class DirectoryExistsError(Exception):
    """首次使用时目标路径已存在（`mkdirat` 撞 `EEXIST`）。

    **只证明目录存在，不证明里面有什么**——调用方须按各自规格处置（R91-F2）。
    """


class LockUnavailableError(Exception):
    """锁被另一个**活着的**进程持有（`flock` 取不到）。锁文件残留不算被持有（R48-F2）。"""


class LockDisciplineError(Exception):
    """锁文件不是普通文件（符号链接或其它类型）——拒绝启动，一个字节都不写（R72-F2）。"""


class MarkerInvalidError(Exception):
    """归属标记不存在 / 非法 JSON / 字段不符。"""


def normalize_abs_path(raw: str) -> str:
    """入口处的**纯字符串**规范化：去尾斜杠、折叠重复 `/`。**绝不 `realpath()`**（O4-F17）。

    尾斜杠必须在检查空分量**之前**折叠掉：shell 目录补全默认补出尾斜杠，
    `--dest /Volumes/staging/` 是操作者最常见的输入，而本项目的操作者不是程序员。
    「含 `.` / `..`」与「含符号链接分量」两条提示必须分开——后者由逐段 open 时抛
    `PathEscapeError` 给出。
    """
    if not raw.startswith("/"):
        raise PathDisciplineError(f"必须是绝对路径（以 / 开头），收到 {raw!r}")
    parts = [p for p in raw.split("/") if p != ""]
    if any(p in (".", "..") for p in parts):
        raise PathDisciplineError(
            f"路径不得含 `.` 或 `..` 分量，收到 {raw!r}"
            f"（本工具不做路径解析——请传一条已经展开好的绝对路径）"
        )
    return "/" + "/".join(parts)


def split_components(path: str) -> list[str]:
    """规范化后的绝对路径 → 分量列表。`/` 得 `[]`。"""
    return [p for p in normalize_abs_path(path).split("/") if p != ""]


def _split_rel(relpath: str) -> list[str]:
    """相对路径 → 分量。与 `open_root` **同一套分量规则**（O4-F14 ①）：
    拒绝绝对路径 / 空分量 / `.` / `..`。

    相对路径是本工具内部构造的（不是操作者敲的），故这里**不**做尾斜杠宽容——
    出现空分量就是构造方的 bug，应当立刻炸出来。
    """
    if relpath.startswith("/"):
        raise PathDisciplineError(f"必须是相对路径，收到 {relpath!r}")
    parts = relpath.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise PathDisciplineError(
            f"相对路径不得含空分量 / `.` / `..`，收到 {relpath!r}"
        )
    return parts
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 9 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): 路径分量规则与异常族 —— 尾斜杠宽容、拒 . 与 ..、逃逸错误带四字段"
```

---

### Task 2: `open_root` —— 从 `/` 逐分量无跟随钉住一个既存目录

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: Task 1 的 `split_components` / `PathEscapeError` / `PathDisciplineError`
- Produces:
  - `open_root(abs_path: str, *, create_leaf: bool = False) -> int` —— 本 Task 只实现 `create_leaf=False` 一半
  - `_raise_walk_error(relative_path: str, component: str, exc: OSError) -> NoReturn`

- [ ] **Step 1: 写失败的测试**

追加到 `backend/tests/test_qmt_fsroot.py`：

```python
import errno
import os
from pathlib import Path
from qmt_fsroot import PathEscapeError, open_root


def test_open_root_pins_existing_dir(tmp_path: Path):
    d = tmp_path / "a" / "b"
    d.mkdir(parents=True)
    fd = open_root(str(d))
    try:
        assert os.fstat(fd).st_ino == d.stat().st_ino
    finally:
        os.close(fd)


def test_open_root_rejects_symlinked_intermediate_component(tmp_path: Path):
    # `O_NOFOLLOW` 只保护最后一段——中间分量被换成符号链接时，
    # 裸 os.open 会把 pin 钉在**另一棵树**上（spec §4.1 R75-F2）
    real = tmp_path / "real"; (real / "leaf").mkdir(parents=True)
    (tmp_path / "link").symlink_to(real)
    with pytest.raises(PathEscapeError) as ei:
        open_root(str(tmp_path / "link" / "leaf"))
    assert ei.value.component == "link"
    # 本机实测：目录分量是符号链接得 ENOTDIR，**不是** ELOOP（O4-F12）
    assert ei.value.errno == errno.ENOTDIR


def test_open_root_escape_message_does_not_claim_symlink(tmp_path: Path):
    # ENOTDIR 与「这里放了个普通文件」不可区分，消息不得声称是符号链接（O4-F12）
    (tmp_path / "notadir").write_text("x")
    with pytest.raises(PathEscapeError) as ei:
        open_root(str(tmp_path / "notadir" / "leaf"))
    assert "可能是符号链接，也可能是个文件" in str(ei.value)
    assert ei.value.component == "notadir"


def test_open_root_missing_component_is_plain_filenotfound(tmp_path: Path):
    # 「不存在」不是「逃逸」——S5 的 CLI 要能把它翻译成「请先 mount_smbfs」
    with pytest.raises(FileNotFoundError):
        open_root(str(tmp_path / "nope"))


def test_open_root_tolerates_trailing_slash(tmp_path: Path):
    d = tmp_path / "a"; d.mkdir()
    fd = open_root(str(d) + "/")
    try:
        assert os.fstat(fd).st_ino == d.stat().st_ino
    finally:
        os.close(fd)
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k open_root`
Expected: FAIL —— `ImportError: cannot import name 'open_root'`

- [ ] **Step 3: 写最小实现**

在 `qmt_fsroot.py` 顶部补 `import os`，并追加：

```python
def _raise_walk_error(relative_path: str, component: str, exc: OSError):
    """逐段走时的错误分流：只有 `ELOOP` / `ENOTDIR` 算**逃逸**，其余原样上抛。

    `ENOENT` 尤其不能算逃逸——「路径不存在」与「路径被换成了符号链接」是两件事，
    前者是操作者忘了挂载（spec §5 要求提示 `mount_smbfs`），后者是信任边界被绕过。
    """
    if exc.errno in (_errno.ELOOP, _errno.ENOTDIR):
        raise PathEscapeError(
            relative_path=relative_path, component=component, errno=exc.errno
        ) from exc
    raise exc


def open_root(abs_path: str, *, create_leaf: bool = False) -> int:
    """从 `/` 起**逐分量** `O_DIRECTORY|O_NOFOLLOW` 打开，返回叶子目录的 fd（调用方全程持有）。

    `O_NOFOLLOW` **只保护最后一段**——`/a/b/out` 里 `a`、`b` 若是符号链接（或在 pin 之前
    被换成符号链接），内核照样跟随，于是被钉住的是**另一棵树**的 inode，此后所有 `*at`
    纪律都忠实地作用在**错的目录**上：报告、zip、staging CSV 全部写进去，而工具坚信
    信任边界已经闭合。**pin 本身是这套边界的起点，起点被绕过则其后一切纪律归零**（R75-F2）。

    **不做 `realpath()`**——那正是「跟随」。
    """
    comps = split_components(abs_path)
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for d in comps:
            try:
                nxt = os.open(
                    d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
                )
            except OSError as e:
                _raise_walk_error(abs_path, d, e)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 14 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): open_root 逐段无跟随钉住根目录 —— 起点被绕过则其后一切纪律归零"
```

---

### Task 3: `open_root(create_leaf=True)` —— `mkdirat` 独占创建 + 父目录耐久

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: Task 2 的 `open_root`
- Produces: `open_root(..., create_leaf=True)` 分支；撞已存在时抛 `DirectoryExistsError`

- [ ] **Step 1: 写失败的测试**

```python
from qmt_fsroot import DirectoryExistsError, PathDisciplineError


def test_open_root_create_leaf_creates_with_0700(tmp_path: Path):
    target = tmp_path / "dest"
    fd = open_root(str(target), create_leaf=True)
    try:
        assert target.is_dir()
        assert (target.stat().st_mode & 0o777) == 0o700
        assert os.fstat(fd).st_ino == target.stat().st_ino
    finally:
        os.close(fd)


def test_open_root_create_leaf_is_exclusive(tmp_path: Path):
    # mkdir 是**唯一可移植的目录级独占创建原语**；已存在即 EEXIST。
    # 绝不能用 os.rename 做「不覆盖发布」——POSIX 的 rename 在目标是**空目录**时
    # 会把目标**替换**掉，预建或并发抢建的空目录会被静默删除并认领（R64-F1）
    target = tmp_path / "dest"; target.mkdir()
    with pytest.raises(DirectoryExistsError):
        open_root(str(target), create_leaf=True)


def test_open_root_create_leaf_exclusive_even_when_target_nonempty(tmp_path: Path):
    target = tmp_path / "dest"; target.mkdir(); (target / "x").write_text("y")
    with pytest.raises(DirectoryExistsError):
        open_root(str(target), create_leaf=True)
    assert (target / "x").read_text() == "y"   # 一个字节都没动


def test_open_root_create_leaf_rejects_symlinked_parent(tmp_path: Path):
    real = tmp_path / "real"; real.mkdir()
    (tmp_path / "link").symlink_to(real)
    with pytest.raises(PathEscapeError):
        open_root(str(tmp_path / "link" / "dest"), create_leaf=True)
    assert not (real / "dest").exists()        # 没在别人的树里造目录


def test_open_root_create_leaf_rejects_root(tmp_path: Path):
    with pytest.raises(PathDisciplineError, match="至少一个分量"):
        open_root("/", create_leaf=True)
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k create_leaf`
Expected: FAIL —— `create_leaf=True` 目前与 `False` 走同一条路，`test_open_root_create_leaf_creates_with_0700` 抛 `FileNotFoundError`

- [ ] **Step 3: 写实现**

把 `open_root` 的函数体替换为：

```python
def open_root(abs_path: str, *, create_leaf: bool = False) -> int:
    """从 `/` 起**逐分量** `O_DIRECTORY|O_NOFOLLOW` 打开，返回叶子目录的 fd（调用方全程持有）。

    `O_NOFOLLOW` **只保护最后一段**——`/a/b/out` 里 `a`、`b` 若是符号链接（或在 pin 之前
    被换成符号链接），内核照样跟随，于是被钉住的是**另一棵树**的 inode，此后所有 `*at`
    纪律都忠实地作用在**错的目录**上。**pin 本身是这套边界的起点，起点被绕过则
    其后一切纪律归零**（R75-F2）。**不做 `realpath()`**——那正是「跟随」。

    `create_leaf=True`（首次使用/认领）：逐段走到**父目录**后用 `os.mkdir(dir_fd=父fd)`
    **独占创建**叶子——`mkdir` 是**唯一可移植的目录级排他原语**，已存在即 `EEXIST`；
    而逐段走保证「独占创建」发生在**验过的那个父 inode** 里（R75-F2）。
    创建成功后 `fsync` 父目录（耐久提交协议：`mkdir` 改的是目录项，
    而目录项的持久化不由文件的 `fsync` 保证，R45-F2）。

    ⚠️ **绝不用 `os.rename` 做「不覆盖发布」**：POSIX 的 `rename(2)` 在「源是目录、
    目标是**空目录**」时**会把目标替换掉**（macOS 同此），于是一个预先建好的空目录
    会被静默删除并认领（R64-F1）。
    """
    comps = split_components(abs_path)
    if create_leaf and not comps:
        raise PathDisciplineError("create_leaf 需要至少一个分量，不能对 `/` 用")
    dirs = comps[:-1] if create_leaf else comps
    leaf = comps[-1] if create_leaf else None
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for d in dirs:
            try:
                nxt = os.open(
                    d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
                )
            except OSError as e:
                _raise_walk_error(abs_path, d, e)
            os.close(fd)
            fd = nxt
        if create_leaf:
            try:
                os.mkdir(leaf, 0o700, dir_fd=fd)
            except FileExistsError as e:
                raise DirectoryExistsError(
                    f"路径已存在：{abs_path}。"
                    f"`EEXIST` 只证明**目录**存在，不证明它属于本工具——"
                    f"处置由调用方按各自规格决定（R91-F2）。"
                ) from e
            try:
                nxt = os.open(
                    leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
                )
            except OSError as e:
                _raise_walk_error(abs_path, leaf, e)
            os.fsync(fd)          # 父目录耐久（R45-F2）
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 19 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): open_root(create_leaf) 用 mkdirat 独占创建 —— rename 在目标是空目录时会替换掉它"
```

---

### Task 4: `open_under` —— 根之下的逐段无跟随打开器

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: Task 1 的 `_split_rel`、Task 2 的 `_raise_walk_error`
- Produces: `open_under(root_fd: int, relpath: str, *, flags: int, mode: int = 0o600, create_dirs: bool = False) -> int`

- [ ] **Step 1: 写失败的测试**

```python
from qmt_fsroot import open_under


def _read_fd(fd: int) -> bytes:
    with os.fdopen(os.dup(fd), "rb") as f:
        return f.read()


def test_open_under_reads_through_nested_dirs(tmp_path: Path):
    (tmp_path / "a" / "b").mkdir(parents=True)
    (tmp_path / "a" / "b" / "c.csv").write_bytes(b"hello")
    root = open_root(str(tmp_path))
    try:
        fd = open_under(root, "a/b/c.csv", flags=os.O_RDONLY)
        try:
            assert _read_fd(fd) == b"hello"
        finally:
            os.close(fd)
    finally:
        os.close(root)


def test_open_under_rejects_symlinked_intermediate_component(tmp_path: Path):
    # `dir_fd=` 只钉住**起点**、`O_NOFOLLOW` 只管**最后一段**：中间分量被换成外指
    # 链接时，fetch 会把 CSV 写到 staging 树**外面**，pilot 又会从树外读，
    # 而 staging_intact 的哈希对此**完全透明**（它读的是同一条被换过的路径，R74-F2）
    outside = tmp_path / "outside"; outside.mkdir()
    inside = tmp_path / "root"; inside.mkdir()
    (inside / "sub").symlink_to(outside)
    root = open_root(str(inside))
    try:
        with pytest.raises(PathEscapeError) as ei:
            open_under(root, "sub/x.csv", flags=os.O_RDONLY)
        assert ei.value.component == "sub"
        assert ei.value.errno == errno.ENOTDIR
    finally:
        os.close(root)


def test_open_under_leaf_symlink_gets_eloop(tmp_path: Path):
    # 叶子是**文件**符号链接、且不带 O_DIRECTORY → ELOOP（本机实测，O4-F12）
    (tmp_path / "real.csv").write_text("x")
    (tmp_path / "link.csv").symlink_to(tmp_path / "real.csv")
    root = open_root(str(tmp_path))
    try:
        with pytest.raises(PathEscapeError) as ei:
            open_under(root, "link.csv", flags=os.O_RDONLY)
        assert ei.value.errno == errno.ELOOP
    finally:
        os.close(root)


def test_open_under_create_dirs_makes_0700_and_is_idempotent(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        fd = open_under(root, "x/y/z.csv",
                        flags=os.O_CREAT | os.O_WRONLY, create_dirs=True)
        os.close(fd)
        assert (tmp_path / "x" / "y").is_dir()
        assert ((tmp_path / "x").stat().st_mode & 0o777) == 0o700
        # 第二次不得因目录已存在而失败
        fd = open_under(root, "x/y/z2.csv",
                        flags=os.O_CREAT | os.O_WRONLY, create_dirs=True)
        os.close(fd)
    finally:
        os.close(root)


def test_open_under_missing_leaf_is_plain_filenotfound(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        with pytest.raises(FileNotFoundError):
            open_under(root, "nope.json", flags=os.O_RDONLY)
    finally:
        os.close(root)


def test_open_under_rejects_bad_components(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        for bad in ("/abs/x", "a/../b", "a/./b", "a//b"):
            with pytest.raises(PathDisciplineError):
                open_under(root, bad, flags=os.O_RDONLY)
    finally:
        os.close(root)


def test_open_under_does_not_leak_intermediate_fds(tmp_path: Path):
    # 中间 fd 必须在 finally 里关掉（O4-F14 ②）：每次泄漏几个 fd 会让
    # 「staging 已被 rename 掉」这类分叉检查拿着陈旧 fd 继续成立
    (tmp_path / "a" / "b").mkdir(parents=True)
    (tmp_path / "a" / "b" / "c.csv").write_text("x")
    root = open_root(str(tmp_path))
    try:
        before = len(os.listdir(f"/dev/fd"))
        for _ in range(50):
            os.close(open_under(root, "a/b/c.csv", flags=os.O_RDONLY))
        after = len(os.listdir(f"/dev/fd"))
        assert after - before <= 2      # 允许 listdir 自身的抖动
    finally:
        os.close(root)
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k open_under`
Expected: FAIL —— `ImportError: cannot import name 'open_under'`

- [ ] **Step 3: 写实现**

```python
def open_under(root_fd: int, relpath: str, *, flags: int, mode: int = 0o600,
               create_dirs: bool = False) -> int:
    """相对 `root_fd` **逐分量**无跟随打开，返回叶子的 fd（调用方负责关）。

    **`dir_fd=` 只保证起点、`O_NOFOLLOW` 只作用于最后一段**——中间的 `a` 或 `b`
    是符号链接时，内核照样跟随。于是一棵被复用的 staging 里，只要
    `1分钟K线_前复权` 被换成指向 staging 之外的链接，`qmt_fetch` 就会把 `.part`/CSV
    **写到 staging 树外面**，随后 pilot 又会**从树外面读**，而全套 `staging_intact`
    哈希校验查的是「同一条路径读回来的字节」——**换过的分量对它完全透明**（R74-F2）。

    `create_dirs=True` 只创建本工具自己的目录（`0o700`），**且只在 `mkdir` 真的成功时**
    才 `fsync` 其父目录（O2-F3）——子目录创建也是一次命名空间改动，漏掉会让
    manifest 已提交「文件在该目录下」而**目录项没落地**：重启后记录在、文件与目录都不在，
    既不是 `untracked_target_file`（那要求文件存在）也回收不了（R84-F2）。

    只有 `ELOOP` / `ENOTDIR` 算逃逸；`ENOENT` 原样上抛为 `FileNotFoundError`
    （「不存在」与「被换掉」是两件事）。
    """
    *dirs, leaf = _split_rel(relpath)
    cur = root_fd
    opened: list[int] = []
    try:
        for d in dirs:
            if create_dirs:
                try:
                    os.mkdir(d, 0o700, dir_fd=cur)
                except FileExistsError:
                    pass
                else:
                    os.fsync(cur)      # 新建成功才 fsync 父目录（O2-F3 / R84-F2）
            try:
                nxt = os.open(
                    d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur
                )
            except OSError as e:
                _raise_walk_error(relpath, d, e)
            opened.append(nxt)
            cur = nxt
        try:
            return os.open(leaf, flags | os.O_NOFOLLOW, mode, dir_fd=cur)
        except OSError as e:
            _raise_walk_error(relpath, leaf, e)
    finally:
        for fd in opened:
            os.close(fd)
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 26 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): open_under 逐段无跟随 —— 中间分量被换掉时哈希校验完全透明"
```

---

### Task 5: `parent_fd_under` —— 命名空间动作的逐段无跟随原语

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: Task 1 的 `_split_rel`、Task 2 的 `_raise_walk_error`
- Produces: `parent_fd_under(root_fd: int, relpath: str) -> tuple[int, str]`（返回的 `parent_fd` **归调用方**）

- [ ] **Step 1: 写失败的测试**

```python
from qmt_fsroot import parent_fd_under


def test_parent_fd_under_returns_parent_and_leaf(tmp_path: Path):
    (tmp_path / "a" / "b").mkdir(parents=True)
    root = open_root(str(tmp_path))
    try:
        pfd, leaf = parent_fd_under(root, "a/b/c.csv")
        try:
            assert leaf == "c.csv"
            assert os.fstat(pfd).st_ino == (tmp_path / "a" / "b").stat().st_ino
        finally:
            os.close(pfd)
    finally:
        os.close(root)


def test_parent_fd_under_single_component_dups_root(tmp_path: Path):
    # 单分量时父目录**就是** root——必须返回 dup，否则调用方一关就把 root_fd 关掉了
    root = open_root(str(tmp_path))
    try:
        pfd, leaf = parent_fd_under(root, "manifest.json")
        assert leaf == "manifest.json"
        assert pfd != root
        os.close(pfd)
        os.fstat(root)                  # root 仍可用，没被连带关掉
    finally:
        os.close(root)


def test_parent_fd_under_supports_replace_and_unlink_and_fsync(tmp_path: Path):
    # 按股事务最关键的三个动作都要「父目录 fd + basename」（O2-F4）
    (tmp_path / "d").mkdir()
    (tmp_path / "d" / "x.csv.part").write_text("data")
    root = open_root(str(tmp_path))
    try:
        pfd, leaf = parent_fd_under(root, "d/x.csv")
        try:
            # ⚠️ 直接传 src_dir_fd/dst_dir_fd，不做 os.supports_dir_fd 能力探测：
            # 本机 `os.replace in os.supports_dir_fd` 为 False 而实际能跑通，
            # 写探测的实现会恰好退回被明令禁止的按路径改名（O4-F14）
            os.replace("x.csv.part", leaf, src_dir_fd=pfd, dst_dir_fd=pfd)
            assert (tmp_path / "d" / "x.csv").read_text() == "data"
            os.fsync(pfd)
            os.unlink(leaf, dir_fd=pfd)
            assert not (tmp_path / "d" / "x.csv").exists()
        finally:
            os.close(pfd)
    finally:
        os.close(root)


def test_parent_fd_under_rejects_symlinked_component(tmp_path: Path):
    # `.inflight.json` 的形状校验用 resolve()，而 **resolve() 会跟随符号链接**——
    # 逐段无跟随是最后一道防线，否则一条**破坏性恢复路径**会删到边界之外（O4-F14 ①）
    outside = tmp_path / "outside"; outside.mkdir()
    (outside / "victim.csv").write_text("someone elses data")
    inside = tmp_path / "root"; inside.mkdir()
    (inside / "sub").symlink_to(outside)
    root = open_root(str(inside))
    try:
        with pytest.raises(PathEscapeError) as ei:
            parent_fd_under(root, "sub/victim.csv")
        assert ei.value.component == "sub"
    finally:
        os.close(root)
    assert (outside / "victim.csv").read_text() == "someone elses data"


def test_parent_fd_under_rejects_bad_components(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        for bad in ("/abs/x", "a/../b", "a/./b", "a//b", ""):
            with pytest.raises(PathDisciplineError):
                parent_fd_under(root, bad)
    finally:
        os.close(root)


def test_parent_fd_under_does_not_leak_intermediate_fds(tmp_path: Path):
    (tmp_path / "a" / "b").mkdir(parents=True)
    root = open_root(str(tmp_path))
    try:
        before = len(os.listdir("/dev/fd"))
        for _ in range(50):
            pfd, _leaf = parent_fd_under(root, "a/b/c.csv")
            os.close(pfd)
        after = len(os.listdir("/dev/fd"))
        assert after - before <= 2
    finally:
        os.close(root)
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k parent_fd`
Expected: FAIL —— `ImportError: cannot import name 'parent_fd_under'`

- [ ] **Step 3: 写实现**

```python
def parent_fd_under(root_fd: int, relpath: str) -> tuple[int, str]:
    """逐分量无跟随走到 `relpath` 的**父目录**，返回 `(parent_fd, leaf)`。

    **为什么需要它**：`open_under` 只能 `open()`，而按股事务里最关键的三个动作——
    `os.replace(.part → final)`、回滚 `unlink`、对子目录 `fsync`——都要
    **父目录 fd + basename**（O2-F4）。实施者最自然的写法 `os.unlink(str(staging / rel))`
    会让 `.inflight.json` 的形状校验（只要求 `resolve()` 后落在 staging 之内，
    而 **`resolve()` 会跟随符号链接**）放行一条**破坏性恢复路径**删到边界之外。

    与 `open_under` 同规格三条（O4-F14）：
      ① 分量规则相同（拒空分量 / `.` / `..`，逐段 `O_DIRECTORY|O_NOFOLLOW`）；
      ② 中间 fd 在 `finally` 里关掉，**返回的 `parent_fd` 归调用方、用完必须关**
         ——每股泄漏 3~4 个 fd 会让「staging 已被 rename 掉」这类分叉检查
         拿着陈旧 fd 继续成立；
      ③ 恢复路径上撞逃逸的处置由调用方决定（S4：不删任何文件、保留 `.inflight.json`、
         记 `stopped_reason: staging_path_escape` 后 rc≠0）。

    ⚠️ 单分量时父目录**就是** `root_fd`，故一律返回 `os.dup(root_fd)`——
    否则调用方一关就把根 fd 连带关掉了。
    """
    *dirs, leaf = _split_rel(relpath)
    cur = root_fd
    opened: list[int] = []
    try:
        for d in dirs:
            try:
                nxt = os.open(
                    d, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=cur
                )
            except OSError as e:
                _raise_walk_error(relpath, d, e)
            opened.append(nxt)
            cur = nxt
        return os.dup(cur), leaf
    finally:
        for fd in opened:
            os.close(fd)
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 32 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): parent_fd_under —— replace/unlink/fsync 三类命名空间动作的无跟随原语"
```

---

### Task 6: 耐久提交原语（`fsync_dir` / `full_fsync`）

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: 无
- Produces: `fsync_dir(dir_fd: int) -> None`、`full_fsync(fd: int) -> None`

- [ ] **Step 1: 写失败的测试**

```python
import fcntl
from qmt_fsroot import fsync_dir, full_fsync


def test_fsync_dir_accepts_directory_fd(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        fsync_dir(root)          # 不抛即可（APFS 上 fsync(dirfd) 返回 0）
    finally:
        os.close(root)


def test_full_fsync_uses_F_FULLFSYNC_not_plain_fsync(tmp_path: Path, monkeypatch):
    # macOS `man 2 fsync` 明写 fsync **既不保证断电耐久、也不保证跨设备写序**
    # （"This is not a theoretical edge case."）。断电在威胁模型之内（O4-F11），
    # 故 manifest 提交与顺序屏障两处必须真的走 F_FULLFSYNC——
    # 用 fsync 写出来的「目录项丢失注入测试」绿灯**证明不了任何东西**。
    calls = []
    real_fcntl = fcntl.fcntl
    monkeypatch.setattr(fcntl, "fcntl",
                        lambda fd, cmd, *a: (calls.append(cmd), real_fcntl(fd, cmd, *a))[1])
    p = tmp_path / "f"; p.write_text("x")
    fd = os.open(str(p), os.O_RDONLY)
    try:
        full_fsync(fd)
    finally:
        os.close(fd)
    assert calls == [fcntl.F_FULLFSYNC]


def test_full_fsync_command_constant_exists():
    assert hasattr(fcntl, "F_FULLFSYNC")     # 本机实测值 51
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k fsync`
Expected: FAIL —— `ImportError: cannot import name 'fsync_dir'`

- [ ] **Step 3: 写实现**

在 `qmt_fsroot.py` 顶部补 `import fcntl`，并追加：

```python
def fsync_dir(dir_fd: int) -> None:
    """命名空间改动（`os.replace` / `os.mkdir` / `unlink`）之后 `fsync` 其所在目录。

    **目录项的持久化不由文件的 `fsync` 保证**：断电后文件系统完全可能只持久化了
    rename、没持久化 manifest 的 replace（或反过来）——于是重启后 staging 里躺着两个
    final 文件而 manifest 无记录，正是按股事务要消灭的那个状态（R45-F2）。
    「原子」（`os.replace` 不会看到半截）与「耐久」（崩溃后仍在）是两件事。
    """
    os.fsync(dir_fd)


def full_fsync(fd: int) -> None:
    """`fcntl(fd, F_FULLFSYNC)` —— 本平台唯一把字节真正推到盘上的调用。

    macOS `man 2 fsync` 原文：「if the drive loses power or the OS crashes, the
    application may find that only some or none of their data was written.
    The disk drive may also **re-order** the data … **This is not a theoretical
    edge case.**」——即 `fsync` 在本平台上**既不保证断电耐久、也不保证跨设备写序**。

    **定案：断电在威胁模型之内**（O4-F11）。故 **manifest 提交**与
    **回滚时那道顺序屏障**两处用本函数（每股 1~2 次，400 股量级完全可接受），
    其余落地点保留 `fsync_dir` / `os.fsync`。
    （实测：`fsync(dirfd)` 在本机 APFS 上返回 0，**不会有任何报错提示这层保证并不存在**。）
    """
    fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 35 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): 耐久提交原语 —— 断电在威胁模型内，manifest 提交必须走 F_FULLFSYNC"
```

---

### Task 7: `acquire_lock` —— 内核持有的生命周期锁

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: Task 4 的 `open_under`、Task 1 的 `LockUnavailableError` / `LockDisciplineError`
- Produces: `acquire_lock(dir_fd: int, lock_name: str, *, tool: str) -> int`（返回锁 fd，调用方全程持有）

- [ ] **Step 1: 写失败的测试**

```python
import json
import subprocess
import sys
from qmt_fsroot import LockDisciplineError, LockUnavailableError, acquire_lock


def test_acquire_lock_succeeds_and_writes_human_readable_holder(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        lk = acquire_lock(root, ".staging.lock", tool="qmt_fetch")
        try:
            info = json.loads((tmp_path / ".staging.lock").read_text())
            # 持有者信息**仅供人读诊断，不参与判定**（R48-F2）
            assert info["tool"] == "qmt_fetch"
            assert info["pid"] == os.getpid()
            assert "hostname" in info
        finally:
            os.close(lk)
    finally:
        os.close(root)


def test_acquire_lock_is_exclusive_across_processes(tmp_path: Path):
    root = open_root(str(tmp_path))
    lk = acquire_lock(root, ".staging.lock", tool="qmt_fetch")
    try:
        code = (
            "import fcntl,os,sys;"
            f"fd=os.open({str(tmp_path / '.staging.lock')!r}, os.O_RDWR);"
            "sys.exit(0 if _try(fd) else 1)"
        )
        script = (
            "import fcntl, os, sys\n"
            f"fd = os.open({str(tmp_path / '.staging.lock')!r}, os.O_RDWR)\n"
            "try:\n"
            "    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
            "    sys.exit(0)\n"
            "except OSError:\n"
            "    sys.exit(3)\n"
        )
        r = subprocess.run([sys.executable, "-c", script])
        assert r.returncode == 3          # 另一个**进程**确实拿不到
    finally:
        os.close(lk)
        os.close(root)


def test_lock_released_when_holder_process_dies(tmp_path: Path):
    # 锁由**内核**持有，进程无论正常退出还是被杀都自动释放；
    # 存在性锁（O_CREAT|O_EXCL）会与「执行阶段中途崩溃」叠成**死锁**：
    # 每次重跑都卡在取锁那一步，只能人工删锁（R48-F2 / §9-5n）
    script = (
        "import fcntl, os\n"
        f"fd = os.open({str(tmp_path / '.staging.lock')!r}, os.O_CREAT | os.O_RDWR, 0o600)\n"
        "fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
        "os.kill(os.getpid(), 9)\n"
    )
    subprocess.run([sys.executable, "-c", script])
    assert (tmp_path / ".staging.lock").exists()     # 锁文件**残留**了
    root = open_root(str(tmp_path))
    try:
        lk = acquire_lock(root, ".staging.lock", tool="qmt_fetch")   # 照样取得
        os.close(lk)
    finally:
        os.close(root)


def test_acquire_lock_refuses_symlinked_lock_file(tmp_path: Path):
    # 锁文件在直觉里像「临时协调物」，恰恰因此被漏掉；
    # 凡本工具会写入的路径，无论承载数据还是协调状态，都过同一套符号链接纪律（R72-F2）
    outside = tmp_path / "outside.lock"; outside.write_text("")
    inside = tmp_path / "root"; inside.mkdir()
    (inside / ".staging.lock").symlink_to(outside)
    root = open_root(str(inside))
    try:
        with pytest.raises(LockDisciplineError):
            acquire_lock(root, ".staging.lock", tool="qmt_fetch")
    finally:
        os.close(root)
    assert outside.read_text() == ""       # 一个字节都没写进去


def test_acquire_lock_refuses_non_regular_lock_file(tmp_path: Path):
    (tmp_path / ".staging.lock").mkdir()
    root = open_root(str(tmp_path))
    try:
        with pytest.raises(LockDisciplineError):
            acquire_lock(root, ".staging.lock", tool="qmt_fetch")
    finally:
        os.close(root)


def test_acquire_lock_raises_when_held(tmp_path: Path):
    root = open_root(str(tmp_path))
    lk = acquire_lock(root, ".staging.lock", tool="qmt_fetch")
    root2 = open_root(str(tmp_path))
    try:
        with pytest.raises(LockUnavailableError):
            acquire_lock(root2, ".staging.lock", tool="qmt_fetch")
    finally:
        os.close(lk); os.close(root); os.close(root2)
```

> ⚠️ 删掉上面 `test_acquire_lock_is_exclusive_across_processes` 里那段没用到的 `code = (...)`
> 变量——它是草稿残留，实现时只保留 `script`。

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k lock`
Expected: FAIL —— `ImportError: cannot import name 'acquire_lock'`

- [ ] **Step 3: 写实现**

在 `qmt_fsroot.py` 顶部补 `import json`、`import socket`、`import stat`，并追加：

```python
def acquire_lock(dir_fd: int, lock_name: str, *, tool: str) -> int:
    """取得目录生命周期锁，返回锁 fd（调用方全程持有到最后一次提交之后）。

    **锁由内核持有，进程无论正常退出还是被杀都自动释放**（R48-F2）。
    **锁文件残留不构成拒绝**——唯一判据是 `flock` 能否取得，也**不得提示人工删锁**：
    存在性锁（`O_CREAT|O_EXCL`）的释放靠「进程记得删文件」，而 `kill -9` / 断电时
    它删不掉，会与「执行阶段中途崩溃」叠成**死锁**。

    序列：`openat(O_CREAT|O_RDWR|O_NOFOLLOW, 0o600)` → `fstat` 确认**普通文件**
    → `flock(LOCK_EX|LOCK_NB)` → 写持有者信息。
    `ELOOP` 或类型不符 → `LockDisciplineError`（拒绝启动，**一个字节都不写**，R72-F2）。

    持有者信息（pid / 主机名 / 工具名）**仅供人读诊断，不参与任何判定**。
    锁文件本身**不进耐久提交协议的闭合清单**（显式豁免：它存在与否不参与判定，
    丢了下次重建即可）。
    """
    try:
        lock_fd = open_under(
            dir_fd, lock_name, flags=os.O_CREAT | os.O_RDWR, mode=0o600
        )
    except PathEscapeError as e:
        raise LockDisciplineError(
            f"锁文件 {lock_name!r} 不是普通文件（{e}）——拒绝启动，一个字节都不写。"
        ) from e
    try:
        if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
            raise LockDisciplineError(
                f"锁文件 {lock_name!r} 存在但不是普通文件——拒绝启动。"
            )
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            raise LockUnavailableError(
                f"{lock_name!r} 正被另一次运行持有，请等待或确认。"
                f"（锁由内核持有、进程死亡即释放，**不需要也不应该手工删锁**）"
            ) from e
        os.ftruncate(lock_fd, 0)
        os.lseek(lock_fd, 0, os.SEEK_SET)
        os.write(lock_fd, json.dumps(
            {"tool": tool, "pid": os.getpid(), "hostname": socket.gethostname()},
            ensure_ascii=False,
        ).encode("utf-8"))
        return lock_fd
    except BaseException:
        os.close(lock_fd)
        raise
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 41 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): acquire_lock 内核持有的生命周期锁 —— 崩溃即释放，残留锁文件不构成拒绝"
```

---

### Task 8: `probe_unclaimed_dir` —— `EEXIST` 且无标记时的三分支探测

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: Task 4 的 `open_under`
- Produces: `probe_unclaimed_dir(dir_fd: int, lock_name: str) -> str`，返回 `"vacuum"` / `"busy"` / `"stale"` 之一

- [ ] **Step 1: 写失败的测试**

```python
from qmt_fsroot import probe_unclaimed_dir


def test_probe_vacuum_when_lock_file_absent(tmp_path: Path):
    # 崩在 mkdir 与建锁文件之间留下的**真空目录**，
    # 也是**唯一 rmdir 能干净成功的一档**（O4-F6）
    root = open_root(str(tmp_path))
    try:
        assert probe_unclaimed_dir(root, ".staging.lock") == "vacuum"
    finally:
        os.close(root)


def test_probe_busy_when_lock_held_by_another_process(tmp_path: Path):
    lockpath = tmp_path / ".staging.lock"
    proc = subprocess.Popen([sys.executable, "-c",
        "import fcntl, os, sys, time\n"
        f"fd = os.open({str(lockpath)!r}, os.O_CREAT | os.O_RDWR, 0o600)\n"
        "fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
        "sys.stdout.write('held'); sys.stdout.flush()\n"
        "time.sleep(30)\n"], stdout=subprocess.PIPE)
    try:
        assert proc.stdout.read(4) == b"held"
        root = open_root(str(tmp_path))
        try:
            # 取不到锁 → 「另一次运行正在认领该目录」，**绝不建议 rmdir**（O2-F9）
            assert probe_unclaimed_dir(root, ".staging.lock") == "busy"
        finally:
            os.close(root)
    finally:
        proc.kill(); proc.wait()


def test_probe_stale_when_lock_file_present_but_free(tmp_path: Path):
    (tmp_path / ".staging.lock").write_text("{}")
    root = open_root(str(tmp_path))
    try:
        assert probe_unclaimed_dir(root, ".staging.lock") == "stale"
    finally:
        os.close(root)


def test_probe_never_creates_the_lock_file(tmp_path: Path):
    # ⚠️ 带 O_CREAT 会在一个**已被证明不属于我们的目录**里造文件——
    # `--dest` 打错成 /Users/me/Documents 时，工具先落下 .staging.lock，
    # 然后建议 rmdir，而 rmdir 恰恰因为我们刚造的这个文件而 ENOTEMPTY，
    # **修复指引自己把自己堵死**；真正的残骸空目录也再 rmdir 不掉（P2-F1）
    root = open_root(str(tmp_path))
    try:
        assert probe_unclaimed_dir(root, ".staging.lock") == "vacuum"
    finally:
        os.close(root)
    assert list(tmp_path.iterdir()) == []          # 目录仍然是空的


def test_probe_rejects_symlinked_lock_file(tmp_path: Path):
    outside = tmp_path / "outside.lock"; outside.write_text("")
    inside = tmp_path / "root"; inside.mkdir()
    (inside / ".staging.lock").symlink_to(outside)
    root = open_root(str(inside))
    try:
        with pytest.raises(LockDisciplineError):
            probe_unclaimed_dir(root, ".staging.lock")
    finally:
        os.close(root)
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k probe`
Expected: FAIL —— `ImportError: cannot import name 'probe_unclaimed_dir'`

- [ ] **Step 3: 写实现**

```python
def probe_unclaimed_dir(dir_fd: int, lock_name: str) -> str:
    """一个**没有合法归属标记**的既存目录，该给操作者什么指引——三分支，一个都不能省。

    探测形态由 P2-F1 写死，**绝不带 `O_CREAT`**：带了会在一个已被证明不属于我们的目录里
    造出锁文件，随后建议的 `rmdir` 恰恰因为这个文件而 `ENOTEMPTY`，
    **修复指引自己把自己堵死**；这直接违反「取锁要写文件，打错字的 `--dest`
    会先在未经证明的目录里落下锁文件」（R65-F1）。

    返回值与调用方必须给出的指引：

    - `"vacuum"` —— 锁文件**不存在**。这是崩在 `mkdir` 与建锁文件之间留下的**真空目录**，
      也是**唯一 `rmdir` 能干净成功的一档**（O4-F6）。调用方须**先复查目录确为空**，
      再给 `rmdir <dir>` 指引。
    - `"busy"` —— `flock` 取不到。报「**另一次运行正在认领该目录，请等待或确认**」，
      **绝不建议 `rmdir`**（O2-F9：那个窗口里至少有一次 openat+flock、一次写、三次
      `fsync`，操作者照做后 A 持有的 fd 仍指向已被 unlink 的 inode，
      此后几百个 CSV 全写进一棵**不可达**的树，而 A 以 rc=0 宣称就绪）。
    - `"stale"` —— `flock` 取得了，才**可能**是残骸。⚠️ 此时目录里**必然有**锁文件
      （正是我们刚打开的那个），**裸 `rmdir` 必撞 `ENOTEMPTY`**（已实测）。
      故指引必须是：先列出目录内容供操作者核对，再给
      「若确认除锁文件外为空：`rm -f <dir>/<lock> && rmdir <dir>`」。

    锁文件是符号链接或非普通文件 → `LockDisciplineError`（R72-F2）。
    """
    try:
        lock_fd = open_under(dir_fd, lock_name, flags=os.O_RDWR)   # ⚠️ 绝不带 O_CREAT
    except FileNotFoundError:
        return "vacuum"
    except PathEscapeError as e:
        raise LockDisciplineError(
            f"锁文件 {lock_name!r} 不是普通文件（{e}）——拒绝启动。"
        ) from e
    try:
        if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
            raise LockDisciplineError(
                f"锁文件 {lock_name!r} 存在但不是普通文件——拒绝启动。"
            )
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return "busy"
        fcntl.flock(lock_fd, fcntl.LOCK_UN)     # 取得后立即释放，不写任何内容
        return "stale"
    finally:
        os.close(lock_fd)
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 46 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): probe_unclaimed_dir 三分支 —— 探测绝不带 O_CREAT，否则修复指引自己堵死自己"
```

---

### Task 9: 归属标记的写与验（参数化，同时表达 `--dest` 与 `--output` 两种规格）

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: Task 4 的 `open_under`、Task 5 的 `parent_fd_under`、Task 6 的 `fsync_dir`
- Produces:
  - `write_owner_marker(dir_fd: int, marker_name: str, payload: dict) -> None`
  - `verify_owner_marker(dir_fd: int, marker_name: str, *, expect_tool: str, self_field: str, self_value: str) -> dict`

- [ ] **Step 1: 写失败的测试**

```python
from qmt_fsroot import MarkerInvalidError, verify_owner_marker, write_owner_marker


def test_write_and_verify_dest_marker(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        write_owner_marker(root, ".staging_owner.json",
                           {"tool": "qmt_fetch", "seed": "s1", "dest": str(tmp_path)})
        got = verify_owner_marker(root, ".staging_owner.json",
                                  expect_tool="qmt_fetch",
                                  self_field="dest", self_value=str(tmp_path))
        assert got["seed"] == "s1"
    finally:
        os.close(root)


def test_same_primitive_expresses_output_marker(tmp_path: Path):
    # 同一套原语必须能表达 --output 的第 1 层（tool + output_dir 自指），
    # 差异只有 EEXIST 那一档（由调用方决定，不在本模块）
    root = open_root(str(tmp_path))
    try:
        write_owner_marker(root, ".pilot_output.json",
                           {"tool": "qmt_pilot", "output_dir": str(tmp_path),
                            "seed": "s1", "export_log_sha256": "a" * 64})
        got = verify_owner_marker(root, ".pilot_output.json",
                                  expect_tool="qmt_pilot",
                                  self_field="output_dir", self_value=str(tmp_path))
        # 第 2 层（seed + export_log_sha256）**必须等到 manifest 校验通过之后**才验，
        # 不在本模块（R31-F1）——这里只把整份内容交回去
        assert got["export_log_sha256"] == "a" * 64
    finally:
        os.close(root)


def test_verify_rejects_wrong_tool(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        write_owner_marker(root, ".staging_owner.json",
                           {"tool": "qmt_pilot", "dest": str(tmp_path)})
        with pytest.raises(MarkerInvalidError, match="tool"):
            verify_owner_marker(root, ".staging_owner.json", expect_tool="qmt_fetch",
                                self_field="dest", self_value=str(tmp_path))
    finally:
        os.close(root)


def test_verify_rejects_marker_moved_wholesale(tmp_path: Path):
    # 自指字段的全部意义：防标记被**整体搬走**到另一个目录还继续生效
    a = tmp_path / "a"; a.mkdir()
    b = tmp_path / "b"; b.mkdir()
    root_a = open_root(str(a))
    try:
        write_owner_marker(root_a, ".staging_owner.json",
                           {"tool": "qmt_fetch", "dest": str(a)})
    finally:
        os.close(root_a)
    import shutil
    shutil.copy(a / ".staging_owner.json", b / ".staging_owner.json")
    root_b = open_root(str(b))
    try:
        with pytest.raises(MarkerInvalidError, match="dest"):
            verify_owner_marker(root_b, ".staging_owner.json", expect_tool="qmt_fetch",
                                self_field="dest", self_value=str(b))
    finally:
        os.close(root_b)


def test_verify_rejects_missing_and_malformed(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        with pytest.raises(MarkerInvalidError):
            verify_owner_marker(root, ".staging_owner.json", expect_tool="qmt_fetch",
                                self_field="dest", self_value=str(tmp_path))
        (tmp_path / ".staging_owner.json").write_text("{not json")
        with pytest.raises(MarkerInvalidError):
            verify_owner_marker(root, ".staging_owner.json", expect_tool="qmt_fetch",
                                self_field="dest", self_value=str(tmp_path))
    finally:
        os.close(root)


def test_write_owner_marker_leaves_no_tmp_behind(tmp_path: Path):
    root = open_root(str(tmp_path))
    try:
        write_owner_marker(root, ".staging_owner.json",
                           {"tool": "qmt_fetch", "dest": str(tmp_path)})
    finally:
        os.close(root)
    assert sorted(p.name for p in tmp_path.iterdir()) == [".staging_owner.json"]


def test_write_owner_marker_refuses_symlink_target(tmp_path: Path):
    outside = tmp_path / "outside.json"; outside.write_text("{}")
    inside = tmp_path / "root"; inside.mkdir()
    (inside / ".staging_owner.json").symlink_to(outside)
    root = open_root(str(inside))
    try:
        # 一个名字对得上的符号链接会让写入**跟出目录**，把归属判定整个绕过去（R13-F2）
        with pytest.raises(PathEscapeError):
            write_owner_marker(root, ".staging_owner.json",
                               {"tool": "qmt_fetch", "dest": str(inside)})
    finally:
        os.close(root)
    assert outside.read_text() == "{}"
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k marker`
Expected: FAIL —— `ImportError: cannot import name 'write_owner_marker'`

- [ ] **Step 3: 写实现**

```python
def write_owner_marker(dir_fd: int, marker_name: str, payload: dict) -> None:
    """原子写归属标记：tmp → `fsync(文件)` → `os.replace` → `fsync(目录)`。

    标记文件与报告一样走「临时文件 + `os.replace`」原子落地（R13-F2）；
    目标是符号链接时 `open_under` 的 `O_NOFOLLOW` 会拒绝——否则一个名字对得上的
    符号链接会让写入**跟出目录**，把归属判定整个绕过去。

    ⚠️ **本函数不管顺序**：调用方必须**先取锁再写标记**（R97-F2 取锁早于发布归属）。
    父目录的 `fsync` 由 `open_root(create_leaf=True)` 在 `mkdir` 之后做掉。
    """
    tmp_name = marker_name + ".tmp"
    fd = open_under(
        dir_fd, tmp_name, flags=os.O_CREAT | os.O_WRONLY | os.O_TRUNC, mode=0o600
    )
    try:
        os.write(fd, json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    # ⚠️ 直接传 dir_fd，不做 os.supports_dir_fd 能力探测（O4-F14）
    os.replace(tmp_name, marker_name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    fsync_dir(dir_fd)


def verify_owner_marker(dir_fd: int, marker_name: str, *, expect_tool: str,
                        self_field: str, self_value: str) -> dict:
    """**第 1 层**归属校验：`tool` 相符 + **自指字段**等于 `self_value`。返回整份标记内容。

    第 1 层**不依赖 manifest，任何时候都能验**。它一旦通过，就确立了
    「**这个目录是本工具的，我有权在里面新增东西**」——但**不足以支撑「作废既有报告」**
    （R31-F1 / R40-F1）。**第 2 层**（`seed` + `export_log_sha256`）**必须等到
    manifest 校验通过之后**才验，**不在本模块**——本函数把整份内容交回给调用方去做。

    自指字段的全部意义是**防标记被整体搬走**：一份从别处拷来的标记，
    `tool` 会对上，只有自指字段对不上。
    """
    try:
        fd = open_under(dir_fd, marker_name, flags=os.O_RDONLY)
    except FileNotFoundError as e:
        raise MarkerInvalidError(f"归属标记 {marker_name!r} 不存在") from e
    try:
        raw = b""
        while chunk := os.read(fd, 65536):
            raw += chunk
    finally:
        os.close(fd)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise MarkerInvalidError(f"归属标记 {marker_name!r} 不是合法 JSON: {e}") from e
    if not isinstance(data, dict):
        raise MarkerInvalidError(f"归属标记 {marker_name!r} 顶层不是对象")
    if data.get("tool") != expect_tool:
        raise MarkerInvalidError(
            f"归属标记 {marker_name!r} 的 tool 为 {data.get('tool')!r}，"
            f"不是 {expect_tool!r}——这个目录不属于本工具"
        )
    if data.get(self_field) != self_value:
        raise MarkerInvalidError(
            f"归属标记 {marker_name!r} 的自指字段 {self_field!r} 为 "
            f"{data.get(self_field)!r}，而当前路径是 {self_value!r}"
            f"——标记可能是从别处整体搬来的"
        )
    return data
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 53 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): 归属标记写/验参数化 —— 自指字段防整体搬走，第 2 层留给调用方"
```

---

### Task 10: `claim_dir` —— 首次使用的完整认领协议

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: Task 3 的 `open_root(create_leaf=True)`、Task 7 的 `acquire_lock`、Task 9 的 `write_owner_marker`
- Produces: `claim_dir(abs_path: str, *, lock_name: str, marker_name: str, marker_payload: dict, tool: str) -> tuple[int, int]`

- [ ] **Step 1: 写失败的测试**

```python
from qmt_fsroot import claim_dir


def test_claim_dir_creates_locks_and_marks(tmp_path: Path):
    target = tmp_path / "dest"
    dir_fd, lock_fd = claim_dir(
        str(target), lock_name=".staging.lock", marker_name=".staging_owner.json",
        marker_payload={"tool": "qmt_fetch", "seed": "s1", "dest": str(target)},
        tool="qmt_fetch",
    )
    try:
        assert target.is_dir()
        assert (target / ".staging_owner.json").exists()
        assert (target / ".staging.lock").exists()
        got = verify_owner_marker(dir_fd, ".staging_owner.json", expect_tool="qmt_fetch",
                                  self_field="dest", self_value=str(target))
        assert got["seed"] == "s1"
    finally:
        os.close(lock_fd); os.close(dir_fd)


def test_claim_dir_takes_lock_before_publishing_ownership(tmp_path: Path, monkeypatch):
    # R97-F2：取锁必须早于发布归属。若顺序反了，两个 qmt_fetch 能同时
    # 往一棵 staging 里写（其中一个刚写完标记还没取到锁）
    order = []
    import qmt_fsroot as M
    real_lock, real_mark = M.acquire_lock, M.write_owner_marker
    monkeypatch.setattr(M, "acquire_lock",
                        lambda *a, **k: (order.append("lock"), real_lock(*a, **k))[1])
    monkeypatch.setattr(M, "write_owner_marker",
                        lambda *a, **k: (order.append("marker"), real_mark(*a, **k))[1])
    target = tmp_path / "dest"
    dir_fd, lock_fd = claim_dir(
        str(target), lock_name=".staging.lock", marker_name=".staging_owner.json",
        marker_payload={"tool": "qmt_fetch", "dest": str(target)}, tool="qmt_fetch")
    try:
        assert order == ["lock", "marker"]
    finally:
        os.close(lock_fd); os.close(dir_fd)


def test_claim_dir_raises_directory_exists_and_writes_nothing(tmp_path: Path):
    # 撞 EEXIST 时**一个字节都不写**——处置由调用方按各自规格决定（R91-F2）：
    # --dest 有合法标记 → 退回复用路径的完整准入序列；--output → 一律拒绝
    target = tmp_path / "dest"; target.mkdir()
    with pytest.raises(DirectoryExistsError):
        claim_dir(str(target), lock_name=".staging.lock",
                  marker_name=".staging_owner.json",
                  marker_payload={"tool": "qmt_fetch", "dest": str(target)},
                  tool="qmt_fetch")
    assert list(target.iterdir()) == []


def test_claim_dir_leaves_nothing_when_lock_unavailable(tmp_path: Path, monkeypatch):
    import qmt_fsroot as M
    def boom(*a, **k):
        raise LockUnavailableError("held")
    monkeypatch.setattr(M, "acquire_lock", boom)
    target = tmp_path / "dest"
    with pytest.raises(LockUnavailableError):
        claim_dir(str(target), lock_name=".staging.lock",
                  marker_name=".staging_owner.json",
                  marker_payload={"tool": "qmt_fetch", "dest": str(target)},
                  tool="qmt_fetch")
    # 目录已被 mkdir 出来（不可避免），但**没有标记** → 下次启动会走 probe 的
    # "vacuum" 分支，拿到唯一能干净 rmdir 的那一档指引
    assert target.is_dir() and list(target.iterdir()) == []
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k claim`
Expected: FAIL —— `ImportError: cannot import name 'claim_dir'`

- [ ] **Step 3: 写实现**

```python
def claim_dir(abs_path: str, *, lock_name: str, marker_name: str,
              marker_payload: dict, tool: str) -> tuple[int, int]:
    """首次使用 / 认领协议（`--dest` 与 `--output` **创建方式同规格**，R64-F1 + R66-F2）：

      1. `open_root(create_leaf=True)` —— 从 `/` 逐分量 `O_NOFOLLOW` 走到父目录，
         再 `os.mkdir(dir_fd=父fd)`：`mkdir` 是**唯一可移植的目录级独占创建原语**，
         而逐段走保证「独占创建」发生在**验过的那个父 inode** 里（R75-F2）；
      2. 取 `flock` —— **先取锁，再发布归属**（R97-F2）。顺序反了，
         两个进程就能同时往一棵 staging 里写；
      3. 写标记 + `fsync(文件)` + `fsync(该目录)`（父目录的 `fsync` 已在第 1 步做掉）。

    返回 `(dir_fd, lock_fd)`，**两者都归调用方、全程持有、用完必须关**。

    **路径已存在 → `DirectoryExistsError`，一个字节都不写。**
    这一档**只能 fail-closed，不能自动认领**：`mkdir` 之后的目录**不携带任何出处信息**，
    「我崩在半路留下的空目录」与「操作者预先建好的空目录」在磁盘上**完全一样**；
    意图记录只能证明「我打算建」，不能证明「我建成了」；写完标记后的「复查目录为空」
    只证明「里面没有文件」，**不证明「这个目录是我造的」**（R66-F2）。
    **造不出证据时，唯一诚实的做法是拒绝并交给人**——宁可要一次人工介入，
    不要一次静默越界。

    **`--dest` 与 `--output` 在 `EEXIST` 这一档结局不同**（R91-F2），
    由调用方决定，本原语不替它们决定。
    """
    dir_fd = open_root(abs_path, create_leaf=True)
    try:
        lock_fd = acquire_lock(dir_fd, lock_name, tool=tool)
    except BaseException:
        os.close(dir_fd)
        raise
    try:
        write_owner_marker(dir_fd, marker_name, marker_payload)
    except BaseException:
        os.close(lock_fd)
        os.close(dir_fd)
        raise
    return dir_fd, lock_fd
```

> ⚠️ 上面两处 `acquire_lock` / `write_owner_marker` 必须写成**模块级名字调用**
> （即直接 `acquire_lock(...)`），这样 Task 10 的顺序测试才能用 `monkeypatch.setattr`
> 拦到。不要在函数内部改成局部别名。

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 57 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): claim_dir 认领协议 —— 先取锁再发布归属，EEXIST 一律 fail-closed"
```

---

### Task 11: 三条边界判据（只读 / 路径重叠 / inode 分叉）

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: 无（纯判据）
- Produces:
  - `assert_readonly_fd(fd: int, *, label: str) -> None`
  - `assert_no_path_overlap(labeled: dict[str, str]) -> None`
  - `assert_distinct_inodes(labeled_fds: dict[str, int]) -> None`
  - `assert_fd_still_at(abs_path: str, fd: int, *, label: str) -> None`
  - `BoundaryError(Exception)`

- [ ] **Step 1: 写失败的测试**

```python
from qmt_fsroot import (
    BoundaryError, assert_distinct_inodes, assert_fd_still_at,
    assert_no_path_overlap, assert_readonly_fd,
)


def test_assert_readonly_fd_accepts_readonly_volume_rejects_writable(tmp_path: Path):
    # 非写入式判据：statvfs 问内核要挂载标志。
    # ⚠️ 禁止用「试写一个临时文件」探测——那种主动探测在**恰恰是它要防的
    # 那个危险场景里**（共享真的可写）会由本工具**亲手去写权威导出共享**，
    # 探测成功即污染（R5-F3）
    ro = open_root("/")                      # 本机实测：根卷 SSV 只读快照
    try:
        assert_readonly_fd(ro, label="--source")
    finally:
        os.close(ro)
    rw = open_root(str(tmp_path))
    try:
        with pytest.raises(BoundaryError, match="只读"):
            assert_readonly_fd(rw, label="--source")
    finally:
        os.close(rw)


def test_assert_no_path_overlap_rejects_equal_and_subtree(tmp_path: Path):
    src = tmp_path / "src"; src.mkdir()
    (src / "inner").mkdir()
    dest = tmp_path / "dest"; dest.mkdir()
    assert_no_path_overlap({"--source": str(src), "--dest": str(dest)})
    with pytest.raises(BoundaryError):
        assert_no_path_overlap({"--source": str(src), "--dest": str(src)})
    with pytest.raises(BoundaryError):
        # 否则一旦源挂载是可写的，qmt_fetch 会把锁/manifest/.part/CSV
        # **写进那个权威导出共享里**，污染的正是本次要取证的数据集（R4-F4）
        assert_no_path_overlap({"--source": str(src), "--dest": str(src / "inner")})
    with pytest.raises(BoundaryError):
        assert_no_path_overlap({"--source": str(src / "inner"), "--dest": str(src)})


def test_assert_no_path_overlap_is_not_fooled_by_sibling_prefix(tmp_path: Path):
    # /a/srcx 不是 /a/src 的子树——字符串前缀比较会误判
    (tmp_path / "src").mkdir(); (tmp_path / "srcx").mkdir()
    assert_no_path_overlap({"--source": str(tmp_path / "src"),
                            "--dest": str(tmp_path / "srcx")})


def test_assert_distinct_inodes_catches_symlink_aliased_dirs(tmp_path: Path):
    # 路径判据可被换掉，inode 判据不会（R84-F1）
    real = tmp_path / "real"; real.mkdir()
    (tmp_path / "alias").symlink_to(real)
    a = open_root(str(real))
    b = os.open(str(tmp_path / "alias"), os.O_RDONLY | os.O_DIRECTORY)
    try:
        with pytest.raises(BoundaryError):
            assert_distinct_inodes({"--source": a, "--dest": b})
    finally:
        os.close(a); os.close(b)


def test_assert_fd_still_at_detects_swapped_directory(tmp_path: Path):
    d = tmp_path / "staging"; d.mkdir()
    fd = open_root(str(d))
    try:
        assert_fd_still_at(str(d), fd, label="--dest")
        d.rename(tmp_path / "moved")
        (tmp_path / "staging").mkdir()       # 有人在原路径上放了另一棵树
        with pytest.raises(BoundaryError, match="--dest"):
            assert_fd_still_at(str(d), fd, label="--dest")
    finally:
        os.close(fd)
```

- [ ] **Step 2: 跑测试确认它红**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v -k assert_`
Expected: FAIL —— `ImportError: cannot import name 'BoundaryError'`

- [ ] **Step 3: 写实现**

在 Task 1 的异常族里追加，并实现四个判据：

```python
class BoundaryError(Exception):
    """信任边界判据不过（只读 / 路径重叠 / inode 不符）。"""


def assert_readonly_fd(fd: int, *, label: str) -> None:
    """**非写入式**只读判据：`os.fstatvfs(fd).f_flag & ST_RDONLY` 为真才继续（R5-F3）。

    ⚠️ **禁止用「试写一个临时文件」去探测**：那种主动探测在**恰恰是它要防的那个
    危险场景里**（共享真的可写）会**由本工具自己去写权威导出共享**——探测成功即污染。
    再叠加崩溃、删除失败或源本身是审计敏感目录，安全检查反而成了第一个破坏者。
    **为了防止破坏而引入的机制，本身带着破坏性**。

    ⚠️ 本判据**只证明「这是某个只读目录」**：本机根卷 `/` 自己就是
    `apfs … read-only`，**「只读」在 macOS 上根本区分不出「网络共享」与「本地卷」**
    （R19-F2，已实测）。绑住「就是那台机器上的那个共享」要靠**挂载身份**，那是 S5。
    """
    if not (os.fstatvfs(fd).f_flag & os.ST_RDONLY):
        raise BoundaryError(
            f"{label} 不是只读挂载。请以 `-o rdonly` 重新挂载："
            f"`mount_smbfs -o rdonly //<user>@<host>/<share> <挂载点>`。"
            f"（`rdonly` 的效果是连 super-user 也写不了——这是强制要求，不是建议。）"
        )


def assert_no_path_overlap(labeled: dict[str, str]) -> None:
    """任意两个目录**规范化后**不得相等、不得互为子树（R4-F4）。

    否则一旦源挂载是可写的，`qmt_fetch` 会把 `.staging.lock` / `fetch_manifest.json`
    / `.part` / 拷贝出来的 CSV **写进那个权威导出共享里**，污染的正是本次要取证的数据集。

    **按分量比，不按字符串前缀比**：`/a/srcx` 不是 `/a/src` 的子树。
    本判据与 `assert_distinct_inodes` **并用**——路径判据可被换掉，inode 判据不会。
    """
    items = [(lab, split_components(p)) for lab, p in labeled.items()]
    for i, (la, ca) in enumerate(items):
        for lb, cb in items[i + 1:]:
            if ca == cb:
                raise BoundaryError(f"{la} 与 {lb} 是同一个目录")
            shorter, longer, ls, ll = (
                (ca, cb, la, lb) if len(ca) < len(cb) else (cb, ca, lb, la)
            )
            if longer[:len(shorter)] == shorter:
                raise BoundaryError(f"{ll} 落在 {ls} 的目录树之内")


def assert_distinct_inodes(labeled_fds: dict[str, int]) -> None:
    """另比 `(st_dev, st_ino)`——**路径判据可被换掉，inode 判据不会**（R84-F1）。"""
    seen: dict[tuple[int, int], str] = {}
    for label, fd in labeled_fds.items():
        st = os.fstat(fd)
        key = (st.st_dev, st.st_ino)
        if key in seen:
            raise BoundaryError(
                f"{label} 与 {seen[key]} 指向同一个 inode"
                f"（路径不同不代表目录不同——符号链接/硬链接别名会让两条路径落到同一棵树）"
            )
        seen[key] = label


def assert_fd_still_at(abs_path: str, fd: int, *, label: str) -> None:
    """运行中途**分叉检查**：`os.stat(路径)` 的 `(st_dev, st_ino)` 必须等于 `os.fstat(fd)`。

    `--source` **没有归属标记、也没有锁**（它不是我们的目录），
    **没有任何东西阻止它在两条闸之间被换掉**（R84-F1 / R91-F1）。
    """
    st_path = os.stat(abs_path)
    st_fd = os.fstat(fd)
    if (st_path.st_dev, st_path.st_ino) != (st_fd.st_dev, st_fd.st_ino):
        raise BoundaryError(
            f"{label} 在运行中途被改名或改指：钉住的 inode 与当前路径已不是同一个"
        )
```

- [ ] **Step 4: 跑测试确认它绿**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_qmt_fsroot.py -v`
Expected: 62 passed

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): 只读/重叠/inode 分叉三条判据 —— 只读探测必须非写入式"
```

---

### Task 12: 收口 —— 全量回归 + 变异验证 + `__all__`

**Files:**
- Modify: `backend/qmt_fsroot.py`
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: 全部
- Produces: `__all__` 显式导出清单

- [ ] **Step 1: 补 `__all__` 与一条守卫测试**

```python
def test_all_exports_exist():
    import qmt_fsroot as M
    for name in M.__all__:
        assert hasattr(M, name), name
```

在 `qmt_fsroot.py` 的 docstring 之后、异常族之前加入：

```python
__all__ = [
    # 异常
    "PathDisciplineError", "PathEscapeError", "DirectoryExistsError",
    "LockUnavailableError", "LockDisciplineError", "MarkerInvalidError",
    "BoundaryError",
    # 路径规则
    "normalize_abs_path", "split_components",
    # 逐段无跟随
    "open_root", "open_under", "parent_fd_under",
    # 耐久提交
    "fsync_dir", "full_fsync",
    # 锁
    "acquire_lock", "probe_unclaimed_dir",
    # 归属
    "write_owner_marker", "verify_owner_marker", "claim_dir",
    # 边界判据
    "assert_readonly_fd", "assert_no_path_overlap",
    "assert_distinct_inodes", "assert_fd_still_at",
]
```

- [ ] **Step 2: 跑全量回归**

Run: `cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest -q`
Expected: **901 passed**（838 基线 + 63 新增），0 failed
⚠️ 报告时**必须贴实际输出行**，不许只写「通过了」（verification-before-completion）。

- [ ] **Step 3: 变异验证（由控制者亲跑，不接受 subagent 自证）**

对每一条守卫做「中和 → 该测必须变红 → 复原」。**最少这 14 条**：

| # | 中和什么 | 必须变红的测 |
|---|---|---|
| M01 | `normalize_abs_path` 去掉尾斜杠折叠 | `test_normalize_strips_trailing_slash_from_shell_completion` |
| M02 | `normalize_abs_path` 去掉 `.`/`..` 检查 | `test_normalize_rejects_dot_and_dotdot_with_distinct_message` |
| M03 | `open_root` 把逐段循环换成一次 `os.open(abs_path, O_NOFOLLOW)` | `test_open_root_rejects_symlinked_intermediate_component` |
| M04 | `_raise_walk_error` 把 `ENOENT` 也归进逃逸 | `test_open_root_missing_component_is_plain_filenotfound` |
| M05 | `open_root(create_leaf)` 把 `mkdir` 换成 `os.makedirs(exist_ok=True)` | `test_open_root_create_leaf_is_exclusive` |
| M06 | `open_root(create_leaf)` 删掉 `os.fsync(fd)` | **预期无测变红** —— 耐久性无法用单测证明，须在收口报告里**如实登记为残留**（同 4a 残留 4 的口径） |
| M07 | `open_under` 去掉逐段循环、直接 `os.open(relpath, dir_fd=root_fd)` | `test_open_under_rejects_symlinked_intermediate_component` |
| M08 | `open_under` 的 leaf 不加 `O_NOFOLLOW` | `test_open_under_leaf_symlink_gets_eloop` |
| M09 | `open_under` 删掉 `finally` 里的关 fd | `test_open_under_does_not_leak_intermediate_fds` |
| M10 | `parent_fd_under` 把 `os.dup(cur)` 改成 `cur` | `test_parent_fd_under_single_component_dups_root` |
| M11 | `full_fsync` 改成 `os.fsync` | `test_full_fsync_uses_F_FULLFSYNC_not_plain_fsync` |
| M12 | `acquire_lock` 去掉 `S_ISREG` 检查 | `test_acquire_lock_refuses_non_regular_lock_file` |
| M13 | `probe_unclaimed_dir` 给探测加上 `O_CREAT` | `test_probe_never_creates_the_lock_file` + `test_probe_vacuum_when_lock_file_absent` |
| M14 | `claim_dir` 把取锁与写标记的顺序对调 | `test_claim_dir_takes_lock_before_publishing_ownership` |

每条的做法：改一处代码 → 只跑那一条测 → 确认 **FAIL** → `git checkout backend/qmt_fsroot.py` 复原 → 跑全量确认回到绿。
**M06 预期无测变红是一条真实的覆盖缺口，必须原样写进 PR 正文与验收清单，不许略过。**

- [ ] **Step 4: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S1): __all__ 导出清单 + 收口回归"
```

- [ ] **Step 5: 对抗性评审**

```bash
bash .claude/scripts/codex-attest.sh --scope branch-diff --head feat/qmt-4b-fetch --base origin/main
```

**零 focus 窄化，绝不传未知参数**（兜底分支会把它当 focus → 假 approve）。
**被杀（日志无 `Verdict:` 行）不计轮次。**

---

## Self-Review

**1. Spec coverage（§4.1 + §4.5 锁/耐久两小节逐条对照）**

| spec 要求 | 落在哪个 Task |
|---|---|
| `open_root` 逐段无跟随 + 不 `realpath` | Task 1（规范化）+ Task 2 |
| `create_leaf` 用 `mkdirat` 独占创建 + 父目录 `fsync` | Task 3 |
| 不得用 `os.rename` 做不覆盖发布 | Task 3 的 docstring + `test_open_root_create_leaf_is_exclusive` |
| `open_under` 逐段 + `create_dirs` 只在新建成功才 `fsync` | Task 4 |
| `parent_fd_under` 三条同规格 | Task 5 |
| `os.replace` 直传 `dir_fd`、禁能力探测 | Task 5 测试 + Task 9 实现 |
| 耐久提交协议 + `F_FULLFSYNC` 威胁模型 | Task 6 |
| `flock` 内核持有、残留不构成拒绝、锁文件过符号链接纪律 | Task 7 |
| `EEXIST` 无标记时的三分支探测、绝不带 `O_CREAT` | Task 8 |
| 归属标记两层拆分、自指防搬走 | Task 9 |
| 认领协议、先取锁再发布归属、`EEXIST` fail-closed | Task 10 |
| 只读非写入式探测、路径重叠、inode 分叉 | Task 11 |
| **`--output` 的 `.superseded` / 报告 / zip** | ❌ **不在 S1** —— 4c（切片映射已登记） |
| **`--dest` / `--output` 在 `EEXIST` 的不同结局** | ❌ **不在 S1** —— 是调用方（S5 / 4c）的决定，S1 只抛 `DirectoryExistsError` |
| **manifest 相关的一切** | ❌ **不在 S1** —— S2 |

**2. Placeholder scan**：无 TBD / TODO；每个代码步骤都给了完整可粘贴的实现；Task 7 的测试里有一段草稿残留变量已在正文用 ⚠️ 显式标出要删。

**3. Type consistency**：`open_root` / `open_under` / `parent_fd_under` 三者的 `relpath` 分量规则统一由 `_split_rel` / `split_components` 提供；`PathEscapeError` 的三个属性名 `relative_path` / `component` / `errno` 在 Task 2、4、5 的测试里逐字一致，且与 spec 要求的 `fetch_fatal_error{kind, relative_path, component, errno}` 四字段中的后三个逐字对应（`kind` 由 S4 调用方补）。

**4. 已知残留（须进 PR 正文）**：M06 —— 耐久性（`fsync` 有没有真的被调用、目录项有没有落地）**无法用单测证伪**。S4 的崩溃注入测试才够得着一部分，断电那一档在本机永远测不到。
