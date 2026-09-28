# 修复轮 11 交付报告 —— codex R9 的 [medium]：路径逃逸信号在 `qmt_fsroot` 里被顶替

**分支 / BASE / 交付 SHA**：`qmt-4b-s4a` / `aa49248e` / **`5a398041`**
开工核对（原样输出）：

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
aa49248e
```

工作树全程在 `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a`，
未 cd 主仓、未 push、未开 PR、未派子代理、未动 `.claude/state/`。

---

## 一、⚠️ 与任务书数字不符的一处（以我重新枚举的为准）

任务书第三节说 BASE 上 `qmt_fsroot.py` 有「**9 个 `finally:` 块**与 **17 个 `os.close` 出现处**」。
**实测：6 个 `finally:` 块、14 个 `os.close` 出现处。**
任务书给的行号清单（262 / 282 / 288 / 319 / 365-367 / 404-406 / 480 / 620 / 673-674 / 739-740 /
871-872 / 987-988 / 990-991）本身列的是 **13 组**位置，其中若干组是「`finally:` 行 + `os.close` 行」
成对写的，我理解那两个计数是把成对行重复数了一次。任务书写明「以你自己重新枚举的为准」，
下面第二节按我枚举的 **14 个** 逐条定性。

BASE 上的枚举命令与输出（`aa49248e`）：

```
$ grep -n "finally:" qmt_fsroot.py        → 365 / 404 / 673 / 739 / 871 / 990                 （6 个）
$ grep -n "os\.close"  qmt_fsroot.py      → 262 / 282 / 288 / 319 / 367 / 406 / 480 / 620 /
                                             674 / 740 / 872 / 987 / 988 / 991                （14 个）
```

---

## 二、按判据穷尽：14 个关闭点逐条定性

判据三选一：**A = 会顶替在途异常**；**B = 会让后续收尾项不执行**；**都不会 = 给可核实理由**。

| # | BASE 行 | 所在函数 / 形态 | 定性 | 理由（可核实） |
|---|---|---|---|---|
| S1 | 262 | `_open_root_impl` 逐段走循环体内，`os.close(fd); fd = nxt` | **都不会** | 它排在 `os.open` **成功之后**；上面那个 `except OSError` 分支调的 `_raise_walk_error` **两条路都 `raise`**（`if errno in (ELOOP, ENOTDIR): raise PathEscapeError(...)` / `raise exc`）⇒ 执行到这一行时**不可能有异常在途**。它也不是收尾块，吃不掉任何收尾项。**保留裸 `os.close`，源码里加了一行理由。** |
| S2 | 282 | `_open_root_impl`，`except BaseException: os.close(nxt); raise` | **A** | 在途的是 `_assert_freshly_created` 抛的 `BoundaryError`（「`mkdir` 与 `open` 之间目录被调包 ⇒ 拒绝启动」）。关闭失败 ⇒ `raise` 不执行 ⇒ 信任边界警报被换成裸 `OSError` |
| S3 | 288 | `_open_root_impl` 外层 `except BaseException: os.close(fd); raise` | **A** | 在途可能是 `PathEscapeError`（逐段走撞 ELOOP/ENOTDIR）、`DirectoryExistsError`、`BoundaryError`、`PathDisciplineError`。**这是评审那条的上游**：`open_root` 是整套边界的起点 |
| S4 | 319 | `open_root`，`if parent_fd is not None: os.close(parent_fd)` | **都不会** | 它排在 `_open_root_impl` **返回之后**，不在任何 `try` 语句的异常展开路径上（实现体抛异常时根本执行不到）；它也是这条路径上唯一的收尾项。**保留裸 `os.close`，源码里加了一行理由。** |
| S5 | 365-367 | `open_under`，`finally: for fd in opened: os.close(fd)` | **A + B** | A：在途可能是 `PathEscapeError` / `FileNotFoundError` / `mkdir`·`fsync` 的裸 `OSError`。B：`for` 循环里第一个 `os.close` 抛出，后面那些中间目录描述符**一个都关不上**（走 `a/b/c/leaf` 会攒下 3 个）。**评审点名** |
| S6 | 404-406 | `parent_fd_under`，`finally: for fd in opened: os.close(fd)` | **A + B** | 同 S5。**评审做过隔离故障注入复现的正是这一处**（`qmt_fetch.py:418-424` 的被调方） |
| S7 | 480 | `_open_regular_probe`，`except BaseException: os.close(fd); raise` | **A** | 在途只可能是 `os.fstat` / `fcntl` 的裸 `OSError`，或 `BaseException` 族（`except BaseException` 是作者刻意的宽度）。**族籍降级只发生在后者**（Ctrl-C 被换成一次普通 I/O 错误）；前者虽不换族籍，但**在途异常的身份与 errno 被顶替**（操作者看到的原因换了一个）⇒ 仍落在 A |
| S8 | 620 | `acquire_lock`，`except BaseException: os.close(lock_fd); raise` | **A** | 在途可能是 `LockDisciplineError`（硬链接 / 类型不符 / 锁目录项被换掉＝脑裂）、`LockUnavailableError`、`PathEscapeError`（写 `.holder` 时 `lstat` 撞符号链接）、`MarkerInvalidError` |
| S9 | 673-674 | `probe_unclaimed_dir`，`finally: os.close(lock_fd)` | **A** | 在途是 `LockDisciplineError`（锁文件不是普通文件 ⇒ 拒绝启动）。B 不成立：这个 `finally` 只有一项 |
| S10 | 739-740 | `_atomic_write_bytes` 内层，`finally: os.close(fd)` | **A** | 在途是 `_write_all` / `fsync` / `full_fsync` 的裸 `OSError`（如 `ENOSPC`）或 `BaseException` 族。族籍不变但 **errno 与身份被顶替**：「磁盘满」变成「I/O 错误」，出路完全不同 |
| S11 | 871-872 | `verify_owner_marker`，`finally: os.close(fd)` | **A** | 在途是 `MarkerInvalidError`（非普通文件 / 读取中超限）。调用方（`claim_dir` 的回读、`qmt_manifest`）有 `except MarkerInvalidError` 分支，顶替之后**那个分支够不着** |
| S12 | 987 | `claim_dir`，`except BaseException:` 里 `os.close(lock_fd)` | **A + B** | A：在途可能是 `_assert_leaf_still_is` 的 `BoundaryError`（取锁后/发布后目录被换掉）、`MarkerInvalidError`、`LockUnavailableError`、`PathEscapeError`。B：它失败会让 **`os.close(dir_fd)` 与 `raise` 本身**都不执行 |
| S13 | 988 | `claim_dir`，同一 `except` 里 `os.close(dir_fd)` | **A** | 同 S12 的 A |
| S14 | 990-991 | `claim_dir`，`finally: os.close(parent_fd)` | **A** | 失败路径上 `finally` 在 `raise` 之后运行，此时在途异常仍在展开 ⇒ 关闭失败顶替它。B 不成立：它是最后一个收尾项 |

**合计：要修 12 个（S2 S3 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14），保留裸 `os.close` 2 个（S1 S4）。**
⛔ 没有「其余同理」；⛔ 没有为了整齐把 S1/S4 一起动。

---

## 三、改法

新增**一条**关闭判据 `_close_or_note(fd, pending)`，加三个外壳：

| 名字 | 用途 |
|---|---|
| `_close_or_note(fd, pending)` | 判据本身。`pending is None` ⇒ 关闭失败**原样上抛**；否则只挂 `pending.add_note(...)`，**类型与身份一个字不换** |
| `_close_all_or_note(fds, pending)` | 关一组：**每一个都要被尝试关到**；`pending is None` 时只上抛第一个失败，其余挂在它的 `__notes__` 上 |
| `with _CloseFd(fd):` | 取代 `try: ... finally: os.close(fd)`（S9 / S10 / S11 / S14） |
| `with _CloseFds() as opened:` | 取代 `finally: for fd in opened: os.close(fd)`（S5 / S6） |

`except ... as e:` 形态的四处（S2 / S3 / S7 / S8 / S12+S13）直接调 `_close_or_note(fd, e)`。

**为什么不复用 `qmt_fetch._close_or_note`**：依赖方向是 `qmt_fetch` → `qmt_fsroot`，
地基不能反过来 import 它的使用者（会成环）。**两边 docstring 已互相指名**：
`qmt_fetch._close_or_note` / `qmt_fetch._CloseFd` 各加了一段指向 `qmt_fsroot` 的等价物并说明
合并不了的理由；`qmt_fsroot._close_or_note` 写明「**那边是登记处**」、语义继承那边，
没有重新发明一套。

**捕获宽度**：`except Exception`（**不是** `BaseException`），与 `qmt_fetch` 同规格，
配了同型守卫测试（见第四节 ⑬）。

**一并订正的陈旧 docstring**：`parent_fd_under` 的「② 中间 fd 在 `finally` 里关掉」
本次之后不再成立，已改为「由 `_CloseFds` 逐个独立关掉」并写明两条理由；
「归调用方、用完必须关」那半句逐字保留。

---

## 四、测试（+15，全部真跑过）

`tests/test_qmt_fsroot.py` +14（112 → 126）、`tests/test_qmt_fetch.py` +1。

1. **评审点名的那条回归**（`test_copy_stock_keeps_path_escape_when_an_intermediate_close_fails`）：
   源侧 `a/b/…csv`，`a` 是真目录（攒下 1 个中间描述符）、`b` 是符号链接 ⇒ `PathEscapeError`；
   同时把**那个中间描述符的关闭**打成 `EIO`。断言到达 `copy_stock` 调用方的仍是
   `PathEscapeError`（`not isinstance(exc, OSError)` + `not isinstance(exc, StockCopyFailed)`
   + `exc.component == "b"` + 关闭失败以 `__notes__` 存在）。
2. ①~⑫ 十二条「要修」站点各一条（见第五节 M2 的逐条红证）。
3. ⑬ **捕获宽度守卫** `test_close_or_note_lets_keyboard_interrupt_escape`：`os.close` 抛
   `KeyboardInterrupt` 时它必须原样逃出去、**不许**被记成 `__notes__` 诊断（照抄
   `qmt_fetch` 那三条的写法，含「`KeyboardInterrupt` 不是 `Exception` 的子类」那句判据断言）。
4. ⑭ `test_close_all_or_note_still_closes_the_rest_when_nothing_is_in_flight`：**没有异常在途**
   那一档仍然原样上抛，但不许在把其余描述符关完之前就抛。

每条都有**前提断言**（`fired == [具体那个 fd]` 或 `seen` 非空 + 撞的是哪一档），
避免「注入压根没生效 ⇒ 断言恒真」这类假绿。无 `skipif`、无 `skip`。

⚠️ **一处平台差异已在测试里如实处理**：中间分量是「指向目录的符号链接」时，
`O_DIRECTORY|O_NOFOLLOW` 的错误码**随平台而异**（本机 macOS 实测 `ENOTDIR`，Linux 给 `ELOOP`）。
`_raise_walk_error` 两者都认作逃逸，故回归里断言 `exc.errno in (ELOOP, ENOTDIR)`，
**不钉死其中一个**——钉死会在 Linux CI 上必红。（第一次写时钉的是 `ELOOP`，本机当场红，已改。）

---

## 五、变异自证

驱动脚本统一做四件事：锚点 `assert count == 1`；变异前后各清 `__pycache__`；
子进程带 `PYTHONDONTWRITEBYTECODE=1`；还原后 sha256 与原文件逐字比对。
每次都只跑目标那条 nodeid（**邻居全部 deselect**）。

| # | 变异（对准哪条新判据） | 目标 | 结果 |
|---|---|---|---|
| **M1** | **把 `parent_fd_under` 的保护整个去掉**，退回 `finally: for fd in opened: os.close(fd)` | 第四节第 1 条那个回归 | **红 ✅** |
| M2 | `_close_or_note` 的 `if pending is None: raise` → `if True: raise`（pending 分支拆掉） | **12 条站点测试 + 那条回归，共 13 条** | **13 条逐条红 ✅** |
| M3 | `_close_all_or_note` 的逐项独立拆掉（退化成 `for fd in fds: _close_or_note(fd, pending)`） | ⑭ | **红 ✅** |
| M4 | 捕获宽度 `except Exception as e:` → `except BaseException as e:` | ⑬ | **红 ✅** |
| M5 | `_CloseFd.__exit__` 传 `None` 而不是 `exc` | ⑨ `verify_owner_marker` | **红 ✅** |
| M6 | `_CloseFds.__exit__` 传 `None` 而不是 `exc` | ① `open_under` | **红 ✅** |

**M1（最关键那条）红掉的现场原文** —— 它显示的正是「`PathEscapeError` 被 `OSError` 顶替」：

```
M1 · parent_fd_under 的保护去掉（退回裸 finally） · 锚点出现次数 count == 1
--- test_copy_stock_keeps_path_escape_when_an_intermediate_close_fails → rc=1 RED
    E                   NotADirectoryError: [Errno 20] Not a directory: 'b'
    E           qmt_fsroot.PathEscapeError: 路径 'a/b/600000.SH_x_1分钟K线_前复权.csv' 的分量 'b' 不是一个普通目录（ENOTDIR）…
    E           OSError: [Errno 5] 打桩：关中间目录描述符撞 EIO
还原后 sha256 逐字相同 ✅  cb86bf7d4a1cee7185dc2a1848905d4a8a4410a6cea63aab6ac68dec5e3742d4
```

同一次变异用 `--tb=line` 再跑一遍，**逃出去的那个异常的族籍**看得更直白
（`pytest.raises(PathEscapeError)` 没接住它，因为它已经是个 `OSError`）：

```
=================================== FAILURES ===================================
…/tests/test_qmt_fetch.py:2456: OSError: [Errno 5] 打桩：关中间目录描述符撞 EIO
=========================== short test summary info ============================
FAILED tests/test_qmt_fetch.py::test_copy_stock_keeps_path_escape_when_an_intermediate_close_fails
1 failed in 0.27s

restore sha equal: True
```

**M2 的 13 条逐条红**（摘要，每条都带了「在途的是哪一类信号 + 顶替它的那个 EIO」）：

```
--- test_open_under_keeps_path_escape…                → RED   PathEscapeError  ← OSError[EIO]
--- test_parent_fd_under_keeps_path_escape…           → RED   PathEscapeError  ← OSError[EIO]
--- test_open_root_keeps_path_escape_when_closing…    → RED   PathEscapeError  ← OSError[EIO]
--- test_open_root_create_leaf_keeps_boundary_error…  → RED   BoundaryError    ← OSError[EIO]
--- test_open_regular_probe_keeps_the_original_error… → RED   assert OSError(5,'关描述符') is OSError(5,'fstat')
--- test_acquire_lock_keeps_lock_discipline_error…    → RED   LockDisciplineError ← OSError[EIO]
--- test_probe_unclaimed_dir_keeps_lock_discipline…   → RED   LockDisciplineError ← OSError[EIO]
--- test_atomic_write_keeps_the_write_error…          → RED   assert OSError(5,'关描述符') is OSError(28,'ENOSPC')
--- test_verify_owner_marker_keeps_marker_invalid…    → RED   MarkerInvalidError ← OSError[EIO]
--- test_claim_dir_keeps_boundary_error…lock_fd…      → RED   BoundaryError    ← OSError[EIO]
--- test_claim_dir_keeps_boundary_error…dir_fd…       → RED   BoundaryError    ← OSError[EIO]
--- test_claim_dir_keeps_boundary_error…parent_fd…    → RED   BoundaryError    ← OSError[EIO]
--- test_copy_stock_keeps_path_escape…                → RED   PathEscapeError  ← OSError[EIO]
还原后 sha256 逐字相同 ✅
```

**M4 红掉的现场**（证明宽度确实被钉住：放宽之后中断被当成诊断咽掉了）：

```
E           qmt_fsroot.PathEscapeError: 路径 'a/b/leaf.csv' 的分量 'b' 不是一个普通目录…
E           关描述符失败（fd=11）——KeyboardInterrupt:
```

---

## 六、验收门改动（第六节要求）+ 每条命令我都真跑过

### 6.1 `docs/superpowers/acceptance/2026-09-20-qmt-4b-s4a-acceptance.md`

- **D2 拆成 D2 / D3 / D4 / D5**：
  - **D2** 只断言**四个**模块（`qmt_manifest` / `qmt_pool` / `qmt_ingest` / `qmt_normalize`）零改动；
  - **D3** 新增：`qmt_fsroot.py` **本片确有改动**，并给出量级；
  - **D4 + D5** 新增：让非程序员看到**改动只落在收尾路径上**。
- **⚠️ 额外必须改的一处（任务书没点名，但不改就是同一个假失败）**：**B2 写着 `1596 passed`**，
  本轮 +15 之后实测 **1611**。不改它，B2 会在一棵完全健康的树上报「不通过」。
  全仓 `1596` 只有这一份副本（`grep -rn "1596" docs/ .superpowers/ backend/` 只命中 B2 这一行）。
- 为 D3/D4/D5 配了一段**大白话说明**：为什么破例动这个模块、这三条各在验证什么。

**D4/D5 的形态刻意避开了管道符**：markdown 表格里裸 `|` 会把单元格切断，而本仓的纪律是
「命令超一行必被截断 ⇒ 落脚本」。故 D4 用 `printf … > /tmp/s4a_d4.sh` 造脚本（脚本体内用
重定向到临时文件，**不用管道**），D5 `bash /tmp/s4a_d4.sh`，与既有 B1/B2、C1/C2 同体例。

### 6.2 五条命令的真实输出（在 `qmt-4b-s4a` / `5a398041` 上跑的）

```
$ grep -c "argparse" ".../backend/qmt_fetch.py"                                   # D1
0

$ git diff --stat main -- backend/qmt_manifest.py backend/qmt_pool.py \           # D2
                          backend/qmt_ingest.py backend/qmt_normalize.py
（没有任何输出）

$ git diff --stat main -- backend/qmt_fsroot.py                                   # D3
 backend/qmt_fsroot.py | 233 +++++++++++++++++++++++++++++++++++++-------------
 1 file changed, 174 insertions(+), 59 deletions(-)

$ printf '%s\n' … > /tmp/s4a_d4.sh                                                # D4
（没有任何输出）

$ bash /tmp/s4a_d4.sh                                                             # D5
一、删掉的行数：
      33
二、其中带业务调用的行数：
0
（检查结束）
```

**D5 那条「报 0」的判别力已实测**（本仓纪律：报 0 必须先证明它能报非 0）：

```
$ { git diff -w main -- backend/qmt_fsroot.py | grep '^-[^-]'; \
    echo "-        os.replace(tmp_name, name, src_dir_fd=dir_fd)"; } \
  | grep -c "os.open\|os.mkdir\|os.replace\|flock\|fsync"
1
```

**被删掉的 33 行全文**（D4/D5 那句「全部是收尾语句」的底稿，未截断）：

```
-            except BaseException:          -    try:
-                os.close(nxt)              -    finally:
-    except BaseException:                  -        os.close(lock_fd)
-        os.close(fd)                       -        try:
-    opened: list[int] = []                 -        finally:
-    try:                                   -            os.close(fd)
-    finally:                               -    try:
-        for fd in opened:                  -    finally:
-            os.close(fd)                   -        os.close(fd)
-      ② 中间 fd 在 `finally` 里关掉，…    -    except BaseException:
-    opened: list[int] = []                 -            os.close(lock_fd)
-    try:                                   -        os.close(dir_fd)
-    finally:                               -    finally:
-        for fd in opened:                  -        os.close(parent_fd)
-            os.close(fd)
-    except BaseException:
-        os.close(fd)
-    except BaseException:
-        os.close(lock_fd)
```

唯一一行不是代码的，是那句被**订正**的 docstring（「② 中间 fd 在 `finally` 里关掉」）。

### 6.3 B1 / B2 也真跑了

```
$ bash /tmp/s4a_b1.sh
qmt-4b-s4a
aa49248e            ← 跑的时候还没 commit；commit 后 SHA 为 5a398041
…
1611 passed in 34.97s
```

---

## 七、契约与 PR 正文

### 7.1 `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md`

- **新增 §3c「本片为什么破例动了 `qmt_fsroot`」**：user 2026-09-21 拍板 + 纯防御性、不改语义
  （没有增删改任何公开函数、没有改任何判据的判定结果、没有改任何异常的类型或触发条件），
  与 R1 那种要改 `qmt_manifest` **转移守卫语义**的情况不同类；并写明范围是「按判据穷尽 14 个、
  修 12 个、留 2 个」，以及两处实现并存合并不了的依赖方向理由。
- **§3b 取舍表 +T6 / +T7**，标题同步改成
  「T1–T3：硬链接修复 · codex R1 [high]；T4–T5：`qmt_fetch` 关闭判据收口 · codex R5 [medium]；
  **T6–T7：`qmt_fsroot` 关闭判据收口 · codex R9 [medium]**」：
  - **T6**：展开途中关闭失败只挂诊断 ⇒ 描述符可能没被回收（与 T5 同判据同理由，换个模块）；
  - **T7**：**没有异常在途**时中间描述符关闭失败，那个**即将交给调用方**的返回值
    （叶子 fd / `os.dup(cur)`）会随异常被丢弃 ⇒ 漏一个描述符。**BASE 上逐字同结局，本片没改它**，
    如实登记而不是沉默。
- **§4 交接 +第 18 条**（S4b）：`qmt_fsroot` 抛出的异常现在可能带 `__notes__`，
  写停机报告时除 `.errors` 外还得看 `__notes__`；且第 10 条那个二选一的**输入集合窄了一档**
  （少了「其实是一次路径逃逸/边界破坏的裸 `OSError`」这一类）。明写**不改变任何
  `stopped_reason` 取值、不新增 failure `reason`、不新增异常族籍**。
- **§5 覆盖表 +2 行**（见下一节的字面量枚举）。

### 7.2 大 spec：**零删改**（对 BASE diff 为空，已自证）

```
$ git diff --stat aa49248e -- docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md
（没有任何输出）
```

本轮**没有**新增指针——大 spec 末尾在更早的轮次已有一节纯指针，写明
「该契约……**逐句列名**了它覆盖的本文件语句（见其 §5）」，我新加的两行落在那张表里，
被这条既有指针覆盖，不需要再加第二条。

### 7.3 大 spec 的字面量枚举 + 逐条定性（⛔ 不按概念搜词）

| 大 spec 处 | 原文要点 | 定性 |
|---|---|---|
| **§4.5:609** | 「② **中间 fd 在 `finally` 里关掉**，返回的 `parent_fd` **归调用方，用完必须关**」 | **不再成立（半句）⇒ 已列进 §5 覆盖表**。只覆盖「在 `finally` 里」这半句；「归调用方、用完必须关」逐字继续有效 |
| **§4.5:641-642** | `open_under` 伪代码块末尾 `finally:` / `for fd in opened: os.close(fd)` | **不再成立 ⇒ 已列进 §5 覆盖表**。同一事实的第二份副本（伪代码形态）——只订正 :609 那份，下一轮评审会从这份重新长出同一条 finding |
| §4.1:98 / :103 | `os.close(fd); fd = nxt` | **逐字继续有效，不列名**。那是 `open_root` 逐段走**成功路径**上那一句（本报告 S1），本片没改它 |
| §11:1215（O4-F14 行） | 「已修：补齐**三条规格** + 恢复路径撞 escape 的专门处置……」 | **逐字继续有效，不列名**。它只说「三条」、不提机制，本片没有增减那三条中的任何一条 |
| :154 / :884 / :1335 / :1358 等的「关掉」 | 「堵住洞」「关掉开关」「关掉 `skip_existing_verify` 位」 | **与描述符关闭无关** |
| :1325 的「描述符」 | `RecoveryScope` 这个「范围**描述符**」 | **与文件描述符无关**（同词异义） |

枚举命令（全文逐处，未截断）：`grep -n "finally"`（2 处）、`grep -n "os\.close"`（3 处）、
`grep -n "关掉\|关闭\|必须关\|fd 归"`（5 处）、`grep -n "描述符"`（1 处）。
这段枚举记录也写进了契约 §5 表下方的纪律段。

---

## 八、闸门（控制者可复跑）

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
5a398041

$ ../.venv/bin/python -m pytest tests/ -q -rs
1611 passed in 34.44s              ← 0 failed / 0 skipped（BASE 1596，+15 全是本轮新增）

$ ../.venv/bin/python -m pytest tests/test_qmt_fsroot.py tests/test_qmt_manifest.py -q
507 passed in 2.30s                ← 被我动的那个模块的**既有用户**全绿
                                      （test_qmt_fsroot 112→126，test_qmt_manifest 381 不变）

$ git diff --stat aa49248e -- backend/qmt_manifest.py backend/qmt_pool.py \
                               backend/qmt_ingest.py backend/qmt_normalize.py
（没有任何输出）                    ← 禁改四模块自证
```

---

## 九、疑虑（逐条）

1. **⚠️ 任务书的计数与实测不符**（第一节）：9 个 `finally` / 17 个 `os.close` vs 实测 6 / 14。
   我按自己的枚举执行，但如果任务书那两个数字来自另一棵树或另一个版本，请复核一次。
2. **⚠️ 验收清单 §五 第 2 条的评审计数已经陈旧，我没有改**：它写着「**3 次真判决**……报出的
   **4 个问题**已全部改掉」。`progress.md` 的账本记到 **R7（第 4 次真判决）**为止，**R8 / R9
   没有条目**，我无法从仓内材料判定 R8 是真判决还是撞额度，也就无法写出正确的数字。
   **按本仓「不凭空写计数」的纪律，我选择不动它并在此登记。** 请控制者用权威账本订正。
3. **S7（`_open_regular_probe`）的收益比其余 11 处弱**，如实说明：那一处在途只可能是裸
   `OSError` 或 `BaseException` 族 ⇒ **族籍降级只在后者成立**，前者是「身份与 errno 被顶替」。
   我仍按判据把它归入「要修」（它确实会顶替在途异常，且留一个洞会让「本模块只有一个关闭判据」
   这句话不成立）。若控制者认为该处不值得动，回退它只需改 3 行、并删掉对应那一条测试。
4. **T7 是我新登记的残留、本片没修**：`open_under` / `parent_fd_under` 在**没有异常在途**时
   撞上关闭失败，那个即将交出去的返回值（叶子 fd / `os.dup(cur)`）会被丢弃 ⇒ 漏一个描述符。
   BASE 上逐字同结局，不属于本轮判据（信号降级）。已写进契约 §3b T7 并指向 T5 末段同族那条。
5. **另一处 BASE 既有缺陷，我发现了但没修**（按「不改不属于本次请求的东西」）：
   `_open_root_impl` 逐段走时若 **S1（262 行）那句裸 `os.close(fd)` 失败**，`fd = nxt` 不执行 ⇒
   `nxt` **泄漏**，且外层 `except` 会对**同一个 fd** 再关一次（多半得 `EBADF`）。
   本轮把外层改成 `_close_or_note` 之后，那次 `EBADF` 至少已降级成诊断、不再顶替第一个
   `OSError`；但 `nxt` 泄漏依旧。它是描述符泄漏、不是信号降级，**不在本轮判据内**，
   未登记进契约（如果控制者认为该登记，我可以补一条 T8）。
6. **`claim_dir` 有约 23 行是纯缩进变化**（包进 `with _CloseFd(parent_fd):`）。
   我选 `with` 而不是把 `finally` 拆成「except 里一份 + 成功路径一份」，理由是后者会把
   **同一条判据落在两处**（本仓明令的缺陷源）。代价是 diff 看起来比实际改动大——
   D4/D5 那两条验收命令用 `git diff -w`（忽略缩进）正是为了让非程序员绕过这个噪声。
7. **平台差异**：本机 macOS 上「指向目录的符号链接」给 `ENOTDIR`，Linux 给 `ELOOP`。
   新测试全部避开了对具体 errno 的钉死（回归那条断言 `in (ELOOP, ENOTDIR)`）。
   但我**只在 macOS 上跑过**——Linux CI 的真实结论要等 CI 跑完才算数。
8. **`os.mkfifo` / `os.link` 我在新测试里用了**，这两个在本文件既有测试里已各有 5 / 2 处先例
   （CI 上跑过），所以我判断 Linux 上没有风险；但这仍是「按先例推断」，不是我亲自在 Linux 上验的。
