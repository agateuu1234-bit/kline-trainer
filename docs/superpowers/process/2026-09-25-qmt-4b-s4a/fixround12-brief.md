# 修复轮 12 任务书 —— 把「不许包装在途异常」这条判据钉住

分支 `qmt-4b-s4a`，BASE `a59f94a5`。工作目录
`/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend`，
解释器 `../.venv/bin/python`（路径带空格，必须引号）。
⛔ 每条闸门命令同时打印 `git rev-parse --abbrev-ref HEAD` 与 `git rev-parse --short HEAD`。

## 一、事实（我亲手实测的，不是推断）

`qmt_fetch._settle_rollback` 有两条刻意的判据，现在**一条守卫都没有**：

```
    if isinstance(original, (RunTerminated, PathEscapeError)):   # ← 判据 A
        return
    if not isinstance(original, Exception):                      # ← 判据 B
        return
    raise RollbackIncomplete(...)
```

我做了两次定向变异，**全套 1611 条各跑一遍，两次都是 `1611 passed`、零条变红**：

- **判据 A**：把 `PathEscapeError` 从元组里去掉 ⇒ 路径逃逸（信任边界被突破）
  会被包成 `RollbackIncomplete`，而且契约 §4 第 12 条要 S4b 去扫的那个
  `PathEscapeError` 会落在 `.original` 而不是 `.errors`。
- **判据 B**：改成 `if False:` ⇒ `KeyboardInterrupt`（用户按 Ctrl-C）叠上
  「回滚删临时文件撞 EIO」时，中断被吞成 `RollbackIncomplete`。

另有第三处同族，也零守卫：

- **判据 C**：`qmt_fsroot._close_all_or_note`（约在 `qmt_fsroot.py:257`）的
  `except Exception` 捕获宽度。放宽成 `BaseException` ⇒ 全套 1611 全绿。
  ⚠️ 同模块的 `_close_or_note`（约 :233）**有**守卫、实测能红 —— 所以这是
  「同一条判据落在两处、只钉住了一处」。

## 二、为什么会漏（写给你，也是这轮的判据来源）

fix round 9 立项就是为了消灭这个形态，当时的任务书要求「按字面量枚举
`except Exception`」，于是**三处语法形式相同的**被找到并钉住了，而同一条判据
**写成 `isinstance(...)` 表达式**的这两处漏掉了。

⇒ **本轮请按「判据」枚举，不要按「语法形式」枚举。**
这个模块里凡是「决定某个异常要不要被换类型 / 要不要被吞掉」的分支，都属于同一条判据，
无论它写成 `except X`、`isinstance(...)`、`issubclass(...)`、还是别的形状。
请在报告里给出你枚举到的**全部**这类分支，并逐条说明「它有没有测试钉着」
（有的话给出测试名；没有的话本轮补上）。

## 三、要做的事

给上面判据 A / B / C **各加一条测试**，并补上你自己枚举出的其余无守卫者。

判据：每条测试必须在**对应那一处**被改坏时变红，且在**另外两处**被改坏时**不**变红
（否则它们其实是同一条测试）。

- 断言要钉**具体行为**：
  · A —— 路径逃逸场景下逃出来的**仍是 `PathEscapeError`**，不是 `RollbackIncomplete`，
    并且它**没有**被塞进 `.errors` / `.original`（按现场实际结构写断言）；
  · B —— `KeyboardInterrupt` 原样逃出，不是 `RollbackIncomplete`；
  · C —— 同 A/B 的形状，钉住 `qmt_fsroot` 那一处。
- ⛔ 不要只断言「抛了异常」。

## 四、预期不动产品代码

这三处现在的**行为是对的**，缺的只是守卫。若你发现必须改产品代码才能让测试通过，
**说明我上面的事实陈述有误** —— 停下来在报告里写清你测到了什么，不要顺着改。

## 五、变异自证（缺这节报告不收）

每条新测试一次定向变异，每次：锚点 `assert count == 1`；前后各清 `__pycache__`；
带 `PYTHONDONTWRITEBYTECODE=1`；**把你新加的其它测试也一起跑**，证明只有对应那条红；
还原后 sha256 与原文件逐字相同；报告里贴每条红掉的 `E   ...` 原文。

## 六、闸门与约束

- `../.venv/bin/python -m pytest tests/ -q -rs`：BASE 是 **1611 passed / 0 skipped**，
  交付时 0 failed / 0 skipped。
- 禁改：`qmt_manifest.py` / `qmt_pool.py` / `qmt_ingest.py` / `qmt_normalize.py`，
  交付前 `git diff --stat a59f94a5 -- <这四个>` 自证为空。
- 契约 `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md` 是权威；
  本轮只加守卫、不改决定，**预期契约无需改动**；若你认为需要改，单列说明理由。
  ⚠️ 验收清单与契约本轮**由控制者另行订正**，你不要动这两个文件。

## 七、交付

中文提交信息，正文说清**为什么**；结尾
`Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`。
报告写进 `.superpowers/sdd/2026-09-19-qmt-4b-s4a-impl/fixround12-report.md`，
返回值只给：状态、提交 SHA、一行测试结论、疑虑逐条列出。
⛔ 不许派子代理、不许 push、不许开 PR、不许动 `.claude/state/`。
