# 切片一 P3b（`INSERT` 补 `schema_version` + 两条按语句匹配的守卫）· 非程序员验收清单

**这一片做了什么（一句话）**：数据库里「训练组」这张表有一列叫 `schema_version`（可以理解成「这条记录是按哪个版本的格式写的」，数据库自己会给它一个默认值 `1`），程序里往这张表写新记录的语句，一共有 10 处忘了写这一列——不写不会报错，数据库会悄悄把这些行的版本号记成默认的 `1`（第 1 代格式），而所有检查照样显示「通过」。这一片把这 10 处全部补上，然后加了两道「以后谁再忘写、谁再让两份建表说明对不上，会立刻被自动检查拦下来」的机械防线。

**为什么要做**：

- 「往数据库写一条训练组记录、却漏写它是第几代格式」这件事，**数据库层面完全不会报错**，它只会安安静静地把这一行标成「第 1 代」。等到有一天系统需要根据这一列区分新旧格式数据时，被漏写的这些行会被误判成「旧格式」——而没有任何人、任何检查会提醒你出了问题。这 10 处漏写分布在三类地方：程序代码里迁移彩排用的脚本（3 处）、部署手册里的操作步骤（2 处）、自动化流水线的配置文件（5 处，这类文件在本仓有专门的提交规矩，所以单独放在一个改动里处理）。
- 只补齐这 10 处还不够——补完之后，如果**将来**又有人在这三类地方新写一条往这张表插数据的语句、又忘了写这一列，同样的问题会原样重演。所以这一片新加了**第一条自动检查**：扫描这三类地方里所有「往这张表插数据」的语句，逐条确认都写了这一列，漏了就立刻报错。
- 另外，程序里生成训练组数据文件时，内嵌了一份「照着建表」的语句；仓库里还单独存着一份「已经定版、不能随便改」的建表说明文件。程序的注释里写着「这两份逐字一致」，但从很早的版本起，就**没有任何检查**真的在核对这句话是否成立。这一片新加了**第二条自动检查**：确认这两份建表语句逐条相同，一旦有人改了其中一份却忘了改另一份，检查会报错。

⛔ **这一片交付后，仍然不能说**「手机能用了」「跨端契约已闭合」——手机 App 那边一行代码都没有动，详见下面「本片交付后仍不成立的事」第 11 条。可以说：**「写库语句已补齐字段、两条漂移守卫已就位」**。

---

## 开始之前

所有命令都在**这个目录**下跑：

```
/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run
```

⚠️ 这个目录里**没有**装 Python（一种编程语言的运行环境）。命令里那一长串路径 `"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3"` 是主目录里装好的那一份，**必须原样照抄**，不能省略、不能改写成简单的 `python3`。

⚠️ 每条命令**只有一行**（哪怕看起来很长）。如果你复制粘贴到终端（就是那个黑色/白色的命令输入窗口）后它自动断成了好几行，说明复制过程中被截断了，请重新复制整行。

⭐ 这一片**没有任何一行改动到手机 App**。想省时间的话，跑 **A1 + A2 + A7** 就够（约 1 分钟）。

---

## A1 · 后端全部测试通过，一条都没被跳过

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```

（这条命令的意思：把后端程序里**所有**自动检查项都跑一遍，一次跑 1500 多项。）

**期望看到**：最后一行是 `1511 passed in <某个秒数>`。

**通过判定**：

- 通过 —— 数字是 **1511**，且这一行里**没有** `failed`（失败）、`skipped`（跳过没跑）、`error`（出错）这三个词。
- 不通过 —— 出现上述任一个词；或数字不是 1511。

⚠️ **1511 是这条分支上的快照**（这条改动合并进主干之后，别人的新改动会让这个数字继续变化）。对不上时先查是不是别的改动动了这份基准数字，⛔ 不要直接改这份清单里的数字。

---

## A2 · 这一片新加的两条检查，共 6 条，逐条列给你看

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py tests/test_training_set_ddl_no_drift.py -v
```

**期望看到**：含 `PASSED`（通过）的行**恰好 6 行**（前面还会有几行环境信息，不用管），最后一行是 `6 passed in <某个秒数>`。六条分别在管：

| 序 | 所在文件 | 这条在管什么 |
|---|---|---|
| 1 | `test_insert_schema_version_guard.py` | 拿一棵合成的假文件树喂给扫描逻辑，确认「发现问题 ⇒ 必须被记录并抛出报错」这条链路本身没有被悄悄拆掉 |
| 2 | `test_insert_schema_version_guard.py` | **主判据**：可执行路径里每一条真的往「训练组」表插数据的语句，列清单里都必须有这一列 |
| 3 | `test_insert_schema_version_guard.py` | 拿真正的 PostgreSQL 语法解析器（`pglast`）当裁判，确认这条检查对各种刁钻写法（嵌套注释、引号标识符、大小写…）的判断和数据库自己的理解逐条一致 |
| 4 | `test_training_set_ddl_no_drift.py` | 确认「这两份建表说明逐字相同」这句承诺赖以成立的前提（两份说明里都不含带引号的字符串默认值）现在仍然成立，一旦破了立刻报错 |
| 5 | `test_training_set_ddl_no_drift.py` | 证明「排版不同不算漂移」这句话是真的（用手写的等价对钉住），同时防止「改宽了反而认不出真改动」 |
| 6 | `test_training_set_ddl_no_drift.py` | **主判据**：程序里内嵌的建表语句，与仓库里已定版的建表说明文件，逐条语句必须相同 |

**通过判定**：

- 通过 —— 含 `PASSED` 的行恰好 6 行，最后一行以 `6 passed` 开头。
- 不通过 —— 任何一行是 `FAILED`（失败）；或含 `PASSED` 的行数不是 6 行。

---

## A3 · 治理脚本套件，结果跟改动前一模一样

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && bash tests/scripts/governance/run-all.sh
```

**期望看到**：一长串 `PASS: …`，最后一行是 `ALL GREEN`。

**通过判定**：

- 通过 —— 最后一行是 `ALL GREEN`，整段输出里没有任何一行以 `FAIL` 开头。
- 不通过 —— 出现任何一行 `FAIL:`；或最后一行不是 `ALL GREEN`。

---

## A4 · 逐条列出「往训练组表插数据」的语句，确认全部带了这一列

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -c "import sys; sys.path.insert(0,'tests'); import test_insert_schema_version_guard as g; files=list(g._iter_files()); [print(f\"{q.relative_to(g.REPO_ROOT).as_posix()}:{txt.count(chr(10),0,m.start())+1}  含schema_version={'schema_version' in g._column_names(cols)}\") for q in files for txt in [q.read_text(encoding='utf-8')] for m in g._HEAD.finditer(txt) for kind,cols in [g._classify(txt,m.start(),m.end())] if kind=='cols']"
```

（这条命令直接调用上面那条检查自己的扫描逻辑，把它扫到的每一条语句、以及是否带了这一列，逐行打印出来。）

**期望看到**：**恰好 12 行**，每行末尾都是 `含schema_version=True`：

```
backend/generate_training_sets.py:563  含schema_version=True
backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:206  含schema_version=True
backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:213  含schema_version=True
backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:443  含schema_version=True
docs/runbooks/2026-08-24-qmt-nas-deployment.md:613  含schema_version=True
docs/runbooks/2026-08-24-qmt-nas-deployment.md:645  含schema_version=True
docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql:63  含schema_version=True
.github/workflows/schema-smoke.yml:73  含schema_version=True
.github/workflows/schema-smoke.yml:76  含schema_version=True
.github/workflows/schema-smoke.yml:79  含schema_version=True
.github/workflows/schema-smoke.yml:82  含schema_version=True
.github/workflows/schema-smoke.yml:85  含schema_version=True
```

⚠️ **12 行，不是 10 行**：这一片实际要补的漏写只有 10 处，但可执行路径里本来就还有 2 处语句是**早就合规**的（`generate_training_sets.py:563` 那一处、以及 `qmt-nas-p11-insert-training-sets.sql:63` 那一处）——它们不是本片改的，但本片的检查也要能看到它们、确认它们没问题。

**通过判定**：

- 通过 —— 恰好 12 行，每行都是 `True`。
- 不通过 —— 行数不是 12；或任意一行出现 `False`。

---

## A5 · `schema-smoke.yml` 里那四个「必须失败」的感叹号，一个没少

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && grep -c '! *psql' .github/workflows/schema-smoke.yml
```

**期望看到**：`4`

**为什么这件事要紧**：这份流水线配置文件里，有 4 行是「故意插入一条不合法的记录，然后断言数据库会拒绝它」（比如插入一个大写的十六进制校验码、一个不存在的状态值），断言方式是在 `psql` 命令前面加一个感叹号 `!`（意思是「这条命令**必须**失败，如果它意外成功了，整条流水线才算出错」）。这四行的目的是确认数据库里那几条「拒绝非法数据」的规则真的在生效。

⛔ **一旦有人不小心把某一行的感叹号删掉**（哪怕只删一个字符），这一行的意思会**完全反过来**：从「这条必须失败，否则报警」变成「这条随便，反正不管成不成功都算过」。而如果这一行本来测的是「插入一条本该被拒绝的非法数据」，感叹号一丢，这行就从「验证拒绝非法数据」悄悄变成了「验证接受非法数据」——**测试还是会显示绿色**，但它已经在测一件完全相反的事，没有人会注意到。

**通过判定**：

- 通过 —— 数字是 **4**。
- 不通过 —— 数字不是 4（多了或少了都要立刻去看哪一行的感叹号被动过）。

---

## A6 · CI 配置文件改完之后，还能被正常解析

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -c "import yaml; d=yaml.safe_load(open('.github/workflows/schema-smoke.yml',encoding='utf-8')); print('YAML OK'); print('jobs=',list(d['jobs'].keys()))"
```

（YAML 是这份配置文件使用的格式，格式一旦被改坏，流水线会直接跑不起来。这条命令用程序把文件重新读一遍，读得进去才说明格式没坏。）

**期望看到**：
```
YAML OK
jobs= ['postgres-runtime-smoke', 'sqlite-runtime-smoke']
```

**通过判定**：

- 通过 —— 两行都出现，`jobs` 里恰好是这两个名字。
- 不通过 —— 报错（说明文件格式坏了）；或 `jobs` 列表内容不对。

---

## A7 · 三个禁区，一行都没被动过

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && echo "ios/ 改动行数：$(git diff --stat 8d47e811...HEAD -- ios/ | wc -l | tr -d ' ')；backend/sql/schema.sql 改动行数：$(git diff --stat 8d47e811...HEAD -- backend/sql/schema.sql | wc -l | tr -d ' ')；generate_training_sets.py 改动行数：$(git diff --stat 8d47e811...HEAD -- backend/generate_training_sets.py | wc -l | tr -d ' ')"
```

（这一片明确规定三个地方不能碰：手机 App 代码（`ios/`）、数据库的正式建表文件（`backend/sql/schema.sql`）、生成训练组数据的程序（`generate_training_sets.py`，本片对它**只读不改**）。）

**期望看到**：`ios/ 改动行数：0；backend/sql/schema.sql 改动行数：0；generate_training_sets.py 改动行数：0`

**通过判定**：

- 通过 —— 三个数字都是 `0`。
- 不通过 —— 任一数字大于 0。

---

## A8 · 本片一共动了哪些文件

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && git diff --name-only 8d47e811...HEAD | sort
```

**期望看到**（**8 行**——这份验收清单、变异记录、施工计划这三份文档提交进版本记录之后是 8 行；⚠️ 若你是在这三份文档提交**之前**跑这条命令，会看到 5 行，少了标 ⭐ 的那 3 行）：

```
.github/workflows/schema-smoke.yml
backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh
backend/tests/test_insert_schema_version_guard.py
backend/tests/test_training_set_ddl_no_drift.py
docs/acceptance/2026-09-17-trainingset-p3b-acceptance.md
docs/acceptance/2026-09-17-trainingset-p3b-mutation-log.md
docs/runbooks/2026-08-24-qmt-nas-deployment.md
docs/superpowers/plans/2026-09-17-trainingset-p3b-insert-schema-version.md
```

| 文件 | 干什么的 |
|---|---|
| `.github/workflows/schema-smoke.yml` | 自动化流水线的 5 处烟测语句补齐这一列（单独一次提交，本仓对这类文件有专门的提交规矩） |
| `backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh` | 数据库迁移彩排脚本里的 3 处语句补齐这一列 |
| `backend/tests/test_insert_schema_version_guard.py` | 新建，**第一条守卫**：每条往训练组表插数据的语句都必须带这一列 |
| `backend/tests/test_training_set_ddl_no_drift.py` | 新建，**第二条守卫**：程序内嵌的建表语句必须与已定版的建表说明文件逐条相同 |
| `docs/acceptance/2026-09-17-trainingset-p3b-acceptance.md` | ⭐ 本清单 |
| `docs/acceptance/2026-09-17-trainingset-p3b-mutation-log.md` | ⭐ 变异记录（逐条「故意改坏、看它红不红」的实测） |
| `docs/runbooks/2026-08-24-qmt-nas-deployment.md` | 部署手册里的 2 处烟测语句补齐这一列 |
| `docs/superpowers/plans/2026-09-17-trainingset-p3b-insert-schema-version.md` | ⭐ 本片的施工计划文档 |

**通过判定**：

- 通过 —— 只出现上面这 8 个（若在三份文档提交之前跑，是 5 个，缺 ⭐ 那 3 个）。
- 不通过 —— 出现清单之外的文件。

---

## A9 · 两条守卫真的会报错，不是摆设——你自己动手试一次

光看「检查全绿」说明不了任何事——一条永远显示「通过」的检查，跟没有这条检查是一回事。下面这条命令会**当场**把两条守卫各弄坏一处（不影响任何真实数据，只改程序文件里的文字），让你亲眼看到它们真的会报错，跑完之后**自动把改动还原**，不需要你自己手动改回去。

**动作**（⚠️ 这条命令比较长，但仍然是**一整行**，务必整行复制粘贴）：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && GEN="backend/generate_training_sets.py" && FROZEN="backend/sql/training_set_schema_v1.sql" && cp "$GEN" "$GEN.bak" && cp "$FROZEN" "$FROZEN.bak" && trap 'cp "$GEN.bak" "$GEN"; rm -f "$GEN.bak"; cp "$FROZEN.bak" "$FROZEN"; rm -f "$FROZEN.bak"; find backend -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null; echo "[已还原，树已恢复原样]"' EXIT && sed -i '' 's/"schema_version, file_path, content_hash)/"file_path, content_hash)/' "$GEN" && sed -i '' 's/ma66 REAL,/ma67 REAL,/' "$FROZEN" && find backend -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null && echo "—— 现在两条守卫应该都变红 ——" && (cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py::test_every_executable_insert_carries_schema_version tests/test_training_set_ddl_no_drift.py::test_generator_ddl_matches_frozen_schema_file_statement_by_statement -q)
```

（这条命令做了四件事，按顺序：① 先把两个会被临时改坏的文件各备份一份；② 设好「不管命令怎么结束，最后都要把备份拷回去」这条保险；③ 分别在两个文件里各删/改一个字，让两条守卫各自该管的问题重新出现一次；④ 跑这两条守卫，看它们红不红。跑完你会看到 `[已还原，树已恢复原样]` 这句话，说明④ 结束之后①的备份已经原样拷回去了，仓库回到跟你跑之前一模一样的状态。）

**期望看到**（顺序可能因终端缓冲略有不同，不影响判定）：

```
—— 现在两条守卫应该都变红 ——
（中间是两条失败的详细信息，各自点名是哪个文件、哪一行）
FAILED tests/test_insert_schema_version_guard.py::test_every_executable_insert_carries_schema_version
FAILED tests/test_training_set_ddl_no_drift.py::test_generator_ddl_matches_frozen_schema_file_statement_by_statement
2 failed in <某个秒数>
[已还原，树已恢复原样]
```

**通过判定**：

- 通过 —— 最后是 `2 failed`（两条守卫都报错了），且看到 `[已还原，树已恢复原样]`。
- 不通过 —— 任何一条守卫没有报错（说明它是摆设）；或没看到还原那句话（说明改动可能没清干净，此时请立刻跑 `git status --short` 检查，正常应该只剩未跟踪的既有文件）。

⚠️ 想确认真的恢复原样了，可以再跑一遍这条核对命令：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && git status --short
```

应该看不到 `backend/generate_training_sets.py` 或 `backend/sql/training_set_schema_v1.sql` 这两个文件出现在结果里。

---

## 本片交付后**仍不成立**的事（请逐条读）

### R1 · PostgreSQL 那一列的「默认值」本身没有去掉

数据库那一列的定义仍然是「不写就自动填 `1`」。更彻底的做法是把这个默认值去掉（这样漏写会直接报错，而不是静默填一个值），但这属于数据库结构的正式变更，需要走专门的、受治理流程管控的变更手续，而且会导致另一道「形状闸门」（一份核对数据库建表文件有没有被改动的自动检查）里存的指纹全部失效，需要重新生成整份闸门文件——代价和收益不成比例，这一片**刻意不做**。⇒ 日后这张表如果因为别的原因需要改结构，**顺带**把这个默认值也一起去掉。

### R2 · 第一条守卫（往表里插数据必须带这一列）有三类已知的、结构上看不见的死角

这条守卫只扫描三类地方（程序代码目录、部署手册目录、流水线配置目录）。它看不见的情况包括：

1. **这三类目录之外的地方**：比如以后有人在 `scripts/` 目录下新写一条往这张表插数据的语句，这条守卫**看不到**，不会报错。（已实测：`scripts/`、`ios/` 下面今天确实一处都没有。）
2. **文件后缀不在白名单里的文件**：这条守卫只认 `.py` `.sql` `.sh` `.md` `.yml` `.yaml` 这六种后缀，以及一个特殊照顾——没有后缀但文件名以 `Dockerfile` 开头的文件。往这三类目录里放一个 `.txt` `.env` `.psql` 之类的新格式文件，这条守卫会悄悄漏掉它、**不报错**。
3. **表名不是直接写在代码里、而是拼出来的情况**：比如把表名写成一个变量、再用这个变量拼出整条语句（`f"INSERT INTO {表名变量} (…)"` 这种写法），这条守卫在结构上**够不着**——它是按照「代码里直接写着 `training_sets` 这几个字」来找语句的，看不见拼出来的表名。这一层修不了：按照直接写死的字来找语句的检查，天生看不见「算出来的」表名。
   ⇒ 但这条守卫里专门为**唯一真正往数据库写数据的那一个文件**（`generate_training_sets.py`）多留了一道后备防线：只要它认不出这个文件里有任何一条合规的插入语句，就会额外报警。已实测：把这个文件里的表名改造成拼接的形式，这道后备防线**照样会响**（见变异记录 M4w）。这道后备防线**只**照顾这一个文件，别的地方发生同样的写法仍然看不见。
4. **表名和列清单之间夹着不是直接写死的内容**（变量、格式化字符串等）时，这条守卫解析不出列清单；如果这时表名两边恰好被引号包住，会被误判成「只是提到了这个词、不是真语句」而**悄悄跳过**，不报错。这一层也由上面第 3 条说的那道后备防线兜底，同样**只**兜住 `generate_training_sets.py` 这一个文件。

> ⭐ **交付前的整支评审又挖出第 4 类，已当场补上判据**（所以上面列的不是「全部」，是「今天已知的」）：
> 前面三类讲的都是「**整类东西退出视野**」（目录外、后缀外、表名拼出来的）。评审员发现还有一种
> 更细的：**同一个文件里少看几条**。当时所有防空转判据都是「**至少要有一条**」这种形状，
> 挡得住「一整类文件不见了」，挡不住「这个文件里本来有 5 条、现在只看了 1 条」。
> 实测：把扫描循环改成「每个文件只看第 1 条」（**改一处**），再真删掉一处的这一列 ⇒
> 两条守卫加那条差分检查**三条全绿**。
> ⇒ 已补上一条**守恒等式**：每个文件里「找到几条」必须等于「判过几条」，对不上就报
> 「**有命中却没被判过**」并逐个文件点名。三种截断方式实测**全部变红**（见变异记录 M4x / M4y / M4z）。
> ⚠️ 这条残留**已闭合**，保留在这里是因为它说明了一件更要紧的事：
> **「至少有一条」这种检查天生表达不了「有没有漏掉」，要表达那个必须用等式。**

⛔ 以上任何一条都不是「反正总会被别处抓到」，这份清单**刻意不写总条数**，因为这个数字在实施过程的多轮复核里被错报过好几次——数条数不如把每一条看清楚。

> ⭐ **第二条守卫的前提检查，交付前也被评审员扩过一次**：它靠「两份建表说明里一个引号都没有」
> 这个前提才成立（因为它会抹掉括号和逗号旁边的空格，而引号里面的空格是有意义的）。
> 上一版这条前提检查**只认单引号一种**，而 SQLite 一共有**四种**带引号的写法
> （`'…'`、`"…"`、反引号、`[…]`）。实测四种各造一对「只差一个空格」的例子 ⇒
> **四种全部被判成相同、而前提检查全部放行**。已扩到四种，并逐一实测各自都能报错（见变异记录 M10）。

### R3 · 第一条守卫只看「列清单里写没写这一列」，不看后面「值给了几个」

如果有人写对了列名（`schema_version` 三个字都在），但后面 `VALUES` 里少给了一个值，让列和值对不上号——这类错误这条守卫**抓不到**。这一类错误在补齐这 10 处的过程中，已经用一次性的人工检查（不是常驻检查）逐条核对过，确认这一片补的 10 处、以及流水线配置文件那 5 处，列和值都是对齐的。⚠️ 但这个人工核对**只在这一片实施时做过一次，不是长期存在的自动检查**——以后如果有人新写一条插入语句、列和值错位，没有任何常驻检查会报错。

另外，如果有人把一条真的插入语句整行注释掉（比如写成 `-- INSERT INTO training_sets (a,b) …`），这条守卫会把它当成「缺字段」报错——这是**故意的取舍**：被注释掉的语句到底是「暂时不用」还是「本该删掉」，交给人来判断，好过检查自己悄悄放过。

### R4 · 第二条守卫（两份建表说明必须逐条相同）对「两边一起被改错」没有防御力

如果有人**同时**把两份建表说明改成同样错误的内容（比如都从版本号 2 改回 1），这条守卫是看不出来的——它比的是「两边是否一致」，不是「两边的内容是否正确」。数据库版本号那一行另外有一道独立的检查在盯着（比对治理台账里记录的版本号），但列名这类「两边一起改错」的情况，目前确实没有人看管。
另外这条守卫**只**比对程序里那一段内嵌建表语句；程序里以后如果又新增第二段内嵌建表语句，这条守卫不会覆盖到它。

### R5 · 第二条守卫的「排版不算漂移」这件事，有一个前提，前提被打破时会响但不会自动修好

这条守卫判断「两份说明是否相同」时，会把标点符号旁边多余的空格都抹掉（这样才不会把纯排版差异误判成真的不一致）。这个抹法只有在**两份说明里都不含带引号的字符串默认值**（比如 `DEFAULT 'x y'` 这种写法）时才是安全的——一旦出现字符串，抹空格可能会把两个本来不同的默认值判成相同。今天这两份说明里确实一个引号都没有，而且本片新加了一条**专门检查这个前提**的常驻测试：前提一旦被打破，这条测试会**立刻**报错、并在报错信息里写清楚该怎么修，不会等到某天真的出现字符串却悄悄放过。

### R6 · 仓库里的守卫代码本身，没有任何东西能证明自己不会被后续改动整体删掉

这两条守卫是普通的程序代码，跟仓库里其它文件一样，可以在同一次改动里被删掉或改成「什么都不检查」。这类改动没有任何自动机制能拦下来，**只能靠人看改动内容**（code review）。这不是这一片能解决的问题，是本仓库所有自动检查共通的局限。

### R7 · 数据库里现存的 3 个训练组，仍是老版本格式

在**下一步（P4）**把它们重新生成成新版本格式之前，负责对外提供服务的程序（`api`）、按时间自动跑的任务（`scheduler`）、以及生成训练组的命令行工具，**都必须保持停止状态**，不能上线运行。

### R8 · 部署手册里「怎么取数据」那一步，来源目录仍然是旧包所在的目录

运维手册里那份「怎么从服务器上取数据」的步骤，是从 NAS（网络存储设备）上一个交接目录里拷贝，但那个目录里存放的**仍然是老版本格式的包**。**下一步（P4）必须把这个数据来源目录本身也一起处理掉**，否则将来照着手册重新部署一次，会用过时的包把已经修好的包覆盖回去。

### R9 · 本片守卫红了，现在真的会拦住代码合并

跟这一片之前的几片不一样：从 2026-09-17 起，「后端完整测试套件」已经被加进了代码托管平台（GitHub）的「合并前必须通过」名单（一共 8 项必需检查，全部绑定在正式的自动化流程上）。也就是说，如果以后有人的改动让这两条守卫报错，**默认情况下这次改动没法被合并进主干**。⚠️ 这跟本仓更早几片交付时的情况**不同**——早几片交付时，新加的检查就算全部报错，也拦不住代码被合并；现在不是这样了，请不要照抄旧清单里「拦不住合并」那句话。

### R10 · 手机 App 那边运行时的逻辑代码，一行都没有改

这一片对手机 App 的改动是 **0 个文件**。手机 App 现在还用不了新格式的数据，这件事归**切片二**（下一个大阶段），而且切片二要过两道拦路石：一是手机 App 现在只认识旧的文件格式（`.sqlite`），二是 `DefaultTrainingSetReader.swift` 文件第 90-92 行有一段代码，会在读到新格式数据时直接判定为「数据库损坏」并拒绝。

⛔ 因此**不能说**「手机能用了」「跨端契约已闭合」「版本已对齐」。
可以说：**「写库语句已补齐字段、两条漂移守卫已就位」**。

### R11 · 切片二完成之后，必须再升一次顶层版本号，且不能跟这一片共用同一个号

上一片（P3c）已经把顶层版本号升到了 `1.14`，这是一个**故意留着的过渡状态**：代表「后端数据已经是新格式，但手机 App 还没跟上」。切片二做完之后，如果**不再升一次版号**，那「手机 App 还读不了新格式」和「手机 App 已经能读新格式」这两种完全不同的状态，就会共用同一个版本号，所有跨语言的自动检查在两种状态下都会显示「正常」——版本号就失去了应有的意义。⚠️ 至于升完是不是正好 `1.15`：**如果这段时间里没有别的改动先占用了下一个号，那就是 `1.15`**；但同时还有另一条工作线（划线工具那条线）也欠着「必须升一次版号」的账，很可能会先占用下一个号——所以这里只能说「下一个号」，不能咬死一定是 `1.15`。

---

## 变异验证（这些检查**真的会红吗**）

光看「检查全绿」说明不了任何事——一条永远为真的断言，也会永远显示「通过」。所以这一片给两条新检查都配了「故意把它该抓的问题重新制造出来一次，看它到底会不会报错」的实测，逐条记录在：

`docs/acceptance/2026-09-17-trainingset-p3b-mutation-log.md`

（这份记录一共做了多少组实测，请自己用文件里写的那条 `grep -c` 命令现场数，本清单不重复写这个数字。）

其中几组最值得看：

- **M0** —— 把唯一那条真正往数据库写数据的语句，列清单里的这一列删掉 ⇒ 检查**当场报错**，精确点名是哪个文件第几行。这是**上一版判据曾经完全抓不住**的那一处，也是全片最要紧的一组。
- **M2** —— 把一条**跨两行**书写、本来就合规的语句删掉这一列 ⇒ 检查照样报错。证明这条检查是按「一整条语句」在看，不是简单地一行一行扫，不会把跨行的语句看漏、也不会把跨行的合规语句误判成缺字段。
- **M5 + M6 配对** —— 只改排版（不改任何列名类型）仍然显示通过；真的改一个列名就会报错。证明第二条检查比对的是「两份说明内容是否一致」，不是死板地比对文字排版。
- **M7** —— 把程序里那段建表语句用到的变量名改掉 ⇒ 检查报「找不到这段语句」而报错，不是安静地把这次比对当成「两边都是空的所以算相等」。
- **M4i 与 M4m** —— 全片**两组**对应过「真正危险」缺陷的变异（⚠️ 上一版这里写「M4m 是唯一一组」，**那是写错了**，已按实测订正）：
  这两组都是「**把要删掉的那一列藏进注释里**」——对数据库来说这一列是真的没写，但检查曾经看不出来。
  第一次（M4i）是因为检查**根本没处理注释**；第二次（M4m）是因为注释**可以一层套一层**，而当时的处理只拆得开一层。
  两次都是**最危险的那个方向**：真的漏写了，检查却说「没问题」。现在两种写法都能被正确识别为缺失。
