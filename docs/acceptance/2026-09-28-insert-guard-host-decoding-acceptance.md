# 验收清单：INSERT 守卫补宿主解码层

**这一片解决什么（大白话）**

数据库里 `training_sets` 这张表有个字段叫 `schema_version`（「这批数据是第几代」）。
它有个**默认值 1**。而我们从 #183 起产出的已经是**第 2 代**了 —— 所以任何**忘记填这个字段**
的写入，都会**悄悄**把新数据标成第 1 代：不报错、不告警，只是数据错了。

#194 已经加了一道**机械守卫**来防止以后再忘。本片补的是它的一个盲区：

> 守卫读的是**源码文件里写的那串字**，而数据库拿到的是**程序运行时拼出来的那串字**。
> 这两者**不是一回事**。

打个比方：源码里写着两句话被引号断开 ——

```
"INSERT INTO "
"training_sets (股票代码, 文件路径) VALUES (…)"
```

Python 运行时会把它们**粘成一句**再交给数据库。而守卫看的是断开的样子，
于是它**根本没认出这里有一条写入**，一言不发地放过去了。

本片实测出 **10 条**这样的缺陷（其中 8 条是「整条语句从守卫视野里消失」），已全部修好。

---

## 怎么验（每条都是复制整块、粘进终端、看输出）

⚠️ 下面每一块都是**完整可粘贴**的：已经带好目录切换和完整路径，不需要你先做别的准备。
⚠️ 「通过 / 不通过」请按**期望**那一行逐字对照，⛔ 不要凭「看着差不多」判断。

---

**A1** —— 期望：最后一行是 `10 passed in N.NNs`（⛔ 读 `passed` **前面的数字**，不读别的字样）

> 这 10 条分别钉住：①合成小树上守卫真会抛错 ②真仓里每条写入都带字段
> ③守卫与**真 PostgreSQL 解析器**逐条一致 ④**守卫看的是运行时字符串**（本片新增）
> ⑤只是提到 `INSERT INTO` 的散文**不许**被报（本片新增）⑥表名拼出来时**不许沉默**（本片新增）
> ⑦列清单里有拼接占位时必须说「**判不了**」、⛔ 不许说「缺字段」（本片新增）
> ⑧求不出来的表达式**里面**的 SQL 不许消失（本片新增）
> ⑨判得出的写法不许降级成「判不了」（本片新增）
> ⑩**解码不许让可见的语句变少**（本片新增，整条解码路线的地板）

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/insert-guard-host/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_insert_schema_version_guard.py -q | tail -1
```

□ 通过　□ 不通过

---

**A2** —— 期望：最后一行形如 `NNNN passed in NN.NNs` —— **只有 `passed` 一个词**，
不含 `failed`、`error`、`skipped` 中的任何一个

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/insert-guard-host/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest -q | tail -1
```

□ 通过　□ 不通过

---

**A3** —— 期望：打印 `退出码=0`

> ⚠️ 为什么要单独看退出码：管道（`|`）会把真正的退出码吞掉，只看最后一行文字
> 可能被骗（本仓踩过这个坑）。这一条直接把退出码打出来。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/insert-guard-host" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest backend -q > /tmp/a3.log 2>&1; echo "退出码=$?"
```

□ 通过　□ 不通过

---

**A4 —— 这一条最重要：证明守卫「真的会报错」，不是永远绿**

期望：打印两行，**都以 `变红了 ✅` 开头**

> 它干的事：故意删掉一处 `schema_version`，看守卫是否变红，然后改回去。
>
> ⚠️ **说清楚风险**：它**确实会临时修改你的真文件**（两个文件，各改一行）。
> 三重保护：改动前先复制一份备份；用 `trap` 保证**无论怎么退出**（成功 / 报错 / 你按 Ctrl-C）
> 都会还原；最后再用 git 复核一遍「工作树干不干净」，不干净就大声报错并列出清单。
> ⛔ 开工前如果你的工作树本来就有未提交的改动，脚本会**拒绝运行**（避免把你的改动搞混）。
>
> 为什么必须验这一条：一道「什么都不报」的守卫和一道「一切正常」的守卫，
> 从输出上看**完全一样** —— 必须先证明它**能**报错，它报的「没问题」才有意义。

```
bash "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/insert-guard-host/docs/acceptance/2026-09-28-insert-guard-host-decoding-a4.sh"
```

> ⚠️ 这个脚本**在仓库里**（跟本清单同一个目录），不是临时文件 —— 换台机器、重启之后照样能跑。
> ⚠️ 它的判别方式是**直接调守卫的检查函数、读它抛出的报错消息**，
> ⛔ 不是去 `grep` 测试输出 —— 第一版就是那么写的，实测**被证伪**：
> 把守卫改成「什么都不报」之后，它照样打印「变红了 ✅」（因为 pytest 的回溯会把守卫
> **源码里**的字样一起打印出来）。现在这一版已实测：守卫恒绿时它会打印「⛔ 没变红」。

□ 通过　□ 不通过

---

**A5** —— 期望：最后一行是 `2 passed in N.NNs`

> 它验的是**最容易被忽略的那一半**：守卫不许把**正常代码**判成有问题。
> 两条分别是：①只是提到 `INSERT INTO` 的散文（含中文）不许被报；
> ②合法写法（含「表名被引号劈开但字段在场」）必须放行。
>
> ⚠️ 为什么单独拎出来：一道**什么都报**的守卫也能让「坏样本该红」那一半全过，
> 但它会把人逼到「干脆无视它」。两头都得钉。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/insert-guard-host" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest "backend/tests/test_insert_schema_version_guard.py::test_guard_stays_quiet_on_prose_that_merely_mentions_insert_into" "backend/tests/test_insert_schema_version_guard.py::test_guard_sees_the_runtime_sql_not_the_source_text" -q | tail -1
```

□ 通过　□ 不通过

---

**A6** —— 期望：打印 `本片改了 3 个文件`，且下面**恰好**是这三个：

```
backend/tests/test_insert_schema_version_guard.py
docs/acceptance/2026-09-28-insert-guard-host-decoding-a4.sh
docs/acceptance/2026-09-28-insert-guard-host-decoding-acceptance.md
```

> 为什么要看这个：本片**没有动任何生产代码**（改的是一个测试文件 + 两份验收材料），
> 没有动数据库、没有动 CI 配置。如果输出里出现别的文件名，说明有不该有的改动混进来了。
> ⚠️ 这一条是**集合等式**，不是「至少有」—— 多出来的和少掉的都算不通过。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/insert-guard-host" && echo "本片只改了 $(git diff --name-only origin/main...HEAD | wc -l | tr -d ' ') 个文件" && git diff --name-only origin/main...HEAD
```

□ 通过　□ 不通过

---

## 这一片**没有**做什么（别误以为做了）

- ⛔ **没有**动数据库。`schema_version` 的 `DEFAULT 1` 还在 —— 忘记填字段时数据库
  **仍然不会报错**。真正让它报错是下一片（TS1-R1）的事。
- ⛔ **没有**动任何生产代码 —— 改的是一个测试文件，加两份验收材料（清单本身和 A4 脚本）。
- ⛔ **不代表手机上能用了**。库存的 3 个训练组仍是第 1 代产物、App 读取端也还钉在第 1 代。

## 仍然挡不住什么（实测过，不是猜的）

- **表名是程序拼出来的**（例如 `INSERT INTO {某个变量}`）：守卫会说「**这里我判不了，
  人来看一眼**」并让测试变红 —— ⛔ 但它**说不出**这条到底缺不缺字段。
  「判不了」和「判对了」是两件事，这个差别只有 TS1-R1 能消掉。
- `VALUES` 里的**值**写错（守卫只看「字段名在不在清单里」，不看填进去的值对不对）。
