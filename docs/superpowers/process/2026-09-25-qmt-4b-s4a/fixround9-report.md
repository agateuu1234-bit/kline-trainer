# 修复轮 9 报告 —— 把「捕获宽度」这个刻意决定钉住

分支 / BASE 自证（开工第一条命令）：

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
0e3e52a6
```

工作目录：`/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a`（全程未 cd 主仓）。
解释器：`../.venv/bin/python`（从 `backend/` 内调用）。

---

## 一、结论先行

任务书事实核实为真：`qmt_fetch.py` 三处 `except Exception as e:`（`_close_or_note`
关描述符一处、`_rollback_all` 删项与退账项各一处）此前只在 docstring 里写着「为什么
是 `Exception` 而不是 `BaseException`」的理由，没有任何测试钉住这个决定。本轮**只加
测试，不改产品代码**：给这三处各配一条测试，注入 `KeyboardInterrupt`（对应真实场景：
长跑批量拷贝时用户按 Ctrl-C），钉住「非 `Exception` 的 `BaseException` 必须原样逃出去，
不许被记进诊断、不许被收进 `RollbackIncomplete.errors`」。

`qmt_fetch.py` 一个字节没动（与 BASE 逐字相同，见下方 sha256）；只改了
`backend/tests/test_qmt_fetch.py`（新增 165 行、3 条测试）。

---

## 二、三条测试

| 测试名 | 钉的那一处 | 场景 |
|---|---|---|
| `test_close_or_note_lets_keyboard_interrupt_escape_when_closing_source_fails` | `_close_or_note`（紧跟 `os.close(fd)`） | `MaxBytesExhausted` 展开途中关源描述符抛 `KeyboardInterrupt` |
| `test_rollback_lets_keyboard_interrupt_escape_when_deleting_a_part_fails` | `_rollback_all` 删项（紧跟 `_cleanup_part(...)`） | 裸 `OSError` 展开途中删 `.tmp` 抛 `KeyboardInterrupt` |
| `test_rollback_lets_keyboard_interrupt_escape_when_refunding_fails` | `_rollback_all` 退账项（紧跟 `budget.refund(n)`） | 同上原异常，删除那一半先正常完成，退账那一步才抛 `KeyboardInterrupt` |

每条测试都带前提断言（注入确实命中、"另一半"确实按预期状态存在/完成），并按任务书
第二节要求断言**具体行为**：

- `pytest.raises(KeyboardInterrupt)`——逃出来的就是那个中断本身，不是被顶替成
  `MaxBytesExhausted`/`OSError`/`RollbackIncomplete`；
- `assert not isinstance(exc, Exception)`；
- `assert not any("关描述符失败" in n for n in getattr(exc, "__notes__", []))`
  （第一条）／`assert not getattr(boom, "__notes__", [])`（后两条）——中断没有被
  当成诊断记下来，不是被 `except BaseException` 接住之后转手 `add_note`。

三条测试互斥（同一次调用里三处 `except` 恰好只有一处真的接到在途异常，另外两处
这一趟根本没轮到执行），每条测试都用一句「另一半确实先正常做完/没做到」的前提断言
把这一点钉住，不是靠推断。

---

## 三、变异自证（脚本 + 三次运行的真实输出）

脚本：`mutate_round9.py`（临时文件，不入库），逻辑：

1. 锚点必须**连同上一行**才唯一（三处 `except Exception as e:` 文本相同）：
   - 锚点 1：`"        os.close(fd)\n    except Exception as e:\n"`
   - 锚点 2：`"            _cleanup_part(stg_fd, name)\n        except Exception as e:\n"`
   - 锚点 3：`"            budget.refund(n)\n        except Exception as e:\n"`
   脚本内 `assert count == 1` 逐条确认命中恰好 1 处；
2. 变异前后各清一次 `__pycache__`，跑测试带 `PYTHONDONTWRITEBYTECODE=1`；
3. 每次把三条目标测试**一起跑**（用 nodeid 精确指定），证明只有对应那条红；
4. 还原后 `sha256` 与原文件逐字相同：原文件 / 三次还原后均为
   `c8339b8b269bfcde1956725789b617f16455acb560509d1ade1a7ba5fbb53de1`。

### 锚点 1（`_close_or_note`）→ 变宽后 `except BaseException as e:`

```
已变异锚点 1（命中 1 次确认）
F..                                                                      [100%]
1 failed, 2 passed
```

红掉的那条（其余两条绿）：

```
E   qmt_fetch.MaxBytesExhausted: charge：剩余 36 字节，本块 64 字节
E   关描述符失败（fd=13）——KeyboardInterrupt:
```

——`MaxBytesExhausted` 展开途中的中断被 `except BaseException` 接住、转手挂成了
`add_note`（"关描述符失败..."），中断本身没能原样逃出去，`pytest.raises(KeyboardInterrupt)`
落空，逃出来的是被降级过的 `MaxBytesExhausted`。

### 锚点 2（`_rollback_all` 删项）→ 变宽后 `except BaseException as e:`

```
已变异锚点 2（命中 1 次确认）
.F.                                                                      [100%]
1 failed, 2 passed
```

红掉的那条（其余两条绿）：

```
E   qmt_fetch.RollbackIncomplete: 回滚未做完（1 项失败：KeyboardInterrupt: ）；
    在途的原异常是 OSError: [Errno 5] 打桩：拷到一半 SMB 断线
```

——删 `.tmp` 时的中断被接住、收进 `errors`，`_settle_rollback` 因此把裸 `OSError`
升级成 `RollbackIncomplete`；中断没有原样逃出去，反而被结构化地塞进
`RollbackIncomplete.errors` 与 `original.__notes__`（"回滚未完成：删 ... 失败——
KeyboardInterrupt:"）。

### 锚点 3（`_rollback_all` 退账项）→ 变宽后 `except BaseException as e:`

```
已变异锚点 3（命中 1 次确认）
..F                                                                      [100%]
1 failed, 2 passed
```

红掉的那条（其余两条绿）：

```
E   qmt_fetch.RollbackIncomplete: 回滚未做完（1 项失败：KeyboardInterrupt: ）；
    在途的原异常是 OSError: [Errno 5] 打桩：拷到一半 SMB 断线
```

（原始日志里紧邻一句 `E   回滚未完成：退还 140 字节 失败——KeyboardInterrupt:`，
证明这次是退账那一格被收进诊断，不是删项那一格。）

三次变异**各自只命中对应的那一条测试**，另外两条全程保持绿——这就是「三条不是
同一条判据的三份拷贝」的直接证据，而不是推断。

---

## 四、闸门

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
0e3e52a6
$ ../.venv/bin/python -m pytest tests/ -q -rs
1594 passed in 36.07s
```

BASE 1591 passed / 0 skipped → 交付 **1594 passed / 0 failed / 0 skipped**（新增 3 条）。

禁改模块自证（输出为空）：

```
$ git diff --stat 0e3e52a6 -- backend/qmt_fsroot.py backend/qmt_manifest.py \
      backend/qmt_pool.py backend/qmt_ingest.py backend/qmt_normalize.py
(空)
```

`git diff --stat 0e3e52a6` 只有一个文件：`backend/tests/test_qmt_fetch.py | 165 ++++`
（产品代码 `qmt_fetch.py` 逐字未动）。

---

## 五、契约

未改动 `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md`——本轮只给已有决定
配守卫，没有新增或调整任何行为决定，任务书第六节的预期成立。

---

## 六、我的疑虑（逐条）

① **只覆盖了 `KeyboardInterrupt`，没有单独测 `SystemExit`**。任务书原话是
  「`KeyboardInterrupt`（或 `SystemExit`）」，两者都不是 `Exception` 子类、走的是
  同一条 `except Exception` 判据，我判断二选一即可证明「宽度就是分界」，没有另配
  一条 `SystemExit` 版本——如果评审认为两者要分别钉（比如 `SystemExit` 携带
  `code` 属性、调用方某处若误判 `isinstance(e, BaseException)` 之外还查了别的
  属性），我可以照抄这三条的写法各补一条。

② **`_rollback_all` 的两条测试（删项、退账项）都用同一个"原异常"场景**
  （`_write_all` 抛 `OSError(EIO, ...)` 触发回滚），只是让中断命中循环体的
  不同半区。这是刻意的——同一个函数、同一段代码路径，让"命中哪一半"成为唯一
  变量，才能干净地证明两条不是同一条判据的拷贝；但这也意味着这两条测试没有
  覆盖"原异常本身就是终止信号（`RunTerminated`/`PathEscapeError`）时中断怎么办"
  这一格——不过 `_settle_rollback` 对这一格的判据（`isinstance(original,
  (RunTerminated, PathEscapeError)): return`）本轮完全没有触碰，任务书范围里
  也没有点名要测它，我判断不属于本轮"捕获宽度"这一件事。

③ **变异脚本 `mutate_round9.py` 是临时文件，没有入库**（任务书没有要求登记成
  仓库内的 `selfcheck_*.sh`，且它只对 `qmt_fetch.py` 做纯文本替换 + 还原，没有
  `docker`/外部依赖那种需要留档重跑的复杂度）。若需要它成为仓库内可重跑的
  自查脚本，我可以照 `backend/scripts/selfcheck_c1_mutation.sh` 的规格补一份。

④ **三条测试都通过 `copy_one` 这一个公开入口间接触达三处判据，没有直接单测
  `_close_or_note` / `_rollback_all` 这两个私有函数本身**。这与本文件既有风格
  一致（round 7/8 的同类测试也都走 `copy_one`/`copy_stock`），但如果这两个私有
  函数未来被其它调用方复用（目前只有 `copy_one` 一处调 `_rollback_all`，
  `_CloseFd` 有多处调用点），新调用点是否也会被这三条测试保护到，取决于它是否
  复用同一套异常展开路径——不是自动继承的。
