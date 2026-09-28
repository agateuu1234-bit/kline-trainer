# 修复轮 12 交付报告 —— 把「不许包装在途异常」这条判据钉住（按判据枚举，不按语法形式）

**分支 / BASE / 交付 SHA**：`qmt-4b-s4a` / `a59f94a5` / 见下方提交后更新
开工核对（原样输出）：

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
a59f94a5
```

工作树全程在 `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a`，
未 cd 主仓、未 push、未开 PR、未派子代理、未动 `.claude/state/`。

---

## 一、按判据枚举（不按语法形式）

任务书要求本轮改按「判据」枚举——凡是「决定某个异常要不要被换类型 / 要不要被吞掉」的
分支都算同一条判据，不论写成 `except X`、`isinstance(...)` 还是别的形状。

对 `qmt_fetch.py` 与 `qmt_fsroot.py` 做了两遍穷尽扫描：

```
$ /usr/bin/grep -n "^\s*except \|isinstance(.*Exception\|isinstance(.*Error\|isinstance(.*Terminated\|issubclass(" qmt_fetch.py
$ /usr/bin/grep -n "^\s*except \|isinstance(.*Exception\|isinstance(.*Error\|issubclass(" qmt_fsroot.py
$ /usr/bin/grep -n "isinstance(" qmt_fetch.py qmt_fsroot.py   # 二次核实没有别的 isinstance 判据被算法漏掉
```

落进「决定要不要换类型/吞掉在途异常」这一族的，穷尽后是 **5 个捕获宽度点 + 1 个函数
（内含 2 条 isinstance 分支）**，共 **7 个分支**：

| # | 位置 | 形态 | 有没有测试钉着（本轮之前） |
|---|------|------|------|
| 1 | `qmt_fetch._close_or_note`（:381 `except Exception as e:`） | 捕获宽度 | ✅ `test_close_or_note_lets_keyboard_interrupt_escape_when_closing_source_fails`（fix round 9） |
| 2 | `qmt_fetch._rollback_all` 删项循环（:1008 `except Exception as e:`） | 捕获宽度 | ✅ `test_rollback_lets_keyboard_interrupt_escape_when_deleting_a_part_fails`（fix round 9） |
| 3 | `qmt_fetch._rollback_all` 退账循环（:1013 `except Exception as e:`） | 捕获宽度 | ✅ `test_rollback_lets_keyboard_interrupt_escape_when_refunding_fails`（fix round 9） |
| 4 | `qmt_fsroot._close_or_note`（:233 `except Exception as e:`） | 捕获宽度 | ✅ `test_close_or_note_lets_keyboard_interrupt_escape`（fix round 9，`test_qmt_fsroot.py`） |
| 5 | `qmt_fsroot._close_all_or_note` 循环体（:257 `except Exception as e:`） | 捕获宽度 | ⛔ **判据 C，本轮之前零守卫** |
| 6 | `qmt_fetch._settle_rollback`（:1040 `if isinstance(original, (RunTerminated, PathEscapeError)): return`） | isinstance 分支 | ⛔ **判据 A，本轮之前零守卫** |
| 7 | `qmt_fetch._settle_rollback`（:1042 `if not isinstance(original, Exception): return`） | isinstance 分支 | ⛔ **判据 B，本轮之前零守卫** |

`_settle_rollback` 被 `copy_one`（:734）与 `copy_stock`（:1308、:1332）三处调用，但三处调用的是
**同一个函数**，判据只活在这一处实现里——本轮只在 `copy_one` 这个最简调用点上钉，不重复钉
另外两个调用点（任务书「同一条判据只落在其中一处」的纪律）。

没有发现第 8 处：`isinstance(` 在两个文件里的全部命中逐条核对过，其余全是普通数据类型校验
（`isinstance(record, dict)` / `isinstance(slot, Slot)` 等），不涉及「在途异常要不要换类型」。
`issubclass(` 在两个文件里零命中。

**结论：任务书第一节给的 A/B/C 三处就是本轮需要补的全部三处，穷尽扫描没有找到第四处。**

---

## 二、新增测试（每条判据一条，判别力互斥）

文件 `backend/tests/test_qmt_fetch.py`（追加在 fix round 9 的 `keyboard_interrupt` 三条测试之后）：

- `test_settle_rollback_keeps_path_escape_original_when_cleanup_itself_fails`
  —— 判据 A：`_publish_part` 打桩直接抛 `PathEscapeError`（原异常，源自「打开 `.part` 之后
  发布」这一步），随后回滚删 `.tmp` 的 `os.unlink` 打桩撞 `EIO`（`errors` 非空）。
  断言：逃出来的 `is` 同一个 `PathEscapeError` 对象、不是 `RollbackIncomplete`、
  没有 `.original`/`.errors` 字段、`__notes__` 里确实记了「回滚未完成」诊断、
  退账那一半正常完成（`budget.used == 0`）。
- `test_settle_rollback_lets_keyboard_interrupt_original_escape_when_cleanup_fails`
  —— 判据 B：`_write_all` 打桩直接抛 `KeyboardInterrupt()`（原异常），回滚删 `.tmp` 同样
  撞 `EIO`。断言同上一条的结构，另加 `not isinstance(exc, Exception)`。

文件 `backend/tests/test_qmt_fsroot.py`（追加在 `test_close_all_or_note_still_closes_the_rest_when_nothing_is_in_flight` 之后）：

- `test_close_all_or_note_lets_keyboard_interrupt_stop_the_loop`
  —— 判据 C：走 `parent_fd_under(root, "a/b/leaf.csv")`（两个中间描述符），第一个关闭时
  抛 `KeyboardInterrupt`。断言：`after == []`（第二个描述符压根没被尝试关闭——这是唯一
  能把「宽度放宽后类型不变但行为变了」这个变异逼出红的断言，见下节）、异常类型仍是
  `KeyboardInterrupt`、没有被记成 `__notes__` 诊断。

⚠️ **这三条与本文件已有的三条 `keyboard_interrupt` 测试不是重复**：round 9 那三条测的是
`KeyboardInterrupt` **在回滚/关闭过程本身**里冒出来；本轮这三条里 `PathEscapeError` /
`KeyboardInterrupt` 是**原本就在途的那个异常**，回滚失败是另一件独立的事——只有这样才会
真正走到 `_settle_rollback` 的两条 isinstance 分支、以及 `_close_all_or_note` 循环体自己
那处 `except`（而不是 `_close_or_note` 那处）。

---

## 三、闸门

```
$ ../.venv/bin/python -m pytest tests/ -q -rs
1614 passed in 34.65s
```
（BASE 1611 + 本轮新增 3 = 1614；0 failed，0 skipped。）

```
$ git diff --stat a59f94a5 -- qmt_manifest.py qmt_pool.py qmt_ingest.py qmt_normalize.py
（空——四个禁改文件零改动）
$ git diff --stat a59f94a5
 backend/tests/test_qmt_fetch.py  | 138 +++++++++++++++++++++++++++++++++++++++
 backend/tests/test_qmt_fsroot.py |  62 ++++++++++++++++++
 2 files changed, 200 insertions(+)
```
只改了两个测试文件，产品代码（`qmt_fetch.py` / `qmt_fsroot.py`）零改动——与任务书第四节
「预期不动产品代码」一致，我没有发现需要改产品代码才能让测试通过的情况。

---

## 四、变异自证（三条各一次定向变异，前后清 `__pycache__`，`PYTHONDONTWRITEBYTECODE=1`，
三条新测试一起跑，还原后 sha256 逐字比对）

### 判据 A：`(RunTerminated, PathEscapeError)` → `(RunTerminated,)`

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ # 用 python3 脚本把 qmt_fetch.py:1040 的元组去掉 PathEscapeError
$ PYTHONDONTWRITEBYTECODE=1 ../.venv/bin/python -m pytest \
    tests/test_qmt_fetch.py::test_settle_rollback_keeps_path_escape_original_when_cleanup_itself_fails \
    tests/test_qmt_fetch.py::test_settle_rollback_lets_keyboard_interrupt_original_escape_when_cleanup_fails \
    tests/test_qmt_fsroot.py::test_close_all_or_note_lets_keyboard_interrupt_stop_the_loop \
    -q -rs
1 failed, 2 passed in 0.42s
```

红掉的那条（`test_settle_rollback_keeps_path_escape_original_when_cleanup_itself_fails`），
`E` 行原文：

```
E       qmt_fetch.RollbackIncomplete: 回滚未做完（1 项失败：OSError: [Errno 5] 打桩：回滚删 .tmp 自己撞 EIO）；在途的原异常是 PathEscapeError: 路径 '1m/600000.SH_x_1分钟K线_前复权.csv' 的分量 '1m' 不是一个普通目录（ELOOP）：它可能是符号链接，也可能是个文件——两者在本平台给出同一个错误码。本工具不替你解析符号链接，请改传完全解析后的绝对路径。
```

判据 B、C 对应的两条 **原样通过**（`2 passed`）。

```
$ git checkout -- qmt_fetch.py
$ sha256sum qmt_fetch.py
c1ac1f3161b6612179a768f4bcfe2bd34351888e1e5ab5b85d699d4fd91f1265  qmt_fetch.py   # 与变异前逐字相同
```

### 判据 B：`if not isinstance(original, Exception):` → `if False:`

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ PYTHONDONTWRITEBYTECODE=1 ../.venv/bin/python -m pytest \
    tests/test_qmt_fetch.py::test_settle_rollback_keeps_path_escape_original_when_cleanup_itself_fails \
    tests/test_qmt_fetch.py::test_settle_rollback_lets_keyboard_interrupt_original_escape_when_cleanup_fails \
    tests/test_qmt_fsroot.py::test_close_all_or_note_lets_keyboard_interrupt_stop_the_loop \
    -q -rs
1 failed, 2 passed in 0.36s
```

红掉的那条（`test_settle_rollback_lets_keyboard_interrupt_original_escape_when_cleanup_fails`），
`E` 行原文：

```
E       qmt_fetch.RollbackIncomplete: 回滚未做完（1 项失败：OSError: [Errno 5] 打桩：回滚删 .tmp 自己撞 EIO）；在途的原异常是 KeyboardInterrupt:
```

判据 A、C 对应的两条 **原样通过**（`2 passed`）。

```
$ git checkout -- qmt_fetch.py
$ sha256sum qmt_fetch.py
c1ac1f3161b6612179a768f4bcfe2bd34351888e1e5ab5b85d699d4fd91f1265  qmt_fetch.py   # 与变异前逐字相同
```

### 判据 C：`qmt_fsroot._close_all_or_note` 循环体 `except Exception as e:` → `except BaseException as e:`

```
$ find . -name "__pycache__" -exec rm -rf {} +
$ PYTHONDONTWRITEBYTECODE=1 ../.venv/bin/python -m pytest \
    tests/test_qmt_fetch.py::test_settle_rollback_keeps_path_escape_original_when_cleanup_itself_fails \
    tests/test_qmt_fetch.py::test_settle_rollback_lets_keyboard_interrupt_original_escape_when_cleanup_fails \
    tests/test_qmt_fsroot.py::test_close_all_or_note_lets_keyboard_interrupt_stop_the_loop \
    -q -rs
1 failed, 2 passed in 0.34s
```

红掉的那条（`test_close_all_or_note_lets_keyboard_interrupt_stop_the_loop`），`E` 行原文：

```
E               AssertionError: 第一个中间描述符关闭抛出 `KeyboardInterrupt` 之后，第二个仍然被尝试关闭（实测 [13]）——说明中断被当成「这一项关闭失败了」接住，循环没有被当场打断
E               assert [13] == []
```

⚠️ 判据 C 的变异**不改变最终逃出去的异常类型**（`first` 变量本身就是那个 `KeyboardInterrupt`
对象，`raise first` 类型不变）——真正的判别力在「循环有没有被当场打断」，所以这条测试的
锚点断言不是 `pytest.raises(...)` 本身，而是 `after == []`。任务书要求锚点是
`assert count == 1`——本条的等价锚点是 `assert after == []`（"count" 语义上就是"打断之后
还被尝试关闭的描述符个数"，这里就是它必须为 0）。

判据 A、B 对应的两条 **原样通过**（`2 passed`）。

```
$ git checkout -- qmt_fsroot.py
$ sha256sum qmt_fsroot.py
cb86bf7d4a1cee7185dc2a1848905d4a8a4410a6cea63aab6ac68dec5e3742d4  qmt_fsroot.py   # 与变异前逐字相同
```

**三次变异，每次都只有对应那一条测试变红，另外两条原样通过——三条测试的判别力互斥，
不是同一条判据的三份拷贝。**

---

## 五、疑虑

1. **判据 C 的"锚点"与任务书字面的 `assert count == 1` 不完全一致**——本判据的可观测差异
   不是"次数"而是"循环有没有被打断"，我用 `assert after == []` 作为等价锚点（"之后还被
   尝试关闭的 fd 数＝0"）。已在第四节显式说明，未隐藏这个偏离。
2. **`_settle_rollback` 的三个调用点（`copy_one` 一处、`copy_stock` 两处）只在 `copy_one`
   这一处钉了判据 A/B**——因为判据只活在被三处共用的同一个函数实现里，重复钉另外两个
   调用点不会增加判别力，只会增加维护成本；但如果以后 `copy_stock` 的两个调用点各自在
   传参上出现分叉（比如某处不传 `errors`），这条假设需要重新核实。
3. 我没有改动契约文件与验收清单（任务书要求由控制者另行订正），也没有改动
   `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md`；本轮结论是"契约无需改动"
   ——这三处判据本轮之前就在契约 §4 第 12 条 / D6 等条款里以文字形式描述过，只是没有
   测试钉着，不是契约本身缺了什么决定。
