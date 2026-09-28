# 修复轮 9 任务书 —— 把「捕获宽度」这个刻意决定钉住

分支 `qmt-4b-s4a`，BASE `0e3e52a6`。工作目录
`/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend`，
解释器 `../.venv/bin/python`（路径带空格，必须引号）。
⛔ 每条闸门命令同时打印 `git rev-parse --abbrev-ref HEAD` 与 `git rev-parse --short HEAD`。

## 一、事实（我实测的，不是推断）

`qmt_fetch.py` 有**三处**刻意把捕获宽度写成 `Exception` 而不是 `BaseException`，
并且两处 docstring 把它当成决定写着，理由是逐字的：
「`KeyboardInterrupt` / `SystemExit` 不是「这一项失败了」，不许被收进明细/挂成诊断顺手咽下去」。

三处是：

1. `_close_or_note` 里 `except Exception as e:`（紧跟 `os.close(fd)`）
2. `_rollback_all` 删项那个 `except Exception as e:`（紧跟 `_cleanup_part(stg_fd, name)`）
3. `_rollback_all` 退账项那个 `except Exception as e:`（紧跟 `budget.refund(n)`）

**我把这三处各自改成 `except BaseException as e:`，全套 1591 条测试各跑一遍，
三次都是 `1591 passed`、零条变红。**

⇒ 这个决定目前**只活在散文里**。下一次有人「顺手统一一下异常处理」把它放宽，
没有任何东西会红。真实后果：长时间运行（400 只股）时用户按 Ctrl-C，
中断会在收尾路径上被吃掉，运行不停。

## 二、要做的事

给这三处**各加一条测试**，钉住「非 `Exception` 的 `BaseException` 不被咽掉」。

判据：该测试必须在**对应那一处**被放宽成 `BaseException` 时变红，
且在**另外两处**被放宽时**不**变红（否则三条测试其实只是同一条）。

- 断言要钉**具体行为**：`KeyboardInterrupt`（或 `SystemExit`）必须原样逃出去，
  而不是变成 `.errors` 里的一项、或变成在途异常的一条 `__notes__`。
- ⛔ 不要只断言「抛了某个异常」——要断言**逃出来的就是那个 `BaseException`**，
  并断言它**没有**被记进诊断（例如 `assert "关描述符失败" not in ...`，按现场实际措辞写）。

## 三、预期不动产品代码

这三处现在的行为**已经是对的**，缺的只是守卫。如果你发现必须改产品代码才能让测试通过，
**说明我上面的事实陈述有误** —— 那就停下来，在报告里写清你测到了什么，不要顺着改。

## 四、变异自证（缺这节报告不收）

三条测试各做一次定向变异，每次：
1. 锚点在源文件里**恰好命中 1 处**（脚本里 `assert count == 1`；这三处的
   `except Exception as e:` 彼此文本相同，**必须连同上一行一起做锚点**才唯一）；
2. 前后各清一次 `__pycache__`，跑测试带 `PYTHONDONTWRITEBYTECODE=1`；
3. **把另外两条测试也一起跑**，证明只有对应那条红（这就是「互相不是同一条」的证据）；
4. 还原后 sha256 与原文件逐字相同；
5. 报告里贴每条红掉的 `E   ...` 原文。

## 五、闸门

`../.venv/bin/python -m pytest tests/ -q -rs` —— BASE 是 **1591 passed / 0 skipped**，
交付时应为 **1594 passed / 0 failed / 0 skipped**（本仓 CI 零容忍 skip）。

## 六、约束

- 禁改模块：`qmt_fsroot.py` / `qmt_manifest.py` / `qmt_pool.py` / `qmt_ingest.py` /
  `qmt_normalize.py`，交付前 `git diff --stat 0e3e52a6 -- <这五个>` 自证为空。
- 契约 `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md` 是权威；
  本轮只加守卫、不改决定，**预期契约无需改动**；若你认为需要改，单列说明理由。

## 七、交付

- 中文提交信息，正文说清**为什么**；结尾加
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`。
- 报告写进 `.superpowers/sdd/2026-09-19-qmt-4b-s4a-impl/fixround9-report.md`，
  返回值只给：状态、提交 SHA、一行测试结论、疑虑逐条列出。
- ⛔ 不许派子代理、不许 push、不许开 PR、不许动 `.claude/state/`。
