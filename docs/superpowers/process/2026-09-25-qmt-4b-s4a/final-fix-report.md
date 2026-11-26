# S4a 整支评审 · 最终修复轮报告（2026-09-20）

## 0 · 位置

```
$ cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a" \
    && git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
e57ba4ef
```

修复后：

```
51d9c143 补第三条分支：`.part` 是 FIFO 且另一端已挂读者时 open 会**成功**
2494e4ba 变异自查订正：超时闸改用 BaseException 子类（TimeoutError 是 OSError，会被洗成期望答案）
0a71a9c8 整支评审修复第 4 轮：.part 纳入 staging 篡改纪律 + 四条零判别力的闸门补钉
e57ba4ef （修复前的 HEAD）
```

HEAD = `51d9c143d84f1d9757ee53f9c13c61c09cfda022`，**未 push**。

## 1 · 测试总数

| | 命令 | 结果 |
|---|---|---|
| 修复前 | `cd backend && ../.venv/bin/python -m pytest tests/ -q -rs` | **1557 passed**，0 skipped |
| 修复后 | 同上 | **1570 passed**，0 skipped（`-rs` 无任何 skip 行） |

新增 13 条测试（`tests/test_qmt_fetch.py` 从 52 条增至 65 条）。

五个禁改模块对 `main` **逐字节未变**（`git diff --quiet main -- backend/<f>` 全部安静）：
`qmt_fsroot.py` / `qmt_manifest.py` / `qmt_pool.py` / `qmt_ingest.py` / `qmt_normalize.py`。

---

## 2 · 逐条 finding 的改动

### Critical 1 · `.part` 拿不到 staging 侧的篡改纪律

**改了什么**（`backend/qmt_fetch.py`）：

1. 新增 `_part_is_non_regular(stg_fd, rel)`：逐段无跟随走到父目录再 `lstat`
   叶子（**不用** `os.stat(多分量路径)`——那会跟随中间分量的符号链接），
   回答「`<rel>.part` 那个名字底下现在是不是一个非普通文件」；看不到一律
   `False`，**不猜**。
2. 新增 `_open_part(stg_fd, rel, *, flags, create_dirs=False)`，收成本模块
   **唯一**的 `.part` 打开点，`copy_one` 原来的两处 `open_under`（写 `:263` /
   复算重读 `:285`）全部改走它。它做三件事：
   - `flags | os.O_NONBLOCK`（FIFO 不再阻塞）；
   - `except IsADirectoryError` → `StockCopyFailed("untracked_target_file")`；
   - 其余 `OSError` 先回头 `_part_is_non_regular`：是非普通文件 →
     `untracked_target_file`，否则**原样上抛**（`PermissionError`/`EIO`/`ENOSPC`
     不许被混进来）；打开成功后再 `os.fstat` 查一次 `S_ISREG`，最后清掉
     `O_NONBLOCK`。
3. `_cleanup_part` 删之前先问一次类型：非普通文件**原样留着、不删不碰**。

**为什么不直接用 `qmt_fsroot.open_regular_probe`**（那条纪律的登记处）：写侧
这一次必须 `create_dirs=True`（staging 的 `1m/` / `daily/` 子目录正是本模块
第一次写 `.part` 时创建的），而 `open_regular_probe` 不转发这个参数，而
`qmt_fsroot` 是本片的禁改模块。故把同一条纪律在 `qmt_fetch` 内收成一个函数、
两个打开点都只经它——**不是**在第四处内联一份。

**家族选择（本简报未回答、我做的决定）：`untracked_target_file`。**
D3 的判据是「这只股能不能继续」，不是「影响面多大」；而 D3 自己就把两侧分开
写死了：「源侧那只股没有可用源文件（跳过它）；**staging 侧那个对象来路不明
（不许覆盖它，跳过该股）**」。`<rel>.part` 是 **staging 侧**的对象，且影响面
只到这一只股（路径里含股票代码），所以它与 D2 对 final 的处置属同一族，
**不新增第五个 `reason`**。符号链接仍由 `open_under` 逐段无跟随抛
`PathEscapeError`（整次致命），**不**归本族。

**`_cleanup_part` 那一条不是顺手改的**：失败收尾对两条 `.part` 各调一次
`_cleanup_part`，而 `os.unlink` 对一个目录抛 `EPERM`（macOS 实测）/`EISDIR`
（Linux）——它会**顶替掉**刚刚定性好的 `StockCopyFailed`，把候选失败变回一个
不属于任何一族的裸 `OSError`。即简报里「植目录得到裸 `IsADirectoryError`」这条
在事务层有第二个独立成因，只修打开点修不完。

**新增测试**（6 条）：
`test_copy_one_fifo_at_part_is_untracked_target_file_not_a_hang` /
`test_copy_one_fifo_with_a_reader_at_part_opens_but_is_still_untracked` /
`test_copy_one_directory_at_part_is_untracked_target_file` /
`test_copy_one_symlinked_part_escapes_and_is_not_untracked` /
`test_copy_stock_fifo_at_part_fails_closed_without_hanging` /
`test_copy_stock_directory_at_part_fails_closed_and_keeps_the_failure_reason`

### Critical 2 · 事务层那道 untracked 闸零判别力

**改了什么**：只加测试，`copy_stock:664`（现 `:774`）那行代码一个字没动。

补的两档**必须在 `copy_stock` 这一层**、且**目录与 FIFO 各一档**，并且都用
「**无记录**」那一格。最后这一点是我的决定，理由：D2 验收那句话的论据是
「只测 FIFO 会全绿，因为 FIFO 的 `os.replace` **本来就成功**」——要让这个论据
在测试里真的成立，闸门被拆掉时控制流必须**走到 `os.replace`**。有记录时
D4 第 2 条的落地前比对会先一步拦下（`SourceChangedMidRun`），`os.replace`
那一幕根本演不到，判别力被邻居遮住。实测（见 M4）闸门被拆掉后：
- 目录那档 → `os.replace` 抛 `IsADirectoryError`，**而在途标记已经写在盘上**
  （E6 的原始现场）；
- FIFO 那档 → `os.replace` **成功**、这只股照常 `committed` → `DID NOT RAISE`
  ——来路不明的对象被静默覆盖，正是 D2 存在的理由。

⚠️ D2 验收另有一句「必须构造记录的 `bytes` 恰等于那个非普通对象的 `st_size`」。
那条判据针对的是 `classify_target`（会不会先比字节数再查 `S_ISREG`），
在那一层**已有两档**（`test_classify_target_directory_with_record_matching_st_size_is_untracked`
/ `..._fifo_...`）。`copy_stock` 这一层不做任何尺寸比较，故该构造在这一层
不增加判别力，我没有重复它。

**新增测试**（2 条）：`test_copy_stock_rejects_directory_at_final_target` /
`test_copy_stock_rejects_fifo_at_final_target`。

### Important 1 · 标记可以在提交之前被删掉而无人喊

**改了什么**：只加测试，`copy_stock` 末尾三行次序一个字没动。两条分别钉住
次序的两半：

- `test_copy_stock_removes_marker_only_after_commit_succeeds`：给
  `qmt_fetch.commit_stock` 挂探针，**提交执行的那一刻**标记必须在盘上；
  提交成功之后必须被删掉。
- `test_copy_stock_keeps_marker_when_commit_fails`：把 `commit_stock` 打桩成
  抛异常，异常必须原样逃出，**且标记必须还在盘上**，两个 final 也确实已落地
  ——后者不是顺带一提，它正是「标记必须活着」的理由（那两个孤儿唯一的回滚凭据）。

### Important 2 · 真正写到盘上的标记内容从未被看过一眼

**改了什么**：只加测试。`test_copy_stock_marker_payload_on_disk_matches_builder`
借用既有的 `os.replace` 探针窗口（标记已写、第一个 final 还没换过去），把
`.inflight.json` 从盘上 `json.loads` 回来，与 `build_inflight_marker(slot,
rel_1m, rel_daily)` 的输出**逐字比对**（`started_at` 单独断言是非空字符串后
两边各自 `pop` 掉）。这一条把「形状测试只跑构造函数」与「在途测试只调
`.exists()`」两条原本不相交的路径接上了。

### Important 3 · 异常分类的穷尽性主张是假的

**改了什么**（`qmt_fetch.py` 模块 docstring `:29-35` 那段）：

- 计数订正：「以下**两种**」→「另有**三种**」，并写明订正来历。
- 第三种＝**裸 `OSError`**（`PermissionError` / `EIO` / `ENOSPC`），并给出规则：
  1. 本模块**不定性**它——不折成 `fetch_missing_file`（D3 明禁），也不包装成
     `RunTerminated`，**原样上抛**；
  2. 本模块对它**只给一条保证，而那是位置保证**：它只可能逃在**在途标记写下
     之前**，故逃出来那一刻盘上什么都没落（两个 `.part` 已删、预算已退还、
     manifest 一个字段没动）；
  3. 「跳过这只股」还是「终止整次运行」**交 S4b 定**，理由写在原处：两条路各有
     代价（无差别 `except OSError` 违反 D3；一路裸抛会让一个读不了的源文件用
     traceback 打死约 2 GiB 的运行），而定性需要「这是哪一只股、失败过几次」
     这类**只有续跑循环才有的上下文**；并明写 S4b **不得回头放宽**
     `_open_source_leaf` / `_open_part` 那两处 `except` 的宽度。
- 配一条可执行的钉子（不靠文档自称）：
  `test_copy_stock_bare_oserror_from_source_escapes_unclassified`。

⚠️ 这里有一个我做的判断：简报说「state the rule」，而给 S4b 选一条处置**超出
S4a 契约范围**（契约 §4「交接」没有这一项，D3 只管本模块内怎么 `except`）。
我写的规则因此是「本模块给什么保证 + 本模块不做什么 + 交接时不许怎么做」，
而不是替 S4b 选一条处置。如果你要的是后者，那要改契约，我停在这里没有改。

**C1 的回声同步**（按「订正的回声散在八处」逐类复核，共 5 处）：模块 docstring
的 reason 清单、`StockCopyFailed` 类文档、`copy_one` 文档的失败成因、
`copy_stock` 文档的失败/终止路径段、`_cleanup_part` 文档。

### 另加的两条

- **`_PERIODS`**：`qmt_fetch.py:423` 的元组保留原样（它同时还承载 D1 钉死的
  次序，直接改成 `= PERIODS` 会把次序悄悄交给别的模块），改为加一条测试
  `test_periods_tuple_agrees_with_qmt_manifest` 断言
  `qmt_fetch._PERIODS == qmt_manifest.PERIODS == ("1m", "daily")`，
  外加一句指向该测试的注释（注释不自称是强制，强制在测试里）。
- **契约 §1 证据指针**：`.superpowers/sdd/2026-09-18-qmt-4b-s4a/` →
  `docs/superpowers/evidence/2026-09-18-qmt-4b-s4a/`。**全仓只此一处活引用**
  （`/usr/bin/grep -rn` 另一处命中在 `.superpowers/sdd/.../review-*.diff` 里，
  那是评审快照产物，没动）。这是本轮唯一的 spec 改动，只改了这一句。

---

## 3 · 我自己栽的一跤（必须记进来）

**第一版的超时闸把变异洗成了绿的。**

C1 的变异（拿掉 `O_NONBLOCK`）不会让任何断言失败——它会让 `os.open(O_WRONLY)`
永远等一个写入方。所以我给两条 FIFO 测试加了 `SIGALRM` 闸，处理函数抛
`TimeoutError`。实测 M1：**2 passed in 10.25s**。

10.25 秒 ≈ 2 × 5 秒，即两条测试**都真的挂满了整个超时窗口，然后报绿**。
根因：`TimeoutError` **是 `OSError` 的子类**。它从阻塞的 `os.open` 里冒出来后，
被 `open_under` 的 `except OSError` 接住、原样再抛，再被 `_open_part` 的
`except OSError` 接住，回头 `lstat` 一看「那确实是个 FIFO」⇒ 变成
`StockCopyFailed("untracked_target_file")` —— **与实现正确时的结论一模一样**。

改成不继承 `Exception` 的 `_DeadlineExceeded(BaseException)` 之后，M1 变红
（见下）。⚠️ 这一跤的形态是本仓已登记的「**同一个思维盲点同时污染实现与验证**」：
我在实现里刚写完「非普通文件一律折成 `untracked_target_file`」，紧接着在验证
工具里用了一个会被这条规则吃掉的信号类型，而两处都是我自己写的。

---

## 4 · 变异证据（11 组，全部红）

共同口径：变异施加前断言**锚点恰好命中一次**（不等于 1 直接中止，结果一律
不可信）；施加后打印 `git diff` 再信任任何结果；`__pycache__` **变异前后各清
一次**；`PYTHONDONTWRITEBYTECODE=1` + `-p no:cacheprovider`；只选目标测试、
**邻居全部 deselect**；还原后逐字节比对确认复原。

命令（`/private/tmp/.../scratchpad/run_all.py` 驱动，每组等价于）：

```
find . -name __pycache__ -type d -prune -exec rm -rf {} +
<施加变异>
git diff -- qmt_fetch.py
PYTHONDONTWRITEBYTECODE=1 ../.venv/bin/python -m pytest -q -p no:cacheprovider --tb=line <选中的测试>
<还原> ; find . -name __pycache__ -type d -prune -exec rm -rf {} +
```

    ===== 变异 M1 · C1 · _open_part 去掉 O_NONBLOCK · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -311,7 +311,7 @@ def _open_part(stg_fd: int, rel: str, *, flags: int, create_dirs: bool = False)
    -        fd = open_under(stg_fd, name, flags=flags | os.O_NONBLOCK,
    +        fd = open_under(stg_fd, name, flags=flags,
    ===== 变异 M1 · C1 · _open_part 去掉 O_NONBLOCK · pytest ['tests/test_qmt_fetch.py::test_copy_one_fifo_at_part_is_untracked_target_file_not_a_hang', 'tests/test_qmt_fetch.py::test_copy_stock_fifo_at_part_fails_closed_without_hanging'] =====
    FF                                                                       [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/tests/test_qmt_fetch.py:1363: tests.test_qmt_fetch._DeadlineExceeded: 超过 5.0 秒仍未返回：疑似阻塞在一个被植入的 FIFO 上
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/tests/test_qmt_fetch.py:1363: tests.test_qmt_fetch._DeadlineExceeded: 超过 5.0 秒仍未返回：疑似阻塞在一个被植入的 FIFO 上
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_one_fifo_at_part_is_untracked_target_file_not_a_hang
    FAILED tests/test_qmt_fetch.py::test_copy_stock_fifo_at_part_fails_closed_without_hanging
    2 failed in 10.27s
    
    ===== 变异 M1 · C1 · _open_part 去掉 O_NONBLOCK · rc=1 =====
    ===== 变异 M1 · C1 · _open_part 去掉 O_NONBLOCK · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M2 · C1 · .part 是目录时不再定性（原样上抛 IsADirectoryError） · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -313,8 +313,8 @@ def _open_part(stg_fd: int, rel: str, *, flags: int, create_dirs: bool = False)
    -    except IsADirectoryError as e:
    -        raise StockCopyFailed("untracked_target_file", f"{name}: 是一个目录") from e
    +    except IsADirectoryError:
    +        raise
    ===== 变异 M2 · C1 · .part 是目录时不再定性（原样上抛 IsADirectoryError） · pytest ['tests/test_qmt_fetch.py::test_copy_one_directory_at_part_is_untracked_target_file', 'tests/test_qmt_fetch.py::test_copy_stock_directory_at_part_fails_closed_and_keeps_the_failure_reason'] =====
    FF                                                                       [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/qmt_fsroot.py:362: IsADirectoryError: [Errno 21] Is a directory: '600000.SH_x_1分钟K线_前复权.csv.part'
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/qmt_fsroot.py:362: IsADirectoryError: [Errno 21] Is a directory: '600000.SH_x_1分钟K线_前复权.csv.part'
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_one_directory_at_part_is_untracked_target_file
    FAILED tests/test_qmt_fetch.py::test_copy_stock_directory_at_part_fails_closed_and_keeps_the_failure_reason
    2 failed in 0.22s
    
    ===== 变异 M2 · C1 · .part 是目录时不再定性（原样上抛 IsADirectoryError） · rc=1 =====
    ===== 变异 M2 · C1 · .part 是目录时不再定性（原样上抛 IsADirectoryError） · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M3 · C1 · _cleanup_part 去掉删前的类型闸 · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -607,8 +607,6 @@ def _cleanup_part(stg_fd: int, rel: str) -> None:
    -    if _part_is_non_regular(stg_fd, rel):
    -        return
    ===== 变异 M3 · C1 · _cleanup_part 去掉删前的类型闸 · pytest ['tests/test_qmt_fetch.py::test_copy_stock_directory_at_part_fails_closed_and_keeps_the_failure_reason'] =====
    F                                                                        [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/qmt_fetch.py:616: PermissionError: [Errno 1] Operation not permitted: '600000.SH_x_1分钟K线_前复权.csv.part'
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_stock_directory_at_part_fails_closed_and_keeps_the_failure_reason
    1 failed in 0.22s
    
    ===== 变异 M3 · C1 · _cleanup_part 去掉删前的类型闸 · rc=1 =====
    ===== 变异 M3 · C1 · _cleanup_part 去掉删前的类型闸 · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M10 · C1 · 拿掉「打开成功之后」那句 S_ISREG · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -327,7 +327,7 @@ def _open_part(stg_fd: int, rel: str, *, flags: int, create_dirs: bool = False)
    -        if not _is_regular(os.fstat(fd)):
    +        if False and not _is_regular(os.fstat(fd)):
    ===== 变异 M10 · C1 · 拿掉「打开成功之后」那句 S_ISREG · pytest ['tests/test_qmt_fetch.py::test_copy_one_fifo_with_a_reader_at_part_opens_but_is_still_untracked'] =====
    F                                                                        [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/tests/test_qmt_fetch.py:1417: Failed: DID NOT RAISE <class 'qmt_fetch.StockCopyFailed'>
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_one_fifo_with_a_reader_at_part_opens_but_is_still_untracked
    1 failed in 0.22s
    
    ===== 变异 M10 · C1 · 拿掉「打开成功之后」那句 S_ISREG · rc=1 =====
    ===== 变异 M10 · C1 · 拿掉「打开成功之后」那句 S_ISREG · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M11 · C1 · _part_is_non_regular 恒返回 False · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -281,7 +281,7 @@ def _part_is_non_regular(stg_fd: int, rel: str) -> bool:
    -    return not _is_regular(st)
    +    return False
    ===== 变异 M11 · C1 · _part_is_non_regular 恒返回 False · pytest ['tests/test_qmt_fetch.py::test_copy_one_fifo_at_part_is_untracked_target_file_not_a_hang', 'tests/test_qmt_fetch.py::test_copy_stock_fifo_at_part_fails_closed_without_hanging', 'tests/test_qmt_fetch.py::test_copy_stock_directory_at_part_fails_closed_and_keeps_the_failure_reason'] =====
    FFF                                                                      [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/qmt_fsroot.py:362: OSError: [Errno 6] Device not configured: '600000.SH_x_1分钟K线_前复权.csv.part'
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/qmt_fsroot.py:362: OSError: [Errno 6] Device not configured: '600000.SH_x_1分钟K线_前复权.csv.part'
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/qmt_fetch.py:618: PermissionError: [Errno 1] Operation not permitted: '600000.SH_x_1分钟K线_前复权.csv.part'
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_one_fifo_at_part_is_untracked_target_file_not_a_hang
    FAILED tests/test_qmt_fetch.py::test_copy_stock_fifo_at_part_fails_closed_without_hanging
    FAILED tests/test_qmt_fetch.py::test_copy_stock_directory_at_part_fails_closed_and_keeps_the_failure_reason
    3 failed in 0.24s
    
    ===== 变异 M11 · C1 · _part_is_non_regular 恒返回 False · rc=1 =====
    ===== 变异 M11 · C1 · _part_is_non_regular 恒返回 False · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M4 · C2 · 事务层 untracked 闸禁用 · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -774,7 +774,7 @@ def copy_stock(src_fd: int, stg_fd: int, slot: Slot, rel_1m: str, rel_daily: str
    -    if TARGET_UNTRACKED in verdicts:
    +    if False and TARGET_UNTRACKED in verdicts:
    ===== 变异 M4 · C2 · 事务层 untracked 闸禁用 · pytest ['tests/test_qmt_fetch.py::test_copy_stock_rejects_directory_at_final_target', 'tests/test_qmt_fetch.py::test_copy_stock_rejects_fifo_at_final_target'] =====
    FF                                                                       [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/qmt_fetch.py:633: IsADirectoryError: [Errno 21] Is a directory: '600000.SH_x_1分钟K线_前复权.csv.part' -> '600000.SH_x_1分钟K线_前复权.csv'
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/tests/test_qmt_fetch.py:1581: Failed: DID NOT RAISE <class 'qmt_fetch.StockCopyFailed'>
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_stock_rejects_directory_at_final_target
    FAILED tests/test_qmt_fetch.py::test_copy_stock_rejects_fifo_at_final_target
    2 failed in 0.24s
    
    ===== 变异 M4 · C2 · 事务层 untracked 闸禁用 · rc=1 =====
    ===== 变异 M4 · C2 · 事务层 untracked 闸禁用 · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M5 · I1 · 删标记挪到 commit_stock 之前 · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -817,6 +817,6 @@ def copy_stock(src_fd: int, stg_fd: int, slot: Slot, rel_1m: str, rel_daily: str
    -    committed = commit_stock(stg_fd, new_manifest, ledger=ledger)
    +    committed = commit_stock(stg_fd, new_manifest, ledger=ledger)
    ===== 变异 M5 · I1 · 删标记挪到 commit_stock 之前 · pytest ['tests/test_qmt_fetch.py::test_copy_stock_removes_marker_only_after_commit_succeeds', 'tests/test_qmt_fetch.py::test_copy_stock_keeps_marker_when_commit_fails'] =====
    FF                                                                       [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/tests/test_qmt_fetch.py:1627: AssertionError: commit_stock 执行的那一刻，在途标记必须还在盘上——删标记只能排在提交**成功之后**（契约 D6）
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/tests/test_qmt_fetch.py:1658: AssertionError: 提交失败时在途标记必须留在盘上——它是两个孤儿 final 唯一的回滚凭据
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_stock_removes_marker_only_after_commit_succeeds
    FAILED tests/test_qmt_fetch.py::test_copy_stock_keeps_marker_when_commit_fails
    2 failed in 0.24s
    
    ===== 变异 M5 · I1 · 删标记挪到 commit_stock 之前 · rc=1 =====
    ===== 变异 M5 · I1 · 删标记挪到 commit_stock 之前 · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M6 · I2 · 标记 payload 掏空成 {"code": slot.code} · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -643,7 +643,7 @@ def _write_inflight_marker(stg_fd: int, slot: Slot, rel_1m: str, rel_daily: str)
    -    atomic_write_json(stg_fd, INFLIGHT, build_inflight_marker(slot, rel_1m, rel_daily))
    +    atomic_write_json(stg_fd, INFLIGHT, {"code": slot.code})
    ===== 变异 M6 · I2 · 标记 payload 掏空成 {"code": slot.code} · pytest ['tests/test_qmt_fetch.py::test_copy_stock_marker_payload_on_disk_matches_builder'] =====
    F                                                                        [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/tests/test_qmt_fetch.py:1705: AssertionError: 盘上那份标记缺少（或写坏了）started_at：{'code': '600000.SH'}
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_stock_marker_payload_on_disk_matches_builder
    1 failed in 0.23s
    
    ===== 变异 M6 · I2 · 标记 payload 掏空成 {"code": slot.code} · rc=1 =====
    ===== 变异 M6 · I2 · 标记 payload 掏空成 {"code": slot.code} · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M7 · I2 · 构造函数两个路径实参对调 · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -643,7 +643,7 @@ def _write_inflight_marker(stg_fd: int, slot: Slot, rel_1m: str, rel_daily: str)
    -    atomic_write_json(stg_fd, INFLIGHT, build_inflight_marker(slot, rel_1m, rel_daily))
    +    atomic_write_json(stg_fd, INFLIGHT, build_inflight_marker(slot, rel_daily, rel_1m))
    ===== 变异 M7 · I2 · 构造函数两个路径实参对调 · pytest ['tests/test_qmt_fetch.py::test_copy_stock_marker_payload_on_disk_matches_builder'] =====
    F                                                                        [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/tests/test_qmt_fetch.py:1709: AssertionError: 真正写到盘上的标记内容必须与 build_inflight_marker 的输出逐字相同（除 started_at 外）——实测盘上是 {'code': '600000.SH', 'universe_idx': 0, 'targets': ['daily/600000.SH_x_日K线_前复权.csv', '1m/600000.SH_x_1分钟K线_前复权.csv'], 'parts': ['daily/600000.SH_x_日K线_前复权.csv.part', '1m/600000.SH_x_1分钟K线_前复权.csv.part']}，期望 {'code': '600000.SH', 'universe_idx': 0, 'targets': ['1m/600000.SH_x_1分钟K线_前复权.csv', 'daily/600000.SH_x_日K线_前复权.csv'], 'parts': ['1m/600000.SH_x_1分钟K线_前复权.csv.part', 'daily/600000.SH_x_日K线_前复权.csv.part']}
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_stock_marker_payload_on_disk_matches_builder
    1 failed in 0.23s
    
    ===== 变异 M7 · I2 · 构造函数两个路径实参对调 · rc=1 =====
    ===== 变异 M7 · I2 · 构造函数两个路径实参对调 · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M8 · I3 · 源侧打开点放宽成 except OSError · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -257,7 +257,7 @@ def _open_source_leaf(src_fd: int, rel: str):
    -    except NotARegularFileError as e:
    +    except OSError as e:
    ===== 变异 M8 · I3 · 源侧打开点放宽成 except OSError · pytest ['tests/test_qmt_fetch.py::test_copy_stock_bare_oserror_from_source_escapes_unclassified'] =====
    F                                                                        [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/qmt_fetch.py:261: qmt_fetch.StockCopyFailed: fetch_missing_file: 1m/600000.SH_x_1分钟K线_前复权.csv: [Errno 13] 打桩：模拟源文件读不了
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_copy_stock_bare_oserror_from_source_escapes_unclassified
    1 failed in 0.24s
    
    ===== 变异 M8 · I3 · 源侧打开点放宽成 except OSError · rc=1 =====
    ===== 变异 M8 · I3 · 源侧打开点放宽成 except OSError · 已还原（内容与变异前逐字节相同）=====
    ===== 变异 M9 · _PERIODS 与 qmt_manifest.PERIODS 分叉 · diff =====
    --- a/backend/qmt_fetch.py
    +++ b/backend/qmt_fetch.py
    @@ -524,7 +524,7 @@ INFLIGHT = ".inflight.json"
    -_PERIODS = ("1m", "daily")
    +_PERIODS = ("1m", "dayly")
    ===== 变异 M9 · _PERIODS 与 qmt_manifest.PERIODS 分叉 · pytest ['tests/test_qmt_fetch.py::test_periods_tuple_agrees_with_qmt_manifest'] =====
    F                                                                        [100%]
    =================================== FAILURES ===================================
    /Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/tests/test_qmt_fetch.py:1766: AssertionError: qmt_fetch._PERIODS=('1m', 'dayly') 与 qmt_manifest.PERIODS=('1m', 'daily') 分叉了
    =========================== short test summary info ============================
    FAILED tests/test_qmt_fetch.py::test_periods_tuple_agrees_with_qmt_manifest
    1 failed in 0.22s
    
    ===== 变异 M9 · _PERIODS 与 qmt_manifest.PERIODS 分叉 · rc=1 =====
    ===== 变异 M9 · _PERIODS 与 qmt_manifest.PERIODS 分叉 · 已还原（内容与变异前逐字节相同）=====

### 4.1 ⚠️ M5 的 diff 在上面那份日志里显示得会骗人

驱动脚本只保留 diff 里的 `+`/`-`/`@@` 行，把上下文行滤掉了；而 M5 是一次**行
互换**，git 把它渲染成「删掉 `commit_stock` 那行、在下面再加回来」，滤掉上下文
之后看起来像个空操作。它不是——重跑一次不做过滤的：

```
$ git diff -U3 -- qmt_fetch.py
@@ -817,6 +817,6 @@ def copy_stock(src_fd: int, stg_fd: int, slot: Slot, rel_1m: str, rel_daily: str
             _replace_part_to_final(stg_fd, rel)

     new_manifest = _apply_stock_records(manifest, slot, new_records, budget.used)
-    committed = commit_stock(stg_fd, new_manifest, ledger=ledger)
     _remove_inflight_marker(stg_fd)
+    committed = commit_stock(stg_fd, new_manifest, ledger=ledger)
     return "committed", committed

已还原（内容与变异前逐字节相同）
```

（锚点计数断言本来就保证了变异真的落盘，红也确实红了；记这一条是因为
「diff 看起来是空的」这件事本身就该当场停住，而不是事后解释。）

### 4.2 变异 ↔ finding 对照

| 变异 | 对应 finding | 变红的测试 |
|---|---|---|
| M1 去掉 `O_NONBLOCK` | C1（挂死） | 两条 FIFO 档，各挂满 5 秒超时窗 |
| M2 `.part` 是目录不再定性 | C1（裸 `IsADirectoryError`） | 两条目录档 |
| M3 `_cleanup_part` 去掉类型闸 | C1（收尾顶替掉已定性的异常） | `copy_stock` 目录档 |
| M10 拿掉打开成功后的 `S_ISREG` | C1（第三条分支） | FIFO+读者档 → **DID NOT RAISE**（整份 CSV 被灌进管子、复算又从管子读回、哈希相符 ⇒ 完全静默的数据丢失） |
| M11 `_part_is_non_regular` 恒 `False` | C1（分类判据本身） | 三条 |
| M4 事务层 untracked 闸禁用 | C2 | 目录档撞 `IsADirectoryError`（标记已写）；FIFO 档 **DID NOT RAISE**（静默提交） |
| M5 删标记挪到提交之前 | I1 | 两条 |
| M6 标记 payload 掏空 | I2 | 一条 |
| M7 构造函数两路径实参对调 | I2 | 一条 |
| M8 源侧 `except` 放宽成 `OSError` | I3 | 一条 |
| M9 `_PERIODS` 分叉 | 另加项 | 一条 |

---

## 5 · 简报没回答、由我决定的事（逐条）

1. **被篡改的 `.part` 归哪一族 → `untracked_target_file`。** 依据 D3 的
   「这只股能不能继续」＋ D3 自己写死的源侧/staging 侧分工。见 §2 Critical 1。
2. **`.part` 的打开点不走 `open_regular_probe`，而是在 `qmt_fetch` 内收成
   `_open_part`。** 因为写侧必须 `create_dirs=True`，而 `open_regular_probe`
   不转发该参数、`qmt_fsroot` 禁改。纪律本身（`O_NONBLOCK` + `S_ISREG` +
   打不开就回头 `lstat`）逐条照搬，且本模块内**只此一处**。
3. **`_cleanup_part` 对非普通 `.part` 原样留着、不删不碰**（而不是 `rmdir` 掉）。
   与 D2 对 final 的处置同一条；顺带使收尾不会顶替掉已定性的异常。
4. **C2 的两档用「无记录」那一格**，而不是「有记录 + `bytes == st_size`」。
   理由见 §2 Critical 2（要让 D2 验收自带的那个论据在测试里真的可达）。
5. **I3 的「规则」写成「本模块给什么保证 + 交接时不许怎么做」，没有替 S4b
   选处置。** 选处置会越过契约 §4 的交接清单，属于改契约。
6. **`_PERIODS` 用测试而不是 import 期断言收口。** import 期硬失败会把一次
   分叉变成整模块收集错误，红是红了，但「哪条判据红的」看不见；且
   `_PERIODS` 同时承载 D1 的次序，直接 `= PERIODS` 会把次序悄悄外包。
7. **新增 `import fcntl`**（清 `O_NONBLOCK`，与 `qmt_fsroot._open_regular_probe`
   同规格）。对普通文件这一步没有可观察效果，留着是为了纪律逐条对齐。
8. **新增 `_DeadlineExceeded(BaseException)` 超时闸**（测试侧）。见 §3。

## 6 · 明确没碰（简报列为 deferred）

`copy_one` 复算循环与 `_hash_target` 的重复；证据 harness 写死主仓路径与
`FACTS.md` 的模块清单；标记创建次序屏障；`MaxBytesExhausted` 没走完整条事务。

## 7 · 仍在的已知残留（不是本轮范围）

- 契约 §3 的 R1（`qmt_manifest` 转移守卫与崩溃恢复第③档冲突，重拉重复计账）
  —— 已拍板另开独立 PR。
- 契约 §4 交接 8：D2 有记录那半边会让一只股同时出现在 `pool_order`+`files`
  与 `failures` 里。
- **本轮新增一条交接**（写在模块 docstring 里，见 §2 Important 3）：裸
  `OSError` 的处置由 S4b 定。它此前是**没有**出路的，现在是一条**写明了的**
  待决项——性质变了，但它还没被解决。

---

# fix round 5（收尾轮，user 明确授权的额外一轮）

**位置**：worktree `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a`，
分支 `qmt-4b-s4a`，起点 HEAD `51d9c143`。
**基线**：全套 1570 passed / 0 skipped ⇒ 本轮之后 **1575 passed / 0 skipped**（新增 5 项）。
**改动文件三个**：`backend/qmt_fetch.py`、`backend/tests/test_qmt_fetch.py`、
`docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md`。
**五个禁改模块**（`qmt_fsroot` / `qmt_manifest` / `qmt_pool` / `qmt_ingest` /
`qmt_normalize`）对 `51d9c143` **逐字节未改**（`git diff --quiet` 逐个核过）。

## A · `_open_part` 的窄 `except` 纪律此前零覆盖

模块头把「`_open_source_leaf` 与 `_open_part` 的窄 `except` 就是这条判据本身，
各有测试钉着」当规则写着，**而 staging 侧那条根本不存在**。

**复现（修复前）**：`qmt_fetch.py:324` 的 `if _part_is_non_regular(stg_fd, rel):`
改成 `if True:`（＝「`.part` 打不开就一律当成篡改」，正是那条规则明禁的放宽）
⇒ 本模块 **65 passed**、全套 **1570 passed**，**零红**。

**修复**：新增 `test_open_part_bare_oserror_escapes_and_is_not_called_tampering`
（参数化三档：`ENOSPC` staging 写满 / `EACCES` 权限 / `EIO` SMB 断线）。
打桩挂在 `qmt_fetch.open_under` —— 它在本模块里**只有 `_open_part` 一个消费者**，
归因唯一；桩自己断言 `relpath.endswith(".part")`。
测试先把 `1m/` `daily/` 两个子目录建好，使 `_part_is_non_regular` 真的走到
`os.stat` 并如实答「那底下什么都没有」，而不是在 `parent_fd_under` 抄近路；
并显式断言这个前提（否则本档会变成在测「确实是篡改」）。

⚠️ **注入信号的可捕获性已核**：注入的**就是**裸 `OSError`，而被测的那句
`except OSError` 接住它之后的**分支结论可区分**——实现正确时原样再抛（测试期望
`OSError`），实现放宽时变成 `StockCopyFailed`。不存在「桩被洗成期望答案」那种
形态（上一轮 `TimeoutError` 是 `OSError` 子类那个坑，在这里不适用：这里要证的
恰恰是「它应该以 `OSError` 的身份逃出来」）。

**变异 M-A 实测**（`__pycache__` 前后各清一次、锚点命中计数断言 = 1、先打 diff 再信结果）：

```
$ ../.venv/bin/python $SP/mutate.py qmt_fetch.py "        if _part_is_non_regular(stg_fd, rel):" "        if True:"
[mutate] anchor 命中次数 = 1
[mutate] 已写入
$ git diff -- qmt_fetch.py | grep -E "^[-+]        if "
-        if _part_is_non_regular(stg_fd, rel):
+        if True:
```

整模块（看是否只有新钉变红、邻居有没有被牵连）：

```
.................................................................FFF..   [100%]
FAILED tests/test_qmt_fetch.py::test_open_part_bare_oserror_escapes_and_is_not_called_tampering[28-staging 写满]
FAILED tests/test_qmt_fetch.py::test_open_part_bare_oserror_escapes_and_is_not_called_tampering[13-权限不足]
FAILED tests/test_qmt_fetch.py::test_open_part_bare_oserror_escapes_and_is_not_called_tampering[5-SMB 断线]
3 failed, 67 passed in 0.45s
```

**邻居全 deselect、只跑新钉**，红的理由逐字如下（＝「红得对」）：

```
$ pytest "tests/test_qmt_fetch.py::test_open_part_bare_oserror_escapes_and_is_not_called_tampering" -q
            if True:
>               raise StockCopyFailed(
                    "untracked_target_file", f"{name}: 存在但不是普通文件（打不开）"
                ) from e
E               qmt_fetch.StockCopyFailed: untracked_target_file: 1m/600000.SH_x_1分钟K线_前复权.csv.part: 存在但不是普通文件（打不开）
qmt_fetch.py:344: StockCopyFailed
3 failed in 0.35s
```

还原后 `cmp` 逐字节相同、70 passed。

## B · 失败收尾的类型闸，两个方向此前都没有测试

**裁决（controller 定案，不再讨论）**：保持当前行为——`_part_is_non_regular`
走 `lstat`，符号链接一并算「非普通」，`_cleanup_part` 原样留着不删（fail-closed）。
但它必须**不再是意外**。

**做了两件事**：

1. **把「故意」写在 `_cleanup_part` 的 docstring 里**（读 `_cleanup_part` 的人
   会看到的那一处），含三层：①它为什么**不与契约 §2 D2 的「非普通文件不含符号
   链接」冲突**——D2 裁的是**覆盖裁决**（能不能被当成重拷目标覆盖掉），本函数裁
   的是**失败收尾删不删**，对象/时机/后果都不同；②取舍与**代价明写**（同一处
   植入会让后续每次运行都死在同一个 `PathEscapeError` 上，直到有人去看一眼）；
   ③**大 spec §4.5 步骤 1「失败即删掉这只股的两个 `.part`」在 S4a 范围内被收窄，
   且只收窄「被篡改」那一档**。
2. **两个方向各补一条测试**：
   `test_cleanup_keeps_a_planted_symlink_at_part` /
   `test_cleanup_still_removes_an_ordinary_part_on_the_failure_path`。

⚠️ 第二条**不是**`test_copy_stock_daily_missing_leaves_no_orphan_1m_final` 的重复：
那条只断言收尾之后 `.part` 不在，**没有证明它曾经在过**（`.part` 压根没被写出来
时它一样绿）。新钉用一个挂在 `_open_source_leaf` 上的中途探针先把「事务中途它
真的在盘上」断言成 `midway == [True]`，「收尾把它删了」这句话才有判别力。

**变异 M-B1（闸拆掉：`if False:`）**，邻居全 deselect、只跑符号链接那一档：

```
[mutate] anchor 命中次数 = 1
-    if _part_is_non_regular(stg_fd, rel):
+    if False:
>       assert part_1m.is_symlink(), (
E       AssertionError: 植进 <rel>.part 的符号链接必须原样留着——本工具不替篡改者把证据顺手删掉，也不 unlink 一个可能指向 staging 树外的名字（fail-closed）
E       assert False
E        +  where False = is_symlink()
tests/test_qmt_fetch.py:1881: AssertionError
1 failed in 0.27s
```

（同一变异整模块跑是 3 failed / 67 passed：另外两条是既有的目录/FIFO 档 ——
正因为它们会被牵连，符号链接这一档**必须**单独跑才证得出判别力。）

**变异 M-B2（一律不删：`if True:`）**，邻居全 deselect、只跑普通 `.part` 那一档：

```
[mutate] anchor 命中次数 = 1
-    if _part_is_non_regular(stg_fd, rel):
+    if True:
        assert midway == [True], (...)          # 前提通过：.part 中途确实在盘上
>       assert not part_1m.exists() and not part_1m.is_symlink(), (
E       AssertionError: 普通 .part 是本工具自己写下的残留——收尾必须删掉它。符号链接那一档的豁免只收窄「被篡改」那一格，不是把整条删除规则关掉
E       assert (not True)
E        +  where True = exists()
tests/test_qmt_fetch.py:1922: AssertionError
1 failed in 0.27s
```

两次变异还原后均 `cmp` 逐字节相同。

⚠️ **实测更正一条简报里的说法**：简报说「两个方向现在都没有测试」——
方向二（普通 `.part` 被删）其实**已被三条既有测试顺带覆盖**（`if True:` 变异下
`test_copy_stock_daily_missing_leaves_no_orphan_1m_final` 等 3 条会红）。
但它们都是**顺带断言**、且都有上面说的恒真风险，没有一条是**专门**守这条语义的。
按裁决照补，并在测试里写明它与邻居的区别。方向一（符号链接留着）确实**零覆盖**。

## Minor 三条

1. **`qmt_fetch.py:208` 的 `raise ValueError`（退还超过已扣）此前未被枚举**，
   而模块头的主张是「按 `raise` 语句逐条枚举」。
   **选了「枚举它」而不是「窄化主张」**（本仓判据：穷尽性主张必须按字面量枚举后
   逐条定性，「跑不到」是**定性**不是**不列**的理由）：「三种」→「**四种**」，
   并补一段把它定性为**本模块自身不变量的自查 · 在本模块调用路径上不可达**
   （`copy_one` 只退自己逐块累加的 `charged`、`copy_stock` 只退 `written` 里
   已扣未退的字节，两者恒 ≤ `budget.used`），只可能被「调用方跨事务复用同一个
   `ByteBudget`／中途把 `used` 改小」触发 ⇒ 与裸 `TypeError` 同族。
   ⚠️ 顺带核过：`qmt_fetch.py:223` 的 `raise OSError`（`os.write` 返回 ≤ 0）
   已被「第三种 · 裸 `OSError`」覆盖；`_validate_record` 的三条 `TypeError`
   已被「前两种 · 裸 `TypeError`」覆盖。
   ⚠️ **枚举方式**：用 `ast` 遍历整份模块（不是 grep 关键词——散文里也有「raise」），
   实测 **27 条 `raise`**（22 条显式 + 5 条裸 re-raise），按抛出类型归并后**恰好 7 种**：
   `StockCopyFailed` ×10 / `TypeError` ×5 / `QmtSchemaError` ×2 / `MaxBytesExhausted` ×2 /
   `SourceChangedMidRun` ×1 / `OSError` ×1 / `ValueError` ×1。
   对照「三族 + 四种」：三族吃掉 `StockCopyFailed`、`MaxBytesExhausted`、`SourceChangedMidRun`；
   四种吃掉 `TypeError`、`QmtSchemaError`、裸 `OSError`、`ValueError`；5 条裸 re-raise 不引入
   新类型。**无第五类**，主张现在逐字为真。

2. **位置保证那句绝对化的话已订正**。原文「它**只可能**逃在在途标记写下之前」
   是假的（两次 `os.replace`、`commit_stock`、删标记三处同样可能逃出裸 `OSError`），
   结论靠紧跟的括号才救回来。改为「**有前提的**位置保证」，把保证的适用范围
   （标记写下之前）与不适用范围（标记写下之后，按**位置**判据由调用方终止整次
   运行）各写一句。

3. **新交接项进了契约 §4 清单**（此前只活在模块 docstring 里，而 S4b 的执行者
   读的是那张清单）：新增 **第 10 条「裸 `OSError` 的处置由 S4b 选」**，原 10/11/12
   顺延为 **11/12/13**。
   ⚠️ **插在 S4b 那一组的末尾（第 10 条）而不是中间**，是为了让第 1–9 条编号不动：
   本目录 `final-fix-report.md`（上一节）与 `progress.md` 各有一处「契约 §4 交接 8」
   的引用，插在中间会把它们变成死引用。插入后用 `markdown_it` 的 commonmark 模式
   真渲染复核过：列表 13 项、第 10 项的 5 行续行全部落在该项内、无 `<pre>` 误判。

## 本轮的收口证据

- `cd backend && ../.venv/bin/python -m pytest tests/ -q -rs` → **1575 passed，0 skipped**。
- 三次变异（M-A / M-B1 / M-B2）**全部变红，且都在邻居 deselect 的条件下单独复现过**；
  每次变异前后各清一次 `__pycache__`、锚点命中计数断言 = 1、先打 diff 再信结果、
  还原后 `cmp` 逐字节相同。

## 仍在的已知残留（本轮未动，不是本轮范围）

与上一节 §7 相同：契约 §3 的 R1（独立 PR）、契约 §4 交接第 8 条。
**上一节 §7 末尾那条「本轮新增一条交接：裸 `OSError` 的处置由 S4b 定」已在本轮
落进契约 §4 清单的第 10 条** —— 它仍是一条待决项，但不再只活在代码注释里。

---

# 第 6 轮修复（codex `needs-attention` 的两条）· 2026-09-20

**分支 `qmt-4b-s4a`，修复前 HEAD `e812b62b`，本轮提交 `42aad694`（未 push）。**
全量：**1579 passed / 0 skipped**（修复前 1575，本轮 +4 条）。
五个禁改模块（`qmt_fsroot` / `qmt_manifest` / `qmt_pool` / `qmt_ingest` /
`qmt_normalize`）对 HEAD 的 diff 为空 —— 逐字节未动。

## C1 [high] · 植在 `<rel>.part` 上的硬链接被 `O_TRUNC` 截断，毁掉 staging 树外的文件

**先复现，再动手**（`copy_one` 直调，非测试桩）：staging 外一个 145 字节的文件，
`os.link` 到 `<rel>.part`：

```
S_ISREG(link) = True          ← 硬链接**就是**普通文件，S_ISREG 判据对它放行
same inode     = True
copy_one returned normally: 110 bytes     ← 没有任何异常
outside unchanged = False | len 110       ← 外部文件已被本次拷来的内容顶掉
```

`O_NOFOLLOW` 只挡符号链接、`S_ISREG` 只挡 FIFO/目录/socket，**两者都挡不住硬链接**；
`O_TRUNC` 在落地复校、回滚、事务编排**之前**就已经清空了链接对面那个文件。

**修法**：与 `qmt_fsroot._atomic_write_bytes`（本仓这条纪律的登记处，同一威胁在那里
栽过 R3 / R5 / R8 三次）逐条相同 —— **只写自己 `O_CREAT|O_EXCL` 刚造出来的 inode**
（`<rel>.part.<pid>.<随机>.tmp`），复算通过后 `os.replace` 发布成 `<rel>.part`：
`replace` 换的是**目录项**，不碰目标 inode 的字节，外部硬链接保有自己的数据。
修复后同一个复现脚本：`copy_one` 仍**正常返回**，`outside unchanged = True | len 145`。

三条配套决定（都写进了 docstring，不只活在这里）：

1. **「上一次运行崩在半路留下的普通 `.part`」是本 spec 自己产得出的合法状态**，
   照常被发布盖掉，**不**变成一次失败 —— 否则一次断电会让这只股此后每次重跑都
   死在同一处。`test_copy_one_publishes_over_an_ordinary_leftover_part` 钉住它，
   并顺带断言「盖法是发布新 inode，不是截断旧的」+「发布成功后不留临时文件」。
2. **写侧不再打开 `<rel>.part` ⇒ C1 第 4 轮那条纪律失去了顺带的落点**，
   新增 `_probe_part` 承担它（判据原样走 `_open_part`，不另立第二份）：
   符号链接 → `PathEscapeError`（整次致命）；FIFO/目录/socket →
   `untracked_target_file`；普通文件/不存在 → 正路。
3. **`_open_part` / `_part_is_non_regular` / `_cleanup_part` 改收完整相对名**
   —— 类型闸必须问「我马上要动的**那个**名字」，把 `.part` 拼接藏在函数里会让
   临时名那个消费者拿到另一个名字的答案。
   同时删掉 `except IsADirectoryError`：写侧不再 `O_WRONLY` 打开那个名字之后它
   **永不执行**（`O_RDONLY` 打开目录是成功的，`O_CREAT|O_EXCL` 撞目录给 `EEXIST`），
   目录改由只读探测 + `S_ISREG` 接住，`reason` 一个字不变。

## N1 [medium] · 标记发布之前失败 ⇒ 两个 `.part` 与预算双漏

`_write_inflight_marker` 此前裸在回滚处置之外。`atomic_write_json` 在
`os.replace` **之前**炸（创建/写临时文件撞 `ENOSPC` 等），两个已拷好的 `.part`
留在盘上、本次扣的账也不退，而**什么都没提交、也没有任何恢复凭据** ⇒ 调用方
接住那个裸 `OSError` 继续跑就可能撞一次**假的** `--max-bytes` 触顶（按大 spec §5
那是「干净的配额停止」⇒ pilot 放行 ⇒ 一次基础设施故障被记成一次正常结束，
正是已登记残留 R1 的喂料口）。

**修法**：分界按「**发布有没有发生**」，不是「写标记那个函数返回了没有」
（`_inflight_marker_on_disk`，`follow_symlinks=False`，**看不清一律算「已发布」**
—— 清理是破坏性的，宁可漏退一次预算，也不删掉一份可能还在授权回滚的凭据）：

- **发布之前**炸 ⇒ 与其它标记前失败路径**逐字同规格**：删两个 `.part`、
  退还本次已扣的账、原样上抛（盘上什么都没落、manifest 一个字段没动）；
- **发布之后**炸（紧跟的那次 `fsync(staging)` 撞 `EIO`）⇒ **D6 接管，一个字节都
  不清理、一分钱都不退**，标记原样留在盘上当回滚凭据，原样上抛。

**不新增第五个 `reason`，不放宽 D6**（D6 反而多了一条把它守住的测试）。
模块头那条「位置保证」的穷尽性主张同步订正：发布之后可能逃出裸 `OSError` 的
地方由三处补成**四处**（多的是写标记时发布之后那次 `fsync(staging)`）。

## 变异验证（4 组，每组：前后清 `__pycache__` → 锚点命中数断言 = 1 → 先打 diff → 邻居 deselect 单独跑）

| 变异 | 锚点 | 结果 |
|---|---|---|
| 还原成 `O_TRUNC` 直写 `<rel>.part`（含复算重读与删掉发布句） | 3 个，各命中 1 次 | 硬链接档**红**在「外部文件必须逐字节不变」（实测 `b'source-data…' == b'vvv…'` 不成立）；残留档**红**在「`.part` 必须是新 inode」（`44838517 != 44838517`） |
| 删掉 `_probe_part(stg_fd, rel)` | 1 个，命中 1 次 | FIFO 档 / 目录档 / 符号链接档**三条既有测试全红**（目录那档实测炸在 `_publish_part` 的 `os.replace` 上 —— E6 的原始现场） |
| 删掉整个写标记的 try/except 回滚处置 | 1 个，命中 1 次 | 「发布之前」档**红**在「发布没发生 ⇒ 两个 `.part` 必须删掉」；「发布之后」档**仍绿**（它守的是另一半） |
| 只删掉 `if _inflight_marker_on_disk(...): raise` 那道闸 | 1 个，命中 1 次 | 「发布之后」档**红**在「标记里明写的 `.part` 不许被顺手删掉」；「发布之前」档**仍绿** |

两条标记档必须**成对**才有判别力：只有前一条时，「一律清理」也能全绿。
两次还原后都对 `qmt_fetch.py` 做了 sha256 逐字节比对（`751b9b94d6b6`）。
四条新测试都在「前提断言」里先把现场钉死（`seen == [(True, True, False)]` /
`[(True, True, True)]`、`S_ISREG`/同 inode/长度不等），**不留恒真断言**。

## 本轮留下的取舍（推荐方案没有替我定，写在这里备审）

1. **发布那次 `os.replace` 之后没有 `fsync(目录)`**。按大 spec 耐久闭合清单自己的
   入选判据（「当且仅当它的丢失会改变后续运行的判断」）算出来不该进清单：`.part`
   不匹配导入侧 glob、不进四象限、崩溃恢复只按标记明写的路径删且容忍不存在，
   清单里「失败路径上 `.part` 的删除」已按同一条理由显式豁免。更硬的一条：改动前
   `O_CREAT` 直接造 `<rel>.part` 本身就是一次没有目录 `fsync` 的命名空间改动，
   本次**没有新增任何一条目录项**，盘上的净效果一个字没变，只是造法换了。
2. **`SIGKILL`/断电落在「临时文件已建、尚未发布」之间会留下一个
   `<rel>.part.<pid>.<随机>.tmp`**，而 S4b 的崩溃恢复按「不做任何模式匹配式清扫」
   **不会**回收它。这与 `qmt_fsroot` 为同一条保护接受的代价逐字相同；改动前同一个
   窗口留下的是一个半截 `.part`，也不是零残留。
3. **`_probe_part` 与 `os.replace` 之间存在一个残留窗口**：期间被植进 `<rel>.part`
   的对象会被 `replace` 连名字一起换掉。**这个窗口里丢不了 staging 树外面的数据**
   —— FIFO/socket 不存数据，符号链接被 `replace` 换掉时**不跟随**。
   关不掉它：POSIX `rename` 恒覆盖，而「合法的残留 `.part` 必须被盖掉」这条又要求
   覆盖。相比改动前「`O_TRUNC` 清空硬链接对面的外部文件」，后果严格更小。
4. **一处明写的行为变化**：`<rel>.part` 底下是一个**读不了**的普通文件（如被植了
   `0o200`）时，探测撞 `EACCES` ⇒ 裸 `OSError` 上抛；改动前的 `O_WRONLY` 会打开
   成功并把它截断重写。本工具自己写的 `.part` 一律 `0o600`，故这一档只可能是外来
   对象，按本模块既有纪律这是正确的那一侧。

---

# fix round 7 · codex [medium, 阻断]：回滚失败时清理异常顶替原异常、并吃掉其余回滚项

**位置**：`backend/qmt_fetch.py`，三处同型收尾路径 —— `copy_one` 的临时文件收尾、
`copy_stock` 的主回滚、写在途标记失败那一支（原 `:1014-1019` 是其中第二处）。
**起点**：`cd "/Users/maziming/Coding/Prj_Kline trainer" && git -C .dev/worktree/qmt-4b-s4a rev-parse --abbrev-ref HEAD && ... --short HEAD`
→ `qmt-4b-s4a` / `b72a14af`。

## 缺陷

三处都写成「顺着一串语句」：`_cleanup_part(A); _cleanup_part(B); refund(x); refund(y)`。
第一项一抛异常，**后面每一项都不执行**，而那个清理异常还**顶替掉**在途的原异常。
两层后果：

1. 一个意思是「终止整次运行」的 `SourceChangedMidRun` 会以**裸 `OSError`** 的样子
   到达调用方，而本模块自己的调用方契约又允许把裸 `OSError` 当候选失败处置
   ⇒ **必须停机的信号被降级成「这一只股失败了」**；
2. 没退的那笔账永久占着 `--max-bytes` ⇒ 一次**假的**配额触顶（残留 R1 那条
   「一次基础设施故障被记成一次正常结束」的喂料口）。

⚠️ 整支评审此前把同一件事报成 Minor、被判为可延后 —— 那是误判，本轮按阻断处理。

## 修法

新增两个函数 + 一个异常类，三处收尾路径改为同一套：

- `_rollback_all(stg_fd, part_names, refunds, budget)` —— 回滚的**唯一执行点**：
  逐项执行、逐项 `except Exception` 兜住，返回失败明细。保留 D7 的「删在前、
  退在后」次序，只是不再让前一项的失败吃掉后面的项。捕获宽度刻意是 `Exception`
  而非 `BaseException`（`KeyboardInterrupt` 不是「这一项回滚失败了」）。
  改后 `refund(` 与 `_cleanup_part(` 在本模块里**各只剩一个调用点**（逐字重数过）。
- `_settle_rollback(original, errors)` —— 收口，三支见下面「留给我定的两个决定」。
- `RollbackIncomplete(RunTerminated)` —— 终止条件族第三个成员，带 `.original`
  与 `.errors`，并 `raise ... from original`。

同步订正的文档回声（按「一条订正的回声散在八处」逐类复核）：模块 docstring 的
族成员数（两个→三个）、`raise` 语句穷尽枚举（四种→三种，且给出的理由是**那条
`raise` 现在逃不出去了**，不是「跑不到所以不列」）、裸 `OSError` 的位置保证
（此前那句话在回滚失败时**是假的**，现在无条件为真）、`RunTerminated` 类
docstring、`copy_one` / `copy_stock` / `_cleanup_part` 的 docstring。

## 留给我定的两个决定（推荐方案没有替我定）

### 决定 1 · 回滚不完整时调用方看到什么

**选：按原异常分两支。**

- 原异常**已经**是强制终止信号（`RunTerminated` / `PathEscapeError`），或是非
  `Exception` 的 `BaseException`（`KeyboardInterrupt`）⇒ **类型一个字不换**，
  只挂诊断。理由：`except RunTerminated` 的族籍、以及「`PathEscapeError` 本模块
  不捕获不包装原样上抛」都是调用方明写的判据，换掉就是这次评审要消灭的那种顶替；
  把一次中断换成别的类型等于吃掉它。
- 原异常**还不是**终止信号（`StockCopyFailed` / 裸 `OSError`）⇒ 抛
  `RollbackIncomplete`（`RunTerminated` 子类）。理由：`_cleanup_part` 撞的
  `EIO`/`EACCES` 是 **staging 这棵树**的事实，同一棵树上后面每一只股都会撞到
  —— 与大 spec R87-F1 把 `source_path_escape` 定性成「终止条件而非候选失败」
  （「同一目录下的所有股都受影响」）是**同一条判据的第五次应用**，也是契约 D5
  复述的那句「**「环境不对」不能记成「这个候选不行」**」。

**为什么不是「只保留原异常、不升级」**：那样盘面/账面已经对不上（而且对不上的
方式本模块并不知道），调用方却会按「跳过这只股」继续跑。M4 变异钉住了这一支。

**为什么不是「一律升级」**：那会把 D5 的 `SourceChangedMidRun` 换掉类型。
M5 变异钉住了这一支。

**合规性逐条核过**：①不新增第五个 failure `reason`（它不是 `StockCopyFailed`）；
②不削弱 D6（只可能在标记**发布之前**抛；发布之后本模块不做任何清理）；
③**不要求新增 `stopped_reason` 取值**（`STOPPED_REASONS` 是 4 值闭合集）——
与 D5 同规格，这条路上 `copy_stock` **manifest 一个字段都不写**，测试逐字节比对钉着；
④五个禁改模块一个字节没动。

### 决定 2 · 清理诊断怎么「随行」而不顶替原异常

**选：`add_note` 挂到原异常上（Python 3.11+，本仓 3.11.15）＋ 结构化
`RollbackIncomplete.errors` ＋ `__cause__` 链。**
理由：上面第二支根本不造新异常，诊断若只挂在新异常上那一支就没有了；挂在
`original` 上三支通吃。`errors` 保留异常对象本身，S4b 取 `.original` / `.errors`
即可，不必去解析异常文本。**不静默吞掉**：每一条失败都同时出现在 note 与
（若升级）`errors` 里。

## 证据：六条变异，每条都「锚点命中恰好 1 次 → 打印 diff → 邻居 deselect → 真跑」

变异前后各清一次 `__pycache__`，还原用保存的原字节（不用 `git checkout`），
还原后逐字节比对。

| 变异 | 打的是哪条判据 | 目标测试 | 结果 |
|---|---|---|---|
| M1 | 收尾路径①（`copy_one`）退回「顺着写」 | `test_copy_one_still_refunds_and_terminates_when_temp_cleanup_fails` | `1 failed` —— `PermissionError [Errno 13]` 顶替掉 `OSError [Errno 5]` |
| M2 | 收尾路径②（`copy_stock` 主回滚）退回「顺着写」 | `..._keeps_the_terminate_signal_when_both_part_cleanups_fail` / `..._escalates_a_candidate_failure_when_rollback_is_incomplete` | `2 failed` —— `SourceChangedMidRun` 与 `StockCopyFailed` 双双被 `OSError [Errno 5]` 顶替 |
| M3 | 收尾路径③（写标记失败那一支）退回「顺着写」 | `..._marker_write_failure_still_reconciles_when_cleanup_fails` | `1 failed` —— `ENOSPC` 被 `EIO` 顶替 |
| M4 | 决定 1 的「升级」那一支（删掉它） | 上述三条 | `3 failed` |
| M5 | 决定 1 的「已是终止信号就不换类型」守卫（删掉它） | `..._keeps_the_terminate_signal...` | `1 failed` —— 拿到的是 `RollbackIncomplete` 而不是 `SourceChangedMidRun` |
| M6 | 「一项清理失败不得跳过其余项」（第一项失败就 `break`） | 三条 | `3 failed` —— `assert 1 == 2`，`seen` 只剩一条 |

⚠️ **判别力是怎么保证的（本轮明确防的那个陷阱）**：注入的是 `OSError`，而被测代码
整段工作就是处理 `OSError` —— 只断言「抛了个 `OSError`」改对改错输出一模一样。
故每一档都按三条**改对改错必然分叉**的判据断言：
(a) 逃出来的是**哪一族**（`RollbackIncomplete` 不是 `OSError` 子类，`pytest.raises`
当场分叉）；(b) 另一项清理**有没有被尝试过**（`seen` 按次序记每一个命中的 leaf）；
(c) 预算**退没退**。三条新测试还各带「前提断言」把现场钉死（`seen` 长度、
`.tmp`/`.part` 确实还在盘上说明注入真的生效、爆炸那一刻标记确实还没发布），
不留恒真断言。

## 交付状态

- `cd backend && ../.venv/bin/python -m pytest tests/ -q -rs` → **1584 passed，0 skipped**
  （修复前 1579；新增 5 条测试）。
- 五个禁改模块（`qmt_fsroot` / `qmt_manifest` / `qmt_pool` / `qmt_ingest` /
  `qmt_normalize`）`git diff --stat HEAD` 全空。
- 契约 §4 交接新增第 12 条（体例同第 10 条「裸 `OSError` 的处置由 S4b 选」）：
  S4b 执行者会读的那一处必须知道终止条件族多了一个成员。后面三条顺延重编号。
- 验收清单 B2 的测试数 `1575` → `1584`。⚠️ 那个 `1575` **在本轮之前就已经是错的**
  （写于 `e812b62b`，随后 `42aad694` 加测试把实测推到 1579 而清单没跟），
  本轮顺手校正，因为我的改动又动了这个数字、而它是**非程序员照着跑**的那一处。

## 收尾时自查发现的一档（第二个提交 `6da54205`）

`<rel>.part` 的**某个路径分量**被换成符号链接时，回滚里的 `_cleanup_part` 自己会抛
`PathEscapeError`。它被 `_rollback_all` 收进 `.errors`（**刻意不原样上抛**——上抛
就成了「清理异常顶替原异常」，正是本轮要消灭的东西），于是调用方接到的是
`RollbackIncomplete` 而不是一次路径逃逸。**两者都必须终止整次运行，所以停不停机
不受影响**；但 `stopped_reason` 会差一个取值。已把「S4b 终止时先扫 `.errors`，
有 `PathEscapeError` 就按 `staging_path_escape` 记」写进契约 §4 第 12 条。
⛔ **S4a 没有为这一档配测试**（本轮范围只到三处收尾路径的独立执行），明写交接。

**提交**：`7214d9d4`（修复本体）+ `6da54205`（交接补档）。未 push。
