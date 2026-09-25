# Task 1 报告：字节预算 + 单文件流式拷贝

## 位置确认

```
$ cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a" && git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
5c6ad98b   ← 开工前（base）
```

开工前 base 是 `5c6ad98b`（契约 + 可复跑证据那个提交），与任务书一致。

完工后 HEAD：

```
$ git log --oneline -3
e2446778 修正一条被 precheck 提前拦截、名不副实的测试
fb28a502 QMT 4b S4a Task 1：字节预算 + 单文件流式拷贝
5c6ad98b QMT 4b S4a：契约 + 可复跑证据（大 spec 与切片地图各加纯指针，零删改）
```

两个提交都在 `qmt-4b-s4a` 分支上，未 push。

## 交付的文件

- `backend/qmt_fetch.py`（新建，219 行）
- `backend/tests/test_qmt_fetch.py`（新建，14 个测试）

## 公开符号与签名（Task 2 / Task 3 要接的接口）

```python
# 异常三族——互不相交，各自可用一个 except 接住整族
class StockCopyFailed(Exception):
    def __init__(self, reason: str, detail: str = ""): ...
    # .reason: str  —— 本片只产生 "fetch_missing_file" / "fetch_copy_hash_mismatch"

class RunTerminated(Exception):
    """终止条件族公共基类。本片只有 MaxBytesExhausted 一个成员；
    Task 3 要补第二个成员（D5：源比对不符），作为 RunTerminated 的另一个子类。"""

class MaxBytesExhausted(RunTerminated): ...

# 路径逃逸：qmt_fsroot.PathEscapeError，本模块不捕获、不包装，原样上抛。

# 字节预算
class ByteBudget:
    def __init__(self, *, limit: int | None, used: int = 0): ...
    def precheck(self, size: int) -> None: ...   # 可能抛 MaxBytesExhausted
    def charge(self, n: int) -> None: ...          # 可能抛 MaxBytesExhausted
    def refund(self, n: int) -> None: ...          # n > used 时抛 ValueError

# `.part` 后缀常量
PART = ".part"

# 单文件流式拷贝
class CopyResult(NamedTuple):
    n_bytes: int
    sha256: str

def copy_one(src_fd: int, stg_fd: int, rel: str, budget: ByteBudget) -> CopyResult: ...
```

`__all__` = `["StockCopyFailed", "RunTerminated", "MaxBytesExhausted", "ByteBudget", "PART", "CopyResult", "copy_one"]`。

## 设计要点（对照契约）

**D3**（源侧叶子非普通文件）：`_open_source_leaf` 只对 `parent_fd_under` 与
`open_regular_probe` 抛出的 `FileNotFoundError` / `NotARegularFileError` 两种做映射
（折成 `StockCopyFailed("fetch_missing_file")`），**不接 `except OSError`**——
`PermissionError` 等其它 `OSError` 原样上抛。`copy_one` 对打得开但 `S_ISREG` 为假
的情形（FIFO / 目录）单独用 `if not stat.S_ISREG(...)` 判，不依赖异常路径。
符号链接由 `qmt_fsroot` 自己在逐段无跟随时抛 `PathEscapeError`，本模块完全不触碰。

**D7**（逐块记账 + 回滚退还）：`copy_one` 用局部变量 `charged` **逐块**累加
（每次 `budget.charge(len(chunk))` 成功后立即 `charged += len(chunk)`），
唯一的 `except BaseException: if charged: budget.refund(charged); raise`
覆盖「写目的文件失败」「budget.charge 中途拒绝」「落地复算不符」三条路径，
退还的触发点是「已经扣过账」，不是「拷贝函数正常返回过」。

## 一个在写测试时抓到的真 bug（已修）

最初 `_open_source_leaf` 把 `parent_fd_under(src_fd, rel)` 这一步放在
`try/except` **之外**，导致「整段中间目录都不存在」（比如这个 period 从没导出过）
会让 `FileNotFoundError` **原样炸出去**，不会被归成 `fetch_missing_file`——
D3 判据出现漏洞。跑 `test_budget_after_three_consecutive_failures_matches_untried`
时第一次调用就直接抛出未捕获的 `FileNotFoundError`，当场发现。
已修：把 `parent_fd_under` 也纳入 try/except（`qmt_fetch.py` 第 143-148 行）。
另补了一条专门回归测试
`test_copy_one_source_whole_directory_missing_is_also_fetch_missing_file`
区分「目录在、叶子不在」与「整段目录都不在」两条不同的异常来源代码路径。

## 全量测试

```
$ cd backend && ../.venv/bin/python -m pytest tests/ -q -rs
...
1519 passed in 34.94s
```

基线是 1505（Task 1 之前），新增 14 个测试，1505+14=1519，`skipped` 为 0。

## 五项必须证据

### 1. D3 验收：源侧 FIFO、源侧 socket 各一档；socket 档另断言 PermissionError 不被归类

```
$ cd backend && ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -v
...
tests/test_qmt_fetch.py::test_copy_one_source_fifo_is_fetch_missing_file PASSED
tests/test_qmt_fetch.py::test_copy_one_source_socket_is_fetch_missing_file_but_permission_error_is_not PASSED
```

socket 档测试体分两段：①用真 `socket.socket(AF_UNIX, SOCK_STREAM)` + `bind()`
造一个真 socket 特殊文件（`AF_UNIX` 路径长度上限约 104 字节，`tmp_path` 常超，
用 `monkeypatch.chdir` 切进目标目录再用相对名绑定，与 `test_qmt_manifest.py`
里 `test_read_manifest_refuses_a_socket_manifest` 同规格），断言
`StockCopyFailed(reason="fetch_missing_file")`；②`monkeypatch.setattr(qmt_fetch,
"open_regular_probe", fake_probe)` 打桩造一个 `PermissionError(EACCES)`
（不用真 `chmod 000`，因为 CI 里 root 跑会无视权限位），断言抛出的是
**原样的 `PermissionError`**，不是 `StockCopyFailed`。

### 2. 变异坐实 D3 判别力

变异：把 `_open_source_leaf` 里 `open_regular_probe` 那一段的
`except FileNotFoundError / except NotARegularFileError` 两支合并成一支
`except OSError`（`qmt_fetch.py:149-154`）。

先跑 FIFO 档 + socket 档、把其余 12 条测试 deselect 掉：

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs -k "fifo or socket"
...
qmt_fetch.StockCopyFailed: fetch_missing_file: 1m/600000.SH_sock.csv: [Errno 13] 打桩：模拟权限错误
1 failed, 1 passed, 12 deselected in 0.03s
```

`socket` 档变红（`PermissionError` 被误判成 `StockCopyFailed("fetch_missing_file")`），
`fifo` 档仍绿——与契约原文吻合：「FIFO 带 O_NONBLOCK 打开成功，走的是调用方
`S_ISREG` 那一支，根本到不了抛异常的分支，故『断言不是……』对 FIFO 是恒真断言」，
判别力只可能落在 socket 档。再单独只跑 socket 档确认（13 条全部 deselect）：

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs -k "test_copy_one_source_socket_is_fetch_missing_file_but_permission_error_is_not"
...
E           qmt_fetch.StockCopyFailed: fetch_missing_file: 1m/600000.SH_sock.csv: [Errno 13] 打桩：模拟权限错误
1 failed, 13 deselected in 0.03s
```

红的确实是这一条，不是巧合。变异前先 `find backend -name __pycache__ -exec rm -rf {} +`
清缓存，之后用 `git checkout -- backend/qmt_fetch.py` 复原（复原前已 commit 干净版本，
不存在抹掉未提交改动的风险），复原后重新清缓存、重跑全量确认恢复 1519 passed。

### 3. D7 验收：连续三次失败后预算与从未尝试过时相同（覆盖「拷到一半抛异常」）

`test_budget_after_three_consecutive_failures_matches_untried`：
第 1 次「文件缺失」（D3，`FileNotFoundError`），第 2 次「拷到一半抛异常」
（打桩 `os.write` 在第 2 块时抛 `OSError(EIO)` 模拟 SMB 断线，`_CHUNK` 打成 64
让 320 字节的源文件切成 5 块，保证真的是「半路」不是「开头」），第 3 次再来一遍
「文件缺失」。三次之后都断言 `budget.used == baseline`（baseline 用 100 起步，
模拟这次运行里已有别的股花掉的字节，证明这只股这三次尝试净贡献是 0）。

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs -k "test_budget_after_three_consecutive_failures_matches_untried"
tests/test_qmt_fetch.py .                                                [100%]
1 passed, 13 deselected in 0.02s
```

### 4. 变异坐实 D7 判别力

变异：把 `copy_one` 里「本次已写字节」的累加方式从**逐块** `charged += len(chunk)`
改成**只在写循环成功跑完（`os.fsync` 之后）才**一次性赋值 `charged = _total`
（`qmt_fetch.py` 写循环那一段，`_total` 逐块累加、`charged` 只在成功路径末尾赋值）。

单独跑第 3 项的 D7 测试（13 条 deselect）：

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs -k "test_budget_after_three_consecutive_failures_matches_untried"
...
>       assert budget.used == baseline, "拷到一半抛异常后，已扣的账必须原样退还"
E       AssertionError: 拷到一半抛异常后，已扣的账必须原样退还
E       assert 228 == 100
E        +  where 228 = <qmt_fetch.ByteBudget object at 0x10a617110>.used
1 failed, 13 deselected in 0.05s
```

变红：mid-copy 断线那一次已经通过 `budget.charge()` 真实扣了两块的账（128），
但被拒之前 `charged`（在变异后的代码里）从未被赋过非零值，退还时
`if charged: refund(charged)` 判定为假、什么都没退，账一直留在 budget 里，
所以最终 `budget.used` 停在 228（100 baseline + 128 未退还），不等于 100。

另外我自己加的一条非必需的补充测试
`test_copy_one_charge_enforces_independently_of_precheck`（见下方「决定」一节）
在同一变异下也单独变红（13 条 deselect）：

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs -k "test_copy_one_charge_enforces_independently_of_precheck"
...
>       assert budget.used == 0          # 已扣的第 1 块（64）也退还了
E       assert 64 == 0
1 failed, 13 deselected in 0.06s
```

变异前后都 `find backend -name __pycache__ -exec rm -rf {} +` 清缓存；
复原用 `git checkout -- backend/qmt_fetch.py`（此时未提交改动只有这一处变异，
干净版本已提前 commit），复原后重新清缓存、重跑全量确认恢复 1519 passed。

### 5. 落地复算不是恒等式：写出去的字节与读回来的不同 ⇒ `fetch_copy_hash_mismatch`

`test_copy_one_detects_landed_part_diverging_from_source_hash`：打桩 `os.write`
「少写一段」——真的只往磁盘写 `len(data)-1` 字节，却向调用方谎报「整段都写完了」
（`_write_all` 的重试循环因此提前认为写完），源端流式算出的 `hasher` 用的是完整
4096 字节，而落地后重新打开 `.part`、从磁盘重新读回去算出的 `verify` 哈希不同
——不是同一份内存里的 hasher 复用，是真的重新打开文件重新读。

```
$ ../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -rs -k "test_copy_one_detects_landed_part_diverging_from_source_hash"
tests/test_qmt_fetch.py .                                                [100%]
1 passed, 13 deselected in 0.02s
```

断言 `ei.value.reason == "fetch_copy_hash_mismatch"`，并额外断言
`budget.used == 0`（落地复算不符这一档同样在 `copy_one` 那个唯一的
`except BaseException` 里退还了已扣的账，验证退还逻辑对这条路径也生效）。

## 我自己做的、brief 没直接回答的决定

1. **`.part` 写入用 `os.fsync`，不用 `full_fsync`**。`qmt_fsroot.full_fsync` 的
   文档明写「manifest 提交与回滚时那道顺序屏障两处用本函数，其余落地点保留
   `fsync_dir` / `os.fsync`」——`.part` 写入不是这两处之一（它甚至还不是提交，
   崩溃后会被当孤儿清理），故用 `os.fsync`，也与证据脚本 `engine.py` 的探针
   写法一致。

2. **`CopyResult` 字段名用 `n_bytes` 不用 `bytes`**，避免跟内建类型 `bytes`
   同名造成阅读歧义（`result.bytes` 读起来容易和 Python 的 `bytes` 类型混淆）。
   语义不变，Task 2/3 用 `.n_bytes` / `.sha256` 两个属性读。

3. **`_open_source_leaf` 把 `parent_fd_under` 也纳入错误分类**（见上方「抓到的
   真 bug」一节）——brief 只提了 `open_regular_probe` 那一层的分类，我按 D3
   的精神（「这只股这次有没有可用源文件」）把「整段目录缺失」也算进
   `fetch_missing_file`，因为对调用方而言这两种缺失没有语义差别。

4. **修正并保留了一条我自己加的非必需测试**（不在 brief 的 5 项硬性证据里）：
   最初写的 `test_copy_one_mid_stream_charge_rejects_and_refunds` 因为文件总
   大小本身就超过 `--max-bytes`，实际上每次都在 `precheck` 那一步被提前拦下，
   从未走到「逐块扣减」，是一条名不副实、和旁边 precheck 测试重复的测试。
   发现后改造成 `test_copy_one_charge_enforces_independently_of_precheck`：
   用「读出来的字节比 `stat` 当时量到的还多」的桩，模拟源文件挂在正在导出的
   SMB 上、`stat` 读到的大小可能陈旧的真实场景，证明 `charge()` 是独立于
   `precheck()` 的第二道闸、不是死代码。这条不在 brief 硬性要求里，但既然
   写了就不能让它撒谎，已用独立提交记录这次订正
   （`e2446778 修正一条被 precheck 提前拦截、名不副实的测试`）。

5. **`ByteBudget.refund` 超额退还抛 `ValueError`**（brief 未提及具体异常类型，
   spike 用的是 `assert`）。`assert` 在 `-O` 优化模式下会被整段跳过，这是我
   自己新写的类型的自身不变量校验，改成显式 `raise ValueError` 更稳妥，
   不属于对既有代码的改动。
