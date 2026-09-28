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

**A1** —— 期望：最后一行是 `6 passed in N.NNs`（⛔ 读 `passed` **前面的数字**，不读别的字样）

> 这 6 条分别钉住：①合成小树上守卫真会抛错 ②真仓里每条写入都带字段
> ③守卫与**真 PostgreSQL 解析器**逐条一致 ④**守卫看的是运行时字符串**（本片新增）
> ⑤只是提到 `INSERT INTO` 的散文**不许**被报（本片新增）⑥表名拼出来时**不许沉默**（本片新增）

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

> 它干的事：先在一个**临时副本**里故意删掉一处 `schema_version`，看守卫是否变红，
> 然后**立刻改回去**。⛔ 全程在临时目录里操作，**不会动你的真文件**。
> 为什么必须验这一条：一道「什么都不报」的守卫和一道「一切正常」的守卫，
> 从输出上看完全一样 —— 必须先证明它**能**报错，它报的「没问题」才有意义。

```
bash /tmp/insert-guard-a4.sh
```

□ 通过　□ 不通过

---

**A5** —— 期望：打印 `干净树上误报=0`

> 它干的事：把 #194 守卫**原本会静默放过**的 10 种写法，逐条喂给新守卫，
> 同时把**合法写法**也喂一遍，确认新守卫既能报出问题、又不会把正常代码误判。
> 这一条已经内置在 A1 那 6 条测试里；这里再单独把「合法写法不许变红」这一半打出来，
> 因为它是最容易被忽略的一半。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/insert-guard-host" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest backend/tests/test_insert_schema_version_guard.py::test_guard_stays_quiet_on_prose_that_merely_mentions_insert_into backend/tests/test_insert_schema_version_guard.py::test_guard_sees_the_runtime_sql_not_the_source_text -q 2>&1 | tail -1 | sed 's/^/干净树上误报=0 ⇐ 若这行是 "2 passed" 则成立，实际：/'
```

□ 通过　□ 不通过

---

**A6** —— 期望：打印 `本片只改了 1 个文件` 和 `backend/tests/test_insert_schema_version_guard.py`

> 为什么要看这个：本片是**只改测试文件**的一片 —— 没有动任何生产代码、没有动数据库、
> 没有动 CI 配置。如果输出里出现别的文件名，说明有不该有的改动混进来了。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/insert-guard-host" && echo "本片只改了 $(git diff --name-only origin/main...HEAD | wc -l | tr -d ' ') 个文件" && git diff --name-only origin/main...HEAD
```

□ 通过　□ 不通过

---

## 这一片**没有**做什么（别误以为做了）

- ⛔ **没有**动数据库。`schema_version` 的 `DEFAULT 1` 还在 —— 忘记填字段时数据库
  **仍然不会报错**。真正让它报错是下一片（TS1-R1）的事。
- ⛔ **没有**动任何生产代码，只改了一个测试文件。
- ⛔ **不代表手机上能用了**。库存的 3 个训练组仍是第 1 代产物、App 读取端也还钉在第 1 代。

## 仍然挡不住什么（实测过，不是猜的）

- **表名是程序拼出来的**（例如 `INSERT INTO {某个变量}`）：守卫会说「**这里我判不了，
  人来看一眼**」并让测试变红 —— ⛔ 但它**说不出**这条到底缺不缺字段。
  「判不了」和「判对了」是两件事，这个差别只有 TS1-R1 能消掉。
- `VALUES` 里的**值**写错（守卫只看「字段名在不在清单里」，不看填进去的值对不对）。
