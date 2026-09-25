# Task 2 报告：幂等四象限判据

## 位置确认

```
$ cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a" && git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
3447b7ff
```

开工前 base 是 `3447b7ff`（实施计划提交，父提交 `e2446778` 是 Task 1 的最后一次
修正提交）——与任务书给定的 base 一致。

完工后提交：

```
$ git log --oneline -2
8875c71a QMT 4b S4a Task 2：幂等四象限判据（D2 + D4 第 1 条）
3447b7ff QMT 4b S4a：实施计划（薄，零代码块）
```

在 `qmt-4b-s4a` 分支上，未 push。

## 交付的文件（修改，非新建）

- `backend/qmt_fetch.py`：+139 行（新增 `_is_regular` / `_validate_record` /
  `_hash_target` / `classify_target` 四个符号 + 四个 `TARGET_*` 常量；`copy_one`
  内联的 `stat.S_ISREG(...)` 改为调用 `_is_regular(st)`，行为不变）。
- `backend/tests/test_qmt_fetch.py`：+13 个测试（未改动 Task 1 已有的 14 个）。

## 公开符号与签名（Task 3 要接的接口）

```python
# 四象限判据返回的四个字面量
TARGET_COPY = "copy"
TARGET_SKIP = "skip"
TARGET_RECOPY = "recopy"
TARGET_UNTRACKED = "untracked_target_file"   # 与 StockCopyFailed 未来要用的 reason 字面量逐字相同

def classify_target(stg_fd: int, rel: str, record) -> str:
    """`record` 是调用方已从 manifest `files` 里按
    (stock_code, period, relative_path) 查出来的那一条记录
    （形如 {"bytes": int, "sha256": str, ...}），或 None（无记录）。
    返回 TARGET_COPY / TARGET_SKIP / TARGET_RECOPY / TARGET_UNTRACKED 之一。
    record 形状不对时抛 TypeError（不是四个字面量之一，也不是四族既有异常）。
    symlink 叶子时 PathEscapeError 原样传播（不捕获）。
    """
```

`__all__` 新增：`"TARGET_COPY", "TARGET_SKIP", "TARGET_RECOPY", "TARGET_UNTRACKED", "classify_target"`。

**Task 3 需要知道的边界**（都是「Task 2 不做」的部分，明写在 `classify_target`
docstring 里，避免 Task 3 误以为这一层已经处理）：
- 不做源侧比对（D3，`copy_one` 的范围）。
- 不做「落地前把新拷出的字节/哈希与记录比对」（D4 第 2 条），**含「有记录 ×
  目标不存在」那一格**——`classify_target` 对这一格只回答「目标不存在，去
  拷贝」（`TARGET_COPY`），不会去比对 `record`；那次比对（以及比对不符时的
  终止逻辑，D5）要 Task 3 在真正落地前自己做。
- 不写任何标记、不碰 `.inflight.json`、不提交 manifest——纯读判据，无副作用。
- 不区分`未知模态类型`（本片只处理 stg_fd 是已打开的根目录 fd 这一种输入形态，
  没有对 `stg_fd` 本身做任何校验——如果 Task 3 传一个已关闭或错误的 fd，
  会得到底层 `OSError`，不是这四个字面量之一）。

## 设计要点（对照契约）

**决定 1（控制者已定）— 抽出单一 `_is_regular` 判据**：Task 1 内联的
`stat.S_ISREG(st.st_mode)` 抽成模块级 `_is_regular(st) -> bool`，`copy_one`
与新增的 `classify_target` 都只经这一处判定「是不是普通文件」。纯提取，
不改变 `copy_one` 行为——Task 1 原有 14 个测试改动前后全部保持绿（见下）。

**D2（staging 目标非普通文件一律拒绝覆盖，不按有无记录分叉）**：
`classify_target` 里唯一的分支依据是 `if not _is_regular(st): return TARGET_UNTRACKED`，
这一句**先于**任何 `record is None` 判断，即无论有没有记录，只要目标存在且
不是普通文件，一律 `TARGET_UNTRACKED`。目录与 FIFO 走的是 `open_regular_probe`
**成功返回 `(fd, st)`** 那条路（契约原文：两者都「打开成功」，只是 `st.st_mode`
不是 `S_ISREG`），走的正是这条显式检查，不是任何 `except`。

**「不是 `except NotARegularFileError`」怎么落实的**：`NotARegularFileError`
只在 `open()` 本身失败（如 socket，`ENOTSUP`/`ENXIO`）时才会抛出，此时把异常
携带的 `e.st`（`_open_regular_probe` 内部 `lstat` 探测的结果）原样取出，
`fd` 置 `None`，随后仍然走同一条 `_is_regular(st)` 判据——**异常本身只是
拿到 `st` 的另一条路，不是判定「非普通」的依据**。真正的判定永远只有一处：
`_is_regular(st)`。

**符号链接不落进拒绝覆盖那一档（决定 2）**：`classify_target` 完全不捕获
`PathEscapeError`（`parent_fd_under` 走中间目录分量、`open_regular_probe`
背后的 `open_under` 走叶子分量，两处任一撞见符号链接都抛 `ELOOP`/`ENOTDIR`
→ `PathEscapeError`，不是 `OSError` 子类），故它会原样穿透 `classify_target`
向上传播，绝不会被归进 `TARGET_UNTRACKED`。专门测试见下方证据 3。

**D4 第 1 条（「相符」判据含 S_ISREG）**：`classify_target` 判「相符」的完整
链条是「先 `_is_regular` 排非普通 → 再比 `st.st_size == record["bytes"]` →
都过了才读内容比 `sha256`」，三层缺一都会把非普通对象或篡改内容错判成相符。

**判据对任意坏输入安全**：`_validate_record` 在函数最开头（任何文件系统 I/O
之前）无条件跑一遍，`record is None` 之外要求是 `dict` 且含 `bytes`（`int`
非 `bool`）与 `sha256`（`str`）两个字段，任一不满足都抛 `TypeError`，**不区分
走到哪一格才校验**——即便最终会落进「目标不存在」这种根本用不上 `record`
细节的分支，坏记录照样先被截住。

## 全量测试

```
$ cd backend && ../.venv/bin/python -m pytest tests/ -q -rs
...
1532 passed in 34.91s
```

基线 1519（Task 1 完工时）+ 本片新增 13 个测试 = 1532，逐字吻合。`skipped` 为 0。

## 五项必须证据

### 1. R2-F3 回归钉：同尺寸不同内容必须判重拷，不得跳过

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py::test_classify_target_same_size_different_content_is_recopy_not_skip -v
tests/test_qmt_fetch.py::test_classify_target_same_size_different_content_is_recopy_not_skip PASSED
```

测试构造 `original`/`tampered` 两串等长（各 200 字节）但内容不同的字节串，
staging 落的是 `tampered`，`record` 记的是 `original` 的 `bytes`+`sha256`，
断言 `classify_target` 返回 `TARGET_RECOPY`（不是 `TARGET_SKIP`）。

### 2. D2 验收：目录与 FIFO 各一档，且记录的 `bytes` 恰等于该非普通对象的 `st_size`

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -v -k "directory_with_record or fifo_with_record"
tests/test_qmt_fetch.py::test_classify_target_directory_with_record_matching_st_size_is_untracked PASSED
tests/test_qmt_fetch.py::test_classify_target_fifo_with_record_matching_st_size_is_untracked PASSED
```

两条测试都是现场 `os.stat()`（目录）/ `os.stat()`（FIFO）读出真实 `st_size`，
把 `record["bytes"]` 设成**恰好相等**的值（`sha256` 随便填一个占位串，因为
正确实现根本不会读到那一步），断言 `classify_target` 仍然返回
`TARGET_UNTRACKED`，不是因为字节数「凑巧不等」才躲过去的。

### 3. 符号链接叶子必须走路径逃逸，不得落进拒绝覆盖那一档

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py::test_classify_target_symlinked_leaf_escapes_not_untracked -v
tests/test_qmt_fetch.py::test_classify_target_symlinked_leaf_escapes_not_untracked PASSED
```

staging 里造一个真实文件 + 一条指向它的符号链接，对符号链接那条相对路径调用
`classify_target`，用 `pytest.raises(PathEscapeError)` 断言，并额外断言
`ei.value.errno == errno.ELOOP`（与 `test_qmt_fsroot.py` 里
`test_open_under_leaf_symlink_gets_eloop` 同规格的实测 errno，不是猜的）。

### 4. 判据对任意坏输入安全：字段缺失 / 类型不对 / 不可哈希类型一律拒绝

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -v -k "rejects_record or rejects_non_dict"
tests/test_qmt_fetch.py::test_classify_target_rejects_record_missing_bytes_field PASSED
tests/test_qmt_fetch.py::test_classify_target_rejects_record_wrong_type_for_bytes PASSED
tests/test_qmt_fetch.py::test_classify_target_rejects_record_unhashable_sha256 PASSED
tests/test_qmt_fetch.py::test_classify_target_rejects_non_dict_record PASSED
```

四档分别覆盖：缺 `bytes` 字段、`bytes` 类型错（字符串）、`sha256` 传成不可哈希
类型（`list`）、`record` 整体不是 `dict`（字符串）。全部断言 `pytest.raises(TypeError)`。

### 5. 三条变异，各自单独跑（邻居全部 deselect），确认红的是那一条

每条变异前后都先清 `__pycache__`（`find . -name "__pycache__" -exec rm -rf {} +`），
只跑目标测试（用 `::test_name` 精确选择，等价于把其余 26 个 deselect 掉）。

**变异①：只比字节数不比哈希**——把
`return TARGET_SKIP if _hash_target(fd) == record["sha256"] else TARGET_RECOPY`
改成 `return TARGET_SKIP`（size 检查照旧，只是过了 size 就直接判 skip，不读内容）。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest "tests/test_qmt_fetch.py::test_classify_target_same_size_different_content_is_recopy_not_skip" -q -rs
F
FAILED tests/test_qmt_fetch.py::test_classify_target_same_size_different_content_is_recopy_not_skip
AssertionError: 同尺寸不同内容必须判重拷，不得因字节数相符就跳过哈希比对
assert 'skip' == 'recopy'
1 failed in 0.03s
```

红的正是这一条。还原代码、清 `__pycache__`、重跑同一条 → 绿（1 passed）。

**变异②：非普通文件当成相符**——删掉 `if not _is_regular(st): return TARGET_UNTRACKED`
这一句（`record is None` 检查以下代码不动）。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest "tests/test_qmt_fetch.py::test_classify_target_directory_with_record_matching_st_size_is_untracked" -q -rs
F
IsADirectoryError: [Errno 21] Is a directory
  qmt_fetch.py:343: in classify_target
    return TARGET_SKIP if _hash_target(fd) == record["sha256"] else TARGET_RECOPY
  qmt_fetch.py:281: in _hash_target
    chunk = os.read(fd, _CHUNK)
1 failed in 0.03s
```

红的正是这一条（去掉类型闸门后，代码试图对目录 fd 调 `os.read`，撞
`IsADirectoryError`——失败形态是异常而不是断言不符，但仍然是「这条测试挂了」，
判别力成立）。用同一条测试外加 FIFO 那一档复核（`-k "directory_with_record or fifo_with_record"`）
两条均变红后，还原代码、清缓存、重跑两条 → 均绿。

**变异③：坏记录「跳过」而非「拒绝」**——把 `_validate_record` 函数体第一行改成
`return`（无条件直接返回，后面的校验全部变成死代码）。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest "tests/test_qmt_fetch.py::test_classify_target_rejects_record_missing_bytes_field" -q -rs
F
Failed: DID NOT RAISE <class 'TypeError'>
1 failed in 0.03s
```

红的正是这一条。额外复核另外三档坏输入测试（`wrong_type_for_bytes` /
`rejects_record_unhashable_sha256` / `rejects_non_dict_record`）同一变异下
**同时全部变红**（3 failed，逐条核对失败信息都是 `DID NOT RAISE`），
证明四条坏输入测试的判别力都真的落在 `_validate_record` 这一处，
不是巧合通过。还原代码、清缓存、四条一起重跑 → 全绿。

变异复原后的终态：清 `__pycache__` 后跑整套 `tests/` → `1532 passed`（与「全量测试」
一节完全一致），确认没有遗留任何变异代码。

## 我做的、brief 没直接写死的决定

1. **四个字面量的具体字符串值**：brief 只说「返回四个字面量之一」，没给出字面
   值。`TARGET_UNTRACKED` 我定成 `"untracked_target_file"`——这不是我编的，
   Task 1 的模块 docstring 里已经预告「D2/Task 2 会另产
   `untracked_target_file`」，且契约正文反复用这个词作为 `reason`；三个探针
   脚本（`docs/superpowers/evidence/.../engine.py`）用的是
   `"untracked"`（缩写），但那是一次性探针、非权威，故没有照抄。另外三个
   （`TARGET_COPY="copy"` / `TARGET_SKIP="skip"` / `TARGET_RECOPY="recopy"`）
   契约正文没给字面量，我选了与探针脚本一致、见名知意的英文词，并作为模块级
   常量导出，供 Task 3 直接 `import` 比较，不必各自硬编码字符串。
2. **坏记录校验统一用 `TypeError`**：brief 只要求「一律拒绝（抛清楚的错）」，
   没指定异常类型。我没有新建异常类，也没有借用 Task 1 的三族异常（候选失败 /
   终止条件 / 路径逃逸——这三族语义都不贴切：一条形状错误的记录既不是「这只
   股这次不行」也不是「整次运行要停」，它是调用方传参错误）。统一用标准库
   `TypeError`（缺字段与类型不对都算「这个位置该是某类型，却不是」），
   四条坏输入测试因此可以用同一个 `pytest.raises(TypeError)` 断言，不必分类型。
3. **`NotARegularFileError` 的处理方式**：没有照抄探针脚本 `engine.py::classify`
   里 `except NotARegularFileError: return TARGET_UNTRACKED if record is None
   else TARGET_RECOPY` 的写法（那是决定 2 警告过的「用 os.lstat/异常类型直接
   分支」路数的变体）。改成把异常携带的 `st` 取出、并入唯一的
   `_is_regular(st)` 判据，让「记录了但目标是 socket」也统一走
   `TARGET_UNTRACKED`（不是探针那样按 `record is None` 分叉成
   `TARGET_UNTRACKED`/`TARGET_RECOPY`，那个分叉本身就是 D2「非普通文件不按
   有无记录分叉」要否决的行为）。socket 目标不在 D2 规定的必测档位里
   （只要求目录与 FIFO 各一档），我没有为它单独加测试，但设计上它与目录/FIFO
   走的是同一段代码（唯一区别只是 `fd` 变量是否为 `None`），不是另开的分支。
4. **`_validate_record` 何时跑**：选择在函数最开头、任何文件系统访问之前
   无条件跑（而不是只在「有记录且需要比对」的分支里跑）。理由见设计要点一节
   ——对齐「判据对任意坏输入安全」的字面要求（不分是哪一格用到它）。

## 未解决 / 交给 Task 3 的事项（均已写在 `classify_target` docstring 里，非新发现）

- D4 第 2 条（「有记录 × 目标不存在」也要在落地前比对，源已换代则触发 D5 终止）
  不在本片范围——`classify_target` 对这一格只回答「拷」，不做比对。
- `classify_target` 是纯读判据，`stg_fd` 由调用方负责打开/持有/关闭，本函数
  内部只临时打开/关闭 `rel` 对应的 `fd`（成功路径下若命中 `TARGET_SKIP`/
  `TARGET_RECOPY`/`TARGET_UNTRACKED` 走到函数末尾都已在 `finally` 里关掉，
  不泄漏）。

---

# Fix round 1（评审：spec ✅，task quality changes requested，0 Critical / 3 Important）

三条 Important 同一家族：**行为本身是对的，但套件对它判别力为零**——把对应代码
改坏，27 个既有测试（Task 1 的 14 + Task 2 的 13）全部保持绿。本轮只加测试，
**不改任何既有行为**：`git diff backend/qmt_fetch.py` 在本轮结束时为空（改动只
落在测试文件）。

## 位置确认

```
$ cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a" && git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
5a83fe7d
```

开工前 HEAD 是 `5a83fe7d`——比 Task 2 提交 `8875c71a` 多一层：中间插入了协调者
自己的一次提交（`证据：给 engine.py 与 FACTS.md 加警示`，与本轮三条 Important
无关，未改动 `backend/`，用 `git diff 8875c71a HEAD -- backend/` 核实过为空）。

## 新增的 3 个测试（`backend/tests/test_qmt_fetch.py`，+85 行，只加不改）

1. `test_classify_target_does_not_leak_target_fd_across_repeated_calls`
   ——覆盖普通文件 / 目录 / FIFO 三个分支，各自建好目标后循环调用
   `classify_target` 50 次，用 `len(os.listdir("/dev/fd"))` 量前后差值
   （与本仓既有的 `test_open_under_does_not_leak_intermediate_fds` /
   `test_parent_fd_under_does_not_leak_intermediate_fds` 同规格：
   `assert after - before <= 2`，留出 listdir 自身的抖动）。
2. `test_classify_target_symlinked_intermediate_component_escapes_not_untracked`
   ——`1m` 这一级目录分量本身是符号链接（指向 staging 之外），断言
   `classify_target` 抛出 `PathEscapeError`（`component == "1m"`，
   `errno == ENOTDIR`），不是 `TARGET_UNTRACKED`。与既有的叶子符号链接钉子
   （`test_classify_target_symlinked_leaf_escapes_not_untracked`）互补，
   覆盖 `parent_fd_under` 撞逃逸的那条路径（叶子钉子走的是
   `open_regular_probe` 那条路径，两条代码路径不同）。
3. `test_classify_target_socket_target_is_untracked_no_leak`
   ——真造一个 `AF_UNIX` socket 当 staging 目标（沿用 Task 1 源侧 socket 测试
   同规格的 `monkeypatch.chdir` + 相对路径 `bind`，绕开 AF_UNIX 路径长度上限），
   `record["bytes"]` 与 `os.lstat` 量到的 `st_size` 对齐，断言返回
   `TARGET_UNTRACKED`、不抛异常、`/dev/fd` 计数前后不变。

## 全量测试

```
$ cd backend && ../.venv/bin/python -m pytest tests/ -q -rs
...
1535 passed in 34.84s
```

基线 1532（本轮开工前）+ 3 = 1535，`skipped` 为 0。`test_qmt_fetch.py` 单独跑
30 passed（14 + 16）。

## 三条变异，逐条单独跑（邻居 deselect），确认红的是那一条

每条变异前后都先清 `__pycache__`，只跑目标测试（`::test_name` 精确选择）。

### Important 1 的变异：`finally: if fd is not None: os.close(fd)` 换成 `finally: pass`

与协调者描述的变异逐字一致。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest "tests/test_qmt_fetch.py::test_classify_target_does_not_leak_target_fd_across_repeated_calls" -q -rs
F
AssertionError: 目标 fd 疑似泄漏：调用前 14 个，调用后 164 个
assert (164 - 14) <= 2
1 failed in 0.04s
```

红的正是这一条（150 = 50 次循环 × 3 个分支，恰好每次调用都漏了一个 fd）。
还原代码、清 `__pycache__`、重跑同一条 → 绿（1 passed）；`git diff backend/qmt_fetch.py`
确认已完全复原。

### Important 2 的变异：`parent_fd_under` 那层 `except FileNotFoundError` 放宽成 `except (FileNotFoundError, Exception)`

模拟「日后重实现时手滑把逃逸异常也吞掉」——`PathEscapeError` 是 `Exception`
子类，会被这一支接住并错误地折成 `TARGET_COPY`。

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest "tests/test_qmt_fetch.py::test_classify_target_symlinked_intermediate_component_escapes_not_untracked" -q -rs
F
Failed: DID NOT RAISE <class 'qmt_fsroot.PathEscapeError'>
1 failed in 0.04s
```

红的正是这一条。还原代码、清 `__pycache__`、重跑同一条 → 绿。

### Important 3 的变异：删掉 `except NotARegularFileError as e: fd, st = None, e.st` 分支

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ ../.venv/bin/python -m pytest "tests/test_qmt_fetch.py::test_classify_target_socket_target_is_untracked_no_leak" -q -rs
F
qmt_fsroot.NotARegularFileError: '600000.SH_sock.csv' 存在但不是普通文件（无法作为文件打开）
1 failed in 0.05s
```

红的正是这一条（`NotARegularFileError` 未捕获、原样炸出，测试因未预期的异常
而不是断言失败挂掉——仍然是「这条测试挂了」，判别力成立）。还原代码、清
`__pycache__`、重跑同一条 → 绿。

变异复原后的终态：清 `__pycache__` 后跑整套 `tests/` → `1535 passed`（与「全量
测试」一节完全一致），`git diff backend/qmt_fetch.py` 为空，确认没有遗留任何
变异代码；`git diff backend/tests/test_qmt_fetch.py` 只有本轮新增的 3 个测试
（纯新增，未改动已有测试）。

## 三条 Minor（协调者已明确本轮不处理，留给整支评审）

未查看、未处理，按指示留给最终整支评审。
