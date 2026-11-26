# 修复轮 8 任务书 —— codex R5 的 [medium]

分支 `qmt-4b-s4a`，BASE `3b6e2dfb`。所有命令在
`/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend` 下跑，
解释器 `../.venv/bin/python`（路径带空格，必须引号）。
⛔ 每条闸门命令都要同时打印 `git rev-parse --abbrev-ref HEAD` 与 `git rev-parse --short HEAD`。

## 一、评审原文（逐字，不要改写、不要替它降级）

> - [medium] Handle source close failures inside the rollback boundary (backend/qmt_fetch.py:609-612)
>   The unconditional os.close(sfd) runs outside copy_one’s rollback handler. If it raises after
>   publication, copy_one never returns, so copy_stock never adds this file to written: the outer
>   rollback deletes its .part but cannot refund its bytes. A close failure during exception
>   unwinding also replaces MaxBytesExhausted with a bare OSError, which the documented caller
>   contract permits treating as a candidate failure. Isolated fault injection reproduced both
>   outcomes: three charged bytes remained after a failed return, and MaxBytesExhausted escaped
>   as OSError.
>   Recommendation: Include source-descriptor closure in the transaction’s failure handling.
>   Preserve any existing termination exception, and ensure a close failure before returning
>   refunds this copy’s charged bytes and cleans its published part. Add fault-injection tests
>   for close failure after successful copying and while unwinding MaxBytesExhausted.

评审附注：它**没能跑全套**（沙箱缺 pandas），只做了隔离故障注入。全套由你跑。

## 二、这是一个**复发**，所以范围不是它点名的那一行

上一轮（fix round 7）修的正是同一个判据——「收尾动作抛的异常顶替在途原异常 /
吃掉后续收尾项」——当时修了三处（`copy_one` 的删临时文件、`copy_stock` 主回滚、
标记发布失败处置），抽象出 `_rollback_all` / `_settle_rollback` / `RollbackIncomplete`。
`os.close(sfd)` 漏了，因为它关的是**源**描述符、不是 `.part`，长得不像「回滚项」。

⇒ **本轮必须按判据穷尽本模块，而不是按评审给的行号。**

### 必做：逐个字面量枚举 + 逐条定性（不许用概念搜词代替）

`qmt_fetch.py` 现有 **12 个关闭点**（`os.close` 出现在 344 / 369 / 433 / 464 / 508 /
583 / 597 / 610 / 712 / 724 / 863 / 940 行）与 **10 个 `finally:` 块**（343 / 368 /
507 / 582 / 596 / 609 / 711 / 722 / 862 / 939）。行号是我 BASE 时点数的，改动后会漂，
**以你自己重新枚举的为准**。

对**每一个**，在报告里给出一行定性，三选一：

- **会顶替在途异常** —— 该处在某条路径上可能在异常展开途中抛出，且没有被任何
  `_settle_rollback` 之类的收口接住 ⇒ **要修**。
- **会漏掉记账 / 漏掉清理** —— 该处抛出会让调用方拿不到本次的字节数或落地物 ⇒ **要修**。
- **两者都不会** —— 必须写清**为什么**（例如：它在 `try` 之前就不可能有在途异常、
  或它本身就在收口函数内部）。「看起来没问题」不算理由。

⛔ 不许只改评审点名那一处然后说「其余同理」。
⛔ 不许把这条判据写成文档里的新规矩就算修完——要落在代码上。

## 三、约束（逐字生效，与前几轮相同）

1. **禁改模块**：`qmt_fsroot.py` / `qmt_manifest.py` / `qmt_pool.py` / `qmt_ingest.py` /
   `qmt_normalize.py` 一个字节都不许动。交付前用
   `git diff --stat 3b6e2dfb -- backend/qmt_fsroot.py backend/qmt_manifest.py backend/qmt_pool.py backend/qmt_ingest.py backend/qmt_normalize.py`
   自证为空。
2. **异常族的契约不许动**：`RunTerminated` 三个成员（`MaxBytesExhausted` /
   `SourceChangedMidRun` / `RollbackIncomplete`）与 `PathEscapeError`
   「本模块不捕获、不包装、原样上抛」的地位是调用方判据。终止信号**绝不能**被换类型。
3. **失败 `reason` 是闭集 4 个**，不许新增：`fetch_missing_file` /
   `fetch_copy_hash_mismatch` / `untracked_target_file` / `fetch_interrupted_rollback`。
4. 本片**不做命令行**：`grep -c argparse qmt_fetch.py` 必须是 0。
5. 契约文件 `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md` 是权威。
   若你的改动让契约里某句话不再成立，**改契约**并在报告里单列；
   若改动引入新的对外可见取舍，加进 §3b 并在 §4 交接里写一条（只写事实，
   不替 S4b 开药方）。§4 交接项当前 15 条，新增就续号。

## 四、测试要求

- 评审点名的两个场景各要一条故障注入测试：
  (a) 拷贝成功、发布之后 `os.close(sfd)` 抛 `OSError` —— 断言**账实相符**
      （退账做了 / 或落地物留下且字节数被调用方收到，两种收口都可以，但必须
      在契约里写明选了哪种，并让测试钉住它）；
  (b) `MaxBytesExhausted` 展开途中 `os.close(sfd)` 抛 `OSError` —— 断言逃出来的
      **仍然是 `MaxBytesExhausted`**，不是裸 `OSError`、不是 `StockCopyFailed`。
- 你按上面第二节定性为「要修」的每一处，各配一条能红的测试。
- ⛔ 断言要钉**具体那一条**，不要只断言「抛了异常」。

## 五、变异自证（缺这节报告不收）

对你新增/改动的**每一条**判据做一次定向变异，每次都要：
1. 锚点在源文件里**恰好命中 1 处**（脚本里写 `assert count == 1`，命中 2 处就换更长的锚点）；
2. 变异前后各清一次 `__pycache__`（`find . -name __pycache__ -exec rm -rf {} +`），
   跑测试时带 `PYTHONDONTWRITEBYTECODE=1`；
3. **把邻居 deselect 掉、只跑目标那一条**，证明红的是它而不是别人；
4. 还原后用 sha256 自证与原文件逐字相同；
5. 报告里写清**红的是哪一条断言**（贴那行 `E   ...`），不是「有测试变红」。

## 六、闸门

`../.venv/bin/python -m pytest tests/ -q -rs` —— BASE 处是 **1584 passed / 0 skipped**。
交付时必须 **0 failed / 0 skipped**（本仓 CI 零容忍 skip）。

## 七、交付

- 小步提交，提交信息中文，正文说清**为什么**而不只是**改了什么**，
  结尾加 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`。
- 报告写进
  `.superpowers/sdd/2026-09-19-qmt-4b-s4a-impl/fixround8-report.md`，
  返回值只给：状态、提交 SHA、一行测试结论、以及你的疑虑清单（逐条列，不要只给数量）。
- ⛔ 你**不许**再派子代理，也不许自己派评审——评审由我在你报告之后发。
- ⛔ 不许 push、不许开 PR、不许动 `.claude/state/` 下任何文件。
