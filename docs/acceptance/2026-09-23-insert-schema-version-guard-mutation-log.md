# 变异验证记录：`INSERT INTO training_sets` 守卫（21 个变体，0 漏掉）

**为什么要这份记录**：一道守卫「跑通了」不等于「它在守什么」。本仓的教训是 ——
只有**故意把被守的东西弄坏、看它是不是变红、而且红的是【那一条】判据**，才算证明了判别力。
⛔ 「有测试变红」是假信号，必须问「**红的是哪一条**」。

**执行环境**：分支 `feat/trainingset-p3d-insert-guard`（基于 `main@b504d630`）；Python 用主仓虚拟环境的绝对路径；
每次 `PYTHONDONTWRITEBYTECODE=1 … -p no:cacheprovider`（本仓教训：等长改动 + 同秒复原会命中陈旧字节码）。
**做法**：每次只追加**一条合法但缺 `schema_version`** 的 SQL，跑守卫，记录，复原。

---

## 21 个变体，全部为红

| 类 | 变体 | 结果 |
|---|---|---|
| **表名侧** | `"public"."training_sets"` 双引号限定 · `PUBLIC.TRAINING_SETS` 全大写 · `public . training_sets` 点号带空格 · `"training_sets"` 仅表名加引号 | 4 / 4 |
| **语句侧** | `AS t` 表别名 · `WITH …` CTE 前置 · `ON CONFLICT` 尾巴 · **无列清单的 `VALUES`**（PG 会给缺列填默认值 ⇒ 真能绕过 `DEFAULT 1`） | 4 / 4 |
| **注释侧** | 行注释夹在关键字之间 · 表名前夹块注释 · 多个块注释连排 · `INSERT /* hi */ INTO` | 4 / 4 |
| **空白侧** | 制表符分隔 | 1 / 1 |
| **解析层** | 无列清单但 `VALUES` 里恰好含字符串 `'schema_version'` · `INSERT … SELECT`（表名后不是括号） · 列清单含函数调用（嵌套括号） · **列名叫 `my_schema_version`**（含子串但不是本列） | 4 / 4 |
| **字符串拼接** | 在 `INTO ` 后断行 · 在 `INSERT ` 后断行 · 单引号字符串 · **表名中间劈开** `training_` + `sets` | 4 / 4 |

**合计 21 / 21 为红，0 漏掉。**（20 条走精确正则报「列清单缺 schema_version」，1 条 —— 表名被劈开 —— 走粗网报「判据够不着」。）

---

## 判据分三层，每层都是被实测打出来的

### ① 发现层：正则，不是固定字面量

`text.find("INSERT INTO training_sets")` **区分大小写**，且只认「`INTO` 与表名之间恰好一个空格、无 schema 限定」一种拼法。实测：小写 / 换行 / `public.` 三种**合法且缺字段**的写法**全部溜过**，而既有 12 处仍满足防空转计数 ⇒ **新写入方可静默绕过**。

### ② 判定层：按【列名集合】，不是子串

一句 `/* schema_version uses the default */` 注释就能把子串判断喂饱，而**真列并不在场**。
⇒ 先剥 SQL 注释（`/* */` 与 `--`），再按逗号切 token、剥引号后按**整个标识符**比对。
⭐ 所以一个叫 `my_schema_version` 的列**不会**被误判为通过（变异已验）。

### ③ 兜底层：一张故意放宽的粗网

精确正则再宽也总有够不着的拼法（表名被劈成 `"INSERT INTO training_"` + `"sets …"`）。
⇒ 凡「像是往 `training_sets` 写」却**没被精确正则认领**的，一律报「**判据够不着**」**让测试红**。
⛔ **不许把「断定不是目标」和「判据够不着」混进同一个分支** —— 两者会互相伪装成对方。宁可偶尔误报（红了有人看），也不要漏报（绿了没人知道）。

---

## ⚠️ 粗网的三次收紧，全是【干净树上的误报】逼出来的

守卫**必须在当前树上是绿的**，否则它就是一张放行许可证。

| # | 干净树上的误报 | 收紧 |
|---|---|---|
| 1 | **中文散文**：注释里「并发 sweep 在预检与 INSERT 之间插入同一起点时」，既有 `INSERT` 又有 `training_sets` —— 实测红 7 处 | 要求 `insert` 后不远处必须跟 `into` |
| 2 | **插另一张表的合法语句**：`INSERT INTO p15_targets (id) SELECT … FROM training_sets` | `into` 与表名之间只容忍空白/引号/下划线（正好够兜住被劈开的表名，又放不进 `p15_targets (id) SELECT … FROM `）|
| 3 | **反引号包住的散文提及**：`（spec §3.3 对 \`INSERT INTO training_sets\` 的计数连栽三轮）` —— 来自 main 的 `test_deployment_source_texts.py:17` | 加一条**结构性**分类：反引号跨度在 markdown / docstring 里是代码跨度、在 shell 里是命令替换（真跑会把 `INSERT` 当命令直接失败），**三种宿主里都不是可执行写入路径** |

⚠️ 第 3 条是**换到新 main 基线后才出现**的 —— 那个文件是 main 上后来合入的。**说明「守卫在当前树上为绿」这件事必须在【每次换基线后】重验，不能沿用旧结论。**

---

## 非 SQL 命中：两类各自计数，不被悄悄吃掉

| 类 | 是什么 | 为什么结构上不可能有该字段 |
|---|---|---|
| test double 的分派谓词（**2** 处） | `if "INSERT INTO training_sets" in query:` | 它是字符串比较、不是要执行的 SQL |
| 反引号散文提及（**1** 处） | 文档 / docstring 里的代码跨度 | markdown 代码跨度 / shell 命令替换，都不执行 |

⛔ **散文提及不设硬性条数**：它会随文档自然增减（本仓「别写含自身的总数」那条教训）；但它**单独计数并在防空转断言的报错里露出来**，不会被悄悄吃掉。

---

## 覆盖面实测（新 main 基线）

```
作用域文件数=91  checked=12  白名单(test double)=2  散文提及=1  仍缺字段=0
```

12 处逐一为：`generate_training_sets.py:563`（本就带）、`rehearse.sh` ×3、`deployment.md` ×2、`qmt-nas-p11-insert-training-sets.sql:63`（本就带）、`schema-smoke.yml` ×5。
—— 其中 **10 处是本片补齐的**，2 处本来就有。
