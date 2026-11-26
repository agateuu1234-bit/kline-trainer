# 修复轮 11 任务书 —— codex R9 的 [medium]：路径逃逸信号在 `qmt_fsroot` 里被顶替

分支 `qmt-4b-s4a`，BASE `aa49248e`。工作目录
`/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend`，
解释器 `../.venv/bin/python`（路径带空格，必须引号）。
⛔ 每条闸门命令同时打印 `git rev-parse --abbrev-ref HEAD` 与 `git rev-parse --short HEAD`。

## 一、评审原文（逐字）

> - [medium] Preserve path-escape exceptions inside directory-walking helpers (backend/qmt_fetch.py:418-424)
>   The new close protection starts after parent_fd_under returns. That helper closes intermediate
>   descriptors in an unguarded finally block: if a nested component triggers PathEscapeError and
>   closing an earlier directory fails, OSError replaces the fatal exception. Fault injection
>   against the actual helper reproduced this. This call propagates that OSError, allowing the
>   documented caller policy to skip the stock instead of terminating on a breached trust
>   boundary. The same helper is used by staging paths.
>   Recommendation: Extend exception-preserving cleanup to qmt_fsroot.parent_fd_under and
>   open_under. Add a regression test combining a nested symlink rejection with an intermediate
>   descriptor-close failure, asserting PathEscapeError reaches the copy_stock caller.

评审附注：它**没能跑全套**（沙箱缺 pandas）。全套由你跑。

## 二、⛔ 本轮**解除** `qmt_fsroot.py` 的禁改令（user 2026-09-21 拍板）

`qmt_fsroot.py` 此前在本片禁改清单里。**user 已明确拍板：这一条在本 PR 里一起修。**
理由（写进契约时照此口径）：这个修法**不改任何已写明的行为**，只是不再让收尾动作顶掉
在途异常——是纯防御性修复，与 R1 那种要改语义的情况不同类。

**仍然禁改**：`qmt_manifest.py` / `qmt_pool.py` / `qmt_ingest.py` / `qmt_normalize.py`。
交付前 `git diff --stat aa49248e -- backend/qmt_manifest.py backend/qmt_pool.py backend/qmt_ingest.py backend/qmt_normalize.py` 自证为空。

## 三、范围：按判据穷尽 `qmt_fsroot.py`，但**不许一股脑全动**

`qmt_fsroot.py` 现有 **9 个 `finally:` 块**与 **17 个 `os.close` 出现处**
（行号 262 / 282 / 288 / 319 / 365-367 / 404-406 / 480 / 620 / 673-674 / 739-740 /
871-872 / 987-988 / 990-991；这是我在 BASE 上数的，改动后会漂，**以你自己重新枚举的为准**）。

⚠️ 这是**已合并模块**，被 `qmt_manifest`（4 处调用）与本片 `qmt_fetch`（14 处）依赖，
自己有 112 条测试。**改多了会伤到别人**。所以：

对**每一个**关闭点，在报告里给出一行定性，三选一：

- **会顶替在途异常** ⇒ 要修；
- **会让后续收尾项不执行**（第一个失败吃掉后面的）⇒ 要修；
- **两者都不会** ⇒ 写清**为什么**（「它不在任何异常展开路径上」「它是那条路径唯一的收尾项」
  之类的**可核实理由**）。「看起来没问题」不算理由。

⛔ 不许只改评审点名的两个函数就说「其余同理」。
⛔ 也不许为了整齐把不需要改的一起改——每一处改动都要能说出它挡住了哪一类信号降级。

## 四、修法约束

- `qmt_fsroot` **不能 import `qmt_fetch`**（依赖方向相反），所以**不要**去复用
  `qmt_fetch._close_or_note`；在 `qmt_fsroot` 里写它自己的等价物。
  两处实现将并存 —— 在**两边的 docstring 里互相指名**，说明为什么不能合并成一处。
- 捕获宽度与 `qmt_fetch` 同规格：`Exception`，**不是** `BaseException`
  （`KeyboardInterrupt` / `SystemExit` 不许被当诊断咽掉）。
- `PathEscapeError` 在本仓的地位是「不捕获、不包装、原样上抛」——修完它必须**仍然**
  原样到达 `copy_stock` 的调用方。

## 五、测试要求

1. **评审点名的那条回归**：嵌套分量触发 `PathEscapeError` + 同时某个中间目录描述符关闭失败
   ⇒ 断言到达 `copy_stock` 调用方的**仍然是 `PathEscapeError`**，不是裸 `OSError`、
   不是 `StockCopyFailed`。
2. 你定性为「要修」的每一处，各配一条能红的测试。
3. **捕获宽度守卫**：新写的那个等价物也要有一条「`KeyboardInterrupt` 不被咽掉」的测试
   （本片已有三条同型的，照抄写法）。
4. ⛔ 断言要钉**具体那一条**，不要只断言「抛了异常」。

CI 是 **Linux**、**零容忍 skip**，不许 `skipif`。

## 六、⚠️ 验收门必须一起改（否则它会报假失败）

`docs/superpowers/acceptance/2026-09-20-qmt-4b-s4a-acceptance.md` 的 **D2** 现在写着：

> 粘贴并回车：`... git diff --stat main -- backend/qmt_fsroot.py backend/qmt_manifest.py ...`
> 预期：**没有任何输出**

`qmt_fsroot.py` 本轮会有改动 ⇒ **这条现在必然「不通过」**，而那是假失败。
请把 D2 拆成两条：
- 仍然断言四个模块（manifest / pool / ingest / normalize）**零改动**；
- 新增一条说明 `qmt_fsroot.py` **本片确有改动**，并给出一条非程序员能执行的命令
  让他看到改动**只落在收尾路径上**（例如只看 `git diff` 的统计行数，并写明预期量级）。
⚠️ 你**必须亲自把你写的每条命令跑一遍**，把真实输出贴进报告。没跑过的配方不许交付。

## 七、契约与 PR 正文

- 契约 `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md`：
  新增一节或一条，写明**本片为什么破例动了 `qmt_fsroot`**（user 拍板 + 纯防御性、不改语义），
  并把这条修复登记进 §3b 取舍表（若有对外可见代价）与 §4 交接（若有留给 S4b 的事实）。
- ⛔ 大 spec `2026-07-27-qmt-plan4b-fetch-design.md` **仍然只加纯指针、零删改**。
- 若 `qmt_fsroot` 的 docstring 里有语句因本次修复而不再成立，**一并订正**
  （本仓栽过七次：订正只落在一两层，而陈旧的注释/测试/验收门会把缺陷固化成「预期行为」）。

## 八、变异自证（缺这节报告不收）

每条新判据一次定向变异：锚点 `assert count == 1`；前后各清 `__pycache__`；
带 `PYTHONDONTWRITEBYTECODE=1`；**邻居 deselect 只跑目标那条**；
还原后 sha256 与原文件逐字相同；贴红掉的 `E   ...` 原文。
**最关键一条**：把 `parent_fd_under` 的保护去掉，第五节第 1 条那个回归必须红，
且红的现场要显示 `PathEscapeError` 被 `OSError` 顶替。

## 九、闸门

`../.venv/bin/python -m pytest tests/ -q -rs` —— BASE 是 **1596 passed / 0 skipped**，
交付时 0 failed / 0 skipped。
⚠️ 额外跑一次 `../.venv/bin/python -m pytest tests/test_qmt_fsroot.py tests/test_qmt_manifest.py -q`
并在报告里单列结果 —— 这两套是**你动的那个模块的既有用户**，它们全绿才说明没伤到别人。

## 十、交付

中文提交信息，正文说清**为什么**；结尾
`Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`。
报告写进 `.superpowers/sdd/2026-09-19-qmt-4b-s4a-impl/fixround11-report.md`，
返回值只给：状态、提交 SHA、一行测试结论、疑虑逐条列出。
⛔ 不许派子代理、不许 push、不许开 PR、不许动 `.claude/state/`。
