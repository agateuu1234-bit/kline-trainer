# 切片一 P1（训练组产物代际公式改造）验收清单

> 面向非程序员。一行一条命令，从上往下照做，不需要看懂命令本身是什么意思。
> `PY=` 那一行只需在**每个新开的终端窗口**跑一次。
> 本清单覆盖的是"训练组产物怎么打包、怎么标注周期结束时刻"这部分代码改动，
> **不**涉及手机 App、**不**涉及 NAS 部署、**不**会改动任何已经生成好的训练组文件。

## 准备（每个新终端窗口跑一次）

| 动作 | 预期 | □ Pass / □ Fail |
|---|---|---|
| 粘贴：`PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3"` | 没有任何输出，光标回到新的一行 | □ |
| 粘贴：`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend"` | 没有任何输出，光标回到新的一行 | □ |

## 一、后端全套测试计数

| 动作 | 预期 | □ Pass / □ Fail |
|---|---|---|
| 粘贴：`"$PY" -m pytest tests/ -q` | 跑大约 30–40 秒后打印统计行 | □ |
| 检查上一步的**最后一行** | 最后一行**恰好**是形如 `1118 passed in XX.XXs` 的字样——数字必须是 `1118`，且**不含** `failed`、`error`、`skipped` 这几个词 | □ |

## 二、schema 硬门（数据库表结构的自动校验脚本）

「schema 硬门」是一个专门检查数据库表结构是否写对的自动化脚本——它会真的建一份数据库文件，
按新写的建表语句建表，再检查版本号对不对，任何一步不对都会报错退出。

| 动作 | 预期 | □ Pass / □ Fail |
|---|---|---|
| 粘贴：`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && bash backend/sql/tests/test_training_set_schema.sh; echo "退出码=$?"` | 打印两行 | □ |
| 检查上一步输出 | 第一行**恰好**是 `PASS: training_set_schema_v1.sql deploys with user_version=2`；第二行**恰好**是 `退出码=0` | □ |

## 三、本片零 App 改动

「App」指手机上装的那个客户端程序（iOS 项目，仓库里放在 `ios/` 目录下）。本片只改后端
（服务器那一侧的代码），手机端代码一行没动。

| 动作 | 预期 | □ Pass / □ Fail |
|---|---|---|
| 粘贴下方代码块里的命令 | 只打印一行 | □ |
| 检查上一步输出 | 那一行**恰好**是 `0` | □ |

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && git diff --name-only origin/main...HEAD -- ios/ | wc -l | tr -d ' '
```

## 四、旧表述扫描（逐条核对，不是"无输出就算过"）

早期版本的注释里写过一种后来被证明是错的计算方法（把"这根 K 线属于哪个周期"算错，专业说法
叫"下一根开盘减一秒"）。改对之后，代码里不应该再有任何**正在生效**的这种旧写法——但允许留着
"提醒后人别再犯"性质的注释（写明"已作废"或"不得这样做"）。

| 动作 | 预期 | □ Pass / □ Fail |
|---|---|---|
| 粘贴下方代码块里的命令 | 打印**恰好 2 行** | □ |
| 逐行核对：第一行是否包含「已作废」字样 | 第一行**必须**包含「已作废」 | □ |
| 逐行核对：第二行是否包含「不得」字样 | 第二行**必须**包含「不得」 | □ |

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && grep -n '下一根 open\|下一open\|\[open, *下一' backend/generate_training_sets.py
```

⚠️ 这条的通过标准是"**恰好命中 2 条、且两条都是禁止/作废语气的注释**"——不是"零命中"。如果命中数
不是 2，或者命中的行里出现了看起来像"正在被调用"的代码（而不是注释里的提醒），判 Fail 并停下来问。

## 五、`user_version = 1` 残留扫描

数据库文件里有个版本号字段（`user_version`），这次改动把它从 `1` 升到了 `2`。仓库里应该只剩
**一处**还写着 `user_version = 1`，而且那一处必须是手机 App 那侧的调试代码（专门用来生成小
样本文件测试用的），不是后端代码。

| 动作 | 预期 | □ Pass / □ Fail |
|---|---|---|
| 粘贴下方代码块里的命令 | 打印**恰好 1 行** | □ |
| 检查那一行的文件路径 | **必须**是 `docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md`（App 侧调试写入器的验收记录，不是后端代码），且该行内容**必须**提到 `DebugTrainingSetWriter` | □ |

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && grep -rn 'user_version = 1\|user_version=1' backend/ scripts/acceptance/ docs/acceptance/ --exclude=2026-09-03-trainingset-p1-acceptance.md 2>/dev/null
```

（`--exclude` 排除的是**本清单文件自己**——本文件的说明文字里也写了同一串字样，不排除会把自己算进命中数里。）

## 六、zip 打包的确定性（跨两次独立进程）

「打包」= 把训练组数据库文件压缩成一个 `.zip` 文件，再算一个 8 位的指纹码（CRC32，可以理解成
给这个文件拍的一张"身份证照片"）。运维那边有一条规则：**同一份数据，不管什么时候打包、打包
几次，指纹码必须完全一样**——这样"重新打包一次"才能被信任成"和上次是同一批东西"。下面这条
命令会**真的开两个独立的 Python 程序进程**（不是同一个程序内部循环两次）来验证这件事。

| 动作 | 预期 | □ Pass / □ Fail |
|---|---|---|
| 粘贴下方代码块里的命令 | 打印两行 | □ |
| 检查第一行 | **恰好**是 `H1=3a4ccb7e H2=3a4ccb7e`（两个指纹码必须一模一样，值必须都是 `3a4ccb7e`） | □ |
| 检查第二行 | **恰好**是 `字节完全相同`（如果两个 zip 文件字节不同，`cmp` 那一步会报错、这行不会出现） | □ |

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" && rm -f /tmp/qmt_accept_x.db /tmp/qmt_accept_a.zip /tmp/qmt_accept_b.zip && "$PY" -c "from pathlib import Path; Path('/tmp/qmt_accept_x.db').write_bytes(b'acceptance-check-payload'*100)" && H1=$("$PY" -c "from pathlib import Path; from generate_training_sets import zip_and_hash; print(zip_and_hash(Path('/tmp/qmt_accept_x.db'), Path('/tmp/qmt_accept_a.zip')))") && touch -mt 202601010000 /tmp/qmt_accept_x.db && H2=$("$PY" -c "from pathlib import Path; from generate_training_sets import zip_and_hash; print(zip_and_hash(Path('/tmp/qmt_accept_x.db'), Path('/tmp/qmt_accept_b.zip')))") && echo "H1=$H1 H2=$H2" && cmp /tmp/qmt_accept_a.zip /tmp/qmt_accept_b.zip && echo "字节完全相同"
```

## 七、本轮最终评审两条修复的判别力（专项）

这两条是"合并前最后一轮评审"新挖出的问题，判别力已用变异测试验证过（详见
`docs/acceptance/2026-09-03-trainingset-p1-mutation-log.md` 的"基线更新"一节），这里只需确认
对应测试确实存在并通过。

| 动作 | 预期 | □ Pass / □ Fail |
|---|---|---|
| 粘贴：`"$PY" -m pytest tests/test_generate_training_sets.py -q -k "zip_and_hash or week_end_date"` | 打印统计行 | □ |
| 检查上一步输出 | 最后一行**恰好**是 `3 passed, 53 deselected in X.XXs`（数字 `3` 与 `53` 必须一致，且**不含** `failed`） | □ |

## 本片交付后仍不成立的事

- 数据库里**现存的 3 个训练组文件仍是第 1 代产物**（旧的 `user_version=1`、旧的
  `end_global_index` 算法）——本片**只改了生成代码**，没有重新生成任何一个文件。重建这些文件
  是后续切片的工作，本片交付**不代表**它们已经被修好。
- ⛔ **不得**据此声称"手机现在能用了"——手机 App 至今没有成功消费过一个真实训练组，这个状态
  在本片之后**没有改变**。
- ⛔ **不得**据此声称"真实数据链路已经打通"——本片验证的是生成代码本身的正确性（在隔离的测试
  环境里），不是端到端从后端生成到手机读取的完整链路。
