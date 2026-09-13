# 切片一 P3c（顶层契约版本 bump + 治理矩阵订正 + Mac 旧包作废）· 非程序员验收清单

**这一片做了什么（一句话）**：把整个系统的「总版本号」从 `1.13` 升到 `1.14`（10 处需要一起动的地方，跨 6 个文件；⚠️ 其中一处是把「自我体检」用的样本数据整体往前挪一代，所以那里改完之后**仍然会看到 `1.13`**——这是对的、不是漏改），把治理台账里一行写错的记录（训练组数据库版本号）改对并补上触发条件，把 Mac 电脑本地那三个已经过时的压缩包正式标成「只做历史存档、不能再用」，然后给后两件事各自加上自动检查，防止以后再有人不小心把这些事弄错。

**为什么要做**：

- 「总版本号」（叫 `CONTRACT_VERSION`，你可以把它理解成软件包装盒上印的「版本 1.14」——前端（手机 App）和后端（服务器程序）拿到的版本号必须完全一样，一样才能保证两边说的是同一件事）本该在上一片改动（把「编号规则」改掉）之后立刻升级，但当时漏了，留到了这一片。放着不升，账本上会一直显示「这次改动还没有走完流程」。
- 治理台账（一份专门记录「什么改动要触发版本号升级」的文档）里有一行写着「训练组数据库版本号 = 1」，但实际程序早在两周前就已经把它改成了 `2`——文档和代码这两处**已经对不上**了，而且当时**没有任何自动检查**发现这件事。这一片把文档改对，并且新增一条自动检查，以后谁再让它们不一致，检查会立刻报错。
- Mac 电脑本地存着三份旧的训练数据压缩包，文档上写着「这三份可以直接拿来用」。但从这一片开始，数据库里存的「正确指纹」已经变了，如果将来有人真的把这三份旧包重新搬到服务器上，会导致数据损坏或者读不出来，而且**检查看起来还是通过的**（因为检查没预料到这种情况）。所以这一片把文档改成「这三份只能看、不能用」，并加一条自动检查防止旧文案复活。

---

## 开始之前

所有命令都在**这个目录**下跑：

```
/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run
```

⚠️ 这个目录里**没有**装 Python（一种编程语言的运行环境）。命令里那一长串路径 `"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3"` 是主目录里装好的那一份，**必须原样照抄**，不能省略、不能改写成简单的 `python3`。

⚠️ 每条命令**只有一行**。如果你复制粘贴到终端（就是那个黑色/白色的命令输入窗口）后它自动断成了好几行，说明复制过程中被截断了，请重新复制整行。

⭐ 这一片全部是**文档改动 + 自动检查代码**，**没有任何东西会跑到手机上**，也不会修改任何数据。想省时间的话，跑 **A1 + A2 + A6** 就够（约 1 分钟）。

---

## A1 · 后端全部测试通过，一条都没被跳过

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```

（这条命令的意思：把后端程序里**所有**自动检查项都跑一遍，一次跑 1400 多项。）

**期望看到**：最后一行是 `1405 passed in <某个秒数>`。

**通过判定**：

- 通过 —— 数字是 **1405**，且这一行里**没有** `failed`（失败）、`skipped`（跳过没跑）、`error`（出错）这三个词。
- 不通过 —— 出现上述任一个词；或数字不是 1405。

⚠️ **1405 是这条分支上的快照**（这条改动合并进主干之后，别人的新改动会让这个数字继续变化）。对不上时先查是不是别的改动动了这份基准数字，⛔ 不要直接改这份清单里的数字。

---

## A2 · 这一片新加的 6 条检查，逐条列给你看

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py::test_m01_matrix_training_set_row_matches_backend_ddl tests/test_deployment_source_texts.py -v
```

**期望看到**：含 `PASSED`（通过）的行**恰好 6 行**（前面还会有几行环境信息，不用管），最后一行形如 `6 passed in <某个秒数>`。六条分别在管：

| 序 | 这条在管什么 |
|---|---|
| 1 | 治理台账里「训练组数据库版本号」那一行，写的数字**必须跟后端建表代码里真正写着的数字一致**，而且必须带一句「App 那边暂时还没跟上」的说明 |
| 2 | 部署说明文档里，**不得再出现**「这三份 Mac 旧包既可以直接用」这句旧话 |
| 3 | 部署说明文档里，**必须真的写着**「这三份 Mac 旧包只能从服务器上重新取、旧包只作历史存档」这句改写后的新规则 |
| 4 | 那三份 Mac 旧包的指纹（CRC32，一种给文件算出的「校验码」，用来确认文件有没有损坏）旁边，**必须带着**「这是历史记录、不能拿来当判断标准」这句说明 |
| 5 | NAS（一台家用网络存储设备）上那份「交接目录」里同样三份旧包的指纹旁边，**也必须带着**同一句「历史记录、不能当判断标准」的说明——这三份指纹跟第 4 条里 Mac 那三份逐字相同，其实是同一批旧包的两份副本 |
| 6 | 「只能从 NAS 交接目录取」这条新规则，**必须带着一个前提条件**：要等重新生成新一代数据、并把新数据同步进那个交接目录之后，才能从那里取——不能不带条件地把交接目录当成一定能用的来源 |

**通过判定**：

- 通过 —— 含 `PASSED` 的行恰好 6 行，最后一行以 `6 passed` 开头。
- 不通过 —— 任何一行是 `FAILED`（失败）；或含 `PASSED` 的行数不是 6 行。

---

## A3 · 手机 App 那边的自动检查全部通过

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/ios/Contracts" && swift test 2>&1 | grep -E "Executed 302 tests|Test run with"
```

（这条命令跑手机 App 代码里的所有自动检查。App 用的编程语言叫 Swift，检查工具分两套，所以下面会看到两种不同格式的结果行。）

**期望看到**（共 3 行，前两行内容一样，是同一个结果打印了两次）：

```
	 Executed 302 tests, with 0 failures (0 unexpected) in <某个秒数> seconds
	 Executed 302 tests, with 0 failures (0 unexpected) in <某个秒数> seconds
✔ Test run with 1993 tests in 232 suites passed after <某个秒数> seconds.
```

**通过判定**：

- 通过 —— 前两行都是 `Executed 302 tests, with 0 failures`；第三行是 `Test run with 1993 tests in 232 suites passed`。
- 不通过 —— 任何一行数字不同，或出现 `failures` 后面的数字不是 0。

---

## A4 · 全仓库里「总版本号」的两个源头，都已经是 1.14

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && grep -n 'CONTRACT_VERSION = "1\.14"\|CONTRACT_VERSION == "1\.14"' -- backend/qmt_pilot_db.py ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift
```

（「总版本号」在代码里只应该有两个「源头」——后端一处、手机 App 一处，别处都是引用这两处的值。这条命令去这两个源头文件里各找一遍。）

**期望看到**：**恰好 2 行**：

```
backend/qmt_pilot_db.py:827:CONTRACT_VERSION = "1.14"
ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7:public let CONTRACT_VERSION = "1.14"
```

⚠️ 两行的先后次序可能与这里相反，不影响判定 —— 只要两行都在、且都是 `1.14`。

**通过判定**：

- 通过 —— 恰好 2 行，且都写着 `"1.14"`。
- 不通过 —— 少于 2 行（说明有一处没改到）；数字不是 1.14。

---

## A5 · 治理台账里那两行，改成了该有的样子

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && grep -n '`CONTRACT_VERSION`（顶层标识）\|训练组 SQLite `PRAGMA user_version`' docs/governance/m01-schema-versioning-contract.md
```

**期望看到**：**恰好 2 行**：

```
29:| `CONTRACT_VERSION`（顶层标识） | `"1.14"` | …
31:| 训练组 SQLite `PRAGMA user_version` | `2` | 训练组 schema **结构变更，或字段语义变更导致新旧产物互不可读**；联动顶层（⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地） |
```

**通过判定**：

- 通过 —— 第一行的值是 `"1.14"`；第二行的值是 `` `2` ``，并且**同一行里**带着「App 侧仍为 1」这句说明。
- 不通过 —— 任一处值不对；或第二行少了那句「App 侧仍为 1」的说明（少了它，文档会显得「前后端已经都支持新版本」，但实际手机 App 完全没跟上）。

---

## A6 · 三个禁区有没有被越界，尤其是手机 App 那一条

**这一条跟上一片（P3a）不一样，请务必看完。** P3a 那一片的规矩是「手机 App 相关文件改动数必须是 0」。**这一片不是** —— 这一片被设计文档明确允许改 4 个手机 App 相关文件，但这 4 个文件改的**全部是数字常量和测试用的断言文字/显示名**，手机 App **实际运行时的逻辑代码一行没动**。

**动作 1（两个真正不能碰的禁区）**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && echo "改动的 .github 文件数：$(git diff --name-only origin/main...HEAD -- .github/ | wc -l | tr -d ' ')；改动的生成器/建表文件数：$(git diff --name-only origin/main...HEAD -- backend/generate_training_sets.py backend/sql/ | wc -l | tr -d ' ')"
```

**期望看到**：`改动的 .github 文件数：0；改动的生成器/建表文件数：0`

**动作 2（手机 App 相关文件，列出具体是哪 4 个）**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && git diff --name-only origin/main...HEAD -- ios/ | sort
```

**期望看到**：**恰好这 4 行**（次序可能不同）：

```
ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift
ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift
```

**动作 3（更严格的一条：手机 App「真正会跑起来的代码」里只应该改了 1 个文件）**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && git diff --name-only origin/main...HEAD -- ios/Contracts/Sources/ | wc -l | tr -d ' '
```

（手机 App 的代码分两类：`Sources/` 目录下的是「真正会跑起来的代码」，`Tests/` 目录下的是「拿来检查代码对不对的测试代码」，测试代码本身不会跑到用户手机上。）

**期望看到**：`1`（只有 `Models.swift` 这一个文件，而且它里面只改了一个版本号字符串。）

**通过判定**：

- 通过 —— 动作 1 的两个数字都是 `0`；动作 2 恰好是那 4 个文件（一个不多一个不少）；动作 3 是 `1`。
- 不通过 —— 动作 1 任一数字大于 0（说明越界碰了不该碰的地方）；动作 2 出现清单之外的文件，或少了清单里的文件；动作 3 不是 1（说明手机 App「真正会跑起来的代码」被动了不止一处）。

---

## A7 · 两个已经存在的旧检查脚本，结果跟改动前一模一样（没有引入新问题）

**动作 1**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh 2>&1 | grep -E "passed, .* failed"
```

**期望看到**（最后一行）：`Plan 1f (M0.1 schema versioning) acceptance: 22 passed, 3 failed`

**动作 2（⚠️ 这一条必须单独跑，不能接在别的命令后面）**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && bash scripts/acceptance/plan_e2_position_manager.sh 2>&1 | grep -c "^FAIL:"
```

**期望看到**：`2`

**通过判定**：

- 通过 —— 动作 1 的结尾是 `22 passed, 3 failed`；动作 2 的结果是 `2`。
- 不通过 —— 任一数字变化。

⚠️ 这两条脚本里各自的「失败」项，都是**这一片之前就存在**的老问题（详见下面「已知残留」的 R7、R8），不是这一片造成的，只要数字没有**变化**（delta 为 0）就算通过。
⚠️ 动作 2 之所以要单独跑：`grep -c` 数到 0 个匹配时，会返回一个「失败」的退出信号，如果接在别的命令后面（用 `&&` 连接），会把整条命令链在这里意外掐断，看起来像出错了，其实是正常的。

---

## A8 · 本片一共动了哪些文件

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && git diff --name-only origin/main...HEAD | sort
```

**期望看到**（12 行——这份验收清单、变异记录、施工计划这三份文档已经提交进版本记录，所以是 12 行；⚠️ 若你是在这三份文档提交**之前**跑这条命令，会看到 9 行，少了标星号 ⭐ 那 3 行；参考上一片 P3a 那份清单 A6 的同类说明）：

```
backend/qmt_pilot_db.py
backend/tests/test_deployment_source_texts.py
backend/tests/test_frozen_contract_texts.py
docs/acceptance/2026-09-07-trainingset-p3c-acceptance.md
docs/acceptance/2026-09-07-trainingset-p3c-mutation-log.md
docs/governance/m01-schema-versioning-contract.md
docs/superpowers/plans/2026-09-07-trainingset-p3c-version-bump.md
docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md
ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift
ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift
```

⭐ 上面 12 行里，`docs/acceptance/2026-09-07-trainingset-p3c-acceptance.md`（本清单）、`docs/acceptance/2026-09-07-trainingset-p3c-mutation-log.md`（变异记录）、`docs/superpowers/plans/2026-09-07-trainingset-p3c-version-bump.md`（施工计划文档）这 3 个，就是「提交前只有 9 行、提交后变 12 行」里多出来的那 3 个。

| 文件 | 干什么的 |
|---|---|
| `backend/qmt_pilot_db.py` | 后端侧「总版本号」常量，改成 `1.14` |
| `backend/tests/test_deployment_source_texts.py` | 新建文件，装 A2 表格里第 2、3、4、5、6 条检查 |
| `backend/tests/test_frozen_contract_texts.py` | 在已有文件里加一条检查（A2 表格里第 1 条） |
| `docs/governance/m01-schema-versioning-contract.md` | 治理台账：顶层版本号、训练组那一行、以及一段说明这次升级原因的记录 |
| `docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md` | 部署说明文档：Mac 旧包那两处文字改写 |
| `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | 手机 App 侧「总版本号」常量，改成 `1.14`（**这一片唯一改动的手机 App「真正会跑」的代码，只改了这一个字符串**） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift` | 手机 App 测试代码：测试函数名字与断言里的数字同步改成 `1.14` |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift` | 手机 App 测试代码：一处测试的显示名字与断言数字同步改 |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift` | 手机 App 测试代码：对照治理台账的断言数字同步改，以及刷新一份「自我体检」用的样本数据 |

**通过判定**：

- 通过 —— 只出现上面这 12 个（若在三份文档提交之前跑，是 9 个）。
- 不通过 —— 出现清单之外的文件。

---

## 本片交付后**仍不成立**的事（请逐条读）

### R1 · 数据库写入语句里有 10 处漏写一个字段

程序里往「训练组」这张表**写入新记录**的语句，有 10 处忘了写「schema_version」（可以理解成「这条记录是按哪个版本的格式写的」）这个字段。这 10 处里有 5 处在自动化流水线的配置文件（CI，一种代码提交后自动跑检查的机制）里。归下一片 **P3b** 处理——那一片是唯一被允许改动这类自动化配置文件的一片。

### R2 · 「生成程序」和「冻结的建表文件」之间没有任何检查在盯着两者是否一致

程序里那份「照着建表」的语句、和仓库里那份「已经定版、不能随便改」的建表文件，**中间没有任何检查**确认两者写的是不是同一件事。这个漏洞从更早的版本就存在，不是这一片或更早几片造成的。建议并入 **P3b**（同属「补检查」类工作）。

### R3 · 数据库里现存的 3 个训练组，仍是老版本格式

在**下一步（P4）** 把它们重新生成成新版本格式之前，负责对外提供服务的程序（`api`）、按时间自动跑的任务（`scheduler`）、以及生成训练组的命令行工具，**都必须保持停止状态**，不能上线运行。

### R4 · 手机上还是用不了

手机 App 那边**运行时的逻辑代码一行没改**，只闭合了「服务器生产数据」这一半。这件事归**切片二**（下一个大阶段），而且切片二要过**两道拦路石**：一是手机 App 现在只认识旧的文件格式（`.sqlite`），二是 `DefaultTrainingSetReader.swift` 文件第 90-92 行有一段代码，会在读到新格式数据时直接判定为「数据库损坏」并拒绝。

⛔ 因此**不能说**「手机能用了」「跨端约定已闭合」「版本已对齐」。
可以说：**「顶层契约版本已升到 1.14，治理矩阵与后端建表代码已经对齐」**。

### R5 · 切片二必须再升一次版号（多半是 1.15，但不保证）

`1.14` 是一个**故意留着的过渡状态**：代表「数据已经是新格式，但手机 App 还没跟上」。如果切片二做完之后不再升一次版号，那「手机 App 还读不了新格式」和「手机 App 已经能读新格式」这两种完全不同的状态，就会共用同一个版本号 `1.14`，所有跨语言的自动检查在两种状态下都会显示「正常」——版本号就失去了应有的意义。⚠️ 至于升完是不是正好 `1.15`：**如果这段时间里没有别的改动先占用了下一个号，那就是 `1.15`**；但现在同时还有另一条工作线（划线工具那条线）也欠着「必须升一次版号」的账，它很可能比切片二先把下一个号用掉 —— 所以这里只能说「下一个号」，不能咬死一定是 `1.15`。

### R6 · 带着旧版本号 `1.13` 的既有测试数据库，会被一道检查拒绝

后端有一道检查（叫「闸 1」）会逐字比对数据库里记录的版本号。升级之后，任何还标着 `"1.13"` 的旧测试数据库都会被拒绝，报错提示需要用 `--reset`（一个命令行参数）重新生成。目前这条数据链路（代号「4b」）还没有正式投入使用，风险不大。

### R7 · 有一处早就过时的记录，这一片故意没改

`kline_trainer_modules_v1.4.md` 文件第 144 行，写着「总版本号 = 1.5」，但实际早就不是这个数字了。这是**很早以前**就存在的过时记录，不是这一片造成的。**实测确认过**：有一个既有的检查脚本（`plan_e2_position_manager.sh` 第 37 行）现在正好断言「这里应该是 1.5」并且**当前是通过的**——如果顺手把它改对，反而会让那个脚本从「2 项失败」变成「3 项失败」。这件事归另一份文档（`2026-08-31-acceptance-stale-literals-design.md`）里的条目 F21 管，这一片不动它。

### R8 · 另一个既有检查脚本，仍有两处失败要求「1.5」

`plan_e2` 那个检查脚本里另外两处判断，也要求某个值等于「1.5」，这一片升级之后这两处**依然是失败状态**——但这是**这一片之前就存在**的失败，不是这一片新引入的，失败的数量前后没有变化。

### R9 · 有一处代码注释里的旧函数名，这一片故意没改

`catalyst-gate.sh` 文件第 161 行的一段长注释里，举的例子仍然写着 `contractVersionIs1_11()`（这是**两次版本升级之前**的函数名字）。它只是注释里的**举例**，不是真正被拿来判断对错的代码（已经实测确认：真正的基准文件里，含有 `contractVersionIs` 这个词的地方命中数是 0，说明它没被任何检查读取）。改动它跟这一片的目标无关，属于「顺手改了不该改的东西」，所以不改。

### R10 · 那道「不许再出现旧文案」的检查，防不住换一种说法

那道检查只死板地盯着「既可从 Mac scp」这**恰好 8 个字**。只要有人把这句话改写成别的说法（比如「也可以从 Mac 拷一份」），或者换成英文，或者把一句话拆成两行来写，这道检查统统**看不出来、照样放行**。这是**有意的取舍**：如果要让检查连各种改写方式都能识别，实现的复杂程度会远远超过它带来的好处，跟上一片（P3a）里同一形状的取舍（R10）一样。

### R11 · 有一份运维操作手册，取数据的目录还是旧包所在的目录

运维手册里那份「怎么从服务器上取数据」的步骤，现在是从 NAS（网络存储设备）上一个叫 `kline-trainer-handoff-20260814/` 的目录里拷贝，但那个目录里存放的**仍然是老版本格式的包**。这一片新加的检查**发现不了这件事**，因为那份手册里根本没出现「Mac」这个词，检查没有理由去盯它。**下一步（P4）必须把这个「数据来源目录」本身也一起处理掉**，否则将来照着手册干净地重新部署一次，会用过时的包把已经修好的包覆盖回去。这是这一片背后的设计文档里点名的「最危险的一处」。

### R12 · 这一片新加的检查，就算今天全部报错，也拦不住代码被合并

后端的这些自动检查**目前不在**代码托管平台（GitHub）设置的「必须通过才能合并」名单里。修好这件事需要开一个独立的改动，而且需要你本人登录网页去修改仓库设置，不是靠写代码能解决的。

### R13 · 治理台账顶层那一行的检查，比对的是「写死的数字」，不是「真正的代码常量」

`M01MatrixSyncGuardTests.swift` 第 52 行那道检查，比对的是「治理台账」和「测试代码里手写的一个数字」是否一致，而不是直接去读后端或手机 App 代码里那个真正的版本号变量。它能挡住「改了代码却忘了改治理台账」这种错误，但**下一次升版号时，这个手写的数字仍然需要有人手动去改**。这一片**没有扩展**这道检查（这一片新加的、管「训练组那一行」的检查已经做成了「文档 ↔ 代码变量」直接比对的形式；「顶层那一行」维持原来的设计，属于既有安排，不在这一片范围内）。

### R14 · 那道文案检查的「绕过方式」，现在已经写进检查代码自己的说明里

跟 R10 说的是同一件事（那道检查只死板地盯着「既可从 Mac scp」这 8 个字，同义改写、英文、拆成两行都能绕过去），但这里要补充一点：**这个已知的局限性现在已经写进了检查文件（`backend/tests/test_deployment_source_texts.py`）自己开头的说明里**，而不只是写在这份验收清单或某份设计文档里。这样做的原因是：将来有人想搞清楚「这道检查到底护住了什么、护不住什么」，他会打开的是**检查代码本身**，而不是回头去翻某份计划文档。

### R15 · 那道检查只认三种文件后缀，将来加别的格式会被悄悄漏掉

`test_deployment_source_texts.py` 里扫描运维手册目录时，**只看**文件名以 `.md`（普通文档）、`.sql`（数据库脚本）、`.sh`（命令行脚本）结尾的文件。今天运维手册目录下的 14 个文件确实都是这三种格式（8 个 `.md`、2 个 `.sh`、4 个 `.sql`），所以现在没问题。但**将来如果有人往这个目录里放别的格式的文件**（比如自动化配置常用的 `.yml`），这道检查会**安安静静地跳过它、不会报任何错误**，而不是发现「有个新格式我不认识」再提醒人。这个盲区已经写进代码自己的注释里提醒——日后新增文件后缀，必须回来把这条检查也一并补上。

---

## 变异验证（这些检查**真的会红吗**）

光看「测试全绿」说明不了任何事——一条永远为真的断言，也会永远显示「通过」。所以这一片给每一条新加的检查都配了「故意把它该抓的问题重新制造出来一次，看它到底会不会报错」的实测，一共 **10 组**，逐条记录在：

`docs/acceptance/2026-09-07-trainingset-p3c-mutation-log.md`

其中四组最值得看：

- **M2** —— 把后端建表代码里的版本号改成 `3`（一个从没出现过的数字）⇒ 检查**当场报错**，而且错误信息里**原样写出「实际是 3」**——证明这道检查是**真的在读代码里当下的值**，不是拿一个写死在检查代码里的数字自欺欺人。
- **M6** —— 把「Mac 旧包只能作历史存档」那句改写后的新规则**整行删掉**（相当于把证据也一起删掉）⇒ 那道「不许出现旧文案」的**禁令检查反而变绿了**（因为旧文案确实也不在了），只有「新规则必须真的写着」的**正向对照**检查报了错——证明**光靠「不许说旧话」是不够的，必须同时有「必须说新话」这一道，否则「把新旧规则一起删掉」这种蒙混手法能骗过检查**。
- **M8** —— 特意往一份运维手册里塞进一行假的「旧文案」⇒ 检查**当场报错，并且精确点名是哪一个文件、第几行**——证明这道检查的覆盖范围**确实**包含运维手册目录，不只是盯着那一份设计文档。
- **M9** —— 把「新规则必须写着」和「历史存档说明必须写着」这**两处**改动**一起删掉**⇒ 分成两个独立检查项后，**两条各自报错、各自点名自己该管的那一处**；如果当初图省事把这两条判断写进同一个检查函数里，第一条判断一失败整个函数就会停下来，第二处缺失就会被**完全遮住、看不见**。
