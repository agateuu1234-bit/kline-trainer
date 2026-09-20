# QMT 4b 切片 S4a（单股拷贝事务）· 验收清单

**给谁用**：不写代码的人。每一步都是「**先粘一行建脚本，再粘一行跑它**」。
⚠️ 不要把多行命令直接粘进终端——超过一行必被换行截断，这是本仓踩过三次的坑。

**这一片做了什么（一句话）**：让「拷一只股的两个文件」变成一件**要么两个都成、要么一个都不留**的事。

⛔ **这一片没做什么**：`qmt_fetch` 这条命令**还不存在**，你现在用不了它。
下料的整体流程（S4b）与源头检查 + 命令行（S5）都还没做。

---

## 第一节 · 准备

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| A1 | 粘贴并回车：`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a" && git log --oneline -1` | 打印一行提交记录，开头是 8 位字母数字编号 | 打印出来了 = 通过；报「No such file or directory」= 不通过 |

## 第二节 · 全部测试通过且一条都没被跳过

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| B1 | 粘贴并回车：`printf '%s\n' 'cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend"' 'git rev-parse --abbrev-ref HEAD; git rev-parse --short HEAD' '../.venv/bin/python -m pytest tests/ -q -rs 2>&1 | tail -6' > /tmp/s4a_b1.sh` | 没有任何输出（安静就是成功） | 没报错 = 通过 |
| B2 | 粘贴并回车：`bash /tmp/s4a_b1.sh` | 最后几行里有 **`1584 passed`**，并且**没有** `skipped` 或 `failed` 字样 | 数字是 1584 且无 skipped/failed = 通过；出现 failed 或 skipped = 不通过 |
| B3 | 看 B2 输出**最上面**两行 | 第一行是 `qmt-4b-s4a`，第二行的编号与 A1 打印的一致 | 一致 = 通过；不一致说明跑的不是这棵树 = 不通过 |

## 第三节 · 三条核心行为各跑一条命令

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| C1 | 粘贴并回车：`printf '%s\n' 'cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend"' '../.venv/bin/python -m pytest tests/test_qmt_fetch.py -q -k "daily_missing_leaves_no_orphan or rejects_fifo_at_final_target or terminates_before_marker" -v 2>&1 | tail -12' > /tmp/s4a_c1.sh` | 无输出 | 没报错 = 通过 |
| C2 | 粘贴并回车：`bash /tmp/s4a_c1.sh` | 看到 **3 个**测试名后面都是 `PASSED`，最后一行是 `3 passed` | 三个都 PASSED = 通过；任何一个 FAILED 或总数不是 3 = 不通过 |

**这三条分别在验证**：
1. 一只股的两个文件里有一个拿不到时，**另一个也不许留在硬盘上**（留下了的话，下次重试会把这只股永久判死）；
2. 硬盘上那个位置已经被人换成了**不是普通文件的东西**（管道、目录之类）时，
   工具**拒绝覆盖它**、原样留着（覆盖就是把别人的东西毁了）；
3. 拷贝过程中**源头的数据被换掉**时，工具在**落地之前**就停住（落地之后再发现，两个文件已经写下去了，账本却还记着旧的）。

## 第四节 · 确认这一片没有越界

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| D1 | 粘贴并回车：`grep -c "argparse" "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend/qmt_fetch.py"` | 打印 **`0`** | 是 0 = 通过；不是 0 说明有人顺手做了命令行，这一片不该有 = 不通过 |
| D2 | 粘贴并回车：`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a" && git diff --stat main -- backend/qmt_fsroot.py backend/qmt_manifest.py backend/qmt_pool.py backend/qmt_ingest.py backend/qmt_normalize.py` | **没有任何输出** | 没输出 = 通过（这五个已有模块一个字节都没被改动）；有输出 = 不通过 |

## 第五节 · 你需要知道的两件事（不用操作）

1. **有一个已知问题被带出了这一片**：账本里记录「一共写了多少字节」的那个数字，
   在「崩溃恢复删掉记录之后又重新拉同一只股」时会**重复计数**。
   根子在**上一片已经合并的代码**里，不在这一片。已决定**另开一个 PR 修**。
   期间的影响：反复崩溃会让运行**提前以「空间用完」结束**，而那种结束下游会当成正常结束放行。
2. **codex 官方评审通道已经跑过，但闸门还没兑现。**
   到目前为止它给出过 **2 次真判决，两次都是「有问题待处理」**；报出的 3 个问题**已全部改掉**
   （其中一个会真的毁掉磁盘上已有的用户文件）。另有 2 次是起手就撞到用量上限、评审根本没跑起来
   —— 那**不算一次判决**，也不算「没通过」。
   ⛔ **评审账本里至今没有一条「通过」的记录。** 治理规矩要求合并前必须有，所以这一片
   **现在还不能合**：要么再跑到一次真「通过」，要么由你明确拍板跳过这道闸门并记在案上。
