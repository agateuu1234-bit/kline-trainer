# 验收清单：`INSERT INTO training_sets` 必须显式给 `schema_version`

**给谁用**：不写代码的人也能逐条执行。
**怎么用**：每条都是**一个独立代码块**，**整块复制、单独执行**，顺序无关、可任意重跑。

⛔ 每条都自带绝对路径的 `cd`，不依赖上一条的当前目录。
⛔ 命令里的 python 路径是**写死的绝对路径**，不要换成变量 —— 这份清单是**单独交付**的，照抄变量会得到「命令找不到」。

**这片改了什么（一句话）**：数据库里「训练组」那张表有个字段叫 `schema_version`，它有个**默认值 1**。后端产出的训练组从 #183 起已经是**第 2 代**了，所以任何**忘了填这个字段**的写入语句，都会**悄悄**把新数据标成第 1 代 —— 不报错、不告警，只是数据错了。本片把仓库里 10 条这样的语句补齐，并加了一道**机械守卫**防止以后再漏。

---

**B1** —— 期望：打印 `3`（三条语句各补一处）

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p3d" && grep -cF 'schema_version' backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh
```

□ 通过　□ 不通过

**B2** —— 期望：打印 `3`（**1 处是本来就有的**、与写入语句无关的表格行 `:498`，加上新补的 2 处）

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p3d" && grep -cF 'schema_version' docs/runbooks/2026-08-24-qmt-nas-deployment.md
```

□ 通过　□ 不通过

**B3** —— 期望：打印 `5`

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p3d" && grep -cF 'schema_version' .github/workflows/schema-smoke.yml
```

□ 通过　□ 不通过

**B4** —— 期望：最后一行是 `12 passed in N.NNs`（⛔ 读 passed 前面的**数字**，不读「success」之类的字样）

> 十二条分别是：①主判据 ②正向对照（合法写法不许被误判）③兜底网的独立判别力 ④`.py` 字面量还原成运行时字符串 ⑤**攻击语料不许假绿**（41 条）⑥**合法语句保持绿** ⑦语料防空转 ⑧**精度不许退化** ⑨列名提取的**词法**正确（两个方向都钉）⑩一条被认出来的语句不许掩护同一文件里的其它语句 ⑪**作用域内没有静默不可见的写法**（动态表名/插值）⑫参数化查询（插值只在 VALUES 里）必须保持绿。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p3d/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest tests/test_training_sets_insert_schema_version.py -q | tail -1
```

□ 通过　□ 不通过

**B5** —— 期望：最后一行形如 `NNNN passed in NN.NNs` —— **只有 `passed` 一个词**，不含 `failed`、`error`、`skipped` 中的任何一个

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p3d/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -m pytest -q | tail -1
```

□ 通过　□ 不通过

**B6** —— 期望：打印出 `作用域文件数=91  checked=12  白名单(test double)=2  散文提及=1  仍缺字段=0`（文件数可能随仓库增长而变大，**关键是 `仍缺字段=0` 且 `checked` 不少于 12**）

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p3d" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" -c "
import sys; sys.path.insert(0, 'backend/tests')
import test_training_sets_insert_schema_version as g
c=w=p=0; miss=[]
for path in g._scope_files():
    t = path.read_text(encoding='utf-8', errors='replace')
    for m in g._INSERT_RE.finditer(t):
        cols = g._column_list(t, m.end())
        if cols is not None:
            c += 1
            if 'schema_version' not in g._column_names(cols): miss.append(str(path))
        elif g._NON_SQL_SHAPE in t[m.end():m.end()+20]: w += 1
        elif g._is_prose_mention(t, m.start(), m.end()): p += 1
print(f'作用域文件数={len(g._scope_files())}  checked={c}  白名单(test double)={w}  散文提及={p}  仍缺字段={len(miss)}')
"
```

□ 通过　□ 不通过

---

## 全部执行完之后

- 6 条**全部**「通过」= 本片交付合格。
- 任何一条「不通过」⇒ ⛔ **不要自行改代码去凑数**，把那条的**实际输出**原样贴回来。

## ⛔ 这道守卫是【辅助防线】，不是完备防线

它经历了 **10 轮对抗性评审、10 次被攻破**（其中 3 次是「守卫报绿而语句确实缺字段」的真假绿）。
最终它覆盖的是「**SQL 以字面量写在源码里**」这一类，**已知挡不住四类**：
表名来自 f-string 变量 / `.format()` / 常量相加，以及被 `/* */` 整段注掉且缺字段的语句。

**真正完备的防线是数据库层的 fail-closed**（去掉 `DEFAULT 1`，漏填直接报错）——
已立项为下一片 **TS1-R1**，简报见
`docs/superpowers/specs/2026-09-23-ts1r1-schema-version-fail-closed-brief.md`。

⛔ **在 TS1-R1 落地之前，不要把这道守卫当成「这件事已经有人管了」的依据。**

---

⚠️ **本片做完 ≠ 手机能用了**：库存的 3 个训练组仍是**第 1 代**产物，App 读取端也仍钉在第 1 代（这是设计好的过渡态）。要手机能用，还需要 P4（重建产物）与切片二（App 侧）两步。
