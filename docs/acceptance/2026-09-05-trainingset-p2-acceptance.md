# 切片一 P2（跨端接缝生产者半边）· 非程序员验收清单

**这一片做了什么（一句话）**：造了**一件**样本训练组文件、把它存进仓库，并加了一道自动检查 —— 以后每次改动，都会拿「当前程序现做的一份」跟「仓库里存的这一份」对账，对不上就报错。

**为什么要这么做**：以前后端和手机 App 各自拿着**互不相干**的样本在做测试。两边各测各的、各自都绿，中间那道缝里的毛病就一直藏着 —— 这一片就是把两边**钉到同一件东西上**的前半截。

---

## 开始之前

所有命令都在**这个目录**下跑：

```
/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run
```

⚠️ 这个目录里**没有** Python 环境，命令里那串长长的解释器路径是主目录里的，不能省略、不能改成 `python3`（会报 `ModuleNotFoundError: No module named 'pandas'`）。

⚠️ 每条命令**只有一行**。若你的终端把它折成了几行，说明复制时被换行截断了，重新复制。

---

## A1 · 后端全部测试通过，且一条都没被跳过

**动作**（复制整行）：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```

**期望看到**：最后一行是

```
1130 passed in <某个秒数>
```

**通过判定**：

- ✅ 通过 —— 数字是 **1130**，并且这一行里**没有** `failed`、**没有** `skipped`、**没有** `error` 这三个词。
- ❌ 不通过 —— 出现上述任一个词；或数字不是 1130。

⚠️ 判据是**这一行里的数字和词**，不是它有没有打印「成功」。数字比 1130 大也算不通过 —— 那说明有人往里加了东西，需要先弄清楚是谁加的。

---

## A2 · 这一片新加的 9 条检查，逐条列出来给你看

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_trainingset_contract_fixture.py -v
```

**期望看到**：9 行，每行结尾都是 `PASSED`，最后一行是 `9 passed`。九条分别在管：

| 序 | 这条在管什么 |
|---|---|
| 1 | 样本文件的名字没被人偷偷改掉（名字是跨端约定的一部分） |
| 2 | 样本的起点日期确实落在**周中**（落周一就造不出「被删掉的跨界周」那个特征） |
| 3 | 三类刻意做进去的特征**真的在数据里**，不是只写在注释里 |
| 4 | 造样本时**真的走了生产程序**，不是有人手工挑几根拼出来的 |
| 5 | 仓库里那份样本文件确实存在（不存在就直接报错，⛔ 不许悄悄跳过） |
| 6 | 现做的一份，六个周期的编号跟**人工手算**的答案逐个相等 |
| 7 | 仓库里存的那份，同样跟人工手算的答案逐个相等 |
| 8 | **对账闸**：现做的一份跟仓库里那份，内容一致 |
| 9 | **对账闸自己的体检**：那道闸的比对范围没被人偷偷改小 |

**通过判定**：

- ✅ 通过 —— 9 行全是 `PASSED`，且最后一行是 `9 passed`。
- ❌ 不通过 —— 任何一行是 `FAILED`；或条数不是 9 条。

---

## A3 · 仓库里那份样本文件，里面确实只装了一个东西

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && unzip -l tests/contract-fixtures/training-set/999002.SZ_1774972800.zip
```

**期望看到**（逐字对照）：

```
  Length      Date    Time    Name
---------  ---------- -----   ----
    32768  01-01-1980 00:00   999002.SZ_1774972800.db
---------                     -------
    32768                     1 file
```

**通过判定**：

- ✅ 通过 —— 最后一行是 `1 file`（**恰好一个**，没有夹带别的文件），文件名以 `.db` 结尾，日期是 `01-01-1980`。
- ❌ 不通过 —— 文件数不是 1；或日期不是 1980-01-01。

⚠️ 那个 1980 年的日期是**故意写死的**：压缩包默认会把「打包那一刻的时间」记进去，不写死的话同样的输入每次打出来的文件都不一样。

---

## A4 · 重新生成一遍，必须得到**一模一样**的文件

**动作**（第一步：先备份一份）：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && cp tests/contract-fixtures/training-set/999002.SZ_1774972800.zip /tmp/verify_before.zip
```

**动作**（第二步：重新生成）：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" backend/scripts/regen_trainingset_contract_fixture.py
```

**期望看到**：输出里有这一行

```
  内容与原先**逐字节相同**
```

**动作**（第三步：不信它的自述，自己比一遍）：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && cmp /tmp/verify_before.zip tests/contract-fixtures/training-set/999002.SZ_1774972800.zip && echo "两份文件完全相同" && git status --short
```

**期望看到**：`两份文件完全相同`，并且**它下面什么都没有**（`git status --short` 无输出 = 仓库里没有任何文件被改动）。

**通过判定**：

- ✅ 通过 —— 第二步打印了「逐字节相同」，且第三步打印了「两份文件完全相同」、下方无任何文件名。
- ❌ 不通过 —— `cmp` 报出差异；或第三步在「两份文件完全相同」下面列出了文件名。

⚠️ 这一条为什么重要：以后如果那道对账闸报错，唯一正确的办法是先搞清楚「程序的行为是不是**有意**改的」。如果重新生成本身就不稳定（同样输入产出不同文件），那这套办法整个就立不住了。

⚠️ 顺带一句：命令打印出来的那个 `content_hash`（一串 8 位字符）**换一台电脑就会变** —— 因为数据库文件里存了「写它的那个数据库程序的版本号」。所以**任何检查都不许拿这串字符当判据**，本片的对账闸比的是内容不是字节。

---

## A5 · 手机 App 的代码，这一片一行都没动

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && echo "改动的 App 文件数：$(git diff --name-only origin/main...HEAD -- ios/ | wc -l | tr -d ' ')"
```

**期望看到**：`改动的 App 文件数：0`

**通过判定**：

- ✅ 通过 —— 数字是 `0`。
- ❌ 不通过 —— 数字大于 0。

---

## A6 · 被检查的那个程序本身，这一片也一行没动

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && echo "改动的生成器/建表/CI 文件数：$(git diff --name-only origin/main...HEAD -- backend/generate_training_sets.py backend/sql/ .github/ | wc -l | tr -d ' ')"
```

**期望看到**：`改动的生成器/建表/CI 文件数：0`

**通过判定**：

- ✅ 通过 —— 数字是 `0`。
- ❌ 不通过 —— 数字大于 0。

⚠️ 这一条是本片的**性质判据**：这一片**只加检查、不改被检查的东西**。一旦这个数字不是 0，就意味着「用被改过的尺子去量被改过的东西」，整片的结论都要重新审。

---

## A7 · 本片一共动了哪 7 个文件

**动作**：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && git diff --name-only origin/main...HEAD
```

**期望看到**（7 行，次序可能不同）：

```
backend/scripts/regen_trainingset_contract_fixture.py
backend/tests/_trainingset_contract_fixture.py
backend/tests/test_trainingset_contract_fixture.py
docs/superpowers/plans/2026-09-04-trainingset-p2-crossboundary-fixture.md
tests/contract-fixtures/README.md
tests/contract-fixtures/training-set/999002.SZ_1774972800.zip
tests/contract-fixtures/training-set/README.md
```

每个文件是干什么的：

| 文件 | 干什么的 |
|---|---|
| `backend/scripts/regen_…py` | 重新生成样本文件的**唯一**入口（人工执行，带「重生 = 改约定」的警告） |
| `backend/tests/_trainingset_contract_fixture.py` | 造样本的模具：合成一批行情数据，再走**生产程序**切窗、打包 |
| `backend/tests/test_trainingset_contract_fixture.py` | 上面那 9 条检查 |
| `docs/superpowers/plans/2026-09-04-…md` | 这一片的施工计划（含施工过程中被评审打回后的两次订正） |
| `tests/contract-fixtures/README.md` | 原有的跨语言约定说明，**只在末尾加了一节**指路 |
| `tests/contract-fixtures/training-set/999002.SZ_1774972800.zip` | ⭐ **样本文件本体** |
| `tests/contract-fixtures/training-set/README.md` | 样本文件的说明书：它是什么、怎么重生、**什么时候不该重生** |

**通过判定**：

- ✅ 通过 —— 恰好这 7 个，没有多余的。
- ❌ 不通过 —— 出现清单之外的文件。

---

## 本片交付后**仍不成立**的事（请逐条读，不要跳过）

这几条是**事实陈述**，不是待办清单的客套话。它们决定了这一片交付后你**还不能说什么**。

### R1 · 手机上还是用不了

App 侧一行代码没改，它仍然读不了任何真实训练组（它只认压缩包里叫 `.sqlite` 的文件，而真实产物里是 `.db`）。**这一片只做了缝的前半截**，后半截（解压 → 打开 → 读取）归**切片二**，并且切片二必须用**这一份**样本，不许另造。

⛔ 因此**不能说**「手机能用了」「真实数据链路打通了」「跨端约定已闭合」。
✅ 可以说**「跨端接缝的生产者半边已交付」**。

### R2 · 数据库里那 3 个训练组，仍然是**第 1 代**

这一片只加检查、不重新生成产物。库里那三个包还是老一代。**这段窗口里，后端服务 `api`、定时任务 `scheduler`、生成器命令行都必须保持停止** —— 现在的程序会产出第 2 代，跟库里的第 1 代对不上。重建归 **P4**。

### R3 · 那道新加的对账闸，**今天全红也拦不住合并**

后端测试在 GitHub 上**不是必需检查**（`main` 的规则集里只有 6 项必需检查，后端测试不在其中）。也就是说，这道闸每次都会跑、会显示红，但**按不下合并按钮这件事不会发生**。修法是把它加进必需检查清单，属**独立的一个 PR**，而且需要你本人在 GitHub 网页上改配置。

### R4 · 样本文件的「校验码」依赖写它那台电脑的数据库程序版本

数据库文件头里存着「最后写它的那个 SQLite 程序的版本号」（本机实测 `3053003`，即 3.53.3 版）。换台电脑或升一次级，同样的输入产出的**字节和校验码都会变**。

⇒ 本片的对账闸因此**只比内容不比字节**，这是对的。
⇒ ⚠️ 但同一条事实对 **P4** 有影响：P4 的运维手册里写死了三个包的「内容指纹」，而「产物有疑就重跑一遍、必得同一批包」这个前提**只在同一台电脑同一版本下成立**。这条已记入残留，P4 必须正面处理。

### R5 · 有个既有的漏洞，本片**故意没修**

生成程序里那份建表语句，和仓库里那份「冻结的」建表语句文件，**中间没有任何检查**在管它们是否一致 —— 注释里写着「逐字一致」，但没人验。而自动检查测的是**文件**，实际写数据库用的是**程序里那份**。两者一旦漂移，闸门会绿着放行。

这个洞从更早的版本就在，不是这一片造成的。混进来会把评审面搅浑 ⇒ **建议归 P3**（P3 本来就在处理约定文本的一致性）。

### R6 · 一个今天到不了、但记下来的地雷

如果生成程序哪天真的往数据库里存了一个「非数字」（NaN），因为「非数字不等于它自己」这条语言规则，那道对账闸会**永久报红，而且没法通过重新生成来消解**。今天到不了 —— 程序在写库前会把非数字转成空值。仅作记录，本片不处理。

---

## 变异验证（这一片的检查**真的会红吗**）

光看「测试全绿」说明不了任何事 —— 恒真的断言也永远是绿的。所以每条判据都配了「故意改坏一处、看它红不红」的实测，共 **10 组**，逐条记录在：

`docs/acceptance/2026-09-05-trainingset-p2-mutation-log.md`

其中三组最值得看：

- **P4**：把压缩包里的文件后缀从 `.db` 改成 `.sqlite` ⇒ **只有对账闸红**，那条「后缀检查」纹丝不动 —— 证明两者分工是真的，谁也替不了谁。
- **P6b**：绕过生产程序、手工丢掉那根跨界周，产出**逐根相同** ⇒ **只有那条「必须走生产程序」的守卫红**，其余全绿。这条守卫是评审挖出来的，原计划里没有。
- **P7b**：把对账闸的比对范围砍掉一块 + 把公式改错 ⇒ **对账闸变绿了（真瞎了）**，只有它自己的体检项红 —— 证明那条体检项是承重的，不是装饰。
