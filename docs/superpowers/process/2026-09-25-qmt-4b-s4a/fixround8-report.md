# 修复轮 8 报告 —— codex R5 的 [medium]（关描述符也是收尾动作）

分支 / BASE 自证（开工第一条命令）：

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
3b6e2dfb
```

工作目录：`/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a`（全程未 cd 主仓）。
解释器：`backend/../.venv/bin/python`（Python 3.11.15）。

---

## 一、结论先行

评审点名的是 `copy_one` 里 `os.close(sfd)` 那一句，但这是 **fix round 7 那条判据的复发**
（「收尾动作抛的异常顶替在途原异常 / 吃掉后续收尾项」），所以本轮按判据穷尽本模块：
**BASE 的 12 个关闭点、10 个 `finally:` 块逐个定性**，同型的一并收进**一个**判据。

改动后：`qmt_fetch.py` 里 **`finally:` 块 0 个**，裸 `os.close` **只剩 2 处**（各有书面理由）。

---

## 二、逐个字面量枚举 + 逐条定性（按 BASE `3b6e2dfb` 的行号）

判据：某处关闭失败能不能**改变调用方的决定**——
① 把在途异常换成裸 `OSError`（族籍变了，而 §4 第 10 条允许 S4b 把裸 `OSError` 当候选失败跳过）；
② 让本趟已扣的字节 / 已落地的东西无人认领。

| # | BASE 行 | 位置（关的是什么） | 定性 |
|---|---|---|---|
| 1 | `finally` 343 → `close` 344 | `_open_source_leaf`，源侧父目录 fd | **要修（顶替在途异常）**。在途可能是 `PathEscapeError`（`open_under` 逐段无跟随撞 ELOOP，整次致命、不属于三族）或 `StockCopyFailed("fetch_missing_file")`；两者都被换成裸 `OSError` ⇒ **一次信任边界破坏被降级成「这只股不行」**。测试 T1 |
| 2 | `finally` 368 → `close` 369 | `_part_is_non_regular`，staging 父目录 fd | **两者都不会**。`os.stat` 的 `OSError` 已被紧邻的 `except OSError: return False` **处理掉**，`finally` 运行时**没有异常在途**（本机实测 `__exit__` 收到 `(None, None, None)`）；唯一能在途的是非 `Exception` 的 `BaseException`。且它的两个消费者都在已经兜住的位置：`_open_part` 的 `except OSError` 分支内、`_rollback_all` 的逐项 `try` 内。**仍随统一判据一并改**（不留第二份内联副本），不单配测试 |
| 3 | `close` 433（无 `finally`） | `_open_part` 的 `except BaseException: os.close(fd)` | **要修（顶替在途异常）**。在途是紧上方 `S_ISREG` 抛出的 `StockCopyFailed("untracked_target_file")` ⇒ 被换成裸 `OSError`，**这只股丢掉自己的 `reason`**，落不进 4c 报告 schema 的任何一个桶。测试 T3 |
| 4 | `close` 464（无 `finally`） | `_probe_part` 成功路径 | **两者都不会**。它排在 `try` **之外**、`_open_part` 已经返回 ⇒ **执行到这里不可能有异常在途**，顶替不了任何东西；它自己失败就是这条路径自己的结果，原样上抛正确，而那时它落在 `copy_one` 的失败收尾里、退账与清理照常。**全模块唯一保留原样的关闭点**（另一处裸 `os.close` 是 `_close_or_note` 自己，它就是判据本身） |
| 5 | `finally` 507 → `close` 508 | `_publish_part`，staging 父目录 fd | **要修（漏记账 + 漏清理）**。`os.replace` **成功之后**这一句失败 ⇒ 抛出的只是裸 `OSError`，`copy_one` **分辨不了发布到底发生没有** ⇒ 已发布的 `<rel>.part` 漏清、本趟字节漏退。（顶替那一半不严重：在途只可能是 `os.replace` 自己的裸 `OSError`，族籍不变。）测试 T5。修法两半：`_CloseFd` ＋ `copy_one` 里 `parts` 提前纳入 `<rel>.part` |
| 6 | `finally` 582 → `close` 583 | `copy_one` 写侧 fd（`dfd`） | **要修（顶替在途异常）**。在途可能是 `budget.charge` 的 `MaxBytesExhausted`（终止条件族）⇒ 被换成裸 `OSError` ⇒ **必须停机被降级成跳过这只股**。而且这是最容易在真实环境里失败的一个：写侧描述符**关闭时才回写**，SMB/NFS 上撞 `EIO`/`ENOSPC`。测试 T6 |
| 7 | `finally` 596 → `close` 597 | `copy_one` 复算重读 fd（`rfd`） | **两者都不会**。那一段只有 `os.read` 与 `hashlib.update`，在途只可能是裸 `OSError`，顶替后逃出的**仍是裸 `OSError`**（族籍不变，原异常保留在 `__context__`）；账实由外层 `except` 的退账与清理保证。**随统一判据一并改** |
| 8 | `finally` 609 → `close` 610 | `copy_one` 源侧 fd（`sfd`）**· 评审点名** | **要修，两条都沾**。(a) 拷贝成功、发布之后失败 ⇒ `copy_one` **永远不返回** ⇒ `copy_stock` 不把它记进 `written` ⇒ 外层回滚删得掉 `.part` 却**退不回字节**；(b) `MaxBytesExhausted` 展开途中失败 ⇒ **终止信号被换成裸 `OSError`**。两条评审都已隔离故障注入复现。测试 T8a / T8b |
| 9 | `finally` 711 → `close` 712 | `classify_target`，staging 父目录 fd | **要修（顶替在途异常）**。在途可能是 `PathEscapeError`，而本函数 docstring 明写符号链接「**绝不会**被归进 `TARGET_UNTRACKED`，必须整次运行终止」⇒ 换成裸 `OSError` 就是把它降级。测试 T9 |
| 10 | `finally` 722 → `close` 724 | `classify_target`，目标文件 fd（带 `if fd is not None`） | **两者都不会**。在途只可能是 `_hash_target` 里 `os.read` 的裸 `OSError`——`record` 的 `bytes`/`sha256` 两个字段已由 `_validate_record` 保证存在且类型正确，`st.st_size` 不抛 ⇒ 顶替后族籍不变；且本函数在 `copy_stock` 里跑在**任何扣账 / 落地之前**，盘面账面都还没动。**随统一判据一并改**（`fd` 可能是 `None`，故 `_CloseFd` 接受 `None`） |
| 11 | `finally` 862 → `close` 863 | `_cleanup_part`，staging 父目录 fd | **两者都不会**。**它本身就在收口函数内部**：`_cleanup_part` 只被 `_rollback_all` 调用，那里对每一项 `except Exception` 逐项兜住 ⇒ 顶替不了在途的原异常（原异常在更外层，由 `_settle_rollback` 处置），也吃不掉后面的回滚项。**随统一判据一并改** |
| 12 | `finally` 939 → `close` 940 | `_replace_part_to_final`，staging 父目录 fd | **两者都不会**。它跑在**在途标记发布之后**，而 D6 的判据是**位置**不是**类型**（调用方在这一段接到任何异常都必须按整次运行终止、不必检查类型）；本函数此后不做任何清理、不退任何账 ⇒ 没有「漏记账 / 漏清理」可言。**随统一判据一并改** |

**要修 6 处**（#1 #3 #5 #6 #8 #9），**两者都不会 6 处**（#2 #4 #7 #10 #11 #12）。
其中 #4 保持原样不动；#2 #7 #10 #11 #12 仍然改，理由不是各自有害，而是
**「同一条判据不许有第二份内联副本」是本模块自己反复申明的纪律**——十处 `finally` 留一半
就是下一轮的复发口。

---

## 三、改法

新增**一个**判据，`qmt_fetch.py`：

```python
def _close_or_note(fd, pending):      # pending 由调用处显式交进来
    try:
        os.close(fd)
    except Exception as e:
        if pending is None:
            raise                      # 没有异常在途 ⇒ 这是这条路径自己的结果，原样上抛
        pending.add_note(...)          # 有异常在途 ⇒ 只挂诊断，类型一个字不换

class _CloseFd:                        # `with _CloseFd(fd):`，__exit__ 的第二个形参就是在途异常
    ...
```

- **不用 `sys.exc_info()`**：那拿到的是**整条调用栈**上正在被处理的异常，包括 S4b 在自己
  `except` 块里调 `copy_stock` 这种情形 ⇒ 本模块的关闭行为会取决于「谁在什么上下文里调它」。
  `__exit__` 的第二个形参是**这一帧**的事实。
- 捕获宽度 `Exception`（与 `_rollback_all` 同规格）：`KeyboardInterrupt` / `SystemExit`
  不是「这次关闭失败了」，不许被当成诊断咽掉。
- `copy_one` 结构改动：`with _CloseFd(sfd):` 挪进失败收尾的 `except` **里面**；
  回滚名单 `parts` 从 `(tmp,)` 在**准备发布那一刻**扩成 `(tmp, rel + PART)`。

`_rollback_all` / `_settle_rollback` / `RollbackIncomplete` **一个字没改**，
exception 三族与 `__all__` 一个字没改，failure `reason` 仍是那 3 个（本模块产出的），
`grep -c argparse` = 0。

---

## 四、测试（7 条新增，全部断言钉具体那一条）

| 代号 | 测试名 | 钉的是 |
|---|---|---|
| T8a | `test_copy_one_refunds_and_cleans_its_part_when_closing_source_fails` | 发布之后关源失败 ⇒ **退账做了 + 自己刚发布的 `.part` 清掉了**，逃出裸 `OSError` |
| T8b | `test_copy_one_keeps_max_bytes_exhausted_when_closing_source_fails` | `MaxBytesExhausted` 展开途中关源失败 ⇒ 逃出的**仍是 `MaxBytesExhausted`** |
| T6 | `test_copy_one_keeps_max_bytes_exhausted_when_closing_dest_fails` | 同上，写侧描述符（#6） |
| T5 | `test_copy_one_cleans_up_when_publish_succeeds_but_its_close_fails` | `os.replace` 成功后关目录 fd 失败 ⇒ 退账 + 清掉已发布的 `.part`（#5） |
| T1 | `test_open_source_leaf_keeps_path_escape_when_closing_parent_fails` | `PathEscapeError` 不被顶替（#1） |
| T9 | `test_classify_target_keeps_path_escape_when_closing_parent_fails` | `PathEscapeError` 不被顶替（#9） |
| T3 | `test_open_part_keeps_untracked_reason_when_its_close_fails` | `StockCopyFailed(reason="untracked_target_file")` 不被顶替（#3） |

**每条都带前提断言**（注入到底有没有生效、炸的那一刻盘上是什么状态），否则
「逃出来的是原异常」可能是恒真的。

契约里明写的收口选择（评审给了两种，本片选第一种，T8a 钉住）：
**退账 + 清掉自己刚发布的 `.part`**，不是「落地物留下、字节数交给调用方」。

---

## 五、变异自证

每次：锚点 `assert count == 1` → 变异前后各清 `__pycache__` → `PYTHONDONTWRITEBYTECODE=1`
→ **只跑目标那一条 nodeid**（邻居全 deselect）→ 还原 → sha256 与原文件逐字相同。
原文件 sha256 = `864f8588ff9ea4de20a417376c8deb42d0c95e3f3f6698a8e7371116ee2973d0`（每轮还原后复核一致）。

| 变异 | 拿掉的判据 | 目标测试 | 结果 | 红在哪一条 |
|---|---|---|---|---|
| M1 | P1「有异常在途 ⇒ 只挂诊断、不顶替」（改成无条件 `raise`） | T8b | 红 | `E   OSError: [Errno 5] 打桩：关源描述符时撞 EIO`（本该是 `E   qmt_fetch.MaxBytesExhausted: charge：剩余 36 字节…`） |
| M1 | 同上 | T6 | 红 | `E   OSError: [Errno 5] 打桩：关写侧描述符时回写撞 EIO` |
| M1 | 同上 | T1 | 红 | `E   OSError: [Errno 5] 打桩：关源侧父目录描述符撞 EIO`（本该是 `PathEscapeError … ELOOP`） |
| M1 | 同上 | T9 | 红 | `E   OSError: [Errno 5] 打桩：关 staging 父目录描述符撞 EIO` |
| M1 | 同上 | T3 | 红 | `E   OSError: [Errno 5] 打桩：关那个目录描述符撞 EIO`（本该是 `StockCopyFailed: untracked_target_file`） |
| M2 | P2「没有异常在途 ⇒ 原样上抛」（改成一律咽掉） | T8a | 红 | `E   Failed: DID NOT RAISE <class 'OSError'>` |
| M2 | 同上 | T5 | 红 | `E   Failed: DID NOT RAISE <class 'OSError'>` |
| M3 | P3「发布可能已发生 ⇒ 回滚名单纳入 `<rel>.part`」 | T8a | 红 | `E   AssertionError: 已发布的 `.part` 漏清：调用方既拿不到字节数，盘上却留着东西` |
| M3 | 同上 | T5 | 红 | `E   AssertionError: 已发布的 `.part` 漏清：`copy_one` 分辨不了发布发生没有，就必须两个名字都清` |
| M4 | P4「关源描述符落在事务边界之内的那个 `except` 里」（把 `except BaseException` 收窄成 `except RunTerminated`） | T8a | 红 | `E   AssertionError: 关源失败吃掉了退账：baseline=17，实测 157` ← **这正是评审说的「三个已扣字节留在账上」** |

### fix round 7 的两条变异**仍然**能红（本轮动了它们旁边的代码，故重跑）

| 变异 | 目标测试 | 结果 | 红在哪一条 |
|---|---|---|---|
| R7-M2「清理项不再兜住异常」 | `test_copy_one_still_refunds_and_terminates_when_temp_cleanup_fails` | 红 | `E   PermissionError: [Errno 13] 打桩：删临时文件撞 EACCES`（本该是 `RollbackIncomplete`） |
| R7-M6「第一项失败即 break」 | `test_copy_stock_keeps_the_terminate_signal_when_both_part_cleanups_fail` | 红 | `E   AssertionError: 两条 `.part` 必须各被尝试删一次，实测 ['600000.SH_x_1分钟K线_前复权.csv.part']` / `E   assert 1 == 2` |

---

## 六、闸门

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
3b6e2dfb
$ ../.venv/bin/python -m pytest tests/ -q -rs
1591 passed in 36.33s
```

BASE 处 1584 passed / 0 skipped → 交付处 **1591 passed / 0 failed / 0 skipped**（新增 7 条）。

禁改模块自证（输出为空）：

```
$ git diff --stat 3b6e2dfb -- backend/qmt_fsroot.py backend/qmt_manifest.py \
      backend/qmt_pool.py backend/qmt_ingest.py backend/qmt_normalize.py
(空)
$ grep -c argparse backend/qmt_fetch.py
0
```

---

## 七、契约改动（单列）

`docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md`：

1. **§3b 标题与引导句**：原写「硬链接修复带来的**三条**已登记取舍」，现在这张表要多收两行
   ⇒ 改成「已登记的对外可见取舍（T1–T3：硬链接修复 · codex R1 [high]；T4–T5：关闭判据收口 · codex R5 [medium]）」，
   引导句点明 T4–T5 与硬链接无关。
2. **§3b 新增 T4**：`copy_one` 从准备发布那一刻起把 `<rel>.part` 列进自己的回滚名单
   ⇒ 这一档的失败会删掉那个名字底下的普通文件，**包括上一次运行留下的合法残留 `.part`**
   （此前 `copy_one` 无条件不删它）。定性**接受**：`copy_stock` 的主回滚在同一条失败路径上
   本来就会删这个名字，非普通对象照旧留着不碰。
3. **§3b 新增 T5**：展开途中 `os.close` 失败只挂诊断 ⇒ 那个描述符可能没被回收。
   定性**接受**（另一侧是顶替终止信号，评审实测的阻断级后果）。**T5 里还登记了一档未修的同类**，见下面疑虑 ③。
4. **§4 交接新增第 16 条**（原 15 条）：给 S4b 的两句话——
   展开途中的关闭失败**不进 `RollbackIncomplete.errors`**、只在 `__notes__` 上
   ⇒ 写停机报告时除 `.errors` 还得看 `__notes__`；没有异常在途时的关闭失败仍是裸 `OSError`，
   处置归 §4 第 10 条那个二选一。

`qmt_fetch.py` 的**模块 docstring**（实现者读的那一处）同步写了同一件事，两处都改了。

---

## 八、我的疑虑（逐条）

① **`parts` 提前一句带来的语义变化是真的，不是零**。`parts = (tmp, rel + PART)` 排在
   `_publish_part` **之前**，于是「`os.replace` 自己失败」那一档也会删掉一份上一次运行崩在
   半路留下的陈旧 `.part`。在本片唯一的调用方（`copy_stock`）看来净效果为零——主回滚在同一条
   路径上本来就删它；但 `copy_one` 在 `__all__` 里，**外部单独调它的语义确实变了**。
   已登记 §3b T4。放在 `_publish_part` 之后则留下一个窗口（`replace` 成功、关目录 fd 失败），
   两者只能二选一，我选了没有窗口的那一侧。

② **关闭失败被挂成诊断之后，那个描述符可能没被回收**（§3b T5）。POSIX 对 `close()` 失败后
   描述符的归属不作保证；本机 macOS 与 CI 的 Linux 都是已回收，但**我没有测试钉这一条**
   ——测「fd 到底回收没有」离不开平台细节。

③ **同一类里有一档我没修，只登记了**：`_open_source_leaf` 与 `classify_target` 的**成功路径**上，
   父目录描述符关闭失败会把**已经打开的那个叶子描述符**的关闭一起吃掉（它还没交到任何 `with` 手里）
   ⇒ 那个描述符漏掉。**它与本轮改动无关**（BASE 上 `finally: os.close(pfd)` 抛出时结局逐字相同），
   后果也只是「描述符没被回收」——盘面、账面、逃出的异常类型全不受影响。
   关它要在这两个函数里各嵌一层纯为「只读目录描述符关不上」服务的 `try/except`，我判断
   判据收益不抵可读性代价，**故登记在 §3b T5 里而不是沉默跳过**。若评审认为这仍属本轮范围，
   改法是现成的（与 `copy_one` 对 `sfd` 的处理同形），我可以补。

④ **非 `Exception` 的 `BaseException`（`KeyboardInterrupt`）那一档没有单配测试**。
   `_close_or_note` 对 `pending` 的类型不做区分，所以行为是对的（只挂诊断、不顶替），
   本机也单独验过 `__exit__` 能拿到 `KeyboardInterrupt`；但 7 条新测试覆盖的是
   `Exception` 与 `PathEscapeError` 两类，`KeyboardInterrupt` 那一格是**推断**不是**钉住**。

⑤ **`_CloseFd` 接受 `fd=None`** 可能被读成「没要求的灵活性」。它是 `classify_target` 那一格
   （`open()` 本身失败、只拿到 `st`）**直接要求**的：那一格必须继续走同一条 `_is_regular(st)`
   判据，不许在那里另抄一份「非普通 ⇒ untracked」。理由写在 `_CloseFd` 的 docstring 里。

⑥ **测试里全局 monkeypatch 了 `os.close`**。一次性解除武装（`armed`）＋命中时「先真关掉再抛」
   两个措施都在，避免 fd 号被后续 `open` 复用后误伤、以及泄漏污染同进程后面的用例；
   但这类桩天生比被测代码更脆，**它自己没有元测试**。

⑦ **评审给了两种合法收口，我替这一片选了一种**（退账 + 清落地物，而不是留落地物 + 把字节数交给
   调用方）。选择写进 §3b T4 并由 T8a 钉住。若 S4b 更想要后一种，那是**改契约**、不只是改代码。
