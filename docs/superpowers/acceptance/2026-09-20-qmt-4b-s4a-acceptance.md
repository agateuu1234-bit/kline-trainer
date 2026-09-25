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
| B2 | 粘贴并回车：`bash /tmp/s4a_b1.sh` | 最后几行里有 **`1614 passed`**，并且**没有** `skipped` 或 `failed` 字样 | 数字是 1614 且无 skipped/failed = 通过；出现 failed 或 skipped = 不通过 |
| B3 | 看 B2 输出**最上面**两行 | 第一行是 `qmt-4b-s4a`，第二行的编号与 A1 打印的一致 | 一致 = 通过；不一致说明跑的不是这棵树 = 不通过 |

## 第三节 · 三条核心行为各跑一条命令

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| C1 | 粘贴并回车：`printf '%s\n' 'cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a/backend"' '../.venv/bin/python -m pytest tests/test_qmt_fetch.py -k "daily_missing_leaves_no_orphan or rejects_fifo_at_final_target or terminates_before_marker" -v 2>&1 | tail -12' > /tmp/s4a_c1.sh` | 无输出 | 没报错 = 通过 |
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
| D2 | 粘贴并回车：`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a" && git diff --stat main -- backend/qmt_manifest.py backend/qmt_pool.py backend/qmt_ingest.py backend/qmt_normalize.py` | **没有任何输出** | 没输出 = 通过（这四个已有模块一个字节都没被改动）；有输出 = 不通过 |
| D3 | 粘贴并回车：`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a" && git diff --stat main -- backend/qmt_fsroot.py` | 打印**两行**，第二行是 `1 file changed, 174 insertions(+), 59 deletions(-)`（新增约 **170** 行、删除约 **60** 行） | 数量级对得上（±15 行以内）= 通过；**没有任何输出** = 不通过（说明该改的压根没改进去） |
| D4 | 粘贴并回车：`printf '%s\n' 'cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s4a"' 'git diff -w main -- backend/qmt_fsroot.py > /tmp/s4a_fsroot.diff' 'grep "^-[^-]" /tmp/s4a_fsroot.diff > /tmp/s4a_removed.txt' 'echo "一、删掉的行数："; wc -l < /tmp/s4a_removed.txt' 'echo "二、其中带业务调用的行数："; grep -c "os.open\|os.mkdir\|os.replace\|flock\|fsync" /tmp/s4a_removed.txt' 'echo "（检查结束）"' > /tmp/s4a_d4.sh` | 没有任何输出（安静就是成功） | 没报错 = 通过 |
| D5 | 粘贴并回车：`bash /tmp/s4a_d4.sh` | 「一、」下面是 **`33`**（本次一共删掉 33 行旧代码）；「二、」下面是 **`0`** | 第一个数在 28~38 之间**且**第二个数是 0 = 通过；第二个数不是 0 = 不通过 |

**D3/D4/D5 在验证什么（大白话）**：
`qmt_fsroot.py` 是这一片原本**说好不动**的五个老模块之一。这一轮**破例动了它**，
是你（user，2026-09-21）明确拍板的：官方评审查出，工具在「收尾、关闭文件」这一步
若失败，会把一条**「有人动了手脚、必须立刻停机」的警报**换成一条**「这只股读不了、跳过就行」
的普通报错** —— 于是本该停机的运行会一路跑下去。

- **D3** 让你看到：它**确实**被改了，改动量约 170 行新增 / 60 行删除
  （新增多是因为新写了一小段带说明的公共「关闭」工具，并把理由写在旁边）；
- **D4 + D5** 一起让你看到：**被删掉的 33 行全部是「收尾语句」**——
  `os.close(...)`（关文件）、`finally:` / `try:` / `except`（收尾块的框架）这几类，
  **一行都没碰**真正干活的那些调用（开文件 `os.open`、建目录 `os.mkdir`、
  改名 `os.replace`、上锁 `flock`、刷盘 `fsync`）。
  也就是说：**这一轮没有改变这个模块做什么，只改变了它收尾时不再把警报顶掉。**
  ⚠️ D5 那条检查的判别力已实测：往被删的行里故意混进一行 `os.replace(...)`，它会打印 `1`
  而不是 `0` —— 所以打印 `0` 是一条真结论，不是「它根本不会报数」。

## 第五节 · 你需要知道的两件事（不用操作）

1. **有一个已知问题被带出了这一片**：账本里记录「一共写了多少字节」的那个数字，
   在「崩溃恢复删掉记录之后又重新拉同一只股」时会**重复计数**。
   根子在**上一片已经合并的代码**里，不在这一片。已决定**另开一个 PR 修**。
   期间的影响：反复崩溃会让运行**提前以「空间用完」结束**，而那种结束下游会当成正常结束放行。
2. **codex 官方评审通道已经跑通，闸门已兑现。**
   这一片反复送审过十余次，其中有实质结果的是：
   · **5 次是「有问题待处理」的真判决**，报出的 **6 个问题已全部改掉**
     （一个会真的毁掉磁盘上已有的用户文件；三个会把「必须停机」的信号降级成「跳过这只股」；
     一个会让断电后的恢复失去删除授权，那只股从此永远拉不动）；
   · **4 次是起手就撞到用量上限、评审根本没跑起来** —— 那不算判决，也不算「没通过」；
   · **1 次给了「通过」但我作废了它** —— 那次用的**对比基准是错的**（评审跑之前主干分支
     往前走了一步，而这条分支还没接上去），所以它证明不了这一片没问题；
   · **最终在提交上拿到一次基准正确的「通过」，评审账本已写入记录 ⇒ 治理要求的那道闸门满足了。**

   ⚠️ **读这个「通过」要连它没做的事一起读**（这是本仓踩过的坑，写在这里供你自己判断）：
   · 它**没有跑任何测试** —— 最后那次判决的原话是「Static review covered publication
     ordering, rollback accounting, exception propagation, and filesystem boundaries;
     tests were not executed in the read-only environment」（静态审查覆盖了发布次序、
     回滚记账、异常传递、文件系统边界；测试没有执行）。测试是我跑的，
     第二节那条就是让你亲手复核这一点的；
   · 它**没有逐行看**那 600 多行新增测试与契约文档；
   · 所以这个「通过」的意思是「**在它看过的代码里没找到会阻断发布的问题**」，
     **不是**「所有东西都被它验过一遍」。
