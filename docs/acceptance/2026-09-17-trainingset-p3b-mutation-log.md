# 切片一 P3b（`INSERT` 补 `schema_version` + 两条守卫）· 变异验证逐条记录

**分支** `feat/trainingset-p3b-insert-schema-version`
**日期** 2026-09-21（本记录撰写日；实施发生于 2026-09-17～2026-09-20）
**基线** 全套 `1505 passed`（这一片开工之前，`origin/main = 8d47e811`）；本记录撰写时重跑全套为 `1511 passed`

## 为什么要做变异验证

一条自动检查显示「通过」，本身**说明不了任何事**。举个极端例子：一条检查如果写成「只要程序还在运行就算通过」，那不管代码改成什么样，它永远显示「通过」——这种检查等于没有。

所以每写完一条新检查，光看它「现在是绿的」不够，还要反过来问一句：**如果我故意把它该抓的那个问题重新制造一次，它会不会真的报错？** 这份文档记的就是这件事——对本片新增的两条守卫，逐一「故意改坏一处、看它红不红」，逐条列出编号。

⛔ **本文档不写「共 N 组」这类总数**——这个数在本片实施过程的 R2/R3/R4/R5 四轮评审里，因为「编号不连续」被错报/打回过。条数请自己数：

```
grep -c '^### M' docs/acceptance/2026-09-17-trainingset-p3b-mutation-log.md
```

（本文撰写时实测这条命令输出 **31**；⛔ 这行字本身不是断言，只是告诉你去哪数，数字请你自己核。
⚠️ 它一度写的是 30 —— 因为漏记了 `M4p`，补回之后才是 31。**这正说明为什么这份文件里不写「共 N 组」**：
任何写死的总数都会在下一次补记时变错，而现场数出来的那个数不会。）

## 为什么编号不连续（M0 / M1…M4 / M4b…M4w / M5…M9，中间跳过 M4r）

这份记录跨了两条守卫、六轮评审，编号是**按发生顺序原样保留**的，不做事后重排：

1. **M0–M4h**（12 组）：守卫①第一次任务评审通过后，由**控制者亲跑**并写进 `task-3-report.md`。`M0` 排在最前——它是 spec §3.3 / B23 明令必须变红的那一条（往**唯一真写生产库**的语句删字段），也是**上一版判据的恒绿死角**；`M4b` 是计划阶段预演打回后补加的，插在 `M4` 与 `M4c` 之间。
2. **M4i–M4l**：守卫①第 1 轮定向复评挖出「块注释没剥」阻断项之后，验证修复补加的 4 组。
3. **M4m–M4o**：第 2 轮定向复评挖出「块注释可嵌套」阻断项之后，验证修复补加的 3 组。
4. **M4p**：第 2 轮定向复评之后，控制者把「标识符必须**整段匹配**」这处修复补上时跑的 1 组。
   ⚠️ **本文件上一版把它写成「未被使用的编号」，那是错的** —— 它是**真跑过**的一组，写错的原因是控制者的实施台账里没有按编号记下它。⛔ 这正是本片反复栽的那一类：**「我没用过它」也是一句需要核实的断言**。已按实测补回（见下文 M4p 一节）。
5. **M4q**：第 3 轮定向复评挖出「上报链路可被从任意一层短路」重要项之后，验证「塌层」修复补加的 1 组。
   （`M4r` 确实未被使用——编过号但没落地的一个候选，不强行填补，也不影响计数。）
6. **M4s–M4v**：第 4/5 轮定向复评挖出「判据带开关可被单参数绕开」「引号标识符处理理由不成立」等问题后，验证修复补加的 4 组。
7. **M4w**：Task 3 收口时量化「`gen_seen` 残留」大小，补加的 1 组。
8. **M5–M9**：守卫②的变异，`M5/M6/M7` 由 Task 4 实施者跑出、控制者复核；`M8/M9` 是控制者复核 Task 4 时加测的 2 组。

⭐ **本记录里的【每一组】（条数以文件开头那条 `grep -c` 现场数为准，⛔ 本文不写死总数），均在最终代码（守卫代码定版于 `537cd1be`；此后只有文档提交，代码未再变动）上于 2026-09-21 当场重新跑出**（`M4p` 一组是控制者在交付复核时补记并当场重跑的，见下文该节），不是照抄历史记录——⛔ 本仓栽过「照抄历史结论、不重新核实」的坑（见 `feedback_cannot_verify_is_not_a_reason_to_defer.md`）。凡是历史上出现过、但没有留存逐字命令输出的编号（`M4i` 及以后），本次都按原始描述在最终代码上**重新构造并重新观测**，观测结果与历史结论逐条一致（无一条翻案）。

**纪律**（本仓这类操作已踩过坑，这次照下面的规矩来）：

- 一组只改一处；改之前先 `cp` 备份，改完验证完，用 `cp` 把备份原样拷回去——⛔ 不用 `git checkout <文件>`（那会把还没提交的其它合法改动一起冲掉）。
- 每次施加变异都放进 `try/finally`（脚本层面），异常也会自动还原，不留变异态在树上。
- 改 Python 文件前后各清一次 `__pycache__`（字节码缓存，不清的话代码改了、缓存却是旧的，会让结果失真）。
- 改动前先确认「锚点」（要改的那句话）在文件里**恰好出现 1 次**——出现 0 次或好几次就说明找错了地方，当场停下不动文件。
- **全部跑完之后**，统一核对一次 `git status --short`——只剩本片开工前就有的未跟踪文件，没有任何变异残留。**实测**：跑完后 `git status --short` 只有一行 `?? docs/superpowers/plans/2026-09-17-trainingset-p3b-insert-schema-version.md`（本片自己要提交的计划文件），`git diff --stat` 为空。

---

# 守卫①（`test_insert_schema_version_guard.py`）—— M0 ~ M4w

### M0 —— 唯一真写生产库那条删掉 schema_version（spec 明令、上一版判据的恒绿死角）

**改了什么**：`backend/generate_training_sets.py` 里 `_register_training_set` 函数的 SQL 列清单，从
`"schema_version, file_path, content_hash) VALUES (…)"` 删掉 `schema_version, `，**保留**下面 Python 侧的实参 `gts.schema_version` 不动（模拟「SQL 忘了写、参数却还在」这种最容易被漏看的错法）。

**跑了什么**：
```
cd "…/backend" && "$PY" -m pytest tests/test_insert_schema_version_guard.py::test_every_executable_insert_carries_schema_version -q
```

**原样贴出的观测输出**：
```
F                                                                        [100%]
=================================== FAILURES ===================================
_____________ test_every_executable_insert_carries_schema_version ______________
...
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E
E         【列清单里没有 `schema_version`】PostgreSQL 会用 `DEFAULT 1` **静默**把行标成第 1 代，而所有闸门照样绿：
E           backend/generate_training_sets.py:563  列清单=stock_code, stock_name, start_datetime, end_datetime, "
E                 "file_path, content_hash

tests/test_insert_schema_version_guard.py:366: AssertionError
=========================== short test summary info ============================
FAILED tests/test_insert_schema_version_guard.py::test_every_executable_insert_carries_schema_version
1 failed in 0.07s
```
还原后 `git status --short`：只剩未跟踪的计划文件。

**结论**：**1 failed**，精确点名 `backend/generate_training_sets.py:563` 且原样打印出「列清单里已经没有 schema_version 了」。这是全片**最要紧的一条**变异：它证明守卫对「唯一会真的把数据静默写错的那一处」有判别力，而不是像上一版那样被 Python 字符串拼接的换行骗过去。

---

### M1 —— `schema-smoke.yml` 第 1 处（:73）删掉列清单里的 schema_version

**改了什么**：`.github/workflows/schema-smoke.yml:73` 那条 `! psql` 语句的列清单里删掉 `schema_version, `。

**跑了什么**：同 M0 的命令。

**原样贴出的观测输出**：
```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E
E         【列清单里没有 `schema_version`】PostgreSQL 会用 `DEFAULT 1` **静默**把行标成第 1 代，而所有闸门照样绿：
E           .github/workflows/schema-smoke.yml:73  列清单=stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash
FAILED tests/test_insert_schema_version_guard.py::test_every_executable_insert_carries_schema_version
1 failed in 0.06s
```

**结论**：**1 failed**，精确点名 `:73`。证明守卫覆盖 CI 配置文件这个作用域，不只是 `backend/`。

---

### M2 —— ⭐ 跨行且本来合规的 P11 导入脚本删掉 schema_version

**改了什么**：`docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql` 里**跨两行**的列清单
`(stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)`
删掉 `schema_version, `（这条语句本来就合规，且列清单本身就跨行）。

**跑了什么**：同上。

**原样贴出的观测输出**：
```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E
E         【列清单里没有 `schema_version`】PostgreSQL 会用 `DEFAULT 1` **静默**把行标成第 1 代，而所有闸门照样绿：
E           docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql:63  列清单=stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash
1 failed in 0.06s
```

**结论**：**1 failed**，精确点名 `:63`（列清单开始的那一行）。证明守卫**真的按语句在看**，不是按单行——这条语句的列清单跨了两行，按行比对的话根本不会被当成一条完整语句。

---

### M3 —— 把 `_SCOPE_DIRS` 改成不含任何 `INSERT` 的目录（防空转）

**改了什么**：守卫①自身的 `_SCOPE_DIRS` 临时改成 `[REPO_ROOT / "docs" / "governance"]`（该目录下没有任何 `INSERT INTO training_sets`）。

**跑了什么**：同上。

**原样贴出的观测输出**：
```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 2 类问题：
E
E         【解析不到列清单】只解析到 0 条 —— 作用域或括号配平坏了，⛔ 这不是「全都合规」。
E
E         【有一类文件一条语句都没解析到】它多半被后缀白名单/改名悄悄移出了视野，而守卫会照样报「全都合规」：
E           backend  下的 .py 文件
E           backend  下的 .sh 文件
E           docs/runbooks  下的 .md 文件
E           docs/runbooks  下的 .sql 文件
E           .github/workflows  下的 .yml 文件
1 failed in 0.09s
```

> ⚠️ **本段输出曾经贴错**（整支最终评审「重要 4」）：上一版只列了**前 3 个格子**、且没有截断标记，
> 读起来像完整原文 —— 那是「**逐目录锚点**」时代的旧输出，而最终代码的 `_EXPECTED_CELLS` 有
> **5 个格子**。已在最终代码上**重跑并原样替换**。
> ⭐ 这正是本文件自己在末尾写下的头号收获（「旧结论不能照抄」）的一次现场复发 ——
> 证据层踩了自己总结的坑。

**结论**：**1 failed**，报的是「只解析到 0 条 —— 作用域或括号配平坏了」**而不是**「全都合规」。这条防空转判据挡住了「报 0 违反」这个本仓最常踩的假绿坑——作用域被误改到没有任何语句的地方时，守卫**响**，不会误判成「都通过了」。

---

### M4 —— 往【被字符串谓词排除】的文件末尾塞一条真的缺字段 SQL

**改了什么**：`backend/tests/test_b2_reconnect_integration.py`（这个文件里本来就有 `if "INSERT INTO training_sets" in query:` 这类分派条件，会被守卫判成「提及」而跳过）末尾追加一行真的缺字段语句：
`_M4_PROBE = "INSERT INTO training_sets (stock_code) VALUES ($1)"`。

**跑了什么**：同上。

**原样贴出的观测输出**：
```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E
E         【列清单里没有 `schema_version`】PostgreSQL 会用 `DEFAULT 1` **静默**把行标成第 1 代，而所有闸门照样绿：
E           backend/tests/test_b2_reconnect_integration.py:1310  列清单=stock_code
1 failed in 0.06s
```

**结论**：**1 failed**，精确点名新加的那一行。证明「这个文件里有几行是分派条件、该排除」这件事，守卫是**按语句结构逐条判**的，不是把整个文件都当成「提及、不用管」——排除项没有把整个文件弄瞎。

---

### M4b —— ⭐ 注入不写列清单的 `INSERT INTO training_sets VALUES (…)`（按位置插入）

**改了什么**：往 `backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh` 末尾追加一行：
`# M4B_PROBE: INSERT INTO training_sets VALUES (1,2,3);`

**跑了什么**：同上。

**原样贴出的观测输出**：
```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E
E         【不写列清单、按位置插入】**本守卫不接受这种写法**，必须改成显式列清单：
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486
1 failed in 0.06s
```

**结论**：**1 failed**，且落进的是**「按位置插入」**这一类，**不是**「列清单里没有 schema_version」那一类。今天全仓真实语句里，「按位置插入」这种写法命中数是 0——这组变异证明那个分支不是「反正永远不会走到、写了也白写」的死代码，而是真的会被触发、真的会响。

---

### M4c —— 注入 Python 相邻字符串字面量拼接形式

**改了什么**：追加一行 `# M4C_PROBE: q = "INSERT INTO training_sets" " (a,b) VALUES ($1,$2)"`（模拟生产语句那种「一条 SQL 被拆成两段相邻字符串字面量」的写法）。

**跑了什么**：同上。

**原样贴出的观测输出**：
```
E         【列清单里没有 `schema_version`】PostgreSQL 会用 `DEFAULT 1` **静默**把行标成第 1 代，而所有闸门照样绿：
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486  列清单=a,b
1 failed in 0.06s
```

**结论**：**1 failed**，列清单被正确解析为 `a,b`（跨过了引号+空格+引号的拼接缝隙）并判定缺字段。证明守卫认得生产代码最容易出现的那种写法。

---

### M4d —— 注入双引号标识符表名

**改了什么**：追加 `# M4D_PROBE: INSERT INTO "training_sets" (a, b) VALUES ($1,$2)`。

**跑了什么**：同上。

**原样贴出的观测输出**：
```
E         【列清单里没有 `schema_version`】…
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486  列清单=a, b
1 failed in 0.06s
```

**结论**：**1 failed**。证明 `INSERT INTO "training_sets"`（带双引号）这种写法也被表头正则认出来，不会因为多了引号就滑出视野。

---

### M4e —— 注入认不出的形状（CTE：`WITH … AS`）

**改了什么**：追加 `# M4E_PROBE: INSERT INTO training_sets WITH c AS (SELECT 1) SELECT 1;`。

**跑了什么**：同上。

**原样贴出的观测输出**：
```
E         【认不出的形状】必须由人来定性（是真语句就补 `schema_version` 并把该形状加进判据；是提及就说明理由）：
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486
1 failed in 0.06s
```

**结论**：**1 failed**，落进**「认不出的形状」**这一类——不是「列清单里没有」，也不是静默放过。证明守卫遇到自己没见过的写法时，归宿是「响、交给人来看」，不是「猜一个通过」。

---

### M4f —— 子串陷阱：`old_schema_version`

**改了什么**：追加缺字段语句，列清单写成 `stock_code, old_schema_version, file_path`。

**跑了什么**：同上。

**原样贴出的观测输出**：
```
E         【列清单里没有 `schema_version`】…
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486  列清单=stock_code, old_schema_version, file_path
1 failed in 0.06s
```

**结论**：**1 failed**——`old_schema_version` 这个列名虽然**包含** `schema_version` 这个子串，但守卫判据是「列名精确相等」，没有被子串假通过。

---

### M4g —— 全小写 `insert into training_sets (…) values (…)`

**原样贴出的观测输出**：
```
E         【列清单里没有 `schema_version`】…
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486  列清单=stock_code, file_path
1 failed in 0.06s
```
**结论**：**1 failed**。大小写不敏感识别生效。

---

### M4h —— schema 限定前缀 `INSERT INTO public.training_sets (…)`

**原样贴出的观测输出**：
```
E         【列清单里没有 `schema_version`】…
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486  列清单=stock_code, file_path
1 failed in 0.06s
```
**结论**：**1 failed**。带 `public.` 前缀的表名同样被认出。

---

### M4i —— 真漏写藏进块注释（第 1 轮定向复评挖出的阻断项，验证修复）

**改了什么**：追加 `INSERT INTO training_sets (stock_code, file_path /*, schema_version */) VALUES (1,2);`——`schema_version` 被塞进了 `/* … */` 块注释里，**真实列清单其实只有** `stock_code, file_path`。

**原样贴出的观测输出**：
```
E         【列清单里没有 `schema_version`】…
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486  列清单=stock_code, file_path /*, schema_version */
1 failed in 0.06s
```

**结论**：**1 failed**，且报错原文里列清单显示的是**未剥注释前的原文**（给人看方便定位），但判定用的是**剥完注释之后**的真实列名集合——正确判定为缺字段。历史上（守卫①第 1 版）这种写法会被**假通过**（块注释根本没被剥），这是该阻断项修复后的回归验证。

---

### M4j —— 合规写法 + 块注释（M4i 的正向对照，不得误报）

**改了什么**：追加 `INSERT INTO training_sets (stock_code, /* 第2代 */ schema_version, file_path) VALUES (1,2,3);`——这次块注释只是插在两个真列名之间，`schema_version` 本身不在注释里。

**原样贴出的观测输出**：
```
1 passed in 0.05s
```

**结论**：**PASSED**。证明剥注释不会把块注释**旁边**的真列名一起吃掉——上一次修复容易犯的对称错误（误报方向）没有发生。

---

### M4k —— 从 `_SUFFIXES` 里去掉 `.yml`（第 1 轮定向复评挖出的重要项：`.github/workflows` 整目录静默退出视野）

**改了什么**：守卫①的 `_SUFFIXES` 临时去掉 `".yml"`。

**原样贴出的观测输出**：
```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E
E         【有一类文件一条语句都没解析到】它多半被后缀白名单/改名悄悄移出了视野，而守卫会照样报「全都合规」：
E           .github/workflows  下的 .yml 文件
1 failed in 0.06s
```

**结论**：**1 failed**，精确点名 `.github/workflows` 下的 `.yml` 格子整格归零。这是逐目录锚点升级为「(目录, 后缀) 格子锚点」之后的效果——只删掉一个后缀就能让 5 条 CI 烟测语句集体消失，锚点当场响。

---

### M4l —— 往 `backend/Dockerfile`（无后缀，靠 `Dockerfile*` 前缀识别）塞缺字段 INSERT

**改了什么**：往 `backend/Dockerfile` 末尾追加：
`# M4L_PROBE: RUN psql -c "INSERT INTO training_sets (stock_code, file_path) VALUES ('a','b')"`

**原样贴出的观测输出**：
```
E         【列清单里没有 `schema_version`】…
E           backend/Dockerfile:33  列清单=stock_code, file_path
1 failed in 0.06s
```

**结论**：**1 failed**，精确点名 `backend/Dockerfile:33`。证明「没有文件后缀、但文件名以 `Dockerfile` 开头」这类文件也在扫描视野内——这是 PR-2 容器化之后补上的扫描口径。

---

### M4m —— ⭐⭐ 嵌套块注释吃字段（第 2 轮定向复评挖出的阻断项，验证修复）

**改了什么**：追加 `INSERT INTO training_sets (/* /* */ schema_version */ stock_code, file_path) VALUES (1,2);`——PostgreSQL 的块注释**可以嵌套**，非贪婪正则会在**第一个** `*/` 就收手，把 `schema_version */` 这一段误当成真内容，从而被**假通过**。这正是历史上第 2 轮定向复评实测出的阻断级绕法。

**原样贴出的观测输出**：
```
E         【列清单里没有 `schema_version`】…
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486  列清单=/* /* */ schema_version */ stock_code, file_path
1 failed in 0.06s
```

**结论**：**1 failed**——正确判定为缺字段。现在的注释屏蔽是「嵌套感知」的（认真数 `/*` `*/` 的深度），不再是容易被绕过的非贪婪正则。这是全片**两个阻断项之一**（另一个是 M4i 对应的「块注释根本没剥」）修好之后的回归验证，也是危险性最高的一组——它对应的是**假通过（真缺失却被放行）**方向，而不是误报方向。

---

### M4n —— 合规写法配嵌套块注释（M4m 的正向对照，不得误报）

**改了什么**：追加 `INSERT INTO training_sets (stock_code, /* /* /* */ */ */ schema_version, file_path) VALUES (1,2,3);`——三层嵌套注释夹在两个真列名之间。

**原样贴出的观测输出**：
```
1 passed in 0.05s
```

**结论**：**PASSED**。多层嵌套注释同样不会误伤旁边的真列名。

---

### M4o —— 从 `_SUFFIXES` 里去掉 `.md`（与 M4k 同类，换一个后缀验证同一道防线）

**改了什么**：守卫①的 `_SUFFIXES` 临时去掉 `".md"`。

**原样贴出的观测输出**：
```
E         【有一类文件一条语句都没解析到】它多半被后缀白名单/改名悄悄移出了视野，而守卫会照样报「全都合规」：
E           docs/runbooks  下的 .md 文件
1 failed in 0.06s
```

**结论**：**1 failed**，精确点名 `docs/runbooks` 下的 `.md` 格子。证明「(目录, 后缀) 格子锚点」这道防线对**任意一个**格子被清空都会响，不是只测过 `.yml` 那一个格子就再没测过别的。

---

### M4p —— 标识符边界：注入 `schema_version★`（前缀匹配会把它当成 `schema_version`）

**改了什么**：往 `docs/runbooks/2026-08-24-qmt-nas-deployment.md` 末尾临时追加一条

```
INSERT INTO training_sets (stock_code, schema_version★, file_path) VALUES (1,2,3);
```

⚠️ `★` 不是 Python 正则里的「单词字符」，所以**前缀匹配**会在它前面停下、把这一列当成
`schema_version`。而用真 PostgreSQL 解析器（`pglast`）核实：这一列的**真名是 `schema_version★`**
—— 也就是说这条语句**真的漏写了** `schema_version`。

**跑了什么命令**：

```
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q
```

**原样输出**：

```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E         
E         【列清单里没有 `schema_version`】PostgreSQL 会用 `DEFAULT 1` **静默**把行标成第 1 代，而所有闸门照样绿：
E           docs/runbooks/2026-08-24-qmt-nas-deployment.md:952  列清单=stock_code, schema_version★, file_path
```

**结论**：守卫**红**，并点名注入处、原样回显列清单 ⇒ 主判据抓得住这种「像但不是」的列名。

**⭐ 附加实测（控制者补记时才查清，写下来免得日后误解这一组在钉什么）**：
把判据从 `re.fullmatch` 退回 `re.match`（前缀匹配）再施加同一条注入，**分工是这样的**：

| 测试 | 结果 |
|---|---|
| 主判据 `test_every_executable_insert_carries_schema_version` | **绿** —— 正是 `fullmatch` 要挡住的那个**假通过** |
| 差分测试 `test_guard_agrees_with_real_postgres_parser` | **红** —— 它拿 `pglast` 当裁判，当场发现守卫与数据库的理解不一致 |

⇒ **M4p 证明的是「主判据抓得住 `★`」；真正钉住 `fullmatch` 这处修复的是【差分测试】。**
两者分工不同，⛔ 不可互相替代。

**还原**：`cp` 备份 + `finally` 还原；`git status --porcelain` 干净。

### M4q —— ⭐⭐ 把 `missing.append(...)` 整行换成 `pass`（第 3 轮定向复评挖出的重要项：上报链路可被短路）

**改了什么**：守卫①内部，把「发现缺字段后记进 `missing` 列表」那一行整行换成 `pass`（相当于「判据判出了违规，但决定不上报」——历史上这类改动，真实生产文件今天恰好全部合规，主测试本身不会有任何反应；必须靠**合成自测**才能钉住这种「上报动作被拔掉」的腐化）。

**跑了什么**：
```
cd "…/backend" && "$PY" -m pytest tests/test_insert_schema_version_guard.py::test_enforce_actually_raises_on_violations -q
```

**原样贴出的观测输出**：
```
F                                                                        [100%]
=================================== FAILURES ===================================
__________________ test_enforce_actually_raises_on_violations __________________
...
>           assert title in msg, f"⛔ 报文里缺类别「{title}」—— 上报/组装/抛出这条链路被短路了：\n{msg}"
E           AssertionError: ⛔ 报文里缺类别「【列清单里没有」—— 上报/组装/抛出这条链路被短路了：
E             `INSERT INTO training_sets` 守卫发现 3 类问题：
E
E               【有一类文件一条语句都没解析到】…
E
E               【认不出的形状】必须由人来定性…：
E                 weird.sql:1
E
E               【不写列清单、按位置插入】**本守卫不接受这种写法**，必须改成显式列清单：
E                 nocols.sql:1

tests/test_insert_schema_version_guard.py:415: AssertionError
1 failed in 0.02s
```

**结论**：**1 failed**——合成自测明确报出「报文里缺类别『列清单里没有』」，精确定位到问题出在哪一层。这是本片**判别力最要害的一组**：它证明「往真实生产文件扫描」的那条上报线，就算被人从**内部**拔掉一截，也有一条**独立**跑在合成小树上的自测会响，不是只有一条能被同一处腐化一起带倒的防线。

---

### M4s —— 引号标识符 + 尾随空格：`"schema_version "` 在 PG 眼里是另一个列

**改了什么**：追加 `INSERT INTO training_sets (stock_code, "schema_version ", file_path) VALUES (1,2,3);`——注意引号内 `schema_version` 后面多了一个空格。PostgreSQL 对**成对双引号包裹**的标识符是逐字比较、区分大小写、内部空格算数的，所以 `"schema_version "` 严格来说是一个**跟 `schema_version` 不同**的列名。

**原样贴出的观测输出**：
```
E         【列清单里没有 `schema_version`】…
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:486  列清单=stock_code, "schema_version ", file_path
1 failed in 0.06s
```

**结论**：**1 failed**——正确判定为缺字段（因为真正的列名其实是 `schema_version `，带一个空格，不是 `schema_version`）。

---

### M4t —— 合法引号标识符（M4s 的正向对照，逐字精确等于 `schema_version`，不得误报）

**改了什么**：追加 `INSERT INTO training_sets (stock_code, "schema_version", file_path) VALUES (1,2,3);`——引号内逐字精确是 `schema_version`，没有多余空格、大小写也一致。

**原样贴出的观测输出**：
```
1 passed in 0.05s
```

**结论**：**PASSED**。证明引号标识符的处理不是「一刀切把引号都当噪声抹掉」，也不是「一刀切认为带引号就不算」，而是按 SQL 语义精确处理：逐字相同才算数。

---

### M4u —— ⭐ 把最终 `assert not problems` 整句换成 `assert True`（第 4 轮定向复评挖出的重要项：判据被彻底掏空）

**改了什么**：守卫①内部的最终断言，从 `assert not problems, (...)` 换成 `assert True`（相当于「不管扫描结果是什么，反正永远算通过」——最彻底的一种腐化）。

**跑了什么**：同 M4q 的命令。

**原样贴出的观测输出**：
```
F                                                                        [100%]
=================================== FAILURES ===================================
__________________ test_enforce_actually_raises_on_violations __________________
...
E       Failed: DID NOT RAISE <class 'AssertionError'>
1 failed in 0.02s
```

**结论**：**1 failed**——合成自测报的是「本该抛出异常但没有抛出」（`DID NOT RAISE`）。这组证明：就算最终那句判决本身被换成恒真断言，也逃不过合成自测——因为主测试与合成自测**共用同一个函数**，改坏这一句会让两边同时失效，而 `pytest.raises(...)` 这个包装本身就在等一个异常，等不到就报错。

---

### M4v —— 把 `if missing:` 短路成 `if False:`（与 M4q 同族，验证另一处短路点）

**改了什么**：守卫①内部，把「有缺字段问题时才组装进报文」的 `if missing:` 换成 `if False:`（相当于「就算判出了缺字段，也永远不组装进最终报错」）。

**跑了什么**：同 M4q 的命令。

**原样贴出的观测输出**：
```
E           AssertionError: ⛔ 报文里缺类别「【列清单里没有」—— 上报/组装/抛出这条链路被短路了：
E             `INSERT INTO training_sets` 守卫发现 3 类问题：
E               【有一类文件一条语句都没解析到】…
E               【认不出的形状】…：weird.sql:1
E               【不写列清单、按位置插入】…：nocols.sql:1
1 failed in 0.02s
```

**结论**：**1 failed**，与 M4q 报的是同一类缺口（「列清单里没有」这一类整个从报文里消失）。证明「组装」这一层无论从哪个位置被短路，合成自测都能钉住，不依赖具体是拔掉了哪一行代码。

---

### M4w —— ⭐ 把生产语句的表名从字面量拆成 `"INSERT INTO " + "training_sets" + "…"`（Task 3 收口时量化的残留）

**改了什么**：`backend/generate_training_sets.py` 里唯一真写生产库的那条语句，把
`"INSERT INTO training_sets (stock_code, …"` 改写成
`"INSERT INTO " + "training_sets" + " (stock_code, …"`——表名从「与 `INSERT INTO ` 紧贴的字面量」变成了「隔着 `+` 拼起来的独立字面量」，表头正则在这个文件里**完全不再命中**（这是本守卫**结构上无法修补**的一类盲区：表名一旦不是紧贴的字面量，正则按定义够不着）。

**原样贴出的观测输出**：
```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 2 类问题：
E
E         【有一类文件一条语句都没解析到】它多半被后缀白名单/改名悄悄移出了视野，而守卫会照样报「全都合规」：
E           backend  下的 .py 文件
E
E         【生产语句脱离视野】`backend/generate_training_sets.py` 里一条都认不出 `INSERT INTO training_sets` 的列清单 —— 唯一真正写生产库的那条语句本守卫已经看不见了（多半是 SQL 被重构成变量拼接 / f-string / 搬去了别处）。⛔ 这不是「它没问题」，是「守卫看不见它了」。
1 failed in 0.06s
```

**结论**：**1 failed**，而且**两道防线一起响**——格子锚点（`backend` 下的 `.py` 文件整格归零）与专门盯着这一个生产文件的 `gen_seen` 检查同时报警。⭐ **附加核验**：把 `gen_seen` 那一条判据也短路成 `if False:` 之后再叠加同一个 M4w 变异，重新跑一遍：

```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E
E         【有一类文件一条语句都没解析到】它多半被后缀白名单/改名悄悄移出了视野，而守卫会照样报「全都合规」：
E           backend  下的 .py 文件
1 failed in 0.06s
```
**仍然是 1 failed**——由格子锚点单独接住。这证明代码里写明的那条残留（`gen_seen` 分支若被短路，不会造成静默放行，只会丢失一条更精确的报错信息）是**实测量过的**，不是一句空话。

---

# 守卫②（`test_training_set_ddl_no_drift.py`）—— M5 ~ M9

### M4x —— ⭐⭐ 把扫描循环截断成「每个文件只看第 1 条命中」（整支最终评审「重要 1」）

**改了什么**：两处，各命中 1 次（**已先数过锚点，不是空转**）：
- `backend/tests/test_insert_schema_version_guard.py`：`for m in _HEAD.finditer(text):` → `for m in list(_HEAD.finditer(text))[:1]:`
- `backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh`：把 `schema_version, file_path, content_hash,` 改成 `file_path, content_hash,`（**真漏写**，落在该文件第 2 条语句）

**为什么要有这一组**：此前守卫①所有防掏空判据都是「**至少一条**」形状（`checked >= 2`、每个格子 ≥1、`gen_seen >= 1`）。它们挡得住「**整类文件退出视野**」，⛔ **挡不住「同一个文件里少看几条」**。

**原样输出 —— 加守恒等式【之前】**：

```
【对照组】只注入真漏写、不截断        ⇒ 1 failed
【注入 + 截断】                      ⇒ 3 passed      ← 守卫、合成自测、差分测试【三条全绿】
```

**原样输出 —— 加守恒等式【之后】**：

```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E         
E         【有命中却没被判过】表头匹配到了，却没落进任何一类 —— 说明**发现端**被掏空了（例如扫描循环被截断）。⛔ 此时「全都合规」这个结论不成立：
E           backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh：表头命中 3 条，却只有 1 条被判过
E           backend/tests/test_b2_reconnect_integration.py：表头命中 2 条，却只有 1 条被判过
E           docs/runbooks/2026-08-24-qmt-nas-deployment.md：表头命中 2 条，却只有 1 条被判过
E           .github/workflows/schema-smoke.yml：表头命中 5 条，却只有 1 条被判过
1 failed in 0.07s
```

**结论**：守恒等式（每个文件的**表头命中总数** == 落进四个桶的条数之和）把这一族关死，且**逐个文件点名**命中几条、判过几条。
⚠️ `expected_hits` 用 `findall` 做**独立的第二次扫描**（⛔ 不复用 `finditer`）—— 两个来源互不依赖，一处编辑才改不掉两边；`mention` **也要计数**，否则等式自己就对不上。

---

### M4y / M4z —— 另两种截断形态（证明钉住的是一整族，不是那一个写法）

**改了什么**：同 M4x，只把截断方式换成 `[:-1]`（丢掉最后一条）与 `[::2]`（每隔一条）。

**原样输出**：

```
[:-1] 丢掉最后一条        ⇒ 2 failed, 1 passed in 0.09s
[::2] 每隔一条            ⇒ 2 failed, 1 passed in 0.09s
```

**结论**：两种都红。⭐ 另外**合成自测也红了**（`2 failed` 里有它）—— 因为本轮同时给它加了一个「**同一文件放两条语句**」的用例；此前全部合成用例都是「一个文件一条」，对截断**完全无感**。

---

### M10 —— 守卫②前提检查：四种引号形态各注入一次（整支最终评审「重要 2」）

**改了什么**：往冻结文件 `training_set_schema_v1.sql` 的 `ma66 REAL,` 处，分别注入四种带引号的词法形态（**每次都先确认变异真的落盘**）。

**为什么要有这一组**：守卫②的归一化会无条件抹掉紧贴 `( ) ,` 的空白，**不区分是否在引号内部**。挡住这个的**只有**「两份 DDL 零引号」这个前提。而上一版的前提检查**只认单引号** —— SQLite 有 **4 种**形态（`'…'` / `"…"` / `` `…` `` / `[…]`），四种各构造一对（只差逗号/括号旁的空格）实测**归一化后全部判等、前提检查全部放行**。

**原样输出**：

```
单引号 '…'     落盘=True ⇒ 1 failed in 0.02s
双引号 "…"     落盘=True ⇒ 1 failed in 0.02s
反引号 `…`     落盘=True ⇒ 1 failed in 0.02s
方括号 […]     落盘=True ⇒ 1 failed in 0.02s
```

**结论**：四种**各自**都能让前提检查变红 ⇒ 这条「前提一破立刻响」的检查现在覆盖 4/4，而不是 1/4。
⭐ 本仓成文教训：**穷尽性必须按字面量枚举后逐条定性**。

---

### M5 —— 冻结文件 `CREATE TABLE meta` 纯排版压成一行（不改任何列名/类型/约束）

**改了什么**：`backend/sql/training_set_schema_v1.sql` 里 `CREATE TABLE meta (…)` 从「一列一行」压缩成一行，逗号、括号旁的空白全部去掉，但**不改动任何列名、类型、约束**。

**跑了什么**：
```
cd "…/backend" && "$PY" -m pytest tests/test_training_set_ddl_no_drift.py::test_generator_ddl_matches_frozen_schema_file_statement_by_statement -q
```

**原样贴出的观测输出**：
```
1 passed in 0.01s
```

**结论**：**PASSED**（符合预期：判据钉的是结构，不是文本排版）。⚠️ **这条守卫在实施过程中曾经因为同类变异变红过一次**（详见下方「过程中发现的真缺陷」），当时的归一化只压缩连续空白、不处理紧贴括号/逗号的空白，是**真的误报**；已在提交 `aaab705f` 修复，现在的归一化会额外抹掉紧贴 `( ) ,` 的空白，本次重新实测确认已修好。

---

### M6 —— 冻结文件把 `ma66` 改成 `ma67`（真实列名漂移）

**改了什么**：`backend/sql/training_set_schema_v1.sql` 里 `ma66 REAL,` 改成 `ma67 REAL,`（一个从未出现过的列名）。

**原样贴出的观测输出**：
```
E       AssertionError: 生成器内嵌的建表语句与冻结的建表文件**已漂移**。
E         冻结文件 5 条 / 生成器 5 条。
E         只在冻结文件里：
E           CREATE TABLE klines(id INTEGER PRIMARY KEY AUTOINCREMENT,period TEXT NOT NULL,datetime INTEGER NOT NULL,open REAL NOT NU...
E         只在生成器里：
E           CREATE TABLE klines(id INTEGER PRIMARY KEY AUTOINCREMENT,period TEXT NOT NULL,datetime INTEGER NOT NULL,open REAL NOT NU...
1 failed in 0.02s
```

**结论**：**1 failed**，报文里**同时**列出「只在冻结文件里」（含 `ma67`）与「只在生成器里」（含 `ma66`）两条几乎一样、只差一个字符的 `CREATE TABLE klines` 语句——一眼就能看出差在哪个列名。证明守卫真的在逐语句比对内容，不是只比条数。

---

### M7 —— 生成器里把 `_TRAINING_SET_DDL` 定义处改名（锚点失效必须响，不能静默变绿）

**改了什么**：`backend/generate_training_sets.py` 把 `_TRAINING_SET_DDL = """` 改成 `_TRAINING_SET_DDL_X = """`（只改**定义**处，下面 `conn.executescript(_TRAINING_SET_DDL)` 那处**引用**没有跟着改——模拟「变量被改名、但用到它的地方漏改」）。

**原样贴出的观测输出**：
```
E       AssertionError: 在 generate_training_sets.py 里找不到 `_TRAINING_SET_DDL = """…"""` —— 是不是被改名或改成了别的写法？⛔ 抓不到就必须响，不能静默当作『没有漂移』
E       assert None
1 failed in 0.02s
```

**结论**：**1 failed**，报的是「找不到锚点」这句**专门写好的报错**，而不是退化成「两边都是空的所以算相等」。证明锚点失效这件事本身会**响**，不会被悄悄吞掉。

---

### M8 —— 往冻结文件塞一段块注释（预期方向安全的误报）

**改了什么**：往冻结文件的 `CREATE TABLE meta (` 前面插入 `/* M8_PROBE */`。

**原样贴出的观测输出**：
```
E       AssertionError: 生成器内嵌的建表语句与冻结的建表文件**已漂移**。
E         冻结文件 5 条 / 生成器 5 条。
E         只在冻结文件里：
E           /* M8_PROBE */ CREATE TABLE meta(stock_code TEXT NOT NULL,stock_name TEXT NOT NULL,start_datetime INTEGER NOT NULL,end_d...
E         只在生成器里：
E           CREATE TABLE meta(stock_code TEXT NOT NULL,stock_name TEXT NOT NULL,start_datetime INTEGER NOT NULL,end_datetime INTEGER...
1 failed in 0.02s
```

**结论**：**1 failed** —— 但这是**误报**（两边内容其实没有真的漂移，只是多了一段注释），**方向安全**：这条守卫的归一化只剥 `--` 行注释，不剥 `/* */` 块注释，所以往冻结文件里加块注释会被判成「漂移」。这是**故意接受的取舍**：吵闹（要人来看）好过悄悄放过一次真漂移。

---

### M9 —— 把 `_statements()` 短路成恒返回 `[]`（归一化坏了，防空转必须响）

**改了什么**：守卫②的 `_statements()` 函数开头插入 `return []`（相当于「不管传进来什么 SQL，一律当成切不出语句」）。

**原样贴出的观测输出**：
```
E       AssertionError: 冻结文件只切出 0 条语句 —— 归一化坏了
E       assert 0 >= 3
E        +  where 0 = len([])
1 failed in 0.02s
```

**结论**：**1 failed**，报的是「归一化坏了」，不是「两边都是空的所以相等」。防空转判据挡住了「两边都被我搞坏成空列表，恰好相等」这种假绿。

---

# 附加核验（不在台账原始编号里，但与本片残留的准确性直接相关）

### 附加核验 A —— 订正：`_SCOPE_DIRS` 整个删掉一个目录，现在**不再是**静默盲区

Task 3 实施过程中期（守卫①仍是「逐目录」锚点、尚未升级成「(目录, 后缀) 格子」锚点的那个阶段），控制者自查曾经记录过一条结论：「改 `_SCOPE_DIRS` 本身（整个删掉一个目录）仍是静默的」。这条结论在**当时的代码版本**下是对的，但守卫后续又经过两轮修复（锚点升级为「(目录, 后缀) 格子」、且格子清单与 `_SCOPE_DIRS` 是**两份独立**的写死清单），本记录撰写时在**最终代码**上重新实测这条结论是否还成立：

**改了什么**：`_SCOPE_DIRS` 从三个目录整个改成只留 `[REPO_ROOT / "backend"]`（相当于把 `docs/runbooks` 与 `.github/workflows` 两个目录整个从作用域里删掉）。

**跑了什么**：同 M0 的命令。

**原样贴出的观测输出**：
```
E       AssertionError: `INSERT INTO training_sets` 守卫发现 1 类问题：
E
E         【有一类文件一条语句都没解析到】它多半被后缀白名单/改名悄悄移出了视野，而守卫会照样报「全都合规」：
E           docs/runbooks  下的 .md 文件
E           docs/runbooks  下的 .sql 文件
E           .github/workflows  下的 .yml 文件
1 failed in 0.05s
```

**结论**：**1 failed** —— 现在会响。⇒ **上一版那条「仍是静默盲区」的结论已经过时**，本记录以这次重新实测为准：`_EXPECTED_CELLS`（格子清单）与 `_SCOPE_DIRS`（扫描目录）是分开写死的两份清单，删掉 `_SCOPE_DIRS` 里的目录会让对应格子的计数掉到 0，被 `blind` 判据接住。这条订正已同步写进验收清单的残留部分。

### 附加核验 B —— 守卫②新增的「前提检查」真的能报非 0

`test_normalisation_premise_no_string_literals` 是 Task 4 收口时新增的第三条常驻测试，钉住「归一化会抹掉紧贴 `( ) ,` 的空白、但不区分是否在字符串字面量内部」这个前提。本记录重新验证这条检查不是恒真的：

**改了什么**：往冻结文件的 `stock_code TEXT NOT NULL,` 后面加一个字符串字面量默认值，改成 `stock_code TEXT NOT NULL DEFAULT 'x',`（往 DDL 里引入了一个单引号）。

**跑了什么**：
```
cd "…/backend" && "$PY" -m pytest tests/test_training_set_ddl_no_drift.py::test_normalisation_premise_no_string_literals -q
```

**原样贴出的观测输出**：
```
E       AssertionError: DDL 里出现了**字符串字面量**（单引号），而本守卫的归一化会抹掉紧贴 `( ) ,` 的空白、**不区分是否在字面量内部** ⇒ 两个不同的默认值可能被判成相同（**假通过**）。
E           出现处：[('冻结文件 training_set_schema_v1.sql', 2)]
E         ⛔ 修法：把 `_statements` 改成**先切出字符串字面量、比较时不动它们内部**，改完再把这条前提检查一并更新。⛔ 不要简单地删掉本测试。
1 failed in 0.02s
```

**结论**：**1 failed**，精确报出「冻结文件里出现了 2 处单引号」。证明这条前提检查不是一句只写在注释里、没人核实过的承诺，而是真的会在前提被打破时响。

---

# 末尾点出几组，说明各自证明了什么

⛔ 下面**只挑重点讲**，不是穷尽全部（条数见文件开头那条 `grep -c`；每组的结论已在上面各自写明）：

- **M0**（把唯一那条生产语句列清单里的字段删掉）—— 这是 spec 明令的那条，也是**上一版判据恒绿的地方**。它红了，才证明守卫对「唯一会真毁数据的那一处」有判别力。
- **M2**（跨行那条的字段被删 ⇒ 红）—— 证明守卫**真的按语句在看**，不是按行。
- **M5 + M6 配对**（只改排版仍绿 / 改一个列名变红）—— 证明第二条守卫钉的是**结构**不是**文本**。
- **M7**（变量改名 ⇒ 报「找不到锚点」而非静默变绿）—— 证明锚点失效会**响**。
- **M4b**（临时写一条不带列清单的 `INSERT`）—— 证明「按位置插入」那条**今天零命中**的分支**不是恒真**，而且报的是**它自己**那条失败信息。
- **M4i 与 M4m**（块注释吃字段 ⇒ 红）—— 全片**两组对应过阻断级「假通过」缺陷**的变异。
  历史上守卫①第 1 版**根本没剥块注释**（M4i 那种单层写法就能骗过它）；第 2 版改用非贪婪正则，
  单层堵上了、但 **PG 的块注释可以嵌套**，于是 M4m 那种写法照样骗得过。两次都是**假通过**方向。
  ⚠️ 上一版这里写「M4m 是**唯一**一组」—— **那是错的**（整支最终评审「重要 3」）。控制者已实测坐实：
  把守卫①退回第 1 版形态（不剥注释 + 前缀匹配）再施加 M4i 的探针 ⇒ **主判据 `1 passed`**，
  真漏写被**静默放行**；同样形态下施加 M4m ⇒ `1 failed`。⇒ M4i 确实是第二组。
  ⭐ 这是本片**第五次**「未经实测就写下一句关于『它挡住过什么』的断言」。
- **M4q + M4u + M4v**（上报/组装/最终断言三处分别被短路 ⇒ 全部由合成自测钉住）—— 证明「判据判出了违规」到「最终真的抛出异常」这条链路上，无论从哪一层短路，都逃不过同一份被主测试与合成自测**共用**的代码。
- **附加核验 A**（订正 `_SCOPE_DIRS` 整个删目录的结论）—— 证明**本仓关于「守卫会不会静默」的结论必须随代码版本重新核实**，旧结论不能照抄。
